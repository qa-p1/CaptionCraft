import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/video_scope_service.dart';
import '../models/timeline_models.dart';
import '../providers/playback_provider.dart';

class VideoScopesPanel extends ConsumerStatefulWidget {
  final TimelineClip clip;
  final String sourcePath;

  const VideoScopesPanel({
    super.key,
    required this.clip,
    required this.sourcePath,
  });

  @override
  ConsumerState<VideoScopesPanel> createState() => _VideoScopesPanelState();
}

class _VideoScopesPanelState extends ConsumerState<VideoScopesPanel> {
  EditorVideoScopeType _type = EditorVideoScopeType.waveform;
  Timer? _throttleTimer;
  DateTime? _lastRenderStarted;
  bool _rendering = false;
  bool _pending = false;
  String? _imagePath;
  String? _error;
  Duration _playbackPosition = Duration.zero;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    final playback = ref.read(playbackProvider);
    _playbackPosition = playback.position;
    _isPlaying = playback.isPlaying;
    _scheduleRender(immediate: true);
  }

  @override
  void didUpdateWidget(covariant VideoScopesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sourcePath != oldWidget.sourcePath ||
        widget.clip.id != oldWidget.clip.id ||
        widget.clip.colorAdjustments.toJson().toString() !=
            oldWidget.clip.colorAdjustments.toJson().toString()) {
      _scheduleRender();
    }
  }

  void _scheduleRender({bool immediate = false}) {
    if (_rendering) {
      _pending = true;
      return;
    }
    _throttleTimer?.cancel();
    final elapsed = _lastRenderStarted == null
        ? const Duration(days: 1)
        : DateTime.now().difference(_lastRenderStarted!);
    const interval = Duration(milliseconds: 360);
    if (immediate || elapsed >= interval) {
      unawaited(_render());
      return;
    }
    _throttleTimer = Timer(interval - elapsed, () => unawaited(_render()));
  }

  Future<void> _render() async {
    if (_rendering || !mounted) return;
    _rendering = true;
    _pending = false;
    _lastRenderStarted = DateTime.now();
    if (mounted) setState(() => _error = null);
    try {
      final rendered = await VideoScopeService.render(
        sourcePath: widget.sourcePath,
        sourcePosition: _sourcePosition(widget.clip, _playbackPosition),
        adjustments: widget.clip.colorAdjustments,
        type: _type,
      );
      if (!mounted) return;
      setState(() => _imagePath = rendered);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      _rendering = false;
      if (_pending && mounted) _scheduleRender();
    }
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PlaybackState>(playbackProvider, (previous, next) {
      final moved =
          (next.position - _playbackPosition).inMilliseconds.abs() >= 100;
      _playbackPosition = next.position;
      _isPlaying = next.isPlaying;
      if (moved) _scheduleRender();
    });
    final imagePath = _imagePath;
    return Container(
      key: const ValueKey('video_scopes_panel'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final type in EditorVideoScopeType.values)
                ChoiceChip(
                  key: ValueKey('video_scope_${type.name}'),
                  label: Text(type.label),
                  selected: _type == type,
                  onSelected: (_) {
                    setState(() => _type = type);
                    _scheduleRender(immediate: true);
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
          AspectRatio(
            aspectRatio: _type == EditorVideoScopeType.vectorscope ? 1 : 2.45,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (imagePath != null && File(imagePath).existsSync())
                      Image.file(
                        File(imagePath),
                        key: ValueKey(imagePath),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      )
                    else
                      const Center(
                        child: Icon(
                          Icons.monitor_heart_outlined,
                          color: kTextSecondary,
                          size: 36,
                        ),
                      ),
                    if (_rendering)
                      const Positioned(
                        right: 9,
                        top: 9,
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            _error ??
                (_isPlaying
                    ? 'Updating from the selected clip during playback.'
                    : 'Showing the selected clip at the playhead.'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _error == null ? kTextSecondary : kError,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }
}

Duration _sourcePosition(TimelineClip clip, Duration timelinePosition) {
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
