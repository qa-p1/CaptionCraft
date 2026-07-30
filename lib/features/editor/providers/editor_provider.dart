import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../models/timeline_models.dart';
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

  const _EditorHistorySnapshot({
    required this.timeline,
    required this.subtitleEntries,
    required this.subtitleStyle,
    required this.selectedTrackId,
    required this.selectedClipId,
    required this.selectedSubtitleId,
  });
}

class EditorNotifier extends StateNotifier<EditorState> {
  final Ref _ref;
  final List<_EditorHistorySnapshot> _undoStack = [];
  final List<_EditorHistorySnapshot> _redoStack = [];
  bool _isTimelineGestureEditing = false;

  static const int _maxHistoryDepth = 100;

  EditorNotifier(this._ref) : super(const EditorState());

  void loadProject({
    required String videoPath,
    required String projectId,
    required String projectName,
    EditorTimeline timeline = const EditorTimeline(),
  }) {
    _undoStack.clear();
    _redoStack.clear();
    _isTimelineGestureEditing = false;
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
    if (recordHistory && !_isTimelineGestureEditing) {
      _pushUndoSnapshot();
    }
    state = state.copyWith(
      timeline: timeline,
      canUndo: _undoStack.isNotEmpty,
      canRedo: _redoStack.isNotEmpty,
      editRevision: state.editRevision + 1,
    );
  }

  /// Replaces the complete caption track as one editor-wide history action.
  ///
  /// Caption batch tools must capture history before mutating [subtitleProvider].
  /// Calling `loadSubtitles` followed by [setTimeline] records the already-mutated
  /// subtitle state and makes the visible caption change impossible to undo from
  /// the editor toolbar. This method keeps both representations in lockstep.
  void replaceSubtitleEntries(List<SubtitleEntry> entries) {
    final subtitleState = _ref.read(subtitleProvider);
    final sortedEntries = List<SubtitleEntry>.from(entries)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final nextTimeline = state.timeline.mergeSubtitleEntries(
      subtitles: sortedEntries,
      globalStyle: subtitleState.globalStyle,
    );

    _pushUndoSnapshot();
    _ref
        .read(subtitleProvider.notifier)
        .restoreFromEditorHistory(
          entries: sortedEntries,
          globalStyle: subtitleState.globalStyle,
          selectedEntryId: subtitleState.selectedEntryId,
        );
    state = state.copyWith(
      timeline: nextTimeline,
      canUndo: _undoStack.isNotEmpty,
      canRedo: _redoStack.isNotEmpty,
      editRevision: state.editRevision + 1,
    );
  }

  void beginTimelineGestureEdit() {
    if (_isTimelineGestureEditing) return;
    _isTimelineGestureEditing = true;
    _pushUndoSnapshot();
  }

  void endTimelineGestureEdit() {
    _isTimelineGestureEditing = false;
    _refreshHistoryFlags();
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    final current = _captureSnapshot();
    final previous = _undoStack.removeLast();
    _redoStack.add(current);
    _restoreSnapshot(previous);
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    final current = _captureSnapshot();
    final next = _redoStack.removeLast();
    _undoStack.add(current);
    _restoreSnapshot(next);
  }

  void clearHistory() {
    _undoStack.clear();
    _redoStack.clear();
    _isTimelineGestureEditing = false;
    _refreshHistoryFlags();
  }

  void setActivePanel(EditorBottomPanel panel) {
    state = state.copyWith(activePanel: panel);
  }

  void selectTrack(String? trackId) {
    state = state.copyWith(
      selectedTrackId: trackId,
      clearTrackSelection: trackId == null,
    );
  }

  void selectClip(String? clipId) {
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
    state = const EditorState();
  }

  void _pushUndoSnapshot() {
    _undoStack.add(_captureSnapshot());
    if (_undoStack.length > _maxHistoryDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  _EditorHistorySnapshot _captureSnapshot() {
    final subtitleState = _ref.read(subtitleProvider);
    return _EditorHistorySnapshot(
      timeline: state.timeline,
      subtitleEntries: List<SubtitleEntry>.from(subtitleState.entries),
      subtitleStyle: subtitleState.globalStyle,
      selectedTrackId: state.selectedTrackId,
      selectedClipId: state.selectedClipId,
      selectedSubtitleId: subtitleState.selectedEntryId,
    );
  }

  void _restoreSnapshot(_EditorHistorySnapshot snapshot) {
    _isTimelineGestureEditing = false;
    _ref
        .read(subtitleProvider.notifier)
        .restoreFromEditorHistory(
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
      canUndo: _undoStack.isNotEmpty,
      canRedo: _redoStack.isNotEmpty,
      editRevision: state.editRevision + 1,
    );
  }

  void _refreshHistoryFlags() {
    state = state.copyWith(
      canUndo: _undoStack.isNotEmpty,
      canRedo: _redoStack.isNotEmpty,
    );
  }
}

final editorProvider = StateNotifierProvider<EditorNotifier, EditorState>((
  ref,
) {
  return EditorNotifier(ref);
});
