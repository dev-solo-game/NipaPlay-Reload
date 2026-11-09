/// 夸克网盘文件与文件夹对象
class QuarkFile {
  final String fid;
  final String fileName;
  final int fileSize;
  final String pdirFid;
  final bool isDir;
  final int fileType;
  final DateTime updatedAt;
  final String? formatType;
  final String? thumbnailUrl;
  final String? downloadUrl;
  final DateTime? downloadUrlExpiresAt;

  QuarkFile({
    required this.fid,
    required this.fileName,
    required this.fileSize,
    required this.pdirFid,
    required this.isDir,
    this.fileType = 0,
    required this.updatedAt,
    this.formatType,
    this.thumbnailUrl,
    this.downloadUrl,
    this.downloadUrlExpiresAt,
  });

  bool get isVideo {
    if (isDir) return false;
    final lower = fileName.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.flv') ||
        lower.endsWith('.wmv') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.iso');
  }

  factory QuarkFile.fromJson(Map<String, dynamic> json) {
    final int? fileTypeVal = json['file_type'] as int?;
    final formatType = json['format_type'];
    final fileFlag = json['file'];
    final bool isDirFlag = json['dir'] == true ||
        json['is_dir'] == true ||
        (json['obj_category'] as String?) == 'dir';
    final bool isDirectory;
    if (fileFlag is bool) {
      isDirectory = !fileFlag;
    } else if (fileTypeVal != null) {
      isDirectory = fileTypeVal == 0;
    } else {
      isDirectory = isDirFlag || formatType == 1;
    }

    final int updateTimeMs = json['updated_at'] as int? ??
        json['created_at'] as int? ??
        DateTime.now().millisecondsSinceEpoch;

    return QuarkFile(
      fid: (json['fid'] ?? json['id'] ?? '').toString(),
      fileName: (json['file_name'] ?? json['name'] ?? '').toString(),
      fileSize: json['size'] as int? ?? 0,
      pdirFid: (json['pdir_fid'] ?? '').toString(),
      isDir: isDirectory,
      fileType: fileTypeVal ?? 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updateTimeMs),
      formatType: formatType?.toString(),
      thumbnailUrl: json['thumbnail'] as String?,
      downloadUrl: json['download_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'fid': fid,
        'fileName': fileName,
        'fileSize': fileSize,
        'pdirFid': pdirFid,
        'isDir': isDir,
        'fileType': fileType,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'formatType': formatType,
        'thumbnailUrl': thumbnailUrl,
        'downloadUrl': downloadUrl,
      };

  QuarkFile copyWith({
    String? fid,
    String? fileName,
    int? fileSize,
    String? pdirFid,
    bool? isDir,
    int? fileType,
    DateTime? updatedAt,
    String? formatType,
    String? thumbnailUrl,
    String? downloadUrl,
    DateTime? downloadUrlExpiresAt,
  }) =>
      QuarkFile(
        fid: fid ?? this.fid,
        fileName: fileName ?? this.fileName,
        fileSize: fileSize ?? this.fileSize,
        pdirFid: pdirFid ?? this.pdirFid,
        isDir: isDir ?? this.isDir,
        fileType: fileType ?? this.fileType,
        updatedAt: updatedAt ?? this.updatedAt,
        formatType: formatType ?? this.formatType,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
        downloadUrl: downloadUrl ?? this.downloadUrl,
        downloadUrlExpiresAt:
            downloadUrlExpiresAt ?? this.downloadUrlExpiresAt,
      );
}
