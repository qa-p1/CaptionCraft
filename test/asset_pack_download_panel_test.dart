import 'dart:io';

import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/editor/widgets/asset_pack_download_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _backgroundPackId = 'background-videos';
const _downloadBytes = 1008491467;
const _temporarySpaceBytes = 2016966632;

void main() {
  test('formats release sizes for people instead of showing raw bytes', () {
    expect(AssetPackDownloadPanel.formatBytes(999), '999 B');
    expect(AssetPackDownloadPanel.formatBytes(1024), '1.0 KB');
    expect(AssetPackDownloadPanel.formatBytes(1024 * 1024), '1.0 MB');
    expect(
      AssetPackDownloadPanel.formatBytes(3 * 1024 * 1024 * 1024),
      '3.0 GB',
    );
  });

  testWidgets('available state discloses pack facts and starts on demand', (
    tester,
  ) async {
    var downloads = 0;
    await _pumpPanel(
      tester,
      model: _model(
        AssetPackPanelStage.available,
        version: '1.0.0',
        assetCount: 40,
        downloadBytes: _downloadBytes,
        temporarySpaceBytes: _temporarySpaceBytes,
      ),
      onDownload: () => downloads++,
    );

    expect(find.text('Available'), findsOne);
    expect(find.text('Ready when you are'), findsOne);
    expect(find.text('1.0.0'), findsOne);
    expect(find.text('40'), findsOne);
    expect(find.text('961.8 MB'), findsOne);
    expect(find.text('1.9 GB'), findsOne);
    expect(
      find.text(
        'Downloads continue if you close this sheet, while CaptionCraft remains open.',
      ),
      findsOne,
    );

    await tester.tap(
      find.byKey(const ValueKey('asset-pack-download-background-videos')),
    );
    expect(downloads, 1);
  });

  testWidgets('queued and downloading states retain an explicit Stop action', (
    tester,
  ) async {
    var stops = 0;
    await _pumpPanel(
      tester,
      model: _model(
        AssetPackPanelStage.queued,
        queuePosition: 2,
        downloadBytes: _downloadBytes,
      ),
      onStop: () => stops++,
    );

    expect(find.text('Queued'), findsWidgets);
    expect(
      find.text('Queue position 2. It will start automatically.'),
      findsOne,
    );
    expect(find.text('Queue position 2'), findsOne);
    await tester.tap(
      find.byKey(const ValueKey('asset-pack-stop-background-videos')),
    );
    expect(stops, 1);

    await _pumpPanel(
      tester,
      model: _model(
        AssetPackPanelStage.downloading,
        receivedBytes: 504245733,
        totalBytes: _downloadBytes,
        downloadBytes: _downloadBytes,
        partIndex: 0,
        partCount: 2,
      ),
      onStop: () => stops++,
    );

    expect(find.text('Downloading'), findsOne);
    expect(find.text('480.9 MB of 961.8 MB • 50%'), findsOne);
    expect(find.text('Part 1 of 2'), findsOne);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('asset-pack-progress-background-videos')),
    );
    expect(progress.value, closeTo(0.5, 0.001));
    await tester.tap(
      find.byKey(const ValueKey('asset-pack-stop-background-videos')),
    );
    expect(stops, 2);
  });

  testWidgets('post-processing stays visibly complete and remains stoppable', (
    tester,
  ) async {
    const expectations = <AssetPackPanelStage, String>{
      AssetPackPanelStage.verifying: 'Checking integrity…',
      AssetPackPanelStage.extracting: 'Unpacking assets…',
      AssetPackPanelStage.installing: 'Updating local library…',
    };

    for (final entry in expectations.entries) {
      await _pumpPanel(
        tester,
        model: _model(
          entry.key,
          receivedBytes: _downloadBytes,
          totalBytes: _downloadBytes,
        ),
        onStop: () {},
      );

      expect(find.text(entry.value), findsOne);
      expect(find.text('Download complete'), findsOne);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('asset-pack-progress-background-videos')),
      );
      expect(progress.value, 1);
      expect(
        find.byKey(const ValueKey('asset-pack-stop-background-videos')),
        findsOne,
      );
    }
  });

  testWidgets('stopping disables cancellation until cleanup completes', (
    tester,
  ) async {
    await _pumpPanel(
      tester,
      model: _model(AssetPackPanelStage.stopping),
      onStop: () => fail('Stopping must not dispatch another cancellation.'),
    );

    expect(find.text('Stopping…'), findsOne);
    expect(
      find.byKey(const ValueKey('asset-pack-stop-background-videos')),
      findsNothing,
    );
    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('asset-pack-stopping-background-videos')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('cancelled and failed states expose Retry with useful context', (
    tester,
  ) async {
    var retries = 0;
    await _pumpPanel(
      tester,
      model: _model(AssetPackPanelStage.cancelled),
      onRetry: () => retries++,
    );

    expect(find.text('Download stopped'), findsOne);
    expect(
      find.text(
        'The download was stopped. Retry will continue from reusable partial data.',
      ),
      findsOne,
    );
    await tester.tap(
      find.byKey(const ValueKey('asset-pack-retry-background-videos')),
    );
    expect(retries, 1);

    await _pumpPanel(
      tester,
      model: _model(
        AssetPackPanelStage.failed,
        errorMessage: 'The connection closed before the download finished.',
      ),
      onRetry: () => retries++,
    );

    expect(find.text('Download couldn’t finish'), findsOne);
    expect(
      find.text('The connection closed before the download finished.'),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('asset-pack-error-background-videos')),
      findsOne,
    );
    await tester.tap(
      find.byKey(const ValueKey('asset-pack-retry-background-videos')),
    );
    expect(retries, 2);
  });

  testWidgets('installed state is a calm summary without download controls', (
    tester,
  ) async {
    await _pumpPanel(
      tester,
      model: _model(
        AssetPackPanelStage.installed,
        version: '1.0.0',
        assetCount: 40,
        downloadBytes: _downloadBytes,
      ),
    );

    expect(find.text('Installed'), findsOne);
    expect(find.text('Ready to use'), findsOne);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(
      find.byKey(const ValueKey('asset-pack-continuation-background-videos')),
      findsNothing,
    );
  });

  testWidgets('announces status, exact progress, and the Stop action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpPanel(
      tester,
      model: _model(
        AssetPackPanelStage.downloading,
        receivedBytes: 504245733,
        totalBytes: _downloadBytes,
      ),
      onStop: () {},
    );

    expect(find.bySemanticsLabel('Background Videos asset pack'), findsOne);
    final statusNode = tester.getSemantics(
      find.byKey(const ValueKey('asset-pack-status-background-videos')),
    );
    expect(statusNode.getSemanticsData().value, 'Downloading');

    final progressNode = tester.getSemantics(
      find.byKey(const ValueKey('asset-pack-progress-background-videos')),
    );
    expect(
      progressNode.getSemanticsData().label,
      'Background Videos download progress',
    );
    expect(progressNode.getSemanticsData().value, '50');
    final detailsNode = tester.getSemantics(
      find.byKey(
        const ValueKey('asset-pack-progress-details-background-videos'),
      ),
    );
    expect(
      detailsNode.getSemanticsData().value,
      contains('1,008,491,467 bytes total'),
    );
    expect(find.bySemanticsLabel('Stop download'), findsOne);
    semantics.dispose();
  });

  testWidgets('remains scrollable on a narrow screen with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(300, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpPanel(
      tester,
      textScale: 2,
      model: _model(
        AssetPackPanelStage.extracting,
        version: '2026.08.14-long-version',
        assetCount: 54,
        downloadBytes: 768353736,
        temporarySpaceBytes: 1536687360,
        receivedBytes: 768353736,
        totalBytes: 768353736,
      ),
      onStop: () {},
    );

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('asset-pack-panel-scroll-background-videos')),
      findsOne,
    );
    final stop = find.byKey(
      const ValueKey('asset-pack-stop-background-videos'),
    );
    await tester.ensureVisible(stop);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(stop, findsOne);
  });

  testWidgets('shared Remove action confirms and reports success', (
    tester,
  ) async {
    var removals = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Center(
            child: AssetPackRemoveButton(
              packId: _backgroundPackId,
              title: 'Background Videos',
              onRemove: () async => removals++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('asset-pack-remove-background-videos')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove Background Videos?'), findsOne);
    expect(find.textContaining('current or saved project'), findsOne);
    expect(removals, 0);

    await tester.tap(
      find.byKey(const ValueKey('asset-pack-confirm-remove-background-videos')),
    );
    await tester.pumpAndSettle();

    expect(removals, 1);
    expect(find.text('Background Videos removed from this device.'), findsOne);
  });

  testWidgets('shared Remove action surfaces dependency failures', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Center(
            child: AssetPackRemoveButton(
              packId: _backgroundPackId,
              title: 'Background Videos',
              onRemove: () async =>
                  throw StateError('Still used by Project One.'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('asset-pack-remove-background-videos')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('asset-pack-confirm-remove-background-videos')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Still used by Project One.'), findsOne);
  });

  testWidgets(
    'available pack visual regression',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpPanel(
        tester,
        model: _model(
          AssetPackPanelStage.available,
          version: '1.0.0',
          assetCount: 40,
          downloadBytes: _downloadBytes,
          temporarySpaceBytes: _temporarySpaceBytes,
        ),
        onDownload: () {},
      );

      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/asset_pack_download_available.png'),
      );
    },
    // Flutter's text and anti-aliasing rasterization is OS-specific. Linux is
    // the pinned canonical renderer in CI; semantic widget coverage above runs
    // on every platform.
    skip: !Platform.isLinux,
  );
}

AssetPackDownloadViewModel _model(
  AssetPackPanelStage stage, {
  String? version,
  int? assetCount,
  int? downloadBytes,
  int? temporarySpaceBytes,
  int receivedBytes = 0,
  int? totalBytes,
  int? queuePosition,
  int? partIndex,
  int? partCount,
  String? errorMessage,
}) {
  return AssetPackDownloadViewModel(
    packId: _backgroundPackId,
    title: 'Background Videos',
    stage: stage,
    version: version,
    assetCount: assetCount,
    downloadBytes: downloadBytes,
    temporarySpaceBytes: temporarySpaceBytes,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
    queuePosition: queuePosition,
    partIndex: partIndex,
    partCount: partCount,
    errorMessage: errorMessage,
    icon: Icons.video_library_outlined,
  );
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  required AssetPackDownloadViewModel model,
  VoidCallback? onDownload,
  VoidCallback? onStop,
  VoidCallback? onRetry,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.darkTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: AssetPackDownloadPanel(
          model: model,
          onDownload: onDownload,
          onStop: onStop,
          onRetry: onRetry,
        ),
      ),
    ),
  );
  await tester.pump();
}
