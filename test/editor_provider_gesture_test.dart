import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('timeline gesture defers preview revision until commit', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(editorProvider.notifier);
    const original = EditorTimeline();
    notifier.loadProject(
      videoPath: 'source.mp4',
      projectId: 'project',
      projectName: 'Project',
      timeline: original,
    );

    notifier.beginTimelineGestureEdit();
    notifier.setTimeline(
      original.copyWith(canvasSettings: const CanvasSettings(showGrid: true)),
      recordHistory: false,
    );

    expect(container.read(editorProvider).editRevision, 0);
    notifier.endTimelineGestureEdit();
    expect(container.read(editorProvider).editRevision, 1);
    expect(container.read(editorProvider).canUndo, isTrue);
    notifier.undo();
    expect(
      container.read(editorProvider).timeline.canvasSettings.showGrid,
      isFalse,
    );
  });

  test('a gesture with no timeline change does not create undo history', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(editorProvider.notifier);
    notifier.loadProject(
      videoPath: 'source.mp4',
      projectId: 'project',
      projectName: 'Project',
    );

    notifier.beginTimelineGestureEdit();
    notifier.endTimelineGestureEdit();

    expect(container.read(editorProvider).canUndo, isFalse);
    expect(container.read(editorProvider).editRevision, 0);
  });

  test('selecting another track clears an unrelated clip selection', () {
    final firstClip = TimelineClip(
      id: 'first_clip',
      trackId: 'first_track',
      type: TimelineTrackType.text,
      label: 'Text',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
    );
    final timeline = EditorTimeline(
      tracks: [
        TimelineTrack(
          id: 'first_track',
          name: 'Text',
          type: TimelineTrackType.text,
          section: TimelineTrackSection.textSubtitle,
          clips: [firstClip],
        ),
        TimelineTrack(
          id: 'audio_track',
          name: 'Audio',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
        ),
      ],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(editorProvider.notifier);
    notifier.loadProject(
      videoPath: 'source.mp4',
      projectId: 'project',
      projectName: 'Project',
      timeline: timeline,
    );
    notifier.selectTrack('first_track');
    notifier.selectClip(firstClip.id);
    container.read(subtitleProvider.notifier).selectEntry('stale-subtitle');

    notifier.selectTrack('audio_track');

    expect(container.read(editorProvider).selectedTrackId, 'audio_track');
    expect(container.read(editorProvider).selectedClipId, isNull);
    expect(container.read(subtitleProvider).selectedEntryId, isNull);
  });

  test('caption generation commits timeline and entries as one undo step', () {
    final oldEntry = SubtitleEntry(
      id: 'old-caption',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
      text: 'Old',
    );
    final newEntry = SubtitleEntry(
      id: 'new-caption',
      startTime: const Duration(seconds: 1),
      endTime: const Duration(seconds: 2),
      text: 'New',
    );
    TimelineTrack subtitleTrack(SubtitleEntry entry) => TimelineTrack(
      id: 'subtitles',
      name: 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      clips: [TimelineClip.fromSubtitleEntry(entry, trackId: 'subtitles')],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(subtitleProvider.notifier)
        .initializeFromProject(
          entries: [oldEntry],
          globalStyle: const SubtitleStyleModel(),
        );
    final notifier = container.read(editorProvider.notifier);
    notifier.loadProject(
      videoPath: 'source.mp4',
      projectId: 'project',
      projectName: 'Project',
      timeline: EditorTimeline(tracks: [subtitleTrack(oldEntry)]),
    );

    notifier.replaceTimelineAndSubtitleEntries(
      timeline: EditorTimeline(tracks: [subtitleTrack(newEntry)]),
      entries: [newEntry],
    );
    expect(container.read(subtitleProvider).entries.single.id, 'new-caption');
    expect(
      container.read(editorProvider).timeline.subtitleEntries.single.id,
      'new-caption',
    );

    notifier.undo();
    expect(container.read(subtitleProvider).entries.single.id, 'old-caption');
    expect(
      container.read(editorProvider).timeline.subtitleEntries.single.id,
      'old-caption',
    );
  });

  test('caption batch edits respect a locked subtitle lane', () {
    final entry = SubtitleEntry(
      id: 'locked-caption',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
      text: 'Locked',
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(subtitleProvider.notifier)
        .initializeFromProject(
          entries: [entry],
          globalStyle: const SubtitleStyleModel(),
        );
    final notifier = container.read(editorProvider.notifier);
    notifier.loadProject(
      videoPath: 'source.mp4',
      projectId: 'project',
      projectName: 'Project',
      timeline: EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'subtitles',
            name: 'Subtitles',
            type: TimelineTrackType.subtitle,
            section: TimelineTrackSection.textSubtitle,
            isLocked: true,
            clips: [
              TimelineClip.fromSubtitleEntry(entry, trackId: 'subtitles'),
            ],
          ),
        ],
      ),
    );

    final applied = notifier.replaceSubtitleEntries([
      entry.copyWith(text: 'Changed'),
    ]);

    expect(applied, isFalse);
    expect(container.read(subtitleProvider).entries.single.text, 'Locked');
    expect(container.read(editorProvider).canUndo, isFalse);
  });

  test('equivalent timeline caption sync is a no-op', () {
    final entry = SubtitleEntry(
      id: 'caption',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
      text: 'Caption',
      styleOverride: const SubtitleStyleModel(fontSize: 18),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(subtitleProvider.notifier);
    notifier.initializeFromProject(
      entries: [entry],
      globalStyle: const SubtitleStyleModel(),
    );
    final before = container.read(subtitleProvider);

    notifier.syncFromTimeline([entry.copyWith()]);

    expect(container.read(subtitleProvider), same(before));
  });

  test('subtitle-only edits stay canonical through later timeline edits', () {
    final entry = SubtitleEntry(
      id: 'caption',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
      text: 'Caption',
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(subtitleProvider.notifier)
        .initializeFromProject(
          entries: [entry],
          globalStyle: const SubtitleStyleModel(),
        );
    final editorNotifier = container.read(editorProvider.notifier);
    editorNotifier.loadProject(
      videoPath: 'source.mp4',
      projectId: 'project',
      projectName: 'Project',
      timeline: EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'subtitles',
            name: 'Subtitles',
            type: TimelineTrackType.subtitle,
            section: TimelineTrackSection.textSubtitle,
            clips: [
              TimelineClip.fromSubtitleEntry(entry, trackId: 'subtitles'),
            ],
          ),
        ],
      ),
    );

    final subtitleNotifier = container.read(subtitleProvider.notifier);
    subtitleNotifier.duplicateEntry(entry.id);
    final duplicatedId = container.read(subtitleProvider).selectedEntryId;
    expect(duplicatedId, isNotNull);
    expect(container.read(editorProvider).selectedClipId, duplicatedId);
    expect(container.read(editorProvider).selectedTrackId, 'subtitles');
    expect(
      container.read(editorProvider).timeline.subtitleEntries,
      hasLength(2),
    );

    editorNotifier.setTimeline(
      container
          .read(editorProvider)
          .timeline
          .copyWith(
            markers: [
              TimelineMarker(
                position: const Duration(milliseconds: 500),
                label: 'Beat',
              ),
            ],
          ),
    );

    expect(container.read(subtitleProvider).entries, hasLength(2));
    expect(
      container.read(editorProvider).timeline.subtitleEntries,
      hasLength(2),
    );
    expect(
      editorNotifier.latestUndoSequence,
      greaterThan(subtitleNotifier.latestUndoSequence!),
    );

    editorNotifier.undo();
    expect(container.read(subtitleProvider).entries, hasLength(2));
    expect(
      container.read(editorProvider).timeline.subtitleEntries,
      hasLength(2),
    );
    expect(container.read(editorProvider).timeline.markers, isEmpty);
  });

  test('a new subtitle edit invalidates editor redo history', () {
    final entry = SubtitleEntry(
      id: 'caption',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
      text: 'Before',
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(subtitleProvider.notifier)
        .initializeFromProject(
          entries: [entry],
          globalStyle: const SubtitleStyleModel(),
        );
    final editorNotifier = container.read(editorProvider.notifier);
    editorNotifier.loadProject(
      videoPath: 'source.mp4',
      projectId: 'project',
      projectName: 'Project',
      timeline: const EditorTimeline(),
    );
    editorNotifier.setTimeline(
      const EditorTimeline(
        canvasSettings: CanvasSettings(showGrid: true),
      ),
    );
    editorNotifier.undo();
    expect(container.read(editorProvider).canRedo, isTrue);

    container.read(subtitleProvider.notifier).updateText(entry.id, 'After');

    expect(editorNotifier.canRedo, isFalse);
    expect(container.read(editorProvider).canRedo, isFalse);
  });
}
