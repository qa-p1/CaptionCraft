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
    for (final key in const [
      'keyframe_curve_hold',
      'keyframe_curve_linear',
      'keyframe_curve_easeInOut',
      'keyframe_curve_sineOut',
      'keyframe_curve_quadInOut',
      'keyframe_curve_cubicOut',
      'keyframe_curve_backOut',
      'keyframe_curve_custom',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
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
    await tester.pumpAndSettle();
    expect(requestedSeek, isNotNull);
  });

  testWidgets(
    'graph supports multi-key copy paste, numeric editing and channel locks',
    (tester) async {
      var clip = TimelineClip(
        id: 'multi',
        trackId: 'video',
        type: TimelineTrackType.video,
        label: 'Multi-key clip',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
        keyframes: [
          TimelineKeyframe(
            id: 'first',
            time: Duration.zero,
            property: TimelineKeyframeProperty.opacity,
            value: 0,
          ),
          TimelineKeyframe(
            id: 'second',
            time: const Duration(seconds: 1),
            property: TimelineKeyframeProperty.opacity,
            value: 1,
          ),
        ],
      );
      var playhead = const Duration(milliseconds: 500);
      final historyModes = <bool>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 760,
              child: StatefulBuilder(
                builder: (context, setState) => KeyframeGraphEditor(
                  clip: clip,
                  properties: const [TimelineKeyframeProperty.opacity],
                  initialProperty: TimelineKeyframeProperty.opacity,
                  playhead: playhead,
                  frameRate: 30,
                  onChanged: (keyframes, recordHistory) {
                    historyModes.add(recordHistory);
                    setState(() => clip = clip.copyWith(keyframes: keyframes));
                  },
                  onSeek: (position) => setState(() => playhead = position),
                  onEditStart: () {},
                  onEditEnd: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(
        find.byTooltip('Drag a box around multiple keyframes'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Select every keyframe in this channel'));
      await tester.pump();
      await tester.tap(find.byTooltip('Copy selected keyframes'));
      await tester.tap(find.byTooltip('Delete selected keyframe'));
      await tester.pump();
      expect(clip.keyframes, isEmpty);

      await tester.tap(
        find.byTooltip('Paste copied keyframes at the playhead'),
      );
      await tester.pump();
      expect(clip.keyframes, hasLength(2));
      expect(historyModes.last, isTrue);

      await tester.tap(find.byTooltip('Enter exact keyframe time and value'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('keyframe_numeric_time')),
        '300',
      );
      await tester.enterText(
        find.byKey(const ValueKey('keyframe_numeric_value')),
        '0.25',
      );
      await tester.tap(find.byKey(const ValueKey('keyframe_numeric_apply')));
      await tester.pumpAndSettle();
      expect(
        clip.keyframes.any(
          (frame) =>
              frame.time == const Duration(milliseconds: 300) &&
              (frame.value - 0.25).abs() < 0.0001,
        ),
        isTrue,
      );

      await tester.tap(find.byTooltip('Show, solo or lock animation channels'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('keyframe_channel_opacity')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('keyframe_channel_lock_opacity')),
      );
      await tester.pump();
      await tester.tap(find.text('Opacity').last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add keyframe at playhead'), findsOneWidget);
      final addButton = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byTooltip('Add keyframe at playhead'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(addButton.onPressed, isNull);
    },
  );
}
