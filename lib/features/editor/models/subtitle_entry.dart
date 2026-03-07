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
      words: words ?? this.words,
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
    return SubtitleEntry(
      id: json['id'] as String,
      startTime: Duration(milliseconds: json['startTimeMs'] as int),
      endTime: Duration(milliseconds: json['endTimeMs'] as int),
      text: json['text'] as String,
      styleOverride: json['styleOverride'] != null
          ? SubtitleStyleModel.fromJson(
              json['styleOverride'] as Map<String, dynamic>,
            )
          : null,
      confidenceScore: (json['confidenceScore'] as num?)?.toDouble() ?? 1.0,
      words: (json['words'] as List<dynamic>?)
          ?.map((w) => WordTiming.fromJson(w as Map<String, dynamic>))
          .toList(),
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
