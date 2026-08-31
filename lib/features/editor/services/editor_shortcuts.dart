import 'package:flutter/services.dart';

enum EditorShortcutCommand {
  undo,
  redo,
  save,
  export,
  importMedia,
  selectAll,
  togglePlayPause,
  pause,
  playForward,
  stepBackward,
  stepForward,
  nudgeBackward,
  nudgeForward,
  jumpToStart,
  jumpToEnd,
  deleteSelectedClip,
  splitAtPlayhead,
  addMarker,
  toggleFullscreen,
  dismiss,
  showShortcutHelp,
}

EditorShortcutCommand? resolveEditorShortcut({
  required LogicalKeyboardKey key,
  required bool controlOrMeta,
  required bool shift,
  required bool alt,
}) {
  if (controlOrMeta) {
    if (key == LogicalKeyboardKey.keyZ) {
      return shift ? EditorShortcutCommand.redo : EditorShortcutCommand.undo;
    }
    if (key == LogicalKeyboardKey.keyY) return EditorShortcutCommand.redo;
    if (key == LogicalKeyboardKey.keyS) return EditorShortcutCommand.save;
    if (key == LogicalKeyboardKey.keyE) return EditorShortcutCommand.export;
    if (key == LogicalKeyboardKey.keyI) {
      return EditorShortcutCommand.importMedia;
    }
    if (key == LogicalKeyboardKey.keyA) {
      return EditorShortcutCommand.selectAll;
    }
    if (key == LogicalKeyboardKey.keyB) {
      return EditorShortcutCommand.splitAtPlayhead;
    }
    return null;
  }

  if (key == LogicalKeyboardKey.space) {
    return EditorShortcutCommand.togglePlayPause;
  }
  if (key == LogicalKeyboardKey.keyJ) {
    return EditorShortcutCommand.stepBackward;
  }
  if (key == LogicalKeyboardKey.keyK) return EditorShortcutCommand.pause;
  if (key == LogicalKeyboardKey.keyL) {
    return EditorShortcutCommand.playForward;
  }
  if (key == LogicalKeyboardKey.arrowLeft) {
    return alt
        ? EditorShortcutCommand.nudgeBackward
        : EditorShortcutCommand.stepBackward;
  }
  if (key == LogicalKeyboardKey.arrowRight) {
    return alt
        ? EditorShortcutCommand.nudgeForward
        : EditorShortcutCommand.stepForward;
  }
  if (key == LogicalKeyboardKey.home) {
    return EditorShortcutCommand.jumpToStart;
  }
  if (key == LogicalKeyboardKey.end) return EditorShortcutCommand.jumpToEnd;
  if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
    return EditorShortcutCommand.deleteSelectedClip;
  }
  if (key == LogicalKeyboardKey.keyM) {
    return EditorShortcutCommand.addMarker;
  }
  if (key == LogicalKeyboardKey.keyF) {
    return EditorShortcutCommand.toggleFullscreen;
  }
  if (key == LogicalKeyboardKey.escape) return EditorShortcutCommand.dismiss;
  if (shift && key == LogicalKeyboardKey.slash) {
    return EditorShortcutCommand.showShortcutHelp;
  }
  return null;
}

bool isRepeatableEditorShortcut(EditorShortcutCommand command) {
  return command == EditorShortcutCommand.stepBackward ||
      command == EditorShortcutCommand.stepForward ||
      command == EditorShortcutCommand.nudgeBackward ||
      command == EditorShortcutCommand.nudgeForward;
}
