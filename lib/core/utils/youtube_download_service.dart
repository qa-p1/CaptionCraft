import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../features/editor/models/discover_models.dart';

typedef YoutubeProgressCallback =
    void Function(int receivedBytes, int? totalBytes);

class YoutubeDownloadCancelledException implements Exception {
  const YoutubeDownloadCancelledException();

  @override
  String toString() => 'YouTube download was cancelled.';
}

class YoutubeDownloadResult {
  const YoutubeDownloadResult({
    required this.path,
    required this.mimeType,
    required this.totalBytes,
  });

  final String path;
  final String mimeType;
  final int totalBytes;
}

abstract class YoutubeMediaService {
  Future<YoutubeVideoInfo> inspect(String url);

  Future<YoutubeDownloadResult> download({
    required String jobId,
    required YoutubeVideoInfo info,
    required YoutubeFormatOption format,
    required String outputPath,
    required YoutubeProgressCallback onProgress,
    required void Function() onProcessing,
    int maxBytes,
  });

  Future<void> cancel(String jobId);

  void dispose();
}

abstract class YoutubeMuxRunner {
  Future<void> mux({
    required String jobId,
    required String videoPath,
    required String audioPath,
    required String outputPath,
    required String container,
  });

  Future<void> cancel(String jobId);
}

class FfmpegYoutubeMuxRunner implements YoutubeMuxRunner {
  final Map<String, int> _sessionIds = <String, int>{};
  final Set<String> _cancelledJobs = <String>{};

  @override
  Future<void> mux({
    required String jobId,
    required String videoPath,
    required String audioPath,
    required String outputPath,
    required String container,
  }) async {
    final completer = Completer<void>();
    final normalizedContainer = container == 'webm' ? 'webm' : 'mp4';
    final arguments = <String>[
      '-y',
      '-i',
      videoPath,
      '-i',
      audioPath,
      '-map',
      '0:v:0',
      '-map',
      '1:a:0',
      '-c',
      'copy',
      '-shortest',
      if (normalizedContainer == 'mp4') ...['-movflags', '+faststart'],
      '-f',
      normalizedContainer,
      outputPath,
    ];

    try {
      final session = await FFmpegKit.executeWithArgumentsAsync(arguments, (
        completedSession,
      ) {
        unawaited(_completeSession(completedSession, completer));
      });
      final sessionId = session.getSessionId();
      if (sessionId != null) _sessionIds[jobId] = sessionId;
      if (_cancelledJobs.contains(jobId) && sessionId != null) {
        await FFmpegKit.cancel(sessionId);
      }
      await completer.future;
    } finally {
      _sessionIds.remove(jobId);
      _cancelledJobs.remove(jobId);
    }
  }

  Future<void> _completeSession(
    FFmpegSession session,
    Completer<void> completer,
  ) async {
    if (completer.isCompleted) return;
    try {
      final returnCode = await session.getReturnCode();
      if (ReturnCode.isSuccess(returnCode)) {
        completer.complete();
        return;
      }
      if (ReturnCode.isCancel(returnCode)) {
        completer.completeError(const YoutubeDownloadCancelledException());
        return;
      }
      final output = await session.getOutput();
      completer.completeError(
        StateError(
          output == null || output.trim().isEmpty
              ? 'FFmpeg could not combine the selected video and audio streams.'
              : 'FFmpeg could not combine the selected streams: ${_tail(output)}',
        ),
      );
    } catch (error, stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
  }

  static String _tail(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 320) return compact;
    return compact.substring(compact.length - 320);
  }

  @override
  Future<void> cancel(String jobId) async {
    _cancelledJobs.add(jobId);
    final sessionId = _sessionIds[jobId];
    if (sessionId != null) await FFmpegKit.cancel(sessionId);
  }
}

class YoutubeDownloadService implements YoutubeMediaService {
  YoutubeDownloadService({
    YoutubeExplode Function()? clientFactory,
    YoutubeMuxRunner? muxRunner,
  }) : _clientFactory = clientFactory ?? YoutubeExplode.new,
       _muxRunner = muxRunner ?? FfmpegYoutubeMuxRunner();

  static const int defaultMaxBytes = 1024 * 1024 * 1024;

  final YoutubeExplode Function() _clientFactory;
  final YoutubeMuxRunner _muxRunner;
  final Map<String, _YoutubeJobControl> _jobs = <String, _YoutubeJobControl>{};
  bool _disposed = false;

  /// Accepts normal watch, share, Shorts, live, and embed URLs from YouTube.
  /// Raw eleven-character IDs and lookalike hosts are deliberately rejected.
  static String? parseVideoIdFromUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final host = uri.host.toLowerCase();
    String? id;
    if (host == 'youtu.be' || host == 'www.youtu.be') {
      id = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
    } else if (const <String>{
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com',
      'youtube-nocookie.com',
      'www.youtube-nocookie.com',
    }.contains(host)) {
      if (uri.path == '/watch') {
        id = uri.queryParameters['v'];
      } else if (uri.pathSegments.length >= 2 &&
          const <String>{
            'shorts',
            'embed',
            'live',
          }.contains(uri.pathSegments.first)) {
        id = uri.pathSegments[1];
      }
    }
    return id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)
        ? id
        : null;
  }

  @override
  Future<YoutubeVideoInfo> inspect(String url) async {
    _ensureActive();
    final videoId = parseVideoIdFromUrl(url);
    if (videoId == null) {
      throw const FormatException('Enter a valid HTTPS YouTube video URL.');
    }
    final client = _clientFactory();
    try {
      final video = await client.videos.get(videoId);
      final manifest = await client.videos.streams.getManifest(videoId);
      final formats = _buildFormats(manifest);
      if (formats.isEmpty) {
        throw StateError(
          'No downloadable streams are available for this video.',
        );
      }
      return YoutubeVideoInfo(
        videoId: video.id.value,
        canonicalUrl: video.url,
        title: video.title,
        author: video.author,
        thumbnailUrl: video.thumbnails.maxResUrl,
        duration: video.duration ?? Duration.zero,
        formats: List<YoutubeFormatOption>.unmodifiable(formats),
      );
    } finally {
      client.close();
    }
  }

  List<YoutubeFormatOption> _buildFormats(StreamManifest manifest) {
    final formats = <YoutubeFormatOption>[];
    for (final stream in manifest.muxed) {
      formats.add(
        YoutubeFormatOption(
          id: 'muxed:${stream.tag}',
          label: _videoLabel(
            stream.qualityLabel,
            stream.container.name,
            stream.framerate.framesPerSecond.toInt(),
            stream.size.totalBytes,
            false,
          ),
          kind: YoutubeDownloadKind.muxedVideo,
          container: stream.container.name,
          videoFormatTag: stream.tag,
          audioFormatTag: stream.tag,
          resolutionLabel: stream.qualityLabel,
          width: stream.videoResolution.width,
          height: stream.videoResolution.height,
          framesPerSecond: stream.framerate.framesPerSecond.toInt(),
          bitrate: stream.bitrate.bitsPerSecond,
          estimatedBytes: stream.size.totalBytes,
          videoCodec: stream.videoCodec,
          audioCodec: stream.audioCodec,
        ),
      );
    }

    for (final stream in manifest.audioOnly) {
      final extension = stream.container.name == 'mp4'
          ? 'm4a'
          : stream.container.name;
      formats.add(
        YoutubeFormatOption(
          id: 'audio:${stream.tag}',
          label:
              '${(stream.bitrate.bitsPerSecond / 1000).round()} kbps · '
              '${extension.toUpperCase()} · ${_sizeLabel(stream.size.totalBytes)}',
          kind: YoutubeDownloadKind.audioOnly,
          container: extension,
          audioFormatTag: stream.tag,
          bitrate: stream.bitrate.bitsPerSecond,
          estimatedBytes: stream.size.totalBytes,
          audioCodec: stream.audioCodec,
        ),
      );
    }

    final audioStreams = manifest.audioOnly.toList(growable: false);
    for (final video in manifest.videoOnly) {
      final matchingAudio =
          audioStreams
              .where((audio) => audio.container.name == video.container.name)
              .toList()
            ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      if (matchingAudio.isEmpty) continue;
      final audio = matchingAudio.first;
      formats.add(
        YoutubeFormatOption(
          id: 'split:${video.tag}+${audio.tag}',
          label: _videoLabel(
            video.qualityLabel,
            video.container.name,
            video.framerate.framesPerSecond.toInt(),
            video.size.totalBytes + audio.size.totalBytes,
            true,
          ),
          kind: YoutubeDownloadKind.splitVideoAudio,
          container: video.container.name,
          videoFormatTag: video.tag,
          audioFormatTag: audio.tag,
          resolutionLabel: video.qualityLabel,
          width: video.videoResolution.width,
          height: video.videoResolution.height,
          framesPerSecond: video.framerate.framesPerSecond.toInt(),
          bitrate: video.bitrate.bitsPerSecond + audio.bitrate.bitsPerSecond,
          estimatedBytes: video.size.totalBytes + audio.size.totalBytes,
          videoCodec: video.videoCodec,
          audioCodec: audio.audioCodec,
        ),
      );
    }

    formats.sort((a, b) {
      final kindOrder = _kindOrder(a.kind).compareTo(_kindOrder(b.kind));
      if (kindOrder != 0) return kindOrder;
      final height = (b.height ?? 0).compareTo(a.height ?? 0);
      if (height != 0) return height;
      final fps = (b.framesPerSecond ?? 0).compareTo(a.framesPerSecond ?? 0);
      if (fps != 0) return fps;
      return (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
    });
    return formats;
  }

  static int _kindOrder(YoutubeDownloadKind kind) => switch (kind) {
    YoutubeDownloadKind.splitVideoAudio => 0,
    YoutubeDownloadKind.muxedVideo => 1,
    YoutubeDownloadKind.audioOnly => 2,
  };

  static String _videoLabel(
    String quality,
    String container,
    int fps,
    int bytes,
    bool split,
  ) {
    return '$quality · ${container.toUpperCase()} · $fps fps · '
        '${_sizeLabel(bytes)}${split ? ' · video + audio' : ''}';
  }

  static String _sizeLabel(int bytes) {
    if (bytes <= 0) return 'unknown size';
    final megabytes = bytes / (1024 * 1024);
    return megabytes >= 1024
        ? '${(megabytes / 1024).toStringAsFixed(1)} GB'
        : '${megabytes.toStringAsFixed(megabytes >= 10 ? 0 : 1)} MB';
  }

  @override
  Future<YoutubeDownloadResult> download({
    required String jobId,
    required YoutubeVideoInfo info,
    required YoutubeFormatOption format,
    required String outputPath,
    required YoutubeProgressCallback onProgress,
    required void Function() onProcessing,
    int maxBytes = defaultMaxBytes,
  }) async {
    _ensureActive();
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    if (_jobs.containsKey(jobId)) {
      throw StateError('A YouTube job with this id is already active.');
    }
    final declaredFormat = info.formats
        .where((candidate) => candidate.id == format.id)
        .firstOrNull;
    if (declaredFormat == null) {
      throw ArgumentError('The selected format is not part of this video.');
    }
    final expectedBytes = declaredFormat.estimatedBytes;
    if (expectedBytes != null && expectedBytes > maxBytes) {
      throw StateError('The selected format exceeds the download size limit.');
    }

    final control = _YoutubeJobControl(_clientFactory());
    _jobs[jobId] = control;
    final output = File(outputPath);
    final outputPart = File('$outputPath.part');
    final tempVideo = File('$outputPath.$jobId.video.part');
    final tempAudio = File('$outputPath.$jobId.audio.part');
    try {
      await output.parent.create(recursive: true);
      await _deleteIfExists(outputPart);
      await _deleteIfExists(tempVideo);
      await _deleteIfExists(tempAudio);
      _throwIfCancelled(control);

      final manifest = await control.client.videos.streams.getManifest(
        info.videoId,
      );
      _throwIfCancelled(control);

      switch (declaredFormat.kind) {
        case YoutubeDownloadKind.muxedVideo:
          final stream = _findStream(
            manifest.muxed,
            declaredFormat.videoFormatTag,
            'muxed',
          );
          await _writeStream(
            control,
            control.client.videos.streams.get(stream),
            outputPart,
            stream.size.totalBytes,
            maxBytes,
            onProgress,
          );
        case YoutubeDownloadKind.audioOnly:
          final stream = _findStream(
            manifest.audioOnly,
            declaredFormat.audioFormatTag,
            'audio',
          );
          await _writeStream(
            control,
            control.client.videos.streams.get(stream),
            outputPart,
            stream.size.totalBytes,
            maxBytes,
            onProgress,
          );
        case YoutubeDownloadKind.splitVideoAudio:
          final video = _findStream(
            manifest.videoOnly,
            declaredFormat.videoFormatTag,
            'video',
          );
          final audio = _findStream(
            manifest.audioOnly,
            declaredFormat.audioFormatTag,
            'audio',
          );
          final total = video.size.totalBytes + audio.size.totalBytes;
          var videoReceived = 0;
          await _writeStream(
            control,
            control.client.videos.streams.get(video),
            tempVideo,
            video.size.totalBytes,
            maxBytes,
            (received, _) {
              videoReceived = received;
              onProgress(received, total);
            },
          );
          await _writeStream(
            control,
            control.client.videos.streams.get(audio),
            tempAudio,
            audio.size.totalBytes,
            maxBytes - videoReceived,
            (received, _) => onProgress(videoReceived + received, total),
          );
          _throwIfCancelled(control);
          onProcessing();
          control.muxing = true;
          await _muxRunner.mux(
            jobId: jobId,
            videoPath: tempVideo.path,
            audioPath: tempAudio.path,
            outputPath: outputPart.path,
            container: declaredFormat.container,
          );
          _throwIfCancelled(control);
      }

      _throwIfCancelled(control);
      if (!await outputPart.exists() || await outputPart.length() == 0) {
        throw StateError('The downloaded YouTube file is empty.');
      }
      await _deleteIfExists(output);
      await outputPart.rename(output.path);
      final bytes = await output.length();
      onProgress(bytes, bytes);
      return YoutubeDownloadResult(
        path: output.path,
        mimeType: _mimeFor(declaredFormat),
        totalBytes: bytes,
      );
    } catch (error) {
      if (control.cancelled && error is! YoutubeDownloadCancelledException) {
        throw const YoutubeDownloadCancelledException();
      }
      rethrow;
    } finally {
      control.client.close();
      _jobs.remove(jobId);
      await _deleteIfExists(tempVideo);
      await _deleteIfExists(tempAudio);
      await _deleteIfExists(outputPart);
    }
  }

  static T _findStream<T extends StreamInfo>(
    Iterable<T> streams,
    int? tag,
    String type,
  ) {
    if (tag != null) {
      for (final stream in streams) {
        if (stream.tag == tag) return stream;
      }
    }
    throw StateError(
      'The selected YouTube $type stream is no longer available.',
    );
  }

  static Future<void> _writeStream(
    _YoutubeJobControl control,
    Stream<List<int>> stream,
    File file,
    int reportedTotal,
    int maxBytes,
    YoutubeProgressCallback onProgress,
  ) async {
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in stream) {
        _throwIfCancelled(control);
        received += chunk.length;
        if (received > maxBytes) {
          throw StateError('The download exceeded the size limit.');
        }
        sink.add(chunk);
        onProgress(received, reportedTotal > 0 ? reportedTotal : null);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    _throwIfCancelled(control);
  }

  static void _throwIfCancelled(_YoutubeJobControl control) {
    if (control.cancelled) throw const YoutubeDownloadCancelledException();
  }

  static String _mimeFor(YoutubeFormatOption format) {
    if (format.kind == YoutubeDownloadKind.audioOnly) {
      return switch (format.container) {
        'm4a' || 'mp4' => 'audio/mp4',
        'webm' => 'audio/webm',
        _ => 'audio/${format.container}',
      };
    }
    return switch (format.container) {
      'mp4' => 'video/mp4',
      'webm' => 'video/webm',
      _ => 'video/${format.container}',
    };
  }

  static Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> cancel(String jobId) async {
    final control = _jobs[jobId];
    if (control == null) return;
    control.cancelled = true;
    if (control.muxing) await _muxRunner.cancel(jobId);
    control.client.close();
  }

  void _ensureActive() {
    if (_disposed) throw StateError('YoutubeDownloadService is disposed.');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final control in _jobs.values) {
      control.cancelled = true;
      control.client.close();
    }
    for (final jobId in _jobs.keys.toList(growable: false)) {
      unawaited(_muxRunner.cancel(jobId));
    }
  }
}

class _YoutubeJobControl {
  _YoutubeJobControl(this.client);

  final YoutubeExplode client;
  bool cancelled = false;
  bool muxing = false;
}
