import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/caption_font_service.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import 'animated_subtitle_overlay.dart';
import 'resizable_editor_sheet.dart';

/// A ready-to-use title treatment. Presets intentionally use only bundled
/// fonts and effects supported by both the canvas preview and ASS export.
class TextClipStylePreset {
  final String name;
  final String description;
  final SubtitleStyleModel style;

  const TextClipStylePreset({
    required this.name,
    required this.description,
    required this.style,
  });
}

const textClipStylePresets = <TextClipStylePreset>[
  TextClipStylePreset(
    name: 'Clean Title',
    description: 'Crisp and versatile',
    style: SubtitleStyleModel(
      fontFamily: 'Inter',
      fontSize: 36,
      isBold: true,
      position: SubtitlePosition.center,
      maxWidthFactor: 0.82,
      backgroundType: SubtitleBackground.outlineShadow,
      animationPreset: SubtitleAnimationPreset.lineFade,
    ),
  ),
  TextClipStylePreset(
    name: 'Social Pop',
    description: 'Bold high-energy hook',
    style: SubtitleStyleModel(
      fontFamily: 'Poppins',
      fontSize: 34,
      textColor: Colors.black,
      backgroundColor: Color(0xFFFFD54F),
      backgroundOpacity: 1,
      backgroundType: SubtitleBackground.semiTransparentBox,
      isBold: true,
      isAllCaps: true,
      position: SubtitlePosition.center,
      maxWidthFactor: 0.82,
      animationPreset: SubtitleAnimationPreset.wordPop,
    ),
  ),
  TextClipStylePreset(
    name: 'Cinema',
    description: 'Elegant editorial serif',
    style: SubtitleStyleModel(
      fontFamily: 'Playfair Display',
      fontSize: 38,
      textColor: Color(0xFFFFF8E1),
      backgroundType: SubtitleBackground.outlineShadow,
      isBold: true,
      position: SubtitlePosition.center,
      maxWidthFactor: 0.88,
      animationPreset: SubtitleAnimationPreset.zoomIn,
    ),
  ),
  TextClipStylePreset(
    name: 'Neon Tech',
    description: 'Digital and electric',
    style: SubtitleStyleModel(
      fontFamily: 'Space Mono',
      fontSize: 30,
      textColor: Color(0xFF62F6FF),
      backgroundColor: Color(0xFF081018),
      backgroundOpacity: 0.88,
      backgroundType: SubtitleBackground.semiTransparentBox,
      isBold: true,
      position: SubtitlePosition.center,
      maxWidthFactor: 0.84,
      animationPreset: SubtitleAnimationPreset.typewriter,
    ),
  ),
  TextClipStylePreset(
    name: 'Editorial',
    description: 'Minimal magazine look',
    style: SubtitleStyleModel(
      fontFamily: 'Montserrat',
      fontSize: 30,
      textColor: Colors.white,
      backgroundType: SubtitleBackground.none,
      isBold: true,
      position: SubtitlePosition.center,
      maxWidthFactor: 0.74,
      animationPreset: SubtitleAnimationPreset.slideFromLeft,
    ),
  ),
  TextClipStylePreset(
    name: 'Playful',
    description: 'Friendly creator intro',
    style: SubtitleStyleModel(
      fontFamily: 'Poppins',
      fontSize: 34,
      textColor: Color(0xFFFF8A80),
      backgroundType: SubtitleBackground.outlineShadow,
      isBold: true,
      position: SubtitlePosition.center,
      maxWidthFactor: 0.82,
      animationPreset: SubtitleAnimationPreset.bounceIn,
    ),
  ),
];

enum _TextEditorPanel { presets, style, animation }

/// Keyboard-safe editor for a visual text clip.
///
/// The parent owns the live timeline mutation and undo transaction; this
/// widget owns only presentation and a lightweight replayable sample preview.
class TextClipEditorSheet extends StatefulWidget {
  final String title;
  final TextEditingController controller;
  final FocusNode focusNode;
  final SubtitleStyleModel initialStyle;
  final bool autofocus;
  final ValueChanged<String> onTextChanged;
  final ValueChanged<SubtitleStyleModel> onStyleChanged;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  const TextClipEditorSheet({
    super.key,
    required this.title,
    required this.controller,
    required this.focusNode,
    required this.initialStyle,
    required this.onTextChanged,
    required this.onStyleChanged,
    required this.onDone,
    required this.onCancel,
    this.autofocus = false,
  });

  @override
  State<TextClipEditorSheet> createState() => _TextClipEditorSheetState();
}

class _TextClipEditorSheetState extends State<TextClipEditorSheet>
    with SingleTickerProviderStateMixin {
  static const _sampleDuration = Duration(milliseconds: 1800);
  static const _textColors = [
    Colors.white,
    Color(0xFFFFD166),
    Color(0xFFFF8A80),
    Color(0xFF80D8FF),
    Color(0xFFB9F6CA),
    Color(0xFF62F6FF),
    Colors.black,
  ];
  static const _backgroundColors = [
    Colors.black,
    Color(0xFF171A2B),
    Color(0xFF4A148C),
    Color(0xFFB71C1C),
    Color(0xFFFFD54F),
    Colors.white,
  ];

  late SubtitleStyleModel _style;
  late final AnimationController _previewController;
  _TextEditorPanel _activePanel = _TextEditorPanel.presets;

  @override
  void initState() {
    super.initState();
    _style = widget.initialStyle;
    _previewController = AnimationController(
      vsync: this,
      duration: _sampleDuration,
      value: 1,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _replayPreview();
    });
  }

  @override
  void dispose() {
    _previewController.dispose();
    super.dispose();
  }

  void _updateStyle(SubtitleStyleModel next, {bool replay = false}) {
    setState(() => _style = next);
    widget.onStyleChanged(next);
    if (replay) _replayPreview();
  }

  void _applyPreset(TextClipStylePreset preset) {
    final next = preset.style.copyWith(
      position: _style.position,
      verticalOffset: _style.verticalOffset,
      offsetX: _style.offsetX,
      offsetY: _style.offsetY,
      textAlignment: _style.textAlignment,
    );
    _updateStyle(next, replay: true);
  }

  void _replayPreview() {
    _previewController.stop();
    if (_style.animationPreset == null ||
        MediaQuery.of(context).disableAnimations) {
      _previewController.value = 1;
      return;
    }
    _previewController.forward(from: 0);
  }

  void _handleTextChanged(String value) {
    setState(() {});
    widget.onTextChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    return ResizableEditorSheet(
      key: const ValueKey('text_clip_editor_sheet'),
      title: widget.title,
      subtitle: 'Edit live while the canvas stays visible',
      icon: Icons.title_rounded,
      initialHeightFactor: 0.66,
      minHeightFactor: 0.48,
      maxHeightFactor: 0.92,
      scrollable: false,
      contentPadding: EdgeInsets.zero,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            key: const ValueKey('text_editor_cancel'),
            onPressed: widget.onCancel,
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('text_editor_done'),
            onPressed: widget.onDone,
            child: const Text('Done'),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 280;
          return Column(
            children: [
              _buildSamplePreview(height: compact ? 80 : 104),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: TextField(
                  key: const ValueKey('text_editor_field'),
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  autofocus: widget.autofocus,
                  minLines: 1,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  style: TextStyle(
                    color: kTextPrimary,
                    fontFamily: CaptionFontService.resolveFamily(
                      _style.fontFamily,
                    ),
                    fontWeight: _style.isBold
                        ? FontWeight.w700
                        : FontWeight.w500,
                    fontStyle: _style.isItalic
                        ? FontStyle.italic
                        : FontStyle.normal,
                    fontSize: 17,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Type your title or message',
                    filled: true,
                    fillColor: kSurfaceElevated,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(13),
                      borderSide: const BorderSide(color: kBorder),
                    ),
                    suffixIcon: IconButton(
                      tooltip: 'Hide keyboard',
                      onPressed: widget.focusNode.unfocus,
                      icon: const Icon(Icons.keyboard_hide_rounded, size: 20),
                    ),
                  ),
                  onChanged: _handleTextChanged,
                ),
              ),
              _buildPanelPicker(),
              const Divider(height: 1, color: kBorder),
              Expanded(child: _buildActivePanel()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSamplePreview({required double height}) {
    return RepaintBoundary(
      child: Container(
        key: const ValueKey('text_editor_sample_preview'),
        height: height,
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: kBorder),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF212438), Color(0xFF090A10)],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: const _PreviewGridPainter()),
            ),
            Positioned.fill(
              child: Center(
                child: AnimatedBuilder(
                  animation: _previewController,
                  builder: (context, _) {
                    final previewText = widget.controller.text.trim().isEmpty
                        ? 'Your text'
                        : widget.controller.text.trim();
                    final previewStyle = _style.copyWith(
                      position: SubtitlePosition.center,
                      verticalOffset: 0,
                      offsetX: 0,
                      offsetY: 0,
                      maxWidthFactor: _style.maxWidthFactor.clamp(0.45, 0.94),
                    );
                    return AnimatedSubtitleOverlay(
                      entry: SubtitleEntry(
                        id: 'text-editor-preview',
                        startTime: Duration.zero,
                        endTime: _sampleDuration,
                        text: previewText,
                        styleOverride: previewStyle,
                      ),
                      globalStyle: previewStyle,
                      currentPosition: Duration(
                        milliseconds:
                            (_sampleDuration.inMilliseconds *
                                    _previewController.value)
                                .round(),
                      ),
                      scaleFactor: 0.48,
                    );
                  },
                ),
              ),
            ),
            Positioned(
              right: 6,
              top: 5,
              child: Material(
                color: Colors.black.withValues(alpha: 0.32),
                shape: const CircleBorder(),
                child: IconButton(
                  key: const ValueKey('text_editor_replay_preview'),
                  tooltip: 'Replay text animation',
                  visualDensity: VisualDensity.compact,
                  onPressed: _replayPreview,
                  icon: const Icon(Icons.replay_rounded, size: 18),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanelPicker() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 7),
      child: Row(
        children: [
          _PanelButton(
            key: const ValueKey('text_editor_tab_presets'),
            icon: Icons.auto_awesome_rounded,
            label: 'Presets',
            selected: _activePanel == _TextEditorPanel.presets,
            onTap: () =>
                setState(() => _activePanel = _TextEditorPanel.presets),
          ),
          _PanelButton(
            key: const ValueKey('text_editor_tab_style'),
            icon: Icons.text_format_rounded,
            label: 'Style',
            selected: _activePanel == _TextEditorPanel.style,
            onTap: () => setState(() => _activePanel = _TextEditorPanel.style),
          ),
          _PanelButton(
            key: const ValueKey('text_editor_tab_animation'),
            icon: Icons.animation_rounded,
            label: 'Animate',
            selected: _activePanel == _TextEditorPanel.animation,
            onTap: () =>
                setState(() => _activePanel = _TextEditorPanel.animation),
          ),
        ],
      ),
    );
  }

  Widget _buildActivePanel() {
    return switch (_activePanel) {
      _TextEditorPanel.presets => _buildPresetsPanel(),
      _TextEditorPanel.style => _buildStylePanel(),
      _TextEditorPanel.animation => _buildAnimationPanel(),
    };
  }

  Widget _buildPresetsPanel() {
    return SingleChildScrollView(
      key: const PageStorageKey('text_editor_presets_panel'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = (constraints.maxWidth - 10) / 2;
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final preset in textClipStylePresets)
                SizedBox(
                  width: width,
                  child: _TextPresetCard(
                    preset: preset,
                    onTap: () => _applyPreset(preset),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStylePanel() {
    return SingleChildScrollView(
      key: const PageStorageKey('text_editor_style_panel'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ControlLabel('Font'),
          const SizedBox(height: 7),
          SizedBox(
            height: 58,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: CaptionFontService.supportedFamilies.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final font = CaptionFontService.supportedFamilies[index];
                final selected = _style.fontFamily == font;
                return InkWell(
                  key: ValueKey('text_editor_font_$font'),
                  borderRadius: BorderRadius.circular(11),
                  onTap: () => _updateStyle(_style.copyWith(fontFamily: font)),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 104,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: selected
                          ? kAccent.withValues(alpha: 0.14)
                          : kSurfaceElevated,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: selected ? kAccent : kBorder),
                    ),
                    child: Text(
                      font,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? kAccent : kTextPrimary,
                        fontFamily: font,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _FormatButton(
                icon: Icons.format_bold_rounded,
                label: 'Bold',
                selected: _style.isBold,
                onTap: () =>
                    _updateStyle(_style.copyWith(isBold: !_style.isBold)),
              ),
              _FormatButton(
                icon: Icons.format_italic_rounded,
                label: 'Italic',
                selected: _style.isItalic,
                onTap: () =>
                    _updateStyle(_style.copyWith(isItalic: !_style.isItalic)),
              ),
              _FormatButton(
                icon: Icons.text_increase_rounded,
                label: 'Caps',
                selected: _style.isAllCaps,
                onTap: () =>
                    _updateStyle(_style.copyWith(isAllCaps: !_style.isAllCaps)),
              ),
              const Spacer(),
              for (final alignment in const [
                TextAlign.left,
                TextAlign.center,
                TextAlign.right,
              ])
                _IconFormatButton(
                  icon: switch (alignment) {
                    TextAlign.left => Icons.format_align_left_rounded,
                    TextAlign.right => Icons.format_align_right_rounded,
                    _ => Icons.format_align_center_rounded,
                  },
                  selected: _style.textAlignment == alignment,
                  onTap: () =>
                      _updateStyle(_style.copyWith(textAlignment: alignment)),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const _ControlLabel('Size'),
              Expanded(
                child: Slider(
                  value: _style.fontSize.clamp(10, 72),
                  min: 10,
                  max: 72,
                  onChanged: (value) =>
                      _updateStyle(_style.copyWith(fontSize: value)),
                ),
              ),
              SizedBox(
                width: 34,
                child: Text(
                  _style.fontSize.round().toString(),
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          const _ControlLabel('Text color'),
          const SizedBox(height: 8),
          _ColorRow(
            colors: _textColors,
            selected: _style.textColor,
            keyPrefix: 'text_editor_text_color',
            onSelected: (color) =>
                _updateStyle(_style.copyWith(textColor: color)),
          ),
          const SizedBox(height: 15),
          const _ControlLabel('Background'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final background in SubtitleBackground.values)
                ChoiceChip(
                  key: ValueKey('text_editor_background_${background.name}'),
                  label: Text(switch (background) {
                    SubtitleBackground.none => 'None',
                    SubtitleBackground.semiTransparentBox => 'Box',
                    SubtitleBackground.fullBar => 'Bar',
                    SubtitleBackground.outlineShadow => 'Shadow',
                  }),
                  selected: _style.backgroundType == background,
                  onSelected: (_) =>
                      _updateStyle(_style.copyWith(backgroundType: background)),
                ),
            ],
          ),
          if (_style.backgroundType != SubtitleBackground.none &&
              _style.backgroundType != SubtitleBackground.outlineShadow) ...[
            const SizedBox(height: 12),
            _ColorRow(
              colors: _backgroundColors,
              selected: _style.backgroundColor,
              keyPrefix: 'text_editor_background_color',
              onSelected: (color) =>
                  _updateStyle(_style.copyWith(backgroundColor: color)),
            ),
            Row(
              children: [
                const _ControlLabel('Opacity'),
                Expanded(
                  child: Slider(
                    value: _style.backgroundOpacity,
                    min: 0.15,
                    max: 1,
                    onChanged: (value) =>
                        _updateStyle(_style.copyWith(backgroundOpacity: value)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAnimationPanel() {
    return SingleChildScrollView(
      key: const PageStorageKey('text_editor_animation_panel'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = (constraints.maxWidth - 10) / 2;
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: width,
                child: _StaticAnimationCard(
                  selected: _style.animationPreset == null,
                  onTap: () => _updateStyle(
                    _style.copyWith(clearAnimationPreset: true),
                    replay: true,
                  ),
                ),
              ),
              for (final preset in SubtitleAnimationPreset.values)
                SizedBox(
                  width: width,
                  child: AnimationPresetCard(
                    preset: preset,
                    isSelected: _style.animationPreset == preset,
                    onTap: () => _updateStyle(
                      _style.copyWith(animationPreset: preset),
                      replay: true,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PanelButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PanelButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? kAccent.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: selected ? kAccent : kTextSecondary),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: selected ? kAccent : kTextSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextPresetCard extends StatelessWidget {
  final TextClipStylePreset preset;
  final VoidCallback onTap;

  const _TextPresetCard({required this.preset, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final style = preset.style;
    return InkWell(
      key: ValueKey('text_editor_preset_${preset.name}'),
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      child: Container(
        height: 92,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: kSurfaceElevated,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: kBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color:
                        style.backgroundType ==
                            SubtitleBackground.semiTransparentBox
                        ? style.backgroundColor.withValues(
                            alpha: style.backgroundOpacity,
                          )
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    child: Text(
                      style.isAllCaps ? 'Aa'.toUpperCase() : 'Aa',
                      style: TextStyle(
                        fontFamily: CaptionFontService.resolveFamily(
                          style.fontFamily,
                        ),
                        color: style.textColor,
                        fontSize: 22,
                        fontWeight: style.isBold
                            ? FontWeight.bold
                            : FontWeight.normal,
                        fontStyle: style.isItalic
                            ? FontStyle.italic
                            : FontStyle.normal,
                        shadows:
                            style.backgroundType ==
                                SubtitleBackground.outlineShadow
                            ? const [Shadow(color: Colors.black, blurRadius: 4)]
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Text(
              preset.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kTextPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              preset.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kTextSecondary, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class _FormatButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FormatButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: label,
        child: _IconFormatButton(icon: icon, selected: selected, onTap: onTap),
      ),
    );
  }
}

class _IconFormatButton extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _IconFormatButton({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 36,
        height: 36,
        margin: const EdgeInsets.only(left: 3),
        decoration: BoxDecoration(
          color: selected ? kAccent.withValues(alpha: 0.16) : kSurfaceElevated,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: selected ? kAccent : kBorder),
        ),
        child: Icon(icon, size: 18, color: selected ? kAccent : kTextSecondary),
      ),
    );
  }
}

class _ColorRow extends StatelessWidget {
  final List<Color> colors;
  final Color selected;
  final String keyPrefix;
  final ValueChanged<Color> onSelected;

  const _ColorRow({
    required this.colors,
    required this.selected,
    required this.keyPrefix,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final color in colors)
            Padding(
              padding: const EdgeInsets.only(right: 9),
              child: InkWell(
                key: ValueKey(
                  '${keyPrefix}_${color.toARGB32().toRadixString(16)}',
                ),
                borderRadius: BorderRadius.circular(999),
                onTap: () => onSelected(color),
                child: Container(
                  width: 31,
                  height: 31,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected == color ? kAccent : kBorder,
                      width: selected == color ? 3 : 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StaticAnimationCard extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;

  const _StaticAnimationCard({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('text_editor_animation_static'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? kAccent.withValues(alpha: 0.15) : kSurfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? kAccent : kBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.text_fields_rounded,
              color: selected ? kAccent : kTextSecondary,
              size: 24,
            ),
            const SizedBox(height: 6),
            Text(
              'Static',
              style: TextStyle(
                color: selected ? kAccent : kTextPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'No entrance animation',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextSecondary, fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlLabel extends StatelessWidget {
  final String text;

  const _ControlLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: kTextSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.35,
      ),
    );
  }
}

class _PreviewGridPainter extends CustomPainter {
  const _PreviewGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.045)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 2 / 3, 0),
      Offset(size.width * 2 / 3, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PreviewGridPainter oldDelegate) => false;
}
