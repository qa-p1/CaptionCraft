import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/playback_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/screens/creator_lab_screen.dart';
import 'package:caption_craft/features/editor/screens/teleprompter_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Creator Lab starts with recommendations and groups every tool', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1180, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpLab(tester);

    expect(find.text('Creator Lab'), findsOneWidget);
    expect(find.textContaining('Offline workflow tools'), findsOneWidget);
    expect(find.text('REVIEW & RECOMMENDED'), findsOneWidget);
    expect(find.text('RECOMMENDED NOW'), findsOneWidget);
    expect(find.text('Smart Line Balance'), findsOneWidget);
    expect(find.text('Reading-Speed Retimer'), findsOneWidget);
    expect(find.text('Estimated Word Timing'), findsOneWidget);

    await tester.tap(find.text('Fix'));
    await tester.pumpAndSettle();
    expect(find.text('Layout & timing'), findsOneWidget);
    expect(find.text('Text cleanup'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Names & safety'),
      260,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Names & safety'), findsOneWidget);
    expect(find.text('Edits captions'), findsWidgets);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Planning markers'), findsOneWidget);
    expect(find.text('Moment Suggestions'), findsOneWidget);
    expect(find.text('Automatic Chapter Markers'), findsOneWidget);
    expect(find.text('B-roll Prompt Markers'), findsOneWidget);
    expect(find.text('Adds markers'), findsNWidgets(3));
    expect(find.text('Viral Moment Radar'), findsNothing);
    expect(find.text('Magic Chapter Director'), findsNothing);
  });

  testWidgets('caption batch is one atomic editor undo and redo step', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await _pumpLab(tester);

    await tester.tap(find.text('Fix'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Text cleanup'),
      260,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.text('Text cleanup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text cleanup'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Filler Word Cleaner'),
      260,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Filler Word Cleaner'));
    await tester.pumpAndSettle();

    final editor = container.read(editorProvider.notifier);
    expect(
      container.read(subtitleProvider).entries.first.text,
      'this workflow is ready.',
    );
    expect(
      container.read(editorProvider).timeline.subtitleEntries.first.text,
      'this workflow is ready.',
    );
    expect(container.read(editorProvider).canUndo, isTrue);
    expect(find.textContaining('Undo available'), findsOneWidget);

    editor.undo();
    await tester.pump();
    expect(container.read(editorProvider).canUndo, isFalse);
    expect(container.read(editorProvider).canRedo, isTrue);
    expect(
      container.read(subtitleProvider).entries.first.text,
      'Um, this workflow is ready.',
    );
    expect(
      container.read(editorProvider).timeline.subtitleEntries.first.text,
      'Um, this workflow is ready.',
    );

    editor.redo();
    await tester.pump();
    expect(container.read(editorProvider).canUndo, isTrue);
    expect(container.read(editorProvider).canRedo, isFalse);
    expect(
      container.read(subtitleProvider).entries.first.text,
      'this workflow is ready.',
    );
    expect(
      container.read(editorProvider).timeline.subtitleEntries.first.text,
      'this workflow is ready.',
    );
  });

  testWidgets('caption-dependent catalog explains and disables empty state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await _pumpLab(tester, seededEntries: const []);

    expect(find.textContaining('Add or generate captions'), findsOneWidget);
    await tester.tap(find.text('Fix'));
    await tester.pumpAndSettle();

    expect(find.text('Needs captions'), findsWidgets);
    final cardInkWell = find
        .ancestor(
          of: find.text('Smart Line Balance'),
          matching: find.byType(InkWell),
        )
        .first;
    expect(tester.widget<InkWell>(cardInkWell).onTap, isNull);
    expect(container.read(subtitleProvider).entries, isEmpty);
  });

  testWidgets('result sheet is compact and a result returns to editor seek', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1180, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const _CreatorLabHost(),
        ),
      ),
    );
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('open_creator_lab'))),
    );
    _seedProviders(container, _sampleEntries());

    await tester.tap(find.byKey(const Key('open_creator_lab')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B-roll Prompt Markers'));
    await tester.pumpAndSettle();

    final sheet = find.byKey(const Key('creator_lab_result_sheet'));
    expect(sheet, findsOneWidget);
    final labScaffold = find.descendant(
      of: find.byType(CreatorLabScreen),
      matching: find.byType(Scaffold),
    );
    final availableHeight = tester.getSize(labScaffold).height;
    expect(
      tester.getSize(sheet).height,
      lessThanOrEqualTo(availableHeight * 0.42),
    );
    expect(
      tester.getSize(sheet).height,
      greaterThanOrEqualTo(availableHeight * 0.25),
    );

    final secondSuggestion = find.textContaining(
      'FROM: A cinematic camera moves',
    );
    await tester.scrollUntilVisible(
      secondSuggestion,
      180,
      scrollable: find
          .descendant(of: sheet, matching: find.byType(Scrollable))
          .last,
    );
    await tester.ensureVisible(secondSuggestion);
    await tester.pumpAndSettle();
    await tester.tap(secondSuggestion);
    await tester.pumpAndSettle();

    expect(find.byType(CreatorLabScreen), findsNothing);
    expect(find.text('Editor preview host'), findsOneWidget);
    expect(
      container.read(playbackProvider).position,
      const Duration(seconds: 10),
    );
    expect(container.read(playbackProvider).seekRequestId, greaterThan(0));
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

Future<ProviderContainer> _pumpLab(
  WidgetTester tester, {
  List<SubtitleEntry>? seededEntries,
}) async {
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
  _seedProviders(container, seededEntries ?? _sampleEntries());
  await tester.pumpAndSettle();
  return container;
}

List<SubtitleEntry> _sampleEntries() {
  return [
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
}

void _seedProviders(ProviderContainer container, List<SubtitleEntry> entries) {
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
  container
      .read(playbackProvider.notifier)
      .updateDuration(const Duration(seconds: 15));
}

class _CreatorLabHost extends StatelessWidget {
  const _CreatorLabHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('open_creator_lab'),
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  const CreatorLabScreen(projectName: 'Creator Lab Test'),
            ),
          ),
          child: const Text('Editor preview host'),
        ),
      ),
    );
  }
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
