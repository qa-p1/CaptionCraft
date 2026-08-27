import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/keyframe_curve_presets.dart';
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
      previewMediaQuality: PreviewMediaQuality.proxy,
    );

    final restored = TimelineWorkspaceSettings.fromJson(settings.toJson());

    expect(restored.frameRate, 60);
    expect(restored.loopPlayback, isTrue);
    expect(restored.showWaveforms, isFalse);
    expect(restored.normalizedWorkAreaStart, const Duration(milliseconds: 500));
    expect(restored.normalizedWorkAreaEnd, const Duration(milliseconds: 2500));
    expect(restored.previewMediaQuality, PreviewMediaQuality.proxy);
    expect(
      TimelineWorkspaceSettings.fromJson(const {}).previewMediaQuality,
      PreviewMediaQuality.auto,
    );
  });

  test('professional audio controls survive persistence with old defaults', () {
    final clip = TimelineClip(
      id: 'music',
      trackId: 'music-track',
      type: TimelineTrackType.audio,
      label: 'Music',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 5),
      audioMix: const AudioMixSettings(
        volume: 0.8,
        fadeInMs: 500,
        fadeOutMs: 750,
        fadeInShape: AudioFadeShape.logarithmic,
        fadeOutShape: AudioFadeShape.exponential,
      ),
      autoDuck: true,
      duckAmount: 0.55,
      duckAttackMs: 240,
      duckReleaseMs: 620,
      duckSidechainTrackIds: const ['dialogue'],
    );
    final timeline = EditorTimeline(
      tracks: [
        TimelineTrack(
          id: 'music-track',
          name: 'Music',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          audioGain: 0.7,
          audioPan: -0.25,
          clips: [clip],
        ),
      ],
    );

    final restored = EditorTimeline.fromJson(timeline.toJson());
    final restoredTrack = restored.tracks.single;
    final restoredClip = restoredTrack.clips.single;
    final legacyMix = AudioMixSettings.fromJson({'volume': 0.5});

    expect(restoredTrack.audioGain, 0.7);
    expect(restoredTrack.audioPan, -0.25);
    expect(restoredClip.audioMix.fadeInShape, AudioFadeShape.logarithmic);
    expect(restoredClip.audioMix.fadeOutShape, AudioFadeShape.exponential);
    expect(restoredClip.duckAttackMs, 240);
    expect(restoredClip.duckReleaseMs, 620);
    expect(restoredClip.duckSidechainTrackIds, ['dialogue']);
    expect(legacyMix.fadeInShape, AudioFadeShape.linear);
    expect(legacyMix.fadeOutShape, AudioFadeShape.linear);
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

  test('keyframe interpolation supports holds, easing, and custom curves', () {
    TimelineClip animated(TimelineKeyframeInterpolation interpolation) {
      return TimelineClip(
        trackId: 'video',
        type: TimelineTrackType.video,
        label: 'Animated',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
        keyframes: [
          TimelineKeyframe(
            time: Duration.zero,
            property: TimelineKeyframeProperty.opacity,
            value: 0,
            interpolation: interpolation,
            curve: const TimelineBezierCurve(
              x1: 0.2,
              y1: 0.8,
              x2: 0.4,
              y2: 1.2,
            ),
          ),
          TimelineKeyframe(
            time: const Duration(seconds: 1),
            property: TimelineKeyframeProperty.opacity,
            value: 1,
          ),
        ],
      );
    }

    expect(
      animated(TimelineKeyframeInterpolation.hold).keyframedValue(
        TimelineKeyframeProperty.opacity,
        const Duration(milliseconds: 999),
      ),
      0,
    );
    expect(
      animated(TimelineKeyframeInterpolation.hold).keyframedValue(
        TimelineKeyframeProperty.opacity,
        const Duration(seconds: 1),
      ),
      1,
    );
    expect(
      animated(TimelineKeyframeInterpolation.easeIn).keyframedValue(
        TimelineKeyframeProperty.opacity,
        const Duration(milliseconds: 500),
      ),
      lessThan(0.5),
    );

    final restored = TimelineClip.fromJson(
      animated(TimelineKeyframeInterpolation.cubicBezier).toJson(),
    );
    final first = restored.keyframes.first;
    expect(first.interpolation, TimelineKeyframeInterpolation.cubicBezier);
    expect(first.curve.x1, closeTo(0.2, 0.0001));
    expect(first.curve.y2, closeTo(1.2, 0.0001));
  });

  test('legacy keyframes default to linear interpolation', () {
    final restored = TimelineKeyframe.fromJson({
      'id': 'legacy',
      'timeMs': 250,
      'property': 'scale',
      'value': 1.5,
    });

    expect(restored.interpolation, TimelineKeyframeInterpolation.linear);
    expect(restored.curve.x1, 0);
    expect(restored.curve.x2, 1);
  });

  test('graph exposes fifteen standard curves plus custom Bézier editing', () {
    expect(timelineCurvePresets, hasLength(15));
    expect(
      timelineCurvePresets.map((preset) => preset.id).toSet(),
      hasLength(15),
    );
    expect(timelineCurvePresets.any((preset) => preset.curve.y2 > 1), isTrue);
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
      final originalFrame = container
          .read(editorProvider)
          .timeline
          .videoClips
          .single
          .keyframes
          .single;
      expect(
        notifier.upsertKeyframe(
          clipId: 'first',
          property: TimelineKeyframeProperty.opacity,
          time: const Duration(seconds: 1),
          value: 0.7,
          interpolation: TimelineKeyframeInterpolation.easeInOut,
        ),
        isTrue,
      );
      final updatedFrame = container
          .read(editorProvider)
          .timeline
          .videoClips
          .single
          .keyframes
          .single;
      expect(updatedFrame.id, originalFrame.id);
      expect(updatedFrame.value, 0.7);
      expect(
        updatedFrame.interpolation,
        TimelineKeyframeInterpolation.easeInOut,
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

  test(
    'state keyframes capture all channels and direct manipulation auto-keys',
    () {
      final clip = TimelineClip(
        id: 'stateful',
        trackId: 'video',
        type: TimelineTrackType.video,
        label: 'Stateful',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 4),
        blur: const ClipBlurSettings(mode: ClipBlurMode.full, strength: 6),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(editorProvider.notifier);
      notifier.loadProject(
        videoPath: 'source.mp4',
        projectId: 'state-project',
        projectName: 'State project',
        timeline: EditorTimeline(
          workspaceSettings: const TimelineWorkspaceSettings(frameRate: 30),
          tracks: [
            TimelineTrack(
              id: 'video',
              name: 'Base layer',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.baseVideo,
              clips: [clip],
            ),
          ],
        ),
      );

      expect(
        notifier.upsertKeyframeState(
          clipId: clip.id,
          absolutePosition: Duration.zero,
        ),
        isTrue,
      );
      var live = container.read(editorProvider).timeline.videoClips.single;
      expect(live.keyframes, hasLength(7));
      expect(live.keyframeStateTimes, [Duration.zero]);
      expect(live.transformAt(const Duration(seconds: 1)).scale, 1);

      expect(
        notifier.updateClipTransformAt(
          clipId: clip.id,
          absolutePosition: const Duration(seconds: 2),
          mapper: (current) => current.copyWith(
            offsetX: 100,
            scale: 2,
            rotation: 1,
            opacity: 0.5,
          ),
        ),
        isTrue,
      );
      live = container.read(editorProvider).timeline.videoClips.single;
      expect(live.keyframes, hasLength(14));
      expect(live.keyframeStateTimes, [
        Duration.zero,
        const Duration(seconds: 2),
      ]);
      expect(live.transform.scale, 1, reason: 'base state remains untouched');
      final middle = live.transformAt(const Duration(seconds: 1));
      expect(middle.scale, closeTo(1.5, 0.0001));
      expect(middle.offsetX, closeTo(50, 0.0001));
      expect(middle.rotation, closeTo(0.5, 0.0001));
      expect(middle.opacity, closeTo(0.75, 0.0001));
      expect(live.transformAt(const Duration(seconds: 3)).scale, 2);

      expect(
        notifier.setKeyframeStateCurve(
          clipId: clip.id,
          absolutePosition: Duration.zero,
          interpolation: TimelineKeyframeInterpolation.easeIn,
          curve: TimelineBezierCurve.easeIn,
        ),
        isTrue,
      );
      live = container.read(editorProvider).timeline.videoClips.single;
      expect(live.transformAt(const Duration(seconds: 1)).scale, lessThan(1.5));
      expect(
        live.keyframes
            .where((frame) => frame.time == Duration.zero)
            .every(
              (frame) =>
                  frame.interpolation == TimelineKeyframeInterpolation.easeIn,
            ),
        isTrue,
      );

      expect(
        notifier.removeKeyframeState(
          clipId: clip.id,
          absolutePosition: const Duration(seconds: 2),
        ),
        isTrue,
      );
      live = container.read(editorProvider).timeline.videoClips.single;
      expect(live.keyframes, hasLength(7));
      expect(live.keyframeStateTimes, [Duration.zero]);
    },
  );
}
