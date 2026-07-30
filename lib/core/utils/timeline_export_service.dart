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
    final baseClips = _visibleBaseClips(timeline);
    if (baseClips.isEmpty) {
      throw Exception('The timeline has no visible base video clips.');
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
        final sourceKey =
            clip.assetId ??
            (clip.type == TimelineTrackType.video
                ? 'project-video:${project.videoPath}'
                : 'clip:${clip.id}');
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

      final firstSourcePath = await resolveSourcePath(baseClips.first.$2);
      final firstMediaInfo = await probeMedia(firstSourcePath);
      final canvasSize = resolveCanvasSize(
        timeline.canvasSettings,
        settings,
        sourceWidth: (firstMediaInfo['width'] as int?) ?? 1920,
        sourceHeight: (firstMediaInfo['height'] as int?) ?? 1080,
        sourceFrameRate: (firstMediaInfo['frameRate'] as double?) ?? 30,
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
            ),
          );
        }
      }

      if (renderInputs
          .where(
            (input) =>
                input.track.section == TimelineTrackSection.baseVideo &&
                input.isVisual,
          )
          .isEmpty) {
        throw Exception('No readable base video clips were found.');
      }

      onProgress?.call(0.08);
      assPath = await _buildAssTrack(
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
    required String outputPath,
  }) {
    final args = <String>['-hide_banner', '-y'];
    for (final input in inputs) {
      args.addAll(_inputArguments(input));
    }

    final filterGraph = _buildFilterGraph(
      timeline: timeline,
      inputs: inputs,
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
      settings.preset,
      '-crf',
      '${settings.crf}',
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
      final rawExtension = uri == null ? '' : p.extension(uri.path);
      final extension = rawExtension.isEmpty ? '.media' : rawExtension;
      final safeAssetId = asset!.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final outputPath = p.join(
        workingDirectory.path,
        'network_${safeAssetId.isEmpty ? 'asset' : safeAssetId}$extension',
      );
      final cachedDownload = File(outputPath);
      if (await cachedDownload.exists() && await cachedDownload.length() > 0) {
        return outputPath;
      }
      try {
        await Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 25),
            receiveTimeout: const Duration(minutes: 5),
          ),
        ).download(remoteUrl, outputPath, cancelToken: downloadCancelToken);
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) {
          throw Exception('Export cancelled.');
        }
        throw Exception(
          'Could not download ${asset.label}: '
          '${error.message ?? 'network error'}.',
        );
      }
      final outputFile = File(outputPath);
      if (!await outputFile.exists() || await outputFile.length() == 0) {
        throw Exception('Downloaded media is empty: ${asset.label}.');
      }
      return outputPath;
    }

    if (clip.type == TimelineTrackType.video &&
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
    final extension = p.extension(input.sourcePath).toLowerCase();
    final isAnimatedImage =
        input.asset?.type == EditorAssetType.gif ||
        (input.asset?.type == EditorAssetType.sticker && extension == '.gif');
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

  static String _buildFilterGraph({
    required EditorTimeline timeline,
    required List<TimelineRenderInput> inputs,
    required ExportSettings settings,
    required ExportCanvasSize canvasSize,
    required Duration timelineDuration,
    required String? assPath,
    required String? captionFontDirectory,
  }) {
    final filters = <String>[];
    final background = _ffmpegColor(timeline.canvasSettings.backgroundColor);
    final durationSeconds = _seconds(timelineDuration);
    filters.add(
      'color=c=$background:s=${canvasSize.width}x${canvasSize.height}:'
      'r=${canvasSize.framesPerSecond}:d=$durationSeconds[canvas0]',
    );

    final visualInputs = inputs.where((input) => input.isVisual).toList()
      ..sort((a, b) {
        final sectionCompare = _sectionLayer(
          a.track.section,
        ).compareTo(_sectionLayer(b.track.section));
        if (sectionCompare != 0) return sectionCompare;
        final trackCompare = a.trackIndex.compareTo(b.trackIndex);
        if (trackCompare != 0) return trackCompare;
        final layerCompare = a.clip.layer.compareTo(b.clip.layer);
        if (layerCompare != 0) return layerCompare;
        return a.clip.startTime.compareTo(b.clip.startTime);
      });

    var canvasIndex = 0;
    for (
      var visualIndex = 0;
      visualIndex < visualInputs.length;
      visualIndex++
    ) {
      final input = visualInputs[visualIndex];
      final clip = input.clip;
      final clipDuration = clip.duration;
      final isBase = input.track.section == TimelineTrackSection.baseVideo;
      final visualLabel = 'visual$visualIndex';
      final preparation = <String>[
        if (clip.isReversed &&
            (clip.type == TimelineTrackType.video ||
                clip.type == TimelineTrackType.gif))
          'reverse',
        'setpts=(PTS-STARTPTS)/${_number(clip.playbackRate)}',
        'trim=duration=${_seconds(clipDuration)}',
        ..._cropFilters(clip.crop),
        ..._colorFilters(clip.colorAdjustments),
        ..._fitFilters(clip, canvasSize: canvasSize, isBase: isBase),
        if (clip.transform.flipX) 'hflip',
        if (clip.transform.flipY) 'vflip',
        if (clip.transform.rotation.abs() > 0.0001)
          'rotate=${_number(clip.transform.rotation)}:'
              'ow=rotw(iw):oh=roth(ih):c=none',
        if (clip.transform.scale != 1)
          'scale=w=trunc(iw*${_number(clip.transform.scale)}/2)*2:'
              'h=trunc(ih*${_number(clip.transform.scale)}/2)*2',
      ];
      final needsAlpha =
          !isBase ||
          clip.transform.opacity < 0.999 ||
          clip.transform.rotation.abs() > 0.0001 ||
          _transitionUsesAlpha(clip.introTransition.type) ||
          _transitionUsesAlpha(clip.outroTransition.type);
      final finishing = <String>[
        if (needsAlpha) 'format=rgba',
        if (clip.transform.opacity < 0.999)
          'colorchannelmixer=aa=${_number(clip.transform.opacity.clamp(0, 1))}',
        ..._transitionAlphaFilters(clip),
        'setpts=PTS-STARTPTS+${_seconds(clip.startTime)}/TB',
      ];
      if (clip.blur.mode == ClipBlurMode.region && clip.blur.isEnabled) {
        final clean = 'clean$visualIndex';
        final blurredSource = 'blurSource$visualIndex';
        final blurredRegion = 'blurRegion$visualIndex';
        final effected = 'effected$visualIndex';
        final blur = clip.blur;
        filters.add(
          '[${input.index}:v]${preparation.join(',')},'
          'format=rgba,split=2[$clean][$blurredSource]',
        );
        filters.add(
          '[$blurredSource]'
          'crop=w=iw*${_number(blur.safeRegionWidth)}:'
          'h=ih*${_number(blur.safeRegionHeight)}:'
          'x=iw*${_number(blur.safeRegionX)}:'
          'y=ih*${_number(blur.safeRegionY)},'
          'gblur=sigma=${_number(blur.safeStrength)}'
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
          if (clip.blur.mode == ClipBlurMode.full && clip.blur.isEnabled)
            'gblur=sigma=${_number(clip.blur.safeStrength)}',
          ...finishing,
        ];
        filters.add('[${input.index}:v]${chain.join(',')}[$visualLabel]');
      }

      final nextCanvas = 'canvas${canvasIndex + 1}';
      final position = _overlayPosition(
        clip,
        canvasSize: canvasSize,
        isBase: isBase,
      );
      filters.add(
        '[canvas$canvasIndex][$visualLabel]'
        "overlay=x='${position.$1}':y='${position.$2}':"
        'eof_action=pass:shortest=0:format=auto[$nextCanvas]',
      );
      canvasIndex++;
    }

    var videoSource = 'canvas$canvasIndex';
    videoSource = _appendTimelineEffects(
      filters: filters,
      timeline: timeline,
      sourceLabel: videoSource,
    );
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

    final audioLabels = <String>[];
    if (settings.includeAudio) {
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
        final fadeInSeconds = math.min(
          mix.fadeInMs / 1000,
          clipDurationSeconds / 2,
        );
        final fadeOutSeconds = math.min(
          mix.fadeOutMs / 1000,
          clipDurationSeconds / 2,
        );
        final audioChain = <String>[
          if (clip.isReversed) 'areverse',
          'asetpts=PTS-STARTPTS',
          ..._atempoFilters(clip.playbackRate),
          'atrim=duration=${_seconds(clip.duration)}',
          'aformat=sample_rates=48000:channel_layouts=stereo',
          if (mix.normalize) 'loudnorm=I=-16:LRA=11:TP=-1.5',
          'volume=${_number(mix.volume.clamp(0, 2))}',
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
        'alimiter=limit=0.95,atrim=duration=$durationSeconds[aout]',
      );
    }

    return filters.join(';');
  }

  static String _appendTimelineEffects({
    required List<String> filters,
    required EditorTimeline timeline,
    required String sourceLabel,
  }) {
    final effectClips = <(int, TimelineClip)>[];
    for (final trackEntry in timeline.tracks.asMap().entries) {
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
    var appliedEffectIndex = 0;
    for (final effectEntry in effectClips) {
      final clip = effectEntry.$2;
      final enableExpression =
          'between(t,${_seconds(clip.startTime)},${_seconds(clip.endTime)})';
      final outputLabel = 'timelineEffect$appliedEffectIndex';

      switch (clip.effectKind!) {
        case TimelineEffectKind.blur:
          final blur = clip.blur;
          if (!blur.isEnabled) continue;
          if (blur.mode == ClipBlurMode.region) {
            final cleanLabel = 'effectClean$appliedEffectIndex';
            final blurSourceLabel = 'effectBlurSource$appliedEffectIndex';
            final blurredRegionLabel = 'effectBlurRegion$appliedEffectIndex';
            filters.add(
              '[$currentSource]split=2[$cleanLabel][$blurSourceLabel]',
            );
            filters.add(
              '[$blurSourceLabel]'
              'crop=w=iw*${_number(blur.safeRegionWidth)}:'
              'h=ih*${_number(blur.safeRegionHeight)}:'
              'x=iw*${_number(blur.safeRegionX)}:'
              'y=ih*${_number(blur.safeRegionY)},'
              "gblur=sigma=${_number(blur.safeStrength)}:"
              "enable='$enableExpression'"
              '[$blurredRegionLabel]',
            );
            filters.add(
              '[$cleanLabel][$blurredRegionLabel]'
              'overlay=x=main_w*${_number(blur.safeRegionX)}:'
              'y=main_h*${_number(blur.safeRegionY)}:'
              "enable='$enableExpression':"
              'eof_action=pass:shortest=0:format=auto'
              '[$outputLabel]',
            );
          } else {
            filters.add(
              '[$currentSource]'
              "gblur=sigma=${_number(blur.safeStrength)}:"
              "enable='$enableExpression'"
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
    return currentSource;
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

  static List<String> _transitionAlphaFilters(TimelineClip clip) {
    final filters = <String>[];
    final durationSeconds = clip.duration.inMilliseconds / 1000;
    final introSeconds = math.min(
      clip.introTransition.durationMs / 1000,
      durationSeconds / 2,
    );
    final outroSeconds = math.min(
      clip.outroTransition.durationMs / 1000,
      durationSeconds / 2,
    );
    if (_transitionUsesAlpha(clip.introTransition.type) && introSeconds > 0) {
      filters.add('fade=t=in:st=0:d=${_number(introSeconds)}:alpha=1');
    }
    if (_transitionUsesAlpha(clip.outroTransition.type) && outroSeconds > 0) {
      filters.add(
        'fade=t=out:st=${_number(math.max(0, durationSeconds - outroSeconds))}:'
        'd=${_number(outroSeconds)}:alpha=1',
      );
    }
    return filters;
  }

  static bool _transitionUsesAlpha(TransitionType type) {
    return type != TransitionType.none && type != TransitionType.cut;
  }

  static (String, String) _overlayPosition(
    TimelineClip clip, {
    required ExportCanvasSize canvasSize,
    required bool isBase,
  }) {
    const referenceWidth = kTimelineDesignWidth;
    const referenceHeight = kTimelineDesignHeight;
    final offsetX = clip.transform.offsetX * canvasSize.width / referenceWidth;
    final offsetY =
        clip.transform.offsetY * canvasSize.height / referenceHeight;
    final baseX = '(W-w)/2+${_number(offsetX)}';
    final baseY = '(H-h)/2+${_number(offsetY)}';

    final intro = clip.introTransition;
    final outro = clip.outroTransition;
    final start = clip.startTime.inMilliseconds / 1000;
    final end = clip.endTime.inMilliseconds / 1000;
    final introDuration = intro.durationMs / 1000;
    final outroDuration = outro.durationMs / 1000;

    String x = baseX;
    String y = baseY;
    if (introDuration > 0) {
      final progress =
          'min(max((t-${_number(start)})/${_number(introDuration)},0),1)';
      if (intro.type == TransitionType.slideLeft) {
        x = '$baseX-W*(1-$progress)';
      } else if (intro.type == TransitionType.slideRight) {
        x = '$baseX+W*(1-$progress)';
      } else if (intro.type == TransitionType.slideUp) {
        y = '$baseY-H*(1-$progress)';
      } else if (intro.type == TransitionType.slideDown) {
        y = '$baseY+H*(1-$progress)';
      }
    }
    if (outroDuration > 0) {
      final hidden =
          'min(max((t-${_number(end - outroDuration)})/'
          '${_number(outroDuration)},0),1)';
      if (outro.type == TransitionType.slideLeft) {
        x = '($x)-W*$hidden';
      } else if (outro.type == TransitionType.slideRight) {
        x = '($x)+W*$hidden';
      } else if (outro.type == TransitionType.slideUp) {
        y = '($y)-H*$hidden';
      } else if (outro.type == TransitionType.slideDown) {
        y = '($y)+H*$hidden';
      }
    }

    if (isBase && clip.fitMode == ClipFitMode.contain) {
      return (x, y);
    }
    return (x, y);
  }

  static Future<String?> _buildAssTrack({
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

  static int _sectionLayer(TimelineTrackSection section) {
    switch (section) {
      case TimelineTrackSection.baseVideo:
        return 0;
      case TimelineTrackSection.overlay:
        return 1;
      case TimelineTrackSection.textSubtitle:
        return 2;
      case TimelineTrackSection.audio:
        return 3;
    }
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

  const TimelineRenderInput({
    required this.index,
    required this.trackIndex,
    required this.track,
    required this.clip,
    required this.asset,
    required this.sourcePath,
    required this.hasAudio,
  });

  bool get isVisual {
    return clip.type == TimelineTrackType.video ||
        clip.type == TimelineTrackType.image ||
        clip.type == TimelineTrackType.gif ||
        clip.type == TimelineTrackType.sticker;
  }
}
