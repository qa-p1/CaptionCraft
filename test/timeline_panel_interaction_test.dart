import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/widgets/timeline_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('clip drags accumulate and vertical swipes still scroll lanes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'timeline-test',
          projectName: 'Timeline test',
          timeline: _testTimeline(),
        );

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('timeline_add_track_button')), findsOne);
    expect(find.byKey(const ValueKey('timeline_track_base')), findsOne);
    expect(
      find.byKey(const ValueKey('timeline_clip_envelope_overlay_clip')),
      findsOne,
    );
    // Track names live in tooltips/semantics; the compact rail itself is icons.
    expect(find.text('Main source track'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('timeline_track_base')));
    await tester.pumpAndSettle();
    expect(container.read(editorProvider).selectedTrackId, 'base');

    final overlay = find.byKey(const ValueKey('timeline_clip_overlay_clip'));
    expect(overlay, findsOne);
    const initialDuration = Duration(seconds: 2);
    final nearLeftEdge = tester.getTopLeft(overlay) + const Offset(2, 18);
    final gesture = await tester.startGesture(nearLeftEdge);
    for (var index = 0; index < 6; index++) {
      await gesture.moveBy(const Offset(5, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final movedClip = container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .where((clip) => clip.id == 'overlay_clip')
        .firstOrNull;
    expect(movedClip, isNotNull);
    expect(movedClip!.startTime, greaterThan(const Duration(seconds: 1)));
    // An unselected clip edge is a move surface; trim handles appear only
    // after selection, avoiding accidental trims during ordinary dragging.
    expect(movedClip.duration, initialDuration);
    // A whole drag is one undoable edit and one committed preview revision.
    expect(container.read(editorProvider).canUndo, isTrue);
    expect(container.read(editorProvider).editRevision, 1);

    final verticalScroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('timeline_vertical_scroll')),
    );
    expect(verticalScroll.controller, isNotNull);
    expect(verticalScroll.controller!.offset, 0);
    final crossLaneGesture = await tester.startGesture(
      tester.getCenter(overlay),
    );
    await crossLaneGesture.moveBy(const Offset(0, 46));
    await tester.pump();
    await crossLaneGesture.up();
    await tester.pumpAndSettle();
    final crossLaneClip = container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .where((clip) => clip.id == 'overlay_clip')
        .single;
    expect(crossLaneClip.trackId, 'overlay_target');

    await tester.drag(
      find.byKey(const ValueKey('timeline_vertical_scroll')),
      const Offset(0, -140),
    );
    await tester.pumpAndSettle();
    expect(verticalScroll.controller!.offset, greaterThan(0));
  });

  testWidgets('the plus button asks for a compatible track type', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'track-test',
          projectName: 'Track test',
          timeline: _testTimeline(),
        );

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    final originalTrackCount = container
        .read(editorProvider)
        .timeline
        .tracks
        .length;

    await tester.tap(find.byKey(const ValueKey('timeline_add_track_button')));
    await tester.pumpAndSettle();
    expect(find.text('Add track'), findsOne);
    expect(find.text('Visual overlay'), findsOne);
    expect(find.text('Text'), findsOne);
    expect(find.text('Audio'), findsOne);
    expect(find.text('Effects'), findsOne);

    final effectsChoice = find.byKey(
      const ValueKey('timeline_track_choice_effect'),
    );
    await tester.ensureVisible(effectsChoice);
    await tester.tap(effectsChoice);
    await tester.pumpAndSettle();

    final state = container.read(editorProvider);
    expect(state.timeline.tracks, hasLength(originalTrackCount + 1));
    final addedTrack = state.timeline.tracks.last;
    expect(addedTrack.type, TimelineTrackType.effect);
    expect(addedTrack.section, TimelineTrackSection.overlay);
    expect(state.selectedTrackId, addedTrack.id);
    expect(state.selectedClipId, isNull);
  });

  testWidgets('locked subtitle lanes reject toolbar mutations', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final entry = SubtitleEntry(
      id: 'locked_caption',
      startTime: const Duration(seconds: 1),
      endTime: const Duration(seconds: 2),
      text: 'Locked caption',
    );
    final subtitleClip = TimelineClip.fromSubtitleEntry(
      entry,
      trackId: 'locked_subtitles',
    );
    final timeline = EditorTimeline(
      tracks: [
        TimelineTrack(
          id: 'base',
          name: 'Base',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [
            TimelineClip(
              id: 'base_clip',
              trackId: 'base',
              type: TimelineTrackType.video,
              label: 'Base',
              startTime: Duration.zero,
              endTime: const Duration(seconds: 5),
              sourceDuration: const Duration(seconds: 5),
            ),
          ],
        ),
        TimelineTrack(
          id: 'locked_subtitles',
          name: 'Subtitles',
          type: TimelineTrackType.subtitle,
          section: TimelineTrackSection.textSubtitle,
          isLocked: true,
          clips: [subtitleClip],
        ),
      ],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(subtitleProvider.notifier)
        .initializeFromProject(
          entries: [entry],
          globalStyle: const SubtitleStyleModel(),
        );
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'locked-track-test',
          projectName: 'Locked track test',
          timeline: timeline,
        );
    container.read(editorProvider.notifier)
      ..selectTrack('locked_subtitles')
      ..selectClip('locked_caption');

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();

    InkWell toolbarAction(String tooltip) {
      final action = find.descendant(
        of: find.byTooltip(tooltip),
        matching: find.byType(InkWell),
      );
      return tester.widget<InkWell>(action.first);
    }

    expect(toolbarAction('Duplicate selection').onTap, isNull);
    expect(toolbarAction('Delete').onTap, isNull);
    expect(toolbarAction('Split').onTap, isNull);

    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    await tester.tap(find.byTooltip('Paste at playhead'));
    await tester.pumpAndSettle();
    expect(container.read(subtitleProvider).entries, hasLength(1));
    expect(
      find.text('Unlock the subtitle track before pasting captions.'),
      findsOne,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _timelineHarness(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: const Scaffold(body: TimelinePanel()),
    ),
  );
}

EditorTimeline _testTimeline() {
  TimelineTrack emptyAudioTrack(int index) => TimelineTrack(
    id: 'audio_$index',
    name: 'Audio $index',
    type: TimelineTrackType.audio,
    section: TimelineTrackSection.audio,
  );

  return EditorTimeline(
    tracks: [
      TimelineTrack(
        id: 'overlay',
        name: 'Overlay',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
        clips: [
          TimelineClip(
            id: 'overlay_clip',
            trackId: 'overlay',
            type: TimelineTrackType.image,
            label: 'Logo',
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 3),
            introTransition: const ClipTransition(
              type: TransitionType.fade,
              durationMs: 500,
            ),
            outroTransition: const ClipTransition(
              type: TransitionType.fade,
              durationMs: 400,
            ),
          ),
        ],
      ),
      TimelineTrack(
        id: 'base',
        name: 'Main source track',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [
          TimelineClip(
            id: 'base_clip',
            trackId: 'base',
            type: TimelineTrackType.video,
            label: 'Source video',
            startTime: Duration.zero,
            endTime: const Duration(seconds: 10),
            sourceDuration: const Duration(seconds: 10),
            audioMix: const AudioMixSettings(fadeInMs: 800, fadeOutMs: 900),
          ),
        ],
      ),
      TimelineTrack(
        id: 'overlay_target',
        name: 'Second visual overlay',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
      ),
      TimelineTrack(
        id: 'text',
        name: 'Text',
        type: TimelineTrackType.text,
        section: TimelineTrackSection.textSubtitle,
      ),
      for (var index = 0; index < 6; index++) emptyAudioTrack(index),
    ],
  );
}
