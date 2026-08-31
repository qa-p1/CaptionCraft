import 'dart:io';

import 'package:caption_craft/app.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    final documents = await Directory.systemTemp.createTemp(
      'captioncraft-local-mode-',
    );
    ProjectLocalStorage.setDocumentsDirectoryForTesting(documents);
    addTearDown(() async {
      ProjectLocalStorage.setDocumentsDirectoryForTesting(null);
      await documents.delete(recursive: true);
    });

    await tester.pumpWidget(
      const ProviderScope(
        child: CaptionCraftApp(launchMode: CaptionCraftLaunchMode.localDesktop),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Local creator'), findsOneWidget);
    expect(find.text('WINDOWS · LOCAL ONLY'), findsOneWidget);
    expect(find.text('Your first frame starts here'), findsOneWidget);

    await tester.tap(find.byTooltip('About local desktop mode'));
    await tester.pumpAndSettle();
    expect(find.text('Local desktop mode'), findsOneWidget);
    expect(find.textContaining('Projects and autosaves stay'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
