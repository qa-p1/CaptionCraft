import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/playback_provider.dart';
import 'package:caption_craft/features/editor/widgets/video_preview_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'referenced missing media never falls back to the first project video',
    () {
      const primaryPath = 'primary.mp4';
      const missingPath = 'missing-secondary.mp4';
      final primaryAsset = EditorAssetReference(
        id: 'asset-primary',
        type: EditorAssetType.video,
        label: 'Primary',
        sourcePath: primaryPath,
      );
      final secondaryAsset = EditorAssetReference(
        id: 'asset-secondary',
        type: EditorAssetType.video,
        label: 'Secondary',
        sourcePath: missingPath,
      );
      final secondaryClip = TimelineClip(
        id: 'clip-secondary',
        trackId: 'track-video',
        type: TimelineTrackType.video,
        label: 'Secondary',
        assetId: secondaryAsset.id,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
      );
      final timeline = EditorTimeline(
        assets: [primaryAsset, secondaryAsset],
        tracks: [
          TimelineTrack(
            id: 'track-video',
            name: 'Video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [secondaryClip],
          ),
        ],
      );

      final resolved = resolvePreviewSourcePathForTesting(
        timeline: timeline,
        clip: secondaryClip,
        legacyVideoPath: primaryPath,
        fileExists: (candidate) => candidate == primaryPath,
      );

      expect(resolved, isNull);
    },
  );

  test('preview playback range uses and clamps a complete work area', () {
    final range = resolvePreviewPlaybackRangeForTesting(
      timelineDuration: const Duration(seconds: 10),
      workspaceSettings: const TimelineWorkspaceSettings(
        workAreaStart: Duration(seconds: 2),
        workAreaEnd: Duration(seconds: 7),
        loopPlayback: true,
      ),
    );
    expect(range.start, const Duration(seconds: 2));
    expect(range.end, const Duration(seconds: 7));

    final clamped = resolvePreviewPlaybackRangeForTesting(
      timelineDuration: const Duration(seconds: 5),
      workspaceSettings: const TimelineWorkspaceSettings(
        workAreaStart: Duration(seconds: 2),
        workAreaEnd: Duration(seconds: 9),
      ),
    );
    expect(clamped.start, const Duration(seconds: 2));
    expect(clamped.end, const Duration(seconds: 5));
  });

  testWidgets('gap playback excludes time spent in the background', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final timeline = EditorTimeline(
      tracks: [
        TimelineTrack(
          id: 'base-track',
          name: 'Video',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [
            TimelineClip(
              id: 'later-clip',
              trackId: 'base-track',
              type: TimelineTrackType.video,
              label: 'Later clip',
              startTime: const Duration(seconds: 5),
              endTime: const Duration(seconds: 10),
            ),
          ],
        ),
      ],
    );
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: '',
          projectId: 'lifecycle-preview',
          projectName: 'Lifecycle preview',
          timeline: timeline,
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: VideoPreviewPanel(videoPath: '')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 165));
    final beforePause = container.read(playbackProvider).position;
    expect(beforePause, greaterThan(Duration.zero));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final pausedAt = container.read(playbackProvider).position;
    expect(container.read(playbackProvider).isPlaying, isFalse);

    await tester.pump(const Duration(seconds: 30));
    expect(container.read(playbackProvider).position, pausedAt);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 99));
    final afterResume = container.read(playbackProvider).position;
    expect(afterResume, greaterThan(pausedAt));
    expect(afterResume, lessThan(pausedAt + const Duration(milliseconds: 500)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('preview color matrix matches eq then temperature channel mixing', () {
    const adjustments = ClipColorAdjustments(
      brightness: 0.18,
      contrast: 1.35,
      saturation: 0.45,
      temperature: 0.75,
      fade: 0.2,
    );
    final actual = buildPreviewColorMatrixForTesting(adjustments);

    final saturation = adjustments.saturation;
    final contrast = adjustments.contrast * (1 - adjustments.fade * 0.22);
    final brightness = adjustments.brightness + adjustments.fade * 0.05;
    const redLuma = 0.2126;
    const greenLuma = 0.7152;
    const blueLuma = 0.0722;
    final inverseSaturation = 1 - saturation;
    final offset = 128 * (1 - contrast) + brightness * 255;
    final redMixer = 1 + adjustments.temperature * 0.16;
    final blueMixer = 1 - adjustments.temperature * 0.16;
    final expected = <double>[
      (redLuma * inverseSaturation + saturation) * contrast * redMixer,
      greenLuma * inverseSaturation * contrast * redMixer,
      blueLuma * inverseSaturation * contrast * redMixer,
      0,
      offset * redMixer,
      redLuma * inverseSaturation * contrast,
      (greenLuma * inverseSaturation + saturation) * contrast,
      blueLuma * inverseSaturation * contrast,
      0,
      offset,
      redLuma * inverseSaturation * contrast * blueMixer,
      greenLuma * inverseSaturation * contrast * blueMixer,
      (blueLuma * inverseSaturation + saturation) * contrast * blueMixer,
      0,
      offset * blueMixer,
      0,
      0,
      0,
      1,
      0,
    ];

    expect(actual, hasLength(expected.length));
    for (var index = 0; index < expected.length; index++) {
      expect(
        actual[index],
        closeTo(expected[index], 1e-10),
        reason: 'row $index',
      );
    }
    expect(actual[1], isNot(0));
    expect(actual[4], isNot(closeTo(offset, 1e-10)));
    expect(
      actual[10],
      isNot(closeTo(redLuma * inverseSaturation * contrast, 1e-10)),
    );
    expect(actual[14], isNot(closeTo(offset, 1e-10)));
  });

  test('GIF decode dimensions obey both viewport and total memory caps', () {
    final landscape = calculateGifDecodeSizeForTesting(
      intrinsicWidth: 4000,
      intrinsicHeight: 1000,
      frameCount: 4,
      maxWidth: 300,
      maxHeight: 100,
    );
    expect(landscape, const Size(300, 75));

    final portrait = calculateGifDecodeSizeForTesting(
      intrinsicWidth: 1000,
      intrinsicHeight: 4000,
      frameCount: 4,
      maxWidth: 500,
      maxHeight: 120,
    );
    expect(portrait, const Size(30, 120));

    final manyFrames = calculateGifDecodeSizeForTesting(
      intrinsicWidth: 1920,
      intrinsicHeight: 1080,
      frameCount: 300,
      maxWidth: 1920,
      maxHeight: 1080,
    );
    final retainedRgbaBytes = manyFrames.width * manyFrames.height * 4 * 300;
    expect(retainedRgbaBytes, lessThanOrEqualTo(48 * 1024 * 1024));
    expect(manyFrames.width, lessThanOrEqualTo(1920));
    expect(manyFrames.height, lessThanOrEqualTo(1080));
  });

  testWidgets('full blur filters the media widget itself', (tester) async {
    const mediaKey = ValueKey('full-blur-media');

    await tester.pumpWidget(
      _blurHarness(
        child: const ColoredBox(key: mediaKey, color: Colors.red),
        blur: const ClipBlurSettings(mode: ClipBlurMode.full, strength: 12),
      ),
    );

    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(mediaKey), findsOneWidget);
  });

  testWidgets('region blur paints clean and clipped filtered media copies', (
    tester,
  ) async {
    const mediaKey = ValueKey('region-blur-media');

    await tester.pumpWidget(
      _blurHarness(
        child: const ColoredBox(key: mediaKey, color: Colors.red),
        blur: const ClipBlurSettings(
          mode: ClipBlurMode.region,
          strength: 12,
          regionX: 0.2,
          regionY: 0.25,
          regionWidth: 0.4,
          regionHeight: 0.35,
        ),
      ),
    );

    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ClipRect), findsOneWidget);
    expect(find.byKey(mediaKey), findsNWidgets(2));
  });

  testWidgets('timeline blur wraps the composed base and overlay canvas', (
    tester,
  ) async {
    const baseKey = ValueKey('composed-base');
    const overlayKey = ValueKey('composed-overlay');

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            height: 100,
            child: buildComposedMediaPreviewForTesting(
              backgroundColor: Colors.black,
              mediaLayers: const [
                ColoredBox(key: baseKey, color: Colors.red),
                Align(
                  child: SizedBox(
                    key: overlayKey,
                    width: 40,
                    height: 30,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ),
              ],
              timelineEffectsBuilder: (canvas) =>
                  buildBlurredMediaPreviewForTesting(
                    child: canvas,
                    blur: const ClipBlurSettings(
                      mode: ClipBlurMode.full,
                      strength: 10,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(
      find.byKey(const ValueKey('preview-composed-media-canvas')),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byKey(baseKey),
        matching: find.byType(ImageFiltered),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byKey(overlayKey),
        matching: find.byType(ImageFiltered),
      ),
      findsOneWidget,
    );
  });
}

Widget _blurHarness({required Widget child, required ClipBlurSettings blur}) {
  return MaterialApp(
    home: Center(
      child: SizedBox(
        width: 200,
        height: 100,
        child: buildBlurredMediaPreviewForTesting(child: child, blur: blur),
      ),
    ),
  );
}
