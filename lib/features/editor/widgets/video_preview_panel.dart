import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../../../core/theme/app_theme.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../providers/playback_provider.dart';
import '../providers/subtitle_provider.dart';
import '../widgets/animated_subtitle_overlay.dart';

/// Video preview panel with subtitle overlay and playback controls.
class VideoPreviewPanel extends ConsumerStatefulWidget {
  final String videoPath;
  final double? targetAspectRatio;

  const VideoPreviewPanel({
    super.key,
    required this.videoPath,
    this.targetAspectRatio,
  });

  @override
  ConsumerState<VideoPreviewPanel> createState() => _VideoPreviewPanelState();
}

class _VideoPreviewPanelState extends ConsumerState<VideoPreviewPanel> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _playbackSyncQueued = false;
  double _playbackSpeed = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initializeVideo();
    });
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    await _controller.initialize();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final playbackNotifier = ref.read(playbackProvider.notifier);
      playbackNotifier.updateDuration(_controller.value.duration);
      playbackNotifier.setReady(true);
    });

    _controller.addListener(_onPlaybackUpdate);
    setState(() => _initialized = true);
  }

  void _onPlaybackUpdate() {
    if (!mounted) return;
    if (_playbackSyncQueued) return;
    _playbackSyncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _playbackSyncQueued = false;
      if (!mounted) return;
      final playback = ref.read(playbackProvider.notifier);
      playback.updatePosition(_controller.value.position);
      playback.setPlaying(_controller.value.isPlaying);
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onPlaybackUpdate);
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
  }

  void _seekTo(Duration position) {
    if (!_initialized) return;
    ref.read(playbackProvider.notifier).requestSeek(position);
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    if (!_initialized) return;
    await _controller.setPlaybackSpeed(speed);
    if (!mounted) return;
    setState(() => _playbackSpeed = speed);
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

      final clampedMs = target.inMilliseconds
          .clamp(0, _controller.value.duration.inMilliseconds)
          .toInt();
      _controller.seekTo(Duration(milliseconds: clampedMs));
      ref.read(playbackProvider.notifier).acknowledgeSeek(requestId);
    });

    final playbackState = ref.watch(playbackProvider);
    final subtitleState = ref.watch(subtitleProvider);

    SubtitleEntry? activeSubtitle;
    for (final entry in subtitleState.entries) {
      if (playbackState.position >= entry.startTime &&
          playbackState.position <= entry.endTime) {
        activeSubtitle = entry;
        break;
      }
    }

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
                          aspectRatio:
                              widget.targetAspectRatio ??
                              _controller.value.aspectRatio,
                          child: Container(
                            color: Colors.black,
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: _controller.value.aspectRatio,
                                child: VideoPlayer(_controller),
                              ),
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
                      if (activeSubtitle != null)
                        Positioned.fill(
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

                              final maxX = (constraints.maxWidth / 2 - 24)
                                  .clamp(0.0, 99999.0);
                              final maxY = (constraints.maxHeight / 2 - 24)
                                  .clamp(0.0, 99999.0);
                              final effectiveOffsetY =
                                  editableStyle.verticalOffset +
                                  editableStyle.offsetY;

                              return Align(
                                alignment: _alignmentForPosition(
                                  editableStyle.position,
                                ),
                                child: Transform.translate(
                                  offset: Offset(
                                    editableStyle.offsetX.clamp(-maxX, maxX),
                                    effectiveOffsetY.clamp(-maxY, maxY),
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
                                          (style.offsetX + delta.dx)
                                              .clamp(-maxX, maxX)
                                              .toDouble();
                                      final nextOffsetY =
                                          (style.offsetY + delta.dy)
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
                                          (style.maxWidthFactor + widthDelta)
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
                                          (style.fontSize + delta.dy * 0.25)
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
                                      globalStyle: subtitleState.globalStyle,
                                      currentPosition: playbackState.position,
                                    ),
                                  ),
                                ),
                              );
                            },
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: kSurface,
            child: Column(
              children: [
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: kAccent,
                    inactiveTrackColor: kBorder,
                    thumbColor: kAccent,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                  ),
                  child: Slider(
                    value: playbackState.progressPercent.clamp(0, 1).toDouble(),
                    onChanged: (value) {
                      final pos = Duration(
                        milliseconds:
                            (value * playbackState.duration.inMilliseconds)
                                .round(),
                      );
                      _seekTo(pos);
                    },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.replay_10_rounded,
                        color: kTextPrimary,
                        size: 22,
                      ),
                      onPressed: () => _seekTo(
                        playbackState.position - const Duration(seconds: 10),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        playbackState.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: kTextPrimary,
                        size: 32,
                      ),
                      onPressed: _togglePlayPause,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(
                        Icons.forward_10_rounded,
                        color: kTextPrimary,
                        size: 22,
                      ),
                      onPressed: () => _seekTo(
                        playbackState.position + const Duration(seconds: 10),
                      ),
                    ),
                    const SizedBox(width: 4),
                    PopupMenuButton<double>(
                      tooltip: 'Playback speed',
                      color: kSurfaceElevated,
                      onSelected: _setPlaybackSpeed,
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 0.5, child: Text('0.5x')),
                        PopupMenuItem(value: 0.75, child: Text('0.75x')),
                        PopupMenuItem(value: 1.0, child: Text('1.0x')),
                        PopupMenuItem(value: 1.25, child: Text('1.25x')),
                        PopupMenuItem(value: 1.5, child: Text('1.5x')),
                        PopupMenuItem(value: 2.0, child: Text('2.0x')),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: kSurfaceElevated,
                          borderRadius: BorderRadius.circular(8),
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
                    const Spacer(),
                    Text(
                      '${SubtitleEntry.formatDisplayTime(playbackState.position)} / '
                      '${SubtitleEntry.formatDisplayTime(playbackState.duration)}',
                      style: const TextStyle(
                        fontFamily: 'SpaceMono',
                        color: kTextSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
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
