import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/screens/creator_lab_screen.dart';
import 'package:caption_craft/features/editor/screens/teleprompter_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Creator Lab exposes repair, wow, and review experiences', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1180, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpLab(tester);

    expect(find.text('Creator Lab'), findsOneWidget);
    expect(find.textContaining('23 creative tools'), findsOneWidget);
    expect(find.text('Smart Line Balance'), findsOneWidget);
    expect(find.text('Reading-Speed Retimer'), findsOneWidget);

    await tester.tap(find.text('Wow Lab'));
    await tester.pumpAndSettle();
    expect(find.text('Viral Moment Radar'), findsOneWidget);
    expect(find.text('Magic Chapter Director'), findsOneWidget);

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('Pace Heatmap & Confidence Desk'), findsOneWidget);
    expect(find.text('PACE HEATMAP'), findsOneWidget);
    expect(find.text('Fix track pace'), findsOneWidget);
  });

  testWidgets('repair cards apply transformations through editor providers', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await _pumpLab(tester);

    await tester.dragUntilVisible(
      find.text('Filler Word Cleaner'),
      find.byType(CustomScrollView),
      const Offset(0, -250),
    );
    await tester.tap(find.text('Filler Word Cleaner'));
    await tester.pumpAndSettle();

    final captions = container.read(subtitleProvider).entries;
    expect(captions.first.text, 'this workflow is ready.');
    expect(
      container.read(editorProvider).timeline.subtitleEntries.first.text,
      'this workflow is ready.',
    );
    expect(find.textContaining('Undo available'), findsOneWidget);
  });

  testWidgets('Teleprompter Stage remains usable on a phone', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: TeleprompterScreen(
          projectName: 'Launch film',
          entries: [
            _entry(
              id: 'one',
              text: 'Welcome to the rehearsal stage.',
              startMs: 0,
              endMs: 1800,
            ),
            _entry(
              id: 'two',
              text: 'The next line scrolls into focus.',
              startMs: 1900,
              endMs: 3800,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Teleprompter Stage'), findsOneWidget);
    expect(find.text('Rehearse'), findsOneWidget);
    await tester.tap(find.text('Rehearse'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Pause'), findsOneWidget);
    await tester.tap(find.byTooltip('Mirror for glass rig'));
    await tester.pump();
    expect(find.byTooltip('Disable mirror'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<ProviderContainer> _pumpLab(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: const CreatorLabScreen(projectName: 'Creator Lab Test'),
      ),
    ),
  );
  await tester.pump();

  final container = ProviderScope.containerOf(
    tester.element(find.byType(CreatorLabScreen)),
  );
  final entries = [
    _entry(
      id: 'one',
      text: 'Um, this workflow is ready.',
      startMs: 0,
      endMs: 1200,
    ),
    _entry(
      id: 'two',
      text: 'Why is this the biggest creator secret?',
      startMs: 1400,
      endMs: 3200,
    ),
    _entry(
      id: 'three',
      text: 'A cinematic camera moves through mountain light.',
      startMs: 10000,
      endMs: 12500,
    ),
  ];
  const style = SubtitleStyleModel();
  final timeline = const EditorTimeline().syncLegacySubtitles(
    subtitles: entries,
    globalStyle: style,
    videoPath: '/media/test.mp4',
    durationMs: 15000,
  );
  container
      .read(subtitleProvider.notifier)
      .initializeFromProject(entries: entries, globalStyle: style);
  container
      .read(editorProvider.notifier)
      .loadProject(
        videoPath: '/media/test.mp4',
        projectId: 'project',
        projectName: 'Creator Lab Test',
        timeline: timeline,
      );
  await tester.pumpAndSettle();
  return container;
}

SubtitleEntry _entry({
  required String id,
  required String text,
  required int startMs,
  required int endMs,
}) {
  return SubtitleEntry(
    id: id,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
    text: text,
  );
}
