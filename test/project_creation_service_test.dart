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
      expect(project.timeline.tracks, hasLength(2));
      expect(project.timeline.tracks.map((track) => track.type), [
        TimelineTrackType.video,
        TimelineTrackType.subtitle,
      ]);
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

      final restored = Project.fromJson(project.toJson());
      expect(restored.timeline.videoClips, hasLength(2));
      expect(restored.durationMs, project.durationMs);
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
