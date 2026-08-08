import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/home/screens/home_screen.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Resume latest is disabled when search has no visible project', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1180, 820);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final project = Project(
      id: 'visible-project',
      ownerUid: 'account-a',
      name: 'Visible cut',
      videoPath: '/visible.mp4',
      durationMs: 1000,
    )..cacheVideoAvailability(true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [currentUserProvider.overrideWithValue(null)],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: HomeScreen(initialProjects: [project]),
        ),
      ),
    );
    await tester.pump();

    OutlinedButton resumeButton() => tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Resume latest'),
        matching: find.byType(OutlinedButton),
      ),
    );

    expect(resumeButton().onPressed, isNotNull);
    await tester.enterText(
      find.widgetWithText(TextField, 'Search projects'),
      'does not exist',
    );
    await tester.pump();
    expect(resumeButton().onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
