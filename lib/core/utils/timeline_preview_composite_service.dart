import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/editor/models/export_settings.dart';
import '../../features/editor/models/subtitle_entry.dart';
import '../../features/editor/models/subtitle_style_model.dart';
import '../../features/editor/models/timeline_models.dart';
import 'caption_font_service.dart';
import 'subtitle_export_service.dart';
import 'timeline_export_service.dart';

/// A conservative ceiling that remains reliable on mobile hardware decoders.
/// Denser projects are rendered to one low-resolution composite stream.
const int kMaximumLivePreviewVideoDecoders = 3;

class PreviewCompositePlan {
  final String fingerprint;
  final EditorTimeline timeline;
  final Duration timelineDuration;
  final List<TimelineRenderInput> inputs;
  final List<SubtitleEntry> subtitleEntries;
  final SubtitleStyleModel globalSubtitleStyle;
  final ExportCanvasSize canvasSize;
  final int maximumConcurrentDecoders;

  const PreviewCompositePlan({
    required this.fingerprint,
    required this.timeline,
    required this.timelineDuration,
    required this.inputs,
    required this.subtitleEntries,
    required this.globalSubtitleStyle,
    required this.canvasSize,
    required this.maximumConcurrentDecoders,
  });
}

class PreviewCompositeResult {
  final String fingerprint;
  final String outputPath;
  final int inputCount;
  final int maximumConcurrentDecoders;
  final ExportCanvasSize canvasSize;

  const PreviewCompositeResult({
    required this.fingerprint,
    required this.outputPath,
    required this.inputCount,
    required this.maximumConcurrentDecoders,
    required this.canvasSize,
  });
}

class PreviewCompositeRenderCancelled implements Exception {
  const PreviewCompositeRenderCancelled();

  @override
  String toString() => 'Optimized preview rendering was paused for playback.';
}

/// Renders decoder-dense timelines into a cached, silent 480p proxy.
///
/// The original timeline remains authoritative and final export is unchanged.
/// This cache only replaces a collection of simultaneous preview decoders with
/// one H.264 stream after the overlap exceeds the safe live decoder budget.
class TimelinePreviewCompositeService {
  TimelinePreviewCompositeService._();

  static const _previewSettings = ExportSettings(
    resolution: ExportResolution.p480,
    frameRate: ExportFrameRate.fps30,
    quality: ExportQuality.compact,
    includeAudio: false,
    burnSubtitles: true,
    saveToGallery: false,
  );

  static Future<void> _renderTail = Future<void>.value();
  static final Map<String, int> _activeSessionIds = <String, int>{};
  static final Set<String> _cancelledFingerprints = <String>{};

  static int maximumConcurrentVisualDecoders(EditorTimeline timeline) {
    final events = <({int timeUs, int delta})>[];
    for (final track in timeline.tracks) {
      if (!track.isVisualLayer || track.isHidden) continue;
      for (final clip in track.clips) {
        if (!clip.enabled ||
            clip.endTime <= clip.startTime ||
            !track.acceptsClip(clip)) {
          continue;
        }
        final asset = timeline.assetForClip(clip);
        if (!_usesContinuousDecoder(clip, asset)) continue;
        events
          ..add((timeUs: clip.startTime.inMicroseconds, delta: 1))
          ..add((timeUs: clip.endTime.inMicroseconds, delta: -1));
      }
    }
    return _maximumConcurrentEvents(events);
  }

  static int activeVisualDecoderCount(
    EditorTimeline timeline,
    Duration position,
  ) {
    var count = 0;
    for (final track in timeline.tracks) {
      if (!track.isVisualLayer || track.isHidden) continue;
      for (final clip in track.clips) {
        if (!clip.enabled ||
            position < clip.startTime ||
            position >= clip.endTime ||
            !track.acceptsClip(clip)) {
          continue;
        }
        if (_usesContinuousDecoder(clip, timeline.assetForClip(clip))) count++;
      }
    }
    return count;
  }

  static bool clipUsesContinuousDecoder(
    EditorTimeline timeline,
    TimelineClip clip,
  ) {
    return _usesContinuousDecoder(clip, timeline.assetForClip(clip));
  }

  static PreviewCompositePlan? buildPlan({
    required EditorTimeline timeline,
    required List<SubtitleEntry> subtitleEntries,
    required SubtitleStyleModel globalSubtitleStyle,
    String legacyVideoPath = '',
    bool Function(String path)? fileExists,
    String Function(String path)? sourceVersion,
  }) {
    final maximumConcurrentDecoders = maximumConcurrentVisualDecoders(timeline);
    if (maximumConcurrentDecoders <= kMaximumLivePreviewVideoDecoders ||
        timeline.duration <= Duration.zero) {
      return null;
    }

    final exists = fileExists ?? (path) => File(path).existsSync();
    final version = sourceVersion ?? _sourceVersion;
    final selected =
        <
          ({
            int trackIndex,
            TimelineTrack track,
            TimelineClip clip,
            EditorAssetReference? asset,
            String sourcePath,
          })
        >[];
    for (
      var trackIndex = 0;
      trackIndex < timeline.tracks.length;
      trackIndex++
    ) {
      final track = timeline.tracks[trackIndex];
      if (!track.isVisualLayer || track.isHidden) continue;
      for (final clip in track.clips) {
        if (!clip.enabled ||
            clip.endTime <= clip.startTime ||
            !clip.type.isVisualMedia ||
            !track.acceptsClip(clip)) {
          continue;
        }
        final asset = timeline.assetForClip(clip);
        final assetPath = asset?.sourcePath?.trim();
        final sourcePath = assetPath != null && assetPath.isNotEmpty
            ? assetPath
            : clip.assetId == null &&
                  clip.type == TimelineTrackType.video &&
                  legacyVideoPath.trim().isNotEmpty
            ? legacyVideoPath.trim()
            : null;
        // A partial composite can silently hide a layer. Keep the bounded live
        // fallback instead unless every visible source is locally renderable.
        if (sourcePath == null || !exists(sourcePath)) return null;
        selected.add((
          trackIndex: trackIndex,
          track: track,
          clip: clip,
          asset: asset,
          sourcePath: sourcePath,
        ));
      }
    }
    if (selected.isEmpty) return null;

    selected.sort((a, b) {
      final trackComparison = a.trackIndex.compareTo(b.trackIndex);
      if (trackComparison != 0) return trackComparison;
      final startComparison = a.clip.startTime.compareTo(b.clip.startTime);
      return startComparison != 0
          ? startComparison
          : a.clip.id.compareTo(b.clip.id);
    });
    final inputs = <TimelineRenderInput>[
      for (var index = 0; index < selected.length; index++)
        TimelineRenderInput(
          index: index,
          trackIndex: selected[index].trackIndex,
          track: selected[index].track,
          clip: selected[index].clip,
          asset: selected[index].asset,
          sourcePath: selected[index].sourcePath,
          hasAudio: false,
          frameRate: _metadataNumber(
            selected[index].asset?.metadata['frameRate'],
          ),
        ),
    ];
    final canvasReference = inputs.firstWhere(
      (input) => input.track.section == TimelineTrackSection.baseVideo,
      orElse: () => inputs.first,
    );
    final canvasSize = _previewCanvasSize(timeline, canvasReference);
    final sourceVersions = <String, String>{};
    final fingerprintPayload = <String, Object?>{
      'durationUs': timeline.duration.inMicroseconds,
      'canvas': {
        'width': canvasSize.width,
        'height': canvasSize.height,
        'fps': canvasSize.framesPerSecond,
        'background': timeline.canvasSettings.backgroundColor.toARGB32(),
      },
      'tracks': [
        for (final track in timeline.tracks)
          if ((track.isVisualLayer ||
                  track.type == TimelineTrackType.text ||
                  track.type == TimelineTrackType.subtitle ||
                  track.type == TimelineTrackType.effect) &&
              !track.isHidden)
            {
              'id': track.id,
              'type': track.type.name,
              'section': track.section.name,
              'clips': [
                for (final clip in track.clips)
                  if (clip.enabled && clip.endTime > clip.startTime)
                    _visualClipFingerprint(clip),
              ],
            },
      ],
      'sources': [
        for (final input in inputs)
          {
            'clipId': input.clip.id,
            'path': input.sourcePath,
            'version': sourceVersions.putIfAbsent(
              input.sourcePath,
              () => version(input.sourcePath),
            ),
            'assetType': input.asset?.type.name,
            'width': input.asset?.metadata['width'],
            'height': input.asset?.metadata['height'],
            'frameRate': input.asset?.metadata['frameRate'],
          },
      ],
      'subtitles': [for (final entry in subtitleEntries) entry.toJson()],
      'subtitleStyle': globalSubtitleStyle.toJson(),
    };
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode(fingerprintPayload)))
        .toString();
    return PreviewCompositePlan(
      fingerprint: fingerprint,
      timeline: timeline,
      timelineDuration: timeline.duration,
      inputs: List.unmodifiable(inputs),
      subtitleEntries: List.unmodifiable(subtitleEntries),
      globalSubtitleStyle: globalSubtitleStyle,
      canvasSize: canvasSize,
      maximumConcurrentDecoders: maximumConcurrentDecoders,
    );
  }

  static Future<PreviewCompositeResult> ensureRendered(
    PreviewCompositePlan plan,
  ) {
    final operation = _renderTail.then((_) => _render(plan));
    _renderTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  /// Stops background proxy work so interactive playback keeps CPU priority.
  static Future<void> cancel(String fingerprint) async {
    _cancelledFingerprints.add(fingerprint);
    final sessionId = _activeSessionIds[fingerprint];
    if (sessionId != null) await FFmpegKit.cancel(sessionId);
  }

  static Future<PreviewCompositeResult> _render(
    PreviewCompositePlan plan,
  ) async {
    final temporaryDirectory = await getTemporaryDirectory();
    final outputPath = p.join(
      temporaryDirectory.path,
      'caption_craft_preview_composite_${plan.fingerprint}.mp4',
    );
    final output = File(outputPath);
    if (await output.exists() && await output.length() > 0) {
      _cancelledFingerprints.remove(plan.fingerprint);
      return _result(plan, outputPath);
    }
    if (_cancelledFingerprints.remove(plan.fingerprint)) {
      throw const PreviewCompositeRenderCancelled();
    }

    final partialPath = p.join(
      temporaryDirectory.path,
      'caption_craft_preview_composite_${plan.fingerprint}_'
      '${DateTime.now().microsecondsSinceEpoch}.partial.mp4',
    );
    final partial = File(partialPath);
    String? assPath;
    try {
      assPath = await TimelineExportService.buildAssTrack(
        timeline: plan.timeline,
        subtitleEntries: plan.subtitleEntries,
        globalSubtitleStyle: plan.globalSubtitleStyle,
        settings: _previewSettings,
        canvasSize: plan.canvasSize,
      );
      String? fontDirectory;
      if (assPath != null) {
        await SubtitleExportService.preflightAssFile(assPath);
        fontDirectory =
            (await CaptionFontService.prepareForExport()).directoryPath;
      }
      final arguments = TimelineExportService.buildFfmpegArguments(
        timeline: plan.timeline,
        inputs: plan.inputs,
        settings: _previewSettings,
        canvasSize: plan.canvasSize,
        timelineDuration: plan.timelineDuration,
        assPath: assPath,
        captionFontDirectory: fontDirectory,
        videoPreset: 'ultrafast',
        videoCrf: 30,
        outputPath: partialPath,
      );
      final completion =
          Completer<({bool success, bool cancelled, String logs})>();
      final session = await FFmpegKit.executeWithArgumentsAsync(arguments, (
        completedSession,
      ) {
        unawaited(() async {
          final returnCode = await completedSession.getReturnCode();
          final logs = await completedSession.getAllLogsAsString() ?? '';
          if (!completion.isCompleted) {
            completion.complete((
              success: ReturnCode.isSuccess(returnCode),
              cancelled: ReturnCode.isCancel(returnCode),
              logs: logs,
            ));
          }
        }());
      });
      final sessionId = session.getSessionId();
      if (sessionId != null) {
        _activeSessionIds[plan.fingerprint] = sessionId;
        if (_cancelledFingerprints.contains(plan.fingerprint)) {
          await FFmpegKit.cancel(sessionId);
        }
      }
      final completed = await completion.future;
      _activeSessionIds.remove(plan.fingerprint);
      final wasCancelled =
          completed.cancelled ||
          _cancelledFingerprints.remove(plan.fingerprint);
      if (wasCancelled) throw const PreviewCompositeRenderCancelled();
      if (!completed.success ||
          !await partial.exists() ||
          await partial.length() == 0) {
        throw StateError(
          completed.logs.trim().isEmpty
              ? 'Could not render the optimized preview.'
              : 'Could not render the optimized preview: '
                    '${_lastLogLines(completed.logs)}',
        );
      }
      if (await output.exists()) await output.delete();
      await partial.rename(outputPath);
      return _result(plan, outputPath);
    } finally {
      _activeSessionIds.remove(plan.fingerprint);
      _cancelledFingerprints.remove(plan.fingerprint);
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {
          // A failed FFmpeg session can retain its output briefly.
        }
      }
      if (assPath != null) {
        try {
          final assFile = File(assPath);
          if (await assFile.exists()) await assFile.delete();
        } catch (_) {
          // The rendered cache is valid even if temporary ASS cleanup waits.
        }
      }
    }
  }

  static PreviewCompositeResult _result(
    PreviewCompositePlan plan,
    String outputPath,
  ) {
    return PreviewCompositeResult(
      fingerprint: plan.fingerprint,
      outputPath: outputPath,
      inputCount: plan.inputs.length,
      maximumConcurrentDecoders: plan.maximumConcurrentDecoders,
      canvasSize: plan.canvasSize,
    );
  }

  static ExportCanvasSize _previewCanvasSize(
    EditorTimeline timeline,
    TimelineRenderInput firstInput,
  ) {
    final metadata = firstInput.asset?.metadata ?? const <String, dynamic>{};
    var sourceWidth = _metadataNumber(metadata['width'])?.round() ?? 1920;
    var sourceHeight = _metadataNumber(metadata['height'])?.round() ?? 1080;
    final canvas = timeline.canvasSettings;
    final hasCustomCanvas =
        canvas.customWidth != null &&
        canvas.customHeight != null &&
        canvas.customWidth! > 0 &&
        canvas.customHeight! > 0;
    if (hasCustomCanvas) {
      final customAspect = canvas.customWidth! / canvas.customHeight!;
      if (customAspect >= 1) {
        sourceHeight = 1080;
        sourceWidth = (sourceHeight * customAspect).round();
      } else {
        sourceWidth = 1080;
        sourceHeight = (sourceWidth / customAspect).round();
      }
    }
    final boundedCanvas = CanvasSettings(
      aspectRatioPreset: hasCustomCanvas
          ? CanvasAspectRatioPreset.original
          : canvas.aspectRatioPreset,
      backgroundColor: canvas.backgroundColor,
      showSafeAreas: false,
      showGrid: false,
      snapToGuides: false,
    );
    return TimelineExportService.resolveCanvasSize(
      boundedCanvas,
      _previewSettings,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      sourceFrameRate: _metadataNumber(metadata['frameRate']) ?? 30,
    );
  }

  static Map<String, Object?> _visualClipFingerprint(TimelineClip clip) {
    final payload = Map<String, dynamic>.from(clip.toJson())
      ..remove('audioMix')
      ..remove('autoDuck')
      ..remove('duckAmount');
    payload['keyframes'] = [
      for (final keyframe in clip.keyframes)
        if (keyframe.property != TimelineKeyframeProperty.volume)
          keyframe.toJson(),
    ];
    return payload;
  }

  static bool _usesContinuousDecoder(
    TimelineClip clip,
    EditorAssetReference? asset,
  ) {
    if (clip.type == TimelineTrackType.video ||
        clip.type == TimelineTrackType.gif ||
        asset?.type == EditorAssetType.video ||
        asset?.type == EditorAssetType.gif) {
      return true;
    }
    if (clip.type != TimelineTrackType.sticker &&
        asset?.type != EditorAssetType.sticker) {
      return false;
    }
    final source = asset?.sourcePath ?? asset?.remoteUrl;
    if (source == null || source.isEmpty) return false;
    final path = Uri.tryParse(source)?.path ?? source;
    return path.toLowerCase().endsWith('.gif');
  }

  static int _maximumConcurrentEvents(List<({int timeUs, int delta})> events) {
    events.sort((a, b) {
      final timeComparison = a.timeUs.compareTo(b.timeUs);
      return timeComparison != 0 ? timeComparison : a.delta.compareTo(b.delta);
    });
    var active = 0;
    var maximum = 0;
    for (final event in events) {
      active = math.max(0, active + event.delta);
      maximum = math.max(maximum, active);
    }
    return maximum;
  }

  static double? _metadataNumber(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static String _sourceVersion(String path) {
    try {
      final stat = File(path).statSync();
      return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    } catch (_) {
      return 'unavailable';
    }
  }

  static String _lastLogLines(String logs) {
    final lines = logs
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return lines.skip(math.max(0, lines.length - 5)).join(' | ');
  }
}
