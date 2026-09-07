import 'timeline_models.dart';

/// Motion recipes use ordinary keyframes, keeping preview, graph editing,
/// persistence and export on the same interpolation path.
enum ClipMotionPreset {
  gentlePush('Gentle push'),
  pullBack('Pull back'),
  float('Float'),
  punch('Punch'),
  rock('Rock'),
  sweep('Pan sweep');

  const ClipMotionPreset(this.label);
  final String label;

  TimelineClip apply(TimelineClip clip) {
    if (!clip.supportsTransformKeyframes || clip.duration.inMicroseconds <= 0) {
      return clip;
    }
    final property = switch (this) {
      gentlePush || pullBack || punch => TimelineKeyframeProperty.scale,
      float => TimelineKeyframeProperty.positionY,
      rock => TimelineKeyframeProperty.rotation,
      sweep => TimelineKeyframeProperty.positionX,
    };
    final base = switch (property) {
      TimelineKeyframeProperty.scale => clip.transform.scale,
      TimelineKeyframeProperty.positionY => clip.transform.offsetY,
      TimelineKeyframeProperty.rotation => clip.transform.rotation,
      _ => clip.transform.offsetX,
    };
    final samples = switch (this) {
      gentlePush => [(0.0, base), (1.0, base * 1.15)],
      pullBack => [(0.0, base * 1.15), (1.0, base)],
      float => [(0.0, base), (0.25, base - 24), (0.75, base + 24), (1.0, base)],
      punch => [
        (0.0, base * 0.8),
        (0.16, base * 1.12),
        (0.3, base * 0.97),
        (0.42, base),
        (1.0, base),
      ],
      rock => [
        (0.0, base),
        (0.25, base - 0.07),
        (0.75, base + 0.07),
        (1.0, base),
      ],
      sweep => [(0.0, base - 64), (1.0, base + 64)],
    };
    // Very short clips can quantize two samples to the same timestamp.
    final frames = <int, TimelineKeyframe>{};
    for (final sample in samples) {
      final time = (clip.duration.inMicroseconds * sample.$1).round();
      frames[time] = TimelineKeyframe(
        time: Duration(microseconds: time),
        property: property,
        value: property == TimelineKeyframeProperty.scale
            ? sample.$2.clamp(0.2, 4.0)
            : sample.$2,
        interpolation: TimelineKeyframeInterpolation.easeInOut,
        curve: TimelineBezierCurve.easeInOut,
      );
    }
    return clip.copyWith(
      keyframes: [
        ...clip.keyframes.where((frame) => frame.property != property),
        ...frames.values,
      ]..sort((a, b) => a.time.compareTo(b.time)),
    );
  }
}
