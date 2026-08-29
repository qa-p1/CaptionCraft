import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('effect model', () {
    test('normalizes keyframes and clones every persisted identity', () {
      final effect = EditorEffect(
        id: 'effect',
        type: EditorEffectType.gaussianBlur,
        keyframes: [
          EditorEffectParameterKeyframe(
            id: 'duplicate',
            parameter: 'radius',
            time: const Duration(seconds: 1),
            value: 20,
          ),
          EditorEffectParameterKeyframe(
            id: 'duplicate',
            parameter: 'radius',
            time: const Duration(seconds: -1),
            value: 4,
          ),
          EditorEffectParameterKeyframe(
            parameter: 'radius',
            time: Duration.zero,
            value: 8,
          ),
        ],
      );

      expect(effect.keyframes, hasLength(2));
      expect(effect.keyframes.first.time, Duration.zero);
      expect(
        effect.parameterAt('radius', const Duration(milliseconds: 500)),
        14,
      );
      expect(effect.keyframes.map((frame) => frame.id).toSet(), hasLength(2));

      final clone = effect.cloneWithNewId();
      expect(clone.id, isNot(effect.id));
      expect(
        clone.keyframes
            .map((frame) => frame.id)
            .toSet()
            .intersection(effect.keyframes.map((frame) => frame.id).toSet()),
        isEmpty,
      );
    });

    test('persists masks, interpolation, and safe bounds', () {
      final restored = EditorEffect.fromJson(
        EditorEffect(
          id: 'masked',
          type: EditorEffectType.directionalBlur,
          intensity: 0.6,
          mask: const EditorEffectMask(
            shape: EditorEffectMaskShape.ellipse,
            x: 0.9,
            y: -0.2,
            width: 0.5,
            height: 0.4,
            feather: 2,
            inverted: true,
          ),
          keyframes: [
            EditorEffectParameterKeyframe(
              parameter: 'angle',
              time: const Duration(milliseconds: 400),
              value: 90,
              interpolation: EditorEffectInterpolation.easeInOut,
            ),
          ],
        ).toJson(),
      );

      expect(restored.intensity, 0.6);
      expect(restored.mask?.shape, EditorEffectMaskShape.ellipse);
      expect(restored.mask?.safeX, 0.5);
      expect(restored.mask?.safeY, 0);
      expect(restored.mask?.safeFeather, 1);
      expect(restored.mask?.inverted, isTrue);
      expect(
        restored.keyframes.single.interpolation,
        EditorEffectInterpolation.easeInOut,
      );
    });

    test('splits parameter animation with continuous values and fresh IDs', () {
      final stack = EditorEffectStack(
        effects: [
          EditorEffect(
            id: 'animated-effect',
            type: EditorEffectType.gaussianBlur,
            keyframes: [
              EditorEffectParameterKeyframe(
                parameter: 'radius',
                time: Duration.zero,
                value: 0,
              ),
              EditorEffectParameterKeyframe(
                parameter: 'radius',
                time: const Duration(seconds: 2),
                value: 20,
              ),
              EditorEffectParameterKeyframe(
                parameter: 'radius',
                time: const Duration(seconds: 4),
                value: 40,
              ),
            ],
          ),
        ],
      );

      final split = stack.splitAt(const Duration(milliseconds: 2500));
      final leading = split.leading.effects.single;
      final trailing = split.trailing.effects.single;
      expect(leading.id, 'animated-effect');
      expect(trailing.id, isNot(leading.id));
      expect(
        leading.parameterAt('radius', const Duration(milliseconds: 2500)),
        25,
      );
      expect(trailing.parameterAt('radius', Duration.zero), 25);
      expect(
        trailing.parameterAt('radius', const Duration(milliseconds: 1500)),
        40,
      );
      expect(
        leading.keyframes
            .map((frame) => frame.id)
            .toSet()
            .intersection(trailing.keyframes.map((frame) => frame.id).toSet()),
        isEmpty,
      );
    });
  });

  group('timeline effect persistence', () {
    test('repairs stale associations and migrates direct containers', () {
      final sharedEffect = EditorEffect(
        id: 'shared-effect',
        type: EditorEffectType.gaussianBlur,
      );
      final first = TimelineClip(
        id: 'first',
        trackId: 'visual',
        type: TimelineTrackType.video,
        label: 'First',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
        groupId: 'group',
        compoundId: 'compound',
        effectStack: EditorEffectStack(effects: [sharedEffect, sharedEffect]),
      );
      final second = TimelineClip(
        id: 'second',
        trackId: 'visual',
        type: TimelineTrackType.video,
        label: 'Second',
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 2),
      );
      final audio = TimelineClip(
        id: 'audio',
        trackId: 'audio-track',
        type: TimelineTrackType.audio,
        label: 'Audio',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
        compoundId: 'compound',
      );
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'visual',
            name: 'Visual',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.overlay,
            clips: [first, second],
          ),
          TimelineTrack(
            id: 'audio-track',
            name: 'Audio',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
            audioBusId: 'missing-bus',
            clips: [audio],
          ),
        ],
        groups: [
          TimelineGroup(
            id: 'group',
            name: 'Group',
            clipIds: const ['first', 'second', 'missing'],
          ),
          TimelineGroup(
            id: 'orphan',
            name: 'Orphan',
            clipIds: const ['missing'],
          ),
        ],
        compoundClips: [
          TimelineCompoundClip(
            id: 'compound',
            name: 'Compound',
            clipIds: const ['first', 'audio', 'missing'],
          ),
        ],
        audioBuses: [
          TimelineAudioBus(
            id: 'bus',
            name: 'Dialogue',
            effectStack: EditorEffectStack(
              effects: [
                EditorEffect(type: EditorEffectType.compressor),
                EditorEffect(type: EditorEffectType.vignette),
              ],
            ),
          ),
        ],
        effectContainers: [
          EditorEffectContainer(
            scope: EditorEffectScope.clip,
            targetId: 'first',
            label: 'Legacy clip stack',
            stack: EditorEffectStack(
              effects: [EditorEffect(type: EditorEffectType.sharpen)],
            ),
          ),
          EditorEffectContainer(
            scope: EditorEffectScope.group,
            targetId: 'group',
            label: 'Group stack',
            enabled: false,
            stack: EditorEffectStack(
              effects: [EditorEffect(type: EditorEffectType.glow)],
            ),
          ),
          EditorEffectContainer(
            scope: EditorEffectScope.group,
            targetId: 'orphan',
            label: 'Stale stack',
          ),
        ],
      );

      final restored = EditorTimeline.fromJson(timeline.toJson());
      final restoredFirst = restored.tracks.first.clips.first;
      final restoredSecond = restored.tracks.first.clips.last;
      final restoredAudio = restored.tracks.last.clips.single;

      expect(restored.schemaVersion, 8);
      expect(restored.groups, hasLength(1));
      expect(restored.groups.single.clipIds, ['first', 'second']);
      expect(restoredFirst.groupId, 'group');
      expect(restoredSecond.groupId, 'group');
      expect(restored.compoundClips.single.clipIds, ['first']);
      expect(restoredAudio.compoundId, isNull);
      expect(restored.tracks.last.audioBusId, isNull);
      expect(restoredFirst.effectStack.effects, hasLength(3));
      expect(
        restoredFirst.effectStack.effects.map((effect) => effect.id).toSet(),
        hasLength(3),
      );
      expect(restored.effectContainers, hasLength(1));
      expect(restored.effectContainers.single.enabled, isTrue);
      expect(
        restored.effectContainers.single.stack.effects.single.enabled,
        isFalse,
      );
      expect(restored.audioBuses.single.effectStack.effects, hasLength(1));
      expect(
        restored.audioBuses.single.effectStack.effects.single.domain,
        EditorEffectDomain.audio,
      );
    });

    test(
      'resolves scoped stack order without applying disabled containers',
      () {
        EditorEffectStack stack(EditorEffectType type) =>
            EditorEffectStack(effects: [EditorEffect(type: type)]);
        final clip = TimelineClip(
          id: 'clip',
          trackId: 'track',
          type: TimelineTrackType.video,
          label: 'Clip',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          groupId: 'group',
          compoundId: 'compound',
          effectStack: stack(EditorEffectType.gaussianBlur),
        );
        final track = TimelineTrack(
          id: 'track',
          name: 'Track',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.overlay,
          effectStack: stack(EditorEffectType.vignette),
          clips: [clip],
        );
        final timeline = EditorTimeline(
          tracks: [track],
          groups: [
            TimelineGroup(id: 'group', name: 'Group', clipIds: const ['clip']),
          ],
          compoundClips: [
            TimelineCompoundClip(
              id: 'compound',
              name: 'Compound',
              clipIds: const ['clip'],
            ),
          ],
          effectContainers: [
            EditorEffectContainer(
              scope: EditorEffectScope.compound,
              targetId: 'compound',
              label: 'Compound',
              stack: stack(EditorEffectType.glow),
            ),
            EditorEffectContainer(
              scope: EditorEffectScope.group,
              targetId: 'group',
              label: 'Group',
              enabled: false,
              stack: stack(EditorEffectType.sharpen),
            ),
          ],
        );

        final scoped = timeline.effectStacksForClip(clip, track: track);
        expect(scoped.map((entry) => entry.scope), [
          EditorEffectScope.clip,
          EditorEffectScope.compound,
          EditorEffectScope.track,
        ]);
        expect(
          timeline
              .effectStackForClip(clip, track: track)
              .effects
              .map((effect) => effect.type),
          [
            EditorEffectType.gaussianBlur,
            EditorEffectType.glow,
            EditorEffectType.vignette,
          ],
        );
      },
    );
  });

  group('editor effect actions', () {
    late ProviderContainer container;
    late EditorNotifier notifier;

    setUp(() {
      final clip = TimelineClip(
        id: 'clip',
        trackId: 'track',
        type: TimelineTrackType.video,
        label: 'Clip',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 4),
      );
      container = ProviderContainer();
      notifier = container.read(editorProvider.notifier);
      notifier.loadProject(
        videoPath: 'source.mp4',
        projectId: 'project',
        projectName: 'Project',
        timeline: EditorTimeline(
          tracks: [
            TimelineTrack(
              id: 'track',
              name: 'Track',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.overlay,
              clips: [clip],
            ),
          ],
        ),
      );
    });

    tearDown(() => container.dispose());

    test('stack editing is ordered, toggleable, and undoable', () {
      expect(
        notifier.addEffect(
          scope: EditorEffectScope.clip,
          targetId: 'clip',
          type: EditorEffectType.gaussianBlur,
        ),
        isTrue,
      );
      expect(
        notifier.addEffect(
          scope: EditorEffectScope.clip,
          targetId: 'clip',
          type: EditorEffectType.sharpen,
        ),
        isTrue,
      );
      expect(
        notifier.reorderEffects(
          scope: EditorEffectScope.clip,
          targetId: 'clip',
          oldIndex: 0,
          newIndex: 2,
        ),
        isTrue,
      );
      var stack = notifier.effectStackForTarget(
        scope: EditorEffectScope.clip,
        targetId: 'clip',
      );
      expect(stack.effects.map((effect) => effect.type), [
        EditorEffectType.sharpen,
        EditorEffectType.gaussianBlur,
      ]);
      expect(
        notifier.toggleEffect(
          scope: EditorEffectScope.clip,
          targetId: 'clip',
          effectId: stack.effects.first.id,
        ),
        isTrue,
      );
      expect(
        notifier
            .effectStackForTarget(
              scope: EditorEffectScope.clip,
              targetId: 'clip',
            )
            .effects
            .first
            .enabled,
        isFalse,
      );

      notifier.undo();
      expect(
        notifier
            .effectStackForTarget(
              scope: EditorEffectScope.clip,
              targetId: 'clip',
            )
            .effects
            .first
            .enabled,
        isTrue,
      );
      notifier.redo();
      expect(container.read(editorProvider).canUndo, isTrue);
    });

    test('invalid and no-op stack edits do not pollute undo history', () {
      expect(
        notifier.updateEffectStack(
          scope: EditorEffectScope.clip,
          targetId: 'clip',
          mapper: (stack) => stack,
        ),
        isFalse,
      );
      expect(
        notifier.addEffect(
          scope: EditorEffectScope.adjustmentLayer,
          targetId: 'clip',
          type: EditorEffectType.glow,
        ),
        isFalse,
      );
      expect(container.read(editorProvider).canUndo, isFalse);
      expect(
        notifier
            .effectStackForTarget(
              scope: EditorEffectScope.clip,
              targetId: 'clip',
            )
            .isEmpty,
        isTrue,
      );
    });

    test('clipboard and presets filter domains and regenerate IDs', () {
      notifier.updateEffectStack(
        scope: EditorEffectScope.project,
        mapper: (_) => EditorEffectStack(
          effects: [
            EditorEffect(type: EditorEffectType.glow),
            EditorEffect(type: EditorEffectType.compressor),
          ],
        ),
      );
      expect(
        notifier.copyEffectStackToClipboard(scope: EditorEffectScope.project),
        isTrue,
      );
      expect(
        notifier.pasteEffectStackFromClipboard(
          scope: EditorEffectScope.clip,
          targetId: 'clip',
          domain: EditorEffectDomain.audio,
        ),
        isTrue,
      );
      final pasted = notifier.effectStackForTarget(
        scope: EditorEffectScope.clip,
        targetId: 'clip',
      );
      expect(pasted.effects, hasLength(1));
      expect(pasted.effects.single.type, EditorEffectType.compressor);

      final presetId = notifier.saveEffectPreset(
        name: 'Audio chain',
        scope: EditorEffectScope.clip,
        targetId: 'clip',
        domain: EditorEffectDomain.audio,
      );
      expect(presetId, isNotNull);
      final firstId = pasted.effects.single.id;
      expect(
        notifier.applyEffectPreset(
          presetId: presetId!,
          scope: EditorEffectScope.clip,
          targetId: 'clip',
          append: true,
          domain: EditorEffectDomain.audio,
        ),
        isTrue,
      );
      final applied = notifier.effectStackForTarget(
        scope: EditorEffectScope.clip,
        targetId: 'clip',
      );
      expect(applied.effects, hasLength(2));
      expect(applied.effects.last.id, isNot(firstId));
    });

    test('adjustment layers and buses persist through undo and redo', () {
      final adjustmentId = notifier.createAdjustmentLayer(
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 3),
      );
      expect(adjustmentId, isNotNull);
      final adjustment = container
          .read(editorProvider)
          .timeline
          .tracks
          .expand((track) => track.clips)
          .singleWhere((clip) => clip.id == adjustmentId);
      expect(adjustment.isAdjustmentLayer, isTrue);
      expect(adjustment.effectKind, isNull);

      final busId = notifier.createAudioBus(name: 'Dialogue');
      expect(notifier.assignTrackToAudioBus('track', busId), isTrue);
      expect(
        container
            .read(editorProvider)
            .timeline
            .tracks
            .firstWhere((track) => track.id == 'track')
            .audioBusId,
        busId,
      );
      notifier.undo();
      expect(
        container
            .read(editorProvider)
            .timeline
            .tracks
            .firstWhere((track) => track.id == 'track')
            .audioBusId,
        isNull,
      );
      notifier.redo();
      expect(
        container
            .read(editorProvider)
            .timeline
            .tracks
            .firstWhere((track) => track.id == 'track')
            .audioBusId,
        busId,
      );
    });

    test('LUT import registers once, applies, favorites, and undoes', () {
      final lutId = notifier.importAndApplyLutToClip(
        clipId: 'clip',
        sourcePath: r'C:\looks\cinematic.cube',
        name: 'Cinematic',
        folder: 'Film',
      );
      expect(lutId, isNotNull);
      var timeline = container.read(editorProvider).timeline;
      expect(timeline.colorManagement.luts, hasLength(1));
      expect(timeline.colorManagement.luts.single.folder, 'Film');
      expect(
        timeline.tracks.single.clips.single.colorAdjustments.lutPath,
        r'C:\looks\cinematic.cube',
      );

      expect(
        notifier.importAndApplyLutToClip(
          clipId: 'clip',
          sourcePath: r'c:\LOOKS\cinematic.cube',
          name: 'Duplicate',
        ),
        lutId,
      );
      expect(
        container.read(editorProvider).timeline.colorManagement.luts,
        hasLength(1),
      );
      expect(
        notifier.updateLutAsset(lutId!, (lut) => lut.copyWith(favorite: true)),
        isTrue,
      );
      timeline = container.read(editorProvider).timeline;
      expect(timeline.colorManagement.luts.single.favorite, isTrue);
      notifier.undo();
      expect(
        container
            .read(editorProvider)
            .timeline
            .colorManagement
            .luts
            .single
            .favorite,
        isFalse,
      );
      expect(notifier.applyLutToClip('clip', null), isTrue);
      expect(
        container
            .read(editorProvider)
            .timeline
            .tracks
            .single
            .clips
            .single
            .colorAdjustments
            .lutPath,
        isNull,
      );
    });

    test('one LUT action applies atomically to multiple clips and undoes', () {
      final second = TimelineClip(
        id: 'clip-2',
        trackId: 'track',
        type: TimelineTrackType.image,
        label: 'Second clip',
        startTime: const Duration(seconds: 4),
        endTime: const Duration(seconds: 8),
      );
      final timeline = container.read(editorProvider).timeline;
      notifier.loadProject(
        videoPath: 'source.mp4',
        projectId: 'project',
        projectName: 'Project',
        timeline: timeline.copyWith(
          tracks: [
            timeline.tracks.single.copyWith(
              clips: [...timeline.tracks.single.clips, second],
            ),
          ],
        ),
      );

      final lutId = notifier.importAndApplyLutToClips(
        clipIds: const ['clip', 'clip-2'],
        sourcePath: r'C:\looks\shared.cube',
        name: 'Shared Look',
      );

      expect(lutId, isNotNull);
      var updated = container.read(editorProvider).timeline;
      expect(updated.colorManagement.luts, hasLength(1));
      expect(
        updated.tracks.single.clips.map(
          (clip) => clip.colorAdjustments.lutPath,
        ),
        everyElement(r'C:\looks\shared.cube'),
      );

      notifier.undo();
      updated = container.read(editorProvider).timeline;
      expect(updated.colorManagement.luts, isEmpty);
      expect(
        updated.tracks.single.clips.map(
          (clip) => clip.colorAdjustments.lutPath,
        ),
        everyElement(isNull),
      );

      notifier.redo();
      updated = container.read(editorProvider).timeline;
      expect(updated.colorManagement.luts, hasLength(1));
      expect(
        notifier.applyLutToClips(const ['clip', 'missing'], lutId),
        isFalse,
      );
      expect(
        container
            .read(editorProvider)
            .timeline
            .tracks
            .single
            .clips
            .map((clip) => clip.colorAdjustments.lutPath),
        everyElement(r'C:\looks\shared.cube'),
      );
    });
  });
}
