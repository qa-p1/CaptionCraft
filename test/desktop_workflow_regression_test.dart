import 'dart:convert';
import 'dart:io';

import 'package:caption_craft/core/utils/export_output_transaction.dart';
import 'package:caption_craft/core/utils/media_job.dart';
import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/features/editor/models/export_settings.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/services/media_pool_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('job ownership', () {
    test(
      'a throwing cancellation still cancels every other session once',
      () async {
        final job = MediaJob();
        var calls = 0;
        await job.attach(
          1,
          () => throw StateError('Native cancellation failed'),
        );
        await job.attach(2, () async {
          calls++;
        });
        await expectLater(job.cancel(), throwsStateError);
        await expectLater(job.cancel(), throwsStateError);
        expect(calls, 1);
        var lateCancelled = false;
        await job.attach(3, () async {
          lateCancelled = true;
        });
        expect(lateCancelled, isTrue);
      },
    );
    test('cancel affects only owned sessions', () async {
      final export = MediaJob();
      final preview = MediaJob();
      final cancelled = <int>[];
      await export.attach(1, () async {
        cancelled.add(1);
      });
      await preview.attach(2, () async {
        cancelled.add(2);
      });
      await export.cancel();
      expect(cancelled, [1]);
      expect(export.checkCancelled, throwsA(isA<MediaJobCancelled>()));
      expect(preview.isCancelled, isFalse);
    });
    test('cancellation before allocation cancels the late session', () async {
      final job = MediaJob();
      await job.cancel();
      var cancelled = false;
      await job.attach(3, () async {
        cancelled = true;
      });
      expect(cancelled, isTrue);
    });
    test('completed sessions are detached', () async {
      final job = MediaJob();
      var cancelled = false;
      await job.attach(4, () async {
        cancelled = true;
      });
      job.detach(4);
      await job.cancel();
      expect(cancelled, isFalse);
    });
  });

  group('output transaction', () {
    late Directory root;
    late File destination;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('cc-output-test-');
      destination = File(p.join(root.path, 'existing video.mp4'));
      await destination.writeAsString('previous verified video');
    });
    tearDown(() => root.delete(recursive: true));
    test(
      'failure preserves the destination and cleans owned partials',
      () async {
        final transaction = await ExportOutputTransaction.create(
          destination.path,
          sourcePaths: [],
        );
        await File(transaction.renderPath).writeAsString('partial');
        await transaction.dispose();
        expect(await destination.readAsString(), 'previous verified video');
        expect(await transaction.directory.exists(), isFalse);
      },
    );
    test('commit replaces the destination only after verification', () async {
      final transaction = await ExportOutputTransaction.create(
        destination.path,
        sourcePaths: [],
      );
      await File(transaction.renderPath).writeAsString('new verified video');
      expect(await destination.readAsString(), 'previous verified video');
      await transaction.commit();
      await transaction.dispose();
      expect(await destination.readAsString(), 'new verified video');
      expect(await transaction.directory.exists(), isFalse);
    });
    test('empty render cannot overwrite a destination', () async {
      final transaction = await ExportOutputTransaction.create(
        destination.path,
        sourcePaths: [],
      );
      await File(transaction.renderPath).create();
      await expectLater(
        transaction.commit(),
        throwsA(isA<FileSystemException>()),
      );
      await transaction.dispose();
      expect(await destination.readAsString(), 'previous verified video');
    });
    test('source path aliases are rejected', () async {
      await expectLater(
        ExportOutputTransaction.create(
          destination.path,
          sourcePaths: [p.join(root.path, '.', p.basename(destination.path))],
        ),
        throwsA(isA<FileSystemException>()),
      );
    });
    test(
      'symbolic links cannot replace source media',
      () async {
        final link = Link(p.join(root.path, 'alias.mp4'));
        await link.create(destination.path);
        await expectLater(
          ExportOutputTransaction.create(
            link.path,
            sourcePaths: [destination.path],
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await destination.readAsString(), 'previous verified video');
      },
      skip: Platform.isWindows ? 'Symlinks require developer mode.' : false,
    );
    test(
      'external destination changes during rendering are preserved',
      () async {
        final transaction = await ExportOutputTransaction.create(
          destination.path,
          sourcePaths: [],
        );
        await File(transaction.renderPath).writeAsString('our output');
        await destination.writeAsString('someone else saved another video');
        await expectLater(
          transaction.commit(),
          throwsA(isA<FileSystemException>()),
        );
        await transaction.dispose();
        expect(
          await destination.readAsString(),
          'someone else saved another video',
        );
      },
    );
    test('a new competing destination is preserved', () async {
      await destination.delete();
      final transaction = await ExportOutputTransaction.create(
        destination.path,
        sourcePaths: [],
      );
      await File(transaction.renderPath).writeAsString('our output');
      await destination.writeAsString('other output');
      await expectLater(
        transaction.commit(),
        throwsA(isA<FileSystemException>()),
      );
      await transaction.dispose();
      expect(await destination.readAsString(), 'other output');
    });
  });

  test(
    'batch import bounds probing, deduplicates, and survives a bad file',
    () async {
      var concurrent = 0;
      var maximum = 0;
      final probed = <String>[];
      final result = await MediaPoolService.importFiles(
        [
          '/one.mp4',
          '/two.mp4',
          '/one.mp4',
          '/bad.mp4',
          '/three.mp4',
          '/existing.mp4',
        ],
        existingAssets: [
          EditorAssetReference(
            type: EditorAssetType.video,
            label: 'Existing',
            sourcePath: '/existing.mp4',
          ),
        ],
        persist: (path) async => path,
        probe: (path) async {
          concurrent++;
          if (concurrent > maximum) maximum = concurrent;
          probed.add(path);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          concurrent--;
          if (path == '/bad.mp4') throw StateError('Corrupt file');
          return {
            'width': 1920,
            'height': 1080,
            'durationMs': 10000,
            'hasAudio': true,
          };
        },
      );
      expect(maximum, 2);
      expect(probed.length, 4);
      expect(result.assets.map((asset) => asset.sourcePath), [
        '/one.mp4',
        '/two.mp4',
        '/three.mp4',
      ]);
      expect(result.failures.keys, ['/bad.mp4']);
    },
  );

  const info = {
    'width': 1920,
    'height': 1080,
    'durationMs': 10000,
    'hasAudio': true,
  };
  test('relink preserves trim, reverse, keyframes, IDs and linked audio', () {
    final before = relinkFixture();
    final after = MediaPoolService.relink(
      timeline: before,
      assetId: 'source',
      sourcePath: '/relocated.mp4',
      mediaInfo: info,
    );
    expect(
      after.tracks.map((track) => track.toJson()).toList(),
      before.tracks.map((track) => track.toJson()).toList(),
    );
    expect(after.assets.single.id, 'source');
    expect(after.assets.single.sourcePath, '/relocated.mp4');
    expect(after.assets.single.metadata.containsKey('proxyMedia'), isFalse);
  });
  test(
    'relink rejects short or incompatible footage without changing edits',
    () {
      final before = relinkFixture();
      for (final incompatible in [
        {...info, 'durationMs': 6000},
        {...info, 'width': 100},
        {...info, 'hasAudio': false},
      ]) {
        expect(
          () => MediaPoolService.relink(
            timeline: before,
            assetId: 'source',
            sourcePath: '/wrong.mp4',
            mediaInfo: incompatible,
          ),
          throwsStateError,
        );
      }
      expect(before.assets.single.sourcePath, '/offline.mp4');
    },
  );
  test('relink respects locked companions', () {
    expect(
      () => MediaPoolService.relink(
        timeline: relinkFixture(lockedAudio: true),
        assetId: 'source',
        sourcePath: '/new.mp4',
        mediaInfo: info,
      ),
      throwsStateError,
    );
  });

  final clip = TimelineClip(
    id: 'video',
    trackId: 'base',
    type: TimelineTrackType.video,
    label: 'Video',
    startTime: Duration.zero,
    endTime: const Duration(seconds: 3),
    assetId: 'asset',
  );
  final track = TimelineTrack(
    id: 'base',
    name: 'Video',
    type: TimelineTrackType.video,
    section: TimelineTrackSection.baseVideo,
    clips: [clip],
  );
  final timeline = EditorTimeline(
    tracks: [track],
    workspaceSettings: const TimelineWorkspaceSettings(
      workAreaStart: Duration(seconds: 1),
      workAreaEnd: Duration(seconds: 2),
    ),
  );
  const settings = ExportSettings(
    range: ExportRange.workArea,
    burnSubtitles: false,
  );
  test(
    'export validates both work-area boundaries and preserves timeline time',
    () {
      final range = TimelineExportService.resolveExportRange(
        timeline,
        settings,
      );
      expect(range.start, const Duration(seconds: 1));
      expect(range.duration, const Duration(seconds: 1));
      expect(timeline.duration, const Duration(seconds: 3));
      expect(
        () => TimelineExportService.resolveExportRange(
          timeline.copyWith(
            workspaceSettings: const TimelineWorkspaceSettings(
              workAreaStart: Duration(seconds: 1),
            ),
          ),
          settings,
        ),
        throwsStateError,
      );
      expect(
        () => TimelineExportService.resolveExportRange(
          timeline.copyWith(
            workspaceSettings: const TimelineWorkspaceSettings(
              workAreaStart: Duration(seconds: 1),
              workAreaEnd: Duration(seconds: 4),
            ),
          ),
          settings,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'work-area render starts at In, ends at Out, and includes audio',
    () async {
      try {
        if ((await Process.run('ffmpeg', ['-version'])).exitCode != 0) {
          markTestSkipped('FFmpeg is unavailable.');
          return;
        }
      } on ProcessException {
        markTestSkipped('FFmpeg is unavailable.');
        return;
      }
      final directory = await Directory.systemTemp.createTemp('cc-work-area-');
      addTearDown(() => directory.delete(recursive: true));
      final source = p.join(directory.path, 'source.mp4');
      final output = p.join(directory.path, 'output.mp4');
      final fixture = await Process.run('ffmpeg', [
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=c=red:size=160x90:rate=30:duration=3',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=3',
        '-vf',
        "drawbox=color=blue:t=fill:enable='gte(t,1)'",
        '-c:v',
        'libx264',
        '-c:a',
        'aac',
        '-shortest',
        source,
      ]);
      expect(fixture.exitCode, 0, reason: fixture.stderr.toString());
      final args = TimelineExportService.buildFfmpegArguments(
        timeline: timeline,
        inputs: [
          TimelineRenderInput(
            index: 0,
            trackIndex: 0,
            track: track,
            clip: clip,
            asset: EditorAssetReference(
              id: 'asset',
              type: EditorAssetType.video,
              label: 'Video',
              sourcePath: source,
            ),
            sourcePath: source,
            hasAudio: true,
          ),
        ],
        settings: settings,
        canvasSize: const ExportCanvasSize(
          width: 160,
          height: 90,
          framesPerSecond: 30,
        ),
        timelineDuration: timeline.duration,
        assPath: null,
        outputPath: output,
      );
      final result = await Process.run('ffmpeg', args);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_format',
        '-show_streams',
        '-of',
        'json',
        output,
      ]);
      expect(probe.exitCode, 0);
      final info = jsonDecode(probe.stdout as String) as Map<String, dynamic>;
      expect(
        double.parse(info['format']['duration'] as String),
        closeTo(1, 0.08),
      );
      expect(
        (info['streams'] as List).any(
          (stream) => stream['codec_type'] == 'audio',
        ),
        isTrue,
      );
      final frame = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-i',
        output,
        '-frames:v',
        '1',
        '-f',
        'rawvideo',
        '-pix_fmt',
        'rgb24',
        'pipe:1',
      ], stdoutEncoding: null);
      expect(frame.exitCode, 0);
      final pixels = frame.stdout as List<int>;
      expect(
        pixels[2],
        greaterThan(200),
        reason: 'In begins in the blue section, not the red intro.',
      );
      expect(pixels[0], lessThan(30));
    },
  );
}

EditorTimeline relinkFixture({bool lockedAudio = false}) {
  final asset = EditorAssetReference(
    id: 'source',
    type: EditorAssetType.video,
    label: 'Source',
    sourcePath: '/offline.mp4',
    metadata: {
      'width': 1920,
      'height': 1080,
      'durationMs': 10000,
      'proxyMedia': {'path': '/stale.mp4'},
    },
  );
  final video = TimelineClip(
    id: 'v',
    trackId: 'video',
    type: TimelineTrackType.video,
    label: 'Trimmed reversed video',
    assetId: asset.id,
    startTime: const Duration(seconds: 1),
    endTime: const Duration(seconds: 3),
    sourceStartTime: const Duration(seconds: 5),
    sourceDuration: const Duration(seconds: 4),
    playbackRate: 2,
    isReversed: true,
    keyframes: [
      TimelineKeyframe(
        time: const Duration(seconds: 1),
        property: TimelineKeyframeProperty.scale,
        value: 1.5,
      ),
    ],
  );
  final audio = TimelineClip(
    id: 'a',
    trackId: 'audio',
    type: TimelineTrackType.audio,
    label: 'Detached audio',
    assetId: asset.id,
    linkedClipId: video.id,
    separatedFromClipId: video.id,
    startTime: video.startTime,
    endTime: video.endTime,
    sourceStartTime: video.sourceStartTime,
    sourceDuration: video.sourceDuration,
  );
  return EditorTimeline(
    assets: [asset],
    tracks: [
      TimelineTrack(
        id: 'video',
        name: 'Video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [video],
      ),
      TimelineTrack(
        id: 'audio',
        name: 'Audio',
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        isLocked: lockedAudio,
        clips: [audio],
      ),
    ],
  );
}
