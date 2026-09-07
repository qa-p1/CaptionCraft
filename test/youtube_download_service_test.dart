import 'dart:async';
import 'dart:io';
import 'package:caption_craft/core/utils/youtube_download_service.dart';
import 'package:caption_craft/core/utils/yt_dlp_bridge.dart';
import 'package:caption_craft/features/editor/models/discover_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('youtube_service_test_');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  const format = YoutubeFormatOption(
    id: 'audio:140',
    label: 'Audio',
    kind: YoutubeDownloadKind.audioOnly,
    container: 'm4a',
    audioFormatTag: 140,
  );
  final info = YoutubeVideoInfo(
    videoId: 'jNQXAC9IVRw',
    canonicalUrl: 'https://www.youtube.com/watch?v=jNQXAC9IVRw',
    title: 'Sample',
    author: 'Sample',
    thumbnailUrl: '',
    duration: const Duration(seconds: 19),
    formats: [format],
  );

  test(
    'failed client transfers fall back to package and publish byte progress',
    () async {
      final extractor = _Extractor();
      final service = YoutubeDownloadService(
        clientFactory: _UnavailableClient.new,
        mediaExtractor: extractor,
      );
      addTearDown(service.dispose);
      final progress = <int>[];
      final result = await service.download(
        jobId: 'test',
        info: info,
        format: format,
        outputPath: '${temp.path}/audio.m4a',
        onProgress: (bytes, _) => progress.add(bytes),
        onProcessing: () {},
      );
      expect(result.totalBytes, 4);
      expect(await File(result.path).readAsBytes(), [1, 2, 3, 4]);
      expect(extractor.formats, ['140']);
      expect(progress, containsAllInOrder([0, 2, 4]));
      expect(temp.listSync().whereType<File>().length, 1);
    },
  );

  test('oversize package output is removed and never published', () async {
    final service = YoutubeDownloadService(
      clientFactory: _UnavailableClient.new,
      mediaExtractor: _Extractor(),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.download(
        jobId: 'test',
        info: info,
        format: format,
        outputPath: '${temp.path}/audio.m4a',
        maxBytes: 3,
        onProgress: (_, _) {},
        onProcessing: () {},
      ),
      throwsStateError,
    );
    expect(temp.listSync(), isEmpty);
  });

  test('cancelled fallback jobs clean partial files', () async {
    final extractor = _Extractor(waitForCancel: true);
    final service = YoutubeDownloadService(
      clientFactory: _UnavailableClient.new,
      mediaExtractor: extractor,
    );
    addTearDown(service.dispose);
    final future = service.download(
      jobId: 'cancel',
      info: info,
      format: format,
      outputPath: '${temp.path}/audio.m4a',
      onProgress: (_, _) {},
      onProcessing: () {},
    );
    final expectation = expectLater(
      future,
      throwsA(isA<YoutubeDownloadCancelledException>()),
    );
    await extractor.started.future;
    await service.cancel('cancel');
    await expectation;
    expect(temp.listSync(), isEmpty);
  });
}

class _UnavailableClient implements YoutubeExplode {
  @override
  VideoClient get videos => throw StateError('Stream client unavailable');
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Extractor implements MediaExtractor {
  _Extractor({this.waitForCancel = false});
  final bool waitForCancel;
  final formats = <String>[];
  final started = Completer<void>();
  final cancelled = Completer<void>();
  @override
  Future<Map<String, dynamic>> inspect(String url) async => {};
  @override
  Future<void> cancel(String jobId) async {
    if (!cancelled.isCompleted) cancelled.complete();
  }

  @override
  Future<void> downloadFormat({
    required String jobId,
    required String url,
    required String format,
    required String outputPath,
    required int maxBytes,
    required void Function(int, int?) onProgress,
  }) async {
    formats.add(format);
    await File(outputPath).writeAsBytes([1, 2, 3, 4]);
    started.complete();
    if (waitForCancel) {
      await cancelled.future;
      throw StateError('cancelled');
    }
    onProgress(2, 4);
    onProgress(4, 4);
  }
}
