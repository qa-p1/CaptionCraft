import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Orders editor-wide and subtitle-only history without coupling their stacks.
class EditorHistoryClock {
  int _sequence = 0;
  int _branch = 0;

  int get branch => _branch;

  /// Records a new user edit and invalidates redo entries from another stack.
  int recordAction() {
    _branch += 1;
    return ++_sequence;
  }

  /// Orders undo/redo traversal without invalidating the current redo branch.
  int recordTraversal() => ++_sequence;
}

final editorHistoryClockProvider = Provider<EditorHistoryClock>(
  (ref) => EditorHistoryClock(),
);
