import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/editor/models/export_settings.dart';
import '../../features/editor/models/editor_effect_models.dart';
import '../../features/editor/models/subtitle_entry.dart';
import '../../features/editor/models/subtitle_style_model.dart';
import '../../features/editor/models/timeline_models.dart';
import '../../shared/models/project_model.dart';
import 'caption_font_service.dart';
import 'ffmpeg_service.dart';
import 'subtitle_export_service.dart';
import 'storage_capacity_service.dart';

class ExportCanvasSize {
  final int width;
  final int height;
  final int framesPerSecond;

  const ExportCanvasSize({
    required this.width,
    required this.height,
    required this.framesPerSecond,
  });

  double get aspectRatio => width / height;
}

class TimelineExportResult {
  final String outputPath;
  final int width;
  final int height;
  final int durationMs;
  final int fileSize;
  final bool hasAudio;

  const TimelineExportResult({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.fileSize,
    required this.hasAudio,
  });
}

class ExportStorageEstimate {
  const ExportStorageEstimate({
    required this.outputBytes,
    required this.workingBytes,
  });

  final int outputBytes;
  final int workingBytes;

  int get combinedBytes => outputBytes + workingBytes;
}

class TimelineExportService {
  TimelineExportService._();

  static const _freezeFramePreroll = Duration(seconds: 1);
  static const _maxNetworkAssetBytes = 64 * 1024 * 1024;
  static CancelToken? _activeDownloadCancelToken;

  @visibleForTesting
  static ExportStorageEstimate estimateStorageRequirements({
    required ExportCanvasSize canvasSize,
    required Duration duration,
    required ExportQuality quality,
    required bool includeAudio,
    required int networkAssetCount,
  }) {
    const referencePixelRate = 1920 * 1080 * 30;
    final pixelRate =
        canvasSize.width * canvasSize.height * canvasSize.framesPerSecond;
    final scale = math
        .pow(math.max(0.1, pixelRate / referencePixelRate), 0.7)
        .toDouble()
        .clamp(0.25, 4.0);
    final referenceMbps = switch (quality) {
      ExportQuality.compact => 6.0,
      ExportQuality.balanced => 10.0,
      ExportQuality.high => 18.0,
      ExportQuality.maximum => 28.0,
    };
    final seconds = math.max(1.0, duration.inMilliseconds / 1000);
    final audioMbps = includeAudio ? 0.24 : 0.0;
    final estimatedFileBytes =
        ((referenceMbps * scale + audioMbps) * 1000000 / 8 * seconds).ceil();
    final outputBytes = (estimatedFileBytes * 1.6).ceil() + 128 * 1024 * 1024;
    final safeNetworkCount = networkAssetCount.clamp(0, 128).toInt();
    final workingBytes =
        safeNetworkCount * _maxNetworkAssetBytes + 256 * 1024 * 1024;
    return ExportStorageEstimate(
      outputBytes: outputBytes,
      workingBytes: workingBytes,
    );
  }

  static Future<void> cancelActiveExport() async {
    final downloadToken = _activeDownloadCancelToken;
    if (downloadToken != null && !downloadToken.isCancelled) {
      downloadToken.cancel('Cancelled by user');
    }
    await FFmpegService.cancelAll();
  }

  static Future<TimelineExportResult> export({
    required Project project,
    required EditorTimeline timeline,
    required List<SubtitleEntry> subtitleEntries,
    required SubtitleStyleModel globalSubtitleStyle,
    required ExportSettings settings,
    required String outputPath,
    void Function(double progress)? onProgress,
    void Function(String stage)? onStage,
  }) async {
    _validateRenderableColorPipeline(timeline);
    final visualClips = _visibleVisualClips(timeline);
    if (visualClips.isEmpty) {
      throw Exception('The timeline has no visible image or video clips.');
    }

    final timelineDuration = timeline.duration;
    if (timelineDuration <= Duration.zero) {
      throw Exception('The timeline duration is invalid.');
    }

    onStage?.call('Checking media');
    onProgress?.call(0.02);

    final workingRoot = await getTemporaryDirectory();
    final workingDirectory = Directory(
      p.join(
        workingRoot.path,
        'cc_render_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await workingDirectory.create(recursive: true);
    final downloadCancelToken = CancelToken();
    _activeDownloadCancelToken = downloadCancelToken;
    String? assPath;
    String? captionFontDirectory;
    var exportCompleted = false;

    try {
      final sourcePaths = <String, Future<String>>{};
      Future<String> resolveSourcePath(TimelineClip clip) {
        final sourceKey = _sourceCacheKey(clip);
        return sourcePaths.putIfAbsent(
          sourceKey,
          () => _sourcePathForClip(
            project: project,
            timeline: timeline,
            clip: clip,
            workingDirectory: workingDirectory,
            downloadCancelToken: downloadCancelToken,
          ),
        );
      }

      final mediaInfoByPath = <String, Future<Map<String, dynamic>>>{};
      Future<Map<String, dynamic>> probeMedia(String sourcePath) {
        return mediaInfoByPath.putIfAbsent(
          sourcePath,
          () => FFmpegService.getMediaInfo(sourcePath),
        );
      }

      final firstSourcePath = await resolveSourcePath(visualClips.first.$2);
      final firstMediaInfo = await probeMedia(firstSourcePath);
      final canvasSize = resolveCanvasSize(
        timeline.canvasSettings,
        settings,
        sourceWidth: (firstMediaInfo['width'] as int?) ?? 1920,
        sourceHeight: (firstMediaInfo['height'] as int?) ?? 1080,
        sourceFrameRate:
            (firstMediaInfo['frameRate'] as num?)?.toDouble() ?? 30,
      );
      final networkAssetCount = timeline.tracks
          .expand((track) => track.clips)
          .where((clip) => clip.enabled && clip.endTime > clip.startTime)
          .map(timeline.assetForClip)
          .whereType<EditorAssetReference>()
          .where((asset) => asset.isNetworkBacked)
          .map((asset) => asset.id)
          .toSet()
          .length;
      final storageEstimate = estimateStorageRequirements(
        canvasSize: canvasSize,
        duration: timelineDuration,
        quality: settings.quality,
        includeAudio: settings.includeAudio,
        networkAssetCount: networkAssetCount,
      );
      final outputDirectory = File(outputPath).parent;
      await outputDirectory.create(recursive: true);
      if (_volumeRoot(outputDirectory.path) == _volumeRoot(workingRoot.path)) {
        await StorageCapacityService.requireAvailable(
          directory: outputDirectory,
          requiredBytes: storageEstimate.combinedBytes,
          operation: 'This export',
        );
      } else {
        await StorageCapacityService.requireAvailable(
          directory: outputDirectory,
          requiredBytes: storageEstimate.outputBytes,
          operation: 'The exported video',
        );
        await StorageCapacityService.requireAvailable(
          directory: workingRoot,
          requiredBytes: storageEstimate.workingBytes,
          operation: 'Export working files',
        );
      }

      final renderInputs = <TimelineRenderInput>[];
      var nextInputIndex = 0;
      final orderedTracks = timeline.tracks.asMap().entries.toList();

      onStage?.call('Resolving media');
      for (final trackEntry in orderedTracks) {
        final track = trackEntry.value;
        if (track.isHidden && track.section != TimelineTrackSection.audio) {
          continue;
        }
        for (final clip in track.clips) {
          if (!clip.enabled || clip.endTime <= clip.startTime) continue;
          if (clip.type == TimelineTrackType.text ||
              clip.type == TimelineTrackType.subtitle ||
              clip.type == TimelineTrackType.effect) {
            continue;
          }
          if (track.section != TimelineTrackSection.baseVideo &&
              track.section != TimelineTrackSection.overlay &&
              track.section != TimelineTrackSection.audio) {
            continue;
          }

          final sourcePath = await resolveSourcePath(clip);
          final asset = timeline.assetForClip(clip);
          final mediaInfo = await _mediaInfoForInput(
            asset,
            sourcePath,
            mediaInfoLoader: probeMedia,
          );
          renderInputs.add(
            TimelineRenderInput(
              index: nextInputIndex++,
              trackIndex: trackEntry.key,
              track: track,
              clip: clip,
              asset: asset,
              sourcePath: sourcePath,
              hasAudio:
                  clip.type == TimelineTrackType.audio ||
                  (mediaInfo['hasAudio'] as bool? ?? false),
              frameRate: (mediaInfo['frameRate'] as num?)?.toDouble(),
              colorPrimaries: mediaInfo['colorPrimaries'] as String?,
              colorTransfer: mediaInfo['colorTransfer'] as String?,
              colorSpace: mediaInfo['colorSpace'] as String?,
              colorRange: mediaInfo['colorRange'] as String?,
              pixelFormat: mediaInfo['pixelFormat'] as String?,
              bitDepth: mediaInfo['bitDepth'] as int?,
              audioStreamCount: mediaInfo['audioStreamCount'] as int?,
              audioChannels: mediaInfo['audioChannels'] as int?,
              audioChannelsByStream: audioChannelsByStreamFromMetadata(
                mediaInfo['audioStreams'],
              ),
            ),
          );
        }
      }

      if (!renderInputs.any((input) => input.isVisual)) {
        throw Exception('No readable visual clips were found.');
      }

      onProgress?.call(0.08);
      assPath = await buildAssTrack(
        timeline: timeline,
        subtitleEntries: subtitleEntries,
        globalSubtitleStyle: globalSubtitleStyle,
        settings: settings,
        canvasSize: canvasSize,
      );
      if (assPath != null) {
        await SubtitleExportService.preflightAssFile(assPath);
        final fontBundle = await CaptionFontService.prepareForExport();
        captionFontDirectory = fontBundle.directoryPath;
      }
      final args = buildFfmpegArguments(
        timeline: timeline,
        inputs: renderInputs,
        settings: settings,
        canvasSize: canvasSize,
        timelineDuration: timelineDuration,
        assPath: assPath,
        captionFontDirectory: captionFontDirectory,
        outputPath: outputPath,
      );

      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      await outputFile.parent.create(recursive: true);

      onStage?.call('Rendering timeline');
      await _execute(
        args,
        expectedDuration: timelineDuration,
        captionsExpected: assPath != null,
        onProgress: (value) {
          onProgress?.call(0.1 + value * 0.84);
        },
      );

      onStage?.call('Verifying export');
      onProgress?.call(0.96);
      if (!await outputFile.exists() || await outputFile.length() == 0) {
        throw Exception('The renderer did not create a valid output file.');
      }

      final outputInfo = await FFmpegService.getMediaInfo(outputPath);
      final outputWidth = (outputInfo['width'] as int?) ?? 0;
      final outputHeight = (outputInfo['height'] as int?) ?? 0;
      final outputDurationMs = (outputInfo['durationMs'] as int?) ?? 0;
      if (outputWidth <= 0 || outputHeight <= 0 || outputDurationMs <= 0) {
        throw Exception('The exported file failed media validation.');
      }
      final allowedDurationDifference = math.max(
        1000,
        (timelineDuration.inMilliseconds * 0.06).round(),
      );
      if ((outputDurationMs - timelineDuration.inMilliseconds).abs() >
          allowedDurationDifference) {
        throw Exception(
          'Export duration mismatch: expected '
          '${timelineDuration.inSeconds}s, got '
          '${Duration(milliseconds: outputDurationMs).inSeconds}s.',
        );
      }

      onProgress?.call(1);
      exportCompleted = true;
      return TimelineExportResult(
        outputPath: outputPath,
        width: outputWidth,
        height: outputHeight,
        durationMs: outputDurationMs,
        fileSize: await outputFile.length(),
        hasAudio: outputInfo['hasAudio'] as bool? ?? false,
      );
    } on FileSystemException catch (error) {
      if (StorageCapacityService.isDiskFull(error)) {
        throw Exception(
          'The device ran out of storage during export. The partial video was removed; free storage or choose a smaller export and try again.',
        );
      }
      rethrow;
    } finally {
      if (identical(_activeDownloadCancelToken, downloadCancelToken)) {
        _activeDownloadCancelToken = null;
      }
      if (!exportCompleted) {
        try {
          final partialOutput = File(outputPath);
          if (await partialOutput.exists()) await partialOutput.delete();
        } catch (_) {
          // A cancelled render may still have a file handle briefly open.
        }
      }
      if (assPath != null) {
        try {
          final assFile = File(assPath);
          if (await assFile.exists()) await assFile.delete();
        } catch (_) {
          // Export result is more important than temporary subtitle cleanup.
        }
      }
      try {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      } catch (_) {
        // Network-backed working media is temporary and can be retried later.
      }
    }
  }

  static String _volumeRoot(String path) {
    if (Platform.isWindows) {
      return p.windows.rootPrefix(p.windows.normalize(path)).toLowerCase();
    }
    return p.rootPrefix(p.normalize(p.absolute(path)));
  }

  /// Builds the exact argument list used by the mobile FFmpeg renderer.
  ///
  /// Keeping command planning independent from execution makes it possible to
  /// validate real multi-track renders with a desktop FFmpeg binary in tests.
  static List<String> buildFfmpegArguments({
    required EditorTimeline timeline,
    required List<TimelineRenderInput> inputs,
    required ExportSettings settings,
    required ExportCanvasSize canvasSize,
    required Duration timelineDuration,
    required String? assPath,
    String? captionFontDirectory,
    String? videoPreset,
    int? videoCrf,
    bool previewMode = false,
    required String outputPath,
  }) {
    _validateRenderableColorPipeline(timeline);
    final args = <String>['-hide_banner', '-y'];
    for (final input in inputs) {
      args.addAll(_inputArguments(input));
    }
    final frozenVisualInputIndices = <int, int>{};
    var nextInputIndex = inputs.length;
    for (final input in inputs.where(_usesFrozenVisualInput)) {
      frozenVisualInputIndices[input.index] = nextInputIndex++;
      args.addAll(_freezeInputArguments(input));
    }

    final filterGraph = _buildFilterGraph(
      timeline: timeline,
      inputs: inputs,
      frozenVisualInputIndices: frozenVisualInputIndices,
      settings: settings,
      canvasSize: canvasSize,
      timelineDuration: timelineDuration,
      assPath: assPath,
      captionFontDirectory: captionFontDirectory,
      previewMode: previewMode,
    );
    args
      ..addAll(['-filter_complex', filterGraph])
      ..addAll(['-map', '[vout]']);

    final hasAudioOutput = _hasAudibleInput(timeline, inputs, settings);
    if (hasAudioOutput) {
      args.addAll([
        '-map',
        '[aout]',
        '-c:a',
        'aac',
        '-b:a',
        settings.quality == ExportQuality.compact ? '128k' : '192k',
        '-ar',
        '48000',
      ]);
    } else {
      args.add('-an');
    }

    final hdrOutput =
        !previewMode &&
        timeline.colorManagement.preserveHdr &&
        (timeline.colorManagement.outputSpace == EditorColorSpace.hlg ||
            timeline.colorManagement.outputSpace == EditorColorSpace.pq ||
            timeline.colorManagement.outputSpace == EditorColorSpace.wideGamut);
    args.addAll([
      '-c:v',
      hdrOutput ? 'libx265' : 'libx264',
      '-preset',
      videoPreset ?? settings.preset,
      '-crf',
      '${videoCrf ?? settings.crf}',
      '-pix_fmt',
      hdrOutput ? 'yuv420p10le' : 'yuv420p',
      if (hdrOutput) ...[
        '-tag:v',
        'hvc1',
        '-profile:v',
        'main10',
        '-color_primaries',
        'bt2020',
        '-color_trc',
        switch (timeline.colorManagement.outputSpace) {
          EditorColorSpace.pq => 'smpte2084',
          EditorColorSpace.hlg => 'arib-std-b67',
          _ => 'bt709',
        },
        '-colorspace',
        'bt2020nc',
        '-color_range',
        'tv',
        if (timeline.colorManagement.outputSpace == EditorColorSpace.pq) ...[
          '-x265-params',
          _hdr10X265Parameters(timeline.colorManagement),
        ],
      ],
      '-t',
      _seconds(timelineDuration),
      '-movflags',
      '+faststart',
      '-max_muxing_queue_size',
      '4096',
      outputPath,
    ]);
    return args;
  }

  static String _hdr10X265Parameters(EditorColorManagementSettings management) {
    final maximumLuminance =
        (management.peakLuminanceNits.clamp(100.0, 10000.0) * 10000).round();
    const minimumLuminance = 50;
    return 'hdr-opt=1:repeat-headers=1:colorprim=9:transfer=16:'
        'colormatrix=9:'
        'master-display=G(8500,39850)B(6550,2300)R(35400,14600)'
        'WP(15635,16450)L($maximumLuminance,$minimumLuminance)';
  }

  /// Builds an audio-only render that uses the exact same clip timing, volume
  /// automation, fades, pan, ducking, and peak limiter as final export.
  ///
  /// The editor uses this for its preview mix bus. Rendering overlapping media
  /// into one continuous audio stream prevents a large collection of platform
  /// video players from independently owning the device audio clock.
  static List<String> buildPreviewAudioMixArguments({
    required EditorTimeline timeline,
    required List<TimelineRenderInput> inputs,
    required Duration timelineDuration,
    required String outputPath,
  }) {
    if (inputs.isEmpty) {
      throw ArgumentError.value(inputs, 'inputs', 'Must contain audio inputs.');
    }
    final safeDuration = timelineDuration <= Duration.zero
        ? const Duration(milliseconds: 1)
        : timelineDuration;
    final args = <String>['-hide_banner', '-y'];
    for (final input in inputs) {
      args.addAll(_inputArguments(input));
    }
    final filters = <String>[];
    final hasAudio = _appendAudioMixFilters(
      filters: filters,
      timeline: timeline,
      inputs: inputs,
      timelineDuration: safeDuration,
      includeAudio: true,
    );
    if (!hasAudio) {
      throw ArgumentError.value(
        inputs,
        'inputs',
        'Must contain at least one audible input.',
      );
    }
    args.addAll([
      '-filter_complex',
      filters.join(';'),
      '-map',
      '[aout]',
      '-vn',
      '-c:a',
      'aac',
      '-b:a',
      '192k',
      '-ar',
      '48000',
      '-ac',
      '2',
      '-t',
      _seconds(safeDuration),
      '-movflags',
      '+faststart',
      outputPath,
    ]);
    return args;
  }

  /// Builds an analysis pass from the same audio graph used by preview and
  /// export. The final JSON block is emitted by loudnorm while astats supplies
  /// sample peak and RMS measurements in the FFmpeg log.
  static List<String> buildAudioAnalysisArguments({
    required EditorTimeline timeline,
    required List<TimelineRenderInput> inputs,
    required Duration timelineDuration,
    required double targetLufs,
    required double peakLimitDb,
  }) {
    if (inputs.isEmpty) {
      throw ArgumentError.value(inputs, 'inputs', 'Must contain audio inputs.');
    }
    final safeDuration = timelineDuration <= Duration.zero
        ? const Duration(milliseconds: 1)
        : timelineDuration;
    final args = <String>['-hide_banner', '-y'];
    for (final input in inputs) {
      args.addAll(_inputArguments(input));
    }
    final filters = <String>[];
    final hasAudio = _appendAudioMixFilters(
      filters: filters,
      timeline: timeline,
      inputs: inputs,
      timelineDuration: safeDuration,
      includeAudio: true,
    );
    if (!hasAudio) {
      throw ArgumentError.value(
        inputs,
        'inputs',
        'Must contain at least one audible input.',
      );
    }
    filters.add(
      '[aout]astats=metadata=1:reset=0,'
      'ebur128=peak=true,'
      'loudnorm=I=${_number(targetLufs.clamp(-60.0, 0.0))}:'
      'LRA=11:TP=${_number(peakLimitDb.clamp(-24.0, 0.0))}:'
      'print_format=json[metered]',
    );
    args.addAll([
      '-filter_complex',
      filters.join(';'),
      '-map',
      '[metered]',
      '-vn',
      '-t',
      _seconds(safeDuration),
      '-f',
      'null',
      '-',
    ]);
    return args;
  }

  static String audioAnalysisFingerprint({
    required EditorTimeline timeline,
    required TimelineRenderInput input,
  }) {
    FileStat? stat;
    try {
      stat = File(input.sourcePath).statSync();
    } catch (_) {
      stat = null;
    }
    final cleanMix = input.clip.audioMix.copyWith(
      normalize: false,
      clearLoudnessAnalysis: true,
    );
    final bus = input.track.audioBusId == null
        ? null
        : timeline.audioBuses
              .where((candidate) => candidate.id == input.track.audioBusId)
              .firstOrNull;
    final payload = jsonEncode({
      'sourcePath': input.sourcePath.replaceAll('\\', '/'),
      'sourceBytes': stat?.size,
      'sourceModifiedUs': stat?.modified.microsecondsSinceEpoch,
      'sourceAudioStreams': input.audioStreamCount,
      'sourceAudioChannels': input.audioChannelsByStream,
      'clip': input.clip.copyWith(audioMix: cleanMix).toJson(),
      'trackGain': input.track.audioGain,
      'trackPan': input.track.audioPan,
      'trackMuted': input.track.isMuted,
      'trackSolo': input.track.isSolo,
      'effectiveStack': timeline
          .effectStackForClip(input.clip, track: input.track)
          .toJson(),
      'bus': bus?.toJson(),
    });
    return sha256.convert(utf8.encode(payload)).toString();
  }

  static ExportCanvasSize resolveCanvasSize(
    CanvasSettings canvasSettings,
    ExportSettings exportSettings, {
    required int sourceWidth,
    required int sourceHeight,
    required double sourceFrameRate,
  }) {
    final safeSourceWidth = sourceWidth > 0 ? sourceWidth : 1920;
    final safeSourceHeight = sourceHeight > 0 ? sourceHeight : 1080;
    final sourceAspect = safeSourceWidth / safeSourceHeight;
    final aspectRatio = switch (canvasSettings.aspectRatioPreset) {
      CanvasAspectRatioPreset.original => sourceAspect,
      CanvasAspectRatioPreset.ratio16x9 => 16 / 9,
      CanvasAspectRatioPreset.ratio9x16 => 9 / 16,
      CanvasAspectRatioPreset.ratio1x1 => 1.0,
      CanvasAspectRatioPreset.ratio4x5 => 4 / 5,
    };

    int width;
    int height;
    if (canvasSettings.customWidth != null &&
        canvasSettings.customHeight != null &&
        canvasSettings.customWidth! > 0 &&
        canvasSettings.customHeight! > 0) {
      width = canvasSettings.customWidth!;
      height = canvasSettings.customHeight!;
    } else {
      final targetEdge = exportSettings.targetHeight;
      if (targetEdge == null) {
        if (aspectRatio >= 1) {
          height = safeSourceHeight;
          width = (height * aspectRatio).round();
        } else {
          width = math.min(safeSourceWidth, safeSourceHeight);
          height = (width / aspectRatio).round();
        }
      } else if (aspectRatio >= 1) {
        height = targetEdge;
        width = (height * aspectRatio).round();
      } else {
        width = targetEdge;
        height = (width / aspectRatio).round();
      }
    }

    width = _makeEven(width.clamp(240, 4096));
    height = _makeEven(height.clamp(240, 4096));
    final requestedFps = exportSettings.targetFps;
    final sourceFps = sourceFrameRate.isFinite && sourceFrameRate > 0
        ? sourceFrameRate.round()
        : 30;
    final fps = (requestedFps ?? sourceFps).clamp(12, 60);
    return ExportCanvasSize(width: width, height: height, framesPerSecond: fps);
  }

  static List<(TimelineTrack, TimelineClip)> _visibleBaseClips(
    EditorTimeline timeline,
  ) {
    final clips = <(TimelineTrack, TimelineClip)>[];
    for (final track in timeline.tracks) {
      if (track.section != TimelineTrackSection.baseVideo || track.isHidden) {
        continue;
      }
      for (final clip in track.clips) {
        if (clip.enabled &&
            clip.type == TimelineTrackType.video &&
            clip.endTime > clip.startTime) {
          clips.add((track, clip));
        }
      }
    }
    clips.sort((a, b) => a.$2.startTime.compareTo(b.$2.startTime));
    return clips;
  }

  static List<(TimelineTrack, TimelineClip)> _visibleVisualClips(
    EditorTimeline timeline,
  ) {
    final clips = <(TimelineTrack, TimelineClip)>[];
    for (final track in timeline.tracks) {
      if (!track.isVisualLayer || track.isHidden) continue;
      for (final clip in track.clips) {
        if (clip.enabled &&
            track.acceptsClip(clip) &&
            clip.type.isVisualMedia &&
            clip.endTime > clip.startTime) {
          clips.add((track, clip));
        }
      }
    }
    clips.sort((a, b) => a.$2.startTime.compareTo(b.$2.startTime));
    return clips;
  }

  static String _sourceCacheKey(TimelineClip clip) {
    final normalizedAssetId = clip.assetId?.trim();
    return normalizedAssetId == null || normalizedAssetId.isEmpty
        ? 'clip:${clip.id}'
        : 'asset:$normalizedAssetId';
  }

  @visibleForTesting
  static String sourceCacheKeyForTesting(TimelineClip clip) {
    return _sourceCacheKey(clip);
  }

  @visibleForTesting
  static Future<String> resolveSourcePathForTesting({
    required Project project,
    required EditorTimeline timeline,
    required TimelineClip clip,
    required Directory workingDirectory,
  }) {
    return _sourcePathForClip(
      project: project,
      timeline: timeline,
      clip: clip,
      workingDirectory: workingDirectory,
      downloadCancelToken: CancelToken(),
    );
  }

  static Future<String> _sourcePathForClip({
    required Project project,
    required EditorTimeline timeline,
    required TimelineClip clip,
    required Directory workingDirectory,
    required CancelToken downloadCancelToken,
  }) async {
    final asset = timeline.assetForClip(clip);
    final localPath = asset?.sourcePath;
    if (localPath != null && localPath.isNotEmpty) {
      final file = File(localPath);
      if (await file.exists()) return file.path;
    }

    final remoteUrl = asset?.remoteUrl;
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      final uri = Uri.tryParse(remoteUrl);
      if (uri == null ||
          !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
          uri.host.isEmpty) {
        throw Exception(
          'Unsupported media URL for ${asset?.label ?? clip.label}.',
        );
      }
      final rawExtension = p.extension(uri.path);
      final extension = RegExp(r'^\.[A-Za-z0-9]{1,8}$').hasMatch(rawExtension)
          ? rawExtension.toLowerCase()
          : '.media';
      final safeAssetId = asset!.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final outputPath = p.join(
        workingDirectory.path,
        'network_${safeAssetId.isEmpty ? 'asset' : safeAssetId}$extension',
      );
      final cachedDownload = File(outputPath);
      if (await cachedDownload.exists() && await cachedDownload.length() > 0) {
        if (await cachedDownload.length() <= _maxNetworkAssetBytes) {
          return outputPath;
        }
        await cachedDownload.delete();
      }
      var exceededDownloadLimit = false;
      try {
        await Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 25),
            receiveTimeout: const Duration(minutes: 5),
          ),
        ).download(
          remoteUrl,
          (headers) {
            final declaredLength = int.tryParse(
              headers.value(Headers.contentLengthHeader) ?? '',
            );
            if (declaredLength != null &&
                declaredLength > _maxNetworkAssetBytes) {
              exceededDownloadLimit = true;
              throw StateError('Network media exceeds the export size limit.');
            }
            return outputPath;
          },
          cancelToken: downloadCancelToken,
          onReceiveProgress: (received, total) {
            if (received > _maxNetworkAssetBytes ||
                total > _maxNetworkAssetBytes) {
              exceededDownloadLimit = true;
              throw StateError('Network media exceeds the export size limit.');
            }
          },
        );
      } on DioException catch (error) {
        if (exceededDownloadLimit) {
          throw Exception(
            '${asset.label} exceeds the 64 MB network-media export limit.',
          );
        }
        if (CancelToken.isCancel(error)) {
          throw Exception('Export cancelled.');
        }
        throw Exception(
          'Could not download ${asset.label}: '
          '${error.message ?? 'network error'}.',
        );
      } catch (_) {
        if (exceededDownloadLimit) {
          throw Exception(
            '${asset.label} exceeds the 64 MB network-media export limit.',
          );
        }
        rethrow;
      }
      final outputFile = File(outputPath);
      if (!await outputFile.exists() || await outputFile.length() == 0) {
        throw Exception('Downloaded media is empty: ${asset.label}.');
      }
      if (await outputFile.length() > _maxNetworkAssetBytes) {
        await outputFile.delete();
        throw Exception(
          '${asset.label} exceeds the 64 MB network-media export limit.',
        );
      }
      return outputPath;
    }

    final baseClips = _visibleBaseClips(timeline);
    final primaryBaseClip = baseClips.isEmpty ? null : baseClips.first.$2;
    final hasAssetReference = clip.assetId?.trim().isNotEmpty ?? false;
    final isLegacyPrimaryClip =
        !hasAssetReference && primaryBaseClip?.id == clip.id;
    if (clip.type == TimelineTrackType.video &&
        isLegacyPrimaryClip &&
        project.videoPath.isNotEmpty &&
        await File(project.videoPath).exists()) {
      return project.videoPath;
    }

    throw Exception('Media is missing for "${clip.label}". Relink it first.');
  }

  static Future<Map<String, dynamic>> _mediaInfoForInput(
    EditorAssetReference? asset,
    String sourcePath, {
    Future<Map<String, dynamic>> Function(String sourcePath)? mediaInfoLoader,
  }) async {
    final metadata = asset?.metadata ?? const <String, dynamic>{};
    final needsStreamProbe =
        asset == null ||
        asset.type == EditorAssetType.video ||
        asset.type == EditorAssetType.audio;
    if (!needsStreamProbe &&
        metadata['durationMs'] is num &&
        (metadata['hasAudio'] is bool ||
            asset.type == EditorAssetType.image ||
            asset.type == EditorAssetType.gif ||
            asset.type == EditorAssetType.sticker)) {
      return {
        ...metadata,
        'hasAudio':
            asset.type == EditorAssetType.audio ||
            (metadata['hasAudio'] as bool? ?? false),
      };
    }
    try {
      final probed =
          await (mediaInfoLoader?.call(sourcePath) ??
              FFmpegService.getMediaInfo(sourcePath));
      return <String, dynamic>{...metadata, ...probed};
    } catch (_) {
      return {
        ...metadata,
        'hasAudio':
            asset?.type == EditorAssetType.audio ||
            (metadata['hasAudio'] as bool? ?? false),
      };
    }
  }

  static List<String> _inputArguments(TimelineRenderInput input) {
    final clipDuration = input.clip.duration;
    final sourceWindow = _sourceWindow(input.clip);
    final isAnimatedImage = _isAnimatedImage(input);
    if (input.asset?.type == EditorAssetType.image ||
        (input.asset?.type == EditorAssetType.sticker && !isAnimatedImage)) {
      return [
        '-loop',
        '1',
        '-t',
        _seconds(clipDuration),
        '-i',
        input.sourcePath,
      ];
    }
    if (isAnimatedImage) {
      return [
        '-stream_loop',
        '-1',
        if (input.clip.sourceStartTime > Duration.zero) ...[
          '-ss',
          _seconds(input.clip.sourceStartTime),
        ],
        '-t',
        _seconds(sourceWindow),
        '-i',
        input.sourcePath,
      ];
    }
    return [
      '-ss',
      _seconds(input.clip.sourceStartTime),
      '-t',
      _seconds(sourceWindow),
      '-i',
      input.sourcePath,
    ];
  }

  static List<String> _freezeInputArguments(TimelineRenderInput input) {
    final seek = _freezeSeekPlan(input.clip);
    return [
      if (_isAnimatedImage(input)) ...['-stream_loop', '-1'],
      '-ss',
      _seconds(seek.seekStart),
      '-t',
      _seconds(seek.decodeWindow),
      '-i',
      input.sourcePath,
    ];
  }

  static bool _isAnimatedImage(TimelineRenderInput input) {
    final extension = p.extension(input.sourcePath).toLowerCase();
    return input.asset?.type == EditorAssetType.gif ||
        (input.asset?.type == EditorAssetType.sticker && extension == '.gif');
  }

  static String _buildFilterGraph({
    required EditorTimeline timeline,
    required List<TimelineRenderInput> inputs,
    required Map<int, int> frozenVisualInputIndices,
    required ExportSettings settings,
    required ExportCanvasSize canvasSize,
    required Duration timelineDuration,
    required String? assPath,
    required String? captionFontDirectory,
    bool previewMode = false,
  }) {
    final filters = <String>[];
    final needsBlackSourceBackdrop = timeline.tracks.any(
      (track) =>
          track.section == TimelineTrackSection.baseVideo &&
          !track.isHidden &&
          track.clips.any(
            (clip) => clip.enabled && clip.mayRevealCanvasBackground,
          ),
    );
    final background = _ffmpegColor(
      needsBlackSourceBackdrop
          ? Colors.black
          : timeline.canvasSettings.backgroundColor,
    );
    final durationSeconds = _seconds(timelineDuration);
    filters.add(
      'color=c=$background:s=${canvasSize.width}x${canvasSize.height}:'
      'r=${canvasSize.framesPerSecond}:d=$durationSeconds[canvas0]',
    );

    final visualPaintTracks = timeline.visualTracksInPaintOrder;
    final paintRankByTrackId = <String, int>{
      for (final entry in visualPaintTracks.indexed) entry.$2.id: entry.$1,
    };
    final timelineIndexByTrackId = <String, int>{
      for (final entry in timeline.tracks.indexed) entry.$2.id: entry.$1,
    };
    final visualInputs = inputs.where((input) => input.isVisual).toList()
      ..sort((a, b) {
        final trackCompare = (paintRankByTrackId[a.track.id] ?? a.trackIndex)
            .compareTo(paintRankByTrackId[b.track.id] ?? b.trackIndex);
        if (trackCompare != 0) return trackCompare;
        final layerCompare = a.clip.layer.compareTo(b.clip.layer);
        if (layerCompare != 0) return layerCompare;
        return a.clip.startTime.compareTo(b.clip.startTime);
      });

    var canvasIndex = 0;
    var currentCanvasLabel = 'canvas0';
    var nextTimelineEffectIndex = 0;
    var nextPaintRankToFinish = 0;

    void applyEffectsThrough(int inclusivePaintRank) {
      final lastRank = math.min(
        inclusivePaintRank,
        visualPaintTracks.length - 1,
      );
      while (nextPaintRankToFinish <= lastRank) {
        final track = visualPaintTracks[nextPaintRankToFinish];
        final trackIndex = timelineIndexByTrackId[track.id];
        if (trackIndex != null) {
          final result = _appendTimelineEffects(
            filters: filters,
            timeline: timeline,
            sourceLabel: currentCanvasLabel,
            onlyTrackIndex: trackIndex,
            startingEffectIndex: nextTimelineEffectIndex,
          );
          currentCanvasLabel = result.sourceLabel;
          nextTimelineEffectIndex = result.nextEffectIndex;
        }
        nextPaintRankToFinish++;
      }
    }

    for (
      var visualIndex = 0;
      visualIndex < visualInputs.length;
      visualIndex++
    ) {
      final input = visualInputs[visualIndex];
      final inputPaintRank = paintRankByTrackId[input.track.id] ?? 0;
      applyEffectsThrough(inputPaintRank - 1);
      final clip = input.clip;
      final clipDuration = clip.duration;
      final playbackRate = clip.playbackRate.clamp(0.25, 4).toDouble();
      final isBase = input.track.section == TimelineTrackSection.baseVideo;
      final visualLabel = 'visual$visualIndex';
      final isFrozenVisual = _usesFrozenVisualInput(input);
      final visualInputIndex = isFrozenVisual
          ? frozenVisualInputIndices[input.index]!
          : input.index;
      final scaleExpression = _visualScaleExpression(clip);
      final rotationExpression = _visualRotationExpression(clip);
      final hasScaleAnimation =
          _hasKeyframes(clip, TimelineKeyframeProperty.scale) ||
          _hasScaleTransition(clip);
      final hasRotationAnimation =
          _hasKeyframes(clip, TimelineKeyframeProperty.rotation) ||
          _hasSpinTransition(clip);
      final hasOpacityAnimation = _hasKeyframes(
        clip,
        TimelineKeyframeProperty.opacity,
      );
      final needsAlpha =
          !isBase ||
          clip.chromaKeyEnabled ||
          hasOpacityAnimation ||
          clip.transform.opacity < 0.999 ||
          hasRotationAnimation ||
          clip.transform.rotation.abs() > 0.0001 ||
          _transitionUsesAlpha(clip.introTransition.type) ||
          _transitionUsesAlpha(clip.outroTransition.type);
      final hasAlphaEnvelope =
          hasOpacityAnimation ||
          clip.transform.opacity < 0.999 ||
          _transitionUsesAlpha(clip.introTransition.type) ||
          _transitionUsesAlpha(clip.outroTransition.type);
      final preparation = <String>[
        if (isFrozenVisual)
          ..._freezeFrameFilters(input)
        else ...[
          if (clip.isReversed &&
              (clip.type == TimelineTrackType.video ||
                  clip.type == TimelineTrackType.gif))
            'reverse',
          'setpts=(PTS-STARTPTS)/${_number(playbackRate)}',
          'trim=duration=${_seconds(clipDuration)}',
        ],
        ..._cropFilters(clip.crop),
        ..._inputColorTransformFilters(
          input,
          management: timeline.colorManagement,
        ),
        if (clip.stabilize) 'deshake=rx=16:ry=16:edge=mirror',
        if (clip.denoise) 'hqdn3d=1.5:1.5:6:6',
        if (clip.chromaKeyEnabled) ...[
          'format=rgba',
          'colorkey=${_ffmpegColor(clip.chromaKeyColor)}:'
              '${_number(clip.chromaKeySimilarity.clamp(0.01, 1.0))}:0.08',
        ],
        ..._fitFilters(clip, canvasSize: canvasSize, isBase: isBase),
        // Apply alpha while the frame geometry is still stable. Some FFmpeg
        // pixel-expression filters do not renegotiate dimensions when a
        // frame-evaluated scale changes size later in the chain.
        if (needsAlpha) 'format=rgba',
        if (hasAlphaEnvelope) ..._alphaEnvelopeFilters(clip),
      ];
      final finishing = <String>[
        if (clip.transform.flipX) 'hflip',
        if (clip.transform.flipY) 'vflip',
        if (hasRotationAnimation || clip.transform.rotation.abs() > 0.0001)
          "rotate=angle='$rotationExpression':"
              "ow='ceil(hypot(iw,ih)/2)*2':"
              "oh='ceil(hypot(iw,ih)/2)*2':c=none",
        if (hasScaleAnimation || clip.transform.scale != 1)
          "scale=w='max(2,trunc(iw*($scaleExpression)/2)*2)':"
              "h='max(2,trunc(ih*($scaleExpression)/2)*2)':eval=frame",
        'setpts=PTS-STARTPTS+${_seconds(clip.startTime)}/TB',
      ];
      final preparedLabel = 'preparedVisual$visualIndex';
      filters.add(
        '[$visualInputIndex:v]${preparation.join(',')}[$preparedLabel]',
      );
      String effectSource = _appendColorAdjustmentGraph(
        filters: filters,
        sourceLabel: preparedLabel,
        adjustments: clip.colorAdjustments,
        labelPrefix: 'clipColor$visualIndex',
      ).sourceLabel;
      if (clip.blur.mode == ClipBlurMode.region && _blurIsEnabled(clip)) {
        final clean = 'clean$visualIndex';
        final blurredSource = 'blurSource$visualIndex';
        final blurredRegion = 'blurRegion$visualIndex';
        final effected = 'effected$visualIndex';
        final blur = clip.blur;
        filters.add(
          '[$effectSource]format=rgba,split=2[$clean][$blurredSource]',
        );
        filters.add(
          '[$blurredSource]'
          'crop=w=iw*${_number(blur.safeRegionWidth)}:'
          'h=ih*${_number(blur.safeRegionHeight)}:'
          'x=iw*${_number(blur.safeRegionX)}:'
          'y=ih*${_number(blur.safeRegionY)},'
          '${_blurFilterChain(clip, target: 'clipRegionBlur$visualIndex').join(',')}'
          '[$blurredRegion]',
        );
        filters.add(
          '[$clean][$blurredRegion]'
          'overlay=x=main_w*${_number(blur.safeRegionX)}:'
          'y=main_h*${_number(blur.safeRegionY)}:'
          'eof_action=pass:shortest=1:format=auto'
          '[$effected]',
        );
        effectSource = effected;
      } else if (clip.blur.mode == ClipBlurMode.full && _blurIsEnabled(clip)) {
        final chain = <String>[
          ..._blurFilterChain(clip, target: 'clipFullBlur$visualIndex'),
        ];
        final blurredLabel = 'blurredVisual$visualIndex';
        filters.add('[$effectSource]${chain.join(',')}[$blurredLabel]');
        effectSource = blurredLabel;
      }

      final clipLutResult = _appendEditorEffectStackGraph(
        filters: filters,
        sourceLabel: effectSource,
        stack: _colorAdjustmentLutStack(clip.colorAdjustments),
        labelPrefix: 'clipLut$visualIndex',
      );
      effectSource = clipLutResult.sourceLabel;

      var stackSource = effectSource;
      var scopedStackIndex = 0;
      for (final scoped in timeline.effectStacksForClip(
        clip,
        track: input.track,
      )) {
        final stackResult = _appendEditorEffectStackGraph(
          filters: filters,
          sourceLabel: stackSource,
          stack: scoped.stack,
          labelPrefix: 'clipStack${visualIndex}_$scopedStackIndex',
          parameterTimeOffset: scoped.scope == EditorEffectScope.clip
              ? Duration.zero
              : clip.startTime,
          animationDuration: clip.duration,
        );
        stackSource = stackResult.sourceLabel;
        scopedStackIndex++;
      }
      filters.add('[$stackSource]${finishing.join(',')}[$visualLabel]');

      final nextCanvas = 'canvas${canvasIndex + 1}';
      final position = _overlayPosition(clip, canvasSize: canvasSize);
      filters.add(
        '[$currentCanvasLabel][$visualLabel]'
        "overlay=x='${position.$1}':y='${position.$2}':"
        'eof_action=pass:shortest=0:format=auto[$nextCanvas]',
      );
      canvasIndex++;
      currentCanvasLabel = nextCanvas;

      final nextInputPaintRank = visualIndex + 1 < visualInputs.length
          ? paintRankByTrackId[visualInputs[visualIndex + 1].track.id]
          : null;
      if (nextInputPaintRank != inputPaintRank) {
        applyEffectsThrough(inputPaintRank);
      }
    }
    applyEffectsThrough(visualPaintTracks.length - 1);

    var videoSource = currentCanvasLabel;
    if (assPath != null) {
      const assOutput = 'captioned';
      final fontsDirectoryOption =
          captionFontDirectory == null || captionFontDirectory.trim().isEmpty
          ? ''
          : ":fontsdir='${_escapeFilterPath(captionFontDirectory)}'";
      filters.add(
        '[$videoSource]ass=filename=\'${_escapeFilterPath(assPath)}\''
        '$fontsDirectoryOption'
        '[$assOutput]',
      );
      videoSource = assOutput;
    }
    videoSource = _appendEditorEffectStackGraph(
      filters: filters,
      sourceLabel: videoSource,
      stack: timeline.projectEffectStack,
      labelPrefix: 'projectStack',
      animationDuration: timelineDuration,
    ).sourceLabel;
    final outputColorFilters = _outputColorTransformFilters(
      timeline.colorManagement,
      previewMode: previewMode,
    );
    filters.add(
      '[$videoSource]'
      '${outputColorFilters.isEmpty ? '' : '${outputColorFilters.join(',')},'}'
      'format=${_outputPixelFormat(timeline.colorManagement, previewMode)},'
      'fps=${canvasSize.framesPerSecond},'
      'trim=duration=$durationSeconds[vout]',
    );

    _appendAudioMixFilters(
      filters: filters,
      timeline: timeline,
      inputs: inputs,
      timelineDuration: timelineDuration,
      includeAudio: settings.includeAudio,
    );

    return filters.join(';');
  }

  static bool _appendAudioMixFilters({
    required List<String> filters,
    required EditorTimeline timeline,
    required List<TimelineRenderInput> inputs,
    required Duration timelineDuration,
    required bool includeAudio,
  }) {
    final durationSeconds = _seconds(timelineDuration);
    final clipLabelsByBusId = <String?, List<String>>{};
    final separatedVideoIds = _separatedVideoAudioOwnerIds(timeline);
    if (includeAudio) {
      final soloTrackIds = inputs
          .where((input) => input.track.isSolo)
          .map((input) => input.track.id)
          .toSet();
      final soloBusIds = timeline.audioBuses
          .where((bus) => bus.solo)
          .map((bus) => bus.id)
          .toSet();
      var audioIndex = 0;
      for (final input in inputs) {
        final bus = input.track.audioBusId == null
            ? null
            : timeline.audioBuses
                  .where((candidate) => candidate.id == input.track.audioBusId)
                  .firstOrNull;
        if (!input.hasAudio ||
            (input.clip.type == TimelineTrackType.video &&
                (input.clip.embeddedAudioSeparated ||
                    separatedVideoIds.contains(input.clip.id))) ||
            input.track.isMuted ||
            bus?.muted == true ||
            input.clip.audioMix.muted ||
            (soloTrackIds.isNotEmpty &&
                !soloTrackIds.contains(input.track.id)) ||
            (soloBusIds.isNotEmpty &&
                (bus == null || !soloBusIds.contains(bus.id)))) {
          continue;
        }
        final label = 'audio$audioIndex';
        final clip = input.clip;
        final clipDurationSeconds = clip.duration.inMilliseconds / 1000;
        final mix = clip.audioMix;
        final availableStreams = math.max(1, input.audioStreamCount ?? 1);
        final sourceStreamIndex = mix.sourceStreamIndex
            .clamp(0, availableStreams - 1)
            .toInt();
        final channelsByStream =
            input.audioChannelsByStream ??
            audioChannelsByStreamFromMetadata(
              input.asset?.metadata['audioStreams'],
            );
        final declaredChannels =
            channelsByStream != null &&
                sourceStreamIndex < channelsByStream.length
            ? channelsByStream[sourceStreamIndex]
            : input.audioChannels;
        final channelCountKnown =
            declaredChannels != null && declaredChannels > 0;
        final availableChannels = math.max(1, declaredChannels ?? 2);
        final sourceLeftChannel = mix.sourceLeftChannel
            .clamp(0, availableChannels - 1)
            .toInt();
        final sourceRightChannel = mix.sourceRightChannel
            .clamp(0, availableChannels - 1)
            .toInt();
        final fadeInSeconds = clip.effectiveAudioFadeInMs / 1000;
        final fadeOutSeconds = clip.effectiveAudioFadeOutMs / 1000;
        final audioChain = <String>[
          if (clip.isReversed) 'areverse',
          'asetpts=PTS-STARTPTS',
          ..._atempoFilters(clip.playbackRate),
          ..._timeStretchFilters(
            mix.timeStretch,
            preservePitch: mix.preservePitch,
          ),
          ..._pitchShiftFilters(mix.pitchSemitones),
          'atrim=duration=${_seconds(clip.duration)}',
          if (!channelCountKnown)
            'aformat=sample_rates=48000:channel_layouts=stereo',
          'pan=stereo|c0=c$sourceLeftChannel|c1=c$sourceRightChannel',
          if (channelCountKnown)
            'aformat=sample_rates=48000:channel_layouts=stereo',
          if (mix.channelMode == EditorAudioChannelMode.mono)
            'pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1',
          if (mix.channelMode == EditorAudioChannelMode.leftOnly)
            'pan=stereo|c0=c0|c1=c0',
          if (mix.channelMode == EditorAudioChannelMode.rightOnly)
            'pan=stereo|c0=c1|c1=c1',
          if ((mix.leftGain - 1).abs() > 0.001 ||
              (mix.rightGain - 1).abs() > 0.001)
            'pan=stereo|c0=${_number(mix.leftGain.clamp(0, 2))}*c0|'
                'c1=${_number(mix.rightGain.clamp(0, 2))}*c1',
          if (clip.denoise) 'afftdn=nr=12:nf=-45',
          if (mix.normalize)
            _loudnormFilter(
              mix,
              expectedFingerprint: audioAnalysisFingerprint(
                timeline: timeline,
                input: input,
              ),
            ),
          ..._audioEffectFilters(
            timeline.effectStackForClip(clip, track: input.track),
          ),
          _audioVolumeFilter(
            clip,
            track: input.track,
            timeline: timeline,
            inputs: inputs,
            soloTrackIds: soloTrackIds,
          ),
          if ((mix.pan + input.track.audioPan).abs() > 0.001)
            _panFilter(
              (mix.pan + input.track.audioPan).clamp(-1, 1).toDouble(),
            ),
          if (fadeInSeconds > 0)
            'afade=t=in:st=0:d=${_number(fadeInSeconds)}:'
                'curve=${_fadeCurve(mix.fadeInShape)}',
          if (fadeOutSeconds > 0)
            'afade=t=out:st=${_number(math.max(0, clipDurationSeconds - fadeOutSeconds))}:'
                'd=${_number(fadeOutSeconds)}:'
                'curve=${_fadeCurve(mix.fadeOutShape)}',
          'adelay=${clip.startTime.inMilliseconds}|'
              '${clip.startTime.inMilliseconds}',
          'apad',
          'atrim=duration=$durationSeconds',
        ];
        filters.add(
          '[${input.index}:a:$sourceStreamIndex]'
          '${audioChain.join(',')}[$label]',
        );
        (clipLabelsByBusId[bus?.id] ??= <String>[]).add(label);
        audioIndex++;
      }
    }

    final masterLabels = <String>[];
    var busIndex = 0;
    for (final entry in clipLabelsByBusId.entries) {
      final clipLabels = entry.value;
      if (clipLabels.isEmpty) continue;
      final bus = entry.key == null
          ? null
          : timeline.audioBuses
                .where((candidate) => candidate.id == entry.key)
                .firstOrNull;
      var sourceLabel = clipLabels.first;
      if (clipLabels.length > 1) {
        final mixedLabel = 'busMix$busIndex';
        filters.add(
          '${clipLabels.map((label) => '[$label]').join()}'
          'amix=inputs=${clipLabels.length}:duration=longest:'
          'dropout_transition=0:normalize=0[$mixedLabel]',
        );
        sourceLabel = mixedLabel;
      }
      if (bus != null) {
        final busChain = <String>[
          ..._audioEffectFilters(bus.effectStack),
          if ((bus.gain - 1).abs() > 0.0001)
            'volume=${_number(bus.gain.clamp(0, 2))}',
          if (bus.pan.abs() > 0.0001)
            _panFilter(bus.pan.clamp(-1, 1).toDouble()),
        ];
        if (busChain.isNotEmpty) {
          final processedLabel = 'busProcessed$busIndex';
          filters.add('[$sourceLabel]${busChain.join(',')}[$processedLabel]');
          sourceLabel = processedLabel;
        }
      }
      masterLabels.add(sourceLabel);
      busIndex++;
    }

    final masterEffectFilters = _audioEffectFilters(
      timeline.projectEffectStack,
    );
    if (masterLabels.length == 1) {
      filters.add(
        '[${masterLabels.first}]'
        '${masterEffectFilters.isEmpty ? '' : '${masterEffectFilters.join(',')},'}'
        'alimiter=limit=0.95:attack=5:release=50:latency=1,'
        'atrim=duration=$durationSeconds[aout]',
      );
    } else if (masterLabels.length > 1) {
      final inputsExpression = masterLabels.map((label) => '[$label]').join();
      filters.add(
        '$inputsExpression'
        'amix=inputs=${masterLabels.length}:duration=longest:'
        'dropout_transition=0:normalize=0,'
        '${masterEffectFilters.isEmpty ? '' : '${masterEffectFilters.join(',')},'}'
        // Compensating limiter latency keeps the rendered preview bus aligned
        // to the visual timeline while protecting dense mixes from clipping.
        'alimiter=limit=0.95:attack=5:release=50:latency=1,'
        'atrim=duration=$durationSeconds[aout]',
      );
    }
    return masterLabels.isNotEmpty;
  }

  static ({String sourceLabel, int nextEffectIndex}) _appendTimelineEffects({
    required List<String> filters,
    required EditorTimeline timeline,
    required String sourceLabel,
    int? onlyTrackIndex,
    int startingEffectIndex = 0,
  }) {
    final effectClips = <(int, TimelineClip)>[];
    for (final trackEntry in timeline.tracks.asMap().entries) {
      if (onlyTrackIndex != null && trackEntry.key != onlyTrackIndex) continue;
      final track = trackEntry.value;
      if (track.isHidden) continue;
      for (final clip in track.clips) {
        if (clip.isEffect && clip.enabled && clip.endTime > clip.startTime) {
          effectClips.add((trackEntry.key, clip));
        }
      }
    }
    effectClips.sort((a, b) {
      final trackComparison = a.$1.compareTo(b.$1);
      if (trackComparison != 0) return trackComparison;
      final layerComparison = a.$2.layer.compareTo(b.$2.layer);
      if (layerComparison != 0) return layerComparison;
      return a.$2.startTime.compareTo(b.$2.startTime);
    });

    var currentSource = sourceLabel;
    var appliedEffectIndex = startingEffectIndex;
    for (final effectEntry in effectClips) {
      final clip = effectEntry.$2;
      final enableExpression =
          'gte(t,${_seconds(clip.startTime)})*'
          'lt(t,${_seconds(clip.endTime)})';
      var effectSource = currentSource;
      var producedEffect = false;

      switch (clip.effectKind) {
        case TimelineEffectKind.blur:
          final blur = clip.blur;
          if (!_blurIsEnabled(clip)) break;
          final outputLabel = 'timelineEffect$appliedEffectIndex';
          if (blur.mode == ClipBlurMode.region) {
            final cleanLabel = 'effectClean$appliedEffectIndex';
            final blurSourceLabel = 'effectBlurSource$appliedEffectIndex';
            final blurredRegionLabel = 'effectBlurRegion$appliedEffectIndex';
            final transformedRegionLabel =
                'effectTransformedRegion$appliedEffectIndex';
            final transform = clip.transform;
            final regionScale = transform.scale.clamp(0.2, 4.0).toDouble();
            final regionWidth = (blur.safeRegionWidth * regionScale)
                .clamp(0.02, 1.0)
                .toDouble();
            final regionHeight = (blur.safeRegionHeight * regionScale)
                .clamp(0.02, 1.0)
                .toDouble();
            final centerX =
                blur.safeRegionX +
                blur.safeRegionWidth / 2 +
                transform.offsetX / kTimelineDesignWidth;
            final centerY =
                blur.safeRegionY +
                blur.safeRegionHeight / 2 +
                transform.offsetY / kTimelineDesignHeight;
            filters.add(
              '[$currentSource]split=2[$cleanLabel][$blurSourceLabel]',
            );
            filters.add(
              '[$blurSourceLabel]'
              'crop=w=iw*${_number(regionWidth)}:'
              'h=ih*${_number(regionHeight)}:'
              "x='max(0,min(iw-ow,iw*${_number(centerX)}-ow/2))':"
              "y='max(0,min(ih-oh,ih*${_number(centerY)}-oh/2))',"
              'format=rgba,'
              '${_blurFilterChain(clip, target: 'effectRegionBlur$appliedEffectIndex', timelineOffset: clip.startTime, enableExpression: enableExpression).join(',')}'
              '[$blurredRegionLabel]',
            );
            final overlayRegionLabel = transform.rotation.abs() > 0.0001
                ? transformedRegionLabel
                : blurredRegionLabel;
            if (transform.rotation.abs() > 0.0001) {
              filters.add(
                '[$blurredRegionLabel]'
                "rotate=angle='${_number(transform.rotation)}':"
                "ow='ceil(hypot(iw,ih)/2)*2':"
                "oh='ceil(hypot(iw,ih)/2)*2':c=none"
                '[$transformedRegionLabel]',
              );
            }
            filters.add(
              '[$cleanLabel][$overlayRegionLabel]'
              "overlay=x='main_w*${_number(centerX)}-overlay_w/2':"
              "y='main_h*${_number(centerY)}-overlay_h/2':"
              "enable='$enableExpression':"
              'eof_action=pass:shortest=0:format=auto'
              '[$outputLabel]',
            );
          } else {
            filters.add(
              '[$currentSource]'
              '${_blurFilterChain(clip, target: 'effectFullBlur$appliedEffectIndex', timelineOffset: clip.startTime, enableExpression: enableExpression).join(',')}'
              '[$outputLabel]',
            );
          }
          effectSource = outputLabel;
          producedEffect = true;
          appliedEffectIndex++;
          break;
        case TimelineEffectKind.filter:
          final colorResult = _appendColorAdjustmentGraph(
            filters: filters,
            sourceLabel: currentSource,
            adjustments: clip.colorAdjustments,
            labelPrefix: 'timelineColor$appliedEffectIndex',
            enableExpression: enableExpression,
          );
          if (colorResult.changed) {
            effectSource = colorResult.sourceLabel;
            producedEffect = true;
            appliedEffectIndex++;
          }
          final lutResult = _appendEditorEffectStackGraph(
            filters: filters,
            sourceLabel: effectSource,
            stack: _colorAdjustmentLutStack(clip.colorAdjustments),
            labelPrefix: 'adjustmentLut$appliedEffectIndex',
            enableExpression: enableExpression,
          );
          if (lutResult.appliedEffects > 0) {
            effectSource = lutResult.sourceLabel;
            producedEffect = true;
            appliedEffectIndex += lutResult.appliedEffects;
          }
          break;
        case null:
          break;
      }

      final stackResult = _appendEditorEffectStackGraph(
        filters: filters,
        sourceLabel: effectSource,
        stack: clip.effectStack,
        labelPrefix: 'adjustmentStack$appliedEffectIndex',
        enableExpression: enableExpression,
        animationDuration: clip.duration,
        filterTimeOffset: clip.startTime,
      );
      if (stackResult.appliedEffects > 0) {
        effectSource = stackResult.sourceLabel;
        producedEffect = true;
        appliedEffectIndex += stackResult.appliedEffects;
      }
      if (!producedEffect) continue;
      currentSource = effectSource;
    }
    return (sourceLabel: currentSource, nextEffectIndex: appliedEffectIndex);
  }

  static bool _hasKeyframes(
    TimelineClip clip,
    TimelineKeyframeProperty property,
  ) {
    return clip.keyframes.any((keyframe) => keyframe.property == property);
  }

  static bool _blurIsEnabled(TimelineClip clip) {
    if (clip.blur.mode == ClipBlurMode.none) return false;
    final frames = _keyframesFor(clip, TimelineKeyframeProperty.blurStrength);
    if (frames.isEmpty) return clip.blur.isEnabled;
    return frames.any((frame) => frame.value.clamp(0, 30) > 0.01);
  }

  /// Produces a Gaussian blur whose sigma follows the editor's keyframe
  /// evaluator. `gblur` accepts runtime commands but not a sigma expression,
  /// so curved segments are deterministically sampled into short linear
  /// commands that use the same model values as preview.
  static List<String> _blurFilterChain(
    TimelineClip clip, {
    required String target,
    Duration timelineOffset = Duration.zero,
    String? enableExpression,
  }) {
    final frames = _renderKeyframesFor(
      clip,
      TimelineKeyframeProperty.blurStrength,
    );
    final initialStrength = frames.isEmpty
        ? clip.blur.safeStrength
        : frames.first.value.clamp(0, 30).toDouble();
    final commands = <String>[];
    final offsetSeconds =
        timelineOffset.inMicroseconds / Duration.microsecondsPerSecond;
    final maximumSeconds =
        clip.duration.inMicroseconds / Duration.microsecondsPerSecond;
    for (var index = 0; index + 1 < frames.length; index++) {
      final previous = frames[index];
      final next = frames[index + 1];
      final localStart =
          (previous.time.inMicroseconds / Duration.microsecondsPerSecond)
              .clamp(0.0, maximumSeconds)
              .toDouble();
      final localEnd =
          (next.time.inMicroseconds / Duration.microsecondsPerSecond)
              .clamp(0.0, maximumSeconds)
              .toDouble();
      if (localEnd <= localStart) continue;
      final start = _number(offsetSeconds + localStart);
      final end = _number(offsetSeconds + localEnd);
      final startValue = _number(previous.value.clamp(0, 30));
      final delta = _number(
        next.value.clamp(0, 30) - previous.value.clamp(0, 30),
      );
      commands.add(
        '$start-$end [expr] gblur@$target sigma '
        '$startValue+($delta)*TI',
      );
      commands.add(
        '$end [enter] gblur@$target sigma '
        '${_number(next.value.clamp(0, 30))}',
      );
    }
    final filterName = commands.isEmpty ? 'gblur' : 'gblur@$target';
    final blur = StringBuffer('$filterName=sigma=${_number(initialStrength)}');
    if (enableExpression != null) {
      blur.write(":enable='$enableExpression'");
    }
    return [
      if (commands.isNotEmpty) "sendcmd=c='${commands.join(';')}'",
      blur.toString(),
    ];
  }

  static List<TimelineKeyframe> _keyframesFor(
    TimelineClip clip,
    TimelineKeyframeProperty property,
  ) {
    final byTime = <int, TimelineKeyframe>{};
    for (final keyframe in clip.keyframes) {
      if (keyframe.property != property) continue;
      byTime[keyframe.time.inMicroseconds] = keyframe;
    }
    final frames = byTime.values.toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    return frames;
  }

  /// Expands non-linear timing into bounded linear samples for FFmpeg filters.
  /// Hold segments receive a point one microsecond before their destination,
  /// preserving the step without requiring filter-specific expression logic.
  static List<TimelineKeyframe> _renderKeyframesFor(
    TimelineClip clip,
    TimelineKeyframeProperty property,
  ) {
    final frames = _keyframesFor(clip, property);
    if (frames.length < 2) return frames;
    final rendered = <TimelineKeyframe>[];
    void addLinear(Duration time, double value) {
      if (rendered.isNotEmpty && rendered.last.time == time) {
        rendered[rendered.length - 1] = TimelineKeyframe(
          id: rendered.last.id,
          time: time,
          property: property,
          value: value,
        );
        return;
      }
      rendered.add(
        TimelineKeyframe(
          id: 'render_${property.name}_${time.inMicroseconds}',
          time: time,
          property: property,
          value: value,
        ),
      );
    }

    addLinear(frames.first.time, frames.first.value);
    for (var index = 0; index + 1 < frames.length; index++) {
      final previous = frames[index];
      final next = frames[index + 1];
      final startUs = previous.time.inMicroseconds;
      final endUs = next.time.inMicroseconds;
      final spanUs = endUs - startUs;
      if (spanUs <= 0) {
        addLinear(next.time, next.value);
        continue;
      }
      if (previous.interpolation == TimelineKeyframeInterpolation.hold) {
        if (spanUs > 1) {
          addLinear(Duration(microseconds: endUs - 1), previous.value);
        }
      } else if (previous.interpolation !=
          TimelineKeyframeInterpolation.linear) {
        final spanSeconds = spanUs / Duration.microsecondsPerSecond;
        final sampleCount = (spanSeconds * 12).ceil().clamp(4, 48);
        for (var sample = 1; sample < sampleCount; sample++) {
          final progress = sample / sampleCount;
          final value =
              previous.value +
              (next.value - previous.value) *
                  previous.transformProgress(progress);
          addLinear(
            Duration(microseconds: startUs + (spanUs * progress).round()),
            value,
          );
        }
      }
      addLinear(next.time, next.value);
    }
    return rendered;
  }

  /// Builds a piecewise-linear FFmpeg expression from values sampled through
  /// [TimelineKeyframe.transformProgress].
  static String _keyframedValueExpression(
    TimelineClip clip,
    TimelineKeyframeProperty property, {
    required double fallback,
    required String variable,
    double? minimum,
    double? maximum,
  }) {
    final frames = _renderKeyframesFor(clip, property);
    if (frames.isEmpty) {
      final value = minimum == null || maximum == null
          ? fallback
          : fallback.clamp(minimum, maximum).toDouble();
      return _number(value);
    }

    var expression = _number(frames.last.value);
    for (var index = frames.length - 2; index >= 0; index--) {
      final previous = frames[index];
      final next = frames[index + 1];
      final start =
          previous.time.inMicroseconds / Duration.microsecondsPerSecond;
      final end = next.time.inMicroseconds / Duration.microsecondsPerSecond;
      final span = math.max(0.000001, end - start);
      final startText = _number(start);
      final endText = _number(end);
      final previousValue = _number(previous.value);
      final delta = _number(next.value - previous.value);
      final interpolated =
          '$previousValue+($delta)*clip((($variable)-$startText)/'
          '${_number(span)},0,1)';
      expression = 'if(lt(($variable),$endText),($interpolated),($expression))';
    }
    final firstTime = _number(
      frames.first.time.inMicroseconds / Duration.microsecondsPerSecond,
    );
    expression =
        'if(lte(($variable),$firstTime),${_number(frames.first.value)},'
        '($expression))';
    if (minimum != null && maximum != null) {
      expression =
          'clip(($expression),${_number(minimum)},${_number(maximum)})';
    }
    return expression;
  }

  static bool _transitionChangesScale(TransitionType type) {
    return type == TransitionType.zoom ||
        type == TransitionType.zoomOut ||
        type == TransitionType.pop ||
        type == TransitionType.spin;
  }

  static bool _hasScaleTransition(TimelineClip clip) {
    return (_transitionChangesScale(clip.introTransition.type) &&
            clip.effectiveIntroTransitionMs > 0) ||
        (_transitionChangesScale(clip.outroTransition.type) &&
            clip.effectiveOutroTransitionMs > 0);
  }

  static bool _hasSpinTransition(TimelineClip clip) {
    return (clip.introTransition.type == TransitionType.spin &&
            clip.effectiveIntroTransitionMs > 0) ||
        (clip.outroTransition.type == TransitionType.spin &&
            clip.effectiveOutroTransitionMs > 0);
  }

  static String? _transitionScaleExpression(
    TransitionType type,
    String visibleProgress,
  ) {
    final eased = _smoothstepExpression(visibleProgress);
    return switch (type) {
      TransitionType.zoom => '0.82+0.18*($eased)',
      TransitionType.zoomOut => '1.18-0.18*($eased)',
      TransitionType.spin => '0.86+0.14*($eased)',
      TransitionType.pop => () {
        final shifted = '(($visibleProgress)-1)';
        final back =
            '1+2.70158*($shifted)*($shifted)*($shifted)'
            '+1.70158*($shifted)*($shifted)';
        return '0.68+0.32*($back)';
      }(),
      _ => null,
    };
  }

  static String _visualScaleExpression(TimelineClip clip) {
    final baseScale = _keyframedValueExpression(
      clip,
      TimelineKeyframeProperty.scale,
      fallback: clip.transform.scale,
      variable: 't',
      minimum: 0.2,
      maximum: 4,
    );
    final factors = <String>[];
    final introSeconds = clip.effectiveIntroTransitionMs / 1000;
    if (introSeconds > 0) {
      final progress = 'clip(t/${_number(introSeconds)},0,1)';
      final factor = _transitionScaleExpression(
        clip.introTransition.type,
        progress,
      );
      if (factor != null) factors.add(factor);
    }
    final outroSeconds = clip.effectiveOutroTransitionMs / 1000;
    if (outroSeconds > 0) {
      final outroStart = clip.duration.inMilliseconds / 1000 - outroSeconds;
      final visible =
          '1-clip((t-${_number(outroStart)})/'
          '${_number(outroSeconds)},0,1)';
      final factor = _transitionScaleExpression(
        clip.outroTransition.type,
        visible,
      );
      if (factor != null) factors.add(factor);
    }
    if (factors.isEmpty) return baseScale;
    return 'clip(($baseScale)*(${factors.join(')*(')}),0.2,4)';
  }

  static String _visualRotationExpression(TimelineClip clip) {
    final baseRotation = _keyframedValueExpression(
      clip,
      TimelineKeyframeProperty.rotation,
      fallback: clip.transform.rotation,
      variable: 't',
    );
    final additions = <String>[];
    final introSeconds = clip.effectiveIntroTransitionMs / 1000;
    if (clip.introTransition.type == TransitionType.spin && introSeconds > 0) {
      final progress = 'clip(t/${_number(introSeconds)},0,1)';
      additions.add(
        '-${_number(math.pi / 2)}*(1-${_smoothstepExpression(progress)})',
      );
    }
    final outroSeconds = clip.effectiveOutroTransitionMs / 1000;
    if (clip.outroTransition.type == TransitionType.spin && outroSeconds > 0) {
      final outroStart = clip.duration.inMilliseconds / 1000 - outroSeconds;
      final hidden =
          'clip((t-${_number(outroStart)})/${_number(outroSeconds)},0,1)';
      additions.add(
        '${_number(math.pi / 2)}*(${_smoothstepExpression(hidden)})',
      );
    }
    if (additions.isEmpty) return baseRotation;
    return '($baseRotation)+(${additions.join(')+(')})';
  }

  static List<String> _alphaEnvelopeFilters(TimelineClip clip) {
    var alpha = _keyframedValueExpression(
      clip,
      TimelineKeyframeProperty.opacity,
      fallback: clip.transform.opacity,
      variable: 'T',
      minimum: 0,
      maximum: 1,
    );
    final introSeconds = clip.effectiveIntroTransitionMs / 1000;
    if (_transitionUsesAlpha(clip.introTransition.type) && introSeconds > 0) {
      final progress = 'clip(T/${_number(introSeconds)},0,1)';
      final envelope = clip.introTransition.type == TransitionType.fade
          ? progress
          : _smoothstepExpression(progress);
      alpha = '($alpha)*($envelope)';
    }
    final outroSeconds = clip.effectiveOutroTransitionMs / 1000;
    if (_transitionUsesAlpha(clip.outroTransition.type) && outroSeconds > 0) {
      final outroStart =
          clip.duration.inMicroseconds / Duration.microsecondsPerSecond -
          outroSeconds;
      final remaining =
          '1-clip((T-${_number(outroStart)})/${_number(outroSeconds)},0,1)';
      final envelope = clip.outroTransition.type == TransitionType.fade
          ? remaining
          : _smoothstepExpression(remaining);
      alpha = '($alpha)*($envelope)';
    }
    return [
      "geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':"
          "a='alpha(X,Y)*clip(($alpha),0,1)'",
    ];
  }

  static String _smoothstepExpression(String progress) {
    return "(($progress)*($progress)*(3-2*($progress)))";
  }

  static List<String> _freezeFrameFilters(TimelineRenderInput input) {
    final clip = input.clip;
    final seek = _freezeSeekPlan(clip);
    // The frozen visual comes from a duplicate input seeked to at most one
    // second before the requested frame. Reversing this bounded prefix selects
    // the frame active at the requested presentation time, including VFR GIF
    // frames, without buffering everything from the beginning of a long clip.
    final inclusiveEndUs = seek.selectionOffset.inMicroseconds + 1;
    return [
      'settb=AVTB',
      'setpts=PTS-STARTPTS',
      'trim=end=${_seconds(Duration(microseconds: inclusiveEndUs))}',
      'reverse',
      'trim=end_frame=1',
      'setpts=PTS-STARTPTS',
      'tpad=stop_mode=clone:stop_duration=${_seconds(clip.duration)}',
      'trim=duration=${_seconds(clip.duration)}',
    ];
  }

  static bool _usesFrozenVisualInput(TimelineRenderInput input) {
    final clip = input.clip;
    return clip.freezeFrame &&
        (clip.type == TimelineTrackType.video ||
            clip.type == TimelineTrackType.gif ||
            _isAnimatedImage(input));
  }

  static ({Duration seekStart, Duration selectionOffset, Duration decodeWindow})
  _freezeSeekPlan(TimelineClip clip) {
    // Freeze-frame selection is independent of how much source media normal
    // playback consumes. The editor permits choosing any frame in the clip's
    // declared source span, including frames after a shortened timeline range.
    final playbackSourceWindow = _sourceWindow(clip);
    final selectableSourceWindow = clip.sourceDuration.inMicroseconds > 0
        ? clip.sourceDuration
        : playbackSourceWindow;
    final requestedOffset =
        clip.effectiveFreezeFrameSourceTime - clip.sourceStartTime;
    final maximumOffsetUs = math.max(
      0,
      selectableSourceWindow.inMicroseconds - 1,
    );
    final selectedOffsetUs = requestedOffset.inMicroseconds
        .clamp(0, maximumOffsetUs)
        .toInt();
    final seekOffsetUs = math.max(
      0,
      selectedOffsetUs - _freezeFramePreroll.inMicroseconds,
    );
    final selectionOffsetUs = selectedOffsetUs - seekOffsetUs;
    final decodeSourceWindow =
        selectedOffsetUs < playbackSourceWindow.inMicroseconds
        ? playbackSourceWindow
        : selectableSourceWindow;
    final remainingWindowUs = decodeSourceWindow.inMicroseconds - seekOffsetUs;
    final decodeWindowUs = math.min(
      remainingWindowUs,
      selectionOffsetUs + _freezeFramePreroll.inMicroseconds,
    );
    return (
      seekStart: clip.sourceStartTime + Duration(microseconds: seekOffsetUs),
      selectionOffset: Duration(microseconds: selectionOffsetUs),
      decodeWindow: Duration(microseconds: math.max(1, decodeWindowUs)),
    );
  }

  static String _audioVolumeFilter(
    TimelineClip clip, {
    required TimelineTrack track,
    required EditorTimeline timeline,
    required List<TimelineRenderInput> inputs,
    required Set<String> soloTrackIds,
  }) {
    final hasVolumeKeyframes = _hasKeyframes(
      clip,
      TimelineKeyframeProperty.volume,
    );
    var expression = _keyframedValueExpression(
      clip,
      TimelineKeyframeProperty.volume,
      fallback: clip.audioMix.volume,
      variable: 't',
      minimum: 0,
      maximum: 2,
    );
    final duckingFactor = clip.autoDuck && clip.duckAmount > 0.001
        ? _duckingVolumeExpression(
            clip,
            timeline: timeline,
            inputs: inputs,
            soloTrackIds: soloTrackIds,
          )
        : null;
    if (duckingFactor != null) {
      expression = 'clip(($expression)*($duckingFactor),0,2)';
    }
    final trackGain = track.audioGain.clamp(0.0, 2.0).toDouble();
    if ((trackGain - 1).abs() > 0.0001) {
      expression = 'clip(($expression)*${_number(trackGain)},0,4)';
    }
    if (!hasVolumeKeyframes &&
        duckingFactor == null &&
        (trackGain - 1).abs() <= 0.0001) {
      return 'volume=${_number(clip.audioMix.volume.clamp(0, 2))}';
    }
    return "volume='$expression':eval=frame";
  }

  @visibleForTesting
  static List<String> buildAudioEffectFiltersForTesting(
    EditorEffectStack stack,
  ) => _audioEffectFilters(stack);

  static List<String> _audioEffectFilters(EditorEffectStack stack) {
    final filters = <String>[];
    for (final effect in stack.effects) {
      if (!effect.enabled ||
          effect.intensity <= 0.0001 ||
          effect.domain != EditorEffectDomain.audio) {
        continue;
      }
      double value(String name, double fallback) {
        return effect
            .parameter(name, fallback)
            .clamp(-100000.0, 100000.0)
            .toDouble();
      }

      final intensity = effect.intensity.clamp(0.0, 1.0).toDouble();
      final amount = (value('amount', 1) * intensity)
          .clamp(0.0, 1.0)
          .toDouble();
      final filter = switch (effect.type) {
        EditorEffectType.equalizer =>
          'equalizer=f=${value('frequency', 1000).clamp(20, 20000)}:'
              'width_type=o:width=${value('width', 1).clamp(0.1, 10)}:'
              'g=${_number(value('gain', 0).clamp(-24, 24) * intensity)}',
        EditorEffectType.compressor =>
          'acompressor=threshold=${_number(_dbToLinear(value('threshold', -18)))}:'
              'ratio=${_number(1 + (value('ratio', 3).clamp(1, 20) - 1) * intensity)}:'
              'attack=${_number(value('attack', 20).clamp(0.01, 2000))}:'
              'release=${_number(value('release', 250).clamp(0.01, 5000))}',
        EditorEffectType.limiter =>
          'alimiter=limit=${_number(_dbToLinear(value('limit', -1)))}:'
              'attack=${_number(value('attack', 5).clamp(0.01, 2000))}:'
              'release=${_number(value('release', 50).clamp(0.01, 5000))}',
        EditorEffectType.noiseGate =>
          'agate=threshold=${_number(_dbToLinear(value('threshold', -45)))}:'
              'range=${_number(_dbToLinear(value('range', -18) * intensity))}',
        EditorEffectType.deEsser =>
          'deesser=i=${_number(amount.clamp(0.01, 1))}:'
              'm=${_number(amount.clamp(0.01, 1))}:'
              'f=${_number((value('frequency', 5500).clamp(1000, 12000) / 24000).clamp(0.0, 1.0))}',
        EditorEffectType.noiseReduction =>
          'afftdn=nr=${_number((amount * 24).clamp(1, 24))}:nf=-45',
        EditorEffectType.hissReduction =>
          'afftdn=nr=${_number((amount * 28).clamp(1, 28))}:'
              'nf=${_number(value('floor', -50).clamp(-80, -20))}:tn=1',
        EditorEffectType.humReduction => () {
          final base = value('frequency', 60).clamp(40, 70);
          final harmonics = value('harmonics', 3).round().clamp(1, 6);
          return [
            for (var harmonic = 1; harmonic <= harmonics; harmonic++)
              'equalizer=f=${_number(base * harmonic)}:'
                  'width_type=h:width=${_number(2 + amount * 8)}:'
                  'g=${_number(-amount * (18 / math.sqrt(harmonic)))}',
          ].join(',');
        }(),
        EditorEffectType.windReduction =>
          'highpass=f=${_number(value('cutoff', 120).clamp(40, 500))}:'
              'poles=2:width_type=o:width=${_number(0.7 + amount * 1.3)},'
              'afftdn=nr=${_number((2 + amount * 10).clamp(2, 12))}:nf=-35',
        EditorEffectType.clickRemoval =>
          'adeclick=w=${_number(35 + amount * 45)}:'
              'o=${_number(65 + amount * 25)}:'
              't=${_number(1 + amount * 5)}',
        EditorEffectType.declip =>
          'adeclip=w=${_number(35 + amount * 45)}:'
              'o=${_number(65 + amount * 25)}:'
              't=${_number(4 + amount * 16)}',
        EditorEffectType.dialogueEnhance => () {
          final presence = value('presence', 0.35).clamp(0.0, 1.0) * intensity;
          final clarity = value('clarity', 0.3).clamp(0.0, 1.0) * intensity;
          final warmth = value('warmth', 0.15).clamp(0.0, 1.0) * intensity;
          final compression =
              value('compression', 0.3).clamp(0.0, 1.0) * intensity;
          return 'highpass=f=${_number(55 + clarity * 45)}:poles=2,'
              'lowpass=f=${_number(18000 - clarity * 3500)}:poles=2,'
              'equalizer=f=180:width_type=o:width=1.2:'
              'g=${_number(warmth * 4)},'
              'equalizer=f=3200:width_type=o:width=1.1:'
              'g=${_number(presence * 6)},'
              'acompressor=threshold=${_number(_dbToLinear(-10 - compression * 18))}:'
              'ratio=${_number(1.5 + compression * 3.5)}:'
              'attack=12:release=180:makeup=${_number(1 + compression * 0.45)}';
        }(),
        EditorEffectType.deReverb => () {
          final room = value('room', 0.5).clamp(0.0, 1.0);
          return 'highpass=f=${_number(70 + amount * 80)}:poles=2,'
              'anlmdn=s=${_number((0.0001 + amount * 0.012).clamp(0.0001, 0.02))}:'
              'p=${_number(0.001 + room * 0.003)}:'
              'r=${_number(0.004 + room * 0.012)}:'
              'm=${_number(7 + amount * 18)},'
              'agate=threshold=${_number(_dbToLinear(-55 + amount * 18))}:'
              'ratio=${_number(1.2 + amount * 2.2)}:'
              'attack=8:release=${_number(120 + room * 280)}';
        }(),
        EditorEffectType.reverb =>
          'aecho=0.8:${_number((0.25 + amount * 0.65).clamp(0.25, 0.9))}:'
              '${_number(value('room', 0.35).clamp(0.05, 1) * 1000)}:'
              '${_number((value('damping', 0.5) * amount).clamp(0.01, 0.95))}',
        EditorEffectType.delay =>
          'aecho=1:1:${value('delayMs', 180).round().clamp(1, 2000)}:'
              '${_number((value('decay', 0.35) * intensity).clamp(0.01, 0.95))}',
        EditorEffectType.distortion =>
          'acrusher=bits=${_number((16 - amount * 8).clamp(4, 16))}:'
              'mix=${_number(amount)}',
        EditorEffectType.pitch => () {
          return _pitchShiftFilters(
            value('semitones', 0).clamp(-24, 24) * intensity,
          ).join(',');
        }(),
        EditorEffectType.timeStretch => _atempoFilters(
          1 + (value('rate', 1).clamp(0.25, 4) - 1) * intensity,
        ).join(','),
        _ => '',
      };
      if (filter.isNotEmpty) filters.add(filter);
    }
    return filters;
  }

  static String? _duckingVolumeExpression(
    TimelineClip clip, {
    required EditorTimeline timeline,
    required List<TimelineRenderInput> inputs,
    required Set<String> soloTrackIds,
  }) {
    final intervals = <(int, int)>[];
    final clipStartMs = clip.startTime.inMilliseconds;
    final clipDurationMs = clip.duration.inMilliseconds;

    void addInterval(Duration start, Duration end) {
      final localStart = math.max(0, start.inMilliseconds - clipStartMs);
      final localEnd = math.min(
        clipDurationMs,
        end.inMilliseconds - clipStartMs,
      );
      if (localEnd > localStart) intervals.add((localStart, localEnd));
    }

    for (final track in timeline.tracks) {
      if (track.isHidden ||
          (clip.duckSidechainTrackIds.isNotEmpty &&
              !clip.duckSidechainTrackIds.contains(track.id)) ||
          (track.type != TimelineTrackType.subtitle &&
              track.type != TimelineTrackType.text)) {
        continue;
      }
      for (final candidate in track.clips) {
        if (!candidate.enabled ||
            candidate.id == clip.id ||
            candidate.endTime <= candidate.startTime) {
          continue;
        }
        addInterval(candidate.startTime, candidate.endTime);
      }
    }

    for (final input in inputs) {
      if (input.clip.id == clip.id ||
          (clip.duckSidechainTrackIds.isNotEmpty &&
              !clip.duckSidechainTrackIds.contains(input.track.id)) ||
          !input.hasAudio ||
          input.track.isMuted ||
          input.clip.audioMix.muted ||
          (soloTrackIds.isNotEmpty && !soloTrackIds.contains(input.track.id))) {
        continue;
      }
      addInterval(input.clip.startTime, input.clip.endTime);
    }
    if (intervals.isEmpty) return null;

    intervals.sort((a, b) => a.$1.compareTo(b.$1));
    final attackMs = clip.duckAttackMs.clamp(0, 5000);
    final releaseMs = clip.duckReleaseMs.clamp(0, 10000);
    final merged = <(int, int)>[];
    for (final interval in intervals) {
      if (merged.isEmpty ||
          interval.$1 > merged.last.$2 + attackMs + releaseMs) {
        merged.add(interval);
      } else {
        final previous = merged.removeLast();
        merged.add((previous.$1, math.max(previous.$2, interval.$2)));
      }
    }

    final gain = (1 - clip.duckAmount.clamp(0.0, 1.0)).clamp(0.0, 1.0);
    final factors = <String>[];
    for (final interval in merged) {
      final attackStartMs = math.max(0, interval.$1 - attackMs);
      final releaseEndMs = math.min(clipDurationMs, interval.$2 + releaseMs);
      final attackStart = _number(attackStartMs / 1000);
      final start = _number(interval.$1 / 1000);
      final end = _number(interval.$2 / 1000);
      final releaseEnd = _number(releaseEndMs / 1000);
      final gainText = _number(gain);
      final depth = _number(1 - gain);
      final attack = interval.$1 > attackStartMs
          ? '1-($depth)*clip((t-$attackStart)/'
                '${_number((interval.$1 - attackStartMs) / 1000)},0,1)'
          : gainText;
      final release = releaseEndMs > interval.$2
          ? '$gainText+($depth)*clip((t-$end)/'
                '${_number((releaseEndMs - interval.$2) / 1000)},0,1)'
          : gainText;
      factors.add(
        'if(lt(t,$attackStart),1,'
        'if(lt(t,$start),($attack),'
        'if(lte(t,$end),$gainText,'
        'if(lt(t,$releaseEnd),($release),1))))',
      );
    }
    return factors.reduce((left, right) => 'min(($left),($right))');
  }

  static List<String> _cropFilters(ClipCropSettings crop) {
    if (crop.isIdentity) return const [];
    return [
      'crop=w=trunc(iw*${_number(crop.visibleWidth)}/2)*2:'
          'h=trunc(ih*${_number(crop.visibleHeight)}/2)*2:'
          'x=iw*${_number(crop.safeLeft)}:'
          'y=ih*${_number(crop.safeTop)}',
    ];
  }

  static List<String> _fitFilters(
    TimelineClip clip, {
    required ExportCanvasSize canvasSize,
    required bool isBase,
  }) {
    final width = isBase
        ? canvasSize.width
        : _makeEven((canvasSize.width * 0.36).round());
    final height = isBase
        ? canvasSize.height
        : _makeEven((canvasSize.height * 0.5).round());
    switch (clip.fitMode) {
      case ClipFitMode.cover:
        return [
          'scale=$width:$height:force_original_aspect_ratio=increase',
          'crop=$width:$height',
        ];
      case ClipFitMode.contain:
        if (isBase) {
          return ['scale=$width:$height:force_original_aspect_ratio=decrease'];
        }
        return ['scale=$width:$height:force_original_aspect_ratio=decrease'];
      case ClipFitMode.stretch:
        return ['scale=$width:$height'];
    }
  }

  static List<String> _inputColorTransformFilters(
    TimelineRenderInput input, {
    required EditorColorManagementSettings management,
  }) {
    final override = input.clip.colorAdjustments.inputColorSpace;
    final detected = _detectedInputColorSpace(input);
    final inputSpace = override == EditorColorSpace.automatic
        ? detected
        : override;
    if (override == EditorColorSpace.automatic &&
        inputSpace == EditorColorSpace.log &&
        !management.automaticLogTransform) {
      return const [];
    }
    final sourceTags = override == EditorColorSpace.automatic
        ? _detectedColorTags(input, detected)
        : _colorTagsForSpace(inputSpace);
    final targetTags = _colorTagsForSpace(management.workingSpace);
    return _colorSpaceConversionFilters(
      sourceTags: sourceTags,
      targetTags: targetTags,
      management: management,
      toneMapHdrToSdr: sourceTags.hdr && !targetTags.hdr,
    );
  }

  static List<String> _outputColorTransformFilters(
    EditorColorManagementSettings management, {
    required bool previewMode,
  }) {
    final sourceTags = _colorTagsForSpace(management.workingSpace);
    final intendedOutput = management.preserveHdr
        ? management.outputSpace
        : EditorColorSpace.sdr709;
    final outputSpace = previewMode ? EditorColorSpace.sdr709 : intendedOutput;
    final targetTags = _colorTagsForSpace(outputSpace);
    return _colorSpaceConversionFilters(
      sourceTags: sourceTags,
      targetTags: targetTags,
      management: management,
      toneMapHdrToSdr: sourceTags.hdr && !targetTags.hdr,
    );
  }

  static String _outputPixelFormat(
    EditorColorManagementSettings management,
    bool previewMode,
  ) {
    if (previewMode || !management.preserveHdr) return 'yuv420p';
    return management.outputSpace == EditorColorSpace.sdr709
        ? 'yuv420p'
        : 'yuv420p10le';
  }

  static EditorColorSpace _detectedInputColorSpace(TimelineRenderInput input) {
    final transfer = input.colorTransfer?.trim().toLowerCase() ?? '';
    final primaries = input.colorPrimaries?.trim().toLowerCase() ?? '';
    if (transfer == 'arib-std-b67' || transfer == 'hlg') {
      return EditorColorSpace.hlg;
    }
    if (transfer == 'smpte2084' || transfer == 'pq') {
      return EditorColorSpace.pq;
    }
    if (transfer == 'log100' || transfer == 'log316') {
      return EditorColorSpace.log;
    }
    if (primaries == 'bt2020' ||
        primaries == 'smpte432' ||
        primaries == 'display-p3') {
      return EditorColorSpace.wideGamut;
    }
    return EditorColorSpace.sdr709;
  }

  static ({
    String primaries,
    String transfer,
    String matrix,
    String range,
    bool hdr,
  })
  _detectedColorTags(TimelineRenderInput input, EditorColorSpace detected) {
    final fallback = _colorTagsForSpace(detected);
    final pixelFormat = input.pixelFormat?.trim().toLowerCase() ?? '';
    final rgbPixels =
        pixelFormat.startsWith('gbr') ||
        pixelFormat.startsWith('rgb') ||
        pixelFormat.startsWith('bgr');
    String supported(
      String? value,
      Set<String> supportedValues,
      String fallbackValue,
    ) {
      final normalized = value?.trim().toLowerCase();
      return normalized != null && supportedValues.contains(normalized)
          ? normalized
          : fallbackValue;
    }

    return (
      primaries: supported(input.colorPrimaries, const {
        'bt709',
        'bt2020',
        'smpte432',
        'smpte431',
      }, fallback.primaries),
      transfer: supported(input.colorTransfer, const {
        'bt709',
        'iec61966-2-1',
        'linear',
        'log100',
        'log316',
        'arib-std-b67',
        'smpte2084',
      }, fallback.transfer),
      matrix: supported(
        input.colorSpace,
        rgbPixels
            ? const {'bt709', 'bt2020nc', 'bt2020c', 'gbr'}
            : const {'bt709', 'bt2020nc', 'bt2020c'},
        fallback.matrix,
      ),
      range: supported(input.colorRange, const {
        'tv',
        'pc',
        'limited',
        'full',
      }, fallback.range).replaceAll('limited', 'tv').replaceAll('full', 'pc'),
      hdr: detected == EditorColorSpace.hlg || detected == EditorColorSpace.pq,
    );
  }

  static ({
    String primaries,
    String transfer,
    String matrix,
    String range,
    bool hdr,
  })
  _colorTagsForSpace(EditorColorSpace space) {
    return switch (space) {
      EditorColorSpace.hlg => (
        primaries: 'bt2020',
        transfer: 'arib-std-b67',
        matrix: 'bt2020nc',
        range: 'tv',
        hdr: true,
      ),
      EditorColorSpace.pq => (
        primaries: 'bt2020',
        transfer: 'smpte2084',
        matrix: 'bt2020nc',
        range: 'tv',
        hdr: true,
      ),
      EditorColorSpace.wideGamut => (
        primaries: 'bt2020',
        transfer: 'bt709',
        matrix: 'bt2020nc',
        range: 'tv',
        hdr: false,
      ),
      EditorColorSpace.log => (
        primaries: 'bt709',
        transfer: 'log100',
        matrix: 'bt709',
        range: 'tv',
        hdr: false,
      ),
      EditorColorSpace.automatic || EditorColorSpace.sdr709 => (
        primaries: 'bt709',
        transfer: 'bt709',
        matrix: 'bt709',
        range: 'tv',
        hdr: false,
      ),
    };
  }

  static List<String> _colorSpaceConversionFilters({
    required ({
      String primaries,
      String transfer,
      String matrix,
      String range,
      bool hdr,
    })
    sourceTags,
    required ({
      String primaries,
      String transfer,
      String matrix,
      String range,
      bool hdr,
    })
    targetTags,
    required EditorColorManagementSettings management,
    required bool toneMapHdrToSdr,
  }) {
    if (sourceTags == targetTags) return const [];
    final input =
        'pin=${sourceTags.primaries}:'
        'tin=${sourceTags.transfer}:'
        'min=${sourceTags.matrix}:rin=${sourceTags.range}';
    final output =
        'p=${targetTags.primaries}:'
        't=${targetTags.transfer}:'
        'm=${targetTags.matrix}:r=${targetTags.range}';
    final linearOutput =
        'p=${sourceTags.primaries}:'
        't=linear';
    final linearInput =
        'pin=${sourceTags.primaries}:'
        'tin=linear:min=gbr:rin=pc';
    if (toneMapHdrToSdr) {
      return [
        _evenFrameGeometryFilter,
        _setColorTagsFilter(sourceTags),
        'zscale=$input:$linearOutput:'
            'npl=${_number(management.peakLuminanceNits)}',
        'format=gbrpf32le',
        'tonemap=tonemap=${management.toneMapMode.name}:'
            'desat=0.15:peak=${_number(management.peakLuminanceNits / management.referenceWhiteNits)}',
        'zscale=$linearInput:$output',
      ];
    }
    return [
      _evenFrameGeometryFilter,
      _setColorTagsFilter(sourceTags),
      'zscale=$input:$linearOutput:'
          'npl=${_number(management.peakLuminanceNits)}',
      'format=gbrpf32le',
      'zscale=$linearInput:$output:'
          'npl=${_number(management.peakLuminanceNits)}',
    ];
  }

  static const String _evenFrameGeometryFilter =
      "scale=w='max(2,ceil(iw/2)*2)':h='max(2,ceil(ih/2)*2)':flags=lanczos";

  static String _setColorTagsFilter(
    ({String primaries, String transfer, String matrix, String range, bool hdr})
    tags,
  ) {
    final range = tags.range == 'pc' ? 'full' : 'limited';
    return 'setparams=range=$range:'
        'color_primaries=${tags.primaries}:'
        'color_trc=${tags.transfer}:'
        'colorspace=${tags.matrix}';
  }

  static List<String> _colorFilters(ClipColorAdjustments adjustments) {
    final exposure = adjustments.exposure.clamp(-4.0, 4.0).toDouble();
    final effectiveBrightness =
        (adjustments.brightness + adjustments.fade * 0.05).clamp(-1, 1);
    final effectiveContrast =
        (adjustments.contrast * (1 - adjustments.fade * 0.22)).clamp(0.1, 3);
    final effectiveGamma = adjustments.gamma.clamp(0.1, 4.0).toDouble();
    final filters = <String>[];
    if (exposure.abs() > 0.0001) {
      filters.add('exposure=exposure=${_number(exposure)}:black=0');
    }
    if (effectiveBrightness.abs() > 0.0001 ||
        (effectiveContrast - 1).abs() > 0.0001 ||
        (adjustments.saturation - 1).abs() > 0.0001 ||
        (effectiveGamma - 1).abs() > 0.0001) {
      filters.add(
        'eq=brightness=${_number(effectiveBrightness)}:'
        'contrast=${_number(effectiveContrast)}:'
        'saturation=${_number(adjustments.saturation.clamp(0, 3))}:'
        'gamma=${_number(effectiveGamma)}',
      );
    }
    if (adjustments.temperature.abs() > 0.001 ||
        adjustments.tint.abs() > 0.001 ||
        (adjustments.redGain - 1).abs() > 0.001 ||
        (adjustments.greenGain - 1).abs() > 0.001 ||
        (adjustments.blueGain - 1).abs() > 0.001 ||
        adjustments.wheels.globalRed.abs() > 0.001 ||
        adjustments.wheels.globalGreen.abs() > 0.001 ||
        adjustments.wheels.globalBlue.abs() > 0.001) {
      final warmth = (adjustments.temperature * 0.16).clamp(-0.2, 0.2);
      final tint = (adjustments.tint * 0.12).clamp(-0.2, 0.2);
      final wheels = adjustments.wheels;
      filters.add(
        'colorchannelmixer='
        'rr=${_number((adjustments.redGain + warmth + tint + wheels.globalRed).clamp(0, 3))}:'
        'gg=${_number((adjustments.greenGain - tint + wheels.globalGreen).clamp(0, 3))}:'
        'bb=${_number((adjustments.blueGain - warmth + tint + wheels.globalBlue).clamp(0, 3))}',
      );
    }
    if (adjustments.vibrance.abs() > 0.001) {
      filters.add(
        'vibrance=intensity=${_number(adjustments.vibrance.clamp(-1, 1))}',
      );
    }
    if (adjustments.hue.abs() > 0.001) {
      filters.add('hue=h=${_number(adjustments.hue.clamp(-180, 180))}');
    }
    if (adjustments.highlights.abs() > 0.001 ||
        adjustments.shadows.abs() > 0.001 ||
        adjustments.whites.abs() > 0.001 ||
        adjustments.blacks.abs() > 0.001) {
      final blackFloor = (adjustments.blacks.clamp(0, 1) * 0.06).toDouble();
      final blackPoint = (0.12 + adjustments.blacks * 0.1)
          .clamp(blackFloor + 0.01, 0.22)
          .toDouble();
      final shadowPoint = (0.25 + adjustments.shadows * 0.17)
          .clamp(blackPoint + 0.01, 0.46)
          .toDouble();
      final highlightPoint = (0.75 + adjustments.highlights * 0.17)
          .clamp(0.54, 0.9)
          .toDouble();
      final whitePoint = (0.88 + adjustments.whites * 0.1)
          .clamp(highlightPoint + 0.01, 0.99)
          .toDouble();
      final whiteCeiling = (1 + math.min(0.0, adjustments.whites) * 0.06)
          .clamp(whitePoint + 0.005, 1.0)
          .toDouble();
      final toneCurve = EditorColorCurve(
        points: [
          EditorColorCurvePoint(0, blackFloor),
          EditorColorCurvePoint(0.12, blackPoint),
          EditorColorCurvePoint(0.25, shadowPoint),
          EditorColorCurvePoint(0.75, highlightPoint),
          EditorColorCurvePoint(0.88, whitePoint),
          EditorColorCurvePoint(1, whiteCeiling),
        ],
      );
      filters.add("curves=all='${_curveExpression(toneCurve)}'");
    }
    if (!adjustments.wheels.isIdentity) {
      final wheels = adjustments.wheels;
      filters.add(
        'colorbalance='
        'rs=${_number(wheels.shadowsRed.clamp(-1, 1))}:'
        'gs=${_number(wheels.shadowsGreen.clamp(-1, 1))}:'
        'bs=${_number(wheels.shadowsBlue.clamp(-1, 1))}:'
        'rm=${_number(wheels.midtonesRed.clamp(-1, 1))}:'
        'gm=${_number(wheels.midtonesGreen.clamp(-1, 1))}:'
        'bm=${_number(wheels.midtonesBlue.clamp(-1, 1))}:'
        'rh=${_number(wheels.highlightsRed.clamp(-1, 1))}:'
        'gh=${_number(wheels.highlightsGreen.clamp(-1, 1))}:'
        'bh=${_number(wheels.highlightsBlue.clamp(-1, 1))}',
      );
    }
    if (!adjustments.rgbCurve.isIdentity) {
      filters.add("curves=all='${_curveExpression(adjustments.rgbCurve)}'");
    }
    filters.addAll(_secondaryColorCurveFilters(adjustments));
    if (adjustments.vignette > 0.001) {
      final angle =
          (math.pi / 2) * (1 - adjustments.vignette.clamp(0, 1) * 0.55);
      filters.add('vignette=angle=${_number(angle)}');
    }
    if (adjustments.sharpen > 0.001) {
      final amount = 0.2 + adjustments.sharpen.clamp(0, 1) * 1.3;
      filters.add('unsharp=5:5:${_number(amount)}:5:5:0');
    }
    return filters;
  }

  static List<String> _secondaryColorCurveFilters(
    ClipColorAdjustments adjustments,
  ) {
    final filters = <String>[];
    const hueBands = <({double input, String color})>[
      (input: 0, color: 'r'),
      (input: 1 / 6, color: 'y'),
      (input: 2 / 6, color: 'g'),
      (input: 3 / 6, color: 'c'),
      (input: 4 / 6, color: 'b'),
      (input: 5 / 6, color: 'm'),
    ];
    for (final band in hueBands) {
      final hueShift =
          (adjustments.hueVsHueCurve.valueAt(band.input) - band.input) * 360;
      final saturationShift =
          adjustments.hueVsSaturationCurve.valueAt(band.input) - band.input;
      final luminanceShift =
          adjustments.hueVsLuminanceCurve.valueAt(band.input) - band.input;
      if (hueShift.abs() < 0.001 &&
          saturationShift.abs() < 0.001 &&
          luminanceShift.abs() < 0.001) {
        continue;
      }
      filters.add(
        'huesaturation=hue=${_number(hueShift.clamp(-180, 180))}:'
        'saturation=${_number(saturationShift.clamp(-1, 1))}:'
        'intensity=${_number(luminanceShift.clamp(-1, 1))}:'
        'colors=${band.color}:strength=1:lightness=1',
      );
    }

    if (!adjustments.luminanceVsSaturationCurve.isIdentity ||
        !adjustments.saturationVsSaturationCurve.isIdentity) {
      const red = 'r(X,Y)/255';
      const green = 'g(X,Y)/255';
      const blue = 'b(X,Y)/255';
      const maximum = 'max(max($red,$green),$blue)';
      const minimum = 'min(min($red,$green),$blue)';
      const luminance = '(($maximum)+($minimum))/2';
      const saturation =
          '(($maximum)-($minimum))/(1-abs(2*($luminance)-1)+0.000001)';
      final mappedSaturation = _curveValueExpression(
        adjustments.saturationVsSaturationCurve,
        saturation,
      );
      final luminanceSaturation = _curveValueExpression(
        adjustments.luminanceVsSaturationCurve,
        luminance,
      );
      final targetSaturation =
          'clip(($mappedSaturation)+(($luminanceSaturation)-($luminance)),0,1)';
      final factor = '(($targetSaturation)/(($saturation)+0.000001))';
      String channel(String value) =>
          '255*clip(($luminance)+(($value)-($luminance))*($factor),0,1)';
      filters.add(
        "geq=r='${channel(red)}':g='${channel(green)}':b='${channel(blue)}'",
      );
    }
    return filters;
  }

  static String _curveValueExpression(EditorColorCurve curve, String variable) {
    final points = curve.points.map((point) => point.normalized()).toList()
      ..sort((first, second) => first.input.compareTo(second.input));
    if (points.isEmpty) return variable;
    var expression = _number(points.last.output);
    for (var index = points.length - 1; index > 0; index--) {
      final previous = points[index - 1];
      final next = points[index];
      final span = math.max(0.000001, next.input - previous.input);
      final interpolation =
          '${_number(previous.output)}+'
          '(($variable)-${_number(previous.input)})/'
          '${_number(span)}*${_number(next.output - previous.output)}';
      expression =
          'if(lte($variable,${_number(next.input)}),$interpolation,$expression)';
    }
    return 'clip($expression,0,1)';
  }

  static ({String sourceLabel, bool changed}) _appendColorAdjustmentGraph({
    required List<String> filters,
    required String sourceLabel,
    required ClipColorAdjustments adjustments,
    required String labelPrefix,
    String? enableExpression,
  }) {
    var currentSource = sourceLabel;
    var changed = false;
    final primaryAndCurveFilters = _colorFilters(adjustments);
    if (primaryAndCurveFilters.isNotEmpty) {
      final outputLabel = '${labelPrefix}Base';
      final enabledFilters = enableExpression == null
          ? primaryAndCurveFilters
          : primaryAndCurveFilters
                .map((filter) => "$filter:enable='$enableExpression'")
                .toList();
      filters.add('[$currentSource]${enabledFilters.join(',')}[$outputLabel]');
      currentSource = outputLabel;
      changed = true;
    }

    final qualifier = adjustments.qualifier;
    final hasQualifierCorrection =
        qualifier.enabled &&
        (qualifier.hueShift.abs() > 0.001 ||
            qualifier.saturationShift.abs() > 0.001 ||
            qualifier.luminanceShift.abs() > 0.001);
    if (!hasQualifierCorrection) {
      return (sourceLabel: currentSource, changed: changed);
    }

    final originalLabel = '${labelPrefix}QualifierOriginal';
    final correctionInputLabel = '${labelPrefix}QualifierInput';
    final keyInputLabel = '${labelPrefix}QualifierKeyInput';
    final spatialInputLabel = '${labelPrefix}QualifierSpatialInput';
    final processedLabel = '${labelPrefix}QualifierProcessed';
    final keyMaskLabel = '${labelPrefix}QualifierKeyMask';
    final spatialMaskLabel = '${labelPrefix}QualifierSpatialMask';
    final combinedMaskLabel = '${labelPrefix}QualifierCombinedMask';
    final outputLabel = '${labelPrefix}QualifierOutput';
    final hasSpatialMask = qualifier.spatialMask != null;
    filters.add(
      '[$currentSource]split=${hasSpatialMask ? 4 : 3}'
      '[$originalLabel][$correctionInputLabel][$keyInputLabel]'
      '${hasSpatialMask ? '[$spatialInputLabel]' : ''}',
    );
    filters.add(
      '[$correctionInputLabel]'
      'huesaturation=hue=${_number(qualifier.hueShift.clamp(-180, 180))}:'
      'saturation=${_number(qualifier.saturationShift.clamp(-1, 1))}:'
      'intensity=${_number(qualifier.luminanceShift.clamp(-1, 1))}:'
      'colors=a:strength=1:lightness=1[$processedLabel]',
    );
    final qualifierMask = _qualifierMaskExpression(qualifier);
    final keyChain = StringBuffer(
      '[$keyInputLabel]format=gbrp,'
      "geq=r='$qualifierMask':g='$qualifierMask':b='$qualifierMask',"
      'format=gray',
    );
    if (enableExpression != null) {
      keyChain.write(
        ",geq=lum='p(X,Y)*(${enableExpression.replaceAll(RegExp(r'\\bt\\b'), 'T')})'",
      );
    }
    keyChain.write('[$keyMaskLabel]');
    filters.add(keyChain.toString());

    var finalMaskLabel = keyMaskLabel;
    if (hasSpatialMask) {
      final maskExpression = _editorEffectMaskExpression(
        qualifier.spatialMask,
        intensity: 1,
      );
      filters.add(
        '[$spatialInputLabel]format=gray,'
        "geq=lum='$maskExpression'"
        '${_maskFeatherFilter(qualifier.spatialMask)}[$spatialMaskLabel]',
      );
      filters.add(
        '[$keyMaskLabel][$spatialMaskLabel]'
        'blend=all_mode=multiply[$combinedMaskLabel]',
      );
      finalMaskLabel = combinedMaskLabel;
    }
    filters.add(
      '[$originalLabel][$processedLabel][$finalMaskLabel]'
      'maskedmerge=planes=15[$outputLabel]',
    );
    return (sourceLabel: outputLabel, changed: true);
  }

  static String _qualifierMaskExpression(EditorColorQualifier qualifier) {
    const red = 'r(X,Y)/255';
    const green = 'g(X,Y)/255';
    const blue = 'b(X,Y)/255';
    const maximum = 'max(max($red,$green),$blue)';
    const minimum = 'min(min($red,$green),$blue)';
    const delta = '(($maximum)-($minimum))';
    const hue =
        '(if(lte($delta,0.000001),0,'
        'if(gte($red,$maximum),mod((($green)-($blue))/($delta)+6,6),'
        'if(gte($green,$maximum),(($blue)-($red))/($delta)+2,'
        '(($red)-($green))/($delta)+4)))/6)';
    const luminance = '(($maximum)+($minimum))/2';
    const saturation = '(($delta)/(1-abs(2*($luminance)-1)+0.000001))';
    final target = qualifier.skinTone
        ? const HSLColor.fromAHSL(1, 28, 0.48, 0.55)
        : HSLColor.fromColor(Color(qualifier.color));
    final targetHue = target.hue / 360;
    final hueDistance =
        'min(abs(($hue)-${_number(targetHue)}),'
        '1-abs(($hue)-${_number(targetHue)}))';
    final saturationDistance =
        'abs(($saturation)-${_number(target.saturation)})';
    final luminanceDistance = 'abs(($luminance)-${_number(target.lightness)})';

    String rangeWeight(String distance, double range) {
      final safeRange = range.clamp(0.001, 1.0).toDouble();
      final softness = (qualifier.softness.clamp(0.0, 1.0) * safeRange)
          .clamp(0.0001, 1.0)
          .toDouble();
      return 'clip((${_number(safeRange + softness)}-($distance))/'
          '${_number(softness)},0,1)';
    }

    final hueWeight = rangeWeight(hueDistance, qualifier.hueRange);
    final saturationWeight = rangeWeight(
      saturationDistance,
      qualifier.saturationRange,
    );
    final luminanceWeight = rangeWeight(
      luminanceDistance,
      qualifier.luminanceRange,
    );
    return '255*($hueWeight)*($saturationWeight)*($luminanceWeight)';
  }

  static ({String filterGraph, String outputLabel})
  buildColorAdjustmentGraphPlan(
    ClipColorAdjustments adjustments, {
    String sourceLabel = 'input',
  }) {
    final filters = <String>[];
    final result = _appendColorAdjustmentGraph(
      filters: filters,
      sourceLabel: sourceLabel,
      adjustments: adjustments,
      labelPrefix: 'testColor',
    );
    return (filterGraph: filters.join(';'), outputLabel: result.sourceLabel);
  }

  @visibleForTesting
  static String buildColorAdjustmentGraphForTesting(
    ClipColorAdjustments adjustments, {
    String sourceLabel = 'input',
  }) {
    final plan = buildColorAdjustmentGraphPlan(
      adjustments,
      sourceLabel: sourceLabel,
    );
    if (plan.filterGraph.isEmpty) {
      return '[$sourceLabel]null[${plan.outputLabel}]';
    }
    return plan.filterGraph;
  }

  @visibleForTesting
  static List<String> buildColorFiltersForTesting(
    ClipColorAdjustments adjustments,
  ) => _colorFilters(adjustments);

  @visibleForTesting
  static void validateColorPipelineForTesting(EditorTimeline timeline) {
    _validateRenderableColorPipeline(timeline);
  }

  static void _validateRenderableColorPipeline(EditorTimeline timeline) {
    final management = timeline.colorManagement;
    if (management.workingSpace == EditorColorSpace.automatic ||
        management.workingSpace == EditorColorSpace.log ||
        management.outputSpace == EditorColorSpace.automatic ||
        management.outputSpace == EditorColorSpace.log) {
      throw ArgumentError(
        'Automatic and Log are input interpretations, not project output '
        'spaces. Choose SDR, HLG, PQ, or wide gamut.',
      );
    }
    if (management.preserveHdr &&
        management.outputSpace == EditorColorSpace.sdr709) {
      throw ArgumentError(
        'HDR preservation requires an HLG, PQ, or wide-gamut output space.',
      );
    }
  }

  static EditorEffectStack _colorAdjustmentLutStack(
    ClipColorAdjustments adjustments,
  ) {
    final lutPath = adjustments.lutPath?.trim();
    if (lutPath == null ||
        lutPath.isEmpty ||
        adjustments.lutIntensity <= 0.0001) {
      return const EditorEffectStack();
    }
    return EditorEffectStack(
      effects: [
        EditorEffect(
          type: EditorEffectType.lut,
          intensity: adjustments.lutIntensity,
          parameters: {'path': lutPath},
        ),
      ],
    );
  }

  static String _curveExpression(EditorColorCurve curve) {
    final points = curve.points
        .map(
          (point) =>
              '${_number(point.input.clamp(0.0, 1.0))}/${_number(point.output.clamp(0.0, 1.0))}',
        )
        .join(' ');
    return points.isEmpty ? '0/0 1/1' : points;
  }

  static List<String> _animatedEditorEffectFilters(
    EditorEffect effect, {
    required Duration fallbackTime,
    required Duration parameterTimeOffset,
    required Duration filterTimeOffset,
    required Duration? duration,
    String? outerEnableExpression,
  }) {
    if (duration == null ||
        duration <= Duration.zero ||
        effect.keyframes.length < 2) {
      return _editorEffectFilters(
        EditorEffectStack(effects: [effect]),
        time: fallbackTime,
        enableExpression: outerEnableExpression,
      );
    }

    final durationUs = duration.inMicroseconds;
    final segmentCount = (durationUs / 83333).ceil().clamp(1, 180);
    final segments = <({int startUs, int endUs, List<String> filters})>[];
    for (var index = 0; index < segmentCount; index++) {
      final startUs = (durationUs * index / segmentCount).round();
      final endUs = (durationUs * (index + 1) / segmentCount).round();
      final sampleUs = startUs + ((endUs - startUs) / 2).round();
      final rawFilters = _editorEffectFilters(
        EditorEffectStack(effects: [effect]),
        time: parameterTimeOffset + Duration(microseconds: sampleUs),
      );
      if (rawFilters.isEmpty) continue;
      if (segments.isNotEmpty &&
          listEquals(segments.last.filters, rawFilters) &&
          segments.last.endUs == startUs) {
        final previous = segments.removeLast();
        segments.add((
          startUs: previous.startUs,
          endUs: endUs,
          filters: previous.filters,
        ));
      } else {
        segments.add((startUs: startUs, endUs: endUs, filters: rawFilters));
      }
    }

    final animated = <String>[];
    for (final segment in segments) {
      final start = filterTimeOffset + Duration(microseconds: segment.startUs);
      final end = filterTimeOffset + Duration(microseconds: segment.endUs);
      final interval = 'gte(t,${_seconds(start)})*lt(t,${_seconds(end)})';
      final enable = outerEnableExpression == null
          ? interval
          : '($outerEnableExpression)*($interval)';
      animated.addAll(
        segment.filters.map((filter) => "$filter:enable='$enable'"),
      );
    }
    return animated;
  }

  static ({String sourceLabel, int appliedEffects})
  _appendEditorEffectStackGraph({
    required List<String> filters,
    required String sourceLabel,
    required EditorEffectStack stack,
    required String labelPrefix,
    Duration time = Duration.zero,
    Duration parameterTimeOffset = Duration.zero,
    Duration? animationDuration,
    Duration filterTimeOffset = Duration.zero,
    String? enableExpression,
  }) {
    var currentSource = sourceLabel;
    var appliedEffects = 0;
    for (final effect in stack.effects) {
      if (!effect.enabled ||
          effect.domain != EditorEffectDomain.visual ||
          effect.intensity <= 0.0001) {
        continue;
      }
      final canUseCompositeGraph =
          _usesCompositeEffectGraph(effect.type) &&
          (animationDuration == null || effect.keyframes.length < 2);
      if (canUseCompositeGraph) {
        final outputLabel = '${labelPrefix}Output$appliedEffects';
        final needsBlend =
            effect.mask != null ||
            effect.intensity < 0.999 ||
            enableExpression != null;
        if (!needsBlend) {
          _appendCompositeEditorEffectGraph(
            filters: filters,
            sourceLabel: currentSource,
            outputLabel: outputLabel,
            effect: effect,
            time: time + parameterTimeOffset,
            labelPrefix: '${labelPrefix}Composite$appliedEffects',
          );
        } else {
          final originalLabel = '${labelPrefix}Original$appliedEffects';
          final effectInputLabel = '${labelPrefix}Input$appliedEffects';
          final maskInputLabel = '${labelPrefix}MaskInput$appliedEffects';
          final processedLabel = '${labelPrefix}Processed$appliedEffects';
          final maskLabel = '${labelPrefix}Mask$appliedEffects';
          filters.add(
            '[$currentSource]split=3'
            '[$originalLabel][$effectInputLabel][$maskInputLabel]',
          );
          _appendCompositeEditorEffectGraph(
            filters: filters,
            sourceLabel: effectInputLabel,
            outputLabel: processedLabel,
            effect: effect,
            time: time + parameterTimeOffset,
            labelPrefix: '${labelPrefix}Composite$appliedEffects',
          );
          final maskExpression = _editorEffectMaskExpression(
            effect.mask,
            intensity: effect.intensity,
            enableExpression: enableExpression,
          );
          filters.add(
            '[$maskInputLabel]format=gray,'
            "geq=lum='$maskExpression'"
            '${_maskFeatherFilter(effect.mask)}[$maskLabel]',
          );
          filters.add(
            '[$originalLabel][$processedLabel][$maskLabel]'
            'maskedmerge=planes=15[$outputLabel]',
          );
        }
        currentSource = outputLabel;
        appliedEffects++;
        continue;
      }
      final effectFilters = _animatedEditorEffectFilters(
        effect,
        fallbackTime: time + parameterTimeOffset,
        parameterTimeOffset: parameterTimeOffset,
        filterTimeOffset: filterTimeOffset,
        duration: animationDuration,
        outerEnableExpression: effect.mask == null && effect.intensity >= 0.999
            ? enableExpression
            : null,
      );
      if (effectFilters.isEmpty) continue;
      final outputLabel = '${labelPrefix}Output$appliedEffects';
      if (effect.mask == null && effect.intensity >= 0.999) {
        filters.add('[$currentSource]${effectFilters.join(',')}[$outputLabel]');
        currentSource = outputLabel;
        appliedEffects++;
        continue;
      }

      final originalLabel = '${labelPrefix}Original$appliedEffects';
      final effectInputLabel = '${labelPrefix}Input$appliedEffects';
      final maskInputLabel = '${labelPrefix}MaskInput$appliedEffects';
      final processedLabel = '${labelPrefix}Processed$appliedEffects';
      final maskLabel = '${labelPrefix}Mask$appliedEffects';
      filters.add(
        '[$currentSource]split=3'
        '[$originalLabel][$effectInputLabel][$maskInputLabel]',
      );
      filters.add(
        '[$effectInputLabel]${effectFilters.join(',')}[$processedLabel]',
      );
      final maskExpression = _editorEffectMaskExpression(
        effect.mask,
        intensity: effect.intensity,
        enableExpression: enableExpression,
      );
      filters.add(
        '[$maskInputLabel]format=gray,'
        "geq=lum='$maskExpression'"
        '${_maskFeatherFilter(effect.mask)}[$maskLabel]',
      );
      filters.add(
        '[$originalLabel][$processedLabel][$maskLabel]'
        'maskedmerge=planes=15[$outputLabel]',
      );
      currentSource = outputLabel;
      appliedEffects++;
    }
    return (sourceLabel: currentSource, appliedEffects: appliedEffects);
  }

  static bool _usesCompositeEffectGraph(EditorEffectType type) {
    return switch (type) {
      EditorEffectType.glow ||
      EditorEffectType.bloom ||
      EditorEffectType.cinematicGlow ||
      EditorEffectType.glare ||
      EditorEffectType.bokeh ||
      EditorEffectType.flare ||
      EditorEffectType.lightLeak ||
      EditorEffectType.prism ||
      EditorEffectType.dropShadow ||
      EditorEffectType.outline ||
      EditorEffectType.stroke ||
      EditorEffectType.reflection => true,
      _ => false,
    };
  }

  static void _appendCompositeEditorEffectGraph({
    required List<String> filters,
    required String sourceLabel,
    required String outputLabel,
    required EditorEffect effect,
    required Duration time,
    required String labelPrefix,
  }) {
    double value(String name, double fallback) {
      return effect
          .parameterAt(name, time, fallback: fallback)
          .clamp(-1000.0, 1000.0)
          .toDouble();
    }

    String highlightIsolation(double threshold) {
      final cutoff = (threshold.clamp(0.0, 1.0) * 255).round();
      return "lutrgb=r='if(lt(val,$cutoff),0,val)':"
          "g='if(lt(val,$cutoff),0,val)':"
          "b='if(lt(val,$cutoff),0,val)'";
    }

    final baseLabel = '${labelPrefix}Base';
    final detailLabel = '${labelPrefix}Detail';
    final processedLabel = '${labelPrefix}Processed';
    final amount = value('amount', 0.65).clamp(0.0, 1.0).toDouble();
    switch (effect.type) {
      case EditorEffectType.glow:
      case EditorEffectType.bloom:
        final radius = value(
          'radius',
          effect.type == EditorEffectType.glow ? 18 : 22,
        ).clamp(1.0, 80.0);
        final threshold = value(
          'threshold',
          effect.type == EditorEffectType.glow ? 0.65 : 0.7,
        ).clamp(0.0, 1.0);
        filters.add('[$sourceLabel]split=2[$baseLabel][$detailLabel]');
        filters.add(
          '[$detailLabel]${highlightIsolation(threshold.toDouble())},'
          'gblur=sigma=${_number(radius)}[$processedLabel]',
        );
        filters.add(
          '[$baseLabel][$processedLabel]blend=all_mode=screen:'
          'all_opacity=${_number(amount)}[$outputLabel]',
        );
      case EditorEffectType.cinematicGlow:
        final radius = value('radius', 18).clamp(1.0, 80.0);
        filters.add('[$sourceLabel]split=2[$baseLabel][$detailLabel]');
        filters.add(
          '[$detailLabel]eq=brightness=${_number(amount * 0.06)}:'
          'contrast=${_number(1 + amount * 0.3)}:'
          'saturation=${_number(0.85 + amount * 0.25)},'
          'gblur=sigma=${_number(radius)}[$processedLabel]',
        );
        filters.add(
          '[$baseLabel][$processedLabel]blend=all_mode=softlight:'
          'all_opacity=${_number((0.3 + amount * 0.55).clamp(0.0, 1.0))}'
          '[$outputLabel]',
        );
      case EditorEffectType.glare:
        final horizontalLabel = '${labelPrefix}Horizontal';
        final verticalLabel = '${labelPrefix}Vertical';
        final combinedLabel = '${labelPrefix}Combined';
        final threshold = (0.9 - amount * 0.55).clamp(0.2, 0.9);
        final spread = (5 + amount * 58).round().clamp(5, 63);
        filters.add(
          '[$sourceLabel]split=3[$baseLabel][$horizontalLabel][$verticalLabel]',
        );
        filters.add(
          '[$horizontalLabel]${highlightIsolation(threshold.toDouble())},'
          'avgblur=sizeX=$spread:sizeY=1[${horizontalLabel}Blurred]',
        );
        filters.add(
          '[$verticalLabel]${highlightIsolation(threshold.toDouble())},'
          'avgblur=sizeX=1:sizeY=$spread[${verticalLabel}Blurred]',
        );
        filters.add(
          '[${horizontalLabel}Blurred][${verticalLabel}Blurred]'
          'blend=all_mode=addition:all_opacity=0.5[$combinedLabel]',
        );
        filters.add(
          '[$baseLabel][$combinedLabel]blend=all_mode=screen:'
          'all_opacity=${_number(amount)}[$outputLabel]',
        );
      case EditorEffectType.bokeh:
        final size = value('size', 12).round().clamp(2, 64);
        final threshold = (0.82 - amount * 0.35).clamp(0.3, 0.82);
        filters.add('[$sourceLabel]split=2[$baseLabel][$detailLabel]');
        filters.add(
          '[$detailLabel]${highlightIsolation(threshold.toDouble())},'
          'pixelize=w=$size:h=$size,'
          'gblur=sigma=${_number((1 + size * 0.16).clamp(1.0, 16.0))}'
          '[$processedLabel]',
        );
        filters.add(
          '[$baseLabel][$processedLabel]blend=all_mode=screen:'
          'all_opacity=${_number(amount)}[$outputLabel]',
        );
      case EditorEffectType.flare:
        final positionX = value('positionX', 0.7).clamp(0.0, 1.0);
        final positionY = value('positionY', 0.25).clamp(0.0, 1.0);
        final distance =
            'sqrt(pow(X/W-${_number(positionX)},2)+'
            'pow(Y/H-${_number(positionY)},2))';
        final ghostDistance =
            'sqrt(pow(X/W-${_number(1 - positionX)},2)+'
            'pow(Y/H-${_number(1 - positionY)},2))';
        final flare =
            'clip(exp(-pow(($distance)*5,2))+'
            '0.32*exp(-pow(($ghostDistance)*10,2)),0,1)';
        filters.add('[$sourceLabel]split=2[$baseLabel][$detailLabel]');
        filters.add(
          '[$detailLabel]format=gbrp,'
          "geq=r='255*($flare)':g='190*($flare)':b='95*($flare)'"
          '[$processedLabel]',
        );
        filters.add(
          '[$baseLabel][$processedLabel]blend=all_mode=screen:'
          'all_opacity=${_number(amount)}[$outputLabel]',
        );
      case EditorEffectType.lightLeak:
        final position = value('position', 0.5).clamp(0.0, 1.0);
        final distance =
            'sqrt(pow((X/W-${_number(position)})/0.55,2)+'
            'pow((Y/H-0.35)/0.85,2))';
        final leak = 'clip(1-($distance),0,1)';
        filters.add('[$sourceLabel]split=2[$baseLabel][$detailLabel]');
        filters.add(
          '[$detailLabel]format=gbrp,'
          "geq=r='255*($leak)':g='115*pow(($leak),1.25)':"
          "b='42*pow(($leak),1.65)'[$processedLabel]",
        );
        filters.add(
          '[$baseLabel][$processedLabel]blend=all_mode=screen:'
          'all_opacity=${_number(amount)}[$outputLabel]',
        );
      case EditorEffectType.prism:
        final shift = (2 + amount * 22).round().clamp(2, 24);
        filters.add('[$sourceLabel]split=2[$baseLabel][$detailLabel]');
        filters.add(
          '[$detailLabel]chromashift=cbh=$shift:crh=${-shift}:'
          'cbv=${(shift / 3).round()}:crv=${-(shift / 3).round()}'
          '[$processedLabel]',
        );
        filters.add(
          '[$baseLabel][$processedLabel]blend=all_mode=screen:'
          'all_opacity=${_number((amount * 0.55).clamp(0.0, 1.0))}'
          '[$outputLabel]',
        );
      case EditorEffectType.dropShadow:
        final shadowLabel = '${labelPrefix}Shadow';
        final canvasLabel = '${labelPrefix}Canvas';
        final shadowCanvasLabel = '${labelPrefix}ShadowCanvas';
        final blur = value('blur', 10).clamp(0.1, 80.0);
        final offsetX = value('offsetX', 8).round().clamp(-256, 256);
        final offsetY = value('offsetY', 8).round().clamp(-256, 256);
        filters.add(
          '[$sourceLabel]format=rgba,split=3'
          '[$baseLabel][$detailLabel][$canvasLabel]',
        );
        filters.add(
          '[$detailLabel]colorchannelmixer=rr=0:gg=0:bb=0:'
          'aa=${_number(amount)},gblur=sigma=${_number(blur)}[$shadowLabel]',
        );
        filters.add(
          '[$canvasLabel]colorchannelmixer=aa=0[${canvasLabel}Clear]',
        );
        filters.add(
          '[${canvasLabel}Clear][$shadowLabel]overlay=x=$offsetX:y=$offsetY:'
          'shortest=1:format=auto[$shadowCanvasLabel]',
        );
        filters.add(
          '[$shadowCanvasLabel][$baseLabel]overlay=x=0:y=0:'
          'shortest=1:format=auto[$outputLabel]',
        );
      case EditorEffectType.outline:
      case EditorEffectType.stroke:
        final width = value(
          'width',
          effect.type == EditorEffectType.outline ? 4 : 3,
        ).clamp(0.1, 40.0);
        filters.add('[$sourceLabel]split=2[$baseLabel][$detailLabel]');
        filters.add(
          '[$detailLabel]edgedetect=mode=colormix:'
          'high=${_number((0.25 + amount * 0.7).clamp(0.05, 1.0))},'
          'gblur=sigma=${_number(width / 2)}[$processedLabel]',
        );
        filters.add(
          '[$baseLabel][$processedLabel]blend=all_mode=screen:'
          'all_opacity=${_number(amount)}[$outputLabel]',
        );
      case EditorEffectType.reflection:
        final offset = value('offset', 0.1).clamp(0.0, 0.9);
        final reflectedLabel = '${labelPrefix}Reflected';
        final weight =
            'clip((Y/H-${_number(offset)})/'
            '${_number((1 - offset).clamp(0.1, 1.0))},0,1)*'
            '${_number(amount * 0.65)}';
        filters.add('[$sourceLabel]split=2[$baseLabel][$detailLabel]');
        filters.add(
          '[$detailLabel]vflip,eq=brightness=${_number(-amount * 0.18)}:'
          'saturation=${_number(1 - amount * 0.45)}[$reflectedLabel]',
        );
        filters.add(
          '[$baseLabel][$reflectedLabel]'
          "blend=all_expr='A*(1-($weight))+B*($weight)'[$outputLabel]",
        );
      default:
        throw StateError('${effect.type.name} is not a composite effect.');
    }
  }

  @visibleForTesting
  static ({String filterGraph, String outputLabel})
  buildEditorEffectGraphPlanForTesting(
    EditorEffect effect, {
    String sourceLabel = 'input',
    Duration time = Duration.zero,
  }) {
    final filters = <String>[];
    final result = _appendEditorEffectStackGraph(
      filters: filters,
      sourceLabel: sourceLabel,
      stack: EditorEffectStack(effects: [effect]),
      labelPrefix: 'testEffect',
      time: time,
    );
    return (filterGraph: filters.join(';'), outputLabel: result.sourceLabel);
  }

  static String _editorEffectMaskExpression(
    EditorEffectMask? mask, {
    required double intensity,
    String? enableExpression,
  }) {
    var expression = '255';
    if (mask != null) {
      final left = _maskTrackingExpression(
        mask,
        fallback: mask.safeX,
        value: (frame) => frame.x,
      );
      final top = _maskTrackingExpression(
        mask,
        fallback: mask.safeY,
        value: (frame) => frame.y,
      );
      final width = _maskTrackingExpression(
        mask,
        fallback: mask.safeWidth,
        value: (frame) => frame.width,
      );
      final height = _maskTrackingExpression(
        mask,
        fallback: mask.safeHeight,
        value: (frame) => frame.height,
      );
      final right = '(($left)+($width))';
      final bottom = '(($top)+($height))';
      final feather = mask.safeFeather;
      if (mask.shape == EditorEffectMaskShape.ellipse) {
        final centerX = '(($left)+($width)/2)';
        final centerY = '(($top)+($height)/2)';
        final radiusX = '(($width)/2)';
        final radiusY = '(($height)/2)';
        final distance =
            'sqrt(pow((X-W*$centerX)/(W*$radiusX),2)+'
            'pow((Y-H*$centerY)/(H*$radiusY),2))';
        if (feather <= 0.0001) {
          expression = "if(lte($distance,1),255,0)";
        } else {
          final edge = _number((feather * 0.5).clamp(0.001, 0.5));
          expression = '255*clip((1+$edge-($distance))/(2*$edge),0,1)';
        }
      } else if (mask.shape == EditorEffectMaskShape.freeform) {
        final points = mask.safePoints.length >= 3
            ? mask.safePoints
            : const <EditorMaskPoint>[
                EditorMaskPoint(0.25, 0.25),
                EditorMaskPoint(0.75, 0.25),
                EditorMaskPoint(0.75, 0.75),
                EditorMaskPoint(0.25, 0.75),
              ];
        final crossings = <String>[];
        for (var index = 0; index < points.length; index++) {
          final nextIndex = (index + 1) % points.length;
          final firstX = _maskPointTrackingExpression(
            mask,
            pointIndex: index,
            coordinate: (point) => point.x,
            fallback: points[index].x,
          );
          final firstY = _maskPointTrackingExpression(
            mask,
            pointIndex: index,
            coordinate: (point) => point.y,
            fallback: points[index].y,
          );
          final nextX = _maskPointTrackingExpression(
            mask,
            pointIndex: nextIndex,
            coordinate: (point) => point.x,
            fallback: points[nextIndex].x,
          );
          final nextY = _maskPointTrackingExpression(
            mask,
            pointIndex: nextIndex,
            coordinate: (point) => point.y,
            fallback: points[nextIndex].y,
          );
          crossings.add(
            'abs(gt(Y,H*($firstY))-gt(Y,H*($nextY)))*'
            'lt(X,W*($firstX)+((Y-H*($firstY))*'
            '(($nextX)-($firstX)))/(H*(($nextY)-($firstY))+0.000001))',
          );
        }
        expression = '255*mod(${crossings.join('+')},2)';
      } else {
        final inside =
            'between(X,W*$left,W*$right)*'
            'between(Y,H*$top,H*$bottom)';
        if (feather <= 0.0001) {
          expression = '255*($inside)';
        } else {
          final distance =
              'min(min(X-W*$left,W*$right-X),'
              'min(Y-H*$top,H*$bottom-Y))';
          final featherPixels = 'max(1,min(W,H)*${_number(feather * 0.25)})';
          expression =
              '255*clip((($distance)+$featherPixels)/'
              '(2*$featherPixels),0,1)';
        }
      }
      if (mask.inverted) expression = '255-($expression)';
    }
    final safeIntensity = intensity.clamp(0.0, 1.0).toDouble();
    expression = '($expression)*${_number(safeIntensity)}';
    if (enableExpression != null) {
      final frameExpression = enableExpression.replaceAll(
        RegExp(r'\bt\b'),
        'T',
      );
      expression = '($expression)*($frameExpression)';
    }
    return expression;
  }

  static String _maskFeatherFilter(EditorEffectMask? mask) {
    if (mask == null ||
        mask.shape != EditorEffectMaskShape.freeform ||
        mask.safeFeather <= 0.0001) {
      return '';
    }
    return ',gblur=sigma=${_number(0.5 + mask.safeFeather * 24)}';
  }

  static String _maskTrackingExpression(
    EditorEffectMask mask, {
    required double fallback,
    required double Function(EditorMaskTrackingKeyframe frame) value,
  }) {
    return _trackingValueExpression(
      mask.trackingKeyframes,
      fallback: fallback,
      value: value,
    );
  }

  static String _maskPointTrackingExpression(
    EditorEffectMask mask, {
    required int pointIndex,
    required double fallback,
    required double Function(EditorMaskPoint point) coordinate,
  }) {
    return _trackingValueExpression(
      mask.trackingKeyframes.where((frame) => frame.points.length > pointIndex),
      fallback: fallback,
      value: (frame) => coordinate(frame.points[pointIndex]),
    );
  }

  static String _trackingValueExpression(
    Iterable<EditorMaskTrackingKeyframe> trackingFrames, {
    required double fallback,
    required double Function(EditorMaskTrackingKeyframe frame) value,
  }) {
    final frames = trackingFrames.toList()
      ..sort((first, second) => first.time.compareTo(second.time));
    if (frames.isEmpty) return _number(fallback);
    if (frames.length == 1) return _number(value(frames.single));
    var expression = _number(value(frames.last));
    for (var index = frames.length - 1; index > 0; index--) {
      final previous = frames[index - 1];
      final next = frames[index];
      final start =
          previous.time.inMicroseconds / Duration.microsecondsPerSecond;
      final end = next.time.inMicroseconds / Duration.microsecondsPerSecond;
      final span = math.max(0.000001, end - start);
      final interpolation =
          '${_number(value(previous))}+'
          'clip((T-${_number(start)})/${_number(span)},0,1)*'
          '${_number(value(next) - value(previous))}';
      expression = 'if(lte(T,${_number(end)}),$interpolation,$expression)';
    }
    return expression;
  }

  @visibleForTesting
  static List<String> buildEditorEffectFiltersForTesting(
    EditorEffect effect, {
    Duration time = Duration.zero,
    String? enableExpression,
  }) {
    return _editorEffectFilters(
      EditorEffectStack(effects: [effect]),
      time: time,
      enableExpression: enableExpression,
    );
  }

  static List<String> _editorEffectFilters(
    EditorEffectStack stack, {
    Duration time = Duration.zero,
    String? enableExpression,
  }) {
    final filters = <String>[];
    for (final effect in stack.effects) {
      if (!effect.enabled || effect.intensity <= 0.0001) continue;
      double value(String name, double fallback) {
        return effect
            .parameterAt(name, time, fallback: fallback)
            .clamp(-1000.0, 1000.0)
            .toDouble();
      }

      final amount = value('amount', 1).clamp(0.0, 1.0).toDouble();
      final radius = value('radius', 12).clamp(0.0, 80.0).toDouble();
      double wrappedScrollPosition(double offset, double extent) {
        final fraction = (offset / extent).clamp(-0.49, 0.49).toDouble();
        return fraction < 0 ? 1 + fraction : fraction;
      }

      String highlightIsolation(double threshold) {
        final cutoff = (threshold.clamp(0.0, 1.0) * 255).round();
        return "lutrgb=r='if(lt(val,$cutoff),0,val)':"
            "g='if(lt(val,$cutoff),0,val)':"
            "b='if(lt(val,$cutoff),0,val)'";
      }

      final filter = switch (effect.type) {
        EditorEffectType.gaussianBlur =>
          'gblur=sigma=${_number(radius.clamp(0.0, 80.0))}',
        EditorEffectType.directionalBlur => () {
          final direction = value('angle', 0) * math.pi / 180;
          final horizontal = (radius * math.cos(direction)).abs().round().clamp(
            1,
            80,
          );
          final vertical = (radius * math.sin(direction)).abs().round().clamp(
            1,
            80,
          );
          return 'avgblur=sizeX=$horizontal:sizeY=$vertical';
        }(),
        EditorEffectType.motionBlur => () {
          final frameCount = (2 + amount * 5).round().clamp(2, 7);
          final direction = value('angle', 0) * math.pi / 180;
          final directionalRadius = (1 + amount * 14).round();
          final horizontal = (directionalRadius * math.cos(direction))
              .abs()
              .round()
              .clamp(1, 16);
          final vertical = (directionalRadius * math.sin(direction))
              .abs()
              .round()
              .clamp(1, 16);
          return 'tmix=frames=$frameCount:'
              "weights='${List.filled(frameCount, '1').join(' ')}'||"
              'avgblur=sizeX=$horizontal:sizeY=$vertical';
        }(),
        EditorEffectType.sharpen =>
          'unsharp=5:5:${_number(0.2 + amount * 1.8)}:5:5:0',
        EditorEffectType.glow || EditorEffectType.bloom => () {
          final threshold = value('threshold', 0.65).clamp(0.0, 1.0);
          return '${highlightIsolation(threshold.toDouble())}||'
              'gblur=sigma=${_number(radius.clamp(1.0, 80.0))}';
        }(),
        EditorEffectType.cinematicGlow =>
          'eq=brightness=${_number(amount * 0.08)}:'
              'contrast=${_number(1 + amount * 0.35)}:'
              'saturation=${_number(1 + amount * 0.18)}||'
              'gblur=sigma=${_number(radius.clamp(1.0, 80.0))}',
        EditorEffectType.bokeh => () {
          final size = value('size', 12).round().clamp(2, 64);
          return 'pixelize=w=$size:h=$size||'
              'gblur=sigma=${_number((1 + amount * size * 0.45).clamp(1.0, 32.0))}';
        }(),
        EditorEffectType.glare => () {
          final threshold = (0.9 - amount * 0.55).clamp(0.2, 0.9);
          return '${highlightIsolation(threshold.toDouble())}||'
              'gblur=sigma=${_number(2 + amount * 18)}';
        }(),
        EditorEffectType.flare => () {
          final positionX = value('positionX', 0.7).clamp(0.0, 1.0);
          final positionY = value('positionY', 0.25).clamp(0.0, 1.0);
          final angle = (math.pi / 2) * (1 - amount * 0.72);
          return 'vignette=mode=backward:angle=${_number(angle)}:'
              'x0=w*${_number(positionX)}:y0=h*${_number(positionY)}';
        }(),
        EditorEffectType.lightLeak => () {
          final position = value('position', 0.5).clamp(0.0, 1.0);
          final angle = (math.pi / 2) * (1 - amount * 0.65);
          return 'vignette=mode=backward:angle=${_number(angle)}:'
              'x0=w*${_number(position)}:y0=h*0.35||'
              'colorchannelmixer=rr=${_number(1 + amount * 0.35)}:'
              'gg=${_number(1 + amount * 0.12)}:'
              'bb=${_number(1 - amount * 0.22)}';
        }(),
        EditorEffectType.prism => () {
          final shift = (amount * 24).round().clamp(0, 24);
          return 'chromashift=cbh=$shift:crh=${-shift}:'
              'cbv=${(shift / 3).round()}:crv=${-(shift / 3).round()}';
        }(),
        EditorEffectType.vignette => () {
          final vignette = value('amount', 0.35).clamp(0.0, 1.0).toDouble();
          final softness = value('softness', 0.7).clamp(0.0, 1.0);
          final angle =
              (math.pi / 2) * (1 - vignette * (0.3 + (1 - softness) * 0.45));
          return 'vignette=angle=${_number(angle)}';
        }(),
        EditorEffectType.grain || EditorEffectType.noise =>
          'noise=alls=${_number((amount * 48).clamp(0.0, 100.0))}:allf=t+u',
        EditorEffectType.pixelate || EditorEffectType.mosaic =>
          'pixelize=w=${value('size', 12).round().clamp(2, 64)}:'
              'h=${value('size', 12).round().clamp(2, 64)}',
        EditorEffectType.posterize => () {
          final levels = value('levels', 6).round().clamp(2, 32);
          final step = 255 / (levels - 1);
          final halfStep = step / 2;
          return "lutrgb=r='floor((val+${_number(halfStep)})/${_number(step)})*${_number(step)}':"
              "g='floor((val+${_number(halfStep)})/${_number(step)})*${_number(step)}':"
              "b='floor((val+${_number(halfStep)})/${_number(step)})*${_number(step)}'";
        }(),
        EditorEffectType.emboss => () {
          final strength = value('amount', 0.65).clamp(0.0, 1.0);
          return 'convolution='
              '${_number(-2 * strength)} ${_number(-strength)} 0 '
              '${_number(-strength)} 1 ${_number(strength)} '
              '0 ${_number(strength)} ${_number(2 * strength)}';
        }(),
        EditorEffectType.edgeDetection || EditorEffectType.sketch =>
          'edgedetect=mode=colormix:high=${_number(amount.clamp(0.01, 1.0))}',
        EditorEffectType.chromaticAberration || EditorEffectType.rgbSplit =>
          'chromashift=cbh=${value('amount', 3).round().clamp(0, 24)}:'
              'crh=${-value('amount', 3).round().clamp(0, 24)}',
        EditorEffectType.lensDistortion || EditorEffectType.fisheye =>
          'lenscorrection=k1=${_number(value('amount', 0.2).clamp(-1.0, 1.0))}:'
              'k2=${_number(value('amount', 0.2).clamp(-1.0, 1.0) * 0.35)}',
        EditorEffectType.warp =>
          'lenscorrection=k1=${_number(value('amount', 0.2).clamp(-0.8, 0.8))}:'
              'k2=${_number(value('amount', 0.2).clamp(-0.8, 0.8) * 0.2)}',
        EditorEffectType.ripple => () {
          final strength = value('amount', 0.2).clamp(-0.8, 0.8);
          final frequency = value('frequency', 4).clamp(0.0, 30.0);
          return 'lenscorrection=k1=${_number(strength)}:'
              'k2=${_number(strength * (0.08 + frequency / 35))}';
        }(),
        EditorEffectType.wave => () {
          final strength = value('amount', 0.15).clamp(0.0, 1.0);
          final frequency = value('frequency', 3).clamp(0.0, 30.0);
          return "rotate=angle='${_number(strength * 0.035)}*"
              "sin(2*PI*t*${_number(frequency)})':ow=iw:oh=ih:c=black@0";
        }(),
        EditorEffectType.shake => () {
          final strength = value('amount', 0.25).clamp(0.0, 1.0);
          final frequency = value('frequency', 8).clamp(0.0, 30.0);
          return "rotate=angle='${_number(strength * 0.055)}*"
              "sin(2*PI*t*${_number(frequency)})':ow=iw:oh=ih:c=black@0";
        }(),
        EditorEffectType.glitch ||
        EditorEffectType.vhs ||
        EditorEffectType.crt =>
          'noise=alls=${_number((amount * 36).clamp(0.0, 100.0))}:allf=t+u||'
              'chromashift=cbh=${(amount * 4).round().clamp(0, 12)}:'
              'crh=${-(amount * 4).round().clamp(0, 12)}',
        EditorEffectType.scanLines =>
          'drawgrid=w=iw:h=${value('spacing', 4).round().clamp(2, 24)}:'
              't=1:c=black@${_number((amount * 0.7).clamp(0.05, 0.9))}',
        EditorEffectType.halftone => () {
          final size = value('size', 5).round().clamp(2, 64);
          return 'pixelize=w=$size:h=$size||'
              'drawgrid=w=$size:h=$size:t=1:'
              'c=black@${_number((amount * 0.75).clamp(0.05, 0.9))}';
        }(),
        EditorEffectType.comic || EditorEffectType.stylized =>
          'edgedetect=mode=colormix:high=${_number((amount * 0.8).clamp(0.05, 1.0))}',
        EditorEffectType.dropShadow => () {
          final blur = value('blur', 10).clamp(0.0, 80.0);
          final horizontal = wrappedScrollPosition(
            value('offsetX', 8),
            kTimelineDesignWidth,
          );
          final vertical = wrappedScrollPosition(
            value('offsetY', 8),
            kTimelineDesignHeight,
          );
          final channel = (1 - amount * 0.88).clamp(0.05, 1.0);
          return 'gblur=sigma=${_number(blur)}||'
              'colorchannelmixer=rr=${_number(channel)}:'
              'gg=${_number(channel)}:bb=${_number(channel)}||'
              'scroll=h=0:v=0:hpos=${_number(horizontal)}:'
              'vpos=${_number(vertical)}';
        }(),
        EditorEffectType.outline || EditorEffectType.stroke => () {
          final width = value(
            'width',
            effect.type == EditorEffectType.outline ? 4 : 3,
          ).clamp(0.0, 80.0);
          return 'edgedetect=mode=colormix:'
              'high=${_number(amount.clamp(0.05, 1.0))}||'
              'gblur=sigma=${_number((width / 2).clamp(0.1, 40.0))}';
        }(),
        EditorEffectType.reflection => () {
          final offset = value('offset', 0.1).clamp(0.0, 1.0);
          return 'vflip||'
              'scroll=h=0:v=0:hpos=0:vpos=${_number(offset)}||'
              'eq=brightness=${_number(-amount * 0.2)}:'
              'saturation=${_number(1 - amount * 0.45)}';
        }(),
        EditorEffectType.colorGrade =>
          'eq=brightness=${_number(value('brightness', 0).clamp(-1, 1))}:'
              'contrast=${_number(value('contrast', 1).clamp(0.1, 3))}:'
              'saturation=${_number(value('saturation', 1).clamp(0, 3))}:'
              'gamma=${_number(value('gamma', 1).clamp(0.1, 4))}',
        EditorEffectType.lut => () {
          final lutPath = effect.parameters['path'];
          if (lutPath is! String || lutPath.trim().isEmpty) return '';
          return "lut3d=file='${_escapeFilterPath(lutPath)}'";
        }(),
        EditorEffectType.equalizer ||
        EditorEffectType.compressor ||
        EditorEffectType.limiter ||
        EditorEffectType.noiseGate ||
        EditorEffectType.deEsser ||
        EditorEffectType.noiseReduction ||
        EditorEffectType.humReduction ||
        EditorEffectType.hissReduction ||
        EditorEffectType.windReduction ||
        EditorEffectType.clickRemoval ||
        EditorEffectType.declip ||
        EditorEffectType.dialogueEnhance ||
        EditorEffectType.deReverb ||
        EditorEffectType.reverb ||
        EditorEffectType.delay ||
        EditorEffectType.distortion ||
        EditorEffectType.pitch ||
        EditorEffectType.timeStretch => '',
      };
      if (filter.isEmpty) continue;
      final expanded = filter.split('||');
      for (final candidate in expanded) {
        filters.add(
          enableExpression == null
              ? candidate
              : candidate.contains('=')
              ? "$candidate:enable='$enableExpression'"
              : "$candidate=enable='$enableExpression'",
        );
      }
    }
    return filters;
  }

  static bool _transitionUsesAlpha(TransitionType type) {
    return type != TransitionType.none && type != TransitionType.cut;
  }

  static (String, String) _overlayPosition(
    TimelineClip clip, {
    required ExportCanvasSize canvasSize,
  }) {
    const referenceWidth = kTimelineDesignWidth;
    const referenceHeight = kTimelineDesignHeight;
    final localTime =
        '(t-${_number(clip.startTime.inMicroseconds / Duration.microsecondsPerSecond)})';
    final offsetX = _keyframedValueExpression(
      clip,
      TimelineKeyframeProperty.positionX,
      fallback: clip.transform.offsetX,
      variable: localTime,
    );
    final offsetY = _keyframedValueExpression(
      clip,
      TimelineKeyframeProperty.positionY,
      fallback: clip.transform.offsetY,
      variable: localTime,
    );
    final baseX =
        '(W-w)/2+($offsetX)*${_number(canvasSize.width / referenceWidth)}';
    final baseY =
        '(H-h)/2+($offsetY)*${_number(canvasSize.height / referenceHeight)}';

    final intro = clip.introTransition;
    final outro = clip.outroTransition;
    final start = clip.startTime.inMilliseconds / 1000;
    final end = clip.endTime.inMilliseconds / 1000;
    final introDuration = clip.effectiveIntroTransitionMs / 1000;
    final outroDuration = clip.effectiveOutroTransitionMs / 1000;

    String x = baseX;
    String y = baseY;
    if (introDuration > 0) {
      final linearProgress =
          'min(max((t-${_number(start)})/${_number(introDuration)},0),1)';
      final progress = _smoothstepExpression(linearProgress);
      if (intro.type == TransitionType.slideLeft) {
        x = '$baseX-W*(1-$progress)';
      } else if (intro.type == TransitionType.slideRight) {
        x = '$baseX+W*(1-$progress)';
      } else if (intro.type == TransitionType.slideUp) {
        y = '$baseY-H*(1-$progress)';
      } else if (intro.type == TransitionType.slideDown) {
        y = '$baseY+H*(1-$progress)';
      } else if (intro.type == TransitionType.slideUpLeft) {
        x = '$baseX-W*(1-$progress)';
        y = '$baseY-H*(1-$progress)';
      } else if (intro.type == TransitionType.slideUpRight) {
        x = '$baseX+W*(1-$progress)';
        y = '$baseY-H*(1-$progress)';
      }
    }
    if (outroDuration > 0) {
      final linearHidden =
          'min(max((t-${_number(end - outroDuration)})/'
          '${_number(outroDuration)},0),1)';
      final hidden = _smoothstepExpression(linearHidden);
      if (outro.type == TransitionType.slideLeft) {
        x = '($x)-W*$hidden';
      } else if (outro.type == TransitionType.slideRight) {
        x = '($x)+W*$hidden';
      } else if (outro.type == TransitionType.slideUp) {
        y = '($y)-H*$hidden';
      } else if (outro.type == TransitionType.slideDown) {
        y = '($y)+H*$hidden';
      } else if (outro.type == TransitionType.slideUpLeft) {
        x = '($x)-W*$hidden';
        y = '($y)-H*$hidden';
      } else if (outro.type == TransitionType.slideUpRight) {
        x = '($x)+W*$hidden';
        y = '($y)-H*$hidden';
      }
    }

    return (x, y);
  }

  /// Materializes the timeline's subtitle and text layers as an ASS track.
  /// Preview render caches use the same path so dense playback remains
  /// visually consistent with final export.
  static Future<String?> buildAssTrack({
    required EditorTimeline timeline,
    required List<SubtitleEntry> subtitleEntries,
    required SubtitleStyleModel globalSubtitleStyle,
    required ExportSettings settings,
    required ExportCanvasSize canvasSize,
  }) async {
    final entries = <SubtitleEntry>[];
    final cueRotationRadians = <String, double>{};
    final cueOpacities = <String, double>{};
    if (settings.burnSubtitles) {
      entries.addAll(
        SubtitleExportService.effectiveTimelineCaptions(
          timeline: timeline,
          entries: subtitleEntries,
        ),
      );
    }

    for (final track in timeline.tracks) {
      if (track.type != TimelineTrackType.text || track.isHidden) continue;
      for (final clip in track.clips) {
        if (!clip.enabled || clip.endTime <= clip.startTime) continue;
        final baseStyle =
            clip.subtitleStyle ??
            const SubtitleStyleModel(
              position: SubtitlePosition.center,
              fontSize: 32,
              maxWidthFactor: 0.8,
            );
        final style = baseStyle.copyWith(
          offsetX: baseStyle.offsetX + clip.transform.offsetX,
          offsetY: baseStyle.offsetY + clip.transform.offsetY,
          fontSize: baseStyle.fontSize * clip.transform.scale.clamp(0.25, 4),
        );
        entries.add(
          SubtitleEntry(
            id: clip.id,
            startTime: clip.startTime,
            endTime: clip.endTime,
            text: clip.text ?? clip.label,
            styleOverride: style,
          ),
        );
        cueRotationRadians[clip.id] = clip.transform.rotation;
        cueOpacities[clip.id] = clip.transform.opacity;
      }
    }

    if (entries.isEmpty) return null;
    return SubtitleExportService.generateAss(
      entries,
      globalSubtitleStyle,
      fileName: 'timeline_${DateTime.now().microsecondsSinceEpoch}.ass',
      playResX: canvasSize.width,
      playResY: canvasSize.height,
      cueRotationRadians: cueRotationRadians,
      cueOpacities: cueOpacities,
    );
  }

  static bool _hasAudibleInput(
    EditorTimeline timeline,
    List<TimelineRenderInput> inputs,
    ExportSettings settings,
  ) {
    if (!settings.includeAudio) return false;
    final soloTrackIds = inputs
        .where((input) => input.track.isSolo)
        .map((input) => input.track.id)
        .toSet();
    final soloBusIds = timeline.audioBuses
        .where((bus) => bus.solo)
        .map((bus) => bus.id)
        .toSet();
    final separatedVideoIds = _separatedVideoAudioOwnerIds(timeline);
    return inputs.any((input) {
      final bus = input.track.audioBusId == null
          ? null
          : timeline.audioBuses
                .where((candidate) => candidate.id == input.track.audioBusId)
                .firstOrNull;
      return input.hasAudio &&
          !(input.clip.type == TimelineTrackType.video &&
              (input.clip.embeddedAudioSeparated ||
                  separatedVideoIds.contains(input.clip.id))) &&
          !input.track.isMuted &&
          bus?.muted != true &&
          !input.clip.audioMix.muted &&
          (soloTrackIds.isEmpty || soloTrackIds.contains(input.track.id)) &&
          (soloBusIds.isEmpty || (bus != null && soloBusIds.contains(bus.id)));
    });
  }

  static Set<String> _separatedVideoAudioOwnerIds(EditorTimeline timeline) {
    return {
      for (final track in timeline.tracks)
        for (final clip in track.clips)
          if (clip.type == TimelineTrackType.audio &&
              clip.separatedAudioSourceClipId != null)
            clip.separatedAudioSourceClipId!,
    };
  }

  static List<String> _atempoFilters(double playbackRate) {
    var remaining = playbackRate.clamp(0.25, 4).toDouble();
    final filters = <String>[];
    while (remaining < 0.5) {
      filters.add('atempo=0.5');
      remaining /= 0.5;
    }
    while (remaining > 2) {
      filters.add('atempo=2');
      remaining /= 2;
    }
    if ((remaining - 1).abs() > 0.0001) {
      filters.add('atempo=${_number(remaining)}');
    }
    return filters;
  }

  static List<String> _timeStretchFilters(
    double rate, {
    required bool preservePitch,
  }) {
    final safeRate = rate.clamp(0.25, 4).toDouble();
    if ((safeRate - 1).abs() <= 0.0001) return const [];
    if (preservePitch) return _atempoFilters(safeRate);
    return ['asetrate=48000*${_number(safeRate)}', 'aresample=48000'];
  }

  static List<String> _pitchShiftFilters(double semitones) {
    final safeSemitones = semitones.clamp(-24.0, 24.0).toDouble();
    if (safeSemitones.abs() <= 0.0001) return const [];
    final ratio = math.pow(2, safeSemitones / 12).toDouble();
    return [
      'asetrate=48000*${_number(ratio)}',
      'aresample=48000',
      ..._atempoFilters(1 / ratio),
    ];
  }

  static String _panFilter(double pan) {
    final left = pan <= 0 ? 1.0 : 1 - pan;
    final right = pan >= 0 ? 1.0 : 1 + pan;
    return 'pan=stereo|c0=${_number(left)}*c0|'
        'c1=${_number(right)}*c1';
  }

  static String _loudnormFilter(
    AudioMixSettings mix, {
    required String expectedFingerprint,
  }) {
    final target = _number(mix.targetLufs.clamp(-60.0, 0.0));
    final peak = _number(mix.peakLimitDb.clamp(-24.0, 0.0));
    final analysis = mix.loudnessAnalysis;
    if (analysis == null || analysis.sourceFingerprint != expectedFingerprint) {
      return 'loudnorm=I=$target:LRA=11:TP=$peak';
    }
    return 'loudnorm=I=$target:LRA=11:TP=$peak:'
        'measured_I=${_number(analysis.integratedLufs)}:'
        'measured_LRA=${_number(analysis.loudnessRange)}:'
        'measured_TP=${_number(analysis.truePeakDb)}:'
        'measured_thresh=${_number(analysis.thresholdLufs)}:'
        'offset=${_number(analysis.targetOffset)}:linear=true';
  }

  static String _fadeCurve(AudioFadeShape shape) {
    return switch (shape) {
      AudioFadeShape.linear => 'tri',
      AudioFadeShape.logarithmic => 'log',
      AudioFadeShape.exponential => 'exp',
      AudioFadeShape.sCurve => 'qsin',
    };
  }

  static Duration _sourceWindow(TimelineClip clip) {
    final rate = clip.playbackRate.clamp(0.25, 4);
    final audioStretch = clip.audioMix.timeStretch.clamp(0.25, 4);
    final requiredStretch = clip.type == TimelineTrackType.audio
        ? audioStretch
        : math.max(1.0, audioStretch);
    final neededMilliseconds =
        (clip.duration.inMilliseconds * rate * requiredStretch).round();
    final declaredMilliseconds = clip.sourceDuration.inMilliseconds;
    final milliseconds = declaredMilliseconds > 0
        ? math.min(declaredMilliseconds, neededMilliseconds)
        : neededMilliseconds;
    return Duration(milliseconds: math.max(1, milliseconds));
  }

  static Future<void> _execute(
    List<String> arguments, {
    required Duration expectedDuration,
    bool captionsExpected = false,
    void Function(double progress)? onProgress,
  }) async {
    if (onProgress != null && expectedDuration.inMilliseconds > 0) {
      FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
        final time = statistics.getTime();
        if (time <= 0) return;
        onProgress((time / expectedDuration.inMilliseconds).clamp(0.0, 1.0));
      });
    }
    final session = await FFmpegKit.executeWithArguments(arguments);
    final returnCode = await session.getReturnCode();
    final logs = captionsExpected || !ReturnCode.isSuccess(returnCode)
        ? await session.getAllLogsAsString() ?? ''
        : '';
    if (ReturnCode.isSuccess(returnCode)) {
      if (captionsExpected && _hasCaptionFontFailure(logs)) {
        throw StateError(
          'The video rendered, but its caption font could not be loaded. '
          'No captionless file was saved. Reopen the app and try again.\n'
          '${_lastMeaningfulLogLines(logs)}',
        );
      }
      return;
    }
    if (ReturnCode.isCancel(returnCode)) {
      throw Exception('Export cancelled.');
    }
    final usefulLog = _lastMeaningfulLogLines(logs);
    throw Exception(
      usefulLog.isEmpty
          ? 'FFmpeg could not render the timeline.'
          : 'FFmpeg could not render the timeline:\n$usefulLog',
    );
  }

  static bool _hasCaptionFontFailure(String logs) {
    final normalized = logs.toLowerCase();
    return const [
      'fontselect: failed',
      'could not find/open font',
      'no usable fontconfig',
      'cannot find a valid font',
      'fontconfig error',
    ].any(normalized.contains);
  }

  static String _lastMeaningfulLogLines(String logs) {
    final lines = logs
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    return lines.skip(math.max(0, lines.length - 8)).join('\n');
  }

  static int _makeEven(int value) => value.isEven ? value : value + 1;

  static String _seconds(Duration duration) {
    return (duration.inMicroseconds / Duration.microsecondsPerSecond)
        .toStringAsFixed(6);
  }

  static String _number(num value) {
    final text = value.toStringAsFixed(6);
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static double _dbToLinear(double decibels) {
    return math.pow(10, decibels.clamp(-80.0, 12.0) / 20).toDouble();
  }

  static String _ffmpegColor(Color color) {
    final red = (color.r * 255).round().clamp(0, 255);
    final green = (color.g * 255).round().clamp(0, 255);
    final blue = (color.b * 255).round().clamp(0, 255);
    return '0x${red.toRadixString(16).padLeft(2, '0')}'
        '${green.toRadixString(16).padLeft(2, '0')}'
        '${blue.toRadixString(16).padLeft(2, '0')}';
  }

  static String _escapeFilterPath(String value) {
    return value
        .replaceAll('\\', '/')
        .replaceAll(':', r'\:')
        .replaceAll("'", r"\'")
        .replaceAll('[', r'\[')
        .replaceAll(']', r'\]');
  }
}

class TimelineRenderInput {
  final int index;
  final int trackIndex;
  final TimelineTrack track;
  final TimelineClip clip;
  final EditorAssetReference? asset;
  final String sourcePath;
  final bool hasAudio;
  final double? frameRate;
  final String? colorPrimaries;
  final String? colorTransfer;
  final String? colorSpace;
  final String? colorRange;
  final String? pixelFormat;
  final int? bitDepth;
  final int? audioStreamCount;
  final int? audioChannels;
  final List<int>? audioChannelsByStream;

  const TimelineRenderInput({
    required this.index,
    required this.trackIndex,
    required this.track,
    required this.clip,
    required this.asset,
    required this.sourcePath,
    required this.hasAudio,
    this.frameRate,
    this.colorPrimaries,
    this.colorTransfer,
    this.colorSpace,
    this.colorRange,
    this.pixelFormat,
    this.bitDepth,
    this.audioStreamCount,
    this.audioChannels,
    this.audioChannelsByStream,
  });

  bool get isVisual {
    return clip.type == TimelineTrackType.video ||
        clip.type == TimelineTrackType.image ||
        clip.type == TimelineTrackType.gif ||
        clip.type == TimelineTrackType.sticker;
  }
}

List<int>? audioChannelsByStreamFromMetadata(Object? value) {
  if (value is! List) return null;
  final channels = <int>[];
  for (final stream in value) {
    if (stream is! Map) continue;
    final raw = stream['channels'];
    final parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
    channels.add((parsed ?? 2).clamp(1, 64));
  }
  return channels.isEmpty ? null : List.unmodifiable(channels);
}
