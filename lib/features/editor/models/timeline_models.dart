import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'subtitle_entry.dart';
import 'subtitle_style_model.dart';
import 'word_timing.dart';

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
}

enum TimelineMarkerType { marker, chapter, beat }

enum TimelineKeyframeProperty {
  opacity,
  scale,
  rotation,
  positionX,
  positionY,
  volume,
  blurStrength,
}

/// A non-destructive value change stored relative to the start of a clip.
/// Keyframes are deliberately small and serializable so they remain safe for
/// older projects and can be interpolated by both preview and export paths.
class TimelineKeyframe {
  final String id;
  final Duration time;
  final TimelineKeyframeProperty property;
  final double value;

  TimelineKeyframe({
    String? id,
    required this.time,
    required this.property,
    required this.value,
  }) : id = id ?? const Uuid().v4();

  TimelineKeyframe copyWith({
    Duration? time,
    TimelineKeyframeProperty? property,
    double? value,
  }) {
    return TimelineKeyframe(
      id: id,
      time: time ?? this.time,
      property: property ?? this.property,
      value: value ?? this.value,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'timeMs': time.inMilliseconds,
      'property': property.name,
      'value': value,
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
    };
  }

  factory TimelineWorkspaceSettings.fromJson(Map<String, dynamic> json) {
    return TimelineWorkspaceSettings(
      frameRate: (json['frameRate'] as num?)?.toInt() ?? 30,
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

  bool get supportsVisualEffects => isVisualMedia;

  bool get supportsTransform {
    return isVisualMedia || this == TimelineTrackType.text;
  }

  /// Generic clip transitions are rendered by the visual-media pipeline.
  /// Text uses its dedicated subtitle/text animation presets instead.
  bool get supportsClipAnimation => isVisualMedia;

  bool get canCarryAudio {
    return this == TimelineTrackType.video || this == TimelineTrackType.audio;
  }
}

/// A non-destructive crop stored as normalized source-space insets.
///
/// The same model is used for base video and every visual overlay type, which
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
  final double brightness;
  final double contrast;
  final double saturation;
  final double temperature;
  final double fade;
  final double vignette;
  final double sharpen;

  const ClipColorAdjustments({
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.temperature = 0,
    this.fade = 0,
    this.vignette = 0,
    this.sharpen = 0,
  });

  bool get isNeutral =>
      brightness == 0 &&
      contrast == 1 &&
      saturation == 1 &&
      temperature == 0 &&
      fade == 0 &&
      vignette == 0 &&
      sharpen == 0;

  ClipColorAdjustments copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? temperature,
    double? fade,
    double? vignette,
    double? sharpen,
  }) {
    return ClipColorAdjustments(
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      temperature: temperature ?? this.temperature,
      fade: fade ?? this.fade,
      vignette: vignette ?? this.vignette,
      sharpen: sharpen ?? this.sharpen,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'brightness': brightness,
      'contrast': contrast,
      'saturation': saturation,
      'temperature': temperature,
      'fade': fade,
      'vignette': vignette,
      'sharpen': sharpen,
    };
  }

  factory ClipColorAdjustments.fromJson(Map<String, dynamic> json) {
    return ClipColorAdjustments(
      brightness: (json['brightness'] as num?)?.toDouble() ?? 0,
      contrast: (json['contrast'] as num?)?.toDouble() ?? 1,
      saturation: (json['saturation'] as num?)?.toDouble() ?? 1,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0,
      fade: (json['fade'] as num?)?.toDouble() ?? 0,
      vignette: (json['vignette'] as num?)?.toDouble() ?? 0,
      sharpen: (json['sharpen'] as num?)?.toDouble() ?? 0,
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

  const AudioMixSettings({
    this.volume = 1,
    this.muted = false,
    this.fadeInMs = 0,
    this.fadeOutMs = 0,
    this.pan = 0,
    this.normalize = false,
  });

  bool get hasMixAdjustment =>
      (volume - 1).abs() > 0.0001 ||
      pan.abs() > 0.0001 ||
      normalize ||
      muted ||
      fadeInMs > 0 ||
      fadeOutMs > 0;

  AudioMixSettings copyWith({
    double? volume,
    bool? muted,
    int? fadeInMs,
    int? fadeOutMs,
    double? pan,
    bool? normalize,
  }) {
    return AudioMixSettings(
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
      fadeInMs: fadeInMs ?? this.fadeInMs,
      fadeOutMs: fadeOutMs ?? this.fadeOutMs,
      pan: pan ?? this.pan,
      normalize: normalize ?? this.normalize,
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
  final String label;
  final String? assetId;
  final String? linkedClipId;
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

  TimelineClip({
    String? id,
    required this.trackId,
    required this.type,
    this.effectKind,
    required this.label,
    required this.startTime,
    required this.endTime,
    this.assetId,
    this.linkedClipId,
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
  }) : id = id ?? const Uuid().v4(),
       sourceStartTime = sourceStartTime ?? Duration.zero,
       sourceDuration = sourceDuration ?? (endTime - startTime),
       keyframes = List.unmodifiable(keyframes ?? const []);

  Duration get duration => endTime - startTime;
  bool get isEffect => type == TimelineTrackType.effect && effectKind != null;

  factory TimelineClip.effect({
    String? id,
    required String trackId,
    required TimelineEffectKind effectKind,
    required String label,
    required Duration startTime,
    required Duration endTime,
    ClipBlurSettings blur = const ClipBlurSettings(),
    ClipColorAdjustments colorAdjustments = const ClipColorAdjustments(),
    int layer = 0,
    bool enabled = true,
  }) {
    return TimelineClip(
      id: id,
      trackId: trackId,
      type: TimelineTrackType.effect,
      effectKind: effectKind,
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
    String? label,
    String? assetId,
    bool clearAssetId = false,
    String? linkedClipId,
    bool clearLinkedClipId = false,
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
  }) {
    return TimelineClip(
      id: id ?? this.id,
      trackId: trackId ?? this.trackId,
      type: type ?? this.type,
      effectKind: clearEffectKind ? null : (effectKind ?? this.effectKind),
      label: label ?? this.label,
      assetId: clearAssetId ? null : (assetId ?? this.assetId),
      linkedClipId: clearLinkedClipId
          ? null
          : (linkedClipId ?? this.linkedClipId),
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
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'trackId': trackId,
      'type': type.name,
      'effectKind': effectKind?.name,
      'label': label,
      'assetId': assetId,
      'linkedClipId': linkedClipId,
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
      label: json['label'] as String? ?? 'Untitled clip',
      assetId: json['assetId'] as String?,
      linkedClipId: json['linkedClipId'] as String?,
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
  bool get supportsTransform => type.supportsTransform;
  bool get supportsClipAnimation => type.supportsClipAnimation;
  bool get supportsSourceTiming => type.supportsSourceTiming;
  bool get supportsReversePlayback => type.supportsReversePlayback;
  bool get canCarryAudio => type.canCarryAudio;

  bool get hasKeyframes => keyframes.isNotEmpty;

  bool get hasAdvancedProcessing =>
      freezeFrame ||
      stabilize ||
      denoise ||
      chromaKeyEnabled ||
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
            .clamp(0.0, 1.0);
        return previous.value + (next.value - previous.value) * progress;
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
  final bool isCollapsed;
  final bool isLocked;
  final bool isMuted;
  final bool isHidden;
  final bool isSolo;
  final List<TimelineClip> clips;

  TimelineTrack({
    String? id,
    required this.name,
    required this.type,
    TimelineTrackSection? section,
    this.isCollapsed = false,
    this.isLocked = false,
    this.isMuted = false,
    this.isHidden = false,
    this.isSolo = false,
    List<TimelineClip>? clips,
  }) : id = id ?? const Uuid().v4(),
       section = section ?? _defaultSectionForType(type),
       clips = clips ?? const [];

  TimelineTrack copyWith({
    String? id,
    String? name,
    TimelineTrackType? type,
    TimelineTrackSection? section,
    bool? isCollapsed,
    bool? isLocked,
    bool? isMuted,
    bool? isHidden,
    bool? isSolo,
    List<TimelineClip>? clips,
  }) {
    return TimelineTrack(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      section: section ?? this.section,
      isCollapsed: isCollapsed ?? this.isCollapsed,
      isLocked: isLocked ?? this.isLocked,
      isMuted: isMuted ?? this.isMuted,
      isHidden: isHidden ?? this.isHidden,
      isSolo: isSolo ?? this.isSolo,
      clips: clips ?? this.clips,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'section': section.name,
      'isCollapsed': isCollapsed,
      'isLocked': isLocked,
      'isMuted': isMuted,
      'isHidden': isHidden,
      'isSolo': isSolo,
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
      isCollapsed: json['isCollapsed'] as bool? ?? false,
      isLocked: json['isLocked'] as bool? ?? false,
      isMuted: json['isMuted'] as bool? ?? false,
      isHidden: json['isHidden'] as bool? ?? false,
      isSolo: json['isSolo'] as bool? ?? false,
      clips: _timelineModelsFromJson(json['clips'], TimelineClip.fromJson),
    );
  }
}

extension TimelineTrackCompatibility on TimelineTrack {
  /// Whether this lane can safely contain [clipType].
  ///
  /// Visual overlay lanes are intentionally media-agnostic so an image, GIF,
  /// sticker or overlay video can share a lane. Text, subtitle, audio and effect
  /// lanes stay strict because their preview/export paths are type-specific.
  bool acceptsClipType(TimelineTrackType clipType) {
    switch (section) {
      case TimelineTrackSection.baseVideo:
        return type == TimelineTrackType.video &&
            clipType == TimelineTrackType.video;
      case TimelineTrackSection.overlay:
        if (type == TimelineTrackType.effect) {
          return clipType == TimelineTrackType.effect;
        }
        return type.isVisualMedia && clipType.isVisualMedia;
      case TimelineTrackSection.textSubtitle:
        return type == clipType && clipType.isTextContent;
      case TimelineTrackSection.audio:
        return type == TimelineTrackType.audio &&
            clipType == TimelineTrackType.audio;
    }
  }

  bool acceptsClip(TimelineClip clip) => acceptsClipType(clip.type);
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
  final int schemaVersion;
  final CanvasSettings canvasSettings;
  final TimelineWorkspaceSettings workspaceSettings;
  final SubtitleStyleModel subtitleStyle;
  final List<EditorAssetReference> assets;
  final List<TimelineTrack> tracks;
  final List<TimelineMarker> markers;

  const EditorTimeline({
    this.schemaVersion = 4,
    this.canvasSettings = const CanvasSettings(),
    this.workspaceSettings = const TimelineWorkspaceSettings(),
    this.subtitleStyle = const SubtitleStyleModel(),
    this.assets = const [],
    this.tracks = const [],
    this.markers = const [],
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
    // Captions are one system-managed lane. Legacy projects can contain
    // duplicates, but persistence coalesces them, including their lock state;
    // never route an edit around a locked duplicate only to relock it on save.
    if (clipType == TimelineTrackType.subtitle &&
        tracks.any(
          (track) => track.type == TimelineTrackType.subtitle && track.isLocked,
        )) {
      return null;
    }
    final candidates = tracks.where(
      (track) =>
          track.section == section &&
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
        return 'Video ${sectionTracks.length + 1}';
      case TimelineTrackSection.textSubtitle:
        final textTracks = sectionTracks
            .where((track) => track.type == TimelineTrackType.text)
            .length;
        return 'Text ${textTracks + 1}';
      case TimelineTrackSection.audio:
        return 'Audio ${sectionTracks.length + 1}';
    }
  }

  List<SubtitleEntry> get subtitleEntries {
    final track = primarySubtitleTrack;
    if (track == null) return const [];
    return track.clips
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

  Duration get baseVideoDuration {
    return tracks
        .where((track) => track.section == TimelineTrackSection.baseVideo)
        .expand((track) => track.clips)
        .fold<Duration>(
          Duration.zero,
          (current, clip) => clip.endTime > current ? clip.endTime : current,
        );
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
  }) {
    return EditorTimeline(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      canvasSettings: canvasSettings ?? this.canvasSettings,
      workspaceSettings: workspaceSettings ?? this.workspaceSettings,
      subtitleStyle: subtitleStyle ?? this.subtitleStyle,
      assets: assets ?? this.assets,
      tracks: tracks ?? this.tracks,
      markers: markers ?? this.markers,
    );
  }

  EditorTimeline canonicalized() {
    return copyWith(
      assets: _canonicalizeAssets(assets),
      tracks: _canonicalizeTimelineTracks(tracks),
    );
  }

  EditorTimeline syncLegacySubtitles({
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
    required String videoPath,
    required int durationMs,
  }) {
    final canonicalTracks = _canonicalizeTimelineTracks(tracks);
    final subtitleTrack = _mergedSubtitleTrack(
      canonicalTracks,
      subtitles: subtitles,
    );
    var nextTracks = _replaceTrackGroup(
      canonicalTracks,
      matches: (track) => track.type == TimelineTrackType.subtitle,
      replacement: subtitleTrack,
    );

    final canonicalAssets = _canonicalizeAssets(assets);
    EditorAssetReference? existingSourceAsset;
    for (final asset in canonicalAssets) {
      if (asset.type == EditorAssetType.video &&
          asset.sourcePath == videoPath) {
        existingSourceAsset = asset;
        break;
      }
    }
    final resolvedSourceAsset =
        existingSourceAsset ??
        EditorAssetReference(
          type: EditorAssetType.video,
          label: 'Source video',
          sourcePath: videoPath,
          metadata: {'durationMs': durationMs},
        );
    final nextAssets = existingSourceAsset == null
        ? [resolvedSourceAsset, ...canonicalAssets]
        : canonicalAssets;

    final baseTracks = nextTracks
        .where((track) => track.section == TimelineTrackSection.baseVideo)
        .toList();
    final baseTrack = _coalesceTrackGroup(
      baseTracks,
      fallback: () => TimelineTrack(
        id: 'track_video_primary',
        name: 'Video 1',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
      ),
    );
    final hasBaseClips = baseTrack.clips.any(
      (clip) => clip.type == TimelineTrackType.video,
    );
    final normalizedBaseTrack = baseTrack.copyWith(
      type: TimelineTrackType.video,
      section: TimelineTrackSection.baseVideo,
      clips: hasBaseClips
          ? baseTrack.clips
                .map(
                  (clip) => clip.copyWith(
                    trackId: baseTrack.id,
                    assetId: clip.assetId ?? resolvedSourceAsset.id,
                  ),
                )
                .toList()
          : [
              TimelineClip(
                trackId: baseTrack.id,
                type: TimelineTrackType.video,
                label: 'Source video',
                assetId: resolvedSourceAsset.id,
                startTime: Duration.zero,
                endTime: Duration(milliseconds: math.max(0, durationMs)),
                sourceStartTime: Duration.zero,
                sourceDuration: Duration(milliseconds: math.max(0, durationMs)),
              ),
            ],
    );
    nextTracks = _replaceTrackGroup(
      nextTracks,
      matches: (track) => track.section == TimelineTrackSection.baseVideo,
      replacement: normalizedBaseTrack,
      insertAtStartWhenMissing: true,
    );

    return copyWith(
      subtitleStyle: globalStyle,
      assets: nextAssets,
      tracks: _canonicalizeTimelineTracks(nextTracks),
    );
  }

  EditorTimeline mergeSubtitleEntries({
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
  }) {
    final canonicalTracks = _canonicalizeTimelineTracks(tracks);
    final mergedTrack = _mergedSubtitleTrack(
      canonicalTracks,
      subtitles: subtitles,
    );
    final nextTracks = _replaceTrackGroup(
      canonicalTracks,
      matches: (track) => track.type == TimelineTrackType.subtitle,
      replacement: mergedTrack,
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

TimelineTrack _mergedSubtitleTrack(
  List<TimelineTrack> tracks, {
  required List<SubtitleEntry> subtitles,
}) {
  final subtitleTracks = tracks
      .where((track) => track.type == TimelineTrackType.subtitle)
      .toList();
  final primary = _coalesceTrackGroup(
    subtitleTracks,
    fallback: () => TimelineTrack(
      id: 'track_subtitles',
      name: 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
    ),
  );
  final existingById = <String, TimelineClip>{};
  for (final track in subtitleTracks) {
    for (final clip in track.clips) {
      existingById.putIfAbsent(clip.id, () => clip);
    }
  }
  final clips = subtitles.map((entry) {
    final existing = existingById[entry.id];
    if (existing == null) {
      return TimelineClip.fromSubtitleEntry(entry, trackId: primary.id);
    }
    return existing.copyWith(
      trackId: primary.id,
      type: TimelineTrackType.subtitle,
      label: entry.text,
      startTime: entry.startTime,
      endTime: entry.endTime,
      text: entry.text,
      subtitleStyle: entry.styleOverride,
      clearSubtitleStyle: entry.styleOverride == null,
    );
  }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
  return primary.copyWith(
    type: TimelineTrackType.subtitle,
    section: TimelineTrackSection.textSubtitle,
    clips: clips,
  );
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
    clips: clips,
  );
}

List<TimelineTrack> _replaceTrackGroup(
  List<TimelineTrack> tracks, {
  required bool Function(TimelineTrack track) matches,
  required TimelineTrack replacement,
  bool insertAtStartWhenMissing = false,
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
  if (!inserted) {
    if (insertAtStartWhenMissing) {
      next.insert(0, replacement);
    } else {
      next.add(replacement);
    }
  }
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
    final normalizedTrack = sourceTrack.copyWith(
      id: trackId,
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

int _colorToInt(Color color) {
  final a = (color.a * 255.0).round().clamp(0, 255);
  final r = (color.r * 255.0).round().clamp(0, 255);
  final g = (color.g * 255.0).round().clamp(0, 255);
  final b = (color.b * 255.0).round().clamp(0, 255);
  return (a << 24) | (r << 16) | (g << 8) | b;
}
