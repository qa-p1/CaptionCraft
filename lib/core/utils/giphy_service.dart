import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../constants/giphy_constants.dart';
import 'api_service_error.dart';

enum GiphySearchKind { gifs, stickers, both }

class GiphyAssetResult {
  final String id;
  final String title;
  final String previewUrl;
  final String originalUrl;
  final String? sourcePageUrl;
  final bool isSticker;
  final int? width;
  final int? height;

  const GiphyAssetResult({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.originalUrl,
    required this.isSticker,
    this.sourcePageUrl,
    this.width,
    this.height,
  });
}

/// GIPHY metadata client with bounded stale-while-error caching.
///
/// Search responses contain only lightweight descriptors. Preview image bytes
/// still use Flutter's image cache, while a selected GIF is materialized into
/// durable project media by [RemoteMediaImportService]. Identical searches are
/// single-flight so opening two pickers cannot spend the same API quota twice.
class GiphyService {
  static const Duration defaultCacheLifetime = Duration(minutes: 30);
  static const int defaultMaximumCachedQueries = 100;

  static final GiphyService shared = GiphyService();

  final Dio _client;
  final String? _suppliedApiKey;
  String get _apiKey => _suppliedApiKey ?? GiphyConstants.apiKey;
  final Uri _baseUri;
  final DateTime Function() _clock;
  final Duration cacheLifetime;
  final int maximumCachedQueries;
  final Map<String, _GiphyCacheEntry> _responseCache = {};
  final Map<String, Future<List<GiphyAssetResult>>> _inFlight = {};

  GiphyService({
    Dio? client,
    String? apiKey,
    String? baseUrl,
    DateTime Function()? clock,
    this.cacheLifetime = defaultCacheLifetime,
    this.maximumCachedQueries = defaultMaximumCachedQueries,
  }) : assert(!cacheLifetime.isNegative),
       assert(maximumCachedQueries > 0),
       _client = client ?? _createClient(),
       _suppliedApiKey = apiKey?.trim(),
       _baseUri = _parseBaseUrl(baseUrl ?? GiphyConstants.baseUrl),
       _clock = clock ?? DateTime.now;

  Future<List<GiphyAssetResult>> search({
    required String query,
    required GiphySearchKind kind,
    int limit = GiphyConstants.defaultLimit,
    bool forceRefresh = false,
  }) async {
    _ensureApiKey();
    final normalizedQuery = query.trim();
    final safeLimit = limit.clamp(1, 25);
    final cacheKey = [
      _baseUri,
      sha256.convert(utf8.encode(_apiKey)),
      normalizedQuery.toLowerCase(),
      kind.name,
      safeLimit,
    ].join('|');
    final now = _clock().toUtc();
    final cached = _responseCache[cacheKey];
    if (!forceRefresh &&
        cached != null &&
        now.difference(cached.storedAt) < cacheLifetime) {
      cached.lastAccessedAt = now;
      return cached.assets;
    }

    final active = _inFlight[cacheKey];
    if (active != null) return active;

    final operation = () async {
      try {
        final fetched = await _searchUncached(
          query: normalizedQuery,
          kind: kind,
          limit: safeLimit,
        );
        final immutable = List<GiphyAssetResult>.unmodifiable(fetched);
        _responseCache[cacheKey] = _GiphyCacheEntry(
          storedAt: now,
          lastAccessedAt: now,
          assets: immutable,
        );
        _evictLeastRecentlyUsed();
        return immutable;
      } catch (_) {
        // An expired result is safer and much friendlier than replacing a grid
        // with a transient network error. Explicit refresh still reports the
        // error when this query has never succeeded.
        if (cached != null) {
          cached.lastAccessedAt = now;
          return cached.assets;
        }
        rethrow;
      }
    }();
    _inFlight[cacheKey] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[cacheKey], operation)) {
        _inFlight.remove(cacheKey);
      }
    }
  }

  Future<List<GiphyAssetResult>> _searchUncached({
    required String query,
    required GiphySearchKind kind,
    required int limit,
  }) async {
    if (kind != GiphySearchKind.both) {
      return _fetchCollection(kind: kind, query: query, limit: limit);
    }

    final gifLimit = (limit / 2).ceil();
    final stickerLimit = limit - gifLimit;
    final responses = await Future.wait<List<GiphyAssetResult>>([
      _fetchCollection(
        kind: GiphySearchKind.gifs,
        query: query,
        limit: gifLimit,
      ),
      if (stickerLimit > 0)
        _fetchCollection(
          kind: GiphySearchKind.stickers,
          query: query,
          limit: stickerLimit,
        )
      else
        Future<List<GiphyAssetResult>>.value(const []),
    ]);
    final unique = <String, GiphyAssetResult>{};
    for (final result in [...responses.first, ...responses.last]) {
      unique.putIfAbsent(
        '${result.isSticker ? 'sticker' : 'gif'}:${result.id}',
        () => result,
      );
      if (unique.length >= limit) break;
    }
    return unique.values.toList(growable: false);
  }

  Future<List<GiphyAssetResult>> _fetchCollection({
    required GiphySearchKind kind,
    required String query,
    required int limit,
  }) async {
    if (limit <= 0) return const [];
    final typeSegment = kind == GiphySearchKind.stickers ? 'stickers' : 'gifs';
    final isTrending = query.isEmpty;
    final endpoint = isTrending
        ? '$typeSegment/trending'
        : '$typeSegment/search';
    final uri = _baseUri
        .resolve(endpoint)
        .replace(
          queryParameters: {
            'api_key': _apiKey,
            'limit': '${limit.clamp(1, 25)}',
            'rating': 'pg-13',
            if (!isTrending) 'q': query,
          },
        );
    final Response<dynamic> response;
    try {
      response = await _client.getUri<dynamic>(
        uri,
        options: Options(followRedirects: false),
      );
    } on DioException catch (error) {
      throw Exception(apiServiceError('GIPHY', error));
    }
    final body = _asMap(response.data);
    final data = body?['data'];
    if (data is! List) return const [];
    return data
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map((item) => _parseAsset(item, kind))
        .whereType<GiphyAssetResult>()
        .take(limit)
        .toList(growable: false);
  }

  GiphyAssetResult? _parseAsset(
    Map<String, dynamic> item,
    GiphySearchKind kind,
  ) {
    final id = _stringValue(item['id']);
    final images = _asMap(item['images']);
    if (id == null || images == null) return null;

    final preview = _firstMap(images, const [
      'fixed_width_small',
      'fixed_width_downsampled',
      'fixed_width',
      'downsized_small',
      'downsized',
      'original',
    ]);
    final original = _firstMap(images, const [
      'original',
      'downsized_large',
      'downsized',
      'fixed_width',
    ]);
    final previewUrl = _firstSecureUrl([
      preview?['webp'],
      preview?['url'],
      original?['webp'],
      original?['url'],
    ]);
    final originalUrl = _firstSecureUrl([
      original?['url'],
      original?['webp'],
      preview?['url'],
      preview?['webp'],
    ]);
    if (previewUrl == null || originalUrl == null) return null;

    final isSticker = kind == GiphySearchKind.stickers;
    final title = _stringValue(item['title']);
    return GiphyAssetResult(
      id: id,
      title: title ?? (isSticker ? 'Sticker' : 'GIF'),
      previewUrl: previewUrl,
      originalUrl: originalUrl,
      sourcePageUrl: _firstSecureUrl([item['url'], item['bitly_url']]),
      isSticker: isSticker,
      width: _positiveInt(original?['width'] ?? preview?['width']),
      height: _positiveInt(original?['height'] ?? preview?['height']),
    );
  }

  void _evictLeastRecentlyUsed() {
    while (_responseCache.length > maximumCachedQueries) {
      final oldest = _responseCache.entries.reduce(
        (first, second) =>
            first.value.lastAccessedAt.isBefore(second.value.lastAccessedAt)
            ? first
            : second,
      );
      _responseCache.remove(oldest.key);
    }
  }

  void _ensureApiKey() {
    if (_apiKey.isEmpty) {
      throw StateError(
        'Add your GIPHY API key in Settings → Connected services.',
      );
    }
  }

  @visibleForTesting
  int get cachedQueryCount => _responseCache.length;

  @visibleForTesting
  void clearCache() {
    _responseCache.clear();
    _inFlight.clear();
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
    final loopback = const {
      'localhost',
      '127.0.0.1',
      '::1',
    }.contains(uri.host.toLowerCase());
    if (uri.scheme != 'https' && !loopback) {
      throw ArgumentError.value(value, 'baseUrl', 'GIPHY requires HTTPS.');
    }
    return uri;
  }
}

Map<String, dynamic>? _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

Map<String, dynamic>? _firstMap(
  Map<String, dynamic> values,
  Iterable<String> keys,
) {
  for (final key in keys) {
    final value = _asMap(values[key]);
    if (value != null) return value;
  }
  return null;
}

String? _stringValue(dynamic value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String? _firstSecureUrl(Iterable<dynamic> values) {
  for (final value in values) {
    final text = _stringValue(value);
    final uri = text == null ? null : Uri.tryParse(text);
    if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
      return uri.toString();
    }
  }
  return null;
}

int? _positiveInt(dynamic value) {
  final parsed = value is int
      ? value
      : value is num
      ? value.round()
      : int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}

class _GiphyCacheEntry {
  final DateTime storedAt;
  DateTime lastAccessedAt;
  final List<GiphyAssetResult> assets;

  _GiphyCacheEntry({
    required this.storedAt,
    required this.lastAccessedAt,
    required this.assets,
  });
}
