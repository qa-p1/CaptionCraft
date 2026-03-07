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
    return WordTiming(
      word: json['word'] as String,
      startTime: Duration(milliseconds: json['startTimeMs'] as int),
      endTime: Duration(milliseconds: json['endTimeMs'] as int),
    );
  }
}
