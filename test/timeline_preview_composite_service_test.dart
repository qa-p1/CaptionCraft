import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/core/utils/timeline_preview_composite_service.dart';
import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:caption_craft/features/editor/models/export_settings.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  EditorTimeline overlappingVideos(
    int count, {
    CanvasSettings canvasSettings = const CanvasSettings(),
  }) {
    final asset = EditorAssetReference(
      id: 'shared-video',
      type: EditorAssetType.video,
      label: 'Shared video',
      sourcePath: '/fixtures/shared.mp4',
      metadata: const {
        'width': 1920,
        'height': 1080,
        'frameRate': 30,
        'hasAudio': true,
      },
    );
    return EditorTimeline(
      canvasSettings: canvasSettings,
      assets: [asset],
      tracks: [
        for (var index = 0; index < count; index++)
          TimelineTrack(
            id: 'video-track-$index',
            name: 'Video $index',
            type: TimelineTrackType.video,
            section: index == count - 1
                ? TimelineTrackSection.baseVideo
                : TimelineTrackSection.overlay,
            clips: [
              TimelineClip(
                id: 'video-$index',
                trackId: 'video-track-$index',
                type: TimelineTrackType.video,
                label: 'Video $index',
                assetId: asset.id,
                startTime: Duration.zero,
                endTime: const Duration(seconds: 10),
              ),
            ],
          ),
      ],
    );
  }

  PreviewCompositePlan buildPlan(EditorTimeline timeline) {
    return TimelinePreviewCompositeService.buildPlan(
      timeline: timeline,
      subtitleEntries: const [],
      globalSubtitleStyle: const SubtitleStyleModel(),
      fileExists: (_) => true,
      sourceVersion: (_) => 'fixture-v1',
    )!;
  }

  test('thirty overlapping videos collapse into one silent 480p plan', () {
    final timeline = overlappingVideos(30);
    final plan = buildPlan(timeline);
    const settings = ExportSettings(
      resolution: ExportResolution.p480,
      frameRate: ExportFrameRate.fps30,
      quality: ExportQuality.compact,
      includeAudio: false,
      burnSubtitles: true,
      saveToGallery: false,
    );
    final arguments = TimelineExportService.buildFfmpegArguments(
      timeline: timeline,
      inputs: plan.inputs,
      settings: settings,
      canvasSize: plan.canvasSize,
      timelineDuration: plan.timelineDuration,
      assPath: null,
      videoPreset: 'ultrafast',
      videoCrf: 30,
      outputPath: '/tmp/dense-preview.mp4',
    );
    final filterGraph = arguments[arguments.indexOf('-filter_complex') + 1];

    expect(plan.inputs, hasLength(30));
    expect(plan.maximumConcurrentDecoders, 30);
    expect(plan.canvasSize.width, 854);
    expect(plan.canvasSize.height, 480);
    expect(arguments.where((argument) => argument == '-i'), hasLength(30));
    expect(arguments, containsAllInOrder(['-map', '[vout]', '-an']));
    expect(arguments, containsAllInOrder(['-preset', 'ultrafast']));
    expect(arguments, containsAllInOrder(['-crf', '30']));
    expect(filterGraph, contains('overlay='));
  });

  test('small overlap stays live and half-open edges do not inflate load', () {
    final twoVideos = overlappingVideos(2);
    expect(
      TimelinePreviewCompositeService.maximumConcurrentVisualDecoders(
        twoVideos,
      ),
      2,
    );
    expect(
      TimelinePreviewCompositeService.buildPlan(
        timeline: twoVideos,
        subtitleEntries: const [],
        globalSubtitleStyle: const SubtitleStyleModel(),
        fileExists: (_) => true,
      ),
      isNull,
    );

    final asset = twoVideos.assets.single;
    final adjacent = EditorTimeline(
      assets: [asset],
      tracks: [
        for (var index = 0; index < 4; index++)
          TimelineTrack(
            id: 'adjacent-track-$index',
            name: 'Adjacent $index',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.overlay,
            clips: [
              TimelineClip(
                id: 'adjacent-$index',
                trackId: 'adjacent-track-$index',
                type: TimelineTrackType.video,
                label: 'Adjacent $index',
                assetId: asset.id,
                startTime: Duration(seconds: index),
                endTime: Duration(seconds: index + 1),
              ),
            ],
          ),
      ],
    );
    expect(
      TimelinePreviewCompositeService.maximumConcurrentVisualDecoders(adjacent),
      1,
    );
    expect(
      TimelinePreviewCompositeService.activeVisualDecoderCount(
        adjacent,
        const Duration(seconds: 1),
      ),
      1,
    );
  });

  test('advanced visual stacks use an export-parity proxy at low density', () {
    final plain = overlappingVideos(1);
    expect(
      TimelinePreviewCompositeService.buildPlan(
        timeline: plain,
        subtitleEntries: const [],
        globalSubtitleStyle: const SubtitleStyleModel(),
        fileExists: (_) => true,
      ),
      isNull,
    );

    final track = plain.tracks.single;
    final clip = track.clips.single;
    final effected = plain.copyWith(
      tracks: [
        track.copyWith(
          clips: [
            clip.copyWith(
              effectStack: EditorEffectStack(
                effects: [
                  EditorEffect(
                    type: EditorEffectType.gaussianBlur,
                    mask: const EditorEffectMask(
                      shape: EditorEffectMaskShape.ellipse,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
    final plan = TimelinePreviewCompositeService.buildPlan(
      timeline: effected,
      subtitleEntries: const [],
      globalSubtitleStyle: const SubtitleStyleModel(),
      fileExists: (_) => true,
      sourceVersion: (_) => 'fixture-v1',
    );

    expect(plan, isNotNull);
    expect(plan!.maximumConcurrentDecoders, 1);
    expect(plan.inputs, hasLength(1));
    expect(
      TimelinePreviewCompositeService.requiresRenderedEffectPreview(effected),
      isTrue,
    );
  });

  test('standard color controls request an export-parity preview proxy', () {
    final plain = overlappingVideos(1);
    final track = plain.tracks.single;
    final clip = track.clips.single;
    final corrected = plain.copyWith(
      tracks: [
        track.copyWith(
          clips: [
            clip.copyWith(
              colorAdjustments: const ClipColorAdjustments(
                exposure: 0.4,
                highlights: 0.2,
                whites: 0.15,
              ),
            ),
          ],
        ),
      ],
    );

    expect(
      TimelinePreviewCompositeService.requiresRenderedEffectPreview(corrected),
      isTrue,
    );
    expect(
      TimelinePreviewCompositeService.buildPlan(
        timeline: corrected,
        subtitleEntries: const [],
        globalSubtitleStyle: const SubtitleStyleModel(),
        fileExists: (_) => true,
      ),
      isNotNull,
    );
  });

  test('a missing source never produces a partial visual composite', () {
    final timeline = overlappingVideos(4);
    expect(
      TimelinePreviewCompositeService.buildPlan(
        timeline: timeline,
        subtitleEntries: const [],
        globalSubtitleStyle: const SubtitleStyleModel(),
        fileExists: (_) => false,
      ),
      isNull,
    );
  });

  test('fingerprint ignores audio-only edits but tracks visual changes', () {
    final timeline = overlappingVideos(4);
    final firstTrack = timeline.tracks.first;
    final firstClip = firstTrack.clips.single;
    final audioChanged = timeline.copyWith(
      tracks: [
        firstTrack.copyWith(
          clips: [
            firstClip.copyWith(
              audioMix: const AudioMixSettings(volume: 0.25),
              autoDuck: true,
              duckAmount: 0.1,
              duckAttackMs: 450,
              duckReleaseMs: 900,
              duckSidechainTrackIds: const ['dialogue'],
              linkedClipId: 'audio-owner',
              notes: 'Mix note',
              timelineColor: const Color(0xFF123456),
            ),
          ],
        ),
        ...timeline.tracks.skip(1),
      ],
    );
    final visualChanged = timeline.copyWith(
      tracks: [
        firstTrack.copyWith(
          clips: [
            firstClip.copyWith(
              transform: const TimelineTransform(offsetX: 120, scale: 1.4),
            ),
          ],
        ),
        ...timeline.tracks.skip(1),
      ],
    );

    final originalFingerprint = buildPlan(timeline).fingerprint;
    expect(buildPlan(audioChanged).fingerprint, originalFingerprint);
    expect(buildPlan(visualChanged).fingerprint, isNot(originalFingerprint));
  });

  test('custom portrait canvas is preserved at a bounded proxy size', () {
    final plan = buildPlan(
      overlappingVideos(
        4,
        canvasSettings: const CanvasSettings(
          customWidth: 1000,
          customHeight: 2000,
        ),
      ),
    );

    expect(plan.canvasSize.width, 480);
    expect(plan.canvasSize.height, 960);
    expect(plan.canvasSize.framesPerSecond, 30);
  });
}
