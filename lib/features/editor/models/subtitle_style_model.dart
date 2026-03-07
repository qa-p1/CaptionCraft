import 'package:flutter/material.dart';

/// Style model for subtitles, used both as a global style and per-cue override.
class SubtitleStyleModel {
  final String fontFamily;
  final double fontSize;
  final Color textColor;
  final SubtitleBackground backgroundType;
  final Color backgroundColor;
  final double backgroundOpacity;
  final SubtitlePosition position;
  final double verticalOffset;
  final double offsetX;
  final double offsetY;
  final double maxWidthFactor;
  final TextAlign textAlignment;
  final bool isBold;
  final bool isItalic;
  final bool isAllCaps;
  final SubtitleAnimationPreset? animationPreset;

  const SubtitleStyleModel({
    this.fontFamily = 'Inter',
    this.fontSize = 24,
    this.textColor = Colors.white,
    this.backgroundType = SubtitleBackground.none,
    this.backgroundColor = Colors.black,
    this.backgroundOpacity = 0.6,
    this.position = SubtitlePosition.bottom,
    this.verticalOffset = 0,
    this.offsetX = 0,
    this.offsetY = 0,
    this.maxWidthFactor = 0.85,
    this.textAlignment = TextAlign.center,
    this.isBold = false,
    this.isItalic = false,
    this.isAllCaps = false,
    this.animationPreset,
  });

  SubtitleStyleModel copyWith({
    String? fontFamily,
    double? fontSize,
    Color? textColor,
    SubtitleBackground? backgroundType,
    Color? backgroundColor,
    double? backgroundOpacity,
    SubtitlePosition? position,
    double? verticalOffset,
    double? offsetX,
    double? offsetY,
    double? maxWidthFactor,
    TextAlign? textAlignment,
    bool? isBold,
    bool? isItalic,
    bool? isAllCaps,
    SubtitleAnimationPreset? animationPreset,
  }) {
    return SubtitleStyleModel(
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      backgroundType: backgroundType ?? this.backgroundType,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      position: position ?? this.position,
      verticalOffset: verticalOffset ?? this.verticalOffset,
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
      maxWidthFactor: maxWidthFactor ?? this.maxWidthFactor,
      textAlignment: textAlignment ?? this.textAlignment,
      isBold: isBold ?? this.isBold,
      isItalic: isItalic ?? this.isItalic,
      isAllCaps: isAllCaps ?? this.isAllCaps,
      animationPreset: animationPreset ?? this.animationPreset,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fontFamily': fontFamily,
      'fontSize': fontSize,
      'textColor': _colorToInt(textColor),
      'backgroundType': backgroundType.name,
      'backgroundColor': _colorToInt(backgroundColor),
      'backgroundOpacity': backgroundOpacity,
      'position': position.name,
      'verticalOffset': verticalOffset,
      'offsetX': offsetX,
      'offsetY': offsetY,
      'maxWidthFactor': maxWidthFactor,
      'textAlignment': textAlignment.name,
      'isBold': isBold,
      'isItalic': isItalic,
      'isAllCaps': isAllCaps,
      'animationPreset': animationPreset?.name,
    };
  }

  factory SubtitleStyleModel.fromJson(Map<String, dynamic> json) {
    return SubtitleStyleModel(
      fontFamily: json['fontFamily'] as String? ?? 'Inter',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 24,
      textColor: Color(json['textColor'] as int? ?? 0xFFFFFFFF),
      backgroundType: SubtitleBackground.values.firstWhere(
        (e) => e.name == json['backgroundType'],
        orElse: () => SubtitleBackground.none,
      ),
      backgroundColor: Color(json['backgroundColor'] as int? ?? 0xFF000000),
      backgroundOpacity: (json['backgroundOpacity'] as num?)?.toDouble() ?? 0.6,
      position: SubtitlePosition.values.firstWhere(
        (e) => e.name == json['position'],
        orElse: () => SubtitlePosition.bottom,
      ),
      verticalOffset: (json['verticalOffset'] as num?)?.toDouble() ?? 0,
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? 0,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? 0,
      maxWidthFactor: (json['maxWidthFactor'] as num?)?.toDouble() ?? 0.85,
      textAlignment: TextAlign.values.firstWhere(
        (e) => e.name == json['textAlignment'],
        orElse: () => TextAlign.center,
      ),
      isBold: json['isBold'] as bool? ?? false,
      isItalic: json['isItalic'] as bool? ?? false,
      isAllCaps: json['isAllCaps'] as bool? ?? false,
      animationPreset: json['animationPreset'] != null
          ? SubtitleAnimationPreset.values.firstWhere(
              (e) => e.name == json['animationPreset'],
              orElse: () => SubtitleAnimationPreset.wordPop,
            )
          : null,
    );
  }
  static int _colorToInt(Color c) {
    final a = ((c.a * 255.0).round().clamp(0, 255)) as int;
    final r = ((c.r * 255.0).round().clamp(0, 255)) as int;
    final g = ((c.g * 255.0).round().clamp(0, 255)) as int;
    final b = ((c.b * 255.0).round().clamp(0, 255)) as int;
    return (a << 24) | (r << 16) | (g << 8) | b;
  }
}

enum SubtitleBackground { none, semiTransparentBox, fullBar, outlineShadow }

enum SubtitlePosition { top, center, bottom }

enum SubtitleAnimationPreset {
  wordPop,
  lineFade,
  karaokeHighlight,
  wordSlideUp,
  typewriter,
}
