import 'package:caption_craft/core/utils/groq_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
