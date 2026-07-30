/// Represents timing data for a single word from Groq's word-level timestamps.
class WordTiming {
  final String word;
  final Duration startTime;
  final Duration endTime;

  const WordTiming({
    required this.word,
    required this.startTime,
    required this.endTime,
  });

  Map<String, dynamic> toJson() {
    return {
      'word': word,
      'startTimeMs': startTime.inMilliseconds,
      'endTimeMs': endTime.inMilliseconds,
    };
  }

  factory WordTiming.fromJson(Map<String, dynamic> json) {
    final startMs = _wordTimingInt(json['startTimeMs']);
    final storedEndMs = _wordTimingInt(
      json['endTimeMs'],
      fallback: startMs + 1,
    );
    return WordTiming(
      word: json['word']?.toString() ?? '',
      startTime: Duration(milliseconds: startMs),
      endTime: Duration(
        milliseconds: storedEndMs <= startMs ? startMs + 1 : storedEndMs,
      ),
    );
  }
}

int _wordTimingInt(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}
