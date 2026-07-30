import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
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
  bool _rippleEditingEnabled = false;
  TimelineClip? _clipboardClip;
  TimelineTrack? _clipboardTrack;
  SubtitleEntry? _clipboardSubtitle;
  EditorTimeline? _cachedSourceTimeline;
  List<SubtitleEntry>? _cachedSubtitleEntries;
  SubtitleStyleModel? _cachedSubtitleStyle;
  EditorTimeline? _cachedMergedTimeline;
  String? _activeDragClipId;
  String? _activeTrimClipId;
  double _activeDragDy = 0;

  static const double _minPixelsPerSecond = 10;
  static const double _maxPixelsPerSecond = 150;
  static const double _toolbarHeight = 48;
  static const double _rulerHeight = 30;
  static const double _labelColumnWidth = 86;
  static const double _sectionHeaderHeight = 18;
  static const double _laneGap = 5;
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

  EditorTimeline _timelineForBuild(
    EditorTimeline source,
    List<SubtitleEntry> subtitles,
    SubtitleStyleModel subtitleStyle,
  ) {
    if (identical(_cachedSourceTimeline, source) &&
        identical(_cachedSubtitleEntries, subtitles) &&
        identical(_cachedSubtitleStyle, subtitleStyle) &&
        _cachedMergedTimeline != null) {
      return _cachedMergedTimeline!;
    }
    final merged = source.mergeSubtitleEntries(
      subtitles: subtitles,
      globalStyle: subtitleStyle,
    );
    _cachedSourceTimeline = source;
    _cachedSubtitleEntries = subtitles;
    _cachedSubtitleStyle = subtitleStyle;
    _cachedMergedTimeline = merged;
    return merged;
  }

  void _applyTimeline(EditorTimeline timeline) {
    ref.read(editorProvider.notifier).setTimeline(timeline);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(timeline.subtitleEntries);
  }

  void _updateTrack(
    TimelineTrack target,
    TimelineTrack Function(TimelineTrack current) mapper,
  ) {
    final timeline = ref.read(editorProvider).timeline;
    final tracks = timeline.tracks
        .map((track) => track.id == target.id ? mapper(track) : track)
        .toList();
    _applyTimeline(timeline.copyWith(tracks: tracks));
  }

  void _addMarker(Duration position) {
    final timeline = ref.read(editorProvider).timeline;
    final marker = TimelineMarker(
      position: position,
      label: 'Marker ${timeline.markers.length + 1}',
      type: TimelineMarkerType.marker,
    );
    final markers = [...timeline.markers, marker]
      ..sort((a, b) => a.position.compareTo(b.position));
    _applyTimeline(timeline.copyWith(markers: markers));
    SnackBarHelper.showInfo(
      context,
      '${marker.label} added at ${SubtitleEntry.formatDisplayTime(position)}',
    );
  }

  void _removeMarker(TimelineMarker marker) {
    final timeline = ref.read(editorProvider).timeline;
    _applyTimeline(
      timeline.copyWith(
        markers: timeline.markers
            .where((candidate) => candidate.id != marker.id)
            .toList(),
      ),
    );
  }

  void _seekMarker(int direction, Duration currentPosition) {
    final markers = [...ref.read(editorProvider).timeline.markers]
      ..sort((a, b) => a.position.compareTo(b.position));
    if (markers.isEmpty) return;
    TimelineMarker target;
    if (direction < 0) {
      target = markers.lastWhere(
        (marker) =>
            marker.position <
            currentPosition - const Duration(milliseconds: 40),
        orElse: () => markers.last,
      );
    } else {
      target = markers.firstWhere(
        (marker) =>
            marker.position >
            currentPosition + const Duration(milliseconds: 40),
        orElse: () => markers.first,
      );
    }
    ref.read(playbackProvider.notifier).requestSeek(target.position);
  }

  void _zoomBy(double factor) {
    setState(() {
      _pixelsPerSecond = (_pixelsPerSecond * factor)
          .clamp(_minPixelsPerSecond, _maxPixelsPerSecond)
          .toDouble();
    });
  }

  void _fitTimeline(Duration duration, double viewportWidth) {
    if (duration.inMilliseconds <= 0) return;
    final usableWidth = math.max(80.0, viewportWidth - _labelColumnWidth - 24);
    setState(() {
      _pixelsPerSecond = (usableWidth / (duration.inMilliseconds / 1000))
          .clamp(_minPixelsPerSecond, _maxPixelsPerSecond)
          .toDouble();
    });
    if (_horizontalScrollController.hasClients) {
      _horizontalScrollController.jumpTo(0);
    }
  }

  void _removeTrack(TimelineTrack track) {
    if (!_canRemoveTrack(track)) return;
    if (track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track before deleting it.');
      return;
    }

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
    switch (track.section) {
      case TimelineTrackSection.overlay:
      case TimelineTrackSection.audio:
        return true;
      case TimelineTrackSection.textSubtitle:
        return track.type == TimelineTrackType.text;
      case TimelineTrackSection.baseVideo:
        return false;
    }
  }

  Future<void> _requestRemoveTrack(TimelineTrack track) async {
    if (!_canRemoveTrack(track)) return;
    if (track.clips.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete track?'),
          content: Text(
            'Delete ${track.name} and its ${track.clips.length} '
            '${track.clips.length == 1 ? 'clip' : 'clips'}?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(backgroundColor: kError),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final liveTrack = ref
        .read(editorProvider)
        .timeline
        .tracks
        .where((candidate) => candidate.id == track.id)
        .firstOrNull;
    if (liveTrack != null) _removeTrack(liveTrack);
  }

  Future<void> _showTrackActions(
    TimelineTrack track,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final local = overlay.globalToLocal(globalPosition);
    final liveTrack = ref
        .read(editorProvider)
        .timeline
        .tracks
        .where((candidate) => candidate.id == track.id)
        .firstOrNull;
    if (liveTrack == null) return;
    final canHide = liveTrack.section != TimelineTrackSection.audio;
    final canMute =
        liveTrack.section == TimelineTrackSection.audio ||
        liveTrack.type == TimelineTrackType.video;
    final action = await showMenu<_TrackQuickAction>(
      context: context,
      color: kSurfaceElevated,
      position: RelativeRect.fromLTRB(
        local.dx,
        local.dy,
        math.max(0, overlay.size.width - local.dx),
        math.max(0, overlay.size.height - local.dy),
      ),
      items: [
        if (canHide)
          PopupMenuItem(
            value: _TrackQuickAction.visibility,
            child: _TrackActionMenuItem(
              icon: liveTrack.isHidden
                  ? Icons.visibility_rounded
                  : Icons.visibility_off_rounded,
              label: liveTrack.isHidden ? 'Show' : 'Hide',
            ),
          ),
        if (canMute)
          PopupMenuItem(
            value: _TrackQuickAction.mute,
            child: _TrackActionMenuItem(
              icon: liveTrack.isMuted
                  ? Icons.volume_up_rounded
                  : Icons.volume_off_rounded,
              label: liveTrack.isMuted ? 'Unmute' : 'Mute',
            ),
          ),
        PopupMenuItem(
          value: _TrackQuickAction.lock,
          child: _TrackActionMenuItem(
            icon: liveTrack.isLocked
                ? Icons.lock_open_rounded
                : Icons.lock_rounded,
            label: liveTrack.isLocked ? 'Unlock' : 'Lock',
          ),
        ),
        if (_canRemoveTrack(liveTrack))
          const PopupMenuItem(
            value: _TrackQuickAction.delete,
            child: _TrackActionMenuItem(
              icon: Icons.delete_outline_rounded,
              label: 'Delete',
              color: kError,
            ),
          ),
      ],
    );
    if (!mounted || action == null) return;
    final latest = ref
        .read(editorProvider)
        .timeline
        .tracks
        .where((candidate) => candidate.id == liveTrack.id)
        .firstOrNull;
    if (latest == null) return;
    switch (action) {
      case _TrackQuickAction.visibility:
        _updateTrack(
          latest,
          (current) => current.copyWith(isHidden: !current.isHidden),
        );
        break;
      case _TrackQuickAction.mute:
        _updateTrack(
          latest,
          (current) => current.copyWith(isMuted: !current.isMuted),
        );
        break;
      case _TrackQuickAction.lock:
        _updateTrack(
          latest,
          (current) => current.copyWith(isLocked: !current.isLocked),
        );
        break;
      case _TrackQuickAction.delete:
        await _requestRemoveTrack(latest);
        break;
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
    return (clip.sourceStartTime + clip.sourceDuration).inMilliseconds;
  }

  int _snapStartMs(
    EditorTimeline timeline,
    TimelineClip clip,
    int proposedStartMs,
    int durationMs,
  ) {
    if (!ref.read(editorProvider).isSnappingEnabled) return proposedStartMs;
    final thresholdMs = (10 / _pixelsPerSecond * 1000).round().clamp(40, 700);
    final candidates = <int>{
      0,
      ref.read(playbackProvider).position.inMilliseconds,
      ...timeline.markers.map((marker) => marker.position.inMilliseconds),
      ...timeline.tracks
          .expand((track) => track.clips)
          .where((candidate) => candidate.id != clip.id)
          .expand(
            (candidate) => [
              candidate.startTime.inMilliseconds,
              candidate.endTime.inMilliseconds,
            ],
          ),
    };
    var bestStart = proposedStartMs;
    var bestDistance = thresholdMs + 1;
    for (final candidate in candidates) {
      final startDistance = (candidate - proposedStartMs).abs();
      if (startDistance < bestDistance) {
        bestDistance = startDistance;
        bestStart = candidate;
      }
      final endDistance = (candidate - (proposedStartMs + durationMs)).abs();
      if (endDistance < bestDistance) {
        bestDistance = endDistance;
        bestStart = candidate - durationMs;
      }
    }
    return bestDistance <= thresholdMs ? bestStart : proposedStartMs;
  }

  int _snapEdgeMs(EditorTimeline timeline, TimelineClip clip, int proposedMs) {
    if (!ref.read(editorProvider).isSnappingEnabled) return proposedMs;
    final thresholdMs = (10 / _pixelsPerSecond * 1000).round().clamp(40, 700);
    final candidates = <int>{
      0,
      ref.read(playbackProvider).position.inMilliseconds,
      ...timeline.markers.map((marker) => marker.position.inMilliseconds),
      ...timeline.tracks
          .expand((track) => track.clips)
          .where((candidate) => candidate.id != clip.id)
          .expand(
            (candidate) => [
              candidate.startTime.inMilliseconds,
              candidate.endTime.inMilliseconds,
            ],
          ),
    };
    var best = proposedMs;
    var bestDistance = thresholdMs + 1;
    for (final candidate in candidates) {
      final distance = (candidate - proposedMs).abs();
      if (distance < bestDistance) {
        best = candidate;
        bestDistance = distance;
      }
    }
    return bestDistance <= thresholdMs ? best : proposedMs;
  }

  void _copySelection(
    TimelineTrack? selectedTrack,
    TimelineClip? selectedClip,
    SubtitleEntry? selectedSubtitle,
  ) {
    if (selectedSubtitle != null) {
      setState(() {
        _clipboardSubtitle = selectedSubtitle;
        _clipboardClip = null;
        _clipboardTrack = null;
      });
      SnackBarHelper.showInfo(context, 'Subtitle copied');
      return;
    }
    if (selectedTrack == null || selectedClip == null) return;
    setState(() {
      _clipboardClip = selectedClip;
      _clipboardTrack = selectedTrack;
      _clipboardSubtitle = null;
    });
    SnackBarHelper.showInfo(context, '${selectedClip.label} copied');
  }

  void _pasteSelection(EditorTimeline timeline, Duration playhead) {
    final subtitle = _clipboardSubtitle;
    if (subtitle != null) {
      ref
          .read(subtitleProvider.notifier)
          .pasteEntry(subtitle, startTime: playhead);
      return;
    }
    final sourceClip = _clipboardClip;
    final sourceTrack = _clipboardTrack;
    if (sourceClip == null || sourceTrack == null) return;
    final targetTrack = timeline.tracks.where(
      (track) =>
          track.id == sourceTrack.id &&
          !track.isLocked &&
          track.section != TimelineTrackSection.baseVideo,
    );
    if (targetTrack.isEmpty) {
      SnackBarHelper.showInfo(
        context,
        'The copied clip track is unavailable or locked.',
      );
      return;
    }
    final timelineEnd = timeline.duration;
    final end = playhead + sourceClip.duration;
    if (end > timelineEnd) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead earlier to paste this clip.',
      );
      return;
    }
    final pasted = TimelineClip(
      trackId: sourceTrack.id,
      type: sourceClip.type,
      effectKind: sourceClip.effectKind,
      label: sourceClip.label,
      assetId: sourceClip.assetId,
      linkedClipId: sourceClip.linkedClipId,
      startTime: playhead,
      endTime: end,
      sourceStartTime: sourceClip.sourceStartTime,
      sourceDuration: sourceClip.sourceDuration,
      layer: sourceClip.layer,
      enabled: sourceClip.enabled,
      transform: sourceClip.transform,
      audioMix: sourceClip.audioMix,
      fitMode: sourceClip.fitMode,
      playbackRate: sourceClip.playbackRate,
      isReversed: sourceClip.isReversed,
      crop: sourceClip.crop,
      blur: sourceClip.blur,
      colorAdjustments: sourceClip.colorAdjustments,
      text: sourceClip.text,
      subtitleStyle: sourceClip.subtitleStyle,
      introTransition: sourceClip.introTransition,
      outroTransition: sourceClip.outroTransition,
    );
    final nextTracks = timeline.tracks.map((track) {
      if (track.id != sourceTrack.id) return track;
      final clips = [...track.clips, pasted]
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
      return track.copyWith(clips: clips);
    }).toList();
    _applyTimeline(timeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier).selectTrack(sourceTrack.id);
    ref.read(editorProvider.notifier).selectClip(pasted.id);
  }

  int _compositionDurationMs(EditorTimeline timeline) {
    final baseDuration = timeline.baseVideoDuration;
    final resolved = baseDuration > Duration.zero
        ? baseDuration
        : timeline.duration;
    return math.max(0, resolved.inMilliseconds);
  }

  void _moveBaseClip(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
    Offset delta,
  ) {
    if (track.isLocked) return;
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
    final minimumStart = previous?.endTime.inMilliseconds ?? 0;
    final maximumStart =
        (next?.startTime.inMilliseconds ?? _compositionDurationMs(timeline)) -
        durationMs;
    final proposedStart = (clip.startTime.inMilliseconds + deltaMs)
        .clamp(minimumStart, maximumStart)
        .toInt();
    final newStartMs = _snapStartMs(
      timeline,
      clip,
      proposedStart,
      durationMs,
    ).clamp(minimumStart, maximumStart).toInt();
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
    if (track.isLocked) return;
    if (track.section == TimelineTrackSection.baseVideo) {
      _moveBaseClip(timeline, track, clip, delta);
      return;
    }

    final deltaMs = (delta.dx / _pixelsPerSecond * 1000).round();
    final durationMs = clip.duration.inMilliseconds;
    final maxTimelineMs = math.max(
      clip.endTime.inMilliseconds,
      _compositionDurationMs(timeline),
    );
    final maximumStart = (maxTimelineMs - durationMs).clamp(0, maxTimelineMs);
    final proposedStart = (clip.startTime.inMilliseconds + deltaMs)
        .clamp(0, maximumStart)
        .toInt();
    final nextStartMs = _snapStartMs(
      timeline,
      clip,
      proposedStart,
      durationMs,
    ).clamp(0, maximumStart).toInt();

    var targetTrack = track;
    _activeDragDy += delta.dy;
    final laneThreshold = math.max(16.0, _laneHeightForTrack(track.type) / 2);
    if (_activeDragDy.abs() >= laneThreshold &&
        track.section != TimelineTrackSection.baseVideo) {
      final sectionTracks = timeline.tracksForSection(track.section);
      final currentIndex = sectionTracks.indexWhere(
        (candidate) => candidate.id == track.id,
      );
      if (currentIndex != -1) {
        final direction = _activeDragDy > 0 ? 1 : -1;
        var targetIndex = currentIndex + direction;
        while (targetIndex >= 0 && targetIndex < sectionTracks.length) {
          final candidateTrack = sectionTracks[targetIndex];
          if (!candidateTrack.isLocked &&
              _trackAcceptsClip(candidateTrack, clip)) {
            targetTrack = candidateTrack;
            break;
          }
          targetIndex += direction;
        }
      }
      _activeDragDy = 0;
    }

    final updatedClip = clip.copyWith(
      trackId: targetTrack.id,
      startTime: Duration(milliseconds: nextStartMs),
      endTime: Duration(milliseconds: nextStartMs + durationMs),
    );
    final appliedDelta = Duration(
      milliseconds: nextStartMs - clip.startTime.inMilliseconds,
    );

    final nextTracks = timeline.tracks.map((candidateTrack) {
      final nextClips = candidateTrack.clips
          .where((candidate) => candidate.id != clip.id)
          .map(
            (candidate) => candidate.linkedClipId == clip.id
                ? candidate.copyWith(
                    startTime: candidate.startTime + appliedDelta,
                    endTime: candidate.endTime + appliedDelta,
                  )
                : candidate,
          )
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

  bool _trackAcceptsClip(TimelineTrack track, TimelineClip clip) {
    switch (track.section) {
      case TimelineTrackSection.overlay:
        return clip.type == TimelineTrackType.effect
            ? track.type == TimelineTrackType.effect
            : track.type != TimelineTrackType.effect;
      case TimelineTrackSection.audio:
        return clip.type == TimelineTrackType.audio;
      case TimelineTrackSection.textSubtitle:
        return track.type == clip.type;
      case TimelineTrackSection.baseVideo:
        return clip.type == TimelineTrackType.video;
    }
  }

  void _beginClipMove(TimelineClip clip) {
    _activeDragClipId = clip.id;
    _activeDragDy = 0;
    final selection = _selectedClipSelection(
      ref.read(editorProvider).timeline,
      clip.id,
    );
    if (selection == null) return;
    final editorNotifier = ref.read(editorProvider.notifier);
    editorNotifier.beginTimelineGestureEdit();
    editorNotifier.selectTrack(selection.$1.id);
    editorNotifier.selectClip(selection.$2.id);
    if (selection.$2.type == TimelineTrackType.subtitle) {
      ref.read(subtitleProvider.notifier).selectEntry(selection.$2.id);
    } else {
      ref.read(subtitleProvider.notifier).selectEntry(null);
    }
  }

  void _moveClipById(String clipId, Offset delta) {
    if (_activeDragClipId != clipId) return;
    final timeline = ref.read(editorProvider).timeline;
    final selection = _selectedClipSelection(timeline, clipId);
    if (selection == null) return;
    _moveClip(timeline, selection.$1, selection.$2, delta);
  }

  void _endClipMove() {
    _activeDragClipId = null;
    _activeDragDy = 0;
    ref.read(editorProvider.notifier).endTimelineGestureEdit();
  }

  void _trimBaseClipStart(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
    Offset delta,
  ) {
    if (track.isLocked) return;
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
    final minimumStart = previous?.endTime.inMilliseconds ?? minStartFromSource;
    final maximumStart = clip.endTime.inMilliseconds - _minClipDurationMs;
    final proposedStart = (clip.startTime.inMilliseconds + deltaMs)
        .clamp(minimumStart, maximumStart)
        .toInt();
    final newStartMs = _snapEdgeMs(
      timeline,
      clip,
      proposedStart,
    ).clamp(minimumStart, maximumStart).toInt();
    if (newStartMs == clip.startTime.inMilliseconds) return;

    final newSourceStartMs =
        clip.sourceStartTime.inMilliseconds +
        ((newStartMs - clip.startTime.inMilliseconds) * clip.playbackRate)
            .round();
    final newSourceDurationMs =
        clip.sourceDuration.inMilliseconds -
        ((newStartMs - clip.startTime.inMilliseconds) * clip.playbackRate)
            .round();
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
    if (track.isLocked) return;
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
        ((assetDurationMs -
                    clip.sourceStartTime.inMilliseconds -
                    clip.sourceDuration.inMilliseconds) /
                clip.playbackRate)
            .floor();
    final minimumEnd = clip.startTime.inMilliseconds + _minClipDurationMs;
    final maximumEnd = next?.startTime.inMilliseconds ?? maxEndFromSource;
    final proposedEnd = (clip.endTime.inMilliseconds + deltaMs)
        .clamp(minimumEnd, maximumEnd)
        .toInt();
    final newEndMs = _snapEdgeMs(
      timeline,
      clip,
      proposedEnd,
    ).clamp(minimumEnd, maximumEnd).toInt();
    if (newEndMs == clip.endTime.inMilliseconds) return;

    final newSourceDurationMs =
        clip.sourceDuration.inMilliseconds +
        ((newEndMs - clip.endTime.inMilliseconds) * clip.playbackRate).round();
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

  bool _usesSourceBounds(TimelineClip clip) {
    return clip.type == TimelineTrackType.video ||
        clip.type == TimelineTrackType.audio ||
        clip.type == TimelineTrackType.gif;
  }

  void _trimNonBaseClipStart(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
    Offset delta,
  ) {
    if (track.isLocked) return;
    final deltaMs = (delta.dx / _pixelsPerSecond * 1000).round();
    final maximumStart = clip.endTime.inMilliseconds - _minClipDurationMs;
    final sourceBounded = _usesSourceBounds(clip);
    final minimumStart = sourceBounded
        ? math.max(
            0,
            clip.startTime.inMilliseconds -
                (clip.sourceStartTime.inMilliseconds / clip.playbackRate)
                    .floor(),
          )
        : 0;
    final proposedStart = (clip.startTime.inMilliseconds + deltaMs)
        .clamp(minimumStart, maximumStart)
        .toInt();
    final newStartMs = _snapEdgeMs(
      timeline,
      clip,
      proposedStart,
    ).clamp(minimumStart, maximumStart).toInt();
    if (newStartMs == clip.startTime.inMilliseconds) return;

    final sourceDeltaMs =
        ((newStartMs - clip.startTime.inMilliseconds) * clip.playbackRate)
            .round();
    final newDuration = Duration(
      milliseconds: clip.endTime.inMilliseconds - newStartMs,
    );
    final updatedClip = clip.copyWith(
      startTime: Duration(milliseconds: newStartMs),
      sourceStartTime: sourceBounded
          ? clip.sourceStartTime + Duration(milliseconds: sourceDeltaMs)
          : clip.sourceStartTime,
      sourceDuration: sourceBounded
          ? clip.sourceDuration - Duration(milliseconds: sourceDeltaMs)
          : newDuration,
    );
    final nextStart = Duration(milliseconds: newStartMs);
    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.id == track.id) {
        return candidateTrack.copyWith(
          clips: candidateTrack.clips
              .map(
                (candidate) =>
                    candidate.id == clip.id ? updatedClip : candidate,
              )
              .toList(),
        );
      }
      final nextClips = candidateTrack.clips
          .where(
            (candidate) =>
                candidate.linkedClipId != clip.id ||
                candidate.endTime > nextStart,
          )
          .map((candidate) {
            if (candidate.linkedClipId != clip.id ||
                candidate.startTime >= nextStart) {
              return candidate;
            }
            return candidate.copyWith(startTime: nextStart);
          })
          .toList();
      return candidateTrack.copyWith(clips: nextClips);
    }).toList();
    _applyTimeline(timeline.copyWith(tracks: nextTracks));
  }

  void _trimNonBaseClipEnd(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
    Offset delta,
  ) {
    if (track.isLocked) return;
    final deltaMs = (delta.dx / _pixelsPerSecond * 1000).round();
    final sourceBounded = _usesSourceBounds(clip);
    final compositionEnd = math.max(
      clip.endTime.inMilliseconds,
      _compositionDurationMs(timeline),
    );
    final assetDurationMs = _assetDurationMs(timeline, clip);
    final sourceMaximumEnd =
        clip.endTime.inMilliseconds +
        ((assetDurationMs -
                    clip.sourceStartTime.inMilliseconds -
                    clip.sourceDuration.inMilliseconds) /
                clip.playbackRate)
            .floor();
    final maximumEnd = sourceBounded
        ? math.min(compositionEnd, sourceMaximumEnd)
        : compositionEnd;
    final minimumEnd = clip.startTime.inMilliseconds + _minClipDurationMs;
    final proposedEnd = (clip.endTime.inMilliseconds + deltaMs)
        .clamp(minimumEnd, math.max(minimumEnd, maximumEnd))
        .toInt();
    final newEndMs = _snapEdgeMs(
      timeline,
      clip,
      proposedEnd,
    ).clamp(minimumEnd, math.max(minimumEnd, maximumEnd)).toInt();
    if (newEndMs == clip.endTime.inMilliseconds) return;

    final sourceDeltaMs =
        ((newEndMs - clip.endTime.inMilliseconds) * clip.playbackRate).round();
    final newDuration = Duration(
      milliseconds: newEndMs - clip.startTime.inMilliseconds,
    );
    final updatedClip = clip.copyWith(
      endTime: Duration(milliseconds: newEndMs),
      sourceDuration: sourceBounded
          ? clip.sourceDuration + Duration(milliseconds: sourceDeltaMs)
          : newDuration,
    );
    final nextEnd = Duration(milliseconds: newEndMs);
    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.id == track.id) {
        return candidateTrack.copyWith(
          clips: candidateTrack.clips
              .map(
                (candidate) =>
                    candidate.id == clip.id ? updatedClip : candidate,
              )
              .toList(),
        );
      }
      final nextClips = candidateTrack.clips
          .where(
            (candidate) =>
                candidate.linkedClipId != clip.id ||
                candidate.startTime < nextEnd,
          )
          .map((candidate) {
            if (candidate.linkedClipId != clip.id ||
                candidate.endTime <= nextEnd) {
              return candidate;
            }
            return candidate.copyWith(endTime: nextEnd);
          })
          .toList();
      return candidateTrack.copyWith(clips: nextClips);
    }).toList();
    _applyTimeline(timeline.copyWith(tracks: nextTracks));
  }

  void _beginClipTrim(TimelineClip clip) {
    _activeTrimClipId = clip.id;
    ref.read(editorProvider.notifier).beginTimelineGestureEdit();
  }

  void _trimClipStartById(String clipId, Offset delta) {
    if (_activeTrimClipId != clipId) return;
    final timeline = ref.read(editorProvider).timeline;
    final selection = _selectedClipSelection(timeline, clipId);
    if (selection == null) return;
    if (selection.$1.section == TimelineTrackSection.baseVideo) {
      _trimBaseClipStart(timeline, selection.$1, selection.$2, delta);
    } else {
      _trimNonBaseClipStart(timeline, selection.$1, selection.$2, delta);
    }
  }

  void _trimClipEndById(String clipId, Offset delta) {
    if (_activeTrimClipId != clipId) return;
    final timeline = ref.read(editorProvider).timeline;
    final selection = _selectedClipSelection(timeline, clipId);
    if (selection == null) return;
    if (selection.$1.section == TimelineTrackSection.baseVideo) {
      _trimBaseClipEnd(timeline, selection.$1, selection.$2, delta);
    } else {
      _trimNonBaseClipEnd(timeline, selection.$1, selection.$2, delta);
    }
  }

  void _endClipTrim() {
    _activeTrimClipId = null;
    ref.read(editorProvider.notifier).endTimelineGestureEdit();
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
    if (targetTrack.isLocked) {
      SnackBarHelper.showInfo(
        context,
        'Unlock the video track to split clips.',
      );
      return;
    }
    if (splitPoint <= clip.startTime || splitPoint >= clip.endTime) {
      SnackBarHelper.showInfo(
        context,
        'Move playhead inside the selected clip to split it.',
      );
      return;
    }

    final leftTimelineDurationMs =
        splitPoint.inMilliseconds - clip.startTime.inMilliseconds;
    final leftSourceDurationMs = (leftTimelineDurationMs * clip.playbackRate)
        .round();
    final firstClip = clip.copyWith(
      endTime: splitPoint,
      sourceDuration: Duration(milliseconds: leftSourceDurationMs),
      outroTransition: const ClipTransition(),
    );
    final secondClip = TimelineClip(
      trackId: clip.trackId,
      type: clip.type,
      effectKind: clip.effectKind,
      label: clip.label,
      assetId: clip.assetId,
      startTime: splitPoint,
      endTime: clip.endTime,
      sourceStartTime:
          clip.sourceStartTime + Duration(milliseconds: leftSourceDurationMs),
      sourceDuration:
          clip.sourceDuration - Duration(milliseconds: leftSourceDurationMs),
      layer: clip.layer,
      enabled: clip.enabled,
      transform: clip.transform,
      audioMix: clip.audioMix,
      fitMode: clip.fitMode,
      playbackRate: clip.playbackRate,
      isReversed: clip.isReversed,
      crop: clip.crop,
      blur: clip.blur,
      colorAdjustments: clip.colorAdjustments,
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
    final containingTrack = timeline.tracks.where(
      (track) => track.clips.any((candidate) => candidate.id == clip.id),
    );
    if (containingTrack.isNotEmpty && containingTrack.first.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track before deleting.');
      return;
    }
    final isRippleDelete =
        _rippleEditingEnabled &&
        containingTrack.isNotEmpty &&
        containingTrack.first.section == TimelineTrackSection.baseVideo;
    final rippleAmount = clip.duration;
    final nextTracks = timeline.tracks.map((track) {
      final clips = <TimelineClip>[];
      for (final candidate in track.clips) {
        if (candidate.id == clip.id || candidate.linkedClipId == clip.id) {
          continue;
        }
        if (isRippleDelete && candidate.startTime >= clip.endTime) {
          clips.add(
            candidate.copyWith(
              startTime: candidate.startTime - rippleAmount,
              endTime: candidate.endTime - rippleAmount,
            ),
          );
        } else {
          clips.add(candidate);
        }
      }
      clips.sort((a, b) => a.startTime.compareTo(b.startTime));
      return track.copyWith(clips: clips);
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
    if (track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track before duplicating.');
      return;
    }
    final durationMs = clip.duration.inMilliseconds;
    final compositionEndMs = _compositionDurationMs(timeline);
    final timelineEndMs = compositionEndMs > 0
        ? compositionEndMs
        : clip.endTime.inMilliseconds + durationMs;
    final nextStartMs = clip.endTime.inMilliseconds
        .clamp(0, (timelineEndMs - durationMs).clamp(0, timelineEndMs))
        .toInt();
    final duplicate = TimelineClip(
      trackId: track.id,
      type: clip.type,
      effectKind: clip.effectKind,
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
      playbackRate: clip.playbackRate,
      isReversed: clip.isReversed,
      crop: clip.crop,
      blur: clip.blur,
      colorAdjustments: clip.colorAdjustments,
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
    if (track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track before splitting.');
      return;
    }
    if (splitPoint <= clip.startTime || splitPoint >= clip.endTime) {
      SnackBarHelper.showInfo(
        context,
        'Move playhead inside the selected clip to split it.',
      );
      return;
    }

    final leftTimelineDurationMs =
        splitPoint.inMilliseconds - clip.startTime.inMilliseconds;
    final leftSourceDurationMs = (leftTimelineDurationMs * clip.playbackRate)
        .round();
    final firstClip = clip.copyWith(
      endTime: splitPoint,
      sourceDuration: Duration(milliseconds: leftSourceDurationMs),
      outroTransition: const ClipTransition(),
    );
    final secondClip = TimelineClip(
      trackId: track.id,
      type: clip.type,
      effectKind: clip.effectKind,
      label: clip.label,
      assetId: clip.assetId,
      linkedClipId: clip.linkedClipId,
      startTime: splitPoint,
      endTime: clip.endTime,
      sourceStartTime:
          clip.sourceStartTime + Duration(milliseconds: leftSourceDurationMs),
      sourceDuration:
          clip.sourceDuration - Duration(milliseconds: leftSourceDurationMs),
      layer: clip.layer,
      enabled: clip.enabled,
      transform: clip.transform,
      audioMix: clip.audioMix,
      fitMode: clip.fitMode,
      playbackRate: clip.playbackRate,
      isReversed: clip.isReversed,
      crop: clip.crop,
      blur: clip.blur,
      colorAdjustments: clip.colorAdjustments,
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
    final playbackDuration = ref.watch(
      playbackProvider.select((state) => state.duration),
    );
    final subtitleState = ref.watch(subtitleProvider);
    final subtitleNotifier = ref.read(subtitleProvider.notifier);
    final editorState = ref.watch(editorProvider);
    final editorNotifier = ref.read(editorProvider.notifier);
    final timeline = _timelineForBuild(
      editorState.timeline,
      subtitleState.entries,
      subtitleState.globalStyle,
    );
    final fallbackDuration = timeline.tracks
        .expand((track) => track.clips)
        .fold<Duration>(
          Duration.zero,
          (current, clip) => clip.endTime > current ? clip.endTime : current,
        );
    final totalDuration = playbackDuration > fallbackDuration
        ? playbackDuration
        : fallbackDuration;
    final viewportWidth = MediaQuery.of(context).size.width;
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
                    onPressed: editorState.canUndo || subtitleNotifier.canUndo
                        ? () {
                            if (selectedSubtitle != null &&
                                subtitleNotifier.canUndo) {
                              subtitleNotifier.undo();
                            } else if (editorState.canUndo) {
                              editorNotifier.undo();
                            } else {
                              subtitleNotifier.undo();
                            }
                          }
                        : null,
                  ),
                  _buildToolbarButton(
                    icon: Icons.redo_rounded,
                    tooltip: 'Redo',
                    onPressed: editorState.canRedo || subtitleNotifier.canRedo
                        ? () {
                            if (selectedSubtitle != null &&
                                subtitleNotifier.canRedo) {
                              subtitleNotifier.redo();
                            } else if (editorState.canRedo) {
                              editorNotifier.redo();
                            } else {
                              subtitleNotifier.redo();
                            }
                          }
                        : null,
                  ),
                  _buildToolbarButton(
                    icon: Icons.copy_rounded,
                    tooltip: 'Copy',
                    onPressed: !canCopySelection
                        ? null
                        : () => _copySelection(
                            selectedTrack,
                            selectedClip,
                            selectedSubtitle,
                          ),
                  ),
                  _buildToolbarButton(
                    icon: Icons.content_paste_rounded,
                    tooltip: 'Paste at playhead',
                    onPressed:
                        _clipboardClip == null && _clipboardSubtitle == null
                        ? null
                        : () => _pasteSelection(
                            timeline,
                            ref.read(playbackProvider).position,
                          ),
                  ),
                  _buildToolbarButton(
                    icon: Icons.control_point_duplicate_rounded,
                    tooltip: 'Duplicate selection',
                    onPressed: selectedSubtitle != null
                        ? () => subtitleNotifier.duplicateEntry(
                            selectedSubtitle.id,
                          )
                        : selectedClip != null && selectedTrack != null
                        ? () => _duplicateClip(
                            timeline,
                            selectedTrack,
                            selectedClip,
                          )
                        : null,
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
                              final splitPoint = ref
                                  .read(playbackProvider)
                                  .position;
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
                                ref.read(playbackProvider).position,
                              );
                              return;
                            }
                            _splitClip(
                              timeline,
                              selectedTrack,
                              selectedClip,
                              ref.read(playbackProvider).position,
                            );
                          },
                  ),
                  _buildToolbarButton(
                    icon: Icons.my_location_rounded,
                    tooltip: 'Center playhead',
                    onPressed: () => _scrollToPlayhead(
                      ref.read(playbackProvider).position,
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
                  _buildToolbarButton(
                    icon: Icons.keyboard_double_arrow_left_rounded,
                    tooltip: 'Previous marker',
                    onPressed: timeline.markers.isEmpty
                        ? null
                        : () => _seekMarker(
                            -1,
                            ref.read(playbackProvider).position,
                          ),
                  ),
                  _buildToolbarButton(
                    icon: Icons.add_location_alt_rounded,
                    tooltip: 'Add marker at playhead',
                    onPressed: () =>
                        _addMarker(ref.read(playbackProvider).position),
                  ),
                  _buildToolbarButton(
                    icon: Icons.keyboard_double_arrow_right_rounded,
                    tooltip: 'Next marker',
                    onPressed: timeline.markers.isEmpty
                        ? null
                        : () => _seekMarker(
                            1,
                            ref.read(playbackProvider).position,
                          ),
                  ),
                  _buildToolbarButton(
                    icon: Icons.compress_rounded,
                    tooltip: _rippleEditingEnabled
                        ? 'Turn ripple editing off'
                        : 'Turn ripple editing on',
                    onPressed: () {
                      setState(
                        () => _rippleEditingEnabled = !_rippleEditingEnabled,
                      );
                    },
                    isActive: _rippleEditingEnabled,
                  ),
                  _buildToolbarButton(
                    icon: Icons.zoom_out_rounded,
                    tooltip: 'Zoom out',
                    onPressed: _pixelsPerSecond <= _minPixelsPerSecond
                        ? null
                        : () => _zoomBy(0.8),
                  ),
                  _buildToolbarButton(
                    icon: Icons.fit_screen_rounded,
                    tooltip: 'Fit timeline',
                    onPressed: () => _fitTimeline(totalDuration, viewportWidth),
                  ),
                  _buildToolbarButton(
                    icon: Icons.zoom_in_rounded,
                    tooltip: 'Zoom in',
                    onPressed: _pixelsPerSecond >= _maxPixelsPerSecond
                        ? null
                        : () => _zoomBy(1.25),
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
                            onShowTrackActions: _showTrackActions,
                          ),
                        ),
                        Expanded(
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
                                      child: Container(color: kSurfaceElevated),
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
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                            ),
                                            alignment: Alignment.centerLeft,
                                            color: kBackground.withValues(
                                              alpha: 0.18,
                                            ),
                                            child: Text(
                                              row.sectionTitle!,
                                              style: TextStyle(
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
                                            onShowTrackActions: (position) =>
                                                _showTrackActions(
                                                  row.track!,
                                                  position,
                                                ),
                                            onClipTap: (clip) {
                                              editorNotifier.selectTrack(
                                                row.track!.id,
                                              );
                                              editorNotifier.selectClip(
                                                clip.id,
                                              );
                                              if (clip.type ==
                                                  TimelineTrackType.subtitle) {
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
                                                      TimelineTrackType.text &&
                                                  widget.onTextClipEditRequested !=
                                                      null) {
                                                widget.onTextClipEditRequested!(
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
                                            onClipMoveStart: _beginClipMove,
                                            onClipMove: (clip, delta) =>
                                                _moveClipById(clip.id, delta),
                                            onClipMoveEnd: (_) =>
                                                _endClipMove(),
                                            onClipTrimGestureStart:
                                                _beginClipTrim,
                                            onClipTrimGestureEnd: (_) =>
                                                _endClipTrim(),
                                            onClipTrimStart: (clip, delta) =>
                                                _trimClipStartById(
                                                  clip.id,
                                                  delta,
                                                ),
                                            onClipTrimEnd: (clip, delta) =>
                                                _trimClipEndById(
                                                  clip.id,
                                                  delta,
                                                ),
                                          ),
                                        ),
                                    ],
                                    for (final marker in timeline.markers)
                                      Positioned(
                                        left:
                                            marker.position.inMilliseconds /
                                                1000 *
                                                _pixelsPerSecond -
                                            6,
                                        top: 0,
                                        bottom: 0,
                                        width: 12,
                                        child: Stack(
                                          alignment: Alignment.topCenter,
                                          children: [
                                            Positioned(
                                              top: 10,
                                              bottom: 0,
                                              child: IgnorePointer(
                                                child: Container(
                                                  width: 1,
                                                  color: marker.color
                                                      .withValues(alpha: 0.48),
                                                ),
                                              ),
                                            ),
                                            Tooltip(
                                              message:
                                                  '${marker.label}\n'
                                                  '${SubtitleEntry.formatDisplayTime(marker.position)}'
                                                  '\nLong-press to remove',
                                              child: GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onTap: () => ref
                                                    .read(
                                                      playbackProvider.notifier,
                                                    )
                                                    .requestSeek(
                                                      marker.position,
                                                    ),
                                                onLongPress: () =>
                                                    _removeMarker(marker),
                                                child: Icon(
                                                  marker.type ==
                                                          TimelineMarkerType
                                                              .chapter
                                                      ? Icons.bookmark_rounded
                                                      : marker.type ==
                                                            TimelineMarkerType
                                                                .beat
                                                      ? Icons.music_note_rounded
                                                      : Icons
                                                            .arrow_drop_down_rounded,
                                                  color: marker.color,
                                                  size: 18,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    Consumer(
                                      builder: (context, ref, _) {
                                        final position = ref.watch(
                                          playbackProvider.select(
                                            (state) => state.position,
                                          ),
                                        );
                                        return Positioned(
                                          left:
                                              position.inMilliseconds /
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
                                                        BorderRadius.circular(
                                                          2,
                                                        ),
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
                                        );
                                      },
                                    ),
                                    if (rowLayouts
                                        .where((row) => row.track != null)
                                        .isEmpty)
                                      Positioned(
                                        top: _rulerHeight + 24,
                                        left: 16,
                                        child: Text(
                                          'Import clips to start editing.',
                                          style: TextStyle(
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
        final laneHeight = track.isCollapsed
            ? 24.0
            : _laneHeightForTrack(track.type);
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
        return 30;
      case TimelineTrackType.subtitle:
      case TimelineTrackType.text:
        return 36;
      case TimelineTrackType.video:
      case TimelineTrackType.image:
      case TimelineTrackType.sticker:
      case TimelineTrackType.gif:
      case TimelineTrackType.effect:
        return 40;
    }
  }
}

enum _TrackQuickAction { visibility, mute, lock, delete }

class _TrackActionMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _TrackActionMenuItem({
    required this.icon,
    required this.label,
    this.color = kTextPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 19, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

IconData _trackIcon(TimelineTrackType type) {
  switch (type) {
    case TimelineTrackType.video:
      return Icons.movie_outlined;
    case TimelineTrackType.audio:
      return Icons.graphic_eq_rounded;
    case TimelineTrackType.subtitle:
      return Icons.closed_caption_outlined;
    case TimelineTrackType.text:
      return Icons.title_rounded;
    case TimelineTrackType.image:
      return Icons.image_outlined;
    case TimelineTrackType.sticker:
      return Icons.emoji_emotions_outlined;
    case TimelineTrackType.gif:
      return Icons.gif_box_outlined;
    case TimelineTrackType.effect:
      return Icons.auto_fix_high_rounded;
  }
}

class _TimelineLabels extends StatelessWidget {
  final List<_TrackRowLayout> rowLayouts;
  final ValueChanged<TimelineTrackSection> onAddTrack;
  final void Function(TimelineTrack track, Offset position) onShowTrackActions;

  const _TimelineLabels({
    required this.rowLayouts,
    required this.onAddTrack,
    required this.onShowTrackActions,
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
                height: row.laneHeight,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  color: kBackground.withValues(alpha: 0.24),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.sectionTitle!,
                          style: TextStyle(
                            color: kTextSecondary,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (row.section != null && _canAddTrack(row.section!))
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => onAddTrack(row.section!),
                          child: const SizedBox(
                            width: 18,
                            height: 18,
                            child: Icon(
                              Icons.add_rounded,
                              color: kTextSecondary,
                              size: 13,
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
                child: _CompactTrackLabel(
                  track: row.track!,
                  onShowActions: (position) =>
                      onShowTrackActions(row.track!, position),
                ),
              ),
          ],
        ],
      ),
    );
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

class _CompactTrackLabel extends StatefulWidget {
  final TimelineTrack track;
  final ValueChanged<Offset> onShowActions;

  const _CompactTrackLabel({required this.track, required this.onShowActions});

  @override
  State<_CompactTrackLabel> createState() => _CompactTrackLabelState();
}

class _CompactTrackLabelState extends State<_CompactTrackLabel> {
  Offset? _lastDoubleTapPosition;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTapDown: (details) {
        _lastDoubleTapPosition = details.globalPosition;
      },
      onDoubleTap: () {
        final renderBox = context.findRenderObject() as RenderBox?;
        widget.onShowActions(
          _lastDoubleTapPosition ??
              renderBox?.localToGlobal(renderBox.size.center(Offset.zero)) ??
              Offset.zero,
        );
      },
      child: Opacity(
        opacity: track.isHidden ? 0.48 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7),
          alignment: Alignment.centerLeft,
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: kBorder, width: 0.6)),
          ),
          child: Row(
            children: [
              Icon(
                _trackIcon(track.type),
                size: 13,
                color: track.isLocked ? kWarning : kTextSecondary,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  track.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (track.isMuted)
                const Icon(
                  Icons.volume_off_rounded,
                  size: 11,
                  color: kTextSecondary,
                ),
              if (track.isLocked) ...[
                const SizedBox(width: 3),
                const Icon(Icons.lock_rounded, size: 11, color: kWarning),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DoubleTapTrackSurface extends StatefulWidget {
  final VoidCallback onTap;
  final ValueChanged<Offset> onShowActions;
  final Widget child;

  const _DoubleTapTrackSurface({
    required this.onTap,
    required this.onShowActions,
    required this.child,
  });

  @override
  State<_DoubleTapTrackSurface> createState() => _DoubleTapTrackSurfaceState();
}

class _DoubleTapTrackSurfaceState extends State<_DoubleTapTrackSurface> {
  Offset? _lastDoubleTapPosition;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: (details) {
        _lastDoubleTapPosition = details.globalPosition;
      },
      onDoubleTap: () {
        final renderBox = context.findRenderObject() as RenderBox?;
        widget.onShowActions(
          _lastDoubleTapPosition ??
              renderBox?.localToGlobal(renderBox.size.center(Offset.zero)) ??
              Offset.zero,
        );
      },
      child: widget.child,
    );
  }
}

class _TimelineLane extends StatelessWidget {
  final TimelineTrack track;
  final double pixelsPerSecond;
  final String? selectedClipId;
  final String? selectedSubtitleId;
  final VoidCallback onTrackTap;
  final ValueChanged<Offset> onShowTrackActions;
  final ValueChanged<TimelineClip> onClipTap;
  final ValueChanged<TimelineClip> onClipLongPress;
  final ValueChanged<TimelineClip> onTransitionTap;
  final ValueChanged<TimelineClip> onClipMoveStart;
  final void Function(TimelineClip clip, Offset delta) onClipMove;
  final ValueChanged<TimelineClip> onClipMoveEnd;
  final ValueChanged<TimelineClip> onClipTrimGestureStart;
  final ValueChanged<TimelineClip> onClipTrimGestureEnd;
  final void Function(TimelineClip clip, Offset delta) onClipTrimStart;
  final void Function(TimelineClip clip, Offset delta) onClipTrimEnd;

  const _TimelineLane({
    required this.track,
    required this.pixelsPerSecond,
    required this.selectedClipId,
    required this.selectedSubtitleId,
    required this.onTrackTap,
    required this.onShowTrackActions,
    required this.onClipTap,
    required this.onClipLongPress,
    required this.onTransitionTap,
    required this.onClipMoveStart,
    required this.onClipMove,
    required this.onClipMoveEnd,
    required this.onClipTrimGestureStart,
    required this.onClipTrimGestureEnd,
    required this.onClipTrimStart,
    required this.onClipTrimEnd,
  });

  @override
  Widget build(BuildContext context) {
    final sortedClips = [...track.clips]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    return _DoubleTapTrackSurface(
      onTap: onTrackTap,
      onShowActions: onShowTrackActions,
      child: Opacity(
        opacity: track.isHidden ? 0.42 : 1,
        child: Container(
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: track.isLocked
                  ? kWarning.withValues(alpha: 0.42)
                  : kBorder,
            ),
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
                        style: TextStyle(
                          color: kTextSecondary.withValues(alpha: 0.8),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              for (final clip in sortedClips) _buildPositionedClip(clip),
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
              if (track.isLocked)
                const Positioned(
                  right: 6,
                  top: 5,
                  child: IgnorePointer(
                    child: Icon(Icons.lock_rounded, size: 12, color: kWarning),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPositionedClip(TimelineClip clip) {
    final visualWidth = math.max(
      1.0,
      clip.duration.inMilliseconds / 1000 * pixelsPerSecond,
    );
    final hitWidth = math.max(28.0, visualWidth);
    final visibleInset = (hitWidth - visualWidth) / 2;
    final startX = clip.startTime.inMilliseconds / 1000 * pixelsPerSecond;
    return Positioned(
      left: startX - visibleInset,
      top: 3,
      width: hitWidth,
      bottom: 3,
      child: _TimelineClipBlock(
        clip: clip,
        visualWidth: visualWidth,
        isSelected: selectedClipId == clip.id || selectedSubtitleId == clip.id,
        showTrimHandles: !track.isCollapsed,
        isLocked: track.isLocked,
        onMoveStart: () => onClipMoveStart(clip),
        onTap: () => onClipTap(clip),
        onLongPress: () => onClipLongPress(clip),
        onMoveUpdate: (delta) => onClipMove(clip, delta),
        onMoveEnd: () => onClipMoveEnd(clip),
        onTrimGestureStart: () => onClipTrimGestureStart(clip),
        onTrimGestureEnd: () => onClipTrimGestureEnd(clip),
        onTrimStartUpdate: (delta) => onClipTrimStart(clip, delta),
        onTrimEndUpdate: (delta) => onClipTrimEnd(clip, delta),
      ),
    );
  }

  String _emptyTrackHint(TimelineTrack track) {
    switch (track.section) {
      case TimelineTrackSection.overlay:
        return track.type == TimelineTrackType.effect
            ? 'Add blur or filter effects'
            : 'Add overlay video, image, gif, or sticker';
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
  final double visualWidth;
  final bool isSelected;
  final bool showTrimHandles;
  final bool isLocked;
  final VoidCallback onMoveStart;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final VoidCallback onTrimGestureStart;
  final VoidCallback onTrimGestureEnd;
  final ValueChanged<Offset> onTrimStartUpdate;
  final ValueChanged<Offset> onTrimEndUpdate;

  const _TimelineClipBlock({
    required this.clip,
    required this.visualWidth,
    required this.isSelected,
    required this.showTrimHandles,
    required this.isLocked,
    required this.onMoveStart,
    required this.onTap,
    required this.onLongPress,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onTrimGestureStart,
    required this.onTrimGestureEnd,
    required this.onTrimStartUpdate,
    required this.onTrimEndUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _clipColors(clip);
    const handleHitWidth = 12.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedVisualWidth = visualWidth
            .clamp(1.0, constraints.maxWidth)
            .toDouble();
        final visibleLeft = (constraints.maxWidth - resolvedVisualWidth) / 2;
        final showMeta =
            constraints.maxHeight >= 34 && resolvedVisualWidth >= 82;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: visibleLeft,
                top: 0,
                bottom: 0,
                width: resolvedVisualWidth,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: showMeta ? 3 : 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.$1,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: isSelected ? kAccent : colors.$2,
                      width: isSelected ? 1.5 : 1,
                    ),
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
                          style: TextStyle(
                            color: kTextPrimary,
                            fontSize: showMeta ? 10.5 : 9.5,
                            fontWeight: FontWeight.w500,
                            height: 1,
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
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              color: kTextSecondary,
                              fontSize: 8,
                              height: 1,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: visibleLeft,
                top: 0,
                bottom: 0,
                width: resolvedVisualWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanStart: isLocked ? null : (_) => onMoveStart(),
                  onPanUpdate: isLocked
                      ? null
                      : (details) => onMoveUpdate(details.delta),
                  onPanEnd: isLocked ? null : (_) => onMoveEnd(),
                  onPanCancel: isLocked ? null : onMoveEnd,
                ),
              ),
              if (showTrimHandles && !isLocked)
                Positioned(
                  left: visibleLeft - handleHitWidth / 2,
                  top: 0,
                  bottom: 0,
                  width: handleHitWidth,
                  child: _TrimHandle(
                    isSelected: isSelected,
                    onGestureStart: onTrimGestureStart,
                    onGestureEnd: onTrimGestureEnd,
                    onUpdate: onTrimStartUpdate,
                  ),
                ),
              if (showTrimHandles && !isLocked)
                Positioned(
                  left: visibleLeft + resolvedVisualWidth - handleHitWidth / 2,
                  top: 0,
                  bottom: 0,
                  width: handleHitWidth,
                  child: _TrimHandle(
                    isSelected: isSelected,
                    onGestureStart: onTrimGestureStart,
                    onGestureEnd: onTrimGestureEnd,
                    onUpdate: onTrimEndUpdate,
                  ),
                ),
            ],
          ),
        );
      },
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
      case TimelineTrackType.effect:
        return (const Color(0xFF30253F), const Color(0xFFB784F7));
    }
  }
}

class _TrimHandle extends StatelessWidget {
  final bool isSelected;
  final VoidCallback onGestureStart;
  final VoidCallback onGestureEnd;
  final ValueChanged<Offset> onUpdate;

  const _TrimHandle({
    required this.isSelected,
    required this.onGestureStart,
    required this.onGestureEnd,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => onGestureStart(),
      onPanUpdate: (details) => onUpdate(details.delta),
      onPanEnd: (_) => onGestureEnd(),
      onPanCancel: onGestureEnd,
      child: Center(
        child: Container(
          width: 3,
          height: double.infinity,
          color: kAccent.withValues(alpha: isSelected ? 0.9 : 0.35),
        ),
      ),
    );
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
      laneHeight: 18,
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
