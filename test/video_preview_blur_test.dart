import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/playback_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/widgets/animated_subtitle_overlay.dart';
import 'package:caption_craft/features/editor/widgets/video_preview_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preview bitmap decoding follows display pixels and stays bounded', () {
    expect(
      calculatePreviewDecodeDimensionForTesting(
        logicalExtent: 360,
        devicePixelRatio: 3,
      ),
      1080,
    );
    expect(
      calculatePreviewDecodeDimensionForTesting(
        logicalExtent: 1400,
        devicePixelRatio: 4,
      ),
      2048,
    );
    expect(
      calculatePreviewDecodeDimensionForTesting(
        logicalExtent: double.nan,
        devicePixelRatio: 3,
      ),
      1,
    );
  });

  test('all preview controllers share platform audio focus', () {
    expect(buildPreviewVideoPlayerOptions().mixWithOthers, isTrue);
  });

  test('fallback mixer protects a thirty-voice overlap from clipping', () {
    expect(previewFallbackMixBusGainForTesting(0), 1);
    expect(previewFallbackMixBusGainForTesting(2), 0.5);
    expect(previewFallbackMixBusGainForTesting(30), closeTo(1 / 30, 0.000001));
  });

  test(
    'preview hit bounds follow visible media instead of the layout slot',
    () {
      final contained = previewVisibleMediaSizeForTesting(
        sourceSize: const Size(400, 100),
        targetSize: const Size(200, 200),
        fitMode: ClipFitMode.contain,
      );
      expect(contained, const Size(200, 50));

      final cropped = previewVisibleMediaSizeForTesting(
        sourceSize: const Size(400, 200),
        targetSize: const Size(200, 200),
        fitMode: ClipFitMode.contain,
        crop: const ClipCropSettings(left: 0.25, right: 0.25),
      );
      expect(cropped, const Size(200, 200));

      expect(
        previewVisibleMediaSizeForTesting(
          sourceSize: const Size(400, 100),
          targetSize: const Size(200, 200),
          fitMode: ClipFitMode.cover,
        ),
        const Size(200, 200),
      );
    },
  );

  test('audio warm window includes only current and near-future clips', () {
    final clip = TimelineClip(
      trackId: 'audio',
      type: TimelineTrackType.audio,
      label: 'Music',
      startTime: const Duration(seconds: 5),
      endTime: const Duration(seconds: 8),
    );

    expect(
      shouldPreloadTimelineAudioPreviewForTesting(
        clip: clip,
        position: const Duration(milliseconds: 3100),
      ),
      isTrue,
    );
    expect(
      shouldPreloadTimelineAudioPreviewForTesting(
        clip: clip,
        position: const Duration(seconds: 2),
      ),
      isFalse,
    );
    expect(
      shouldPreloadTimelineAudioPreviewForTesting(
        clip: clip,
        position: const Duration(seconds: 8),
      ),
      isFalse,
    );
  });

  test('base video warm window is bounded and ignores active clips', () {
    final clip = TimelineClip(
      trackId: 'video',
      type: TimelineTrackType.video,
      label: 'Next shot',
      startTime: const Duration(seconds: 10),
      endTime: const Duration(seconds: 14),
    );

    expect(
      shouldPreloadBaseVideoForTesting(
        clip: clip,
        position: const Duration(milliseconds: 6600),
      ),
      isTrue,
    );
    expect(
      shouldPreloadBaseVideoForTesting(
        clip: clip,
        position: const Duration(seconds: 6),
      ),
      isFalse,
    );
    expect(
      shouldPreloadBaseVideoForTesting(
        clip: clip,
        position: const Duration(seconds: 10),
      ),
      isFalse,
    );
  });

  test('indexed preview lookup stays correct on a long timeline lane', () {
    final clips = List<TimelineClip>.generate(10000, (index) {
      final start = Duration(milliseconds: index * 100);
      return TimelineClip(
        id: 'clip_$index',
        trackId: 'long-track',
        type: TimelineTrackType.video,
        label: 'Clip $index',
        startTime: start,
        endTime: start + const Duration(milliseconds: 100),
      );
    }, growable: false);
    const position = Duration(milliseconds: 777750);

    expect(previewClipStartUpperBoundForTesting(clips, position), 7778);
    expect(
      resolveIndexedPreviewClipForTesting(
        sortedClips: clips,
        position: position,
      )?.id,
      'clip_7777',
    );
    expect(
      indexedPreviewClipsStartingInWindowForTesting(
        sortedClips: clips,
        position: position,
        window: const Duration(milliseconds: 250),
      ).map((clip) => clip.id),
      ['clip_7778', 'clip_7779', 'clip_7780'],
    );
  });

  test(
    'indexed lookup handles gaps and an explicitly included final frame',
    () {
      final clips = [
        TimelineClip(
          id: 'first',
          trackId: 'video',
          type: TimelineTrackType.video,
          label: 'First',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
        TimelineClip(
          id: 'second',
          trackId: 'video',
          type: TimelineTrackType.video,
          label: 'Second',
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 3),
        ),
      ];

      expect(
        resolveIndexedPreviewClipForTesting(
          sortedClips: clips,
          position: const Duration(milliseconds: 1500),
        ),
        isNull,
      );
      expect(
        resolveIndexedPreviewClipForTesting(
          sortedClips: clips,
          position: const Duration(seconds: 3),
          includeEnd: true,
        )?.id,
        'second',
      );
    },
  );

  test('caption interval index finds overlaps deep in a large caption set', () {
    final entries = <SubtitleEntry>[
      SubtitleEntry(
        id: 'long-caption',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1000),
        text: 'Persistent title',
      ),
      ...List<SubtitleEntry>.generate(10000, (index) {
        final start = Duration(milliseconds: index * 100);
        return SubtitleEntry(
          id: 'caption_$index',
          startTime: start,
          endTime: start + const Duration(milliseconds: 100),
          text: 'Caption $index',
        );
      }, growable: false),
    ];

    final active = resolveIndexedPreviewSubtitlesForTesting(
      entries: entries,
      position: const Duration(milliseconds: 777750),
    );
    expect(active.map((entry) => entry.id), ['long-caption', 'caption_7777']);
  });

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

  test(
    'preview resolves validated proxies without affecting original mode',
    () {
      final asset = EditorAssetReference(
        id: 'asset-video',
        type: EditorAssetType.video,
        label: 'Video',
        sourcePath: '/media/original.mp4',
        metadata: const {
          'proxyMedia': {
            'path': '/cache/proxy.mp4',
            'sourceFingerprint': 'fixture-v1',
          },
        },
      );
      final clip = TimelineClip(
        id: 'clip-video',
        trackId: 'track-video',
        type: TimelineTrackType.video,
        label: 'Video',
        assetId: asset.id,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
      );
      EditorTimeline timeline(PreviewMediaQuality quality) => EditorTimeline(
        assets: [asset],
        workspaceSettings: TimelineWorkspaceSettings(
          previewMediaQuality: quality,
        ),
        tracks: [
          TimelineTrack(
            id: 'track-video',
            name: 'Video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [clip],
          ),
        ],
      );
      bool exists(String path) =>
          path == '/media/original.mp4' || path == '/cache/proxy.mp4';

      expect(
        resolvePreviewSourcePathForTesting(
          timeline: timeline(PreviewMediaQuality.auto),
          clip: clip,
          legacyVideoPath: '',
          fileExists: exists,
          sourceFingerprintSync: (_) => 'fixture-v1',
        ),
        '/cache/proxy.mp4',
      );
      expect(
        resolvePreviewSourcePathForTesting(
          timeline: timeline(PreviewMediaQuality.original),
          clip: clip,
          legacyVideoPath: '',
          fileExists: exists,
          sourceFingerprintSync: (_) => 'fixture-v1',
        ),
        '/media/original.mp4',
      );
      expect(
        resolvePreviewSourcePathForTesting(
          timeline: timeline(PreviewMediaQuality.proxy),
          clip: clip,
          legacyVideoPath: '',
          fileExists: (path) => path == '/cache/proxy.mp4',
          sourceFingerprintSync: (_) => 'missing',
        ),
        '/cache/proxy.mp4',
        reason: 'an offline original remains previewable from its proxy',
      );
      expect(
        resolvePreviewSourcePathForTesting(
          timeline: timeline(PreviewMediaQuality.proxy),
          clip: clip,
          legacyVideoPath: '',
          fileExists: exists,
          sourceFingerprintSync: (_) => 'changed-source',
        ),
        '/media/original.mp4',
        reason: 'relinked or modified sources invalidate stale proxies',
      );
    },
  );

  testWidgets('preview diagnostics can be shown, reset, and hidden', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: '',
          projectId: 'diagnostics-preview',
          projectName: 'Diagnostics preview',
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

    await tester.tap(find.byTooltip('Show preview diagnostics'));
    await tester.pump();
    expect(find.text('PREVIEW DIAGNOSTICS'), findsOneWidget);
    await tester.tap(find.text('RESET'));
    await tester.pump();

    await tester.tap(find.byTooltip('Hide preview diagnostics'));
    await tester.pump();
    expect(find.text('PREVIEW DIAGNOSTICS'), findsNothing);
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

  testWidgets('an image base layer renders and advances on the shared clock', (
    tester,
  ) async {
    const existingPath = 'pubspec.yaml';
    final asset = EditorAssetReference(
      id: 'base-image-asset',
      type: EditorAssetType.image,
      label: 'Base image',
      sourcePath: existingPath,
    );
    final imageClip = TimelineClip(
      id: 'base-image',
      trackId: 'base-track',
      type: TimelineTrackType.image,
      label: 'Base image',
      assetId: asset.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 3),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: '',
          projectId: 'image-base-preview',
          projectName: 'Image base preview',
          timeline: EditorTimeline(
            assets: [asset],
            tracks: [
              TimelineTrack(
                id: 'base-track',
                name: 'Base layer',
                type: TimelineTrackType.video,
                section: TimelineTrackSection.baseVideo,
                clips: [imageClip],
              ),
            ],
          ),
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
    expect(find.byType(Image), findsOneWidget);
    expect(
      find.byKey(const ValueKey('preview-source-interaction-base-image')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Play'));
    await tester.pump(const Duration(milliseconds: 220));
    expect(container.read(playbackProvider).isPlaying, isTrue);
    expect(
      container.read(playbackProvider).position,
      greaterThan(Duration.zero),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('one unavailable video cannot stop the shared playhead', (
    tester,
  ) async {
    final missingVideo = TimelineClip(
      id: 'missing-base-video',
      trackId: 'base-track',
      type: TimelineTrackType.video,
      label: 'Missing base video',
      assetId: 'missing-asset',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 3),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: '',
          projectId: 'missing-video-clock',
          projectName: 'Missing video clock',
          timeline: EditorTimeline(
            assets: [
              EditorAssetReference(
                id: 'missing-asset',
                type: EditorAssetType.video,
                label: 'Missing video',
                sourcePath: 'definitely-not-present.mp4',
              ),
            ],
            tracks: [
              TimelineTrack(
                id: 'base-track',
                name: 'Base layer',
                type: TimelineTrackType.video,
                section: TimelineTrackSection.baseVideo,
                clips: [missingVideo],
              ),
            ],
          ),
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
    await tester.pump(const Duration(milliseconds: 165));

    expect(container.read(playbackProvider).isPlaying, isTrue);
    expect(
      container.read(playbackProvider).position,
      greaterThan(Duration.zero),
    );
    expect(find.textContaining('Media is missing'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('preview renders simultaneous captions from separate sources', (
    tester,
  ) async {
    final mainCaption = SubtitleEntry(
      id: 'caption-main',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
      text: 'Main source caption',
    );
    final overlayCaption = SubtitleEntry(
      id: 'caption-overlay',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
      text: 'Overlay source caption',
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(subtitleProvider.notifier)
        .initializeFromProject(
          entries: [mainCaption, overlayCaption],
          globalStyle: const SubtitleStyleModel(),
        );
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: '',
          projectId: 'multi-caption-preview',
          projectName: 'Multi-caption preview',
          timeline: EditorTimeline(
            tracks: [
              TimelineTrack(
                id: 'captions-main',
                name: 'Captions · Main',
                type: TimelineTrackType.subtitle,
                section: TimelineTrackSection.textSubtitle,
                clips: [
                  TimelineClip.fromSubtitleEntry(
                    mainCaption,
                    trackId: 'captions-main',
                    linkedClipId: 'main-video',
                  ),
                ],
              ),
              TimelineTrack(
                id: 'captions-overlay',
                name: 'Captions · Overlay',
                type: TimelineTrackType.subtitle,
                section: TimelineTrackSection.textSubtitle,
                clips: [
                  TimelineClip.fromSubtitleEntry(
                    overlayCaption,
                    trackId: 'captions-overlay',
                    linkedClipId: 'overlay-video',
                  ),
                ],
              ),
            ],
          ),
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

    final composition = find.byKey(
      const ValueKey('preview-composed-effect-output'),
    );
    expect(composition, findsOneWidget);
    expect(
      find.descendant(
        of: composition,
        matching: find.byType(AnimatedSubtitleOverlay),
      ),
      findsNWidgets(2),
    );

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
    expect(retainedRgbaBytes, lessThanOrEqualTo(24 * 1024 * 1024));
    expect(manyFrames.width, lessThanOrEqualTo(1920));
    expect(manyFrames.height, lessThanOrEqualTo(1080));
  });

  test('GIF preview size buckets ignore tiny layout changes', () {
    expect(quantizeGifPreviewSizeForTesting(321, 179), const Size(352, 192));
    expect(
      quantizeGifPreviewSizeForTesting(335.9, 191.9),
      const Size(352, 192),
    );
    expect(quantizeGifPreviewSizeForTesting(double.nan, -4), const Size(1, 1));
  });

  test('inaudible timeline clips are rejected before controller creation', () {
    TimelineClip clip({bool muted = false}) => TimelineClip(
      id: muted ? 'muted' : 'audible',
      trackId: 'audio-track',
      type: TimelineTrackType.audio,
      label: 'Audio',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
      audioMix: AudioMixSettings(muted: muted),
    );

    final audibleTrack = TimelineTrack(
      id: 'audio-track',
      name: 'Audio',
      type: TimelineTrackType.audio,
      section: TimelineTrackSection.audio,
      clips: [clip()],
    );
    expect(
      shouldCreateTimelineAudioPreviewForTesting(
        track: audibleTrack,
        clip: audibleTrack.clips.single,
        hasSoloMediaTrack: false,
      ),
      isTrue,
    );
    expect(
      shouldCreateTimelineAudioPreviewForTesting(
        track: audibleTrack.copyWith(isMuted: true),
        clip: audibleTrack.clips.single,
        hasSoloMediaTrack: false,
      ),
      isFalse,
    );
    expect(
      shouldCreateTimelineAudioPreviewForTesting(
        track: audibleTrack,
        clip: clip(muted: true),
        hasSoloMediaTrack: false,
      ),
      isFalse,
    );
    expect(
      shouldCreateTimelineAudioPreviewForTesting(
        track: audibleTrack,
        clip: audibleTrack.clips.single,
        hasSoloMediaTrack: true,
      ),
      isFalse,
    );
    expect(
      shouldCreateTimelineAudioPreviewForTesting(
        track: audibleTrack.copyWith(isSolo: true),
        clip: audibleTrack.clips.single,
        hasSoloMediaTrack: true,
      ),
      isTrue,
    );
    expect(
      shouldCreateTimelineAudioPreviewForTesting(
        track: audibleTrack,
        clip: audibleTrack.clips.single,
        hasSoloMediaTrack: false,
        baseMonitoredClipId: audibleTrack.clips.single.id,
      ),
      isFalse,
    );
  });

  test(
    'three overlapping videos keep independent embedded-audio ownership',
    () {
      TimelineClip video(String id, String trackId, String assetId) =>
          TimelineClip(
            id: id,
            trackId: trackId,
            type: TimelineTrackType.video,
            label: id,
            assetId: assetId,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 5),
            sourceDuration: const Duration(seconds: 5),
          );
      TimelineTrack track(
        String id,
        TimelineTrackSection section,
        TimelineClip clip,
      ) => TimelineTrack(
        id: id,
        name: id,
        type: TimelineTrackType.video,
        section: section,
        clips: [clip],
      );

      final clips = [
        video('base-video', 'base-track', 'asset-base'),
        video('overlay-video-a', 'overlay-track-a', 'asset-overlay-a'),
        video('overlay-video-b', 'overlay-track-b', 'asset-overlay-b'),
      ];
      final visualTracks = [
        track('base-track', TimelineTrackSection.baseVideo, clips[0]),
        track('overlay-track-a', TimelineTrackSection.overlay, clips[1]),
        track('overlay-track-b', TimelineTrackSection.overlay, clips[2]),
      ];
      final assets = [
        for (var index = 0; index < clips.length; index++)
          EditorAssetReference(
            id: clips[index].assetId!,
            type: EditorAssetType.video,
            label: clips[index].label,
            sourcePath: 'video-$index.mp4',
            metadata: const {'hasAudio': true},
          ),
      ];
      final timeline = EditorTimeline(assets: assets, tracks: visualTracks);

      for (var index = 0; index < clips.length; index++) {
        expect(
          previewVisualUsesEmbeddedAudioForTesting(
            timeline: timeline,
            visualTrack: visualTracks[index],
            visualClip: clips[index],
            position: const Duration(seconds: 1),
            hasSoloMediaTrack: false,
          ),
          isTrue,
          reason: '${clips[index].id} should own its embedded audio',
        );
      }

      final explicitAudio = TimelineClip(
        id: 'explicit-overlay-audio',
        trackId: 'explicit-audio-track',
        type: TimelineTrackType.audio,
        label: 'Separated overlay audio',
        assetId: clips[1].assetId,
        linkedClipId: clips[1].id,
        startTime: clips[1].startTime,
        endTime: clips[1].endTime,
        sourceStartTime: clips[1].sourceStartTime,
        sourceDuration: clips[1].sourceDuration,
      );
      final explicitAudioTrack = TimelineTrack(
        id: 'explicit-audio-track',
        name: 'Separated audio',
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        role: TimelineTrackRole.regular,
        clips: [explicitAudio],
      );
      final separatedTimeline = timeline.copyWith(
        tracks: [...visualTracks, explicitAudioTrack],
      );

      expect(
        previewVisualUsesEmbeddedAudioForTesting(
          timeline: separatedTimeline,
          visualTrack: visualTracks[1],
          visualClip: clips[1],
          position: const Duration(seconds: 1),
          hasSoloMediaTrack: false,
        ),
        isFalse,
        reason: 'an explicit linked lane must take ownership without doubling',
      );
      expect(
        resolvePreviewLinkedAudioMonitorForTesting(
          timeline: separatedTimeline,
          visualClip: clips[1],
          position: const Duration(seconds: 1),
        )?.clip.id,
        explicitAudio.id,
        reason: 'regular separated-audio lanes are valid playback owners',
      );
      expect(
        shouldCreateTimelineAudioPreviewForTesting(
          track: explicitAudioTrack,
          clip: explicitAudio,
          hasSoloMediaTrack: false,
        ),
        isTrue,
      );
      final shiftedExplicitAudio = explicitAudio.copyWith(
        startTime: const Duration(milliseconds: 400),
        endTime: const Duration(milliseconds: 4600),
      );
      final shiftedTimeline = timeline.copyWith(
        tracks: [
          ...visualTracks,
          explicitAudioTrack.copyWith(clips: [shiftedExplicitAudio]),
        ],
      );
      expect(
        previewVisualUsesEmbeddedAudioForTesting(
          timeline: shiftedTimeline,
          visualTrack: visualTracks[1],
          visualClip: clips[1],
          position: const Duration(seconds: 1),
          hasSoloMediaTrack: false,
        ),
        isFalse,
        reason: 'moving separated audio must not re-enable embedded audio',
      );
      expect(
        resolvePreviewLinkedAudioMonitorForTesting(
          timeline: shiftedTimeline,
          visualClip: clips[1],
          position: const Duration(seconds: 1),
        ),
        isNull,
        reason: 'a shifted lane needs its own audio follower controller',
      );
      for (final index in const [0, 2]) {
        expect(
          previewVisualUsesEmbeddedAudioForTesting(
            timeline: separatedTimeline,
            visualTrack: visualTracks[index],
            visualClip: clips[index],
            position: const Duration(seconds: 1),
            hasSoloMediaTrack: false,
          ),
          isTrue,
        );
      }
    },
  );

  test('base layer accepts video, images, GIFs, and stickers only', () {
    TimelineClip clip(TimelineTrackType type) => TimelineClip(
      id: type.name,
      trackId: 'base-track',
      type: type,
      label: type.name,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
    );

    for (final type in const [
      TimelineTrackType.video,
      TimelineTrackType.image,
      TimelineTrackType.gif,
      TimelineTrackType.sticker,
    ]) {
      expect(isPreviewBaseLayerClipForTesting(clip(type)), isTrue);
    }
    for (final type in const [
      TimelineTrackType.audio,
      TimelineTrackType.subtitle,
      TimelineTrackType.text,
      TimelineTrackType.effect,
    ]) {
      expect(isPreviewBaseLayerClipForTesting(clip(type)), isFalse);
    }
  });

  test('forward base controller can monitor its exact linked source audio', () {
    final asset = EditorAssetReference(
      id: 'asset',
      type: EditorAssetType.video,
      label: 'Video',
      sourcePath: 'video.mp4',
    );
    final base = TimelineClip(
      id: 'base',
      trackId: 'base-track',
      type: TimelineTrackType.video,
      label: 'Video',
      assetId: asset.id,
      startTime: const Duration(seconds: 1),
      endTime: const Duration(seconds: 5),
      sourceStartTime: const Duration(milliseconds: 250),
      sourceDuration: const Duration(seconds: 4),
      audioMix: const AudioMixSettings(muted: true),
    );
    final linkedAudio = TimelineClip(
      id: 'source-audio',
      trackId: 'source-audio-track',
      type: TimelineTrackType.audio,
      label: 'Video audio',
      assetId: asset.id,
      linkedClipId: base.id,
      startTime: base.startTime,
      endTime: base.endTime,
      sourceStartTime: base.sourceStartTime,
      sourceDuration: base.sourceDuration,
      audioMix: const AudioMixSettings(volume: 0.6),
    );
    final timeline = EditorTimeline(
      assets: [asset],
      tracks: [
        TimelineTrack(
          id: 'base-track',
          name: 'Video',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [base],
        ),
        TimelineTrack(
          id: 'source-audio-track',
          name: 'Source audio',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          role: TimelineTrackRole.sourceAudio,
          clips: [linkedAudio],
        ),
      ],
    );

    final monitor = resolvePreviewBaseAudioMonitorForTesting(
      timeline: timeline,
      baseClip: base,
      position: const Duration(seconds: 2),
    );
    expect(monitor?.clip.id, linkedAudio.id);
    expect(
      resolvePreviewBaseAudioMonitorForTesting(
        timeline: timeline,
        baseClip: base.copyWith(isReversed: true),
        position: const Duration(seconds: 2),
      ),
      isNull,
    );
    expect(
      resolvePreviewBaseAudioMonitorForTesting(
        timeline: timeline,
        baseClip: base.copyWith(freezeFrame: true),
        position: const Duration(seconds: 2),
      ),
      isNull,
    );
  });

  testWidgets(
    'preview suppresses fallback controllers while exact mix prepares',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const existingPath = 'pubspec.yaml';
      final sourceAsset = EditorAssetReference(
        id: 'source-asset',
        type: EditorAssetType.video,
        label: 'Source',
        sourcePath: existingPath,
        metadata: const {'hasAudio': true},
      );
      final audioAsset = EditorAssetReference(
        id: 'audio-asset',
        type: EditorAssetType.audio,
        label: 'Audio',
        sourcePath: existingPath,
      );
      final base = TimelineClip(
        id: 'base',
        trackId: 'base-track',
        type: TimelineTrackType.video,
        label: 'Base',
        assetId: sourceAsset.id,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
        audioMix: const AudioMixSettings(muted: true),
      );
      TimelineClip audio(String id, String trackId, {bool muted = false}) =>
          TimelineClip(
            id: id,
            trackId: trackId,
            type: TimelineTrackType.audio,
            label: id,
            assetId: audioAsset.id,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 2),
            audioMix: AudioMixSettings(muted: muted),
          );
      final sourceAudio = TimelineClip(
        id: 'linked-source-audio',
        trackId: 'source-track',
        type: TimelineTrackType.audio,
        label: 'Source audio',
        assetId: sourceAsset.id,
        linkedClipId: base.id,
        startTime: base.startTime,
        endTime: base.endTime,
        sourceStartTime: base.sourceStartTime,
        sourceDuration: base.sourceDuration,
      );
      final timeline = EditorTimeline(
        assets: [sourceAsset, audioAsset],
        tracks: [
          TimelineTrack(
            id: 'base-track',
            name: 'Base',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [base],
          ),
          TimelineTrack(
            id: 'source-track',
            name: 'Source audio',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
            role: TimelineTrackRole.sourceAudio,
            clips: [sourceAudio],
          ),
          TimelineTrack(
            id: 'audible-track',
            name: 'Audible',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
            clips: [audio('audible', 'audible-track')],
          ),
          TimelineTrack(
            id: 'muted-clip-track',
            name: 'Muted clip',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
            clips: [audio('muted-clip', 'muted-clip-track', muted: true)],
          ),
          TimelineTrack(
            id: 'muted-track',
            name: 'Muted track',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
            isMuted: true,
            clips: [audio('muted-track-clip', 'muted-track')],
          ),
        ],
      );
      container
          .read(editorProvider.notifier)
          .loadProject(
            videoPath: existingPath,
            projectId: 'audio-controller-filter',
            projectName: 'Audio controller filter',
            timeline: timeline,
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: VideoPreviewPanel(videoPath: existingPath)),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('preview-audio-processing-state')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('audio_audible')), findsNothing);
      expect(
        find.byKey(const ValueKey('audio_linked-source-audio')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('audio_muted-clip')), findsNothing);
      expect(
        find.byKey(const ValueKey('audio_muted-track-clip')),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('ducking intervals are merged once into stable timeline windows', () {
    final ducked = TimelineClip(
      id: 'music',
      trackId: 'music-track',
      type: TimelineTrackType.audio,
      label: 'Music',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 5),
      autoDuck: true,
    );
    TimelineClip speech(String id, int startMs, int endMs) => TimelineClip(
      id: id,
      trackId: 'speech-track',
      type: TimelineTrackType.audio,
      label: id,
      startTime: Duration(milliseconds: startMs),
      endTime: Duration(milliseconds: endMs),
    );
    final timeline = EditorTimeline(
      tracks: [
        TimelineTrack(
          id: 'music-track',
          name: 'Music',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          clips: [ducked],
        ),
        TimelineTrack(
          id: 'speech-track',
          name: 'Speech',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          clips: [speech('a', 1000, 1500), speech('b', 1700, 2100)],
        ),
      ],
    );

    expect(
      buildPreviewDuckingIntervalsForTesting(timeline: timeline, clip: ducked),
      [(startMs: 1000, endMs: 2100)],
    );
  });

  test('ducking fallback honors selected sidechains and envelope timing', () {
    final ducked = TimelineClip(
      id: 'music',
      trackId: 'music-track',
      type: TimelineTrackType.audio,
      label: 'Music',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 5),
      autoDuck: true,
      duckAmount: 0.5,
      duckAttackMs: 400,
      duckReleaseMs: 600,
      duckSidechainTrackIds: const ['selected-speech'],
    );
    TimelineTrack speechTrack(String id, int startMs, int endMs) {
      return TimelineTrack(
        id: id,
        name: id,
        type: TimelineTrackType.text,
        section: TimelineTrackSection.textSubtitle,
        clips: [
          TimelineClip(
            id: '$id-clip',
            trackId: id,
            type: TimelineTrackType.text,
            label: id,
            startTime: Duration(milliseconds: startMs),
            endTime: Duration(milliseconds: endMs),
          ),
        ],
      );
    }

    final timeline = EditorTimeline(
      tracks: [
        TimelineTrack(
          id: 'music-track',
          name: 'Music',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          clips: [ducked],
        ),
        speechTrack('selected-speech', 1000, 2000),
        speechTrack('ignored-speech', 3000, 4000),
      ],
    );

    final intervals = buildPreviewDuckingIntervalsForTesting(
      timeline: timeline,
      clip: ducked,
    );
    expect(intervals, [(startMs: 1000, endMs: 2000)]);
    expect(
      previewDuckingGainForTesting(
        clip: ducked,
        position: const Duration(milliseconds: 800),
        intervals: intervals,
      ),
      closeTo(0.75, 0.0001),
    );
    expect(
      previewDuckingGainForTesting(
        clip: ducked,
        position: const Duration(milliseconds: 1500),
        intervals: intervals,
      ),
      0.5,
    );
    expect(
      previewDuckingGainForTesting(
        clip: ducked,
        position: const Duration(milliseconds: 2300),
        intervals: intervals,
      ),
      closeTo(0.75, 0.0001),
    );
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
