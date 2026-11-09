import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/models/quark/quark_catalog_item.dart';
import 'package:nipaplay/models/quark/quark_mount_folder.dart';
import 'package:nipaplay/models/watch_history_database.dart';
import 'package:nipaplay/services/quark/quark_catalog_store.dart';
import 'package:nipaplay/services/quark/quark_api_client.dart';
import 'package:nipaplay/services/quark/quark_metadata_scraper.dart';
import 'package:nipaplay/services/quark/quark_scan_pacer.dart';
import 'package:nipaplay/services/quark/quark_service.dart';
import 'package:nipaplay/utils/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _testTmdbApiKey = '0123456789abcdef0123456789abcdef';

QuarkCatalogItem _parse(String name, List<({String fid, String name})> dirs) {
  return QuarkCatalogItem.parse(
    fid: 'video',
    fileName: name,
    directories: [(fid: 'root', name: '电影电视剧'), ...dirs],
    size: 1234,
    modifiedAt: 1000,
    addedAt: 2000,
  );
}

void main() {
  test('groups TV seasons under the series folder and preserves parts', () {
    const series = (fid: 'show', name: '例剧 (2024)');
    final episode = _parse('例剧 - S02E03-2 - 第 3 集.mkv', [
      series,
      (fid: 's2', name: 'Season 02'),
    ]);
    final earlier = _parse('例剧 - S01E12.mp4', [
      series,
      (fid: 's1', name: 'Season 01'),
    ]);

    expect(episode.workKey, earlier.workKey);
    expect(episode.title, '例剧');
    expect(episode.year, 2024);
    expect((episode.season, episode.episode, episode.part), (2, 3, '2'));
    expect(episode.label, contains('S02E03'));
    expect(episode.episodeOrder, greaterThan(earlier.episodeOrder));
    expect(
        episode.relativePath, '例剧 (2024)/Season 02/例剧 - S02E03-2 - 第 3 集.mkv');
  });

  test('uses the film folder, strips format, and keeps multipart ordering', () {
    const movie = (fid: 'movie', name: '例片 (2019)');
    final first = _parse('例片 (2019)-cd1 - 2160p.mkv', [movie]);
    final second = _parse('例片 (2019)-cd2 - 2160p.mkv', [movie]);
    final noYear = _parse('无年份-2 - 1080p.mp4', [(fid: 'other', name: '无年份')]);

    expect(first.isSeries, isFalse);
    expect(first.workKey, second.workKey);
    expect(first.displayTitle, '例片 (2019)');
    expect(first.part, 'cd1');
    expect(second.episodeOrder, greaterThan(first.episodeOrder));
    expect(noYear.displayTitle, '无年份');
    expect(noYear.part, '2');
  });

  test('the metadata pacer waits 2 seconds per request and 30 per batch',
      () async {
    var now = DateTime(2026);
    final delays = <Duration>[];
    final pacer = QuarkScanPacer(
        now: () => now,
        delay: (duration) async {
          delays.add(duration);
          now = now.add(duration);
        });
    for (var page = 0; page < 11; page++) {
      await pacer.waitForTurn();
    }
    expect(delays, [
      for (var page = 1; page < 10; page++) const Duration(seconds: 2),
      const Duration(seconds: 30)
    ]);
  });

  test('directory requests use a steady interval across batch boundaries',
      () async {
    var now = DateTime(2026);
    final waits = <Duration>[];
    final pacer = QuarkScanPacer(
      now: () => now,
      delay: (duration) async {
        now = now.add(duration);
      },
    );

    const interval = Duration(milliseconds: 725);
    for (var page = 0; page < 12; page++) {
      await pacer.waitForTurn(
        interval: interval,
        onWait: waits.add,
      );
    }
    await pacer.waitForTurn(interval: Duration.zero, onWait: waits.add);

    expect(waits, List.filled(11, interval));
    expect(now, DateTime(2026).add(interval * 11));
  });

  test('TMDB selects a unique exact film match using the folder year',
      () async {
    final movie = _parse('例片 (2019).mkv', [(fid: 'movie', name: '例片 (2019)')]);
    final dio = Dio();
    addTearDown(dio.close);
    final requests = <RequestOptions>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      requests.add(request);
      expect(request.uri.path, '/3/search/movie');
      expect(request.queryParameters['query'], '例片');
      expect(request.queryParameters['primary_release_year'], 2019);
      handler.resolve(Response(requestOptions: request, data: {
        'results': [
          {
            'title': '例片',
            'release_date': '2024-01-01',
            'poster_path': '/wrong.jpg'
          },
          {
            'title': '例片',
            'release_date': '2019-01-01',
            'poster_path': '/right.jpg',
            'overview': '简介'
          },
        ],
      }));
    }));
    final scraper = QuarkMetadataScraper(dio: dio);
    const expected =
        (cover: 'https://image.tmdb.org/t/p/w500/right.jpg', summary: '简介');
    expect(await scraper.lookup(movie, 'test-token'), expected);
    expect(await scraper.lookup(movie, _testTmdbApiKey), expected);
    expect(requests[0].headers['Authorization'], 'Bearer test-token');
    expect(requests[0].queryParameters, isNot(contains('api_key')));
    expect(requests[1].headers, isNot(contains('Authorization')));
    expect(requests[1].queryParameters['api_key'], _testTmdbApiKey);
  });

  test('catalog snapshots persist without creating viewing history rows',
      () async {
    final root = await Directory.systemTemp.createTemp('quark-index-');
    StorageService.debugAppStorageDirectoryOverride = root;
    final history = WatchHistoryDatabase.instance;
    addTearDown(() async {
      await history.close();
      StorageService.debugAppStorageDirectoryOverride = null;
      await root.delete(recursive: true);
    });
    final store = QuarkCatalogStore();
    final item = _parse('例片 (2019).mkv', [(fid: 'movie', name: '例片 (2019)')]);
    await store.save('account-a', 'mount', [item]);
    await store.saveMetadata('film', (checkedAt: 1000, metadata: null));

    final loaded = await QuarkCatalogStore().load('account-a');
    expect(loaded['mount']!.single.toJson(), item.toJson());
    expect(await store.load('account-b'), isEmpty);
    expect((await store.loadMetadata())['film']?.checkedAt, 1000);
    expect(await history.getAllWatchHistory(), isEmpty);
  });

  test('a paged deep scan publishes early, resumes, and restores its index',
      () async {
    final root = await Directory.systemTemp.createTemp('quark-scan-');
    StorageService.debugAppStorageDirectoryOverride = root;
    final history = WatchHistoryDatabase.instance;
    final drive = Dio();
    final metadata = Dio();
    final folder = QuarkMountFolder(
        id: 'mount', fid: '0', name: '电视剧', addedAt: DateTime(2026));
    SharedPreferences.setMockInitialValues({
      'quark_saved_account': jsonEncode({'cookie': '__uid=test; __pus=mock'}),
      'quark_mount_folders': [jsonEncode(folder.toJson())],
      'quark_scan_request_seconds': 3,
    });

    final drivePaths = <String>[];
    final drivePages = <({int directory, int page})>[];
    var interrupted = false;
    drive.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      drivePaths.add(request.uri.path);
      final parent =
          int.tryParse(request.queryParameters['pdir_fid']?.toString() ?? '');
      final page = request.queryParameters['_page'] as int? ?? 1;
      if (parent != null) drivePages.add((directory: parent, page: page));
      if (parent == 7 && page == 2 && !interrupted) {
        interrupted = true;
        handler.reject(DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        ));
        return;
      }
      final List<Map<String, Object>> files;
      if (parent == null) {
        files = [];
      } else if (parent < 7) {
        files = [
          {
            'fid': '${parent + 1}',
            'file': false,
            'file_name': switch (parent) {
              5 => '例剧 (2024)',
              6 => 'Season 02',
              _ => '目录 $parent',
            },
          },
        ];
      } else if (page == 1) {
        files = [
          {
            'fid': interrupted ? 'MediaFID' : 'StaleFID',
            'file': true,
            'file_name': '例剧 - S02E03-1.mkv',
            'size': 1234,
            'updated_at': 1000,
          },
        ];
      } else {
        files = [
          {'fid': 'text', 'file': true, 'file_name': 'readme.txt'}
        ];
      }
      handler.resolve(Response(requestOptions: request, statusCode: 200, data: {
        'status': 200,
        'code': 0,
        'data': parent == null ? <String, dynamic>{} : {'list': files},
        'metadata': {'_total': parent == 7 ? 2 : files.length},
      }));
    }));
    final metadataPaths = <String>[];
    var rejectTmdb = true;
    metadata.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      metadataPaths.add(request.uri.path);
      if (request.uri.path == '/3/search/tv') {
        if (rejectTmdb) {
          handler.reject(DioException.badResponse(
            statusCode: 401,
            requestOptions: request,
            response: Response(requestOptions: request, statusCode: 401),
          ));
        } else {
          handler.resolve(Response(requestOptions: request, data: {
            'results': [
              {
                'name': '例剧',
                'first_air_date': '2024-01-01',
                'poster_path': '/show.jpg',
              },
            ],
          }));
        }
        return;
      }
      handler.resolve(Response(requestOptions: request, statusCode: 200, data: {
        'data': [
          {'name_cn': '例剧', 'date': '2024-01-01', 'summary': '作品简介'},
        ],
      }));
    }));
    var now = DateTime(2026);
    QuarkService createService() => QuarkService.forTesting(
          client: QuarkApiClient(dio: drive),
          metadataScraper: QuarkMetadataScraper(dio: metadata),
          pacer: QuarkScanPacer(
              now: () => now,
              delay: (duration) async {
                now = now.add(duration);
              }),
        );
    final service = createService();
    final restored = createService();
    addTearDown(() async {
      service.dispose();
      restored.dispose();
      drive.close();
      metadata.close();
      await history.close();
      StorageService.debugAppStorageDirectoryOverride = null;
      await root.delete(recursive: true);
    });

    await service.initialize();
    expect(service.autoScanHours, 0);
    expect(service.scanRequestMilliseconds, 3000);
    await service.setScanRequestMilliseconds(725);
    final waitingFolders = <String?>[];
    service.addListener(() {
      if (service.scanningStatus.startsWith('约 725 毫秒后继续请求目录')) {
        waitingFolders.add(service.scanningFolderId);
      }
    });

    final mount = service.mountFolders.single;
    await expectLater(
        service.scanMountFolder(mount), throwsA(isA<DioException>()));
    expect(
        service.indexedHistory.single.filePath, startsWith('quark://StaleFID/'));
    expect(metadataPaths, isEmpty);
    expect(waitingFolders, List.filled(8, folder.id));
    expect(service.scanningFolderId, isNull);
    expect(drivePages, [
      for (var directory = 0; directory <= 7; directory++)
        (directory: directory, page: 1),
      (directory: 7, page: 2),
    ]);

    final beforeRetry = drivePages.length;
    final result = await service.scanMountFolder(service.mountFolders.single);
    expect(drivePages.skip(beforeRetry), [
      (directory: 7, page: 1),
      (directory: 7, page: 2),
    ]);
    final item = service.indexedHistory.single;
    final detail = service.detailForWork(item.animeId)!;
    expect(result['total'], 1);
    expect(item.filePath, startsWith('quark://MediaFID/'));
    expect(detail.episodeList!.single.id, item.episodeId);
    expect(detail.summary, '作品简介');
    expect(
        drivePaths.where(
            (path) => path.contains('/file/') && !path.endsWith('/sort')),
        isEmpty);
    expect(await history.getAllWatchHistory(), isEmpty);

    final beforeRescan = service.catalogRevision.value;
    await service.scanMountFolder(service.mountFolders.single);
    expect(metadataPaths, ['/v0/search/subjects']);
    expect(service.catalogRevision.value, beforeRescan);
    expect(service.indexedHistory.single.lastWatchTime, item.lastWatchTime);
    await service.setAutoScanHours(3);
    await restored.initialize();
    expect(restored.autoScanHours, 3);
    expect(restored.scanRequestMilliseconds, 725);
    expect(restored.indexedHistory.single.filePath, item.filePath);
    expect(restored.detailForWork(item.animeId)?.summary, '作品简介');

    final directoriesBeforeScraping = drivePages.length;
    await service.setTmdbToken(_testTmdbApiKey);
    await service.scrapeMountMetadata(mount);
    final failed = service.metadataProgressFor(mount.id)!;
    expect((failed.total, failed.completed, failed.matched, failed.failed),
        (1, 1, 0, 1));
    expect(failed.error, contains('HTTP 401'));
    expect(failed.error, isNot(contains(_testTmdbApiKey)));

    rejectTmdb = false;
    await service.scrapeMountMetadata(mount);
    final scraped = service.metadataProgressFor(mount.id)!;
    expect((scraped.total, scraped.matched, scraped.unmatched, scraped.failed),
        (1, 1, 0, 0));
    expect(scraped.error, isNull);
    expect(service.detailForWork(item.animeId)?.imageUrl,
        'https://image.tmdb.org/t/p/w500/show.jpg');
    expect(drivePages, hasLength(directoriesBeforeScraping));
    await Future<void>.delayed(Duration.zero);
  });
}
