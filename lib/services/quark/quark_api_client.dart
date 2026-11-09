import 'dart:async';
import 'package:dio/dio.dart';
import 'package:nipaplay/models/quark/quark_file.dart';
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

/// 夸克网盘 API 客户端
class QuarkApiClient {
  static const String baseDriveUrl = 'https://drive-pc.quark.cn/1/clouddrive';
  static const String uopUrl = 'https://uop.quark.cn/cas/ajax';
  static const String panUrl = 'https://pan.quark.cn';

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

  QuarkApiClient({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 20),
                headers: defaultHeaders,
              ),
            );

  /// 1. 获取扫码登录二维码信息
  /// 返回：{'token': '...', 'qrUrl': 'https://su.quark.cn/...'}
  Future<Map<String, dynamic>> getQrCode() async {
    final requestId = const Uuid().v4();
    final response = await _dio.get(
      '$uopUrl/getTokenForQrcodeLogin',
      queryParameters: {
        'client_id': '1',
        'v': '1.2',
        'request_id': requestId,
      },
    );

    final data = response.data;
    if (data is Map && data['status'] == 200) {
      final token = (data['data'] as Map?)?['token'] as String?;
      if (token != null && token.isNotEmpty) {
        final qrUrl = 'https://su.quark.cn/4_eMHBJ?token=$token';
        return {
          'token': token,
          'qrUrl': qrUrl,
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
        'client_id': '1',
        'v': '1.2',
        'token': token,
        'request_id': requestId,
      },
    );

    final data = response.data;
    if (data is! Map) {
      return QuarkQrCodeStatus.failed('响应格式错误');
    }

    final code = data['code'];
    final status = data['status'];

    // 0: 成功换取 ticket
    if (status == 200 && code == 0) {
      final ticket = (data['data'] as Map?)?['ticket'] as String?;
      if (ticket != null && ticket.isNotEmpty) {
        // 使用 ticket 换取 Cookie
        final cookie = await _exchangeTicketForCookie(ticket);
        if (cookie.isNotEmpty) {
          return QuarkQrCodeStatus.success(cookie);
        }
      }
    }

    // 40001: 等待扫码
    if (code == 40001) {
      return QuarkQrCodeStatus.waiting();
    }
    // 40002: 已扫码待确认
    if (code == 40002) {
      return QuarkQrCodeStatus.scanned();
    }
    // 40003 或 40004: 二维码失效 / 过期
    if (code == 40003 || code == 40004) {
      return QuarkQrCodeStatus.expired();
    }

    final msg = data['message'] as String? ?? '状态检查失败 ($code)';
    return QuarkQrCodeStatus.failed(msg);
  }

  /// 使用 ticket 换取并拼接 Cookie
  Future<String> _exchangeTicketForCookie(String ticket) async {
    final loginUrl = '$panUrl/account/login';
    final response = await _dio.get(
      loginUrl,
      queryParameters: {'ticket': ticket},
      options: Options(
        followRedirects: false,
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    final setCookies = response.headers['set-cookie'] ?? [];
    final Map<String, String> cookieMap = {};

    for (final raw in setCookies) {
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

    return cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 3. 获取用户基本信息及网盘空间
  Future<Map<String, dynamic>> getAccountInfo(String cookie) async {
    final response = await _dio.get(
      '$panUrl/account/info',
      options: Options(
        headers: {
          'Cookie': cookie,
        },
      ),
    );

    final data = response.data;
    if (data is Map && data['status'] == 200) {
      final accountData = data['data'] as Map<String, dynamic>? ?? {};
      return accountData;
    }
    throw StateError('获取账号信息失败: ${data['message'] ?? '未知错误'}');
  }

  /// 4. 列出目录下的文件与文件夹
  Future<Map<String, dynamic>> listFiles({
    required String cookie,
    String pdirFid = '0',
    int page = 1,
    int size = 100,
    String sort = 'file_type:desc,updated_at:desc',
  }) async {
    final response = await _dio.post(
      '$baseDriveUrl/file/sort',
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
      },
      data: {
        'pdir_fid': pdirFid,
        '_page': page,
        '_size': size,
        '_sort': sort,
        '_fetch_total': 1,
      },
      options: Options(
        headers: {
          'Cookie': cookie,
          'Content-Type': 'application/json',
        },
      ),
    );

    final data = response.data;
    if (data is Map && data['status'] == 200) {
      final innerData = data['data'] as Map<String, dynamic>? ?? {};
      final list = innerData['list'] as List? ?? [];
      final total = innerData['total'] as int? ?? list.length;

      final files = list
          .whereType<Map<String, dynamic>>()
          .map((item) => QuarkFile.fromJson(item))
          .toList();

      return {
        'total': total,
        'files': files,
      };
    }

    final code = data is Map ? data['code'] : -1;
    final message = data is Map ? data['message'] : '未知错误';
    if (code == 41001 || code == 41002 || (data is Map && data['status'] == 401)) {
      throw StateError('夸克登录状态已过期，请重新登录 (code: $code)');
    }
    throw StateError('获取文件列表失败: $message (code: $code)');
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

  /// 6. 获取文件临时下载直链
  Future<String> getDownloadUrl({
    required String cookie,
    required String fid,
  }) async {
    final response = await _dio.post(
      '$baseDriveUrl/file/download',
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
      },
      data: {
        'fids': [fid],
      },
      options: Options(
        headers: {
          'Cookie': cookie,
          'Content-Type': 'application/json',
        },
      ),
    );

    final data = response.data;
    if (data is Map && data['status'] == 200) {
      final list = data['data'] as List? ?? [];
      if (list.isNotEmpty && list[0] is Map) {
        final downloadUrl = list[0]['download_url'] as String?;
        if (downloadUrl != null && downloadUrl.isNotEmpty) {
          return downloadUrl;
        }
      }
    }

    final message = data is Map ? data['message'] : '获取下载直链失败';
    throw StateError('获取下载链接失败: $message');
  }
}
