import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workspace persistence clamps malformed frame rates', () {
    expect(
      TimelineWorkspaceSettings.fromJson(const {'frameRate': 0}).frameRate,
      1,
    );
    expect(
      TimelineWorkspaceSettings.fromJson(const {'frameRate': 240}).frameRate,
      120,
    );
    expect(
      TimelineWorkspaceSettings.fromJson(const {'frameRate': '24'}).frameRate,
      24,
    );
  });

  group('typed track compatibility', () {
    final visualTrack = TimelineTrack(
      id: 'visual',
      name: 'Visual overlay',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.overlay,
    );
    final legacyEffectTrack = TimelineTrack(
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

    test('overlay lanes accept visual media and visual effects', () {
      for (final type in const [
        TimelineTrackType.video,
        TimelineTrackType.image,
        TimelineTrackType.gif,
        TimelineTrackType.sticker,
      ]) {
        expect(visualTrack.acceptsClipType(type), isTrue);
      }
      expect(visualTrack.acceptsClipType(TimelineTrackType.effect), isTrue);
      expect(visualTrack.acceptsClipType(TimelineTrackType.audio), isFalse);
      expect(visualTrack.acceptsClipType(TimelineTrackType.text), isFalse);
    });

    test('the Base layer accepts video, images, GIFs, and stickers', () {
      final baseLayer = TimelineTrack(
        id: 'base',
        name: 'Source video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
      );

      for (final type in const [
        TimelineTrackType.video,
        TimelineTrackType.image,
        TimelineTrackType.gif,
        TimelineTrackType.sticker,
      ]) {
        expect(baseLayer.acceptsClipType(type), isTrue);
      }
      expect(baseLayer.acceptsClipType(TimelineTrackType.effect), isFalse);
      expect(baseLayer.acceptsClipType(TimelineTrackType.audio), isFalse);
      expect(baseLayer.displayName, 'Base layer');
    });

    test('image and GIF base clips round-trip with the legacy section key', () {
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'base',
            name: 'Main video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [
              TimelineClip(
                id: 'photo',
                trackId: 'base',
                type: TimelineTrackType.image,
                label: 'Photo',
                startTime: Duration.zero,
                endTime: const Duration(seconds: 3),
              ),
              TimelineClip(
                id: 'gif',
                trackId: 'base',
                type: TimelineTrackType.gif,
                label: 'GIF',
                startTime: const Duration(seconds: 3),
                endTime: const Duration(seconds: 6),
              ),
            ],
          ),
        ],
      );

      final json = timeline.toJson();
      expect((json['tracks'] as List).single['section'], 'baseVideo');
      final restored = EditorTimeline.fromJson(json);
      final base = restored.tracks.single;
      expect(base.name, 'Base layer');
      expect(base.clips.map((clip) => clip.type), [
        TimelineTrackType.image,
        TimelineTrackType.gif,
      ]);
      expect(restored.visualMediaClips, hasLength(2));
    });

    test('legacy effect lanes migrate as generic overlays', () {
      expect(
        legacyEffectTrack.acceptsClipType(TimelineTrackType.effect),
        isTrue,
      );
      expect(
        legacyEffectTrack.acceptsClipType(TimelineTrackType.image),
        isTrue,
      );
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
      expect(TimelineTrackType.text.supportsTransformKeyframes, isFalse);
      expect(TimelineTrackType.text.supportsClipAnimation, isFalse);
      expect(TimelineTrackType.audio.supportsVisualEffects, isFalse);
      expect(TimelineTrackType.audio.supportsSourceTiming, isTrue);
      expect(TimelineTrackType.audio.supportsReversePlayback, isFalse);
      expect(TimelineTrackType.video.supportsReversePlayback, isTrue);
      expect(TimelineTrackType.effect.supportsTransform, isTrue);
      expect(TimelineTrackType.effect.supportsTransformKeyframes, isFalse);
      expect(TimelineTrackType.video.supportsTransformKeyframes, isTrue);
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
      final timeline = EditorTimeline(tracks: [lockedVisual, fallbackVisual]);

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
        same(fallbackVisual),
      );
    });

    test('a locked caption lane does not block another caption source', () {
      final lockedCaptions = subtitleTrack.copyWith(isLocked: true);
      final secondCaptions = TimelineTrack(
        id: 'captions_second',
        name: 'Captions · overlay',
        type: TimelineTrackType.subtitle,
        section: TimelineTrackSection.textSubtitle,
      );
      final timeline = EditorTimeline(tracks: [lockedCaptions, secondCaptions]);

      expect(
        timeline
            .insertionTrackFor(
              section: TimelineTrackSection.textSubtitle,
              clipType: TimelineTrackType.subtitle,
              preferredTrackId: lockedCaptions.id,
            )
            ?.id,
        secondCaptions.id,
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

      expect(restoredTrack.type, TimelineTrackType.video);
      expect(restoredTrack.section, TimelineTrackSection.overlay);
      expect(restoredTrack.name, 'Overlay');
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
      expect(timeline.baseLayerDuration, const Duration(seconds: 5));
      expect(timeline.baseVideoDuration, timeline.baseLayerDuration);
    });
  });

  group('legacy embedded-audio migration', () {
    TimelineClip baseVideo({bool muted = true}) => TimelineClip(
      id: 'base_video',
      trackId: 'base',
      type: TimelineTrackType.video,
      label: 'Base video',
      assetId: 'video_asset',
      startTime: const Duration(seconds: 2),
      endTime: const Duration(seconds: 8),
      sourceStartTime: const Duration(seconds: 4),
      sourceDuration: const Duration(seconds: 6),
      audioMix: AudioMixSettings(muted: muted),
    );

    TimelineClip sourceAudio({Duration? startTime}) => TimelineClip(
      id: 'source_audio_clip',
      trackId: 'source_audio',
      type: TimelineTrackType.audio,
      label: 'Base video audio',
      assetId: 'video_asset',
      linkedClipId: 'base_video',
      startTime: startTime ?? const Duration(seconds: 2),
      endTime: startTime == null
          ? const Duration(seconds: 8)
          : startTime + const Duration(seconds: 6),
      sourceStartTime: const Duration(seconds: 4),
      sourceDuration: const Duration(seconds: 6),
      audioMix: const AudioMixSettings(volume: 0.55, fadeInMs: 300, pan: -0.2),
      autoDuck: true,
      duckAmount: 0.42,
    );

    EditorTimeline legacyTimeline(TimelineClip audio) => EditorTimeline(
      schemaVersion: 5,
      tracks: [
        TimelineTrack(
          id: 'base',
          name: 'Source video',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          role: TimelineTrackRole.sourceVideo,
          clips: [baseVideo()],
        ),
        TimelineTrack(
          id: 'source_audio',
          name: 'Source audio',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          role: TimelineTrackRole.sourceAudio,
          isLocked: true,
          clips: [audio],
        ),
      ],
    );

    test('an exact automatic mirror folds back into the Base-layer video', () {
      final restored = EditorTimeline.fromJson(
        legacyTimeline(sourceAudio()).toJson(),
      );

      expect(
        restored.tracks.any(
          (track) => track.role == TimelineTrackRole.sourceAudio,
        ),
        isFalse,
      );
      final baseTrack = restored.tracks.single;
      final video = baseTrack.clips.single;
      expect(baseTrack.name, 'Base layer');
      expect(baseTrack.displayName, 'Base layer');
      expect(video.audioMix.muted, isFalse);
      expect(video.audioMix.volume, 0.55);
      expect(video.audioMix.fadeInMs, 300);
      expect(video.audioMix.pan, -0.2);
      expect(video.autoDuck, isTrue);
      expect(video.duckAmount, 0.42);
    });

    test('a user-retimed source-audio clip is preserved without guessing', () {
      final restored = EditorTimeline.fromJson(
        legacyTimeline(
          sourceAudio(startTime: const Duration(milliseconds: 2100)),
        ).toJson(),
      );

      final sourceTrack = restored.tracks.singleWhere(
        (track) => track.role == TimelineTrackRole.sourceAudio,
      );
      expect(sourceTrack.clips.single.startTime.inMilliseconds, 2100);
      final video = restored.tracks
          .singleWhere(
            (track) => track.section == TimelineTrackSection.baseVideo,
          )
          .clips
          .single;
      expect(video.audioMix.muted, isTrue);
    });

    test(
      'same-range audio with independent playback semantics is preserved',
      () {
        final variants = <TimelineClip>[
          sourceAudio().copyWith(playbackRate: 1.25),
          sourceAudio().copyWith(isReversed: true),
          sourceAudio().copyWith(denoise: true),
        ];

        for (final variant in variants) {
          final restored = EditorTimeline.fromJson(
            legacyTimeline(variant).toJson(),
          );
          expect(
            restored.tracks.any(
              (track) =>
                  track.role == TimelineTrackRole.sourceAudio &&
                  track.clips.single.id == variant.id,
            ),
            isTrue,
          );
          final video = restored.tracks
              .singleWhere(
                (track) => track.section == TimelineTrackSection.baseVideo,
              )
              .clips
              .single;
          expect(video.audioMix.muted, isTrue);
        }
      },
    );
  });

  group('track structure and paint order', () {
    TimelineTrack textTrack(String id) => TimelineTrack(
      id: id,
      name: 'Text',
      type: TimelineTrackType.text,
      section: TimelineTrackSection.textSubtitle,
    );
    TimelineTrack overlayTrack(String id) => TimelineTrack(
      id: id,
      name: 'Overlay',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.overlay,
    );
    TimelineTrack audioTrack(String id, {bool source = false}) => TimelineTrack(
      id: id,
      name: source ? 'Source audio' : 'Audio',
      type: TimelineTrackType.audio,
      section: TimelineTrackSection.audio,
      role: source ? TimelineTrackRole.sourceAudio : TimelineTrackRole.regular,
    );
    TimelineTrack sourceVideoTrack() => TimelineTrack(
      id: 'source_video',
      name: 'Source video',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.baseVideo,
      role: TimelineTrackRole.sourceVideo,
    );

    test('new lanes follow editor insertion rules', () {
      final initial = EditorTimeline(
        tracks: [
          textTrack('text'),
          overlayTrack('overlay'),
          sourceVideoTrack(),
          audioTrack('source_audio', source: true),
        ],
      );

      final withOverlay = initial.insertTrackUsingEditorRules(
        overlayTrack('new_overlay'),
      );
      expect(withOverlay.tracks.map((track) => track.id), [
        'text',
        'new_overlay',
        'overlay',
        'source_video',
        'source_audio',
      ]);

      final withAudio = withOverlay.insertTrackUsingEditorRules(
        audioTrack('imported_audio'),
      );
      expect(withAudio.tracks.last.id, 'imported_audio');
      expect(
        withAudio.tracks.indexWhere((track) => track.id == 'imported_audio'),
        greaterThan(
          withAudio.tracks.indexWhere((track) => track.id == 'source_audio'),
        ),
      );
    });

    test('sync inserts a missing Base layer below visuals and above audio', () {
      final synced =
          EditorTimeline(
            tracks: [
              textTrack('text'),
              overlayTrack('overlay'),
              audioTrack('audio'),
            ],
          ).syncLegacySubtitles(
            subtitles: const [],
            globalStyle: const SubtitleStyleModel(),
            videoPath: '',
            durationMs: 0,
          );

      expect(synced.tracks.map((track) => track.id), [
        'text',
        'overlay',
        'track_video_primary',
        'audio',
      ]);
      expect(synced.tracks[2].displayName, 'Base layer');
      expect(synced.tracks[2].clips, isEmpty);
    });

    test(
      'visual lanes reorder in both directions but source lanes stay fixed',
      () {
        final initial = EditorTimeline(
          tracks: [
            textTrack('text'),
            overlayTrack('overlay'),
            sourceVideoTrack(),
            audioTrack('source_audio', source: true),
          ],
        );

        final movedDown = initial.reorderTrackTo('text', 'overlay');
        expect(movedDown.tracks.map((track) => track.id), [
          'overlay',
          'text',
          'source_video',
          'source_audio',
        ]);
        expect(movedDown.visualTracksInPaintOrder.map((track) => track.id), [
          'source_video',
          'text',
          'overlay',
        ]);

        final movedBack = movedDown.reorderTrackTo('text', 'overlay');
        expect(movedBack.tracks.map((track) => track.id), [
          'text',
          'overlay',
          'source_video',
          'source_audio',
        ]);
        expect(
          identical(initial.reorderTrackTo('source_video', 'overlay'), initial),
          isTrue,
        );
        expect(
          identical(initial.reorderTrackTo('source_audio', 'overlay'), initial),
          isTrue,
        );
      },
    );

    test(
      'visual paint order follows visible lane order without source magic',
      () {
        final legacy = EditorTimeline(
          tracks: [
            sourceVideoTrack(),
            overlayTrack('legacy_overlay'),
            overlayTrack('legacy_top'),
          ],
        );
        expect(legacy.visualTracksInPaintOrder.map((track) => track.id), [
          'legacy_top',
          'legacy_overlay',
          'source_video',
        ]);
      },
    );

    test('schema-four rows migrate to visible top-down order', () {
      final restored = EditorTimeline.fromJson(
        EditorTimeline(
          schemaVersion: 4,
          tracks: [
            sourceVideoTrack(),
            overlayTrack('legacy_low'),
            overlayTrack('legacy_high'),
            textTrack('legacy_text'),
          ],
        ).toJson(),
      );

      expect(restored.schemaVersion, EditorTimeline.currentSchemaVersion);
      expect(restored.tracks.map((track) => track.id), [
        'legacy_text',
        'legacy_high',
        'legacy_low',
        'source_video',
      ]);
      expect(restored.visualTracksInPaintOrder.map((track) => track.id), [
        'source_video',
        'legacy_low',
        'legacy_high',
        'legacy_text',
      ]);
    });
  });

  group('legacy timeline canonicalization', () {
    test(
      'preserves separate source-linked caption lanes across sync and JSON',
      () {
        TimelineClip caption({
          required String id,
          required String trackId,
          required String sourceId,
          required int start,
        }) {
          return TimelineClip(
            id: id,
            trackId: trackId,
            type: TimelineTrackType.subtitle,
            label: id,
            linkedClipId: sourceId,
            startTime: Duration(seconds: start),
            endTime: Duration(seconds: start + 1),
            text: id,
          );
        }

        final timeline = EditorTimeline(
          tracks: [
            TimelineTrack(
              id: 'captions_main',
              name: 'Captions · Main',
              type: TimelineTrackType.subtitle,
              section: TimelineTrackSection.textSubtitle,
              clips: [
                caption(
                  id: 'main_caption',
                  trackId: 'captions_main',
                  sourceId: 'main_video',
                  start: 0,
                ),
              ],
            ),
            TimelineTrack(
              id: 'captions_overlay',
              name: 'Captions · Interview overlay',
              type: TimelineTrackType.subtitle,
              section: TimelineTrackSection.textSubtitle,
              clips: [
                caption(
                  id: 'overlay_caption',
                  trackId: 'captions_overlay',
                  sourceId: 'overlay_video',
                  start: 0,
                ),
              ],
            ),
          ],
        );
        final updatedEntries = [
          SubtitleEntry(
            id: 'main_caption',
            startTime: const Duration(milliseconds: 100),
            endTime: const Duration(milliseconds: 900),
            text: 'Main updated',
          ),
          SubtitleEntry(
            id: 'overlay_caption',
            startTime: const Duration(milliseconds: 200),
            endTime: const Duration(milliseconds: 950),
            text: 'Overlay updated',
          ),
        ];

        final merged = timeline.mergeSubtitleEntries(
          subtitles: updatedEntries,
          globalStyle: const SubtitleStyleModel(),
        );
        final restored = EditorTimeline.fromJson(merged.toJson());
        final captionTracks = restored.tracks
            .where((track) => track.type == TimelineTrackType.subtitle)
            .toList();

        expect(captionTracks.map((track) => track.id), [
          'captions_main',
          'captions_overlay',
        ]);
        expect(captionTracks.first.clips.single.linkedClipId, 'main_video');
        expect(captionTracks.last.clips.single.linkedClipId, 'overlay_video');
        expect(restored.subtitleEntries.map((entry) => entry.text), [
          'Main updated',
          'Overlay updated',
        ]);
      },
    );

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

  group('timeline invariants', () {
    TimelineClip clip(String id, int startMs, int endMs) => TimelineClip(
      id: id,
      trackId: 'overlay',
      type: TimelineTrackType.image,
      label: id,
      startTime: Duration(milliseconds: startMs),
      endTime: Duration(milliseconds: endMs),
    );

    test('uses half-open intervals so cuts may touch but never overlap', () {
      final track = TimelineTrack(
        id: 'overlay',
        name: 'Overlay',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
        clips: [clip('first', 0, 1000)],
      );

      expect(track.canPlaceClip(clip('touching', 1000, 2000)), isTrue);
      expect(track.canPlaceClip(clip('partial', 999, 2000)), isFalse);
      expect(track.canPlaceClip(clip('contained', 100, 900)), isFalse);
      expect(track.canPlaceClip(clip('identical', 0, 1000)), isFalse);
    });

    test('finds the closest legal gap and repairs persisted collisions', () {
      final track = TimelineTrack(
        id: 'overlay',
        name: 'Overlay',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
        clips: [clip('first', 0, 1000), clip('second', 1500, 2500)],
      );
      expect(
        track.closestAvailableStart(
          desiredStart: const Duration(milliseconds: 800),
          duration: const Duration(milliseconds: 500),
        ),
        const Duration(milliseconds: 1000),
      );

      final restored = EditorTimeline.fromJson(
        EditorTimeline(
          tracks: [
            track.copyWith(
              clips: [clip('first', 0, 1000), clip('stacked', 500, 1500)],
            ),
          ],
        ).toJson(),
      );
      expect(restored.hasTrackOverlaps, isFalse);
      expect(
        restored.tracks.single.clips.last.startTime,
        const Duration(seconds: 1),
      );
    });

    test('reuses the nearest gap instead of requiring another track', () {
      final existingTrack = TimelineTrack(
        id: 'downloads_overlay',
        name: 'Downloads overlay',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
        clips: [clip('occupied', 0, 4000)],
      );

      final placement = resolveClosestReusableTrackPlacement(
        tracks: [existingTrack],
        clipType: TimelineTrackType.video,
        desiredStart: const Duration(seconds: 2),
        duration: const Duration(seconds: 2),
      );

      expect(placement, isNotNull);
      expect(placement!.track.id, existingTrack.id);
      expect(placement.start, const Duration(seconds: 4));
    });

    test('last-visual guard is timeline-wide and main lane may stay empty', () {
      final overlayVisual = clip('only_visual', 0, 2000);
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'main',
            name: 'Main video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
          ),
          TimelineTrack(
            id: 'overlay',
            name: 'Overlay',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.overlay,
            clips: [overlayVisual],
          ),
        ],
      );

      expect(timeline.hasVisualContent, isTrue);
      expect(
        timeline.wouldRetainVisualContentAfterRemoving([overlayVisual.id]),
        isFalse,
      );
      final synced = timeline.syncLegacySubtitles(
        subtitles: const [],
        globalStyle: const SubtitleStyleModel(),
        videoPath: '/legacy/video.mp4',
        durationMs: 5000,
      );
      expect(
        synced.tracks
            .singleWhere(
              (track) => track.section == TimelineTrackSection.baseVideo,
            )
            .clips,
        isEmpty,
      );
      expect(synced.visualMediaClips.single.id, overlayVisual.id);

      final syncedWithoutMainLane =
          EditorTimeline(tracks: [timeline.tracks.last]).syncLegacySubtitles(
            subtitles: const [],
            globalStyle: const SubtitleStyleModel(),
            videoPath: '/legacy/video.mp4',
            durationMs: 5000,
          );
      expect(
        syncedWithoutMainLane.tracks
            .singleWhere(
              (track) => track.section == TimelineTrackSection.baseVideo,
            )
            .clips,
        isEmpty,
      );
      expect(
        syncedWithoutMainLane.visualMediaClips.single.id,
        overlayVisual.id,
      );
    });

    test('misplaced visual clips do not bypass the last-visual guard', () {
      final renderableVisual = clip(
        'renderable',
        0,
        2000,
      ).copyWith(trackId: 'main', type: TimelineTrackType.video);
      final misplacedVisual = clip('misplaced', 0, 2000);
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'main',
            name: 'Main video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [renderableVisual],
          ),
          TimelineTrack(
            id: 'text',
            name: 'Text',
            type: TimelineTrackType.text,
            section: TimelineTrackSection.textSubtitle,
            clips: [misplacedVisual],
          ),
        ],
      );

      expect(timeline.visualMediaClips, [renderableVisual]);
      expect(
        timeline.wouldRetainVisualContentAfterRemoving([renderableVisual.id]),
        isFalse,
      );
    });
  });
}
