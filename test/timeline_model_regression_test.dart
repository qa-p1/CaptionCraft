import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('timeline effect clips', () {
    test('persist as asset-free overlay clips', () {
      final blur = TimelineClip.effect(
        id: 'effect_blur',
        trackId: 'track_effects',
        effectKind: TimelineEffectKind.blur,
        label: 'Soft blur',
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 4),
        blur: const ClipBlurSettings(mode: ClipBlurMode.full, strength: 18),
      );
      final filter = TimelineClip.effect(
        id: 'effect_filter',
        trackId: 'track_effects',
        effectKind: TimelineEffectKind.filter,
        label: 'Cinematic',
        startTime: const Duration(seconds: 4),
        endTime: const Duration(seconds: 7),
        colorAdjustments: const ClipColorAdjustments(
          contrast: 1.12,
          saturation: 0.88,
          vignette: 0.24,
        ),
      );
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'track_effects',
            name: 'Effects',
            type: TimelineTrackType.effect,
            section: TimelineTrackSection.overlay,
            clips: [blur, filter],
          ),
        ],
      );

      final json = timeline.toJson();
      final clipsJson =
          ((json['tracks'] as List).single as Map<String, dynamic>)['clips']
              as List;
      (clipsJson.first as Map<String, dynamic>)['assetId'] = 'legacy_asset';
      final restored = EditorTimeline.fromJson(json);
      final restoredTrack = restored.tracks.single;

      expect(restoredTrack.type, TimelineTrackType.effect);
      expect(restoredTrack.section, TimelineTrackSection.overlay);
      expect(restoredTrack.clips.map((clip) => clip.effectKind), [
        TimelineEffectKind.blur,
        TimelineEffectKind.filter,
      ]);
      expect(restoredTrack.clips.every((clip) => clip.assetId == null), isTrue);
      expect(restoredTrack.clips.first.blur.strength, 18);
      expect(restoredTrack.clips.last.colorAdjustments.vignette, 0.24);
    });

    test('base duration is not extended by overlay effects', () {
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'base',
            name: 'Video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [
              TimelineClip(
                id: 'video',
                trackId: 'base',
                type: TimelineTrackType.video,
                label: 'Video',
                startTime: Duration.zero,
                endTime: const Duration(seconds: 5),
              ),
            ],
          ),
          TimelineTrack(
            id: 'effects',
            name: 'Effects',
            type: TimelineTrackType.effect,
            section: TimelineTrackSection.overlay,
            clips: [
              TimelineClip.effect(
                id: 'long_effect',
                trackId: 'effects',
                effectKind: TimelineEffectKind.filter,
                label: 'Filter',
                startTime: Duration.zero,
                endTime: const Duration(seconds: 20),
              ),
            ],
          ),
        ],
      );

      expect(timeline.duration, const Duration(seconds: 20));
      expect(timeline.baseVideoDuration, const Duration(seconds: 5));
    });
  });

  group('legacy timeline canonicalization', () {
    test(
      'coalesces duplicate base and subtitle tracks without seeding lanes',
      () {
        final subtitle = SubtitleEntry(
          id: 'subtitle_1',
          startTime: const Duration(milliseconds: 400),
          endTime: const Duration(milliseconds: 1400),
          text: 'Updated caption',
        );
        final existingSubtitle = TimelineClip(
          id: subtitle.id,
          trackId: 'captions_old',
          type: TimelineTrackType.subtitle,
          label: 'Old caption',
          linkedClipId: 'video_1',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          enabled: false,
          text: 'Old caption',
        );
        final video = TimelineClip(
          id: 'video_1',
          trackId: 'video_old',
          type: TimelineTrackType.video,
          label: 'Source',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 5),
        );
        final timeline = EditorTimeline(
          tracks: [
            TimelineTrack(
              id: 'video_empty',
              name: 'Empty video',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.baseVideo,
            ),
            TimelineTrack(
              id: 'video_old',
              name: 'Video',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.baseVideo,
              clips: [video],
            ),
            TimelineTrack(
              id: 'captions_old',
              name: 'Captions',
              type: TimelineTrackType.subtitle,
              section: TimelineTrackSection.textSubtitle,
              isLocked: true,
              isHidden: true,
              clips: [existingSubtitle],
            ),
            TimelineTrack(
              id: 'captions_duplicate',
              name: 'Duplicate captions',
              type: TimelineTrackType.subtitle,
              section: TimelineTrackSection.textSubtitle,
            ),
          ],
        );

        final synced = timeline.syncLegacySubtitles(
          subtitles: [subtitle],
          globalStyle: const SubtitleStyleModel(),
          videoPath: '/media/source.mp4',
          durationMs: 5000,
        );
        final trackIds = synced.tracks.map((track) => track.id).toList();
        final clipIds = synced.tracks
            .expand((track) => track.clips)
            .map((clip) => clip.id)
            .toList();
        final subtitleTrack = synced.primarySubtitleTrack!;
        final syncedSubtitle = subtitleTrack.clips.single;

        expect(synced.tracks, hasLength(2));
        expect(trackIds.toSet(), hasLength(trackIds.length));
        expect(clipIds.toSet(), hasLength(clipIds.length));
        expect(
          synced.tracks.where(
            (track) => track.section == TimelineTrackSection.baseVideo,
          ),
          hasLength(1),
        );
        expect(subtitleTrack.isLocked, isTrue);
        expect(subtitleTrack.isHidden, isTrue);
        expect(syncedSubtitle.linkedClipId, 'video_1');
        expect(syncedSubtitle.enabled, isFalse);
        expect(syncedSubtitle.text, 'Updated caption');
        expect(syncedSubtitle.startTime, subtitle.startTime);
        expect(syncedSubtitle.endTime, subtitle.endTime);
        expect(
          synced.tracks.any(
            (track) =>
                track.section == TimelineTrackSection.overlay ||
                track.section == TimelineTrackSection.audio ||
                track.type == TimelineTrackType.text,
          ),
          isFalse,
        );
      },
    );

    test('drops duplicate track and clip ids when restoring JSON', () {
      TimelineTrack duplicateTrack(String name) => TimelineTrack(
        id: 'duplicate_track',
        name: name,
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        clips: [
          TimelineClip(
            id: 'duplicate_clip',
            trackId: 'wrong_track',
            type: TimelineTrackType.audio,
            label: name,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 1),
          ),
        ],
      );

      final restored = EditorTimeline.fromJson(
        EditorTimeline(
          tracks: [duplicateTrack('First'), duplicateTrack('Second')],
        ).toJson(),
      );

      expect(restored.tracks, hasLength(1));
      expect(restored.tracks.single.clips, hasLength(1));
      expect(restored.tracks.single.clips.single.trackId, 'duplicate_track');
    });
  });
}
