import 'dart:async';
import 'dart:io';

import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/features/editor/models/export_settings.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workingDirectory;
  late String projectVideoPath;

  setUp(() async {
    workingDirectory = await Directory.systemTemp.createTemp(
      'captioncraft_source_resolution_',
    );
    projectVideoPath = p.join(workingDirectory.path, 'primary.mp4');
    await File(projectVideoPath).writeAsBytes(const [0]);
  });

  tearDown(() async {
    if (await workingDirectory.exists()) {
      await workingDirectory.delete(recursive: true);
    }
  });

  test(
    'only an assetless legacy primary clip uses the project video',
    () async {
      final primary = TimelineClip(
        id: 'primary',
        trackId: 'base',
        type: TimelineTrackType.video,
        label: 'Legacy primary',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
      );
      final missingSecondary = TimelineClip(
        id: 'secondary',
        trackId: 'base',
        type: TimelineTrackType.video,
        label: 'Missing secondary',
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 2),
      );
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'base',
            name: 'Video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [primary, missingSecondary],
          ),
        ],
      );
      final project = Project(
        id: 'project',
        name: 'Project',
        videoPath: projectVideoPath,
        durationMs: 2000,
        timeline: timeline,
      );

      expect(
        await TimelineExportService.resolveSourcePathForTesting(
          project: project,
          timeline: timeline,
          clip: primary,
          workingDirectory: workingDirectory,
        ),
        projectVideoPath,
      );
      await expectLater(
        TimelineExportService.resolveSourcePathForTesting(
          project: project,
          timeline: timeline,
          clip: missingSecondary,
          workingDirectory: workingDirectory,
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Relink it first'),
          ),
        ),
      );
      expect(
        TimelineExportService.sourceCacheKeyForTesting(primary),
        isNot(TimelineExportService.sourceCacheKeyForTesting(missingSecondary)),
      );
    },
  );

  test('a dangling asset id never falls back to the project video', () async {
    final clip = TimelineClip(
      id: 'primary',
      trackId: 'base',
      type: TimelineTrackType.video,
      label: 'Missing referenced video',
      assetId: 'missing-asset',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
    );
    final timeline = EditorTimeline(
      tracks: [
        TimelineTrack(
          id: 'base',
          name: 'Video',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [clip],
        ),
      ],
    );
    final project = Project(
      id: 'project',
      name: 'Project',
      videoPath: projectVideoPath,
      durationMs: 1000,
      timeline: timeline,
    );

    await expectLater(
      TimelineExportService.resolveSourcePathForTesting(
        project: project,
        timeline: timeline,
        clip: clip,
        workingDirectory: workingDirectory,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('non-HTTP remote media URLs are rejected before export', () async {
    final asset = EditorAssetReference(
      id: 'remote',
      type: EditorAssetType.video,
      label: 'Unsafe remote',
      remoteUrl: 'file:///private/source.mp4',
      isNetworkBacked: true,
    );
    final clip = TimelineClip(
      id: 'primary',
      trackId: 'base',
      type: TimelineTrackType.video,
      label: 'Unsafe remote',
      assetId: asset.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
    );
    final timeline = EditorTimeline(
      assets: [asset],
      tracks: [
        TimelineTrack(
          id: 'base',
          name: 'Video',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [clip],
        ),
      ],
    );
    final project = Project(
      id: 'project',
      name: 'Project',
      videoPath: projectVideoPath,
      durationMs: 1000,
      timeline: timeline,
    );

    await expectLater(
      TimelineExportService.resolveSourcePathForTesting(
        project: project,
        timeline: timeline,
        clip: clip,
        workingDirectory: workingDirectory,
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Unsupported media URL'),
        ),
      ),
    );
  });

  test('public cleartext remote media is rejected before export', () async {
    final source = _remoteSource(
      remoteUrl: 'http://media.example.test/source.mp4',
      label: 'Cleartext remote',
    );

    await expectLater(
      TimelineExportService.resolveSourcePathForTesting(
        project: source.project,
        timeline: source.timeline,
        clip: source.clip,
        workingDirectory: workingDirectory,
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Unsupported media URL'),
        ),
      ),
    );
  });

  test('HTML remote-media responses are rejected and removed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<html><body>Sign in to continue</body></html>');
      await request.response.close();
    });
    final source = _remoteSource(
      remoteUrl: 'http://${server.address.address}:${server.port}/source.mp4',
      label: 'Expired remote clip',
    );

    await expectLater(
      TimelineExportService.resolveSourcePathForTesting(
        project: source.project,
        timeline: source.timeline,
        clip: source.clip,
        workingDirectory: workingDirectory,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          'message',
          contains('web page instead of media'),
        ),
      ),
    );
    final leftovers = await workingDirectory
        .list()
        .where(
          (entity) =>
              entity is File && p.basename(entity.path).startsWith('network_'),
        )
        .toList();
    expect(leftovers, isEmpty);
  });

  test('remote-media downloads have a hard overall deadline', () async {
    final dio = _HangingDownloadDio();
    addTearDown(() => dio.close(force: true));
    final source = _remoteSource(
      remoteUrl: 'https://media.example.test/slow.mp4',
      label: 'Slow remote clip',
    );

    await expectLater(
      TimelineExportService.resolveSourcePathForTesting(
        project: source.project,
        timeline: source.timeline,
        clip: source.clip,
        workingDirectory: workingDirectory,
        dioOverride: dio,
        networkRequestTimeout: const Duration(milliseconds: 40),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('timed out'),
        ),
      ),
    );
    expect(dio.cancelToken?.isCancelled, isTrue);
    expect(
      await workingDirectory
          .list()
          .where(
            (entity) =>
                entity is File &&
                p.basename(entity.path).startsWith('network_'),
          )
          .toList(),
      isEmpty,
    );
  });

  test('unsafe redirects are rejected before requesting the target', () async {
    final requestedPaths = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requestedPaths.add(request.uri.path);
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://media.example.test/redirected.mp4',
        );
      await request.response.close();
    });
    final source = _remoteSource(
      remoteUrl: 'http://${server.address.address}:${server.port}/source.mp4',
      label: 'Redirected clip',
    );

    await expectLater(
      TimelineExportService.resolveSourcePathForTesting(
        project: source.project,
        timeline: source.timeline,
        clip: source.clip,
        workingDirectory: workingDirectory,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          'message',
          contains('unsafe URL'),
        ),
      ),
    );
    expect(requestedPaths, <String>['/source.mp4']);
    expect(
      await workingDirectory
          .list()
          .where(
            (entity) =>
                entity is File &&
                p.basename(entity.path).startsWith('network_'),
          )
          .toList(),
      isEmpty,
    );
  });

  test(
    'safe relative redirects are followed within the overall limit',
    () async {
      final requestedPaths = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requestedPaths.add(request.uri.path);
        if (request.uri.path == '/source.mp4') {
          request.response
            ..statusCode = HttpStatus.temporaryRedirect
            ..headers.set(HttpHeaders.locationHeader, '/media/final.mp4');
        } else {
          request.response.headers.contentType = ContentType('video', 'mp4');
          request.response.add(const <int>[0, 0, 0, 24, 102, 116, 121, 112]);
        }
        await request.response.close();
      });
      final source = _remoteSource(
        remoteUrl: 'http://${server.address.address}:${server.port}/source.mp4',
        label: 'Redirected clip',
      );

      final path = await TimelineExportService.resolveSourcePathForTesting(
        project: source.project,
        timeline: source.timeline,
        clip: source.clip,
        workingDirectory: workingDirectory,
      );

      expect(requestedPaths, <String>['/source.mp4', '/media/final.mp4']);
      expect(await File(path).readAsBytes(), <int>[
        0,
        0,
        0,
        24,
        102,
        116,
        121,
        112,
      ]);
    },
  );

  test('oversized network media is stopped during download', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      try {
        request.response.contentLength = 64 * 1024 * 1024 + 1;
        request.response.add(const [1]);
        await request.response.flush();
        await request.response.close();
      } catch (_) {
        // The client intentionally cancels after reading the oversized header.
      }
    });
    final asset = EditorAssetReference(
      id: 'large-remote',
      type: EditorAssetType.gif,
      label: 'Large GIF',
      remoteUrl: 'http://${server.address.address}:${server.port}/large.gif',
      isNetworkBacked: true,
    );
    final clip = TimelineClip(
      id: 'primary',
      trackId: 'base',
      type: TimelineTrackType.video,
      label: 'Large GIF',
      assetId: asset.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
    );
    final timeline = EditorTimeline(
      assets: [asset],
      tracks: [
        TimelineTrack(
          id: 'base',
          name: 'Video',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [clip],
        ),
      ],
    );
    final project = Project(
      id: 'project',
      name: 'Project',
      videoPath: projectVideoPath,
      durationMs: 1000,
      timeline: timeline,
    );

    await expectLater(
      TimelineExportService.resolveSourcePathForTesting(
        project: project,
        timeline: timeline,
        clip: clip,
        workingDirectory: workingDirectory,
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('exceeds the 64 MB'),
        ),
      ),
    );
  });

  test('freeze export can select beyond the normal playback source window', () {
    final clip = TimelineClip(
      id: 'freeze',
      trackId: 'base',
      type: TimelineTrackType.video,
      label: 'Freeze',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
      sourceDuration: const Duration(seconds: 12),
      freezeFrame: true,
      freezeFrameSourceTime: const Duration(milliseconds: 10400),
    );
    final track = TimelineTrack(
      id: 'base',
      name: 'Video',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.baseVideo,
      clips: [clip],
    );
    final timeline = EditorTimeline(tracks: [track]);

    final arguments = TimelineExportService.buildFfmpegArguments(
      timeline: timeline,
      inputs: [
        TimelineRenderInput(
          index: 0,
          trackIndex: 0,
          track: track,
          clip: clip,
          asset: null,
          sourcePath: 'source.mp4',
          hasAudio: false,
        ),
      ],
      settings: const ExportSettings(includeAudio: false),
      canvasSize: const ExportCanvasSize(
        width: 640,
        height: 360,
        framesPerSecond: 30,
      ),
      timelineDuration: const Duration(seconds: 1),
      assPath: null,
      outputPath: 'output.mp4',
    );

    expect(
      arguments,
      containsAllInOrder(['-ss', '9.400000', '-t', '2.000000']),
    );
  });

  test(
    'expanded transitions plan smooth scale, rotation, and diagonal motion',
    () {
      final clip = TimelineClip(
        id: 'animated',
        trackId: 'base',
        type: TimelineTrackType.video,
        label: 'Animated',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 4),
        sourceDuration: const Duration(seconds: 4),
        introTransition: const ClipTransition(
          type: TransitionType.spin,
          durationMs: 600,
        ),
        outroTransition: const ClipTransition(
          type: TransitionType.slideUpRight,
          durationMs: 700,
        ),
      );
      final track = TimelineTrack(
        id: 'base',
        name: 'Video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [clip],
      );
      final timeline = EditorTimeline(tracks: [track]);

      final arguments = TimelineExportService.buildFfmpegArguments(
        timeline: timeline,
        inputs: [
          TimelineRenderInput(
            index: 0,
            trackIndex: 0,
            track: track,
            clip: clip,
            asset: null,
            sourcePath: 'source.mp4',
            hasAudio: false,
          ),
        ],
        settings: const ExportSettings(includeAudio: false),
        canvasSize: const ExportCanvasSize(
          width: 640,
          height: 360,
          framesPerSecond: 30,
        ),
        timelineDuration: const Duration(seconds: 4),
        assPath: null,
        outputPath: 'output.mp4',
      );
      final filterGraph = arguments[arguments.indexOf('-filter_complex') + 1];

      expect(filterGraph, contains('rotate=angle='));
      expect(filterGraph, contains('1.570796'));
      expect(filterGraph, contains('scale=w='));
      expect(filterGraph, contains('+W*'));
      expect(filterGraph, contains('-H*'));
      expect(filterGraph, contains('(3-2*'));
    },
  );
}

({Project project, EditorTimeline timeline, TimelineClip clip}) _remoteSource({
  required String remoteUrl,
  required String label,
}) {
  final asset = EditorAssetReference(
    id: 'remote-asset',
    type: EditorAssetType.video,
    label: label,
    remoteUrl: remoteUrl,
    isNetworkBacked: true,
  );
  final clip = TimelineClip(
    id: 'remote-clip',
    trackId: 'base',
    type: TimelineTrackType.video,
    label: label,
    assetId: asset.id,
    startTime: Duration.zero,
    endTime: const Duration(seconds: 1),
  );
  final timeline = EditorTimeline(
    assets: [asset],
    tracks: [
      TimelineTrack(
        id: 'base',
        name: 'Video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [clip],
      ),
    ],
  );
  return (
    project: Project(
      id: 'remote-project',
      name: 'Remote project',
      videoPath: '',
      durationMs: 1000,
      timeline: timeline,
    ),
    timeline: timeline,
    clip: clip,
  );
}

class _HangingDownloadDio extends DioForNative {
  CancelToken? cancelToken;

  @override
  Future<Response> download(
    String urlPath,
    dynamic savePath, {
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    FileAccessMode fileAccessMode = FileAccessMode.write,
    String lengthHeader = Headers.contentLengthHeader,
    Object? data,
    Options? options,
  }) async {
    this.cancelToken = cancelToken;
    final headers = Headers();
    final resolvedPath = savePath is String
        ? savePath
        : await (savePath as FutureOr<String> Function(Headers))(headers);
    await File(resolvedPath).writeAsBytes(const <int>[1, 2, 3]);
    return Completer<Response<dynamic>>().future;
  }
}
