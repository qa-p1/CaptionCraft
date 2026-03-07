import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;
import '../../../core/constants/groq_constants.dart';
import '../../../core/utils/ffmpeg_service.dart';
import '../../../core/utils/groq_service.dart';
import '../../../shared/models/processing_state.dart';
import '../../../shared/models/project_model.dart';
import '../../editor/models/subtitle_entry.dart';
import '../../editor/models/word_timing.dart';

/// Orchestrates the full transcription pipeline:
/// video info → audio extraction → chunking → Groq transcription → word grouping → subtitle assembly.
class TranscriptionPipeline {
  final StreamController<ProcessingProgress> _progressController =
      StreamController<ProcessingProgress>.broadcast();

  Stream<ProcessingProgress> get progressStream => _progressController.stream;

  bool _cancelled = false;

  /// Run the full pipeline. Returns a Project on success.
  Future<Project?> run({
    required String videoPath,
    String language = '',
    required String uid,
    String? projectName,
  }) async {
    final finalEntries = await transcribeVideoSegment(
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

      final mediaInfo = await FFmpegService.getMediaInfo(videoPath);
      final durationMs = mediaInfo['durationMs'] as int;
      String? thumbnailBase64;
      try {
        final thumbPath = await FFmpegService.generateThumbnail(videoPath);
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
      }

      _emitProgress(ProcessingStage.done, 1.0, 'Done!');

      final projectId = const Uuid().v4();
      final videoName = projectName?.isNotEmpty == true
          ? projectName!
          : p.basenameWithoutExtension(videoPath);

      return Project(
        id: projectId,
        name: videoName,
        videoPath: videoPath,
        thumbnailBase64: thumbnailBase64,
        durationMs: durationMs,
        subtitles: finalEntries,
      );
    } catch (e) {
      _emitProgress(ProcessingStage.error, 0, e.toString());
      rethrow;
    }
  }

  Future<List<SubtitleEntry>?> transcribeVideoSegment({
    required String videoPath,
    Duration startTime = Duration.zero,
    Duration? clipDuration,
    String language = '',
  }) async {
    _cancelled = false;

    try {
      // ── Step 1: Get media info ──
      _emitProgress(ProcessingStage.extractingAudio, 0.0, 'Analyzing video...');

      final mediaInfo = await FFmpegService.getMediaInfo(videoPath);
      if (_cancelled) return null;

      if (!(mediaInfo['hasAudio'] as bool)) {
        throw Exception(
          'This video has no audio track. Subtitles require audio.',
        );
      }

      final sourceDurationMs = mediaInfo['durationMs'] as int;
      final durationMs = clipDuration?.inMilliseconds ?? sourceDurationMs;
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

      final audioPath = await FFmpegService.extractAudio(
        videoPath,
        startTime: startTime,
        clipDuration: clipDuration,
        onProgress: (p) {
          _emitProgress(
            ProcessingStage.extractingAudio,
            0.05 + p * 0.15,
            'Extracting audio...',
          );
        },
      );
      if (_cancelled) return null;

      // ── Step 3: Chunk audio if needed ──
      _emitProgress(
        ProcessingStage.compressing,
        0.22,
        'Preparing audio chunks...',
      );

      final chunks = await FFmpegService.chunkAudio(audioPath, totalDuration);
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

        final words = await GroqService.transcribeChunk(
          audioChunk: File(chunk.filePath),
          chunkIndex: chunk.index,
          chunkStartOffset: chunk.startTime,
          language: language,
        );

        allWords.addAll(words);
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
      _emitProgress(ProcessingStage.error, 0, e.toString());
      rethrow;
    }
  }

  void cancel() {
    _cancelled = true;
    FFmpegService.cancelAll();
    if (!_progressController.isClosed) {
      _progressController.close();
    }
  }

  void _emitProgress(
    ProcessingStage stage,
    double progress,
    String message, {
    int? currentChunk,
    int? totalChunks,
  }) {
    if (!_progressController.isClosed) {
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
    if (!_progressController.isClosed) {
      _progressController.close();
    }
  }
}
