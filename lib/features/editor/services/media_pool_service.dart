import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../../core/utils/ffmpeg_service.dart';
import '../../../core/utils/media_import_service.dart';
import '../../../core/utils/media_job.dart';
import '../../../core/utils/timeline_proxy_media_service.dart';
import '../models/timeline_models.dart';

class MediaPoolImportResult {
  const MediaPoolImportResult(this.assets, this.failures);
  final List<EditorAssetReference> assets;
  final Map<String, String> failures;
}

class MediaPoolService {
  static const extensions = [
    'mp4',
    'mov',
    'm4v',
    'webm',
    'mkv',
    'avi',
    'mp3',
    'wav',
    'm4a',
    'aac',
    'flac',
    'ogg',
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
    'bmp',
  ];

  /// Two workers bound native probing; invalid files do not abort valid ones.
  static Future<MediaPoolImportResult> importFiles(
    List<String> paths, {
    required List<EditorAssetReference> existingAssets,
    void Function(int completed, int total)? onProgress,
    Future<Map<String, dynamic>> Function(String)? probe,
    Future<String> Function(String)? persist,
  }) async {
    String identity(String value) {
      final normalized = p.normalize(p.absolute(value));
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    final known = existingAssets
        .map((asset) => asset.sourcePath)
        .whereType<String>()
        .map(identity)
        .toSet();
    final pending = paths.where((path) => known.add(identity(path))).toList();
    final results = List<EditorAssetReference?>.filled(pending.length, null);
    final failures = <String, String>{};
    var cursor = 0;
    var completed = 0;
    Future<void> worker() async {
      while (cursor < pending.length) {
        final index = cursor++;
        final source = pending[index];
        try {
          final type = switch (p.extension(source).toLowerCase()) {
            '.mp4' ||
            '.mov' ||
            '.m4v' ||
            '.webm' ||
            '.mkv' ||
            '.avi' => EditorAssetType.video,
            '.mp3' ||
            '.wav' ||
            '.m4a' ||
            '.aac' ||
            '.flac' ||
            '.ogg' => EditorAssetType.audio,
            '.png' ||
            '.jpg' ||
            '.jpeg' ||
            '.webp' ||
            '.bmp' => EditorAssetType.image,
            '.gif' => EditorAssetType.gif,
            _ => throw StateError('Unsupported media type.'),
          };
          final sourcePath = await (persist ?? MediaImportService.persistFile)(
            source,
          );
          final info = probe != null
              ? await probe(sourcePath).timeout(const Duration(seconds: 30))
              : await FFmpegService.getMediaInfo(sourcePath, job: MediaJob());
          final duration = (info['durationMs'] as num?)?.toInt() ?? 0;
          if ((type == EditorAssetType.video ||
                  type == EditorAssetType.audio) &&
              duration <= 0) {
            throw StateError('This file has no readable duration.');
          }
          if (type != EditorAssetType.audio &&
              ((info['width'] as num?) ?? 0) <= 0) {
            throw StateError(
              'This file has no readable image or video stream.',
            );
          }
          if (type == EditorAssetType.audio && info['hasAudio'] != true) {
            throw StateError('This file has no readable audio stream.');
          }
          results[index] = EditorAssetReference(
            type: type,
            label: p.basename(source),
            sourcePath: sourcePath,
            metadata: info,
          );
        } catch (error) {
          failures[source] = error.toString().replaceFirst('Exception: ', '');
        }
        onProgress?.call(++completed, pending.length);
      }
    }

    await Future.wait(
      List.generate(math.min(2, pending.length), (_) => worker()),
    );
    return MediaPoolImportResult(
      results.whereType<EditorAssetReference>().toList(),
      failures,
    );
  }

  /// Relink changes asset paths and metadata, preserving all clip edits and IDs.
  static EditorTimeline relink({
    required EditorTimeline timeline,
    required String assetId,
    required String sourcePath,
    required Map<String, dynamic> mediaInfo,
  }) {
    final original = timeline.assets
        .where((asset) => asset.id == assetId)
        .firstOrNull;
    if (original == null)
      throw StateError('The asset is no longer in this project.');
    final affected = timeline.assets
        .where(
          (asset) =>
              asset.id == assetId ||
              (original.sourcePath?.isNotEmpty == true &&
                  asset.sourcePath == original.sourcePath),
        )
        .toList();
    final ids = affected.map((asset) => asset.id).toSet();
    final durationMs = (mediaInfo['durationMs'] as num?)?.toInt() ?? 0;
    for (final track in timeline.tracks) {
      for (final clip in track.clips.where(
        (clip) => ids.contains(clip.assetId),
      )) {
        if (track.isLocked)
          throw StateError(
            'Unlock every track using this source before relinking.',
          );
        if (clip.type == TimelineTrackType.audio &&
            mediaInfo['hasAudio'] != true) {
          throw StateError(
            'The selected file is missing the audio used by this project.',
          );
        }
        if (clip.type.supportsSourceTiming) {
          final span = clip.sourceDuration > Duration.zero
              ? clip.sourceDuration.inMilliseconds
              : (clip.duration.inMilliseconds * clip.playbackRate).round();
          final end = clip.freezeFrame
              ? clip.effectiveFreezeFrameSourceTime.inMilliseconds + 1
              : clip.sourceStartTime.inMilliseconds + span;
          if (durationMs < end)
            throw StateError(
              'The selected file is shorter than an existing source trim. Use Replace footage to change the edit.',
            );
        }
      }
    }
    for (final key in ['width', 'height']) {
      final previous = (original.metadata[key] as num?)?.toInt() ?? 0;
      if (previous > 0 && previous != (mediaInfo[key] as num?)?.toInt()) {
        throw StateError(
          'The selected file has different dimensions. Use Replace footage for a different source.',
        );
      }
    }
    if (original.type == EditorAssetType.audio &&
        mediaInfo['hasAudio'] != true) {
      throw StateError('The selected file has no audio stream.');
    }
    if (original.type != EditorAssetType.audio &&
        ((mediaInfo['width'] as num?) ?? 0) <= 0) {
      throw StateError('The selected file has no image or video stream.');
    }
    return timeline.copyWith(
      assets: [
        for (final asset in timeline.assets)
          if (ids.contains(asset.id))
            asset.copyWith(
              sourcePath: sourcePath,
              isNetworkBacked: false,
              clearRemoteUrl: true,
              metadata: TimelineProxyMediaService.metadataAfterSourceRelink(
                previousMetadata: asset.metadata,
                mediaInfo: mediaInfo,
              ),
            )
          else
            asset,
      ],
    );
  }
}
