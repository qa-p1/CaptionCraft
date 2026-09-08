import 'dart:async';
import '../../features/editor/models/discover_models.dart';
import 'yt_dlp_bridge.dart';

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

/// URL validation and model mapping only. yt-dlp owns Instagram extraction.
class InstagramDownloadService implements InstagramMediaService {
  InstagramDownloadService({
    Future<Map<String, dynamic>> Function(String)? extractor,
    this.inspectionTimeout = const Duration(seconds: 125),
  }) : _extractor = extractor ?? YtDlpBridge.instance.inspect;
  final Future<Map<String, dynamic>> Function(String) _extractor;
  final Duration inspectionTimeout;
  final _disposedSignal = Completer<void>();
  bool _disposed = false;
  static const _instagramHosts = {
    'instagram.com',
    'www.instagram.com',
    'm.instagram.com',
  };
  static const browserUserAgent = 'Mozilla/5.0';
  static const _headerNames = {
    'user-agent': 'User-Agent',
    'referer': 'Referer',
    'origin': 'Origin',
    'accept': 'Accept',
    'accept-language': 'Accept-Language',
  };
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

  static Map<String, String> downloadHeaders(
    String canonicalUrl, [
    Map<String, String> extracted = const {},
  ]) => {
    'User-Agent': browserUserAgent,
    'Referer': canonicalUrl,
    'Origin': 'https://www.instagram.com',
    for (final entry in extracted.entries)
      if (_headerNames.containsKey(entry.key.toLowerCase()) &&
          !entry.value.contains(RegExp(r'[\r\n]')))
        _headerNames[entry.key.toLowerCase()]!: entry.value,
  };

  @override
  Future<InstagramPostInfo> inspect(String url) async {
    final parsed = parseUrl(url);
    if (parsed == null) {
      throw const InstagramDownloadException(
        InstagramFailureKind.invalidUrl,
        'Enter a valid HTTPS Instagram Reel or post URL.',
      );
    }
    if (_disposed) {
      throw const InstagramDownloadException(
        InstagramFailureKind.disposed,
        'Instagram inspection was cancelled.',
      );
    }
    try {
      final info = await Future.any<Map<String, dynamic>>([
        _extractor(parsed.canonicalUri.toString()).timeout(inspectionTimeout),
        _disposedSignal.future.then(
          (_) => throw const InstagramDownloadException(
            InstagramFailureKind.disposed,
            'Instagram inspection was cancelled.',
          ),
        ),
      ]);
      final entries = info['entries'] is List
          ? (info['entries'] as List).whereType<Map>()
          : [info];
      final media = <InstagramMediaOption>[];
      final seen = <String>{};
      for (final entry in entries.take(24)) {
        final formats =
            (entry['formats'] as List?)?.whereType<Map>().toList() ?? [];
        final videos = formats.where(
          (f) => f['vcodec'] != 'none' && f['url'] is String,
        );
        // Instagram's progressive variants include the post's complete media.
        // Adaptive DASH variants can separate audio from video.
        final video =
            videos
                .where(
                  (f) =>
                      !'${f['format_id']}'.startsWith('dash-') &&
                      (f['protocol'] == null || f['protocol'] == 'https'),
                )
                .lastOrNull ??
            videos.lastOrNull;
        final candidate = video ?? entry;
        final source = _https(candidate['url']);
        if (source == null || !seen.add(source)) continue;
        final ext = candidate['ext'] as String? ?? '';
        final isImage = const {'jpg', 'jpeg', 'png', 'webp'}.contains(ext);
        if (parsed.isReel && isImage) continue;
        media.add(
          InstagramMediaOption(
            id: '${parsed.shortcode}-${media.length}',
            url: source,
            kind: isImage ? DiscoverMediaKind.image : DiscoverMediaKind.video,
            mimeType: isImage
                ? 'image/${ext == 'jpg' ? 'jpeg' : ext}'
                : 'video/mp4',
            thumbnailUrl: _https(entry['thumbnail'] ?? info['thumbnail']),
            httpHeaders: {
              for (final source in [info, entry, candidate])
                if (source['http_headers'] is Map)
                  for (final header in (source['http_headers'] as Map).entries)
                    if (header.key is String && header.value is String)
                      header.key as String: header.value as String,
            },
          ),
        );
      }
      if (media.isEmpty) {
        throw const InstagramDownloadException(
          InstagramFailureKind.unavailable,
          'No downloadable media was found. Check that the post is public.',
        );
      }
      return InstagramPostInfo(
        shortcode: parsed.shortcode,
        canonicalUrl: parsed.canonicalUri.toString(),
        title: info['title'] as String? ?? 'Instagram post',
        author: info['uploader'] as String? ?? '',
        isReel: parsed.isReel,
        thumbnailUrl: _https(info['thumbnail']),
        media: List.unmodifiable(media),
      );
    } on InstagramDownloadException {
      rethrow;
    } on TimeoutException {
      throw const InstagramDownloadException(
        InstagramFailureKind.timedOut,
        'Instagram took too long to respond. Retry the link.',
      );
    } catch (error) {
      final message = error.toString().toLowerCase();
      final restricted =
          message.contains('login') || message.contains('private');
      throw InstagramDownloadException(
        restricted
            ? InstagramFailureKind.privateOrLoginRequired
            : InstagramFailureKind.network,
        restricted
            ? 'This post requires an Instagram login. Use a public post.'
            : 'Instagram could not resolve this post. Check the link and retry.',
      );
    }
  }

  static String? _https(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri.toString()
        : null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disposedSignal.complete();
  }
}
