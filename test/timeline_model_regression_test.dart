import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('typed track compatibility', () {
    final visualTrack = TimelineTrack(
      id: 'visual',
      name: 'Visual overlay',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.overlay,
    );
    final effectTrack = TimelineTrack(
      id: 'effects',
      name: 'Effects',
      type: TimelineTrackType.effect,
      section: TimelineTrackSection.overlay,
    );
    final textTrack = TimelineTrack(
      id: 'text',
      name: 'Text',
      type: TimelineTrackType.text,
      section: TimelineTrackSection.textSubtitle,
    );
    final subtitleTrack = TimelineTrack(
      id: 'subtitles',
      name: 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
    );
    final audioTrack = TimelineTrack(
      id: 'audio',
      name: 'Audio',
      type: TimelineTrackType.audio,
      section: TimelineTrackSection.audio,
    );

    test('visual lanes accept only visual media', () {
      for (final type in const [
        TimelineTrackType.video,
        TimelineTrackType.image,
        TimelineTrackType.gif,
        TimelineTrackType.sticker,
      ]) {
        expect(visualTrack.acceptsClipType(type), isTrue);
      }
      expect(visualTrack.acceptsClipType(TimelineTrackType.effect), isFalse);
      expect(visualTrack.acceptsClipType(TimelineTrackType.audio), isFalse);
      expect(visualTrack.acceptsClipType(TimelineTrackType.text), isFalse);
    });

    test('effect, text, subtitle and audio lanes stay strict', () {
      expect(effectTrack.acceptsClipType(TimelineTrackType.effect), isTrue);
      expect(effectTrack.acceptsClipType(TimelineTrackType.image), isFalse);
      expect(textTrack.acceptsClipType(TimelineTrackType.text), isTrue);
      expect(textTrack.acceptsClipType(TimelineTrackType.subtitle), isFalse);
      expect(subtitleTrack.acceptsClipType(TimelineTrackType.subtitle), isTrue);
      expect(subtitleTrack.acceptsClipType(TimelineTrackType.text), isFalse);
      expect(audioTrack.acceptsClipType(TimelineTrackType.audio), isTrue);
      expect(audioTrack.acceptsClipType(TimelineTrackType.video), isFalse);
    });

    test('clip tools follow the media pipeline that can render them', () {
      expect(TimelineTrackType.video.supportsVisualEffects, isTrue);
      expect(TimelineTrackType.image.supportsClipAnimation, isTrue);
      expect(TimelineTrackType.text.supportsTransform, isTrue);
      expect(TimelineTrackType.text.supportsClipAnimation, isFalse);
      expect(TimelineTrackType.audio.supportsVisualEffects, isFalse);
      expect(TimelineTrackType.audio.supportsSourceTiming, isTrue);
      expect(TimelineTrackType.audio.supportsReversePlayback, isFalse);
      expect(TimelineTrackType.video.supportsReversePlayback, isTrue);
      expect(TimelineTrackType.effect.supportsTransform, isFalse);
      expect(const TimelineTransform().isIdentity, isTrue);
      expect(const TimelineTransform(scale: 1.2).isIdentity, isFalse);
      expect(const AudioMixSettings().hasMixAdjustment, isFalse);
      expect(const AudioMixSettings(normalize: true).hasMixAdjustment, isTrue);
    });

    test('insertion skips locked and incompatible selected tracks', () {
      final lockedVisual = visualTrack.copyWith(isLocked: true);
      final fallbackVisual = TimelineTrack(
        id: 'visual_fallback',
        name: 'Visual fallback',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
      );
      final timeline = EditorTimeline(
        tracks: [lockedVisual, effectTrack, fallbackVisual],
      );

      expect(
        timeline
            .insertionTrackFor(
              section: TimelineTrackSection.overlay,
              clipType: TimelineTrackType.image,
              preferredTrackId: lockedVisual.id,
            )
            ?.id,
        fallbackVisual.id,
      );
      expect(
        timeline.insertionTrackFor(
          section: TimelineTrackSection.overlay,
          clipType: TimelineTrackType.effect,
          preferredTrackId: fallbackVisual.id,
        ),
        same(effectTrack),
      );
    });

    test('audio capability follows video asset metadata', () {
      TimelineClip videoClip(String id, String assetId) => TimelineClip(
        id: id,
        trackId: 'base',
        type: TimelineTrackType.video,
        label: id,
        assetId: assetId,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
      );
      final audible = videoClip('audible', 'audible_asset');
      final silent = videoClip('silent', 'silent_asset');
      final timeline = EditorTimeline(
        assets: [
          EditorAssetReference(
            id: 'audible_asset',
            type: EditorAssetType.video,
            label: 'Audible',
            metadata: const {'hasAudio': true},
          ),
          EditorAssetReference(
            id: 'silent_asset',
            type: EditorAssetType.video,
            label: 'Silent',
            metadata: const {'hasAudio': false},
          ),
        ],
      );

      expect(timeline.clipHasAudio(audible), isTrue);
      expect(timeline.clipHasAudio(silent), isFalse);
    });

    test('transition and audio envelopes are capped at half the clip', () {
      final clip = TimelineClip(
        id: 'envelope',
        trackId: 'audio',
        type: TimelineTrackType.audio,
        label: 'Envelope',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
        introTransition: const ClipTransition(
          type: TransitionType.fade,
          durationMs: 1800,
        ),
        outroTransition: const ClipTransition(
          type: TransitionType.zoom,
          durationMs: 1200,
        ),
        audioMix: const AudioMixSettings(fadeInMs: 1600, fadeOutMs: 1400),
      );

      expect(clip.effectiveIntroTransitionMs, 1000);
      expect(clip.effectiveOutroTransitionMs, 1000);
      expect(clip.effectiveAudioFadeInMs, 1000);
      expect(clip.effectiveAudioFadeOutMs, 1000);
    });

    test('source captions follow clip speed and stay inside the clip', () {
      final clip = TimelineClip(
        id: 'fast_video',
        trackId: 'base',
        type: TimelineTrackType.video,
        label: 'Fast video',
        startTime: const Duration(seconds: 3),
        endTime: const Duration(seconds: 8),
        sourceStartTime: const Duration(seconds: 20),
        sourceDuration: const Duration(seconds: 10),
        playbackRate: 2,
      );
      final mapped = clip.mapSourceSubtitlesToTimeline([
        SubtitleEntry(
          id: 'first',
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 4),
          text: 'First',
          words: const [
            WordTiming(
              word: 'First',
              startTime: Duration(seconds: 2),
              endTime: Duration(seconds: 3),
            ),
          ],
        ),
        SubtitleEntry(
          id: 'clipped',
          startTime: const Duration(seconds: 9),
          endTime: const Duration(seconds: 12),
          text: 'Clipped',
        ),
      ]);

      expect(mapped, hasLength(2));
      expect(mapped.first.startTime, const Duration(seconds: 4));
      expect(mapped.first.endTime, const Duration(seconds: 5));
      expect(mapped.first.words!.single.startTime, const Duration(seconds: 4));
      expect(
        mapped.first.words!.single.endTime,
        const Duration(milliseconds: 4500),
      );
      expect(mapped.last.startTime, const Duration(milliseconds: 7500));
      expect(mapped.last.endTime, clip.endTime);
    });

    test('source captions and words reverse into timeline order', () {
      final clip = TimelineClip(
        id: 'reverse_video',
        trackId: 'base',
        type: TimelineTrackType.video,
        label: 'Reverse video',
        startTime: const Duration(seconds: 10),
        endTime: const Duration(seconds: 15),
        sourceStartTime: const Duration(seconds: 20),
        sourceDuration: const Duration(seconds: 10),
        playbackRate: 2,
        isReversed: true,
      );
      final mapped = clip.mapSourceSubtitlesToTimeline([
        SubtitleEntry(
          id: 'early_source',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 2),
          text: 'Early source',
        ),
        SubtitleEntry(
          id: 'late_source',
          startTime: const Duration(seconds: 6),
          endTime: const Duration(seconds: 10),
          text: 'Late source',
          words: const [
            WordTiming(
              word: 'two',
              startTime: Duration(seconds: 6),
              endTime: Duration(seconds: 7),
            ),
            WordTiming(
              word: 'three',
              startTime: Duration(seconds: 9),
              endTime: Duration(seconds: 10),
            ),
          ],
        ),
      ]);

      expect(mapped.map((entry) => entry.id), ['late_source', 'early_source']);
      expect(mapped.first.startTime, clip.startTime);
      expect(mapped.first.endTime, const Duration(seconds: 12));
      expect(mapped.first.words!.map((word) => word.word), ['two', 'three']);
      expect(mapped.first.words!.map((word) => word.startTime), [
        const Duration(milliseconds: 11500),
        const Duration(seconds: 10),
      ]);
      expect(mapped.last.startTime, const Duration(seconds: 14));
      expect(mapped.last.endTime, clip.endTime);
    });
  });

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
