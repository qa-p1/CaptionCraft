import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../features/editor/models/subtitle_style_model.dart';
import '../../features/editor/models/timeline_models.dart';
import '../../shared/models/project_model.dart';
import 'ffmpeg_service.dart';

typedef ProjectMediaInfoLoader =
    Future<Map<String, dynamic>> Function(String filePath);

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
    required String ownerUid,
    String? projectName,
    bool generateThumbnail = true,
    ProjectMediaInfoLoader? mediaInfoLoader,
  }) async {
    if (sources.isEmpty) {
      throw Exception('Select at least one video to create a project.');
    }

    final assets = <EditorAssetReference>[];
    final clips = <TimelineClip>[];
    var timelineCursor = Duration.zero;
    var totalDurationMs = 0;
    final loadMediaInfo = mediaInfoLoader ?? FFmpegService.getMediaInfo;

    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      final mediaInfo = await loadMediaInfo(source.filePath).timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException(
          'Reading ${source.displayName} took too long. Try importing it again.',
        ),
      );
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
          'frameRate': mediaInfo['frameRate'],
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

    final thumbnailBase64 = generateThumbnail
        ? await _buildThumbnailBase64(sources.first.filePath)
        : null;
    final resolvedProjectName = (projectName?.trim().isNotEmpty == true)
        ? projectName!.trim()
        : path.basenameWithoutExtension(sources.first.displayName);

    final timeline = EditorTimeline(
      subtitleStyle: const SubtitleStyleModel(),
      assets: assets,
      tracks: [
        TimelineTrack(
          id: 'track_video_primary',
          name: 'Video 1',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: clips,
        ),
        TimelineTrack(
          id: 'track_subtitles',
          name: 'Subtitles',
          type: TimelineTrackType.subtitle,
          section: TimelineTrackSection.textSubtitle,
          clips: const [],
        ),
      ],
    );

    return Project(
      id: const Uuid().v4(),
      ownerUid: ownerUid,
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
    String? thumbPath;
    try {
      thumbPath = await FFmpegService.generateThumbnail(videoPath);
      if (thumbPath.isEmpty) return null;
      final thumbFile = File(thumbPath);
      if (!await thumbFile.exists()) return null;
      final bytes = await thumbFile.readAsBytes();
      if (bytes.isEmpty) return null;
      return base64Encode(bytes);
    } catch (_) {
      return null;
    } finally {
      if (thumbPath != null && thumbPath.isNotEmpty) {
        try {
          final thumbFile = File(thumbPath);
          if (await thumbFile.exists()) await thumbFile.delete();
        } catch (_) {
          // Thumbnail cleanup is best-effort.
        }
      }
    }
  }
}
