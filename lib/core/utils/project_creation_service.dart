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

class ImportedMediaSource {
  final String filePath;
  final String displayName;

  const ImportedMediaSource({
    required this.filePath,
    required this.displayName,
  });

  EditorAssetType get assetType {
    return switch (path.extension(filePath).toLowerCase()) {
      '.png' || '.jpg' || '.jpeg' || '.webp' => EditorAssetType.image,
      '.gif' => EditorAssetType.gif,
      _ => EditorAssetType.video,
    };
  }

  TimelineTrackType get clipType {
    return switch (assetType) {
      EditorAssetType.image => TimelineTrackType.image,
      EditorAssetType.gif => TimelineTrackType.gif,
      _ => TimelineTrackType.video,
    };
  }
}

// Kept as a source-compatible alias for callers compiled against the earlier
// video-only project creator.
typedef ImportedVideoSource = ImportedMediaSource;

class ProjectCreationService {
  ProjectCreationService._();

  static Future<Project> createProjectFromVideos({
    required List<ImportedVideoSource> sources,
    required String ownerUid,
    String? projectName,
    bool generateThumbnail = true,
    ProjectMediaInfoLoader? mediaInfoLoader,
  }) => createProjectFromMedia(
    sources: sources,
    ownerUid: ownerUid,
    projectName: projectName,
    generateThumbnail: generateThumbnail,
    mediaInfoLoader: mediaInfoLoader,
  );

  static Future<Project> createProjectFromMedia({
    required List<ImportedMediaSource> sources,
    required String ownerUid,
    String? projectName,
    bool generateThumbnail = true,
    ProjectMediaInfoLoader? mediaInfoLoader,
  }) async {
    if (sources.isEmpty) {
      throw Exception('Select at least one visual to create a project.');
    }

    final assets = <EditorAssetReference>[];
    final clips = <TimelineClip>[];
    var timelineCursor = Duration.zero;
    var totalDurationMs = 0;
    final loadMediaInfo = mediaInfoLoader ?? FFmpegService.getMediaInfo;

    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      Map<String, dynamic> mediaInfo;
      try {
        mediaInfo = await loadMediaInfo(source.filePath).timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'Reading ${source.displayName} took too long. Try importing it again.',
          ),
        );
      } catch (_) {
        if (source.assetType == EditorAssetType.video) rethrow;
        mediaInfo = const {};
      }
      var durationMs = (mediaInfo['durationMs'] as int?) ?? 0;
      if (source.assetType == EditorAssetType.video && durationMs <= 0) {
        throw Exception('Could not read duration for ${source.displayName}.');
      }
      if (durationMs <= 0) durationMs = 4000;

      final asset = EditorAssetReference(
        type: source.assetType,
        label: source.displayName,
        sourcePath: source.filePath,
        metadata: {
          'durationMs': durationMs,
          'width': mediaInfo['width'],
          'height': mediaInfo['height'],
          'hasAudio':
              source.assetType == EditorAssetType.video &&
              mediaInfo['hasAudio'] == true,
          'frameRate': mediaInfo['frameRate'],
        },
      );
      assets.add(asset);

      final clipDuration = Duration(milliseconds: durationMs);
      final videoClip = TimelineClip(
        trackId: 'track_video_primary',
        type: source.clipType,
        label: source.displayName,
        assetId: asset.id,
        startTime: timelineCursor,
        endTime: timelineCursor + clipDuration,
        sourceStartTime: Duration.zero,
        sourceDuration: clipDuration,
        fitMode: ClipFitMode.cover,
        layer: index,
      );
      clips.add(videoClip);

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
          id: 'track_text_primary',
          name: 'Text',
          type: TimelineTrackType.text,
          section: TimelineTrackSection.textSubtitle,
          clips: const [],
        ),
        TimelineTrack(
          id: 'track_overlay_primary',
          name: 'Overlay',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.overlay,
          clips: const [],
        ),
        TimelineTrack(
          id: 'track_video_primary',
          name: 'Base layer',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          role: TimelineTrackRole.regular,
          clips: clips,
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
