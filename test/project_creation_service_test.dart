import 'package:caption_craft/core/utils/project_creation_service.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('project creation', () {
    test('builds a loadable multi-clip timeline in import order', () async {
      final project = await ProjectCreationService.createProjectFromVideos(
        ownerUid: 'user-a',
        sources: const [
          ImportedVideoSource(
            filePath: '/media/first.mp4',
            displayName: 'first.mp4',
          ),
          ImportedVideoSource(
            filePath: '/media/second.mp4',
            displayName: 'second.mp4',
          ),
        ],
        projectName: 'New montage',
        generateThumbnail: false,
        mediaInfoLoader: (filePath) async => {
          'durationMs': filePath.endsWith('first.mp4') ? 2500 : 1750,
          'width': 1920,
          'height': 1080,
          'hasAudio': true,
          'frameRate': 30,
        },
      );

      expect(project.name, 'New montage');
      expect(project.ownerUid, 'user-a');
      expect(project.durationMs, 4250);
      expect(project.thumbnailBase64, isNull);
      expect(project.timeline.assets, hasLength(2));
      expect(project.timeline.tracks, hasLength(3));
      expect(project.timeline.tracks.map((track) => track.type), [
        TimelineTrackType.text,
        TimelineTrackType.video,
        TimelineTrackType.video,
      ]);
      expect(project.timeline.tracks.map((track) => track.section), [
        TimelineTrackSection.textSubtitle,
        TimelineTrackSection.overlay,
        TimelineTrackSection.baseVideo,
      ]);
      expect(project.timeline.tracks.map((track) => track.role), [
        TimelineTrackRole.regular,
        TimelineTrackRole.regular,
        TimelineTrackRole.regular,
      ]);
      expect(
        project.timeline.tracks.any(
          (track) => track.type == TimelineTrackType.subtitle,
        ),
        isFalse,
      );
      final clips = project.timeline.tracks
          .firstWhere(
            (track) => track.section == TimelineTrackSection.baseVideo,
          )
          .clips;
      expect(clips, hasLength(2));
      expect(clips.first.startTime, Duration.zero);
      expect(clips.first.endTime, const Duration(milliseconds: 2500));
      expect(clips.last.startTime, const Duration(milliseconds: 2500));
      expect(clips.last.endTime, const Duration(milliseconds: 4250));
      expect(clips.every((clip) => !clip.audioMix.muted), isTrue);
      expect(
        project.timeline.tracks.any(
          (track) => track.role == TimelineTrackRole.sourceAudio,
        ),
        isFalse,
      );

      final restored = Project.fromJson(project.toJson());
      expect(restored.timeline.videoClips, hasLength(2));
      expect(
        restored.timeline.tracks.any(
          (track) => track.role == TimelineTrackRole.sourceAudio,
        ),
        isFalse,
      );
      expect(restored.durationMs, project.durationMs);
    });

    test('accepts image and GIF clips on the base layer', () async {
      final project = await ProjectCreationService.createProjectFromMedia(
        ownerUid: 'user-a',
        sources: const [
          ImportedMediaSource(
            filePath: '/media/cover.png',
            displayName: 'cover.png',
          ),
          ImportedMediaSource(
            filePath: '/media/loop.gif',
            displayName: 'loop.gif',
          ),
        ],
        generateThumbnail: false,
        mediaInfoLoader: (filePath) async => {
          'durationMs': filePath.endsWith('.gif') ? 2200 : 0,
          'width': 1080,
          'height': 1080,
          'hasAudio': false,
        },
      );

      final baseTrack = project.timeline.tracks.singleWhere(
        (track) => track.section == TimelineTrackSection.baseVideo,
      );
      expect(baseTrack.name, 'Base layer');
      expect(baseTrack.clips.map((clip) => clip.type), [
        TimelineTrackType.image,
        TimelineTrackType.gif,
      ]);
      expect(baseTrack.clips.first.duration, const Duration(seconds: 4));
      expect(baseTrack.clips.last.duration, const Duration(milliseconds: 2200));
      expect(
        project.timeline.tracks.any(
          (track) => track.section == TimelineTrackSection.audio,
        ),
        isFalse,
      );
    });

    test('rejects media that has no readable duration', () async {
      await expectLater(
        ProjectCreationService.createProjectFromVideos(
          ownerUid: 'user-a',
          sources: const [
            ImportedVideoSource(
              filePath: '/media/broken.mp4',
              displayName: 'broken.mp4',
            ),
          ],
          generateThumbnail: false,
          mediaInfoLoader: (_) async => const {
            'durationMs': 0,
            'width': 0,
            'height': 0,
            'hasAudio': false,
            'frameRate': 0,
          },
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Could not read duration'),
          ),
        ),
      );
    });
  });
}
