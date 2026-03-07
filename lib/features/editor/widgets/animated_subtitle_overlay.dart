import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../../../core/theme/app_theme.dart';

/// Animated subtitle overlay that renders word-level animations
/// based on the selected SubtitleAnimationPreset.
class AnimatedSubtitleOverlay extends StatelessWidget {
  final SubtitleEntry entry;
  final SubtitleStyleModel globalStyle;
  final Duration currentPosition;

  const AnimatedSubtitleOverlay({
    super.key,
    required this.entry,
    required this.globalStyle,
    required this.currentPosition,
  });

  SubtitleStyleModel get _style {
    final base = entry.styleOverride ?? globalStyle;
    // Spatial + size controls are treated as global editor transforms.
    return base.copyWith(
      fontSize: globalStyle.fontSize,
      verticalOffset: globalStyle.verticalOffset,
      offsetX: globalStyle.offsetX,
      offsetY: globalStyle.offsetY,
      maxWidthFactor: globalStyle.maxWidthFactor,
    );
  }

  SubtitleAnimationPreset? get _preset => _style.animationPreset;

  @override
  Widget build(BuildContext context) {
    if (_preset == null || entry.words == null || entry.words!.isEmpty) {
      return _buildStaticOverlay();
    }

    switch (_preset!) {
      case SubtitleAnimationPreset.wordPop:
        return _buildWordPop();
      case SubtitleAnimationPreset.lineFade:
        return _buildLineFade();
      case SubtitleAnimationPreset.karaokeHighlight:
        return _buildKaraokeHighlight();
      case SubtitleAnimationPreset.wordSlideUp:
        return _buildWordSlideUp();
      case SubtitleAnimationPreset.typewriter:
        return _buildTypewriter();
    }
  }

  // ─── Static fallback (no animation / no words data) ───
  Widget _buildStaticOverlay() {
    final style = _style;
    return _wrapBackground(
      style,
      Text(
        style.isAllCaps ? entry.text.toUpperCase() : entry.text,
        textAlign: style.textAlignment,
        style: _textStyle(style),
      ),
    );
  }

  // ─── Preset 1: Word Pop ───
  // Words scale from 0.6→1.0 + fade in as their timestamp arrives.
  // Current word pulses 1.0→1.08→1.0.
  Widget _buildWordPop() {
    final words = entry.words!;
    final style = _style;
    final posMs = currentPosition.inMilliseconds;

    return _wrapBackground(
      style,
      Wrap(
        alignment: _wrapAlignment(style.textAlignment),
        children: words.map((word) {
          final wordStartMs = word.startTime.inMilliseconds;
          final wordEndMs = word.endTime.inMilliseconds;
          final elapsed = posMs - wordStartMs;

          double opacity;
          double scale;

          if (posMs < wordStartMs) {
            // Not reached yet — invisible
            opacity = 0.0;
            scale = 0.6;
          } else if (elapsed < 120) {
            // Animating in (0→120ms)
            final t = elapsed / 120.0;
            opacity = t.clamp(0.0, 1.0);
            scale = 0.6 + 0.4 * t.clamp(0.0, 1.0);
          } else if (posMs <= wordEndMs) {
            // Current word — subtle pulse
            final pulseT = ((elapsed - 120) % 600) / 600.0;
            final pulse = sin(pulseT * pi * 2) * 0.04;
            opacity = 1.0;
            scale = 1.0 + pulse;
          } else {
            // Already spoken — fully visible
            opacity = 1.0;
            scale = 1.0;
          }

          final displayWord = style.isAllCaps
              ? word.word.toUpperCase()
              : word.word;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: scale,
                child: Text(displayWord, style: _textStyle(style)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ─── Preset 2: Line Fade ───
  // Entire line fades in as a single unit over 200ms.
  Widget _buildLineFade() {
    final style = _style;
    final posMs = currentPosition.inMilliseconds;
    final startMs = entry.startTime.inMilliseconds;
    final elapsed = posMs - startMs;

    final opacity = (elapsed / 200.0).clamp(0.0, 1.0);

    return _wrapBackground(
      style,
      Opacity(
        opacity: opacity,
        child: Text(
          style.isAllCaps ? entry.text.toUpperCase() : entry.text,
          textAlign: style.textAlignment,
          style: _textStyle(style),
        ),
      ),
    );
  }

  // ─── Preset 3: Karaoke Highlight ───
  // All words shown at 40% opacity, each lights up at its timestamp.
  Widget _buildKaraokeHighlight() {
    final words = entry.words!;
    final style = _style;
    final posMs = currentPosition.inMilliseconds;

    return _wrapBackground(
      style,
      Wrap(
        alignment: _wrapAlignment(style.textAlignment),
        children: words.map((word) {
          final isReached = posMs >= word.startTime.inMilliseconds;
          final displayWord = style.isAllCaps
              ? word.word.toUpperCase()
              : word.word;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              displayWord,
              style: _textStyle(style).copyWith(
                color: isReached
                    ? kAccent
                    : style.textColor.withValues(alpha: 0.4),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ─── Preset 4: Word Slide Up ───
  // Each word slides up from 12px below + fades in.
  // 80ms stagger per word, 150ms duration per word.
  Widget _buildWordSlideUp() {
    final words = entry.words!;
    final style = _style;
    final posMs = currentPosition.inMilliseconds;
    final lineStartMs = entry.startTime.inMilliseconds;

    return _wrapBackground(
      style,
      Wrap(
        alignment: _wrapAlignment(style.textAlignment),
        children: List.generate(words.length, (i) {
          final word = words[i];
          final staggerStartMs = lineStartMs + (i * 80);
          final elapsed = posMs - staggerStartMs;
          final t = (elapsed / 150.0).clamp(0.0, 1.0);

          final opacity = t;
          final offsetY = 12.0 * (1.0 - t);
          final displayWord = style.isAllCaps
              ? word.word.toUpperCase()
              : word.word;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Transform.translate(
              offset: Offset(0, offsetY),
              child: Opacity(
                opacity: opacity,
                child: Text(displayWord, style: _textStyle(style)),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ─── Preset 5: Typewriter ───
  // Text revealed character by character from left to right.
  Widget _buildTypewriter() {
    final style = _style;
    final posMs = currentPosition.inMilliseconds;
    final startMs = entry.startTime.inMilliseconds;
    final endMs = entry.endTime.inMilliseconds;
    final durationMs = endMs - startMs;

    if (durationMs <= 0) return _buildStaticOverlay();

    final elapsed = posMs - startMs;
    final text = style.isAllCaps ? entry.text.toUpperCase() : entry.text;
    final totalChars = text.length;
    final charsToShow = ((elapsed / durationMs) * totalChars).round().clamp(
      0,
      totalChars,
    );
    final visibleText = text.substring(0, charsToShow);

    return _wrapBackground(
      style,
      Text(
        visibleText,
        textAlign: style.textAlignment,
        style: _textStyle(style),
      ),
    );
  }

  // ─── Shared helpers ───

  TextStyle _textStyle(SubtitleStyleModel style) {
    return GoogleFonts.getFont(
      style.fontFamily,
      fontSize: style.fontSize,
      color: style.textColor,
      fontWeight: style.isBold ? FontWeight.bold : FontWeight.normal,
      fontStyle: style.isItalic ? FontStyle.italic : FontStyle.normal,
      shadows: style.backgroundType == SubtitleBackground.outlineShadow
          ? const [
              Shadow(color: Colors.black, blurRadius: 4, offset: Offset(1, 1)),
              Shadow(
                color: Colors.black,
                blurRadius: 6,
                offset: Offset(-1, -1),
              ),
            ]
          : null,
    );
  }

  Widget _wrapBackground(SubtitleStyleModel style, Widget child) {
    final backgroundColor = style.backgroundColor.withValues(
      alpha: style.backgroundOpacity.clamp(0.0, 1.0),
    );
    final isBar = style.backgroundType == SubtitleBackground.fullBar;
    final isBox = style.backgroundType == SubtitleBackground.semiTransparentBox;
    final core = Container(
      width: isBar ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isBox || isBar ? backgroundColor : Colors.transparent,
        borderRadius: BorderRadius.circular(isBar ? 0 : 8),
      ),
      child: child,
    );

    if (isBar) return core;

    return FractionallySizedBox(
      widthFactor: style.maxWidthFactor.clamp(0.25, 1.0),
      child: core,
    );
  }

  WrapAlignment _wrapAlignment(TextAlign textAlign) {
    switch (textAlign) {
      case TextAlign.left:
      case TextAlign.start:
        return WrapAlignment.start;
      case TextAlign.right:
      case TextAlign.end:
        return WrapAlignment.end;
      default:
        return WrapAlignment.center;
    }
  }
}

/// Selectable preset card for the style panel.
class AnimationPresetCard extends StatelessWidget {
  final SubtitleAnimationPreset preset;
  final bool isSelected;
  final VoidCallback onTap;

  const AnimationPresetCard({
    super.key,
    required this.preset,
    required this.isSelected,
    required this.onTap,
  });

  static const _labels = {
    SubtitleAnimationPreset.wordPop: 'Word Pop',
    SubtitleAnimationPreset.lineFade: 'Line Fade',
    SubtitleAnimationPreset.karaokeHighlight: 'Karaoke',
    SubtitleAnimationPreset.wordSlideUp: 'Slide Up',
    SubtitleAnimationPreset.typewriter: 'Typewriter',
  };

  static const _descriptions = {
    SubtitleAnimationPreset.wordPop: 'Words pop in one by one',
    SubtitleAnimationPreset.lineFade: 'Clean fade-in as a line',
    SubtitleAnimationPreset.karaokeHighlight: 'Words light up in sync',
    SubtitleAnimationPreset.wordSlideUp: 'Words slide up smoothly',
    SubtitleAnimationPreset.typewriter: 'Character by character reveal',
  };

  static const _icons = {
    SubtitleAnimationPreset.wordPop: Icons.bubble_chart_rounded,
    SubtitleAnimationPreset.lineFade: Icons.gradient_rounded,
    SubtitleAnimationPreset.karaokeHighlight: Icons.mic_rounded,
    SubtitleAnimationPreset.wordSlideUp: Icons.arrow_upward_rounded,
    SubtitleAnimationPreset.typewriter: Icons.keyboard_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? kAccent.withValues(alpha: 0.15)
              : kSurfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? kAccent : kBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _icons[preset] ?? Icons.animation_rounded,
              color: isSelected ? kAccent : kTextSecondary,
              size: 24,
            ),
            const SizedBox(height: 6),
            Text(
              _labels[preset] ?? '',
              style: GoogleFonts.inter(
                color: isSelected ? kAccent : kTextPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _descriptions[preset] ?? '',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(color: kTextSecondary, fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }
}
