import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../models/timeline_models.dart';
import 'editor_history_clock.dart';
import 'subtitle_provider.dart';

/// High-level editor state (current project info, video path, etc.)
class EditorState {
  final String? videoPath;
  final String? projectId;
  final String? projectName;
  final bool isProcessing;
  final String? waveformPath;
  final EditorTimeline timeline;
  final EditorBottomPanel activePanel;
  final String? selectedTrackId;
  final String? selectedClipId;
  final bool isSnappingEnabled;
  final bool canUndo;
  final bool canRedo;
  final int editRevision;

  const EditorState({
    this.videoPath,
    this.projectId,
    this.projectName,
    this.isProcessing = false,
    this.waveformPath,
    this.timeline = const EditorTimeline(),
    this.activePanel = EditorBottomPanel.timeline,
    this.selectedTrackId,
    this.selectedClipId,
    this.isSnappingEnabled = true,
    this.canUndo = false,
    this.canRedo = false,
    this.editRevision = 0,
  });

  EditorState copyWith({
    String? videoPath,
    String? projectId,
    String? projectName,
    bool? isProcessing,
    String? waveformPath,
    EditorTimeline? timeline,
    EditorBottomPanel? activePanel,
    String? selectedTrackId,
    String? selectedClipId,
    bool? isSnappingEnabled,
    bool? canUndo,
    bool? canRedo,
    int? editRevision,
    bool clearTrackSelection = false,
    bool clearClipSelection = false,
  }) {
    return EditorState(
      videoPath: videoPath ?? this.videoPath,
      projectId: projectId ?? this.projectId,
      projectName: projectName ?? this.projectName,
      isProcessing: isProcessing ?? this.isProcessing,
      waveformPath: waveformPath ?? this.waveformPath,
      timeline: timeline ?? this.timeline,
      activePanel: activePanel ?? this.activePanel,
      selectedTrackId: clearTrackSelection
          ? null
          : (selectedTrackId ?? this.selectedTrackId),
      selectedClipId: clearClipSelection
          ? null
          : (selectedClipId ?? this.selectedClipId),
      isSnappingEnabled: isSnappingEnabled ?? this.isSnappingEnabled,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      editRevision: editRevision ?? this.editRevision,
    );
  }
}

enum EditorBottomPanel {
  timeline,
  text,
  media,
  audio,
  stickers,
  transitions,
  style,
}

class _EditorHistorySnapshot {
  final EditorTimeline timeline;
  final List<SubtitleEntry> subtitleEntries;
  final SubtitleStyleModel subtitleStyle;
  final String? selectedTrackId;
  final String? selectedClipId;
  final String? selectedSubtitleId;
  final int sequence;
  final int branch;

  const _EditorHistorySnapshot({
    required this.timeline,
    required this.subtitleEntries,
    required this.subtitleStyle,
    required this.selectedTrackId,
    required this.selectedClipId,
    required this.selectedSubtitleId,
    required this.sequence,
    required this.branch,
  });
}

class EditorNotifier extends StateNotifier<EditorState> {
  final Ref _ref;
  final List<_EditorHistorySnapshot> _undoStack = [];
  final List<_EditorHistorySnapshot> _redoStack = [];
  bool _isTimelineGestureEditing = false;
  bool _timelineChangedDuringGesture = false;
  bool _isRestoringEditorSubtitleState = false;
  late final EditorHistoryClock _historyClock = _ref.read(
    editorHistoryClockProvider,
  );

  static const int _maxHistoryDepth = 100;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo =>
      _redoStack.isNotEmpty && _redoStack.last.branch == _historyClock.branch;
  int? get latestUndoSequence => canUndo ? _undoStack.last.sequence : null;
  int? get latestRedoSequence => canRedo ? _redoStack.last.sequence : null;

  EditorNotifier(this._ref) : super(const EditorState()) {
    _ref.listen<SubtitleState>(subtitleProvider, (_, next) {
      _synchronizeTimelineFromSubtitles(next);
    });
  }

  void loadProject({
    required String videoPath,
    required String projectId,
    required String projectName,
    EditorTimeline timeline = const EditorTimeline(),
  }) {
    _undoStack.clear();
    _redoStack.clear();
    _isTimelineGestureEditing = false;
    _timelineChangedDuringGesture = false;
    state = state.copyWith(
      videoPath: videoPath,
      projectId: projectId,
      projectName: projectName,
      timeline: timeline,
      canUndo: false,
      canRedo: false,
      editRevision: 0,
      clearTrackSelection: true,
      clearClipSelection: true,
    );
  }

  void setProcessing(bool processing) {
    state = state.copyWith(isProcessing: processing);
  }

  void setWaveformPath(String path) {
    state = state.copyWith(waveformPath: path);
  }

  void setTimeline(EditorTimeline timeline, {bool recordHistory = true}) {
    if (identical(state.timeline, timeline)) return;
    if (_isTimelineGestureEditing) {
      // Gesture callers pass recordHistory:false for their live intermediate
      // values. The first actual change still needs one baseline snapshot so
      // the completed slider/drag remains a single undoable action.
      if (!_timelineChangedDuringGesture) _pushUndoSnapshot();
      _timelineChangedDuringGesture = true;
    } else if (recordHistory) {
      _pushUndoSnapshot();
    }
    state = state.copyWith(
      timeline: timeline,
      canUndo: canUndo,
      canRedo: canRedo,
      // Preview widgets still rebuild from the live timeline during a gesture,
      // but expensive media re-seeks are deferred until the edit is committed.
      editRevision: _isTimelineGestureEditing
          ? state.editRevision
          : state.editRevision + 1,
    );
  }

  /// Replaces the complete caption track as one editor-wide history action.
  ///
  /// Caption batch tools must capture history before mutating [subtitleProvider].
  /// Calling `loadSubtitles` followed by [setTimeline] records the already-mutated
  /// subtitle state and makes the visible caption change impossible to undo from
  /// the editor toolbar. This method keeps both representations in lockstep.
  bool replaceSubtitleEntries(List<SubtitleEntry> entries) {
    final subtitleTracks = state.timeline.tracks.where(
      (track) => track.type == TimelineTrackType.subtitle,
    );
    if (subtitleTracks.any((track) => track.isLocked)) return false;
    final subtitleState = _ref.read(subtitleProvider);
    final sortedEntries = List<SubtitleEntry>.from(entries)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final nextTimeline = state.timeline.mergeSubtitleEntries(
      subtitles: sortedEntries,
      globalStyle: subtitleState.globalStyle,
    );

    replaceTimelineAndSubtitleEntries(
      timeline: nextTimeline,
      entries: sortedEntries,
    );
    return true;
  }

  /// Commits timeline and caption representations as one editor history step.
  ///
  /// Generation/import workflows often have an explicitly chosen subtitle
  /// lane, so rebuilding the primary lane here would lose that routing. This
  /// variant preserves the prepared timeline while keeping undo atomic.
  void replaceTimelineAndSubtitleEntries({
    required EditorTimeline timeline,
    required List<SubtitleEntry> entries,
  }) {
    final subtitleState = _ref.read(subtitleProvider);
    final sortedEntries = List<SubtitleEntry>.from(entries)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final selectedEntryId = subtitleState.selectedEntryId;

    _pushUndoSnapshot();
    _restoreEditorSubtitleState(
      entries: sortedEntries,
      globalStyle: subtitleState.globalStyle,
      selectedEntryId: selectedEntryId,
    );
    state = state.copyWith(
      timeline: timeline,
      canUndo: canUndo,
      canRedo: canRedo,
      editRevision: state.editRevision + 1,
    );
  }

  void beginTimelineGestureEdit() {
    if (_isTimelineGestureEditing) return;
    _isTimelineGestureEditing = true;
    _timelineChangedDuringGesture = false;
  }

  void endTimelineGestureEdit() {
    final shouldNotifyPreview = _timelineChangedDuringGesture;
    _isTimelineGestureEditing = false;
    _timelineChangedDuringGesture = false;
    state = state.copyWith(
      canUndo: canUndo,
      canRedo: canRedo,
      editRevision: shouldNotifyPreview
          ? state.editRevision + 1
          : state.editRevision,
    );
  }

  void undo() {
    if (!canUndo) return;
    final previous = _undoStack.removeLast();
    final current = _captureSnapshot(
      sequence: _historyClock.recordTraversal(),
      branch: _historyClock.branch,
    );
    _redoStack.add(current);
    _restoreSnapshot(previous);
  }

  void redo() {
    if (!canRedo) return;
    final next = _redoStack.removeLast();
    final current = _captureSnapshot(
      sequence: _historyClock.recordTraversal(),
      branch: _historyClock.branch,
    );
    _undoStack.add(current);
    _restoreSnapshot(next);
  }

  void clearHistory() {
    _undoStack.clear();
    _redoStack.clear();
    _isTimelineGestureEditing = false;
    _timelineChangedDuringGesture = false;
    _refreshHistoryFlags();
  }

  void setActivePanel(EditorBottomPanel panel) {
    state = state.copyWith(activePanel: panel);
  }

  void selectTrack(String? trackId) {
    final targetTrack = trackId == null
        ? null
        : state.timeline.tracks
              .where((track) => track.id == trackId)
              .firstOrNull;
    final selectedClipBelongsToTrack =
        targetTrack != null &&
        state.selectedClipId != null &&
        targetTrack.clips.any((clip) => clip.id == state.selectedClipId);
    final nextSelectedClipId = selectedClipBelongsToTrack
        ? state.selectedClipId
        : null;
    final nextSubtitleId =
        selectedClipBelongsToTrack &&
            targetTrack.type == TimelineTrackType.subtitle
        ? state.selectedClipId
        : null;
    if (state.selectedTrackId == trackId &&
        state.selectedClipId == nextSelectedClipId &&
        _ref.read(subtitleProvider).selectedEntryId == nextSubtitleId) {
      return;
    }
    _ref.read(subtitleProvider.notifier).selectEntry(nextSubtitleId);
    state = state.copyWith(
      selectedTrackId: trackId,
      clearTrackSelection: trackId == null,
      clearClipSelection:
          state.selectedClipId != null && !selectedClipBelongsToTrack,
    );
  }

  void selectClip(String? clipId) {
    TimelineClip? selectedClip;
    if (clipId != null) {
      for (final track in state.timeline.tracks) {
        for (final clip in track.clips) {
          if (clip.id == clipId) {
            selectedClip = clip;
            break;
          }
        }
        if (selectedClip != null) break;
      }
    }
    final nextSubtitleId = selectedClip?.type == TimelineTrackType.subtitle
        ? clipId
        : null;
    if (state.selectedClipId == clipId &&
        _ref.read(subtitleProvider).selectedEntryId == nextSubtitleId) {
      return;
    }
    _ref.read(subtitleProvider.notifier).selectEntry(nextSubtitleId);
    state = state.copyWith(
      selectedClipId: clipId,
      clearClipSelection: clipId == null,
    );
  }

  void setSnappingEnabled(bool enabled) {
    state = state.copyWith(isSnappingEnabled: enabled);
  }

  void reset() {
    _undoStack.clear();
    _redoStack.clear();
    _isTimelineGestureEditing = false;
    _timelineChangedDuringGesture = false;
    state = const EditorState();
  }

  void _pushUndoSnapshot() {
    final sequence = _historyClock.recordAction();
    _undoStack.add(
      _captureSnapshot(sequence: sequence, branch: _historyClock.branch),
    );
    if (_undoStack.length > _maxHistoryDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  _EditorHistorySnapshot _captureSnapshot({
    required int sequence,
    required int branch,
  }) {
    final subtitleState = _ref.read(subtitleProvider);
    return _EditorHistorySnapshot(
      timeline: state.timeline,
      subtitleEntries: List<SubtitleEntry>.from(subtitleState.entries),
      subtitleStyle: subtitleState.globalStyle,
      selectedTrackId: state.selectedTrackId,
      selectedClipId: state.selectedClipId,
      selectedSubtitleId: subtitleState.selectedEntryId,
      sequence: sequence,
      branch: branch,
    );
  }

  void _restoreSnapshot(_EditorHistorySnapshot snapshot) {
    _isTimelineGestureEditing = false;
    _timelineChangedDuringGesture = false;
    _restoreEditorSubtitleState(
      entries: snapshot.subtitleEntries,
      globalStyle: snapshot.subtitleStyle,
      selectedEntryId: snapshot.selectedSubtitleId,
    );
    state = state.copyWith(
      timeline: snapshot.timeline,
      selectedTrackId: snapshot.selectedTrackId,
      selectedClipId: snapshot.selectedClipId,
      clearTrackSelection: snapshot.selectedTrackId == null,
      clearClipSelection: snapshot.selectedClipId == null,
      canUndo: canUndo,
      canRedo: canRedo,
      editRevision: state.editRevision + 1,
    );
  }

  void _refreshHistoryFlags() {
    state = state.copyWith(canUndo: canUndo, canRedo: canRedo);
  }

  void _restoreEditorSubtitleState({
    required List<SubtitleEntry> entries,
    required SubtitleStyleModel globalStyle,
    String? selectedEntryId,
  }) {
    _isRestoringEditorSubtitleState = true;
    try {
      _ref
          .read(subtitleProvider.notifier)
          .restoreFromEditorHistory(
            entries: entries,
            globalStyle: globalStyle,
            selectedEntryId: selectedEntryId,
          );
    } finally {
      _isRestoringEditorSubtitleState = false;
    }
  }

  void _synchronizeTimelineFromSubtitles(SubtitleState subtitles) {
    if (_isRestoringEditorSubtitleState) {
      return;
    }
    final matchesTimeline = _timelineMatchesSubtitles(
      state.timeline,
      subtitles,
    );
    final nextTimeline = matchesTimeline
        ? state.timeline
        : state.timeline.mergeSubtitleEntries(
            subtitles: subtitles.entries,
            globalStyle: subtitles.globalStyle,
          );
    final selectedSubtitleId = subtitles.selectedEntryId;
    final subtitleTrack = nextTimeline.primarySubtitleTrack;
    final canSelectSubtitle =
        selectedSubtitleId != null &&
        subtitleTrack != null &&
        subtitleTrack.clips.any((clip) => clip.id == selectedSubtitleId);
    final selectedEditorClipWasSubtitle = _isSubtitleClipSelection(
      state.timeline,
      state.selectedClipId,
    );
    final nextTrackId = canSelectSubtitle
        ? subtitleTrack.id
        : state.selectedTrackId;
    final nextClipId = canSelectSubtitle
        ? selectedSubtitleId
        : selectedEditorClipWasSubtitle
        ? null
        : state.selectedClipId;
    final selectionChanged =
        nextTrackId != state.selectedTrackId || nextClipId != state.selectedClipId;
    if (matchesTimeline &&
        !selectionChanged &&
        state.canUndo == canUndo &&
        state.canRedo == canRedo) {
      return;
    }
    state = state.copyWith(
      timeline: nextTimeline,
      selectedTrackId: nextTrackId,
      selectedClipId: nextClipId,
      clearClipSelection: nextClipId == null,
      canUndo: canUndo,
      canRedo: canRedo,
    );
  }

  bool _isSubtitleClipSelection(EditorTimeline timeline, String? clipId) {
    if (clipId == null) return false;
    return timeline.tracks.any(
      (track) =>
          track.type == TimelineTrackType.subtitle &&
          track.clips.any((clip) => clip.id == clipId),
    );
  }

  bool _timelineMatchesSubtitles(
    EditorTimeline timeline,
    SubtitleState subtitles,
  ) {
    if (!mapEquals(
      timeline.subtitleStyle.toJson(),
      subtitles.globalStyle.toJson(),
    )) {
      return false;
    }
    final timelineEntries = timeline.subtitleEntries;
    if (timelineEntries.length != subtitles.entries.length) return false;
    final timelineById = {for (final entry in timelineEntries) entry.id: entry};
    return subtitles.entries.every((entry) {
      final existing = timelineById[entry.id];
      return existing != null &&
          existing.startTime == entry.startTime &&
          existing.endTime == entry.endTime &&
          existing.text == entry.text &&
          mapEquals(
            existing.styleOverride?.toJson(),
            entry.styleOverride?.toJson(),
          );
    });
  }
}

final editorProvider = StateNotifierProvider<EditorNotifier, EditorState>((
  ref,
) {
  return EditorNotifier(ref);
});
