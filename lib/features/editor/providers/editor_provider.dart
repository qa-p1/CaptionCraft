import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../models/editor_effect_models.dart';
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
  final bool isTimelineGestureEditing;
  final Set<String> selectedClipIds;

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
    this.isTimelineGestureEditing = false,
    this.selectedClipIds = const <String>{},
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
    bool? isTimelineGestureEditing,
    Set<String>? selectedClipIds,
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
      isTimelineGestureEditing:
          isTimelineGestureEditing ?? this.isTimelineGestureEditing,
      selectedClipIds: selectedClipIds ?? this.selectedClipIds,
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
  final Set<String> selectedClipIds;
  final String? selectedSubtitleId;
  final int sequence;
  final int branch;

  const _EditorHistorySnapshot({
    required this.timeline,
    required this.subtitleEntries,
    required this.subtitleStyle,
    required this.selectedTrackId,
    required this.selectedClipId,
    required this.selectedClipIds,
    required this.selectedSubtitleId,
    required this.sequence,
    required this.branch,
  });

  _EditorHistorySnapshot withHistory({
    required int sequence,
    required int branch,
  }) {
    return _EditorHistorySnapshot(
      timeline: timeline,
      subtitleEntries: subtitleEntries,
      subtitleStyle: subtitleStyle,
      selectedTrackId: selectedTrackId,
      selectedClipId: selectedClipId,
      selectedClipIds: selectedClipIds,
      selectedSubtitleId: selectedSubtitleId,
      sequence: sequence,
      branch: branch,
    );
  }
}

class EditorNotifier extends StateNotifier<EditorState> {
  final Ref _ref;
  final List<_EditorHistorySnapshot> _undoStack = [];
  final List<_EditorHistorySnapshot> _redoStack = [];
  EditorEffectStack? _effectStackClipboard;
  bool _isTimelineGestureEditing = false;
  bool _timelineChangedDuringGesture = false;
  _EditorHistorySnapshot? _timelineGestureBaseline;
  bool _isRestoringEditorSubtitleState = false;
  late final EditorHistoryClock _historyClock = _ref.read(
    editorHistoryClockProvider,
  );

  static const int _maxHistoryDepth = 100;

  bool get canUndo => !_isTimelineGestureEditing && _undoStack.isNotEmpty;
  bool get canRedo =>
      !_isTimelineGestureEditing &&
      _redoStack.isNotEmpty &&
      _redoStack.last.branch == _historyClock.branch;
  int? get latestUndoSequence => canUndo ? _undoStack.last.sequence : null;
  int? get latestRedoSequence => canRedo ? _redoStack.last.sequence : null;
  bool get hasCopiedEffectStack => _effectStackClipboard?.isNotEmpty == true;

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
    _timelineGestureBaseline = null;
    final currentSubtitles = _ref.read(subtitleProvider);
    final normalizedTimeline =
        (currentSubtitles.entries.isEmpty
                ? timeline
                : timeline.mergeSubtitleEntries(
                    subtitles: currentSubtitles.entries,
                    globalStyle: currentSubtitles.globalStyle,
                  ))
            .withoutTrackOverlaps();
    state = state.copyWith(
      videoPath: videoPath,
      projectId: projectId,
      projectName: projectName,
      timeline: normalizedTimeline,
      isSnappingEnabled: normalizedTimeline.workspaceSettings.snapping.enabled,
      canUndo: false,
      canRedo: false,
      editRevision: 0,
      isTimelineGestureEditing: false,
      clearTrackSelection: true,
      clearClipSelection: true,
      selectedClipIds: const <String>{},
    );
    _isRestoringEditorSubtitleState = true;
    try {
      _ref
          .read(subtitleProvider.notifier)
          .syncFromTimeline(normalizedTimeline.subtitleEntries);
    } finally {
      _isRestoringEditorSubtitleState = false;
    }
  }

  void setProcessing(bool processing) {
    state = state.copyWith(isProcessing: processing);
  }

  void setWaveformPath(String path) {
    state = state.copyWith(waveformPath: path);
  }

  void setTimeline(EditorTimeline timeline, {bool recordHistory = true}) {
    final normalizedTimeline = timeline.withoutTrackOverlaps();
    if (identical(state.timeline, normalizedTimeline)) return;
    if (_isTimelineGestureEditing) {
      _timelineGestureBaseline ??= _captureSnapshot(
        sequence: 0,
        branch: _historyClock.branch,
      );
      _timelineChangedDuringGesture = true;
    } else if (recordHistory) {
      _pushUndoSnapshot();
    }
    state = state.copyWith(
      timeline: normalizedTimeline,
      isSnappingEnabled: normalizedTimeline.workspaceSettings.snapping.enabled,
      canUndo: _isTimelineGestureEditing ? false : canUndo,
      canRedo: _isTimelineGestureEditing ? false : canRedo,
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
    final normalizedTimeline = timeline.withoutTrackOverlaps();

    _pushUndoSnapshot();
    _restoreEditorSubtitleState(
      entries: sortedEntries,
      globalStyle: subtitleState.globalStyle,
      selectedEntryId: selectedEntryId,
    );
    _isRestoringEditorSubtitleState = true;
    try {
      _ref
          .read(subtitleProvider.notifier)
          .syncFromTimeline(normalizedTimeline.subtitleEntries);
    } finally {
      _isRestoringEditorSubtitleState = false;
    }
    state = state.copyWith(
      timeline: normalizedTimeline,
      canUndo: canUndo,
      canRedo: canRedo,
      isTimelineGestureEditing: false,
      editRevision: state.editRevision + 1,
    );
  }

  void beginTimelineGestureEdit() {
    if (_isTimelineGestureEditing) return;
    final baseline = _captureSnapshot(
      sequence: 0,
      branch: _historyClock.branch,
    );
    _isTimelineGestureEditing = true;
    _timelineChangedDuringGesture = false;
    _timelineGestureBaseline = baseline;
    state = state.copyWith(
      canUndo: false,
      canRedo: false,
      isTimelineGestureEditing: true,
    );
  }

  void endTimelineGestureEdit() {
    if (!_isTimelineGestureEditing) return;
    final shouldNotifyPreview = _timelineChangedDuringGesture;
    final baseline = _timelineGestureBaseline;
    _isTimelineGestureEditing = false;
    _timelineChangedDuringGesture = false;
    _timelineGestureBaseline = null;
    if (shouldNotifyPreview && baseline != null) {
      final sequence = _historyClock.recordAction();
      _undoStack.add(
        baseline.withHistory(sequence: sequence, branch: _historyClock.branch),
      );
      if (_undoStack.length > _maxHistoryDepth) _undoStack.removeAt(0);
      _redoStack.clear();
    }
    state = state.copyWith(
      canUndo: canUndo,
      canRedo: canRedo,
      isTimelineGestureEditing: false,
      editRevision: shouldNotifyPreview
          ? state.editRevision + 1
          : state.editRevision,
    );
  }

  void cancelTimelineGestureEdit() {
    if (!_isTimelineGestureEditing) return;
    final baseline = _timelineGestureBaseline;
    final changed = _timelineChangedDuringGesture;
    _isTimelineGestureEditing = false;
    _timelineChangedDuringGesture = false;
    _timelineGestureBaseline = null;
    if (changed && baseline != null) {
      _restoreSnapshot(baseline);
      return;
    }
    state = state.copyWith(
      canUndo: canUndo,
      canRedo: canRedo,
      isTimelineGestureEditing: false,
    );
  }

  void undo() {
    if (_isTimelineGestureEditing || !canUndo) return;
    final previous = _undoStack.removeLast();
    final current = _captureSnapshot(
      sequence: _historyClock.recordTraversal(),
      branch: _historyClock.branch,
    );
    _redoStack.add(current);
    _restoreSnapshot(previous);
  }

  void redo() {
    if (_isTimelineGestureEditing || !canRedo) return;
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
    _timelineGestureBaseline = null;
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
      selectedClipIds: selectedClipBelongsToTrack
          ? state.selectedClipIds
          : const <String>{},
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
      selectedClipIds: clipId == null ? const <String>{} : {clipId},
    );
  }

  void toggleClipSelection(String clipId) {
    final selection = {...state.selectedClipIds};
    if (selection.contains(clipId)) {
      selection.remove(clipId);
    } else {
      selection.add(clipId);
    }
    final nextPrimary = selection.isEmpty ? null : selection.last;
    state = state.copyWith(
      selectedClipIds: selection,
      selectedClipId: nextPrimary,
      clearClipSelection: nextPrimary == null,
    );
  }

  void selectClipIds(Iterable<String> clipIds) {
    final selection = clipIds.toSet();
    final primary = selection.isEmpty ? null : selection.last;
    state = state.copyWith(
      selectedClipIds: selection,
      selectedClipId: primary,
      clearClipSelection: primary == null,
    );
  }

  void clearClipSelection() {
    state = state.copyWith(
      selectedClipIds: const <String>{},
      clearClipSelection: true,
    );
  }

  void setWorkspaceSettings(
    TimelineWorkspaceSettings Function(TimelineWorkspaceSettings current)
    mapper, {
    bool recordHistory = true,
  }) {
    setTimeline(
      state.timeline.copyWith(
        workspaceSettings: mapper(state.timeline.workspaceSettings),
      ),
      recordHistory: recordHistory,
    );
  }

  bool updateClip(
    String clipId,
    TimelineClip Function(TimelineClip clip) mapper, {
    bool recordHistory = true,
  }) {
    final track = state.timeline.tracks
        .where((candidate) => candidate.clips.any((clip) => clip.id == clipId))
        .firstOrNull;
    if (track == null || track.isLocked) return false;
    final tracks = state.timeline.tracks
        .map(
          (candidate) => candidate.id == track.id
              ? candidate.copyWith(
                  clips: candidate.clips
                      .map((clip) => clip.id == clipId ? mapper(clip) : clip)
                      .toList(),
                )
              : candidate,
        )
        .toList();
    setTimeline(
      state.timeline.copyWith(tracks: tracks),
      recordHistory: recordHistory,
    );
    return true;
  }

  bool updateTrack(
    String trackId,
    TimelineTrack Function(TimelineTrack track) mapper, {
    bool recordHistory = true,
  }) {
    final current = state.timeline.tracks
        .where((track) => track.id == trackId)
        .firstOrNull;
    if (current == null || current.isLocked) return false;
    final updated = mapper(current);
    setTimeline(
      state.timeline.copyWith(
        tracks: state.timeline.tracks
            .map((track) => track.id == trackId ? updated : track)
            .toList(),
      ),
      recordHistory: recordHistory,
    );
    return true;
  }

  EditorEffectStack effectStackForTarget({
    required EditorEffectScope scope,
    String? targetId,
  }) {
    switch (scope) {
      case EditorEffectScope.project:
        return state.timeline.projectEffectStack;
      case EditorEffectScope.clip:
      case EditorEffectScope.adjustmentLayer:
        return state.timeline.tracks
                .expand((track) => track.clips)
                .where((clip) => clip.id == targetId)
                .firstOrNull
                ?.effectStack ??
            const EditorEffectStack();
      case EditorEffectScope.track:
        return state.timeline.tracks
                .where((track) => track.id == targetId)
                .firstOrNull
                ?.effectStack ??
            const EditorEffectStack();
      case EditorEffectScope.audioBus:
        return state.timeline.audioBuses
                .where((bus) => bus.id == targetId)
                .firstOrNull
                ?.effectStack ??
            const EditorEffectStack();
      case EditorEffectScope.group:
      case EditorEffectScope.compound:
        return state.timeline.effectContainers
                .where(
                  (container) =>
                      container.scope == scope &&
                      container.targetId == targetId,
                )
                .firstOrNull
                ?.stack ??
            const EditorEffectStack();
    }
  }

  bool updateEffectStack({
    required EditorEffectScope scope,
    String? targetId,
    required EditorEffectStack Function(EditorEffectStack current) mapper,
    bool recordHistory = true,
  }) {
    if (scope != EditorEffectScope.project && targetId == null) return false;
    if (scope == EditorEffectScope.adjustmentLayer &&
        !state.timeline.tracks
            .expand((track) => track.clips)
            .any((clip) => clip.id == targetId && clip.isAdjustmentLayer)) {
      return false;
    }
    final current = effectStackForTarget(scope: scope, targetId: targetId);
    final updated = mapper(current);
    if (identical(current, updated)) return false;
    switch (scope) {
      case EditorEffectScope.project:
        setTimeline(
          state.timeline.copyWith(projectEffectStack: updated),
          recordHistory: recordHistory,
        );
        return true;
      case EditorEffectScope.clip:
      case EditorEffectScope.adjustmentLayer:
        return updateClip(
          targetId!,
          (clip) => clip.copyWith(effectStack: updated),
          recordHistory: recordHistory,
        );
      case EditorEffectScope.track:
        return updateTrack(
          targetId!,
          (track) => track.copyWith(effectStack: updated),
          recordHistory: recordHistory,
        );
      case EditorEffectScope.audioBus:
        return updateAudioBus(
          targetId!,
          (bus) => bus.copyWith(effectStack: updated),
          recordHistory: recordHistory,
        );
      case EditorEffectScope.group:
      case EditorEffectScope.compound:
        if (!_effectTargetExists(scope, targetId!)) {
          return false;
        }
        if (_effectTargetIsLocked(scope, targetId)) return false;
        final containers = [...state.timeline.effectContainers];
        final index = containers.indexWhere(
          (container) =>
              container.scope == scope && container.targetId == targetId,
        );
        if (index < 0) {
          containers.add(
            EditorEffectContainer(
              scope: scope,
              targetId: targetId,
              label: scope == EditorEffectScope.group
                  ? 'Group effects'
                  : 'Compound effects',
              stack: updated,
            ),
          );
        } else {
          containers[index] = containers[index].copyWith(
            enabled: true,
            stack: updated,
          );
        }
        setTimeline(
          state.timeline.copyWith(effectContainers: containers),
          recordHistory: recordHistory,
        );
        return true;
    }
  }

  bool addEffect({
    required EditorEffectScope scope,
    String? targetId,
    required EditorEffectType type,
  }) {
    return updateEffectStack(
      scope: scope,
      targetId: targetId,
      mapper: (stack) => stack.add(EditorEffect(type: type)),
    );
  }

  bool updateEffect({
    required EditorEffectScope scope,
    String? targetId,
    required String effectId,
    required EditorEffect Function(EditorEffect effect) mapper,
    bool recordHistory = true,
  }) {
    final currentStack = effectStackForTarget(scope: scope, targetId: targetId);
    if (currentStack.byId(effectId) == null) return false;
    var found = false;
    final changed = updateEffectStack(
      scope: scope,
      targetId: targetId,
      recordHistory: recordHistory,
      mapper: (stack) => stack.copyWith(
        effects: stack.effects.map((effect) {
          if (effect.id != effectId) return effect;
          found = true;
          return mapper(effect);
        }).toList(),
      ),
    );
    return changed && found;
  }

  bool removeEffect({
    required EditorEffectScope scope,
    String? targetId,
    required String effectId,
  }) {
    if (effectStackForTarget(scope: scope, targetId: targetId).byId(effectId) ==
        null) {
      return false;
    }
    return updateEffectStack(
      scope: scope,
      targetId: targetId,
      mapper: (stack) => stack.remove(effectId),
    );
  }

  bool toggleEffect({
    required EditorEffectScope scope,
    String? targetId,
    required String effectId,
  }) {
    if (effectStackForTarget(scope: scope, targetId: targetId).byId(effectId) ==
        null) {
      return false;
    }
    return updateEffectStack(
      scope: scope,
      targetId: targetId,
      mapper: (stack) => stack.toggle(effectId),
    );
  }

  bool reorderEffects({
    required EditorEffectScope scope,
    String? targetId,
    required int oldIndex,
    required int newIndex,
  }) {
    final stack = effectStackForTarget(scope: scope, targetId: targetId);
    if (oldIndex < 0 ||
        oldIndex >= stack.effects.length ||
        newIndex < 0 ||
        newIndex > stack.effects.length ||
        oldIndex == newIndex ||
        oldIndex + 1 == newIndex) {
      return false;
    }
    return updateEffectStack(
      scope: scope,
      targetId: targetId,
      mapper: (stack) => stack.reorder(oldIndex, newIndex),
    );
  }

  bool copyEffectStack({
    required EditorEffectScope sourceScope,
    String? sourceTargetId,
    required EditorEffectScope destinationScope,
    String? destinationTargetId,
    bool append = false,
  }) {
    final source = effectStackForTarget(
      scope: sourceScope,
      targetId: sourceTargetId,
    );
    if (source.isEmpty) return false;
    final copied = source.cloneWithNewIds();
    return updateEffectStack(
      scope: destinationScope,
      targetId: destinationTargetId,
      mapper: (current) => append
          ? current.copyWith(effects: [...current.effects, ...copied.effects])
          : copied,
    );
  }

  bool copyEffectStackToClipboard({
    required EditorEffectScope scope,
    String? targetId,
    EditorEffectDomain? domain,
  }) {
    final source = effectStackForTarget(scope: scope, targetId: targetId);
    final stack = domain == null
        ? source
        : source.copyWith(
            effects: source.effects
                .where((effect) => effect.domain == domain)
                .toList(),
          );
    if (stack.isEmpty) return false;
    _effectStackClipboard = stack.cloneWithNewIds();
    return true;
  }

  bool pasteEffectStackFromClipboard({
    required EditorEffectScope scope,
    String? targetId,
    bool append = false,
    EditorEffectDomain? domain,
  }) {
    final clipboard = _effectStackClipboard;
    if (clipboard == null || clipboard.isEmpty) return false;
    final copied = EditorEffectStack(
      effects: clipboard.effects
          .where((effect) => domain == null || effect.domain == domain)
          .map((effect) => effect.cloneWithNewId())
          .toList(),
    );
    if (copied.isEmpty) return false;
    return updateEffectStack(
      scope: scope,
      targetId: targetId,
      mapper: (current) {
        if (append || domain == null) {
          return append
              ? current.copyWith(
                  effects: [...current.effects, ...copied.effects],
                )
              : copied;
        }
        return current.copyWith(
          effects: [
            ...current.effects.where((effect) => effect.domain != domain),
            ...copied.effects,
          ],
        );
      },
    );
  }

  String? saveEffectPreset({
    required String name,
    required EditorEffectScope scope,
    String? targetId,
    EditorEffectDomain? domain,
  }) {
    final cleaned = name.trim();
    if (cleaned.isEmpty) return null;
    final source = effectStackForTarget(scope: scope, targetId: targetId);
    final stack = domain == null
        ? source
        : source.copyWith(
            effects: source.effects
                .where((effect) => effect.domain == domain)
                .toList(),
          );
    if (stack.isEmpty) return null;
    final preset = EditorEffectPreset(
      name: cleaned,
      stack: stack.cloneWithNewIds(),
    );
    setTimeline(
      state.timeline.copyWith(
        effectPresets: [...state.timeline.effectPresets, preset],
      ),
    );
    return preset.id;
  }

  bool applyEffectPreset({
    required String presetId,
    required EditorEffectScope scope,
    String? targetId,
    bool append = false,
    EditorEffectDomain? domain,
  }) {
    final preset = state.timeline.effectPresets
        .where((candidate) => candidate.id == presetId)
        .firstOrNull;
    if (preset == null) return false;
    final copied = EditorEffectStack(
      effects: preset.stack.effects
          .where((effect) => domain == null || effect.domain == domain)
          .map((effect) => effect.cloneWithNewId())
          .toList(),
    );
    if (copied.isEmpty) return false;
    return updateEffectStack(
      scope: scope,
      targetId: targetId,
      mapper: (current) {
        if (append || domain == null) {
          return append
              ? current.copyWith(
                  effects: [...current.effects, ...copied.effects],
                )
              : copied;
        }
        return current.copyWith(
          effects: [
            ...current.effects.where((effect) => effect.domain != domain),
            ...copied.effects,
          ],
        );
      },
    );
  }

  bool deleteEffectPreset(String presetId) {
    if (!state.timeline.effectPresets.any((preset) => preset.id == presetId)) {
      return false;
    }
    setTimeline(
      state.timeline.copyWith(
        effectPresets: state.timeline.effectPresets
            .where((preset) => preset.id != presetId)
            .toList(),
      ),
    );
    return true;
  }

  bool upsertEffectParameterKeyframe({
    required EditorEffectScope scope,
    String? targetId,
    required String effectId,
    required String parameter,
    required Duration time,
    required double value,
    EditorEffectInterpolation interpolation = EditorEffectInterpolation.linear,
  }) {
    final safeTime = time.isNegative ? Duration.zero : time;
    return updateEffect(
      scope: scope,
      targetId: targetId,
      effectId: effectId,
      mapper: (effect) => effect.upsertKeyframe(
        parameter: parameter,
        time: safeTime,
        value: value,
        interpolation: interpolation,
      ),
    );
  }

  bool removeEffectParameterKeyframe({
    required EditorEffectScope scope,
    String? targetId,
    required String effectId,
    required String parameter,
    required Duration time,
  }) {
    return updateEffect(
      scope: scope,
      targetId: targetId,
      effectId: effectId,
      mapper: (effect) => effect.copyWith(
        keyframes: effect.keyframes
            .where(
              (keyframe) =>
                  keyframe.parameter != parameter || keyframe.time != time,
            )
            .toList(),
      ),
    );
  }

  String? createGroup(Iterable<String> clipIds, {String? name}) {
    final ids = clipIds.toSet();
    if (ids.length < 2) return null;
    final matching = state.timeline.tracks
        .expand((track) => track.clips.map((clip) => (track, clip)))
        .where((entry) => ids.contains(entry.$2.id))
        .toList();
    if (matching.length != ids.length ||
        matching.any((entry) => entry.$1.isLocked)) {
      return null;
    }
    final group = TimelineGroup(
      name: name?.trim().isNotEmpty == true
          ? name!.trim()
          : 'Group ${state.timeline.groups.length + 1}',
      clipIds: ids,
    );
    final oldGroupIds = matching
        .map((entry) => entry.$2.groupId)
        .whereType<String>()
        .toSet();
    final tracks = state.timeline.tracks.map((track) {
      return track.copyWith(
        clips: track.clips
            .map(
              (clip) => ids.contains(clip.id)
                  ? clip.copyWith(groupId: group.id)
                  : clip,
            )
            .toList(),
      );
    }).toList();
    final groups =
        state.timeline.groups
            .map(
              (existing) => oldGroupIds.contains(existing.id)
                  ? existing.copyWith(
                      clipIds: existing.clipIds.where(
                        (id) => !ids.contains(id),
                      ),
                    )
                  : existing,
            )
            .where((existing) => existing.clipIds.isNotEmpty)
            .toList()
          ..add(group);
    setTimeline(state.timeline.copyWith(tracks: tracks, groups: groups));
    selectClipIds(ids);
    return group.id;
  }

  bool ungroup(String groupId) {
    if (_effectTargetIsLocked(EditorEffectScope.group, groupId)) return false;
    final group = state.timeline.groups
        .where((candidate) => candidate.id == groupId)
        .firstOrNull;
    if (group == null) return false;
    final tracks = state.timeline.tracks.map((track) {
      return track.copyWith(
        clips: track.clips
            .map(
              (clip) => clip.groupId == groupId
                  ? clip.copyWith(clearGroupId: true)
                  : clip,
            )
            .toList(),
      );
    }).toList();
    setTimeline(
      state.timeline.copyWith(
        tracks: tracks,
        groups: state.timeline.groups
            .where((candidate) => candidate.id != groupId)
            .toList(),
        effectContainers: state.timeline.effectContainers
            .where(
              (container) =>
                  container.scope != EditorEffectScope.group ||
                  container.targetId != groupId,
            )
            .toList(),
      ),
    );
    return true;
  }

  String? createCompoundClip(Iterable<String> clipIds, {String? name}) {
    final ids = clipIds.toSet();
    if (ids.length < 2) return null;
    final matching = state.timeline.tracks
        .expand((track) => track.clips.map((clip) => (track, clip)))
        .where((entry) => ids.contains(entry.$2.id))
        .toList();
    if (matching.length != ids.length ||
        matching.any(
          (entry) => entry.$1.isLocked || !entry.$2.type.isVisualMedia,
        )) {
      return null;
    }
    final compound = TimelineCompoundClip(
      name: name?.trim().isNotEmpty == true
          ? name!.trim()
          : 'Compound ${state.timeline.compoundClips.length + 1}',
      clipIds: ids,
    );
    final oldCompoundIds = matching
        .map((entry) => entry.$2.compoundId)
        .whereType<String>()
        .toSet();
    final tracks = state.timeline.tracks.map((track) {
      return track.copyWith(
        clips: track.clips
            .map(
              (clip) => ids.contains(clip.id)
                  ? clip.copyWith(compoundId: compound.id)
                  : clip,
            )
            .toList(),
      );
    }).toList();
    final compounds =
        state.timeline.compoundClips
            .map(
              (existing) => oldCompoundIds.contains(existing.id)
                  ? existing.copyWith(
                      clipIds: existing.clipIds.where(
                        (id) => !ids.contains(id),
                      ),
                    )
                  : existing,
            )
            .where((existing) => existing.clipIds.isNotEmpty)
            .toList()
          ..add(compound);
    setTimeline(
      state.timeline.copyWith(tracks: tracks, compoundClips: compounds),
    );
    selectClipIds(ids);
    return compound.id;
  }

  bool dissolveCompoundClip(String compoundId) {
    if (_effectTargetIsLocked(EditorEffectScope.compound, compoundId)) {
      return false;
    }
    if (!state.timeline.compoundClips.any(
      (candidate) => candidate.id == compoundId,
    )) {
      return false;
    }
    final tracks = state.timeline.tracks.map((track) {
      return track.copyWith(
        clips: track.clips
            .map(
              (clip) => clip.compoundId == compoundId
                  ? clip.copyWith(clearCompoundId: true)
                  : clip,
            )
            .toList(),
      );
    }).toList();
    setTimeline(
      state.timeline.copyWith(
        tracks: tracks,
        compoundClips: state.timeline.compoundClips
            .where((candidate) => candidate.id != compoundId)
            .toList(),
        effectContainers: state.timeline.effectContainers
            .where(
              (container) =>
                  container.scope != EditorEffectScope.compound ||
                  container.targetId != compoundId,
            )
            .toList(),
      ),
    );
    return true;
  }

  String? createAdjustmentLayer({
    required Duration startTime,
    required Duration endTime,
    String label = 'Adjustment layer',
  }) {
    if (endTime <= startTime) return null;
    final timeline = state.timeline;
    var track = timeline.tracks
        .where(
          (candidate) =>
              candidate.section == TimelineTrackSection.overlay &&
              candidate.acceptsClipType(TimelineTrackType.effect) &&
              !candidate.isLocked &&
              candidate.clips.every(
                (clip) =>
                    endTime <= clip.startTime || startTime >= clip.endTime,
              ),
        )
        .firstOrNull;
    var nextTimeline = timeline;
    if (track == null) {
      track = TimelineTrack(
        name: timeline.nextTrackNameForSection(TimelineTrackSection.overlay),
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
      );
      nextTimeline = timeline.insertTrackUsingEditorRules(track);
    }
    final layer = TimelineClip.effect(
      trackId: track.id,
      effectKind: null,
      label: label.trim().isEmpty ? 'Adjustment layer' : label.trim(),
      startTime: startTime,
      endTime: endTime,
      isAdjustmentLayer: true,
    );
    final tracks = nextTimeline.tracks.map((candidate) {
      return candidate.id == track!.id
          ? candidate.copyWith(clips: [...candidate.clips, layer])
          : candidate;
    }).toList();
    setTimeline(nextTimeline.copyWith(tracks: tracks));
    selectTrack(track.id);
    selectClip(layer.id);
    return layer.id;
  }

  String createAudioBus({String? name}) {
    final bus = TimelineAudioBus(
      name: name?.trim().isNotEmpty == true
          ? name!.trim()
          : 'Bus ${state.timeline.audioBuses.length + 1}',
    );
    setTimeline(
      state.timeline.copyWith(audioBuses: [...state.timeline.audioBuses, bus]),
    );
    return bus.id;
  }

  bool updateAudioBus(
    String busId,
    TimelineAudioBus Function(TimelineAudioBus bus) mapper, {
    bool recordHistory = true,
  }) {
    if (!state.timeline.audioBuses.any((bus) => bus.id == busId)) return false;
    setTimeline(
      state.timeline.copyWith(
        audioBuses: state.timeline.audioBuses
            .map((bus) => bus.id == busId ? mapper(bus) : bus)
            .toList(),
      ),
      recordHistory: recordHistory,
    );
    return true;
  }

  bool assignTrackToAudioBus(String trackId, String? busId) {
    if (busId != null &&
        !state.timeline.audioBuses.any((bus) => bus.id == busId)) {
      return false;
    }
    return updateTrack(
      trackId,
      (track) => busId == null
          ? track.copyWith(clearAudioBusId: true)
          : track.copyWith(audioBusId: busId),
    );
  }

  bool deleteAudioBus(String busId) {
    if (!state.timeline.audioBuses.any((bus) => bus.id == busId)) return false;
    setTimeline(
      state.timeline.copyWith(
        audioBuses: state.timeline.audioBuses
            .where((bus) => bus.id != busId)
            .toList(),
        tracks: state.timeline.tracks
            .map(
              (track) => track.audioBusId == busId
                  ? track.copyWith(clearAudioBusId: true)
                  : track,
            )
            .toList(),
      ),
    );
    return true;
  }

  String? importAndApplyLutToClip({
    required String clipId,
    required String sourcePath,
    String? name,
    String folder = 'Custom',
  }) => importAndApplyLutToClips(
    clipIds: [clipId],
    sourcePath: sourcePath,
    name: name,
    folder: folder,
  );

  String? importAndApplyLutToClips({
    required Iterable<String> clipIds,
    required String sourcePath,
    String? name,
    String folder = 'Custom',
  }) {
    final ids = clipIds.toSet();
    if (ids.isEmpty) return null;
    final cleanedPath = sourcePath.trim();
    if (cleanedPath.isEmpty) return null;
    final matching = state.timeline.tracks
        .expand((track) => track.clips.map((clip) => (track, clip)))
        .where((entry) => ids.contains(entry.$2.id))
        .toList();
    if (matching.length != ids.length ||
        matching.any(
          (entry) => entry.$1.isLocked || !entry.$2.supportsVisualEffects,
        )) {
      return null;
    }
    final existing = state.timeline.colorManagement.luts
        .where((lut) => lut.path.toLowerCase() == cleanedPath.toLowerCase())
        .firstOrNull;
    final lut =
        existing ??
        EditorLutAsset(
          name: name?.trim().isNotEmpty == true ? name!.trim() : 'Custom LUT',
          path: cleanedPath,
          folder: folder.trim().isEmpty ? 'Custom' : folder.trim(),
        );
    final tracks = state.timeline.tracks
        .map(
          (track) => track.copyWith(
            clips: track.clips
                .map(
                  (clip) => ids.contains(clip.id)
                      ? clip.copyWith(
                          colorAdjustments: clip.colorAdjustments.copyWith(
                            lutPath: lut.path,
                            lutIntensity: 1,
                          ),
                        )
                      : clip,
                )
                .toList(),
          ),
        )
        .toList();
    setTimeline(
      state.timeline.copyWith(
        tracks: tracks,
        colorManagement: state.timeline.colorManagement.copyWith(
          luts: existing == null
              ? [...state.timeline.colorManagement.luts, lut]
              : state.timeline.colorManagement.luts,
        ),
      ),
    );
    return lut.id;
  }

  bool applyLutToClip(String clipId, String? lutId) {
    return applyLutToClips([clipId], lutId);
  }

  bool applyLutToClips(Iterable<String> clipIds, String? lutId) {
    final ids = clipIds.toSet();
    if (ids.isEmpty) return false;
    final lut = lutId == null
        ? null
        : state.timeline.colorManagement.luts
              .where((candidate) => candidate.id == lutId)
              .firstOrNull;
    if (lutId != null && lut == null) return false;
    final matching = state.timeline.tracks
        .expand((track) => track.clips.map((clip) => (track, clip)))
        .where((entry) => ids.contains(entry.$2.id))
        .toList();
    if (matching.length != ids.length ||
        matching.any(
          (entry) => entry.$1.isLocked || !entry.$2.supportsVisualEffects,
        )) {
      return false;
    }
    setTimeline(
      state.timeline.copyWith(
        tracks: state.timeline.tracks
            .map(
              (track) => track.copyWith(
                clips: track.clips
                    .map(
                      (clip) => ids.contains(clip.id)
                          ? clip.copyWith(
                              colorAdjustments: lut == null
                                  ? clip.colorAdjustments.copyWith(
                                      clearLutPath: true,
                                    )
                                  : clip.colorAdjustments.copyWith(
                                      lutPath: lut.path,
                                    ),
                            )
                          : clip,
                    )
                    .toList(),
              ),
            )
            .toList(),
      ),
    );
    return true;
  }

  bool updateLutAsset(
    String lutId,
    EditorLutAsset Function(EditorLutAsset lut) mapper,
  ) {
    if (!state.timeline.colorManagement.luts.any((lut) => lut.id == lutId)) {
      return false;
    }
    setTimeline(
      state.timeline.copyWith(
        colorManagement: state.timeline.colorManagement.copyWith(
          luts: state.timeline.colorManagement.luts
              .map((lut) => lut.id == lutId ? mapper(lut) : lut)
              .toList(),
        ),
      ),
    );
    return true;
  }

  bool _effectTargetExists(EditorEffectScope scope, String targetId) {
    return switch (scope) {
      EditorEffectScope.group => state.timeline.groups.any(
        (group) => group.id == targetId,
      ),
      EditorEffectScope.compound => state.timeline.compoundClips.any(
        (compound) => compound.id == targetId,
      ),
      _ => false,
    };
  }

  bool _effectTargetIsLocked(EditorEffectScope scope, String targetId) {
    return state.timeline.tracks.any(
      (track) =>
          track.isLocked &&
          track.clips.any(
            (clip) => switch (scope) {
              EditorEffectScope.group => clip.groupId == targetId,
              EditorEffectScope.compound => clip.compoundId == targetId,
              _ => false,
            },
          ),
    );
  }

  bool upsertKeyframe({
    required String clipId,
    required TimelineKeyframeProperty property,
    required Duration time,
    required double value,
    TimelineKeyframeInterpolation? interpolation,
    TimelineBezierCurve? curve,
  }) {
    return updateClip(clipId, (clip) {
      final relativeMs = time.inMilliseconds
          .clamp(0, math.max(0, clip.duration.inMilliseconds))
          .toInt();
      TimelineKeyframe? existing;
      for (final keyframe in clip.keyframes) {
        if (keyframe.property == property &&
            keyframe.time.inMilliseconds == relativeMs) {
          existing = keyframe;
          break;
        }
      }
      final next = [...clip.keyframes]
        ..removeWhere(
          (keyframe) =>
              keyframe.property == property &&
              keyframe.time.inMilliseconds == relativeMs,
        )
        ..add(
          existing?.copyWith(
                time: Duration(milliseconds: relativeMs),
                value: value,
                interpolation: interpolation,
                curve: curve,
              ) ??
              TimelineKeyframe(
                time: Duration(milliseconds: relativeMs),
                property: property,
                value: value,
                interpolation:
                    interpolation ?? TimelineKeyframeInterpolation.linear,
                curve: curve ?? TimelineBezierCurve.linear,
              ),
        )
        ..sort((a, b) => a.time.compareTo(b.time));
      return clip.copyWith(keyframes: next);
    });
  }

  Duration _snappedKeyframeTime(TimelineClip clip, Duration absolutePosition) {
    final frameRate = state.timeline.workspaceSettings.frameRate.clamp(1, 120);
    final frameUs = Duration.microsecondsPerSecond / frameRate;
    final relativeUs = (absolutePosition - clip.startTime).inMicroseconds.clamp(
      0,
      math.max(0, clip.duration.inMicroseconds),
    );
    final snappedUs = (relativeUs / frameUs).round() * frameUs;
    return Duration(
      microseconds: snappedUs
          .round()
          .clamp(0, math.max(0, clip.duration.inMicroseconds))
          .toInt(),
    );
  }

  TimelineClip _upsertKeyframeValues(
    TimelineClip clip, {
    required Duration time,
    required Map<TimelineKeyframeProperty, double> values,
    TimelineKeyframeInterpolation? interpolation,
    TimelineBezierCurve? curve,
  }) {
    final next = [...clip.keyframes];
    for (final entry in values.entries) {
      TimelineKeyframe? existing;
      for (final keyframe in next) {
        if (keyframe.property == entry.key &&
            keyframe.time.inMilliseconds == time.inMilliseconds) {
          existing = keyframe;
          break;
        }
      }
      next.removeWhere(
        (keyframe) =>
            keyframe.property == entry.key &&
            keyframe.time.inMilliseconds == time.inMilliseconds,
      );
      next.add(
        existing?.copyWith(
              value: entry.value,
              interpolation: interpolation,
              curve: curve,
            ) ??
            TimelineKeyframe(
              time: time,
              property: entry.key,
              value: entry.value,
              interpolation:
                  interpolation ?? TimelineKeyframeInterpolation.linear,
              curve: curve ?? TimelineBezierCurve.linear,
            ),
      );
    }
    next.sort((a, b) {
      final timeOrder = a.time.compareTo(b.time);
      return timeOrder != 0
          ? timeOrder
          : a.property.index.compareTo(b.property.index);
    });
    return clip.copyWith(keyframes: next);
  }

  /// Captures every animatable value supported by the clip in one undoable
  /// state. A later state automatically interpolates from this snapshot.
  bool upsertKeyframeState({
    required String clipId,
    required Duration absolutePosition,
    TimelineKeyframeInterpolation? interpolation,
    TimelineBezierCurve? curve,
  }) {
    final targetClip = state.timeline.tracks
        .expand((track) => track.clips)
        .where((clip) => clip.id == clipId)
        .firstOrNull;
    final hasAudio = state.timeline.tracks.any(
      (track) => track.clips.any(
        (clip) => clip.id == clipId && state.timeline.clipHasAudio(clip),
      ),
    );
    if (targetClip == null ||
        (!targetClip.supportsTransformKeyframes &&
            !hasAudio &&
            !targetClip.blur.isEnabled)) {
      return false;
    }
    return updateClip(clipId, (clip) {
      final time = _snappedKeyframeTime(clip, absolutePosition);
      final resolvedPosition = clip.startTime + time;
      final transform = clip.transformAt(resolvedPosition);
      final values = <TimelineKeyframeProperty, double>{
        if (clip.supportsTransformKeyframes) ...{
          TimelineKeyframeProperty.opacity: transform.opacity,
          TimelineKeyframeProperty.scale: transform.scale,
          TimelineKeyframeProperty.rotation: transform.rotation,
          TimelineKeyframeProperty.positionX: transform.offsetX,
          TimelineKeyframeProperty.positionY: transform.offsetY,
        },
        if (hasAudio)
          TimelineKeyframeProperty.volume: clip.volumeAt(resolvedPosition),
        if (clip.blur.isEnabled)
          TimelineKeyframeProperty.blurStrength: clip
              .blurAt(resolvedPosition)
              .safeStrength,
      };
      return _upsertKeyframeValues(
        clip,
        time: time,
        values: values,
        interpolation: interpolation,
        curve: curve,
      );
    });
  }

  /// Direct manipulation edits the base transform until the first transform
  /// state exists. Once armed, every later gesture writes a complete state at
  /// the playhead so position, scale, rotation and opacity stay synchronized.
  bool updateClipTransformAt({
    required String clipId,
    required Duration absolutePosition,
    required TimelineTransform Function(TimelineTransform current) mapper,
    bool recordHistory = true,
  }) {
    final hasAudio = state.timeline.tracks.any(
      (track) => track.clips.any(
        (clip) => clip.id == clipId && state.timeline.clipHasAudio(clip),
      ),
    );
    return updateClip(clipId, (clip) {
      final current = clip.supportsTransformKeyframes
          ? clip.transformAt(absolutePosition)
          : clip.transform;
      final updated = mapper(current);
      if (!clip.supportsTransformKeyframes || !clip.hasTransformKeyframes) {
        return clip.copyWith(transform: updated);
      }
      final time = _snappedKeyframeTime(clip, absolutePosition);
      return _upsertKeyframeValues(
        clip,
        time: time,
        values: {
          TimelineKeyframeProperty.opacity: updated.opacity,
          TimelineKeyframeProperty.scale: updated.scale,
          TimelineKeyframeProperty.rotation: updated.rotation,
          TimelineKeyframeProperty.positionX: updated.offsetX,
          TimelineKeyframeProperty.positionY: updated.offsetY,
          if (hasAudio)
            TimelineKeyframeProperty.volume: clip.volumeAt(absolutePosition),
          if (clip.blur.isEnabled)
            TimelineKeyframeProperty.blurStrength: clip
                .blurAt(absolutePosition)
                .safeStrength,
        },
      );
    }, recordHistory: recordHistory);
  }

  bool updateClipVolumeAt({
    required String clipId,
    required Duration absolutePosition,
    required double volume,
    bool recordHistory = true,
  }) {
    return updateClip(clipId, (clip) {
      final safeVolume = volume.clamp(0.0, 2.0).toDouble();
      if (!clip.hasVolumeKeyframes) {
        return clip.copyWith(
          audioMix: clip.audioMix.copyWith(volume: safeVolume),
        );
      }
      final time = _snappedKeyframeTime(clip, absolutePosition);
      final transform = clip.transformAt(absolutePosition);
      return _upsertKeyframeValues(
        clip,
        time: time,
        values: {
          if (clip.hasTransformKeyframes) ...{
            TimelineKeyframeProperty.opacity: transform.opacity,
            TimelineKeyframeProperty.scale: transform.scale,
            TimelineKeyframeProperty.rotation: transform.rotation,
            TimelineKeyframeProperty.positionX: transform.offsetX,
            TimelineKeyframeProperty.positionY: transform.offsetY,
          },
          TimelineKeyframeProperty.volume: safeVolume,
          if (clip.blur.isEnabled)
            TimelineKeyframeProperty.blurStrength: clip
                .blurAt(absolutePosition)
                .safeStrength,
        },
      );
    }, recordHistory: recordHistory);
  }

  bool updateClipBlurStrengthAt({
    required String clipId,
    required Duration absolutePosition,
    required double strength,
    bool recordHistory = true,
  }) {
    return updateClip(clipId, (clip) {
      final safeStrength = strength.clamp(0.0, 30.0).toDouble();
      final hasBlurKeyframes = clip.keyframes.any(
        (keyframe) =>
            keyframe.property == TimelineKeyframeProperty.blurStrength,
      );
      if (!hasBlurKeyframes) {
        return clip.copyWith(blur: clip.blur.copyWith(strength: safeStrength));
      }
      final time = _snappedKeyframeTime(clip, absolutePosition);
      final transform = clip.transformAt(absolutePosition);
      return _upsertKeyframeValues(
        clip,
        time: time,
        values: {
          if (clip.hasTransformKeyframes) ...{
            TimelineKeyframeProperty.opacity: transform.opacity,
            TimelineKeyframeProperty.scale: transform.scale,
            TimelineKeyframeProperty.rotation: transform.rotation,
            TimelineKeyframeProperty.positionX: transform.offsetX,
            TimelineKeyframeProperty.positionY: transform.offsetY,
          },
          if (clip.hasVolumeKeyframes)
            TimelineKeyframeProperty.volume: clip.volumeAt(absolutePosition),
          TimelineKeyframeProperty.blurStrength: safeStrength,
        },
      );
    }, recordHistory: recordHistory);
  }

  bool removeKeyframeState({
    required String clipId,
    required Duration absolutePosition,
  }) {
    return updateClip(clipId, (clip) {
      final time = _snappedKeyframeTime(clip, absolutePosition);
      final next = clip.keyframes
          .where(
            (keyframe) => keyframe.time.inMilliseconds != time.inMilliseconds,
          )
          .toList();
      return clip.copyWith(keyframes: next);
    });
  }

  bool setKeyframeStateCurve({
    required String clipId,
    required Duration absolutePosition,
    required TimelineKeyframeInterpolation interpolation,
    required TimelineBezierCurve curve,
  }) {
    return updateClip(clipId, (clip) {
      final time = _snappedKeyframeTime(clip, absolutePosition);
      final next = clip.keyframes
          .map(
            (keyframe) => keyframe.time.inMilliseconds == time.inMilliseconds
                ? keyframe.copyWith(interpolation: interpolation, curve: curve)
                : keyframe,
          )
          .toList();
      return clip.copyWith(keyframes: next);
    });
  }

  bool removeKeyframes(String clipId, {TimelineKeyframeProperty? property}) {
    return updateClip(clipId, (clip) {
      final next = property == null
          ? const <TimelineKeyframe>[]
          : clip.keyframes
                .where((keyframe) => keyframe.property != property)
                .toList();
      return clip.copyWith(keyframes: next);
    });
  }

  bool renameTrack(String trackId, String name) {
    final cleaned = name.trim();
    if (cleaned.isEmpty) return false;
    final track = state.timeline.tracks
        .where((candidate) => candidate.id == trackId)
        .firstOrNull;
    if (track == null || track.isLocked) return false;
    setTimeline(
      state.timeline.copyWith(
        tracks: state.timeline.tracks
            .map(
              (candidate) => candidate.id == trackId
                  ? candidate.copyWith(name: cleaned)
                  : candidate,
            )
            .toList(),
      ),
    );
    return true;
  }

  bool duplicateTrack(String trackId) {
    final source = state.timeline.tracks
        .where((candidate) => candidate.id == trackId)
        .firstOrNull;
    if (source == null || source.isLocked || !source.isDuplicable) return false;
    final duplicateId = 'track_${DateTime.now().microsecondsSinceEpoch}';
    final duplicatedClipIds = {
      for (final clip in source.clips) clip.id: '${clip.id}_copy_$duplicateId',
    };
    final duplicate = TimelineTrack(
      id: duplicateId,
      name: '${source.name} copy',
      type: source.type,
      section: source.section,
      role: source.role,
      isCollapsed: source.isCollapsed,
      isMuted: source.isMuted,
      isHidden: source.isHidden,
      isSolo: source.isSolo,
      audioGain: source.audioGain,
      audioPan: source.audioPan,
      audioBusId: source.audioBusId,
      syncLocked: source.syncLocked,
      effectStack: source.effectStack.cloneWithNewIds(),
      clips: source.clips
          .map(
            (clip) => clip.copyWith(
              id: duplicatedClipIds[clip.id],
              trackId: duplicateId,
              linkedClipId: duplicatedClipIds[clip.linkedClipId],
              clearLinkedClipId:
                  clip.linkedClipId != null &&
                  !duplicatedClipIds.containsKey(clip.linkedClipId),
              effectStack: clip.effectStack.cloneWithNewIds(),
              clearGroupId: true,
              clearCompoundId: true,
            ),
          )
          .toList(),
    );
    final index = state.timeline.tracks.indexOf(source);
    final tracks = [...state.timeline.tracks]..insert(index + 1, duplicate);
    setTimeline(state.timeline.copyWith(tracks: tracks));
    selectTrack(duplicate.id);
    return true;
  }

  bool reorderTrack(String trackId, int direction) {
    if (direction == 0) return false;
    final source = state.timeline.tracks
        .where((track) => track.id == trackId)
        .firstOrNull;
    if (source == null || !source.isReorderable) return false;
    final sourceIsAudio = source.section == TimelineTrackSection.audio;
    final candidates = state.timeline.tracks
        .where(
          (track) =>
              track.isReorderable &&
              (track.section == TimelineTrackSection.audio) == sourceIsAudio,
        )
        .toList();
    final index = candidates.indexWhere((track) => track.id == trackId);
    final target = index + direction.sign;
    if (index < 0 || target < 0 || target >= candidates.length) return false;
    return reorderTrackTo(trackId, candidates[target].id);
  }

  bool reorderTrackTo(String trackId, String targetTrackId) {
    final next = state.timeline.reorderTrackTo(trackId, targetTrackId);
    if (identical(next, state.timeline)) return false;
    setTimeline(next);
    return true;
  }

  void setAllTracks({
    bool? locked,
    bool? muted,
    bool? hidden,
    bool? collapsed,
  }) {
    setTimeline(
      state.timeline.copyWith(
        tracks: state.timeline.tracks
            .map(
              (track) => track.copyWith(
                isLocked: locked ?? track.isLocked,
                isMuted: muted ?? track.isMuted,
                isHidden: hidden ?? track.isHidden,
                isCollapsed: collapsed ?? track.isCollapsed,
              ),
            )
            .toList(),
      ),
    );
  }

  void setSnappingEnabled(bool enabled) {
    setWorkspaceSettings(
      (settings) => settings.copyWith(
        snapping: settings.snapping.copyWith(enabled: enabled),
      ),
    );
  }

  void reset() {
    _undoStack.clear();
    _redoStack.clear();
    _isTimelineGestureEditing = false;
    _timelineChangedDuringGesture = false;
    _timelineGestureBaseline = null;
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
      selectedClipIds: state.selectedClipIds,
      selectedSubtitleId: subtitleState.selectedEntryId,
      sequence: sequence,
      branch: branch,
    );
  }

  void _restoreSnapshot(_EditorHistorySnapshot snapshot) {
    _isTimelineGestureEditing = false;
    _timelineChangedDuringGesture = false;
    _timelineGestureBaseline = null;
    _restoreEditorSubtitleState(
      entries: snapshot.subtitleEntries,
      globalStyle: snapshot.subtitleStyle,
      selectedEntryId: snapshot.selectedSubtitleId,
    );
    state = state.copyWith(
      timeline: snapshot.timeline,
      isSnappingEnabled: snapshot.timeline.workspaceSettings.snapping.enabled,
      selectedTrackId: snapshot.selectedTrackId,
      selectedClipId: snapshot.selectedClipId,
      selectedClipIds: snapshot.selectedClipIds,
      clearTrackSelection: snapshot.selectedTrackId == null,
      clearClipSelection: snapshot.selectedClipId == null,
      canUndo: canUndo,
      canRedo: canRedo,
      isTimelineGestureEditing: false,
      editRevision: state.editRevision + 1,
    );
  }

  void _refreshHistoryFlags() {
    state = state.copyWith(
      canUndo: canUndo,
      canRedo: canRedo,
      isTimelineGestureEditing: _isTimelineGestureEditing,
    );
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
    var nextTimeline = matchesTimeline
        ? state.timeline
        : state.timeline.mergeSubtitleEntries(
            subtitles: subtitles.entries,
            globalStyle: subtitles.globalStyle,
          );
    if (!matchesTimeline) {
      nextTimeline = nextTimeline.withoutTrackOverlaps();
      final repairedEntries = nextTimeline.subtitleEntries;
      final repairedById = {
        for (final entry in repairedEntries) entry.id: entry,
      };
      final timingsWereRepaired = subtitles.entries.any((entry) {
        final repaired = repairedById[entry.id];
        return repaired != null &&
            (repaired.startTime != entry.startTime ||
                repaired.endTime != entry.endTime);
      });
      if (timingsWereRepaired) {
        _isRestoringEditorSubtitleState = true;
        try {
          _ref
              .read(subtitleProvider.notifier)
              .syncFromTimeline(repairedEntries);
        } finally {
          _isRestoringEditorSubtitleState = false;
        }
      }
    }
    final selectedSubtitleId = subtitles.selectedEntryId;
    final subtitleTrack = selectedSubtitleId == null
        ? null
        : nextTimeline.tracks
              .where(
                (track) =>
                    track.type == TimelineTrackType.subtitle &&
                    track.clips.any((clip) => clip.id == selectedSubtitleId),
              )
              .firstOrNull;
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
        nextTrackId != state.selectedTrackId ||
        nextClipId != state.selectedClipId;
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
      selectedClipIds: nextClipId == null ? const <String>{} : {nextClipId},
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
