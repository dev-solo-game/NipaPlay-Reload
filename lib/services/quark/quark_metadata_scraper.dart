import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:nipaplay/models/quark/quark_catalog_item.dart';

typedef QuarkWorkMetadata = ({String cover, String summary});
typedef QuarkMetadataCacheEntry = ({
  int checkedAt,
  QuarkWorkMetadata? metadata
});

class QuarkMetadataScraper {
  QuarkMetadataScraper({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
            ));

  final Dio _dio;
  static final _tmdbApiKey = RegExp(r'^[0-9a-fA-F]{32}$');

  static String _normalize(String title) =>
      title.toLowerCase().replaceAll(RegExp(r'[\s·・:：._\-]+'), '');

  static String keyFor(QuarkCatalogItem item, {required bool useTmdb}) =>
      jsonEncode([
        useTmdb ? 'tmdb' : 'bangumi',
        _normalize(item.title),
        item.year,
        item.isSeries
      ]);

  Future<QuarkWorkMetadata?> lookup(QuarkCatalogItem item, String tmdbToken) {
    return tmdbToken.isEmpty
        ? _lookupBangumi(item)
        : _lookupTmdb(item, tmdbToken);
  }

  Future<QuarkWorkMetadata?> _lookupTmdb(
      QuarkCatalogItem item, String credential) async {
    final isSeries = item.isSeries;
    final type = isSeries ? 'tv' : 'movie';
    final isApiKey = _tmdbApiKey.hasMatch(credential);
    final response = await _dio.get<Map<String, dynamic>>(
      'https://api.themoviedb.org/3/search/$type',
      queryParameters: {
        'query': item.title,
        'language': 'zh-CN',
        if (isApiKey) 'api_key': credential,
        if (item.year != null)
          (isSeries ? 'first_air_date_year' : 'primary_release_year'):
              item.year,
      },
      options: Options(
        headers: {if (!isApiKey) 'Authorization': 'Bearer $credential'},
        followRedirects: false,
      ),
    );
    final candidate = _uniqueMatch(
      item,
      response.data?['results'],
      titleKeys:
          isSeries ? ['name', 'original_name'] : ['title', 'original_title'],
      dateKey: isSeries ? 'first_air_date' : 'release_date',
    );
    if (candidate == null) return null;
    final poster = candidate['poster_path'] as String?;
    return (
      cover: poster?.startsWith('/') == true
          ? 'https://image.tmdb.org/t/p/w500$poster'
          : '',
      summary: candidate['overview'] as String? ?? '',
    );
  }

  Future<QuarkWorkMetadata?> _lookupBangumi(QuarkCatalogItem item) async {
    final response = await _dio.post<Map<String, dynamic>>(
      'https://api.bgm.tv/v0/search/subjects',
      queryParameters: {'limit': 12},
      data: {
        'keyword': item.title,
        'filter': {
          'type': [2, 6],
          if (item.year != null)
            'air_date': ['>=${item.year}-01-01', '<${item.year! + 1}-01-01'],
        },
      },
      options: Options(headers: {
        'User-Agent':
            'NipaPlay (https://github.com/dev-solo-game/NipaPlay-Reload)'
      }),
    );
    final candidate = _uniqueMatch(
      item,
      response.data?['data'],
      titleKeys: ['name', 'name_cn'],
      dateKey: 'date',
    );
    if (candidate == null) return null;
    final images = candidate['images'] as Map?;
    return (
      cover: (images?['large'] ?? images?['common'])?.toString() ?? '',
      summary: candidate['summary'] as String? ?? '',
    );
  }

  Map<String, dynamic>? _uniqueMatch(
    QuarkCatalogItem item,
    Object? results, {
    required List<String> titleKeys,
    required String dateKey,
  }) {
    if (results is! List) return null;
    final title = _normalize(item.title);
    final matches = results
        .whereType<Map<String, dynamic>>()
        .where((candidate) {
          final date = candidate[dateKey] as String?;
          if (item.year != null && date?.startsWith('${item.year}-') != true) {
            return false;
          }
          return titleKeys.any(
              (key) => _normalize(candidate[key] as String? ?? '') == title);
        })
        .take(2)
        .toList();
    return matches.length == 1 ? matches.single : null;
  }
}
