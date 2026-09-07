import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';

enum DesktopSplitterAxis { horizontal, vertical }

/// Mouse-friendly divider used by the desktop workspace.
class DesktopSplitter extends StatefulWidget {
  final DesktopSplitterAxis axis;
  final ValueChanged<double> onDelta;
  final VoidCallback? onDoubleTap;
  final String semanticsLabel;

  const DesktopSplitter({
    super.key,
    required this.axis,
    required this.onDelta,
    this.onDoubleTap,
    required this.semanticsLabel,
  });

  @override
  State<DesktopSplitter> createState() => _DesktopSplitterState();
}

class _DesktopSplitterState extends State<DesktopSplitter> {
  bool _hovered = false;
  bool _dragging = false;

  bool get _isVertical => widget.axis == DesktopSplitterAxis.vertical;

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final logicalKey = event.logicalKey;
    final isForward = _isVertical
        ? logicalKey == LogicalKeyboardKey.arrowRight
        : logicalKey == LogicalKeyboardKey.arrowDown;
    final isBackward = _isVertical
        ? logicalKey == LogicalKeyboardKey.arrowLeft
        : logicalKey == LogicalKeyboardKey.arrowUp;
    if (isForward || isBackward) {
      widget.onDelta(
        (isForward ? 1 : -1) *
            (HardwareKeyboard.instance.isShiftPressed ? 24 : 8),
      );
      return KeyEventResult.handled;
    }
    if (logicalKey == LogicalKeyboardKey.home && widget.onDoubleTap != null) {
      widget.onDoubleTap!.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cursor = _isVertical
        ? SystemMouseCursors.resizeColumn
        : SystemMouseCursors.resizeRow;
    return MouseRegion(
      cursor: cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _dragging = false;
      }),
      child: Semantics(
        label: widget.semanticsLabel,
        hint: 'Drag to resize. Double-click to reset.',
        child: Focus(
          canRequestFocus: true,
          onKeyEvent: _handleKeyEvent,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: widget.onDoubleTap,
            onPanStart: (_) => setState(() => _dragging = true),
            onPanEnd: (_) => setState(() => _dragging = false),
            onPanCancel: () => setState(() => _dragging = false),
            onPanUpdate: (details) => widget.onDelta(
              _isVertical ? details.delta.dx : details.delta.dy,
            ),
            child: SizedBox(
              width: _isVertical ? 9 : double.infinity,
              height: _isVertical ? double.infinity : 9,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: _isVertical
                      ? (_hovered || _dragging ? 3 : 1)
                      : double.infinity,
                  height: _isVertical
                      ? double.infinity
                      : (_hovered || _dragging ? 3 : 1),
                  color: _hovered || _dragging ? kAccent : kBorder,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
