import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/models/quark/quark_account.dart';
import 'package:nipaplay/models/quark/quark_catalog_item.dart';
import 'package:nipaplay/models/quark/quark_file.dart';
import 'package:nipaplay/models/quark/quark_mount_folder.dart';
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/services/quark/quark_api_client.dart';
import 'package:nipaplay/services/quark/quark_catalog_store.dart';
import 'package:nipaplay/services/quark/quark_metadata_scraper.dart';
import 'package:nipaplay/services/quark/quark_scan_pacer.dart';
import 'package:nipaplay/utils/media_source_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 夸克网盘业务逻辑服务单例
class QuarkService extends ChangeNotifier {
  static const String _accountPrefsKey = 'quark_saved_account';
  static const String _mountFoldersPrefsKey = 'quark_mount_folders';
  static const String _autoScanHoursKey = 'quark_auto_scan_hours';
  static const String _scanRequestMillisecondsKey =
      'quark_scan_request_milliseconds';
  static const String _legacyScanRequestSecondsKey =
      'quark_scan_request_seconds';
  static const String _tmdbTokenKey = 'quark_tmdb_read_token';
  static const String _scanBackoffKey = 'quark_scan_backoff_until';
  static const List<int> autoScanIntervals = [0, 1, 3, 6, 12, 24];
  static const int maxScanRequestMilliseconds = Duration.millisecondsPerDay;
  static bool isCatalogWorkId(int? id) => id != null && id <= -0x10000000000000;

  QuarkService._({
    QuarkApiClient? client,
    QuarkMetadataScraper? metadataScraper,
    QuarkScanPacer? testPacer,
  })  : _scanPacer = testPacer ?? QuarkScanPacer(),
        _metadataPacer = testPacer ?? QuarkScanPacer(),
        _metadataScraper = metadataScraper ?? QuarkMetadataScraper() {
    _client =
        client ?? QuarkApiClient(onCookieRefreshed: _persistRefreshedCookie);
  }
  static final QuarkService instance = QuarkService._();

  @visibleForTesting
  factory QuarkService.forTesting({
    required QuarkApiClient client,
    required QuarkMetadataScraper metadataScraper,
    required QuarkScanPacer pacer,
  }) =>
      QuarkService._(
          client: client, metadataScraper: metadataScraper, testPacer: pacer);

  late final QuarkApiClient _client;
  QuarkApiClient get client => _client;

  QuarkAccount? _currentAccount;
  QuarkAccount? get currentAccount => _currentAccount;
  int _sessionGeneration = 0;

  bool get isLoggedIn => _currentAccount != null && _currentAccount!.isValid;

  final List<QuarkMountFolder> _mountFolders = [];
  List<QuarkMountFolder> get mountFolders => List.unmodifiable(_mountFolders);

  // 缓存下载直链：fid -> (url, 过期时间)
  final Map<String, ({String url, DateTime expiresAt})> _urlCache = {};

  Future<void>? _initialization;
  final _catalogStore = QuarkCatalogStore();
  final QuarkScanPacer _scanPacer;
  final QuarkScanPacer _metadataPacer;
  final QuarkMetadataScraper _metadataScraper;
  final _metadata = <String, QuarkMetadataCacheEntry>{};
  final _workDetails = <int, BangumiAnime>{};
  String _tmdbToken = '';
  bool get hasTmdbToken => _tmdbToken.isNotEmpty;
  BangumiAnime? detailForWork(int? id) => _workDetails[id];
  final _catalogByMount = <String, List<QuarkCatalogItem>>{};
  final catalogRevision = ValueNotifier<int>(0);
  String? _catalogAccount;
  List<WatchHistoryItem> _indexedHistory = const [];
  List<WatchHistoryItem> get indexedHistory => _indexedHistory;
  bool get hasCatalog => _catalogByMount.isNotEmpty;
  final _autoAttempts = <String, DateTime>{};
  int _autoScanHours = 0;
  int get autoScanHours => _autoScanHours;
  int _scanRequestMilliseconds = 5000;
  int get scanRequestMilliseconds => _scanRequestMilliseconds;
  Timer? _autoScanTimer;
  DateTime? _scanBlockedUntil;

  @override
  void dispose() {
    _autoScanTimer?.cancel();
    catalogRevision.dispose();
    super.dispose();
  }

  /// 初始化，从本地存储加载已保存账号与挂载目录
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _tmdbToken = prefs.getString(_tmdbTokenKey) ?? '';
      final blockedUntil = prefs.getInt(_scanBackoffKey);
      if (blockedUntil != null) {
        _scanBlockedUntil = DateTime.fromMillisecondsSinceEpoch(blockedUntil);
      }
      final savedInterval = prefs.getInt(_autoScanHoursKey);
      if (autoScanIntervals.contains(savedInterval)) {
        _autoScanHours = savedInterval!;
      }
      final savedRequestMilliseconds =
          prefs.getInt(_scanRequestMillisecondsKey) ??
              (prefs.getInt(_legacyScanRequestSecondsKey) ?? 5) *
                  Duration.millisecondsPerSecond;
      if (savedRequestMilliseconds >= 0 &&
          savedRequestMilliseconds <= maxScanRequestMilliseconds) {
        _scanRequestMilliseconds = savedRequestMilliseconds;
      }
      final accountJson = prefs.getString(_accountPrefsKey);
      if (accountJson != null && accountJson.isNotEmpty) {
        _currentAccount = QuarkAccount.fromJson(
            jsonDecode(accountJson) as Map<String, dynamic>);
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
        await _loadCatalog(_currentAccount!, _sessionGeneration);
        unawaited(refreshAccountInfo());
      }
    } catch (e) {
      debugPrint('QuarkService 初始化失败: $e');
    }
    _scheduleAutoScan();
    notifyListeners();
  }

  /// 刷新当前账号的用户信息和空间容量
  Future<void> refreshAccountInfo() async {
    if (!isLoggedIn) return;
    final cookie = _currentAccount!.cookie;
    final generation = _sessionGeneration;
    try {
      final [info, member] = await Future.wait([
        _client.getAccountInfo(cookie).onError((_, __) => {}),
        _client.getMemberInfo(cookie).onError((_, __) => {}),
      ]);
      if (_sessionGeneration != generation ||
          (info.isEmpty && member.isEmpty)) {
        return;
      }
      final account = _currentAccount!;
      final memberType = (member['member_type'] as String?)?.toLowerCase();

      _currentAccount = account.copyWith(
        nickname: (info['nickname'] ?? info['name'])?.toString(),
        uid: info['uid']?.toString(),
        totalCapacity: member['total_capacity'] as int? ??
            info['total_capacity'] as int? ??
            info['total'] as int?,
        usedCapacity: member['use_capacity'] as int? ??
            info['used_capacity'] as int? ??
            info['used'] as int?,
        isVip: memberType == null
            ? info['is_vip'] as bool?
            : memberType != 'normal',
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
    final credentials = cookie.trim();
    if (credentials.isEmpty) throw StateError('夸克登录凭证为空');
    final generation = ++_sessionGeneration;
    final verifiedCookie = await _client.validateSession(credentials);
    _checkSession(generation);
    _urlCache.clear();
    _currentAccount = QuarkAccount(
      id: 'quark_default',
      uid: _extractUidFromCookie(verifiedCookie),
      nickname: '夸克用户',
      cookie: verifiedCookie,
      updatedAt: DateTime.now(),
    );

    await _persistAccount();
    _checkSession(generation);
    await refreshAccountInfo();
    _checkSession(generation);
    await _loadCatalog(_currentAccount!, generation);
    _scheduleAutoScan();
    notifyListeners();
  }

  /// 登出并清理当前账号
  Future<void> logout() async {
    _sessionGeneration++;
    _currentAccount = null;
    _catalogAccount = null;
    _catalogByMount.clear();
    _publishCatalog();
    _scheduleAutoScan();
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
    _scheduleAutoScan();
    notifyListeners();
  }

  /// 移除挂载目录
  Future<void> removeMountFolder(String fid) async {
    for (final folder in _mountFolders.where((folder) => folder.fid == fid)) {
      _catalogByMount.remove(folder.id);
      _autoAttempts.remove(folder.id);
    }
    _mountFolders.removeWhere((item) => item.fid == fid);
    _publishCatalog();
    await _persistMountFolders();
    _scheduleAutoScan();
    notifyListeners();
  }

  /// 列出夸克目录下的所有内容
  Future<List<QuarkFile>> listFiles(
    String pdirFid, {
    Future<void> Function()? beforePage,
  }) async {
    if (!isLoggedIn) {
      throw StateError('未登录夸克网盘');
    }

    final generation = _sessionGeneration;
    final files = <QuarkFile>[];
    for (var page = 1;; page++) {
      if (beforePage != null) await beforePage();
      _checkSession(generation);
      final result = await _client.listFiles(
        cookie: _currentAccount!.cookie,
        pdirFid: pdirFid,
        page: page,
      );
      _checkSession(generation);
      final pageFiles = result['files'] as List<QuarkFile>;
      files.addAll(pageFiles);
      if (pageFiles.isEmpty || files.length >= (result['total'] as int)) {
        return files;
      }
    }
  }

  /// 获取文件可播放/可下载的直链（带内存缓存，通常有效期 2 小时）
  Future<({String url, String cookie})> getDownloadLink(
    String fid, {
    bool forceRefresh = false,
  }) async {
    if (!isLoggedIn) {
      throw StateError('未登录夸克网盘');
    }

    final generation = _sessionGeneration;
    final now = DateTime.now();
    if (!forceRefresh && _urlCache.containsKey(fid)) {
      final cached = _urlCache[fid]!;
      if (cached.expiresAt.isAfter(now)) {
        return (url: cached.url, cookie: _currentAccount!.cookie);
      }
    }

    final freshUrl = await _client.getDownloadUrl(
      cookie: _currentAccount!.cookie,
      fid: fid,
    );
    _checkSession(generation);

    // 缓存 1.5 小时（夸克直链通常有效 2~4 小时）
    _urlCache[fid] = (
      url: freshUrl,
      expiresAt: now.add(const Duration(minutes: 90)),
    );

    return (url: freshUrl, cookie: _currentAccount!.cookie);
  }

  void _checkSession(int generation) {
    if (_sessionGeneration != generation) {
      throw StateError('夸克账号状态已变更，请重试');
    }
  }

  Future<void> _persistRefreshedCookie(
      String previousCookie, String cookie) async {
    final account = _currentAccount;
    if (account == null || account.cookie != previousCookie) return;
    _currentAccount = account.copyWith(cookie: cookie);
    await _persistAccount();
  }

  Future<void> _persistAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final account = _currentAccount;
    if (account == null) return;
    await prefs.setString(
      _accountPrefsKey,
      jsonEncode(account.toJson()),
    );
  }

  Future<void> _persistMountFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _mountFolders.map((f) => jsonEncode(f.toJson())).toList();
    await prefs.setStringList(_mountFoldersPrefsKey, list);
  }

  String? _scanningFolderId;
  String? get scanningFolderId => _scanningFolderId;
  bool get isScanning => _scanningFolderId != null;

  String _scanningStatus = '';
  String get scanningStatus => _scanningStatus;

  Future<void> setAutoScanHours(int hours) async {
    if (!autoScanIntervals.contains(hours)) throw ArgumentError.value(hours);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_autoScanHoursKey, hours);
    _autoScanHours = hours;
    _scheduleAutoScan();
    notifyListeners();
  }

  Future<void> setScanRequestMilliseconds(int milliseconds) async {
    if (milliseconds < 0 || milliseconds > maxScanRequestMilliseconds) {
      throw RangeError.range(milliseconds, 0, maxScanRequestMilliseconds);
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setInt(_scanRequestMillisecondsKey, milliseconds)) {
      throw StateError('无法保存目录请求间隔');
    }
    _scanRequestMilliseconds = milliseconds;
    notifyListeners();
  }

  Future<void> setTmdbToken(String token) async {
    final normalized = token.trim();
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      await prefs.remove(_tmdbTokenKey);
    } else {
      await prefs.setString(_tmdbTokenKey, normalized);
    }
    _tmdbToken = normalized;
    _publishCatalog();
    notifyListeners();
  }

  void _scheduleAutoScan() {
    _autoScanTimer?.cancel();
    _autoScanTimer = null;
    if (!isLoggedIn || _autoScanHours == 0 || isScanning) return;

    QuarkMountFolder? selected;
    DateTime? nextRun;
    final interval = Duration(hours: _autoScanHours);
    for (final folder in _mountFolders.where((folder) => folder.autoScan)) {
      final lastScan = folder.lastScanTime ?? folder.addedAt;
      final attempt = _autoAttempts[folder.id];
      final last =
          attempt != null && attempt.isAfter(lastScan) ? attempt : lastScan;
      final due = last.add(interval);
      if (nextRun == null || due.isBefore(nextRun)) {
        nextRun = due;
        selected = folder;
      }
    }
    if (nextRun == null || selected == null) return;
    final blockedUntil = _scanBlockedUntil;
    if (blockedUntil != null && blockedUntil.isAfter(nextRun)) {
      nextRun = blockedUntil;
    }
    final folder = selected;
    final delay = nextRun.difference(DateTime.now());
    _autoScanTimer = Timer(delay.isNegative ? Duration.zero : delay, () async {
      _autoAttempts[folder.id] = DateTime.now();
      try {
        await scanMountFolder(folder);
      } catch (error) {
        debugPrint('夸克自动扫描失败: $error');
      } finally {
        _scheduleAutoScan();
      }
    });
  }

  Future<void> _loadCatalog(QuarkAccount account, int generation) async {
    final uid = _extractUidFromCookie(account.cookie);
    final stableCookie = account.cookie
        .split(';')
        .map((part) => part.trim())
        .firstWhere((part) => part.startsWith('__pus='),
            orElse: () => account.cookie);
    final scope = uid.isNotEmpty
        ? 'uid:$uid'
        : account.uid.isNotEmpty
            ? 'uid:${account.uid}'
            : 'session:${sha256.convert(utf8.encode(stableCookie))}';
    final stored = _mountFolders.isEmpty
        ? <String, List<QuarkCatalogItem>>{}
        : await _catalogStore.load(scope);
    final metadata = stored.isEmpty ? null : await _catalogStore.loadMetadata();
    _checkSession(generation);
    _catalogAccount = scope;
    if (metadata != null) _metadata.addAll(metadata);
    _catalogByMount
      ..clear()
      ..addEntries(stored.entries.where(
          (entry) => _mountFolders.any((folder) => folder.id == entry.key)));
    _publishCatalog();
  }

  void _publishCatalog() {
    final distinct = <String, QuarkCatalogItem>{};
    for (final items in _catalogByMount.values) {
      for (final item in items) {
        distinct.putIfAbsent(item.fid, () => item);
      }
    }
    final workIds = <String, int>{};
    final episodesByWork = <int, List<EpisodeData>>{};
    _workDetails.clear();
    _indexedHistory = List.unmodifiable(distinct.values.map((item) {
      final workId = workIds.putIfAbsent(item.workKey, () {
        final digest = sha256
            .convert(utf8.encode('quark|$_catalogAccount|${item.workKey}'));
        return -0x10000000000000 -
            int.parse(digest.toString().substring(0, 13), radix: 16);
      });
      final key = QuarkMetadataScraper.keyFor(item, useTmdb: hasTmdbToken);
      final metadata = _metadata[key]?.metadata;
      final episodeId = item.episodeOrder * 0x100000 +
          int.parse(
              sha256.convert(utf8.encode(item.fid)).toString().substring(0, 5),
              radix: 16);
      final episodes = episodesByWork.putIfAbsent(workId, () => []);
      episodes.add(EpisodeData(id: episodeId, title: item.label));
      _workDetails.putIfAbsent(
          workId,
          () => BangumiAnime(
                id: workId,
                name: item.displayTitle,
                nameCn: item.displayTitle,
                imageUrl: metadata?.cover ?? '',
                summary: metadata?.summary,
                typeDescription: item.isSeries ? '电视剧' : '电影',
                episodeList: episodes,
              ));
      return WatchHistoryItem(
        filePath: MediaSourceUtils.buildQuarkPath(item.fid, item.fileName),
        animeName: item.displayTitle,
        episodeTitle: item.label,
        animeId: workId,
        episodeId: episodeId,
        watchProgress: 0,
        lastPosition: 0,
        duration: 0,
        lastWatchTime: DateTime.fromMillisecondsSinceEpoch(item.addedAt),
        thumbnailPath: metadata?.cover,
        isFromScan: true,
      );
    }));
    for (final episodes in episodesByWork.values) {
      episodes.sort((a, b) => a.id.compareTo(b.id));
    }
    catalogRevision.value++;
  }

  Future<int> _scrapeMetadata(
      List<QuarkCatalogItem> items, void Function() checkScan) async {
    final token = _tmdbToken;
    final uniqueWorks = <String, QuarkCatalogItem>{};
    for (final item in items) {
      uniqueWorks.putIfAbsent(
          QuarkMetadataScraper.keyFor(item, useTmdb: token.isNotEmpty),
          () => item);
    }
    var updated = 0;
    for (final work in uniqueWorks.entries) {
      checkScan();
      if (_tmdbToken != token) break;
      final cached = _metadata[work.key];
      final ttl = Duration(days: cached?.metadata == null ? 7 : 30);
      if (cached != null &&
          DateTime.now().millisecondsSinceEpoch - cached.checkedAt <
              ttl.inMilliseconds) {
        continue;
      }
      _scanningStatus = '正在补充作品资料：${work.value.displayTitle}';
      notifyListeners();
      await _metadataPacer.waitForTurn();
      checkScan();
      if (_tmdbToken != token) break;
      try {
        final result = await _metadataScraper.lookup(work.value, token);
        checkScan();
        final entry = (
          checkedAt: DateTime.now().millisecondsSinceEpoch,
          metadata: result ?? cached?.metadata
        );
        await _catalogStore.saveMetadata(work.key, entry);
        _metadata[work.key] = entry;
        if (result != null && ++updated % 10 == 0) _publishCatalog();
      } catch (error) {
        checkScan();
        debugPrint('夸克作品资料查询已暂停 (${error.runtimeType})');
        break;
      }
    }
    if (updated > 0) _publishCatalog();
    return updated;
  }

  /// 扫描只读取目录分页，使用文件名和目录名建立可播放的索引。
  Future<Map<String, int>> scanMountFolder(QuarkMountFolder folder) async {
    if (!isLoggedIn) throw StateError('未登录夸克网盘');
    if (isScanning) throw StateError('已有扫描任务正在进行中');
    if (_scanBlockedUntil?.isAfter(DateTime.now()) ?? false) {
      throw StateError('夸克请求过于频繁，请稍后重试');
    }
    final scope = _catalogAccount;
    if (scope == null) throw StateError('夸克索引尚未初始化');
    final generation = _sessionGeneration;
    final requestInterval = Duration(seconds: _scanRequestSeconds);
    final existing = {
      for (final item
          in _catalogByMount[folder.id] ?? const <QuarkCatalogItem>[])
        item.fid: item
    };
    final entries = <String, QuarkCatalogItem>{};
    final directories = Queue<List<({String fid, String name})>>()
      ..add([(fid: folder.fid, name: folder.name)]);
    final visited = <String>{folder.fid};
    final now = DateTime.now();
    var nextCheckpoint = now;
    var changed = false;

    void checkScan() {
      _checkSession(generation);
      if (!_mountFolders.any((mounted) => mounted.id == folder.id)) {
        throw StateError('扫描目录已解除挂载');
      }
    }

    Future<void> persist(List<QuarkCatalogItem> items) async {
      checkScan();
      await _catalogStore.save(scope, folder.id, items);
      checkScan();
      _catalogByMount[folder.id] = items;
      _publishCatalog();
    }

    _scanningFolderId = folder.id;
    _scheduleAutoScan();
    _scanningStatus = '正在扫描 ${folder.name}';
    notifyListeners();
    try {
      while (directories.isNotEmpty) {
        final path = directories.removeLast();
        final progress = '已发现 ${entries.length} 个视频';
        final files = await listFiles(path.last.fid, beforePage: () async {
          checkScan();
          await _scanPacer.waitForTurn(
            interval: requestInterval,
            onWait: (wait) {
              final seconds =
                  (wait.inMicroseconds / Duration.microsecondsPerSecond).ceil();
              _scanningStatus = '约 $seconds 秒后继续请求目录，$progress';
              notifyListeners();
            },
          );
          checkScan();
          _scanningStatus = '正在扫描 ${path.last.name}，$progress';
          notifyListeners();
        });
        final relativeDirectory = path.skip(1).map((dir) => dir.name).join('/');
        for (final file in files) {
          if (file.fid.isEmpty) continue;
          if (file.isDir && visited.add(file.fid)) {
            directories.add([...path, (fid: file.fid, name: file.fileName)]);
          } else if (file.isVideo) {
            final previous = existing[file.fid];
            final relativePath = relativeDirectory.isEmpty
                ? file.fileName
                : '$relativeDirectory/${file.fileName}';
            if (previous != null &&
                previous.relativePath == relativePath &&
                previous.size == file.fileSize &&
                previous.modifiedAt == file.updatedAt.millisecondsSinceEpoch) {
              entries[file.fid] = previous;
              continue;
            }
            changed = true;
            entries[file.fid] = QuarkCatalogItem.parse(
              fid: file.fid,
              fileName: file.fileName,
              directories: path,
              size: file.fileSize,
              modifiedAt: file.updatedAt.millisecondsSinceEpoch,
              addedAt: previous?.addedAt ?? now.millisecondsSinceEpoch,
            );
          }
        }
        if (changed && !DateTime.now().isBefore(nextCheckpoint)) {
          // Only a successful traversal may remove entries from the old index.
          await persist(
              {...existing, ...entries}.values.toList(growable: false));
          nextCheckpoint = DateTime.now().add(const Duration(seconds: 45));
          changed = false;
        }
      }
      final indexed = entries.values.toList(growable: false);
      await persist(indexed);
      final enriched = await _scrapeMetadata(indexed, checkScan);
      checkScan();
      final index =
          _mountFolders.indexWhere((mounted) => mounted.id == folder.id);
      _mountFolders[index] = _mountFolders[index].copyWith(
        videoCount: indexed.length,
        lastScanTime: DateTime.now(),
      );
      await _persistMountFolders();
      return {
        'total': indexed.length,
        'works': indexed.map((item) => item.workKey).toSet().length,
        'enriched': enriched,
      };
    } on QuarkRateLimitException catch (error) {
      _scanBlockedUntil = DateTime.now().add(error.retryAfter);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _scanBackoffKey, _scanBlockedUntil!.millisecondsSinceEpoch);
      rethrow;
    } finally {
      _scanningFolderId = null;
      _scanningStatus = '';
      _scheduleAutoScan();
      notifyListeners();
    }
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
