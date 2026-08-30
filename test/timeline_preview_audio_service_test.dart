import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/core/utils/timeline_preview_audio_service.dart';
import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
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

  test('unlinked separated audio remains the sole persistent owner', () {
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
      embeddedAudioSeparated: true,
    );
    final separated = TimelineClip(
      id: 'separated-audio',
      trackId: 'audio',
      type: TimelineTrackType.audio,
      label: 'Separated audio',
      assetId: asset.id,
      separatedFromClipId: visual.id,
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

  test('a separated video never silently revives embedded audio', () {
    final asset = EditorAssetReference(
      id: 'video-asset',
      type: EditorAssetType.video,
      label: 'Video',
      sourcePath: '/fixtures/video.mp4',
      metadata: const {'hasAudio': true},
    );
    final timeline = EditorTimeline(
      assets: [asset],
      tracks: [
        TimelineTrack(
          id: 'base',
          name: 'Base',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [
            TimelineClip(
              id: 'visual',
              trackId: 'base',
              type: TimelineTrackType.video,
              label: 'Visual',
              assetId: asset.id,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 5),
              embeddedAudioSeparated: true,
            ),
          ],
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
    final frozen = timeline.copyWith(
      tracks: [
        track.copyWith(
          clips: [
            clip.copyWith(
              freezeFrame: true,
              freezeFrameSourceTime: const Duration(seconds: 2),
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
    final trackMixed = timeline.copyWith(
      tracks: [track.copyWith(audioGain: 0.7, audioPan: 0.2)],
    );

    expect(buildPlan(transformed).fingerprint, buildPlan(timeline).fingerprint);
    expect(buildPlan(frozen).fingerprint, buildPlan(timeline).fingerprint);
    expect(
      buildPlan(quieter).fingerprint,
      isNot(buildPlan(timeline).fingerprint),
    );
    expect(
      buildPlan(trackMixed).fingerprint,
      isNot(buildPlan(timeline).fingerprint),
    );
  });

  test('bus and project processing invalidate preview audio safely', () {
    final asset = EditorAssetReference(
      id: 'audio-asset',
      type: EditorAssetType.audio,
      label: 'Dialogue',
      sourcePath: '/fixtures/dialogue.wav',
    );
    final clip = TimelineClip(
      id: 'dialogue',
      trackId: 'dialogue-track',
      type: TimelineTrackType.audio,
      label: 'Dialogue',
      assetId: asset.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
    );
    final bus = TimelineAudioBus(
      id: 'dialogue-bus',
      name: 'Dialogue',
      effectStack: EditorEffectStack(
        effects: [EditorEffect(type: EditorEffectType.compressor)],
      ),
    );
    final track = TimelineTrack(
      id: 'dialogue-track',
      name: 'Dialogue',
      type: TimelineTrackType.audio,
      section: TimelineTrackSection.audio,
      audioBusId: bus.id,
      clips: [clip],
    );
    final timeline = EditorTimeline(
      assets: [asset],
      tracks: [track],
      audioBuses: [bus],
    );
    final baseline = buildPlan(timeline).fingerprint;
    final busChanged = timeline.copyWith(
      audioBuses: [bus.copyWith(gain: 0.7, pan: 0.2)],
    );
    final projectChanged = timeline.copyWith(
      projectEffectStack: EditorEffectStack(
        effects: [EditorEffect(type: EditorEffectType.limiter)],
      ),
    );

    expect(buildPlan(busChanged).fingerprint, isNot(baseline));
    expect(buildPlan(projectChanged).fingerprint, isNot(baseline));
    expect(
      TimelinePreviewAudioService.buildPlan(
        timeline: timeline.copyWith(audioBuses: [bus.copyWith(muted: true)]),
        fileExists: (_) => true,
      ),
      isNull,
    );
  });

  test(
    'preview bus applies track mix, shaped fades, duck timing and limiter',
    () {
      final asset = EditorAssetReference(
        id: 'music-asset',
        type: EditorAssetType.audio,
        label: 'Music',
        sourcePath: '/fixtures/music.m4a',
      );
      final music = TimelineClip(
        id: 'music',
        trackId: 'music-track',
        type: TimelineTrackType.audio,
        label: 'Music',
        assetId: asset.id,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 4),
        audioMix: const AudioMixSettings(
          volume: 0.8,
          pan: -0.2,
          normalize: true,
          fadeInMs: 500,
          fadeOutMs: 700,
          fadeInShape: AudioFadeShape.logarithmic,
          fadeOutShape: AudioFadeShape.exponential,
        ),
        autoDuck: true,
        duckAmount: 0.5,
        duckAttackMs: 240,
        duckReleaseMs: 620,
        duckSidechainTrackIds: const ['dialogue'],
      );
      final timeline = EditorTimeline(
        assets: [asset],
        tracks: [
          TimelineTrack(
            id: 'dialogue',
            name: 'Dialogue',
            type: TimelineTrackType.subtitle,
            section: TimelineTrackSection.textSubtitle,
            clips: [
              TimelineClip(
                id: 'speech',
                trackId: 'dialogue',
                type: TimelineTrackType.subtitle,
                label: 'Speech',
                startTime: const Duration(seconds: 1),
                endTime: const Duration(seconds: 2),
              ),
            ],
          ),
          TimelineTrack(
            id: 'music-track',
            name: 'Music',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
            audioGain: 0.5,
            audioPan: 0.3,
            clips: [music],
          ),
        ],
      );
      final plan = buildPlan(timeline);
      final arguments = TimelineExportService.buildPreviewAudioMixArguments(
        timeline: timeline,
        inputs: plan.inputs,
        timelineDuration: plan.timelineDuration,
        outputPath: '/tmp/preview.m4a',
      );
      final graph = arguments[arguments.indexOf('-filter_complex') + 1];

      expect(graph, contains('loudnorm=I=-16:LRA=11:TP=-1.5'));
      expect(graph, contains('curve=log'));
      expect(graph, contains('curve=exp'));
      expect(graph, contains('pan=stereo'));
      expect(graph, contains('clip((0.8)'));
      expect(graph, contains('*0.5'));
      expect(graph, contains('0.24'));
      expect(graph, contains('0.62'));
      expect(
        graph,
        contains('alimiter=limit=0.95:attack=5:release=50:latency=1'),
      );
    },
  );
}
