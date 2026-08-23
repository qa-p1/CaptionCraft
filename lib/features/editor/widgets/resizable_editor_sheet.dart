import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// A bottom sheet whose top edge follows the user's drag and stays where it is
/// released. This intentionally does not snap to a small set of presets: the
/// editor often needs a very specific balance between canvas and controls.
class ResizableEditorSheet extends StatefulWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onClose;
  final Widget? trailing;
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
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 22,
                  offset: Offset(0, -6),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  Semantics(
                    label: 'Resize bottom sheet',
                    hint: 'Drag up or down to resize',
                    child: GestureDetector(
                      key: const ValueKey('resizable_sheet_handle'),
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (details) =>
                          _resizeBy(details.delta.dy, availableHeight),
                      child: SizedBox(
                        height: 28,
                        width: double.infinity,
                        child: Center(
                          child: Container(
                            width: 44,
                            height: 5,
                            decoration: BoxDecoration(
                              color: kTextSecondary.withValues(alpha: 0.65),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 2, 10, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title,
                                style: const TextStyle(
                                  color: kTextPrimary,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              if (widget.subtitle?.trim().isNotEmpty ==
                                  true) ...[
                                const SizedBox(height: 2),
                                Text(
                                  widget.subtitle!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kTextSecondary,
                                    fontSize: 12,
                                    height: 1.25,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (widget.trailing != null) widget.trailing!,
                        if (widget.onClose != null)
                          IconButton(
                            tooltip: 'Close',
                            onPressed: widget.onClose,
                            icon: const Icon(Icons.close_rounded),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: kBorder),
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
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 22,
                  offset: Offset(0, -6),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 10, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  color: kTextPrimary,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              if (subtitle?.trim().isNotEmpty == true) ...[
                                const SizedBox(height: 2),
                                Text(
                                  subtitle!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kTextSecondary,
                                    fontSize: 12,
                                    height: 1.25,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        ?trailing,
                        if (onClose != null)
                          IconButton(
                            tooltip: 'Close',
                            onPressed: onClose,
                            icon: const Icon(Icons.close_rounded),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: kBorder),
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
      onClose: () => Navigator.of(sheetContext).pop(),
      child: builder(sheetContext),
    ),
  );
}
