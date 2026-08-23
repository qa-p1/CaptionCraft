import 'dart:convert';

import '../../features/editor/models/discover_models.dart';

/// Builds and normalizes the small, read-only DOM probe used by Discover.
///
/// The script intentionally returns only bounded HTTPS URLs. It does not fetch
/// page resources, inspect response bodies, bypass authentication, or persist
/// cookies. Request headers needed for an immediate download must be supplied
/// separately to [DiscoverDownloadRequest] and are kept in memory only.
class DiscoverMediaExtractionService {
  const DiscoverMediaExtractionService._();

  static const int maxCandidates = 80;
  static const int maxStringLength = 2048;

  /// A self-contained JavaScript expression suitable for
  /// `InAppWebViewController.evaluateJavascript`.
  ///
  /// A JSON string is returned because Android and iOS WebView bridges differ
  /// in how nested JavaScript arrays are represented.
  static const String extractionJavaScript = r'''
(() => {
  const LIMIT = 80;
  const SCAN_LIMIT = 300;
  const STRING_LIMIT = 2048;
  const results = [];
  const seen = new Set();
  const pageTitle = String(document.title || '').slice(0, 300);

  const absoluteHttps = (value) => {
    if (!value || typeof value !== 'string' || value.length > STRING_LIMIT) {
      return null;
    }
    try {
      const url = new URL(value, document.baseURI);
      url.hash = '';
      return url.protocol === 'https:' ? url.href.slice(0, STRING_LIMIT) : null;
    } catch (_) {
      return null;
    }
  };

  const add = (value, kind, origin, extra = {}) => {
    if (results.length >= LIMIT) return;
    const url = absoluteHttps(value);
    if (!url || seen.has(url)) return;
    seen.add(url);
    const candidate = {url, kind, origin, title: pageTitle};
    if (typeof extra.mimeType === 'string') {
      candidate.mimeType = extra.mimeType.slice(0, 200);
    }
    if (typeof extra.thumbnailUrl === 'string') {
      const thumbnailUrl = absoluteHttps(extra.thumbnailUrl);
      if (thumbnailUrl) candidate.thumbnailUrl = thumbnailUrl;
    }
    if (Number.isFinite(extra.width) && extra.width > 0) {
      candidate.width = Math.round(extra.width);
    }
    if (Number.isFinite(extra.height) && extra.height > 0) {
      candidate.height = Math.round(extra.height);
    }
    results.push(candidate);
  };

  const addSrcSet = (value, kind, origin, extra) => {
    if (!value || typeof value !== 'string') return;
    for (const part of value.split(',').slice(0, 12)) {
      add(part.trim().split(/\s+/)[0], kind, origin, extra);
    }
  };

  for (const image of Array.from(document.images).slice(0, SCAN_LIMIT)) {
    const extra = {
      width: image.naturalWidth || image.width,
      height: image.naturalHeight || image.height,
    };
    add(image.currentSrc, 'image', 'imageElement', extra);
    add(image.src, 'image', 'imageElement', extra);
    add(image.getAttribute('data-src'), 'image', 'imageElement', extra);
    add(image.getAttribute('data-original'), 'image', 'imageElement', extra);
    add(image.getAttribute('data-lazy-src'), 'image', 'imageElement', extra);
    add(image.getAttribute('data-pin-media'), 'image', 'imageElement', extra);
    add(image.getAttribute('data-image'), 'image', 'imageElement', extra);
    add(image.getAttribute('data-original-src'), 'image', 'imageElement', extra);
    addSrcSet(image.srcset || image.getAttribute('data-srcset'),
      'image', 'imageElement', extra);
  }

  for (const video of Array.from(document.querySelectorAll('video')).slice(0, SCAN_LIMIT)) {
    const extra = {
      width: video.videoWidth || video.width,
      height: video.videoHeight || video.height,
      thumbnailUrl: video.poster,
    };
    add(video.currentSrc, 'video', 'videoElement', extra);
    add(video.src, 'video', 'videoElement', extra);
    add(video.poster, 'image', 'videoElement', extra);
  }

  for (const audio of Array.from(document.querySelectorAll('audio')).slice(0, SCAN_LIMIT)) {
    add(audio.currentSrc, 'audio', 'sourceElement');
    add(audio.src, 'audio', 'sourceElement');
  }

  for (const source of Array.from(document.querySelectorAll('source')).slice(0, SCAN_LIMIT)) {
    const mimeType = String(source.type || '').toLowerCase();
    const kind = source.parentElement?.tagName === 'AUDIO' || mimeType.startsWith('audio/') ? 'audio' :
      (mimeType.startsWith('image/') ? 'image' : 'video');
    add(source.src, kind, 'sourceElement', {mimeType});
    addSrcSet(source.srcset, kind, 'sourceElement', {mimeType});
  }

  for (const meta of Array.from(document.querySelectorAll('meta[property], meta[name]')).slice(0, SCAN_LIMIT)) {
    const name = String(meta.getAttribute('property') || meta.getAttribute('name') || '').toLowerCase();
    const content = meta.content;
    if (name.includes('image')) add(content, 'image', 'openGraph');
    if (name.includes('video')) add(content, 'video', 'openGraph');
    if (name.includes('audio')) add(content, 'audio', 'openGraph');
  }

  const extensionKind = (value) => {
    const clean = String(value || '').split(/[?#]/)[0].toLowerCase();
    if (/\.(png|jpe?g|gif|webp|avif|bmp|svg)$/.test(clean)) return 'image';
    if (/\.(mp4|m4v|mov|webm|mkv|avi|3gp)$/.test(clean)) return 'video';
    if (/\.(mp3|m4a|aac|wav|ogg|flac|opus)$/.test(clean)) return 'audio';
    return null;
  };

  for (const anchor of Array.from(document.links).slice(0, SCAN_LIMIT)) {
    const kind = extensionKind(anchor.href);
    if (kind) add(anchor.href, kind, 'link');
  }

  for (const element of Array.from(document.querySelectorAll('[data-pin-media], [data-image]')).slice(0, SCAN_LIMIT)) {
    add(element.getAttribute('data-pin-media') || element.getAttribute('data-image'),
      'image', 'imageElement');
  }

  // Avoid getComputedStyle() across every node: it can force repeated style
  // work on image-heavy pages. Loaded CSS backgrounds are still covered by
  // performance entries below; this pass only handles bounded inline styles.
  for (const element of Array.from(document.querySelectorAll(
      '[style*="background-image"], [style*="background:"]')).slice(0, SCAN_LIMIT)) {
    const background = String(getComputedStyle(element).backgroundImage || '');
    for (const match of background.matchAll(/url\(["']?([^"')]+)["']?\)/g)) {
      add(match[1], 'image', 'imageElement');
    }
  }

  try {
    for (const entry of performance.getEntriesByType('resource').slice(-SCAN_LIMIT)) {
      const kind = extensionKind(entry.name);
      if (kind) add(entry.name, kind, 'link');
    }
  } catch (_) {}

  return JSON.stringify(results.slice(0, LIMIT));
})()
''';

  static List<DiscoveredMediaCandidate> normalizeResult(
    Object? raw, {
    String? pageUrl,
    int limit = maxCandidates,
  }) {
    Object? decoded = raw;
    for (var attempt = 0; attempt < 2 && decoded is String; attempt++) {
      final value = decoded.trim();
      if (value.isEmpty) return const <DiscoveredMediaCandidate>[];
      try {
        decoded = jsonDecode(value);
      } on FormatException {
        return const <DiscoveredMediaCandidate>[];
      }
    }

    if (decoded is Map) decoded = decoded['candidates'];
    if (decoded is! List) return const <DiscoveredMediaCandidate>[];

    final boundedLimit = limit.clamp(0, maxCandidates);
    if (boundedLimit == 0) return const <DiscoveredMediaCandidate>[];
    final normalizedPageUrl = _httpsUrl(pageUrl);
    final seen = <String>{};
    final candidates = <DiscoveredMediaCandidate>[];

    for (final value in decoded.take(maxCandidates * 2)) {
      if (candidates.length >= boundedLimit) break;
      if (value is! Map) continue;
      final map = value.map((key, entry) => MapEntry(key.toString(), entry));
      final url = _httpsUrl(_boundedString(map['url']));
      if (url == null || !seen.add(url)) continue;

      final mimeType = _boundedString(map['mimeType'], maxLength: 200);
      final kind = _kind(map['kind'], mimeType, url);
      candidates.add(
        DiscoveredMediaCandidate(
          url: url,
          kind: kind,
          origin: _origin(map['origin']),
          pageUrl: normalizedPageUrl,
          title: _boundedString(map['title'], maxLength: 300),
          thumbnailUrl: _httpsUrl(_boundedString(map['thumbnailUrl'])),
          mimeType: mimeType,
          width: _positiveInt(map['width']),
          height: _positiveInt(map['height']),
          contentLength: _positiveInt(map['contentLength']),
        ),
      );
    }
    return List<DiscoveredMediaCandidate>.unmodifiable(candidates);
  }

  static String? _boundedString(
    Object? value, {
    int maxLength = maxStringLength,
  }) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > maxLength) return null;
    return trimmed;
  }

  static String? _httpsUrl(String? value) {
    if (value == null) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final normalized = uri.toString();
    return uri.hasFragment
        ? normalized.substring(0, normalized.lastIndexOf('#'))
        : normalized;
  }

  static int? _positiveInt(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static DiscoverMediaOrigin _origin(Object? value) {
    final name = value?.toString();
    return DiscoverMediaOrigin.values.firstWhere(
      (origin) => origin.name == name,
      orElse: () => DiscoverMediaOrigin.link,
    );
  }

  static DiscoverMediaKind _kind(Object? value, String? mimeType, String url) {
    final name = value?.toString();
    for (final kind in DiscoverMediaKind.values) {
      if (kind.name == name) return kind;
    }
    final mime = mimeType?.toLowerCase() ?? '';
    if (mime.startsWith('image/')) return DiscoverMediaKind.image;
    if (mime.startsWith('video/')) return DiscoverMediaKind.video;
    if (mime.startsWith('audio/')) return DiscoverMediaKind.audio;
    final path = Uri.parse(url).path.toLowerCase();
    if (RegExp(r'\.(png|jpe?g|gif|webp|avif|bmp|svg)$').hasMatch(path)) {
      return DiscoverMediaKind.image;
    }
    if (RegExp(r'\.(mp4|m4v|mov|webm|mkv|avi|3gp)$').hasMatch(path)) {
      return DiscoverMediaKind.video;
    }
    if (RegExp(r'\.(mp3|m4a|aac|wav|ogg|flac|opus)$').hasMatch(path)) {
      return DiscoverMediaKind.audio;
    }
    return DiscoverMediaKind.unknown;
  }
}
