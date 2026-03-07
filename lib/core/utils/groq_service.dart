import 'dart:io';
import 'package:dio/dio.dart';
import '../constants/groq_constants.dart';
import '../../features/editor/models/subtitle_entry.dart';
import '../../features/editor/models/word_timing.dart';

/// Service for calling Groq's Whisper API for audio transcription.
class GroqService {
  GroqService._();

  static final Dio _dio = Dio(BaseOptions(
    baseUrl: GroqConstants.baseUrl,
    headers: {
      'Authorization': 'Bearer ${GroqConstants.apiKey}',
    },
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 120),
  ));

  /// Transcribe a single audio chunk and return a list of WordTiming.
  /// [chunkStartOffset] is added to all word timestamps for multi-chunk alignment.
  static Future<List<WordTiming>> transcribeChunk({
    required File audioChunk,
    required int chunkIndex,
    required Duration chunkStartOffset,
    String language = '',
  }) async {
    int retries = 0;
    const maxRetries = 3;

    while (retries < maxRetries) {
      try {
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

        final response = await _dio.post(
          GroqConstants.transcriptionsEndpoint,
          data: formData,
        );

        return _parseWords(response.data, chunkStartOffset);
      } on DioException catch (e) {
        if (e.response?.statusCode == 429) {
          // Rate limited — exponential backoff
          retries++;
          if (retries < maxRetries) {
            await Future.delayed(Duration(seconds: 1 << retries)); // 2s, 4s, 8s
            continue;
          }
        }
        if (retries == 0 && e.type == DioExceptionType.connectionError) {
          // Retry once on network error
          retries++;
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        rethrow;
      }
    }

    throw Exception(
        'Transcription failed after $maxRetries retries for chunk $chunkIndex');
  }

  /// Parse Groq's verbose_json response words array into WordTiming list.
  static List<WordTiming> _parseWords(
    dynamic responseData,
    Duration offset,
  ) {
    final words = responseData['words'] as List<dynamic>? ?? [];
    final timings = <WordTiming>[];

    for (final word in words) {
      final startSec = (word['start'] as num).toDouble();
      final endSec = (word['end'] as num).toDouble();
      final text = (word['word'] as String).trim();

      if (text.isEmpty) continue;

      timings.add(WordTiming(
        word: text,
        startTime: Duration(milliseconds: (startSec * 1000).round()) + offset,
        endTime: Duration(milliseconds: (endSec * 1000).round()) + offset,
      ));
    }

    return timings;
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
        final gapMs = allWords[i + 1].startTime.inMilliseconds -
            allWords[i].endTime.inMilliseconds;
        hasGap = gapMs > 400;
      }

      // Decide whether to flush the current group
      if (isLastWord || hasMaxWords || (hasEnoughWords && hasGap)) {
        entries.add(SubtitleEntry(
          startTime: currentGroupWords.first.startTime,
          endTime: currentGroupWords.last.endTime,
          text: currentGroupWords.map((w) => w.word).join(' '),
          words: List<WordTiming>.from(currentGroupWords),
        ));
        currentGroupWords = <WordTiming>[];
      }
    }

    return entries;
  }

  /// Deduplicate overlapping entries that arise from chunk overlap.
  static List<SubtitleEntry> deduplicateOverlaps(
      List<SubtitleEntry> allEntries) {
    if (allEntries.length <= 1) return allEntries;

    // Sort by start time
    allEntries.sort((a, b) => a.startTime.compareTo(b.startTime));

    final deduplicated = <SubtitleEntry>[allEntries.first];
    for (var i = 1; i < allEntries.length; i++) {
      final prev = deduplicated.last;
      final current = allEntries[i];

      // If entries overlap significantly (>50% of shorter duration), skip the later one
      final overlapStart = current.startTime;
      final overlapEnd =
          prev.endTime.compareTo(current.endTime) < 0
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

    allWords.sort((a, b) => a.startTime.compareTo(b.startTime));

    final deduplicated = <WordTiming>[allWords.first];
    for (var i = 1; i < allWords.length; i++) {
      final prev = deduplicated.last;
      final current = allWords[i];

      // Skip if this word overlaps with the previous one
      if (current.startTime.inMilliseconds < prev.endTime.inMilliseconds) {
        continue;
      }

      deduplicated.add(current);
    }

    return deduplicated;
  }

  static String _extension(String path) {
    final dotIndex = path.lastIndexOf('.');
    return dotIndex != -1 ? path.substring(dotIndex) : '';
  }
}
