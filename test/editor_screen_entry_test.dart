import 'dart:async';
import 'dart:io';

import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/core/utils/desktop_window_close_service.dart';
import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/providers/playback_provider.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/editor/screens/editor_screen.dart';
import 'package:caption_craft/features/editor/widgets/subtitle_edit_modal.dart';
import 'package:caption_craft/features/home/screens/home_screen.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory documentsDirectory;

  setUp(() async {
    await ProjectLocalStorage.waitForPendingSavesForTesting();
    documentsDirectory = await Directory.systemTemp.createTemp(
      'captioncraft_editor_widget_',
    );
    ProjectLocalStorage.setDocumentsDirectoryForTesting(documentsDirectory);
  });

  tearDown(() async {
    await ProjectLocalStorage.waitForPendingSavesForTesting();
    ProjectLocalStorage.setDocumentsDirectoryForTesting(null);
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  testWidgets('a newly created project mounts the editor on a phone', (
    tester,
  ) async {
    _setTestView(tester, const Size(390, 844));
    final project = _freshProject();

    await tester.pumpWidget(
      _testApp(home: EditorScreen.withoutPersistence(project: project)),
    );
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
    await _disposeEditorAndDrain(tester);
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
    await _waitForEditorToClose(tester);

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor dock exposes direct tools with one flat overflow sheet', (
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
          home: EditorScreen.withoutPersistence(project: _freshProject()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    container.read(editorProvider.notifier)
      ..selectTrack('track_video_primary')
      ..selectClip('fresh-clip');
    await tester.pump();

    final dock = find.byKey(const ValueKey('editor_tool_dock'));

    Future<void> tapDock(String key) async {
      final target = find.byKey(ValueKey(key));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
    }

    expect(dock, findsOneWidget);
    expect(find.byKey(const ValueKey('editor_primary_tools')), findsOneWidget);
    for (final tool in const {
      'split': 'Split',
      'timing': 'Timing',
      'transform': 'Transform',
      'crop': 'Crop',
      'effects': 'Effects',
      'chroma': 'Chroma',
      'color': 'Color',
      'animation': 'Animate',
      'audio': 'Audio',
      'keyframe': 'Keyframe',
      'duplicate': 'Duplicate',
      'delete': 'Delete',
      'more': 'More',
    }.entries) {
      final target = find.byKey(ValueKey('dock_primary_${tool.key}'));
      expect(target, findsOneWidget);
      expect(
        find.descendant(of: target, matching: find.text(tool.value)),
        findsOneWidget,
      );
    }
    final primaryTools = find.descendant(
      of: dock,
      matching: find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> && key.value.startsWith('dock_primary_');
      }),
    );
    expect(primaryTools, findsNWidgets(13));
    expect(find.byKey(const ValueKey('dock_category_edit')), findsNothing);
    expect(find.byKey(const ValueKey('editor_export_button')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('editor_aspect_ratio_button')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Export')),
      findsNothing,
    );

    await tapDock('dock_primary_more');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('editor_all_tools_sheet')),
      findsOneWidget,
    );
    expect(find.text('All tools'), findsOneWidget);
    expect(find.text('Clip'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('all_tools_clip_attributes_copy_attrs')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('Visual'),
      300,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('editor_all_tools_sheet')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('Visual'), findsOneWidget);
    expect(find.byKey(const ValueKey('dock_back_button')), findsNothing);
    expect(find.byKey(const ValueKey('categories')), findsNothing);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('editor_aspect_ratio_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('resizable_editor_sheet')),
      findsOneWidget,
    );
    expect(find.text('Canvas'), findsOneWidget);
    expect(find.text('Format, background and guides'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposeEditorAndDrain(tester);
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
          home: EditorScreen.withoutPersistence(project: _layeredProject()),
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
    final addMenu = find.byKey(const ValueKey('fixed_editor_sheet'));
    final addText = find.descendant(
      of: addMenu,
      matching: find.text('Add Text'),
    );
    expect(addText, findsOneWidget);
    expect(
      find.descendant(of: addMenu, matching: find.text('Subtitles')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('resizable_sheet_handle')), findsNothing);
    await tester.tap(addText);
    // The add menu closes before the persistent text editor animates in.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('text_editor_field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('text_editor_field')),
      'Direct canvas title',
    );
    await tester.pump();
    expect(find.text('Direct canvas title'), findsWidgets);
    tester.testTextInput.hide();
    await tester.pump(const Duration(milliseconds: 100));
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
    await _disposeEditorAndDrain(tester);
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
    await tester.tap(find.text('Save subtitle'));
    await tester.pumpAndSettle();

    expect(container.read(subtitleProvider).entries.single.text, 'After edit');
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening a project clears stale playback state', (tester) async {
    _setTestView(tester, const Size(1180, 820));
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    container.read(playbackProvider.notifier)
      ..updateDuration(const Duration(seconds: 30))
      ..updatePosition(const Duration(seconds: 17))
      ..requestTransport(PlaybackTransportCommand.playForward);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: EditorScreen.withoutPersistence(project: _freshProject()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(container.read(playbackProvider).position, Duration.zero);
    expect(container.read(playbackProvider).pendingTransportCommand, isNull);
    expect(tester.takeException(), isNull);
    await _disposeEditorAndDrain(tester);
  });

  testWidgets('desktop shortcuts update work range and snapping state', (
    tester,
  ) async {
    _setTestView(tester, const Size(1180, 820));
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: EditorScreen.withoutPersistence(project: _freshProject()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    final shortcutRegion = find.byKey(
      const ValueKey('editor_keyboard_shortcut_focus'),
    );
    final scaffold = find.descendant(
      of: shortcutRegion,
      matching: find.byType(Scaffold),
    );
    Focus.of(tester.element(scaffold)).requestFocus();
    await tester.pump();

    final playback = container.read(playbackProvider.notifier)
      ..updateDuration(const Duration(seconds: 12))
      ..updatePosition(const Duration(seconds: 3));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    expect(
      container.read(editorProvider).timeline.workspaceSettings.workAreaStart,
      const Duration(seconds: 3),
    );

    playback.updatePosition(const Duration(seconds: 8));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    var workspace = container.read(editorProvider).timeline.workspaceSettings;
    expect(workspace.workAreaEnd, const Duration(seconds: 8));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    workspace = container.read(editorProvider).timeline.workspaceSettings;
    expect(workspace.snapping.enabled, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    workspace = container.read(editorProvider).timeline.workspaceSettings;
    expect(workspace.workAreaStart, isNull);
    expect(workspace.workAreaEnd, isNull);

    playback.updatePosition(const Duration(seconds: 8));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    playback.updatePosition(const Duration(seconds: 9));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    workspace = container.read(editorProvider).timeline.workspaceSettings;
    expect(workspace.workAreaStart, const Duration(seconds: 9));
    expect(workspace.workAreaEnd, isNull);

    playback.updatePosition(const Duration(seconds: 4));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    workspace = container.read(editorProvider).timeline.workspaceSettings;
    expect(workspace.workAreaStart, isNull);
    expect(workspace.workAreaEnd, const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
    await _disposeEditorAndDrain(tester);
  });

  testWidgets('back navigation waits for the latest local project save', (
    tester,
  ) async {
    _setTestView(tester, const Size(1180, 820));
    final project = _freshProject();
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const ValueKey('open-editor'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => EditorScreen(project: project),
                    ),
                  ),
                  child: const Text('Open editor'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-editor')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    container
        .read(editorProvider.notifier)
        .setWorkspaceSettings(
          (settings) => settings.copyWith(
            snapping: settings.snapping.copyWith(enabled: false),
          ),
        );
    await tester.pump();
    final shortcutRegion = find.byKey(
      const ValueKey('editor_keyboard_shortcut_focus'),
    );
    final editorScaffold = find.descendant(
      of: shortcutRegion,
      matching: find.byType(Scaffold),
    );
    Focus.of(tester.element(editorScaffold)).requestFocus();
    await tester.pump();
    await tester.pageBack();
    await tester.pump();
    expect(
      find.byType(EditorScreen),
      findsOneWidget,
      reason: 'The route must remain mounted until its local write completes.',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    expect(
      container
          .read(editorProvider)
          .timeline
          .workspaceSettings
          .snapping
          .enabled,
      isFalse,
      reason: 'Keyboard edits must be blocked after the exit save begins.',
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _waitForEditorToClose(tester);

    expect(find.byType(EditorScreen), findsNothing);
    final saved = await tester.runAsync(
      () => ProjectLocalStorage.loadProject(project.id),
    );
    expect(saved, isNotNull);
    expect(saved!.timeline.workspaceSettings.snapping.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native Windows close waits for the latest local project save', (
    tester,
  ) async {
    _setTestView(tester, const Size(1180, 820));
    final project = _freshProject();
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: EditorScreen(project: project),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    container
        .read(editorProvider.notifier)
        .setWorkspaceSettings(
          (settings) => settings.copyWith(
            snapping: settings.snapping.copyWith(enabled: false),
          ),
        );
    await tester.pump();

    final closeRequest = DesktopWindowCloseService.requestCloseForTesting();
    bool? closeAllowed;
    Object? closeError;
    unawaited(
      closeRequest.then<void>(
        (value) => closeAllowed = value,
        onError: (Object error) => closeError = error,
      ),
    );
    for (var attempt = 0; attempt < 40 && closeAllowed == null; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(closeError, isNull);
    expect(closeAllowed, isTrue);
    expect(
      find.byType(EditorScreen),
      findsOneWidget,
      reason: 'The native runner owns process shutdown after save approval.',
    );

    final saved = await tester.runAsync(
      () => ProjectLocalStorage.loadProject(project.id),
    );
    expect(saved, isNotNull);
    expect(saved!.timeline.workspaceSettings.snapping.enabled, isFalse);
    expect(tester.takeException(), isNull);

    await _disposeEditorAndDrain(tester);
    expect(
      await DesktopWindowCloseService.requestCloseForTesting(),
      isTrue,
      reason: 'With no editor mounted, Windows can close immediately.',
    );
  });

  testWidgets('a failed exit save keeps the editor open unless confirmed', (
    tester,
  ) async {
    _setTestView(tester, const Size(1180, 820));
    final blockedPath =
        '${documentsDirectory.path}${Platform.pathSeparator}not_a_directory';
    await tester.runAsync(() => File(blockedPath).writeAsString('blocked'));
    ProjectLocalStorage.setDocumentsDirectoryForTesting(Directory(blockedPath));

    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                key: const ValueKey('open-editor-with-blocked-storage'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => EditorScreen(project: _freshProject()),
                  ),
                ),
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('open-editor-with-blocked-storage')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await tester.pageBack();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _waitForText(tester, 'Project could not be saved');
    expect(find.text('Project could not be saved'), findsOneWidget);
    expect(find.byType(EditorScreen), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await tester.pump();
    expect(find.byType(EditorScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _waitForText(tester, 'Project could not be saved');
    await tester.tap(find.text('Leave without saving'));
    await tester.pump();
    await _waitForEditorToClose(tester);
    expect(find.byType(EditorScreen), findsNothing);
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

Future<void> _waitForEditorToClose(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (find.byType(EditorScreen).evaluate().isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('Editor did not close after its bounded save wait.');
}

Future<void> _disposeEditorAndDrain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.runAsync(ProjectLocalStorage.waitForPendingSavesForTesting);
}

Future<void> _waitForText(WidgetTester tester, String text) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.text(text).evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  fail('Timed out waiting for "$text".');
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
