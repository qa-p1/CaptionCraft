import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/playback_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/widgets/timeline_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ruler label cadence expands as the timeline zooms out', () {
    final zoomedIn = timelineRulerLabelIntervalForTesting(pixelsPerSecond: 120);
    final zoomedOut = timelineRulerLabelIntervalForTesting(pixelsPerSecond: 12);

    expect(zoomedIn, const Duration(seconds: 1));
    expect(zoomedOut, const Duration(seconds: 10));
    expect(zoomedOut, greaterThan(zoomedIn));
    expect(zoomedOut.inSeconds * 12, greaterThanOrEqualTo(64));
  });

  test('timeline viewport selects only visible clips plus pinned gestures', () {
    final clips = List<TimelineClip>.generate(10000, (index) {
      final start = Duration(milliseconds: index * 100);
      return TimelineClip(
        id: 'clip_$index',
        trackId: 'video',
        type: TimelineTrackType.video,
        label: 'Clip $index',
        startTime: start,
        endTime: start + const Duration(milliseconds: 100),
      );
    }, growable: false);

    final visible = timelineVisibleClipsForTesting(
      sortedClips: clips,
      viewportStart: const Duration(milliseconds: 777750),
      viewportEnd: const Duration(milliseconds: 778050),
      pinnedClips: [clips[5]],
    );

    expect(visible.map((clip) => clip.id), [
      'clip_5',
      'clip_7777',
      'clip_7778',
      'clip_7779',
      'clip_7780',
    ]);
  });

  testWidgets('timeline mounts only the horizontal clip window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final clips = List<TimelineClip>.generate(1000, (index) {
      final start = Duration(milliseconds: index * 200);
      return TimelineClip(
        id: 'virtual_clip_$index',
        trackId: 'base',
        type: TimelineTrackType.video,
        label: 'Clip $index',
        startTime: start,
        endTime: start + const Duration(milliseconds: 200),
        sourceDuration: const Duration(milliseconds: 200),
      );
    }, growable: false);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'horizontal-virtualization',
          projectName: 'Horizontal virtualization',
          timeline: EditorTimeline(
            tracks: [
              TimelineTrack(
                id: 'base',
                name: 'Base',
                type: TimelineTrackType.video,
                section: TimelineTrackSection.baseVideo,
                clips: clips,
              ),
            ],
          ),
        );

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('timeline_clip_virtual_clip_0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timeline_clip_virtual_clip_999')),
      findsNothing,
    );

    final horizontal = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .singleWhere(
          (view) =>
              view.scrollDirection == Axis.horizontal &&
              view.controller != null,
        )
        .controller!;
    horizontal.jumpTo(horizontal.position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('timeline_clip_virtual_clip_999')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timeline_clip_virtual_clip_0')),
      findsNothing,
    );
  });

  testWidgets('timeline mounts only vertically visible track lanes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tracks = <TimelineTrack>[
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
            endTime: const Duration(seconds: 2),
            sourceDuration: const Duration(seconds: 2),
          ),
        ],
      ),
      for (var index = 0; index < 100; index++)
        TimelineTrack(
          id: 'audio_virtual_$index',
          name: 'Audio $index',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
        ),
    ];
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'vertical-virtualization',
          projectName: 'Vertical virtualization',
          timeline: EditorTimeline(tracks: tracks),
        );

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline_lane_base')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('timeline_lane_audio_virtual_99')),
      findsNothing,
    );

    final vertical = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('timeline_vertical_scroll')),
    );
    vertical.controller!.jumpTo(vertical.controller!.position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('timeline_lane_audio_virtual_99')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('timeline_lane_base')), findsNothing);
  });

  testWidgets('clip bodies and both trim handles let quick swipes scroll', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'scroll-gesture-test',
          projectName: 'Scroll gesture test',
          timeline: _testTimeline(),
        );
    container.read(editorProvider.notifier)
      ..selectTrack('overlay')
      ..selectClip('overlay_clip');

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();

    TimelineClip currentClip() => container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'overlay_clip');
    final original = currentClip();
    final horizontalScroll = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .singleWhere(
          (scrollView) =>
              scrollView.scrollDirection == Axis.horizontal &&
              scrollView.controller != null,
        );
    final controller = horizontalScroll.controller!;

    Future<void> quickSwipe(Finder target) async {
      final gesture = await tester.startGesture(tester.getCenter(target));
      for (var index = 0; index < 5; index++) {
        await gesture.moveBy(const Offset(-12, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(currentClip().startTime, original.startTime);
      expect(currentClip().endTime, original.endTime);
      expect(controller.offset, greaterThan(0));
      expect(container.read(editorProvider).editRevision, 0);
      controller.jumpTo(0);
      await tester.pump();
    }

    await quickSwipe(find.byKey(const ValueKey('timeline_clip_overlay_clip')));
    await quickSwipe(
      find.byKey(const ValueKey('timeline_trim_start_overlay_clip')),
    );
    await quickSwipe(
      find.byKey(const ValueKey('timeline_trim_end_overlay_clip')),
    );
    expect(tester.takeException(), isNull);
  });

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
    expect(find.bySemanticsLabel('Base layer track'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('timeline_track_base')));
    await tester.pumpAndSettle();
    expect(container.read(editorProvider).selectedTrackId, 'base');

    final overlay = find.byKey(const ValueKey('timeline_clip_overlay_clip'));
    expect(overlay, findsOne);
    const initialDuration = Duration(seconds: 2);
    final nearLeftEdge = tester.getTopLeft(overlay) + const Offset(2, 18);
    final gesture = await tester.startGesture(nearLeftEdge);
    await _armTimelineEdit(tester);
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
    expect(
      find.byKey(const ValueKey('timeline_trim_start_overlay_clip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timeline_trim_end_overlay_clip')),
      findsOneWidget,
    );
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
    await _armTimelineEdit(tester);
    final sourceLaneCenter = tester.getCenter(
      find.byKey(const ValueKey('timeline_lane_overlay')),
    );
    final targetLaneCenter = tester.getCenter(
      find.byKey(const ValueKey('timeline_lane_overlay_target')),
    );
    await crossLaneGesture.moveBy(
      Offset(0, targetLaneCenter.dy - sourceLaneCenter.dy),
    );
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

  testWidgets('an overlay stays mounted while crossing several overlay lanes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 440));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'multi-lane-drag-test',
          projectName: 'Multi-lane drag test',
          timeline: _threeOverlayLaneTimeline(),
        );

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();

    final moving = find.byKey(const ValueKey('timeline_clip_overlay_clip'));
    final gesture = await tester.startGesture(tester.getCenter(moving));
    await _armTimelineEdit(tester);
    final firstLaneCenter = tester.getCenter(
      find.byKey(const ValueKey('timeline_lane_overlay')),
    );
    final secondLaneCenter = tester.getCenter(
      find.byKey(const ValueKey('timeline_lane_overlay_target')),
    );
    final thirdLaneCenter = tester.getCenter(
      find.byKey(const ValueKey('timeline_lane_overlay_third')),
    );
    await gesture.moveBy(Offset(0, secondLaneCenter.dy - firstLaneCenter.dy));
    await tester.pump();
    expect(moving, findsOneWidget);
    expect(
      container
          .read(editorProvider)
          .timeline
          .tracks
          .expand((track) => track.clips)
          .where((clip) => clip.id == 'overlay_clip'),
      hasLength(1),
    );

    await gesture.moveBy(Offset(0, thirdLaneCenter.dy - secondLaneCenter.dy));
    await tester.pump();
    expect(moving, findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    final matches = container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .where((clip) => clip.id == 'overlay_clip')
        .toList();
    expect(matches, hasLength(1));
    expect(matches.single.trackId, 'overlay_third');
  });

  testWidgets(
    'a long clip never jumps away when crossing an occupied overlay lane',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 440));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(editorProvider.notifier)
          .loadProject(
            videoPath: 'missing.mp4',
            projectId: 'long-cross-lane-drag-test',
            projectName: 'Long cross-lane drag test',
            timeline: _longClipDragTimeline(),
          );

      await tester.pumpWidget(_timelineHarness(container));
      await tester.pumpAndSettle();

      final moving = find.byKey(const ValueKey('timeline_clip_long_overlay'));
      final gesture = await tester.startGesture(tester.getCenter(moving));
      await _armTimelineEdit(tester);
      final sourceCenter = tester.getCenter(
        find.byKey(const ValueKey('timeline_lane_overlay_source')),
      );
      final occupiedCenter = tester.getCenter(
        find.byKey(const ValueKey('timeline_lane_overlay_occupied')),
      );
      final freeCenter = tester.getCenter(
        find.byKey(const ValueKey('timeline_lane_overlay_free')),
      );

      await gesture.moveBy(Offset(0, occupiedCenter.dy - sourceCenter.dy));
      await tester.pump();
      expect(moving, findsOneWidget);
      var liveClip = container
          .read(editorProvider)
          .timeline
          .tracks
          .expand((track) => track.clips)
          .singleWhere((clip) => clip.id == 'long_overlay');
      expect(liveClip.trackId, 'overlay_source');
      expect(liveClip.startTime, const Duration(seconds: 1));

      await gesture.moveBy(Offset(0, freeCenter.dy - occupiedCenter.dy));
      await tester.pump();
      expect(moving, findsOneWidget);
      liveClip = container
          .read(editorProvider)
          .timeline
          .tracks
          .expand((track) => track.clips)
          .singleWhere((clip) => clip.id == 'long_overlay');
      expect(liveClip.trackId, 'overlay_free');
      expect(liveClip.startTime, const Duration(seconds: 1));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(moving, findsOneWidget);
    },
  );

  testWidgets('selected clip handles trim both edges without scrolling away', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'trim-test',
          projectName: 'Trim test',
          timeline: _testTimeline(),
        );
    container.read(editorProvider.notifier)
      ..selectTrack('overlay')
      ..selectClip('overlay_clip');

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();

    TimelineClip currentClip() => container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'overlay_clip');

    Future<void> dragHandle(String edge, Offset delta) async {
      final handle = find.byKey(ValueKey('timeline_trim_${edge}_overlay_clip'));
      expect(handle, findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await _armTimelineEdit(tester);
      await gesture.moveBy(delta);
      await tester.pump(const Duration(milliseconds: 32));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(container.read(editorProvider).selectedClipId, 'overlay_clip');
    }

    final horizontalScroll = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .singleWhere(
          (scrollView) =>
              scrollView.scrollDirection == Axis.horizontal &&
              scrollView.controller != null,
        );
    final initialScrollOffset = horizontalScroll.controller!.offset;
    final initial = currentClip();

    await dragHandle('start', const Offset(24, 0));
    final startTrimmed = currentClip();
    expect(startTrimmed.startTime, greaterThan(initial.startTime));
    expect(startTrimmed.endTime, initial.endTime);
    expect(startTrimmed.duration, lessThan(initial.duration));

    await dragHandle('start', const Offset(-12, 0));
    final startExtended = currentClip();
    expect(startExtended.startTime, lessThan(startTrimmed.startTime));

    await dragHandle('end', const Offset(-24, 0));
    final endTrimmed = currentClip();
    expect(endTrimmed.endTime, lessThan(startExtended.endTime));

    await dragHandle('end', const Offset(12, 0));
    final endExtended = currentClip();
    expect(endExtended.endTime, greaterThan(endTrimmed.endTime));
    expect(horizontalScroll.controller!.offset, initialScrollOffset);
    expect(container.read(editorProvider).editRevision, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source video trims keep linked source audio aligned', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'linked-trim-test',
          projectName: 'Linked trim test',
          timeline: _linkedSourceTimeline(),
        );
    container.read(editorProvider.notifier)
      ..selectTrack('linked_video_track')
      ..selectClip('linked_video');

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();

    final handle = find.byKey(
      const ValueKey('timeline_trim_start_linked_video'),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await _armTimelineEdit(tester);
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump(const Duration(milliseconds: 32));
    await gesture.up();
    await tester.pumpAndSettle();

    final clips = container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips);
    final video = clips.singleWhere((clip) => clip.id == 'linked_video');
    final audio = clips.singleWhere((clip) => clip.id == 'linked_audio');
    expect(video.startTime, greaterThan(const Duration(seconds: 1)));
    expect(audio.startTime, video.startTime);
    expect(audio.endTime, video.endTime);
    expect(audio.sourceStartTime, video.sourceStartTime);
    expect(audio.sourceDuration, video.sourceDuration);
    expect(container.read(editorProvider).selectedClipId, 'linked_video');
    expect(tester.takeException(), isNull);
  });

  testWidgets('separated audio follows Base-layer moves and both trim edges', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(520, 340));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'separated-audio-follow-test',
          projectName: 'Separated audio follow test',
          timeline: _linkedSourceTimeline(audioRole: TimelineTrackRole.regular),
        );

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();

    ({TimelineClip video, TimelineClip audio}) linkedClips() {
      final clips = container
          .read(editorProvider)
          .timeline
          .tracks
          .expand((track) => track.clips);
      return (
        video: clips.singleWhere((clip) => clip.id == 'linked_video'),
        audio: clips.singleWhere((clip) => clip.id == 'linked_audio'),
      );
    }

    void expectMirrored() {
      final linked = linkedClips();
      expect(linked.audio.startTime, linked.video.startTime);
      expect(linked.audio.endTime, linked.video.endTime);
      expect(linked.audio.sourceStartTime, linked.video.sourceStartTime);
      expect(linked.audio.sourceDuration, linked.video.sourceDuration);
      expect(linked.audio.playbackRate, linked.video.playbackRate);
      expect(linked.audio.isReversed, linked.video.isReversed);
    }

    final clipFinder = find.byKey(const ValueKey('timeline_clip_linked_video'));
    var gesture = await tester.startGesture(tester.getCenter(clipFinder));
    await _armTimelineEdit(tester);
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump(const Duration(milliseconds: 32));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      linkedClips().video.startTime,
      greaterThan(const Duration(seconds: 1)),
    );
    expectMirrored();

    gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('timeline_trim_start_linked_video')),
      ),
    );
    await _armTimelineEdit(tester);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 32));
    await gesture.up();
    await tester.pumpAndSettle();
    expectMirrored();

    gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('timeline_trim_end_linked_video')),
      ),
    );
    await _armTimelineEdit(tester);
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump(const Duration(milliseconds: 32));
    await gesture.up();
    await tester.pumpAndSettle();
    expectMirrored();
    expect(tester.takeException(), isNull);
  });

  testWidgets('independently retimed separated audio is never overwritten', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(520, 340));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'independent-audio-timing-test',
          projectName: 'Independent audio timing test',
          timeline: _linkedSourceTimeline(
            audioRole: TimelineTrackRole.regular,
            audioOffset: const Duration(milliseconds: 240),
          ),
        );

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    TimelineClip audio() => container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'linked_audio');
    final originalAudioJson = audio().toJson();

    final clipFinder = find.byKey(const ValueKey('timeline_clip_linked_video'));
    var gesture = await tester.startGesture(tester.getCenter(clipFinder));
    await _armTimelineEdit(tester);
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump(const Duration(milliseconds: 32));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(audio().toJson(), originalAudioJson);

    gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('timeline_trim_start_linked_video')),
      ),
    );
    await _armTimelineEdit(tester);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 32));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(audio().toJson(), originalAudioJson);
    expect(tester.takeException(), isNull);
  });

  testWidgets('splitting the Base layer splits exact separated audio', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'base-separated-audio-split-test',
          projectName: 'Base separated audio split test',
          timeline: _linkedSourceTimeline(audioRole: TimelineTrackRole.regular),
        );
    container.read(editorProvider.notifier)
      ..selectTrack('linked_video_track')
      ..selectClip('linked_video');
    container
        .read(playbackProvider.notifier)
        .updatePosition(const Duration(seconds: 5));

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Split'));
    await tester.pumpAndSettle();

    final timeline = container.read(editorProvider).timeline;
    final videos = timeline.tracks
        .singleWhere((track) => track.id == 'linked_video_track')
        .clips;
    final audios = timeline.tracks
        .singleWhere((track) => track.id == 'linked_audio_track')
        .clips;
    expect(videos, hasLength(2));
    expect(audios, hasLength(2));
    for (final video in videos) {
      final audio = audios.singleWhere(
        (candidate) => candidate.linkedClipId == video.id,
      );
      expect(audio.startTime, video.startTime);
      expect(audio.endTime, video.endTime);
      expect(audio.sourceStartTime, video.sourceStartTime);
      expect(audio.sourceDuration, video.sourceDuration);
    }
  });

  testWidgets('split preserves independent and locked separated audio', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final variant in const [
      (offset: Duration(milliseconds: 240), locked: false),
      (offset: Duration.zero, locked: true),
    ]) {
      final container = ProviderContainer();
      container
          .read(editorProvider.notifier)
          .loadProject(
            videoPath: 'missing.mp4',
            projectId: 'base-split-preserve-${variant.locked}',
            projectName: 'Base split preserve test',
            timeline: _linkedSourceTimeline(
              audioRole: TimelineTrackRole.regular,
              audioOffset: variant.offset,
              audioLocked: variant.locked,
            ),
          );
      container.read(editorProvider.notifier)
        ..selectTrack('linked_video_track')
        ..selectClip('linked_video');
      container
          .read(playbackProvider.notifier)
          .updatePosition(const Duration(seconds: 5));
      final originalAudio = container
          .read(editorProvider)
          .timeline
          .tracks
          .expand((track) => track.clips)
          .singleWhere((clip) => clip.id == 'linked_audio')
          .toJson();

      await tester.pumpWidget(_timelineHarness(container));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Split'));
      await tester.pumpAndSettle();

      final timeline = container.read(editorProvider).timeline;
      expect(
        timeline.tracks
            .singleWhere((track) => track.id == 'linked_video_track')
            .clips,
        hasLength(2),
      );
      final audios = timeline.tracks
          .singleWhere((track) => track.id == 'linked_audio_track')
          .clips;
      expect(audios, hasLength(1));
      expect(audios.single.toJson(), originalAudio);
      container.dispose();
    }
  });

  testWidgets('splitting an adjustment layer preserves animated stack state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adjustment = TimelineClip.effect(
      id: 'adjustment',
      trackId: 'adjustments',
      label: 'Adjustment',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 4),
      isAdjustmentLayer: true,
      groupId: 'adjustment-group',
      effectStack: EditorEffectStack(
        effects: [
          EditorEffect(
            id: 'blur-effect',
            type: EditorEffectType.gaussianBlur,
            keyframes: [
              EditorEffectParameterKeyframe(
                parameter: 'radius',
                time: Duration.zero,
                value: 0,
              ),
              EditorEffectParameterKeyframe(
                parameter: 'radius',
                time: const Duration(seconds: 4),
                value: 40,
              ),
            ],
          ),
        ],
      ),
    );
    final initial = _testTimeline();
    final timeline = initial.copyWith(
      tracks: [
        TimelineTrack(
          id: 'adjustments',
          name: 'Adjustments',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.overlay,
          clips: [adjustment],
        ),
        ...initial.tracks,
      ],
      groups: [
        TimelineGroup(
          id: 'adjustment-group',
          name: 'Adjustment group',
          clipIds: const ['adjustment'],
        ),
      ],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'adjustment-split-test',
          projectName: 'Adjustment split test',
          timeline: timeline,
        );
    container.read(editorProvider.notifier)
      ..selectTrack('adjustments')
      ..selectClip('adjustment');
    container
        .read(playbackProvider.notifier)
        .updatePosition(const Duration(seconds: 2));

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Split'));
    await tester.pumpAndSettle();

    final restored = container.read(editorProvider).timeline;
    final clips = restored.tracks
        .singleWhere((track) => track.id == 'adjustments')
        .clips;
    expect(clips, hasLength(2));
    expect(clips.every((clip) => clip.isAdjustmentLayer), isTrue);
    final leading = clips.first.effectStack.effects.single;
    final trailing = clips.last.effectStack.effects.single;
    expect(leading.id, 'blur-effect');
    expect(trailing.id, isNot(leading.id));
    expect(trailing.parameterAt('radius', Duration.zero), closeTo(20, 0.001));
    expect(
      restored.groups.single.clipIds.toSet(),
      clips.map((clip) => clip.id).toSet(),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('overlay-video audio follows moves and both trim edges', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(520, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'overlay-audio-follow-test',
          projectName: 'Overlay audio follow test',
          timeline: _linkedOverlayAudioTimeline(),
        );

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();

    ({TimelineClip video, TimelineClip audio}) linkedClips() {
      final clips = container
          .read(editorProvider)
          .timeline
          .tracks
          .expand((track) => track.clips);
      return (
        video: clips.singleWhere((clip) => clip.id == 'overlay_video'),
        audio: clips.singleWhere((clip) => clip.id == 'overlay_audio'),
      );
    }

    void expectMirrored() {
      final linked = linkedClips();
      expect(linked.audio.startTime, linked.video.startTime);
      expect(linked.audio.endTime, linked.video.endTime);
      expect(linked.audio.sourceStartTime, linked.video.sourceStartTime);
      expect(linked.audio.sourceDuration, linked.video.sourceDuration);
    }

    final clipFinder = find.byKey(
      const ValueKey('timeline_clip_overlay_video'),
    );
    var gesture = await tester.startGesture(tester.getCenter(clipFinder));
    await _armTimelineEdit(tester);
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump(const Duration(milliseconds: 32));
    await gesture.up();
    await tester.pumpAndSettle();
    expectMirrored();

    for (final edit in const [('start', 20.0), ('end', -20.0)]) {
      gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(ValueKey('timeline_trim_${edit.$1}_overlay_video')),
        ),
      );
      await _armTimelineEdit(tester);
      await gesture.moveBy(Offset(edit.$2, 0));
      await tester.pump(const Duration(milliseconds: 32));
      await gesture.up();
      await tester.pumpAndSettle();
      expectMirrored();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('independent or locked overlay audio remains untouched', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(520, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final variant in const [
      (offset: Duration(milliseconds: 240), locked: false),
      (offset: Duration.zero, locked: true),
    ]) {
      final container = ProviderContainer();
      container
          .read(editorProvider.notifier)
          .loadProject(
            videoPath: 'missing.mp4',
            projectId: 'overlay-audio-independent-${variant.locked}',
            projectName: 'Overlay audio independent test',
            timeline: _linkedOverlayAudioTimeline(
              audioOffset: variant.offset,
              audioLocked: variant.locked,
            ),
          );
      await tester.pumpWidget(_timelineHarness(container));
      await tester.pumpAndSettle();
      TimelineClip audio() => container
          .read(editorProvider)
          .timeline
          .tracks
          .expand((track) => track.clips)
          .singleWhere((clip) => clip.id == 'overlay_audio');
      final originalAudio = audio().toJson();

      final video = find.byKey(const ValueKey('timeline_clip_overlay_video'));
      var gesture = await tester.startGesture(tester.getCenter(video));
      await _armTimelineEdit(tester);
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump(const Duration(milliseconds: 32));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(audio().toJson(), originalAudio);

      gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey('timeline_trim_start_overlay_video')),
        ),
      );
      await _armTimelineEdit(tester);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 32));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(audio().toJson(), originalAudio);
      container.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('trim handle stays attached during edge auto-scroll', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'edge-trim-test',
          projectName: 'Edge trim test',
          timeline: _edgeTrimTimeline(),
        );
    container.read(editorProvider.notifier)
      ..selectTrack('overlay')
      ..selectClip('edge_clip');

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    final horizontalScroll = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .singleWhere(
          (scrollView) =>
              scrollView.scrollDirection == Axis.horizontal &&
              scrollView.controller != null,
        );
    horizontalScroll.controller!.jumpTo(50);
    await tester.pump();
    final initialOffset = horizontalScroll.controller!.offset;
    final initialEnd = container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'edge_clip')
        .endTime;

    final handle = find.byKey(const ValueKey('timeline_trim_end_edge_clip'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await _armTimelineEdit(tester);
    await gesture.moveBy(const Offset(8, 0));
    await tester.pump(const Duration(milliseconds: 240));
    await gesture.up();
    await tester.pumpAndSettle();

    final updatedEnd = container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'edge_clip')
        .endTime;
    expect(horizontalScroll.controller!.offset, greaterThan(initialOffset));
    expect(updatedEnd, greaterThan(initialEnd));
    expect(container.read(editorProvider).selectedClipId, 'edge_clip');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the plus button creates only supported lane types', (
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
    expect(find.text('Effects'), findsNothing);
    expect(find.byKey(const ValueKey('fixed_editor_sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('resizable_sheet_handle')), findsNothing);

    final overlayChoice = find.byKey(
      const ValueKey('timeline_track_choice_video'),
    );
    await tester.ensureVisible(overlayChoice);
    await tester.tap(overlayChoice);
    await tester.pumpAndSettle();

    final state = container.read(editorProvider);
    expect(state.timeline.tracks, hasLength(originalTrackCount + 1));
    final addedTrack = state.timeline.tracks.singleWhere(
      (track) => track.id == state.selectedTrackId,
    );
    expect(addedTrack.type, TimelineTrackType.video);
    expect(addedTrack.section, TimelineTrackSection.overlay);
    expect(state.selectedTrackId, addedTrack.id);
    expect(state.selectedClipId, isNull);
  });

  testWidgets('side add badges distinguish taps from track drags', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'side-add-test',
          projectName: 'Side add test',
          timeline: _testTimeline(),
        );
    var overlayAdds = 0;
    var textAdds = 0;
    var audioAdds = 0;

    await tester.pumpWidget(
      _timelineHarness(
        container,
        onOverlayAddRequested: (_) => overlayAdds++,
        onTextAddRequested: (_) => textAdds++,
        onAudioAddRequested: (_) => audioAdds++,
      ),
    );
    await tester.pumpAndSettle();

    final overlayAdd = find.byKey(const ValueKey('timeline_track_add_overlay'));
    await tester.tap(overlayAdd);
    await tester.pump();
    expect(overlayAdds, 1);

    final drag = await tester.startGesture(tester.getCenter(overlayAdd));
    await tester.pump(const Duration(milliseconds: 320));
    await drag.moveBy(const Offset(0, 80));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(overlayAdds, 1);

    final textAdd = find.byKey(const ValueKey('timeline_track_add_text'));
    await tester.ensureVisible(textAdd);
    await tester.tap(textAdd);
    await tester.pump();
    expect(textAdds, 1);

    final audioAdd = find.byKey(const ValueKey('timeline_track_add_audio_0'));
    await tester.ensureVisible(audioAdd);
    await tester.tap(audioAdd);
    await tester.pump();
    expect(audioAdds, 1);
  });

  testWidgets('main video plus trails clips and starts at zero when empty', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'main-add-test',
          projectName: 'Main add test',
          timeline: _testTimeline(),
        );
    TimelineTrack? requestedTrack;

    await tester.pumpWidget(
      _timelineHarness(
        container,
        onMainVideoAddRequested: (track) => requestedTrack = track,
      ),
    );
    await tester.pumpAndSettle();

    final addButton = find.byKey(
      const ValueKey('timeline_main_video_add_button'),
    );
    final baseClip = find.byKey(const ValueKey('timeline_clip_base_clip'));
    expect(addButton, findsOneWidget);
    expect(
      tester.getTopLeft(addButton).dx,
      closeTo(tester.getTopRight(baseClip).dx, 0.5),
    );
    await tester.tap(addButton);
    await tester.pump(const Duration(milliseconds: 400));
    expect(requestedTrack?.id, 'base');

    final timeline = container.read(editorProvider).timeline;
    container
        .read(editorProvider.notifier)
        .setTimeline(
          timeline.copyWith(
            tracks: timeline.tracks.map((track) {
              return track.id == 'base'
                  ? track.copyWith(clips: const [])
                  : track;
            }).toList(),
          ),
        );
    await tester.pumpAndSettle();

    final emptyLane = find.byKey(const ValueKey('timeline_lane_base'));
    expect(
      find.byKey(const ValueKey('timeline_main_video_add_base')),
      findsOne,
    );
    expect(
      tester.getTopLeft(addButton).dx,
      closeTo(tester.getTopLeft(emptyLane).dx, 1.1),
    );

    final emptyTimeline = container.read(editorProvider).timeline;
    container
        .read(editorProvider.notifier)
        .setTimeline(
          emptyTimeline.copyWith(
            tracks: emptyTimeline.tracks.map((track) {
              return track.id == 'base'
                  ? track.copyWith(isLocked: true)
                  : track;
            }).toList(),
          ),
        );
    await tester.pumpAndSettle();
    expect(addButton, findsNothing);
  });

  testWidgets('long press converts main video and preserves linked audio', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final initialTimeline = _linkedSourceTimeline();
    final originalVideo = initialTimeline.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'linked_video');
    final originalAudio = initialTimeline.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'linked_audio');
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'convert-overlay-test',
          projectName: 'Convert overlay test',
          timeline: initialTimeline,
        );

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('timeline_clip_linked_video')),
    );
    await tester.pumpAndSettle();

    final convertAction = find.byKey(
      const ValueKey('timeline_convert_to_overlay_action'),
    );
    expect(convertAction, findsOneWidget);
    expect(find.text('Convert to overlay'), findsOneWidget);
    await tester.tap(convertAction);
    await tester.pumpAndSettle();

    final updated = container.read(editorProvider).timeline;
    final mainTrack = updated.tracks.singleWhere(
      (track) => track.section == TimelineTrackSection.baseVideo,
    );
    final overlayTrack = updated.tracks.singleWhere(
      (track) =>
          track.section == TimelineTrackSection.overlay &&
          track.clips.any((clip) => clip.id == originalVideo.id),
    );
    final converted = overlayTrack.clips.singleWhere(
      (clip) => clip.id == originalVideo.id,
    );
    final linkedAudio = updated.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == originalAudio.id);

    expect(mainTrack.clips, isEmpty);
    expect({
      ...converted.toJson(),
      'trackId': originalVideo.trackId,
    }, originalVideo.toJson());
    expect(linkedAudio.toJson(), originalAudio.toJson());
    expect(linkedAudio.linkedClipId, converted.id);
    expect(container.read(editorProvider).selectedTrackId, overlayTrack.id);
    expect(container.read(editorProvider).selectedClipId, converted.id);
  });

  testWidgets('a sole main clip can move later and extend the timeline', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'main-move-test',
          projectName: 'Main move test',
          timeline: _testTimeline(),
        );

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    final mainClip = find.byKey(const ValueKey('timeline_clip_base_clip'));
    final gesture = await tester.startGesture(tester.getCenter(mainClip));
    await _armTimelineEdit(tester);
    for (var index = 0; index < 5; index++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final moved = container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'base_clip');
    expect(moved.startTime, greaterThan(Duration.zero));
    expect(moved.endTime, greaterThan(const Duration(seconds: 10)));
    expect(moved.duration, const Duration(seconds: 10));
    expect(container.read(editorProvider).timeline.hasTrackOverlaps, isFalse);
  });

  testWidgets('pasting uses the nearest free gap in the same track', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'paste-gap-test',
          projectName: 'Paste gap test',
          timeline: _testTimeline(),
        );
    container.read(editorProvider.notifier)
      ..selectTrack('overlay')
      ..selectClip('overlay_clip');

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    await tester.tap(find.byTooltip('Paste at playhead'));
    await tester.pumpAndSettle();

    final overlay = container
        .read(editorProvider)
        .timeline
        .tracks
        .singleWhere((track) => track.id == 'overlay');
    final pasted = overlay.clips.singleWhere(
      (clip) => clip.id != 'overlay_clip',
    );
    expect(pasted.startTime, const Duration(seconds: 3));
    expect(pasted.endTime, const Duration(seconds: 5));
    expect(overlay.hasOverlappingClips, isFalse);
  });

  testWidgets('duplicate skips occupied time and keeps edge adjacency', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'duplicate-gap-test',
          projectName: 'Duplicate gap test',
          timeline: _duplicateGapTimeline(),
        );
    container.read(editorProvider.notifier)
      ..selectTrack('overlay')
      ..selectClip('overlay_clip');

    await tester.pumpWidget(_timelineHarness(container));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Duplicate selection'));
    await tester.pumpAndSettle();

    final overlay = container
        .read(editorProvider)
        .timeline
        .tracks
        .singleWhere((track) => track.id == 'overlay');
    final duplicate = overlay.clips.singleWhere(
      (clip) => clip.id != 'overlay_clip' && clip.id != 'occupied_after',
    );
    expect(duplicate.startTime, const Duration(seconds: 5));
    expect(duplicate.endTime, const Duration(seconds: 7));
    expect(overlay.hasOverlappingClips, isFalse);
  });

  testWidgets(
    'trim stops at an edge and occupied cross-lane drops are rejected',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(editorProvider.notifier)
          .loadProject(
            videoPath: 'missing.mp4',
            projectId: 'collision-gesture-test',
            projectName: 'Collision gesture test',
            timeline: _crossLaneCollisionTimeline(),
          );
      container.read(editorProvider.notifier)
        ..selectTrack('overlay_target')
        ..selectClip('target_moving');

      await tester.pumpWidget(_timelineHarness(container));
      await tester.pumpAndSettle();

      final trimHandle = find.byKey(
        const ValueKey('timeline_trim_start_target_moving'),
      );
      final trimGesture = await tester.startGesture(
        tester.getCenter(trimHandle),
      );
      await _armTimelineEdit(tester);
      await trimGesture.moveBy(const Offset(-150, 0));
      await tester.pump(const Duration(milliseconds: 32));
      await trimGesture.up();
      await tester.pumpAndSettle();

      var targetTrack = container
          .read(editorProvider)
          .timeline
          .tracks
          .singleWhere((track) => track.id == 'overlay_target');
      final trimmed = targetTrack.clips.singleWhere(
        (clip) => clip.id == 'target_moving',
      );
      expect(trimmed.startTime, const Duration(seconds: 3));
      expect(targetTrack.hasOverlappingClips, isFalse);

      final moving = find.byKey(const ValueKey('timeline_clip_overlay_clip'));
      final moveGesture = await tester.startGesture(tester.getCenter(moving));
      await _armTimelineEdit(tester);
      final sourceLaneCenter = tester.getCenter(
        find.byKey(const ValueKey('timeline_lane_overlay')),
      );
      final targetLaneCenter = tester.getCenter(
        find.byKey(const ValueKey('timeline_lane_overlay_target')),
      );
      await moveGesture.moveBy(
        Offset(0, targetLaneCenter.dy - sourceLaneCenter.dy),
      );
      await tester.pump();
      await moveGesture.up();
      await tester.pumpAndSettle();

      targetTrack = container
          .read(editorProvider)
          .timeline
          .tracks
          .singleWhere((track) => track.id == 'overlay_target');
      expect(
        targetTrack.clips.where((clip) => clip.id == 'overlay_clip'),
        isEmpty,
      );
      final moved = container
          .read(editorProvider)
          .timeline
          .tracks
          .singleWhere((track) => track.id == 'overlay')
          .clips
          .singleWhere((clip) => clip.id == 'overlay_clip');
      expect(moved.startTime, const Duration(seconds: 1));
      expect(targetTrack.hasOverlappingClips, isFalse);
    },
  );

  testWidgets('clip deletion cannot remove the project last visual', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'last-visual-clip-test',
          projectName: 'Last visual clip test',
          timeline: _onlyOverlayVisualTimeline(),
        );
    container.read(editorProvider.notifier)
      ..selectTrack('overlay')
      ..selectClip('overlay_clip');
    TimelineClip? replaceRequested;

    await tester.pumpWidget(
      _timelineHarness(
        container,
        onReplaceMediaRequested: (clip) => replaceRequested = clip,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();

    expect(
      container.read(editorProvider).timeline.visualMediaClips,
      hasLength(1),
    );
    expect(
      find.byKey(const ValueKey('timeline_last_visual_dialog')),
      findsOneWidget,
    );
    expect(replaceRequested, isNull);
    await tester.tap(
      find.byKey(const ValueKey('timeline_replace_last_visual')),
    );
    await tester.pumpAndSettle();
    expect(replaceRequested?.id, 'overlay_clip');
  });

  testWidgets('track deletion cannot remove the project last visual', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(editorProvider.notifier)
        .loadProject(
          videoPath: 'missing.mp4',
          projectId: 'last-visual-track-test',
          projectName: 'Last visual track test',
          timeline: _onlyOverlayVisualTimeline(),
        );
    TimelineClip? replaceRequested;

    await tester.pumpWidget(
      _timelineHarness(
        container,
        onReplaceMediaRequested: (clip) => replaceRequested = clip,
      ),
    );
    await tester.pumpAndSettle();
    final trackLabel = find.byKey(const ValueKey('timeline_track_overlay'));
    tester.widget<GestureDetector>(trackLabel).onTap?.call();
    await tester.pump();
    tester.widget<GestureDetector>(trackLabel).onTap?.call();
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      container
          .read(editorProvider)
          .timeline
          .tracks
          .any((track) => track.id == 'overlay'),
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('timeline_last_visual_dialog')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('timeline_replace_last_visual')),
    );
    await tester.pumpAndSettle();
    expect(replaceRequested?.id, 'overlay_clip');
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

Future<void> _armTimelineEdit(WidgetTester tester) {
  return tester.pump(
    timelineEditHoldDurationForTesting + const Duration(milliseconds: 20),
  );
}

Widget _timelineHarness(
  ProviderContainer container, {
  ValueChanged<TimelineTrack>? onMainVideoAddRequested,
  ValueChanged<TimelineClip>? onReplaceMediaRequested,
  ValueChanged<TimelineTrack>? onOverlayAddRequested,
  ValueChanged<TimelineTrack>? onTextAddRequested,
  ValueChanged<TimelineTrack>? onAudioAddRequested,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: TimelinePanel(
          onMainVideoAddRequested: onMainVideoAddRequested,
          onReplaceMediaRequested: onReplaceMediaRequested,
          onOverlayAddRequested: onOverlayAddRequested,
          onTextAddRequested: onTextAddRequested,
          onAudioAddRequested: onAudioAddRequested,
        ),
      ),
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

EditorTimeline _threeOverlayLaneTimeline() {
  final timeline = _testTimeline();
  final third = TimelineTrack(
    id: 'overlay_third',
    name: 'Third visual overlay',
    type: TimelineTrackType.video,
    section: TimelineTrackSection.overlay,
  );
  final overlay = timeline.tracks.singleWhere((track) => track.id == 'overlay');
  final target = timeline.tracks.singleWhere(
    (track) => track.id == 'overlay_target',
  );
  return timeline.copyWith(
    tracks: [
      overlay,
      target,
      third,
      ...timeline.tracks.where(
        (track) => track.id != overlay.id && track.id != target.id,
      ),
    ],
  );
}

EditorTimeline _longClipDragTimeline() {
  TimelineTrack overlay(String id, {List<TimelineClip> clips = const []}) {
    return TimelineTrack(
      id: id,
      name: id,
      type: TimelineTrackType.video,
      section: TimelineTrackSection.overlay,
      clips: clips,
    );
  }

  final moving = TimelineClip(
    id: 'long_overlay',
    trackId: 'overlay_source',
    type: TimelineTrackType.video,
    label: 'Long overlay',
    startTime: const Duration(seconds: 1),
    endTime: const Duration(seconds: 7),
  );
  final blocker = TimelineClip(
    id: 'occupied_overlay',
    trackId: 'overlay_occupied',
    type: TimelineTrackType.video,
    label: 'Occupied overlay',
    startTime: Duration.zero,
    endTime: const Duration(seconds: 8),
  );
  return EditorTimeline(
    tracks: [
      overlay('overlay_source', clips: [moving]),
      overlay('overlay_occupied', clips: [blocker]),
      overlay('overlay_free'),
      TimelineTrack(
        id: 'base',
        name: 'Base layer',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [
          TimelineClip(
            id: 'base_clip',
            trackId: 'base',
            type: TimelineTrackType.video,
            label: 'Base',
            startTime: Duration.zero,
            endTime: const Duration(seconds: 20),
          ),
        ],
      ),
    ],
  );
}

EditorTimeline _duplicateGapTimeline() {
  final timeline = _testTimeline();
  return timeline.copyWith(
    tracks: timeline.tracks.map((track) {
      if (track.id != 'overlay') return track;
      return track.copyWith(
        clips: [
          ...track.clips,
          TimelineClip(
            id: 'occupied_after',
            trackId: track.id,
            type: TimelineTrackType.image,
            label: 'Occupied after',
            startTime: const Duration(seconds: 3),
            endTime: const Duration(seconds: 5),
          ),
        ],
      );
    }).toList(),
  );
}

EditorTimeline _crossLaneCollisionTimeline() {
  final timeline = _testTimeline();
  return timeline.copyWith(
    tracks: timeline.tracks.map((track) {
      if (track.id != 'overlay_target') return track;
      return track.copyWith(
        clips: [
          TimelineClip(
            id: 'target_blocker',
            trackId: track.id,
            type: TimelineTrackType.image,
            label: 'Target blocker',
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 3),
          ),
          TimelineClip(
            id: 'target_moving',
            trackId: track.id,
            type: TimelineTrackType.image,
            label: 'Target moving',
            startTime: const Duration(seconds: 5),
            endTime: const Duration(seconds: 7),
          ),
        ],
      );
    }).toList(),
  );
}

EditorTimeline _onlyOverlayVisualTimeline() {
  final timeline = _testTimeline();
  return timeline.copyWith(
    tracks: timeline.tracks.map((track) {
      return track.section == TimelineTrackSection.baseVideo
          ? track.copyWith(clips: const [])
          : track;
    }).toList(),
  );
}

EditorTimeline _linkedSourceTimeline({
  TimelineTrackRole audioRole = TimelineTrackRole.sourceAudio,
  Duration audioOffset = Duration.zero,
  bool audioLocked = false,
}) {
  const timelineDuration = Duration(seconds: 10);
  const sourceStart = Duration(seconds: 1);
  const sourceDuration = Duration(seconds: 8);
  final asset = EditorAssetReference(
    id: 'linked_asset',
    type: EditorAssetType.video,
    label: 'Linked source',
    sourcePath: 'missing.mp4',
    metadata: const {'durationMs': 12000, 'hasAudio': true},
  );
  final video = TimelineClip(
    id: 'linked_video',
    trackId: 'linked_video_track',
    type: TimelineTrackType.video,
    label: 'Linked video',
    assetId: asset.id,
    startTime: const Duration(seconds: 1),
    endTime: const Duration(seconds: 9),
    sourceStartTime: sourceStart,
    sourceDuration: sourceDuration,
    audioMix: const AudioMixSettings(muted: true),
  );
  return EditorTimeline(
    assets: [asset],
    tracks: [
      TimelineTrack(
        id: 'linked_video_track',
        name: 'Source video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        role: TimelineTrackRole.sourceVideo,
        clips: [video],
      ),
      TimelineTrack(
        id: 'linked_audio_track',
        name: audioRole == TimelineTrackRole.sourceAudio
            ? 'Source audio'
            : 'Separated audio',
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        role: audioRole,
        isLocked: audioLocked,
        clips: [
          TimelineClip(
            id: 'linked_audio',
            trackId: 'linked_audio_track',
            type: TimelineTrackType.audio,
            label: 'Linked audio',
            assetId: asset.id,
            linkedClipId: video.id,
            startTime: video.startTime + audioOffset,
            endTime: video.endTime + audioOffset,
            sourceStartTime: sourceStart,
            sourceDuration: sourceDuration,
            playbackRate: video.playbackRate,
            isReversed: video.isReversed,
          ),
        ],
      ),
    ],
    workspaceSettings: const TimelineWorkspaceSettings(
      workAreaEnd: timelineDuration,
    ),
  );
}

EditorTimeline _linkedOverlayAudioTimeline({
  Duration audioOffset = Duration.zero,
  bool audioLocked = false,
}) {
  const sourceStart = Duration(seconds: 1);
  const sourceDuration = Duration(seconds: 8);
  final asset = EditorAssetReference(
    id: 'overlay_asset',
    type: EditorAssetType.video,
    label: 'Overlay source',
    sourcePath: 'missing.mp4',
    metadata: const {'durationMs': 12000, 'hasAudio': true},
  );
  final video = TimelineClip(
    id: 'overlay_video',
    trackId: 'overlay_video_track',
    type: TimelineTrackType.video,
    label: 'Overlay video',
    assetId: asset.id,
    startTime: const Duration(seconds: 1),
    endTime: const Duration(seconds: 9),
    sourceStartTime: sourceStart,
    sourceDuration: sourceDuration,
    audioMix: const AudioMixSettings(muted: true),
  );
  return EditorTimeline(
    assets: [asset],
    tracks: [
      TimelineTrack(
        id: 'overlay_video_track',
        name: 'Overlay',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
        clips: [video],
      ),
      TimelineTrack(
        id: 'base',
        name: 'Base layer',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [
          TimelineClip(
            id: 'base_clip',
            trackId: 'base',
            type: TimelineTrackType.video,
            label: 'Base',
            startTime: Duration.zero,
            endTime: const Duration(seconds: 12),
          ),
        ],
      ),
      TimelineTrack(
        id: 'overlay_audio_track',
        name: 'Separated overlay audio',
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        isLocked: audioLocked,
        clips: [
          TimelineClip(
            id: 'overlay_audio',
            trackId: 'overlay_audio_track',
            type: TimelineTrackType.audio,
            label: 'Overlay audio',
            assetId: asset.id,
            linkedClipId: video.id,
            startTime: video.startTime + audioOffset,
            endTime: video.endTime + audioOffset,
            sourceStartTime: sourceStart,
            sourceDuration: sourceDuration,
            playbackRate: video.playbackRate,
            isReversed: video.isReversed,
          ),
        ],
      ),
    ],
  );
}

EditorTimeline _edgeTrimTimeline() {
  final timeline = _testTimeline();
  return timeline.copyWith(
    tracks: timeline.tracks.map((track) {
      if (track.id != 'overlay') return track;
      return track.copyWith(
        clips: [
          ...track.clips,
          TimelineClip(
            id: 'edge_clip',
            trackId: track.id,
            type: TimelineTrackType.image,
            label: 'Edge overlay',
            startTime: const Duration(seconds: 5),
            endTime: const Duration(seconds: 7),
            sourceDuration: const Duration(seconds: 2),
          ),
        ],
      );
    }).toList(),
  );
}
