import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_surface.dart';
import '../models/keyframe_curve_presets.dart';
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

enum _GraphDragKind {
  none,
  keyframe,
  firstHandle,
  secondHandle,
  pan,
  boxSelect,
}

class _KeyframeGraphEditorState extends State<KeyframeGraphEditor> {
  late TimelineKeyframeProperty _property;
  String? _selectedKeyframeId;
  Set<String> _selectedKeyframeIds = <String>{};
  _GraphDragKind _dragKind = _GraphDragKind.none;
  Map<String, TimelineKeyframe> _dragStartFrames = const {};
  Offset? _dragStartPosition;
  Rect? _selectionRect;
  bool _boxSelectionMode = false;
  List<TimelineKeyframe> _clipboard = const [];
  final Set<TimelineKeyframeProperty> _hiddenProperties = {};
  final Set<TimelineKeyframeProperty> _lockedProperties = {};
  TimelineKeyframeProperty? _soloProperty;
  double _timeZoom = 1;
  double _valueZoom = 1;
  double _timeOffsetUs = 0;
  double? _valueCenter;
  bool _editGestureOpen = false;

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
      _selectedKeyframeIds = <String>{};
    }
    final liveIds = _propertyFrames.map((frame) => frame.id).toSet();
    _selectedKeyframeIds = _selectedKeyframeIds.intersection(liveIds);
    if (_selectedKeyframeId != null &&
        !_selectedKeyframeIds.contains(_selectedKeyframeId)) {
      _selectedKeyframeId = _selectedKeyframeIds.firstOrNull;
    }
  }

  void _beginEdit() {
    if (_editGestureOpen) return;
    _editGestureOpen = true;
    widget.onEditStart();
  }

  void _endEdit() {
    if (!_editGestureOpen) return;
    _editGestureOpen = false;
    widget.onEditEnd();
  }

  @override
  void dispose() {
    _endEdit();
    super.dispose();
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

  bool get _channelVisible =>
      !_hiddenProperties.contains(_property) &&
      (_soloProperty == null || _soloProperty == _property);

  bool get _channelLocked => _lockedProperties.contains(_property);

  Iterable<TimelineKeyframe> get _selectedFrames =>
      _propertyFrames.where((frame) => _selectedKeyframeIds.contains(frame.id));

  void _selectOnly(String? id) {
    _selectedKeyframeId = id;
    _selectedKeyframeIds = id == null ? <String>{} : <String>{id};
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
    _selectOnly(frames.first.id);
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
    if (_channelLocked) return;
    final time = _snapTime(_relativePlayhead);
    final existing = _propertyFrames
        .where((frame) => frame.time == time)
        .firstOrNull;
    if (existing != null) {
      setState(() => _selectOnly(existing.id));
      return;
    }
    final frame = TimelineKeyframe(
      time: time,
      property: _property,
      value: _valueAt(time).clamp(_range.minimum, _range.maximum).toDouble(),
    );
    final frames = [..._propertyFrames, frame]
      ..sort((a, b) => a.time.compareTo(b.time));
    setState(() => _selectOnly(frame.id));
    _emitPropertyFrames(frames, recordHistory: true);
  }

  void _addAtGraphPosition(_GraphGeometry geometry, Offset position) {
    if (_channelLocked) return;
    final mapped = geometry.fromOffset(position);
    final time = _snapTime(mapped.time);
    final existing = _propertyFrames
        .where((frame) => frame.time == time)
        .firstOrNull;
    if (existing != null) {
      setState(() => _selectOnly(existing.id));
      return;
    }
    final frame = TimelineKeyframe(
      time: time,
      property: _property,
      value: mapped.value.clamp(_range.minimum, _range.maximum).toDouble(),
    );
    final frames = [..._propertyFrames, frame]
      ..sort((a, b) => a.time.compareTo(b.time));
    setState(() => _selectOnly(frame.id));
    _emitPropertyFrames(frames, recordHistory: true);
    widget.onSeek(widget.clip.startTime + time);
  }

  void _deleteSelected() {
    if (_selectedKeyframeIds.isEmpty || _channelLocked) return;
    final frames = _propertyFrames
        .where((frame) => !_selectedKeyframeIds.contains(frame.id))
        .toList();
    setState(() => _selectOnly(null));
    _emitPropertyFrames(frames, recordHistory: true);
  }

  void _setInterpolation(TimelineKeyframeInterpolation interpolation) {
    if (_selectedKeyframeIds.isEmpty || _channelLocked) return;
    final replacements = _selectedFrames.map((selected) {
      final curve = switch (interpolation) {
        TimelineKeyframeInterpolation.easeIn => TimelineBezierCurve.easeIn,
        TimelineKeyframeInterpolation.easeOut => TimelineBezierCurve.easeOut,
        TimelineKeyframeInterpolation.easeInOut =>
          TimelineBezierCurve.easeInOut,
        TimelineKeyframeInterpolation.cubicBezier =>
          selected.interpolation == TimelineKeyframeInterpolation.linear ||
                  selected.interpolation == TimelineKeyframeInterpolation.hold
              ? TimelineBezierCurve.easeInOut
              : selected.effectiveCurve,
        _ => TimelineBezierCurve.linear,
      };
      return selected.copyWith(interpolation: interpolation, curve: curve);
    });
    _replaceFrames(replacements, recordHistory: true);
  }

  void _setCurvePreset(TimelineCurvePreset preset) {
    if (_selectedKeyframeIds.isEmpty || _channelLocked) return;
    _replaceFrames(
      _selectedFrames.map(
        (selected) => selected.copyWith(
          interpolation: preset.interpolation,
          curve: preset.curve,
        ),
      ),
      recordHistory: true,
    );
  }

  void _replaceFrame(
    TimelineKeyframe replacement, {
    required bool recordHistory,
  }) {
    _replaceFrames([replacement], recordHistory: recordHistory);
  }

  void _replaceFrames(
    Iterable<TimelineKeyframe> replacements, {
    required bool recordHistory,
  }) {
    final replacementsById = {
      for (final replacement in replacements) replacement.id: replacement,
    };
    final frames =
        _propertyFrames
            .map((frame) => replacementsById[frame.id] ?? frame)
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    _emitPropertyFrames(frames, recordHistory: recordHistory);
  }

  void _selectProperty(TimelineKeyframeProperty property) {
    setState(() {
      _property = property;
      _selectOnly(null);
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
    final visibleFrames = _channelVisible
        ? _propertyFrames
        : const <TimelineKeyframe>[];
    for (final frame in visibleFrames.reversed) {
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
    _dragKind = _boxSelectionMode && target.kind == _GraphDragKind.pan
        ? _GraphDragKind.boxSelect
        : target.kind;
    final targetId = target.id;
    if (targetId != null) {
      setState(() {
        _selectedKeyframeId = targetId;
        if (!_selectedKeyframeIds.contains(targetId)) {
          _selectedKeyframeIds = <String>{targetId};
        }
      });
    }
    if (_channelLocked &&
        _dragKind != _GraphDragKind.pan &&
        _dragKind != _GraphDragKind.boxSelect) {
      _dragKind = _GraphDragKind.none;
      return;
    }
    if (_dragKind == _GraphDragKind.keyframe) {
      _dragStartFrames = {for (final frame in _selectedFrames) frame.id: frame};
      _dragStartPosition = details.localPosition;
    } else if (_dragKind == _GraphDragKind.boxSelect) {
      _dragStartPosition = details.localPosition;
      setState(() {
        _selectionRect = Rect.fromPoints(
          details.localPosition,
          details.localPosition,
        );
        _selectOnly(null);
      });
    }
    if (_dragKind != _GraphDragKind.pan &&
        _dragKind != _GraphDragKind.boxSelect &&
        _dragKind != _GraphDragKind.none) {
      _beginEdit();
    }
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
    if (_dragKind == _GraphDragKind.boxSelect) {
      final origin = _dragStartPosition ?? details.localPosition;
      final selection = Rect.fromPoints(origin, details.localPosition);
      final selectedIds = _propertyFrames
          .where(
            (frame) =>
                selection.contains(geometry.toOffset(frame.time, frame.value)),
          )
          .map((frame) => frame.id)
          .toSet();
      setState(() {
        _selectionRect = selection;
        _selectedKeyframeIds = selectedIds;
        _selectedKeyframeId = selectedIds.firstOrNull;
      });
      return;
    }
    final selected = _selectedFrame;
    if (selected == null) return;
    final frames = _propertyFrames;
    final selectedIndex = frames.indexWhere((frame) => frame.id == selected.id);
    if (selectedIndex < 0) return;

    if (_dragKind == _GraphDragKind.keyframe) {
      final baseline = _dragStartFrames[selected.id];
      if (baseline == null) return;
      final mapped = geometry.fromOffset(details.localPosition);
      final frameUs =
          (Duration.microsecondsPerSecond / widget.frameRate.clamp(1, 120))
              .round();
      var minimumDeltaUs = -_dragStartFrames.values
          .map((frame) => frame.time.inMicroseconds)
          .reduce((first, second) => first < second ? first : second);
      var maximumDeltaUs =
          widget.clip.duration.inMicroseconds -
          _dragStartFrames.values
              .map((frame) => frame.time.inMicroseconds)
              .reduce((first, second) => first > second ? first : second);
      final unselected = frames.where(
        (frame) => !_dragStartFrames.containsKey(frame.id),
      );
      for (final moving in _dragStartFrames.values) {
        for (final stationary in unselected) {
          if (stationary.time < moving.time) {
            minimumDeltaUs = math.max(
              minimumDeltaUs,
              stationary.time.inMicroseconds +
                  frameUs -
                  moving.time.inMicroseconds,
            );
          } else {
            maximumDeltaUs = math.min(
              maximumDeltaUs,
              stationary.time.inMicroseconds -
                  frameUs -
                  moving.time.inMicroseconds,
            );
            break;
          }
        }
      }
      final desiredTime = _snapTime(mapped.time);
      final deltaUs =
          (desiredTime.inMicroseconds - baseline.time.inMicroseconds)
              .clamp(minimumDeltaUs, math.max(minimumDeltaUs, maximumDeltaUs))
              .toInt();
      final desiredValueDelta = mapped.value - baseline.value;
      final minimumValueDelta = _dragStartFrames.values
          .map((frame) => _range.minimum - frame.value)
          .reduce((first, second) => first > second ? first : second);
      final maximumValueDelta = _dragStartFrames.values
          .map((frame) => _range.maximum - frame.value)
          .reduce((first, second) => first < second ? first : second);
      final valueDelta = desiredValueDelta
          .clamp(minimumValueDelta, maximumValueDelta)
          .toDouble();
      final replacements = _dragStartFrames.values.map(
        (frame) => frame.copyWith(
          time: Duration(microseconds: frame.time.inMicroseconds + deltaUs),
          value: frame.value + valueDelta,
        ),
      );
      _replaceFrames(replacements, recordHistory: false);
      widget.onSeek(
        widget.clip.startTime +
            Duration(microseconds: baseline.time.inMicroseconds + deltaUs),
      );
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
    if (_dragKind != _GraphDragKind.none &&
        _dragKind != _GraphDragKind.pan &&
        _dragKind != _GraphDragKind.boxSelect) {
      _endEdit();
    }
    setState(() {
      _dragKind = _GraphDragKind.none;
      _dragStartFrames = const {};
      _dragStartPosition = null;
      _selectionRect = null;
    });
  }

  void _onTap(_GraphGeometry geometry, TapUpDetails details) {
    final target = _hitTest(geometry, details.localPosition);
    if (target.id != null) {
      setState(() => _selectOnly(target.id));
      final frame = _selectedFrame;
      if (frame != null) widget.onSeek(widget.clip.startTime + frame.time);
      return;
    }
    final time = geometry.timeForX(details.localPosition.dx);
    widget.onSeek(widget.clip.startTime + _snapTime(time));
  }

  void _changeSelectedValue(double value, {required bool recordHistory}) {
    final selected = _selectedFrame;
    if (selected == null || _channelLocked) return;
    _replaceFrame(
      selected.copyWith(
        value: value.clamp(_range.minimum, _range.maximum).toDouble(),
      ),
      recordHistory: recordHistory,
    );
  }

  void _selectAllFrames() {
    final ids = _propertyFrames.map((frame) => frame.id).toSet();
    setState(() {
      _selectedKeyframeIds = ids;
      _selectedKeyframeId = ids.firstOrNull;
    });
  }

  void _copySelectedFrames() {
    final selected = _selectedFrames.toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    if (selected.isEmpty) return;
    setState(() => _clipboard = List.unmodifiable(selected));
  }

  void _pasteFramesAtPlayhead() {
    if (_clipboard.isEmpty || _channelLocked) return;
    final source = [..._clipboard]..sort((a, b) => a.time.compareTo(b.time));
    final sourceStartUs = source.first.time.inMicroseconds;
    final sourceSpanUs = source.last.time.inMicroseconds - sourceStartUs;
    final maximumStartUs = math.max(
      0,
      widget.clip.duration.inMicroseconds - sourceSpanUs,
    );
    final pasteStartUs = _snapTime(
      _relativePlayhead,
    ).inMicroseconds.clamp(0, maximumStartUs).toInt();
    final occupied = _propertyFrames
        .map((frame) => frame.time.inMicroseconds)
        .toSet();
    final pasted = <TimelineKeyframe>[];
    for (final frame in source) {
      final timeUs = pasteStartUs + frame.time.inMicroseconds - sourceStartUs;
      if (!occupied.add(timeUs)) continue;
      pasted.add(
        TimelineKeyframe(
          time: Duration(microseconds: timeUs),
          property: _property,
          value: frame.value,
          interpolation: frame.interpolation,
          curve: frame.curve,
        ),
      );
    }
    if (pasted.isEmpty) return;
    final frames = [..._propertyFrames, ...pasted]
      ..sort((a, b) => a.time.compareTo(b.time));
    setState(() {
      _selectedKeyframeIds = pasted.map((frame) => frame.id).toSet();
      _selectedKeyframeId = pasted.first.id;
    });
    _emitPropertyFrames(frames, recordHistory: true);
    widget.onSeek(widget.clip.startTime + pasted.first.time);
  }

  Future<void> _editSelectedNumeric() async {
    final selected = _selectedFrame;
    if (selected == null || _channelLocked) return;
    final replacement = await showDialog<TimelineKeyframe>(
      context: context,
      builder: (dialogContext) => _NumericKeyframeDialog(
        initialTimeMs: (selected.time.inMicroseconds / 1000).toStringAsFixed(3),
        initialValue: selected.value.toStringAsFixed(4),
        valueLabel: '${_propertyLabel(_property)} value',
        resolve: (timeText, valueText) {
          final timeMs = double.tryParse(timeText.trim());
          final value = double.tryParse(valueText.trim());
          if (timeMs == null || value == null || !value.isFinite) {
            return (frame: null, error: 'Enter valid numbers.');
          }
          final time = _snapTime(
            Duration(microseconds: (timeMs * 1000).round()),
          );
          final collision = _propertyFrames.any(
            (frame) => frame.id != selected.id && frame.time == time,
          );
          if (collision) {
            return (
              frame: null,
              error: 'Another keyframe already uses this frame.',
            );
          }
          return (
            frame: selected.copyWith(
              time: time,
              value: value.clamp(_range.minimum, _range.maximum).toDouble(),
            ),
            error: null,
          );
        },
      ),
    );
    if (replacement == null || !mounted) return;
    _replaceFrame(replacement, recordHistory: true);
    widget.onSeek(widget.clip.startTime + replacement.time);
  }

  Future<void> _showChannelControls() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => AppSheetSurface(
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: math.min(
                MediaQuery.sizeOf(sheetContext).height * 0.68,
                560,
              ),
              child: Column(
                children: [
                  AppSheetHeader(
                    title: 'Animation channels',
                    subtitle:
                        'Visibility, solo and locking affect this graph session only',
                    icon: Icons.tune_rounded,
                    onClose: () => Navigator.pop(sheetContext),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 14, 12, 20),
                      itemCount: widget.properties.length,
                      itemBuilder: (context, index) {
                        final property = widget.properties[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 7),
                          child: AppPanel(
                            padding: EdgeInsets.zero,
                            color: property == _property
                                ? kAccent.withValues(alpha: 0.07)
                                : kSurfaceElevated,
                            selected: property == _property,
                            child: ListTile(
                              key: ValueKey(
                                'keyframe_channel_${property.name}',
                              ),
                              title: Text(_propertyLabel(property)),
                              selected: property == _property,
                              onTap: () {
                                _selectProperty(property);
                                Navigator.pop(sheetContext);
                              },
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    key: ValueKey(
                                      'keyframe_channel_visibility_${property.name}',
                                    ),
                                    tooltip:
                                        _hiddenProperties.contains(property)
                                        ? 'Show channel'
                                        : 'Hide channel',
                                    onPressed: () {
                                      setState(() {
                                        if (!_hiddenProperties.add(property)) {
                                          _hiddenProperties.remove(property);
                                        }
                                      });
                                      setSheetState(() {});
                                    },
                                    icon: Icon(
                                      _hiddenProperties.contains(property)
                                          ? Icons.visibility_off_rounded
                                          : Icons.visibility_rounded,
                                    ),
                                  ),
                                  IconButton(
                                    key: ValueKey(
                                      'keyframe_channel_solo_${property.name}',
                                    ),
                                    tooltip: _soloProperty == property
                                        ? 'Clear solo'
                                        : 'Solo channel',
                                    onPressed: () {
                                      setState(() {
                                        _soloProperty =
                                            _soloProperty == property
                                            ? null
                                            : property;
                                        if (_soloProperty != null) {
                                          _property = property;
                                          _selectOnly(null);
                                          _selectNearestToPlayhead();
                                        }
                                      });
                                      setSheetState(() {});
                                    },
                                    icon: Icon(
                                      Icons.headphones_rounded,
                                      color: _soloProperty == property
                                          ? kAccent
                                          : null,
                                    ),
                                  ),
                                  IconButton(
                                    key: ValueKey(
                                      'keyframe_channel_lock_${property.name}',
                                    ),
                                    tooltip:
                                        _lockedProperties.contains(property)
                                        ? 'Unlock channel'
                                        : 'Lock channel',
                                    onPressed: () {
                                      setState(() {
                                        if (!_lockedProperties.add(property)) {
                                          _lockedProperties.remove(property);
                                        }
                                      });
                                      setSheetState(() {});
                                    },
                                    icon: Icon(
                                      _lockedProperties.contains(property)
                                          ? Icons.lock_rounded
                                          : Icons.lock_open_rounded,
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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final frames = _propertyFrames;
    final selected = _selectedFrame;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<TimelineKeyframeProperty>(
                initialValue: _property,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.fromLTRB(12, 9, 10, 9),
                  prefixIcon: Icon(Icons.diamond_outlined, size: 17),
                  prefixIconConstraints: BoxConstraints(minWidth: 36),
                ),
                items: [
                  for (final property in widget.properties)
                    DropdownMenuItem(
                      value: property,
                      child: Text(
                        _propertyLabel(property),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: kTextPrimary),
                      ),
                    ),
                ],
                onChanged: (property) {
                  if (property != null) _selectProperty(property);
                },
              ),
            ),
            const SizedBox(width: 8),
            _GraphButton(
              tooltip: 'Add keyframe at playhead',
              icon: Icons.add_rounded,
              label: 'Add',
              compact: true,
              onPressed: _channelLocked ? null : _addAtPlayhead,
            ),
            const SizedBox(width: 8),
            _GraphButton(
              tooltip: 'Delete selected keyframe',
              icon: Icons.delete_outline_rounded,
              label: _selectedKeyframeIds.length > 1
                  ? 'Delete ${_selectedKeyframeIds.length}'
                  : 'Delete',
              compact: true,
              onPressed: selected == null || _channelLocked
                  ? null
                  : _deleteSelected,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _GraphButton(
                  tooltip: 'Drag a box around multiple keyframes',
                  icon: Icons.crop_free_rounded,
                  label: 'Box',
                  compact: true,
                  selected: _boxSelectionMode,
                  onPressed: () {
                    setState(() => _boxSelectionMode = !_boxSelectionMode);
                  },
                ),
                const SizedBox(width: 7),
                _GraphButton(
                  tooltip: 'Select every keyframe in this channel',
                  icon: Icons.select_all_rounded,
                  label: 'All',
                  compact: true,
                  onPressed: frames.isEmpty ? null : _selectAllFrames,
                ),
                const SizedBox(width: 7),
                _GraphButton(
                  tooltip: 'Copy selected keyframes',
                  icon: Icons.copy_rounded,
                  label: 'Copy',
                  compact: true,
                  onPressed: selected == null ? null : _copySelectedFrames,
                ),
                const SizedBox(width: 7),
                _GraphButton(
                  tooltip: 'Paste copied keyframes at the playhead',
                  icon: Icons.content_paste_rounded,
                  label: 'Paste',
                  compact: true,
                  onPressed: _clipboard.isEmpty || _channelLocked
                      ? null
                      : _pasteFramesAtPlayhead,
                ),
                const SizedBox(width: 7),
                _GraphButton(
                  tooltip: 'Enter exact keyframe time and value',
                  icon: Icons.pin_rounded,
                  label: 'Numeric',
                  compact: true,
                  onPressed: selected == null || _channelLocked
                      ? null
                      : _editSelectedNumeric,
                ),
                const SizedBox(width: 7),
                _GraphButton(
                  tooltip: 'Show, solo or lock animation channels',
                  icon: Icons.tune_rounded,
                  label: 'Channels',
                  compact: true,
                  onPressed: _showChannelControls,
                ),
                const SizedBox(width: 7),
                _GraphButton(
                  tooltip: 'Show the whole clip and value range',
                  icon: Icons.fit_screen_rounded,
                  label: 'Fit',
                  compact: true,
                  onPressed: _fitGraph,
                ),
                const SizedBox(width: 7),
                _GraphIconButton(
                  tooltip: 'Zoom out in time',
                  icon: Icons.zoom_out_rounded,
                  onPressed: _timeZoom <= 1 ? null : () => _changeTimeZoom(0.7),
                ),
                const SizedBox(width: 7),
                _GraphIconButton(
                  tooltip: 'Zoom in in time',
                  icon: Icons.zoom_in_rounded,
                  onPressed: _timeZoom >= 16
                      ? null
                      : () => _changeTimeZoom(1.4),
                ),
                const SizedBox(width: 7),
                _GraphIconButton(
                  tooltip: 'Compress value range',
                  icon: Icons.unfold_more_rounded,
                  onPressed: _valueZoom <= 1
                      ? null
                      : () => _changeValueZoom(0.7),
                ),
                const SizedBox(width: 7),
                _GraphIconButton(
                  tooltip: 'Expand value range',
                  icon: Icons.unfold_less_rounded,
                  onPressed: _valueZoom >= 12
                      ? null
                      : () => _changeValueZoom(1.4),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0C0F12), kBackground],
              ),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: kBorderStrong),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x2E000000),
                  blurRadius: 12,
                  offset: Offset(0, 5),
                ),
              ],
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
                      frames: _channelVisible
                          ? frames
                          : const <TimelineKeyframe>[],
                      selectedKeyframeId: _selectedKeyframeId,
                      selectedKeyframeIds: _selectedKeyframeIds,
                      selectionRect: _selectionRect,
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
                _selectedKeyframeIds.length > 1
                    ? '${_selectedKeyframeIds.length} keys selected  •  Primary ${_formatTime(selected.time)}'
                    : '${_formatTime(selected.time)}  •  ${_range.format(selected.value)}',
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
            onChangeStart: _channelLocked ? null : (_) => _beginEdit(),
            onChanged: _channelLocked
                ? null
                : (value) => _changeSelectedValue(value, recordHistory: false),
            onChangeEnd: _channelLocked ? null : (_) => _endEdit(),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final preset in timelineCurvePresets)
                  Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: ChoiceChip(
                      key: ValueKey('keyframe_curve_${preset.id}'),
                      label: Text(preset.label),
                      selected: preset.matches(selected),
                      onSelected: _channelLocked
                          ? null
                          : (_) => _setCurvePreset(preset),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 7),
                  child: ChoiceChip(
                    key: const ValueKey('keyframe_curve_custom'),
                    label: const Text('Custom'),
                    selected:
                        selected.interpolation ==
                            TimelineKeyframeInterpolation.cubicBezier &&
                        !timelineCurvePresets.any(
                          (preset) => preset.matches(selected),
                        ),
                    onSelected: _channelLocked
                        ? null
                        : (_) => _setInterpolation(
                            TimelineKeyframeInterpolation.cubicBezier,
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Drag selected points together to change time and value. Use Box for marquee selection; tangent handles edit the primary key.',
            style: TextStyle(color: kTextSecondary, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

typedef _NumericKeyframeResolver =
    ({TimelineKeyframe? frame, String? error}) Function(
      String timeText,
      String valueText,
    );

class _NumericKeyframeDialog extends StatefulWidget {
  final String initialTimeMs;
  final String initialValue;
  final String valueLabel;
  final _NumericKeyframeResolver resolve;

  const _NumericKeyframeDialog({
    required this.initialTimeMs,
    required this.initialValue,
    required this.valueLabel,
    required this.resolve,
  });

  @override
  State<_NumericKeyframeDialog> createState() => _NumericKeyframeDialogState();
}

class _NumericKeyframeDialogState extends State<_NumericKeyframeDialog> {
  late final TextEditingController _timeController;
  late final TextEditingController _valueController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _timeController = TextEditingController(text: widget.initialTimeMs);
    _valueController = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _timeController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  void _apply() {
    final result = widget.resolve(_timeController.text, _valueController.text);
    final frame = result.frame;
    if (frame == null) {
      setState(() => _error = result.error ?? 'Enter valid numbers.');
      return;
    }
    Navigator.pop(context, frame);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit keyframe numerically'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('keyframe_numeric_time'),
              controller: _timeController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Clip-relative time (ms)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('keyframe_numeric_value'),
              controller: _valueController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: InputDecoration(
                labelText: widget.valueLabel,
                errorText: _error,
              ),
              onSubmitted: (_) => _apply(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('keyframe_numeric_apply'),
          onPressed: _apply,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _GraphButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool compact;
  final bool selected;

  const _GraphButton({
    required this.tooltip,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.compact = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: Size(0, compact ? 38 : 44),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 11 : 15,
            vertical: 0,
          ),
          backgroundColor: selected
              ? kAccent.withValues(alpha: 0.14)
              : Colors.transparent,
          foregroundColor: selected ? kAccent : null,
          side: BorderSide(color: selected ? kAccent : kBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label),
      ),
    );
  }
}

class _GraphIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const _GraphIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: 38,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.square(38),
            padding: EdgeInsets.zero,
            side: const BorderSide(color: kBorder),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            visualDensity: VisualDensity.compact,
          ),
          onPressed: onPressed,
          child: Icon(icon, size: 18),
        ),
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
  final Set<String> selectedKeyframeIds;
  final Rect? selectionRect;
  final Duration playhead;
  final double fallbackValue;
  final String Function(double value) valueFormatter;

  const _KeyframeGraphPainter({
    required this.geometry,
    required this.frames,
    required this.selectedKeyframeId,
    required this.selectedKeyframeIds,
    required this.selectionRect,
    required this.playhead,
    required this.fallbackValue,
    required this.valueFormatter,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = kBorder.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    final timeDivisions = geometry.plot.width < 260
        ? 2
        : geometry.plot.width < 380
        ? 3
        : 4;
    for (var index = 0; index <= timeDivisions; index++) {
      final x =
          geometry.plot.left + geometry.plot.width * index / timeDivisions;
      canvas.drawLine(
        Offset(x, geometry.plot.top),
        Offset(x, geometry.plot.bottom),
        gridPaint,
      );
      final timeUs =
          geometry.startUs +
          (geometry.endUs - geometry.startUs) * index / timeDivisions;
      _paintLabel(
        canvas,
        _formatTime(Duration(microseconds: timeUs.round())),
        Offset(x, geometry.plot.bottom + 7),
        center: index > 0 && index < timeDivisions,
        alignRight: index == timeDivisions,
      );
    }
    final valueDivisions = geometry.plot.height < 90
        ? 1
        : geometry.plot.height < 150
        ? 2
        : 4;
    for (var index = 0; index <= valueDivisions; index++) {
      final y =
          geometry.plot.top + geometry.plot.height * index / valueDivisions;
      canvas.drawLine(
        Offset(geometry.plot.left, y),
        Offset(geometry.plot.right, y),
        gridPaint,
      );
      final value =
          geometry.maximumValue -
          (geometry.maximumValue - geometry.minimumValue) *
              index /
              valueDivisions;
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
      final selected = selectedKeyframeIds.contains(frame.id);
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
    final marquee = selectionRect;
    if (marquee != null) {
      canvas.drawRect(
        marquee,
        Paint()
          ..color = kAccent.withValues(alpha: 0.12)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        marquee,
        Paint()
          ..color = kAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
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
        oldDelegate.selectedKeyframeIds != selectedKeyframeIds ||
        oldDelegate.selectionRect != selectionRect ||
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

String _formatTime(Duration duration) {
  final totalMs = math.max(0, duration.inMilliseconds);
  final minutes = totalMs ~/ 60000;
  final seconds = (totalMs % 60000) ~/ 1000;
  final milliseconds = totalMs % 1000;
  return '$minutes:${seconds.toString().padLeft(2, '0')}.${milliseconds.toString().padLeft(3, '0')}';
}
