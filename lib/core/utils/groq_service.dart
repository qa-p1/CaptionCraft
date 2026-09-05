import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../constants/groq_constants.dart';
import 'api_key_vault.dart';
import '../../features/editor/models/subtitle_entry.dart';
import '../../features/editor/models/word_timing.dart';

/// Service for calling Groq's Whisper API for audio transcription.
class GroqService {
  GroqService._();

  static bool get isConfigured => GroqConstants.apiKey.isNotEmpty;

  static void ensureConfigured() {
    if (!isConfigured) {
      throw Exception(
        'Add your Groq API key in Settings → Connected services to generate captions. Manual captions and editing remain available.',
      );
    }
  }

  static final Dio _dio = Dio(
    BaseOptions(
      followRedirects: false,
      connectTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 120),
      receiveTimeout: const Duration(seconds: 120),
    ),
  );

  /// Transcribe a single audio chunk and return a list of WordTiming.
  /// [chunkStartOffset] is added to all word timestamps for multi-chunk alignment.
  static Future<List<WordTiming>> transcribeChunk({
    required File audioChunk,
    required int chunkIndex,
    required Duration chunkStartOffset,
    String language = '',
    CancelToken? cancelToken,
  }) async {
    ensureConfigured();
    final apiKey = GroqConstants.apiKey;
    final vault = ApiKeys.active;
    final endpoint = Uri.parse(
      '${GroqConstants.baseUrl}${GroqConstants.transcriptionsEndpoint}',
    );
    final requestHeaders = {'Authorization': 'Bearer $apiKey'};
    final effectiveCancelToken = cancelToken ?? CancelToken();

    if (!await audioChunk.exists()) {
      throw Exception('Audio chunk ${audioChunk.path} was not created.');
    }

    final chunkBytes = await audioChunk.length();
    if (chunkBytes == 0) {
      throw Exception('Audio chunk ${audioChunk.path} is empty.');
    }
    if (chunkBytes > GroqConstants.maxChunkBytes) {
      throw Exception(
        'Audio chunk ${(chunkBytes / 1024 / 1024).toStringAsFixed(1)} MB '
        'exceeds the configured Groq upload limit.',
      );
    }

    int retries = 0;
    const maxRetries = 3;

    while (retries < maxRetries) {
      try {
        if (vault?.isRetired == true || !identical(vault, ApiKeys.active)) {
          throw Exception('Account changed. Start transcription again.');
        }
        final formData = FormData.fromMap({
          'file': await MultipartFile.fromFile(
            audioChunk.path,
            filename: 'chunk_$chunkIndex${_extension(audioChunk.path)}',
          ),
          'model': GroqConstants.model,
          'response_format': 'verbose_json',
          'timestamp_granularities[]': 'word',
          'temperature': 0,
          if (language.isNotEmpty) 'language': language,
        });

        if (kDebugMode) {
          debugPrint(
            '[Transcription] POST provider '
            'chunk=$chunkIndex size=${(chunkBytes / 1024 / 1024).toStringAsFixed(2)}MB',
          );
        }

        final response = await _dio
            .postUri(
              endpoint,
              data: formData,
              cancelToken: effectiveCancelToken,
              options: Options(headers: requestHeaders),
            )
            .timeout(const Duration(minutes: 4));

        if (kDebugMode) {
          debugPrint(
            '[Transcription] Response ${response.statusCode} for chunk=$chunkIndex',
          );
        }

        return parseWordsResponse(response.data, chunkStartOffset);
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          throw Exception('Transcription cancelled.');
        }
        if (e.response?.statusCode == 429) {
          // Rate limited — exponential backoff
          retries++;
          if (retries < maxRetries) {
            await _waitForRetry(
              Duration(seconds: 1 << retries),
              effectiveCancelToken,
            );
            continue;
          }
        }
        if (retries == 0 && e.type == DioExceptionType.connectionError) {
          // Retry once on network error
          retries++;
          await _waitForRetry(const Duration(seconds: 2), effectiveCancelToken);
          continue;
        }
        throw Exception(_formatDioError(e));
      } on TimeoutException {
        if (!effectiveCancelToken.isCancelled) {
          effectiveCancelToken.cancel('Transcription request timed out.');
        }
        throw Exception(
          'Transcription timed out for chunk ${chunkIndex + 1}. Check the connection and try again.',
        );
      }
    }

    throw Exception(
      'Transcription failed after $maxRetries retries for chunk $chunkIndex',
    );
  }

  /// Parse Groq's verbose_json response into validated word timings.
  static List<WordTiming> parseWordsResponse(
    dynamic responseData,
    Duration offset,
  ) {
    final dynamic decoded = responseData is String
        ? jsonDecode(responseData)
        : responseData;
    if (decoded is! Map) {
      throw const FormatException('Groq returned an invalid response body.');
    }
    final data = Map<String, dynamic>.from(decoded);
    final words = _extractWordItems(data);
    final timings = <WordTiming>[];

    for (final word in words) {
      final textValue = word['word'] ?? word['text'];
      final text = textValue is String ? textValue.trim() : '';
      final startValue = word['start'];
      final endValue = word['end'];

      if (text.isEmpty || startValue is! num || endValue is! num) continue;

      final startSeconds = startValue.toDouble();
      final endSeconds = endValue.toDouble();
      if (!startSeconds.isFinite || !endSeconds.isFinite) continue;

      final startMs = (max(0.0, startSeconds) * 1000).round();
      final endMs = (max(0.0, endSeconds) * 1000).round();
      if (endMs <= startMs) continue;

      timings.add(
        WordTiming(
          word: text,
          startTime: Duration(milliseconds: startMs) + offset,
          endTime: Duration(milliseconds: endMs) + offset,
        ),
      );
    }

    timings.sort((a, b) => a.startTime.compareTo(b.startTime));
    return timings;
  }

  static List<Map<String, dynamic>> _extractWordItems(
    Map<String, dynamic> data,
  ) {
    final topLevelWords = data['words'];
    if (topLevelWords is List) {
      return topLevelWords
          .whereType<Map>()
          .map((word) => Map<String, dynamic>.from(word))
          .toList();
    }

    final segments = data['segments'];
    if (segments is! List) return const [];

    final words = <Map<String, dynamic>>[];
    for (final segment in segments.whereType<Map>()) {
      final segmentWords = segment['words'];
      if (segmentWords is List) {
        words.addAll(
          segmentWords.whereType<Map>().map(
            (word) => Map<String, dynamic>.from(word),
          ),
        );
        continue;
      }

      final text = segment['text'];
      final start = segment['start'];
      final end = segment['end'];
      if (text is String && start is num && end is num) {
        words.add({'word': text, 'start': start, 'end': end});
      }
    }
    return words;
  }

  /// Group consecutive words into line-level SubtitleEntry blocks.
  /// Rules:
  /// - Group until 4–6 words OR gap > 400ms between words, whichever first.
  /// - Each SubtitleEntry: startTime=first word's start, endTime=last word's end,
  ///   text=all words joined with spaces, words=per-word timing sub-list.
  static List<SubtitleEntry> groupWordsIntoLines(List<WordTiming> allWords) {
    if (allWords.isEmpty) return [];

    final entries = <SubtitleEntry>[];
    var currentGroupWords = <WordTiming>[];

    for (var i = 0; i < allWords.length; i++) {
      currentGroupWords.add(allWords[i]);

      final isLastWord = i == allWords.length - 1;
      final hasEnoughWords = currentGroupWords.length >= 4;
      final hasMaxWords = currentGroupWords.length >= 6;

      // Check for natural pause gap (> 400ms between current word's end and next word's start)
      bool hasGap = false;
      if (!isLastWord) {
        final gapMs =
            allWords[i + 1].startTime.inMilliseconds -
            allWords[i].endTime.inMilliseconds;
        hasGap = gapMs > 400;
      }

      // Decide whether to flush the current group
      if (isLastWord || hasMaxWords || (hasEnoughWords && hasGap)) {
        entries.add(
          SubtitleEntry(
            startTime: currentGroupWords.first.startTime,
            endTime: currentGroupWords.last.endTime,
            text: currentGroupWords.map((w) => w.word).join(' '),
            words: List<WordTiming>.from(currentGroupWords),
          ),
        );
        currentGroupWords = <WordTiming>[];
      }
    }

    return entries;
  }

  /// Deduplicate overlapping entries that arise from chunk overlap.
  static List<SubtitleEntry> deduplicateOverlaps(
    List<SubtitleEntry> allEntries,
  ) {
    if (allEntries.length <= 1) return allEntries;

    // Sort by start time
    allEntries.sort((a, b) => a.startTime.compareTo(b.startTime));

    final deduplicated = <SubtitleEntry>[allEntries.first];
    for (var i = 1; i < allEntries.length; i++) {
      final prev = deduplicated.last;
      final current = allEntries[i];

      // If entries overlap significantly (>50% of shorter duration), skip the later one
      final overlapStart = current.startTime;
      final overlapEnd = prev.endTime.compareTo(current.endTime) < 0
          ? prev.endTime
          : current.endTime;

      if (overlapStart < overlapEnd) {
        final overlapDuration = overlapEnd - overlapStart;
        final shorterDuration = prev.duration.compareTo(current.duration) < 0
            ? prev.duration
            : current.duration;

        if (overlapDuration.inMilliseconds >
            shorterDuration.inMilliseconds * 0.5) {
          // Significant overlap — skip this entry
          continue;
        }
      }

      deduplicated.add(current);
    }

    return deduplicated;
  }

  /// Deduplicate overlapping word timings from chunk overlap.
  static List<WordTiming> deduplicateWordOverlaps(List<WordTiming> allWords) {
    if (allWords.length <= 1) return allWords;

    final sorted = List<WordTiming>.from(allWords)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final deduplicated = <WordTiming>[];

    for (final current in sorted) {
      if (current.endTime <= current.startTime || current.word.trim().isEmpty) {
        continue;
      }

      final normalizedCurrent = _normalizedWord(current.word);
      var isDuplicate = false;
      for (final previous in deduplicated.reversed) {
        final distanceMs =
            current.startTime.inMilliseconds - previous.endTime.inMilliseconds;
        if (distanceMs > 1500) break;
        if (_normalizedWord(previous.word) != normalizedCurrent) continue;

        final overlapStart = current.startTime > previous.startTime
            ? current.startTime
            : previous.startTime;
        final overlapEnd = current.endTime < previous.endTime
            ? current.endTime
            : previous.endTime;
        final overlapMs = (overlapEnd - overlapStart).inMilliseconds.clamp(
          0,
          1 << 30,
        );
        final shorterMs = min(
          (current.endTime - current.startTime).inMilliseconds,
          (previous.endTime - previous.startTime).inMilliseconds,
        ).clamp(1, 1 << 30);
        final startsNearlyMatch =
            (current.startTime.inMilliseconds -
                    previous.startTime.inMilliseconds)
                .abs() <=
            140;
        final endsNearlyMatch =
            (current.endTime.inMilliseconds - previous.endTime.inMilliseconds)
                .abs() <=
            260;

        if (overlapMs / shorterMs >= 0.45 ||
            (startsNearlyMatch && endsNearlyMatch)) {
          isDuplicate = true;
          break;
        }
      }
      if (isDuplicate) continue;

      // Different words may legitimately have slightly overlapping timestamps
      // (rapid speech or multiple speakers), so keep them instead of silently
      // dropping dialogue at an audio-chunk boundary.
      deduplicated.add(current);
    }

    return deduplicated;
  }

  static String _normalizedWord(String word) => word.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]+', unicode: true),
    '',
  );

  static String _extension(String path) {
    final dotIndex = path.lastIndexOf('.');
    return dotIndex != -1 ? path.substring(dotIndex) : '';
  }

  static Future<void> _waitForRetry(
    Duration duration,
    CancelToken cancelToken,
  ) async {
    const pollInterval = Duration(milliseconds: 100);
    var elapsed = Duration.zero;
    while (elapsed < duration) {
      if (cancelToken.isCancelled) {
        throw Exception('Transcription cancelled.');
      }
      final remaining = duration - elapsed;
      final wait = remaining < pollInterval ? remaining : pollInterval;
      await Future<void>.delayed(wait);
      elapsed += wait;
    }
  }

  static String _formatDioError(DioException error) {
    return switch (error.response?.statusCode) {
      401 =>
        'Groq rejected your API key. Update it in Settings → Connected services.',
      403 =>
        'Groq denied this request. Check your provider account permissions.',
      413 => 'This audio chunk is too large for the transcription service.',
      429 => 'Your Groq account is rate limited. Wait and try again.',
      final int status =>
        'Transcription failed (HTTP $status). Try again later.',
      _ => 'Could not reach Groq. Check your connection and try again.',
    };
  }
}
