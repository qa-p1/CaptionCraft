import 'package:caption_craft/features/editor/widgets/preview_playback_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('preview playback extrapolation', () {
    test('holds the published position while paused', () {
      expect(
        extrapolatePreviewPosition(
          basePosition: const Duration(milliseconds: 420),
          elapsed: const Duration(milliseconds: 80),
          duration: const Duration(seconds: 2),
          playbackSpeed: 1,
          isPlaying: false,
        ),
        const Duration(milliseconds: 420),
      );
    });

    test('advances between updates at the active playback speed', () {
      expect(
        extrapolatePreviewPosition(
          basePosition: const Duration(milliseconds: 400),
          elapsed: const Duration(milliseconds: 50),
          duration: const Duration(seconds: 2),
          playbackSpeed: 2,
          isPlaying: true,
        ),
        const Duration(milliseconds: 500),
      );
    });

    test('clamps extrapolated positions to the timeline duration', () {
      expect(
        extrapolatePreviewPosition(
          basePosition: const Duration(milliseconds: 980),
          elapsed: const Duration(milliseconds: 80),
          duration: const Duration(seconds: 1),
          playbackSpeed: 1,
          isPlaying: true,
        ),
        const Duration(seconds: 1),
      );
      expect(
        extrapolatePreviewPosition(
          basePosition: const Duration(milliseconds: -20),
          elapsed: Duration.zero,
          duration: const Duration(seconds: 1),
          playbackSpeed: 1,
          isPlaying: false,
        ),
        Duration.zero,
      );
    });

    test('shared clock advances even when three media decoders lag', () {
      final timelinePosition = extrapolatePreviewPosition(
        basePosition: const Duration(seconds: 2),
        elapsed: const Duration(milliseconds: 750),
        duration: const Duration(seconds: 10),
        playbackSpeed: 1,
        isPlaying: true,
      );

      expect(timelinePosition, const Duration(milliseconds: 2750));
      for (final decoderPosition in const [
        Duration(milliseconds: 2010),
        Duration(milliseconds: 2140),
        Duration(milliseconds: 2380),
      ]) {
        expect(
          shouldCorrectPreviewMediaDrift(
            timelineTarget: timelinePosition,
            decoderPosition: decoderPosition,
          ),
          isTrue,
        );
      }
      // A decoder close to the shared clock is allowed to keep playing. This
      // avoids a seek storm when several videos are active at once.
      expect(
        shouldCorrectPreviewMediaDrift(
          timelineTarget: timelinePosition,
          decoderPosition: const Duration(milliseconds: 2500),
        ),
        isFalse,
      );
    });
  });
}
