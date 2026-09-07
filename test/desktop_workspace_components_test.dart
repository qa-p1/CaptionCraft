import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/services/desktop_workspace_preferences.dart';
import 'package:caption_craft/features/editor/widgets/desktop_inspector_panel.dart';
import 'package:caption_craft/features/editor/widgets/desktop_splitter.dart';
import 'package:caption_craft/features/editor/widgets/desktop_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop workspace preferences', () {
    test(
      'rejects nonfinite persisted strings and queues latest writes',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'captioncraft_workspace_preferences_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = DesktopWorkspacePreferencesStore(
          directoryProvider: () async => directory,
        );

        final parsed = DesktopWorkspacePreferences.fromJson({
          'leftPanelWidth': 'NaN',
          'rightPanelWidth': 'Infinity',
          'timelineHeight': '-Infinity',
        });
        expect(
          parsed.leftPanelWidth,
          DesktopWorkspacePreferences.defaultLeftPanelWidth,
        );
        expect(
          parsed.rightPanelWidth,
          DesktopWorkspacePreferences.defaultRightPanelWidth,
        );
        expect(
          parsed.timelineHeight,
          DesktopWorkspacePreferences.defaultTimelineHeight,
        );

        final first = parsed.copyWith(leftPanelWidth: 200);
        final latest = parsed.copyWith(leftPanelWidth: 392);
        await Future.wait([store.save(first), store.save(latest)]);
        final loaded = await store.load();
        expect(loaded.leftPanelWidth, 392);
      },
    );
  });

  testWidgets('splitter exposes hover state and sends mouse deltas', (
    tester,
  ) async {
    final deltas = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: SizedBox(
          width: 160,
          height: 80,
          child: DesktopSplitter(
            axis: DesktopSplitterAxis.vertical,
            semanticsLabel: 'Media width',
            onDelta: deltas.add,
          ),
        ),
      ),
    );

    final line = find.byType(AnimatedContainer);
    Color? lineColor() =>
        (tester.widget<AnimatedContainer>(line).decoration as BoxDecoration?)
            ?.color;
    expect(lineColor(), kBorder);
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(
      location: tester.getCenter(find.byType(DesktopSplitter)),
    );
    await hover.moveTo(tester.getCenter(find.byType(DesktopSplitter)));
    await tester.pump();
    expect(lineColor(), kAccent);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(DesktopSplitter)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(13, 0));
    await tester.pump();
    await gesture.up();
    expect(deltas, contains(13));
  });

  testWidgets('compact workspace reveals one side panel at a time', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 520);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: DesktopWorkspace(
          preferencesStore: _MemoryPreferencesStore(),
          mediaPanel: const ColoredBox(
            key: ValueKey('media_panel_content'),
            color: Colors.blue,
            child: Center(child: Text('Media panel content')),
          ),
          viewer: const ColoredBox(
            key: ValueKey('viewer_content'),
            color: Colors.black,
            child: Center(child: Text('Viewer content')),
          ),
          inspectorPanel: const ColoredBox(
            key: ValueKey('inspector_panel_content'),
            color: Colors.green,
            child: Center(child: Text('Inspector panel content')),
          ),
          timeline: const ColoredBox(
            key: ValueKey('timeline_content'),
            color: Colors.orange,
            child: Center(child: Text('Timeline content')),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 30));

    expect(find.byKey(const ValueKey('media_panel_content')), findsNothing);
    expect(find.byKey(const ValueKey('inspector_panel_content')), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('desktop_workspace_media_toggle')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('media_panel_content')), findsOneWidget);
    expect(find.byKey(const ValueKey('inspector_panel_content')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('desktop_workspace_inspector_toggle')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('media_panel_content')), findsNothing);
    expect(
      find.byKey(const ValueKey('inspector_panel_content')),
      findsOneWidget,
    );
  });

  testWidgets('inspector refreshes unfocused values and commits blur/cancel', (
    tester,
  ) async {
    final key = GlobalKey<_InspectorHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(body: _InspectorHarness(key: key)),
      ),
    );
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(5));
    TextEditingController controllerAt(int index) =>
        tester.widget<TextField>(fields.at(index)).controller!;

    expect(controllerAt(0).text, '10');
    expect(controllerAt(1).text, '20');
    await tester.tap(fields.at(2));
    await tester.enterText(fields.at(2), '2.5');
    key.currentState!.replaceTransform(
      key.currentState!.transform.copyWith(offsetX: 99, scale: 3),
    );
    await tester.pump();
    expect(controllerAt(0).text, '99');
    expect(controllerAt(2).text, '2.5');

    await tester.tap(fields.at(0));
    await tester.enterText(fields.at(0), '42');
    await tester.tap(fields.at(1));
    await tester.pump();
    expect(key.currentState!.transform.offsetX, 42);

    await tester.enterText(fields.at(1), '88');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controllerAt(1).text, '20');
    expect(key.currentState!.transform.offsetY, 20);

    await tester.tap(fields.at(3));
    await tester.enterText(fields.at(3), 'NaN');
    await tester.tap(fields.at(4));
    await tester.pump();
    expect(controllerAt(3).text, '45');
  });
}

class _InspectorHarness extends StatefulWidget {
  const _InspectorHarness({super.key});

  @override
  State<_InspectorHarness> createState() => _InspectorHarnessState();
}

class _MemoryPreferencesStore extends DesktopWorkspacePreferencesStore {
  _MemoryPreferencesStore() : super(fileName: 'unused.json');

  DesktopWorkspacePreferences value = const DesktopWorkspacePreferences();

  @override
  Future<DesktopWorkspacePreferences> load() async => value;

  @override
  Future<void> save(DesktopWorkspacePreferences preferences) async {
    value = preferences;
  }
}

class _InspectorHarnessState extends State<_InspectorHarness> {
  TimelineTransform transform = const TimelineTransform(
    offsetX: 10,
    offsetY: 20,
    scale: 1.5,
    rotation: math.pi / 4,
    opacity: 0.8,
  );

  TimelineClip get clip => TimelineClip(
    id: 'inspector-clip',
    trackId: 'video-track',
    type: TimelineTrackType.video,
    label: 'Inspector clip',
    startTime: Duration.zero,
    endTime: const Duration(seconds: 10),
    transform: transform,
  );

  void replaceTransform(TimelineTransform next) {
    setState(() => transform = next);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 340,
      height: 700,
      child: DesktopInspectorPanel(
        clip: clip,
        track: TimelineTrack(
          id: 'video-track',
          name: 'Video',
          type: TimelineTrackType.video,
          clips: [clip],
        ),
        playheadPosition: const Duration(seconds: 1),
        canEdit: true,
        canAdjustAudio: true,
        canOpenEffects: false,
        canAnimate: false,
        canOpenTiming: false,
        canEditCaptions: false,
        onTransformChanged: (mapper, _) => replaceTransform(mapper(transform)),
      ),
    );
  }
}
