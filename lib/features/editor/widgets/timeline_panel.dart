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
  final ValueChanged<TimelineClip>? onTextClipEditRequested;
  final ValueChanged<TimelineClip>? onTransitionRequested;
  final ValueChanged<TimelineTrack>? onOverlayAddRequested;

  const TimelinePanel({
    super.key,
    this.onEditRequested,
    this.onTextClipEditRequested,
    this.onTransitionRequested,
    this.onOverlayAddRequested,
  });

  @override
  ConsumerState<TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends ConsumerState<TimelinePanel> {
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  double _pixelsPerSecond = 50;
  double? _scaleStartPixelsPerSecond;

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

  void _removeTrack(TimelineTrack track) {
    if (!_canRemoveTrack(track)) return;

    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final nextTracks = timeline.tracks
        .where((candidate) => candidate.id != track.id)
        .toList();
    final removedAssetIds = track.clips
        .map((clip) => clip.assetId)
        .whereType<String>()
        .toSet();
    final remainingAssetIds = nextTracks
        .expand((candidate) => candidate.clips)
        .map((clip) => clip.assetId)
        .whereType<String>()
        .toSet();
    final nextAssets = timeline.assets
        .where(
          (asset) =>
              !removedAssetIds.contains(asset.id) ||
              remainingAssetIds.contains(asset.id),
        )
        .toList();

    ref
        .read(editorProvider.notifier)
        .setTimeline(timeline.copyWith(tracks: nextTracks, assets: nextAssets));

    if (editorState.selectedTrackId == track.id) {
      ref.read(editorProvider.notifier).selectTrack(null);
    }
    if (editorState.selectedClipId != null &&
        track.clips.any((clip) => clip.id == editorState.selectedClipId)) {
      ref.read(editorProvider.notifier).selectClip(null);
      ref.read(subtitleProvider.notifier).selectEntry(null);
    }
  }

  bool _canRemoveTrack(TimelineTrack track) {
    final timeline = ref.read(editorProvider).timeline;
    switch (track.section) {
      case TimelineTrackSection.overlay:
      case TimelineTrackSection.audio:
        return timeline.tracksForSection(track.section).length > 1;
      case TimelineTrackSection.textSubtitle:
        if (track.type != TimelineTrackType.text) return false;
        return timeline
                .tracksForSection(track.section)
                .where((candidate) => candidate.type == TimelineTrackType.text)
                .length >
            1;
      case TimelineTrackSection.baseVideo:
        return false;
    }
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

  void _moveClip(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
    Offset delta,
  ) {
    if (track.section == TimelineTrackSection.baseVideo) {
      _moveBaseClip(timeline, track, clip, delta);
      return;
    }

    final deltaMs = (delta.dx / _pixelsPerSecond * 1000).round();
    final durationMs = clip.duration.inMilliseconds;
    final maxTimelineMs = timeline.videoClips.isEmpty
        ? clip.endTime.inMilliseconds
        : timeline.videoClips.last.endTime.inMilliseconds;
    final nextStartMs = (clip.startTime.inMilliseconds + deltaMs)
        .clamp(0, (maxTimelineMs - durationMs).clamp(0, maxTimelineMs))
        .toInt();

    var targetTrack = track;
    if (track.section == TimelineTrackSection.overlay) {
      final overlayTracks = timeline.tracksForSection(
        TimelineTrackSection.overlay,
      );
      final currentIndex = overlayTracks.indexWhere(
        (candidate) => candidate.id == track.id,
      );
      if (currentIndex != -1) {
        var targetIndex = currentIndex;
        if (delta.dy.abs() > delta.dx.abs() &&
            delta.dy > 8 &&
            currentIndex < overlayTracks.length - 1) {
          targetIndex += 1;
        } else if (delta.dy.abs() > delta.dx.abs() &&
            delta.dy < -8 &&
            currentIndex > 0) {
          targetIndex -= 1;
        }
        targetTrack = overlayTracks[targetIndex];
      }
    }

    final updatedClip = clip.copyWith(
      trackId: targetTrack.id,
      startTime: Duration(milliseconds: nextStartMs),
      endTime: Duration(milliseconds: nextStartMs + durationMs),
    );

    final nextTracks = timeline.tracks.map((candidateTrack) {
      final nextClips = candidateTrack.clips
          .where((candidate) => candidate.id != clip.id)
          .toList();
      if (candidateTrack.id == targetTrack.id) {
        nextClips.add(updatedClip);
        nextClips.sort((a, b) => a.startTime.compareTo(b.startTime));
      }
      return candidateTrack.copyWith(clips: nextClips);
    }).toList();

    _applyTimeline(timeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier).selectTrack(targetTrack.id);
    ref.read(editorProvider.notifier).selectClip(updatedClip.id);
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

  (TimelineTrack, TimelineClip)? _selectedClipSelection(
    EditorTimeline timeline,
    String? clipId,
  ) {
    if (clipId == null) return null;
    for (final track in timeline.tracks) {
      for (final clip in track.clips) {
        if (clip.id == clipId) {
          return (track, clip);
        }
      }
    }
    return null;
  }

  void _deleteClip(EditorTimeline timeline, TimelineClip clip) {
    final nextTracks = timeline.tracks.map((track) {
      return track.copyWith(
        clips: track.clips
            .where((candidate) => candidate.id != clip.id)
            .toList(),
      );
    }).toList();

    final assetId = clip.assetId;
    final nextAssets = assetId == null
        ? timeline.assets
        : timeline.assets.where((asset) {
            if (asset.id != assetId) return true;
            return nextTracks.any(
              (track) =>
                  track.clips.any((candidate) => candidate.assetId == assetId),
            );
          }).toList();

    _applyTimeline(timeline.copyWith(tracks: nextTracks, assets: nextAssets));
    ref.read(editorProvider.notifier).selectClip(null);
    ref.read(subtitleProvider.notifier).selectEntry(null);
  }

  void _duplicateClip(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
  ) {
    final durationMs = clip.duration.inMilliseconds;
    final timelineEndMs = timeline.videoClips.isEmpty
        ? clip.endTime.inMilliseconds + durationMs
        : timeline.videoClips.last.endTime.inMilliseconds;
    final nextStartMs = clip.endTime.inMilliseconds
        .clamp(0, (timelineEndMs - durationMs).clamp(0, timelineEndMs))
        .toInt();
    final duplicate = TimelineClip(
      trackId: track.id,
      type: clip.type,
      label: clip.label,
      assetId: clip.assetId,
      linkedClipId: clip.linkedClipId,
      startTime: Duration(milliseconds: nextStartMs),
      endTime: Duration(milliseconds: nextStartMs + durationMs),
      sourceStartTime: clip.sourceStartTime,
      sourceDuration: clip.sourceDuration,
      layer: clip.layer,
      enabled: clip.enabled,
      transform: clip.transform,
      audioMix: clip.audioMix,
      fitMode: clip.fitMode,
      text: clip.text,
      subtitleStyle: clip.subtitleStyle,
      introTransition: clip.introTransition,
      outroTransition: clip.outroTransition,
    );

    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.id != track.id) return candidateTrack;
      final nextClips = [...candidateTrack.clips, duplicate]
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
      return candidateTrack.copyWith(clips: nextClips);
    }).toList();

    _applyTimeline(timeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier).selectTrack(track.id);
    ref.read(editorProvider.notifier).selectClip(duplicate.id);
  }

  void _splitClip(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
    Duration splitPoint,
  ) {
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
      trackId: track.id,
      type: clip.type,
      label: clip.label,
      assetId: clip.assetId,
      linkedClipId: clip.linkedClipId,
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

    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.id != track.id) return candidateTrack;
      final nextClips = <TimelineClip>[];
      for (final candidate in candidateTrack.clips) {
        if (candidate.id != clip.id) {
          nextClips.add(candidate);
          continue;
        }
        nextClips.add(firstClip);
        nextClips.add(secondClip);
      }
      nextClips.sort((a, b) => a.startTime.compareTo(b.startTime));
      return candidateTrack.copyWith(clips: nextClips);
    }).toList();

    _applyTimeline(timeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier).selectTrack(track.id);
    ref.read(editorProvider.notifier).selectClip(secondClip.id);
  }

  Widget _buildToolbarButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color color = kTextSecondary,
    bool isActive = false,
  }) {
    final resolvedColor = onPressed == null
        ? color.withValues(alpha: 0.28)
        : (isActive ? kAccent : color);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: isActive
                  ? kAccent.withValues(alpha: 0.14)
                  : kSurfaceElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: isActive ? kAccent : kBorder),
            ),
            child: Icon(icon, color: resolvedColor, size: 18),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
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

  void _scrollToPlayhead(Duration position, double viewportWidth) {
    final targetX = position.inMilliseconds / 1000 * _pixelsPerSecond;
    final centered = (targetX - viewportWidth / 2).clamp(
      0.0,
      _horizontalScrollController.position.maxScrollExtent,
    );
    _horizontalScrollController.animateTo(
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
    final selectedSelection = _selectedClipSelection(
      timeline,
      editorState.selectedClipId,
    );
    final selectedTrack = selectedSelection?.$1;
    final selectedClip = selectedSelection?.$2;
    final selectedSubtitle = subtitleState.selectedEntry;
    final canCopySelection =
        selectedSubtitle != null ||
        (selectedClip != null &&
            selectedTrack?.section != TimelineTrackSection.baseVideo);
    final canDeleteSelection = selectedSubtitle != null || selectedClip != null;
    final canSplitSelection = selectedSubtitle != null || selectedClip != null;
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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: kBorder)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildToolbarButton(
                    icon: Icons.undo_rounded,
                    tooltip: 'Undo',
                    onPressed: subtitleNotifier.canUndo
                        ? () => subtitleNotifier.undo()
                        : null,
                  ),
                  _buildToolbarButton(
                    icon: Icons.redo_rounded,
                    tooltip: 'Redo',
                    onPressed: subtitleNotifier.canRedo
                        ? () => subtitleNotifier.redo()
                        : null,
                  ),
                  _buildToolbarButton(
                    icon: Icons.copy_rounded,
                    tooltip: 'Copy',
                    onPressed: !canCopySelection
                        ? null
                        : () {
                            if (selectedSubtitle != null) {
                              subtitleNotifier.duplicateEntry(
                                selectedSubtitle.id,
                              );
                              return;
                            }
                            if (selectedClip != null && selectedTrack != null) {
                              _duplicateClip(
                                timeline,
                                selectedTrack,
                                selectedClip,
                              );
                            }
                          },
                  ),
                  _buildToolbarButton(
                    icon: Icons.delete_rounded,
                    tooltip: 'Delete',
                    color: kError,
                    onPressed: !canDeleteSelection
                        ? null
                        : () {
                            if (selectedSubtitle != null) {
                              subtitleNotifier.deleteEntry(selectedSubtitle.id);
                              return;
                            }
                            if (selectedClip != null) {
                              _deleteClip(timeline, selectedClip);
                            }
                          },
                  ),
                  _buildToolbarButton(
                    icon: Icons.call_split_rounded,
                    tooltip: 'Split',
                    onPressed: !canSplitSelection
                        ? null
                        : () {
                            if (selectedSubtitle != null) {
                              final splitPoint = playbackState.position;
                              if (splitPoint <= selectedSubtitle.startTime ||
                                  splitPoint >= selectedSubtitle.endTime) {
                                SnackBarHelper.showInfo(
                                  context,
                                  'Move playhead inside the selected subtitle to split it.',
                                );
                                return;
                              }
                              subtitleNotifier.splitEntry(
                                selectedSubtitle.id,
                                splitPoint,
                              );
                              return;
                            }
                            if (selectedClip == null || selectedTrack == null) {
                              return;
                            }
                            if (selectedTrack.section ==
                                TimelineTrackSection.baseVideo) {
                              _splitSelectedBaseClip(
                                timeline,
                                playbackState.position,
                              );
                              return;
                            }
                            _splitClip(
                              timeline,
                              selectedTrack,
                              selectedClip,
                              playbackState.position,
                            );
                          },
                  ),
                  _buildToolbarButton(
                    icon: Icons.my_location_rounded,
                    tooltip: 'Center playhead',
                    onPressed: () => _scrollToPlayhead(
                      playbackState.position,
                      viewportWidth,
                    ),
                  ),
                  _buildToolbarButton(
                    icon: Icons.grid_on_rounded,
                    tooltip: editorState.isSnappingEnabled
                        ? 'Turn snapping off'
                        : 'Turn snapping on',
                    onPressed: () => editorNotifier.setSnappingEnabled(
                      !editorState.isSnappingEnabled,
                    ),
                    isActive: editorState.isSnappingEnabled,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  controller: _verticalScrollController,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: contentHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: _labelColumnWidth,
                          height: contentHeight,
                          child: _TimelineLabels(
                            rowLayouts: rowLayouts,
                            onAddTrack: _addTrack,
                            onRemoveTrack: _removeTrack,
                            canRemoveTrack: _canRemoveTrack,
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onScaleStart: (_) {
                              _scaleStartPixelsPerSecond = _pixelsPerSecond;
                            },
                            onScaleUpdate: (details) {
                              final base = _scaleStartPixelsPerSecond;
                              if (base == null) return;
                              setState(() {
                                _pixelsPerSecond = (base * details.scale)
                                    .clamp(
                                      _minPixelsPerSecond,
                                      _maxPixelsPerSecond,
                                    )
                                    .toDouble();
                              });
                            },
                            onScaleEnd: (_) {
                              _scaleStartPixelsPerSecond = null;
                            },
                            child: SingleChildScrollView(
                              controller: _horizontalScrollController,
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: totalWidth,
                                height: contentHeight,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (details) {
                                    if (details.localPosition.dy <=
                                        _rulerHeight) {
                                      _seekToTimelineX(
                                        details.localPosition.dx,
                                        totalDuration,
                                      );
                                    } else {
                                      editorNotifier.selectClip(null);
                                      editorNotifier.selectTrack(null);
                                      subtitleNotifier.selectEntry(null);
                                    }
                                  },
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: Container(
                                          color: kSurfaceElevated,
                                        ),
                                      ),
                                      Positioned(
                                        top: 0,
                                        left: 0,
                                        right: 0,
                                        height: _rulerHeight,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTapDown: (details) {
                                            _seekToTimelineX(
                                              details.localPosition.dx,
                                              totalDuration,
                                            );
                                          },
                                          child: CustomPaint(
                                            painter: _RulerPainter(
                                              pixelsPerSecond: _pixelsPerSecond,
                                              totalDuration: totalDuration,
                                            ),
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
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                  ),
                                              alignment: Alignment.centerLeft,
                                              color: kBackground.withValues(
                                                alpha: 0.18,
                                              ),
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
                                              selectedClipId:
                                                  editorState.selectedClipId,
                                              selectedSubtitleId:
                                                  subtitleState.selectedEntryId,
                                              onTrackTap: () {
                                                editorNotifier.selectTrack(
                                                  row.track!.id,
                                                );
                                                editorNotifier.selectClip(null);
                                                subtitleNotifier.selectEntry(
                                                  null,
                                                );
                                              },
                                              onDoubleTap:
                                                  row.track!.section ==
                                                      TimelineTrackSection
                                                          .overlay
                                                  ? () => widget
                                                        .onOverlayAddRequested
                                                        ?.call(row.track!)
                                                  : null,
                                              onClipTap: (clip) {
                                                editorNotifier.selectTrack(
                                                  row.track!.id,
                                                );
                                                editorNotifier.selectClip(
                                                  clip.id,
                                                );
                                                if (clip.type ==
                                                    TimelineTrackType
                                                        .subtitle) {
                                                  subtitleNotifier.selectEntry(
                                                    clip.id,
                                                  );
                                                } else {
                                                  subtitleNotifier.selectEntry(
                                                    null,
                                                  );
                                                }
                                              },
                                              onClipLongPress: (clip) {
                                                if (clip.type ==
                                                        TimelineTrackType
                                                            .subtitle &&
                                                    widget.onEditRequested !=
                                                        null) {
                                                  final entry = clip
                                                      .toSubtitleEntry();
                                                  if (entry != null) {
                                                    widget.onEditRequested!(
                                                      entry,
                                                    );
                                                  }
                                                  return;
                                                }
                                                if (clip.type ==
                                                        TimelineTrackType
                                                            .text &&
                                                    widget.onTextClipEditRequested !=
                                                        null) {
                                                  widget
                                                      .onTextClipEditRequested!(
                                                    clip,
                                                  );
                                                }
                                              },
                                              onTransitionTap: (clip) {
                                                editorNotifier.selectTrack(
                                                  row.track!.id,
                                                );
                                                editorNotifier.selectClip(
                                                  clip.id,
                                                );
                                                widget.onTransitionRequested
                                                    ?.call(clip);
                                              },
                                              onClipMoveStart: (clip) {
                                                editorNotifier.selectTrack(
                                                  row.track!.id,
                                                );
                                                editorNotifier.selectClip(
                                                  clip.id,
                                                );
                                                if (clip.type ==
                                                    TimelineTrackType
                                                        .subtitle) {
                                                  subtitleNotifier.selectEntry(
                                                    clip.id,
                                                  );
                                                } else {
                                                  subtitleNotifier.selectEntry(
                                                    null,
                                                  );
                                                }
                                              },
                                              onClipMove: (clip, delta) =>
                                                  _moveClip(
                                                    timeline,
                                                    row.track!,
                                                    clip,
                                                    delta,
                                                  ),
                                              onClipMoveEnd: (_) {},
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
                                            playbackState
                                                    .position
                                                    .inMilliseconds /
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
                                                  borderRadius:
                                                      BorderRadius.circular(2),
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
                        ),
                      ],
                    ),
                  ),
                );
              },
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
        return 44;
      case TimelineTrackType.subtitle:
      case TimelineTrackType.text:
        return 54;
      case TimelineTrackType.video:
      case TimelineTrackType.image:
      case TimelineTrackType.sticker:
      case TimelineTrackType.gif:
        return 58;
    }
  }
}

class _TimelineLabels extends StatelessWidget {
  final List<_TrackRowLayout> rowLayouts;
  final ValueChanged<TimelineTrackSection> onAddTrack;
  final ValueChanged<TimelineTrack> onRemoveTrack;
  final bool Function(TimelineTrack track) canRemoveTrack;

  const _TimelineLabels({
    required this.rowLayouts,
    required this.onAddTrack,
    required this.onRemoveTrack,
    required this.canRemoveTrack,
  });

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
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              row.track!.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                color: kTextPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (canRemoveTrack(row.track!))
                            InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () => onRemoveTrack(row.track!),
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: kBorder),
                                ),
                                child: const Icon(
                                  Icons.remove_rounded,
                                  color: kTextSecondary,
                                  size: 14,
                                ),
                              ),
                            ),
                        ],
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
  final VoidCallback onTrackTap;
  final VoidCallback? onDoubleTap;
  final ValueChanged<TimelineClip> onClipTap;
  final ValueChanged<TimelineClip> onClipLongPress;
  final ValueChanged<TimelineClip> onTransitionTap;
  final ValueChanged<TimelineClip> onClipMoveStart;
  final void Function(TimelineClip clip, Offset delta) onClipMove;
  final ValueChanged<TimelineClip> onClipMoveEnd;
  final void Function(TimelineClip clip, Offset delta) onClipTrimStart;
  final void Function(TimelineClip clip, Offset delta) onClipTrimEnd;

  const _TimelineLane({
    required this.track,
    required this.pixelsPerSecond,
    required this.selectedClipId,
    required this.selectedSubtitleId,
    required this.onTrackTap,
    this.onDoubleTap,
    required this.onClipTap,
    required this.onClipLongPress,
    required this.onTransitionTap,
    required this.onClipMoveStart,
    required this.onClipMove,
    required this.onClipMoveEnd,
    required this.onClipTrimStart,
    required this.onClipTrimEnd,
  });

  @override
  Widget build(BuildContext context) {
    final sortedClips = [...track.clips]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTrackTap,
      onDoubleTap: onDoubleTap,
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
                  onMoveStart: () => onClipMoveStart(clip),
                  onTap: () => onClipTap(clip),
                  onLongPress: () => onClipLongPress(clip),
                  onMoveUpdate: (delta) => onClipMove(clip, delta),
                  onMoveEnd: () => onClipMoveEnd(clip),
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
                          Icons.add_rounded,
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
  final VoidCallback onMoveStart;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final ValueChanged<Offset> onTrimStartUpdate;
  final ValueChanged<Offset> onTrimEndUpdate;

  const _TimelineClipBlock({
    required this.clip,
    required this.isSelected,
    required this.isEditableBaseClip,
    required this.onMoveStart,
    required this.onTap,
    required this.onLongPress,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onTrimStartUpdate,
    required this.onTrimEndUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _clipColors(clip);
    const handleWidth = 10.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showMeta =
                      constraints.maxHeight >= 36 && constraints.maxWidth >= 82;
                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isEditableBaseClip ? handleWidth + 2 : 8,
                      vertical: showMeta ? 4 : 2,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            clip.text?.trim().isNotEmpty == true
                                ? clip.text!
                                : clip.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              color: kTextPrimary,
                              fontSize: showMeta ? 11 : 10,
                              fontWeight: FontWeight.w500,
                              height: 1.0,
                            ),
                          ),
                        ),
                        if (showMeta) const SizedBox(height: 2),
                        if (showMeta)
                          Flexible(
                            child: Text(
                              '${SubtitleEntry.formatDisplayTime(clip.startTime)} • ${clip.duration.inSeconds}s',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.spaceMono(
                                color: kTextSecondary,
                                fontSize: 8.5,
                                height: 1.0,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Positioned(
              left: isEditableBaseClip ? handleWidth : 0,
              right: isEditableBaseClip ? handleWidth : 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => onMoveStart(),
                onPanUpdate: (details) => onMoveUpdate(details.delta),
                onPanEnd: (_) => onMoveEnd(),
                onPanCancel: onMoveEnd,
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
    if (pixelsPerSecond >= 18) {
      tickIntervalSec = 1;
    } else if (pixelsPerSecond >= 12) {
      tickIntervalSec = 2;
    } else {
      tickIntervalSec = 5;
    }

    final totalSeconds = totalDuration.inSeconds;
    for (var sec = 0; sec <= totalSeconds; sec += tickIntervalSec) {
      final x = sec * pixelsPerSecond;
      canvas.drawLine(
        Offset(x, size.height - 8),
        Offset(x, size.height),
        paint,
      );

      final textPainter = TextPainter(
        text: TextSpan(text: '$sec', style: textStyle),
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
