import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../../features/editor/models/sound_effect_library_asset.dart';

/// Searches Openverse's keyless audio catalog for commercially usable SFX.
///
/// Calls are made only when [search] is explicitly invoked. In particular,
/// an empty query is rejected before any network request so opening a library
/// sheet cannot consume Openverse's anonymous request allowance.
class OpenverseSfxService {
  static const String defaultBaseUrl = 'https://api.openverse.org/v1/';
  static const int maximumPageSize = 20;
  static const Duration metadataCacheLifetime = Duration(hours: 1);
  static const int maximumCachedSearches = 100;
  static const Set<String> allowedLicenseCodes = {'cc0', 'pdm', 'by'};
  static final Map<String, _OpenverseCacheEntry> _metadataCache = {};

  final Dio _client;
  final Uri _baseUri;
  final bool _ownsClient;

  OpenverseSfxService({Dio? client, String baseUrl = defaultBaseUrl})
    : _client = client ?? _createClient(),
      _baseUri = _parseBaseUrl(baseUrl),
      _ownsClient = client == null;

  Future<List<SoundEffectLibraryAsset>> search({
    required String query,
    OpenverseLicenseFilter filter = OpenverseLicenseFilter.allUsable,
    int page = 1,
    int limit = maximumPageSize,
    CancelToken? cancelToken,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      throw ArgumentError.value(query, 'query', 'Must not be empty.');
    }

    final safePage = math.max(1, page);
    final safeLimit = limit.clamp(1, maximumPageSize);
    final cacheKey = [
      _baseUri,
      normalizedQuery.toLowerCase(),
      filter.name,
      safePage,
      safeLimit,
    ].join('|');
    final now = DateTime.now().toUtc();
    _metadataCache.removeWhere(
      (_, entry) => now.difference(entry.storedAt) >= metadataCacheLifetime,
    );
    final cached = _metadataCache[cacheKey];
    if (cached != null) return cached.assets;

    final uri = _baseUri
        .resolve('audio/')
        .replace(
          queryParameters: {
            'q': normalizedQuery,
            'category': 'sound_effect',
            'mature': 'false',
            'filter_dead': 'true',
            'license': _licenseCodes(filter),
            'page': '$safePage',
            'page_size': '$safeLimit',
          },
        );

    final response = await _client.getUri(uri, cancelToken: cancelToken);
    final body = _asMap(response.data);
    final rawResults = body?['results'];
    if (rawResults is! List) return const [];

    final assets = rawResults
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(_parseAsset)
        .whereType<SoundEffectLibraryAsset>()
        .where((asset) => _licenseMatchesFilter(asset.licenseCode, filter))
        .take(safeLimit)
        .toList(growable: false);
    final cachedAssets = List<SoundEffectLibraryAsset>.unmodifiable(assets);
    _metadataCache[cacheKey] = _OpenverseCacheEntry(
      storedAt: now,
      assets: cachedAssets,
    );
    if (_metadataCache.length > maximumCachedSearches) {
      final oldest = _metadataCache.entries.reduce(
        (first, second) => first.value.storedAt.isBefore(second.value.storedAt)
            ? first
            : second,
      );
      _metadataCache.remove(oldest.key);
    }
    return cachedAssets;
  }

  SoundEffectLibraryAsset? _parseAsset(Map<String, dynamic> item) {
    final providerId = _stringValue(item['id']);
    if (providerId == null) return null;

    final selectedFile = _selectAudioFile(item);
    if (selectedFile == null) return null;

    final licenseCode =
        _stringValue(item['license'])?.toLowerCase() ?? 'unknown';
    if (!allowedLicenseCodes.contains(licenseCode)) return null;
    final title = _stringValue(item['title']) ?? 'Openverse sound effect';
    final creatorName = _stringValue(item['creator']);
    final licenseUrl = _webUrl(item['license_url']);
    final sourcePageUrl = _webUrl(item['foreign_landing_url']);
    final suppliedAttribution = _stringValue(item['attribution']);
    if (licenseCode == 'by' &&
        (creatorName == null ||
            licenseUrl == null ||
            sourcePageUrl == null ||
            suppliedAttribution == null)) {
      return null;
    }
    final sourceName =
        _stringValue(item['source']) ??
        _stringValue(item['provider']) ??
        'Openverse';
    final attribution =
        suppliedAttribution ??
        _fallbackAttribution(
          title: title,
          creatorName: creatorName,
          licenseCode: licenseCode,
          sourceName: sourceName,
        );

    return SoundEffectLibraryAsset(
      id: 'openverse-$providerId',
      title: title,
      previewUrl: selectedFile.url,
      downloadUrl: selectedFile.url,
      provider: SoundEffectLibraryProvider.openverse,
      duration: _durationMilliseconds(item['duration']),
      fileSizeBytes:
          selectedFile.fileSizeBytes ?? _nonNegativeInt(item['filesize']),
      fileExtension: selectedFile.extension,
      attribution: attribution,
      licenseCode: licenseCode,
      licenseVersion: _stringValue(item['license_version']),
      licenseUrl: licenseUrl,
      sourceName: sourceName,
      sourcePageUrl: sourcePageUrl,
      creatorName: creatorName,
      creatorPageUrl: _webUrl(item['creator_url']),
      tags: List<String>.unmodifiable(_parseTags(item['tags'])),
      thumbnailUrl: _webUrl(item['thumbnail']),
      waveformUrl: _webUrl(item['waveform']),
    );
  }

  _OpenverseAudioFile? _selectAudioFile(Map<String, dynamic> item) {
    final alternatives = _audioFiles(item['alt_files']);

    // Openverse can expose a consistent MP3 preview alongside a source file in
    // a less portable format. Prefer that MP3 for editor playback and import.
    for (final alternative in alternatives) {
      if (alternative.extension == 'mp3') return alternative;
    }

    final mainFile = _parseAudioFile(
      urlValue: item['url'],
      typeValue: item['filetype'],
      fileSizeValue: item['filesize'],
    );
    if (mainFile != null) return mainFile;

    // Some providers omit the main file URL but still supply a usable
    // alternative. Retain that final standards-compliant fallback.
    return alternatives.firstOrNull;
  }

  List<_OpenverseAudioFile> _audioFiles(dynamic value) {
    final candidates = <Map<String, dynamic>>[];
    if (value is List) {
      candidates.addAll(value.map(_asMap).whereType<Map<String, dynamic>>());
    } else {
      final map = _asMap(value);
      if (map != null) {
        for (final entry in map.entries) {
          final nested = _asMap(entry.value);
          if (nested != null) {
            candidates.add({
              ...nested,
              if (!nested.containsKey('filetype')) 'filetype': entry.key,
            });
          } else if (entry.value is String) {
            candidates.add({'url': entry.value, 'filetype': entry.key});
          }
        }
      }
    }

    return candidates
        .map(
          (candidate) => _parseAudioFile(
            urlValue: candidate['url'],
            typeValue:
                candidate['filetype'] ??
                candidate['file_type'] ??
                candidate['format'],
            fileSizeValue: candidate['filesize'] ?? candidate['file_size'],
          ),
        )
        .whereType<_OpenverseAudioFile>()
        .toList(growable: false);
  }

  _OpenverseAudioFile? _parseAudioFile({
    required dynamic urlValue,
    required dynamic typeValue,
    required dynamic fileSizeValue,
  }) {
    final rawUrl = _stringValue(urlValue);
    if (rawUrl == null) return null;
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      return null;
    }

    final extension =
        _supportedAudioExtension(typeValue) ??
        _supportedAudioExtension(uri.pathSegments.lastOrNull);
    if (extension == null) return null;

    return _OpenverseAudioFile(
      url: uri.toString(),
      extension: extension,
      fileSizeBytes: _nonNegativeInt(fileSizeValue),
    );
  }

  static String _licenseCodes(OpenverseLicenseFilter filter) =>
      switch (filter) {
        OpenverseLicenseFilter.allUsable => 'cc0,pdm,by',
        OpenverseLicenseFilter.publicDomain => 'cc0,pdm',
        OpenverseLicenseFilter.attribution => 'by',
      };

  static bool _licenseMatchesFilter(
    String licenseCode,
    OpenverseLicenseFilter filter,
  ) => switch (filter) {
    OpenverseLicenseFilter.allUsable => allowedLicenseCodes.contains(
      licenseCode,
    ),
    OpenverseLicenseFilter.publicDomain => const {
      'cc0',
      'pdm',
    }.contains(licenseCode),
    OpenverseLicenseFilter.attribution => licenseCode == 'by',
  };

  void close() {
    if (_ownsClient) _client.close(force: true);
  }

  static Dio _createClient() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  static Uri _parseBaseUrl(String value) {
    final normalized = '${value.trim().replaceFirst(RegExp(r'/+$'), '')}/';
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      throw ArgumentError.value(value, 'baseUrl', 'Must be an absolute URL.');
    }
    return uri;
  }
}

class _OpenverseAudioFile {
  final String url;
  final String extension;
  final int? fileSizeBytes;

  const _OpenverseAudioFile({
    required this.url,
    required this.extension,
    required this.fileSizeBytes,
  });
}

class _OpenverseCacheEntry {
  final DateTime storedAt;
  final List<SoundEffectLibraryAsset> assets;

  const _OpenverseCacheEntry({required this.storedAt, required this.assets});
}

Map<String, dynamic>? _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String? _stringValue(dynamic value) {
  if (value == null) return null;
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

String? _webUrl(dynamic value) {
  final raw = _stringValue(value);
  if (raw == null) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty) {
    return null;
  }
  return uri.toString();
}

int? _nonNegativeInt(dynamic value) {
  final parsed = switch (value) {
    int number => number,
    num number => number.round(),
    _ => int.tryParse(value?.toString() ?? ''),
  };
  return parsed == null || parsed < 0 ? null : parsed;
}

Duration? _durationMilliseconds(dynamic value) {
  final milliseconds = switch (value) {
    num number => number.toDouble(),
    _ => double.tryParse(value?.toString() ?? ''),
  };
  if (milliseconds == null || !milliseconds.isFinite || milliseconds < 0) {
    return null;
  }
  return Duration(milliseconds: milliseconds.round());
}

String? _supportedAudioExtension(dynamic value) {
  var normalized = _stringValue(value)?.toLowerCase();
  if (normalized == null) return null;
  normalized = normalized.split(';').first.trim();
  if (normalized.contains('/')) normalized = normalized.split('/').last;
  if (normalized.contains('.')) normalized = normalized.split('.').last;
  return switch (normalized) {
    'mpeg' || 'mpeg3' || 'mp3' => 'mp3',
    'wave' || 'x-wav' || 'wav' => 'wav',
    'vorbis' || 'ogg' => 'ogg',
    'x-flac' || 'flac' => 'flac',
    'mp4' || 'x-m4a' || 'm4a' => 'm4a',
    'x-aac' || 'aac' => 'aac',
    _ => null,
  };
}

List<String> _parseTags(dynamic value) {
  final rawTags = value is List ? value : const [];
  final tags = <String>[];
  final seen = <String>{};
  for (final rawTag in rawTags) {
    final tag = rawTag is Map
        ? _stringValue(_asMap(rawTag)?['name'])
        : _stringValue(rawTag);
    if (tag == null) continue;
    final normalized = tag.toLowerCase();
    if (seen.add(normalized)) tags.add(tag);
  }
  return tags;
}

String _fallbackAttribution({
  required String title,
  required String? creatorName,
  required String licenseCode,
  required String sourceName,
}) {
  final creator = creatorName == null ? '' : ' by $creatorName';
  return '"$title"$creator via $sourceName ($licenseCode)';
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
  T? get lastOrNull => isEmpty ? null : last;
}
