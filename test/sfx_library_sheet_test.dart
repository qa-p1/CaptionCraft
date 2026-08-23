import 'dart:async';
import 'dart:io';

import 'package:caption_craft/core/constants/asset_pack_constants.dart';
import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/core/utils/asset_pack_service.dart';
import 'package:caption_craft/features/editor/models/asset_pack_models.dart';
import 'package:caption_craft/features/editor/models/sound_effect_library_asset.dart';
import 'package:caption_craft/features/editor/providers/asset_pack_provider.dart';
import 'package:caption_craft/features/editor/widgets/sfx_library_sheet.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('does not request Openverse when the sheet opens', (
    tester,
  ) async {
    var requests = 0;
    final launched = <Uri>[];

    await _pumpSheet(
      tester,
      search: (query, filter) async {
        requests++;
        return const [];
      },
      externalUrlLauncher: (uri) async {
        launched.add(uri);
        return true;
      },
    );

    expect(requests, 0);
    expect(find.byKey(const ValueKey('sfx-library-online-ready')), findsOne);
    expect(
      find.text(
        'Made using Openverse. Openverse does not endorse CaptionCraft.',
      ),
      findsOne,
    );

    await tester.tap(
      find.byKey(const ValueKey('sfx-library-openverse-notice')),
    );
    await tester.pump();
    expect(launched.single, Uri.parse('https://openverse.org/'));
    expect(requests, 0);
  });

  testWidgets('search and filter run only after explicit submit', (
    tester,
  ) async {
    final calls = <({String query, OpenverseLicenseFilter filter})>[];
    final selected = <SoundEffectLibraryAsset>[];
    final previewed = <SoundEffectLibraryAsset>[];
    var stoppedPreviews = 0;

    await _pumpSheet(
      tester,
      search: (query, filter) async {
        calls.add((query: query, filter: filter));
        return const [_onlineAsset];
      },
      onOnlineAssetSelected: (asset) async => selected.add(asset),
      onOnlineAssetPreview: (asset) async => previewed.add(asset),
      onStopPreview: () async => stoppedPreviews++,
    );

    await tester.enterText(
      find.byKey(const ValueKey('sfx-library-openverse-search')),
      '  thunder  ',
    );
    await tester.pump(const Duration(seconds: 1));
    expect(calls, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey('sfx-library-filter-public-domain')),
    );
    await tester.pump();
    expect(calls, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey('sfx-library-openverse-submit')),
    );
    await tester.pumpAndSettle();

    expect(calls, [
      (query: 'thunder', filter: OpenverseLicenseFilter.publicDomain),
    ]);
    expect(
      find.byKey(const ValueKey('sfx-library-online-result-openverse-one')),
      findsOne,
    );
    expect(find.text('CC0 1.0'), findsWidgets);
    expect(find.text('Sound Author'), findsOne);

    final preview = find.byKey(
      const ValueKey('sfx-library-online-preview-openverse-one'),
    );
    await tester.ensureVisible(preview);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(previewed, [_onlineAsset]);
    expect(find.byTooltip('Stop preview'), findsOne);

    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(stoppedPreviews, 1);
    expect(find.byTooltip('Preview'), findsOne);

    final add = find.byKey(
      const ValueKey('sfx-library-online-add-openverse-one'),
    );
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(selected, [_onlineAsset]);
  });

  testWidgets('always exposes Openverse and the manifest-driven local pack', (
    tester,
  ) async {
    await _pumpSheet(tester);

    expect(find.text('Openverse'), findsWidgets);
    expect(find.text('Local SFX'), findsOne);
    expect(find.byKey(const ValueKey('sfx-library-navigation')), findsOne);
    expect(find.byKey(const ValueKey('sfx-library-nav-openverse')), findsOne);
    expect(find.byKey(const ValueKey('sfx-library-nav-local')), findsOne);
    expect(find.text('Local SFX'), findsOne);
  });

  testWidgets('local pack remains local-only until Download is tapped', (
    tester,
  ) async {
    final packs = _FakeAssetPackFacade();
    await _pumpSheet(tester, packs: packs);

    expect(
      packs.getInstalledCalls,
      contains(AssetPackConstants.soundEffectsId),
    );
    expect(packs.getReleaseCalls, isEmpty);
    expect(packs.installCalls, isEmpty);

    await tester.tap(find.byKey(const ValueKey('sfx-library-nav-local')));
    await tester.pumpAndSettle();

    expect(packs.getReleaseCalls, [AssetPackConstants.soundEffectsId]);
    expect(packs.installCalls, isEmpty);
    final download = find.byKey(
      const ValueKey('asset-pack-download-sound-effects'),
    );
    expect(download, findsOne);

    await tester.pump(const Duration(seconds: 1));
    expect(packs.installCalls, isEmpty);

    await tester.drag(
      find.byKey(const ValueKey('asset-pack-panel-scroll-sound-effects')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(packs.installCalls, [AssetPackConstants.soundEffectsId]);
  });

  testWidgets('sheet dismissal keeps the job alive and Stop cancels it', (
    tester,
  ) async {
    final installCompleter = Completer<AssetPackCatalog>();
    final packs = _FakeAssetPackFacade(installCompleter: installCompleter);
    final container = ProviderContainer(
      overrides: [assetPackFacadeProvider.overrideWithValue(packs)],
    );
    addTearDown(container.dispose);
    await _pumpSheet(tester, packs: packs, container: container);

    await tester.tap(find.byKey(const ValueKey('sfx-library-nav-local')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('asset-pack-panel-scroll-sound-effects')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('asset-pack-download-sound-effects')),
    );
    await tester.pump();
    expect(packs.lastInstallCancelToken, isNotNull);
    expect(packs.lastInstallCancelToken!.isCancelled, isFalse);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox()),
      ),
    );
    await tester.pump();
    expect(packs.lastInstallCancelToken!.isCancelled, isFalse);

    await _pumpSheet(tester, packs: packs, container: container, settle: false);
    await tester.tap(find.byKey(const ValueKey('sfx-library-nav-local')));
    await tester.pump(const Duration(milliseconds: 250));
    final stop = find.byKey(const ValueKey('asset-pack-stop-sound-effects'));
    await tester.ensureVisible(stop);
    await tester.tap(stop);
    await tester.pump();
    expect(packs.lastInstallCancelToken!.isCancelled, isTrue);
    installCompleter.completeError(const AssetPackException.cancelled());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('asset-pack-retry-sound-effects')),
      findsOne,
    );
  });

  testWidgets('renders a friendly Openverse rate-limit error', (tester) async {
    await _pumpSheet(
      tester,
      search: (query, filter) async {
        final request = RequestOptions(path: '/audio/');
        throw DioException(
          requestOptions: request,
          response: Response<void>(requestOptions: request, statusCode: 429),
        );
      },
    );

    await tester.enterText(
      find.byKey(const ValueKey('sfx-library-openverse-search')),
      'impact',
    );
    await tester.tap(
      find.byKey(const ValueKey('sfx-library-openverse-submit')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Openverse is receiving too many requests. Please wait a moment and try again.',
      ),
      findsOne,
    );
    expect(find.byKey(const ValueKey('sfx-library-online-retry')), findsOne);
  });

  testWidgets('installed local sounds support search, category and Add', (
    tester,
  ) async {
    final packs = _FakeAssetPackFacade(installedCatalog: _installedCatalog());
    final selected = <AssetPackCatalogItem>[];
    await _pumpSheet(
      tester,
      packs: packs,
      onPackAssetSelected: (item) async => selected.add(item),
    );

    await tester.tap(find.byKey(const ValueKey('sfx-library-nav-local')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('sfx-library-pack-result-local-hit')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('sfx-library-pack-filter-impacts')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('asset-pack-remove-sound-effects')),
      findsOne,
    );

    await tester.enterText(
      find.byKey(const ValueKey('sfx-library-pack-search')),
      'hit',
    );
    await tester.pump();
    final add = find.byKey(const ValueKey('sfx-library-pack-add-local-hit'));
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(selected.single.id, 'local-hit');
  });
}

const _onlineAsset = SoundEffectLibraryAsset(
  id: 'openverse-one',
  title: 'Rolling thunder',
  previewUrl: 'https://cdn.example.test/thunder.mp3',
  downloadUrl: 'https://cdn.example.test/thunder.mp3',
  provider: SoundEffectLibraryProvider.openverse,
  duration: Duration(seconds: 7),
  fileSizeBytes: 2048,
  fileExtension: 'mp3',
  attribution: 'Rolling thunder by Sound Author, CC0 1.0',
  licenseCode: 'cc0',
  licenseVersion: '1.0',
  licenseUrl: 'https://creativecommons.org/publicdomain/zero/1.0/',
  sourceName: 'Freesound',
  sourcePageUrl: 'https://example.test/sounds/one',
  creatorName: 'Sound Author',
  creatorPageUrl: 'https://example.test/people/author',
  tags: ['thunder', 'storm'],
);

Future<void> _pumpSheet(
  WidgetTester tester, {
  OpenverseSfxSearchCallback? search,
  AssetPackFacade? packs,
  OnlineSoundEffectSelected? onOnlineAssetSelected,
  PackSoundEffectSelected? onPackAssetSelected,
  OnlineSoundEffectPreview? onOnlineAssetPreview,
  StopSoundEffectPreview? onStopPreview,
  SfxExternalUrlLauncher? externalUrlLauncher,
  ProviderContainer? container,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 820));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final facade = packs ?? _FakeAssetPackFacade();
  final app = MaterialApp(
    theme: AppTheme.darkTheme,
    home: Scaffold(
      body: SfxLibrarySheet(
        openverseSearch: search ?? (query, filter) async => const [],
        externalUrlLauncher: externalUrlLauncher ?? (_) async => true,
        onOnlineAssetSelected: onOnlineAssetSelected ?? (_) async {},
        onPackAssetSelected: onPackAssetSelected ?? (_) async {},
        onOnlineAssetPreview: onOnlineAssetPreview,
        onStopPreview: onStopPreview,
        onClose: () {},
      ),
    ),
  );
  await tester.pumpWidget(
    container == null
        ? ProviderScope(
            overrides: [assetPackFacadeProvider.overrideWithValue(facade)],
            child: app,
          )
        : UncontrolledProviderScope(container: container, child: app),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

class _FakeAssetPackFacade implements AssetPackFacade {
  final AssetPackCatalog? installedCatalog;
  final Completer<AssetPackCatalog>? installCompleter;
  final List<String> getInstalledCalls = <String>[];
  final List<String> getReleaseCalls = <String>[];
  final List<String> installCalls = <String>[];
  CancelToken? lastInstallCancelToken;

  _FakeAssetPackFacade({this.installedCatalog, this.installCompleter});

  @override
  Future<AssetPackCatalog?> getInstalledCatalog(String packId) async {
    getInstalledCalls.add(packId);
    return installedCatalog;
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
      archiveUri: Uri.parse('https://assets.example.test/sound-effects.zip'),
      sha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      archiveBytes: 1024 * 1024,
      installedBytes: 2 * 1024 * 1024,
      catalogPath: 'catalog.json',
      title: 'Sound effects',
      description: 'A rights-cleared local SFX pack.',
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
    lastInstallCancelToken = cancelToken;
    final pending = installCompleter;
    if (pending != null) return pending.future;
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
    return AssetPackCatalog(
      id: packId,
      title: 'Sound effects',
      version: 'test',
      installationDirectory: Directory.systemTemp,
      items: const [],
      categoryIds: const [],
      categoryNames: const {},
    );
  }
}

AssetPackCatalog _installedCatalog() {
  final directory = Directory.systemTemp;
  final item = AssetPackCatalogItem(
    packId: AssetPackConstants.soundEffectsId,
    packVersion: 'test',
    id: 'local-hit',
    title: 'Heavy hit',
    categoryId: 'impacts',
    categoryName: 'Impacts',
    mediaKind: AssetPackMediaKind.audio,
    relativePath: 'media/heavy-hit.mp3',
    previewRelativePath: null,
    sizeBytes: 1024,
    width: null,
    height: null,
    duration: const Duration(seconds: 2),
    hasAudio: true,
    tags: const ['hit', 'impact'],
    metadata: const {},
    installationDirectory: directory,
  );
  return AssetPackCatalog(
    id: AssetPackConstants.soundEffectsId,
    title: 'Sound effects',
    version: 'test',
    installationDirectory: directory,
    items: [item],
    categoryIds: const ['impacts'],
    categoryNames: const {'impacts': 'Impacts'},
  );
}
