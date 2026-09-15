import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/screens/editor_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = TimelineClip(
    id: 'source',
    trackId: 'video',
    type: TimelineTrackType.video,
    label: 'Interview',
    assetId: 'asset',
    startTime: Duration.zero,
    endTime: const Duration(seconds: 4),
    sourceDuration: const Duration(seconds: 4),
  );
  EditorTimeline timeline({
    TimelineClip? live,
    String path = 'source.mp4',
    List<TimelineTrack> extra = const [],
  }) => EditorTimeline(
    assets: [
      EditorAssetReference(
        id: 'asset',
        type: EditorAssetType.video,
        label: 'Source',
        sourcePath: path,
      ),
    ],
    tracks: [
      TimelineTrack(
        id: 'video',
        name: 'Video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [live ?? source],
      ),
      ...extra,
    ],
  );
  final generated = [
    SubtitleEntry(
      id: 'generated',
      text: 'Hello',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
    ),
  ];
  ({EditorTimeline timeline, List<SubtitleEntry> entries}) apply(
    EditorTimeline current, {
    List<SubtitleEntry> cues = const [],
  }) => buildGeneratedCaptionUpdate(
    requestedSource: source,
    requestedMediaPath: 'source.mp4',
    currentTimeline: current,
    currentEntries: cues,
    generatedEntries: generated,
    legacyBaseVideoPath: 'source.mp4',
  );

  test(
    'late captions preserve unrelated edits and follow the current source placement',
    () {
      final manual = SubtitleEntry(
        id: 'manual',
        text: 'Keep my edit',
        startTime: const Duration(seconds: 8),
        endTime: const Duration(seconds: 9),
      );
      final moved = source.copyWith(
        startTime: const Duration(seconds: 3),
        endTime: const Duration(seconds: 7),
      );
      final manualTrack = TimelineTrack(
        id: 'manual-track',
        name: 'Manual',
        type: TimelineTrackType.subtitle,
        section: TimelineTrackSection.textSubtitle,
        clips: [
          TimelineClip.fromSubtitleEntry(manual, trackId: 'manual-track'),
        ],
      );
      final current = timeline(live: moved, extra: [manualTrack]).copyWith(
        markers: [
          TimelineMarker(
            position: const Duration(seconds: 6),
            label: 'Keep marker',
          ),
        ],
      );
      final result = apply(current, cues: [manual]);
      expect(
        result.timeline.tracks.first.clips.single.startTime,
        const Duration(seconds: 3),
      );
      expect(result.timeline.markers.single.label, 'Keep marker');
      expect(
        result.entries.singleWhere((cue) => cue.id == 'manual'),
        same(manual),
      );
      expect(
        result.entries.singleWhere((cue) => cue.id == 'generated').startTime,
        const Duration(seconds: 3),
      );
      expect(
        result.timeline.tracks
            .singleWhere((track) => track.id == 'manual-track')
            .clips
            .single
            .text,
        'Keep my edit',
      );
    },
  );

  test('late result cannot resurrect a removed source', () {
    expect(() => apply(timeline().copyWith(tracks: [])), throwsStateError);
  });

  test('late result rejects changed source windows and relinked files', () {
    expect(
      () => apply(
        timeline(
          live: source.copyWith(sourceStartTime: const Duration(seconds: 1)),
        ),
      ),
      throwsStateError,
    );
    expect(() => apply(timeline(path: 'replacement.mp4')), throwsStateError);
    expect(
      () => apply(timeline(live: source.copyWith(playbackRate: 2))),
      throwsStateError,
    );
  });

  for (final locked in [false, true]) {
    test(
      'late result preserves captions added during transcription (locked=$locked)',
      () {
        final existing = SubtitleEntry(
          id: 'existing',
          text: 'Current captions',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        );
        final track = TimelineTrack(
          id: 'captions',
          name: 'Captions',
          type: TimelineTrackType.subtitle,
          section: TimelineTrackSection.textSubtitle,
          isLocked: locked,
          clips: [
            TimelineClip.fromSubtitleEntry(
              existing,
              trackId: 'captions',
              linkedClipId: source.id,
            ),
          ],
        );
        final current = timeline(extra: [track]);
        expect(() => apply(current, cues: [existing]), throwsStateError);
        expect(current.tracks.last.clips.single.text, 'Current captions');
      },
    );
  }
}
