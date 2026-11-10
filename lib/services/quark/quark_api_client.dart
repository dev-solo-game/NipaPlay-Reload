import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:nipaplay/models/quark/quark_file.dart';
import 'package:nipaplay/models/quark/quark_playback_info.dart';
import 'package:uuid/uuid.dart';

/// 扫码状态返回结果
class QuarkQrCodeStatus {
  final bool isSuccess;
  final bool isWaiting;
  final bool isExpired;
  final String message;
  final String? cookie;
  final String? ticket;

  QuarkQrCodeStatus({
    required this.isSuccess,
    required this.isWaiting,
    required this.isExpired,
    required this.message,
    this.cookie,
    this.ticket,
  });

  factory QuarkQrCodeStatus.waiting([String msg = '请使用手机夸克 App 扫码']) =>
      QuarkQrCodeStatus(
        isSuccess: false,
        isWaiting: true,
        isExpired: false,
        message: msg,
      );

  factory QuarkQrCodeStatus.scanned([String msg = '已扫码，请在手机上点击确认']) =>
      QuarkQrCodeStatus(
        isSuccess: false,
        isWaiting: true,
        isExpired: false,
        message: msg,
      );

  factory QuarkQrCodeStatus.expired([String msg = '二维码已过期，请刷新']) =>
      QuarkQrCodeStatus(
        isSuccess: false,
        isWaiting: false,
        isExpired: true,
        message: msg,
      );

  factory QuarkQrCodeStatus.success(String cookie) => QuarkQrCodeStatus(
        isSuccess: true,
        isWaiting: false,
        isExpired: false,
        message: '登录成功',
        cookie: cookie,
      );

  factory QuarkQrCodeStatus.failed(String msg) => QuarkQrCodeStatus(
        isSuccess: false,
        isWaiting: false,
        isExpired: false,
        message: msg,
      );
}

class QuarkRateLimitException extends StateError {
  QuarkRateLimitException(this.retryAfter) : super('夸克请求过于频繁，扫描已暂停');

  final Duration retryAfter;
}

/// 夸克网盘 API 客户端
class QuarkApiClient {
  static const String baseDriveUrl = 'https://drive.quark.cn/1/clouddrive';
  static const String uopUrl = 'https://uop.quark.cn/cas/ajax';
  static const String panUrl = 'https://pan.quark.cn';
  static const String downloadUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';

  static const Map<String, String> defaultHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Referer': 'https://pan.quark.cn/',
    'Origin': 'https://pan.quark.cn',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'x-client-version': '3.1.0',
    'x-platform-version': 'web',
    'x-platform-type': 'web',
    'x-app-id': '30',
  };

  final Dio _dio;
  final FutureOr<void> Function(String previousCookie, String cookie)?
      _onCookieRefreshed;

  QuarkApiClient({
    Dio? dio,
    FutureOr<void> Function(String previousCookie, String cookie)?
        onCookieRefreshed,
  })  : _onCookieRefreshed = onCookieRefreshed,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 20),
              ),
            );

  /// 1. 获取扫码登录二维码信息
  /// 返回：{'token': '...', 'qrUrl': 'https://su.quark.cn/...'}
  Future<Map<String, dynamic>> getQrCode() async {
    final requestId = const Uuid().v4();
    final response = await _dio.get(
      '$uopUrl/getTokenForQrcodeLogin',
      queryParameters: {
        'client_id': '532',
        'v': '1.2',
        'request_id': requestId,
      },
      options: Options(headers: defaultHeaders),
    );

    final data = response.data;
    if (data is Map && (data['status'] == 2000000 || data['message'] == 'ok')) {
      final members = (data['data'] as Map?)?['members'] as Map?;
      final token = members?['token'] as String? ?? (data['data'] as Map?)?['token'] as String?;
      if (token != null && token.isNotEmpty) {
        // 官方标准 URL 参数拼接：
        // 注意：uc_param_str 必须携带等号 (uc_param_str=)，否则阿里短链网关解析截断将丢失后面的 token 和 client_id
        final encodedBiz = Uri.encodeComponent('S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0');
        final queryStr = 'token=$token&client_id=532&ssb=weblogin&uc_param_str=&uc_biz_str=$encodedBiz';
        final qrUrl = 'https://su.quark.cn/4_eMHBJ?$queryStr';
        final directUrl = 'https://b.quark.cn/apps/DuJrlezmS/routes/EATJRLSvv?$queryStr';

        return {
          'token': token,
          'qrUrl': qrUrl,
          'directUrl': directUrl,
          'expiresIn': 300,
        };
      }
    }
    throw StateError('获取夸克二维码失败: ${response.data}');
  }

  /// 2. 轮询二维码扫码状态
  Future<QuarkQrCodeStatus> pollQrCode(String token) async {
    final requestId = const Uuid().v4();
    final response = await _dio.get(
      '$uopUrl/getServiceTicketByQrcodeToken',
      queryParameters: {
        'client_id': '532',
        'v': '1.2',
        'token': token,
        'request_id': requestId,
      },
      options: Options(headers: defaultHeaders),
    );

    final data = response.data;
    if (data is! Map) {
      return QuarkQrCodeStatus.failed('响应格式错误');
    }

    final status = data['status'];
    final message = (data['message'] ?? '').toString();

    // 成功换取 service_ticket
    if ((status == 2000000 || status == 200) && (message == 'ok' || message.isEmpty)) {
      final members = (data['data'] as Map?)?['members'] as Map?;
      final serviceTicket = members?['service_ticket'] as String? ??
          (data['data'] as Map?)?['ticket'] as String?;
      if (serviceTicket != null && serviceTicket.isNotEmpty) {
        final cookie = await _exchangeTicketForCookie(serviceTicket);
        if (cookie.isNotEmpty) {
          return QuarkQrCodeStatus.success(cookie);
        }
      }
    }

    // 官方状态 50004001: 等待扫码中
    if (status == 50004001 || status == 40001) {
      return QuarkQrCodeStatus.waiting('请使用手机夸克 App 扫描二维码');
    }

    // 已扫码待确认
    if (status == 40002 || message.contains('scanned') || message.contains('已扫码')) {
      return QuarkQrCodeStatus.scanned('已扫码，请在手机上点击确认');
    }

    // 官方状态 50004002: 二维码已过期
    if (status == 50004002 ||
        message.contains('expired') ||
        message.contains('timeout') ||
        message.contains('过期')) {
      return QuarkQrCodeStatus.expired('二维码已失效，点击刷新');
    }

    return QuarkQrCodeStatus.waiting('请使用手机夸克 App 扫描二维码');
  }

  /// 使用 ticket 换取并拼接 Cookie
  Future<String> _exchangeTicketForCookie(String ticket) async {
    final Map<String, String> cookieMap = {};

    void extractCookies(List<String> rawHeaders) {
      for (final raw in rawHeaders) {
        final parts = raw.split(';');
        if (parts.isNotEmpty) {
          final pair = parts[0].trim();
          final eqIdx = pair.indexOf('=');
          if (eqIdx > 0) {
            final key = pair.substring(0, eqIdx).trim();
            final val = pair.substring(eqIdx + 1).trim();
            cookieMap[key] = val;
          }
        }
      }
    }

    // 1. 请求 account/info 获取 Cookie
    try {
      final infoResponse = await _dio.get(
        '$panUrl/account/info',
        queryParameters: {'st': ticket, 'lw': 'scan'},
        options: Options(
          headers: defaultHeaders,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      extractCookies(infoResponse.headers['set-cookie'] ?? []);
    } catch (e) {
      debugPrint('account/info 换取 Cookie 失败: $e');
    }

    // 2. 备用请求 account/login 获取 Cookie
    try {
      final loginResponse = await _dio.get(
        '$panUrl/account/login',
        queryParameters: {'ticket': ticket},
        options: Options(
          headers: defaultHeaders,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      extractCookies(loginResponse.headers['set-cookie'] ?? []);
    } catch (e) {
      debugPrint('account/login 换取 Cookie 失败: $e');
    }

    return cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 3. 获取用户基本信息及网盘空间
  Future<Map<String, dynamic>> getAccountInfo(String cookie) async {
    final response = await _dio.get(
      '$panUrl/account/info',
      options: Options(
        headers: {
          ...defaultHeaders,
          'Cookie': cookie,
        },
      ),
    );

    final data = response.data;
    if (data is Map && data['status'] == 200) {
      final accountData = data['data'] as Map<String, dynamic>? ?? {};
      return accountData;
    }
    final message = data is Map ? data['message'] : null;
    throw StateError('获取账号信息失败: ${message ?? '未知错误'}');
  }

  /// 按 OpenList 夸克驱动的约定验证网盘会话。
  Future<String> validateSession(String cookie) async {
    var verifiedCookie = cookie;
    await _requestDrive(
      '/config',
      cookie: cookie,
      onCookieRefreshed: (_, refreshed) => verifiedCookie = refreshed,
    );
    return verifiedCookie;
  }

  Future<Map<String, dynamic>> getMemberInfo(String cookie) async {
    final data = await _requestDrive(
      '/member',
      cookie: cookie,
      queryParameters: {
        'fetch_subscribe': 'false',
        '_ch': 'home',
        'fetch_identity': 'false',
      },
    );
    return data['data'] as Map<String, dynamic>? ?? {};
  }

  /// 列出目录下的文件与文件夹
  Future<Map<String, dynamic>> listFiles({
    required String cookie,
    String pdirFid = '0',
    int page = 1,
    int size = 100,
    String? sort,
  }) async {
    final data = await _requestDrive(
      '/file/sort',
      cookie: cookie,
      queryParameters: {
        'pdir_fid': pdirFid,
        '_page': page,
        '_size': size,
        '_fetch_total': 1,
        'fetch_all_file': 1,
        'fetch_risk_file_name': 1,
        if (sort != null) '_sort': sort,
      },
    );

    final innerData = data['data'] as Map<String, dynamic>? ?? {};
    final list = innerData['list'] as List? ?? [];
    final metadata = data['metadata'] as Map?;
    return {
      'total': metadata?['_total'] as int? ??
          innerData['total'] as int? ??
          list.length,
      'files': list
          .whereType<Map<String, dynamic>>()
          .map(QuarkFile.fromJson)
          .toList(),
    };
  }

  /// 5. 递归或层级搜索文件
  Future<List<QuarkFile>> searchFiles({
    required String cookie,
    required String keyword,
    int page = 1,
    int size = 50,
  }) async {
    final response = await _dio.get(
      '$baseDriveUrl/file/search',
      queryParameters: {
        'q': keyword,
        '_page': page,
        '_size': size,
        '_fetch_total': 1,
        '_sort': 'file_type:desc,updated_at:desc',
        '_is_hl': 1,
        'pr': 'ucpro',
        'fr': 'pc',
      },
      options: Options(
        headers: {
          'Cookie': cookie,
        },
      ),
    );

    final data = response.data;
    if (data is Map && data['status'] == 200) {
      final list = (data['data'] as Map?)?['list'] as List? ?? [];
      return list
          .whereType<Map<String, dynamic>>()
          .map((item) => QuarkFile.fromJson(item))
          .toList();
    }
    return [];
  }

  Future<QuarkPlaybackInfo> getPlaybackInfo({
    required String cookie,
    required String fid,
  }) async {
    String? videoAuthCookie;
    final response = await _requestDrive(
      '/file/v2/play',
      cookie: cookie,
      method: 'POST',
      userAgent: downloadUserAgent,
      body: {
        'fid': fid,
        'resolutions': 'low,normal,high,super,2k,4k',
        'supports': 'fmp4_av,m3u8,dolby_vision',
      },
      onResponseHeaders: (headers) {
        const prefix = 'Video-Auth=';
        for (final header in headers['set-cookie'] ?? const <String>[]) {
          final pair = header.split(';').first.trim();
          if (pair.startsWith(prefix) && pair.length > prefix.length) {
            videoAuthCookie = pair;
            break;
          }
        }
      },
    );
    final data = response['data'] as Map?;
    final variants = <String, QuarkVideoVariant>{};
    for (final item in (data?['video_list'] as List? ?? []).whereType<Map>()) {
      final info = item['video_info'];
      if (item['accessable'] == false || info is! Map) continue;
      final resolution = item['resolution'];
      final url = Uri.tryParse(info['url']?.toString() ?? '');
      if (resolution is! String ||
          resolution.isEmpty ||
          url == null ||
          url.scheme != 'https' ||
          url.host.isEmpty) {
        continue;
      }
      variants[resolution] = QuarkVideoVariant(
        resolution: resolution,
        url: url,
        height: int.tryParse('${info['height']}'),
      );
    }
    return QuarkPlaybackInfo(
      variants: List.unmodifiable(variants.values),
      defaultResolution: data?['default_resolution'] as String?,
      videoAuthCookie: videoAuthCookie,
    );
  }

  /// 6. 获取文件临时下载直链
  Future<String> getDownloadUrl({
    required String cookie,
    required String fid,
  }) async {
    final data = await _requestDrive(
      '/file/download',
      cookie: cookie,
      method: 'POST',
      userAgent: downloadUserAgent,
      body: {
        'fids': [fid],
      },
    );

    final list = data['data'] as List? ?? [];
    if (list.isNotEmpty && list.first is Map) {
      final url = list.first['download_url'] as String?;
      if (url != null && url.isNotEmpty) return url;
    }
    throw StateError('夸克网盘未返回下载链接');
  }

  Future<Map<String, dynamic>> _requestDrive(
    String path, {
    required String cookie,
    String method = 'GET',
    Map<String, dynamic> queryParameters = const {},
    Map<String, dynamic>? body,
    String? userAgent,
    FutureOr<void> Function(String, String)? onCookieRefreshed,
    void Function(Headers)? onResponseHeaders,
  }) async {
    final response = await _dio.request<dynamic>(
      '$baseDriveUrl$path',
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        ...queryParameters,
      },
      data: body,
      options: Options(
        method: method,
        validateStatus: (status) => status != null,
        headers: {
          'Cookie': cookie,
          'Referer': panUrl,
          'Accept': 'application/json, text/plain, */*',
          if (userAgent != null) 'User-Agent': userAgent,
        },
      ),
    );

    final refresh = onCookieRefreshed ?? _onCookieRefreshed;
    if (refresh != null) {
      final refreshed = _refreshDriveCookie(cookie, response.headers);
      if (refreshed != cookie) await refresh(cookie, refreshed);
    }

    final data = response.data;
    final httpStatus = response.statusCode ?? 0;
    final code = data is Map ? data['code'] : null;
    final status = data is Map ? data['status'] : null;
    if (httpStatus == 429 || status == 429) {
      final seconds = int.tryParse(response.headers.value('retry-after') ?? '');
      throw QuarkRateLimitException(Duration(seconds: seconds == null || seconds < 60 ? 60 : seconds));
    }
    if (httpStatus == 401 || status == 401 || code == 41001 || code == 41002) {
      throw StateError('夸克登录状态已过期，请重新登录');
    }
    if (data is! Map<String, dynamic> ||
        httpStatus < 200 ||
        httpStatus >= 300 ||
        (status is int && status >= 400) ||
        (code != null && code != 0)) {
      final message = data is Map ? data['message'] : null;
      throw StateError('夸克网盘请求失败 ($path, HTTP $httpStatus)：${message ?? '未知错误'}');
    }
    onResponseHeaders?.call(response.headers);
    return data;
  }

  String _refreshDriveCookie(String cookie, Headers headers) {
    const prefix = '__puus=';
    for (final header in headers['set-cookie'] ?? const <String>[]) {
      final pair = header.split(';').first.trim();
      if (!pair.startsWith(prefix) || pair.length == prefix.length) continue;

      final existing = cookie.split(';').map((part) => part.trim());
      if (existing.contains(pair)) return cookie;
      return [
        ...existing.where((part) => part.isNotEmpty && !part.startsWith(prefix)),
        pair,
      ].join('; ');
    }
    return cookie;
  }
}
