import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/ffmpeg_service.dart';
import '../models/editor_effect_models.dart';
import '../models/timeline_models.dart';

typedef ColorAdjustmentsChanged =
    void Function(ClipColorAdjustments value, {required bool recordHistory});

class AdvancedColorControls extends StatelessWidget {
  final ClipColorAdjustments adjustments;
  final ColorAdjustmentsChanged onChanged;
  final VoidCallback onGestureStart;
  final VoidCallback onGestureEnd;
  final Future<void> Function() onPickNeutralReference;
  final Future<void> Function()? onPickQualifierReference;
  final Future<void> Function()? onTrackQualifierMask;

  const AdvancedColorControls({
    super.key,
    required this.adjustments,
    required this.onChanged,
    required this.onGestureStart,
    required this.onGestureEnd,
    required this.onPickNeutralReference,
    this.onPickQualifierReference,
    this.onTrackQualifierMask,
  });

  void _commit(ClipColorAdjustments value) {
    onChanged(value, recordHistory: true);
  }

  void _change(ClipColorAdjustments value) {
    onChanged(value, recordHistory: false);
  }

  @override
  Widget build(BuildContext context) {
    final qualifier = adjustments.qualifier;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('INPUT COLOR'),
        const SizedBox(height: 8),
        DropdownButtonFormField<EditorColorSpace>(
          key: ValueKey('input_color_${adjustments.inputColorSpace.name}'),
          initialValue: adjustments.inputColorSpace,
          decoration: const InputDecoration(
            labelText: 'Source color-space override',
            prefixIcon: Icon(Icons.camera_outlined),
          ),
          items: [
            for (final space in EditorColorSpace.values)
              DropdownMenuItem(
                value: space,
                child: Text(_colorSpaceLabel(space)),
              ),
          ],
          onChanged: (space) {
            if (space != null) {
              _commit(adjustments.copyWith(inputColorSpace: space));
            }
          },
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const ValueKey('white_balance_eyedropper'),
            onPressed: onPickNeutralReference,
            icon: const Icon(Icons.colorize_rounded, size: 18),
            label: const Text('Pick neutral white-balance reference'),
          ),
        ),
        const SizedBox(height: 18),
        _sectionTitle('PROFESSIONAL CURVES'),
        const SizedBox(height: 6),
        _curveTile(
          label: 'RGB master',
          subtitle: 'Remap overall luminance and channel response',
          curve: adjustments.rgbCurve,
          onCurve: (curve) => _change(adjustments.copyWith(rgbCurve: curve)),
        ),
        _curveTile(
          label: 'Hue vs Hue',
          subtitle: 'Rotate selected hue ranges',
          curve: adjustments.hueVsHueCurve,
          hueGradient: true,
          onCurve: (curve) =>
              _change(adjustments.copyWith(hueVsHueCurve: curve)),
        ),
        _curveTile(
          label: 'Hue vs Saturation',
          subtitle: 'Change saturation by source hue',
          curve: adjustments.hueVsSaturationCurve,
          hueGradient: true,
          onCurve: (curve) =>
              _change(adjustments.copyWith(hueVsSaturationCurve: curve)),
        ),
        _curveTile(
          label: 'Hue vs Luminance',
          subtitle: 'Change brightness by source hue',
          curve: adjustments.hueVsLuminanceCurve,
          hueGradient: true,
          onCurve: (curve) =>
              _change(adjustments.copyWith(hueVsLuminanceCurve: curve)),
        ),
        _curveTile(
          label: 'Luminance vs Saturation',
          subtitle: 'Control color density from shadows to highlights',
          curve: adjustments.luminanceVsSaturationCurve,
          onCurve: (curve) =>
              _change(adjustments.copyWith(luminanceVsSaturationCurve: curve)),
        ),
        _curveTile(
          label: 'Saturation vs Saturation',
          subtitle: 'Compress or expand existing saturation',
          curve: adjustments.saturationVsSaturationCurve,
          onCurve: (curve) =>
              _change(adjustments.copyWith(saturationVsSaturationCurve: curve)),
        ),
        const SizedBox(height: 18),
        _sectionTitle('COLOR WHEELS'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _ColorWheelControl(
              label: 'Shadows',
              red: adjustments.wheels.shadowsRed,
              green: adjustments.wheels.shadowsGreen,
              blue: adjustments.wheels.shadowsBlue,
              onChangeStart: onGestureStart,
              onChangeEnd: onGestureEnd,
              onChanged: (value) => _change(
                adjustments.copyWith(
                  wheels: adjustments.wheels.copyWith(
                    shadowsRed: value.$1,
                    shadowsGreen: value.$2,
                    shadowsBlue: value.$3,
                  ),
                ),
              ),
            ),
            _ColorWheelControl(
              label: 'Midtones',
              red: adjustments.wheels.midtonesRed,
              green: adjustments.wheels.midtonesGreen,
              blue: adjustments.wheels.midtonesBlue,
              onChangeStart: onGestureStart,
              onChangeEnd: onGestureEnd,
              onChanged: (value) => _change(
                adjustments.copyWith(
                  wheels: adjustments.wheels.copyWith(
                    midtonesRed: value.$1,
                    midtonesGreen: value.$2,
                    midtonesBlue: value.$3,
                  ),
                ),
              ),
            ),
            _ColorWheelControl(
              label: 'Highlights',
              red: adjustments.wheels.highlightsRed,
              green: adjustments.wheels.highlightsGreen,
              blue: adjustments.wheels.highlightsBlue,
              onChangeStart: onGestureStart,
              onChangeEnd: onGestureEnd,
              onChanged: (value) => _change(
                adjustments.copyWith(
                  wheels: adjustments.wheels.copyWith(
                    highlightsRed: value.$1,
                    highlightsGreen: value.$2,
                    highlightsBlue: value.$3,
                  ),
                ),
              ),
            ),
            _ColorWheelControl(
              label: 'Global',
              red: adjustments.wheels.globalRed,
              green: adjustments.wheels.globalGreen,
              blue: adjustments.wheels.globalBlue,
              onChangeStart: onGestureStart,
              onChangeEnd: onGestureEnd,
              onChanged: (value) => _change(
                adjustments.copyWith(
                  wheels: adjustments.wheels.copyWith(
                    globalRed: value.$1,
                    globalGreen: value.$2,
                    globalBlue: value.$3,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _sectionTitle('SELECTIVE HSL QUALIFIER'),
        SwitchListTile.adaptive(
          key: const ValueKey('color_qualifier_enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable selective correction'),
          subtitle: const Text(
            'Isolate a hue range, then adjust only that selection',
          ),
          value: qualifier.enabled,
          onChanged: (enabled) => _commit(
            adjustments.copyWith(
              qualifier: qualifier.copyWith(enabled: enabled),
            ),
          ),
        ),
        if (qualifier.enabled) ...[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Skin-tone isolation'),
            subtitle: const Text('Use a protected human skin hue range'),
            value: qualifier.skinTone,
            onChanged: (enabled) => _commit(
              adjustments.copyWith(
                qualifier: qualifier.copyWith(skinTone: enabled),
              ),
            ),
          ),
          if (!qualifier.skinTone)
            Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(qualifier.color),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white70, width: 2),
                    ),
                    child: const SizedBox.square(dimension: 34),
                  ),
                  title: const Text('Qualifier target color'),
                  subtitle: const Text('Tap to choose a color range'),
                  trailing: const Icon(Icons.palette_outlined),
                  onTap: () => _pickQualifierColor(context, qualifier),
                ),
                if (onPickQualifierReference != null)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const ValueKey('qualifier_eyedropper'),
                      onPressed: onPickQualifierReference,
                      icon: const Icon(Icons.colorize_rounded, size: 18),
                      label: const Text('Pick target from current frame'),
                    ),
                  ),
              ],
            ),
          _slider(
            label: 'Hue range',
            value: qualifier.hueRange,
            minimum: 0.01,
            maximum: 0.5,
            onChanged: (value) => _change(
              adjustments.copyWith(
                qualifier: qualifier.copyWith(hueRange: value),
              ),
            ),
          ),
          _slider(
            label: 'Saturation range',
            value: qualifier.saturationRange,
            minimum: 0.01,
            maximum: 1,
            onChanged: (value) => _change(
              adjustments.copyWith(
                qualifier: qualifier.copyWith(saturationRange: value),
              ),
            ),
          ),
          _slider(
            label: 'Luminance range',
            value: qualifier.luminanceRange,
            minimum: 0.01,
            maximum: 1,
            onChanged: (value) => _change(
              adjustments.copyWith(
                qualifier: qualifier.copyWith(luminanceRange: value),
              ),
            ),
          ),
          _slider(
            label: 'Edge softness',
            value: qualifier.softness,
            minimum: 0,
            maximum: 1,
            onChanged: (value) => _change(
              adjustments.copyWith(
                qualifier: qualifier.copyWith(softness: value),
              ),
            ),
          ),
          const Divider(color: kBorder),
          _slider(
            label: 'Selected hue shift',
            value: qualifier.hueShift,
            minimum: -180,
            maximum: 180,
            formatted: (value) => '${value.round()}°',
            onChanged: (value) => _change(
              adjustments.copyWith(
                qualifier: qualifier.copyWith(hueShift: value),
              ),
            ),
          ),
          _slider(
            label: 'Selected saturation',
            value: qualifier.saturationShift,
            minimum: -1,
            maximum: 1,
            onChanged: (value) => _change(
              adjustments.copyWith(
                qualifier: qualifier.copyWith(saturationShift: value),
              ),
            ),
          ),
          _slider(
            label: 'Selected luminance',
            value: qualifier.luminanceShift,
            minimum: -1,
            maximum: 1,
            onChanged: (value) => _change(
              adjustments.copyWith(
                qualifier: qualifier.copyWith(luminanceShift: value),
              ),
            ),
          ),
          _buildQualifierMask(qualifier),
        ],
      ],
    );
  }

  Widget _curveTile({
    required String label,
    required String subtitle,
    required EditorColorCurve curve,
    required ValueChanged<EditorColorCurve> onCurve,
    bool hueGradient = false,
  }) {
    return ExpansionTile(
      key: ValueKey('curve_${label.replaceAll(' ', '_').toLowerCase()}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      title: Text(label, style: const TextStyle(fontSize: 12)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 9)),
      children: [
        _ColorCurveEditor(
          curve: curve,
          hueGradient: hueGradient,
          onChanged: onCurve,
          onChangeStart: onGestureStart,
          onChangeEnd: onGestureEnd,
        ),
      ],
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double minimum,
    required double maximum,
    required ValueChanged<double> onChanged,
    String Function(double value)? formatted,
  }) {
    final formatter =
        formatted ?? (candidate) => '${(candidate * 100).round()}%';
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: kTextSecondary, fontSize: 10),
              ),
            ),
            Text(
              formatter(value),
              style: const TextStyle(color: kTextPrimary, fontSize: 10),
            ),
          ],
        ),
        Slider(
          value: value.clamp(minimum, maximum).toDouble(),
          min: minimum,
          max: maximum,
          divisions: 100,
          onChangeStart: (_) => onGestureStart(),
          onChanged: onChanged,
          onChangeEnd: (_) => onGestureEnd(),
        ),
      ],
    );
  }

  Widget _buildQualifierMask(EditorColorQualifier qualifier) {
    final mask = qualifier.spatialMask;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Combine qualifier with a mask'),
            subtitle: const Text('Restrict the selected color spatially'),
            value: mask != null,
            onChanged: (enabled) => _commit(
              adjustments.copyWith(
                qualifier: qualifier.copyWith(
                  spatialMask: enabled ? const EditorEffectMask() : null,
                  clearSpatialMask: !enabled,
                ),
              ),
            ),
          ),
          if (mask != null) ...[
            DropdownButtonFormField<EditorEffectMaskShape>(
              key: ValueKey('qualifier_mask_${mask.shape.name}'),
              initialValue: mask.shape,
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
                DropdownMenuItem(
                  value: EditorEffectMaskShape.freeform,
                  child: Text('Freeform polygon'),
                ),
              ],
              onChanged: (shape) {
                if (shape == null) return;
                const defaultPoints = <EditorMaskPoint>[
                  EditorMaskPoint(0.2, 0.2),
                  EditorMaskPoint(0.8, 0.2),
                  EditorMaskPoint(0.8, 0.8),
                  EditorMaskPoint(0.2, 0.8),
                ];
                _commit(
                  adjustments.copyWith(
                    qualifier: qualifier.copyWith(
                      spatialMask: mask.copyWith(
                        shape: shape,
                        points:
                            shape == EditorEffectMaskShape.freeform &&
                                mask.safePoints.length < 3
                            ? defaultPoints
                            : mask.points,
                      ),
                    ),
                  ),
                );
              },
            ),
            if (mask.shape == EditorEffectMaskShape.freeform) ...[
              const SizedBox(height: 10),
              _QualifierFreeformMaskEditor(
                points: mask.safePoints,
                onChangeStart: onGestureStart,
                onChangeEnd: onGestureEnd,
                onChanged: (points) => _change(
                  adjustments.copyWith(
                    qualifier: qualifier.copyWith(
                      spatialMask: mask.copyWith(points: points),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Drag polygon points around the subject. Tracking preserves the polygon while following its bounding region.',
                  style: TextStyle(color: kTextSecondary, fontSize: 9),
                ),
              ),
            ] else ...[
              _slider(
                label: 'Mask horizontal',
                value: mask.x,
                minimum: 0,
                maximum: 1,
                onChanged: (value) => _change(
                  adjustments.copyWith(
                    qualifier: qualifier.copyWith(
                      spatialMask: mask.copyWith(x: value),
                    ),
                  ),
                ),
              ),
              _slider(
                label: 'Mask vertical',
                value: mask.y,
                minimum: 0,
                maximum: 1,
                onChanged: (value) => _change(
                  adjustments.copyWith(
                    qualifier: qualifier.copyWith(
                      spatialMask: mask.copyWith(y: value),
                    ),
                  ),
                ),
              ),
              _slider(
                label: 'Mask width',
                value: mask.width,
                minimum: 0.02,
                maximum: 1,
                onChanged: (value) => _change(
                  adjustments.copyWith(
                    qualifier: qualifier.copyWith(
                      spatialMask: mask.copyWith(width: value),
                    ),
                  ),
                ),
              ),
              _slider(
                label: 'Mask height',
                value: mask.height,
                minimum: 0.02,
                maximum: 1,
                onChanged: (value) => _change(
                  adjustments.copyWith(
                    qualifier: qualifier.copyWith(
                      spatialMask: mask.copyWith(height: value),
                    ),
                  ),
                ),
              ),
            ],
            _slider(
              label: 'Mask feather',
              value: mask.feather,
              minimum: 0,
              maximum: 1,
              onChanged: (value) => _change(
                adjustments.copyWith(
                  qualifier: qualifier.copyWith(
                    spatialMask: mask.copyWith(feather: value),
                  ),
                ),
              ),
            ),
            if (onTrackQualifierMask != null)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('track_qualifier_mask'),
                  onPressed: onTrackQualifierMask,
                  icon: const Icon(Icons.center_focus_strong_rounded),
                  label: Text(
                    mask.hasTrackedMotion
                        ? 'Track qualifier mask again'
                        : 'Track qualifier mask forward',
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickQualifierColor(
    BuildContext context,
    EditorColorQualifier qualifier,
  ) async {
    var selected = Color(qualifier.color);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Qualifier target'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: selected,
            enableAlpha: false,
            onColorChanged: (color) => selected = color,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Use color'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      _commit(
        adjustments.copyWith(
          qualifier: qualifier.copyWith(color: selected.toARGB32()),
        ),
      );
    }
  }
}

class _QualifierFreeformMaskEditor extends StatelessWidget {
  final List<EditorMaskPoint> points;
  final ValueChanged<List<EditorMaskPoint>> onChanged;
  final VoidCallback onChangeStart;
  final VoidCallback onChangeEnd;

  const _QualifierFreeformMaskEditor({
    required this.points,
    required this.onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final safePoints = points.length >= 3
        ? points
        : const <EditorMaskPoint>[
            EditorMaskPoint(0.2, 0.2),
            EditorMaskPoint(0.8, 0.2),
            EditorMaskPoint(0.8, 0.8),
            EditorMaskPoint(0.2, 0.8),
          ];
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.38),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kBorder),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _QualifierMaskPainter(points: safePoints),
                  ),
                  for (var index = 0; index < safePoints.length; index++)
                    Positioned(
                      left: safePoints[index].x * constraints.maxWidth - 11,
                      top: safePoints[index].y * constraints.maxHeight - 11,
                      width: 22,
                      height: 22,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) => onChangeStart(),
                        onPanUpdate: (details) {
                          final next = [...safePoints];
                          final current = next[index];
                          next[index] = EditorMaskPoint(
                            (current.x +
                                    details.delta.dx / constraints.maxWidth)
                                .clamp(0.0, 1.0)
                                .toDouble(),
                            (current.y +
                                    details.delta.dy / constraints.maxHeight)
                                .clamp(0.0, 1.0)
                                .toDouble(),
                          );
                          onChanged(next);
                        },
                        onPanEnd: (_) => onChangeEnd(),
                        onPanCancel: onChangeEnd,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: kAccent,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(color: Colors.black54, blurRadius: 4),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _QualifierMaskPainter extends CustomPainter {
  final List<EditorMaskPoint> points;

  const _QualifierMaskPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 3) return;
    final path = Path()
      ..moveTo(points.first.x * size.width, points.first.y * size.height);
    for (final point in points.skip(1)) {
      path.lineTo(point.x * size.width, point.y * size.height);
    }
    path.close();
    canvas
      ..drawPath(
        path,
        Paint()
          ..color = kAccent.withValues(alpha: 0.18)
          ..style = PaintingStyle.fill,
      )
      ..drawPath(
        path,
        Paint()
          ..color = kAccent
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
  }

  @override
  bool shouldRepaint(covariant _QualifierMaskPainter oldDelegate) {
    return oldDelegate.points != points;
  }
}

class _ColorCurveEditor extends StatelessWidget {
  final EditorColorCurve curve;
  final bool hueGradient;
  final ValueChanged<EditorColorCurve> onChanged;
  final VoidCallback onChangeStart;
  final VoidCallback onChangeEnd;

  const _ColorCurveEditor({
    required this.curve,
    required this.hueGradient,
    required this.onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final points = curve.points.map((point) => point.normalized()).toList()
      ..sort((first, second) => first.input.compareTo(second.input));
    return AspectRatio(
      aspectRatio: 1.8,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              final next = [
                ...points,
                EditorColorCurvePoint(
                  details.localPosition.dx / constraints.maxWidth,
                  1 - details.localPosition.dy / constraints.maxHeight,
                ).normalized(),
              ]..sort((first, second) => first.input.compareTo(second.input));
              onChanged(EditorColorCurve(points: next));
            },
            onLongPressStart: (details) {
              if (points.length <= 2) return;
              var closest = 1;
              var distance = double.infinity;
              for (var index = 1; index < points.length - 1; index++) {
                final candidate = Offset(
                  points[index].input * constraints.maxWidth,
                  (1 - points[index].output) * constraints.maxHeight,
                );
                final candidateDistance =
                    (candidate - details.localPosition).distance;
                if (candidateDistance < distance) {
                  closest = index;
                  distance = candidateDistance;
                }
              }
              if (distance <= 28) {
                final next = [...points]..removeAt(closest);
                onChanged(EditorColorCurve(points: next));
              }
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.34),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kBorder),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      painter: _ColorCurvePainter(
                        points: points,
                        hueGradient: hueGradient,
                      ),
                    ),
                    for (var index = 0; index < points.length; index++)
                      Positioned(
                        left: points[index].input * constraints.maxWidth - 11,
                        top:
                            (1 - points[index].output) * constraints.maxHeight -
                            11,
                        width: 22,
                        height: 22,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) => onChangeStart(),
                          onPanUpdate: (details) {
                            final next = [...points];
                            final current = next[index];
                            final input = index == 0
                                ? 0.0
                                : index == next.length - 1
                                ? 1.0
                                : (current.input +
                                          details.delta.dx /
                                              constraints.maxWidth)
                                      .clamp(
                                        next[index - 1].input + 0.01,
                                        next[index + 1].input - 0.01,
                                      )
                                      .toDouble();
                            next[index] = EditorColorCurvePoint(
                              input,
                              (current.output -
                                      details.delta.dy / constraints.maxHeight)
                                  .clamp(0.0, 1.0)
                                  .toDouble(),
                            );
                            onChanged(EditorColorCurve(points: next));
                          },
                          onPanEnd: (_) => onChangeEnd(),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: kAccent,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: const [
                                BoxShadow(color: Colors.black54, blurRadius: 4),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ColorCurvePainter extends CustomPainter {
  final List<EditorColorCurvePoint> points;
  final bool hueGradient;

  const _ColorCurvePainter({required this.points, required this.hueGradient});

  @override
  void paint(Canvas canvas, Size size) {
    if (hueGradient) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = const LinearGradient(
            colors: [
              Colors.red,
              Colors.yellow,
              Colors.green,
              Colors.cyan,
              Colors.blue,
              Colors.purple,
              Colors.red,
            ],
          ).createShader(Offset.zero & size)
          ..color = Colors.white.withValues(alpha: 0.16),
      );
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Colors.black.withValues(alpha: 0.72),
      );
    }
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    for (var index = 1; index < 4; index++) {
      final fraction = index / 4;
      canvas.drawLine(
        Offset(size.width * fraction, 0),
        Offset(size.width * fraction, size.height),
        gridPaint,
      );
      canvas.drawLine(
        Offset(0, size.height * fraction),
        Offset(size.width, size.height * fraction),
        gridPaint,
      );
    }
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, 0),
      Paint()
        ..color = Colors.white24
        ..strokeWidth = 1,
    );
    if (points.isEmpty) return;
    final path = Path()
      ..moveTo(
        points.first.input * size.width,
        (1 - points.first.output) * size.height,
      );
    for (final point in points.skip(1)) {
      path.lineTo(point.input * size.width, (1 - point.output) * size.height);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = kAccent
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorCurvePainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.hueGradient != hueGradient;
  }
}

class _ColorWheelControl extends StatelessWidget {
  final String label;
  final double red;
  final double green;
  final double blue;
  final ValueChanged<(double, double, double)> onChanged;
  final VoidCallback onChangeStart;
  final VoidCallback onChangeEnd;

  const _ColorWheelControl({
    required this.label,
    required this.red,
    required this.green,
    required this.blue,
    required this.onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 145,
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Reset $label wheel',
                onPressed: () => onChanged((0, 0, 0)),
                icon: const Icon(Icons.restart_alt_rounded, size: 15),
              ),
            ],
          ),
          AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (context, constraints) {
                void update(Offset local) {
                  final center = constraints.biggest.center(Offset.zero);
                  final radius = constraints.maxWidth / 2;
                  final delta = local - center;
                  final distance = (delta.distance / radius).clamp(0.0, 1.0);
                  final angle = math.atan2(delta.dy, delta.dx);
                  final hue = (angle * 180 / math.pi + 360) % 360;
                  final color = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
                  final channels = <double>[color.r, color.g, color.b];
                  final average = channels.reduce((a, b) => a + b) / 3;
                  const maximumOffset = 0.35;
                  onChanged((
                    (channels[0] - average) * distance * maximumOffset,
                    (channels[1] - average) * distance * maximumOffset,
                    (channels[2] - average) * distance * maximumOffset,
                  ));
                }

                return GestureDetector(
                  onPanStart: (details) {
                    onChangeStart();
                    update(details.localPosition);
                  },
                  onPanUpdate: (details) => update(details.localPosition),
                  onPanEnd: (_) => onChangeEnd(),
                  onTapDown: (details) {
                    onChangeStart();
                    update(details.localPosition);
                    onChangeEnd();
                  },
                  child: CustomPaint(
                    painter: _ColorWheelPainter(
                      red: red,
                      green: green,
                      blue: blue,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'R ${red.toStringAsFixed(2)}  G ${green.toStringAsFixed(2)}  B ${blue.toStringAsFixed(2)}',
            style: const TextStyle(color: kTextSecondary, fontSize: 8),
          ),
        ],
      ),
    );
  }
}

class _ColorWheelPainter extends CustomPainter {
  final double red;
  final double green;
  final double blue;

  const _ColorWheelPainter({
    required this.red,
    required this.green,
    required this.blue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 3;
    final bounds = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const SweepGradient(
          colors: [
            Colors.red,
            Colors.yellow,
            Colors.green,
            Colors.cyan,
            Colors.blue,
            Colors.purple,
            Colors.red,
          ],
        ).createShader(bounds),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          colors: [Colors.white, Colors.transparent],
          stops: [0, 1],
        ).createShader(bounds),
    );
    final range = math.max(
      0.0001,
      math.max(red, math.max(green, blue)) -
          math.min(red, math.min(green, blue)),
    );
    final normalizedColor = Color.from(
      alpha: 1,
      red: ((red - math.min(red, math.min(green, blue))) / range).clamp(
        0.0,
        1.0,
      ),
      green: ((green - math.min(red, math.min(green, blue))) / range).clamp(
        0.0,
        1.0,
      ),
      blue: ((blue - math.min(red, math.min(green, blue))) / range).clamp(
        0.0,
        1.0,
      ),
    );
    final hue = HSVColor.fromColor(normalizedColor).hue * math.pi / 180;
    final strength =
        (math.max(red.abs(), math.max(green.abs(), blue.abs())) / 0.24).clamp(
          0.0,
          1.0,
        );
    final puck =
        center + Offset(math.cos(hue), math.sin(hue)) * radius * strength;
    canvas.drawCircle(
      puck,
      7,
      Paint()
        ..color = Colors.black87
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    canvas.drawCircle(
      puck,
      6,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorWheelPainter oldDelegate) {
    return oldDelegate.red != red ||
        oldDelegate.green != green ||
        oldDelegate.blue != blue;
  }
}

Future<Color?> pickNeutralReferenceColor({
  required BuildContext context,
  required String sourcePath,
  required Duration sourcePosition,
}) => pickFrameReferenceColor(
  context: context,
  sourcePath: sourcePath,
  sourcePosition: sourcePosition,
  title: 'White-balance eyedropper',
  instruction: 'Tap something that should be neutral gray or white.',
  actionLabel: 'Balance from sample',
);

Future<Color?> pickFrameReferenceColor({
  required BuildContext context,
  required String sourcePath,
  required Duration sourcePosition,
  required String title,
  required String instruction,
  required String actionLabel,
}) async {
  final framePath = await FFmpegService.extractVideoFrame(
    sourcePath,
    position: sourcePosition,
  );
  try {
    if (!context.mounted) return null;
    return showDialog<Color>(
      context: context,
      builder: (context) => _FrameReferenceDialog(
        framePath: framePath,
        title: title,
        instruction: instruction,
        actionLabel: actionLabel,
      ),
    );
  } finally {
    try {
      final frame = File(framePath);
      if (await frame.exists()) await frame.delete();
    } catch (_) {
      // The sampled color is independent from the temporary frame file.
    }
  }
}

class _FrameReferenceDialog extends StatefulWidget {
  final String framePath;
  final String title;
  final String instruction;
  final String actionLabel;

  const _FrameReferenceDialog({
    required this.framePath,
    required this.title,
    required this.instruction,
    required this.actionLabel,
  });

  @override
  State<_FrameReferenceDialog> createState() => _FrameReferenceDialogState();
}

class _FrameReferenceDialogState extends State<_FrameReferenceDialog> {
  ui.Image? _image;
  Uint8List? _pixels;
  Color? _selected;
  Offset? _selectedPoint;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.framePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final byteData = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    codec.dispose();
    if (!mounted || byteData == null) {
      frame.image.dispose();
      return;
    }
    setState(() {
      _image = frame.image;
      _pixels = byteData.buffer.asUint8List();
    });
  }

  void _sample(Offset localPosition, Size availableSize) {
    final image = _image;
    final pixels = _pixels;
    if (image == null || pixels == null) return;
    final sourceSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, sourceSize, availableSize);
    final destination = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & availableSize,
    );
    if (!destination.contains(localPosition)) return;
    final normalizedX =
        ((localPosition.dx - destination.left) / destination.width).clamp(
          0.0,
          0.999999,
        );
    final normalizedY =
        ((localPosition.dy - destination.top) / destination.height).clamp(
          0.0,
          0.999999,
        );
    final x = (normalizedX * image.width).floor();
    final y = (normalizedY * image.height).floor();
    final index = (y * image.width + x) * 4;
    if (index + 2 >= pixels.length) return;
    setState(() {
      _selected = Color.fromARGB(
        255,
        pixels[index],
        pixels[index + 1],
        pixels[index + 2],
      );
      _selectedPoint = localPosition;
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.instruction,
              style: const TextStyle(color: kTextSecondary, fontSize: 11),
            ),
            const SizedBox(height: 10),
            AspectRatio(
              aspectRatio: image == null ? 16 / 9 : image.width / image.height,
              child: LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) =>
                      _sample(details.localPosition, constraints.biggest),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Colors.black,
                        child: image == null
                            ? const Center(child: CircularProgressIndicator())
                            : RawImage(image: image, fit: BoxFit.contain),
                      ),
                      if (_selectedPoint != null)
                        Positioned(
                          left: _selectedPoint!.dx - 11,
                          top: _selectedPoint!.dy - 11,
                          child: IgnorePointer(
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black87,
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_selected != null) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircleAvatar(backgroundColor: _selected, radius: 12),
                  const SizedBox(width: 8),
                  Text(
                    'R ${(_selected!.r * 255).round()}  '
                    'G ${(_selected!.g * 255).round()}  '
                    'B ${(_selected!.b * 255).round()}',
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected == null
              ? null
              : () => Navigator.of(context).pop(_selected),
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

Widget _sectionTitle(String label) {
  return Text(
    label,
    style: const TextStyle(
      color: kTextSecondary,
      fontSize: 10,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.1,
    ),
  );
}

String _colorSpaceLabel(EditorColorSpace space) {
  return switch (space) {
    EditorColorSpace.automatic => 'Automatic from camera metadata',
    EditorColorSpace.sdr709 => 'SDR / Rec.709',
    EditorColorSpace.log => 'Camera Log',
    EditorColorSpace.hlg => 'HLG (Rec.2020)',
    EditorColorSpace.pq => 'PQ / HDR10 (Rec.2020)',
    EditorColorSpace.wideGamut => 'Wide gamut (Rec.2020)',
  };
}
