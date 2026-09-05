import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'subtitle_entry.dart';
import 'subtitle_style_model.dart';
import 'word_timing.dart';
import 'editor_effect_models.dart';

/// Stable editor-space coordinates used by preview gestures and export.
///
/// Persisting transforms in a device-independent space keeps projects visually
/// identical on different phones, tablets, and output resolutions.
const double kTimelineDesignWidth = 390;
const double kTimelineDesignHeight = 360;

Map<String, dynamic>? _timelineJsonMap(Object? value) {
  if (value is! Map) return null;
  try {
    return Map<String, dynamic>.from(value);
  } catch (_) {
    return null;
  }
}

T _timelineModelFromJson<T>(
  Object? value,
  T Function(Map<String, dynamic>) parser,
  T fallback,
) {
  final map = _timelineJsonMap(value);
  if (map == null) return fallback;
  try {
    return parser(map);
  } catch (_) {
    return fallback;
  }
}

T? _timelineOptionalModelFromJson<T>(
  Object? value,
  T Function(Map<String, dynamic>) parser,
) {
  final map = _timelineJsonMap(value);
  if (map == null) return null;
  try {
    return parser(map);
  } catch (_) {
    return null;
  }
}

List<T> _timelineModelsFromJson<T>(
  Object? value,
  T Function(Map<String, dynamic>) parser,
) {
  if (value is! List) return const [];
  final models = <T>[];
  for (final candidate in value) {
    final map = _timelineJsonMap(candidate);
    if (map == null) continue;
    try {
      models.add(parser(map));
    } catch (_) {
      // Keep the rest of the timeline usable when one nested item is damaged.
    }
  }
  return models;
}

int _timelineInt(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

enum TimelineTrackType {
  video,
  audio,
  subtitle,
  text,
  image,
  sticker,
  gif,
  effect,
}

enum TimelineTrackSection { overlay, baseVideo, textSubtitle, audio }

/// Describes the structural responsibility of a timeline lane.
///
/// [sourceVideo] and [sourceAudio] are retained only so older project JSON
/// remains readable. New projects store the bottom visual lane as [regular]
/// and keep a video's embedded audio on the video clip unless the user
/// explicitly extracts it.
enum TimelineTrackRole { regular, sourceVideo, sourceAudio }

enum TimelineEffectKind { blur, filter }

enum EditorAssetType { video, audio, image, gif, sticker, unknown }

enum ClipFitMode { cover, contain, stretch }

enum ClipBlurMode { none, full, region }

enum ClipFilterPreset {
  original,
  cinematic,
  warm,
  cool,
  vivid,
  muted,
  monochrome,
  vintage,
}

enum AudioFadeShape { linear, logarithmic, exponential, sCurve }

enum PreviewMediaQuality { auto, proxy, original }

enum CanvasAspectRatioPreset {
  original,
  ratio16x9,
  ratio9x16,
  ratio1x1,
  ratio4x5,
}

enum TransitionType {
  none,
  cut,
  fade,
  dissolve,
  slideLeft,
  slideRight,
  slideUp,
  slideDown,
  zoom,
  zoomOut,
  pop,
  spin,
  slideUpLeft,
  slideUpRight,
}

enum TimelineMarkerType { marker, chapter, beat }

/// Independent magnetic targets available to timeline move/trim operations.
///
/// This is persisted as a set so adding a new target does not require another
/// top-level workspace boolean or a second snapping implementation in the UI.
enum TimelineSnapTarget {
  frames,
  playhead,
  clipEdges,
  markers,
  beats,
  keyframes,
  selectionBoundaries,
  workAreaBoundaries,
}

const Set<TimelineSnapTarget> kDefaultTimelineSnapTargets = {
  TimelineSnapTarget.frames,
  TimelineSnapTarget.playhead,
  TimelineSnapTarget.clipEdges,
  TimelineSnapTarget.markers,
  TimelineSnapTarget.beats,
  TimelineSnapTarget.keyframes,
  TimelineSnapTarget.selectionBoundaries,
  TimelineSnapTarget.workAreaBoundaries,
};

class TimelineSnapSettings {
  final bool enabled;
  final Set<TimelineSnapTarget> targets;

  const TimelineSnapSettings({
    this.enabled = true,
    this.targets = kDefaultTimelineSnapTargets,
  });

  bool includes(TimelineSnapTarget target) =>
      enabled && targets.contains(target);

  TimelineSnapSettings copyWith({
    bool? enabled,
    Set<TimelineSnapTarget>? targets,
  }) {
    return TimelineSnapSettings(
      enabled: enabled ?? this.enabled,
      targets: Set.unmodifiable(targets ?? this.targets),
    );
  }

  TimelineSnapSettings withTarget(
    TimelineSnapTarget target, {
    required bool enabled,
  }) {
    final next = {...targets};
    if (enabled) {
      next.add(target);
    } else {
      next.remove(target);
    }
    return copyWith(targets: next);
  }

  Map<String, dynamic> toJson() {
    final ordered = targets.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return {
      'enabled': enabled,
      'targets': ordered.map((target) => target.name).toList(),
    };
  }

  factory TimelineSnapSettings.fromJson(Map<String, dynamic> json) {
    final rawTargets = json['targets'];
    final parsedTargets = rawTargets is List
        ? rawTargets
              .whereType<String>()
              .map(
                (name) => TimelineSnapTarget.values
                    .where((target) => target.name == name)
                    .firstOrNull,
              )
              .whereType<TimelineSnapTarget>()
              .toSet()
        : kDefaultTimelineSnapTargets;
    return TimelineSnapSettings(
      enabled: json['enabled'] as bool? ?? true,
      targets: Set.unmodifiable(parsedTargets),
    );
  }
}

enum TimelineKeyframeProperty {
  opacity,
  scale,
  rotation,
  positionX,
  positionY,
  volume,
  blurStrength,
}

/// Transform channels captured together by the editor's state-keyframe flow.
/// Keeping this list canonical prevents preview gestures, the dock and export
/// from disagreeing about what constitutes a visual state.
const Set<TimelineKeyframeProperty> kTimelineTransformKeyframeProperties = {
  TimelineKeyframeProperty.opacity,
  TimelineKeyframeProperty.scale,
  TimelineKeyframeProperty.rotation,
  TimelineKeyframeProperty.positionX,
  TimelineKeyframeProperty.positionY,
};

/// Interpolation applied by a keyframe to the segment that follows it.
enum TimelineKeyframeInterpolation {
  hold,
  linear,
  easeIn,
  easeOut,
  easeInOut,
  cubicBezier,
}

/// Serializable cubic-bezier timing handles for a keyframe segment.
///
/// X coordinates are constrained to [0, 1] so time always moves forward. Y
/// coordinates deliberately allow overshoot, matching professional graph
/// editors where a value can pass its destination before settling.
@immutable
class TimelineBezierCurve {
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  const TimelineBezierCurve({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  static const linear = TimelineBezierCurve(x1: 0, y1: 0, x2: 1, y2: 1);
  static const easeIn = TimelineBezierCurve(x1: 0.42, y1: 0, x2: 1, y2: 1);
  static const easeOut = TimelineBezierCurve(x1: 0, y1: 0, x2: 0.58, y2: 1);
  static const easeInOut = TimelineBezierCurve(
    x1: 0.42,
    y1: 0,
    x2: 0.58,
    y2: 1,
  );

  TimelineBezierCurve normalized() {
    return TimelineBezierCurve(
      x1: x1.isFinite ? x1.clamp(0.0, 1.0).toDouble() : 0,
      y1: y1.isFinite ? y1.clamp(-4.0, 5.0).toDouble() : 0,
      x2: x2.isFinite ? x2.clamp(0.0, 1.0).toDouble() : 1,
      y2: y2.isFinite ? y2.clamp(-4.0, 5.0).toDouble() : 1,
    );
  }

  double transform(double progress) {
    final x = progress.clamp(0.0, 1.0).toDouble();
    if (x <= 0 || x >= 1) return x;
    final curve = normalized();

    double sample(double first, double second, double t) {
      final inverse = 1 - t;
      return 3 * inverse * inverse * t * first +
          3 * inverse * t * t * second +
          t * t * t;
    }

    double derivative(double first, double second, double t) {
      final inverse = 1 - t;
      return 3 * inverse * inverse * first +
          6 * inverse * t * (second - first) +
          3 * t * t * (1 - second);
    }

    var parameter = x;
    for (var iteration = 0; iteration < 8; iteration++) {
      final error = sample(curve.x1, curve.x2, parameter) - x;
      if (error.abs() < 0.000001) break;
      final slope = derivative(curve.x1, curve.x2, parameter);
      if (slope.abs() < 0.000001) break;
      parameter = (parameter - error / slope).clamp(0.0, 1.0).toDouble();
    }

    // Newton iteration can become unstable for nearly-flat handles. A short
    // bisection pass makes the evaluator deterministic for every valid curve.
    var lower = 0.0;
    var upper = 1.0;
    for (var iteration = 0; iteration < 12; iteration++) {
      final sampledX = sample(curve.x1, curve.x2, parameter);
      if ((sampledX - x).abs() < 0.000001) break;
      if (sampledX < x) {
        lower = parameter;
      } else {
        upper = parameter;
      }
      parameter = (lower + upper) / 2;
    }
    return sample(curve.y1, curve.y2, parameter);
  }

  Map<String, dynamic> toJson() => {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2};

  factory TimelineBezierCurve.fromJson(Map<String, dynamic> json) {
    return TimelineBezierCurve(
      x1: (json['x1'] as num?)?.toDouble() ?? 0,
      y1: (json['y1'] as num?)?.toDouble() ?? 0,
      x2: (json['x2'] as num?)?.toDouble() ?? 1,
      y2: (json['y2'] as num?)?.toDouble() ?? 1,
    ).normalized();
  }
}

/// A non-destructive value change stored relative to the start of a clip.
/// Keyframes are deliberately small and serializable so they remain safe for
/// older projects and can be interpolated by both preview and export paths.
class TimelineKeyframe {
  final String id;
  final Duration time;
  final TimelineKeyframeProperty property;
  final double value;
  final TimelineKeyframeInterpolation interpolation;
  final TimelineBezierCurve curve;

  TimelineKeyframe({
    String? id,
    required this.time,
    required this.property,
    required this.value,
    this.interpolation = TimelineKeyframeInterpolation.linear,
    this.curve = TimelineBezierCurve.linear,
  }) : id = id ?? const Uuid().v4();

  TimelineKeyframe copyWith({
    Duration? time,
    TimelineKeyframeProperty? property,
    double? value,
    TimelineKeyframeInterpolation? interpolation,
    TimelineBezierCurve? curve,
  }) {
    return TimelineKeyframe(
      id: id,
      time: time ?? this.time,
      property: property ?? this.property,
      value: value ?? this.value,
      interpolation: interpolation ?? this.interpolation,
      curve: curve ?? this.curve,
    );
  }

  TimelineBezierCurve get effectiveCurve => switch (interpolation) {
    TimelineKeyframeInterpolation.easeIn => TimelineBezierCurve.easeIn,
    TimelineKeyframeInterpolation.easeOut => TimelineBezierCurve.easeOut,
    TimelineKeyframeInterpolation.easeInOut => TimelineBezierCurve.easeInOut,
    TimelineKeyframeInterpolation.cubicBezier => curve,
    _ => TimelineBezierCurve.linear,
  };

  double transformProgress(double progress) {
    final normalized = progress.clamp(0.0, 1.0).toDouble();
    return switch (interpolation) {
      TimelineKeyframeInterpolation.hold => normalized >= 1 ? 1 : 0,
      TimelineKeyframeInterpolation.linear => normalized,
      _ => effectiveCurve.transform(normalized),
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'timeMs': time.inMilliseconds,
      'property': property.name,
      'value': value,
      'interpolation': interpolation.name,
      'curve': curve.toJson(),
    };
  }

  factory TimelineKeyframe.fromJson(Map<String, dynamic> json) {
    return TimelineKeyframe(
      id: json['id'] as String?,
      time: Duration(milliseconds: (json['timeMs'] as num?)?.toInt() ?? 0),
      property: TimelineKeyframeProperty.values.firstWhere(
        (candidate) => candidate.name == json['property'],
        orElse: () => TimelineKeyframeProperty.opacity,
      ),
      value: (json['value'] as num?)?.toDouble() ?? 0,
      interpolation: TimelineKeyframeInterpolation.values.firstWhere(
        (candidate) => candidate.name == json['interpolation'],
        orElse: () => TimelineKeyframeInterpolation.linear,
      ),
      curve: _timelineModelFromJson(
        json['curve'],
        TimelineBezierCurve.fromJson,
        TimelineBezierCurve.linear,
      ),
    );
  }
}

class TimelineWorkspaceSettings {
  final int frameRate;
  final bool loopPlayback;
  final bool showWaveforms;
  final bool showThumbnails;
  final bool showTimecode;
  final bool showKeyframes;
  final bool autoFollowPlayhead;
  final bool showClipLabels;
  final Duration? workAreaStart;
  final Duration? workAreaEnd;
  final TimelineSnapSettings snapping;
  final PreviewMediaQuality previewMediaQuality;

  const TimelineWorkspaceSettings({
    this.frameRate = 30,
    this.loopPlayback = false,
    this.showWaveforms = true,
    this.showThumbnails = true,
    this.showTimecode = true,
    this.showKeyframes = true,
    this.autoFollowPlayhead = false,
    this.showClipLabels = true,
    this.workAreaStart,
    this.workAreaEnd,
    this.snapping = const TimelineSnapSettings(),
    this.previewMediaQuality = PreviewMediaQuality.auto,
  });

  TimelineWorkspaceSettings copyWith({
    int? frameRate,
    bool? loopPlayback,
    bool? showWaveforms,
    bool? showThumbnails,
    bool? showTimecode,
    bool? showKeyframes,
    bool? autoFollowPlayhead,
    bool? showClipLabels,
    Duration? workAreaStart,
    Duration? workAreaEnd,
    TimelineSnapSettings? snapping,
    PreviewMediaQuality? previewMediaQuality,
    bool clearWorkAreaStart = false,
    bool clearWorkAreaEnd = false,
  }) {
    return TimelineWorkspaceSettings(
      frameRate: (frameRate ?? this.frameRate).clamp(1, 120),
      loopPlayback: loopPlayback ?? this.loopPlayback,
      showWaveforms: showWaveforms ?? this.showWaveforms,
      showThumbnails: showThumbnails ?? this.showThumbnails,
      showTimecode: showTimecode ?? this.showTimecode,
      showKeyframes: showKeyframes ?? this.showKeyframes,
      autoFollowPlayhead: autoFollowPlayhead ?? this.autoFollowPlayhead,
      showClipLabels: showClipLabels ?? this.showClipLabels,
      workAreaStart: clearWorkAreaStart
          ? null
          : (workAreaStart ?? this.workAreaStart),
      workAreaEnd: clearWorkAreaEnd ? null : (workAreaEnd ?? this.workAreaEnd),
      snapping: snapping ?? this.snapping,
      previewMediaQuality: previewMediaQuality ?? this.previewMediaQuality,
    );
  }

  /// Sets the work-area In marker and discards an older Out marker that no
  /// longer falls after it. This keeps partial I/O marking predictable while
  /// the user chooses the replacement boundary.
  TimelineWorkspaceSettings withWorkAreaStart(Duration position) {
    final shouldClearEnd = workAreaEnd != null && position >= workAreaEnd!;
    return copyWith(workAreaStart: position, clearWorkAreaEnd: shouldClearEnd);
  }

  /// Sets the work-area Out marker and discards an older In marker that no
  /// longer falls before it.
  TimelineWorkspaceSettings withWorkAreaEnd(Duration position) {
    final shouldClearStart =
        workAreaStart != null && position <= workAreaStart!;
    return copyWith(
      workAreaEnd: position,
      clearWorkAreaStart: shouldClearStart,
    );
  }

  Duration? get normalizedWorkAreaStart {
    final start = workAreaStart;
    final end = workAreaEnd;
    if (start == null || end == null || end <= start) return null;
    return start;
  }

  Duration? get normalizedWorkAreaEnd {
    final start = workAreaStart;
    final end = workAreaEnd;
    if (start == null || end == null || end <= start) return null;
    return end;
  }

  Map<String, dynamic> toJson() {
    return {
      'frameRate': frameRate,
      'loopPlayback': loopPlayback,
      'showWaveforms': showWaveforms,
      'showThumbnails': showThumbnails,
      'showTimecode': showTimecode,
      'showKeyframes': showKeyframes,
      'autoFollowPlayhead': autoFollowPlayhead,
      'showClipLabels': showClipLabels,
      'workAreaStartMs': normalizedWorkAreaStart?.inMilliseconds,
      'workAreaEndMs': normalizedWorkAreaEnd?.inMilliseconds,
      'snapping': snapping.toJson(),
      'previewMediaQuality': previewMediaQuality.name,
    };
  }

  factory TimelineWorkspaceSettings.fromJson(Map<String, dynamic> json) {
    return TimelineWorkspaceSettings(
      frameRate: _timelineInt(json['frameRate'], fallback: 30).clamp(1, 120),
      loopPlayback: json['loopPlayback'] as bool? ?? false,
      showWaveforms: json['showWaveforms'] as bool? ?? true,
      showThumbnails: json['showThumbnails'] as bool? ?? true,
      showTimecode: json['showTimecode'] as bool? ?? true,
      showKeyframes: json['showKeyframes'] as bool? ?? true,
      autoFollowPlayhead: json['autoFollowPlayhead'] as bool? ?? false,
      showClipLabels: json['showClipLabels'] as bool? ?? true,
      workAreaStart: (json['workAreaStartMs'] as num?) == null
          ? null
          : Duration(milliseconds: (json['workAreaStartMs'] as num).toInt()),
      workAreaEnd: (json['workAreaEndMs'] as num?) == null
          ? null
          : Duration(milliseconds: (json['workAreaEndMs'] as num).toInt()),
      snapping: _timelineModelFromJson(
        json['snapping'],
        TimelineSnapSettings.fromJson,
        const TimelineSnapSettings(),
      ),
      previewMediaQuality: PreviewMediaQuality.values.firstWhere(
        (quality) => quality.name == json['previewMediaQuality'],
        orElse: () => PreviewMediaQuality.auto,
      ),
    );
  }
}

/// Capability flags shared by the editor, timeline and render paths.
///
/// Keeping these rules beside the timeline model prevents a selected track from
/// accidentally accepting an unrelated clip (for example, text on a subtitle
/// lane or an image on an effect lane).
extension TimelineTrackTypeCapabilities on TimelineTrackType {
  bool get isVisualMedia {
    return this == TimelineTrackType.video ||
        this == TimelineTrackType.image ||
        this == TimelineTrackType.gif ||
        this == TimelineTrackType.sticker;
  }

  bool get isTextContent {
    return this == TimelineTrackType.text || this == TimelineTrackType.subtitle;
  }

  bool get supportsSourceTiming {
    return this == TimelineTrackType.video ||
        this == TimelineTrackType.audio ||
        this == TimelineTrackType.gif;
  }

  /// Reverse preview needs a visual stream because the current media backend
  /// cannot play audio backward in real time.
  bool get supportsReversePlayback {
    return this == TimelineTrackType.video || this == TimelineTrackType.gif;
  }

  bool get supportsVisualEffects =>
      isVisualMedia || this == TimelineTrackType.effect;

  bool get supportsTransform {
    return isVisualMedia ||
        this == TimelineTrackType.text ||
        this == TimelineTrackType.effect;
  }

  bool get supportsTransformKeyframes => isVisualMedia;

  /// Generic clip transitions are rendered by the visual-media pipeline.
  /// Text uses its dedicated subtitle/text animation presets instead.
  bool get supportsClipAnimation => isVisualMedia;

  bool get canCarryAudio {
    return this == TimelineTrackType.video || this == TimelineTrackType.audio;
  }
}

/// A non-destructive crop stored as normalized source-space insets.
///
/// The same model is used for Base-layer media and every visual overlay type,
/// keeps crop behavior portable across preview, persistence, and export.
class ClipCropSettings {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const ClipCropSettings({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  double get safeLeft => left.clamp(0.0, 0.94).toDouble();
  double get safeTop => top.clamp(0.0, 0.94).toDouble();
  double get safeRight =>
      right.clamp(0.0, math.max(0.0, 0.95 - safeLeft)).toDouble();
  double get safeBottom =>
      bottom.clamp(0.0, math.max(0.0, 0.95 - safeTop)).toDouble();
  double get visibleWidth => math.max(0.05, 1 - safeLeft - safeRight);
  double get visibleHeight => math.max(0.05, 1 - safeTop - safeBottom);

  bool get isIdentity =>
      safeLeft < 0.0001 &&
      safeTop < 0.0001 &&
      safeRight < 0.0001 &&
      safeBottom < 0.0001;

  ClipCropSettings copyWith({
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) {
    return ClipCropSettings(
      left: left ?? this.left,
      top: top ?? this.top,
      right: right ?? this.right,
      bottom: bottom ?? this.bottom,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'left': safeLeft,
      'top': safeTop,
      'right': safeRight,
      'bottom': safeBottom,
    };
  }

  factory ClipCropSettings.fromJson(Map<String, dynamic> json) {
    return ClipCropSettings(
      left: (json['left'] as num?)?.toDouble() ?? 0,
      top: (json['top'] as num?)?.toDouble() ?? 0,
      right: (json['right'] as num?)?.toDouble() ?? 0,
      bottom: (json['bottom'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Reusable privacy/effect blur settings for any visual timeline clip.
class ClipBlurSettings {
  final ClipBlurMode mode;
  final double strength;
  final double regionX;
  final double regionY;
  final double regionWidth;
  final double regionHeight;

  const ClipBlurSettings({
    this.mode = ClipBlurMode.none,
    this.strength = 12,
    this.regionX = 0.25,
    this.regionY = 0.25,
    this.regionWidth = 0.5,
    this.regionHeight = 0.35,
  });

  double get safeStrength => strength.clamp(0.0, 30.0).toDouble();
  double get safeRegionWidth => regionWidth.clamp(0.08, 1.0).toDouble();
  double get safeRegionHeight => regionHeight.clamp(0.08, 1.0).toDouble();
  double get safeRegionX => regionX.clamp(0.0, 1 - safeRegionWidth).toDouble();
  double get safeRegionY => regionY.clamp(0.0, 1 - safeRegionHeight).toDouble();
  bool get isEnabled => mode != ClipBlurMode.none && safeStrength > 0.01;

  ClipBlurSettings copyWith({
    ClipBlurMode? mode,
    double? strength,
    double? regionX,
    double? regionY,
    double? regionWidth,
    double? regionHeight,
  }) {
    return ClipBlurSettings(
      mode: mode ?? this.mode,
      strength: strength ?? this.strength,
      regionX: regionX ?? this.regionX,
      regionY: regionY ?? this.regionY,
      regionWidth: regionWidth ?? this.regionWidth,
      regionHeight: regionHeight ?? this.regionHeight,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.name,
      'strength': safeStrength,
      'regionX': safeRegionX,
      'regionY': safeRegionY,
      'regionWidth': safeRegionWidth,
      'regionHeight': safeRegionHeight,
    };
  }

  factory ClipBlurSettings.fromJson(Map<String, dynamic> json) {
    return ClipBlurSettings(
      mode: ClipBlurMode.values.firstWhere(
        (value) => value.name == json['mode'],
        orElse: () => ClipBlurMode.none,
      ),
      strength: (json['strength'] as num?)?.toDouble() ?? 12,
      regionX: (json['regionX'] as num?)?.toDouble() ?? 0.25,
      regionY: (json['regionY'] as num?)?.toDouble() ?? 0.25,
      regionWidth: (json['regionWidth'] as num?)?.toDouble() ?? 0.5,
      regionHeight: (json['regionHeight'] as num?)?.toDouble() ?? 0.35,
    );
  }
}

class ClipColorAdjustments {
  final double exposure;
  final double brightness;
  final double contrast;
  final double highlights;
  final double shadows;
  final double whites;
  final double blacks;
  final double saturation;
  final double vibrance;
  final double temperature;
  final double tint;
  final double gamma;
  final double hue;
  final double redGain;
  final double greenGain;
  final double blueGain;
  final double fade;
  final double vignette;
  final double sharpen;
  final EditorColorCurve rgbCurve;
  final EditorColorCurve hueVsHueCurve;
  final EditorColorCurve hueVsSaturationCurve;
  final EditorColorCurve hueVsLuminanceCurve;
  final EditorColorCurve luminanceVsSaturationCurve;
  final EditorColorCurve saturationVsSaturationCurve;
  final EditorColorWheels wheels;
  final EditorColorQualifier qualifier;
  final String? lutPath;
  final double lutIntensity;
  final EditorColorSpace inputColorSpace;

  const ClipColorAdjustments({
    this.exposure = 0,
    this.brightness = 0,
    this.contrast = 1,
    this.highlights = 0,
    this.shadows = 0,
    this.whites = 0,
    this.blacks = 0,
    this.saturation = 1,
    this.vibrance = 0,
    this.temperature = 0,
    this.tint = 0,
    this.gamma = 1,
    this.hue = 0,
    this.redGain = 1,
    this.greenGain = 1,
    this.blueGain = 1,
    this.fade = 0,
    this.vignette = 0,
    this.sharpen = 0,
    this.rgbCurve = const EditorColorCurve(),
    this.hueVsHueCurve = const EditorColorCurve(),
    this.hueVsSaturationCurve = const EditorColorCurve(),
    this.hueVsLuminanceCurve = const EditorColorCurve(),
    this.luminanceVsSaturationCurve = const EditorColorCurve(),
    this.saturationVsSaturationCurve = const EditorColorCurve(),
    this.wheels = const EditorColorWheels(),
    this.qualifier = const EditorColorQualifier(),
    this.lutPath,
    this.lutIntensity = 1,
    this.inputColorSpace = EditorColorSpace.automatic,
  });

  bool get isNeutral =>
      exposure == 0 &&
      brightness == 0 &&
      contrast == 1 &&
      highlights == 0 &&
      shadows == 0 &&
      whites == 0 &&
      blacks == 0 &&
      saturation == 1 &&
      vibrance == 0 &&
      temperature == 0 &&
      tint == 0 &&
      gamma == 1 &&
      hue == 0 &&
      redGain == 1 &&
      greenGain == 1 &&
      blueGain == 1 &&
      fade == 0 &&
      vignette == 0 &&
      sharpen == 0 &&
      rgbCurve.isIdentity &&
      hueVsHueCurve.isIdentity &&
      hueVsSaturationCurve.isIdentity &&
      hueVsLuminanceCurve.isIdentity &&
      luminanceVsSaturationCurve.isIdentity &&
      saturationVsSaturationCurve.isIdentity &&
      wheels.isIdentity &&
      !qualifier.enabled &&
      (lutPath == null || lutPath!.trim().isEmpty || lutIntensity <= 0) &&
      inputColorSpace == EditorColorSpace.automatic;

  ClipColorAdjustments copyWith({
    double? exposure,
    double? brightness,
    double? contrast,
    double? highlights,
    double? shadows,
    double? whites,
    double? blacks,
    double? saturation,
    double? vibrance,
    double? temperature,
    double? tint,
    double? gamma,
    double? hue,
    double? redGain,
    double? greenGain,
    double? blueGain,
    double? fade,
    double? vignette,
    double? sharpen,
    EditorColorCurve? rgbCurve,
    EditorColorCurve? hueVsHueCurve,
    EditorColorCurve? hueVsSaturationCurve,
    EditorColorCurve? hueVsLuminanceCurve,
    EditorColorCurve? luminanceVsSaturationCurve,
    EditorColorCurve? saturationVsSaturationCurve,
    EditorColorWheels? wheels,
    EditorColorQualifier? qualifier,
    String? lutPath,
    bool clearLutPath = false,
    double? lutIntensity,
    EditorColorSpace? inputColorSpace,
  }) {
    return ClipColorAdjustments(
      exposure: exposure ?? this.exposure,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      highlights: highlights ?? this.highlights,
      shadows: shadows ?? this.shadows,
      whites: whites ?? this.whites,
      blacks: blacks ?? this.blacks,
      saturation: saturation ?? this.saturation,
      vibrance: vibrance ?? this.vibrance,
      temperature: temperature ?? this.temperature,
      tint: tint ?? this.tint,
      gamma: gamma ?? this.gamma,
      hue: hue ?? this.hue,
      redGain: redGain ?? this.redGain,
      greenGain: greenGain ?? this.greenGain,
      blueGain: blueGain ?? this.blueGain,
      fade: fade ?? this.fade,
      vignette: vignette ?? this.vignette,
      sharpen: sharpen ?? this.sharpen,
      rgbCurve: rgbCurve ?? this.rgbCurve,
      hueVsHueCurve: hueVsHueCurve ?? this.hueVsHueCurve,
      hueVsSaturationCurve: hueVsSaturationCurve ?? this.hueVsSaturationCurve,
      hueVsLuminanceCurve: hueVsLuminanceCurve ?? this.hueVsLuminanceCurve,
      luminanceVsSaturationCurve:
          luminanceVsSaturationCurve ?? this.luminanceVsSaturationCurve,
      saturationVsSaturationCurve:
          saturationVsSaturationCurve ?? this.saturationVsSaturationCurve,
      wheels: wheels ?? this.wheels,
      qualifier: qualifier ?? this.qualifier,
      lutPath: clearLutPath ? null : (lutPath ?? this.lutPath),
      lutIntensity: lutIntensity ?? this.lutIntensity,
      inputColorSpace: inputColorSpace ?? this.inputColorSpace,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'exposure': exposure,
      'brightness': brightness,
      'contrast': contrast,
      'highlights': highlights,
      'shadows': shadows,
      'whites': whites,
      'blacks': blacks,
      'saturation': saturation,
      'vibrance': vibrance,
      'temperature': temperature,
      'tint': tint,
      'gamma': gamma,
      'hue': hue,
      'redGain': redGain,
      'greenGain': greenGain,
      'blueGain': blueGain,
      'fade': fade,
      'vignette': vignette,
      'sharpen': sharpen,
      'rgbCurve': rgbCurve.toJson(),
      'hueVsHueCurve': hueVsHueCurve.toJson(),
      'hueVsSaturationCurve': hueVsSaturationCurve.toJson(),
      'hueVsLuminanceCurve': hueVsLuminanceCurve.toJson(),
      'luminanceVsSaturationCurve': luminanceVsSaturationCurve.toJson(),
      'saturationVsSaturationCurve': saturationVsSaturationCurve.toJson(),
      'wheels': wheels.toJson(),
      'qualifier': qualifier.toJson(),
      'lutPath': lutPath,
      'lutIntensity': lutIntensity.clamp(0.0, 1.0),
      'inputColorSpace': inputColorSpace.name,
    };
  }

  factory ClipColorAdjustments.fromJson(Map<String, dynamic> json) {
    return ClipColorAdjustments(
      exposure: (json['exposure'] as num?)?.toDouble() ?? 0,
      brightness: (json['brightness'] as num?)?.toDouble() ?? 0,
      contrast: (json['contrast'] as num?)?.toDouble() ?? 1,
      highlights: (json['highlights'] as num?)?.toDouble() ?? 0,
      shadows: (json['shadows'] as num?)?.toDouble() ?? 0,
      whites: (json['whites'] as num?)?.toDouble() ?? 0,
      blacks: (json['blacks'] as num?)?.toDouble() ?? 0,
      saturation: (json['saturation'] as num?)?.toDouble() ?? 1,
      vibrance: (json['vibrance'] as num?)?.toDouble() ?? 0,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0,
      tint: (json['tint'] as num?)?.toDouble() ?? 0,
      gamma: (json['gamma'] as num?)?.toDouble() ?? 1,
      hue: (json['hue'] as num?)?.toDouble() ?? 0,
      redGain: (json['redGain'] as num?)?.toDouble() ?? 1,
      greenGain: (json['greenGain'] as num?)?.toDouble() ?? 1,
      blueGain: (json['blueGain'] as num?)?.toDouble() ?? 1,
      fade: (json['fade'] as num?)?.toDouble() ?? 0,
      vignette: (json['vignette'] as num?)?.toDouble() ?? 0,
      sharpen: (json['sharpen'] as num?)?.toDouble() ?? 0,
      rgbCurve: EditorColorCurve.fromJson(json['rgbCurve']),
      hueVsHueCurve: EditorColorCurve.fromJson(json['hueVsHueCurve']),
      hueVsSaturationCurve: EditorColorCurve.fromJson(
        json['hueVsSaturationCurve'],
      ),
      hueVsLuminanceCurve: EditorColorCurve.fromJson(
        json['hueVsLuminanceCurve'],
      ),
      luminanceVsSaturationCurve: EditorColorCurve.fromJson(
        json['luminanceVsSaturationCurve'],
      ),
      saturationVsSaturationCurve: EditorColorCurve.fromJson(
        json['saturationVsSaturationCurve'],
      ),
      wheels: EditorColorWheels.fromJson(json['wheels']),
      qualifier: EditorColorQualifier.fromJson(json['qualifier']),
      lutPath: json['lutPath'] as String?,
      lutIntensity: ((json['lutIntensity'] as num?)?.toDouble() ?? 1)
          .clamp(0.0, 1.0)
          .toDouble(),
      inputColorSpace: EditorColorSpace.values.firstWhere(
        (space) => space.name == json['inputColorSpace'],
        orElse: () => EditorColorSpace.automatic,
      ),
    );
  }

  factory ClipColorAdjustments.forPreset(ClipFilterPreset preset) {
    switch (preset) {
      case ClipFilterPreset.original:
        return const ClipColorAdjustments();
      case ClipFilterPreset.cinematic:
        return const ClipColorAdjustments(
          contrast: 1.12,
          saturation: 0.88,
          temperature: -0.08,
          vignette: 0.24,
          sharpen: 0.12,
        );
      case ClipFilterPreset.warm:
        return const ClipColorAdjustments(
          brightness: 0.03,
          contrast: 1.04,
          saturation: 1.08,
          temperature: 0.28,
        );
      case ClipFilterPreset.cool:
        return const ClipColorAdjustments(
          contrast: 1.06,
          saturation: 0.96,
          temperature: -0.3,
        );
      case ClipFilterPreset.vivid:
        return const ClipColorAdjustments(
          contrast: 1.14,
          saturation: 1.34,
          sharpen: 0.2,
        );
      case ClipFilterPreset.muted:
        return const ClipColorAdjustments(
          brightness: 0.04,
          contrast: 0.92,
          saturation: 0.66,
          fade: 0.12,
        );
      case ClipFilterPreset.monochrome:
        return const ClipColorAdjustments(
          contrast: 1.12,
          saturation: 0,
          vignette: 0.12,
        );
      case ClipFilterPreset.vintage:
        return const ClipColorAdjustments(
          brightness: 0.04,
          contrast: 0.9,
          saturation: 0.76,
          temperature: 0.22,
          fade: 0.2,
          vignette: 0.3,
        );
    }
  }
}

class TimelineTransform {
  final double offsetX;
  final double offsetY;
  final double scale;
  final double rotation;
  final double opacity;
  final bool flipX;
  final bool flipY;

  const TimelineTransform({
    this.offsetX = 0,
    this.offsetY = 0,
    this.scale = 1,
    this.rotation = 0,
    this.opacity = 1,
    this.flipX = false,
    this.flipY = false,
  });

  bool get isIdentity =>
      offsetX.abs() < 0.0001 &&
      offsetY.abs() < 0.0001 &&
      (scale - 1).abs() < 0.0001 &&
      rotation.abs() < 0.0001 &&
      (opacity - 1).abs() < 0.0001 &&
      !flipX &&
      !flipY;

  TimelineTransform copyWith({
    double? offsetX,
    double? offsetY,
    double? scale,
    double? rotation,
    double? opacity,
    bool? flipX,
    bool? flipY,
  }) {
    return TimelineTransform(
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
      opacity: opacity ?? this.opacity,
      flipX: flipX ?? this.flipX,
      flipY: flipY ?? this.flipY,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'offsetX': offsetX,
      'offsetY': offsetY,
      'scale': scale,
      'rotation': rotation,
      'opacity': opacity,
      'flipX': flipX,
      'flipY': flipY,
    };
  }

  factory TimelineTransform.fromJson(Map<String, dynamic> json) {
    return TimelineTransform(
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? 0,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? 0,
      scale: (json['scale'] as num?)?.toDouble() ?? 1,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1,
      flipX: json['flipX'] as bool? ?? false,
      flipY: json['flipY'] as bool? ?? false,
    );
  }
}

class AudioMixSettings {
  final double volume;
  final bool muted;
  final int fadeInMs;
  final int fadeOutMs;
  final double pan;
  final bool normalize;
  final AudioFadeShape fadeInShape;
  final AudioFadeShape fadeOutShape;
  final EditorAudioChannelMode channelMode;
  final int sourceStreamIndex;
  final int sourceLeftChannel;
  final int sourceRightChannel;
  final double leftGain;
  final double rightGain;
  final double targetLufs;
  final double peakLimitDb;
  final double pitchSemitones;
  final double timeStretch;
  final bool preservePitch;
  final AudioLoudnessAnalysis? loudnessAnalysis;

  const AudioMixSettings({
    this.volume = 1,
    this.muted = false,
    this.fadeInMs = 0,
    this.fadeOutMs = 0,
    this.pan = 0,
    this.normalize = false,
    this.fadeInShape = AudioFadeShape.linear,
    this.fadeOutShape = AudioFadeShape.linear,
    this.channelMode = EditorAudioChannelMode.stereo,
    this.sourceStreamIndex = 0,
    this.sourceLeftChannel = 0,
    this.sourceRightChannel = 1,
    this.leftGain = 1,
    this.rightGain = 1,
    this.targetLufs = -16,
    this.peakLimitDb = -1.5,
    this.pitchSemitones = 0,
    this.timeStretch = 1,
    this.preservePitch = true,
    this.loudnessAnalysis,
  });

  bool get hasMixAdjustment =>
      (volume - 1).abs() > 0.0001 ||
      pan.abs() > 0.0001 ||
      normalize ||
      muted ||
      fadeInMs > 0 ||
      fadeOutMs > 0 ||
      channelMode != EditorAudioChannelMode.stereo ||
      sourceStreamIndex != 0 ||
      sourceLeftChannel != 0 ||
      sourceRightChannel != 1 ||
      (leftGain - 1).abs() > 0.0001 ||
      (rightGain - 1).abs() > 0.0001 ||
      (targetLufs + 16).abs() > 0.0001 ||
      (peakLimitDb + 1.5).abs() > 0.0001 ||
      pitchSemitones.abs() > 0.0001 ||
      (timeStretch - 1).abs() > 0.0001;

  AudioMixSettings copyWith({
    double? volume,
    bool? muted,
    int? fadeInMs,
    int? fadeOutMs,
    double? pan,
    bool? normalize,
    AudioFadeShape? fadeInShape,
    AudioFadeShape? fadeOutShape,
    EditorAudioChannelMode? channelMode,
    int? sourceStreamIndex,
    int? sourceLeftChannel,
    int? sourceRightChannel,
    double? leftGain,
    double? rightGain,
    double? targetLufs,
    double? peakLimitDb,
    double? pitchSemitones,
    double? timeStretch,
    bool? preservePitch,
    AudioLoudnessAnalysis? loudnessAnalysis,
    bool clearLoudnessAnalysis = false,
  }) {
    return AudioMixSettings(
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
      fadeInMs: fadeInMs ?? this.fadeInMs,
      fadeOutMs: fadeOutMs ?? this.fadeOutMs,
      pan: pan ?? this.pan,
      normalize: normalize ?? this.normalize,
      fadeInShape: fadeInShape ?? this.fadeInShape,
      fadeOutShape: fadeOutShape ?? this.fadeOutShape,
      channelMode: channelMode ?? this.channelMode,
      sourceStreamIndex: sourceStreamIndex ?? this.sourceStreamIndex,
      sourceLeftChannel: sourceLeftChannel ?? this.sourceLeftChannel,
      sourceRightChannel: sourceRightChannel ?? this.sourceRightChannel,
      leftGain: leftGain ?? this.leftGain,
      rightGain: rightGain ?? this.rightGain,
      targetLufs: targetLufs ?? this.targetLufs,
      peakLimitDb: peakLimitDb ?? this.peakLimitDb,
      pitchSemitones: pitchSemitones ?? this.pitchSemitones,
      timeStretch: timeStretch ?? this.timeStretch,
      preservePitch: preservePitch ?? this.preservePitch,
      loudnessAnalysis: clearLoudnessAnalysis
          ? null
          : (loudnessAnalysis ?? this.loudnessAnalysis),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'volume': volume,
      'muted': muted,
      'fadeInMs': fadeInMs,
      'fadeOutMs': fadeOutMs,
      'pan': pan,
      'normalize': normalize,
      'fadeInShape': fadeInShape.name,
      'fadeOutShape': fadeOutShape.name,
      'channelMode': channelMode.name,
      'sourceStreamIndex': sourceStreamIndex.clamp(0, 31),
      'sourceLeftChannel': sourceLeftChannel.clamp(0, 63),
      'sourceRightChannel': sourceRightChannel.clamp(0, 63),
      'leftGain': leftGain.clamp(0.0, 2.0),
      'rightGain': rightGain.clamp(0.0, 2.0),
      'targetLufs': targetLufs.clamp(-60.0, 0.0),
      'peakLimitDb': peakLimitDb.clamp(-24.0, 0.0),
      'pitchSemitones': pitchSemitones.clamp(-24.0, 24.0),
      'timeStretch': timeStretch.clamp(0.25, 4.0),
      'preservePitch': preservePitch,
      'loudnessAnalysis': loudnessAnalysis?.toJson(),
    };
  }

  factory AudioMixSettings.fromJson(Map<String, dynamic> json) {
    return AudioMixSettings(
      volume: (json['volume'] as num?)?.toDouble() ?? 1,
      muted: json['muted'] as bool? ?? false,
      fadeInMs: (json['fadeInMs'] as num?)?.toInt() ?? 0,
      fadeOutMs: (json['fadeOutMs'] as num?)?.toInt() ?? 0,
      pan: (json['pan'] as num?)?.toDouble() ?? 0,
      normalize: json['normalize'] as bool? ?? false,
      fadeInShape: AudioFadeShape.values.firstWhere(
        (shape) => shape.name == json['fadeInShape'],
        orElse: () => AudioFadeShape.linear,
      ),
      fadeOutShape: AudioFadeShape.values.firstWhere(
        (shape) => shape.name == json['fadeOutShape'],
        orElse: () => AudioFadeShape.linear,
      ),
      channelMode: EditorAudioChannelMode.values.firstWhere(
        (mode) => mode.name == json['channelMode'],
        orElse: () => EditorAudioChannelMode.stereo,
      ),
      sourceStreamIndex: _timelineInt(
        json['sourceStreamIndex'],
      ).clamp(0, 31).toInt(),
      sourceLeftChannel: _timelineInt(
        json['sourceLeftChannel'],
      ).clamp(0, 63).toInt(),
      sourceRightChannel: _timelineInt(
        json['sourceRightChannel'],
        fallback: 1,
      ).clamp(0, 63).toInt(),
      leftGain: ((json['leftGain'] as num?)?.toDouble() ?? 1)
          .clamp(0.0, 2.0)
          .toDouble(),
      rightGain: ((json['rightGain'] as num?)?.toDouble() ?? 1)
          .clamp(0.0, 2.0)
          .toDouble(),
      targetLufs: ((json['targetLufs'] as num?)?.toDouble() ?? -16)
          .clamp(-60.0, 0.0)
          .toDouble(),
      peakLimitDb: ((json['peakLimitDb'] as num?)?.toDouble() ?? -1.5)
          .clamp(-24.0, 0.0)
          .toDouble(),
      pitchSemitones: ((json['pitchSemitones'] as num?)?.toDouble() ?? 0)
          .clamp(-24.0, 24.0)
          .toDouble(),
      timeStretch: ((json['timeStretch'] as num?)?.toDouble() ?? 1)
          .clamp(0.25, 4.0)
          .toDouble(),
      preservePitch: json['preservePitch'] as bool? ?? true,
      loudnessAnalysis: json['loudnessAnalysis'] is Map
          ? AudioLoudnessAnalysis.fromJson(json['loudnessAnalysis'])
          : null,
    );
  }
}

class ClipTransition {
  final TransitionType type;
  final int durationMs;

  const ClipTransition({this.type = TransitionType.none, this.durationMs = 0});

  ClipTransition copyWith({TransitionType? type, int? durationMs}) {
    return ClipTransition(
      type: type ?? this.type,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  Map<String, dynamic> toJson() {
    return {'type': type.name, 'durationMs': durationMs};
  }

  factory ClipTransition.fromJson(Map<String, dynamic> json) {
    return ClipTransition(
      type: TransitionType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => TransitionType.none,
      ),
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class EditorAssetReference {
  final String id;
  final EditorAssetType type;
  final String label;
  final String? sourcePath;
  final String? remoteUrl;
  final bool isNetworkBacked;
  final Map<String, dynamic> metadata;

  EditorAssetReference({
    String? id,
    required this.type,
    required this.label,
    this.sourcePath,
    this.remoteUrl,
    this.isNetworkBacked = false,
    Map<String, dynamic>? metadata,
  }) : id = id ?? const Uuid().v4(),
       metadata = metadata ?? const {};

  EditorAssetReference copyWith({
    EditorAssetType? type,
    String? label,
    String? sourcePath,
    String? remoteUrl,
    bool? isNetworkBacked,
    Map<String, dynamic>? metadata,
    bool clearSourcePath = false,
    bool clearRemoteUrl = false,
  }) {
    return EditorAssetReference(
      id: id,
      type: type ?? this.type,
      label: label ?? this.label,
      sourcePath: clearSourcePath ? null : (sourcePath ?? this.sourcePath),
      remoteUrl: clearRemoteUrl ? null : (remoteUrl ?? this.remoteUrl),
      isNetworkBacked: isNetworkBacked ?? this.isNetworkBacked,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'label': label,
      'sourcePath': sourcePath,
      'remoteUrl': remoteUrl,
      'isNetworkBacked': isNetworkBacked,
      'metadata': metadata,
    };
  }

  factory EditorAssetReference.fromJson(Map<String, dynamic> json) {
    return EditorAssetReference(
      id: json['id'] as String?,
      type: EditorAssetType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => EditorAssetType.unknown,
      ),
      label: json['label'] as String? ?? 'Untitled asset',
      sourcePath: json['sourcePath'] as String?,
      remoteUrl: json['remoteUrl'] as String?,
      isNetworkBacked: json['isNetworkBacked'] as bool? ?? false,
      metadata: _timelineJsonMap(json['metadata']) ?? const {},
    );
  }
}

class TimelineMarker {
  final String id;
  final Duration position;
  final String label;
  final TimelineMarkerType type;
  final Color color;

  TimelineMarker({
    String? id,
    required this.position,
    required this.label,
    this.type = TimelineMarkerType.marker,
    this.color = const Color(0xFFFF9A62),
  }) : id = id ?? const Uuid().v4();

  TimelineMarker copyWith({
    Duration? position,
    String? label,
    TimelineMarkerType? type,
    Color? color,
  }) {
    return TimelineMarker(
      id: id,
      position: position ?? this.position,
      label: label ?? this.label,
      type: type ?? this.type,
      color: color ?? this.color,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'positionMs': position.inMilliseconds,
      'label': label,
      'type': type.name,
      'color': _colorToInt(color),
    };
  }

  factory TimelineMarker.fromJson(Map<String, dynamic> json) {
    return TimelineMarker(
      id: json['id'] as String?,
      position: Duration(milliseconds: _timelineInt(json['positionMs'])),
      label: json['label'] as String? ?? 'Marker',
      type: TimelineMarkerType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => TimelineMarkerType.marker,
      ),
      color: Color(_timelineInt(json['color'], fallback: 0xFFFF9A62)),
    );
  }
}

class TimelineClip {
  final String id;
  final String trackId;
  final TimelineTrackType type;
  final TimelineEffectKind? effectKind;
  final EditorEffectStack effectStack;
  final bool isAdjustmentLayer;
  final String? groupId;
  final String? compoundId;
  final String label;
  final String? assetId;
  final String? linkedClipId;
  final String? separatedFromClipId;
  final bool embeddedAudioSeparated;
  final Duration startTime;
  final Duration endTime;
  final Duration sourceStartTime;
  final Duration sourceDuration;
  final int layer;
  final bool enabled;
  final TimelineTransform transform;
  final AudioMixSettings audioMix;
  final ClipFitMode fitMode;
  final double playbackRate;
  final bool isReversed;
  final ClipCropSettings crop;
  final ClipBlurSettings blur;
  final ClipColorAdjustments colorAdjustments;
  final String? text;
  final SubtitleStyleModel? subtitleStyle;
  final ClipTransition introTransition;
  final ClipTransition outroTransition;
  final List<TimelineKeyframe> keyframes;
  final bool freezeFrame;

  /// Source timestamp held while [freezeFrame] is enabled.
  ///
  /// Older projects only persisted the boolean flag. In that case the first
  /// frame in the selected source range is used so the feature remains
  /// deterministic instead of becoming a render-only no-op.
  final Duration? freezeFrameSourceTime;
  final bool stabilize;
  final bool denoise;
  final bool chromaKeyEnabled;
  final Color chromaKeyColor;
  final double chromaKeySimilarity;
  final Color timelineColor;
  final String? notes;
  final bool autoDuck;
  final double duckAmount;
  final int duckAttackMs;
  final int duckReleaseMs;
  final List<String> duckSidechainTrackIds;

  TimelineClip({
    String? id,
    required this.trackId,
    required this.type,
    this.effectKind,
    this.effectStack = const EditorEffectStack(),
    this.isAdjustmentLayer = false,
    this.groupId,
    this.compoundId,
    required this.label,
    required this.startTime,
    required this.endTime,
    this.assetId,
    this.linkedClipId,
    this.separatedFromClipId,
    this.embeddedAudioSeparated = false,
    Duration? sourceStartTime,
    Duration? sourceDuration,
    this.layer = 0,
    this.enabled = true,
    this.transform = const TimelineTransform(),
    this.audioMix = const AudioMixSettings(),
    this.fitMode = ClipFitMode.cover,
    this.playbackRate = 1,
    this.isReversed = false,
    this.crop = const ClipCropSettings(),
    this.blur = const ClipBlurSettings(),
    this.colorAdjustments = const ClipColorAdjustments(),
    this.text,
    this.subtitleStyle,
    this.introTransition = const ClipTransition(),
    this.outroTransition = const ClipTransition(),
    List<TimelineKeyframe>? keyframes,
    this.freezeFrame = false,
    this.freezeFrameSourceTime,
    this.stabilize = false,
    this.denoise = false,
    this.chromaKeyEnabled = false,
    this.chromaKeyColor = const Color(0xFF00FF00),
    this.chromaKeySimilarity = 0.25,
    this.timelineColor = const Color(0x00000000),
    this.notes,
    this.autoDuck = false,
    this.duckAmount = 0.35,
    this.duckAttackMs = 120,
    this.duckReleaseMs = 180,
    List<String>? duckSidechainTrackIds,
  }) : id = id ?? const Uuid().v4(),
       sourceStartTime = sourceStartTime ?? Duration.zero,
       sourceDuration = sourceDuration ?? (endTime - startTime),
       keyframes = List.unmodifiable(keyframes ?? const []),
       duckSidechainTrackIds = List.unmodifiable(
         duckSidechainTrackIds ?? const [],
       );

  Duration get duration => endTime - startTime;
  String? get separatedAudioSourceClipId => type == TimelineTrackType.audio
      ? separatedFromClipId ?? linkedClipId
      : null;
  bool get isEffect =>
      type == TimelineTrackType.effect &&
      (effectKind != null || isAdjustmentLayer);
  bool get hasEffectStack => effectStack.isNotEmpty;

  factory TimelineClip.effect({
    String? id,
    required String trackId,
    TimelineEffectKind? effectKind,
    required String label,
    required Duration startTime,
    required Duration endTime,
    ClipBlurSettings blur = const ClipBlurSettings(),
    ClipColorAdjustments colorAdjustments = const ClipColorAdjustments(),
    EditorEffectStack effectStack = const EditorEffectStack(),
    bool isAdjustmentLayer = false,
    String? groupId,
    String? compoundId,
    int layer = 0,
    bool enabled = true,
  }) {
    return TimelineClip(
      id: id,
      trackId: trackId,
      type: TimelineTrackType.effect,
      effectKind: effectKind,
      effectStack: effectStack,
      isAdjustmentLayer: isAdjustmentLayer,
      groupId: groupId,
      compoundId: compoundId,
      label: label,
      startTime: startTime,
      endTime: endTime,
      sourceDuration: endTime - startTime,
      layer: layer,
      enabled: enabled,
      blur: blur,
      colorAdjustments: colorAdjustments,
      fitMode: ClipFitMode.cover,
    );
  }

  TimelineClip copyWith({
    String? id,
    String? trackId,
    TimelineTrackType? type,
    TimelineEffectKind? effectKind,
    bool clearEffectKind = false,
    EditorEffectStack? effectStack,
    bool? isAdjustmentLayer,
    String? groupId,
    bool clearGroupId = false,
    String? compoundId,
    bool clearCompoundId = false,
    String? label,
    String? assetId,
    bool clearAssetId = false,
    String? linkedClipId,
    bool clearLinkedClipId = false,
    String? separatedFromClipId,
    bool clearSeparatedFromClipId = false,
    bool? embeddedAudioSeparated,
    Duration? startTime,
    Duration? endTime,
    Duration? sourceStartTime,
    Duration? sourceDuration,
    int? layer,
    bool? enabled,
    TimelineTransform? transform,
    AudioMixSettings? audioMix,
    ClipFitMode? fitMode,
    double? playbackRate,
    bool? isReversed,
    ClipCropSettings? crop,
    ClipBlurSettings? blur,
    ClipColorAdjustments? colorAdjustments,
    String? text,
    SubtitleStyleModel? subtitleStyle,
    bool clearSubtitleStyle = false,
    ClipTransition? introTransition,
    ClipTransition? outroTransition,
    List<TimelineKeyframe>? keyframes,
    bool? freezeFrame,
    Duration? freezeFrameSourceTime,
    bool clearFreezeFrameSourceTime = false,
    bool? stabilize,
    bool? denoise,
    bool? chromaKeyEnabled,
    Color? chromaKeyColor,
    double? chromaKeySimilarity,
    Color? timelineColor,
    String? notes,
    bool clearNotes = false,
    bool? autoDuck,
    double? duckAmount,
    int? duckAttackMs,
    int? duckReleaseMs,
    List<String>? duckSidechainTrackIds,
  }) {
    return TimelineClip(
      id: id ?? this.id,
      trackId: trackId ?? this.trackId,
      type: type ?? this.type,
      effectKind: clearEffectKind ? null : (effectKind ?? this.effectKind),
      effectStack: effectStack ?? this.effectStack,
      isAdjustmentLayer: isAdjustmentLayer ?? this.isAdjustmentLayer,
      groupId: clearGroupId ? null : (groupId ?? this.groupId),
      compoundId: clearCompoundId ? null : (compoundId ?? this.compoundId),
      label: label ?? this.label,
      assetId: clearAssetId ? null : (assetId ?? this.assetId),
      linkedClipId: clearLinkedClipId
          ? null
          : (linkedClipId ?? this.linkedClipId),
      separatedFromClipId: clearSeparatedFromClipId
          ? null
          : (separatedFromClipId ?? this.separatedFromClipId),
      embeddedAudioSeparated:
          embeddedAudioSeparated ?? this.embeddedAudioSeparated,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      sourceStartTime: sourceStartTime ?? this.sourceStartTime,
      sourceDuration: sourceDuration ?? this.sourceDuration,
      layer: layer ?? this.layer,
      enabled: enabled ?? this.enabled,
      transform: transform ?? this.transform,
      audioMix: audioMix ?? this.audioMix,
      fitMode: fitMode ?? this.fitMode,
      playbackRate: playbackRate ?? this.playbackRate,
      isReversed: isReversed ?? this.isReversed,
      crop: crop ?? this.crop,
      blur: blur ?? this.blur,
      colorAdjustments: colorAdjustments ?? this.colorAdjustments,
      text: text ?? this.text,
      subtitleStyle: clearSubtitleStyle
          ? null
          : (subtitleStyle ?? this.subtitleStyle),
      introTransition: introTransition ?? this.introTransition,
      outroTransition: outroTransition ?? this.outroTransition,
      keyframes: keyframes ?? this.keyframes,
      freezeFrame: freezeFrame ?? this.freezeFrame,
      freezeFrameSourceTime: clearFreezeFrameSourceTime
          ? null
          : (freezeFrameSourceTime ?? this.freezeFrameSourceTime),
      stabilize: stabilize ?? this.stabilize,
      denoise: denoise ?? this.denoise,
      chromaKeyEnabled: chromaKeyEnabled ?? this.chromaKeyEnabled,
      chromaKeyColor: chromaKeyColor ?? this.chromaKeyColor,
      chromaKeySimilarity: chromaKeySimilarity ?? this.chromaKeySimilarity,
      timelineColor: timelineColor ?? this.timelineColor,
      notes: clearNotes ? null : (notes ?? this.notes),
      autoDuck: autoDuck ?? this.autoDuck,
      duckAmount: duckAmount ?? this.duckAmount,
      duckAttackMs: duckAttackMs ?? this.duckAttackMs,
      duckReleaseMs: duckReleaseMs ?? this.duckReleaseMs,
      duckSidechainTrackIds:
          duckSidechainTrackIds ?? this.duckSidechainTrackIds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'trackId': trackId,
      'type': type.name,
      'effectKind': effectKind?.name,
      'effectStack': effectStack.toJson(),
      'isAdjustmentLayer': isAdjustmentLayer,
      'groupId': groupId,
      'compoundId': compoundId,
      'label': label,
      'assetId': assetId,
      'linkedClipId': linkedClipId,
      'separatedFromClipId': separatedFromClipId,
      'embeddedAudioSeparated': embeddedAudioSeparated,
      'startTimeMs': startTime.inMilliseconds,
      'endTimeMs': endTime.inMilliseconds,
      'sourceStartTimeMs': sourceStartTime.inMilliseconds,
      'sourceDurationMs': sourceDuration.inMilliseconds,
      'layer': layer,
      'enabled': enabled,
      'transform': transform.toJson(),
      'audioMix': audioMix.toJson(),
      'fitMode': fitMode.name,
      'playbackRate': playbackRate,
      'isReversed': isReversed,
      'crop': crop.toJson(),
      'blur': blur.toJson(),
      'colorAdjustments': colorAdjustments.toJson(),
      'text': text,
      'subtitleStyle': subtitleStyle?.toJson(),
      'introTransition': introTransition.toJson(),
      'outroTransition': outroTransition.toJson(),
      'keyframes': keyframes.map((keyframe) => keyframe.toJson()).toList(),
      'freezeFrame': freezeFrame,
      'freezeFrameSourceTimeMs': freezeFrameSourceTime?.inMilliseconds,
      'stabilize': stabilize,
      'denoise': denoise,
      'chromaKeyEnabled': chromaKeyEnabled,
      'chromaKeyColor': _colorToInt(chromaKeyColor),
      'chromaKeySimilarity': chromaKeySimilarity.clamp(0.01, 1.0),
      'timelineColor': _colorToInt(timelineColor),
      'notes': notes,
      'autoDuck': autoDuck,
      'duckAmount': duckAmount.clamp(0.0, 1.0),
      'duckAttackMs': duckAttackMs.clamp(0, 5000),
      'duckReleaseMs': duckReleaseMs.clamp(0, 10000),
      'duckSidechainTrackIds': duckSidechainTrackIds,
    };
  }

  factory TimelineClip.fromJson(Map<String, dynamic> json) {
    final startTimeMs = _timelineInt(json['startTimeMs']);
    final endTimeMs = _timelineInt(json['endTimeMs']);
    if (endTimeMs <= startTimeMs) {
      throw const FormatException(
        'Timeline clips must have positive duration.',
      );
    }
    final playbackRate = ((json['playbackRate'] as num?)?.toDouble() ?? 1)
        .clamp(0.25, 4)
        .toDouble();
    final storedSourceDurationMs = _timelineInt(json['sourceDurationMs']);
    final sourceDurationMs = storedSourceDurationMs > 0
        ? storedSourceDurationMs
        : math.max(1, ((endTimeMs - startTimeMs) * playbackRate).round());
    return TimelineClip(
      id: json['id'] as String?,
      trackId: json['trackId'] as String? ?? '',
      type: TimelineTrackType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => TimelineTrackType.subtitle,
      ),
      effectKind: TimelineEffectKind.values
          .where((value) => value.name == json['effectKind'])
          .firstOrNull,
      effectStack: EditorEffectStack.fromJson(json['effectStack']),
      isAdjustmentLayer: json['isAdjustmentLayer'] as bool? ?? false,
      groupId: json['groupId'] as String?,
      compoundId: json['compoundId'] as String?,
      label: json['label'] as String? ?? 'Untitled clip',
      assetId: json['assetId'] as String?,
      linkedClipId: json['linkedClipId'] as String?,
      separatedFromClipId:
          json['separatedFromClipId'] as String? ??
          (json['type'] == TimelineTrackType.audio.name
              ? json['linkedClipId'] as String?
              : null),
      embeddedAudioSeparated: json['embeddedAudioSeparated'] as bool? ?? false,
      startTime: Duration(milliseconds: startTimeMs),
      endTime: Duration(milliseconds: endTimeMs),
      sourceStartTime: Duration(
        milliseconds: _timelineInt(json['sourceStartTimeMs']),
      ),
      sourceDuration: Duration(milliseconds: sourceDurationMs),
      layer: (json['layer'] as num?)?.toInt() ?? 0,
      enabled: json['enabled'] as bool? ?? true,
      transform: _timelineModelFromJson(
        json['transform'],
        TimelineTransform.fromJson,
        const TimelineTransform(),
      ),
      audioMix: _timelineModelFromJson(
        json['audioMix'],
        AudioMixSettings.fromJson,
        const AudioMixSettings(),
      ),
      fitMode: ClipFitMode.values.firstWhere(
        (value) => value.name == json['fitMode'],
        orElse: () => ClipFitMode.cover,
      ),
      playbackRate: playbackRate,
      isReversed: json['isReversed'] as bool? ?? false,
      crop: _timelineModelFromJson(
        json['crop'],
        ClipCropSettings.fromJson,
        const ClipCropSettings(),
      ),
      blur: _timelineModelFromJson(
        json['blur'],
        ClipBlurSettings.fromJson,
        const ClipBlurSettings(),
      ),
      colorAdjustments: _timelineModelFromJson(
        json['colorAdjustments'],
        ClipColorAdjustments.fromJson,
        const ClipColorAdjustments(),
      ),
      text: json['text'] as String?,
      subtitleStyle: _timelineOptionalModelFromJson(
        json['subtitleStyle'],
        SubtitleStyleModel.fromJson,
      ),
      introTransition: _timelineModelFromJson(
        json['introTransition'],
        ClipTransition.fromJson,
        const ClipTransition(),
      ),
      outroTransition: _timelineModelFromJson(
        json['outroTransition'],
        ClipTransition.fromJson,
        const ClipTransition(),
      ),
      keyframes: _timelineModelsFromJson(
        json['keyframes'],
        TimelineKeyframe.fromJson,
      ),
      freezeFrame: json['freezeFrame'] as bool? ?? false,
      freezeFrameSourceTime: (json['freezeFrameSourceTimeMs'] as num?) == null
          ? null
          : Duration(
              milliseconds: (json['freezeFrameSourceTimeMs'] as num).toInt(),
            ),
      stabilize: json['stabilize'] as bool? ?? false,
      denoise: json['denoise'] as bool? ?? false,
      chromaKeyEnabled: json['chromaKeyEnabled'] as bool? ?? false,
      chromaKeyColor: Color(
        _timelineInt(json['chromaKeyColor'], fallback: 0xFF00FF00),
      ),
      chromaKeySimilarity:
          (json['chromaKeySimilarity'] as num?)?.toDouble() ?? 0.25,
      timelineColor: Color(_timelineInt(json['timelineColor'])),
      notes: json['notes'] as String?,
      autoDuck: json['autoDuck'] as bool? ?? false,
      duckAmount: (json['duckAmount'] as num?)?.toDouble() ?? 0.35,
      duckAttackMs: _timelineInt(
        json['duckAttackMs'],
        fallback: 120,
      ).clamp(0, 5000).toInt(),
      duckReleaseMs: _timelineInt(
        json['duckReleaseMs'],
        fallback: 180,
      ).clamp(0, 10000).toInt(),
      duckSidechainTrackIds: json['duckSidechainTrackIds'] is List
          ? (json['duckSidechainTrackIds'] as List)
                .whereType<String>()
                .where((id) => id.trim().isNotEmpty)
                .toSet()
                .toList()
          : const [],
    );
  }

  factory TimelineClip.fromSubtitleEntry(
    SubtitleEntry entry, {
    required String trackId,
    String? linkedClipId,
  }) {
    return TimelineClip(
      id: entry.id,
      trackId: trackId,
      type: TimelineTrackType.subtitle,
      label: entry.text,
      linkedClipId: linkedClipId,
      startTime: entry.startTime,
      endTime: entry.endTime,
      text: entry.text,
      subtitleStyle: entry.styleOverride,
    );
  }

  SubtitleEntry? toSubtitleEntry() {
    if (type != TimelineTrackType.subtitle) return null;
    return SubtitleEntry(
      id: id,
      startTime: startTime,
      endTime: endTime,
      text: text ?? label,
      styleOverride: subtitleStyle,
    );
  }
}

extension TimelineClipCapabilities on TimelineClip {
  bool get supportsVisualEffects => type.supportsVisualEffects;
  bool get supportsChromaKey =>
      !isEffect &&
      (type == TimelineTrackType.video ||
          type == TimelineTrackType.image ||
          type == TimelineTrackType.gif ||
          type == TimelineTrackType.sticker);
  bool get supportsTransform => type.supportsTransform;
  bool get supportsTransformKeyframes => type.supportsTransformKeyframes;
  bool get supportsClipAnimation => type.supportsClipAnimation;
  bool get supportsSourceTiming => type.supportsSourceTiming;
  bool get supportsReversePlayback => type.supportsReversePlayback;
  bool get canCarryAudio => type.canCarryAudio;

  bool get hasKeyframes => keyframes.isNotEmpty;

  bool get hasTransformKeyframes =>
      supportsTransformKeyframes &&
      keyframes.any(
        (keyframe) =>
            kTimelineTransformKeyframeProperties.contains(keyframe.property),
      );

  bool get hasVolumeKeyframes => keyframes.any(
    (keyframe) => keyframe.property == TimelineKeyframeProperty.volume,
  );

  /// Unique clip-relative state times used by previous/next navigation.
  List<Duration> get keyframeStateTimes {
    final times = keyframes.map((keyframe) => keyframe.time).toSet().toList()
      ..sort();
    return times;
  }

  bool hasKeyframeStateAt(Duration relativeTime) => keyframes.any(
    (keyframe) => keyframe.time.inMilliseconds == relativeTime.inMilliseconds,
  );

  bool get hasAdvancedProcessing =>
      freezeFrame ||
      stabilize ||
      denoise ||
      chromaKeyEnabled ||
      effectStack.isNotEmpty ||
      autoDuck ||
      notes?.trim().isNotEmpty == true;

  /// Resolve a keyframed value at an absolute timeline position. Keyframes
  /// are stored clip-relative, which makes trim, split, duplicate and move
  /// operations preserve the animation without rewriting every keyframe.
  double keyframedValue(
    TimelineKeyframeProperty property,
    Duration absolutePosition, {
    double fallback = 0,
  }) {
    final frames =
        keyframes.where((keyframe) => keyframe.property == property).toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    if (frames.isEmpty) return fallback;
    final relative = (absolutePosition - startTime).inMilliseconds;
    if (relative <= frames.first.time.inMilliseconds) return frames.first.value;
    if (relative >= frames.last.time.inMilliseconds) return frames.last.value;
    for (var index = 1; index < frames.length; index++) {
      final previous = frames[index - 1];
      final next = frames[index];
      if (relative <= next.time.inMilliseconds) {
        final span = math.max(
          1,
          next.time.inMilliseconds - previous.time.inMilliseconds,
        );
        final progress = ((relative - previous.time.inMilliseconds) / span)
            .clamp(0.0, 1.0)
            .toDouble();
        final interpolatedProgress = previous.transformProgress(progress);
        return previous.value +
            (next.value - previous.value) * interpolatedProgress;
      }
    }
    return frames.last.value;
  }

  TimelineTransform transformAt(Duration position) {
    return transform.copyWith(
      offsetX: keyframedValue(
        TimelineKeyframeProperty.positionX,
        position,
        fallback: transform.offsetX,
      ),
      offsetY: keyframedValue(
        TimelineKeyframeProperty.positionY,
        position,
        fallback: transform.offsetY,
      ),
      scale: keyframedValue(
        TimelineKeyframeProperty.scale,
        position,
        fallback: transform.scale,
      ),
      rotation: keyframedValue(
        TimelineKeyframeProperty.rotation,
        position,
        fallback: transform.rotation,
      ),
      opacity: keyframedValue(
        TimelineKeyframeProperty.opacity,
        position,
        fallback: transform.opacity,
      ),
    );
  }

  ClipBlurSettings blurAt(Duration position) {
    return blur.copyWith(
      strength: keyframedValue(
        TimelineKeyframeProperty.blurStrength,
        position,
        fallback: blur.safeStrength,
      ).clamp(0.0, 30.0).toDouble(),
    );
  }

  /// An absolute source-file timestamp that is always inside the selected
  /// source window and can safely be passed to preview and FFmpeg seeks.
  Duration get effectiveFreezeFrameSourceTime {
    final startMs = sourceStartTime.inMilliseconds;
    final declaredSpanMs = sourceDuration.inMilliseconds;
    final fallbackSpanMs = math.max(
      1,
      (duration.inMilliseconds * playbackRate.clamp(0.25, 4)).round(),
    );
    final spanMs = declaredSpanMs > 0 ? declaredSpanMs : fallbackSpanMs;
    final endMs = startMs + math.max(0, spanMs - 1);
    final requestedMs =
        (freezeFrameSourceTime ?? sourceStartTime).inMilliseconds;
    return Duration(milliseconds: requestedMs.clamp(startMs, endMs).toInt());
  }

  double volumeAt(Duration position) {
    return keyframedValue(
      TimelineKeyframeProperty.volume,
      position,
      fallback: audioMix.volume,
    ).clamp(0.0, 2.0);
  }

  bool get hasRenderableTransformAdjustment {
    if (type == TimelineTrackType.text) {
      return transform.offsetX.abs() > 0.0001 ||
          transform.offsetY.abs() > 0.0001 ||
          (transform.scale - 1).abs() > 0.0001;
    }
    return supportsTransform && !transform.isIdentity;
  }

  /// Whether placement can expose the canvas around a source-video frame.
  /// Opacity and flips do not change coverage, while contain, translation,
  /// down-scaling and rotation can reveal an edge at some point in time.
  bool get mayRevealCanvasBackground {
    if (fitMode == ClipFitMode.contain ||
        transform.offsetX.abs() > 0.0001 ||
        transform.offsetY.abs() > 0.0001 ||
        transform.scale < 0.999 ||
        transform.rotation.abs() > 0.0001) {
      return true;
    }
    return keyframes.any((keyframe) {
      return switch (keyframe.property) {
        TimelineKeyframeProperty.positionX ||
        TimelineKeyframeProperty.positionY => keyframe.value.abs() > 0.0001,
        TimelineKeyframeProperty.scale => keyframe.value < 0.999,
        TimelineKeyframeProperty.rotation => keyframe.value.abs() > 0.0001,
        _ => false,
      };
    });
  }

  int get effectiveIntroTransitionMs => math.min(
    introTransition.durationMs.clamp(0, duration.inMilliseconds).toInt(),
    duration.inMilliseconds ~/ 2,
  );

  int get effectiveOutroTransitionMs => math.min(
    outroTransition.durationMs.clamp(0, duration.inMilliseconds).toInt(),
    duration.inMilliseconds ~/ 2,
  );

  int get effectiveAudioFadeInMs => math.min(
    audioMix.fadeInMs.clamp(0, duration.inMilliseconds).toInt(),
    duration.inMilliseconds ~/ 2,
  );

  int get effectiveAudioFadeOutMs => math.min(
    audioMix.fadeOutMs.clamp(0, duration.inMilliseconds).toInt(),
    duration.inMilliseconds ~/ 2,
  );

  /// Maps source-relative transcription cues into this clip's timeline span.
  ///
  /// Transcription runs against the selected source range, so its timestamps
  /// start at zero and do not account for timeline speed or reverse playback.
  List<SubtitleEntry> mapSourceSubtitlesToTimeline(
    Iterable<SubtitleEntry> sourceEntries,
  ) {
    final timelineSpanMs = math.max(0, duration.inMilliseconds);
    if (timelineSpanMs == 0) return const [];
    final safeRate = playbackRate.clamp(0.25, 4).toDouble();
    final sourceSpanMs = sourceDuration.inMilliseconds > 0
        ? sourceDuration.inMilliseconds
        : math.max(1, (timelineSpanMs * safeRate).round());

    ({int start, int end})? mapInterval(Duration start, Duration end) {
      final clippedSourceStart = start.inMilliseconds
          .clamp(0, sourceSpanMs)
          .toInt();
      final clippedSourceEnd = end.inMilliseconds
          .clamp(0, sourceSpanMs)
          .toInt();
      if (clippedSourceEnd <= clippedSourceStart) return null;

      final timelineStart = isReversed
          ? ((sourceSpanMs - clippedSourceEnd) / safeRate).round()
          : (clippedSourceStart / safeRate).round();
      final timelineEnd = isReversed
          ? ((sourceSpanMs - clippedSourceStart) / safeRate).round()
          : (clippedSourceEnd / safeRate).round();
      if (timelineEnd <= 0 || timelineStart >= timelineSpanMs) return null;
      var boundedStart = timelineStart.clamp(0, timelineSpanMs).toInt();
      var boundedEnd = timelineEnd.clamp(0, timelineSpanMs).toInt();
      if (boundedEnd <= boundedStart) {
        if (boundedStart < timelineSpanMs) {
          boundedEnd = boundedStart + 1;
        } else if (boundedEnd > 0) {
          boundedStart = boundedEnd - 1;
        } else {
          return null;
        }
      }
      return (start: boundedStart, end: boundedEnd);
    }

    final mappedEntries = <SubtitleEntry>[];
    for (final entry in sourceEntries) {
      final interval = mapInterval(entry.startTime, entry.endTime);
      if (interval == null) continue;
      final entryStart = startTime + Duration(milliseconds: interval.start);
      final entryEnd = startTime + Duration(milliseconds: interval.end);
      final mappedWords = <WordTiming>[];
      for (final word in entry.words ?? const <WordTiming>[]) {
        final wordInterval = mapInterval(word.startTime, word.endTime);
        if (wordInterval == null) continue;
        var wordStartMs = wordInterval.start
            .clamp(interval.start, interval.end)
            .toInt();
        var wordEndMs = wordInterval.end
            .clamp(interval.start, interval.end)
            .toInt();
        if (wordEndMs <= wordStartMs) {
          if (wordStartMs < interval.end) {
            wordEndMs = wordStartMs + 1;
          } else if (wordEndMs > interval.start) {
            wordStartMs = wordEndMs - 1;
          } else {
            continue;
          }
        }
        mappedWords.add(
          WordTiming(
            word: word.word,
            startTime: startTime + Duration(milliseconds: wordStartMs),
            endTime: startTime + Duration(milliseconds: wordEndMs),
          ),
        );
      }
      mappedEntries.add(
        entry.copyWith(
          startTime: entryStart,
          endTime: entryEnd,
          words: mappedWords.isEmpty ? null : mappedWords,
          clearWords: entry.words != null && mappedWords.isEmpty,
        ),
      );
    }
    mappedEntries.sort((a, b) => a.startTime.compareTo(b.startTime));
    return mappedEntries;
  }
}

class TimelineTrack {
  final String id;
  final String name;
  final TimelineTrackType type;
  final TimelineTrackSection section;
  final TimelineTrackRole role;
  final bool isCollapsed;
  final bool isLocked;
  final bool isMuted;
  final bool isHidden;
  final bool isSolo;
  final double audioGain;
  final double audioPan;
  final String? audioBusId;
  final bool syncLocked;
  final EditorEffectStack effectStack;
  final List<TimelineClip> clips;

  TimelineTrack({
    String? id,
    required this.name,
    required this.type,
    TimelineTrackSection? section,
    TimelineTrackRole? role,
    this.isCollapsed = false,
    this.isLocked = false,
    this.isMuted = false,
    this.isHidden = false,
    this.isSolo = false,
    this.audioGain = 1,
    this.audioPan = 0,
    this.audioBusId,
    this.syncLocked = false,
    this.effectStack = const EditorEffectStack(),
    List<TimelineClip>? clips,
  }) : id = id ?? const Uuid().v4(),
       section = section ?? _defaultSectionForType(type),
       role = role ?? TimelineTrackRole.regular,
       clips = clips ?? const [];

  TimelineTrack copyWith({
    String? id,
    String? name,
    TimelineTrackType? type,
    TimelineTrackSection? section,
    TimelineTrackRole? role,
    bool? isCollapsed,
    bool? isLocked,
    bool? isMuted,
    bool? isHidden,
    bool? isSolo,
    double? audioGain,
    double? audioPan,
    String? audioBusId,
    bool clearAudioBusId = false,
    bool? syncLocked,
    EditorEffectStack? effectStack,
    List<TimelineClip>? clips,
  }) {
    return TimelineTrack(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      section: section ?? this.section,
      role: role ?? this.role,
      isCollapsed: isCollapsed ?? this.isCollapsed,
      isLocked: isLocked ?? this.isLocked,
      isMuted: isMuted ?? this.isMuted,
      isHidden: isHidden ?? this.isHidden,
      isSolo: isSolo ?? this.isSolo,
      audioGain: audioGain ?? this.audioGain,
      audioPan: audioPan ?? this.audioPan,
      audioBusId: clearAudioBusId ? null : (audioBusId ?? this.audioBusId),
      syncLocked: syncLocked ?? this.syncLocked,
      effectStack: effectStack ?? this.effectStack,
      clips: clips ?? this.clips,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'section': section.name,
      'role': role.name,
      'isCollapsed': isCollapsed,
      'isLocked': isLocked,
      'isMuted': isMuted,
      'isHidden': isHidden,
      'isSolo': isSolo,
      'audioGain': audioGain.clamp(0.0, 2.0),
      'audioPan': audioPan.clamp(-1.0, 1.0),
      'audioBusId': audioBusId,
      'syncLocked': syncLocked,
      'effectStack': effectStack.toJson(),
      'clips': clips.map((clip) => clip.toJson()).toList(),
    };
  }

  factory TimelineTrack.fromJson(Map<String, dynamic> json) {
    return TimelineTrack(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Untitled track',
      type: _trackTypeFromJson(json['type']),
      section: TimelineTrackSection.values.firstWhere(
        (value) => value.name == json['section'],
        orElse: () => _defaultSectionForType(_trackTypeFromJson(json['type'])),
      ),
      role: _trackRoleFromJson(
        json['role'],
        id: json['id'] as String?,
        name: json['name'] as String?,
        type: _trackTypeFromJson(json['type']),
        section: TimelineTrackSection.values.firstWhere(
          (value) => value.name == json['section'],
          orElse: () =>
              _defaultSectionForType(_trackTypeFromJson(json['type'])),
        ),
      ),
      isCollapsed: json['isCollapsed'] as bool? ?? false,
      isLocked: json['isLocked'] as bool? ?? false,
      isMuted: json['isMuted'] as bool? ?? false,
      isHidden: json['isHidden'] as bool? ?? false,
      isSolo: json['isSolo'] as bool? ?? false,
      audioGain: ((json['audioGain'] as num?)?.toDouble() ?? 1)
          .clamp(0.0, 2.0)
          .toDouble(),
      audioPan: ((json['audioPan'] as num?)?.toDouble() ?? 0)
          .clamp(-1.0, 1.0)
          .toDouble(),
      audioBusId: json['audioBusId'] as String?,
      syncLocked: json['syncLocked'] as bool? ?? false,
      effectStack: EditorEffectStack.fromJson(json['effectStack']),
      clips: _timelineModelsFromJson(json['clips'], TimelineClip.fromJson),
    );
  }
}

extension TimelineTrackCompatibility on TimelineTrack {
  bool get isSourceTrack => role == TimelineTrackRole.sourceAudio;

  /// The fixed, bottom-most visual lane. The persisted section name remains
  /// `baseVideo` so existing project files stay compatible, but the lane may
  /// contain video, still images, GIFs, or stickers.
  bool get isBaseLayer => section == TimelineTrackSection.baseVideo;

  /// Stable user-facing terminology independent of names saved by old builds.
  String get displayName => isBaseLayer ? 'Base layer' : name;

  bool get isReorderable =>
      role == TimelineTrackRole.regular &&
      section != TimelineTrackSection.baseVideo;

  bool get isDuplicable =>
      role == TimelineTrackRole.regular &&
      section != TimelineTrackSection.baseVideo &&
      type != TimelineTrackType.subtitle;

  bool get isVisualLayer =>
      section == TimelineTrackSection.overlay ||
      section == TimelineTrackSection.textSubtitle ||
      section == TimelineTrackSection.baseVideo;

  /// Whether this lane can safely contain [clipType].
  ///
  /// Visual lanes are intentionally media-agnostic so a video, image, GIF, or
  /// sticker may act as either the base or an overlay. Text, subtitle, and
  /// audio lanes stay strict because their preview/export paths are specific.
  bool acceptsClipType(TimelineTrackType clipType) {
    switch (section) {
      case TimelineTrackSection.baseVideo:
        return clipType.isVisualMedia;
      case TimelineTrackSection.overlay:
        // Overlay lanes are deliberately generic. Effects and filters are
        // visual-layer clips, not a dedicated track architecture.
        return clipType == TimelineTrackType.effect || clipType.isVisualMedia;
      case TimelineTrackSection.textSubtitle:
        return type == clipType && clipType.isTextContent;
      case TimelineTrackSection.audio:
        return type == TimelineTrackType.audio &&
            clipType == TimelineTrackType.audio;
    }
  }

  bool acceptsClip(TimelineClip clip) => acceptsClipType(clip.type);

  /// Whether [clip] can occupy this lane without sharing time with another
  /// clip. Touching edges are valid cuts; positive-duration intersections are
  /// not. Disabled clips still reserve their edit, just like hidden tracks do.
  bool canPlaceClip(TimelineClip clip, {String? ignoringClipId}) {
    if (!acceptsClip(clip) || clip.endTime <= clip.startTime) return false;
    return clips.every((candidate) {
      if (candidate.id == ignoringClipId || candidate.id == clip.id) {
        return true;
      }
      return clip.endTime <= candidate.startTime ||
          clip.startTime >= candidate.endTime;
    });
  }

  bool get hasOverlappingClips {
    final sorted = [...clips]
      ..sort((a, b) {
        final byStart = a.startTime.compareTo(b.startTime);
        return byStart != 0 ? byStart : a.endTime.compareTo(b.endTime);
      });
    for (var index = 1; index < sorted.length; index++) {
      if (sorted[index].startTime < sorted[index - 1].endTime) return true;
    }
    return false;
  }

  /// Returns the closest non-overlapping start for a clip with [duration].
  ///
  /// The search considers every gap in the lane, so dragging against a
  /// neighbour stops at its edge instead of jumping needlessly to the end.
  /// When [latestEnd] is omitted the timeline may grow after the last clip.
  Duration closestAvailableStart({
    required Duration desiredStart,
    required Duration duration,
    String? ignoringClipId,
    Duration? latestEnd,
  }) {
    final durationMs = math.max(1, duration.inMilliseconds);
    final desiredMs = math.max(0, desiredStart.inMilliseconds);
    final maximumEndMs = latestEnd?.inMilliseconds;
    final candidates = <int>[];
    final occupied = clips.where((clip) => clip.id != ignoringClipId).toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    var gapStartMs = 0;
    for (final clip in occupied) {
      final gapEndMs = clip.startTime.inMilliseconds;
      if (gapEndMs - gapStartMs >= durationMs) {
        candidates.add(
          desiredMs.clamp(gapStartMs, gapEndMs - durationMs).toInt(),
        );
      }
      gapStartMs = math.max(gapStartMs, clip.endTime.inMilliseconds);
    }

    if (maximumEndMs == null) {
      candidates.add(math.max(desiredMs, gapStartMs));
    } else if (maximumEndMs - gapStartMs >= durationMs) {
      candidates.add(
        desiredMs.clamp(gapStartMs, maximumEndMs - durationMs).toInt(),
      );
    }

    if (candidates.isEmpty) {
      // A bounded lane with no fitting gap cannot accept the requested edit.
      // Returning the current/desired position lets the caller detect that by
      // running [canPlaceClip] before committing.
      return Duration(milliseconds: desiredMs);
    }
    candidates.sort((a, b) {
      final byDistance = (a - desiredMs).abs().compareTo((b - desiredMs).abs());
      return byDistance != 0 ? byDistance : a.compareTo(b);
    });
    return Duration(milliseconds: candidates.first);
  }
}

/// Finds the nearest legal gap without allocating another lane.
///
/// Candidate order is used as the tie-breaker, allowing callers to put the
/// selected lane first while keeping placement deterministic.
({TimelineTrack track, Duration start})? resolveClosestReusableTrackPlacement({
  required Iterable<TimelineTrack> tracks,
  required TimelineTrackType clipType,
  required Duration desiredStart,
  required Duration duration,
}) {
  TimelineTrack? bestTrack;
  Duration? bestStart;
  var bestDistanceMs = 1 << 62;
  for (final track in tracks) {
    if (track.isLocked ||
        track.isSourceTrack ||
        !track.acceptsClipType(clipType)) {
      continue;
    }
    final candidateStart = track.closestAvailableStart(
      desiredStart: desiredStart,
      duration: duration,
    );
    final probe = TimelineClip(
      trackId: track.id,
      type: clipType,
      label: 'Imported media',
      startTime: candidateStart,
      endTime: candidateStart + duration,
    );
    if (!track.canPlaceClip(probe)) continue;
    final distanceMs = (candidateStart - desiredStart).inMilliseconds.abs();
    if (bestTrack == null || distanceMs < bestDistanceMs) {
      bestTrack = track;
      bestStart = candidateStart;
      bestDistanceMs = distanceMs;
    }
  }
  return bestTrack == null || bestStart == null
      ? null
      : (track: bestTrack, start: bestStart);
}

class CanvasSettings {
  final CanvasAspectRatioPreset aspectRatioPreset;
  final int? customWidth;
  final int? customHeight;
  final Color backgroundColor;
  final bool showSafeAreas;
  final bool showGrid;
  final int gridDivisions;
  final bool snapToGuides;

  const CanvasSettings({
    this.aspectRatioPreset = CanvasAspectRatioPreset.original,
    this.customWidth,
    this.customHeight,
    this.backgroundColor = Colors.black,
    this.showSafeAreas = true,
    this.showGrid = false,
    this.gridDivisions = 3,
    this.snapToGuides = true,
  });

  CanvasSettings copyWith({
    CanvasAspectRatioPreset? aspectRatioPreset,
    int? customWidth,
    int? customHeight,
    Color? backgroundColor,
    bool? showSafeAreas,
    bool? showGrid,
    int? gridDivisions,
    bool? snapToGuides,
  }) {
    return CanvasSettings(
      aspectRatioPreset: aspectRatioPreset ?? this.aspectRatioPreset,
      customWidth: customWidth ?? this.customWidth,
      customHeight: customHeight ?? this.customHeight,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      showSafeAreas: showSafeAreas ?? this.showSafeAreas,
      showGrid: showGrid ?? this.showGrid,
      gridDivisions: gridDivisions ?? this.gridDivisions,
      snapToGuides: snapToGuides ?? this.snapToGuides,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'aspectRatioPreset': aspectRatioPreset.name,
      'customWidth': customWidth,
      'customHeight': customHeight,
      'backgroundColor': _colorToInt(backgroundColor),
      'showSafeAreas': showSafeAreas,
      'showGrid': showGrid,
      'gridDivisions': gridDivisions,
      'snapToGuides': snapToGuides,
    };
  }

  factory CanvasSettings.fromJson(Map<String, dynamic> json) {
    return CanvasSettings(
      aspectRatioPreset: CanvasAspectRatioPreset.values.firstWhere(
        (value) => value.name == json['aspectRatioPreset'],
        orElse: () => CanvasAspectRatioPreset.original,
      ),
      customWidth: (json['customWidth'] as num?)?.toInt(),
      customHeight: (json['customHeight'] as num?)?.toInt(),
      backgroundColor: Color(json['backgroundColor'] as int? ?? 0xFF000000),
      showSafeAreas: json['showSafeAreas'] as bool? ?? true,
      showGrid: json['showGrid'] as bool? ?? false,
      gridDivisions: (json['gridDivisions'] as num?)?.toInt() ?? 3,
      snapToGuides: json['snapToGuides'] as bool? ?? true,
    );
  }
}

class EditorTimeline {
  static const int currentSchemaVersion = 10;

  final int schemaVersion;
  final CanvasSettings canvasSettings;
  final TimelineWorkspaceSettings workspaceSettings;
  final SubtitleStyleModel subtitleStyle;
  final List<EditorAssetReference> assets;
  final List<TimelineTrack> tracks;
  final List<TimelineMarker> markers;
  final EditorEffectStack projectEffectStack;
  final List<EditorEffectContainer> effectContainers;
  final List<EditorEffectPreset> effectPresets;
  final List<TimelineGroup> groups;
  final List<TimelineCompoundClip> compoundClips;
  final List<TimelineAudioBus> audioBuses;
  final EditorColorManagementSettings colorManagement;

  const EditorTimeline({
    this.schemaVersion = currentSchemaVersion,
    this.canvasSettings = const CanvasSettings(),
    this.workspaceSettings = const TimelineWorkspaceSettings(),
    this.subtitleStyle = const SubtitleStyleModel(),
    this.assets = const [],
    this.tracks = const [],
    this.markers = const [],
    this.projectEffectStack = const EditorEffectStack(),
    this.effectContainers = const [],
    this.effectPresets = const [],
    this.groups = const [],
    this.compoundClips = const [],
    this.audioBuses = const [],
    this.colorManagement = const EditorColorManagementSettings(),
  });

  TimelineTrack? get primarySubtitleTrack {
    for (final track in tracks) {
      if (track.type == TimelineTrackType.subtitle) {
        return track;
      }
    }
    return null;
  }

  List<TimelineTrack> tracksForSection(TimelineTrackSection section) {
    return tracks.where((track) => track.section == section).toList();
  }

  TimelineTrack? insertionTrackFor({
    required TimelineTrackSection section,
    required TimelineTrackType clipType,
    String? preferredTrackId,
  }) {
    // Caption lanes can be source-specific. A locked lane blocks edits to that
    // lane only; it must not prevent captions for another video from using an
    // unlocked lane.
    final candidates = tracks.where(
      (track) =>
          track.section == section &&
          !track.isSourceTrack &&
          !track.isLocked &&
          track.acceptsClipType(clipType),
    );
    if (preferredTrackId != null) {
      for (final track in candidates) {
        if (track.id == preferredTrackId) return track;
      }
    }
    return candidates.firstOrNull;
  }

  String nextTrackNameForSection(TimelineTrackSection section) {
    final sectionTracks = tracksForSection(section);
    switch (section) {
      case TimelineTrackSection.overlay:
        return 'Overlay ${sectionTracks.length + 1}';
      case TimelineTrackSection.baseVideo:
        return 'Base layer';
      case TimelineTrackSection.textSubtitle:
        final textTracks = sectionTracks
            .where((track) => track.type == TimelineTrackType.text)
            .length;
        return 'Text ${textTracks + 1}';
      case TimelineTrackSection.audio:
        return 'Audio ${sectionTracks.length + 1}';
    }
  }

  /// Track order is stored top-to-bottom, matching the rows the user sees.
  /// Flutter and FFmpeg paint bottom-to-top, so composition consumes this view.
  ///
  /// Older saved projects stored their Base layer first and appended visual
  /// lanes beneath it. Keep those lanes above the base while they are
  /// migrated so opening an existing project cannot silently invert its
  /// composition.
  List<TimelineTrack> get visualTracksInPaintOrder {
    return tracks
        .where((track) => track.isVisualLayer && !track.isHidden)
        .toList()
        .reversed
        .toList(growable: false);
  }

  /// Inserts a new lane without disturbing the fixed Base layer or any
  /// preserved legacy source-audio lane.
  ///
  /// New overlays sit above existing overlays but below text. Additional audio
  /// lanes always live beneath the extracted source-audio lane.
  EditorTimeline insertTrackUsingEditorRules(TimelineTrack track) {
    final next = [...tracks];
    switch (track.section) {
      case TimelineTrackSection.textSubtitle:
        final firstNonText = next.indexWhere(
          (candidate) => candidate.section != TimelineTrackSection.textSubtitle,
        );
        next.insert(firstNonText < 0 ? next.length : firstNonText, track);
        break;
      case TimelineTrackSection.overlay:
        final mainVideoIndex = next.indexWhere(
          (candidate) => candidate.section == TimelineTrackSection.baseVideo,
        );
        final firstOverlay = next.indexWhere(
          (candidate) => candidate.section == TimelineTrackSection.overlay,
        );
        final afterText =
            next.lastIndexWhere(
              (candidate) =>
                  candidate.section == TimelineTrackSection.textSubtitle,
            ) +
            1;
        final insertionIndex = firstOverlay >= 0
            ? math.max(afterText, firstOverlay)
            : mainVideoIndex >= 0
            ? math.max(afterText, mainVideoIndex)
            : math.max(afterText, next.length);
        next.insert(insertionIndex.clamp(0, next.length).toInt(), track);
        break;
      case TimelineTrackSection.audio:
        // Appending places a newly-created lane below older audio content and
        // beneath any preserved legacy source-audio lane.
        next.add(track);
        break;
      case TimelineTrackSection.baseVideo:
        final firstAudioIndex = next.indexWhere(
          (candidate) => candidate.section == TimelineTrackSection.audio,
        );
        next.insert(firstAudioIndex < 0 ? next.length : firstAudioIndex, track);
        break;
    }
    return copyWith(tracks: next);
  }

  bool canReorderTrackTo(String trackId, String targetTrackId) {
    if (trackId == targetTrackId) return false;
    final source = tracks.where((track) => track.id == trackId).firstOrNull;
    final target = tracks
        .where((track) => track.id == targetTrackId)
        .firstOrNull;
    if (source == null || target == null) return false;
    if (!source.isReorderable || !target.isReorderable) return false;
    final sourceIsAudio = source.section == TimelineTrackSection.audio;
    final targetIsAudio = target.section == TimelineTrackSection.audio;
    // Visual layers may be freely reordered with one another. Audio lanes form
    // their own ordering group below the fixed source audio lane.
    return sourceIsAudio == targetIsAudio;
  }

  EditorTimeline reorderTrackTo(String trackId, String targetTrackId) {
    if (!canReorderTrackTo(trackId, targetTrackId)) return this;
    final next = [...tracks];
    final sourceIndex = next.indexWhere((track) => track.id == trackId);
    final originalTargetIndex = next.indexWhere(
      (track) => track.id == targetTrackId,
    );
    final moved = next.removeAt(sourceIndex);
    // Occupy the target row's original slot. When moving down, inserting at
    // that unadjusted index places the moved row after the target; when moving
    // up it places it before the target. This makes both drag directions
    // responsive instead of turning downward moves into a no-op.
    next.insert(originalTargetIndex.clamp(0, next.length).toInt(), moved);
    return copyWith(tracks: next);
  }

  List<SubtitleEntry> get subtitleEntries {
    return tracks
        .where((track) => track.type == TimelineTrackType.subtitle)
        .expand((track) => track.clips)
        .map((clip) => clip.toSubtitleEntry())
        .whereType<SubtitleEntry>()
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  List<TimelineClip> get videoClips {
    return tracks
        .where((track) => track.type == TimelineTrackType.video)
        .expand((track) => track.clips)
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  Duration get duration {
    return tracks
        .expand((track) => track.clips)
        .fold<Duration>(
          Duration.zero,
          (current, clip) => clip.endTime > current ? clip.endTime : current,
        );
  }

  Duration get baseLayerDuration {
    return tracks
        .where((track) => track.section == TimelineTrackSection.baseVideo)
        .expand((track) => track.clips)
        .fold<Duration>(
          Duration.zero,
          (current, clip) => clip.endTime > current ? clip.endTime : current,
        );
  }

  /// Backwards-compatible alias for code and files that still use the old
  /// base-video terminology internally.
  Duration get baseVideoDuration => baseLayerDuration;

  EditorEffectStack effectStackForClip(
    TimelineClip clip, {
    TimelineTrack? track,
  }) {
    final scopedStacks = effectStacksForClip(clip, track: track);
    return EditorEffectStack(
      effects: [for (final scoped in scopedStacks) ...scoped.stack.effects],
    );
  }

  List<({EditorEffectScope scope, EditorEffectStack stack})>
  effectStacksForClip(TimelineClip clip, {TimelineTrack? track}) {
    final resolvedTrack =
        track ??
        tracks.where((candidate) => candidate.id == clip.trackId).firstOrNull ??
        tracks.where((candidate) {
          return candidate.clips.any(
            (candidateClip) => candidateClip.id == clip.id,
          );
        }).firstOrNull;
    final stacks = <({EditorEffectScope scope, EditorEffectStack stack})>[
      if (clip.effectStack.isNotEmpty)
        (scope: EditorEffectScope.clip, stack: clip.effectStack),
    ];
    void appendContainer(EditorEffectScope scope, String? targetId) {
      if (targetId == null) return;
      final targetEnabled = switch (scope) {
        EditorEffectScope.group =>
          groups.where((group) => group.id == targetId).firstOrNull?.enabled,
        EditorEffectScope.compound =>
          compoundClips
              .where((compound) => compound.id == targetId)
              .firstOrNull
              ?.enabled,
        EditorEffectScope.audioBus => true,
        _ => true,
      };
      if (targetEnabled != true) return;
      for (final container in effectContainers) {
        if (container.enabled &&
            container.scope == scope &&
            container.targetId == targetId) {
          if (container.stack.isNotEmpty) {
            stacks.add((scope: scope, stack: container.stack));
          }
        }
      }
    }

    appendContainer(EditorEffectScope.compound, clip.compoundId);
    appendContainer(EditorEffectScope.group, clip.groupId);
    if (resolvedTrack?.effectStack.isNotEmpty == true) {
      stacks.add((
        scope: EditorEffectScope.track,
        stack: resolvedTrack!.effectStack,
      ));
    }
    return stacks;
  }

  List<TimelineClip> get visualMediaClips {
    return tracks
        .where(
          (track) =>
              track.section == TimelineTrackSection.baseVideo ||
              track.section == TimelineTrackSection.overlay,
        )
        .expand(
          (track) => track.clips.where(
            (clip) => clip.type.isVisualMedia && track.acceptsClip(clip),
          ),
        )
        .toList(growable: false);
  }

  bool get hasVisualContent => visualMediaClips.isNotEmpty;

  bool wouldRetainVisualContentAfterRemoving(Iterable<String> clipIds) {
    final removed = clipIds.toSet();
    return visualMediaClips.any((clip) => !removed.contains(clip.id));
  }

  bool get hasTrackOverlaps => tracks.any((track) => track.hasOverlappingClips);

  /// Repairs malformed/legacy timelines by moving colliding clips to the
  /// earliest free point while preserving clip duration and lane membership.
  EditorTimeline withoutTrackOverlaps() {
    if (!hasTrackOverlaps) return this;
    final nextTracks = tracks.map((track) {
      if (!track.hasOverlappingClips) return track;
      final sorted = [...track.clips]
        ..sort((a, b) {
          final byStart = a.startTime.compareTo(b.startTime);
          return byStart != 0 ? byStart : a.endTime.compareTo(b.endTime);
        });
      var cursor = Duration.zero;
      final repaired = <TimelineClip>[];
      for (final clip in sorted) {
        final start = clip.startTime < cursor ? cursor : clip.startTime;
        final duration = clip.duration > Duration.zero
            ? clip.duration
            : const Duration(milliseconds: 1);
        final placed = clip.copyWith(
          startTime: start,
          endTime: start + duration,
        );
        repaired.add(placed);
        cursor = placed.endTime;
      }
      return track.copyWith(clips: repaired);
    }).toList();
    return copyWith(tracks: nextTracks);
  }

  EditorAssetReference? assetForClip(TimelineClip clip) {
    final assetId = clip.assetId;
    if (assetId == null) return null;
    for (final asset in assets) {
      if (asset.id == assetId) return asset;
    }
    return null;
  }

  /// Audio controls are valid only when the selected media actually has audio.
  /// Unknown video metadata remains editable for backwards-compatible projects.
  bool clipHasAudio(TimelineClip clip) {
    if (clip.type == TimelineTrackType.audio) return true;
    if (clip.type != TimelineTrackType.video) return false;
    final hasAudio = assetForClip(clip)?.metadata['hasAudio'];
    return hasAudio is bool ? hasAudio : true;
  }

  List<TimelineClip> subtitleClipsForLinkedClip(String clipId) {
    return tracks
        .where((track) => track.type == TimelineTrackType.subtitle)
        .expand((track) => track.clips)
        .where((clip) => clip.linkedClipId == clipId)
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  EditorTimeline copyWith({
    int? schemaVersion,
    CanvasSettings? canvasSettings,
    TimelineWorkspaceSettings? workspaceSettings,
    SubtitleStyleModel? subtitleStyle,
    List<EditorAssetReference>? assets,
    List<TimelineTrack>? tracks,
    List<TimelineMarker>? markers,
    EditorEffectStack? projectEffectStack,
    List<EditorEffectContainer>? effectContainers,
    List<EditorEffectPreset>? effectPresets,
    List<TimelineGroup>? groups,
    List<TimelineCompoundClip>? compoundClips,
    List<TimelineAudioBus>? audioBuses,
    EditorColorManagementSettings? colorManagement,
  }) {
    return EditorTimeline(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      canvasSettings: canvasSettings ?? this.canvasSettings,
      workspaceSettings: workspaceSettings ?? this.workspaceSettings,
      subtitleStyle: subtitleStyle ?? this.subtitleStyle,
      assets: assets ?? this.assets,
      tracks: tracks ?? this.tracks,
      markers: markers ?? this.markers,
      projectEffectStack: projectEffectStack ?? this.projectEffectStack,
      effectContainers: effectContainers ?? this.effectContainers,
      effectPresets: effectPresets ?? this.effectPresets,
      groups: groups ?? this.groups,
      compoundClips: compoundClips ?? this.compoundClips,
      audioBuses: audioBuses ?? this.audioBuses,
      colorManagement: colorManagement ?? this.colorManagement,
    );
  }

  EditorTimeline canonicalized() {
    final migratedInputColorTracks = schemaVersion < 9
        ? tracks
              .map(
                (track) => track.copyWith(
                  clips: track.clips
                      .map(
                        (clip) =>
                            clip.colorAdjustments.inputColorSpace ==
                                EditorColorSpace.sdr709
                            ? clip.copyWith(
                                colorAdjustments: clip.colorAdjustments
                                    .copyWith(
                                      inputColorSpace:
                                          EditorColorSpace.automatic,
                                    ),
                              )
                            : clip,
                      )
                      .toList(),
                ),
              )
              .toList()
        : tracks;
    final normalizedTracks = _foldRedundantLegacySourceAudio(
      _canonicalizeTimelineTracks(migratedInputColorTracks),
    );
    final orderedTracks = schemaVersion < 5
        ? _migrateLegacyTrackOrder(normalizedTracks)
        : normalizedTracks;
    final separationAwareTracks = _restoreSeparatedAudioOwnership(
      orderedTracks,
    );
    final relationships = _canonicalizeTimelineRelationships(
      tracks: separationAwareTracks,
      groups: groups,
      compoundClips: compoundClips,
      audioBuses: audioBuses,
      effectContainers: effectContainers,
      projectEffectStack: projectEffectStack,
    );
    return copyWith(
      schemaVersion: currentSchemaVersion,
      assets: _canonicalizeAssets(assets),
      tracks: relationships.tracks,
      projectEffectStack: relationships.projectEffectStack,
      effectContainers: relationships.effectContainers,
      effectPresets: _canonicalizeEffectPresets(effectPresets),
      groups: relationships.groups,
      compoundClips: relationships.compoundClips,
      audioBuses: relationships.audioBuses,
      colorManagement: _canonicalizeColorManagement(colorManagement),
    ).withoutTrackOverlaps();
  }

  EditorTimeline prunedRelationships() {
    final relationships = _canonicalizeTimelineRelationships(
      tracks: tracks,
      groups: groups,
      compoundClips: compoundClips,
      audioBuses: audioBuses,
      effectContainers: effectContainers,
      projectEffectStack: projectEffectStack,
    );
    return copyWith(
      tracks: relationships.tracks,
      groups: relationships.groups,
      compoundClips: relationships.compoundClips,
      audioBuses: relationships.audioBuses,
      effectContainers: relationships.effectContainers,
      projectEffectStack: relationships.projectEffectStack,
    );
  }

  EditorTimeline syncLegacySubtitles({
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
    required String videoPath,
    required int durationMs,
  }) {
    final canonicalTracks = _canonicalizeTimelineTracks(tracks);
    var nextTracks = canonicalTracks;
    if (subtitles.isNotEmpty ||
        canonicalTracks.any(
          (track) => track.type == TimelineTrackType.subtitle,
        )) {
      final subtitleTracks = _mergedSubtitleTracks(
        canonicalTracks,
        subtitles: subtitles,
      );
      nextTracks = _replaceTrackGroupWithMany(
        canonicalTracks,
        matches: (track) => track.type == TimelineTrackType.subtitle,
        replacements: subtitleTracks,
      );
    }

    var nextAssets = _canonicalizeAssets(assets);
    final hasVisualClip = nextTracks.any(
      (track) =>
          (track.section == TimelineTrackSection.baseVideo ||
              track.section == TimelineTrackSection.overlay) &&
          track.clips.any(
            (clip) => clip.type.isVisualMedia && track.acceptsClip(clip),
          ),
    );
    final hasUsableLegacyVideo = videoPath.trim().isNotEmpty && durationMs > 0;
    EditorAssetReference? existingSourceAsset;
    for (final asset in nextAssets) {
      if (asset.type == EditorAssetType.video &&
          asset.sourcePath == videoPath) {
        existingSourceAsset = asset;
        break;
      }
    }

    final baseTracks = nextTracks
        .where((track) => track.section == TimelineTrackSection.baseVideo)
        .toList();
    final baseClipsNeedLegacyAsset = baseTracks.any(
      (track) => track.clips.any(
        (clip) => clip.type == TimelineTrackType.video && clip.assetId == null,
      ),
    );
    final shouldSeedLegacyClip = !hasVisualClip && hasUsableLegacyVideo;
    EditorAssetReference? resolvedSourceAsset = existingSourceAsset;
    if ((shouldSeedLegacyClip || baseClipsNeedLegacyAsset) &&
        hasUsableLegacyVideo &&
        resolvedSourceAsset == null) {
      resolvedSourceAsset = EditorAssetReference(
        type: EditorAssetType.video,
        label: 'Imported video',
        sourcePath: videoPath,
        metadata: {'durationMs': durationMs},
      );
      nextAssets = [resolvedSourceAsset, ...nextAssets];
    }

    // A populated overlay lane is a complete visual project. Keep an empty
    // main lane available for later inserts, but never recreate the old first
    // video merely because that lane is intentionally empty.
    final baseTrack = _coalesceTrackGroup(
      baseTracks,
      fallback: () => TimelineTrack(
        id: 'track_video_primary',
        name: 'Base layer',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
      ),
    );
    final hasBaseClips = baseTrack.clips.any((clip) => clip.type.isVisualMedia);
    final normalizedBaseTrack = baseTrack.copyWith(
      name: 'Base layer',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.baseVideo,
      clips: hasBaseClips
          ? baseTrack.clips
                .map(
                  (clip) => clip.copyWith(
                    trackId: baseTrack.id,
                    assetId: clip.assetId ?? resolvedSourceAsset?.id,
                  ),
                )
                .toList()
          : shouldSeedLegacyClip && resolvedSourceAsset != null
          ? [
              TimelineClip(
                trackId: baseTrack.id,
                type: TimelineTrackType.video,
                label: resolvedSourceAsset.label,
                assetId: resolvedSourceAsset.id,
                startTime: Duration.zero,
                endTime: Duration(milliseconds: math.max(0, durationMs)),
                sourceStartTime: Duration.zero,
                sourceDuration: Duration(milliseconds: math.max(0, durationMs)),
              ),
            ]
          : const [],
    );
    nextTracks = baseTracks.isEmpty
        ? copyWith(
            tracks: nextTracks,
          ).insertTrackUsingEditorRules(normalizedBaseTrack).tracks
        : _replaceTrackGroup(
            nextTracks,
            matches: (track) => track.section == TimelineTrackSection.baseVideo,
            replacement: normalizedBaseTrack,
          );

    return copyWith(
      subtitleStyle: globalStyle,
      assets: nextAssets,
      tracks: _canonicalizeTimelineTracks(nextTracks),
    ).withoutTrackOverlaps();
  }

  EditorTimeline mergeSubtitleEntries({
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
  }) {
    final canonicalTracks = _canonicalizeTimelineTracks(tracks);
    if (subtitles.isEmpty &&
        !canonicalTracks.any(
          (track) => track.type == TimelineTrackType.subtitle,
        )) {
      return copyWith(subtitleStyle: globalStyle, tracks: canonicalTracks);
    }
    final mergedTracks = _mergedSubtitleTracks(
      canonicalTracks,
      subtitles: subtitles,
    );
    final nextTracks = _replaceTrackGroupWithMany(
      canonicalTracks,
      matches: (track) => track.type == TimelineTrackType.subtitle,
      replacements: mergedTracks,
    );

    return copyWith(
      subtitleStyle: globalStyle,
      tracks: _canonicalizeTimelineTracks(nextTracks),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'canvasSettings': canvasSettings.toJson(),
      'workspaceSettings': workspaceSettings.toJson(),
      'subtitleStyle': subtitleStyle.toJson(),
      'assets': assets.map((asset) => asset.toJson()).toList(),
      'tracks': tracks.map((track) => track.toJson()).toList(),
      'markers': markers.map((marker) => marker.toJson()).toList(),
      'projectEffectStack': projectEffectStack.toJson(),
      'effectContainers': effectContainers
          .map((container) => container.toJson())
          .toList(),
      'effectPresets': effectPresets.map((preset) => preset.toJson()).toList(),
      'groups': groups.map((group) => group.toJson()).toList(),
      'compoundClips': compoundClips
          .map((compound) => compound.toJson())
          .toList(),
      'audioBuses': audioBuses.map((bus) => bus.toJson()).toList(),
      'colorManagement': colorManagement.toJson(),
    };
  }

  factory EditorTimeline.fromJson(Map<String, dynamic> json) {
    final parsed = EditorTimeline(
      schemaVersion: _timelineInt(json['schemaVersion'], fallback: 2),
      canvasSettings: _timelineModelFromJson(
        json['canvasSettings'],
        CanvasSettings.fromJson,
        const CanvasSettings(),
      ),
      workspaceSettings: _timelineModelFromJson(
        json['workspaceSettings'],
        TimelineWorkspaceSettings.fromJson,
        const TimelineWorkspaceSettings(),
      ),
      subtitleStyle: _timelineModelFromJson(
        json['subtitleStyle'],
        SubtitleStyleModel.fromJson,
        const SubtitleStyleModel(),
      ),
      assets: _timelineModelsFromJson(
        json['assets'],
        EditorAssetReference.fromJson,
      ),
      tracks: _timelineModelsFromJson(json['tracks'], TimelineTrack.fromJson),
      markers: _timelineModelsFromJson(
        json['markers'],
        TimelineMarker.fromJson,
      ),
      projectEffectStack: EditorEffectStack.fromJson(
        json['projectEffectStack'],
      ),
      effectContainers: _timelineModelsFromJson(
        json['effectContainers'],
        EditorEffectContainer.fromJson,
      ),
      effectPresets: _timelineModelsFromJson(
        json['effectPresets'],
        EditorEffectPreset.fromJson,
      ),
      groups: _timelineModelsFromJson(json['groups'], TimelineGroup.fromJson),
      compoundClips: _timelineModelsFromJson(
        json['compoundClips'],
        TimelineCompoundClip.fromJson,
      ),
      audioBuses: _timelineModelsFromJson(
        json['audioBuses'],
        TimelineAudioBus.fromJson,
      ),
      colorManagement: EditorColorManagementSettings.fromJson(
        json['colorManagement'],
      ),
    );
    return parsed.canonicalized();
  }

  factory EditorTimeline.fromLegacy({
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
    required String videoPath,
    required int durationMs,
  }) {
    return const EditorTimeline().syncLegacySubtitles(
      subtitles: subtitles,
      globalStyle: globalStyle,
      videoPath: videoPath,
      durationMs: durationMs,
    );
  }
}

List<TimelineTrack> _restoreSeparatedAudioOwnership(
  List<TimelineTrack> tracks,
) {
  final separatedVideoIds = <String>{
    for (final track in tracks)
      for (final clip in track.clips)
        if (clip.type == TimelineTrackType.audio &&
            clip.separatedAudioSourceClipId != null)
          clip.separatedAudioSourceClipId!,
  };
  if (separatedVideoIds.isEmpty) return tracks;
  return tracks.map((track) {
    return track.copyWith(
      clips: track.clips.map((clip) {
        if (clip.type != TimelineTrackType.video ||
            !separatedVideoIds.contains(clip.id) ||
            clip.embeddedAudioSeparated) {
          return clip;
        }
        return clip.copyWith(embeddedAudioSeparated: true);
      }).toList(),
    );
  }).toList();
}

List<TimelineTrack> _mergedSubtitleTracks(
  List<TimelineTrack> tracks, {
  required List<SubtitleEntry> subtitles,
}) {
  final subtitleTracks = tracks
      .where((track) => track.type == TimelineTrackType.subtitle)
      .toList();
  if (subtitleTracks.isEmpty) {
    if (subtitles.isEmpty) return const [];
    final track = TimelineTrack(
      id: 'track_subtitles',
      name: 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
    );
    return [
      track.copyWith(
        clips:
            subtitles
                .map(
                  (entry) =>
                      TimelineClip.fromSubtitleEntry(entry, trackId: track.id),
                )
                .toList()
              ..sort((a, b) => a.startTime.compareTo(b.startTime)),
      ),
    ];
  }

  final entriesById = {for (final entry in subtitles) entry.id: entry};
  final assignedEntryIds = <String>{};
  final merged = <TimelineTrack>[];
  var generalTrackIndex = -1;
  for (final track in subtitleTracks) {
    final hadGeneralCaption = track.clips.any(
      (clip) => clip.linkedClipId == null,
    );
    final clips = <TimelineClip>[];
    for (final existing in track.clips) {
      final entry = entriesById[existing.id];
      if (entry == null || !assignedEntryIds.add(entry.id)) continue;
      clips.add(
        existing.copyWith(
          trackId: track.id,
          type: TimelineTrackType.subtitle,
          label: entry.text,
          startTime: entry.startTime,
          endTime: entry.endTime,
          text: entry.text,
          subtitleStyle: entry.styleOverride,
          clearSubtitleStyle: entry.styleOverride == null,
        ),
      );
    }
    clips.sort((a, b) => a.startTime.compareTo(b.startTime));
    if (generalTrackIndex < 0 && (hadGeneralCaption || track.clips.isEmpty)) {
      generalTrackIndex = merged.length;
    }
    merged.add(
      track.copyWith(
        type: TimelineTrackType.subtitle,
        section: TimelineTrackSection.textSubtitle,
        clips: clips,
      ),
    );
  }

  final unassigned = subtitles
      .where((entry) => !assignedEntryIds.contains(entry.id))
      .toList();
  if (unassigned.isNotEmpty) {
    if (generalTrackIndex < 0) {
      final usedIds = tracks.map((track) => track.id).toSet();
      var id = 'track_subtitles';
      var suffix = 2;
      while (usedIds.contains(id)) {
        id = 'track_subtitles_${suffix++}';
      }
      merged.insert(
        0,
        TimelineTrack(
          id: id,
          name: 'Subtitles',
          type: TimelineTrackType.subtitle,
          section: TimelineTrackSection.textSubtitle,
        ),
      );
      generalTrackIndex = 0;
    }
    final general = merged[generalTrackIndex];
    final clips = [
      ...general.clips,
      ...unassigned.map(
        (entry) => TimelineClip.fromSubtitleEntry(entry, trackId: general.id),
      ),
    ]..sort((a, b) => a.startTime.compareTo(b.startTime));
    merged[generalTrackIndex] = general.copyWith(clips: clips);
  }

  final populated = merged.where((track) => track.clips.isNotEmpty).toList();
  if (populated.isNotEmpty) return populated;
  // Keep one empty lane so deleting the final caption does not also delete the
  // user's subtitle track controls and lock state.
  return [merged.first];
}

TimelineTrack _coalesceTrackGroup(
  List<TimelineTrack> tracks, {
  required TimelineTrack Function() fallback,
}) {
  if (tracks.isEmpty) return fallback();
  final primary = tracks.firstWhere(
    (track) => track.clips.isNotEmpty,
    orElse: () => tracks.first,
  );
  final clipsById = <String, TimelineClip>{};
  for (final track in tracks) {
    for (final clip in track.clips) {
      clipsById.putIfAbsent(clip.id, () => clip.copyWith(trackId: primary.id));
    }
  }
  final clips = clipsById.values.toList()
    ..sort((a, b) => a.startTime.compareTo(b.startTime));
  return primary.copyWith(
    isCollapsed: tracks.any((track) => track.isCollapsed),
    isLocked: tracks.any((track) => track.isLocked),
    isMuted: tracks.any((track) => track.isMuted),
    isHidden: tracks.any((track) => track.isHidden),
    isSolo: tracks.any((track) => track.isSolo),
    audioBusId: primary.audioBusId,
    syncLocked: tracks.any((track) => track.syncLocked),
    effectStack: primary.effectStack,
    clips: clips,
  );
}

List<TimelineTrack> _replaceTrackGroup(
  List<TimelineTrack> tracks, {
  required bool Function(TimelineTrack track) matches,
  required TimelineTrack replacement,
}) {
  final next = <TimelineTrack>[];
  var inserted = false;
  for (final track in tracks) {
    if (!matches(track)) {
      next.add(track);
      continue;
    }
    if (!inserted) {
      next.add(replacement);
      inserted = true;
    }
  }
  if (!inserted) next.add(replacement);
  return next;
}

List<TimelineTrack> _replaceTrackGroupWithMany(
  List<TimelineTrack> tracks, {
  required bool Function(TimelineTrack track) matches,
  required List<TimelineTrack> replacements,
}) {
  final next = <TimelineTrack>[];
  var inserted = false;
  for (final track in tracks) {
    if (!matches(track)) {
      next.add(track);
      continue;
    }
    if (!inserted) {
      next.addAll(replacements);
      inserted = true;
    }
  }
  if (!inserted) next.addAll(replacements);
  return next;
}

List<EditorAssetReference> _canonicalizeAssets(
  Iterable<EditorAssetReference> assets,
) {
  final byId = <String, EditorAssetReference>{};
  for (final asset in assets) {
    byId.putIfAbsent(asset.id, () => asset);
  }
  return byId.values.toList();
}

({
  List<TimelineTrack> tracks,
  List<TimelineGroup> groups,
  List<TimelineCompoundClip> compoundClips,
  List<TimelineAudioBus> audioBuses,
  List<EditorEffectContainer> effectContainers,
  EditorEffectStack projectEffectStack,
})
_canonicalizeTimelineRelationships({
  required List<TimelineTrack> tracks,
  required List<TimelineGroup> groups,
  required List<TimelineCompoundClip> compoundClips,
  required List<TimelineAudioBus> audioBuses,
  required List<EditorEffectContainer> effectContainers,
  required EditorEffectStack projectEffectStack,
}) {
  final clipsById = <String, TimelineClip>{
    for (final track in tracks)
      for (final clip in track.clips) clip.id: clip,
  };
  final trackIds = tracks.map((track) => track.id).toSet();

  final busesById = <String, TimelineAudioBus>{};
  for (final bus in audioBuses) {
    busesById.putIfAbsent(
      bus.id,
      () => bus.copyWith(
        effectStack: _canonicalizeEffectStack(
          bus.effectStack,
          domain: EditorEffectDomain.audio,
        ),
      ),
    );
  }

  final groupsById = <String, TimelineGroup>{};
  for (final group in groups) {
    groupsById.putIfAbsent(group.id, () => group);
  }
  final groupForClip = <String, String>{};
  for (final clip in clipsById.values) {
    final groupId = clip.groupId;
    if (groupId != null && groupsById.containsKey(groupId)) {
      groupForClip[clip.id] = groupId;
    }
  }
  for (final group in groupsById.values) {
    for (final clipId in group.clipIds) {
      if (clipsById.containsKey(clipId)) {
        groupForClip.putIfAbsent(clipId, () => group.id);
      }
    }
  }
  final canonicalGroups = <TimelineGroup>[];
  for (final group in groupsById.values) {
    final declaredClipIds = group.clipIds.toSet();
    final clipIds = <String>[
      ...group.clipIds.where((clipId) => groupForClip[clipId] == group.id),
      ...clipsById.keys.where(
        (clipId) =>
            groupForClip[clipId] == group.id &&
            !declaredClipIds.contains(clipId),
      ),
    ];
    if (clipIds.isNotEmpty) {
      canonicalGroups.add(group.copyWith(clipIds: clipIds));
    }
  }
  final validGroupIds = canonicalGroups.map((group) => group.id).toSet();
  groupForClip.removeWhere((_, groupId) => !validGroupIds.contains(groupId));

  final compoundsById = <String, TimelineCompoundClip>{};
  for (final compound in compoundClips) {
    compoundsById.putIfAbsent(compound.id, () => compound);
  }
  final compoundForClip = <String, String>{};
  for (final clip in clipsById.values.where(
    (candidate) => candidate.type.isVisualMedia,
  )) {
    final compoundId = clip.compoundId;
    if (compoundId != null && compoundsById.containsKey(compoundId)) {
      compoundForClip[clip.id] = compoundId;
    }
  }
  for (final compound in compoundsById.values) {
    for (final clipId in compound.clipIds) {
      if (clipsById[clipId]?.type.isVisualMedia == true) {
        compoundForClip.putIfAbsent(clipId, () => compound.id);
      }
    }
  }
  final canonicalCompounds = <TimelineCompoundClip>[];
  for (final compound in compoundsById.values) {
    final declaredClipIds = compound.clipIds.toSet();
    final clipIds = <String>[
      ...compound.clipIds.where(
        (clipId) => compoundForClip[clipId] == compound.id,
      ),
      ...clipsById.keys.where(
        (clipId) =>
            compoundForClip[clipId] == compound.id &&
            !declaredClipIds.contains(clipId),
      ),
    ];
    if (clipIds.isNotEmpty) {
      canonicalCompounds.add(compound.copyWith(clipIds: clipIds));
    }
  }
  final validCompoundIds = canonicalCompounds
      .map((compound) => compound.id)
      .toSet();
  compoundForClip.removeWhere(
    (_, compoundId) => !validCompoundIds.contains(compoundId),
  );

  final clipContainerStacks = <String, EditorEffectStack>{};
  final trackContainerStacks = <String, EditorEffectStack>{};
  final busContainerStacks = <String, EditorEffectStack>{};
  var canonicalProjectStack = _canonicalizeEffectStack(projectEffectStack);
  final scopedContainers = <String, EditorEffectContainer>{};
  for (final container in effectContainers) {
    final stack = _canonicalizeEffectStack(
      container.enabled
          ? container.stack
          : EditorEffectStack(
              effects: container.stack.effects
                  .map((effect) => effect.copyWith(enabled: false))
                  .toList(),
            ),
    );
    switch (container.scope) {
      case EditorEffectScope.project:
        canonicalProjectStack = _mergeEffectStacks(
          canonicalProjectStack,
          stack,
        );
      case EditorEffectScope.clip:
        if (clipsById.containsKey(container.targetId)) {
          clipContainerStacks[container.targetId] = _mergeEffectStacks(
            clipContainerStacks[container.targetId] ??
                const EditorEffectStack(),
            stack,
          );
        }
      case EditorEffectScope.adjustmentLayer:
        if (clipsById[container.targetId]?.isAdjustmentLayer == true) {
          clipContainerStacks[container.targetId] = _mergeEffectStacks(
            clipContainerStacks[container.targetId] ??
                const EditorEffectStack(),
            stack,
          );
        }
      case EditorEffectScope.track:
        if (trackIds.contains(container.targetId)) {
          trackContainerStacks[container.targetId] = _mergeEffectStacks(
            trackContainerStacks[container.targetId] ??
                const EditorEffectStack(),
            stack,
          );
        }
      case EditorEffectScope.audioBus:
        if (busesById.containsKey(container.targetId)) {
          busContainerStacks[container.targetId] = _mergeEffectStacks(
            busContainerStacks[container.targetId] ?? const EditorEffectStack(),
            stack,
          );
        }
      case EditorEffectScope.group:
      case EditorEffectScope.compound:
        final targetExists = container.scope == EditorEffectScope.group
            ? validGroupIds.contains(container.targetId)
            : validCompoundIds.contains(container.targetId);
        if (!targetExists) continue;
        final key = '${container.scope.name}:${container.targetId}';
        final existing = scopedContainers[key];
        scopedContainers[key] = EditorEffectContainer(
          id: existing?.id ?? container.id,
          scope: container.scope,
          targetId: container.targetId,
          label: existing?.label ?? container.label,
          stack: _mergeEffectStacks(
            existing?.stack ?? const EditorEffectStack(),
            stack,
          ),
        );
    }
  }

  final canonicalTracks = tracks.map((track) {
    final containerStack = trackContainerStacks[track.id];
    final trackStack = _mergeEffectStacks(
      _canonicalizeEffectStack(track.effectStack),
      containerStack ?? const EditorEffectStack(),
    );
    return track.copyWith(
      clearAudioBusId:
          track.audioBusId != null && !busesById.containsKey(track.audioBusId),
      effectStack: trackStack,
      clips: track.clips.map((clip) {
        final groupId = groupForClip[clip.id];
        final compoundId = compoundForClip[clip.id];
        return clip.copyWith(
          groupId: groupId,
          clearGroupId: groupId == null,
          compoundId: compoundId,
          clearCompoundId: compoundId == null,
          effectStack: _mergeEffectStacks(
            _canonicalizeEffectStack(clip.effectStack),
            clipContainerStacks[clip.id] ?? const EditorEffectStack(),
          ),
        );
      }).toList(),
    );
  }).toList();

  final canonicalBuses = busesById.values.map((bus) {
    return bus.copyWith(
      effectStack: _mergeEffectStacks(
        bus.effectStack,
        busContainerStacks[bus.id] ?? const EditorEffectStack(),
        domain: EditorEffectDomain.audio,
      ),
    );
  }).toList();

  return (
    tracks: canonicalTracks,
    groups: canonicalGroups,
    compoundClips: canonicalCompounds,
    audioBuses: canonicalBuses,
    effectContainers: scopedContainers.values.toList(),
    projectEffectStack: canonicalProjectStack,
  );
}

EditorEffectStack _mergeEffectStacks(
  EditorEffectStack first,
  EditorEffectStack second, {
  EditorEffectDomain? domain,
}) {
  return _canonicalizeEffectStack(
    EditorEffectStack(effects: [...first.effects, ...second.effects]),
    domain: domain,
  );
}

EditorEffectStack _canonicalizeEffectStack(
  EditorEffectStack stack, {
  EditorEffectDomain? domain,
}) {
  final ids = <String>{};
  final effects = <EditorEffect>[];
  for (final effect in stack.effects) {
    if (domain != null && effect.domain != domain) continue;
    final normalized = ids.add(effect.id) ? effect : effect.cloneWithNewId();
    ids.add(normalized.id);
    effects.add(normalized);
  }
  return EditorEffectStack(effects: effects);
}

List<EditorEffectPreset> _canonicalizeEffectPresets(
  Iterable<EditorEffectPreset> presets,
) {
  final byId = <String, EditorEffectPreset>{};
  for (final preset in presets) {
    byId.putIfAbsent(
      preset.id,
      () => EditorEffectPreset(
        id: preset.id,
        name: preset.name.trim().isEmpty ? 'Preset' : preset.name.trim(),
        description: preset.description,
        stack: _canonicalizeEffectStack(preset.stack),
        createdAt: preset.createdAt,
      ),
    );
  }
  return byId.values.toList();
}

EditorColorManagementSettings _canonicalizeColorManagement(
  EditorColorManagementSettings settings,
) {
  final lutsById = <String, EditorLutAsset>{};
  for (final lut in settings.luts) {
    if (lut.path.trim().isEmpty) continue;
    lutsById.putIfAbsent(lut.id, () => lut);
  }
  final workingSpace = settings.workingSpace == EditorColorSpace.automatic
      ? EditorColorSpace.sdr709
      : settings.workingSpace;
  final outputSpace = switch (settings.outputSpace) {
    EditorColorSpace.automatic ||
    EditorColorSpace.log => EditorColorSpace.sdr709,
    _ => settings.outputSpace,
  };
  return settings.copyWith(
    workingSpace: workingSpace,
    outputSpace: outputSpace,
    preserveHdr:
        settings.preserveHdr &&
        (outputSpace == EditorColorSpace.hlg ||
            outputSpace == EditorColorSpace.pq ||
            outputSpace == EditorColorSpace.wideGamut),
    luts: lutsById.values.toList(),
  );
}

List<TimelineTrack> _canonicalizeTimelineTracks(
  Iterable<TimelineTrack> tracks,
) {
  final byId = <String, TimelineTrack>{};
  for (final sourceTrack in tracks) {
    final trackId = sourceTrack.id.trim().isEmpty
        ? const Uuid().v4()
        : sourceTrack.id;
    final localClipIds = <String>{};
    final normalizedClips = <TimelineClip>[];
    for (final sourceClip in sourceTrack.clips) {
      final clipId = sourceClip.id.trim().isEmpty
          ? const Uuid().v4()
          : sourceClip.id;
      if (!localClipIds.add(clipId)) continue;
      normalizedClips.add(
        sourceClip.copyWith(
          id: clipId,
          trackId: trackId,
          clearAssetId: sourceClip.type == TimelineTrackType.effect,
        ),
      );
    }
    // `effect` remains a clip discriminator for backwards-compatible project
    // files, but effects no longer own a dedicated lane. Migrate old effect
    // lanes into ordinary overlay lanes as projects are read or saved.
    final normalizedTrack = sourceTrack.copyWith(
      id: trackId,
      name: sourceTrack.type == TimelineTrackType.effect
          ? sourceTrack.name.replaceFirst(
              RegExp(r'^Effects?', caseSensitive: false),
              'Overlay',
            )
          : sourceTrack.section == TimelineTrackSection.baseVideo
          ? 'Base layer'
          : sourceTrack.name,
      type: sourceTrack.type == TimelineTrackType.effect
          ? TimelineTrackType.video
          : sourceTrack.type,
      section: sourceTrack.type == TimelineTrackType.effect
          ? TimelineTrackSection.overlay
          : sourceTrack.section,
      role: sourceTrack.role == TimelineTrackRole.sourceVideo
          ? TimelineTrackRole.regular
          : sourceTrack.role,
      clips: normalizedClips,
    );
    final existing = byId[trackId];
    if (existing == null) {
      byId[trackId] = normalizedTrack;
      continue;
    }
    final primary = existing.clips.isEmpty && normalizedTrack.clips.isNotEmpty
        ? normalizedTrack
        : existing;
    final mergedClips = <String, TimelineClip>{};
    for (final clip in [...existing.clips, ...normalizedTrack.clips]) {
      mergedClips.putIfAbsent(clip.id, () => clip.copyWith(trackId: trackId));
    }
    byId[trackId] = primary.copyWith(
      id: trackId,
      isCollapsed: existing.isCollapsed || normalizedTrack.isCollapsed,
      isLocked: existing.isLocked || normalizedTrack.isLocked,
      isMuted: existing.isMuted || normalizedTrack.isMuted,
      isHidden: existing.isHidden || normalizedTrack.isHidden,
      isSolo: existing.isSolo || normalizedTrack.isSolo,
      clips: mergedClips.values.toList(),
    );
  }

  final globalClipIds = <String>{};
  return byId.values.map((track) {
    final uniqueClips =
        track.clips
            .where((clip) => globalClipIds.add(clip.id))
            .map((clip) => clip.copyWith(trackId: track.id))
            .toList()
          ..sort((a, b) => a.startTime.compareTo(b.startTime));
    return track.copyWith(clips: uniqueClips);
  }).toList();
}

/// Collapses the automatic embedded-audio duplication produced by older
/// builds. Only an exact, one-to-one mirror is folded back into its linked base
/// video. Any timing/source divergence, ambiguous duplicate, or independently
/// managed lane remains untouched so a user's audio edit cannot be lost.
List<TimelineTrack> _foldRedundantLegacySourceAudio(
  List<TimelineTrack> tracks,
) {
  final baseVideosById = <String, TimelineClip>{};
  for (final track in tracks) {
    if (track.section != TimelineTrackSection.baseVideo) continue;
    for (final clip in track.clips) {
      if (clip.type == TimelineTrackType.video) {
        baseVideosById[clip.id] = clip;
      }
    }
  }
  if (baseVideosById.isEmpty) return tracks;

  final candidatesByBaseId =
      <String, List<({TimelineTrack track, TimelineClip audio})>>{};
  for (final track in tracks) {
    if (track.role != TimelineTrackRole.sourceAudio ||
        track.isHidden ||
        track.isSolo) {
      continue;
    }
    for (final audio in track.clips) {
      final linkedId = audio.linkedClipId;
      final base = linkedId == null ? null : baseVideosById[linkedId];
      if (base == null || !_isExactLegacyAudioMirror(base, audio)) continue;
      candidatesByBaseId.putIfAbsent(base.id, () => []).add((
        track: track,
        audio: audio,
      ));
    }
  }

  final foldedAudioByBaseId =
      <String, ({TimelineTrack track, TimelineClip audio})>{};
  final foldedAudioIds = <String>{};
  for (final entry in candidatesByBaseId.entries) {
    // More than one matching clip is ambiguous and therefore preserved.
    if (entry.value.length != 1) continue;
    final candidate = entry.value.single;
    foldedAudioByBaseId[entry.key] = candidate;
    foldedAudioIds.add(candidate.audio.id);
  }
  if (foldedAudioIds.isEmpty) return tracks;

  final next = <TimelineTrack>[];
  for (final track in tracks) {
    if (track.section == TimelineTrackSection.baseVideo) {
      next.add(
        track.copyWith(
          clips: track.clips.map((clip) {
            final folded = foldedAudioByBaseId[clip.id];
            if (folded == null) return clip;
            final audio = folded.audio;
            return clip.copyWith(
              audioMix: audio.audioMix.copyWith(
                muted:
                    audio.audioMix.muted ||
                    folded.track.isMuted ||
                    !audio.enabled,
              ),
              autoDuck: audio.autoDuck,
              duckAmount: audio.duckAmount,
              duckAttackMs: audio.duckAttackMs,
              duckReleaseMs: audio.duckReleaseMs,
              duckSidechainTrackIds: audio.duckSidechainTrackIds,
            );
          }).toList(),
        ),
      );
      continue;
    }
    if (track.role == TimelineTrackRole.sourceAudio) {
      final remaining = track.clips
          .where((clip) => !foldedAudioIds.contains(clip.id))
          .toList();
      if (remaining.isEmpty) continue;
      next.add(track.copyWith(clips: remaining));
      continue;
    }
    next.add(track);
  }
  return next;
}

bool _isExactLegacyAudioMirror(TimelineClip base, TimelineClip audio) {
  return base.audioMix.muted &&
      base.assetId != null &&
      audio.type == TimelineTrackType.audio &&
      audio.assetId == base.assetId &&
      audio.linkedClipId == base.id &&
      audio.startTime == base.startTime &&
      audio.endTime == base.endTime &&
      audio.sourceStartTime == base.sourceStartTime &&
      audio.sourceDuration == base.sourceDuration &&
      (audio.playbackRate - base.playbackRate).abs() < 0.0001 &&
      audio.isReversed == base.isReversed &&
      audio.freezeFrame == base.freezeFrame &&
      audio.freezeFrameSourceTime == base.freezeFrameSourceTime &&
      audio.denoise == base.denoise &&
      audio.keyframes.isEmpty &&
      audio.introTransition.type == TransitionType.none &&
      audio.outroTransition.type == TransitionType.none &&
      (audio.notes == null || audio.notes!.trim().isEmpty) &&
      audio.timelineColor.a == 0;
}

/// Schema 4 and earlier stored the base layer first and appended visual layers.
/// Schema 5+ stores exactly what the timeline shows: topmost visual lane first,
/// the main storyline in the middle, and audio beneath it.
List<TimelineTrack> _migrateLegacyTrackOrder(List<TimelineTrack> tracks) {
  final text = tracks
      .where((track) => track.section == TimelineTrackSection.textSubtitle)
      .toList()
      .reversed;
  final overlays = tracks
      .where((track) => track.section == TimelineTrackSection.overlay)
      .toList()
      .reversed;
  final mainVideo = tracks.where(
    (track) => track.section == TimelineTrackSection.baseVideo,
  );
  final sourceAudio = tracks.where(
    (track) => track.role == TimelineTrackRole.sourceAudio,
  );
  final regularAudio = tracks.where(
    (track) =>
        track.section == TimelineTrackSection.audio &&
        track.role != TimelineTrackRole.sourceAudio,
  );
  return List.unmodifiable([
    ...text,
    ...overlays,
    ...mainVideo,
    ...sourceAudio,
    ...regularAudio,
  ]);
}

TimelineTrackType _trackTypeFromJson(dynamic value) {
  return TimelineTrackType.values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () => TimelineTrackType.subtitle,
  );
}

TimelineTrackSection _defaultSectionForType(TimelineTrackType type) {
  switch (type) {
    case TimelineTrackType.audio:
      return TimelineTrackSection.audio;
    case TimelineTrackType.subtitle:
    case TimelineTrackType.text:
      return TimelineTrackSection.textSubtitle;
    case TimelineTrackType.video:
      return TimelineTrackSection.baseVideo;
    case TimelineTrackType.image:
    case TimelineTrackType.sticker:
    case TimelineTrackType.gif:
    case TimelineTrackType.effect:
      return TimelineTrackSection.overlay;
  }
}

TimelineTrackRole _trackRoleFromJson(
  Object? value, {
  required String? id,
  required String? name,
  required TimelineTrackType type,
  required TimelineTrackSection section,
}) {
  final persisted = TimelineTrackRole.values.where(
    (candidate) => candidate.name == value,
  );
  if (persisted.isNotEmpty) {
    return persisted.first == TimelineTrackRole.sourceVideo
        ? TimelineTrackRole.regular
        : persisted.first;
  }
  final normalizedId = id?.trim().toLowerCase() ?? '';
  final normalizedName = name?.trim().toLowerCase() ?? '';
  if (type == TimelineTrackType.audio &&
      (normalizedId == 'track_audio_source' ||
          normalizedName == 'source audio' ||
          normalizedName == 'source video audio')) {
    return TimelineTrackRole.sourceAudio;
  }
  return TimelineTrackRole.regular;
}

int _colorToInt(Color color) {
  final a = (color.a * 255.0).round().clamp(0, 255);
  final r = (color.r * 255.0).round().clamp(0, 255);
  final g = (color.g * 255.0).round().clamp(0, 255);
  final b = (color.b * 255.0).round().clamp(0, 255);
  return (a << 24) | (r << 16) | (g << 8) | b;
}
