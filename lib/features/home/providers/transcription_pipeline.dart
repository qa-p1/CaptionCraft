import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;
import '../../../core/constants/groq_constants.dart';
import '../../../core/utils/ffmpeg_service.dart';
import '../../../core/utils/media_job.dart';
import '../../../core/utils/groq_service.dart';
import '../../../shared/models/processing_state.dart';
import '../../../shared/models/project_model.dart';
import '../../editor/models/subtitle_entry.dart';
import '../../editor/models/word_timing.dart';

/// Injectable boundary for native media work and speech requests.
class TranscriptionBackend {
  void ensureConfigured() => GroqService.ensureConfigured();
  Future<Map<String, dynamic>> probe(String path, MediaJob job) =>
      FFmpegService.getMediaInfo(path, job: job);
  Future<String> extract(
    String path,
    Duration start,
    Duration duration,
    MediaJob job,
    void Function(double) progress,
  ) => FFmpegService.extractAudio(
    path,
    startTime: start,
    clipDuration: duration,
    job: job,
    onProgress: progress,
  );
  Future<List<AudioChunk>> chunks(
    String path,
    Duration duration,
    MediaJob job,
  ) => FFmpegService.chunkAudio(path, duration, job: job);
  Future<String> thumbnail(String path, MediaJob job) =>
      FFmpegService.generateThumbnail(path, job: job);
  Future<List<WordTiming>> transcribe(
    AudioChunk chunk,
    String language,
    CancelToken token,
  ) => GroqService.transcribeChunk(
    audioChunk: File(chunk.filePath),
    chunkIndex: chunk.index,
    chunkStartOffset: chunk.startTime,
    language: language,
    cancelToken: token,
  );
}

/// Orchestrates the full transcription pipeline:
/// video info → audio extraction → chunking → Groq transcription → word grouping → subtitle assembly.
class TranscriptionPipeline {
  TranscriptionPipeline({TranscriptionBackend? backend})
    : _backend = backend ?? TranscriptionBackend();
  final TranscriptionBackend _backend;
  MediaJob _mediaJob = MediaJob();
  bool _running = false;
  bool _disposed = false;

  Future<T?> _exclusive<T>(Future<T?> Function() operation) async {
    if (_disposed) throw StateError('Transcription has been disposed.');
    if (_running) throw StateError('A transcription is already running.');
    _running = true;
    _cancelled = false;
    _mediaJob = MediaJob();
    _transcriptionCancelToken = CancelToken();
    try {
      final result = await operation();
      return _cancelled ? null : result;
    } catch (_) {
      if (_cancelled) return null;
      rethrow;
    } finally {
      _running = false;
    }
  }

  final StreamController<ProcessingProgress> _progressController =
      StreamController<ProcessingProgress>.broadcast();

  Stream<ProcessingProgress> get progressStream => _progressController.stream;

  bool _cancelled = false;
  CancelToken _transcriptionCancelToken = CancelToken();

  /// Run the full pipeline. Returns a Project on success.
  Future<Project?> run({
    required String videoPath,
    String language = '',
    required String uid,
    String? projectName,
  }) => _exclusive(() async {
    final finalEntries = await _transcribeVideoSegment(
      videoPath: videoPath,
      language: language,
    );
    if (finalEntries == null) return null;

    try {
      _emitProgress(
        ProcessingStage.assemblingSubtitles,
        0.92,
        'Generating thumbnail...',
      );

      final mediaInfo = await _backend.probe(videoPath, _mediaJob);
      final durationMs = mediaInfo['durationMs'] as int;
      String? thumbnailBase64;
      String? thumbPath;
      try {
        thumbPath = await _backend.thumbnail(videoPath, _mediaJob);
        if (thumbPath.isNotEmpty) {
          final thumbFile = File(thumbPath);
          if (await thumbFile.exists()) {
            final bytes = await thumbFile.readAsBytes();
            if (bytes.length <= 50 * 1024) {
              thumbnailBase64 = base64Encode(bytes);
            }
          }
        }
      } catch (_) {
        // Non-critical — skip thumbnail
      } finally {
        if (thumbPath != null && thumbPath.isNotEmpty) {
          try {
            final thumbFile = File(thumbPath);
            if (await thumbFile.exists()) await thumbFile.delete();
          } catch (_) {
            // Thumbnail cleanup is best-effort.
          }
        }
      }

      if (_cancelled) return null;
      _emitProgress(ProcessingStage.done, 1.0, 'Done!');

      final projectId = const Uuid().v4();
      final videoName = projectName?.isNotEmpty == true
          ? projectName!
          : p.basenameWithoutExtension(videoPath);

      return Project(
        id: projectId,
        ownerUid: uid,
        name: videoName,
        videoPath: videoPath,
        thumbnailBase64: thumbnailBase64,
        durationMs: durationMs,
        subtitles: finalEntries,
      );
    } catch (e) {
      if (_cancelled) return null;
      _emitProgress(ProcessingStage.error, 0, e.toString());
      rethrow;
    }
  });

  Future<List<SubtitleEntry>?> transcribeVideoSegment({
    required String videoPath,
    Duration startTime = Duration.zero,
    Duration? clipDuration,
    String language = '',
  }) => _exclusive(
    () => _transcribeVideoSegment(
      videoPath: videoPath,
      startTime: startTime,
      clipDuration: clipDuration,
      language: language,
    ),
  );

  Future<List<SubtitleEntry>?> _transcribeVideoSegment({
    required String videoPath,
    Duration startTime = Duration.zero,
    Duration? clipDuration,
    String language = '',
  }) async {
    final generatedTemporaryPaths = <String>{};

    try {
      _backend.ensureConfigured();

      // ── Step 1: Get media info ──
      _emitProgress(ProcessingStage.extractingAudio, 0.0, 'Analyzing video...');

      final mediaInfo = await _backend.probe(videoPath, _mediaJob);
      if (_cancelled) return null;

      if (!(mediaInfo['hasAudio'] as bool)) {
        throw Exception(
          'This video has no audio track. Subtitles require audio.',
        );
      }

      final sourceDurationMs = mediaInfo['durationMs'] as int;
      final startMs = startTime.inMilliseconds;
      if (startMs < 0 ||
          sourceDurationMs <= 0 ||
          startMs >= sourceDurationMs ||
          (clipDuration != null && clipDuration <= Duration.zero)) {
        throw ArgumentError(
          'Select a non-empty segment inside the source video.',
        );
      }
      final remainingMs = sourceDurationMs - startMs;
      final durationMs = (clipDuration?.inMilliseconds ?? remainingMs).clamp(
        1,
        remainingMs,
      );
      final maxDurationMs = GroqConstants.maxVideoDurationMinutes * 60 * 1000;
      if (durationMs > maxDurationMs) {
        throw Exception(
          'Maximum supported video length is ${GroqConstants.maxVideoDurationMinutes} minutes.',
        );
      }
      final totalDuration = Duration(milliseconds: durationMs);

      // ── Step 2: Extract audio ──
      _emitProgress(
        ProcessingStage.extractingAudio,
        0.05,
        'Extracting audio...',
      );

      final audioPath = await _backend.extract(
        videoPath,
        startTime,
        totalDuration,
        _mediaJob,
        (p) {
          _emitProgress(
            ProcessingStage.extractingAudio,
            0.05 + p * 0.15,
            'Extracting audio...',
          );
        },
      );
      generatedTemporaryPaths.add(audioPath);
      if (_cancelled) return null;

      // ── Step 3: Chunk audio if needed ──
      _emitProgress(
        ProcessingStage.compressing,
        0.22,
        'Preparing audio chunks...',
      );

      final chunks = await _backend.chunks(audioPath, totalDuration, _mediaJob);
      generatedTemporaryPaths.addAll(chunks.map((chunk) => chunk.filePath));
      if (_cancelled) return null;

      _emitProgress(
        ProcessingStage.compressing,
        0.30,
        'Audio ready (${chunks.length} chunk${chunks.length > 1 ? "s" : ""})',
      );

      // ── Step 4: Transcribe each chunk (word-level) ──
      final allWords = <WordTiming>[];

      for (var i = 0; i < chunks.length; i++) {
        if (_cancelled) return null;

        final chunk = chunks[i];
        final chunkProgress = i / chunks.length;
        final progressStart = 0.30 + chunkProgress * 0.55;

        _emitProgress(
          ProcessingStage.transcribing,
          progressStart,
          'Transcribing${chunks.length > 1 ? " chunk ${i + 1} of ${chunks.length}" : ""}...',
          currentChunk: i,
          totalChunks: chunks.length,
        );

        final words = await _backend.transcribe(
          chunk,
          language,
          _transcriptionCancelToken,
        );
        if (_cancelled) return null;

        allWords.addAll(words);

        _emitProgress(
          ProcessingStage.transcribing,
          0.30 + ((i + 1) / chunks.length) * 0.55,
          chunks.length > 1
              ? 'Finished chunk ${i + 1} of ${chunks.length}...'
              : 'Transcription received...',
          currentChunk: i,
          totalChunks: chunks.length,
        );
      }

      if (_cancelled) return null;

      // ── Step 5: Deduplicate & group words into lines ──
      _emitProgress(
        ProcessingStage.assemblingSubtitles,
        0.88,
        'Grouping words into lines...',
      );

      final deduplicatedWords = chunks.length > 1
          ? GroqService.deduplicateWordOverlaps(allWords)
          : allWords;

      final finalEntries = GroqService.groupWordsIntoLines(deduplicatedWords);

      if (finalEntries.isEmpty) {
        throw Exception('No speech was detected in this video.');
      }

      return finalEntries;
    } catch (e) {
      if (_cancelled) return null;
      _emitProgress(ProcessingStage.error, 0, e.toString());
      rethrow;
    } finally {
      for (final temporaryPath in generatedTemporaryPaths) {
        try {
          final file = File(temporaryPath);
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Temporary media cleanup is best-effort.
        }
      }
    }
  }

  void cancel() {
    _cancelled = true;
    if (!_transcriptionCancelToken.isCancelled) {
      _transcriptionCancelToken.cancel('Cancelled by user');
    }
    unawaited(
      _mediaJob.cancel().catchError((Object _) {
        // Logical cancellation still suppresses late results if native cleanup fails.
      }),
    );
  }

  void _emitProgress(
    ProcessingStage stage,
    double progress,
    String message, {
    int? currentChunk,
    int? totalChunks,
  }) {
    if (!_cancelled && !_progressController.isClosed) {
      _progressController.add(
        ProcessingProgress(
          stage: stage,
          progress: progress,
          message: message,
          currentChunk: currentChunk,
          totalChunks: totalChunks,
        ),
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
    if (!_progressController.isClosed) {
      _progressController.close();
    }
  }
}
