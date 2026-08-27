import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/editor/models/export_settings.dart';
import '../../features/editor/models/subtitle_entry.dart';
import '../../features/editor/models/subtitle_style_model.dart';
import '../../features/editor/models/timeline_models.dart';
import '../../shared/models/project_model.dart';
import 'caption_font_service.dart';
import 'ffmpeg_service.dart';
import 'subtitle_export_service.dart';

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

class TimelineExportService {
  TimelineExportService._();

  static const _freezeFramePreroll = Duration(seconds: 1);
  static const _maxNetworkAssetBytes = 64 * 1024 * 1024;
  static CancelToken? _activeDownloadCancelToken;

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
    required String outputPath,
  }) {
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
    );
    args
      ..addAll(['-filter_complex', filterGraph])
      ..addAll(['-map', '[vout]']);

    final hasAudioOutput = _hasAudibleInput(inputs, settings);
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

    args.addAll([
      '-c:v',
      'libx264',
      '-preset',
      videoPreset ?? settings.preset,
      '-crf',
      '${videoCrf ?? settings.crf}',
      '-pix_fmt',
      'yuv420p',
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
    if (metadata['durationMs'] is num &&
        (metadata['hasAudio'] is bool ||
            asset?.type == EditorAssetType.audio ||
            asset?.type == EditorAssetType.image ||
            asset?.type == EditorAssetType.gif ||
            asset?.type == EditorAssetType.sticker)) {
      return {
        ...metadata,
        'hasAudio':
            asset?.type == EditorAssetType.audio ||
            (metadata['hasAudio'] as bool? ?? false),
      };
    }
    try {
      return await (mediaInfoLoader?.call(sourcePath) ??
          FFmpegService.getMediaInfo(sourcePath));
    } catch (_) {
      return {...metadata, 'hasAudio': asset?.type == EditorAssetType.audio};
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
        ..._colorFilters(clip.colorAdjustments),
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
      if (clip.blur.mode == ClipBlurMode.region && _blurIsEnabled(clip)) {
        final clean = 'clean$visualIndex';
        final blurredSource = 'blurSource$visualIndex';
        final blurredRegion = 'blurRegion$visualIndex';
        final effected = 'effected$visualIndex';
        final blur = clip.blur;
        filters.add(
          '[$visualInputIndex:v]${preparation.join(',')},'
          'format=rgba,split=2[$clean][$blurredSource]',
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
        filters.add('[$effected]${finishing.join(',')}[$visualLabel]');
      } else {
        final chain = <String>[
          ...preparation,
          if (clip.blur.mode == ClipBlurMode.full && _blurIsEnabled(clip))
            ..._blurFilterChain(clip, target: 'clipFullBlur$visualIndex'),
          ...finishing,
        ];
        filters.add('[$visualInputIndex:v]${chain.join(',')}[$visualLabel]');
      }

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
    filters.add(
      '[$videoSource]format=yuv420p,'
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
    final audioLabels = <String>[];
    if (includeAudio) {
      final soloTrackIds = inputs
          .where((input) => input.track.isSolo)
          .map((input) => input.track.id)
          .toSet();
      var audioIndex = 0;
      for (final input in inputs) {
        if (!input.hasAudio ||
            input.track.isMuted ||
            input.clip.audioMix.muted ||
            (soloTrackIds.isNotEmpty &&
                !soloTrackIds.contains(input.track.id))) {
          continue;
        }
        final label = 'audio$audioIndex';
        final clip = input.clip;
        final clipDurationSeconds = clip.duration.inMilliseconds / 1000;
        final mix = clip.audioMix;
        final fadeInSeconds = clip.effectiveAudioFadeInMs / 1000;
        final fadeOutSeconds = clip.effectiveAudioFadeOutMs / 1000;
        final audioChain = <String>[
          if (clip.isReversed) 'areverse',
          'asetpts=PTS-STARTPTS',
          ..._atempoFilters(clip.playbackRate),
          'atrim=duration=${_seconds(clip.duration)}',
          'aformat=sample_rates=48000:channel_layouts=stereo',
          if (clip.denoise) 'afftdn=nr=12:nf=-45',
          if (mix.normalize) 'loudnorm=I=-16:LRA=11:TP=-1.5',
          _audioVolumeFilter(
            clip,
            timeline: timeline,
            inputs: inputs,
            soloTrackIds: soloTrackIds,
          ),
          if (mix.pan.abs() > 0.001)
            _panFilter(mix.pan.clamp(-1, 1).toDouble()),
          if (fadeInSeconds > 0) 'afade=t=in:st=0:d=${_number(fadeInSeconds)}',
          if (fadeOutSeconds > 0)
            'afade=t=out:st=${_number(math.max(0, clipDurationSeconds - fadeOutSeconds))}:'
                'd=${_number(fadeOutSeconds)}',
          'adelay=${clip.startTime.inMilliseconds}|'
              '${clip.startTime.inMilliseconds}',
          'apad',
          'atrim=duration=$durationSeconds',
        ];
        filters.add('[${input.index}:a]${audioChain.join(',')}[$label]');
        audioLabels.add(label);
        audioIndex++;
      }
    }

    if (audioLabels.length == 1) {
      filters.add(
        '[${audioLabels.first}]anull,atrim=duration=$durationSeconds[aout]',
      );
    } else if (audioLabels.length > 1) {
      final inputsExpression = audioLabels.map((label) => '[$label]').join();
      filters.add(
        '$inputsExpression'
        'amix=inputs=${audioLabels.length}:duration=longest:'
        'dropout_transition=0:normalize=0,'
        // Compensating limiter latency keeps the rendered preview bus aligned
        // to the visual timeline while protecting dense mixes from clipping.
        'alimiter=limit=0.95:attack=5:release=50:latency=1,'
        'atrim=duration=$durationSeconds[aout]',
      );
    }
    return audioLabels.isNotEmpty;
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
      final outputLabel = 'timelineEffect$appliedEffectIndex';

      switch (clip.effectKind!) {
        case TimelineEffectKind.blur:
          final blur = clip.blur;
          if (!_blurIsEnabled(clip)) continue;
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
          break;
        case TimelineEffectKind.filter:
          final colorFilters = _colorFilters(clip.colorAdjustments);
          if (colorFilters.isEmpty) continue;
          final timedFilters = colorFilters
              .map((filter) => "$filter:enable='$enableExpression'")
              .join(',');
          filters.add('[$currentSource]$timedFilters[$outputLabel]');
          break;
      }

      currentSource = outputLabel;
      appliedEffectIndex++;
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
    if (!hasVolumeKeyframes && duckingFactor == null) {
      return 'volume=${_number(clip.audioMix.volume.clamp(0, 2))}';
    }
    return "volume='$expression':eval=frame";
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
    const attackMs = 120;
    const releaseMs = 180;
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

  static List<String> _colorFilters(ClipColorAdjustments adjustments) {
    if (adjustments.isNeutral) return const [];
    final effectiveBrightness =
        (adjustments.brightness + adjustments.fade * 0.05).clamp(-1, 1);
    final effectiveContrast =
        (adjustments.contrast * (1 - adjustments.fade * 0.22)).clamp(0.1, 3);
    final filters = <String>[
      'eq=brightness=${_number(effectiveBrightness)}:'
          'contrast=${_number(effectiveContrast)}:'
          'saturation=${_number(adjustments.saturation.clamp(0, 3))}',
    ];
    if (adjustments.temperature.abs() > 0.001) {
      final warmth = (adjustments.temperature * 0.16).clamp(-0.2, 0.2);
      filters.add(
        'colorchannelmixer=rr=${_number(1 + warmth)}:'
        'bb=${_number(1 - warmth)}',
      );
    }
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
      }
    }

    if (entries.isEmpty) return null;
    return SubtitleExportService.generateAss(
      entries,
      globalSubtitleStyle,
      fileName: 'timeline_${DateTime.now().microsecondsSinceEpoch}.ass',
      playResX: canvasSize.width,
      playResY: canvasSize.height,
    );
  }

  static bool _hasAudibleInput(
    List<TimelineRenderInput> inputs,
    ExportSettings settings,
  ) {
    if (!settings.includeAudio) return false;
    final soloTrackIds = inputs
        .where((input) => input.track.isSolo)
        .map((input) => input.track.id)
        .toSet();
    return inputs.any(
      (input) =>
          input.hasAudio &&
          !input.track.isMuted &&
          !input.clip.audioMix.muted &&
          (soloTrackIds.isEmpty || soloTrackIds.contains(input.track.id)),
    );
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

  static String _panFilter(double pan) {
    final left = pan <= 0 ? 1.0 : 1 - pan;
    final right = pan >= 0 ? 1.0 : 1 + pan;
    return 'pan=stereo|c0=${_number(left)}*c0|'
        'c1=${_number(right)}*c1';
  }

  static Duration _sourceWindow(TimelineClip clip) {
    final rate = clip.playbackRate.clamp(0.25, 4);
    final neededMilliseconds = (clip.duration.inMilliseconds * rate).round();
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

  const TimelineRenderInput({
    required this.index,
    required this.trackIndex,
    required this.track,
    required this.clip,
    required this.asset,
    required this.sourcePath,
    required this.hasAudio,
    this.frameRate,
  });

  bool get isVisual {
    return clip.type == TimelineTrackType.video ||
        clip.type == TimelineTrackType.image ||
        clip.type == TimelineTrackType.gif ||
        clip.type == TimelineTrackType.sticker;
  }
}
