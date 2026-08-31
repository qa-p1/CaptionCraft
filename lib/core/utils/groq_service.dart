import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import '../constants/groq_constants.dart';
import 'firebase_service.dart';
import '../../features/editor/models/subtitle_entry.dart';
import '../../features/editor/models/word_timing.dart';

/// Service for calling Groq's Whisper API for audio transcription.
class GroqService {
  GroqService._();

  static bool get isConfigured => GroqConstants.isConfiguredFor(
    proxyUrl: GroqConstants.transcriptionProxyUrl,
    apiKey: GroqConstants.apiKey,
    releaseMode: kReleaseMode,
  );

  /// Fail before media analysis or transcoding when transcription has not
  /// been configured for this build.
  static void ensureConfigured() {
    if (!isConfigured) {
      if (GroqConstants.transcriptionProxyUrl.isNotEmpty &&
          GroqConstants.transcriptionProxyUri == null) {
        throw Exception(
          'The transcription proxy URL is invalid. Production endpoints must use HTTPS without embedded credentials, query parameters, or fragments.',
        );
      }
      throw Exception(
        kReleaseMode
            ? 'Automatic transcription is not configured for this release. Set CAPTIONCRAFT_TRANSCRIPTION_PROXY_URL to an authenticated HTTPS endpoint.'
            : 'Automatic transcription is not configured. Add a local GROQ_API_KEY for development or set CAPTIONCRAFT_TRANSCRIPTION_PROXY_URL.',
      );
    }
  }

  static final Dio _dio = Dio(
    BaseOptions(
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
    final proxyUri = GroqConstants.transcriptionProxyUri;
    final endpoint =
        proxyUri ??
        Uri.parse(
          '${GroqConstants.baseUrl}${GroqConstants.transcriptionsEndpoint}',
        );
    final requestHeaders = await _requestHeaders(
      proxyUri: proxyUri,
      apiKey: apiKey,
    );
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
            '[Transcription] POST ${proxyUri == null ? 'provider' : 'proxy'} '
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
        throw Exception(_formatDioError(e, usesProxy: proxyUri != null));
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

  static Future<Map<String, String>> _requestHeaders({
    required Uri? proxyUri,
    required String apiKey,
  }) async {
    if (proxyUri == null) {
      return {'Authorization': 'Bearer $apiKey'};
    }

    final user = FirebaseService.currentUser;
    if (user == null) {
      throw Exception(
        'Sign in before using automatic transcription in a production build.',
      );
    }

    try {
      final idToken = await user.getIdToken().timeout(
        const Duration(seconds: 12),
      );
      final appCheckToken = await FirebaseAppCheck.instance.getToken().timeout(
        const Duration(seconds: 12),
      );
      if (idToken == null || idToken.isEmpty) {
        throw const FormatException('Firebase ID token was empty.');
      }
      if (appCheckToken == null || appCheckToken.isEmpty) {
        throw const FormatException('Firebase App Check token was empty.');
      }
      return {
        'Authorization': 'Bearer $idToken',
        'X-Firebase-AppCheck': appCheckToken,
      };
    } on TimeoutException {
      throw Exception(
        'Account verification timed out before transcription could start.',
      );
    } catch (_) {
      throw Exception(
        'CaptionCraft could not verify this app installation for transcription. Reopen the app and try again.',
      );
    }
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

  static String _formatDioError(DioException error, {required bool usesProxy}) {
    final statusCode = error.response?.statusCode;
    final responseData = error.response?.data;
    final message = _responseMessage(responseData) ?? error.message;

    if (statusCode == 401) {
      return usesProxy
          ? 'Your transcription session could not be verified. Sign in again and retry.'
          : 'Groq authentication failed. Check the development GROQ_API_KEY.';
    }

    if (statusCode == 403) {
      return usesProxy
          ? 'This app installation is not authorized for transcription. Check App Check and proxy configuration.'
          : 'Groq denied this transcription request.';
    }

    if (statusCode == 413) {
      return 'The transcription service rejected this audio chunk because it is too large.';
    }

    if (statusCode != null) {
      return 'Transcription failed with HTTP $statusCode'
          '${message == null || message.isEmpty ? '' : ': $message'}';
    }

    return 'Could not reach the transcription service'
        '${message == null || message.isEmpty ? '' : ': $message'}';
  }

  static String? _responseMessage(dynamic responseData) {
    if (responseData is Map) {
      final error = responseData['error'];
      if (error is Map) {
        final message = error['message'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }

      final message = responseData['message'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
    }

    if (responseData is String && responseData.trim().isNotEmpty) {
      final normalized = responseData.replaceAll(RegExp(r'\s+'), ' ').trim();
      return normalized.length <= 240
          ? normalized
          : '${normalized.substring(0, 240)}…';
    }

    return null;
  }
}
