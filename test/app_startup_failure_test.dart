import 'dart:io';

import 'package:caption_craft/app.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory documentsDirectory;

  setUp(() async {
    await ProjectLocalStorage.waitForPendingSavesForTesting();
    documentsDirectory = await Directory.systemTemp.createTemp(
      'captioncraft_windows_startup_',
    );
    ProjectLocalStorage.setDocumentsDirectoryForTesting(documentsDirectory);
  });

  tearDown(() async {
    await ProjectLocalStorage.waitForPendingSavesForTesting();
    ProjectLocalStorage.setDocumentsDirectoryForTesting(null);
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  testWidgets('Firebase startup failures render a recoverable app screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: CaptionCraftApp(
          launchMode: CaptionCraftLaunchMode.startupFailure,
        ),
      ),
    );

    expect(find.text('CaptionCraft could not start securely'), findsOneWidget);
    expect(find.textContaining('Close and reopen the app'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows local mode opens an honest, usable project library', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1024, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const ProviderScope(
        child: CaptionCraftApp(launchMode: CaptionCraftLaunchMode.localDesktop),
      ),
    );
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('Your first frame starts here').evaluate().isNotEmpty) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }

    expect(find.text('Local creator'), findsOneWidget);
    expect(find.text('WINDOWS · LOCAL ONLY'), findsOneWidget);

    await tester.tap(find.byTooltip('About local desktop mode'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Local desktop mode'), findsOneWidget);
    expect(find.textContaining('Projects and autosaves stay'), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Your first frame starts here'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
