import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nipaplay/services/quark/quark_api_client.dart';
import 'package:nipaplay/services/quark/quark_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

class _QuarkHlsSession {
  _QuarkHlsSession(this.generation, this.cookie);

  final int generation;
  final String cookie;
  final resources = <Uri>[];
  final _indices = <Uri, int>{};

  int indexOf(Uri uri) => _indices.putIfAbsent(uri, () {
        resources.add(uri);
        return resources.length - 1;
      });
}

@visibleForTesting
String rewriteQuarkHlsPlaylist(
  String playlist,
  Uri upstream,
  String Function(Uri) proxyUrl,
) {
  final uriAttribute = RegExp(r'\bURI="([^"]+)"');
  final lines = const LineSplitter().convert(playlist).map((line) {
    final value = line.trim();
    if (value.isEmpty) return line;
    if (!value.startsWith('#')) return proxyUrl(upstream.resolve(value));
    return line.replaceAllMapped(uriAttribute, (match) {
      return 'URI="${proxyUrl(upstream.resolve(match[1]!))}"';
    });
  });
  return '${lines.join('\n')}\n';
}

/// 夸克网盘本地流媒体代理服务
///
/// 解决播放器内核对跨域、直链动态刷新、自定义 Header 及 Range 206 请求的需求。
/// 播放器请求本地回环地址: http://127.0.0.1:port/quark/stream?fid=xxx
class QuarkProxyService {
  static const String _portKey = 'quark_proxy_port';
  static const int _defaultPort = 33223;
  QuarkProxyService._();
  static final QuarkProxyService instance = QuarkProxyService._();

  HttpServer? _server;
  int _port = 0;
  bool _isRunning = false;
  final _hlsSessions = <String, _QuarkHlsSession>{};

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
      ..add('HEAD', '/quark/hls/<session>/<resource>', _handleHlsResource)
      ..add('GET', '/quark/hls/<session>/<resource>', _handleHlsResource)
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
    _hlsSessions.clear();
  }

  /// 为指定 fid 构造本地播放代理 URL
  String buildStreamUrl(String fid, {String? fileName, String? resolution}) {
    final resolvedPort = _port > 0 ? _port : _defaultPort;
    final query = <String, String>{
      'fid': fid,
      if (resolution != null) 'resolution': resolution,
    };
    if (fileName != null && fileName.isNotEmpty) {
      query['file'] = fileName;
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

    final resolution = request.url.queryParameters['resolution'];
    final service = QuarkService.instance;
    final generation = service.sessionGeneration;

    for (int attempt = 1; attempt <= 2; attempt++) {
      if (generation != service.sessionGeneration) break;
      final ({String url, String cookie}) link;
      try {
        link = await service.getPlaybackLink(
          fid,
          resolution: resolution,
          forceRefresh: attempt > 1,
        );
      } catch (e) {
        debugPrint('QuarkProxy: 获取播放地址失败: ${e.runtimeType}');
        return Response(HttpStatus.badGateway,
            body: 'Failed to fetch playback URL');
      }
      try {
        final response = await _proxyUpstream(
          request,
          Uri.parse(link.url),
          _QuarkHlsSession(generation, link.cookie),
          headOnly: headOnly,
          refreshOnExpiry: attempt == 1,
        );
        if (response != null) return response;
      } catch (_) {
        if (attempt == 2) break;
      }
    }

    return Response(HttpStatus.badGateway,
        body: 'Failed to proxy media stream');
  }

  Future<Response> _handleHlsResource(
    Request request,
    String sessionId,
    String resource,
  ) async {
    final session = _hlsSessions[sessionId];
    final index = int.tryParse(resource.split('.').first);
    if (session == null ||
        session.generation != QuarkService.instance.sessionGeneration ||
        index == null ||
        index < 0 ||
        index >= session.resources.length) {
      return Response.notFound('Unknown HLS resource');
    }
    _hlsSessions.remove(sessionId);
    _hlsSessions[sessionId] = session;
    try {
      return (await _proxyUpstream(
        request,
        session.resources[index],
        session,
        headOnly: request.method == 'HEAD',
        sessionId: sessionId,
      ))!;
    } catch (_) {
      return Response(HttpStatus.badGateway, body: 'HLS request failed');
    }
  }

  static bool _isQuarkHttps(Uri uri) =>
      uri.scheme == 'https' &&
      (uri.host == 'quark.cn' || uri.host.endsWith('.quark.cn'));

  Future<Response?> _proxyUpstream(
    Request request,
    Uri target,
    _QuarkHlsSession session, {
    required bool headOnly,
    bool refreshOnExpiry = false,
    String? sessionId,
    bool forwardRange = true,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = false;
    var handedToStream = false;
    try {
      final upstream = await client.openUrl(headOnly ? 'HEAD' : 'GET', target);
      upstream.headers
          .set(HttpHeaders.userAgentHeader, QuarkApiClient.downloadUserAgent);
      upstream.headers.set(HttpHeaders.refererHeader, QuarkApiClient.panUrl);
      upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      upstream.headers.set(HttpHeaders.acceptHeader, '*/*');
      if (_isQuarkHttps(target)) {
        upstream.headers.set(HttpHeaders.cookieHeader, session.cookie);
      }
      final range = request.headers['range'];
      if (forwardRange && range != null) {
        upstream.headers.set(HttpHeaders.rangeHeader, range);
      }

      final response =
          await upstream.close().timeout(const Duration(seconds: 30));
      final status = response.statusCode;
      if (refreshOnExpiry &&
          (status == HttpStatus.forbidden ||
              status == HttpStatus.unauthorized ||
              status == HttpStatus.gone)) {
        return null;
      }

      final effectiveUri = response.redirects.fold(
        target,
        (uri, redirect) => uri.resolveUri(redirect.location),
      );
      final isPlaylist = (status == HttpStatus.ok ||
              status == HttpStatus.partialContent) &&
          (response.headers.contentType?.mimeType.contains('mpegurl') == true ||
              effectiveUri.path.toLowerCase().endsWith('.m3u8'));
      if (isPlaylist) {
        if (!headOnly && status == HttpStatus.partialContent) {
          if (!forwardRange || range == null) {
            throw const FormatException('Incomplete HLS playlist');
          }
          client.close(force: true);
          return await _proxyUpstream(
            request,
            target,
            session,
            headOnly: false,
            refreshOnExpiry: refreshOnExpiry,
            sessionId: sessionId,
            forwardRange: false,
          );
        }
        return await _proxyPlaylist(
          response,
          effectiveUri,
          session,
          sessionId,
          headOnly,
        );
      }

      final responseHeaders = <String, String>{
        'Accept-Ranges': 'bytes',
        'Access-Control-Allow-Origin': '*',
      };
      for (final name in [
        'Content-Type',
        'Content-Length',
        'Content-Range',
        'ETag',
        'Last-Modified'
      ]) {
        final value = response.headers.value(name);
        if (value != null) responseHeaders[name] = value;
      }
      if (headOnly) return Response(status, headers: responseHeaders);

      handedToStream = true;
      return Response(status,
          headers: responseHeaders,
          body: _bindClientToStream(response, client));
    } finally {
      if (!handedToStream) client.close(force: true);
    }
  }

  Future<Response> _proxyPlaylist(
    HttpClientResponse response,
    Uri upstream,
    _QuarkHlsSession session,
    String? sessionId,
    bool headOnly,
  ) async {
    const headers = {
      'Content-Type': 'application/vnd.apple.mpegurl',
      'Access-Control-Allow-Origin': '*',
    };
    if (headOnly) return Response.ok(null, headers: headers);

    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes.add(chunk);
      if (bytes.length > 4 * 1024 * 1024) {
        throw const FormatException('HLS playlist exceeds size limit');
      }
    }
    final playlist = utf8.decode(bytes.takeBytes());
    final id = sessionId ?? const Uuid().v4();
    final content = rewriteQuarkHlsPlaylist(playlist, upstream, (uri) {
      if (!_isQuarkHttps(uri)) {
        throw const FormatException('Unexpected HLS resource origin');
      }
      final extension =
          RegExp(r'\.[a-zA-Z0-9]{1,8}$').stringMatch(uri.path) ?? '';
      return '/quark/hls/$id/${session.indexOf(uri)}$extension';
    });
    if (sessionId == null) {
      if (_hlsSessions.length >= 16) {
        _hlsSessions.remove(_hlsSessions.keys.first);
      }
      _hlsSessions[id] = session;
    }
    return Response.ok(content, headers: headers);
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
