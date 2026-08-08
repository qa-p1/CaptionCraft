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

const int _maxGifDecodeDimension = 2048;
const int _maxGifDecodedBytes = 48 * 1024 * 1024;
const int _maxGifEncodedBytes = 64 * 1024 * 1024;

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
  bool _initialized = false;
  bool _isSwitchingClip = false;
  bool _isAdvancingClip = false;
  bool _playRequested = false;
  bool _playbackSuspendedByLifecycle = false;
  Duration? _queuedSeekPosition;
  bool? _queuedSeekAutoplay;
  bool _queuedSeekForce = false;
  String? _previewError;
  Timer? _playbackTicker;
  double _playbackSpeed = 1.0;
  DateTime? _gapPlaybackStartedAt;
  Duration _gapPlaybackStartPosition = Duration.zero;
  DateTime? _reversePlaybackStartedAt;
  Duration _reversePlaybackStartPosition = Duration.zero;
  bool _isSeekingReverseFrame = false;
  EditorTimeline? _cachedCaptionTimeline;
  List<SubtitleEntry>? _cachedCaptionEntries;
  List<SubtitleEntry> _effectiveCaptionCache = const [];
  double? _dragSourceOffsetX;
  double? _dragSourceOffsetY;

  Duration _timelineDuration() {
    final timeline = ref.read(editorProvider).timeline;
    return timeline.tracks
        .expand((track) => track.clips)
        .fold<Duration>(
          Duration.zero,
          (current, clip) => clip.endTime > current ? clip.endTime : current,
        );
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
        final position = ref.read(playbackProvider).position;
        // Reverse, freeze-frame, and gap playback use wall-clock anchors.
        // Rebase those anchors to the last published playhead so background
        // time can never be counted when playback resumes.
        _gapPlaybackStartPosition = position;
        _gapPlaybackStartedAt = null;
        _reversePlaybackStartPosition = position;
        _reversePlaybackStartedAt = null;
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
    if (_playRequested &&
        (_gapPlaybackStartedAt != null ||
            _controllerClip?.isReversed == true ||
            _controllerClip?.freezeFrame == true)) {
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
        _gapPlaybackStartedAt != null ||
        clip.isReversed ||
        clip.freezeFrame) {
      return;
    }
    final controllerValue = controller.value;
    final playback = ref.read(playbackProvider.notifier);
    final editorDuration = _timelineDuration();
    if (editorDuration > Duration.zero) {
      playback.updateDuration(editorDuration);
    }
    final sourceElapsed = controllerValue.position - clip.sourceStartTime;
    final timelineElapsedMs = (sourceElapsed.inMilliseconds / clip.playbackRate)
        .round();
    final timelinePosition =
        clip.startTime + Duration(milliseconds: timelineElapsedMs);
    final clampedPosition = timelinePosition < clip.startTime
        ? clip.startTime
        : timelinePosition > clip.endTime
        ? clip.endTime
        : timelinePosition;
    playback.updatePosition(clampedPosition);
    playback.setPlaying(_playRequested);
    unawaited(_applyBaseAudioVolume(clampedPosition));

    if (_playRequested) {
      final playbackRange = _playbackRange(ref.read(editorProvider).timeline);
      if (clampedPosition >= playbackRange.end) {
        unawaited(_handlePlaybackRangeEnd());
      } else if (clampedPosition >=
              clip.endTime - const Duration(milliseconds: 34) ||
          controllerValue.isCompleted) {
        unawaited(_advanceFromClip(clip));
      }
    }
  }

  void _startPlaybackTicker() {
    if (_playbackTicker?.isActive == true) return;
    _playbackTicker = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!_initialized || !mounted || _playbackSuspendedByLifecycle) return;
      final reverseStarted = _reversePlaybackStartedAt;
      final reverseClip = _controllerClip;
      if (_playRequested &&
          reverseStarted != null &&
          reverseClip != null &&
          (reverseClip.isReversed || reverseClip.freezeFrame)) {
        final elapsed = DateTime.now().difference(reverseStarted);
        final advanced = Duration(
          microseconds: (elapsed.inMicroseconds * _playbackSpeed).round(),
        );
        final target = _reversePlaybackStartPosition + advanced;
        final timeline = ref.read(editorProvider).timeline;
        if (target >= _playbackRange(timeline).end) {
          unawaited(_handlePlaybackRangeEnd());
        } else if (target >= reverseClip.endTime) {
          unawaited(_advanceFromClip(reverseClip));
        } else if (reverseClip.freezeFrame) {
          ref.read(playbackProvider.notifier)
            ..updatePosition(target)
            ..setPlaying(true);
          unawaited(_applyBaseAudioVolume(target));
        } else if (!_isSeekingReverseFrame) {
          unawaited(_seekReversedFrame(target));
        }
        return;
      }
      final gapStarted = _gapPlaybackStartedAt;
      if (_playRequested && gapStarted != null) {
        final elapsed = DateTime.now().difference(gapStarted);
        final advanced = Duration(
          microseconds: (elapsed.inMicroseconds * _playbackSpeed).round(),
        );
        final target = _gapPlaybackStartPosition + advanced;
        final timeline = ref.read(editorProvider).timeline;
        final playbackRange = _playbackRange(timeline);
        if (target >= playbackRange.end) {
          unawaited(_handlePlaybackRangeEnd());
          return;
        }
        final nextSelection = _baseSelectionAt(
          ref.read(editorProvider).timeline,
          target,
        );
        if (nextSelection != null) {
          unawaited(
            _seekTimelinePosition(target, autoplay: true, forceSeek: true),
          );
          return;
        }
        ref.read(playbackProvider.notifier).updatePosition(target);
        return;
      }
      // Forward playback is driven by VideoPlayerController's listener. A
      // second 30 Hz state publisher here doubled provider updates and rebuilt
      // the editor twice per frame.
      _stopPlaybackTicker();
    });
  }

  void _stopPlaybackTicker() {
    _playbackTicker?.cancel();
    _playbackTicker = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPlaybackTicker();
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onPlaybackUpdate);
      controller.dispose();
    }
    super.dispose();
  }

  void _togglePlayPause() {
    final playback = ref.read(playbackProvider);
    if (_playRequested) {
      _playRequested = false;
      _gapPlaybackStartedAt = null;
      _reversePlaybackStartedAt = null;
      unawaited(_controller?.pause());
      _stopPlaybackTicker();
      ref.read(playbackProvider.notifier).setPlaying(false);
    } else {
      final startPosition = playback.position >= playback.duration
          ? Duration.zero
          : playback.position;
      _playRequested = true;
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
    final controller = _controller;
    final clip = _controllerClip;
    if (controller != null && clip != null) {
      if (!clip.isReversed && !clip.freezeFrame) {
        await controller.setPlaybackSpeed(
          (speed * clip.playbackRate).clamp(0.25, 4),
        );
      }
    }
    if (!mounted) return;
    setState(() => _playbackSpeed = speed);
    if (_gapPlaybackStartedAt != null) {
      final current = ref.read(playbackProvider).position;
      _gapPlaybackStartPosition = current;
      _gapPlaybackStartedAt = DateTime.now();
    }
    if (_reversePlaybackStartedAt != null) {
      final current = ref.read(playbackProvider).position;
      _reversePlaybackStartPosition = current;
      _reversePlaybackStartedAt = DateTime.now();
    }
  }

  (TimelineTrack, TimelineClip)? _baseSelectionAt(
    EditorTimeline timeline,
    Duration position,
  ) {
    for (final track in timeline.tracks) {
      if (track.section != TimelineTrackSection.baseVideo || track.isHidden) {
        continue;
      }
      final clips = [...track.clips]
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
      for (final clip in clips) {
        if (!clip.enabled) continue;
        final isLastFrame =
            position == timeline.duration && position == clip.endTime;
        if (position >= clip.startTime &&
            (position < clip.endTime || isLastFrame)) {
          return (track, clip);
        }
      }
    }
    return null;
  }

  String? _sourcePathForClip(EditorTimeline timeline, TimelineClip clip) {
    return resolvePreviewSourcePathForTesting(
      timeline: timeline,
      clip: clip,
      legacyVideoPath: widget.videoPath,
      fileExists: (path) => File(path).existsSync(),
    );
  }

  Future<void> _seekTimelinePosition(
    Duration requested, {
    bool? autoplay,
    bool forceSeek = false,
  }) async {
    if (!_initialized || !mounted) return;
    if (_isSwitchingClip) {
      _queuedSeekPosition = requested;
      _queuedSeekAutoplay = autoplay;
      _queuedSeekForce = _queuedSeekForce || forceSeek;
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
    final selection = _baseSelectionAt(timeline, target);
    final playbackNotifier = ref.read(playbackProvider.notifier);

    if (selection == null) {
      _reversePlaybackStartedAt = null;
      _gapPlaybackStartPosition = target;
      final controller = _controller;
      if (controller?.value.isPlaying == true) {
        await controller!.pause();
      }
      final playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      _gapPlaybackStartedAt = playNow ? DateTime.now() : null;
      _controllerClip = null;
      _controllerTrack = null;
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(target)
        ..setPlaying(playNow)
        ..setReady(true);
      if (mounted) setState(() {});
      if (playNow) _startPlaybackTicker();
      return;
    }

    _gapPlaybackStartedAt = null;
    final track = selection.$1;
    final clip = selection.$2;
    final sourcePath = _sourcePathForClip(timeline, clip);
    if (sourcePath == null) {
      final unavailableController = _controller;
      unavailableController?.removeListener(_onPlaybackUpdate);
      _controller = null;
      _controllerClip = null;
      _controllerTrack = null;
      _controllerPath = null;
      _playRequested = false;
      _gapPlaybackStartedAt = null;
      _reversePlaybackStartedAt = null;
      _previewError = 'Media is missing for "${clip.label}". Relink it first.';
      _stopPlaybackTicker();
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(target)
        ..setPlaying(false)
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
      return;
    }
    final sourceTarget = _sourceTargetForClip(clip, target);

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
      final drift = (currentController.value.position - sourceTarget)
          .inMilliseconds
          .abs();
      if (forceSeek || drift > 90) {
        await currentController.seekTo(sourceTarget);
      }
      if (!clip.isReversed && !clip.freezeFrame) {
        await currentController.setPlaybackSpeed(
          (_playbackSpeed * clip.playbackRate).clamp(0.25, 4),
        );
      }
      await _applyBaseAudioVolume(target);
      var playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      if (clip.isReversed || clip.freezeFrame) {
        if (currentController.value.isPlaying) {
          await currentController.pause();
        }
        _reversePlaybackStartPosition = target;
        playNow = shouldPlay && !_playbackSuspendedByLifecycle;
        _reversePlaybackStartedAt = playNow ? DateTime.now() : null;
      } else if (playNow && !currentController.value.isPlaying) {
        _reversePlaybackStartedAt = null;
        await currentController.play();
      } else if (!playNow && currentController.value.isPlaying) {
        _reversePlaybackStartedAt = null;
        await currentController.pause();
      } else {
        _reversePlaybackStartedAt = null;
      }
      playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      if (!playNow && currentController.value.isPlaying) {
        await currentController.pause();
      }
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(target)
        ..setPlaying(playNow);
      if (playNow) _startPlaybackTicker();
      return;
    }

    _isSwitchingClip = true;
    VideoPlayerController? nextController;
    try {
      _previewError = null;
      if (currentController != null) {
        currentController.removeListener(_onPlaybackUpdate);
        await currentController.pause();
        await currentController.dispose();
      }
      nextController = VideoPlayerController.file(File(sourcePath));
      await nextController.initialize();
      await nextController.seekTo(sourceTarget);
      if (!clip.isReversed && !clip.freezeFrame) {
        await nextController.setPlaybackSpeed(
          (_playbackSpeed * clip.playbackRate).clamp(0.25, 4),
        );
      }
      if (!mounted) {
        await nextController.dispose();
        return;
      }
      _controller = nextController;
      _controllerClip = clip;
      _controllerTrack = track;
      _controllerPath = sourcePath;
      nextController.addListener(_onPlaybackUpdate);
      await _applyBaseAudioVolume(target);
      var playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      if (clip.isReversed || clip.freezeFrame) {
        _reversePlaybackStartPosition = target;
        _reversePlaybackStartedAt = playNow ? DateTime.now() : null;
      } else {
        _reversePlaybackStartedAt = null;
        if (playNow) await nextController.play();
      }
      playNow = shouldPlay && !_playbackSuspendedByLifecycle;
      if (!playNow && nextController.value.isPlaying) {
        await nextController.pause();
      }
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(target)
        ..setPlaying(playNow)
        ..setReady(true);
      setState(() {});
      if (playNow) _startPlaybackTicker();
    } catch (_) {
      final failedController = nextController;
      if (failedController != null) {
        try {
          failedController.removeListener(_onPlaybackUpdate);
          await failedController.dispose();
        } catch (_) {
          // Initialization can leave the platform controller partly torn down.
        }
      }
      _controller = null;
      _controllerClip = null;
      _controllerTrack = null;
      _controllerPath = null;
      _playRequested = false;
      _reversePlaybackStartedAt = null;
      _previewError = 'This clip could not be decoded on this device.';
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(target)
        ..setPlaying(false)
        ..setReady(true);
      if (mounted) setState(() {});
    } finally {
      _isSwitchingClip = false;
      final queuedPosition = _queuedSeekPosition;
      final queuedAutoplay = _queuedSeekAutoplay;
      final queuedForce = _queuedSeekForce;
      _queuedSeekPosition = null;
      _queuedSeekAutoplay = null;
      _queuedSeekForce = false;
      if (queuedPosition != null && mounted) {
        unawaited(
          _seekTimelinePosition(
            queuedPosition,
            autoplay: queuedAutoplay,
            forceSeek: queuedForce,
          ),
        );
      }
    }
  }

  Future<void> _advanceFromClip(TimelineClip completedClip) async {
    if (_isAdvancingClip || !_playRequested || !mounted) return;
    _isAdvancingClip = true;
    _reversePlaybackStartedAt = null;
    try {
      final timeline = ref.read(editorProvider).timeline;
      final nextPosition = completedClip.endTime;
      if (nextPosition >= _playbackRange(timeline).end) {
        await _finishPlaybackRange(timeline);
        return;
      }
      await _seekTimelinePosition(
        nextPosition,
        autoplay: true,
        forceSeek: true,
      );
    } finally {
      _isAdvancingClip = false;
    }
  }

  Future<void> _handlePlaybackRangeEnd() async {
    if (_isAdvancingClip || !_playRequested || !mounted) return;
    _isAdvancingClip = true;
    _reversePlaybackStartedAt = null;
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
    _gapPlaybackStartedAt = null;
    _reversePlaybackStartedAt = null;
    await _seekTimelinePosition(
      playbackRange.end,
      autoplay: false,
      forceSeek: true,
    );
    _stopPlaybackTicker();
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
    final volume = _previewAudioVolume(
      clip: clip,
      position: position,
      isTrackAudible: !track.isMuted && (!hasSolo || track.isSolo),
      duckingGain: _previewDuckingGain(clip, position),
    );
    await controller.setVolume(volume);
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
    final notifier = ref.read(subtitleProvider.notifier);
    notifier.selectEntry(activeEntry.id);
    notifier.beginStyleGestureEdit();
  }

  void _endStyleGesture() {
    _dragSourceOffsetX = null;
    _dragSourceOffsetY = null;
    ref.read(subtitleProvider.notifier).endStyleGestureEdit();
  }

  List<_OverlayCanvasItem> _activeOverlayItems(
    EditorTimeline timeline,
    Duration position,
  ) {
    final items = <_OverlayCanvasItem>[];
    for (
      var trackIndex = 0;
      trackIndex < timeline.tracks.length;
      trackIndex++
    ) {
      final track = timeline.tracks[trackIndex];
      if (track.section != TimelineTrackSection.overlay || track.isHidden) {
        continue;
      }
      for (final clip in track.clips) {
        if (!clip.enabled ||
            position < clip.startTime ||
            position >= clip.endTime) {
          continue;
        }
        EditorAssetReference? asset;
        for (final candidate in timeline.assets) {
          if (candidate.id == clip.assetId) {
            asset = candidate;
            break;
          }
        }
        if (asset == null) continue;
        items.add(
          _OverlayCanvasItem(
            trackIndex: trackIndex,
            track: track,
            clip: clip,
            asset: asset,
          ),
        );
      }
    }

    items.sort((a, b) {
      final trackCompare = a.trackIndex.compareTo(b.trackIndex);
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
    final items = <_EffectCanvasItem>[];
    for (
      var trackIndex = 0;
      trackIndex < timeline.tracks.length;
      trackIndex++
    ) {
      final track = timeline.tracks[trackIndex];
      if (track.type != TimelineTrackType.effect || track.isHidden) continue;
      for (final clip in track.clips) {
        if (!clip.enabled ||
            !clip.isEffect ||
            position < clip.startTime ||
            position >= clip.endTime) {
          continue;
        }
        items.add(
          _EffectCanvasItem(
            trackIndex: trackIndex,
            trackId: track.id,
            clip: clip,
          ),
        );
      }
    }
    items.sort((a, b) {
      final trackCompare = a.trackIndex.compareTo(b.trackIndex);
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
    final items = <_TextCanvasItem>[];
    for (
      var trackIndex = 0;
      trackIndex < timeline.tracks.length;
      trackIndex++
    ) {
      final track = timeline.tracks[trackIndex];
      if (track.type != TimelineTrackType.text || track.isHidden) continue;
      for (final clip in track.clips) {
        if (!clip.enabled ||
            position < clip.startTime ||
            position >= clip.endTime) {
          continue;
        }
        items.add(
          _TextCanvasItem(
            trackIndex: trackIndex,
            trackId: track.id,
            clip: clip,
          ),
        );
      }
    }

    items.sort((a, b) {
      final trackCompare = a.trackIndex.compareTo(b.trackIndex);
      if (trackCompare != 0) return trackCompare;
      return a.clip.layer.compareTo(b.clip.layer);
    });
    return items;
  }

  List<_AudioCanvasItem> _activeAudioItems(
    EditorTimeline timeline,
    Duration position,
  ) {
    final items = <_AudioCanvasItem>[];
    for (final track in timeline.tracks) {
      if (track.section != TimelineTrackSection.audio) continue;
      for (final clip in track.clips) {
        if (!clip.enabled ||
            position < clip.startTime ||
            position >= clip.endTime) {
          continue;
        }
        final asset = timeline.assetForClip(clip);
        final sourcePath = asset?.sourcePath;
        if (asset == null ||
            sourcePath == null ||
            !File(sourcePath).existsSync()) {
          continue;
        }
        items.add(_AudioCanvasItem(track: track, clip: clip, asset: asset));
      }
    }
    return items;
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
  }

  void _endSnappedDrag() {
    _dragSourceOffsetX = null;
    _dragSourceOffsetY = null;
    ref.read(editorProvider.notifier).endTimelineGestureEdit();
  }

  bool _hasSoloMediaTrack(EditorTimeline timeline) {
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

  double _previewDuckingGain(TimelineClip clip, Duration position) {
    if (!clip.autoDuck || clip.duckAmount <= 0.001) return 1;
    final timeline = ref.read(editorProvider).timeline;
    final duckedGain = (1 - clip.duckAmount.clamp(0.0, 1.0)).toDouble();
    final positionMs = position.inMilliseconds;
    final clipStartMs = clip.startTime.inMilliseconds;
    final clipEndMs = clip.endTime.inMilliseconds;
    final intervals = <(int, int)>[];

    void addInterval(Duration start, Duration end) {
      final startMs = math.max(clipStartMs, start.inMilliseconds);
      final endMs = math.min(clipEndMs, end.inMilliseconds);
      if (endMs > startMs) intervals.add((startMs, endMs));
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

    final hasSoloTrack = _hasSoloMediaTrack(timeline);
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

    if (intervals.isEmpty) return 1;
    intervals.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final interval in intervals) {
      if (merged.isEmpty || interval.$1 > merged.last.$2 + 300) {
        merged.add(interval);
      } else {
        final previous = merged.removeLast();
        merged.add((previous.$1, math.max(previous.$2, interval.$2)));
      }
    }

    var gain = 1.0;
    for (final interval in merged) {
      final startMs = interval.$1;
      final endMs = interval.$2;
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

  void _updateEffectBlur(
    String clipId,
    ClipBlurSettings Function(ClipBlurSettings current) mapper,
  ) {
    final editorState = ref.read(editorProvider);
    final nextTracks = editorState.timeline.tracks.map((track) {
      final updatedClips = track.clips.map((clip) {
        if (clip.id != clipId) return clip;
        return clip.copyWith(blur: mapper(clip.blur));
      }).toList();
      return track.copyWith(clips: updatedClips);
    }).toList();
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          editorState.timeline.copyWith(tracks: nextTracks),
          recordHistory: false,
        );
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
    final previewUrl =
        item.asset.metadata['previewUrl'] as String? ?? item.asset.remoteUrl;
    final localPath = item.asset.sourcePath;
    final localFile = localPath == null ? null : File(localPath);
    final hasLocalFile = localFile?.existsSync() ?? false;
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
        key: ValueKey('gif_${item.clip.id}'),
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
                  filterQuality: FilterQuality.medium,
                )
              : previewUrl != null
              ? Image.network(
                  previewUrl,
                  width: baseWidth,
                  height: previewHeight,
                  fit: overlayFit,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) =>
                      _buildMissingOverlay(item.clip.label),
                )
              : _buildMissingOverlay(item.clip.label),
        ),
        EditorAssetType.video =>
          hasLocalFile
              ? _OverlayVideoPreview(
                  key: ValueKey(item.clip.id),
                  videoPath: localFile!.path,
                  clip: item.clip,
                  playbackPosition: playbackState.position,
                  isPlaying: playbackState.isPlaying,
                  playbackSpeed: _playbackSpeed,
                  // Timeline region effects paint a filtered media copy.
                  // Keep visual controllers silent so that copy can never
                  // double the monitored audio; one hidden controller below
                  // owns audio for each overlay clip.
                  duckingGain: 1,
                  isTrackAudible: false,
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
                  filterQuality: FilterQuality.medium,
                )
              : previewUrl != null
              ? Image.network(
                  previewUrl,
                  width: baseWidth,
                  height: previewHeight,
                  fit: overlayFit,
                  filterQuality: FilterQuality.medium,
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
          angle: transform.rotation,
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
    var offset = Offset.zero;

    final elapsedMs = (position - clip.startTime).inMilliseconds
        .clamp(0, clip.duration.inMilliseconds)
        .toDouble();
    final remainingMs = (clip.endTime - position).inMilliseconds
        .clamp(0, clip.duration.inMilliseconds)
        .toDouble();

    void applyTransition(ClipTransition transition, double hiddenAmount) {
      if (transition.type == TransitionType.none ||
          transition.type == TransitionType.cut ||
          hiddenAmount <= 0) {
        return;
      }

      // Dissolve uses the same eased alpha curve as export; the remaining
      // transitions deliberately retain a linear envelope.
      final visibleAmount = (1 - hiddenAmount).clamp(0.0, 1.0).toDouble();
      final alphaAmount = transition.type == TransitionType.dissolve
          ? visibleAmount * visibleAmount * (3 - 2 * visibleAmount)
          : visibleAmount;
      opacity *= alphaAmount;
      switch (transition.type) {
        case TransitionType.fade:
        case TransitionType.dissolve:
          break;
        case TransitionType.zoom:
          // A zoom animation should change geometry as well as opacity. Keep
          // the range restrained so it reads as motion without exposing the
          // fitted media outside the canvas bounds.
          scale *= 1 - (hiddenAmount * 0.15);
          break;
        case TransitionType.slideLeft:
          offset += Offset(-constraints.maxWidth * hiddenAmount, 0);
          break;
        case TransitionType.slideRight:
          offset += Offset(constraints.maxWidth * hiddenAmount, 0);
          break;
        case TransitionType.slideUp:
          offset += Offset(0, -constraints.maxHeight * hiddenAmount);
          break;
        case TransitionType.slideDown:
          offset += Offset(0, constraints.maxHeight * hiddenAmount);
          break;
        case TransitionType.none:
        case TransitionType.cut:
          break;
      }
    }

    final introDuration = clip.effectiveIntroTransitionMs;
    if (introDuration > 0 && elapsedMs < introDuration) {
      final hiddenAmount = 1 - (elapsedMs / introDuration).clamp(0.0, 1.0);
      applyTransition(clip.introTransition, hiddenAmount);
    }

    final outroDuration = clip.effectiveOutroTransitionMs;
    if (outroDuration > 0 && remainingMs < outroDuration) {
      final hiddenAmount = 1 - (remainingMs / outroDuration).clamp(0.0, 1.0);
      applyTransition(clip.outroTransition, hiddenAmount);
    }

    return _OverlayAnimationState(
      opacity: opacity.clamp(0.0, 1.0),
      scale: scale.clamp(0.2, 4.0),
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
    child = Transform.rotate(angle: transform.rotation, child: child);
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
          effected = _applyBlurPreview(
            effected,
            _resolvedBlurAt(effect.clip, playbackPosition),
          );
          break;
        case null:
          break;
      }
    }
    return effected;
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
              return Positioned(
                left: constraints.maxWidth * blur.safeRegionX,
                top: constraints.maxHeight * blur.safeRegionY,
                width: constraints.maxWidth * blur.safeRegionWidth,
                height: constraints.maxHeight * blur.safeRegionHeight,
                child: _OverlayTransformBox(
                  isSelected: isSelected,
                  onTap: () => _selectEffectClip(item),
                  onMoveStart: () {
                    _selectEffectClip(item);
                    ref
                        .read(editorProvider.notifier)
                        .beginTimelineGestureEdit();
                  },
                  onMoveUpdate: (delta) {
                    _updateEffectBlur(
                      clip.id,
                      (current) => current.copyWith(
                        regionX:
                            (current.safeRegionX +
                                    delta.dx / constraints.maxWidth)
                                .clamp(0.0, 1 - current.safeRegionWidth)
                                .toDouble(),
                        regionY:
                            (current.safeRegionY +
                                    delta.dy / constraints.maxHeight)
                                .clamp(0.0, 1 - current.safeRegionHeight)
                                .toDouble(),
                      ),
                    );
                  },
                  onMoveEnd: () => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                  onWidthResizeStart: () {
                    _selectEffectClip(item);
                    ref
                        .read(editorProvider.notifier)
                        .beginTimelineGestureEdit();
                  },
                  onWidthResizeUpdate: (delta) {
                    _updateEffectBlur(
                      clip.id,
                      (current) => current.copyWith(
                        regionWidth:
                            (current.safeRegionWidth +
                                    delta.dx / constraints.maxWidth)
                                .clamp(0.08, 1 - current.safeRegionX)
                                .toDouble(),
                      ),
                    );
                  },
                  onWidthResizeEnd: () => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                  onHeightResizeStart: () {
                    _selectEffectClip(item);
                    ref
                        .read(editorProvider.notifier)
                        .beginTimelineGestureEdit();
                  },
                  onHeightResizeUpdate: (delta) {
                    _updateEffectBlur(
                      clip.id,
                      (current) => current.copyWith(
                        regionHeight:
                            (current.safeRegionHeight +
                                    delta.dy / constraints.maxHeight)
                                .clamp(0.08, 1 - current.safeRegionY)
                                .toDouble(),
                      ),
                    );
                  },
                  onHeightResizeEnd: () => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                  child: ColoredBox(
                    color: isSelected
                        ? kAccent.withValues(alpha: 0.035)
                        : Colors.transparent,
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
    final activeAudioItems = _activeAudioItems(
      editorState.timeline,
      playbackState.position,
    );
    final activeBaseClip = _activeBaseClip(
      editorState.timeline,
      playbackState.position,
    );
    final effectiveCaptions = _effectiveCaptions(
      editorState.timeline,
      subtitleState.entries,
    );
    final controller = _controller;
    final controllerPath = _controllerPath;
    final controllerTrack = _controllerTrack;
    final controllerReady =
        controller != null &&
        controller.value.isInitialized &&
        activeBaseClip != null &&
        _controllerClip?.id == activeBaseClip.id;
    final previewAspectRatio =
        widget.targetAspectRatio ??
        (controllerReady ? controller.value.aspectRatio : 16 / 9);

    SubtitleEntry? activeSubtitle;
    for (final entry in effectiveCaptions) {
      if (playbackState.position >= entry.startTime &&
          playbackState.position < entry.endTime) {
        activeSubtitle = entry;
        break;
      }
    }

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
                                    final mediaLayers = <Widget>[
                                      if (controllerReady)
                                        _buildBaseVideoLayer(
                                          controller: controller,
                                          clip: activeBaseClip,
                                          constraints: constraints,
                                          playbackPosition:
                                              playbackState.position,
                                        ),
                                      for (final item in activeOverlayItems)
                                        Align(
                                          child: Transform.translate(
                                            offset: Offset(
                                              item.clip
                                                      .transformAt(
                                                        playbackState.position,
                                                      )
                                                      .offsetX *
                                                  constraints.maxWidth /
                                                  kTimelineDesignWidth,
                                              item.clip
                                                      .transformAt(
                                                        playbackState.position,
                                                      )
                                                      .offsetY *
                                                  constraints.maxHeight /
                                                  kTimelineDesignHeight,
                                            ),
                                            child: _buildOverlayAsset(
                                              item,
                                              constraints,
                                              playbackState,
                                            ),
                                          ),
                                        ),
                                    ];
                                    return _buildComposedMediaPreview(
                                      backgroundColor: editorState
                                          .timeline
                                          .canvasSettings
                                          .backgroundColor,
                                      mediaLayers: mediaLayers,
                                      timelineEffectsBuilder: (composedMedia) =>
                                          _applyTimelineEffectsToMedia(
                                            composedMedia,
                                            activeEffectItems,
                                            playbackState.position,
                                          ),
                                    );
                                  },
                                ),
                              ),
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
                              child: AnimatedOpacity(
                                opacity: playbackState.isPlaying ? 0 : 0.7,
                                duration: const Duration(milliseconds: 200),
                                child: const Center(
                                  child: Icon(
                                    Icons.play_circle_filled_rounded,
                                    size: 56,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
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
                                            onWidthResizeStart: () {
                                              _selectOverlayClip(item);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .beginTimelineGestureEdit();
                                            },
                                            onWidthResizeUpdate: (delta) {
                                              _updateOverlayTransform(
                                                item.clip.id,
                                                (current) => current.copyWith(
                                                  scale:
                                                      (current.scale +
                                                              (delta.dx /
                                                                  constraints
                                                                      .maxWidth))
                                                          .clamp(0.2, 4.0)
                                                          .toDouble(),
                                                ),
                                              );
                                            },
                                            onWidthResizeEnd: () => ref
                                                .read(editorProvider.notifier)
                                                .endTimelineGestureEdit(),
                                            onHeightResizeStart: () {
                                              _selectOverlayClip(item);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .beginTimelineGestureEdit();
                                            },
                                            onHeightResizeUpdate: (delta) {
                                              _updateOverlayTransform(
                                                item.clip.id,
                                                (current) => current.copyWith(
                                                  scale:
                                                      (current.scale +
                                                              (delta.dy /
                                                                  constraints
                                                                      .maxHeight))
                                                          .clamp(0.2, 4.0)
                                                          .toDouble(),
                                                ),
                                              );
                                            },
                                            onHeightResizeEnd: () => ref
                                                .read(editorProvider.notifier)
                                                .endTimelineGestureEdit(),
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
                                      Widget textPreview = ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth:
                                              constraints.maxWidth *
                                              style.maxWidthFactor,
                                        ),
                                        child: Text(
                                          item.clip.text ?? item.clip.label,
                                          textAlign: style.textAlignment,
                                          style: TextStyle(
                                            color: style.textColor,
                                            fontSize:
                                                style.fontSize *
                                                constraints.maxHeight /
                                                kTimelineDesignHeight,
                                            fontWeight: style.isBold
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            fontStyle: style.isItalic
                                                ? FontStyle.italic
                                                : FontStyle.normal,
                                          ),
                                        ),
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
                                            onWidthResizeStart: () {
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectTrack(item.trackId);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectClip(item.clip.id);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .beginTimelineGestureEdit();
                                            },
                                            onWidthResizeUpdate: (delta) {
                                              _updateOverlayTransform(
                                                item.clip.id,
                                                (current) => current.copyWith(
                                                  scale:
                                                      (current.scale +
                                                              (delta.dx /
                                                                  constraints
                                                                      .maxWidth))
                                                          .clamp(0.25, 4.0)
                                                          .toDouble(),
                                                ),
                                              );
                                            },
                                            onWidthResizeEnd: () => ref
                                                .read(editorProvider.notifier)
                                                .endTimelineGestureEdit(),
                                            onHeightResizeStart: () {
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectTrack(item.trackId);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .selectClip(item.clip.id);
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .beginTimelineGestureEdit();
                                            },
                                            onHeightResizeUpdate: (delta) {
                                              _updateOverlayTransform(
                                                item.clip.id,
                                                (current) => current.copyWith(
                                                  scale:
                                                      (current.scale +
                                                              (delta.dy /
                                                                  constraints
                                                                      .maxHeight))
                                                          .clamp(0.25, 4.0)
                                                          .toDouble(),
                                                ),
                                              );
                                            },
                                            onHeightResizeEnd: () => ref
                                                .read(editorProvider.notifier)
                                                .endTimelineGestureEdit(),
                                            child: textPreview,
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
                                  final activeEntry = activeSubtitle!;
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
                                        onWidthResizeStart: () =>
                                            _beginStyleGesture(
                                              activeEntry,
                                              editPerEntry,
                                            ),
                                        onWidthResizeUpdate: (delta) {
                                          final style = _readEditableStyleFor(
                                            activeEntry,
                                            editPerEntry,
                                          );
                                          final widthDelta =
                                              delta.dx / constraints.maxWidth;
                                          final nextWidth =
                                              (style.maxWidthFactor +
                                                      widthDelta)
                                                  .clamp(0.25, 1.0)
                                                  .toDouble();

                                          _applyStyleLive(
                                            activeEntry: activeEntry,
                                            editPerEntry: editPerEntry,
                                            style: style.copyWith(
                                              maxWidthFactor: nextWidth,
                                            ),
                                          );
                                        },
                                        onWidthResizeEnd: _endStyleGesture,
                                        onHeightResizeStart: () =>
                                            _beginStyleGesture(
                                              activeEntry,
                                              editPerEntry,
                                            ),
                                        onHeightResizeUpdate: (delta) {
                                          final style = _readEditableStyleFor(
                                            activeEntry,
                                            editPerEntry,
                                          );
                                          final nextFontSize =
                                              (style.fontSize +
                                                      delta.dy *
                                                          kTimelineDesignHeight /
                                                          constraints
                                                              .maxHeight *
                                                          0.25)
                                                  .clamp(1.0, 72.0)
                                                  .toDouble();

                                          _applyStyleLive(
                                            activeEntry: activeEntry,
                                            editPerEntry: editPerEntry,
                                            style: style.copyWith(
                                              fontSize: nextFontSize,
                                            ),
                                          );
                                        },
                                        onHeightResizeEnd: _endStyleGesture,
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
                                item.asset.sourcePath != null &&
                                File(item.asset.sourcePath!).existsSync() &&
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
                                  duckingGain: _previewDuckingGain(
                                    item.clip,
                                    playbackState.position,
                                  ),
                                  isTrackAudible:
                                      !item.track.isMuted &&
                                      (!_hasSoloMediaTrack(
                                            editorState.timeline,
                                          ) ||
                                          item.track.isSolo),
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
                                isPlaying: playbackState.isPlaying,
                                playbackSpeed: _playbackSpeed,
                                duckingGain: _previewDuckingGain(
                                  item.clip,
                                  playbackState.position,
                                ),
                                isTrackAudible:
                                    !item.track.isMuted &&
                                    (!_hasSoloMediaTrack(
                                          editorState.timeline,
                                        ) ||
                                        item.track.isSolo),
                              ),
                            ),
                          if (controllerReady &&
                              activeBaseClip.freezeFrame &&
                              !activeBaseClip.isReversed &&
                              controllerPath != null &&
                              controllerTrack != null &&
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
                                duckingGain: _previewDuckingGain(
                                  activeBaseClip,
                                  playbackState.position,
                                ),
                                isTrackAudible:
                                    !controllerTrack.isMuted &&
                                    (!_hasSoloMediaTrack(
                                          editorState.timeline,
                                        ) ||
                                        controllerTrack.isSolo),
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

class _OverlayAnimationState {
  final double opacity;
  final double scale;
  final Offset offset;

  const _OverlayAnimationState({
    required this.opacity,
    required this.scale,
    required this.offset,
  });
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

  const _AudioCanvasItem({
    required this.track,
    required this.clip,
    required this.asset,
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
    required this.mediaEffectsBuilder,
  });

  @override
  State<_TimelineGifPreview> createState() => _TimelineGifPreviewState();
}

class _TimelineGifPreviewState extends State<_TimelineGifPreview> {
  List<_DecodedGifFrame> _frames = const [];
  int _totalDurationMs = 0;
  int _decodeGeneration = 0;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_decodeFrames());
  }

  @override
  void didUpdateWidget(covariant _TimelineGifPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath ||
        oldWidget.remoteUrl != widget.remoteUrl ||
        oldWidget.width.ceil() != widget.width.ceil() ||
        oldWidget.height.ceil() != widget.height.ceil()) {
      unawaited(_decodeFrames());
    }
  }

  Future<Uint8List> _loadBytes() async {
    final filePath = widget.filePath;
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
    final uri = Uri.tryParse(widget.remoteUrl ?? '');
    if (uri == null || !uri.hasScheme) {
      throw const FormatException('Invalid GIF source');
    }
    final client = HttpClient();
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
      client.close(force: true);
    }
  }

  Future<void> _decodeFrames() async {
    final generation = ++_decodeGeneration;
    _disposeFrames();
    _loading = true;
    _failed = false;
    try {
      final bytes = await _loadBytes();
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

      final targetSize = calculateGifDecodeSizeForTesting(
        intrinsicWidth: intrinsicWidth,
        intrinsicHeight: intrinsicHeight,
        frameCount: frameCount,
        maxWidth: widget.width,
        maxHeight: widget.height,
      );
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetSize.width.toInt(),
        targetHeight: targetSize.height.toInt(),
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
      setState(() {
        _frames = decoded;
        _totalDurationMs = math.max(1, elapsedMs);
        _loading = false;
        _failed = decoded.isEmpty;
      });
    } catch (_) {
      if (!mounted || generation != _decodeGeneration) return;
      setState(() {
        _loading = false;
        _failed = true;
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
          borderRadius: BorderRadius.circular(10),
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

class _OverlayVideoPreview extends StatefulWidget {
  final String videoPath;
  final TimelineClip clip;
  final Duration playbackPosition;
  final bool isPlaying;
  final double playbackSpeed;
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
  bool _ready = false;
  bool _syncInFlight = false;
  bool _syncQueued = false;
  bool _forceSeekQueued = false;
  double? _lastVolume;
  double? _lastPlaybackSpeed;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant _OverlayVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      unawaited(_replaceController());
      return;
    }
    _schedulePlaybackSync();
  }

  Future<void> _initialize() async {
    VideoPlayerController? createdController;
    try {
      final controller = VideoPlayerController.file(File(widget.videoPath));
      createdController = controller;
      await controller.initialize();
      await controller.setVolume(0);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _ready = true;
      });
      _lastVolume = 0;
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
      if (mounted) setState(() => _ready = false);
    }
  }

  void _schedulePlaybackSync({bool forceSeek = false}) {
    if (_syncInFlight) {
      _syncQueued = true;
      _forceSeekQueued = _forceSeekQueued || forceSeek;
      return;
    }
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
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return;
    }

    final relative = _previewSourcePosition(
      widget.clip,
      widget.playbackPosition,
    );
    final targetMs = relative.inMilliseconds
        .clamp(0, controller.value.duration.inMilliseconds)
        .toInt();
    final currentMs = controller.value.position.inMilliseconds;
    if (forceSeek || (currentMs - targetMs).abs() > 200) {
      await controller.seekTo(Duration(milliseconds: targetMs));
    }
    final volume = _previewAudioVolume(
      clip: widget.clip,
      position: widget.playbackPosition,
      isTrackAudible: widget.isTrackAudible,
      duckingGain: widget.duckingGain,
    );
    if (_lastVolume == null || (_lastVolume! - volume).abs() > 0.01) {
      await controller.setVolume(volume);
      _lastVolume = volume;
    }
    if (!widget.clip.isReversed && !widget.clip.freezeFrame) {
      final speed = (widget.playbackSpeed * widget.clip.playbackRate)
          .clamp(0.25, 4)
          .toDouble();
      if (_lastPlaybackSpeed == null ||
          (_lastPlaybackSpeed! - speed).abs() > 0.001) {
        await controller.setPlaybackSpeed(speed);
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
  }

  Future<void> _replaceController() async {
    await _disposeController();
    if (mounted) await _initialize();
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    _ready = false;
    _lastVolume = null;
    _lastPlaybackSpeed = null;
    if (controller != null) {
      await controller.dispose();
    }
  }

  @override
  void dispose() {
    _disposeController();
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
  final double duckingGain;
  final bool isTrackAudible;
  final bool continueFreezeFrameAudio;

  const _TimelineAudioPreview({
    super.key,
    required this.audioPath,
    required this.clip,
    required this.playbackPosition,
    required this.isPlaying,
    required this.playbackSpeed,
    required this.duckingGain,
    required this.isTrackAudible,
    this.continueFreezeFrameAudio = false,
  });

  @override
  State<_TimelineAudioPreview> createState() => _TimelineAudioPreviewState();
}

class _TimelineAudioPreviewState extends State<_TimelineAudioPreview> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _syncInFlight = false;
  bool _syncQueued = false;
  bool _forceSeekQueued = false;
  double? _lastVolume;
  double? _lastPlaybackSpeed;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant _TimelineAudioPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioPath != widget.audioPath) {
      unawaited(_replaceController());
    } else {
      _schedulePlaybackSync();
    }
  }

  Future<void> _initialize() async {
    VideoPlayerController? createdController;
    try {
      final controller = VideoPlayerController.file(File(widget.audioPath));
      createdController = controller;
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _ready = true;
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
      _ready = false;
    }
  }

  Future<void> _replaceController() async {
    final previous = _controller;
    _controller = null;
    _ready = false;
    _lastVolume = null;
    _lastPlaybackSpeed = null;
    if (previous != null) await previous.dispose();
    await _initialize();
  }

  void _schedulePlaybackSync({bool forceSeek = false}) {
    if (_syncInFlight) {
      _syncQueued = true;
      _forceSeekQueued = _forceSeekQueued || forceSeek;
      return;
    }
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
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return;
    }
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
    if (forceSeek ||
        (controller.value.position - target).inMilliseconds.abs() > 180) {
      await controller.seekTo(target);
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
        _lastPlaybackSpeed = speed;
      }
    }

    final safeVolume = _previewAudioVolume(
      clip: widget.clip,
      position: widget.playbackPosition,
      isTrackAudible: widget.isTrackAudible,
      duckingGain: widget.duckingGain,
    );
    if (_lastVolume == null || (_lastVolume! - safeVolume).abs() > 0.01) {
      await controller.setVolume(safeVolume);
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
  }

  @override
  void dispose() {
    _controller?.dispose();
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

class _OverlayTransformBox extends StatelessWidget {
  final Widget child;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onMoveStart;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final VoidCallback onWidthResizeStart;
  final ValueChanged<Offset> onWidthResizeUpdate;
  final VoidCallback onWidthResizeEnd;
  final VoidCallback onHeightResizeStart;
  final ValueChanged<Offset> onHeightResizeUpdate;
  final VoidCallback onHeightResizeEnd;

  const _OverlayTransformBox({
    required this.child,
    required this.isSelected,
    required this.onTap,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onWidthResizeStart,
    required this.onWidthResizeUpdate,
    required this.onWidthResizeEnd,
    required this.onHeightResizeStart,
    required this.onHeightResizeUpdate,
    required this.onHeightResizeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTap,
      onPanStart: (_) => onMoveStart(),
      onPanUpdate: (details) => onMoveUpdate(details.delta),
      onPanEnd: (_) => onMoveEnd(),
      onPanCancel: onMoveEnd,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(
                color: isSelected
                    ? kAccent.withValues(alpha: 0.8)
                    : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: child,
          ),
          if (isSelected)
            Positioned(
              right: -10,
              top: 0,
              bottom: 0,
              child: Center(
                child: _TransformHandle(
                  icon: Icons.open_in_full_rounded,
                  onPanStart: onWidthResizeStart,
                  onPanUpdate: onWidthResizeUpdate,
                  onPanEnd: onWidthResizeEnd,
                ),
              ),
            ),
          if (isSelected)
            Positioned(
              bottom: -10,
              left: 0,
              right: 0,
              child: Center(
                child: _TransformHandle(
                  icon: Icons.height_rounded,
                  onPanStart: onHeightResizeStart,
                  onPanUpdate: onHeightResizeUpdate,
                  onPanEnd: onHeightResizeEnd,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TransformHandle extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPanStart;
  final ValueChanged<Offset> onPanUpdate;
  final VoidCallback onPanEnd;

  const _TransformHandle({
    required this.icon,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => onPanStart(),
      onPanUpdate: (details) => onPanUpdate(details.delta),
      onPanEnd: (_) => onPanEnd(),
      onPanCancel: onPanEnd,
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: kAccent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white, width: 1),
        ),
        child: Icon(icon, size: 12, color: Colors.white),
      ),
    );
  }
}
