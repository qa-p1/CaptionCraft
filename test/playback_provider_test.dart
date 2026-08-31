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
}
