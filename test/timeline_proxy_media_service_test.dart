import 'dart:io';

import 'package:caption_craft/core/utils/timeline_proxy_media_service.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  EditorAssetReference asset(String path) => EditorAssetReference(
    id: 'source-video',
    type: EditorAssetType.video,
    label: 'Source video',
    sourcePath: path,
  );

  test('proxy identity includes source version and encoding profile', () {
    String identity({
      String fingerprint = '100:1',
      int dimension = 960,
      int frameRate = 30,
    }) => TimelineProxyMediaService.cacheIdentity(
      sourcePath: '/media/source.mp4',
      sourceFingerprint: fingerprint,
      maximumDimension: dimension,
      maximumFrameRate: frameRate,
    );

    final baseline = identity();
    expect(identity(), baseline);
    expect(identity(fingerprint: '100:2'), isNot(baseline));
    expect(identity(dimension: 720), isNot(baseline));
    expect(identity(frameRate: 24), isNot(baseline));
  });

  test('identical requests share one generated source proxy', () async {
    final directory = await Directory.systemTemp.createTemp(
      'caption_craft_proxy_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    var generations = 0;
    final service = TimelineProxyMediaService(
      directoryProvider: () async => directory,
      fingerprintResolver: (_) async => 'fixture-v1',
      generator:
          ({
            required sourcePath,
            required outputPath,
            required maximumDimension,
            required maximumFrameRate,
          }) async {
            generations++;
            await File(outputPath).writeAsBytes([1, 2, 3]);
            return true;
          },
    );

    final results = await Future.wait([
      for (var index = 0; index < 10; index++)
        service.ensureProxy(asset('/fixtures/source.mp4')),
    ]);
    expect(generations, 1);
    expect(results.whereType<TimelineProxyMediaResult>(), hasLength(10));
    expect(results.map((result) => result?.path).toSet(), hasLength(1));

    final cached = await service.ensureProxy(asset('/fixtures/source.mp4'));
    expect(cached?.path, results.first?.path);
    expect(generations, 1);
    expect(cached?.toMetadata()['sourceFingerprint'], 'fixture-v1');
    expect(cached?.toMetadata()['sourcePath'], '/fixtures/source.mp4');
  });

  test('source changes invalidate proxies and cache remains bounded', () async {
    final directory = await Directory.systemTemp.createTemp(
      'caption_craft_proxy_bound_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    var version = 1;
    final service = TimelineProxyMediaService(
      directoryProvider: () async => directory,
      fingerprintResolver: (_) async => 'fixture-v$version',
      maximumEntries: 2,
      maximumBytes: 1024,
      generator:
          ({
            required sourcePath,
            required outputPath,
            required maximumDimension,
            required maximumFrameRate,
          }) async {
            await File(outputPath).writeAsBytes(List.filled(24, version));
            return true;
          },
    );

    final first = await service.ensureProxy(asset('/fixtures/source.mp4'));
    version = 2;
    final second = await service.ensureProxy(asset('/fixtures/source.mp4'));
    version = 3;
    await service.ensureProxy(asset('/fixtures/source.mp4'));

    expect(first?.path, isNot(second?.path));
    expect(
      directory.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.mp4'),
      ),
      hasLength(2),
    );
  });

  test('cancelled proxy output is not committed', () async {
    final directory = await Directory.systemTemp.createTemp(
      'caption_craft_proxy_cancel_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    late TimelineProxyMediaService service;
    service = TimelineProxyMediaService(
      directoryProvider: () async => directory,
      fingerprintResolver: (_) async => 'fixture-v1',
      generator:
          ({
            required sourcePath,
            required outputPath,
            required maximumDimension,
            required maximumFrameRate,
          }) async {
            await File(outputPath).writeAsBytes([1]);
            service.cancelSource(sourcePath);
            return true;
          },
    );

    final result = await service.ensureProxy(asset('/fixtures/source.mp4'));
    expect(result, isNull);
    expect(directory.listSync().whereType<File>(), isEmpty);
  });

  test('persisted proxy validation handles offline and relinked sources', () {
    final proxied = asset('/media/source.mp4').copyWith(
      metadata: const {
        'proxyMedia': {
          'path': '/cache/proxy.mp4',
          'sourceFingerprint': 'fixture-v1',
        },
      },
    );
    expect(
      TimelineProxyMediaService.validProxyPath(
        proxied,
        fileExists: (path) => path == '/cache/proxy.mp4',
        sourceFingerprintSync: (_) => 'missing',
      ),
      '/cache/proxy.mp4',
    );
    expect(
      TimelineProxyMediaService.validProxyPath(
        proxied,
        fileExists: (_) => true,
        sourceFingerprintSync: (_) => 'fixture-v2',
      ),
      isNull,
    );

    final sourceBoundProxy = proxied.copyWith(
      sourcePath: '/media/relinked.mp4',
      metadata: const {
        'proxyMedia': {
          'path': '/cache/proxy.mp4',
          'sourcePath': '/media/source.mp4',
          'sourceFingerprint': 'fixture-v1',
        },
      },
    );
    expect(
      TimelineProxyMediaService.validProxyPath(
        sourceBoundProxy,
        fileExists: (path) => path == '/cache/proxy.mp4',
        sourceFingerprintSync: (_) => 'missing',
      ),
      isNull,
    );
  });

  test('stale proxy results and relink metadata are rejected', () {
    const result = TimelineProxyMediaResult(
      path: '/cache/proxy.mp4',
      sourcePath: '/media/source.mp4',
      identity: 'proxy-id',
      sourceFingerprint: 'fixture-v1',
      maximumDimension: 960,
      maximumFrameRate: 30,
    );
    expect(
      TimelineProxyMediaService.resultMatchesAsset(
        result,
        asset('/media/source.mp4'),
        sourceFingerprintSync: (_) => 'fixture-v1',
      ),
      isTrue,
    );
    expect(
      TimelineProxyMediaService.resultMatchesAsset(
        result,
        asset('/media/relinked.mp4'),
        sourceFingerprintSync: (_) => 'fixture-v1',
      ),
      isFalse,
    );
    expect(
      TimelineProxyMediaService.metadataAfterSourceRelink(
        previousMetadata: const {
          'width': 1920,
          'proxyMedia': {'path': '/cache/proxy.mp4'},
        },
        mediaInfo: const {'width': 1280, 'height': 720},
      ),
      {'width': 1280, 'height': 720},
    );
  });
}
