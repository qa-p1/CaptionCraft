import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../features/editor/models/editor_effect_models.dart';
import 'ffmpeg_service.dart';

class MaskTrackingResult {
  final List<EditorMaskTrackingKeyframe> keyframes;
  final double averageConfidence;

  const MaskTrackingResult({
    required this.keyframes,
    required this.averageConfidence,
  });
}

class MaskTrackingService {
  MaskTrackingService._();

  static Future<MaskTrackingResult> trackForward({
    required String sourcePath,
    required Duration sourceStartTime,
    required Duration sourceDuration,
    required Duration timelineOffset,
    required Duration timelineDuration,
    required double playbackRate,
    required bool reversed,
    required EditorEffectMask initialMask,
    void Function(double progress)? onProgress,
  }) async {
    if (timelineDuration <= Duration.zero || sourceDuration <= Duration.zero) {
      throw ArgumentError('The tracking range is empty.');
    }
    final mediaInfo = await FFmpegService.getMediaInfo(sourcePath);
    final width = (mediaInfo['width'] as int?) ?? 0;
    final height = (mediaInfo['height'] as int?) ?? 0;
    if (width <= 0 || height <= 0) {
      throw Exception('The source dimensions could not be read.');
    }

    final temporaryRoot = await getTemporaryDirectory();
    final workingDirectory = Directory(
      path.join(
        temporaryRoot.path,
        'cc_mask_track_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await workingDirectory.create(recursive: true);
    final objectPath = path.join(workingDirectory.path, 'object.png');
    final metadataPath = path.join(workingDirectory.path, 'tracking.txt');
    try {
      final cropWidth = math.max(8, (initialMask.safeWidth * width).round());
      final cropHeight = math.max(8, (initialMask.safeHeight * height).round());
      final cropX = (initialMask.safeX * width).round().clamp(
        0,
        math.max(0, width - cropWidth),
      );
      final cropY = (initialMask.safeY * height).round().clamp(
        0,
        math.max(0, height - cropHeight),
      );
      final sourcePreparation = <String>[
        ..._sourcePreparationFilters(
          sourceStartTime: sourceStartTime,
          sourceDuration: sourceDuration,
          playbackRate: playbackRate,
          reversed: reversed,
        ),
      ];
      final templateSession = await FFmpegKit.executeWithArguments([
        '-hide_banner',
        '-y',
        '-i',
        sourcePath,
        '-vf',
        '${sourcePreparation.join(',')},'
            'crop=$cropWidth:$cropHeight:$cropX:$cropY,format=gray',
        '-frames:v',
        '1',
        objectPath,
      ]);
      final templateCode = await templateSession.getReturnCode();
      if (!ReturnCode.isSuccess(templateCode) ||
          !await File(objectPath).exists()) {
        final logs = await templateSession.getAllLogsAsString();
        throw Exception('Could not create a tracking reference: $logs');
      }

      final durationSeconds =
          timelineDuration.inMicroseconds / Duration.microsecondsPerSecond;
      final sampleRate = (900 / math.max(0.001, durationSeconds))
          .clamp(3.0, 12.0)
          .toDouble();
      final filter = buildTrackingFilterForTesting(
        sourceStartTime: sourceStartTime,
        sourceDuration: sourceDuration,
        playbackRate: playbackRate,
        reversed: reversed,
        sampleRate: sampleRate,
        objectPath: objectPath,
        metadataPath: metadataPath,
      );
      onProgress?.call(0.08);
      final trackingSession = await FFmpegKit.executeWithArguments([
        '-hide_banner',
        '-y',
        '-i',
        sourcePath,
        '-vf',
        filter,
        '-an',
        '-f',
        'null',
        '-',
      ]);
      final trackingCode = await trackingSession.getReturnCode();
      if (!ReturnCode.isSuccess(trackingCode)) {
        final logs = await trackingSession.getAllLogsAsString();
        throw Exception('Object tracking failed: $logs');
      }
      onProgress?.call(0.92);
      if (!await File(metadataPath).exists()) {
        throw Exception('No tracking samples were produced.');
      }
      final samples = parseMetadataForTesting(
        await File(metadataPath).readAsString(),
      );
      if (samples.length < 2) {
        throw Exception(
          'The selected region could not be followed. Choose a more '
          'distinct object or a tighter mask.',
        );
      }
      final basePoints = initialMask.safePoints;
      final frames = <EditorMaskTrackingKeyframe>[];
      for (final sample in samples) {
        final normalizedX = (sample.x / width).clamp(0.0, 1.0).toDouble();
        final normalizedY = (sample.y / height).clamp(0.0, 1.0).toDouble();
        final normalizedWidth = (sample.width / width)
            .clamp(0.02, 1.0)
            .toDouble();
        final normalizedHeight = (sample.height / height)
            .clamp(0.02, 1.0)
            .toDouble();
        final deltaX = normalizedX - initialMask.safeX;
        final deltaY = normalizedY - initialMask.safeY;
        frames.add(
          EditorMaskTrackingKeyframe(
            time: timelineOffset + sample.time,
            x: normalizedX,
            y: normalizedY,
            width: normalizedWidth,
            height: normalizedHeight,
            points: basePoints
                .map(
                  (point) => EditorMaskPoint(
                    point.x + deltaX,
                    point.y + deltaY,
                  ).normalized,
                )
                .toList(),
            confidence: sample.confidence,
          ),
        );
      }
      final first = frames.first;
      frames[0] = first.copyWith(
        time: timelineOffset,
        x: initialMask.safeX,
        y: initialMask.safeY,
        width: initialMask.safeWidth,
        height: initialMask.safeHeight,
        points: basePoints,
        confidence: 1,
      );
      final averageConfidence =
          frames
              .map((frame) => frame.confidence)
              .reduce((first, second) => first + second) /
          frames.length;
      onProgress?.call(1);
      return MaskTrackingResult(
        keyframes: List.unmodifiable(frames),
        averageConfidence: averageConfidence,
      );
    } finally {
      try {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      } catch (_) {
        // Tracking output is already persisted in the timeline model.
      }
    }
  }

  static List<
    ({Duration time, int x, int y, int width, int height, double confidence})
  >
  parseMetadataForTesting(String contents) {
    final samples =
        <
          ({
            Duration time,
            int x,
            int y,
            int width,
            int height,
            double confidence,
          })
        >[];
    double? time;
    int? x;
    int? y;
    int? width;
    int? height;
    double? score;

    void commit() {
      if (time == null ||
          x == null ||
          y == null ||
          width == null ||
          height == null) {
        return;
      }
      final safeScore = score ?? 0.18;
      samples.add((
        time: Duration(
          microseconds: (time * Duration.microsecondsPerSecond).round(),
        ),
        x: x,
        y: y,
        width: width,
        height: height,
        confidence: (1 - safeScore / 0.18).clamp(0.0, 1.0).toDouble(),
      ));
    }

    for (final rawLine in contents.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.startsWith('frame:')) {
        commit();
        time = double.tryParse(
          RegExp(r'pts_time:([^\s]+)').firstMatch(line)?.group(1) ?? '',
        );
        x = null;
        y = null;
        width = null;
        height = null;
        score = null;
        continue;
      }
      final separator = line.indexOf('=');
      if (separator < 0) continue;
      final key = line.substring(0, separator);
      final value = line.substring(separator + 1);
      switch (key) {
        case 'lavfi.rect.x':
          x = int.tryParse(value);
        case 'lavfi.rect.y':
          y = int.tryParse(value);
        case 'lavfi.rect.w':
          width = int.tryParse(value);
        case 'lavfi.rect.h':
          height = int.tryParse(value);
        case 'lavfi.rect.score':
          score = double.tryParse(value);
      }
    }
    commit();
    samples.sort((first, second) => first.time.compareTo(second.time));
    return List.unmodifiable(samples);
  }

  static String buildTrackingFilterForTesting({
    required Duration sourceStartTime,
    required Duration sourceDuration,
    required double playbackRate,
    required bool reversed,
    required double sampleRate,
    required String objectPath,
    required String metadataPath,
  }) {
    final escapedObject = _escapeFilterPath(objectPath);
    final escapedMetadata = _escapeFilterPath(metadataPath);
    return <String>[
      ..._sourcePreparationFilters(
        sourceStartTime: sourceStartTime,
        sourceDuration: sourceDuration,
        playbackRate: playbackRate,
        reversed: reversed,
      ),
      'fps=${_number(sampleRate.clamp(1.0, 60.0))}',
      'format=gray',
      "find_rect=object='$escapedObject':threshold=0.18:mipmaps=3",
      "metadata=mode=print:file='$escapedMetadata'",
    ].join(',');
  }

  static List<String> _sourcePreparationFilters({
    required Duration sourceStartTime,
    required Duration sourceDuration,
    required double playbackRate,
    required bool reversed,
  }) {
    return <String>[
      'trim=start=${_seconds(sourceStartTime)}:'
          'duration=${_seconds(sourceDuration)}',
      if (reversed) 'reverse',
      'setpts=(PTS-STARTPTS)/${_number(playbackRate.clamp(0.25, 4))}',
    ];
  }

  static String _seconds(Duration duration) =>
      _number(duration.inMicroseconds / Duration.microsecondsPerSecond);

  static String _number(num value) {
    final text = value.toStringAsFixed(6);
    final trimmed = text.replaceFirst(RegExp(r'\.?0+$'), '');
    return trimmed.isEmpty || trimmed == '-' ? '0' : trimmed;
  }

  static String _escapeFilterPath(String value) =>
      value.replaceAll('\\', '/').replaceAll(':', r'\:').replaceAll("'", r"\'");
}
