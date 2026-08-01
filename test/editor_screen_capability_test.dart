import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/screens/editor_screen.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('subtitle insertion never falls back to a text lane', () {
    final textTrack = TimelineTrack(
      id: 'text',
      name: 'Text',
      type: TimelineTrackType.text,
      section: TimelineTrackSection.textSubtitle,
    );
    final lockedSubtitleTrack = TimelineTrack(
      id: 'locked-subtitles',
      name: 'Locked subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      isLocked: true,
    );
    final subtitleTrack = TimelineTrack(
      id: 'subtitles',
      name: 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
    );
    final timeline = EditorTimeline(
      tracks: [textTrack, lockedSubtitleTrack, subtitleTrack],
    );

    expect(
      timeline.insertionTrackFor(
        section: TimelineTrackSection.textSubtitle,
        clipType: TimelineTrackType.subtitle,
        preferredTrackId: textTrack.id,
      ),
      isNull,
    );
    expect(
      EditorTimeline(tracks: [textTrack, subtitleTrack]).insertionTrackFor(
        section: TimelineTrackSection.textSubtitle,
        clipType: TimelineTrackType.subtitle,
        preferredTrackId: textTrack.id,
      ),
      same(subtitleTrack),
    );
    expect(
      EditorTimeline(
        tracks: [textTrack, lockedSubtitleTrack],
      ).insertionTrackFor(
        section: TimelineTrackSection.textSubtitle,
        clipType: TimelineTrackType.subtitle,
        preferredTrackId: textTrack.id,
      ),
      isNull,
    );
  });

  testWidgets('locked selected clips expose no mutation categories', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    final project = _lockedVideoProject();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: EditorScreen(project: project),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    container.read(editorProvider.notifier)
      ..selectTrack('locked-video')
      ..selectClip('locked-clip');
    await tester.pump();

    InkWell category(String label) {
      final labelFinder = find.text(label).last;
      final inkWellFinder = find.ancestor(
        of: labelFinder,
        matching: find.byType(InkWell),
      );
      return tester.widget<InkWell>(inkWellFinder.last);
    }

    expect(category('Add').onTap, isNotNull);
    expect(category('Canvas').onTap, isNotNull);
    expect(category('Edit').onTap, isNull);
    expect(category('Effects').onTap, isNull);
    expect(category('Audio').onTap, isNull);
    expect(tester.takeException(), isNull);
  });
}

Project _lockedVideoProject() {
  const duration = Duration(seconds: 8);
  const sourcePath = 'locked-source.mp4';
  final asset = EditorAssetReference(
    id: 'locked-asset',
    type: EditorAssetType.video,
    label: 'Locked source',
    sourcePath: sourcePath,
    metadata: const {'durationMs': 8000, 'hasAudio': true},
  );
  final timeline = EditorTimeline(
    assets: [asset],
    tracks: [
      TimelineTrack(
        id: 'locked-video',
        name: 'Video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        isLocked: true,
        clips: [
          TimelineClip(
            id: 'locked-clip',
            trackId: 'locked-video',
            type: TimelineTrackType.video,
            label: 'Locked source',
            assetId: asset.id,
            startTime: Duration.zero,
            endTime: duration,
            sourceDuration: duration,
          ),
        ],
      ),
    ],
  );
  return Project(
    id: 'locked-project',
    name: 'Locked project',
    videoPath: sourcePath,
    durationMs: duration.inMilliseconds,
    timeline: timeline,
  )..cacheVideoAvailability(true);
}
