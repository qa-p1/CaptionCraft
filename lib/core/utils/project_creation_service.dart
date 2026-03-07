import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../features/editor/models/subtitle_style_model.dart';
import '../../features/editor/models/timeline_models.dart';
import '../../shared/models/project_model.dart';
import 'ffmpeg_service.dart';

class ImportedVideoSource {
  final String filePath;
  final String displayName;

  const ImportedVideoSource({
    required this.filePath,
    required this.displayName,
  });
}

class ProjectCreationService {
  ProjectCreationService._();

  static Future<Project> createProjectFromVideos({
    required List<ImportedVideoSource> sources,
    String? projectName,
  }) async {
    if (sources.isEmpty) {
      throw Exception('Select at least one video to create a project.');
    }

    final assets = <EditorAssetReference>[];
    final clips = <TimelineClip>[];
    var timelineCursor = Duration.zero;
    var totalDurationMs = 0;

    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      final mediaInfo = await FFmpegService.getMediaInfo(source.filePath);
      final durationMs = (mediaInfo['durationMs'] as int?) ?? 0;
      if (durationMs <= 0) {
        throw Exception('Could not read duration for ${source.displayName}.');
      }

      final asset = EditorAssetReference(
        type: EditorAssetType.video,
        label: source.displayName,
        sourcePath: source.filePath,
        metadata: {
          'durationMs': durationMs,
          'width': mediaInfo['width'],
          'height': mediaInfo['height'],
          'hasAudio': mediaInfo['hasAudio'],
        },
      );
      assets.add(asset);

      final clipDuration = Duration(milliseconds: durationMs);
      clips.add(
        TimelineClip(
          trackId: 'track_video_primary',
          type: TimelineTrackType.video,
          label: source.displayName,
          assetId: asset.id,
          startTime: timelineCursor,
          endTime: timelineCursor + clipDuration,
          sourceStartTime: Duration.zero,
          sourceDuration: clipDuration,
          fitMode: ClipFitMode.cover,
          layer: index,
        ),
      );

      timelineCursor += clipDuration;
      totalDurationMs += durationMs;
    }

    final thumbnailBase64 = await _buildThumbnailBase64(sources.first.filePath);
    final resolvedProjectName = (projectName?.trim().isNotEmpty == true)
        ? projectName!.trim()
        : path.basenameWithoutExtension(sources.first.displayName);

    final timeline = EditorTimeline(
      subtitleStyle: const SubtitleStyleModel(),
      assets: assets,
      tracks: [
        TimelineTrack(
          id: 'track_overlay_primary',
          name: 'Overlay 1',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.overlay,
          clips: const [],
        ),
        TimelineTrack(
          id: 'track_video_primary',
          name: 'Video 1',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: clips,
        ),
        TimelineTrack(
          id: 'track_text_primary',
          name: 'Text 1',
          type: TimelineTrackType.text,
          section: TimelineTrackSection.textSubtitle,
          clips: const [],
        ),
        TimelineTrack(
          id: 'track_subtitles',
          name: 'Subtitles',
          type: TimelineTrackType.subtitle,
          section: TimelineTrackSection.textSubtitle,
          clips: const [],
        ),
        TimelineTrack(
          id: 'track_audio_primary',
          name: 'Audio 1',
          type: TimelineTrackType.audio,
          section: TimelineTrackSection.audio,
          clips: const [],
        ),
      ],
    );

    return Project(
      id: const Uuid().v4(),
      name: resolvedProjectName,
      videoPath: sources.first.filePath,
      thumbnailBase64: thumbnailBase64,
      durationMs: totalDurationMs,
      subtitles: const [],
      globalStyle: timeline.subtitleStyle,
      timeline: timeline,
    );
  }

  static Future<String?> _buildThumbnailBase64(String videoPath) async {
    try {
      final thumbPath = await FFmpegService.generateThumbnail(videoPath);
      if (thumbPath.isEmpty) return null;
      final thumbFile = File(thumbPath);
      if (!await thumbFile.exists()) return null;
      final bytes = await thumbFile.readAsBytes();
      if (bytes.isEmpty) return null;
      return base64Encode(bytes);
    } catch (_) {
      return null;
    }
  }
}
