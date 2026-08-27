import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/screens/editor_screen.dart';
import 'package:caption_craft/features/editor/widgets/subtitle_edit_modal.dart';
import 'package:caption_craft/features/home/screens/home_screen.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  testWidgets('progressive dock drills from categories to grouped tools', (
    tester,
  ) async {
    _setTestView(tester, const Size(390, 844));
    await tester.pumpWidget(
      _testApp(home: EditorScreen(project: _freshProject())),
    );
    await tester.pump(const Duration(milliseconds: 600));

    final dock = find.byKey(const ValueKey('editor_tool_dock'));
    Finder inDock(Finder matching) =>
        find.descendant(of: dock, matching: matching);

    Future<void> tapDock(String key) async {
      final target = find.byKey(ValueKey(key));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
    }

    expect(dock, findsOneWidget);
    expect(find.byKey(const ValueKey('categories')), findsOneWidget);
    for (final category in const {
      'edit': 'Edit',
      'effects': 'Effects',
      'keyframes': 'Keyframes',
      'audio': 'Audio',
      'text': 'Text',
      'timeline': 'Timeline',
      'canvas': 'Canvas',
      'studio': 'Studio',
      'discover': 'Discover',
    }.entries) {
      expect(
        find.byKey(ValueKey('dock_category_${category.key}')),
        findsOneWidget,
      );
      expect(inDock(find.text(category.value)), findsOneWidget);
    }
    final editCategory = find.byKey(const ValueKey('dock_category_edit'));
    expect(tester.getSize(editCategory).width, 72);
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: editCategory,
              matching: find.byIcon(Icons.content_cut_rounded),
            ),
          )
          .size,
      22,
    );
    final categoryScroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('categories')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(categoryScroll.position.maxScrollExtent, greaterThan(0));
    expect(find.byKey(const ValueKey('editor_export_button')), findsOneWidget);
    expect(find.byTooltip('Editor tools'), findsNothing);
    expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
    expect(find.text('Creator Lab'), findsNothing);

    // Timeline track controls already own creation and the toolbar owns the
    // selected-clip split action, so the dock root must not repeat them.
    for (final duplicate in const ['Overlay', 'Add Text', 'Split', 'Add']) {
      expect(inDock(find.text(duplicate)), findsNothing);
    }

    await tapDock('dock_category_edit');
    expect(find.byKey(const ValueKey('subgroups_edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('categories')), findsNothing);
    expect(find.byKey(const ValueKey('dock_back_button')), findsOneWidget);
    for (final subgroup in const [
      'editTiming',
      'editTransform',
      'editDetails',
    ]) {
      expect(find.byKey(ValueKey('dock_subgroup_$subgroup')), findsOneWidget);
    }

    await tapDock('dock_subgroup_editTransform');
    expect(find.byKey(const ValueKey('tools_editTransform')), findsOneWidget);
    expect(find.byKey(const ValueKey('subgroups_edit')), findsNothing);
    expect(find.byKey(const ValueKey('dock_back_button')), findsOneWidget);
    for (final tool in const ['inspector', 'crop']) {
      expect(
        find.byKey(ValueKey('dock_tool_edit_editTransform_$tool')),
        findsOneWidget,
      );
    }

    await tapDock('dock_back_button');
    expect(find.byKey(const ValueKey('subgroups_edit')), findsOneWidget);
    await tapDock('dock_back_button');
    expect(find.byKey(const ValueKey('categories')), findsOneWidget);

    await tapDock('dock_category_effects');
    for (final subgroup in const [
      'effectsColor',
      'effectsBlur',
      'effectsMotion',
      'effectsEnhance',
    ]) {
      expect(find.byKey(ValueKey('dock_subgroup_$subgroup')), findsOneWidget);
    }
    await tapDock('dock_subgroup_effectsColor');
    for (final tool in const ['chroma_key', 'filters', 'adjust']) {
      expect(
        find.byKey(ValueKey('dock_tool_effects_effectsColor_$tool')),
        findsOneWidget,
      );
    }
    await tapDock('dock_back_button');
    await tapDock('dock_back_button');

    await tapDock('dock_category_keyframes');
    for (final subgroup in const [
      'keyframeControls',
      'keyframeCurves',
      'keyframeProperties',
    ]) {
      expect(find.byKey(ValueKey('dock_subgroup_$subgroup')), findsOneWidget);
    }
    await tapDock('dock_subgroup_keyframeControls');
    for (final tool in const ['add_state', 'delete', 'previous', 'next']) {
      expect(
        find.byKey(ValueKey('dock_tool_keyframes_keyframeControls_$tool')),
        findsOneWidget,
      );
    }
    await tapDock('dock_back_button');
    await tapDock('dock_subgroup_keyframeCurves');
    for (final tool in const ['graph', 'presets', 'clear_all']) {
      expect(
        find.byKey(ValueKey('dock_tool_keyframes_keyframeCurves_$tool')),
        findsOneWidget,
      );
    }
    await tapDock('dock_back_button');
    await tapDock('dock_back_button');

    await tapDock('dock_category_text');
    for (final subgroup in const ['textObjects', 'textCaptions', 'textFiles']) {
      expect(find.byKey(ValueKey('dock_subgroup_$subgroup')), findsOneWidget);
    }
    await tapDock('dock_subgroup_textCaptions');
    expect(
      find.byKey(const ValueKey('dock_tool_text_textCaptions_style')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('dock_tool_text_textCaptions_workshop')),
      findsOneWidget,
    );
    await tapDock('dock_back_button');
    await tapDock('dock_back_button');

    // Canvas, Studio, and Discover are intentionally large, direct
    // destinations. Discover has its own injected sheet coverage so this
    // editor smoke test does not instantiate a native platform WebView.
    await tapDock('dock_category_canvas');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('resizable_editor_sheet')),
      findsOneWidget,
    );
    expect(find.text('Format, background and guides'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tapDock('dock_category_studio');
    await tester.pumpAndSettle();
    expect(find.text('Creator Lab'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact add choices stay fixed and libraries resize', (
    tester,
  ) async {
    _setTestView(tester, const Size(390, 844));
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: EditorScreen(project: _layeredProject()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));

    await tester.tap(
      find.byKey(const ValueKey('timeline_track_add_overlay-primary')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Add overlay'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Videos'), findsOneWidget);
    expect(find.text('GIF'), findsNothing);
    expect(find.text('Elements'), findsOneWidget);
    expect(find.byKey(const ValueKey('fixed_editor_sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('resizable_sheet_handle')), findsNothing);
    await tester.ensureVisible(find.text('Elements'));
    await tester.tap(find.text('Elements'));
    await tester.pumpAndSettle();
    expect(find.text('Library placeholder'), findsNothing);
    expect(
      find.byKey(const ValueKey('element-library-navigation')),
      findsOneWidget,
    );
    for (final destination in const [
      'GIPHY',
      'Pexels',
      'Pixabay',
      'BG Videos',
      'Overlays',
    ]) {
      expect(find.text(destination), findsOneWidget);
    }
    expect(
      find.byKey(const ValueKey('resizable_sheet_handle')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('timeline_track_add_text-primary')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Add Text'), findsOneWidget);
    expect(find.text('Subtitles'), findsOneWidget);
    expect(find.byKey(const ValueKey('resizable_sheet_handle')), findsNothing);
    await tester.tap(find.text('Add Text'));
    // The add menu closes before the persistent text editor animates in.
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('text_editor_field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('text_editor_field')),
      'Direct canvas title',
    );
    await tester.pump();
    expect(find.text('Direct canvas title'), findsWidgets);
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('text_editor_done')));
    await tester.pumpAndSettle();

    final editorNotifier = container.read(editorProvider.notifier);
    expect(
      container
          .read(editorProvider)
          .timeline
          .tracks
          .where((track) => track.type == TimelineTrackType.text)
          .expand((track) => track.clips)
          .single
          .text,
      'Direct canvas title',
    );
    editorNotifier.undo();
    expect(
      container
          .read(editorProvider)
          .timeline
          .tracks
          .where((track) => track.type == TimelineTrackType.text)
          .expand((track) => track.clips),
      isEmpty,
    );
    editorNotifier.redo();

    await tester.tap(
      find.byKey(const ValueKey('timeline_track_add_source-audio')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Select a local track'), findsOneWidget);
    expect(find.text('SFX'), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(find.byKey(const ValueKey('resizable_sheet_handle')), findsNothing);
    await tester.ensureVisible(find.text('SFX'));
    await tester.tap(find.text('SFX'));
    await tester.pumpAndSettle();
    expect(find.text('Sound effects'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sfx-library-openverse-search')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sfx-library-openverse-notice')),
      findsOneWidget,
    );
    expect(find.text('Library placeholder'), findsNothing);
    expect(
      find.byKey(const ValueKey('resizable_sheet_handle')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('timeline_track_add_source-audio')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Music'));
    await tester.tap(find.text('Music'));
    await tester.pumpAndSettle();
    expect(find.text('Library placeholder'), findsOneWidget);
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

Project _layeredProject() {
  const duration = Duration(seconds: 12);
  const sourcePath = 'layered-source.mp4';
  final asset = EditorAssetReference(
    id: 'layered-asset',
    type: EditorAssetType.video,
    label: 'Layered source',
    sourcePath: sourcePath,
    metadata: const {'durationMs': 12000, 'hasAudio': true},
  );
  final video = TimelineClip(
    id: 'layered-video',
    trackId: 'source-video',
    type: TimelineTrackType.video,
    label: 'Layered source',
    assetId: asset.id,
    startTime: Duration.zero,
    endTime: duration,
    sourceDuration: duration,
    audioMix: const AudioMixSettings(muted: true),
  );
  final timeline = EditorTimeline(
    assets: [asset],
    tracks: [
      TimelineTrack(
        id: 'text-primary',
        name: 'Text',
        type: TimelineTrackType.text,
        section: TimelineTrackSection.textSubtitle,
      ),
      TimelineTrack(
        id: 'overlay-primary',
        name: 'Overlay',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
      ),
      TimelineTrack(
        id: 'source-video',
        name: 'Source video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        role: TimelineTrackRole.sourceVideo,
        clips: [video],
      ),
      TimelineTrack(
        id: 'source-audio',
        name: 'Source audio',
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        role: TimelineTrackRole.sourceAudio,
        clips: [
          TimelineClip(
            id: 'layered-audio',
            trackId: 'source-audio',
            type: TimelineTrackType.audio,
            label: 'Layered source audio',
            assetId: asset.id,
            linkedClipId: video.id,
            startTime: Duration.zero,
            endTime: duration,
            sourceDuration: duration,
          ),
        ],
      ),
    ],
  );
  return Project(
    id: 'layered-project',
    name: 'Layered editor project',
    videoPath: sourcePath,
    durationMs: duration.inMilliseconds,
    timeline: timeline,
  )..cacheVideoAvailability(true);
}
