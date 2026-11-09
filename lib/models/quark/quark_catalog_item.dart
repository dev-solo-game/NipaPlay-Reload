import 'package:path/path.dart' as p;

class QuarkCatalogItem {
  const QuarkCatalogItem({
    required this.fid,
    required this.fileName,
    required this.relativePath,
    required this.size,
    required this.modifiedAt,
    required this.addedAt,
    required this.workKey,
    required this.title,
    this.year,
    this.season,
    this.episode,
    this.part,
    this.episodeTitle,
  });

  final String fid;
  final String fileName;
  final String relativePath;
  final int size;
  final int modifiedAt;
  final int addedAt;
  final String workKey;
  final String title;
  final int? year;
  final int? season;
  final int? episode;
  final String? part;
  final String? episodeTitle;

  bool get isSeries => season != null || episode != null;

  String get displayTitle => year == null ? title : '$title ($year)';

  int get episodeOrder {
    final partNumber =
        int.tryParse(RegExp(r'\d+').stringMatch(part ?? '') ?? '');
    return (season ?? 0) * 1000000 + (episode ?? 1) * 1000 + (partNumber ?? 0);
  }

  String get label {
    final prefix = episode == null
        ? fileName
        : 'S${(season ?? 1).toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    return [
      prefix,
      if (isSeries && part != null) part!,
      if (episodeTitle != null) episodeTitle!
    ].join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'fid': fid,
        'name': fileName,
        'path': relativePath,
        'size': size,
        'modified': modifiedAt,
        'added': addedAt,
        'work': workKey,
        'title': title,
        'year': year,
        'season': season,
        'episode': episode,
        'part': part,
        'episodeTitle': episodeTitle,
      };

  factory QuarkCatalogItem.fromJson(Map<String, dynamic> json) =>
      QuarkCatalogItem(
        fid: json['fid'] as String,
        fileName: json['name'] as String,
        relativePath: json['path'] as String,
        size: json['size'] as int,
        modifiedAt: json['modified'] as int,
        addedAt: json['added'] as int,
        workKey: json['work'] as String,
        title: json['title'] as String,
        year: json['year'] as int?,
        season: json['season'] as int?,
        episode: json['episode'] as int?,
        part: json['part'] as String?,
        episodeTitle: json['episodeTitle'] as String?,
      );

  static final _seasonFolder =
      RegExp(r'^Season\s+(\d+)$', caseSensitive: false);
  static final _episodeName = RegExp(
    r'^(.*?)\s+-\s+S(\d+)E(\d+)(?:-(\S+))?(?:\s+-\s+第\s*(.*?)\s*集)?$',
    caseSensitive: false,
  );
  static final _numberedEpisode = RegExp(r'第\s*(\d+)\s*[集话話]');
  static final _yearSuffix = RegExp(r'\s*[（(]((?:18|19|20)\d{2})[）)]$');
  static final _yearInFile =
      RegExp(r'^(.*?[（(](?:18|19|20)\d{2}[）)])(?=$|-|\s)');
  static final _moviePart = RegExp(r'^\s*-([^\s]+)(?:\s|$)');

  /// [directories] runs from the mounted root to the file's parent.
  static QuarkCatalogItem parse({
    required String fid,
    required String fileName,
    required List<({String fid, String name})> directories,
    required int size,
    required int modifiedAt,
    required int addedAt,
  }) {
    final stem = p.basenameWithoutExtension(fileName).trim();
    final parent = directories.last;
    final seasonFolder = _seasonFolder.firstMatch(parent.name.trim());
    final episodeName = _episodeName.firstMatch(stem);
    final isSeries = seasonFolder != null || episodeName != null;
    final workDirectory = seasonFolder != null && directories.length > 1
        ? directories[directories.length - 2]
        : parent;
    final season =
        int.tryParse(episodeName?.group(2) ?? seasonFolder?.group(1) ?? '');
    final episode = int.tryParse(episodeName?.group(3) ??
        (isSeries ? _numberedEpisode.firstMatch(stem)?.group(1) ?? '' : ''));
    final movieStem =
        _yearInFile.firstMatch(stem)?.group(1) ?? stem.split(' - ').first;
    final directoryTitle = workDirectory.name.trim();
    final fileTitle = episodeName?.group(1)?.trim() ?? movieStem;
    final plainDirectoryTitle = _stripYear(directoryTitle).toLowerCase();
    final plainFileTitle = _stripYear(fileTitle).toLowerCase();
    final directoryMatchesFile = plainDirectoryTitle.isNotEmpty &&
        (plainDirectoryTitle == plainFileTitle ||
            plainFileTitle.startsWith('$plainDirectoryTitle-'));
    final useDirectory = directoryMatchesFile ||
        (seasonFolder != null && directories.length > 1);
    final titleWithYear = useDirectory ? directoryTitle : fileTitle;
    final title = _stripYear(titleWithYear);
    final year = int.tryParse(_yearSuffix.firstMatch(titleWithYear)?.group(1) ??
        _yearSuffix.firstMatch(fileTitle)?.group(1) ??
        '');
    final moviePrefix = useDirectory ? directoryTitle : movieStem;
    final part = isSeries
        ? episodeName?.group(4)
        : stem.startsWith(moviePrefix)
            ? _moviePart
                .firstMatch(stem.substring(moviePrefix.length))
                ?.group(1)
            : null;

    return QuarkCatalogItem(
      fid: fid,
      fileName: fileName,
      relativePath:
          [...directories.skip(1).map((dir) => dir.name), fileName].join('/'),
      size: size,
      modifiedAt: modifiedAt,
      addedAt: addedAt,
      workKey: useDirectory
          ? 'folder:${workDirectory.fid}'
          : 'name:${workDirectory.fid}:${title.toLowerCase()}:$year:$isSeries',
      title: title.isEmpty ? stem : title,
      year: year,
      season: season,
      episode: episode,
      part: part,
      episodeTitle: episodeName?.group(5)?.trim(),
    );
  }

  static String _stripYear(String name) =>
      name.replaceFirst(_yearSuffix, '').trim();
}
