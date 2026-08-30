import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'timeline_media_cache_pruner.dart';

typedef WaveformFingerprintResolver = Future<String> Function(String path);
typedef WaveformGenerator =
    Future<bool> Function({
      required String sourcePath,
      required String outputPath,
      required Duration sourceStart,
      required Duration sourceDuration,
      required int audioStreamIndex,
      required int width,
      required int height,
    });

/// Deterministic, bounded cache for source-window waveform images.
///
/// Timeline virtualization limits requests to visible clips, while this cache
/// deduplicates identical work across rebuilds, duplicate clips and sessions.
/// Jobs are serialized so a scroll across many audio clips cannot launch an
/// unbounded number of FFmpeg processes on a phone.
class TimelineWaveformCache {
  static final TimelineWaveformCache instance = TimelineWaveformCache();

  final Future<Directory> Function() _directoryProvider;
  final WaveformFingerprintResolver _fingerprintResolver;
  final WaveformGenerator _generator;
  final int maximumEntries;
  final int maximumBytes;
  final Map<String, Future<String>> _inFlight = {};
  final Map<String, int> _sourceGenerations = {};
  Future<void> _generationTail = Future<void>.value();

  TimelineWaveformCache({
    Future<Directory> Function()? directoryProvider,
    WaveformFingerprintResolver? fingerprintResolver,
    WaveformGenerator? generator,
    this.maximumEntries = 128,
    this.maximumBytes = 96 * 1024 * 1024,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _fingerprintResolver = fingerprintResolver ?? _sourceFingerprint,
       _generator = generator ?? _generate;

  Future<String> waveformFor({
    required String sourcePath,
    required Duration sourceStart,
    required Duration sourceDuration,
    int audioStreamIndex = 0,
    int width = 1024,
    int height = 96,
  }) async {
    final normalizedPath = sourcePath.trim();
    if (normalizedPath.isEmpty || sourceDuration <= Duration.zero) return '';
    final safeWidth = width.clamp(64, 16384).toInt();
    final safeHeight = height.clamp(24, 256).toInt();
    final sourceFingerprint = await _fingerprintResolver(normalizedPath);
    if (sourceFingerprint == 'missing') return '';
    final identity = cacheIdentity(
      sourcePath: normalizedPath,
      sourceFingerprint: sourceFingerprint,
      sourceStart: sourceStart,
      sourceDuration: sourceDuration,
      audioStreamIndex: audioStreamIndex,
      width: safeWidth,
      height: safeHeight,
    );
    final existing = _inFlight[identity];
    if (existing != null) return existing;
    final operation = _enqueue(
      identity: identity,
      sourcePath: normalizedPath,
      sourceStart: sourceStart,
      sourceDuration: sourceDuration,
      audioStreamIndex: audioStreamIndex,
      width: safeWidth,
      height: safeHeight,
    );
    _inFlight[identity] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[identity], operation)) {
        _inFlight.remove(identity);
      }
    }
  }

  /// Invalidates pending output for one source without cancelling unrelated
  /// preview/export FFmpeg work globally.
  void cancelSource(String sourcePath) {
    final normalized = sourcePath.trim();
    _sourceGenerations[normalized] = (_sourceGenerations[normalized] ?? 0) + 1;
  }

  Future<String> _enqueue({
    required String identity,
    required String sourcePath,
    required Duration sourceStart,
    required Duration sourceDuration,
    required int audioStreamIndex,
    required int width,
    required int height,
  }) {
    final generation = _sourceGenerations[sourcePath] ?? 0;
    final operation = _generationTail.then((_) async {
      final directory = await _directoryProvider();
      if (!await directory.exists()) await directory.create(recursive: true);
      final output = File(p.join(directory.path, '$identity.png'));
      if (await output.exists() && await output.length() > 0) {
        try {
          await output.setLastModified(DateTime.now());
        } catch (_) {
          // Cache recency is an optimization only.
        }
        await _prune(directory, preservingPath: output.path);
        return output.path;
      }
      final partial = File(
        p.join(
          directory.path,
          '$identity.${DateTime.now().microsecondsSinceEpoch}.partial.png',
        ),
      );
      try {
        final generated = await _generator(
          sourcePath: sourcePath,
          outputPath: partial.path,
          sourceStart: sourceStart,
          sourceDuration: sourceDuration,
          audioStreamIndex: audioStreamIndex,
          width: width,
          height: height,
        );
        final cancelled = (_sourceGenerations[sourcePath] ?? 0) != generation;
        if (!generated ||
            cancelled ||
            !await partial.exists() ||
            await partial.length() == 0) {
          return '';
        }
        if (await output.exists()) await output.delete();
        await partial.rename(output.path);
        await _prune(directory, preservingPath: output.path);
        return output.path;
      } finally {
        if (await partial.exists()) {
          try {
            await partial.delete();
          } catch (_) {
            // A failed native FFmpeg session can retain its output briefly.
          }
        }
      }
    });
    _generationTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _prune(
    Directory directory, {
    required String preservingPath,
  }) async {
    await pruneTimelineMediaCache(
      directory: directory,
      includes: (file) =>
          RegExp(r'^[0-9a-f]{64}\.png$').hasMatch(p.basename(file.path)),
      preservingPath: preservingPath,
      maximumEntries: maximumEntries,
      maximumBytes: maximumBytes,
    );
  }

  static String cacheIdentity({
    required String sourcePath,
    required String sourceFingerprint,
    required Duration sourceStart,
    required Duration sourceDuration,
    required int audioStreamIndex,
    required int width,
    required int height,
  }) {
    final payload = jsonEncode({
      'version': 1,
      'sourcePath': sourcePath,
      'sourceFingerprint': sourceFingerprint,
      'sourceStartUs': sourceStart.inMicroseconds,
      'sourceDurationUs': sourceDuration.inMicroseconds,
      'audioStreamIndex': audioStreamIndex,
      'width': width,
      'height': height,
    });
    return sha256.convert(utf8.encode(payload)).toString();
  }

  static Future<Directory> _defaultDirectory() async {
    final temporary = await getTemporaryDirectory();
    return Directory(p.join(temporary.path, 'caption_craft_waveforms_v1'));
  }

  static Future<String> _sourceFingerprint(String path) async {
    try {
      final stat = await File(path).stat();
      return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    } catch (_) {
      return 'missing';
    }
  }

  static Future<bool> _generate({
    required String sourcePath,
    required String outputPath,
    required Duration sourceStart,
    required Duration sourceDuration,
    required int audioStreamIndex,
    required int width,
    required int height,
  }) async {
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-ss',
      _seconds(sourceStart),
      '-t',
      _seconds(sourceDuration),
      '-i',
      sourcePath,
      '-map',
      '0:a:$audioStreamIndex',
      '-filter_complex',
      'showwavespic=s=${width}x$height:colors=white',
      '-frames:v',
      '1',
      outputPath,
    ]);
    return ReturnCode.isSuccess(await session.getReturnCode());
  }

  static String _seconds(Duration duration) {
    return (duration.inMicroseconds / Duration.microsecondsPerSecond)
        .toStringAsFixed(6);
  }
}
