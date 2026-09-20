import 'dart:convert';
import 'dart:io';

import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/widgets/desktop_media_panel.dart';
import 'package:caption_craft/features/editor/widgets/source_media_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('media actions share asset identity and protect used assets', (
    tester,
  ) async {
    final asset = EditorAssetReference(
      id: 'pool',
      type: EditorAssetType.video,
      label: 'Pool video',
      isNetworkBacked: true,
    );
    EditorAssetReference? inserted;
    final clip = TimelineClip(
      trackId: 'video',
      type: TimelineTrackType.video,
      label: 'Used clip',
      assetId: asset.id,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: DesktopMediaPanel(
              timeline: EditorTimeline(
                assets: [asset],
                tracks: [
                  TimelineTrack(
                    id: 'video',
                    name: 'Video',
                    type: TimelineTrackType.video,
                    section: TimelineTrackSection.baseVideo,
                    clips: [clip],
                  ),
                ],
              ),
              onInsertAsset: (value) => inserted = value,
              onRemoveAsset: (_) => fail('Used asset must not be removable'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Asset actions'));
    await tester.pumpAndSettle();
    final remove = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Remove from pool'),
    );
    expect(remove.enabled, isFalse);
    await tester.tap(find.text('Insert at playhead'));
    await tester.pumpAndSettle();
    expect(inserted, same(asset));
    expect(tester.takeException(), isNull);
  });

  testWidgets('source range returns In and Out without changing the asset', (
    tester,
  ) async {
    late Directory directory;
    late File file;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('cc-source-viewer-');
      file = File(p.join(directory.path, 'source.png'));
      await file.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
        ),
      );
    });
    addTearDown(() => directory.delete(recursive: true));
    final asset = EditorAssetReference(
      type: EditorAssetType.image,
      label: 'Still image',
      sourcePath: file.path,
    );
    SourceMediaSelection? selection;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selection = await showDialog<SourceMediaSelection>(
                  context: context,
                  builder: (_) => SourceMediaDialog(asset: asset),
                );
              },
              child: const Text('Review source'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review source'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
    expect(slider.onChanged, isNotNull);
    slider.onChanged!(const RangeValues(1000, 2500));
    await tester.pump();
    await tester.tap(find.text('Insert at playhead'));
    await tester.pumpAndSettle();
    expect(selection?.start, const Duration(seconds: 1));
    expect(selection?.duration, const Duration(milliseconds: 1500));
    expect(selection?.append, isFalse);
    expect(asset.metadata, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
