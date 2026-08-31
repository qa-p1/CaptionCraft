import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../features/editor/models/discover_models.dart';

typedef InstagramPageLoader = Future<String> Function(Uri uri);

enum InstagramFailureKind {
  invalidUrl,
  unavailable,
  privateOrLoginRequired,
  accessBlocked,
  rateLimited,
  timedOut,
  network,
  unsupported,
  disposed,
}

class InstagramDownloadException implements Exception {
  const InstagramDownloadException(this.kind, this.message, {this.statusCode});

  final InstagramFailureKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

abstract class InstagramMediaService {
  Future<InstagramPostInfo> inspect(String url);

  void dispose();
}

class InstagramDownloadService implements InstagramMediaService {
  InstagramDownloadService({
    Dio? dio,
    InstagramPageLoader? pageLoader,
    this.pageRequestTimeout = const Duration(seconds: 12),
  }) : _dio = dio ?? Dio(BaseOptions(connectTimeout: pageRequestTimeout)),
       _ownsDio = dio == null,
       _pageLoader = pageLoader;

  static const int _maximumPageCharacters = 4 * 1024 * 1024;
  static const int _maximumMediaItems = 24;
  static const String browserUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

  final Dio _dio;
  final bool _ownsDio;
  final InstagramPageLoader? _pageLoader;
  final Duration pageRequestTimeout;
  final Set<CancelToken> _activeRequests = <CancelToken>{};
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
      'Origin': 'https://www.instagram.com',
    };
  }

  @override
  Future<InstagramPostInfo> inspect(String url) async {
    _ensureNotDisposed();
    final parsed = parseUrl(url);
    if (parsed == null) {
      throw const InstagramDownloadException(
        InstagramFailureKind.invalidUrl,
        'Enter a valid HTTPS Instagram Reel or post URL.',
      );
    }

    final media = <InstagramMediaOption>[];
    final seenMediaUrls = <String>{};
    final failures = <InstagramDownloadException>[];
    Map<String, String> metadata = const <String, String>{};

    for (final inspectionUri in _inspectionUris(parsed)) {
      _ensureNotDisposed();
      try {
        final body = await _loadPage(inspectionUri);
        if (body.isEmpty || body.length > _maximumPageCharacters) {
          failures.add(
            const InstagramDownloadException(
              InstagramFailureKind.unsupported,
              'Instagram returned an invalid media page.',
            ),
          );
          continue;
        }
        final pageMetadata = _openGraphMetadata(body);
        if (metadata.isEmpty || pageMetadata.containsKey('og:title')) {
          metadata = pageMetadata;
        }
        final extracted = _extractMedia(
          body: body,
          metadata: pageMetadata,
          shortcode: parsed.shortcode,
          thumbnailUrl: _safeHttpsUrl(
            pageMetadata['og:image:secure_url'] ??
                pageMetadata['og:image'] ??
                pageMetadata['twitter:image'],
          ),
          isReel: parsed.isReel,
        );
        for (final item in extracted) {
          if (!seenMediaUrls.add(item.url)) continue;
          media.add(
            InstagramMediaOption(
              id: '${parsed.shortcode}-${media.length}',
              url: item.url,
              kind: item.kind,
              mimeType: item.mimeType,
              thumbnailUrl: item.thumbnailUrl,
            ),
          );
          if (media.length >= _maximumMediaItems) break;
        }
        if (parsed.isReel &&
            media.any((item) => item.kind == DiscoverMediaKind.video)) {
          break;
        }
        final pageFailure = _classifyPage(body);
        if (pageFailure != null) failures.add(pageFailure);
      } on InstagramDownloadException catch (error) {
        failures.add(error);
      }
    }

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
    if (media.isEmpty ||
        (parsed.isReel &&
            !media.any((item) => item.kind == DiscoverMediaKind.video))) {
      throw _bestFailure(failures);
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

  static Iterable<Uri> _inspectionUris(
    ({String shortcode, Uri canonicalUri, bool isReel}) parsed,
  ) sync* {
    yield parsed.canonicalUri;
    yield Uri.https(
      'www.instagram.com',
      '${parsed.canonicalUri.path}embed/captioned/',
    );
    if (parsed.isReel) {
      // Instagram's embed service also accepts the post-style route for many
      // Reel shortcodes. It remains public and is a useful fallback when the
      // normal Reel document is only a login shell.
      yield Uri.https(
        'www.instagram.com',
        '/p/${parsed.shortcode}/embed/captioned/',
      );
    }
  }

  Future<String> _loadPage(Uri uri) async {
    final loader = _pageLoader;
    if (loader != null) {
      try {
        return await loader(uri).timeout(pageRequestTimeout);
      } on TimeoutException {
        throw const InstagramDownloadException(
          InstagramFailureKind.timedOut,
          'Instagram took too long to respond. Check the connection and retry.',
        );
      }
    }
    final cancelToken = CancelToken();
    _activeRequests.add(cancelToken);
    try {
      final response = await _dio
          .get<String>(
            uri.toString(),
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.plain,
              followRedirects: true,
              maxRedirects: 5,
              receiveTimeout: pageRequestTimeout,
              sendTimeout: pageRequestTimeout,
              headers: const <String, String>{
                'User-Agent': browserUserAgent,
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'en-US,en;q=0.8',
              },
              validateStatus: (status) =>
                  status != null && status >= 200 && status < 300,
            ),
          )
          .timeout(
            pageRequestTimeout,
            onTimeout: () {
              cancelToken.cancel('Instagram page request timed out.');
              throw const InstagramDownloadException(
                InstagramFailureKind.timedOut,
                'Instagram took too long to respond. Check the connection and retry.',
              );
            },
          );
      final announcedBytes = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      final finalUri = response.realUri;
      if (finalUri.scheme.toLowerCase() != 'https' ||
          !_instagramHosts.contains(finalUri.host.toLowerCase())) {
        throw const InstagramDownloadException(
          InstagramFailureKind.accessBlocked,
          'Instagram redirected this request to an unsupported destination.',
        );
      }
      if (finalUri.path.toLowerCase().startsWith('/accounts/login')) {
        throw const InstagramDownloadException(
          InstagramFailureKind.privateOrLoginRequired,
          'Instagram requires a login to access this post. Only anonymously accessible public media is supported.',
        );
      }
      if (announcedBytes != null &&
          announcedBytes > _maximumPageCharacters * 4) {
        throw const InstagramDownloadException(
          InstagramFailureKind.unsupported,
          'Instagram returned an unexpectedly large media page.',
        );
      }
      return response.data ?? '';
    } on DioException catch (error) {
      if (_disposed || error.type == DioExceptionType.cancel) {
        throw const InstagramDownloadException(
          InstagramFailureKind.disposed,
          'Instagram inspection was cancelled.',
        );
      }
      final status = error.response?.statusCode;
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        throw const InstagramDownloadException(
          InstagramFailureKind.timedOut,
          'Instagram took too long to respond. Check the connection and retry.',
        );
      }
      if (status == 401 || status == 403) {
        throw InstagramDownloadException(
          InstagramFailureKind.accessBlocked,
          'Instagram blocked anonymous access to this link. The post may still be public; try again later.',
          statusCode: status,
        );
      }
      if (status == 404 || status == 410) {
        throw InstagramDownloadException(
          InstagramFailureKind.unavailable,
          'This Instagram post is unavailable, deleted, or the link is incorrect.',
          statusCode: status,
        );
      }
      if (status == 429) {
        throw const InstagramDownloadException(
          InstagramFailureKind.rateLimited,
          'Instagram is temporarily rate-limiting requests. Wait a few minutes and retry.',
          statusCode: 429,
        );
      }
      throw InstagramDownloadException(
        InstagramFailureKind.network,
        status == null
            ? 'Instagram could not be reached. Check the connection and retry.'
            : 'Instagram is temporarily unavailable (HTTP $status).',
        statusCode: status,
      );
    } finally {
      _activeRequests.remove(cancelToken);
    }
  }

  static InstagramDownloadException? _classifyPage(String body) {
    final normalized = body.toLowerCase();
    if (normalized.contains('"is_private":true') ||
        normalized.contains('this account is private') ||
        normalized.contains('follow this account to see')) {
      return const InstagramDownloadException(
        InstagramFailureKind.privateOrLoginRequired,
        'This Instagram post is private. Only public posts can be downloaded.',
      );
    }
    if (normalized.contains('login_required') ||
        normalized.contains('log in to continue') ||
        normalized.contains('log in to see photos and videos')) {
      return const InstagramDownloadException(
        InstagramFailureKind.privateOrLoginRequired,
        'Instagram requires a login to access this post. Only anonymously accessible public media is supported.',
      );
    }
    if (normalized.contains('polariserrorroot') ||
        normalized.contains('"pageid":"httperrorpage"')) {
      return const InstagramDownloadException(
        InstagramFailureKind.accessBlocked,
        'Instagram did not expose this post to anonymous requests. It may still be public; try again later.',
      );
    }
    if (normalized.contains('please wait a few minutes') ||
        normalized.contains('rate_limit') ||
        normalized.contains('too many requests')) {
      return const InstagramDownloadException(
        InstagramFailureKind.rateLimited,
        'Instagram is temporarily rate-limiting requests. Wait a few minutes and retry.',
      );
    }
    if (normalized.contains("page isn't available") ||
        normalized.contains('page is not available') ||
        normalized.contains("content isn't available") ||
        normalized.contains('the link you followed may be broken')) {
      return const InstagramDownloadException(
        InstagramFailureKind.unavailable,
        'This Instagram post is unavailable, deleted, or the link is incorrect.',
      );
    }
    return null;
  }

  static InstagramDownloadException _bestFailure(
    List<InstagramDownloadException> failures,
  ) {
    const priority = <InstagramFailureKind, int>{
      InstagramFailureKind.rateLimited: 0,
      InstagramFailureKind.privateOrLoginRequired: 1,
      InstagramFailureKind.accessBlocked: 2,
      InstagramFailureKind.unavailable: 3,
      InstagramFailureKind.timedOut: 4,
      InstagramFailureKind.network: 5,
      InstagramFailureKind.disposed: 6,
      InstagramFailureKind.unsupported: 7,
      InstagramFailureKind.invalidUrl: 8,
    };
    if (failures.isNotEmpty) {
      failures.sort(
        (first, second) => (priority[first.kind] ?? 99).compareTo(
          priority[second.kind] ?? 99,
        ),
      );
      return failures.first;
    }
    return const InstagramDownloadException(
      InstagramFailureKind.unsupported,
      'Instagram did not expose downloadable media for this link. The post may be private, login-only, expired, or unsupported.',
    );
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
      r'"(video_url|videoUrl|contentUrl|display_url|displayUrl|thumbnail_src|thumbnailUrl)"\s*:\s*"((?:\\.|[^"\\])*)"',
      caseSensitive: false,
    ).allMatches(body);
    for (final match in serializedUrls.take(120)) {
      final key = match.group(1)!.toLowerCase();
      final decoded = _decodeJsonString(match.group(2)!);
      if (key == 'video_url' || key == 'videourl' || key == 'contenturl') {
        add(decoded, DiscoverMediaKind.video);
      } else if (key == 'display_url' || key == 'displayurl') {
        add(decoded, DiscoverMediaKind.image);
      }
    }

    // Current Instagram documents frequently put the playable URL inside a
    // video_versions array where the field is simply named "url".
    for (final block in RegExp(
      r'"video_versions"\s*:\s*\[(.{0,131072}?)\]',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(body).take(24)) {
      for (final match in RegExp(
        r'"url"\s*:\s*"((?:\\.|[^"\\])*)"',
        caseSensitive: false,
      ).allMatches(block.group(1) ?? '').take(8)) {
        add(_decodeJsonString(match.group(1)!), DiscoverMediaKind.video);
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
    if (_disposed) {
      throw const InstagramDownloadException(
        InstagramFailureKind.disposed,
        'Instagram inspection is no longer available.',
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final request in _activeRequests.toList(growable: false)) {
      request.cancel('InstagramDownloadService disposed.');
    }
    _activeRequests.clear();
    if (_ownsDio) _dio.close(force: true);
  }
}

const Set<String> _instagramHosts = <String>{
  'instagram.com',
  'www.instagram.com',
  'm.instagram.com',
};
