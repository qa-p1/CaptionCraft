import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../features/editor/models/subtitle_entry.dart';
import '../../features/editor/models/subtitle_style_model.dart';
import '../../features/editor/models/word_timing.dart';

enum CaptionPaceBand { slow, balanced, fast, extreme }

class CaptionTransformResult {
  final List<SubtitleEntry> entries;
  final int changedCount;
  final String summary;

  const CaptionTransformResult({
    required this.entries,
    required this.changedCount,
    required this.summary,
  });

  bool get changed => changedCount > 0;
}

class CaptionPaceMetric {
  final SubtitleEntry entry;
  final double charactersPerSecond;
  final double wordsPerMinute;
  final CaptionPaceBand band;

  const CaptionPaceMetric({
    required this.entry,
    required this.charactersPerSecond,
    required this.wordsPerMinute,
    required this.band,
  });
}

class ViralMoment {
  final Duration start;
  final Duration end;
  final int score;
  final String snippet;
  final List<String> reasons;

  const ViralMoment({
    required this.start,
    required this.end,
    required this.score,
    required this.snippet,
    required this.reasons,
  });

  Duration get duration => end - start;
}

class ChapterSuggestion {
  final Duration position;
  final String title;
  final double confidence;

  const ChapterSuggestion({
    required this.position,
    required this.title,
    required this.confidence,
  });
}

class BrollSuggestion {
  final Duration position;
  final String prompt;
  final String sourceText;

  const BrollSuggestion({
    required this.position,
    required this.prompt,
    required this.sourceText,
  });
}

class SocialLaunchPack {
  final List<String> titles;
  final List<String> hooks;
  final String description;
  final List<String> hashtags;

  const SocialLaunchPack({
    required this.titles,
    required this.hooks,
    required this.description,
    required this.hashtags,
  });

  String get asPlainText {
    return [
      'TITLE IDEAS',
      ...titles.map((title) => '• $title'),
      '',
      'HOOKS',
      ...hooks.map((hook) => '• $hook'),
      '',
      'DESCRIPTION',
      description,
      '',
      hashtags.join(' '),
    ].join('\n');
  }
}

/// Offline, deterministic caption tooling used by Creator Lab.
///
/// The service intentionally does not make network calls. Every transform
/// returns a new list and leaves the editor's current state untouched until
/// the user explicitly applies it.
class CaptionStudioService {
  CaptionStudioService._();

  static const Set<String> _fillerPhrases = {
    'you know',
    'i mean',
    'kind of',
    'sort of',
    'um',
    'uh',
    'erm',
    'hmm',
  };

  static const Set<String> _soundCueWords = {
    'music',
    'applause',
    'laughter',
    'laughs',
    'silence',
    'noise',
    'inaudible',
    'crosstalk',
    'cheering',
    'sighs',
  };

  static const Set<String> _hookWords = {
    'secret',
    'truth',
    'mistake',
    'warning',
    'never',
    'always',
    'best',
    'worst',
    'biggest',
    'stop',
    'imagine',
    'surprising',
    'finally',
    'proven',
    'why',
    'how',
    'nobody',
    'everyone',
  };

  static const Set<String> _energyWords = {
    'amazing',
    'crazy',
    'huge',
    'massive',
    'incredible',
    'impossible',
    'love',
    'win',
    'powerful',
    'breakthrough',
    'wow',
  };

  static const Set<String> _stopWords = {
    'about',
    'after',
    'again',
    'also',
    'and',
    'are',
    'because',
    'been',
    'before',
    'being',
    'but',
    'can',
    'could',
    'did',
    'does',
    'doing',
    'for',
    'from',
    'get',
    'give',
    'had',
    'has',
    'have',
    'here',
    'how',
    'into',
    'its',
    'just',
    'like',
    'more',
    'most',
    'not',
    'now',
    'of',
    'off',
    'on',
    'one',
    'only',
    'or',
    'our',
    'out',
    'really',
    'said',
    'should',
    'some',
    'than',
    'that',
    'the',
    'their',
    'them',
    'then',
    'there',
    'these',
    'they',
    'this',
    'those',
    'through',
    'to',
    'too',
    'up',
    'very',
    'was',
    'we',
    'were',
    'what',
    'when',
    'where',
    'which',
    'who',
    'why',
    'will',
    'with',
    'would',
    'you',
    'your',
  };

  static CaptionTransformResult balanceLines(
    List<SubtitleEntry> entries, {
    int maximumLineLength = 38,
  }) {
    final transformed = entries
        .map(
          (entry) =>
              entry.copyWith(text: _balanceText(entry.text, maximumLineLength)),
        )
        .toList();
    return _result(
      entries,
      transformed,
      'Balanced caption lines for mobile-safe reading.',
    );
  }

  static CaptionTransformResult retimeForReadingSpeed(
    List<SubtitleEntry> entries, {
    double targetCharactersPerSecond = 17,
    Duration minimumDuration = const Duration(milliseconds: 800),
    Duration maximumDuration = const Duration(seconds: 6),
    Duration minimumGap = const Duration(milliseconds: 80),
    Duration? projectDuration,
  }) {
    if (targetCharactersPerSecond <= 0) {
      throw ArgumentError.value(
        targetCharactersPerSecond,
        'targetCharactersPerSecond',
        'Must be greater than zero.',
      );
    }
    final sorted = _sorted(entries);
    final transformed = <SubtitleEntry>[];

    for (var index = 0; index < sorted.length; index++) {
      final entry = sorted[index];
      final characterCount = _readableCharacterCount(entry.text);
      final desiredMs = ((characterCount / targetCharactersPerSecond) * 1000)
          .round()
          .clamp(
            minimumDuration.inMilliseconds,
            maximumDuration.inMilliseconds,
          );
      var end = entry.startTime + Duration(milliseconds: desiredMs);
      if (index < sorted.length - 1) {
        final latestEnd = sorted[index + 1].startTime - minimumGap;
        if (end > latestEnd) end = latestEnd;
      }
      final durationLimit = projectDuration;
      if (durationLimit != null && end > durationLimit) {
        end = durationLimit;
      }
      if (end <= entry.startTime) {
        end = entry.startTime + const Duration(milliseconds: 100);
      }
      transformed.add(_retimedEntry(entry, entry.startTime, end));
    }

    return _result(
      entries,
      transformed,
      'Retimed captions to a ${targetCharactersPerSecond.toStringAsFixed(0)} CPS reading target.',
    );
  }

  static CaptionTransformResult splitLongCues(
    List<SubtitleEntry> entries, {
    int maximumCharacters = 72,
  }) {
    if (maximumCharacters < 12) {
      throw ArgumentError.value(
        maximumCharacters,
        'maximumCharacters',
        'Must be at least 12.',
      );
    }
    final transformed = <SubtitleEntry>[];
    for (final entry in _sorted(entries)) {
      final normalized = _normalizeWhitespace(entry.text);
      final chunks = _chunkText(normalized, maximumCharacters);
      if (chunks.length <= 1) {
        transformed.add(entry);
        continue;
      }

      final totalWeight = chunks.fold<int>(
        0,
        (sum, chunk) => sum + math.max(1, _readableCharacterCount(chunk)),
      );
      var consumedWeight = 0;
      for (var index = 0; index < chunks.length; index++) {
        final chunk = chunks[index];
        final chunkStart = index == 0
            ? entry.startTime
            : entry.startTime +
                  Duration(
                    milliseconds:
                        (entry.duration.inMilliseconds *
                                (consumedWeight / totalWeight))
                            .round(),
                  );
        consumedWeight += math.max(1, _readableCharacterCount(chunk));
        final chunkEnd = index == chunks.length - 1
            ? entry.endTime
            : entry.startTime +
                  Duration(
                    milliseconds:
                        (entry.duration.inMilliseconds *
                                (consumedWeight / totalWeight))
                            .round(),
                  );
        transformed.add(
          SubtitleEntry(
            id: index == 0 ? entry.id : null,
            startTime: chunkStart,
            endTime: chunkEnd <= chunkStart
                ? chunkStart + const Duration(milliseconds: 100)
                : chunkEnd,
            text: chunk,
            styleOverride: entry.styleOverride,
            confidenceScore: entry.confidenceScore,
            words: _synthesizedWords(chunk, chunkStart, chunkEnd),
          ),
        );
      }
    }
    return _result(
      entries,
      transformed,
      'Split long captions into concise, evenly timed cues.',
    );
  }

  static CaptionTransformResult mergeShortCues(
    List<SubtitleEntry> entries, {
    int shortCueCharacters = 26,
    int maximumMergedCharacters = 72,
    Duration maximumGap = const Duration(milliseconds: 300),
  }) {
    final sorted = _sorted(entries);
    final transformed = <SubtitleEntry>[];
    var index = 0;
    while (index < sorted.length) {
      var current = sorted[index];
      while (index + 1 < sorted.length) {
        final next = sorted[index + 1];
        final gap = next.startTime - current.endTime;
        final joinedText = _joinSentences(current.text, next.text);
        final oneIsShort =
            _readableCharacterCount(current.text) <= shortCueCharacters ||
            _readableCharacterCount(next.text) <= shortCueCharacters;
        if (!oneIsShort ||
            gap < Duration.zero ||
            gap > maximumGap ||
            _readableCharacterCount(joinedText) > maximumMergedCharacters) {
          break;
        }
        current = SubtitleEntry(
          id: current.id,
          startTime: current.startTime,
          endTime: next.endTime,
          text: joinedText,
          styleOverride: current.styleOverride,
          confidenceScore: (current.confidenceScore + next.confidenceScore) / 2,
          words: current.words != null && next.words != null
              ? [...current.words!, ...next.words!]
              : null,
        );
        index++;
      }
      transformed.add(current);
      index++;
    }
    return _result(
      entries,
      transformed,
      'Merged short neighboring captions without crossing long pauses.',
    );
  }

  static CaptionTransformResult removeFillerWords(List<SubtitleEntry> entries) {
    final phrases = _fillerPhrases.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final expression = RegExp(
      r'(?<![\w])(?:' +
          phrases.map(RegExp.escape).join('|') +
          r')(?![\w])[, ]*',
      caseSensitive: false,
    );
    final transformed = entries.map((entry) {
      final cleaned = _cleanAfterRemoval(entry.text.replaceAll(expression, ''));
      return entry.copyWith(text: cleaned, clearWords: cleaned != entry.text);
    }).toList();
    return _result(
      entries,
      transformed,
      'Removed safe filler phrases such as “um”, “uh”, and “you know”.',
    );
  }

  static CaptionTransformResult removeRepeatedWords(
    List<SubtitleEntry> entries,
  ) {
    final transformed = entries.map((entry) {
      final tokens = _normalizeWhitespace(entry.text).split(' ');
      final kept = <String>[];
      String? previousCanonical;
      for (final token in tokens) {
        final canonical = token.toLowerCase().replaceAll(
          RegExp(r"[^a-z0-9']"),
          '',
        );
        if (canonical.isNotEmpty && canonical == previousCanonical) {
          continue;
        }
        kept.add(token);
        if (canonical.isNotEmpty) previousCanonical = canonical;
      }
      final cleaned = kept.join(' ');
      return entry.copyWith(text: cleaned, clearWords: cleaned != entry.text);
    }).toList();
    return _result(
      entries,
      transformed,
      'Removed accidental consecutive word echoes.',
    );
  }

  static CaptionTransformResult polishPunctuation(List<SubtitleEntry> entries) {
    final transformed = entries.map((entry) {
      var text = _normalizeWhitespace(entry.text);
      if (text.isEmpty) return entry;
      text = text.replaceFirstMapped(
        RegExp(r'[A-Za-z]'),
        (match) => match.group(0)!.toUpperCase(),
      );
      if (!RegExp(r'''[.!?…]["']?$''').hasMatch(text)) {
        final withoutLabel = stripSpeakerLabel(text).toLowerCase();
        final isQuestion = RegExp(
          r'^(who|what|when|where|why|how|can|could|would|will|do|does|did|is|are|should)\b',
        ).hasMatch(withoutLabel);
        text = '$text${isQuestion ? '?' : '.'}';
      }
      return entry.copyWith(text: text);
    }).toList();
    return _result(
      entries,
      transformed,
      'Restored sentence casing and terminal punctuation.',
    );
  }

  static CaptionTransformResult snapToFrameGrid(
    List<SubtitleEntry> entries, {
    double framesPerSecond = 30,
  }) {
    if (framesPerSecond <= 0) {
      throw ArgumentError.value(
        framesPerSecond,
        'framesPerSecond',
        'Must be greater than zero.',
      );
    }
    final frameMs = 1000 / framesPerSecond;
    final sorted = _sorted(entries);
    final snappedStarts = sorted
        .map(
          (entry) => Duration(
            milliseconds:
                ((entry.startTime.inMilliseconds / frameMs).round() * frameMs)
                    .round(),
          ),
        )
        .toList();
    final transformed = <SubtitleEntry>[];
    for (var index = 0; index < sorted.length; index++) {
      final entry = sorted[index];
      final start = snappedStarts[index];
      var end = Duration(
        milliseconds:
            ((entry.endTime.inMilliseconds / frameMs).round() * frameMs)
                .round(),
      );
      if (index < sorted.length - 1 && end > snappedStarts[index + 1]) {
        end = snappedStarts[index + 1];
      }
      if (end <= start) {
        end = start + Duration(milliseconds: math.max(1, frameMs.round()));
      }
      transformed.add(_retimedEntry(entry, start, end));
    }
    return _result(
      entries,
      transformed,
      'Snapped caption boundaries to ${framesPerSecond.toStringAsFixed(0)} fps.',
    );
  }

  static CaptionTransformResult removeEmptyCues(List<SubtitleEntry> entries) {
    final transformed = entries
        .where((entry) => entry.text.trim().isNotEmpty)
        .toList();
    return _result(entries, transformed, 'Removed empty caption cues.');
  }

  static CaptionTransformResult removeSoundCues(List<SubtitleEntry> entries) {
    final transformed = entries.where((entry) {
      final normalized = entry.text.trim().toLowerCase().replaceAll(
        RegExp(r'^[\[(♪♫\s]+|[\])♪♫\s]+$'),
        '',
      );
      final words = normalized
          .split(RegExp(r'[^a-z]+'))
          .where((word) => word.isNotEmpty)
          .toSet();
      final isBracketed = RegExp(
        r'^\s*(?:\[.*\]|\(.*\)|♪.*♪|♫.*♫)\s*$',
      ).hasMatch(entry.text);
      return !(isBracketed && words.any(_soundCueWords.contains));
    }).toList();
    return _result(
      entries,
      transformed,
      'Removed standalone music, applause, and ambient sound cues.',
    );
  }

  static CaptionTransformResult maskTerms(
    List<SubtitleEntry> entries,
    Iterable<String> terms, {
    String maskCharacter = '•',
  }) {
    final normalizedTerms =
        terms
            .map((term) => term.trim())
            .where((term) => term.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    if (normalizedTerms.isEmpty) {
      return _result(entries, List.of(entries), 'No sensitive terms supplied.');
    }
    final expression = RegExp(
      r'(?<![\w])(?:' +
          normalizedTerms.map(RegExp.escape).join('|') +
          r')(?![\w])',
      caseSensitive: false,
    );
    final transformed = entries.map((entry) {
      final masked = entry.text.replaceAllMapped(expression, (match) {
        return match
            .group(0)!
            .split('')
            .map(
              (character) =>
                  character.trim().isEmpty ? character : maskCharacter,
            )
            .join();
      });
      return entry.copyWith(text: masked, clearWords: masked != entry.text);
    }).toList();
    return _result(
      entries,
      transformed,
      'Masked selected sensitive terms while preserving word length.',
    );
  }

  static CaptionTransformResult addSpeakerLabels(
    List<SubtitleEntry> entries,
    List<String> speakers, {
    int cuesPerSpeaker = 1,
  }) {
    final names = speakers
        .map((speaker) => speaker.trim())
        .where((speaker) => speaker.isNotEmpty)
        .toList();
    if (names.isEmpty) {
      return _result(entries, List.of(entries), 'No speaker names supplied.');
    }
    final safeGroupSize = math.max(1, cuesPerSpeaker);
    final transformed = _sorted(entries).asMap().entries.map((indexed) {
      final speaker = names[(indexed.key ~/ safeGroupSize) % names.length];
      final text =
          '${speaker.toUpperCase()}: '
          '${stripSpeakerLabel(indexed.value.text)}';
      return indexed.value.copyWith(text: text, clearWords: true);
    }).toList();
    return _result(
      entries,
      transformed,
      'Added alternating speaker labels for ${names.join(', ')}.',
    );
  }

  static CaptionTransformResult stripSpeakerLabelsFromEntries(
    List<SubtitleEntry> entries,
  ) {
    final transformed = entries.map((entry) {
      final stripped = stripSpeakerLabel(entry.text);
      return entry.copyWith(text: stripped, clearWords: stripped != entry.text);
    }).toList();
    return _result(entries, transformed, 'Removed leading speaker labels.');
  }

  static String stripSpeakerLabel(String text) {
    return text
        .replaceFirst(
          RegExp(
            r'''^\s*(?:\[[A-Za-z][\w .'-]{0,24}\]|[A-Za-z][\w .'-]{0,24}:)\s*''',
          ),
          '',
        )
        .trim();
  }

  static CaptionTransformResult applyGlossary(
    List<SubtitleEntry> entries,
    Map<String, String> replacements,
  ) {
    final terms =
        replacements.entries
            .where(
              (replacement) =>
                  replacement.key.trim().isNotEmpty &&
                  replacement.value.trim().isNotEmpty,
            )
            .toList()
          ..sort((a, b) => b.key.length.compareTo(a.key.length));
    final transformed = entries.map((entry) {
      var text = entry.text;
      for (final replacement in terms) {
        text = text.replaceAll(
          RegExp(
            r'(?<![\w])' + RegExp.escape(replacement.key.trim()) + r'(?![\w])',
            caseSensitive: false,
          ),
          replacement.value.trim(),
        );
      }
      return entry.copyWith(text: text, clearWords: text != entry.text);
    }).toList();
    return _result(
      entries,
      transformed,
      'Applied ${terms.length} glossary corrections consistently.',
    );
  }

  static CaptionTransformResult addTimingPadding(
    List<SubtitleEntry> entries, {
    Duration leadIn = const Duration(milliseconds: 100),
    Duration trailOut = const Duration(milliseconds: 140),
    Duration minimumGap = const Duration(milliseconds: 40),
    Duration? projectDuration,
  }) {
    final sorted = _sorted(entries);
    final starts = sorted.map((entry) {
      final candidate = entry.startTime - leadIn;
      return candidate < Duration.zero ? Duration.zero : candidate;
    }).toList();
    final ends = sorted.map((entry) {
      final candidate = entry.endTime + trailOut;
      if (projectDuration != null && candidate > projectDuration) {
        return projectDuration;
      }
      return candidate;
    }).toList();

    for (var index = 0; index < sorted.length - 1; index++) {
      if (ends[index] + minimumGap <= starts[index + 1]) continue;
      final midpointMs =
          (sorted[index].endTime.inMilliseconds +
              sorted[index + 1].startTime.inMilliseconds) ~/
          2;
      final leftGapMs = minimumGap.inMilliseconds ~/ 2;
      final rightGapMs = minimumGap.inMilliseconds - leftGapMs;
      ends[index] = Duration(milliseconds: midpointMs - leftGapMs);
      starts[index + 1] = Duration(milliseconds: midpointMs + rightGapMs);
    }

    final transformed = <SubtitleEntry>[];
    for (var index = 0; index < sorted.length; index++) {
      final entry = sorted[index];
      var start = starts[index];
      var end = ends[index];
      if (end <= start) {
        start = entry.startTime;
        end = entry.endTime;
      }
      transformed.add(_retimedEntry(entry, start, end));
    }
    return _result(
      entries,
      transformed,
      'Added natural lead-in and breathing room around each caption.',
    );
  }

  static List<CaptionPaceMetric> analyzePace(List<SubtitleEntry> entries) {
    return _sorted(entries).map((entry) {
      final seconds = math.max(0.1, entry.duration.inMilliseconds / 1000);
      final cps = _readableCharacterCount(entry.text) / seconds;
      final words = _words(entry.text).length;
      final wpm = words / seconds * 60;
      final band = switch (cps) {
        < 9 => CaptionPaceBand.slow,
        <= 20 => CaptionPaceBand.balanced,
        <= 26 => CaptionPaceBand.fast,
        _ => CaptionPaceBand.extreme,
      };
      return CaptionPaceMetric(
        entry: entry,
        charactersPerSecond: cps,
        wordsPerMinute: wpm,
        band: band,
      );
    }).toList();
  }

  /// Scores short transcript windows for strong hooks and shareable moments.
  static List<ViralMoment> findViralMoments(
    List<SubtitleEntry> entries, {
    int maximumMoments = 5,
    Duration targetWindow = const Duration(seconds: 12),
  }) {
    final sorted = _sorted(entries);
    if (sorted.isEmpty) return const [];
    final candidates = <ViralMoment>[];

    for (var startIndex = 0; startIndex < sorted.length; startIndex++) {
      final window = <SubtitleEntry>[];
      for (var index = startIndex; index < sorted.length; index++) {
        final candidate = sorted[index];
        if (candidate.endTime - sorted[startIndex].startTime > targetWindow &&
            window.isNotEmpty) {
          break;
        }
        window.add(candidate);
      }
      if (window.isEmpty) continue;

      final text = window.map((entry) => entry.text).join(' ');
      final lower = text.toLowerCase();
      final words = _words(lower);
      final reasons = <String>[];
      var score = 24.0;

      final hookHits = _hookWords
          .where(
            (word) =>
                RegExp(r'\b' + RegExp.escape(word) + r'\b').hasMatch(lower),
          )
          .length;
      if (hookHits > 0) {
        score += math.min(26, hookHits * 9);
        reasons.add('$hookHits hook phrase${hookHits == 1 ? '' : 's'}');
      }
      if (text.contains('?')) {
        score += 12;
        reasons.add('curiosity question');
      }
      if (text.contains('!')) {
        score += 8;
        reasons.add('high energy');
      }
      if (RegExp(r'\b\d+(?:\.\d+)?%?\b').hasMatch(text)) {
        score += 8;
        reasons.add('specific number');
      }
      if (RegExp(r'\b(you|your)\b', caseSensitive: false).hasMatch(text)) {
        score += 7;
        reasons.add('direct audience address');
      }
      final durationSeconds = math.max(
        0.1,
        (window.last.endTime - window.first.startTime).inMilliseconds / 1000,
      );
      final cps = _readableCharacterCount(text) / durationSeconds;
      if (cps >= 11 && cps <= 22) {
        score += 10;
        reasons.add('strong speaking pace');
      }
      final uniqueRatio = words.isEmpty
          ? 0
          : words.toSet().length / words.length;
      score += uniqueRatio * 8;
      final averageConfidence =
          window.fold<double>(0, (sum, entry) => sum + entry.confidenceScore) /
          window.length;
      score += averageConfidence * 6;

      candidates.add(
        ViralMoment(
          start: window.first.startTime,
          end: window.last.endTime,
          score: score.round().clamp(0, 100),
          snippet: _ellipsize(_normalizeWhitespace(text), 150),
          reasons: reasons.isEmpty
              ? const ['clear standalone thought']
              : reasons,
        ),
      );
    }

    candidates.sort((a, b) => b.score.compareTo(a.score));
    final selected = <ViralMoment>[];
    for (final candidate in candidates) {
      final overlaps = selected.any(
        (existing) =>
            candidate.start < existing.end && candidate.end > existing.start,
      );
      if (!overlaps) selected.add(candidate);
      if (selected.length >= maximumMoments) break;
    }
    selected.sort((a, b) => a.start.compareTo(b.start));
    return selected;
  }

  static List<ChapterSuggestion> generateChapters(
    List<SubtitleEntry> entries, {
    Duration maximumChapterLength = const Duration(seconds: 75),
    Duration pauseBoundary = const Duration(seconds: 4),
  }) {
    final sorted = _sorted(entries);
    if (sorted.isEmpty) return const [];
    final groups = <List<SubtitleEntry>>[];
    var current = <SubtitleEntry>[];

    for (final entry in sorted) {
      final shouldBreak =
          current.isNotEmpty &&
          (entry.startTime - current.last.endTime >= pauseBoundary ||
              entry.startTime - current.first.startTime >=
                  maximumChapterLength);
      if (shouldBreak) {
        groups.add(current);
        current = <SubtitleEntry>[];
      }
      current.add(entry);
    }
    if (current.isNotEmpty) groups.add(current);

    return groups.asMap().entries.map((indexed) {
      final group = indexed.value;
      final text = group.map((entry) => entry.text).join(' ');
      final keywords = _topKeywords(text, count: 2);
      final title = keywords.isEmpty
          ? 'Chapter ${indexed.key + 1}'
          : keywords.map(_titleWord).join(' & ');
      final confidence = (0.58 + math.min(0.32, group.length * 0.035)).clamp(
        0.0,
        0.95,
      );
      return ChapterSuggestion(
        position: group.first.startTime,
        title: title,
        confidence: confidence,
      );
    }).toList();
  }

  static CaptionTransformResult directKineticCaptions(
    List<SubtitleEntry> entries, {
    required SubtitleStyleModel globalStyle,
  }) {
    final transformed = entries.map((entry) {
      final lower = entry.text.toLowerCase();
      final hasEnergy =
          entry.text.contains('!') ||
          _energyWords.any(
            (word) =>
                RegExp(r'\b' + RegExp.escape(word) + r'\b').hasMatch(lower),
          );
      final base = entry.styleOverride ?? globalStyle;
      final SubtitleAnimationPreset animation;
      final Color color;
      final bool bold;
      if (hasEnergy) {
        animation = SubtitleAnimationPreset.wordPop;
        color = const Color(0xFFC7F36B);
        bold = true;
      } else if (entry.text.contains('?')) {
        animation = SubtitleAnimationPreset.typewriter;
        color = const Color(0xFF72C7EA);
        bold = base.isBold;
      } else if (entry.words?.isNotEmpty == true) {
        animation = SubtitleAnimationPreset.karaokeHighlight;
        color = base.textColor;
        bold = base.isBold;
      } else if (_readableCharacterCount(entry.text) > 62) {
        animation = SubtitleAnimationPreset.lineFade;
        color = base.textColor;
        bold = base.isBold;
      } else {
        animation = SubtitleAnimationPreset.wordSlideUp;
        color = base.textColor;
        bold = base.isBold;
      }
      return entry.copyWith(
        styleOverride: base.copyWith(
          animationPreset: animation,
          textColor: color,
          isBold: bold,
        ),
      );
    }).toList();
    return _result(
      entries,
      transformed,
      'Directed animation, emphasis, and color cue-by-cue.',
    );
  }

  static List<BrollSuggestion> generateBrollStoryboard(
    List<SubtitleEntry> entries, {
    int maximumSuggestions = 8,
    Duration minimumSpacing = const Duration(seconds: 8),
  }) {
    final sorted = _sorted(entries);
    final suggestions = <BrollSuggestion>[];
    final usedPrompts = <String>{};
    Duration? lastPosition;

    for (final entry in sorted) {
      if (lastPosition != null &&
          entry.startTime - lastPosition < minimumSpacing) {
        continue;
      }
      final keywords = _topKeywords(entry.text, count: 3);
      if (keywords.isEmpty) continue;
      final subject = keywords.map(_titleWord).join(' ');
      final prompt =
          'Cinematic ${subject.toLowerCase()} detail, natural motion, '
          'editorial lighting, vertical-safe composition';
      if (!usedPrompts.add(prompt)) continue;
      suggestions.add(
        BrollSuggestion(
          position: entry.startTime,
          prompt: prompt,
          sourceText: _ellipsize(_normalizeWhitespace(entry.text), 100),
        ),
      );
      lastPosition = entry.startTime;
      if (suggestions.length >= maximumSuggestions) break;
    }
    return suggestions;
  }

  static SocialLaunchPack generateSocialLaunchPack(
    List<SubtitleEntry> entries, {
    required String projectName,
  }) {
    final transcript = entries.map((entry) => entry.text).join(' ');
    final keywords = _topKeywords(transcript, count: 6);
    final subject = keywords.isEmpty
        ? projectName.trim()
        : keywords.take(2).map(_titleWord).join(' ');
    final safeProjectName = projectName.trim().isEmpty
        ? 'New video'
        : projectName.trim();
    final moments = findViralMoments(entries, maximumMoments: 2);
    final firstThought = entries.isEmpty
        ? 'A fresh story worth sharing.'
        : _ellipsize(_normalizeWhitespace(entries.first.text), 100);

    final titles = <String>[
      '$safeProjectName — $subject',
      'The truth about $subject',
      '$subject: what nobody tells you',
    ];
    final hooks = <String>[
      if (moments.isNotEmpty) moments.first.snippet,
      'Before you scroll: here is what changes everything about $subject.',
      'Most people miss this one detail about $subject.',
    ].take(3).toList();
    final description =
        '$firstThought\n\n'
        'A concise breakdown of ${subject.toLowerCase()}, with the key ideas '
        'and moments you can put into action.';
    final hashtagWords = <String>{
      ...keywords.take(6).map(_hashtag),
      '#CaptionCraft',
      '#VideoEditing',
      '#CreatorTips',
    }.where((tag) => tag.length > 1).toList();

    return SocialLaunchPack(
      titles: titles,
      hooks: hooks,
      description: description,
      hashtags: hashtagWords,
    );
  }

  static CaptionTransformResult synthesizeKaraokeTimings(
    List<SubtitleEntry> entries, {
    bool overwriteExisting = false,
  }) {
    final transformed = entries.map((entry) {
      if (!overwriteExisting && entry.words?.isNotEmpty == true) return entry;
      final words = _synthesizedWords(
        entry.text,
        entry.startTime,
        entry.endTime,
      );
      return entry.copyWith(words: words);
    }).toList();
    return _result(
      entries,
      transformed,
      'Generated word-level timing for karaoke and kinetic animations.',
    );
  }

  static CaptionTransformResult _result(
    List<SubtitleEntry> original,
    List<SubtitleEntry> transformed,
    String summary,
  ) {
    final originalById = {for (final entry in original) entry.id: entry};
    final transformedIds = transformed.map((entry) => entry.id).toSet();
    var changed = original
        .where((entry) => !transformedIds.contains(entry.id))
        .length;
    for (final entry in transformed) {
      final previous = originalById[entry.id];
      if (previous == null ||
          jsonEncode(previous.toJson()) != jsonEncode(entry.toJson())) {
        changed++;
      }
    }
    return CaptionTransformResult(
      entries: transformed,
      changedCount: changed,
      summary: summary,
    );
  }

  static List<SubtitleEntry> _sorted(List<SubtitleEntry> entries) {
    return List<SubtitleEntry>.from(entries)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  static SubtitleEntry _retimedEntry(
    SubtitleEntry entry,
    Duration start,
    Duration end,
  ) {
    final oldDurationMs = math.max(1, entry.duration.inMilliseconds);
    final newDurationMs = math.max(1, (end - start).inMilliseconds);
    final remappedWords = entry.words?.map((word) {
      final startRatio =
          (word.startTime - entry.startTime).inMilliseconds / oldDurationMs;
      final endRatio =
          (word.endTime - entry.startTime).inMilliseconds / oldDurationMs;
      return WordTiming(
        word: word.word,
        startTime:
            start +
            Duration(
              milliseconds: (newDurationMs * startRatio.clamp(0, 1)).round(),
            ),
        endTime:
            start +
            Duration(
              milliseconds: (newDurationMs * endRatio.clamp(0, 1)).round(),
            ),
      );
    }).toList();
    return entry.copyWith(startTime: start, endTime: end, words: remappedWords);
  }

  static List<WordTiming> _synthesizedWords(
    String text,
    Duration start,
    Duration end,
  ) {
    final tokens = _normalizeWhitespace(
      text,
    ).split(' ').where((token) => token.isNotEmpty).toList();
    if (tokens.isEmpty || end <= start) return const [];
    final weights = tokens
        .map(
          (token) =>
              math.max(1, token.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').length),
        )
        .toList();
    final totalWeight = weights.fold<int>(0, (sum, weight) => sum + weight);
    final durationMs = (end - start).inMilliseconds;
    var consumedWeight = 0;
    return tokens.asMap().entries.map((indexed) {
      final wordStart =
          start +
          Duration(
            milliseconds: (durationMs * (consumedWeight / totalWeight)).round(),
          );
      consumedWeight += weights[indexed.key];
      final wordEnd = indexed.key == tokens.length - 1
          ? end
          : start +
                Duration(
                  milliseconds: (durationMs * (consumedWeight / totalWeight))
                      .round(),
                );
      return WordTiming(
        word: indexed.value,
        startTime: wordStart,
        endTime: wordEnd,
      );
    }).toList();
  }

  static String _balanceText(String text, int maximumLineLength) {
    final normalized = _normalizeWhitespace(text);
    if (normalized.length <= maximumLineLength) return normalized;
    final words = normalized.split(' ');
    if (words.length < 2) return normalized;

    var bestIndex = 1;
    var bestCost = double.infinity;
    for (var index = 1; index < words.length; index++) {
      final firstLength = words.take(index).join(' ').length;
      final secondLength = words.skip(index).join(' ').length;
      final overflow =
          math.max(0, firstLength - maximumLineLength) +
          math.max(0, secondLength - maximumLineLength);
      final balance = (firstLength - secondLength).abs();
      final cost = overflow * 1000 + balance;
      if (cost < bestCost) {
        bestCost = cost.toDouble();
        bestIndex = index;
      }
    }
    return '${words.take(bestIndex).join(' ')}\n'
        '${words.skip(bestIndex).join(' ')}';
  }

  static List<String> _chunkText(String text, int maximumCharacters) {
    if (text.length <= maximumCharacters) return [text];
    final words = text.split(' ');
    final chunks = <String>[];
    var current = <String>[];
    for (final word in words) {
      final candidate = [...current, word].join(' ');
      if (current.isNotEmpty && candidate.length > maximumCharacters) {
        chunks.add(current.join(' '));
        current = [word];
      } else {
        current.add(word);
      }
    }
    if (current.isNotEmpty) chunks.add(current.join(' '));
    return chunks;
  }

  static String _joinSentences(String first, String second) {
    final left = _normalizeWhitespace(first);
    final right = _normalizeWhitespace(second);
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    return '$left $right';
  }

  static String _normalizeWhitespace(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _cleanAfterRemoval(String text) {
    var cleaned = text
        .replaceAllMapped(RegExp(r'\s+([,.;!?])'), (match) => match.group(1)!)
        .replaceAll(RegExp(r',\s*,'), ',')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    cleaned = cleaned.replaceFirst(RegExp(r'^[,;:\-]\s*'), '');
    return cleaned;
  }

  static int _readableCharacterCount(String text) {
    return _normalizeWhitespace(text).length;
  }

  static List<String> _words(String text) {
    return RegExp(
      r"[A-Za-z0-9][A-Za-z0-9'-]*",
    ).allMatches(text).map((match) => match.group(0)!.toLowerCase()).toList();
  }

  static List<String> _topKeywords(String text, {required int count}) {
    final frequency = <String, int>{};
    for (final word in _words(text)) {
      if (word.length < 3 ||
          _stopWords.contains(word) ||
          RegExp(r'^\d+$').hasMatch(word)) {
        continue;
      }
      frequency[word] = (frequency[word] ?? 0) + 1;
    }
    final ranked = frequency.entries.toList()
      ..sort((a, b) {
        final frequencyOrder = b.value.compareTo(a.value);
        if (frequencyOrder != 0) return frequencyOrder;
        final lengthOrder = b.key.length.compareTo(a.key.length);
        if (lengthOrder != 0) return lengthOrder;
        return a.key.compareTo(b.key);
      });
    return ranked.take(count).map((entry) => entry.key).toList();
  }

  static String _titleWord(String word) {
    if (word.isEmpty) return word;
    return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
  }

  static String _hashtag(String word) {
    final cleaned = word.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return cleaned.isEmpty ? '' : '#${_titleWord(cleaned)}';
  }

  static String _ellipsize(String text, int maximumLength) {
    if (text.length <= maximumLength) return text;
    final clipped = text.substring(0, maximumLength - 1);
    final boundary = clipped.lastIndexOf(' ');
    return '${clipped.substring(0, boundary > 30 ? boundary : clipped.length)}…';
  }
}
