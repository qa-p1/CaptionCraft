import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workspace settings round-trip and normalize the work area', () {
    const settings = TimelineWorkspaceSettings(
      frameRate: 60,
      loopPlayback: true,
      showWaveforms: false,
      showThumbnails: false,
      showTimecode: true,
      showKeyframes: true,
      autoFollowPlayhead: true,
      showClipLabels: false,
      workAreaStart: Duration(milliseconds: 500),
      workAreaEnd: Duration(milliseconds: 2500),
    );

    final restored = TimelineWorkspaceSettings.fromJson(settings.toJson());

    expect(restored.frameRate, 60);
    expect(restored.loopPlayback, isTrue);
    expect(restored.showWaveforms, isFalse);
    expect(restored.normalizedWorkAreaStart, const Duration(milliseconds: 500));
    expect(restored.normalizedWorkAreaEnd, const Duration(milliseconds: 2500));
  });

  test('keyframes interpolate transforms and survive persistence', () {
    final clip = TimelineClip(
      id: 'animated',
      trackId: 'video',
      type: TimelineTrackType.video,
      label: 'Animated',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 4),
      transform: const TimelineTransform(scale: 1),
      keyframes: [
        TimelineKeyframe(
          id: 'start',
          time: Duration.zero,
          property: TimelineKeyframeProperty.scale,
          value: 1,
        ),
        TimelineKeyframe(
          id: 'end',
          time: const Duration(seconds: 4),
          property: TimelineKeyframeProperty.scale,
          value: 2,
        ),
      ],
      freezeFrame: true,
      stabilize: true,
      denoise: true,
      chromaKeyEnabled: true,
      chromaKeyColor: const Color(0xFF00FF00),
      notes: 'Hold on the hero frame',
      timelineColor: const Color(0xFF4F8CFF),
      autoDuck: true,
    );

    final restored = TimelineClip.fromJson(clip.toJson());
    expect(restored.hasKeyframes, isTrue);
    expect(
      restored.transformAt(const Duration(seconds: 2)).scale,
      closeTo(1.5, 0.0001),
    );
    expect(restored.freezeFrame, isTrue);
    expect(restored.stabilize, isTrue);
    expect(restored.denoise, isTrue);
    expect(restored.chromaKeyEnabled, isTrue);
    expect(restored.notes, 'Hold on the hero frame');
    expect(restored.autoDuck, isTrue);
  });

  test('freeze selection and blur-strength keyframes survive persistence', () {
    final clip = TimelineClip(
      id: 'freeze_blur',
      trackId: 'video',
      type: TimelineTrackType.video,
      label: 'Freeze and blur',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
      sourceDuration: const Duration(seconds: 2),
      freezeFrame: true,
      freezeFrameSourceTime: const Duration(milliseconds: 750),
      blur: const ClipBlurSettings(mode: ClipBlurMode.full, strength: 4),
      keyframes: [
        TimelineKeyframe(
          id: 'blur_start',
          time: Duration.zero,
          property: TimelineKeyframeProperty.blurStrength,
          value: 4,
        ),
        TimelineKeyframe(
          id: 'blur_end',
          time: const Duration(seconds: 1),
          property: TimelineKeyframeProperty.blurStrength,
          value: 20,
        ),
      ],
    );

    final restored = TimelineClip.fromJson(clip.toJson());

    expect(restored.freezeFrameSourceTime, const Duration(milliseconds: 750));
    expect(
      restored.effectiveFreezeFrameSourceTime,
      const Duration(milliseconds: 750),
    );
    expect(
      restored.blurAt(const Duration(milliseconds: 500)).strength,
      closeTo(12, 0.0001),
    );
    expect(
      restored.keyframes
          .where(
            (keyframe) =>
                keyframe.property == TimelineKeyframeProperty.blurStrength,
          )
          .map((keyframe) => keyframe.id),
      ['blur_start', 'blur_end'],
    );
  });

  test(
    'editor notifier supports multi-selection, keyframes, and track tools',
    () {
      final first = TimelineClip(
        id: 'first',
        trackId: 'video',
        type: TimelineTrackType.video,
        label: 'First',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
      );
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'video',
            name: 'Video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [first],
          ),
          TimelineTrack(
            id: 'audio',
            name: 'Audio',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
          ),
        ],
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(editorProvider.notifier);
      notifier.loadProject(
        videoPath: 'source.mp4',
        projectId: 'project',
        projectName: 'Project',
        timeline: timeline,
      );

      notifier.selectClipIds(['first']);
      expect(container.read(editorProvider).selectedClipIds, {'first'});
      expect(
        notifier.upsertKeyframe(
          clipId: 'first',
          property: TimelineKeyframeProperty.opacity,
          time: const Duration(seconds: 1),
          value: 0.5,
        ),
        isTrue,
      );
      expect(
        container.read(editorProvider).timeline.videoClips.single.keyframes,
        hasLength(1),
      );

      expect(notifier.renameTrack('audio', 'Music'), isTrue);
      expect(notifier.duplicateTrack('video'), isFalse);
      expect(notifier.duplicateTrack('audio'), isTrue);
      expect(container.read(editorProvider).timeline.tracks, hasLength(3));
      notifier.setAllTracks(collapsed: true);
      expect(
        container
            .read(editorProvider)
            .timeline
            .tracks
            .every((track) => track.isCollapsed),
        isTrue,
      );
    },
  );
}
