import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// The parts of a preview transform box that can own a pointer gesture.
enum PreviewTransformHandle {
  none,
  move,
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
  rotation,
}

/// A transform frame captured in screen coordinates.
///
/// Preview layers are wrapped in [Transform] widgets. Their local coordinates
/// therefore change while a live edit is rebuilding. Keeping this small affine
/// frame for the duration of a pointer gesture makes pointer conversion stable
/// even when the provider publishes a new transform on every move.
@immutable
class PreviewTransformFrame {
  final Size size;
  final Offset origin;
  final Offset axisX;
  final Offset axisY;

  const PreviewTransformFrame({
    required this.size,
    required this.origin,
    required this.axisX,
    required this.axisY,
  });

  factory PreviewTransformFrame.fromRenderBox(RenderBox box) {
    final origin = box.localToGlobal(Offset.zero);
    return PreviewTransformFrame(
      size: box.size,
      origin: origin,
      axisX: box.localToGlobal(const Offset(1, 0)) - origin,
      axisY: box.localToGlobal(const Offset(0, 1)) - origin,
    );
  }

  double get determinant => axisX.dx * axisY.dy - axisX.dy * axisY.dx;

  bool get isUsable =>
      size.width > 0 && size.height > 0 && determinant.abs() > 0.000001;

  Offset toLocal(Offset global) {
    final delta = global - origin;
    final determinant = this.determinant;
    if (determinant.abs() <= 0.000001) return delta;
    return Offset(
      (delta.dx * axisY.dy - delta.dy * axisY.dx) / determinant,
      (axisX.dx * delta.dy - axisX.dy * delta.dx) / determinant,
    );
  }

  Offset toGlobal(Offset local) {
    return origin + axisX * local.dx + axisY * local.dy;
  }

  Offset vectorToGlobal(Offset localVector) {
    return axisX * localVector.dx + axisY * localVector.dy;
  }
}

/// Pure geometry used by the desktop preview handles and its tests.
class PreviewTransformGeometry {
  const PreviewTransformGeometry._();

  static const double defaultHitSlop = 10;
  static const double defaultRotationHandleDistance = 28;

  static Offset centerFor(Size size) => Offset(size.width / 2, size.height / 2);

  static bool isResizeHandle(PreviewTransformHandle handle) {
    return switch (handle) {
      PreviewTransformHandle.topLeft ||
      PreviewTransformHandle.top ||
      PreviewTransformHandle.topRight ||
      PreviewTransformHandle.right ||
      PreviewTransformHandle.bottomRight ||
      PreviewTransformHandle.bottom ||
      PreviewTransformHandle.bottomLeft ||
      PreviewTransformHandle.left => true,
      _ => false,
    };
  }

  /// Finds the closest handle in local box coordinates.
  ///
  /// [hitSlop] is expressed in the same local units as [size]. The widget
  /// scales it by the inverse screen scale so handles remain usable when a
  /// layer is zoomed or transformed.
  static PreviewTransformHandle handleAt(
    Offset point,
    Size size, {
    double hitSlop = defaultHitSlop,
    double rotationHandleDistance = defaultRotationHandleDistance,
    bool includeMove = true,
    bool includeRotation = true,
  }) {
    if (size.width <= 0 || size.height <= 0) {
      return PreviewTransformHandle.none;
    }

    final center = centerFor(size);
    final rotationCenter = Offset(center.dx, -rotationHandleDistance);
    if (includeRotation &&
        (point - rotationCenter).distance <= hitSlop * 1.35) {
      return PreviewTransformHandle.rotation;
    }

    final corners = <(PreviewTransformHandle, Offset)>[
      (PreviewTransformHandle.topLeft, Offset.zero),
      (PreviewTransformHandle.topRight, Offset(size.width, 0)),
      (PreviewTransformHandle.bottomRight, Offset(size.width, size.height)),
      (PreviewTransformHandle.bottomLeft, Offset(0, size.height)),
    ];
    var nearest = PreviewTransformHandle.none;
    var nearestDistance = double.infinity;
    for (final (handle, location) in corners) {
      final distance = (point - location).distance;
      if (distance <= hitSlop && distance < nearestDistance) {
        nearest = handle;
        nearestDistance = distance;
      }
    }
    if (nearest != PreviewTransformHandle.none) return nearest;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final nearLeft = (point.dx - rect.left).abs() <= hitSlop;
    final nearRight = (point.dx - rect.right).abs() <= hitSlop;
    final nearTop = (point.dy - rect.top).abs() <= hitSlop;
    final nearBottom = (point.dy - rect.bottom).abs() <= hitSlop;
    final insideVertical =
        point.dy >= rect.top - hitSlop && point.dy <= rect.bottom + hitSlop;
    final insideHorizontal =
        point.dx >= rect.left - hitSlop && point.dx <= rect.right + hitSlop;
    if (nearTop && insideHorizontal) return PreviewTransformHandle.top;
    if (nearRight && insideVertical) return PreviewTransformHandle.right;
    if (nearBottom && insideHorizontal) return PreviewTransformHandle.bottom;
    if (nearLeft && insideVertical) return PreviewTransformHandle.left;
    if (includeMove && rect.contains(point)) return PreviewTransformHandle.move;
    return PreviewTransformHandle.none;
  }

  /// Returns the uniform scale factor represented by a resize pointer.
  ///
  /// Corner handles use the radial projection of the pointer. Edge handles
  /// use their active dimension and still apply the same uniform factor to
  /// both axes because the project model stores one scale value.
  static double resizeFactor({
    required PreviewTransformHandle handle,
    required Size size,
    required Offset startPointer,
    required Offset pointer,
    bool centerResize = false,
  }) {
    if (!isResizeHandle(handle) || size.width <= 0 || size.height <= 0) {
      return 1;
    }
    final center = centerFor(size);
    final halfWidth = size.width / 2;
    final halfHeight = size.height / 2;
    final signs = _handleSigns(handle);
    final signX = signs.$1;
    final signY = signs.$2;
    final anchor = centerResize
        ? center
        : center - Offset(signX * halfWidth, signY * halfHeight);
    final start = startPointer - anchor;
    final current = pointer - anchor;

    double factor;
    if (signX != 0 && signY != 0) {
      final diagonal = Offset(signX * halfWidth, signY * halfHeight);
      final diagonalLength = diagonal.distance;
      if (diagonalLength <= 0) return 1;
      final direction = diagonal / diagonalLength;
      final startProjection = start.dx * direction.dx + start.dy * direction.dy;
      final currentProjection =
          current.dx * direction.dx + current.dy * direction.dy;
      factor = _ratio(currentProjection, startProjection);
    } else if (signX != 0) {
      factor = _ratio(current.dx * signX, start.dx * signX);
    } else {
      factor = _ratio(current.dy * signY, start.dy * signY);
    }
    if (!factor.isFinite) return 1;
    return factor.clamp(0.04, 32.0).toDouble();
  }

  /// Clamps a pointer-derived factor to the range the target model accepts.
  ///
  /// The pointer can travel much farther than the model's scale range. The
  /// accepted factor is therefore calculated from the value captured at
  /// gesture start, before it is used to move the opposite anchor.
  static double acceptedResizeFactor({
    required double pointerFactor,
    required double initialValue,
    double minValue = 0.2,
    double maxValue = 4.0,
  }) {
    if (!pointerFactor.isFinite ||
        !initialValue.isFinite ||
        initialValue <= 0) {
      return 1;
    }
    var lower = minValue / initialValue;
    var upper = maxValue / initialValue;
    if (!lower.isFinite || !upper.isFinite) return 1;
    if (lower > upper) {
      final swap = lower;
      lower = upper;
      upper = swap;
    }
    lower = lower.clamp(0.04, 32.0).toDouble();
    upper = upper.clamp(0.04, 32.0).toDouble();
    if (lower > upper) lower = upper;
    return pointerFactor.clamp(lower, upper).toDouble();
  }

  /// Returns the box center after [factor] scaling around the opposite anchor.
  static Offset centerAfterResize({
    required PreviewTransformHandle handle,
    required Size size,
    required double factor,
    bool centerResize = false,
  }) {
    final center = centerFor(size);
    if (centerResize || !isResizeHandle(handle)) return center;
    final halfWidth = size.width / 2;
    final halfHeight = size.height / 2;
    final signs = _handleSigns(handle);
    final anchor = center - Offset(signs.$1 * halfWidth, signs.$2 * halfHeight);
    return anchor + (center - anchor) * factor;
  }

  static double rotationDelta({
    required Offset center,
    required Offset startPointer,
    required Offset pointer,
  }) {
    final start = startPointer - center;
    final current = pointer - center;
    if (start.distance <= 0.001 || current.distance <= 0.001) return 0;
    return normalizeRadians(
      math.atan2(current.dy, current.dx) - math.atan2(start.dy, start.dx),
    );
  }

  static double snapRotation(
    double radians, {
    double increment = math.pi / 12,
  }) {
    if (!radians.isFinite || increment <= 0) return radians;
    return (radians / increment).round() * increment;
  }

  /// Returns the delta that makes the resulting absolute angle snap cleanly.
  static double snappedRotationDelta({
    required double initialRotation,
    required double rotationDelta,
    double increment = math.pi / 12,
  }) {
    if (!initialRotation.isFinite || !rotationDelta.isFinite) {
      return rotationDelta;
    }
    return snapRotation(initialRotation + rotationDelta, increment: increment) -
        initialRotation;
  }

  static double normalizeRadians(double radians) {
    if (!radians.isFinite) return 0;
    var value = radians.remainder(math.pi * 2);
    if (value > math.pi) value -= math.pi * 2;
    if (value < -math.pi) value += math.pi * 2;
    return value;
  }

  static (int, int) _handleSigns(PreviewTransformHandle handle) {
    return switch (handle) {
      PreviewTransformHandle.topLeft => (-1, -1),
      PreviewTransformHandle.top => (0, -1),
      PreviewTransformHandle.topRight => (1, -1),
      PreviewTransformHandle.right => (1, 0),
      PreviewTransformHandle.bottomRight => (1, 1),
      PreviewTransformHandle.bottom => (0, 1),
      PreviewTransformHandle.bottomLeft => (-1, 1),
      PreviewTransformHandle.left => (-1, 0),
      _ => (0, 0),
    };
  }

  static double _ratio(double numerator, double denominator) {
    if (denominator.abs() <= 0.001) return 1;
    return numerator / denominator;
  }
}

/// Desktop pointer controls layered over a preview element.
///
/// Mouse gestures use a captured [PreviewTransformFrame]. Touch and stylus
/// gestures retain the existing Flutter scale gesture behavior so mobile input
/// continues to provide one-finger move and pinch/rotate interactions.
class PreviewTransformControls extends StatefulWidget {
  final Widget child;
  final bool isSelected;
  final bool interactionEnabled;
  final bool desktopMode;
  final double rotation;
  final bool flipX;
  final bool flipY;
  final double resizeBaseValue;
  final double minResizeValue;
  final double maxResizeValue;
  final VoidCallback onTap;
  final VoidCallback onMoveStart;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final VoidCallback? onGestureCancel;
  final ValueChanged<double> onScaleFactorUpdate;
  final ValueChanged<double>? onRotationUpdate;

  const PreviewTransformControls({
    super.key,
    required this.child,
    required this.isSelected,
    this.interactionEnabled = true,
    this.desktopMode = false,
    this.rotation = 0,
    this.flipX = false,
    this.flipY = false,
    this.resizeBaseValue = 1,
    this.minResizeValue = 0.2,
    this.maxResizeValue = 4.0,
    required this.onTap,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    this.onGestureCancel,
    required this.onScaleFactorUpdate,
    this.onRotationUpdate,
  });

  @override
  State<PreviewTransformControls> createState() =>
      _PreviewTransformControlsState();
}

class _PreviewDesktopGesture {
  final int pointer;
  final PreviewTransformHandle handle;
  final PreviewTransformFrame frame;
  final Offset startGlobal;
  final Offset startLocal;
  final double initialRotation;
  final double initialResizeValue;
  final double minResizeValue;
  final double maxResizeValue;
  Offset lastGlobal;
  Offset lastCenterGlobal;
  bool started;

  _PreviewDesktopGesture({
    required this.pointer,
    required this.handle,
    required this.frame,
    required this.startGlobal,
    required this.startLocal,
    required this.initialRotation,
    required this.initialResizeValue,
    required this.minResizeValue,
    required this.maxResizeValue,
  }) : lastGlobal = startGlobal,
       lastCenterGlobal = frame.toGlobal(
         PreviewTransformGeometry.centerFor(frame.size),
       ),
       started = false;
}

class _PreviewTransformControlsState extends State<PreviewTransformControls>
    with WidgetsBindingObserver {
  static const _mouseSlop = 3.0;
  static const _screenHandleSize = 9.0;
  static const _screenHitSlop = 12.0;
  static const _screenRotationDistance = 30.0;

  final FocusNode _focusNode = FocusNode(debugLabel: 'preview-transform');
  final GlobalKey _contentKey = GlobalKey(
    debugLabel: 'preview-transform-content',
  );
  PreviewTransformHandle _hoveredHandle = PreviewTransformHandle.none;
  PreviewTransformFrame? _layoutFrame;
  _PreviewDesktopGesture? _desktopGesture;
  bool _touchDragging = false;
  double _screenScale = 1;

  bool get _desktopInteraction =>
      widget.desktopMode && widget.interactionEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(_handleFocusChange);
    _scheduleFrameMeasure();
  }

  @override
  void didUpdateWidget(covariant PreviewTransformControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleFrameMeasure();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cancelInteraction();
    }
  }

  void _scheduleFrameMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.desktopMode) return;
      final renderObject = _contentKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) return;
      final frame = PreviewTransformFrame.fromRenderBox(renderObject);
      final xScale = frame.axisX.distance;
      final yScale = frame.axisY.distance;
      final nextScale = ((xScale + yScale) / 2).clamp(0.01, 1000.0).toDouble();
      if ((nextScale - _screenScale).abs() > 0.01 || _layoutFrame == null) {
        if (!mounted) return;
        setState(() {
          _layoutFrame = frame;
          _screenScale = nextScale;
        });
      }
    });
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) _cancelInteraction();
  }

  bool _isPrimaryMouse(PointerEvent event) {
    return event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryButton) != 0;
  }

  bool _isMouse(PointerEvent event) => event.kind == PointerDeviceKind.mouse;

  PreviewTransformFrame? _captureFrame() {
    final renderObject = _contentKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return _layoutFrame;
    }
    final frame = PreviewTransformFrame.fromRenderBox(renderObject);
    if (!frame.isUsable) return _layoutFrame ?? frame;
    return frame;
  }

  double get _localHitSlop =>
      (_screenHitSlop / _screenScale).clamp(4.0, 80.0).toDouble();

  double get _localRotationDistance =>
      (_screenRotationDistance / _screenScale).clamp(12.0, 160.0).toDouble();

  double get _localHandleRadius =>
      (_screenHandleSize / _screenScale).clamp(3.0, 80.0).toDouble();

  void _handleHover(PointerHoverEvent event) {
    if (!_desktopInteraction) {
      if (_hoveredHandle != PreviewTransformHandle.none) {
        setState(() => _hoveredHandle = PreviewTransformHandle.none);
      }
      return;
    }
    final frame = _captureFrame();
    if (frame == null) return;
    final handle = PreviewTransformGeometry.handleAt(
      frame.toLocal(event.position),
      frame.size,
      hitSlop: _localHitSlop,
      rotationHandleDistance: _localRotationDistance,
      includeRotation: widget.onRotationUpdate != null,
    );
    if (handle != _hoveredHandle) {
      setState(() => _hoveredHandle = handle);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_desktopInteraction || !_isMouse(event) || !_isPrimaryMouse(event)) {
      return;
    }
    if (_desktopGesture != null) return;
    final frame = _captureFrame();
    if (frame == null || !frame.isUsable) return;
    final startLocal = frame.toLocal(event.position);
    final handle = PreviewTransformGeometry.handleAt(
      startLocal,
      frame.size,
      hitSlop: _localHitSlop,
      rotationHandleDistance: _localRotationDistance,
      includeRotation: widget.onRotationUpdate != null,
    );
    if (handle == PreviewTransformHandle.none) return;
    _focusNode.requestFocus();
    widget.onTap();
    _desktopGesture = _PreviewDesktopGesture(
      pointer: event.pointer,
      handle: handle,
      frame: frame,
      startGlobal: event.position,
      startLocal: startLocal,
      initialRotation: widget.rotation,
      initialResizeValue: widget.resizeBaseValue,
      minResizeValue: widget.minResizeValue,
      maxResizeValue: widget.maxResizeValue,
    );
    setState(() => _hoveredHandle = handle);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final gesture = _desktopGesture;
    if (gesture == null ||
        !_isMouse(event) ||
        event.pointer != gesture.pointer) {
      return;
    }
    final displacement = event.position - gesture.startGlobal;
    if (!gesture.started) {
      if (displacement.distance < _mouseSlop) return;
      gesture.started = true;
      widget.onMoveStart();
    }

    final local = gesture.frame.toLocal(event.position);
    final center = PreviewTransformGeometry.centerFor(gesture.frame.size);
    switch (gesture.handle) {
      case PreviewTransformHandle.move:
        final delta = event.position - gesture.lastGlobal;
        if (delta.distance > 0) widget.onMoveUpdate(delta);
        break;
      case PreviewTransformHandle.rotation:
        var rotation = PreviewTransformGeometry.rotationDelta(
          center: center,
          startPointer: gesture.startLocal,
          pointer: local,
        );
        if (_isShiftPressed) {
          rotation = PreviewTransformGeometry.snappedRotationDelta(
            initialRotation: gesture.initialRotation,
            rotationDelta: rotation,
          );
        }
        widget.onRotationUpdate?.call(rotation);
        break;
      default:
        if (PreviewTransformGeometry.isResizeHandle(gesture.handle)) {
          final pointerFactor = PreviewTransformGeometry.resizeFactor(
            handle: gesture.handle,
            size: gesture.frame.size,
            startPointer: gesture.startLocal,
            pointer: local,
            centerResize: _isAltPressed,
          );
          final factor = PreviewTransformGeometry.acceptedResizeFactor(
            pointerFactor: pointerFactor,
            initialValue: gesture.initialResizeValue,
            minValue: gesture.minResizeValue,
            maxValue: gesture.maxResizeValue,
          );
          final nextCenter = PreviewTransformGeometry.centerAfterResize(
            handle: gesture.handle,
            size: gesture.frame.size,
            factor: factor,
            centerResize: _isAltPressed,
          );
          final nextCenterGlobal = gesture.frame.toGlobal(nextCenter);
          final centerDelta = nextCenterGlobal - gesture.lastCenterGlobal;
          widget.onScaleFactorUpdate(factor);
          if (centerDelta.distance > 0.0001) {
            widget.onMoveUpdate(centerDelta);
          }
          gesture.lastCenterGlobal = nextCenterGlobal;
        }
        break;
    }
    gesture.lastGlobal = event.position;
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (!_isMouse(event)) return;
    final gesture = _desktopGesture;
    if (gesture == null || event.pointer != gesture.pointer) return;
    _desktopGesture = null;
    if (gesture.started) widget.onMoveEnd();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (!_isMouse(event) || _desktopGesture?.pointer != event.pointer) {
      return;
    }
    _cancelDesktopGesture();
  }

  void _handleExpandedPointerEvent(PointerEvent event) {
    if (!_desktopInteraction) return;
    switch (event) {
      case PointerHoverEvent():
        _handleHover(event);
      case PointerDownEvent():
        _handlePointerDown(event);
      case PointerMoveEvent():
        _handlePointerMove(event);
      case PointerUpEvent():
        _handlePointerUp(event);
      case PointerCancelEvent():
        _handlePointerCancel(event);
      default:
        break;
    }
  }

  void _cancelDesktopGesture({bool notify = true}) {
    final gesture = _desktopGesture;
    if (gesture == null) return;
    _desktopGesture = null;
    if (notify && gesture.started) widget.onGestureCancel?.call();
  }

  void _cancelTouchGesture({bool notify = true}) {
    if (!_touchDragging) return;
    _touchDragging = false;
    if (notify) widget.onGestureCancel?.call();
  }

  void _cancelInteraction({bool notify = true}) {
    _cancelDesktopGesture(notify: notify);
    _cancelTouchGesture(notify: notify);
  }

  bool get _isAltPressed =>
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.altLeft,
      ) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.altRight,
      );

  bool get _isShiftPressed =>
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.shiftLeft,
      ) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(
        LogicalKeyboardKey.shiftRight,
      );

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        (_desktopGesture != null || _touchDragging)) {
      _cancelInteraction();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  MouseCursor _cursorForHandle(PreviewTransformHandle handle) {
    switch (handle) {
      case PreviewTransformHandle.move:
        return SystemMouseCursors.move;
      case PreviewTransformHandle.rotation:
        return SystemMouseCursors.grab;
      case PreviewTransformHandle.top:
      case PreviewTransformHandle.bottom:
        return _edgeCursor(
          math.pi / 2 +
              widget.rotation +
              (widget.flipX != widget.flipY ? math.pi : 0),
        );
      case PreviewTransformHandle.left:
      case PreviewTransformHandle.right:
        return _edgeCursor(widget.rotation + (widget.flipX ? math.pi : 0));
      case PreviewTransformHandle.topLeft:
      case PreviewTransformHandle.topRight:
      case PreviewTransformHandle.bottomRight:
      case PreviewTransformHandle.bottomLeft:
        var signs = switch (handle) {
          PreviewTransformHandle.topLeft => (-1.0, -1.0),
          PreviewTransformHandle.topRight => (1.0, -1.0),
          PreviewTransformHandle.bottomRight => (1.0, 1.0),
          _ => (-1.0, 1.0),
        };
        if (widget.flipX) signs = (-signs.$1, signs.$2);
        if (widget.flipY) signs = (signs.$1, -signs.$2);
        return _diagonalCursor(
          math.atan2(signs.$2, signs.$1) + widget.rotation,
        );
      case PreviewTransformHandle.none:
        return SystemMouseCursors.basic;
    }
  }

  MouseCursor _edgeCursor(double angle) {
    final normalized = PreviewTransformGeometry.normalizeRadians(angle);
    final horizontal =
        normalized.abs() < math.pi / 4 || normalized.abs() > math.pi * 3 / 4;
    return horizontal
        ? SystemMouseCursors.resizeLeftRight
        : SystemMouseCursors.resizeUpDown;
  }

  MouseCursor _diagonalCursor(double angle) {
    final normalized = PreviewTransformGeometry.normalizeRadians(angle);
    final x = math.cos(normalized);
    final y = math.sin(normalized);
    if (x >= 0 && y >= 0) return SystemMouseCursors.resizeDownRight;
    if (x < 0 && y < 0) return SystemMouseCursors.resizeUpLeft;
    if (x >= 0 && y < 0) return SystemMouseCursors.resizeUpRight;
    return SystemMouseCursors.resizeDownLeft;
  }

  @override
  Widget build(BuildContext context) {
    _scheduleFrameMeasure();
    final outlineVisible =
        widget.desktopMode &&
        (widget.isSelected || _hoveredHandle != PreviewTransformHandle.none);
    final controls = Stack(
      key: _contentKey,
      clipBehavior: Clip.none,
      children: [
        widget.child,
        if (widget.desktopMode)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _PreviewTransformPainter(
                  outlineVisible: outlineVisible,
                  selected: widget.isSelected,
                  showHandles: widget.isSelected,
                  showRotationHandle: widget.onRotationUpdate != null,
                  hoveredHandle: _hoveredHandle,
                  handleRadius: _localHandleRadius,
                  rotationHandleDistance: _localRotationDistance,
                  strokeWidth: (1.5 / _screenScale).clamp(0.5, 8.0).toDouble(),
                ),
              ),
            ),
          ),
      ],
    );

    // Symmetric padding expands the hit-test surface for the rotation
    // affordance while keeping the content center (and therefore the outer
    // Transform pivot) exactly where it was. The content frame is captured
    // from [_contentKey], so this margin never enters model geometry.
    final desktopMargin = widget.desktopMode
        ? (_localRotationDistance + _localHitSlop)
        : 0.0;
    final touchControls = GestureDetector(
      behavior: HitTestBehavior.opaque,
      supportedDevices: const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
      },
      onTap: widget.onTap,
      onScaleStart: (_) {
        _touchDragging = true;
        widget.onMoveStart();
      },
      onScaleUpdate: (details) {
        if (!_touchDragging) return;
        widget.onMoveUpdate(details.focalPointDelta);
        widget.onScaleFactorUpdate(details.scale);
        widget.onRotationUpdate?.call(details.rotation);
      },
      onScaleEnd: (_) {
        if (!_touchDragging) return;
        _touchDragging = false;
        widget.onMoveEnd();
      },
      child: controls,
    );

    final gated = IgnorePointer(
      ignoring:
          !widget.interactionEnabled &&
          !_touchDragging &&
          _desktopGesture == null,
      child: touchControls,
    );
    if (!widget.desktopMode) return gated;
    final desktopContent = MouseRegion(
      opaque: false,
      cursor: _desktopInteraction
          ? _cursorForHandle(_hoveredHandle)
          : SystemMouseCursors.basic,
      onExit: (_) {
        if (_hoveredHandle != PreviewTransformHandle.none &&
            _desktopGesture == null) {
          setState(() => _hoveredHandle = PreviewTransformHandle.none);
        }
      },
      child: gated,
    );
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: _PreviewInteractionSurface(
        hitPadding: EdgeInsets.all(desktopMargin),
        onPointerEvent: _handleExpandedPointerEvent,
        child: desktopContent,
      ),
    );
  }

  @override
  void dispose() {
    final gestureWasActive = _desktopGesture?.started == true || _touchDragging;
    final cancel = gestureWasActive ? widget.onGestureCancel : null;
    _desktopGesture = null;
    _touchDragging = false;
    if (cancel != null) {
      // A target can disappear while the provider is publishing the live
      // transform. Defer the restore until the removal has completed so the
      // callback cannot mutate the tree during this State's dispose.
      scheduleMicrotask(cancel);
    }
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Gives the handles space around the unchanged child layout and keeps the
/// child's painting, coordinate conversion and hit testing at the same offset.
class _PreviewInteractionSurface extends SingleChildRenderObjectWidget {
  final EdgeInsets hitPadding;
  final ValueChanged<PointerEvent> onPointerEvent;

  const _PreviewInteractionSurface({
    required this.hitPadding,
    required this.onPointerEvent,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderPreviewInteractionSurface(
      hitPadding: hitPadding,
      onPointerEvent: onPointerEvent,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPreviewInteractionSurface renderObject,
  ) {
    renderObject
      ..hitPadding = hitPadding
      ..onPointerEvent = onPointerEvent;
  }
}

class _RenderPreviewInteractionSurface extends RenderProxyBox {
  EdgeInsets _hitPadding;
  EdgeInsets get hitPadding => _hitPadding;
  set hitPadding(EdgeInsets value) {
    if (_hitPadding == value) return;
    _hitPadding = value;
    markNeedsLayout();
  }

  ValueChanged<PointerEvent> onPointerEvent;

  _RenderPreviewInteractionSurface({
    required EdgeInsets hitPadding,
    required this.onPointerEvent,
    RenderBox? child,
  }) : _hitPadding = hitPadding,
       super(child);

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) {
      child.parentData = BoxParentData();
    }
  }

  @override
  void performLayout() {
    final renderChild = child;
    if (renderChild == null) {
      size = constraints.constrain(Size.zero);
      return;
    }
    // Layout the preview exactly as it would have been laid out without the
    // interaction proxy. The proxy then grows around that layout, so the
    // rotation affordance has a real hit-testable area without changing the
    // media/text frame or its transform pivot.
    renderChild.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(
      Size(
        renderChild.size.width + hitPadding.horizontal,
        renderChild.size.height + hitPadding.vertical,
      ),
    );
    final parentData = renderChild.parentData! as BoxParentData;
    parentData.offset = Offset(
      (size.width - renderChild.size.width) / 2,
      (size.height - renderChild.size.height) / 2,
    );
  }

  Rect get _expandedBounds => Rect.fromLTRB(
    -hitPadding.left,
    -hitPadding.top,
    size.width + hitPadding.right,
    size.height + hitPadding.bottom,
  );

  @override
  void paint(PaintingContext context, Offset offset) {
    final renderChild = child;
    if (renderChild == null) return;
    final parentData = renderChild.parentData! as BoxParentData;
    context.paintChild(renderChild, offset + parentData.offset);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final parentData = child.parentData! as BoxParentData;
    transform.translateByDouble(
      parentData.offset.dx,
      parentData.offset.dy,
      0,
      1,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!_expandedBounds.contains(position)) return false;
    final renderChild = child;
    if (renderChild != null) {
      final parentData = renderChild.parentData! as BoxParentData;
      final childPosition = position - parentData.offset;
      if (childPosition.dx >= 0 &&
          childPosition.dy >= 0 &&
          childPosition.dx < renderChild.size.width &&
          childPosition.dy < renderChild.size.height) {
        result.addWithPaintOffset(
          offset: parentData.offset,
          position: position,
          hitTest: (result, position) =>
              renderChild.hitTest(result, position: position),
        );
      }
    }
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    onPointerEvent(event);
  }
}

class _PreviewTransformPainter extends CustomPainter {
  final bool outlineVisible;
  final bool selected;
  final bool showHandles;
  final bool showRotationHandle;
  final PreviewTransformHandle hoveredHandle;
  final double handleRadius;
  final double rotationHandleDistance;
  final double strokeWidth;

  const _PreviewTransformPainter({
    required this.outlineVisible,
    required this.selected,
    required this.showHandles,
    required this.showRotationHandle,
    required this.hoveredHandle,
    required this.handleRadius,
    required this.rotationHandleDistance,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!outlineVisible || size.width <= 0 || size.height <= 0) return;
    final outlinePaint = Paint()
      ..color = selected
          ? const Color(0xff63d8ff).withValues(alpha: 0.95)
          : const Color(0xff63d8ff).withValues(alpha: 0.72)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawRect(Offset.zero & size, outlinePaint);
    if (!showHandles) return;

    final handlePaint = Paint()
      ..color = const Color(0xfff5fbff)
      ..style = PaintingStyle.fill;
    final activePaint = Paint()
      ..color = const Color(0xff63d8ff)
      ..style = PaintingStyle.fill;
    final center = PreviewTransformGeometry.centerFor(size);
    final points = <PreviewTransformHandle, Offset>{
      PreviewTransformHandle.topLeft: Offset.zero,
      PreviewTransformHandle.top: Offset(center.dx, 0),
      PreviewTransformHandle.topRight: Offset(size.width, 0),
      PreviewTransformHandle.right: Offset(size.width, center.dy),
      PreviewTransformHandle.bottomRight: Offset(size.width, size.height),
      PreviewTransformHandle.bottom: Offset(center.dx, size.height),
      PreviewTransformHandle.bottomLeft: Offset(0, size.height),
      PreviewTransformHandle.left: Offset(0, center.dy),
    };
    for (final entry in points.entries) {
      canvas.drawCircle(
        entry.value,
        handleRadius,
        entry.key == hoveredHandle ? activePaint : handlePaint,
      );
      canvas.drawCircle(
        entry.value,
        handleRadius,
        Paint()
          ..color = const Color(0xff16202a)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (strokeWidth * 0.8).clamp(0.5, 4.0).toDouble(),
      );
    }
    if (!showRotationHandle) return;
    final rotationCenter = Offset(center.dx, -rotationHandleDistance);
    final linePaint = Paint()
      ..color = const Color(0xff63d8ff).withValues(alpha: 0.8)
      ..strokeWidth = strokeWidth;
    canvas.drawLine(Offset(center.dx, 0), rotationCenter, linePaint);
    canvas.drawCircle(
      rotationCenter,
      handleRadius,
      hoveredHandle == PreviewTransformHandle.rotation
          ? activePaint
          : handlePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _PreviewTransformPainter oldDelegate) {
    return outlineVisible != oldDelegate.outlineVisible ||
        selected != oldDelegate.selected ||
        showHandles != oldDelegate.showHandles ||
        showRotationHandle != oldDelegate.showRotationHandle ||
        hoveredHandle != oldDelegate.hoveredHandle ||
        handleRadius != oldDelegate.handleRadius ||
        rotationHandleDistance != oldDelegate.rotationHandleDistance ||
        strokeWidth != oldDelegate.strokeWidth;
  }
}
