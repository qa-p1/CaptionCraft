import 'package:caption_craft/features/editor/widgets/preview_performance_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monitor counts decoder pressure, buffering transitions, and drift', () {
    final monitor = PreviewPerformanceMonitor();
    final sampledAt = DateTime.utc(2026, 8, 26);

    monitor.updateDecoder(
      id: 'base',
      label: 'Base',
      kind: PreviewDecoderKind.baseVideo,
      initialized: true,
      buffering: false,
      audible: true,
      playing: true,
      warm: false,
      drift: const Duration(milliseconds: -42),
      sampledAt: sampledAt,
    );
    monitor.updateDecoder(
      id: 'audio:music',
      label: 'Music',
      kind: PreviewDecoderKind.timelineAudio,
      initialized: true,
      buffering: true,
      audible: false,
      playing: false,
      warm: true,
      drift: const Duration(milliseconds: 125),
      sampledAt: sampledAt,
    );
    // Re-reporting the same buffering state is not a second event.
    monitor.updateDecoder(
      id: 'audio:music',
      label: 'Music',
      kind: PreviewDecoderKind.timelineAudio,
      initialized: true,
      buffering: true,
      audible: false,
      playing: false,
      warm: true,
      drift: const Duration(milliseconds: 125),
      sampledAt: sampledAt,
    );
    monitor.recordHardSeek();

    final snapshot = monitor.snapshot();
    expect(snapshot.decoderCount, 2);
    expect(snapshot.videoDecoderCount, 1);
    expect(snapshot.audioDecoderCount, 1);
    expect(snapshot.warmDecoderCount, 1);
    expect(snapshot.audibleDecoderCount, 1);
    expect(snapshot.bufferingDecoderCount, 1);
    expect(snapshot.bufferingEventCount, 1);
    expect(snapshot.hardSeekCount, 1);
    expect(snapshot.maximumAbsoluteDrift, const Duration(milliseconds: 125));

    monitor.removeDecoder('audio:music');
    expect(monitor.snapshot().decoderCount, 1);
  });

  test(
    'monitor estimates missed composition ticks without calling them frames',
    () {
      final monitor = PreviewPerformanceMonitor();
      final start = DateTime.utc(2026, 8, 26);
      monitor.recordTick(start);
      monitor.recordTick(start.add(const Duration(milliseconds: 33)));
      monitor.recordTick(start.add(const Duration(milliseconds: 66)));
      monitor.recordTick(start.add(const Duration(milliseconds: 165)));

      final snapshot = monitor.snapshot();
      expect(snapshot.averageTickInterval.inMilliseconds, 55);
      expect(snapshot.peakTickInterval, const Duration(milliseconds: 99));
      expect(snapshot.missedTickEstimate, 2);

      monitor.resetCounters();
      expect(monitor.snapshot().missedTickEstimate, 0);
      expect(monitor.snapshot().averageTickInterval, Duration.zero);
    },
  );
}
