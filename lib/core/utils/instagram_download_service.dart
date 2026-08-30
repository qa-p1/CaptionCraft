import 'dart:convert';

import 'package:dio/dio.dart';

import '../../features/editor/models/discover_models.dart';

typedef InstagramPageLoader = Future<String> Function(Uri uri);

abstract class InstagramMediaService {
  Future<InstagramPostInfo> inspect(String url);

  void dispose();
}

class InstagramDownloadService implements InstagramMediaService {
  InstagramDownloadService({Dio? dio, InstagramPageLoader? pageLoader})
    : _dio = dio ?? Dio(),
      _pageLoader = pageLoader;

  static const int _maximumPageCharacters = 4 * 1024 * 1024;
  static const int _maximumMediaItems = 24;
  static const String browserUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

  final Dio _dio;
  final InstagramPageLoader? _pageLoader;
  bool _disposed = false;

  static ({String shortcode, Uri canonicalUri, bool isReel})? parseUrl(
    String value,
  ) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        !_instagramHosts.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final segments = uri.pathSegments
        .where((segment) => segment.trim().isNotEmpty)
        .toList(growable: false);
    if (segments.length < 2) return null;
    final route = segments.first.toLowerCase();
    if (!const {'p', 'reel', 'reels', 'tv'}.contains(route)) return null;
    final shortcode = segments[1];
    if (!RegExp(r'^[A-Za-z0-9_-]{5,64}$').hasMatch(shortcode)) return null;
    final normalizedRoute = route == 'reels' ? 'reel' : route;
    return (
      shortcode: shortcode,
      canonicalUri: Uri.https(
        'www.instagram.com',
        '/$normalizedRoute/$shortcode/',
      ),
      isReel: normalizedRoute == 'reel' || normalizedRoute == 'tv',
    );
  }

  static Map<String, String> downloadHeaders(String canonicalUrl) {
    return <String, String>{
      'User-Agent': browserUserAgent,
      'Accept': '*/*',
      'Referer': canonicalUrl,
    };
  }

  @override
  Future<InstagramPostInfo> inspect(String url) async {
    _ensureNotDisposed();
    final parsed = parseUrl(url);
    if (parsed == null) {
      throw const FormatException('Enter a valid Instagram Reel or post URL.');
    }

    final body = await _loadPage(parsed.canonicalUri);
    if (body.isEmpty || body.length > _maximumPageCharacters) {
      throw StateError('Instagram returned an invalid media page.');
    }
    final metadata = _openGraphMetadata(body);
    final title = _boundedText(
      metadata['og:title'] ?? metadata['twitter:title'],
      fallback: parsed.isReel ? 'Instagram Reel' : 'Instagram post',
    );
    final author = _authorFromTitle(title);
    final thumbnail = _safeHttpsUrl(
      metadata['og:image:secure_url'] ??
          metadata['og:image'] ??
          metadata['twitter:image'],
    );
    final media = _extractMedia(
      body: body,
      metadata: metadata,
      shortcode: parsed.shortcode,
      thumbnailUrl: thumbnail,
      isReel: parsed.isReel,
    );
    if (media.isEmpty ||
        (parsed.isReel &&
            !media.any((item) => item.kind == DiscoverMediaKind.video))) {
      throw StateError(
        'No downloadable media was exposed for this public Instagram link. '
        'Private, login-only, expired, or unsupported posts cannot be downloaded.',
      );
    }
    return InstagramPostInfo(
      shortcode: parsed.shortcode,
      canonicalUrl: parsed.canonicalUri.toString(),
      title: title,
      author: author,
      isReel: parsed.isReel,
      thumbnailUrl: thumbnail,
      media: List<InstagramMediaOption>.unmodifiable(media),
    );
  }

  Future<String> _loadPage(Uri uri) async {
    final loader = _pageLoader;
    if (loader != null) return loader(uri);
    try {
      final response = await _dio.get<String>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          maxRedirects: 5,
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 20),
          headers: const <String, String>{
            'User-Agent': browserUserAgent,
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.8',
          },
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
      return response.data ?? '';
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw StateError(
        status == null
            ? 'Instagram could not be reached. Check the connection and retry.'
            : 'Instagram rejected the media request (HTTP $status).',
      );
    }
  }

  static Map<String, String> _openGraphMetadata(String body) {
    final result = <String, String>{};
    final tags = RegExp(
      r'<meta\b[^>]*>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(body);
    for (final tagMatch in tags.take(600)) {
      final tag = tagMatch.group(0) ?? '';
      final attributes = <String, String>{};
      for (final match in RegExp(
        r'([:\w-]+)\s*=\s*"([^"]*)"',
        caseSensitive: false,
        dotAll: true,
      ).allMatches(tag)) {
        attributes[match.group(1)!.toLowerCase()] = _decodeHtml(
          match.group(2)!,
        );
      }
      for (final match in RegExp(
        r"([:\w-]+)\s*=\s*'([^']*)'",
        caseSensitive: false,
        dotAll: true,
      ).allMatches(tag)) {
        attributes.putIfAbsent(
          match.group(1)!.toLowerCase(),
          () => _decodeHtml(match.group(2)!),
        );
      }
      final key = (attributes['property'] ?? attributes['name'])?.toLowerCase();
      final content = attributes['content'];
      if (key != null && content != null && content.isNotEmpty) {
        result.putIfAbsent(key, () => content);
      }
    }
    return result;
  }

  static List<InstagramMediaOption> _extractMedia({
    required String body,
    required Map<String, String> metadata,
    required String shortcode,
    required String? thumbnailUrl,
    required bool isReel,
  }) {
    final candidates = <({String url, DiscoverMediaKind kind})>[];
    final seen = <String>{};

    void add(String? rawUrl, DiscoverMediaKind kind) {
      final url = _safeHttpsUrl(rawUrl);
      if (url == null || !seen.add(url)) return;
      candidates.add((url: url, kind: kind));
    }

    final serializedUrls = RegExp(
      r'"(video_url|display_url|thumbnail_src)"\s*:\s*"((?:\\.|[^"\\])*)"',
      caseSensitive: false,
    ).allMatches(body);
    for (final match in serializedUrls.take(120)) {
      final key = match.group(1)!.toLowerCase();
      final decoded = _decodeJsonString(match.group(2)!);
      if (key == 'video_url') {
        add(decoded, DiscoverMediaKind.video);
      } else if (key == 'display_url') {
        add(decoded, DiscoverMediaKind.image);
      }
    }

    add(
      metadata['og:video:secure_url'] ??
          metadata['og:video:url'] ??
          metadata['og:video'] ??
          metadata['twitter:player:stream'],
      DiscoverMediaKind.video,
    );
    final hasVideo = candidates.any(
      (candidate) => candidate.kind == DiscoverMediaKind.video,
    );
    if (!isReel && !hasVideo) {
      add(
        metadata['og:image:secure_url'] ??
            metadata['og:image'] ??
            metadata['twitter:image'],
        DiscoverMediaKind.image,
      );
    }

    final filtered = isReel
        ? candidates
              .where((candidate) => candidate.kind == DiscoverMediaKind.video)
              .toList(growable: false)
        : candidates;
    return <InstagramMediaOption>[
      for (final entry in filtered.take(_maximumMediaItems).indexed)
        InstagramMediaOption(
          id: '$shortcode-${entry.$1}',
          url: entry.$2.url,
          kind: entry.$2.kind,
          mimeType: entry.$2.kind == DiscoverMediaKind.video
              ? 'video/mp4'
              : 'image/jpeg',
          thumbnailUrl: entry.$2.kind == DiscoverMediaKind.video
              ? thumbnailUrl
              : entry.$2.url,
        ),
    ];
  }

  static String _decodeJsonString(String value) {
    try {
      final decoded = jsonDecode('"$value"');
      if (decoded is String) return _decodeHtml(decoded);
    } catch (_) {
      // Fall through to the bounded replacement used for malformed pages.
    }
    return _decodeHtml(value.replaceAll(r'\/', '/').replaceAll(r'\u0026', '&'));
  }

  static String _decodeHtml(String value) {
    var decoded = value
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    decoded = decoded.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (match) => String.fromCharCode(int.tryParse(match.group(1)!) ?? 0),
    );
    decoded = decoded.replaceAllMapped(
      RegExp(r'&#x([0-9a-f]+);', caseSensitive: false),
      (match) =>
          String.fromCharCode(int.tryParse(match.group(1)!, radix: 16) ?? 0),
    );
    return decoded;
  }

  static String? _safeHttpsUrl(String? value) {
    if (value == null || value.trim().isEmpty || value.length > 8192) {
      return null;
    }
    final uri = Uri.tryParse(_decodeHtml(value.trim()));
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.hasFragment
        ? uri.replace(fragment: '').toString()
        : uri.toString();
  }

  static String _boundedText(String? value, {required String fallback}) {
    final normalized = value?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    if (normalized.isEmpty) return fallback;
    return normalized.length <= 240
        ? normalized
        : '${normalized.substring(0, 237)}...';
  }

  static String _authorFromTitle(String title) {
    final marker = title.toLowerCase().indexOf(' on instagram');
    if (marker <= 0) return 'Instagram';
    final author = title.substring(0, marker).trim();
    return author.isEmpty || author.length > 100 ? 'Instagram' : author;
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('InstagramDownloadService is disposed.');
  }

  @override
  void dispose() {
    _disposed = true;
  }
}

const Set<String> _instagramHosts = <String>{
  'instagram.com',
  'www.instagram.com',
  'm.instagram.com',
};
