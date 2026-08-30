import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/timeline_waveform_cache.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../models/timeline_models.dart';
import '../providers/editor_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/subtitle_provider.dart';
import '../services/timeline_keyframe_editing.dart';
import '../services/timeline_snapping.dart';
import 'resizable_editor_sheet.dart';

@visibleForTesting
const Duration timelineEditHoldDurationForTesting = Duration(milliseconds: 480);

const double _timelineEditMovementSlop = 6;

@visibleForTesting
Duration timelineRulerLabelIntervalForTesting({
  required double pixelsPerSecond,
  double minimumLabelSpacing = 64,
}) {
  final safePixelsPerSecond = math.max(0.001, pixelsPerSecond);
  final requiredMilliseconds = minimumLabelSpacing / safePixelsPerSecond * 1000;
  const niceIntervalsMs = <int>[
    100,
    200,
    500,
    1000,
    2000,
    5000,
    10000,
    15000,
    30000,
    60000,
    120000,
    300000,
    600000,
    1800000,
    3600000,
  ];
  for (final interval in niceIntervalsMs) {
    if (interval >= requiredMilliseconds) {
      return Duration(milliseconds: interval);
    }
  }
  return const Duration(hours: 1);
}

String _snapTargetLabel(TimelineSnapTarget target) {
  return switch (target) {
    TimelineSnapTarget.frames => 'Frame boundaries',
    TimelineSnapTarget.playhead => 'Playhead',
    TimelineSnapTarget.clipEdges => 'Clip starts and ends',
    TimelineSnapTarget.markers => 'Markers and chapters',
    TimelineSnapTarget.beats => 'Beat markers',
    TimelineSnapTarget.keyframes => 'Keyframes',
    TimelineSnapTarget.selectionBoundaries => 'Selection boundaries',
    TimelineSnapTarget.workAreaBoundaries => 'Work-area boundaries',
  };
}

/// Selects only clips intersecting a horizontally visible timeline window.
/// [sortedClips] must be ordered by start time and non-overlapping, which is
/// guaranteed by the editor's normalized lane model.
@visibleForTesting
List<TimelineClip> timelineVisibleClipsForTesting({
  required List<TimelineClip> sortedClips,
  required Duration viewportStart,
  required Duration viewportEnd,
  Iterable<TimelineClip> pinnedClips = const [],
}) {
  if (sortedClips.isEmpty) return pinnedClips.toList(growable: false);
  final start = viewportStart <= viewportEnd ? viewportStart : viewportEnd;
  final end = viewportStart <= viewportEnd ? viewportEnd : viewportStart;
  var lower = 0;
  var upper = sortedClips.length;
  while (lower < upper) {
    final middle = lower + ((upper - lower) >> 1);
    if (sortedClips[middle].startTime <= start) {
      lower = middle + 1;
    } else {
      upper = middle;
    }
  }

  final visible = <TimelineClip>[];
  final includedIds = <String>{};
  var index = math.max(0, lower - 1);
  while (index < sortedClips.length) {
    final clip = sortedClips[index];
    if (clip.startTime > end) break;
    if (clip.endTime >= start && includedIds.add(clip.id)) visible.add(clip);
    index++;
  }
  for (final clip in pinnedClips) {
    if (includedIds.add(clip.id)) visible.add(clip);
  }
  visible.sort((a, b) => a.startTime.compareTo(b.startTime));
  return visible;
}

class TimelinePanel extends ConsumerStatefulWidget {
  final ValueChanged<SubtitleEntry>? onEditRequested;
  final ValueChanged<TimelineClip>? onTextClipEditRequested;
  final ValueChanged<TimelineClip>? onTransitionRequested;
  final ValueChanged<TimelineTrack>? onMainVideoAddRequested;
  final ValueChanged<TimelineClip>? onReplaceMediaRequested;
  final ValueChanged<TimelineTrack>? onOverlayAddRequested;
  final ValueChanged<TimelineTrack>? onTextAddRequested;
  final ValueChanged<TimelineTrack>? onAudioAddRequested;

  const TimelinePanel({
    super.key,
    this.onEditRequested,
    this.onTextClipEditRequested,
    this.onTransitionRequested,
    this.onMainVideoAddRequested,
    this.onReplaceMediaRequested,
    this.onOverlayAddRequested,
    this.onTextAddRequested,
    this.onAudioAddRequested,
  });

  @override
  ConsumerState<TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends ConsumerState<TimelinePanel> {
  late final EditorNotifier _editorNotifier;
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  final GlobalKey _horizontalViewportKey = GlobalKey();
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
  bool _audioFadeGestureActive = false;
  final Map<String, GlobalKey> _clipStateKeys = <String, GlobalKey>{};
  Timer? _edgeScrollTimer;
  Offset? _latestTimelineGesturePointer;
  bool _viewportRebuildScheduled = false;
  EditorTimeline? _cachedRenderIndexTimeline;
  Duration _cachedRenderDuration = Duration.zero;
  Map<String, List<TimelineClip>> _cachedSortedClipsByTrackId = const {};
  Map<String, (TimelineTrack, TimelineClip)> _cachedClipSelectionById =
      const {};
  List<TimelineMarker> _cachedSortedMarkers = const [];
  TimelineSnapIndex _cachedSnapIndex = const TimelineSnapIndex();
  Map<String, String> _cachedWaveformSourceByAssetId = const {};

  @override
  void initState() {
    super.initState();
    _editorNotifier = ref.read(editorProvider.notifier);
    _horizontalScrollController.addListener(_scheduleViewportRebuild);
    _verticalScrollController.addListener(_scheduleViewportRebuild);
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
  static const double _maxPixelsPerSecond = 1200;
  static const double _toolbarHeight = 48;
  static const double _rulerHeight = 30;
  static const double _labelColumnWidth = 50;
  static const double _sectionHeaderHeight = 8;
  static const double _laneGap = 5;
  static const int _minClipDurationMs = 300;
  static const double _edgeAutoScrollZone = 52;

  @override
  void dispose() {
    _edgeScrollTimer?.cancel();
    if (_clipMoveSession != null ||
        _clipTrimSession != null ||
        _audioFadeGestureActive) {
      _editorNotifier.endTimelineGestureEdit();
    }
    _horizontalScrollController.removeListener(_scheduleViewportRebuild);
    _verticalScrollController.removeListener(_scheduleViewportRebuild);
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    super.dispose();
  }

  void _scheduleViewportRebuild() {
    if (_viewportRebuildScheduled || !mounted) return;
    _viewportRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportRebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  void _ensureRenderIndex(EditorTimeline timeline) {
    if (identical(_cachedRenderIndexTimeline, timeline)) return;
    _cachedRenderIndexTimeline = timeline;
    final sortedByTrack = <String, List<TimelineClip>>{};
    final selections = <String, (TimelineTrack, TimelineClip)>{};
    final liveClipIds = <String>{};
    var duration = Duration.zero;
    for (final track in timeline.tracks) {
      final clips = [...track.clips]
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
      sortedByTrack[track.id] = clips;
      for (final clip in clips) {
        selections[clip.id] = (track, clip);
        liveClipIds.add(clip.id);
        if (clip.endTime > duration) duration = clip.endTime;
      }
    }
    _cachedSortedClipsByTrackId = sortedByTrack;
    _cachedClipSelectionById = selections;
    _cachedRenderDuration = duration;
    _cachedSortedMarkers = [...timeline.markers]
      ..sort((a, b) => a.position.compareTo(b.position));
    _cachedSnapIndex = TimelineSnapIndex.fromTimeline(timeline);
    _cachedWaveformSourceByAssetId = Map.unmodifiable({
      for (final asset in timeline.assets)
        if (asset.sourcePath?.trim().isNotEmpty == true)
          asset.id: asset.sourcePath!.trim(),
    });
    _clipStateKeys.removeWhere((clipId, _) => !liveClipIds.contains(clipId));
  }

  List<TimelineMarker> _markersInWindow(Duration start, Duration end) {
    if (_cachedSortedMarkers.isEmpty) return const [];
    var lower = 0;
    var upper = _cachedSortedMarkers.length;
    while (lower < upper) {
      final middle = lower + ((upper - lower) >> 1);
      if (_cachedSortedMarkers[middle].position < start) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    final visible = <TimelineMarker>[];
    for (var index = lower; index < _cachedSortedMarkers.length; index++) {
      final marker = _cachedSortedMarkers[index];
      if (marker.position > end) break;
      visible.add(marker);
    }
    return visible;
  }

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
      // Effects are clips inside an ordinary overlay lane, never a separate
      // track type.
      TimelineTrackType.effect => null,
      TimelineTrackType.image ||
      TimelineTrackType.gif ||
      TimelineTrackType.sticker ||
      TimelineTrackType.subtitle => null,
    };

    if (nextTrack == null) return;

    final notifier = ref.read(editorProvider.notifier);
    notifier
      ..setTimeline(timeline.insertTrackUsingEditorRules(nextTrack))
      ..selectTrack(nextTrack.id)
      ..selectClip(null);
    ref.read(subtitleProvider.notifier).selectEntry(null);
  }

  Future<void> _showAddTrackChooser() async {
    final selectedType = await showFixedEditorSheet<TimelineTrackType>(
      context: context,
      title: 'Add track',
      subtitle: 'Create another reusable timeline lane',
      heightFactor: 0.44,
      builder: (sheetContext) => Column(
        children: [
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
          ])
            ListTile(
              key: ValueKey('timeline_track_choice_${option.$1.name}'),
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
                style: const TextStyle(color: kTextSecondary, fontSize: 11),
              ),
              onTap: () => Navigator.pop(sheetContext, option.$1),
            ),
        ],
      ),
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

  bool _applyTimeline(EditorTimeline timeline) {
    if (timeline.hasTrackOverlaps) {
      SnackBarHelper.showInfo(
        context,
        'That edit would overlap another clip in the same track.',
      );
      return false;
    }
    ref.read(editorProvider.notifier).setTimeline(timeline);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(timeline.subtitleEntries);
    return true;
  }

  void _beginAudioFadeEdit() {
    if (_audioFadeGestureActive) return;
    _audioFadeGestureActive = true;
    _editorNotifier.beginTimelineGestureEdit();
  }

  void _updateAudioFade(
    String clipId, {
    required bool fadeIn,
    required int durationMs,
  }) {
    final timeline = ref.read(editorProvider).timeline;
    final selection = _cachedClipSelectionById[clipId];
    if (selection == null || selection.$1.isLocked) return;
    final safeDuration = durationMs
        .clamp(0, selection.$2.duration.inMilliseconds ~/ 2)
        .toInt();
    final nextTracks = timeline.tracks.map((track) {
      if (track.id != selection.$1.id) return track;
      return track.copyWith(
        clips: track.clips.map((clip) {
          if (clip.id != clipId) return clip;
          return clip.copyWith(
            audioMix: clip.audioMix.copyWith(
              fadeInMs: fadeIn ? safeDuration : clip.audioMix.fadeInMs,
              fadeOutMs: fadeIn ? clip.audioMix.fadeOutMs : safeDuration,
              clearLoudnessAnalysis: true,
            ),
          );
        }).toList(),
      );
    }).toList();
    _applyTimeline(timeline.copyWith(tracks: nextTracks));
  }

  void _endAudioFadeEdit() {
    if (!_audioFadeGestureActive) return;
    _audioFadeGestureActive = false;
    _editorNotifier.endTimelineGestureEdit();
  }

  bool _wouldRemoveLastVisual(
    EditorTimeline timeline,
    Iterable<String> clipIds,
  ) {
    final removed = clipIds.toSet();
    final removesVisual = timeline.visualMediaClips.any(
      (clip) => removed.contains(clip.id),
    );
    return removesVisual &&
        !timeline.wouldRetainVisualContentAfterRemoving(removed);
  }

  Future<void> _showLastVisualGuard(TimelineClip visual) async {
    if (widget.onReplaceMediaRequested == null) {
      SnackBarHelper.showInfo(
        context,
        'A project needs at least one image, GIF, sticker, or video. Replace it instead.',
      );
      return;
    }
    final shouldReplace = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('timeline_last_visual_dialog'),
        title: const Text('Keep one visual'),
        content: const Text(
          'A project needs at least one image, GIF, sticker, or video. You can replace this '
          'clip instead of deleting it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            key: const ValueKey('timeline_replace_last_visual'),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.swap_horiz_rounded),
            label: const Text('Replace'),
          ),
        ],
      ),
    );
    if (!mounted || shouldReplace != true) return;
    widget.onReplaceMediaRequested?.call(visual);
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

  void _zoomBy(double factor, {Duration? anchor, bool centerAnchor = false}) {
    final oldPixelsPerSecond = _pixelsPerSecond;
    final anchorPosition = anchor ?? ref.read(playbackProvider).position;
    final oldScroll = _horizontalScrollController.hasClients
        ? _horizontalScrollController.offset
        : 0.0;
    final oldAnchorX =
        anchorPosition.inMicroseconds /
        Duration.microsecondsPerSecond *
        oldPixelsPerSecond;
    final viewportAnchorX =
        centerAnchor && _horizontalScrollController.hasClients
        ? _horizontalScrollController.position.viewportDimension / 2
        : oldAnchorX - oldScroll;
    setState(() {
      _pixelsPerSecond = (_pixelsPerSecond * factor)
          .clamp(_minPixelsPerSecond, _maxPixelsPerSecond)
          .toDouble();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_horizontalScrollController.hasClients) return;
      final newAnchorX =
          anchorPosition.inMicroseconds /
          Duration.microsecondsPerSecond *
          _pixelsPerSecond;
      final target = (newAnchorX - viewportAnchorX).clamp(
        _horizontalScrollController.position.minScrollExtent,
        _horizontalScrollController.position.maxScrollExtent,
      );
      _horizontalScrollController.jumpTo(target.toDouble());
    });
  }

  void _zoomToSelection() {
    final editorState = ref.read(editorProvider);
    final selectedIds = editorState.selectedClipIds.isNotEmpty
        ? editorState.selectedClipIds
        : {if (editorState.selectedClipId != null) editorState.selectedClipId!};
    final clips = selectedIds
        .map((id) => _cachedClipSelectionById[id]?.$2)
        .whereType<TimelineClip>()
        .toList();
    if (clips.isEmpty) {
      SnackBarHelper.showInfo(context, 'Select one or more clips to zoom.');
      return;
    }
    final startUs = clips
        .map((clip) => clip.startTime.inMicroseconds)
        .reduce((first, second) => first < second ? first : second);
    final endUs = clips
        .map((clip) => clip.endTime.inMicroseconds)
        .reduce((first, second) => first > second ? first : second);
    final spanSeconds = math.max(
      0.001,
      (endUs - startUs) / Duration.microsecondsPerSecond,
    );
    final viewportWidth = _horizontalScrollController.hasClients
        ? _horizontalScrollController.position.viewportDimension
        : math.max(0.0, MediaQuery.sizeOf(context).width - _labelColumnWidth);
    final usableWidth = math.max(80.0, viewportWidth - 32);
    setState(() {
      _pixelsPerSecond = (usableWidth / spanSeconds)
          .clamp(_minPixelsPerSecond, _maxPixelsPerSecond)
          .toDouble();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_horizontalScrollController.hasClients) return;
      final target =
          startUs / Duration.microsecondsPerSecond * _pixelsPerSecond - 16;
      _horizontalScrollController.jumpTo(
        target
            .clamp(
              _horizontalScrollController.position.minScrollExtent,
              _horizontalScrollController.position.maxScrollExtent,
            )
            .toDouble(),
      );
    });
  }

  Future<void> _showSnappingSettings() async {
    var settings = ref.read(editorProvider).timeline.workspaceSettings.snapping;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            children: [
              const Text(
                'Snapping targets',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Choose which timeline relationships become magnetic while moving or trimming clips.',
                style: TextStyle(color: kTextSecondary, fontSize: 12),
              ),
              const SizedBox(height: 8),
              for (final target in TimelineSnapTarget.values)
                SwitchListTile.adaptive(
                  key: ValueKey('timeline_snap_target_${target.name}'),
                  value: settings.targets.contains(target),
                  title: Text(_snapTargetLabel(target)),
                  onChanged: (enabled) {
                    final next = settings.withTarget(target, enabled: enabled);
                    setSheetState(() => settings = next);
                    _updateWorkspace(
                      (workspace) => workspace.copyWith(snapping: next),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
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

  Future<void> _removeTrack(TimelineTrack track) async {
    if (!_canRemoveTrack(track)) return;
    if (track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track before deleting it.');
      return;
    }

    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    if (_wouldRemoveLastVisual(timeline, track.clips.map((clip) => clip.id))) {
      final replacement = track.clips
          .where((clip) => clip.type.isVisualMedia)
          .firstOrNull;
      if (replacement != null) await _showLastVisualGuard(replacement);
      return;
    }
    final removedClipIds = track.clips.map((clip) => clip.id).toSet();
    final nextTracks = timeline.tracks
        .where((candidate) => candidate.id != track.id)
        .map(
          (candidate) => candidate.copyWith(
            clips: candidate.clips
                .where(
                  (clip) =>
                      clip.linkedClipId == null ||
                      !removedClipIds.contains(clip.linkedClipId),
                )
                .toList(),
          ),
        )
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
        .setTimeline(
          timeline
              .copyWith(tracks: nextTracks, assets: nextAssets)
              .prunedRelationships(),
        );

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
    if (track.isSourceTrack) return false;
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
    final currentTimeline = ref.read(editorProvider).timeline;
    final currentTrack = currentTimeline.tracks
        .where((candidate) => candidate.id == track.id)
        .firstOrNull;
    if (currentTrack == null) return;
    if (_wouldRemoveLastVisual(
      currentTimeline,
      currentTrack.clips.map((clip) => clip.id),
    )) {
      final replacement = currentTrack.clips
          .where((clip) => clip.type.isVisualMedia)
          .firstOrNull;
      if (replacement != null) await _showLastVisualGuard(replacement);
      return;
    }
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
    final timeline = ref.read(editorProvider).timeline;
    final liveTrack = timeline.tracks
        .where((candidate) => candidate.id == track.id)
        .firstOrNull;
    if (liveTrack != null) await _removeTrack(liveTrack);
  }

  Future<void> _showTrackActions(
    TimelineTrack track,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final local = overlay.globalToLocal(globalPosition);
    final timeline = ref.read(editorProvider).timeline;
    final liveTrack = timeline.tracks
        .where((candidate) => candidate.id == track.id)
        .firstOrNull;
    if (liveTrack == null) return;
    final canHide = liveTrack.section != TimelineTrackSection.audio;
    final canMute =
        liveTrack.section == TimelineTrackSection.audio ||
        liveTrack.type == TimelineTrackType.video;
    final canSolo =
        liveTrack.isSolo ||
        liveTrack.clips.any((clip) => timeline.clipHasAudio(clip));
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
        if (canSolo)
          PopupMenuItem(
            value: _TrackQuickAction.solo,
            child: _TrackActionMenuItem(
              icon: liveTrack.isSolo
                  ? Icons.hearing_disabled_rounded
                  : Icons.hearing_rounded,
              label: liveTrack.isSolo ? 'Unsolo' : 'Solo',
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
      case _TrackQuickAction.solo:
        _updateTrack(
          latest,
          (current) => current.copyWith(isSolo: !current.isSolo),
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
    final workspace = timeline.workspaceSettings;
    final snapped = TimelineSnapEngine.snapRangeStart(
      proposedStart: Duration(milliseconds: proposedStartMs),
      duration: Duration(milliseconds: durationMs),
      settings: workspace.snapping,
      index: _cachedSnapIndex,
      frameRate: workspace.frameRate,
      threshold: _timelineSnapThreshold,
      playhead: ref.read(playbackProvider).position,
      selectionBoundaries: _selectedSnapBoundaries(clip.id),
      excludedClipBoundaries: [clip.startTime, clip.endTime],
      excludedClipId: clip.id,
      workAreaStart: workspace.normalizedWorkAreaStart,
      workAreaEnd: workspace.normalizedWorkAreaEnd,
    );
    return (snapped.inMicroseconds / 1000).round();
  }

  int _snapEdgeMs(EditorTimeline timeline, TimelineClip clip, int proposedMs) {
    final workspace = timeline.workspaceSettings;
    final snapped = TimelineSnapEngine.snapPoint(
      proposed: Duration(milliseconds: proposedMs),
      settings: workspace.snapping,
      index: _cachedSnapIndex,
      frameRate: workspace.frameRate,
      threshold: _timelineSnapThreshold,
      playhead: ref.read(playbackProvider).position,
      selectionBoundaries: _selectedSnapBoundaries(clip.id),
      excludedClipBoundaries: [clip.startTime, clip.endTime],
      excludedClipId: clip.id,
      workAreaStart: workspace.normalizedWorkAreaStart,
      workAreaEnd: workspace.normalizedWorkAreaEnd,
    );
    return (snapped.inMicroseconds / 1000).round();
  }

  Duration get _timelineSnapThreshold => Duration(
    microseconds: (10 / _pixelsPerSecond * Duration.microsecondsPerSecond)
        .round()
        .clamp(40000, 700000),
  );

  Iterable<Duration> _selectedSnapBoundaries(String movingClipId) sync* {
    final selectedIds = ref.read(editorProvider).selectedClipIds;
    for (final selectedId in selectedIds) {
      if (selectedId == movingClipId) continue;
      final selection = _cachedClipSelectionById[selectedId];
      if (selection == null) continue;
      yield selection.$2.startTime;
      yield selection.$2.endTime;
    }
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
      final compositionEnd = Duration(
        milliseconds: _compositionDurationMs(timeline),
      );
      final resolvedStart = targetTrack.closestAvailableStart(
        desiredStart: playhead,
        duration: subtitle.duration,
        latestEnd: compositionEnd,
      );
      final candidate = TimelineClip(
        id: const Uuid().v4(),
        trackId: targetTrack.id,
        type: TimelineTrackType.subtitle,
        label: subtitle.text,
        startTime: resolvedStart,
        endTime: resolvedStart + subtitle.duration,
        text: subtitle.text,
        subtitleStyle: subtitle.styleOverride,
      );
      if (!targetTrack.canPlaceClip(candidate)) {
        SnackBarHelper.showInfo(
          context,
          'There is no free space in this subtitle track.',
        );
        return;
      }
      ref
          .read(subtitleProvider.notifier)
          .pasteEntry(subtitle, startTime: resolvedStart);
      return;
    }
    final sourceClip = _clipboardClip;
    final sourceTrack = _clipboardTrack;
    if (sourceClip == null || sourceTrack == null) return;
    final targetTracks = timeline.tracks.where(
      (track) =>
          track.id == sourceTrack.id &&
          !track.isLocked &&
          track.section != TimelineTrackSection.baseVideo,
    );
    if (targetTracks.isEmpty) {
      SnackBarHelper.showInfo(
        context,
        'The copied clip track is unavailable or locked.',
      );
      return;
    }
    final targetTrack = targetTracks.first;
    final timelineEnd = timeline.duration;
    final resolvedStart = targetTrack.closestAvailableStart(
      desiredStart: playhead,
      duration: sourceClip.duration,
      latestEnd: timelineEnd,
    );
    final pasted = sourceClip.copyWith(
      id: const Uuid().v4(),
      trackId: targetTrack.id,
      startTime: resolvedStart,
      endTime: resolvedStart + sourceClip.duration,
      effectStack: sourceClip.effectStack.cloneWithNewIds(),
      clearGroupId: true,
      clearCompoundId: true,
    );
    if (!targetTrack.canPlaceClip(pasted)) {
      SnackBarHelper.showInfo(context, 'There is no free space in this track.');
      return;
    }
    final nextTracks = timeline.tracks.map((track) {
      if (track.id != targetTrack.id) return track;
      final clips = [...track.clips, pasted]
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
      return track.copyWith(clips: clips);
    }).toList();
    if (!_applyTimeline(timeline.copyWith(tracks: nextTracks))) return;
    ref.read(editorProvider.notifier).selectTrack(targetTrack.id);
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
    final rawStart = math.max(
      minimumStart,
      clip.startTime.inMilliseconds + deltaMs,
    );
    final maximumStart = next == null
        ? math.max(clip.startTime.inMilliseconds, rawStart)
        : next.startTime.inMilliseconds - durationMs;
    final proposedStart = rawStart.clamp(minimumStart, maximumStart).toInt();
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
    if (!track.canPlaceClip(updatedClip, ignoringClipId: clip.id)) return;

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
      if (candidateTrack.section == TimelineTrackSection.audio) {
        final nextClips = candidateTrack.clips.map((candidate) {
          if (!_shouldSynchronizeLinkedAudio(
            track: candidateTrack,
            audio: candidate,
            source: clip,
          )) {
            return candidate;
          }
          return candidate.copyWith(
            startTime: updatedClip.startTime,
            endTime: updatedClip.endTime,
            sourceStartTime: updatedClip.sourceStartTime,
            sourceDuration: updatedClip.sourceDuration,
          );
        }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
      }
      if (candidateTrack.type == TimelineTrackType.subtitle) {
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
      final shifted = candidateTrack.clips.map((candidate) {
        final linkedId = candidate.linkedClipId;
        final shift = linkedId == null ? null : shiftsByClipId[linkedId];
        if (shift == null || shift == Duration.zero) return candidate;
        final originalSource = originalById[linkedId];
        if (candidate.type == TimelineTrackType.audio &&
            (originalSource == null ||
                !_shouldSynchronizeLinkedAudio(
                  track: candidateTrack,
                  audio: candidate,
                  source: originalSource,
                ))) {
          return candidate;
        }
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
    final snappedStartMs = _snapStartMs(
      timeline,
      clip,
      proposedStart,
      durationMs,
    ).clamp(0, maximumStart).toInt();

    final targetTrack = _targetTrackForDrag(timeline, track, clip, delta.dy);
    final desiredStart = Duration(milliseconds: snappedStartMs);
    final crossesLanes = targetTrack.id != track.id;
    final resolvedStart = crossesLanes
        ? desiredStart
        : targetTrack.closestAvailableStart(
            desiredStart: desiredStart,
            duration: clip.duration,
            ignoringClipId: clip.id,
            latestEnd: Duration(milliseconds: maxTimelineMs),
          );
    final nextStartMs = resolvedStart.inMilliseconds;
    if (nextStartMs == clip.startTime.inMilliseconds &&
        targetTrack.id == track.id) {
      return;
    }

    final updatedClip = clip.copyWith(
      trackId: targetTrack.id,
      startTime: Duration(milliseconds: nextStartMs),
      endTime: Duration(milliseconds: nextStartMs + durationMs),
    );
    // Crossing lanes must never make a clip jump to some distant free gap.
    // Keep the edit where the pointer put it; an occupied lane simply rejects
    // the crossing until the pointer reaches a compatible free lane.
    if (!targetTrack.canPlaceClip(
      updatedClip,
      ignoringClipId: crossesLanes ? null : clip.id,
    )) {
      return;
    }
    final appliedDelta = Duration(
      milliseconds: nextStartMs - clip.startTime.inMilliseconds,
    );

    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.isLocked) {
        final shiftedDependents = candidateTrack.clips.map((candidate) {
          if (candidate.linkedClipId != clip.id) return candidate;
          if (candidate.type == TimelineTrackType.audio &&
              !_shouldSynchronizeLinkedAudio(
                track: candidateTrack,
                audio: candidate,
                source: clip,
              )) {
            return candidate;
          }
          return candidate.copyWith(
            startTime: candidate.startTime + appliedDelta,
            endTime: candidate.endTime + appliedDelta,
          );
        }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: shiftedDependents);
      }
      final nextClips = candidateTrack.clips
          .where((candidate) => candidate.id != clip.id)
          .map((candidate) {
            if (candidate.linkedClipId != clip.id) return candidate;
            if (candidate.type == TimelineTrackType.audio &&
                !_shouldSynchronizeLinkedAudio(
                  track: candidateTrack,
                  audio: candidate,
                  source: clip,
                )) {
              return candidate;
            }
            return candidate.copyWith(
              startTime: candidate.startTime + appliedDelta,
              endTime: candidate.endTime + appliedDelta,
            );
          })
          .toList();
      if (candidateTrack.id == targetTrack.id) {
        nextClips.add(updatedClip);
        nextClips.sort((a, b) => a.startTime.compareTo(b.startTime));
      }
      return candidateTrack.copyWith(clips: nextClips);
    }).toList();

    if (!_applyTimeline(timeline.copyWith(tracks: nextTracks))) return;
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

  bool _shouldSynchronizeLinkedAudio({
    required TimelineTrack track,
    required TimelineClip audio,
    required TimelineClip source,
  }) {
    if (audio.type != TimelineTrackType.audio ||
        audio.linkedClipId != source.id) {
      return false;
    }
    // System-managed lanes from old projects always followed their source.
    if (track.role == TimelineTrackRole.sourceAudio) return true;
    // A lock on an explicit audio lane is an ownership boundary. Base/overlay
    // edits may continue, but must leave that separated audio untouched.
    if (track.isLocked) return false;
    // Explicitly separated audio follows while it is still an exact mirror.
    // Once a user shifts, trims, changes speed, or reverses it independently,
    // later Base-layer edits must not overwrite that intentional divergence.
    return _isExactLinkedAudioMirror(audio: audio, source: source);
  }

  bool _isExactLinkedAudioMirror({
    required TimelineClip audio,
    required TimelineClip source,
  }) {
    return source.assetId != null &&
        audio.assetId == source.assetId &&
        audio.startTime == source.startTime &&
        audio.endTime == source.endTime &&
        audio.sourceStartTime == source.sourceStartTime &&
        audio.sourceDuration == source.sourceDuration &&
        (audio.playbackRate - source.playbackRate).abs() < 0.0001 &&
        audio.isReversed == source.isReversed;
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

    final rows = _buildTrackLayouts(
      timeline,
    ).where((row) => row.track != null).toList(growable: false);
    final sourceRow = rows
        .where((row) => row.track!.id == sourceTrack.id)
        .firstOrNull;
    if (sourceRow == null) return sourceTrack;

    final desiredCenter =
        sourceRow.laneTop + sourceRow.laneHeight / 2 + cumulativeDy;
    var target = sourceTrack;
    var bestDistance = double.infinity;
    for (final row in rows) {
      final candidate = row.track!;
      if (candidate.section != sourceTrack.section ||
          !_trackAcceptsClip(candidate, clip)) {
        continue;
      }
      final center = row.laneTop + row.laneHeight / 2;
      final distance = (center - desiredCenter).abs();
      // Timeline order is the deterministic tie-breaker because rows are
      // visited top-to-bottom. Real row geometry also handles collapsed lanes,
      // group headers, and unrelated tracks between compatible lanes.
      if (distance < bestDistance) {
        target = candidate;
        bestDistance = distance;
      }
    }
    return target;
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
    _latestTimelineGesturePointer = pointerOrigin;
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
    _latestTimelineGesturePointer = pointerPosition;
    _updateEdgeAutoScroll();
    session.cumulativeDelta =
        pointerPosition -
        session.pointerOrigin +
        Offset(session.scrollCompensationDx, 0);
    _moveClip(
      session.timeline,
      session.track,
      session.clip,
      session.cumulativeDelta,
    );
  }

  void _endClipMove() {
    _edgeScrollTimer?.cancel();
    _edgeScrollTimer = null;
    _latestTimelineGesturePointer = null;
    _clipMoveSession = null;
    ref.read(editorProvider.notifier).endTimelineGestureEdit();
  }

  GlobalKey _clipStateKey(String clipId) {
    return _clipStateKeys.putIfAbsent(
      clipId,
      () => GlobalKey(debugLabel: 'timeline-movable-$clipId'),
    );
  }

  void _updateEdgeAutoScroll() {
    if (_edgeScrollVelocity() == 0) {
      _edgeScrollTimer?.cancel();
      _edgeScrollTimer = null;
      return;
    }
    _edgeScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _performEdgeAutoScrollTick(),
    );
    _performEdgeAutoScrollTick();
  }

  double _edgeScrollVelocity() {
    final pointer = _latestTimelineGesturePointer;
    final renderBox =
        _horizontalViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (pointer == null ||
        renderBox == null ||
        !_horizontalScrollController.hasClients) {
      return 0;
    }
    final local = renderBox.globalToLocal(pointer);
    final width = renderBox.size.width;
    if (width <= 0 || local.dy < -24 || local.dy > renderBox.size.height + 24) {
      return 0;
    }
    if (local.dx < _edgeAutoScrollZone) {
      final strength = ((_edgeAutoScrollZone - local.dx) / _edgeAutoScrollZone)
          .clamp(0.0, 1.0);
      return -math.max(2.0, 14.0 * strength);
    }
    if (local.dx > width - _edgeAutoScrollZone) {
      final strength =
          ((local.dx - (width - _edgeAutoScrollZone)) / _edgeAutoScrollZone)
              .clamp(0.0, 1.0);
      return math.max(2.0, 14.0 * strength);
    }
    return 0;
  }

  void _performEdgeAutoScrollTick() {
    final moveSession = _clipMoveSession;
    final trimSession = _clipTrimSession;
    final pointer = _latestTimelineGesturePointer;
    if ((moveSession == null && trimSession == null) ||
        pointer == null ||
        !_horizontalScrollController.hasClients) {
      _edgeScrollTimer?.cancel();
      _edgeScrollTimer = null;
      return;
    }
    final velocity = _edgeScrollVelocity();
    if (velocity == 0) {
      _edgeScrollTimer?.cancel();
      _edgeScrollTimer = null;
      return;
    }
    final position = _horizontalScrollController.position;
    final before = position.pixels;
    final next = (before + velocity)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((next - before).abs() < 0.01) return;
    _horizontalScrollController.jumpTo(next);
    final appliedScroll = next - before;
    if (moveSession != null) {
      moveSession.scrollCompensationDx += appliedScroll;
      moveSession.cumulativeDelta =
          pointer -
          moveSession.pointerOrigin +
          Offset(moveSession.scrollCompensationDx, 0);
      _moveClip(
        moveSession.timeline,
        moveSession.track,
        moveSession.clip,
        moveSession.cumulativeDelta,
      );
      return;
    }
    if (trimSession != null) {
      trimSession.scrollCompensationDx += appliedScroll;
      trimSession.cumulativeDelta =
          pointer -
          trimSession.pointerOrigin +
          Offset(trimSession.scrollCompensationDx, 0);
      _applyClipTrimSession(trimSession);
    }
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
      keyframes: TimelineKeyframeEditing.forNewStart(
        clip,
        Duration(milliseconds: newStartMs),
      ),
      effectStack: clip.effectStack.trimmedFromStart(
        Duration(milliseconds: newStartMs - clip.startTime.inMilliseconds),
      ),
    );
    if (!track.canPlaceClip(updatedClip, ignoringClipId: clip.id)) return;

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
      if (candidateTrack.section == TimelineTrackSection.audio) {
        final nextClips = candidateTrack.clips.map((candidate) {
          if (!_shouldSynchronizeLinkedAudio(
            track: candidateTrack,
            audio: candidate,
            source: clip,
          )) {
            return candidate;
          }
          return candidate.copyWith(
            startTime: updatedClip.startTime,
            endTime: updatedClip.endTime,
            sourceStartTime: updatedClip.sourceStartTime,
            sourceDuration: updatedClip.sourceDuration,
            keyframes: TimelineKeyframeEditing.forNewStart(
              candidate,
              updatedClip.startTime,
            ),
            effectStack: candidate.effectStack.trimmedFromStart(
              updatedClip.startTime - candidate.startTime,
            ),
          );
        }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
      }
      if (candidateTrack.type == TimelineTrackType.subtitle) {
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
      keyframes: TimelineKeyframeEditing.forNewEnd(
        clip,
        Duration(milliseconds: newEndMs),
      ),
      effectStack: clip.effectStack.trimmedToDuration(
        Duration(milliseconds: newEndMs) - clip.startTime,
      ),
    );
    if (!track.canPlaceClip(updatedClip, ignoringClipId: clip.id)) return;

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
      if (candidateTrack.section == TimelineTrackSection.audio) {
        final nextClips = candidateTrack.clips.map((candidate) {
          if (!_shouldSynchronizeLinkedAudio(
            track: candidateTrack,
            audio: candidate,
            source: clip,
          )) {
            return candidate;
          }
          return candidate.copyWith(
            startTime: updatedClip.startTime,
            endTime: updatedClip.endTime,
            sourceStartTime: updatedClip.sourceStartTime,
            sourceDuration: updatedClip.sourceDuration,
            keyframes: TimelineKeyframeEditing.forNewEnd(
              candidate,
              updatedClip.endTime,
            ),
            effectStack: candidate.effectStack.trimmedToDuration(
              updatedClip.endTime - candidate.startTime,
            ),
          );
        }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
      }
      if (candidateTrack.type == TimelineTrackType.subtitle) {
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
    final sourceMinimumStart = sourceBounded
        ? math.max(
            0,
            clip.startTime.inMilliseconds -
                (sourceAvailableBeforeTimelineMs / clip.playbackRate).floor(),
          )
        : 0;
    final previousEndMs = track.clips
        .where(
          (candidate) =>
              candidate.id != clip.id && candidate.endTime <= clip.startTime,
        )
        .fold<int>(0, (latest, candidate) {
          return math.max(latest, candidate.endTime.inMilliseconds);
        });
    final minimumStart = math.max(sourceMinimumStart, previousEndMs);
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
      keyframes: TimelineKeyframeEditing.forNewStart(
        clip,
        Duration(milliseconds: newStartMs),
      ),
      effectStack: clip.effectStack.trimmedFromStart(
        Duration(milliseconds: newStartMs - clip.startTime.inMilliseconds),
      ),
    );
    if (!track.canPlaceClip(updatedClip, ignoringClipId: clip.id)) return;
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
      if (candidateTrack.section == TimelineTrackSection.audio) {
        final nextClips = candidateTrack.clips.map((candidate) {
          if (!_shouldSynchronizeLinkedAudio(
            track: candidateTrack,
            audio: candidate,
            source: clip,
          )) {
            return candidate;
          }
          return candidate.copyWith(
            startTime: updatedClip.startTime,
            endTime: updatedClip.endTime,
            sourceStartTime: updatedClip.sourceStartTime,
            sourceDuration: updatedClip.sourceDuration,
            keyframes: TimelineKeyframeEditing.forNewStart(
              candidate,
              updatedClip.startTime,
            ),
            effectStack: candidate.effectStack.trimmedFromStart(
              updatedClip.startTime - candidate.startTime,
            ),
          );
        }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
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
    final sourceOrCompositionMaximumEnd = sourceBounded
        ? math.min(compositionEnd, sourceMaximumEnd)
        : compositionEnd;
    final nextStartMs = track.clips
        .where(
          (candidate) =>
              candidate.id != clip.id && candidate.startTime >= clip.endTime,
        )
        .fold<int>(sourceOrCompositionMaximumEnd, (earliest, candidate) {
          return math.min(earliest, candidate.startTime.inMilliseconds);
        });
    final maximumEnd = math.min(sourceOrCompositionMaximumEnd, nextStartMs);
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
      keyframes: TimelineKeyframeEditing.forNewEnd(
        clip,
        Duration(milliseconds: newEndMs),
      ),
      effectStack: clip.effectStack.trimmedToDuration(newDuration),
    );
    if (!track.canPlaceClip(updatedClip, ignoringClipId: clip.id)) return;
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
      if (candidateTrack.section == TimelineTrackSection.audio) {
        final nextClips = candidateTrack.clips.map((candidate) {
          if (!_shouldSynchronizeLinkedAudio(
            track: candidateTrack,
            audio: candidate,
            source: clip,
          )) {
            return candidate;
          }
          return candidate.copyWith(
            startTime: updatedClip.startTime,
            endTime: updatedClip.endTime,
            sourceStartTime: updatedClip.sourceStartTime,
            sourceDuration: updatedClip.sourceDuration,
            keyframes: TimelineKeyframeEditing.forNewEnd(
              candidate,
              updatedClip.endTime,
            ),
            effectStack: candidate.effectStack.trimmedToDuration(
              updatedClip.endTime - candidate.startTime,
            ),
          );
        }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidateTrack.copyWith(clips: nextClips);
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

  void _beginClipTrim(TimelineClip clip, _TrimEdge edge, Offset pointerOrigin) {
    final timeline = ref.read(editorProvider).timeline;
    final selection = _selectedClipSelection(timeline, clip.id);
    if (selection == null) return;
    _clipTrimSession = _ClipTrimSession(
      timeline: timeline,
      track: selection.$1,
      clip: selection.$2,
      edge: edge,
      pointerOrigin: pointerOrigin,
    );
    _latestTimelineGesturePointer = pointerOrigin;
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

  void _trimClipStartById(String clipId, Offset pointerPosition) {
    final session = _clipTrimSession;
    if (session == null || session.clip.id != clipId) return;
    if (session.edge != _TrimEdge.start) return;
    _updateClipTrimPointer(session, pointerPosition);
  }

  void _trimClipEndById(String clipId, Offset pointerPosition) {
    final session = _clipTrimSession;
    if (session == null || session.clip.id != clipId) return;
    if (session.edge != _TrimEdge.end) return;
    _updateClipTrimPointer(session, pointerPosition);
  }

  void _updateClipTrimPointer(
    _ClipTrimSession session,
    Offset pointerPosition,
  ) {
    _latestTimelineGesturePointer = pointerPosition;
    _updateEdgeAutoScroll();
    session.cumulativeDelta =
        pointerPosition -
        session.pointerOrigin +
        Offset(session.scrollCompensationDx, 0);
    _applyClipTrimSession(session);
  }

  void _applyClipTrimSession(_ClipTrimSession session) {
    if (session.track.section == TimelineTrackSection.baseVideo) {
      if (session.edge == _TrimEdge.start) {
        _trimBaseClipStart(
          session.timeline,
          session.track,
          session.clip,
          session.cumulativeDelta,
        );
      } else {
        _trimBaseClipEnd(
          session.timeline,
          session.track,
          session.clip,
          session.cumulativeDelta,
        );
      }
      return;
    }
    if (session.edge == _TrimEdge.start) {
      _trimNonBaseClipStart(
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
    if (_clipTrimSession == null) return;
    _edgeScrollTimer?.cancel();
    _edgeScrollTimer = null;
    _latestTimelineGesturePointer = null;
    _clipTrimSession = null;
    ref.read(editorProvider.notifier).endTimelineGestureEdit();
  }

  void _splitSelectedBaseClip(EditorTimeline timeline, Duration splitPoint) {
    final editorState = ref.read(editorProvider);
    final selectedClipId = editorState.selectedClipId;
    if (selectedClipId == null) {
      SnackBarHelper.showInfo(context, 'Select a Base layer clip first.');
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
      SnackBarHelper.showInfo(context, 'Select a Base layer clip first.');
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
    final keyframeSplit = TimelineKeyframeEditing.split(
      clip,
      Duration(milliseconds: leftTimelineDurationMs),
    );
    final effectStackSplit = clip.effectStack.splitAt(
      Duration(milliseconds: leftTimelineDurationMs),
    );
    final firstClip = clip.copyWith(
      endTime: splitPoint,
      sourceStartTime: firstSourceStart,
      sourceDuration: Duration(milliseconds: leftSourceDurationMs),
      outroTransition: const ClipTransition(),
      keyframes: keyframeSplit.leading,
      effectStack: effectStackSplit.leading,
    );
    final secondClip = TimelineClip(
      trackId: clip.trackId,
      type: clip.type,
      effectKind: clip.effectKind,
      effectStack: effectStackSplit.trailing,
      isAdjustmentLayer: clip.isAdjustmentLayer,
      groupId: clip.groupId,
      compoundId: clip.compoundId,
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
      keyframes: keyframeSplit.trailing,
      freezeFrame: clip.freezeFrame,
      freezeFrameSourceTime: clip.freezeFrameSourceTime,
      stabilize: clip.stabilize,
      denoise: clip.denoise,
      chromaKeyEnabled: clip.chromaKeyEnabled,
      chromaKeyColor: clip.chromaKeyColor,
      chromaKeySimilarity: clip.chromaKeySimilarity,
      timelineColor: clip.timelineColor,
      notes: clip.notes,
      autoDuck: clip.autoDuck,
      duckAmount: clip.duckAmount,
      duckAttackMs: clip.duckAttackMs,
      duckReleaseMs: clip.duckReleaseMs,
      duckSidechainTrackIds: clip.duckSidechainTrackIds,
    );

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
      if (track.section == TimelineTrackSection.audio) {
        final nextClips = <TimelineClip>[];
        for (final candidate in track.clips) {
          final canSplitMirror =
              candidate.linkedClipId == clip!.id &&
              (track.role == TimelineTrackRole.sourceAudio ||
                  !track.isLocked) &&
              _isExactLinkedAudioMirror(audio: candidate, source: clip);
          if (!canSplitMirror) {
            nextClips.add(candidate);
            continue;
          }
          final splitAudio = _splitLinkedAudioMirror(
            audio: candidate,
            firstSource: firstClip,
            secondSource: secondClip,
          );
          nextClips.add(splitAudio.first);
          nextClips.add(splitAudio.second);
        }
        nextClips.sort((a, b) => a.startTime.compareTo(b.startTime));
        return track.copyWith(clips: nextClips);
      }
      if (track.type == TimelineTrackType.subtitle) {
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

    final nextTimeline = timeline.copyWith(
      tracks: nextTracks,
      groups: timeline.groups
          .map(
            (group) => group.id == clip!.groupId
                ? group.copyWith(clipIds: [...group.clipIds, secondClip.id])
                : group,
          )
          .toList(),
      compoundClips: timeline.compoundClips
          .map(
            (compound) => compound.id == clip!.compoundId
                ? compound.copyWith(
                    clipIds: [...compound.clipIds, secondClip.id],
                  )
                : compound,
          )
          .toList(),
    );
    _applyTimeline(nextTimeline);
    ref.read(editorProvider.notifier).selectClip(secondClip.id);
  }

  ({TimelineClip first, TimelineClip second}) _splitLinkedAudioMirror({
    required TimelineClip audio,
    required TimelineClip firstSource,
    required TimelineClip secondSource,
  }) {
    final keyframeSplit = TimelineKeyframeEditing.split(
      audio,
      firstSource.duration,
    );
    final effectStackSplit = audio.effectStack.splitAt(firstSource.duration);
    final first = audio.copyWith(
      linkedClipId: firstSource.id,
      endTime: firstSource.endTime,
      sourceStartTime: firstSource.sourceStartTime,
      sourceDuration: firstSource.sourceDuration,
      audioMix: audio.audioMix.copyWith(fadeOutMs: 0),
      outroTransition: const ClipTransition(),
      keyframes: keyframeSplit.leading,
      effectStack: effectStackSplit.leading,
    );
    final second = TimelineClip(
      trackId: audio.trackId,
      type: TimelineTrackType.audio,
      effectStack: effectStackSplit.trailing,
      groupId: audio.groupId,
      compoundId: audio.compoundId,
      label: audio.label,
      assetId: audio.assetId,
      linkedClipId: secondSource.id,
      startTime: secondSource.startTime,
      endTime: secondSource.endTime,
      sourceStartTime: secondSource.sourceStartTime,
      sourceDuration: secondSource.sourceDuration,
      layer: audio.layer,
      enabled: audio.enabled,
      transform: audio.transform,
      audioMix: audio.audioMix.copyWith(fadeInMs: 0),
      fitMode: audio.fitMode,
      playbackRate: audio.playbackRate,
      isReversed: audio.isReversed,
      crop: audio.crop,
      blur: audio.blur,
      colorAdjustments: audio.colorAdjustments,
      introTransition: const ClipTransition(),
      outroTransition: audio.outroTransition,
      keyframes: keyframeSplit.trailing,
      freezeFrame: audio.freezeFrame,
      freezeFrameSourceTime: audio.freezeFrameSourceTime,
      stabilize: audio.stabilize,
      denoise: audio.denoise,
      chromaKeyEnabled: audio.chromaKeyEnabled,
      chromaKeyColor: audio.chromaKeyColor,
      chromaKeySimilarity: audio.chromaKeySimilarity,
      timelineColor: audio.timelineColor,
      notes: audio.notes,
      autoDuck: audio.autoDuck,
      duckAmount: audio.duckAmount,
      duckAttackMs: audio.duckAttackMs,
      duckReleaseMs: audio.duckReleaseMs,
      duckSidechainTrackIds: audio.duckSidechainTrackIds,
    );
    return (first: first, second: second);
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

  Future<void> _handleClipLongPress(
    TimelineTrack track,
    TimelineClip clip,
  ) async {
    final editorNotifier = ref.read(editorProvider.notifier);
    editorNotifier
      ..selectTrack(track.id)
      ..selectClip(clip.id);
    if (clip.type == TimelineTrackType.subtitle &&
        widget.onEditRequested != null) {
      final entry = clip.toSubtitleEntry();
      if (entry != null) widget.onEditRequested!(entry);
      return;
    }
    if (clip.type == TimelineTrackType.text &&
        widget.onTextClipEditRequested != null) {
      widget.onTextClipEditRequested!(clip);
      return;
    }
    if (track.section != TimelineTrackSection.baseVideo ||
        !clip.type.isVisualMedia) {
      return;
    }
    if (track.isLocked) {
      SnackBarHelper.showInfo(
        context,
        'Unlock the Base layer before converting this clip.',
      );
      return;
    }

    final action = await showFixedEditorSheet<_ClipLongPressAction>(
      context: context,
      title: 'Base layer options',
      subtitle: 'Move this item without changing its timing or media',
      heightFactor: 0.3,
      builder: (sheetContext) => ListTile(
        key: const ValueKey('timeline_convert_to_overlay_action'),
        leading: const Icon(Icons.layers_outlined, color: kAccent),
        title: const Text('Convert to overlay'),
        subtitle: const Text('Move this item to a visual overlay track'),
        onTap: () =>
            Navigator.pop(sheetContext, _ClipLongPressAction.convertToOverlay),
      ),
    );
    if (!mounted || action != _ClipLongPressAction.convertToOverlay) return;
    _convertMainClipToOverlay(clip.id);
  }

  void _convertMainClipToOverlay(String clipId) {
    final timeline = ref.read(editorProvider).timeline;
    final selection = _selectedClipSelection(timeline, clipId);
    if (selection == null) return;
    final sourceTrack = selection.$1;
    final clip = selection.$2;
    if (sourceTrack.section != TimelineTrackSection.baseVideo ||
        sourceTrack.isLocked ||
        !clip.type.isVisualMedia) {
      return;
    }

    TimelineTrack? destination;
    TimelineClip? convertedClip;
    for (final candidateTrack in timeline.tracks) {
      if (candidateTrack.section != TimelineTrackSection.overlay ||
          candidateTrack.isLocked) {
        continue;
      }
      final candidate = clip.copyWith(trackId: candidateTrack.id);
      if (candidateTrack.canPlaceClip(candidate)) {
        destination = candidateTrack;
        convertedClip = candidate;
        break;
      }
    }

    EditorTimeline nextTimeline;
    if (destination == null || convertedClip == null) {
      final newTrack = TimelineTrack(
        name: timeline.nextTrackNameForSection(TimelineTrackSection.overlay),
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
      );
      destination = newTrack;
      convertedClip = clip.copyWith(trackId: newTrack.id);
      final withoutSourceClip = timeline.copyWith(
        tracks: timeline.tracks.map((track) {
          if (track.id != sourceTrack.id) return track;
          return track.copyWith(
            clips: track.clips
                .where((candidate) => candidate.id != clip.id)
                .toList(),
          );
        }).toList(),
      );
      nextTimeline = withoutSourceClip.insertTrackUsingEditorRules(
        newTrack.copyWith(clips: [convertedClip]),
      );
    } else {
      nextTimeline = timeline.copyWith(
        tracks: timeline.tracks.map((track) {
          if (track.id == sourceTrack.id) {
            return track.copyWith(
              clips: track.clips
                  .where((candidate) => candidate.id != clip.id)
                  .toList(),
            );
          }
          if (track.id == destination!.id) {
            final clips = [...track.clips, convertedClip!]
              ..sort((a, b) => a.startTime.compareTo(b.startTime));
            return track.copyWith(clips: clips);
          }
          return track;
        }).toList(),
      );
    }

    if (!_applyTimeline(nextTimeline)) return;
    ref.read(editorProvider.notifier)
      ..selectTrack(destination.id)
      ..selectClip(convertedClip.id);
  }

  Future<void> _deleteClip(EditorTimeline timeline, TimelineClip clip) async {
    final containingTrack = timeline.tracks.where(
      (track) => track.clips.any((candidate) => candidate.id == clip.id),
    );
    if (containingTrack.isNotEmpty && containingTrack.first.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track before deleting.');
      return;
    }
    final removedClipIds = <String>{
      clip.id,
      ...timeline.tracks
          .expand((track) => track.clips)
          .where((candidate) => candidate.linkedClipId == clip.id)
          .map((candidate) => candidate.id),
    };
    if (_wouldRemoveLastVisual(timeline, removedClipIds)) {
      await _showLastVisualGuard(clip);
      return;
    }
    final isRippleDelete =
        _rippleEditingEnabled &&
        containingTrack.isNotEmpty &&
        containingTrack.first.section == TimelineTrackSection.baseVideo;
    final rippleAmount = clip.duration;
    final nextTracks = timeline.tracks.map((track) {
      if (track.isLocked) {
        final dependentClips = track.clips
            .where((candidate) => candidate.linkedClipId != clip.id)
            .toList();
        return dependentClips.length == track.clips.length
            ? track
            : track.copyWith(clips: dependentClips);
      }
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

    _applyTimeline(
      timeline
          .copyWith(tracks: nextTracks, assets: nextAssets)
          .prunedRelationships(),
    );
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
    final nextStart = track.closestAvailableStart(
      desiredStart: clip.endTime,
      duration: clip.duration,
      latestEnd: Duration(milliseconds: timelineEndMs),
    );
    final nextStartMs = nextStart.inMilliseconds;
    final duplicate = clip.copyWith(
      id: const Uuid().v4(),
      trackId: track.id,
      startTime: Duration(milliseconds: nextStartMs),
      endTime: Duration(milliseconds: nextStartMs + durationMs),
      effectStack: clip.effectStack.cloneWithNewIds(),
      clearGroupId: true,
      clearCompoundId: true,
    );
    if (!track.canPlaceClip(duplicate)) {
      SnackBarHelper.showInfo(
        context,
        'There is no free space in this track for a duplicate.',
      );
      return;
    }

    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.id != track.id) return candidateTrack;
      final nextClips = [...candidateTrack.clips, duplicate]
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
      return candidateTrack.copyWith(clips: nextClips);
    }).toList();

    if (!_applyTimeline(timeline.copyWith(tracks: nextTracks))) return;
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
    final keyframeSplit = TimelineKeyframeEditing.split(
      clip,
      Duration(milliseconds: leftTimelineDurationMs),
    );
    final effectStackSplit = clip.effectStack.splitAt(
      Duration(milliseconds: leftTimelineDurationMs),
    );
    final firstClip = clip.copyWith(
      endTime: splitPoint,
      sourceStartTime: firstSourceStart,
      sourceDuration: Duration(milliseconds: leftSourceDurationMs),
      outroTransition: const ClipTransition(),
      keyframes: keyframeSplit.leading,
      effectStack: effectStackSplit.leading,
    );
    final secondClip = TimelineClip(
      trackId: track.id,
      type: clip.type,
      effectKind: clip.effectKind,
      effectStack: effectStackSplit.trailing,
      isAdjustmentLayer: clip.isAdjustmentLayer,
      groupId: clip.groupId,
      compoundId: clip.compoundId,
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
      keyframes: keyframeSplit.trailing,
      freezeFrame: clip.freezeFrame,
      freezeFrameSourceTime: clip.freezeFrameSourceTime,
      stabilize: clip.stabilize,
      denoise: clip.denoise,
      chromaKeyEnabled: clip.chromaKeyEnabled,
      chromaKeyColor: clip.chromaKeyColor,
      chromaKeySimilarity: clip.chromaKeySimilarity,
      timelineColor: clip.timelineColor,
      notes: clip.notes,
      autoDuck: clip.autoDuck,
      duckAmount: clip.duckAmount,
      duckAttackMs: clip.duckAttackMs,
      duckReleaseMs: clip.duckReleaseMs,
      duckSidechainTrackIds: clip.duckSidechainTrackIds,
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

    _applyTimeline(
      timeline.copyWith(
        tracks: nextTracks,
        groups: timeline.groups
            .map(
              (group) => group.id == clip.groupId
                  ? group.copyWith(clipIds: [...group.clipIds, secondClip.id])
                  : group,
            )
            .toList(),
        compoundClips: timeline.compoundClips
            .map(
              (compound) => compound.id == clip.compoundId
                  ? compound.copyWith(
                      clipIds: [...compound.clipIds, secondClip.id],
                    )
                  : compound,
            )
            .toList(),
      ),
    );
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
    final playback = ref.read(playbackProvider);
    ref
        .read(playbackProvider.notifier)
        .requestSeek(
          TimelineSnapEngine.adjacentFrame(
            playback.position,
            frameRate: workspace.frameRate,
            direction: direction,
          ),
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
    _ensureRenderIndex(timeline);
    final workspace = timeline.workspaceSettings;
    final fallbackDuration = _cachedRenderDuration;
    final totalDuration = playbackDuration > fallbackDuration
        ? playbackDuration
        : fallbackDuration;
    final selectedSelection = editorState.selectedClipId == null
        ? null
        : _cachedClipSelectionById[editorState.selectedClipId!];
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
        : _cachedClipSelectionById[selectedSubtitle.id]?.$1;
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
                    tooltip: workspace.snapping.enabled
                        ? 'Turn snapping off'
                        : 'Turn snapping on',
                    onPressed: () => editorNotifier.setSnappingEnabled(
                      !workspace.snapping.enabled,
                    ),
                    isActive: workspace.snapping.enabled,
                  ),
                  _buildToolbarButton(
                    icon: Icons.tune_rounded,
                    tooltip: 'Configure snapping targets',
                    onPressed: _showSnappingSettings,
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
                    onPressed:
                        workspace.workAreaStart == null &&
                            workspace.workAreaEnd == null
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
                        : () => _zoomBy(
                            0.8,
                            anchor: ref.read(playbackProvider).position,
                          ),
                  ),
                  _buildToolbarButton(
                    icon: Icons.center_focus_strong_rounded,
                    tooltip: 'Zoom to playhead',
                    onPressed: _pixelsPerSecond >= _maxPixelsPerSecond
                        ? () => _scrollToPlayhead(
                            ref.read(playbackProvider).position,
                          )
                        : () => _zoomBy(
                            2,
                            anchor: ref.read(playbackProvider).position,
                            centerAnchor: true,
                          ),
                  ),
                  _buildToolbarButton(
                    icon: Icons.select_all_rounded,
                    tooltip: 'Zoom to selection',
                    onPressed: _zoomToSelection,
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
                        : () => _zoomBy(
                            1.25,
                            anchor: ref.read(playbackProvider).position,
                          ),
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
                final horizontalViewportWidth =
                    _horizontalScrollController.hasClients
                    ? _horizontalScrollController.position.viewportDimension
                    : math.max(1.0, constraints.maxWidth - _labelColumnWidth);
                final horizontalOffset = _horizontalScrollController.hasClients
                    ? _horizontalScrollController.offset
                    : 0.0;
                final overscanPixels = math.max(
                  180.0,
                  horizontalViewportWidth * 0.35,
                );
                final viewportStart = Duration(
                  milliseconds:
                      ((horizontalOffset - overscanPixels) /
                              _pixelsPerSecond *
                              1000)
                          .floor()
                          .clamp(0, totalDuration.inMilliseconds)
                          .toInt(),
                );
                final viewportEnd = Duration(
                  milliseconds:
                      ((horizontalOffset +
                                  horizontalViewportWidth +
                                  overscanPixels) /
                              _pixelsPerSecond *
                              1000)
                          .ceil()
                          .clamp(0, totalDuration.inMilliseconds)
                          .toInt(),
                );
                final pinnedClipsByTrack = <String, List<TimelineClip>>{};
                void pinClip(String? clipId) {
                  if (clipId == null) return;
                  final selection = _cachedClipSelectionById[clipId];
                  if (selection == null) return;
                  pinnedClipsByTrack
                      .putIfAbsent(selection.$1.id, () => <TimelineClip>[])
                      .add(selection.$2);
                }

                pinClip(editorState.selectedClipId);
                pinClip(subtitleState.selectedEntryId);
                pinClip(_clipMoveSession?.clip.id);
                pinClip(_clipTrimSession?.clip.id);
                final visibleMarkers = _markersInWindow(
                  viewportStart,
                  viewportEnd,
                );
                final verticalViewportHeight =
                    _verticalScrollController.hasClients
                    ? _verticalScrollController.position.viewportDimension
                    : constraints.maxHeight;
                final verticalOffset = _verticalScrollController.hasClients
                    ? _verticalScrollController.offset
                    : 0.0;
                final verticalStart = math.max(0.0, verticalOffset - 100);
                final verticalEnd =
                    verticalOffset + verticalViewportHeight + 100;
                final pinnedTrackIds = pinnedClipsByTrack.keys.toSet();
                final visibleRowLayouts = rowLayouts
                    .where(
                      (row) =>
                          (row.bottom >= verticalStart &&
                              row.top <= verticalEnd) ||
                          (row.track != null &&
                              pinnedTrackIds.contains(row.track!.id)),
                    )
                    .toList(growable: false);
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
                              rowLayouts: visibleRowLayouts,
                              rulerHeight: _rulerHeight,
                              onAddTrack: _showAddTrackChooser,
                              onTrackTap: (track) {
                                editorNotifier.selectTrack(track.id);
                                editorNotifier.selectClip(null);
                                subtitleNotifier.selectEntry(null);
                              },
                              onShowTrackActions: _showTrackActions,
                              onTrackAdd: (track) {
                                switch (track.section) {
                                  case TimelineTrackSection.overlay:
                                    widget.onOverlayAddRequested?.call(track);
                                    break;
                                  case TimelineTrackSection.textSubtitle:
                                    if (track.type == TimelineTrackType.text) {
                                      widget.onTextAddRequested?.call(track);
                                    }
                                    break;
                                  case TimelineTrackSection.audio:
                                    widget.onAudioAddRequested?.call(track);
                                    break;
                                  case TimelineTrackSection.baseVideo:
                                    break;
                                }
                              },
                              onTrackReorderStart: () =>
                                  editorNotifier.beginTimelineGestureEdit(),
                              onTrackReorder: (sourceId, targetId) =>
                                  editorNotifier.reorderTrackTo(
                                    sourceId,
                                    targetId,
                                  ),
                              onTrackReorderEnd: () =>
                                  editorNotifier.endTimelineGestureEdit(),
                            ),
                          ),
                          Expanded(
                            child: SizedBox(
                              key: _horizontalViewportKey,
                              child: SingleChildScrollView(
                                controller: _horizontalScrollController,
                                scrollDirection: Axis.horizontal,
                                child: SizedBox(
                                  width: totalWidth,
                                  height: resolvedContentHeight,
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: Container(
                                          color: kSurfaceElevated,
                                        ),
                                      ),
                                      Positioned(
                                        top: _rulerHeight,
                                        left: 0,
                                        right: 0,
                                        bottom: 0,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {
                                            editorNotifier.selectClip(null);
                                            editorNotifier.selectTrack(null);
                                            subtitleNotifier.selectEntry(null);
                                          },
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
                                      for (final row in visibleRowLayouts) ...[
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
                                              sortedClips:
                                                  _cachedSortedClipsByTrackId[row
                                                      .track!
                                                      .id] ??
                                                  const [],
                                              viewportStart: viewportStart,
                                              viewportEnd: viewportEnd,
                                              pinnedClips:
                                                  pinnedClipsByTrack[row
                                                      .track!
                                                      .id] ??
                                                  const [],
                                              pixelsPerSecond: _pixelsPerSecond,
                                              selectedClipId:
                                                  editorState.selectedClipId,
                                              selectedClipIds:
                                                  editorState.selectedClipIds,
                                              selectedSubtitleId:
                                                  subtitleState.selectedEntryId,
                                              workspaceSettings:
                                                  timeline.workspaceSettings,
                                              waveformSourceByAssetId:
                                                  _cachedWaveformSourceByAssetId,
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
                                              onClipLongPress: (clip) =>
                                                  _handleClipLongPress(
                                                    row.track!,
                                                    clip,
                                                  ),
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
                                              onMainVideoAddRequested:
                                                  row.track!.section ==
                                                          TimelineTrackSection
                                                              .baseVideo &&
                                                      widget.onMainVideoAddRequested !=
                                                          null
                                                  ? () => widget
                                                        .onMainVideoAddRequested
                                                        ?.call(row.track!)
                                                  : null,
                                              onClipMoveStart: _beginClipMove,
                                              clipStateKey: _clipStateKey,
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
                                              onAudioFadeStart:
                                                  _beginAudioFadeEdit,
                                              onAudioFadeChanged:
                                                  (clip, fadeIn, durationMs) =>
                                                      _updateAudioFade(
                                                        clip.id,
                                                        fadeIn: fadeIn,
                                                        durationMs: durationMs,
                                                      ),
                                              onAudioFadeEnd: _endAudioFadeEdit,
                                            ),
                                          ),
                                      ],
                                      for (final marker in visibleMarkers)
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
    String? previousGroup;
    for (final track in timeline.tracks) {
      final group = switch (track.section) {
        TimelineTrackSection.overlay ||
        TimelineTrackSection.textSubtitle => 'Layers',
        TimelineTrackSection.baseVideo => 'Base',
        TimelineTrackSection.audio => 'Audio',
      };
      if (group != previousGroup) {
        layouts.add(
          _TrackRowLayout.sectionHeader(
            top: cursor,
            title: group,
            section: track.section,
          ),
        );
        cursor += _sectionHeaderHeight;
        previousGroup = group;
      }

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

    return layouts;
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

enum _TrackQuickAction { visibility, mute, solo, lock, delete }

enum _ClipLongPressAction { convertToOverlay }

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
  final ValueChanged<TimelineTrack> onTrackAdd;
  final VoidCallback onTrackReorderStart;
  final void Function(String sourceTrackId, String targetTrackId)
  onTrackReorder;
  final VoidCallback onTrackReorderEnd;

  const _TimelineLabels({
    required this.rowLayouts,
    required this.rulerHeight,
    required this.onAddTrack,
    required this.onTrackTap,
    required this.onShowTrackActions,
    required this.onTrackAdd,
    required this.onTrackReorderStart,
    required this.onTrackReorder,
    required this.onTrackReorderEnd,
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
                  onAdd:
                      row.track!.section == TimelineTrackSection.overlay ||
                          row.track!.section == TimelineTrackSection.audio ||
                          (row.track!.section ==
                                  TimelineTrackSection.textSubtitle &&
                              row.track!.type == TimelineTrackType.text)
                      ? () => onTrackAdd(row.track!)
                      : null,
                  onReorderStart: onTrackReorderStart,
                  onReorder: onTrackReorder,
                  onReorderEnd: onTrackReorderEnd,
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
  final VoidCallback? onAdd;
  final VoidCallback onReorderStart;
  final void Function(String sourceTrackId, String targetTrackId) onReorder;
  final VoidCallback onReorderEnd;

  const _CompactTrackLabel({
    required this.track,
    required this.onTap,
    required this.onShowActions,
    required this.onAdd,
    required this.onReorderStart,
    required this.onReorder,
    required this.onReorderEnd,
  });

  @override
  State<_CompactTrackLabel> createState() => _CompactTrackLabelState();
}

class _CompactTrackLabelState extends State<_CompactTrackLabel> {
  bool _isDragging = false;
  Offset? _actionPosition;
  DateTime? _lastTapAt;

  void _finishDrag() {
    if (!_isDragging) return;
    _isDragging = false;
    widget.onReorderEnd();
  }

  void _handleTap() {
    final now = DateTime.now();
    final previous = _lastTapAt;
    widget.onTap();
    if (previous != null &&
        now.difference(previous) <= const Duration(milliseconds: 340)) {
      _lastTapAt = null;
      widget.onShowActions(_actionPosition ?? Offset.zero);
      return;
    }
    _lastTapAt = now;
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final status = [
      if (track.isLocked) 'locked',
      if (track.isMuted) 'muted',
      if (track.isSolo) 'solo',
      if (track.isHidden) 'hidden',
    ];
    final statusLabel = status.isEmpty ? '' : ', ${status.join(', ')}';
    final displayName = track.displayName;
    final label = Tooltip(
      message:
          '$displayName$statusLabel\nHold to reorder • double-tap for controls',
      child: Semantics(
        button: true,
        label: '$displayName track$statusLabel',
        hint: track.isReorderable
            ? 'Tap to select. Hold to reorder. Double-tap for controls'
            : 'Tap to select. Double-tap for controls',
        child: GestureDetector(
          key: ValueKey('timeline_track_${track.id}'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _actionPosition = details.globalPosition,
          onTap: _handleTap,
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
                  if (widget.onAdd != null)
                    Positioned(
                      right: 1,
                      bottom: 1,
                      child: _TrackAddBadge(
                        key: ValueKey('timeline_track_add_${track.id}'),
                        onTap: widget.onAdd!,
                      ),
                    ),
                  if (track.isMuted)
                    const Positioned(
                      left: 3,
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
                  if (track.isSolo)
                    const Positioned(
                      left: 3,
                      top: 2,
                      child: Icon(
                        Icons.hearing_rounded,
                        size: 9,
                        color: kAccent,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (!track.isReorderable) return label;

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data != track.id && track.isReorderable,
      onMove: (details) {
        if (details.data == track.id || !track.isReorderable) return;
        widget.onReorder(details.data, track.id);
      },
      builder: (context, candidates, rejected) => LongPressDraggable<String>(
        data: track.id,
        maxSimultaneousDrags: 1,
        delay: const Duration(milliseconds: 260),
        hapticFeedbackOnStart: true,
        onDragStarted: () {
          _isDragging = true;
          widget.onReorderStart();
        },
        onDragEnd: (_) => _finishDrag(),
        onDraggableCanceled: (_, _) => _finishDrag(),
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            width: 44,
            height: 38,
            decoration: BoxDecoration(
              color: kSurfaceElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kAccent, width: 1.5),
              boxShadow: const [
                BoxShadow(color: Colors.black45, blurRadius: 10),
              ],
            ),
            child: Icon(_trackRailIcon(track), color: kAccent, size: 18),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: label),
        child: label,
      ),
    );
  }
}

class _TrackAddBadge extends StatefulWidget {
  final VoidCallback onTap;

  const _TrackAddBadge({super.key, required this.onTap});

  @override
  State<_TrackAddBadge> createState() => _TrackAddBadgeState();
}

class _TrackAddBadgeState extends State<_TrackAddBadge> {
  Offset? _origin;
  bool _moved = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Add to track',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          _origin = details.globalPosition;
          _moved = false;
        },
        onTapCancel: () {
          _origin = null;
          _moved = false;
        },
        onTapUp: (details) {
          final origin = _origin;
          if (origin != null &&
              (details.globalPosition - origin).distanceSquared > 25) {
            _moved = true;
          }
          if (!_moved) widget.onTap();
          _origin = null;
          _moved = false;
        },
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: kAccent,
            shape: BoxShape.circle,
            border: Border.all(color: kSurface, width: 1.5),
          ),
          child: const Icon(Icons.add_rounded, color: Colors.white, size: 12),
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
  final List<TimelineClip> sortedClips;
  final Duration viewportStart;
  final Duration viewportEnd;
  final List<TimelineClip> pinnedClips;
  final double pixelsPerSecond;
  final String? selectedClipId;
  final Set<String> selectedClipIds;
  final String? selectedSubtitleId;
  final TimelineWorkspaceSettings workspaceSettings;
  final Map<String, String> waveformSourceByAssetId;
  final VoidCallback onTrackTap;
  final ValueChanged<Offset> onShowTrackActions;
  final ValueChanged<TimelineClip> onClipTap;
  final ValueChanged<TimelineClip> onClipLongPress;
  final ValueChanged<TimelineClip> onTransitionTap;
  final VoidCallback? onMainVideoAddRequested;
  final bool Function(TimelineClip clip) canClipMoveVertically;
  final GlobalKey Function(String clipId) clipStateKey;
  final void Function(TimelineClip clip, Offset pointerOrigin) onClipMoveStart;
  final void Function(TimelineClip clip, Offset pointerPosition) onClipMove;
  final ValueChanged<TimelineClip> onClipMoveEnd;
  final void Function(TimelineClip clip, _TrimEdge edge, Offset pointerOrigin)
  onClipTrimGestureStart;
  final ValueChanged<TimelineClip> onClipTrimGestureEnd;
  final void Function(TimelineClip clip, Offset delta) onClipTrimStart;
  final void Function(TimelineClip clip, Offset delta) onClipTrimEnd;
  final VoidCallback onAudioFadeStart;
  final void Function(TimelineClip clip, bool fadeIn, int durationMs)
  onAudioFadeChanged;
  final VoidCallback onAudioFadeEnd;

  const _TimelineLane({
    required this.track,
    required this.sortedClips,
    required this.viewportStart,
    required this.viewportEnd,
    required this.pinnedClips,
    required this.pixelsPerSecond,
    required this.selectedClipId,
    required this.selectedClipIds,
    required this.selectedSubtitleId,
    required this.workspaceSettings,
    required this.waveformSourceByAssetId,
    required this.onTrackTap,
    required this.onShowTrackActions,
    required this.onClipTap,
    required this.onClipLongPress,
    required this.onTransitionTap,
    required this.onMainVideoAddRequested,
    required this.canClipMoveVertically,
    required this.clipStateKey,
    required this.onClipMoveStart,
    required this.onClipMove,
    required this.onClipMoveEnd,
    required this.onClipTrimGestureStart,
    required this.onClipTrimGestureEnd,
    required this.onClipTrimStart,
    required this.onClipTrimEnd,
    required this.onAudioFadeStart,
    required this.onAudioFadeChanged,
    required this.onAudioFadeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final visibleClips = timelineVisibleClipsForTesting(
      sortedClips: sortedClips,
      viewportStart: viewportStart,
      viewportEnd: viewportEnd,
      pinnedClips: pinnedClips,
    );
    bool selectedForPaint(TimelineClip clip) =>
        selectedClipId == clip.id ||
        selectedSubtitleId == clip.id ||
        selectedClipIds.contains(clip.id);
    final paintOrderedClips = [
      ...visibleClips.where((clip) => !selectedForPaint(clip)),
      ...visibleClips.where(selectedForPaint),
    ];
    final transitionSources = _visibleTransitionSources();

    return _DoubleTapTrackSurface(
      onTap: onTrackTap,
      onShowActions: onShowTrackActions,
      child: Opacity(
        opacity: track.isHidden ? 0.42 : 1,
        child: Container(
          key: ValueKey('timeline_lane_${track.id}'),
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
              // Selected clips paint last so their enlarged trim targets stay
              // above neighboring clips at cuts and short overlaps.
              for (final clip in paintOrderedClips) _buildPositionedClip(clip),
              if (track.section == TimelineTrackSection.baseVideo)
                for (final clip in transitionSources)
                  Positioned(
                    left:
                        clip.endTime.inMilliseconds / 1000 * pixelsPerSecond -
                        10,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: GestureDetector(
                        onTap: () => onTransitionTap(clip),
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
              if (track.section == TimelineTrackSection.baseVideo &&
                  !track.isLocked &&
                  onMainVideoAddRequested != null)
                Positioned(
                  left: sortedClips.isEmpty
                      ? 0
                      : sortedClips.last.endTime.inMilliseconds /
                            1000 *
                            pixelsPerSecond,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Semantics(
                      key: ValueKey('timeline_main_video_add_${track.id}'),
                      button: true,
                      label: 'Add media to the Base layer',
                      child: Tooltip(
                        message: 'Add media to Base layer',
                        child: GestureDetector(
                          key: const ValueKey('timeline_main_video_add_button'),
                          behavior: HitTestBehavior.opaque,
                          onTap: onMainVideoAddRequested,
                          child: Container(
                            width: 34,
                            height: 28,
                            decoration: BoxDecoration(
                              color: kSurfaceElevated,
                              border: Border.all(color: kAccent),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.add_rounded,
                              size: 17,
                              color: kAccent,
                            ),
                          ),
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

  List<TimelineClip> _visibleTransitionSources() {
    if (sortedClips.length < 2) return const [];
    var lower = 0;
    var upper = sortedClips.length - 1;
    while (lower < upper) {
      final middle = lower + ((upper - lower) >> 1);
      if (sortedClips[middle].endTime < viewportStart) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    final visible = <TimelineClip>[];
    for (var index = lower; index < sortedClips.length - 1; index++) {
      final clip = sortedClips[index];
      if (clip.endTime > viewportEnd) break;
      visible.add(clip);
    }
    return visible;
  }

  Widget _buildPositionedClip(TimelineClip clip) {
    final visualWidth = math.max(
      1.0,
      clip.duration.inMilliseconds / 1000 * pixelsPerSecond,
    );
    final isSelected =
        selectedClipId == clip.id || selectedSubtitleId == clip.id;
    final isMultiSelected = selectedClipIds.contains(clip.id);
    final showTrimTargets =
        (isSelected || isMultiSelected) &&
        !track.isCollapsed &&
        !track.isLocked;
    final hitWidth = math.max(
      28.0,
      visualWidth + (showTrimTargets ? 44.0 : 0.0),
    );
    final visibleInset = (hitWidth - visualWidth) / 2;
    final startX = clip.startTime.inMilliseconds / 1000 * pixelsPerSecond;
    return Positioned(
      left: startX - visibleInset,
      top: 3,
      width: hitWidth,
      bottom: 3,
      child: KeyedSubtree(
        key: ValueKey('timeline_clip_${clip.id}'),
        child: _TimelineClipBlock(
          key: clipStateKey(clip.id),
          clip: clip,
          visualWidth: visualWidth,
          isSelected: isSelected || isMultiSelected,
          showWaveform: workspaceSettings.showWaveforms,
          showThumbnail: workspaceSettings.showThumbnails,
          showTimecode: workspaceSettings.showTimecode,
          showKeyframes: workspaceSettings.showKeyframes,
          showClipLabel: workspaceSettings.showClipLabels,
          waveformSourcePath: waveformSourceByAssetId[clip.assetId],
          showTrimHandles: isSelected && !track.isCollapsed,
          isLocked: track.isLocked,
          canMove: !track.isLocked,
          canMoveVertically: canClipMoveVertically(clip),
          onMoveStart: (position) => onClipMoveStart(clip, position),
          onTap: () => onClipTap(clip),
          onLongPress: () => onClipLongPress(clip),
          onMoveUpdate: (delta) => onClipMove(clip, delta),
          onMoveEnd: () => onClipMoveEnd(clip),
          onTrimGestureStart: (edge, pointerOrigin) =>
              onClipTrimGestureStart(clip, edge, pointerOrigin),
          onTrimGestureEnd: () => onClipTrimGestureEnd(clip),
          onTrimStartUpdate: (pointerPosition) =>
              onClipTrimStart(clip, pointerPosition),
          onTrimEndUpdate: (pointerPosition) =>
              onClipTrimEnd(clip, pointerPosition),
          onAudioFadeStart: onAudioFadeStart,
          onAudioFadeChanged: (fadeIn, durationMs) =>
              onAudioFadeChanged(clip, fadeIn, durationMs),
          onAudioFadeEnd: onAudioFadeEnd,
        ),
      ),
    );
  }

  String _emptyTrackHint(TimelineTrack track) {
    switch (track.section) {
      case TimelineTrackSection.overlay:
        return 'Add photos, GIFs, blur, filters, or other overlays';
      case TimelineTrackSection.baseVideo:
        return 'Add a video, photo, or GIF to the Base layer';
      case TimelineTrackSection.textSubtitle:
        return track.type == TimelineTrackType.subtitle
            ? 'Generated subtitles for clips appear here'
            : 'Add text layers here';
      case TimelineTrackSection.audio:
        return track.role == TimelineTrackRole.sourceAudio
            ? 'Video audio'
            : 'Add music, voiceover, or sound effects';
    }
  }
}

/// Waits for a deliberate hold before claiming a clip edit. Until the hold is
/// recognized, the surrounding timeline scroll views remain free to win the
/// gesture arena, so a swipe that starts over a clip still scrolls normally.
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
  bool _isActivated = false;
  bool _didMove = false;

  void _activate(LongPressStartDetails details) {
    _isActivated = true;
    _didMove = false;
    setState(() {});
    Feedback.forLongPress(context);
    widget.onMoveStart(details.globalPosition);
  }

  void _update(LongPressMoveUpdateDetails details) {
    if (!_isActivated) return;
    final offset = widget.canMoveVertically
        ? details.offsetFromOrigin
        : Offset(details.offsetFromOrigin.dx, 0);
    if (!_didMove && offset.distance < _timelineEditMovementSlop) return;
    _didMove = true;
    widget.onMoveUpdate(details.globalPosition);
  }

  void _finish() {
    if (!_isActivated) return;
    final shouldOpenLongPressAction = !_didMove;
    widget.onMoveEnd();
    _resetGesture();
    if (shouldOpenLongPressAction) widget.onLongPress();
  }

  void _cancel() {
    if (_isActivated) widget.onMoveEnd();
    _resetGesture();
  }

  void _resetGesture() {
    _isActivated = false;
    _didMove = false;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.canMove) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
      );
    }
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              TapGestureRecognizer.new,
              (recognizer) => recognizer.onTap = widget.onTap,
            ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: timelineEditHoldDurationForTesting,
              ),
              (recognizer) {
                recognizer.onLongPressStart = _activate;
                recognizer.onLongPressMoveUpdate = _update;
                recognizer.onLongPressEnd = (_) => _finish();
                recognizer.onLongPressCancel = _cancel;
              },
            ),
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        decoration: BoxDecoration(
          color: _isActivated
              ? kAccent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: _isActivated
              ? Border.all(color: kAccent.withValues(alpha: 0.72))
              : null,
        ),
      ),
    );
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
  final String? waveformSourcePath;
  final bool showTrimHandles;
  final bool isLocked;
  final bool canMove;
  final bool canMoveVertically;
  final ValueChanged<Offset> onMoveStart;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final void Function(_TrimEdge edge, Offset pointerOrigin) onTrimGestureStart;
  final VoidCallback onTrimGestureEnd;
  final ValueChanged<Offset> onTrimStartUpdate;
  final ValueChanged<Offset> onTrimEndUpdate;
  final VoidCallback onAudioFadeStart;
  final void Function(bool fadeIn, int durationMs) onAudioFadeChanged;
  final VoidCallback onAudioFadeEnd;

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
    required this.waveformSourcePath,
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
    required this.onAudioFadeStart,
    required this.onAudioFadeChanged,
    required this.onAudioFadeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _clipColors(clip);
    final badges = _visualBadges(clip);
    const handleHitWidth = 44.0;

    return Semantics(
      button: true,
      selected: isSelected,
      label: _clipSemanticsLabel(clip, badges),
      hint: canMove ? 'Hold, then drag to move' : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final resolvedVisualWidth = visualWidth
              .clamp(1.0, constraints.maxWidth)
              .toDouble();
          final visibleLeft = (constraints.maxWidth - resolvedVisualWidth) / 2;
          final showUsableTrimHandles = showTrimHandles && !isLocked;
          final showAudioFadeHandles =
              isSelected && !isLocked && clip.type == TimelineTrackType.audio;
          final moveHitLeft = showUsableTrimHandles
              ? visibleLeft + handleHitWidth / 2
              : 0.0;
          final moveHitWidth = showUsableTrimHandles
              ? math.max(0.0, resolvedVisualWidth - handleHitWidth)
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
                            child: _CachedTimelineWaveform(
                              clip: clip,
                              sourcePath: waveformSourcePath,
                              targetWidth: resolvedVisualWidth,
                              color: colors.$2.withValues(alpha: 0.35),
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
                      key: ValueKey('timeline_trim_start_${clip.id}'),
                      edge: _TrimEdge.start,
                      isSelected: isSelected,
                      onGestureStart: (pointerOrigin) =>
                          onTrimGestureStart(_TrimEdge.start, pointerOrigin),
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
                      key: ValueKey('timeline_trim_end_${clip.id}'),
                      edge: _TrimEdge.end,
                      isSelected: isSelected,
                      onGestureStart: (pointerOrigin) =>
                          onTrimGestureStart(_TrimEdge.end, pointerOrigin),
                      onGestureEnd: onTrimGestureEnd,
                      onUpdate: onTrimEndUpdate,
                    ),
                  ),
                if (showAudioFadeHandles)
                  _AudioFadeHandle(
                    key: ValueKey('timeline_fade_in_${clip.id}'),
                    fadeIn: true,
                    visibleLeft: visibleLeft,
                    visualWidth: resolvedVisualWidth,
                    clipDurationMs: clip.duration.inMilliseconds,
                    fadeDurationMs: clip.audioMix.fadeInMs,
                    onStart: onAudioFadeStart,
                    onChanged: (value) => onAudioFadeChanged(true, value),
                    onEnd: onAudioFadeEnd,
                  ),
                if (showAudioFadeHandles)
                  _AudioFadeHandle(
                    key: ValueKey('timeline_fade_out_${clip.id}'),
                    fadeIn: false,
                    visibleLeft: visibleLeft,
                    visualWidth: resolvedVisualWidth,
                    clipDurationMs: clip.duration.inMilliseconds,
                    fadeDurationMs: clip.audioMix.fadeOutMs,
                    onStart: onAudioFadeStart,
                    onChanged: (value) => onAudioFadeChanged(false, value),
                    onEnd: onAudioFadeEnd,
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

class _AudioFadeHandle extends StatefulWidget {
  final bool fadeIn;
  final double visibleLeft;
  final double visualWidth;
  final int clipDurationMs;
  final int fadeDurationMs;
  final VoidCallback onStart;
  final ValueChanged<int> onChanged;
  final VoidCallback onEnd;

  const _AudioFadeHandle({
    super.key,
    required this.fadeIn,
    required this.visibleLeft,
    required this.visualWidth,
    required this.clipDurationMs,
    required this.fadeDurationMs,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
  });

  @override
  State<_AudioFadeHandle> createState() => _AudioFadeHandleState();
}

class _AudioFadeHandleState extends State<_AudioFadeHandle> {
  double? _dragDurationMs;

  void _start(DragStartDetails details) {
    _dragDurationMs = widget.fadeDurationMs.toDouble();
    widget.onStart();
  }

  void _update(DragUpdateDetails details) {
    final width = math.max(1.0, widget.visualWidth);
    final maximumFadeMs = math.max(0, widget.clipDurationMs ~/ 2);
    final direction = widget.fadeIn ? 1.0 : -1.0;
    final deltaMs =
        (details.primaryDelta ?? 0) / width * widget.clipDurationMs * direction;
    final next = ((_dragDurationMs ?? widget.fadeDurationMs) + deltaMs).clamp(
      0.0,
      maximumFadeMs.toDouble(),
    );
    _dragDurationMs = next;
    widget.onChanged(next.round());
    setState(() {});
  }

  void _finish() {
    _dragDurationMs = null;
    widget.onEnd();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final maximumFadeMs = math.max(0, widget.clipDurationMs ~/ 2);
    final durationMs = (_dragDurationMs ?? widget.fadeDurationMs).clamp(
      0.0,
      maximumFadeMs.toDouble(),
    );
    final offset = widget.clipDurationMs <= 0
        ? 0.0
        : durationMs / widget.clipDurationMs * widget.visualWidth;
    final centerX = widget.fadeIn
        ? widget.visibleLeft + offset
        : widget.visibleLeft + widget.visualWidth - offset;
    return Positioned(
      left: centerX - 15,
      top: 0,
      height: 28,
      width: 30,
      child: Semantics(
        slider: true,
        label: widget.fadeIn ? 'Audio fade in' : 'Audio fade out',
        value: '${durationMs.round()} milliseconds',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _start,
          onHorizontalDragUpdate: _update,
          onHorizontalDragEnd: (_) => _finish(),
          onHorizontalDragCancel: _finish,
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: kSuccess,
                shape: BoxShape.circle,
                border: Border.all(color: kTextPrimary, width: 1.5),
                boxShadow: const [
                  BoxShadow(color: Colors.black45, blurRadius: 3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
    const highY = 3.5;
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

class _CachedTimelineWaveform extends StatefulWidget {
  final TimelineClip clip;
  final String? sourcePath;
  final double targetWidth;
  final Color color;

  const _CachedTimelineWaveform({
    required this.clip,
    required this.sourcePath,
    required this.targetWidth,
    required this.color,
  });

  @override
  State<_CachedTimelineWaveform> createState() =>
      _CachedTimelineWaveformState();
}

class _CachedTimelineWaveformState extends State<_CachedTimelineWaveform> {
  Future<String>? _waveform;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CachedTimelineWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    final resolutionChanged =
        (_resolutionFor(oldWidget.targetWidth) -
                _resolutionFor(widget.targetWidth))
            .abs() >=
        128;
    if (oldWidget.sourcePath != widget.sourcePath ||
        oldWidget.clip.sourceStartTime != widget.clip.sourceStartTime ||
        oldWidget.clip.sourceDuration != widget.clip.sourceDuration ||
        resolutionChanged) {
      _load();
    }
  }

  void _load() {
    final sourcePath = widget.sourcePath;
    if (sourcePath == null ||
        sourcePath.trim().isEmpty ||
        !File(sourcePath).existsSync()) {
      _waveform = null;
      return;
    }
    final sourceDuration = widget.clip.sourceDuration > Duration.zero
        ? widget.clip.sourceDuration
        : Duration(
            microseconds:
                (widget.clip.duration.inMicroseconds * widget.clip.playbackRate)
                    .round(),
          );
    _waveform = TimelineWaveformCache.instance.waveformFor(
      sourcePath: sourcePath,
      sourceStart: widget.clip.sourceStartTime,
      sourceDuration: sourceDuration,
      width: _resolutionFor(widget.targetWidth),
      height: 72,
    );
  }

  int _resolutionFor(double logicalWidth) {
    return (logicalWidth * 2).round().clamp(128, 16384).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final fallback = CustomPaint(
      painter: _WaveformPainter(
        seed: widget.clip.id.hashCode,
        color: widget.color,
      ),
      child: const SizedBox.expand(),
    );
    final waveform = _waveform;
    if (waveform == null) return fallback;
    return FutureBuilder<String>(
      future: waveform,
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path == null || path.isEmpty) return fallback;
        return Image.file(
          File(path),
          fit: BoxFit.fill,
          color: widget.color,
          colorBlendMode: BlendMode.srcIn,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, _, _) => fallback,
        );
      },
    );
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

class _TrimHandle extends StatefulWidget {
  final _TrimEdge edge;
  final bool isSelected;
  final ValueChanged<Offset> onGestureStart;
  final VoidCallback onGestureEnd;
  final ValueChanged<Offset> onUpdate;

  const _TrimHandle({
    super.key,
    required this.edge,
    required this.isSelected,
    required this.onGestureStart,
    required this.onGestureEnd,
    required this.onUpdate,
  });

  @override
  State<_TrimHandle> createState() => _TrimHandleState();
}

class _TrimHandleState extends State<_TrimHandle> {
  bool _isActivated = false;
  bool _didMove = false;

  void _activate(LongPressStartDetails details) {
    _isActivated = true;
    _didMove = false;
    setState(() {});
    Feedback.forLongPress(context);
    widget.onGestureStart(details.globalPosition);
  }

  void _update(LongPressMoveUpdateDetails details) {
    if (!_isActivated) return;
    if (!_didMove &&
        details.offsetFromOrigin.dx.abs() < _timelineEditMovementSlop) {
      return;
    }
    _didMove = true;
    widget.onUpdate(details.globalPosition);
  }

  void _finish() {
    if (!_isActivated) return;
    widget.onGestureEnd();
    _resetGesture();
  }

  void _cancel() {
    if (_isActivated) widget.onGestureEnd();
    _resetGesture();
  }

  void _resetGesture() {
    _isActivated = false;
    _didMove = false;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.edge == _TrimEdge.start ? 'start' : 'end';
    return Semantics(
      button: true,
      label: 'Trim clip $action',
      hint: 'Hold, then drag to change the clip $action',
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: timelineEditHoldDurationForTesting,
                ),
                (recognizer) {
                  recognizer.onLongPressStart = _activate;
                  recognizer.onLongPressMoveUpdate = _update;
                  recognizer.onLongPressEnd = (_) => _finish();
                  recognizer.onLongPressCancel = _cancel;
                },
              ),
        },
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            width: 12,
            height: double.infinity,
            decoration: BoxDecoration(
              color: kAccent.withValues(
                alpha: _isActivated ? 1 : (widget.isSelected ? 0.96 : 0.45),
              ),
              boxShadow: _isActivated
                  ? [
                      BoxShadow(
                        color: kAccent.withValues(alpha: 0.45),
                        blurRadius: 7,
                      ),
                    ]
                  : null,
              borderRadius: BorderRadius.horizontal(
                left: widget.edge == _TrimEdge.start
                    ? const Radius.circular(5)
                    : Radius.zero,
                right: widget.edge == _TrimEdge.end
                    ? const Radius.circular(5)
                    : Radius.zero,
              ),
            ),
            child: Icon(
              widget.edge == _TrimEdge.start
                  ? Icons.chevron_left_rounded
                  : Icons.chevron_right_rounded,
              size: 14,
              color: Colors.white,
            ),
          ),
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

    final sampleLabel = showTimecode ? '00:00:00' : '0000';
    final samplePainter = TextPainter(
      text: TextSpan(text: sampleLabel, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final interval = timelineRulerLabelIntervalForTesting(
      pixelsPerSecond: pixelsPerSecond,
      minimumLabelSpacing: samplePainter.width + 14,
    );
    final intervalMs = math.max(1, interval.inMilliseconds);
    final minorIntervalMs = math.max(1, intervalMs ~/ 5);
    final totalMs = totalDuration.inMilliseconds;

    for (var millis = 0; millis <= totalMs; millis += minorIntervalMs) {
      final isMajor = millis % intervalMs == 0;
      final x = millis / 1000 * pixelsPerSecond;
      canvas.drawLine(
        Offset(x, size.height - (isMajor ? 8 : 4)),
        Offset(x, size.height),
        paint,
      );

      if (!isMajor) continue;

      final label = showTimecode
          ? _timecode(Duration(milliseconds: millis), frameRate)
          : _compactTime(Duration(milliseconds: millis));
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

  String _compactTime(Duration duration) {
    final seconds = duration.inMilliseconds / 1000;
    return seconds == seconds.roundToDouble()
        ? '${seconds.round()}s'
        : '${seconds.toStringAsFixed(1)}s';
  }
}

class _ClipMoveSession {
  final EditorTimeline timeline;
  final TimelineTrack track;
  final TimelineClip clip;
  final Offset pointerOrigin;
  Offset cumulativeDelta = Offset.zero;
  double scrollCompensationDx = 0;

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
  final _TrimEdge edge;
  final Offset pointerOrigin;
  Offset cumulativeDelta = Offset.zero;
  double scrollCompensationDx = 0;

  _ClipTrimSession({
    required this.timeline,
    required this.track,
    required this.clip,
    required this.edge,
    required this.pointerOrigin,
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
