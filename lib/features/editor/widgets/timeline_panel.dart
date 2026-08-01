import 'dart:math' as math;

import 'package:flutter/gestures.dart';
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
  _ClipMoveSession? _clipMoveSession;
  _ClipTrimSession? _clipTrimSession;

  @override
  void initState() {
    super.initState();
    ref.listenManual<Duration>(
      playbackProvider.select((state) => state.position),
      (_, next) {
        if (!mounted) return;
        final workspace = ref.read(editorProvider).timeline.workspaceSettings;
        if (workspace.autoFollowPlayhead) _scrollToPlayhead(next);
      },
    );
  }

  static const double _minPixelsPerSecond = 10;
  static const double _maxPixelsPerSecond = 150;
  static const double _toolbarHeight = 48;
  static const double _rulerHeight = 30;
  static const double _labelColumnWidth = 50;
  static const double _sectionHeaderHeight = 8;
  static const double _laneGap = 5;
  static const int _minClipDurationMs = 300;

  void _addTrack(TimelineTrackType type) {
    final timeline = ref.read(editorProvider).timeline;
    final nextTrack = switch (type) {
      TimelineTrackType.video => TimelineTrack(
        name: timeline.nextTrackNameForSection(TimelineTrackSection.overlay),
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
      ),
      TimelineTrackType.text => TimelineTrack(
        name: timeline.nextTrackNameForSection(
          TimelineTrackSection.textSubtitle,
        ),
        type: TimelineTrackType.text,
        section: TimelineTrackSection.textSubtitle,
      ),
      TimelineTrackType.audio => TimelineTrack(
        name: timeline.nextTrackNameForSection(TimelineTrackSection.audio),
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
      ),
      TimelineTrackType.effect => TimelineTrack(
        name:
            'Effects ${timeline.tracks.where((track) => track.type == TimelineTrackType.effect).length + 1}',
        type: TimelineTrackType.effect,
        section: TimelineTrackSection.overlay,
      ),
      TimelineTrackType.image ||
      TimelineTrackType.gif ||
      TimelineTrackType.sticker ||
      TimelineTrackType.subtitle => null,
    };

    if (nextTrack == null) return;

    final notifier = ref.read(editorProvider.notifier);
    notifier
      ..setTimeline(timeline.copyWith(tracks: [...timeline.tracks, nextTrack]))
      ..selectTrack(nextTrack.id)
      ..selectClip(null);
    ref.read(subtitleProvider.notifier).selectEntry(null);
  }

  Future<void> _showAddTrackChooser() async {
    final selectedType = await showModalBottomSheet<TimelineTrackType>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final maxHeight = math.min(
          430.0,
          MediaQuery.sizeOf(sheetContext).height * 0.82,
        );
        return SafeArea(
          top: false,
          child: SizedBox(
            height: maxHeight,
            child: Container(
              decoration: const BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
              ),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: kBorder,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        'Add track',
                        style: TextStyle(
                          color: kTextPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final option in const [
                      (
                        TimelineTrackType.video,
                        'Visual overlay',
                        'Video, image, GIF, or sticker clips',
                        Icons.layers_outlined,
                      ),
                      (
                        TimelineTrackType.text,
                        'Text',
                        'Titles and text overlays',
                        Icons.title_rounded,
                      ),
                      (
                        TimelineTrackType.audio,
                        'Audio',
                        'Music, voiceover, or sound effects',
                        Icons.graphic_eq_rounded,
                      ),
                      (
                        TimelineTrackType.effect,
                        'Effects',
                        'Timed blur and look effects',
                        Icons.auto_fix_high_rounded,
                      ),
                    ])
                      ListTile(
                        key: ValueKey(
                          'timeline_track_choice_${option.$1.name}',
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: kAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(option.$4, color: kAccent, size: 20),
                        ),
                        title: Text(
                          option.$2,
                          style: const TextStyle(
                            color: kTextPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          option.$3,
                          style: const TextStyle(
                            color: kTextSecondary,
                            fontSize: 11,
                          ),
                        ),
                        onTap: () => Navigator.pop(sheetContext, option.$1),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || selectedType == null) return;
    _addTrack(selectedType);
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

  void _fitTimeline(Duration duration) {
    if (duration.inMilliseconds <= 0) return;
    final viewportWidth = _horizontalScrollController.hasClients
        ? _horizontalScrollController.position.viewportDimension
        : math.max(0.0, MediaQuery.sizeOf(context).width - _labelColumnWidth);
    final usableWidth = math.max(80.0, viewportWidth - 24);
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
      final targetTrack = timeline.insertionTrackFor(
        section: TimelineTrackSection.textSubtitle,
        clipType: TimelineTrackType.subtitle,
        preferredTrackId: ref.read(editorProvider).selectedTrackId,
      );
      if (targetTrack == null) {
        SnackBarHelper.showInfo(
          context,
          'Unlock the subtitle track before pasting captions.',
        );
        return;
      }
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
      keyframes: sourceClip.keyframes,
      freezeFrame: sourceClip.freezeFrame,
      stabilize: sourceClip.stabilize,
      denoise: sourceClip.denoise,
      chromaKeyEnabled: sourceClip.chromaKeyEnabled,
      chromaKeyColor: sourceClip.chromaKeyColor,
      chromaKeySimilarity: sourceClip.chromaKeySimilarity,
      timelineColor: sourceClip.timelineColor,
      notes: sourceClip.notes,
      autoDuck: sourceClip.autoDuck,
      duckAmount: sourceClip.duckAmount,
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

    final isContiguous =
        trackClips.length > 1 &&
        trackClips.indexed.skip(1).every((entry) {
          final previous = trackClips[entry.$1 - 1];
          return (entry.$2.startTime.inMilliseconds -
                      previous.endTime.inMilliseconds)
                  .abs() <=
              1;
        });
    if (isContiguous) {
      _reorderBaseStoryline(
        timeline: timeline,
        track: track,
        clip: clip,
        currentIndex: currentIndex,
        sortedClips: trackClips,
        cumulativeDx: delta.dx,
      );
      return;
    }

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
      if (subtitleTrack != null &&
          candidateTrack.id == subtitleTrack.id &&
          !candidateTrack.isLocked) {
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

  void _reorderBaseStoryline({
    required EditorTimeline timeline,
    required TimelineTrack track,
    required TimelineClip clip,
    required int currentIndex,
    required List<TimelineClip> sortedClips,
    required double cumulativeDx,
  }) {
    final deltaMs = (cumulativeDx / _pixelsPerSecond * 1000).round();
    final desiredCenterMs =
        clip.startTime.inMilliseconds +
        clip.duration.inMilliseconds / 2 +
        deltaMs;
    final others = sortedClips
        .where((candidate) => candidate.id != clip.id)
        .toList();
    final targetIndex = others
        .where(
          (candidate) =>
              candidate.startTime.inMilliseconds +
                  candidate.duration.inMilliseconds / 2 <
              desiredCenterMs,
        )
        .length
        .clamp(0, others.length)
        .toInt();

    if (targetIndex == currentIndex) {
      if (!identical(ref.read(editorProvider).timeline, timeline)) {
        _applyTimeline(timeline);
      }
      return;
    }

    final reordered = [...others]..insert(targetIndex, clip);
    final originalById = {
      for (final candidate in sortedClips) candidate.id: candidate,
    };
    final updatedById = <String, TimelineClip>{};
    var cursor = sortedClips.first.startTime;
    for (final candidate in reordered) {
      final updated = candidate.copyWith(
        startTime: cursor,
        endTime: cursor + candidate.duration,
      );
      updatedById[candidate.id] = updated;
      cursor = updated.endTime;
    }
    final shiftsByClipId = <String, Duration>{
      for (final entry in updatedById.entries)
        entry.key: entry.value.startTime - originalById[entry.key]!.startTime,
    };

    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.id == track.id) {
        return candidateTrack.copyWith(
          clips: reordered.map((item) => updatedById[item.id]!).toList(),
        );
      }
      if (candidateTrack.isLocked) return candidateTrack;
      final shifted = candidateTrack.clips.map((candidate) {
        final linkedId = candidate.linkedClipId;
        final shift = linkedId == null ? null : shiftsByClipId[linkedId];
        if (shift == null || shift == Duration.zero) return candidate;
        return candidate.copyWith(
          startTime: candidate.startTime + shift,
          endTime: candidate.endTime + shift,
        );
      }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
      return candidateTrack.copyWith(clips: shifted);
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

    final targetTrack = _targetTrackForDrag(timeline, track, clip, delta.dy);
    if (nextStartMs == clip.startTime.inMilliseconds &&
        targetTrack.id == track.id) {
      return;
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
      if (candidateTrack.isLocked) return candidateTrack;
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
    if (ref.read(editorProvider).selectedTrackId != targetTrack.id) {
      ref.read(editorProvider.notifier).selectTrack(targetTrack.id);
    }
    if (ref.read(editorProvider).selectedClipId != updatedClip.id) {
      ref.read(editorProvider.notifier).selectClip(updatedClip.id);
    }
  }

  bool _trackAcceptsClip(TimelineTrack track, TimelineClip clip) {
    return !track.isLocked && track.acceptsClip(clip);
  }

  bool _canMoveClipAcrossLanes(
    EditorTimeline timeline,
    TimelineTrack sourceTrack,
    TimelineClip clip,
  ) {
    if (sourceTrack.section == TimelineTrackSection.baseVideo) return false;
    return timeline.tracks.any(
      (track) =>
          track.id != sourceTrack.id &&
          track.section == sourceTrack.section &&
          _trackAcceptsClip(track, clip),
    );
  }

  TimelineTrack _targetTrackForDrag(
    EditorTimeline timeline,
    TimelineTrack sourceTrack,
    TimelineClip clip,
    double cumulativeDy,
  ) {
    if (sourceTrack.section == TimelineTrackSection.baseVideo ||
        cumulativeDy.abs() < 4) {
      return sourceTrack;
    }

    final layouts = _buildTrackLayouts(timeline);
    final sourceRow = layouts
        .where((row) => row.track?.id == sourceTrack.id)
        .firstOrNull;
    if (sourceRow == null) return sourceTrack;

    final targetY = sourceRow.laneTop + sourceRow.laneHeight / 2 + cumulativeDy;
    final candidates = layouts
        .where(
          (row) =>
              row.track != null &&
              row.track!.section == sourceTrack.section &&
              _trackAcceptsClip(row.track!, clip),
        )
        .toList();
    if (candidates.isEmpty) return sourceTrack;

    var nearest = candidates.first;
    var nearestDistance = double.infinity;
    for (final row in candidates) {
      final center = row.laneTop + row.laneHeight / 2;
      final distance = (center - targetY).abs();
      if (distance < nearestDistance) {
        nearest = row;
        nearestDistance = distance;
      }
    }
    return nearest.track!;
  }

  void _beginClipMove(TimelineClip clip, Offset pointerOrigin) {
    final timeline = ref.read(editorProvider).timeline;
    final selection = _selectedClipSelection(timeline, clip.id);
    if (selection == null) return;
    _clipMoveSession = _ClipMoveSession(
      timeline: timeline,
      track: selection.$1,
      clip: selection.$2,
      pointerOrigin: pointerOrigin,
    );
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

  void _moveClipById(String clipId, Offset pointerPosition) {
    final session = _clipMoveSession;
    if (session == null || session.clip.id != clipId) return;
    session.cumulativeDelta = pointerPosition - session.pointerOrigin;
    _moveClip(
      session.timeline,
      session.track,
      session.clip,
      session.cumulativeDelta,
    );
  }

  void _endClipMove() {
    _clipMoveSession = null;
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
    final sourceAvailableBeforeTimelineMs = math.max(
      0,
      clip.isReversed
          ? assetDurationMs -
                clip.sourceStartTime.inMilliseconds -
                clip.sourceDuration.inMilliseconds
          : clip.sourceStartTime.inMilliseconds,
    );
    final minStartFromSource = math.max(
      0,
      clip.startTime.inMilliseconds -
          (sourceAvailableBeforeTimelineMs / clip.playbackRate).floor(),
    );
    final minimumStart = math.max(
      previous?.endTime.inMilliseconds ?? 0,
      minStartFromSource,
    );
    final maximumStart =
        clip.endTime.inMilliseconds - _minimumEditableDurationMs(clip);
    if (minimumStart > maximumStart) return;
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
    final newSourceStartMs = clip.isReversed
        ? clip.sourceStartTime.inMilliseconds
        : clip.sourceStartTime.inMilliseconds + sourceDeltaMs;
    final newSourceDurationMs =
        clip.sourceDuration.inMilliseconds - sourceDeltaMs;
    if (newSourceStartMs < 0 ||
        newSourceDurationMs <= 0 ||
        newSourceStartMs + newSourceDurationMs > assetDurationMs) {
      return;
    }

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
      if (subtitleTrack != null &&
          candidateTrack.id == subtitleTrack.id &&
          !candidateTrack.isLocked) {
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
    final sourceAvailableAfterTimelineMs = math.max(
      0,
      clip.isReversed
          ? clip.sourceStartTime.inMilliseconds
          : assetDurationMs -
                clip.sourceStartTime.inMilliseconds -
                clip.sourceDuration.inMilliseconds,
    );
    final maxEndFromSource =
        clip.endTime.inMilliseconds +
        (sourceAvailableAfterTimelineMs / clip.playbackRate).floor();
    final minimumEnd =
        clip.startTime.inMilliseconds + _minimumEditableDurationMs(clip);
    final maximumEnd = math.min(
      next?.startTime.inMilliseconds ?? maxEndFromSource,
      maxEndFromSource,
    );
    if (maximumEnd < minimumEnd) return;
    final proposedEnd = (clip.endTime.inMilliseconds + deltaMs)
        .clamp(minimumEnd, maximumEnd)
        .toInt();
    final newEndMs = _snapEdgeMs(
      timeline,
      clip,
      proposedEnd,
    ).clamp(minimumEnd, maximumEnd).toInt();
    if (newEndMs == clip.endTime.inMilliseconds) return;

    final sourceDeltaMs =
        ((newEndMs - clip.endTime.inMilliseconds) * clip.playbackRate).round();
    final newSourceStartMs = clip.isReversed
        ? clip.sourceStartTime.inMilliseconds - sourceDeltaMs
        : clip.sourceStartTime.inMilliseconds;
    final newSourceDurationMs =
        clip.sourceDuration.inMilliseconds + sourceDeltaMs;
    if (newSourceStartMs < 0 ||
        newSourceDurationMs <= 0 ||
        newSourceStartMs + newSourceDurationMs > assetDurationMs) {
      return;
    }
    final updatedClip = clip.copyWith(
      endTime: Duration(milliseconds: newEndMs),
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
      if (subtitleTrack != null &&
          candidateTrack.id == subtitleTrack.id &&
          !candidateTrack.isLocked) {
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

  int _minimumEditableDurationMs(TimelineClip clip) {
    return math.min(
      _minClipDurationMs,
      math.max(1, clip.duration.inMilliseconds),
    );
  }

  void _trimNonBaseClipStart(
    EditorTimeline timeline,
    TimelineTrack track,
    TimelineClip clip,
    Offset delta,
  ) {
    if (track.isLocked) return;
    final deltaMs = (delta.dx / _pixelsPerSecond * 1000).round();
    final maximumStart =
        clip.endTime.inMilliseconds - _minimumEditableDurationMs(clip);
    final sourceBounded = _usesSourceBounds(clip);
    final assetDurationMs = _assetDurationMs(timeline, clip);
    final sourceAvailableBeforeTimelineMs = math.max(
      0,
      clip.isReversed
          ? assetDurationMs -
                clip.sourceStartTime.inMilliseconds -
                clip.sourceDuration.inMilliseconds
          : clip.sourceStartTime.inMilliseconds,
    );
    final minimumStart = sourceBounded
        ? math.max(
            0,
            clip.startTime.inMilliseconds -
                (sourceAvailableBeforeTimelineMs / clip.playbackRate).floor(),
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
          ? clip.isReversed
                ? clip.sourceStartTime
                : clip.sourceStartTime + Duration(milliseconds: sourceDeltaMs)
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
      if (candidateTrack.isLocked) return candidateTrack;
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
    final sourceAvailableAfterTimelineMs = math.max(
      0,
      clip.isReversed
          ? clip.sourceStartTime.inMilliseconds
          : assetDurationMs -
                clip.sourceStartTime.inMilliseconds -
                clip.sourceDuration.inMilliseconds,
    );
    final sourceMaximumEnd =
        clip.endTime.inMilliseconds +
        (sourceAvailableAfterTimelineMs / clip.playbackRate).floor();
    final maximumEnd = sourceBounded
        ? math.min(compositionEnd, sourceMaximumEnd)
        : compositionEnd;
    final minimumEnd =
        clip.startTime.inMilliseconds + _minimumEditableDurationMs(clip);
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
      sourceStartTime: sourceBounded && clip.isReversed
          ? clip.sourceStartTime - Duration(milliseconds: sourceDeltaMs)
          : clip.sourceStartTime,
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
      if (candidateTrack.isLocked) return candidateTrack;
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
    final timeline = ref.read(editorProvider).timeline;
    final selection = _selectedClipSelection(timeline, clip.id);
    if (selection == null) return;
    _clipTrimSession = _ClipTrimSession(
      timeline: timeline,
      track: selection.$1,
      clip: selection.$2,
    );
    ref.read(editorProvider.notifier).beginTimelineGestureEdit();
  }

  void _trimClipStartById(String clipId, Offset delta) {
    final session = _clipTrimSession;
    if (session == null || session.clip.id != clipId) return;
    if (session.edge != null && session.edge != _TrimEdge.start) return;
    session.edge = _TrimEdge.start;
    session.cumulativeDelta += delta;
    if (session.track.section == TimelineTrackSection.baseVideo) {
      _trimBaseClipStart(
        session.timeline,
        session.track,
        session.clip,
        session.cumulativeDelta,
      );
    } else {
      _trimNonBaseClipStart(
        session.timeline,
        session.track,
        session.clip,
        session.cumulativeDelta,
      );
    }
  }

  void _trimClipEndById(String clipId, Offset delta) {
    final session = _clipTrimSession;
    if (session == null || session.clip.id != clipId) return;
    if (session.edge != null && session.edge != _TrimEdge.end) return;
    session.edge = _TrimEdge.end;
    session.cumulativeDelta += delta;
    if (session.track.section == TimelineTrackSection.baseVideo) {
      _trimBaseClipEnd(
        session.timeline,
        session.track,
        session.clip,
        session.cumulativeDelta,
      );
    } else {
      _trimNonBaseClipEnd(
        session.timeline,
        session.track,
        session.clip,
        session.cumulativeDelta,
      );
    }
  }

  void _endClipTrim() {
    _clipTrimSession = null;
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
    if (clip.sourceDuration.inMilliseconds <= 1) return;
    final leftSourceDurationMs = (leftTimelineDurationMs * clip.playbackRate)
        .round()
        .clamp(1, clip.sourceDuration.inMilliseconds - 1)
        .toInt();
    final rightSourceDurationMs =
        clip.sourceDuration.inMilliseconds - leftSourceDurationMs;
    final firstSourceStart = clip.isReversed
        ? clip.sourceStartTime + Duration(milliseconds: rightSourceDurationMs)
        : clip.sourceStartTime;
    final secondSourceStart = clip.isReversed
        ? clip.sourceStartTime
        : clip.sourceStartTime + Duration(milliseconds: leftSourceDurationMs);
    final firstClip = clip.copyWith(
      endTime: splitPoint,
      sourceStartTime: firstSourceStart,
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
      sourceStartTime: secondSourceStart,
      sourceDuration: Duration(milliseconds: rightSourceDurationMs),
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
      keyframes: clip.keyframes,
      freezeFrame: clip.freezeFrame,
      stabilize: clip.stabilize,
      denoise: clip.denoise,
      chromaKeyEnabled: clip.chromaKeyEnabled,
      chromaKeyColor: clip.chromaKeyColor,
      chromaKeySimilarity: clip.chromaKeySimilarity,
      timelineColor: clip.timelineColor,
      notes: clip.notes,
      autoDuck: clip.autoDuck,
      duckAmount: clip.duckAmount,
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
      if (subtitleTrack != null &&
          track.id == subtitleTrack.id &&
          !track.isLocked) {
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
      if (track.isLocked) return track;
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
      keyframes: clip.keyframes,
      freezeFrame: clip.freezeFrame,
      stabilize: clip.stabilize,
      denoise: clip.denoise,
      chromaKeyEnabled: clip.chromaKeyEnabled,
      chromaKeyColor: clip.chromaKeyColor,
      chromaKeySimilarity: clip.chromaKeySimilarity,
      timelineColor: clip.timelineColor,
      notes: clip.notes,
      autoDuck: clip.autoDuck,
      duckAmount: clip.duckAmount,
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
    if (clip.sourceDuration.inMilliseconds <= 1) return;
    final leftSourceDurationMs = (leftTimelineDurationMs * clip.playbackRate)
        .round()
        .clamp(1, clip.sourceDuration.inMilliseconds - 1)
        .toInt();
    final rightSourceDurationMs =
        clip.sourceDuration.inMilliseconds - leftSourceDurationMs;
    final firstSourceStart = clip.isReversed
        ? clip.sourceStartTime + Duration(milliseconds: rightSourceDurationMs)
        : clip.sourceStartTime;
    final secondSourceStart = clip.isReversed
        ? clip.sourceStartTime
        : clip.sourceStartTime + Duration(milliseconds: leftSourceDurationMs);
    final firstClip = clip.copyWith(
      endTime: splitPoint,
      sourceStartTime: firstSourceStart,
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
      sourceStartTime: secondSourceStart,
      sourceDuration: Duration(milliseconds: rightSourceDurationMs),
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
      keyframes: clip.keyframes,
      freezeFrame: clip.freezeFrame,
      stabilize: clip.stabilize,
      denoise: clip.denoise,
      chromaKeyEnabled: clip.chromaKeyEnabled,
      chromaKeyColor: clip.chromaKeyColor,
      chromaKeySimilarity: clip.chromaKeySimilarity,
      timelineColor: clip.timelineColor,
      notes: clip.notes,
      autoDuck: clip.autoDuck,
      duckAmount: clip.duckAmount,
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

  void _scrollToPlayhead(Duration position) {
    if (!_horizontalScrollController.hasClients) return;
    final viewportWidth =
        _horizontalScrollController.position.viewportDimension;
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

  void _updateWorkspace(
    TimelineWorkspaceSettings Function(TimelineWorkspaceSettings current)
    mapper,
  ) {
    ref.read(editorProvider.notifier).setWorkspaceSettings(mapper);
  }

  void _setWorkAreaIn(Duration position) {
    final timeline = ref.read(editorProvider).timeline;
    final end = timeline.workspaceSettings.workAreaEnd;
    _updateWorkspace(
      (settings) => settings.copyWith(
        workAreaStart: end != null && position >= end ? null : position,
        clearWorkAreaStart: end != null && position >= end,
      ),
    );
  }

  void _setWorkAreaOut(Duration position) {
    final timeline = ref.read(editorProvider).timeline;
    final start = timeline.workspaceSettings.workAreaStart;
    _updateWorkspace(
      (settings) => settings.copyWith(
        workAreaEnd: start != null && position <= start ? null : position,
        clearWorkAreaEnd: start != null && position <= start,
      ),
    );
  }

  void _clearWorkArea() {
    _updateWorkspace(
      (settings) =>
          settings.copyWith(clearWorkAreaStart: true, clearWorkAreaEnd: true),
    );
  }

  void _nudgePlayhead(int direction) {
    final workspace = ref.read(editorProvider).timeline.workspaceSettings;
    final frameMs = math.max(1, (1000 / workspace.frameRate).round());
    final playback = ref.read(playbackProvider);
    ref
        .read(playbackProvider.notifier)
        .requestSeek(
          playback.position + Duration(milliseconds: direction * frameMs),
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
    final workspace = timeline.workspaceSettings;
    final fallbackDuration = timeline.tracks
        .expand((track) => track.clips)
        .fold<Duration>(
          Duration.zero,
          (current, clip) => clip.endTime > current ? clip.endTime : current,
        );
    final totalDuration = playbackDuration > fallbackDuration
        ? playbackDuration
        : fallbackDuration;
    final selectedSelection = _selectedClipSelection(
      timeline,
      editorState.selectedClipId,
    );
    final selectedTrack = selectedSelection?.$1;
    final selectedClip = selectedSelection?.$2;
    final rawSelectedSubtitle = subtitleState.selectedEntry;
    final selectedSubtitle = selectedClip == null
        ? rawSelectedSubtitle
        : selectedClip.type == TimelineTrackType.subtitle &&
              rawSelectedSubtitle?.id == selectedClip.id
        ? rawSelectedSubtitle
        : null;
    final selectedSubtitleTrack = selectedSubtitle == null
        ? null
        : _selectedClipSelection(timeline, selectedSubtitle.id)?.$1;
    final canMutateSelectedSubtitle =
        selectedSubtitle != null &&
        selectedSubtitleTrack != null &&
        !selectedSubtitleTrack.isLocked;
    final canMutateSelectedClip =
        selectedClip != null &&
        selectedTrack != null &&
        !selectedTrack.isLocked;
    final canCopySelection =
        selectedSubtitle != null ||
        (selectedClip != null &&
            selectedTrack?.section != TimelineTrackSection.baseVideo);
    final canDeleteSelection =
        canMutateSelectedSubtitle || canMutateSelectedClip;
    final canSplitSelection =
        canMutateSelectedSubtitle || canMutateSelectedClip;
    final editorUndoSequence = editorNotifier.latestUndoSequence ?? -1;
    final subtitleUndoSequence = subtitleNotifier.latestUndoSequence ?? -1;
    final editorRedoSequence = editorNotifier.latestRedoSequence ?? -1;
    final subtitleRedoSequence = subtitleNotifier.latestRedoSequence ?? -1;
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
                    onPressed:
                        editorNotifier.canUndo || subtitleNotifier.canUndo
                        ? () {
                            if (editorUndoSequence >= subtitleUndoSequence &&
                                editorNotifier.canUndo) {
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
                    onPressed:
                        editorNotifier.canRedo || subtitleNotifier.canRedo
                        ? () {
                            if (editorRedoSequence >= subtitleRedoSequence &&
                                editorNotifier.canRedo) {
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
                    onPressed: canMutateSelectedSubtitle
                        ? () => subtitleNotifier.duplicateEntry(
                            selectedSubtitle.id,
                          )
                        : canMutateSelectedClip
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
                            if (canMutateSelectedSubtitle) {
                              subtitleNotifier.deleteEntry(selectedSubtitle.id);
                              return;
                            }
                            if (canMutateSelectedClip) {
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
                            if (canMutateSelectedSubtitle) {
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
                    onPressed: () =>
                        _scrollToPlayhead(ref.read(playbackProvider).position),
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
                    icon: Icons.keyboard_arrow_left_rounded,
                    tooltip: 'Previous frame',
                    onPressed: () => _nudgePlayhead(-1),
                  ),
                  _buildToolbarButton(
                    icon: Icons.keyboard_arrow_right_rounded,
                    tooltip: 'Next frame',
                    onPressed: () => _nudgePlayhead(1),
                  ),
                  _buildToolbarButton(
                    icon: Icons.repeat_rounded,
                    tooltip: workspace.loopPlayback
                        ? 'Turn loop playback off'
                        : 'Loop work area',
                    onPressed: () => _updateWorkspace(
                      (settings) => settings.copyWith(
                        loopPlayback: !settings.loopPlayback,
                      ),
                    ),
                    isActive: workspace.loopPlayback,
                  ),
                  _buildToolbarButton(
                    icon: Icons.first_page_rounded,
                    tooltip: 'Set work area in',
                    onPressed: () =>
                        _setWorkAreaIn(ref.read(playbackProvider).position),
                    isActive: workspace.normalizedWorkAreaStart != null,
                  ),
                  _buildToolbarButton(
                    icon: Icons.last_page_rounded,
                    tooltip: 'Set work area out',
                    onPressed: () =>
                        _setWorkAreaOut(ref.read(playbackProvider).position),
                    isActive: workspace.normalizedWorkAreaEnd != null,
                  ),
                  _buildToolbarButton(
                    icon: Icons.clear_all_rounded,
                    tooltip: 'Clear work area',
                    onPressed: workspace.normalizedWorkAreaStart == null
                        ? null
                        : _clearWorkArea,
                  ),
                  _buildToolbarButton(
                    icon: Icons.graphic_eq_rounded,
                    tooltip: workspace.showWaveforms
                        ? 'Hide audio waveforms'
                        : 'Show audio waveforms',
                    onPressed: () => _updateWorkspace(
                      (settings) => settings.copyWith(
                        showWaveforms: !settings.showWaveforms,
                      ),
                    ),
                    isActive: workspace.showWaveforms,
                  ),
                  _buildToolbarButton(
                    icon: Icons.photo_library_outlined,
                    tooltip: workspace.showThumbnails
                        ? 'Hide clip thumbnails'
                        : 'Show clip thumbnails',
                    onPressed: () => _updateWorkspace(
                      (settings) => settings.copyWith(
                        showThumbnails: !settings.showThumbnails,
                      ),
                    ),
                    isActive: workspace.showThumbnails,
                  ),
                  _buildToolbarButton(
                    icon: Icons.key_rounded,
                    tooltip: workspace.showKeyframes
                        ? 'Hide keyframes'
                        : 'Show keyframes',
                    onPressed: () => _updateWorkspace(
                      (settings) => settings.copyWith(
                        showKeyframes: !settings.showKeyframes,
                      ),
                    ),
                    isActive: workspace.showKeyframes,
                  ),
                  _buildToolbarButton(
                    icon: Icons.follow_the_signs_rounded,
                    tooltip: workspace.autoFollowPlayhead
                        ? 'Stop following playhead'
                        : 'Follow playhead while playing',
                    onPressed: () => _updateWorkspace(
                      (settings) => settings.copyWith(
                        autoFollowPlayhead: !settings.autoFollowPlayhead,
                      ),
                    ),
                    isActive: workspace.autoFollowPlayhead,
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
                    onPressed: () => _fitTimeline(totalDuration),
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
                final resolvedContentHeight = math.max(
                  contentHeight,
                  constraints.maxHeight,
                );
                return Scrollbar(
                  controller: _verticalScrollController,
                  thumbVisibility: true,
                  interactive: true,
                  thickness: 4,
                  radius: const Radius.circular(999),
                  child: SingleChildScrollView(
                    key: const ValueKey('timeline_vertical_scroll'),
                    controller: _verticalScrollController,
                    physics: const ClampingScrollPhysics(),
                    child: SizedBox(
                      width: constraints.maxWidth,
                      height: resolvedContentHeight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: _labelColumnWidth,
                            height: resolvedContentHeight,
                            child: _TimelineLabels(
                              rowLayouts: rowLayouts,
                              rulerHeight: _rulerHeight,
                              onAddTrack: _showAddTrackChooser,
                              onTrackTap: (track) {
                                editorNotifier.selectTrack(track.id);
                                editorNotifier.selectClip(null);
                                subtitleNotifier.selectEntry(null);
                              },
                              onShowTrackActions: _showTrackActions,
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              controller: _horizontalScrollController,
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: totalWidth,
                                height: resolvedContentHeight,
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
                                              frameRate: workspace.frameRate,
                                              showTimecode:
                                                  workspace.showTimecode,
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (workspace.normalizedWorkAreaStart !=
                                              null &&
                                          workspace.normalizedWorkAreaEnd !=
                                              null)
                                        Positioned(
                                          left:
                                              workspace
                                                  .normalizedWorkAreaStart!
                                                  .inMilliseconds /
                                              1000 *
                                              _pixelsPerSecond,
                                          top: 0,
                                          bottom: 0,
                                          width:
                                              (workspace
                                                      .normalizedWorkAreaEnd!
                                                      .inMilliseconds -
                                                  workspace
                                                      .normalizedWorkAreaStart!
                                                      .inMilliseconds) /
                                              1000 *
                                              _pixelsPerSecond,
                                          child: IgnorePointer(
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                color: kAccent.withValues(
                                                  alpha: 0.045,
                                                ),
                                                border: Border.symmetric(
                                                  vertical: BorderSide(
                                                    color: kAccent.withValues(
                                                      alpha: 0.35,
                                                    ),
                                                  ),
                                                ),
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
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                color: kBackground.withValues(
                                                  alpha: 0.18,
                                                ),
                                                border: Border(
                                                  bottom: BorderSide(
                                                    color: kBorder.withValues(
                                                      alpha: 0.55,
                                                    ),
                                                  ),
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
                                              selectedClipIds:
                                                  editorState.selectedClipIds,
                                              selectedSubtitleId:
                                                  subtitleState.selectedEntryId,
                                              workspaceSettings:
                                                  timeline.workspaceSettings,
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
                                              onClipMoveStart: _beginClipMove,
                                              canClipMoveVertically: (clip) =>
                                                  _canMoveClipAcrossLanes(
                                                    timeline,
                                                    row.track!,
                                                    clip,
                                                  ),
                                              onClipMove: (clip, position) =>
                                                  _moveClipById(
                                                    clip.id,
                                                    position,
                                                  ),
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
                                                        .withValues(
                                                          alpha: 0.48,
                                                        ),
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
                                                        playbackProvider
                                                            .notifier,
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
                                                        ? Icons
                                                              .music_note_rounded
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

IconData _trackRailIcon(TimelineTrack track) {
  if (track.section == TimelineTrackSection.baseVideo) {
    return Icons.movie_creation_outlined;
  }
  if (track.section == TimelineTrackSection.overlay &&
      track.type == TimelineTrackType.video) {
    return Icons.layers_outlined;
  }
  return _trackIcon(track.type);
}

class _TimelineLabels extends StatelessWidget {
  final List<_TrackRowLayout> rowLayouts;
  final double rulerHeight;
  final VoidCallback onAddTrack;
  final ValueChanged<TimelineTrack> onTrackTap;
  final void Function(TimelineTrack track, Offset position) onShowTrackActions;

  const _TimelineLabels({
    required this.rowLayouts,
    required this.rulerHeight,
    required this.onAddTrack,
    required this.onTrackTap,
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
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: rulerHeight,
            child: Center(
              child: Tooltip(
                message: 'Add track',
                child: Semantics(
                  button: true,
                  label: 'Add a timeline track',
                  child: IconButton(
                    key: const ValueKey('timeline_add_track_button'),
                    onPressed: onAddTrack,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 26,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: kAccent.withValues(alpha: 0.12),
                      side: BorderSide(color: kAccent.withValues(alpha: 0.38)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(
                      Icons.add_rounded,
                      color: kAccent,
                      size: 17,
                    ),
                  ),
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
                height: row.laneHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: kBackground.withValues(alpha: 0.24),
                    border: Border(
                      bottom: BorderSide(
                        color: kBorder.withValues(alpha: 0.55),
                      ),
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
                child: _CompactTrackLabel(
                  track: row.track!,
                  onTap: () => onTrackTap(row.track!),
                  onShowActions: (position) =>
                      onShowTrackActions(row.track!, position),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _CompactTrackLabel extends StatefulWidget {
  final TimelineTrack track;
  final VoidCallback onTap;
  final ValueChanged<Offset> onShowActions;

  const _CompactTrackLabel({
    required this.track,
    required this.onTap,
    required this.onShowActions,
  });

  @override
  State<_CompactTrackLabel> createState() => _CompactTrackLabelState();
}

class _CompactTrackLabelState extends State<_CompactTrackLabel> {
  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final status = [
      if (track.isLocked) 'locked',
      if (track.isMuted) 'muted',
      if (track.isHidden) 'hidden',
    ];
    final statusLabel = status.isEmpty ? '' : ', ${status.join(', ')}';
    return Tooltip(
      message: '${track.name}$statusLabel\nLong-press for track controls',
      child: Semantics(
        button: true,
        label: '${track.name} track$statusLabel',
        hint: 'Tap to select. Long-press for track controls',
        child: GestureDetector(
          key: ValueKey('timeline_track_${track.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onLongPressStart: (details) =>
              widget.onShowActions(details.globalPosition),
          child: Opacity(
            opacity: track.isHidden ? 0.48 : 1,
            child: Container(
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: kBorder, width: 0.6)),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 30,
                    height: 28,
                    decoration: BoxDecoration(
                      color: kSurfaceElevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: track.isLocked
                            ? kWarning.withValues(alpha: 0.55)
                            : kBorder,
                      ),
                    ),
                    child: Icon(
                      _trackRailIcon(track),
                      size: 17,
                      color: track.isLocked ? kWarning : kTextSecondary,
                    ),
                  ),
                  if (track.isMuted)
                    const Positioned(
                      right: 3,
                      bottom: 2,
                      child: Icon(
                        Icons.volume_off_rounded,
                        size: 10,
                        color: kWarning,
                      ),
                    ),
                  if (track.isLocked)
                    const Positioned(
                      right: 3,
                      top: 2,
                      child: Icon(Icons.lock_rounded, size: 9, color: kWarning),
                    ),
                ],
              ),
            ),
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
  final Set<String> selectedClipIds;
  final String? selectedSubtitleId;
  final TimelineWorkspaceSettings workspaceSettings;
  final VoidCallback onTrackTap;
  final ValueChanged<Offset> onShowTrackActions;
  final ValueChanged<TimelineClip> onClipTap;
  final ValueChanged<TimelineClip> onClipLongPress;
  final ValueChanged<TimelineClip> onTransitionTap;
  final bool Function(TimelineClip clip) canClipMoveVertically;
  final void Function(TimelineClip clip, Offset pointerOrigin) onClipMoveStart;
  final void Function(TimelineClip clip, Offset pointerPosition) onClipMove;
  final ValueChanged<TimelineClip> onClipMoveEnd;
  final ValueChanged<TimelineClip> onClipTrimGestureStart;
  final ValueChanged<TimelineClip> onClipTrimGestureEnd;
  final void Function(TimelineClip clip, Offset delta) onClipTrimStart;
  final void Function(TimelineClip clip, Offset delta) onClipTrimEnd;

  const _TimelineLane({
    required this.track,
    required this.pixelsPerSecond,
    required this.selectedClipId,
    required this.selectedClipIds,
    required this.selectedSubtitleId,
    required this.workspaceSettings,
    required this.onTrackTap,
    required this.onShowTrackActions,
    required this.onClipTap,
    required this.onClipLongPress,
    required this.onTransitionTap,
    required this.canClipMoveVertically,
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
    final isSelected =
        selectedClipId == clip.id || selectedSubtitleId == clip.id;
    final isMultiSelected = selectedClipIds.contains(clip.id);
    return Positioned(
      left: startX - visibleInset,
      top: 3,
      width: hitWidth,
      bottom: 3,
      child: _TimelineClipBlock(
        key: ValueKey('timeline_clip_${clip.id}'),
        clip: clip,
        visualWidth: visualWidth,
        isSelected: isSelected || isMultiSelected,
        showWaveform: workspaceSettings.showWaveforms,
        showThumbnail: workspaceSettings.showThumbnails,
        showTimecode: workspaceSettings.showTimecode,
        showKeyframes: workspaceSettings.showKeyframes,
        showClipLabel: workspaceSettings.showClipLabels,
        showTrimHandles: isSelected && !track.isCollapsed,
        isLocked: track.isLocked,
        canMove:
            !track.isLocked &&
            (track.section != TimelineTrackSection.baseVideo ||
                track.clips.length > 1),
        canMoveVertically: canClipMoveVertically(clip),
        onMoveStart: (position) => onClipMoveStart(clip, position),
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

/// Claims pointers that start on a movable clip before either surrounding
/// scroll view can reinterpret the gesture. Empty lane space remains the
/// scroll surface, while a clip can move freely in both axes.
class _ClipMoveSurface extends StatefulWidget {
  final bool canMove;
  final bool canMoveVertically;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<Offset> onMoveStart;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;

  const _ClipMoveSurface({
    required this.canMove,
    required this.canMoveVertically,
    required this.onTap,
    required this.onLongPress,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
  });

  @override
  State<_ClipMoveSurface> createState() => _ClipMoveSurfaceState();
}

class _ClipMoveSurfaceState extends State<_ClipMoveSurface> {
  Offset? _pointerOrigin;
  DateTime? _pointerDownAt;
  bool _didMove = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.canMove) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
      );
    }
    if (!widget.canMoveVertically) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onHorizontalDragStart: (details) =>
            widget.onMoveStart(details.globalPosition),
        onHorizontalDragUpdate: (details) =>
            widget.onMoveUpdate(details.globalPosition),
        onHorizontalDragEnd: (_) => widget.onMoveEnd(),
        onHorizontalDragCancel: widget.onMoveEnd,
      );
    }
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              EagerGestureRecognizer.new,
              (_) {},
            ),
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          _pointerOrigin = event.position;
          _pointerDownAt = DateTime.now();
          _didMove = false;
          widget.onMoveStart(event.position);
        },
        onPointerMove: (event) {
          final origin = _pointerOrigin;
          if (origin == null) return;
          if ((event.position - origin).distanceSquared >= 9) {
            _didMove = true;
          }
          widget.onMoveUpdate(event.position);
        },
        onPointerUp: (_) {
          final heldFor = DateTime.now().difference(
            _pointerDownAt ?? DateTime.now(),
          );
          widget.onMoveEnd();
          if (!_didMove) {
            if (heldFor >= const Duration(milliseconds: 500)) {
              widget.onLongPress();
            } else {
              widget.onTap();
            }
          }
          _resetPointer();
        },
        onPointerCancel: (_) {
          widget.onMoveEnd();
          _resetPointer();
        },
        child: const SizedBox.expand(),
      ),
    );
  }

  void _resetPointer() {
    _pointerOrigin = null;
    _pointerDownAt = null;
    _didMove = false;
  }
}

class _TimelineClipBlock extends StatelessWidget {
  final TimelineClip clip;
  final double visualWidth;
  final bool isSelected;
  final bool showWaveform;
  final bool showThumbnail;
  final bool showTimecode;
  final bool showKeyframes;
  final bool showClipLabel;
  final bool showTrimHandles;
  final bool isLocked;
  final bool canMove;
  final bool canMoveVertically;
  final ValueChanged<Offset> onMoveStart;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final VoidCallback onTrimGestureStart;
  final VoidCallback onTrimGestureEnd;
  final ValueChanged<Offset> onTrimStartUpdate;
  final ValueChanged<Offset> onTrimEndUpdate;

  const _TimelineClipBlock({
    super.key,
    required this.clip,
    required this.visualWidth,
    required this.isSelected,
    required this.showWaveform,
    required this.showThumbnail,
    required this.showTimecode,
    required this.showKeyframes,
    required this.showClipLabel,
    required this.showTrimHandles,
    required this.isLocked,
    required this.canMove,
    required this.canMoveVertically,
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
    final badges = _visualBadges(clip);
    const handleHitWidth = 12.0;

    return Semantics(
      button: true,
      selected: isSelected,
      label: _clipSemanticsLabel(clip, badges),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final resolvedVisualWidth = visualWidth
              .clamp(1.0, constraints.maxWidth)
              .toDouble();
          final visibleLeft = (constraints.maxWidth - resolvedVisualWidth) / 2;
          final showUsableTrimHandles =
              showTrimHandles &&
              !isLocked &&
              resolvedVisualWidth >= handleHitWidth * 2 + 4;
          final moveHitLeft = showUsableTrimHandles ? visibleLeft : 0.0;
          final moveHitWidth = showUsableTrimHandles
              ? resolvedVisualWidth
              : constraints.maxWidth;
          final showMeta =
              constraints.maxHeight >= 34 && resolvedVisualWidth >= 82;
          final visibleBadgeCount = resolvedVisualWidth < 42
              ? 0
              : math
                    .min(
                      badges.length,
                      ((resolvedVisualWidth - 10) / 13).floor(),
                    )
                    .clamp(0, badges.length);
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
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: colors.$1,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: isSelected ? kAccent : colors.$2,
                        width: isSelected ? 1.5 : 1,
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (showThumbnail && clip.type.isVisualMedia)
                          IgnorePointer(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Icon(
                                Icons.photo_size_select_actual_outlined,
                                color: colors.$2.withValues(alpha: 0.28),
                                size: math.min(28, resolvedVisualWidth * 0.45),
                              ),
                            ),
                          ),
                        if (showWaveform &&
                            (clip.type == TimelineTrackType.audio ||
                                clip.canCarryAudio))
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _WaveformPainter(
                                seed: clip.id.hashCode,
                                color: colors.$2.withValues(alpha: 0.35),
                              ),
                            ),
                          ),
                        IgnorePointer(
                          child: CustomPaint(
                            key: ValueKey('timeline_clip_envelope_${clip.id}'),
                            painter: _ClipEnvelopePainter(
                              clip: clip,
                              accentColor: colors.$2,
                            ),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: showMeta ? 3 : 2,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    right: visibleBadgeCount * 13.0,
                                  ),
                                  child: Text(
                                    showClipLabel &&
                                            clip.text?.trim().isNotEmpty == true
                                        ? clip.text!
                                        : showClipLabel
                                        ? clip.label
                                        : '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: kTextPrimary,
                                      fontSize: showMeta ? 10.5 : 9.5,
                                      fontWeight: FontWeight.w600,
                                      height: 1,
                                      shadows: const [
                                        Shadow(
                                          color: Colors.black54,
                                          blurRadius: 2,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (showMeta) const SizedBox(height: 2),
                              if (showMeta && showTimecode)
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
                                      shadows: [
                                        Shadow(
                                          color: Colors.black54,
                                          blurRadius: 2,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (showKeyframes && clip.hasKeyframes)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _KeyframePainter(
                                  keyframes: clip.keyframes,
                                  duration: clip.duration,
                                  color: kWarning,
                                ),
                              ),
                            ),
                          ),
                        if (visibleBadgeCount > 0)
                          Positioned(
                            right: 3,
                            top: 3,
                            child: IgnorePointer(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.42),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (final badge in badges.take(
                                      visibleBadgeCount,
                                    ))
                                      Icon(badge.$1, size: 10, color: badge.$3),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: moveHitLeft,
                  top: 0,
                  bottom: 0,
                  width: moveHitWidth,
                  child: _ClipMoveSurface(
                    canMove: canMove,
                    canMoveVertically: canMoveVertically,
                    onTap: onTap,
                    onLongPress: onLongPress,
                    onMoveStart: onMoveStart,
                    onMoveUpdate: onMoveUpdate,
                    onMoveEnd: onMoveEnd,
                  ),
                ),
                if (showUsableTrimHandles)
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
                if (showUsableTrimHandles)
                  Positioned(
                    left:
                        visibleLeft + resolvedVisualWidth - handleHitWidth / 2,
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
      ),
    );
  }

  List<(IconData, String, Color)> _visualBadges(TimelineClip clip) {
    return [
      if (clip.effectKind == TimelineEffectKind.blur)
        (Icons.blur_on_rounded, 'Blur effect', const Color(0xFFD8B4FE)),
      if (clip.effectKind == TimelineEffectKind.filter)
        (Icons.tonality_rounded, 'Filter effect', const Color(0xFFD8B4FE)),
      if (!clip.isEffect && clip.blur.isEnabled)
        (Icons.blur_on_rounded, 'Blur adjustment', const Color(0xFF93C5FD)),
      if (!clip.isEffect && !clip.colorAdjustments.isNeutral)
        (Icons.tonality_rounded, 'Color adjustment', const Color(0xFF93C5FD)),
      if (!clip.crop.isIdentity)
        (Icons.crop_rounded, 'Cropped', const Color(0xFF93C5FD)),
      if (clip.hasRenderableTransformAdjustment)
        (Icons.open_with_rounded, 'Transformed', const Color(0xFF93C5FD)),
      if (clip.supportsClipAnimation &&
          (clip.introTransition.type != TransitionType.none ||
              clip.outroTransition.type != TransitionType.none))
        (
          Icons.auto_awesome_motion_rounded,
          'Animated',
          const Color(0xFFF9A8D4),
        ),
      if (clip.audioMix.fadeInMs > 0 || clip.audioMix.fadeOutMs > 0)
        (Icons.show_chart_rounded, 'Audio fade', const Color(0xFF86EFAC)),
      if (clip.canCarryAudio &&
          ((clip.audioMix.volume - 1).abs() > 0.0001 ||
              clip.audioMix.pan.abs() > 0.0001 ||
              clip.audioMix.normalize))
        (Icons.tune_rounded, 'Audio mix', const Color(0xFF86EFAC)),
      if (clip.audioMix.muted)
        (Icons.volume_off_rounded, 'Muted', const Color(0xFFFCA5A5)),
      if (!clip.enabled)
        (Icons.visibility_off_rounded, 'Disabled', const Color(0xFFFCA5A5)),
      if (clip.isReversed)
        (Icons.replay_rounded, 'Reversed', const Color(0xFFFDE68A)),
      if ((clip.playbackRate - 1).abs() > 0.001)
        (Icons.speed_rounded, 'Speed changed', const Color(0xFFFDE68A)),
      if (clip.hasKeyframes)
        (Icons.key_rounded, 'Keyframed', const Color(0xFFFFD166)),
      if (clip.freezeFrame)
        (
          Icons.pause_circle_outline_rounded,
          'Freeze frame',
          const Color(0xFFFFD166),
        ),
      if (clip.stabilize)
        (Icons.vibration_rounded, 'Stabilized', const Color(0xFF67E8F9)),
      if (clip.denoise)
        (Icons.noise_aware_rounded, 'Noise reduced', const Color(0xFF67E8F9)),
      if (clip.chromaKeyEnabled)
        (Icons.colorize_rounded, 'Chroma key', const Color(0xFF86EFAC)),
      if (clip.autoDuck)
        (
          Icons.record_voice_over_rounded,
          'Auto ducking',
          const Color(0xFF86EFAC),
        ),
      if (clip.notes?.trim().isNotEmpty == true)
        (Icons.sticky_note_2_outlined, 'Has notes', const Color(0xFFF9A8D4)),
    ];
  }

  String _clipSemanticsLabel(
    TimelineClip clip,
    List<(IconData, String, Color)> badges,
  ) {
    final details = badges.map((badge) => badge.$2).join(', ');
    final base =
        '${clip.label}, ${clip.type.name} clip, '
        '${SubtitleEntry.formatDisplayTime(clip.startTime)}, '
        '${clip.duration.inMilliseconds} milliseconds';
    return details.isEmpty ? base : '$base, $details';
  }

  (Color, Color) _clipColors(TimelineClip clip) {
    final custom = clip.timelineColor;
    if (custom.a > 0.01) {
      return (custom.withValues(alpha: 0.22), custom.withValues(alpha: 0.78));
    }
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

class _ClipEnvelopePainter extends CustomPainter {
  final TimelineClip clip;
  final Color accentColor;

  const _ClipEnvelopePainter({required this.clip, required this.accentColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 1 || size.height <= 1) return;
    if (clip.isEffect) _paintEffectTexture(canvas, size);
    _paintTransitionRamps(canvas, size);
    _paintAudioEnvelope(canvas, size);
  }

  void _paintEffectTexture(Canvas canvas, Size size) {
    final stripePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.13)
      ..strokeWidth = 1;
    const spacing = 9.0;
    for (var x = -size.height; x < size.width; x += spacing) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        stripePaint,
      );
    }
  }

  void _paintTransitionRamps(Canvas canvas, Size size) {
    if (!clip.supportsClipAnimation) return;
    final durationMs = math.max(1, clip.duration.inMilliseconds);
    final introEnabled =
        clip.introTransition.type != TransitionType.none &&
        clip.introTransition.type != TransitionType.cut &&
        clip.effectiveIntroTransitionMs > 0;
    final outroEnabled =
        clip.outroTransition.type != TransitionType.none &&
        clip.outroTransition.type != TransitionType.cut &&
        clip.effectiveOutroTransitionMs > 0;
    if (!introEnabled && !outroEnabled) return;

    final fillPaint = Paint()
      ..color = accentColor.withValues(alpha: 0.20)
      ..style = PaintingStyle.fill;
    final linePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35;
    const highY = 2.5;
    final lowY = size.height - 2.5;

    if (introEnabled) {
      final x = (clip.effectiveIntroTransitionMs / durationMs * size.width)
          .clamp(1.0, size.width)
          .toDouble();
      final fill = Path()
        ..moveTo(0, lowY)
        ..lineTo(x, highY)
        ..lineTo(x, lowY)
        ..close();
      final line = Path()
        ..moveTo(0, lowY)
        ..lineTo(x, highY);
      canvas
        ..drawPath(fill, fillPaint)
        ..drawPath(line, linePaint);
    }

    if (outroEnabled) {
      final width = (clip.effectiveOutroTransitionMs / durationMs * size.width)
          .clamp(1.0, size.width)
          .toDouble();
      final x = size.width - width;
      final fill = Path()
        ..moveTo(x, highY)
        ..lineTo(size.width, lowY)
        ..lineTo(x, lowY)
        ..close();
      final line = Path()
        ..moveTo(x, highY)
        ..lineTo(size.width, lowY);
      canvas
        ..drawPath(fill, fillPaint)
        ..drawPath(line, linePaint);
    }
  }

  void _paintAudioEnvelope(Canvas canvas, Size size) {
    if (!clip.canCarryAudio) return;
    final fadeInMs = clip.effectiveAudioFadeInMs;
    final fadeOutMs = clip.effectiveAudioFadeOutMs;
    if (fadeInMs <= 0 && fadeOutMs <= 0) return;

    final durationMs = math.max(1, clip.duration.inMilliseconds);
    final fadeInX = fadeInMs / durationMs * size.width;
    final fadeOutX = size.width - fadeOutMs / durationMs * size.width;
    final highY = math.max(3.0, size.height * 0.56);
    final lowY = size.height - 3;
    final path = Path()
      ..moveTo(0, fadeInMs > 0 ? lowY : highY)
      ..lineTo(fadeInX, highY)
      ..lineTo(fadeOutX, highY)
      ..lineTo(size.width, fadeOutMs > 0 ? lowY : highY);
    final fill = Path.from(path)
      ..lineTo(size.width, lowY)
      ..lineTo(0, lowY)
      ..close();
    canvas
      ..drawPath(
        fill,
        Paint()
          ..color = kSuccess.withValues(alpha: 0.11)
          ..style = PaintingStyle.fill,
      )
      ..drawPath(
        path,
        Paint()
          ..color = kSuccess.withValues(alpha: 0.88)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25,
      );
  }

  @override
  bool shouldRepaint(covariant _ClipEnvelopePainter oldDelegate) {
    return oldDelegate.clip != clip || oldDelegate.accentColor != accentColor;
  }
}

class _WaveformPainter extends CustomPainter {
  final int seed;
  final Color color;

  const _WaveformPainter({required this.seed, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 4 || size.height <= 4) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    var value = seed.abs() + 17;
    final step = math.max(3.0, size.width / 28);
    for (var x = 1.0; x < size.width - 1; x += step) {
      value = (value * 1103515245 + 12345) & 0x7fffffff;
      final amplitude = 0.18 + (value % 78) / 100;
      final center = size.height * 0.68;
      final half = size.height * 0.28 * amplitude;
      canvas.drawLine(
        Offset(x, center - half),
        Offset(x, center + half),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.seed != seed || oldDelegate.color != color;
  }
}

class _KeyframePainter extends CustomPainter {
  final List<TimelineKeyframe> keyframes;
  final Duration duration;
  final Color color;

  const _KeyframePainter({
    required this.keyframes,
    required this.duration,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 4 || duration.inMilliseconds <= 0) return;
    final paint = Paint()..color = color;
    final seen = <int>{};
    for (final keyframe in keyframes) {
      final x =
          (keyframe.time.inMilliseconds / duration.inMilliseconds * size.width)
              .clamp(2.0, size.width - 2)
              .toDouble();
      final bucket = x.round();
      if (!seen.add(bucket)) continue;
      final path = Path()
        ..moveTo(x, 3)
        ..lineTo(x + 3.5, size.height / 2)
        ..lineTo(x, size.height - 3)
        ..lineTo(x - 3.5, size.height / 2)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _KeyframePainter oldDelegate) {
    return oldDelegate.keyframes != keyframes ||
        oldDelegate.duration != duration ||
        oldDelegate.color != color;
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
      onHorizontalDragStart: (_) => onGestureStart(),
      onHorizontalDragUpdate: (details) => onUpdate(details.delta),
      onHorizontalDragEnd: (_) => onGestureEnd(),
      onHorizontalDragCancel: onGestureEnd,
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
  final int frameRate;
  final bool showTimecode;

  _RulerPainter({
    required this.pixelsPerSecond,
    required this.totalDuration,
    this.frameRate = 30,
    this.showTimecode = true,
  });

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

      final label = showTimecode
          ? _timecode(Duration(seconds: sec), frameRate)
          : '$sec';
      final textPainter = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(x + 2, 4));
    }
  }

  @override
  bool shouldRepaint(covariant _RulerPainter oldDelegate) {
    return oldDelegate.pixelsPerSecond != pixelsPerSecond ||
        oldDelegate.totalDuration != totalDuration ||
        oldDelegate.frameRate != frameRate ||
        oldDelegate.showTimecode != showTimecode;
  }

  String _timecode(Duration duration, int rate) {
    final totalSeconds = duration.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    final frame = ((duration.inMilliseconds % 1000) * rate / 1000)
        .floor()
        .toString()
        .padLeft(2, '0');
    return '$minutes:$seconds:$frame';
  }
}

class _ClipMoveSession {
  final EditorTimeline timeline;
  final TimelineTrack track;
  final TimelineClip clip;
  final Offset pointerOrigin;
  Offset cumulativeDelta = Offset.zero;

  _ClipMoveSession({
    required this.timeline,
    required this.track,
    required this.clip,
    required this.pointerOrigin,
  });
}

enum _TrimEdge { start, end }

class _ClipTrimSession {
  final EditorTimeline timeline;
  final TimelineTrack track;
  final TimelineClip clip;
  Offset cumulativeDelta = Offset.zero;
  _TrimEdge? edge;

  _ClipTrimSession({
    required this.timeline,
    required this.track,
    required this.clip,
  });
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
      laneHeight: 8,
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
