import 'dart:collection';
import 'dart:math' as math;

enum PreviewDecoderKind {
  baseVideo,
  preparedVideo,
  overlayVideo,
  timelineAudio,
}

class PreviewDecoderTelemetry {
  final String id;
  final String label;
  final PreviewDecoderKind kind;
  final bool initialized;
  final bool buffering;
  final bool audible;
  final bool playing;
  final bool warm;
  final Duration drift;
  final DateTime sampledAt;

  const PreviewDecoderTelemetry({
    required this.id,
    required this.label,
    required this.kind,
    required this.initialized,
    required this.buffering,
    required this.audible,
    required this.playing,
    required this.warm,
    required this.drift,
    required this.sampledAt,
  });
}

class PreviewPerformanceSnapshot {
  final int decoderCount;
  final int videoDecoderCount;
  final int audioDecoderCount;
  final int warmDecoderCount;
  final int audibleDecoderCount;
  final int bufferingDecoderCount;
  final int bufferingEventCount;
  final int hardSeekCount;
  final int missedTickEstimate;
  final Duration maximumAbsoluteDrift;
  final Duration averageTickInterval;
  final Duration peakTickInterval;

  const PreviewPerformanceSnapshot({
    required this.decoderCount,
    required this.videoDecoderCount,
    required this.audioDecoderCount,
    required this.warmDecoderCount,
    required this.audibleDecoderCount,
    required this.bufferingDecoderCount,
    required this.bufferingEventCount,
    required this.hardSeekCount,
    required this.missedTickEstimate,
    required this.maximumAbsoluteDrift,
    required this.averageTickInterval,
    required this.peakTickInterval,
  });
}

/// Low-overhead preview telemetry kept entirely outside persisted projects.
///
/// This reports requested decoder state and composition-ticker starvation. It
/// deliberately calls the latter "missed ticks", not dropped rendered frames:
/// platform players do not expose a reliable cross-platform rendered-frame
/// counter through `video_player`.
class PreviewPerformanceMonitor {
  static const targetTickInterval = Duration(milliseconds: 33);
  static const _maximumTickSamples = 180;

  final Map<String, PreviewDecoderTelemetry> _decoders = {};
  final ListQueue<int> _tickIntervalsUs = ListQueue<int>();
  DateTime? _lastTickAt;
  int _missedTickEstimate = 0;
  int _hardSeekCount = 0;
  int _bufferingEventCount = 0;

  bool _enabled;

  PreviewPerformanceMonitor({bool enabled = true}) : _enabled = enabled;

  bool get isEnabled => _enabled;

  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    clear();
  }

  void beginTickSession() {
    if (!_enabled) return;
    _lastTickAt = null;
  }

  void recordTick(DateTime sampledAt) {
    if (!_enabled) return;
    final previous = _lastTickAt;
    _lastTickAt = sampledAt;
    if (previous == null) return;
    final intervalUs = sampledAt.difference(previous).inMicroseconds;
    if (intervalUs <= 0) return;
    _tickIntervalsUs.addLast(intervalUs);
    while (_tickIntervalsUs.length > _maximumTickSamples) {
      _tickIntervalsUs.removeFirst();
    }
    final expectedUs = targetTickInterval.inMicroseconds;
    if (intervalUs > (expectedUs * 1.5).round()) {
      _missedTickEstimate += math.max(1, (intervalUs / expectedUs).round() - 1);
    }
  }

  void updateDecoder({
    required String id,
    required String label,
    required PreviewDecoderKind kind,
    required bool initialized,
    required bool buffering,
    required bool audible,
    required bool playing,
    required bool warm,
    required Duration drift,
    DateTime? sampledAt,
  }) {
    if (!_enabled) return;
    final previous = _decoders[id];
    if (buffering && previous?.buffering != true) {
      _bufferingEventCount++;
    }
    _decoders[id] = PreviewDecoderTelemetry(
      id: id,
      label: label,
      kind: kind,
      initialized: initialized,
      buffering: buffering,
      audible: audible,
      playing: playing,
      warm: warm,
      drift: drift,
      sampledAt: sampledAt ?? DateTime.now(),
    );
  }

  void removeDecoder(String id) {
    _decoders.remove(id);
  }

  void recordHardSeek() {
    if (!_enabled) return;
    _hardSeekCount++;
  }

  PreviewPerformanceSnapshot snapshot() {
    final initialized = _decoders.values
        .where((decoder) => decoder.initialized)
        .toList(growable: false);
    var maximumDriftUs = 0;
    for (final decoder in initialized) {
      maximumDriftUs = math.max(
        maximumDriftUs,
        decoder.drift.abs().inMicroseconds,
      );
    }
    var tickTotalUs = 0;
    var peakTickUs = 0;
    for (final intervalUs in _tickIntervalsUs) {
      tickTotalUs += intervalUs;
      peakTickUs = math.max(peakTickUs, intervalUs);
    }
    final averageTickUs = _tickIntervalsUs.isEmpty
        ? 0
        : (tickTotalUs / _tickIntervalsUs.length).round();
    return PreviewPerformanceSnapshot(
      decoderCount: initialized.length,
      videoDecoderCount: initialized
          .where((decoder) => decoder.kind != PreviewDecoderKind.timelineAudio)
          .length,
      audioDecoderCount: initialized
          .where((decoder) => decoder.kind == PreviewDecoderKind.timelineAudio)
          .length,
      warmDecoderCount: initialized.where((decoder) => decoder.warm).length,
      audibleDecoderCount: initialized
          .where((decoder) => decoder.audible)
          .length,
      bufferingDecoderCount: initialized
          .where((decoder) => decoder.buffering)
          .length,
      bufferingEventCount: _bufferingEventCount,
      hardSeekCount: _hardSeekCount,
      missedTickEstimate: _missedTickEstimate,
      maximumAbsoluteDrift: Duration(microseconds: maximumDriftUs),
      averageTickInterval: Duration(microseconds: averageTickUs),
      peakTickInterval: Duration(microseconds: peakTickUs),
    );
  }

  void resetCounters() {
    _tickIntervalsUs.clear();
    _lastTickAt = null;
    _missedTickEstimate = 0;
    _hardSeekCount = 0;
    _bufferingEventCount = 0;
  }

  void clear() {
    _decoders.clear();
    resetCounters();
  }
}
