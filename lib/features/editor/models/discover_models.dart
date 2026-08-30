enum DiscoverMediaKind { image, video, audio, unknown }

enum DiscoverMediaOrigin {
  imageElement,
  videoElement,
  sourceElement,
  openGraph,
  link,
  direct,
  youtube,
  instagram,
}

enum DiscoverDownloadSource { direct, youtube, instagram }

enum DiscoverDownloadStatus {
  queued,
  downloading,
  processing,
  completed,
  failed,
  cancelled,
}

enum YoutubeDownloadKind { muxedVideo, audioOnly, splitVideoAudio }

T _enumValue<T extends Enum>(Iterable<T> values, Object? value, T fallback) {
  final name = value?.toString();
  return values.cast<T>().firstWhere(
    (candidate) => candidate.name == name,
    orElse: () => fallback,
  );
}

int? _nullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is! Map) return const <String, dynamic>{};
  return value.map((key, entry) => MapEntry(key.toString(), entry));
}

class DiscoveredMediaCandidate {
  const DiscoveredMediaCandidate({
    required this.url,
    required this.kind,
    required this.origin,
    this.pageUrl,
    this.title,
    this.thumbnailUrl,
    this.mimeType,
    this.width,
    this.height,
    this.contentLength,
    this.metadata = const <String, dynamic>{},
  });

  final String url;
  final DiscoverMediaKind kind;
  final DiscoverMediaOrigin origin;
  final String? pageUrl;
  final String? title;
  final String? thumbnailUrl;
  final String? mimeType;
  final int? width;
  final int? height;
  final int? contentLength;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'kind': kind.name,
    'origin': origin.name,
    if (pageUrl != null) 'pageUrl': pageUrl,
    if (title != null) 'title': title,
    if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
    if (mimeType != null) 'mimeType': mimeType,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (contentLength != null) 'contentLength': contentLength,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory DiscoveredMediaCandidate.fromJson(Map<String, dynamic> json) {
    return DiscoveredMediaCandidate(
      url: json['url']?.toString() ?? '',
      kind: _enumValue(
        DiscoverMediaKind.values,
        json['kind'],
        DiscoverMediaKind.unknown,
      ),
      origin: _enumValue(
        DiscoverMediaOrigin.values,
        json['origin'],
        DiscoverMediaOrigin.direct,
      ),
      pageUrl: json['pageUrl']?.toString(),
      title: json['title']?.toString(),
      thumbnailUrl: json['thumbnailUrl']?.toString(),
      mimeType: json['mimeType']?.toString(),
      width: _nullableInt(json['width']),
      height: _nullableInt(json['height']),
      contentLength: _nullableInt(json['contentLength']),
      metadata: _jsonMap(json['metadata']),
    );
  }
}

class DiscoverDownloadRequest {
  const DiscoverDownloadRequest({
    required this.url,
    required this.displayName,
    required this.kind,
    this.pageUrl,
    this.headers = const <String, String>{},
    this.mimeType,
    this.metadata = const <String, dynamic>{},
  });

  factory DiscoverDownloadRequest.fromCandidate(
    DiscoveredMediaCandidate candidate, {
    String? displayName,
    Map<String, String> headers = const <String, String>{},
  }) {
    return DiscoverDownloadRequest(
      url: candidate.url,
      displayName: displayName ?? candidate.title ?? 'Downloaded media',
      kind: candidate.kind,
      pageUrl: candidate.pageUrl,
      headers: headers,
      mimeType: candidate.mimeType,
      metadata: candidate.metadata,
    );
  }

  final String url;
  final String displayName;
  final DiscoverMediaKind kind;
  final String? pageUrl;

  /// Request-scoped values such as cookies and referers. These are deliberately
  /// excluded from [toJson] and are never persisted by the download manager.
  final Map<String, String> headers;
  final String? mimeType;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'displayName': displayName,
    'kind': kind.name,
    if (pageUrl != null) 'pageUrl': pageUrl,
    if (mimeType != null) 'mimeType': mimeType,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory DiscoverDownloadRequest.fromJson(Map<String, dynamic> json) {
    return DiscoverDownloadRequest(
      url: json['url']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? 'Downloaded media',
      kind: _enumValue(
        DiscoverMediaKind.values,
        json['kind'],
        DiscoverMediaKind.unknown,
      ),
      pageUrl: json['pageUrl']?.toString(),
      mimeType: json['mimeType']?.toString(),
      metadata: _jsonMap(json['metadata']),
    );
  }
}

class YoutubeFormatOption {
  const YoutubeFormatOption({
    required this.id,
    required this.label,
    required this.kind,
    required this.container,
    this.videoFormatTag,
    this.audioFormatTag,
    this.resolutionLabel,
    this.width,
    this.height,
    this.framesPerSecond,
    this.bitrate,
    this.estimatedBytes,
    this.videoCodec,
    this.audioCodec,
  });

  final String id;
  final String label;
  final YoutubeDownloadKind kind;
  final String container;
  final int? videoFormatTag;
  final int? audioFormatTag;
  final String? resolutionLabel;
  final int? width;
  final int? height;
  final int? framesPerSecond;
  final int? bitrate;
  final int? estimatedBytes;
  final String? videoCodec;
  final String? audioCodec;

  bool get hasVideo => kind != YoutubeDownloadKind.audioOnly;
  bool get hasAudio =>
      kind != YoutubeDownloadKind.splitVideoAudio || audioFormatTag != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    'kind': kind.name,
    'container': container,
    if (videoFormatTag != null) 'videoFormatTag': videoFormatTag,
    if (audioFormatTag != null) 'audioFormatTag': audioFormatTag,
    if (resolutionLabel != null) 'resolutionLabel': resolutionLabel,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (framesPerSecond != null) 'framesPerSecond': framesPerSecond,
    if (bitrate != null) 'bitrate': bitrate,
    if (estimatedBytes != null) 'estimatedBytes': estimatedBytes,
    if (videoCodec != null) 'videoCodec': videoCodec,
    if (audioCodec != null) 'audioCodec': audioCodec,
  };

  factory YoutubeFormatOption.fromJson(Map<String, dynamic> json) {
    return YoutubeFormatOption(
      id: json['id']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      kind: _enumValue(
        YoutubeDownloadKind.values,
        json['kind'],
        YoutubeDownloadKind.muxedVideo,
      ),
      container: json['container']?.toString() ?? 'mp4',
      videoFormatTag: _nullableInt(json['videoFormatTag']),
      audioFormatTag: _nullableInt(json['audioFormatTag']),
      resolutionLabel: json['resolutionLabel']?.toString(),
      width: _nullableInt(json['width']),
      height: _nullableInt(json['height']),
      framesPerSecond: _nullableInt(json['framesPerSecond']),
      bitrate: _nullableInt(json['bitrate']),
      estimatedBytes: _nullableInt(json['estimatedBytes']),
      videoCodec: json['videoCodec']?.toString(),
      audioCodec: json['audioCodec']?.toString(),
    );
  }
}

class YoutubeVideoInfo {
  const YoutubeVideoInfo({
    required this.videoId,
    required this.canonicalUrl,
    required this.title,
    required this.author,
    required this.duration,
    required this.formats,
    this.thumbnailUrl,
  });

  final String videoId;
  final String canonicalUrl;
  final String title;
  final String author;
  final String? thumbnailUrl;
  final Duration duration;
  final List<YoutubeFormatOption> formats;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'videoId': videoId,
    'canonicalUrl': canonicalUrl,
    'title': title,
    'author': author,
    if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
    'durationMilliseconds': duration.inMilliseconds,
    'formats': formats.map((format) => format.toJson()).toList(),
  };

  factory YoutubeVideoInfo.fromJson(Map<String, dynamic> json) {
    final rawFormats = json['formats'];
    return YoutubeVideoInfo(
      videoId: json['videoId']?.toString() ?? '',
      canonicalUrl: json['canonicalUrl']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      thumbnailUrl: json['thumbnailUrl']?.toString(),
      duration: Duration(
        milliseconds: _nullableInt(json['durationMilliseconds']) ?? 0,
      ),
      formats: rawFormats is List
          ? rawFormats
                .whereType<Map>()
                .map(
                  (value) => YoutubeFormatOption.fromJson(
                    value.map((key, entry) => MapEntry(key.toString(), entry)),
                  ),
                )
                .toList(growable: false)
          : const <YoutubeFormatOption>[],
    );
  }
}

class InstagramMediaOption {
  const InstagramMediaOption({
    required this.id,
    required this.url,
    required this.kind,
    this.mimeType,
    this.thumbnailUrl,
    this.width,
    this.height,
  });

  final String id;
  final String url;
  final DiscoverMediaKind kind;
  final String? mimeType;
  final String? thumbnailUrl;
  final int? width;
  final int? height;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'url': url,
    'kind': kind.name,
    if (mimeType != null) 'mimeType': mimeType,
    if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
  };

  factory InstagramMediaOption.fromJson(Map<String, dynamic> json) {
    return InstagramMediaOption(
      id: json['id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      kind: _enumValue(
        DiscoverMediaKind.values,
        json['kind'],
        DiscoverMediaKind.unknown,
      ),
      mimeType: json['mimeType']?.toString(),
      thumbnailUrl: json['thumbnailUrl']?.toString(),
      width: _nullableInt(json['width']),
      height: _nullableInt(json['height']),
    );
  }
}

class InstagramPostInfo {
  const InstagramPostInfo({
    required this.shortcode,
    required this.canonicalUrl,
    required this.title,
    required this.author,
    required this.isReel,
    required this.media,
    this.thumbnailUrl,
  });

  final String shortcode;
  final String canonicalUrl;
  final String title;
  final String author;
  final bool isReel;
  final String? thumbnailUrl;
  final List<InstagramMediaOption> media;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'shortcode': shortcode,
    'canonicalUrl': canonicalUrl,
    'title': title,
    'author': author,
    'isReel': isReel,
    if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
    'media': media.map((item) => item.toJson()).toList(),
  };

  factory InstagramPostInfo.fromJson(Map<String, dynamic> json) {
    final rawMedia = json['media'];
    return InstagramPostInfo(
      shortcode: json['shortcode']?.toString() ?? '',
      canonicalUrl: json['canonicalUrl']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Instagram media',
      author: json['author']?.toString() ?? 'Instagram',
      isReel: json['isReel'] as bool? ?? false,
      thumbnailUrl: json['thumbnailUrl']?.toString(),
      media: rawMedia is List
          ? rawMedia
                .whereType<Map>()
                .map(
                  (value) => InstagramMediaOption.fromJson(
                    value.map((key, entry) => MapEntry(key.toString(), entry)),
                  ),
                )
                .toList(growable: false)
          : const <InstagramMediaOption>[],
    );
  }
}

class DiscoverDownloadItem {
  const DiscoverDownloadItem({
    required this.id,
    required this.source,
    required this.status,
    required this.sourceUrl,
    required this.displayName,
    required this.fileName,
    required this.kind,
    required this.receivedBytes,
    required this.createdAt,
    required this.updatedAt,
    this.pageUrl,
    this.localPath,
    this.mimeType,
    this.totalBytes,
    this.errorMessage,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final DiscoverDownloadSource source;
  final DiscoverDownloadStatus status;
  final String sourceUrl;
  final String? pageUrl;
  final String displayName;
  final String fileName;
  final String? localPath;
  final String? mimeType;
  final DiscoverMediaKind kind;
  final int receivedBytes;
  final int? totalBytes;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? errorMessage;
  final Map<String, dynamic> metadata;

  double get progress {
    if (status == DiscoverDownloadStatus.completed) return 1;
    final total = totalBytes;
    if (total == null || total <= 0) return 0;
    return (receivedBytes / total).clamp(0, 1).toDouble();
  }

  bool get hasKnownProgress => totalBytes != null && totalBytes! > 0;
  bool get isTerminal => const <DiscoverDownloadStatus>{
    DiscoverDownloadStatus.completed,
    DiscoverDownloadStatus.failed,
    DiscoverDownloadStatus.cancelled,
  }.contains(status);
  bool get canRetry =>
      status == DiscoverDownloadStatus.failed ||
      status == DiscoverDownloadStatus.cancelled;
  bool get canImport =>
      status == DiscoverDownloadStatus.completed && localPath != null;
  bool get isPausable => false;

  DiscoverDownloadItem copyWith({
    DiscoverDownloadStatus? status,
    String? displayName,
    String? fileName,
    String? localPath,
    String? mimeType,
    DiscoverMediaKind? kind,
    int? receivedBytes,
    int? totalBytes,
    DateTime? updatedAt,
    String? errorMessage,
    Map<String, dynamic>? metadata,
    bool clearLocalPath = false,
    bool clearTotalBytes = false,
    bool clearErrorMessage = false,
  }) {
    return DiscoverDownloadItem(
      id: id,
      source: source,
      status: status ?? this.status,
      sourceUrl: sourceUrl,
      pageUrl: pageUrl,
      displayName: displayName ?? this.displayName,
      fileName: fileName ?? this.fileName,
      localPath: clearLocalPath ? null : localPath ?? this.localPath,
      mimeType: mimeType ?? this.mimeType,
      kind: kind ?? this.kind,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: clearTotalBytes ? null : totalBytes ?? this.totalBytes,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'source': source.name,
    'status': status.name,
    'sourceUrl': sourceUrl,
    if (pageUrl != null) 'pageUrl': pageUrl,
    'displayName': displayName,
    'fileName': fileName,
    if (localPath != null) 'localPath': localPath,
    if (mimeType != null) 'mimeType': mimeType,
    'kind': kind.name,
    'receivedBytes': receivedBytes,
    if (totalBytes != null) 'totalBytes': totalBytes,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (errorMessage != null) 'errorMessage': errorMessage,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory DiscoverDownloadItem.fromJson(Map<String, dynamic> json) {
    final createdAt =
        DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return DiscoverDownloadItem(
      id: json['id']?.toString() ?? '',
      source: _enumValue(
        DiscoverDownloadSource.values,
        json['source'],
        DiscoverDownloadSource.direct,
      ),
      status: _enumValue(
        DiscoverDownloadStatus.values,
        json['status'],
        DiscoverDownloadStatus.failed,
      ),
      sourceUrl: json['sourceUrl']?.toString() ?? '',
      pageUrl: json['pageUrl']?.toString(),
      displayName: json['displayName']?.toString() ?? 'Downloaded media',
      fileName: json['fileName']?.toString() ?? '',
      localPath: json['localPath']?.toString(),
      mimeType: json['mimeType']?.toString(),
      kind: _enumValue(
        DiscoverMediaKind.values,
        json['kind'],
        DiscoverMediaKind.unknown,
      ),
      receivedBytes: _nullableInt(json['receivedBytes']) ?? 0,
      totalBytes: _nullableInt(json['totalBytes']),
      createdAt: createdAt,
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? createdAt,
      errorMessage: json['errorMessage']?.toString(),
      metadata: _jsonMap(json['metadata']),
    );
  }
}
