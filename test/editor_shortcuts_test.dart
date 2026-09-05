import 'package:caption_craft/features/editor/services/editor_shortcuts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  EditorShortcutCommand? resolve(
    LogicalKeyboardKey key, {
    bool controlOrMeta = false,
    bool shift = false,
    bool alt = false,
  }) {
    return resolveEditorShortcut(
      key: key,
      controlOrMeta: controlOrMeta,
      shift: shift,
      alt: alt,
    );
  }

  test('maps desktop editing commands without platform-specific key codes', () {
    expect(
      resolve(LogicalKeyboardKey.keyZ, controlOrMeta: true),
      EditorShortcutCommand.undo,
    );
    expect(
      resolve(LogicalKeyboardKey.keyZ, controlOrMeta: true, shift: true),
      EditorShortcutCommand.redo,
    );
    expect(
      resolve(LogicalKeyboardKey.keyY, controlOrMeta: true),
      EditorShortcutCommand.redo,
    );
    expect(
      resolve(LogicalKeyboardKey.keyS, controlOrMeta: true),
      EditorShortcutCommand.save,
    );
    expect(
      resolve(LogicalKeyboardKey.keyE, controlOrMeta: true),
      EditorShortcutCommand.export,
    );
    expect(
      resolve(LogicalKeyboardKey.keyI, controlOrMeta: true),
      EditorShortcutCommand.importMedia,
    );
  });

  test('maps transport and timeline commands', () {
    expect(
      resolve(LogicalKeyboardKey.space),
      EditorShortcutCommand.togglePlayPause,
    );
    expect(
      resolve(LogicalKeyboardKey.keyJ),
      EditorShortcutCommand.stepBackward,
    );
    expect(resolve(LogicalKeyboardKey.keyK), EditorShortcutCommand.pause);
    expect(resolve(LogicalKeyboardKey.keyL), EditorShortcutCommand.playForward);
    expect(
      resolve(LogicalKeyboardKey.arrowLeft, alt: true),
      EditorShortcutCommand.nudgeBackward,
    );
    expect(resolve(LogicalKeyboardKey.home), EditorShortcutCommand.jumpToStart);
    expect(resolve(LogicalKeyboardKey.end), EditorShortcutCommand.jumpToEnd);
    expect(
      resolve(LogicalKeyboardKey.arrowUp),
      EditorShortcutCommand.previousEditPoint,
    );
    expect(
      resolve(LogicalKeyboardKey.arrowDown),
      EditorShortcutCommand.nextEditPoint,
    );
    expect(
      resolve(LogicalKeyboardKey.keyI),
      EditorShortcutCommand.setWorkAreaStart,
    );
    expect(
      resolve(LogicalKeyboardKey.keyO),
      EditorShortcutCommand.setWorkAreaEnd,
    );
    expect(
      resolve(LogicalKeyboardKey.keyX, alt: true),
      EditorShortcutCommand.clearWorkArea,
    );
    expect(
      resolve(LogicalKeyboardKey.keyN),
      EditorShortcutCommand.toggleSnapping,
    );
    expect(
      resolve(LogicalKeyboardKey.delete),
      EditorShortcutCommand.deleteSelectedClip,
    );
  });

  test('only navigation commands repeat while a key is held', () {
    expect(
      isRepeatableEditorShortcut(EditorShortcutCommand.stepForward),
      isTrue,
    );
    expect(
      isRepeatableEditorShortcut(EditorShortcutCommand.nudgeBackward),
      isTrue,
    );
    expect(
      isRepeatableEditorShortcut(EditorShortcutCommand.nextEditPoint),
      isTrue,
    );
    expect(isRepeatableEditorShortcut(EditorShortcutCommand.save), isFalse);
    expect(resolve(LogicalKeyboardKey.keyQ, controlOrMeta: true), isNull);
  });
}
