import 'dart:math';
import 'package:flutter/material.dart';
import '../../../core/utils/caption_font_service.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../../../core/theme/app_theme.dart';

@visibleForTesting
SubtitleStyleModel resolvePreviewSubtitleStyleForTesting({
  required SubtitleEntry entry,
  required SubtitleStyleModel globalStyle,
}) {
  final override = entry.styleOverride;
  if (override == null) return globalStyle;
  final animationPreset =
      override.animationPreset ?? globalStyle.animationPreset;
  return animationPreset == null
      ? override
      : override.copyWith(animationPreset: animationPreset);
}

@visibleForTesting
String typewriterTextAtProgressForTesting(String text, double progress) {
  final graphemes = text.characters;
  final totalGraphemes = graphemes.length;
  final visibleCount = (progress.clamp(0.0, 1.0) * totalGraphemes)
      .round()
      .clamp(0, totalGraphemes);
  return graphemes.take(visibleCount).toString();
}

/// Animated subtitle overlay that renders word-level animations
/// based on the selected SubtitleAnimationPreset.
class AnimatedSubtitleOverlay extends StatelessWidget {
  final SubtitleEntry entry;
  final SubtitleStyleModel globalStyle;
  final Duration currentPosition;
  final double scaleFactor;

  const AnimatedSubtitleOverlay({
    super.key,
    required this.entry,
    required this.globalStyle,
    required this.currentPosition,
    this.scaleFactor = 1,
  });

  SubtitleStyleModel get _style {
    return resolvePreviewSubtitleStyleForTesting(
      entry: entry,
      globalStyle: globalStyle,
    );
  }

  SubtitleAnimationPreset? get _preset => _style.animationPreset;

  @override
  Widget build(BuildContext context) {
    if (_preset == null) {
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
        return _buildLineSlideUp();
      case SubtitleAnimationPreset.typewriter:
        return _buildTypewriter();
      case SubtitleAnimationPreset.zoomIn:
        return _buildZoomIn();
      case SubtitleAnimationPreset.slideFromLeft:
        return _buildSlideFromLeft();
      case SubtitleAnimationPreset.bounceIn:
        return _buildBounceIn();
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
  // Words scale from 0.6→1.0 + fade in as their timestamp arrives. Cues
  // without usable word timing get the same deterministic 160ms stagger used
  // by ASS export.
  Widget _buildWordPop() {
    final words = _resolveWordPopWords();
    if (words.isEmpty) return _buildStaticOverlay();
    final style = _style;
    final posMs = currentPosition.inMilliseconds;

    return _wrapBackground(
      style,
      Wrap(
        alignment: _wrapAlignment(style.textAlignment),
        children: words.map((word) {
          final wordStartMs = word.startTime.inMilliseconds;
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
          } else {
            opacity = 1.0;
            scale = 1.0;
          }

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: scale,
                child: Text(word.text, style: _textStyle(style)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  List<_PreviewAnimationWord> _resolveWordPopWords() {
    final style = _style;
    final text = style.isAllCaps ? entry.text.toUpperCase() : entry.text;
    final matches = RegExp(r'\S+').allMatches(text).toList(growable: false);
    if (matches.isEmpty) return const [];

    final validWords = entry.words
        ?.where(
          (word) =>
              word.word.trim().isNotEmpty && word.endTime > word.startTime,
        )
        .toList(growable: false);
    final useProviderTiming = validWords?.length == matches.length;
    final durationMs = max(entry.duration.inMilliseconds, 0);
    final availableMs = max(durationMs - 120, 0);
    final fallbackStaggerMs = matches.length <= 1
        ? 0
        : min(availableMs ~/ (matches.length - 1), 160);

    return List.generate(matches.length, (index) {
      final startTime = useProviderTiming
          ? validWords![index].startTime
          : entry.startTime + Duration(milliseconds: index * fallbackStaggerMs);
      return _PreviewAnimationWord(
        text: text.substring(matches[index].start, matches[index].end),
        startTime: startTime,
      );
    }, growable: false);
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
    final fragments = _resolveTimedKaraokeFragments();
    if (fragments.isEmpty) return _buildKaraokeHighlightFallback();
    final style = _style;
    final posMs = currentPosition.inMilliseconds;

    return _wrapBackground(
      style,
      Text.rich(
        TextSpan(
          children: fragments
              .map((fragment) {
                final isReached = posMs >= fragment.startTime.inMilliseconds;
                return TextSpan(
                  text: style.isAllCaps
                      ? fragment.text.toUpperCase()
                      : fragment.text,
                  style: _textStyle(style).copyWith(
                    color: isReached
                        ? kAccent
                        : style.textColor.withValues(alpha: 0.4),
                  ),
                );
              })
              .toList(growable: false),
        ),
        textAlign: style.textAlignment,
      ),
    );
  }

  List<_PreviewAnimationWord> _resolveTimedKaraokeFragments() {
    final matches = RegExp(
      r'\S+',
    ).allMatches(entry.text).toList(growable: false);
    final validWords = entry.words
        ?.where(
          (word) =>
              word.word.trim().isNotEmpty && word.endTime > word.startTime,
        )
        .toList(growable: false);
    if (matches.isEmpty || validWords?.length != matches.length) {
      return const [];
    }
    return List.generate(matches.length, (index) {
      final start = index == 0 ? 0 : matches[index].start;
      final end = index + 1 < matches.length
          ? matches[index + 1].start
          : entry.text.length;
      return _PreviewAnimationWord(
        text: entry.text.substring(start, end),
        startTime: validWords![index].startTime,
      );
    }, growable: false);
  }

  Widget _buildKaraokeHighlightFallback() {
    final style = _style;
    final durationMs = max(entry.duration.inMilliseconds, 1);
    final elapsedMs = (currentPosition - entry.startTime).inMilliseconds.clamp(
      0,
      durationMs,
    );
    final progress = elapsedMs / durationMs;

    return _wrapBackground(
      style,
      ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) {
          final highlightStop = progress.clamp(0.0, 1.0);
          return LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              kAccent,
              kAccent,
              style.textColor.withValues(alpha: 0.4),
              style.textColor.withValues(alpha: 0.4),
            ],
            stops: [0, highlightStop, highlightStop, 1],
          ).createShader(bounds);
        },
        child: Text(
          style.isAllCaps ? entry.text.toUpperCase() : entry.text,
          textAlign: style.textAlignment,
          style: _textStyle(style),
        ),
      ),
    );
  }

  // ─── Preset 4: Line Slide Up ───
  // ASS supports motion for a complete dialogue event, not independently for
  // inline word runs. Preview uses that same 180ms whole-line move and fade so
  // wrapping, alignment, and backgrounds stay identical in the export.
  Widget _buildLineSlideUp() {
    final style = _style;
    final elapsed = (currentPosition - entry.startTime).inMilliseconds;
    final t = (elapsed / 180.0).clamp(0.0, 1.0);

    return _wrapBackground(
      style,
      Transform.translate(
        offset: Offset(0, 12 * scaleFactor * (1 - t)),
        child: Opacity(
          opacity: t,
          child: Text(
            style.isAllCaps ? entry.text.toUpperCase() : entry.text,
            textAlign: style.textAlignment,
            style: _textStyle(style),
          ),
        ),
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
    final visibleText = typewriterTextAtProgressForTesting(
      text,
      elapsed / durationMs,
    );

    return _wrapBackground(
      style,
      Text(
        visibleText,
        textAlign: style.textAlignment,
        style: _textStyle(style),
      ),
    );
  }

  // ─── Preset 6: Zoom In ───
  // A short scale-and-fade entrance that remains cheap to render because it
  // only transforms the completed text layer.
  Widget _buildZoomIn() {
    final style = _style;
    final elapsed = (currentPosition - entry.startTime).inMilliseconds;
    final rawT = (elapsed / 220.0).clamp(0.0, 1.0);
    final t = Curves.easeOutCubic.transform(rawT);
    return Opacity(
      opacity: rawT,
      child: Transform.scale(
        scale: 0.72 + (0.28 * t),
        child: _wrapBackground(
          style,
          Text(
            style.isAllCaps ? entry.text.toUpperCase() : entry.text,
            textAlign: style.textAlignment,
            style: _textStyle(style),
          ),
        ),
      ),
    );
  }

  // ─── Preset 7: Slide From Left ───
  Widget _buildSlideFromLeft() {
    final style = _style;
    final elapsed = (currentPosition - entry.startTime).inMilliseconds;
    final rawT = (elapsed / 240.0).clamp(0.0, 1.0);
    final t = Curves.easeOutCubic.transform(rawT);
    return Transform.translate(
      offset: Offset(-28 * scaleFactor * (1 - t), 0),
      child: Opacity(
        opacity: rawT,
        child: _wrapBackground(
          style,
          Text(
            style.isAllCaps ? entry.text.toUpperCase() : entry.text,
            textAlign: style.textAlignment,
            style: _textStyle(style),
          ),
        ),
      ),
    );
  }

  // ─── Preset 8: Bounce In ───
  Widget _buildBounceIn() {
    final style = _style;
    final elapsed = (currentPosition - entry.startTime).inMilliseconds;
    final rawT = (elapsed / 320.0).clamp(0.0, 1.0);
    final double scale;
    if (rawT < 0.68) {
      final rise = Curves.easeOutCubic.transform(rawT / 0.68);
      scale = 0.55 + (0.55 * rise);
    } else {
      final settle = Curves.easeInOut.transform((rawT - 0.68) / 0.32);
      scale = 1.10 - (0.10 * settle);
    }
    return Opacity(
      opacity: (elapsed / 110.0).clamp(0.0, 1.0),
      child: Transform.scale(
        scale: scale,
        child: _wrapBackground(
          style,
          Text(
            style.isAllCaps ? entry.text.toUpperCase() : entry.text,
            textAlign: style.textAlignment,
            style: _textStyle(style),
          ),
        ),
      ),
    );
  }

  // ─── Shared helpers ───

  TextStyle _textStyle(SubtitleStyleModel style) {
    return TextStyle(
      fontFamily: CaptionFontService.resolveFamily(style.fontFamily),
      fontSize: style.fontSize * scaleFactor,
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
      padding: EdgeInsets.symmetric(
        horizontal: 16 * scaleFactor,
        vertical: 8 * scaleFactor,
      ),
      decoration: BoxDecoration(
        color: isBox || isBar ? backgroundColor : Colors.transparent,
        borderRadius: BorderRadius.circular(isBar ? 0 : 8 * scaleFactor),
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

class _PreviewAnimationWord {
  final String text;
  final Duration startTime;

  const _PreviewAnimationWord({required this.text, required this.startTime});
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
    SubtitleAnimationPreset.wordSlideUp: 'Line Slide Up',
    SubtitleAnimationPreset.typewriter: 'Typewriter',
    SubtitleAnimationPreset.zoomIn: 'Zoom In',
    SubtitleAnimationPreset.slideFromLeft: 'Slide Left',
    SubtitleAnimationPreset.bounceIn: 'Bounce In',
  };

  static const _descriptions = {
    SubtitleAnimationPreset.wordPop: 'Words pop in one by one',
    SubtitleAnimationPreset.lineFade: 'Clean fade-in as a line',
    SubtitleAnimationPreset.karaokeHighlight: 'Words light up in sync',
    SubtitleAnimationPreset.wordSlideUp: 'Whole line slides up smoothly',
    SubtitleAnimationPreset.typewriter: 'Character by character reveal',
    SubtitleAnimationPreset.zoomIn: 'Clean scale and fade entrance',
    SubtitleAnimationPreset.slideFromLeft: 'Line glides in from the left',
    SubtitleAnimationPreset.bounceIn: 'Playful overshoot and settle',
  };

  static const _icons = {
    SubtitleAnimationPreset.wordPop: Icons.bubble_chart_rounded,
    SubtitleAnimationPreset.lineFade: Icons.gradient_rounded,
    SubtitleAnimationPreset.karaokeHighlight: Icons.mic_rounded,
    SubtitleAnimationPreset.wordSlideUp: Icons.arrow_upward_rounded,
    SubtitleAnimationPreset.typewriter: Icons.keyboard_rounded,
    SubtitleAnimationPreset.zoomIn: Icons.zoom_in_rounded,
    SubtitleAnimationPreset.slideFromLeft: Icons.arrow_forward_rounded,
    SubtitleAnimationPreset.bounceIn: Icons.sports_basketball_rounded,
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
              style: TextStyle(
                color: isSelected ? kAccent : kTextPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _descriptions[preset] ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextSecondary, fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }
}
