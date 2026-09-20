import 'dart:async';
import 'dart:io';

import 'package:caption_craft/core/utils/ffmpeg_service.dart';
import 'package:caption_craft/core/utils/media_job.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:caption_craft/features/home/providers/transcription_pipeline.dart';
import 'package:caption_craft/shared/models/processing_state.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio chunk ranges include subsecond tails and the full overlap', () {
    final ranges = FFmpegService.audioChunkRanges(
      const Duration(milliseconds: 600750),
    );
    expect(ranges, [
      (start: Duration.zero, end: const Duration(seconds: 600)),
      (
        start: const Duration(seconds: 597),
        end: const Duration(milliseconds: 600750),
      ),
    ]);
    expect(FFmpegService.audioChunkRanges(const Duration(milliseconds: 500)), [
      (start: Duration.zero, end: const Duration(milliseconds: 500)),
    ]);
    expect(
      () => FFmpegService.audioChunkRanges(Duration.zero),
      throwsArgumentError,
    );
  });
  late Directory root;
  late _Backend backend;
  late TranscriptionPipeline pipeline;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('transcription-lifecycle-');
    backend = _Backend(root);
    pipeline = TranscriptionPipeline(backend: backend);
  });
  tearDown(() async {
    pipeline.dispose();
    await root.delete(recursive: true);
  });

  test('cancel stops only this probe and suppresses late results', () async {
    backend.probeGate = Completer<void>();
    final unrelated = MediaJob();
    var unrelatedCancelled = false;
    await unrelated.attach(99, () async => unrelatedCancelled = true);
    final work = pipeline.transcribeVideoSegment(videoPath: 'source.mp4');
    await backend.probeStarted.future;
    pipeline.cancel();
    backend.probeGate!.complete();
    expect(await work, isNull);
    expect(backend.cancelledProbes, 1);
    expect(unrelatedCancelled, isFalse);
    expect(backend.extractedDuration, isNull);
  });

  test(
    'segment ends at source boundary and temporary audio is removed',
    () async {
      final result = await pipeline.transcribeVideoSegment(
        videoPath: 'source.mp4',
        startTime: const Duration(milliseconds: 8500),
        clipDuration: const Duration(seconds: 5),
      );
      expect(result, isNotEmpty);
      expect(backend.extractedDuration, const Duration(milliseconds: 1750));
      expect(await Directory(root.path).list().toList(), isEmpty);
    },
  );

  test('invalid source ranges fail before extraction', () async {
    for (final start in [
      const Duration(seconds: -1),
      const Duration(seconds: 11),
    ]) {
      await expectLater(
        pipeline.transcribeVideoSegment(
          videoPath: 'source.mp4',
          startTime: start,
        ),
        throwsArgumentError,
      );
    }
    await expectLater(
      pipeline.transcribeVideoSegment(
        videoPath: 'source.mp4',
        clipDuration: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(backend.extractedDuration, isNull);
  });

  test(
    'overlapping runs cannot reset cancellation of the first operation',
    () async {
      backend.probeGate = Completer<void>();
      final work = pipeline.transcribeVideoSegment(videoPath: 'source.mp4');
      await backend.probeStarted.future;
      await expectLater(
        pipeline.transcribeVideoSegment(videoPath: 'second.mp4'),
        throwsStateError,
      );
      pipeline.cancel();
      backend.probeGate!.complete();
      expect(await work, isNull);
      backend.probeGate = null;
      expect(
        await pipeline.transcribeVideoSegment(videoPath: 'source.mp4'),
        isNotEmpty,
      );
    },
  );

  test(
    'disposing during speech request cancels it and discards completion',
    () async {
      backend.speechGate = Completer<void>();
      final work = pipeline.transcribeVideoSegment(videoPath: 'source.mp4');
      await backend.speechStarted.future;
      pipeline.dispose();
      expect(backend.token!.isCancelled, isTrue);
      backend.speechGate!.complete();
      expect(await work, isNull);
      expect(await root.list().toList(), isEmpty);
      await expectLater(
        pipeline.transcribeVideoSegment(videoPath: 'source.mp4'),
        throwsStateError,
      );
    },
  );

  test(
    'cancel during final thumbnail does not publish a completed project',
    () async {
      backend.thumbnailGate = Completer<void>();
      final stages = <ProcessingStage>[];
      final subscription = pipeline.progressStream.listen(
        (event) => stages.add(event.stage),
      );
      addTearDown(subscription.cancel);
      final work = pipeline.run(videoPath: 'source.mp4', uid: 'owner');
      await backend.thumbnailStarted.future;
      pipeline.cancel();
      backend.thumbnailGate!.complete();
      expect(await work, isNull);
      expect(stages, isNot(contains(ProcessingStage.done)));
      expect(await root.list().toList(), isEmpty);
    },
  );
}

class _Backend extends TranscriptionBackend {
  _Backend(this.root);
  final Directory root;
  Completer<void>? probeGate;
  Completer<void>? speechGate;
  Completer<void>? thumbnailGate;
  final probeStarted = Completer<void>();
  final speechStarted = Completer<void>();
  final thumbnailStarted = Completer<void>();
  int cancelledProbes = 0;
  Duration? extractedDuration;
  CancelToken? token;

  @override
  void ensureConfigured() {}
  @override
  Future<Map<String, dynamic>> probe(String path, MediaJob job) async {
    await job.attach(1, () async {
      cancelledProbes++;
    });
    if (!probeStarted.isCompleted) probeStarted.complete();
    await probeGate?.future;
    job.detach(1);
    return {'durationMs': 10250, 'hasAudio': true};
  }

  @override
  Future<String> extract(
    String path,
    Duration start,
    Duration duration,
    MediaJob job,
    void Function(double) progress,
  ) async {
    job.checkCancelled();
    extractedDuration = duration;
    final output = File('${root.path}/audio.flac');
    await output.writeAsBytes([1, 2, 3]);
    return output.path;
  }

  @override
  Future<List<AudioChunk>> chunks(
    String path,
    Duration duration,
    MediaJob job,
  ) async => [
    AudioChunk(
      index: 0,
      startTime: Duration.zero,
      endTime: duration,
      filePath: path,
    ),
  ];
  @override
  Future<List<WordTiming>> transcribe(
    AudioChunk chunk,
    String language,
    CancelToken token,
  ) async {
    this.token = token;
    if (!speechStarted.isCompleted) speechStarted.complete();
    await speechGate?.future;
    return [
      WordTiming(
        word: 'Hello',
        startTime: const Duration(milliseconds: 100),
        endTime: const Duration(milliseconds: 400),
      ),
    ];
  }

  @override
  Future<String> thumbnail(String path, MediaJob job) async {
    thumbnailStarted.complete();
    await thumbnailGate?.future;
    final output = File('${root.path}/thumbnail.jpg');
    await output.writeAsBytes([1, 2, 3]);
    return output.path;
  }
}
