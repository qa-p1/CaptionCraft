import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models/timeline_models.dart';

typedef KeyframeGraphChanged =
    void Function(List<TimelineKeyframe> keyframes, bool recordHistory);

/// A clip-relative value graph with editable keyframes and Bézier handles.
///
/// The graph deliberately edits the timeline model directly instead of
/// maintaining a second animation representation. Preview and export therefore
/// consume the exact curves shown here.
class KeyframeGraphEditor extends StatefulWidget {
  final TimelineClip clip;
  final List<TimelineKeyframeProperty> properties;
  final TimelineKeyframeProperty initialProperty;
  final Duration playhead;
  final int frameRate;
  final KeyframeGraphChanged onChanged;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onEditStart;
  final VoidCallback onEditEnd;

  const KeyframeGraphEditor({
    super.key,
    required this.clip,
    required this.properties,
    required this.initialProperty,
    required this.playhead,
    required this.frameRate,
    required this.onChanged,
    required this.onSeek,
    required this.onEditStart,
    required this.onEditEnd,
  });

  @override
  State<KeyframeGraphEditor> createState() => _KeyframeGraphEditorState();
}

enum _GraphDragKind { none, keyframe, firstHandle, secondHandle, pan }

class _KeyframeGraphEditorState extends State<KeyframeGraphEditor> {
  late TimelineKeyframeProperty _property;
  String? _selectedKeyframeId;
  _GraphDragKind _dragKind = _GraphDragKind.none;
  double _timeZoom = 1;
  double _valueZoom = 1;
  double _timeOffsetUs = 0;
  double? _valueCenter;

  @override
  void initState() {
    super.initState();
    _property = widget.properties.contains(widget.initialProperty)
        ? widget.initialProperty
        : widget.properties.first;
    _selectNearestToPlayhead();
  }

  @override
  void didUpdateWidget(covariant KeyframeGraphEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.properties.contains(_property)) {
      _property = widget.properties.first;
      _selectedKeyframeId = null;
    }
    if (_selectedKeyframeId != null &&
        !_propertyFrames.any((frame) => frame.id == _selectedKeyframeId)) {
      _selectedKeyframeId = null;
    }
  }

  List<TimelineKeyframe> get _propertyFrames =>
      widget.clip.keyframes
          .where((frame) => frame.property == _property)
          .toList()
        ..sort((a, b) => a.time.compareTo(b.time));

  TimelineKeyframe? get _selectedFrame {
    final selectedId = _selectedKeyframeId;
    if (selectedId == null) return null;
    for (final frame in _propertyFrames) {
      if (frame.id == selectedId) return frame;
    }
    return null;
  }

  Duration get _relativePlayhead {
    final durationMs = math.max(0, widget.clip.duration.inMilliseconds);
    final relativeMs = (widget.playhead - widget.clip.startTime).inMilliseconds
        .clamp(0, durationMs)
        .toInt();
    return Duration(milliseconds: relativeMs);
  }

  void _selectNearestToPlayhead() {
    final frames = _propertyFrames;
    if (frames.isEmpty) return;
    final target = _relativePlayhead.inMicroseconds;
    frames.sort(
      (a, b) => (a.time.inMicroseconds - target).abs().compareTo(
        (b.time.inMicroseconds - target).abs(),
      ),
    );
    _selectedKeyframeId = frames.first.id;
  }

  _PropertyRange get _range => _propertyRange(_property);

  double get _fallbackValue => switch (_property) {
    TimelineKeyframeProperty.opacity => widget.clip.transform.opacity,
    TimelineKeyframeProperty.scale => widget.clip.transform.scale,
    TimelineKeyframeProperty.rotation => widget.clip.transform.rotation,
    TimelineKeyframeProperty.positionX => widget.clip.transform.offsetX,
    TimelineKeyframeProperty.positionY => widget.clip.transform.offsetY,
    TimelineKeyframeProperty.volume => widget.clip.audioMix.volume,
    TimelineKeyframeProperty.blurStrength => widget.clip.blur.safeStrength,
  };

  double _valueAt(Duration relativeTime) {
    return widget.clip.keyframedValue(
      _property,
      widget.clip.startTime + relativeTime,
      fallback: _fallbackValue,
    );
  }

  void _emitPropertyFrames(
    List<TimelineKeyframe> propertyFrames, {
    required bool recordHistory,
  }) {
    final next =
        widget.clip.keyframes
            .where((frame) => frame.property != _property)
            .toList()
          ..addAll(propertyFrames)
          ..sort((a, b) {
            final propertyOrder = a.property.index.compareTo(b.property.index);
            return propertyOrder != 0
                ? propertyOrder
                : a.time.compareTo(b.time);
          });
    widget.onChanged(next, recordHistory);
  }

  Duration _snapTime(Duration time) {
    final frameRate = widget.frameRate.clamp(1, 120);
    final frameUs = Duration.microsecondsPerSecond / frameRate;
    final snapped = (time.inMicroseconds / frameUs).round() * frameUs;
    return Duration(
      microseconds: snapped
          .round()
          .clamp(0, widget.clip.duration.inMicroseconds)
          .toInt(),
    );
  }

  void _addAtPlayhead() {
    final time = _snapTime(_relativePlayhead);
    final existing = _propertyFrames
        .where((frame) => frame.time == time)
        .firstOrNull;
    if (existing != null) {
      setState(() => _selectedKeyframeId = existing.id);
      return;
    }
    final frame = TimelineKeyframe(
      time: time,
      property: _property,
      value: _valueAt(time).clamp(_range.minimum, _range.maximum).toDouble(),
    );
    final frames = [..._propertyFrames, frame]
      ..sort((a, b) => a.time.compareTo(b.time));
    setState(() => _selectedKeyframeId = frame.id);
    _emitPropertyFrames(frames, recordHistory: true);
  }

  void _addAtGraphPosition(_GraphGeometry geometry, Offset position) {
    final mapped = geometry.fromOffset(position);
    final time = _snapTime(mapped.time);
    final existing = _propertyFrames
        .where((frame) => frame.time == time)
        .firstOrNull;
    if (existing != null) {
      setState(() => _selectedKeyframeId = existing.id);
      return;
    }
    final frame = TimelineKeyframe(
      time: time,
      property: _property,
      value: mapped.value.clamp(_range.minimum, _range.maximum).toDouble(),
    );
    final frames = [..._propertyFrames, frame]
      ..sort((a, b) => a.time.compareTo(b.time));
    setState(() => _selectedKeyframeId = frame.id);
    _emitPropertyFrames(frames, recordHistory: true);
    widget.onSeek(widget.clip.startTime + time);
  }

  void _deleteSelected() {
    final selected = _selectedFrame;
    if (selected == null) return;
    final frames = _propertyFrames
        .where((frame) => frame.id != selected.id)
        .toList();
    setState(() => _selectedKeyframeId = null);
    _emitPropertyFrames(frames, recordHistory: true);
  }

  void _setInterpolation(TimelineKeyframeInterpolation interpolation) {
    final selected = _selectedFrame;
    if (selected == null) return;
    final curve = switch (interpolation) {
      TimelineKeyframeInterpolation.easeIn => TimelineBezierCurve.easeIn,
      TimelineKeyframeInterpolation.easeOut => TimelineBezierCurve.easeOut,
      TimelineKeyframeInterpolation.easeInOut => TimelineBezierCurve.easeInOut,
      TimelineKeyframeInterpolation.cubicBezier =>
        selected.interpolation == TimelineKeyframeInterpolation.linear ||
                selected.interpolation == TimelineKeyframeInterpolation.hold
            ? TimelineBezierCurve.easeInOut
            : selected.effectiveCurve,
      _ => TimelineBezierCurve.linear,
    };
    _replaceFrame(
      selected.copyWith(interpolation: interpolation, curve: curve),
      recordHistory: true,
    );
  }

  void _replaceFrame(
    TimelineKeyframe replacement, {
    required bool recordHistory,
  }) {
    final frames =
        _propertyFrames
            .map((frame) => frame.id == replacement.id ? replacement : frame)
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    _emitPropertyFrames(frames, recordHistory: recordHistory);
  }

  void _selectProperty(TimelineKeyframeProperty property) {
    setState(() {
      _property = property;
      _selectedKeyframeId = null;
      _valueZoom = 1;
      _valueCenter = null;
      _selectNearestToPlayhead();
    });
  }

  void _fitGraph() {
    setState(() {
      _timeZoom = 1;
      _valueZoom = 1;
      _timeOffsetUs = 0;
      _valueCenter = null;
    });
  }

  void _changeTimeZoom(double multiplier) {
    final oldZoom = _timeZoom;
    final nextZoom = (_timeZoom * multiplier).clamp(1.0, 16.0).toDouble();
    if ((nextZoom - oldZoom).abs() < 0.0001) return;
    final durationUs = math.max(1, widget.clip.duration.inMicroseconds);
    final oldVisible = durationUs / oldZoom;
    final nextVisible = durationUs / nextZoom;
    final anchor = _relativePlayhead.inMicroseconds.toDouble();
    final fraction = ((anchor - _timeOffsetUs) / oldVisible)
        .clamp(0.0, 1.0)
        .toDouble();
    setState(() {
      _timeZoom = nextZoom;
      _timeOffsetUs = (anchor - nextVisible * fraction)
          .clamp(0.0, math.max(0, durationUs - nextVisible))
          .toDouble();
    });
  }

  void _changeValueZoom(double multiplier) {
    setState(() {
      _valueCenter ??= (_range.minimum + _range.maximum) / 2;
      _valueZoom = (_valueZoom * multiplier).clamp(1.0, 12.0).toDouble();
    });
  }

  _GraphGeometry _geometry(Size size) {
    final plot = Rect.fromLTRB(
      46,
      14,
      math.max(47.0, size.width - 12),
      size.height - 30,
    );
    final durationUs = math.max(1, widget.clip.duration.inMicroseconds);
    final visibleUs = durationUs / _timeZoom;
    final maximumOffset = math.max(0.0, durationUs - visibleUs);
    final startUs = _timeOffsetUs.clamp(0.0, maximumOffset).toDouble();
    final baseSpan = math.max(0.000001, _range.maximum - _range.minimum);
    final visibleValueSpan = baseSpan / _valueZoom;
    final defaultCenter = (_range.minimum + _range.maximum) / 2;
    final center = (_valueCenter ?? defaultCenter)
        .clamp(
          _range.minimum + visibleValueSpan / 2,
          _range.maximum - visibleValueSpan / 2,
        )
        .toDouble();
    return _GraphGeometry(
      plot: plot,
      startUs: startUs,
      endUs: startUs + visibleUs,
      minimumValue: center - visibleValueSpan / 2,
      maximumValue: center + visibleValueSpan / 2,
    );
  }

  ({_GraphDragKind kind, String? id}) _hitTest(
    _GraphGeometry geometry,
    Offset position,
  ) {
    for (final frame in _propertyFrames.reversed) {
      if ((position - geometry.toOffset(frame.time, frame.value)).distance <=
          18) {
        return (kind: _GraphDragKind.keyframe, id: frame.id);
      }
    }
    final selected = _selectedFrame;
    if (selected != null) {
      final frames = _propertyFrames;
      final selectedIndex = frames.indexWhere(
        (frame) => frame.id == selected.id,
      );
      if (selectedIndex >= 0 && selectedIndex + 1 < frames.length) {
        final next = frames[selectedIndex + 1];
        final handles = geometry.handlesFor(selected, next);
        if ((position - handles.$1).distance <= 18) {
          return (kind: _GraphDragKind.firstHandle, id: selected.id);
        }
        if ((position - handles.$2).distance <= 18) {
          return (kind: _GraphDragKind.secondHandle, id: selected.id);
        }
      }
    }
    return (kind: _GraphDragKind.pan, id: null);
  }

  void _onPanStart(_GraphGeometry geometry, DragStartDetails details) {
    final target = _hitTest(geometry, details.localPosition);
    _dragKind = target.kind;
    if (target.id != null) {
      setState(() => _selectedKeyframeId = target.id);
    }
    if (_dragKind != _GraphDragKind.pan) widget.onEditStart();
  }

  void _onPanUpdate(_GraphGeometry geometry, DragUpdateDetails details) {
    if (_dragKind == _GraphDragKind.pan) {
      final visibleUs = geometry.endUs - geometry.startUs;
      final valueSpan = geometry.maximumValue - geometry.minimumValue;
      setState(() {
        _timeOffsetUs =
            (_timeOffsetUs - details.delta.dx / geometry.plot.width * visibleUs)
                .clamp(
                  0.0,
                  math.max(
                    0.0,
                    widget.clip.duration.inMicroseconds - visibleUs,
                  ),
                )
                .toDouble();
        _valueCenter =
            ((_valueCenter ?? (_range.minimum + _range.maximum) / 2) +
                    details.delta.dy / geometry.plot.height * valueSpan)
                .clamp(_range.minimum, _range.maximum)
                .toDouble();
      });
      return;
    }
    final selected = _selectedFrame;
    if (selected == null) return;
    final frames = _propertyFrames;
    final selectedIndex = frames.indexWhere((frame) => frame.id == selected.id);
    if (selectedIndex < 0) return;

    if (_dragKind == _GraphDragKind.keyframe) {
      final mapped = geometry.fromOffset(details.localPosition);
      final frameUs =
          (Duration.microsecondsPerSecond / widget.frameRate.clamp(1, 120))
              .round();
      final minimumUs = selectedIndex == 0
          ? 0
          : frames[selectedIndex - 1].time.inMicroseconds + frameUs;
      final maximumUs = selectedIndex + 1 >= frames.length
          ? widget.clip.duration.inMicroseconds
          : frames[selectedIndex + 1].time.inMicroseconds - frameUs;
      final time = _snapTime(mapped.time);
      final replacement = selected.copyWith(
        time: Duration(
          microseconds: time.inMicroseconds
              .clamp(minimumUs, math.max(minimumUs, maximumUs))
              .toInt(),
        ),
        value: mapped.value.clamp(_range.minimum, _range.maximum).toDouble(),
      );
      _replaceFrame(replacement, recordHistory: false);
      widget.onSeek(widget.clip.startTime + replacement.time);
      return;
    }

    if (selectedIndex + 1 >= frames.length) return;
    final next = frames[selectedIndex + 1];
    final spanUs = math.max(
      1,
      next.time.inMicroseconds - selected.time.inMicroseconds,
    );
    final timeProgress =
        ((geometry.timeForX(details.localPosition.dx).inMicroseconds -
                    selected.time.inMicroseconds) /
                spanUs)
            .clamp(0.0, 1.0)
            .toDouble();
    final valueDelta = next.value - selected.value;
    final safeDelta = valueDelta.abs() < 0.000001
        ? (_range.maximum - _range.minimum) * 0.1
        : valueDelta;
    final valueProgress =
        (geometry.unclampedValueForY(details.localPosition.dy) -
            selected.value) /
        safeDelta;
    final current = selected.effectiveCurve;
    final curve = _dragKind == _GraphDragKind.firstHandle
        ? TimelineBezierCurve(
            x1: timeProgress,
            y1: valueProgress,
            x2: current.x2,
            y2: current.y2,
          )
        : TimelineBezierCurve(
            x1: current.x1,
            y1: current.y1,
            x2: timeProgress,
            y2: valueProgress,
          );
    _replaceFrame(
      selected.copyWith(
        interpolation: TimelineKeyframeInterpolation.cubicBezier,
        curve: curve.normalized(),
      ),
      recordHistory: false,
    );
  }

  void _onPanEnd() {
    if (_dragKind != _GraphDragKind.none && _dragKind != _GraphDragKind.pan) {
      widget.onEditEnd();
    }
    _dragKind = _GraphDragKind.none;
  }

  void _onTap(_GraphGeometry geometry, TapUpDetails details) {
    final target = _hitTest(geometry, details.localPosition);
    if (target.id != null) {
      setState(() => _selectedKeyframeId = target.id);
      final frame = _selectedFrame;
      if (frame != null) widget.onSeek(widget.clip.startTime + frame.time);
      return;
    }
    final time = geometry.timeForX(details.localPosition.dx);
    widget.onSeek(widget.clip.startTime + _snapTime(time));
  }

  void _changeSelectedValue(double value, {required bool recordHistory}) {
    final selected = _selectedFrame;
    if (selected == null) return;
    _replaceFrame(
      selected.copyWith(
        value: value.clamp(_range.minimum, _range.maximum).toDouble(),
      ),
      recordHistory: recordHistory,
    );
  }

  @override
  Widget build(BuildContext context) {
    final frames = _propertyFrames;
    final selected = _selectedFrame;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<TimelineKeyframeProperty>(
              value: _property,
              dropdownColor: kSurfaceElevated,
              underline: const SizedBox.shrink(),
              borderRadius: BorderRadius.circular(12),
              items: [
                for (final property in widget.properties)
                  DropdownMenuItem(
                    value: property,
                    child: Text(
                      _propertyLabel(property),
                      style: const TextStyle(color: kTextPrimary),
                    ),
                  ),
              ],
              onChanged: (property) {
                if (property != null) _selectProperty(property);
              },
            ),
            _GraphButton(
              tooltip: 'Add keyframe at playhead',
              icon: Icons.add_rounded,
              label: 'Add',
              onPressed: _addAtPlayhead,
            ),
            _GraphButton(
              tooltip: 'Delete selected keyframe',
              icon: Icons.delete_outline_rounded,
              label: 'Delete',
              onPressed: selected == null ? null : _deleteSelected,
            ),
            _GraphButton(
              tooltip: 'Show the whole clip and value range',
              icon: Icons.fit_screen_rounded,
              label: 'Fit',
              onPressed: _fitGraph,
            ),
            IconButton(
              tooltip: 'Zoom out in time',
              onPressed: _timeZoom <= 1 ? null : () => _changeTimeZoom(0.7),
              icon: const Icon(Icons.zoom_out_rounded),
            ),
            IconButton(
              tooltip: 'Zoom in in time',
              onPressed: _timeZoom >= 16 ? null : () => _changeTimeZoom(1.4),
              icon: const Icon(Icons.zoom_in_rounded),
            ),
            IconButton(
              tooltip: 'Compress value range',
              onPressed: _valueZoom <= 1 ? null : () => _changeValueZoom(0.7),
              icon: const Icon(Icons.unfold_more_rounded),
            ),
            IconButton(
              tooltip: 'Expand value range',
              onPressed: _valueZoom >= 12 ? null : () => _changeValueZoom(1.4),
              icon: const Icon(Icons.unfold_less_rounded),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: kBackground,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBorder),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final geometry = _geometry(constraints.biggest);
                return GestureDetector(
                  key: const ValueKey('keyframe_graph_canvas'),
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _onTap(geometry, details),
                  onDoubleTapDown: (details) =>
                      _addAtGraphPosition(geometry, details.localPosition),
                  onPanStart: (details) => _onPanStart(geometry, details),
                  onPanUpdate: (details) => _onPanUpdate(geometry, details),
                  onPanEnd: (_) => _onPanEnd(),
                  onPanCancel: _onPanEnd,
                  child: CustomPaint(
                    painter: _KeyframeGraphPainter(
                      geometry: geometry,
                      frames: frames,
                      selectedKeyframeId: _selectedKeyframeId,
                      playhead: _relativePlayhead,
                      fallbackValue: _fallbackValue,
                      valueFormatter: _range.format,
                    ),
                    child: const SizedBox.expand(),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (selected == null)
          const Text(
            'Double-tap the graph or use Add to create a keyframe. Drag the empty graph to pan.',
            style: TextStyle(color: kTextSecondary, fontSize: 11),
          )
        else ...[
          Row(
            children: [
              Text(
                '${_formatTime(selected.time)}  •  ${_range.format(selected.value)}',
                style: const TextStyle(
                  color: kTextPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              const Text(
                'Outgoing curve',
                style: TextStyle(color: kTextSecondary, fontSize: 11),
              ),
            ],
          ),
          Slider(
            value: selected.value
                .clamp(_range.minimum, _range.maximum)
                .toDouble(),
            min: _range.minimum,
            max: _range.maximum,
            label: _range.format(selected.value),
            onChangeStart: (_) => widget.onEditStart(),
            onChanged: (value) =>
                _changeSelectedValue(value, recordHistory: false),
            onChangeEnd: (_) => widget.onEditEnd(),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final interpolation
                    in TimelineKeyframeInterpolation.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: ChoiceChip(
                      label: Text(_interpolationLabel(interpolation)),
                      selected: selected.interpolation == interpolation,
                      onSelected: (_) => _setInterpolation(interpolation),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Drag a point to change time and value. Drag either tangent handle to create a custom curve.',
            style: TextStyle(color: kTextSecondary, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

class _GraphButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _GraphButton({
    required this.tooltip,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label),
      ),
    );
  }
}

class _GraphGeometry {
  final Rect plot;
  final double startUs;
  final double endUs;
  final double minimumValue;
  final double maximumValue;

  const _GraphGeometry({
    required this.plot,
    required this.startUs,
    required this.endUs,
    required this.minimumValue,
    required this.maximumValue,
  });

  Offset toOffset(Duration time, double value) {
    final xProgress =
        ((time.inMicroseconds - startUs) / math.max(1, endUs - startUs))
            .clamp(0.0, 1.0)
            .toDouble();
    final yProgress =
        ((value - minimumValue) /
                math.max(0.000001, maximumValue - minimumValue))
            .clamp(0.0, 1.0)
            .toDouble();
    return Offset(
      plot.left + plot.width * xProgress,
      plot.bottom - plot.height * yProgress,
    );
  }

  ({Duration time, double value}) fromOffset(Offset offset) {
    return (
      time: timeForX(offset.dx),
      value: unclampedValueForY(
        offset.dy,
      ).clamp(minimumValue, maximumValue).toDouble(),
    );
  }

  Duration timeForX(double x) {
    final progress = ((x - plot.left) / math.max(1, plot.width))
        .clamp(0.0, 1.0)
        .toDouble();
    return Duration(
      microseconds: (startUs + (endUs - startUs) * progress).round(),
    );
  }

  double unclampedValueForY(double y) {
    final progress = 1 - (y - plot.top) / math.max(1, plot.height);
    return minimumValue + (maximumValue - minimumValue) * progress;
  }

  (Offset, Offset) handlesFor(
    TimelineKeyframe previous,
    TimelineKeyframe next,
  ) {
    final curve = previous.effectiveCurve;
    final spanUs = next.time.inMicroseconds - previous.time.inMicroseconds;
    final delta = next.value - previous.value;
    return (
      toOffset(
        Duration(
          microseconds:
              previous.time.inMicroseconds + (spanUs * curve.x1).round(),
        ),
        previous.value + delta * curve.y1,
      ),
      toOffset(
        Duration(
          microseconds:
              previous.time.inMicroseconds + (spanUs * curve.x2).round(),
        ),
        previous.value + delta * curve.y2,
      ),
    );
  }
}

class _KeyframeGraphPainter extends CustomPainter {
  final _GraphGeometry geometry;
  final List<TimelineKeyframe> frames;
  final String? selectedKeyframeId;
  final Duration playhead;
  final double fallbackValue;
  final String Function(double value) valueFormatter;

  const _KeyframeGraphPainter({
    required this.geometry,
    required this.frames,
    required this.selectedKeyframeId,
    required this.playhead,
    required this.fallbackValue,
    required this.valueFormatter,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = kBorder.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (var index = 0; index <= 4; index++) {
      final x = geometry.plot.left + geometry.plot.width * index / 4;
      final y = geometry.plot.top + geometry.plot.height * index / 4;
      canvas.drawLine(
        Offset(x, geometry.plot.top),
        Offset(x, geometry.plot.bottom),
        gridPaint,
      );
      canvas.drawLine(
        Offset(geometry.plot.left, y),
        Offset(geometry.plot.right, y),
        gridPaint,
      );
      final timeUs =
          geometry.startUs + (geometry.endUs - geometry.startUs) * index / 4;
      _paintLabel(
        canvas,
        _formatTime(Duration(microseconds: timeUs.round())),
        Offset(x, geometry.plot.bottom + 7),
        center: true,
      );
      final value =
          geometry.maximumValue -
          (geometry.maximumValue - geometry.minimumValue) * index / 4;
      _paintLabel(
        canvas,
        valueFormatter(value),
        Offset(geometry.plot.left - 6, y - 6),
        alignRight: true,
      );
    }

    canvas.save();
    canvas.clipRect(geometry.plot.inflate(1));
    final curvePaint = Paint()
      ..color = kAccentSecondary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    if (frames.isEmpty) {
      final start = geometry.toOffset(
        Duration(microseconds: geometry.startUs.round()),
        fallbackValue,
      );
      final end = geometry.toOffset(
        Duration(microseconds: geometry.endUs.round()),
        fallbackValue,
      );
      path
        ..moveTo(start.dx, start.dy)
        ..lineTo(end.dx, end.dy);
    } else {
      final first = frames.first;
      final start = geometry.toOffset(
        Duration(microseconds: geometry.startUs.round()),
        first.value,
      );
      path.moveTo(start.dx, start.dy);
      path.lineTo(
        geometry.toOffset(first.time, first.value).dx,
        geometry.toOffset(first.time, first.value).dy,
      );
      for (var index = 0; index + 1 < frames.length; index++) {
        final previous = frames[index];
        final next = frames[index + 1];
        const samples = 36;
        for (var sample = 1; sample <= samples; sample++) {
          final progress = sample / samples;
          final timeUs =
              previous.time.inMicroseconds +
              ((next.time.inMicroseconds - previous.time.inMicroseconds) *
                      progress)
                  .round();
          final value =
              previous.value +
              (next.value - previous.value) *
                  previous.transformProgress(progress);
          final point = geometry.toOffset(
            Duration(microseconds: timeUs),
            value,
          );
          path.lineTo(point.dx, point.dy);
        }
      }
      final last = frames.last;
      final end = geometry.toOffset(
        Duration(microseconds: geometry.endUs.round()),
        last.value,
      );
      path.lineTo(end.dx, end.dy);
    }
    canvas.drawPath(path, curvePaint);

    final selectedIndex = frames.indexWhere(
      (frame) => frame.id == selectedKeyframeId,
    );
    if (selectedIndex >= 0 && selectedIndex + 1 < frames.length) {
      final selected = frames[selectedIndex];
      final next = frames[selectedIndex + 1];
      final handles = geometry.handlesFor(selected, next);
      final anchor = geometry.toOffset(selected.time, selected.value);
      final destination = geometry.toOffset(next.time, next.value);
      final handlePaint = Paint()
        ..color = kAccent.withValues(alpha: 0.72)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas
        ..drawLine(anchor, handles.$1, handlePaint)
        ..drawLine(destination, handles.$2, handlePaint);
      final handleFill = Paint()..color = kAccent;
      canvas
        ..drawCircle(handles.$1, 5, handleFill)
        ..drawCircle(handles.$2, 5, handleFill);
    }

    for (final frame in frames) {
      final point = geometry.toOffset(frame.time, frame.value);
      final selected = frame.id == selectedKeyframeId;
      final diamond = Path()
        ..moveTo(point.dx, point.dy - (selected ? 8 : 6))
        ..lineTo(point.dx + (selected ? 8 : 6), point.dy)
        ..lineTo(point.dx, point.dy + (selected ? 8 : 6))
        ..lineTo(point.dx - (selected ? 8 : 6), point.dy)
        ..close();
      canvas.drawPath(
        diamond,
        Paint()..color = selected ? kAccent : kAccentSecondary,
      );
      canvas.drawPath(
        diamond,
        Paint()
          ..color = kTextPrimary.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    final playheadX = geometry.toOffset(playhead, geometry.minimumValue).dx;
    canvas.drawLine(
      Offset(playheadX, geometry.plot.top),
      Offset(playheadX, geometry.plot.bottom),
      Paint()
        ..color = kAccent.withValues(alpha: 0.9)
        ..strokeWidth = 1.2,
    );
    canvas.restore();
  }

  void _paintLabel(
    Canvas canvas,
    String value,
    Offset position, {
    bool center = false,
    bool alignRight = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: const TextStyle(color: kTextSecondary, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final dx = center
        ? position.dx - painter.width / 2
        : alignRight
        ? position.dx - painter.width
        : position.dx;
    painter.paint(canvas, Offset(dx, position.dy));
  }

  @override
  bool shouldRepaint(covariant _KeyframeGraphPainter oldDelegate) {
    return oldDelegate.geometry != geometry ||
        oldDelegate.frames != frames ||
        oldDelegate.selectedKeyframeId != selectedKeyframeId ||
        oldDelegate.playhead != playhead ||
        oldDelegate.fallbackValue != fallbackValue;
  }
}

class _PropertyRange {
  final double minimum;
  final double maximum;
  final String Function(double value) format;

  const _PropertyRange({
    required this.minimum,
    required this.maximum,
    required this.format,
  });
}

_PropertyRange _propertyRange(TimelineKeyframeProperty property) {
  return switch (property) {
    TimelineKeyframeProperty.opacity => _PropertyRange(
      minimum: 0,
      maximum: 1,
      format: (value) => '${(value * 100).round()}%',
    ),
    TimelineKeyframeProperty.scale => _PropertyRange(
      minimum: 0.2,
      maximum: 4,
      format: (value) => '${value.toStringAsFixed(2)}×',
    ),
    TimelineKeyframeProperty.rotation => _PropertyRange(
      minimum: -math.pi * 2,
      maximum: math.pi * 2,
      format: (value) => '${(value * 180 / math.pi).round()}°',
    ),
    TimelineKeyframeProperty.positionX => _PropertyRange(
      minimum: -kTimelineDesignWidth / 2,
      maximum: kTimelineDesignWidth / 2,
      format: (value) => value.round().toString(),
    ),
    TimelineKeyframeProperty.positionY => _PropertyRange(
      minimum: -kTimelineDesignHeight / 2,
      maximum: kTimelineDesignHeight / 2,
      format: (value) => value.round().toString(),
    ),
    TimelineKeyframeProperty.volume => _PropertyRange(
      minimum: 0,
      maximum: 2,
      format: (value) => '${(value * 100).round()}%',
    ),
    TimelineKeyframeProperty.blurStrength => _PropertyRange(
      minimum: 0,
      maximum: 30,
      format: (value) => value.toStringAsFixed(1),
    ),
  };
}

String _propertyLabel(TimelineKeyframeProperty property) {
  return switch (property) {
    TimelineKeyframeProperty.opacity => 'Opacity',
    TimelineKeyframeProperty.scale => 'Scale',
    TimelineKeyframeProperty.rotation => 'Rotation',
    TimelineKeyframeProperty.positionX => 'Position X',
    TimelineKeyframeProperty.positionY => 'Position Y',
    TimelineKeyframeProperty.volume => 'Volume',
    TimelineKeyframeProperty.blurStrength => 'Blur strength',
  };
}

String _interpolationLabel(TimelineKeyframeInterpolation interpolation) {
  return switch (interpolation) {
    TimelineKeyframeInterpolation.hold => 'Hold',
    TimelineKeyframeInterpolation.linear => 'Linear',
    TimelineKeyframeInterpolation.easeIn => 'Ease in',
    TimelineKeyframeInterpolation.easeOut => 'Ease out',
    TimelineKeyframeInterpolation.easeInOut => 'Ease in/out',
    TimelineKeyframeInterpolation.cubicBezier => 'Custom',
  };
}

String _formatTime(Duration duration) {
  final totalMs = math.max(0, duration.inMilliseconds);
  final minutes = totalMs ~/ 60000;
  final seconds = (totalMs % 60000) ~/ 1000;
  final milliseconds = totalMs % 1000;
  return '$minutes:${seconds.toString().padLeft(2, '0')}.${milliseconds.toString().padLeft(3, '0')}';
}
