import 'dart:async';
import 'dart:io';

import 'package:caption_craft/core/constants/asset_pack_constants.dart';
import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/core/utils/asset_pack_service.dart';
import 'package:caption_craft/core/utils/giphy_service.dart';
import 'package:caption_craft/core/utils/pexels_service.dart';
import 'package:caption_craft/core/utils/pixabay_service.dart';
import 'package:caption_craft/features/editor/models/asset_pack_models.dart';
import 'package:caption_craft/features/editor/providers/asset_pack_provider.dart';
import 'package:caption_craft/features/editor/widgets/element_library_sheet.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows all six destinations on a phone without overflow', (
    tester,
  ) async {
    final packs = _FakeAssetPackFacade();
    await _pumpSheet(tester, packs: packs, surfaceSize: const Size(390, 800));

    expect(find.byKey(const ValueKey('element-library-navigation')), findsOne);
    expect(find.byKey(const ValueKey('element-library-nav-giphy')), findsOne);
    expect(find.byKey(const ValueKey('element-library-nav-pexels')), findsOne);
    expect(find.byKey(const ValueKey('element-library-nav-pixabay')), findsOne);
    expect(
      find.byKey(const ValueKey('element-library-nav-background-videos')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('element-library-nav-overlays')),
      findsOne,
    );
    expect(find.byKey(const ValueKey('element-library-nav-luts')), findsOne);
    expect(find.text('GIPHY'), findsOne);
    expect(find.text('Pexels'), findsOne);
    expect(find.text('Pixabay'), findsOne);
    expect(find.text('BG Videos'), findsOne);
    expect(find.text('Overlays'), findsOne);
    expect(find.text('LUTs'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dedicated LUT library previews and returns installed looks', (
    tester,
  ) async {
    final item = AssetPackCatalogItem(
      packId: AssetPackConstants.lutsId,
      packVersion: 'test',
      id: 'cinematic-look',
      title: 'Cinematic Look',
      categoryId: 'film',
      categoryName: 'Film',
      mediaKind: AssetPackMediaKind.lut,
      relativePath: 'luts/cinematic-look.cube',
      previewRelativePath: 'previews/cinematic-look.jpg',
      sizeBytes: 128,
      width: null,
      height: null,
      duration: null,
      hasAudio: false,
      tags: const ['film'],
      metadata: const {'gridSize': 17},
      installationDirectory: Directory.systemTemp,
    );
    final packs = _FakeAssetPackFacade(
      installedPackIds: const {AssetPackConstants.lutsId},
      installedItems: {
        AssetPackConstants.lutsId: [item],
      },
    );
    AssetPackCatalogItem? selected;

    await _pumpSheet(
      tester,
      packs: packs,
      initialDestination: ElementLibraryDestination.luts,
      showNavigation: false,
      title: 'LUT Library',
      subtitle: 'Preview and apply a look',
      surfaceSize: const Size(390, 800),
      onPackAssetSelected: (item) async => selected = item,
    );

    expect(find.text('LUT Library'), findsOne);
    expect(
      find.byKey(const ValueKey('element-library-navigation')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('element-library-pack-grid-luts')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('element-library-pack-result-cinematic-look')),
      findsOne,
    );
    expect(find.text('Cinematic Look'), findsOne);
    expect(find.text('LUT'), findsOne);
    expect(packs.getReleaseCalls, [AssetPackConstants.lutsId]);
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey('element-library-pack-result-cinematic-look')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(selected?.id, item.id);
  });

  testWidgets('shows and applies each online provider filter set', (
    tester,
  ) async {
    final pexelsFilters = <PexelsMediaFilter>[];
    final pixabayFilters = <PixabayMediaFilter>[];
    await _pumpSheet(
      tester,
      packs: _FakeAssetPackFacade(),
      pexelsSearch: (query, filter) async {
        pexelsFilters.add(filter);
        return const [];
      },
      pixabaySearch: (query, filter) async {
        pixabayFilters.add(filter);
        return const [];
      },
    );

    expect(
      find.byKey(const ValueKey('element-library-filter-giphy-all')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('element-library-filter-giphy-gifs')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('element-library-filter-giphy-stickers')),
      findsOne,
    );

    await tester.tap(find.byKey(const ValueKey('element-library-nav-pexels')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('element-library-filter-pexels-all')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('element-library-filter-pexels-photos')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('element-library-filter-pexels-videos')),
      findsOne,
    );
    await tester.tap(
      find.byKey(const ValueKey('element-library-filter-pexels-videos')),
    );
    await tester.pumpAndSettle();
    expect(pexelsFilters.last, PexelsMediaFilter.videos);

    await tester.tap(find.byKey(const ValueKey('element-library-nav-pixabay')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('element-library-filter-pixabay-all')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('element-library-filter-pixabay-photos')),
      findsOne,
    );
    expect(
      find.byKey(
        const ValueKey('element-library-filter-pixabay-illustrations'),
      ),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('element-library-filter-pixabay-vectors')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('element-library-filter-pixabay-videos')),
      findsOne,
    );
    final vectorFilter = find.byKey(
      const ValueKey('element-library-filter-pixabay-vectors'),
    );
    await tester.ensureVisible(vectorFilter);
    await tester.tap(vectorFilter);
    await tester.pumpAndSettle();
    expect(pixabayFilters.last, PixabayMediaFilter.vectors);
  });

  testWidgets(
    'opening a pack only checks local state until Download is tapped',
    (tester) async {
      final packs = _FakeAssetPackFacade();
      await _pumpSheet(tester, packs: packs);

      await tester.tap(
        find.byKey(const ValueKey('element-library-nav-background-videos')),
      );
      await tester.pumpAndSettle();

      expect(
        packs.getInstalledCalls,
        contains(AssetPackConstants.backgroundVideosId),
      );
      expect(packs.getReleaseCalls, [AssetPackConstants.backgroundVideosId]);
      expect(packs.installCalls, isEmpty);
      final download = find.byKey(
        const ValueKey('asset-pack-download-background-videos'),
      );
      expect(download, findsOne);

      await tester.pump(const Duration(seconds: 1));
      expect(packs.installCalls, isEmpty);

      await tester.drag(
        find.byKey(const ValueKey('asset-pack-panel-scroll-background-videos')),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();
      await tester.tap(download);
      await tester.pumpAndSettle();
      expect(packs.installCalls, [AssetPackConstants.backgroundVideosId]);
    },
  );

  testWidgets('closing and reopening keeps one live pack download', (
    tester,
  ) async {
    final packs = _FakeAssetPackFacade(holdInstallOpen: true);
    final container = ProviderContainer(
      overrides: [assetPackFacadeProvider.overrideWithValue(packs)],
    );
    addTearDown(container.dispose);

    await _pumpSheet(
      tester,
      packs: packs,
      container: container,
      initialDestination: ElementLibraryDestination.backgroundVideos,
      settle: false,
    );
    await tester.drag(
      find.byKey(const ValueKey('asset-pack-panel-scroll-background-videos')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('asset-pack-download-background-videos')),
    );
    await tester.pump();

    expect(packs.installCalls, [AssetPackConstants.backgroundVideosId]);
    expect(packs.lastInstallToken?.isCancelled, isFalse);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    await tester.pump();
    expect(packs.lastInstallToken?.isCancelled, isFalse);

    await _pumpSheet(
      tester,
      packs: packs,
      container: container,
      initialDestination: ElementLibraryDestination.backgroundVideos,
      settle: false,
    );
    expect(
      find.byKey(const ValueKey('asset-pack-stop-background-videos')),
      findsOne,
    );
    expect(packs.installCalls, [AssetPackConstants.backgroundVideosId]);

    packs.finishInstall();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'background and overlay downloads expose the same Remove action',
    (tester) async {
      final packs = _FakeAssetPackFacade(
        installedPackIds: const {
          AssetPackConstants.backgroundVideosId,
          AssetPackConstants.overlaysId,
        },
      );
      await _pumpSheet(
        tester,
        packs: packs,
        initialDestination: ElementLibraryDestination.backgroundVideos,
      );

      expect(
        find.byKey(const ValueKey('asset-pack-remove-background-videos')),
        findsOne,
      );
      await tester.tap(
        find.byKey(const ValueKey('element-library-nav-overlays')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('asset-pack-remove-overlays')),
        findsOne,
      );
    },
  );
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required AssetPackFacade packs,
  PexelsSearchCallback? pexelsSearch,
  PixabaySearchCallback? pixabaySearch,
  ProviderContainer? container,
  ElementLibraryDestination initialDestination =
      ElementLibraryDestination.giphy,
  bool settle = true,
  bool showNavigation = true,
  String title = 'Elements',
  String subtitle = 'Stock media and verified on-demand packs',
  Size surfaceSize = const Size(430, 800),
  PackElementAssetSelected? onPackAssetSelected,
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final app = MaterialApp(
    theme: AppTheme.darkTheme,
    home: Scaffold(
      body: ElementLibrarySheet(
        giphySearch: (query, kind) async => const <GiphyAssetResult>[],
        pexelsSearch: pexelsSearch ?? (query, filter) async => const [],
        pixabaySearch: pixabaySearch ?? (query, filter) async => const [],
        externalUrlLauncher: (_) async => true,
        initialDestination: initialDestination,
        title: title,
        subtitle: subtitle,
        showNavigation: showNavigation,
        onOnlineAssetSelected: (_) async {},
        onPackAssetSelected: onPackAssetSelected ?? (_) async {},
      ),
    ),
  );
  await tester.pumpWidget(
    container == null
        ? ProviderScope(
            overrides: [assetPackFacadeProvider.overrideWithValue(packs)],
            child: app,
          )
        : UncontrolledProviderScope(container: container, child: app),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

class _FakeAssetPackFacade implements AssetPackFacade {
  _FakeAssetPackFacade({
    this.holdInstallOpen = false,
    this.installedPackIds = const <String>{},
    this.installedItems = const <String, List<AssetPackCatalogItem>>{},
  });

  final bool holdInstallOpen;
  final Set<String> installedPackIds;
  final Map<String, List<AssetPackCatalogItem>> installedItems;
  final List<String> getInstalledCalls = <String>[];
  final List<String> getReleaseCalls = <String>[];
  final List<String> installCalls = <String>[];
  final Completer<AssetPackCatalog> _installCompleter =
      Completer<AssetPackCatalog>();
  CancelToken? lastInstallToken;

  @override
  Future<AssetPackCatalog?> getInstalledCatalog(String packId) async {
    getInstalledCalls.add(packId);
    if (!installedPackIds.contains(packId)) return null;
    return AssetPackCatalog(
      id: packId,
      title: _fakePackTitle(packId),
      version: 'test',
      installationDirectory: Directory.systemTemp,
      items: installedItems[packId] ?? const [],
      categoryIds: (installedItems[packId] ?? const [])
          .map((item) => item.categoryId)
          .toSet()
          .toList(),
      categoryNames: {
        for (final item in installedItems[packId] ?? const [])
          item.categoryId: item.categoryName,
      },
    );
  }

  @override
  Future<AssetPackRelease> getRelease(
    String packId, {
    CancelToken? cancelToken,
  }) async {
    getReleaseCalls.add(packId);
    return AssetPackRelease(
      id: packId,
      version: 'test',
      archiveUri: Uri.parse('https://assets.example.test/$packId.zip'),
      sha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      archiveBytes: 1024 * 1024,
      installedBytes: 2 * 1024 * 1024,
      catalogPath: 'db.json',
      title: _fakePackTitle(packId),
      description: 'A test media pack.',
      assetCount: 1,
    );
  }

  @override
  Future<AssetPackCatalog> install(
    String packId, {
    AssetPackRelease? release,
    AssetPackProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    installCalls.add(packId);
    lastInstallToken = cancelToken;
    onProgress?.call(
      const AssetPackProgress(
        phase: AssetPackProgressPhase.downloading,
        receivedBytes: 1,
        totalBytes: 2,
      ),
    );
    onProgress?.call(
      const AssetPackProgress(phase: AssetPackProgressPhase.complete),
    );
    final catalog = AssetPackCatalog(
      id: packId,
      title: _fakePackTitle(packId),
      version: 'test',
      installationDirectory: Directory.systemTemp,
      items: const [],
      categoryIds: const [],
      categoryNames: const {},
    );
    if (holdInstallOpen) return _installCompleter.future;
    return catalog;
  }

  void finishInstall() {
    if (!_installCompleter.isCompleted) {
      final packId = installCalls.last;
      _installCompleter.complete(
        AssetPackCatalog(
          id: packId,
          title: 'Test pack',
          version: 'test',
          installationDirectory: Directory.systemTemp,
          items: const [],
          categoryIds: const [],
          categoryNames: const {},
        ),
      );
    }
  }
}

String _fakePackTitle(String packId) => switch (packId) {
  AssetPackConstants.backgroundVideosId => 'Background videos',
  AssetPackConstants.soundEffectsId => 'Sound effects',
  AssetPackConstants.lutsId => 'LUTs',
  _ => 'Overlays',
};
