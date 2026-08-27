import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/services/timeline_keyframe_editing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TimelineKeyframeEditing', () {
    test('split preserves both retained halves of a cubic segment', () {
      final clip = _animatedClip();
      const cut = Duration(milliseconds: 1375);
      final split = TimelineKeyframeEditing.split(clip, cut);
      final leading = clip.copyWith(
        endTime: clip.startTime + cut,
        keyframes: split.leading,
      );
      final trailing = clip.copyWith(
        id: 'trailing',
        startTime: clip.startTime + cut,
        keyframes: split.trailing,
      );

      for (var milliseconds = 0; milliseconds <= 4000; milliseconds += 25) {
        final position = clip.startTime + Duration(milliseconds: milliseconds);
        final expected = clip.keyframedValue(
          TimelineKeyframeProperty.opacity,
          position,
        );
        final actual = milliseconds <= cut.inMilliseconds
            ? leading.keyframedValue(TimelineKeyframeProperty.opacity, position)
            : trailing.keyframedValue(
                TimelineKeyframeProperty.opacity,
                position,
              );
        expect(actual, closeTo(expected, 0.00002), reason: '$milliseconds ms');
      }

      final leadingIds = split.leading.map((frame) => frame.id).toSet();
      final trailingIds = split.trailing.map((frame) => frame.id).toSet();
      expect(leadingIds.intersection(trailingIds), isEmpty);
      expect(split.leading.last.time, cut);
      expect(split.trailing.first.time, Duration.zero);
    });

    test('leading trim rebases a curve without changing visible values', () {
      final clip = _animatedClip();
      final newStart = clip.startTime + const Duration(milliseconds: 925);
      final trimmed = clip.copyWith(
        startTime: newStart,
        keyframes: TimelineKeyframeEditing.forNewStart(clip, newStart),
      );

      for (var milliseconds = 925; milliseconds <= 4000; milliseconds += 25) {
        final position = clip.startTime + Duration(milliseconds: milliseconds);
        expect(
          trimmed.keyframedValue(TimelineKeyframeProperty.opacity, position),
          closeTo(
            clip.keyframedValue(TimelineKeyframeProperty.opacity, position),
            0.00002,
          ),
          reason: '$milliseconds ms',
        );
      }
    });

    test('trailing trim preserves a cubic segment up to the new edge', () {
      final clip = _animatedClip();
      final newEnd = clip.startTime + const Duration(milliseconds: 2875);
      final trimmed = clip.copyWith(
        endTime: newEnd,
        keyframes: TimelineKeyframeEditing.forNewEnd(clip, newEnd),
      );

      for (var milliseconds = 0; milliseconds <= 2875; milliseconds += 25) {
        final position = clip.startTime + Duration(milliseconds: milliseconds);
        expect(
          trimmed.keyframedValue(TimelineKeyframeProperty.opacity, position),
          closeTo(
            clip.keyframedValue(TimelineKeyframeProperty.opacity, position),
            0.00002,
          ),
          reason: '$milliseconds ms',
        );
      }
    });

    test('extending the leading edge keeps keys at absolute positions', () {
      final clip = _animatedClip();
      final newStart = clip.startTime - const Duration(milliseconds: 500);
      final extended = clip.copyWith(
        startTime: newStart,
        keyframes: TimelineKeyframeEditing.forNewStart(clip, newStart),
      );

      expect(extended.keyframes.map((frame) => frame.time.inMilliseconds), [
        500,
        4500,
      ]);
      for (var milliseconds = 0; milliseconds <= 4000; milliseconds += 100) {
        final position = clip.startTime + Duration(milliseconds: milliseconds);
        expect(
          extended.keyframedValue(TimelineKeyframeProperty.opacity, position),
          closeTo(
            clip.keyframedValue(TimelineKeyframeProperty.opacity, position),
            0.000001,
          ),
        );
      }
    });

    test('hold interpolation remains a hold across an interior split', () {
      final clip = TimelineClip(
        trackId: 'video',
        type: TimelineTrackType.video,
        label: 'Hold',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
        keyframes: [
          TimelineKeyframe(
            time: Duration.zero,
            property: TimelineKeyframeProperty.scale,
            value: 1,
            interpolation: TimelineKeyframeInterpolation.hold,
          ),
          TimelineKeyframe(
            time: const Duration(seconds: 2),
            property: TimelineKeyframeProperty.scale,
            value: 2,
          ),
        ],
      );

      final split = TimelineKeyframeEditing.split(
        clip,
        const Duration(seconds: 1),
      );
      final trailing = clip.copyWith(
        startTime: const Duration(seconds: 1),
        keyframes: split.trailing,
      );

      expect(split.leading.last.value, 1);
      expect(
        split.trailing.first.interpolation,
        TimelineKeyframeInterpolation.hold,
      );
      expect(
        trailing.keyframedValue(
          TimelineKeyframeProperty.scale,
          const Duration(milliseconds: 1999),
        ),
        1,
      );
      expect(
        trailing.keyframedValue(
          TimelineKeyframeProperty.scale,
          const Duration(seconds: 2),
        ),
        2,
      );
    });

    test('retime scales key times and preserves normalized curve values', () {
      final clip = _animatedClip();
      const newDuration = Duration(seconds: 10);
      final retimed = clip.copyWith(
        endTime: clip.startTime + newDuration,
        keyframes: TimelineKeyframeEditing.retime(clip, newDuration),
      );

      expect(retimed.keyframes.last.time, newDuration);
      for (var step = 0; step <= 100; step++) {
        final progress = step / 100;
        final originalPosition =
            clip.startTime +
            Duration(
              microseconds: (clip.duration.inMicroseconds * progress).round(),
            );
        final retimedPosition =
            retimed.startTime +
            Duration(
              microseconds: (newDuration.inMicroseconds * progress).round(),
            );
        expect(
          retimed.keyframedValue(
            TimelineKeyframeProperty.opacity,
            retimedPosition,
          ),
          closeTo(
            clip.keyframedValue(
              TimelineKeyframeProperty.opacity,
              originalPosition,
            ),
            0.00001,
          ),
        );
      }
    });
  });
}

TimelineClip _animatedClip() {
  return TimelineClip(
    id: 'animated',
    trackId: 'video',
    type: TimelineTrackType.video,
    label: 'Animated',
    startTime: const Duration(seconds: 10),
    endTime: const Duration(seconds: 14),
    keyframes: [
      TimelineKeyframe(
        id: 'start',
        time: Duration.zero,
        property: TimelineKeyframeProperty.opacity,
        value: 0.1,
        interpolation: TimelineKeyframeInterpolation.cubicBezier,
        curve: const TimelineBezierCurve(
          x1: 0.18,
          y1: 0.72,
          x2: 0.76,
          y2: 0.24,
        ),
      ),
      TimelineKeyframe(
        id: 'end',
        time: const Duration(seconds: 4),
        property: TimelineKeyframeProperty.opacity,
        value: 0.9,
      ),
    ],
  );
}
