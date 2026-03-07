import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';

/// Undo/redo action for the subtitle state.
class SubtitleAction {
  final List<SubtitleEntry> subtitles;
  final SubtitleStyleModel globalStyle;

  SubtitleAction({required this.subtitles, required this.globalStyle});
}

/// State for all subtitle data.
class SubtitleState {
  final List<SubtitleEntry> entries;
  final SubtitleStyleModel globalStyle;
  final String? selectedEntryId;

  const SubtitleState({
    this.entries = const [],
    this.globalStyle = const SubtitleStyleModel(),
    this.selectedEntryId,
  });

  SubtitleEntry? get selectedEntry {
    if (selectedEntryId == null) return null;
    try {
      return entries.firstWhere((e) => e.id == selectedEntryId);
    } catch (_) {
      return null;
    }
  }

  SubtitleState copyWith({
    List<SubtitleEntry>? entries,
    SubtitleStyleModel? globalStyle,
    String? selectedEntryId,
    bool clearSelection = false,
  }) {
    return SubtitleState(
      entries: entries ?? this.entries,
      globalStyle: globalStyle ?? this.globalStyle,
      selectedEntryId: clearSelection
          ? null
          : (selectedEntryId ?? this.selectedEntryId),
    );
  }
}

class SubtitleNotifier extends StateNotifier<SubtitleState> {
  SubtitleNotifier() : super(const SubtitleState());

  final List<SubtitleAction> _undoStack = [];
  final List<SubtitleAction> _redoStack = [];
  static const int _maxStackDepth = 50;
  bool _isTimelineGestureEditing = false;
  bool _isStyleGestureEditing = false;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void _pushUndo() {
    _undoStack.add(
      SubtitleAction(
        subtitles: List.from(state.entries),
        globalStyle: state.globalStyle,
      ),
    );
    if (_undoStack.length > _maxStackDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  void undo() {
    if (!canUndo) return;
    _redoStack.add(
      SubtitleAction(
        subtitles: List.from(state.entries),
        globalStyle: state.globalStyle,
      ),
    );
    final action = _undoStack.removeLast();
    state = state.copyWith(
      entries: action.subtitles,
      globalStyle: action.globalStyle,
    );
  }

  void redo() {
    if (!canRedo) return;
    _undoStack.add(
      SubtitleAction(
        subtitles: List.from(state.entries),
        globalStyle: state.globalStyle,
      ),
    );
    final action = _redoStack.removeLast();
    state = state.copyWith(
      entries: action.subtitles,
      globalStyle: action.globalStyle,
    );
  }

  /// Load subtitles from transcription results.
  void loadSubtitles(List<SubtitleEntry> entries) {
    _pushUndo();
    state = state.copyWith(entries: entries);
  }

  /// Initialize editor state from a persisted project.
  /// This intentionally clears undo/redo stacks to create a clean session baseline.
  void initializeFromProject({
    required List<SubtitleEntry> entries,
    required SubtitleStyleModel globalStyle,
  }) {
    _undoStack.clear();
    _redoStack.clear();
    state = SubtitleState(
      entries: List<SubtitleEntry>.from(entries),
      globalStyle: globalStyle,
      selectedEntryId: null,
    );
  }

  /// Select a subtitle entry.
  void selectEntry(String? id) {
    state = state.copyWith(selectedEntryId: id, clearSelection: id == null);
  }

  /// Update a subtitle's text.
  void updateText(String id, String text) {
    _pushUndo();
    final entries = state.entries.map((e) {
      if (e.id == id) {
        return e.copyWith(text: text);
      }
      return e;
    }).toList();
    state = state.copyWith(entries: entries);
  }

  /// Update a subtitle's timing.
  void updateTiming(
    String id,
    Duration startTime,
    Duration endTime, {
    bool pushUndo = true,
  }) {
    if (pushUndo && !_isTimelineGestureEditing) {
      _pushUndo();
    }
    final entries = state.entries.map((e) {
      if (e.id == id) {
        return e.copyWith(startTime: startTime, endTime: endTime);
      }
      return e;
    }).toList();
    state = state.copyWith(entries: entries);
  }

  void updateTimingLive(String id, Duration startTime, Duration endTime) {
    updateTiming(id, startTime, endTime, pushUndo: false);
  }

  void beginTimelineGestureEdit() {
    if (_isTimelineGestureEditing) return;
    _isTimelineGestureEditing = true;
    _pushUndo();
  }

  void endTimelineGestureEdit() {
    _isTimelineGestureEditing = false;
  }

  /// Add a new empty subtitle entry.
  void addEntry(Duration startTime, Duration endTime) {
    _pushUndo();
    final entry = SubtitleEntry(
      startTime: startTime,
      endTime: endTime,
      text: 'New subtitle',
    );
    state = state.copyWith(
      entries: [...state.entries, entry],
      selectedEntryId: entry.id,
    );
  }

  /// Delete a subtitle entry.
  void deleteEntry(String id) {
    _pushUndo();
    final entries = state.entries.where((e) => e.id != id).toList();
    state = state.copyWith(
      entries: entries,
      clearSelection: state.selectedEntryId == id,
    );
  }

  /// Duplicate a subtitle entry.
  void duplicateEntry(String id) {
    _pushUndo();
    final original = state.entries.firstWhere((e) => e.id == id);
    final copy = SubtitleEntry(
      startTime: original.endTime,
      endTime: original.endTime + original.duration,
      text: original.text,
      styleOverride: original.styleOverride,
    );
    state = state.copyWith(entries: [...state.entries, copy]);
  }

  /// Split a subtitle at a given time.
  void splitEntry(String id, Duration splitAt) {
    _pushUndo();
    final original = state.entries.firstWhere((e) => e.id == id);
    if (splitAt <= original.startTime || splitAt >= original.endTime) return;

    final first = original.copyWith(endTime: splitAt);
    final second = SubtitleEntry(
      startTime: splitAt,
      endTime: original.endTime,
      text: original.text,
    );

    final entries = state.entries.map((e) => e.id == id ? first : e).toList()
      ..add(second);
    state = state.copyWith(entries: entries);
  }

  /// Update the global style.
  void updateGlobalStyle(SubtitleStyleModel style) {
    if (!_isStyleGestureEditing) {
      _pushUndo();
    }
    state = state.copyWith(globalStyle: style);
  }

  void updateGlobalStyleLive(SubtitleStyleModel style) {
    state = state.copyWith(globalStyle: style);
  }

  /// Apply a style preset.
  void applyPreset(SubtitleStyleModel preset) {
    updateGlobalStyle(preset);
  }

  /// Set a per-entry style override.
  void setEntryStyleOverride(String id, SubtitleStyleModel? style) {
    if (!_isStyleGestureEditing) {
      _pushUndo();
    }
    final entries = state.entries.map((e) {
      if (e.id == id) {
        return e.copyWith(
          styleOverride: style,
          clearStyleOverride: style == null,
        );
      }
      return e;
    }).toList();
    state = state.copyWith(entries: entries);
  }

  void setEntryStyleOverrideLive(String id, SubtitleStyleModel? style) {
    final entries = state.entries.map((e) {
      if (e.id == id) {
        return e.copyWith(
          styleOverride: style,
          clearStyleOverride: style == null,
        );
      }
      return e;
    }).toList();
    state = state.copyWith(entries: entries);
  }

  void beginStyleGestureEdit() {
    if (_isStyleGestureEditing) return;
    _isStyleGestureEditing = true;
    _pushUndo();
  }

  void endStyleGestureEdit() {
    _isStyleGestureEditing = false;
  }
}

final subtitleProvider = StateNotifierProvider<SubtitleNotifier, SubtitleState>(
  (ref) {
    return SubtitleNotifier();
  },
);
