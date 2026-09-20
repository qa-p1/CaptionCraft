import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/widgets/subtitle_style_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('track style controls stay scoped and remain undoable', (
    tester,
  ) async {
    final container = _projectContainer();
    addTearDown(container.dispose);
    await _pumpPanel(tester, container, entryIds: const {'caption'});

    final slider = find.byType(Slider).first;
    await tester.ensureVisible(slider);
    await tester.drag(slider, const Offset(120, 0));
    await tester.pumpAndSettle();

    final state = container.read(subtitleProvider);
    expect(state.globalStyle.fontSize, 10);
    expect(_entry(state, 'caption').styleOverride?.fontSize, isNot(20));
    expect(container.read(subtitleProvider.notifier).canUndo, isTrue);

    final editedFontSize = _entry(state, 'caption').styleOverride!.fontSize;
    container.read(subtitleProvider.notifier).undo();
    expect(
      _entry(
        container.read(subtitleProvider),
        'caption',
      ).styleOverride?.fontSize,
      20,
    );
    expect(container.read(subtitleProvider).globalStyle.fontSize, 10);
    container.read(subtitleProvider.notifier).redo();
    expect(
      _entry(
        container.read(subtitleProvider),
        'caption',
      ).styleOverride?.fontSize,
      editedFontSize,
    );

    final cleanWhite = find.text('Clean White');
    await tester.ensureVisible(cleanWhite);
    await tester.tap(cleanWhite);
    await tester.pumpAndSettle();

    final presetState = container.read(subtitleProvider);
    expect(presetState.globalStyle.fontFamily, 'Inter');
    expect(
      _entry(presetState, 'caption').styleOverride?.backgroundType,
      SubtitleBackground.outlineShadow,
    );
  });

  testWidgets('scoped color dialog preserves the targeted cue style', (
    tester,
  ) async {
    final container = _projectContainer();
    addTearDown(container.dispose);
    await _pumpPanel(tester, container, entryIds: const {'caption'});

    final header = find.text('Text Color');
    await tester.scrollUntilVisible(header, 200);
    final headerRect = tester.getRect(header);
    await tester.tapAt(Offset(headerRect.center.dx, headerRect.bottom + 20));
    await tester.pumpAndSettle();

    expect(find.byType(ColorPicker), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();

    final state = container.read(subtitleProvider);
    expect(_entry(state, 'caption').styleOverride?.fontSize, 20);
    expect(state.globalStyle.fontSize, 10);
  });

  testWidgets('a lane locked after opening the panel cannot change style', (
    tester,
  ) async {
    final container = _projectContainer();
    addTearDown(container.dispose);
    await _pumpPanel(tester, container, entryIds: const {'caption'});

    final originalStyle = _entry(
      container.read(subtitleProvider),
      'caption',
    ).styleOverride;
    final colorHeader = find.text('Text Color');
    await tester.scrollUntilVisible(colorHeader, 200);
    final colorHeaderRect = tester.getRect(colorHeader);
    await tester.tapAt(
      Offset(colorHeaderRect.center.dx, colorHeaderRect.bottom + 20),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ColorPicker), findsOneWidget);

    final editor = container.read(editorProvider.notifier);
    editor.setTimeline(
      editor.currentState.timeline.copyWith(
        tracks: editor.currentState.timeline.tracks
            .map((track) => track.copyWith(isLocked: true))
            .toList(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('track is locked'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(
      _entry(
        container.read(subtitleProvider),
        'caption',
      ).styleOverride?.toJson(),
      originalStyle?.toJson(),
    );

    // Reveal the preset without a gesture: the locked panel ignores scrolling.
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    final cleanWhite = find.text('Clean White');
    await tester.tap(cleanWhite, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      _entry(
        container.read(subtitleProvider),
        'caption',
      ).styleOverride?.toJson(),
      originalStyle?.toJson(),
    );

    final unlockedTracks = editor.currentState.timeline.tracks
        .map((track) => track.copyWith(isLocked: false))
        .toList();
    editor.setTimeline(
      editor.currentState.timeline.copyWith(tracks: unlockedTracks),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('track is locked'), findsNothing);

    await tester.ensureVisible(cleanWhite);
    await tester.tap(cleanWhite);
    await tester.pumpAndSettle();
    expect(
      _entry(
        container.read(subtitleProvider),
        'caption',
      ).styleOverride?.fontFamily,
      'Inter',
    );
  });

  testWidgets(
    'global style controls are disabled while any caption lane is locked',
    (tester) async {
      final container = _projectContainer();
      addTearDown(container.dispose);
      await _pumpPanel(tester, container);

      final editor = container.read(editorProvider.notifier);
      final unlockedTrack = editor.currentState.timeline.tracks.single;
      final lockedTrack = TimelineTrack(
        id: 'locked-captions',
        name: 'Locked captions',
        type: TimelineTrackType.subtitle,
        section: TimelineTrackSection.textSubtitle,
        isLocked: true,
      );
      editor.setTimeline(
        editor.currentState.timeline.copyWith(
          tracks: [unlockedTrack, lockedTrack],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        editor.currentState.timeline.tracks.any(
          (track) =>
              track.type == TimelineTrackType.subtitle && !track.isLocked,
        ),
        isTrue,
      );
      expect(find.textContaining('track is locked'), findsOneWidget);
      final cleanWhite = find.text('Clean White');
      await tester.tap(cleanWhite, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(
        container.read(subtitleProvider).globalStyle.backgroundType,
        SubtitleBackground.none,
      );
    },
  );

  test('stale subtitle IDs are no-ops', () {
    final notifier = SubtitleNotifier();
    addTearDown(notifier.dispose);
    notifier.initializeFromProject(
      entries: [
        SubtitleEntry(
          id: 'caption',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 2),
          text: 'Caption',
        ),
      ],
      globalStyle: const SubtitleStyleModel(fontSize: 10),
    );

    notifier.selectEntry('caption');
    final before = notifier.currentState.entries.single.toJson();
    notifier.updateText('missing', 'Changed');
    notifier.updateTiming(
      'missing',
      const Duration(seconds: 1),
      const Duration(seconds: 2),
    );
    notifier.deleteEntry('missing');
    notifier.duplicateEntry('missing');
    notifier.splitEntry('missing', const Duration(seconds: 1));
    notifier.setEntryStyleOverride(
      'missing',
      const SubtitleStyleModel(fontSize: 42),
    );
    notifier.setEntryStyleOverrideLive(
      'missing',
      const SubtitleStyleModel(fontSize: 42),
    );
    notifier.selectEntry('missing');

    expect(notifier.currentState.entries.single.toJson(), before);
    expect(notifier.currentState.selectedEntryId, 'caption');
    expect(notifier.currentState.globalStyle.fontSize, 10);
    expect(notifier.canUndo, isFalse);
  });

  test('split clips word timings to each resulting cue', () {
    final notifier = SubtitleNotifier();
    addTearDown(notifier.dispose);
    notifier.initializeFromProject(
      entries: [
        SubtitleEntry(
          id: 'cue',
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 5),
          text: 'lead cross tail',
          words: [
            const WordTiming(
              word: 'before',
              startTime: Duration(milliseconds: 500),
              endTime: Duration(seconds: 1),
            ),
            const WordTiming(
              word: 'lead',
              startTime: Duration(milliseconds: 1200),
              endTime: Duration(milliseconds: 1800),
            ),
            const WordTiming(
              word: 'cross',
              startTime: Duration(milliseconds: 2500),
              endTime: Duration(milliseconds: 3500),
            ),
            const WordTiming(
              word: 'tail',
              startTime: Duration(milliseconds: 4500),
              endTime: Duration(milliseconds: 5500),
            ),
          ],
        ),
      ],
      globalStyle: const SubtitleStyleModel(),
    );

    notifier.splitEntry('cue', const Duration(seconds: 3));

    final first = _entry(notifier.currentState, 'cue');
    final second = notifier.currentState.entries.firstWhere(
      (entry) => entry.id != 'cue',
    );
    expect(first.words, isNotNull);
    expect(second.words, isNotNull);
    expect(first.words!.map((word) => word.word), ['lead', 'cross']);
    expect(second.words!.map((word) => word.word), ['cross', 'tail']);
    expect(first.words!.first.startTime, const Duration(milliseconds: 1200));
    expect(first.words!.last.endTime, const Duration(seconds: 3));
    expect(second.words!.first.startTime, const Duration(seconds: 3));
    expect(second.words!.last.endTime, const Duration(seconds: 5));
    expect(
      first.words!.every(
        (word) =>
            word.startTime >= first.startTime && word.endTime <= first.endTime,
      ),
      isTrue,
    );
    expect(
      second.words!.every(
        (word) =>
            word.startTime >= second.startTime &&
            word.endTime <= second.endTime,
      ),
      isTrue,
    );
  });
}

SubtitleEntry _entry(SubtitleState state, String id) =>
    state.entries.firstWhere((entry) => entry.id == id);

ProviderContainer _projectContainer() {
  final container = ProviderContainer();
  final subtitles = container.read(subtitleProvider.notifier);
  final entry = SubtitleEntry(
    id: 'caption',
    startTime: Duration.zero,
    endTime: const Duration(seconds: 2),
    text: 'Caption',
    styleOverride: const SubtitleStyleModel(fontSize: 20),
  );
  subtitles.initializeFromProject(
    entries: [entry],
    globalStyle: const SubtitleStyleModel(fontSize: 10),
  );
  container
      .read(editorProvider.notifier)
      .loadProject(
        videoPath: 'missing.mp4',
        projectId: 'style-panel',
        projectName: 'Style panel',
        timeline: EditorTimeline(
          tracks: [
            TimelineTrack(
              id: 'captions',
              name: 'Captions',
              type: TimelineTrackType.subtitle,
              section: TimelineTrackSection.textSubtitle,
              clips: [
                TimelineClip.fromSubtitleEntry(entry, trackId: 'captions'),
              ],
            ),
          ],
        ),
      );
  return container;
}

Future<void> _pumpPanel(
  WidgetTester tester,
  ProviderContainer container, {
  Set<String>? entryIds,
}) async {
  tester.view.physicalSize = const Size(500, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(body: SubtitleStylePanel(entryIds: entryIds)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
