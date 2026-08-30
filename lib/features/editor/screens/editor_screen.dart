// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/editor_change_log_service.dart';
import '../../../core/utils/audio_meter_service.dart';
import '../../../core/utils/discover_media_import_service.dart';
import '../../../core/utils/ffmpeg_service.dart';
import '../../../core/utils/firebase_service.dart';
import '../../../core/utils/giphy_service.dart';
import '../../../core/utils/media_import_service.dart';
import '../../../core/utils/mask_tracking_service.dart';
import '../../../core/utils/remote_audio_import_service.dart';
import '../../../core/utils/remote_media_import_service.dart';
import '../../../core/utils/subtitle_export_service.dart';
import '../../../core/utils/subtitle_quality_service.dart';
import '../../../core/utils/timeline_proxy_media_service.dart';
import '../../../shared/models/project_model.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../../auth/providers/auth_provider.dart';
import '../../home/providers/transcription_pipeline.dart';
import '../../home/screens/processing_screen.dart';
import '../../quota/providers/quota_provider.dart';
import '../../quota/screens/quota_exhausted_screen.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../models/keyframe_curve_presets.dart';
import '../models/timeline_models.dart';
import '../models/export_settings.dart';
import '../models/asset_pack_models.dart';
import '../models/element_library_asset.dart';
import '../models/discover_models.dart';
import '../models/editor_effect_models.dart';
import '../models/sound_effect_library_asset.dart';
import '../providers/editor_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/subtitle_provider.dart';
import '../services/timeline_keyframe_editing.dart';
import 'creator_lab_screen.dart';
import 'export_video_screen.dart';
import '../widgets/export_dialog.dart';
import '../widgets/element_library_sheet.dart';
import '../widgets/effect_stack_editor_sheet.dart';
import '../widgets/discover_sheet.dart';
import '../widgets/subtitle_edit_modal.dart';
import '../widgets/subtitle_style_panel.dart';
import '../widgets/timeline_panel.dart';
import '../widgets/text_clip_editor_sheet.dart';
import '../widgets/video_preview_panel.dart';
import '../widgets/resizable_editor_sheet.dart';
import '../widgets/sfx_library_sheet.dart';
import '../widgets/keyframe_graph_editor.dart';
import '../widgets/advanced_color_controls.dart';
import '../widgets/video_scopes_panel.dart';

String _audioFadeShapeLabel(AudioFadeShape shape) {
  return switch (shape) {
    AudioFadeShape.linear => 'Linear',
    AudioFadeShape.logarithmic => 'Logarithmic',
    AudioFadeShape.exponential => 'Exponential',
    AudioFadeShape.sCurve => 'Smooth S-curve',
  };
}

double _linearGainToDb(double gain) {
  if (gain <= 0.001) return -60;
  return (20 * math.log(gain) / math.ln10).clamp(-60.0, 6.0).toDouble();
}

double _dbToLinearGain(double decibels) {
  if (decibels <= -60) return 0;
  return math.pow(10, decibels.clamp(-60.0, 6.0) / 20).toDouble();
}

@visibleForTesting
EditorTimeline applyAudioCrossfadeForTesting({
  required EditorTimeline timeline,
  required String firstClipId,
  required String secondClipId,
  required Duration duration,
}) {
  if (firstClipId == secondClipId) {
    throw ArgumentError('Select two different audio clips.');
  }
  (TimelineTrack, TimelineClip)? locate(String id) {
    for (final track in timeline.tracks) {
      for (final clip in track.clips) {
        if (clip.id == id) return (track, clip);
      }
    }
    return null;
  }

  var first = locate(firstClipId);
  var second = locate(secondClipId);
  if (first == null || second == null) {
    throw ArgumentError('Both crossfade clips must still exist.');
  }
  if (first.$2.startTime > second.$2.startTime) {
    final swap = first;
    first = second;
    second = swap;
  }
  if (first.$1.isLocked || second.$1.isLocked) {
    throw StateError('Unlock both audio tracks before crossfading.');
  }
  if (first.$2.type != TimelineTrackType.audio ||
      second.$2.type != TimelineTrackType.audio) {
    throw StateError('Crossfades require two independent audio clips.');
  }
  if (first.$2.linkedClipId != null || second.$2.linkedClipId != null) {
    throw StateError('Unlink separated video audio before crossfading it.');
  }
  final maximumMs = math.min(
    first.$2.duration.inMilliseconds ~/ 2,
    second.$2.duration.inMilliseconds ~/ 2,
  );
  if (maximumMs <= 0) throw StateError('The selected clips are too short.');
  final fadeMs = duration.inMilliseconds.clamp(1, maximumMs).toInt();
  final fadeDuration = Duration(milliseconds: fadeMs);
  final movedSecond = second.$2.copyWith(
    startTime: first.$2.endTime - fadeDuration,
    endTime: first.$2.endTime - fadeDuration + second.$2.duration,
    audioMix: second.$2.audioMix.copyWith(
      fadeInMs: fadeMs,
      fadeInShape: AudioFadeShape.sCurve,
      clearLoudnessAnalysis: true,
    ),
  );
  var tracks = timeline.tracks.map((track) {
    final clips = <TimelineClip>[];
    for (final clip in track.clips) {
      if (clip.id == second!.$2.id) continue;
      clips.add(
        clip.id == first!.$2.id
            ? clip.copyWith(
                audioMix: clip.audioMix.copyWith(
                  fadeOutMs: fadeMs,
                  fadeOutShape: AudioFadeShape.sCurve,
                  clearLoudnessAnalysis: true,
                ),
              )
            : clip,
      );
    }
    return track.copyWith(clips: clips);
  }).toList();

  TimelineTrack? destination;
  for (final track in tracks) {
    if (track.id == first.$1.id ||
        track.isLocked ||
        track.section != TimelineTrackSection.audio ||
        track.role != TimelineTrackRole.regular ||
        !track.acceptsClipType(TimelineTrackType.audio)) {
      continue;
    }
    final candidate = movedSecond.copyWith(trackId: track.id);
    if (track.canPlaceClip(candidate)) {
      destination = track;
      break;
    }
  }
  var working = timeline.copyWith(tracks: tracks);
  if (destination == null) {
    destination = TimelineTrack(
      name: timeline.nextTrackNameForSection(TimelineTrackSection.audio),
      type: TimelineTrackType.audio,
      section: TimelineTrackSection.audio,
    );
    working = working.insertTrackUsingEditorRules(destination);
    tracks = working.tracks;
  }
  final destinationId = destination.id;
  tracks = tracks.map((track) {
    if (track.id != destinationId) return track;
    return track.copyWith(
      clips: [...track.clips, movedSecond.copyWith(trackId: destinationId)]
        ..sort((a, b) => a.startTime.compareTo(b.startTime)),
    );
  }).toList();
  return working.copyWith(tracks: tracks);
}

@visibleForTesting
EditorTimeline fitAudioClipToDurationForTesting({
  required EditorTimeline timeline,
  required String clipId,
  required Duration targetDuration,
}) {
  TimelineTrack? sourceTrack;
  TimelineClip? sourceClip;
  for (final track in timeline.tracks) {
    for (final clip in track.clips) {
      if (clip.id == clipId) {
        sourceTrack = track;
        sourceClip = clip;
        break;
      }
    }
    if (sourceClip != null) break;
  }
  if (sourceTrack == null || sourceClip == null) {
    throw ArgumentError('The audio clip no longer exists.');
  }
  if (sourceTrack.isLocked || sourceClip.type != TimelineTrackType.audio) {
    throw StateError('Select an unlocked independent audio clip.');
  }
  if (targetDuration <= Duration.zero) {
    throw ArgumentError('Target duration must be greater than zero.');
  }
  final sourceSpanUs = sourceClip.sourceDuration > Duration.zero
      ? sourceClip.sourceDuration.inMicroseconds
      : (sourceClip.duration.inMicroseconds * sourceClip.playbackRate).round();
  final stretch =
      sourceSpanUs /
      math.max(1, targetDuration.inMicroseconds) /
      sourceClip.playbackRate;
  if (stretch < 0.25 || stretch > 4) {
    throw StateError(
      'This target requires ${stretch.toStringAsFixed(2)}× stretching; '
      'choose a duration within the supported 0.25×–4× range.',
    );
  }
  final oldDuration = sourceClip.duration;
  final updated = sourceClip.copyWith(
    endTime: sourceClip.startTime + targetDuration,
    audioMix: sourceClip.audioMix.copyWith(
      timeStretch: stretch,
      preservePitch: true,
      clearLoudnessAnalysis: true,
    ),
    keyframes: sourceClip.keyframes
        .map(
          (keyframe) => keyframe.copyWith(
            time: Duration(
              microseconds:
                  (keyframe.time.inMicroseconds *
                          targetDuration.inMicroseconds /
                          math.max(1, oldDuration.inMicroseconds))
                      .round(),
            ),
          ),
        )
        .toList(),
    effectStack: sourceClip.effectStack.retimed(oldDuration, targetDuration),
  );
  if (!sourceTrack.canPlaceClip(updated, ignoringClipId: sourceClip.id)) {
    throw StateError('The fitted clip would overlap another clip.');
  }
  return timeline.copyWith(
    tracks: timeline.tracks.map((track) {
      if (track.id != sourceTrack!.id) return track;
      return track.copyWith(
        clips: track.clips
            .map((clip) => clip.id == sourceClip!.id ? updated : clip)
            .toList(),
      );
    }).toList(),
  );
}

@visibleForTesting
EditorTimeline unlinkSeparatedAudioForTesting({
  required EditorTimeline timeline,
  required String audioClipId,
}) {
  return timeline.copyWith(
    tracks: timeline.tracks.map((track) {
      if (track.isLocked) return track;
      return track.copyWith(
        clips: track.clips.map((clip) {
          if (clip.id != audioClipId ||
              clip.type != TimelineTrackType.audio ||
              clip.linkedClipId == null) {
            return clip;
          }
          return clip.copyWith(clearLinkedClipId: true);
        }).toList(),
      );
    }).toList(),
  );
}

@visibleForTesting
EditorTimeline relinkSeparatedAudioForTesting({
  required EditorTimeline timeline,
  required String audioClipId,
  required String videoClipId,
}) {
  TimelineTrack? audioTrack;
  TimelineClip? audio;
  TimelineTrack? videoTrack;
  TimelineClip? video;
  for (final track in timeline.tracks) {
    for (final clip in track.clips) {
      if (clip.id == audioClipId) {
        audioTrack = track;
        audio = clip;
      }
      if (clip.id == videoClipId) {
        videoTrack = track;
        video = clip;
      }
    }
  }
  if (audioTrack == null ||
      audio == null ||
      videoTrack == null ||
      video == null) {
    throw ArgumentError('The source audio or video clip no longer exists.');
  }
  if (audioTrack.isLocked || videoTrack.isLocked) {
    throw StateError('Unlock both tracks before relinking audio.');
  }
  if (audio.type != TimelineTrackType.audio ||
      video.type != TimelineTrackType.video ||
      audio.assetId == null ||
      audio.assetId != video.assetId) {
    throw StateError('Audio can only be relinked to its source video asset.');
  }
  for (final track in timeline.tracks) {
    for (final candidate in track.clips) {
      if (candidate.id != audio.id && candidate.linkedClipId == video.id) {
        throw StateError('That video already has a separated audio clip.');
      }
    }
  }
  final linkedAudio = syncSeparatedAudioTransport(
    audio: audio,
    updatedVideo: video,
    linkedClipId: video.id,
  );
  return timeline.copyWith(
    tracks: timeline.tracks.map((track) {
      return track.copyWith(
        clips: track.clips.map((clip) {
          if (clip.id == audio!.id) return linkedAudio;
          if (clip.id == video!.id) {
            return clip.copyWith(audioMix: clip.audioMix.copyWith(muted: true));
          }
          return clip;
        }).toList(),
      );
    }).toList(),
  );
}

@visibleForTesting
EditorTimeline reattachSeparatedAudioForTesting({
  required EditorTimeline timeline,
  required String audioClipId,
}) {
  TimelineTrack? audioTrack;
  TimelineClip? audio;
  for (final track in timeline.tracks) {
    final candidate = track.clips
        .where((clip) => clip.id == audioClipId)
        .firstOrNull;
    if (candidate != null) {
      audioTrack = track;
      audio = candidate;
      break;
    }
  }
  final videoId = audio?.linkedClipId;
  if (audioTrack == null || audio == null || videoId == null) {
    throw StateError('Relink this audio to its source video first.');
  }
  TimelineTrack? videoTrack;
  TimelineClip? video;
  for (final track in timeline.tracks) {
    final candidate = track.clips
        .where((clip) => clip.id == videoId)
        .firstOrNull;
    if (candidate != null) {
      videoTrack = track;
      video = candidate;
      break;
    }
  }
  if (videoTrack == null ||
      video == null ||
      audioTrack.isLocked ||
      videoTrack.isLocked) {
    throw StateError('Unlock the linked audio and video tracks first.');
  }
  final bus = audioTrack.audioBusId == null
      ? null
      : timeline.audioBuses
            .where((candidate) => candidate.id == audioTrack!.audioBusId)
            .firstOrNull;
  final routedEffects = <EditorEffect>[
    ...audio.effectStack.effects,
    ...audioTrack.effectStack.effects.where(
      (effect) => effect.type.domain == EditorEffectDomain.audio,
    ),
    ...?bus?.effectStack.effects.where(
      (effect) => effect.type.domain == EditorEffectDomain.audio,
    ),
  ];
  final usedIds = <String>{
    for (final effect in video.effectStack.effects)
      if (effect.type.domain == EditorEffectDomain.visual) effect.id,
  };
  final mergedAudioEffects = <EditorEffect>[];
  for (final effect in routedEffects) {
    final resolved = usedIds.add(effect.id) ? effect : effect.cloneWithNewId();
    usedIds.add(resolved.id);
    mergedAudioEffects.add(resolved);
  }
  final routeGain = (audioTrack.audioGain * (bus?.gain ?? 1)).clamp(0.0, 4.0);
  final routePan = (audio.audioMix.pan + audioTrack.audioPan + (bus?.pan ?? 0))
      .clamp(-1.0, 1.0)
      .toDouble();
  final restoredMix = audio.audioMix.copyWith(
    volume: (audio.audioMix.volume * routeGain).clamp(0.0, 2.0),
    pan: routePan,
    muted: audio.audioMix.muted || audioTrack.isMuted || bus?.muted == true,
    clearLoudnessAnalysis: true,
  );
  final restoredVideo = video.copyWith(
    audioMix: restoredMix,
    effectStack: EditorEffectStack(
      effects: [
        ...video.effectStack.effects.where(
          (effect) => effect.type.domain == EditorEffectDomain.visual,
        ),
        ...mergedAudioEffects,
      ],
    ),
    autoDuck: audio.autoDuck,
    duckAmount: audio.duckAmount,
    duckAttackMs: audio.duckAttackMs,
    duckReleaseMs: audio.duckReleaseMs,
    duckSidechainTrackIds: audio.duckSidechainTrackIds,
    denoise: audio.denoise,
    keyframes: [
      ...video.keyframes.where(
        (keyframe) => keyframe.property != TimelineKeyframeProperty.volume,
      ),
      ...audio.keyframes
          .where(
            (keyframe) => keyframe.property == TimelineKeyframeProperty.volume,
          )
          .map(
            (keyframe) => keyframe.copyWith(
              value: (keyframe.value * routeGain).clamp(0.0, 2.0),
            ),
          ),
    ],
  );
  return timeline.copyWith(
    tracks: timeline.tracks.map((track) {
      return track.copyWith(
        clips: track.clips
            .where((clip) => clip.id != audioClipId)
            .map((clip) => clip.id == restoredVideo.id ? restoredVideo : clip)
            .toList(),
      );
    }).toList(),
  );
}

String _audioChannelModeLabel(EditorAudioChannelMode mode) {
  return switch (mode) {
    EditorAudioChannelMode.stereo => 'Stereo',
    EditorAudioChannelMode.mono => 'Stereo to mono',
    EditorAudioChannelMode.dualMono => 'Dual mono',
    EditorAudioChannelMode.leftOnly => 'Left channel only',
    EditorAudioChannelMode.rightOnly => 'Right channel only',
  };
}

Map<String, dynamic> _editorMediaMetadata(Map<String, dynamic> mediaInfo) {
  const persistedKeys = <String>{
    'durationMs',
    'width',
    'height',
    'frameRate',
    'hasAudio',
    'audioStreamCount',
    'audioStreams',
    'audioChannels',
    'colorPrimaries',
    'colorTransfer',
    'colorSpace',
    'colorRange',
    'pixelFormat',
    'bitDepth',
  };
  return <String, dynamic>{
    for (final entry in mediaInfo.entries)
      if (persistedKeys.contains(entry.key) && entry.value != null)
        entry.key: entry.value,
  };
}

Duration _sourcePositionForTimelineClip(
  TimelineClip clip,
  Duration timelinePosition,
) {
  if (clip.freezeFrame) return clip.effectiveFreezeFrameSourceTime;
  final elapsedMs = (timelinePosition - clip.startTime).inMilliseconds.clamp(
    0,
    clip.duration.inMilliseconds,
  );
  final forwardOffsetMs = (elapsedMs * clip.playbackRate).round();
  if (!clip.isReversed) {
    return clip.sourceStartTime + Duration(milliseconds: forwardOffsetMs);
  }
  final spanMs = clip.sourceDuration.inMilliseconds > 0
      ? clip.sourceDuration.inMilliseconds
      : (clip.duration.inMilliseconds * clip.playbackRate).round();
  final reversedOffsetMs = (spanMs - forwardOffsetMs - 1)
      .clamp(0, math.max(0, spanMs - 1))
      .toInt();
  return clip.sourceStartTime + Duration(milliseconds: reversedOffsetMs);
}

String _editorColorSpaceLabel(EditorColorSpace space) {
  return switch (space) {
    EditorColorSpace.automatic => 'Automatic',
    EditorColorSpace.sdr709 => 'SDR / Rec.709',
    EditorColorSpace.log => 'Camera Log',
    EditorColorSpace.hlg => 'HLG / Rec.2020',
    EditorColorSpace.pq => 'PQ / HDR10',
    EditorColorSpace.wideGamut => 'Wide gamut / Rec.2020',
  };
}

/// Resolves the default mix for media inserted into a visual timeline lane.
///
/// Video keeps its embedded audio attached when probing reports an audio
/// stream. Creating an independent audio lane is reserved for the editor's
/// explicit "Separate audio" action.
AudioMixSettings resolveTimelineInsertionAudioMix({
  required EditorAssetType assetType,
  required TimelineTrackSection section,
  required Map<String, dynamic> metadata,
  bool enableEmbeddedAudio = false,
}) {
  final isVisualVideo =
      assetType == EditorAssetType.video &&
      (section == TimelineTrackSection.overlay ||
          section == TimelineTrackSection.baseVideo);
  if (!isVisualVideo) return const AudioMixSettings();
  final hasEmbeddedAudio = metadata['hasAudio'] == true;
  return AudioMixSettings(
    muted: !(enableEmbeddedAudio || hasEmbeddedAudio),
    volume: 1,
  );
}

/// True when a separated audio clip still shares the video's transport and
/// source window. Only these exact links follow destructive timing changes;
/// independently moved or trimmed audio is preserved as its own edit.
bool isExactSeparatedAudioTransportMirror({
  required TimelineClip video,
  required TimelineClip audio,
}) {
  return video.type == TimelineTrackType.video &&
      audio.type == TimelineTrackType.audio &&
      audio.linkedClipId == video.id &&
      audio.assetId == video.assetId &&
      audio.startTime == video.startTime &&
      audio.endTime == video.endTime &&
      audio.sourceStartTime == video.sourceStartTime &&
      audio.sourceDuration == video.sourceDuration &&
      (audio.playbackRate - video.playbackRate).abs() < 0.0001 &&
      audio.isReversed == video.isReversed;
}

({TimelineTrack track, TimelineClip clip})? resolveEffectiveAudioOwner({
  required EditorTimeline timeline,
  required TimelineClip clip,
}) {
  if (clip.type == TimelineTrackType.video) {
    for (final track in timeline.tracks) {
      for (final candidate in track.clips) {
        if (candidate.type == TimelineTrackType.audio &&
            candidate.linkedClipId == clip.id) {
          return (track: track, clip: candidate);
        }
      }
    }
  }
  for (final track in timeline.tracks) {
    final live = track.clips.where((candidate) => candidate.id == clip.id);
    if (live.isNotEmpty) return (track: track, clip: live.first);
  }
  return null;
}

TimelineClip syncSeparatedAudioTransport({
  required TimelineClip audio,
  required TimelineClip updatedVideo,
  String? linkedClipId,
}) {
  return audio.copyWith(
    linkedClipId: linkedClipId ?? updatedVideo.id,
    startTime: updatedVideo.startTime,
    endTime: updatedVideo.endTime,
    sourceStartTime: updatedVideo.sourceStartTime,
    sourceDuration: updatedVideo.sourceDuration,
    playbackRate: updatedVideo.playbackRate,
    isReversed: updatedVideo.isReversed,
  );
}

TimelineClip restoreAttachedAudioForDuplicate({
  required TimelineClip duplicateVideo,
  required TimelineClip separatedAudio,
}) {
  return duplicateVideo.copyWith(
    audioMix: separatedAudio.audioMix,
    autoDuck: separatedAudio.autoDuck,
    duckAmount: separatedAudio.duckAmount,
    duckAttackMs: separatedAudio.duckAttackMs,
    duckReleaseMs: separatedAudio.duckReleaseMs,
    duckSidechainTrackIds: separatedAudio.duckSidechainTrackIds,
    denoise: separatedAudio.denoise,
  );
}

({TimelineClip left, TimelineClip right}) splitExactSeparatedAudioMirror({
  required TimelineClip originalVideo,
  required TimelineClip leftVideo,
  required TimelineClip rightVideo,
  required TimelineClip audio,
  required String rightAudioId,
  required Duration splitAt,
}) {
  if (!isExactSeparatedAudioTransportMirror(
    video: originalVideo,
    audio: audio,
  )) {
    throw ArgumentError('Audio is not an exact transport mirror of the video.');
  }

  final splitOffset = splitAt - originalVideo.startTime;
  final keyframeSplit = TimelineKeyframeEditing.split(audio, splitOffset);
  final effectStackSplit = audio.effectStack.splitAt(splitOffset);

  final left =
      syncSeparatedAudioTransport(
        audio: audio,
        updatedVideo: leftVideo,
        linkedClipId: leftVideo.id,
      ).copyWith(
        keyframes: keyframeSplit.leading,
        effectStack: effectStackSplit.leading,
        outroTransition: const ClipTransition(),
        audioMix: audio.audioMix.copyWith(fadeOutMs: 0),
      );
  final right =
      syncSeparatedAudioTransport(
        audio: audio.copyWith(
          id: rightAudioId,
          effectStack: effectStackSplit.trailing,
        ),
        updatedVideo: rightVideo,
        linkedClipId: rightVideo.id,
      ).copyWith(
        keyframes: keyframeSplit.trailing,
        introTransition: const ClipTransition(),
        audioMix: audio.audioMix.copyWith(fadeInMs: 0),
      );
  return (left: left, right: right);
}

/// A source-specific caption lane decision.
///
/// Caption generation never shares a lane with another source. Legacy mixed
/// lanes are repaired when the generated captions are committed. A locked lane
/// that already contains captions for this source blocks replacement so lock
/// semantics are never bypassed.
class CaptionTrackRouting {
  const CaptionTrackRouting({this.destination, this.blockingTrack});

  final TimelineTrack? destination;
  final TimelineTrack? blockingTrack;

  bool get isBlocked => blockingTrack != null;
}

CaptionTrackRouting resolveCaptionTrackRouting({
  required EditorTimeline timeline,
  required TimelineClip sourceClip,
}) {
  final captionTracks = timeline.tracks
      .where(
        (track) =>
            track.type == TimelineTrackType.subtitle &&
            track.section == TimelineTrackSection.textSubtitle,
      )
      .toList(growable: false);
  final sourceTracks = captionTracks
      .where(
        (track) =>
            track.clips.any((clip) => clip.linkedClipId == sourceClip.id),
      )
      .toList(growable: false);
  final blockingTrack = sourceTracks
      .where((track) => track.isLocked)
      .firstOrNull;
  if (blockingTrack != null) {
    return CaptionTrackRouting(blockingTrack: blockingTrack);
  }

  final dedicatedTrack = sourceTracks
      .where(
        (track) =>
            !track.isLocked &&
            track.clips.isNotEmpty &&
            track.clips.every((clip) => clip.linkedClipId == sourceClip.id),
      )
      .firstOrNull;
  if (dedicatedTrack != null) {
    return CaptionTrackRouting(destination: dedicatedTrack);
  }

  final emptyTrack = captionTracks
      .where(
        (track) =>
            !track.isLocked &&
            track.clips.isEmpty &&
            track.acceptsClipType(TimelineTrackType.subtitle),
      )
      .firstOrNull;
  if (emptyTrack != null) {
    return CaptionTrackRouting(destination: emptyTrack);
  }

  return CaptionTrackRouting(
    destination: TimelineTrack(
      name: captionTrackNameForSource(sourceClip.label),
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
    ),
  );
}

String captionTrackNameForSource(String sourceLabel) {
  final trimmed = sourceLabel.trim();
  final safe = trimmed.isEmpty ? 'media' : trimmed;
  final compact = safe.length > 28 ? '${safe.substring(0, 27)}…' : safe;
  return 'Captions · $compact';
}

/// Resolves the exact local media used for source-specific transcription.
/// Only legacy base-video clips may use the project-level compatibility path;
/// an overlay must never silently transcribe the base layer instead.
String resolveCaptionMediaPath({
  required EditorTimeline timeline,
  required TimelineClip sourceClip,
  required String legacyBaseVideoPath,
}) {
  final assetPath = timeline.assetForClip(sourceClip)?.sourcePath?.trim();
  if (assetPath != null && assetPath.isNotEmpty) return assetPath;
  final sourceTrack = timeline.tracks
      .where((track) => track.clips.any((clip) => clip.id == sourceClip.id))
      .firstOrNull;
  if (sourceTrack?.section == TimelineTrackSection.baseVideo &&
      sourceClip.type == TimelineTrackType.video) {
    return legacyBaseVideoPath.trim();
  }
  return '';
}

/// Replaces captions for exactly one media source while preserving every
/// other source's lane and link identity.
EditorTimeline replaceGeneratedCaptionsForSource({
  required EditorTimeline timeline,
  required TimelineClip sourceClip,
  required TimelineTrack destinationTrack,
  required List<SubtitleEntry> generatedEntries,
}) {
  final generatedClips = generatedEntries
      .map(
        (entry) => TimelineClip.fromSubtitleEntry(
          entry,
          trackId: destinationTrack.id,
          linkedClipId: sourceClip.id,
        ),
      )
      .toList(growable: false);
  var foundDestination = false;
  final nextTracks = timeline.tracks.map((track) {
    if (track.type != TimelineTrackType.subtitle) return track;
    final clipsWithoutSource = track.clips
        .where((clip) => clip.linkedClipId != sourceClip.id)
        .toList();
    if (track.id != destinationTrack.id) {
      return track.copyWith(clips: clipsWithoutSource);
    }
    foundDestination = true;
    return track.copyWith(
      name: captionTrackNameForSource(sourceClip.label),
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      clips: [...clipsWithoutSource, ...generatedClips]
        ..sort((a, b) => a.startTime.compareTo(b.startTime)),
    );
  }).toList();

  var nextTimeline = timeline.copyWith(tracks: nextTracks);
  if (!foundDestination) {
    nextTimeline = nextTimeline.insertTrackUsingEditorRules(
      destinationTrack.copyWith(
        name: captionTrackNameForSource(sourceClip.label),
        type: TimelineTrackType.subtitle,
        section: TimelineTrackSection.textSubtitle,
        clips: generatedClips,
      ),
    );
  }
  return nextTimeline;
}

/// Main editor screen with 3-panel layout:
/// Video Preview (top-left), Style Panel (top-right), Timeline (bottom).
class EditorScreen extends ConsumerStatefulWidget {
  final Project project;

  const EditorScreen({super.key, required this.project});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

enum _CanvasAspectRatio { original, ratio16x9, ratio9x16, ratio1x1, ratio4x5 }

enum _OverlayAddOption { photos, videos, elements }

enum _TextAddOption { addText, subtitles }

enum _AudioAddOption { localTrack, sfx, music }

enum _LastVisualAction { cancel, replace }

enum _BottomActionCategory {
  edit,
  effects,
  keyframes,
  audio,
  text,
  timeline,
  canvas,
  studio,
  discover,
}

enum _BottomActionSubgroup {
  editTiming,
  editTransform,
  editDetails,
  effectsStack,
  effectsColor,
  effectsLuts,
  effectsBlur,
  effectsMotion,
  effectsKeyframes,
  effectsEnhance,
  keyframeControls,
  keyframeCurves,
  keyframeProperties,
  audioMix,
  audioEffects,
  audioCleanup,
  audioAutomation,
  textObjects,
  textCaptions,
  textFiles,
  timelineSelection,
  timelineTracks,
  timelineMarkers,
  timelineProject,
}

class _EditorScreenState extends ConsumerState<EditorScreen>
    with WidgetsBindingObserver {
  static const double _editorDockContentHeight = 72;

  Timer? _saveDebounce;
  Timer? _remoteSaveDebounce;
  bool _isSavingProject = false;
  Project? _queuedProjectSnapshot;
  bool _queuedRemoteSync = false;
  String? _queuedUserUid;
  String _queuedChangeType = 'queued_editor_change';
  Future<void>? _activeProjectSave;
  DateTime? _lastSavedAt;
  Object? _localSaveError;
  bool _remoteSyncPending = false;
  bool _isClosing = false;
  bool _editorInitialized = false;
  bool _isInitializingEditor = true;
  Object? _editorInitializationError;
  String? _currentUserUid;
  late Project _projectSnapshot;
  _CanvasAspectRatio _canvasAspectRatio = _CanvasAspectRatio.original;
  _BottomActionCategory? _activeBottomCategory;
  _BottomActionSubgroup? _activeBottomSubgroup;
  final GlobalKey _previewKey = GlobalKey(debugLabel: 'editor-video-preview');
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  PersistentBottomSheetController? _textEditorSheetController;
  bool _isPreviewFullscreen = false;
  bool _isGeneratingSubtitles = false;
  String? _analyzingAudioClipId;
  TimelineClip? _clipAttributeClipboard;

  @override
  void initState() {
    super.initState();
    _projectSnapshot = widget.project;
    _currentUserUid = ref.read(currentUserProvider)?.uid;
    _canvasAspectRatio = _canvasAspectRatioFromPreset(
      widget.project.timeline.canvasSettings.aspectRatioPreset,
    );
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeEditor();
    });
  }

  void _initializeEditor() {
    if (!mounted || _editorInitialized) return;

    try {
      final initialStyle = widget.project.editorGlobalStyle;
      final didNormalizeLegacyStyle =
          initialStyle.fontSize != widget.project.globalStyle.fontSize ||
          initialStyle.maxWidthFactor !=
              widget.project.globalStyle.maxWidthFactor;
      final didUpgradeProjectSchema =
          widget.project.projectSchemaVersion < Project.currentSchemaVersion;
      final initialTimeline = widget.project.timeline.mergeSubtitleEntries(
        subtitles: widget.project.subtitles,
        globalStyle: initialStyle,
      );

      ref
          .read(subtitleProvider.notifier)
          .initializeFromProject(
            entries: widget.project.subtitles,
            globalStyle: initialStyle,
          );
      ref
          .read(editorProvider.notifier)
          .loadProject(
            videoPath: widget.project.videoPath,
            projectId: widget.project.id,
            projectName: widget.project.name,
            timeline: initialTimeline,
          );
      _projectSnapshot = widget.project.copyWith(
        projectSchemaVersion: Project.currentSchemaVersion,
        globalStyle: initialStyle,
        timeline: initialTimeline,
      );

      if (!mounted) return;
      setState(() {
        _editorInitialized = true;
        _isInitializingEditor = false;
        _editorInitializationError = null;
      });
      if (didUpgradeProjectSchema) {
        _scheduleProjectSave(
          changeType: didNormalizeLegacyStyle
              ? 'subtitle_style_migrated'
              : 'project_schema_migrated',
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Editor initialization failed: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _isInitializingEditor = false;
        _editorInitializationError = error;
      });
    }
  }

  @override
  void dispose() {
    // Riverpod invalidates ConsumerState.ref before State.dispose is invoked.
    // Provider listeners and PopScope keep this snapshot current while mounted,
    // so disposal must only use cached values.
    final finalSnapshot = _projectSnapshot;
    final userUid = _currentUserUid;
    _isClosing = true;
    _saveDebounce?.cancel();
    _remoteSaveDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_isPreviewFullscreen) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    unawaited(
      _saveProjectState(
        project: finalSnapshot,
        userUid: userUid,
        syncRemote: false,
        changeType: 'editor_disposed',
      ),
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        _flushProjectSave(
          syncRemote: false,
          changeType: 'app_lifecycle_$state',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _currentUserUid = ref.watch(currentUserProvider)?.uid;
    if (!_editorInitialized) {
      return _buildEditorStartup();
    }

    final editorState = ref.watch(editorProvider);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final selectedClip = _selectedClipFromState(editorState);

    ref.listen(subtitleProvider, (prev, next) {
      final entriesChanged = prev?.entries != next.entries;
      final styleChanged = prev?.globalStyle != next.globalStyle;
      if (entriesChanged || styleChanged) {
        _scheduleProjectSave(
          changeType: entriesChanged ? 'subtitles_changed' : 'style_changed',
        );
      }
    });
    ref.listen(editorProvider.select((state) => state.timeline), (prev, next) {
      if (prev != null && prev != next) {
        _scheduleProjectSave(changeType: 'timeline_changed');
      }
    });

    return PopScope(
      canPop: !_isPreviewFullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isPreviewFullscreen) {
          _setPreviewFullscreen(false);
          return;
        }
        if (didPop) {
          unawaited(
            _flushProjectSave(syncRemote: false, changeType: 'editor_popped'),
          );
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: kBackground,
        // Text editing manages the keyboard inside its bottom sheet. Keeping
        // the canvas at its normal size prevents the video preview collapsing
        // to a thumbnail while the user types.
        resizeToAvoidBottomInset: false,
        appBar: _isPreviewFullscreen ? null : _buildEditorToolbar(context),
        body: _isPreviewFullscreen
            ? _buildFullscreenPreview()
            : isLandscape
            ? _buildLandscape(context, selectedClip)
            : _buildPortrait(context, selectedClip),
      ),
    );
  }

  Widget _buildEditorStartup() {
    final error = _editorInitializationError;
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        backgroundColor: kBackground,
        title: Text(
          widget.project.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: error == null
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 18),
                      Text(
                        'Opening editor…',
                        style: TextStyle(
                          color: kTextSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        color: kError,
                        size: 40,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'This project could not be prepared for editing.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: kTextPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        error.toString().replaceFirst('Exception: ', ''),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: kTextSecondary),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _isInitializingEditor
                            ? null
                            : () {
                                setState(() {
                                  _isInitializingEditor = true;
                                  _editorInitializationError = null;
                                });
                                _initializeEditor();
                              },
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try again'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildEditorToolbar(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 560;
    final phoneToolbar = width < 480;

    return AppBar(
      toolbarHeight: 62,
      leadingWidth: 48,
      titleSpacing: 0,
      backgroundColor: kBackground,
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1),
      ),
      title: Row(
        children: [
          if (!phoneToolbar)
            Container(
              width: 31,
              height: 31,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: kAccent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(
                Icons.content_cut_rounded,
                color: kOnAccent,
                size: 17,
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.project.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: kTextPrimary,
                      fontSize: compact ? 13 : 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.25,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _localSaveError != null
                              ? kError
                              : _isSavingProject
                              ? kWarning
                              : _remoteSyncPending
                              ? kInfo
                              : kSuccess,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _localSaveError != null
                              ? 'LOCAL SAVE FAILED'
                              : _isSavingProject
                              ? 'SAVING LOCALLY'
                              : _remoteSyncPending
                              ? 'LOCAL SAVED · SYNC PENDING'
                              : _lastSavedAt == null
                              ? 'AUTOSAVE READY'
                              : 'SAVED LOCALLY',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kTextSecondary,
                            fontSize: 7.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.85,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: EdgeInsets.fromLTRB(8, 10, compact ? 8 : 12, 10),
          child: FilledButton.icon(
            key: const ValueKey('editor_export_button'),
            onPressed: _showExportDialog,
            style: FilledButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: compact ? 11 : 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.file_upload_outlined, size: 17),
            label: const Text('Export'),
          ),
        ),
      ],
    );
  }

  TimelineClip? _toolSelectedClip() {
    return _selectedClipFromState(ref.read(editorProvider));
  }

  bool _toggleSelectedClipFlag(
    TimelineClip Function(TimelineClip) mapper, {
    bool Function(TimelineClip clip, EditorTimeline timeline)? supports,
    String unsupportedMessage = 'This tool does not support the selected clip.',
  }) {
    final clip = _toolSelectedClip();
    if (clip == null) {
      SnackBarHelper.showInfo(context, 'Select a clip first.');
      return false;
    }
    final timeline = ref.read(editorProvider).timeline;
    if (supports != null && !supports(clip, timeline)) {
      SnackBarHelper.showInfo(context, unsupportedMessage);
      return false;
    }
    final changed = ref
        .read(editorProvider.notifier)
        .updateClip(clip.id, mapper);
    if (!changed) {
      SnackBarHelper.showInfo(context, 'Unlock the selected track first.');
    }
    return changed;
  }

  void _toggleSelectedFreezeFrame() {
    final clip = _toolSelectedClip();
    if (clip == null) {
      SnackBarHelper.showInfo(context, 'Select a video clip first.');
      return;
    }
    if (clip.type != TimelineTrackType.video &&
        clip.type != TimelineTrackType.gif) {
      SnackBarHelper.showInfo(
        context,
        'Freeze frame requires a video or animated GIF clip.',
      );
      return;
    }
    if (clip.freezeFrame) {
      _toggleSelectedClipFlag(
        (current) => current.copyWith(
          freezeFrame: false,
          clearFreezeFrameSourceTime: true,
        ),
      );
      return;
    }

    final position = ref.read(playbackProvider).position;
    if (position < clip.startTime || position > clip.endTime) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead inside the selected clip first.',
      );
      return;
    }
    final elapsedMs = (position - clip.startTime).inMilliseconds.clamp(
      0,
      clip.duration.inMilliseconds,
    );
    final forwardOffsetMs = (elapsedMs * clip.playbackRate).round();
    final declaredSpanMs = clip.sourceDuration.inMilliseconds;
    final spanMs = declaredSpanMs > 0
        ? declaredSpanMs
        : math.max(
            1,
            (clip.duration.inMilliseconds * clip.playbackRate).round(),
          );
    final sourceOffsetMs = clip.isReversed
        ? (spanMs - forwardOffsetMs - 1).clamp(0, math.max(0, spanMs - 1))
        : forwardOffsetMs.clamp(0, math.max(0, spanMs - 1));
    final sourceTime =
        clip.sourceStartTime + Duration(milliseconds: sourceOffsetMs.toInt());
    final changed = _toggleSelectedClipFlag(
      (current) => current.copyWith(
        freezeFrame: true,
        freezeFrameSourceTime: sourceTime,
      ),
      supports: (candidate, _) =>
          candidate.type == TimelineTrackType.video ||
          candidate.type == TimelineTrackType.gif,
      unsupportedMessage: 'Freeze frame requires video or animated GIF media.',
    );
    if (changed) {
      SnackBarHelper.showSuccess(
        context,
        'Frame held at ${_formatEditorDuration(sourceTime)}.',
      );
    }
  }

  Future<void> _openSelectedChromaKeySheet() async {
    final clip = _toolSelectedClip();
    if (clip == null || !clip.supportsChromaKey) {
      SnackBarHelper.showInfo(
        context,
        'Select an image, GIF, or video layer first.',
      );
      return;
    }
    final track = _trackForClip(clip, ref.read(editorProvider));
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the selected track first.');
      return;
    }
    var liveClip = clip;
    const keyColors = [
      Color(0xFF00FF00),
      Color(0xFF00A651),
      Color(0xFF0000FF),
      Color(0xFFFF00FF),
      Color(0xFFFFFFFF),
      Color(0xFF000000),
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(
            TimelineClip Function(TimelineClip current) mapper, {
            bool recordHistory = true,
          }) {
            _updateTimelineClip(liveClip, mapper, recordHistory: recordHistory);
            final latest = _clipById(liveClip.id, ref.read(editorProvider));
            if (latest != null) setSheetState(() => liveClip = latest);
          }

          return _buildEditorSheet(
            title: 'Chroma key',
            subtitle:
                'Live key preview; export uses the same colour with precise RGB-distance removal',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Remove screen colour'),
                  subtitle: const Text(
                    'Makes pixels close to the key colour transparent',
                  ),
                  value: liveClip.chromaKeyEnabled,
                  onChanged: (value) => update(
                    (current) => current.copyWith(chromaKeyEnabled: value),
                  ),
                ),
                const SizedBox(height: 12),
                _sheetSectionTitle('KEY COLOUR'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: keyColors.map((color) {
                    final selected =
                        color.toARGB32() == liveClip.chromaKeyColor.toARGB32();
                    return Semantics(
                      label: 'Use ${_hexColor(color)} as chroma key',
                      button: true,
                      selected: selected,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => update(
                          (current) => current.copyWith(
                            chromaKeyEnabled: true,
                            chromaKeyColor: color,
                          ),
                        ),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected ? kAccent : kBorder,
                              width: selected ? 3 : 1,
                            ),
                          ),
                          child: selected
                              ? Icon(
                                  Icons.check_rounded,
                                  size: 20,
                                  color: color.computeLuminance() > 0.5
                                      ? Colors.black
                                      : Colors.white,
                                )
                              : null,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    var draftColor = liveClip.chromaKeyColor;
                    final picked = await showDialog<Color>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Custom key color'),
                        content: SingleChildScrollView(
                          child: ColorPicker(
                            pickerColor: draftColor,
                            enableAlpha: false,
                            hexInputBar: true,
                            onColorChanged: (color) => draftColor = color,
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, draftColor),
                            child: const Text('Use color'),
                          ),
                        ],
                      ),
                    );
                    if (picked == null) return;
                    update(
                      (current) => current.copyWith(
                        chromaKeyEnabled: true,
                        chromaKeyColor: picked,
                      ),
                    );
                  },
                  icon: const Icon(Icons.color_lens_outlined),
                  label: const Text('Choose custom color'),
                ),
                const SizedBox(height: 18),
                _sheetSliderHeader(
                  'Similarity',
                  '${(liveClip.chromaKeySimilarity * 100).round()}%',
                ),
                Slider(
                  value: liveClip.chromaKeySimilarity.clamp(0.01, 1.0),
                  min: 0.01,
                  max: 1,
                  divisions: 99,
                  label: '${(liveClip.chromaKeySimilarity * 100).round()}%',
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (value) => update(
                    (current) => current.copyWith(
                      chromaKeyEnabled: true,
                      chromaKeySimilarity: value,
                    ),
                    recordHistory: false,
                  ),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _hexColor(Color color) {
    final value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  Future<void> _addSelectedKeyframe(
    TimelineKeyframeProperty property, {
    TimelineClip? targetClip,
  }) async {
    final clip = targetClip ?? _toolSelectedClip();
    if (clip == null) {
      SnackBarHelper.showInfo(context, 'Select a clip first.');
      return;
    }
    final timeline = ref.read(editorProvider).timeline;
    final isVolume = property == TimelineKeyframeProperty.volume;
    final isBlur = property == TimelineKeyframeProperty.blurStrength;
    if (isVolume && !timeline.clipHasAudio(clip)) {
      SnackBarHelper.showInfo(context, 'Volume keyframes require audio media.');
      return;
    }
    if (isBlur && !clip.blur.isEnabled) {
      SnackBarHelper.showInfo(context, 'Enable blur on this clip first.');
      return;
    }
    if (!isVolume && !isBlur && !clip.supportsTransformKeyframes) {
      SnackBarHelper.showInfo(
        context,
        'Transform keyframes require visual media.',
      );
      return;
    }
    final position = ref.read(playbackProvider).position;
    if (position < clip.startTime || position > clip.endTime) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead inside the selected clip.',
      );
      return;
    }
    final transform = clip.transformAt(position);
    final initialValue = switch (property) {
      TimelineKeyframeProperty.opacity => transform.opacity,
      TimelineKeyframeProperty.scale => transform.scale,
      TimelineKeyframeProperty.rotation => transform.rotation,
      TimelineKeyframeProperty.positionX => transform.offsetX,
      TimelineKeyframeProperty.positionY => transform.offsetY,
      TimelineKeyframeProperty.volume => clip.volumeAt(position),
      TimelineKeyframeProperty.blurStrength =>
        clip.blurAt(position).safeStrength,
    };
    final (minimum, maximum, divisions) = switch (property) {
      TimelineKeyframeProperty.opacity => (0.0, 1.0, 100),
      TimelineKeyframeProperty.scale => (0.2, 4.0, 190),
      TimelineKeyframeProperty.rotation => (-math.pi * 2, math.pi * 2, 144),
      TimelineKeyframeProperty.positionX => (
        -kTimelineDesignWidth / 2,
        kTimelineDesignWidth / 2,
        156,
      ),
      TimelineKeyframeProperty.positionY => (
        -kTimelineDesignHeight / 2,
        kTimelineDesignHeight / 2,
        144,
      ),
      TimelineKeyframeProperty.volume => (0.0, 2.0, 100),
      TimelineKeyframeProperty.blurStrength => (0.0, 30.0, 120),
    };
    var value = initialValue.clamp(minimum, maximum).toDouble();
    String formattedValue(double candidate) => switch (property) {
      TimelineKeyframeProperty.opacity ||
      TimelineKeyframeProperty.volume => '${(candidate * 100).round()}%',
      TimelineKeyframeProperty.scale => '${candidate.toStringAsFixed(2)}×',
      TimelineKeyframeProperty.rotation =>
        '${(candidate * 180 / math.pi).round()}°',
      TimelineKeyframeProperty.positionX ||
      TimelineKeyframeProperty.positionY => candidate.round().toString(),
      TimelineKeyframeProperty.blurStrength => candidate.toStringAsFixed(1),
    };
    final selectedValue = await showDialog<double>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('${property.name} keyframe'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Value at ${_formatEditorDuration(position)}',
                  style: const TextStyle(color: kTextSecondary, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text(
                  formattedValue(value),
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Slider(
                  value: value,
                  min: minimum,
                  max: maximum,
                  divisions: divisions,
                  label: formattedValue(value),
                  onChanged: (next) => setDialogState(() => value = next),
                ),
                if (property == TimelineKeyframeProperty.volume)
                  const Text(
                    'Device preview monitors up to 100%; gain above 100% is applied in the export mix.',
                    style: TextStyle(color: kTextSecondary, fontSize: 11),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, value),
              child: const Text('Set keyframe'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || selectedValue == null) return;
    final ok = ref
        .read(editorProvider.notifier)
        .upsertKeyframe(
          clipId: clip.id,
          property: property,
          time: position - clip.startTime,
          value: selectedValue,
        );
    if (ok) {
      SnackBarHelper.showSuccess(context, '${property.name} keyframe added.');
    } else {
      SnackBarHelper.showInfo(context, 'Unlock the selected track first.');
    }
  }

  Duration? _snappedKeyframeTimeAtPlayhead(TimelineClip clip) {
    final position = ref.read(playbackProvider).position;
    if (position < clip.startTime || position > clip.endTime) return null;
    final frameRate = ref
        .read(editorProvider)
        .timeline
        .workspaceSettings
        .frameRate
        .clamp(1, 120);
    final frameUs = Duration.microsecondsPerSecond / frameRate;
    final relativeUs = (position - clip.startTime).inMicroseconds.clamp(
      0,
      math.max(0, clip.duration.inMicroseconds),
    );
    final snappedUs = (relativeUs / frameUs).round() * frameUs;
    return Duration(
      microseconds: snappedUs
          .round()
          .clamp(0, math.max(0, clip.duration.inMicroseconds))
          .toInt(),
    );
  }

  bool _clipCanUseStateKeyframes(EditorTimeline timeline, TimelineClip? clip) {
    if (clip == null) return false;
    return clip.supportsTransformKeyframes ||
        clip.blur.isEnabled ||
        timeline.clipHasAudio(clip);
  }

  void _addSelectedKeyframeState({TimelineClip? targetClip}) {
    final clip = targetClip ?? _toolSelectedClip();
    if (clip == null) {
      SnackBarHelper.showInfo(context, 'Select a clip first.');
      return;
    }
    final timeline = ref.read(editorProvider).timeline;
    if (!_clipCanUseStateKeyframes(timeline, clip)) {
      SnackBarHelper.showInfo(
        context,
        'This clip has no properties that can be animated.',
      );
      return;
    }
    if (_snappedKeyframeTimeAtPlayhead(clip) == null) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead inside the selected clip.',
      );
      return;
    }
    final ok = ref
        .read(editorProvider.notifier)
        .upsertKeyframeState(
          clipId: clip.id,
          absolutePosition: ref.read(playbackProvider).position,
        );
    if (ok) {
      SnackBarHelper.showSuccess(
        context,
        'State keyframe added. Later changes now animate automatically.',
      );
    } else {
      SnackBarHelper.showInfo(context, 'Unlock the selected track first.');
    }
  }

  void _deleteSelectedKeyframeState() {
    final clip = _toolSelectedClip();
    if (clip == null) return;
    final time = _snappedKeyframeTimeAtPlayhead(clip);
    if (time == null || !clip.hasKeyframeStateAt(time)) {
      SnackBarHelper.showInfo(context, 'There is no keyframe at the playhead.');
      return;
    }
    final ok = ref
        .read(editorProvider.notifier)
        .removeKeyframeState(
          clipId: clip.id,
          absolutePosition: ref.read(playbackProvider).position,
        );
    if (ok) {
      SnackBarHelper.showSuccess(context, 'Keyframe state deleted.');
    }
  }

  void _seekSelectedKeyframe({required bool previous}) {
    final clip = _toolSelectedClip();
    if (clip == null) return;
    final relative =
        (ref.read(playbackProvider).position - clip.startTime).inMicroseconds;
    final candidates = previous
        ? clip.keyframeStateTimes
              .where((time) => time.inMicroseconds < relative)
              .toList()
        : clip.keyframeStateTimes
              .where((time) => time.inMicroseconds > relative)
              .toList();
    if (candidates.isEmpty) {
      SnackBarHelper.showInfo(
        context,
        previous ? 'No previous keyframe.' : 'No next keyframe.',
      );
      return;
    }
    final target = previous ? candidates.last : candidates.first;
    ref.read(playbackProvider.notifier).requestSeek(clip.startTime + target);
  }

  Future<void> _openStateCurvePicker(TimelineClip initialClip) async {
    final liveClip = _clipById(initialClip.id, ref.read(editorProvider));
    if (liveClip == null) return;
    final time = _snappedKeyframeTimeAtPlayhead(liveClip);
    if (time == null || !liveClip.hasKeyframeStateAt(time)) {
      SnackBarHelper.showInfo(
        context,
        'Move to a keyframe before choosing its outgoing curve.',
      );
      return;
    }
    final selectedFrame = liveClip.keyframes.firstWhere(
      (keyframe) => keyframe.time.inMilliseconds == time.inMilliseconds,
    );
    final selectedPreset = timelineCurvePresets
        .where((preset) => preset.matches(selectedFrame))
        .firstOrNull;
    var openCustomGraph = false;
    final preset = await showModalBottomSheet<TimelineCurvePreset>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: math.min(
            MediaQuery.sizeOf(sheetContext).height * 0.72,
            620.0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Curve to next state',
                            style: TextStyle(
                              color: kTextPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Applied to every property captured at this keyframe.',
                            style: TextStyle(
                              color: kTextSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 3.2,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: timelineCurvePresets.length,
                  itemBuilder: (context, index) {
                    final candidate = timelineCurvePresets[index];
                    return OutlinedButton.icon(
                      key: ValueKey('state_curve_${candidate.id}'),
                      onPressed: () => Navigator.pop(sheetContext, candidate),
                      icon: Icon(
                        selectedPreset?.id == candidate.id
                            ? Icons.check_circle_rounded
                            : Icons.show_chart_rounded,
                        size: 17,
                      ),
                      label: Text(candidate.label),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      openCustomGraph = true;
                      Navigator.pop(sheetContext);
                    },
                    icon: const Icon(Icons.multiline_chart_rounded),
                    label: const Text('Custom curve in graph editor'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (preset == null && openCustomGraph) {
      final properties = _graphPropertiesForClip(
        ref.read(editorProvider).timeline,
        liveClip,
      );
      if (properties.isNotEmpty) {
        await _openKeyframeGraphEditor(
          liveClip,
          initialProperty: properties.first,
        );
      }
      return;
    }
    if (preset == null) return;
    ref
        .read(editorProvider.notifier)
        .setKeyframeStateCurve(
          clipId: liveClip.id,
          absolutePosition: ref.read(playbackProvider).position,
          interpolation: preset.interpolation,
          curve: preset.curve,
        );
    if (mounted) {
      SnackBarHelper.showSuccess(
        context,
        '${preset.label} applied to the outgoing state.',
      );
    }
  }

  void _clearSelectedKeyframes(
    Set<TimelineKeyframeProperty> properties, {
    TimelineClip? targetClip,
  }) {
    final clip = targetClip ?? _toolSelectedClip();
    if (clip == null) return;
    ref
        .read(editorProvider.notifier)
        .updateClip(
          clip.id,
          (current) => current.copyWith(
            keyframes: current.keyframes
                .where((keyframe) => !properties.contains(keyframe.property))
                .toList(),
          ),
        );
  }

  List<TimelineKeyframeProperty> _graphPropertiesForClip(
    EditorTimeline timeline,
    TimelineClip clip,
  ) {
    final properties = <TimelineKeyframeProperty>[
      if (clip.supportsTransformKeyframes) ...const [
        TimelineKeyframeProperty.opacity,
        TimelineKeyframeProperty.scale,
        TimelineKeyframeProperty.rotation,
        TimelineKeyframeProperty.positionX,
        TimelineKeyframeProperty.positionY,
      ],
      if (clip.blur.isEnabled) TimelineKeyframeProperty.blurStrength,
      if (timeline.clipHasAudio(clip)) TimelineKeyframeProperty.volume,
    ];
    for (final keyframe in clip.keyframes) {
      final supported = switch (keyframe.property) {
        TimelineKeyframeProperty.volume => timeline.clipHasAudio(clip),
        TimelineKeyframeProperty.blurStrength => clip.blur.isEnabled,
        _ => clip.supportsTransformKeyframes,
      };
      if (supported && !properties.contains(keyframe.property)) {
        properties.add(keyframe.property);
      }
    }
    return properties;
  }

  Future<void> _openKeyframeGraphEditor(
    TimelineClip clip, {
    required TimelineKeyframeProperty initialProperty,
  }) async {
    final editorState = ref.read(editorProvider);
    final liveClip = _clipById(clip.id, editorState);
    final track = _trackForClip(liveClip, editorState);
    if (liveClip == null || track == null) return;
    if (track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the selected track first.');
      return;
    }
    final properties = _graphPropertiesForClip(editorState.timeline, liveClip);
    if (properties.isEmpty) {
      SnackBarHelper.showInfo(
        context,
        'This clip has no properties that can be animated.',
      );
      return;
    }
    final resolvedInitial = properties.contains(initialProperty)
        ? initialProperty
        : properties.first;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Consumer(
        builder: (context, sheetRef, _) {
          final state = sheetRef.watch(editorProvider);
          TimelineClip? currentClip;
          for (final candidateTrack in state.timeline.tracks) {
            for (final candidate in candidateTrack.clips) {
              if (candidate.id == liveClip.id) {
                currentClip = candidate;
                break;
              }
            }
            if (currentClip != null) break;
          }
          if (currentClip == null) {
            return ResizableEditorSheet(
              title: 'Keyframe graph',
              subtitle: 'The clip was removed from the timeline.',
              initialHeightFactor: 0.78,
              minHeightFactor: 0.52,
              maxHeightFactor: 0.94,
              scrollable: false,
              onClose: () => Navigator.pop(sheetContext),
              child: const Center(
                child: Text(
                  'Select another clip to continue.',
                  style: TextStyle(color: kTextSecondary),
                ),
              ),
            );
          }
          final currentProperties = _graphPropertiesForClip(
            state.timeline,
            currentClip,
          );
          final playback = sheetRef.watch(playbackProvider);
          return ResizableEditorSheet(
            title: 'Keyframe graph',
            subtitle:
                '${currentClip.label} • Curves are shared by preview and export',
            initialHeightFactor: 0.78,
            minHeightFactor: 0.52,
            maxHeightFactor: 0.94,
            scrollable: false,
            contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
            onClose: () => Navigator.pop(sheetContext),
            child: KeyframeGraphEditor(
              clip: currentClip,
              properties: currentProperties,
              initialProperty: resolvedInitial,
              playhead: playback.position,
              frameRate: state.timeline.workspaceSettings.frameRate,
              onChanged: (keyframes, recordHistory) {
                sheetRef
                    .read(editorProvider.notifier)
                    .updateClip(
                      currentClip!.id,
                      (candidate) => candidate.copyWith(keyframes: keyframes),
                      recordHistory: recordHistory,
                    );
              },
              onSeek: (position) => sheetRef
                  .read(playbackProvider.notifier)
                  .requestSeek(position),
              onEditStart: () => sheetRef
                  .read(editorProvider.notifier)
                  .beginTimelineGestureEdit(),
              onEditEnd: () => sheetRef
                  .read(editorProvider.notifier)
                  .endTimelineGestureEdit(),
            ),
          );
        },
      ),
    );
  }

  Future<void> _setSelectedClipNote() async {
    final clip = _toolSelectedClip();
    if (clip == null) return;
    final controller = TextEditingController(text: clip.notes ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clip note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'What should you remember about this clip?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save note'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || note == null) return;
    ref
        .read(editorProvider.notifier)
        .updateClip(
          clip.id,
          (current) => note.trim().isEmpty
              ? current.copyWith(clearNotes: true)
              : current.copyWith(notes: note.trim()),
        );
  }

  void _cycleSelectedClipColor() {
    final clip = _toolSelectedClip();
    if (clip == null) return;
    const colors = [
      Color(0x00000000),
      Color(0xFF4F8CFF),
      Color(0xFF9B6DFF),
      Color(0xFFEF7187),
      Color(0xFFF4B942),
      Color(0xFF44C38A),
    ];
    final current = colors.indexWhere(
      (color) => color.toARGB32() == clip.timelineColor.toARGB32(),
    );
    final next = colors[(current + 1) % colors.length];
    ref
        .read(editorProvider.notifier)
        .updateClip(
          clip.id,
          (currentClip) => currentClip.copyWith(timelineColor: next),
        );
  }

  void _copyClipAttributes() {
    final clip = _toolSelectedClip();
    if (clip == null) return;
    setState(() => _clipAttributeClipboard = clip);
  }

  void _pasteClipAttributes() {
    final source = _clipAttributeClipboard;
    final editorState = ref.read(editorProvider);
    if (source == null || editorState.selectedClipIds.isEmpty) {
      SnackBarHelper.showInfo(
        context,
        'Copy clip attributes first, then select clips.',
      );
      return;
    }
    final selected = editorState.selectedClipIds;
    final timeline = editorState.timeline;
    final sourceHasAudio = timeline.clipHasAudio(source);
    final sourceIsFilterEffect =
        source.isEffect && source.effectKind == TimelineEffectKind.filter;
    final sourceIsBlurEffect =
        source.isEffect && source.effectKind == TimelineEffectKind.blur;
    final tracks = editorState.timeline.tracks.map((track) {
      if (track.isLocked) return track;
      return track.copyWith(
        clips: track.clips.map((clip) {
          if (!selected.contains(clip.id)) return clip;

          final targetHasAudio = timeline.clipHasAudio(clip);
          final targetIsFilterEffect =
              clip.isEffect && clip.effectKind == TimelineEffectKind.filter;
          final targetIsBlurEffect =
              clip.isEffect && clip.effectKind == TimelineEffectKind.blur;
          final copyFullTransform =
              source.supportsVisualEffects && clip.supportsVisualEffects;
          final copyBasicTransform =
              source.supportsTransform && clip.supportsTransform;
          final copyVisualSettings = copyFullTransform;
          final copyColor =
              (source.supportsVisualEffects || sourceIsFilterEffect) &&
              (clip.supportsVisualEffects || targetIsFilterEffect);
          final copyBlur =
              (source.supportsVisualEffects || sourceIsBlurEffect) &&
              (clip.supportsVisualEffects || targetIsBlurEffect);
          final copyAudio = sourceHasAudio && targetHasAudio;
          final ownsAudioOnLinkedLane =
              clip.type == TimelineTrackType.video &&
              _separatedAudioForVideo(timeline, clip.id) != null;
          final copySourceTiming =
              source.supportsSourceTiming && clip.supportsSourceTiming;
          final copyTransitions =
              source.supportsClipAnimation && clip.supportsClipAnimation;
          final copyFreeze =
              (source.type == TimelineTrackType.video ||
                  source.type == TimelineTrackType.gif) &&
              (clip.type == TimelineTrackType.video ||
                  clip.type == TimelineTrackType.gif);
          final copyDenoise =
              (source.type == TimelineTrackType.video || sourceHasAudio) &&
              (clip.type == TimelineTrackType.video || targetHasAudio);

          final copyTransformKeyframes =
              source.supportsTransformKeyframes &&
              clip.supportsTransformKeyframes;
          final copiedKeyframeProperties = <TimelineKeyframeProperty>{
            if (copyTransformKeyframes) ...[
              TimelineKeyframeProperty.opacity,
              TimelineKeyframeProperty.scale,
              TimelineKeyframeProperty.rotation,
              TimelineKeyframeProperty.positionX,
              TimelineKeyframeProperty.positionY,
            ],
            if (copyAudio) TimelineKeyframeProperty.volume,
            if (copyBlur) TimelineKeyframeProperty.blurStrength,
          };
          final nextKeyframes = clip.keyframes
              .where(
                (keyframe) =>
                    !copiedKeyframeProperties.contains(keyframe.property),
              )
              .toList();
          final copiedFramesByPropertyAndTime = <String, TimelineKeyframe>{};
          for (final keyframe in source.keyframes) {
            if (!copiedKeyframeProperties.contains(keyframe.property)) {
              continue;
            }
            final timeMs = keyframe.time.inMilliseconds
                .clamp(0, math.max(0, clip.duration.inMilliseconds))
                .toInt();
            copiedFramesByPropertyAndTime['${keyframe.property.name}:$timeMs'] =
                TimelineKeyframe(
                  time: Duration(milliseconds: timeMs),
                  property: keyframe.property,
                  value: keyframe.value,
                  interpolation: keyframe.interpolation,
                  curve: keyframe.curve,
                );
          }
          nextKeyframes.addAll(copiedFramesByPropertyAndTime.values);
          nextKeyframes.sort((a, b) => a.time.compareTo(b.time));

          var nextTransform = clip.transform;
          if (copyFullTransform) {
            nextTransform = source.transform;
          } else if (copyBasicTransform) {
            nextTransform = clip.transform.copyWith(
              offsetX: source.transform.offsetX,
              offsetY: source.transform.offsetY,
              scale: source.transform.scale,
            );
          }

          Duration? nextFreezeSourceTime = clip.freezeFrameSourceTime;
          if (copyFreeze) {
            if (!source.freezeFrame) {
              nextFreezeSourceTime = null;
            } else {
              final sourceSpanMs = math.max(
                1,
                source.sourceDuration.inMilliseconds > 0
                    ? source.sourceDuration.inMilliseconds
                    : (source.duration.inMilliseconds * source.playbackRate)
                          .round(),
              );
              final sourceOffsetMs =
                  (source.effectiveFreezeFrameSourceTime -
                          source.sourceStartTime)
                      .inMilliseconds
                      .clamp(0, sourceSpanMs - 1);
              final relativeOffset = sourceOffsetMs / sourceSpanMs;
              final targetSpanMs = math.max(
                1,
                clip.sourceDuration.inMilliseconds > 0
                    ? clip.sourceDuration.inMilliseconds
                    : (clip.duration.inMilliseconds * clip.playbackRate)
                          .round(),
              );
              nextFreezeSourceTime =
                  clip.sourceStartTime +
                  Duration(
                    milliseconds: (relativeOffset * (targetSpanMs - 1)).round(),
                  );
            }
          }

          return clip.copyWith(
            transform: nextTransform,
            audioMix: (copyAudio ? source.audioMix : clip.audioMix).copyWith(
              // Attribute paste must not reactivate the embedded stream after
              // ownership has moved to a separated audio clip.
              muted: ownsAudioOnLinkedLane
                  ? true
                  : (copyAudio ? source.audioMix.muted : clip.audioMix.muted),
            ),
            fitMode: copyVisualSettings ? source.fitMode : clip.fitMode,
            playbackRate: copySourceTiming
                ? source.playbackRate
                : clip.playbackRate,
            isReversed: copySourceTiming && clip.supportsReversePlayback
                ? source.isReversed
                : clip.isReversed,
            crop: copyVisualSettings ? source.crop : clip.crop,
            blur: copyBlur ? source.blur : clip.blur,
            colorAdjustments: copyColor
                ? source.colorAdjustments
                : clip.colorAdjustments,
            introTransition: copyTransitions
                ? source.introTransition
                : clip.introTransition,
            outroTransition: copyTransitions
                ? source.outroTransition
                : clip.outroTransition,
            keyframes: nextKeyframes,
            freezeFrame: copyFreeze ? source.freezeFrame : clip.freezeFrame,
            freezeFrameSourceTime: nextFreezeSourceTime,
            clearFreezeFrameSourceTime:
                copyFreeze && nextFreezeSourceTime == null,
            stabilize:
                source.type == TimelineTrackType.video &&
                    clip.type == TimelineTrackType.video
                ? source.stabilize
                : clip.stabilize,
            denoise: copyDenoise ? source.denoise : clip.denoise,
            chromaKeyEnabled: copyVisualSettings
                ? source.chromaKeyEnabled
                : clip.chromaKeyEnabled,
            chromaKeyColor: copyVisualSettings
                ? source.chromaKeyColor
                : clip.chromaKeyColor,
            chromaKeySimilarity: copyVisualSettings
                ? source.chromaKeySimilarity
                : clip.chromaKeySimilarity,
            timelineColor: source.timelineColor,
            autoDuck: copyAudio ? source.autoDuck : clip.autoDuck,
            duckAmount: copyAudio ? source.duckAmount : clip.duckAmount,
            duckAttackMs: copyAudio ? source.duckAttackMs : clip.duckAttackMs,
            duckReleaseMs: copyAudio
                ? source.duckReleaseMs
                : clip.duckReleaseMs,
            duckSidechainTrackIds: copyAudio
                ? source.duckSidechainTrackIds
                : clip.duckSidechainTrackIds,
          );
        }).toList(),
      );
    }).toList();
    ref
        .read(editorProvider.notifier)
        .setTimeline(editorState.timeline.copyWith(tracks: tracks));
  }

  void _splitEveryTrackAtPlayhead() {
    final position = ref.read(playbackProvider).position;
    final ids = ref
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .where((clip) => clip.startTime < position && clip.endTime > position)
        .map((clip) => clip.id)
        .toList();
    final notifier = ref.read(editorProvider.notifier);
    notifier.beginTimelineGestureEdit();
    try {
      for (final id in ids) {
        final live = _clipById(id, ref.read(editorProvider));
        if (live != null) _splitClipAtPlayhead(live);
      }
    } finally {
      notifier.endTimelineGestureEdit();
    }
    if (ids.isEmpty) {
      SnackBarHelper.showInfo(context, 'No clips cross the playhead.');
    }
  }

  void _generateBeatMarkers() {
    final timeline = ref.read(editorProvider).timeline;
    final duration = timeline.duration;
    if (duration <= Duration.zero) return;
    final markers = [...timeline.markers];
    for (var ms = 0; ms <= duration.inMilliseconds; ms += 500) {
      if (markers.any(
        (marker) =>
            marker.type == TimelineMarkerType.beat &&
            (marker.position.inMilliseconds - ms).abs() < 40,
      )) {
        continue;
      }
      markers.add(
        TimelineMarker(
          position: Duration(milliseconds: ms),
          label: 'Beat ${ms ~/ 500 + 1}',
          type: TimelineMarkerType.beat,
          color: const Color(0xFF67E8F9),
        ),
      );
    }
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          timeline.copyWith(
            markers: markers..sort((a, b) => a.position.compareTo(b.position)),
          ),
        );
  }

  void _addChapterMarker() {
    final timeline = ref.read(editorProvider).timeline;
    final position = ref.read(playbackProvider).position;
    final marker = TimelineMarker(
      position: position,
      label:
          'Chapter ${timeline.markers.where((marker) => marker.type == TimelineMarkerType.chapter).length + 1}',
      type: TimelineMarkerType.chapter,
      color: const Color(0xFFF59E0B),
    );
    ref
        .read(editorProvider.notifier)
        .setTimeline(timeline.copyWith(markers: [...timeline.markers, marker]));
  }

  void _clearAllMarkers() {
    final timeline = ref.read(editorProvider).timeline;
    if (timeline.markers.isEmpty) return;
    ref
        .read(editorProvider.notifier)
        .setTimeline(timeline.copyWith(markers: const []));
  }

  Future<void> _chooseProjectFrameRate() async {
    final current = ref
        .read(editorProvider)
        .timeline
        .workspaceSettings
        .frameRate;
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Project frame rate'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final rate in const [24, 25, 30, 50, 60])
              ListTile(
                leading: Icon(
                  rate == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: rate == current ? kAccent : kTextSecondary,
                ),
                title: Text('$rate fps'),
                onTap: () => Navigator.pop(dialogContext, rate),
              ),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    _toggleWorkspace((settings) => settings.copyWith(frameRate: selected));
  }

  void _selectAllClips() {
    final ids = ref
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .map((clip) => clip.id);
    ref.read(editorProvider.notifier).selectClipIds(ids);
  }

  void _nudgeSelectedClips(int direction) {
    final editorState = ref.read(editorProvider);
    final selected = editorState.selectedClipIds;
    if (selected.isEmpty) return;
    final frameMs = math.max(
      1,
      (1000 / editorState.timeline.workspaceSettings.frameRate).round(),
    );
    final requestedDeltaMs = frameMs * direction;
    final movableClips = editorState.timeline.tracks
        .where((track) => !track.isLocked)
        .expand((track) => track.clips)
        .where((clip) => selected.contains(clip.id))
        .toList();
    if (movableClips.isEmpty) return;
    final earliestStartMs = movableClips
        .map((clip) => clip.startTime.inMilliseconds)
        .reduce(math.min);
    // Clamp the group once so clips at zero do not collapse spacing between
    // independently-clamped selected clips.
    final effectiveDeltaMs = math.max(requestedDeltaMs, -earliestStartMs);
    if (effectiveDeltaMs == 0) return;
    final nextTracks = editorState.timeline.tracks.map((track) {
      if (track.isLocked) return track;
      return track.copyWith(
        clips: track.clips.map((clip) {
          if (!selected.contains(clip.id)) return clip;
          final start = clip.startTime.inMilliseconds + effectiveDeltaMs;
          return clip.copyWith(
            startTime: Duration(milliseconds: start),
            endTime: Duration(
              milliseconds: start + clip.duration.inMilliseconds,
            ),
          );
        }).toList(),
      );
    }).toList();
    final nextTimeline = editorState.timeline.copyWith(tracks: nextTracks);
    if (nextTimeline.hasTrackOverlaps) {
      SnackBarHelper.showInfo(
        context,
        'The selection cannot move through another clip on the same track.',
      );
      return;
    }
    ref.read(editorProvider.notifier).setTimeline(nextTimeline);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(nextTimeline.subtitleEntries);
  }

  Future<void> _renameSelectedTrack() async {
    final editorState = ref.read(editorProvider);
    final track = editorState.timeline.tracks
        .where((candidate) => candidate.id == editorState.selectedTrackId)
        .firstOrNull;
    if (track == null) return;
    final controller = TextEditingController(text: track.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename track'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null) return;
    ref.read(editorProvider.notifier).renameTrack(track.id, name);
  }

  void _duplicateSelectedTrack() {
    final trackId = ref.read(editorProvider).selectedTrackId;
    if (trackId == null) return;
    ref.read(editorProvider.notifier).duplicateTrack(trackId);
  }

  void _moveSelectedTrack(int direction) {
    final trackId = ref.read(editorProvider).selectedTrackId;
    if (trackId == null) return;
    ref.read(editorProvider.notifier).reorderTrack(trackId, direction);
  }

  void _toggleWorkspace(
    TimelineWorkspaceSettings Function(TimelineWorkspaceSettings current)
    mapper,
  ) {
    ref.read(editorProvider.notifier).setWorkspaceSettings(mapper);
  }

  Future<void> _choosePreviewMediaQuality() async {
    final current = ref
        .read(editorProvider)
        .timeline
        .workspaceSettings
        .previewMediaQuality;
    final selected = await showDialog<PreviewMediaQuality>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Preview media quality'),
        content: RadioGroup<PreviewMediaQuality>(
          groupValue: current,
          onChanged: (value) => Navigator.of(dialogContext).pop(value),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile(
                value: PreviewMediaQuality.auto,
                title: Text('Auto'),
                subtitle: Text('Use a valid proxy when available'),
              ),
              RadioListTile(
                value: PreviewMediaQuality.proxy,
                title: Text('Prefer proxies'),
                subtitle: Text('Fall back to originals while proxies build'),
              ),
              RadioListTile(
                value: PreviewMediaQuality.original,
                title: Text('Original media'),
                subtitle: Text('Always decode the source file'),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    _toggleWorkspace(
      (settings) => settings.copyWith(previewMediaQuality: selected),
    );
  }

  Future<void> _generateProjectProxies() async {
    final startingTimeline = ref.read(editorProvider).timeline;
    final candidates = startingTimeline.assets.where((asset) {
      final sourcePath = asset.sourcePath?.trim();
      return asset.type == EditorAssetType.video &&
          sourcePath != null &&
          sourcePath.isNotEmpty &&
          File(sourcePath).existsSync();
    }).toList();
    if (candidates.isEmpty) {
      SnackBarHelper.showInfo(context, 'No local video sources need proxies');
      return;
    }

    SnackBarHelper.showInfo(
      context,
      'Building ${candidates.length} editing ${candidates.length == 1 ? 'proxy' : 'proxies'}…',
    );
    final resultByAssetId = <String, TimelineProxyMediaResult>{};
    var completed = 0;
    for (final asset in candidates) {
      final result = await TimelineProxyMediaService.instance.ensureProxy(
        asset,
      );
      if (!mounted) return;
      if (result != null) {
        resultByAssetId[asset.id] = result;
        completed++;
      }
    }
    var applied = 0;
    if (resultByAssetId.isNotEmpty) {
      final current = ref.read(editorProvider).timeline;
      final startingQuality =
          startingTimeline.workspaceSettings.previewMediaQuality;
      final currentSettings = current.workspaceSettings;
      final nextAssets = current.assets.map((asset) {
        final result = resultByAssetId[asset.id];
        if (result == null ||
            !TimelineProxyMediaService.resultMatchesAsset(result, asset)) {
          return asset;
        }
        applied++;
        return asset.copyWith(
          metadata: {...asset.metadata, 'proxyMedia': result.toMetadata()},
        );
      }).toList();
      if (applied > 0) {
        ref
            .read(editorProvider.notifier)
            .setTimeline(
              current.copyWith(
                assets: nextAssets,
                workspaceSettings:
                    currentSettings.previewMediaQuality == startingQuality
                    ? currentSettings.copyWith(
                        previewMediaQuality: PreviewMediaQuality.auto,
                      )
                    : currentSettings,
              ),
            );
      }
    }
    if (!mounted) return;
    if (applied == candidates.length) {
      SnackBarHelper.showSuccess(context, '$applied editing proxies ready');
    } else {
      SnackBarHelper.showInfo(
        context,
        '$applied of ${candidates.length} editing proxies ready'
        '${completed > applied ? ' (${completed - applied} source changes skipped)' : ''}',
      );
    }
  }

  Future<void> _exportSubtitleFile(String format) async {
    final state = ref.read(subtitleProvider);
    String? generatedPath;
    try {
      generatedPath = format == 'srt'
          ? await SubtitleExportService.generateSrt(state.entries)
          : await SubtitleExportService.generateVtt(state.entries);

      final generatedFile = File(generatedPath);
      if (!await generatedFile.exists() || await generatedFile.length() == 0) {
        throw Exception(
          'Generated ${format.toUpperCase()} file is empty. Cannot export.',
        );
      }

      final savePath = await _resolveSubtitleExportPath(format);
      if (savePath == null) return;

      final outputFile = File(savePath);
      final bytes = await generatedFile.readAsBytes();
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      await outputFile.create(recursive: true);
      await outputFile.writeAsBytes(bytes, flush: true);

      final outputSize = await outputFile.length();
      if (outputSize == 0) {
        throw Exception(
          '${format.toUpperCase()} export failed (0 KB output file).',
        );
      }

      if (!mounted) return;
      SnackBarHelper.showSuccess(
        context,
        '${format.toUpperCase()} exported to:\n$savePath',
      );
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.showError(context, 'Export failed: $e');
    } finally {
      if (generatedPath != null) {
        try {
          final temporaryFile = File(generatedPath);
          if (await temporaryFile.exists()) await temporaryFile.delete();
        } catch (_) {
          // The delivered subtitle file is independent from its temp source.
        }
      }
    }
  }

  Future<String?> _resolveSubtitleExportPath(String format) async {
    final safeProjectName = _safeProjectName();
    final fileName = '${safeProjectName}_subtitles.$format';

    if (Platform.isAndroid || Platform.isIOS) {
      final Directory baseDir = Platform.isAndroid
          ? (await getExternalStorageDirectory() ??
                await getApplicationDocumentsDirectory())
          : await getApplicationDocumentsDirectory();

      final exportDir = Directory(
        path.join(baseDir.path, 'CaptionCraft', 'exports'),
      );
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      return path.join(exportDir.path, fileName);
    }

    final picked = await FilePicker.platform.saveFile(
      dialogTitle: 'Save ${format.toUpperCase()} file',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [format],
    );
    if (picked == null) return null;

    // Some Android storage providers return content:// URIs; fallback to app export dir.
    if (picked.startsWith('content://')) {
      final fallbackDir = await getApplicationDocumentsDirectory();
      final exportDir = Directory(path.join(fallbackDir.path, 'exports'));
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      return path.join(exportDir.path, fileName);
    }

    return picked;
  }

  Future<void> _importSubtitleFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'vtt'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;
      final filePath = result.files.first.path;
      if (filePath == null) return;
      final subtitleFile = File(filePath);
      if (!await subtitleFile.exists()) {
        throw Exception('The selected subtitle file is no longer available.');
      }
      if (await subtitleFile.length() > 10 * 1024 * 1024) {
        throw Exception('Subtitle files must be smaller than 10 MB.');
      }

      final lowerPath = filePath.toLowerCase();
      final parsedEntries = lowerPath.endsWith('.vtt')
          ? await SubtitleExportService.importVtt(filePath)
          : await SubtitleExportService.importSrt(filePath);

      if (parsedEntries.isEmpty) {
        if (!mounted) return;
        SnackBarHelper.showWarning(context, 'No subtitles found in file');
        return;
      }

      final editorState = ref.read(editorProvider);
      final compositionDuration = editorState.timeline.duration;
      final entries = SubtitleExportService.clampEntriesToDuration(
        parsedEntries,
        compositionDuration,
      );
      if (entries.isEmpty) {
        if (!mounted) return;
        SnackBarHelper.showWarning(
          context,
          'No imported subtitles overlap this project.',
        );
        return;
      }

      final imported = ref
          .read(editorProvider.notifier)
          .replaceSubtitleEntries(entries);
      if (!imported) {
        if (!mounted) return;
        SnackBarHelper.showInfo(
          context,
          'Unlock the subtitle track before importing captions.',
        );
        return;
      }
      _scheduleProjectSave(immediate: true, changeType: 'subtitles_imported');
      if (!mounted) return;
      SnackBarHelper.showSuccess(
        context,
        entries.length == parsedEntries.length
            ? 'Imported ${entries.length} subtitles'
            : 'Imported ${entries.length}; skipped cues outside the project',
      );
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.showError(context, 'Import failed: $e');
    }
  }

  void _showExportDialog() {
    showDialog(
      context: context,
      builder: (_) => ExportDialog(
        onExport: (settings) {
          Navigator.pop(context);
          unawaited(_openExportVideoScreen(settings));
        },
      ),
    );
  }

  Future<void> _openExportVideoScreen(ExportSettings settings) async {
    final subtitleState = ref.read(subtitleProvider);
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline.mergeSubtitleEntries(
      subtitles: subtitleState.entries,
      globalStyle: subtitleState.globalStyle,
    );
    final projectSnapshot = _projectSnapshot.copyWith(
      subtitles: List<SubtitleEntry>.from(subtitleState.entries),
      globalStyle: subtitleState.globalStyle,
      timeline: timeline,
      lastModifiedAt: DateTime.now(),
    );
    final exportedPath = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ExportVideoScreen(
          project: projectSnapshot,
          timeline: timeline,
          settings: settings,
          entries: List<SubtitleEntry>.from(subtitleState.entries),
          globalStyle: subtitleState.globalStyle,
        ),
      ),
    );
    if (!mounted) return;
    final persistedProject = await ProjectLocalStorage.loadProject(
      widget.project.id,
      ownerUid: _projectSnapshot.ownerUid ?? _currentUserUid,
    );
    if (persistedProject != null) {
      _projectSnapshot = persistedProject;
    } else if (exportedPath != null) {
      _projectSnapshot = projectSnapshot.copyWith(
        lastExportPath: exportedPath,
        lastModifiedAt: DateTime.now(),
      );
    }
  }

  Future<void> _handleGenerateSubtitles() async {
    if (_isGeneratingSubtitles) return;
    setState(() => _isGeneratingSubtitles = true);
    try {
      final quota = ref.read(quotaProvider);
      if (!quota.canRun) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const QuotaExhaustedScreen()),
        );
        return;
      }

      final timeline = ref.read(editorProvider).timeline;
      final targetClip = await _chooseCaptionSourceClip(timeline);
      if (targetClip == null || !mounted) return;

      await _generateSubtitlesForMediaClip(targetClip, timeline);
    } finally {
      if (mounted) {
        setState(() => _isGeneratingSubtitles = false);
      } else {
        _isGeneratingSubtitles = false;
      }
    }
  }

  Future<TimelineClip?> _chooseCaptionSourceClip(
    EditorTimeline timeline,
  ) async {
    final captionSources =
        timeline.tracks
            .expand((track) => track.clips)
            .where((clip) => timeline.clipHasAudio(clip))
            .toList()
          ..sort((a, b) {
            final startCompare = a.startTime.compareTo(b.startTime);
            if (startCompare != 0) return startCompare;
            return a.type.index.compareTo(b.type.index);
          });

    if (captionSources.isEmpty) {
      SnackBarHelper.showInfo(
        context,
        'Add a video or audio clip before generating captions.',
      );
      return null;
    }

    return showModalBottomSheet<TimelineClip>(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.56,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: kBorder,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Choose caption source',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: captionSources.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: kBorder, height: 1),
                  itemBuilder: (_, index) {
                    final clip = captionSources[index];
                    final isAudio = clip.type == TimelineTrackType.audio;
                    return ListTile(
                      leading: Icon(
                        isAudio
                            ? Icons.graphic_eq_rounded
                            : Icons.movie_creation_outlined,
                        color: kTextPrimary,
                      ),
                      title: Text(
                        clip.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: kTextPrimary),
                      ),
                      subtitle: Text(
                        '${isAudio ? 'Audio' : 'Video'} • '
                        '${SubtitleEntry.formatDisplayTime(clip.startTime)} - '
                        '${SubtitleEntry.formatDisplayTime(clip.endTime)}',
                        style: TextStyle(color: kTextSecondary, fontSize: 12),
                      ),
                      onTap: () => Navigator.pop(context, clip),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _generateSubtitlesForMediaClip(
    TimelineClip targetClip,
    EditorTimeline timeline,
  ) async {
    final captionRouting = resolveCaptionTrackRouting(
      timeline: timeline,
      sourceClip: targetClip,
    );
    if (captionRouting.isBlocked) {
      SnackBarHelper.showInfo(
        context,
        'Unlock ${captionRouting.blockingTrack!.name} before replacing these captions.',
      );
      return;
    }
    final subtitleTrack = captionRouting.destination;
    if (subtitleTrack == null ||
        !subtitleTrack.acceptsClipType(TimelineTrackType.subtitle)) {
      SnackBarHelper.showInfo(
        context,
        'Add or unlock a subtitle track before generating captions.',
      );
      return;
    }

    final user = ref.read(currentUserProvider);
    if (user == null) {
      SnackBarHelper.showError(context, 'Sign in to generate subtitles.');
      return;
    }

    final mediaPath = resolveCaptionMediaPath(
      timeline: timeline,
      sourceClip: targetClip,
      legacyBaseVideoPath: widget.project.videoPath,
    );
    if (mediaPath.isEmpty) {
      SnackBarHelper.showError(
        context,
        'Media source is missing for this clip.',
      );
      return;
    }

    if (!ref.read(quotaProvider).canRun) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const QuotaExhaustedScreen()),
      );
      return;
    }

    if (!mounted) return;
    final pipeline = TranscriptionPipeline();
    final processingNavigator = Navigator.of(context);
    var processingClosed = false;
    var cancellationRequested = false;
    late final MaterialPageRoute<void> processingRoute;

    void closeProcessingRoute() {
      if (processingClosed) return;
      processingClosed = true;
      if (processingNavigator.mounted && processingRoute.isActive) {
        processingNavigator.removeRoute(processingRoute);
      }
    }

    processingRoute = MaterialPageRoute<void>(
      builder: (_) => ProcessingScreen(
        progressStream: pipeline.progressStream,
        onCancel: () {
          cancellationRequested = true;
          pipeline.cancel();
          closeProcessingRoute();
        },
      ),
    );
    unawaited(
      processingNavigator.push<void>(processingRoute).whenComplete(() {
        processingClosed = true;
      }),
    );

    try {
      final generatedEntries = await pipeline.transcribeVideoSegment(
        videoPath: mediaPath,
        startTime: targetClip.sourceStartTime,
        clipDuration: targetClip.sourceDuration,
      );

      if (generatedEntries == null || generatedEntries.isEmpty) {
        closeProcessingRoute();
        if (cancellationRequested) return;
        if (mounted) {
          SnackBarHelper.showInfo(
            context,
            'No subtitles detected for this clip.',
          );
        }
        return;
      }

      // A free run is charged only after transcription produces usable cues.
      // Failed, cancelled, and silent-media attempts do not consume the quota.
      final quotaRecorded = await ref
          .read(quotaProvider.notifier)
          .consumeRun(user.uid);

      final shiftedEntries = targetClip.mapSourceSubtitlesToTimeline(
        generatedEntries,
      );

      final existingLinkedSubtitleIds = timeline.tracks
          .where((track) => track.type == TimelineTrackType.subtitle)
          .expand((track) => track.clips)
          .where((clip) => clip.linkedClipId == targetClip.id)
          .map((clip) => clip.id)
          .toSet();

      final currentSubtitleState = ref.read(subtitleProvider);
      final mergedEntries = [
        ...currentSubtitleState.entries.where(
          (entry) => !existingLinkedSubtitleIds.contains(entry.id),
        ),
        ...shiftedEntries,
      ]..sort((a, b) => a.startTime.compareTo(b.startTime));

      final nextTimeline = _timelineWithGeneratedSubtitles(
        timeline: timeline,
        targetClip: targetClip,
        subtitleTrack: subtitleTrack,
        generatedEntries: shiftedEntries,
      );

      ref
          .read(editorProvider.notifier)
          .replaceTimelineAndSubtitleEntries(
            timeline: nextTimeline,
            entries: mergedEntries,
          );
      _scheduleProjectSave(immediate: true, changeType: 'subtitles_generated');

      closeProcessingRoute();
      if (mounted) {
        SnackBarHelper.showSuccess(
          context,
          'Generated ${shiftedEntries.length} captions for ${targetClip.label}',
        );
        if (!quotaRecorded) {
          SnackBarHelper.showWarning(
            context,
            'Captions were created, but usage could not be synced.',
          );
        }
      }
    } catch (e) {
      closeProcessingRoute();
      if (mounted && !cancellationRequested) {
        SnackBarHelper.showError(
          context,
          e.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      pipeline.dispose();
    }
  }

  EditorTimeline _timelineWithGeneratedSubtitles({
    required EditorTimeline timeline,
    required TimelineClip targetClip,
    required TimelineTrack subtitleTrack,
    required List<SubtitleEntry> generatedEntries,
  }) {
    return replaceGeneratedCaptionsForSource(
      timeline: timeline,
      sourceClip: targetClip,
      destinationTrack: subtitleTrack,
      generatedEntries: generatedEntries,
    );
  }

  void _scheduleProjectSave({
    bool immediate = false,
    String changeType = 'editor_change',
  }) {
    if (!_editorInitialized) return;
    _saveDebounce?.cancel();
    _remoteSaveDebounce?.cancel();
    final userUid = ref.read(currentUserProvider)?.uid;
    final project = _captureProjectSnapshot(
      captionsChanged: _changeAffectsCaptions(changeType),
    );
    if (userUid != null) {
      _remoteSyncPending = true;
    }
    if (immediate) {
      unawaited(
        _saveProjectState(
          project: project,
          userUid: userUid,
          syncRemote: true,
          changeType: changeType,
        ),
      );
      return;
    }

    // Timeline drags can publish dozens of revisions per second. Keep the
    // latest snapshot in memory, then coalesce disk writes after the gesture
    // settles instead of serializing the entire project for every pointer move.
    _saveDebounce = Timer(const Duration(milliseconds: 650), () {
      unawaited(
        _saveProjectState(
          project: _projectSnapshot,
          userUid: userUid,
          syncRemote: false,
          changeType: changeType,
        ),
      );
    });
    _remoteSaveDebounce = Timer(const Duration(seconds: 2), () {
      unawaited(
        _saveProjectState(
          project: _projectSnapshot,
          userUid: userUid,
          syncRemote: true,
          changeType: '${changeType}_remote_sync',
        ),
      );
    });
  }

  Future<void> _flushProjectSave({
    bool syncRemote = true,
    String changeType = 'editor_flush',
  }) async {
    _saveDebounce?.cancel();
    _remoteSaveDebounce?.cancel();
    final userUid = ref.read(currentUserProvider)?.uid;
    final project = _captureProjectSnapshot();
    await _saveProjectState(
      project: project,
      userUid: userUid,
      syncRemote: syncRemote,
      changeType: changeType,
    );
  }

  Project _captureProjectSnapshot({bool captionsChanged = false}) {
    if (!_editorInitialized) return _projectSnapshot;

    final subtitleState = ref.read(subtitleProvider);
    final editorState = ref.read(editorProvider);
    final entries = List<SubtitleEntry>.from(subtitleState.entries);
    final mergedTimeline = editorState.timeline.mergeSubtitleEntries(
      subtitles: entries,
      globalStyle: subtitleState.globalStyle,
    );
    final now = DateTime.now();
    final project = _projectSnapshot.copyWith(
      subtitles: entries,
      globalStyle: subtitleState.globalStyle,
      timeline: mergedTimeline,
      durationMs: mergedTimeline.duration.inMilliseconds,
      lastModifiedAt: now,
      captionsModifiedAt: captionsChanged
          ? now
          : _projectSnapshot.captionsModifiedAt,
    );
    _projectSnapshot = project;
    return project;
  }

  bool _changeAffectsCaptions(String changeType) {
    return changeType.contains('subtitle') ||
        changeType.contains('caption') ||
        changeType.contains('style');
  }

  Future<void> _saveProjectState({
    required Project project,
    required String? userUid,
    bool syncRemote = true,
    String changeType = 'editor_change',
  }) {
    _queuedProjectSnapshot = project;
    _queuedRemoteSync = _queuedRemoteSync || (syncRemote && userUid != null);
    if (userUid != null) {
      _queuedUserUid = userUid;
    }
    _queuedChangeType = changeType;

    final activeSave = _activeProjectSave;
    if (activeSave != null) return activeSave;

    late final Future<void> saveDrain;
    saveDrain = _drainProjectSaves().whenComplete(() {
      if (identical(_activeProjectSave, saveDrain)) {
        _activeProjectSave = null;
      }
    });
    _activeProjectSave = saveDrain;
    return saveDrain;
  }

  Future<void> _drainProjectSaves() async {
    _isSavingProject = true;
    if (mounted && !_isClosing) {
      setState(() {});
    }

    try {
      while (_queuedProjectSnapshot != null) {
        final project = _queuedProjectSnapshot!;
        final shouldSyncRemote = _queuedRemoteSync;
        final userUid = _queuedUserUid;
        final changeType = _queuedChangeType;

        _queuedProjectSnapshot = null;
        _queuedRemoteSync = false;
        _queuedUserUid = null;
        _queuedChangeType = 'queued_editor_change';

        var savedLocally = false;
        try {
          await EditorChangeLogService.saveLocalSnapshot(
            project: project,
            changeType: changeType,
          );
          savedLocally = true;
          _lastSavedAt = DateTime.now();
          _localSaveError = null;
        } catch (error) {
          _localSaveError = error;
        }

        if (savedLocally && shouldSyncRemote && userUid != null) {
          if (_queuedProjectSnapshot != null) {
            _queuedRemoteSync = true;
            _queuedUserUid ??= userUid;
          } else {
            try {
              await FirebaseService.saveProject(
                userUid,
                project.id,
                project.toFirestore(),
              );
              _remoteSyncPending = false;
            } catch (_) {
              _remoteSyncPending = true;
            }
          }
        }
      }
    } finally {
      _isSavingProject = false;
      if (mounted && !_isClosing) {
        setState(() {});
      }
    }
  }

  String _safeProjectName() {
    final cleaned = widget.project.name
        .replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'caption_craft' : cleaned;
  }

  TimelineClip? _selectedClipFromState(EditorState editorState) {
    if (editorState.selectedClipId == null) return null;
    for (final track in editorState.timeline.tracks) {
      for (final clip in track.clips) {
        if (clip.id == editorState.selectedClipId) {
          return clip;
        }
      }
    }
    return null;
  }

  TimelineTrack? _trackForClip(TimelineClip? clip, EditorState editorState) {
    if (clip == null) return null;
    for (final track in editorState.timeline.tracks) {
      if (track.clips.any((candidate) => candidate.id == clip.id)) {
        return track;
      }
    }
    return null;
  }

  TimelineClip? _clipById(String clipId, EditorState editorState) {
    for (final track in editorState.timeline.tracks) {
      for (final clip in track.clips) {
        if (clip.id == clipId) {
          return clip;
        }
      }
    }
    return null;
  }

  void _updateTimelineClip(
    TimelineClip target,
    TimelineClip Function(TimelineClip current) mapper, {
    bool recordHistory = true,
  }) {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(target, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to edit this clip.');
      return;
    }
    final nextTracks = editorState.timeline.tracks.map((timelineTrack) {
      final clips = timelineTrack.clips
          .map((clip) => clip.id == target.id ? mapper(clip) : clip)
          .toList();
      return timelineTrack.copyWith(clips: clips);
    }).toList();
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          editorState.timeline.copyWith(tracks: nextTracks),
          recordHistory: recordHistory,
        );
  }

  void _updateClipPlaybackRate(
    TimelineClip target,
    double playbackRate, {
    bool recordHistory = true,
  }) {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final liveTarget = _clipById(target.id, editorState) ?? target;
    final track = _trackForClip(liveTarget, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to change speed.');
      return;
    }
    final safeRate = playbackRate.clamp(0.25, 4).toDouble();
    final sourceDurationMs = liveTarget.sourceDuration.inMilliseconds > 0
        ? liveTarget.sourceDuration.inMilliseconds
        : liveTarget.duration.inMilliseconds;
    final nextDuration = Duration(
      milliseconds: math.max(100, (sourceDurationMs / safeRate).round()),
    );
    final nextEnd = liveTarget.startTime + nextDuration;
    final rippleDelta = nextDuration - liveTarget.duration;
    final isBase = track.section == TimelineTrackSection.baseVideo;
    final oldEnd = liveTarget.endTime;
    final oldDurationMs = math.max(1, liveTarget.duration.inMilliseconds);
    final updatedTarget = liveTarget.copyWith(
      playbackRate: safeRate,
      endTime: nextEnd,
      keyframes: TimelineKeyframeEditing.retime(liveTarget, nextDuration),
      effectStack: liveTarget.effectStack.retimed(
        liveTarget.duration,
        nextDuration,
      ),
    );

    final retimedTracks = timeline.tracks.map((timelineTrack) {
      final clips = timelineTrack.clips.map((clip) {
        if (clip.id == liveTarget.id) {
          return updatedTarget;
        }

        if (clip.type == TimelineTrackType.audio &&
            clip.linkedClipId == liveTarget.id) {
          return isExactSeparatedAudioTransportMirror(
                video: liveTarget,
                audio: clip,
              )
              ? syncSeparatedAudioTransport(
                  audio: clip.copyWith(
                    keyframes: TimelineKeyframeEditing.retime(
                      clip,
                      nextDuration,
                    ),
                    effectStack: clip.effectStack.retimed(
                      clip.duration,
                      nextDuration,
                    ),
                  ),
                  updatedVideo: updatedTarget,
                )
              : clip;
        }

        final isSubtitleClip =
            timelineTrack.type == TimelineTrackType.subtitle ||
            clip.type == TimelineTrackType.subtitle;
        final intersectsChangedClip =
            clip.startTime < oldEnd && clip.endTime > liveTarget.startTime;
        final belongsToChangedClip =
            (isSubtitleClip && clip.linkedClipId == liveTarget.id) ||
            (isBase &&
                isSubtitleClip &&
                clip.linkedClipId == null &&
                intersectsChangedClip);
        if (belongsToChangedClip) {
          final relativeStartMs = (clip.startTime - liveTarget.startTime)
              .inMilliseconds
              .clamp(0, oldDurationMs)
              .toInt();
          final relativeEndMs = (clip.endTime - liveTarget.startTime)
              .inMilliseconds
              .clamp(relativeStartMs + 1, oldDurationMs)
              .toInt();
          final startRatio = relativeStartMs / oldDurationMs;
          final endRatio = relativeEndMs / oldDurationMs;
          final nextStart =
              liveTarget.startTime +
              Duration(
                milliseconds: (nextDuration.inMilliseconds * startRatio)
                    .round(),
              );
          final scaledEnd =
              liveTarget.startTime +
              Duration(
                milliseconds: (nextDuration.inMilliseconds * endRatio).round(),
              );
          return clip.copyWith(
            linkedClipId: liveTarget.id,
            startTime: nextStart,
            endTime: scaledEnd > nextStart + const Duration(milliseconds: 80)
                ? scaledEnd
                : nextStart + const Duration(milliseconds: 80),
          );
        }
        if (isBase && clip.startTime >= oldEnd) {
          return clip.copyWith(
            startTime: clip.startTime + rippleDelta,
            endTime: clip.endTime + rippleDelta,
          );
        }
        return clip;
      }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
      return timelineTrack.copyWith(clips: clips);
    }).toList();
    final nextTracks = retimedTracks
        .map(
          (timelineTrack) =>
              timelineTrack.type == TimelineTrackType.subtitle &&
                  !timelineTrack.isLocked
              ? timelineTrack.copyWith(
                  clips: _removeSubtitleTimingCollisions(timelineTrack.clips),
                )
              : timelineTrack,
        )
        .toList();
    final markers = timeline.markers.map((marker) {
      if (isBase && marker.position >= oldEnd) {
        return marker.copyWith(position: marker.position + rippleDelta);
      }
      return marker;
    }).toList();
    final nextTimeline = timeline
        .copyWith(tracks: nextTracks, markers: markers)
        .prunedRelationships();
    if (nextTimeline.hasTrackOverlaps) {
      if (mounted && recordHistory) {
        SnackBarHelper.showInfo(
          context,
          'That speed would overlap another clip on this track.',
        );
      }
      return;
    }
    ref
        .read(editorProvider.notifier)
        .setTimeline(nextTimeline, recordHistory: recordHistory);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(nextTimeline.subtitleEntries);
  }

  List<TimelineClip> _removeSubtitleTimingCollisions(List<TimelineClip> clips) {
    final sorted = [...clips]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final result = <TimelineClip>[];
    var nextAvailable = Duration.zero;
    for (final clip in sorted) {
      final start = clip.startTime < nextAvailable
          ? nextAvailable
          : clip.startTime;
      final minimumEnd = start + const Duration(milliseconds: 80);
      final end = clip.endTime < minimumEnd ? minimumEnd : clip.endTime;
      result.add(clip.copyWith(startTime: start, endTime: end));
      nextAvailable = end + const Duration(milliseconds: 20);
    }
    return result;
  }

  bool _isVisualClip(TimelineClip? clip) {
    return clip?.supportsVisualEffects ?? false;
  }

  bool _canReverseClip(TimelineClip? clip) {
    return clip?.supportsReversePlayback ?? false;
  }

  void _toggleClipReverse(TimelineClip clip) {
    if (!_canReverseClip(clip)) return;
    final editorState = ref.read(editorProvider);
    final liveClip = _clipById(clip.id, editorState) ?? clip;
    final track = _trackForClip(liveClip, editorState);
    if (track == null || track.isLocked) return;
    final updatedVideo = liveClip.copyWith(isReversed: !liveClip.isReversed);
    final tracks = editorState.timeline.tracks.map((candidateTrack) {
      return candidateTrack.copyWith(
        clips: candidateTrack.clips.map((candidate) {
          if (candidate.id == liveClip.id) return updatedVideo;
          if (candidate.type == TimelineTrackType.audio &&
              isExactSeparatedAudioTransportMirror(
                video: liveClip,
                audio: candidate,
              )) {
            return syncSeparatedAudioTransport(
              audio: candidate,
              updatedVideo: updatedVideo,
            );
          }
          return candidate;
        }).toList(),
      );
    }).toList();
    ref
        .read(editorProvider.notifier)
        .setTimeline(editorState.timeline.copyWith(tracks: tracks));
  }

  void _setClipFit(TimelineClip clip, ClipFitMode fitMode) {
    if (!clip.supportsVisualEffects) return;
    _updateTimelineClip(clip, (current) => current.copyWith(fitMode: fitMode));
  }

  void _rotateClip(TimelineClip clip, double radians) {
    if (!clip.supportsVisualEffects) return;
    ref
        .read(editorProvider.notifier)
        .updateClipTransformAt(
          clipId: clip.id,
          absolutePosition: ref.read(playbackProvider).position,
          mapper: (current) =>
              current.copyWith(rotation: current.rotation + radians),
        );
  }

  void _toggleClipFlip(TimelineClip clip, {required bool horizontal}) {
    if (!clip.supportsVisualEffects) return;
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(
        transform: horizontal
            ? current.transform.copyWith(flipX: !current.transform.flipX)
            : current.transform.copyWith(flipY: !current.transform.flipY),
      ),
    );
  }

  void _changeClipLayer(TimelineClip clip, int delta) {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    final supportsLayering =
        track != null &&
        !track.isLocked &&
        track.section == TimelineTrackSection.overlay;
    if (!supportsLayering) return;
    final timeline = editorState.timeline;
    final overlayTracks = timeline.tracks
        .where(
          (candidate) =>
              candidate.section == TimelineTrackSection.overlay &&
              !candidate.isLocked &&
              candidate.acceptsClip(clip),
        )
        .toList();
    final sourceIndex = overlayTracks.indexWhere(
      (candidate) => candidate.id == track.id,
    );
    if (sourceIndex < 0) return;
    final step = delta > 0 ? -1 : 1;
    TimelineTrack? target;
    for (
      var index = sourceIndex + step;
      index >= 0 && index < overlayTracks.length;
      index += step
    ) {
      final candidate = overlayTracks[index];
      if (candidate.canPlaceClip(clip.copyWith(trackId: candidate.id))) {
        target = candidate;
        break;
      }
    }
    var tracks = [...timeline.tracks];
    if (target == null) {
      target = TimelineTrack(
        name: timeline.nextTrackNameForSection(TimelineTrackSection.overlay),
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
      );
      final sourceTimelineIndex = tracks.indexWhere(
        (candidate) => candidate.id == track.id,
      );
      final insertionIndex = delta > 0
          ? sourceTimelineIndex
          : sourceTimelineIndex + 1;
      tracks.insert(insertionIndex.clamp(0, tracks.length), target);
    }
    final moved = clip.copyWith(trackId: target.id, layer: 0);
    tracks = tracks.map((candidate) {
      final clips = candidate.clips
          .where((item) => item.id != clip.id)
          .toList();
      if (candidate.id == target!.id) clips.add(moved);
      clips.sort((a, b) => a.startTime.compareTo(b.startTime));
      return candidate.copyWith(clips: clips);
    }).toList();
    ref.read(editorProvider.notifier)
      ..setTimeline(timeline.copyWith(tracks: tracks))
      ..selectTrack(target.id)
      ..selectClip(clip.id);
  }

  void _toggleClipEnabled(TimelineClip clip) {
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(enabled: !current.enabled),
    );
  }

  void _resetClipTransform(TimelineClip clip) {
    if (!clip.supportsVisualEffects) return;
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(
        transform: const TimelineTransform(),
        crop: const ClipCropSettings(),
        fitMode: current.type == TimelineTrackType.video
            ? ClipFitMode.cover
            : ClipFitMode.contain,
      ),
    );
  }

  void _addEffectOverlay({
    TimelineClip? anchor,
    required TimelineEffectKind kind,
    required String label,
    ClipBlurSettings blur = const ClipBlurSettings(),
    ClipColorAdjustments colorAdjustments = const ClipColorAdjustments(),
  }) {
    final editorState = ref.read(editorProvider);
    final liveAnchor = anchor == null
        ? null
        : _clipById(anchor.id, editorState);
    final anchorTrack = _trackForClip(liveAnchor, editorState);
    final timeline = editorState.timeline;
    final playhead = ref.read(playbackProvider).position;
    final compositionEnd = _currentCompositionDuration(timeline);
    final startTime =
        liveAnchor != null &&
            anchorTrack != null &&
            !anchorTrack.isLocked &&
            liveAnchor.supportsVisualEffects
        ? liveAnchor.startTime
        : playhead;
    final requestedEnd =
        liveAnchor != null &&
            anchorTrack != null &&
            !anchorTrack.isLocked &&
            liveAnchor.supportsVisualEffects
        ? liveAnchor.endTime
        : playhead + const Duration(seconds: 4);
    final endTime = requestedEnd > compositionEnd
        ? compositionEnd
        : requestedEnd;
    if (endTime <= startTime) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead earlier to add this overlay.',
      );
      return;
    }
    final existingEffectTrack = timeline.tracks
        .where(
          (track) =>
              track.section == TimelineTrackSection.overlay &&
              !track.isLocked &&
              track.acceptsClipType(TimelineTrackType.effect),
        )
        .where(
          (track) => track.canPlaceClip(
            TimelineClip.effect(
              trackId: track.id,
              effectKind: kind,
              label: label,
              startTime: startTime,
              endTime: endTime,
            ),
          ),
        )
        .firstOrNull;
    final effectTrack =
        existingEffectTrack ??
        _createOptionalTrack(
          timeline,
          TimelineTrackSection.overlay,
          TimelineTrackType.effect,
        );
    if (effectTrack == null ||
        !effectTrack.acceptsClipType(TimelineTrackType.effect)) {
      SnackBarHelper.showInfo(
        context,
        'Add or unlock an overlay track before applying this effect.',
      );
      return;
    }
    final effectClip = TimelineClip.effect(
      trackId: effectTrack.id,
      effectKind: kind,
      label: label,
      startTime: startTime,
      endTime: endTime,
      blur: blur,
      colorAdjustments: colorAdjustments,
      layer: effectTrack.clips.length,
    );
    final updatedEffectTrack = effectTrack.copyWith(
      clips: [...effectTrack.clips, effectClip],
    );
    final nextTracks = existingEffectTrack != null
        ? timeline.tracks
              .map(
                (track) =>
                    track.id == effectTrack.id ? updatedEffectTrack : track,
              )
              .toList()
        : timeline.insertTrackUsingEditorRules(updatedEffectTrack).tracks;
    ref
        .read(editorProvider.notifier)
        .setTimeline(timeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier)
      ..selectTrack(effectTrack.id)
      ..selectClip(effectClip.id);
    if (mounted) {
      SnackBarHelper.showSuccess(
        context,
        '$label added as a movable timeline overlay',
      );
    }
  }

  Future<void> _openEffectStackSheet(
    TimelineClip? selectedClip, {
    required EditorEffectDomain domain,
    EditorEffectScope? preferredScope,
  }) async {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final liveClip = selectedClip == null
        ? null
        : _clipById(selectedClip.id, editorState);
    final track = liveClip == null
        ? null
        : _trackForClip(liveClip, editorState);
    final targets = <EffectStackTargetOption>[];

    if (liveClip != null && track != null) {
      final supportsDomain = domain == EditorEffectDomain.visual
          ? liveClip.supportsVisualEffects || liveClip.isAdjustmentLayer
          : timeline.clipHasAudio(liveClip);
      if (supportsDomain) {
        targets.add(
          EffectStackTargetOption(
            scope: liveClip.isAdjustmentLayer
                ? EditorEffectScope.adjustmentLayer
                : EditorEffectScope.clip,
            targetId: liveClip.id,
            label: liveClip.isAdjustmentLayer
                ? liveClip.label
                : 'Clip • ${liveClip.label}',
            description: liveClip.isAdjustmentLayer
                ? 'Affects visual layers beneath it'
                : 'Only this timeline clip',
          ),
        );
      }

      final compound = liveClip.compoundId == null
          ? null
          : timeline.compoundClips
                .where((candidate) => candidate.id == liveClip.compoundId)
                .firstOrNull;
      if (compound != null) {
        targets.add(
          EffectStackTargetOption(
            scope: EditorEffectScope.compound,
            targetId: compound.id,
            label: 'Compound • ${compound.name}',
            description: '${compound.clipIds.length} linked visual clips',
          ),
        );
      }

      final group = liveClip.groupId == null
          ? null
          : timeline.groups
                .where((candidate) => candidate.id == liveClip.groupId)
                .firstOrNull;
      if (group != null) {
        targets.add(
          EffectStackTargetOption(
            scope: EditorEffectScope.group,
            targetId: group.id,
            label: 'Group • ${group.name}',
            description: '${group.clipIds.length} linked clips',
          ),
        );
      }

      targets.add(
        EffectStackTargetOption(
          scope: EditorEffectScope.track,
          targetId: track.id,
          label: 'Track • ${track.displayName}',
          description: 'Every compatible clip on this track',
        ),
      );
      if (domain == EditorEffectDomain.audio && track.audioBusId != null) {
        final bus = timeline.audioBuses
            .where((candidate) => candidate.id == track.audioBusId)
            .firstOrNull;
        if (bus != null) {
          targets.add(
            EffectStackTargetOption(
              scope: EditorEffectScope.audioBus,
              targetId: bus.id,
              label: 'Bus • ${bus.name}',
              description: 'Post-mix processing for assigned tracks',
            ),
          );
        }
      }
    }

    targets.add(
      EffectStackTargetOption(
        scope: EditorEffectScope.project,
        targetId: null,
        label: domain == EditorEffectDomain.visual
            ? 'Entire project'
            : 'Master output',
        description: domain == EditorEffectDomain.visual
            ? 'Runs after the complete visual composition'
            : 'Runs after buses and before the master limiter',
      ),
    );

    final initialTarget = preferredScope == null
        ? targets.first
        : targets.firstWhere(
            (target) => target.scope == preferredScope,
            orElse: () => targets.first,
          );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.58),
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.92,
        child: EffectStackEditorSheet(
          domain: domain,
          targets: targets,
          initialTargetKey: initialTarget.key,
        ),
      ),
    );
  }

  Future<void> _createAdjustmentLayerAtPlayhead() async {
    final timeline = ref.read(editorProvider).timeline;
    if (timeline.duration <= Duration.zero) {
      SnackBarHelper.showError(context, 'Add visual media first.');
      return;
    }
    final playhead = ref.read(playbackProvider).position;
    final endTime = timeline.duration;
    final preferredStart = playhead < endTime
        ? playhead
        : endTime - const Duration(seconds: 3);
    final startTime = preferredStart.isNegative
        ? Duration.zero
        : preferredStart;
    if (endTime - startTime < const Duration(milliseconds: 100)) {
      SnackBarHelper.showError(context, 'Move the playhead earlier first.');
      return;
    }
    final id = ref
        .read(editorProvider.notifier)
        .createAdjustmentLayer(startTime: startTime, endTime: endTime);
    if (id == null || !mounted) {
      SnackBarHelper.showError(context, 'Could not place an adjustment layer.');
      return;
    }
    final state = ref.read(editorProvider);
    final clip = _clipById(id, state);
    if (clip != null) {
      await _openEffectStackSheet(clip, domain: EditorEffectDomain.visual);
    }
  }

  void _replaceFilterEffect(TimelineClip effectClip, ClipFilterPreset preset) {
    final adjustments = ClipColorAdjustments.forPreset(preset);
    _updateTimelineClip(
      effectClip,
      (current) => current.copyWith(
        label: '${_filterPresetLabel(preset)} filter',
        colorAdjustments: adjustments,
      ),
    );
  }

  void _setBlurMode(TimelineClip clip, ClipBlurMode mode) {
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(
        label: current.isEffect
            ? (mode == ClipBlurMode.region ? 'Region blur' : 'Whole blur')
            : current.label,
        blur: current.blur.copyWith(mode: mode),
      ),
    );
  }

  Future<void> _openBlurSheet(TimelineClip initialClip) async {
    final editorState = ref.read(editorProvider);
    final initialTrack = _trackForClip(initialClip, editorState);
    final isBlurEffect =
        initialClip.isEffect &&
        initialClip.effectKind == TimelineEffectKind.blur;
    if (initialTrack == null ||
        initialTrack.isLocked ||
        (!isBlurEffect && !initialClip.supportsVisualEffects)) {
      return;
    }
    var clip = _clipById(initialClip.id, editorState) ?? initialClip;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(
            ClipBlurSettings Function(ClipBlurSettings current) mapper, {
            bool recordHistory = true,
          }) {
            _updateTimelineClip(
              clip,
              (current) => current.copyWith(blur: mapper(current.blur)),
              recordHistory: recordHistory,
            );
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest != null) setSheetState(() => clip = latest);
          }

          void updateStrength(double strength, {bool recordHistory = true}) {
            ref
                .read(editorProvider.notifier)
                .updateClipBlurStrengthAt(
                  clipId: clip.id,
                  absolutePosition: ref.read(playbackProvider).position,
                  strength: strength,
                  recordHistory: recordHistory,
                );
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest != null) setSheetState(() => clip = latest);
          }

          final blur = clip.blurAt(ref.read(playbackProvider).position);
          Widget regionSlider({
            required String label,
            required double value,
            required double maximum,
            required ClipBlurSettings Function(double value) mapper,
          }) {
            final safeMaximum = math.max(0.01, maximum);
            return Column(
              children: [
                _sheetSliderHeader(label, '${(value * 100).round()}%'),
                Slider(
                  value: value.clamp(0.0, safeMaximum).toDouble(),
                  min: 0,
                  max: safeMaximum,
                  divisions: math.max(1, (safeMaximum * 100).round()),
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (next) =>
                      update((_) => mapper(next), recordHistory: false),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
              ],
            );
          }

          return _buildEditorSheet(
            title: 'Blur',
            subtitle: 'Rendered in preview and final export',
            resizable: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('MODE'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Whole frame'),
                      selected: blur.mode == ClipBlurMode.full,
                      onSelected: (_) => update(
                        (current) => current.copyWith(mode: ClipBlurMode.full),
                      ),
                    ),
                    ChoiceChip(
                      label: const Text('Privacy region'),
                      selected: blur.mode == ClipBlurMode.region,
                      onSelected: (_) => update(
                        (current) =>
                            current.copyWith(mode: ClipBlurMode.region),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _sheetSliderHeader(
                  'Strength',
                  blur.safeStrength.toStringAsFixed(1),
                ),
                Slider(
                  value: blur.safeStrength,
                  min: 0.5,
                  max: 30,
                  divisions: 118,
                  label: blur.safeStrength.toStringAsFixed(1),
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (value) =>
                      updateStrength(value, recordHistory: false),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
                if (blur.mode == ClipBlurMode.region) ...[
                  const SizedBox(height: 14),
                  _sheetSectionTitle('REGION'),
                  const SizedBox(height: 6),
                  regionSlider(
                    label: 'Left',
                    value: blur.safeRegionX,
                    maximum: 1 - blur.safeRegionWidth,
                    mapper: (value) => blur.copyWith(regionX: value),
                  ),
                  regionSlider(
                    label: 'Top',
                    value: blur.safeRegionY,
                    maximum: 1 - blur.safeRegionHeight,
                    mapper: (value) => blur.copyWith(regionY: value),
                  ),
                  regionSlider(
                    label: 'Width',
                    value: blur.safeRegionWidth,
                    maximum: 1,
                    mapper: (value) => blur.copyWith(
                      regionWidth: value
                          .clamp(0.08, 1 - blur.safeRegionX)
                          .toDouble(),
                    ),
                  ),
                  regionSlider(
                    label: 'Height',
                    value: blur.safeRegionHeight,
                    maximum: 1,
                    mapper: (value) => blur.copyWith(
                      regionHeight: value
                          .clamp(0.08, 1 - blur.safeRegionY)
                          .toDouble(),
                    ),
                  ),
                  const Text(
                    'You can also drag and resize the privacy region directly on the preview.',
                    style: TextStyle(color: kTextSecondary, fontSize: 11),
                  ),
                ],
                if (clip.keyframes.any(
                  (frame) =>
                      frame.property == TimelineKeyframeProperty.blurStrength,
                )) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Blur strength is animated by keyframes on this clip.',
                    style: TextStyle(color: kAccentSecondary, fontSize: 11),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _toggleClipMute(TimelineClip clip) {
    final timeline = ref.read(editorProvider).timeline;
    if (!timeline.clipHasAudio(clip)) return;
    final owner = _audioOwnerForClip(timeline, clip);
    if (owner == null || owner.track.isLocked) return;
    _updateTimelineClip(
      owner.clip,
      (current) => current.copyWith(
        audioMix: current.audioMix.copyWith(muted: !current.audioMix.muted),
      ),
    );
  }

  bool _separateVideoAudio(TimelineClip videoClip) {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final liveVideo = _clipById(videoClip.id, editorState);
    final videoTrack = _trackForClip(liveVideo, editorState);
    if (liveVideo == null ||
        videoTrack == null ||
        videoTrack.isLocked ||
        liveVideo.type != TimelineTrackType.video ||
        !timeline.clipHasAudio(liveVideo)) {
      return false;
    }

    for (final track in timeline.tracks) {
      final existing = track.clips
          .where(
            (candidate) =>
                candidate.type == TimelineTrackType.audio &&
                candidate.linkedClipId == liveVideo.id,
          )
          .firstOrNull;
      if (existing != null) {
        ref.read(editorProvider.notifier)
          ..selectTrack(track.id)
          ..selectClip(existing.id);
        SnackBarHelper.showInfo(
          context,
          'This video audio is already separate.',
        );
        return false;
      }
    }

    final audioProbe = TimelineClip(
      trackId: '',
      type: TimelineTrackType.audio,
      label: '${liveVideo.label} audio',
      assetId: liveVideo.assetId,
      linkedClipId: liveVideo.id,
      startTime: liveVideo.startTime,
      endTime: liveVideo.endTime,
      sourceStartTime: liveVideo.sourceStartTime,
      sourceDuration: liveVideo.sourceDuration,
      playbackRate: liveVideo.playbackRate,
      isReversed: liveVideo.isReversed,
      // Transfer the current mix exactly. A video that the user muted before
      // separating should not unexpectedly become audible again.
      audioMix: liveVideo.audioMix,
      effectStack: EditorEffectStack(
        effects: liveVideo.effectStack.effects
            .where((effect) => effect.type.domain == EditorEffectDomain.audio)
            .toList(),
      ),
      autoDuck: liveVideo.autoDuck,
      duckAmount: liveVideo.duckAmount,
      duckAttackMs: liveVideo.duckAttackMs,
      duckReleaseMs: liveVideo.duckReleaseMs,
      duckSidechainTrackIds: liveVideo.duckSidechainTrackIds,
      denoise: liveVideo.denoise,
    );
    var audioTrack = timeline.tracks
        .where(
          (track) =>
              track.section == TimelineTrackSection.audio &&
              track.role == TimelineTrackRole.regular &&
              !track.isLocked &&
              track.acceptsClipType(TimelineTrackType.audio) &&
              track.canPlaceClip(audioProbe.copyWith(trackId: track.id)),
        )
        .firstOrNull;
    audioTrack ??= TimelineTrack(
      name: timeline.nextTrackNameForSection(TimelineTrackSection.audio),
      type: TimelineTrackType.audio,
      section: TimelineTrackSection.audio,
    );

    var workingTimeline = timeline;
    if (!timeline.tracks.any((track) => track.id == audioTrack!.id)) {
      workingTimeline = timeline.insertTrackUsingEditorRules(audioTrack);
    }
    final separatedAudio = audioProbe.copyWith(trackId: audioTrack.id);
    final nextTracks = workingTimeline.tracks.map((track) {
      if (track.id == liveVideo.trackId) {
        return track.copyWith(
          clips: track.clips
              .map(
                (candidate) => candidate.id == liveVideo.id
                    ? candidate.copyWith(
                        audioMix: candidate.audioMix.copyWith(muted: true),
                        effectStack: EditorEffectStack(
                          effects: candidate.effectStack.effects
                              .where(
                                (effect) =>
                                    effect.type.domain ==
                                    EditorEffectDomain.visual,
                              )
                              .toList(),
                        ),
                      )
                    : candidate,
              )
              .toList(),
        );
      }
      if (track.id == audioTrack!.id) {
        final clips = [...track.clips, separatedAudio]
          ..sort((a, b) => a.startTime.compareTo(b.startTime));
        return track.copyWith(clips: clips);
      }
      return track;
    }).toList();
    ref
        .read(editorProvider.notifier)
        .setTimeline(workingTimeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier)
      ..selectTrack(audioTrack.id)
      ..selectClip(separatedAudio.id);
    SnackBarHelper.showSuccess(
      context,
      'Video audio moved to a separate track.',
    );
    return true;
  }

  void _toggleClipNormalize(TimelineClip clip) {
    final timeline = ref.read(editorProvider).timeline;
    if (!timeline.clipHasAudio(clip)) return;
    final owner = _audioOwnerForClip(timeline, clip);
    if (owner == null || owner.track.isLocked) return;
    _updateTimelineClip(
      owner.clip,
      (current) => current.copyWith(
        audioMix: current.audioMix.copyWith(
          normalize: !current.audioMix.normalize,
        ),
      ),
    );
  }

  void _toggleQuickFade(TimelineClip clip, {required bool fadeIn}) {
    final timeline = ref.read(editorProvider).timeline;
    if (!timeline.clipHasAudio(clip)) return;
    final owner = _audioOwnerForClip(timeline, clip);
    if (owner == null || owner.track.isLocked) return;
    _updateTimelineClip(owner.clip, (current) {
      final mix = current.audioMix;
      return current.copyWith(
        audioMix: fadeIn
            ? mix.copyWith(fadeInMs: mix.fadeInMs == 0 ? 500 : 0)
            : mix.copyWith(fadeOutMs: mix.fadeOutMs == 0 ? 500 : 0),
      );
    });
  }

  void _duplicateClip(TimelineClip clip) {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to duplicate clips.');
      return;
    }
    final timeline = editorState.timeline;
    final desiredStart = track.section == TimelineTrackSection.baseVideo
        ? track.clips.fold<Duration>(
            Duration.zero,
            (latest, candidate) =>
                candidate.endTime > latest ? candidate.endTime : latest,
          )
        : clip.endTime;
    final newStart = track.closestAvailableStart(
      desiredStart: desiredStart,
      duration: clip.duration,
    );
    final separatedAudio = clip.type == TimelineTrackType.video
        ? _separatedAudioForVideo(timeline, clip.id)
        : null;
    var duplicate = clip.copyWith(
      id: const Uuid().v4(),
      startTime: newStart,
      endTime: newStart + clip.duration,
      clearLinkedClipId: true,
      effectStack: clip.effectStack.cloneWithNewIds(),
      clearGroupId: true,
      clearCompoundId: true,
    );
    if (separatedAudio != null) {
      // A duplicate starts with attached audio again; it must not become
      // mysteriously silent just because the original owns a separated lane.
      duplicate = restoreAttachedAudioForDuplicate(
        duplicateVideo: duplicate,
        separatedAudio: separatedAudio.clip,
      );
    }
    final nextTracks = timeline.tracks.map((candidate) {
      if (candidate.id != track.id) return candidate;
      final clips = [...candidate.clips, duplicate]
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
      return candidate.copyWith(clips: clips);
    }).toList();
    ref
        .read(editorProvider.notifier)
        .setTimeline(timeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier)
      ..selectTrack(track.id)
      ..selectClip(duplicate.id);
  }

  Future<void> _deleteClip(TimelineClip clip) async {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to delete clips.');
      return;
    }
    final timeline = editorState.timeline;
    if (clip.type.isVisualMedia &&
        !timeline.wouldRetainVisualContentAfterRemoving([clip.id])) {
      final action = await showDialog<_LastVisualAction>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Keep one visual'),
          content: const Text(
            'A project needs at least one image, GIF, sticker, or video. '
            'Replace this clip before removing it.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _LastVisualAction.cancel),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () =>
                  Navigator.pop(dialogContext, _LastVisualAction.replace),
              icon: const Icon(Icons.swap_horiz_rounded),
              label: const Text('Replace'),
            ),
          ],
        ),
      );
      if (action == _LastVisualAction.replace && mounted) {
        await _relinkClipMedia(clip);
      }
      return;
    }
    final nextTracks = timeline.tracks.map((candidate) {
      if (candidate.id != track.id && candidate.isLocked) {
        final dependentClips = candidate.clips
            .where((item) => item.linkedClipId != clip.id)
            .toList();
        return dependentClips.length == candidate.clips.length
            ? candidate
            : candidate.copyWith(clips: dependentClips);
      }
      final clips = candidate.clips
          .where(
            (item) =>
                item.id != clip.id &&
                (item.linkedClipId == null || item.linkedClipId != clip.id),
          )
          .toList();
      return candidate.copyWith(clips: clips);
    }).toList();
    final remainingClipIds = nextTracks
        .expand((candidate) => candidate.clips)
        .map((candidate) => candidate.id)
        .toSet();
    final nextGroups = timeline.groups
        .map(
          (group) => group.copyWith(
            clipIds: group.clipIds.where(remainingClipIds.contains),
          ),
        )
        .where((group) => group.clipIds.isNotEmpty)
        .toList();
    final nextCompounds = timeline.compoundClips
        .map(
          (compound) => compound.copyWith(
            clipIds: compound.clipIds.where(remainingClipIds.contains),
          ),
        )
        .where((compound) => compound.clipIds.isNotEmpty)
        .toList();
    final validGroupIds = nextGroups.map((group) => group.id).toSet();
    final validCompoundIds = nextCompounds
        .map((compound) => compound.id)
        .toSet();
    final nextTimeline = timeline.copyWith(
      tracks: nextTracks,
      groups: nextGroups,
      compoundClips: nextCompounds,
      effectContainers: timeline.effectContainers.where((container) {
        return switch (container.scope) {
          EditorEffectScope.clip || EditorEffectScope.adjustmentLayer =>
            remainingClipIds.contains(container.targetId),
          EditorEffectScope.group => validGroupIds.contains(container.targetId),
          EditorEffectScope.compound => validCompoundIds.contains(
            container.targetId,
          ),
          _ => true,
        };
      }).toList(),
    );
    ref.read(editorProvider.notifier)
      ..setTimeline(nextTimeline)
      ..selectClip(null);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(nextTimeline.subtitleEntries);
  }

  void _splitClipAtPlayhead(TimelineClip clip) {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final track = _trackForClip(clip, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to split clips.');
      return;
    }
    final splitPoint = ref.read(playbackProvider).position;
    if (splitPoint <= clip.startTime ||
        splitPoint >= clip.endTime ||
        (splitPoint - clip.startTime).inMilliseconds < 100 ||
        (clip.endTime - splitPoint).inMilliseconds < 100) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead inside the selected clip to split it.',
      );
      return;
    }

    final rightId = const Uuid().v4();
    final timelineOffsetMs = (splitPoint - clip.startTime).inMilliseconds;
    final sourceOffsetMs = (timelineOffsetMs * clip.playbackRate).round();
    final sourceDurationMs = math.max(
      sourceOffsetMs + 1,
      clip.sourceDuration.inMilliseconds,
    );
    final keyframeSplit = TimelineKeyframeEditing.split(
      clip,
      Duration(milliseconds: timelineOffsetMs),
    );
    final effectStackSplit = clip.effectStack.splitAt(
      Duration(milliseconds: timelineOffsetMs),
    );
    final leftSourceStart = clip.isReversed
        ? clip.sourceStartTime +
              Duration(milliseconds: sourceDurationMs - sourceOffsetMs)
        : clip.sourceStartTime;
    final rightSourceStart = clip.isReversed
        ? clip.sourceStartTime
        : clip.sourceStartTime + Duration(milliseconds: sourceOffsetMs);
    final left = clip.copyWith(
      endTime: splitPoint,
      sourceStartTime: leftSourceStart,
      sourceDuration: Duration(milliseconds: sourceOffsetMs),
      keyframes: keyframeSplit.leading,
      effectStack: effectStackSplit.leading,
      outroTransition: const ClipTransition(),
      audioMix: clip.audioMix.copyWith(fadeOutMs: 0),
    );
    final right = clip.copyWith(
      id: rightId,
      startTime: splitPoint,
      sourceStartTime: rightSourceStart,
      sourceDuration: Duration(
        milliseconds: math.max(1, sourceDurationMs - sourceOffsetMs),
      ),
      keyframes: keyframeSplit.trailing,
      effectStack: effectStackSplit.trailing,
      introTransition: const ClipTransition(),
      audioMix: clip.audioMix.copyWith(fadeInMs: 0),
    );

    final nextTracks = <TimelineTrack>[];
    for (final candidateTrack in timeline.tracks) {
      if (candidateTrack.id == track.id) {
        final clips = <TimelineClip>[];
        for (final candidate in candidateTrack.clips) {
          if (candidate.id == clip.id) {
            clips.addAll([left, right]);
          } else {
            clips.add(candidate);
          }
        }
        clips.sort((a, b) => a.startTime.compareTo(b.startTime));
        nextTracks.add(candidateTrack.copyWith(clips: clips));
        continue;
      }
      if (candidateTrack.type == TimelineTrackType.audio) {
        final audioClips = <TimelineClip>[];
        for (final audio in candidateTrack.clips) {
          if (!isExactSeparatedAudioTransportMirror(
            video: clip,
            audio: audio,
          )) {
            audioClips.add(audio);
            continue;
          }
          final splitAudio = splitExactSeparatedAudioMirror(
            originalVideo: clip,
            leftVideo: left,
            rightVideo: right,
            audio: audio,
            rightAudioId: const Uuid().v4(),
            splitAt: splitPoint,
          );
          audioClips.addAll([splitAudio.left, splitAudio.right]);
        }
        audioClips.sort((a, b) => a.startTime.compareTo(b.startTime));
        nextTracks.add(candidateTrack.copyWith(clips: audioClips));
        continue;
      }
      if (candidateTrack.type != TimelineTrackType.subtitle) {
        nextTracks.add(candidateTrack);
        continue;
      }
      final captions = <TimelineClip>[];
      for (final caption in candidateTrack.clips) {
        if (caption.linkedClipId != clip.id || caption.endTime <= splitPoint) {
          captions.add(caption);
        } else if (caption.startTime >= splitPoint) {
          captions.add(caption.copyWith(linkedClipId: rightId));
        } else {
          captions.add(caption.copyWith(endTime: splitPoint));
          captions.add(
            caption.copyWith(
              id: const Uuid().v4(),
              linkedClipId: rightId,
              startTime: splitPoint,
            ),
          );
        }
      }
      captions.sort((a, b) => a.startTime.compareTo(b.startTime));
      nextTracks.add(candidateTrack.copyWith(clips: captions));
    }
    final nextTimeline = timeline.copyWith(
      tracks: nextTracks,
      groups: timeline.groups
          .map(
            (group) => group.id == clip.groupId
                ? group.copyWith(clipIds: [...group.clipIds, rightId])
                : group,
          )
          .toList(),
      compoundClips: timeline.compoundClips
          .map(
            (compound) => compound.id == clip.compoundId
                ? compound.copyWith(clipIds: [...compound.clipIds, rightId])
                : compound,
          )
          .toList(),
    );
    ref.read(editorProvider.notifier)
      ..setTimeline(nextTimeline)
      ..selectClip(rightId);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(nextTimeline.subtitleEntries);
  }

  int _assetDurationMs(EditorTimeline timeline, TimelineClip clip) {
    final asset = timeline.assetForClip(clip);
    final metadataDuration = (asset?.metadata['durationMs'] as num?)?.toInt();
    if (metadataDuration != null && metadataDuration > 0) {
      return metadataDuration;
    }
    return math.max(
      100,
      clip.sourceStartTime.inMilliseconds +
          math.max(clip.sourceDuration.inMilliseconds, 100),
    );
  }

  void _applySourceTrim(
    TimelineClip target, {
    required int sourceStartMs,
    required int sourceEndMs,
  }) {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final track = _trackForClip(target, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to trim this clip.');
      return;
    }
    final assetDurationMs = _assetDurationMs(timeline, target);
    final safeStart = sourceStartMs.clamp(0, assetDurationMs - 100).toInt();
    final safeEnd = sourceEndMs.clamp(safeStart + 100, assetDurationMs).toInt();
    final sourceDuration = Duration(milliseconds: safeEnd - safeStart);
    final nextDuration = Duration(
      milliseconds: math.max(
        100,
        (sourceDuration.inMilliseconds / target.playbackRate).round(),
      ),
    );
    final nextEnd = target.startTime + nextDuration;
    final oldEnd = target.endTime;
    final rippleDelta = nextEnd - oldEnd;
    final isBase = track.section == TimelineTrackSection.baseVideo;
    final updatedTarget = target.copyWith(
      sourceStartTime: Duration(milliseconds: safeStart),
      sourceDuration: sourceDuration,
      endTime: nextEnd,
      keyframes: TimelineKeyframeEditing.forNewEnd(target, nextEnd),
      effectStack: target.effectStack.trimmedToDuration(nextDuration),
    );

    final nextTracks = timeline.tracks.map((candidateTrack) {
      final clips = candidateTrack.clips.map((clip) {
        if (clip.id == target.id) {
          return updatedTarget;
        }
        if (clip.type == TimelineTrackType.audio &&
            clip.linkedClipId == target.id) {
          return isExactSeparatedAudioTransportMirror(
                video: target,
                audio: clip,
              )
              ? syncSeparatedAudioTransport(
                  audio: clip,
                  updatedVideo: updatedTarget,
                )
              : clip;
        }
        if (candidateTrack.type == TimelineTrackType.subtitle &&
            clip.linkedClipId == target.id) {
          final oldDurationMs = math.max(1, target.duration.inMilliseconds);
          final startRatio =
              (clip.startTime - target.startTime).inMilliseconds /
              oldDurationMs;
          final endRatio =
              (clip.endTime - target.startTime).inMilliseconds / oldDurationMs;
          return clip.copyWith(
            startTime:
                target.startTime +
                Duration(
                  milliseconds: (nextDuration.inMilliseconds * startRatio)
                      .round(),
                ),
            endTime:
                target.startTime +
                Duration(
                  milliseconds: (nextDuration.inMilliseconds * endRatio)
                      .round(),
                ),
          );
        }
        if (isBase && clip.startTime >= oldEnd) {
          return clip.copyWith(
            startTime: clip.startTime + rippleDelta,
            endTime: clip.endTime + rippleDelta,
          );
        }
        return clip;
      }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
      return candidateTrack.copyWith(clips: clips);
    }).toList();
    final markers = timeline.markers.map((marker) {
      if (isBase && marker.position >= oldEnd) {
        return marker.copyWith(position: marker.position + rippleDelta);
      }
      return marker;
    }).toList();
    final nextTimeline = timeline.copyWith(
      tracks: nextTracks,
      markers: markers,
    );
    if (nextTimeline.hasTrackOverlaps) {
      SnackBarHelper.showInfo(
        context,
        'That trim would overlap another clip on this track.',
      );
      return;
    }
    ref.read(editorProvider.notifier).setTimeline(nextTimeline);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(nextTimeline.subtitleEntries);
  }

  void _updateCanvasSettings(
    CanvasSettings Function(CanvasSettings current) mapper, {
    bool recordHistory = true,
  }) {
    final editorState = ref.read(editorProvider);
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          editorState.timeline.copyWith(
            canvasSettings: mapper(editorState.timeline.canvasSettings),
          ),
          recordHistory: recordHistory,
        );
  }

  Future<void> _openClipInspectorSheet(TimelineClip initialClip) async {
    final initialState = ref.read(editorProvider);
    final initialTrack = _trackForClip(initialClip, initialState);
    if (!initialClip.supportsVisualEffects ||
        initialTrack == null ||
        initialTrack.isLocked) {
      return;
    }
    var clip = initialClip;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void refreshClip() {
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest != null) {
              setSheetState(() => clip = latest);
            }
          }

          void update(
            TimelineClip Function(TimelineClip current) mapper, {
            bool recordHistory = true,
          }) {
            _updateTimelineClip(clip, mapper, recordHistory: recordHistory);
            refreshClip();
          }

          void updateTransform(
            TimelineTransform Function(TimelineTransform current) mapper, {
            bool recordHistory = true,
          }) {
            ref
                .read(editorProvider.notifier)
                .updateClipTransformAt(
                  clipId: clip.id,
                  absolutePosition: ref.read(playbackProvider).position,
                  mapper: mapper,
                  recordHistory: recordHistory,
                );
            refreshClip();
          }

          final resolvedTransform = clip.transformAt(
            ref.read(playbackProvider).position,
          );

          return _buildEditorSheet(
            title: 'Clip inspector',
            subtitle: clip.label,
            resizable: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('LAYOUT'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ClipFitMode.values.map((fit) {
                    return ChoiceChip(
                      label: Text(switch (fit) {
                        ClipFitMode.cover => 'Fill',
                        ClipFitMode.contain => 'Fit',
                        ClipFitMode.stretch => 'Stretch',
                      }),
                      selected: clip.fitMode == fit,
                      onSelected: (_) {
                        update((current) => current.copyWith(fitMode: fit));
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.rotate_left_rounded,
                        label: 'Rotate −90°',
                        onTap: () => updateTransform(
                          (current) => current.copyWith(
                            rotation: current.rotation - math.pi / 2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.rotate_right_rounded,
                        label: 'Rotate +90°',
                        onTap: () => updateTransform(
                          (current) => current.copyWith(
                            rotation: current.rotation + math.pi / 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.flip_rounded,
                        label: 'Flip horizontal',
                        active: clip.transform.flipX,
                        onTap: () => update(
                          (current) => current.copyWith(
                            transform: current.transform.copyWith(
                              flipX: !current.transform.flipX,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.flip_camera_android_rounded,
                        label: 'Flip vertical',
                        active: clip.transform.flipY,
                        onTap: () => update(
                          (current) => current.copyWith(
                            transform: current.transform.copyWith(
                              flipY: !current.transform.flipY,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _sheetSliderHeader(
                  'Opacity',
                  '${(resolvedTransform.opacity * 100).round()}%',
                ),
                Slider(
                  value: resolvedTransform.opacity.clamp(0.0, 1.0),
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (value) => updateTransform(
                    (current) => current.copyWith(opacity: value),
                    recordHistory: false,
                  ),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
                if (clip.type == TimelineTrackType.video ||
                    clip.type == TimelineTrackType.audio) ...[
                  const SizedBox(height: 10),
                  _sheetSectionTitle('SPEED'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: const [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0]
                        .map(
                          (speed) => ChoiceChip(
                            label: Text('${speed}x'),
                            selected: (clip.playbackRate - speed).abs() < 0.001,
                            onSelected: (_) {
                              _updateClipPlaybackRate(clip, speed);
                              refreshClip();
                            },
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 18),
                _sheetSectionTitle('LAYER'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.move_down_rounded,
                        label: 'Send backward',
                        onTap: () => update(
                          (current) => current.copyWith(
                            layer: math.max(0, current.layer - 1),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.move_up_rounded,
                        label: 'Bring forward',
                        onTap: () => update(
                          (current) =>
                              current.copyWith(layer: current.layer + 1),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Clip enabled'),
                  subtitle: const Text('Disabled clips are skipped in export'),
                  value: clip.enabled,
                  onChanged: (value) =>
                      update((current) => current.copyWith(enabled: value)),
                ),
                if (clip.assetId != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.link_rounded),
                    title: const Text('Relink media'),
                    subtitle: const Text('Replace a missing or moved source'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      await _relinkClipMedia(clip);
                      refreshClip();
                    },
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => update(
                    (current) => current.copyWith(
                      transform: const TimelineTransform(),
                      fitMode: current.type == TimelineTrackType.video
                          ? ClipFitMode.cover
                          : ClipFitMode.contain,
                    ),
                  ),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Reset transform'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openTimingSheet(TimelineClip initialClip) async {
    final initialState = ref.read(editorProvider);
    final initialTrack = _trackForClip(initialClip, initialState);
    if (!initialClip.supportsSourceTiming ||
        initialTrack == null ||
        initialTrack.isLocked) {
      return;
    }
    var clip = initialClip;
    final initialTimeline = ref.read(editorProvider).timeline;
    final initialAssetDurationMs = _assetDurationMs(initialTimeline, clip);
    var trimRange = RangeValues(
      clip.sourceStartTime.inMilliseconds
          .clamp(0, initialAssetDurationMs - 100)
          .toDouble(),
      (clip.sourceStartTime.inMilliseconds +
              math.max(100, clip.sourceDuration.inMilliseconds))
          .clamp(100, initialAssetDurationMs)
          .toDouble(),
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void refreshClip() {
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest == null) return;
            setSheetState(() {
              clip = latest;
              final timeline = ref.read(editorProvider).timeline;
              final assetDurationMs = _assetDurationMs(timeline, latest);
              trimRange = RangeValues(
                latest.sourceStartTime.inMilliseconds
                    .clamp(0, assetDurationMs - 100)
                    .toDouble(),
                (latest.sourceStartTime.inMilliseconds +
                        math.max(100, latest.sourceDuration.inMilliseconds))
                    .clamp(100, assetDurationMs)
                    .toDouble(),
              );
            });
          }

          final timeline = ref.read(editorProvider).timeline;
          final assetDurationMs = _assetDurationMs(timeline, clip);
          final canReverse = _canReverseClip(clip);
          return _buildEditorSheet(
            title: 'Timing',
            subtitle: canReverse
                ? 'Trim, speed, split and reverse'
                : 'Trim, speed and split',
            resizable: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('SOURCE TRIM'),
                const SizedBox(height: 5),
                Text(
                  '${_formatEditorDuration(Duration(milliseconds: trimRange.start.round()))}'
                  '  —  '
                  '${_formatEditorDuration(Duration(milliseconds: trimRange.end.round()))}',
                  style: const TextStyle(
                    color: kTextSecondary,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
                RangeSlider(
                  values: RangeValues(
                    trimRange.start.clamp(0, assetDurationMs - 100).toDouble(),
                    trimRange.end.clamp(100, assetDurationMs).toDouble(),
                  ),
                  min: 0,
                  max: assetDurationMs.toDouble(),
                  divisions: (assetDurationMs ~/ 100).clamp(1, 1000),
                  labels: RangeLabels(
                    _formatEditorDuration(
                      Duration(milliseconds: trimRange.start.round()),
                    ),
                    _formatEditorDuration(
                      Duration(milliseconds: trimRange.end.round()),
                    ),
                  ),
                  onChanged: (value) {
                    if (value.end - value.start < 100) return;
                    setSheetState(() => trimRange = value);
                  },
                  onChangeEnd: (value) {
                    _applySourceTrim(
                      clip,
                      sourceStartMs: value.start.round(),
                      sourceEndMs: value.end.round(),
                    );
                    refreshClip();
                  },
                ),
                const SizedBox(height: 14),
                _sheetSectionTitle('SPEED'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: const [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0]
                      .map(
                        (speed) => ChoiceChip(
                          label: Text('${speed}x'),
                          selected: (clip.playbackRate - speed).abs() < 0.001,
                          onSelected: (_) {
                            _updateClipPlaybackRate(clip, speed);
                            refreshClip();
                          },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 8),
                _sheetSliderHeader(
                  'Fine speed',
                  '${clip.playbackRate.toStringAsFixed(2)}x',
                ),
                Slider(
                  value: clip.playbackRate.clamp(0.25, 4),
                  min: 0.25,
                  max: 4,
                  divisions: 75,
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (value) {
                    _updateClipPlaybackRate(clip, value, recordHistory: false);
                    refreshClip();
                  },
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
                if (canReverse) ...[
                  const SizedBox(height: 10),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Reverse playback'),
                    subtitle: const Text(
                      'Preview scrubs backward; export reverses picture and audio',
                    ),
                    value: clip.isReversed,
                    onChanged: (_) {
                      _toggleClipReverse(clip);
                      refreshClip();
                    },
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.content_cut_rounded,
                        label: 'Split at playhead',
                        onTap: () {
                          _splitClipAtPlayhead(clip);
                          Navigator.pop(context);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.restart_alt_rounded,
                        label: 'Reset speed',
                        onTap: () {
                          _updateClipPlaybackRate(clip, 1);
                          refreshClip();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatEditorDuration(Duration duration) {
    final totalMs = math.max(0, duration.inMilliseconds);
    final minutes = totalMs ~/ 60000;
    final seconds = (totalMs % 60000) ~/ 1000;
    final millis = totalMs % 1000;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
  }

  ClipCropSettings _centerCropForAspect(
    TimelineClip clip,
    double targetAspect,
  ) {
    final timeline = ref.read(editorProvider).timeline;
    final asset = timeline.assetForClip(clip);
    var width = (asset?.metadata['width'] as num?)?.toDouble() ?? 0;
    var height = (asset?.metadata['height'] as num?)?.toDouble() ?? 0;
    if (width <= 0 || height <= 0) {
      final canvasAspect = _selectedAspectRatioValue;
      width = canvasAspect ?? 16 / 9;
      height = 1;
    }
    final sourceAspect = width / height;
    if ((sourceAspect - targetAspect).abs() < 0.001) {
      return const ClipCropSettings();
    }
    if (sourceAspect > targetAspect) {
      final visibleWidth = (targetAspect / sourceAspect).clamp(0.05, 1.0);
      final inset = (1 - visibleWidth) / 2;
      return ClipCropSettings(left: inset, right: inset);
    }
    final visibleHeight = (sourceAspect / targetAspect).clamp(0.05, 1.0);
    final inset = (1 - visibleHeight) / 2;
    return ClipCropSettings(top: inset, bottom: inset);
  }

  Future<void> _openCropSheet(TimelineClip initialClip) async {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(initialClip, editorState);
    if (!_isVisualClip(initialClip) || track == null || track.isLocked) return;
    var clip = initialClip;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(ClipCropSettings crop, {bool recordHistory = true}) {
            _updateTimelineClip(
              clip,
              (current) => current.copyWith(crop: crop),
              recordHistory: recordHistory,
            );
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest != null) setSheetState(() => clip = latest);
          }

          Widget cropSlider({
            required String label,
            required double value,
            required double opposite,
            required ClipCropSettings Function(double value) mapper,
          }) {
            final max = math.max(0.0, 0.9 - opposite);
            return Column(
              children: [
                _sheetSliderHeader(label, '${(value * 100).round()}%'),
                Slider(
                  value: value.clamp(0, max),
                  min: 0,
                  max: math.max(0.01, max),
                  divisions: math.max(1, (max * 100).round()),
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (next) =>
                      update(mapper(next), recordHistory: false),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
              ],
            );
          }

          final crop = clip.crop;
          return _buildEditorSheet(
            title: 'Crop',
            subtitle: 'Non-destructive and reusable on any visual clip',
            resizable: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('ASPECT PRESETS'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.restart_alt_rounded, size: 16),
                      label: const Text('Original'),
                      onPressed: () => update(const ClipCropSettings()),
                    ),
                    for (final preset in const [
                      (1.0, '1:1'),
                      (16 / 9, '16:9'),
                      (9 / 16, '9:16'),
                      (4 / 5, '4:5'),
                    ])
                      ActionChip(
                        label: Text(preset.$2),
                        onPressed: () =>
                            update(_centerCropForAspect(clip, preset.$1)),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                _sheetSectionTitle('FREE CROP'),
                cropSlider(
                  label: 'Left',
                  value: crop.safeLeft,
                  opposite: crop.safeRight,
                  mapper: (value) => crop.copyWith(left: value),
                ),
                cropSlider(
                  label: 'Right',
                  value: crop.safeRight,
                  opposite: crop.safeLeft,
                  mapper: (value) => crop.copyWith(right: value),
                ),
                cropSlider(
                  label: 'Top',
                  value: crop.safeTop,
                  opposite: crop.safeBottom,
                  mapper: (value) => crop.copyWith(top: value),
                ),
                cropSlider(
                  label: 'Bottom',
                  value: crop.safeBottom,
                  opposite: crop.safeTop,
                  mapper: (value) => crop.copyWith(bottom: value),
                ),
                const SizedBox(height: 8),
                Text(
                  'Visible area: ${(crop.visibleWidth * 100).round()}% × '
                  '${(crop.visibleHeight * 100).round()}%',
                  style: const TextStyle(color: kTextSecondary, fontSize: 11),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openFilterSheet(TimelineClip? initialClip) async {
    final isExistingFilter =
        initialClip?.type == TimelineTrackType.effect &&
        initialClip?.effectKind == TimelineEffectKind.filter;
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(initialClip, editorState);
    if (initialClip != null &&
        (track == null ||
            track.isLocked ||
            (!isExistingFilter && !initialClip.supportsVisualEffects))) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _buildEditorSheet(
        title: isExistingFilter
            ? 'Change filter overlay'
            : 'Add filter overlay',
        subtitle: isExistingFilter
            ? 'Choose a preset for this timeline overlay'
            : 'The preset becomes a draggable, resizable timeline clip',
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: ClipFilterPreset.values
              .where((preset) => preset != ClipFilterPreset.original)
              .map((preset) {
                return ActionChip(
                  avatar: const Icon(Icons.tonality_rounded, size: 17),
                  label: Text(_filterPresetLabel(preset)),
                  onPressed: () {
                    if (isExistingFilter) {
                      _replaceFilterEffect(initialClip!, preset);
                    } else {
                      final adjustments = ClipColorAdjustments.forPreset(
                        preset,
                      );
                      _addEffectOverlay(
                        anchor: initialClip,
                        kind: TimelineEffectKind.filter,
                        label: '${_filterPresetLabel(preset)} filter',
                        colorAdjustments: adjustments,
                      );
                    }
                    Navigator.pop(context);
                  },
                );
              })
              .toList(),
        ),
      ),
    );
  }

  Future<void> _openColorAdjustmentsSheet(TimelineClip initialClip) async {
    final initialState = ref.read(editorProvider);
    final initialTrack = _trackForClip(initialClip, initialState);
    final isFilterEffect =
        initialClip.isEffect &&
        initialClip.effectKind == TimelineEffectKind.filter;
    if (initialTrack == null ||
        initialTrack.isLocked ||
        (!isFilterEffect && !initialClip.supportsVisualEffects)) {
      return;
    }
    var clip = _clipById(initialClip.id, initialState) ?? initialClip;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(
            ClipColorAdjustments Function(ClipColorAdjustments current)
            mapper, {
            bool recordHistory = true,
          }) {
            _updateTimelineClip(
              clip,
              (current) => current.copyWith(
                colorAdjustments: mapper(current.colorAdjustments),
              ),
              recordHistory: recordHistory,
            );
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest != null) setSheetState(() => clip = latest);
          }

          final adjustments = clip.colorAdjustments;
          final currentTimeline = ref.read(editorProvider).timeline;
          final sourcePath = currentTimeline.assetForClip(clip)?.sourcePath;
          final lutLibrary = [...currentTimeline.colorManagement.luts]
            ..sort((first, second) {
              final byFavorite = (second.favorite ? 1 : 0).compareTo(
                first.favorite ? 1 : 0,
              );
              if (byFavorite != 0) return byFavorite;
              final byFolder = first.folder.toLowerCase().compareTo(
                second.folder.toLowerCase(),
              );
              return byFolder != 0
                  ? byFolder
                  : first.name.toLowerCase().compareTo(
                      second.name.toLowerCase(),
                    );
            });
          final appliedLut = lutLibrary
              .where((lut) => lut.path == adjustments.lutPath)
              .firstOrNull;
          Widget adjustmentSlider({
            required String label,
            required double value,
            required double minimum,
            required double maximum,
            required ClipColorAdjustments Function(double value) mapper,
            String Function(double value)? formatter,
          }) {
            final format =
                formatter ?? (candidate) => '${(candidate * 100).round()}%';
            return Column(
              children: [
                _sheetSliderHeader(label, format(value)),
                Slider(
                  value: value.clamp(minimum, maximum).toDouble(),
                  min: minimum,
                  max: maximum,
                  divisions: 100,
                  label: format(value),
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (next) =>
                      update((_) => mapper(next), recordHistory: false),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
              ],
            );
          }

          return _buildEditorSheet(
            title: 'Color correction',
            subtitle:
                'Basic controls preview live; advanced corrections render an accurate cached proxy',
            resizable: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (sourcePath?.trim().isNotEmpty == true) ...[
                  _sheetSectionTitle('LIVE VIDEO SCOPES'),
                  const SizedBox(height: 8),
                  VideoScopesPanel(
                    key: ValueKey('scopes_${clip.id}'),
                    clip: clip,
                    sourcePath: sourcePath!.trim(),
                  ),
                  const SizedBox(height: 14),
                ],
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const ValueKey('project_color_management'),
                    onPressed: _openColorManagementSheet,
                    icon: const Icon(Icons.hdr_on_rounded),
                    label: const Text('Project color management & HDR output'),
                  ),
                ),
                const SizedBox(height: 14),
                _sheetSectionTitle('LIGHT'),
                adjustmentSlider(
                  label: 'Exposure',
                  value: adjustments.exposure,
                  minimum: -4,
                  maximum: 4,
                  formatter: (value) => '${value.toStringAsFixed(2)} EV',
                  mapper: (value) => adjustments.copyWith(exposure: value),
                ),
                adjustmentSlider(
                  label: 'Brightness',
                  value: adjustments.brightness,
                  minimum: -1,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(brightness: value),
                ),
                adjustmentSlider(
                  label: 'Contrast',
                  value: adjustments.contrast,
                  minimum: 0.1,
                  maximum: 3,
                  formatter: (value) => '${value.toStringAsFixed(2)}×',
                  mapper: (value) => adjustments.copyWith(contrast: value),
                ),
                const SizedBox(height: 8),
                _sheetSectionTitle('TONE'),
                adjustmentSlider(
                  label: 'Highlights',
                  value: adjustments.highlights,
                  minimum: -1,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(highlights: value),
                ),
                adjustmentSlider(
                  label: 'Shadows',
                  value: adjustments.shadows,
                  minimum: -1,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(shadows: value),
                ),
                adjustmentSlider(
                  label: 'Whites',
                  value: adjustments.whites,
                  minimum: -1,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(whites: value),
                ),
                adjustmentSlider(
                  label: 'Blacks',
                  value: adjustments.blacks,
                  minimum: -1,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(blacks: value),
                ),
                const SizedBox(height: 8),
                _sheetSectionTitle('COLOR'),
                adjustmentSlider(
                  label: 'Saturation',
                  value: adjustments.saturation,
                  minimum: 0,
                  maximum: 3,
                  formatter: (value) => '${value.toStringAsFixed(2)}×',
                  mapper: (value) => adjustments.copyWith(saturation: value),
                ),
                adjustmentSlider(
                  label: 'Vibrance',
                  value: adjustments.vibrance,
                  minimum: -1,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(vibrance: value),
                ),
                adjustmentSlider(
                  label: 'Temperature',
                  value: adjustments.temperature,
                  minimum: -1,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(temperature: value),
                ),
                adjustmentSlider(
                  label: 'Tint',
                  value: adjustments.tint,
                  minimum: -1,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(tint: value),
                ),
                adjustmentSlider(
                  label: 'Hue',
                  value: adjustments.hue,
                  minimum: -180,
                  maximum: 180,
                  formatter: (value) => '${value.round()}°',
                  mapper: (value) => adjustments.copyWith(hue: value),
                ),
                adjustmentSlider(
                  label: 'Gamma',
                  value: adjustments.gamma,
                  minimum: 0.1,
                  maximum: 4,
                  formatter: (value) => value.toStringAsFixed(2),
                  mapper: (value) => adjustments.copyWith(gamma: value),
                ),
                const SizedBox(height: 8),
                _sheetSectionTitle('RGB CHANNELS'),
                adjustmentSlider(
                  label: 'Red gain',
                  value: adjustments.redGain,
                  minimum: 0,
                  maximum: 3,
                  formatter: (value) => '${value.toStringAsFixed(2)}×',
                  mapper: (value) => adjustments.copyWith(redGain: value),
                ),
                adjustmentSlider(
                  label: 'Green gain',
                  value: adjustments.greenGain,
                  minimum: 0,
                  maximum: 3,
                  formatter: (value) => '${value.toStringAsFixed(2)}×',
                  mapper: (value) => adjustments.copyWith(greenGain: value),
                ),
                adjustmentSlider(
                  label: 'Blue gain',
                  value: adjustments.blueGain,
                  minimum: 0,
                  maximum: 3,
                  formatter: (value) => '${value.toStringAsFixed(2)}×',
                  mapper: (value) => adjustments.copyWith(blueGain: value),
                ),
                const SizedBox(height: 12),
                AdvancedColorControls(
                  adjustments: adjustments,
                  onChanged: (value, {required recordHistory}) =>
                      update((_) => value, recordHistory: recordHistory),
                  onGestureStart: () => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onGestureEnd: () => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                  onPickNeutralReference: () async {
                    if (sourcePath?.trim().isNotEmpty != true) {
                      SnackBarHelper.showWarning(
                        context,
                        'The source media is unavailable.',
                      );
                      return;
                    }
                    try {
                      final playback = ref.read(playbackProvider).position;
                      final sampled = await pickNeutralReferenceColor(
                        context: context,
                        sourcePath: sourcePath!.trim(),
                        sourcePosition: _sourcePositionForTimelineClip(
                          clip,
                          playback,
                        ),
                      );
                      if (sampled == null || !context.mounted) return;
                      final red = sampled.r;
                      final green = sampled.g;
                      final blue = sampled.b;
                      final temperatureCorrection = ((blue - red) * 1.65)
                          .clamp(-1.0, 1.0)
                          .toDouble();
                      final tintCorrection = ((green - (red + blue) / 2) * 1.65)
                          .clamp(-1.0, 1.0)
                          .toDouble();
                      update(
                        (current) => current.copyWith(
                          temperature:
                              (current.temperature + temperatureCorrection)
                                  .clamp(-1.0, 1.0)
                                  .toDouble(),
                          tint: (current.tint + tintCorrection)
                              .clamp(-1.0, 1.0)
                              .toDouble(),
                        ),
                      );
                    } catch (error) {
                      if (context.mounted) {
                        SnackBarHelper.showError(
                          context,
                          error.toString().replaceFirst('Exception: ', ''),
                        );
                      }
                    }
                  },
                  onPickQualifierReference:
                      sourcePath?.trim().isNotEmpty != true
                      ? null
                      : () async {
                          try {
                            final playback = ref
                                .read(playbackProvider)
                                .position;
                            final sampled = await pickFrameReferenceColor(
                              context: context,
                              sourcePath: sourcePath!.trim(),
                              sourcePosition: _sourcePositionForTimelineClip(
                                clip,
                                playback,
                              ),
                              title: 'Qualifier eyedropper',
                              instruction:
                                  'Tap the color you want to isolate and correct.',
                              actionLabel: 'Use sampled color',
                            );
                            if (sampled == null || !context.mounted) return;
                            update(
                              (current) => current.copyWith(
                                qualifier: current.qualifier.copyWith(
                                  enabled: true,
                                  skinTone: false,
                                  color: sampled.toARGB32(),
                                ),
                              ),
                            );
                          } catch (error) {
                            if (context.mounted) {
                              SnackBarHelper.showError(
                                context,
                                error.toString().replaceFirst(
                                  'Exception: ',
                                  '',
                                ),
                              );
                            }
                          }
                        },
                  onTrackQualifierMask:
                      adjustments.qualifier.spatialMask == null ||
                          sourcePath?.trim().isNotEmpty != true
                      ? null
                      : () async {
                          final tracked = await _trackColorQualifierMask(
                            clip,
                            adjustments.qualifier.spatialMask!,
                          );
                          if (tracked != null && context.mounted) {
                            update(
                              (current) => current.copyWith(
                                qualifier: current.qualifier.copyWith(
                                  spatialMask: tracked,
                                ),
                              ),
                            );
                          }
                        },
                ),
                const SizedBox(height: 8),
                _sheetSectionTitle('LUT'),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: ValueKey('clip_lut_${appliedLut?.id ?? 'none'}'),
                  initialValue: appliedLut?.id ?? '__none__',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Project LUT library',
                    prefixIcon: Icon(Icons.color_lens_outlined),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '__none__',
                      child: Text('No LUT'),
                    ),
                    for (final lut in lutLibrary)
                      DropdownMenuItem(
                        value: lut.id,
                        child: Text(
                          '${lut.favorite ? '★ ' : ''}${lut.folder} / ${lut.name}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    ref
                        .read(editorProvider.notifier)
                        .applyLutToClip(
                          clip.id,
                          value == '__none__' ? null : value,
                        );
                    final latest = _clipById(clip.id, ref.read(editorProvider));
                    if (latest != null) setSheetState(() => clip = latest);
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final result = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: const ['cube', '3dl'],
                          allowMultiple: false,
                        );
                        final selectedPath = result?.files.single.path;
                        if (selectedPath == null || !mounted) return;
                        try {
                          await validateLutFile(selectedPath);
                          final durablePath =
                              await MediaImportService.persistFile(
                                selectedPath,
                                originalFileName: path.basename(selectedPath),
                                forceCopy: true,
                              );
                          ref
                              .read(editorProvider.notifier)
                              .importAndApplyLutToClip(
                                clipId: clip.id,
                                sourcePath: durablePath,
                                name: path.basenameWithoutExtension(
                                  selectedPath,
                                ),
                              );
                        } catch (error) {
                          if (context.mounted) {
                            SnackBarHelper.showError(
                              context,
                              'Could not import LUT: $error',
                            );
                          }
                          return;
                        }
                        final latest = _clipById(
                          clip.id,
                          ref.read(editorProvider),
                        );
                        if (latest != null && context.mounted) {
                          setSheetState(() => clip = latest);
                        }
                      },
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Import LUT'),
                    ),
                    if (appliedLut != null)
                      OutlinedButton.icon(
                        onPressed: () {
                          ref
                              .read(editorProvider.notifier)
                              .updateLutAsset(
                                appliedLut.id,
                                (lut) => lut.copyWith(favorite: !lut.favorite),
                              );
                          setSheetState(() {});
                        },
                        icon: Icon(
                          appliedLut.favorite
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                        ),
                        label: Text(
                          appliedLut.favorite ? 'Favorited' : 'Favorite',
                        ),
                      ),
                    if (appliedLut != null)
                      OutlinedButton.icon(
                        key: const ValueKey('organize_applied_lut'),
                        onPressed: () async {
                          final organization = await _editLutOrganization(
                            appliedLut,
                          );
                          if (organization == null || !context.mounted) return;
                          ref
                              .read(editorProvider.notifier)
                              .updateLutAsset(
                                appliedLut.id,
                                (lut) => lut.copyWith(
                                  name: organization.name,
                                  folder: organization.folder,
                                  favorite: organization.favorite,
                                ),
                              );
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.folder_outlined),
                        label: const Text('Organize'),
                      ),
                  ],
                ),
                if (adjustments.lutPath?.trim().isNotEmpty == true)
                  adjustmentSlider(
                    label: 'LUT intensity',
                    value: adjustments.lutIntensity,
                    minimum: 0,
                    maximum: 1,
                    mapper: (value) =>
                        adjustments.copyWith(lutIntensity: value),
                  ),
                const SizedBox(height: 8),
                _sheetSectionTitle('FINISH'),
                adjustmentSlider(
                  label: 'Fade',
                  value: adjustments.fade,
                  minimum: 0,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(fade: value),
                ),
                adjustmentSlider(
                  label: 'Vignette',
                  value: adjustments.vignette,
                  minimum: 0,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(vignette: value),
                ),
                adjustmentSlider(
                  label: 'Sharpen',
                  value: adjustments.sharpen,
                  minimum: 0,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(sharpen: value),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => update((_) => const ClipColorAdjustments()),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Reset color correction'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<EditorEffectMask?> _trackColorQualifierMask(
    TimelineClip clip,
    EditorEffectMask mask,
  ) async {
    final timeline = ref.read(editorProvider).timeline;
    final liveClip = _clipById(clip.id, ref.read(editorProvider)) ?? clip;
    final sourcePath = timeline.assetForClip(liveClip)?.sourcePath?.trim();
    if (sourcePath == null ||
        sourcePath.isEmpty ||
        !await File(sourcePath).exists()) {
      if (mounted) {
        SnackBarHelper.showWarning(
          context,
          'The source video is unavailable for tracking.',
        );
      }
      return null;
    }
    final playhead = ref.read(playbackProvider).position;
    final relativeUs = (playhead - liveClip.startTime).inMicroseconds
        .clamp(0, liveClip.duration.inMicroseconds)
        .toInt();
    final remainingUs = liveClip.duration.inMicroseconds - relativeUs;
    if (remainingUs < const Duration(milliseconds: 200).inMicroseconds) {
      if (mounted) {
        SnackBarHelper.showInfo(
          context,
          'Move the playhead earlier to track forward.',
        );
      }
      return null;
    }
    final rate = liveClip.playbackRate.clamp(0.25, 4).toDouble();
    final declaredSpanUs = liveClip.sourceDuration.inMicroseconds > 0
        ? liveClip.sourceDuration.inMicroseconds
        : (liveClip.duration.inMicroseconds * rate).round();
    final remainingSourceUs = math.min(
      (remainingUs * rate).round(),
      declaredSpanUs,
    );
    final sourceStartOffsetUs = liveClip.isReversed
        ? math.max(
            0,
            declaredSpanUs - (relativeUs * rate).round() - remainingSourceUs,
          )
        : math.min(declaredSpanUs, (relativeUs * rate).round());
    if (mounted) {
      SnackBarHelper.showInfo(context, 'Tracking qualifier mask…');
    }
    try {
      final result = await MaskTrackingService.trackForward(
        sourcePath: sourcePath,
        sourceStartTime:
            liveClip.sourceStartTime +
            Duration(microseconds: sourceStartOffsetUs),
        sourceDuration: Duration(microseconds: remainingSourceUs),
        timelineOffset: Duration(microseconds: relativeUs),
        timelineDuration: Duration(microseconds: remainingUs),
        playbackRate: rate,
        reversed: liveClip.isReversed,
        initialMask: mask,
      );
      if (mounted) {
        SnackBarHelper.showSuccess(
          context,
          'Tracked ${result.keyframes.length} samples '
          '(${(result.averageConfidence * 100).round()}% confidence).',
        );
      }
      return mask.copyWith(
        trackingEnabled: true,
        trackingTargetId: liveClip.id,
        trackingKeyframes: [
          ...mask.trackingKeyframes.where(
            (frame) => frame.time.inMicroseconds < relativeUs,
          ),
          ...result.keyframes,
        ],
      );
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(
          context,
          error.toString().replaceFirst('Exception: ', ''),
        );
      }
      return null;
    }
  }

  Future<void> _openColorManagementSheet() async {
    var settings = ref.read(editorProvider).timeline.colorManagement;
    const outputSpaces = <EditorColorSpace>[
      EditorColorSpace.sdr709,
      EditorColorSpace.hlg,
      EditorColorSpace.pq,
      EditorColorSpace.wideGamut,
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(
            EditorColorManagementSettings next, {
            bool recordHistory = true,
          }) {
            setSheetState(() => settings = next);
            final notifier = ref.read(editorProvider.notifier);
            notifier.setTimeline(
              ref.read(editorProvider).timeline.copyWith(colorManagement: next),
              recordHistory: recordHistory,
            );
          }

          Widget slider({
            required String label,
            required double value,
            required double minimum,
            required double maximum,
            required ValueChanged<double> onChanged,
          }) {
            return Column(
              children: [
                _sheetSliderHeader(label, '${value.round()} nits'),
                Slider(
                  value: value.clamp(minimum, maximum).toDouble(),
                  min: minimum,
                  max: maximum,
                  divisions: 100,
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: onChanged,
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
              ],
            );
          }

          return _buildEditorSheet(
            title: 'Color management',
            subtitle:
                'Camera transforms, working gamut, tone mapping and HDR delivery',
            resizable: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('PROJECT PIPELINE'),
                const SizedBox(height: 8),
                DropdownButtonFormField<EditorColorSpace>(
                  key: ValueKey('working_${settings.workingSpace.name}'),
                  initialValue: settings.workingSpace,
                  decoration: const InputDecoration(
                    labelText: 'Working color space',
                    prefixIcon: Icon(Icons.workspaces_outline),
                  ),
                  items: [
                    for (final space in outputSpaces)
                      DropdownMenuItem(
                        value: space,
                        child: Text(_editorColorSpaceLabel(space)),
                      ),
                  ],
                  onChanged: (space) {
                    if (space != null) {
                      update(settings.copyWith(workingSpace: space));
                    }
                  },
                ),
                const SizedBox(height: 10),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Automatic camera Log transform'),
                  subtitle: const Text(
                    'Interpret detected Log footage before grading',
                  ),
                  value: settings.automaticLogTransform,
                  onChanged: (value) =>
                      update(settings.copyWith(automaticLogTransform: value)),
                ),
                const SizedBox(height: 12),
                _sheetSectionTitle('DELIVERY'),
                const SizedBox(height: 8),
                DropdownButtonFormField<EditorColorSpace>(
                  key: ValueKey('output_${settings.outputSpace.name}'),
                  initialValue: settings.outputSpace,
                  decoration: const InputDecoration(
                    labelText: 'Output color space',
                    prefixIcon: Icon(Icons.tv_rounded),
                  ),
                  items: [
                    for (final space in outputSpaces)
                      DropdownMenuItem(
                        value: space,
                        child: Text(_editorColorSpaceLabel(space)),
                      ),
                  ],
                  onChanged: (space) {
                    if (space == null) return;
                    update(
                      settings.copyWith(
                        outputSpace: space,
                        preserveHdr: space == EditorColorSpace.sdr709
                            ? false
                            : settings.preserveHdr,
                      ),
                    );
                  },
                ),
                SwitchListTile.adaptive(
                  key: const ValueKey('preserve_hdr_export'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Preserve HDR on export'),
                  subtitle: Text(
                    settings.outputSpace == EditorColorSpace.sdr709
                        ? 'Choose HLG, PQ, or wide gamut output first'
                        : 'Encode 10-bit HEVC with matching color metadata',
                  ),
                  value: settings.preserveHdr,
                  onChanged: settings.outputSpace == EditorColorSpace.sdr709
                      ? null
                      : (value) =>
                            update(settings.copyWith(preserveHdr: value)),
                ),
                slider(
                  label: 'Reference white',
                  value: settings.referenceWhiteNits,
                  minimum: 80,
                  maximum: 500,
                  onChanged: (value) => update(
                    settings.copyWith(referenceWhiteNits: value),
                    recordHistory: false,
                  ),
                ),
                slider(
                  label: 'Mastering peak',
                  value: settings.peakLuminanceNits,
                  minimum: 100,
                  maximum: 4000,
                  onChanged: (value) => update(
                    settings.copyWith(peakLuminanceNits: value),
                    recordHistory: false,
                  ),
                ),
                DropdownButtonFormField<EditorToneMapMode>(
                  key: ValueKey('tone_map_${settings.toneMapMode.name}'),
                  initialValue: settings.toneMapMode,
                  decoration: const InputDecoration(
                    labelText: 'HDR-to-SDR tone map',
                    prefixIcon: Icon(Icons.tonality_rounded),
                  ),
                  items: [
                    for (final mode in EditorToneMapMode.values)
                      DropdownMenuItem(
                        value: mode,
                        child: Text(switch (mode) {
                          EditorToneMapMode.hable => 'Hable (filmic)',
                          EditorToneMapMode.reinhard => 'Reinhard',
                          EditorToneMapMode.mobius => 'Mobius',
                        }),
                      ),
                  ],
                  onChanged: (mode) {
                    if (mode != null) {
                      update(settings.copyWith(toneMapMode: mode));
                    }
                  },
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: kSurfaceElevated,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kBorder),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        settings.preserveHdr
                            ? Icons.hdr_on_rounded
                            : Icons.hdr_off_rounded,
                        color: settings.preserveHdr ? kAccent : kTextSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          settings.preserveHdr
                              ? 'HDR delivery uses HEVC Main 10, yuv420p10le, and explicit Rec.2020 transfer/primaries metadata.'
                              : 'Preview and export tone-map into SDR Rec.709 when HDR preservation is off.',
                          style: const TextStyle(
                            color: kTextSecondary,
                            fontSize: 10,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openCanvasSettingsSheet() async {
    var canvas = ref.read(editorProvider).timeline.canvasSettings;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(CanvasSettings next, {bool recordHistory = true}) {
            setSheetState(() => canvas = next);
            _updateCanvasSettings((_) => next, recordHistory: recordHistory);
          }

          const backgroundColors = [
            Colors.black,
            Color(0xFF111512),
            Color(0xFF202420),
            Color(0xFFF3F0E7),
            Color(0xFF17324D),
            Color(0xFF4A2318),
          ];
          return _buildEditorSheet(
            title: 'Canvas',
            subtitle: 'Format, background and guides',
            resizable: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('FORMAT'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: CanvasAspectRatioPreset.values.map((preset) {
                    final label = switch (preset) {
                      CanvasAspectRatioPreset.original => 'Original',
                      CanvasAspectRatioPreset.ratio16x9 => '16:9',
                      CanvasAspectRatioPreset.ratio9x16 => '9:16',
                      CanvasAspectRatioPreset.ratio1x1 => '1:1',
                      CanvasAspectRatioPreset.ratio4x5 => '4:5',
                    };
                    return ChoiceChip(
                      label: Text(label),
                      selected: canvas.aspectRatioPreset == preset,
                      onSelected: (_) {
                        update(canvas.copyWith(aspectRatioPreset: preset));
                        setState(() {
                          _canvasAspectRatio = _canvasAspectRatioFromPreset(
                            preset,
                          );
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                _sheetSectionTitle('BACKGROUND'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  children: backgroundColors.map((color) {
                    final selected = canvas.backgroundColor == color;
                    return InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () =>
                          update(canvas.copyWith(backgroundColor: color)),
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? kAccent : kBorder,
                            width: selected ? 3 : 1,
                          ),
                        ),
                        child: selected
                            ? Icon(
                                Icons.check_rounded,
                                color: color.computeLuminance() > 0.5
                                    ? Colors.black
                                    : Colors.white,
                                size: 18,
                              )
                            : null,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Title and action safe areas'),
                  subtitle: const Text('Preview guides are never exported'),
                  value: canvas.showSafeAreas,
                  onChanged: (value) =>
                      update(canvas.copyWith(showSafeAreas: value)),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Composition grid'),
                  subtitle: Text(
                    '${canvas.gridDivisions} × ${canvas.gridDivisions}',
                  ),
                  value: canvas.showGrid,
                  onChanged: (value) =>
                      update(canvas.copyWith(showGrid: value)),
                ),
                if (canvas.showGrid)
                  Slider(
                    value: canvas.gridDivisions.toDouble(),
                    min: 2,
                    max: 6,
                    divisions: 4,
                    label: '${canvas.gridDivisions}',
                    onChanged: (value) =>
                        update(canvas.copyWith(gridDivisions: value.round())),
                  ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Snap objects to guides'),
                  value: canvas.snapToGuides,
                  onChanged: (value) =>
                      update(canvas.copyWith(snapToGuides: value)),
                ),
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed:
                      !canvas.showGrid &&
                          !canvas.showSafeAreas &&
                          !canvas.snapToGuides
                      ? null
                      : () => update(
                          canvas.copyWith(
                            showGrid: false,
                            showSafeAreas: false,
                            snapToGuides: false,
                          ),
                        ),
                  icon: const Icon(Icons.layers_clear_rounded),
                  label: const Text('Clear all guides'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openCreatorLab() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatorLabScreen(projectName: _projectSnapshot.name),
      ),
    );
  }

  Future<void> _openSubtitleToolsSheet() async {
    final hasLockedSubtitleLane = ref
        .read(editorProvider)
        .timeline
        .tracks
        .any(
          (track) => track.type == TimelineTrackType.subtitle && track.isLocked,
        );
    if (hasLockedSubtitleLane) {
      SnackBarHelper.showInfo(
        context,
        'Unlock the subtitle track before editing captions.',
      );
      return;
    }
    Map<String, String> captionLaneMap() => {
      for (final track in ref.read(editorProvider).timeline.tracks)
        if (track.type == TimelineTrackType.subtitle)
          for (final clip in track.clips) clip.id: track.id,
    };
    var report = SubtitleQualityService.analyze(
      ref.read(subtitleProvider).entries,
      laneByEntryId: captionLaneMap(),
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void refreshReport() {
            setSheetState(() {
              report = SubtitleQualityService.analyze(
                ref.read(subtitleProvider).entries,
                laneByEntryId: captionLaneMap(),
              );
            });
          }

          return _buildEditorSheet(
            title: 'Caption workshop',
            subtitle:
                '${report.cueCount} cues • '
                '${report.averageCharactersPerSecond.toStringAsFixed(1)} avg CPS',
            resizable: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: report.isClean
                        ? kSuccess.withValues(alpha: 0.08)
                        : kWarning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: report.isClean
                          ? kSuccess.withValues(alpha: 0.28)
                          : kWarning.withValues(alpha: 0.28),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        report.isClean
                            ? Icons.verified_rounded
                            : Icons.rule_rounded,
                        color: report.isClean ? kSuccess : kWarning,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          report.isClean
                              ? 'Captions pass readability checks'
                              : '${report.issues.length} readability issues found',
                          style: TextStyle(
                            color: kTextPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!report.isClean) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: SubtitleIssueType.values
                        .where((type) => report.countFor(type) > 0)
                        .map(
                          (type) => Chip(
                            label: Text(
                              '${_subtitleIssueLabel(type)} '
                              '${report.countFor(type)}',
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 14),
                _sheetSectionTitle('EDIT'),
                const SizedBox(height: 8),
                _sheetListAction(
                  icon: Icons.search_rounded,
                  title: 'Find and replace',
                  subtitle: 'Change repeated words across every cue',
                  onTap: () async {
                    await _showSubtitleFindReplaceDialog();
                    refreshReport();
                  },
                ),
                _sheetListAction(
                  icon: Icons.more_time_rounded,
                  title: 'Shift all timings',
                  subtitle: 'Move the complete subtitle track earlier or later',
                  onTap: () async {
                    await _showSubtitleShiftDialog();
                    refreshReport();
                  },
                ),
                _sheetListAction(
                  icon: Icons.auto_fix_high_rounded,
                  title: 'Normalize spacing',
                  subtitle: 'Clean repeated spaces and ragged line breaks',
                  onTap: () {
                    ref.read(subtitleProvider.notifier).normalizeText();
                    refreshReport();
                  },
                ),
                _sheetListAction(
                  icon: Icons.format_line_spacing_rounded,
                  title: 'Resolve overlaps',
                  subtitle: 'Insert an 80ms gap where cues collide',
                  onTap: () {
                    ref
                        .read(subtitleProvider.notifier)
                        .fixOverlaps(laneByEntryId: captionLaneMap());
                    refreshReport();
                  },
                ),
                const SizedBox(height: 14),
                _sheetSectionTitle('CASE'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: SubtitleTextCase.values.map((textCase) {
                    return ActionChip(
                      label: Text(switch (textCase) {
                        SubtitleTextCase.sentence => 'Sentence',
                        SubtitleTextCase.upper => 'UPPER',
                        SubtitleTextCase.lower => 'lower',
                        SubtitleTextCase.title => 'Title Case',
                      }),
                      onPressed: () {
                        ref
                            .read(subtitleProvider.notifier)
                            .convertCase(textCase);
                        refreshReport();
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    final playhead = ref.read(playbackProvider).position;
                    final duration = ref.read(editorProvider).timeline.duration;
                    final end = playhead + const Duration(seconds: 2);
                    ref
                        .read(subtitleProvider.notifier)
                        .addEntry(playhead, end > duration ? duration : end);
                    refreshReport();
                  },
                  icon: const Icon(Icons.add_comment_rounded),
                  label: const Text('Add cue at playhead'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showSubtitleFindReplaceDialog() async {
    final findController = TextEditingController();
    final replaceController = TextEditingController();
    var matchCase = false;
    final shouldReplace = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Find and replace'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: findController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Find'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: replaceController,
                decoration: const InputDecoration(labelText: 'Replace with'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Match case'),
                value: matchCase,
                onChanged: (value) =>
                    setDialogState(() => matchCase = value ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Replace all'),
            ),
          ],
        ),
      ),
    );
    if (shouldReplace == true) {
      final count = ref
          .read(subtitleProvider.notifier)
          .replaceText(
            query: findController.text,
            replacement: replaceController.text,
            matchCase: matchCase,
          );
      if (mounted) {
        SnackBarHelper.showInfo(context, '$count replacements made');
      }
    }
    findController.dispose();
    replaceController.dispose();
  }

  Future<void> _showSubtitleShiftDialog() async {
    final controller = TextEditingController(text: '0');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Shift subtitle timings'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          decoration: const InputDecoration(
            labelText: 'Milliseconds',
            helperText: 'Negative moves cues earlier',
            prefixText: '± ',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    final milliseconds = int.tryParse(result?.trim() ?? '');
    if (milliseconds == null || milliseconds == 0) return;
    ref
        .read(subtitleProvider.notifier)
        .shiftAll(
          Duration(milliseconds: milliseconds),
          projectDuration: ref.read(editorProvider).timeline.duration,
        );
  }

  Future<void> _relinkClipMedia(TimelineClip clip) async {
    try {
      final fileType = switch (clip.type) {
        TimelineTrackType.audio => FileType.audio,
        TimelineTrackType.video => FileType.video,
        _ => FileType.image,
      };
      final result = await FilePicker.platform.pickFiles(
        type: fileType,
        allowMultiple: false,
      );
      final file = result?.files.firstOrNull;
      final selectedPath = file?.path;
      if (selectedPath == null) return;
      final sourcePath = await MediaImportService.persistFile(
        selectedPath,
        originalFileName: file!.name,
      );
      final shouldProbe =
          clip.type == TimelineTrackType.video ||
          clip.type == TimelineTrackType.audio ||
          clip.type == TimelineTrackType.gif;
      final mediaInfo = shouldProbe
          ? await FFmpegService.getMediaInfo(sourcePath)
          : <String, dynamic>{};
      if (!mounted) return;
      final editorState = ref.read(editorProvider);
      final timeline = editorState.timeline;
      final oldAsset = timeline.assetForClip(clip);
      final assetType = switch (clip.type) {
        TimelineTrackType.video => EditorAssetType.video,
        TimelineTrackType.audio => EditorAssetType.audio,
        TimelineTrackType.gif => EditorAssetType.gif,
        TimelineTrackType.sticker => EditorAssetType.sticker,
        _ => EditorAssetType.image,
      };
      final replacementAsset = EditorAssetReference(
        type: assetType,
        label: file.name,
        sourcePath: sourcePath,
        metadata: TimelineProxyMediaService.metadataAfterSourceRelink(
          previousMetadata: oldAsset?.metadata ?? const {},
          mediaInfo: mediaInfo,
        ),
      );
      final probedDurationMs = (mediaInfo['durationMs'] as num?)?.toInt();
      final replacementSourceDuration =
          probedDurationMs != null && probedDurationMs > 0
          ? Duration(milliseconds: probedDurationMs)
          : clip.sourceDuration;
      final maximumTimelineDuration = Duration(
        milliseconds: math.max(
          100,
          (replacementSourceDuration.inMilliseconds /
                  clip.playbackRate.clamp(0.25, 4))
              .round(),
        ),
      );
      final replacementEnd = clip.type.supportsSourceTiming
          ? clip.startTime +
                (maximumTimelineDuration < clip.duration
                    ? maximumTimelineDuration
                    : clip.duration)
          : clip.endTime;
      final replacementHasAudio = mediaInfo['hasAudio'] == true;
      final nextTracks = timeline.tracks.map((track) {
        final clips = <TimelineClip>[];
        for (final candidate in track.clips) {
          if (candidate.id == clip.id) {
            clips.add(
              candidate.copyWith(
                label: file.name,
                assetId: replacementAsset.id,
                sourceStartTime: Duration.zero,
                sourceDuration: replacementSourceDuration,
                endTime: replacementEnd,
              ),
            );
            continue;
          }
          if (candidate.linkedClipId == clip.id) {
            if (candidate.type == TimelineTrackType.audio) {
              if (clip.type == TimelineTrackType.video &&
                  !replacementHasAudio) {
                continue;
              }
              clips.add(
                candidate.copyWith(
                  assetId: replacementAsset.id,
                  startTime: clip.startTime,
                  endTime: replacementEnd,
                  sourceStartTime: Duration.zero,
                  sourceDuration: replacementSourceDuration,
                ),
              );
              continue;
            }

            // Captions and other linked annotations keep their own media/text
            // identity. Only trim or drop the portion that no longer fits
            // when a shorter replacement shortens the parent clip.
            if (candidate.startTime >= replacementEnd) continue;
            clips.add(
              candidate.endTime > replacementEnd
                  ? candidate.copyWith(endTime: replacementEnd)
                  : candidate,
            );
            continue;
          }
          clips.add(candidate);
        }
        return track.copyWith(clips: clips);
      }).toList();
      final referencedAssetIds = nextTracks
          .expand((track) => track.clips)
          .map((candidate) => candidate.assetId)
          .whereType<String>()
          .toSet();
      final assets = [
        for (final asset in timeline.assets)
          if (asset.id != oldAsset?.id || referencedAssetIds.contains(asset.id))
            asset,
        replacementAsset,
      ];
      final nextTimeline = timeline.copyWith(
        assets: assets,
        tracks: nextTracks,
      );
      ref.read(editorProvider.notifier).setTimeline(nextTimeline);
      ref
          .read(subtitleProvider.notifier)
          .syncFromTimeline(nextTimeline.subtitleEntries);
      SnackBarHelper.showSuccess(context, 'Clip media replaced');
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(
          context,
          'Could not relink media: ${error.toString().replaceFirst('Exception: ', '')}',
        );
      }
    }
  }

  Widget _buildEditorSheet({
    required String title,
    required String subtitle,
    required Widget child,
    bool resizable = false,
  }) {
    if (resizable) {
      return ResizableEditorSheet(
        title: title,
        subtitle: subtitle,
        onClose: () => Navigator.pop(context),
        child: child,
      );
    }
    return FixedEditorSheet(
      title: title,
      subtitle: subtitle,
      heightFactor: 0.52,
      onClose: () => Navigator.pop(context),
      child: child,
    );
  }

  Widget _sheetSectionTitle(String label) {
    return Text(
      label,
      style: TextStyle(
        color: kTextSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.1,
      ),
    );
  }

  Widget _sheetSliderHeader(String label, String value) {
    return Row(
      children: [
        Text(label, style: TextStyle(color: kTextPrimary, fontSize: 13)),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'monospace',
            color: kTextSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _audioMeterValue(String label, String value) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 92),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(color: kTextSecondary, fontSize: 9),
          ),
          Text(
            value,
            style: const TextStyle(
              color: kTextPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _sheetActionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: active ? kAccent.withValues(alpha: 0.12) : kSurfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? kAccent : kBorder),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: active ? kAccent : kTextSecondary, size: 17),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? kAccent : kTextPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetListAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: kSurfaceElevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kBorder),
        ),
        child: Icon(icon, color: kTextSecondary, size: 19),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }

  String _filterPresetLabel(ClipFilterPreset preset) {
    return switch (preset) {
      ClipFilterPreset.original => 'Original',
      ClipFilterPreset.cinematic => 'Cinema',
      ClipFilterPreset.warm => 'Warm',
      ClipFilterPreset.cool => 'Cool',
      ClipFilterPreset.vivid => 'Vivid',
      ClipFilterPreset.muted => 'Muted',
      ClipFilterPreset.monochrome => 'Mono',
      ClipFilterPreset.vintage => 'Vintage',
    };
  }

  String _subtitleIssueLabel(SubtitleIssueType type) {
    return switch (type) {
      SubtitleIssueType.overlap => 'Overlap',
      SubtitleIssueType.tooFast => 'Too fast',
      SubtitleIssueType.tooLong => 'Too long',
      SubtitleIssueType.tooShort => 'Too short',
      SubtitleIssueType.tooManyLines => 'Too many lines',
      SubtitleIssueType.longLine => 'Long line',
      SubtitleIssueType.lowConfidence => 'Review',
      SubtitleIssueType.empty => 'Empty',
    };
  }

  Widget _buildPortrait(BuildContext context, TimelineClip? selectedClip) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final actionBarHeight = _editorDockHeightFor(context);
        final workspaceHeight = math.max(
          0.0,
          constraints.maxHeight - actionBarHeight,
        );
        final minimumTimelineHeight = math.min(230.0, workspaceHeight * 0.55);
        final availablePreviewHeight = math.max(
          0.0,
          workspaceHeight - minimumTimelineHeight,
        );
        final minimumPreviewHeight = math.min(190.0, availablePreviewHeight);
        final maximumPreviewHeight = math.min(420.0, availablePreviewHeight);
        final previewHeight = (workspaceHeight * 0.43)
            .clamp(minimumPreviewHeight, maximumPreviewHeight)
            .toDouble();

        return Column(
          children: [
            SizedBox(height: previewHeight, child: _buildVideoPreview()),
            Expanded(child: _buildTimelinePanel()),
            _buildBottomQuickActions(context, selectedClip),
          ],
        );
      },
    );
  }

  Widget _buildLandscape(BuildContext context, TimelineClip? selectedClip) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final actionBarHeight = _editorDockHeightFor(context);
        final workspaceHeight = math.max(
          0.0,
          constraints.maxHeight - actionBarHeight,
        );
        final useSideBySideWorkspace = constraints.maxHeight < 560;

        final workspace = useSideBySideWorkspace
            ? Row(
                children: [
                  Expanded(flex: 5, child: _buildVideoPreview()),
                  const VerticalDivider(width: 1, thickness: 1, color: kBorder),
                  Expanded(flex: 6, child: _buildTimelinePanel()),
                ],
              )
            : _buildTallLandscapeWorkspace(workspaceHeight);

        return Column(
          children: [
            Expanded(child: workspace),
            _buildBottomQuickActions(context, selectedClip),
          ],
        );
      },
    );
  }

  Widget _buildTallLandscapeWorkspace(double workspaceHeight) {
    final minimumTimelineHeight = math.min(300.0, workspaceHeight * 0.48);
    final availablePreviewHeight = math.max(
      0.0,
      workspaceHeight - minimumTimelineHeight,
    );
    final minimumPreviewHeight = math.min(230.0, availablePreviewHeight);
    final maximumPreviewHeight = math.min(420.0, availablePreviewHeight);
    final previewHeight = (workspaceHeight * 0.48)
        .clamp(minimumPreviewHeight, maximumPreviewHeight)
        .toDouble();

    return Column(
      children: [
        SizedBox(height: previewHeight, child: _buildVideoPreview()),
        Expanded(child: _buildTimelinePanel()),
      ],
    );
  }

  Widget _buildVideoPreview() {
    return VideoPreviewPanel(
      key: _previewKey,
      videoPath: widget.project.videoPath,
      targetAspectRatio: _selectedAspectRatioValue,
      onFullscreenToggle: () => _setPreviewFullscreen(true),
    );
  }

  Widget _buildTimelinePanel() {
    return TimelinePanel(
      onEditRequested: _openSubtitleTextEditor,
      onTextClipEditRequested: _editTextClip,
      onTransitionRequested: _openTransitionSheet,
      onOverlayAddRequested: _openOverlayAddSheet,
      onTextAddRequested: _openTextAddSheet,
      onAudioAddRequested: _openAudioAddSheet,
      onMainVideoAddRequested: _pickBaseMedia,
      onReplaceMediaRequested: _relinkClipMedia,
    );
  }

  Widget _buildFullscreenPreview() {
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: VideoPreviewPanel(
          key: _previewKey,
          videoPath: widget.project.videoPath,
          targetAspectRatio: _selectedAspectRatioValue,
          isFullscreen: true,
          onFullscreenToggle: () => _setPreviewFullscreen(false),
        ),
      ),
    );
  }

  void _setPreviewFullscreen(bool fullscreen) {
    if (_isPreviewFullscreen == fullscreen || !mounted) return;
    setState(() => _isPreviewFullscreen = fullscreen);
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
    );
  }

  _CanvasAspectRatio _canvasAspectRatioFromPreset(
    CanvasAspectRatioPreset preset,
  ) {
    return switch (preset) {
      CanvasAspectRatioPreset.original => _CanvasAspectRatio.original,
      CanvasAspectRatioPreset.ratio16x9 => _CanvasAspectRatio.ratio16x9,
      CanvasAspectRatioPreset.ratio9x16 => _CanvasAspectRatio.ratio9x16,
      CanvasAspectRatioPreset.ratio1x1 => _CanvasAspectRatio.ratio1x1,
      CanvasAspectRatioPreset.ratio4x5 => _CanvasAspectRatio.ratio4x5,
    };
  }

  double? get _selectedAspectRatioValue {
    switch (_canvasAspectRatio) {
      case _CanvasAspectRatio.original:
        return null;
      case _CanvasAspectRatio.ratio16x9:
        return 16 / 9;
      case _CanvasAspectRatio.ratio9x16:
        return 9 / 16;
      case _CanvasAspectRatio.ratio1x1:
        return 1;
      case _CanvasAspectRatio.ratio4x5:
        return 4 / 5;
    }
  }

  Future<void> _openSubtitleTextEditor(SubtitleEntry entry) async {
    final editorState = ref.read(editorProvider);
    final clip = _clipById(entry.id, editorState);
    final track = clip == null ? null : _trackForClip(clip, editorState);
    if (track?.isLocked == true) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SubtitleEditModal(entry: entry),
    );
  }

  Future<void> _openOverlayAddSheet(TimelineTrack preferredTrack) async {
    final option = await showFixedEditorSheet<_OverlayAddOption>(
      context: context,
      title: 'Add overlay',
      subtitle: 'Add a visual layer at the current playhead',
      heightFactor: 0.48,
      builder: (sheetContext) => Column(
        children: [
          _buildAddOptionTile(
            icon: Icons.photo_library_outlined,
            title: 'Photos',
            subtitle: 'Choose an image from this device',
            onTap: () => Navigator.pop(sheetContext, _OverlayAddOption.photos),
          ),
          _buildAddOptionTile(
            icon: Icons.video_library_outlined,
            title: 'Videos',
            subtitle: 'Add a video layer with full visual tools',
            onTap: () => Navigator.pop(sheetContext, _OverlayAddOption.videos),
          ),
          _buildAddOptionTile(
            icon: Icons.category_outlined,
            title: 'Elements',
            subtitle: 'GIPHY, stock media, backgrounds and overlays',
            onTap: () =>
                Navigator.pop(sheetContext, _OverlayAddOption.elements),
          ),
        ],
      ),
    );
    if (!mounted || option == null) return;
    ref.read(editorProvider.notifier).selectTrack(preferredTrack.id);
    switch (option) {
      case _OverlayAddOption.photos:
        await _pickOverlayMedia(photosOnly: true);
        break;
      case _OverlayAddOption.videos:
        await _pickOverlayMedia(videosOnly: true);
        break;
      case _OverlayAddOption.elements:
        await _openElementsLibrarySheet();
        break;
    }
  }

  Future<void> _openTextAddSheet(TimelineTrack preferredTrack) async {
    final option = await showFixedEditorSheet<_TextAddOption>(
      context: context,
      title: 'Add text',
      subtitle: 'Create a title or work with timed subtitles',
      heightFactor: 0.36,
      builder: (sheetContext) => Column(
        children: [
          _buildAddOptionTile(
            icon: Icons.title_rounded,
            title: 'Add Text',
            subtitle: 'Type and style text directly on the canvas',
            onTap: () => Navigator.pop(sheetContext, _TextAddOption.addText),
          ),
          _buildAddOptionTile(
            icon: Icons.closed_caption_outlined,
            title: 'Subtitles',
            subtitle: 'Generate or edit timed subtitles',
            onTap: () => Navigator.pop(sheetContext, _TextAddOption.subtitles),
          ),
        ],
      ),
    );
    if (!mounted || option == null) return;
    ref.read(editorProvider.notifier).selectTrack(preferredTrack.id);
    switch (option) {
      case _TextAddOption.addText:
        await _addTextClipAtPlayhead(preferredTrackId: preferredTrack.id);
        break;
      case _TextAddOption.subtitles:
        await _handleGenerateSubtitles();
        break;
    }
  }

  Future<void> _openAudioAddSheet(TimelineTrack preferredTrack) async {
    final option = await showFixedEditorSheet<_AudioAddOption>(
      context: context,
      title: 'Add audio',
      subtitle: 'Add a local sound or open an editor library',
      heightFactor: 0.48,
      builder: (sheetContext) => Column(
        children: [
          _buildAddOptionTile(
            icon: Icons.audio_file_outlined,
            title: 'Select a local track',
            subtitle: 'Import audio stored on this device',
            onTap: () =>
                Navigator.pop(sheetContext, _AudioAddOption.localTrack),
          ),
          _buildAddOptionTile(
            icon: Icons.graphic_eq_rounded,
            title: 'SFX',
            subtitle: 'Openverse and optional local sound effects',
            onTap: () => Navigator.pop(sheetContext, _AudioAddOption.sfx),
          ),
          _buildAddOptionTile(
            icon: Icons.library_music_outlined,
            title: 'Music',
            subtitle: 'CaptionCraft music library',
            badge: 'Soon',
            onTap: () => Navigator.pop(sheetContext, _AudioAddOption.music),
          ),
        ],
      ),
    );
    if (!mounted || option == null) return;
    ref.read(editorProvider.notifier).selectTrack(preferredTrack.id);
    switch (option) {
      case _AudioAddOption.localTrack:
        await _pickAudioMedia(forceNewTrack: true);
        break;
      case _AudioAddOption.sfx:
        await _openSfxLibrarySheet();
        break;
      case _AudioAddOption.music:
        await _openLibraryPlaceholderSheet(
          title: 'Music',
          icon: Icons.library_music_outlined,
        );
        break;
    }
  }

  Widget _buildAddOptionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    String? badge,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: ValueKey(
            'add_option_${title.toLowerCase().replaceAll(' ', '_')}',
          ),
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: kAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kAccent.withValues(alpha: 0.24)),
                  ),
                  child: Icon(icon, color: kAccent, size: 22),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: kTextSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: kAccent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(
                        color: kAccent,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right_rounded, color: kTextSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openLibraryPlaceholderSheet({
    required String title,
    required IconData icon,
  }) {
    return showResizableEditorSheet<void>(
      context: context,
      title: title,
      subtitle: 'Library placeholder',
      initialHeightFactor: 0.32,
      builder: (_) => SizedBox(
        height: 120,
        child: Center(
          child: Icon(
            icon,
            size: 38,
            color: kTextSecondary.withValues(alpha: 0.38),
          ),
        ),
      ),
    );
  }

  Future<void> _pickOverlayMedia({
    bool photosOnly = false,
    bool videosOnly = false,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: photosOnly
            ? ['png', 'jpg', 'jpeg', 'webp']
            : videosOnly
            ? ['mp4', 'mov']
            : ['png', 'jpg', 'jpeg', 'webp', 'gif', 'mp4', 'mov'],
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final selectedPath = file.path;
      if (selectedPath == null) return;
      final filePath = await MediaImportService.persistFile(
        selectedPath,
        originalFileName: file.name,
      );

      final extension = path.extension(filePath).toLowerCase();
      final assetType = switch (extension) {
        '.png' || '.jpg' || '.jpeg' || '.webp' => EditorAssetType.image,
        '.gif' => EditorAssetType.gif,
        '.mp4' || '.mov' => EditorAssetType.video,
        _ => EditorAssetType.unknown,
      };
      if (assetType == EditorAssetType.unknown) {
        SnackBarHelper.showWarning(context, 'Unsupported overlay file type.');
        return;
      }

      final clipType = switch (assetType) {
        EditorAssetType.image => TimelineTrackType.image,
        EditorAssetType.gif => TimelineTrackType.gif,
        EditorAssetType.video => TimelineTrackType.video,
        _ => TimelineTrackType.image,
      };

      Duration? sourceDuration;
      Map<String, dynamic> metadata = const {};
      if (assetType == EditorAssetType.video) {
        final mediaInfo = await FFmpegService.getMediaInfo(filePath);
        sourceDuration = Duration(
          milliseconds: (mediaInfo['durationMs'] as int?) ?? 0,
        );
        if (sourceDuration <= Duration.zero) {
          throw Exception('Could not read the selected video duration.');
        }
        metadata = _editorMediaMetadata(mediaInfo);
      }

      if (!mounted) return;

      _insertClipIntoTimeline(
        section: TimelineTrackSection.overlay,
        assetType: assetType,
        clipType: clipType,
        sourcePath: filePath,
        label: file.name,
        sourceDuration: sourceDuration,
        metadata: metadata,
        enableEmbeddedAudio:
            assetType == EditorAssetType.video && metadata['hasAudio'] == true,
      );
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(
          context,
          'Could not add overlay: ${error.toString().replaceFirst('Exception: ', '')}',
        );
      }
    }
  }

  Future<void> _pickBaseMedia(TimelineTrack targetTrack) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: const [
          'mp4',
          'mov',
          'm4v',
          'webm',
          'mkv',
          'png',
          'jpg',
          'jpeg',
          'webp',
          'gif',
        ],
      );
      final file = result?.files.firstOrNull;
      final selectedPath = file?.path;
      if (file == null || selectedPath == null) return;
      final filePath = await MediaImportService.persistFile(
        selectedPath,
        originalFileName: file.name,
      );
      final extension = path.extension(filePath).toLowerCase();
      final assetType = switch (extension) {
        '.png' || '.jpg' || '.jpeg' || '.webp' => EditorAssetType.image,
        '.gif' => EditorAssetType.gif,
        '.mp4' ||
        '.mov' ||
        '.m4v' ||
        '.webm' ||
        '.mkv' => EditorAssetType.video,
        _ => EditorAssetType.unknown,
      };
      if (assetType == EditorAssetType.unknown) {
        throw Exception('This file cannot be used as base-layer media.');
      }
      final clipType = switch (assetType) {
        EditorAssetType.image => TimelineTrackType.image,
        EditorAssetType.gif => TimelineTrackType.gif,
        _ => TimelineTrackType.video,
      };
      Map<String, dynamic> mediaInfo = const {};
      if (assetType != EditorAssetType.image) {
        mediaInfo = await FFmpegService.getMediaInfo(filePath);
      } else {
        try {
          mediaInfo = await FFmpegService.getMediaInfo(filePath);
        } catch (_) {
          // Static images have a predictable editable duration even on
          // platforms where ffprobe does not return stream timing.
        }
      }
      var sourceDuration = Duration(
        milliseconds: (mediaInfo['durationMs'] as int?) ?? 0,
      );
      if (assetType == EditorAssetType.video &&
          sourceDuration <= Duration.zero) {
        throw Exception('Could not read the selected video duration.');
      }
      if (sourceDuration <= Duration.zero) {
        sourceDuration = const Duration(seconds: 4);
      }
      if (!mounted) return;
      _insertClipIntoTimeline(
        section: TimelineTrackSection.baseVideo,
        assetType: assetType,
        clipType: clipType,
        sourcePath: filePath,
        label: file.name,
        sourceDuration: sourceDuration,
        appendToMainTrack: true,
        preferredTrackId: targetTrack.id,
        metadata: _editorMediaMetadata(mediaInfo),
        enableEmbeddedAudio:
            assetType == EditorAssetType.video && mediaInfo['hasAudio'] == true,
      );
    } catch (error) {
      if (!mounted) return;
      SnackBarHelper.showError(
        context,
        'Could not add base media: ${error.toString().replaceFirst('Exception: ', '')}',
      );
    }
  }

  Future<void> _pickAudioMedia({bool forceNewTrack = false}) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.audio,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final selectedPath = file.path;
      if (selectedPath == null) return;
      final filePath = await MediaImportService.persistFile(
        selectedPath,
        originalFileName: file.name,
      );

      final mediaInfo = await FFmpegService.getMediaInfo(filePath);
      final duration = Duration(
        milliseconds: (mediaInfo['durationMs'] as int?) ?? 0,
      );
      if (duration <= Duration.zero) {
        throw Exception('Could not read the selected audio duration.');
      }

      if (!mounted) return;

      _insertClipIntoTimeline(
        section: TimelineTrackSection.audio,
        assetType: EditorAssetType.audio,
        clipType: TimelineTrackType.audio,
        sourcePath: filePath,
        label: file.name,
        sourceDuration: duration,
        metadata: _editorMediaMetadata(mediaInfo),
        forceNewTrack: forceNewTrack,
      );
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(
          context,
          'Could not add audio: ${error.toString().replaceFirst('Exception: ', '')}',
        );
      }
    }
  }

  Duration _currentCompositionDuration(EditorTimeline timeline) {
    return timeline.duration;
  }

  bool _insertClipIntoTimeline({
    required TimelineTrackSection section,
    required EditorAssetType assetType,
    required TimelineTrackType clipType,
    String? sourcePath,
    String? remoteUrl,
    bool isNetworkBacked = false,
    required String label,
    required Duration? sourceDuration,
    Map<String, dynamic> metadata = const {},
    bool forceNewTrack = false,
    bool reuseExistingTrackIfPresent = false,
    Duration? requestedStart,
    bool appendToMainTrack = false,
    String? preferredTrackId,
    bool enableEmbeddedAudio = false,
    ClipFitMode? fitMode,
    bool chromaKeyEnabled = false,
    Color chromaKeyColor = const Color(0xFF00FF00),
    double chromaKeySimilarity = 0.25,
  }) {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final clipDuration =
        sourceDuration == null || sourceDuration == Duration.zero
        ? const Duration(seconds: 4)
        : sourceDuration;
    final desiredStart = requestedStart ?? ref.read(playbackProvider).position;

    final asset = EditorAssetReference(
      type: assetType,
      label: label,
      sourcePath: sourcePath,
      remoteUrl: remoteUrl,
      isNetworkBacked: isNetworkBacked,
      metadata: metadata,
    );
    final compatibleTracks = timeline.tracks
        .where(
          (track) =>
              track.section == section &&
              !track.isSourceTrack &&
              !track.isLocked &&
              track.acceptsClipType(clipType),
        )
        .toList();
    final resolvedPreferredTrackId =
        preferredTrackId ?? editorState.selectedTrackId;
    compatibleTracks.sort((a, b) {
      if (a.id == resolvedPreferredTrackId) return -1;
      if (b.id == resolvedPreferredTrackId) return 1;
      return timeline.tracks.indexOf(a).compareTo(timeline.tracks.indexOf(b));
    });

    TimelineTrack? targetTrack;
    Duration placementStart = desiredStart < Duration.zero
        ? Duration.zero
        : desiredStart;
    if (!forceNewTrack) {
      for (final candidate in compatibleTracks) {
        final candidateStart = appendToMainTrack
            ? candidate.clips.fold<Duration>(
                Duration.zero,
                (latest, clip) => clip.endTime > latest ? clip.endTime : latest,
              )
            : placementStart;
        final probe = TimelineClip(
          trackId: candidate.id,
          type: clipType,
          label: label,
          startTime: candidateStart,
          endTime: candidateStart + clipDuration,
        );
        if (candidate.canPlaceClip(probe)) {
          targetTrack = candidate;
          placementStart = candidateStart;
          break;
        }
      }
    }

    // Downloads should reuse the editor's existing lane instead of creating a
    // fresh overlay for every item. If the playhead is occupied, choose the
    // nearest valid gap in one of the existing compatible lanes.
    if (targetTrack == null &&
        reuseExistingTrackIfPresent &&
        compatibleTracks.isNotEmpty) {
      final placement = resolveClosestReusableTrackPlacement(
        tracks: compatibleTracks,
        clipType: clipType,
        desiredStart: placementStart,
        duration: clipDuration,
      );
      targetTrack = placement?.track;
      placementStart = placement?.start ?? placementStart;
    }

    targetTrack ??= _createOptionalTrack(timeline, section, clipType);
    if (targetTrack == null) {
      SnackBarHelper.showInfo(
        context,
        'Add or unlock a compatible track before inserting this clip.',
      );
      return false;
    }
    final resolvedTargetTrack = targetTrack;
    final isNewTrack = !timeline.tracks.any(
      (track) => track.id == resolvedTargetTrack.id,
    );
    if (appendToMainTrack && resolvedTargetTrack.clips.isNotEmpty) {
      placementStart = resolvedTargetTrack.clips.fold<Duration>(
        Duration.zero,
        (latest, clip) => clip.endTime > latest ? clip.endTime : latest,
      );
    }
    var workingTimeline = isNewTrack
        ? timeline.insertTrackUsingEditorRules(resolvedTargetTrack)
        : timeline;

    final audioMix = resolveTimelineInsertionAudioMix(
      assetType: assetType,
      section: section,
      metadata: metadata,
      enableEmbeddedAudio: enableEmbeddedAudio,
    );
    final clip = TimelineClip(
      trackId: resolvedTargetTrack.id,
      type: clipType,
      label: label,
      assetId: asset.id,
      startTime: placementStart,
      endTime: placementStart + clipDuration,
      sourceStartTime: Duration.zero,
      sourceDuration: sourceDuration ?? clipDuration,
      fitMode:
          fitMode ??
          (section == TimelineTrackSection.overlay
              ? ClipFitMode.contain
              : ClipFitMode.cover),
      chromaKeyEnabled: chromaKeyEnabled,
      chromaKeyColor: chromaKeyColor,
      chromaKeySimilarity: chromaKeySimilarity,
      audioMix: audioMix,
      layer:
          resolvedTargetTrack.clips.fold<int>(
            -1,
            (highest, candidate) => math.max(highest, candidate.layer),
          ) +
          1,
    );

    var nextTracks = workingTimeline.tracks.map((track) {
      if (track.id != resolvedTargetTrack.id) return track;
      final clips = [...track.clips, clip]
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
      return track.copyWith(clips: clips);
    }).toList();
    workingTimeline = workingTimeline.copyWith(
      assets: [...timeline.assets, asset],
      tracks: nextTracks,
    );

    ref.read(editorProvider.notifier).setTimeline(workingTimeline);
    ref.read(editorProvider.notifier).selectTrack(resolvedTargetTrack.id);
    ref.read(editorProvider.notifier).selectClip(clip.id);
    SnackBarHelper.showSuccess(
      context,
      appendToMainTrack ? '$label added to the base layer' : '$label added',
    );
    return true;
  }

  Future<void> _openDiscoverSheet() {
    return showDiscoverSheet<void>(
      context: context,
      onAddToTimeline: _insertDiscoverDownload,
    );
  }

  Future<void> _insertDiscoverDownload(DiscoverDownloadItem item) async {
    final localPath = item.localPath;
    if (!item.canImport || localPath == null || localPath.trim().isEmpty) {
      throw StateError(
        'Finish this download before adding it to the timeline.',
      );
    }

    final importer = DiscoverMediaImportService();
    try {
      final imported = await importer.importDownload(item, jobId: item.id);
      if (!mounted) return;

      final playhead = ref.read(playbackProvider).position;
      final sourceDuration = imported.duration;
      final section = imported.clipType == TimelineTrackType.audio
          ? TimelineTrackSection.audio
          : TimelineTrackSection.overlay;

      final inserted = _insertClipIntoTimeline(
        section: section,
        assetType: imported.assetType,
        clipType: imported.clipType,
        sourcePath: imported.path,
        label: imported.label,
        sourceDuration: sourceDuration,
        requestedStart: playhead,
        reuseExistingTrackIfPresent: true,
        // The video's own audio remains attached to this clip. A separate
        // audio lane is created only through the explicit editor command.
        enableEmbeddedAudio:
            imported.assetType == EditorAssetType.video && imported.hasAudio,
        metadata: {
          ...imported.metadata,
          'discoverDownloadId': item.id,
          'discoverSource': item.source.name,
          'discoverSourceUrl': item.sourceUrl,
          if (item.pageUrl != null) 'discoverPageUrl': item.pageUrl,
          'downloadMimeType': item.mimeType,
          'wasTranscoded': imported.wasTranscoded,
        },
      );
      if (!inserted) {
        throw StateError(
          'No compatible free timeline lane is available at the playhead.',
        );
      }
    } finally {
      importer.dispose();
    }
  }

  Future<void> _openElementsLibrarySheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (sheetContext) => ElementLibrarySheet(
        onOnlineAssetSelected: _insertOnlineElementAsset,
        onPackAssetSelected: _insertPackElementAsset,
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    );
  }

  Set<String> _lutTargetClipIds(TimelineClip anchor) {
    final editorState = ref.read(editorProvider);
    final selectedIds = editorState.selectedClipIds.contains(anchor.id)
        ? editorState.selectedClipIds
        : {anchor.id};
    return editorState.timeline.tracks
        .expand((track) => track.clips)
        .where(
          (clip) => selectedIds.contains(clip.id) && clip.supportsVisualEffects,
        )
        .map((clip) => clip.id)
        .toSet();
  }

  Future<void> _openLutLibrarySheet(TimelineClip anchor) async {
    final targetIds = _lutTargetClipIds(anchor);
    if (targetIds.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (sheetContext) => ElementLibrarySheet(
        title: 'LUT Library',
        subtitle: targetIds.length == 1
            ? 'Preview and apply a verified offline color look'
            : 'Apply one look to ${targetIds.length} selected visual clips',
        initialDestination: ElementLibraryDestination.luts,
        showNavigation: false,
        onOnlineAssetSelected: _insertOnlineElementAsset,
        onPackAssetSelected: (item) => _applyPackLut(item, targetIds),
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    );
  }

  Future<({String name, String folder, bool favorite})?> _editLutOrganization(
    EditorLutAsset lut,
  ) async {
    final nameController = TextEditingController(text: lut.name);
    final folderController = TextEditingController(text: lut.folder);
    var favorite = lut.favorite;
    final result =
        await showDialog<({String name, String folder, bool favorite})>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text('Organize LUT'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: folderController,
                    decoration: const InputDecoration(
                      labelText: 'Folder / collection',
                      hintText: 'Film, Portrait, Favorites…',
                    ),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Favorite'),
                    value: favorite,
                    onChanged: (value) =>
                        setDialogState(() => favorite = value),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final name = nameController.text.trim();
                    final folder = folderController.text.trim();
                    if (name.isEmpty || folder.isEmpty) return;
                    Navigator.of(
                      dialogContext,
                    ).pop((name: name, folder: folder, favorite: favorite));
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        );
    nameController.dispose();
    folderController.dispose();
    return result;
  }

  Future<void> _applyPackLut(
    AssetPackCatalogItem item,
    Set<String> targetIds,
  ) async {
    if (item.mediaKind != AssetPackMediaKind.lut) {
      throw Exception('This library item is not a LUT.');
    }
    final source = File(item.localPath);
    if (!await source.exists() || await source.length() == 0) {
      throw Exception('This LUT is missing. Download the pack again.');
    }
    final durablePath = await MediaImportService.persistFile(
      item.localPath,
      originalFileName: path.basename(item.localPath),
      forceCopy: true,
      stableCacheKey: 'pack_${item.packId}_${item.packVersion}_${item.id}',
    );
    final lutId = ref
        .read(editorProvider.notifier)
        .importAndApplyLutToClips(
          clipIds: targetIds,
          sourcePath: durablePath,
          name: item.title,
          folder: 'Pack / ${item.categoryName}',
        );
    if (lutId == null) {
      throw Exception(
        'Unlock the selected visual clips before applying a LUT.',
      );
    }
    if (mounted) {
      SnackBarHelper.showSuccess(
        context,
        targetIds.length == 1
            ? '${item.title} applied'
            : '${item.title} applied to ${targetIds.length} clips',
      );
    }
  }

  Future<void> _importLutForSelection(TimelineClip anchor) async {
    final targetIds = _lutTargetClipIds(anchor);
    if (targetIds.isEmpty) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['cube', '3dl'],
      allowMultiple: false,
    );
    final selectedPath = result?.files.single.path;
    if (selectedPath == null || !mounted) return;
    try {
      await validateLutFile(selectedPath);
      final durablePath = await MediaImportService.persistFile(
        selectedPath,
        originalFileName: path.basename(selectedPath),
        forceCopy: true,
      );
      final lutId = ref
          .read(editorProvider.notifier)
          .importAndApplyLutToClips(
            clipIds: targetIds,
            sourcePath: durablePath,
            name: path.basenameWithoutExtension(selectedPath),
          );
      if (lutId == null) {
        throw Exception('Unlock the selected visual clips first.');
      }
      if (mounted) {
        SnackBarHelper.showSuccess(
          context,
          targetIds.length == 1
              ? 'LUT imported and applied'
              : 'LUT applied to ${targetIds.length} clips',
        );
      }
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(context, 'Could not import LUT: $error');
      }
    }
  }

  void _clearLutFromSelection(TimelineClip anchor) {
    final targetIds = _lutTargetClipIds(anchor);
    final cleared = ref
        .read(editorProvider.notifier)
        .applyLutToClips(targetIds, null);
    if (cleared) {
      SnackBarHelper.showSuccess(
        context,
        targetIds.length == 1
            ? 'LUT removed'
            : 'LUT removed from ${targetIds.length} clips',
      );
    }
  }

  Future<void> _openSfxLibrarySheet() async {
    final downloadCancellation = CancelToken();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.4),
        builder: (sheetContext) => SfxLibrarySheet(
          onOnlineAssetSelected: (result) => _insertOnlineSoundEffect(
            result,
            cancelToken: downloadCancellation,
          ),
          onPackAssetSelected: _insertPackSoundEffect,
          onClose: () => Navigator.of(sheetContext).pop(),
        ),
      );
    } finally {
      if (!downloadCancellation.isCancelled) {
        downloadCancellation.cancel('Sound-effects library closed.');
      }
    }
  }

  Future<void> _insertOnlineSoundEffect(
    SoundEffectLibraryAsset result, {
    CancelToken? cancelToken,
  }) async {
    Map<String, dynamic>? validatedMediaInfo;
    final localPath = await RemoteAudioImportService.download(
      url: result.downloadUrl,
      provider: result.provider.name,
      assetId: result.id,
      suggestedFileName: '${result.id}.${result.fileExtension}',
      cancelToken: cancelToken,
      validator: (candidatePath) async {
        try {
          final info = await FFmpegService.getMediaInfo(candidatePath);
          final durationMs = (info['durationMs'] as int?) ?? 0;
          final valid = durationMs > 0 && info['hasAudio'] == true;
          if (valid) validatedMediaInfo = info;
          return valid;
        } catch (_) {
          return false;
        }
      },
    );
    if (!mounted || cancelToken?.isCancelled == true) return;
    final mediaInfo = validatedMediaInfo;
    if (mediaInfo == null) {
      throw Exception('Could not validate the selected sound effect.');
    }
    final probedDuration = Duration(
      milliseconds: (mediaInfo['durationMs'] as int?) ?? 0,
    );
    final sourceDuration = probedDuration > Duration.zero
        ? probedDuration
        : result.duration;
    if (sourceDuration == null ||
        sourceDuration <= Duration.zero ||
        mediaInfo['hasAudio'] != true) {
      throw Exception('Could not read the selected sound-effect duration.');
    }
    if (!mounted || cancelToken?.isCancelled == true) return;

    final inserted = _insertClipIntoTimeline(
      section: TimelineTrackSection.audio,
      assetType: EditorAssetType.audio,
      clipType: TimelineTrackType.audio,
      label: result.title,
      sourcePath: localPath,
      sourceDuration: sourceDuration,
      forceNewTrack: true,
      metadata: {
        ..._editorMediaMetadata(mediaInfo),
        'durationMs': sourceDuration.inMilliseconds,
        'hasAudio': true,
        'provider': result.provider.name,
        'providerAssetId': result.id,
        'sourceName': result.sourceName,
        'sourcePageUrl': result.sourcePageUrl,
        'creatorName': result.creatorName,
        'creatorPageUrl': result.creatorPageUrl,
        'license': result.licenseCode,
        'licenseVersion': result.licenseVersion,
        'licenseUrl': result.licenseUrl,
        'attribution': result.attribution,
        'tags': result.tags,
      },
    );
    if (!inserted) {
      throw Exception(
        'Could not place this sound effect at the current playhead.',
      );
    }
  }

  Future<void> _insertPackSoundEffect(AssetPackCatalogItem result) async {
    if (result.mediaKind != AssetPackMediaKind.audio) {
      throw Exception('This local library item is not an audio file.');
    }
    final mediaFile = File(result.localPath);
    if (!await mediaFile.exists()) {
      throw Exception(
        'This downloaded sound effect is missing. Download the pack again.',
      );
    }

    var sourceDuration = result.duration;
    var hasAudio = result.hasAudio;
    final mediaInfo = await FFmpegService.getMediaInfo(result.localPath);
    if (sourceDuration == null || sourceDuration <= Duration.zero) {
      sourceDuration = Duration(
        milliseconds: (mediaInfo['durationMs'] as int?) ?? 0,
      );
    }
    hasAudio = mediaInfo['hasAudio'] == true;
    if (sourceDuration <= Duration.zero) {
      throw Exception('Could not read this sound-effect duration.');
    }
    final projectMediaPath = await MediaImportService.persistFile(
      result.localPath,
      originalFileName: path.basename(result.localPath),
      forceCopy: true,
      stableCacheKey:
          'pack_${result.packId}_${result.packVersion}_${result.id}',
    );

    final inserted = _insertClipIntoTimeline(
      section: TimelineTrackSection.audio,
      assetType: EditorAssetType.audio,
      clipType: TimelineTrackType.audio,
      label: result.title,
      sourcePath: projectMediaPath,
      sourceDuration: sourceDuration,
      forceNewTrack: true,
      metadata: {
        ...result.metadata,
        ..._editorMediaMetadata(mediaInfo),
        'provider': 'captionCraft',
        'packId': result.packId,
        'packVersion': result.packVersion,
        'libraryAssetId': result.id,
        'relativePath': result.relativePath,
        'categoryId': result.categoryId,
        'categoryName': result.categoryName,
        'durationMs': sourceDuration.inMilliseconds,
        'hasAudio': hasAudio,
        'tags': result.tags,
      },
    );
    if (!inserted) {
      throw Exception(
        'Could not place this sound effect at the current playhead.',
      );
    }
  }

  Future<void> _insertOnlineElementAsset(ElementLibraryAsset result) async {
    final isGiphy = result.provider == ElementLibraryProvider.giphy;
    final isSticker = result.subtype == ElementLibraryAssetSubtype.sticker;
    if (isGiphy) {
      final localPath = await RemoteMediaImportService.download(
        url: result.downloadUrl,
        provider: result.provider.name,
        assetId: result.id,
        isVideo: false,
        suggestedFileName: Uri.tryParse(result.downloadUrl)?.path,
      );
      var animationDuration = const Duration(seconds: 4);
      try {
        final mediaInfo = await FFmpegService.getMediaInfo(localPath);
        final durationMs = mediaInfo['durationMs'] as int?;
        if (durationMs != null && durationMs > 0) {
          animationDuration = Duration(milliseconds: durationMs);
        }
      } catch (_) {
        // Some animated image decoders do not expose a duration. A four-second
        // editable placement remains a predictable fallback.
      }
      final inserted = _insertClipIntoTimeline(
        section: TimelineTrackSection.overlay,
        assetType: isSticker ? EditorAssetType.sticker : EditorAssetType.gif,
        clipType: isSticker ? TimelineTrackType.sticker : TimelineTrackType.gif,
        label: result.title,
        sourceDuration: animationDuration,
        sourcePath: localPath,
        metadata: {
          'previewUrl': result.previewUrl,
          'providerOriginalUrl': result.downloadUrl,
          'providerAssetId': result.id,
          'width': result.width,
          'height': result.height,
          'durationMs': animationDuration.inMilliseconds,
          'provider': result.provider.name,
          'subtype': result.subtype.name,
          'attribution': result.attribution,
          'sourcePageUrl': result.sourcePageUrl,
        },
      );
      if (!inserted) {
        throw Exception(
          'Could not place this element at the current playhead.',
        );
      }
      return;
    }

    final isVideo = result.mediaKind == ElementLibraryMediaKind.video;
    final localPath = await RemoteMediaImportService.download(
      url: result.downloadUrl,
      provider: result.provider.name,
      assetId: result.id,
      isVideo: isVideo,
    );
    var sourceDuration = result.duration;
    var width = result.width;
    var height = result.height;
    var hasAudio = false;
    Map<String, dynamic> mediaInfo = const {};
    if (isVideo) {
      mediaInfo = await FFmpegService.getMediaInfo(localPath);
      if (sourceDuration == null || sourceDuration <= Duration.zero) {
        sourceDuration = Duration(
          milliseconds: (mediaInfo['durationMs'] as int?) ?? 0,
        );
      }
      width ??= mediaInfo['width'] as int?;
      height ??= mediaInfo['height'] as int?;
      hasAudio = mediaInfo['hasAudio'] == true;
    }
    if (isVideo &&
        (sourceDuration == null || sourceDuration <= Duration.zero)) {
      throw Exception('Could not read the selected video duration.');
    }
    final inserted = _insertClipIntoTimeline(
      section: TimelineTrackSection.overlay,
      assetType: isVideo ? EditorAssetType.video : EditorAssetType.image,
      clipType: isVideo ? TimelineTrackType.video : TimelineTrackType.image,
      label: result.title,
      sourcePath: localPath,
      sourceDuration: sourceDuration,
      metadata: {
        ..._editorMediaMetadata(mediaInfo),
        'previewUrl': result.previewUrl,
        'providerAssetId': result.id,
        'width': width,
        'height': height,
        'durationMs': sourceDuration?.inMilliseconds,
        'hasAudio': hasAudio,
        'provider': result.provider.name,
        'subtype': result.subtype.name,
        'attribution': result.attribution,
        'sourcePageUrl': result.sourcePageUrl,
        'creatorId': result.creatorId,
        'creatorName': result.creatorName,
        'creatorPageUrl': result.creatorPageUrl,
      },
      enableEmbeddedAudio: isVideo && hasAudio,
    );
    if (!inserted) {
      throw Exception('Could not place this element at the current playhead.');
    }
  }

  Future<void> _insertPackElementAsset(AssetPackCatalogItem result) async {
    if (result.mediaKind == AssetPackMediaKind.lut) {
      final editorState = ref.read(editorProvider);
      final selected = _clipById(editorState.selectedClipId ?? '', editorState);
      if (selected == null || !selected.supportsVisualEffects) {
        throw Exception('Select a visual clip first, or open Effects › LUTs.');
      }
      await _applyPackLut(result, _lutTargetClipIds(selected));
      return;
    }
    if (result.mediaKind == AssetPackMediaKind.audio) {
      throw Exception('Use the Sound Effects library for audio assets.');
    }
    final mediaFile = File(result.localPath);
    if (!await mediaFile.exists()) {
      throw Exception(
        'This downloaded pack item is missing. Download it again.',
      );
    }
    final isVideo = result.mediaKind == AssetPackMediaKind.video;
    var sourceDuration = result.duration;
    var width = result.width;
    var height = result.height;
    var hasAudio = result.hasAudio;
    Map<String, dynamic> mediaInfo = const {};
    if (isVideo) {
      mediaInfo = await FFmpegService.getMediaInfo(result.localPath);
      width ??= mediaInfo['width'] as int?;
      height ??= mediaInfo['height'] as int?;
      hasAudio = mediaInfo['hasAudio'] == true;
    }
    if (isVideo &&
        (sourceDuration == null || sourceDuration <= Duration.zero)) {
      sourceDuration = Duration(
        milliseconds: (mediaInfo['durationMs'] as int?) ?? 0,
      );
    }
    if (isVideo &&
        (sourceDuration == null || sourceDuration <= Duration.zero)) {
      throw Exception('Could not read this pack video duration.');
    }
    final projectMediaPath = await MediaImportService.persistFile(
      result.localPath,
      originalFileName: path.basename(result.localPath),
      forceCopy: true,
      stableCacheKey:
          'pack_${result.packId}_${result.packVersion}_${result.id}',
    );

    final compositing = result.metadata['compositing'];
    final compositingMap = compositing is Map
        ? Map<String, dynamic>.from(compositing)
        : const <String, dynamic>{};
    final chromaValue = compositingMap['chromaKey'];
    final chromaMap = chromaValue is Map
        ? Map<String, dynamic>.from(chromaValue)
        : const <String, dynamic>{};
    final compositingMode = compositingMap['mode'];
    final chromaKeyEnabled =
        compositingMode == 'chromaKey' ||
        compositingMode == 'screen' ||
        result.relativePath.toLowerCase().contains('green-screen');
    final similarity =
        (chromaMap['similarity'] as num?)?.toDouble() ??
        (compositingMap['similarity'] as num?)?.toDouble();
    final defaultKeyColor = compositingMode == 'screen'
        ? const Color(0xFF000000)
        : const Color(0xFF00FF00);
    final fitMode = result.packId == 'background-videos'
        ? ClipFitMode.cover
        : ClipFitMode.contain;
    final inserted = _insertClipIntoTimeline(
      section: TimelineTrackSection.overlay,
      assetType: isVideo ? EditorAssetType.video : EditorAssetType.image,
      clipType: isVideo ? TimelineTrackType.video : TimelineTrackType.image,
      label: result.title,
      sourcePath: projectMediaPath,
      sourceDuration: sourceDuration,
      fitMode: fitMode,
      chromaKeyEnabled: chromaKeyEnabled,
      chromaKeyColor: _parseCatalogColor(
        chromaMap['color'] ?? compositingMap['keyColor'],
        fallback: defaultKeyColor,
      ),
      chromaKeySimilarity:
          (similarity ?? (compositingMode == 'screen' ? 0.12 : 0.25))
              .clamp(0.01, 1)
              .toDouble(),
      metadata: {
        ...result.metadata,
        ..._editorMediaMetadata(mediaInfo),
        'provider': 'captionCraft',
        'packId': result.packId,
        'packVersion': result.packVersion,
        'libraryAssetId': result.id,
        'relativePath': result.relativePath,
        'previewPath': result.previewRelativePath,
        'categoryId': result.categoryId,
        'categoryName': result.categoryName,
        'width': width,
        'height': height,
        'durationMs': sourceDuration?.inMilliseconds,
        'hasAudio': hasAudio,
      },
      enableEmbeddedAudio: isVideo && hasAudio,
    );
    if (!inserted) {
      throw Exception('Could not place this element at the current playhead.');
    }
  }

  Color _parseCatalogColor(dynamic value, {required Color fallback}) {
    if (value is int) return Color(value);
    if (value is! String) return fallback;
    final normalized = value.trim().replaceFirst('#', '');
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) return fallback;
    return Color(normalized.length <= 6 ? 0xFF000000 | parsed : parsed);
  }

  Future<void> _addTextClipAtPlayhead({String? preferredTrackId}) async {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final playhead = ref.read(playbackProvider).position;
    final maxDuration = _currentCompositionDuration(timeline);
    final endTime = (playhead + const Duration(seconds: 4)) > maxDuration
        ? maxDuration
        : playhead + const Duration(seconds: 4);
    if (endTime <= playhead) {
      SnackBarHelper.showInfo(
        context,
        'Add an image or video before adding text here.',
      );
      return;
    }
    final preferredId = preferredTrackId ?? editorState.selectedTrackId;
    final candidates =
        timeline.tracks
            .where(
              (track) =>
                  track.section == TimelineTrackSection.textSubtitle &&
                  !track.isLocked &&
                  track.acceptsClipType(TimelineTrackType.text),
            )
            .toList()
          ..sort((a, b) {
            if (a.id == preferredId) return -1;
            if (b.id == preferredId) return 1;
            return timeline.tracks
                .indexOf(a)
                .compareTo(timeline.tracks.indexOf(b));
          });
    final probe = TimelineClip(
      trackId: '',
      type: TimelineTrackType.text,
      label: 'Text',
      startTime: playhead,
      endTime: endTime,
    );
    final existingTrack = candidates
        .where((track) => track.canPlaceClip(probe.copyWith(trackId: track.id)))
        .firstOrNull;
    final targetTrack =
        existingTrack ??
        _createOptionalTrack(
          timeline,
          TimelineTrackSection.textSubtitle,
          TimelineTrackType.text,
        );
    if (targetTrack == null) return;
    if (!targetTrack.acceptsClipType(TimelineTrackType.text)) {
      SnackBarHelper.showInfo(
        context,
        'Add or unlock a text track before inserting text.',
      );
      return;
    }
    final workingTracks = existingTrack == null
        ? timeline.insertTrackUsingEditorRules(targetTrack).tracks
        : timeline.tracks;

    final clip = TimelineClip(
      trackId: targetTrack.id,
      type: TimelineTrackType.text,
      label: 'Text',
      text: 'Text',
      startTime: playhead,
      endTime: endTime,
      subtitleStyle: const SubtitleStyleModel(
        position: SubtitlePosition.center,
        fontSize: 32,
        maxWidthFactor: 0.75,
      ),
      fitMode: ClipFitMode.contain,
      layer:
          targetTrack.clips.fold<int>(
            -1,
            (highest, candidate) => math.max(highest, candidate.layer),
          ) +
          1,
    );

    final nextTracks = workingTracks.map((track) {
      if (track.id != targetTrack.id) return track;
      return track.copyWith(clips: [...track.clips, clip]);
    }).toList();

    await _openTextClipEditor(
      clip,
      isNew: true,
      insertionTimeline: timeline.copyWith(tracks: nextTracks),
    );
  }

  Future<void> _editTextClip(TimelineClip clip) async {
    if (clip.type != TimelineTrackType.text) return;
    final currentState = ref.read(editorProvider);
    final currentTrack = _trackForClip(clip, currentState);
    if (currentTrack == null || currentTrack.isLocked) return;
    await _openTextClipEditor(clip);
  }

  Future<void> _openClipAnimationSheetForSelection(TimelineClip clip) async {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    if (track == null || track.isLocked || !clip.supportsClipAnimation) return;
    await _openClipAnimationSheet(clip, track);
  }

  Future<void> _openTextClipEditor(
    TimelineClip originalClip, {
    bool isNew = false,
    EditorTimeline? insertionTimeline,
  }) async {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null) return;
    final previousSheet = _textEditorSheetController;
    if (previousSheet != null) {
      previousSheet.close();
      await previousSheet.closed;
      if (!mounted) return;
    }

    final editorNotifier = ref.read(editorProvider.notifier);
    var gestureOpen = false;
    if (isNew && insertionTimeline != null) {
      editorNotifier.beginTimelineGestureEdit();
      gestureOpen = true;
      editorNotifier.setTimeline(insertionTimeline, recordHistory: false);
      editorNotifier.selectTrack(originalClip.trackId);
      editorNotifier.selectClip(originalClip.id);
    }

    final controller = TextEditingController(
      text: originalClip.text ?? originalClip.label,
    );
    if (isNew) {
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
    }
    final focusNode = FocusNode();
    var liveStyle =
        originalClip.subtitleStyle ??
        const SubtitleStyleModel(
          position: SubtitlePosition.center,
          fontSize: 32,
          maxWidthFactor: 0.75,
        );
    var keepChanges = true;
    var isClosing = false;
    if (!gestureOpen) {
      editorNotifier.beginTimelineGestureEdit();
      gestureOpen = true;
    }

    void updateClip({String? text, SubtitleStyleModel? style}) {
      final liveClip = _clipById(originalClip.id, ref.read(editorProvider));
      if (liveClip == null) return;
      final nextText = text ?? liveClip.text ?? liveClip.label;
      _updateTimelineClip(
        liveClip,
        (current) => current.copyWith(
          label: nextText.trim().isEmpty ? 'Text' : nextText.trim(),
          text: nextText,
          subtitleStyle: style ?? current.subtitleStyle ?? liveStyle,
        ),
        recordHistory: false,
      );
    }

    late PersistentBottomSheetController sheetController;
    void closeSheet() {
      if (isClosing) return;
      isClosing = true;
      focusNode.unfocus();
      sheetController.close();
    }

    sheetController = scaffold.showBottomSheet(
      (sheetContext) => TextClipEditorSheet(
        key: ValueKey('text_editor_sheet_${originalClip.id}'),
        title: isNew ? 'Add text' : 'Edit text',
        controller: controller,
        focusNode: focusNode,
        initialStyle: liveStyle,
        autofocus: isNew,
        onTextChanged: (value) => updateClip(text: value),
        onStyleChanged: (style) {
          liveStyle = style;
          updateClip(style: style);
        },
        onDone: closeSheet,
        onCancel: () {
          keepChanges = false;
          closeSheet();
        },
      ),
      backgroundColor: Colors.transparent,
      elevation: 0,
      enableDrag: false,
    );
    _textEditorSheetController = sheetController;
    await sheetController.closed;
    if (identical(_textEditorSheetController, sheetController)) {
      _textEditorSheetController = null;
    }

    final shouldKeepChanges = keepChanges && controller.text.trim().isNotEmpty;
    if (gestureOpen) {
      gestureOpen = false;
      if (shouldKeepChanges) {
        editorNotifier.endTimelineGestureEdit();
      } else {
        editorNotifier.cancelTimelineGestureEdit();
      }
    }
    // `PersistentBottomSheetController.closed` can complete during the same
    // frame in which the route removes its TextField. Dispose input objects on
    // the next frame so the departing focus/animation widgets never observe a
    // disposed notifier.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusNode.dispose();
      controller.dispose();
    });
    if (mounted && shouldKeepChanges && !isNew) {
      SnackBarHelper.showSuccess(context, 'Text updated');
    }
  }

  void _updateSelectedClipTransition({
    required TimelineClip clip,
    bool updateIntro = false,
    bool updateOutro = true,
    TransitionType? type,
    int? durationMs,
  }) {
    final editorState = ref.read(editorProvider);
    final liveClip = _clipById(clip.id, editorState);
    final track = _trackForClip(liveClip, editorState);
    if (liveClip == null ||
        track == null ||
        track.isLocked ||
        !liveClip.supportsClipAnimation) {
      return;
    }
    _updateTimelineClip(
      liveClip,
      (current) => current.copyWith(
        introTransition: updateIntro
            ? current.introTransition.copyWith(
                type: type ?? current.introTransition.type,
                durationMs: durationMs ?? current.introTransition.durationMs,
              )
            : current.introTransition,
        outroTransition: updateOutro
            ? current.outroTransition.copyWith(
                type: type ?? current.outroTransition.type,
                durationMs: durationMs ?? current.outroTransition.durationMs,
              )
            : current.outroTransition,
      ),
    );
  }

  void _updateSelectedClipAudioMix(
    TimelineClip clip, {
    bool? muted,
    double? volume,
    int? fadeInMs,
    int? fadeOutMs,
    double? pan,
    bool? normalize,
    AudioFadeShape? fadeInShape,
    AudioFadeShape? fadeOutShape,
    EditorAudioChannelMode? channelMode,
    int? sourceStreamIndex,
    int? sourceLeftChannel,
    int? sourceRightChannel,
    double? leftGain,
    double? rightGain,
    double? targetLufs,
    double? peakLimitDb,
    double? pitchSemitones,
    double? timeStretch,
    bool? preservePitch,
    AudioLoudnessAnalysis? loudnessAnalysis,
    bool clearLoudnessAnalysis = false,
  }) {
    final editorState = ref.read(editorProvider);
    if (!editorState.timeline.clipHasAudio(clip)) {
      return;
    }
    final owner = _audioOwnerForClip(editorState.timeline, clip);
    if (owner == null || owner.track.isLocked) return;
    final notifier = ref.read(editorProvider.notifier);
    final hasMixUpdate =
        muted != null ||
        fadeInMs != null ||
        fadeOutMs != null ||
        pan != null ||
        normalize != null ||
        fadeInShape != null ||
        fadeOutShape != null ||
        channelMode != null ||
        sourceStreamIndex != null ||
        sourceLeftChannel != null ||
        sourceRightChannel != null ||
        leftGain != null ||
        rightGain != null ||
        targetLufs != null ||
        peakLimitDb != null ||
        pitchSemitones != null ||
        timeStretch != null ||
        preservePitch != null ||
        loudnessAnalysis != null ||
        clearLoudnessAnalysis;
    final invalidatesAnalysis =
        fadeInMs != null ||
        fadeOutMs != null ||
        pan != null ||
        fadeInShape != null ||
        fadeOutShape != null ||
        channelMode != null ||
        sourceStreamIndex != null ||
        sourceLeftChannel != null ||
        sourceRightChannel != null ||
        leftGain != null ||
        rightGain != null ||
        targetLufs != null ||
        peakLimitDb != null ||
        pitchSemitones != null ||
        timeStretch != null ||
        preservePitch != null;
    final ownsGesture =
        volume != null && hasMixUpdate && !editorState.isTimelineGestureEditing;
    if (ownsGesture) notifier.beginTimelineGestureEdit();
    try {
      if (volume != null) {
        notifier.updateClipVolumeAt(
          clipId: owner.clip.id,
          absolutePosition: ref.read(playbackProvider).position,
          volume: volume,
        );
      }
      if (hasMixUpdate) {
        notifier.updateClip(
          owner.clip.id,
          (candidate) => candidate.copyWith(
            audioMix: candidate.audioMix.copyWith(
              muted: muted ?? candidate.audioMix.muted,
              fadeInMs: fadeInMs ?? candidate.audioMix.fadeInMs,
              fadeOutMs: fadeOutMs ?? candidate.audioMix.fadeOutMs,
              pan: pan ?? candidate.audioMix.pan,
              normalize: normalize ?? candidate.audioMix.normalize,
              fadeInShape: fadeInShape ?? candidate.audioMix.fadeInShape,
              fadeOutShape: fadeOutShape ?? candidate.audioMix.fadeOutShape,
              channelMode: channelMode ?? candidate.audioMix.channelMode,
              sourceStreamIndex:
                  sourceStreamIndex ?? candidate.audioMix.sourceStreamIndex,
              sourceLeftChannel:
                  sourceLeftChannel ?? candidate.audioMix.sourceLeftChannel,
              sourceRightChannel:
                  sourceRightChannel ?? candidate.audioMix.sourceRightChannel,
              leftGain: leftGain ?? candidate.audioMix.leftGain,
              rightGain: rightGain ?? candidate.audioMix.rightGain,
              targetLufs: targetLufs ?? candidate.audioMix.targetLufs,
              peakLimitDb: peakLimitDb ?? candidate.audioMix.peakLimitDb,
              pitchSemitones:
                  pitchSemitones ?? candidate.audioMix.pitchSemitones,
              timeStretch: timeStretch ?? candidate.audioMix.timeStretch,
              preservePitch: preservePitch ?? candidate.audioMix.preservePitch,
              loudnessAnalysis: loudnessAnalysis,
              clearLoudnessAnalysis:
                  clearLoudnessAnalysis ||
                  (loudnessAnalysis == null && invalidatesAnalysis),
            ),
          ),
        );
      }
    } finally {
      if (ownsGesture) notifier.endTimelineGestureEdit();
    }
  }

  Future<void> _analyzeAudioClip(TimelineClip clip) async {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final owner = _audioOwnerForClip(timeline, clip);
    if (owner == null || owner.track.isLocked) return;
    final asset = timeline.assetForClip(owner.clip);
    var sourcePath = asset?.sourcePath?.trim() ?? '';
    final linkedVideoId = owner.clip.linkedClipId;
    if (sourcePath.isEmpty && linkedVideoId != null) {
      final sourceVideo = _clipById(linkedVideoId, editorState);
      sourcePath = sourceVideo == null
          ? ''
          : timeline.assetForClip(sourceVideo)?.sourcePath?.trim() ?? '';
    }
    if (sourcePath.isEmpty && owner.clip.type == TimelineTrackType.video) {
      sourcePath = resolveCaptionMediaPath(
        timeline: timeline,
        sourceClip: owner.clip,
        legacyBaseVideoPath: widget.project.videoPath,
      );
    }
    if (sourcePath.isEmpty || !await File(sourcePath).exists()) {
      if (mounted) {
        SnackBarHelper.showError(context, 'The audio source is unavailable.');
      }
      return;
    }
    setState(() => _analyzingAudioClipId = owner.clip.id);
    try {
      final analysis = await AudioMeterService.analyzeClip(
        timeline: timeline,
        track: owner.track,
        clip: owner.clip,
        asset: asset,
        sourcePath: sourcePath,
      );
      if (!mounted) return;
      final current = _clipById(owner.clip.id, ref.read(editorProvider));
      if (current == null) return;
      _updateSelectedClipAudioMix(
        current,
        normalize: true,
        loudnessAnalysis: analysis,
      );
      SnackBarHelper.showSuccess(
        context,
        'Measured ${analysis.integratedLufs.toStringAsFixed(1)} LUFS.',
      );
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(context, 'Audio analysis failed: $error');
      }
    } finally {
      if (mounted) setState(() => _analyzingAudioClipId = null);
    }
  }

  Future<void> _crossfadeSelectedAudioClips() async {
    final editorState = ref.read(editorProvider);
    final selectedIds = <String>{
      ...editorState.selectedClipIds,
      if (editorState.selectedClipId != null) editorState.selectedClipId!,
    };
    final clips = <TimelineClip>[];
    for (final track in editorState.timeline.tracks) {
      for (final clip in track.clips) {
        if (selectedIds.contains(clip.id) &&
            clip.type == TimelineTrackType.audio) {
          clips.add(clip);
        }
      }
    }
    clips.sort((a, b) => a.startTime.compareTo(b.startTime));
    if (clips.length != 2) {
      SnackBarHelper.showInfo(
        context,
        'Select exactly two independent audio clips to crossfade.',
      );
      return;
    }
    final maximumMs = math.min(
      clips.first.duration.inMilliseconds ~/ 2,
      clips.last.duration.inMilliseconds ~/ 2,
    );
    final defaultMs = math.min(1000, maximumMs);
    final controller = TextEditingController(
      text: (defaultMs / 1000).toStringAsFixed(2),
    );
    final durationMs = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create music crossfade'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Crossfade duration (seconds)',
            helperText: 'Maximum ${(maximumMs / 1000).toStringAsFixed(2)} s',
          ),
          onSubmitted: (value) {
            final seconds = double.tryParse(value);
            if (seconds != null) {
              Navigator.of(dialogContext).pop((seconds * 1000).round());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final seconds = double.tryParse(controller.text);
              if (seconds != null) {
                Navigator.of(dialogContext).pop((seconds * 1000).round());
              }
            },
            child: const Text('Crossfade'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (durationMs == null || !mounted) return;
    try {
      final next = applyAudioCrossfadeForTesting(
        timeline: ref.read(editorProvider).timeline,
        firstClipId: clips.first.id,
        secondClipId: clips.last.id,
        duration: Duration(milliseconds: durationMs),
      );
      ref.read(editorProvider.notifier).setTimeline(next);
      SnackBarHelper.showSuccess(context, 'Music crossfade created.');
    } catch (error) {
      SnackBarHelper.showError(context, '$error');
    }
  }

  Future<void> _fitAudioClipToTarget(TimelineClip clip) async {
    final sourceSpan = clip.sourceDuration > Duration.zero
        ? clip.sourceDuration
        : Duration(
            microseconds: (clip.duration.inMicroseconds * clip.playbackRate)
                .round(),
          );
    final controller = TextEditingController(
      text: (clip.duration.inMilliseconds / 1000).toStringAsFixed(2),
    );
    final durationMs = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Fit music to duration'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Target duration (seconds)',
            helperText:
                'Selected source: ${(sourceSpan.inMilliseconds / 1000).toStringAsFixed(2)} s',
          ),
          onSubmitted: (value) {
            final seconds = double.tryParse(value);
            if (seconds != null) {
              Navigator.of(dialogContext).pop((seconds * 1000).round());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final seconds = double.tryParse(controller.text);
              if (seconds != null) {
                Navigator.of(dialogContext).pop((seconds * 1000).round());
              }
            },
            child: const Text('Fit'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (durationMs == null || durationMs <= 0 || !mounted) return;
    try {
      final next = fitAudioClipToDurationForTesting(
        timeline: ref.read(editorProvider).timeline,
        clipId: clip.id,
        targetDuration: Duration(milliseconds: durationMs),
      );
      ref.read(editorProvider.notifier).setTimeline(next);
      SnackBarHelper.showSuccess(context, 'Music fitted with pitch preserved.');
    } catch (error) {
      SnackBarHelper.showError(context, '$error');
    }
  }

  void _unlinkSeparatedAudio(TimelineClip audio) {
    final timeline = ref.read(editorProvider).timeline;
    final next = unlinkSeparatedAudioForTesting(
      timeline: timeline,
      audioClipId: audio.id,
    );
    ref.read(editorProvider.notifier).setTimeline(next);
    SnackBarHelper.showSuccess(
      context,
      'Audio unlinked and can now move independently.',
    );
  }

  Future<void> _relinkSeparatedAudio(TimelineClip audio) async {
    final timeline = ref.read(editorProvider).timeline;
    final candidates = <TimelineClip>[];
    for (final track in timeline.tracks) {
      for (final clip in track.clips) {
        if (clip.type == TimelineTrackType.video &&
            clip.assetId != null &&
            clip.assetId == audio.assetId &&
            _separatedAudioForVideo(timeline, clip.id) == null) {
          candidates.add(clip);
        }
      }
    }
    if (candidates.isEmpty) {
      SnackBarHelper.showInfo(
        context,
        'No available source video uses this audio asset.',
      );
      return;
    }
    TimelineClip? target = candidates.singleOrNull;
    target ??= await showDialog<TimelineClip>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Relink to source video'),
        children: [
          for (final candidate in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(candidate),
              child: Text(
                '${candidate.label} • ${SubtitleEntry.formatDisplayTime(candidate.startTime)}',
              ),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    try {
      final next = relinkSeparatedAudioForTesting(
        timeline: ref.read(editorProvider).timeline,
        audioClipId: audio.id,
        videoClipId: target.id,
      );
      ref.read(editorProvider.notifier).setTimeline(next);
      SnackBarHelper.showSuccess(context, 'Audio relinked to source video.');
    } catch (error) {
      SnackBarHelper.showError(context, '$error');
    }
  }

  void _reattachSeparatedAudio(TimelineClip audio) {
    final linkedVideoId = audio.linkedClipId;
    try {
      final next = reattachSeparatedAudioForTesting(
        timeline: ref.read(editorProvider).timeline,
        audioClipId: audio.id,
      );
      ref.read(editorProvider.notifier).setTimeline(next);
      if (linkedVideoId != null) {
        ref.read(editorProvider.notifier).selectClip(linkedVideoId);
      }
      SnackBarHelper.showSuccess(context, 'Audio reattached to the video.');
    } catch (error) {
      SnackBarHelper.showError(context, '$error');
    }
  }

  Future<void> _editClipVolumeDb(
    TimelineClip clip,
    double currentDecibels,
  ) async {
    final controller = TextEditingController(
      text: currentDecibels.toStringAsFixed(1),
    );
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clip volume'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
            signed: true,
            decimal: true,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^-?\d{0,2}(\.\d?)?')),
          ],
          decoration: const InputDecoration(
            labelText: 'Gain in dB',
            helperText: 'Range: −60.0 dB to +6.0 dB',
            suffixText: 'dB',
          ),
          onSubmitted: (text) => Navigator.of(
            context,
          ).pop(double.tryParse(text)?.clamp(-60.0, 6.0).toDouble()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              double.tryParse(controller.text)?.clamp(-60.0, 6.0).toDouble(),
            ),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    _updateSelectedClipAudioMix(
      clip,
      volume: _dbToLinearGain(value),
      muted: value <= -60,
    );
  }

  void _updateTrackAudioMix(String trackId, {double? gain, double? pan}) {
    ref
        .read(editorProvider.notifier)
        .updateTrack(
          trackId,
          (track) => track.copyWith(
            audioGain: gain ?? track.audioGain,
            audioPan: pan ?? track.audioPan,
          ),
        );
  }

  void _updateSelectedClipDucking(
    TimelineClip clip, {
    bool? enabled,
    double? amount,
    int? attackMs,
    int? releaseMs,
    List<String>? sidechainTrackIds,
  }) {
    ref
        .read(editorProvider.notifier)
        .updateClip(
          clip.id,
          (current) => current.copyWith(
            autoDuck: enabled ?? current.autoDuck,
            duckAmount: amount ?? current.duckAmount,
            duckAttackMs: attackMs ?? current.duckAttackMs,
            duckReleaseMs: releaseMs ?? current.duckReleaseMs,
            duckSidechainTrackIds:
                sidechainTrackIds ?? current.duckSidechainTrackIds,
          ),
        );
  }

  Future<void> _chooseDuckingSidechains(TimelineClip clip) async {
    final timeline = ref.read(editorProvider).timeline;
    final candidates = timeline.tracks
        .where(
          (track) =>
              track.id != clip.trackId &&
              (track.type == TimelineTrackType.audio ||
                  track.type == TimelineTrackType.video ||
                  track.type == TimelineTrackType.text ||
                  track.type == TimelineTrackType.subtitle),
        )
        .toList();
    var selected = clip.duckSidechainTrackIds.toSet();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Ducking sidechains'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('All dialogue and audible tracks'),
                  value: selected.isEmpty,
                  onChanged: (_) => setDialogState(() => selected = {}),
                ),
                for (final track in candidates)
                  CheckboxListTile(
                    key: ValueKey('duck_sidechain_${track.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(track.displayName),
                    subtitle: Text(track.type.name),
                    value: selected.contains(track.id),
                    onChanged: (enabled) {
                      setDialogState(() {
                        selected = {...selected};
                        if (enabled == true) {
                          selected.add(track.id);
                        } else {
                          selected.remove(track.id);
                        }
                      });
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    _updateSelectedClipDucking(
      clip,
      sidechainTrackIds: result.toList()..sort(),
    );
  }

  TimelineTrack? _createOptionalTrack(
    EditorTimeline timeline,
    TimelineTrackSection section,
    TimelineTrackType clipType,
  ) {
    final isCompatibleType = switch (section) {
      TimelineTrackSection.overlay =>
        clipType.isVisualMedia || clipType == TimelineTrackType.effect,
      TimelineTrackSection.textSubtitle =>
        clipType == TimelineTrackType.text ||
            clipType == TimelineTrackType.subtitle,
      TimelineTrackSection.audio => clipType == TimelineTrackType.audio,
      TimelineTrackSection.baseVideo => clipType.isVisualMedia,
    };
    if (!isCompatibleType) return null;

    final name = switch (clipType) {
      TimelineTrackType.effect => timeline.nextTrackNameForSection(
        TimelineTrackSection.overlay,
      ),
      TimelineTrackType.subtitle =>
        'Subtitles ${timeline.tracks.where((track) => track.type == clipType).length + 1}',
      TimelineTrackType.video ||
      TimelineTrackType.image ||
      TimelineTrackType.gif ||
      TimelineTrackType.sticker
          when section == TimelineTrackSection.baseVideo =>
        'Base layer',
      _ => timeline.nextTrackNameForSection(section),
    };
    return TimelineTrack(
      name: name,
      type: clipType == TimelineTrackType.effect
          ? TimelineTrackType.video
          : clipType,
      section: section,
    );
  }

  _SelectionCapabilities _selectionCapabilitiesFor(
    EditorState editorState,
    TimelineClip? selectedClip,
  ) {
    final selectedTrack = _trackForClip(selectedClip, editorState);
    final canEdit =
        selectedClip != null &&
        selectedTrack != null &&
        !selectedTrack.isLocked;
    final canVisualEffects = canEdit && selectedClip.supportsVisualEffects;
    final canAnimate = canEdit && selectedClip.supportsClipAnimation;
    final canTransition =
        canEdit &&
        selectedTrack.section == TimelineTrackSection.baseVideo &&
        selectedClip.type == TimelineTrackType.video;
    final canAdjustAudio =
        canEdit && editorState.timeline.clipHasAudio(selectedClip);
    final canChangeLayer =
        canEdit && selectedTrack.section == TimelineTrackSection.overlay;
    final canArrange =
        canEdit && selectedClip.type != TimelineTrackType.subtitle;
    final isFilterEffect =
        canEdit &&
        selectedClip.type == TimelineTrackType.effect &&
        selectedClip.effectKind == TimelineEffectKind.filter;
    final isBlurEffect =
        canEdit &&
        selectedClip.type == TimelineTrackType.effect &&
        selectedClip.effectKind == TimelineEffectKind.blur;

    return _SelectionCapabilities(
      canEdit: canEdit,
      canAdjustAudio: canAdjustAudio,
      canVisualEffects: canVisualEffects,
      canAnimate: canAnimate,
      canTransition: canTransition,
      canArrange: canArrange,
      canChangeLayer: canChangeLayer,
      isFilterEffect: isFilterEffect,
      isBlurEffect: isBlurEffect,
    );
  }

  Widget _buildBottomQuickActions(
    BuildContext context,
    TimelineClip? selectedClip,
  ) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final editorState = ref.read(editorProvider);
    final capabilities = _selectionCapabilitiesFor(editorState, selectedClip);
    final activeCategory = _activeBottomCategory;
    final requestedSubgroup = _activeBottomSubgroup;
    final activeSubgroup =
        activeCategory != null &&
            requestedSubgroup != null &&
            _subgroupsFor(
              activeCategory,
            ).any((subgroup) => subgroup.$1 == requestedSubgroup)
        ? requestedSubgroup
        : null;

    return Container(
      key: const ValueKey('editor_tool_dock'),
      height: _editorDockContentHeight + bottomInset,
      padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + bottomInset),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final returningHome = child.key == const ValueKey('categories');
          final offset = Tween<Offset>(
            begin: returningHome
                ? const Offset(-0.16, 0)
                : const Offset(0.16, 0),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: offset, child: child),
          );
        },
        child: activeCategory == null
            ? _buildDockCategoryRow()
            : activeSubgroup == null
            ? _buildDockSubgroupRow(activeCategory, selectedClip, capabilities)
            : _buildDockToolRow(
                activeSubgroup,
                editorState,
                selectedClip,
                capabilities,
              ),
      ),
    );
  }

  double _editorDockHeightFor(BuildContext context) {
    return _editorDockContentHeight + MediaQuery.viewPaddingOf(context).bottom;
  }

  Widget _buildDockCategoryRow() {
    const categories = [
      (
        _BottomActionCategory.edit,
        'Edit',
        'Timing, transform and clip details',
        Icons.content_cut_rounded,
      ),
      (
        _BottomActionCategory.effects,
        'Effects',
        'Color, blur, motion and enhancement',
        Icons.auto_fix_high_rounded,
      ),
      (
        _BottomActionCategory.keyframes,
        'Keyframes',
        'State animation, navigation and graph curves',
        Icons.diamond_outlined,
      ),
      (
        _BottomActionCategory.audio,
        'Audio',
        'Mix, cleanup and automation',
        Icons.graphic_eq_rounded,
      ),
      (
        _BottomActionCategory.text,
        'Text',
        'Text objects and captions',
        Icons.title_rounded,
      ),
      (
        _BottomActionCategory.timeline,
        'Timeline',
        'Selection, tracks, markers and project setup',
        Icons.view_timeline_rounded,
      ),
      (
        _BottomActionCategory.canvas,
        'Canvas',
        'Open canvas format, background and guides',
        Icons.aspect_ratio_rounded,
      ),
      (
        _BottomActionCategory.studio,
        'Studio',
        'Open Creator Lab publishing workflows',
        Icons.auto_awesome_rounded,
      ),
      (
        _BottomActionCategory.discover,
        'Discover',
        'Find and download media without leaving the editor',
        Icons.travel_explore_rounded,
      ),
    ];
    return _buildActionScroller(
      key: const ValueKey('categories'),
      // Keep comfortable touch targets and let the existing horizontal
      // scroller reveal the remaining categories on narrow screens.
      actions: [
        for (final category in categories)
          _ActionSpec(
            key: ValueKey('dock_category_${category.$1.name}'),
            width: 72,
            group: 'Categories',
            label: category.$2,
            tooltip: category.$3,
            icon: category.$4,
            onTap: category.$1 == _BottomActionCategory.canvas
                ? _openCanvasSettingsSheet
                : category.$1 == _BottomActionCategory.studio
                ? _openCreatorLab
                : category.$1 == _BottomActionCategory.discover
                ? _openDiscoverSheet
                : () => setState(() {
                    _activeBottomCategory = category.$1;
                    _activeBottomSubgroup = null;
                  }),
          ),
      ],
    );
  }

  List<(_BottomActionSubgroup, String, String, IconData)> _subgroupsFor(
    _BottomActionCategory category,
  ) {
    return switch (category) {
      _BottomActionCategory.edit => const [
        (
          _BottomActionSubgroup.editTiming,
          'Timing',
          'Trim, speed, reverse and freeze',
          Icons.av_timer_rounded,
        ),
        (
          _BottomActionSubgroup.editTransform,
          'Transform',
          'Layout, crop, rotation and opacity',
          Icons.crop_rotate_rounded,
        ),
        (
          _BottomActionSubgroup.editDetails,
          'Details',
          'Attributes, notes and frame nudging',
          Icons.tune_rounded,
        ),
      ],
      _BottomActionCategory.effects => const [
        (
          _BottomActionSubgroup.effectsStack,
          'Stack',
          'Layer, reorder, mask and animate effects',
          Icons.auto_awesome_rounded,
        ),
        (
          _BottomActionSubgroup.effectsColor,
          'Color',
          'Chroma key, filters and adjustments',
          Icons.tonality_rounded,
        ),
        (
          _BottomActionSubgroup.effectsLuts,
          'LUTs',
          'Browse, import and control reusable color looks',
          Icons.color_lens_rounded,
        ),
        (
          _BottomActionSubgroup.effectsBlur,
          'Blur',
          'Whole-frame and privacy-region blur',
          Icons.blur_on_rounded,
        ),
        (
          _BottomActionSubgroup.effectsMotion,
          'Motion',
          'Animations and transitions',
          Icons.auto_awesome_motion_rounded,
        ),
        (
          _BottomActionSubgroup.effectsEnhance,
          'Enhance',
          'Stabilization and noise reduction',
          Icons.high_quality_rounded,
        ),
      ],
      _BottomActionCategory.keyframes => const [
        (
          _BottomActionSubgroup.keyframeControls,
          'States',
          'Add, delete, previous and next state',
          Icons.diamond_rounded,
        ),
        (
          _BottomActionSubgroup.keyframeCurves,
          'Curves',
          'Graph editor, easing presets and custom Bézier curves',
          Icons.multiline_chart_rounded,
        ),
        (
          _BottomActionSubgroup.keyframeProperties,
          'Advanced',
          'Edit an individual animation channel',
          Icons.tune_rounded,
        ),
      ],
      _BottomActionCategory.audio => const [
        (
          _BottomActionSubgroup.audioMix,
          'Mixer',
          'Volume, pan, fades and normalization',
          Icons.tune_rounded,
        ),
        (
          _BottomActionSubgroup.audioEffects,
          'Effects',
          'EQ, dynamics, restoration and pitch',
          Icons.multitrack_audio_rounded,
        ),
        (
          _BottomActionSubgroup.audioCleanup,
          'Cleanup',
          'Denoise and automatic ducking',
          Icons.noise_control_off_rounded,
        ),
      ],
      _BottomActionCategory.text => const [
        (
          _BottomActionSubgroup.textObjects,
          'Text',
          'Edit the selected text object',
          Icons.edit_rounded,
        ),
        (
          _BottomActionSubgroup.textCaptions,
          'Captions',
          'Subtitle styling and cleanup',
          Icons.closed_caption_rounded,
        ),
        (
          _BottomActionSubgroup.textFiles,
          'Files',
          'Import and export subtitle files',
          Icons.file_open_outlined,
        ),
      ],
      _BottomActionCategory.timeline => const [
        (
          _BottomActionSubgroup.timelineSelection,
          'Selection',
          'Batch selection and splitting',
          Icons.select_all_rounded,
        ),
        (
          _BottomActionSubgroup.timelineTracks,
          'Tracks',
          'Rename, duplicate and manage all tracks',
          Icons.layers_rounded,
        ),
        (
          _BottomActionSubgroup.timelineMarkers,
          'Markers',
          'Beat grids and chapter markers',
          Icons.bookmarks_outlined,
        ),
        (
          _BottomActionSubgroup.timelineProject,
          'Project',
          'Frame rate, timecode and clip labels',
          Icons.settings_suggest_outlined,
        ),
      ],
      _BottomActionCategory.canvas ||
      _BottomActionCategory.studio ||
      _BottomActionCategory.discover => const [],
    };
  }

  Widget _buildDockSubgroupRow(
    _BottomActionCategory category,
    TimelineClip? selectedClip,
    _SelectionCapabilities capabilities,
  ) {
    final subgroups = _subgroupsFor(category);
    return _buildActionScroller(
      key: ValueKey('subgroups_${category.name}'),
      spread: true,
      actions: [
        _dockBackAction(
          tooltip: 'Back to tool categories',
          onTap: () => setState(() {
            _activeBottomCategory = null;
            _activeBottomSubgroup = null;
          }),
        ),
        for (final subgroup in subgroups)
          _ActionSpec(
            key: ValueKey('dock_subgroup_${subgroup.$1.name}'),
            group: category.name,
            label: subgroup.$2,
            tooltip: subgroup.$3,
            icon: subgroup.$4,
            onTap: _isDirectBottomSubgroup(subgroup.$1)
                ? _directBottomSubgroupAction(
                    subgroup.$1,
                    selectedClip,
                    capabilities,
                  )
                : () => setState(() => _activeBottomSubgroup = subgroup.$1),
          ),
      ],
    );
  }

  bool _isDirectBottomSubgroup(_BottomActionSubgroup subgroup) {
    return subgroup == _BottomActionSubgroup.audioMix ||
        subgroup == _BottomActionSubgroup.textObjects;
  }

  VoidCallback? _directBottomSubgroupAction(
    _BottomActionSubgroup subgroup,
    TimelineClip? selectedClip,
    _SelectionCapabilities capabilities,
  ) {
    return switch (subgroup) {
      _BottomActionSubgroup.audioMix =>
        selectedClip != null && capabilities.canAdjustAudio
            ? () => _openAudioControlsSheet(selectedClip)
            : null,
      _BottomActionSubgroup.textObjects =>
        selectedClip?.type == TimelineTrackType.text && capabilities.canEdit
            ? () => _editTextClip(selectedClip!)
            : null,
      _ => null,
    };
  }

  Widget _buildDockToolRow(
    _BottomActionSubgroup subgroup,
    EditorState editorState,
    TimelineClip? selectedClip,
    _SelectionCapabilities capabilities,
  ) {
    final actions = _bottomActionsForSubgroup(
      subgroup,
      editorState,
      selectedClip,
      capabilities,
    );
    return _buildActionScroller(
      key: ValueKey('tools_${subgroup.name}'),
      actions: [
        _dockBackAction(
          tooltip:
              'Back to ${_bottomCategoryLabel(_activeBottomCategory!)} tools',
          onTap: () => setState(() => _activeBottomSubgroup = null),
        ),
        ...actions,
      ],
    );
  }

  _ActionSpec _dockBackAction({
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return _ActionSpec(
      key: const ValueKey('dock_back_button'),
      group: 'Navigation',
      label: 'Back',
      tooltip: tooltip,
      icon: Icons.arrow_back_rounded,
      onTap: onTap,
    );
  }

  String _bottomCategoryLabel(_BottomActionCategory category) {
    return switch (category) {
      _BottomActionCategory.edit => 'Edit',
      _BottomActionCategory.effects => 'Effects',
      _BottomActionCategory.keyframes => 'Keyframes',
      _BottomActionCategory.audio => 'Audio',
      _BottomActionCategory.text => 'Text',
      _BottomActionCategory.timeline => 'Timeline',
      _BottomActionCategory.canvas => 'Canvas',
      _BottomActionCategory.studio => 'Studio',
      _BottomActionCategory.discover => 'Discover',
    };
  }

  List<_ActionSpec> _bottomActionsForSubgroup(
    _BottomActionSubgroup subgroup,
    EditorState editorState,
    TimelineClip? selectedClip,
    _SelectionCapabilities capabilities,
  ) {
    final clipActions = _clipDockActions(selectedClip, capabilities);
    final effectActions = _visualDockActions(selectedClip, capabilities);
    final audioActions = _audioDockActions(selectedClip, capabilities);
    final keyframeActions = _keyframeDockActions(
      editorState,
      selectedClip,
      capabilities,
    );
    final textActions = _textDockActions(selectedClip, capabilities);
    final timelineActions = _timelineDockActions(
      editorState,
      selectedClip,
      capabilities,
    );

    return switch (subgroup) {
      _BottomActionSubgroup.editTiming =>
        clipActions
            .where(
              (action) =>
                  action.group == 'Timing' &&
                  (action.label == 'Timing' ||
                      action.label == 'Freeze' ||
                      action.label == 'Unfreeze'),
            )
            .toList(),
      _BottomActionSubgroup.editTransform =>
        clipActions
            .where(
              (action) =>
                  action.group == 'Transform' &&
                  (action.label == 'Inspector' || action.label == 'Crop'),
            )
            .toList(),
      _BottomActionSubgroup.editDetails =>
        clipActions
            .where(
              (action) =>
                  action.group == 'Attributes' ||
                  action.group == 'Precision' ||
                  (!capabilities.canVisualEffects &&
                      action.group == 'Arrange' &&
                      (action.label == 'Enable' || action.label == 'Disable')),
            )
            .toList(),
      _BottomActionSubgroup.effectsStack =>
        effectActions.where((action) => action.group == 'Stack').toList(),
      _BottomActionSubgroup.effectsColor =>
        effectActions
            .where(
              (action) =>
                  (action.group == 'Keying' || action.group == 'Color') &&
                  action.label != 'Remove',
            )
            .toList(),
      _BottomActionSubgroup.effectsLuts =>
        effectActions.where((action) => action.group == 'LUTs').toList(),
      _BottomActionSubgroup.effectsBlur =>
        effectActions
            .where(
              (action) => action.group == 'Blur' && action.label != 'Remove',
            )
            .toList(),
      _BottomActionSubgroup.effectsMotion =>
        effectActions.where((action) => action.group == 'Motion').toList(),
      _BottomActionSubgroup.effectsKeyframes =>
        effectActions.where((action) => action.group == 'Keyframes').toList(),
      _BottomActionSubgroup.effectsEnhance =>
        effectActions
            .where(
              (action) =>
                  action.group == 'Enhance' &&
                  (action.label == 'Stabilize' ||
                      action.label == 'Stabilized' ||
                      action.label == 'Denoise' ||
                      action.label == 'Denoised'),
            )
            .toList(),
      _BottomActionSubgroup.keyframeControls =>
        keyframeActions.where((action) => action.group == 'States').toList(),
      _BottomActionSubgroup.keyframeCurves =>
        keyframeActions.where((action) => action.group == 'Curves').toList(),
      _BottomActionSubgroup.keyframeProperties =>
        keyframeActions.where((action) => action.group == 'Advanced').toList(),
      _BottomActionSubgroup.audioMix =>
        audioActions
            .where((action) => action.group == 'Mix' && action.label == 'Mixer')
            .toList(),
      _BottomActionSubgroup.audioEffects =>
        audioActions.where((action) => action.group == 'Effects').toList(),
      _BottomActionSubgroup.audioCleanup =>
        audioActions
            .where(
              (action) =>
                  action.group == 'Enhance' &&
                  ((action.label == 'Denoise' || action.label == 'Denoised') ||
                      action.label == 'Auto Duck' ||
                      action.label == 'Ducking On'),
            )
            .toList(),
      _BottomActionSubgroup.audioAutomation =>
        audioActions.where((action) => action.group == 'Automation').toList(),
      _BottomActionSubgroup.textObjects =>
        textActions.where((action) => action.label == 'Edit Text').toList(),
      _BottomActionSubgroup.textCaptions =>
        textActions.where((action) => action.group == 'Captions').toList(),
      _BottomActionSubgroup.textFiles =>
        textActions.where((action) => action.group == 'Caption Files').toList(),
      _BottomActionSubgroup.timelineSelection =>
        timelineActions.where((action) => action.group == 'Selection').toList(),
      _BottomActionSubgroup.timelineTracks =>
        timelineActions
            .where(
              (action) =>
                  action.group == 'Tracks' &&
                  action.label != 'Move Up' &&
                  action.label != 'Move Down',
            )
            .toList(),
      _BottomActionSubgroup.timelineMarkers =>
        timelineActions.where((action) => action.group == 'Markers').toList(),
      _BottomActionSubgroup.timelineProject =>
        timelineActions
            .where(
              (action) =>
                  action.group == 'Workspace' &&
                  (action.label == 'Frame Rate' ||
                      action.label == 'Timecode' ||
                      action.label == 'Labels' ||
                      action.label == 'Preview' ||
                      action.label == 'Proxies'),
            )
            .toList(),
    };
  }

  List<_ActionSpec> _keyframeDockActions(
    EditorState editorState,
    TimelineClip? clip,
    _SelectionCapabilities capabilities,
  ) {
    final timeline = editorState.timeline;
    final canAnimate =
        capabilities.canEdit && _clipCanUseStateKeyframes(timeline, clip);
    final time = clip == null ? null : _snappedKeyframeTimeAtPlayhead(clip);
    final hasCurrent =
        clip != null && time != null && clip.hasKeyframeStateAt(time);
    final relativeUs = clip == null
        ? 0
        : (ref.read(playbackProvider).position - clip.startTime).inMicroseconds;
    final hasPrevious =
        clip?.keyframeStateTimes.any(
          (candidate) => candidate.inMicroseconds < relativeUs,
        ) ??
        false;
    final hasNext =
        clip?.keyframeStateTimes.any(
          (candidate) => candidate.inMicroseconds > relativeUs,
        ) ??
        false;
    final hasAudio = clip != null && timeline.clipHasAudio(clip);
    final canTransformKeyframes =
        capabilities.canEdit && clip?.supportsTransformKeyframes == true;
    final graphProperties = clip == null
        ? const <TimelineKeyframeProperty>[]
        : _graphPropertiesForClip(timeline, clip);
    final initialGraphProperty = graphProperties.firstOrNull;

    return [
      _ActionSpec(
        group: 'States',
        label: hasCurrent ? 'Update State' : 'Add State',
        tooltip:
            'Capture position, scale, rotation, opacity and supported effect/audio values together',
        icon: hasCurrent ? Icons.diamond_rounded : Icons.add_rounded,
        active: hasCurrent,
        onTap: canAnimate ? () => _addSelectedKeyframeState() : null,
      ),
      _ActionSpec(
        group: 'States',
        label: 'Delete',
        tooltip: 'Delete the complete keyframe state at the playhead',
        icon: Icons.delete_outline_rounded,
        onTap: capabilities.canEdit && hasCurrent
            ? _deleteSelectedKeyframeState
            : null,
      ),
      _ActionSpec(
        group: 'States',
        label: 'Previous',
        tooltip: 'Move the playhead to the previous keyframe state',
        icon: Icons.skip_previous_rounded,
        onTap: hasPrevious ? () => _seekSelectedKeyframe(previous: true) : null,
      ),
      _ActionSpec(
        group: 'States',
        label: 'Next',
        tooltip: 'Move the playhead to the next keyframe state',
        icon: Icons.skip_next_rounded,
        onTap: hasNext ? () => _seekSelectedKeyframe(previous: false) : null,
      ),
      _ActionSpec(
        group: 'Curves',
        label: 'Graph',
        tooltip: 'Open the property graph with editable Bézier handles',
        icon: Icons.multiline_chart_rounded,
        active: clip?.hasKeyframes == true,
        onTap:
            capabilities.canEdit && clip != null && initialGraphProperty != null
            ? () => _openKeyframeGraphEditor(
                clip,
                initialProperty: initialGraphProperty,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Curves',
        label: 'Presets',
        tooltip: 'Choose the outgoing curve for every channel in this state',
        icon: Icons.ssid_chart_rounded,
        onTap: capabilities.canEdit && clip != null && hasCurrent
            ? () => _openStateCurvePicker(clip)
            : null,
      ),
      _ActionSpec(
        group: 'Curves',
        label: 'Clear All',
        tooltip: 'Remove all animation keyframes from the selected clip',
        icon: Icons.delete_sweep_rounded,
        onTap: capabilities.canEdit && clip?.hasKeyframes == true
            ? () => ref.read(editorProvider.notifier).removeKeyframes(clip!.id)
            : null,
      ),
      _ActionSpec(
        group: 'Advanced',
        label: 'Opacity',
        tooltip: 'Edit only the opacity channel at the playhead',
        icon: Icons.opacity_rounded,
        onTap: canTransformKeyframes
            ? () => _addSelectedKeyframe(
                TimelineKeyframeProperty.opacity,
                targetClip: clip,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Advanced',
        label: 'Scale',
        tooltip: 'Edit only the scale channel at the playhead',
        icon: Icons.zoom_in_rounded,
        onTap: canTransformKeyframes
            ? () => _addSelectedKeyframe(
                TimelineKeyframeProperty.scale,
                targetClip: clip,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Advanced',
        label: 'Position X',
        tooltip: 'Edit only horizontal position at the playhead',
        icon: Icons.swap_horiz_rounded,
        onTap: canTransformKeyframes
            ? () => _addSelectedKeyframe(
                TimelineKeyframeProperty.positionX,
                targetClip: clip,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Advanced',
        label: 'Position Y',
        tooltip: 'Edit only vertical position at the playhead',
        icon: Icons.swap_vert_rounded,
        onTap: canTransformKeyframes
            ? () => _addSelectedKeyframe(
                TimelineKeyframeProperty.positionY,
                targetClip: clip,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Advanced',
        label: 'Rotation',
        tooltip: 'Edit only rotation at the playhead',
        icon: Icons.rotate_right_rounded,
        onTap: canTransformKeyframes
            ? () => _addSelectedKeyframe(
                TimelineKeyframeProperty.rotation,
                targetClip: clip,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Advanced',
        label: 'Volume',
        tooltip: 'Edit only volume at the playhead',
        icon: Icons.volume_up_rounded,
        onTap: hasAudio
            ? () => _addSelectedKeyframe(
                TimelineKeyframeProperty.volume,
                targetClip: clip,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Advanced',
        label: 'Blur',
        tooltip: 'Edit only blur strength at the playhead',
        icon: Icons.blur_on_rounded,
        onTap: clip?.blur.isEnabled == true
            ? () => _addSelectedKeyframe(
                TimelineKeyframeProperty.blurStrength,
                targetClip: clip,
              )
            : null,
      ),
    ];
  }

  List<_ActionSpec> _clipDockActions(
    TimelineClip? clip,
    _SelectionCapabilities capabilities,
  ) {
    final editable = clip != null && capabilities.canEdit;
    final visual = clip != null && capabilities.canVisualEffects;
    return [
      _ActionSpec(
        group: 'Timing',
        label: 'Timing',
        tooltip: 'Trim source, change speed and reverse',
        icon: Icons.av_timer_rounded,
        onTap: editable && clip.supportsSourceTiming
            ? () => _openTimingSheet(clip)
            : null,
      ),
      _ActionSpec(
        group: 'Timing',
        label: 'Split',
        tooltip: 'Split the selected clip at the playhead',
        icon: Icons.content_cut_rounded,
        onTap: editable ? () => _splitClipAtPlayhead(clip) : null,
      ),
      _ActionSpec(
        group: 'Timing',
        label: clip?.isReversed == true ? 'Forward' : 'Reverse',
        tooltip: 'Reverse the selected media',
        icon: Icons.replay_rounded,
        active: clip?.isReversed == true,
        onTap: editable && clip.supportsReversePlayback
            ? () => _toggleClipReverse(clip)
            : null,
      ),
      _ActionSpec(
        group: 'Timing',
        label: clip?.freezeFrame == true ? 'Unfreeze' : 'Freeze',
        tooltip: 'Hold the selected video or GIF frame',
        icon: Icons.pause_circle_outline_rounded,
        active: clip?.freezeFrame == true,
        onTap: editable ? _toggleSelectedFreezeFrame : null,
      ),
      _ActionSpec(
        group: 'Transform',
        label: 'Inspector',
        tooltip: 'Position, scale, rotation, opacity and layer',
        icon: Icons.tune_rounded,
        onTap: visual ? () => _openClipInspectorSheet(clip) : null,
      ),
      _ActionSpec(
        group: 'Transform',
        label: 'Crop',
        tooltip: 'Crop with presets or free insets',
        icon: Icons.crop_rounded,
        onTap: visual ? () => _openCropSheet(clip) : null,
      ),
      _ActionSpec(
        group: 'Transform',
        label: 'Fill',
        tooltip: 'Fill the canvas',
        icon: Icons.fullscreen_rounded,
        active: clip?.fitMode == ClipFitMode.cover,
        onTap: visual ? () => _setClipFit(clip, ClipFitMode.cover) : null,
      ),
      _ActionSpec(
        group: 'Transform',
        label: 'Fit',
        tooltip: 'Fit inside the canvas',
        icon: Icons.fit_screen_rounded,
        active: clip?.fitMode == ClipFitMode.contain,
        onTap: visual ? () => _setClipFit(clip, ClipFitMode.contain) : null,
      ),
      _ActionSpec(
        group: 'Transform',
        label: 'Stretch',
        tooltip: 'Stretch to the canvas',
        icon: Icons.open_in_full_rounded,
        active: clip?.fitMode == ClipFitMode.stretch,
        onTap: visual ? () => _setClipFit(clip, ClipFitMode.stretch) : null,
      ),
      _ActionSpec(
        group: 'Transform',
        label: 'Rotate L',
        tooltip: 'Rotate left 90 degrees',
        icon: Icons.rotate_left_rounded,
        onTap: visual ? () => _rotateClip(clip, -math.pi / 2) : null,
      ),
      _ActionSpec(
        group: 'Transform',
        label: 'Rotate R',
        tooltip: 'Rotate right 90 degrees',
        icon: Icons.rotate_right_rounded,
        onTap: visual ? () => _rotateClip(clip, math.pi / 2) : null,
      ),
      _ActionSpec(
        group: 'Transform',
        label: 'Mirror',
        tooltip: 'Mirror horizontally',
        icon: Icons.flip_rounded,
        active: clip?.transform.flipX == true,
        onTap: visual ? () => _toggleClipFlip(clip, horizontal: true) : null,
      ),
      _ActionSpec(
        group: 'Transform',
        label: 'Flip V',
        tooltip: 'Flip vertically',
        icon: Icons.flip_camera_android_rounded,
        active: clip?.transform.flipY == true,
        onTap: visual ? () => _toggleClipFlip(clip, horizontal: false) : null,
      ),
      _ActionSpec(
        group: 'Transform',
        label: 'Reset',
        tooltip: 'Reset transform and crop',
        icon: Icons.restart_alt_rounded,
        onTap: visual ? () => _resetClipTransform(clip) : null,
      ),
      _ActionSpec(
        group: 'Arrange',
        label: 'Forward',
        tooltip: 'Bring the overlay forward one layer',
        icon: Icons.move_up_rounded,
        onTap: clip != null && capabilities.canChangeLayer
            ? () => _changeClipLayer(clip, 1)
            : null,
      ),
      _ActionSpec(
        group: 'Arrange',
        label: 'Backward',
        tooltip: 'Send the overlay backward one layer',
        icon: Icons.move_down_rounded,
        onTap: clip != null && capabilities.canChangeLayer
            ? () => _changeClipLayer(clip, -1)
            : null,
      ),
      _ActionSpec(
        group: 'Arrange',
        label: 'Duplicate',
        tooltip: 'Duplicate the selected clip',
        icon: Icons.content_copy_rounded,
        onTap: editable && capabilities.canArrange
            ? () => _duplicateClip(clip)
            : null,
      ),
      _ActionSpec(
        group: 'Arrange',
        label: clip?.enabled == false ? 'Enable' : 'Disable',
        tooltip: 'Toggle clip visibility in preview and export',
        icon: clip?.enabled == false
            ? Icons.visibility_rounded
            : Icons.visibility_off_rounded,
        active: clip?.enabled == false,
        onTap: editable && capabilities.canArrange
            ? () => _toggleClipEnabled(clip)
            : null,
      ),
      _ActionSpec(
        group: 'Arrange',
        label: 'Delete',
        tooltip: 'Delete the selected clip',
        icon: Icons.delete_outline_rounded,
        onTap: editable ? () => _deleteClip(clip) : null,
      ),
      _ActionSpec(
        group: 'Attributes',
        label: 'Copy attrs',
        tooltip: 'Copy timing, visual and audio attributes',
        icon: Icons.copy_all_rounded,
        active: clip != null && _clipAttributeClipboard?.id == clip.id,
        onTap: editable ? _copyClipAttributes : null,
      ),
      _ActionSpec(
        group: 'Attributes',
        label: 'Paste attrs',
        tooltip: 'Paste copied attributes to the selection',
        icon: Icons.content_paste_go_rounded,
        active: _clipAttributeClipboard != null,
        onTap: editable && _clipAttributeClipboard != null
            ? _pasteClipAttributes
            : null,
      ),
      _ActionSpec(
        group: 'Attributes',
        label: 'Note',
        tooltip: 'Attach an edit note to the clip',
        icon: Icons.sticky_note_2_outlined,
        active: clip?.notes?.trim().isNotEmpty == true,
        onTap: editable ? _setSelectedClipNote : null,
      ),
      _ActionSpec(
        group: 'Attributes',
        label: 'Color',
        tooltip: 'Cycle the timeline clip color',
        icon: Icons.palette_outlined,
        onTap: editable ? _cycleSelectedClipColor : null,
      ),
      _ActionSpec(
        group: 'Precision',
        label: 'Frame −',
        tooltip: 'Nudge selection one frame left',
        icon: Icons.keyboard_double_arrow_left_rounded,
        onTap: editable ? () => _nudgeSelectedClips(-1) : null,
      ),
      _ActionSpec(
        group: 'Precision',
        label: 'Frame +',
        tooltip: 'Nudge selection one frame right',
        icon: Icons.keyboard_double_arrow_right_rounded,
        onTap: editable ? () => _nudgeSelectedClips(1) : null,
      ),
    ];
  }

  List<_ActionSpec> _visualDockActions(
    TimelineClip? clip,
    _SelectionCapabilities capabilities,
  ) {
    final visual = clip != null && capabilities.canVisualEffects;
    final filter = clip != null && capabilities.isFilterEffect;
    final blur = clip != null && capabilities.isBlurEffect;
    final hasLut = clip?.colorAdjustments.lutPath?.trim().isNotEmpty == true;
    final canKey =
        clip != null && capabilities.canEdit && clip.supportsChromaKey;
    return [
      _ActionSpec(
        group: 'Stack',
        label: 'Effect Stack',
        tooltip: 'Add, reorder, mask, disable and animate visual effects',
        icon: Icons.auto_awesome_rounded,
        active:
            clip?.effectStack.effects.any(
              (effect) => effect.domain == EditorEffectDomain.visual,
            ) ==
            true,
        onTap: () =>
            _openEffectStackSheet(clip, domain: EditorEffectDomain.visual),
      ),
      _ActionSpec(
        group: 'Stack',
        label: 'Adjustment',
        tooltip: 'Create a timed adjustment layer above the composition',
        icon: Icons.layers_rounded,
        onTap: _createAdjustmentLayerAtPlayhead,
      ),
      _ActionSpec(
        group: 'Keying',
        label: 'Chroma Key',
        tooltip: 'Remove a screen color from an image or video layer',
        icon: Icons.colorize_rounded,
        active: clip?.chromaKeyEnabled == true,
        onTap: canKey ? _openSelectedChromaKeySheet : null,
      ),
      _ActionSpec(
        group: 'Color',
        label: 'Filters',
        tooltip: 'Add or change a filter overlay',
        icon: Icons.tonality_rounded,
        active: filter,
        onTap: () => _openFilterSheet(visual || filter ? clip : null),
      ),
      _ActionSpec(
        group: 'Color',
        label: 'Adjust',
        tooltip: 'Brightness, contrast, saturation and temperature',
        icon: Icons.tune_rounded,
        active: clip?.colorAdjustments.isNeutral == false,
        onTap: visual || filter ? () => _openColorAdjustmentsSheet(clip) : null,
      ),
      _ActionSpec(
        group: 'LUTs',
        label: 'Library',
        tooltip: 'Browse the verified offline LUT pack',
        icon: Icons.grid_view_rounded,
        active: hasLut,
        onTap: visual || filter ? () => _openLutLibrarySheet(clip) : null,
      ),
      _ActionSpec(
        group: 'LUTs',
        label: 'Import',
        tooltip: 'Import a custom CUBE or 3DL file',
        icon: Icons.file_open_outlined,
        onTap: visual || filter ? () => _importLutForSelection(clip) : null,
      ),
      _ActionSpec(
        group: 'LUTs',
        label: 'Strength',
        tooltip: 'Adjust LUT intensity and color controls',
        icon: Icons.tune_rounded,
        onTap: (visual || filter) && hasLut
            ? () => _openColorAdjustmentsSheet(clip)
            : null,
      ),
      _ActionSpec(
        group: 'LUTs',
        label: 'Clear',
        tooltip: 'Remove the LUT from the selected visual clips',
        icon: Icons.layers_clear_outlined,
        onTap: (visual || filter) && hasLut
            ? () => _clearLutFromSelection(clip)
            : null,
      ),
      _ActionSpec(
        group: 'Color',
        label: 'Remove',
        tooltip: 'Remove the selected filter overlay',
        icon: Icons.layers_clear_rounded,
        onTap: filter ? () => _deleteClip(clip) : null,
      ),
      _ActionSpec(
        group: 'Blur',
        label: 'Whole',
        tooltip: 'Add whole-frame blur as an overlay',
        icon: Icons.blur_circular_rounded,
        active: blur && clip.blur.mode == ClipBlurMode.full,
        onTap: blur
            ? () {
                _setBlurMode(clip, ClipBlurMode.full);
                unawaited(_openBlurSheet(clip));
              }
            : () => _addEffectOverlay(
                anchor: visual ? clip : null,
                kind: TimelineEffectKind.blur,
                label: 'Whole blur',
                blur: const ClipBlurSettings(
                  mode: ClipBlurMode.full,
                  strength: 12,
                ),
              ),
      ),
      _ActionSpec(
        group: 'Blur',
        label: 'Region',
        tooltip: 'Add a movable privacy blur region',
        icon: Icons.center_focus_strong_rounded,
        active: blur && clip.blur.mode == ClipBlurMode.region,
        onTap: blur
            ? () {
                _setBlurMode(clip, ClipBlurMode.region);
                unawaited(_openBlurSheet(clip));
              }
            : () => _addEffectOverlay(
                anchor: visual ? clip : null,
                kind: TimelineEffectKind.blur,
                label: 'Region blur',
                blur: const ClipBlurSettings(
                  mode: ClipBlurMode.region,
                  strength: 12,
                ),
              ),
      ),
      _ActionSpec(
        group: 'Blur',
        label: 'Settings',
        tooltip: 'Adjust blur mode, strength and region',
        icon: Icons.tune_rounded,
        onTap: blur ? () => _openBlurSheet(clip) : null,
      ),
      _ActionSpec(
        group: 'Blur',
        label: 'Remove',
        tooltip: 'Remove the selected blur overlay',
        icon: Icons.layers_clear_rounded,
        onTap: blur ? () => _deleteClip(clip) : null,
      ),
      _ActionSpec(
        group: 'Motion',
        label: 'Animate',
        tooltip: 'Apply clip entrance and exit animation',
        icon: Icons.auto_awesome_motion_rounded,
        onTap: clip != null && capabilities.canAnimate
            ? () => _openClipAnimationSheetForSelection(clip)
            : null,
      ),
      _ActionSpec(
        group: 'Motion',
        label: 'Transition',
        tooltip: 'Edit the source-clip transition',
        icon: Icons.join_inner_rounded,
        onTap: clip != null && capabilities.canTransition
            ? () => _openTransitionSheet(clip)
            : null,
      ),
      _ActionSpec(
        group: 'Keyframes',
        label: 'Graph',
        tooltip: 'Edit animation curves, timing, and Bézier handles',
        icon: Icons.show_chart_rounded,
        active: clip?.hasKeyframes == true,
        onTap: visual || blur
            ? () => _openKeyframeGraphEditor(
                clip,
                initialProperty: blur
                    ? TimelineKeyframeProperty.blurStrength
                    : TimelineKeyframeProperty.opacity,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Keyframes',
        label: 'Opacity',
        tooltip: 'Add an opacity keyframe at the playhead',
        icon: Icons.opacity_rounded,
        onTap: visual
            ? () => _addSelectedKeyframe(TimelineKeyframeProperty.opacity)
            : null,
      ),
      _ActionSpec(
        group: 'Keyframes',
        label: 'Scale',
        tooltip: 'Add a scale keyframe at the playhead',
        icon: Icons.zoom_in_rounded,
        onTap: visual
            ? () => _addSelectedKeyframe(TimelineKeyframeProperty.scale)
            : null,
      ),
      _ActionSpec(
        group: 'Keyframes',
        label: 'Move X',
        tooltip: 'Add a horizontal-position keyframe',
        icon: Icons.open_with_rounded,
        onTap: visual
            ? () => _addSelectedKeyframe(TimelineKeyframeProperty.positionX)
            : null,
      ),
      _ActionSpec(
        group: 'Keyframes',
        label: 'Move Y',
        tooltip: 'Add a vertical-position keyframe',
        icon: Icons.height_rounded,
        onTap: visual
            ? () => _addSelectedKeyframe(TimelineKeyframeProperty.positionY)
            : null,
      ),
      _ActionSpec(
        group: 'Keyframes',
        label: 'Rotation',
        tooltip: 'Add a rotation keyframe',
        icon: Icons.rotate_right_rounded,
        onTap: visual
            ? () => _addSelectedKeyframe(TimelineKeyframeProperty.rotation)
            : null,
      ),
      _ActionSpec(
        group: 'Keyframes',
        label: 'Blur',
        tooltip: 'Add a blur-strength keyframe',
        icon: Icons.blur_on_rounded,
        onTap: blur
            ? () => _addSelectedKeyframe(TimelineKeyframeProperty.blurStrength)
            : null,
      ),
      _ActionSpec(
        group: 'Keyframes',
        label: 'Clear visual',
        tooltip: 'Clear visual keyframes from the selected clip',
        icon: Icons.delete_sweep_rounded,
        onTap:
            clip?.keyframes.any(
                  (keyframe) =>
                      keyframe.property != TimelineKeyframeProperty.volume,
                ) ==
                true
            ? () => _clearSelectedKeyframes(const {
                TimelineKeyframeProperty.opacity,
                TimelineKeyframeProperty.scale,
                TimelineKeyframeProperty.rotation,
                TimelineKeyframeProperty.positionX,
                TimelineKeyframeProperty.positionY,
                TimelineKeyframeProperty.blurStrength,
              })
            : null,
      ),
      _ActionSpec(
        group: 'Enhance',
        label: clip?.stabilize == true ? 'Stabilized' : 'Stabilize',
        tooltip: 'Stabilize video during final rendering',
        icon: Icons.vibration_rounded,
        active: clip?.stabilize == true,
        onTap: visual && clip.type == TimelineTrackType.video
            ? () => _toggleSelectedClipFlag(
                (current) => current.copyWith(stabilize: !current.stabilize),
                supports: (candidate, _) =>
                    candidate.type == TimelineTrackType.video,
                unsupportedMessage: 'Stabilization requires a video clip.',
              )
            : null,
      ),
      _ActionSpec(
        group: 'Enhance',
        label: clip?.denoise == true ? 'Denoised' : 'Denoise',
        tooltip: 'Reduce visual noise during final rendering',
        icon: Icons.noise_aware_rounded,
        active: clip?.denoise == true,
        onTap: visual
            ? () => _toggleSelectedClipFlag(
                (current) => current.copyWith(denoise: !current.denoise),
                supports: (candidate, _) =>
                    candidate.type == TimelineTrackType.video,
                unsupportedMessage: 'Visual denoise requires a video clip.',
              )
            : null,
      ),
    ];
  }

  List<_ActionSpec> _audioDockActions(
    TimelineClip? clip,
    _SelectionCapabilities capabilities,
  ) {
    final timeline = ref.read(editorProvider).timeline;
    final owner = clip == null ? null : _audioOwnerForClip(timeline, clip);
    final audioClip = owner?.clip;
    final audio =
        audioClip != null &&
        owner != null &&
        !owner.track.isLocked &&
        timeline.clipHasAudio(audioClip) &&
        (audioClip.id != clip?.id || capabilities.canAdjustAudio);
    return [
      _ActionSpec(
        group: 'Mix',
        label: 'Mixer',
        tooltip: 'Volume, pan, fades and normalization',
        icon: Icons.tune_rounded,
        onTap: audio ? () => _openAudioControlsSheet(audioClip) : null,
      ),
      _ActionSpec(
        group: 'Effects',
        label: 'Audio FX',
        tooltip: 'Build a non-destructive audio processing chain',
        icon: Icons.multitrack_audio_rounded,
        active:
            audioClip?.effectStack.effects.any(
              (effect) => effect.domain == EditorEffectDomain.audio,
            ) ==
            true,
        onTap: audio
            ? () => _openEffectStackSheet(
                audioClip,
                domain: EditorEffectDomain.audio,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Mix',
        label: audioClip?.audioMix.muted == true ? 'Unmute' : 'Mute',
        tooltip: 'Toggle selected clip audio',
        icon: audioClip?.audioMix.muted == true
            ? Icons.volume_up_rounded
            : Icons.volume_off_rounded,
        active: audioClip?.audioMix.muted == true,
        onTap: audio ? () => _toggleClipMute(audioClip) : null,
      ),
      _ActionSpec(
        group: 'Fades',
        label: 'Fade In',
        tooltip: 'Toggle a 500ms fade in',
        icon: Icons.trending_up_rounded,
        active: (audioClip?.audioMix.fadeInMs ?? 0) > 0,
        onTap: audio ? () => _toggleQuickFade(audioClip, fadeIn: true) : null,
      ),
      _ActionSpec(
        group: 'Fades',
        label: 'Fade Out',
        tooltip: 'Toggle a 500ms fade out',
        icon: Icons.trending_down_rounded,
        active: (audioClip?.audioMix.fadeOutMs ?? 0) > 0,
        onTap: audio ? () => _toggleQuickFade(audioClip, fadeIn: false) : null,
      ),
      _ActionSpec(
        group: 'Fades',
        label: 'Clear',
        tooltip: 'Clear both audio fades',
        icon: Icons.restart_alt_rounded,
        onTap: audio
            ? () => _updateSelectedClipAudioMix(
                audioClip,
                fadeInMs: 0,
                fadeOutMs: 0,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Enhance',
        label: audioClip?.audioMix.normalize == true
            ? 'Raw Level'
            : 'Normalize',
        tooltip: 'Toggle loudness normalization',
        icon: Icons.hearing_rounded,
        active: audioClip?.audioMix.normalize == true,
        onTap: audio ? () => _toggleClipNormalize(audioClip) : null,
      ),
      _ActionSpec(
        group: 'Enhance',
        label: 'Center Pan',
        tooltip: 'Center the stereo pan',
        icon: Icons.swap_horiz_rounded,
        onTap: audio
            ? () => _updateSelectedClipAudioMix(audioClip, pan: 0)
            : null,
      ),
      _ActionSpec(
        group: 'Enhance',
        label: audioClip?.denoise == true ? 'Denoised' : 'Denoise',
        tooltip: 'Reduce audio noise during export',
        icon: Icons.noise_aware_rounded,
        active: audioClip?.denoise == true,
        onTap: audio
            ? () => _updateTimelineClip(
                audioClip,
                (current) => current.copyWith(denoise: !current.denoise),
              )
            : null,
      ),
      _ActionSpec(
        group: 'Enhance',
        label: audioClip?.autoDuck == true ? 'Ducking On' : 'Auto Duck',
        tooltip: 'Lower this clip beneath captions and voice',
        icon: Icons.record_voice_over_rounded,
        active: audioClip?.autoDuck == true,
        onTap: audio
            ? () => _updateTimelineClip(
                audioClip,
                (current) => current.copyWith(autoDuck: !current.autoDuck),
              )
            : null,
      ),
      _ActionSpec(
        group: 'Enhance',
        label: 'Reset Mix',
        tooltip: 'Reset volume, pan, fades and normalization',
        icon: Icons.restart_alt_rounded,
        onTap: audio
            ? () => _updateSelectedClipAudioMix(
                audioClip,
                muted: false,
                volume: 1,
                fadeInMs: 0,
                fadeOutMs: 0,
                fadeInShape: AudioFadeShape.linear,
                fadeOutShape: AudioFadeShape.linear,
                pan: 0,
                normalize: false,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Automation',
        label: 'Graph',
        tooltip: 'Edit volume automation curves and timing',
        icon: Icons.multiline_chart_rounded,
        active:
            audioClip?.keyframes.any(
              (frame) => frame.property == TimelineKeyframeProperty.volume,
            ) ==
            true,
        onTap: audio
            ? () => _openKeyframeGraphEditor(
                audioClip,
                initialProperty: TimelineKeyframeProperty.volume,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Automation',
        label: 'Volume Key',
        tooltip: 'Add a volume keyframe at the playhead',
        icon: Icons.key_rounded,
        onTap: audio
            ? () => _addSelectedKeyframe(
                TimelineKeyframeProperty.volume,
                targetClip: audioClip,
              )
            : null,
      ),
      _ActionSpec(
        group: 'Automation',
        label: 'Clear volume',
        tooltip: 'Clear volume automation from the selected clip',
        icon: Icons.delete_sweep_rounded,
        onTap:
            audioClip?.keyframes.any(
                  (keyframe) =>
                      keyframe.property == TimelineKeyframeProperty.volume,
                ) ==
                true
            ? () => _clearSelectedKeyframes(const {
                TimelineKeyframeProperty.volume,
              }, targetClip: audioClip)
            : null,
      ),
    ];
  }

  List<_ActionSpec> _textDockActions(
    TimelineClip? clip,
    _SelectionCapabilities capabilities,
  ) {
    final textClip = clip?.type == TimelineTrackType.text;
    return [
      _ActionSpec(
        group: 'Create',
        label: 'Add Text',
        tooltip: 'Add and edit a text object on the canvas',
        icon: Icons.title_rounded,
        onTap: _addTextClipAtPlayhead,
      ),
      _ActionSpec(
        group: 'Create',
        label: 'Subtitles',
        tooltip: 'Generate timed subtitles from a video or audio clip',
        icon: Icons.closed_caption_outlined,
        onTap: _handleGenerateSubtitles,
      ),
      _ActionSpec(
        group: 'Create',
        label: 'Edit Text',
        tooltip: 'Edit the selected text object',
        icon: Icons.edit_rounded,
        onTap: textClip && capabilities.canEdit
            ? () => _editTextClip(clip!)
            : null,
      ),
      _ActionSpec(
        group: 'Captions',
        label: 'Style',
        tooltip: 'Typography, placement and subtitle animation',
        icon: Icons.palette_outlined,
        onTap: () => _openStylePanelSheet(context),
      ),
      _ActionSpec(
        group: 'Captions',
        label: 'Workshop',
        tooltip: 'Find, retime, clean and quality-check captions',
        icon: Icons.fact_check_outlined,
        onTap: _openSubtitleToolsSheet,
      ),
      _ActionSpec(
        group: 'Caption Files',
        label: 'Import',
        tooltip: 'Import an SRT or VTT subtitle file',
        icon: Icons.file_upload_rounded,
        onTap: _importSubtitleFile,
      ),
      _ActionSpec(
        group: 'Caption Files',
        label: 'Export SRT',
        tooltip: 'Export subtitles as SRT',
        icon: Icons.subtitles_rounded,
        onTap: () => _exportCaptionSidecar('srt'),
      ),
      _ActionSpec(
        group: 'Caption Files',
        label: 'Export VTT',
        tooltip: 'Export subtitles as VTT',
        icon: Icons.subtitles_outlined,
        onTap: () => _exportCaptionSidecar('vtt'),
      ),
    ];
  }

  List<_ActionSpec> _timelineDockActions(
    EditorState editorState,
    TimelineClip? clip,
    _SelectionCapabilities capabilities,
  ) {
    final timeline = editorState.timeline;
    final workspace = timeline.workspaceSettings;
    final selectedTrack = timeline.tracks
        .where((track) => track.id == editorState.selectedTrackId)
        .firstOrNull;
    final hasTrack = selectedTrack != null;
    final canReorderTrack = selectedTrack?.isReorderable == true;
    final canDuplicateTrack =
        selectedTrack?.isDuplicable == true && !selectedTrack!.isLocked;
    final selectedClips = timeline.tracks
        .expand((track) => track.clips)
        .where(
          (candidate) => editorState.selectedClipIds.contains(candidate.id),
        )
        .toList();
    final selectedGroupId = selectedClips
        .map((candidate) => candidate.groupId)
        .whereType<String>()
        .firstOrNull;
    final selectedCompoundId = selectedClips
        .map((candidate) => candidate.compoundId)
        .whereType<String>()
        .firstOrNull;
    return [
      _ActionSpec(
        group: 'Selection',
        label: 'Select All',
        tooltip: 'Select every clip',
        icon: Icons.select_all_rounded,
        onTap: _selectAllClips,
      ),
      _ActionSpec(
        group: 'Selection',
        label: 'Clear multi',
        tooltip: 'Clear the current multi-selection',
        icon: Icons.deselect_rounded,
        onTap: editorState.selectedClipIds.isNotEmpty
            ? _clearClipMultiSelection
            : null,
      ),
      _ActionSpec(
        group: 'Selection',
        label: 'Split All',
        tooltip: 'Split every clip crossing the playhead',
        icon: Icons.call_split_rounded,
        onTap: _splitEveryTrackAtPlayhead,
      ),
      _ActionSpec(
        group: 'Selection',
        label: selectedGroupId == null ? 'Group' : 'Ungroup',
        tooltip: selectedGroupId == null
            ? 'Link selected clips for shared effects'
            : 'Remove the selected clip group',
        icon: selectedGroupId == null
            ? Icons.group_work_outlined
            : Icons.workspaces_outline,
        onTap: selectedGroupId != null
            ? () => _ungroupSelection(selectedGroupId)
            : selectedClips.length >= 2
            ? _groupSelection
            : null,
      ),
      _ActionSpec(
        group: 'Selection',
        label: selectedCompoundId == null ? 'Compound' : 'Dissolve',
        tooltip: selectedCompoundId == null
            ? 'Link selected visual clips for shared processing'
            : 'Dissolve the selected compound',
        icon: selectedCompoundId == null
            ? Icons.layers_outlined
            : Icons.layers_clear_outlined,
        onTap: selectedCompoundId != null
            ? () => _dissolveCompoundSelection(selectedCompoundId)
            : selectedClips.length >= 2 &&
                  selectedClips.every(
                    (candidate) => candidate.type.isVisualMedia,
                  )
            ? _compoundSelection
            : null,
      ),
      _ActionSpec(
        group: 'Tracks',
        label: 'Rename',
        tooltip: 'Rename the selected track',
        icon: Icons.edit_outlined,
        onTap: hasTrack ? _renameSelectedTrack : null,
      ),
      _ActionSpec(
        group: 'Tracks',
        label: 'Duplicate',
        tooltip: 'Duplicate the selected track and its clips',
        icon: Icons.library_add_outlined,
        onTap: canDuplicateTrack ? _duplicateSelectedTrack : null,
      ),
      _ActionSpec(
        group: 'Tracks',
        label: 'Move Up',
        tooltip: 'Move the selected layer up',
        icon: Icons.arrow_upward_rounded,
        onTap: canReorderTrack ? () => _moveSelectedTrack(-1) : null,
      ),
      _ActionSpec(
        group: 'Tracks',
        label: 'Move Down',
        tooltip: 'Move the selected layer down',
        icon: Icons.arrow_downward_rounded,
        onTap: canReorderTrack ? () => _moveSelectedTrack(1) : null,
      ),
      _ActionSpec(
        group: 'Tracks',
        label: 'Collapse',
        tooltip: 'Collapse every track',
        icon: Icons.unfold_less_rounded,
        onTap: () =>
            ref.read(editorProvider.notifier).setAllTracks(collapsed: true),
      ),
      _ActionSpec(
        group: 'Tracks',
        label: 'Expand',
        tooltip: 'Expand every track',
        icon: Icons.unfold_more_rounded,
        onTap: () =>
            ref.read(editorProvider.notifier).setAllTracks(collapsed: false),
      ),
      _ActionSpec(
        group: 'Tracks',
        label: 'Lock All',
        tooltip: 'Lock every editable track',
        icon: Icons.lock_rounded,
        onTap: () =>
            ref.read(editorProvider.notifier).setAllTracks(locked: true),
      ),
      _ActionSpec(
        group: 'Tracks',
        label: 'Unlock All',
        tooltip: 'Unlock every track',
        icon: Icons.lock_open_rounded,
        onTap: () =>
            ref.read(editorProvider.notifier).setAllTracks(locked: false),
      ),
      _ActionSpec(
        group: 'Tracks',
        label: 'Mute All',
        tooltip: 'Mute all audio-capable tracks',
        icon: Icons.volume_off_rounded,
        onTap: () =>
            ref.read(editorProvider.notifier).setAllTracks(muted: true),
      ),
      _ActionSpec(
        group: 'Tracks',
        label: 'Unmute All',
        tooltip: 'Restore track audio',
        icon: Icons.volume_up_rounded,
        onTap: () =>
            ref.read(editorProvider.notifier).setAllTracks(muted: false),
      ),
      _ActionSpec(
        group: 'Markers',
        label: 'Beats',
        tooltip: 'Generate a half-second beat grid',
        icon: Icons.music_note_rounded,
        onTap: _generateBeatMarkers,
      ),
      _ActionSpec(
        group: 'Markers',
        label: 'Chapter',
        tooltip: 'Add a chapter marker at the playhead',
        icon: Icons.bookmark_add_outlined,
        onTap: _addChapterMarker,
      ),
      _ActionSpec(
        group: 'Markers',
        label: 'Clear',
        tooltip: 'Remove every marker, beat and chapter',
        icon: Icons.clear_all_rounded,
        onTap: timeline.markers.isNotEmpty ? _clearAllMarkers : null,
      ),
      _ActionSpec(
        group: 'Workspace',
        label: 'Frame Rate',
        tooltip: 'Choose timeline frame rate and snapping',
        icon: Icons.tune_rounded,
        onTap: _chooseProjectFrameRate,
      ),
      _ActionSpec(
        group: 'Workspace',
        label: 'Preview',
        tooltip: 'Choose original or proxy preview media',
        icon: Icons.hd_outlined,
        active: workspace.previewMediaQuality != PreviewMediaQuality.original,
        onTap: _choosePreviewMediaQuality,
      ),
      _ActionSpec(
        group: 'Workspace',
        label: 'Proxies',
        tooltip: 'Build bounded source-media editing proxies',
        icon: Icons.video_settings_outlined,
        onTap: _generateProjectProxies,
      ),
      _ActionSpec(
        group: 'Workspace',
        label: 'Timecode',
        tooltip: 'Toggle frame-aware ruler labels',
        icon: Icons.access_time_rounded,
        active: workspace.showTimecode,
        onTap: () => _toggleWorkspace(
          (settings) => settings.copyWith(showTimecode: !settings.showTimecode),
        ),
      ),
      _ActionSpec(
        group: 'Workspace',
        label: 'Labels',
        tooltip: 'Toggle clip labels',
        icon: Icons.text_fields_rounded,
        active: workspace.showClipLabels,
        onTap: () => _toggleWorkspace(
          (settings) =>
              settings.copyWith(showClipLabels: !settings.showClipLabels),
        ),
      ),
      _ActionSpec(
        group: 'Workspace',
        label: 'Thumbnails',
        tooltip: 'Toggle timeline thumbnails',
        icon: Icons.photo_library_outlined,
        active: workspace.showThumbnails,
        onTap: () => _toggleWorkspace(
          (settings) =>
              settings.copyWith(showThumbnails: !settings.showThumbnails),
        ),
      ),
      _ActionSpec(
        group: 'Workspace',
        label: 'Waveforms',
        tooltip: 'Toggle audio waveforms',
        icon: Icons.graphic_eq_rounded,
        active: workspace.showWaveforms,
        onTap: () => _toggleWorkspace(
          (settings) =>
              settings.copyWith(showWaveforms: !settings.showWaveforms),
        ),
      ),
      _ActionSpec(
        group: 'Workspace',
        label: 'Keyframes',
        tooltip: 'Toggle keyframe guides',
        icon: Icons.key_rounded,
        active: workspace.showKeyframes,
        onTap: () => _toggleWorkspace(
          (settings) =>
              settings.copyWith(showKeyframes: !settings.showKeyframes),
        ),
      ),
      _ActionSpec(
        group: 'Workspace',
        label: 'Follow',
        tooltip: 'Keep the playhead centered during playback',
        icon: Icons.follow_the_signs_rounded,
        active: workspace.autoFollowPlayhead,
        onTap: () => _toggleWorkspace(
          (settings) => settings.copyWith(
            autoFollowPlayhead: !settings.autoFollowPlayhead,
          ),
        ),
      ),
    ];
  }

  void _clearClipMultiSelection() {
    final primaryClipId = ref.read(editorProvider).selectedClipId;
    final notifier = ref.read(editorProvider.notifier);
    notifier.clearClipSelection();
    if (primaryClipId != null) notifier.selectClip(primaryClipId);
  }

  void _groupSelection() {
    final ids = ref.read(editorProvider).selectedClipIds;
    final groupId = ref.read(editorProvider.notifier).createGroup(ids);
    if (groupId == null) {
      SnackBarHelper.showError(
        context,
        'Select at least two editable clips to create a group.',
      );
      return;
    }
    SnackBarHelper.showSuccess(context, 'Clip group created');
  }

  void _ungroupSelection(String groupId) {
    final removed = ref.read(editorProvider.notifier).ungroup(groupId);
    if (removed) SnackBarHelper.showSuccess(context, 'Clip group removed');
  }

  void _compoundSelection() {
    final ids = ref.read(editorProvider).selectedClipIds;
    final compoundId = ref
        .read(editorProvider.notifier)
        .createCompoundClip(ids);
    if (compoundId == null) {
      SnackBarHelper.showError(
        context,
        'Select at least two editable visual clips.',
      );
      return;
    }
    SnackBarHelper.showSuccess(context, 'Compound selection created');
  }

  void _dissolveCompoundSelection(String compoundId) {
    final removed = ref
        .read(editorProvider.notifier)
        .dissolveCompoundClip(compoundId);
    if (removed) SnackBarHelper.showSuccess(context, 'Compound dissolved');
  }

  Future<void> _exportCaptionSidecar(String format) async {
    if (ref.read(subtitleProvider).entries.isEmpty) {
      SnackBarHelper.showInfo(context, 'No subtitles to export');
      return;
    }
    await _exportSubtitleFile(format);
  }

  Widget _buildActionScroller({
    required Key key,
    required List<_ActionSpec> actions,
    bool spread = false,
  }) {
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              mainAxisAlignment: spread
                  ? MainAxisAlignment.spaceAround
                  : MainAxisAlignment.start,
              children: [
                for (var index = 0; index < actions.length; index++) ...[
                  _buildQuickActionButton(
                    key: actions[index].key ?? _dockToolKey(actions, index),
                    width: actions[index].width ?? 70,
                    tooltip: actions[index].tooltip,
                    icon: actions[index].icon,
                    label: actions[index].label,
                    active: actions[index].active,
                    onTap: actions[index].onTap,
                  ),
                  if (!spread && index != actions.length - 1)
                    const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  ValueKey<String> _dockToolKey(List<_ActionSpec> actions, int index) {
    final action = actions[index];
    final normalizedLabel = action.label.toLowerCase().replaceAll(' ', '_');
    final duplicateLabel =
        actions.where((candidate) => candidate.label == action.label).length >
        1;
    final qualifier = duplicateLabel
        ? '${action.group.toLowerCase().replaceAll(' ', '_')}_'
        : '';
    final category = _activeBottomCategory?.name ?? 'root';
    final subgroup = _activeBottomSubgroup?.name;
    final path = subgroup == null ? category : '${category}_$subgroup';
    return ValueKey('dock_tool_${path}_$qualifier$normalizedLabel');
  }

  Future<void> _openAudioControlsSheet(TimelineClip clip) async {
    final editorState = ref.read(editorProvider);
    final liveClip = _clipById(clip.id, editorState) ?? clip;
    final owner = _audioOwnerForClip(editorState.timeline, liveClip);
    if (owner == null ||
        owner.track.isLocked ||
        !editorState.timeline.clipHasAudio(owner.clip)) {
      return;
    }
    final audioTarget = owner.clip;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.64,
      ),
      backgroundColor: Colors.transparent,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final editorState = ref.watch(editorProvider);
          final liveClip =
              _clipById(audioTarget.id, editorState) ?? audioTarget;
          return SingleChildScrollView(child: _buildAudioControls(liveClip));
        },
      ),
    );
  }

  Widget _buildQuickActionButton({
    required Key key,
    required double width,
    required String tooltip,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool active = false,
  }) {
    final isEnabled = onTap != null;
    return Tooltip(
      key: key,
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Ink(
          width: width,
          height: 48,
          decoration: BoxDecoration(
            color: active ? kAccent.withValues(alpha: 0.13) : kSurfaceElevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active
                  ? kAccent.withValues(alpha: 0.65)
                  : isEnabled
                  ? kBorder
                  : kBorder.withValues(alpha: 0.45),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: active
                    ? kAccent
                    : isEnabled
                    ? kTextPrimary
                    : kTextPrimary.withValues(alpha: 0.32),
                size: 22,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active
                      ? kAccent
                      : isEnabled
                      ? kTextPrimary
                      : kTextPrimary.withValues(alpha: 0.32),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAudioControls(TimelineClip clip) {
    final isVideoClip = clip.type == TimelineTrackType.video;
    final timeline = ref.read(editorProvider).timeline;
    final audioOwner = _audioOwnerForClip(timeline, clip);
    final audioTrack = audioOwner?.track;
    final asset = timeline.assetForClip(clip);
    final separatedAudio = _separatedAudioForVideo(timeline, clip.id);
    final hasSeparatedAudio = separatedAudio != null;
    final provenance = asset?.metadata['provenance'];
    final rawAttribution =
        asset?.metadata['attribution'] ??
        (provenance is Map ? provenance['attribution'] : null);
    final attribution = rawAttribution is String ? rawAttribution.trim() : null;
    final license = (asset?.metadata['license'] as String?)?.trim();
    final resolvedVolume = clip.volumeAt(ref.read(playbackProvider).position);
    final resolvedVolumeDb = _linearGainToDb(resolvedVolume);
    final hasCustomMix =
        clip.audioMix.hasMixAdjustment ||
        (resolvedVolume - 1).abs() > 0.001 ||
        clip.audioMix.fadeInShape != AudioFadeShape.linear ||
        clip.audioMix.fadeOutShape != AudioFadeShape.linear;
    final maximumFadeMs = math.max(1, clip.duration.inMilliseconds ~/ 2);
    final fadeDivisions = math.max(1, math.min(200, maximumFadeMs ~/ 50));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      decoration: const BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            isVideoClip ? 'Video Clip Audio' : 'Audio Clip Controls',
            style: TextStyle(
              color: kTextPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (attribution != null && attribution.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              key: const ValueKey('audio-clip-attribution'),
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
              decoration: BoxDecoration(
                color: kAccent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kAccent.withValues(alpha: 0.22)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    license == null || license.isEmpty
                        ? 'Sound attribution'
                        : 'Sound attribution • ${license.toUpperCase()}',
                    style: const TextStyle(
                      color: kTextPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  SelectableText(
                    attribution,
                    style: const TextStyle(
                      color: kTextSecondary,
                      fontSize: 10,
                      height: 1.35,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const ValueKey('copy-audio-attribution'),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: attribution),
                        );
                        if (!mounted) return;
                        SnackBarHelper.showSuccess(
                          context,
                          'Sound attribution copied',
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 15),
                      label: const Text('Copy credit'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          if (isVideoClip) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: ValueKey(
                  hasSeparatedAudio
                      ? 'edit-separated-video-audio'
                      : 'separate-video-audio',
                ),
                onPressed: hasSeparatedAudio
                    ? () {
                        ref.read(editorProvider.notifier)
                          ..selectTrack(separatedAudio.track.id)
                          ..selectClip(separatedAudio.clip.id);
                        Navigator.of(context).maybePop();
                      }
                    : () => _separateVideoAudio(clip),
                icon: Icon(
                  hasSeparatedAudio
                      ? Icons.graphic_eq_rounded
                      : Icons.call_split_rounded,
                  size: 18,
                ),
                label: Text(
                  hasSeparatedAudio
                      ? 'Edit separated audio'
                      : 'Separate audio to its own track',
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              hasSeparatedAudio
                  ? 'This video is muted to prevent duplicate playback. Volume, fades, pan, and mute now belong to the linked audio clip.'
                  : 'Video audio stays attached by default. Separate it only when you need independent timeline controls.',
              style: TextStyle(
                color: kTextSecondary,
                fontSize: 10,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (clip.type == TimelineTrackType.audio) ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: ValueKey(
                      clip.linkedClipId == null
                          ? 'relink-separated-audio'
                          : 'unlink-separated-audio',
                    ),
                    onPressed: clip.linkedClipId == null
                        ? () => _relinkSeparatedAudio(clip)
                        : () => _unlinkSeparatedAudio(clip),
                    icon: Icon(
                      clip.linkedClipId == null
                          ? Icons.link_rounded
                          : Icons.link_off_rounded,
                    ),
                    label: Text(
                      clip.linkedClipId == null ? 'Relink video' : 'Unlink',
                    ),
                  ),
                ),
                if (clip.linkedClipId != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('reattach-separated-audio'),
                      onPressed: () => _reattachSeparatedAudio(clip),
                      icon: const Icon(Icons.merge_type_rounded),
                      label: const Text('Reattach'),
                    ),
                  ),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                clip.linkedClipId == null
                    ? 'Relinking restores synchronized transport with the original video.'
                    : 'Unlink to edit transport independently, or reattach the processed audio to the video clip.',
                style: const TextStyle(color: kTextSecondary, fontSize: 9),
              ),
            ),
          ],
          if (!isVideoClip || !hasSeparatedAudio) ...[
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _updateSelectedClipAudioMix(
                    clip,
                    muted: !clip.audioMix.muted,
                  ),
                  icon: Icon(
                    clip.audioMix.muted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    size: 16,
                  ),
                  label: Text(clip.audioMix.muted ? 'Unmute' : 'Mute'),
                ),
                const SizedBox(width: 8),
                Text(
                  clip.audioMix.muted
                      ? 'Muted'
                      : '${resolvedVolumeDb.toStringAsFixed(1)} dB',
                  style: TextStyle(color: kTextSecondary, fontSize: 12),
                ),
                const Spacer(),
                IconButton(
                  key: const ValueKey('audio_volume_db_entry'),
                  tooltip: 'Enter an exact dB value',
                  onPressed: () => _editClipVolumeDb(clip, resolvedVolumeDb),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
              ],
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kAccent,
                inactiveTrackColor: kBorder,
                thumbColor: kAccent,
                overlayColor: kAccent.withValues(alpha: 0.14),
              ),
              child: Slider(
                value: resolvedVolumeDb,
                min: -60,
                max: 6,
                divisions: 132,
                label: '${resolvedVolumeDb.toStringAsFixed(1)} dB',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) => _updateSelectedClipAudioMix(
                  clip,
                  volume: _dbToLinearGain(value),
                  muted: value <= -60,
                ),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
            ),
            Text(
              'Stereo Pan',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            Slider(
              value: clip.audioMix.pan.clamp(-1.0, 1.0),
              min: -1,
              max: 1,
              divisions: 20,
              label: clip.audioMix.pan.abs() < 0.05
                  ? 'Center'
                  : clip.audioMix.pan < 0
                  ? 'L ${(clip.audioMix.pan.abs() * 100).round()}'
                  : 'R ${(clip.audioMix.pan * 100).round()}',
              onChangeStart: (_) =>
                  ref.read(editorProvider.notifier).beginTimelineGestureEdit(),
              onChanged: (value) =>
                  _updateSelectedClipAudioMix(clip, pan: value),
              onChangeEnd: (_) =>
                  ref.read(editorProvider.notifier).endTimelineGestureEdit(),
            ),
            const Text(
              'Clip pan is applied identically to the rendered preview bus and final export.',
              style: TextStyle(color: kTextSecondary, fontSize: 10),
            ),
            if (audioTrack != null) ...[
              const SizedBox(height: 12),
              Text(
                'Track Gain',
                style: TextStyle(color: kTextSecondary, fontSize: 12),
              ),
              Slider(
                key: const ValueKey('audio_track_gain'),
                value: audioTrack.audioGain.clamp(0.0, 2.0),
                min: 0,
                max: 2,
                divisions: 40,
                label: '${(audioTrack.audioGain * 100).round()}%',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateTrackAudioMix(audioTrack.id, gain: value),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
              Text(
                'Track Pan',
                style: TextStyle(color: kTextSecondary, fontSize: 12),
              ),
              Slider(
                key: const ValueKey('audio_track_pan'),
                value: audioTrack.audioPan.clamp(-1.0, 1.0),
                min: -1,
                max: 1,
                divisions: 40,
                label: audioTrack.audioPan.abs() < 0.025
                    ? 'Center'
                    : audioTrack.audioPan < 0
                    ? 'L ${(audioTrack.audioPan.abs() * 100).round()}'
                    : 'R ${(audioTrack.audioPan * 100).round()}',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateTrackAudioMix(audioTrack.id, pan: value),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
            ],
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Normalize loudness'),
              subtitle: Text(
                'Target ${clip.audioMix.targetLufs.toStringAsFixed(0)} LUFS • '
                '${clip.audioMix.peakLimitDb.toStringAsFixed(1)} dBTP ceiling',
              ),
              value: clip.audioMix.normalize,
              onChanged: (value) =>
                  _updateSelectedClipAudioMix(clip, normalize: value),
            ),
            _buildAdvancedAudioControls(
              clip: clip,
              track: audioTrack,
              timeline: timeline,
            ),
            const SizedBox(height: 6),
            Text(
              'Fade In',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kAccent,
                inactiveTrackColor: kBorder,
                thumbColor: kAccent,
                overlayColor: kAccent.withValues(alpha: 0.14),
              ),
              child: Slider(
                value: clip.audioMix.fadeInMs
                    .toDouble()
                    .clamp(0, maximumFadeMs)
                    .toDouble(),
                min: 0,
                max: maximumFadeMs.toDouble(),
                divisions: fadeDivisions,
                label: '${clip.audioMix.fadeInMs}ms',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateSelectedClipAudioMix(clip, fadeInMs: value.round()),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
            ),
            DropdownButtonFormField<AudioFadeShape>(
              key: const ValueKey('audio_fade_in_shape'),
              initialValue: clip.audioMix.fadeInShape,
              decoration: const InputDecoration(labelText: 'Fade-in curve'),
              items: [
                for (final shape in AudioFadeShape.values)
                  DropdownMenuItem(
                    value: shape,
                    child: Text(_audioFadeShapeLabel(shape)),
                  ),
              ],
              onChanged: (shape) {
                if (shape != null) {
                  _updateSelectedClipAudioMix(clip, fadeInShape: shape);
                }
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Fade Out',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kAccent,
                inactiveTrackColor: kBorder,
                thumbColor: kAccent,
                overlayColor: kAccent.withValues(alpha: 0.14),
              ),
              child: Slider(
                value: clip.audioMix.fadeOutMs
                    .toDouble()
                    .clamp(0, maximumFadeMs)
                    .toDouble(),
                min: 0,
                max: maximumFadeMs.toDouble(),
                divisions: fadeDivisions,
                label: '${clip.audioMix.fadeOutMs}ms',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateSelectedClipAudioMix(clip, fadeOutMs: value.round()),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
            ),
            DropdownButtonFormField<AudioFadeShape>(
              key: const ValueKey('audio_fade_out_shape'),
              initialValue: clip.audioMix.fadeOutShape,
              decoration: const InputDecoration(labelText: 'Fade-out curve'),
              items: [
                for (final shape in AudioFadeShape.values)
                  DropdownMenuItem(
                    value: shape,
                    child: Text(_audioFadeShapeLabel(shape)),
                  ),
              ],
              onChanged: (shape) {
                if (shape != null) {
                  _updateSelectedClipAudioMix(clip, fadeOutShape: shape);
                }
              },
            ),
            const SizedBox(height: 10),
            SwitchListTile.adaptive(
              key: const ValueKey('audio_ducking_enabled'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Automatic ducking'),
              subtitle: const Text(
                'Lower this clip beneath selected dialogue or audio lanes',
              ),
              value: clip.autoDuck,
              onChanged: (enabled) =>
                  _updateSelectedClipDucking(clip, enabled: enabled),
            ),
            if (clip.autoDuck) ...[
              Text(
                'Duck Amount',
                style: TextStyle(color: kTextSecondary, fontSize: 12),
              ),
              Slider(
                key: const ValueKey('audio_duck_amount'),
                value: clip.duckAmount.clamp(0.0, 1.0),
                min: 0,
                max: 1,
                divisions: 20,
                label: '${(clip.duckAmount * 100).round()}%',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateSelectedClipDucking(clip, amount: value),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
              Text(
                'Attack ${clip.duckAttackMs}ms',
                style: TextStyle(color: kTextSecondary, fontSize: 12),
              ),
              Slider(
                key: const ValueKey('audio_duck_attack'),
                value: clip.duckAttackMs.toDouble().clamp(0, 1000),
                min: 0,
                max: 1000,
                divisions: 20,
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateSelectedClipDucking(clip, attackMs: value.round()),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
              Text(
                'Release ${clip.duckReleaseMs}ms',
                style: TextStyle(color: kTextSecondary, fontSize: 12),
              ),
              Slider(
                key: const ValueKey('audio_duck_release'),
                value: clip.duckReleaseMs.toDouble().clamp(0, 2000),
                min: 0,
                max: 2000,
                divisions: 40,
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateSelectedClipDucking(clip, releaseMs: value.round()),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
              OutlinedButton.icon(
                key: const ValueKey('audio_duck_sidechains'),
                onPressed: () => _chooseDuckingSidechains(clip),
                icon: const Icon(Icons.account_tree_outlined),
                label: Text(
                  clip.duckSidechainTrackIds.isEmpty
                      ? 'Sidechain: all eligible lanes'
                      : 'Sidechains: ${clip.duckSidechainTrackIds.length}',
                ),
              ),
            ],
            Text(
              isVideoClip
                  ? 'Attached video audio can be mixed here without creating another timeline lane.'
                  : 'Audio clips now support volume plus simple fade in and fade out.',
              style: TextStyle(
                color: kTextSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: hasCustomMix
                    ? () => _updateSelectedClipAudioMix(
                        clip,
                        muted: false,
                        volume: 1,
                        fadeInMs: 0,
                        fadeOutMs: 0,
                        fadeInShape: AudioFadeShape.linear,
                        fadeOutShape: AudioFadeShape.linear,
                        pan: 0,
                        normalize: false,
                        channelMode: EditorAudioChannelMode.stereo,
                        leftGain: 1,
                        rightGain: 1,
                        targetLufs: -16,
                        peakLimitDb: -1.5,
                        pitchSemitones: 0,
                        timeStretch: 1,
                        preservePitch: true,
                      )
                    : null,
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Reset mix'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAdvancedAudioControls({
    required TimelineClip clip,
    required TimelineTrack? track,
    required EditorTimeline timeline,
  }) {
    final mix = clip.audioMix;
    final asset = timeline.assetForClip(clip);
    final rawAudioStreams = asset?.metadata['audioStreams'];
    final audioStreams = rawAudioStreams is List
        ? rawAudioStreams
              .whereType<Map>()
              .map((value) => Map<String, dynamic>.from(value))
              .toList()
        : <Map<String, dynamic>>[];
    final declaredStreamCount =
        (asset?.metadata['audioStreamCount'] as num?)?.toInt() ??
        audioStreams.length;
    final streamCount = math.max(1, declaredStreamCount);
    final selectedStream = mix.sourceStreamIndex
        .clamp(0, streamCount - 1)
        .toInt();
    final selectedStreamMetadata = selectedStream < audioStreams.length
        ? audioStreams[selectedStream]
        : const <String, dynamic>{};
    final sourceChannelCount = math.max(
      1,
      (selectedStreamMetadata['channels'] as num?)?.toInt() ??
          (asset?.metadata['audioChannels'] as num?)?.toInt() ??
          2,
    );
    final storedMeasurement = mix.loudnessAnalysis;
    String? currentMeasurementFingerprint;
    final measurementSourcePath = asset?.sourcePath?.trim();
    if (storedMeasurement != null &&
        track != null &&
        measurementSourcePath?.isNotEmpty == true) {
      try {
        currentMeasurementFingerprint = AudioMeterService.fingerprintForClip(
          timeline: timeline,
          track: track,
          clip: clip,
          asset: asset,
          sourcePath: measurementSourcePath!,
        );
      } catch (_) {
        currentMeasurementFingerprint = null;
      }
    }
    final measurementIsCurrent =
        storedMeasurement != null &&
        (currentMeasurementFingerprint == null ||
            storedMeasurement.sourceFingerprint ==
                currentMeasurementFingerprint);
    final measured = measurementIsCurrent ? storedMeasurement : null;
    final hasStaleMeasurement =
        storedMeasurement != null && !measurementIsCurrent;
    final isAnalyzing = _analyzingAudioClipId == clip.id;
    final bus = track?.audioBusId == null
        ? null
        : timeline.audioBuses
              .where((candidate) => candidate.id == track!.audioBusId)
              .firstOrNull;

    Widget slider({
      required String label,
      required double value,
      required double minimum,
      required double maximum,
      required int divisions,
      required String Function(double value) format,
      required ValueChanged<double> onChanged,
    }) {
      return Column(
        children: [
          _sheetSliderHeader(label, format(value)),
          Slider(
            value: value.clamp(minimum, maximum).toDouble(),
            min: minimum,
            max: maximum,
            divisions: divisions,
            label: format(value),
            onChangeStart: (_) =>
                ref.read(editorProvider.notifier).beginTimelineGestureEdit(),
            onChanged: onChanged,
            onChangeEnd: (_) =>
                ref.read(editorProvider.notifier).endTimelineGestureEdit(),
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: ExpansionTile(
        key: const ValueKey('advanced_audio_controls'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
        leading: const Icon(Icons.tune_rounded, color: kAccent, size: 20),
        title: const Text(
          'Advanced routing & processing',
          style: TextStyle(
            color: kTextPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: const Text(
          'Channels, LUFS, pitch, stretch and buses',
          style: TextStyle(color: kTextSecondary, fontSize: 9),
        ),
        children: [
          if (streamCount > 1) ...[
            DropdownButtonFormField<int>(
              key: ValueKey('audio_source_stream_${clip.id}_$selectedStream'),
              initialValue: selectedStream,
              decoration: const InputDecoration(labelText: 'Audio stream'),
              items: [
                for (var index = 0; index < streamCount; index++)
                  DropdownMenuItem(
                    value: index,
                    child: Text(() {
                      final metadata = index < audioStreams.length
                          ? audioStreams[index]
                          : const <String, dynamic>{};
                      final title = metadata['title']?.toString().trim();
                      final language = metadata['language']?.toString().trim();
                      final channels = (metadata['channels'] as num?)?.toInt();
                      return [
                        'Stream ${index + 1}',
                        if (title?.isNotEmpty == true) title!,
                        if (language?.isNotEmpty == true) language!,
                        if (channels != null) '$channels ch',
                      ].join(' • ');
                    }()),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                final metadata = value < audioStreams.length
                    ? audioStreams[value]
                    : const <String, dynamic>{};
                final channels = math.max(
                  1,
                  (metadata['channels'] as num?)?.toInt() ?? 2,
                );
                _updateSelectedClipAudioMix(
                  clip,
                  sourceStreamIndex: value,
                  sourceLeftChannel: 0,
                  sourceRightChannel: math.min(1, channels - 1),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
          if (sourceChannelCount > 1) ...[
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey(
                      'audio_left_source_${clip.id}_$selectedStream',
                    ),
                    initialValue: mix.sourceLeftChannel
                        .clamp(0, sourceChannelCount - 1)
                        .toInt(),
                    decoration: const InputDecoration(labelText: 'Output L'),
                    items: [
                      for (var index = 0; index < sourceChannelCount; index++)
                        DropdownMenuItem(
                          value: index,
                          child: Text('Source ${index + 1}'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        _updateSelectedClipAudioMix(
                          clip,
                          sourceLeftChannel: value,
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey(
                      'audio_right_source_${clip.id}_$selectedStream',
                    ),
                    initialValue: mix.sourceRightChannel
                        .clamp(0, sourceChannelCount - 1)
                        .toInt(),
                    decoration: const InputDecoration(labelText: 'Output R'),
                    items: [
                      for (var index = 0; index < sourceChannelCount; index++)
                        DropdownMenuItem(
                          value: index,
                          child: Text('Source ${index + 1}'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        _updateSelectedClipAudioMix(
                          clip,
                          sourceRightChannel: value,
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          DropdownButtonFormField<EditorAudioChannelMode>(
            key: const ValueKey('audio_channel_mode'),
            initialValue: mix.channelMode,
            decoration: const InputDecoration(labelText: 'Source channels'),
            items: [
              for (final mode in EditorAudioChannelMode.values)
                DropdownMenuItem(
                  value: mode,
                  child: Text(_audioChannelModeLabel(mode)),
                ),
            ],
            onChanged: (mode) {
              if (mode != null) {
                _updateSelectedClipAudioMix(clip, channelMode: mode);
              }
            },
          ),
          const SizedBox(height: 8),
          slider(
            label: 'Left channel gain',
            value: _linearGainToDb(mix.leftGain),
            minimum: -60,
            maximum: 6,
            divisions: 132,
            format: (value) => '${value.toStringAsFixed(1)} dB',
            onChanged: (value) => _updateSelectedClipAudioMix(
              clip,
              leftGain: _dbToLinearGain(value),
            ),
          ),
          slider(
            label: 'Right channel gain',
            value: _linearGainToDb(mix.rightGain),
            minimum: -60,
            maximum: 6,
            divisions: 132,
            format: (value) => '${value.toStringAsFixed(1)} dB',
            onChanged: (value) => _updateSelectedClipAudioMix(
              clip,
              rightGain: _dbToLinearGain(value),
            ),
          ),
          if (mix.normalize) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'TARGET STANDARD',
                style: TextStyle(
                  color: kTextSecondary,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final preset in const [
                  (label: 'Streaming', lufs: -14.0, peak: -1.0),
                  (label: 'Podcast', lufs: -16.0, peak: -1.0),
                  (label: 'EBU R128', lufs: -23.0, peak: -1.0),
                  (label: 'ATSC A/85', lufs: -24.0, peak: -2.0),
                ])
                  ChoiceChip(
                    key: ValueKey(
                      'loudness_preset_${preset.label.toLowerCase().replaceAll(' ', '_')}',
                    ),
                    label: Text(preset.label),
                    selected:
                        (mix.targetLufs - preset.lufs).abs() < 0.01 &&
                        (mix.peakLimitDb - preset.peak).abs() < 0.01,
                    onSelected: (_) => _updateSelectedClipAudioMix(
                      clip,
                      targetLufs: preset.lufs,
                      peakLimitDb: preset.peak,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            slider(
              label: 'Loudness target',
              value: mix.targetLufs,
              minimum: -30,
              maximum: -6,
              divisions: 48,
              format: (value) => '${value.toStringAsFixed(1)} LUFS',
              onChanged: (value) =>
                  _updateSelectedClipAudioMix(clip, targetLufs: value),
            ),
            slider(
              label: 'True-peak ceiling',
              value: mix.peakLimitDb,
              minimum: -12,
              maximum: -0.1,
              divisions: 119,
              format: (value) => '${value.toStringAsFixed(1)} dBTP',
              onChanged: (value) =>
                  _updateSelectedClipAudioMix(clip, peakLimitDb: value),
            ),
          ],
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              key: const ValueKey('analyze_audio_loudness'),
              onPressed: isAnalyzing ? null : () => _analyzeAudioClip(clip),
              icon: isAnalyzing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.speed_rounded),
              label: Text(
                isAnalyzing ? 'Analyzing audio…' : 'Analyze Peak / RMS / LUFS',
              ),
            ),
          ),
          if (measured != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kBorder),
              ),
              child: Wrap(
                spacing: 14,
                runSpacing: 8,
                children: [
                  _audioMeterValue(
                    'Peak',
                    '${measured.samplePeakDb.toStringAsFixed(1)} dBFS',
                  ),
                  _audioMeterValue(
                    'True peak',
                    '${measured.truePeakDb.toStringAsFixed(1)} dBTP',
                  ),
                  _audioMeterValue(
                    'RMS',
                    '${measured.rmsDb.toStringAsFixed(1)} dBFS',
                  ),
                  _audioMeterValue(
                    'Integrated',
                    '${measured.integratedLufs.toStringAsFixed(1)} LUFS',
                  ),
                  _audioMeterValue(
                    'LRA',
                    '${measured.loudnessRange.toStringAsFixed(1)} LU',
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Export uses these measurements for deterministic two-pass loudness normalization. Re-analyze after changing effects.',
                style: TextStyle(color: kTextSecondary, fontSize: 9),
              ),
            ),
          ],
          if (hasStaleMeasurement) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kWarning.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kWarning.withValues(alpha: 0.45)),
              ),
              child: const Text(
                'The stored meter pass is stale because routing, gain, effects, or source media changed. Export falls back to safe one-pass normalization until you analyze again.',
                style: TextStyle(color: kWarning, fontSize: 9),
              ),
            ),
          ],
          slider(
            label: 'Pitch',
            value: mix.pitchSemitones,
            minimum: -24,
            maximum: 24,
            divisions: 48,
            format: (value) => '${value.round()} semitones',
            onChanged: (value) =>
                _updateSelectedClipAudioMix(clip, pitchSemitones: value),
          ),
          slider(
            label: 'Time stretch',
            value: mix.timeStretch,
            minimum: 0.25,
            maximum: 4,
            divisions: 75,
            format: (value) => '${value.toStringAsFixed(2)}×',
            onChanged: (value) =>
                _updateSelectedClipAudioMix(clip, timeStretch: value),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Preserve pitch while stretching'),
            subtitle: const Text(
              'Uses FFmpeg tempo processing in preview and export',
            ),
            value: mix.preservePitch,
            onChanged: (value) =>
                _updateSelectedClipAudioMix(clip, preservePitch: value),
          ),
          if (clip.type == TimelineTrackType.audio) ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('fit_audio_target_duration'),
                    onPressed: () => _fitAudioClipToTarget(clip),
                    icon: const Icon(Icons.fit_screen_rounded),
                    label: const Text('Fit duration'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('crossfade_selected_audio'),
                    onPressed: _crossfadeSelectedAudioClips,
                    icon: const Icon(Icons.compare_arrows_rounded),
                    label: const Text('Crossfade 2'),
                  ),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Fit uses pitch-preserving tempo processing. Crossfade overlaps clips on independent lanes with smooth curves.',
                style: TextStyle(color: kTextSecondary, fontSize: 9),
              ),
            ),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('open_audio_effect_stack'),
              onPressed: () =>
                  _openEffectStackSheet(clip, domain: EditorEffectDomain.audio),
              icon: const Icon(Icons.multitrack_audio_rounded),
              label: const Text('Open clip / track effect stack'),
            ),
          ),
          if (track != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('audio_bus_${track.id}'),
                    initialValue: track.audioBusId ?? '',
                    decoration: const InputDecoration(labelText: 'Output bus'),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Master output'),
                      ),
                      for (final candidate in timeline.audioBuses)
                        DropdownMenuItem(
                          value: candidate.id,
                          child: Text(candidate.name),
                        ),
                    ],
                    onChanged: (value) => ref
                        .read(editorProvider.notifier)
                        .assignTrackToAudioBus(
                          track.id,
                          value == null || value.isEmpty ? null : value,
                        ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  key: const ValueKey('create_audio_bus'),
                  tooltip: 'Create bus',
                  onPressed: () => _createAudioBusForTrack(track.id),
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ],
          if (bus != null) ...[
            const SizedBox(height: 8),
            slider(
              label: '${bus.name} gain',
              value: _linearGainToDb(bus.gain),
              minimum: -60,
              maximum: 6,
              divisions: 132,
              format: (value) => '${value.toStringAsFixed(1)} dB',
              onChanged: (value) => ref
                  .read(editorProvider.notifier)
                  .updateAudioBus(
                    bus.id,
                    (current) => current.copyWith(gain: _dbToLinearGain(value)),
                    recordHistory: false,
                  ),
            ),
            slider(
              label: '${bus.name} pan',
              value: bus.pan,
              minimum: -1,
              maximum: 1,
              divisions: 40,
              format: (value) => value.abs() < 0.025
                  ? 'Center'
                  : value < 0
                  ? 'L ${(value.abs() * 100).round()}'
                  : 'R ${(value * 100).round()}',
              onChanged: (value) => ref
                  .read(editorProvider.notifier)
                  .updateAudioBus(
                    bus.id,
                    (current) => current.copyWith(pan: value),
                    recordHistory: false,
                  ),
            ),
            Row(
              children: [
                FilterChip(
                  label: const Text('Mute'),
                  selected: bus.muted,
                  onSelected: (value) => ref
                      .read(editorProvider.notifier)
                      .updateAudioBus(
                        bus.id,
                        (current) => current.copyWith(muted: value),
                      ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Solo'),
                  selected: bus.solo,
                  onSelected: (value) => ref
                      .read(editorProvider.notifier)
                      .updateAudioBus(
                        bus.id,
                        (current) => current.copyWith(solo: value),
                      ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _openEffectStackSheet(
                    clip,
                    domain: EditorEffectDomain.audio,
                    preferredScope: EditorEffectScope.audioBus,
                  ),
                  icon: const Icon(Icons.graphic_eq_rounded, size: 17),
                  label: const Text('Bus FX'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _createAudioBusForTrack(String trackId) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create audio bus'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Bus name',
            hintText: 'Dialogue, Music, SFX…',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    final notifier = ref.read(editorProvider.notifier);
    final busId = notifier.createAudioBus(name: name);
    notifier.assignTrackToAudioBus(trackId, busId);
  }

  ({TimelineTrack track, TimelineClip clip})? _separatedAudioForVideo(
    EditorTimeline timeline,
    String videoClipId,
  ) {
    for (final track in timeline.tracks) {
      for (final clip in track.clips) {
        if (clip.type == TimelineTrackType.audio &&
            clip.linkedClipId == videoClipId) {
          return (track: track, clip: clip);
        }
      }
    }
    return null;
  }

  ({TimelineTrack track, TimelineClip clip})? _audioOwnerForClip(
    EditorTimeline timeline,
    TimelineClip clip,
  ) => resolveEffectiveAudioOwner(timeline: timeline, clip: clip);

  Future<void> _openTransitionSheet(TimelineClip clip) async {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    if (track == null ||
        track.isLocked ||
        track.section != TimelineTrackSection.baseVideo ||
        clip.type != TimelineTrackType.video) {
      return;
    }
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.68,
      ),
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final editorState = ref.watch(editorProvider);
          final liveClip = _clipById(clip.id, editorState) ?? clip;
          return SingleChildScrollView(child: _buildTransitionEditor(liveClip));
        },
      ),
    );
  }

  Future<void> _openClipAnimationSheet(
    TimelineClip clip,
    TimelineTrack track,
  ) async {
    if (track.isLocked || !clip.supportsClipAnimation) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.68,
      ),
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final editorState = ref.watch(editorProvider);
          final liveClip = _clipById(clip.id, editorState) ?? clip;
          final liveTrack = _trackForClip(liveClip, editorState) ?? track;
          return SingleChildScrollView(
            child: _buildClipAnimationSheet(liveClip, liveTrack),
          );
        },
      ),
    );
  }

  Widget _buildTransitionEditor(TimelineClip clip) {
    final isCut =
        clip.outroTransition.type == TransitionType.none ||
        clip.outroTransition.type == TransitionType.cut;
    const transitionOptions = [
      (TransitionType.cut, 'Cut'),
      (TransitionType.fade, 'Fade'),
      (TransitionType.dissolve, 'Soft fade'),
      (TransitionType.slideLeft, 'Left'),
      (TransitionType.slideRight, 'Right'),
      (TransitionType.slideUp, 'Up'),
      (TransitionType.slideDown, 'Down'),
      (TransitionType.zoom, 'Zoom'),
      (TransitionType.zoomOut, 'Zoom out'),
      (TransitionType.pop, 'Pop'),
      (TransitionType.spin, 'Spin'),
      (TransitionType.slideUpLeft, 'Up-left'),
      (TransitionType.slideUpRight, 'Up-right'),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      decoration: const BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Transition from ${clip.label}',
            style: TextStyle(
              color: kTextPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: transitionOptions.map((option) {
              final isSelected =
                  clip.outroTransition.type == option.$1 ||
                  (clip.outroTransition.type == TransitionType.none &&
                      option.$1 == TransitionType.cut);
              return ChoiceChip(
                label: Text(option.$2),
                selected: isSelected,
                selectedColor: kAccent.withValues(alpha: 0.18),
                backgroundColor: kSurfaceElevated,
                side: BorderSide(color: isSelected ? kAccent : kBorder),
                labelStyle: TextStyle(
                  color: isSelected ? kAccent : kTextSecondary,
                  fontSize: 12,
                ),
                onSelected: (_) => _updateSelectedClipTransition(
                  clip: clip,
                  type: option.$1,
                  durationMs: option.$1 == TransitionType.cut
                      ? 0
                      : (clip.outroTransition.durationMs == 0
                            ? 450
                            : clip.outroTransition.durationMs),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          Text(
            'Duration',
            style: TextStyle(color: kTextSecondary, fontSize: 12),
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: kAccent,
              inactiveTrackColor: kBorder,
              thumbColor: kAccent,
              overlayColor: kAccent.withValues(alpha: 0.14),
            ),
            child: Slider(
              value: isCut
                  ? 0
                  : clip.outroTransition.durationMs.toDouble().clamp(100, 2000),
              min: 0,
              max: 2000,
              divisions: 20,
              label: '${isCut ? 0 : clip.outroTransition.durationMs}ms',
              onChangeStart: isCut
                  ? null
                  : (_) => ref
                        .read(editorProvider.notifier)
                        .beginTimelineGestureEdit(),
              onChanged: isCut
                  ? null
                  : (value) => _updateSelectedClipTransition(
                      clip: clip,
                      durationMs: value.round(),
                    ),
              onChangeEnd: isCut
                  ? null
                  : (_) => ref
                        .read(editorProvider.notifier)
                        .endTimelineGestureEdit(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClipAnimationSheet(TimelineClip clip, TimelineTrack track) {
    const animationOptions = [
      (TransitionType.none, 'None'),
      (TransitionType.fade, 'Fade'),
      (TransitionType.slideLeft, 'Slide Left'),
      (TransitionType.slideRight, 'Slide Right'),
      (TransitionType.slideUp, 'Slide Up'),
      (TransitionType.slideDown, 'Slide Down'),
      (TransitionType.zoom, 'Zoom'),
      (TransitionType.zoomOut, 'Zoom out'),
      (TransitionType.pop, 'Pop'),
      (TransitionType.spin, 'Spin'),
      (TransitionType.slideUpLeft, 'Up-left'),
      (TransitionType.slideUpRight, 'Up-right'),
    ];
    final isAudioTrack = track.section == TimelineTrackSection.audio;
    final sheetTitle = isAudioTrack
        ? 'Audio Animation'
        : track.section == TimelineTrackSection.baseVideo
        ? 'Clip Animation'
        : 'Overlay Animation';
    final maximumFadeMs = math.max(1, clip.duration.inMilliseconds ~/ 2);
    final fadeDivisions = math.max(1, math.min(200, maximumFadeMs ~/ 50));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      decoration: const BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            sheetTitle,
            style: TextStyle(
              color: kTextPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          if (!isAudioTrack) ...[
            Text(
              'Animate In',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: animationOptions.map((option) {
                final isSelected = clip.introTransition.type == option.$1;
                return ChoiceChip(
                  label: Text(option.$2),
                  selected: isSelected,
                  selectedColor: kAccent.withValues(alpha: 0.18),
                  backgroundColor: kSurfaceElevated,
                  side: BorderSide(color: isSelected ? kAccent : kBorder),
                  labelStyle: TextStyle(
                    color: isSelected ? kAccent : kTextSecondary,
                    fontSize: 12,
                  ),
                  onSelected: (_) => _updateSelectedClipTransition(
                    clip: clip,
                    updateIntro: true,
                    updateOutro: false,
                    type: option.$1,
                    durationMs: option.$1 == TransitionType.none
                        ? 0
                        : math.max(350, clip.introTransition.durationMs),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            Text(
              'Animate Out',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: animationOptions.map((option) {
                final isSelected = clip.outroTransition.type == option.$1;
                return ChoiceChip(
                  label: Text(option.$2),
                  selected: isSelected,
                  selectedColor: kAccent.withValues(alpha: 0.18),
                  backgroundColor: kSurfaceElevated,
                  side: BorderSide(color: isSelected ? kAccent : kBorder),
                  labelStyle: TextStyle(
                    color: isSelected ? kAccent : kTextSecondary,
                    fontSize: 12,
                  ),
                  onSelected: (_) => _updateSelectedClipTransition(
                    clip: clip,
                    updateIntro: false,
                    updateOutro: true,
                    type: option.$1,
                    durationMs: option.$1 == TransitionType.none
                        ? 0
                        : math.max(350, clip.outroTransition.durationMs),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            Text(
              'Animation Length',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kAccent,
                inactiveTrackColor: kBorder,
                thumbColor: kAccent,
                overlayColor: kAccent.withValues(alpha: 0.14),
              ),
              child: Slider(
                value:
                    (clip.introTransition.durationMs == 0
                            ? clip.outroTransition.durationMs
                            : clip.introTransition.durationMs)
                        .toDouble()
                        .clamp(150, 2000),
                min: 150,
                max: 2000,
                divisions: 37,
                label:
                    '${(clip.introTransition.durationMs == 0 ? clip.outroTransition.durationMs : clip.introTransition.durationMs)}ms',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) {
                  final rounded = value.round();
                  _updateSelectedClipTransition(
                    clip: clip,
                    updateIntro:
                        clip.introTransition.type != TransitionType.none,
                    updateOutro: false,
                    durationMs: rounded,
                  );
                  _updateSelectedClipTransition(
                    clip: clip,
                    updateIntro: false,
                    updateOutro:
                        clip.outroTransition.type != TransitionType.none,
                    durationMs: rounded,
                  );
                },
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
            ),
          ] else ...[
            Text(
              'Fade In',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kAccent,
                inactiveTrackColor: kBorder,
                thumbColor: kAccent,
                overlayColor: kAccent.withValues(alpha: 0.14),
              ),
              child: Slider(
                value: clip.audioMix.fadeInMs
                    .toDouble()
                    .clamp(0, maximumFadeMs)
                    .toDouble(),
                min: 0,
                max: maximumFadeMs.toDouble(),
                divisions: fadeDivisions,
                label: '${clip.audioMix.fadeInMs}ms',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateSelectedClipAudioMix(clip, fadeInMs: value.round()),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
            ),
            Text(
              'Fade Out',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kAccent,
                inactiveTrackColor: kBorder,
                thumbColor: kAccent,
                overlayColor: kAccent.withValues(alpha: 0.14),
              ),
              child: Slider(
                value: clip.audioMix.fadeOutMs
                    .toDouble()
                    .clamp(0, maximumFadeMs)
                    .toDouble(),
                min: 0,
                max: maximumFadeMs.toDouble(),
                divisions: fadeDivisions,
                label: '${clip.audioMix.fadeOutMs}ms',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateSelectedClipAudioMix(clip, fadeOutMs: value.round()),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openStylePanelSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.2),
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => ResizableEditorSheet(
        title: 'Subtitle style',
        subtitle: 'Resize the sheet to balance the preview and controls',
        initialHeightFactor: 0.38,
        minHeightFactor: 0.24,
        maxHeightFactor: 0.88,
        scrollable: false,
        contentPadding: EdgeInsets.zero,
        onClose: () => Navigator.pop(sheetContext),
        child: const SubtitleStylePanel(),
      ),
    );
  }
}

class _SelectionCapabilities {
  final bool canEdit;
  final bool canAdjustAudio;
  final bool canVisualEffects;
  final bool canAnimate;
  final bool canTransition;
  final bool canArrange;
  final bool canChangeLayer;
  final bool isFilterEffect;
  final bool isBlurEffect;

  const _SelectionCapabilities({
    required this.canEdit,
    required this.canAdjustAudio,
    required this.canVisualEffects,
    required this.canAnimate,
    required this.canTransition,
    required this.canArrange,
    required this.canChangeLayer,
    required this.isFilterEffect,
    required this.isBlurEffect,
  });
}

class _ActionSpec {
  final Key? key;
  final double? width;
  final String group;
  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;

  const _ActionSpec({
    this.key,
    this.width,
    required this.group,
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.active = false,
  });
}

class _GiphyPickerSheet extends StatefulWidget {
  final Future<void> Function(GiphyAssetResult result) onSelected;

  const _GiphyPickerSheet({required this.onSelected});

  @override
  State<_GiphyPickerSheet> createState() => _GiphyPickerSheetState();
}

class _GiphyPickerSheetState extends State<_GiphyPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<GiphyAssetResult> _results = const [];
  bool _isLoading = false;
  bool _selectionInProgress = false;
  String? _error;
  GiphySearchKind _searchKind = GiphySearchKind.both;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_refreshResults());
    });
  }

  @override
  void dispose() {
    _requestGeneration++;
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(_refreshResults());
    });
  }

  Future<void> _refreshResults() async {
    final requestGeneration = ++_requestGeneration;
    final query = _searchController.text;
    final searchKind = _searchKind;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final results = await GiphyService.shared.search(
        query: query,
        kind: searchKind,
      );
      if (!mounted || requestGeneration != _requestGeneration) return;
      setState(() {
        _results = results;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || requestGeneration != _requestGeneration) return;
      setState(() {
        _results = const [];
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Future<void> _selectResult(GiphyAssetResult result) async {
    if (_selectionInProgress) return;
    setState(() => _selectionInProgress = true);
    try {
      await widget.onSelected(result);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selectionInProgress = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ResizableEditorSheet(
      title: 'GIFs & stickers',
      subtitle: 'Search animated overlays from GIPHY',
      initialHeightFactor: 0.72,
      minHeightFactor: 0.48,
      maxHeightFactor: 0.90,
      scrollable: false,
      contentPadding: EdgeInsets.zero,
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onQueryChanged,
                    style: TextStyle(color: kTextPrimary),
                    decoration: InputDecoration(
                      hintText: 'Search GIFs and stickers',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _searchController.clear();
                                _refreshResults();
                              },
                              icon: const Icon(Icons.close_rounded, size: 18),
                            ),
                      filled: true,
                      fillColor: kSurfaceElevated,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: const BorderSide(color: kBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: const BorderSide(color: kBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: const BorderSide(color: kAccent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _isLoading ? null : _refreshResults,
                  child: Ink(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: kSurfaceElevated,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kBorder),
                    ),
                    child: const Icon(
                      Icons.refresh_rounded,
                      color: kTextPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _buildKindChip(label: 'All', kind: GiphySearchKind.both),
                    const SizedBox(width: 8),
                    _buildKindChip(label: 'GIFs', kind: GiphySearchKind.gifs),
                    const SizedBox(width: 8),
                    _buildKindChip(
                      label: 'Stickers',
                      kind: GiphySearchKind.stickers,
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                const Text(
                  'Powered by GIPHY',
                  style: TextStyle(
                    color: kTextSecondary,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Builder(
              builder: (context) {
                if (_isLoading) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: kAccent,
                      strokeWidth: 2,
                    ),
                  );
                }

                if (_error != null) {
                  return _buildSheetMessage(
                    icon: Icons.key_off_rounded,
                    message: _error!,
                  );
                }

                if (_results.isEmpty) {
                  return _buildSheetMessage(
                    icon: Icons.gif_box_outlined,
                    message: _searchController.text.trim().isEmpty
                        ? 'No trending results right now.'
                        : 'No results for this search.',
                  );
                }

                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: _results.length,
                  itemBuilder: (_, index) {
                    final result = _results[index];
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: () => _selectResult(result),
                        child: Ink(
                          decoration: BoxDecoration(
                            color: kSurfaceElevated,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: kBorder),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.network(
                                  result.previewUrl,
                                  fit: BoxFit.cover,
                                  filterQuality: FilterQuality.low,
                                  errorBuilder: (_, _, _) => Container(
                                    color: kSurfaceElevated,
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.broken_image_outlined,
                                      color: kTextSecondary,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 10,
                                  bottom: 10,
                                  child: Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.45,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.add_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKindChip({
    required String label,
    required GiphySearchKind kind,
  }) {
    final isSelected = _searchKind == kind;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: kAccent.withValues(alpha: 0.18),
      backgroundColor: kSurfaceElevated,
      side: BorderSide(color: isSelected ? kAccent : kBorder),
      labelStyle: TextStyle(
        color: isSelected ? kAccent : kTextSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      onSelected: (_) {
        setState(() => _searchKind = kind);
        unawaited(_refreshResults());
      },
    );
  }

  Widget _buildSheetMessage({required IconData icon, required String message}) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: kSurfaceElevated,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: kBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: kTextSecondary),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: kTextSecondary,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
