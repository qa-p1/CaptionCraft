import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../../features/editor/models/element_library_asset.dart';
import '../constants/pexels_constants.dart';

enum PexelsMediaFilter { all, photos, videos }

class PexelsService {
  final Dio _client;
  final String _apiKey;
  final Uri _baseUri;
  final bool _ownsClient;
  bool _closed = false;

  PexelsService({Dio? client, String? apiKey, String? baseUrl})
    : _client = client ?? _createClient(),
      _apiKey = (apiKey ?? PexelsConstants.apiKey).trim(),
      _baseUri = _parseBaseUrl(baseUrl ?? PexelsConstants.baseUrl),
      _ownsClient = client == null;

  Future<List<ElementLibraryAsset>> search({
    String query = '',
    PexelsMediaFilter filter = PexelsMediaFilter.all,
    int page = 1,
    int limit = PexelsConstants.defaultLimit,
  }) async {
    _ensureOpen();
    _ensureApiKey();
    final normalizedQuery = query.trim();
    final safePage = math.max(1, page);
    final safeLimit = limit.clamp(1, PexelsConstants.maximumLimit);

    switch (filter) {
      case PexelsMediaFilter.photos:
        return _fetchPhotos(
          query: normalizedQuery,
          page: safePage,
          limit: safeLimit,
        );
      case PexelsMediaFilter.videos:
        return _fetchVideos(
          query: normalizedQuery,
          page: safePage,
          limit: safeLimit,
        );
      case PexelsMediaFilter.all:
        final photoLimit = math.max(1, (safeLimit / 2).ceil());
        final videoLimit = math.max(1, safeLimit ~/ 2);
        final collections = await Future.wait([
          _fetchPhotos(
            query: normalizedQuery,
            page: safePage,
            limit: photoLimit,
          ),
          _fetchVideos(
            query: normalizedQuery,
            page: safePage,
            limit: videoLimit,
          ),
        ]);
        return [
          ...collections.first,
          ...collections.last,
        ].take(safeLimit).toList(growable: false);
    }
  }

  Future<List<ElementLibraryAsset>> _fetchPhotos({
    required String query,
    required int page,
    required int limit,
  }) async {
    final response = await _get(
      query.isEmpty ? 'curated' : 'search',
      queryParameters: {
        'page': page,
        'per_page': limit,
        if (query.isNotEmpty) 'query': query,
      },
    );
    final body = _asMap(response.data);
    final items = body?['photos'] as List<dynamic>? ?? const [];
    return items
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(_parsePhoto)
        .whereType<ElementLibraryAsset>()
        .toList(growable: false);
  }

  Future<List<ElementLibraryAsset>> _fetchVideos({
    required String query,
    required int page,
    required int limit,
  }) async {
    final response = await _get(
      query.isEmpty ? 'videos/popular' : 'videos/search',
      queryParameters: {
        'page': page,
        'per_page': limit,
        if (query.isNotEmpty) 'query': query,
      },
    );
    final body = _asMap(response.data);
    final items = body?['videos'] as List<dynamic>? ?? const [];
    return items
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(_parseVideo)
        .whereType<ElementLibraryAsset>()
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
    return _client.getUri(
      uri,
      options: Options(headers: {'Authorization': _apiKey}),
    );
  }

  ElementLibraryAsset? _parsePhoto(Map<String, dynamic> item) {
    final providerId = _stringValue(item['id']);
    final source = _stringValue(item['url']);
    final creatorName = _stringValue(item['photographer']);
    final src = _asMap(item['src']);
    final previewUrl = _firstString([
      src?['medium'],
      src?['small'],
      src?['large'],
      src?['original'],
    ]);
    final downloadUrl = _firstString([
      src?['original'],
      src?['large2x'],
      src?['large'],
      previewUrl,
    ]);
    if (providerId == null || previewUrl == null || downloadUrl == null) {
      return null;
    }

    return ElementLibraryAsset(
      id: 'pexels-photo-$providerId',
      title:
          _stringValue(item['alt']) ??
          (creatorName == null ? 'Pexels photo' : 'Photo by $creatorName'),
      previewUrl: previewUrl,
      downloadUrl: downloadUrl,
      provider: ElementLibraryProvider.pexels,
      mediaKind: ElementLibraryMediaKind.image,
      subtype: ElementLibraryAssetSubtype.photo,
      width: _intValue(item['width']),
      height: _intValue(item['height']),
      attribution: creatorName == null
          ? 'Photo on Pexels'
          : 'Photo by $creatorName on Pexels',
      sourcePageUrl: source,
      creatorId: _stringValue(item['photographer_id']),
      creatorName: creatorName,
      creatorPageUrl: _stringValue(item['photographer_url']),
    );
  }

  ElementLibraryAsset? _parseVideo(Map<String, dynamic> item) {
    final providerId = _stringValue(item['id']);
    final creator = _asMap(item['user']);
    final creatorName = _stringValue(creator?['name']);
    final rendition = _selectPracticalMp4(item['video_files']);
    final downloadUrl = _stringValue(rendition?['link']);
    final previewUrl = _firstString([
      item['image'],
      _firstVideoPicture(item['video_pictures']),
    ]);
    if (providerId == null || previewUrl == null || downloadUrl == null) {
      return null;
    }

    return ElementLibraryAsset(
      id: 'pexels-video-$providerId',
      title: creatorName == null ? 'Pexels video' : 'Video by $creatorName',
      previewUrl: previewUrl,
      downloadUrl: downloadUrl,
      provider: ElementLibraryProvider.pexels,
      mediaKind: ElementLibraryMediaKind.video,
      subtype: ElementLibraryAssetSubtype.video,
      width: _intValue(rendition?['width']) ?? _intValue(item['width']),
      height: _intValue(rendition?['height']) ?? _intValue(item['height']),
      duration: _durationValue(item['duration']),
      attribution: creatorName == null
          ? 'Video on Pexels'
          : 'Video by $creatorName on Pexels',
      sourcePageUrl: _stringValue(item['url']),
      creatorId: _stringValue(creator?['id']),
      creatorName: creatorName,
      creatorPageUrl: _stringValue(creator?['url']),
    );
  }

  Map<String, dynamic>? _selectPracticalMp4(dynamic value) {
    final candidates = (value as List<dynamic>? ?? const [])
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .where((candidate) {
          final link = _stringValue(candidate['link']);
          if (link == null) return false;
          final fileType = _stringValue(candidate['file_type'])?.toLowerCase();
          return fileType == 'video/mp4' ||
              Uri.tryParse(link)?.path.toLowerCase().endsWith('.mp4') == true;
        })
        .toList(growable: false);
    if (candidates.isEmpty) return null;

    final sized = candidates
        .where((candidate) {
          return (_intValue(candidate['width']) ?? 0) > 0 &&
              (_intValue(candidate['height']) ?? 0) > 0;
        })
        .toList(growable: false);
    if (sized.isEmpty) return candidates.first;

    final practical = sized
        .where((candidate) {
          final width = _intValue(candidate['width'])!;
          final height = _intValue(candidate['height'])!;
          return math.max(width, height) <= 1920;
        })
        .toList(growable: false);
    final pool = practical.isEmpty ? sized : practical;
    return pool.reduce((selected, candidate) {
      final selectedPixels =
          _intValue(selected['width'])! * _intValue(selected['height'])!;
      final candidatePixels =
          _intValue(candidate['width'])! * _intValue(candidate['height'])!;
      if (practical.isEmpty) {
        return candidatePixels < selectedPixels ? candidate : selected;
      }
      return candidatePixels > selectedPixels ? candidate : selected;
    });
  }

  String? _firstVideoPicture(dynamic value) {
    final pictures = value as List<dynamic>? ?? const [];
    for (final picture in pictures) {
      final url = _stringValue(_asMap(picture)?['picture']);
      if (url != null) return url;
    }
    return null;
  }

  void _ensureApiKey() {
    if (_apiKey.isEmpty) {
      throw StateError('Missing PEXELS_API_KEY configuration.');
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('PexelsService is closed.');
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
