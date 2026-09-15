import 'dart:io';

import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/home/screens/home_screen.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory documentsDirectory;
  late String replacementPath;
  FilePicker? previousFilePicker;

  setUp(() async {
    try {
      previousFilePicker = FilePicker.platform;
    } on Error {
      previousFilePicker = null;
    }
    documentsDirectory = await Directory.systemTemp.createTemp(
      'captioncraft_home_relink_',
    );
    replacementPath = p.join(documentsDirectory.path, 'replacement.mp4');
    await File(replacementPath).writeAsBytes(const [1, 2, 3, 4]);
    ProjectLocalStorage.setDocumentsDirectoryForTesting(documentsDirectory);
    FilePicker.platform = _FakeFilePicker(replacementPath);
  });

  tearDown(() async {
    await ProjectLocalStorage.waitForPendingSavesForTesting();
    ProjectLocalStorage.setDocumentsDirectoryForTesting(null);
    final previous = previousFilePicker;
    if (previous != null) FilePicker.platform = previous;
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  testWidgets(
    'Home relink preserves trims and speed for every shared source path',
    (tester) async {
      final ffprobeChannel = const MethodChannel(
        'flutter.arthenica.com/ffmpeg_kit',
      );
      final ffprobeCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        ffprobeChannel,
        (call) async {
          ffprobeCalls.add(call);
          switch (call.method) {
            case 'getLogLevel':
              return null;
            case 'getPlatform':
              return 'test';
            case 'getArch':
              return 'test';
            case 'getPackageName':
              return 'test';
            case 'enableRedirection':
            case 'setLogLevel':
              return null;
            case 'isLTSBuild':
              return false;
            case 'mediaInformationSession':
              return {'sessionId': 1};
            case 'mediaInformationSessionExecute':
              return null;
            case 'getMediaInformation':
              return {
                'format': {'duration': '12.0', 'size': '4096'},
                'streams': [
                  {
                    'index': 0,
                    'codec_type': 'video',
                    'codec_name': 'h264',
                    'width': 1920,
                    'height': 1080,
                    'avg_frame_rate': '30/1',
                    'pix_fmt': 'yuv420p',
                  },
                  {
                    'index': 1,
                    'codec_type': 'audio',
                    'codec_name': 'aac',
                    'channels': 2,
                    'channel_layout': 'stereo',
                    'sample_rate': '48000',
                  },
                ],
              };
            default:
              return null;
          }
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          ffprobeChannel,
          null,
        ),
      );

      final missingPath = p.join(
        documentsDirectory.path,
        'original-no-longer-mounted.mp4',
      );
      final firstAsset = EditorAssetReference(
        id: 'shared-asset-a',
        type: EditorAssetType.video,
        label: 'Original A',
        sourcePath: missingPath,
        remoteUrl: 'https://example.invalid/original-a.mp4',
        metadata: const {
          'durationMs': 10000,
          'width': 1920,
          'height': 1080,
          'hasAudio': true,
        },
      );
      final secondAsset = EditorAssetReference(
        id: 'shared-asset-b',
        type: EditorAssetType.video,
        label: 'Original B',
        sourcePath: missingPath,
        remoteUrl: 'https://example.invalid/original-b.mp4',
        metadata: const {
          'durationMs': 10000,
          'width': 1920,
          'height': 1080,
          'hasAudio': true,
        },
      );
      final baseClip = TimelineClip(
        id: 'base-clip',
        trackId: 'base-track',
        type: TimelineTrackType.video,
        label: 'Base cut',
        assetId: firstAsset.id,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 4),
        sourceStartTime: const Duration(milliseconds: 700),
        sourceDuration: const Duration(milliseconds: 2600),
        playbackRate: 1.5,
      );
      final overlayClip = TimelineClip(
        id: 'overlay-clip',
        trackId: 'overlay-track',
        type: TimelineTrackType.video,
        label: 'Overlay cut',
        assetId: secondAsset.id,
        startTime: const Duration(seconds: 4),
        endTime: const Duration(seconds: 7),
        sourceStartTime: const Duration(milliseconds: 1200),
        sourceDuration: const Duration(milliseconds: 1800),
        playbackRate: 0.75,
      );
      final project = Project(
        id: 'home-relink-project',
        ownerUid: 'local-test-user',
        name: 'Shared source relink',
        videoPath: missingPath,
        durationMs: 7000,
        timeline: EditorTimeline(
          assets: [firstAsset, secondAsset],
          tracks: [
            TimelineTrack(
              id: 'base-track',
              name: 'Base layer',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.baseVideo,
              clips: [baseClip],
            ),
            TimelineTrack(
              id: 'overlay-track',
              name: 'Overlay 1',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.overlay,
              clips: [overlayClip],
            ),
          ],
        ),
      );

      await tester.binding.setSurfaceSize(const Size(1180, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [currentUserProvider.overrideWithValue(null)],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: HomeScreen(
              initialProjects: [project],
              localOwnerUid: 'local-test-user',
            ),
          ),
        ),
      );
      await tester.pump();

      final relinkButton = find.text('Relink media');
      expect(relinkButton, findsOneWidget);
      await tester.ensureVisible(relinkButton);
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        await tester.tap(relinkButton);
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final saved = await ProjectLocalStorage.loadProject(project.id);
          final savedAssets = saved?.timeline.assets;
          if (savedAssets != null &&
              savedAssets.length == 2 &&
              savedAssets.every((asset) => asset.sourcePath == replacementPath)) {
            break;
          }
        }
        await ProjectLocalStorage.waitForPendingSavesForTesting();
      });
      final saved = await tester.runAsync(
        () => ProjectLocalStorage.loadProject(project.id),
      );
      await tester.pumpAndSettle();

      expect(
        ffprobeCalls.any((call) => call.method == 'getMediaInformation'),
        isTrue,
      );
      expect(find.text('Media relinked successfully'), findsOneWidget);
      expect(saved, isNotNull);
      expect(saved!.videoPath, replacementPath);
      expect(saved!.timeline.assets, hasLength(2));
      expect(
        saved!.timeline.assets.map((asset) => asset.sourcePath),
        everyElement(replacementPath),
      );
      expect(
        saved!.timeline.assets.map((asset) => asset.remoteUrl),
        everyElement(isNull),
      );

      final restoredBase = saved!.timeline.tracks
          .singleWhere((track) => track.id == baseClip.trackId)
          .clips
          .single;
      final restoredOverlay = saved!.timeline.tracks
          .singleWhere((track) => track.id == overlayClip.trackId)
          .clips
          .single;
      expect(restoredBase.assetId, firstAsset.id);
      expect(restoredOverlay.assetId, secondAsset.id);
      expect(restoredBase.sourceStartTime, baseClip.sourceStartTime);
      expect(restoredBase.sourceDuration, baseClip.sourceDuration);
      expect(restoredBase.playbackRate, baseClip.playbackRate);
      expect(restoredOverlay.sourceStartTime, overlayClip.sourceStartTime);
      expect(restoredOverlay.sourceDuration, overlayClip.sourceDuration);
      expect(restoredOverlay.playbackRate, overlayClip.playbackRate);
    },
  );
}

class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.path);

  final String path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    @Deprecated('allowCompression is deprecated and has no effect.')
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    return FilePickerResult([
      PlatformFile(
        name: p.basename(path),
        path: path,
        size: await File(path).length(),
      ),
    ]);
  }
}
