import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/timeline_models.dart';

/// High-level editor state (current project info, video path, etc.)
class EditorState {
  final String? videoPath;
  final String? projectId;
  final String? projectName;
  final bool isProcessing;
  final String? waveformPath;
  final EditorTimeline timeline;
  final EditorBottomPanel activePanel;
  final String? selectedTrackId;
  final String? selectedClipId;
  final bool isSnappingEnabled;

  const EditorState({
    this.videoPath,
    this.projectId,
    this.projectName,
    this.isProcessing = false,
    this.waveformPath,
    this.timeline = const EditorTimeline(),
    this.activePanel = EditorBottomPanel.timeline,
    this.selectedTrackId,
    this.selectedClipId,
    this.isSnappingEnabled = true,
  });

  EditorState copyWith({
    String? videoPath,
    String? projectId,
    String? projectName,
    bool? isProcessing,
    String? waveformPath,
    EditorTimeline? timeline,
    EditorBottomPanel? activePanel,
    String? selectedTrackId,
    String? selectedClipId,
    bool? isSnappingEnabled,
    bool clearTrackSelection = false,
    bool clearClipSelection = false,
  }) {
    return EditorState(
      videoPath: videoPath ?? this.videoPath,
      projectId: projectId ?? this.projectId,
      projectName: projectName ?? this.projectName,
      isProcessing: isProcessing ?? this.isProcessing,
      waveformPath: waveformPath ?? this.waveformPath,
      timeline: timeline ?? this.timeline,
      activePanel: activePanel ?? this.activePanel,
      selectedTrackId: clearTrackSelection
          ? null
          : (selectedTrackId ?? this.selectedTrackId),
      selectedClipId: clearClipSelection
          ? null
          : (selectedClipId ?? this.selectedClipId),
      isSnappingEnabled: isSnappingEnabled ?? this.isSnappingEnabled,
    );
  }
}

enum EditorBottomPanel {
  timeline,
  text,
  media,
  audio,
  stickers,
  transitions,
  style,
}

class EditorNotifier extends StateNotifier<EditorState> {
  EditorNotifier() : super(const EditorState());

  void loadProject({
    required String videoPath,
    required String projectId,
    required String projectName,
    EditorTimeline timeline = const EditorTimeline(),
  }) {
    state = state.copyWith(
      videoPath: videoPath,
      projectId: projectId,
      projectName: projectName,
      timeline: timeline,
    );
  }

  void setProcessing(bool processing) {
    state = state.copyWith(isProcessing: processing);
  }

  void setWaveformPath(String path) {
    state = state.copyWith(waveformPath: path);
  }

  void setTimeline(EditorTimeline timeline) {
    state = state.copyWith(timeline: timeline);
  }

  void setActivePanel(EditorBottomPanel panel) {
    state = state.copyWith(activePanel: panel);
  }

  void selectTrack(String? trackId) {
    state = state.copyWith(
      selectedTrackId: trackId,
      clearTrackSelection: trackId == null,
    );
  }

  void selectClip(String? clipId) {
    state = state.copyWith(
      selectedClipId: clipId,
      clearClipSelection: clipId == null,
    );
  }

  void setSnappingEnabled(bool enabled) {
    state = state.copyWith(isSnappingEnabled: enabled);
  }

  void reset() {
    state = const EditorState();
  }
}

final editorProvider = StateNotifierProvider<EditorNotifier, EditorState>((
  ref,
) {
  return EditorNotifier();
});
