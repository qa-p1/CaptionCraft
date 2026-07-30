import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'subtitle_entry.dart';
import 'subtitle_style_model.dart';

/// Stable editor-space coordinates used by preview gestures and export.
///
/// Persisting transforms in a device-independent space keeps projects visually
/// identical on different phones, tablets, and output resolutions.
const double kTimelineDesignWidth = 390;
const double kTimelineDesignHeight = 360;

enum TimelineTrackType { video, audio, subtitle, text, image, sticker, gif }

enum TimelineTrackSection { overlay, baseVideo, textSubtitle, audio }

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
      metadata: (json['metadata'] as Map<String, dynamic>?) ?? const {},
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
      position: Duration(
        milliseconds: (json['positionMs'] as num?)?.toInt() ?? 0,
      ),
      label: json['label'] as String? ?? 'Marker',
      type: TimelineMarkerType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => TimelineMarkerType.marker,
      ),
      color: Color(json['color'] as int? ?? 0xFFFF9A62),
    );
  }
}

class TimelineClip {
  final String id;
  final String trackId;
  final TimelineTrackType type;
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

  TimelineClip({
    String? id,
    required this.trackId,
    required this.type,
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
  }) : id = id ?? const Uuid().v4(),
       sourceStartTime = sourceStartTime ?? Duration.zero,
       sourceDuration = sourceDuration ?? (endTime - startTime);

  Duration get duration => endTime - startTime;

  TimelineClip copyWith({
    String? id,
    String? trackId,
    TimelineTrackType? type,
    String? label,
    String? assetId,
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
  }) {
    return TimelineClip(
      id: id ?? this.id,
      trackId: trackId ?? this.trackId,
      type: type ?? this.type,
      label: label ?? this.label,
      assetId: assetId ?? this.assetId,
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
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'trackId': trackId,
      'type': type.name,
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
    };
  }

  factory TimelineClip.fromJson(Map<String, dynamic> json) {
    return TimelineClip(
      id: json['id'] as String?,
      trackId: json['trackId'] as String? ?? '',
      type: TimelineTrackType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => TimelineTrackType.subtitle,
      ),
      label: json['label'] as String? ?? 'Untitled clip',
      assetId: json['assetId'] as String?,
      linkedClipId: json['linkedClipId'] as String?,
      startTime: Duration(
        milliseconds: (json['startTimeMs'] as num?)?.toInt() ?? 0,
      ),
      endTime: Duration(
        milliseconds: (json['endTimeMs'] as num?)?.toInt() ?? 0,
      ),
      sourceStartTime: Duration(
        milliseconds: (json['sourceStartTimeMs'] as num?)?.toInt() ?? 0,
      ),
      sourceDuration: Duration(
        milliseconds: (json['sourceDurationMs'] as num?)?.toInt() ?? 0,
      ),
      layer: (json['layer'] as num?)?.toInt() ?? 0,
      enabled: json['enabled'] as bool? ?? true,
      transform: json['transform'] is Map<String, dynamic>
          ? TimelineTransform.fromJson(
              json['transform'] as Map<String, dynamic>,
            )
          : const TimelineTransform(),
      audioMix: json['audioMix'] is Map<String, dynamic>
          ? AudioMixSettings.fromJson(json['audioMix'] as Map<String, dynamic>)
          : const AudioMixSettings(),
      fitMode: ClipFitMode.values.firstWhere(
        (value) => value.name == json['fitMode'],
        orElse: () => ClipFitMode.cover,
      ),
      playbackRate: ((json['playbackRate'] as num?)?.toDouble() ?? 1)
          .clamp(0.25, 4)
          .toDouble(),
      isReversed: json['isReversed'] as bool? ?? false,
      crop: json['crop'] is Map<String, dynamic>
          ? ClipCropSettings.fromJson(json['crop'] as Map<String, dynamic>)
          : const ClipCropSettings(),
      blur: json['blur'] is Map<String, dynamic>
          ? ClipBlurSettings.fromJson(json['blur'] as Map<String, dynamic>)
          : const ClipBlurSettings(),
      colorAdjustments: json['colorAdjustments'] is Map<String, dynamic>
          ? ClipColorAdjustments.fromJson(
              json['colorAdjustments'] as Map<String, dynamic>,
            )
          : const ClipColorAdjustments(),
      text: json['text'] as String?,
      subtitleStyle: json['subtitleStyle'] is Map<String, dynamic>
          ? SubtitleStyleModel.fromJson(
              json['subtitleStyle'] as Map<String, dynamic>,
            )
          : null,
      introTransition: json['introTransition'] is Map<String, dynamic>
          ? ClipTransition.fromJson(
              json['introTransition'] as Map<String, dynamic>,
            )
          : const ClipTransition(),
      outroTransition: json['outroTransition'] is Map<String, dynamic>
          ? ClipTransition.fromJson(
              json['outroTransition'] as Map<String, dynamic>,
            )
          : const ClipTransition(),
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
      clips:
          (json['clips'] as List<dynamic>?)
              ?.map(
                (clip) => TimelineClip.fromJson(clip as Map<String, dynamic>),
              )
              .toList() ??
          const [],
    );
  }
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
  final SubtitleStyleModel subtitleStyle;
  final List<EditorAssetReference> assets;
  final List<TimelineTrack> tracks;
  final List<TimelineMarker> markers;

  const EditorTimeline({
    this.schemaVersion = 4,
    this.canvasSettings = const CanvasSettings(),
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

  EditorAssetReference? assetForClip(TimelineClip clip) {
    final assetId = clip.assetId;
    if (assetId == null) return null;
    for (final asset in assets) {
      if (asset.id == assetId) return asset;
    }
    return null;
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
    SubtitleStyleModel? subtitleStyle,
    List<EditorAssetReference>? assets,
    List<TimelineTrack>? tracks,
    List<TimelineMarker>? markers,
  }) {
    return EditorTimeline(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      canvasSettings: canvasSettings ?? this.canvasSettings,
      subtitleStyle: subtitleStyle ?? this.subtitleStyle,
      assets: assets ?? this.assets,
      tracks: tracks ?? this.tracks,
      markers: markers ?? this.markers,
    );
  }

  EditorTimeline syncLegacySubtitles({
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
    required String videoPath,
    required int durationMs,
  }) {
    final subtitleTrackId = primarySubtitleTrack?.id ?? 'track_subtitles';
    final subtitleTrack = TimelineTrack(
      id: subtitleTrackId,
      name: 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      clips: subtitles
          .map(
            (entry) =>
                TimelineClip.fromSubtitleEntry(entry, trackId: subtitleTrackId),
          )
          .toList(),
    );

    final nextTracks = <TimelineTrack>[
      ...tracks.where((track) => track.type != TimelineTrackType.subtitle),
      subtitleTrack,
    ];

    EditorAssetReference? existingSourceAsset;
    for (final asset in assets) {
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
        ? [resolvedSourceAsset, ...assets]
        : assets;

    final hasVideoTrack = nextTracks.any(
      (track) =>
          track.type == TimelineTrackType.video &&
          track.section == TimelineTrackSection.baseVideo &&
          track.clips.isNotEmpty,
    );
    final completeTracks = hasVideoTrack
        ? nextTracks
        : [
            TimelineTrack(
              id: 'track_overlay_primary',
              name: 'Overlay 1',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.overlay,
              clips: const [],
            ),
            TimelineTrack(
              id: 'track_video_primary',
              name: 'Video 1',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.baseVideo,
              clips: [
                TimelineClip(
                  trackId: 'track_video_primary',
                  type: TimelineTrackType.video,
                  label: 'Source video',
                  assetId: resolvedSourceAsset.id,
                  startTime: Duration.zero,
                  endTime: Duration(milliseconds: durationMs),
                ),
              ],
            ),
            TimelineTrack(
              id: 'track_text_primary',
              name: 'Text 1',
              type: TimelineTrackType.text,
              section: TimelineTrackSection.textSubtitle,
              clips: const [],
            ),
            ...nextTracks,
            TimelineTrack(
              id: 'track_audio_primary',
              name: 'Audio 1',
              type: TimelineTrackType.audio,
              section: TimelineTrackSection.audio,
              clips: const [],
            ),
          ];

    final linkedTracks = completeTracks.map((track) {
      if (track.section != TimelineTrackSection.baseVideo) return track;
      return track.copyWith(
        clips: track.clips
            .map(
              (clip) => clip.assetId == null
                  ? clip.copyWith(assetId: resolvedSourceAsset.id)
                  : clip,
            )
            .toList(),
      );
    }).toList();

    return copyWith(
      subtitleStyle: globalStyle,
      assets: nextAssets,
      tracks: linkedTracks,
    );
  }

  EditorTimeline mergeSubtitleEntries({
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
  }) {
    final subtitleTrackId = primarySubtitleTrack?.id ?? 'track_subtitles';
    final existingSubtitleClips = tracks
        .where((track) => track.type == TimelineTrackType.subtitle)
        .expand((track) => track.clips)
        .fold<Map<String, TimelineClip>>({}, (map, clip) {
          map[clip.id] = clip;
          return map;
        });

    final mergedTrack = TimelineTrack(
      id: subtitleTrackId,
      name: primarySubtitleTrack?.name ?? 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      clips: subtitles.map((entry) {
        final existing = existingSubtitleClips[entry.id];
        if (existing == null) {
          return TimelineClip.fromSubtitleEntry(
            entry,
            trackId: subtitleTrackId,
          );
        }
        return existing.copyWith(
          label: entry.text,
          startTime: entry.startTime,
          endTime: entry.endTime,
          text: entry.text,
          subtitleStyle: entry.styleOverride,
        );
      }).toList(),
    );

    return copyWith(
      subtitleStyle: globalStyle,
      tracks: [
        ...tracks.where((track) => track.type != TimelineTrackType.subtitle),
        mergedTrack,
      ],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'canvasSettings': canvasSettings.toJson(),
      'subtitleStyle': subtitleStyle.toJson(),
      'assets': assets.map((asset) => asset.toJson()).toList(),
      'tracks': tracks.map((track) => track.toJson()).toList(),
      'markers': markers.map((marker) => marker.toJson()).toList(),
    };
  }

  factory EditorTimeline.fromJson(Map<String, dynamic> json) {
    return EditorTimeline(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 2,
      canvasSettings: json['canvasSettings'] is Map<String, dynamic>
          ? CanvasSettings.fromJson(
              json['canvasSettings'] as Map<String, dynamic>,
            )
          : const CanvasSettings(),
      subtitleStyle: json['subtitleStyle'] is Map<String, dynamic>
          ? SubtitleStyleModel.fromJson(
              json['subtitleStyle'] as Map<String, dynamic>,
            )
          : const SubtitleStyleModel(),
      assets:
          (json['assets'] as List<dynamic>?)
              ?.map(
                (asset) => EditorAssetReference.fromJson(
                  asset as Map<String, dynamic>,
                ),
              )
              .toList() ??
          const [],
      tracks:
          (json['tracks'] as List<dynamic>?)
              ?.map(
                (track) =>
                    TimelineTrack.fromJson(track as Map<String, dynamic>),
              )
              .toList() ??
          const [],
      markers:
          (json['markers'] as List<dynamic>?)
              ?.map(
                (marker) =>
                    TimelineMarker.fromJson(marker as Map<String, dynamic>),
              )
              .toList() ??
          const [],
    );
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
