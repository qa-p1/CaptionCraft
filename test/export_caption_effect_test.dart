import 'dart:io';

import 'package:caption_craft/core/utils/caption_font_service.dart';
import 'package:caption_craft/core/utils/subtitle_export_service.dart';
import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/features/editor/models/export_settings.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('caption export safeguards', () {
    test('resolves visible captions without losing rich cue data', () {
      final richEntry = SubtitleEntry(
        id: 'enabled',
        startTime: const Duration(milliseconds: 500),
        endTime: const Duration(seconds: 2),
        text: 'Keep every word',
        confidenceScore: 0.73,
        words: const [
          WordTiming(
            word: 'Keep',
            startTime: Duration(milliseconds: 500),
            endTime: Duration(milliseconds: 850),
          ),
          WordTiming(
            word: 'every',
            startTime: Duration(milliseconds: 900),
            endTime: Duration(milliseconds: 1300),
          ),
          WordTiming(
            word: 'word',
            startTime: Duration(milliseconds: 1400),
            endTime: Duration(milliseconds: 1900),
          ),
        ],
        styleOverride: const SubtitleStyleModel(
          fontFamily: 'Poppins',
          isBold: true,
        ),
      );
      final disabledEntry = SubtitleEntry(
        id: 'disabled',
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 3),
        text: 'Do not render',
      );
      final hiddenEntry = SubtitleEntry(
        id: 'hidden',
        startTime: const Duration(seconds: 3),
        endTime: const Duration(seconds: 4),
        text: 'Hidden track',
      );
      final importedEntry = SubtitleEntry(
        id: 'imported',
        startTime: const Duration(seconds: 4),
        endTime: const Duration(seconds: 5),
        text: 'Migration-safe caption',
      );
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'visible_subtitles',
            name: 'Captions',
            type: TimelineTrackType.subtitle,
            clips: [
              TimelineClip.fromSubtitleEntry(
                richEntry,
                trackId: 'visible_subtitles',
              ),
              TimelineClip.fromSubtitleEntry(
                disabledEntry,
                trackId: 'visible_subtitles',
              ).copyWith(enabled: false),
            ],
          ),
          TimelineTrack(
            id: 'hidden_subtitles',
            name: 'Hidden captions',
            type: TimelineTrackType.subtitle,
            isHidden: true,
            clips: [
              TimelineClip.fromSubtitleEntry(
                hiddenEntry,
                trackId: 'hidden_subtitles',
              ),
            ],
          ),
        ],
      );

      final resolved = SubtitleExportService.effectiveTimelineCaptions(
        timeline: timeline,
        entries: [richEntry, disabledEntry, hiddenEntry, importedEntry],
      );

      expect(resolved.map((entry) => entry.id), ['enabled', 'imported']);
      expect(identical(resolved.first, richEntry), isTrue);
      expect(resolved.first.words, same(richEntry.words));
      expect(resolved.first.styleOverride, same(richEntry.styleOverride));
      expect(resolved.first.confidenceScore, 0.73);
    });

    test('preflight rejects empty ASS output and accepts dialogue', () async {
      final directory = await Directory.systemTemp.createTemp(
        'captioncraft_ass_preflight_',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      final missing = File('${directory.path}/missing.ass');
      await expectLater(
        SubtitleExportService.preflightAssFile(missing.path),
        throwsA(isA<StateError>()),
      );

      final empty = File('${directory.path}/empty.ass');
      await empty.writeAsString('');
      await expectLater(
        SubtitleExportService.preflightAssFile(empty.path),
        throwsA(isA<StateError>()),
      );

      final headerOnly = File('${directory.path}/header.ass');
      await headerOnly.writeAsString('[Events]\nFormat: Layer, Start, End\n');
      await expectLater(
        SubtitleExportService.preflightAssFile(headerOnly.path),
        throwsA(isA<StateError>()),
      );

      final valid = File('${directory.path}/valid.ass');
      await valid.writeAsString(
        '[Events]\n'
        'Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,Visible\n',
      );
      final result = await SubtitleExportService.preflightAssFile(valid.path);
      expect(result.fileSize, greaterThan(0));
      expect(result.dialogueCount, 1);
    });

    test('ASS font names always resolve to bundled families', () {
      expect(CaptionFontService.resolveFamily('Arial'), 'Roboto');
      expect(CaptionFontService.resolveFamily('unknown-device-font'), 'Inter');

      final document = SubtitleExportService.buildAssDocument([
        SubtitleEntry(
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          text: 'Bundled font',
        ),
      ], const SubtitleStyleModel(fontFamily: 'Arial'));
      expect(document, contains('Style: Default,Roboto,'));
    });
  });

  group('timed export effects', () {
    test('effect clips round-trip and are applied before captions', () {
      final baseClip = TimelineClip(
        id: 'base_clip',
        trackId: 'base_track',
        type: TimelineTrackType.video,
        label: 'Base',
        assetId: 'base_asset',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 3),
      );
      final baseTrack = TimelineTrack(
        id: 'base_track',
        name: 'Video 1',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [baseClip],
      );
      final regionBlur = TimelineClip.effect(
        id: 'blur_effect',
        trackId: 'effect_track',
        effectKind: TimelineEffectKind.blur,
        label: 'Region blur',
        startTime: const Duration(milliseconds: 500),
        endTime: const Duration(milliseconds: 1500),
        blur: const ClipBlurSettings(
          mode: ClipBlurMode.region,
          strength: 14,
          regionX: 0.1,
          regionY: 0.2,
          regionWidth: 0.4,
          regionHeight: 0.3,
        ),
      );
      final warmFilter = TimelineClip.effect(
        id: 'filter_effect',
        trackId: 'effect_track',
        effectKind: TimelineEffectKind.filter,
        label: 'Warm',
        startTime: const Duration(seconds: 1),
        endTime: const Duration(milliseconds: 2500),
        colorAdjustments: ClipColorAdjustments.forPreset(ClipFilterPreset.warm),
      );
      final effectTrack = TimelineTrack(
        id: 'effect_track',
        name: 'Effects',
        type: TimelineTrackType.effect,
        section: TimelineTrackSection.overlay,
        clips: [regionBlur, warmFilter],
      );
      final timeline = EditorTimeline(tracks: [baseTrack, effectTrack]);

      final restored = EditorTimeline.fromJson(timeline.toJson());
      expect(
        restored.tracks.last.clips.first.effectKind,
        TimelineEffectKind.blur,
      );
      expect(
        restored.tracks.last.clips.last.effectKind,
        TimelineEffectKind.filter,
      );

      final arguments = TimelineExportService.buildFfmpegArguments(
        timeline: restored,
        inputs: [
          TimelineRenderInput(
            index: 0,
            trackIndex: 0,
            track: restored.tracks.first,
            clip: restored.tracks.first.clips.single,
            asset: null,
            sourcePath: 'base.mp4',
            hasAudio: false,
          ),
        ],
        settings: const ExportSettings(includeAudio: false),
        canvasSize: const ExportCanvasSize(
          width: 640,
          height: 360,
          framesPerSecond: 30,
        ),
        timelineDuration: const Duration(seconds: 3),
        assPath: 'C:/tmp/captions.ass',
        captionFontDirectory: 'C:/tmp/caption fonts',
        outputPath: 'output.mp4',
      );
      final graph = arguments[arguments.indexOf('-filter_complex') + 1];

      expect(graph, contains('between(t,0.500000,1.500000)'));
      expect(graph, contains('between(t,1.000000,2.500000)'));
      expect(graph, contains('effectBlurRegion'));
      expect(graph, contains('colorchannelmixer=rr='));
      expect(graph, contains("fontsdir='C\\:/tmp/caption fonts'"));
      expect(graph.indexOf('timelineEffect'), lessThan(graph.indexOf('ass=')));
      expect(RegExp(r'fps=30').allMatches(graph), hasLength(1));
      expect(arguments, isNot(contains('-r')));
    });
  });
}
