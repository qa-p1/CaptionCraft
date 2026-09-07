import 'dart:math' as math;

import 'package:caption_craft/features/editor/widgets/preview_transform_controls.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreviewTransformGeometry', () {
    const size = Size(100, 80);

    test('classifies every edge and corner as a resize handle', () {
      final points = <PreviewTransformHandle, Offset>{
        PreviewTransformHandle.topLeft: Offset.zero,
        PreviewTransformHandle.top: const Offset(50, 0),
        PreviewTransformHandle.topRight: const Offset(100, 0),
        PreviewTransformHandle.right: const Offset(100, 40),
        PreviewTransformHandle.bottomRight: const Offset(100, 80),
        PreviewTransformHandle.bottom: const Offset(50, 80),
        PreviewTransformHandle.bottomLeft: const Offset(0, 80),
        PreviewTransformHandle.left: const Offset(0, 40),
      };

      for (final entry in points.entries) {
        expect(PreviewTransformGeometry.isResizeHandle(entry.key), isTrue);
        expect(
          PreviewTransformGeometry.handleAt(
            entry.value,
            size,
            hitSlop: 4,
            rotationHandleDistance: 30,
            includeMove: false,
          ),
          entry.key,
        );
      }
    });

    test('rotation hit area is outside the content frame', () {
      expect(
        PreviewTransformGeometry.handleAt(
          const Offset(50, -30),
          size,
          hitSlop: 6,
          rotationHandleDistance: 30,
          includeMove: false,
        ),
        PreviewTransformHandle.rotation,
      );
    });

    test('accepted resize factor and anchor use the model bounds', () {
      final accepted = PreviewTransformGeometry.acceptedResizeFactor(
        pointerFactor: 32,
        initialValue: 4,
        minValue: 0.2,
        maxValue: 4,
      );
      expect(accepted, closeTo(1, 0.000001));

      final center = PreviewTransformGeometry.centerAfterResize(
        handle: PreviewTransformHandle.right,
        size: size,
        factor: accepted,
      );
      expect(center, const Offset(50, 40));

      final expandedCenter = PreviewTransformGeometry.centerAfterResize(
        handle: PreviewTransformHandle.right,
        size: size,
        factor: 1.5,
      );
      expect(expandedCenter, const Offset(75, 40));
      expect(
        PreviewTransformGeometry.centerAfterResize(
          handle: PreviewTransformHandle.right,
          size: size,
          factor: 1.5,
          centerResize: true,
        ),
        const Offset(50, 40),
      );
    });

    test('absolute rotation snapping handles a non-snapped start angle', () {
      final delta = PreviewTransformGeometry.snappedRotationDelta(
        initialRotation: 7 * math.pi / 180,
        rotationDelta: 4 * math.pi / 180,
      );
      expect(delta, closeTo(8 * math.pi / 180, 0.000001));
    });

    test('affine frame remains invertible for rotated and flipped layers', () {
      const frame = PreviewTransformFrame(
        size: size,
        origin: Offset(300, 200),
        axisX: Offset(-0.8, 0.6),
        axisY: Offset(-0.6, -0.8),
      );
      const local = Offset(17, 31);
      final roundTrip = frame.toLocal(frame.toGlobal(local));
      expect(roundTrip.dx, closeTo(local.dx, 0.000001));
      expect(roundTrip.dy, closeTo(local.dy, 0.000001));

      final leftGlobal = frame.toGlobal(const Offset(0, 40));
      expect(
        PreviewTransformGeometry.handleAt(
          frame.toLocal(leftGlobal),
          size,
          hitSlop: 4,
          includeMove: false,
        ),
        PreviewTransformHandle.left,
      );
    });
  });

  group('PreviewTransformControls pointer behavior', () {
    testWidgets('resizes from a real edge and captures one pointer', (
      tester,
    ) async {
      final key = GlobalKey<_TransformHarnessState>();
      await _pumpHarness(tester, key, desktopMode: true, resizeBaseValue: 4);
      final rect = tester.getRect(find.byKey(_TransformHarness.layerKey));
      final start = Offset(rect.right, rect.center.dy);
      final primary = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await primary.addPointer(location: start);
      await primary.down(start);

      // A second pointer's move must not steal the captured gesture. Sending
      // the synthetic event avoids the test binding's single-mouse-pointer
      // tracker while still exercising pointer-id ownership.
      await tester.sendEventToBinding(
        PointerMoveEvent(
          pointer: 991,
          position: start + const Offset(80, 0),
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.mouse,
        ),
      );
      expect(key.currentState!.starts, 0);

      await primary.moveTo(start + const Offset(80, 0));
      await tester.pump();
      expect(key.currentState!.starts, 1);
      expect(key.currentState!.scaleFactors, isNotEmpty);
      expect(key.currentState!.scaleFactors.last, closeTo(1, 0.000001));
      expect(key.currentState!.moves, isEmpty);

      await primary.up();
      expect(key.currentState!.ends, 1);
    });

    testWidgets(
      'rotation handle outside child accepts an absolute snapped angle',
      (tester) async {
        final key = GlobalKey<_TransformHarnessState>();
        await _pumpHarness(
          tester,
          key,
          desktopMode: true,
          rotation: 7 * math.pi / 180,
        );
        final rect = tester.getRect(find.byKey(_TransformHarness.layerKey));
        final start = Offset(rect.center.dx, rect.top - 30);
        final radius = 70.0;
        final current =
            rect.center +
            Offset(
              math.cos(-75 * math.pi / 180) * radius,
              math.sin(-75 * math.pi / 180) * radius,
            );
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: start);
        await gesture.down(start);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await gesture.moveTo(current);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

        expect(key.currentState!.rotationUpdates, isNotEmpty);
        expect(
          key.currentState!.rotationUpdates.last,
          closeTo(8 * math.pi / 180, 0.02),
        );
        await gesture.up();
      },
    );

    testWidgets('Escape cancels the active gesture without completing it', (
      tester,
    ) async {
      final key = GlobalKey<_TransformHarnessState>();
      await _pumpHarness(tester, key, desktopMode: true);
      final rect = tester.getRect(find.byKey(_TransformHarness.layerKey));
      final start = rect.center;
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: start);
      await gesture.down(start);
      await gesture.moveTo(start + const Offset(15, 4));
      await tester.pump();
      expect(key.currentState!.starts, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(key.currentState!.cancels, 1);
      expect(key.currentState!.ends, 0);
      await gesture.up();
    });

    testWidgets('target removal schedules cancellation after dispose', (
      tester,
    ) async {
      final key = GlobalKey<_TransformHarnessState>();
      await _pumpHarness(tester, key, desktopMode: true);
      final rect = tester.getRect(find.byKey(_TransformHarness.layerKey));
      final start = rect.center;
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: start);
      await gesture.down(start);
      await gesture.moveTo(start + const Offset(15, 0));
      await tester.pump();
      key.currentState!.removeTarget();
      await tester.pump();
      await tester.pump();
      expect(key.currentState!.cancels, 1);
      await gesture.up();
    });

    testWidgets('touch keeps one-finger move behavior when desktop is off', (
      tester,
    ) async {
      final key = GlobalKey<_TransformHarnessState>();
      await _pumpHarness(tester, key, desktopMode: false);
      final rect = tester.getRect(find.byKey(_TransformHarness.layerKey));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
      await gesture.addPointer(location: rect.center);
      await gesture.down(rect.center);
      await gesture.moveBy(const Offset(24, 10));
      await tester.pump();
      await gesture.moveBy(const Offset(12, 4));
      await tester.pump();
      await gesture.up();

      expect(key.currentState!.starts, 1);
      expect(key.currentState!.moves, isNotEmpty);
      expect(key.currentState!.ends, 1);
    });
  });
}

Future<void> _pumpHarness(
  WidgetTester tester,
  GlobalKey<_TransformHarnessState> key, {
  required bool desktopMode,
  double rotation = 0,
  double resizeBaseValue = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: _TransformHarness(
            key: key,
            desktopMode: desktopMode,
            rotation: rotation,
            resizeBaseValue: resizeBaseValue,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _TransformHarness extends StatefulWidget {
  static const layerKey = ValueKey<String>('transform-test-layer');

  final bool desktopMode;
  final double rotation;
  final double resizeBaseValue;

  const _TransformHarness({
    super.key,
    required this.desktopMode,
    required this.rotation,
    required this.resizeBaseValue,
  });

  @override
  State<_TransformHarness> createState() => _TransformHarnessState();
}

class _TransformHarnessState extends State<_TransformHarness> {
  int starts = 0;
  int ends = 0;
  int cancels = 0;
  final moves = <Offset>[];
  final scaleFactors = <double>[];
  final rotationUpdates = <double>[];
  bool showTarget = true;

  void removeTarget() => setState(() => showTarget = false);

  @override
  Widget build(BuildContext context) {
    if (!showTarget) return const SizedBox.shrink();
    return PreviewTransformControls(
      isSelected: true,
      desktopMode: widget.desktopMode,
      rotation: widget.rotation,
      resizeBaseValue: widget.resizeBaseValue,
      onTap: () {},
      onMoveStart: () => starts++,
      onMoveUpdate: moves.add,
      onMoveEnd: () => ends++,
      onGestureCancel: () => cancels++,
      onScaleFactorUpdate: scaleFactors.add,
      onRotationUpdate: rotationUpdates.add,
      child: const SizedBox(
        key: _TransformHarness.layerKey,
        width: 100,
        height: 80,
        child: ColoredBox(color: Colors.blue),
      ),
    );
  }
}
