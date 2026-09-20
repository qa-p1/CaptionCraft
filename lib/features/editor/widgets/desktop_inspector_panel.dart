import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../models/timeline_models.dart';

typedef DesktopTransformChanged =
    void Function(
      TimelineTransform Function(TimelineTransform current) mapper,
      bool recordHistory,
    );

typedef DesktopVolumeChanged = void Function(double volume, bool recordHistory);

/// Contextual right-hand inspector for the selected clip.
///
/// The widget owns only editor chrome and text field state. All project edits
/// are delegated to [DesktopTransformChanged] and the callbacks supplied by
/// [EditorScreen], so keyframes, undo grouping and provider selection remain
/// authoritative in the existing editor model.
class DesktopInspectorPanel extends StatefulWidget {
  final TimelineClip? clip;
  final TimelineTrack? track;
  final Duration playheadPosition;
  final bool canEdit;
  final bool canAdjustAudio;
  final bool canOpenEffects;
  final bool canAnimate;
  final bool canOpenTiming;
  final bool canEditCaptions;
  final DesktopTransformChanged? onTransformChanged;
  final VoidCallback? onTransformGestureStart;
  final VoidCallback? onTransformGestureEnd;
  final DesktopVolumeChanged? onVolumeChanged;
  final VoidCallback? onVolumeGestureStart;
  final VoidCallback? onVolumeGestureEnd;
  final ValueChanged<ClipFitMode>? onFitModeChanged;
  final VoidCallback? onToggleFlipX;
  final VoidCallback? onToggleFlipY;
  final VoidCallback? onResetTransform;
  final VoidCallback? onOpenEffects;
  final VoidCallback? onOpenAnimation;
  final VoidCallback? onOpenTiming;
  final VoidCallback? onOpenAudio;
  final VoidCallback? onOpenCaptions;
  final VoidCallback? onEditText;
  final VoidCallback? onToggleMute;
  final ValueChanged<bool>? onToggleEnabled;
  final VoidCallback? onDuplicate;
  final VoidCallback? onDelete;
  final VoidCallback? onSetNote;

  const DesktopInspectorPanel({
    super.key,
    required this.clip,
    required this.track,
    required this.playheadPosition,
    required this.canEdit,
    required this.canAdjustAudio,
    required this.canOpenEffects,
    required this.canAnimate,
    required this.canOpenTiming,
    required this.canEditCaptions,
    this.onTransformChanged,
    this.onTransformGestureStart,
    this.onTransformGestureEnd,
    this.onVolumeChanged,
    this.onVolumeGestureStart,
    this.onVolumeGestureEnd,
    this.onFitModeChanged,
    this.onToggleFlipX,
    this.onToggleFlipY,
    this.onResetTransform,
    this.onOpenEffects,
    this.onOpenAnimation,
    this.onOpenTiming,
    this.onOpenAudio,
    this.onOpenCaptions,
    this.onEditText,
    this.onToggleMute,
    this.onToggleEnabled,
    this.onDuplicate,
    this.onDelete,
    this.onSetNote,
  });

  @override
  State<DesktopInspectorPanel> createState() => _DesktopInspectorPanelState();
}

class _DesktopInspectorPanelState extends State<DesktopInspectorPanel> {
  final TextEditingController _positionXController = TextEditingController();
  final TextEditingController _positionYController = TextEditingController();
  final TextEditingController _scaleController = TextEditingController();
  final TextEditingController _rotationController = TextEditingController();
  final TextEditingController _opacityController = TextEditingController();
  final FocusNode _positionXFocusNode = FocusNode();
  final FocusNode _positionYFocusNode = FocusNode();
  final FocusNode _scaleFocusNode = FocusNode();
  final FocusNode _rotationFocusNode = FocusNode();
  final FocusNode _opacityFocusNode = FocusNode();
  String? _controllerClipId;
  final Map<FocusNode, String> _editingOriginals = <FocusNode, String>{};
  final Map<FocusNode, ValueChanged<String>> _commitCallbacks =
      <FocusNode, ValueChanged<String>>{};

  @override
  void initState() {
    super.initState();
    for (final focusNode in _focusNodes) {
      focusNode.addListener(_handleFocusChange);
    }
    _syncControllers(force: true);
  }

  @override
  void didUpdateWidget(covariant DesktopInspectorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final clipChanged = oldWidget.clip?.id != widget.clip?.id;
    if (clipChanged || (oldWidget.canEdit && !widget.canEdit)) {
      // A pending field edit belongs to the old selection. Blurring after a
      // rebuild must not create an edit or undo entry on the new clip.
      _editingOriginals.clear();
      for (final node in _focusNodes) {
        node.unfocus();
      }
    }
    _syncControllers(force: clipChanged);
  }

  @override
  void dispose() {
    _positionXController.dispose();
    _positionYController.dispose();
    _scaleController.dispose();
    _rotationController.dispose();
    _opacityController.dispose();
    for (final focusNode in _focusNodes) {
      focusNode
        ..removeListener(_handleFocusChange)
        ..dispose();
    }
    super.dispose();
  }

  Iterable<FocusNode> get _focusNodes => [
    _positionXFocusNode,
    _positionYFocusNode,
    _scaleFocusNode,
    _rotationFocusNode,
    _opacityFocusNode,
  ];

  void _handleFocusChange() {
    if (!mounted) return;
    final fields = _fieldControllers;
    for (final entry in fields.entries) {
      final node = entry.key;
      final controller = entry.value;
      if (node.hasFocus) {
        _editingOriginals.putIfAbsent(node, () => controller.text);
        continue;
      }
      final original = _editingOriginals.remove(node);
      if (original != null && original != controller.text) {
        _commitCallbacks[node]?.call(controller.text);
      }
    }
    _syncControllers();
  }

  Map<FocusNode, TextEditingController> get _fieldControllers => {
    _positionXFocusNode: _positionXController,
    _positionYFocusNode: _positionYController,
    _scaleFocusNode: _scaleController,
    _rotationFocusNode: _rotationController,
    _opacityFocusNode: _opacityController,
  };

  void _beginEditing(FocusNode focusNode) {
    final controller = _fieldControllers[focusNode];
    if (controller == null) return;
    _editingOriginals[focusNode] = controller.text;
  }

  void _cancelEditing(FocusNode focusNode) {
    final original = _editingOriginals.remove(focusNode);
    if (original == null) return;
    final controller = _fieldControllers[focusNode];
    if (controller != null) _setController(controller, original);
  }

  KeyEventResult _handleFieldKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelEditing(focusNode);
      focusNode.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _syncControllers({bool force = false}) {
    final clip = widget.clip;
    if (clip == null) {
      _controllerClipId = null;
      for (final controller in _controllers) {
        controller.clear();
      }
      return;
    }
    final transform = clip.transformAt(widget.playheadPosition);
    final clipChanged = _controllerClipId != clip.id;
    _controllerClipId = clip.id;
    if (force || clipChanged || !_positionXFocusNode.hasFocus) {
      _setController(_positionXController, _format(transform.offsetX));
    }
    if (force || clipChanged || !_positionYFocusNode.hasFocus) {
      _setController(_positionYController, _format(transform.offsetY));
    }
    if (force || clipChanged || !_scaleFocusNode.hasFocus) {
      _setController(_scaleController, _format(transform.scale));
    }
    if (force || clipChanged || !_rotationFocusNode.hasFocus) {
      _setController(
        _rotationController,
        _format(transform.rotation * 180 / math.pi),
      );
    }
    if (force || clipChanged || !_opacityFocusNode.hasFocus) {
      _setController(_opacityController, _format(transform.opacity * 100));
    }
  }

  Iterable<TextEditingController> get _controllers => [
    _positionXController,
    _positionYController,
    _scaleController,
    _rotationController,
    _opacityController,
  ];

  void _setController(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  String _format(double value) {
    if (!value.isFinite) return '0';
    final rounded = (value * 100).round() / 100;
    return rounded.toStringAsFixed(rounded == rounded.roundToDouble() ? 0 : 2);
  }

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    if (clip == null) return _buildNoSelection();
    final transform = clip.transformAt(widget.playheadPosition);
    final volume = clip.volumeAt(widget.playheadPosition);
    final visual = clip.supportsTransform;
    final selectedTrackName = widget.track?.name ?? 'Selected item';

    return ColoredBox(
      color: kSurface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 20),
        children: [
          _buildSelectionHeader(clip, selectedTrackName),
          const SizedBox(height: 8),
          if (visual) ...[
            _buildTransformSection(clip, transform),
            const SizedBox(height: 6),
          ],
          _buildAnimationSection(clip),
          const SizedBox(height: 6),
          _buildEffectsSection(clip),
          const SizedBox(height: 6),
          if (widget.canAdjustAudio || clip.type == TimelineTrackType.audio)
            _buildAudioSection(clip, volume),
          if (clip.type == TimelineTrackType.subtitle ||
              clip.type == TimelineTrackType.text) ...[
            const SizedBox(height: 6),
            _buildCaptionsSection(clip),
          ],
          const SizedBox(height: 6),
          _buildActionsSection(clip),
        ],
      ),
    );
  }

  Widget _buildNoSelection() {
    return ColoredBox(
      color: kSurface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tune_rounded, size: 30, color: kTextTertiary),
              const SizedBox(height: 10),
              const Text(
                'Nothing selected',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Select a clip in the viewer or timeline to inspect its properties.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: kTextSecondary,
                  fontSize: 10,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionHeader(TimelineClip clip, String trackName) {
    final locked = !widget.canEdit;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: locked ? kBorder : kAccent),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(_clipIcon(clip), size: 17, color: kAccent),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  clip.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  locked ? '$trackName · locked' : trackName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: locked ? kWarning : kTextSecondary,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
          if (locked)
            const Tooltip(
              message: 'Unlock the track to edit this clip',
              child: Icon(
                Icons.lock_outline_rounded,
                size: 16,
                color: kWarning,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTransformSection(
    TimelineClip clip,
    TimelineTransform transform,
  ) {
    final enabled = widget.canEdit && widget.onTransformChanged != null;
    return _section(
      title: 'Transform',
      icon: Icons.open_with_rounded,
      initiallyExpanded: true,
      children: [
        Row(
          children: [
            Expanded(
              child: _numberField(
                label: 'X',
                controller: _positionXController,
                focusNode: _positionXFocusNode,
                suffix: '',
                enabled: enabled,
                onSubmitted: (value) => _submitTransform(
                  value,
                  (current, parsed) => current.copyWith(offsetX: parsed),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _numberField(
                label: 'Y',
                controller: _positionYController,
                focusNode: _positionYFocusNode,
                suffix: '',
                enabled: enabled,
                onSubmitted: (value) => _submitTransform(
                  value,
                  (current, parsed) => current.copyWith(offsetY: parsed),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _numberField(
                label: 'Scale',
                controller: _scaleController,
                focusNode: _scaleFocusNode,
                suffix: '×',
                enabled: enabled,
                onSubmitted: (value) => _submitTransform(
                  value,
                  (current, parsed) => current.copyWith(scale: parsed),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _numberField(
                label: 'Rotation',
                controller: _rotationController,
                focusNode: _rotationFocusNode,
                suffix: '°',
                enabled: enabled,
                onSubmitted: (value) => _submitTransform(
                  value,
                  (current, parsed) =>
                      current.copyWith(rotation: parsed * math.pi / 180),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _numberField(
          label: 'Opacity',
          controller: _opacityController,
          focusNode: _opacityFocusNode,
          suffix: '%',
          enabled: enabled,
          onSubmitted: (value) => _submitTransform(
            value,
            (current, parsed) => current.copyWith(
              opacity: (parsed / 100).clamp(0.0, 1.0).toDouble(),
            ),
          ),
        ),
        const SizedBox(height: 7),
        _sliderRow(
          label: 'Opacity',
          valueLabel: '${(transform.opacity * 100).round()}%',
          value: transform.opacity.clamp(0.0, 1.0),
          enabled: enabled,
          min: 0,
          max: 1,
          divisions: 100,
          onChangeStart: (_) => widget.onTransformGestureStart?.call(),
          onChanged: (value) => widget.onTransformChanged?.call(
            (current) => current.copyWith(opacity: value),
            false,
          ),
          onChangeEnd: (_) => widget.onTransformGestureEnd?.call(),
        ),
        const SizedBox(height: 7),
        _sliderRow(
          label: 'Scale',
          valueLabel: '${transform.scale.toStringAsFixed(2)}×',
          value: transform.scale.clamp(0.05, 4.0),
          enabled: enabled,
          min: 0.05,
          max: 4,
          divisions: 395,
          onChangeStart: (_) => widget.onTransformGestureStart?.call(),
          onChanged: (value) => widget.onTransformChanged?.call(
            (current) => current.copyWith(scale: value),
            false,
          ),
          onChangeEnd: (_) => widget.onTransformGestureEnd?.call(),
        ),
        const SizedBox(height: 8),
        Text(
          'Fit mode',
          style: const TextStyle(
            color: kTextSecondary,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: ClipFitMode.values
              .map(
                (fit) => ChoiceChip(
                  label: Text(_fitLabel(fit)),
                  selected: clip.fitMode == fit,
                  onSelected: enabled
                      ? (_) => widget.onFitModeChanged?.call(fit)
                      : null,
                  visualDensity: const VisualDensity(
                    horizontal: -3,
                    vertical: -3,
                  ),
                  labelStyle: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _smallAction(
                icon: Icons.flip_rounded,
                label: 'Mirror',
                active: transform.flipX,
                enabled: enabled,
                onTap: widget.onToggleFlipX,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _smallAction(
                icon: Icons.flip_camera_android_rounded,
                label: 'Flip V',
                active: transform.flipY,
                enabled: enabled,
                onTap: widget.onToggleFlipY,
              ),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: 'Reset transform',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? widget.onResetTransform : null,
                icon: const Icon(Icons.restart_alt_rounded, size: 17),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAnimationSection(TimelineClip clip) {
    final enabled = widget.canEdit && widget.canAnimate;
    return _section(
      title: 'Animation',
      icon: Icons.auto_awesome_motion_rounded,
      children: [
        _inspectorAction(
          icon: Icons.auto_awesome_motion_rounded,
          title: clip.hasKeyframes ? 'Keyframed motion' : 'Clip animation',
          subtitle: clip.hasKeyframes
              ? '${clip.keyframeStateTimes.length} animated state${clip.keyframeStateTimes.length == 1 ? '' : 's'}'
              : 'Entrance, exit and motion presets',
          enabled: enabled,
          onTap: widget.onOpenAnimation,
        ),
      ],
    );
  }

  Widget _buildEffectsSection(TimelineClip clip) {
    final count = clip.effectStack.effects.length;
    return _section(
      title: 'Effects',
      icon: Icons.auto_fix_high_rounded,
      children: [
        _inspectorAction(
          icon: Icons.layers_rounded,
          title: count == 0 ? 'Add effect' : 'Effect stack · $count',
          subtitle: 'Visual effects, color and blur',
          enabled: widget.canEdit && widget.canOpenEffects,
          onTap: widget.onOpenEffects,
        ),
      ],
    );
  }

  Widget _buildAudioSection(TimelineClip clip, double volume) {
    final enabled = widget.canEdit && widget.canAdjustAudio;
    return _section(
      title: 'Audio',
      icon: Icons.graphic_eq_rounded,
      children: [
        _sliderRow(
          label: 'Volume',
          valueLabel: '${(volume * 100).round()}%',
          value: volume.clamp(0.0, 2.0),
          min: 0,
          max: 2,
          divisions: 200,
          enabled: enabled,
          onChangeStart: (_) => widget.onVolumeGestureStart?.call(),
          onChanged: (value) => widget.onVolumeChanged?.call(value, false),
          onChangeEnd: (_) => widget.onVolumeGestureEnd?.call(),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Expanded(
              child: _smallAction(
                icon: clip.audioMix.muted
                    ? Icons.volume_up_rounded
                    : Icons.volume_off_rounded,
                label: clip.audioMix.muted ? 'Unmute' : 'Mute',
                active: clip.audioMix.muted,
                enabled: enabled,
                onTap: widget.onToggleMute,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _smallAction(
                icon: Icons.tune_rounded,
                label: 'Mixer',
                enabled: enabled,
                onTap: widget.onOpenAudio,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCaptionsSection(TimelineClip clip) {
    final isCaption = clip.type == TimelineTrackType.subtitle;
    return _section(
      title: isCaption ? 'Caption' : 'Text',
      icon: isCaption ? Icons.closed_caption_outlined : Icons.title_rounded,
      children: [
        Text(
          clip.text ?? clip.label,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kTextPrimary,
            fontSize: 11,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 7),
        Row(
          children: [
            Expanded(
              child: _smallAction(
                icon: Icons.edit_rounded,
                label: isCaption ? 'Edit cue' : 'Edit text',
                enabled:
                    widget.canEdit &&
                    (isCaption ? widget.canEditCaptions : true),
                onTap: isCaption ? widget.onOpenCaptions : widget.onEditText,
              ),
            ),
            if (isCaption) ...[
              const SizedBox(width: 6),
              Expanded(
                child: _smallAction(
                  icon: Icons.closed_caption_rounded,
                  label: 'Caption tools',
                  enabled: widget.onOpenCaptions != null,
                  onTap: widget.onOpenCaptions,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildActionsSection(TimelineClip clip) {
    return _section(
      title: 'Clip actions',
      icon: Icons.more_horiz_rounded,
      children: [
        Row(
          children: [
            Expanded(
              child: _smallAction(
                icon: Icons.content_copy_rounded,
                label: 'Duplicate',
                enabled: widget.canEdit,
                onTap: widget.onDuplicate,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _smallAction(
                icon: clip.enabled
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                label: clip.enabled ? 'Disable' : 'Enable',
                enabled: widget.canEdit,
                onTap: () => widget.onToggleEnabled?.call(!clip.enabled),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _smallAction(
                icon: Icons.sticky_note_2_outlined,
                label: clip.notes?.trim().isNotEmpty == true
                    ? 'Edit note'
                    : 'Add note',
                active: clip.notes?.trim().isNotEmpty == true,
                enabled: widget.canEdit,
                onTap: widget.onSetNote,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _smallAction(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                enabled: widget.canEdit,
                onTap: widget.onDelete,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        if (widget.canOpenTiming)
          _inspectorAction(
            icon: Icons.av_timer_rounded,
            title: 'Timing and source',
            subtitle: 'Duration, speed and source range',
            enabled: widget.canEdit,
            onTap: widget.onOpenTiming,
          ),
      ],
    );
  }

  Widget _section({
    required String title,
    required IconData icon,
    required List<Widget> children,
    bool initiallyExpanded = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: kBorder),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          visualDensity: const VisualDensity(vertical: -3),
          leading: Icon(icon, size: 17, color: kTextSecondary),
          title: Text(
            title,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
          children: children,
        ),
      ),
    );
  }

  Widget _sliderRow({
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required bool enabled,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeStart,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: kTextSecondary,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              valueLabel,
              style: const TextStyle(
                color: kTextPrimary,
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChangeStart: enabled ? onChangeStart : null,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: enabled ? onChangeEnd : null,
          ),
        ),
      ],
    );
  }

  Widget _numberField({
    required String label,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String suffix,
    required bool enabled,
    required ValueChanged<String> onSubmitted,
  }) {
    _commitCallbacks[focusNode] = onSubmitted;
    return Focus(
      onFocusChange: (focused) {
        if (focused) _beginEditing(focusNode);
      },
      onKeyEvent: (_, event) => _handleFieldKeyEvent(focusNode, event),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        textInputAction: TextInputAction.done,
        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
        onSubmitted: (value) {
          _editingOriginals.remove(focusNode);
          onSubmitted(value);
          focusNode.unfocus();
        },
        onEditingComplete: focusNode.unfocus,
        onTapOutside: (_) {
          if (focusNode.hasFocus) focusNode.unfocus();
        },
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffix.isEmpty ? null : suffix,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
        ),
      ),
    );
  }

  void _submitTransform(
    String value,
    TimelineTransform Function(TimelineTransform current, double parsed) mapper,
  ) {
    if (!widget.canEdit || widget.clip == null) return;
    final parsed = double.tryParse(value.trim());
    if (parsed == null || !parsed.isFinite) {
      _syncControllers();
      return;
    }
    widget.onTransformChanged?.call((current) => mapper(current, parsed), true);
  }

  Widget _smallAction({
    required IconData icon,
    required String label,
    required bool enabled,
    VoidCallback? onTap,
    bool active = false,
  }) {
    final effectiveOnTap = enabled ? onTap : null;
    return OutlinedButton.icon(
      onPressed: effectiveOnTap,
      icon: Icon(icon, size: 14),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        foregroundColor: active ? kAccent : kTextPrimary,
        side: BorderSide(color: active ? kAccent : kBorder),
        textStyle: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _inspectorAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool enabled,
    required VoidCallback? onTap,
  }) {
    final active = enabled && onTap != null;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        icon,
        size: 17,
        color: active ? kTextPrimary : kTextTertiary,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: active ? kTextPrimary : kTextTertiary,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 9),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, size: 16),
      onTap: active ? onTap : null,
    );
  }

  IconData _clipIcon(TimelineClip clip) => switch (clip.type) {
    TimelineTrackType.video => Icons.movie_outlined,
    TimelineTrackType.audio => Icons.audiotrack_rounded,
    TimelineTrackType.subtitle => Icons.closed_caption_outlined,
    TimelineTrackType.text => Icons.title_rounded,
    TimelineTrackType.image => Icons.image_outlined,
    TimelineTrackType.sticker => Icons.emoji_emotions_outlined,
    TimelineTrackType.gif => Icons.gif_box_outlined,
    TimelineTrackType.effect => Icons.auto_fix_high_rounded,
  };

  String _fitLabel(ClipFitMode fit) => switch (fit) {
    ClipFitMode.cover => 'Fill',
    ClipFitMode.contain => 'Fit',
    ClipFitMode.stretch => 'Stretch',
  };
}
