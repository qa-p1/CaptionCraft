import 'package:caption_craft/features/editor/widgets/resizable_editor_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('fixed sheet has no resize affordance', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FixedEditorSheet(
              title: 'Choose one',
              child: Text('Compact choices'),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('fixed_editor_sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('resizable_sheet_handle')), findsNothing);
  });

  testWidgets('sheet handle resizes continuously and keeps released height', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ResizableEditorSheet(
              title: 'Resizable controls',
              child: SizedBox(height: 200),
            ),
          ),
        ),
      ),
    );

    final sheet = find.byKey(const ValueKey('resizable_editor_sheet'));
    final handle = find.byKey(const ValueKey('resizable_sheet_handle'));
    expect(sheet, findsOneWidget);
    expect(handle, findsOneWidget);
    final initialHeight = tester.getSize(sheet).height;

    await tester.drag(handle, const Offset(0, -96));
    await tester.pumpAndSettle();
    final expandedHeight = tester.getSize(sheet).height;
    expect(expandedHeight, closeTo(initialHeight + 96, 2));

    await tester.drag(handle, const Offset(0, 37));
    await tester.pumpAndSettle();
    final releasedHeight = tester.getSize(sheet).height;
    expect(releasedHeight, closeTo(expandedHeight - 37, 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getSize(sheet).height, releasedHeight);
  });
}
