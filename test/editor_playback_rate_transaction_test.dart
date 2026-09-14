import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/screens/editor_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final video = TimelineClip(
    id: 'video',
    trackId: 'base',
    type: TimelineTrackType.video,
    label: 'Video',
    startTime: Duration.zero,
    endTime: const Duration(seconds: 4),
    sourceDuration: const Duration(seconds: 4),
  );
  EditorTimeline timeline(List<TimelineTrack> extra) => EditorTimeline(
    tracks: [
      TimelineTrack(
        id: 'base',
        name: 'Video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [video],
      ),
      ...extra,
    ],
    markers: [
      TimelineMarker(position: const Duration(seconds: 6), label: 'Later'),
    ],
    workspaceSettings: const TimelineWorkspaceSettings(
      workAreaStart: Duration(seconds: 4),
      workAreaEnd: Duration(seconds: 8),
    ),
  );
  TimelineClip caption({int start = 1, int end = 2}) => TimelineClip(
    id: 'caption',
    trackId: 'captions',
    type: TimelineTrackType.subtitle,
    label: 'Caption',
    text: 'Caption',
    linkedClipId: video.id,
    startTime: Duration(seconds: start),
    endTime: Duration(seconds: end),
  );
  TimelineTrack captionTrack(TimelineClip cue, {bool locked = false}) =>
      TimelineTrack(
        id: 'captions',
        name: 'Captions',
        type: TimelineTrackType.subtitle,
        isLocked: locked,
        clips: [cue],
      );
  EditorTimeline change(EditorTimeline value) => buildClipPlaybackRateUpdate(
    timeline: value,
    clipId: video.id,
    playbackRate: 2,
  );

  test('speed rejects locked linked captions without changing the source', () {
    final original = timeline([captionTrack(caption(), locked: true)]);
    expect(() => change(original), throwsStateError);
    expect(original.tracks.first.clips.single.endTime, video.endTime);
    expect(
      original.tracks.last.clips.single.startTime,
      const Duration(seconds: 1),
    );
  });

  test('speed rejects ripple edits into locked downstream tracks', () {
    final original = timeline([
      captionTrack(caption(start: 5, end: 6), locked: true),
    ]);
    expect(() => change(original), throwsStateError);
  });

  test(
    'captions outside the old source window ripple without a range error',
    () {
      final updated = change(
        timeline([captionTrack(caption(start: 5, end: 6))]),
      );
      final cue = updated.tracks.last.clips.single;
      expect(cue.startTime, const Duration(seconds: 3));
      expect(cue.endTime, const Duration(seconds: 4));
      expect(cue.linkedClipId, video.id);
      expect(
        updated.tracks.first.clips.single.endTime,
        const Duration(seconds: 2),
      );
    },
  );

  test(
    'speed ripple keeps downstream markers and export work area aligned',
    () {
      final updated = change(timeline([]));
      expect(updated.markers.single.position, const Duration(seconds: 4));
      expect(
        updated.workspaceSettings.workAreaStart,
        const Duration(seconds: 2),
      );
      expect(updated.workspaceSettings.workAreaEnd, const Duration(seconds: 6));
    },
  );

  test('a stale speed action cannot edit a removed clip', () {
    expect(() => change(timeline([]).copyWith(tracks: [])), throwsStateError);
  });

  test('non-finite playback rates are rejected', () {
    expect(
      () => buildClipPlaybackRateUpdate(
        timeline: timeline([]),
        clipId: video.id,
        playbackRate: double.nan,
      ),
      throwsStateError,
    );
  });
}
