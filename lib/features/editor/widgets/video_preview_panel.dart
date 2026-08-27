import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/subtitle_export_service.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../models/timeline_models.dart';
import '../providers/editor_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/subtitle_provider.dart';
import '../widgets/animated_subtitle_overlay.dart';
import '../widgets/preview_performance_monitor.dart';
import '../widgets/preview_playback_clock.dart';

double _previewAudioVolume({
  required TimelineClip clip,
  required Duration position,
  required bool isTrackAudible,
  double duckingGain = 1,
}) {
  final mix = clip.audioMix;
  if (!isTrackAudible || mix.muted) return 0;

  // Loudness normalization needs analysis of the complete source and remains
  // an export-time operation. Preview only the deterministic mix envelope.
  var volume = clip.volumeAt(position).clamp(0.0, 1.0).toDouble();
  if (clip.autoDuck) volume *= duckingGain.clamp(0.0, 1.0);

  final durationMs = math.max(0, clip.duration.inMilliseconds);
  final fadeInMs = clip.effectiveAudioFadeInMs;
  final fadeOutMs = clip.effectiveAudioFadeOutMs;
  final elapsedMs = (position - clip.startTime).inMilliseconds.clamp(
    0,
    durationMs,
  );
  final remainingMs = (clip.endTime - position).inMilliseconds.clamp(
    0,
    durationMs,
  );
  if (fadeInMs > 0) {
    volume *= (elapsedMs / fadeInMs).clamp(0.0, 1.0);
  }
  if (fadeOutMs > 0) {
    volume *= (remainingMs / fadeOutMs).clamp(0.0, 1.0);
  }
  return volume.clamp(0.0, 1.0).toDouble();
}

Widget _cropSourcePreview({
  required Widget child,
  required double sourceWidth,
  required double sourceHeight,
  required ClipCropSettings crop,
}) {
  if (crop.isIdentity) return child;
  return SizedBox(
    width: sourceWidth * crop.visibleWidth,
    height: sourceHeight * crop.visibleHeight,
    child: ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: sourceWidth,
        maxWidth: sourceWidth,
        minHeight: sourceHeight,
        maxHeight: sourceHeight,
        child: Transform.translate(
          offset: Offset(
            -sourceWidth * crop.safeLeft,
            -sourceHeight * crop.safeTop,
          ),
          child: child,
        ),
      ),
    ),
  );
}

bool _isGifSource(String? value) {
  if (value == null || value.trim().isEmpty) return false;
  final path = Uri.tryParse(value)?.path ?? value;
  return path.toLowerCase().endsWith('.gif');
}

/// Every preview decoder participates in one editor mix. Without this option,
/// platform players can take exclusive audio focus from one another as soon as
/// a second video or separated-audio controller starts.
VideoPlayerOptions buildPreviewVideoPlayerOptions() {
  return VideoPlayerOptions(mixWithOthers: true);
}

const int _maxPreviewDecodeDimension = 2048;
const int _maxGifDecodeDimension = 1280;
const int _maxGifDecodedBytes = 24 * 1024 * 1024;
const int _maxGifEncodedBytes = 32 * 1024 * 1024;
const double _gifDecodeSizeQuantum = 32;
const Duration _gifResizeDecodeDebounce = Duration(milliseconds: 120);
const Duration _audioPreviewPreloadWindow = Duration(seconds: 2);
const int _maxUpcomingAudioPreviewControllers = 3;
const Duration _baseVideoPreloadWindow = Duration(milliseconds: 3500);

typedef PreviewDuckingInterval = ({int startMs, int endMs});

/// Returns the first index whose clip starts strictly after [position].
///
/// Preview lanes are normalized so clips do not overlap. Keeping their starts
/// sorted lets the 30 Hz playback path resolve the active clip in O(log n)
/// instead of walking every clip in a long project on every tick.
@visibleForTesting
int previewClipStartUpperBoundForTesting(
  List<TimelineClip> sortedClips,
  Duration position,
) {
  var lower = 0;
  var upper = sortedClips.length;
  while (lower < upper) {
    final middle = lower + ((upper - lower) >> 1);
    if (sortedClips[middle].startTime <= position) {
      lower = middle + 1;
    } else {
      upper = middle;
    }
  }
  return lower;
}

/// Resolves one active clip from a sorted, non-overlapping preview lane.
@visibleForTesting
TimelineClip? resolveIndexedPreviewClipForTesting({
  required List<TimelineClip> sortedClips,
  required Duration position,
  bool includeEnd = false,
}) {
  final index = previewClipStartUpperBoundForTesting(sortedClips, position) - 1;
  if (index < 0) return null;
  final clip = sortedClips[index];
  final inside = position >= clip.startTime && position < clip.endTime;
  final onIncludedEnd =
      includeEnd && position == clip.endTime && position >= clip.startTime;
  return inside || onIncludedEnd ? clip : null;
}

/// Returns only future clips whose starts fall inside a bounded warm window.
@visibleForTesting
List<TimelineClip> indexedPreviewClipsStartingInWindowForTesting({
  required List<TimelineClip> sortedClips,
  required Duration position,
  required Duration window,
}) {
  final safeWindow = window < Duration.zero ? Duration.zero : window;
  final maximumStart = position + safeWindow;
  final first = previewClipStartUpperBoundForTesting(sortedClips, position);
  final result = <TimelineClip>[];
  for (var index = first; index < sortedClips.length; index++) {
    final clip = sortedClips[index];
    if (clip.startTime > maximumStart) break;
    result.add(clip);
  }
  return result;
}

@visibleForTesting
List<SubtitleEntry> resolveIndexedPreviewSubtitlesForTesting({
  required List<SubtitleEntry> entries,
  required Duration position,
}) {
  return _PreviewCaptionIndex(entries).activeAt(position);
}

@visibleForTesting
bool previewHasSoloMediaTrackForTesting(EditorTimeline timeline) {
  return timeline.tracks.any(
    (track) =>
        track.isSolo &&
        (!track.isHidden || track.section == TimelineTrackSection.audio) &&
        track.clips.any(
          (candidate) =>
              candidate.enabled &&
              candidate.endTime > candidate.startTime &&
              candidate.type != TimelineTrackType.text &&
              candidate.type != TimelineTrackType.subtitle &&
              candidate.type != TimelineTrackType.effect,
        ),
  );
}

@visibleForTesting
bool shouldCreateTimelineAudioPreviewForTesting({
  required TimelineTrack track,
  required TimelineClip clip,
  required bool hasSoloMediaTrack,
  String? baseMonitoredClipId,
}) {
  if (!clip.enabled || clip.audioMix.muted) return false;
  if (track.isMuted || (hasSoloMediaTrack && !track.isSolo)) return false;
  return clip.id != baseMonitoredClipId;
}

/// Keeps a small, bounded set of upcoming audio decoders warm. Initializing a
/// player at the exact clip boundary is too late on long or decoder-heavy
/// projects and creates an audible gap before the first buffer is ready.
@visibleForTesting
bool shouldPreloadTimelineAudioPreviewForTesting({
  required TimelineClip clip,
  required Duration position,
  Duration preloadWindow = _audioPreviewPreloadWindow,
}) {
  if (clip.endTime <= position) return false;
  final safeWindow = preloadWindow < Duration.zero
      ? Duration.zero
      : preloadWindow;
  return clip.startTime <= position + safeWindow;
}

@visibleForTesting
bool shouldPreloadBaseVideoForTesting({
  required TimelineClip clip,
  required Duration position,
  Duration preloadWindow = _baseVideoPreloadWindow,
}) {
  if (!clip.enabled || clip.type != TimelineTrackType.video) return false;
  if (clip.startTime <= position) return false;
  final safeWindow = preloadWindow < Duration.zero
      ? Duration.zero
      : preloadWindow;
  return clip.startTime <= position + safeWindow;
}

@visibleForTesting
({TimelineTrack track, TimelineClip clip})?
resolvePreviewLinkedAudioMonitorForTesting({
  required EditorTimeline timeline,
  required TimelineClip visualClip,
  required Duration position,
}) {
  if (visualClip.type != TimelineTrackType.video) {
    return null;
  }
  for (final track in timeline.tracks) {
    if (track.section != TimelineTrackSection.audio) {
      continue;
    }
    for (final candidate in track.clips) {
      final timingMatches =
          candidate.startTime == visualClip.startTime &&
          candidate.endTime == visualClip.endTime &&
          candidate.sourceStartTime == visualClip.sourceStartTime &&
          candidate.sourceDuration == visualClip.sourceDuration &&
          (candidate.playbackRate - visualClip.playbackRate).abs() < 0.0001;
      if (candidate.enabled &&
          candidate.type == TimelineTrackType.audio &&
          candidate.linkedClipId == visualClip.id &&
          candidate.assetId != null &&
          candidate.assetId == visualClip.assetId &&
          !candidate.isReversed &&
          !candidate.freezeFrame &&
          timingMatches &&
          position >= candidate.startTime &&
          position < candidate.endTime) {
        return (track: track, clip: candidate);
      }
    }
  }
  return null;
}

@visibleForTesting
({TimelineTrack track, TimelineClip clip})?
resolvePreviewBaseAudioMonitorForTesting({
  required EditorTimeline timeline,
  required TimelineClip baseClip,
  required Duration position,
}) {
  if (baseClip.isReversed || baseClip.freezeFrame) return null;
  return resolvePreviewLinkedAudioMonitorForTesting(
    timeline: timeline,
    visualClip: baseClip,
    position: position,
  );
}

@visibleForTesting
bool previewHasExplicitLinkedAudioForTesting({
  required EditorTimeline timeline,
  required TimelineClip visualClip,
}) {
  if (visualClip.type != TimelineTrackType.video) return false;
  return timeline.tracks.any(
    (track) =>
        track.section == TimelineTrackSection.audio &&
        track.clips.any(
          (candidate) =>
              candidate.type == TimelineTrackType.audio &&
              candidate.linkedClipId == visualClip.id &&
              candidate.assetId != null &&
              candidate.assetId == visualClip.assetId,
        ),
  );
}

/// Whether a visual video controller should emit its own embedded audio.
///
/// Embedded audio belongs to the visual clip by default. An explicit linked
/// audio clip transfers ownership to that audio lane, so preview never
/// doubles the same stream through two platform controllers.
@visibleForTesting
bool previewVisualUsesEmbeddedAudioForTesting({
  required EditorTimeline timeline,
  required TimelineTrack visualTrack,
  required TimelineClip visualClip,
  required Duration position,
  required bool hasSoloMediaTrack,
}) {
  if (!visualClip.enabled ||
      visualClip.type != TimelineTrackType.video ||
      visualClip.audioMix.muted ||
      visualTrack.isMuted ||
      (hasSoloMediaTrack && !visualTrack.isSolo) ||
      !timeline.clipHasAudio(visualClip)) {
    return false;
  }
  return !previewHasExplicitLinkedAudioForTesting(
    timeline: timeline,
    visualClip: visualClip,
  );
}

@visibleForTesting
List<PreviewDuckingInterval> buildPreviewDuckingIntervalsForTesting({
  required EditorTimeline timeline,
  required TimelineClip clip,
}) {
  final clipStartMs = clip.startTime.inMilliseconds;
  final clipEndMs = clip.endTime.inMilliseconds;
  final intervals = <PreviewDuckingInterval>[];

  void addInterval(Duration start, Duration end) {
    final startMs = math.max(clipStartMs, start.inMilliseconds);
    final endMs = math.min(clipEndMs, end.inMilliseconds);
    if (endMs > startMs) intervals.add((startMs: startMs, endMs: endMs));
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

  final hasSoloTrack = previewHasSoloMediaTrackForTesting(timeline);
  for (final track in timeline.tracks) {
    if (track.isMuted ||
        (hasSoloTrack && !track.isSolo) ||
        (track.isHidden && track.section != TimelineTrackSection.audio)) {
      continue;
    }
    for (final candidate in track.clips) {
      if (!candidate.enabled ||
          candidate.id == clip.id ||
          candidate.audioMix.muted ||
          candidate.endTime <= candidate.startTime ||
          !timeline.clipHasAudio(candidate)) {
        continue;
      }
      addInterval(candidate.startTime, candidate.endTime);
    }
  }

  if (intervals.isEmpty) return const [];
  intervals.sort((a, b) => a.startMs.compareTo(b.startMs));
  final merged = <PreviewDuckingInterval>[];
  for (final interval in intervals) {
    if (merged.isEmpty || interval.startMs > merged.last.endMs + 300) {
      merged.add(interval);
    } else {
      final previous = merged.removeLast();
      merged.add((
        startMs: previous.startMs,
        endMs: math.max(previous.endMs, interval.endMs),
      ));
    }
  }
  return List.unmodifiable(merged);
}

@visibleForTesting
Size quantizeGifPreviewSizeForTesting(double width, double height) {
  double quantize(double value) {
    if (!value.isFinite || value <= 0) return 1;
    return math.max(
      1,
      (value / _gifDecodeSizeQuantum).ceil() * _gifDecodeSizeQuantum,
    );
  }

  return Size(quantize(width), quantize(height));
}

bool _clipHasFlutterDrivenMotionAt(TimelineClip clip, Duration position) {
  bool transitionAnimates(ClipTransition transition) =>
      transition.type != TransitionType.none &&
      transition.type != TransitionType.cut;
  final elapsedMs = (position - clip.startTime).inMilliseconds;
  final remainingMs = (clip.endTime - position).inMilliseconds;
  if ((transitionAnimates(clip.introTransition) &&
          elapsedMs >= 0 &&
          elapsedMs < clip.effectiveIntroTransitionMs) ||
      (transitionAnimates(clip.outroTransition) &&
          remainingMs >= 0 &&
          remainingMs < clip.effectiveOutroTransitionMs)) {
    return true;
  }

  final relativeMs = elapsedMs;
  for (final property in TimelineKeyframeProperty.values) {
    if (property == TimelineKeyframeProperty.volume) continue;
    final frames =
        clip.keyframes
            .where((keyframe) => keyframe.property == property)
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    for (var index = 1; index < frames.length; index++) {
      final previous = frames[index - 1];
      final next = frames[index];
      if (relativeMs >= previous.time.inMilliseconds &&
          relativeMs < next.time.inMilliseconds &&
          (previous.value - next.value).abs() > 0.0001) {
        return true;
      }
    }
  }
  return false;
}

@visibleForTesting
int calculatePreviewDecodeDimensionForTesting({
  required double logicalExtent,
  required double devicePixelRatio,
}) {
  if (!logicalExtent.isFinite || logicalExtent <= 0) return 1;
  final ratio = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1.0;
  return (logicalExtent * ratio).ceil().clamp(1, _maxPreviewDecodeDimension);
}

@visibleForTesting
String? resolvePreviewSourcePathForTesting({
  required EditorTimeline timeline,
  required TimelineClip clip,
  required String legacyVideoPath,
  required bool Function(String path) fileExists,
}) {
  final asset = timeline.assetForClip(clip);
  final sourcePath = asset?.sourcePath;
  if (sourcePath != null && sourcePath.isNotEmpty && fileExists(sourcePath)) {
    return sourcePath;
  }

  // Canonical projects link every media clip to an asset. Falling back to the
  // project's first video for a referenced-but-missing asset silently previews
  // the wrong clip in multi-source projects. Keep the fallback only for truly
  // legacy, unlinked clips.
  if (clip.assetId == null &&
      legacyVideoPath.isNotEmpty &&
      fileExists(legacyVideoPath)) {
    return legacyVideoPath;
  }
  return null;
}

@visibleForTesting
({Duration start, Duration end}) resolvePreviewPlaybackRangeForTesting({
  required Duration timelineDuration,
  required TimelineWorkspaceSettings workspaceSettings,
}) {
  final safeDuration = timelineDuration < Duration.zero
      ? Duration.zero
      : timelineDuration;
  final requestedStart = workspaceSettings.normalizedWorkAreaStart;
  final requestedEnd = workspaceSettings.normalizedWorkAreaEnd;
  if (requestedStart == null || requestedEnd == null) {
    return (start: Duration.zero, end: safeDuration);
  }
  final end = requestedEnd > safeDuration ? safeDuration : requestedEnd;
  final start = requestedStart < Duration.zero
      ? Duration.zero
      : requestedStart > end
      ? end
      : requestedStart;
  return (start: start, end: end);
}

@visibleForTesting
List<double> buildPreviewColorMatrixForTesting(
  ClipColorAdjustments adjustments,
) {
  final saturation = adjustments.saturation.clamp(0.0, 3.0);
  final contrast = (adjustments.contrast * (1 - adjustments.fade * 0.22)).clamp(
    0.1,
    3.0,
  );
  final brightness = (adjustments.brightness + adjustments.fade * 0.05).clamp(
    -1.0,
    1.0,
  );
  final warmth = (adjustments.temperature * 0.16).clamp(-0.2, 0.2);
  const redLuma = 0.2126;
  const greenLuma = 0.7152;
  const blueLuma = 0.0722;
  final inverseSaturation = 1 - saturation;
  final offset = 128 * (1 - contrast) + brightness * 255;
  final redWarmth = 1 + warmth;
  final blueWarmth = 1 - warmth;

  // Export applies eq first, then colorchannelmixer. Scale the complete
  // post-eq red/blue rows, including their offsets, to preserve that order.
  return [
    (redLuma * inverseSaturation + saturation) * contrast * redWarmth,
    greenLuma * inverseSaturation * contrast * redWarmth,
    blueLuma * inverseSaturation * contrast * redWarmth,
    0,
    offset * redWarmth,
    redLuma * inverseSaturation * contrast,
    (greenLuma * inverseSaturation + saturation) * contrast,
    blueLuma * inverseSaturation * contrast,
    0,
    offset,
    redLuma * inverseSaturation * contrast * blueWarmth,
    greenLuma * inverseSaturation * contrast * blueWarmth,
    (blueLuma * inverseSaturation + saturation) * contrast * blueWarmth,
    0,
    offset * blueWarmth,
    0,
    0,
    0,
    1,
    0,
  ];
}

@visibleForTesting
Size calculateGifDecodeSizeForTesting({
  required int intrinsicWidth,
  required int intrinsicHeight,
  required int frameCount,
  required double maxWidth,
  required double maxHeight,
}) {
  final sourceWidth = math.max(1, intrinsicWidth);
  final sourceHeight = math.max(1, intrinsicHeight);
  final widthLimit = maxWidth.isFinite && maxWidth > 0
      ? math.min(_maxGifDecodeDimension, maxWidth.floor())
      : 1;
  final heightLimit = maxHeight.isFinite && maxHeight > 0
      ? math.min(_maxGifDecodeDimension, maxHeight.floor())
      : 1;
  final perFramePixelBudget = math.max(
    1,
    _maxGifDecodedBytes ~/ (4 * math.max(1, frameCount)),
  );
  final scale = math.min(
    1.0,
    math.min(
      widthLimit / sourceWidth,
      math.min(
        heightLimit / sourceHeight,
        math.sqrt(perFramePixelBudget / (sourceWidth * sourceHeight)),
      ),
    ),
  );
  return Size(
    math.max(1, (sourceWidth * scale).floor()).toDouble(),
    math.max(1, (sourceHeight * scale).floor()).toDouble(),
  );
}

@visibleForTesting
Widget buildBlurredMediaPreviewForTesting({
  required Widget child,
  required ClipBlurSettings blur,
}) {
  if (!blur.isEnabled) return child;
  final filter = ui.ImageFilter.blur(
    sigmaX: blur.safeStrength,
    sigmaY: blur.safeStrength,
    tileMode: TileMode.clamp,
  );
  if (blur.mode == ClipBlurMode.full) {
    return ImageFiltered(imageFilter: filter, child: child);
  }
  if (blur.mode != ClipBlurMode.region) return child;
  return LayoutBuilder(
    builder: (context, constraints) {
      if (!constraints.hasBoundedWidth ||
          !constraints.hasBoundedHeight ||
          constraints.maxWidth <= 0 ||
          constraints.maxHeight <= 0) {
        return child;
      }
      final width = constraints.maxWidth;
      final height = constraints.maxHeight;
      final left = width * blur.safeRegionX;
      final top = height * blur.safeRegionY;
      final regionWidth = width * blur.safeRegionWidth;
      final regionHeight = height * blur.safeRegionHeight;
      return Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            left: left,
            top: top,
            width: regionWidth,
            height: regionHeight,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: width,
                maxWidth: width,
                minHeight: height,
                maxHeight: height,
                child: Transform.translate(
                  offset: Offset(-left, -top),
                  child: SizedBox(
                    width: width,
                    height: height,
                    // Paint an explicitly filtered copy of the media in the
                    // ROI. This works for texture-backed video without
                    // relying on BackdropFilter sampling platform pixels.
                    child: ImageFiltered(imageFilter: filter, child: child),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

Widget _buildComposedMediaPreview({
  required Color backgroundColor,
  required List<Widget> mediaLayers,
  required Widget Function(Widget composedMedia) timelineEffectsBuilder,
}) {
  final composedMedia = ColoredBox(
    key: const ValueKey('preview-composed-media-canvas'),
    color: backgroundColor,
    child: Stack(fit: StackFit.expand, children: mediaLayers),
  );
  return KeyedSubtree(
    key: const ValueKey('preview-composed-effect-output'),
    child: timelineEffectsBuilder(composedMedia),
  );
}

@visibleForTesting
Widget buildComposedMediaPreviewForTesting({
  required Color backgroundColor,
  required List<Widget> mediaLayers,
  required Widget Function(Widget composedMedia) timelineEffectsBuilder,
}) => _buildComposedMediaPreview(
  backgroundColor: backgroundColor,
  mediaLayers: mediaLayers,
  timelineEffectsBuilder: timelineEffectsBuilder,
);

@visibleForTesting
List<String> previewVisualTrackPaintOrderForTesting(EditorTimeline timeline) {
  return timeline.visualTracksInPaintOrder.map((track) => track.id).toList();
}

@visibleForTesting
bool isPreviewBaseLayerClipForTesting(TimelineClip clip) {
  return switch (clip.type) {
    TimelineTrackType.video ||
    TimelineTrackType.image ||
    TimelineTrackType.gif ||
    TimelineTrackType.sticker => true,
    _ => false,
  };
}

/// Video preview panel with subtitle overlay and playback controls.
class VideoPreviewPanel extends ConsumerStatefulWidget {
  final String videoPath;
  final double? targetAspectRatio;
  final VoidCallback? onFullscreenToggle;
  final bool isFullscreen;

  const VideoPreviewPanel({
    super.key,
    required this.videoPath,
    this.targetAspectRatio,
    this.onFullscreenToggle,
    this.isFullscreen = false,
  });

  @override
  ConsumerState<VideoPreviewPanel> createState() => _VideoPreviewPanelState();
}

class _VideoPreviewPanelState extends ConsumerState<VideoPreviewPanel>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  TimelineClip? _controllerClip;
  TimelineTrack? _controllerTrack;
  String? _controllerPath;
  int _controllerGeneration = 0;
  bool _initialized = false;
  bool _isSwitchingClip = false;
  bool _isAdvancingClip = false;
  bool _playRequested = false;
  bool _playbackSuspendedByLifecycle = false;
  Duration? _queuedSeekPosition;
  bool? _queuedSeekAutoplay;
  bool _queuedSeekForce = false;
  bool _queuedSeekPreserveClock = true;
  String? _previewError;
  Timer? _playbackTicker;
  final Stopwatch _timelineClock = Stopwatch();
  Duration _timelineClockAnchorElapsed = Duration.zero;
  Duration _timelineClockAnchorPosition = Duration.zero;
  bool _timelineClockAnchored = false;
  bool _baseFollowerSyncInFlight = false;
  DateTime? _lastBaseFollowerSyncAt;
  DateTime? _lastBaseDriftCorrectionAt;
  VideoPlayerController? _preparedBaseController;
  String? _preparedBaseClipId;
  String? _preparedBasePath;
  int _preparedBaseGeneration = 0;
  bool _basePreloadInFlight = false;
  DateTime? _lastBasePreloadCheckAt;
  double _playbackSpeed = 1.0;
  double? _lastBaseVolume;
  double? _lastBasePlaybackSpeed;
  bool _isSeekingReverseFrame = false;
  final PreviewPerformanceMonitor _performanceMonitor =
      PreviewPerformanceMonitor(enabled: false);
  bool _showPerformanceDiagnostics = false;
  EditorTimeline? _cachedCaptionTimeline;
  List<SubtitleEntry>? _cachedCaptionEntries;
  List<SubtitleEntry> _effectiveCaptionCache = const [];
  _PreviewCaptionIndex _effectiveCaptionIndex = _PreviewCaptionIndex.empty();
  EditorTimeline? _cachedPreviewTimeline;
  int? _cachedPreviewEditRevision;
  Map<String, EditorAssetReference> _cachedAssetsById = const {};
  List<_PreviewTrackLane> _cachedBaseVideoLanes = const [];
  List<_PreviewTrackLane> _cachedOverlayLanes = const [];
  List<_PreviewTrackLane> _cachedTextLanes = const [];
  List<_PreviewTrackLane> _cachedAudioLanes = const [];
  final Map<String, bool> _cachedFileAvailability = {};
  final Map<String, List<PreviewDuckingInterval>> _cachedDuckingIntervals = {};
  bool _cachedHasSoloMediaTrack = false;
  final Map<String, GlobalKey> _stableMediaPreviewKeys = {};
  double? _dragSourceOffsetX;
  double? _dragSourceOffsetY;
  double? _freeTransformStartScale;
  double? _freeTransformStartRotation;
  double? _freeTransformStartFontSize;

  void _ensurePreviewCaches(EditorTimeline timeline, {int? editRevision}) {
    if (identical(_cachedPreviewTimeline, timeline) &&
        (editRevision == null || editRevision == _cachedPreviewEditRevision)) {
      return;
    }
    _cachedPreviewTimeline = timeline;
    _cachedPreviewEditRevision = editRevision;
    _cachedAssetsById = {for (final asset in timeline.assets) asset.id: asset};
    final baseVideoLanes = <_PreviewTrackLane>[];
    final overlayLanes = <_PreviewTrackLane>[];
    final textLanes = <_PreviewTrackLane>[];
    final audioLanes = <_PreviewTrackLane>[];
    for (
      var trackIndex = 0;
      trackIndex < timeline.tracks.length;
      trackIndex++
    ) {
      final track = timeline.tracks[trackIndex];
      final clips =
          track.clips
              .where((clip) => clip.enabled && clip.endTime > clip.startTime)
              .toList(growable: false)
            ..sort((a, b) => a.startTime.compareTo(b.startTime));
      if (clips.isEmpty) continue;
      final lane = _PreviewTrackLane(
        trackIndex: trackIndex,
        track: track,
        clips: clips,
      );
      if (track.section == TimelineTrackSection.baseVideo && !track.isHidden) {
        baseVideoLanes.add(lane);
      }
      if (track.section == TimelineTrackSection.overlay && !track.isHidden) {
        overlayLanes.add(lane);
      }
      if (track.type == TimelineTrackType.text && !track.isHidden) {
        textLanes.add(lane);
      }
      if (track.section == TimelineTrackSection.audio) {
        audioLanes.add(lane);
      }
    }
    _cachedBaseVideoLanes = baseVideoLanes;
    _cachedOverlayLanes = overlayLanes;
    _cachedTextLanes = textLanes;
    _cachedAudioLanes = audioLanes;
    _cachedHasSoloMediaTrack = previewHasSoloMediaTrackForTesting(timeline);
    _cachedFileAvailability.clear();
    _cachedDuckingIntervals.clear();
    final liveMediaClipIds = timeline.tracks
        .expand((track) => track.clips)
        .where(
          (clip) =>
              clip.type == TimelineTrackType.video ||
              clip.type == TimelineTrackType.gif ||
              clip.type == TimelineTrackType.sticker,
        )
        .map((clip) => clip.id)
        .toSet();
    _stableMediaPreviewKeys.removeWhere(
      (clipId, _) => !liveMediaClipIds.contains(clipId),
    );
  }

  bool _cachedFileExists(String path) {
    return _cachedFileAvailability.putIfAbsent(
      path,
      () => File(path).existsSync(),
    );
  }

  EditorAssetReference? _cachedAssetForClip(
    EditorTimeline timeline,
    TimelineClip clip,
  ) {
    _ensurePreviewCaches(timeline);
    final assetId = clip.assetId;
    return assetId == null ? null : _cachedAssetsById[assetId];
  }

  Duration _timelineDuration() {
    final timeline = ref.read(editorProvider).timeline;
    return timeline.tracks
        .expand((track) => track.clips)
        .fold<Duration>(
          Duration.zero,
          (current, clip) => clip.endTime > current ? clip.endTime : current,
        );
  }

  GlobalKey _stableMediaPreviewKey(String clipId) {
    return _stableMediaPreviewKeys.putIfAbsent(clipId, GlobalKey.new);
  }

  void _anchorTimelineClock(Duration position) {
    _timelineClockAnchorPosition = position;
    _timelineClockAnchorElapsed = _timelineClock.elapsed;
    _timelineClockAnchored = true;
  }

  Duration _timelineClockPosition(EditorTimeline timeline) {
    if (!_timelineClockAnchored || !_playRequested) {
      return ref.read(playbackProvider).position;
    }
    final range = _playbackRange(timeline);
    final position = extrapolatePreviewPosition(
      basePosition: _timelineClockAnchorPosition,
      elapsed: _timelineClock.elapsed - _timelineClockAnchorElapsed,
      duration: range.end,
      playbackSpeed: _playbackSpeed,
      isPlaying: true,
    );
    return position < range.start ? range.start : position;
  }

  ({Duration start, Duration end}) _playbackRange(EditorTimeline timeline) {
    return resolvePreviewPlaybackRangeForTesting(
      timelineDuration: timeline.duration,
      workspaceSettings: timeline.workspaceSettings,
    );
  }

  @override
  void initState() {
    super.initState();
    _timelineClock.start();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initializeVideo();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_playbackSuspendedByLifecycle) return;
        _playbackSuspendedByLifecycle = false;
        if (!_playRequested || !mounted) return;
        final position = ref.read(playbackProvider).position;
        _anchorTimelineClock(position);
        unawaited(
          _seekTimelinePosition(position, autoplay: true, forceSeek: true),
        );
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (_playbackSuspendedByLifecycle || !_playRequested) return;
        _playbackSuspendedByLifecycle = true;
        final timeline = ref.read(editorProvider).timeline;
        final position = _timelineClockPosition(timeline);
        ref.read(playbackProvider.notifier).updatePosition(position);
        _anchorTimelineClock(position);
        // Rebase the shared monotonic clock so background time can never be
        // counted when playback resumes.
        _stopPlaybackTicker();
        unawaited(_controller?.pause());
        ref.read(playbackProvider.notifier).setPlaying(false);
        break;
    }
  }

  Future<void> _initializeVideo() async {
    final duration = _timelineDuration();
    ref.read(playbackProvider.notifier)
      ..updateDuration(duration)
      ..setReady(true);
    if (mounted) {
      setState(() => _initialized = true);
    }
    await _seekTimelinePosition(Duration.zero, forceSeek: true);
  }

  void _onPlaybackUpdate() {
    if (!mounted) return;
    if (_playbackSuspendedByLifecycle) {
      _stopPlaybackTicker();
      return;
    }
    _syncPlaybackState();
    if (_playRequested) {
      _startPlaybackTicker();
    } else {
      _stopPlaybackTicker();
    }
  }

  void _syncPlaybackState() {
    final controller = _controller;
    final clip = _controllerClip;
    if (!_initialized ||
        !mounted ||
        _playbackSuspendedByLifecycle ||
        controller == null ||
        clip == null ||
        !controller.value.isInitialized ||
        clip.isReversed ||
        clip.freezeFrame) {
      return;
    }
    // Platform decoder callbacks are deliberately not the timeline clock.
    // With several simultaneous videos a busy decoder can report late (or not
    // at all for a frame); letting that callback own the shared playhead made
    // the scrubber and every other media layer stall with it.
    final position = ref.read(playbackProvider).position;
    ref.read(playbackProvider.notifier).setPlaying(_playRequested);
    unawaited(_applyBaseAudioVolume(position));
  }

  void _startPlaybackTicker() {
    if (_playbackTicker?.isActive == true) return;
    if (!_timelineClockAnchored) {
      _anchorTimelineClock(ref.read(playbackProvider).position);
    }
    _performanceMonitor.beginTickSession();
    _playbackTicker = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!_initialized || !mounted || _playbackSuspendedByLifecycle) return;
      if (_performanceMonitor.isEnabled) {
        _performanceMonitor.recordTick(DateTime.now());
      }
      if (!_playRequested) {
        _stopPlaybackTicker();
        return;
      }

      final timeline = ref.read(editorProvider).timeline;
      final playbackRange = _playbackRange(timeline);
      final target = _timelineClockPosition(timeline);
      if (target >= playbackRange.end) {
        unawaited(_handlePlaybackRangeEnd());
        return;
      }

      ref.read(playbackProvider.notifier)
        ..updatePosition(target)
        ..setPlaying(true);
      final selection = _baseSelectionAt(timeline, target);
      final selectedClip = selection?.$2;
      if (!_isSwitchingClip && selectedClip?.id != _controllerClip?.id) {
        unawaited(
          _seekTimelinePosition(
            target,
            autoplay: true,
            forceSeek: true,
            preserveTimelineClock: true,
          ),
        );
      } else if (selectedClip?.type == TimelineTrackType.video) {
        if (selectedClip!.isReversed && !_isSeekingReverseFrame) {
          unawaited(_seekReversedFrame(target));
        } else if (!selectedClip.isReversed && !selectedClip.freezeFrame) {
          unawaited(_synchronizeBaseControllerFollower(target));
        }
      }
      unawaited(_prepareUpcomingBaseController(timeline, target));
      unawaited(_applyBaseAudioVolume(target));
    });
  }

  Future<void> _synchronizeBaseControllerFollower(
    Duration timelinePosition,
  ) async {
    final controller = _controller;
    final clip = _controllerClip;
    if (_baseFollowerSyncInFlight ||
        controller == null ||
        clip == null ||
        !controller.value.isInitialized ||
        clip.type != TimelineTrackType.video ||
        clip.isReversed ||
        clip.freezeFrame) {
      return;
    }
    final now = DateTime.now();
    final lastSync = _lastBaseFollowerSyncAt;
    if (lastSync != null &&
        now.difference(lastSync) < const Duration(milliseconds: 240)) {
      return;
    }
    _lastBaseFollowerSyncAt = now;
    _baseFollowerSyncInFlight = true;
    final generation = _controllerGeneration;
    try {
      final target = _sourceTargetForClip(clip, timelinePosition);
      final lastCorrection = _lastBaseDriftCorrectionAt;
      final decision = decidePreviewMediaSync(
        timelineTarget: target,
        decoderPosition: controller.value.position,
        isPlaying: _playRequested,
        isAudible: (_lastBaseVolume ?? 0) > 0.001,
        isBuffering: controller.value.isBuffering,
        timeSinceLastCorrection: lastCorrection == null
            ? null
            : now.difference(lastCorrection),
      );
      if (decision == PreviewMediaSyncDecision.seek) {
        _performanceMonitor.recordHardSeek();
        await controller.seekTo(target);
        _lastBaseDriftCorrectionAt = now;
      }
      if (!mounted ||
          generation != _controllerGeneration ||
          !identical(controller, _controller)) {
        return;
      }
      if (_playRequested &&
          !_playbackSuspendedByLifecycle &&
          !controller.value.isPlaying) {
        await controller.play();
      }
    } catch (_) {
      // A follower may be replaced while a platform seek is in flight.
    } finally {
      _baseFollowerSyncInFlight = false;
    }
  }

  void _stopPlaybackTicker() {
    _playbackTicker?.cancel();
    _playbackTicker = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPlaybackTicker();
    _timelineClock.stop();
    _controllerGeneration++;
    _preparedBaseGeneration++;
    final controller = _controller;
    final preparedController = _preparedBaseController;
    _controller = null;
    _preparedBaseController = null;
    _preparedBaseClipId = null;
    _preparedBasePath = null;
    _controllerClip = null;
    _controllerTrack = null;
    _controllerPath = null;
    if (controller != null) {
      controller.removeListener(_onPlaybackUpdate);
      unawaited(controller.dispose());
    }
    if (preparedController != null) {
      unawaited(preparedController.dispose());
    }
    _performanceMonitor.clear();
    super.dispose();
  }

  void _togglePlayPause() {
    final playback = ref.read(playbackProvider);
    if (_playRequested) {
      final current = _timelineClockPosition(ref.read(editorProvider).timeline);
      _playRequested = false;
      _anchorTimelineClock(current);
      unawaited(_controller?.pause());
      _stopPlaybackTicker();
      ref.read(playbackProvider.notifier)
        ..updatePosition(current)
        ..setPlaying(false);
    } else {
      final startPosition = playback.position >= playback.duration
          ? Duration.zero
          : playback.position;
      _playRequested = true;
      _anchorTimelineClock(startPosition);
      _startPlaybackTicker();
      unawaited(
        _seekTimelinePosition(
          startPosition,
          autoplay: true,
          forceSeek: playback.position >= playback.duration,
        ),
      );
    }
  }

  void _seekTo(Duration position) {
    if (!_initialized) return;
    ref.read(playbackProvider.notifier).requestSeek(position);
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    if (!_initialized) return;
    final timeline = ref.read(editorProvider).timeline;
    final current = _playRequested
        ? _timelineClockPosition(timeline)
        : ref.read(playbackProvider).position;
    if (mounted) setState(() => _playbackSpeed = speed);
    _anchorTimelineClock(current);
    final controller = _controller;
    final clip = _controllerClip;
    if (controller != null && clip != null) {
      if (!clip.isReversed && !clip.freezeFrame) {
        final effectiveSpeed = (speed * clip.playbackRate)
            .clamp(0.25, 4)
            .toDouble();
        if (_lastBasePlaybackSpeed == null ||
            (_lastBasePlaybackSpeed! - effectiveSpeed).abs() > 0.001) {
          await controller.setPlaybackSpeed(effectiveSpeed);
          _lastBasePlaybackSpeed = effectiveSpeed;
        }
      }
    }
  }

  (TimelineTrack, TimelineClip)? _baseSelectionAt(
    EditorTimeline timeline,
    Duration position,
  ) {
    _ensurePreviewCaches(timeline);
    final includeEnd = position == timeline.duration;
    for (final lane in _cachedBaseVideoLanes) {
      final clip = lane.activeAt(position, includeEnd: includeEnd);
      if (clip != null && isPreviewBaseLayerClipForTesting(clip)) {
        return (lane.track, clip);
      }
    }
    return null;
  }

  (TimelineTrack, TimelineClip)? _nextBaseVideoSelection(
    EditorTimeline timeline,
    Duration position,
  ) {
    _ensurePreviewCaches(timeline);
    final candidates = <(TimelineTrack, TimelineClip)>[];
    final maximumStart = position + _baseVideoPreloadWindow;
    for (final lane in _cachedBaseVideoLanes) {
      final first = lane.firstStartingAfter(position);
      for (var index = first; index < lane.clips.length; index++) {
        final clip = lane.clips[index];
        if (clip.startTime > maximumStart) break;
        if (shouldPreloadBaseVideoForTesting(clip: clip, position: position)) {
          candidates.add((lane.track, clip));
        }
      }
    }
    candidates.sort((a, b) => a.$2.startTime.compareTo(b.$2.startTime));
    return candidates.firstOrNull;
  }

  Future<void> _disposeDetachedController(
    VideoPlayerController controller,
  ) async {
    try {
      await controller.pause();
    } catch (_) {
      // A platform decoder may already have released its player handle.
    }
    try {
      await controller.dispose();
    } catch (_) {
      // Detached decoder cleanup is best-effort.
    }
  }

  void _discardPreparedBaseController({bool invalidate = true}) {
    if (invalidate) _preparedBaseGeneration++;
    final controller = _preparedBaseController;
    _preparedBaseController = null;
    _preparedBaseClipId = null;
    _preparedBasePath = null;
    if (controller != null) {
      unawaited(_disposeDetachedController(controller));
    }
  }

  VideoPlayerController? _takePreparedBaseController(
    TimelineClip clip,
    String sourcePath,
  ) {
    final controller = _preparedBaseController;
    final matches =
        controller != null &&
        controller.value.isInitialized &&
        _preparedBaseClipId == clip.id &&
        _preparedBasePath == sourcePath;
    if (!matches) {
      _discardPreparedBaseController();
      return null;
    }
    _preparedBaseGeneration++;
    _preparedBaseController = null;
    _preparedBaseClipId = null;
    _preparedBasePath = null;
    return controller;
  }

  Future<void> _prepareUpcomingBaseController(
    EditorTimeline timeline,
    Duration position,
  ) async {
    if (!mounted ||
        _basePreloadInFlight ||
        _isSwitchingClip ||
        _playbackSuspendedByLifecycle) {
      return;
    }
    final now = DateTime.now();
    final lastCheck = _lastBasePreloadCheckAt;
    if (lastCheck != null &&
        now.difference(lastCheck) < const Duration(milliseconds: 450)) {
      return;
    }
    _lastBasePreloadCheckAt = now;
    final selection = _nextBaseVideoSelection(timeline, position);
    if (selection == null) {
      if (_preparedBaseController != null &&
          _preparedBaseClipId != _controllerClip?.id) {
        _discardPreparedBaseController();
      }
      return;
    }
    final clip = selection.$2;
    final sourcePath = _sourcePathForClip(timeline, clip);
    if (sourcePath == null) return;
    if (_preparedBaseClipId == clip.id &&
        _preparedBasePath == sourcePath &&
        _preparedBaseController?.value.isInitialized == true) {
      return;
    }

    _discardPreparedBaseController();
    final generation = _preparedBaseGeneration;
    _basePreloadInFlight = true;
    VideoPlayerController? candidate;
    try {
      candidate = VideoPlayerController.file(
        File(sourcePath),
        videoPlayerOptions: buildPreviewVideoPlayerOptions(),
      );
      await candidate.initialize();
      await candidate.setVolume(0);
      if (!clip.isReversed && !clip.freezeFrame) {
        await candidate.setPlaybackSpeed(
          (_playbackSpeed * clip.playbackRate).clamp(0.25, 4).toDouble(),
        );
      }
      await candidate.seekTo(_sourceTargetForClip(clip, clip.startTime));
      if (!mounted ||
          generation != _preparedBaseGeneration ||
          _controllerClip?.id == clip.id) {
        await candidate.dispose();
        candidate = null;
        return;
      }
      _preparedBaseController = candidate;
      _preparedBaseClipId = clip.id;
      _preparedBasePath = sourcePath;
      candidate = null;
    } catch (_) {
      if (candidate != null) {
        try {
          await candidate.dispose();
        } catch (_) {
          // Preloading is an optimization and can fail without blocking edit.
        }
      }
    } finally {
      _basePreloadInFlight = false;
    }
  }

  String? _sourcePathForClip(EditorTimeline timeline, TimelineClip clip) {
    _ensurePreviewCaches(timeline);
    return resolvePreviewSourcePathForTesting(
      timeline: timeline,
      clip: clip,
      legacyVideoPath: clip.type == TimelineTrackType.video
          ? widget.videoPath
          : '',
      fileExists: _cachedFileExists,
    );
  }

  Future<void> _seekTimelinePosition(
    Duration requested, {
    bool? autoplay,
    bool forceSeek = false,
    bool preserveTimelineClock = false,
  }) async {
    if (!_initialized || !mounted) return;
    if (_isSwitchingClip) {
      _queuedSeekPosition = requested;
      _queuedSeekAutoplay = autoplay;
      _queuedSeekForce = _queuedSeekForce || forceSeek;
      _queuedSeekPreserveClock =
          _queuedSeekPreserveClock && preserveTimelineClock;
      return;
    }
    final timeline = ref.read(editorProvider).timeline;
    final duration = timeline.duration;
    final requestedTargetMs = requested.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toInt();
    final shouldPlay = autoplay ?? _playRequested;
    final requestedTarget = Duration(milliseconds: requestedTargetMs);
    final playbackRange = _playbackRange(timeline);
    final target =
        shouldPlay &&
            playbackRange.end > playbackRange.start &&
            (requestedTarget < playbackRange.start ||
                requestedTarget >= playbackRange.end)
        ? playbackRange.start
        : requestedTarget;
    _playRequested = shouldPlay;
    if (!preserveTimelineClock || !_timelineClockAnchored) {
      _anchorTimelineClock(target);
    }
    final selection = _baseSelectionAt(timeline, target);
    final playbackNotifier = ref.read(playbackProvider.notifier);

    if (selection == null) {
      final controller = _controller;
      // Detach the old base clip before yielding to the platform pause. The
      // shared ticker can fire meanwhile; seeing the stale clip here used to
      // launch several overlapping gap-transition seeks.
      _controllerClip = null;
      _controllerTrack = null;
      _previewError = null;
      if (controller?.value.isPlaying == true) {
        await controller!.pause();
      }
      final playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      final publishedPosition = playNow && preserveTimelineClock
          ? _timelineClockPosition(timeline)
          : target;
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(publishedPosition)
        ..setPlaying(playNow)
        ..setReady(true);
      if (mounted) setState(() {});
      if (playNow) _startPlaybackTicker();
      return;
    }

    final track = selection.$1;
    final clip = selection.$2;
    final sourcePath = _sourcePathForClip(timeline, clip);
    if (clip.type != TimelineTrackType.video) {
      final previous = _controller;
      if (previous != null) previous.removeListener(_onPlaybackUpdate);
      _controllerGeneration++;
      _controller = null;
      _controllerClip = clip;
      _controllerTrack = track;
      _controllerPath = sourcePath;
      _lastBaseVolume = null;
      _lastBasePlaybackSpeed = null;
      _lastBaseFollowerSyncAt = null;
      _lastBaseDriftCorrectionAt = null;
      _previewError = null;
      final asset = _cachedAssetForClip(timeline, clip);
      final hasRenderableSource =
          sourcePath != null ||
          asset?.remoteUrl?.isNotEmpty == true ||
          (asset?.metadata['previewUrl'] as String?)?.isNotEmpty == true;
      if (!hasRenderableSource) {
        _previewError =
            'Media is missing for "${clip.label}". Relink it first.';
      }
      final playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      final publishedPosition = playNow && preserveTimelineClock
          ? _timelineClockPosition(timeline)
          : target;
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(publishedPosition)
        ..setPlaying(playNow)
        ..setReady(true);
      if (mounted) setState(() {});
      if (previous != null) {
        unawaited(() async {
          try {
            await previous.pause();
          } catch (_) {
            // The previous platform decoder may already be unavailable.
          }
          try {
            await previous.dispose();
          } catch (_) {
            // Controller disposal is best-effort after ownership is detached.
          }
        }());
      }
      if (playNow) _startPlaybackTicker();
      return;
    }
    if (sourcePath == null) {
      final unavailableController = _controller;
      unavailableController?.removeListener(_onPlaybackUpdate);
      _controller = null;
      _controllerClip = clip;
      _controllerTrack = track;
      _controllerPath = null;
      _lastBaseVolume = null;
      _lastBasePlaybackSpeed = null;
      _lastBaseDriftCorrectionAt = null;
      _previewError = 'Media is missing for "${clip.label}". Relink it first.';
      final playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      final publishedPosition = playNow && preserveTimelineClock
          ? _timelineClockPosition(timeline)
          : target;
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(publishedPosition)
        ..setPlaying(playNow)
        ..setReady(true);
      if (mounted) setState(() {});
      if (unavailableController != null) {
        try {
          await unavailableController.pause();
        } catch (_) {
          // The controller can already be invalid if its source disappeared.
        }
        try {
          await unavailableController.dispose();
        } catch (_) {
          // Disposal is best-effort after detaching the listener and ownership.
        }
      }
      if (playNow) _startPlaybackTicker();
      return;
    }
    var sourceTarget = _sourceTargetForClip(clip, target);

    final currentController = _controller;
    final canReuse =
        currentController != null &&
        currentController.value.isInitialized &&
        _controllerClip?.id == clip.id &&
        _controllerPath == sourcePath;
    if (canReuse) {
      // Bind the latest immutable timeline values before any controller call
      // can notify listeners. Timing edits must never be interpreted through
      // the stale clip that originally created this controller.
      _controllerClip = clip;
      _controllerTrack = track;
      final now = DateTime.now();
      final lastCorrection = _lastBaseDriftCorrectionAt;
      final decision = decidePreviewMediaSync(
        timelineTarget: sourceTarget,
        decoderPosition: currentController.value.position,
        isPlaying: shouldPlay,
        isAudible: (_lastBaseVolume ?? 0) > 0.001,
        isBuffering: currentController.value.isBuffering,
        forceSeek: forceSeek,
        timeSinceLastCorrection: lastCorrection == null
            ? null
            : now.difference(lastCorrection),
      );
      if (decision == PreviewMediaSyncDecision.seek) {
        if (!forceSeek) _performanceMonitor.recordHardSeek();
        await currentController.seekTo(sourceTarget);
        _lastBaseDriftCorrectionAt = now;
      }
      if (!clip.isReversed && !clip.freezeFrame) {
        final effectiveSpeed = (_playbackSpeed * clip.playbackRate)
            .clamp(0.25, 4)
            .toDouble();
        if (_lastBasePlaybackSpeed == null ||
            (_lastBasePlaybackSpeed! - effectiveSpeed).abs() > 0.001) {
          await currentController.setPlaybackSpeed(effectiveSpeed);
          _lastBasePlaybackSpeed = effectiveSpeed;
        }
      }
      await _applyBaseAudioVolume(target);
      var playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      if (clip.isReversed || clip.freezeFrame) {
        if (currentController.value.isPlaying) {
          await currentController.pause();
        }
        playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      } else if (playNow && !currentController.value.isPlaying) {
        await currentController.play();
      } else if (!playNow && currentController.value.isPlaying) {
        await currentController.pause();
      }
      playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      if (!playNow && currentController.value.isPlaying) {
        await currentController.pause();
      }
      final publishedPosition = playNow && preserveTimelineClock
          ? _timelineClockPosition(timeline)
          : target;
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(publishedPosition)
        ..setPlaying(playNow);
      if (playNow) _startPlaybackTicker();
      return;
    }

    final preparedController = _takePreparedBaseController(clip, sourcePath);
    _isSwitchingClip = true;
    final controllerGeneration = ++_controllerGeneration;
    VideoPlayerController? nextController;
    try {
      _previewError = null;
      if (currentController != null) {
        currentController.removeListener(_onPlaybackUpdate);
        // Relinquish widget ownership before the first await. Builds triggered
        // while the replacement initializes must never read a disposed texture.
        if (identical(_controller, currentController)) {
          _controller = null;
          _controllerClip = null;
          _controllerTrack = null;
          _controllerPath = null;
          if (mounted && preparedController == null) setState(() {});
        }
        if (preparedController != null) {
          // The warm controller can take ownership immediately. Tear down the
          // previous decoder off the cut-critical path.
          unawaited(_disposeDetachedController(currentController));
        } else {
          await _disposeDetachedController(currentController);
        }
      }
      if (!mounted || controllerGeneration != _controllerGeneration) return;
      _lastBaseVolume = null;
      _lastBasePlaybackSpeed = null;
      _lastBaseDriftCorrectionAt = null;
      nextController =
          preparedController ??
          VideoPlayerController.file(
            File(sourcePath),
            videoPlayerOptions: buildPreviewVideoPlayerOptions(),
          );
      if (preparedController == null) {
        await nextController.initialize();
      }
      if (!mounted || controllerGeneration != _controllerGeneration) {
        await nextController.dispose();
        nextController = null;
        return;
      }
      final synchronizedTimelineTarget = shouldPlay && preserveTimelineClock
          ? _timelineClockPosition(timeline)
          : target;
      final synchronizedSelection = _baseSelectionAt(
        timeline,
        synchronizedTimelineTarget,
      );
      if (synchronizedSelection?.$2.id != clip.id) {
        await nextController.dispose();
        nextController = null;
        _queuedSeekPosition = synchronizedTimelineTarget;
        _queuedSeekAutoplay = shouldPlay;
        _queuedSeekForce = true;
        _queuedSeekPreserveClock = true;
        return;
      }
      sourceTarget = _sourceTargetForClip(clip, synchronizedTimelineTarget);
      final preparedDrift = (nextController.value.position - sourceTarget)
          .abs();
      if (preparedController == null ||
          preparedDrift > const Duration(milliseconds: 90)) {
        await nextController.seekTo(sourceTarget);
      }
      if (!mounted || controllerGeneration != _controllerGeneration) {
        await nextController.dispose();
        nextController = null;
        return;
      }
      if (!clip.isReversed && !clip.freezeFrame) {
        final effectiveSpeed = (_playbackSpeed * clip.playbackRate)
            .clamp(0.25, 4)
            .toDouble();
        if (preparedController == null) {
          await nextController.setPlaybackSpeed(effectiveSpeed);
        }
        _lastBasePlaybackSpeed = effectiveSpeed;
      }
      if (!mounted || controllerGeneration != _controllerGeneration) {
        await nextController.dispose();
        nextController = null;
        return;
      }
      _controller = nextController;
      _controllerClip = clip;
      _controllerTrack = track;
      _controllerPath = sourcePath;
      nextController.addListener(_onPlaybackUpdate);
      await _applyBaseAudioVolume(synchronizedTimelineTarget);
      var playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      if (!clip.isReversed && !clip.freezeFrame) {
        if (playNow) await nextController.play();
      }
      playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      if (!playNow && nextController.value.isPlaying) {
        await nextController.pause();
      }
      final publishedPosition = playNow && preserveTimelineClock
          ? _timelineClockPosition(timeline)
          : synchronizedTimelineTarget;
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(publishedPosition)
        ..setPlaying(playNow)
        ..setReady(true);
      setState(() {});
      if (playNow) _startPlaybackTicker();
    } catch (_) {
      final failedController = nextController;
      if (failedController != null) {
        if (identical(failedController, _controller)) {
          _controller = null;
          _controllerClip = null;
          _controllerTrack = null;
          _controllerPath = null;
        }
        try {
          failedController.removeListener(_onPlaybackUpdate);
          await failedController.dispose();
        } catch (_) {
          // Initialization can leave the platform controller partly torn down.
        }
      }
      if (!mounted || controllerGeneration != _controllerGeneration) return;
      _controller = null;
      _controllerClip = clip;
      _controllerTrack = track;
      _controllerPath = sourcePath;
      _lastBaseVolume = null;
      _lastBasePlaybackSpeed = null;
      _previewError = 'This clip could not be decoded on this device.';
      final playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      final publishedPosition = playNow && preserveTimelineClock
          ? _timelineClockPosition(timeline)
          : target;
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(publishedPosition)
        ..setPlaying(playNow)
        ..setReady(true);
      setState(() {});
      if (playNow) _startPlaybackTicker();
    } finally {
      if (controllerGeneration == _controllerGeneration) {
        _isSwitchingClip = false;
      }
      final queuedPosition = _queuedSeekPosition;
      final queuedAutoplay = _queuedSeekAutoplay;
      final queuedForce = _queuedSeekForce;
      final queuedPreserveClock = _queuedSeekPreserveClock;
      _queuedSeekPosition = null;
      _queuedSeekAutoplay = null;
      _queuedSeekForce = false;
      _queuedSeekPreserveClock = true;
      if (queuedPosition != null && mounted && !_isSwitchingClip) {
        unawaited(
          _seekTimelinePosition(
            queuedPosition,
            autoplay: queuedAutoplay,
            forceSeek: queuedForce,
            preserveTimelineClock: queuedPreserveClock,
          ),
        );
      }
    }
  }

  Future<void> _handlePlaybackRangeEnd() async {
    if (_isAdvancingClip || !_playRequested || !mounted) return;
    _isAdvancingClip = true;
    try {
      await _finishPlaybackRange(ref.read(editorProvider).timeline);
    } finally {
      _isAdvancingClip = false;
    }
  }

  Future<void> _finishPlaybackRange(EditorTimeline timeline) async {
    final playbackRange = _playbackRange(timeline);
    if (timeline.workspaceSettings.loopPlayback &&
        playbackRange.end > playbackRange.start) {
      await _seekTimelinePosition(
        playbackRange.start,
        autoplay: true,
        forceSeek: true,
      );
      return;
    }

    _playRequested = false;
    await _seekTimelinePosition(
      playbackRange.end,
      autoplay: false,
      forceSeek: true,
    );
    _stopPlaybackTicker();
  }

  void _updateOwnedDecoderDiagnostics(Duration position) {
    if (!_performanceMonitor.isEnabled) return;
    final controller = _controller;
    final clip = _controllerClip;
    if (controller == null || !controller.value.isInitialized) {
      _performanceMonitor.removeDecoder('base');
    } else {
      final target = clip == null
          ? controller.value.position
          : _sourceTargetForClip(clip, position);
      _performanceMonitor.updateDecoder(
        id: 'base',
        label: clip?.label ?? 'Detached base decoder',
        kind: PreviewDecoderKind.baseVideo,
        initialized: true,
        buffering: controller.value.isBuffering,
        audible: (_lastBaseVolume ?? 0) > 0.001,
        playing: controller.value.isPlaying,
        warm: false,
        drift: target - controller.value.position,
      );
    }

    final prepared = _preparedBaseController;
    if (prepared == null || !prepared.value.isInitialized) {
      _performanceMonitor.removeDecoder('prepared');
    } else {
      _performanceMonitor.updateDecoder(
        id: 'prepared',
        label: _preparedBaseClipId ?? 'Prepared base decoder',
        kind: PreviewDecoderKind.preparedVideo,
        initialized: true,
        buffering: prepared.value.isBuffering,
        audible: false,
        playing: false,
        warm: true,
        drift: Duration.zero,
      );
    }
  }

  Future<void> _applyBaseAudioVolume(Duration position) async {
    final controller = _controller;
    final clip = _controllerClip;
    final track = _controllerTrack;
    if (controller == null ||
        clip == null ||
        track == null ||
        !controller.value.isInitialized) {
      return;
    }
    final timeline = ref.read(editorProvider).timeline;
    final hasSolo = _hasSoloMediaTrack(timeline);
    final linkedAudio = resolvePreviewBaseAudioMonitorForTesting(
      timeline: timeline,
      baseClip: clip,
      position: position,
    );
    final hasExplicitLinkedAudio = previewHasExplicitLinkedAudioForTesting(
      timeline: timeline,
      visualClip: clip,
    );
    final monitoredClip = linkedAudio?.clip ?? clip;
    final monitoredTrack = linkedAudio?.track ?? track;
    final volume = _previewAudioVolume(
      clip: monitoredClip,
      position: position,
      isTrackAudible:
          (!hasExplicitLinkedAudio || linkedAudio != null) &&
          !monitoredTrack.isMuted &&
          (!hasSolo || monitoredTrack.isSolo),
      duckingGain: _previewDuckingGain(monitoredClip, position),
    );
    if (_lastBaseVolume != null && (_lastBaseVolume! - volume).abs() <= 0.01) {
      return;
    }
    await controller.setVolume(volume);
    if (identical(controller, _controller)) _lastBaseVolume = volume;
  }

  Duration _sourceTargetForClip(TimelineClip clip, Duration timelinePosition) {
    if (clip.freezeFrame) return clip.effectiveFreezeFrameSourceTime;
    final elapsedMs = (timelinePosition - clip.startTime).inMilliseconds.clamp(
      0,
      clip.duration.inMilliseconds,
    );
    final forwardOffsetMs = (elapsedMs * clip.playbackRate).round();
    if (!clip.isReversed) {
      return clip.sourceStartTime + Duration(milliseconds: forwardOffsetMs);
    }
    final declaredSpanMs = clip.sourceDuration.inMilliseconds;
    final spanMs = declaredSpanMs > 0
        ? declaredSpanMs
        : (clip.duration.inMilliseconds * clip.playbackRate).round();
    final reversedOffsetMs = (spanMs - forwardOffsetMs - 1)
        .clamp(0, math.max(0, spanMs - 1))
        .toInt();
    return clip.sourceStartTime + Duration(milliseconds: reversedOffsetMs);
  }

  Future<void> _seekReversedFrame(Duration timelinePosition) async {
    final controller = _controller;
    final clip = _controllerClip;
    if (controller == null ||
        clip == null ||
        !clip.isReversed ||
        !controller.value.isInitialized ||
        _isSeekingReverseFrame) {
      return;
    }
    _isSeekingReverseFrame = true;
    try {
      await controller.seekTo(_sourceTargetForClip(clip, timelinePosition));
      if (!mounted) return;
      ref.read(playbackProvider.notifier)
        ..updatePosition(timelinePosition)
        ..setPlaying(_playRequested);
      await _applyBaseAudioVolume(timelinePosition);
    } finally {
      _isSeekingReverseFrame = false;
    }
  }

  void _stepFrame(int direction) {
    final timeline = ref.read(editorProvider).timeline;
    final clip = _controllerClip;
    final asset = clip == null ? null : timeline.assetForClip(clip);
    final sourceFrameRate = (asset?.metadata['frameRate'] as num?)?.toDouble();
    final fps = sourceFrameRate != null && sourceFrameRate > 0
        ? sourceFrameRate
        : 30.0;
    final frame = Duration(
      microseconds: (Duration.microsecondsPerSecond / fps).round(),
    );
    final playback = ref.read(playbackProvider);
    if (_playRequested) {
      _togglePlayPause();
    }
    _seekTo(playback.position + frame * direction);
  }

  Future<void> _showTimecodeJumpDialog() async {
    final playback = ref.read(playbackProvider);
    final controller = TextEditingController(
      text: _formatDetailedTimecode(playback.position),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Jump to timecode'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.datetime,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: '00:00:00.000',
            helperText: 'HH:MM:SS.mmm',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Jump'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    final parsed = _parseTimecode(result);
    if (parsed == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Use a timecode like 00:01:23.500')),
      );
      return;
    }
    _seekTo(parsed);
  }

  Duration? _parseTimecode(String value) {
    final match = RegExp(
      r'^\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,:](\d{1,3}))?\s*$',
    ).firstMatch(value);
    if (match == null) return null;
    final hours = int.tryParse(match.group(1) ?? '0');
    final minutes = int.tryParse(match.group(2) ?? '');
    final seconds = int.tryParse(match.group(3) ?? '');
    final fraction = (match.group(4) ?? '0').padRight(3, '0').substring(0, 3);
    final milliseconds = int.tryParse(fraction);
    if (hours == null ||
        minutes == null ||
        seconds == null ||
        milliseconds == null ||
        minutes > 59 ||
        seconds > 59) {
      return null;
    }
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  }

  String _formatDetailedTimecode(Duration duration) {
    final safe = duration < Duration.zero ? Duration.zero : duration;
    final hours = safe.inHours.toString().padLeft(2, '0');
    final minutes = (safe.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (safe.inSeconds % 60).toString().padLeft(2, '0');
    final milliseconds = (safe.inMilliseconds % 1000).toString().padLeft(
      3,
      '0',
    );
    return '$hours:$minutes:$seconds.$milliseconds';
  }

  SubtitleStyleModel _readEditableStyleFor(
    SubtitleEntry activeEntry,
    bool editPerEntry,
  ) {
    final subtitleState = ref.read(subtitleProvider);
    final latest = subtitleState.entries.where((e) => e.id == activeEntry.id);
    final latestEntry = latest.isNotEmpty ? latest.first : activeEntry;
    if (editPerEntry) {
      return latestEntry.styleOverride ?? subtitleState.globalStyle;
    }
    return subtitleState.globalStyle;
  }

  void _applyStyleLive({
    required SubtitleEntry activeEntry,
    required SubtitleStyleModel style,
    required bool editPerEntry,
  }) {
    final notifier = ref.read(subtitleProvider.notifier);
    if (editPerEntry) {
      notifier.setEntryStyleOverrideLive(activeEntry.id, style);
    } else {
      notifier.updateGlobalStyleLive(style);
    }
  }

  void _beginStyleGesture(SubtitleEntry activeEntry, bool editPerEntry) {
    final style = _readEditableStyleFor(activeEntry, editPerEntry);
    _dragSourceOffsetX = style.offsetX;
    _dragSourceOffsetY = style.verticalOffset + style.offsetY;
    _freeTransformStartFontSize = style.fontSize;
    final notifier = ref.read(subtitleProvider.notifier);
    notifier.selectEntry(activeEntry.id);
    notifier.beginStyleGestureEdit();
  }

  void _endStyleGesture() {
    _dragSourceOffsetX = null;
    _dragSourceOffsetY = null;
    _freeTransformStartFontSize = null;
    ref.read(subtitleProvider.notifier).endStyleGestureEdit();
  }

  List<_OverlayCanvasItem> _activeOverlayItems(
    EditorTimeline timeline,
    Duration position,
  ) {
    _ensurePreviewCaches(timeline);
    final items = <_OverlayCanvasItem>[];
    for (final lane in _cachedOverlayLanes) {
      final clip = lane.activeAt(position);
      if (clip == null) continue;
      final asset = _cachedAssetForClip(timeline, clip);
      if (asset == null) continue;
      items.add(
        _OverlayCanvasItem(
          trackIndex: lane.trackIndex,
          track: lane.track,
          clip: clip,
          asset: asset,
        ),
      );
    }

    items.sort((a, b) {
      final trackCompare = b.trackIndex.compareTo(a.trackIndex);
      if (trackCompare != 0) return trackCompare;
      final layerCompare = a.clip.layer.compareTo(b.clip.layer);
      if (layerCompare != 0) return layerCompare;
      return a.clip.startTime.compareTo(b.clip.startTime);
    });
    return items;
  }

  List<_EffectCanvasItem> _activeEffectItems(
    EditorTimeline timeline,
    Duration position,
  ) {
    _ensurePreviewCaches(timeline);
    final items = <_EffectCanvasItem>[];
    for (final lane in _cachedOverlayLanes) {
      final clip = lane.activeAt(position);
      if (clip == null || !clip.isEffect) continue;
      items.add(
        _EffectCanvasItem(
          trackIndex: lane.trackIndex,
          trackId: lane.track.id,
          clip: clip,
        ),
      );
    }
    items.sort((a, b) {
      final trackCompare = b.trackIndex.compareTo(a.trackIndex);
      if (trackCompare != 0) return trackCompare;
      final layerCompare = a.clip.layer.compareTo(b.clip.layer);
      if (layerCompare != 0) return layerCompare;
      return a.clip.startTime.compareTo(b.clip.startTime);
    });
    return items;
  }

  List<_TextCanvasItem> _activeTextItems(
    EditorTimeline timeline,
    Duration position,
  ) {
    _ensurePreviewCaches(timeline);
    final items = <_TextCanvasItem>[];
    for (final lane in _cachedTextLanes) {
      final clip = lane.activeAt(position);
      if (clip == null) continue;
      items.add(
        _TextCanvasItem(
          trackIndex: lane.trackIndex,
          trackId: lane.track.id,
          clip: clip,
        ),
      );
    }

    items.sort((a, b) {
      final trackCompare = b.trackIndex.compareTo(a.trackIndex);
      if (trackCompare != 0) return trackCompare;
      return a.clip.layer.compareTo(b.clip.layer);
    });
    return items;
  }

  List<_AudioCanvasItem> _activeAudioItems(
    EditorTimeline timeline,
    Duration position,
    String? baseMonitoredClipId,
  ) {
    _ensurePreviewCaches(timeline);
    final activeItems = <_AudioCanvasItem>[];
    final upcomingItems = <_AudioCanvasItem>[];
    final hasSoloMediaTrack = _hasSoloMediaTrack(timeline);
    void collectClip(_PreviewTrackLane lane, TimelineClip clip) {
      if (!shouldCreateTimelineAudioPreviewForTesting(
            track: lane.track,
            clip: clip,
            hasSoloMediaTrack: hasSoloMediaTrack,
            baseMonitoredClipId: baseMonitoredClipId,
          ) ||
          !shouldPreloadTimelineAudioPreviewForTesting(
            clip: clip,
            position: position,
          )) {
        return;
      }
      final asset = _cachedAssetForClip(timeline, clip);
      final sourcePath = asset?.sourcePath;
      if (asset == null ||
          sourcePath == null ||
          !_cachedFileExists(sourcePath)) {
        return;
      }
      final isActive = position >= clip.startTime && position < clip.endTime;
      final item = _AudioCanvasItem(
        track: lane.track,
        clip: clip,
        asset: asset,
        isActive: isActive,
      );
      if (isActive) {
        activeItems.add(item);
      } else {
        upcomingItems.add(item);
      }
    }

    final maximumStart = position + _audioPreviewPreloadWindow;
    for (final lane in _cachedAudioLanes) {
      final activeClip = lane.activeAt(position);
      if (activeClip != null) collectClip(lane, activeClip);
      final first = lane.firstStartingAfter(position);
      for (var index = first; index < lane.clips.length; index++) {
        final clip = lane.clips[index];
        if (clip.startTime > maximumStart) break;
        collectClip(lane, clip);
      }
    }
    upcomingItems.sort((a, b) => a.clip.startTime.compareTo(b.clip.startTime));
    return [
      ...activeItems,
      ...upcomingItems.take(_maxUpcomingAudioPreviewControllers),
    ];
  }

  TimelineClip? _activeBaseClip(EditorTimeline timeline, Duration position) {
    return _baseSelectionAt(timeline, position)?.$2;
  }

  List<SubtitleEntry> _effectiveCaptions(
    EditorTimeline timeline,
    List<SubtitleEntry> entries,
  ) {
    if (identical(_cachedCaptionTimeline, timeline) &&
        identical(_cachedCaptionEntries, entries)) {
      return _effectiveCaptionCache;
    }
    _cachedCaptionTimeline = timeline;
    _cachedCaptionEntries = entries;
    _effectiveCaptionCache = SubtitleExportService.effectiveTimelineCaptions(
      timeline: timeline,
      entries: entries,
    );
    _effectiveCaptionIndex = _PreviewCaptionIndex(_effectiveCaptionCache);
    return _effectiveCaptionCache;
  }

  void _selectOverlayClip(_OverlayCanvasItem item) {
    final editorNotifier = ref.read(editorProvider.notifier);
    editorNotifier.selectTrack(item.track.id);
    editorNotifier.selectClip(item.clip.id);
    ref.read(subtitleProvider.notifier).selectEntry(null);
  }

  void _selectEffectClip(_EffectCanvasItem item) {
    final editorNotifier = ref.read(editorProvider.notifier);
    editorNotifier.selectTrack(item.trackId);
    editorNotifier.selectClip(item.clip.id);
    ref.read(subtitleProvider.notifier).selectEntry(null);
  }

  void _updateOverlayTransform(
    String clipId,
    TimelineTransform Function(TimelineTransform current) mapper,
  ) {
    final editorState = ref.read(editorProvider);
    final nextTracks = editorState.timeline.tracks.map((track) {
      final updatedClips = track.clips.map((clip) {
        if (clip.id != clipId) return clip;
        return clip.copyWith(transform: mapper(clip.transform));
      }).toList();
      return track.copyWith(clips: updatedClips);
    }).toList();

    ref
        .read(editorProvider.notifier)
        .setTimeline(editorState.timeline.copyWith(tracks: nextTracks));
  }

  double _snapDesignCoordinate({
    required double proposed,
    required double designExtent,
    required double viewportExtent,
    double objectHalfExtent = 0,
  }) {
    final canvas = ref.read(editorProvider).timeline.canvasSettings;
    if (!canvas.snapToGuides || viewportExtent <= 0) return proposed;

    final guides = <double>{0};
    if (canvas.showGrid) {
      final divisions = canvas.gridDivisions.clamp(2, 6);
      for (var index = 1; index < divisions; index++) {
        guides.add(-designExtent / 2 + designExtent * index / divisions);
      }
    }
    if (canvas.showSafeAreas) {
      guides
        ..add(-designExtent * 0.45)
        ..add(designExtent * 0.45)
        ..add(-designExtent * 0.40)
        ..add(designExtent * 0.40);
    }

    final candidates = <double>{...guides};
    if (objectHalfExtent > 0) {
      for (final guide in guides) {
        candidates
          ..add(guide - objectHalfExtent)
          ..add(guide + objectHalfExtent);
      }
    }
    final threshold = 8 * designExtent / viewportExtent;
    var nearest = proposed;
    var nearestDistance = threshold;
    for (final candidate in candidates) {
      final distance = (candidate - proposed).abs();
      if (distance <= nearestDistance) {
        nearest = candidate;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  void _beginSnappedDrag(TimelineTransform transform) {
    _dragSourceOffsetX = transform.offsetX;
    _dragSourceOffsetY = transform.offsetY;
    _freeTransformStartScale = transform.scale;
    _freeTransformStartRotation = transform.rotation;
  }

  void _endSnappedDrag() {
    _dragSourceOffsetX = null;
    _dragSourceOffsetY = null;
    _freeTransformStartScale = null;
    _freeTransformStartRotation = null;
    _freeTransformStartFontSize = null;
    ref.read(editorProvider.notifier).endTimelineGestureEdit();
  }

  bool _hasSoloMediaTrack(EditorTimeline timeline) {
    _ensurePreviewCaches(timeline);
    return _cachedHasSoloMediaTrack;
  }

  double _previewDuckingGain(TimelineClip clip, Duration position) {
    if (!clip.autoDuck || clip.duckAmount <= 0.001) return 1;
    final timeline = ref.read(editorProvider).timeline;
    final duckedGain = (1 - clip.duckAmount.clamp(0.0, 1.0)).toDouble();
    final positionMs = position.inMilliseconds;
    final clipStartMs = clip.startTime.inMilliseconds;
    final clipEndMs = clip.endTime.inMilliseconds;
    _ensurePreviewCaches(timeline);
    final intervals = _cachedDuckingIntervals.putIfAbsent(
      clip.id,
      () => buildPreviewDuckingIntervalsForTesting(
        timeline: timeline,
        clip: clip,
      ),
    );
    if (intervals.isEmpty) return 1;

    var gain = 1.0;
    for (final interval in intervals) {
      final startMs = interval.startMs;
      final endMs = interval.endMs;
      final attackStartMs = math.max(clipStartMs, startMs - 120);
      final releaseEndMs = math.min(clipEndMs, endMs + 180);
      if (positionMs < attackStartMs || positionMs > releaseEndMs) continue;

      double intervalGain;
      if (positionMs < startMs && startMs > attackStartMs) {
        final progress =
            (positionMs - attackStartMs) / (startMs - attackStartMs);
        intervalGain = 1 - (1 - duckedGain) * progress.clamp(0.0, 1.0);
      } else if (positionMs <= endMs) {
        intervalGain = duckedGain;
      } else if (releaseEndMs > endMs) {
        final progress = (positionMs - endMs) / (releaseEndMs - endMs);
        intervalGain = duckedGain + (1 - duckedGain) * progress.clamp(0.0, 1.0);
      } else {
        intervalGain = 1;
      }
      gain = math.min(gain, intervalGain);
    }
    return gain.clamp(0.0, 1.0).toDouble();
  }

  Widget _applyClipMediaEffects(
    Widget child,
    TimelineClip clip,
    Duration playbackPosition,
  ) {
    if (!clip.colorAdjustments.isNeutral) {
      child = ColorFiltered(
        colorFilter: ColorFilter.matrix(
          _colorMatrixForAdjustments(clip.colorAdjustments),
        ),
        child: child,
      );
    }
    child = _applyVignettePreview(child, clip.colorAdjustments);
    child = _applyChromaKeyPreview(child, clip);
    return _applyBlurPreview(child, _resolvedBlurAt(clip, playbackPosition));
  }

  Widget _buildOverlayAsset(
    _OverlayCanvasItem item,
    BoxConstraints constraints,
    PlaybackState playbackState,
    EditorTimeline timeline,
  ) {
    final canvasWidth = constraints.hasBoundedWidth
        ? math.max(0.0, constraints.maxWidth)
        : 611.0;
    final canvasHeight = constraints.hasBoundedHeight
        ? math.max(0.0, constraints.maxHeight)
        : 344.0;
    // Export prepares overlays inside a 36%-wide by 50%-high canvas box.
    // Keeping the same target geometry makes contain/cover/stretch meaningful
    // in preview and keeps their crop/distortion consistent with rendering.
    final baseWidth = canvasWidth * 0.36;
    final previewHeight = canvasHeight * 0.5;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = calculatePreviewDecodeDimensionForTesting(
      logicalExtent: baseWidth,
      devicePixelRatio: pixelRatio,
    );
    final cacheHeight = calculatePreviewDecodeDimensionForTesting(
      logicalExtent: previewHeight,
      devicePixelRatio: pixelRatio,
    );
    final previewUrl =
        item.asset.metadata['previewUrl'] as String? ?? item.asset.remoteUrl;
    final localPath = item.asset.sourcePath;
    final localFile = localPath == null ? null : File(localPath);
    final hasLocalFile = localPath != null && _cachedFileExists(localPath);
    final overlayFit = switch (item.clip.fitMode) {
      ClipFitMode.cover => BoxFit.cover,
      ClipFitMode.contain => BoxFit.contain,
      ClipFitMode.stretch => BoxFit.fill,
    };
    final animation = _resolveOverlayAnimation(
      item.clip,
      constraints,
      playbackState.position,
    );
    final transform = item.clip.transformAt(playbackState.position);
    final remoteMediaUrl = item.asset.remoteUrl ?? previewUrl;
    final isAnimatedImage =
        item.asset.type == EditorAssetType.gif ||
        (item.asset.type == EditorAssetType.sticker &&
            (_isGifSource(localPath) || _isGifSource(remoteMediaUrl)));
    Widget child;
    if (isAnimatedImage && (hasLocalFile || remoteMediaUrl != null)) {
      child = _TimelineGifPreview(
        key: _stableMediaPreviewKey(item.clip.id),
        filePath: hasLocalFile ? localFile!.path : null,
        remoteUrl: hasLocalFile ? null : remoteMediaUrl,
        clip: item.clip,
        playbackPosition: playbackState.position,
        width: baseWidth,
        height: previewHeight,
        fitMode: item.clip.fitMode,
        crop: item.clip.crop,
        label: item.clip.label,
        mediaEffectsBuilder: (media) =>
            _applyClipMediaEffects(media, item.clip, playbackState.position),
      );
    } else {
      child = switch (item.asset.type) {
        EditorAssetType.image || EditorAssetType.gif => ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: hasLocalFile
              ? Image.file(
                  localFile!,
                  width: baseWidth,
                  height: previewHeight,
                  fit: overlayFit,
                  cacheWidth: cacheWidth,
                  cacheHeight: cacheHeight,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                )
              : previewUrl != null
              ? Image.network(
                  previewUrl,
                  width: baseWidth,
                  height: previewHeight,
                  fit: overlayFit,
                  cacheWidth: cacheWidth,
                  cacheHeight: cacheHeight,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      _buildMissingOverlay(item.clip.label),
                )
              : _buildMissingOverlay(item.clip.label),
        ),
        EditorAssetType.video =>
          hasLocalFile
              ? _OverlayVideoPreview(
                  key: _stableMediaPreviewKey(item.clip.id),
                  videoPath: localFile!.path,
                  clip: item.clip,
                  playbackPosition: playbackState.position,
                  isPlaying: playbackState.isPlaying,
                  playbackSpeed: _playbackSpeed,
                  diagnostics: _performanceMonitor,
                  duckingGain: _previewDuckingGain(
                    item.clip,
                    playbackState.position,
                  ),
                  // The visual controller already owns one platform decoder
                  // and audio output. Reusing it for normal overlays avoids a
                  // second hidden decoder per active video. Freeze frames keep
                  // a separate audio-only controller so their audio can carry
                  // on while the visual frame is held.
                  isTrackAudible:
                      !item.clip.freezeFrame &&
                      previewVisualUsesEmbeddedAudioForTesting(
                        timeline: timeline,
                        visualTrack: item.track,
                        visualClip: item.clip,
                        position: playbackState.position,
                        hasSoloMediaTrack: _hasSoloMediaTrack(timeline),
                      ),
                  width: baseWidth,
                  height: previewHeight,
                  fitMode: item.clip.fitMode,
                  crop: item.clip.crop,
                  mediaEffectsBuilder: (media) => _applyClipMediaEffects(
                    media,
                    item.clip,
                    playbackState.position,
                  ),
                )
              : _buildMissingOverlay(item.clip.label),
        EditorAssetType.sticker => ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: hasLocalFile
              ? Image.file(
                  localFile!,
                  width: baseWidth,
                  height: previewHeight,
                  fit: overlayFit,
                  cacheWidth: cacheWidth,
                  cacheHeight: cacheHeight,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                )
              : previewUrl != null
              ? Image.network(
                  previewUrl,
                  width: baseWidth,
                  height: previewHeight,
                  fit: overlayFit,
                  cacheWidth: cacheWidth,
                  cacheHeight: cacheHeight,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      _buildMissingOverlay(item.clip.label),
                )
              : _buildMissingOverlay(item.clip.label),
        ),
        _ => _buildMissingOverlay(item.clip.label),
      };
    }
    child = SizedBox(width: baseWidth, height: previewHeight, child: child);
    // Video is cropped in source space before fitting. Applying this target-
    // space fallback as well would crop video overlays twice.
    if (item.asset.type != EditorAssetType.video && !isAnimatedImage) {
      child = _applyNormalizedCropPreview(child, item.clip.crop);
      child = _applyClipMediaEffects(child, item.clip, playbackState.position);
      // The bitmap/effect subtree is static while only its outer transition
      // transform changes. Isolating it avoids repainting color and blur work
      // for every animation tick.
      child = RepaintBoundary(
        key: ValueKey('static_overlay_${item.clip.id}'),
        child: child,
      );
    }
    child = Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(
        transform.flipX ? -1 : 1,
        transform.flipY ? -1 : 1,
        1,
      ),
      child: child,
    );

    return Transform.translate(
      offset: animation.offset,
      child: Opacity(
        opacity: (animation.opacity * transform.opacity).clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: transform.rotation + animation.rotation,
          child: Transform.scale(
            scale: (animation.scale * transform.scale).clamp(0.2, 4.0),
            child: child,
          ),
        ),
      ),
    );
  }

  _OverlayAnimationState _resolveOverlayAnimation(
    TimelineClip clip,
    BoxConstraints constraints,
    Duration position,
  ) {
    var opacity = 1.0;
    var scale = 1.0;
    var rotation = 0.0;
    var offset = Offset.zero;

    final elapsedMs = (position - clip.startTime).inMilliseconds
        .clamp(0, clip.duration.inMilliseconds)
        .toDouble();
    final remainingMs = (clip.endTime - position).inMilliseconds
        .clamp(0, clip.duration.inMilliseconds)
        .toDouble();

    void applyTransition(
      ClipTransition transition,
      double hiddenAmount, {
      required bool isOutro,
    }) {
      if (transition.type == TransitionType.none ||
          transition.type == TransitionType.cut ||
          hiddenAmount <= 0) {
        return;
      }

      final visibleAmount = (1 - hiddenAmount).clamp(0.0, 1.0).toDouble();
      final easedVisible =
          visibleAmount * visibleAmount * (3 - 2 * visibleAmount);
      final easedHidden = 1 - easedVisible;
      final alphaAmount = transition.type == TransitionType.fade
          ? visibleAmount
          : transition.type == TransitionType.dissolve
          ? visibleAmount * visibleAmount * (3 - 2 * visibleAmount)
          : easedVisible;
      opacity *= alphaAmount;
      switch (transition.type) {
        case TransitionType.fade:
        case TransitionType.dissolve:
          break;
        case TransitionType.zoom:
          scale *= 0.82 + 0.18 * easedVisible;
          break;
        case TransitionType.zoomOut:
          scale *= 1.18 - 0.18 * easedVisible;
          break;
        case TransitionType.pop:
          // A compact ease-out-back curve gives the preset a restrained
          // overshoot without allocating a separate animation controller.
          final shifted = visibleAmount - 1;
          final back =
              1 +
              2.70158 * shifted * shifted * shifted +
              1.70158 * shifted * shifted;
          scale *= 0.68 + 0.32 * back;
          break;
        case TransitionType.spin:
          scale *= 0.86 + 0.14 * easedVisible;
          rotation += (isOutro ? 1 : -1) * easedHidden * math.pi / 2;
          break;
        case TransitionType.slideLeft:
          offset += Offset(-constraints.maxWidth * easedHidden, 0);
          break;
        case TransitionType.slideRight:
          offset += Offset(constraints.maxWidth * easedHidden, 0);
          break;
        case TransitionType.slideUp:
          offset += Offset(0, -constraints.maxHeight * easedHidden);
          break;
        case TransitionType.slideDown:
          offset += Offset(0, constraints.maxHeight * easedHidden);
          break;
        case TransitionType.slideUpLeft:
          offset += Offset(
            -constraints.maxWidth * easedHidden,
            -constraints.maxHeight * easedHidden,
          );
          break;
        case TransitionType.slideUpRight:
          offset += Offset(
            constraints.maxWidth * easedHidden,
            -constraints.maxHeight * easedHidden,
          );
          break;
        case TransitionType.none:
        case TransitionType.cut:
          break;
      }
    }

    final introDuration = clip.effectiveIntroTransitionMs;
    if (introDuration > 0 && elapsedMs < introDuration) {
      final hiddenAmount = 1 - (elapsedMs / introDuration).clamp(0.0, 1.0);
      applyTransition(clip.introTransition, hiddenAmount, isOutro: false);
    }

    final outroDuration = clip.effectiveOutroTransitionMs;
    if (outroDuration > 0 && remainingMs < outroDuration) {
      final hiddenAmount = 1 - (remainingMs / outroDuration).clamp(0.0, 1.0);
      applyTransition(clip.outroTransition, hiddenAmount, isOutro: true);
    }

    return _OverlayAnimationState(
      opacity: opacity.clamp(0.0, 1.0),
      scale: scale.clamp(0.2, 4.0),
      rotation: rotation,
      offset: offset,
    );
  }

  Widget _buildMissingOverlay(String label) {
    return Container(
      width: 140,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: kTextPrimary, fontSize: 12),
      ),
    );
  }

  Widget _buildBaseVideoLayer({
    required VideoPlayerController controller,
    required TimelineClip clip,
    required BoxConstraints constraints,
    required Duration playbackPosition,
  }) {
    final animation = _resolveOverlayAnimation(
      clip,
      constraints,
      playbackPosition,
    );
    final fit = switch (clip.fitMode) {
      ClipFitMode.cover => BoxFit.cover,
      ClipFitMode.contain => BoxFit.contain,
      ClipFitMode.stretch => BoxFit.fill,
    };
    final videoSize = controller.value.size;
    final sourceWidth = videoSize.width <= 0 ? 16.0 : videoSize.width;
    final sourceHeight = videoSize.height <= 0 ? 9.0 : videoSize.height;
    final transform = clip.transformAt(playbackPosition);
    Widget source = SizedBox(
      width: sourceWidth,
      height: sourceHeight,
      child: VideoPlayer(controller),
    );
    source = _cropSourcePreview(
      child: source,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      crop: clip.crop,
    );

    Widget child = SizedBox.expand(
      child: FittedBox(fit: fit, clipBehavior: Clip.hardEdge, child: source),
    );
    child = _applyClipMediaEffects(child, clip, playbackPosition);
    child = Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(
        transform.flipX ? -1 : 1,
        transform.flipY ? -1 : 1,
        1,
      ),
      child: child,
    );
    child = Transform.rotate(
      angle: transform.rotation + animation.rotation,
      child: child,
    );
    child = Transform.scale(
      scale: (animation.scale * transform.scale).clamp(0.2, 4),
      child: child,
    );
    child = Opacity(
      opacity: (animation.opacity * transform.opacity).clamp(0.0, 1.0),
      child: child,
    );
    return Transform.translate(
      offset:
          animation.offset +
          Offset(
            transform.offsetX * constraints.maxWidth / kTimelineDesignWidth,
            transform.offsetY * constraints.maxHeight / kTimelineDesignHeight,
          ),
      child: child,
    );
  }

  Widget _buildBaseAssetLayer({
    required EditorTimeline timeline,
    required TimelineClip clip,
    required BoxConstraints constraints,
    required Duration playbackPosition,
  }) {
    final asset = _cachedAssetForClip(timeline, clip);
    if (asset == null) return _buildMissingOverlay(clip.label);
    final localPath = asset.sourcePath;
    final hasLocalFile =
        localPath != null &&
        localPath.isNotEmpty &&
        _cachedFileExists(localPath);
    final previewUrl =
        asset.metadata['previewUrl'] as String? ?? asset.remoteUrl;
    final remoteMediaUrl = asset.remoteUrl ?? previewUrl;
    final isAnimatedImage =
        clip.type == TimelineTrackType.gif ||
        asset.type == EditorAssetType.gif ||
        (asset.type == EditorAssetType.sticker &&
            (_isGifSource(localPath) || _isGifSource(remoteMediaUrl)));
    final fit = switch (clip.fitMode) {
      ClipFitMode.cover => BoxFit.cover,
      ClipFitMode.contain => BoxFit.contain,
      ClipFitMode.stretch => BoxFit.fill,
    };
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = calculatePreviewDecodeDimensionForTesting(
      logicalExtent: constraints.maxWidth,
      devicePixelRatio: pixelRatio,
    );
    final cacheHeight = calculatePreviewDecodeDimensionForTesting(
      logicalExtent: constraints.maxHeight,
      devicePixelRatio: pixelRatio,
    );

    Widget child;
    if (isAnimatedImage && (hasLocalFile || remoteMediaUrl != null)) {
      child = _TimelineGifPreview(
        key: _stableMediaPreviewKey(clip.id),
        filePath: hasLocalFile ? localPath : null,
        remoteUrl: hasLocalFile ? null : remoteMediaUrl,
        clip: clip,
        playbackPosition: playbackPosition,
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        fitMode: clip.fitMode,
        crop: clip.crop,
        label: clip.label,
        borderRadius: BorderRadius.zero,
        mediaEffectsBuilder: (media) =>
            _applyClipMediaEffects(media, clip, playbackPosition),
      );
    } else if (hasLocalFile) {
      child = Image.file(
        File(localPath),
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        fit: fit,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _buildMissingOverlay(clip.label),
      );
      child = _applyNormalizedCropPreview(child, clip.crop);
      child = _applyClipMediaEffects(child, clip, playbackPosition);
    } else if (previewUrl != null) {
      child = Image.network(
        previewUrl,
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        fit: fit,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _buildMissingOverlay(clip.label),
      );
      child = _applyNormalizedCropPreview(child, clip.crop);
      child = _applyClipMediaEffects(child, clip, playbackPosition);
    } else {
      child = _buildMissingOverlay(clip.label);
    }

    final animation = _resolveOverlayAnimation(
      clip,
      constraints,
      playbackPosition,
    );
    final transform = clip.transformAt(playbackPosition);
    child = Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(
        transform.flipX ? -1 : 1,
        transform.flipY ? -1 : 1,
        1,
      ),
      child: child,
    );
    child = Transform.rotate(
      angle: transform.rotation + animation.rotation,
      child: child,
    );
    child = Transform.scale(
      scale: (animation.scale * transform.scale).clamp(0.2, 4),
      child: child,
    );
    child = Opacity(
      opacity: (animation.opacity * transform.opacity).clamp(0.0, 1.0),
      child: child,
    );
    return Transform.translate(
      offset:
          animation.offset +
          Offset(
            transform.offsetX * constraints.maxWidth / kTimelineDesignWidth,
            transform.offsetY * constraints.maxHeight / kTimelineDesignHeight,
          ),
      child: child,
    );
  }

  Widget _buildTextVisualLayer(
    _TextCanvasItem item,
    BoxConstraints constraints,
    Duration playbackPosition,
  ) {
    final style =
        item.clip.subtitleStyle ??
        const SubtitleStyleModel(
          position: SubtitlePosition.center,
          fontSize: 32,
        );
    final transform = item.clip.transformAt(playbackPosition);
    final previewEntry = SubtitleEntry(
      id: item.clip.id,
      startTime: item.clip.startTime,
      endTime: item.clip.endTime,
      text: item.clip.text ?? item.clip.label,
      styleOverride: style,
    );
    Widget text = AnimatedSubtitleOverlay(
      entry: previewEntry,
      globalStyle: style,
      currentPosition: playbackPosition,
      scaleFactor: constraints.maxHeight / kTimelineDesignHeight,
    );
    text = Transform.scale(
      scale: transform.scale.clamp(0.25, 4.0),
      child: text,
    );
    text = Transform.rotate(angle: transform.rotation, child: text);
    text = Opacity(opacity: transform.opacity.clamp(0.0, 1.0), child: text);
    return Align(
      child: Transform.translate(
        offset: Offset(
          transform.offsetX * constraints.maxWidth / kTimelineDesignWidth,
          transform.offsetY * constraints.maxHeight / kTimelineDesignHeight,
        ),
        child: text,
      ),
    );
  }

  Widget _buildSubtitleVisualLayer({
    required SubtitleEntry entry,
    required SubtitleState subtitleState,
    required BoxConstraints constraints,
    required Duration playbackPosition,
  }) {
    final style = entry.styleOverride ?? subtitleState.globalStyle;
    final effectiveOffsetY = style.verticalOffset + style.offsetY;
    return Align(
      alignment: _alignmentForPosition(style.position),
      child: Transform.translate(
        offset: Offset(
          style.offsetX * constraints.maxWidth / kTimelineDesignWidth,
          effectiveOffsetY * constraints.maxHeight / kTimelineDesignHeight,
        ),
        child: AnimatedSubtitleOverlay(
          entry: entry,
          globalStyle: subtitleState.globalStyle,
          currentPosition: playbackPosition,
          scaleFactor: constraints.maxHeight / kTimelineDesignHeight,
        ),
      ),
    );
  }

  Widget _buildTrackOrderedComposition({
    required EditorTimeline timeline,
    required BoxConstraints constraints,
    required PlaybackState playbackState,
    required SubtitleState subtitleState,
    required VideoPlayerController? controller,
    required TimelineClip? activeBaseClip,
    required bool controllerReady,
    required List<_OverlayCanvasItem> overlays,
    required List<_EffectCanvasItem> effects,
    required List<_TextCanvasItem> textItems,
    required List<SubtitleEntry> activeSubtitles,
  }) {
    final overlaysByTrack = <String, List<_OverlayCanvasItem>>{};
    for (final item in overlays) {
      overlaysByTrack.putIfAbsent(item.track.id, () => []).add(item);
    }
    final effectsByTrack = <String, List<_EffectCanvasItem>>{};
    for (final item in effects) {
      effectsByTrack.putIfAbsent(item.trackId, () => []).add(item);
    }
    final textByTrack = <String, List<_TextCanvasItem>>{};
    for (final item in textItems) {
      textByTrack.putIfAbsent(item.trackId, () => []).add(item);
    }
    final subtitleTrackByClipId = <String, String>{
      for (final track in timeline.tracks)
        if (track.type == TimelineTrackType.subtitle)
          for (final clip in track.clips) clip.id: track.id,
    };
    final subtitlesByTrack = <String, List<SubtitleEntry>>{};
    for (final entry in activeSubtitles) {
      final trackId = subtitleTrackByClipId[entry.id];
      if (trackId != null) {
        subtitlesByTrack.putIfAbsent(trackId, () => []).add(entry);
      }
    }

    Widget composed = ColoredBox(
      key: const ValueKey('preview-composed-media-canvas'),
      color: activeBaseClip?.mayRevealCanvasBackground == true
          ? Colors.black
          : timeline.canvasSettings.backgroundColor,
    );

    for (final track in timeline.visualTracksInPaintOrder) {
      if (track.section == TimelineTrackSection.baseVideo &&
          activeBaseClip != null &&
          activeBaseClip.trackId == track.id) {
        final baseLayer = activeBaseClip.type == TimelineTrackType.video
            ? controllerReady && controller != null
                  ? _buildBaseVideoLayer(
                      controller: controller,
                      clip: activeBaseClip,
                      constraints: constraints,
                      playbackPosition: playbackState.position,
                    )
                  : null
            : _buildBaseAssetLayer(
                timeline: timeline,
                clip: activeBaseClip,
                constraints: constraints,
                playbackPosition: playbackState.position,
              );
        if (baseLayer != null) {
          composed = Stack(
            fit: StackFit.expand,
            children: [composed, baseLayer],
          );
        }
      }

      final operations =
          <({int layer, Duration start, Object item})>[
            for (final item in overlaysByTrack[track.id] ?? const [])
              (layer: item.clip.layer, start: item.clip.startTime, item: item),
            for (final item in effectsByTrack[track.id] ?? const [])
              (layer: item.clip.layer, start: item.clip.startTime, item: item),
            for (final item in textByTrack[track.id] ?? const [])
              (layer: item.clip.layer, start: item.clip.startTime, item: item),
          ]..sort((a, b) {
            final layer = a.layer.compareTo(b.layer);
            return layer != 0 ? layer : a.start.compareTo(b.start);
          });

      for (final operation in operations) {
        final item = operation.item;
        if (item is _EffectCanvasItem) {
          composed = _applyTimelineEffectsToMedia(composed, [
            item,
          ], playbackState.position);
        } else if (item is _OverlayCanvasItem) {
          composed = Stack(
            fit: StackFit.expand,
            children: [
              composed,
              Align(
                child: Transform.translate(
                  offset: Offset(
                    item.clip.transformAt(playbackState.position).offsetX *
                        constraints.maxWidth /
                        kTimelineDesignWidth,
                    item.clip.transformAt(playbackState.position).offsetY *
                        constraints.maxHeight /
                        kTimelineDesignHeight,
                  ),
                  child: _buildOverlayAsset(
                    item,
                    constraints,
                    playbackState,
                    timeline,
                  ),
                ),
              ),
            ],
          );
        } else if (item is _TextCanvasItem) {
          composed = Stack(
            fit: StackFit.expand,
            children: [
              composed,
              _buildTextVisualLayer(item, constraints, playbackState.position),
            ],
          );
        }
      }

      for (final entry in subtitlesByTrack[track.id] ?? const []) {
        composed = Stack(
          fit: StackFit.expand,
          children: [
            composed,
            _buildSubtitleVisualLayer(
              entry: entry,
              subtitleState: subtitleState,
              constraints: constraints,
              playbackPosition: playbackState.position,
            ),
          ],
        );
      }
    }

    return KeyedSubtree(
      key: const ValueKey('preview-composed-effect-output'),
      child: composed,
    );
  }

  Widget _applyTimelineEffectsToMedia(
    Widget child,
    List<_EffectCanvasItem> activeEffects,
    Duration playbackPosition,
  ) {
    var effected = child;
    for (final effect in activeEffects) {
      switch (effect.clip.effectKind) {
        case TimelineEffectKind.filter:
          final adjustments = effect.clip.colorAdjustments;
          if (!adjustments.isNeutral) {
            effected = ColorFiltered(
              colorFilter: ColorFilter.matrix(
                _colorMatrixForAdjustments(adjustments),
              ),
              child: effected,
            );
            effected = _applyVignettePreview(effected, adjustments);
          }
          break;
        case TimelineEffectKind.blur:
          final resolvedBlur = _resolvedBlurAt(effect.clip, playbackPosition);
          effected = resolvedBlur.mode == ClipBlurMode.region
              ? _applyTransformedRegionBlurPreview(
                  effected,
                  effect.clip,
                  resolvedBlur,
                  playbackPosition,
                )
              : _applyBlurPreview(effected, resolvedBlur);
          break;
        case null:
          break;
      }
    }
    return effected;
  }

  Widget _applyTransformedRegionBlurPreview(
    Widget child,
    TimelineClip clip,
    ClipBlurSettings blur,
    Duration playbackPosition,
  ) {
    if (!blur.isEnabled) return child;
    final transform = clip.transformAt(playbackPosition);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth ||
            !constraints.hasBoundedHeight ||
            constraints.maxWidth <= 0 ||
            constraints.maxHeight <= 0) {
          return child;
        }
        final scale = transform.scale.clamp(0.2, 4.0).toDouble();
        final width = constraints.maxWidth * blur.safeRegionWidth * scale;
        final height = constraints.maxHeight * blur.safeRegionHeight * scale;
        final centerX =
            constraints.maxWidth *
                (blur.safeRegionX + blur.safeRegionWidth / 2) +
            transform.offsetX * constraints.maxWidth / kTimelineDesignWidth;
        final centerY =
            constraints.maxHeight *
                (blur.safeRegionY + blur.safeRegionHeight / 2) +
            transform.offsetY * constraints.maxHeight / kTimelineDesignHeight;
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            child,
            Positioned(
              left: centerX - width / 2,
              top: centerY - height / 2,
              width: width,
              height: height,
              child: Transform.rotate(
                angle: transform.rotation,
                child: ClipRect(
                  child: BackdropFilter(
                    key: ValueKey('effect_blur_region_${clip.id}'),
                    filter: ui.ImageFilter.blur(
                      sigmaX: blur.safeStrength,
                      sigmaY: blur.safeStrength,
                      tileMode: TileMode.clamp,
                    ),
                    child: const ColoredBox(color: Colors.transparent),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEffectLayer({
    required List<_EffectCanvasItem> effects,
    required double aspectRatio,
    required String? selectedClipId,
  }) {
    return _CanvasBoundLayer(
      aspectRatio: aspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            fit: StackFit.expand,
            children: effects.map((item) {
              final clip = item.clip;
              if (clip.effectKind == TimelineEffectKind.filter) {
                return const SizedBox.shrink();
              }

              final blur = clip.blur;
              if (clip.effectKind != TimelineEffectKind.blur ||
                  !blur.isEnabled) {
                return const SizedBox.shrink();
              }
              if (blur.mode == ClipBlurMode.full) {
                return const SizedBox.shrink();
              }

              if (blur.mode != ClipBlurMode.region) {
                return const SizedBox.shrink();
              }
              final isSelected = selectedClipId == clip.id;
              final transform = clip.transform;
              return Positioned(
                left: constraints.maxWidth * blur.safeRegionX,
                top: constraints.maxHeight * blur.safeRegionY,
                width: constraints.maxWidth * blur.safeRegionWidth,
                height: constraints.maxHeight * blur.safeRegionHeight,
                child: Transform.translate(
                  offset: Offset(
                    transform.offsetX *
                        constraints.maxWidth /
                        kTimelineDesignWidth,
                    transform.offsetY *
                        constraints.maxHeight /
                        kTimelineDesignHeight,
                  ),
                  child: Transform.rotate(
                    angle: transform.rotation,
                    child: Transform.scale(
                      scale: transform.scale.clamp(0.2, 4.0),
                      child: _OverlayTransformBox(
                        isSelected: isSelected,
                        onTap: () => _selectEffectClip(item),
                        onMoveStart: () {
                          _selectEffectClip(item);
                          _beginSnappedDrag(transform);
                          ref
                              .read(editorProvider.notifier)
                              .beginTimelineGestureEdit();
                        },
                        onMoveUpdate: (delta) {
                          _updateOverlayTransform(clip.id, (current) {
                            final proposedX =
                                (_dragSourceOffsetX ?? current.offsetX) +
                                delta.dx *
                                    kTimelineDesignWidth /
                                    constraints.maxWidth;
                            final proposedY =
                                (_dragSourceOffsetY ?? current.offsetY) +
                                delta.dy *
                                    kTimelineDesignHeight /
                                    constraints.maxHeight;
                            _dragSourceOffsetX = proposedX;
                            _dragSourceOffsetY = proposedY;
                            return current.copyWith(
                              offsetX: proposedX,
                              offsetY: proposedY,
                            );
                          });
                        },
                        onMoveEnd: _endSnappedDrag,
                        onScaleFactorUpdate: (factor) {
                          _updateOverlayTransform(
                            clip.id,
                            (current) => current.copyWith(
                              scale:
                                  ((_freeTransformStartScale ?? current.scale) *
                                          factor)
                                      .clamp(0.2, 4.0)
                                      .toDouble(),
                            ),
                          );
                        },
                        onRotationUpdate: (rotation) {
                          _updateOverlayTransform(
                            clip.id,
                            (current) => current.copyWith(
                              rotation:
                                  (_freeTransformStartRotation ??
                                      current.rotation) +
                                  rotation,
                            ),
                          );
                        },
                        child: ColoredBox(
                          color: isSelected
                              ? kAccent.withValues(alpha: 0.035)
                              : Colors.transparent,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  List<double> _colorMatrixForAdjustments(ClipColorAdjustments adjustments) {
    return buildPreviewColorMatrixForTesting(adjustments);
  }

  ClipBlurSettings _resolvedBlurAt(
    TimelineClip clip,
    Duration playbackPosition,
  ) {
    final strength = clip.keyframedValue(
      TimelineKeyframeProperty.blurStrength,
      playbackPosition,
      fallback: clip.blur.safeStrength,
    );
    return clip.blur.copyWith(strength: strength.clamp(0.0, 30.0).toDouble());
  }

  Widget _applyVignettePreview(Widget child, ClipColorAdjustments adjustments) {
    final vignette = adjustments.vignette.clamp(0.0, 1.0).toDouble();
    if (vignette <= 0.001) return child;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 0.78,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: vignette * 0.68),
                  ],
                  stops: const [0.52, 1],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _applyChromaKeyPreview(Widget child, TimelineClip clip) {
    if (!clip.chromaKeyEnabled) return child;
    final argb = clip.chromaKeyColor.toARGB32();
    final red = ((argb >> 16) & 0xff).toDouble();
    final green = ((argb >> 8) & 0xff).toDouble();
    final blue = (argb & 0xff).toDouble();
    final mean = (red + green + blue) / 3;
    var redWeight = red - mean;
    var greenWeight = green - mean;
    var blueWeight = blue - mean;
    final chromaMagnitude =
        redWeight.abs() + greenWeight.abs() + blueWeight.abs();

    if (chromaMagnitude < 1) {
      // Achromatic keys use luminance distance; chromatic keys use their
      // direction away from neutral gray. A color matrix cannot calculate a
      // true RGB-radius key, but this gives stable, immediate alpha feedback
      // while FFmpeg performs the exact radial key during export.
      final direction = mean >= 127.5 ? 1.0 : -1.0;
      redWeight = 0.2126 * direction;
      greenWeight = 0.7152 * direction;
      blueWeight = 0.0722 * direction;
    } else {
      redWeight /= chromaMagnitude;
      greenWeight /= chromaMagnitude;
      blueWeight /= chromaMagnitude;
    }

    final keyProjection =
        redWeight * red + greenWeight * green + blueWeight * blue;
    final similarity = clip.chromaKeySimilarity.clamp(0.01, 1.0).toDouble();
    const softness = 0.08;
    const alphaGain = 1 / softness;
    final alphaOffset = alphaGain * (keyProjection - similarity * 255) - 255;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix([
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        -alphaGain * redWeight,
        -alphaGain * greenWeight,
        -alphaGain * blueWeight,
        1,
        alphaOffset,
      ]),
      child: child,
    );
  }

  Widget _applyBlurPreview(Widget child, ClipBlurSettings blur) {
    return buildBlurredMediaPreviewForTesting(child: child, blur: blur);
  }

  Widget _applyNormalizedCropPreview(Widget child, ClipCropSettings crop) {
    if (crop.isIdentity) return child;
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.hasBoundedWidth ||
              !constraints.hasBoundedHeight ||
              constraints.maxWidth <= 0 ||
              constraints.maxHeight <= 0) {
            return child;
          }
          final scaleX = 1 / crop.visibleWidth;
          final scaleY = 1 / crop.visibleHeight;
          final matrix = Matrix4.identity()
            ..setEntry(0, 0, scaleX)
            ..setEntry(1, 1, scaleY)
            ..setEntry(0, 3, -constraints.maxWidth * crop.safeLeft * scaleX)
            ..setEntry(1, 3, -constraints.maxHeight * crop.safeTop * scaleY);
          return Transform(
            alignment: Alignment.topLeft,
            transform: matrix,
            child: child,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playbackProvider.select((state) => state.seekRequestId ?? 0), (
      _,
      requestId,
    ) {
      if (!_initialized || !mounted) return;
      final playbackState = ref.read(playbackProvider);
      final target = playbackState.pendingSeekPosition;
      if (target == null) return;
      unawaited(() async {
        await _seekTimelinePosition(target, forceSeek: true);
        if (!mounted) return;
        ref.read(playbackProvider.notifier).acknowledgeSeek(requestId);
      }());
    });
    ref.listen(editorProvider.select((state) => state.editRevision), (_, _) {
      if (!_initialized || !mounted) return;
      unawaited(
        _seekTimelinePosition(
          ref.read(playbackProvider).position,
          forceSeek: false,
        ),
      );
    });

    final playbackState = ref.watch(playbackProvider);
    final subtitleState = ref.watch(subtitleProvider);
    final editorState = ref.watch(editorProvider);
    _ensurePreviewCaches(
      editorState.timeline,
      editRevision: editorState.editRevision,
    );
    final workspaceLoop = editorState.timeline.workspaceSettings.loopPlayback;
    final activeOverlayItems = _activeOverlayItems(
      editorState.timeline,
      playbackState.position,
    );
    final activeEffectItems = _activeEffectItems(
      editorState.timeline,
      playbackState.position,
    );
    final activeTextItems = _activeTextItems(
      editorState.timeline,
      playbackState.position,
    );
    final activeBaseClip = _activeBaseClip(
      editorState.timeline,
      playbackState.position,
    );
    final baseAudioMonitor = activeBaseClip == null
        ? null
        : resolvePreviewBaseAudioMonitorForTesting(
            timeline: editorState.timeline,
            baseClip: activeBaseClip,
            position: playbackState.position,
          );
    final activeAudioItems = _activeAudioItems(
      editorState.timeline,
      playbackState.position,
      baseAudioMonitor?.clip.id,
    );
    _effectiveCaptions(editorState.timeline, subtitleState.entries);
    final controller = _controller;
    final controllerPath = _controllerPath;
    final controllerTrack = _controllerTrack;
    _updateOwnedDecoderDiagnostics(playbackState.position);
    final controllerReady =
        controller != null &&
        controller.value.isInitialized &&
        activeBaseClip != null &&
        _controllerClip?.id == activeBaseClip.id;
    final previewAspectRatio =
        widget.targetAspectRatio ??
        (controllerReady ? controller.value.aspectRatio : 16 / 9);

    final activeSubtitles = _effectiveCaptionIndex.activeAt(
      playbackState.position,
    );
    final activeSubtitle =
        activeSubtitles
            .where((entry) => entry.id == subtitleState.selectedEntryId)
            .firstOrNull ??
        activeSubtitles.firstOrNull;
    final needsSmoothPreviewClock =
        (activeBaseClip != null &&
            (activeBaseClip.type == TimelineTrackType.gif ||
                _clipHasFlutterDrivenMotionAt(
                  activeBaseClip,
                  playbackState.position,
                ))) ||
        activeOverlayItems.any(
          (item) =>
              item.asset.type == EditorAssetType.gif ||
              _clipHasFlutterDrivenMotionAt(item.clip, playbackState.position),
        ) ||
        activeEffectItems.any(
          (item) =>
              _clipHasFlutterDrivenMotionAt(item.clip, playbackState.position),
        ) ||
        activeTextItems.any(
          (item) =>
              item.clip.subtitleStyle?.animationPreset != null ||
              _clipHasFlutterDrivenMotionAt(item.clip, playbackState.position),
        ) ||
        activeSubtitles.any(
          (entry) =>
              (entry.styleOverride?.animationPreset ??
                  subtitleState.globalStyle.animationPreset) !=
              null,
        );

    return LayoutBuilder(
      builder: (context, panelConstraints) {
        final boundedPanelHeight =
            panelConstraints.hasBoundedHeight &&
                panelConstraints.maxHeight.isFinite
            ? math.max(0.0, panelConstraints.maxHeight)
            : null;
        final compactControls =
            boundedPanelHeight != null && boundedPanelHeight < 420;
        final naturalFooterHeight = compactControls ? 60.0 : 104.0;
        final footerViewportHeight = boundedPanelHeight == null
            ? naturalFooterHeight
            : math.min(naturalFooterHeight, boundedPanelHeight / 2);
        return Container(
          color: kBackground,
          child: Column(
            children: [
              // Video with subtitle overlay
              Expanded(
                child: _initialized
                    ? Stack(
                        alignment: Alignment.center,
                        children: [
                          Center(
                            child: AspectRatio(
                              aspectRatio: previewAspectRatio,
                              child: ClipRect(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    return PreviewPlaybackClock(
                                      position: playbackState.position,
                                      duration: playbackState.duration,
                                      isPlaying: playbackState.isPlaying,
                                      enabled: needsSmoothPreviewClock,
                                      playbackSpeed: _playbackSpeed,
                                      builder: (context, previewPosition) {
                                        return _buildTrackOrderedComposition(
                                          timeline: editorState.timeline,
                                          constraints: constraints,
                                          playbackState: playbackState.copyWith(
                                            position: previewPosition,
                                          ),
                                          subtitleState: subtitleState,
                                          controller: controller,
                                          activeBaseClip: activeBaseClip,
                                          controllerReady: controllerReady,
                                          overlays: activeOverlayItems,
                                          effects: activeEffectItems,
                                          textItems: activeTextItems,
                                          activeSubtitles: activeSubtitles,
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                          if (_showPerformanceDiagnostics)
                            Positioned(
                              left: 10,
                              top: 10,
                              child: _PreviewDiagnosticsOverlay(
                                snapshot: _performanceMonitor.snapshot(),
                                onReset: () {
                                  _performanceMonitor.resetCounters();
                                  setState(() {});
                                },
                              ),
                            ),
                          if (_previewError != null)
                            _CanvasBoundLayer(
                              aspectRatio: previewAspectRatio,
                              child: Center(
                                child: Container(
                                  margin: const EdgeInsets.all(20),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 11,
                                  ),
                                  decoration: BoxDecoration(
                                    color: kBackground.withValues(alpha: 0.78),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: kWarning.withValues(alpha: 0.45),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.warning_amber_rounded,
                                        color: kWarning,
                                        size: 17,
                                      ),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          _previewError!,
                                          style: const TextStyle(
                                            color: kTextPrimary,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          Positioned.fill(
                            child: GestureDetector(
                              onTap: _togglePlayPause,
                              behavior: HitTestBehavior.translucent,
                              child: const SizedBox.expand(),
                            ),
                          ),
                          if (controllerReady &&
                              (activeBaseClip.fitMode == ClipFitMode.contain ||
                                  activeBaseClip.transform.scale < 0.999 ||
                                  activeBaseClip.transform.rotation.abs() >
                                      0.0001 ||
                                  activeBaseClip.transform.offsetX.abs() >
                                      0.0001 ||
                                  activeBaseClip.transform.offsetY.abs() >
                                      0.0001))
                            _CanvasBoundLayer(
                              aspectRatio: previewAspectRatio,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final sourceSize = controller.value.size;
                                  final safeSourceSize = Size(
                                    sourceSize.width <= 0
                                        ? constraints.maxWidth
                                        : sourceSize.width,
                                    sourceSize.height <= 0
                                        ? constraints.maxHeight
                                        : sourceSize.height,
                                  );
                                  final destination = applyBoxFit(
                                    BoxFit.contain,
                                    safeSourceSize,
                                    constraints.biggest,
                                  ).destination;
                                  final transform = activeBaseClip.transformAt(
                                    playbackState.position,
                                  );
                                  final isSelected =
                                      editorState.selectedClipId ==
                                      activeBaseClip.id;
                                  return Align(
                                    child: Transform.translate(
                                      offset: Offset(
                                        transform.offsetX *
                                            constraints.maxWidth /
                                            kTimelineDesignWidth,
                                        transform.offsetY *
                                            constraints.maxHeight /
                                            kTimelineDesignHeight,
                                      ),
                                      child: Transform.rotate(
                                        angle: transform.rotation,
                                        child: Transform.scale(
                                          scale: transform.scale.clamp(
                                            0.2,
                                            4.0,
                                          ),
                                          child: _OverlayTransformBox(
                                            isSelected: isSelected,
                                            onTap: () {
                                              final track = controllerTrack;
                                              if (track == null) return;
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectTrack(track.id);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectClip(
                                                    activeBaseClip.id,
                                                  );
                                            },
                                            onMoveStart: () {
                                              final track = controllerTrack;
                                              if (track == null ||
                                                  track.isLocked) {
                                                return;
                                              }
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectTrack(track.id);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectClip(
                                                    activeBaseClip.id,
                                                  );
                                              _beginSnappedDrag(transform);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .beginTimelineGestureEdit();
                                            },
                                            onMoveUpdate: (delta) {
                                              if (controllerTrack?.isLocked ==
                                                  true) {
                                                return;
                                              }
                                              _updateOverlayTransform(
                                                activeBaseClip.id,
                                                (current) {
                                                  final proposedX =
                                                      (_dragSourceOffsetX ??
                                                          current.offsetX) +
                                                      delta.dx *
                                                          kTimelineDesignWidth /
                                                          constraints.maxWidth;
                                                  final proposedY =
                                                      (_dragSourceOffsetY ??
                                                          current.offsetY) +
                                                      delta.dy *
                                                          kTimelineDesignHeight /
                                                          constraints.maxHeight;
                                                  _dragSourceOffsetX =
                                                      proposedX;
                                                  _dragSourceOffsetY =
                                                      proposedY;
                                                  return current.copyWith(
                                                    offsetX: proposedX,
                                                    offsetY: proposedY,
                                                  );
                                                },
                                              );
                                            },
                                            onMoveEnd: () {
                                              if (_freeTransformStartScale !=
                                                  null) {
                                                _endSnappedDrag();
                                              }
                                            },
                                            onScaleFactorUpdate: (factor) {
                                              if (controllerTrack?.isLocked ==
                                                  true) {
                                                return;
                                              }
                                              _updateOverlayTransform(
                                                activeBaseClip.id,
                                                (current) => current.copyWith(
                                                  scale:
                                                      ((_freeTransformStartScale ??
                                                                  current
                                                                      .scale) *
                                                              factor)
                                                          .clamp(0.2, 4.0)
                                                          .toDouble(),
                                                ),
                                              );
                                            },
                                            onRotationUpdate: (rotation) {
                                              if (controllerTrack?.isLocked ==
                                                  true) {
                                                return;
                                              }
                                              _updateOverlayTransform(
                                                activeBaseClip.id,
                                                (current) => current.copyWith(
                                                  rotation:
                                                      (_freeTransformStartRotation ??
                                                          current.rotation) +
                                                      rotation,
                                                ),
                                              );
                                            },
                                            child: SizedBox(
                                              key: ValueKey(
                                                'preview-source-interaction-${activeBaseClip.id}',
                                              ),
                                              width: destination.width,
                                              height: destination.height,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          if (activeOverlayItems.isNotEmpty)
                            _CanvasBoundLayer(
                              aspectRatio: previewAspectRatio,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  const maxX = kTimelineDesignWidth / 2 - 28;
                                  const maxY = kTimelineDesignHeight / 2 - 28;

                                  return Stack(
                                    children: activeOverlayItems.map((item) {
                                      final isSelected =
                                          editorState.selectedClipId ==
                                          item.clip.id;
                                      final transform = item.clip.transformAt(
                                        playbackState.position,
                                      );
                                      return Align(
                                        child: Transform.translate(
                                          offset: Offset(
                                            transform.offsetX.clamp(
                                                  -maxX,
                                                  maxX,
                                                ) *
                                                constraints.maxWidth /
                                                kTimelineDesignWidth,
                                            transform.offsetY.clamp(
                                                  -maxY,
                                                  maxY,
                                                ) *
                                                constraints.maxHeight /
                                                kTimelineDesignHeight,
                                          ),
                                          child: _OverlayTransformBox(
                                            isSelected: isSelected,
                                            onTap: () =>
                                                _selectOverlayClip(item),
                                            onMoveStart: () {
                                              _selectOverlayClip(item);
                                              _beginSnappedDrag(transform);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .beginTimelineGestureEdit();
                                            },
                                            onMoveUpdate: (delta) {
                                              _updateOverlayTransform(item.clip.id, (
                                                current,
                                              ) {
                                                final proposedX =
                                                    (_dragSourceOffsetX ??
                                                        current.offsetX) +
                                                    delta.dx *
                                                        kTimelineDesignWidth /
                                                        constraints.maxWidth;
                                                final proposedY =
                                                    (_dragSourceOffsetY ??
                                                        current.offsetY) +
                                                    delta.dy *
                                                        kTimelineDesignHeight /
                                                        constraints.maxHeight;
                                                _dragSourceOffsetX = proposedX;
                                                _dragSourceOffsetY = proposedY;
                                                final halfWidth =
                                                    kTimelineDesignWidth *
                                                    0.18 *
                                                    current.scale;
                                                final halfHeight =
                                                    kTimelineDesignHeight *
                                                    0.25 *
                                                    current.scale;
                                                return current.copyWith(
                                                  offsetX: _snapDesignCoordinate(
                                                    proposed: proposedX,
                                                    designExtent:
                                                        kTimelineDesignWidth,
                                                    viewportExtent:
                                                        constraints.maxWidth,
                                                    objectHalfExtent: halfWidth,
                                                  ).clamp(-maxX, maxX).toDouble(),
                                                  offsetY: _snapDesignCoordinate(
                                                    proposed: proposedY,
                                                    designExtent:
                                                        kTimelineDesignHeight,
                                                    viewportExtent:
                                                        constraints.maxHeight,
                                                    objectHalfExtent:
                                                        halfHeight,
                                                  ).clamp(-maxY, maxY).toDouble(),
                                                );
                                              });
                                            },
                                            onMoveEnd: _endSnappedDrag,
                                            onScaleFactorUpdate: (factor) {
                                              _updateOverlayTransform(
                                                item.clip.id,
                                                (current) => current.copyWith(
                                                  scale:
                                                      ((_freeTransformStartScale ??
                                                                  current
                                                                      .scale) *
                                                              factor)
                                                          .clamp(0.2, 4.0)
                                                          .toDouble(),
                                                ),
                                              );
                                            },
                                            onRotationUpdate: (rotation) {
                                              _updateOverlayTransform(
                                                item.clip.id,
                                                (current) => current.copyWith(
                                                  rotation:
                                                      (_freeTransformStartRotation ??
                                                          current.rotation) +
                                                      rotation,
                                                ),
                                              );
                                            },
                                            // Media is painted once in the
                                            // composed canvas below timeline
                                            // effects. Keep only this clear
                                            // edit target above the effects so
                                            // selection chrome stays crisp and
                                            // video controllers are not
                                            // duplicated.
                                            child: SizedBox(
                                              key: ValueKey(
                                                'preview-overlay-interaction-${item.clip.id}',
                                              ),
                                              width:
                                                  constraints.maxWidth * 0.36,
                                              height:
                                                  constraints.maxHeight * 0.5,
                                            ),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  );
                                },
                              ),
                            ),
                          if (activeEffectItems.isNotEmpty)
                            _buildEffectLayer(
                              effects: activeEffectItems,
                              aspectRatio: previewAspectRatio,
                              selectedClipId: editorState.selectedClipId,
                            ),
                          if (activeTextItems.isNotEmpty)
                            _CanvasBoundLayer(
                              aspectRatio: previewAspectRatio,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  const maxX = kTimelineDesignWidth / 2 - 28;
                                  const maxY = kTimelineDesignHeight / 2 - 28;

                                  return Stack(
                                    children: activeTextItems.map((item) {
                                      final isSelected =
                                          editorState.selectedClipId ==
                                          item.clip.id;
                                      final style =
                                          item.clip.subtitleStyle ??
                                          const SubtitleStyleModel(
                                            position: SubtitlePosition.center,
                                            fontSize: 32,
                                          );
                                      final transform = item.clip.transformAt(
                                        playbackState.position,
                                      );
                                      Widget
                                      textPreview = AnimatedSubtitleOverlay(
                                        entry: SubtitleEntry(
                                          id: item.clip.id,
                                          startTime: item.clip.startTime,
                                          endTime: item.clip.endTime,
                                          text:
                                              item.clip.text ?? item.clip.label,
                                          styleOverride: style,
                                        ),
                                        globalStyle: style,
                                        currentPosition: playbackState.position,
                                        scaleFactor:
                                            constraints.maxHeight /
                                            kTimelineDesignHeight,
                                      );
                                      // Text clips export through ASS today,
                                      // which supports editor offsets and font
                                      // scaling but not generic media
                                      // rotation, flip, opacity or transitions.
                                      textPreview = Transform.scale(
                                        scale: transform.scale.clamp(0.25, 4.0),
                                        child: textPreview,
                                      );
                                      return Align(
                                        child: Transform.translate(
                                          offset: Offset(
                                            transform.offsetX.clamp(
                                                  -maxX,
                                                  maxX,
                                                ) *
                                                constraints.maxWidth /
                                                kTimelineDesignWidth,
                                            transform.offsetY.clamp(
                                                  -maxY,
                                                  maxY,
                                                ) *
                                                constraints.maxHeight /
                                                kTimelineDesignHeight,
                                          ),
                                          child: _OverlayTransformBox(
                                            isSelected: isSelected,
                                            onTap: () {
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectTrack(item.trackId);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectClip(item.clip.id);
                                              ref
                                                  .read(
                                                    subtitleProvider.notifier,
                                                  )
                                                  .selectEntry(null);
                                            },
                                            onMoveStart: () {
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectTrack(item.trackId);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectClip(item.clip.id);
                                              _beginSnappedDrag(transform);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .beginTimelineGestureEdit();
                                            },
                                            onMoveUpdate: (delta) {
                                              _updateOverlayTransform(item.clip.id, (
                                                current,
                                              ) {
                                                final proposedX =
                                                    (_dragSourceOffsetX ??
                                                        current.offsetX) +
                                                    delta.dx *
                                                        kTimelineDesignWidth /
                                                        constraints.maxWidth;
                                                final proposedY =
                                                    (_dragSourceOffsetY ??
                                                        current.offsetY) +
                                                    delta.dy *
                                                        kTimelineDesignHeight /
                                                        constraints.maxHeight;
                                                _dragSourceOffsetX = proposedX;
                                                _dragSourceOffsetY = proposedY;
                                                return current.copyWith(
                                                  offsetX: _snapDesignCoordinate(
                                                    proposed: proposedX,
                                                    designExtent:
                                                        kTimelineDesignWidth,
                                                    viewportExtent:
                                                        constraints.maxWidth,
                                                  ).clamp(-maxX, maxX).toDouble(),
                                                  offsetY: _snapDesignCoordinate(
                                                    proposed: proposedY,
                                                    designExtent:
                                                        kTimelineDesignHeight,
                                                    viewportExtent:
                                                        constraints.maxHeight,
                                                  ).clamp(-maxY, maxY).toDouble(),
                                                );
                                              });
                                            },
                                            onMoveEnd: _endSnappedDrag,
                                            onScaleFactorUpdate: (factor) {
                                              _updateOverlayTransform(
                                                item.clip.id,
                                                (current) => current.copyWith(
                                                  scale:
                                                      ((_freeTransformStartScale ??
                                                                  current
                                                                      .scale) *
                                                              factor)
                                                          .clamp(0.25, 4.0)
                                                          .toDouble(),
                                                ),
                                              );
                                            },
                                            onRotationUpdate: (rotation) {
                                              _updateOverlayTransform(
                                                item.clip.id,
                                                (current) => current.copyWith(
                                                  rotation:
                                                      (_freeTransformStartRotation ??
                                                          current.rotation) +
                                                      rotation,
                                                ),
                                              );
                                            },
                                            child: Opacity(
                                              opacity: 0,
                                              child: ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                      minWidth: 48,
                                                      minHeight: 36,
                                                    ),
                                                child: textPreview,
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  );
                                },
                              ),
                            ),
                          if (activeSubtitle != null)
                            _CanvasBoundLayer(
                              aspectRatio: previewAspectRatio,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final activeEntry = activeSubtitle;
                                  final isSelected =
                                      subtitleState.selectedEntryId ==
                                      activeEntry.id;
                                  // A style override is a complete cue style in
                                  // the export model, so preview and direct
                                  // manipulation must edit that same style.
                                  final editPerEntry =
                                      activeEntry.styleOverride != null;
                                  final editableStyle = _readEditableStyleFor(
                                    activeEntry,
                                    editPerEntry,
                                  );

                                  const maxX = kTimelineDesignWidth / 2 - 24;
                                  const maxY = kTimelineDesignHeight / 2 - 24;
                                  final effectiveOffsetY =
                                      editableStyle.verticalOffset +
                                      editableStyle.offsetY;

                                  return Align(
                                    alignment: _alignmentForPosition(
                                      editableStyle.position,
                                    ),
                                    child: Transform.translate(
                                      offset: Offset(
                                        editableStyle.offsetX.clamp(
                                              -maxX,
                                              maxX,
                                            ) *
                                            constraints.maxWidth /
                                            kTimelineDesignWidth,
                                        effectiveOffsetY.clamp(-maxY, maxY) *
                                            constraints.maxHeight /
                                            kTimelineDesignHeight,
                                      ),
                                      child: _OverlayTransformBox(
                                        isSelected: isSelected,
                                        onTap: () {
                                          ref
                                              .read(subtitleProvider.notifier)
                                              .selectEntry(activeEntry.id);
                                        },
                                        onMoveStart: () => _beginStyleGesture(
                                          activeEntry,
                                          editPerEntry,
                                        ),
                                        onMoveUpdate: (delta) {
                                          final style = _readEditableStyleFor(
                                            activeEntry,
                                            editPerEntry,
                                          );
                                          final proposedX =
                                              (_dragSourceOffsetX ??
                                                  style.offsetX) +
                                              delta.dx *
                                                  kTimelineDesignWidth /
                                                  constraints.maxWidth;
                                          final proposedEffectiveY =
                                              (_dragSourceOffsetY ??
                                                  style.verticalOffset +
                                                      style.offsetY) +
                                              delta.dy *
                                                  kTimelineDesignHeight /
                                                  constraints.maxHeight;
                                          _dragSourceOffsetX = proposedX;
                                          _dragSourceOffsetY =
                                              proposedEffectiveY;
                                          final nextOffsetX =
                                              _snapDesignCoordinate(
                                                proposed: proposedX,
                                                designExtent:
                                                    kTimelineDesignWidth,
                                                viewportExtent:
                                                    constraints.maxWidth,
                                              ).clamp(-maxX, maxX).toDouble();
                                          final snappedEffectiveY =
                                              _snapDesignCoordinate(
                                                proposed: proposedEffectiveY,
                                                designExtent:
                                                    kTimelineDesignHeight,
                                                viewportExtent:
                                                    constraints.maxHeight,
                                              ).clamp(-maxY, maxY).toDouble();
                                          // verticalOffset is the style's
                                          // anchored baseline. Store only the
                                          // user's delta so switching subtitle
                                          // positions keeps its semantics.
                                          final nextOffsetY =
                                              snappedEffectiveY -
                                              style.verticalOffset;

                                          _applyStyleLive(
                                            activeEntry: activeEntry,
                                            editPerEntry: editPerEntry,
                                            style: style.copyWith(
                                              offsetX: nextOffsetX,
                                              offsetY: nextOffsetY,
                                            ),
                                          );
                                        },
                                        onMoveEnd: _endStyleGesture,
                                        onScaleFactorUpdate: (factor) {
                                          final style = _readEditableStyleFor(
                                            activeEntry,
                                            editPerEntry,
                                          );
                                          _applyStyleLive(
                                            activeEntry: activeEntry,
                                            editPerEntry: editPerEntry,
                                            style: style.copyWith(
                                              fontSize:
                                                  ((_freeTransformStartFontSize ??
                                                              style.fontSize) *
                                                          factor)
                                                      .clamp(1.0, 72.0)
                                                      .toDouble(),
                                            ),
                                          );
                                        },
                                        child: Opacity(
                                          opacity: 0,
                                          child: AnimatedSubtitleOverlay(
                                            entry: activeEntry,
                                            globalStyle:
                                                subtitleState.globalStyle,
                                            currentPosition:
                                                playbackState.position,
                                            scaleFactor:
                                                constraints.maxHeight /
                                                kTimelineDesignHeight,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          if (editorState
                                  .timeline
                                  .canvasSettings
                                  .showSafeAreas ||
                              editorState.timeline.canvasSettings.showGrid)
                            _CanvasBoundLayer(
                              aspectRatio: previewAspectRatio,
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _CanvasGuidesPainter(
                                    showSafeAreas: editorState
                                        .timeline
                                        .canvasSettings
                                        .showSafeAreas,
                                    showGrid: editorState
                                        .timeline
                                        .canvasSettings
                                        .showGrid,
                                    gridDivisions: editorState
                                        .timeline
                                        .canvasSettings
                                        .gridDivisions,
                                  ),
                                ),
                              ),
                            ),
                          for (final item in activeOverlayItems)
                            if (item.asset.type == EditorAssetType.video &&
                                item.clip.freezeFrame &&
                                !item.clip.isReversed &&
                                previewVisualUsesEmbeddedAudioForTesting(
                                  timeline: editorState.timeline,
                                  visualTrack: item.track,
                                  visualClip: item.clip,
                                  position: playbackState.position,
                                  hasSoloMediaTrack: _hasSoloMediaTrack(
                                    editorState.timeline,
                                  ),
                                ) &&
                                item.asset.sourcePath != null &&
                                _cachedFileExists(item.asset.sourcePath!) &&
                                editorState.timeline.clipHasAudio(item.clip))
                              Positioned(
                                left: 0,
                                top: 0,
                                width: 1,
                                height: 1,
                                child: _TimelineAudioPreview(
                                  key: ValueKey(
                                    'overlay_audio_${item.clip.id}',
                                  ),
                                  audioPath: item.asset.sourcePath!,
                                  clip: item.clip,
                                  playbackPosition: playbackState.position,
                                  isPlaying: playbackState.isPlaying,
                                  playbackSpeed: _playbackSpeed,
                                  diagnostics: _performanceMonitor,
                                  duckingGain: _previewDuckingGain(
                                    item.clip,
                                    playbackState.position,
                                  ),
                                  isTrackAudible: true,
                                  continueFreezeFrameAudio: true,
                                ),
                              ),
                          for (final item in activeAudioItems)
                            Positioned(
                              left: 0,
                              top: 0,
                              width: 1,
                              height: 1,
                              child: _TimelineAudioPreview(
                                key: ValueKey('audio_${item.clip.id}'),
                                audioPath: item.asset.sourcePath!,
                                clip: item.clip,
                                playbackPosition: playbackState.position,
                                isPlaying:
                                    playbackState.isPlaying && item.isActive,
                                playbackSpeed: _playbackSpeed,
                                diagnostics: _performanceMonitor,
                                duckingGain: _previewDuckingGain(
                                  item.clip,
                                  playbackState.position,
                                ),
                                isTrackAudible: item.isActive,
                                preloadOnly: !item.isActive,
                              ),
                            ),
                          if (controllerReady &&
                              activeBaseClip.freezeFrame &&
                              !activeBaseClip.isReversed &&
                              !activeBaseClip.audioMix.muted &&
                              controllerPath != null &&
                              controllerTrack != null &&
                              !controllerTrack.isMuted &&
                              (!_hasSoloMediaTrack(editorState.timeline) ||
                                  controllerTrack.isSolo) &&
                              editorState.timeline.clipHasAudio(activeBaseClip))
                            Positioned(
                              left: 0,
                              top: 0,
                              width: 1,
                              height: 1,
                              child: _TimelineAudioPreview(
                                key: ValueKey(
                                  'freeze_audio_${activeBaseClip.id}',
                                ),
                                audioPath: controllerPath,
                                clip: activeBaseClip,
                                playbackPosition: playbackState.position,
                                isPlaying: playbackState.isPlaying,
                                playbackSpeed: _playbackSpeed,
                                diagnostics: _performanceMonitor,
                                duckingGain: _previewDuckingGain(
                                  activeBaseClip,
                                  playbackState.position,
                                ),
                                isTrackAudible: true,
                                continueFreezeFrameAudio: true,
                              ),
                            ),
                        ],
                      )
                    : const Center(
                        child: CircularProgressIndicator(
                          color: kAccent,
                          strokeWidth: 2,
                        ),
                      ),
              ),
              // Playback controls
              SizedBox(
                height: footerViewportHeight,
                child: SingleChildScrollView(
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: compactControls ? 6 : 12,
                      vertical: compactControls ? 2 : 8,
                    ),
                    color: kSurface,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: compactControls ? 24 : 40,
                          child: SliderTheme(
                            data: SliderThemeData(
                              activeTrackColor: kAccent,
                              inactiveTrackColor: kBorder,
                              thumbColor: kAccent,
                              thumbShape: RoundSliderThumbShape(
                                enabledThumbRadius: compactControls ? 5 : 6,
                              ),
                              trackHeight: compactControls ? 2 : 3,
                              overlayShape: RoundSliderOverlayShape(
                                overlayRadius: compactControls ? 9 : 12,
                              ),
                            ),
                            child: Slider(
                              value: playbackState.progressPercent
                                  .clamp(0, 1)
                                  .toDouble(),
                              onChanged: (value) {
                                final pos = Duration(
                                  milliseconds:
                                      (value *
                                              playbackState
                                                  .duration
                                                  .inMilliseconds)
                                          .round(),
                                );
                                _seekTo(pos);
                              },
                            ),
                          ),
                        ),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            return SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minWidth: constraints.maxWidth,
                                ),
                                child: IconButtonTheme(
                                  data: IconButtonThemeData(
                                    style: IconButton.styleFrom(
                                      minimumSize: Size.square(
                                        compactControls ? 32 : 48,
                                      ),
                                      padding: compactControls
                                          ? EdgeInsets.zero
                                          : null,
                                      tapTargetSize: compactControls
                                          ? MaterialTapTargetSize.shrinkWrap
                                          : MaterialTapTargetSize.padded,
                                      visualDensity: compactControls
                                          ? VisualDensity.compact
                                          : VisualDensity.standard,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      IconButton(
                                        tooltip: 'Go to start',
                                        icon: const Icon(
                                          Icons.first_page_rounded,
                                          color: kTextSecondary,
                                          size: 21,
                                        ),
                                        onPressed: () => _seekTo(Duration.zero),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.replay_10_rounded,
                                          color: kTextPrimary,
                                          size: 22,
                                        ),
                                        onPressed: () => _seekTo(
                                          playbackState.position -
                                              const Duration(seconds: 10),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Previous frame',
                                        icon: const Icon(
                                          Icons.skip_previous_rounded,
                                          color: kTextPrimary,
                                          size: 22,
                                        ),
                                        onPressed: () => _stepFrame(-1),
                                      ),
                                      IconButton(
                                        tooltip: playbackState.isPlaying
                                            ? 'Pause'
                                            : 'Play',
                                        icon: Icon(
                                          playbackState.isPlaying
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          color: kTextPrimary,
                                          size: 32,
                                        ),
                                        onPressed: _togglePlayPause,
                                      ),
                                      IconButton(
                                        tooltip: 'Next frame',
                                        icon: const Icon(
                                          Icons.skip_next_rounded,
                                          color: kTextPrimary,
                                          size: 22,
                                        ),
                                        onPressed: () => _stepFrame(1),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.forward_10_rounded,
                                          color: kTextPrimary,
                                          size: 22,
                                        ),
                                        onPressed: () => _seekTo(
                                          playbackState.position +
                                              const Duration(seconds: 10),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: workspaceLoop
                                            ? 'Turn looping off'
                                            : 'Loop timeline',
                                        icon: Icon(
                                          Icons.repeat_rounded,
                                          color: workspaceLoop
                                              ? kAccent
                                              : kTextSecondary,
                                          size: 20,
                                        ),
                                        onPressed: () {
                                          final current = ref
                                              .read(editorProvider)
                                              .timeline
                                              .workspaceSettings
                                              .loopPlayback;
                                          ref
                                              .read(editorProvider.notifier)
                                              .setWorkspaceSettings(
                                                (settings) => settings.copyWith(
                                                  loopPlayback: !current,
                                                ),
                                              );
                                        },
                                      ),
                                      IconButton(
                                        tooltip: _showPerformanceDiagnostics
                                            ? 'Hide preview diagnostics'
                                            : 'Show preview diagnostics',
                                        icon: Icon(
                                          Icons.monitor_heart_outlined,
                                          color: _showPerformanceDiagnostics
                                              ? kAccent
                                              : kTextSecondary,
                                          size: 20,
                                        ),
                                        onPressed: () {
                                          final next =
                                              !_showPerformanceDiagnostics;
                                          _performanceMonitor.setEnabled(next);
                                          setState(
                                            () => _showPerformanceDiagnostics =
                                                next,
                                          );
                                        },
                                      ),
                                      if (widget.onFullscreenToggle != null)
                                        IconButton(
                                          tooltip: widget.isFullscreen
                                              ? 'Exit fullscreen preview'
                                              : 'Fullscreen preview',
                                          icon: Icon(
                                            widget.isFullscreen
                                                ? Icons.fullscreen_exit_rounded
                                                : Icons.fullscreen_rounded,
                                            color: kTextSecondary,
                                            size: 21,
                                          ),
                                          onPressed: widget.onFullscreenToggle,
                                        ),
                                      const SizedBox(width: 4),
                                      PopupMenuButton<double>(
                                        tooltip: 'Playback speed',
                                        color: kSurfaceElevated,
                                        onSelected: _setPlaybackSpeed,
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 0.5,
                                            child: Text('0.5x'),
                                          ),
                                          PopupMenuItem(
                                            value: 0.75,
                                            child: Text('0.75x'),
                                          ),
                                          PopupMenuItem(
                                            value: 1.0,
                                            child: Text('1.0x'),
                                          ),
                                          PopupMenuItem(
                                            value: 1.25,
                                            child: Text('1.25x'),
                                          ),
                                          PopupMenuItem(
                                            value: 1.5,
                                            child: Text('1.5x'),
                                          ),
                                          PopupMenuItem(
                                            value: 2.0,
                                            child: Text('2.0x'),
                                          ),
                                        ],
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: kSurfaceElevated,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            border: Border.all(color: kBorder),
                                          ),
                                          child: Text(
                                            '${_playbackSpeed.toStringAsFixed(_playbackSpeed == 1 ? 0 : 2)}x',
                                            style: const TextStyle(
                                              color: kTextSecondary,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      ),
                                      SizedBox(width: compactControls ? 8 : 16),
                                      Tooltip(
                                        message: 'Tap to jump to a timecode',
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          onTap: _showTimecodeJumpDialog,
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: compactControls ? 2 : 5,
                                            ),
                                            child: Text(
                                              '${SubtitleEntry.formatDisplayTime(playbackState.position)} / '
                                              '${SubtitleEntry.formatDisplayTime(playbackState.duration)}',
                                              style: TextStyle(
                                                fontFamily: 'SpaceMono',
                                                color: kTextSecondary,
                                                fontSize: compactControls
                                                    ? 10
                                                    : 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Alignment _alignmentForPosition(SubtitlePosition position) {
    switch (position) {
      case SubtitlePosition.top:
        return Alignment.topCenter;
      case SubtitlePosition.center:
        return Alignment.center;
      case SubtitlePosition.bottom:
        return Alignment.bottomCenter;
    }
  }
}

class _PreviewDiagnosticsOverlay extends StatelessWidget {
  final PreviewPerformanceSnapshot snapshot;
  final VoidCallback onReset;

  const _PreviewDiagnosticsOverlay({
    required this.snapshot,
    required this.onReset,
  });

  String _milliseconds(Duration value) {
    return '${(value.inMicroseconds / 1000).toStringAsFixed(1)} ms';
  }

  @override
  Widget build(BuildContext context) {
    const labelStyle = TextStyle(
      color: Colors.white70,
      fontFamily: 'SpaceMono',
      fontSize: 9,
      height: 1.35,
    );
    const valueStyle = TextStyle(
      color: Colors.white,
      fontFamily: 'SpaceMono',
      fontSize: 9,
      height: 1.35,
      fontWeight: FontWeight.w700,
    );
    Widget row(String label, String value) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label  ', style: labelStyle),
          Flexible(child: Text(value, style: valueStyle)),
        ],
      );
    }

    return Semantics(
      label: 'Preview performance diagnostics',
      child: Container(
        width: 226,
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: const Color(0xE611151C),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kAccent.withValues(alpha: 0.55)),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 12),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'PREVIEW DIAGNOSTICS',
                    style: TextStyle(
                      color: kAccent,
                      fontFamily: 'SpaceMono',
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(5),
                  onTap: onReset,
                  child: const Padding(
                    padding: EdgeInsets.all(3),
                    child: Text('RESET', style: labelStyle),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            row(
              'Decoders',
              '${snapshot.decoderCount} total • '
                  '${snapshot.videoDecoderCount}V/${snapshot.audioDecoderCount}A • '
                  '${snapshot.warmDecoderCount} warm',
            ),
            row(
              'Audio/buffer',
              '${snapshot.audibleDecoderCount} audible • '
                  '${snapshot.bufferingDecoderCount} buffering '
                  '(${snapshot.bufferingEventCount} events)',
            ),
            row(
              'Clock drift',
              '${_milliseconds(snapshot.maximumAbsoluteDrift)} max • '
                  '${snapshot.hardSeekCount} corrections',
            ),
            row(
              'Ticker',
              '${_milliseconds(snapshot.averageTickInterval)} avg • '
                  '${_milliseconds(snapshot.peakTickInterval)} peak • '
                  '${snapshot.missedTickEstimate} missed',
            ),
          ],
        ),
      ),
    );
  }
}

class _OverlayAnimationState {
  final double opacity;
  final double scale;
  final double rotation;
  final Offset offset;

  const _OverlayAnimationState({
    required this.opacity,
    required this.scale,
    required this.rotation,
    required this.offset,
  });
}

class _PreviewTrackLane {
  final int trackIndex;
  final TimelineTrack track;
  final List<TimelineClip> clips;

  const _PreviewTrackLane({
    required this.trackIndex,
    required this.track,
    required this.clips,
  });

  TimelineClip? activeAt(Duration position, {bool includeEnd = false}) {
    return resolveIndexedPreviewClipForTesting(
      sortedClips: clips,
      position: position,
      includeEnd: includeEnd,
    );
  }

  int firstStartingAfter(Duration position) =>
      previewClipStartUpperBoundForTesting(clips, position);
}

class _PreviewCaptionIndex {
  final List<SubtitleEntry> entries;
  late final List<int> _segmentMaximumEndUs;

  _PreviewCaptionIndex(Iterable<SubtitleEntry> source)
    : entries = source.toList(growable: false)
        ..sort((a, b) => a.startTime.compareTo(b.startTime)) {
    _segmentMaximumEndUs = entries.isEmpty
        ? const []
        : List<int>.filled(entries.length * 4, 0);
    if (entries.isNotEmpty) _build(1, 0, entries.length - 1);
  }

  _PreviewCaptionIndex.empty() : entries = const [] {
    _segmentMaximumEndUs = const [];
  }

  int _build(int node, int start, int end) {
    if (start == end) {
      return _segmentMaximumEndUs[node] = entries[start].endTime.inMicroseconds;
    }
    final middle = start + ((end - start) >> 1);
    return _segmentMaximumEndUs[node] = math.max(
      _build(node * 2, start, middle),
      _build(node * 2 + 1, middle + 1, end),
    );
  }

  List<SubtitleEntry> activeAt(Duration position) {
    if (entries.isEmpty) return const [];
    final positionUs = position.inMicroseconds;
    final active = <SubtitleEntry>[];
    void collect(int node, int start, int end) {
      if (_segmentMaximumEndUs[node] <= positionUs ||
          entries[start].startTime > position) {
        return;
      }
      if (start == end) {
        final entry = entries[start];
        if (entry.startTime <= position && position < entry.endTime) {
          active.add(entry);
        }
        return;
      }
      final middle = start + ((end - start) >> 1);
      collect(node * 2, start, middle);
      if (middle + 1 < entries.length &&
          entries[middle + 1].startTime <= position) {
        collect(node * 2 + 1, middle + 1, end);
      }
    }

    collect(1, 0, entries.length - 1);
    return active;
  }
}

class _OverlayCanvasItem {
  final int trackIndex;
  final TimelineTrack track;
  final TimelineClip clip;
  final EditorAssetReference asset;

  const _OverlayCanvasItem({
    required this.trackIndex,
    required this.track,
    required this.clip,
    required this.asset,
  });
}

class _EffectCanvasItem {
  final int trackIndex;
  final String trackId;
  final TimelineClip clip;

  const _EffectCanvasItem({
    required this.trackIndex,
    required this.trackId,
    required this.clip,
  });
}

class _AudioCanvasItem {
  final TimelineTrack track;
  final TimelineClip clip;
  final EditorAssetReference asset;
  final bool isActive;

  const _AudioCanvasItem({
    required this.track,
    required this.clip,
    required this.asset,
    required this.isActive,
  });
}

class _TextCanvasItem {
  final int trackIndex;
  final String trackId;
  final TimelineClip clip;

  const _TextCanvasItem({
    required this.trackIndex,
    required this.trackId,
    required this.clip,
  });
}

class _DecodedGifFrame {
  final ui.Image image;
  final int endMilliseconds;

  const _DecodedGifFrame({required this.image, required this.endMilliseconds});
}

class _TimelineGifPreview extends StatefulWidget {
  final String? filePath;
  final String? remoteUrl;
  final TimelineClip clip;
  final Duration playbackPosition;
  final double width;
  final double height;
  final ClipFitMode fitMode;
  final ClipCropSettings crop;
  final String label;
  final BorderRadius borderRadius;
  final Widget Function(Widget child) mediaEffectsBuilder;

  const _TimelineGifPreview({
    super.key,
    required this.filePath,
    required this.remoteUrl,
    required this.clip,
    required this.playbackPosition,
    required this.width,
    required this.height,
    required this.fitMode,
    required this.crop,
    required this.label,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
    required this.mediaEffectsBuilder,
  });

  @override
  State<_TimelineGifPreview> createState() => _TimelineGifPreviewState();
}

class _TimelineGifPreviewState extends State<_TimelineGifPreview> {
  List<_DecodedGifFrame> _frames = const [];
  int _totalDurationMs = 0;
  int _decodeGeneration = 0;
  Timer? _resizeDecodeTimer;
  HttpClient? _activeHttpClient;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _requestDecode(immediate: true);
  }

  @override
  void didUpdateWidget(covariant _TimelineGifPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged =
        oldWidget.filePath != widget.filePath ||
        oldWidget.remoteUrl != widget.remoteUrl;
    final oldSize = quantizeGifPreviewSizeForTesting(
      oldWidget.width,
      oldWidget.height,
    );
    final nextSize = quantizeGifPreviewSizeForTesting(
      widget.width,
      widget.height,
    );
    if (sourceChanged || oldSize != nextSize) {
      _requestDecode(immediate: sourceChanged);
    }
  }

  void _requestDecode({required bool immediate}) {
    final generation = ++_decodeGeneration;
    _resizeDecodeTimer?.cancel();
    _activeHttpClient?.close(force: true);
    _activeHttpClient = null;
    final filePath = widget.filePath;
    final remoteUrl = widget.remoteUrl;
    final targetSize = quantizeGifPreviewSizeForTesting(
      widget.width,
      widget.height,
    );
    final retainCurrentFrames = !immediate && _frames.isNotEmpty;
    void start() {
      if (!mounted || generation != _decodeGeneration) return;
      unawaited(
        _decodeFrames(
          generation: generation,
          filePath: filePath,
          remoteUrl: remoteUrl,
          targetSize: targetSize,
          retainCurrentFrames: retainCurrentFrames,
        ),
      );
    }

    if (immediate) {
      start();
    } else {
      _resizeDecodeTimer = Timer(_gifResizeDecodeDebounce, start);
    }
  }

  Future<Uint8List> _loadBytes({
    required int generation,
    required String? filePath,
    required String? remoteUrl,
  }) async {
    if (filePath != null && filePath.isNotEmpty) {
      final file = File(filePath);
      if (await file.length() > _maxGifEncodedBytes) {
        throw const FormatException('GIF exceeds the preview size limit');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > _maxGifEncodedBytes) {
        throw const FormatException('GIF exceeds the preview size limit');
      }
      return bytes;
    }
    final uri = Uri.tryParse(remoteUrl ?? '');
    if (uri == null || !uri.hasScheme) {
      throw const FormatException('Invalid GIF source');
    }
    final client = HttpClient();
    if (generation == _decodeGeneration) _activeHttpClient = client;
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'GIF request failed (${response.statusCode})',
          uri: uri,
        );
      }
      if (response.contentLength > _maxGifEncodedBytes) {
        throw HttpException('GIF exceeds the preview size limit', uri: uri);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
        if (bytes.length > _maxGifEncodedBytes) {
          throw HttpException('GIF exceeds the preview size limit', uri: uri);
        }
      }
      return bytes.takeBytes();
    } finally {
      if (identical(client, _activeHttpClient)) _activeHttpClient = null;
      client.close(force: true);
    }
  }

  Future<void> _decodeFrames({
    required int generation,
    required String? filePath,
    required String? remoteUrl,
    required Size targetSize,
    required bool retainCurrentFrames,
  }) async {
    if (!retainCurrentFrames) _disposeFrames();
    _loading = _frames.isEmpty;
    _failed = false;
    try {
      final bytes = await _loadBytes(
        generation: generation,
        filePath: filePath,
        remoteUrl: remoteUrl,
      );
      if (!mounted || generation != _decodeGeneration) return;

      var intrinsicWidth = 1;
      var intrinsicHeight = 1;
      final probeBuffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // instantiateImageCodecWithSize takes ownership of probeBuffer and
      // disposes it after creating the lightweight 1x1 probe codec.
      final probeCodec = await ui.instantiateImageCodecWithSize(
        probeBuffer,
        getTargetSize: (width, height) {
          intrinsicWidth = width;
          intrinsicHeight = height;
          return const ui.TargetImageSize(width: 1, height: 1);
        },
      );
      final frameCount = probeCodec.frameCount;
      probeCodec.dispose();
      if (!mounted || generation != _decodeGeneration) return;

      final decodeSize = calculateGifDecodeSizeForTesting(
        intrinsicWidth: intrinsicWidth,
        intrinsicHeight: intrinsicHeight,
        frameCount: frameCount,
        maxWidth: targetSize.width,
        maxHeight: targetSize.height,
      );
      // Show a decoded first frame immediately while the deterministic
      // timeline frame cache is prepared. Large GIFs can contain hundreds of
      // frames; waiting for all of them made a durable local file look like it
      // was still network-buffering.
      if (_frames.isEmpty) {
        final firstFrameCodec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: decodeSize.width.toInt(),
          targetHeight: decodeSize.height.toInt(),
          allowUpscaling: false,
        );
        try {
          final firstFrame = await firstFrameCodec.getNextFrame();
          if (!mounted || generation != _decodeGeneration) {
            firstFrame.image.dispose();
            return;
          }
          setState(() {
            _frames = [
              _DecodedGifFrame(
                image: firstFrame.image,
                endMilliseconds: math.max(
                  1,
                  firstFrame.duration.inMilliseconds,
                ),
              ),
            ];
            _totalDurationMs = math.max(1, firstFrame.duration.inMilliseconds);
            _loading = false;
            _failed = false;
          });
        } finally {
          firstFrameCodec.dispose();
        }
      }
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: decodeSize.width.toInt(),
        targetHeight: decodeSize.height.toInt(),
        allowUpscaling: false,
      );
      final decoded = <_DecodedGifFrame>[];
      var elapsedMs = 0;
      try {
        for (var index = 0; index < codec.frameCount; index++) {
          final frame = await codec.getNextFrame();
          if (!mounted || generation != _decodeGeneration) {
            frame.image.dispose();
            for (final decodedFrame in decoded) {
              decodedFrame.image.dispose();
            }
            return;
          }
          elapsedMs += math.max(1, frame.duration.inMilliseconds);
          decoded.add(
            _DecodedGifFrame(image: frame.image, endMilliseconds: elapsedMs),
          );
        }
      } catch (_) {
        for (final frame in decoded) {
          frame.image.dispose();
        }
        rethrow;
      } finally {
        codec.dispose();
      }
      if (!mounted || generation != _decodeGeneration) {
        for (final frame in decoded) {
          frame.image.dispose();
        }
        return;
      }
      final previousFrames = _frames;
      setState(() {
        _frames = decoded;
        _totalDurationMs = math.max(1, elapsedMs);
        _loading = false;
        _failed = decoded.isEmpty;
      });
      if (!identical(previousFrames, decoded)) {
        for (final frame in previousFrames) {
          frame.image.dispose();
        }
      }
    } catch (_) {
      if (!mounted || generation != _decodeGeneration) return;
      setState(() {
        _loading = false;
        _failed = _frames.isEmpty;
      });
    }
  }

  void _disposeFrames() {
    for (final frame in _frames) {
      frame.image.dispose();
    }
    _frames = const [];
    _totalDurationMs = 0;
  }

  @override
  void dispose() {
    _decodeGeneration++;
    _resizeDecodeTimer?.cancel();
    _activeHttpClient?.close(force: true);
    _activeHttpClient = null;
    _disposeFrames();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _failed || _frames.isEmpty) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: widget.borderRadius,
          border: Border.all(color: kBorder),
        ),
        alignment: Alignment.center,
        child: _loading
            ? const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              )
            : Text(
                widget.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kTextSecondary, fontSize: 11),
              ),
      );
    }

    final sourcePosition = _previewSourcePosition(
      widget.clip,
      widget.playbackPosition,
    );
    final frameTimeMs = sourcePosition.inMilliseconds % _totalDurationMs;
    var selectedFrame = _frames.last;
    for (final frame in _frames) {
      if (frameTimeMs < frame.endMilliseconds) {
        selectedFrame = frame;
        break;
      }
    }
    final fit = switch (widget.fitMode) {
      ClipFitMode.cover => BoxFit.cover,
      ClipFitMode.contain => BoxFit.contain,
      ClipFitMode.stretch => BoxFit.fill,
    };
    Widget source = SizedBox(
      width: selectedFrame.image.width.toDouble(),
      height: selectedFrame.image.height.toDouble(),
      child: RawImage(
        image: selectedFrame.image,
        filterQuality: FilterQuality.medium,
      ),
    );
    source = _cropSourcePreview(
      child: source,
      sourceWidth: selectedFrame.image.width.toDouble(),
      sourceHeight: selectedFrame.image.height.toDouble(),
      crop: widget.crop,
    );
    final media = ClipRRect(
      borderRadius: widget.borderRadius,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: FittedBox(fit: fit, clipBehavior: Clip.hardEdge, child: source),
      ),
    );
    return widget.mediaEffectsBuilder(media);
  }
}

class _OverlayVideoPreview extends StatefulWidget {
  final String videoPath;
  final TimelineClip clip;
  final Duration playbackPosition;
  final bool isPlaying;
  final double playbackSpeed;
  final PreviewPerformanceMonitor diagnostics;
  final double duckingGain;
  final bool isTrackAudible;
  final double width;
  final double height;
  final ClipFitMode fitMode;
  final ClipCropSettings crop;
  final Widget Function(Widget child) mediaEffectsBuilder;

  const _OverlayVideoPreview({
    super.key,
    required this.videoPath,
    required this.clip,
    required this.playbackPosition,
    required this.isPlaying,
    required this.playbackSpeed,
    required this.diagnostics,
    required this.duckingGain,
    required this.isTrackAudible,
    required this.width,
    required this.height,
    required this.fitMode,
    required this.crop,
    required this.mediaEffectsBuilder,
  });

  @override
  State<_OverlayVideoPreview> createState() => _OverlayVideoPreviewState();
}

class _OverlayVideoPreviewState extends State<_OverlayVideoPreview> {
  VideoPlayerController? _controller;
  int _controllerGeneration = 0;
  bool _ready = false;
  bool _syncInFlight = false;
  bool _syncQueued = false;
  bool _forceSeekQueued = false;
  double? _lastVolume;
  double? _lastPlaybackSpeed;
  DateTime? _lastSyncStartedAt;
  DateTime? _lastDriftCorrectionAt;

  String get _diagnosticId => 'overlay:${widget.clip.id}';

  void _reportDiagnostics(
    VideoPlayerController controller,
    Duration target,
    double volume,
  ) {
    widget.diagnostics.updateDecoder(
      id: _diagnosticId,
      label: widget.clip.label,
      kind: PreviewDecoderKind.overlayVideo,
      initialized: controller.value.isInitialized,
      buffering: controller.value.isBuffering,
      audible: volume > 0.001,
      playing: controller.value.isPlaying,
      warm: false,
      drift: target - controller.value.position,
    );
  }

  void _onControllerDiagnosticUpdate() {
    if (!widget.diagnostics.isEnabled) return;
    final controller = _controller;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return;
    }
    _reportDiagnostics(
      controller,
      _previewSourcePosition(widget.clip, widget.playbackPosition),
      _lastVolume ?? 0,
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadController(widget.videoPath));
  }

  @override
  void didUpdateWidget(covariant _OverlayVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clip.id != widget.clip.id) {
      oldWidget.diagnostics.removeDecoder('overlay:${oldWidget.clip.id}');
    }
    if (oldWidget.videoPath != widget.videoPath) {
      unawaited(_loadController(widget.videoPath));
      return;
    }
    final positionDelta = widget.playbackPosition - oldWidget.playbackPosition;
    final positionJump =
        positionDelta < const Duration(milliseconds: -80) ||
        (!widget.isPlaying &&
            positionDelta.abs() > const Duration(milliseconds: 12)) ||
        positionDelta.abs() > const Duration(milliseconds: 1500);
    final controlsChanged =
        oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.playbackSpeed != widget.playbackSpeed ||
        !identical(oldWidget.clip, widget.clip);
    _schedulePlaybackSync(
      forceSeek: positionJump,
      urgent: controlsChanged || positionJump,
    );
  }

  Future<void> _loadController(String videoPath) async {
    widget.diagnostics.removeDecoder(_diagnosticId);
    final generation = ++_controllerGeneration;
    final previous = _controller;
    _controller = null;
    _ready = false;
    _lastVolume = null;
    _lastPlaybackSpeed = null;
    _lastSyncStartedAt = null;
    _lastDriftCorrectionAt = null;
    if (mounted) setState(() {});
    if (previous != null) {
      try {
        previous.removeListener(_onControllerDiagnosticUpdate);
        await previous.dispose();
      } catch (_) {
        // Ownership was cleared synchronously; disposal remains best-effort.
      }
    }
    if (!mounted || generation != _controllerGeneration) return;
    VideoPlayerController? createdController;
    try {
      final controller = VideoPlayerController.file(
        File(videoPath),
        videoPlayerOptions: buildPreviewVideoPlayerOptions(),
      );
      createdController = controller;
      await controller.initialize();
      await controller.setVolume(0);
      if (!mounted ||
          generation != _controllerGeneration ||
          widget.videoPath != videoPath) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _ready = true;
      });
      controller.addListener(_onControllerDiagnosticUpdate);
      _lastVolume = 0;
      _reportDiagnostics(
        controller,
        _previewSourcePosition(widget.clip, widget.playbackPosition),
        0,
      );
      _schedulePlaybackSync(forceSeek: true);
    } catch (_) {
      final controller = createdController;
      if (controller != null && !identical(controller, _controller)) {
        try {
          await controller.dispose();
        } catch (_) {
          // A failed platform initialization may already release its handle.
        }
      }
      if (mounted && generation == _controllerGeneration) {
        setState(() => _ready = false);
      }
    }
  }

  void _schedulePlaybackSync({bool forceSeek = false, bool urgent = false}) {
    final now = DateTime.now();
    if (!forceSeek && !urgent) {
      final previous = _lastSyncStartedAt;
      if (previous != null &&
          now.difference(previous) < const Duration(milliseconds: 120)) {
        return;
      }
    }
    if (_syncInFlight) {
      _syncQueued = true;
      _forceSeekQueued = _forceSeekQueued || forceSeek;
      return;
    }
    _lastSyncStartedAt = now;
    unawaited(_runPlaybackSync(forceSeek: forceSeek));
  }

  Future<void> _runPlaybackSync({required bool forceSeek}) async {
    _syncInFlight = true;
    try {
      var shouldForceSeek = forceSeek;
      do {
        _syncQueued = false;
        shouldForceSeek = shouldForceSeek || _forceSeekQueued;
        _forceSeekQueued = false;
        await _syncPlaybackOnce(forceSeek: shouldForceSeek);
        shouldForceSeek = false;
      } while (mounted && _syncQueued);
    } catch (_) {
      // The media controller may be replaced while a queued sync is yielding.
    } finally {
      _syncInFlight = false;
    }
  }

  Future<void> _syncPlaybackOnce({bool forceSeek = false}) async {
    final controller = _controller;
    final generation = _controllerGeneration;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return;
    }
    bool stillOwnsController() =>
        mounted &&
        generation == _controllerGeneration &&
        identical(controller, _controller);

    final relative = _previewSourcePosition(
      widget.clip,
      widget.playbackPosition,
    );
    final targetMs = relative.inMilliseconds
        .clamp(0, controller.value.duration.inMilliseconds)
        .toInt();
    final target = Duration(milliseconds: targetMs);
    final volume = _previewAudioVolume(
      clip: widget.clip,
      position: widget.playbackPosition,
      isTrackAudible: widget.isTrackAudible,
      duckingGain: widget.duckingGain,
    );
    final now = DateTime.now();
    final lastCorrection = _lastDriftCorrectionAt;
    final decision = decidePreviewMediaSync(
      timelineTarget: target,
      decoderPosition: controller.value.position,
      isPlaying: widget.isPlaying,
      isAudible: volume > 0.001,
      isBuffering: controller.value.isBuffering,
      forceSeek: forceSeek,
      timeSinceLastCorrection: lastCorrection == null
          ? null
          : now.difference(lastCorrection),
    );
    if (decision == PreviewMediaSyncDecision.seek) {
      if (!forceSeek) widget.diagnostics.recordHardSeek();
      await controller.seekTo(target);
      if (!stillOwnsController()) return;
      _lastDriftCorrectionAt = now;
    }
    if (_lastVolume == null || (_lastVolume! - volume).abs() > 0.01) {
      await controller.setVolume(volume);
      if (!stillOwnsController()) return;
      _lastVolume = volume;
    }
    if (!widget.clip.isReversed && !widget.clip.freezeFrame) {
      final speed = (widget.playbackSpeed * widget.clip.playbackRate)
          .clamp(0.25, 4)
          .toDouble();
      if (_lastPlaybackSpeed == null ||
          (_lastPlaybackSpeed! - speed).abs() > 0.001) {
        await controller.setPlaybackSpeed(speed);
        if (!stillOwnsController()) return;
        _lastPlaybackSpeed = speed;
      }
    }
    if (!mounted) return;
    if (widget.clip.isReversed || widget.clip.freezeFrame) {
      if (controller.value.isPlaying) {
        await controller.pause();
      }
    } else if (widget.isPlaying) {
      if (!controller.value.isPlaying) {
        await controller.play();
      }
    } else {
      if (controller.value.isPlaying) {
        await controller.pause();
      }
    }
    if (stillOwnsController()) {
      _reportDiagnostics(controller, target, volume);
    }
  }

  Future<void> _disposeController() async {
    _controllerGeneration++;
    final controller = _controller;
    _controller = null;
    _ready = false;
    _lastVolume = null;
    _lastPlaybackSpeed = null;
    _lastSyncStartedAt = null;
    _lastDriftCorrectionAt = null;
    if (controller != null) {
      controller.removeListener(_onControllerDiagnosticUpdate);
      await controller.dispose();
    }
  }

  @override
  void dispose() {
    widget.diagnostics.removeDecoder(_diagnosticId);
    unawaited(_disposeController());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        ),
      );
    }

    final videoSize = controller.value.size;
    final sourceWidth = videoSize.width > 0 ? videoSize.width : 16.0;
    final sourceHeight = videoSize.height > 0 ? videoSize.height : 9.0;
    final fit = switch (widget.fitMode) {
      ClipFitMode.cover => BoxFit.cover,
      ClipFitMode.contain => BoxFit.contain,
      ClipFitMode.stretch => BoxFit.fill,
    };
    Widget source = SizedBox(
      width: sourceWidth,
      height: sourceHeight,
      child: VideoPlayer(controller),
    );
    source = _cropSourcePreview(
      child: source,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      crop: widget.crop,
    );
    final media = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: FittedBox(fit: fit, clipBehavior: Clip.hardEdge, child: source),
      ),
    );
    return widget.mediaEffectsBuilder(media);
  }
}

class _TimelineAudioPreview extends StatefulWidget {
  final String audioPath;
  final TimelineClip clip;
  final Duration playbackPosition;
  final bool isPlaying;
  final double playbackSpeed;
  final PreviewPerformanceMonitor diagnostics;
  final double duckingGain;
  final bool isTrackAudible;
  final bool continueFreezeFrameAudio;
  final bool preloadOnly;

  const _TimelineAudioPreview({
    super.key,
    required this.audioPath,
    required this.clip,
    required this.playbackPosition,
    required this.isPlaying,
    required this.playbackSpeed,
    required this.diagnostics,
    required this.duckingGain,
    required this.isTrackAudible,
    this.continueFreezeFrameAudio = false,
    this.preloadOnly = false,
  });

  @override
  State<_TimelineAudioPreview> createState() => _TimelineAudioPreviewState();
}

class _TimelineAudioPreviewState extends State<_TimelineAudioPreview> {
  VideoPlayerController? _controller;
  int _controllerGeneration = 0;
  bool _ready = false;
  bool _syncInFlight = false;
  bool _syncQueued = false;
  bool _forceSeekQueued = false;
  double? _lastVolume;
  double? _lastPlaybackSpeed;
  DateTime? _lastSyncStartedAt;
  DateTime? _lastDriftCorrectionAt;

  String get _diagnosticId => 'audio:${widget.clip.id}';

  void _reportDiagnostics(
    VideoPlayerController controller,
    Duration target,
    double volume,
  ) {
    widget.diagnostics.updateDecoder(
      id: _diagnosticId,
      label: widget.clip.label,
      kind: PreviewDecoderKind.timelineAudio,
      initialized: controller.value.isInitialized,
      buffering: controller.value.isBuffering,
      audible: volume > 0.001,
      playing: controller.value.isPlaying,
      warm: widget.preloadOnly,
      drift: target - controller.value.position,
    );
  }

  void _onControllerDiagnosticUpdate() {
    if (!widget.diagnostics.isEnabled) return;
    final controller = _controller;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return;
    }
    _reportDiagnostics(
      controller,
      _previewSourcePosition(widget.clip, widget.playbackPosition),
      _lastVolume ?? 0,
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadController(widget.audioPath));
  }

  @override
  void didUpdateWidget(covariant _TimelineAudioPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clip.id != widget.clip.id) {
      oldWidget.diagnostics.removeDecoder('audio:${oldWidget.clip.id}');
    }
    if (oldWidget.audioPath != widget.audioPath) {
      unawaited(_loadController(widget.audioPath));
    } else {
      if (widget.preloadOnly &&
          oldWidget.preloadOnly &&
          identical(oldWidget.clip, widget.clip)) {
        _onControllerDiagnosticUpdate();
        return;
      }
      final positionDelta =
          widget.playbackPosition - oldWidget.playbackPosition;
      final activatingWarmController =
          oldWidget.preloadOnly && !widget.preloadOnly;
      final positionJump =
          activatingWarmController ||
          (!widget.preloadOnly &&
              (positionDelta < const Duration(milliseconds: -80) ||
                  (!widget.isPlaying &&
                      positionDelta.abs() > const Duration(milliseconds: 12)) ||
                  positionDelta.abs() > const Duration(milliseconds: 1500)));
      final controlsChanged =
          oldWidget.isPlaying != widget.isPlaying ||
          oldWidget.preloadOnly != widget.preloadOnly ||
          oldWidget.playbackSpeed != widget.playbackSpeed ||
          !identical(oldWidget.clip, widget.clip);
      _schedulePlaybackSync(
        forceSeek: positionJump,
        urgent: controlsChanged || positionJump,
      );
    }
  }

  Future<void> _loadController(String audioPath) async {
    widget.diagnostics.removeDecoder(_diagnosticId);
    final generation = ++_controllerGeneration;
    final previous = _controller;
    _controller = null;
    _ready = false;
    _lastVolume = null;
    _lastPlaybackSpeed = null;
    _lastSyncStartedAt = null;
    _lastDriftCorrectionAt = null;
    if (previous != null) {
      try {
        previous.removeListener(_onControllerDiagnosticUpdate);
        await previous.dispose();
      } catch (_) {
        // Ownership was cleared synchronously; disposal remains best-effort.
      }
    }
    if (!mounted || generation != _controllerGeneration) return;
    VideoPlayerController? createdController;
    try {
      final controller = VideoPlayerController.file(
        File(audioPath),
        videoPlayerOptions: buildPreviewVideoPlayerOptions(),
      );
      createdController = controller;
      await controller.initialize();
      if (!mounted ||
          generation != _controllerGeneration ||
          widget.audioPath != audioPath) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _ready = true;
      controller.addListener(_onControllerDiagnosticUpdate);
      _reportDiagnostics(
        controller,
        _previewSourcePosition(widget.clip, widget.playbackPosition),
        0,
      );
      _schedulePlaybackSync(forceSeek: true);
    } catch (_) {
      final controller = createdController;
      if (controller != null && !identical(controller, _controller)) {
        try {
          await controller.dispose();
        } catch (_) {
          // A failed platform initialization may already release its handle.
        }
      }
      if (mounted && generation == _controllerGeneration) _ready = false;
    }
  }

  void _schedulePlaybackSync({bool forceSeek = false, bool urgent = false}) {
    final now = DateTime.now();
    if (!forceSeek && !urgent) {
      final previous = _lastSyncStartedAt;
      if (previous != null &&
          now.difference(previous) < const Duration(milliseconds: 50)) {
        return;
      }
    }
    if (_syncInFlight) {
      _syncQueued = true;
      _forceSeekQueued = _forceSeekQueued || forceSeek;
      return;
    }
    _lastSyncStartedAt = now;
    unawaited(_runPlaybackSync(forceSeek: forceSeek));
  }

  Future<void> _runPlaybackSync({required bool forceSeek}) async {
    _syncInFlight = true;
    try {
      var shouldForceSeek = forceSeek;
      do {
        _syncQueued = false;
        shouldForceSeek = shouldForceSeek || _forceSeekQueued;
        _forceSeekQueued = false;
        await _syncPlaybackOnce(forceSeek: shouldForceSeek);
        shouldForceSeek = false;
      } while (mounted && _syncQueued);
    } catch (_) {
      // Replacing a media controller can invalidate an in-flight update.
    } finally {
      _syncInFlight = false;
    }
  }

  Future<void> _syncPlaybackOnce({bool forceSeek = false}) async {
    final controller = _controller;
    final generation = _controllerGeneration;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return;
    }
    bool stillOwnsController() =>
        mounted &&
        generation == _controllerGeneration &&
        identical(controller, _controller);
    final continuesFrozenAudio =
        widget.continueFreezeFrameAudio &&
        widget.clip.freezeFrame &&
        !widget.clip.isReversed;
    final sourcePosition = _previewSourcePosition(
      widget.clip,
      widget.playbackPosition,
      holdFreezeFrame: !continuesFrozenAudio,
    );
    final target = Duration(
      milliseconds: sourcePosition.inMilliseconds
          .clamp(0, controller.value.duration.inMilliseconds)
          .toInt(),
    );
    final safeVolume = _previewAudioVolume(
      clip: widget.clip,
      position: widget.playbackPosition,
      isTrackAudible: widget.isTrackAudible,
      duckingGain: widget.duckingGain,
    );
    final now = DateTime.now();
    final lastCorrection = _lastDriftCorrectionAt;
    final decision = decidePreviewMediaSync(
      timelineTarget: target,
      decoderPosition: controller.value.position,
      isPlaying: widget.isPlaying,
      isAudible: safeVolume > 0.001,
      isBuffering: controller.value.isBuffering,
      forceSeek: forceSeek,
      timeSinceLastCorrection: lastCorrection == null
          ? null
          : now.difference(lastCorrection),
    );
    if (decision == PreviewMediaSyncDecision.seek) {
      if (!forceSeek) widget.diagnostics.recordHardSeek();
      await controller.seekTo(target);
      if (!stillOwnsController()) return;
      _lastDriftCorrectionAt = now;
    }
    final canPlayForward =
        !widget.clip.isReversed &&
        (!widget.clip.freezeFrame || continuesFrozenAudio);
    if (canPlayForward) {
      final speed = (widget.playbackSpeed * widget.clip.playbackRate)
          .clamp(0.25, 4)
          .toDouble();
      if (_lastPlaybackSpeed == null ||
          (_lastPlaybackSpeed! - speed).abs() > 0.001) {
        await controller.setPlaybackSpeed(speed);
        if (!stillOwnsController()) return;
        _lastPlaybackSpeed = speed;
      }
    }

    if (_lastVolume == null || (_lastVolume! - safeVolume).abs() > 0.01) {
      await controller.setVolume(safeVolume);
      if (!stillOwnsController()) return;
      _lastVolume = safeVolume;
    }
    if (!canPlayForward) {
      if (controller.value.isPlaying) {
        await controller.pause();
      }
    } else if (widget.isPlaying && !controller.value.isPlaying) {
      await controller.play();
    } else if (!widget.isPlaying && controller.value.isPlaying) {
      await controller.pause();
    }
    if (stillOwnsController()) {
      _reportDiagnostics(controller, target, safeVolume);
    }
  }

  @override
  void dispose() {
    widget.diagnostics.removeDecoder(_diagnosticId);
    _controllerGeneration++;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onControllerDiagnosticUpdate);
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Duration _previewSourcePosition(
  TimelineClip clip,
  Duration timelinePosition, {
  bool holdFreezeFrame = true,
}) {
  if (clip.freezeFrame && holdFreezeFrame) {
    return clip.effectiveFreezeFrameSourceTime;
  }
  final elapsedMs = (timelinePosition - clip.startTime).inMilliseconds.clamp(
    0,
    clip.duration.inMilliseconds,
  );
  final forwardOffsetMs = (elapsedMs * clip.playbackRate).round();
  if (!clip.isReversed) {
    return clip.sourceStartTime + Duration(milliseconds: forwardOffsetMs);
  }
  final declaredSpanMs = clip.sourceDuration.inMilliseconds;
  final spanMs = declaredSpanMs > 0
      ? declaredSpanMs
      : (clip.duration.inMilliseconds * clip.playbackRate).round();
  final reversedOffsetMs = (spanMs - forwardOffsetMs - 1)
      .clamp(0, math.max(0, spanMs - 1))
      .toInt();
  return clip.sourceStartTime + Duration(milliseconds: reversedOffsetMs);
}

class _CanvasBoundLayer extends StatelessWidget {
  final double aspectRatio;
  final Widget child;

  const _CanvasBoundLayer({required this.aspectRatio, required this.child});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: ClipRect(child: child),
      ),
    );
  }
}

class _CanvasGuidesPainter extends CustomPainter {
  final bool showSafeAreas;
  final bool showGrid;
  final int gridDivisions;

  const _CanvasGuidesPainter({
    required this.showSafeAreas,
    required this.showGrid,
    required this.gridDivisions,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (showGrid) {
      final divisions = gridDivisions.clamp(2, 6);
      final gridPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..strokeWidth = 0.7;
      for (var index = 1; index < divisions; index++) {
        final x = size.width * index / divisions;
        final y = size.height * index / divisions;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
        canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      }
    }
    if (showSafeAreas) {
      final safePaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.32)
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke;
      canvas.drawRect(
        Rect.fromLTWH(
          size.width * 0.05,
          size.height * 0.05,
          size.width * 0.9,
          size.height * 0.9,
        ),
        safePaint,
      );
      canvas.drawRect(
        Rect.fromLTWH(
          size.width * 0.1,
          size.height * 0.1,
          size.width * 0.8,
          size.height * 0.8,
        ),
        safePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CanvasGuidesPainter oldDelegate) {
    return oldDelegate.showSafeAreas != showSafeAreas ||
        oldDelegate.showGrid != showGrid ||
        oldDelegate.gridDivisions != gridDivisions;
  }
}

class _OverlayTransformBox extends StatefulWidget {
  final Widget child;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onMoveStart;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final ValueChanged<double> onScaleFactorUpdate;
  final ValueChanged<double>? onRotationUpdate;

  const _OverlayTransformBox({
    required this.child,
    required this.isSelected,
    required this.onTap,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onScaleFactorUpdate,
    this.onRotationUpdate,
  });

  @override
  State<_OverlayTransformBox> createState() => _OverlayTransformBoxState();
}

class _OverlayTransformBoxState extends State<_OverlayTransformBox> {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onTap,
      onScaleStart: (_) {
        widget.onMoveStart();
      },
      onScaleUpdate: (details) {
        widget.onMoveUpdate(details.focalPointDelta);
        widget.onScaleFactorUpdate(details.scale);
        widget.onRotationUpdate?.call(details.rotation);
      },
      onScaleEnd: (_) => widget.onMoveEnd(),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(
                color: widget.isSelected
                    ? kAccent.withValues(alpha: 0.8)
                    : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
