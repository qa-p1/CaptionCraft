import 'dart:io';

import 'package:caption_craft/core/utils/groq_service.dart';
import 'package:caption_craft/core/utils/subtitle_export_service.dart';
import 'package:caption_craft/core/utils/subtitle_quality_service.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/widgets/animated_subtitle_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('subtitle editing workflow', () {
    test('normalizes, replaces, fixes overlaps, converts case, and undoes', () {
      final notifier = SubtitleNotifier();
      notifier.initializeFromProject(
        entries: [
          SubtitleEntry(
            id: 'second',
            startTime: const Duration(milliseconds: 1800),
            endTime: const Duration(milliseconds: 3500),
            text: '  second   LINE ',
          ),
          SubtitleEntry(
            id: 'first',
            startTime: Duration.zero,
            endTime: const Duration(milliseconds: 2000),
            text: ' hello    world ',
          ),
        ],
        globalStyle: const SubtitleState().globalStyle,
      );

      notifier.normalizeText();
      expect(notifier.state.entries.first.id, 'second');
      // initializeFromProject intentionally preserves input order; timing edits
      // and batch operations sort only when timing changes.
      expect(notifier.state.entries.first.text, 'second LINE');
      expect(
        notifier.replaceText(
          query: 'line',
          replacement: 'caption',
          matchCase: false,
        ),
        1,
      );
      notifier.convertCase(SubtitleTextCase.title);
      notifier.fixOverlaps(minimumGap: const Duration(milliseconds: 100));

      final first = notifier.state.entries.firstWhere(
        (entry) => entry.id == 'first',
      );
      final second = notifier.state.entries.firstWhere(
        (entry) => entry.id == 'second',
      );
      expect(second.text, 'Second Caption');
      expect(first.text, 'Hello World');
      expect(first.endTime, const Duration(milliseconds: 1700));
      expect(notifier.canUndo, isTrue);

      notifier.undo();
      expect(
        notifier.state.entries
            .firstWhere((entry) => entry.id == 'first')
            .endTime,
        const Duration(milliseconds: 2000),
      );
      notifier.redo();
      expect(
        notifier.state.entries
            .firstWhere((entry) => entry.id == 'first')
            .endTime,
        const Duration(milliseconds: 1700),
      );
    });

    test('splits text near the playhead and remaps word timing on resize', () {
      final notifier = SubtitleNotifier();
      final entry = SubtitleEntry(
        id: 'cue',
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 5),
        text: 'one two three four',
        confidenceScore: 0.82,
        words: [
          WordTiming(
            word: 'one',
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 2),
          ),
          WordTiming(
            word: 'two',
            startTime: const Duration(seconds: 2),
            endTime: const Duration(seconds: 3),
          ),
          WordTiming(
            word: 'three',
            startTime: const Duration(seconds: 3),
            endTime: const Duration(seconds: 4),
          ),
          WordTiming(
            word: 'four',
            startTime: const Duration(seconds: 4),
            endTime: const Duration(seconds: 5),
          ),
        ],
      );
      notifier.initializeFromProject(
        entries: [entry],
        globalStyle: const SubtitleState().globalStyle,
      );
      notifier.splitEntry('cue', const Duration(seconds: 3));

      expect(notifier.state.entries, hasLength(2));
      expect(notifier.state.entries.first.text, 'one two');
      expect(notifier.state.entries.last.text, 'three four');
      expect(notifier.state.entries.last.confidenceScore, 0.82);

      final firstHalf = notifier.state.entries.first;
      notifier.syncFromTimeline([
        firstHalf.copyWith(
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 6),
        ),
        notifier.state.entries.last,
      ]);
      final remapped = notifier.state.entries.first.words!;
      expect(remapped.first.startTime, const Duration(seconds: 2));
      expect(remapped.last.endTime, const Duration(seconds: 6));
    });

    test('editor-wide undo restores timeline and subtitle state together', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final subtitleNotifier = container.read(subtitleProvider.notifier);
      subtitleNotifier.initializeFromProject(
        entries: [
          SubtitleEntry(
            id: 'caption',
            startTime: Duration.zero,
            endTime: const Duration(seconds: 2),
            text: 'Before',
          ),
        ],
        globalStyle: const SubtitleState().globalStyle,
      );

      final originalTrack = TimelineTrack(
        id: 'track',
        name: 'Video 1',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [
          TimelineClip(
            id: 'clip',
            trackId: 'track',
            type: TimelineTrackType.video,
            label: 'Clip',
            startTime: Duration.zero,
            endTime: const Duration(seconds: 3),
          ),
        ],
      );
      final editor = container.read(editorProvider.notifier);
      editor.loadProject(
        videoPath: '/video.mp4',
        projectId: 'project',
        projectName: 'Project',
        timeline: EditorTimeline(tracks: [originalTrack]),
      );

      subtitleNotifier.updateText('caption', 'After');
      editor.setTimeline(
        EditorTimeline(tracks: [originalTrack.copyWith(name: 'Renamed video')]),
      );
      expect(container.read(editorProvider).canUndo, isTrue);
      expect(container.read(subtitleProvider).entries.single.text, 'After');

      editor.undo();
      expect(
        container
            .read(editorProvider)
            .timeline
            .tracks
            .firstWhere((track) => track.id == 'track')
            .name,
        'Video 1',
      );
      // The timeline edit snapshot captures the subtitle state that existed
      // when the edit began, so subtitle-only edits remain intact.
      expect(container.read(subtitleProvider).entries.single.text, 'After');

      editor.redo();
      expect(
        container
            .read(editorProvider)
            .timeline
            .tracks
            .firstWhere((track) => track.id == 'track')
            .name,
        'Renamed video',
      );
    });
  });

  group('subtitle quality and interchange', () {
    test('chunk overlap removes duplicate words without losing dialogue', () {
      final words = GroqService.deduplicateWordOverlaps([
        const WordTiming(
          word: 'cut',
          startTime: Duration(milliseconds: 1000),
          endTime: Duration(milliseconds: 1400),
        ),
        const WordTiming(
          word: 'cut,',
          startTime: Duration(milliseconds: 1020),
          endTime: Duration(milliseconds: 1410),
        ),
        const WordTiming(
          word: 'quickly',
          startTime: Duration(milliseconds: 1320),
          endTime: Duration(milliseconds: 1740),
        ),
        const WordTiming(
          word: 'go',
          startTime: Duration(milliseconds: 2100),
          endTime: Duration(milliseconds: 2320),
        ),
        const WordTiming(
          word: 'go',
          startTime: Duration(milliseconds: 2360),
          endTime: Duration(milliseconds: 2580),
        ),
      ]);

      expect(words.map((word) => word.word), ['cut', 'quickly', 'go', 'go']);
    });

    test('quality report catches readability and timing problems', () {
      final report = SubtitleQualityService.analyze([
        SubtitleEntry(
          id: 'fast',
          startTime: Duration.zero,
          endTime: const Duration(milliseconds: 500),
          text: 'This subtitle is much too fast to read comfortably',
          confidenceScore: 0.3,
        ),
        SubtitleEntry(
          id: 'overlap',
          startTime: const Duration(milliseconds: 400),
          endTime: const Duration(seconds: 9),
          text: 'line one\nline two\nline three',
        ),
        SubtitleEntry(
          id: 'empty',
          startTime: const Duration(seconds: 10),
          endTime: const Duration(seconds: 12),
          text: '   ',
        ),
      ]);

      expect(report.cueCount, 3);
      expect(report.countFor(SubtitleIssueType.tooFast), 1);
      expect(report.countFor(SubtitleIssueType.tooShort), 1);
      expect(report.countFor(SubtitleIssueType.lowConfidence), 1);
      expect(report.countFor(SubtitleIssueType.overlap), 1);
      expect(report.countFor(SubtitleIssueType.tooLong), 1);
      expect(report.countFor(SubtitleIssueType.tooManyLines), 1);
      expect(report.countFor(SubtitleIssueType.empty), 1);
      expect(report.isClean, isFalse);
    });

    test('ASS delivery preserves caption motion and full-bar styling', () {
      final entries = [
        SubtitleEntry(
          id: 'fade',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 2),
          text: 'Fade cue',
          styleOverride: const SubtitleStyleModel(
            animationPreset: SubtitleAnimationPreset.lineFade,
          ),
        ),
        SubtitleEntry(
          id: 'pop',
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 4),
          text: 'Pop cue',
          styleOverride: const SubtitleStyleModel(
            animationPreset: SubtitleAnimationPreset.wordPop,
          ),
        ),
        SubtitleEntry(
          id: 'slide',
          startTime: const Duration(seconds: 4),
          endTime: const Duration(seconds: 6),
          text: 'Slide cue',
          styleOverride: const SubtitleStyleModel(
            animationPreset: SubtitleAnimationPreset.wordSlideUp,
          ),
        ),
        SubtitleEntry(
          id: 'type',
          startTime: const Duration(seconds: 6),
          endTime: const Duration(seconds: 8),
          text: 'Type cue',
          styleOverride: const SubtitleStyleModel(
            animationPreset: SubtitleAnimationPreset.typewriter,
          ),
        ),
        SubtitleEntry(
          id: 'bar',
          startTime: const Duration(seconds: 8),
          endTime: const Duration(seconds: 10),
          text: 'Karaoke cue',
          words: const [
            WordTiming(
              word: 'Karaoke',
              startTime: Duration(seconds: 8),
              endTime: Duration(milliseconds: 8700),
            ),
            WordTiming(
              word: 'cue',
              startTime: Duration(seconds: 9),
              endTime: Duration(milliseconds: 9600),
            ),
          ],
          styleOverride: const SubtitleStyleModel(
            backgroundType: SubtitleBackground.fullBar,
            animationPreset: SubtitleAnimationPreset.karaokeHighlight,
          ),
        ),
      ];

      final document = SubtitleExportService.buildAssDocument(
        entries,
        const SubtitleStyleModel(),
        playResX: 1920,
        playResY: 1080,
      );

      expect(document, contains(r'\fad(200,0)'));
      expect(document, contains(r'\fscx60\fscy60'));
      expect(document, contains(r'\move('));
      expect(document, contains(r'\fad(180,0)'));
      expect(document, contains(r'{\k'));
      expect(document, contains(r'\p1'));
      expect(document, contains('&H004875FF'));
    });

    test(
      'ASS anchors horizontal alignment inside the centered preview width box',
      () {
        const cases =
            <
              ({
                TextAlign textAlignment,
                SubtitlePosition position,
                int assAlignment,
                int x,
                int y,
              })
            >[
              (
                textAlignment: TextAlign.left,
                position: SubtitlePosition.top,
                assAlignment: 7,
                x: 273,
                y: 90,
              ),
              (
                textAlignment: TextAlign.start,
                position: SubtitlePosition.center,
                assAlignment: 4,
                x: 273,
                y: 378,
              ),
              (
                textAlignment: TextAlign.center,
                position: SubtitlePosition.bottom,
                assAlignment: 2,
                x: 468,
                y: 666,
              ),
              (
                textAlignment: TextAlign.right,
                position: SubtitlePosition.top,
                assAlignment: 9,
                x: 663,
                y: 90,
              ),
              (
                textAlignment: TextAlign.end,
                position: SubtitlePosition.center,
                assAlignment: 6,
                x: 663,
                y: 378,
              ),
            ];

        for (final testCase in cases) {
          final document = SubtitleExportService.buildAssDocument(
            [
              SubtitleEntry(
                startTime: Duration.zero,
                endTime: const Duration(seconds: 1),
                text: 'Aligned cue',
                styleOverride: SubtitleStyleModel(
                  position: testCase.position,
                  verticalOffset: 4,
                  offsetX: 39,
                  offsetY: 5,
                  maxWidthFactor: 0.5,
                  textAlignment: testCase.textAlignment,
                ),
              ),
            ],
            const SubtitleStyleModel(),
            playResX: 780,
            playResY: 720,
          );
          final styleLine = document
              .split('\n')
              .singleWhere((line) => line.startsWith('Style: Cue0,'));
          final styleFields = styleLine.split(',');
          final dialogue = document
              .split('\n')
              .singleWhere((line) => line.startsWith('Dialogue: 1,'));

          expect(
            styleFields[18],
            '${testCase.assAlignment}',
            reason: '${testCase.textAlignment} must retain vertical anchoring',
          );
          expect(styleFields[19], '195');
          expect(styleFields[20], '195');
          expect(
            dialogue,
            contains('{\\pos(${testCase.x},${testCase.y})}'),
            reason:
                '${testCase.textAlignment} must use its translated box anchor',
          );
        }
      },
    );

    test('ASS word pop uses word timing without duplicating cue text', () {
      final document = SubtitleExportService.buildAssDocument([
        SubtitleEntry(
          id: 'timed-pop',
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 4),
          text: 'Hello, brave world!',
          words: const [
            WordTiming(
              word: 'Hello',
              startTime: Duration(seconds: 1),
              endTime: Duration(milliseconds: 1400),
            ),
            WordTiming(
              word: 'brave',
              startTime: Duration(milliseconds: 1550),
              endTime: Duration(seconds: 2),
            ),
            WordTiming(
              word: 'world',
              startTime: Duration(milliseconds: 2200),
              endTime: Duration(milliseconds: 2800),
            ),
          ],
          styleOverride: const SubtitleStyleModel(
            animationPreset: SubtitleAnimationPreset.wordPop,
            backgroundType: SubtitleBackground.semiTransparentBox,
          ),
        ),
      ], const SubtitleStyleModel());

      final dialogue = document
          .split('\n')
          .where((line) => line.startsWith('Dialogue: 1,'))
          .toList(growable: false);
      expect(dialogue, hasLength(1));
      expect(dialogue.single, contains(r'\t(0,120,'));
      expect(dialogue.single, contains(r'\t(550,670,'));
      expect(dialogue.single, contains(r'\t(1200,1320,'));
      expect(dialogue.single, contains(r'\fscx60\fscy60'));
      final cueText = dialogue.single.substring(
        dialogue.single.lastIndexOf(',,') + 2,
      );
      expect(
        cueText.replaceAll(RegExp(r'\{[^}]*\}'), ''),
        'Hello, brave world!',
      );
      expect(document, contains('Style: Cue0,'));
    });

    test('ASS word pop has deterministic timing when word data is absent', () {
      final document = SubtitleExportService.buildAssDocument([
        SubtitleEntry(
          startTime: const Duration(seconds: 3),
          endTime: const Duration(seconds: 5),
          text: 'One two three',
          styleOverride: const SubtitleStyleModel(
            animationPreset: SubtitleAnimationPreset.wordPop,
          ),
        ),
      ], const SubtitleStyleModel());

      final dialogue = document
          .split('\n')
          .singleWhere((line) => line.startsWith('Dialogue: 1,'));
      expect(dialogue, contains(r'\t(0,120,'));
      expect(dialogue, contains(r'\t(160,280,'));
      expect(dialogue, contains(r'\t(320,440,'));
    });

    test('ASS karaoke fallback sweeps the exact cue for its full duration', () {
      final document = SubtitleExportService.buildAssDocument([
        SubtitleEntry(
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 4),
          text: 'Sing, every word!',
          styleOverride: const SubtitleStyleModel(
            animationPreset: SubtitleAnimationPreset.karaokeHighlight,
          ),
        ),
      ], const SubtitleStyleModel());

      final dialogue = document
          .split('\n')
          .singleWhere((line) => line.startsWith('Dialogue: 1,'));
      expect(dialogue, contains(r'\kf200'));
      expect(dialogue, endsWith('Sing, every word!'));
    });

    test('ASS timed karaoke preserves source punctuation and spacing', () {
      final document = SubtitleExportService.buildAssDocument([
        SubtitleEntry(
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 3),
          text: 'Hello,  world!',
          words: const [
            WordTiming(
              word: 'Hello',
              startTime: Duration(seconds: 1),
              endTime: Duration(milliseconds: 1400),
            ),
            WordTiming(
              word: 'world',
              startTime: Duration(milliseconds: 1500),
              endTime: Duration(seconds: 2),
            ),
          ],
          styleOverride: const SubtitleStyleModel(
            animationPreset: SubtitleAnimationPreset.karaokeHighlight,
          ),
        ),
      ], const SubtitleStyleModel());

      final dialogue = document
          .split('\n')
          .singleWhere((line) => line.startsWith('Dialogue: 1,'));
      final cueText = dialogue.substring(dialogue.lastIndexOf(',,') + 2);
      expect(
        cueText.replaceAll(RegExp(r'\{[^}]*\}'), '').replaceAll(r'\h', ''),
        'Hello,  world!',
      );
    });

    testWidgets('slide-up preview honestly animates the whole line', (
      tester,
    ) async {
      final entry = SubtitleEntry(
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 3),
        text: 'One two',
        words: const [
          WordTiming(
            word: 'One',
            startTime: Duration(seconds: 1),
            endTime: Duration(milliseconds: 1400),
          ),
          WordTiming(
            word: 'two',
            startTime: Duration(milliseconds: 1500),
            endTime: Duration(seconds: 2),
          ),
        ],
        styleOverride: const SubtitleStyleModel(
          animationPreset: SubtitleAnimationPreset.wordSlideUp,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AnimatedSubtitleOverlay(
            entry: entry,
            globalStyle: const SubtitleStyleModel(),
            currentPosition: const Duration(milliseconds: 1090),
          ),
        ),
      );

      expect(find.text('One two'), findsOneWidget);
      expect(find.text('One'), findsNothing);
      expect(find.text('two'), findsNothing);
      final transforms = tester.widgetList<Transform>(
        find.descendant(
          of: find.byType(AnimatedSubtitleOverlay),
          matching: find.byType(Transform),
        ),
      );
      expect(
        transforms.any(
          (widget) => (widget.transform.storage[13] - 6).abs() < 0.001,
        ),
        isTrue,
      );
    });

    testWidgets('preview honors a complete per-cue style override', (
      tester,
    ) async {
      final entry = SubtitleEntry(
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
        text: 'Override style',
        styleOverride: const SubtitleStyleModel(
          fontSize: 42,
          position: SubtitlePosition.top,
          offsetX: 18,
          offsetY: -12,
          maxWidthFactor: 0.55,
        ),
      );
      const global = SubtitleStyleModel(
        fontSize: 10,
        position: SubtitlePosition.bottom,
        maxWidthFactor: 0.9,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: AnimatedSubtitleOverlay(
              entry: entry,
              globalStyle: global,
              currentPosition: const Duration(seconds: 1),
            ),
          ),
        ),
      );

      final renderedText = tester.widget<Text>(find.text('Override style'));
      expect(renderedText.style?.fontSize, 42);
      final widthBox = tester.widget<FractionallySizedBox>(
        find.descendant(
          of: find.byType(AnimatedSubtitleOverlay),
          matching: find.byType(FractionallySizedBox),
        ),
      );
      expect(widthBox.widthFactor, 0.55);

      final resolved = resolvePreviewSubtitleStyleForTesting(
        entry: entry,
        globalStyle: global,
      );
      expect(resolved.position, SubtitlePosition.top);
      expect(resolved.offsetX, 18);
      expect(resolved.offsetY, -12);
    });

    test('typewriter reveals whole user-perceived characters', () {
      const text = 'A👨‍👩‍👧‍👦e\u0301🇮🇳';

      expect(typewriterTextAtProgressForTesting(text, 0.25), 'A');
      expect(typewriterTextAtProgressForTesting(text, 0.5), 'A👨‍👩‍👧‍👦');
      expect(
        typewriterTextAtProgressForTesting(text, 0.75),
        'A👨‍👩‍👧‍👦e\u0301',
      );
      expect(typewriterTextAtProgressForTesting(text, 1), text);
    });

    test('imports real-world SRT and WebVTT variants', () async {
      final directory = await Directory.systemTemp.createTemp(
        'captioncraft_subtitle_test_',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      final srt = File('${directory.path}${Platform.pathSeparator}sample.srt');
      await srt.writeAsString('''
\uFEFF1
00:00:01,250 --> 00:00:03,040
First line
continues here

2
00:01:04.500 --> 00:01:06.000
Second cue
''');
      final srtEntries = await SubtitleExportService.importSrt(srt.path);
      expect(srtEntries, hasLength(2));
      expect(srtEntries.first.startTime.inMilliseconds, 1250);
      expect(srtEntries.first.text, 'First line\ncontinues here');
      expect(
        srtEntries.last.startTime,
        const Duration(minutes: 1, seconds: 4, milliseconds: 500),
      );

      final vtt = File('${directory.path}${Platform.pathSeparator}sample.vtt');
      await vtt.writeAsString('''
\uFEFFWEBVTT

NOTE generated by a caption service
this note spans two lines

cue-1
00:01.500 --> 00:04.000 align:center position:50%
Hello from VTT

01:05.000 --> 01:07.250
Minute timestamp
''');
      final vttEntries = await SubtitleExportService.importVtt(vtt.path);
      expect(vttEntries, hasLength(2));
      expect(vttEntries.first.startTime.inMilliseconds, 1500);
      expect(vttEntries.last.startTime, const Duration(minutes: 1, seconds: 5));
      expect(vttEntries.last.endTime.inMilliseconds, 67250);
    });
  });
}
