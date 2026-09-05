import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
    this.inspectionTimeout = const Duration(seconds: 30),
  }) : _dio = dio ?? Dio(BaseOptions(connectTimeout: pageRequestTimeout)),
       _ownsDio = dio == null,
       _pageLoader = pageLoader,
       assert(pageRequestTimeout > Duration.zero),
       assert(inspectionTimeout > Duration.zero);

  static const int _maximumPageBytes = 4 * 1024 * 1024;
  static const int _maximumMediaItems = 24;
  static const int _maximumRedirects = 5;
  static const Set<int> _redirectStatuses = <int>{301, 302, 303, 307, 308};
  static const InstagramDownloadException _timeoutFailure =
      InstagramDownloadException(
        InstagramFailureKind.timedOut,
        'Instagram took too long to respond. Check the connection and retry.',
      );
  static const InstagramDownloadException _disposedFailure =
      InstagramDownloadException(
        InstagramFailureKind.disposed,
        'Instagram inspection was cancelled.',
      );
  static const InstagramDownloadException
  _loginRequiredFailure = InstagramDownloadException(
    InstagramFailureKind.privateOrLoginRequired,
    'Instagram requires a login to access this post. Only anonymously accessible public media is supported.',
  );
  static const String browserUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

  final Dio _dio;
  final bool _ownsDio;
  final InstagramPageLoader? _pageLoader;
  final Duration pageRequestTimeout;
  final Duration inspectionTimeout;
  final Set<CancelToken> _activeRequests = <CancelToken>{};
  final Completer<void> _disposedSignal = Completer<void>();
  bool _disposed = false;

  static ({String shortcode, Uri canonicalUri, bool isReel})? parseUrl(
    String value,
  ) {
    final normalizedValue = value.trim();
    if (normalizedValue.isEmpty || normalizedValue.length > 2048) return null;
    final uri = Uri.tryParse(normalizedValue);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        !_instagramHosts.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      return null;
    }
    final rawSegments = uri.pathSegments;
    // Instagram's copied links conventionally end in `/`. Dart represents
    // that final slash as an empty path segment, so discard exactly that one
    // while continuing to reject doubled slashes and extra route components.
    final segments = rawSegments.isNotEmpty && rawSegments.last.isEmpty
        ? rawSegments.sublist(0, rawSegments.length - 1)
        : rawSegments;
    if (segments.length != 2 || segments.any((segment) => segment.isEmpty)) {
      return null;
    }
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
    final inspectionClock = Stopwatch()..start();

    for (final inspectionUri in _inspectionUris(parsed)) {
      _ensureNotDisposed();
      try {
        final remaining = inspectionTimeout - inspectionClock.elapsed;
        if (remaining <= Duration.zero) {
          failures.add(_timeoutFailure);
          break;
        }
        final body = await _loadPage(
          inspectionUri,
          timeout: remaining < pageRequestTimeout
              ? remaining
              : pageRequestTimeout,
        );
        if (body.isEmpty || utf8.encode(body).length > _maximumPageBytes) {
          failures.add(
            const InstagramDownloadException(
              InstagramFailureKind.unsupported,
              'Instagram returned an invalid media page.',
            ),
          );
          continue;
        }
        // Error/login documents can contain Instagram's own Open Graph image
        // and generic serialized URLs. Never treat those shell assets as the
        // requested post; only extract media from a page that passed the
        // availability classification.
        final pageFailure = _classifyPage(body);
        if (pageFailure != null) {
          failures.add(pageFailure);
          continue;
        }
        final pageMetadata = _openGraphMetadata(body);
        // Preserve useful fields from the canonical document when an embed
        // response only supplies the playable URL (and vice versa).
        metadata = <String, String>{...metadata, ...pageMetadata};
        final extracted = _extractMedia(
          body: body,
          metadata: metadata,
          shortcode: parsed.shortcode,
          thumbnailUrl: _safeHttpsUrl(
            metadata['og:image:secure_url'] ??
                metadata['og:image'] ??
                metadata['twitter:image'],
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
      } on InstagramDownloadException catch (error) {
        if (error.kind == InstagramFailureKind.disposed) rethrow;
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
    yield Uri.https('www.instagram.com', '${parsed.canonicalUri.path}embed/');
    yield Uri.https(
      'www.instagram.com',
      '${parsed.canonicalUri.path}embed/captioned/',
    );
    if (parsed.isReel) {
      // Instagram's embed service also accepts the post-style route for many
      // Reel shortcodes. It remains public and is a useful fallback when the
      // normal Reel document is only a login shell.
      yield Uri.https('www.instagram.com', '/p/${parsed.shortcode}/embed/');
      yield Uri.https(
        'www.instagram.com',
        '/p/${parsed.shortcode}/embed/captioned/',
      );
    }
  }

  Future<String> _loadPage(Uri uri, {required Duration timeout}) async {
    final loader = _pageLoader;
    if (loader != null) {
      try {
        final guardedLoad = Future<String>.sync(
          () => loader(uri),
        ).timeout(timeout);
        return await Future.any<String>(<Future<String>>[
          guardedLoad,
          _disposedSignal.future.then<String>((_) => throw _disposedFailure),
        ]);
      } on InstagramDownloadException {
        rethrow;
      } on TimeoutException {
        throw _timeoutFailure;
      } catch (_) {
        if (_disposed) throw _disposedFailure;
        throw const InstagramDownloadException(
          InstagramFailureKind.network,
          'Instagram could not be reached. Check the connection and retry.',
        );
      }
    }
    final cancelToken = CancelToken();
    _activeRequests.add(cancelToken);
    try {
      var currentUri = uri;
      final visited = <String>{currentUri.toString()};
      final requestClock = Stopwatch()..start();

      for (var redirectCount = 0; ; redirectCount++) {
        _ensureNotDisposed();
        final remaining = timeout - requestClock.elapsed;
        if (remaining <= Duration.zero) throw _timeoutFailure;

        final response = await _dio
            .get<ResponseBody>(
              currentUri.toString(),
              cancelToken: cancelToken,
              options: Options(
                responseType: ResponseType.stream,
                followRedirects: false,
                maxRedirects: 0,
                receiveTimeout: remaining,
                sendTimeout: remaining,
                headers: const <String, String>{
                  'User-Agent': browserUserAgent,
                  'Accept':
                      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'Accept-Language': 'en-US,en;q=0.8',
                },
                validateStatus: (status) =>
                    status != null &&
                    ((status >= 200 && status < 300) ||
                        _redirectStatuses.contains(status)),
              ),
            )
            .timeout(
              remaining,
              onTimeout: () {
                cancelToken.cancel('Instagram page request timed out.');
                throw _timeoutFailure;
              },
            );
        final status = response.statusCode;
        if (status != null && _redirectStatuses.contains(status)) {
          await _cancelResponseBody(response.data);
          if (redirectCount >= _maximumRedirects) {
            throw const InstagramDownloadException(
              InstagramFailureKind.accessBlocked,
              'Instagram redirected this request too many times.',
            );
          }
          final location = response.headers.value('location');
          if (location == null || location.trim().isEmpty) {
            throw const InstagramDownloadException(
              InstagramFailureKind.accessBlocked,
              'Instagram returned an invalid redirect while inspecting this post.',
            );
          }
          final nextUri = currentUri.resolve(location.trim());
          if (!_isSafeInstagramPageUri(nextUri)) {
            throw const InstagramDownloadException(
              InstagramFailureKind.accessBlocked,
              'Instagram redirected this request to an unsupported destination.',
            );
          }
          if (_isLoginUri(nextUri)) throw _loginRequiredFailure;
          if (!visited.add(nextUri.toString())) {
            throw const InstagramDownloadException(
              InstagramFailureKind.accessBlocked,
              'Instagram returned a redirect loop while inspecting this post.',
            );
          }
          currentUri = nextUri;
          continue;
        }

        if (!_isSafeInstagramPageUri(response.realUri)) {
          await _cancelResponseBody(response.data);
          throw const InstagramDownloadException(
            InstagramFailureKind.accessBlocked,
            'Instagram redirected this request to an unsupported destination.',
          );
        }
        if (_isLoginUri(response.realUri)) {
          await _cancelResponseBody(response.data);
          throw _loginRequiredFailure;
        }
        final announcedBytes = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        );
        if (announcedBytes != null && announcedBytes > _maximumPageBytes) {
          await _cancelResponseBody(response.data);
          throw const InstagramDownloadException(
            InstagramFailureKind.unsupported,
            'Instagram returned an unexpectedly large media page.',
          );
        }
        final bodyTimeout = timeout - requestClock.elapsed;
        if (bodyTimeout <= Duration.zero) {
          await _cancelResponseBody(response.data);
          throw _timeoutFailure;
        }
        return await _readBoundedPage(response.data).timeout(
          bodyTimeout,
          onTimeout: () {
            cancelToken.cancel('Instagram page response timed out.');
            throw _timeoutFailure;
          },
        );
      }
    } on InstagramDownloadException {
      rethrow;
    } on DioException catch (error) {
      if (_disposed || error.type == DioExceptionType.cancel) {
        throw _disposedFailure;
      }
      final status = error.response?.statusCode;
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        throw _timeoutFailure;
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
    } catch (_) {
      if (_disposed) throw _disposedFailure;
      throw const InstagramDownloadException(
        InstagramFailureKind.network,
        'Instagram could not be reached. Check the connection and retry.',
      );
    } finally {
      _activeRequests.remove(cancelToken);
    }
  }

  static Future<String> _readBoundedPage(ResponseBody? responseBody) async {
    if (responseBody == null) return '';
    final bytes = BytesBuilder(copy: false);
    final iterator = StreamIterator<Uint8List>(responseBody.stream);
    try {
      while (await iterator.moveNext()) {
        final chunk = iterator.current;
        if (bytes.length + chunk.length > _maximumPageBytes) {
          throw const InstagramDownloadException(
            InstagramFailureKind.unsupported,
            'Instagram returned an unexpectedly large media page.',
          );
        }
        bytes.add(chunk);
      }
    } finally {
      await iterator.cancel();
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  static Future<void> _cancelResponseBody(ResponseBody? responseBody) async {
    if (responseBody == null) return;
    final subscription = responseBody.stream.listen(null);
    await subscription.cancel();
  }

  static bool _isSafeInstagramPageUri(Uri uri) =>
      uri.scheme.toLowerCase() == 'https' &&
      _instagramHosts.contains(uri.host.toLowerCase()) &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);

  static bool _isLoginUri(Uri uri) =>
      uri.path.toLowerCase().startsWith('/accounts/login');

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
        (first, second) =>
            (priority[first.kind] ?? 99).compareTo(priority[second.kind] ?? 99),
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
    _disposedSignal.complete();
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
