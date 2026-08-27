import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/editor/models/timeline_models.dart';
import 'ffmpeg_service.dart';
import 'timeline_export_service.dart';

class PreviewAudioMixPlan {
  final String fingerprint;
  final EditorTimeline timeline;
  final Duration timelineDuration;
  final List<TimelineRenderInput> inputs;
  final int maximumConcurrentVoices;

  const PreviewAudioMixPlan({
    required this.fingerprint,
    required this.timeline,
    required this.timelineDuration,
    required this.inputs,
    required this.maximumConcurrentVoices,
  });
}

class PreviewAudioMixResult {
  final String fingerprint;
  final String outputPath;
  final int inputCount;
  final int maximumConcurrentVoices;

  const PreviewAudioMixResult({
    required this.fingerprint,
    required this.outputPath,
    required this.inputCount,
    required this.maximumConcurrentVoices,
  });
}

/// Creates one deterministic audio stream for the complete editor timeline.
///
/// Visual preview controllers are intentionally not used as independent audio
/// players once this mix is available. One continuous 48 kHz bus avoids audio
/// focus contention, per-player buffering races, duplicate embedded streams,
/// and seek storms when many videos overlap.
class TimelinePreviewAudioService {
  TimelinePreviewAudioService._();

  static Future<void> _renderTail = Future<void>.value();
  static final Map<String, bool> _probedAudioCapabilities = {};

  static PreviewAudioMixPlan? buildPlan({
    required EditorTimeline timeline,
    String legacyVideoPath = '',
    bool Function(String path)? fileExists,
    String Function(String path)? sourceVersion,
  }) {
    final exists = fileExists ?? (path) => File(path).existsSync();
    final version = sourceVersion ?? _sourceVersion;
    final explicitVisualAudioOwners = <({String visualClipId, String assetId})>{
      for (final track in timeline.tracks)
        if (track.section == TimelineTrackSection.audio)
          for (final clip in track.clips)
            if (clip.type == TimelineTrackType.audio &&
                clip.linkedClipId != null &&
                clip.assetId != null)
              (visualClipId: clip.linkedClipId!, assetId: clip.assetId!),
    };
    final hasSoloMediaTrack = timeline.tracks.any(
      (track) =>
          track.isSolo &&
          (!track.isHidden || track.section == TimelineTrackSection.audio) &&
          track.clips.any(
            (clip) =>
                clip.enabled &&
                clip.endTime > clip.startTime &&
                clip.type != TimelineTrackType.text &&
                clip.type != TimelineTrackType.subtitle &&
                clip.type != TimelineTrackType.effect,
          ),
    );

    final selected =
        <
          ({
            int trackIndex,
            TimelineTrack track,
            TimelineClip clip,
            EditorAssetReference? asset,
            String sourcePath,
          })
        >[];
    for (
      var trackIndex = 0;
      trackIndex < timeline.tracks.length;
      trackIndex++
    ) {
      final track = timeline.tracks[trackIndex];
      if (track.section != TimelineTrackSection.baseVideo &&
          track.section != TimelineTrackSection.overlay &&
          track.section != TimelineTrackSection.audio) {
        continue;
      }
      if (track.isMuted ||
          (track.isHidden && track.section != TimelineTrackSection.audio) ||
          (hasSoloMediaTrack && !track.isSolo)) {
        continue;
      }
      for (final clip in track.clips) {
        if (!clip.enabled ||
            clip.endTime <= clip.startTime ||
            clip.audioMix.muted ||
            (clip.type != TimelineTrackType.video &&
                clip.type != TimelineTrackType.audio)) {
          continue;
        }
        // An explicit separated audio clip owns the source even if an older or
        // malformed project forgot to mute the corresponding visual clip.
        if (clip.type == TimelineTrackType.video &&
            clip.assetId != null &&
            explicitVisualAudioOwners.contains((
              visualClipId: clip.id,
              assetId: clip.assetId!,
            ))) {
          continue;
        }
        if (clip.type == TimelineTrackType.video &&
            !timeline.clipHasAudio(clip)) {
          continue;
        }
        final asset = timeline.assetForClip(clip);
        final assetPath = asset?.sourcePath?.trim();
        final sourcePath = assetPath != null && assetPath.isNotEmpty
            ? assetPath
            : clip.assetId == null && legacyVideoPath.trim().isNotEmpty
            ? legacyVideoPath.trim()
            : null;
        if (sourcePath == null || !exists(sourcePath)) continue;
        selected.add((
          trackIndex: trackIndex,
          track: track,
          clip: clip,
          asset: asset,
          sourcePath: sourcePath,
        ));
      }
    }
    if (selected.isEmpty) return null;

    selected.sort((a, b) {
      final trackComparison = a.trackIndex.compareTo(b.trackIndex);
      if (trackComparison != 0) return trackComparison;
      final startComparison = a.clip.startTime.compareTo(b.clip.startTime);
      return startComparison != 0
          ? startComparison
          : a.clip.id.compareTo(b.clip.id);
    });
    final inputs = <TimelineRenderInput>[
      for (var index = 0; index < selected.length; index++)
        TimelineRenderInput(
          index: index,
          trackIndex: selected[index].trackIndex,
          track: selected[index].track,
          clip: selected[index].clip,
          asset: selected[index].asset,
          sourcePath: selected[index].sourcePath,
          hasAudio: true,
        ),
    ];
    final maximumConcurrentVoices = _maximumConcurrentVoices(inputs);
    final sourceVersions = <String, String>{};
    final fingerprintPayload = <String, Object?>{
      'durationUs': timeline.duration.inMicroseconds,
      'inputs': [
        for (final input in inputs)
          {
            'source': input.sourcePath,
            'sourceVersion': sourceVersions.putIfAbsent(
              input.sourcePath,
              () => version(input.sourcePath),
            ),
            'trackId': input.track.id,
            'trackIndex': input.trackIndex,
            'trackMuted': input.track.isMuted,
            'trackSolo': input.track.isSolo,
            'trackGain': input.track.audioGain,
            'trackPan': input.track.audioPan,
            'clipId': input.clip.id,
            'assetId': input.clip.assetId,
            'linkedClipId': input.clip.linkedClipId,
            'startUs': input.clip.startTime.inMicroseconds,
            'endUs': input.clip.endTime.inMicroseconds,
            'sourceStartUs': input.clip.sourceStartTime.inMicroseconds,
            'sourceDurationUs': input.clip.sourceDuration.inMicroseconds,
            'playbackRate': input.clip.playbackRate,
            'reversed': input.clip.isReversed,
            'freezeFrame': input.clip.freezeFrame,
            'audioMix': input.clip.audioMix.toJson(),
            'autoDuck': input.clip.autoDuck,
            'duckAmount': input.clip.duckAmount,
            'duckAttackMs': input.clip.duckAttackMs,
            'duckReleaseMs': input.clip.duckReleaseMs,
            'duckSidechainTrackIds': input.clip.duckSidechainTrackIds,
            'denoise': input.clip.denoise,
            'volumeKeyframes': [
              for (final keyframe in input.clip.keyframes)
                if (keyframe.property == TimelineKeyframeProperty.volume)
                  keyframe.toJson(),
            ],
          },
      ],
      // Automatic ducking depends on dialogue/text timing even when those
      // clips do not own an audio stream themselves.
      'dialogueWindows': [
        for (final track in timeline.tracks)
          if (!track.isHidden &&
              (track.type == TimelineTrackType.text ||
                  track.type == TimelineTrackType.subtitle))
            for (final clip in track.clips)
              if (clip.enabled && clip.endTime > clip.startTime)
                [
                  track.id,
                  clip.id,
                  clip.startTime.inMicroseconds,
                  clip.endTime.inMicroseconds,
                ],
      ],
    };
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode(fingerprintPayload)))
        .toString();
    return PreviewAudioMixPlan(
      fingerprint: fingerprint,
      timeline: timeline,
      timelineDuration: timeline.duration,
      inputs: List.unmodifiable(inputs),
      maximumConcurrentVoices: maximumConcurrentVoices,
    );
  }

  static Future<PreviewAudioMixResult> ensureRendered(
    PreviewAudioMixPlan plan,
  ) {
    final operation = _renderTail.then((_) => _render(plan));
    _renderTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  static Future<PreviewAudioMixResult> _render(PreviewAudioMixPlan plan) async {
    final temporaryDirectory = await getTemporaryDirectory();
    final outputPath = p.join(
      temporaryDirectory.path,
      'caption_craft_preview_audio_${plan.fingerprint}.m4a',
    );
    final output = File(outputPath);
    if (await output.exists() && await output.length() > 0) {
      return PreviewAudioMixResult(
        fingerprint: plan.fingerprint,
        outputPath: outputPath,
        inputCount: plan.inputs.length,
        maximumConcurrentVoices: plan.maximumConcurrentVoices,
      );
    }

    final partialPath = p.join(
      temporaryDirectory.path,
      'caption_craft_preview_audio_${plan.fingerprint}_'
      '${DateTime.now().microsecondsSinceEpoch}.partial.m4a',
    );
    final partial = File(partialPath);
    final renderInputs = await _verifiedAudioInputs(plan.inputs);
    if (renderInputs.isEmpty) {
      throw StateError('No readable audio streams were found for preview.');
    }
    final arguments = TimelineExportService.buildPreviewAudioMixArguments(
      timeline: plan.timeline,
      inputs: renderInputs,
      timelineDuration: plan.timelineDuration,
      outputPath: partialPath,
    );
    try {
      final session = await FFmpegKit.executeWithArguments(arguments);
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode) ||
          !await partial.exists() ||
          await partial.length() == 0) {
        final logs = await session.getAllLogsAsString() ?? '';
        throw StateError(
          logs.trim().isEmpty
              ? 'Could not render the editor preview audio mix.'
              : 'Could not render the editor preview audio mix: '
                    '${_lastLogLines(logs)}',
        );
      }
      if (await output.exists()) await output.delete();
      await partial.rename(outputPath);
      return PreviewAudioMixResult(
        fingerprint: plan.fingerprint,
        outputPath: outputPath,
        inputCount: renderInputs.length,
        maximumConcurrentVoices: _maximumConcurrentVoices(renderInputs),
      );
    } finally {
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {
          // A failed FFmpeg session can retain its output briefly.
        }
      }
    }
  }

  static Future<List<TimelineRenderInput>> _verifiedAudioInputs(
    List<TimelineRenderInput> inputs,
  ) async {
    final readable = <TimelineRenderInput>[];
    for (final input in inputs) {
      if (input.clip.type == TimelineTrackType.audio) {
        readable.add(input);
        continue;
      }
      final declaredCapability = input.asset?.metadata['hasAudio'];
      if (declaredCapability is bool) {
        if (declaredCapability) readable.add(input);
        continue;
      }

      final capabilityKey =
          '${input.sourcePath}|${_sourceVersion(input.sourcePath)}';
      var hasAudio = _probedAudioCapabilities[capabilityKey];
      if (hasAudio == null) {
        try {
          final mediaInfo = await FFmpegService.getMediaInfo(input.sourcePath);
          hasAudio = mediaInfo['hasAudio'] as bool? ?? false;
          if (_probedAudioCapabilities.length >= 256) {
            _probedAudioCapabilities.clear();
          }
          _probedAudioCapabilities[capabilityKey] = hasAudio;
        } catch (_) {
          // Let the actual renderer decide when a probe is unavailable. This
          // avoids dropping valid audio because of a transient probe failure.
          hasAudio = true;
        }
      }
      if (hasAudio) readable.add(input);
    }

    return [
      for (var index = 0; index < readable.length; index++)
        TimelineRenderInput(
          index: index,
          trackIndex: readable[index].trackIndex,
          track: readable[index].track,
          clip: readable[index].clip,
          asset: readable[index].asset,
          sourcePath: readable[index].sourcePath,
          hasAudio: true,
          frameRate: readable[index].frameRate,
        ),
    ];
  }

  static int _maximumConcurrentVoices(List<TimelineRenderInput> inputs) {
    final events =
        <({int timeUs, int delta})>[
          for (final input in inputs) ...[
            (timeUs: input.clip.startTime.inMicroseconds, delta: 1),
            (timeUs: input.clip.endTime.inMicroseconds, delta: -1),
          ],
        ]..sort((a, b) {
          final timeComparison = a.timeUs.compareTo(b.timeUs);
          return timeComparison != 0
              ? timeComparison
              : a.delta.compareTo(b.delta);
        });
    var active = 0;
    var maximum = 0;
    for (final event in events) {
      active = math.max(0, active + event.delta);
      maximum = math.max(maximum, active);
    }
    return maximum;
  }

  static String _sourceVersion(String path) {
    try {
      final stat = File(path).statSync();
      return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    } catch (_) {
      return 'unavailable';
    }
  }

  static String _lastLogLines(String logs) {
    final lines = logs
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return lines.skip(math.max(0, lines.length - 5)).join(' | ');
  }
}
