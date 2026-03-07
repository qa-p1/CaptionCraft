import 'package:dio/dio.dart';

import '../constants/giphy_constants.dart';

enum GiphySearchKind { gifs, stickers, both }

class GiphyAssetResult {
  final String id;
  final String title;
  final String previewUrl;
  final String originalUrl;
  final bool isSticker;
  final int? width;
  final int? height;

  const GiphyAssetResult({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.originalUrl,
    required this.isSticker,
    this.width,
    this.height,
  });
}

class GiphyService {
  GiphyService._();

  static final Dio _dio = Dio(
    BaseOptions(
      baseUrl: GiphyConstants.baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  static Future<List<GiphyAssetResult>> search({
    required String query,
    required GiphySearchKind kind,
    int limit = GiphyConstants.defaultLimit,
  }) async {
    _ensureApiKey();
    final normalizedQuery = query.trim();

    if (kind == GiphySearchKind.both) {
      final responses = await Future.wait([
        _fetchCollection(
          kind: GiphySearchKind.gifs,
          query: normalizedQuery,
          limit: (limit / 2).ceil(),
        ),
        _fetchCollection(
          kind: GiphySearchKind.stickers,
          query: normalizedQuery,
          limit: limit ~/ 2,
        ),
      ]);
      return [...responses.first, ...responses.last];
    }

    return _fetchCollection(kind: kind, query: normalizedQuery, limit: limit);
  }

  static Future<List<GiphyAssetResult>> _fetchCollection({
    required GiphySearchKind kind,
    required String query,
    required int limit,
  }) async {
    final typeSegment = kind == GiphySearchKind.stickers ? 'stickers' : 'gifs';
    final isTrending = query.isEmpty;
    final endpoint = isTrending
        ? '/$typeSegment/trending'
        : '/$typeSegment/search';

    final response = await _dio.get(
      endpoint,
      queryParameters: {
        'api_key': GiphyConstants.apiKey,
        'limit': limit.clamp(1, 25),
        'rating': 'pg-13',
        if (!isTrending) 'q': query,
      },
    );

    final data = response.data['data'] as List<dynamic>? ?? const [];
    return data
        .map((item) => _parseAsset(item as Map<String, dynamic>, kind))
        .whereType<GiphyAssetResult>()
        .toList();
  }

  static GiphyAssetResult? _parseAsset(
    Map<String, dynamic> item,
    GiphySearchKind kind,
  ) {
    final images = item['images'] as Map<String, dynamic>? ?? const {};
    final preview =
        (images['fixed_width'] as Map<String, dynamic>?) ??
        (images['downsized'] as Map<String, dynamic>?) ??
        (images['preview_gif'] as Map<String, dynamic>?) ??
        (images['original'] as Map<String, dynamic>?);
    final original = images['original'] as Map<String, dynamic>? ?? preview;
    final previewUrl = preview?['url'] as String?;
    final originalUrl = original?['url'] as String? ?? previewUrl;
    if (previewUrl == null || originalUrl == null) {
      return null;
    }

    return GiphyAssetResult(
      id: item['id'] as String? ?? '',
      title: (item['title'] as String?)?.trim().isNotEmpty == true
          ? (item['title'] as String).trim()
          : (kind == GiphySearchKind.stickers ? 'Sticker' : 'GIF'),
      previewUrl: previewUrl,
      originalUrl: originalUrl,
      isSticker: kind == GiphySearchKind.stickers,
      width: int.tryParse('${preview?['width'] ?? ''}'),
      height: int.tryParse('${preview?['height'] ?? ''}'),
    );
  }

  static void _ensureApiKey() {
    if (GiphyConstants.apiKey.isEmpty) {
      throw Exception('Missing GIPHY_API_KEY in .env');
    }
  }
}
