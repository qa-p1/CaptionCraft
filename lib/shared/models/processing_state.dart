/// Represents the current stage and progress of audio/video processing.
class ProcessingProgress {
  final ProcessingStage stage;
  final double progress; // 0.0 – 1.0
  final String message;
  final int? currentChunk;
  final int? totalChunks;

  const ProcessingProgress({
    required this.stage,
    required this.progress,
    required this.message,
    this.currentChunk,
    this.totalChunks,
  });

  factory ProcessingProgress.initial() {
    return const ProcessingProgress(
      stage: ProcessingStage.idle,
      progress: 0,
      message: 'Preparing...',
    );
  }
}

enum ProcessingStage {
  idle,
  extractingAudio,
  compressing,
  transcribing,
  assemblingSubtitles,
  done,
  error,
}
