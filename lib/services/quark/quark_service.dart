import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:nipaplay/models/quark/quark_account.dart';
import 'package:nipaplay/models/quark/quark_file.dart';
import 'package:nipaplay/models/quark/quark_mount_folder.dart';
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/services/danmaku_matching_service.dart';
import 'package:nipaplay/services/quark/quark_api_client.dart';
import 'package:nipaplay/services/quark/quark_proxy_service.dart';
import 'package:nipaplay/utils/media_source_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 夸克网盘业务逻辑服务单例
class QuarkService extends ChangeNotifier {
  static const String _accountPrefsKey = 'quark_saved_account';
  static const String _mountFoldersPrefsKey = 'quark_mount_folders';

  QuarkService._();
  static final QuarkService instance = QuarkService._();

  final QuarkApiClient _client = QuarkApiClient();
  QuarkApiClient get client => _client;

  QuarkAccount? _currentAccount;
  QuarkAccount? get currentAccount => _currentAccount;

  bool get isLoggedIn =>
      _currentAccount != null && _currentAccount!.isValid;

  final List<QuarkMountFolder> _mountFolders = [];
  List<QuarkMountFolder> get mountFolders =>
      List.unmodifiable(_mountFolders);

  // 缓存下载直链：fid -> (url, 过期时间)
  final Map<String, ({String url, DateTime expiresAt})> _urlCache = {};

  bool _isInitialized = false;

  /// 初始化，从本地存储加载已保存账号与挂载目录
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final accountJson = prefs.getString(_accountPrefsKey);
      if (accountJson != null && accountJson.isNotEmpty) {
        _currentAccount =
            QuarkAccount.fromJson(jsonDecode(accountJson) as Map<String, dynamic>);
      }

      final foldersJson = prefs.getStringList(_mountFoldersPrefsKey) ?? [];
      _mountFolders.clear();
      for (final raw in foldersJson) {
        try {
          _mountFolders.add(
            QuarkMountFolder.fromJson(jsonDecode(raw) as Map<String, dynamic>),
          );
        } catch (_) {}
      }

      // 静默刷新用户信息与容量
      if (isLoggedIn) {
        unawaited(refreshAccountInfo());
      }
    } catch (e) {
      debugPrint('QuarkService 初始化失败: $e');
    }
    notifyListeners();
  }

  /// 刷新当前账号的用户信息和空间容量
  Future<void> refreshAccountInfo() async {
    if (!isLoggedIn) return;
    try {
      final info = await _client.getAccountInfo(_currentAccount!.cookie);
      final nickname = (info['nickname'] ?? info['name'] ?? '夸克用户').toString();
      final uid = (info['uid'] ?? '').toString();
      final total = info['total_capacity'] as int? ??
          info['total'] as int? ??
          _currentAccount!.totalCapacity;
      final used = info['used_capacity'] as int? ??
          info['used'] as int? ??
          _currentAccount!.usedCapacity;
      final isVip = info['is_vip'] as bool? ??
          info['member_type'] != null && info['member_type'] != 'normal';

      _currentAccount = _currentAccount!.copyWith(
        nickname: nickname,
        uid: uid.isNotEmpty ? uid : _currentAccount!.uid,
        totalCapacity: total,
        usedCapacity: used,
        isVip: isVip,
        updatedAt: DateTime.now(),
      );

      await _persistAccount();
      notifyListeners();
    } catch (e) {
      debugPrint('刷新夸克账号信息失败: $e');
    }
  }

  /// 登录成功后设置 Cookie 并保存
  Future<void> loginWithCookie(String cookie) async {
    final uid = _extractUidFromCookie(cookie);
    _currentAccount = QuarkAccount(
      id: 'quark_default',
      uid: uid,
      nickname: '夸克用户',
      cookie: cookie.trim(),
      updatedAt: DateTime.now(),
    );

    await _persistAccount();
    await refreshAccountInfo();
    notifyListeners();
  }

  /// 登出并清理当前账号
  Future<void> logout() async {
    _currentAccount = null;
    _urlCache.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accountPrefsKey);
    notifyListeners();
  }

  /// 添加挂载目录
  Future<void> addMountFolder(QuarkMountFolder folder) async {
    _mountFolders.removeWhere((item) => item.fid == folder.fid);
    _mountFolders.add(folder);
    await _persistMountFolders();
    notifyListeners();
  }

  /// 移除挂载目录
  Future<void> removeMountFolder(String fid) async {
    _mountFolders.removeWhere((item) => item.fid == fid);
    await _persistMountFolders();
    notifyListeners();
  }

  /// 列出夸克目录下的所有内容
  Future<List<QuarkFile>> listFiles(String pdirFid) async {
    if (!isLoggedIn) {
      throw StateError('未登录夸克网盘');
    }
    final result = await _client.listFiles(
      cookie: _currentAccount!.cookie,
      pdirFid: pdirFid,
      size: 200,
    );
    return result['files'] as List<QuarkFile>? ?? [];
  }

  /// 获取文件可播放/可下载的直链（带内存缓存，通常有效期 2 小时）
  Future<String> getDownloadUrl(String fid, {bool forceRefresh = false}) async {
    if (!isLoggedIn) {
      throw StateError('未登录夸克网盘');
    }

    final now = DateTime.now();
    if (!forceRefresh && _urlCache.containsKey(fid)) {
      final cached = _urlCache[fid]!;
      if (cached.expiresAt.isAfter(now)) {
        return cached.url;
      }
    }

    final freshUrl = await _client.getDownloadUrl(
      cookie: _currentAccount!.cookie,
      fid: fid,
    );

    // 缓存 1.5 小时（夸克直链通常有效 2~4 小时）
    _urlCache[fid] = (
      url: freshUrl,
      expiresAt: now.add(const Duration(minutes: 90)),
    );

    return freshUrl;
  }

  Future<void> _persistAccount() async {
    if (_currentAccount == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _accountPrefsKey,
      jsonEncode(_currentAccount!.toJson()),
    );
  }

  Future<void> _persistMountFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _mountFolders.map((f) => jsonEncode(f.toJson())).toList();
    await prefs.setStringList(_mountFoldersPrefsKey, list);
  }

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  String _scanningStatus = '';
  String get scanningStatus => _scanningStatus;

  /// 递归遍历夸克目录收集所有视频文件
  Future<List<QuarkFile>> collectVideoFilesRecursively(
    String rootFid, {
    void Function(String folderName)? onFolderEntered,
    int maxDepth = 5,
  }) async {
    final List<QuarkFile> videos = [];
    final List<({String fid, String name, int depth})> queue = [
      (fid: rootFid, name: '/', depth: 0)
    ];
    final Set<String> visitedFids = {rootFid};

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      onFolderEntered?.call(current.name);

      try {
        final items = await listFiles(current.fid);
        for (final item in items) {
          if (item.isDir) {
            if (current.depth + 1 <= maxDepth && !visitedFids.contains(item.fid)) {
              visitedFids.add(item.fid);
              queue.add((
                fid: item.fid,
                name: item.fileName,
                depth: current.depth + 1,
              ));
            }
          } else if (item.isVideo) {
            videos.add(item);
          }
        }
      } catch (e) {
        debugPrint('遍历夸克文件夹 ${current.name} (${current.fid}) 失败: $e');
      }
    }
    return videos;
  }

  /// 扫描已挂载的夸克目录，拉取视频并自动刮削识别番剧
  Future<Map<String, int>> scanMountFolder(
    QuarkMountFolder folder, {
    void Function(int processed, int total, String currentName)? onProgress,
  }) async {
    if (!isLoggedIn) {
      throw StateError('未登录夸克网盘');
    }
    if (_isScanning) {
      throw StateError('已有扫描任务正在进行中');
    }

    _isScanning = true;
    _scanningStatus = '正在遍历网盘目录: ${folder.name}...';
    notifyListeners();

    int matched = 0;
    int failed = 0;
    int total = 0;

    try {
      await QuarkProxyService.instance.initialize();

      final videos = await collectVideoFilesRecursively(
        folder.fid,
        onFolderEntered: (folderName) {
          _scanningStatus = '正在遍历: $folderName...';
          notifyListeners();
        },
      );

      total = videos.length;
      int processed = 0;

      for (final video in videos) {
        processed++;
        _scanningStatus = '正在刮削: ${video.fileName} ($processed/$total)...';
        notifyListeners();
        onProgress?.call(processed, total, video.fileName);

        final filePath = MediaSourceUtils.buildQuarkPath(video.fid, video.fileName);
        final probePath = QuarkProxyService.instance.buildStreamUrl(
          video.fid,
          fileName: video.fileName,
        );

        try {
          final videoInfo = await DanmakuMatchingService.instance.getVideoInfo(probePath);
          final matches = videoInfo['matches'];
          if (videoInfo['isMatched'] != true ||
              matches is! List ||
              matches.isEmpty ||
              matches.first is! Map) {
            failed++;
            continue;
          }

          final match = Map<String, dynamic>.from(matches.first as Map);
          final animeId = _parseMatchId(match['animeId']);
          final episodeId = _parseMatchId(match['episodeId']);
          if (animeId == null || episodeId == null) {
            failed++;
            continue;
          }

          final existingHistory = await WatchHistoryManager.getHistoryItem(filePath);
          WatchHistoryItem? migratedHistory;
          if (existingHistory == null && animeId > 0 && episodeId > 0) {
            migratedHistory = await WatchHistoryManager.getClearedHistoryItemByEpisode(
              animeId,
              episodeId,
            );
          }

          final sourceForProgress = existingHistory ?? migratedHistory;
          final rawAnimeTitle = videoInfo['animeTitle'] ?? match['animeTitle'];
          final rawEpisodeTitle = videoInfo['episodeTitle'] ?? match['episodeTitle'];
          final rawHash = videoInfo['fileHash'] ?? videoInfo['hash'];
          final animeTitle = rawAnimeTitle?.toString();
          final episodeTitle = rawEpisodeTitle?.toString();
          final hashString = rawHash?.toString();
          final durationFromMatch = (videoInfo['duration'] is int)
              ? videoInfo['duration'] as int
              : (sourceForProgress?.duration ?? 0);

          final preserveProgress = sourceForProgress != null &&
              sourceForProgress.watchProgress > 0.01 &&
              !sourceForProgress.isFromScan;

          final historyItem = WatchHistoryItem(
            filePath: filePath,
            animeName: animeTitle?.isNotEmpty == true
                ? animeTitle!
                : (sourceForProgress?.animeName ??
                    p.basenameWithoutExtension(video.fileName)),
            episodeTitle: episodeTitle?.isNotEmpty == true
                ? episodeTitle
                : sourceForProgress?.episodeTitle,
            episodeId: episodeId,
            animeId: animeId,
            watchProgress: preserveProgress
                ? sourceForProgress.watchProgress
                : (sourceForProgress?.watchProgress ?? 0.0),
            lastPosition: preserveProgress
                ? sourceForProgress.lastPosition
                : (sourceForProgress?.lastPosition ?? 0),
            duration: durationFromMatch,
            lastWatchTime: DateTime.now(),
            thumbnailPath: sourceForProgress?.thumbnailPath,
            isFromScan: !preserveProgress,
            videoHash: hashString?.isNotEmpty == true
                ? hashString
                : sourceForProgress?.videoHash,
          );

          await WatchHistoryManager.addOrUpdateHistory(historyItem);
          matched++;
        } catch (e) {
          debugPrint('刮削视频 ${video.fileName} 失败: $e');
          failed++;
        }
      }

      // 更新挂载文件夹的视频数量与上次扫描时间
      final updatedFolder = folder.copyWith(
        videoCount: total,
        lastScanTime: DateTime.now(),
      );
      await addMountFolder(updatedFolder);
    } finally {
      _isScanning = false;
      _scanningStatus = '';
      notifyListeners();
    }

    return {
      'total': total,
      'matched': matched,
      'failed': failed,
    };
  }

  int? _parseMatchId(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse(raw.toString().trim());
  }

  String _extractUidFromCookie(String cookie) {
    for (final part in cookie.split(';')) {
      final trimmed = part.trim();
      if (trimmed.startsWith('__uid=')) {
        return trimmed.substring('__uid='.length);
      }
    }
    return '';
  }
}
