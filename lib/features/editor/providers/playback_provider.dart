import 'package:flutter_riverpod/flutter_riverpod.dart';

enum PlaybackTransportCommand {
  togglePlayPause,
  pause,
  playForward,
  stepBackward,
  stepForward,
  jumpToStart,
  jumpToEnd,
}

/// State for video playback in the editor.
class PlaybackState {
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool isReady;
  final Duration? pendingSeekPosition;
  final int? seekRequestId;
  final PlaybackTransportCommand? pendingTransportCommand;
  final int transportRequestId;

  const PlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.isPlaying = false,
    this.isReady = false,
    this.pendingSeekPosition,
    this.seekRequestId = 0,
    this.pendingTransportCommand,
    this.transportRequestId = 0,
  });

  double get progressPercent {
    final durationUs = duration.inMicroseconds;
    if (durationUs <= 0) return 0;
    return (position.inMicroseconds / durationUs).clamp(0.0, 1.0).toDouble();
  }

  PlaybackState copyWith({
    Duration? position,
    Duration? duration,
    bool? isPlaying,
    bool? isReady,
    Duration? pendingSeekPosition,
    int? seekRequestId,
    PlaybackTransportCommand? pendingTransportCommand,
    int? transportRequestId,
    bool clearPendingSeek = false,
    bool clearPendingTransport = false,
  }) {
    return PlaybackState(
      position: position ?? this.position,
      duration: duration ?? this.duration,
      isPlaying: isPlaying ?? this.isPlaying,
      isReady: isReady ?? this.isReady,
      pendingSeekPosition: clearPendingSeek
          ? null
          : (pendingSeekPosition ?? this.pendingSeekPosition),
      seekRequestId: seekRequestId ?? this.seekRequestId ?? 0,
      pendingTransportCommand: clearPendingTransport
          ? null
          : (pendingTransportCommand ?? this.pendingTransportCommand),
      transportRequestId: transportRequestId ?? this.transportRequestId,
    );
  }
}

class PlaybackNotifier extends StateNotifier<PlaybackState> {
  PlaybackNotifier() : super(const PlaybackState());

  void updatePosition(Duration position) {
    final durationUs = state.duration.inMicroseconds;
    final safePosition = durationUs <= 0
        ? (position.isNegative ? Duration.zero : position)
        : Duration(
            microseconds: position.inMicroseconds.clamp(0, durationUs).toInt(),
          );
    if (state.position == safePosition) return;
    state = state.copyWith(position: safePosition);
  }

  void updateDuration(Duration duration) {
    final safeDuration = duration.isNegative ? Duration.zero : duration;
    final durationUs = safeDuration.inMicroseconds;
    final safePosition = Duration(
      microseconds: state.position.inMicroseconds.clamp(0, durationUs).toInt(),
    );
    final pending = state.pendingSeekPosition;
    final safePending = pending == null
        ? null
        : Duration(
            microseconds: pending.inMicroseconds.clamp(0, durationUs).toInt(),
          );
    if (state.duration == safeDuration &&
        state.position == safePosition &&
        state.pendingSeekPosition == safePending) {
      return;
    }
    state = state.copyWith(
      duration: safeDuration,
      position: safePosition,
      pendingSeekPosition: safePending,
    );
  }

  void setPlaying(bool isPlaying) {
    if (state.isPlaying == isPlaying) return;
    state = state.copyWith(isPlaying: isPlaying);
  }

  void setReady(bool isReady) {
    if (state.isReady == isReady) return;
    state = state.copyWith(isReady: isReady);
  }

  void requestSeek(Duration position) {
    final durationUs = state.duration.inMicroseconds;
    final maxUs = durationUs < 0 ? 0 : durationUs;
    final target = Duration(
      microseconds: position.inMicroseconds.clamp(0, maxUs).toInt(),
    );
    final nextRequestId = (state.seekRequestId ?? 0) + 1;

    state = state.copyWith(
      position: target,
      pendingSeekPosition: target,
      seekRequestId: nextRequestId,
    );
  }

  void acknowledgeSeek(int requestId) {
    if (requestId != (state.seekRequestId ?? 0)) return;
    state = state.copyWith(clearPendingSeek: true);
  }

  void requestTransport(PlaybackTransportCommand command) {
    state = state.copyWith(
      pendingTransportCommand: command,
      transportRequestId: state.transportRequestId + 1,
    );
  }

  void acknowledgeTransport(int requestId) {
    if (requestId != state.transportRequestId) return;
    state = state.copyWith(clearPendingTransport: true);
  }

  void reset() {
    state = const PlaybackState();
  }
}

final playbackProvider = StateNotifierProvider<PlaybackNotifier, PlaybackState>(
  (ref) {
    return PlaybackNotifier();
  },
);
