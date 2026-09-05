import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../../features/editor/models/element_library_asset.dart';
import '../constants/pixabay_constants.dart';

enum PixabayMediaFilter { all, photos, illustrations, vectors, videos }

class PixabayService {
  static const Duration _cacheLifetime = Duration(hours: 24);
  static const int _maximumCachedQueries = 200;
  static final Map<String, _PixabayCacheEntry> _responseCache = {};

  final Dio _client;
  final String _apiKey;
  final Uri _baseUri;
  final bool _ownsClient;
  bool _closed = false;

  PixabayService({Dio? client, String? apiKey, String? baseUrl})
    : _client = client ?? _createClient(),
      _apiKey = (apiKey ?? PixabayConstants.apiKey).trim(),
      _baseUri = _parseBaseUrl(baseUrl ?? PixabayConstants.baseUrl),
      _ownsClient = client == null;

  Future<List<ElementLibraryAsset>> search({
    String query = '',
    PixabayMediaFilter filter = PixabayMediaFilter.all,
    int page = 1,
    int limit = PixabayConstants.defaultLimit,
  }) async {
    _ensureOpen();
    _ensureApiKey();
    final normalizedQuery = query.trim();
    final safePage = math.max(1, page);
    final safeLimit = limit.clamp(1, PixabayConstants.maximumLimit);
    final cacheKey = [
      _baseUri,
      normalizedQuery.toLowerCase(),
      filter.name,
      safePage,
      safeLimit,
    ].join('|');
    final now = DateTime.now().toUtc();
    final cached = _responseCache[cacheKey];
    if (cached != null && now.difference(cached.storedAt) < _cacheLifetime) {
      return cached.assets;
    }

    final assets = await _searchUncached(
      query: normalizedQuery,
      filter: filter,
      page: safePage,
      limit: safeLimit,
    );
    final cachedAssets = List<ElementLibraryAsset>.unmodifiable(assets);
    _responseCache[cacheKey] = _PixabayCacheEntry(
      storedAt: now,
      assets: cachedAssets,
    );
    if (_responseCache.length > _maximumCachedQueries) {
      final oldest = _responseCache.entries.reduce(
        (first, second) => first.value.storedAt.isBefore(second.value.storedAt)
            ? first
            : second,
      );
      _responseCache.remove(oldest.key);
    }
    return cachedAssets;
  }

  Future<List<ElementLibraryAsset>> _searchUncached({
    required String query,
    required PixabayMediaFilter filter,
    required int page,
    required int limit,
  }) async {
    switch (filter) {
      case PixabayMediaFilter.photos:
      case PixabayMediaFilter.illustrations:
      case PixabayMediaFilter.vectors:
        return _fetchImages(
          query: query,
          filter: filter,
          page: page,
          resultLimit: limit,
        );
      case PixabayMediaFilter.videos:
        return _fetchVideos(query: query, page: page, resultLimit: limit);
      case PixabayMediaFilter.all:
        final imageLimit = math.max(1, (limit / 2).ceil());
        final videoLimit = math.max(1, limit ~/ 2);
        final collections = await Future.wait([
          _fetchImages(
            query: query,
            filter: PixabayMediaFilter.all,
            page: page,
            resultLimit: imageLimit,
          ),
          _fetchVideos(query: query, page: page, resultLimit: videoLimit),
        ]);
        return [
          ...collections.first,
          ...collections.last,
        ].take(limit).toList(growable: false);
    }
  }

  Future<List<ElementLibraryAsset>> _fetchImages({
    required String query,
    required PixabayMediaFilter filter,
    required int page,
    required int resultLimit,
  }) async {
    final response = await _get(
      '',
      queryParameters: {
        'key': _apiKey,
        if (query.isNotEmpty) 'q': query,
        'image_type': _imageType(filter),
        'safesearch': true,
        'order': 'popular',
        'page': page,
        'per_page': _apiPageSize(resultLimit),
      },
    );
    final body = _asMap(response.data);
    final items = body?['hits'] as List<dynamic>? ?? const [];
    return items
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(_parseImage)
        .whereType<ElementLibraryAsset>()
        .take(resultLimit)
        .toList(growable: false);
  }

  Future<List<ElementLibraryAsset>> _fetchVideos({
    required String query,
    required int page,
    required int resultLimit,
  }) async {
    final response = await _get(
      'videos/',
      queryParameters: {
        'key': _apiKey,
        if (query.isNotEmpty) 'q': query,
        'safesearch': true,
        'order': 'popular',
        'page': page,
        'per_page': _apiPageSize(resultLimit),
      },
    );
    final body = _asMap(response.data);
    final items = body?['hits'] as List<dynamic>? ?? const [];
    return items
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(_parseVideo)
        .whereType<ElementLibraryAsset>()
        .take(resultLimit)
        .toList(growable: false);
  }

  Future<Response<dynamic>> _get(
    String path, {
    required Map<String, dynamic> queryParameters,
  }) {
    final uri = _baseUri
        .resolve(path)
        .replace(
          queryParameters: queryParameters.map(
            (key, value) => MapEntry(key, value.toString()),
          ),
        );
    return _client.getUri(uri);
  }

  ElementLibraryAsset? _parseImage(Map<String, dynamic> item) {
    final providerId = _stringValue(item['id']);
    final previewUrl = _firstString([
      item['webformatURL'],
      item['previewURL'],
      item['largeImageURL'],
    ]);
    // largeImageURL is a useful raster rendition for every image type,
    // including vectors. Deliberately do not select vectorURL (SVG).
    final downloadUrl = _firstString([
      item['largeImageURL'],
      item['webformatURL'],
      item['previewURL'],
    ]);
    if (providerId == null || previewUrl == null || downloadUrl == null) {
      return null;
    }

    final creatorName = _stringValue(item['user']);
    final creatorId = _stringValue(item['user_id']);
    final subtype = switch (_stringValue(item['type'])?.toLowerCase()) {
      'illustration' => ElementLibraryAssetSubtype.illustration,
      'vector' => ElementLibraryAssetSubtype.vector,
      _ => ElementLibraryAssetSubtype.photo,
    };
    final typeLabel = switch (subtype) {
      ElementLibraryAssetSubtype.illustration => 'Illustration',
      ElementLibraryAssetSubtype.vector => 'Vector',
      _ => 'Image',
    };

    return ElementLibraryAsset(
      id: 'pixabay-image-$providerId',
      title: _stringValue(item['tags']) ?? '$typeLabel on Pixabay',
      previewUrl: previewUrl,
      downloadUrl: downloadUrl,
      provider: ElementLibraryProvider.pixabay,
      mediaKind: ElementLibraryMediaKind.image,
      subtype: subtype,
      width: _intValue(item['imageWidth']) ?? _intValue(item['webformatWidth']),
      height:
          _intValue(item['imageHeight']) ?? _intValue(item['webformatHeight']),
      attribution: creatorName == null
          ? '$typeLabel on Pixabay'
          : '$typeLabel by $creatorName on Pixabay',
      sourcePageUrl: _stringValue(item['pageURL']),
      creatorId: creatorId,
      creatorName: creatorName,
      creatorPageUrl: _pixabayCreatorPage(creatorName, creatorId),
    );
  }

  ElementLibraryAsset? _parseVideo(Map<String, dynamic> item) {
    final providerId = _stringValue(item['id']);
    final rendition = _selectVideoRendition(item['videos']);
    final previewUrl = _stringValue(rendition?['thumbnail']);
    final downloadUrl = _stringValue(rendition?['url']);
    if (providerId == null || previewUrl == null || downloadUrl == null) {
      return null;
    }

    final creatorName = _stringValue(item['user']);
    final creatorId = _stringValue(item['user_id']);
    return ElementLibraryAsset(
      id: 'pixabay-video-$providerId',
      title: _stringValue(item['tags']) ?? 'Video on Pixabay',
      previewUrl: previewUrl,
      downloadUrl: downloadUrl,
      provider: ElementLibraryProvider.pixabay,
      mediaKind: ElementLibraryMediaKind.video,
      subtype: ElementLibraryAssetSubtype.video,
      width: _intValue(rendition?['width']),
      height: _intValue(rendition?['height']),
      duration: _durationValue(item['duration']),
      attribution: creatorName == null
          ? 'Video on Pixabay'
          : 'Video by $creatorName on Pixabay',
      sourcePageUrl: _stringValue(item['pageURL']),
      creatorId: creatorId,
      creatorName: creatorName,
      creatorPageUrl: _pixabayCreatorPage(creatorName, creatorId),
    );
  }

  Map<String, dynamic>? _selectVideoRendition(dynamic value) {
    final videos = _asMap(value);
    if (videos == null) return null;
    for (final key in const ['medium', 'small', 'large', 'tiny']) {
      final rendition = _asMap(videos[key]);
      if (_stringValue(rendition?['url']) != null &&
          _stringValue(rendition?['thumbnail']) != null) {
        return rendition;
      }
    }
    return null;
  }

  String? _pixabayCreatorPage(String? name, String? id) {
    if (name == null || id == null) return null;
    return 'https://pixabay.com/users/${Uri.encodeComponent(name)}-$id/';
  }

  int _apiPageSize(int resultLimit) => resultLimit.clamp(
    PixabayConstants.minimumLimit,
    PixabayConstants.maximumLimit,
  );

  String _imageType(PixabayMediaFilter filter) => switch (filter) {
    PixabayMediaFilter.photos => 'photo',
    PixabayMediaFilter.illustrations => 'illustration',
    PixabayMediaFilter.vectors => 'vector',
    _ => 'all',
  };

  void _ensureApiKey() {
    if (_apiKey.isEmpty) {
      throw StateError('Missing PIXABAY_API_KEY configuration.');
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('PixabayService is closed.');
  }

  /// Cancels requests and releases sockets only when this service created the
  /// underlying client. A caller-injected client remains caller-owned.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close(force: true);
  }

  static Dio _createClient() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  static Uri _parseBaseUrl(String value) {
    final normalized = '${value.trim().replaceFirst(RegExp(r'/+$'), '')}/';
    final uri = Uri.parse(normalized);
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError.value(value, 'baseUrl', 'Must be an absolute URL.');
    }
    return uri;
  }
}

Map<String, dynamic>? _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String? _stringValue(dynamic value) {
  if (value == null) return null;
  final string = value.toString().trim();
  return string.isEmpty ? null : string;
}

String? _firstString(Iterable<dynamic> values) {
  for (final value in values) {
    final string = _stringValue(value);
    if (string != null) return string;
  }
  return null;
}

int? _intValue(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '');
}

Duration? _durationValue(dynamic value) {
  final seconds = value is num ? value.toDouble() : double.tryParse('$value');
  if (seconds == null || !seconds.isFinite || seconds < 0) return null;
  return Duration(milliseconds: (seconds * 1000).round());
}

class _PixabayCacheEntry {
  final DateTime storedAt;
  final List<ElementLibraryAsset> assets;

  const _PixabayCacheEntry({required this.storedAt, required this.assets});
}
