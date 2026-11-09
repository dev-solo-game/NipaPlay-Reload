/// 夸克网盘媒体库挂载目录配置
class QuarkMountFolder {
  final String id;
  final String fid; // 夸克目录 ID，根目录为 '0'
  final String name; // 目录显示名称
  final String path; // 相对路径，如 /我的资源/动漫
  final DateTime addedAt;
  final bool autoScan; // 是否加入自动扫描刮削
  final int videoCount;
  final DateTime? lastScanTime;

  QuarkMountFolder({
    required this.id,
    required this.fid,
    required this.name,
    this.path = '/',
    required this.addedAt,
    this.autoScan = true,
    this.videoCount = 0,
    this.lastScanTime,
  });

  QuarkMountFolder copyWith({
    String? id,
    String? fid,
    String? name,
    String? path,
    DateTime? addedAt,
    bool? autoScan,
    int? videoCount,
    DateTime? lastScanTime,
  }) {
    return QuarkMountFolder(
      id: id ?? this.id,
      fid: fid ?? this.fid,
      name: name ?? this.name,
      path: path ?? this.path,
      addedAt: addedAt ?? this.addedAt,
      autoScan: autoScan ?? this.autoScan,
      videoCount: videoCount ?? this.videoCount,
      lastScanTime: lastScanTime ?? this.lastScanTime,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fid': fid,
        'name': name,
        'path': path,
        'addedAt': addedAt.toIso8601String(),
        'autoScan': autoScan,
        'videoCount': videoCount,
        'lastScanTime': lastScanTime?.toIso8601String(),
      };

  factory QuarkMountFolder.fromJson(Map<String, dynamic> json) =>
      QuarkMountFolder(
        id: json['id'] as String? ?? json['fid'] as String,
        fid: json['fid'] as String? ?? '0',
        name: json['name'] as String? ?? '夸克文件夹',
        path: json['path'] as String? ?? '/',
        addedAt: json['addedAt'] != null
            ? DateTime.tryParse(json['addedAt'] as String) ?? DateTime.now()
            : DateTime.now(),
        autoScan: json['autoScan'] as bool? ?? true,
        videoCount: json['videoCount'] as int? ?? 0,
        lastScanTime: json['lastScanTime'] != null
            ? DateTime.tryParse(json['lastScanTime'] as String)
            : null,
      );
}
