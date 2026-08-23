import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../models/word_timing.dart';
import 'editor_history_clock.dart';

/// Undo/redo action for the subtitle state.
class SubtitleAction {
  final List<SubtitleEntry> subtitles;
  final SubtitleStyleModel globalStyle;
  final int sequence;
  final int branch;

  SubtitleAction({
    required this.subtitles,
    required this.globalStyle,
    required this.sequence,
    required this.branch,
  });
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
  SubtitleNotifier([EditorHistoryClock? historyClock])
    : _historyClock = historyClock ?? EditorHistoryClock(),
      super(const SubtitleState());

  final EditorHistoryClock _historyClock;
  final List<SubtitleAction> _undoStack = [];
  final List<SubtitleAction> _redoStack = [];
  static const int _maxStackDepth = 50;
  bool _isTimelineGestureEditing = false;
  bool _isStyleGestureEditing = false;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo =>
      _redoStack.isNotEmpty && _redoStack.last.branch == _historyClock.branch;
  int? get latestUndoSequence => canUndo ? _undoStack.last.sequence : null;
  int? get latestRedoSequence => canRedo ? _redoStack.last.sequence : null;

  void _pushUndo() {
    final sequence = _historyClock.recordAction();
    _undoStack.add(
      SubtitleAction(
        subtitles: List.from(state.entries),
        globalStyle: state.globalStyle,
        sequence: sequence,
        branch: _historyClock.branch,
      ),
    );
    if (_undoStack.length > _maxStackDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  void undo() {
    if (!canUndo) return;
    final action = _undoStack.removeLast();
    _redoStack.add(
      SubtitleAction(
        subtitles: List.from(state.entries),
        globalStyle: state.globalStyle,
        sequence: _historyClock.recordTraversal(),
        branch: _historyClock.branch,
      ),
    );
    state = state.copyWith(
      entries: action.subtitles,
      globalStyle: action.globalStyle,
    );
  }

  void redo() {
    if (!canRedo) return;
    final action = _redoStack.removeLast();
    _undoStack.add(
      SubtitleAction(
        subtitles: List.from(state.entries),
        globalStyle: state.globalStyle,
        sequence: _historyClock.recordTraversal(),
        branch: _historyClock.branch,
      ),
    );
    state = state.copyWith(
      entries: action.subtitles,
      globalStyle: action.globalStyle,
    );
  }

  /// Load subtitles from transcription results.
  void loadSubtitles(List<SubtitleEntry> entries) {
    _pushUndo();
    state = state.copyWith(entries: _normalizeEntries(entries));
  }

  /// Sync subtitle entries from timeline edits without creating a new undo step.
  void syncFromTimeline(List<SubtitleEntry> entries) {
    final normalizedEntries = _normalizeEntries(entries);
    final existingById = {for (final entry in state.entries) entry.id: entry};
    final isUnchanged =
        normalizedEntries.length == state.entries.length &&
        normalizedEntries.every((entry) {
          final existing = existingById[entry.id];
          return existing != null &&
              existing.startTime == entry.startTime &&
              existing.endTime == entry.endTime &&
              existing.text == entry.text &&
              mapEquals(
                existing.styleOverride?.toJson(),
                entry.styleOverride?.toJson(),
              );
        });
    if (isUnchanged) return;
    final mergedEntries = normalizedEntries.map((entry) {
      final existing = existingById[entry.id];
      if (existing == null) return entry;
      final mappedWords = _remapWords(
        existing,
        newStartTime: entry.startTime,
        newEndTime: entry.endTime,
      );
      return entry.copyWith(
        confidenceScore: existing.confidenceScore,
        words: mappedWords,
      );
    }).toList();
    final selectedId = state.selectedEntryId;
    final hasSelected =
        selectedId != null && mergedEntries.any((e) => e.id == selectedId);
    state = state.copyWith(
      entries: mergedEntries,
      selectedEntryId: hasSelected ? selectedId : null,
      clearSelection: !hasSelected,
    );
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
      entries: _normalizeEntries(entries),
      globalStyle: globalStyle,
      selectedEntryId: null,
    );
  }

  /// Restore a subtitle snapshot owned by the editor-wide history.
  /// This deliberately avoids creating another subtitle-only undo entry.
  void restoreFromEditorHistory({
    required List<SubtitleEntry> entries,
    required SubtitleStyleModel globalStyle,
    String? selectedEntryId,
  }) {
    final hasSelection =
        selectedEntryId != null &&
        entries.any((entry) => entry.id == selectedEntryId);
    state = SubtitleState(
      entries: _normalizeEntries(entries),
      globalStyle: globalStyle,
      selectedEntryId: hasSelection ? selectedEntryId : null,
    );
  }

  /// Select a subtitle entry.
  void selectEntry(String? id) {
    if (state.selectedEntryId == id) return;
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
    final safeStart = startTime < Duration.zero ? Duration.zero : startTime;
    final safeEnd = endTime <= safeStart
        ? safeStart + const Duration(milliseconds: 100)
        : endTime;
    if (pushUndo && !_isTimelineGestureEditing) {
      _pushUndo();
    }
    final entries = state.entries.map((e) {
      if (e.id == id) {
        return e.copyWith(
          startTime: safeStart,
          endTime: safeEnd,
          words: _remapWords(e, newStartTime: safeStart, newEndTime: safeEnd),
        );
      }
      return e;
    }).toList();
    state = state.copyWith(entries: _normalizeEntries(entries));
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
    final safeStart = startTime < Duration.zero ? Duration.zero : startTime;
    final safeEnd = endTime <= safeStart
        ? safeStart + const Duration(seconds: 2)
        : endTime;
    final entry = SubtitleEntry(
      startTime: safeStart,
      endTime: safeEnd,
      text: 'New subtitle',
    );
    state = state.copyWith(
      entries: _normalizeEntries([...state.entries, entry]),
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
    final copyStart = original.endTime;
    final copyEnd = original.endTime + original.duration;
    final copy = SubtitleEntry(
      startTime: copyStart,
      endTime: copyEnd,
      text: original.text,
      styleOverride: original.styleOverride,
      confidenceScore: original.confidenceScore,
      words: _remapWords(
        original,
        newStartTime: copyStart,
        newEndTime: copyEnd,
      ),
    );
    state = state.copyWith(
      entries: _normalizeEntries([...state.entries, copy]),
      selectedEntryId: copy.id,
    );
  }

  void pasteEntry(SubtitleEntry source, {required Duration startTime}) {
    _pushUndo();
    final safeStart = startTime < Duration.zero ? Duration.zero : startTime;
    final copy = SubtitleEntry(
      startTime: safeStart,
      endTime: safeStart + source.duration,
      text: source.text,
      styleOverride: source.styleOverride,
      confidenceScore: source.confidenceScore,
      words: null,
    );
    state = state.copyWith(
      entries: _normalizeEntries([...state.entries, copy]),
      selectedEntryId: copy.id,
    );
  }

  /// Split a subtitle at a given time.
  void splitEntry(String id, Duration splitAt) {
    final original = state.entries.firstWhere((e) => e.id == id);
    if (splitAt <= original.startTime || splitAt >= original.endTime) return;
    _pushUndo();

    final durationMs = original.duration.inMilliseconds;
    final elapsedMs = (splitAt - original.startTime).inMilliseconds;
    final splitRatio = durationMs <= 0 ? 0.5 : elapsedMs / durationMs;
    final textParts = _splitTextNearRatio(original.text, splitRatio);
    final firstWords = original.words
        ?.where((word) => word.startTime < splitAt)
        .toList();
    final secondWords = original.words
        ?.where((word) => word.endTime > splitAt)
        .toList();

    final first = original.copyWith(
      endTime: splitAt,
      text: textParts.$1,
      words: firstWords,
    );
    final second = SubtitleEntry(
      startTime: splitAt,
      endTime: original.endTime,
      text: textParts.$2,
      styleOverride: original.styleOverride,
      confidenceScore: original.confidenceScore,
      words: secondWords,
    );

    final entries = state.entries.map((e) => e.id == id ? first : e).toList()
      ..add(second)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    state = state.copyWith(entries: entries, selectedEntryId: second.id);
  }

  /// Shift every cue by a fixed amount while keeping cues inside the project.
  void shiftAll(Duration offset, {Duration? projectDuration}) {
    if (state.entries.isEmpty || offset == Duration.zero) return;
    _pushUndo();
    final maxMs = projectDuration?.inMilliseconds;
    final shifted = state.entries.map((entry) {
      var startMs = entry.startTime.inMilliseconds + offset.inMilliseconds;
      var endMs = entry.endTime.inMilliseconds + offset.inMilliseconds;
      if (startMs < 0) {
        endMs -= startMs;
        startMs = 0;
      }
      if (maxMs != null && endMs > maxMs) {
        final overshoot = endMs - maxMs;
        startMs = (startMs - overshoot).clamp(0, maxMs).toInt();
        endMs = maxMs;
      }
      final newStartTime = Duration(milliseconds: startMs);
      final newEndTime = Duration(milliseconds: endMs);
      return entry.copyWith(
        startTime: newStartTime,
        endTime: newEndTime,
        words: _remapWords(
          entry,
          newStartTime: newStartTime,
          newEndTime: newEndTime,
        ),
      );
    }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
    state = state.copyWith(entries: _normalizeEntries(shifted));
  }

  int replaceText({
    required String query,
    required String replacement,
    bool matchCase = false,
  }) {
    if (query.isEmpty) return 0;
    final expression = RegExp(RegExp.escape(query), caseSensitive: matchCase);
    var replacements = 0;
    final nextEntries = state.entries.map((entry) {
      final matches = expression.allMatches(entry.text).length;
      if (matches == 0) return entry;
      replacements += matches;
      return entry.copyWith(
        text: entry.text.replaceAll(expression, replacement),
      );
    }).toList();
    if (replacements == 0) return 0;
    _pushUndo();
    state = state.copyWith(entries: nextEntries);
    return replacements;
  }

  void normalizeText() {
    if (state.entries.isEmpty) return;
    _pushUndo();
    final entries = state.entries.map((entry) {
      final cleaned = entry.text
          .replaceAll(RegExp(r'[ \t]+'), ' ')
          .replaceAll(RegExp(r' *\n *'), '\n')
          .trim();
      return entry.copyWith(text: cleaned);
    }).toList();
    state = state.copyWith(entries: entries);
  }

  void convertCase(SubtitleTextCase textCase) {
    if (state.entries.isEmpty) return;
    _pushUndo();
    final entries = state.entries.map((entry) {
      final text = switch (textCase) {
        SubtitleTextCase.sentence => _sentenceCase(entry.text),
        SubtitleTextCase.upper => entry.text.toUpperCase(),
        SubtitleTextCase.lower => entry.text.toLowerCase(),
        SubtitleTextCase.title => _titleCase(entry.text),
      };
      return entry.copyWith(text: text);
    }).toList();
    state = state.copyWith(entries: entries);
  }

  /// Removes cue overlaps within each caption lane.
  ///
  /// Entries from different source videos may intentionally be simultaneous,
  /// so callers that know timeline ownership should provide [laneByEntryId].
  void fixOverlaps({
    Duration minimumGap = const Duration(milliseconds: 80),
    Map<String, String>? laneByEntryId,
  }) {
    if (state.entries.length < 2) return;
    var changed = false;
    final lanes = <String, List<SubtitleEntry>>{};
    for (final entry in state.entries) {
      final laneId = laneByEntryId?[entry.id] ?? '__captions__';
      lanes.putIfAbsent(laneId, () => []).add(entry);
    }
    final replacements = <String, SubtitleEntry>{};
    for (final lane in lanes.values) {
      lane.sort((a, b) => a.startTime.compareTo(b.startTime));
      for (var index = 0; index < lane.length - 1; index++) {
        final entry = lane[index];
        final next = lane[index + 1];
        final latestEnd = next.startTime - minimumGap;
        if (entry.endTime > latestEnd &&
            latestEnd > entry.startTime + const Duration(milliseconds: 100)) {
          replacements[entry.id] = entry.copyWith(
            endTime: latestEnd,
            words: _remapWords(
              entry,
              newStartTime: entry.startTime,
              newEndTime: latestEnd,
            ),
          );
          changed = true;
        }
      }
    }
    if (!changed) return;
    _pushUndo();
    state = state.copyWith(
      entries: state.entries
          .map((entry) => replacements[entry.id] ?? entry)
          .toList(),
    );
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

  List<SubtitleEntry> _normalizeEntries(Iterable<SubtitleEntry> entries) {
    final normalized =
        entries.map((entry) {
          final originalDuration = entry.duration > Duration.zero
              ? entry.duration
              : const Duration(milliseconds: 100);
          final start = entry.startTime < Duration.zero
              ? Duration.zero
              : entry.startTime;
          final end = start + originalDuration;
          if (start == entry.startTime && end == entry.endTime) return entry;
          return entry.copyWith(
            startTime: start,
            endTime: end,
            words: _remapWords(entry, newStartTime: start, newEndTime: end),
          );
        }).toList()..sort((a, b) {
          final byStart = a.startTime.compareTo(b.startTime);
          if (byStart != 0) return byStart;
          final byEnd = a.endTime.compareTo(b.endTime);
          return byEnd != 0 ? byEnd : a.id.compareTo(b.id);
        });
    return normalized;
  }

  List<WordTiming>? _remapWords(
    SubtitleEntry entry, {
    required Duration newStartTime,
    required Duration newEndTime,
  }) {
    final words = entry.words;
    if (words == null) return null;
    if (words.isEmpty) return const [];

    final oldStartMs = entry.startTime.inMilliseconds;
    final oldDurationMs = entry.duration.inMilliseconds;
    final newStartMs = newStartTime.inMilliseconds;
    final newEndMs = newEndTime.inMilliseconds;
    final newDurationMs = newEndMs - newStartMs;
    if (newDurationMs <= 0) return const [];

    return words
        .map((word) {
          int mappedStartMs;
          int mappedEndMs;
          if (oldDurationMs <= 0) {
            final deltaMs = newStartMs - oldStartMs;
            mappedStartMs = word.startTime.inMilliseconds + deltaMs;
            mappedEndMs = word.endTime.inMilliseconds + deltaMs;
          } else {
            final startRatio =
                ((word.startTime.inMilliseconds - oldStartMs) / oldDurationMs)
                    .clamp(0.0, 1.0);
            final endRatio =
                ((word.endTime.inMilliseconds - oldStartMs) / oldDurationMs)
                    .clamp(0.0, 1.0);
            mappedStartMs = newStartMs + (newDurationMs * startRatio).round();
            mappedEndMs = newStartMs + (newDurationMs * endRatio).round();
          }

          mappedStartMs = mappedStartMs.clamp(newStartMs, newEndMs - 1).toInt();
          mappedEndMs = mappedEndMs.clamp(mappedStartMs + 1, newEndMs).toInt();
          return WordTiming(
            word: word.word,
            startTime: Duration(milliseconds: mappedStartMs),
            endTime: Duration(milliseconds: mappedEndMs),
          );
        })
        .toList(growable: false);
  }

  (String, String) _splitTextNearRatio(String text, double ratio) {
    final words = text.trim().split(RegExp(r'\s+'));
    if (words.length < 2) return (text.trim(), text.trim());
    final splitIndex = (words.length * ratio)
        .round()
        .clamp(1, words.length - 1)
        .toInt();
    return (words.take(splitIndex).join(' '), words.skip(splitIndex).join(' '));
  }

  String _sentenceCase(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    final lower = trimmed.toLowerCase();
    return '${lower[0].toUpperCase()}${lower.substring(1)}';
  }

  String _titleCase(String value) {
    return value
        .trim()
        .split(RegExp(r'\s+'))
        .map((word) => _sentenceCase(word))
        .join(' ');
  }
}

enum SubtitleTextCase { sentence, upper, lower, title }

final subtitleProvider = StateNotifierProvider<SubtitleNotifier, SubtitleState>(
  (ref) {
    return SubtitleNotifier(ref.read(editorHistoryClockProvider));
  },
);
