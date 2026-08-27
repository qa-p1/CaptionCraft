import 'dart:io';

import 'package:caption_craft/core/utils/timeline_waveform_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cache identity includes source version, window, stream and density',
    () {
      String identity({
        String fingerprint = '100:1',
        int startMs = 0,
        int durationMs = 1000,
        int stream = 0,
        int width = 512,
      }) {
        return TimelineWaveformCache.cacheIdentity(
          sourcePath: '/media/audio.m4a',
          sourceFingerprint: fingerprint,
          sourceStart: Duration(milliseconds: startMs),
          sourceDuration: Duration(milliseconds: durationMs),
          audioStreamIndex: stream,
          width: width,
          height: 72,
        );
      }

      final baseline = identity();
      expect(identity(), baseline);
      expect(identity(fingerprint: '100:2'), isNot(baseline));
      expect(identity(startMs: 1), isNot(baseline));
      expect(identity(durationMs: 999), isNot(baseline));
      expect(identity(stream: 1), isNot(baseline));
      expect(identity(width: 1024), isNot(baseline));
    },
  );

  test('identical concurrent waveform requests render only once', () async {
    final directory = await Directory.systemTemp.createTemp(
      'caption_craft_waveform_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    var generations = 0;
    final cache = TimelineWaveformCache(
      directoryProvider: () async => directory,
      fingerprintResolver: (_) async => 'fixture-v1',
      generator:
          ({
            required sourcePath,
            required outputPath,
            required sourceStart,
            required sourceDuration,
            required audioStreamIndex,
            required width,
            required height,
          }) async {
            generations++;
            await File(outputPath).writeAsBytes([1, 2, 3, 4]);
            return true;
          },
    );

    final requests = [
      for (var index = 0; index < 12; index++)
        cache.waveformFor(
          sourcePath: '/fixtures/audio.m4a',
          sourceStart: const Duration(milliseconds: 250),
          sourceDuration: const Duration(seconds: 2),
          width: 800,
        ),
    ];
    final results = await Future.wait(requests);

    expect(generations, 1);
    expect(results.toSet(), hasLength(1));
    expect(await File(results.first).readAsBytes(), [1, 2, 3, 4]);

    final cached = await cache.waveformFor(
      sourcePath: '/fixtures/audio.m4a',
      sourceStart: const Duration(milliseconds: 250),
      sourceDuration: const Duration(seconds: 2),
      width: 800,
    );
    expect(cached, results.first);
    expect(generations, 1);
  });

  test('source invalidation and bounded cleanup are deterministic', () async {
    final directory = await Directory.systemTemp.createTemp(
      'caption_craft_waveform_bound_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    var version = 1;
    var generations = 0;
    final cache = TimelineWaveformCache(
      directoryProvider: () async => directory,
      fingerprintResolver: (_) async => 'fixture-v$version',
      maximumEntries: 2,
      maximumBytes: 1024,
      generator:
          ({
            required sourcePath,
            required outputPath,
            required sourceStart,
            required sourceDuration,
            required audioStreamIndex,
            required width,
            required height,
          }) async {
            generations++;
            await File(outputPath).writeAsBytes(List.filled(16, generations));
            return true;
          },
    );

    final first = await cache.waveformFor(
      sourcePath: '/fixtures/audio.m4a',
      sourceStart: Duration.zero,
      sourceDuration: const Duration(seconds: 1),
    );
    version = 2;
    final invalidated = await cache.waveformFor(
      sourcePath: '/fixtures/audio.m4a',
      sourceStart: Duration.zero,
      sourceDuration: const Duration(seconds: 1),
    );
    await cache.waveformFor(
      sourcePath: '/fixtures/audio.m4a',
      sourceStart: const Duration(seconds: 1),
      sourceDuration: const Duration(seconds: 1),
    );

    expect(first, isNot(invalidated));
    expect(generations, 3);
    final cachedFiles = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.png'))
        .toList();
    expect(cachedFiles.length, lessThanOrEqualTo(2));
  });

  test(
    'cancelled source generation never commits its partial output',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'caption_craft_waveform_cancel_test_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      late TimelineWaveformCache cache;
      cache = TimelineWaveformCache(
        directoryProvider: () async => directory,
        fingerprintResolver: (_) async => 'fixture-v1',
        generator:
            ({
              required sourcePath,
              required outputPath,
              required sourceStart,
              required sourceDuration,
              required audioStreamIndex,
              required width,
              required height,
            }) async {
              await File(outputPath).writeAsBytes([1]);
              cache.cancelSource(sourcePath);
              return true;
            },
      );

      final result = await cache.waveformFor(
        sourcePath: '/fixtures/cancel.m4a',
        sourceStart: Duration.zero,
        sourceDuration: const Duration(seconds: 1),
      );

      expect(result, isEmpty);
      expect(directory.listSync().whereType<File>(), isEmpty);
    },
  );
}
