import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/services/timeline_editor_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'paste is disabled when multiple copied lanes resolve to one overlapping lane',
    () {
      TimelineClip clip(String id, String trackId) => TimelineClip(
        id: id,
        trackId: trackId,
        type: TimelineTrackType.audio,
        label: id,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
        sourceDuration: const Duration(seconds: 2),
      );

      final first = clip('first', 'audio-a');
      final second = clip('second', 'audio-b');
      TimelineTrack audioTrack(String id, TimelineClip value) => TimelineTrack(
        id: id,
        name: id,
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        clips: [value],
      );
      final sourceTimeline = EditorTimeline(
        tracks: [audioTrack('audio-a', first), audioTrack('audio-b', second)],
      );
      final container = ProviderContainer(
        overrides: [currentUserProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      final editor = container.read(editorProvider.notifier);
      final subtitles = container.read(subtitleProvider.notifier);
      editor.loadProject(
        videoPath: 'missing.mp4',
        projectId: 'clip-paste-overlap',
        projectName: 'Clip paste overlap',
        timeline: sourceTimeline,
      );
      editor.selectClipIds([first.id, second.id]);
      final controller = TimelineEditorController(
        editor: editor,
        subtitles: subtitles,
        playheadPosition: () => const Duration(seconds: 5),
      );
      addTearDown(controller.dispose);

      expect(controller.copySelection(), isTrue);
      // The original source lanes disappear, leaving one fallback destination.
      // Both copied clips start at the same relative time and cannot share it.
      editor.setTimeline(
        sourceTimeline.copyWith(
          tracks: [
            TimelineTrack(
              id: 'fallback-audio',
              name: 'Audio',
              type: TimelineTrackType.audio,
              section: TimelineTrackSection.audio,
            ),
          ],
        ),
      );

      expect(controller.canExecute(TimelineEditorCommand.paste), isFalse);
      expect(controller.pasteAtPlayhead(), isFalse);
      expect(
        container
            .read(editorProvider)
            .timeline
            .tracks
            .single
            .clips,
        isEmpty,
      );
    },
  );

}
