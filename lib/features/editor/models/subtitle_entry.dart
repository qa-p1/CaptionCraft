import 'package:uuid/uuid.dart';
import 'subtitle_style_model.dart';
import 'word_timing.dart';

/// Represents a single subtitle cue on the timeline.
class SubtitleEntry {
  final String id;
  Duration startTime;
  Duration endTime;
  String text;
  SubtitleStyleModel? styleOverride; // null = use global style
  double confidenceScore;
  List<WordTiming>? words; // per-word timing data for animated presets

  SubtitleEntry({
    String? id,
    required this.startTime,
    required this.endTime,
    required this.text,
    this.styleOverride,
    this.confidenceScore = 1.0,
    this.words,
  }) : id = id ?? const Uuid().v4();

  bool get isLowConfidence => confidenceScore < 0.5;

  Duration get duration => endTime - startTime;

  SubtitleEntry copyWith({
    String? id,
    Duration? startTime,
    Duration? endTime,
    String? text,
    SubtitleStyleModel? styleOverride,
    bool clearStyleOverride = false,
    double? confidenceScore,
    List<WordTiming>? words,
    bool clearWords = false,
  }) {
    return SubtitleEntry(
      id: id ?? this.id,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      text: text ?? this.text,
      styleOverride: clearStyleOverride
          ? null
          : (styleOverride ?? this.styleOverride),
      confidenceScore: confidenceScore ?? this.confidenceScore,
      words: clearWords ? null : (words ?? this.words),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'startTimeMs': startTime.inMilliseconds,
      'endTimeMs': endTime.inMilliseconds,
      'text': text,
      'styleOverride': styleOverride?.toJson(),
      'confidenceScore': confidenceScore,
      'words': words?.map((w) => w.toJson()).toList(),
    };
  }

  factory SubtitleEntry.fromJson(Map<String, dynamic> json) {
    final startMs = _jsonInt(json['startTimeMs']);
    final storedEndMs = _jsonInt(json['endTimeMs'], fallback: startMs + 100);
    final endMs = storedEndMs <= startMs ? startMs + 100 : storedEndMs;
    SubtitleStyleModel? styleOverride;
    final styleData = json['styleOverride'];
    if (styleData is Map) {
      try {
        styleOverride = SubtitleStyleModel.fromJson(
          Map<String, dynamic>.from(styleData),
        );
      } catch (_) {
        styleOverride = null;
      }
    }

    List<WordTiming>? words;
    final wordData = json['words'];
    if (wordData is List) {
      final restoredWords = <WordTiming>[];
      for (final candidate in wordData.whereType<Map>()) {
        try {
          restoredWords.add(
            WordTiming.fromJson(Map<String, dynamic>.from(candidate)),
          );
        } catch (_) {
          // A damaged word timing must not make the whole project unreadable.
        }
      }
      if (restoredWords.isNotEmpty) words = restoredWords;
    }

    final storedId = json['id'];
    return SubtitleEntry(
      id: storedId is String && storedId.isNotEmpty ? storedId : null,
      startTime: Duration(milliseconds: startMs),
      endTime: Duration(milliseconds: endMs),
      text: json['text']?.toString() ?? '',
      styleOverride: styleOverride,
      confidenceScore: ((json['confidenceScore'] as num?)?.toDouble() ?? 1)
          .clamp(0, 1),
      words: words,
    );
  }

  /// Format time as HH:MM:SS,mmm (SRT format)
  static String formatSrtTime(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    final millis = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds,$millis';
  }

  /// Format time as HH:MM:SS.mmm (VTT format)
  static String formatVttTime(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    final millis = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds.$millis';
  }

  /// Format time for display in the UI (MM:SS.m)
  static String formatDisplayTime(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    final tenths = ((d.inMilliseconds % 1000) ~/ 100).toString();
    return '$minutes:$seconds.$tenths';
  }
}

int _jsonInt(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}
