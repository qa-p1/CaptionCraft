import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:caption_craft/core/utils/discover_media_import_service.dart';
import 'package:caption_craft/features/editor/models/discover_models.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DiscoverMediaImportService', () {
    test('normalizes an unsupported still to an editor-ready PNG', () async {
      final fixture = await _fixture('poster.avif');
      final backend = _FakeImportBackend(<DiscoverMediaProbeResult>[
        _imageProbe(videoCodec: 'av1'),
        _imageProbe(videoCodec: 'png'),
      ]);
      final service = DiscoverMediaImportService(
        documentsDirectoryOverride: fixture.documents,
        backend: backend,
        clock: () => DateTime.utc(2026, 8, 12),
        jobIdGenerator: () => 'image-job',
      );
      addTearDown(service.dispose);

      final result = await service.importDownload(
        _item(fixture.source, DiscoverMediaKind.image, mimeType: 'image/avif'),
      );

      expect(backend.transcodes, <DiscoverTranscodeKind>[
        DiscoverTranscodeKind.imageToPng,
      ]);
      expect(result.path, endsWith('.png'));
      expect(result.assetType, EditorAssetType.image);
      expect(result.clipType, TimelineTrackType.image);
      expect(result.mimeType, 'image/png');
      expect(result.wasTranscoded, isTrue);
      expect(result.duration, isNull);
      expect(result.width, 1440);
      expect(await File(result.path).exists(), isTrue);
      expect(result.metadata['discoverDownloadId'], 'download-id');
      expect(await File('${result.path}.part').exists(), isFalse);
    });

    test('transcodes VP9 WebM to H.264/AAC MP4 with clip metadata', () async {
      final fixture = await _fixture('movie.webm');
      final backend = _FakeImportBackend(<DiscoverMediaProbeResult>[
        _videoProbe(videoCodec: 'vp9', audioCodec: 'opus'),
        _videoProbe(videoCodec: 'h264', audioCodec: 'aac'),
      ]);
      final service = DiscoverMediaImportService(
        documentsDirectoryOverride: fixture.documents,
        backend: backend,
        jobIdGenerator: () => 'video-job',
      );
      addTearDown(service.dispose);

      final result = await service.importDownload(
        _item(fixture.source, DiscoverMediaKind.video, mimeType: 'video/webm'),
      );

      expect(backend.transcodes, <DiscoverTranscodeKind>[
        DiscoverTranscodeKind.videoToMp4,
      ]);
      expect(result.path, endsWith('.mp4'));
      expect(result.assetType, EditorAssetType.video);
      expect(result.clipType, TimelineTrackType.video);
      expect(result.duration, const Duration(seconds: 12));
      expect(result.videoCodec, 'h264');
      expect(result.audioCodec, 'aac');
      expect(result.metadata['durationMs'], 12000);
    });

    test('copies an already-safe image without invoking FFmpeg', () async {
      final fixture = await _fixture('photo.jpg');
      final backend = _FakeImportBackend(<DiscoverMediaProbeResult>[
        _imageProbe(videoCodec: 'mjpeg'),
        _imageProbe(videoCodec: 'mjpeg'),
      ]);
      final service = DiscoverMediaImportService(
        documentsDirectoryOverride: fixture.documents,
        backend: backend,
        jobIdGenerator: () => 'copy-job',
      );
      addTearDown(service.dispose);

      final result = await service.importDownload(
        _item(fixture.source, DiscoverMediaKind.image, mimeType: 'image/jpeg'),
      );

      expect(backend.transcodes, isEmpty);
      expect(result.path, endsWith('.jpg'));
      expect(result.wasTranscoded, isFalse);
      expect(
        await File(result.path).readAsBytes(),
        await fixture.source.readAsBytes(),
      );
    });

    test(
      'uses detected GIF MIME when the download has a fallback jpg name',
      () async {
        final fixture = await _fixture('extensionless-fallback.jpg');
        final backend = _FakeImportBackend(<DiscoverMediaProbeResult>[
          _gifProbe(),
          _gifProbe(),
        ]);
        final service = DiscoverMediaImportService(
          documentsDirectoryOverride: fixture.documents,
          backend: backend,
          jobIdGenerator: () => 'gif-job',
        );
        addTearDown(service.dispose);

        final result = await service.importDownload(
          _item(fixture.source, DiscoverMediaKind.image, mimeType: 'image/gif'),
        );

        expect(backend.transcodes, isEmpty);
        expect(result.path, endsWith('.gif'));
        expect(result.mimeType, 'image/gif');
        expect(result.assetType, EditorAssetType.gif);
        expect(result.clipType, TimelineTrackType.gif);
        expect(result.duration, const Duration(seconds: 2));
      },
    );

    test('rejects a catalog path outside managed Discover storage', () async {
      final fixture = await _fixture('inside.png');
      final outside = File(p.join(fixture.documents.path, 'outside.png'));
      await outside.writeAsBytes(const <int>[1, 2, 3], flush: true);
      final service = DiscoverMediaImportService(
        documentsDirectoryOverride: fixture.documents,
        backend: _FakeImportBackend(<DiscoverMediaProbeResult>[]),
      );
      addTearDown(service.dispose);

      await expectLater(
        service.importDownload(_item(outside, DiscoverMediaKind.image)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('outside managed'),
          ),
        ),
      );
    });

    test('cancels a job-local transcode and cleans its partial file', () async {
      final fixture = await _fixture('cancel.webm');
      final backend = _BlockingImportBackend(_videoProbe(videoCodec: 'vp9'));
      final service = DiscoverMediaImportService(
        documentsDirectoryOverride: fixture.documents,
        backend: backend,
      );
      addTearDown(service.dispose);

      final import = service.importDownload(
        _item(fixture.source, DiscoverMediaKind.video),
        jobId: 'cancel-job',
      );
      await backend.started.future.timeout(const Duration(seconds: 2));
      await service.cancel('cancel-job');

      await expectLater(
        import,
        throwsA(isA<DiscoverMediaImportCancelledException>()),
      );
      final media = Directory(
        p.join(fixture.documents.path, 'CaptionCraft', 'media'),
      );
      final files = await media
          .list()
          .where((entity) => entity is File)
          .toList();
      expect(files, isEmpty);
    });
  });
}

Future<({Directory documents, File source})> _fixture(String fileName) async {
  final documents = await Directory.systemTemp.createTemp(
    'discover_import_test_',
  );
  final downloads = Directory(
    p.join(documents.path, 'CaptionCraft', 'discover_downloads'),
  );
  await downloads.create(recursive: true);
  final source = File(p.join(downloads.path, fileName));
  await source.writeAsBytes(const <int>[1, 2, 3, 4, 5], flush: true);
  addTearDown(() async {
    if (await documents.exists()) await documents.delete(recursive: true);
  });
  return (documents: documents, source: source);
}

DiscoverDownloadItem _item(
  File source,
  DiscoverMediaKind kind, {
  String? mimeType,
}) {
  final now = DateTime.utc(2026, 8, 12);
  return DiscoverDownloadItem(
    id: 'download-id',
    source: DiscoverDownloadSource.direct,
    status: DiscoverDownloadStatus.completed,
    sourceUrl: 'https://cdn.example.test/${p.basename(source.path)}',
    displayName: p.basename(source.path),
    fileName: p.basename(source.path),
    localPath: source.path,
    mimeType: mimeType,
    kind: kind,
    receivedBytes: 5,
    totalBytes: 5,
    createdAt: now,
    updatedAt: now,
  );
}

DiscoverMediaProbeResult _imageProbe({String? videoCodec}) {
  return DiscoverMediaProbeResult(
    duration: Duration.zero,
    width: 1440,
    height: 900,
    frameRate: 0,
    hasVideo: true,
    hasAudio: false,
    fileSize: 5,
    videoCodec: videoCodec,
  );
}

DiscoverMediaProbeResult _videoProbe({
  required String videoCodec,
  String? audioCodec = 'aac',
}) {
  return DiscoverMediaProbeResult(
    duration: const Duration(seconds: 12),
    width: 1920,
    height: 1080,
    frameRate: 30,
    hasVideo: true,
    hasAudio: audioCodec != null,
    fileSize: 5,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
  );
}

DiscoverMediaProbeResult _gifProbe() {
  return const DiscoverMediaProbeResult(
    duration: Duration(seconds: 2),
    width: 640,
    height: 360,
    frameRate: 12,
    hasVideo: true,
    hasAudio: false,
    fileSize: 5,
    videoCodec: 'gif',
  );
}

class _FakeImportBackend implements DiscoverMediaImportBackend {
  _FakeImportBackend(Iterable<DiscoverMediaProbeResult> probes)
    : _probes = ListQueue<DiscoverMediaProbeResult>.from(probes);

  final ListQueue<DiscoverMediaProbeResult> _probes;
  final List<DiscoverTranscodeKind> transcodes = <DiscoverTranscodeKind>[];

  @override
  Future<DiscoverMediaProbeResult> probe(String path) async =>
      _probes.removeFirst();

  @override
  Future<void> transcode({
    required String jobId,
    required DiscoverTranscodeKind kind,
    required String inputPath,
    required String outputPath,
    required Duration sourceDuration,
    void Function(double progress)? onProgress,
  }) async {
    transcodes.add(kind);
    await File(outputPath).writeAsBytes(const <int>[9, 8, 7], flush: true);
    onProgress?.call(1);
  }

  @override
  Future<void> cancel(String jobId) async {}
}

class _BlockingImportBackend implements DiscoverMediaImportBackend {
  _BlockingImportBackend(this.sourceProbe);

  final DiscoverMediaProbeResult sourceProbe;
  final Completer<void> started = Completer<void>();
  final Completer<void> _cancelled = Completer<void>();

  @override
  Future<DiscoverMediaProbeResult> probe(String path) async => sourceProbe;

  @override
  Future<void> transcode({
    required String jobId,
    required DiscoverTranscodeKind kind,
    required String inputPath,
    required String outputPath,
    required Duration sourceDuration,
    void Function(double progress)? onProgress,
  }) async {
    if (!started.isCompleted) started.complete();
    await _cancelled.future;
    throw const DiscoverMediaImportCancelledException();
  }

  @override
  Future<void> cancel(String jobId) async {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
