import 'package:caption_craft/core/constants/groq_constants.dart';
import 'package:caption_craft/core/utils/api_key_vault.dart';
import 'package:caption_craft/core/utils/groq_service.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'missing user key gives Settings guidance without requiring a proxy',
    () {
      ApiKeys.selectOwner(null);
      expect(GroqConstants.apiKey, isEmpty);
      expect(GroqService.isConfigured, isFalse);
      expect(
        GroqService.ensureConfigured,
        throwsA(predicate((e) => e.toString().contains('Settings'))),
      );
    },
  );

  test('transcription endpoint is fixed HTTPS without user credentials', () {
    final endpoint = Uri.parse(
      '${GroqConstants.baseUrl}${GroqConstants.transcriptionsEndpoint}',
    );
    expect(endpoint.scheme, 'https');
    expect(endpoint.host, 'api.groq.com');
    expect(endpoint.userInfo, isEmpty);
    expect(endpoint.query, isEmpty);
  });

  test('Groq word parsing clamps or rejects invalid timestamps', () {
    final words = GroqService.parseWordsResponse({
      'words': [
        {'word': 'later', 'start': 0.5, 'end': 0.75},
        {'word': 'clamped', 'start': -0.2, 'end': 0.25},
        {'word': 'reversed', 'start': 1.0, 'end': 0.5},
        {'word': 'empty', 'start': 2.0, 'end': 2.0},
        {'word': 'non-finite', 'start': double.nan, 'end': 3.0},
        {'word': 42, 'start': 3.0, 'end': 4.0},
        {'word': 'rounds-to-zero', 'start': 1.0001, 'end': 1.0002},
      ],
    }, const Duration(seconds: 2));

    expect(words, hasLength(2));
    expect(words.first.word, 'clamped');
    expect(words.first.startTime, const Duration(seconds: 2));
    expect(words.first.endTime, const Duration(milliseconds: 2250));
    expect(words.last.word, 'later');
    expect(words.last.startTime, const Duration(milliseconds: 2500));
    expect(words.last.endTime, const Duration(milliseconds: 2750));
  });

  test('Groq word parsing rejects non-object response bodies', () {
    expect(
      () => GroqService.parseWordsResponse(const ['unexpected'], Duration.zero),
      throwsFormatException,
    );
  });

  test(
    'Groq parsing falls back to segment timing when word arrays are empty',
    () {
      final words = GroqService.parseWordsResponse({
        'words': const [],
        'segments': [
          {'words': const [], 'text': 'fallback', 'start': 0.0, 'end': 0.5},
          {
            'words': [
              {'word': 'timed', 'start': 0.5, 'end': 1.0},
            ],
            'text': 'timed',
            'start': 0.5,
            'end': 1.0,
          },
        ],
      }, Duration.zero);

      expect(words.map((word) => word.word), ['fallback', 'timed']);
    },
  );

  test('caption grouping preserves input order for equal start times', () {
    final entries = GroqService.groupWordsIntoLines([
      const WordTiming(
        word: 'alpha',
        startTime: Duration.zero,
        endTime: Duration(milliseconds: 300),
      ),
      const WordTiming(
        word: 'zulu',
        startTime: Duration.zero,
        endTime: Duration(milliseconds: 100),
      ),
    ]);

    expect(entries.single.text, 'alpha zulu');
    expect(entries.single.endTime, const Duration(milliseconds: 300));
  });

  test('Groq parsing preserves equal-timestamp word order', () {
    final words = GroqService.parseWordsResponse({
      'words': [
        {'word': 'first', 'start': 1.0, 'end': 1.3},
        {'word': 'second', 'start': 1.0, 'end': 1.1},
      ],
    }, Duration.zero);

    expect(words.map((word) => word.word), ['first', 'second']);
  });

  test('subtitle overlap deduplication does not reorder its input list', () {
    final entries = [
      SubtitleEntry(
        id: 'later',
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 3),
        text: 'later',
      ),
      SubtitleEntry(
        id: 'earlier',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
        text: 'earlier',
      ),
    ];

    final result = GroqService.deduplicateOverlaps(entries);

    expect(entries.map((entry) => entry.id), ['later', 'earlier']);
    expect(result.map((entry) => entry.id), ['earlier', 'later']);
  });
}
