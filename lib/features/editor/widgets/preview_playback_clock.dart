import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Advances a recently published playback position between provider updates.
///
/// The editor intentionally publishes its global playback state less often
/// than the display refresh rate to avoid rebuilding the timeline and every
/// control on each frame. The preview can use this small local clock for
/// Flutter-rendered motion while the media controller remains the source of
/// truth at the next published update.
Duration extrapolatePreviewPosition({
  required Duration basePosition,
  required Duration elapsed,
  required Duration duration,
  required double playbackSpeed,
  required bool isPlaying,
}) {
  final durationUs = math.max(0, duration.inMicroseconds);
  final baseUs = basePosition.inMicroseconds.clamp(0, durationUs).toInt();
  if (!isPlaying || elapsed <= Duration.zero || durationUs == 0) {
    return Duration(microseconds: baseUs);
  }

  final safeSpeed = playbackSpeed.isFinite && playbackSpeed > 0
      ? playbackSpeed
      : 1.0;
  final advancedUs = (elapsed.inMicroseconds * safeSpeed).round();
  return Duration(
    microseconds: (baseUs + advancedUs).clamp(0, durationUs).toInt(),
  );
}

/// Returns whether a media decoder has drifted far enough from the editor's
/// monotonic timeline clock to justify an explicit seek.
///
/// Decoders are intentionally followers. In particular, a busy overlay video
/// must never be allowed to stop the shared playhead merely because its
/// platform position callback is late. Small differences are left alone so
/// audio and video can play continuously without seek churn.
bool shouldCorrectPreviewMediaDrift({
  required Duration timelineTarget,
  required Duration decoderPosition,
  Duration tolerance = const Duration(milliseconds: 320),
}) {
  final safeTolerance = tolerance < Duration.zero ? Duration.zero : tolerance;
  return (timelineTarget - decoderPosition).abs() > safeTolerance;
}

/// The result of comparing a platform decoder with the editor's monotonic
/// composition clock.
enum PreviewMediaSyncDecision { none, seek }

/// Decides whether a preview decoder should be hard-seeked back to the shared
/// composition clock.
///
/// A hard seek is intentionally rare while playing, especially for audible
/// media. Platform seeks flush decoder/audio buffers; issuing one every time a
/// busy decoder reports a late position produces the stutter and pitch-like
/// artifacts users hear in complex projects. Paused scrubbing remains precise,
/// while playing media gets a wider tolerance and a correction cooldown.
PreviewMediaSyncDecision decidePreviewMediaSync({
  required Duration timelineTarget,
  required Duration decoderPosition,
  required bool isPlaying,
  required bool isAudible,
  Duration? timeSinceLastCorrection,
  bool forceSeek = false,
  bool isBuffering = false,
  Duration pausedTolerance = const Duration(milliseconds: 12),
  Duration silentPlaybackTolerance = const Duration(milliseconds: 320),
  Duration audiblePlaybackTolerance = const Duration(milliseconds: 850),
  Duration silentCorrectionCooldown = const Duration(milliseconds: 550),
  Duration audibleCorrectionCooldown = const Duration(milliseconds: 1200),
  Duration emergencyDrift = const Duration(milliseconds: 2400),
}) {
  if (forceSeek) return PreviewMediaSyncDecision.seek;
  if (isPlaying && isBuffering) return PreviewMediaSyncDecision.none;

  final drift = (timelineTarget - decoderPosition).abs();
  final tolerance = !isPlaying
      ? pausedTolerance
      : isAudible
      ? audiblePlaybackTolerance
      : silentPlaybackTolerance;
  if (drift <= tolerance) return PreviewMediaSyncDecision.none;

  // Very large drift is allowed to recover immediately. This also ensures a
  // controller that has stopped advancing can never remain stale forever.
  if (drift >= emergencyDrift) return PreviewMediaSyncDecision.seek;
  if (!isPlaying) return PreviewMediaSyncDecision.seek;

  final cooldown = isAudible
      ? audibleCorrectionCooldown
      : silentCorrectionCooldown;
  if (timeSinceLastCorrection != null && timeSinceLastCorrection < cooldown) {
    return PreviewMediaSyncDecision.none;
  }
  return PreviewMediaSyncDecision.seek;
}

/// Rebuilds only its preview subtree at vsync while time-driven visuals are
/// visible. Static footage bypasses the ticker completely.
class PreviewPlaybackClock extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool enabled;
  final double playbackSpeed;
  final Widget Function(BuildContext context, Duration position) builder;

  const PreviewPlaybackClock({
    super.key,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.enabled,
    required this.playbackSpeed,
    required this.builder,
  });

  @override
  State<PreviewPlaybackClock> createState() => _PreviewPlaybackClockState();
}

class _PreviewPlaybackClockState extends State<PreviewPlaybackClock>
    with SingleTickerProviderStateMixin {
  final Stopwatch _clock = Stopwatch();
  late final Ticker _ticker;
  late Duration _anchorPosition;
  Duration _anchorClock = Duration.zero;

  @override
  void initState() {
    super.initState();
    _clock.start();
    _anchorPosition = widget.position;
    _anchorClock = _clock.elapsed;
    _ticker = createTicker((_) {
      if (mounted) setState(() {});
    });
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant PreviewPlaybackClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position ||
        oldWidget.duration != widget.duration ||
        oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.enabled != widget.enabled ||
        oldWidget.playbackSpeed != widget.playbackSpeed) {
      _anchorPosition = widget.position;
      _anchorClock = _clock.elapsed;
    }
    _syncTicker();
  }

  void _syncTicker() {
    final shouldTick =
        widget.enabled && widget.isPlaying && widget.position < widget.duration;
    if (shouldTick && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final position = extrapolatePreviewPosition(
      basePosition: widget.enabled ? _anchorPosition : widget.position,
      elapsed: widget.enabled ? _clock.elapsed - _anchorClock : Duration.zero,
      duration: widget.duration,
      playbackSpeed: widget.playbackSpeed,
      isPlaying: widget.enabled && widget.isPlaying,
    );
    return widget.builder(context, position);
  }
}
