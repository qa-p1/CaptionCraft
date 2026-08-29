import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/widgets/effect_stack_editor_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('effect sheet adds, animates, masks, and disables an effect', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final clip = TimelineClip(
      id: 'clip',
      trackId: 'track',
      type: TimelineTrackType.video,
      label: 'Clip',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 3),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
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

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: EffectStackEditorSheet(
              domain: EditorEffectDomain.visual,
              targets: [
                EffectStackTargetOption(
                  scope: EditorEffectScope.clip,
                  targetId: 'clip',
                  label: 'Clip',
                  description: 'Selected clip',
                ),
              ],
              initialTargetKey: 'clip:clip',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Build a non-destructive stack'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'initial sheet layout');

    await tester.tap(find.byKey(const ValueKey('effect_stack_add')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'effect browser layout');
    await tester.tap(find.byKey(const ValueKey('effect_browser_gaussianBlur')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'expanded effect card');

    var effect = container
        .read(editorProvider)
        .timeline
        .tracks
        .single
        .clips
        .single
        .effectStack
        .effects
        .single;
    expect(effect.type, EditorEffectType.gaussianBlur);
    expect(find.text('Gaussian Blur'), findsOneWidget);
    expect(find.text('Mix'), findsOneWidget);

    await tester.tap(find.byTooltip('Add keyframe').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'keyframe controls');
    effect = container
        .read(editorProvider)
        .timeline
        .tracks
        .single
        .clips
        .single
        .effectStack
        .effects
        .single;
    expect(effect.keyframes, hasLength(1));
    expect(effect.keyframes.single.time, Duration.zero);

    await tester.tap(find.text('Selective mask'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'mask controls');
    effect = container
        .read(editorProvider)
        .timeline
        .tracks
        .single
        .clips
        .single
        .effectStack
        .effects
        .single;
    expect(effect.mask, isNotNull);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(
      container
          .read(editorProvider)
          .timeline
          .tracks
          .single
          .clips
          .single
          .effectStack
          .effects
          .single
          .enabled,
      isFalse,
    );
    expect(tester.takeException(), isNull, reason: 'disabled effect state');
  });
}
