import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/caption_font_service.dart';
import '../models/subtitle_style_model.dart';
import '../providers/subtitle_provider.dart';
import 'animated_subtitle_overlay.dart';

/// Style panel for customizing subtitle appearance.
class SubtitleStylePanel extends ConsumerWidget {
  const SubtitleStylePanel({super.key});

  // Available fonts
  static const _fonts = CaptionFontService.supportedFamilies;

  // Pre-built style presets
  static final _presets = <String, SubtitleStyleModel>{
    'Clean White': const SubtitleStyleModel(
      fontFamily: 'Inter',
      textColor: Colors.white,
      backgroundType: SubtitleBackground.outlineShadow,
    ),
    'Cinema Black': SubtitleStyleModel(
      fontFamily: 'Playfair Display',
      textColor: Colors.white,
      backgroundType: SubtitleBackground.semiTransparentBox,
      backgroundColor: Colors.black,
      backgroundOpacity: 0.7,
      isBold: true,
    ),
    'TikTok Bold': SubtitleStyleModel(
      fontFamily: 'Montserrat',
      textColor: Colors.yellow,
      backgroundType: SubtitleBackground.outlineShadow,
      isBold: true,
      isAllCaps: true,
    ),
    'Minimal Grey': SubtitleStyleModel(
      fontFamily: 'Roboto',
      textColor: const Color(0xFFBBBBBB),
      backgroundType: SubtitleBackground.none,
    ),
    'Neon Pop': SubtitleStyleModel(
      fontFamily: 'Space Mono',
      textColor: const Color(0xFF00BCD4),
      backgroundType: SubtitleBackground.semiTransparentBox,
      backgroundColor: const Color(0xFF1A1A2E),
      backgroundOpacity: 0.8,
    ),
    'News Ticker': SubtitleStyleModel(
      fontFamily: 'Roboto',
      textColor: Colors.white,
      backgroundType: SubtitleBackground.fullBar,
      backgroundColor: Colors.black,
    ),
    'Documentary': SubtitleStyleModel(
      fontFamily: 'Playfair Display',
      textColor: const Color(0xFFFFF8E1),
      backgroundType: SubtitleBackground.outlineShadow,
      isItalic: true,
    ),
    'Highlight Reel': SubtitleStyleModel(
      fontFamily: 'Poppins',
      textColor: Colors.black,
      backgroundType: SubtitleBackground.semiTransparentBox,
      backgroundColor: Colors.yellow,
      backgroundOpacity: 0.9,
      isBold: true,
    ),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitleState = ref.watch(subtitleProvider);
    final style = subtitleState.globalStyle;

    return Container(
      color: kSurface,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Section: Animation Presets
          _sectionHeader('Animation Presets'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // None option
              GestureDetector(
                onTap: () {
                  ref
                      .read(subtitleProvider.notifier)
                      .updateGlobalStyle(
                        SubtitleStyleModel(
                          fontFamily: style.fontFamily,
                          fontSize: style.fontSize,
                          textColor: style.textColor,
                          backgroundType: style.backgroundType,
                          backgroundColor: style.backgroundColor,
                          backgroundOpacity: style.backgroundOpacity,
                          position: style.position,
                          verticalOffset: style.verticalOffset,
                          offsetX: style.offsetX,
                          offsetY: style.offsetY,
                          maxWidthFactor: style.maxWidthFactor,
                          textAlignment: style.textAlignment,
                          isBold: style.isBold,
                          isItalic: style.isItalic,
                          isAllCaps: style.isAllCaps,
                          animationPreset: null,
                        ),
                      );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: style.animationPreset == null
                        ? kAccent.withValues(alpha: 0.15)
                        : kSurfaceElevated,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: style.animationPreset == null ? kAccent : kBorder,
                      width: style.animationPreset == null ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.text_fields_rounded,
                        color: style.animationPreset == null
                            ? kAccent
                            : kTextSecondary,
                        size: 24,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Static',
                        style: TextStyle(
                          color: style.animationPreset == null
                              ? kAccent
                              : kTextPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'No animation',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kTextSecondary, fontSize: 9),
                      ),
                    ],
                  ),
                ),
              ),
              ...SubtitleAnimationPreset.values.map((preset) {
                return AnimationPresetCard(
                  preset: preset,
                  isSelected: style.animationPreset == preset,
                  onTap: () {
                    ref
                        .read(subtitleProvider.notifier)
                        .updateGlobalStyle(
                          style.copyWith(animationPreset: preset),
                        );
                  },
                );
              }),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(color: kBorder),
          const SizedBox(height: 12),

          // Section: Style Presets
          _sectionHeader('Style Presets'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presets.entries.map((preset) {
              return _PresetChip(
                name: preset.key,
                style: preset.value,
                onTap: () {
                  ref.read(subtitleProvider.notifier).applyPreset(preset.value);
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          const Divider(color: kBorder),
          const SizedBox(height: 12),

          // Section: Font
          _sectionHeader('Font'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: kSurfaceElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kBorder),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _fonts.contains(style.fontFamily)
                    ? style.fontFamily
                    : 'Inter',
                dropdownColor: kSurfaceElevated,
                isExpanded: true,
                items: _fonts
                    .map(
                      (f) => DropdownMenuItem(
                        value: f,
                        child: Text(
                          f,
                          style: TextStyle(
                            fontFamily: f,
                            color: kTextPrimary,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    ref
                        .read(subtitleProvider.notifier)
                        .updateGlobalStyle(style.copyWith(fontFamily: value));
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Font size slider
          _sectionHeader('Size'),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                '${style.fontSize.round()}px',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: kTextSecondary,
                  fontSize: 12,
                ),
              ),
              Expanded(
                child: Slider(
                  value: style.fontSize,
                  min: 1,
                  max: 48,
                  activeColor: kAccent,
                  inactiveColor: kBorder,
                  onChangeStart: (_) => ref
                      .read(subtitleProvider.notifier)
                      .beginStyleGestureEdit(),
                  onChanged: (value) {
                    ref
                        .read(subtitleProvider.notifier)
                        .updateGlobalStyleLive(style.copyWith(fontSize: value));
                  },
                  onChangeEnd: (_) =>
                      ref.read(subtitleProvider.notifier).endStyleGestureEdit(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _sectionHeader('Max Width'),
          Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  '${(style.maxWidthFactor * 100).round()}%',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: kTextSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                child: Slider(
                  value: style.maxWidthFactor.clamp(0.25, 1.0),
                  min: 0.25,
                  max: 1.0,
                  activeColor: kAccent,
                  inactiveColor: kBorder,
                  onChangeStart: (_) => ref
                      .read(subtitleProvider.notifier)
                      .beginStyleGestureEdit(),
                  onChanged: (value) {
                    ref
                        .read(subtitleProvider.notifier)
                        .updateGlobalStyleLive(
                          style.copyWith(maxWidthFactor: value),
                        );
                  },
                  onChangeEnd: (_) =>
                      ref.read(subtitleProvider.notifier).endStyleGestureEdit(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Drag subtitle in preview to reposition/resize',
                  style: TextStyle(color: kTextSecondary, fontSize: 11),
                ),
              ),
              TextButton(
                onPressed: () {
                  ref
                      .read(subtitleProvider.notifier)
                      .updateGlobalStyle(
                        style.copyWith(
                          offsetX: 0,
                          offsetY: 0,
                          verticalOffset: 0,
                          maxWidthFactor: 0.85,
                        ),
                      );
                },
                child: const Text('Reset'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Text Color
          _sectionHeader('Text Color'),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => _showColorPicker(context, ref, style.textColor, true),
            child: _colorPreview(style.textColor),
          ),
          const SizedBox(height: 16),

          // Background
          _sectionHeader('Background'),
          const SizedBox(height: 8),
          _backgroundSelector(ref, style),
          if (style.backgroundType != SubtitleBackground.none) ...[
            const SizedBox(height: 12),
            _sectionHeader('Background Color'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () =>
                  _showColorPicker(context, ref, style.backgroundColor, false),
              child: _colorPreview(style.backgroundColor),
            ),
            const SizedBox(height: 12),
            _sectionHeader('Opacity'),
            Slider(
              value: style.backgroundOpacity,
              min: 0,
              max: 1,
              activeColor: kAccent,
              inactiveColor: kBorder,
              onChangeStart: (_) =>
                  ref.read(subtitleProvider.notifier).beginStyleGestureEdit(),
              onChanged: (value) {
                ref
                    .read(subtitleProvider.notifier)
                    .updateGlobalStyleLive(
                      style.copyWith(backgroundOpacity: value),
                    );
              },
              onChangeEnd: (_) =>
                  ref.read(subtitleProvider.notifier).endStyleGestureEdit(),
            ),
          ],
          const SizedBox(height: 16),

          // Position
          _sectionHeader('Position'),
          const SizedBox(height: 8),
          _positionSelector(ref, style),
          const SizedBox(height: 10),
          _sectionHeader('Vertical Nudge'),
          Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  style.verticalOffset.toStringAsFixed(0),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: kTextSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                child: Slider(
                  value: style.verticalOffset.clamp(-60.0, 60.0).toDouble(),
                  min: -60,
                  max: 60,
                  activeColor: kAccent,
                  inactiveColor: kBorder,
                  onChangeStart: (_) => ref
                      .read(subtitleProvider.notifier)
                      .beginStyleGestureEdit(),
                  onChanged: (value) {
                    ref
                        .read(subtitleProvider.notifier)
                        .updateGlobalStyleLive(
                          style.copyWith(verticalOffset: value),
                        );
                  },
                  onChangeEnd: (_) =>
                      ref.read(subtitleProvider.notifier).endStyleGestureEdit(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Text Alignment
          _sectionHeader('Alignment'),
          const SizedBox(height: 8),
          _alignmentSelector(ref, style),
          const SizedBox(height: 16),

          // Text Style toggles
          _sectionHeader('Text Style'),
          const SizedBox(height: 8),
          Row(
            children: [
              _ToggleChip(
                label: 'B',
                isActive: style.isBold,
                fontWeight: FontWeight.bold,
                onTap: () {
                  ref
                      .read(subtitleProvider.notifier)
                      .updateGlobalStyle(style.copyWith(isBold: !style.isBold));
                },
              ),
              const SizedBox(width: 8),
              _ToggleChip(
                label: 'I',
                isActive: style.isItalic,
                isItalic: true,
                onTap: () {
                  ref
                      .read(subtitleProvider.notifier)
                      .updateGlobalStyle(
                        style.copyWith(isItalic: !style.isItalic),
                      );
                },
              ),
              const SizedBox(width: 8),
              _ToggleChip(
                label: 'AA',
                isActive: style.isAllCaps,
                onTap: () {
                  ref
                      .read(subtitleProvider.notifier)
                      .updateGlobalStyle(
                        style.copyWith(isAllCaps: !style.isAllCaps),
                      );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Text(
      text,
      style: TextStyle(
        color: kTextSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _colorPreview(Color color) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kBorder),
      ),
    );
  }

  Widget _backgroundSelector(WidgetRef ref, SubtitleStyleModel style) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: SubtitleBackground.values.map((bg) {
        final labels = {
          SubtitleBackground.none: 'None',
          SubtitleBackground.semiTransparentBox: 'Box',
          SubtitleBackground.fullBar: 'Bar',
          SubtitleBackground.outlineShadow: 'Shadow',
        };
        return _ToggleChip(
          label: labels[bg] ?? '',
          isActive: style.backgroundType == bg,
          onTap: () {
            ref
                .read(subtitleProvider.notifier)
                .updateGlobalStyle(style.copyWith(backgroundType: bg));
          },
        );
      }).toList(),
    );
  }

  Widget _positionSelector(WidgetRef ref, SubtitleStyleModel style) {
    return Row(
      children: SubtitlePosition.values.map((pos) {
        final labels = {
          SubtitlePosition.top: 'Top',
          SubtitlePosition.center: 'Center',
          SubtitlePosition.bottom: 'Bottom',
        };
        final icons = {
          SubtitlePosition.top: Icons.vertical_align_top_rounded,
          SubtitlePosition.center: Icons.vertical_align_center_rounded,
          SubtitlePosition.bottom: Icons.vertical_align_bottom_rounded,
        };
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: _ToggleChip(
            label: labels[pos] ?? '',
            icon: icons[pos],
            isActive: style.position == pos,
            onTap: () {
              ref
                  .read(subtitleProvider.notifier)
                  .updateGlobalStyle(style.copyWith(position: pos));
            },
          ),
        );
      }).toList(),
    );
  }

  Widget _alignmentSelector(WidgetRef ref, SubtitleStyleModel style) {
    return Row(
      children: [
        _ToggleChip(
          icon: Icons.format_align_left_rounded,
          label: '',
          isActive: style.textAlignment == TextAlign.left,
          onTap: () {
            ref
                .read(subtitleProvider.notifier)
                .updateGlobalStyle(
                  style.copyWith(textAlignment: TextAlign.left),
                );
          },
        ),
        const SizedBox(width: 8),
        _ToggleChip(
          icon: Icons.format_align_center_rounded,
          label: '',
          isActive: style.textAlignment == TextAlign.center,
          onTap: () {
            ref
                .read(subtitleProvider.notifier)
                .updateGlobalStyle(
                  style.copyWith(textAlignment: TextAlign.center),
                );
          },
        ),
        const SizedBox(width: 8),
        _ToggleChip(
          icon: Icons.format_align_right_rounded,
          label: '',
          isActive: style.textAlignment == TextAlign.right,
          onTap: () {
            ref
                .read(subtitleProvider.notifier)
                .updateGlobalStyle(
                  style.copyWith(textAlignment: TextAlign.right),
                );
          },
        ),
      ],
    );
  }

  void _showColorPicker(
    BuildContext context,
    WidgetRef ref,
    Color currentColor,
    bool isTextColor,
  ) {
    Color pickedColor = currentColor;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: kSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            isTextColor ? 'Text Color' : 'Background Color',
            style: TextStyle(color: kTextPrimary),
          ),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: currentColor,
              onColorChanged: (color) => pickedColor = color,
              enableAlpha: false,
              labelTypes: const [],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final style = ref.read(subtitleProvider).globalStyle;
                if (isTextColor) {
                  ref
                      .read(subtitleProvider.notifier)
                      .updateGlobalStyle(
                        style.copyWith(textColor: pickedColor),
                      );
                } else {
                  ref
                      .read(subtitleProvider.notifier)
                      .updateGlobalStyle(
                        style.copyWith(backgroundColor: pickedColor),
                      );
                }
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String name;
  final SubtitleStyleModel style;
  final VoidCallback onTap;

  const _PresetChip({
    required this.name,
    required this.style,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: kSurfaceElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kBorder),
        ),
        child: Text(
          name,
          style: TextStyle(
            fontFamily: CaptionFontService.resolveFamily(style.fontFamily),
            color: style.textColor,
            fontSize: 12,
            fontWeight: style.isBold ? FontWeight.bold : FontWeight.normal,
            fontStyle: style.isItalic ? FontStyle.italic : FontStyle.normal,
          ),
        ),
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final FontWeight? fontWeight;
  final bool isItalic;
  final IconData? icon;

  const _ToggleChip({
    required this.label,
    required this.isActive,
    required this.onTap,
    this.fontWeight,
    this.isItalic = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? kAccent.withValues(alpha: 0.2) : kSurfaceElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isActive ? kAccent : kBorder),
        ),
        child: icon != null
            ? Icon(icon, size: 16, color: isActive ? kAccent : kTextSecondary)
            : Text(
                label,
                style: TextStyle(
                  color: isActive ? kAccent : kTextSecondary,
                  fontSize: 12,
                  fontWeight: fontWeight ?? FontWeight.w500,
                  fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
                ),
              ),
      ),
    );
  }
}
