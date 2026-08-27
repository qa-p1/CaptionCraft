import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/widgets/keyframe_graph_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('graph adds a key and persists its outgoing curve preset', (
    tester,
  ) async {
    var clip = TimelineClip(
      id: 'animated',
      trackId: 'video',
      type: TimelineTrackType.video,
      label: 'Animated clip',
      startTime: const Duration(seconds: 10),
      endTime: const Duration(seconds: 11),
      keyframes: [
        TimelineKeyframe(
          id: 'start',
          time: Duration.zero,
          property: TimelineKeyframeProperty.opacity,
          value: 0,
        ),
        TimelineKeyframe(
          id: 'end',
          time: const Duration(seconds: 1),
          property: TimelineKeyframeProperty.opacity,
          value: 1,
        ),
      ],
    );
    final historyModes = <bool>[];
    Duration? requestedSeek;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 720,
            child: StatefulBuilder(
              builder: (context, setState) => KeyframeGraphEditor(
                clip: clip,
                properties: const [TimelineKeyframeProperty.opacity],
                initialProperty: TimelineKeyframeProperty.opacity,
                playhead: const Duration(milliseconds: 10500),
                frameRate: 30,
                onChanged: (keyframes, recordHistory) {
                  historyModes.add(recordHistory);
                  setState(() => clip = clip.copyWith(keyframes: keyframes));
                },
                onSeek: (position) => requestedSeek = position,
                onEditStart: () {},
                onEditEnd: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('keyframe_graph_canvas')), findsOneWidget);
    await tester.tap(find.text('Add'));
    await tester.pump();

    final middle = clip.keyframes.singleWhere(
      (frame) => frame.time == const Duration(milliseconds: 500),
    );
    expect(middle.value, closeTo(0.5, 0.0001));
    expect(historyModes.last, isTrue);

    await tester.tap(find.text('Ease in/out'));
    await tester.pump();

    final curvedMiddle = clip.keyframes.singleWhere(
      (frame) => frame.id == middle.id,
    );
    expect(curvedMiddle.interpolation, TimelineKeyframeInterpolation.easeInOut);

    await tester.tap(find.byKey(const ValueKey('keyframe_graph_canvas')));
    await tester.pump();
    expect(requestedSeek, isNotNull);
  });
}
