import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:nipaplay/services/quark/quark_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

/// 夸克网盘本地流媒体代理服务
///
/// 解决播放器内核对跨域、直链动态刷新、自定义 Header 及 Range 206 请求的需求。
/// 播放器请求本地回环地址: http://127.0.0.1:port/quark/stream?fid=xxx
class QuarkProxyService {
  static const String _portKey = 'quark_proxy_port';
  static const int _defaultPort = 33223;
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  QuarkProxyService._();
  static final QuarkProxyService instance = QuarkProxyService._();

  HttpServer? _server;
  int _port = 0;
  bool _isRunning = false;

  bool get isRunning => _isRunning;
  int get port => _port;

  Future<void>? _initializing;

  Future<void> initialize() async {
    if (_isRunning || kIsWeb) return;
    final pending = _initializing ??= _initialize();
    try {
      await pending;
    } finally {
      if (identical(_initializing, pending)) _initializing = null;
    }
  }

  Future<void> _initialize() async {
    if (_isRunning) return;

    final router = Router()
      ..add('HEAD', '/quark/stream', _handleStreamHead)
      ..add('GET', '/quark/stream', _handleStream)
      ..get('/quark/health', (Request request) => Response.ok('ok'));

    final handler = const Pipeline().addHandler(router.call);

    final prefs = await SharedPreferences.getInstance();
    final savedPort = prefs.getInt(_portKey);

    final portsToTry = <int>[];
    if (savedPort != null) portsToTry.add(savedPort);
    portsToTry.add(_defaultPort);
    portsToTry.add(0); // 随机可用端口

    Object? lastError;
    for (final candidatePort in portsToTry) {
      try {
        _server = await shelf_io.serve(
          handler,
          InternetAddress.loopbackIPv4,
          candidatePort,
        );
        _port = _server!.port;
        _isRunning = true;
        try {
          await prefs.setInt(_portKey, _port);
        } catch (_) {}
        debugPrint('QuarkProxyService running on port $_port');
        return;
      } catch (e) {
        lastError = e;
      }
    }

    throw StateError('QuarkProxyService 启动失败: $lastError');
  }

  Future<void> stop() async {
    await _initializing;
    await _server?.close(force: true);
    _server = null;
    _port = 0;
    _isRunning = false;
  }

  /// 为指定 fid 构造本地播放代理 URL
  String buildStreamUrl(String fid, {String? fileName}) {
    final resolvedPort = _port > 0 ? _port : _defaultPort;
    final query = <String, String>{'fid': fid};
    if (fileName != null && fileName.isNotEmpty) {
      query['name'] = fileName;
    }

    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: resolvedPort,
      path: '/quark/stream',
      queryParameters: query,
    ).toString();
  }

  Future<Response> _handleStream(Request request) {
    return _handleStreamInternal(request, headOnly: false);
  }

  Future<Response> _handleStreamHead(Request request) {
    return _handleStreamInternal(request, headOnly: true);
  }

  Future<Response> _handleStreamInternal(
    Request request, {
    required bool headOnly,
  }) async {
    final fid = request.url.queryParameters['fid']?.trim();
    if (fid == null || fid.isEmpty) {
      return Response(HttpStatus.badRequest, body: 'Missing fid parameter');
    }

    final rangeHeader = request.headers['range'];
    final method = headOnly ? 'HEAD' : 'GET';

    // 尝试获取或刷新直链（最多重试2次）
    String? currentUrl;
    for (int attempt = 1; attempt <= 2; attempt++) {
      try {
        currentUrl = await QuarkService.instance.getDownloadUrl(
          fid,
          forceRefresh: attempt > 1,
        );
      } catch (e) {
        debugPrint('QuarkProxy: 获取下载直链失败 (attempt $attempt): $e');
        if (attempt == 2) {
          return Response(HttpStatus.internalServerError,
              body: 'Failed to fetch download url: $e');
        }
      }

      if (currentUrl == null) continue;

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..autoUncompress = false;

      var handedToStream = false;
      try {
        final targetUri = Uri.parse(currentUrl);
        final upstreamReq = await client.openUrl(method, targetUri);
        upstreamReq.followRedirects = true;
        upstreamReq.headers.set(HttpHeaders.userAgentHeader, _defaultUserAgent);
        upstreamReq.headers.set(HttpHeaders.acceptHeader, '*/*');
        if (rangeHeader != null) {
          upstreamReq.headers.set(HttpHeaders.rangeHeader, rangeHeader);
        }

        final upstreamResp =
            await upstreamReq.close().timeout(const Duration(seconds: 30));

        // 如果鉴权失败或直链已失效，且是第一次尝试，则强制刷新直链重试
        if ((upstreamResp.statusCode == HttpStatus.forbidden ||
                upstreamResp.statusCode == HttpStatus.unauthorized ||
                upstreamResp.statusCode == HttpStatus.gone) &&
            attempt == 1) {
          client.close(force: true);
          continue;
        }

        final responseHeaders = <String, String>{
          'Accept-Ranges': 'bytes',
          'Access-Control-Allow-Origin': '*',
        };

        void passHeader(String name) {
          final val = upstreamResp.headers.value(name);
          if (val != null) responseHeaders[name] = val;
        }

        passHeader('Content-Type');
        passHeader('Content-Length');
        passHeader('Content-Range');
        passHeader('ETag');
        passHeader('Last-Modified');

        if (headOnly) {
          return Response(upstreamResp.statusCode, headers: responseHeaders);
        }

        handedToStream = true;
        return Response(
          upstreamResp.statusCode,
          headers: responseHeaders,
          body: _bindClientToStream(upstreamResp, client),
        );
      } catch (e) {
        if (!handedToStream) {
          client.close(force: true);
        }
        if (attempt == 2) {
          return Response(HttpStatus.badGateway, body: 'Upstream error: $e');
        }
      }
    }

    return Response(HttpStatus.badGateway, body: 'Failed to proxy media stream');
  }

  Stream<List<int>> _bindClientToStream(
    HttpClientResponse response,
    HttpClient client,
  ) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;

    void cleanup() {
      subscription?.cancel();
      subscription = null;
      client.close(force: true);
    }

    controller = StreamController<List<int>>(
      onListen: () {
        subscription = response.listen(
          controller.add,
          onError: (error, stack) {
            controller.addError(error, stack);
            cleanup();
            controller.close();
          },
          onDone: () {
            cleanup();
            controller.close();
          },
          cancelOnError: true,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        cleanup();
      },
    );

    return controller.stream;
  }
}
