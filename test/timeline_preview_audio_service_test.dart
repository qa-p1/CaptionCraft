import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/core/utils/timeline_preview_audio_service.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PreviewAudioMixPlan buildPlan(EditorTimeline timeline) {
    return TimelinePreviewAudioService.buildPlan(
      timeline: timeline,
      fileExists: (_) => true,
      sourceVersion: (_) => 'fixture-v1',
    )!;
  }

  test('thirty overlapping videos render through one limited audio bus', () {
    final asset = EditorAssetReference(
      id: 'shared-video',
      type: EditorAssetType.video,
      label: 'Shared video',
      sourcePath: '/fixtures/shared.mp4',
      metadata: const {'hasAudio': true},
    );
    final tracks = [
      for (var index = 0; index < 30; index++)
        TimelineTrack(
          id: 'overlay-$index',
          name: 'Overlay $index',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.overlay,
          clips: [
            TimelineClip(
              id: 'video-$index',
              trackId: 'overlay-$index',
              type: TimelineTrackType.video,
              label: 'Video $index',
              assetId: asset.id,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 10),
            ),
          ],
        ),
    ];
    final timeline = EditorTimeline(assets: [asset], tracks: tracks);

    final plan = buildPlan(timeline);
    final arguments = TimelineExportService.buildPreviewAudioMixArguments(
      timeline: timeline,
      inputs: plan.inputs,
      timelineDuration: plan.timelineDuration,
      outputPath: '/tmp/preview.m4a',
    );
    final filterGraph = arguments[arguments.indexOf('-filter_complex') + 1];

    expect(plan.inputs, hasLength(30));
    expect(plan.maximumConcurrentVoices, 30);
    expect(arguments.where((argument) => argument == '-i'), hasLength(30));
    expect(filterGraph, contains('amix=inputs=30'));
    expect(filterGraph, contains('normalize=0'));
    expect(
      filterGraph,
      contains('alimiter=limit=0.95:attack=5:release=50:latency=1'),
    );
    expect(arguments, containsAllInOrder(['-map', '[aout]', '-vn']));
    expect(arguments, containsAllInOrder(['-ar', '48000', '-ac', '2']));
  });

  test('separated linked audio is the sole owner of a video source', () {
    final asset = EditorAssetReference(
      id: 'video-asset',
      type: EditorAssetType.video,
      label: 'Video',
      sourcePath: '/fixtures/video.mp4',
      metadata: const {'hasAudio': true},
    );
    final visual = TimelineClip(
      id: 'visual',
      trackId: 'base',
      type: TimelineTrackType.video,
      label: 'Visual',
      assetId: asset.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 5),
    );
    final separated = TimelineClip(
      id: 'separated-audio',
      trackId: 'audio',
      type: TimelineTrackType.audio,
      label: 'Separated audio',
      assetId: asset.id,
      linkedClipId: visual.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 5),
    );
    final timeline = EditorTimeline(
      assets: [asset],
      tracks: [
        TimelineTrack(
          id: 'base',
          name: 'Base',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [visual],
        ),
        TimelineTrack(
          id: 'audio',
          name: 'Audio',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          clips: [separated],
        ),
      ],
    );

    final plan = buildPlan(timeline);

    expect(plan.inputs, hasLength(1));
    expect(plan.inputs.single.clip.id, separated.id);
  });

  test('disabled separated audio does not revive embedded visual audio', () {
    final asset = EditorAssetReference(
      id: 'video-asset',
      type: EditorAssetType.video,
      label: 'Video',
      sourcePath: '/fixtures/video.mp4',
      metadata: const {'hasAudio': true},
    );
    final visual = TimelineClip(
      id: 'visual',
      trackId: 'base',
      type: TimelineTrackType.video,
      label: 'Visual',
      assetId: asset.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 5),
    );
    final disabledAudio = TimelineClip(
      id: 'disabled-audio',
      trackId: 'audio',
      type: TimelineTrackType.audio,
      label: 'Disabled audio',
      assetId: asset.id,
      linkedClipId: visual.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 5),
      enabled: false,
    );
    final timeline = EditorTimeline(
      assets: [asset],
      tracks: [
        TimelineTrack(
          id: 'base',
          name: 'Base',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [visual],
        ),
        TimelineTrack(
          id: 'audio',
          name: 'Audio',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          clips: [disabledAudio],
        ),
      ],
    );

    expect(
      TimelinePreviewAudioService.buildPlan(
        timeline: timeline,
        fileExists: (_) => true,
        sourceVersion: (_) => 'fixture-v1',
      ),
      isNull,
    );
  });

  test('adjacent clips use half-open intervals for concurrency', () {
    final asset = EditorAssetReference(
      id: 'audio-asset',
      type: EditorAssetType.audio,
      label: 'Audio',
      sourcePath: '/fixtures/audio.m4a',
    );
    final clips = [
      TimelineClip(
        id: 'first',
        trackId: 'audio',
        type: TimelineTrackType.audio,
        label: 'First',
        assetId: asset.id,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
      ),
      TimelineClip(
        id: 'second',
        trackId: 'audio',
        type: TimelineTrackType.audio,
        label: 'Second',
        assetId: asset.id,
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 4),
      ),
    ];
    final timeline = EditorTimeline(
      assets: [asset],
      tracks: [
        TimelineTrack(
          id: 'audio',
          name: 'Audio',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          clips: clips,
        ),
      ],
    );

    expect(buildPlan(timeline).maximumConcurrentVoices, 1);
  });

  test('fingerprint ignores visual transforms but tracks audio changes', () {
    final asset = EditorAssetReference(
      id: 'video-asset',
      type: EditorAssetType.video,
      label: 'Video',
      sourcePath: '/fixtures/video.mp4',
      metadata: const {'hasAudio': true},
    );
    final clip = TimelineClip(
      id: 'video',
      trackId: 'overlay',
      type: TimelineTrackType.video,
      label: 'Video',
      assetId: asset.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 5),
    );
    final track = TimelineTrack(
      id: 'overlay',
      name: 'Overlay',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.overlay,
      clips: [clip],
    );
    final timeline = EditorTimeline(assets: [asset], tracks: [track]);
    final transformed = timeline.copyWith(
      tracks: [
        track.copyWith(
          clips: [
            clip.copyWith(
              transform: const TimelineTransform(
                offsetX: 120,
                scale: 1.8,
                rotation: 0.4,
              ),
            ),
          ],
        ),
      ],
    );
    final quieter = timeline.copyWith(
      tracks: [
        track.copyWith(
          clips: [clip.copyWith(audioMix: const AudioMixSettings(volume: 0.4))],
        ),
      ],
    );

    expect(buildPlan(transformed).fingerprint, buildPlan(timeline).fingerprint);
    expect(
      buildPlan(quieter).fingerprint,
      isNot(buildPlan(timeline).fingerprint),
    );
  });
}
