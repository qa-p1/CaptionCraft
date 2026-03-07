import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../models/subtitle_entry.dart';
import '../models/timeline_models.dart';
import '../providers/editor_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/subtitle_provider.dart';

class TimelinePanel extends ConsumerStatefulWidget {
  final ValueChanged<SubtitleEntry>? onEditRequested;

  const TimelinePanel({super.key, this.onEditRequested});

  @override
  ConsumerState<TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends ConsumerState<TimelinePanel> {
  final ScrollController _scrollController = ScrollController();
  double _pixelsPerSecond = 50;

  static const double _minPixelsPerSecond = 10;
  static const double _maxPixelsPerSecond = 150;
  static const double _toolbarHeight = 48;
  static const double _rulerHeight = 30;
  static const double _labelColumnWidth = 128;
  static const double _sectionHeaderHeight = 24;
  static const double _laneGap = 8;
  static const int _minClipDurationMs = 300;

  void _addTrack(TimelineTrackSection section) {
    final timeline = ref.read(editorProvider).timeline;
    final nextTrack = switch (section) {
      TimelineTrackSection.overlay => TimelineTrack(
        name: timeline.nextTrackNameForSection(section),
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
      ),
      TimelineTrackSection.textSubtitle => TimelineTrack(
        name: timeline.nextTrackNameForSection(section),
        type: TimelineTrackType.text,
        section: TimelineTrackSection.textSubtitle,
      ),
      TimelineTrackSection.audio => TimelineTrack(
        name: timeline.nextTrackNameForSection(section),
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
      ),
      TimelineTrackSection.baseVideo => null,
    };

    if (nextTrack == null) return;

    ref
        .read(editorProvider.notifier)
        .setTimeline(
          timeline.copyWith(tracks: [...timeline.tracks, nextTrack]),
        );
  }

  void _applyTimeline(EditorTimeline timeline) {
    ref.read(editorProvider.notifier).setTimeline(timeline);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(timeline.subtitleEntries);
  }

  int _assetDurationMs(EditorTimeline timeline, TimelineClip clip) {
    for (final asset in timeline.assets) {
      if (asset.id == clip.assetId) {
        final durationMs = (asset.metadata['durationMs'] as num?)?.toInt();
        if (durationMs != null && durationMs > 0) {
          return durationMs;
        }
      }
    }
    return clip.sourceDuration.inMilliseconds;
  }

  void _moveBaseClip(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
    Offset delta,
  ) {
    final trackClips = [...track.clips]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final currentIndex = trackClips.indexWhere(
      (candidate) => candidate.id == clip.id,
    );
    if (currentIndex == -1) return;

    final previous = currentIndex > 0 ? trackClips[currentIndex - 1] : null;
    final next = currentIndex < trackClips.length - 1
        ? trackClips[currentIndex + 1]
        : null;
    final deltaMs = (delta.dx / _pixelsPerSecond * 1000).round();
    final durationMs = clip.duration.inMilliseconds;
    final newStartMs = (clip.startTime.inMilliseconds + deltaMs)
        .clamp(
          previous?.endTime.inMilliseconds ?? 0,
          (next?.startTime.inMilliseconds ??
                  timeline.videoClips.last.endTime.inMilliseconds) -
              durationMs,
        )
        .toInt();
    final appliedDelta = newStartMs - clip.startTime.inMilliseconds;
    if (appliedDelta == 0) return;

    final updatedClip = clip.copyWith(
      startTime: Duration(milliseconds: newStartMs),
      endTime: Duration(milliseconds: newStartMs + durationMs),
    );

    final subtitleTrack = timeline.primarySubtitleTrack;
    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.id == track.id) {
        final nextClips =
            candidateTrack.clips
                .map(
                  (candidate) =>
                      candidate.id == clip.id ? updatedClip : candidate,
                )
                .toList()
              ..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
      }
      if (subtitleTrack != null && candidateTrack.id == subtitleTrack.id) {
        final nextClips = candidateTrack.clips.map((candidate) {
          if (candidate.linkedClipId != clip.id) return candidate;
          return candidate.copyWith(
            startTime:
                candidate.startTime + Duration(milliseconds: appliedDelta),
            endTime: candidate.endTime + Duration(milliseconds: appliedDelta),
          );
        }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
      }
      return candidateTrack;
    }).toList();

    _applyTimeline(timeline.copyWith(tracks: nextTracks));
  }

  void _trimBaseClipStart(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
    Offset delta,
  ) {
    final trackClips = [...track.clips]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final currentIndex = trackClips.indexWhere(
      (candidate) => candidate.id == clip.id,
    );
    if (currentIndex == -1) return;

    final previous = currentIndex > 0 ? trackClips[currentIndex - 1] : null;
    final deltaMs = (delta.dx / _pixelsPerSecond * 1000).round();
    final assetDurationMs = _assetDurationMs(timeline, clip);
    final minStartFromSource =
        clip.startTime.inMilliseconds - clip.sourceStartTime.inMilliseconds;
    final newStartMs = (clip.startTime.inMilliseconds + deltaMs)
        .clamp(
          previous?.endTime.inMilliseconds ?? minStartFromSource,
          clip.endTime.inMilliseconds - _minClipDurationMs,
        )
        .toInt();
    if (newStartMs == clip.startTime.inMilliseconds) return;

    final newSourceStartMs =
        clip.sourceStartTime.inMilliseconds +
        (newStartMs - clip.startTime.inMilliseconds);
    final newSourceDurationMs =
        clip.sourceDuration.inMilliseconds -
        (newStartMs - clip.startTime.inMilliseconds);
    if (newSourceStartMs < 0 || newSourceStartMs >= assetDurationMs) return;

    final updatedClip = clip.copyWith(
      startTime: Duration(milliseconds: newStartMs),
      sourceStartTime: Duration(milliseconds: newSourceStartMs),
      sourceDuration: Duration(milliseconds: newSourceDurationMs),
    );

    final subtitleTrack = timeline.primarySubtitleTrack;
    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.id == track.id) {
        final nextClips =
            candidateTrack.clips
                .map(
                  (candidate) =>
                      candidate.id == clip.id ? updatedClip : candidate,
                )
                .toList()
              ..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
      }
      if (subtitleTrack != null && candidateTrack.id == subtitleTrack.id) {
        final nextClips =
            candidateTrack.clips
                .where(
                  (candidate) =>
                      candidate.linkedClipId != clip.id ||
                      candidate.endTime > Duration(milliseconds: newStartMs),
                )
                .map((candidate) {
                  if (candidate.linkedClipId != clip.id) return candidate;
                  return candidate.copyWith(
                    startTime:
                        candidate.startTime < Duration(milliseconds: newStartMs)
                        ? Duration(milliseconds: newStartMs)
                        : candidate.startTime,
                  );
                })
                .toList()
              ..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
      }
      return candidateTrack;
    }).toList();

    _applyTimeline(timeline.copyWith(tracks: nextTracks));
  }

  void _trimBaseClipEnd(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
    Offset delta,
  ) {
    final trackClips = [...track.clips]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final currentIndex = trackClips.indexWhere(
      (candidate) => candidate.id == clip.id,
    );
    if (currentIndex == -1) return;

    final next = currentIndex < trackClips.length - 1
        ? trackClips[currentIndex + 1]
        : null;
    final deltaMs = (delta.dx / _pixelsPerSecond * 1000).round();
    final assetDurationMs = _assetDurationMs(timeline, clip);
    final maxEndFromSource =
        clip.endTime.inMilliseconds +
        (assetDurationMs -
            clip.sourceStartTime.inMilliseconds -
            clip.sourceDuration.inMilliseconds);
    final newEndMs = (clip.endTime.inMilliseconds + deltaMs)
        .clamp(
          clip.startTime.inMilliseconds + _minClipDurationMs,
          next?.startTime.inMilliseconds ?? maxEndFromSource,
        )
        .toInt();
    if (newEndMs == clip.endTime.inMilliseconds) return;

    final newSourceDurationMs =
        clip.sourceDuration.inMilliseconds +
        (newEndMs - clip.endTime.inMilliseconds);
    final updatedClip = clip.copyWith(
      endTime: Duration(milliseconds: newEndMs),
      sourceDuration: Duration(milliseconds: newSourceDurationMs),
    );

    final subtitleTrack = timeline.primarySubtitleTrack;
    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.id == track.id) {
        final nextClips =
            candidateTrack.clips
                .map(
                  (candidate) =>
                      candidate.id == clip.id ? updatedClip : candidate,
                )
                .toList()
              ..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
      }
      if (subtitleTrack != null && candidateTrack.id == subtitleTrack.id) {
        final nextClips =
            candidateTrack.clips
                .where(
                  (candidate) =>
                      candidate.linkedClipId != clip.id ||
                      candidate.startTime < Duration(milliseconds: newEndMs),
                )
                .map((candidate) {
                  if (candidate.linkedClipId != clip.id) return candidate;
                  return candidate.copyWith(
                    endTime:
                        candidate.endTime > Duration(milliseconds: newEndMs)
                        ? Duration(milliseconds: newEndMs)
                        : candidate.endTime,
                  );
                })
                .toList()
              ..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
      }
      return candidateTrack;
    }).toList();

    _applyTimeline(timeline.copyWith(tracks: nextTracks));
  }

  void _splitSelectedBaseClip(EditorTimeline timeline, Duration splitPoint) {
    final editorState = ref.read(editorProvider);
    final selectedClipId = editorState.selectedClipId;
    if (selectedClipId == null) {
      SnackBarHelper.showInfo(context, 'Select a base video clip first.');
      return;
    }

    TimelineTrack? targetTrack;
    TimelineClip? clip;
    for (final track in timeline.tracks) {
      if (track.section != TimelineTrackSection.baseVideo) continue;
      for (final candidate in track.clips) {
        if (candidate.id == selectedClipId) {
          targetTrack = track;
          clip = candidate;
          break;
        }
      }
    }
    if (targetTrack == null || clip == null) {
      SnackBarHelper.showInfo(context, 'Select a base video clip first.');
      return;
    }
    if (splitPoint <= clip.startTime || splitPoint >= clip.endTime) {
      SnackBarHelper.showInfo(
        context,
        'Move playhead inside the selected clip to split it.',
      );
      return;
    }

    final leftDurationMs =
        splitPoint.inMilliseconds - clip.startTime.inMilliseconds;
    final firstClip = clip.copyWith(
      endTime: splitPoint,
      sourceDuration: Duration(milliseconds: leftDurationMs),
      outroTransition: const ClipTransition(),
    );
    final secondClip = TimelineClip(
      trackId: clip.trackId,
      type: clip.type,
      label: clip.label,
      assetId: clip.assetId,
      startTime: splitPoint,
      endTime: clip.endTime,
      sourceStartTime:
          clip.sourceStartTime + Duration(milliseconds: leftDurationMs),
      sourceDuration:
          clip.sourceDuration - Duration(milliseconds: leftDurationMs),
      layer: clip.layer,
      enabled: clip.enabled,
      transform: clip.transform,
      audioMix: clip.audioMix,
      fitMode: clip.fitMode,
      text: clip.text,
      subtitleStyle: clip.subtitleStyle,
      introTransition: const ClipTransition(),
      outroTransition: clip.outroTransition,
    );

    final subtitleTrack = timeline.primarySubtitleTrack;
    final nextTracks = timeline.tracks.map((track) {
      if (track.id == targetTrack!.id) {
        final nextClips = <TimelineClip>[];
        for (final candidate in track.clips) {
          if (candidate.id != clip!.id) {
            nextClips.add(candidate);
            continue;
          }
          nextClips.add(firstClip);
          nextClips.add(secondClip);
        }
        nextClips.sort((a, b) => a.startTime.compareTo(b.startTime));
        return track.copyWith(clips: nextClips);
      }
      if (subtitleTrack != null && track.id == subtitleTrack.id) {
        final nextClips = <TimelineClip>[];
        for (final candidate in track.clips) {
          if (candidate.linkedClipId != clip!.id) {
            nextClips.add(candidate);
            continue;
          }
          if (candidate.endTime <= splitPoint) {
            nextClips.add(candidate.copyWith(linkedClipId: firstClip.id));
            continue;
          }
          if (candidate.startTime >= splitPoint) {
            nextClips.add(candidate.copyWith(linkedClipId: secondClip.id));
            continue;
          }

          final firstSubtitle = candidate.copyWith(
            endTime: splitPoint,
            linkedClipId: firstClip.id,
          );
          final secondEntry = SubtitleEntry(
            startTime: splitPoint,
            endTime: candidate.endTime,
            text: candidate.text ?? candidate.label,
            styleOverride: candidate.subtitleStyle,
          );
          final secondSubtitle = TimelineClip.fromSubtitleEntry(
            secondEntry,
            trackId: candidate.trackId,
            linkedClipId: secondClip.id,
          );
          nextClips.add(firstSubtitle);
          nextClips.add(secondSubtitle);
        }
        nextClips.sort((a, b) => a.startTime.compareTo(b.startTime));
        return track.copyWith(clips: nextClips);
      }
      return track;
    }).toList();

    final nextTimeline = timeline.copyWith(tracks: nextTracks);
    _applyTimeline(nextTimeline);
    ref.read(editorProvider.notifier).selectClip(secondClip.id);
  }

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
    final fit = ((viewportWidth - _labelColumnWidth - 100) / durationSec)
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
    final editorState = ref.watch(editorProvider);
    final editorNotifier = ref.read(editorProvider.notifier);
    final totalDuration = playbackState.duration;
    final viewportWidth = MediaQuery.of(context).size.width;

    final timeline = editorState.timeline.mergeSubtitleEntries(
      subtitles: subtitleState.entries,
      globalStyle: subtitleState.globalStyle,
    );
    TimelineClip? selectedBaseClip;
    if (editorState.selectedClipId != null) {
      for (final track in timeline.tracks) {
        if (track.section != TimelineTrackSection.baseVideo) continue;
        for (final clip in track.clips) {
          if (clip.id == editorState.selectedClipId) {
            selectedBaseClip = clip;
            break;
          }
        }
        if (selectedBaseClip != null) {
          break;
        }
      }
    }
    final rowLayouts = _buildTrackLayouts(timeline);
    final totalWidth =
        (totalDuration.inMilliseconds / 1000 * _pixelsPerSecond) + 120;
    final contentHeight = rowLayouts.isEmpty
        ? _rulerHeight + 80
        : rowLayouts.last.bottom + 12;

    return Container(
      color: kSurfaceElevated,
      child: Column(
        children: [
          Container(
            height: _toolbarHeight,
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
                    editorNotifier.setActivePanel(EditorBottomPanel.text);
                  },
                ),
                IconButton(
                  tooltip: 'Split selected base clip',
                  icon: Icon(
                    Icons.call_split_rounded,
                    color: selectedBaseClip != null
                        ? kTextSecondary
                        : kTextSecondary.withValues(alpha: 0.3),
                    size: 18,
                  ),
                  onPressed: selectedBaseClip == null
                      ? null
                      : () => _splitSelectedBaseClip(
                          timeline,
                          playbackState.position,
                        ),
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
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => editorNotifier.setSnappingEnabled(
                    !editorState.isSnappingEnabled,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: editorState.isSnappingEnabled
                          ? kAccent.withValues(alpha: 0.15)
                          : kSurface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: editorState.isSnappingEnabled
                            ? kAccent
                            : kBorder,
                      ),
                    ),
                    child: Text(
                      editorState.isSnappingEnabled ? 'Snap On' : 'Snap Off',
                      style: GoogleFonts.inter(
                        color: editorState.isSnappingEnabled
                            ? kAccent
                            : kTextSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
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
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: _labelColumnWidth,
                  child: _TimelineLabels(
                    rowLayouts: rowLayouts,
                    onAddTrack: _addTrack,
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: totalWidth,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (details) {
                          _seekToTimelineX(
                            details.localPosition.dx,
                            totalDuration,
                          );
                          editorNotifier.selectClip(null);
                          editorNotifier.selectTrack(null);
                          subtitleNotifier.selectEntry(null);
                        },
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Container(color: kSurfaceElevated),
                            ),
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
                            for (final row in rowLayouts) ...[
                              if (row.sectionTitle != null)
                                Positioned(
                                  top: row.top,
                                  left: 0,
                                  right: 0,
                                  height: _sectionHeaderHeight,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    alignment: Alignment.centerLeft,
                                    color: kBackground.withValues(alpha: 0.18),
                                    child: Text(
                                      row.sectionTitle!,
                                      style: GoogleFonts.inter(
                                        color: kTextSecondary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              if (row.track != null)
                                Positioned(
                                  top: row.laneTop,
                                  left: 0,
                                  right: 0,
                                  height: row.laneHeight,
                                  child: _TimelineLane(
                                    track: row.track!,
                                    pixelsPerSecond: _pixelsPerSecond,
                                    selectedClipId: editorState.selectedClipId,
                                    selectedSubtitleId:
                                        subtitleState.selectedEntryId,
                                    onSeek: (timelineX) => _seekToTimelineX(
                                      timelineX,
                                      totalDuration,
                                    ),
                                    onTrackTap: () {
                                      editorNotifier.selectTrack(row.track!.id);
                                      subtitleNotifier.selectEntry(null);
                                    },
                                    onClipTap: (clip) {
                                      editorNotifier.selectTrack(row.track!.id);
                                      editorNotifier.selectClip(clip.id);
                                      if (clip.type ==
                                          TimelineTrackType.subtitle) {
                                        subtitleNotifier.selectEntry(clip.id);
                                      } else {
                                        subtitleNotifier.selectEntry(null);
                                      }
                                    },
                                    onClipLongPress: (clip) {
                                      if (clip.type !=
                                              TimelineTrackType.subtitle ||
                                          widget.onEditRequested == null) {
                                        return;
                                      }
                                      final entry = clip.toSubtitleEntry();
                                      if (entry != null) {
                                        widget.onEditRequested!(entry);
                                      }
                                    },
                                    onTransitionTap: (clip) {
                                      editorNotifier.selectTrack(row.track!.id);
                                      editorNotifier.selectClip(clip.id);
                                      editorNotifier.setActivePanel(
                                        EditorBottomPanel.transitions,
                                      );
                                    },
                                    onClipMove: (clip, delta) => _moveBaseClip(
                                      timeline,
                                      row.track!,
                                      clip,
                                      delta,
                                    ),
                                    onClipTrimStart: (clip, delta) =>
                                        _trimBaseClipStart(
                                          timeline,
                                          row.track!,
                                          clip,
                                          delta,
                                        ),
                                    onClipTrimEnd: (clip, delta) =>
                                        _trimBaseClipEnd(
                                          timeline,
                                          row.track!,
                                          clip,
                                          delta,
                                        ),
                                  ),
                                ),
                            ],
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
                                      child: Container(
                                        width: 2,
                                        color: kAccent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (rowLayouts
                                .where((row) => row.track != null)
                                .isEmpty)
                              Positioned(
                                top: _rulerHeight + 24,
                                left: 16,
                                child: Text(
                                  'Import clips to start editing.',
                                  style: GoogleFonts.inter(
                                    color: kTextSecondary,
                                    fontSize: 13,
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
          ),
        ],
      ),
    );
  }

  List<_TrackRowLayout> _buildTrackLayouts(EditorTimeline timeline) {
    final layouts = <_TrackRowLayout>[];
    var cursor = _rulerHeight + 4;
    const sectionOrder = [
      TimelineTrackSection.overlay,
      TimelineTrackSection.baseVideo,
      TimelineTrackSection.textSubtitle,
      TimelineTrackSection.audio,
    ];

    for (final section in sectionOrder) {
      final tracks = timeline.tracksForSection(section);
      if (tracks.isEmpty) continue;

      layouts.add(
        _TrackRowLayout.sectionHeader(
          top: cursor,
          title: _sectionTitle(section),
          section: section,
        ),
      );
      cursor += _sectionHeaderHeight;

      for (final track in tracks) {
        final laneHeight = _laneHeightForTrack(track.type);
        layouts.add(
          _TrackRowLayout.track(
            top: cursor,
            laneHeight: laneHeight,
            track: track,
          ),
        );
        cursor += laneHeight + _laneGap;
      }
    }

    return layouts;
  }

  String _sectionTitle(TimelineTrackSection section) {
    switch (section) {
      case TimelineTrackSection.overlay:
        return 'Overlay';
      case TimelineTrackSection.baseVideo:
        return 'Base Video';
      case TimelineTrackSection.textSubtitle:
        return 'Text / Subtitle';
      case TimelineTrackSection.audio:
        return 'Audio';
    }
  }

  double _laneHeightForTrack(TimelineTrackType type) {
    switch (type) {
      case TimelineTrackType.audio:
        return 42;
      case TimelineTrackType.subtitle:
      case TimelineTrackType.text:
        return 48;
      case TimelineTrackType.video:
      case TimelineTrackType.image:
      case TimelineTrackType.sticker:
      case TimelineTrackType.gif:
        return 52;
    }
  }
}

class _TimelineLabels extends StatelessWidget {
  final List<_TrackRowLayout> rowLayouts;
  final ValueChanged<TimelineTrackSection> onAddTrack;

  const _TimelineLabels({required this.rowLayouts, required this.onAddTrack});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: kBorder)),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: Container(color: kSurface)),
          for (final row in rowLayouts) ...[
            if (row.sectionTitle != null)
              Positioned(
                top: row.top,
                left: 0,
                right: 0,
                height: 24,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  color: kBackground.withValues(alpha: 0.24),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.sectionTitle!,
                          style: GoogleFonts.inter(
                            color: kTextSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (row.section != null && _canAddTrack(row.section!))
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => onAddTrack(row.section!),
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: kBorder),
                            ),
                            child: const Icon(
                              Icons.add_rounded,
                              color: kTextSecondary,
                              size: 14,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (row.track != null)
              Positioned(
                top: row.laneTop,
                left: 0,
                right: 0,
                height: row.laneHeight,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.centerLeft,
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: kBorder, width: 0.6),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        row.track!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          color: kTextPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _trackKindLabel(row.track!),
                        style: GoogleFonts.inter(
                          color: kTextSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _trackKindLabel(TimelineTrack track) {
    switch (track.section) {
      case TimelineTrackSection.overlay:
        return 'Overlay lane';
      case TimelineTrackSection.baseVideo:
        return 'Main video lane';
      case TimelineTrackSection.textSubtitle:
        return track.type == TimelineTrackType.subtitle
            ? 'Generated subtitles'
            : 'Text lane';
      case TimelineTrackSection.audio:
        return 'Audio lane';
    }
  }

  bool _canAddTrack(TimelineTrackSection section) {
    switch (section) {
      case TimelineTrackSection.overlay:
      case TimelineTrackSection.textSubtitle:
      case TimelineTrackSection.audio:
        return true;
      case TimelineTrackSection.baseVideo:
        return false;
    }
  }
}

class _TimelineLane extends StatelessWidget {
  final TimelineTrack track;
  final double pixelsPerSecond;
  final String? selectedClipId;
  final String? selectedSubtitleId;
  final ValueChanged<double> onSeek;
  final VoidCallback onTrackTap;
  final ValueChanged<TimelineClip> onClipTap;
  final ValueChanged<TimelineClip> onClipLongPress;
  final ValueChanged<TimelineClip> onTransitionTap;
  final void Function(TimelineClip clip, Offset delta) onClipMove;
  final void Function(TimelineClip clip, Offset delta) onClipTrimStart;
  final void Function(TimelineClip clip, Offset delta) onClipTrimEnd;

  const _TimelineLane({
    required this.track,
    required this.pixelsPerSecond,
    required this.selectedClipId,
    required this.selectedSubtitleId,
    required this.onSeek,
    required this.onTrackTap,
    required this.onClipTap,
    required this.onClipLongPress,
    required this.onTransitionTap,
    required this.onClipMove,
    required this.onClipTrimStart,
    required this.onClipTrimEnd,
  });

  @override
  Widget build(BuildContext context) {
    final sortedClips = [...track.clips]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => onSeek(details.localPosition.dx),
      onTap: onTrackTap,
      child: Container(
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kBorder),
        ),
        child: Stack(
          children: [
            if (sortedClips.isEmpty)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      _emptyTrackHint(track),
                      style: GoogleFonts.inter(
                        color: kTextSecondary.withValues(alpha: 0.8),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            for (final clip in sortedClips)
              Positioned(
                left: clip.startTime.inMilliseconds / 1000 * pixelsPerSecond,
                top: 4,
                width: (clip.duration.inMilliseconds / 1000 * pixelsPerSecond)
                    .clamp(44.0, double.infinity)
                    .toDouble(),
                bottom: 4,
                child: _TimelineClipBlock(
                  clip: clip,
                  isSelected:
                      selectedClipId == clip.id ||
                      selectedSubtitleId == clip.id,
                  isEditableBaseClip:
                      track.section == TimelineTrackSection.baseVideo,
                  onTapDown: (localX) {
                    onSeek(
                      clip.startTime.inMilliseconds / 1000 * pixelsPerSecond +
                          localX,
                    );
                  },
                  onTap: () => onClipTap(clip),
                  onLongPress: () => onClipLongPress(clip),
                  onMoveUpdate: (delta) => onClipMove(clip, delta),
                  onTrimStartUpdate: (delta) => onClipTrimStart(clip, delta),
                  onTrimEndUpdate: (delta) => onClipTrimEnd(clip, delta),
                ),
              ),
            if (track.section == TimelineTrackSection.baseVideo)
              for (var index = 0; index < sortedClips.length - 1; index++)
                Positioned(
                  left:
                      sortedClips[index].endTime.inMilliseconds /
                          1000 *
                          pixelsPerSecond -
                      10,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: () => onTransitionTap(sortedClips[index]),
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: kSurfaceElevated,
                          border: Border.all(color: kAccent),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.auto_awesome_motion_rounded,
                          size: 12,
                          color: kAccent,
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

  String _emptyTrackHint(TimelineTrack track) {
    switch (track.section) {
      case TimelineTrackSection.overlay:
        return 'Add overlay video, image, gif, or sticker';
      case TimelineTrackSection.baseVideo:
        return 'Base clips appear here';
      case TimelineTrackSection.textSubtitle:
        return track.type == TimelineTrackType.subtitle
            ? 'Generated subtitles for clips appear here'
            : 'Add text layers here';
      case TimelineTrackSection.audio:
        return 'Add music, voiceover, or effects';
    }
  }
}

class _TimelineClipBlock extends StatelessWidget {
  final TimelineClip clip;
  final bool isSelected;
  final bool isEditableBaseClip;
  final ValueChanged<double> onTapDown;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<Offset> onMoveUpdate;
  final ValueChanged<Offset> onTrimStartUpdate;
  final ValueChanged<Offset> onTrimEndUpdate;

  const _TimelineClipBlock({
    required this.clip,
    required this.isSelected,
    required this.isEditableBaseClip,
    required this.onTapDown,
    required this.onTap,
    required this.onLongPress,
    required this.onMoveUpdate,
    required this.onTrimStartUpdate,
    required this.onTrimEndUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _clipColors(clip);

    const handleWidth = 10.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => onTapDown(details.localPosition.dx),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: colors.$1,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? kAccent : colors.$2,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: isEditableBaseClip ? handleWidth + 2 : 8,
                  vertical: 5,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      clip.text?.trim().isNotEmpty == true
                          ? clip.text!
                          : clip.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: kTextPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${SubtitleEntry.formatDisplayTime(clip.startTime)} • ${clip.duration.inSeconds}s',
                      style: GoogleFonts.spaceMono(
                        color: kTextSecondary,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (isEditableBaseClip)
              Positioned(
                left: handleWidth,
                right: handleWidth,
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanUpdate: (details) => onMoveUpdate(details.delta),
                ),
              ),
            if (isEditableBaseClip)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: handleWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) => onTrimStartUpdate(details.delta),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected
                          ? kAccent.withValues(alpha: 0.45)
                          : Colors.transparent,
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(6),
                      ),
                    ),
                  ),
                ),
              ),
            if (isEditableBaseClip)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: handleWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) => onTrimEndUpdate(details.delta),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected
                          ? kAccent.withValues(alpha: 0.45)
                          : Colors.transparent,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(6),
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

  (Color, Color) _clipColors(TimelineClip clip) {
    switch (clip.type) {
      case TimelineTrackType.video:
        return (
          kAccent.withValues(alpha: 0.18),
          kAccent.withValues(alpha: 0.45),
        );
      case TimelineTrackType.audio:
        return (const Color(0xFF15352B), const Color(0xFF2E8B57));
      case TimelineTrackType.subtitle:
        return (const Color(0xFF332710), const Color(0xFFD4A017));
      case TimelineTrackType.text:
        return (const Color(0xFF24203C), const Color(0xFF8A7DFF));
      case TimelineTrackType.image:
      case TimelineTrackType.sticker:
      case TimelineTrackType.gif:
        return (const Color(0xFF233349), const Color(0xFF5CA8FF));
    }
  }
}

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
  bool shouldRepaint(covariant _RulerPainter oldDelegate) {
    return oldDelegate.pixelsPerSecond != pixelsPerSecond ||
        oldDelegate.totalDuration != totalDuration;
  }
}

class _TrackRowLayout {
  final double top;
  final double laneHeight;
  final TimelineTrack? track;
  final String? sectionTitle;
  final TimelineTrackSection? section;

  const _TrackRowLayout._({
    required this.top,
    required this.laneHeight,
    this.track,
    this.sectionTitle,
    this.section,
  });

  factory _TrackRowLayout.sectionHeader({
    required double top,
    required String title,
    required TimelineTrackSection section,
  }) {
    return _TrackRowLayout._(
      top: top,
      laneHeight: 24,
      sectionTitle: title,
      section: section,
    );
  }

  factory _TrackRowLayout.track({
    required double top,
    required double laneHeight,
    required TimelineTrack track,
  }) {
    return _TrackRowLayout._(top: top, laneHeight: laneHeight, track: track);
  }

  double get laneTop => track == null ? top : top;
  double get bottom => top + laneHeight;
}
