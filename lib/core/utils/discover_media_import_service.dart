import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../features/editor/models/discover_models.dart';
import '../../features/editor/models/timeline_models.dart';

enum DiscoverTranscodeKind { imageToPng, videoToMp4, audioToM4a }

class DiscoverMediaProbeResult {
  const DiscoverMediaProbeResult({
    required this.duration,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.hasVideo,
    required this.hasAudio,
    required this.fileSize,
    this.videoCodec,
    this.audioCodec,
    this.container,
  });

  final Duration duration;
  final int width;
  final int height;
  final double frameRate;
  final bool hasVideo;
  final bool hasAudio;
  final int fileSize;
  final String? videoCodec;
  final String? audioCodec;
  final String? container;
}

abstract class DiscoverMediaImportBackend {
  Future<DiscoverMediaProbeResult> probe(String path);

  Future<void> transcode({
    required String jobId,
    required DiscoverTranscodeKind kind,
    required String inputPath,
    required String outputPath,
    required Duration sourceDuration,
    void Function(double progress)? onProgress,
  });

  Future<void> cancel(String jobId);
}

class FfmpegDiscoverMediaImportBackend implements DiscoverMediaImportBackend {
  final Map<String, int> _sessionIds = <String, int>{};
  final Set<String> _cancelledJobs = <String>{};

  @override
  Future<DiscoverMediaProbeResult> probe(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final information = session.getMediaInformation();
    if (information == null) {
      throw StateError('The downloaded media is unreadable or corrupted.');
    }
    var width = 0;
    var height = 0;
    var frameRate = 0.0;
    var hasVideo = false;
    var hasAudio = false;
    String? videoCodec;
    String? audioCodec;
    for (final stream in information.getStreams()) {
      if (stream.getType() == 'video' && !hasVideo) {
        hasVideo = true;
        width = stream.getWidth() ?? 0;
        height = stream.getHeight() ?? 0;
        frameRate = _parseFrameRate(
          stream.getAverageFrameRate() ?? stream.getRealFrameRate(),
        );
        videoCodec = stream.getCodec();
      } else if (stream.getType() == 'audio' && !hasAudio) {
        hasAudio = true;
        audioCodec = stream.getCodec();
      }
    }
    final durationSeconds =
        double.tryParse(information.getDuration() ?? '') ?? 0;
    return DiscoverMediaProbeResult(
      duration: Duration(
        milliseconds: (durationSeconds * 1000).round().clamp(0, 1 << 53),
      ),
      width: width,
      height: height,
      frameRate: frameRate,
      hasVideo: hasVideo,
      hasAudio: hasAudio,
      videoCodec: videoCodec,
      audioCodec: audioCodec,
      container: information.getFormat(),
      fileSize:
          int.tryParse(information.getSize() ?? '') ??
          await File(path).length(),
    );
  }

  static double _parseFrameRate(String? value) {
    if (value == null || value.isEmpty) return 0;
    final parts = value.split('/');
    if (parts.length == 2) {
      final numerator = double.tryParse(parts[0]) ?? 0;
      final denominator = double.tryParse(parts[1]) ?? 0;
      return denominator == 0 ? 0 : numerator / denominator;
    }
    return double.tryParse(value) ?? 0;
  }

  @override
  Future<void> transcode({
    required String jobId,
    required DiscoverTranscodeKind kind,
    required String inputPath,
    required String outputPath,
    required Duration sourceDuration,
    void Function(double progress)? onProgress,
  }) async {
    final completer = Completer<void>();
    final arguments = switch (kind) {
      DiscoverTranscodeKind.imageToPng => <String>[
        '-y',
        '-i',
        inputPath,
        '-frames:v',
        '1',
        '-an',
        '-c:v',
        'png',
        '-f',
        'image2',
        outputPath,
      ],
      DiscoverTranscodeKind.videoToMp4 => <String>[
        '-y',
        '-i',
        inputPath,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-vf',
        'scale=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p',
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '20',
        '-c:a',
        'aac',
        '-b:a',
        '192k',
        '-movflags',
        '+faststart',
        '-f',
        'mp4',
        outputPath,
      ],
      DiscoverTranscodeKind.audioToM4a => <String>[
        '-y',
        '-i',
        inputPath,
        '-map',
        '0:a:0',
        '-vn',
        '-c:a',
        'aac',
        '-b:a',
        '192k',
        '-f',
        'ipod',
        outputPath,
      ],
    };

    try {
      final session = await FFmpegKit.executeWithArgumentsAsync(
        arguments,
        (completedSession) {
          unawaited(_completeSession(completedSession, completer));
        },
        null,
        (Statistics statistics) {
          if (sourceDuration <= Duration.zero) return;
          onProgress?.call(
            (statistics.getTime() / sourceDuration.inMilliseconds)
                .clamp(0.0, 0.99)
                .toDouble(),
          );
        },
      );
      final sessionId = session.getSessionId();
      if (sessionId != null) _sessionIds[jobId] = sessionId;
      if (_cancelledJobs.contains(jobId) && sessionId != null) {
        await FFmpegKit.cancel(sessionId);
      }
      await completer.future;
      onProgress?.call(1);
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
      } else if (ReturnCode.isCancel(returnCode)) {
        completer.completeError(const DiscoverMediaImportCancelledException());
      } else {
        final output = await session.getOutput();
        completer.completeError(
          StateError(
            output == null || output.trim().isEmpty
                ? 'FFmpeg could not normalize the downloaded media.'
                : 'FFmpeg could not normalize the media: ${_tail(output)}',
          ),
        );
      }
    } catch (error, stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
  }

  static String _tail(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return compact.length <= 300
        ? compact
        : compact.substring(compact.length - 300);
  }

  @override
  Future<void> cancel(String jobId) async {
    _cancelledJobs.add(jobId);
    final sessionId = _sessionIds[jobId];
    if (sessionId != null) await FFmpegKit.cancel(sessionId);
  }
}

class DiscoverMediaImportCancelledException implements Exception {
  const DiscoverMediaImportCancelledException();

  @override
  String toString() => 'Media import was cancelled.';
}

class DiscoverMediaImportResult {
  const DiscoverMediaImportResult({
    required this.jobId,
    required this.path,
    required this.label,
    required this.assetType,
    required this.clipType,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.hasAudio,
    required this.mimeType,
    required this.fileSize,
    required this.wasTranscoded,
    required this.metadata,
    this.duration,
    this.videoCodec,
    this.audioCodec,
  });

  final String jobId;
  final String path;
  final String label;
  final EditorAssetType assetType;
  final TimelineTrackType clipType;
  final Duration? duration;
  final int width;
  final int height;
  final double frameRate;
  final bool hasAudio;
  final String? videoCodec;
  final String? audioCodec;
  final String mimeType;
  final int fileSize;
  final bool wasTranscoded;
  final Map<String, dynamic> metadata;
}

class DiscoverMediaImportService {
  DiscoverMediaImportService({
    Directory? documentsDirectoryOverride,
    Directory? managedDownloadsDirectoryOverride,
    DiscoverMediaImportBackend? backend,
    DateTime Function()? clock,
    String Function()? jobIdGenerator,
  }) : _documentsDirectoryOverride = documentsDirectoryOverride,
       _managedDownloadsDirectoryOverride = managedDownloadsDirectoryOverride,
       _backend = backend ?? FfmpegDiscoverMediaImportBackend(),
       _clock = clock ?? DateTime.now,
       _jobIdGenerator = jobIdGenerator ?? const Uuid().v4;

  final Directory? _documentsDirectoryOverride;
  final Directory? _managedDownloadsDirectoryOverride;
  final DiscoverMediaImportBackend _backend;
  final DateTime Function() _clock;
  final String Function() _jobIdGenerator;
  final Set<String> _activeJobs = <String>{};
  final Set<String> _cancelledJobs = <String>{};
  bool _disposed = false;

  /// Copies a completed Discover download into durable editor media storage.
  /// Unsupported still/video formats are normalized to PNG/H.264 MP4. Audio
  /// is normalized to AAC M4A when requested or when its extension is unsafe.
  Future<DiscoverMediaImportResult> importDownload(
    DiscoverDownloadItem item, {
    Directory? destinationDirectory,
    bool normalizeAudio = false,
    void Function(double progress)? onProgress,
    String? jobId,
  }) async {
    _ensureActive();
    if (!item.canImport || item.localPath == null) {
      throw StateError('Only completed Discover downloads can be imported.');
    }
    final resolvedJobId = _safeJobId(jobId ?? _jobIdGenerator());
    if (!_activeJobs.add(resolvedJobId)) {
      throw StateError('This media import is already running.');
    }

    File? partial;
    File? destination;
    try {
      final documents =
          _documentsDirectoryOverride ??
          await getApplicationDocumentsDirectory();
      final managedDownloads =
          _managedDownloadsDirectoryOverride ??
          Directory(
            p.join(documents.path, 'CaptionCraft', 'discover_downloads'),
          );
      final input = File(p.normalize(p.absolute(item.localPath!)));
      await _validateManagedInput(input, managedDownloads);
      final sourceLength = await input.length();
      if (sourceLength <= 0) {
        throw StateError('The downloaded media file is empty.');
      }
      _throwIfCancelled(resolvedJobId);

      final sourceExtension = p.extension(input.path).toLowerCase();
      final sourceMime = item.mimeType ?? lookupMimeType(input.path);
      final mediaKind = _resolveKind(item.kind, sourceMime, sourceExtension);
      DiscoverMediaProbeResult? sourceProbe;
      try {
        sourceProbe = await _backend.probe(input.path);
      } catch (_) {
        if (mediaKind != DiscoverMediaKind.image ||
            _isEditorReadableImage(sourceMime, sourceExtension)) {
          rethrow;
        }
      }
      _throwIfCancelled(resolvedJobId);

      final plan = _buildPlan(
        mediaKind: mediaKind,
        sourceExtension: sourceExtension,
        sourceMime: sourceMime,
        sourceProbe: sourceProbe,
        normalizeAudio: normalizeAudio,
      );
      final mediaDirectory =
          destinationDirectory ??
          Directory(p.join(documents.path, 'CaptionCraft', 'media'));
      await mediaDirectory.create(recursive: true);
      destination = await _uniqueDestination(
        mediaDirectory,
        item.displayName,
        plan.extension,
        resolvedJobId,
      );
      partial = File('${destination.path}.part');
      await _deleteIfExists(partial);
      onProgress?.call(0);

      if (plan.transcodeKind == null) {
        await _copyWithProgress(
          resolvedJobId,
          input,
          partial,
          sourceLength,
          onProgress,
        );
      } else {
        await _backend.transcode(
          jobId: resolvedJobId,
          kind: plan.transcodeKind!,
          inputPath: input.path,
          outputPath: partial.path,
          sourceDuration: sourceProbe?.duration ?? Duration.zero,
          onProgress: onProgress,
        );
      }
      _throwIfCancelled(resolvedJobId);
      if (!await partial.exists() || await partial.length() <= 0) {
        throw StateError('The editor-ready media file could not be created.');
      }
      final finalProbe = await _backend.probe(partial.path);
      _validateFinalProbe(plan.assetType, finalProbe);
      _throwIfCancelled(resolvedJobId);
      await partial.rename(destination.path);
      if (_cancelledJobs.contains(resolvedJobId)) {
        await _deleteIfExists(destination);
        throw const DiscoverMediaImportCancelledException();
      }

      final finalLength = await destination.length();
      final duration = plan.assetType == EditorAssetType.image
          ? null
          : finalProbe.duration > Duration.zero
          ? finalProbe.duration
          : null;
      final metadata = <String, dynamic>{
        if (duration != null) 'durationMs': duration.inMilliseconds,
        'width': finalProbe.width,
        'height': finalProbe.height,
        'frameRate': finalProbe.frameRate,
        'hasAudio': finalProbe.hasAudio,
        if (finalProbe.videoCodec != null) 'videoCodec': finalProbe.videoCodec,
        if (finalProbe.audioCodec != null) 'audioCodec': finalProbe.audioCodec,
        'fileSize': finalLength,
        'mimeType': plan.mimeType,
        'discoverDownloadId': item.id,
        'discoverSourceUrl': item.sourceUrl,
        'wasTranscoded': plan.transcodeKind != null,
      };
      onProgress?.call(1);
      return DiscoverMediaImportResult(
        jobId: resolvedJobId,
        path: destination.path,
        label: item.displayName,
        assetType: plan.assetType,
        clipType: plan.clipType,
        duration: duration,
        width: finalProbe.width,
        height: finalProbe.height,
        frameRate: finalProbe.frameRate,
        hasAudio: finalProbe.hasAudio,
        videoCodec: finalProbe.videoCodec,
        audioCodec: finalProbe.audioCodec,
        mimeType: plan.mimeType,
        fileSize: finalLength,
        wasTranscoded: plan.transcodeKind != null,
        metadata: Map<String, dynamic>.unmodifiable(metadata),
      );
    } catch (error) {
      if (_cancelledJobs.contains(resolvedJobId) &&
          error is! DiscoverMediaImportCancelledException) {
        throw const DiscoverMediaImportCancelledException();
      }
      rethrow;
    } finally {
      if (partial != null) await _deleteIfExists(partial);
      _activeJobs.remove(resolvedJobId);
      _cancelledJobs.remove(resolvedJobId);
    }
  }

  static const Set<String> _safeImageExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
  };
  static const Set<String> _safeVideoExtensions = <String>{
    '.mp4',
    '.mov',
    '.m4v',
  };
  static const Set<String> _safeAudioExtensions = <String>{
    '.mp3',
    '.wav',
    '.ogg',
    '.flac',
    '.m4a',
    '.aac',
  };

  static bool _isEditorReadableImage(String? mimeType, String extension) {
    final mime = mimeType?.split(';').first.trim().toLowerCase();
    if (const <String>{
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
    }.contains(mime)) {
      return true;
    }
    return mime == null &&
        (_safeImageExtensions.contains(extension) || extension == '.gif');
  }

  static _ImportPlan _buildPlan({
    required DiscoverMediaKind mediaKind,
    required String sourceExtension,
    required String? sourceMime,
    required DiscoverMediaProbeResult? sourceProbe,
    required bool normalizeAudio,
  }) {
    final mime = sourceMime?.split(';').first.trim().toLowerCase();
    switch (mediaKind) {
      case DiscoverMediaKind.image:
        if (mime == 'image/gif' ||
            (mime == null && sourceExtension == '.gif')) {
          return const _ImportPlan(
            extension: '.gif',
            mimeType: 'image/gif',
            assetType: EditorAssetType.gif,
            clipType: TimelineTrackType.gif,
          );
        }
        final mimeImageExtension = switch (mime) {
          'image/jpeg' => '.jpg',
          'image/png' => '.png',
          'image/webp' => '.webp',
          _ => null,
        };
        if (mimeImageExtension != null) {
          return _ImportPlan(
            extension: mimeImageExtension,
            mimeType: _imageMime(mimeImageExtension),
            assetType: EditorAssetType.image,
            clipType: TimelineTrackType.image,
          );
        }
        if (mime == null && _safeImageExtensions.contains(sourceExtension)) {
          return _ImportPlan(
            extension: sourceExtension,
            mimeType: _imageMime(sourceExtension),
            assetType: EditorAssetType.image,
            clipType: TimelineTrackType.image,
          );
        }
        return const _ImportPlan(
          extension: '.png',
          mimeType: 'image/png',
          assetType: EditorAssetType.image,
          clipType: TimelineTrackType.image,
          transcodeKind: DiscoverTranscodeKind.imageToPng,
        );
      case DiscoverMediaKind.video:
        final videoCodec = sourceProbe?.videoCodec?.toLowerCase();
        final audioCodec = sourceProbe?.audioCodec?.toLowerCase();
        final safeCodec =
            videoCodec == 'h264' &&
            (sourceProbe?.hasAudio != true || audioCodec == 'aac');
        final mimeVideoExtension = switch (mime) {
          'video/mp4' || 'application/mp4' => '.mp4',
          'video/quicktime' => '.mov',
          'video/x-m4v' => '.m4v',
          _ => null,
        };
        final safeContainer =
            mimeVideoExtension != null ||
            (mime == null && _safeVideoExtensions.contains(sourceExtension));
        if (safeContainer && safeCodec) {
          final extension = mimeVideoExtension ?? sourceExtension;
          return _ImportPlan(
            extension: extension,
            mimeType: extension == '.mov'
                ? 'video/quicktime'
                : extension == '.m4v'
                ? 'video/x-m4v'
                : 'video/mp4',
            assetType: EditorAssetType.video,
            clipType: TimelineTrackType.video,
          );
        }
        return const _ImportPlan(
          extension: '.mp4',
          mimeType: 'video/mp4',
          assetType: EditorAssetType.video,
          clipType: TimelineTrackType.video,
          transcodeKind: DiscoverTranscodeKind.videoToMp4,
        );
      case DiscoverMediaKind.audio:
        final mimeAudioExtension = switch (mime) {
          'audio/mpeg' => '.mp3',
          'audio/mp4' || 'audio/aac' => '.m4a',
          'audio/wav' || 'audio/x-wav' => '.wav',
          'audio/ogg' => '.ogg',
          'audio/flac' => '.flac',
          _ => null,
        };
        final safeAudio =
            mimeAudioExtension != null ||
            (mime == null && _safeAudioExtensions.contains(sourceExtension));
        if (!normalizeAudio && safeAudio) {
          final extension = mimeAudioExtension ?? sourceExtension;
          return _ImportPlan(
            extension: extension,
            mimeType: _audioMime(extension),
            assetType: EditorAssetType.audio,
            clipType: TimelineTrackType.audio,
          );
        }
        return const _ImportPlan(
          extension: '.m4a',
          mimeType: 'audio/mp4',
          assetType: EditorAssetType.audio,
          clipType: TimelineTrackType.audio,
          transcodeKind: DiscoverTranscodeKind.audioToM4a,
        );
      case DiscoverMediaKind.unknown:
        throw StateError('The downloaded file is not supported by the editor.');
    }
  }

  static DiscoverMediaKind _resolveKind(
    DiscoverMediaKind declared,
    String? mimeType,
    String extension,
  ) {
    if (declared != DiscoverMediaKind.unknown) return declared;
    final mime = mimeType?.toLowerCase() ?? '';
    if (mime.startsWith('image/')) return DiscoverMediaKind.image;
    if (mime.startsWith('video/')) return DiscoverMediaKind.video;
    if (mime.startsWith('audio/')) return DiscoverMediaKind.audio;
    if (_safeImageExtensions.contains(extension) ||
        const <String>{'.gif', '.avif', '.svg', '.bmp'}.contains(extension)) {
      return DiscoverMediaKind.image;
    }
    if (_safeVideoExtensions.contains(extension) ||
        const <String>{
          '.webm',
          '.mkv',
          '.avi',
          '.3gp',
          '.3gpp',
        }.contains(extension)) {
      return DiscoverMediaKind.video;
    }
    if (_safeAudioExtensions.contains(extension) || extension == '.opus') {
      return DiscoverMediaKind.audio;
    }
    return DiscoverMediaKind.unknown;
  }

  static void _validateFinalProbe(
    EditorAssetType assetType,
    DiscoverMediaProbeResult probe,
  ) {
    if (assetType == EditorAssetType.audio) {
      if (!probe.hasAudio || probe.duration <= Duration.zero) {
        throw StateError(
          'The normalized audio is unreadable or has no duration.',
        );
      }
      return;
    }
    if (!probe.hasVideo || probe.width <= 0 || probe.height <= 0) {
      throw StateError('The normalized visual media is unreadable.');
    }
    if ((assetType == EditorAssetType.video ||
            assetType == EditorAssetType.gif) &&
        probe.duration <= Duration.zero) {
      throw StateError('The normalized video has no readable duration.');
    }
  }

  static Future<void> _validateManagedInput(
    File input,
    Directory managedDownloads,
  ) async {
    if (!await input.exists()) {
      throw StateError('The downloaded media file is missing.');
    }
    final resolvedInput = p.normalize(await input.resolveSymbolicLinks());
    final resolvedRoot = p.normalize(
      await managedDownloads.resolveSymbolicLinks(),
    );
    final within = Platform.isWindows
        ? p.isWithin(resolvedRoot.toLowerCase(), resolvedInput.toLowerCase())
        : p.isWithin(resolvedRoot, resolvedInput);
    if (!within) {
      throw StateError(
        'The selected file is outside managed Discover storage.',
      );
    }
  }

  Future<void> _copyWithProgress(
    String jobId,
    File source,
    File destination,
    int totalBytes,
    void Function(double progress)? onProgress,
  ) async {
    final sink = destination.openWrite();
    var copied = 0;
    try {
      await for (final chunk in source.openRead()) {
        _throwIfCancelled(jobId);
        sink.add(chunk);
        copied += chunk.length;
        onProgress?.call(
          totalBytes <= 0 ? 0 : (copied / totalBytes).clamp(0, 1).toDouble(),
        );
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<File> _uniqueDestination(
    Directory directory,
    String displayName,
    String extension,
    String jobId,
  ) async {
    var stem = p
        .basenameWithoutExtension(displayName)
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_')
        .trim();
    if (stem.isEmpty) stem = 'discover_media';
    if (stem.length > 72) stem = stem.substring(0, 72).trimRight();
    final suffix = _clock().toUtc().microsecondsSinceEpoch;
    final shortJob = jobId.length <= 12 ? jobId : jobId.substring(0, 12);
    var candidate = File(
      p.join(directory.path, '${stem}_${suffix}_$shortJob$extension'),
    );
    var collision = 1;
    while (await candidate.exists() ||
        await File('${candidate.path}.part').exists()) {
      candidate = File(
        p.join(
          directory.path,
          '${stem}_${suffix}_${shortJob}_$collision$extension',
        ),
      );
      collision++;
    }
    return candidate;
  }

  static String _safeJobId(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (safe.isEmpty) return 'discover_import';
    return safe.length <= 100 ? safe : safe.substring(0, 100);
  }

  static String _imageMime(String extension) => switch (extension) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.webp' => 'image/webp',
    _ => 'image/png',
  };

  static String _audioMime(String extension) => switch (extension) {
    '.mp3' => 'audio/mpeg',
    '.m4a' || '.aac' => 'audio/mp4',
    '.wav' => 'audio/wav',
    '.ogg' => 'audio/ogg',
    '.flac' => 'audio/flac',
    _ => 'application/octet-stream',
  };

  void _throwIfCancelled(String jobId) {
    if (_cancelledJobs.contains(jobId)) {
      throw const DiscoverMediaImportCancelledException();
    }
  }

  Future<void> cancel(String jobId) async {
    final safeJobId = _safeJobId(jobId);
    if (!_activeJobs.contains(safeJobId)) return;
    _cancelledJobs.add(safeJobId);
    await _backend.cancel(safeJobId);
  }

  void _ensureActive() {
    if (_disposed) throw StateError('DiscoverMediaImportService is disposed.');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final jobId in _activeJobs) {
      _cancelledJobs.add(jobId);
      unawaited(_backend.cancel(jobId));
    }
  }

  static Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }
}

class _ImportPlan {
  const _ImportPlan({
    required this.extension,
    required this.mimeType,
    required this.assetType,
    required this.clipType,
    this.transcodeKind,
  });

  final String extension;
  final String mimeType;
  final EditorAssetType assetType;
  final TimelineTrackType clipType;
  final DiscoverTranscodeKind? transcodeKind;
}
