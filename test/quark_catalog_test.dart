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

    for (var page = 0; page < 12; page++) {
      await pacer.waitForTurn(
        interval: const Duration(seconds: 3),
        onWait: waits.add,
      );
    }

    expect(waits, List.filled(11, const Duration(seconds: 3)));
    expect(now, DateTime(2026).add(const Duration(seconds: 33)));
  });

  test('TMDB selects a unique exact film match using the folder year',
      () async {
    final movie = _parse('例片 (2019).mkv', [(fid: 'movie', name: '例片 (2019)')]);
    final dio = Dio();
    addTearDown(dio.close);
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
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
    final found =
        await QuarkMetadataScraper(dio: dio).lookup(movie, 'test-token');
    expect(found,
        (cover: 'https://image.tmdb.org/t/p/w500/right.jpg', summary: '简介'));
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

  test('a deep scan uses directory pages only and restores its playable index',
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
    });

    final drivePaths = <String>[];
    drive.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      drivePaths.add(request.uri.path);
      final parent =
          int.tryParse(request.queryParameters['pdir_fid']?.toString() ?? '');
      final files = parent == null
          ? const []
          : parent < 7
              ? [
                  {
                    'fid': '${parent + 1}',
                    'file': false,
                    'file_name': switch (parent) {
                      5 => '例剧 (2024)',
                      6 => 'Season 02',
                      _ => '目录 $parent',
                    },
                  },
                ]
              : [
                  {
                    'fid': 'MediaFID',
                    'file': true,
                    'file_name': '例剧 - S02E03-1.mkv',
                    'size': 1234,
                    'updated_at': 1000,
                  },
                ];
      handler.resolve(Response(requestOptions: request, statusCode: 200, data: {
        'status': 200,
        'code': 0,
        'data': parent == null ? <String, dynamic>{} : {'list': files},
        'metadata': {'_total': files.length},
      }));
    }));
    final metadataPaths = <String>[];
    metadata.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      metadataPaths.add(request.uri.path);
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
    expect(service.scanRequestSeconds, 5);
    await service.setScanRequestSeconds(3);
    final waitingFolders = <String?>[];
    service.addListener(() {
      if (service.scanningStatus.startsWith('约 3 秒后继续请求目录')) {
        waitingFolders.add(service.scanningFolderId);
      }
    });
    final result = await service.scanMountFolder(service.mountFolders.single);
    final item = service.indexedHistory.single;
    final detail = service.detailForWork(item.animeId)!;
    expect(result['total'], 1);
    expect(item.filePath, startsWith('quark://MediaFID/'));
    expect(detail.episodeList!.single.id, item.episodeId);
    expect(detail.summary, '作品简介');
    expect(
        drivePaths.where((path) => path.endsWith('/file/sort')), hasLength(8));
    expect(waitingFolders, List.filled(7, folder.id));
    expect(service.scanningFolderId, isNull);
    expect(
        drivePaths.where(
            (path) => path.contains('/file/') && !path.endsWith('/sort')),
        isEmpty);
    expect(await history.getAllWatchHistory(), isEmpty);

    await service.scanMountFolder(service.mountFolders.single);
    expect(metadataPaths, ['/v0/search/subjects']);
    expect(service.indexedHistory.single.lastWatchTime, item.lastWatchTime);
    await service.setAutoScanHours(3);
    await restored.initialize();
    expect(restored.autoScanHours, 3);
    expect(restored.scanRequestSeconds, 3);
    expect(restored.indexedHistory.single.filePath, item.filePath);
    expect(restored.detailForWork(item.animeId)?.summary, '作品简介');
    await Future<void>.delayed(Duration.zero);
  });
}
