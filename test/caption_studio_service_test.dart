import 'package:caption_craft/core/utils/caption_studio_service.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('caption repair tools', () {
    test('balances long text across two lines without losing words', () {
      final source = _entry(
        text: 'A carefully balanced subtitle should remain easy to scan',
      );

      final result = CaptionStudioService.balanceLines([
        source,
      ], maximumLineLength: 30);

      expect(result.changed, isTrue);
      expect(result.entries.single.text.split('\n'), hasLength(2));
      expect(result.entries.single.text.replaceAll('\n', ' '), source.text);
    });

    test('retimes captions to reading speed and preserves cue boundaries', () {
      final source = [
        _entry(
          id: 'first',
          text: 'This caption needs a little more time to read clearly',
          startMs: 0,
          endMs: 800,
          words: const [
            WordTiming(
              word: 'This',
              startTime: Duration.zero,
              endTime: Duration(milliseconds: 200),
            ),
          ],
        ),
        _entry(id: 'second', text: 'Next cue', startMs: 3000, endMs: 4000),
      ];

      final result = CaptionStudioService.retimeForReadingSpeed(
        source,
        targetCharactersPerSecond: 15,
      );

      expect(
        result.entries.first.endTime,
        lessThanOrEqualTo(
          result.entries.last.startTime - const Duration(milliseconds: 80),
        ),
      );
      expect(result.entries.first.duration.inMilliseconds, greaterThan(800));
      expect(result.entries.first.words!.single.startTime, Duration.zero);
      expect(
        result.entries.first.words!.single.endTime,
        greaterThan(const Duration(milliseconds: 200)),
      );
    });

    test('splits oversized cues into contiguous timed captions', () {
      final source = _entry(
        id: 'long',
        text:
            'One two three four five six seven eight nine ten eleven twelve '
            'thirteen fourteen fifteen sixteen seventeen eighteen',
        startMs: 1000,
        endMs: 7000,
      );

      final result = CaptionStudioService.splitLongCues([
        source,
      ], maximumCharacters: 35);

      expect(result.entries.length, greaterThan(1));
      expect(result.entries.first.id, source.id);
      expect(result.entries.first.startTime, source.startTime);
      expect(result.entries.last.endTime, source.endTime);
      for (var index = 0; index < result.entries.length - 1; index++) {
        expect(
          result.entries[index].endTime,
          result.entries[index + 1].startTime,
        );
      }
    });

    test('merges neighboring short cues but not distant cues', () {
      final source = [
        _entry(id: 'one', text: 'Small thought.', startMs: 0, endMs: 900),
        _entry(id: 'two', text: 'Continued.', startMs: 1000, endMs: 1800),
        _entry(id: 'three', text: 'Much later.', startMs: 4000, endMs: 4800),
      ];

      final result = CaptionStudioService.mergeShortCues(source);

      expect(result.entries, hasLength(2));
      expect(result.entries.first.text, 'Small thought. Continued.');
      expect(result.entries.last.id, 'three');
    });

    test('removes safe filler phrases and clears stale word timing', () {
      final source = _entry(
        text: 'Um, you know, this is the point.',
        words: const [
          WordTiming(
            word: 'Um',
            startTime: Duration.zero,
            endTime: Duration(milliseconds: 100),
          ),
        ],
      );

      final result = CaptionStudioService.removeFillerWords([source]);

      expect(result.entries.single.text, 'this is the point.');
      expect(result.entries.single.words, isNull);
    });

    test('removes accidental repeated consecutive words', () {
      final source = _entry(text: 'This this is is ready now.');

      final result = CaptionStudioService.removeRepeatedWords([source]);

      expect(result.entries.single.text, 'This is ready now.');
    });

    test('polishes capitalization and question punctuation', () {
      final source = _entry(text: 'why does this work');

      final result = CaptionStudioService.polishPunctuation([source]);

      expect(result.entries.single.text, 'Why does this work?');
    });

    test('snaps caption boundaries to a frame grid', () {
      final source = _entry(text: 'Frame perfect', startMs: 94, endMs: 1094);

      final result = CaptionStudioService.snapToFrameGrid([
        source,
      ], framesPerSecond: 30);

      expect(result.entries.single.startTime.inMilliseconds, 100);
      expect(result.entries.single.endTime.inMilliseconds, 1100);
    });

    test('removes empty cues only', () {
      final source = [
        _entry(id: 'blank', text: '  '),
        _entry(id: 'kept', text: 'Keep me'),
      ];

      final result = CaptionStudioService.removeEmptyCues(source);

      expect(result.entries.map((entry) => entry.id), ['kept']);
    });

    test('removes bracketed sound cues while preserving dialogue', () {
      final source = [
        _entry(id: 'music', text: '[Music]'),
        _entry(id: 'dialogue', text: 'Music changed my life.'),
      ];

      final result = CaptionStudioService.removeSoundCues(source);

      expect(result.entries.map((entry) => entry.id), ['dialogue']);
    });

    test('masks selected terms case-insensitively', () {
      final source = _entry(text: 'Hide SECRET but not secretion.');

      final result = CaptionStudioService.maskTerms([source], ['secret']);

      expect(result.entries.single.text, 'Hide •••••• but not secretion.');
    });

    test('adds alternating speaker labels in configurable groups', () {
      final source = List.generate(
        4,
        (index) => _entry(
          id: '$index',
          text: 'Line $index',
          startMs: index * 1000,
          endMs: index * 1000 + 800,
        ),
      );

      final result = CaptionStudioService.addSpeakerLabels(source, [
        'Aadi',
        'Maya',
      ], cuesPerSpeaker: 2);

      expect(result.entries[0].text, 'AADI: Line 0');
      expect(result.entries[1].text, 'AADI: Line 1');
      expect(result.entries[2].text, 'MAYA: Line 2');
    });

    test('strips common speaker label formats', () {
      final source = [
        _entry(id: 'one', text: 'HOST: Welcome back'),
        _entry(id: 'two', text: '[Guest] Great to be here'),
      ];

      final result = CaptionStudioService.stripSpeakerLabelsFromEntries(source);

      expect(result.entries.map((entry) => entry.text), [
        'Welcome back',
        'Great to be here',
      ]);
    });

    test('applies a multi-term glossary consistently', () {
      final source = _entry(text: 'Flutter and fire base work together.');

      final result = CaptionStudioService.applyGlossary(
        [source],
        {'fire base': 'Firebase', 'flutter': 'Flutter'},
      );

      expect(result.entries.single.text, 'Flutter and Firebase work together.');
    });

    test('adds timing padding without colliding with neighbors', () {
      final source = [
        _entry(id: 'one', text: 'One', startMs: 500, endMs: 1000),
        _entry(id: 'two', text: 'Two', startMs: 1200, endMs: 1800),
      ];

      final result = CaptionStudioService.addTimingPadding(source);

      expect(result.entries.first.startTime.inMilliseconds, 400);
      expect(result.entries.first.endTime.inMilliseconds, 1080);
      expect(result.entries.last.startTime.inMilliseconds, 1120);
      expect(
        result.entries.last.startTime - result.entries.first.endTime,
        const Duration(milliseconds: 40),
      );
    });
  });

  group('caption intelligence', () {
    test('classifies pace bands from cue density', () {
      final metrics = CaptionStudioService.analyzePace([
        _entry(id: 'slow', text: 'Short', startMs: 0, endMs: 3000),
        _entry(
          id: 'fast',
          text: 'This exceptionally dense line moves far too quickly',
          startMs: 4000,
          endMs: 4700,
        ),
      ]);

      expect(metrics.first.band, CaptionPaceBand.slow);
      expect(metrics.last.band, CaptionPaceBand.extreme);
    });

    test('finds high-energy non-overlapping viral moments', () {
      final moments = CaptionStudioService.findViralMoments([
        _entry(
          text: 'Here is the biggest secret nobody tells you!',
          startMs: 0,
          endMs: 2500,
        ),
        _entry(
          text: 'Why does this surprising trick work?',
          startMs: 2600,
          endMs: 5000,
        ),
        _entry(text: 'A calm unrelated ending.', startMs: 20000, endMs: 23000),
      ]);

      expect(moments, isNotEmpty);
      expect(moments.first.score, greaterThan(50));
      expect(moments.first.reasons, isNotEmpty);
    });

    test('generates chapter boundaries from long pauses', () {
      final chapters = CaptionStudioService.generateChapters([
        _entry(text: 'Camera setup and lighting', startMs: 0, endMs: 2000),
        _entry(text: 'Lens choices explained', startMs: 2200, endMs: 4200),
        _entry(text: 'Audio mixing workflow', startMs: 10000, endMs: 12000),
      ]);

      expect(chapters, hasLength(2));
      expect(chapters.first.position, Duration.zero);
      expect(chapters.last.position, const Duration(seconds: 10));
      expect(chapters.every((chapter) => chapter.title.isNotEmpty), isTrue);
    });

    test('directs energetic and question captions with different motion', () {
      const globalStyle = SubtitleStyleModel();
      final result = CaptionStudioService.directKineticCaptions([
        _entry(id: 'energy', text: 'This is amazing!'),
        _entry(id: 'question', text: 'How did that happen?'),
      ], globalStyle: globalStyle);

      expect(
        result.entries.first.styleOverride!.animationPreset,
        SubtitleAnimationPreset.wordPop,
      );
      expect(result.entries.first.styleOverride!.isBold, isTrue);
      expect(
        result.entries.last.styleOverride!.animationPreset,
        SubtitleAnimationPreset.typewriter,
      );
    });

    test('builds spaced B-roll prompts from concrete caption keywords', () {
      final suggestions = CaptionStudioService.generateBrollStoryboard([
        _entry(
          text: 'A vintage camera captures mountain light',
          startMs: 0,
          endMs: 2000,
        ),
        _entry(
          text: 'Coffee beans roast inside the studio',
          startMs: 10000,
          endMs: 12000,
        ),
      ]);

      expect(suggestions, hasLength(2));
      expect(suggestions.first.prompt, contains('Cinematic'));
      expect(
        suggestions.last.position - suggestions.first.position,
        greaterThanOrEqualTo(const Duration(seconds: 8)),
      );
    });

    test('generates a complete social launch pack', () {
      final pack = CaptionStudioService.generateSocialLaunchPack([
        _entry(text: 'The biggest camera lighting mistake is easy to fix.'),
        _entry(
          text: 'This simple lighting workflow makes portraits stronger.',
          startMs: 3000,
          endMs: 5000,
        ),
      ], projectName: 'Portrait Masterclass');

      expect(pack.titles, hasLength(3));
      expect(pack.hooks, hasLength(3));
      expect(pack.description, isNotEmpty);
      expect(pack.hashtags, contains('#CaptionCraft'));
      expect(pack.asPlainText, contains('TITLE IDEAS'));
    });

    test('synthesizes contiguous word timing for imported captions', () {
      final source = _entry(
        text: 'Karaoke timing works',
        startMs: 1000,
        endMs: 4000,
      );

      final result = CaptionStudioService.synthesizeKaraokeTimings([source]);
      final words = result.entries.single.words!;

      expect(words, hasLength(3));
      expect(words.first.startTime, source.startTime);
      expect(words.last.endTime, source.endTime);
      for (var index = 0; index < words.length - 1; index++) {
        expect(words[index].endTime, words[index + 1].startTime);
      }
    });

    test(
      'kinetic style and generated word timing survive JSON persistence',
      () {
        const style = SubtitleStyleModel();
        final karaoke = CaptionStudioService.synthesizeKaraokeTimings([
          _entry(text: 'This is amazing!', startMs: 500, endMs: 2500),
        ]);
        final directed = CaptionStudioService.directKineticCaptions(
          karaoke.entries,
          globalStyle: style,
        );

        final restored = SubtitleEntry.fromJson(
          directed.entries.single.toJson(),
        );

        expect(restored.words, isNotEmpty);
        expect(
          restored.words!.first.startTime,
          const Duration(milliseconds: 500),
        );
        expect(
          restored.styleOverride!.animationPreset,
          SubtitleAnimationPreset.wordPop,
        );
        expect(restored.styleOverride!.isBold, isTrue);
      },
    );
  });
}

SubtitleEntry _entry({
  String? id,
  required String text,
  int startMs = 0,
  int endMs = 2000,
  double confidence = 1,
  List<WordTiming>? words,
}) {
  return SubtitleEntry(
    id: id,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
    text: text,
    confidenceScore: confidence,
    words: words,
  );
}
