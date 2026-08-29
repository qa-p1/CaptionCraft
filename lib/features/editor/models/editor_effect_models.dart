import 'dart:math' as math;

import 'package:uuid/uuid.dart';

enum EditorEffectDomain { visual, audio }

enum EditorEffectScope {
  clip,
  track,
  group,
  compound,
  adjustmentLayer,
  audioBus,
  project,
}

enum EditorEffectType {
  gaussianBlur,
  directionalBlur,
  motionBlur,
  sharpen,
  glow,
  bloom,
  vignette,
  grain,
  noise,
  pixelate,
  mosaic,
  posterize,
  emboss,
  edgeDetection,
  chromaticAberration,
  lensDistortion,
  fisheye,
  warp,
  ripple,
  wave,
  shake,
  glitch,
  rgbSplit,
  scanLines,
  vhs,
  crt,
  halftone,
  comic,
  sketch,
  stylized,
  dropShadow,
  outline,
  stroke,
  reflection,
  flare,
  glare,
  bokeh,
  lightLeak,
  prism,
  cinematicGlow,
  colorGrade,
  lut,
  equalizer,
  compressor,
  limiter,
  noiseGate,
  deEsser,
  noiseReduction,
  humReduction,
  reverb,
  delay,
  distortion,
  pitch,
  timeStretch,
}

enum EditorEffectMaskShape { rectangle, ellipse, freeform }

enum EditorEffectInterpolation { hold, linear, easeIn, easeOut, easeInOut }

enum EditorAudioChannelMode { stereo, mono, dualMono, leftOnly, rightOnly }

enum EditorColorSpace { sdr709, log, hlg, pq, wideGamut }

const Map<EditorEffectType, String> _effectLabels = {
  EditorEffectType.gaussianBlur: 'Gaussian Blur',
  EditorEffectType.directionalBlur: 'Directional Blur',
  EditorEffectType.motionBlur: 'Motion Blur',
  EditorEffectType.sharpen: 'Sharpen',
  EditorEffectType.glow: 'Glow',
  EditorEffectType.bloom: 'Bloom',
  EditorEffectType.vignette: 'Vignette',
  EditorEffectType.grain: 'Film Grain',
  EditorEffectType.noise: 'Noise',
  EditorEffectType.pixelate: 'Pixelate',
  EditorEffectType.mosaic: 'Mosaic',
  EditorEffectType.posterize: 'Posterize',
  EditorEffectType.emboss: 'Emboss',
  EditorEffectType.edgeDetection: 'Edge Detection',
  EditorEffectType.chromaticAberration: 'Chromatic Aberration',
  EditorEffectType.lensDistortion: 'Lens Distortion',
  EditorEffectType.fisheye: 'Fisheye',
  EditorEffectType.warp: 'Warp',
  EditorEffectType.ripple: 'Ripple',
  EditorEffectType.wave: 'Wave',
  EditorEffectType.shake: 'Shake',
  EditorEffectType.glitch: 'Glitch',
  EditorEffectType.rgbSplit: 'RGB Split',
  EditorEffectType.scanLines: 'Scan Lines',
  EditorEffectType.vhs: 'VHS',
  EditorEffectType.crt: 'CRT',
  EditorEffectType.halftone: 'Halftone',
  EditorEffectType.comic: 'Comic',
  EditorEffectType.sketch: 'Sketch',
  EditorEffectType.stylized: 'Stylized',
  EditorEffectType.dropShadow: 'Drop Shadow',
  EditorEffectType.outline: 'Outline',
  EditorEffectType.stroke: 'Stroke',
  EditorEffectType.reflection: 'Reflection',
  EditorEffectType.flare: 'Lens Flare',
  EditorEffectType.glare: 'Glare',
  EditorEffectType.bokeh: 'Bokeh',
  EditorEffectType.lightLeak: 'Light Leak',
  EditorEffectType.prism: 'Prism',
  EditorEffectType.cinematicGlow: 'Cinematic Glow',
  EditorEffectType.colorGrade: 'Color Grade',
  EditorEffectType.lut: 'LUT',
  EditorEffectType.equalizer: 'Equalizer',
  EditorEffectType.compressor: 'Compressor',
  EditorEffectType.limiter: 'Limiter',
  EditorEffectType.noiseGate: 'Noise Gate',
  EditorEffectType.deEsser: 'De-esser',
  EditorEffectType.noiseReduction: 'Noise Reduction',
  EditorEffectType.humReduction: 'Hum Reduction',
  EditorEffectType.reverb: 'Reverb',
  EditorEffectType.delay: 'Delay',
  EditorEffectType.distortion: 'Distortion',
  EditorEffectType.pitch: 'Pitch',
  EditorEffectType.timeStretch: 'Time Stretch',
};

const Set<EditorEffectType> _audioEffectTypes = {
  EditorEffectType.equalizer,
  EditorEffectType.compressor,
  EditorEffectType.limiter,
  EditorEffectType.noiseGate,
  EditorEffectType.deEsser,
  EditorEffectType.noiseReduction,
  EditorEffectType.humReduction,
  EditorEffectType.reverb,
  EditorEffectType.delay,
  EditorEffectType.distortion,
  EditorEffectType.pitch,
  EditorEffectType.timeStretch,
};

extension EditorEffectTypeMetadata on EditorEffectType {
  String get label => _effectLabels[this] ?? name;

  EditorEffectDomain get domain => _audioEffectTypes.contains(this)
      ? EditorEffectDomain.audio
      : EditorEffectDomain.visual;

  String get category {
    if (domain == EditorEffectDomain.audio) return 'Audio';
    if (this == EditorEffectType.colorGrade || this == EditorEffectType.lut) {
      return 'Color';
    }
    if ({
      EditorEffectType.gaussianBlur,
      EditorEffectType.directionalBlur,
      EditorEffectType.motionBlur,
    }.contains(this)) {
      return 'Blur';
    }
    if ({
      EditorEffectType.dropShadow,
      EditorEffectType.outline,
      EditorEffectType.stroke,
      EditorEffectType.reflection,
    }.contains(this)) {
      return 'Depth';
    }
    if ({
      EditorEffectType.flare,
      EditorEffectType.glare,
      EditorEffectType.bokeh,
      EditorEffectType.lightLeak,
      EditorEffectType.prism,
      EditorEffectType.cinematicGlow,
    }.contains(this)) {
      return 'Lens';
    }
    return 'Stylize';
  }

  bool get supportsMask =>
      domain == EditorEffectDomain.visual && this != EditorEffectType.lut;

  double get defaultIntensity {
    return switch (this) {
      EditorEffectType.glow ||
      EditorEffectType.bloom ||
      EditorEffectType.dropShadow ||
      EditorEffectType.outline ||
      EditorEffectType.stroke ||
      EditorEffectType.flare ||
      EditorEffectType.glare ||
      EditorEffectType.bokeh ||
      EditorEffectType.lightLeak ||
      EditorEffectType.prism ||
      EditorEffectType.cinematicGlow => 0.45,
      EditorEffectType.reflection => 0.3,
      _ => 1,
    };
  }

  Map<String, double> get defaultParameters {
    return switch (this) {
      EditorEffectType.gaussianBlur => {'radius': 12},
      EditorEffectType.directionalBlur => {'radius': 12, 'angle': 0},
      EditorEffectType.motionBlur => {'amount': 0.35, 'angle': 0},
      EditorEffectType.sharpen => {'amount': 0.4},
      EditorEffectType.glow => {'radius': 18, 'threshold': 0.65},
      EditorEffectType.bloom => {'radius': 22, 'threshold': 0.7},
      EditorEffectType.vignette => {'amount': 0.35, 'softness': 0.7},
      EditorEffectType.grain => {'amount': 0.18},
      EditorEffectType.noise => {'amount': 0.12},
      EditorEffectType.pixelate => {'size': 12},
      EditorEffectType.mosaic => {'size': 18},
      EditorEffectType.posterize => {'levels': 6},
      EditorEffectType.emboss => {'amount': 0.65},
      EditorEffectType.edgeDetection => {'amount': 0.8},
      EditorEffectType.chromaticAberration => {'amount': 3},
      EditorEffectType.lensDistortion => {'amount': 0.18},
      EditorEffectType.fisheye => {'amount': 0.22},
      EditorEffectType.warp => {'amount': 0.2},
      EditorEffectType.ripple => {'amount': 0.2, 'frequency': 4},
      EditorEffectType.wave => {'amount': 0.15, 'frequency': 3},
      EditorEffectType.shake => {'amount': 0.25, 'frequency': 8},
      EditorEffectType.glitch => {'amount': 0.25},
      EditorEffectType.rgbSplit => {'amount': 4},
      EditorEffectType.scanLines => {'amount': 0.35, 'spacing': 4},
      EditorEffectType.vhs => {'amount': 0.35},
      EditorEffectType.crt => {'amount': 0.35},
      EditorEffectType.halftone => {'amount': 0.5, 'size': 5},
      EditorEffectType.comic => {'amount': 0.65},
      EditorEffectType.sketch => {'amount': 0.7},
      EditorEffectType.stylized => {'amount': 0.5},
      EditorEffectType.dropShadow => {
        'amount': 0.45,
        'blur': 10,
        'offsetX': 8,
        'offsetY': 8,
      },
      EditorEffectType.outline => {'amount': 0.45, 'width': 4},
      EditorEffectType.stroke => {'amount': 0.45, 'width': 3},
      EditorEffectType.reflection => {'amount': 0.25, 'offset': 0.1},
      EditorEffectType.flare => {
        'amount': 0.35,
        'positionX': 0.7,
        'positionY': 0.25,
      },
      EditorEffectType.glare => {'amount': 0.35},
      EditorEffectType.bokeh => {'amount': 0.3, 'size': 12},
      EditorEffectType.lightLeak => {'amount': 0.3, 'position': 0.5},
      EditorEffectType.prism => {'amount': 0.25},
      EditorEffectType.cinematicGlow => {'amount': 0.35, 'radius': 18},
      EditorEffectType.colorGrade => {},
      EditorEffectType.lut => {'intensity': 1},
      EditorEffectType.equalizer => {'frequency': 1000, 'gain': 0, 'width': 1},
      EditorEffectType.compressor => {
        'threshold': -18,
        'ratio': 3,
        'attack': 20,
        'release': 250,
      },
      EditorEffectType.limiter => {'limit': -1, 'attack': 5, 'release': 50},
      EditorEffectType.noiseGate => {'threshold': -45, 'range': -18},
      EditorEffectType.deEsser => {'frequency': 5500, 'amount': 0.35},
      EditorEffectType.noiseReduction => {'amount': 0.35},
      EditorEffectType.humReduction => {'frequency': 60, 'amount': 0.5},
      EditorEffectType.reverb => {'room': 0.35, 'damping': 0.5},
      EditorEffectType.delay => {'delayMs': 180, 'decay': 0.35},
      EditorEffectType.distortion => {'amount': 0.2},
      EditorEffectType.pitch => {'semitones': 0},
      EditorEffectType.timeStretch => {'rate': 1},
    };
  }
}

double _effectDouble(Object? value, double fallback) {
  if (value is num && value.isFinite) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

int _effectInt(Object? value, int fallback) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

Map<String, dynamic> _effectMap(Object? value) {
  if (value is! Map) return <String, dynamic>{};
  return Map<String, dynamic>.from(value);
}

EditorEffectType _effectType(Object? value) {
  return EditorEffectType.values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () => EditorEffectType.stylized,
  );
}

EditorEffectInterpolation _effectInterpolation(Object? value) {
  return EditorEffectInterpolation.values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () => EditorEffectInterpolation.linear,
  );
}

class EditorEffectMask {
  final EditorEffectMaskShape shape;
  final double x;
  final double y;
  final double width;
  final double height;
  final double feather;
  final bool inverted;
  final bool trackingEnabled;
  final String? trackingTargetId;

  const EditorEffectMask({
    this.shape = EditorEffectMaskShape.rectangle,
    this.x = 0.25,
    this.y = 0.25,
    this.width = 0.5,
    this.height = 0.5,
    this.feather = 0.15,
    this.inverted = false,
    this.trackingEnabled = false,
    this.trackingTargetId,
  });

  double get safeWidth => width.clamp(0.02, 1).toDouble();
  double get safeHeight => height.clamp(0.02, 1).toDouble();
  double get safeX => x.clamp(0.0, 1 - safeWidth).toDouble();
  double get safeY => y.clamp(0.0, 1 - safeHeight).toDouble();
  double get safeFeather => feather.clamp(0.0, 1).toDouble();

  EditorEffectMask copyWith({
    EditorEffectMaskShape? shape,
    double? x,
    double? y,
    double? width,
    double? height,
    double? feather,
    bool? inverted,
    bool? trackingEnabled,
    String? trackingTargetId,
  }) {
    return EditorEffectMask(
      shape: shape ?? this.shape,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      feather: feather ?? this.feather,
      inverted: inverted ?? this.inverted,
      trackingEnabled: trackingEnabled ?? this.trackingEnabled,
      trackingTargetId: trackingTargetId ?? this.trackingTargetId,
    );
  }

  Map<String, dynamic> toJson() => {
    'shape': shape.name,
    'x': safeX,
    'y': safeY,
    'width': safeWidth,
    'height': safeHeight,
    'feather': safeFeather,
    'inverted': inverted,
    'trackingEnabled': trackingEnabled,
    'trackingTargetId': trackingTargetId,
  };

  factory EditorEffectMask.fromJson(Map<String, dynamic> json) {
    return EditorEffectMask(
      shape: EditorEffectMaskShape.values.firstWhere(
        (candidate) => candidate.name == json['shape'],
        orElse: () => EditorEffectMaskShape.rectangle,
      ),
      x: _effectDouble(json['x'], 0.25),
      y: _effectDouble(json['y'], 0.25),
      width: _effectDouble(json['width'], 0.5),
      height: _effectDouble(json['height'], 0.5),
      feather: _effectDouble(json['feather'], 0.15),
      inverted: json['inverted'] as bool? ?? false,
      trackingEnabled: json['trackingEnabled'] as bool? ?? false,
      trackingTargetId: json['trackingTargetId'] as String?,
    );
  }
}

class EditorEffectParameterKeyframe {
  final String id;
  final String parameter;
  final Duration time;
  final double value;
  final EditorEffectInterpolation interpolation;

  EditorEffectParameterKeyframe({
    String? id,
    required String parameter,
    required Duration time,
    required double value,
    this.interpolation = EditorEffectInterpolation.linear,
  }) : id = id?.trim().isNotEmpty == true ? id! : const Uuid().v4(),
       parameter = parameter.trim().isEmpty ? 'amount' : parameter.trim(),
       time = time.isNegative ? Duration.zero : time,
       value = value.isFinite ? value : 0;

  EditorEffectParameterKeyframe copyWith({
    String? parameter,
    Duration? time,
    double? value,
    EditorEffectInterpolation? interpolation,
  }) {
    return EditorEffectParameterKeyframe(
      id: id,
      parameter: parameter ?? this.parameter,
      time: time ?? this.time,
      value: value ?? this.value,
      interpolation: interpolation ?? this.interpolation,
    );
  }

  EditorEffectParameterKeyframe cloneWithNewId() {
    return EditorEffectParameterKeyframe(
      parameter: parameter,
      time: time,
      value: value,
      interpolation: interpolation,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'parameter': parameter,
    'timeMs': time.inMilliseconds,
    'value': value,
    'interpolation': interpolation.name,
  };

  factory EditorEffectParameterKeyframe.fromJson(Map<String, dynamic> json) {
    return EditorEffectParameterKeyframe(
      id: json['id'] as String?,
      parameter: json['parameter'] as String? ?? 'amount',
      time: Duration(milliseconds: _effectInt(json['timeMs'], 0)),
      value: _effectDouble(json['value'], 0),
      interpolation: _effectInterpolation(json['interpolation']),
    );
  }
}

class EditorEffect {
  final String id;
  final EditorEffectType type;
  final String? customName;
  final bool enabled;
  final double intensity;
  final Map<String, dynamic> parameters;
  final EditorEffectMask? mask;
  final List<EditorEffectParameterKeyframe> keyframes;

  EditorEffect({
    String? id,
    required this.type,
    this.customName,
    this.enabled = true,
    double? intensity,
    Map<String, dynamic>? parameters,
    this.mask,
    List<EditorEffectParameterKeyframe>? keyframes,
  }) : id = id?.trim().isNotEmpty == true ? id! : const Uuid().v4(),
       intensity = (intensity ?? type.defaultIntensity)
           .clamp(0.0, 1.0)
           .toDouble(),
       parameters = Map.unmodifiable({
         ...type.defaultParameters,
         ...?parameters,
       }),
       keyframes = List.unmodifiable(_normalizedEffectKeyframes(keyframes));

  String get displayName =>
      customName?.trim().isNotEmpty == true ? customName!.trim() : type.label;

  EditorEffectDomain get domain => type.domain;

  double parameter(String name, [double fallback = 0]) {
    return _effectDouble(parameters[name], fallback);
  }

  double parameterAt(String name, Duration time, {double fallback = 0}) {
    final frames =
        keyframes.where((keyframe) => keyframe.parameter == name).toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    if (frames.isEmpty) return parameter(name, fallback);
    if (time <= frames.first.time) return frames.first.value;
    if (time >= frames.last.time) return frames.last.value;
    for (var index = 1; index < frames.length; index++) {
      final previous = frames[index - 1];
      final next = frames[index];
      if (time <= next.time) {
        final total = math.max(
          1,
          next.time.inMicroseconds - previous.time.inMicroseconds,
        );
        final progress =
            ((time.inMicroseconds - previous.time.inMicroseconds) / total)
                .clamp(0.0, 1.0)
                .toDouble();
        final eased = switch (previous.interpolation) {
          EditorEffectInterpolation.hold => progress < 1 ? 0.0 : 1.0,
          EditorEffectInterpolation.linear => progress,
          EditorEffectInterpolation.easeIn => progress * progress,
          EditorEffectInterpolation.easeOut =>
            1 - (1 - progress) * (1 - progress),
          EditorEffectInterpolation.easeInOut =>
            progress < 0.5
                ? 2 * progress * progress
                : (1 - math.pow(-2 * progress + 2, 2) / 2).toDouble(),
        };
        return previous.value + (next.value - previous.value) * eased;
      }
    }
    return frames.last.value;
  }

  EditorEffect copyWith({
    EditorEffectType? type,
    String? customName,
    bool clearCustomName = false,
    bool? enabled,
    double? intensity,
    Map<String, dynamic>? parameters,
    EditorEffectMask? mask,
    bool clearMask = false,
    List<EditorEffectParameterKeyframe>? keyframes,
  }) {
    return EditorEffect(
      id: id,
      type: type ?? this.type,
      customName: clearCustomName ? null : (customName ?? this.customName),
      enabled: enabled ?? this.enabled,
      intensity: intensity ?? this.intensity,
      parameters: parameters ?? this.parameters,
      mask: clearMask ? null : (mask ?? this.mask),
      keyframes: keyframes ?? this.keyframes,
    );
  }

  EditorEffect withParameter(String name, double value) {
    return copyWith(parameters: {...parameters, name: value});
  }

  EditorEffect cloneWithNewId() {
    return EditorEffect(
      type: type,
      customName: customName,
      enabled: enabled,
      intensity: intensity,
      parameters: parameters,
      mask: mask,
      keyframes: keyframes
          .map((keyframe) => keyframe.cloneWithNewId())
          .toList(),
    );
  }

  EditorEffect trimmedFromStart(
    Duration removedDuration, {
    bool cloneIdentity = false,
  }) {
    final removed = removedDuration.isNegative
        ? Duration.zero
        : removedDuration;
    final trimmed = <EditorEffectParameterKeyframe>[];
    final parametersWithFrames = keyframes
        .map((keyframe) => keyframe.parameter)
        .toSet();
    for (final parameterName in parametersWithFrames) {
      final frames = keyframes
          .where((keyframe) => keyframe.parameter == parameterName)
          .toList();
      final boundaryValue = parameterAt(
        parameterName,
        removed,
        fallback: parameter(parameterName),
      );
      final exactBoundary = frames
          .where((keyframe) => keyframe.time == removed)
          .firstOrNull;
      trimmed.add(
        EditorEffectParameterKeyframe(
          id: cloneIdentity ? null : exactBoundary?.id,
          parameter: parameterName,
          time: Duration.zero,
          value: boundaryValue,
          interpolation:
              exactBoundary?.interpolation ??
              frames
                  .where((keyframe) => keyframe.time <= removed)
                  .lastOrNull
                  ?.interpolation ??
              EditorEffectInterpolation.linear,
        ),
      );
      for (final frame in frames.where((keyframe) => keyframe.time > removed)) {
        trimmed.add(
          EditorEffectParameterKeyframe(
            id: cloneIdentity ? null : frame.id,
            parameter: frame.parameter,
            time: frame.time - removed,
            value: frame.value,
            interpolation: frame.interpolation,
          ),
        );
      }
    }
    return EditorEffect(
      id: cloneIdentity ? null : id,
      type: type,
      customName: customName,
      enabled: enabled,
      intensity: intensity,
      parameters: parameters,
      mask: mask,
      keyframes: trimmed,
    );
  }

  EditorEffect trimmedToDuration(Duration duration) {
    final end = duration.isNegative ? Duration.zero : duration;
    final trimmed = <EditorEffectParameterKeyframe>[];
    final parametersWithFrames = keyframes
        .map((keyframe) => keyframe.parameter)
        .toSet();
    for (final parameterName in parametersWithFrames) {
      final frames = keyframes
          .where((keyframe) => keyframe.parameter == parameterName)
          .toList();
      trimmed.addAll(frames.where((keyframe) => keyframe.time <= end));
      if (frames.any((keyframe) => keyframe.time > end) &&
          !frames.any((keyframe) => keyframe.time == end)) {
        trimmed.add(
          EditorEffectParameterKeyframe(
            parameter: parameterName,
            time: end,
            value: parameterAt(
              parameterName,
              end,
              fallback: parameter(parameterName),
            ),
            interpolation:
                frames
                    .where((keyframe) => keyframe.time < end)
                    .lastOrNull
                    ?.interpolation ??
                EditorEffectInterpolation.linear,
          ),
        );
      }
    }
    return copyWith(keyframes: trimmed);
  }

  EditorEffect retimed(Duration oldDuration, Duration newDuration) {
    final oldUs = oldDuration.inMicroseconds;
    final newUs = math.max(0, newDuration.inMicroseconds);
    if (keyframes.isEmpty || oldUs <= 0 || oldUs == newUs) return this;
    return copyWith(
      keyframes: keyframes
          .map(
            (keyframe) => keyframe.copyWith(
              time: Duration(
                microseconds: (keyframe.time.inMicroseconds * newUs / oldUs)
                    .round(),
              ),
            ),
          )
          .toList(),
    );
  }

  EditorEffect upsertKeyframe({
    required String parameter,
    required Duration time,
    required double value,
    EditorEffectInterpolation? interpolation,
  }) {
    final next = [...keyframes]
      ..removeWhere(
        (keyframe) => keyframe.parameter == parameter && keyframe.time == time,
      )
      ..add(
        EditorEffectParameterKeyframe(
          parameter: parameter,
          time: time,
          value: value,
          interpolation: interpolation ?? EditorEffectInterpolation.linear,
        ),
      )
      ..sort((a, b) {
        final timeComparison = a.time.compareTo(b.time);
        return timeComparison != 0
            ? timeComparison
            : a.parameter.compareTo(b.parameter);
      });
    return copyWith(keyframes: next);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'customName': customName,
    'enabled': enabled,
    'intensity': intensity,
    'parameters': parameters,
    'mask': mask?.toJson(),
    'keyframes': keyframes.map((keyframe) => keyframe.toJson()).toList(),
  };

  factory EditorEffect.fromJson(Map<String, dynamic> json) {
    final type = _effectType(json['type']);
    final rawKeyframes = json['keyframes'];
    final keyframes = <EditorEffectParameterKeyframe>[];
    if (rawKeyframes is List) {
      for (final candidate in rawKeyframes) {
        final map = candidate is Map
            ? Map<String, dynamic>.from(candidate)
            : null;
        if (map == null) continue;
        try {
          keyframes.add(EditorEffectParameterKeyframe.fromJson(map));
        } catch (_) {}
      }
    }
    final maskValue = json['mask'];
    final maskMap = maskValue is Map
        ? Map<String, dynamic>.from(maskValue)
        : null;
    return EditorEffect(
      id: json['id'] as String?,
      type: type,
      customName: json['customName'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      intensity: json.containsKey('intensity')
          ? _effectDouble(json['intensity'], type.defaultIntensity)
          : null,
      parameters: _effectMap(json['parameters']),
      mask: maskMap == null ? null : EditorEffectMask.fromJson(maskMap),
      keyframes: keyframes,
    );
  }
}

List<EditorEffectParameterKeyframe> _normalizedEffectKeyframes(
  List<EditorEffectParameterKeyframe>? keyframes,
) {
  final byParameterAndTime = <String, EditorEffectParameterKeyframe>{};
  final usedIds = <String>{};
  for (final keyframe in keyframes ?? const []) {
    var normalized = EditorEffectParameterKeyframe(
      id: keyframe.id,
      parameter: keyframe.parameter,
      time: keyframe.time,
      value: keyframe.value,
      interpolation: keyframe.interpolation,
    );
    if (!usedIds.add(normalized.id)) {
      normalized = normalized.cloneWithNewId();
      usedIds.add(normalized.id);
    }
    byParameterAndTime['${normalized.parameter}:${normalized.time.inMicroseconds}'] =
        normalized;
  }
  final normalized = byParameterAndTime.values.toList()
    ..sort((first, second) {
      final byTime = first.time.compareTo(second.time);
      return byTime != 0 ? byTime : first.parameter.compareTo(second.parameter);
    });
  return normalized;
}

class EditorEffectStack {
  final List<EditorEffect> effects;

  const EditorEffectStack({this.effects = const []});

  bool get isEmpty => effects.isEmpty;
  bool get isNotEmpty => effects.isNotEmpty;

  EditorEffect? get firstEnabled => effects
      .where((effect) => effect.enabled)
      .cast<EditorEffect?>()
      .firstOrNull;

  EditorEffect? byId(String id) =>
      effects.where((effect) => effect.id == id).firstOrNull;

  EditorEffectStack copyWith({List<EditorEffect>? effects}) {
    return EditorEffectStack(
      effects: List.unmodifiable(effects ?? this.effects),
    );
  }

  EditorEffectStack add(EditorEffect effect) =>
      copyWith(effects: [...effects, effect]);

  EditorEffectStack cloneWithNewIds() => copyWith(
    effects: effects.map((effect) => effect.cloneWithNewId()).toList(),
  );

  EditorEffectStack trimmedFromStart(
    Duration removedDuration, {
    bool cloneIdentities = false,
  }) => copyWith(
    effects: effects
        .map(
          (effect) => effect.trimmedFromStart(
            removedDuration,
            cloneIdentity: cloneIdentities,
          ),
        )
        .toList(),
  );

  EditorEffectStack trimmedToDuration(Duration duration) => copyWith(
    effects: effects
        .map((effect) => effect.trimmedToDuration(duration))
        .toList(),
  );

  EditorEffectStack retimed(Duration oldDuration, Duration newDuration) =>
      copyWith(
        effects: effects
            .map((effect) => effect.retimed(oldDuration, newDuration))
            .toList(),
      );

  ({EditorEffectStack leading, EditorEffectStack trailing}) splitAt(
    Duration splitTime,
  ) {
    final safeTime = splitTime.isNegative ? Duration.zero : splitTime;
    return (
      leading: trimmedToDuration(safeTime),
      trailing: trimmedFromStart(safeTime, cloneIdentities: true),
    );
  }

  EditorEffectStack remove(String effectId) => copyWith(
    effects: effects.where((effect) => effect.id != effectId).toList(),
  );

  EditorEffectStack toggle(String effectId) => copyWith(
    effects: effects
        .map(
          (effect) => effect.id == effectId
              ? effect.copyWith(enabled: !effect.enabled)
              : effect,
        )
        .toList(),
  );

  EditorEffectStack reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= effects.length) return this;
    final adjustedIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (adjustedIndex < 0 || adjustedIndex >= effects.length) return this;
    final next = [...effects];
    final moved = next.removeAt(oldIndex);
    next.insert(adjustedIndex, moved);
    return copyWith(effects: next);
  }

  Map<String, dynamic> toJson() => {
    'effects': effects.map((effect) => effect.toJson()).toList(),
  };

  factory EditorEffectStack.fromJson(Object? value) {
    if (value is! Map) return const EditorEffectStack();
    final rawEffects = value['effects'];
    if (rawEffects is! List) return const EditorEffectStack();
    final effects = <EditorEffect>[];
    for (final candidate in rawEffects) {
      if (candidate is! Map) continue;
      try {
        effects.add(
          EditorEffect.fromJson(Map<String, dynamic>.from(candidate)),
        );
      } catch (_) {}
    }
    return EditorEffectStack(effects: List.unmodifiable(effects));
  }
}

class EditorEffectContainer {
  final String id;
  final EditorEffectScope scope;
  final String targetId;
  final String label;
  final bool enabled;
  final EditorEffectStack stack;

  EditorEffectContainer({
    String? id,
    required this.scope,
    required this.targetId,
    required this.label,
    this.enabled = true,
    this.stack = const EditorEffectStack(),
  }) : id = id?.trim().isNotEmpty == true ? id! : const Uuid().v4();

  EditorEffectContainer copyWith({
    EditorEffectScope? scope,
    String? targetId,
    String? label,
    bool? enabled,
    EditorEffectStack? stack,
  }) {
    return EditorEffectContainer(
      id: id,
      scope: scope ?? this.scope,
      targetId: targetId ?? this.targetId,
      label: label ?? this.label,
      enabled: enabled ?? this.enabled,
      stack: stack ?? this.stack,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'scope': scope.name,
    'targetId': targetId,
    'label': label,
    'enabled': enabled,
    'stack': stack.toJson(),
  };

  factory EditorEffectContainer.fromJson(Map<String, dynamic> json) {
    return EditorEffectContainer(
      id: json['id'] as String?,
      scope: EditorEffectScope.values.firstWhere(
        (candidate) => candidate.name == json['scope'],
        orElse: () => EditorEffectScope.group,
      ),
      targetId: json['targetId'] as String? ?? '',
      label: json['label'] as String? ?? 'Effects',
      enabled: json['enabled'] as bool? ?? true,
      stack: EditorEffectStack.fromJson(json['stack']),
    );
  }
}

class TimelineGroup {
  final String id;
  final String name;
  final List<String> clipIds;
  final bool enabled;

  TimelineGroup({
    String? id,
    required this.name,
    required Iterable<String> clipIds,
    this.enabled = true,
  }) : id = id?.trim().isNotEmpty == true ? id! : const Uuid().v4(),
       clipIds = List.unmodifiable(
         clipIds
             .map((clipId) => clipId.trim())
             .where((clipId) => clipId.isNotEmpty)
             .toSet(),
       );

  TimelineGroup copyWith({
    String? name,
    Iterable<String>? clipIds,
    bool? enabled,
  }) {
    return TimelineGroup(
      id: id,
      name: name ?? this.name,
      clipIds: clipIds ?? this.clipIds,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'clipIds': clipIds,
    'enabled': enabled,
  };

  factory TimelineGroup.fromJson(Map<String, dynamic> json) {
    return TimelineGroup(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Group',
      clipIds: json['clipIds'] is List
          ? (json['clipIds'] as List).whereType<String>()
          : const <String>[],
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}

class TimelineCompoundClip {
  final String id;
  final String name;
  final List<String> clipIds;
  final bool enabled;

  TimelineCompoundClip({
    String? id,
    required this.name,
    required Iterable<String> clipIds,
    this.enabled = true,
  }) : id = id?.trim().isNotEmpty == true ? id! : const Uuid().v4(),
       clipIds = List.unmodifiable(
         clipIds
             .map((clipId) => clipId.trim())
             .where((clipId) => clipId.isNotEmpty)
             .toSet(),
       );

  TimelineCompoundClip copyWith({
    String? name,
    Iterable<String>? clipIds,
    bool? enabled,
  }) {
    return TimelineCompoundClip(
      id: id,
      name: name ?? this.name,
      clipIds: clipIds ?? this.clipIds,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'clipIds': clipIds,
    'enabled': enabled,
  };

  factory TimelineCompoundClip.fromJson(Map<String, dynamic> json) {
    return TimelineCompoundClip(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Compound clip',
      clipIds: json['clipIds'] is List
          ? (json['clipIds'] as List).whereType<String>()
          : const <String>[],
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}

class EditorEffectPreset {
  final String id;
  final String name;
  final String? description;
  final EditorEffectStack stack;
  final DateTime createdAt;

  EditorEffectPreset({
    String? id,
    required this.name,
    this.description,
    required this.stack,
    DateTime? createdAt,
  }) : id = id?.trim().isNotEmpty == true ? id! : const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'stack': stack.toJson(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory EditorEffectPreset.fromJson(Map<String, dynamic> json) {
    return EditorEffectPreset(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Preset',
      description: json['description'] as String?,
      stack: EditorEffectStack.fromJson(json['stack']),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }
}

class EditorColorCurvePoint {
  final double input;
  final double output;

  const EditorColorCurvePoint(this.input, this.output);

  EditorColorCurvePoint normalized() => EditorColorCurvePoint(
    input.clamp(0.0, 1.0).toDouble(),
    output.clamp(0.0, 1.0).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'input': normalized().input,
    'output': normalized().output,
  };

  factory EditorColorCurvePoint.fromJson(Map<String, dynamic> json) {
    return EditorColorCurvePoint(
      _effectDouble(json['input'], 0),
      _effectDouble(json['output'], 0),
    ).normalized();
  }
}

class EditorColorCurve {
  final List<EditorColorCurvePoint> points;

  const EditorColorCurve({
    this.points = const [
      EditorColorCurvePoint(0, 0),
      EditorColorCurvePoint(1, 1),
    ],
  });

  bool get isIdentity =>
      points.length == 2 &&
      (points.first.input - 0).abs() < 0.0001 &&
      (points.first.output - 0).abs() < 0.0001 &&
      (points.last.input - 1).abs() < 0.0001 &&
      (points.last.output - 1).abs() < 0.0001;

  EditorColorCurve copyWith({List<EditorColorCurvePoint>? points}) {
    return EditorColorCurve(points: List.unmodifiable(points ?? this.points));
  }

  Map<String, dynamic> toJson() => {
    'points': points.map((point) => point.toJson()).toList(),
  };

  factory EditorColorCurve.fromJson(Object? value) {
    if (value is! Map || value['points'] is! List) {
      return const EditorColorCurve();
    }
    final points = <EditorColorCurvePoint>[];
    for (final candidate in value['points'] as List) {
      if (candidate is! Map) continue;
      points.add(
        EditorColorCurvePoint.fromJson(Map<String, dynamic>.from(candidate)),
      );
    }
    points.sort((a, b) => a.input.compareTo(b.input));
    return EditorColorCurve(
      points: points.length >= 2
          ? points
          : const [EditorColorCurvePoint(0, 0), EditorColorCurvePoint(1, 1)],
    );
  }
}

class EditorColorWheels {
  final double shadowsRed;
  final double shadowsGreen;
  final double shadowsBlue;
  final double midtonesRed;
  final double midtonesGreen;
  final double midtonesBlue;
  final double highlightsRed;
  final double highlightsGreen;
  final double highlightsBlue;
  final double globalRed;
  final double globalGreen;
  final double globalBlue;

  const EditorColorWheels({
    this.shadowsRed = 0,
    this.shadowsGreen = 0,
    this.shadowsBlue = 0,
    this.midtonesRed = 0,
    this.midtonesGreen = 0,
    this.midtonesBlue = 0,
    this.highlightsRed = 0,
    this.highlightsGreen = 0,
    this.highlightsBlue = 0,
    this.globalRed = 0,
    this.globalGreen = 0,
    this.globalBlue = 0,
  });

  bool get isIdentity =>
      shadowsRed == 0 &&
      shadowsGreen == 0 &&
      shadowsBlue == 0 &&
      midtonesRed == 0 &&
      midtonesGreen == 0 &&
      midtonesBlue == 0 &&
      highlightsRed == 0 &&
      highlightsGreen == 0 &&
      highlightsBlue == 0 &&
      globalRed == 0 &&
      globalGreen == 0 &&
      globalBlue == 0;

  EditorColorWheels copyWith({
    double? shadowsRed,
    double? shadowsGreen,
    double? shadowsBlue,
    double? midtonesRed,
    double? midtonesGreen,
    double? midtonesBlue,
    double? highlightsRed,
    double? highlightsGreen,
    double? highlightsBlue,
    double? globalRed,
    double? globalGreen,
    double? globalBlue,
  }) {
    return EditorColorWheels(
      shadowsRed: shadowsRed ?? this.shadowsRed,
      shadowsGreen: shadowsGreen ?? this.shadowsGreen,
      shadowsBlue: shadowsBlue ?? this.shadowsBlue,
      midtonesRed: midtonesRed ?? this.midtonesRed,
      midtonesGreen: midtonesGreen ?? this.midtonesGreen,
      midtonesBlue: midtonesBlue ?? this.midtonesBlue,
      highlightsRed: highlightsRed ?? this.highlightsRed,
      highlightsGreen: highlightsGreen ?? this.highlightsGreen,
      highlightsBlue: highlightsBlue ?? this.highlightsBlue,
      globalRed: globalRed ?? this.globalRed,
      globalGreen: globalGreen ?? this.globalGreen,
      globalBlue: globalBlue ?? this.globalBlue,
    );
  }

  Map<String, dynamic> toJson() => {
    'shadowsRed': shadowsRed,
    'shadowsGreen': shadowsGreen,
    'shadowsBlue': shadowsBlue,
    'midtonesRed': midtonesRed,
    'midtonesGreen': midtonesGreen,
    'midtonesBlue': midtonesBlue,
    'highlightsRed': highlightsRed,
    'highlightsGreen': highlightsGreen,
    'highlightsBlue': highlightsBlue,
    'globalRed': globalRed,
    'globalGreen': globalGreen,
    'globalBlue': globalBlue,
  };

  factory EditorColorWheels.fromJson(Object? value) {
    final json = _effectMap(value);
    return EditorColorWheels(
      shadowsRed: _effectDouble(json['shadowsRed'], 0),
      shadowsGreen: _effectDouble(json['shadowsGreen'], 0),
      shadowsBlue: _effectDouble(json['shadowsBlue'], 0),
      midtonesRed: _effectDouble(json['midtonesRed'], 0),
      midtonesGreen: _effectDouble(json['midtonesGreen'], 0),
      midtonesBlue: _effectDouble(json['midtonesBlue'], 0),
      highlightsRed: _effectDouble(json['highlightsRed'], 0),
      highlightsGreen: _effectDouble(json['highlightsGreen'], 0),
      highlightsBlue: _effectDouble(json['highlightsBlue'], 0),
      globalRed: _effectDouble(json['globalRed'], 0),
      globalGreen: _effectDouble(json['globalGreen'], 0),
      globalBlue: _effectDouble(json['globalBlue'], 0),
    );
  }
}

class EditorColorQualifier {
  final bool enabled;
  final int color;
  final double hueRange;
  final double saturationRange;
  final double luminanceRange;
  final double softness;

  const EditorColorQualifier({
    this.enabled = false,
    this.color = 0xFFFF0000,
    this.hueRange = 0.08,
    this.saturationRange = 0.25,
    this.luminanceRange = 0.3,
    this.softness = 0.15,
  });

  EditorColorQualifier copyWith({
    bool? enabled,
    int? color,
    double? hueRange,
    double? saturationRange,
    double? luminanceRange,
    double? softness,
  }) {
    return EditorColorQualifier(
      enabled: enabled ?? this.enabled,
      color: color ?? this.color,
      hueRange: hueRange ?? this.hueRange,
      saturationRange: saturationRange ?? this.saturationRange,
      luminanceRange: luminanceRange ?? this.luminanceRange,
      softness: softness ?? this.softness,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'color': color,
    'hueRange': hueRange,
    'saturationRange': saturationRange,
    'luminanceRange': luminanceRange,
    'softness': softness,
  };

  factory EditorColorQualifier.fromJson(Object? value) {
    final json = _effectMap(value);
    return EditorColorQualifier(
      enabled: json['enabled'] as bool? ?? false,
      color: _effectInt(json['color'], 0xFFFF0000),
      hueRange: _effectDouble(json['hueRange'], 0.08),
      saturationRange: _effectDouble(json['saturationRange'], 0.25),
      luminanceRange: _effectDouble(json['luminanceRange'], 0.3),
      softness: _effectDouble(json['softness'], 0.15),
    );
  }
}

class EditorLutAsset {
  final String id;
  final String name;
  final String path;
  final String folder;
  final bool favorite;

  EditorLutAsset({
    String? id,
    required this.name,
    required this.path,
    this.folder = 'Custom',
    this.favorite = false,
  }) : id = id?.trim().isNotEmpty == true ? id! : const Uuid().v4();

  EditorLutAsset copyWith({
    String? name,
    String? path,
    String? folder,
    bool? favorite,
  }) {
    return EditorLutAsset(
      id: id,
      name: name ?? this.name,
      path: path ?? this.path,
      folder: folder ?? this.folder,
      favorite: favorite ?? this.favorite,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'folder': folder,
    'favorite': favorite,
  };

  factory EditorLutAsset.fromJson(Map<String, dynamic> json) {
    return EditorLutAsset(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'LUT',
      path: json['path'] as String? ?? '',
      folder: json['folder'] as String? ?? 'Custom',
      favorite: json['favorite'] as bool? ?? false,
    );
  }
}

class EditorColorManagementSettings {
  final EditorColorSpace workingSpace;
  final EditorColorSpace outputSpace;
  final bool automaticLogTransform;
  final bool preserveHdr;
  final List<EditorLutAsset> luts;

  const EditorColorManagementSettings({
    this.workingSpace = EditorColorSpace.sdr709,
    this.outputSpace = EditorColorSpace.sdr709,
    this.automaticLogTransform = true,
    this.preserveHdr = false,
    this.luts = const [],
  });

  EditorColorManagementSettings copyWith({
    EditorColorSpace? workingSpace,
    EditorColorSpace? outputSpace,
    bool? automaticLogTransform,
    bool? preserveHdr,
    List<EditorLutAsset>? luts,
  }) {
    return EditorColorManagementSettings(
      workingSpace: workingSpace ?? this.workingSpace,
      outputSpace: outputSpace ?? this.outputSpace,
      automaticLogTransform:
          automaticLogTransform ?? this.automaticLogTransform,
      preserveHdr: preserveHdr ?? this.preserveHdr,
      luts: List.unmodifiable(luts ?? this.luts),
    );
  }

  Map<String, dynamic> toJson() => {
    'workingSpace': workingSpace.name,
    'outputSpace': outputSpace.name,
    'automaticLogTransform': automaticLogTransform,
    'preserveHdr': preserveHdr,
    'luts': luts.map((lut) => lut.toJson()).toList(),
  };

  factory EditorColorManagementSettings.fromJson(Object? value) {
    final json = _effectMap(value);
    final rawLuts = json['luts'];
    final luts = <EditorLutAsset>[];
    if (rawLuts is List) {
      for (final candidate in rawLuts) {
        if (candidate is Map) {
          luts.add(
            EditorLutAsset.fromJson(Map<String, dynamic>.from(candidate)),
          );
        }
      }
    }
    return EditorColorManagementSettings(
      workingSpace: EditorColorSpace.values.firstWhere(
        (candidate) => candidate.name == json['workingSpace'],
        orElse: () => EditorColorSpace.sdr709,
      ),
      outputSpace: EditorColorSpace.values.firstWhere(
        (candidate) => candidate.name == json['outputSpace'],
        orElse: () => EditorColorSpace.sdr709,
      ),
      automaticLogTransform: json['automaticLogTransform'] as bool? ?? true,
      preserveHdr: json['preserveHdr'] as bool? ?? false,
      luts: List.unmodifiable(luts),
    );
  }
}

class TimelineAudioBus {
  final String id;
  final String name;
  final double gain;
  final double pan;
  final bool muted;
  final bool solo;
  final EditorEffectStack effectStack;

  TimelineAudioBus({
    String? id,
    required this.name,
    double gain = 1,
    double pan = 0,
    this.muted = false,
    this.solo = false,
    this.effectStack = const EditorEffectStack(),
  }) : id = id?.trim().isNotEmpty == true ? id! : const Uuid().v4(),
       gain = gain.clamp(0.0, 2.0).toDouble(),
       pan = pan.clamp(-1.0, 1.0).toDouble();

  TimelineAudioBus copyWith({
    String? name,
    double? gain,
    double? pan,
    bool? muted,
    bool? solo,
    EditorEffectStack? effectStack,
  }) {
    return TimelineAudioBus(
      id: id,
      name: name ?? this.name,
      gain: gain ?? this.gain,
      pan: pan ?? this.pan,
      muted: muted ?? this.muted,
      solo: solo ?? this.solo,
      effectStack: effectStack ?? this.effectStack,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'gain': gain.clamp(0.0, 2.0),
    'pan': pan.clamp(-1.0, 1.0),
    'muted': muted,
    'solo': solo,
    'effectStack': effectStack.toJson(),
  };

  factory TimelineAudioBus.fromJson(Map<String, dynamic> json) {
    return TimelineAudioBus(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Bus',
      gain: _effectDouble(json['gain'], 1).clamp(0.0, 2.0).toDouble(),
      pan: _effectDouble(json['pan'], 0).clamp(-1.0, 1.0).toDouble(),
      muted: json['muted'] as bool? ?? false,
      solo: json['solo'] as bool? ?? false,
      effectStack: EditorEffectStack.fromJson(json['effectStack']),
    );
  }
}
