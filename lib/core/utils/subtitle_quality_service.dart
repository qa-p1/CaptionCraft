import '../../features/editor/models/subtitle_entry.dart';

enum SubtitleIssueType {
  overlap,
  tooFast,
  tooLong,
  tooShort,
  tooManyLines,
  longLine,
  lowConfidence,
  empty,
}

class SubtitleQualityIssue {
  final SubtitleIssueType type;
  final String entryId;
  final String message;

  const SubtitleQualityIssue({
    required this.type,
    required this.entryId,
    required this.message,
  });
}

class SubtitleQualityReport {
  final List<SubtitleQualityIssue> issues;
  final int cueCount;
  final double averageCharactersPerSecond;

  const SubtitleQualityReport({
    required this.issues,
    required this.cueCount,
    required this.averageCharactersPerSecond,
  });

  int countFor(SubtitleIssueType type) {
    return issues.where((issue) => issue.type == type).length;
  }

  bool get isClean => issues.isEmpty;
}

class SubtitleQualityService {
  SubtitleQualityService._();

  static SubtitleQualityReport analyze(
    List<SubtitleEntry> entries, {
    Map<String, String>? laneByEntryId,
    double maximumCharactersPerSecond = 20,
    int maximumLineLength = 42,
    int maximumLines = 2,
    Duration minimumDuration = const Duration(milliseconds: 700),
    Duration maximumDuration = const Duration(seconds: 7),
  }) {
    final sorted = List<SubtitleEntry>.from(entries)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final issues = <SubtitleQualityIssue>[];
    var charactersPerSecondTotal = 0.0;
    var measuredCueCount = 0;

    final nextEntryInLane = <String, SubtitleEntry>{};
    final lanes = <String, List<SubtitleEntry>>{};
    for (final entry in sorted) {
      final laneId = laneByEntryId?[entry.id] ?? '__captions__';
      lanes.putIfAbsent(laneId, () => []).add(entry);
    }
    for (final lane in lanes.values) {
      for (var index = 0; index < lane.length - 1; index++) {
        nextEntryInLane[lane[index].id] = lane[index + 1];
      }
    }

    for (final entry in sorted) {
      final text = entry.text.trim();
      final durationMs = entry.duration.inMilliseconds;

      if (text.isEmpty) {
        issues.add(
          SubtitleQualityIssue(
            type: SubtitleIssueType.empty,
            entryId: entry.id,
            message: 'Empty subtitle cue',
          ),
        );
        continue;
      }

      if (durationMs > 0) {
        final cps =
            text.replaceAll(RegExp(r'\s+'), ' ').length / (durationMs / 1000);
        charactersPerSecondTotal += cps;
        measuredCueCount++;
        if (cps > maximumCharactersPerSecond) {
          issues.add(
            SubtitleQualityIssue(
              type: SubtitleIssueType.tooFast,
              entryId: entry.id,
              message: '${cps.toStringAsFixed(1)} characters/second',
            ),
          );
        }
      }

      if (entry.duration < minimumDuration) {
        issues.add(
          SubtitleQualityIssue(
            type: SubtitleIssueType.tooShort,
            entryId: entry.id,
            message: 'Cue is shorter than ${minimumDuration.inMilliseconds}ms',
          ),
        );
      }
      if (entry.duration > maximumDuration) {
        issues.add(
          SubtitleQualityIssue(
            type: SubtitleIssueType.tooLong,
            entryId: entry.id,
            message: 'Cue is longer than ${maximumDuration.inSeconds}s',
          ),
        );
      }

      final lines = text.split('\n');
      if (lines.length > maximumLines) {
        issues.add(
          SubtitleQualityIssue(
            type: SubtitleIssueType.tooManyLines,
            entryId: entry.id,
            message: '${lines.length} lines (recommended: $maximumLines)',
          ),
        );
      }
      if (lines.any((line) => line.length > maximumLineLength)) {
        issues.add(
          SubtitleQualityIssue(
            type: SubtitleIssueType.longLine,
            entryId: entry.id,
            message: 'Line exceeds $maximumLineLength characters',
          ),
        );
      }
      if (entry.isLowConfidence) {
        issues.add(
          SubtitleQualityIssue(
            type: SubtitleIssueType.lowConfidence,
            entryId: entry.id,
            message:
                'Low transcription confidence (${(entry.confidenceScore * 100).round()}%)',
          ),
        );
      }

      final nextInLane = nextEntryInLane[entry.id];
      if (nextInLane != null && entry.endTime > nextInLane.startTime) {
        final overlapMs = (entry.endTime - nextInLane.startTime).inMilliseconds;
        issues.add(
          SubtitleQualityIssue(
            type: SubtitleIssueType.overlap,
            entryId: entry.id,
            message: 'Overlaps next cue by ${overlapMs}ms',
          ),
        );
      }
    }

    return SubtitleQualityReport(
      issues: issues,
      cueCount: sorted.length,
      averageCharactersPerSecond: measuredCueCount == 0
          ? 0
          : charactersPerSecondTotal / measuredCueCount,
    );
  }
}
