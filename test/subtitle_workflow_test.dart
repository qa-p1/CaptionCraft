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
      expect(document, contains(r'\fscx82\fscy82'));
      expect(document, contains(r'\move('));
      expect(document, contains(r'{\k'));
      expect(document, contains(r'\p1'));
      expect(document, contains('&H004875FF'));
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
