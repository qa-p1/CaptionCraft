import 'dart:async';
import 'dart:io';

import 'package:caption_craft/core/constants/asset_pack_constants.dart';
import 'package:caption_craft/core/utils/asset_pack_service.dart';
import 'package:caption_craft/features/editor/models/asset_pack_models.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/asset_pack_provider.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/widgets/asset_pack_facade.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AssetPackManager', () {
    test(
      'dependency collection includes current and saved audio/visual paths',
      () {
        final paths = collectAssetPackProtectedPaths(
          editor: EditorState(
            videoPath: ' current-base.mp4 ',
            timeline: EditorTimeline(
              assets: [
                EditorAssetReference(
                  id: 'current-audio',
                  type: EditorAssetType.audio,
                  label: 'Current sound',
                  sourcePath: 'current-sound.wav',
                ),
              ],
            ),
          ),
          savedProjects: [
            Project(
              id: 'saved',
              name: 'Saved project',
              videoPath: 'saved-base.gif',
              durationMs: 1000,
              timeline: EditorTimeline(
                assets: [
                  EditorAssetReference(
                    id: 'saved-overlay',
                    type: EditorAssetType.video,
                    label: 'Saved overlay',
                    sourcePath: 'saved-overlay.mp4',
                  ),
                ],
              ),
            ),
          ],
        );

        expect(
          paths,
          equals({
            'current-base.mp4',
            'current-sound.wav',
            'saved-base.gif',
            'saved-overlay.mp4',
          }),
        );
      },
    );

    test(
      'initializes locally and fetches release metadata only on demand',
      () async {
        final facade = _ControlledAssetPackFacade(
          installed: <String, AssetPackCatalog?>{
            AssetPackConstants.backgroundVideosId: _catalog(
              AssetPackConstants.backgroundVideosId,
            ),
          },
        );
        final manager = AssetPackManager(facade);
        addTearDown(manager.dispose);

        await manager.initialize();

        expect(
          facade.getInstalledCalls,
          unorderedEquals(AssetPackManagerState.supportedPackIds),
        );
        expect(facade.getReleaseCalls, isEmpty);
        expect(manager.state.isInitialized, isTrue);
        expect(
          manager.state.pack(AssetPackConstants.backgroundVideosId).status,
          AssetPackDownloadStatus.installed,
        );
        expect(
          manager.state.pack(AssetPackConstants.overlaysId).status,
          AssetPackDownloadStatus.idle,
        );

        await manager.refresh(AssetPackConstants.overlaysId);

        expect(facade.getReleaseCalls, <String>[AssetPackConstants.overlaysId]);
        final overlays = manager.state.pack(AssetPackConstants.overlaysId);
        expect(overlays.status, AssetPackDownloadStatus.available);
        expect(overlays.release?.id, AssetPackConstants.overlaysId);
      },
    );

    test('coalesces each pack and runs one global serial queue', () async {
      final facade = _ControlledAssetPackFacade();
      final manager = AssetPackManager(facade, progressThrottle: Duration.zero);
      addTearDown(manager.dispose);

      final backgroundFirst = manager.enqueue(
        AssetPackConstants.backgroundVideosId,
      );
      final backgroundSecond = manager.enqueue(
        AssetPackConstants.backgroundVideosId,
      );
      final overlays = manager.enqueue(AssetPackConstants.overlaysId);
      final sounds = manager.enqueue(AssetPackConstants.soundEffectsId);

      expect(identical(backgroundFirst, backgroundSecond), isTrue);
      await _eventually(() => facade.installCalls.length == 1);
      expect(
        facade.installCalls.single.packId,
        AssetPackConstants.backgroundVideosId,
      );
      expect(
        manager.state.pack(AssetPackConstants.overlaysId).queuePosition,
        1,
      );
      expect(
        manager.state.pack(AssetPackConstants.soundEffectsId).queuePosition,
        2,
      );

      facade.installCalls[0].complete();
      await backgroundFirst;
      await _eventually(() => facade.installCalls.length == 2);
      expect(facade.installCalls[1].packId, AssetPackConstants.overlaysId);
      expect(
        manager.state.pack(AssetPackConstants.soundEffectsId).queuePosition,
        1,
      );

      facade.installCalls[1].complete();
      await overlays;
      await _eventually(() => facade.installCalls.length == 3);
      expect(facade.installCalls[2].packId, AssetPackConstants.soundEffectsId);
      facade.installCalls[2].complete();
      await sounds;

      expect(facade.getReleaseCalls, hasLength(3));
      expect(facade.installCalls, hasLength(3));
      for (final packId in AssetPackManagerState.supportedPackIds) {
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.installed,
          reason: packId,
        );
      }
    });

    test(
      'direct enqueue discovers an existing current install without downloading',
      () async {
        const packId = AssetPackConstants.overlaysId;
        final catalog = _catalog(packId);
        final facade = _ControlledAssetPackFacade(
          installed: <String, AssetPackCatalog?>{packId: catalog},
        );
        final manager = AssetPackManager(facade);
        addTearDown(manager.dispose);

        await manager.enqueue(packId);

        expect(facade.getReleaseCalls, <String>[packId]);
        expect(facade.installCalls, isEmpty);
        final pack = manager.state.pack(packId);
        expect(pack.status, AssetPackDownloadStatus.installed);
        expect(pack.catalog, same(catalog));
      },
    );

    test(
      'only explicit cancel stops a job and retry uses a fresh attempt',
      () async {
        final facade = _ControlledAssetPackFacade();
        final manager = AssetPackManager(
          facade,
          progressThrottle: Duration.zero,
        );
        addTearDown(manager.dispose);
        const packId = AssetPackConstants.soundEffectsId;

        final firstAttempt = manager.enqueue(packId);
        await _eventually(() => facade.installCalls.length == 1);
        final firstCall = facade.installCalls.single;
        firstCall.emit(
          const AssetPackProgress(
            phase: AssetPackProgressPhase.downloading,
            receivedBytes: 10,
            totalBytes: 100,
          ),
        );
        expect(manager.state.pack(packId).progress?.receivedBytes, 10);

        await manager.cancel(packId);
        await firstAttempt;

        expect(firstCall.cancelToken?.isCancelled, isTrue);
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.cancelled,
        );
        expect(manager.state.pack(packId).canRetry, isTrue);

        final retry = manager.retry(packId);
        await _eventually(() => facade.installCalls.length == 2);
        final secondCall = facade.installCalls.last;
        expect(
          identical(firstCall.cancelToken, secondCall.cancelToken),
          isFalse,
        );

        // A callback retained by an old sheet/service attempt cannot corrupt the
        // fresh operation.
        firstCall.emit(
          const AssetPackProgress(
            phase: AssetPackProgressPhase.verifying,
            receivedBytes: 100,
            totalBytes: 100,
          ),
        );
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.downloading,
        );

        secondCall.complete();
        await retry;
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.installed,
        );
      },
    );

    test(
      'a queued pack can be cancelled without touching the active job',
      () async {
        final facade = _ControlledAssetPackFacade();
        final manager = AssetPackManager(facade);
        addTearDown(manager.dispose);
        const activePack = AssetPackConstants.backgroundVideosId;
        const queuedPack = AssetPackConstants.overlaysId;

        final active = manager.enqueue(activePack);
        final queued = manager.enqueue(queuedPack);
        await _eventually(() => facade.installCalls.length == 1);
        final activeCall = facade.installCalls.single;

        await manager.cancel(queuedPack);
        await queued;

        expect(activeCall.cancelToken?.isCancelled, isFalse);
        expect(
          manager.state.pack(queuedPack).status,
          AssetPackDownloadStatus.cancelled,
        );
        expect(facade.installCalls, hasLength(1));

        activeCall.complete();
        await active;
        expect(
          manager.state.pack(activePack).status,
          AssetPackDownloadStatus.installed,
        );
      },
    );

    test(
      'active cancellation exposes stopping until backend cleanup finishes',
      () async {
        const packId = AssetPackConstants.overlaysId;
        final facade = _ControlledAssetPackFacade(
          autoFinishCancellation: false,
        );
        final manager = AssetPackManager(facade);
        addTearDown(manager.dispose);

        final operation = manager.enqueue(packId);
        await _eventually(() => facade.installCalls.isNotEmpty);
        final call = facade.installCalls.single;
        final cancellation = manager.cancel(packId);

        expect(call.cancelToken?.isCancelled, isTrue);
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.stopping,
        );
        expect(manager.state.pack(packId).installRequested, isTrue);

        call.fail(StateError('Asset pack download cancelled.'));
        await cancellation;
        await operation;
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.cancelled,
        );
      },
    );

    test(
      'failure starts the next pack and failed work can rejoin the queue',
      () async {
        final facade = _ControlledAssetPackFacade();
        final manager = AssetPackManager(facade);
        addTearDown(manager.dispose);
        const failedPack = AssetPackConstants.backgroundVideosId;
        const nextPack = AssetPackConstants.overlaysId;

        final failedFuture = manager.enqueue(failedPack);
        final nextFuture = manager.enqueue(nextPack);
        await _eventually(() => facade.installCalls.length == 1);
        facade.installCalls.single.fail(
          StateError('R2 temporarily unavailable'),
        );
        await failedFuture;
        await _eventually(() => facade.installCalls.length == 2);

        final failed = manager.state.pack(failedPack);
        expect(failed.status, AssetPackDownloadStatus.failed);
        expect(failed.errorMessage, contains('R2 temporarily unavailable'));
        expect(failed.canRetry, isTrue);

        final retry = manager.retry(failedPack);
        expect(
          manager.state.pack(failedPack).status,
          AssetPackDownloadStatus.queued,
        );
        facade.installCalls[1].complete();
        await nextFuture;
        await _eventually(() => facade.installCalls.length == 3);
        facade.installCalls[2].complete();
        await retry;

        expect(
          manager.state.pack(failedPack).status,
          AssetPackDownloadStatus.installed,
        );
      },
    );

    test('a failed update retains the previously installed catalog', () async {
      const packId = AssetPackConstants.backgroundVideosId;
      final versionOne = _catalog(packId, version: '1.0.0');
      final facade = _ControlledAssetPackFacade(
        installed: <String, AssetPackCatalog?>{packId: versionOne},
        releases: <String, AssetPackRelease>{
          packId: _release(packId, version: '2.0.0'),
        },
      );
      final manager = AssetPackManager(facade);
      addTearDown(manager.dispose);

      await manager.initialize();
      await manager.refresh(packId);
      expect(manager.state.pack(packId).hasUpdate, isTrue);

      final update = manager.enqueue(packId);
      await _eventually(() => facade.installCalls.isNotEmpty);
      facade.installCalls.single.fail(StateError('Update download failed'));
      await update;

      final pack = manager.state.pack(packId);
      expect(pack.status, AssetPackDownloadStatus.failed);
      expect(pack.catalog, same(versionOne));
      expect(pack.catalog?.version, '1.0.0');
      expect(pack.isInstalled, isTrue);
      expect(pack.hasUpdate, isTrue);
    });

    test(
      'metadata failure can be refreshed after a pack is published',
      () async {
        const packId = AssetPackConstants.soundEffectsId;
        final facade = _ControlledAssetPackFacade(
          releaseErrors: <String, Object>{
            packId: StateError('Pack is not listed in the public manifest.'),
          },
        );
        final manager = AssetPackManager(facade);
        addTearDown(manager.dispose);

        await manager.refresh(packId);
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.failed,
        );
        expect(manager.state.pack(packId).release, isNull);

        facade.releaseErrors.remove(packId);
        facade.releases[packId] = _release(packId);
        await manager.refresh(packId);

        final refreshed = manager.state.pack(packId);
        expect(refreshed.status, AssetPackDownloadStatus.available);
        expect(refreshed.release?.id, packId);
        expect(refreshed.errorMessage, isNull);
      },
    );

    test(
      'throttles byte updates but publishes phase changes immediately',
      () async {
        final facade = _ControlledAssetPackFacade();
        final manager = AssetPackManager(
          facade,
          progressThrottle: const Duration(milliseconds: 40),
        );
        addTearDown(manager.dispose);
        const packId = AssetPackConstants.backgroundVideosId;

        final operation = manager.enqueue(packId);
        await _eventually(() => facade.installCalls.isNotEmpty);
        final call = facade.installCalls.single;
        call.emit(
          const AssetPackProgress(
            phase: AssetPackProgressPhase.downloading,
            receivedBytes: 1,
            totalBytes: 100,
          ),
        );
        call.emit(
          const AssetPackProgress(
            phase: AssetPackProgressPhase.downloading,
            receivedBytes: 2,
            totalBytes: 100,
          ),
        );

        expect(manager.state.pack(packId).progress?.receivedBytes, 1);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(manager.state.pack(packId).progress?.receivedBytes, 2);

        call.emit(
          const AssetPackProgress(
            phase: AssetPackProgressPhase.verifying,
            receivedBytes: 100,
            totalBytes: 100,
          ),
        );
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.verifying,
        );
        call.emit(
          const AssetPackProgress(phase: AssetPackProgressPhase.extracting),
        );
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.extracting,
        );
        call.emit(
          const AssetPackProgress(phase: AssetPackProgressPhase.installing),
        );
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.installing,
        );

        call.complete();
        await operation;
      },
    );

    test(
      'non-autoDispose provider keeps a live job after listeners leave',
      () async {
        final facade = _ControlledAssetPackFacade();
        final container = ProviderContainer(
          overrides: <Override>[
            assetPackFacadeProvider.overrideWithValue(facade),
          ],
        );
        addTearDown(container.dispose);
        final manager = container.read(assetPackProvider.notifier);
        await manager.initialize();

        final subscription = container.listen<AssetPackManagerState>(
          assetPackProvider,
          (_, _) {},
        );
        final operation = manager.enqueue(AssetPackConstants.overlaysId);
        await _eventually(() => facade.installCalls.isNotEmpty);
        final call = facade.installCalls.single;
        subscription.close();

        call.emit(
          const AssetPackProgress(
            phase: AssetPackProgressPhase.downloading,
            receivedBytes: 40,
            totalBytes: 100,
          ),
        );
        expect(call.cancelToken?.isCancelled, isFalse);
        expect(
          container
              .read(assetPackProvider)
              .pack(AssetPackConstants.overlaysId)
              .progress
              ?.receivedBytes,
          40,
        );

        call.complete();
        await operation;
        expect(
          container
              .read(assetPackProvider)
              .pack(AssetPackConstants.overlaysId)
              .status,
          AssetPackDownloadStatus.installed,
        );
      },
    );

    test(
      'removes an installed pack and forwards every protected path',
      () async {
        const packId = AssetPackConstants.overlaysId;
        final catalog = _catalog(packId);
        final facade = _ControlledAssetPackFacade(
          installed: <String, AssetPackCatalog?>{packId: catalog},
        );
        final manager = AssetPackManager(
          facade,
          protectedPathsLoader: () async => {
            r'C:\projects\current\clip.mp4',
            r'C:\projects\saved\sound.wav',
          },
        );
        addTearDown(manager.dispose);
        await manager.initialize();

        final removal = manager.remove(packId);
        expect(
          manager.state.pack(packId).status,
          AssetPackDownloadStatus.removing,
        );
        await removal;

        expect(facade.uninstallCalls, hasLength(1));
        expect(facade.uninstallCalls.single.packId, packId);
        expect(
          facade.uninstallCalls.single.protectedPaths,
          containsAll({
            r'C:\projects\current\clip.mp4',
            r'C:\projects\saved\sound.wav',
          }),
        );
        final pack = manager.state.pack(packId);
        expect(pack.catalog, isNull);
        expect(pack.status, AssetPackDownloadStatus.idle);
        expect(pack.removalErrorMessage, isNull);
      },
    );

    test('dependency failure keeps the installed catalog available', () async {
      const packId = AssetPackConstants.backgroundVideosId;
      final catalog = _catalog(packId);
      final facade = _ControlledAssetPackFacade(
        installed: <String, AssetPackCatalog?>{packId: catalog},
        uninstallError: const AssetPackException(
          'This library is still used by a project.',
          reason: AssetPackFailureReason.inUse,
        ),
      );
      final manager = AssetPackManager(
        facade,
        protectedPathsLoader: () async => {'used/clip.mp4'},
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await expectLater(
        manager.remove(packId),
        throwsA(
          isA<AssetPackException>().having(
            (error) => error.reason,
            'reason',
            AssetPackFailureReason.inUse,
          ),
        ),
      );

      final pack = manager.state.pack(packId);
      expect(pack.status, AssetPackDownloadStatus.installed);
      expect(pack.catalog, same(catalog));
      expect(pack.removalErrorMessage, contains('still used by a project'));
    });
  });
}

Future<void> _eventually(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not met before timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

AssetPackRelease _release(String packId, {String version = '2026.08.14'}) {
  return AssetPackRelease(
    id: packId,
    version: version,
    archiveUri: Uri.parse('https://media.example.test/$packId.zip'),
    sha256: 'a' * 64,
    archiveBytes: 100,
    installedBytes: 200,
    catalogPath: 'catalog.json',
  );
}

AssetPackCatalog _catalog(String packId, {String version = '2026.08.14'}) {
  return AssetPackCatalog(
    id: packId,
    title: packId,
    version: version,
    installationDirectory: Directory.systemTemp,
    items: const <AssetPackCatalogItem>[],
    categoryIds: const <String>[],
    categoryNames: const <String, String>{},
  );
}

class _ControlledAssetPackFacade
    implements AssetPackFacade, AssetPackRemovalFacade {
  _ControlledAssetPackFacade({
    Map<String, AssetPackCatalog?>? installed,
    Map<String, AssetPackRelease>? releases,
    Map<String, Object>? releaseErrors,
    this.uninstallError,
    this.autoFinishCancellation = true,
  }) : installed = installed ?? <String, AssetPackCatalog?>{},
       releases = releases ?? <String, AssetPackRelease>{},
       releaseErrors = releaseErrors ?? <String, Object>{};

  final bool autoFinishCancellation;
  final Object? uninstallError;
  final Map<String, AssetPackCatalog?> installed;
  final Map<String, AssetPackRelease> releases;
  final Map<String, Object> releaseErrors;
  final List<String> getInstalledCalls = <String>[];
  final List<String> getReleaseCalls = <String>[];
  final List<_InstallCall> installCalls = <_InstallCall>[];
  final List<_UninstallCall> uninstallCalls = <_UninstallCall>[];

  @override
  Future<AssetPackCatalog?> getInstalledCatalog(String packId) async {
    getInstalledCalls.add(packId);
    return installed[packId];
  }

  @override
  Future<AssetPackRelease> getRelease(
    String packId, {
    CancelToken? cancelToken,
  }) async {
    getReleaseCalls.add(packId);
    if (cancelToken?.isCancelled == true) {
      throw StateError('Asset pack download cancelled.');
    }
    final error = releaseErrors[packId];
    if (error != null) throw error;
    return releases[packId] ?? _release(packId);
  }

  @override
  Future<AssetPackCatalog> install(
    String packId, {
    AssetPackRelease? release,
    AssetPackProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) {
    final call = _InstallCall(
      packId: packId,
      release: release,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
    installCalls.add(call);
    cancelToken?.whenCancel.then((_) {
      if (autoFinishCancellation && !call.completer.isCompleted) {
        call.completer.completeError(
          StateError('Asset pack download cancelled.'),
        );
      }
    });
    return call.completer.future;
  }

  @override
  Future<void> uninstall(
    String packId, {
    Set<String> protectedPaths = const <String>{},
  }) async {
    uninstallCalls.add(
      _UninstallCall(packId, Set<String>.unmodifiable(protectedPaths)),
    );
    final error = uninstallError;
    if (error != null) throw error;
    installed[packId] = null;
  }
}

class _UninstallCall {
  const _UninstallCall(this.packId, this.protectedPaths);

  final String packId;
  final Set<String> protectedPaths;
}

class _InstallCall {
  _InstallCall({
    required this.packId,
    required this.release,
    required this.cancelToken,
    required this.onProgress,
  });

  final String packId;
  final AssetPackRelease? release;
  final CancelToken? cancelToken;
  final AssetPackProgressCallback? onProgress;
  final Completer<AssetPackCatalog> completer = Completer<AssetPackCatalog>();

  void emit(AssetPackProgress progress) => onProgress?.call(progress);

  void complete() {
    if (!completer.isCompleted) completer.complete(_catalog(packId));
  }

  void fail(Object error) {
    if (!completer.isCompleted) completer.completeError(error);
  }
}
