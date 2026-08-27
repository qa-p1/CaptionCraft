import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/editor/models/timeline_models.dart';
import 'timeline_media_cache_pruner.dart';

typedef ProxyMediaGenerator =
    Future<bool> Function({
      required String sourcePath,
      required String outputPath,
      required int maximumDimension,
      required int maximumFrameRate,
    });

class TimelineProxyMediaResult {
  final String path;
  final String sourcePath;
  final String identity;
  final String sourceFingerprint;
  final int maximumDimension;
  final int maximumFrameRate;

  const TimelineProxyMediaResult({
    required this.path,
    required this.sourcePath,
    required this.identity,
    required this.sourceFingerprint,
    required this.maximumDimension,
    required this.maximumFrameRate,
  });

  Map<String, dynamic> toMetadata() => {
    'version': 2,
    'path': path,
    'sourcePath': sourcePath,
    'identity': identity,
    'sourceFingerprint': sourceFingerprint,
    'maximumDimension': maximumDimension,
    'maximumFrameRate': maximumFrameRate,
  };
}

/// Generates genuine per-source editing proxies.
///
/// These files are independent of the dense-composition preview cache: one
/// proxy represents one source asset and is never used by final export.
class TimelineProxyMediaService {
  static final TimelineProxyMediaService instance = TimelineProxyMediaService();

  final Future<Directory> Function() _directoryProvider;
  final Future<String> Function(String path) _fingerprintResolver;
  final ProxyMediaGenerator _generator;
  final int maximumEntries;
  final int maximumBytes;
  final Map<String, Future<TimelineProxyMediaResult?>> _inFlight = {};
  final Map<String, int> _sourceGenerations = {};
  Future<void> _generationTail = Future<void>.value();

  TimelineProxyMediaService({
    Future<Directory> Function()? directoryProvider,
    Future<String> Function(String path)? fingerprintResolver,
    ProxyMediaGenerator? generator,
    this.maximumEntries = 32,
    this.maximumBytes = 2 * 1024 * 1024 * 1024,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _fingerprintResolver = fingerprintResolver ?? sourceFingerprint,
       _generator = generator ?? _generate;

  Future<TimelineProxyMediaResult?> ensureProxy(
    EditorAssetReference asset, {
    int maximumDimension = 960,
    int maximumFrameRate = 30,
  }) async {
    final sourcePath = asset.sourcePath?.trim();
    if (sourcePath == null || sourcePath.isEmpty) return null;
    final safeDimension = maximumDimension.clamp(360, 1920).toInt();
    final safeFrameRate = maximumFrameRate.clamp(12, 60).toInt();
    final fingerprint = await _fingerprintResolver(sourcePath);
    if (fingerprint == 'missing') return null;
    final identity = cacheIdentity(
      sourcePath: sourcePath,
      sourceFingerprint: fingerprint,
      maximumDimension: safeDimension,
      maximumFrameRate: safeFrameRate,
    );
    final existing = _inFlight[identity];
    if (existing != null) return existing;
    final operation = _enqueue(
      sourcePath: sourcePath,
      sourceFingerprint: fingerprint,
      identity: identity,
      maximumDimension: safeDimension,
      maximumFrameRate: safeFrameRate,
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

  void cancelSource(String sourcePath) {
    final normalized = sourcePath.trim();
    _sourceGenerations[normalized] = (_sourceGenerations[normalized] ?? 0) + 1;
  }

  Future<TimelineProxyMediaResult?> _enqueue({
    required String sourcePath,
    required String sourceFingerprint,
    required String identity,
    required int maximumDimension,
    required int maximumFrameRate,
  }) {
    final generation = _sourceGenerations[sourcePath] ?? 0;
    final operation = _generationTail.then((_) async {
      final directory = await _directoryProvider();
      if (!await directory.exists()) await directory.create(recursive: true);
      final output = File(p.join(directory.path, '$identity.mp4'));
      if (await output.exists() && await output.length() > 0) {
        try {
          await output.setLastModified(DateTime.now());
        } catch (_) {}
        await _prune(directory, preservingPath: output.path);
        return TimelineProxyMediaResult(
          path: output.path,
          sourcePath: sourcePath,
          identity: identity,
          sourceFingerprint: sourceFingerprint,
          maximumDimension: maximumDimension,
          maximumFrameRate: maximumFrameRate,
        );
      }
      final partial = File(
        p.join(
          directory.path,
          '$identity.${DateTime.now().microsecondsSinceEpoch}.partial.mp4',
        ),
      );
      try {
        final generated = await _generator(
          sourcePath: sourcePath,
          outputPath: partial.path,
          maximumDimension: maximumDimension,
          maximumFrameRate: maximumFrameRate,
        );
        final cancelled = (_sourceGenerations[sourcePath] ?? 0) != generation;
        if (!generated ||
            cancelled ||
            !await partial.exists() ||
            await partial.length() == 0) {
          return null;
        }
        if (await output.exists()) await output.delete();
        await partial.rename(output.path);
        await _prune(directory, preservingPath: output.path);
        return TimelineProxyMediaResult(
          path: output.path,
          sourcePath: sourcePath,
          identity: identity,
          sourceFingerprint: sourceFingerprint,
          maximumDimension: maximumDimension,
          maximumFrameRate: maximumFrameRate,
        );
      } finally {
        if (await partial.exists()) {
          try {
            await partial.delete();
          } catch (_) {}
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
          RegExp(r'^[0-9a-f]{64}\.mp4$').hasMatch(p.basename(file.path)),
      preservingPath: preservingPath,
      maximumEntries: maximumEntries,
      maximumBytes: maximumBytes,
    );
  }

  static String? validProxyPath(
    EditorAssetReference asset, {
    required bool Function(String path) fileExists,
    required String Function(String path) sourceFingerprintSync,
  }) {
    final proxy = asset.metadata['proxyMedia'];
    if (proxy is! Map) return null;
    final path = proxy['path'];
    final storedFingerprint = proxy['sourceFingerprint'];
    if (path is! String || path.isEmpty || !fileExists(path)) return null;
    final sourcePath = asset.sourcePath?.trim();
    final storedSourcePath = proxy['sourcePath'];
    if (storedSourcePath is String &&
        storedSourcePath.trim().isNotEmpty &&
        (sourcePath == null ||
            sourcePath.isEmpty ||
            !_sameSourcePath(storedSourcePath, sourcePath))) {
      return null;
    }
    if (sourcePath == null || sourcePath.isEmpty || !fileExists(sourcePath)) {
      // A proxy keeps an offline project previewable, but export still resolves
      // the original and will report it missing.
      return path;
    }
    if (storedFingerprint is! String ||
        storedFingerprint != sourceFingerprintSync(sourcePath)) {
      return null;
    }
    return path;
  }

  static bool resultMatchesAsset(
    TimelineProxyMediaResult result,
    EditorAssetReference asset, {
    String Function(String path)? sourceFingerprintSync,
  }) {
    final sourcePath = asset.sourcePath?.trim();
    if (sourcePath == null ||
        sourcePath.isEmpty ||
        !_sameSourcePath(result.sourcePath, sourcePath)) {
      return false;
    }
    return result.sourceFingerprint ==
        (sourceFingerprintSync ??
            TimelineProxyMediaService.sourceFingerprintSync)(sourcePath);
  }

  static Map<String, dynamic> metadataAfterSourceRelink({
    required Map<String, dynamic> previousMetadata,
    required Map<String, dynamic> mediaInfo,
  }) {
    return <String, dynamic>{...previousMetadata, ...mediaInfo}
      ..remove('proxyMedia');
  }

  static bool _sameSourcePath(String first, String second) {
    String key(String value) {
      final normalized = p.normalize(p.absolute(value.trim()));
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    return key(first) == key(second);
  }

  static String cacheIdentity({
    required String sourcePath,
    required String sourceFingerprint,
    required int maximumDimension,
    required int maximumFrameRate,
  }) {
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'sourcePath': sourcePath,
              'sourceFingerprint': sourceFingerprint,
              'maximumDimension': maximumDimension,
              'maximumFrameRate': maximumFrameRate,
              'videoCodec': 'h264',
              'audio': 'aac-48000-stereo',
            }),
          ),
        )
        .toString();
  }

  static Future<String> sourceFingerprint(String path) async {
    try {
      final stat = await File(path).stat();
      return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    } catch (_) {
      return 'missing';
    }
  }

  static String sourceFingerprintSync(String path) {
    try {
      final stat = File(path).statSync();
      return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    } catch (_) {
      return 'missing';
    }
  }

  static Future<Directory> _defaultDirectory() async {
    final temporary = await getTemporaryDirectory();
    return Directory(p.join(temporary.path, 'caption_craft_source_proxies_v1'));
  }

  static Future<bool> _generate({
    required String sourcePath,
    required String outputPath,
    required int maximumDimension,
    required int maximumFrameRate,
  }) async {
    final scale =
        "scale='if(gte(iw,ih),min(iw,$maximumDimension),-2)':"
        "'if(gte(iw,ih),-2,min(ih,$maximumDimension))',"
        'fps=$maximumFrameRate';
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-i',
      sourcePath,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-vf',
      scale,
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '28',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      '-ar',
      '48000',
      '-ac',
      '2',
      '-movflags',
      '+faststart',
      outputPath,
    ]);
    return ReturnCode.isSuccess(await session.getReturnCode());
  }
}
