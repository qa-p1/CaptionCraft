import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('export ducking follows muted and solo audio buses', () {
    final target = _audioClip(
      id: 'target',
      trackId: 'target-track',
      autoDuck: true,
      duckAmount: 0.5,
      duckAttackMs: 0,
      duckReleaseMs: 0,
    );
    final selectedVoice = _audioClip(
      id: 'selected-voice',
      trackId: 'selected-track',
      startMs: 1234,
      endMs: 1567,
    );
    final mutedVoice = _audioClip(
      id: 'muted-voice',
      trackId: 'muted-track',
      startMs: 2345,
      endMs: 2678,
    );
    final unsoloedVoice = _audioClip(
      id: 'unsoloed-voice',
      trackId: 'unsoloed-track',
      startMs: 3456,
      endMs: 3789,
    );
    final targetTrack = _audioTrack(
      id: 'target-track',
      audioBusId: 'solo-bus',
      clips: [target],
    );
    final selectedTrack = _audioTrack(
      id: 'selected-track',
      audioBusId: 'solo-bus',
      clips: [selectedVoice],
    );
    final mutedTrack = _audioTrack(
      id: 'muted-track',
      audioBusId: 'muted-bus',
      clips: [mutedVoice],
    );
    final unsoloedTrack = _audioTrack(
      id: 'unsoloed-track',
      audioBusId: 'unsoloed-bus',
      clips: [unsoloedVoice],
    );
    final timeline = EditorTimeline(
      tracks: [targetTrack, selectedTrack, mutedTrack, unsoloedTrack],
      audioBuses: [
        TimelineAudioBus(id: 'solo-bus', name: 'Solo', solo: true),
        TimelineAudioBus(id: 'muted-bus', name: 'Muted', muted: true),
        TimelineAudioBus(id: 'unsoloed-bus', name: 'Other'),
      ],
    );
    final expression =
        TimelineExportService.buildDuckingVolumeExpressionForTesting(
          clip: target,
          timeline: timeline,
          inputs: [
            _audioInput(targetTrack, target, 0),
            _audioInput(selectedTrack, selectedVoice, 1),
            _audioInput(mutedTrack, mutedVoice, 2),
            _audioInput(unsoloedTrack, unsoloedVoice, 3),
          ],
        );

    expect(expression, isNotNull);
    expect(expression, contains('1.234'));
    expect(expression, isNot(contains('2.345')));
    expect(expression, isNot(contains('3.456')));
  });

  test('export ducking excludes separated video audio owners', () {
    final target = _audioClip(
      id: 'target',
      trackId: 'target-track',
      autoDuck: true,
      duckAmount: 0.5,
      duckAttackMs: 0,
      duckReleaseMs: 0,
    );
    final separatedOwner = TimelineClip(
      id: 'separated-owner',
      trackId: 'separated-video-track',
      type: TimelineTrackType.video,
      label: 'Separated owner',
      startTime: const Duration(milliseconds: 345),
      endTime: const Duration(milliseconds: 678),
    );
    final separatedAudio = TimelineClip(
      id: 'separated-audio',
      trackId: 'separated-audio-track',
      type: TimelineTrackType.audio,
      label: 'Separated audio',
      separatedFromClipId: separatedOwner.id,
      startTime: separatedOwner.startTime,
      endTime: separatedOwner.endTime,
      audioMix: const AudioMixSettings(muted: true),
    );
    final explicitlySeparatedVideo = TimelineClip(
      id: 'explicitly-separated-video',
      trackId: 'explicitly-separated-track',
      type: TimelineTrackType.video,
      label: 'Explicitly separated video',
      startTime: const Duration(milliseconds: 1100),
      endTime: const Duration(milliseconds: 1400),
      embeddedAudioSeparated: true,
    );
    final ordinaryVoice = _audioClip(
      id: 'ordinary-voice',
      trackId: 'ordinary-track',
      startMs: 2345,
      endMs: 2678,
    );
    final targetTrack = _audioTrack(id: 'target-track', clips: [target]);
    final separatedVideoTrack = TimelineTrack(
      id: separatedOwner.trackId,
      name: 'Separated video',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.baseVideo,
      clips: [separatedOwner],
    );
    final separatedAudioTrack = _audioTrack(
      id: separatedAudio.trackId,
      clips: [separatedAudio],
    );
    final explicitlySeparatedTrack = TimelineTrack(
      id: explicitlySeparatedVideo.trackId,
      name: 'Explicitly separated video',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.baseVideo,
      clips: [explicitlySeparatedVideo],
    );
    final ordinaryTrack = _audioTrack(
      id: ordinaryVoice.trackId,
      clips: [ordinaryVoice],
    );
    final timeline = EditorTimeline(
      tracks: [
        targetTrack,
        separatedVideoTrack,
        separatedAudioTrack,
        explicitlySeparatedTrack,
        ordinaryTrack,
      ],
    );
    final expression =
        TimelineExportService.buildDuckingVolumeExpressionForTesting(
          clip: target,
          timeline: timeline,
          inputs: [
            _audioInput(targetTrack, target, 0),
            _audioInput(separatedVideoTrack, separatedOwner, 1),
            _audioInput(separatedAudioTrack, separatedAudio, 2),
            _audioInput(explicitlySeparatedTrack, explicitlySeparatedVideo, 3),
            _audioInput(ordinaryTrack, ordinaryVoice, 4),
          ],
        );

    expect(expression, isNotNull);
    expect(expression, contains('2.345'));
    expect(expression, isNot(contains('0.345')));
    expect(expression, isNot(contains('1.1')));
  });
}

TimelineClip _audioClip({
  required String id,
  required String trackId,
  int startMs = 0,
  int endMs = 5000,
  bool autoDuck = false,
  double duckAmount = 0.35,
  int duckAttackMs = 120,
  int duckReleaseMs = 180,
}) {
  return TimelineClip(
    id: id,
    trackId: trackId,
    type: TimelineTrackType.audio,
    label: id,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
    autoDuck: autoDuck,
    duckAmount: duckAmount,
    duckAttackMs: duckAttackMs,
    duckReleaseMs: duckReleaseMs,
  );
}

TimelineTrack _audioTrack({
  required String id,
  String? audioBusId,
  required List<TimelineClip> clips,
}) {
  return TimelineTrack(
    id: id,
    name: id,
    type: TimelineTrackType.audio,
    section: TimelineTrackSection.audio,
    audioBusId: audioBusId,
    clips: clips,
  );
}

TimelineRenderInput _audioInput(
  TimelineTrack track,
  TimelineClip clip,
  int index,
) {
  return TimelineRenderInput(
    index: index,
    trackIndex: index,
    track: track,
    clip: clip,
    asset: null,
    sourcePath: '$index.wav',
    hasAudio: true,
  );
}
