import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/services/timeline_editor_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('destructive commands reject a locked linked companion', () {
    final video = TimelineClip(
      id: 'video',
      trackId: 'video_track',
      type: TimelineTrackType.video,
      label: 'Video',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 4),
      sourceDuration: const Duration(seconds: 4),
      assetId: 'asset',
    );
    final audio = TimelineClip(
      id: 'audio',
      trackId: 'audio_track',
      type: TimelineTrackType.audio,
      label: 'Separated audio',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 4),
      sourceDuration: const Duration(seconds: 4),
      assetId: 'asset',
      linkedClipId: video.id,
      separatedFromClipId: video.id,
    );
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    final editor = container.read(editorProvider.notifier);
    final subtitles = container.read(subtitleProvider.notifier);
    editor.loadProject(
      videoPath: 'missing.mp4',
      projectId: 'locked-companion',
      projectName: 'Locked companion',
      timeline: EditorTimeline(
        tracks: [
          TimelineTrack(
            id: video.trackId,
            name: 'Video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [video],
          ),
          TimelineTrack(
            id: audio.trackId,
            name: 'Audio',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
            isLocked: true,
            clips: [audio],
          ),
        ],
      ),
    );
    editor.selectClip(video.id);
    final controller = TimelineEditorController(
      editor: editor,
      subtitles: subtitles,
    );
    addTearDown(controller.dispose);

    expect(controller.canExecute(TimelineEditorCommand.delete), isFalse);
    expect(controller.deleteSelection(), isFalse);
    expect(
      container
          .read(editorProvider)
          .timeline
          .tracks
          .expand((track) => track.clips)
          .map((clip) => clip.id),
      containsAll(<String>['video', 'audio']),
    );
  });

  test(
    'subtitle paste allocates fresh ids and delete removes both mirrors',
    () {
      final cue = SubtitleEntry(
        id: 'cue-original',
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 3),
        text: 'Hello',
        words: [
          WordTiming(
            word: 'Hello',
            startTime: const Duration(milliseconds: 2100),
            endTime: const Duration(milliseconds: 2800),
          ),
        ],
      );
      final subtitleTrack = TimelineTrack(
        id: 'subtitles',
        name: 'Subtitles',
        type: TimelineTrackType.subtitle,
        section: TimelineTrackSection.textSubtitle,
      );
      final container = ProviderContainer(
        overrides: [currentUserProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      final editor = container.read(editorProvider.notifier);
      final subtitles = container.read(subtitleProvider.notifier);
      subtitles.loadSubtitles([cue]);
      editor.loadProject(
        videoPath: 'missing.mp4',
        projectId: 'subtitle-paste',
        projectName: 'Subtitle paste',
        timeline: EditorTimeline(tracks: [subtitleTrack]),
      );
      var playhead = const Duration(seconds: 10);
      final controller = TimelineEditorController(
        editor: editor,
        subtitles: subtitles,
        playheadPosition: () => playhead,
      );
      addTearDown(controller.dispose);

      subtitles.selectEntry(cue.id);
      expect(controller.copySelection(), isTrue);
      expect(controller.pasteAtPlayhead(), isTrue);

      final entries = container.read(subtitleProvider).entries;
      expect(entries, hasLength(2));
      final pasted = entries.singleWhere((entry) => entry.id != cue.id);
      expect(pasted.id, isNot(cue.id));
      expect(pasted.startTime, const Duration(seconds: 10));
      expect(pasted.endTime, const Duration(seconds: 11));
      expect(
        pasted.words!.single.startTime,
        const Duration(milliseconds: 10100),
      );
      expect(pasted.words!.single.endTime, const Duration(milliseconds: 10800));
      final pastedClip = container
          .read(editorProvider)
          .timeline
          .tracks
          .single
          .clips
          .singleWhere((clip) => clip.id == pasted.id);
      expect(pastedClip.id, pasted.id);

      editor.clearClipSelection();
      subtitles.selectEntry(pasted.id);
      expect(controller.deleteSelection(), isTrue);
      expect(
        container.read(subtitleProvider).entries.map((entry) => entry.id),
        [cue.id],
      );
      expect(
        container
            .read(editorProvider)
            .timeline
            .tracks
            .single
            .clips
            .map((clip) => clip.id),
        [cue.id],
      );
      playhead = Duration.zero;
    },
  );

  test('pasted linked companions point at cloned relationship ids', () {
    final video = TimelineClip(
      id: 'video',
      trackId: 'video_track',
      type: TimelineTrackType.video,
      label: 'Video',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
      sourceDuration: const Duration(seconds: 2),
      assetId: 'asset',
    );
    final audio = TimelineClip(
      id: 'audio',
      trackId: 'audio_track',
      type: TimelineTrackType.audio,
      label: 'Audio',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
      sourceDuration: const Duration(seconds: 2),
      assetId: 'asset',
      linkedClipId: video.id,
      separatedFromClipId: video.id,
    );
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    final editor = container.read(editorProvider.notifier);
    final subtitles = container.read(subtitleProvider.notifier);
    editor.loadProject(
      videoPath: 'missing.mp4',
      projectId: 'linked-paste',
      projectName: 'Linked paste',
      timeline: EditorTimeline(
        tracks: [
          TimelineTrack(
            id: video.trackId,
            name: 'Video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [video],
          ),
          TimelineTrack(
            id: audio.trackId,
            name: 'Audio',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
            clips: [audio],
          ),
        ],
      ),
    );
    var playhead = const Duration(seconds: 5);
    editor.selectClip(video.id);
    final controller = TimelineEditorController(
      editor: editor,
      subtitles: subtitles,
      playheadPosition: () => playhead,
    );
    addTearDown(controller.dispose);

    expect(controller.copySelection(), isTrue);
    expect(controller.pasteAtPlayhead(), isTrue);
    final clips = container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .toList();
    final clonedVideo = clips.singleWhere(
      (clip) => clip.type == TimelineTrackType.video && clip.id != video.id,
    );
    final clonedAudio = clips.singleWhere(
      (clip) => clip.type == TimelineTrackType.audio && clip.id != audio.id,
    );
    expect(clonedAudio.linkedClipId, clonedVideo.id);
    expect(clonedAudio.separatedFromClipId, clonedVideo.id);
    expect(clonedAudio.linkedClipId, isNot(video.id));
    playhead = Duration.zero;
  });

  test('split command delegates to the workspace canonical operation', () {
    final clip = TimelineClip(
      id: 'split-me',
      trackId: 'video',
      type: TimelineTrackType.video,
      label: 'Video',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 4),
      sourceDuration: const Duration(seconds: 4),
    );
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    final editor = container.read(editorProvider.notifier);
    final subtitles = container.read(subtitleProvider.notifier);
    editor.loadProject(
      videoPath: 'missing.mp4',
      projectId: 'canonical-split',
      projectName: 'Canonical split',
      timeline: EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'video',
            name: 'Video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [clip],
          ),
        ],
      ),
    );
    editor.selectClip(clip.id);
    var callbackClipId = '';
    Duration? callbackPosition;
    final controller = TimelineEditorController(
      editor: editor,
      subtitles: subtitles,
      playheadPosition: () => const Duration(seconds: 2),
      splitClipAtPlayhead: (selected, position) {
        callbackClipId = selected.id;
        callbackPosition = position;
        return true;
      },
    );
    addTearDown(controller.dispose);

    expect(controller.splitSelected(), isTrue);
    expect(callbackClipId, clip.id);
    expect(callbackPosition, const Duration(seconds: 2));
  });
}
