import 'dart:io';

import 'package:caption_craft/core/utils/audio_meter_service.dart';
import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/core/utils/timeline_preview_audio_service.dart';
import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/screens/editor_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test('audio meter parser preserves Peak, RMS, LUFS and loudnorm values', () {
    const logs = '''
      [Parsed_astats_0] RMS level dB: -18.42
      [Parsed_astats_0] Peak level dB: -3.21
      {
        "input_i" : "-16.73",
        "input_tp" : "-2.04",
        "input_lra" : "4.80",
        "input_thresh" : "-27.15",
        "output_i" : "-16.01",
        "target_offset" : "0.01"
      }
    ''';
    final analysis = AudioMeterService.parseLogs(
      logs,
      sourceFingerprint: 'fingerprint',
    );

    expect(analysis.samplePeakDb, closeTo(-3.21, 0.001));
    expect(analysis.rmsDb, closeTo(-18.42, 0.001));
    expect(analysis.integratedLufs, closeTo(-16.73, 0.001));
    expect(analysis.truePeakDb, closeTo(-2.04, 0.001));
    expect(analysis.loudnessRange, closeTo(4.8, 0.001));
    expect(
      AudioLoudnessAnalysis.fromJson(analysis.toJson()).rmsDb,
      closeTo(-18.42, 0.001),
    );
  });

  test('audio routing and loudness measurements survive project reload', () {
    final analyzedAt = DateTime.utc(2026, 8, 30, 12, 34, 56);
    final settings = AudioMixSettings(
      volume: 0.72,
      fadeInMs: 320,
      fadeOutMs: 480,
      pan: -0.25,
      normalize: true,
      fadeInShape: AudioFadeShape.logarithmic,
      fadeOutShape: AudioFadeShape.sCurve,
      channelMode: EditorAudioChannelMode.dualMono,
      sourceStreamIndex: 2,
      sourceLeftChannel: 3,
      sourceRightChannel: 5,
      leftGain: 0.65,
      rightGain: 1.35,
      targetLufs: -23,
      peakLimitDb: -2,
      pitchSemitones: 3,
      timeStretch: 1.25,
      preservePitch: true,
      loudnessAnalysis: AudioLoudnessAnalysis(
        integratedLufs: -19.4,
        truePeakDb: -1.8,
        samplePeakDb: -2.1,
        rmsDb: -22.3,
        loudnessRange: 5.7,
        thresholdLufs: -29.6,
        targetOffset: -3.6,
        sourceFingerprint: 'exact-render-graph',
        analyzedAt: analyzedAt,
      ),
    );
    final restored = AudioMixSettings.fromJson(settings.toJson());

    expect(restored.volume, 0.72);
    expect(restored.fadeInMs, 320);
    expect(restored.fadeOutMs, 480);
    expect(restored.fadeInShape, AudioFadeShape.logarithmic);
    expect(restored.fadeOutShape, AudioFadeShape.sCurve);
    expect(restored.channelMode, EditorAudioChannelMode.dualMono);
    expect(restored.sourceStreamIndex, 2);
    expect(restored.sourceLeftChannel, 3);
    expect(restored.sourceRightChannel, 5);
    expect(restored.leftGain, 0.65);
    expect(restored.rightGain, 1.35);
    expect(restored.targetLufs, -23);
    expect(restored.peakLimitDb, -2);
    expect(restored.pitchSemitones, 3);
    expect(restored.timeStretch, 1.25);
    expect(restored.loudnessAnalysis?.samplePeakDb, -2.1);
    expect(restored.loudnessAnalysis?.rmsDb, -22.3);
    expect(restored.loudnessAnalysis?.sourceFingerprint, 'exact-render-graph');
    expect(restored.loudnessAnalysis?.analyzedAt, analyzedAt);
  });

  test(
    'stored loudness pass is used only while its fingerprint is current',
    () {
      final clip = TimelineClip(
        id: 'audio',
        trackId: 'audio-track',
        type: TimelineTrackType.audio,
        label: 'Audio',
        assetId: 'asset',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
        sourceDuration: const Duration(seconds: 2),
        audioMix: const AudioMixSettings(normalize: true),
      );
      final track = TimelineTrack(
        id: 'audio-track',
        name: 'Audio',
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        clips: [clip],
      );
      final asset = EditorAssetReference(
        id: 'asset',
        type: EditorAssetType.audio,
        label: 'Audio',
        sourcePath: 'missing.wav',
        metadata: const {
          'hasAudio': true,
          'audioStreamCount': 1,
          'audioChannels': 2,
        },
      );
      var timeline = EditorTimeline(assets: [asset], tracks: [track]);
      var input = TimelineRenderInput(
        index: 0,
        trackIndex: 0,
        track: track,
        clip: clip,
        asset: asset,
        sourcePath: 'missing.wav',
        hasAudio: true,
        audioStreamCount: 1,
        audioChannels: 2,
      );
      final fingerprint = TimelineExportService.audioAnalysisFingerprint(
        timeline: timeline,
        input: input,
      );
      final analysis = AudioLoudnessAnalysis(
        integratedLufs: -20,
        truePeakDb: -3,
        samplePeakDb: -3.2,
        rmsDb: -22,
        loudnessRange: 4,
        thresholdLufs: -30,
        targetOffset: 0.2,
        sourceFingerprint: fingerprint,
      );
      final measuredClip = clip.copyWith(
        audioMix: clip.audioMix.copyWith(loudnessAnalysis: analysis),
      );
      final measuredTrack = track.copyWith(clips: [measuredClip]);
      timeline = timeline.copyWith(tracks: [measuredTrack]);
      input = TimelineRenderInput(
        index: 0,
        trackIndex: 0,
        track: measuredTrack,
        clip: measuredClip,
        asset: asset,
        sourcePath: 'missing.wav',
        hasAudio: true,
        audioStreamCount: 1,
        audioChannels: 2,
      );
      final currentGraph = TimelineExportService.buildPreviewAudioMixArguments(
        timeline: timeline,
        inputs: [input],
        timelineDuration: const Duration(seconds: 2),
        outputPath: 'preview.m4a',
      ).join(' ');
      expect(currentGraph, contains('measured_I=-20'));

      final staleClip = measuredClip.copyWith(
        audioMix: measuredClip.audioMix.copyWith(leftGain: 0.5),
      );
      final staleTrack = measuredTrack.copyWith(clips: [staleClip]);
      final staleGraph = TimelineExportService.buildPreviewAudioMixArguments(
        timeline: timeline.copyWith(tracks: [staleTrack]),
        inputs: [
          TimelineRenderInput(
            index: 0,
            trackIndex: 0,
            track: staleTrack,
            clip: staleClip,
            asset: asset,
            sourcePath: 'missing.wav',
            hasAudio: true,
            audioStreamCount: 1,
            audioChannels: 2,
          ),
        ],
        timelineDuration: const Duration(seconds: 2),
        outputPath: 'preview.m4a',
      ).join(' ');
      expect(staleGraph, isNot(contains('measured_I=')));
    },
  );

  test(
    'crossfade overlaps clips on separate lanes with smooth persisted fades',
    () {
      final first = _audioClip('first', 'track-a', 0, 4000);
      final second = _audioClip('second', 'track-a', 4000, 8000);
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'track-a',
            name: 'Music',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
            clips: [first, second],
          ),
        ],
      );

      final crossed = applyAudioCrossfadeForTesting(
        timeline: timeline,
        firstClipId: first.id,
        secondClipId: second.id,
        duration: const Duration(seconds: 1),
      );
      final crossedFirst = crossed.tracks
          .expand((track) => track.clips)
          .singleWhere((clip) => clip.id == first.id);
      final crossedSecond = crossed.tracks
          .expand((track) => track.clips)
          .singleWhere((clip) => clip.id == second.id);

      expect(crossed.hasTrackOverlaps, isFalse);
      expect(
        crossed.tracks.where((track) => track.clips.isNotEmpty),
        hasLength(2),
      );
      expect(crossedSecond.startTime, const Duration(seconds: 3));
      expect(crossedFirst.audioMix.fadeOutMs, 1000);
      expect(crossedSecond.audioMix.fadeInMs, 1000);
      expect(crossedFirst.audioMix.fadeOutShape, AudioFadeShape.sCurve);
      expect(crossedSecond.audioMix.fadeInShape, AudioFadeShape.sCurve);
    },
  );

  test(
    'fit music retimes automation and consumes the complete source window',
    () {
      final clip = _audioClip('music', 'audio', 0, 4000).copyWith(
        sourceDuration: const Duration(seconds: 4),
        keyframes: [
          TimelineKeyframe(
            time: const Duration(seconds: 2),
            property: TimelineKeyframeProperty.volume,
            value: 0.5,
          ),
        ],
      );
      final track = TimelineTrack(
        id: 'audio',
        name: 'Audio',
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        clips: [clip],
      );
      final fitted = fitAudioClipToDurationForTesting(
        timeline: EditorTimeline(tracks: [track]),
        clipId: clip.id,
        targetDuration: const Duration(seconds: 2),
      );
      final result = fitted.tracks.single.clips.single;
      expect(result.duration, const Duration(seconds: 2));
      expect(result.audioMix.timeStretch, closeTo(2, 0.001));
      expect(result.keyframes.single.time, const Duration(seconds: 1));
      final arguments = TimelineExportService.buildPreviewAudioMixArguments(
        timeline: fitted,
        inputs: [
          TimelineRenderInput(
            index: 0,
            trackIndex: 0,
            track: fitted.tracks.single,
            clip: result,
            asset: null,
            sourcePath: 'music.wav',
            hasAudio: true,
            audioChannels: 2,
          ),
        ],
        timelineDuration: result.duration,
        outputPath: 'preview.m4a',
      );
      expect(
        arguments,
        containsAllInOrder(['-t', '4.000000', '-i', 'music.wav']),
      );
      expect(arguments.join(' '), contains('atempo=2'));
    },
  );

  test('unlink, relink and reattach preserve routing and audio effects', () {
    final video = TimelineClip(
      id: 'video',
      trackId: 'video-track',
      type: TimelineTrackType.video,
      label: 'Video',
      assetId: 'asset',
      startTime: const Duration(seconds: 5),
      endTime: const Duration(seconds: 9),
      sourceStartTime: const Duration(seconds: 1),
      sourceDuration: const Duration(seconds: 4),
      embeddedAudioSeparated: true,
      audioMix: const AudioMixSettings(muted: true),
      effectStack: EditorEffectStack(
        effects: [EditorEffect(type: EditorEffectType.glow)],
      ),
    );
    final audio = TimelineClip(
      id: 'audio',
      trackId: 'audio-track',
      type: TimelineTrackType.audio,
      label: 'Audio',
      assetId: 'asset',
      linkedClipId: video.id,
      separatedFromClipId: video.id,
      startTime: video.startTime,
      endTime: video.endTime,
      sourceStartTime: video.sourceStartTime,
      sourceDuration: video.sourceDuration,
      audioMix: const AudioMixSettings(volume: 0.5, pan: 0.1),
      effectStack: EditorEffectStack(
        effects: [EditorEffect(type: EditorEffectType.compressor)],
      ),
    );
    final timeline = EditorTimeline(
      tracks: [
        TimelineTrack(
          id: 'video-track',
          name: 'Video',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [video],
        ),
        TimelineTrack(
          id: 'audio-track',
          name: 'Audio',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          audioGain: 1.5,
          audioPan: 0.2,
          clips: [audio],
        ),
      ],
    );

    final unlinked = unlinkSeparatedAudioForTesting(
      timeline: timeline,
      audioClipId: audio.id,
    );
    expect(
      unlinked.tracks
          .expand((track) => track.clips)
          .byId(audio.id)
          ?.linkedClipId,
      isNull,
    );
    final unlinkedAudio = unlinked.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == audio.id);
    expect(unlinkedAudio.separatedAudioSourceClipId, video.id);
    expect(
      resolveEffectiveAudioOwner(timeline: unlinked, clip: video)?.clip.id,
      audio.id,
    );

    final reloaded = EditorTimeline.fromJson(unlinked.toJson());
    final reloadedVideo = reloaded.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == video.id);
    final reloadedAudio = reloaded.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == audio.id);
    expect(reloadedVideo.embeddedAudioSeparated, isTrue);
    expect(reloadedAudio.linkedClipId, isNull);
    expect(reloadedAudio.separatedAudioSourceClipId, video.id);
    expect(
      resolveEffectiveAudioOwner(
        timeline: reloaded,
        clip: reloadedVideo,
      )?.clip.id,
      audio.id,
    );

    final directlyReattached = reattachSeparatedAudioForTesting(
      timeline: unlinked,
      audioClipId: audio.id,
    );
    final directlyRestoredVideo = directlyReattached.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == video.id);
    expect(directlyRestoredVideo.embeddedAudioSeparated, isFalse);
    expect(
      directlyReattached.tracks
          .expand((track) => track.clips)
          .any((clip) => clip.id == audio.id),
      isFalse,
    );
    final movedTimeline = unlinked.copyWith(
      tracks: unlinked.tracks.map((track) {
        return track.copyWith(
          clips: track.clips.map((clip) {
            return clip.id == audio.id
                ? clip.copyWith(
                    startTime: Duration.zero,
                    endTime: const Duration(seconds: 4),
                  )
                : clip;
          }).toList(),
        );
      }).toList(),
    );
    final relinked = relinkSeparatedAudioForTesting(
      timeline: movedTimeline,
      audioClipId: audio.id,
      videoClipId: video.id,
    );
    final relinkedAudio = relinked.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == audio.id);
    expect(relinkedAudio.startTime, video.startTime);
    expect(relinkedAudio.linkedClipId, video.id);

    final reattached = reattachSeparatedAudioForTesting(
      timeline: relinked,
      audioClipId: audio.id,
    );
    expect(
      reattached.tracks
          .expand((track) => track.clips)
          .any((clip) => clip.id == audio.id),
      isFalse,
    );
    final restoredVideo = reattached.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == video.id);
    expect(restoredVideo.audioMix.volume, closeTo(0.75, 0.001));
    expect(restoredVideo.audioMix.pan, closeTo(0.3, 0.001));
    expect(
      restoredVideo.effectStack.effects.map((effect) => effect.type),
      containsAll([EditorEffectType.glow, EditorEffectType.compressor]),
    );
  });

  test('legacy separated audio upgrades to persistent ownership on reload', () {
    final video = TimelineClip(
      id: 'video',
      trackId: 'video-track',
      type: TimelineTrackType.video,
      label: 'Video',
      assetId: 'asset',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
      audioMix: const AudioMixSettings(muted: true),
    );
    final audio = TimelineClip(
      id: 'audio',
      trackId: 'audio-track',
      type: TimelineTrackType.audio,
      label: 'Video audio',
      assetId: 'asset',
      linkedClipId: video.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
    );
    final legacyJson = EditorTimeline(
      schemaVersion: 9,
      tracks: [
        TimelineTrack(
          id: 'video-track',
          name: 'Video',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [video],
        ),
        TimelineTrack(
          id: 'audio-track',
          name: 'Audio',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          clips: [audio],
        ),
      ],
    ).toJson();
    legacyJson['schemaVersion'] = 9;
    final tracks = legacyJson['tracks'] as List<dynamic>;
    final videoJson = (tracks[0] as Map<String, dynamic>)['clips'] as List;
    final audioJson = (tracks[1] as Map<String, dynamic>)['clips'] as List;
    (videoJson.single as Map<String, dynamic>).remove('embeddedAudioSeparated');
    (audioJson.single as Map<String, dynamic>).remove('separatedFromClipId');

    final restored = EditorTimeline.fromJson(legacyJson);
    final restoredVideo = restored.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == video.id);
    final restoredAudio = restored.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == audio.id);

    expect(restored.schemaVersion, EditorTimeline.currentSchemaVersion);
    expect(restoredVideo.embeddedAudioSeparated, isTrue);
    expect(restoredAudio.separatedAudioSourceClipId, video.id);
  });

  test(
    'equalizer processes attached video audio and extracted audio identically',
    () async {
      if (!await _commandExists('ffmpeg')) {
        markTestSkipped('Desktop FFmpeg is not installed.');
        return;
      }
      final directory = await Directory.systemTemp.createTemp(
        'cc_attached_audio_fx_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final source = path.join(directory.path, 'source.mp4');
      final generated = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=c=black:size=160x120:rate=24:duration=1',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=1000:sample_rate=48000:duration=1',
        '-shortest',
        '-c:v',
        'mpeg4',
        '-c:a',
        'aac',
        source,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');

      final effect = EditorEffect(
        type: EditorEffectType.equalizer,
        parameters: const <String, dynamic>{
          'frequency': 1000,
          'gain': -18,
          'width': 2,
        },
      );

      Future<double> render({
        required String name,
        required TimelineTrackType type,
        required bool withEffect,
      }) async {
        final asset = EditorAssetReference(
          id: 'asset-$name',
          type: EditorAssetType.video,
          label: name,
          sourcePath: source,
          metadata: const <String, dynamic>{
            'hasAudio': true,
            'audioStreamCount': 1,
            'audioChannels': 1,
          },
        );
        final track = TimelineTrack(
          id: 'track-$name',
          name: name,
          type: type,
          section: type == TimelineTrackType.video
              ? TimelineTrackSection.baseVideo
              : TimelineTrackSection.audio,
          clips: [
            TimelineClip(
              id: 'clip-$name',
              trackId: 'track-$name',
              type: type,
              label: name,
              assetId: asset.id,
              separatedFromClipId: type == TimelineTrackType.audio
                  ? 'source-video'
                  : null,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 1),
              sourceDuration: const Duration(seconds: 1),
              effectStack: withEffect
                  ? EditorEffectStack(effects: [effect])
                  : const EditorEffectStack(),
            ),
          ],
        );
        final timeline = EditorTimeline(assets: [asset], tracks: [track]);
        final plan = TimelinePreviewAudioService.buildPlan(
          timeline: timeline,
          fileExists: (_) => true,
          sourceVersion: (_) => 'source-v1',
        );
        expect(plan, isNotNull);
        final output = path.join(directory.path, '$name.m4a');
        final arguments = TimelineExportService.buildPreviewAudioMixArguments(
          timeline: timeline,
          inputs: plan!.inputs,
          timelineDuration: plan.timelineDuration,
          outputPath: output,
        );
        if (withEffect) {
          expect(arguments.join(' '), contains('equalizer=f=1000'));
        }
        final result = await Process.run('ffmpeg', arguments);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return _rmsLevelDb(output);
      }

      final baseline = await render(
        name: 'baseline',
        type: TimelineTrackType.video,
        withEffect: false,
      );
      final attached = await render(
        name: 'attached',
        type: TimelineTrackType.video,
        withEffect: true,
      );
      final extracted = await render(
        name: 'extracted',
        type: TimelineTrackType.audio,
        withEffect: true,
      );

      expect(attached, lessThan(baseline - 10));
      expect(extracted, lessThan(baseline - 10));
      expect(attached, closeTo(extracted, 0.5));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('real analysis graph executes through desktop FFmpeg', () async {
    if (!await _commandExists('ffmpeg')) {
      markTestSkipped('Desktop FFmpeg is not installed.');
      return;
    }
    final directory = await Directory.systemTemp.createTemp('cc_audio_meter_');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final source = path.join(directory.path, 'tone.wav');
    final generated = await Process.run('ffmpeg', [
      '-hide_banner',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=48000:duration=1',
      source,
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    final clip = _audioClip(
      'meter',
      'audio',
      0,
      1000,
    ).copyWith(sourceDuration: const Duration(seconds: 1));
    final track = TimelineTrack(
      id: 'audio',
      name: 'Audio',
      type: TimelineTrackType.audio,
      section: TimelineTrackSection.audio,
      clips: [clip],
    );
    final timeline = EditorTimeline(tracks: [track]);
    final input = TimelineRenderInput(
      index: 0,
      trackIndex: 0,
      track: track,
      clip: clip,
      asset: null,
      sourcePath: source,
      hasAudio: true,
      audioStreamCount: 1,
      audioChannels: 1,
    );
    final arguments = TimelineExportService.buildAudioAnalysisArguments(
      timeline: timeline,
      inputs: [input],
      timelineDuration: const Duration(seconds: 1),
      targetLufs: -16,
      peakLimitDb: -1.5,
    );
    final result = await Process.run('ffmpeg', arguments);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final analysis = AudioMeterService.parseLogs(
      '${result.stdout}\n${result.stderr}',
      sourceFingerprint: 'desktop',
    );
    expect(analysis.integratedLufs.isFinite, isTrue);
    expect(analysis.rmsDb.isFinite, isTrue);
    expect(analysis.samplePeakDb, lessThanOrEqualTo(0));
  });

  test(
    'source channel mapping renders the selected channels to stereo',
    () async {
      if (!await _commandExists('ffmpeg')) {
        markTestSkipped('Desktop FFmpeg is not installed.');
        return;
      }
      final directory = await Directory.systemTemp.createTemp(
        'cc_audio_routing_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final source = path.join(directory.path, 'four_channels.wav');
      final output = path.join(directory.path, 'routed.m4a');
      final generated = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'aevalsrc=0.1*sin(2*PI*220*t)|0.1*sin(2*PI*440*t)|'
            '0.1*sin(2*PI*660*t)|0.1*sin(2*PI*880*t):'
            's=48000:d=1:c=4.0',
        source,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      final clip = _audioClip('route', 'audio', 0, 1000).copyWith(
        sourceDuration: const Duration(seconds: 1),
        audioMix: const AudioMixSettings(
          sourceLeftChannel: 2,
          sourceRightChannel: 3,
          leftGain: 0.75,
          rightGain: 1.2,
        ),
      );
      final track = TimelineTrack(
        id: 'audio',
        name: 'Audio',
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        clips: [clip],
      );
      final timeline = EditorTimeline(tracks: [track]);
      final arguments = TimelineExportService.buildPreviewAudioMixArguments(
        timeline: timeline,
        inputs: [
          TimelineRenderInput(
            index: 0,
            trackIndex: 0,
            track: track,
            clip: clip,
            asset: null,
            sourcePath: source,
            hasAudio: true,
            audioStreamCount: 1,
            audioChannels: 4,
            audioChannelsByStream: const [4],
          ),
        ],
        timelineDuration: const Duration(seconds: 1),
        outputPath: output,
      );
      expect(arguments.join(' '), contains('pan=stereo|c0=c2|c1=c3'));
      final render = await Process.run('ffmpeg', arguments);
      expect(render.exitCode, 0, reason: '${render.stderr}');
      final leftCrossings = await _zeroCrossings(output, channel: 0);
      final rightCrossings = await _zeroCrossings(output, channel: 1);
      expect(leftCrossings, greaterThan(900));
      expect(rightCrossings, greaterThan(leftCrossings + 250));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

TimelineClip _audioClip(String id, String trackId, int startMs, int endMs) {
  return TimelineClip(
    id: id,
    trackId: trackId,
    type: TimelineTrackType.audio,
    label: id,
    assetId: '$id-asset',
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
    sourceDuration: Duration(milliseconds: endMs - startMs),
  );
}

Future<bool> _commandExists(String command) async {
  try {
    final result = await Process.run(command, const ['-version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<int> _zeroCrossings(String sourcePath, {required int channel}) async {
  final result = await Process.run('ffmpeg', [
    '-hide_banner',
    '-i',
    sourcePath,
    '-af',
    'pan=mono|c0=c$channel,astats=reset=0',
    '-f',
    'null',
    '-',
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  final matches = RegExp(
    r'Zero crossings:\s*(\d+)',
    caseSensitive: false,
  ).allMatches('${result.stdout}\n${result.stderr}');
  expect(matches, isNotEmpty, reason: '${result.stderr}');
  return int.parse(matches.last.group(1)!);
}

Future<double> _rmsLevelDb(String sourcePath) async {
  final result = await Process.run('ffmpeg', [
    '-hide_banner',
    '-i',
    sourcePath,
    '-af',
    'astats=metadata=0:reset=0',
    '-f',
    'null',
    '-',
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  final matches = RegExp(
    r'RMS level dB:\s*(-?(?:\d+(?:\.\d+)?|inf))',
    caseSensitive: false,
  ).allMatches('${result.stdout}\n${result.stderr}');
  expect(matches, isNotEmpty, reason: '${result.stderr}');
  return double.parse(matches.last.group(1)!);
}

extension on Iterable<TimelineClip> {
  TimelineClip? byId(String id) =>
      where((clip) => clip.id == id).cast<TimelineClip?>().firstOrNull;
}
