import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/widgets/app_surface.dart';

/// A bottom sheet whose top edge follows the user's drag and stays where it is
/// released. This intentionally does not snap to a small set of presets: the
/// editor often needs a very specific balance between canvas and controls.
class ResizableEditorSheet extends StatefulWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onClose;
  final Widget? trailing;
  final IconData? icon;
  final double initialHeightFactor;
  final double minHeightFactor;
  final double maxHeightFactor;
  final EdgeInsetsGeometry contentPadding;
  final bool scrollable;

  const ResizableEditorSheet({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onClose,
    this.trailing,
    this.icon,
    this.initialHeightFactor = 0.44,
    this.minHeightFactor = 0.24,
    this.maxHeightFactor = 0.90,
    this.contentPadding = const EdgeInsets.fromLTRB(18, 16, 18, 28),
    this.scrollable = true,
  });

  @override
  State<ResizableEditorSheet> createState() => _ResizableEditorSheetState();
}

class _ResizableEditorSheetState extends State<ResizableEditorSheet> {
  double? _height;

  void _resizeBy(double delta, double availableHeight) {
    final minimum = availableHeight * widget.minHeightFactor;
    final maximum = availableHeight * widget.maxHeightFactor;
    final current = _height ?? availableHeight * widget.initialHeightFactor;
    setState(() {
      _height = (current - delta).clamp(minimum, maximum).toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final availableHeight = math.max(
      180.0,
      mediaQuery.size.height - keyboardInset - mediaQuery.padding.top,
    );
    final minimum = availableHeight * widget.minHeightFactor;
    final maximum = availableHeight * widget.maxHeightFactor;
    final resolvedHeight =
        (_height ?? availableHeight * widget.initialHeightFactor)
            .clamp(minimum, maximum)
            .toDouble();

    final body = widget.scrollable
        ? SingleChildScrollView(
            padding: widget.contentPadding,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: widget.child,
          )
        : Padding(padding: widget.contentPadding, child: widget.child);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          key: const ValueKey('resizable_editor_sheet'),
          height: resolvedHeight,
          width: double.infinity,
          child: AppSheetSurface(
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  AppSheetHeader(
                    title: widget.title,
                    subtitle: widget.subtitle,
                    icon: widget.icon,
                    trailing: widget.trailing,
                    onClose: widget.onClose,
                    handle: Semantics(
                      label: 'Resize bottom sheet',
                      hint: 'Drag up or down to resize',
                      child: GestureDetector(
                        key: const ValueKey('resizable_sheet_handle'),
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragUpdate: (details) =>
                            _resizeBy(details.delta.dy, availableHeight),
                        child: const AppSheetHandle(height: 28),
                      ),
                    ),
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A deliberately non-resizable editor sheet for short choices and compact
/// controls. It shares the editor sheet language without displaying a handle
/// that promises a resize gesture the content does not need.
class FixedEditorSheet extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onClose;
  final Widget? trailing;
  final IconData? icon;
  final double heightFactor;
  final EdgeInsetsGeometry contentPadding;
  final bool scrollable;

  const FixedEditorSheet({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onClose,
    this.trailing,
    this.icon,
    this.heightFactor = 0.48,
    this.contentPadding = const EdgeInsets.fromLTRB(18, 16, 18, 28),
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final availableHeight = math.max(
      180.0,
      mediaQuery.size.height - keyboardInset - mediaQuery.padding.top,
    );
    final resolvedHeight = (availableHeight * heightFactor)
        .clamp(220.0, availableHeight * 0.88)
        .toDouble();
    final body = scrollable
        ? SingleChildScrollView(
            padding: contentPadding,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: child,
          )
        : Padding(padding: contentPadding, child: child);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          key: const ValueKey('fixed_editor_sheet'),
          height: resolvedHeight,
          width: double.infinity,
          child: AppSheetSurface(
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  AppSheetHeader(
                    title: title,
                    subtitle: subtitle,
                    icon: icon,
                    trailing: trailing,
                    onClose: onClose,
                    showHandle: false,
                    padding: const EdgeInsets.fromLTRB(18, 15, 10, 13),
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<T?> showResizableEditorSheet<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  required WidgetBuilder builder,
  double initialHeightFactor = 0.44,
  double minHeightFactor = 0.24,
  double maxHeightFactor = 0.90,
  Color barrierColor = const Color(0x66000000),
  IconData? icon,
  EdgeInsetsGeometry contentPadding = const EdgeInsets.fromLTRB(18, 16, 18, 28),
  bool scrollable = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    barrierColor: barrierColor,
    builder: (sheetContext) => ResizableEditorSheet(
      title: title,
      subtitle: subtitle,
      initialHeightFactor: initialHeightFactor,
      minHeightFactor: minHeightFactor,
      maxHeightFactor: maxHeightFactor,
      icon: icon,
      contentPadding: contentPadding,
      scrollable: scrollable,
      onClose: () => Navigator.of(sheetContext).pop(),
      child: builder(sheetContext),
    ),
  );
}

Future<T?> showFixedEditorSheet<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  required WidgetBuilder builder,
  double heightFactor = 0.48,
  Color barrierColor = const Color(0x66000000),
  IconData? icon,
  EdgeInsetsGeometry contentPadding = const EdgeInsets.fromLTRB(18, 16, 18, 28),
  bool scrollable = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    barrierColor: barrierColor,
    builder: (sheetContext) => FixedEditorSheet(
      title: title,
      subtitle: subtitle,
      heightFactor: heightFactor,
      icon: icon,
      contentPadding: contentPadding,
      scrollable: scrollable,
      onClose: () => Navigator.of(sheetContext).pop(),
      child: builder(sheetContext),
    ),
  );
}
