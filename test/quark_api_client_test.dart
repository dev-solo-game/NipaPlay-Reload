import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/models/quark/quark_file.dart';
import 'package:nipaplay/services/quark/quark_api_client.dart';
import 'package:nipaplay/utils/media_source_utils.dart';

class _ResponseAdapter implements HttpClientAdapter {
  _ResponseAdapter(this.body, {this.statusCode = 200, this.cookies = const []});

  final Object body;
  final int statusCode;
  final List<String> cookies;
  late RequestOptions request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        'set-cookie': cookies,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const cookie = '__pus=test-session';
  late Dio dio;
  late QuarkApiClient client;

  setUp(() {
    dio = Dio();
    client = QuarkApiClient(dio: dio);
  });

  tearDown(() => dio.close());

  test('the proxy URL exposes the original filename to media probing', () {
    const fileName = '第01集 100%.mkv';
    final path = MediaSourceUtils.buildQuarkPath('video', fileName);
    final url = MediaSourceUtils.resolveQuarkPathToUrl(path)!;
    final uri = Uri.parse(url);

    expect(uri.path, '/quark/stream');
    expect(uri.queryParameters['file'], fileName);
    expect(MediaSourceUtils.parseQuarkPath(url),
        (fid: 'video', fileName: fileName));
    final legacyUrl = uri.replace(queryParameters: {
      'fid': 'video',
      'name': fileName,
    }).toString();
    expect(MediaSourceUtils.parseQuarkPath(legacyUrl),
        (fid: 'video', fileName: fileName));
  });

  test('sends a GET query to list the root and decodes files and folders',
      () async {
    final adapter = _ResponseAdapter({
      'status': 200,
      'code': 0,
      'metadata': {'_total': 120},
      'data': {
        'list': [
          {
            'fid': 'folder',
            'file_name': '动画',
            'file': false,
            'format_type': ''
          },
          {
            'fid': 'video',
            'file_name': '第01话.mp4',
            'file': true,
            'format_type': 'video/mp4',
          },
        ],
      },
    });
    dio.httpClientAdapter = adapter;

    final result = await client.listFiles(cookie: cookie);

    expect(adapter.request.method, 'GET');
    expect(adapter.request.uri.host, 'drive.quark.cn');
    expect(adapter.request.uri.path, '/1/clouddrive/file/sort');
    expect(adapter.request.uri.queryParameters, {
      'pr': 'ucpro',
      'fr': 'pc',
      'pdir_fid': '0',
      '_page': '1',
      '_size': '100',
      '_fetch_total': '1',
      'fetch_all_file': '1',
      'fetch_risk_file_name': '1',
    });
    expect(adapter.request.headers['cookie'], cookie);
    expect(adapter.request.headers['referer'], 'https://pan.quark.cn');
    expect(adapter.request.data, isNull);
    expect(result['total'], 120);
    final files = result['files'] as List<QuarkFile>;
    expect(files.map((file) => file.fid), ['folder', 'video']);
    expect(files.first.isDir, isTrue);
    expect(files.last.isVideo, isTrue);
    expect(files.last.formatType, 'video/mp4');
  });

  test('requests a later page and accepts the legacy list response', () async {
    final adapter = _ResponseAdapter({
      'status': 200,
      'data': {
        'total': 51,
        'list': [
          {'fid': 'child', 'file_name': '子目录', 'format_type': 1},
        ],
      },
    });
    dio.httpClientAdapter = adapter;

    final result = await client.listFiles(
      cookie: cookie,
      pdirFid: 'folder',
      page: 2,
      size: 50,
    );

    final query = adapter.request.uri.queryParameters;
    expect(query['pdir_fid'], 'folder');
    expect(query['_page'], '2');
    expect(query['_size'], '50');
    expect(result['total'], 51);
    expect((result['files'] as List<QuarkFile>).single.isDir, isTrue);
  });

  test('reports an expired session when the directory API returns 401',
      () async {
    dio.httpClientAdapter = _ResponseAdapter({}, statusCode: 401);

    await expectLater(
      client.listFiles(cookie: cookie),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('夸克登录状态已过期，请重新登录'),
      )),
    );
  });

  test('reports a directory rate limit with a conservative retry delay',
      () async {
    dio.httpClientAdapter = _ResponseAdapter({}, statusCode: 429);
    await expectLater(
      client.listFiles(cookie: cookie),
      throwsA(isA<QuarkRateLimitException>().having(
        (error) => error.retryAfter,
        'retryAfter',
        const Duration(minutes: 1),
      )),
    );
  });

  test('validates the cookie against config and merges the refreshed token',
      () async {
    final adapter = _ResponseAdapter(
      {'status': 200, 'code': 0},
      cookies: ['__pus=ignored; Path=/', '__puus=fresh; Path=/; Secure'],
    );
    dio.httpClientAdapter = adapter;

    final verified = await client.validateSession('$cookie; __puus=old');

    expect(adapter.request.method, 'GET');
    expect(adapter.request.uri.path, '/1/clouddrive/config');
    expect(adapter.request.uri.queryParameters, {'pr': 'ucpro', 'fr': 'pc'});
    expect(adapter.request.headers['cookie'], '$cookie; __puus=old');
    expect(verified, '$cookie; __puus=fresh');
  });

  test('gets capacity from the member endpoint with the driver query',
      () async {
    final adapter = _ResponseAdapter({
      'status': 200,
      'code': 0,
      'data': {'total_capacity': 5000, 'use_capacity': 1000},
    });
    dio.httpClientAdapter = adapter;

    final data = await client.getMemberInfo(cookie);

    expect(adapter.request.method, 'GET');
    expect(adapter.request.uri.path, '/1/clouddrive/member');
    expect(adapter.request.uri.queryParameters, {
      'pr': 'ucpro',
      'fr': 'pc',
      'fetch_subscribe': 'false',
      '_ch': 'home',
      'fetch_identity': 'false',
    });
    expect(data['total_capacity'], 5000);
    expect(data['use_capacity'], 1000);
  });

  test('uses the desktop client for download and publishes token updates',
      () async {
    const downloadUrl = 'https://dl.pds.quark.cn/video';
    final adapter = _ResponseAdapter(
      {
        'status': 200,
        'code': 0,
        'data': [
          {'download_url': downloadUrl},
        ],
      },
      cookies: ['__puus=fresh; Path=/; Secure'],
    );
    dio.httpClientAdapter = adapter;
    final updates = <(String, String)>[];
    client = QuarkApiClient(
      dio: dio,
      onCookieRefreshed: (previous, current) =>
          updates.add((previous, current)),
    );

    final url = await client.getDownloadUrl(cookie: cookie, fid: 'video');

    expect(adapter.request.method, 'POST');
    expect(adapter.request.uri.path, '/1/clouddrive/file/download');
    expect(adapter.request.uri.queryParameters, {'pr': 'ucpro', 'fr': 'pc'});
    expect(
        adapter.request.headers['user-agent'], contains('quark-cloud-drive/'));
    expect(adapter.request.data, {
      'fids': ['video']
    });
    expect(url, downloadUrl);
    expect(updates, [(cookie, '$cookie; __puus=fresh')]);
  });
}
