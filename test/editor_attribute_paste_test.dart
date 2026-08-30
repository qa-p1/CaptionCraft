import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/screens/editor_screen.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('attribute paste ignores settings unsupported by the target', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1180, 820);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final project = _projectWithVideoAndAudio();
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: EditorScreen(project: project),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));

    container.read(editorProvider.notifier)
      ..selectTrack('video_track')
      ..selectClip('video_clip');
    await tester.pump();
    await _runAttributeTool(tester, 'copy_attrs');

    container.read(editorProvider.notifier)
      ..selectTrack('audio_track')
      ..selectClip('audio_clip');
    await tester.pump();
    await _runAttributeTool(tester, 'paste_attrs');

    final pasted = container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'audio_clip');
    expect(pasted.transform.isIdentity, isTrue);
    expect(pasted.blur.mode, ClipBlurMode.none);
    expect(pasted.chromaKeyEnabled, isFalse);
    expect(pasted.freezeFrame, isFalse);
    expect(pasted.keyframes.map((keyframe) => keyframe.property), [
      TimelineKeyframeProperty.volume,
    ]);
    expect(pasted.audioMix.volume, closeTo(0.42, 0.0001));
    expect(pasted.autoDuck, isTrue);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _runAttributeTool(WidgetTester tester, String toolName) async {
  final more = find.byKey(const ValueKey('dock_primary_more'));
  await tester.ensureVisible(more);
  await tester.tap(more);
  await tester.pumpAndSettle();

  final toolKey = ValueKey('all_tools_clip_attributes_$toolName');
  final tool = find.byKey(toolKey);
  expect(tool, findsOneWidget);
  await tester.ensureVisible(tool);
  await tester.tap(tool);
  await tester.pumpAndSettle();
}

Project _projectWithVideoAndAudio() {
  const duration = Duration(seconds: 4);
  final videoAsset = EditorAssetReference(
    id: 'video_asset',
    type: EditorAssetType.video,
    label: 'Video',
    sourcePath: 'missing-video.mp4',
    metadata: const {'durationMs': 4000, 'hasAudio': true, 'frameRate': 30},
  );
  final audioAsset = EditorAssetReference(
    id: 'audio_asset',
    type: EditorAssetType.audio,
    label: 'Audio',
    sourcePath: 'missing-audio.wav',
    metadata: const {'durationMs': 4000, 'hasAudio': true},
  );
  final source = TimelineClip(
    id: 'video_clip',
    trackId: 'video_track',
    type: TimelineTrackType.video,
    label: 'Video',
    assetId: videoAsset.id,
    startTime: Duration.zero,
    endTime: duration,
    sourceDuration: duration,
    transform: const TimelineTransform(
      offsetX: 42,
      rotation: 0.4,
      opacity: 0.6,
    ),
    audioMix: const AudioMixSettings(volume: 0.42, pan: 0.3),
    blur: const ClipBlurSettings(mode: ClipBlurMode.full, strength: 18),
    chromaKeyEnabled: true,
    freezeFrame: true,
    freezeFrameSourceTime: const Duration(milliseconds: 900),
    autoDuck: true,
    keyframes: [
      TimelineKeyframe(
        time: const Duration(milliseconds: 500),
        property: TimelineKeyframeProperty.positionX,
        value: 80,
      ),
      TimelineKeyframe(
        time: const Duration(milliseconds: 500),
        property: TimelineKeyframeProperty.volume,
        value: 0.35,
      ),
    ],
  );
  final target = TimelineClip(
    id: 'audio_clip',
    trackId: 'audio_track',
    type: TimelineTrackType.audio,
    label: 'Audio',
    assetId: audioAsset.id,
    startTime: Duration.zero,
    endTime: duration,
    sourceDuration: duration,
  );
  final timeline = EditorTimeline(
    assets: [videoAsset, audioAsset],
    tracks: [
      TimelineTrack(
        id: 'video_track',
        name: 'Video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [source],
      ),
      TimelineTrack(
        id: 'audio_track',
        name: 'Audio',
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        clips: [target],
      ),
    ],
  );
  return Project(
    id: 'paste-project',
    name: 'Paste attributes',
    videoPath: 'missing-video.mp4',
    durationMs: duration.inMilliseconds,
    timeline: timeline,
  )..cacheVideoAvailability(true);
}
