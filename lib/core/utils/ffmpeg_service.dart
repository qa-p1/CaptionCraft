import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../constants/groq_constants.dart';

/// Chunk metadata for split audio files.
class AudioChunk {
  final int index;
  final Duration startTime;
  final Duration endTime;
  final String filePath;

  const AudioChunk({
    required this.index,
    required this.startTime,
    required this.endTime,
    required this.filePath,
  });
}

/// Service handling all FFmpeg operations:
/// audio extraction, compression, chunking, waveform generation, and subtitle burning.
class FFmpegService {
  FFmpegService._();

  /// Extract and compress audio from video optimized for Whisper (16kHz mono).
  /// Returns the path to the extracted audio file.
  static Future<String> extractAudio(
    String videoPath, {
    Duration? startTime,
    Duration? clipDuration,
    void Function(double progress)? onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final operationId = DateTime.now().microsecondsSinceEpoch;
    final flacPath = p.join(
      tempDir.path,
      'caption_craft_audio_$operationId.flac',
    );

    // Get video duration for progress reporting
    final durationMs =
        clipDuration?.inMilliseconds.toDouble() ??
        await _getMediaDurationMs(videoPath);

    // Enable statistics callback for progress
    if (onProgress != null && durationMs > 0) {
      FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
        final time = statistics.getTime();
        if (time > 0) {
          onProgress((time / durationMs).clamp(0.0, 1.0));
        }
      });
    }

    // Try FLAC first (lossless, good compression for speech)
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      if (startTime != null) ...['-ss', _formatDurationForFfmpeg(startTime)],
      '-i',
      videoPath,
      if (clipDuration != null) ...[
        '-t',
        _formatDurationForFfmpeg(clipDuration),
      ],
      '-vn',
      '-ar',
      '${GroqConstants.targetAudioSampleRate}',
      '-ac',
      '${GroqConstants.targetAudioChannels}',
      '-c:a',
      'flac',
      flacPath,
    ]);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isCancel(returnCode)) {
      await _deleteFileBestEffort(flacPath);
      throw Exception('Audio extraction cancelled.');
    }

    if (ReturnCode.isSuccess(returnCode) && await File(flacPath).exists()) {
      // Check file size - if too large, fall back to MP3
      final fileSize = await File(flacPath).length();
      if (fileSize <= GroqConstants.maxChunkBytes) {
        return flacPath;
      }
    }

    // Fallback to MP3 (smaller but still fine for speech)
    await _deleteFileBestEffort(flacPath);
    final mp3Path = p.join(
      tempDir.path,
      'caption_craft_audio_$operationId.mp3',
    );
    final mp3Session = await FFmpegKit.executeWithArguments([
      '-y',
      if (startTime != null) ...['-ss', _formatDurationForFfmpeg(startTime)],
      '-i',
      videoPath,
      if (clipDuration != null) ...[
        '-t',
        _formatDurationForFfmpeg(clipDuration),
      ],
      '-vn',
      '-ar',
      '${GroqConstants.targetAudioSampleRate}',
      '-ac',
      '${GroqConstants.targetAudioChannels}',
      '-b:a',
      '64k',
      mp3Path,
    ]);
    final mp3ReturnCode = await mp3Session.getReturnCode();

    if (ReturnCode.isCancel(mp3ReturnCode)) {
      await _deleteFileBestEffort(mp3Path);
      throw Exception('Audio extraction cancelled.');
    }

    if (!ReturnCode.isSuccess(mp3ReturnCode)) {
      final logs = await mp3Session.getAllLogsAsString();
      await _deleteFileBestEffort(mp3Path);
      throw Exception('Audio extraction failed: $logs');
    }

    return mp3Path;
  }

  static Future<void> _deleteFileBestEffort(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Preserve the operation result; temporary cleanup is best-effort.
    }
  }

  /// Split audio into chunks for Groq's file size limit.
  static Future<List<AudioChunk>> chunkAudio(
    String audioPath,
    Duration totalDuration,
  ) async {
    final fileSize = await File(audioPath).length();

    // If file is small enough, return as a single chunk
    if (fileSize <= GroqConstants.maxChunkBytes) {
      return [
        AudioChunk(
          index: 0,
          startTime: Duration.zero,
          endTime: totalDuration,
          filePath: audioPath,
        ),
      ];
    }

    // Calculate how many chunks we need
    final totalSeconds = totalDuration.inSeconds;
    final chunkDurationSec = GroqConstants.chunkDurationSeconds;
    final overlapSec = GroqConstants.chunkOverlapSeconds;

    final tempDir = await getTemporaryDirectory();
    final chunks = <AudioChunk>[];
    final operationId = DateTime.now().microsecondsSinceEpoch;
    var startSec = 0;
    var index = 0;

    while (startSec < totalSeconds) {
      final endSec = (startSec + chunkDurationSec).clamp(0, totalSeconds);
      final durationSec = endSec - startSec;
      if (durationSec <= 0) {
        break;
      }
      final chunkPath = p.join(
        tempDir.path,
        'cc_chunk_${operationId}_$index.mp3',
      );

      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-ss',
        '$startSec',
        '-i',
        audioPath,
        '-t',
        '$durationSec',
        '-ar',
        '${GroqConstants.targetAudioSampleRate}',
        '-ac',
        '${GroqConstants.targetAudioChannels}',
        '-b:a',
        '64k',
        chunkPath,
      ]);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isCancel(returnCode)) {
        for (final createdChunk in [
          ...chunks.map((chunk) => chunk.filePath),
          chunkPath,
        ]) {
          await _deleteFileBestEffort(createdChunk);
        }
        throw Exception('Audio chunking cancelled.');
      }

      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        for (final createdChunk in [
          ...chunks.map((chunk) => chunk.filePath),
          chunkPath,
        ]) {
          try {
            final file = File(createdChunk);
            if (await file.exists()) await file.delete();
          } catch (_) {
            // Preserve the chunking failure as the useful error.
          }
        }
        throw Exception('Audio chunking failed at chunk $index: $logs');
      }

      chunks.add(
        AudioChunk(
          index: index,
          startTime: Duration(seconds: startSec),
          endTime: Duration(seconds: endSec.toInt()),
          filePath: chunkPath,
        ),
      );

      if (endSec >= totalSeconds) {
        break;
      }
      final nextStartSec = endSec.toInt() - overlapSec;
      if (nextStartSec <= startSec) {
        startSec = endSec.toInt();
      } else {
        startSec = nextStartSec;
      }
      index++;
    }

    return chunks;
  }

  /// Generate a waveform PNG for timeline visualization.
  static Future<String> generateWaveform(
    String audioPath, {
    int width = 1920,
    int height = 120,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final outputPath = p.join(
      tempDir.path,
      'caption_craft_waveform_${DateTime.now().microsecondsSinceEpoch}.png',
    );

    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-i',
      audioPath,
      '-filter_complex',
      'showwavespic=s=${width}x$height:colors=white',
      '-frames:v',
      '1',
      outputPath,
    ]);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      // Non-critical - return empty string and skip waveform
      return '';
    }

    return outputPath;
  }

  static Future<String> extractVideoFrame(
    String videoPath, {
    required Duration position,
    int maximumWidth = 1280,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final outputPath = p.join(
      tempDir.path,
      'caption_craft_frame_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    final session = await FFmpegKit.executeWithArguments([
      '-hide_banner',
      '-y',
      '-ss',
      _formatDurationForFfmpeg(position.isNegative ? Duration.zero : position),
      '-i',
      videoPath,
      '-vf',
      "scale='min(iw,$maximumWidth)':-2:flags=lanczos,format=rgba",
      '-frames:v',
      '1',
      outputPath,
    ]);
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode) ||
        !await File(outputPath).exists() ||
        await File(outputPath).length() == 0) {
      final logs = await session.getAllLogsAsString();
      await _deleteFileBestEffort(outputPath);
      throw Exception('Could not read the selected frame: $logs');
    }
    return outputPath;
  }

  /// Burn subtitles into video using ASS file.
  static Future<String> burnSubtitles({
    required String videoPath,
    required String assFilePath,
    required String outputPath,
    String quality = 'Original',
    void Function(double progress)? onProgress,
  }) async {
    final durationMs = await _getMediaDurationMs(videoPath);

    if (onProgress != null && durationMs > 0) {
      FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
        final time = statistics.getTime();
        if (time > 0) {
          onProgress((time / durationMs).clamp(0.0, 1.0));
        }
      });
    }

    // Copy ASS file to a safe temp path with no spaces or special chars
    final tempDir = await getTemporaryDirectory();
    final safeAssPath = p.join(
      tempDir.path,
      'cc_subs_${DateTime.now().millisecondsSinceEpoch}.ass',
    );
    await File(assFilePath).copy(safeAssPath);

    // Verify ASS file is non-empty
    final safeAssFile = File(safeAssPath);
    final assSize = await safeAssFile.length();
    if (assSize == 0) {
      throw Exception('ASS subtitle file is empty. Cannot burn subtitles.');
    }
    final assContent = await safeAssFile.readAsString();
    final dialogueCount = RegExp(
      r'^Dialogue:',
      multiLine: true,
    ).allMatches(assContent).length;
    if (dialogueCount == 0) {
      throw Exception('ASS subtitle file contains no dialogue entries.');
    }

    if (kDebugMode) {
      debugPrint(
        '[FFmpeg] ASS path: $safeAssPath (size: $assSize bytes, '
        'dialogues: $dialogueCount)',
      );
    }

    String scaleFilter = '';
    switch (quality) {
      case '1080p':
        scaleFilter = 'scale=-2:1080,';
        break;
      case '720p':
        scaleFilter = 'scale=-2:720,';
        break;
      case '480p':
        scaleFilter = 'scale=-2:480,';
        break;
    }

    final vfFilter = scaleFilter.isNotEmpty
        ? '${scaleFilter}ass=$safeAssPath'
        : 'ass=$safeAssPath';

    final session = await FFmpegKit.executeWithArguments([
      '-i',
      videoPath,
      '-vf',
      vfFilter,
      '-c:v',
      'libx264',
      '-crf',
      '23',
      '-preset',
      'fast',
      '-c:a',
      'copy',
      outputPath,
      '-y',
    ]);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      if (kDebugMode) {
        debugPrint('[FFmpeg] Burn subtitles FAILED. Logs:\n$logs');
      }
      throw Exception('Subtitle burn failed. Check logs for details.');
    }

    // Verify the output file exists and is non-empty
    final outputFile = File(outputPath);
    if (!await outputFile.exists()) {
      throw Exception('Video export failed: output file was not created.');
    }
    final outputSize = await outputFile.length();
    if (outputSize == 0) {
      await outputFile.delete();
      throw Exception('Video export failed: output file is empty (0 bytes).');
    }

    if (kDebugMode) {
      debugPrint(
        '[FFmpeg] Burn subtitles SUCCESS. Output: $outputPath '
        '(${(outputSize / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    }

    return outputPath;
  }

  /// Get media information (duration, resolution, has audio).
  static Future<Map<String, dynamic>> getMediaInfo(String videoPath) async {
    final session = await FFprobeKit.getMediaInformation(videoPath);
    final info = session.getMediaInformation();

    if (info == null) {
      throw Exception('Could not read video file. It may be corrupted.');
    }

    final durationStr = info.getDuration();
    final durationMs = durationStr != null
        ? (double.tryParse(durationStr) ?? 0) * 1000
        : 0;

    // Find video and audio streams
    final streams = info.getStreams();
    int width = 0;
    int height = 0;
    bool hasAudio = false;
    double frameRate = 0;
    String? colorPrimaries;
    String? colorTransfer;
    String? colorSpace;
    String? colorRange;
    String? pixelFormat;
    int bitDepth = 0;
    final audioStreams = <Map<String, dynamic>>[];

    for (final stream in streams) {
      final type = stream.getType();
      if (type == 'video' && width == 0) {
        width = stream.getWidth() ?? 0;
        height = stream.getHeight() ?? 0;
        frameRate = _parseFrameRate(
          stream.getAverageFrameRate() ?? stream.getRealFrameRate(),
        );
        final properties = stream.getAllProperties() ?? const {};
        colorPrimaries = properties['color_primaries']?.toString();
        colorTransfer = properties['color_transfer']?.toString();
        colorSpace = properties['color_space']?.toString();
        colorRange = properties['color_range']?.toString();
        pixelFormat = properties['pix_fmt']?.toString();
        bitDepth =
            int.tryParse(properties['bits_per_raw_sample']?.toString() ?? '') ??
            _pixelFormatBitDepth(pixelFormat);
      }
      if (type == 'audio') {
        hasAudio = true;
        final properties = stream.getAllProperties() ?? const {};
        final tags = properties['tags'];
        audioStreams.add({
          'streamIndex': audioStreams.length,
          'codec': stream.getCodec(),
          'channels':
              int.tryParse(properties['channels']?.toString() ?? '') ??
              _channelsForLayout(stream.getChannelLayout()),
          'channelLayout': stream.getChannelLayout(),
          'sampleRate': int.tryParse(stream.getSampleRate() ?? '') ?? 0,
          'language': tags is Map ? tags['language']?.toString() : null,
          'title': tags is Map ? tags['title']?.toString() : null,
        });
      }
    }

    final fileSize = info.getSize();

    return {
      'durationMs': durationMs.round(),
      'width': width,
      'height': height,
      'frameRate': frameRate,
      'hasAudio': hasAudio,
      'audioStreamCount': audioStreams.length,
      'audioStreams': audioStreams,
      'audioChannels': audioStreams.isEmpty
          ? 0
          : audioStreams.first['channels'] as int? ?? 0,
      'colorPrimaries': colorPrimaries,
      'colorTransfer': colorTransfer,
      'colorSpace': colorSpace,
      'colorRange': colorRange,
      'pixelFormat': pixelFormat,
      'bitDepth': bitDepth,
      'fileSize': int.tryParse(fileSize ?? '0') ?? 0,
    };
  }

  static int _pixelFormatBitDepth(String? pixelFormat) {
    final match = RegExp(
      r'p(\d{2})(?:le|be)?$',
    ).firstMatch(pixelFormat?.toLowerCase() ?? '');
    return int.tryParse(match?.group(1) ?? '') ?? 8;
  }

  static int _channelsForLayout(String? layout) {
    return switch (layout?.toLowerCase()) {
      'mono' => 1,
      'stereo' => 2,
      '2.1' => 3,
      'quad' || '4.0' => 4,
      '5.0' => 5,
      '5.1' => 6,
      '7.1' => 8,
      _ => 0,
    };
  }

  /// Generate a thumbnail from the video.
  static Future<String> generateThumbnail(String videoPath) async {
    final tempDir = await getTemporaryDirectory();
    final outputPath = p.join(
      tempDir.path,
      'caption_craft_thumb_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );

    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-i',
      videoPath,
      '-vf',
      'thumbnail,scale=320:180',
      '-frames:v',
      '1',
      '-q:v',
      '6',
      outputPath,
    ]);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      return ''; // Non-critical - return empty
    }

    return outputPath;
  }

  /// Cancel all running FFmpeg sessions.
  static Future<void> cancelAll() async {
    await FFmpegKit.cancel();
  }

  /// Get media duration in milliseconds (helper).
  static Future<double> _getMediaDurationMs(String videoPath) async {
    try {
      final session = await FFprobeKit.getMediaInformation(videoPath);
      final info = session.getMediaInformation();
      if (info == null) return 0;
      final durationStr = info.getDuration();
      return (double.tryParse(durationStr ?? '0') ?? 0) * 1000;
    } catch (e) {
      return 0;
    }
  }

  static String _formatDurationForFfmpeg(Duration duration) {
    final totalMilliseconds = duration.inMilliseconds;
    final hours = totalMilliseconds ~/ 3600000;
    final minutes = (totalMilliseconds % 3600000) ~/ 60000;
    final seconds = (totalMilliseconds % 60000) ~/ 1000;
    final milliseconds = totalMilliseconds % 1000;
    final hoursText = hours.toString().padLeft(2, '0');
    final minutesText = minutes.toString().padLeft(2, '0');
    final secondsText = seconds.toString().padLeft(2, '0');
    final millisText = milliseconds.toString().padLeft(3, '0');
    return '$hoursText:$minutesText:$secondsText.$millisText';
  }

  static double _parseFrameRate(String? value) {
    if (value == null || value.isEmpty) return 0;
    final parts = value.split('/');
    if (parts.length == 2) {
      final numerator = double.tryParse(parts[0]) ?? 0;
      final denominator = double.tryParse(parts[1]) ?? 0;
      if (denominator != 0) return numerator / denominator;
    }
    return double.tryParse(value) ?? 0;
  }
}
