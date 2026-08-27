import 'timeline_models.dart';

/// A named outgoing timing curve shared by the dock and graph editor.
///
/// These presets intentionally use standard cubic-bezier families used by
/// professional motion tools. The final custom curve remains editable through
/// the graph handles and is stored directly on each keyframe segment.
class TimelineCurvePreset {
  final String id;
  final String label;
  final TimelineKeyframeInterpolation interpolation;
  final TimelineBezierCurve curve;

  const TimelineCurvePreset({
    required this.id,
    required this.label,
    required this.interpolation,
    required this.curve,
  });

  bool matches(TimelineKeyframe keyframe) {
    if (keyframe.interpolation != interpolation) return false;
    if (interpolation != TimelineKeyframeInterpolation.cubicBezier) {
      return true;
    }
    final effective = keyframe.curve.normalized();
    final target = curve.normalized();
    return (effective.x1 - target.x1).abs() < 0.0001 &&
        (effective.y1 - target.y1).abs() < 0.0001 &&
        (effective.x2 - target.x2).abs() < 0.0001 &&
        (effective.y2 - target.y2).abs() < 0.0001;
  }
}

/// Fifteen production-ready timing presets. Custom curves are provided as a
/// separate graph-editor mode so they never masquerade as a built-in preset.
const List<TimelineCurvePreset> timelineCurvePresets = [
  TimelineCurvePreset(
    id: 'hold',
    label: 'Hold',
    interpolation: TimelineKeyframeInterpolation.hold,
    curve: TimelineBezierCurve.linear,
  ),
  TimelineCurvePreset(
    id: 'linear',
    label: 'Linear',
    interpolation: TimelineKeyframeInterpolation.linear,
    curve: TimelineBezierCurve.linear,
  ),
  TimelineCurvePreset(
    id: 'easeIn',
    label: 'Ease in',
    interpolation: TimelineKeyframeInterpolation.easeIn,
    curve: TimelineBezierCurve.easeIn,
  ),
  TimelineCurvePreset(
    id: 'easeOut',
    label: 'Ease out',
    interpolation: TimelineKeyframeInterpolation.easeOut,
    curve: TimelineBezierCurve.easeOut,
  ),
  TimelineCurvePreset(
    id: 'easeInOut',
    label: 'Ease in/out',
    interpolation: TimelineKeyframeInterpolation.easeInOut,
    curve: TimelineBezierCurve.easeInOut,
  ),
  TimelineCurvePreset(
    id: 'sineIn',
    label: 'Sine in',
    interpolation: TimelineKeyframeInterpolation.cubicBezier,
    curve: TimelineBezierCurve(x1: 0.47, y1: 0, x2: 0.745, y2: 0.715),
  ),
  TimelineCurvePreset(
    id: 'sineOut',
    label: 'Sine out',
    interpolation: TimelineKeyframeInterpolation.cubicBezier,
    curve: TimelineBezierCurve(x1: 0.39, y1: 0.575, x2: 0.565, y2: 1),
  ),
  TimelineCurvePreset(
    id: 'sineInOut',
    label: 'Sine in/out',
    interpolation: TimelineKeyframeInterpolation.cubicBezier,
    curve: TimelineBezierCurve(x1: 0.445, y1: 0.05, x2: 0.55, y2: 0.95),
  ),
  TimelineCurvePreset(
    id: 'quadIn',
    label: 'Quad in',
    interpolation: TimelineKeyframeInterpolation.cubicBezier,
    curve: TimelineBezierCurve(x1: 0.55, y1: 0.085, x2: 0.68, y2: 0.53),
  ),
  TimelineCurvePreset(
    id: 'quadOut',
    label: 'Quad out',
    interpolation: TimelineKeyframeInterpolation.cubicBezier,
    curve: TimelineBezierCurve(x1: 0.25, y1: 0.46, x2: 0.45, y2: 0.94),
  ),
  TimelineCurvePreset(
    id: 'quadInOut',
    label: 'Quad in/out',
    interpolation: TimelineKeyframeInterpolation.cubicBezier,
    curve: TimelineBezierCurve(x1: 0.455, y1: 0.03, x2: 0.515, y2: 0.955),
  ),
  TimelineCurvePreset(
    id: 'cubicIn',
    label: 'Cubic in',
    interpolation: TimelineKeyframeInterpolation.cubicBezier,
    curve: TimelineBezierCurve(x1: 0.55, y1: 0.055, x2: 0.675, y2: 0.19),
  ),
  TimelineCurvePreset(
    id: 'cubicOut',
    label: 'Cubic out',
    interpolation: TimelineKeyframeInterpolation.cubicBezier,
    curve: TimelineBezierCurve(x1: 0.215, y1: 0.61, x2: 0.355, y2: 1),
  ),
  TimelineCurvePreset(
    id: 'cubicInOut',
    label: 'Cubic in/out',
    interpolation: TimelineKeyframeInterpolation.cubicBezier,
    curve: TimelineBezierCurve(x1: 0.645, y1: 0.045, x2: 0.355, y2: 1),
  ),
  TimelineCurvePreset(
    id: 'backOut',
    label: 'Back out',
    interpolation: TimelineKeyframeInterpolation.cubicBezier,
    curve: TimelineBezierCurve(x1: 0.175, y1: 0.885, x2: 0.32, y2: 1.275),
  ),
];
