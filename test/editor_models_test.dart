import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/features/editor/models/export_settings.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('timeline persistence', () {
    test('all clip transition presets survive project persistence', () {
      for (final type in TransitionType.values) {
        final restored = ClipTransition.fromJson(
          ClipTransition(type: type, durationMs: 725).toJson(),
        );
        expect(restored.type, type);
        expect(restored.durationMs, 725);
      }
    });

    test(
      'round-trips professional clip, track, canvas, and marker settings',
      () {
        final asset = EditorAssetReference(
          id: 'asset',
          type: EditorAssetType.video,
          label: 'Camera A',
          sourcePath: '/media/camera-a.mp4',
          metadata: const {
            'durationMs': 5000,
            'width': 1920,
            'height': 1080,
            'hasAudio': true,
            'frameRate': 29.97,
          },
        );
        final clip = TimelineClip(
          id: 'clip',
          trackId: 'track',
          type: TimelineTrackType.video,
          label: 'Camera A',
          assetId: asset.id,
          startTime: const Duration(milliseconds: 250),
          endTime: const Duration(milliseconds: 4250),
          sourceStartTime: const Duration(milliseconds: 700),
          sourceDuration: const Duration(milliseconds: 5000),
          playbackRate: 1.25,
          isReversed: true,
          fitMode: ClipFitMode.contain,
          crop: const ClipCropSettings(
            left: 0.08,
            top: 0.12,
            right: 0.06,
            bottom: 0.04,
          ),
          blur: const ClipBlurSettings(
            mode: ClipBlurMode.region,
            strength: 16,
            regionX: 0.18,
            regionY: 0.22,
            regionWidth: 0.46,
            regionHeight: 0.28,
          ),
          transform: const TimelineTransform(
            offsetX: 28,
            offsetY: -14,
            scale: 1.15,
            rotation: 0.12,
            opacity: 0.84,
            flipX: true,
          ),
          audioMix: const AudioMixSettings(
            volume: 0.72,
            fadeInMs: 250,
            fadeOutMs: 400,
            pan: -0.35,
            normalize: true,
          ),
          colorAdjustments: const ClipColorAdjustments(
            brightness: 0.08,
            contrast: 1.14,
            saturation: 0.82,
            temperature: 0.2,
            fade: 0.1,
            vignette: 0.24,
            sharpen: 0.18,
          ),
          introTransition: const ClipTransition(
            type: TransitionType.slideLeft,
            durationMs: 320,
          ),
        );
        final timeline = EditorTimeline(
          canvasSettings: const CanvasSettings(
            aspectRatioPreset: CanvasAspectRatioPreset.ratio9x16,
            backgroundColor: Color(0xFF132019),
            showSafeAreas: false,
            showGrid: true,
            gridDivisions: 4,
            snapToGuides: false,
          ),
          assets: [asset],
          tracks: [
            TimelineTrack(
              id: 'track',
              name: 'Hero angle',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.baseVideo,
              isLocked: true,
              isMuted: true,
              isSolo: true,
              clips: [clip],
            ),
          ],
          markers: [
            TimelineMarker(
              id: 'marker',
              position: const Duration(milliseconds: 2100),
              label: 'Beat drop',
              type: TimelineMarkerType.beat,
              color: const Color(0xFFC7F36B),
            ),
          ],
        );

        final restored = EditorTimeline.fromJson(timeline.toJson());
        final restoredTrack = restored.tracks.single;
        final restoredClip = restoredTrack.clips.single;

        expect(restored.schemaVersion, EditorTimeline.currentSchemaVersion);
        expect(
          restored.canvasSettings.aspectRatioPreset,
          CanvasAspectRatioPreset.ratio9x16,
        );
        expect(restored.canvasSettings.showGrid, isTrue);
        expect(restored.canvasSettings.gridDivisions, 4);
        expect(restoredTrack.isSolo, isTrue);
        expect(restoredTrack.isLocked, isTrue);
        expect(restoredTrack.role, TimelineTrackRole.regular);
        expect(restoredClip.playbackRate, 1.25);
        expect(restoredClip.isReversed, isTrue);
        expect(restoredClip.crop.safeLeft, closeTo(0.08, 0.0001));
        expect(restoredClip.crop.visibleWidth, closeTo(0.86, 0.0001));
        expect(restoredClip.blur.mode, ClipBlurMode.region);
        expect(restoredClip.blur.safeStrength, 16);
        expect(restoredClip.blur.safeRegionWidth, closeTo(0.46, 0.0001));
        expect(restoredClip.transform.flipX, isTrue);
        expect(restoredClip.transform.opacity, closeTo(0.84, 0.0001));
        expect(restoredClip.audioMix.pan, closeTo(-0.35, 0.0001));
        expect(restoredClip.audioMix.normalize, isTrue);
        expect(restoredClip.colorAdjustments.vignette, closeTo(0.24, 0.0001));
        expect(restoredClip.introTransition.type, TransitionType.slideLeft);
        expect(restored.markers.single.type, TimelineMarkerType.beat);
        expect(restored.duration, const Duration(milliseconds: 4250));
        expect(restored.assetForClip(restoredClip)?.label, 'Camera A');
      },
    );

    test('old timeline JSON receives safe defaults', () {
      final restored = EditorTimeline.fromJson({
        'schemaVersion': 2,
        'assets': <dynamic>[],
        'tracks': [
          {
            'id': 'legacy_track',
            'name': 'Legacy',
            'type': 'video',
            'section': 'baseVideo',
            'clips': [
              {
                'id': 'legacy_clip',
                'trackId': 'legacy_track',
                'type': 'video',
                'label': 'Legacy clip',
                'startTimeMs': 0,
                'endTimeMs': 1000,
              },
            ],
          },
        ],
      });

      final clip = restored.tracks.single.clips.single;
      expect(restored.canvasSettings.showSafeAreas, isTrue);
      expect(restored.canvasSettings.showGrid, isFalse);
      expect(restored.tracks.single.isSolo, isFalse);
      expect(clip.playbackRate, 1);
      expect(clip.isReversed, isFalse);
      expect(clip.crop.isIdentity, isTrue);
      expect(clip.blur.mode, ClipBlurMode.none);
      expect(clip.colorAdjustments.isNeutral, isTrue);
      expect(clip.audioMix.pan, 0);
      expect(clip.audioMix.normalize, isFalse);
    });

    test('chroma key capability is limited to actual visual media', () {
      TimelineClip clip(TimelineTrackType type, {bool effect = false}) =>
          TimelineClip(
            type: type,
            trackId: 'track',
            label: type.name,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 1),
            effectKind: effect ? TimelineEffectKind.blur : null,
          );

      expect(clip(TimelineTrackType.image).supportsChromaKey, isTrue);
      expect(clip(TimelineTrackType.video).supportsChromaKey, isTrue);
      expect(clip(TimelineTrackType.gif).supportsChromaKey, isTrue);
      expect(clip(TimelineTrackType.sticker).supportsChromaKey, isTrue);
      expect(clip(TimelineTrackType.audio).supportsChromaKey, isFalse);
      expect(clip(TimelineTrackType.text).supportsChromaKey, isFalse);
      expect(
        clip(TimelineTrackType.effect, effect: true).supportsChromaKey,
        isFalse,
      );
    });

    test('legacy projects create and link a source asset automatically', () {
      final project = Project.fromJson({
        'id': 'legacy_project',
        'name': 'Legacy project',
        'videoPath': '/media/legacy.mp4',
        'durationMs': 3000,
        'subtitles': <dynamic>[],
        'createdAt': '2026-07-20T10:00:00.000',
        'lastModifiedAt': '2026-07-20T10:00:00.000',
      });

      final baseClip = project.timeline.tracks
          .firstWhere(
            (track) => track.section == TimelineTrackSection.baseVideo,
          )
          .clips
          .single;
      expect(baseClip.assetId, isNotNull);
      expect(
        project.timeline.assetForClip(baseClip)?.sourcePath,
        '/media/legacy.mp4',
      );
    });

    test('damaged legacy items fall back to an editable timeline', () {
      final project = Project.fromJson({
        'id': 'damaged_legacy_project',
        'name': 'Recovered project',
        'videoPath': '/media/recovered.mp4',
        'durationMs': 4000,
        'globalStyle': 'invalid-style',
        'subtitles': [
          {
            'startTimeMs': '250',
            'endTimeMs': '1750',
            'text': 'Recovered caption',
            'words': [
              {'word': 'Recovered', 'startTimeMs': '250', 'endTimeMs': '900'},
              'invalid-word',
            ],
          },
          'invalid-caption',
        ],
        'timeline': {
          'tracks': [42, 'invalid-track'],
        },
        'createdAt': '2026-07-20T10:00:00.000',
        'lastModifiedAt': '2026-07-20T10:00:00.000',
      });

      expect(project.subtitles, hasLength(1));
      expect(project.subtitles.single.text, 'Recovered caption');
      expect(
        project.subtitles.single.startTime,
        const Duration(milliseconds: 250),
      );
      expect(project.subtitles.single.words, hasLength(1));
      final baseTrack = project.timeline.tracks.firstWhere(
        (track) => track.section == TimelineTrackSection.baseVideo,
      );
      expect(baseTrack.clips, hasLength(1));
      expect(
        project.timeline.assetForClip(baseTrack.clips.single)?.sourcePath,
        '/media/recovered.mp4',
      );
    });
  });

  group('export sizing', () {
    test('portrait 1080p uses the short edge and stays even', () {
      final size = TimelineExportService.resolveCanvasSize(
        const CanvasSettings(
          aspectRatioPreset: CanvasAspectRatioPreset.ratio9x16,
        ),
        const ExportSettings(
          resolution: ExportResolution.p1080,
          frameRate: ExportFrameRate.fps60,
        ),
        sourceWidth: 3840,
        sourceHeight: 2160,
        sourceFrameRate: 29.97,
      );

      expect(size.width, 1080);
      expect(size.height, 1920);
      expect(size.framesPerSecond, 60);
      expect(size.width.isEven, isTrue);
      expect(size.height.isEven, isTrue);
    });

    test('source settings preserve dimensions and frame rate safely', () {
      final size = TimelineExportService.resolveCanvasSize(
        const CanvasSettings(),
        const ExportSettings(),
        sourceWidth: 1919,
        sourceHeight: 1079,
        sourceFrameRate: 23.976,
      );

      expect(size.width.isEven, isTrue);
      expect(size.height.isEven, isTrue);
      expect(size.framesPerSecond, 24);
      expect(size.aspectRatio, closeTo(1919 / 1079, 0.01));
    });
  });
}
