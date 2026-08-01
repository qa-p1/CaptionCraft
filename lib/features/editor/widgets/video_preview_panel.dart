import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
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
}) {
  final mix = clip.audioMix;
  if (!isTrackAudible || mix.muted) return 0;

  // Loudness normalization needs analysis of the complete source and remains
  // an export-time operation. Preview only the deterministic mix envelope.
  var volume = mix.volume.clamp(0.0, 1.0).toDouble();

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

class _VideoPreviewPanelState extends ConsumerState<VideoPreviewPanel> {
  VideoPlayerController? _controller;
  TimelineClip? _controllerClip;
  TimelineTrack? _controllerTrack;
  String? _controllerPath;
  bool _initialized = false;
  bool _isSwitchingClip = false;
  bool _isAdvancingClip = false;
  bool _playRequested = false;
  bool _loopPlayback = false;
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

  Duration _timelineDuration() {
    final timeline = ref.read(editorProvider).timeline;
    return timeline.tracks
        .expand((track) => track.clips)
        .fold<Duration>(
          Duration.zero,
          (current, clip) => clip.endTime > current ? clip.endTime : current,
        );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initializeVideo();
    });
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
    _syncPlaybackState();
    if (_playRequested &&
        (_gapPlaybackStartedAt != null ||
            _controllerClip?.isReversed == true)) {
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
        controller == null ||
        clip == null ||
        !controller.value.isInitialized ||
        _gapPlaybackStartedAt != null ||
        clip.isReversed) {
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

    if (_playRequested &&
        (clampedPosition >= clip.endTime - const Duration(milliseconds: 34) ||
            controllerValue.isCompleted)) {
      unawaited(_advanceFromClip(clip));
    }
  }

  void _startPlaybackTicker() {
    if (_playbackTicker?.isActive == true) return;
    _playbackTicker = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!_initialized || !mounted) return;
      final reverseStarted = _reversePlaybackStartedAt;
      final reverseClip = _controllerClip;
      if (_playRequested &&
          reverseStarted != null &&
          reverseClip != null &&
          reverseClip.isReversed) {
        final elapsed = DateTime.now().difference(reverseStarted);
        final advanced = Duration(
          microseconds: (elapsed.inMicroseconds * _playbackSpeed).round(),
        );
        final target = _reversePlaybackStartPosition + advanced;
        if (target >= reverseClip.endTime) {
          unawaited(_advanceFromClip(reverseClip));
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
        final duration = _timelineDuration();
        if (target >= duration) {
          _playRequested = false;
          _gapPlaybackStartedAt = null;
          ref.read(playbackProvider.notifier)
            ..updatePosition(duration)
            ..setPlaying(false);
          _stopPlaybackTicker();
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
      if (!clip.isReversed) {
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
    final asset = timeline.assetForClip(clip);
    final sourcePath = asset?.sourcePath;
    if (sourcePath != null &&
        sourcePath.isNotEmpty &&
        File(sourcePath).existsSync()) {
      return sourcePath;
    }
    if (File(widget.videoPath).existsSync()) return widget.videoPath;
    return null;
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
    final targetMs = requested.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toInt();
    final target = Duration(milliseconds: targetMs);
    final shouldPlay = autoplay ?? _playRequested;
    _playRequested = shouldPlay;
    final selection = _baseSelectionAt(timeline, target);
    final playbackNotifier = ref.read(playbackProvider.notifier);

    if (selection == null) {
      _reversePlaybackStartedAt = null;
      _gapPlaybackStartPosition = target;
      _gapPlaybackStartedAt = shouldPlay ? DateTime.now() : null;
      final controller = _controller;
      if (controller?.value.isPlaying == true) {
        await controller!.pause();
      }
      _controllerClip = null;
      _controllerTrack = null;
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(target)
        ..setPlaying(shouldPlay)
        ..setReady(true);
      if (mounted) setState(() {});
      if (shouldPlay) _startPlaybackTicker();
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
      if (!clip.isReversed) {
        await currentController.setPlaybackSpeed(
          (_playbackSpeed * clip.playbackRate).clamp(0.25, 4),
        );
      }
      await _applyBaseAudioVolume(target);
      if (clip.isReversed) {
        if (currentController.value.isPlaying) {
          await currentController.pause();
        }
        _reversePlaybackStartPosition = target;
        _reversePlaybackStartedAt = shouldPlay ? DateTime.now() : null;
      } else if (shouldPlay && !currentController.value.isPlaying) {
        _reversePlaybackStartedAt = null;
        await currentController.play();
      } else if (!shouldPlay && currentController.value.isPlaying) {
        _reversePlaybackStartedAt = null;
        await currentController.pause();
      } else {
        _reversePlaybackStartedAt = null;
      }
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(target)
        ..setPlaying(shouldPlay);
      if (shouldPlay) _startPlaybackTicker();
      return;
    }

    _isSwitchingClip = true;
    try {
      _previewError = null;
      if (currentController != null) {
        currentController.removeListener(_onPlaybackUpdate);
        await currentController.pause();
        await currentController.dispose();
      }
      final nextController = VideoPlayerController.file(File(sourcePath));
      await nextController.initialize();
      await nextController.seekTo(sourceTarget);
      if (!clip.isReversed) {
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
      if (clip.isReversed) {
        _reversePlaybackStartPosition = target;
        _reversePlaybackStartedAt = shouldPlay ? DateTime.now() : null;
      } else {
        _reversePlaybackStartedAt = null;
        if (shouldPlay) await nextController.play();
      }
      playbackNotifier
        ..updateDuration(duration)
        ..updatePosition(target)
        ..setPlaying(shouldPlay)
        ..setReady(true);
      setState(() {});
      if (shouldPlay) _startPlaybackTicker();
    } catch (_) {
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
      if (nextPosition >= timeline.duration) {
        if (_loopPlayback) {
          await _seekTimelinePosition(
            Duration.zero,
            autoplay: true,
            forceSeek: true,
          );
          return;
        }
        _playRequested = false;
        await _controller?.pause();
        ref.read(playbackProvider.notifier)
          ..updatePosition(timeline.duration)
          ..setPlaying(false);
        _stopPlaybackTicker();
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
    final hasSolo = timeline.tracks.any((candidate) => candidate.isSolo);
    final volume = _previewAudioVolume(
      clip: clip,
      position: position,
      isTrackAudible: !track.isMuted && (!hasSolo || track.isSolo),
    );
    await controller.setVolume(volume);
  }

  Duration _sourceTargetForClip(TimelineClip clip, Duration timelinePosition) {
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

  void _beginStyleGesture(SubtitleEntry activeEntry) {
    final notifier = ref.read(subtitleProvider.notifier);
    notifier.selectEntry(activeEntry.id);
    notifier.beginStyleGestureEdit();
  }

  void _endStyleGesture() {
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
      return a.clip.layer.compareTo(b.clip.layer);
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
      return a.clip.layer.compareTo(b.clip.layer);
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

  Widget _buildOverlayAsset(
    _OverlayCanvasItem item,
    BoxConstraints constraints,
    PlaybackState playbackState,
    List<_EffectCanvasItem> activeFilterEffects,
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
    Widget child = switch (item.asset.type) {
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
                isTrackAudible:
                    !item.track.isMuted &&
                    (!ref
                            .read(editorProvider)
                            .timeline
                            .tracks
                            .any((track) => track.isSolo) ||
                        item.track.isSolo),
                width: baseWidth,
                height: previewHeight,
                fitMode: item.clip.fitMode,
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
    child = SizedBox(width: baseWidth, height: previewHeight, child: child);
    child = _applyNormalizedCropPreview(child, item.clip.crop);
    if (!item.clip.colorAdjustments.isNeutral) {
      child = ColorFiltered(
        colorFilter: ColorFilter.matrix(
          _colorMatrixForAdjustments(item.clip.colorAdjustments),
        ),
        child: child,
      );
    }
    child = _applyBlurPreview(child, item.clip.blur);
    child = _applyEffectFilters(child, activeFilterEffects);
    child = Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(
        item.clip.transform.flipX ? -1 : 1,
        item.clip.transform.flipY ? -1 : 1,
        1,
      ),
      child: child,
    );

    return Transform.translate(
      offset: animation.offset,
      child: Opacity(
        opacity: (animation.opacity * item.clip.transform.opacity).clamp(
          0.0,
          1.0,
        ),
        child: Transform.rotate(
          angle: item.clip.transform.rotation,
          child: Transform.scale(
            scale: (animation.scale * item.clip.transform.scale).clamp(
              0.2,
              4.0,
            ),
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

      // Export applies a complete alpha ramp to every non-cut transition.
      opacity *= (1 - hiddenAmount).clamp(0.0, 1.0);
      switch (transition.type) {
        case TransitionType.fade:
        case TransitionType.dissolve:
        case TransitionType.zoom:
          // Zoom currently exports as an alpha transition only.
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
    required List<_EffectCanvasItem> activeFilterEffects,
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
    final transform = clip.transform;
    final crop = clip.crop;

    Widget source = SizedBox(
      width: sourceWidth,
      height: sourceHeight,
      child: VideoPlayer(controller),
    );
    if (!crop.isIdentity) {
      source = SizedBox(
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
              child: source,
            ),
          ),
        ),
      );
    }

    Widget child = SizedBox.expand(
      child: FittedBox(fit: fit, clipBehavior: Clip.hardEdge, child: source),
    );
    if (!clip.colorAdjustments.isNeutral) {
      child = ColorFiltered(
        colorFilter: ColorFilter.matrix(
          _colorMatrixForAdjustments(clip.colorAdjustments),
        ),
        child: child,
      );
    }
    child = _applyBlurPreview(child, clip.blur);
    child = _applyEffectFilters(child, activeFilterEffects);
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

  Widget _applyEffectFilters(
    Widget child,
    List<_EffectCanvasItem> activeFilterEffects,
  ) {
    var filtered = child;
    for (final effect in activeFilterEffects) {
      final adjustments = effect.clip.colorAdjustments;
      filtered = ColorFiltered(
        colorFilter: ColorFilter.matrix(
          _colorMatrixForAdjustments(adjustments),
        ),
        child: filtered,
      );
    }
    return filtered;
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
                final vignette = clip.colorAdjustments.vignette.clamp(0.0, 1.0);
                if (vignette <= 0.001) return const SizedBox.shrink();
                return IgnorePointer(
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
                );
              }

              final blur = clip.blur;
              if (clip.effectKind != TimelineEffectKind.blur ||
                  !blur.isEnabled) {
                return const SizedBox.shrink();
              }
              final imageFilter = ui.ImageFilter.blur(
                sigmaX: blur.safeStrength,
                sigmaY: blur.safeStrength,
                tileMode: TileMode.decal,
              );
              if (blur.mode == ClipBlurMode.full) {
                return IgnorePointer(
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: imageFilter,
                      child: const ColoredBox(color: Colors.transparent),
                    ),
                  ),
                );
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
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: imageFilter,
                      child: ColoredBox(
                        color: isSelected
                            ? kAccent.withValues(alpha: 0.035)
                            : Colors.transparent,
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
    final saturation = adjustments.saturation.clamp(0.0, 3.0);
    final contrast = (adjustments.contrast * (1 - adjustments.fade * 0.22))
        .clamp(0.1, 3.0);
    final brightness = (adjustments.brightness + adjustments.fade * 0.05).clamp(
      -1.0,
      1.0,
    );
    final warmth = adjustments.temperature.clamp(-1.0, 1.0);
    const redLuma = 0.2126;
    const greenLuma = 0.7152;
    const blueLuma = 0.0722;
    final inverseSaturation = 1 - saturation;
    final offset = 128 * (1 - contrast) + brightness * 255;
    final redWarmth = 1 + warmth * 0.16;
    final blueWarmth = 1 - warmth * 0.16;

    return [
      (redLuma * inverseSaturation + saturation) * contrast * redWarmth,
      greenLuma * inverseSaturation * contrast,
      blueLuma * inverseSaturation * contrast,
      0,
      offset,
      redLuma * inverseSaturation * contrast,
      (greenLuma * inverseSaturation + saturation) * contrast,
      blueLuma * inverseSaturation * contrast,
      0,
      offset,
      redLuma * inverseSaturation * contrast,
      greenLuma * inverseSaturation * contrast,
      (blueLuma * inverseSaturation + saturation) * contrast * blueWarmth,
      0,
      offset,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  Widget _applyBlurPreview(Widget child, ClipBlurSettings blur) {
    if (!blur.isEnabled) return child;
    final filter = ui.ImageFilter.blur(
      sigmaX: blur.safeStrength,
      sigmaY: blur.safeStrength,
      tileMode: TileMode.decal,
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
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned(
              left: constraints.maxWidth * blur.safeRegionX,
              top: constraints.maxHeight * blur.safeRegionY,
              width: constraints.maxWidth * blur.safeRegionWidth,
              height: constraints.maxHeight * blur.safeRegionHeight,
              child: ClipRect(
                child: BackdropFilter(
                  filter: filter,
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
            ),
          ],
        );
      },
    );
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
    final activeOverlayItems = _activeOverlayItems(
      editorState.timeline,
      playbackState.position,
    );
    final activeEffectItems = _activeEffectItems(
      editorState.timeline,
      playbackState.position,
    );
    final activeFilterEffects = activeEffectItems
        .where((item) => item.clip.effectKind == TimelineEffectKind.filter)
        .toList(growable: false);
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
                              child: Container(
                                color: editorState
                                    .timeline
                                    .canvasSettings
                                    .backgroundColor,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    LayoutBuilder(
                                      builder: (context, constraints) {
                                        if (!controllerReady) {
                                          return const SizedBox.expand();
                                        }
                                        return _buildBaseVideoLayer(
                                          controller: controller,
                                          clip: activeBaseClip,
                                          constraints: constraints,
                                          playbackPosition:
                                              playbackState.position,
                                          activeFilterEffects:
                                              activeFilterEffects,
                                        );
                                      },
                                    ),
                                    if (_previewError != null)
                                      Center(
                                        child: Container(
                                          margin: const EdgeInsets.all(20),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 11,
                                          ),
                                          decoration: BoxDecoration(
                                            color: kBackground.withValues(
                                              alpha: 0.78,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            border: Border.all(
                                              color: kWarning.withValues(
                                                alpha: 0.45,
                                              ),
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
                                      final transform = item.clip.transform;
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
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .beginTimelineGestureEdit();
                                            },
                                            onMoveUpdate: (delta) {
                                              _updateOverlayTransform(
                                                item.clip.id,
                                                (current) => current.copyWith(
                                                  offsetX:
                                                      (current.offsetX +
                                                              delta.dx *
                                                                  kTimelineDesignWidth /
                                                                  constraints
                                                                      .maxWidth)
                                                          .clamp(-maxX, maxX)
                                                          .toDouble(),
                                                  offsetY:
                                                      (current.offsetY +
                                                              delta.dy *
                                                                  kTimelineDesignHeight /
                                                                  constraints
                                                                      .maxHeight)
                                                          .clamp(-maxY, maxY)
                                                          .toDouble(),
                                                ),
                                              );
                                            },
                                            onMoveEnd: () => ref
                                                .read(editorProvider.notifier)
                                                .endTimelineGestureEdit(),
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
                                            child: _buildOverlayAsset(
                                              item,
                                              constraints,
                                              playbackState,
                                              activeFilterEffects,
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
                                      final transform = item.clip.transform;
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
                                            item.clip.transform.offsetX.clamp(
                                                  -maxX,
                                                  maxX,
                                                ) *
                                                constraints.maxWidth /
                                                kTimelineDesignWidth,
                                            item.clip.transform.offsetY.clamp(
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
                                              ref
                                                  .read(editorProvider.notifier)
                                                  .beginTimelineGestureEdit();
                                            },
                                            onMoveUpdate: (delta) {
                                              _updateOverlayTransform(
                                                item.clip.id,
                                                (current) => current.copyWith(
                                                  offsetX:
                                                      (current.offsetX +
                                                              delta.dx *
                                                                  kTimelineDesignWidth /
                                                                  constraints
                                                                      .maxWidth)
                                                          .clamp(-maxX, maxX)
                                                          .toDouble(),
                                                  offsetY:
                                                      (current.offsetY +
                                                              delta.dy *
                                                                  kTimelineDesignHeight /
                                                                  constraints
                                                                      .maxHeight)
                                                          .clamp(-maxY, maxY)
                                                          .toDouble(),
                                                ),
                                              );
                                            },
                                            onMoveEnd: () => ref
                                                .read(editorProvider.notifier)
                                                .endTimelineGestureEdit(),
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
                                  // Keep transform edits global so move/resize
                                  // applies consistently to all subtitle blocks.
                                  const editPerEntry = false;
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
                                        onMoveStart: () =>
                                            _beginStyleGesture(activeEntry),
                                        onMoveUpdate: (delta) {
                                          final style = _readEditableStyleFor(
                                            activeEntry,
                                            editPerEntry,
                                          );
                                          final nextOffsetX =
                                              (style.offsetX +
                                                      delta.dx *
                                                          kTimelineDesignWidth /
                                                          constraints.maxWidth)
                                                  .clamp(-maxX, maxX)
                                                  .toDouble();
                                          final nextOffsetY =
                                              (style.offsetY +
                                                      delta.dy *
                                                          kTimelineDesignHeight /
                                                          constraints.maxHeight)
                                                  .clamp(-maxY, maxY)
                                                  .toDouble();

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
                                            _beginStyleGesture(activeEntry),
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
                                            _beginStyleGesture(activeEntry),
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
                                isTrackAudible:
                                    !item.track.isMuted &&
                                    (!editorState.timeline.tracks.any(
                                          (track) => track.isSolo,
                                        ) ||
                                        item.track.isSolo),
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
                                        tooltip: _loopPlayback
                                            ? 'Turn looping off'
                                            : 'Loop timeline',
                                        icon: Icon(
                                          Icons.repeat_rounded,
                                          color: _loopPlayback
                                              ? kAccent
                                              : kTextSecondary,
                                          size: 20,
                                        ),
                                        onPressed: () {
                                          setState(
                                            () =>
                                                _loopPlayback = !_loopPlayback,
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

class _OverlayVideoPreview extends StatefulWidget {
  final String videoPath;
  final TimelineClip clip;
  final Duration playbackPosition;
  final bool isPlaying;
  final double playbackSpeed;
  final bool isTrackAudible;
  final double width;
  final double height;
  final ClipFitMode fitMode;

  const _OverlayVideoPreview({
    super.key,
    required this.videoPath,
    required this.clip,
    required this.playbackPosition,
    required this.isPlaying,
    required this.playbackSpeed,
    required this.isTrackAudible,
    required this.width,
    required this.height,
    required this.fitMode,
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
    try {
      final controller = VideoPlayerController.file(File(widget.videoPath));
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
    );
    if (_lastVolume == null || (_lastVolume! - volume).abs() > 0.01) {
      await controller.setVolume(volume);
      _lastVolume = volume;
    }
    if (!widget.clip.isReversed) {
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
    if (widget.clip.isReversed) {
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: FittedBox(
          fit: fit,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: sourceWidth,
            height: sourceHeight,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }
}

class _TimelineAudioPreview extends StatefulWidget {
  final String audioPath;
  final TimelineClip clip;
  final Duration playbackPosition;
  final bool isPlaying;
  final double playbackSpeed;
  final bool isTrackAudible;

  const _TimelineAudioPreview({
    super.key,
    required this.audioPath,
    required this.clip,
    required this.playbackPosition,
    required this.isPlaying,
    required this.playbackSpeed,
    required this.isTrackAudible,
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
    try {
      final controller = VideoPlayerController.file(File(widget.audioPath));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _ready = true;
      _schedulePlaybackSync(forceSeek: true);
    } catch (_) {
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
    final sourcePosition = _previewSourcePosition(
      widget.clip,
      widget.playbackPosition,
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
    if (!widget.clip.isReversed) {
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
    );
    if (_lastVolume == null || (_lastVolume! - safeVolume).abs() > 0.01) {
      await controller.setVolume(safeVolume);
      _lastVolume = safeVolume;
    }
    if (widget.clip.isReversed) {
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

Duration _previewSourcePosition(TimelineClip clip, Duration timelinePosition) {
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
