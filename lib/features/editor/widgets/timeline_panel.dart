import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../models/subtitle_entry.dart';
import '../providers/playback_provider.dart';
import '../providers/subtitle_provider.dart';

/// Horizontally scrollable timeline with draggable/resizable subtitle cue blocks.
class TimelinePanel extends ConsumerStatefulWidget {
  final ValueChanged<SubtitleEntry>? onEditRequested;

  const TimelinePanel({super.key, this.onEditRequested});

  @override
  ConsumerState<TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends ConsumerState<TimelinePanel> {
  final ScrollController _scrollController = ScrollController();
  double _pixelsPerSecond = 50; // Zoom level: pixels per second of video
  static const double _minPixelsPerSecond = 10;
  static const double _maxPixelsPerSecond = 150;
  static const double _trackHeight = 50;
  static const double _rulerHeight = 30;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _seekToTimelineX(double timelineX, Duration totalDuration) {
    if (totalDuration.inMilliseconds <= 0) return;
    final clampedX = timelineX.clamp(0.0, double.infinity).toDouble();
    final targetMs = ((clampedX / _pixelsPerSecond) * 1000)
        .round()
        .clamp(0, totalDuration.inMilliseconds)
        .toInt();
    ref
        .read(playbackProvider.notifier)
        .requestSeek(Duration(milliseconds: targetMs));
  }

  void _zoomToFit(double viewportWidth, Duration totalDuration) {
    if (totalDuration.inMilliseconds <= 0) return;
    final durationSec = totalDuration.inMilliseconds / 1000;
    final fit = ((viewportWidth - 120) / durationSec)
        .clamp(_minPixelsPerSecond, _maxPixelsPerSecond)
        .toDouble();
    setState(() => _pixelsPerSecond = fit);
  }

  void _scrollToPlayhead(Duration position, double viewportWidth) {
    final targetX = position.inMilliseconds / 1000 * _pixelsPerSecond;
    final centered = (targetX - viewportWidth / 2).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      centered,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final playbackState = ref.watch(playbackProvider);
    final subtitleState = ref.watch(subtitleProvider);
    final subtitleNotifier = ref.read(subtitleProvider.notifier);
    final totalDuration = playbackState.duration;
    final viewportWidth = MediaQuery.of(context).size.width;
    final totalWidth =
        totalDuration.inMilliseconds / 1000 * _pixelsPerSecond + 100;

    return Container(
      color: kSurfaceElevated,
      child: Column(
        children: [
          // Toolbar
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: kBorder)),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Add subtitle at playhead',
                  icon: const Icon(
                    Icons.add_box_outlined,
                    color: kTextSecondary,
                    size: 18,
                  ),
                  onPressed: () {
                    final pos = playbackState.position;
                    final totalMs = totalDuration.inMilliseconds;
                    final endMs = (pos.inMilliseconds + 3000)
                        .clamp(0, totalMs == 0 ? 999999999 : totalMs)
                        .toInt();
                    subtitleNotifier.addEntry(
                      pos,
                      Duration(milliseconds: endMs),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Split selected at playhead',
                  icon: const Icon(
                    Icons.call_split_rounded,
                    color: kTextSecondary,
                    size: 18,
                  ),
                  onPressed: () {
                    final selected = subtitleState.selectedEntry;
                    if (selected == null) return;
                    final splitPoint = playbackState.position;
                    if (splitPoint <= selected.startTime ||
                        splitPoint >= selected.endTime) {
                      return;
                    }
                    subtitleNotifier.splitEntry(selected.id, splitPoint);
                  },
                ),
                IconButton(
                  tooltip: 'Center playhead',
                  icon: const Icon(
                    Icons.my_location_rounded,
                    color: kTextSecondary,
                    size: 18,
                  ),
                  onPressed: () =>
                      _scrollToPlayhead(playbackState.position, viewportWidth),
                ),
                IconButton(
                  tooltip: 'Zoom to fit',
                  icon: const Icon(
                    Icons.fit_screen_rounded,
                    color: kTextSecondary,
                    size: 18,
                  ),
                  onPressed: () => _zoomToFit(viewportWidth, totalDuration),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(
                    Icons.remove,
                    color: kTextSecondary,
                    size: 18,
                  ),
                  onPressed: () {
                    setState(() {
                      _pixelsPerSecond = (_pixelsPerSecond - 10)
                          .clamp(_minPixelsPerSecond, _maxPixelsPerSecond)
                          .toDouble();
                    });
                  },
                ),
                Text(
                  '${(_pixelsPerSecond / 50 * 100).round()}%',
                  style: GoogleFonts.spaceMono(
                    color: kTextSecondary,
                    fontSize: 11,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, color: kTextSecondary, size: 18),
                  onPressed: () {
                    setState(() {
                      _pixelsPerSecond = (_pixelsPerSecond + 10)
                          .clamp(_minPixelsPerSecond, _maxPixelsPerSecond)
                          .toDouble();
                    });
                  },
                ),
              ],
            ),
          ),
          // Scrollable timeline
          Expanded(
            child: GestureDetector(
              onScaleUpdate: (details) {
                setState(() {
                  _pixelsPerSecond = (_pixelsPerSecond * details.scale)
                      .clamp(_minPixelsPerSecond, _maxPixelsPerSecond)
                      .toDouble();
                });
              },
              child: SingleChildScrollView(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: totalWidth,
                  child: Stack(
                    children: [
                      // Timeline background tap zone (seek playhead).
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (details) {
                            _seekToTimelineX(
                              details.localPosition.dx,
                              totalDuration,
                            );
                          },
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                      // Time ruler
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: _rulerHeight,
                        child: CustomPaint(
                          painter: _RulerPainter(
                            pixelsPerSecond: _pixelsPerSecond,
                            totalDuration: totalDuration,
                          ),
                        ),
                      ),
                      // Timeline lane (normal editor-like track area)
                      Positioned(
                        top: _rulerHeight + 6,
                        left: 0,
                        right: 0,
                        height: _trackHeight + 4,
                        child: Container(
                          decoration: BoxDecoration(
                            color: kSurface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: kBorder),
                          ),
                        ),
                      ),
                      // Subtitle cue blocks
                      ...subtitleState.entries.map((entry) {
                        final left =
                            entry.startTime.inMilliseconds /
                            1000 *
                            _pixelsPerSecond;
                        final width =
                            entry.duration.inMilliseconds /
                            1000 *
                            _pixelsPerSecond;
                        final isSelected =
                            entry.id == subtitleState.selectedEntryId;
                        final maxTimelineMs = totalDuration.inMilliseconds == 0
                            ? 999999999
                            : totalDuration.inMilliseconds;

                        return Positioned(
                          left: left,
                          top: _rulerHeight + 8,
                          width: width.clamp(20.0, double.infinity).toDouble(),
                          height: _trackHeight,
                          child: _SubtitleCueBlock(
                            entry: entry,
                            isSelected: isSelected,
                            onTap: () {
                              subtitleNotifier.selectEntry(entry.id);
                            },
                            onTapAtX: (localX) {
                              _seekToTimelineX(left + localX, totalDuration);
                            },
                            onLongPress: widget.onEditRequested == null
                                ? null
                                : () => widget.onEditRequested!.call(entry),
                            onDragStart:
                                subtitleNotifier.beginTimelineGestureEdit,
                            onDragEnd: subtitleNotifier.endTimelineGestureEdit,
                            onDragUpdate: (delta) {
                              final deltaMs =
                                  (delta.dx / _pixelsPerSecond * 1000).round();
                              final spanMs = entry.duration.inMilliseconds;
                              final newStartMs =
                                  (entry.startTime.inMilliseconds + deltaMs)
                                      .clamp(0, maxTimelineMs - spanMs)
                                      .toInt();
                              final newEndMs = (newStartMs + spanMs).clamp(
                                0,
                                maxTimelineMs,
                              );
                              subtitleNotifier.updateTimingLive(
                                entry.id,
                                Duration(milliseconds: newStartMs),
                                Duration(milliseconds: newEndMs.toInt()),
                              );
                            },
                            onLeftEdgeDrag: (delta) {
                              final deltaMs =
                                  (delta.dx / _pixelsPerSecond * 1000).round();
                              final newStartMs =
                                  (entry.startTime.inMilliseconds + deltaMs)
                                      .clamp(
                                        0,
                                        entry.endTime.inMilliseconds - 100,
                                      )
                                      .toInt();
                              subtitleNotifier.updateTimingLive(
                                entry.id,
                                Duration(milliseconds: newStartMs),
                                entry.endTime,
                              );
                            },
                            onRightEdgeDrag: (delta) {
                              final deltaMs =
                                  (delta.dx / _pixelsPerSecond * 1000).round();
                              final newEndMs =
                                  (entry.endTime.inMilliseconds + deltaMs)
                                      .clamp(
                                        entry.startTime.inMilliseconds + 100,
                                        maxTimelineMs,
                                      )
                                      .toInt();
                              subtitleNotifier.updateTimingLive(
                                entry.id,
                                entry.startTime,
                                Duration(milliseconds: newEndMs),
                              );
                            },
                          ),
                        );
                      }),
                      // Playhead
                      Positioned(
                        left:
                            playbackState.position.inMilliseconds /
                                1000 *
                                _pixelsPerSecond -
                            1,
                        top: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: Column(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: kAccent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              Expanded(
                                child: Container(width: 2, color: kAccent),
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
          ),
        ],
      ),
    );
  }
}

/// Draggable, resizable subtitle cue block on the timeline.
class _SubtitleCueBlock extends StatelessWidget {
  final SubtitleEntry entry;
  final bool isSelected;
  final VoidCallback onTap;
  final ValueChanged<double> onTapAtX;
  final VoidCallback? onLongPress;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final Function(Offset) onDragUpdate;
  final Function(Offset) onLeftEdgeDrag;
  final Function(Offset) onRightEdgeDrag;

  const _SubtitleCueBlock({
    required this.entry,
    required this.isSelected,
    required this.onTap,
    required this.onTapAtX,
    required this.onLongPress,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onDragUpdate,
    required this.onLeftEdgeDrag,
    required this.onRightEdgeDrag,
  });

  @override
  Widget build(BuildContext context) {
    const handleWidth = 10.0;
    final bgColor = entry.isLowConfidence
        ? kWarning.withValues(alpha: 0.2)
        : isSelected
        ? kAccent.withValues(alpha: 0.3)
        : kSurface;
    final borderColor = isSelected ? kAccent : kBorder;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => onTapAtX(details.localPosition.dx),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: borderColor, width: isSelected ? 1.5 : 1),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final showTimestamp = constraints.maxWidth >= 60;
                    final maxContentWidth = constraints.maxWidth <= 0
                        ? 0.0
                        : (constraints.maxWidth - 4).clamp(
                            0.0,
                            constraints.maxWidth,
                          );

                    return Align(
                      alignment: Alignment.centerLeft,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: maxContentWidth,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  color: kTextPrimary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                              if (showTimestamp) ...[
                                const SizedBox(height: 1),
                                Text(
                                  SubtitleEntry.formatDisplayTime(
                                    entry.startTime,
                                  ),
                                  style: GoogleFonts.spaceMono(
                                    color: kTextSecondary,
                                    fontSize: 9,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            // Main drag zone for moving the subtitle block.
            Positioned(
              left: handleWidth,
              right: handleWidth,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => onDragStart(),
                onPanUpdate: (details) => onDragUpdate(details.delta),
                onPanEnd: (_) => onDragEnd(),
                onPanCancel: onDragEnd,
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: handleWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => onDragStart(),
                onPanUpdate: (d) => onLeftEdgeDrag(d.delta),
                onPanEnd: (_) => onDragEnd(),
                onPanCancel: onDragEnd,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: Container(
                    width: handleWidth,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? kAccent.withValues(alpha: 0.7)
                          : Colors.transparent,
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(6),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: handleWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => onDragStart(),
                onPanUpdate: (d) => onRightEdgeDrag(d.delta),
                onPanEnd: (_) => onDragEnd(),
                onPanCancel: onDragEnd,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: Container(
                    width: handleWidth,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? kAccent.withValues(alpha: 0.7)
                          : Colors.transparent,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(6),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints the time ruler at the top of the timeline.
class _RulerPainter extends CustomPainter {
  final double pixelsPerSecond;
  final Duration totalDuration;

  _RulerPainter({required this.pixelsPerSecond, required this.totalDuration});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kBorder
      ..strokeWidth = 1;

    final textStyle = TextStyle(
      color: kTextSecondary,
      fontSize: 10,
      fontFamily: 'SpaceMono',
    );

    int tickIntervalSec;
    if (pixelsPerSecond >= 100) {
      tickIntervalSec = 1;
    } else if (pixelsPerSecond >= 50) {
      tickIntervalSec = 5;
    } else if (pixelsPerSecond >= 20) {
      tickIntervalSec = 10;
    } else {
      tickIntervalSec = 30;
    }

    final totalSeconds = totalDuration.inSeconds;
    for (var sec = 0; sec <= totalSeconds; sec += tickIntervalSec) {
      final x = sec * pixelsPerSecond;
      canvas.drawLine(
        Offset(x, size.height - 8),
        Offset(x, size.height),
        paint,
      );

      final minutes = (sec ~/ 60).toString().padLeft(2, '0');
      final secs = (sec % 60).toString().padLeft(2, '0');
      final textPainter = TextPainter(
        text: TextSpan(text: '$minutes:$secs', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(x + 2, 4));
    }
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.pixelsPerSecond != pixelsPerSecond ||
      old.totalDuration != totalDuration;
}
