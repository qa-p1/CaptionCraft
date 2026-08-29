import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/media_import_service.dart';
import '../models/editor_effect_models.dart';
import '../models/asset_pack_models.dart';
import '../models/timeline_models.dart';
import '../providers/editor_provider.dart';
import '../providers/playback_provider.dart';

@immutable
class EffectStackTargetOption {
  final EditorEffectScope scope;
  final String? targetId;
  final String label;
  final String description;

  const EffectStackTargetOption({
    required this.scope,
    required this.targetId,
    required this.label,
    required this.description,
  });

  String get key => '${scope.name}:${targetId ?? 'project'}';
}

class EffectStackEditorSheet extends ConsumerStatefulWidget {
  final EditorEffectDomain domain;
  final List<EffectStackTargetOption> targets;
  final String initialTargetKey;

  const EffectStackEditorSheet({
    super.key,
    required this.domain,
    required this.targets,
    required this.initialTargetKey,
  });

  @override
  ConsumerState<EffectStackEditorSheet> createState() =>
      _EffectStackEditorSheetState();
}

class _EffectStackEditorSheetState
    extends ConsumerState<EffectStackEditorSheet> {
  late String _targetKey;
  String? _expandedEffectId;
  bool _clipboardAvailable = false;

  @override
  void initState() {
    super.initState();
    _targetKey =
        widget.targets.any((target) => target.key == widget.initialTargetKey)
        ? widget.initialTargetKey
        : widget.targets.first.key;
  }

  EffectStackTargetOption get _target => widget.targets.firstWhere(
    (candidate) => candidate.key == _targetKey,
    orElse: () => widget.targets.first,
  );

  Duration _effectTime(EditorTimeline timeline, Duration playhead) {
    if (_target.scope != EditorEffectScope.clip &&
        _target.scope != EditorEffectScope.adjustmentLayer) {
      return playhead;
    }
    final clip = timeline.tracks
        .expand((track) => track.clips)
        .where((candidate) => candidate.id == _target.targetId)
        .firstOrNull;
    if (clip == null) return Duration.zero;
    final relative = playhead - clip.startTime;
    if (relative.isNegative) return Duration.zero;
    return relative > clip.duration ? clip.duration : relative;
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(
      editorProvider.select((state) => state.timeline),
    );
    final playhead = ref.watch(
      playbackProvider.select((state) => state.position),
    );
    final notifier = ref.read(editorProvider.notifier);
    final stack = notifier.effectStackForTarget(
      scope: _target.scope,
      targetId: _target.targetId,
    );
    final domainStack = stack.copyWith(
      effects: stack.effects
          .where((effect) => effect.domain == widget.domain)
          .toList(),
    );
    _clipboardAvailable = _clipboardAvailable || notifier.hasCopiedEffectStack;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: kAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      widget.domain == EditorEffectDomain.visual
                          ? Icons.auto_awesome_motion_rounded
                          : Icons.graphic_eq_rounded,
                      color: kAccent,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.domain == EditorEffectDomain.visual
                              ? 'Effect Stack'
                              : 'Audio Processing',
                          style: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${domainStack.effects.length} effect${domainStack.effects.length == 1 ? '' : 's'} • top runs first',
                          style: const TextStyle(
                            color: kTextSecondary,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                key: ValueKey('effect_target_$_targetKey'),
                initialValue: _targetKey,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Apply to',
                  prefixIcon: const Icon(Icons.layers_outlined, size: 19),
                  filled: true,
                  fillColor: kSurfaceElevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(13),
                    borderSide: const BorderSide(color: kBorder),
                  ),
                ),
                items: [
                  for (final target in widget.targets)
                    DropdownMenuItem(
                      value: target.key,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            target.label,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kTextPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            target.description,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kTextSecondary,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                selectedItemBuilder: (context) => [
                  for (final target in widget.targets)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        target.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _targetKey = value;
                    _expandedEffectId = null;
                  });
                },
              ),
            ),
            const SizedBox(height: 9),
            SizedBox(
              height: 42,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                children: [
                  _ToolbarButton(
                    key: const ValueKey('effect_stack_add'),
                    icon: Icons.add_rounded,
                    label: 'Add effect',
                    emphasized: true,
                    onTap: _pickAndAddEffect,
                  ),
                  _ToolbarButton(
                    key: const ValueKey('effect_stack_copy'),
                    icon: Icons.copy_all_rounded,
                    label: 'Copy stack',
                    onTap: domainStack.isEmpty
                        ? null
                        : () {
                            final copied = notifier.copyEffectStackToClipboard(
                              scope: _target.scope,
                              targetId: _target.targetId,
                              domain: widget.domain,
                            );
                            if (copied) {
                              setState(() => _clipboardAvailable = true);
                              _showMessage('Effect stack copied');
                            }
                          },
                  ),
                  _ToolbarButton(
                    key: const ValueKey('effect_stack_paste'),
                    icon: Icons.content_paste_rounded,
                    label: 'Paste',
                    onTap: _clipboardAvailable
                        ? () => _pasteStack(append: false)
                        : null,
                  ),
                  _ToolbarButton(
                    key: const ValueKey('effect_stack_paste_append'),
                    icon: Icons.playlist_add_rounded,
                    label: 'Append',
                    onTap: _clipboardAvailable
                        ? () => _pasteStack(append: true)
                        : null,
                  ),
                  _ToolbarButton(
                    key: const ValueKey('effect_stack_presets'),
                    icon: Icons.bookmarks_outlined,
                    label: 'Presets',
                    onTap: () => _openPresets(timeline, domainStack),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: kBorder),
            Expanded(
              child: domainStack.isEmpty
                  ? _EmptyStack(domain: widget.domain, onAdd: _pickAndAddEffect)
                  : ReorderableListView.builder(
                      key: ValueKey('effect_stack_${_target.key}'),
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                      buildDefaultDragHandles: false,
                      itemCount: domainStack.effects.length,
                      onReorder: (oldIndex, newIndex) =>
                          _reorderDomainEffects(oldIndex, newIndex),
                      itemBuilder: (context, index) {
                        final effect = domainStack.effects[index];
                        return _buildEffectCard(
                          timeline: timeline,
                          effect: effect,
                          index: index,
                          playhead: playhead,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEffectCard({
    required EditorTimeline timeline,
    required EditorEffect effect,
    required int index,
    required Duration playhead,
  }) {
    final expanded = _expandedEffectId == effect.id;
    final effectTime = _effectTime(timeline, playhead);
    final parameterSpecs = _parameterSpecs(effect);
    return Container(
      key: ValueKey(effect.id),
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: expanded
              ? kAccent.withValues(alpha: 0.55)
              : kBorder.withValues(alpha: 0.9),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () =>
                setState(() => _expandedEffectId = expanded ? null : effect.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 7, 5, 7),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.all(7),
                      child: Icon(
                        Icons.drag_indicator_rounded,
                        color: kTextSecondary,
                        size: 21,
                      ),
                    ),
                  ),
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _categoryColor(
                        effect.type,
                      ).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _effectIcon(effect.type),
                      color: _categoryColor(effect.type),
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          effect.displayName,
                          style: TextStyle(
                            color: effect.enabled
                                ? kTextPrimary
                                : kTextSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${effect.type.category} • ${(effect.intensity * 100).round()}%',
                          style: const TextStyle(
                            color: kTextSecondary,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: effect.enabled,
                    onChanged: (_) => ref
                        .read(editorProvider.notifier)
                        .toggleEffect(
                          scope: _target.scope,
                          targetId: _target.targetId,
                          effectId: effect.id,
                        ),
                  ),
                  IconButton(
                    tooltip: 'Delete effect',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref
                        .read(editorProvider.notifier)
                        .removeEffect(
                          scope: _target.scope,
                          targetId: _target.targetId,
                          effectId: effect.id,
                        ),
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      size: 19,
                      color: kTextSecondary,
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: kTextSecondary,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                children: [
                  const Divider(height: 1, color: kBorder),
                  const SizedBox(height: 12),
                  _EffectSlider(
                    label: 'Mix',
                    value: effect.intensity,
                    minimum: 0,
                    maximum: 1,
                    divisions: 100,
                    formattedValue: '${(effect.intensity * 100).round()}%',
                    onChangeStart: _beginGesture,
                    onChanged: (value) => _updateEffect(
                      effect.id,
                      (current) => current.copyWith(intensity: value),
                    ),
                    onChangeEnd: _endGesture,
                  ),
                  for (final spec in parameterSpecs)
                    _buildParameterSlider(effect, spec, effectTime),
                  if (effect.type.supportsMask &&
                      widget.domain == EditorEffectDomain.visual)
                    _buildMaskControls(effect),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParameterSlider(
    EditorEffect effect,
    _EffectParameterSpec spec,
    Duration effectTime,
  ) {
    final supportsAutomation = effect.domain == EditorEffectDomain.visual;
    final frames = supportsAutomation
        ? effect.keyframes
              .where((frame) => frame.parameter == spec.name)
              .toList()
        : const <EditorEffectParameterKeyframe>[];
    final hasAnimation = frames.isNotEmpty;
    final hasFrameHere = frames.any((frame) => frame.time == effectTime);
    final value =
        (supportsAutomation
                ? effect.parameterAt(
                    spec.name,
                    effectTime,
                    fallback: spec.fallback,
                  )
                : effect.parameter(spec.name, spec.fallback))
            .clamp(spec.minimum, spec.maximum)
            .toDouble();
    return _EffectSlider(
      key: ValueKey('${effect.id}_${spec.name}'),
      label: spec.label,
      value: value,
      minimum: spec.minimum,
      maximum: spec.maximum,
      divisions: spec.divisions,
      formattedValue: spec.format(value),
      trailing: supportsAutomation
          ? IconButton(
              tooltip: hasFrameHere ? 'Remove keyframe' : 'Add keyframe',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                final notifier = ref.read(editorProvider.notifier);
                if (hasFrameHere) {
                  notifier.removeEffectParameterKeyframe(
                    scope: _target.scope,
                    targetId: _target.targetId,
                    effectId: effect.id,
                    parameter: spec.name,
                    time: effectTime,
                  );
                } else {
                  notifier.upsertEffectParameterKeyframe(
                    scope: _target.scope,
                    targetId: _target.targetId,
                    effectId: effect.id,
                    parameter: spec.name,
                    time: effectTime,
                    value: value,
                  );
                }
              },
              icon: Icon(
                hasFrameHere
                    ? Icons.diamond_rounded
                    : hasAnimation
                    ? Icons.diamond_outlined
                    : Icons.add_to_photos_outlined,
                size: 17,
                color: hasFrameHere || hasAnimation ? kAccent : kTextSecondary,
              ),
            )
          : null,
      onChangeStart: _beginGesture,
      onChanged: (nextValue) {
        final notifier = ref.read(editorProvider.notifier);
        if (supportsAutomation && hasAnimation) {
          notifier.upsertEffectParameterKeyframe(
            scope: _target.scope,
            targetId: _target.targetId,
            effectId: effect.id,
            parameter: spec.name,
            time: effectTime,
            value: nextValue,
          );
        } else {
          _updateEffect(
            effect.id,
            (current) => current.withParameter(spec.name, nextValue),
          );
        }
      },
      onChangeEnd: _endGesture,
    );
  }

  Widget _buildMaskControls(EditorEffect effect) {
    final mask = effect.mask;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text(
              'Selective mask',
              style: TextStyle(
                color: kTextPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: const Text(
              'Limit this effect to part of the frame',
              style: TextStyle(color: kTextSecondary, fontSize: 9),
            ),
            value: mask != null,
            onChanged: (enabled) => _updateEffect(
              effect.id,
              (current) => enabled
                  ? current.copyWith(mask: const EditorEffectMask())
                  : current.copyWith(clearMask: true),
            ),
          ),
          if (mask != null) ...[
            DropdownButtonFormField<EditorEffectMaskShape>(
              initialValue: mask.shape == EditorEffectMaskShape.freeform
                  ? EditorEffectMaskShape.rectangle
                  : mask.shape,
              decoration: const InputDecoration(labelText: 'Mask shape'),
              items: const [
                DropdownMenuItem(
                  value: EditorEffectMaskShape.rectangle,
                  child: Text('Rectangle'),
                ),
                DropdownMenuItem(
                  value: EditorEffectMaskShape.ellipse,
                  child: Text('Ellipse'),
                ),
              ],
              onChanged: (shape) {
                if (shape == null) return;
                _updateMask(effect.id, mask.copyWith(shape: shape));
              },
            ),
            const SizedBox(height: 8),
            _maskSlider(effect.id, mask, 'Horizontal', mask.x, 0, 1, (value) {
              return mask.copyWith(x: value);
            }),
            _maskSlider(effect.id, mask, 'Vertical', mask.y, 0, 1, (value) {
              return mask.copyWith(y: value);
            }),
            _maskSlider(effect.id, mask, 'Width', mask.width, 0.02, 1, (value) {
              return mask.copyWith(width: value);
            }),
            _maskSlider(effect.id, mask, 'Height', mask.height, 0.02, 1, (
              value,
            ) {
              return mask.copyWith(height: value);
            }),
            _maskSlider(effect.id, mask, 'Feather', mask.feather, 0, 1, (
              value,
            ) {
              return mask.copyWith(feather: value);
            }),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                'Invert mask',
                style: TextStyle(color: kTextPrimary, fontSize: 11),
              ),
              value: mask.inverted,
              onChanged: (value) =>
                  _updateMask(effect.id, mask.copyWith(inverted: value)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _maskSlider(
    String effectId,
    EditorEffectMask mask,
    String label,
    double value,
    double minimum,
    double maximum,
    EditorEffectMask Function(double value) mapper,
  ) {
    return _EffectSlider(
      label: label,
      value: value.clamp(minimum, maximum).toDouble(),
      minimum: minimum,
      maximum: maximum,
      divisions: 100,
      formattedValue: '${(value * 100).round()}%',
      onChangeStart: _beginGesture,
      onChanged: (next) => _updateMask(effectId, mapper(next)),
      onChangeEnd: _endGesture,
    );
  }

  void _reorderDomainEffects(int oldIndex, int newIndex) {
    ref
        .read(editorProvider.notifier)
        .updateEffectStack(
          scope: _target.scope,
          targetId: _target.targetId,
          mapper: (current) {
            final reordered = current.effects
                .where((effect) => effect.domain == widget.domain)
                .toList();
            if (oldIndex < 0 || oldIndex >= reordered.length) return current;
            final adjusted = newIndex > oldIndex ? newIndex - 1 : newIndex;
            if (adjusted < 0 ||
                adjusted >= reordered.length ||
                adjusted == oldIndex) {
              return current;
            }
            final moved = reordered.removeAt(oldIndex);
            reordered.insert(adjusted, moved);
            var domainIndex = 0;
            return current.copyWith(
              effects: current.effects.map((effect) {
                if (effect.domain != widget.domain) return effect;
                return reordered[domainIndex++];
              }).toList(),
            );
          },
        );
  }

  void _beginGesture(double _) {
    ref.read(editorProvider.notifier).beginTimelineGestureEdit();
  }

  void _endGesture(double _) {
    ref.read(editorProvider.notifier).endTimelineGestureEdit();
  }

  void _updateEffect(
    String effectId,
    EditorEffect Function(EditorEffect effect) mapper,
  ) {
    ref
        .read(editorProvider.notifier)
        .updateEffect(
          scope: _target.scope,
          targetId: _target.targetId,
          effectId: effectId,
          mapper: mapper,
        );
  }

  void _updateMask(String effectId, EditorEffectMask mask) {
    _updateEffect(effectId, (effect) => effect.copyWith(mask: mask));
  }

  Future<void> _pickAndAddEffect() async {
    final type = await showModalBottomSheet<EditorEffectType>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _EffectBrowser(domain: widget.domain),
    );
    if (type == null || !mounted) return;

    String? lutPath;
    if (type == EditorEffectType.lut) {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['cube', '3dl'],
        allowMultiple: false,
      );
      final selectedPath = picked?.files.single.path;
      if (selectedPath == null || selectedPath.trim().isEmpty || !mounted) {
        return;
      }
      try {
        await validateLutFile(selectedPath);
        lutPath = await MediaImportService.persistFile(
          selectedPath,
          originalFileName: path.basename(selectedPath),
          forceCopy: true,
        );
      } catch (error) {
        _showMessage('Could not import LUT: $error');
        return;
      }
    }

    final effect = EditorEffect(
      type: type,
      customName: lutPath == null
          ? null
          : '${path.basenameWithoutExtension(lutPath)} LUT',
      parameters: lutPath == null ? null : {'path': lutPath, 'intensity': 1.0},
    );
    final added = ref
        .read(editorProvider.notifier)
        .updateEffectStack(
          scope: _target.scope,
          targetId: _target.targetId,
          mapper: (stack) => stack.add(effect),
        );
    if (added && mounted) {
      setState(() => _expandedEffectId = effect.id);
    }
  }

  void _pasteStack({required bool append}) {
    final pasted = ref
        .read(editorProvider.notifier)
        .pasteEffectStackFromClipboard(
          scope: _target.scope,
          targetId: _target.targetId,
          append: append,
          domain: widget.domain,
        );
    if (pasted) _showMessage(append ? 'Effects appended' : 'Stack pasted');
  }

  Future<void> _openPresets(
    EditorTimeline timeline,
    EditorEffectStack stack,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final matching = timeline.effectPresets
            .where(
              (preset) => preset.stack.effects.any(
                (effect) => effect.domain == widget.domain,
              ),
            )
            .toList();
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
          decoration: const BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Effect Presets',
                        style: TextStyle(
                          color: kTextPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: stack.isEmpty
                          ? null
                          : () async {
                              Navigator.of(context).pop();
                              await _savePreset();
                            },
                      icon: const Icon(Icons.add_rounded, size: 17),
                      label: const Text('Save current'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (matching.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No saved presets yet.',
                        style: TextStyle(color: kTextSecondary),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: matching.length,
                      separatorBuilder: (_, _) => const Divider(color: kBorder),
                      itemBuilder: (context, index) {
                        final preset = matching[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            backgroundColor: kSurfaceElevated,
                            child: Icon(Icons.auto_awesome_rounded, size: 18),
                          ),
                          title: Text(
                            preset.name,
                            style: const TextStyle(color: kTextPrimary),
                          ),
                          subtitle: Text(
                            '${preset.stack.effects.length} effect${preset.stack.effects.length == 1 ? '' : 's'}',
                            style: const TextStyle(color: kTextSecondary),
                          ),
                          onTap: () {
                            ref
                                .read(editorProvider.notifier)
                                .applyEffectPreset(
                                  presetId: preset.id,
                                  scope: _target.scope,
                                  targetId: _target.targetId,
                                  domain: widget.domain,
                                );
                            Navigator.of(context).pop();
                          },
                          trailing: IconButton(
                            tooltip: 'Delete preset',
                            onPressed: () {
                              ref
                                  .read(editorProvider.notifier)
                                  .deleteEffectPreset(preset.id);
                              Navigator.of(context).pop();
                            },
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _savePreset() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save effect preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Preset name',
            hintText: 'Cinematic soft glow',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    final id = ref
        .read(editorProvider.notifier)
        .saveEffectPreset(
          name: name,
          scope: _target.scope,
          targetId: _target.targetId,
          domain: widget.domain,
        );
    if (id != null) _showMessage('Preset saved');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _EffectBrowser extends StatefulWidget {
  final EditorEffectDomain domain;

  const _EffectBrowser({required this.domain});

  @override
  State<_EffectBrowser> createState() => _EffectBrowserState();
}

class _EffectBrowserState extends State<_EffectBrowser> {
  String _query = '';
  String? _category;

  @override
  Widget build(BuildContext context) {
    final all = EditorEffectType.values
        .where((type) => type.domain == widget.domain)
        .toList();
    final categories = all.map((type) => type.category).toSet().toList()
      ..sort();
    final query = _query.trim().toLowerCase();
    final visible = all.where((type) {
      return (_category == null || type.category == _category) &&
          (query.isEmpty ||
              type.label.toLowerCase().contains(query) ||
              type.category.toLowerCase().contains(query));
    }).toList();
    return FractionallySizedBox(
      heightFactor: 0.82,
      child: Container(
        decoration: const BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: kBorder,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Search effects',
                    prefixIcon: const Icon(Icons.search_rounded),
                    filled: true,
                    fillColor: kSurfaceElevated,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              SizedBox(
                height: 38,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    ChoiceChip(
                      label: const Text('All'),
                      selected: _category == null,
                      onSelected: (_) => setState(() => _category = null),
                    ),
                    const SizedBox(width: 7),
                    for (final category in categories) ...[
                      ChoiceChip(
                        label: Text(category),
                        selected: _category == category,
                        onSelected: (_) => setState(() => _category = category),
                      ),
                      const SizedBox(width: 7),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 2.35,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final type = visible[index];
                    final color = _categoryColor(type);
                    return InkWell(
                      key: ValueKey('effect_browser_${type.name}'),
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => Navigator.of(context).pop(type),
                      child: Ink(
                        decoration: BoxDecoration(
                          color: kSurfaceElevated,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: kBorder),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.13),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  _effectIcon(type),
                                  color: color,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      type.label,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: kTextPrimary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      type.category,
                                      style: const TextStyle(
                                        color: kTextSecondary,
                                        fontSize: 8,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EffectSlider extends StatelessWidget {
  final String label;
  final double value;
  final double minimum;
  final double maximum;
  final int divisions;
  final String formattedValue;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final Widget? trailing;

  const _EffectSlider({
    super.key,
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.divisions,
    required this.formattedValue,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: kTextSecondary, fontSize: 11),
              ),
            ),
            Container(
              constraints: const BoxConstraints(minWidth: 54),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kBorder),
              ),
              child: Text(
                formattedValue,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 10,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        Slider(
          value: value.clamp(minimum, maximum).toDouble(),
          min: minimum,
          max: maximum,
          divisions: divisions,
          onChangeStart: onChangeStart,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool emphasized;

  const _ToolbarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: emphasized
          ? FilledButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 17),
              label: Text(label),
            )
          : OutlinedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 16),
              label: Text(label),
            ),
    );
  }
}

class _EmptyStack extends StatelessWidget {
  final EditorEffectDomain domain;
  final VoidCallback onAdd;

  const _EmptyStack({required this.domain, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: kAccent.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                domain == EditorEffectDomain.visual
                    ? Icons.auto_awesome_motion_outlined
                    : Icons.multitrack_audio_rounded,
                color: kAccent,
                size: 32,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Build a non-destructive stack',
              style: TextStyle(
                color: kTextPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Add effects, drag to change processing order, disable them temporarily, and animate parameters with keyframes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: kTextSecondary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add first effect'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EffectParameterSpec {
  final String name;
  final String label;
  final double minimum;
  final double maximum;
  final int divisions;
  final double fallback;
  final String Function(double value) format;

  const _EffectParameterSpec({
    required this.name,
    required this.label,
    required this.minimum,
    required this.maximum,
    required this.divisions,
    required this.fallback,
    required this.format,
  });
}

List<_EffectParameterSpec> _parameterSpecs(EditorEffect effect) {
  return effect.parameters.entries
      .where((entry) => entry.value is num && entry.key != 'intensity')
      .map(
        (entry) => _parameterSpec(effect.type, entry.key, entry.value as num),
      )
      .toList();
}

_EffectParameterSpec _parameterSpec(
  EditorEffectType type,
  String name,
  num fallback,
) {
  String label = _parameterLabel(name);
  double minimum = 0;
  double maximum = 1;
  var divisions = 100;
  String Function(double) format = (value) => '${(value * 100).round()}%';

  switch (name) {
    case 'radius':
    case 'blur':
      maximum = 80;
      divisions = 80;
      format = (value) => value.toStringAsFixed(1);
    case 'angle':
      minimum = -180;
      maximum = 180;
      divisions = 360;
      format = (value) => '${value.round()}°';
    case 'size':
      minimum = 1;
      maximum = 64;
      divisions = 63;
      format = (value) => value.round().toString();
    case 'levels':
      minimum = 2;
      maximum = 32;
      divisions = 30;
      format = (value) => value.round().toString();
    case 'frequency':
      if (type.domain == EditorEffectDomain.audio) {
        minimum = 20;
        maximum = 20000;
        divisions = 200;
        format = (value) => value >= 1000
            ? '${(value / 1000).toStringAsFixed(1)} kHz'
            : '${value.round()} Hz';
      } else {
        minimum = 0;
        maximum = 30;
        divisions = 120;
        format = (value) => value.toStringAsFixed(1);
      }
    case 'gain':
      minimum = -24;
      maximum = 24;
      divisions = 96;
      format = (value) => '${value.toStringAsFixed(1)} dB';
    case 'threshold':
      if (type.domain == EditorEffectDomain.audio) {
        minimum = -60;
        maximum = 0;
        divisions = 120;
        format = (value) => '${value.toStringAsFixed(1)} dB';
      }
    case 'ratio':
      minimum = 1;
      maximum = 20;
      divisions = 76;
      format = (value) => '${value.toStringAsFixed(1)}:1';
    case 'attack':
      minimum = 0.1;
      maximum = 500;
      divisions = 200;
      format = (value) => '${value.round()} ms';
    case 'release':
      minimum = 10;
      maximum = 2000;
      divisions = 199;
      format = (value) => '${value.round()} ms';
    case 'limit':
    case 'range':
      minimum = -24;
      maximum = 0;
      divisions = 96;
      format = (value) => '${value.toStringAsFixed(1)} dB';
    case 'delayMs':
      minimum = 1;
      maximum = 2000;
      divisions = 200;
      format = (value) => '${value.round()} ms';
    case 'semitones':
      minimum = -24;
      maximum = 24;
      divisions = 48;
      format = (value) => '${value.round()} st';
    case 'rate':
      minimum = 0.25;
      maximum = 4;
      divisions = 75;
      format = (value) => '${value.toStringAsFixed(2)}×';
    case 'offsetX':
    case 'offsetY':
      minimum = -80;
      maximum = 80;
      divisions = 160;
      format = (value) => value.round().toString();
    case 'brightness':
      minimum = -1;
      maximum = 1;
      divisions = 200;
    case 'contrast':
    case 'saturation':
    case 'gamma':
      minimum = 0;
      maximum = 3;
      divisions = 150;
      format = (value) => value.toStringAsFixed(2);
  }

  return _EffectParameterSpec(
    name: name,
    label: label,
    minimum: minimum,
    maximum: maximum,
    divisions: divisions,
    fallback: fallback.toDouble(),
    format: format,
  );
}

String _parameterLabel(String name) {
  final words = name
      .replaceAllMapped(RegExp(r'([A-Z])'), (match) => ' ${match.group(1)}')
      .trim();
  return words.isEmpty
      ? 'Parameter'
      : '${words[0].toUpperCase()}${words.substring(1)}';
}

Color _categoryColor(EditorEffectType type) {
  return switch (type.category) {
    'Audio' => const Color(0xFF67E8F9),
    'Blur' => const Color(0xFF93C5FD),
    'Color' => const Color(0xFFF9A8D4),
    'Depth' => const Color(0xFFC4B5FD),
    'Lens' => const Color(0xFFFDE68A),
    _ => const Color(0xFF86EFAC),
  };
}

IconData _effectIcon(EditorEffectType type) {
  return switch (type.category) {
    'Audio' => Icons.graphic_eq_rounded,
    'Blur' => Icons.blur_on_rounded,
    'Color' => Icons.palette_outlined,
    'Depth' => Icons.layers_rounded,
    'Lens' => Icons.lens_blur_rounded,
    _ => Icons.auto_awesome_rounded,
  };
}
