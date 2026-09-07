import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/subtitle_entry.dart';
import '../models/editor_effect_models.dart';
import '../models/timeline_models.dart';
import '../models/word_timing.dart';
import '../providers/editor_provider.dart';
import '../providers/subtitle_provider.dart';
import 'timeline_keyframe_editing.dart';

/// Commands that can be issued by the timeline, keyboard router, menus, and
/// clip context menus.  Keeping the identifiers here gives every entry point
/// the same enabled state and mutation semantics.
enum TimelineEditorCommand {
  copy,
  cut,
  paste,
  duplicate,
  delete,
  rippleDelete,
  splitSelected,
  selectAll,
}

/// Display metadata for a [TimelineEditorCommand].
class TimelineEditorCommandInfo {
  final TimelineEditorCommand command;
  final String label;
  final String? shortcut;

  const TimelineEditorCommandInfo({
    required this.command,
    required this.label,
    this.shortcut,
  });
}

const Map<TimelineEditorCommand, TimelineEditorCommandInfo>
timelineEditorCommandInfo = {
  TimelineEditorCommand.copy: TimelineEditorCommandInfo(
    command: TimelineEditorCommand.copy,
    label: 'Copy',
    shortcut: 'Ctrl+C',
  ),
  TimelineEditorCommand.cut: TimelineEditorCommandInfo(
    command: TimelineEditorCommand.cut,
    label: 'Cut',
    shortcut: 'Ctrl+X',
  ),
  TimelineEditorCommand.paste: TimelineEditorCommandInfo(
    command: TimelineEditorCommand.paste,
    label: 'Paste at playhead',
    shortcut: 'Ctrl+V',
  ),
  TimelineEditorCommand.duplicate: TimelineEditorCommandInfo(
    command: TimelineEditorCommand.duplicate,
    label: 'Duplicate',
    shortcut: 'Ctrl+D',
  ),
  TimelineEditorCommand.delete: TimelineEditorCommandInfo(
    command: TimelineEditorCommand.delete,
    label: 'Delete selection',
    shortcut: 'Delete',
  ),
  TimelineEditorCommand.rippleDelete: TimelineEditorCommandInfo(
    command: TimelineEditorCommand.rippleDelete,
    label: 'Ripple delete',
    shortcut: 'Shift+Delete',
  ),
  TimelineEditorCommand.splitSelected: TimelineEditorCommandInfo(
    command: TimelineEditorCommand.splitSelected,
    label: 'Split selected clip',
    shortcut: 'Ctrl+K',
  ),
  TimelineEditorCommand.selectAll: TimelineEditorCommandInfo(
    command: TimelineEditorCommand.selectAll,
    label: 'Select all clips',
    shortcut: 'Ctrl+A',
  ),
};

/// A clip captured by the shared timeline clipboard.
///
/// [relativeStart] is measured from the earliest copied clip.  Keeping the
/// source track id lets paste retain lane relationships when the source lanes
/// still exist, while the clip snapshot retains effects, source bounds,
/// keyframes, and linked-media metadata.
class TimelineClipboardClip {
  final TimelineClip clip;
  final String sourceTrackId;
  final Duration relativeStart;

  const TimelineClipboardClip({
    required this.clip,
    required this.sourceTrackId,
    required this.relativeStart,
  });
}

/// Shared clipboard state for timeline clips and caption cues.
class TimelineClipboard {
  final List<TimelineClipboardClip> clips;
  final List<SubtitleEntry> subtitles;
  final Duration origin;

  const TimelineClipboard({
    this.clips = const [],
    this.subtitles = const [],
    this.origin = Duration.zero,
  });

  bool get isEmpty => clips.isEmpty && subtitles.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// The command and clipboard boundary shared by desktop menus, shortcuts and
/// [TimelinePanel].
///
/// The controller deliberately uses [EditorNotifier.setTimeline] for timeline
/// edits and then synchronizes captions through [SubtitleNotifier].  That is
/// the same transaction path used by the existing timeline gestures: one
/// completed command creates one editor-wide undo snapshot, and caption timing
/// remains in the editor history rather than creating a second subtitle-only
/// undo action.
class TimelineEditorController extends ChangeNotifier {
  final EditorNotifier editor;
  final SubtitleNotifier subtitles;
  final Duration Function()? playheadPosition;
  final void Function(String message)? onFeedback;

  /// Optional owner callback for the editor's canonical split operation.
  ///
  /// The screen already owns the complete split semantics (keyframe curve
  /// subdivision, reverse/freeze timing, separated audio and caption links).
  /// A desktop workspace can inject that operation here so keyboard/menu split
  /// commands use exactly the same path as the existing editor action.
  final bool Function(TimelineClip clip, Duration splitAt)? splitClipAtPlayhead;

  TimelineClipboard _clipboard = const TimelineClipboard();
  VoidCallback? _cancelGesture;

  TimelineEditorController({
    required this.editor,
    required this.subtitles,
    this.playheadPosition,
    this.onFeedback,
    this.splitClipAtPlayhead,
  });

  EditorState get _editorState => editor.currentState;
  SubtitleState get _subtitleState => subtitles.currentState;

  TimelineClipboard get clipboard => _clipboard;
  bool get hasClipboard => _clipboard.isNotEmpty;

  /// The timeline panel binds its active pointer gesture here.  The callback
  /// is intentionally optional so a workspace can create the controller
  /// before the panel is mounted.
  void bindGestureCancellation(VoidCallback? callback) {
    _cancelGesture = callback;
  }

  void cancelActiveGesture() => _cancelGesture?.call();

  /// Lets menu surfaces rebuild enabled states after selection changes.
  void refresh() => notifyListeners();

  TimelineEditorCommandInfo info(TimelineEditorCommand command) =>
      timelineEditorCommandInfo[command]!;

  bool canExecute(TimelineEditorCommand command) {
    switch (command) {
      case TimelineEditorCommand.copy:
        return _selectedClipsWithTracks.isNotEmpty || _selectedSubtitle != null;
      case TimelineEditorCommand.cut:
      case TimelineEditorCommand.delete:
        return _hasEditableSelection;
      case TimelineEditorCommand.paste:
        return hasClipboard && _canPaste;
      case TimelineEditorCommand.duplicate:
        return _hasEditableSelection;
      case TimelineEditorCommand.rippleDelete:
        return _canRippleDelete;
      case TimelineEditorCommand.splitSelected:
        return _canSplitSelected;
      case TimelineEditorCommand.selectAll:
        return _allClipIds.isNotEmpty;
    }
  }

  /// Executes a command and returns whether it changed project state.
  bool execute(TimelineEditorCommand command) {
    switch (command) {
      case TimelineEditorCommand.copy:
        return copySelection();
      case TimelineEditorCommand.cut:
        return cutSelection();
      case TimelineEditorCommand.paste:
        return pasteAtPlayhead();
      case TimelineEditorCommand.duplicate:
        return duplicateSelection();
      case TimelineEditorCommand.delete:
        return deleteSelection();
      case TimelineEditorCommand.rippleDelete:
        return deleteSelection(ripple: true);
      case TimelineEditorCommand.splitSelected:
        return splitSelected();
      case TimelineEditorCommand.selectAll:
        return selectAll();
    }
  }

  bool copySelection() {
    final selected = _selectedClipsWithTracks;
    final selectedSubtitle = _selectedSubtitle;
    if (selected.isEmpty && selectedSubtitle == null) return false;

    if (selected.isEmpty && selectedSubtitle != null) {
      _clipboard = TimelineClipboard(
        subtitles: [selectedSubtitle],
        origin: selectedSubtitle.startTime,
      );
      notifyListeners();
      _feedback('Subtitle copied');
      return true;
    }

    // Include every linked/separated companion when the user selects either
    // side. This preserves the relationship on paste and avoids silently
    // detaching source audio from a selected video clip.
    final clips = _expandedSelectionEntries(selected);
    final origin = clips
        .map((entry) => entry.$2.startTime)
        .reduce((a, b) => a < b ? a : b);
    _clipboard = TimelineClipboard(
      origin: origin,
      clips: [
        for (final entry in clips)
          TimelineClipboardClip(
            clip: entry.$2,
            sourceTrackId: entry.$1.id,
            relativeStart: entry.$2.startTime - origin,
          ),
      ],
    );
    notifyListeners();
    _feedback('${clips.length} ${clips.length == 1 ? 'clip' : 'clips'} copied');
    return true;
  }

  bool cutSelection() {
    if (!canExecute(TimelineEditorCommand.cut)) return false;
    copySelection();
    return deleteSelection();
  }

  bool pasteAtPlayhead() {
    if (!canExecute(TimelineEditorCommand.paste)) return false;
    return _pasteAt(playheadPosition?.call() ?? Duration.zero);
  }

  bool duplicateSelection() {
    if (!canExecute(TimelineEditorCommand.duplicate)) return false;
    final copied = copySelection();
    if (!copied) return false;
    // Duplicates follow the selected range.  The target is still validated by
    // the same lane and overlap checks as ordinary paste.
    return _pasteAt(_selectionEnd);
  }

  bool deleteSelection({bool ripple = false}) {
    if (ripple) {
      if (!canExecute(TimelineEditorCommand.rippleDelete)) return false;
      return _delete(ripple: true);
    }
    if (!canExecute(TimelineEditorCommand.delete)) return false;
    return _delete();
  }

  bool selectAll() {
    final ids = _allClipIds;
    if (ids.isEmpty) return false;
    editor.selectClipIds(ids);
    notifyListeners();
    return true;
  }

  bool splitSelected() {
    if (!canExecute(TimelineEditorCommand.splitSelected)) return false;
    final selected = _selectedClipsWithTracks;
    final primaryId = _editorState.selectedClipId;
    final selectedEntry = primaryId == null
        ? selected.first
        : selected.where((entry) => entry.$2.id == primaryId).firstOrNull ??
              selected.first;
    final track = selectedEntry.$1;
    final clip = selectedEntry.$2;
    final splitAt = playheadPosition?.call() ?? Duration.zero;
    if (splitAt <= clip.startTime || splitAt >= clip.endTime) return false;

    final canonicalSplit = splitClipAtPlayhead;
    if (canonicalSplit != null) {
      // The screen owns the full split semantics. Route keyboard, menu and
      // context-menu commands through that operation whenever the workspace
      // provides it, so there is one implementation and one undo step.
      final changed = canonicalSplit(clip, splitAt);
      if (changed) notifyListeners();
      return changed;
    }

    final firstDuration = splitAt - clip.startTime;
    final sourceOffsetMs = (firstDuration.inMilliseconds * clip.playbackRate)
        .round();
    final sourceTotalMs = math.max(
      sourceOffsetMs + 1,
      clip.sourceDuration.inMilliseconds,
    );
    final sourceFirst = Duration(milliseconds: sourceOffsetMs);
    final keyframeSplit = TimelineKeyframeEditing.split(clip, firstDuration);
    final effectStackSplit = clip.effectStack.splitAt(firstDuration);
    final secondId = const Uuid().v4();
    final first = clip.copyWith(
      endTime: splitAt,
      sourceStartTime: clip.isReversed
          ? clip.sourceStartTime +
                Duration(milliseconds: sourceTotalMs - sourceOffsetMs)
          : clip.sourceStartTime,
      sourceDuration: sourceFirst,
      keyframes: keyframeSplit.leading,
      effectStack: effectStackSplit.leading,
      outroTransition: const ClipTransition(),
      audioMix: clip.audioMix.copyWith(fadeOutMs: 0),
    );
    final second = clip.copyWith(
      id: secondId,
      startTime: splitAt,
      endTime: clip.endTime,
      sourceStartTime: clip.isReversed
          ? clip.sourceStartTime
          : clip.sourceStartTime + sourceFirst,
      sourceDuration: Duration(milliseconds: sourceTotalMs - sourceOffsetMs),
      keyframes: keyframeSplit.trailing,
      effectStack: effectStackSplit.trailing,
      introTransition: const ClipTransition(),
      audioMix: clip.audioMix.copyWith(fadeInMs: 0),
    );
    final sourceTimeline = _editorState.timeline;
    final nextTracks = sourceTimeline.tracks.map((candidate) {
      if (candidate.id == track.id) {
        final clips =
            candidate.clips
                .map(
                  (candidateClip) =>
                      candidateClip.id == clip.id ? first : candidateClip,
                )
                .toList()
              ..add(second)
              ..sort((a, b) => a.startTime.compareTo(b.startTime));
        return candidate.copyWith(clips: clips);
      }
      if (candidate.isLocked) return candidate;
      final clips = <TimelineClip>[];
      for (final candidateClip in candidate.clips) {
        if (_isExactSeparatedAudioMirror(video: clip, audio: candidateClip)) {
          final audioKeyframes = TimelineKeyframeEditing.split(
            candidateClip,
            firstDuration,
          );
          final audioEffects = candidateClip.effectStack.splitAt(firstDuration);
          clips
            ..add(
              candidateClip.copyWith(
                endTime: splitAt,
                sourceStartTime: first.sourceStartTime,
                sourceDuration: first.sourceDuration,
                keyframes: audioKeyframes.leading,
                effectStack: audioEffects.leading,
                outroTransition: const ClipTransition(),
                audioMix: candidateClip.audioMix.copyWith(fadeOutMs: 0),
              ),
            )
            ..add(
              candidateClip.copyWith(
                id: const Uuid().v4(),
                linkedClipId: second.id,
                separatedFromClipId: second.id,
                startTime: splitAt,
                endTime: second.endTime,
                sourceStartTime: second.sourceStartTime,
                sourceDuration: second.sourceDuration,
                keyframes: audioKeyframes.trailing,
                effectStack: audioEffects.trailing,
                introTransition: const ClipTransition(),
                audioMix: candidateClip.audioMix.copyWith(fadeInMs: 0),
              ),
            );
          continue;
        }
        if (candidateClip.type == TimelineTrackType.subtitle &&
            candidateClip.linkedClipId == clip.id) {
          if (candidateClip.endTime <= splitAt) {
            clips.add(candidateClip);
          } else if (candidateClip.startTime >= splitAt) {
            clips.add(candidateClip.copyWith(linkedClipId: second.id));
          } else {
            clips
              ..add(candidateClip.copyWith(endTime: splitAt))
              ..add(
                candidateClip.copyWith(
                  id: const Uuid().v4(),
                  linkedClipId: second.id,
                  startTime: splitAt,
                ),
              );
          }
          continue;
        }
        clips.add(candidateClip);
      }
      clips.sort((a, b) => a.startTime.compareTo(b.startTime));
      return candidate.copyWith(clips: clips);
    }).toList();
    final nextTimeline = sourceTimeline.copyWith(
      tracks: nextTracks,
      groups: sourceTimeline.groups
          .map(
            (group) => group.id == clip.groupId
                ? group.copyWith(clipIds: [...group.clipIds, secondId])
                : group,
          )
          .toList(),
      compoundClips: sourceTimeline.compoundClips
          .map(
            (compound) => compound.id == clip.compoundId
                ? compound.copyWith(clipIds: [...compound.clipIds, secondId])
                : compound,
          )
          .toList(),
    );
    final nextEntries = nextTimeline.subtitleEntries;
    if (!_commit(nextTimeline, entries: nextEntries)) return false;
    editor.selectClipIds({first.id, second.id});
    notifyListeners();
    return true;
  }

  bool get _hasEditableSelection {
    final selected = _selectedClipsWithTracks;
    if (selected.isEmpty) {
      final selectedSubtitle = _selectedSubtitle;
      if (selectedSubtitle == null) return false;
      final subtitleTracks = _editorState.timeline.tracks.where(
        (track) => track.type == TimelineTrackType.subtitle,
      );
      return subtitleTracks.isNotEmpty &&
          subtitleTracks.any(
            (track) =>
                track.clips.any((clip) => clip.id == selectedSubtitle.id) &&
                !track.isLocked,
          );
    }
    final editableClosure = _expandedSelectionEntries(selected);
    return editableClosure.isNotEmpty &&
        editableClosure.every((entry) => !entry.$1.isLocked);
  }

  bool get _canPaste {
    if (_clipboard.subtitles.isNotEmpty) {
      return _editorState.timeline.insertionTrackFor(
            section: TimelineTrackSection.textSubtitle,
            clipType: TimelineTrackType.subtitle,
            preferredTrackId: _editorState.selectedTrackId,
          ) !=
          null;
    }
    return _canPasteAt(playheadPosition?.call() ?? Duration.zero);
  }

  bool _canPasteAt(Duration start) {
    if (_clipboard.clips.isEmpty) return _clipboard.subtitles.isNotEmpty;
    final targets = _resolvePasteTracks();
    if (targets == null) return false;
    for (final item in _clipboard.clips) {
      final target = targets[item.sourceTrackId];
      if (target == null) return false;
      final nextStart = start + item.relativeStart;
      final candidate = item.clip.copyWith(
        id: '__probe_${item.clip.id}',
        trackId: target.id,
        startTime: nextStart,
        endTime: nextStart + item.clip.duration,
      );
      if (!target.canPlaceClip(candidate)) return false;
    }
    return true;
  }

  bool get _canSplitSelected {
    final selected = _selectedClipsWithTracks;
    if (selected.length != 1) return false;
    final closure = _expandedSelectionEntries(selected);
    if (selected.first.$1.isLocked ||
        closure.any((entry) => entry.$1.isLocked)) {
      return false;
    }
    final position = playheadPosition?.call() ?? Duration.zero;
    return position > selected.first.$2.startTime &&
        position < selected.first.$2.endTime;
  }

  bool get _canRippleDelete {
    final selected = _selectedClipsWithTracks;
    final closure = _expandedSelectionEntries(selected);
    if (selected.isEmpty ||
        closure.isEmpty ||
        closure.any((entry) => entry.$1.isLocked)) {
      return false;
    }
    final ids = closure.map((entry) => entry.$2.id).toSet();
    final all = _allClipsWithTracks;
    final rangeStart = selected
        .map((entry) => entry.$2.startTime)
        .reduce((a, b) => a < b ? a : b);
    final rangeEnd = selected
        .map((entry) => entry.$2.endTime)
        .reduce((a, b) => a > b ? a : b);
    for (final entry in all) {
      final clip = entry.$2;
      if (ids.contains(clip.id)) {
        if (entry.$1.isLocked) return false;
        continue;
      }
      final intersects = clip.startTime < rangeEnd && clip.endTime > rangeStart;
      if (intersects) return false;
      if (clip.startTime >= rangeEnd && entry.$1.isLocked) return false;
    }
    return rangeEnd > rangeStart;
  }

  bool _delete({bool ripple = false}) {
    // Re-check the complete relationship closure immediately before applying
    // the mutation. Selection and lock state may have changed since a menu
    // computed its enabled state; deleting only the explicit side could remove
    // a locked linked/separated companion.
    if (!_hasEditableSelection) return false;
    final selected = _selectedClipsWithTracks;
    final selectedIds = _expandedSelectionIds(selected);
    final timeline = _editorState.timeline;
    final selectedSubtitle = _selectedSubtitle;
    if (selected.isEmpty && selectedSubtitle != null) {
      final nextEntries = _subtitleState.entries
          .where((entry) => entry.id != selectedSubtitle.id)
          .toList();
      final changed = nextEntries.length != _subtitleState.entries.length;
      if (!changed) return false;
      // Subtitle entries are mirrored into timeline clips. Removing only the
      // provider entry and then syncing from [timeline] would immediately
      // resurrect the cue, so remove both representations in one transaction.
      final nextTimeline = timeline
          .copyWith(
            tracks: timeline.tracks
                .map(
                  (track) => track.type == TimelineTrackType.subtitle
                      ? track.copyWith(
                          clips: track.clips
                              .where((clip) => clip.id != selectedSubtitle.id)
                              .toList(),
                        )
                      : track,
                )
                .toList(),
          )
          .prunedRelationships();
      if (!_commit(nextTimeline, entries: nextEntries)) return false;
      editor.clearClipSelection();
      subtitles.selectEntry(null);
      notifyListeners();
      return true;
    }
    if (selectedIds.isEmpty) return false;
    final rangeStart = selected
        .map((entry) => entry.$2.startTime)
        .reduce((a, b) => a < b ? a : b);
    final rangeEnd = selected
        .map((entry) => entry.$2.endTime)
        .reduce((a, b) => a > b ? a : b);
    final rippleDuration = rangeEnd - rangeStart;
    final nextTracks = timeline.tracks.map((track) {
      var nextClips = track.clips
          .where((clip) => !selectedIds.contains(clip.id))
          .toList();
      if (ripple) {
        nextClips = nextClips.map((clip) {
          if (clip.startTime < rangeEnd) return clip;
          return clip.copyWith(
            startTime: clip.startTime - rippleDuration,
            endTime: clip.endTime - rippleDuration,
          );
        }).toList();
      }
      nextClips.sort((a, b) => a.startTime.compareTo(b.startTime));
      return track.copyWith(clips: nextClips);
    }).toList();
    final nextTimeline = timeline
        .copyWith(tracks: nextTracks)
        .prunedRelationships();
    if (!_commit(nextTimeline)) return false;
    editor.clearClipSelection();
    subtitles.selectEntry(null);
    notifyListeners();
    return true;
  }

  bool _pasteAt(Duration targetStart) {
    if (_clipboard.subtitles.isNotEmpty && _clipboard.clips.isEmpty) {
      final targetTrack = _editorState.timeline.insertionTrackFor(
        section: TimelineTrackSection.textSubtitle,
        clipType: TimelineTrackType.subtitle,
        preferredTrackId: _editorState.selectedTrackId,
      );
      if (targetTrack == null) {
        _feedback('Unlock a subtitle track before pasting captions');
        return false;
      }
      final entries = <SubtitleEntry>[..._subtitleState.entries];
      final clips = <TimelineClip>[];
      for (final source in _clipboard.subtitles) {
        final newId = const Uuid().v4();
        final offset = source.startTime - _clipboard.origin;
        final nextStart = targetStart + offset;
        final shiftedEntry = source.copyWith(
          id: newId,
          startTime: nextStart,
          endTime: nextStart + source.duration,
          words: source.words
              ?.map(
                (word) => WordTiming(
                  word: word.word,
                  startTime: word.startTime + offset,
                  endTime: word.endTime + offset,
                ),
              )
              .toList(),
        );
        final candidate = TimelineClip.fromSubtitleEntry(
          shiftedEntry,
          trackId: targetTrack.id,
        );
        if (!targetTrack.canPlaceClip(candidate)) {
          _feedback('There is no free space in the subtitle track');
          return false;
        }
        clips.add(candidate);
        // [shiftedEntry] already owns the fresh cue/clip id and preserves the
        // source cue's relative offset, style and word timings.
        entries.add(shiftedEntry);
      }
      final tracks = _editorState.timeline.tracks.map((track) {
        if (track.id != targetTrack.id) return track;
        return track.copyWith(clips: [...track.clips, ...clips]);
      }).toList();
      if (!_commit(
        _editorState.timeline.copyWith(tracks: tracks),
        entries: entries,
      )) {
        return false;
      }
      editor.selectClipIds(clips.map((clip) => clip.id));
      notifyListeners();
      return true;
    }

    final targets = _resolvePasteTracks();
    if (targets == null || _clipboard.clips.isEmpty) {
      _feedback('The copied clip tracks are unavailable or locked');
      return false;
    }
    final idMap = <String, String>{
      for (final item in _clipboard.clips) item.clip.id: const Uuid().v4(),
    };
    final sourceTimeline = _editorState.timeline;
    final groupIdMap = <String, String>{};
    final compoundIdMap = <String, String>{};
    for (final item in _clipboard.clips) {
      final old = item.clip;
      if (old.groupId != null &&
          sourceTimeline.groups.any((group) => group.id == old.groupId)) {
        groupIdMap.putIfAbsent(old.groupId!, const Uuid().v4);
      }
      if (old.compoundId != null &&
          sourceTimeline.compoundClips.any(
            (compound) => compound.id == old.compoundId,
          )) {
        compoundIdMap.putIfAbsent(old.compoundId!, const Uuid().v4);
      }
    }
    final added = <String, List<TimelineClip>>{};
    final working = <String, TimelineTrack>{
      for (final track in _editorState.timeline.tracks) track.id: track,
    };
    final newIds = <String>[];
    for (final item in _clipboard.clips) {
      final target = targets[item.sourceTrackId];
      if (target == null) return false;
      final start = targetStart + item.relativeStart;
      final old = item.clip;
      final linkedId = old.linkedClipId == null
          ? null
          : idMap[old.linkedClipId!];
      final separatedFromId = old.separatedFromClipId == null
          ? null
          : idMap[old.separatedFromClipId!];
      final clone = _cloneClip(
        old,
        id: idMap[old.id]!,
        trackId: target.id,
        startTime: start,
        linkedClipId: linkedId,
        clearLinkedClipId: old.linkedClipId != null && linkedId == null,
        separatedFromClipId: separatedFromId,
        clearSeparatedFromClipId:
            old.separatedFromClipId != null && separatedFromId == null,
        groupId: groupIdMap[old.groupId],
        clearGroupId: old.groupId != null && groupIdMap[old.groupId] == null,
        compoundId: compoundIdMap[old.compoundId],
        clearCompoundId:
            old.compoundId != null && compoundIdMap[old.compoundId] == null,
      );
      final current = working[target.id]!;
      final probe = current.copyWith(
        clips: [...current.clips, ...(added[target.id] ?? const []), clone],
      );
      if (!probe.canPlaceClip(clone, ignoringClipId: clone.id)) {
        _feedback('There is no free space for the pasted selection');
        return false;
      }
      added.putIfAbsent(target.id, () => <TimelineClip>[]).add(clone);
      newIds.add(clone.id);
    }
    final pastedClipIds = idMap.values.toSet();
    final extraGroups = sourceTimeline.groups
        .where((group) => groupIdMap.containsKey(group.id))
        .map(
          (group) => TimelineGroup(
            id: groupIdMap[group.id],
            name: group.name,
            enabled: group.enabled,
            clipIds: group.clipIds
                .where(idMap.containsKey)
                .map((clipId) => idMap[clipId]!)
                .where(pastedClipIds.contains),
          ),
        )
        .where((group) => group.clipIds.isNotEmpty)
        .toList();
    final extraCompounds = sourceTimeline.compoundClips
        .where((compound) => compoundIdMap.containsKey(compound.id))
        .map(
          (compound) => TimelineCompoundClip(
            id: compoundIdMap[compound.id],
            name: compound.name,
            enabled: compound.enabled,
            clipIds: compound.clipIds
                .where(idMap.containsKey)
                .map((clipId) => idMap[clipId]!)
                .where(pastedClipIds.contains),
          ),
        )
        .where((compound) => compound.clipIds.isNotEmpty)
        .toList();
    final extraEffectContainers = sourceTimeline.effectContainers
        .map((container) {
          final mappedTarget = switch (container.scope) {
            EditorEffectScope.clip ||
            EditorEffectScope.adjustmentLayer => idMap[container.targetId],
            EditorEffectScope.group => groupIdMap[container.targetId],
            EditorEffectScope.compound => compoundIdMap[container.targetId],
            _ => null,
          };
          if (mappedTarget == null) return null;
          return EditorEffectContainer(
            scope: container.scope,
            targetId: mappedTarget,
            label: container.label,
            enabled: container.enabled,
            stack: container.stack.cloneWithNewIds(),
          );
        })
        .whereType<EditorEffectContainer>()
        .toList();
    final tracks = sourceTimeline.tracks.map((track) {
      final extra = added[track.id];
      if (extra == null) return track;
      return track.copyWith(clips: [...track.clips, ...extra]);
    }).toList();
    if (!_commit(
      sourceTimeline.copyWith(
        tracks: tracks,
        groups: [...sourceTimeline.groups, ...extraGroups],
        compoundClips: [...sourceTimeline.compoundClips, ...extraCompounds],
        effectContainers: [
          ...sourceTimeline.effectContainers,
          ...extraEffectContainers,
        ],
      ),
    )) {
      return false;
    }
    editor.selectClipIds(newIds);
    notifyListeners();
    return true;
  }

  Map<String, TimelineTrack>? _resolvePasteTracks() {
    final tracks = _editorState.timeline.tracks;
    final result = <String, TimelineTrack>{};
    for (final sourceId
        in _clipboard.clips.map((item) => item.sourceTrackId).toSet()) {
      final source = tracks.where((track) => track.id == sourceId).firstOrNull;
      TimelineTrack? target;
      if (source != null &&
          !source.isLocked &&
          source.acceptsClipType(
            _clipboard.clips
                .firstWhere((item) => item.sourceTrackId == sourceId)
                .clip
                .type,
          )) {
        target = source;
      } else {
        final sourceSection = source?.section;
        target = tracks.firstWhereOrNull((track) {
          final type = _clipboard.clips
              .firstWhere((item) => item.sourceTrackId == sourceId)
              .clip
              .type;
          return !track.isLocked &&
              !track.isSourceTrack &&
              track.acceptsClipType(type) &&
              (sourceSection == null || track.section == sourceSection);
        });
        target ??= tracks.firstWhereOrNull((track) {
          final type = _clipboard.clips
              .firstWhere((item) => item.sourceTrackId == sourceId)
              .clip
              .type;
          return !track.isLocked &&
              !track.isSourceTrack &&
              track.acceptsClipType(type);
        });
      }
      if (target == null) return null;
      result[sourceId] = target;
    }
    return result;
  }

  TimelineClip _cloneClip(
    TimelineClip source, {
    required String id,
    required String trackId,
    required Duration startTime,
    String? linkedClipId,
    bool clearLinkedClipId = false,
    String? separatedFromClipId,
    bool clearSeparatedFromClipId = false,
    String? groupId,
    bool clearGroupId = false,
    String? compoundId,
    bool clearCompoundId = false,
  }) {
    return source.copyWith(
      id: id,
      trackId: trackId,
      startTime: startTime,
      endTime: startTime + source.duration,
      linkedClipId: linkedClipId,
      clearLinkedClipId: clearLinkedClipId,
      separatedFromClipId: separatedFromClipId,
      clearSeparatedFromClipId: clearSeparatedFromClipId,
      groupId: groupId,
      clearGroupId: clearGroupId,
      compoundId: compoundId,
      clearCompoundId: clearCompoundId,
      effectStack: source.effectStack.cloneWithNewIds(),
      keyframes: [
        for (final keyframe in source.keyframes)
          TimelineKeyframe(
            time: keyframe.time,
            property: keyframe.property,
            value: keyframe.value,
            interpolation: keyframe.interpolation,
            curve: keyframe.curve,
          ),
      ],
    );
  }

  bool _isExactSeparatedAudioMirror({
    required TimelineClip video,
    required TimelineClip audio,
  }) {
    return video.type == TimelineTrackType.video &&
        audio.type == TimelineTrackType.audio &&
        audio.linkedClipId == video.id &&
        audio.separatedAudioSourceClipId == video.id &&
        audio.assetId == video.assetId &&
        audio.startTime == video.startTime &&
        audio.endTime == video.endTime &&
        audio.sourceStartTime == video.sourceStartTime &&
        audio.sourceDuration == video.sourceDuration &&
        (audio.playbackRate - video.playbackRate).abs() < 0.0001 &&
        audio.isReversed == video.isReversed;
  }

  bool _commit(EditorTimeline next, {List<SubtitleEntry>? entries}) {
    // Check the operation's actual candidates before normalization. The model
    // repair helper is intentionally allowed to move malformed overlaps, which
    // would otherwise turn a rejected edit into a silently different edit.
    if (next.hasTrackOverlaps) {
      _feedback('That edit would overlap another clip in the same track');
      return false;
    }
    if (identical(next, _editorState.timeline) && entries == null) {
      return false;
    }
    if (entries != null) {
      // Keep timeline clips and subtitle cues in one editor-wide history
      // snapshot. Calling setTimeline followed by a subtitle mutation creates
      // two undo actions and can sync the removed cue back into the timeline.
      editor.replaceTimelineAndSubtitleEntries(
        timeline: next,
        entries: entries,
      );
      return true;
    }
    editor.setTimeline(next);
    subtitles.syncFromTimeline(next.subtitleEntries);
    return true;
  }

  Set<String> _expandedSelectionIds(
    Iterable<(TimelineTrack, TimelineClip)> selected,
  ) {
    final ids = _expandedSelectionEntries(
      selected,
    ).map((entry) => entry.$2.id).toSet();
    return ids;
  }

  /// Returns the symmetric relationship closure for an explicit selection.
  ///
  /// Links in older projects are not always stored in the same direction:
  /// video commonly points to audio through [linkedClipId], while separated
  /// audio points back through [separatedFromClipId]. Walking both fields in
  /// both directions keeps selection, copy and destructive commands atomic.
  List<(TimelineTrack, TimelineClip)> _expandedSelectionEntries(
    Iterable<(TimelineTrack, TimelineClip)> selected,
  ) {
    final ids = selected.map((entry) => entry.$2.id).toSet();
    var changed = true;
    final all = _allClipsWithTracks;
    while (changed) {
      changed = false;
      for (final entry in all) {
        final clip = entry.$2;
        if (ids.contains(clip.id)) continue;
        final referencesSelected =
            ids.contains(clip.linkedClipId) ||
            ids.contains(clip.separatedFromClipId) ||
            all.any((candidate) {
              final other = candidate.$2;
              return ids.contains(other.id) &&
                  (other.linkedClipId == clip.id ||
                      other.separatedFromClipId == clip.id);
            });
        if (referencesSelected) {
          ids.add(clip.id);
          changed = true;
        }
      }
    }
    return all
        .where((entry) => ids.contains(entry.$2.id))
        .toList(growable: false);
  }

  List<(TimelineTrack, TimelineClip)> get _selectedClipsWithTracks {
    final ids = _editorState.selectedClipIds.isNotEmpty
        ? _editorState.selectedClipIds
        : {
            if (_editorState.selectedClipId != null)
              _editorState.selectedClipId!,
          };
    return _allClipsWithTracks
        .where((entry) => ids.contains(entry.$2.id))
        .toList(growable: false);
  }

  List<(TimelineTrack, TimelineClip)> get _allClipsWithTracks => [
    for (final track in _editorState.timeline.tracks)
      for (final clip in track.clips) (track, clip),
  ];

  Set<String> get _allClipIds =>
      _allClipsWithTracks.map((e) => e.$2.id).toSet();

  SubtitleEntry? get _selectedSubtitle {
    final selectedId = _subtitleState.selectedEntryId;
    if (selectedId == null) return null;
    return _subtitleState.entries
        .where((entry) => entry.id == selectedId)
        .firstOrNull;
  }

  Duration get _selectionEnd {
    final selected = _selectedClipsWithTracks;
    if (selected.isEmpty) return playheadPosition?.call() ?? Duration.zero;
    return selected
        .map((entry) => entry.$2.endTime)
        .reduce((a, b) => a > b ? a : b);
  }

  void _feedback(String message) => onFeedback?.call(message);
}

extension<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T value) test) {
    for (final value in this) {
      if (test(value)) return value;
    }
    return null;
  }
}
