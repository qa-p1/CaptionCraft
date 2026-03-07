import 'package:flutter_riverpod/flutter_riverpod.dart';

/// State for video playback in the editor.
class PlaybackState {
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool isReady;
  final Duration? pendingSeekPosition;
  final int? seekRequestId;

  const PlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.isPlaying = false,
    this.isReady = false,
    this.pendingSeekPosition,
    this.seekRequestId = 0,
  });

  double get progressPercent {
    if (duration.inMilliseconds == 0) return 0;
    return position.inMilliseconds / duration.inMilliseconds;
  }

  PlaybackState copyWith({
    Duration? position,
    Duration? duration,
    bool? isPlaying,
    bool? isReady,
    Duration? pendingSeekPosition,
    int? seekRequestId,
    bool clearPendingSeek = false,
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
    );
  }
}

class PlaybackNotifier extends StateNotifier<PlaybackState> {
  PlaybackNotifier() : super(const PlaybackState());

  void updatePosition(Duration position) {
    state = state.copyWith(position: position);
  }

  void updateDuration(Duration duration) {
    state = state.copyWith(duration: duration);
  }

  void setPlaying(bool isPlaying) {
    state = state.copyWith(isPlaying: isPlaying);
  }

  void setReady(bool isReady) {
    state = state.copyWith(isReady: isReady);
  }

  void requestSeek(Duration position) {
    final maxMs = state.duration.inMilliseconds;
    final clampedMs = position.inMilliseconds.clamp(0, maxMs).toInt();
    final target = Duration(milliseconds: clampedMs);
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

  void reset() {
    state = const PlaybackState();
  }
}

final playbackProvider = StateNotifierProvider<PlaybackNotifier, PlaybackState>(
  (ref) {
    return PlaybackNotifier();
  },
);
