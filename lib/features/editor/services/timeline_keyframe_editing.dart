import 'dart:math' as math;

import '../models/timeline_models.dart';

/// Pure keyframe math used by destructive timeline edits.
///
/// Keyframes are clip-relative, so moving a clip needs no rewrite. Splitting,
/// trimming the leading edge, and changing a clip's duration do. Keeping this
/// logic outside the timeline widget gives every edit path the same curve
/// semantics and makes the result independently testable.
final class TimelineKeyframeEditing {
  const TimelineKeyframeEditing._();

  /// Splits every animation channel at [relativeCut].
  ///
  /// Cubic timing curves are subdivided with De Casteljau's algorithm at the
  /// parameter whose x-coordinate matches the cut time. The two normalized
  /// child curves therefore reproduce the retained portions of the original
  /// segment rather than restarting the easing on each new clip.
  static ({List<TimelineKeyframe> leading, List<TimelineKeyframe> trailing})
  split(
    TimelineClip clip,
    Duration relativeCut, {
    bool regenerateTrailingIds = true,
  }) {
    final cutUs = relativeCut.inMicroseconds
        .clamp(0, clip.duration.inMicroseconds)
        .toInt();
    if (clip.keyframes.isEmpty) {
      return (leading: const [], trailing: const []);
    }

    final leading = <TimelineKeyframe>[];
    final trailing = <TimelineKeyframe>[];
    for (final property in TimelineKeyframeProperty.values) {
      final frames =
          clip.keyframes.where((frame) => frame.property == property).toList()
            ..sort((a, b) => a.time.compareTo(b.time));
      if (frames.isEmpty) continue;
      final split = _splitChannel(
        frames,
        Duration(microseconds: cutUs),
        regenerateTrailingIds: regenerateTrailingIds,
      );
      leading.addAll(split.leading);
      trailing.addAll(split.trailing);
    }
    _sort(leading);
    _sort(trailing);
    return (
      leading: List.unmodifiable(leading),
      trailing: List.unmodifiable(trailing),
    );
  }

  /// Keyframes for a clip whose leading edge moves to [newStart].
  ///
  /// Trimming inward keeps the trailing part of each curve and rebases it to
  /// zero. Extending outward shifts existing keys so their absolute timeline
  /// positions and the visible animation remain unchanged.
  static List<TimelineKeyframe> forNewStart(
    TimelineClip clip,
    Duration newStart,
  ) {
    final delta = newStart - clip.startTime;
    if (delta == Duration.zero || clip.keyframes.isEmpty) {
      return clip.keyframes;
    }
    if (delta.isNegative) {
      final shift = -delta;
      return List.unmodifiable(
        clip.keyframes
            .map((frame) => frame.copyWith(time: frame.time + shift))
            .toList()
          ..sort(_compare),
      );
    }
    return split(clip, delta, regenerateTrailingIds: false).trailing;
  }

  /// Keyframes for a clip whose trailing edge moves to [newEnd].
  ///
  /// Extending the clip needs no rewrite because values after the last key are
  /// held. Trimming inward retains the leading portion of every curve.
  static List<TimelineKeyframe> forNewEnd(TimelineClip clip, Duration newEnd) {
    final retainedDuration = newEnd - clip.startTime;
    if (clip.keyframes.isEmpty || retainedDuration >= clip.duration) {
      return clip.keyframes;
    }
    return split(clip, retainedDuration).leading;
  }

  /// Scales clip-relative key times for a playback-rate or duration change.
  /// Curve handles are normalized segment coordinates, so preserving them
  /// while scaling every key time preserves the complete animation shape.
  static List<TimelineKeyframe> retime(
    TimelineClip clip,
    Duration newDuration,
  ) {
    if (clip.keyframes.isEmpty || clip.duration <= Duration.zero) {
      return clip.keyframes;
    }
    final safeNewUs = math.max(1, newDuration.inMicroseconds);
    final oldUs = math.max(1, clip.duration.inMicroseconds);
    return List.unmodifiable(
      clip.keyframes
          .map(
            (frame) => frame.copyWith(
              time: Duration(
                microseconds: (frame.time.inMicroseconds * safeNewUs / oldUs)
                    .round()
                    .clamp(0, safeNewUs)
                    .toInt(),
              ),
            ),
          )
          .toList()
        ..sort(_compare),
    );
  }

  static ({List<TimelineKeyframe> leading, List<TimelineKeyframe> trailing})
  _splitChannel(
    List<TimelineKeyframe> frames,
    Duration cut, {
    required bool regenerateTrailingIds,
  }) {
    final cutUs = cut.inMicroseconds;
    final exactIndex = frames.indexWhere(
      (frame) => frame.time.inMicroseconds == cutUs,
    );
    if (exactIndex >= 0) {
      final exact = frames[exactIndex];
      final leading = frames.take(exactIndex + 1).toList();
      final trailing = <TimelineKeyframe>[
        _clone(exact, time: Duration.zero, regenerateId: regenerateTrailingIds),
        for (final frame in frames.skip(exactIndex + 1))
          _clone(
            frame,
            time: frame.time - cut,
            regenerateId: regenerateTrailingIds,
          ),
      ];
      return (leading: leading, trailing: trailing);
    }

    final before = frames.where((frame) => frame.time < cut).toList();
    final after = frames.where((frame) => frame.time > cut).toList();
    final previous = before.lastOrNull;
    final next = after.firstOrNull;

    var boundaryValue = previous?.value ?? next?.value ?? frames.first.value;
    var boundaryInterpolation = TimelineKeyframeInterpolation.linear;
    var boundaryCurve = TimelineBezierCurve.linear;
    var leadingFrames = [...before];

    if (previous != null && next != null) {
      final spanUs = math.max(
        1,
        next.time.inMicroseconds - previous.time.inMicroseconds,
      );
      final progress = ((cutUs - previous.time.inMicroseconds) / spanUs)
          .clamp(0.0, 1.0)
          .toDouble();
      switch (previous.interpolation) {
        case TimelineKeyframeInterpolation.hold:
          boundaryValue = previous.value;
          boundaryInterpolation = TimelineKeyframeInterpolation.hold;
        case TimelineKeyframeInterpolation.linear:
          boundaryValue =
              previous.value + (next.value - previous.value) * progress;
          boundaryInterpolation = TimelineKeyframeInterpolation.linear;
        case TimelineKeyframeInterpolation.easeIn:
        case TimelineKeyframeInterpolation.easeOut:
        case TimelineKeyframeInterpolation.easeInOut:
        case TimelineKeyframeInterpolation.cubicBezier:
          final divided = _subdivide(previous.effectiveCurve, progress);
          boundaryValue =
              previous.value + (next.value - previous.value) * divided.y;
          boundaryInterpolation = TimelineKeyframeInterpolation.cubicBezier;
          boundaryCurve = divided.trailing;
          leadingFrames = [
            ...before.take(before.length - 1),
            previous.copyWith(
              interpolation: TimelineKeyframeInterpolation.cubicBezier,
              curve: divided.leading,
            ),
          ];
      }
    }

    final boundaryLeading = TimelineKeyframe(
      id: '${previous?.id ?? next?.id ?? frames.first.id}:cut:$cutUs:L',
      time: cut,
      property: frames.first.property,
      value: boundaryValue,
    );
    final boundaryTrailing = TimelineKeyframe(
      id: '${previous?.id ?? next?.id ?? frames.first.id}:cut:$cutUs:R',
      time: Duration.zero,
      property: frames.first.property,
      value: boundaryValue,
      interpolation: boundaryInterpolation,
      curve: boundaryCurve,
    );
    return (
      leading: [...leadingFrames, boundaryLeading],
      trailing: [
        boundaryTrailing,
        for (final frame in after)
          _clone(
            frame,
            time: frame.time - cut,
            regenerateId: regenerateTrailingIds,
          ),
      ],
    );
  }

  static TimelineKeyframe _clone(
    TimelineKeyframe frame, {
    required Duration time,
    required bool regenerateId,
  }) {
    // A split creates a second clip. Fresh IDs avoid ambiguous graph/editor
    // selection when both clips remain in the same project.
    return TimelineKeyframe(
      id: regenerateId ? null : frame.id,
      time: time,
      property: frame.property,
      value: frame.value,
      interpolation: frame.interpolation,
      curve: frame.curve,
    );
  }

  static _SubdividedCurve _subdivide(
    TimelineBezierCurve source,
    double xProgress,
  ) {
    final curve = source.normalized();
    final parameter = _parameterForX(curve, xProgress);
    const p0 = _CurvePoint(0, 0);
    final p1 = _CurvePoint(curve.x1, curve.y1);
    final p2 = _CurvePoint(curve.x2, curve.y2);
    const p3 = _CurvePoint(1, 1);
    final a = _CurvePoint.lerp(p0, p1, parameter);
    final b = _CurvePoint.lerp(p1, p2, parameter);
    final c = _CurvePoint.lerp(p2, p3, parameter);
    final d = _CurvePoint.lerp(a, b, parameter);
    final e = _CurvePoint.lerp(b, c, parameter);
    final point = _CurvePoint.lerp(d, e, parameter);

    final leading = TimelineBezierCurve(
      x1: _ratio(a.x, point.x),
      y1: _ratio(a.y, point.y),
      x2: _ratio(d.x, point.x),
      y2: _ratio(d.y, point.y),
    ).normalized();
    final trailing = TimelineBezierCurve(
      x1: _ratio(e.x - point.x, 1 - point.x),
      y1: _ratio(e.y - point.y, 1 - point.y),
      x2: _ratio(c.x - point.x, 1 - point.x),
      y2: _ratio(c.y - point.y, 1 - point.y),
    ).normalized();
    return _SubdividedCurve(leading: leading, trailing: trailing, y: point.y);
  }

  static double _parameterForX(TimelineBezierCurve curve, double xProgress) {
    final target = xProgress.clamp(0.0, 1.0).toDouble();
    var lower = 0.0;
    var upper = 1.0;
    var parameter = target;
    for (var iteration = 0; iteration < 32; iteration++) {
      final sampled = _sample(curve.x1, curve.x2, parameter);
      if ((sampled - target).abs() < 0.000000001) break;
      if (sampled < target) {
        lower = parameter;
      } else {
        upper = parameter;
      }
      parameter = (lower + upper) / 2;
    }
    return parameter;
  }

  static double _sample(double first, double second, double parameter) {
    final inverse = 1 - parameter;
    return 3 * inverse * inverse * parameter * first +
        3 * inverse * parameter * parameter * second +
        parameter * parameter * parameter;
  }

  static double _ratio(double numerator, double denominator) {
    if (denominator.abs() < 0.000000001) return 0;
    final value = numerator / denominator;
    return value.isFinite ? value : 0;
  }

  static int _compare(TimelineKeyframe a, TimelineKeyframe b) {
    final property = a.property.index.compareTo(b.property.index);
    return property != 0 ? property : a.time.compareTo(b.time);
  }

  static void _sort(List<TimelineKeyframe> frames) => frames.sort(_compare);
}

final class _SubdividedCurve {
  final TimelineBezierCurve leading;
  final TimelineBezierCurve trailing;
  final double y;

  const _SubdividedCurve({
    required this.leading,
    required this.trailing,
    required this.y,
  });
}

final class _CurvePoint {
  final double x;
  final double y;

  const _CurvePoint(this.x, this.y);

  factory _CurvePoint.lerp(
    _CurvePoint first,
    _CurvePoint second,
    double amount,
  ) {
    return _CurvePoint(
      first.x + (second.x - first.x) * amount,
      first.y + (second.y - first.y) * amount,
    );
  }
}
