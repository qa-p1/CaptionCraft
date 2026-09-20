import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/services/timeline_editor_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;
  late EditorNotifier editor;
  late SubtitleNotifier subtitles;
  late TimelineEditorController commands;
  setUp(() {
    container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    editor = container.read(editorProvider.notifier);
    subtitles = container.read(subtitleProvider.notifier);
    commands = TimelineEditorController(
      editor: editor,
      subtitles: subtitles,
      playheadPosition: () => const Duration(seconds: 2),
    );
  });
  tearDown(() {
    commands.dispose();
    container.dispose();
  });
  void load(
    List<TimelineTrack> tracks, {
    List<SubtitleEntry> cues = const [],
    List<TimelineGroup> groups = const [],
    List<EditorEffectContainer> effects = const [],
  }) {
    subtitles.loadSubtitles(cues);
    editor.loadProject(
      videoPath: 'missing.mp4',
      projectId: 'edge',
      projectName: 'Edge',
      timeline: EditorTimeline(
        tracks: tracks,
        groups: groups,
        effectContainers: effects,
      ),
    );
  }

  TimelineClip video({bool freeze = false}) => TimelineClip(
    id: 'video',
    trackId: 'video-track',
    type: TimelineTrackType.video,
    label: 'Video',
    startTime: Duration.zero,
    endTime: const Duration(seconds: 4),
    sourceStartTime: const Duration(seconds: 10),
    sourceDuration: const Duration(seconds: 4),
    freezeFrame: freeze,
    freezeFrameSourceTime: freeze ? const Duration(seconds: 13) : null,
  );
  TimelineTrack track(TimelineClip clip, {bool locked = false}) =>
      TimelineTrack(
        id: clip.trackId,
        name: clip.label,
        type: clip.type,
        isLocked: locked,
        clips: [clip],
      );

  test(
    'splitting captions clips word timings, retains confidence, and undoes atomically',
    () {
      final cue = SubtitleEntry(
        id: 'cue',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 4),
        text: 'one two three',
        confidenceScore: 0.35,
        words: [
          WordTiming(
            word: 'one',
            startTime: Duration.zero,
            endTime: const Duration(seconds: 1),
          ),
          WordTiming(
            word: 'two',
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 3),
          ),
          WordTiming(
            word: 'three',
            startTime: const Duration(seconds: 3),
            endTime: const Duration(seconds: 4),
          ),
        ],
      );
      load(
        [
          track(video()),
          track(
            TimelineClip.fromSubtitleEntry(
              cue,
              trackId: 'captions',
              linkedClipId: 'video',
            ),
          ),
        ],
        cues: [cue],
      );
      expect(commands.splitClip('video', const Duration(seconds: 2)), isTrue);
      final result = container.read(subtitleProvider).entries;
      expect(result, hasLength(2));
      expect(result.first.words!.map((w) => w.word), ['one', 'two']);
      expect(result.first.words!.last.endTime, const Duration(seconds: 2));
      expect(result.last.words!.map((w) => w.word), ['two', 'three']);
      expect(result.last.words!.first.startTime, const Duration(seconds: 2));
      expect(result.map((cue) => cue.confidenceScore), everyElement(0.35));
      editor.undo();
      expect(
        container.read(subtitleProvider).entries.single.toJson(),
        cue.toJson(),
      );
      expect(
        container.read(editorProvider).timeline.tracks.first.clips,
        hasLength(1),
      );
      editor.redo();
      expect(
        container.read(subtitleProvider).entries.last.words!.last.word,
        'three',
      );
    },
  );

  test(
    'ripple delete moves markers and work area with downstream clips and undoes',
    () {
      final first = video().copyWith(endTime: const Duration(seconds: 2));
      final second = video().copyWith(
        id: 'second',
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 4),
      );
      load([
        track(first).copyWith(clips: [first, second]),
      ]);
      editor.setTimeline(
        container
            .read(editorProvider)
            .timeline
            .copyWith(
              markers: [
                TimelineMarker(
                  id: 'removed',
                  position: const Duration(seconds: 1),
                  label: 'Removed',
                ),
                TimelineMarker(
                  id: 'retained',
                  position: const Duration(seconds: 3),
                  label: 'Retained',
                ),
              ],
              workspaceSettings: const TimelineWorkspaceSettings(
                workAreaStart: Duration(seconds: 2),
                workAreaEnd: Duration(seconds: 4),
              ),
            ),
      );
      editor.selectClip(first.id);
      expect(commands.deleteSelection(ripple: true), isTrue);
      final result = container.read(editorProvider).timeline;
      expect(result.tracks.single.clips.single.startTime, Duration.zero);
      expect(result.markers.single.id, 'retained');
      expect(result.markers.single.position, const Duration(seconds: 1));
      expect(result.workspaceSettings.workAreaStart, Duration.zero);
      expect(result.workspaceSettings.workAreaEnd, const Duration(seconds: 2));
      editor.undo();
      expect(container.read(editorProvider).timeline.markers, hasLength(2));
      expect(
        container.read(editorProvider).timeline.workspaceSettings.workAreaStart,
        const Duration(seconds: 2),
      );
    },
  );

  test('both freeze-frame halves keep the same source frame', () {
    final original = video(freeze: true);
    load([track(original)]);
    expect(commands.splitClip(original.id, const Duration(seconds: 2)), isTrue);
    final halves = container.read(editorProvider).timeline.tracks.single.clips;
    expect(halves, hasLength(2));
    for (final half in halves) {
      expect(
        half.effectiveFreezeFrameSourceTime,
        original.effectiveFreezeFrameSourceTime,
      );
      expect(half.sourceStartTime, original.sourceStartTime);
      expect(half.sourceDuration, original.sourceDuration);
    }
  });

  test(
    'split preserves locked companions and rejects locked targets and tiny fragments',
    () {
      final cue = SubtitleEntry(
        id: 'cue',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 4),
        text: 'Hello',
      );
      load(
        [
          track(video()),
          track(
            TimelineClip.fromSubtitleEntry(
              cue,
              trackId: 'captions',
              linkedClipId: 'video',
            ),
            locked: true,
          ),
        ],
        cues: [cue],
      );
      expect(commands.splitClip('cue', const Duration(seconds: 2)), isFalse);
      expect(commands.splitClip('video', const Duration(seconds: 2)), isTrue);
      expect(
        container.read(subtitleProvider).entries.single.toJson(),
        cue.toJson(),
      );
      expect(
        commands.splitClip('missing', const Duration(seconds: 2)),
        isFalse,
      );
      load([track(video())]);
      expect(
        commands.splitClip('video', const Duration(milliseconds: 50)),
        isFalse,
      );
      expect(
        container.read(editorProvider).timeline.tracks.single.clips,
        hasLength(1),
      );
    },
  );

  test(
    'split carries linked group members and scoped effects into the right half',
    () {
      final source = video().copyWith(groupId: 'group');
      final audio = TimelineClip(
        id: 'audio',
        trackId: 'audio-track',
        type: TimelineTrackType.audio,
        label: 'Audio',
        startTime: source.startTime,
        endTime: source.endTime,
        sourceStartTime: source.sourceStartTime,
        sourceDuration: source.sourceDuration,
        linkedClipId: source.id,
        separatedFromClipId: source.id,
        groupId: 'group',
      );
      load(
        [track(source), track(audio)],
        groups: [
          TimelineGroup(
            id: 'group',
            name: 'Linked',
            clipIds: ['video', 'audio'],
          ),
        ],
        effects: [
          EditorEffectContainer(
            scope: EditorEffectScope.clip,
            targetId: source.id,
            label: 'Look',
            stack: EditorEffectStack(
              effects: [EditorEffect(type: EditorEffectType.vignette)],
            ),
          ),
        ],
      );
      expect(commands.splitClip('video', const Duration(seconds: 2)), isTrue);
      final timeline = container.read(editorProvider).timeline;
      expect(timeline.groups.single.clipIds, hasLength(4));
      final right = timeline.tracks.first.clips.last;
      expect(
        timeline.effectContainers.where(
          (effect) => effect.targetId == right.id,
        ),
        hasLength(1),
      );
      expect(
        timeline.effectContainers.map((effect) => effect.id).toSet(),
        hasLength(2),
      );
    },
  );

  test(
    'create and assign audio bus is one undo step and rejects stale tracks',
    () {
      load([track(video())]);
      final busId = editor.createAudioBusForTrack(
        'video-track',
        name: 'Dialogue',
      );
      expect(busId, isNotNull);
      expect(
        container.read(editorProvider).timeline.tracks.single.audioBusId,
        busId,
      );
      editor.undo();
      expect(container.read(editorProvider).timeline.audioBuses, isEmpty);
      expect(
        container.read(editorProvider).timeline.tracks.single.audioBusId,
        isNull,
      );
      editor.redo();
      expect(
        container.read(editorProvider).timeline.tracks.single.audioBusId,
        busId,
      );
      expect(editor.createAudioBusForTrack('missing'), isNull);
      expect(container.read(editorProvider).timeline.audioBuses, hasLength(1));
    },
  );

  test(
    'deleting audio bus restores routing on undo and respects locked tracks',
    () {
      load([track(video())]);
      final id = editor.createAudioBusForTrack('video-track')!;
      expect(editor.deleteAudioBus(id), isTrue);
      expect(container.read(editorProvider).timeline.audioBuses, isEmpty);
      expect(
        container.read(editorProvider).timeline.tracks.single.audioBusId,
        isNull,
      );
      editor.undo();
      expect(
        container.read(editorProvider).timeline.tracks.single.audioBusId,
        id,
      );
      final timeline = container.read(editorProvider).timeline;
      editor.setTimeline(
        timeline.copyWith(
          tracks: [timeline.tracks.single.copyWith(isLocked: true)],
        ),
      );
      expect(editor.deleteAudioBus(id), isFalse);
      expect(editor.createAudioBusForTrack('video-track'), isNull);
      expect(container.read(editorProvider).timeline.audioBuses, hasLength(1));
    },
  );
}
