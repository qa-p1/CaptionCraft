import 'package:caption_craft/core/constants/groq_constants.dart';
import 'package:caption_craft/core/utils/api_key_vault.dart';
import 'package:caption_craft/core/utils/groq_service.dart';
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
}
