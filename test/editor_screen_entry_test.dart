import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/screens/editor_screen.dart';
import 'package:caption_craft/features/editor/widgets/subtitle_edit_modal.dart';
import 'package:caption_craft/features/home/screens/home_screen.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('a newly created project mounts the editor on a phone', (
    tester,
  ) async {
    _setTestView(tester, const Size(390, 844));
    final project = _freshProject();

    await tester.pumpWidget(_testApp(home: EditorScreen(project: project)));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(project.name), findsOneWidget);
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(844, 390);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(320, 568);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a restored legacy project opens from the home screen', (
    tester,
  ) async {
    _setTestView(tester, const Size(1180, 820));
    final project = Project.fromJson({
      'id': 'legacy-project',
      'name': 'Restored legacy edit',
      'videoPath': 'legacy-source.mp4',
      'durationMs': 8000,
      'subtitles': const [],
      'createdAt': '2026-07-20T12:00:00.000',
      'lastModifiedAt': '2026-07-28T12:00:00.000',
    })..cacheVideoAvailability(true);

    await tester.pumpWidget(
      _testApp(home: HomeScreen(initialProjects: [project])),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -450));
    await tester.pumpAndSettle();
    await tester.tap(find.text(project.name));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(EditorScreen), findsOneWidget);
    expect(find.text(project.name), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bottom tools use five groups and at most three subgroups', (
    tester,
  ) async {
    _setTestView(tester, const Size(390, 844));
    await tester.pumpWidget(
      _testApp(home: EditorScreen(project: _freshProject())),
    );
    await tester.pump(const Duration(milliseconds: 600));

    for (final group in const ['Add', 'Edit', 'Effects', 'Audio', 'Canvas']) {
      expect(find.text(group), findsWidgets);
    }

    await tester.tap(find.text('Edit').last);
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('Timing'), findsOneWidget);
    expect(find.text('Transform'), findsOneWidget);
    expect(find.text('Arrange'), findsOneWidget);

    await tester.tap(find.text('Transform'));
    await tester.pump(const Duration(milliseconds: 260));
    for (final tool in const [
      'Crop',
      'Fill',
      'Fit',
      'Stretch',
      'Rotate L',
      'Rotate R',
      'Mirror',
      'Flip V',
      'Reset',
    ]) {
      expect(find.text(tool), findsOneWidget);
    }

    await tester.ensureVisible(find.text('Back').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Effects'));
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('Looks'), findsOneWidget);
    expect(find.text('Blur'), findsOneWidget);
    expect(find.text('Motion'), findsOneWidget);

    await tester.tap(find.text('Blur'));
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('Whole'), findsOneWidget);
    expect(find.text('Region'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('subtitle editor saves before dismiss without dispose errors', (
    tester,
  ) async {
    _setTestView(tester, const Size(390, 844));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final entry = SubtitleEntry(
      id: 'caption-to-edit',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
      text: 'Before edit',
    );
    container
        .read(subtitleProvider.notifier)
        .initializeFromProject(
          entries: [entry],
          globalStyle: const SubtitleStyleModel(),
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(body: SubtitleEditModal(entry: entry)),
        ),
      ),
    );
    await tester.enterText(find.byType(TextFormField), 'After edit');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(container.read(subtitleProvider).entries.single.text, 'After edit');
    expect(tester.takeException(), isNull);
  });
}

Widget _testApp({required Widget home}) {
  return ProviderScope(
    overrides: [currentUserProvider.overrideWithValue(null)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: home,
    ),
  );
}

void _setTestView(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}

Project _freshProject() {
  const duration = Duration(seconds: 12);
  const sourcePath = 'fresh-source.mp4';
  final asset = EditorAssetReference(
    id: 'fresh-asset',
    type: EditorAssetType.video,
    label: 'Fresh source',
    sourcePath: sourcePath,
    metadata: const {
      'durationMs': 12000,
      'width': 1920,
      'height': 1080,
      'hasAudio': true,
      'frameRate': 30,
    },
  );
  final timeline = EditorTimeline(
    assets: [asset],
    tracks: [
      TimelineTrack(
        id: 'track_video_primary',
        name: 'Video 1',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [
          TimelineClip(
            id: 'fresh-clip',
            trackId: 'track_video_primary',
            type: TimelineTrackType.video,
            label: 'Fresh source',
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
    id: 'fresh-project',
    name: 'Fresh editor project',
    videoPath: sourcePath,
    durationMs: duration.inMilliseconds,
    timeline: timeline,
  )..cacheVideoAvailability(true);
}
