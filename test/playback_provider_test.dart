import 'package:caption_craft/features/editor/providers/playback_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transport commands are monotonic and acknowledge only the latest', () {
    final notifier = PlaybackNotifier();

    notifier.requestTransport(PlaybackTransportCommand.stepForward);
    final firstId = notifier.state.transportRequestId;
    notifier.requestTransport(PlaybackTransportCommand.pause);
    final secondId = notifier.state.transportRequestId;

    expect(secondId, firstId + 1);
    expect(
      notifier.state.pendingTransportCommand,
      PlaybackTransportCommand.pause,
    );

    notifier.acknowledgeTransport(firstId);
    expect(
      notifier.state.pendingTransportCommand,
      PlaybackTransportCommand.pause,
    );

    notifier.acknowledgeTransport(secondId);
    expect(notifier.state.pendingTransportCommand, isNull);
  });

  test('seek requests remain independent from transport requests', () {
    final notifier = PlaybackNotifier();
    notifier.updateDuration(const Duration(seconds: 10));
    notifier.requestSeek(const Duration(seconds: 4));
    notifier.requestTransport(PlaybackTransportCommand.togglePlayPause);

    expect(notifier.state.pendingSeekPosition, const Duration(seconds: 4));
    expect(
      notifier.state.pendingTransportCommand,
      PlaybackTransportCommand.togglePlayPause,
    );
  });

  test('duration changes clamp position and pending seeks to valid bounds', () {
    final notifier = PlaybackNotifier();
    notifier.updateDuration(const Duration(seconds: 10));
    notifier.updatePosition(const Duration(seconds: 9, milliseconds: 750));
    notifier.requestSeek(const Duration(seconds: 9, milliseconds: 750));

    notifier.updateDuration(const Duration(seconds: 4));

    expect(notifier.state.position, const Duration(seconds: 4));
    expect(notifier.state.pendingSeekPosition, const Duration(seconds: 4));
    expect(notifier.state.progressPercent, 1);
  });

  test('invalid decoder positions cannot produce invalid progress', () {
    final notifier = PlaybackNotifier();
    notifier.updateDuration(const Duration(seconds: 2));
    notifier.updatePosition(const Duration(seconds: 3));
    expect(notifier.state.position, const Duration(seconds: 2));
    expect(notifier.state.progressPercent, 1);

    notifier.updatePosition(const Duration(milliseconds: -1));
    expect(notifier.state.position, Duration.zero);
    expect(notifier.state.progressPercent, 0);

    notifier.updateDuration(const Duration(milliseconds: -1));
    expect(notifier.state.duration, Duration.zero);
    expect(notifier.state.progressPercent, 0);
  });

  test('seeks retain microsecond precision when the timeline has it', () {
    final notifier = PlaybackNotifier();
    notifier.updateDuration(const Duration(seconds: 1));
    notifier.requestSeek(const Duration(microseconds: 123456));

    expect(
      notifier.state.pendingSeekPosition,
      const Duration(microseconds: 123456),
    );
    expect(notifier.state.position, const Duration(microseconds: 123456));
  });
}
