import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/asset_pack_constants.dart';
import '../../../core/utils/asset_pack_service.dart';
import '../../../shared/models/project_model.dart';
import '../models/asset_pack_models.dart';
import '../models/timeline_models.dart';
import '../widgets/asset_pack_facade.dart';
import 'editor_provider.dart';

typedef AssetPackProtectedPathsLoader = Future<Set<String>> Function();

/// User-visible lifecycle of an optional asset pack.
enum AssetPackDownloadStatus {
  idle,
  checking,
  available,
  queued,
  downloading,
  verifying,
  extracting,
  installing,
  stopping,
  removing,
  cancelled,
  failed,
  installed,
}

/// Immutable state for one asset pack.
class AssetPackDownloadState {
  const AssetPackDownloadState({
    required this.packId,
    this.status = AssetPackDownloadStatus.idle,
    this.release,
    this.catalog,
    this.progress,
    this.errorMessage,
    this.removalErrorMessage,
    this.queuePosition,
    this.installRequested = false,
  });

  final String packId;
  final AssetPackDownloadStatus status;
  final AssetPackRelease? release;
  final AssetPackCatalog? catalog;
  final AssetPackProgress? progress;
  final String? errorMessage;
  final String? removalErrorMessage;

  /// One-based position among waiting jobs. The active job has no position.
  final int? queuePosition;

  /// True from enqueue until the attempt reaches a terminal state.
  ///
  /// This distinguishes an install's `checking` phase from a metadata refresh.
  final bool installRequested;

  /// Whether a previously installed catalog remains usable.
  ///
  /// This intentionally stays true when an update attempt fails or is
  /// cancelled; failure of v2 must never hide a working v1 library.
  bool get isInstalled => catalog != null;

  bool get isQueued => status == AssetPackDownloadStatus.queued;

  bool get isRemoving => status == AssetPackDownloadStatus.removing;

  bool get canRemove => catalog != null && !isActive && !isRemoving;

  bool get isActive => installRequested && !isTerminal;

  bool get isTerminal => switch (status) {
    AssetPackDownloadStatus.idle ||
    AssetPackDownloadStatus.available ||
    AssetPackDownloadStatus.cancelled ||
    AssetPackDownloadStatus.failed ||
    AssetPackDownloadStatus.installed => true,
    _ => false,
  };

  bool get canStop =>
      installRequested &&
      switch (status) {
        AssetPackDownloadStatus.checking ||
        AssetPackDownloadStatus.queued ||
        AssetPackDownloadStatus.downloading ||
        AssetPackDownloadStatus.verifying ||
        AssetPackDownloadStatus.extracting ||
        AssetPackDownloadStatus.installing => true,
        _ => false,
      };

  bool get canRetry =>
      status == AssetPackDownloadStatus.cancelled ||
      status == AssetPackDownloadStatus.failed;

  bool get hasUpdate =>
      catalog != null &&
      release != null &&
      catalog!.version != release!.version;

  AssetPackDownloadState copyWith({
    AssetPackDownloadStatus? status,
    AssetPackRelease? release,
    AssetPackCatalog? catalog,
    AssetPackProgress? progress,
    String? errorMessage,
    String? removalErrorMessage,
    int? queuePosition,
    bool? installRequested,
    bool clearRelease = false,
    bool clearCatalog = false,
    bool clearProgress = false,
    bool clearError = false,
    bool clearRemovalError = false,
    bool clearQueuePosition = false,
  }) {
    return AssetPackDownloadState(
      packId: packId,
      status: status ?? this.status,
      release: clearRelease ? null : release ?? this.release,
      catalog: clearCatalog ? null : catalog ?? this.catalog,
      progress: clearProgress ? null : progress ?? this.progress,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      removalErrorMessage: clearRemovalError
          ? null
          : removalErrorMessage ?? this.removalErrorMessage,
      queuePosition: clearQueuePosition
          ? null
          : queuePosition ?? this.queuePosition,
      installRequested: installRequested ?? this.installRequested,
    );
  }
}

/// App-scoped snapshot for every supported optional pack.
class AssetPackManagerState {
  static const supportedPackIds = <String>[
    AssetPackConstants.backgroundVideosId,
    AssetPackConstants.overlaysId,
    AssetPackConstants.soundEffectsId,
  ];

  AssetPackManagerState({
    Map<String, AssetPackDownloadState>? packs,
    this.isInitialized = false,
  }) : packs = Map<String, AssetPackDownloadState>.unmodifiable(
         packs ??
             <String, AssetPackDownloadState>{
               for (final id in supportedPackIds)
                 id: AssetPackDownloadState(packId: id),
             },
       );

  final Map<String, AssetPackDownloadState> packs;
  final bool isInitialized;

  AssetPackDownloadState pack(String packId) {
    final value = packs[packId];
    if (value == null) {
      throw ArgumentError.value(packId, 'packId', 'Unsupported asset pack.');
    }
    return value;
  }

  String? get activePackId {
    for (final entry in packs.entries) {
      if (entry.value.installRequested && !entry.value.isQueued) {
        return entry.key;
      }
    }
    return null;
  }

  int get queuedCount => packs.values.where((value) => value.isQueued).length;

  AssetPackManagerState withPack(AssetPackDownloadState value) {
    return AssetPackManagerState(
      packs: <String, AssetPackDownloadState>{...packs, value.packId: value},
      isInitialized: isInitialized,
    );
  }

  AssetPackManagerState copyWith({bool? isInitialized}) {
    return AssetPackManagerState(
      packs: packs,
      isInitialized: isInitialized ?? this.isInitialized,
    );
  }
}

/// Owns asset-pack jobs independently of any bottom sheet.
///
/// Installs are globally serialized to keep disk, checksum, and extraction
/// pressure bounded. A second enqueue for the same pack joins the original
/// future. Only [cancel] stops a job; removing UI listeners has no effect.
class AssetPackManager extends StateNotifier<AssetPackManagerState> {
  AssetPackManager(
    this._facade, {
    this.progressThrottle = const Duration(milliseconds: 120),
    DateTime Function()? clock,
    AssetPackProtectedPathsLoader? protectedPathsLoader,
  }) : assert(!progressThrottle.isNegative),
       _clock = clock ?? DateTime.now,
       _protectedPathsLoader =
           protectedPathsLoader ?? _emptyProtectedPathsLoader,
       super(AssetPackManagerState());

  final AssetPackFacade _facade;
  final Duration progressThrottle;
  final DateTime Function() _clock;
  final AssetPackProtectedPathsLoader _protectedPathsLoader;

  final List<String> _queue = <String>[];
  final Map<String, Completer<void>> _operations = <String, Completer<void>>{};
  final Map<String, Future<void>> _refreshOperations = <String, Future<void>>{};
  final Map<String, Future<void>> _removalOperations = <String, Future<void>>{};
  final Map<String, bool> _refreshIncludesRemote = <String, bool>{};
  final Map<String, int> _generations = <String, int>{};
  final Set<String> _cancelRequested = <String>{};
  final Map<String, DateTime> _lastProgressAt = <String, DateTime>{};
  final Map<String, AssetPackProgress> _pendingProgress =
      <String, AssetPackProgress>{};
  final Map<String, Timer> _progressTimers = <String, Timer>{};

  Future<void>? _initialization;
  String? _activePackId;
  CancelToken? _activeCancelToken;
  bool _disposed = false;

  static Future<Set<String>> _emptyProtectedPathsLoader() async =>
      const <String>{};

  /// Checks durable local state for all packs without contacting the network.
  ///
  /// Pass [fetchRemoteMetadata] only from an explicit user-facing refresh. The
  /// default preserves the on-demand guarantee: app startup does not touch R2.
  Future<void> initialize({bool fetchRemoteMetadata = false}) async {
    await (_initialization ??= _initializeLocalState());
    if (fetchRemoteMetadata && !_disposed) {
      await Future.wait<void>(
        AssetPackManagerState.supportedPackIds.map(
          (packId) => refresh(packId, fetchRemoteMetadata: true),
        ),
      );
    }
  }

  Future<void> _initializeLocalState() async {
    await Future.wait<void>(
      AssetPackManagerState.supportedPackIds.map(
        (packId) => refresh(packId, fetchRemoteMetadata: false),
      ),
    );
    if (!_disposed && mounted) {
      state = state.copyWith(isInitialized: true);
    }
  }

  /// Reconciles a pack's installed catalog and, by default, current release.
  Future<void> refresh(String packId, {bool fetchRemoteMetadata = true}) async {
    _validatePackId(packId);
    if (_disposed ||
        _operations.containsKey(packId) ||
        _removalOperations.containsKey(packId)) {
      return;
    }

    final existing = _refreshOperations[packId];
    if (existing != null) {
      final existingIncludesRemote = _refreshIncludesRemote[packId] == true;
      await existing;
      if (fetchRemoteMetadata && !existingIncludesRemote && !_disposed) {
        await refresh(packId, fetchRemoteMetadata: true);
      }
      return;
    }

    final generation = _nextGeneration(packId);
    final operation = _runRefresh(
      packId,
      generation: generation,
      fetchRemoteMetadata: fetchRemoteMetadata,
    );
    _refreshOperations[packId] = operation;
    _refreshIncludesRemote[packId] = fetchRemoteMetadata;
    try {
      await operation;
    } finally {
      if (identical(_refreshOperations[packId], operation)) {
        _refreshOperations.remove(packId);
        _refreshIncludesRemote.remove(packId);
      }
    }
  }

  Future<void> _runRefresh(
    String packId, {
    required int generation,
    required bool fetchRemoteMetadata,
  }) async {
    final previous = state.pack(packId);
    _replacePack(
      previous.copyWith(
        status: AssetPackDownloadStatus.checking,
        installRequested: false,
        clearProgress: true,
        clearError: true,
        clearRemovalError: true,
        clearQueuePosition: true,
      ),
    );

    AssetPackCatalog? catalog;
    AssetPackRelease? release = previous.release;
    Object? localError;
    Object? remoteError;

    try {
      catalog = await _facade.getInstalledCatalog(packId);
    } catch (error) {
      localError = error;
    }
    if (fetchRemoteMetadata) {
      try {
        release = await _facade.getRelease(packId);
        if (release.id != packId) {
          throw StateError('Release metadata belongs to another asset pack.');
        }
      } catch (error) {
        remoteError = error;
      }
    }

    if (!_isCurrent(packId, generation) || _operations.containsKey(packId)) {
      return;
    }
    if (localError != null) {
      _replacePack(
        previous.copyWith(
          status: AssetPackDownloadStatus.failed,
          release: release,
          errorMessage: _errorText(localError),
          installRequested: false,
          clearProgress: true,
          clearQueuePosition: true,
        ),
      );
      return;
    }

    if (catalog != null) {
      _replacePack(
        previous.copyWith(
          status: AssetPackDownloadStatus.installed,
          release: release,
          catalog: catalog,
          errorMessage: remoteError == null ? null : _errorText(remoteError),
          installRequested: false,
          clearProgress: true,
          clearError: remoteError == null,
          clearQueuePosition: true,
        ),
      );
      return;
    }

    if (remoteError != null) {
      _replacePack(
        previous.copyWith(
          status: AssetPackDownloadStatus.failed,
          release: release,
          errorMessage: _errorText(remoteError),
          installRequested: false,
          clearCatalog: true,
          clearProgress: true,
          clearQueuePosition: true,
        ),
      );
      return;
    }

    _replacePack(
      previous.copyWith(
        status: release == null
            ? AssetPackDownloadStatus.idle
            : AssetPackDownloadStatus.available,
        release: release,
        installRequested: false,
        clearCatalog: true,
        clearProgress: true,
        clearError: true,
        clearQueuePosition: true,
      ),
    );
  }

  /// Enqueues a pack or joins its existing queued/running operation.
  Future<void> enqueue(String packId) {
    _validatePackId(packId);
    if (_disposed || _removalOperations.containsKey(packId)) {
      return Future<void>.value();
    }
    final existing = _operations[packId];
    if (existing != null) return existing.future;

    final current = state.pack(packId);
    if (current.status == AssetPackDownloadStatus.installed &&
        current.isInstalled &&
        !current.hasUpdate) {
      return Future<void>.value();
    }

    final generation = _nextGeneration(packId);
    final completer = Completer<void>();
    _operations[packId] = completer;
    _cancelRequested.remove(packId);
    _queue.add(packId);
    _replacePack(
      current.copyWith(
        status: AssetPackDownloadStatus.queued,
        queuePosition: _queue.length,
        installRequested: true,
        clearProgress: true,
        clearError: true,
        clearRemovalError: true,
      ),
    );
    _updateQueuePositions();
    _drainQueue(generationHint: generation);
    return completer.future;
  }

  /// Stops only the explicitly selected pack.
  Future<void> cancel(String packId) async {
    _validatePackId(packId);
    final operation = _operations[packId];
    if (operation == null) return;

    _cancelRequested.add(packId);
    if (_queue.remove(packId)) {
      _replacePack(
        state
            .pack(packId)
            .copyWith(
              status: AssetPackDownloadStatus.cancelled,
              installRequested: false,
              clearProgress: true,
              clearError: true,
              clearQueuePosition: true,
            ),
      );
      _cancelRequested.remove(packId);
      _finishOperation(packId);
      _updateQueuePositions();
      return;
    }

    if (_activePackId == packId) {
      _replacePack(
        state
            .pack(packId)
            .copyWith(
              status: AssetPackDownloadStatus.stopping,
              installRequested: true,
              clearError: true,
              clearQueuePosition: true,
            ),
      );
      final token = _activeCancelToken;
      if (token != null && !token.isCancelled) {
        token.cancel('Asset pack download stopped by the user.');
      }
      await operation.future;
    }
  }

  Future<void> retry(String packId) {
    _validatePackId(packId);
    final current = state.pack(packId);
    if (!current.canRetry) return Future<void>.value();
    return enqueue(packId);
  }

  /// Deletes an installed optional pack only when no current or saved project
  /// references any path inside it.
  ///
  /// Concurrent removal requests join the same operation. A failed dependency
  /// check leaves the existing catalog usable and reports a focused message in
  /// [AssetPackDownloadState.removalErrorMessage].
  Future<void> remove(String packId) {
    _validatePackId(packId);
    if (_disposed) return Future<void>.value();
    final existing = _removalOperations[packId];
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = _remove(packId).whenComplete(() {
      if (identical(_removalOperations[packId], operation)) {
        _removalOperations.remove(packId);
      }
    });
    _removalOperations[packId] = operation;
    return operation;
  }

  Future<void> _remove(String packId) async {
    final current = state.pack(packId);
    if (current.catalog == null) return;
    if (_operations.containsKey(packId)) {
      const error = AssetPackException(
        'Stop the current download before removing this library.',
        reason: AssetPackFailureReason.busy,
        retryable: true,
      );
      _replacePack(current.copyWith(removalErrorMessage: error.message));
      throw error;
    }
    if (_facade is! AssetPackRemovalFacade) {
      const error = AssetPackException(
        'This asset-pack source does not support local removal.',
        reason: AssetPackFailureReason.filesystem,
      );
      _replacePack(current.copyWith(removalErrorMessage: error.message));
      throw error;
    }
    final removalFacade = _facade as AssetPackRemovalFacade;

    final generation = _nextGeneration(packId);
    _replacePack(
      current.copyWith(
        status: AssetPackDownloadStatus.removing,
        installRequested: false,
        clearProgress: true,
        clearError: true,
        clearRemovalError: true,
        clearQueuePosition: true,
      ),
    );
    try {
      final protectedPaths = await _protectedPathsLoader();
      if (!_isCurrent(packId, generation)) return;
      await removalFacade.uninstall(
        packId,
        protectedPaths: Set<String>.unmodifiable(protectedPaths),
      );
      if (!_isCurrent(packId, generation)) return;
      final latest = state.pack(packId);
      _replacePack(
        latest.copyWith(
          status: latest.release == null
              ? AssetPackDownloadStatus.idle
              : AssetPackDownloadStatus.available,
          installRequested: false,
          clearCatalog: true,
          clearProgress: true,
          clearError: true,
          clearRemovalError: true,
          clearQueuePosition: true,
        ),
      );
    } catch (error) {
      if (_isCurrent(packId, generation)) {
        _replacePack(
          current.copyWith(
            status: AssetPackDownloadStatus.installed,
            removalErrorMessage: _errorText(error),
            installRequested: false,
            clearProgress: true,
            clearQueuePosition: true,
          ),
        );
      }
      rethrow;
    }
  }

  void _drainQueue({int? generationHint}) {
    if (_disposed || _activePackId != null || _queue.isEmpty) return;
    final packId = _queue.removeAt(0);
    _activePackId = packId;
    _activeCancelToken = CancelToken();
    _replacePack(
      state
          .pack(packId)
          .copyWith(
            status: state.pack(packId).release == null
                ? AssetPackDownloadStatus.checking
                : AssetPackDownloadStatus.downloading,
            installRequested: true,
            clearProgress: true,
            clearError: true,
            clearQueuePosition: true,
          ),
    );
    _updateQueuePositions();
    final generation = _generations[packId] ?? generationHint ?? 0;
    unawaited(
      _runInstall(
        packId,
        generation: generation,
        cancelToken: _activeCancelToken!,
      ),
    );
  }

  Future<void> _runInstall(
    String packId, {
    required int generation,
    required CancelToken cancelToken,
  }) async {
    try {
      var current = state.pack(packId);
      var release = current.release;
      var installedCatalog = current.catalog;
      if (release == null) {
        _replacePack(
          state
              .pack(packId)
              .copyWith(
                status: AssetPackDownloadStatus.checking,
                installRequested: true,
                clearProgress: true,
                clearError: true,
                clearQueuePosition: true,
              ),
        );
        installedCatalog ??= await _facade.getInstalledCatalog(packId);
        if (!_isCurrent(packId, generation)) return;
        if (installedCatalog != null) {
          _replacePack(
            state
                .pack(packId)
                .copyWith(
                  catalog: installedCatalog,
                  installRequested: true,
                  clearError: true,
                ),
          );
        }
        release = await _facade.getRelease(packId, cancelToken: cancelToken);
        if (release.id != packId) {
          throw StateError('Release metadata belongs to another asset pack.');
        }
        if (!_isCurrent(packId, generation)) return;
        if (installedCatalog?.version == release.version) {
          _replacePack(
            state
                .pack(packId)
                .copyWith(
                  status: AssetPackDownloadStatus.installed,
                  release: release,
                  catalog: installedCatalog,
                  installRequested: false,
                  clearProgress: true,
                  clearError: true,
                  clearQueuePosition: true,
                ),
          );
          return;
        }
        _replacePack(
          state
              .pack(packId)
              .copyWith(
                release: release,
                catalog: installedCatalog,
                status: AssetPackDownloadStatus.downloading,
                installRequested: true,
                clearProgress: true,
                clearError: true,
                clearQueuePosition: true,
              ),
        );
      }

      final catalog = await _facade.install(
        packId,
        release: release,
        cancelToken: cancelToken,
        onProgress: (progress) =>
            _receiveProgress(packId, generation, progress),
      );
      if (!_isCurrent(packId, generation)) return;
      if (_cancelRequested.contains(packId) || cancelToken.isCancelled) {
        _setCancelled(packId);
      } else {
        _clearPendingProgress(packId);
        _replacePack(
          state
              .pack(packId)
              .copyWith(
                status: AssetPackDownloadStatus.installed,
                catalog: catalog,
                installRequested: false,
                clearProgress: true,
                clearError: true,
                clearQueuePosition: true,
              ),
        );
      }
    } catch (error) {
      if (!_isCurrent(packId, generation)) return;
      if (_cancelRequested.contains(packId) || cancelToken.isCancelled) {
        _setCancelled(packId);
      } else {
        _clearPendingProgress(packId);
        _replacePack(
          state
              .pack(packId)
              .copyWith(
                status: AssetPackDownloadStatus.failed,
                errorMessage: _errorText(error),
                installRequested: false,
                clearProgress: true,
                clearQueuePosition: true,
              ),
        );
      }
    } finally {
      if (_activePackId == packId) {
        _activePackId = null;
        _activeCancelToken = null;
      }
      _cancelRequested.remove(packId);
      _finishOperation(packId);
      _drainQueue();
    }
  }

  void _setCancelled(String packId) {
    _clearPendingProgress(packId);
    _replacePack(
      state
          .pack(packId)
          .copyWith(
            status: AssetPackDownloadStatus.cancelled,
            installRequested: false,
            clearProgress: true,
            clearError: true,
            clearQueuePosition: true,
          ),
    );
  }

  void _receiveProgress(
    String packId,
    int generation,
    AssetPackProgress progress,
  ) {
    if (!_isCurrent(packId, generation) ||
        _activePackId != packId ||
        _cancelRequested.contains(packId)) {
      return;
    }
    final current = state.pack(packId);
    final nextStatus = _statusForPhase(progress.phase);
    final phaseChanged = current.progress?.phase != progress.phase;
    final isFinalByteUpdate =
        progress.totalBytes > 0 &&
        progress.receivedBytes >= progress.totalBytes;
    final now = _clock();
    final last = _lastProgressAt[packId];
    final elapsed = last == null ? progressThrottle : now.difference(last);

    if (progressThrottle > Duration.zero &&
        !phaseChanged &&
        !isFinalByteUpdate &&
        elapsed < progressThrottle) {
      _pendingProgress[packId] = progress;
      _progressTimers[packId] ??= Timer(progressThrottle - elapsed, () {
        _progressTimers.remove(packId);
        final pending = _pendingProgress.remove(packId);
        if (pending != null &&
            _isCurrent(packId, generation) &&
            _activePackId == packId &&
            !_cancelRequested.contains(packId)) {
          _publishProgress(packId, pending);
        }
      });
      return;
    }

    _clearPendingProgress(packId);
    _lastProgressAt[packId] = now;
    _replacePack(
      current.copyWith(
        status: nextStatus,
        progress: progress,
        installRequested: true,
        clearError: true,
        clearQueuePosition: true,
      ),
    );
  }

  void _publishProgress(String packId, AssetPackProgress progress) {
    _lastProgressAt[packId] = _clock();
    _replacePack(
      state
          .pack(packId)
          .copyWith(
            status: _statusForPhase(progress.phase),
            progress: progress,
            installRequested: true,
            clearError: true,
            clearQueuePosition: true,
          ),
    );
  }

  AssetPackDownloadStatus _statusForPhase(AssetPackProgressPhase phase) {
    return switch (phase) {
      AssetPackProgressPhase.fetchingManifest =>
        AssetPackDownloadStatus.checking,
      AssetPackProgressPhase.downloading => AssetPackDownloadStatus.downloading,
      AssetPackProgressPhase.verifying => AssetPackDownloadStatus.verifying,
      AssetPackProgressPhase.extracting => AssetPackDownloadStatus.extracting,
      AssetPackProgressPhase.installing ||
      AssetPackProgressPhase.complete => AssetPackDownloadStatus.installing,
    };
  }

  void _updateQueuePositions() {
    if (_disposed || !mounted) return;
    var nextState = state;
    for (var index = 0; index < _queue.length; index++) {
      final packId = _queue[index];
      final current = nextState.pack(packId);
      nextState = nextState.withPack(
        current.copyWith(
          status: AssetPackDownloadStatus.queued,
          queuePosition: index + 1,
          installRequested: true,
        ),
      );
    }
    state = nextState;
  }

  void _clearPendingProgress(String packId) {
    _progressTimers.remove(packId)?.cancel();
    _pendingProgress.remove(packId);
    _lastProgressAt.remove(packId);
  }

  void _finishOperation(String packId) {
    final operation = _operations.remove(packId);
    if (operation != null && !operation.isCompleted) operation.complete();
  }

  int _nextGeneration(String packId) {
    final next = (_generations[packId] ?? 0) + 1;
    _generations[packId] = next;
    return next;
  }

  bool _isCurrent(String packId, int generation) {
    return !_disposed && mounted && _generations[packId] == generation;
  }

  void _replacePack(AssetPackDownloadState value) {
    if (_disposed || !mounted) return;
    state = state.withPack(value);
  }

  void _validatePackId(String packId) {
    if (!AssetPackManagerState.supportedPackIds.contains(packId)) {
      throw ArgumentError.value(packId, 'packId', 'Unsupported asset pack.');
    }
  }

  static String _errorText(Object error) {
    final text = error
        .toString()
        .replaceFirst(
          RegExp(
            r'^(?:Exception|AssetPackException|Bad state|Invalid argument|FormatException):\s*',
          ),
          '',
        )
        .trim();
    if (text.isEmpty) return 'The asset pack operation failed.';
    return text.length <= 300 ? text : '${text.substring(0, 297)}...';
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _progressTimers.values) {
      timer.cancel();
    }
    _progressTimers.clear();
    _pendingProgress.clear();
    final token = _activeCancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel('Asset pack manager disposed.');
    }
    for (final operation in _operations.values) {
      if (!operation.isCompleted) operation.complete();
    }
    _operations.clear();
    _removalOperations.clear();
    _queue.clear();
    super.dispose();
  }
}

final assetPackFacadeProvider = Provider<AssetPackFacade>((ref) {
  return AssetPackServiceFacade();
});

/// App-scoped, deliberately non-auto-disposing asset-pack coordinator.
final assetPackProvider =
    StateNotifierProvider<AssetPackManager, AssetPackManagerState>((ref) {
      final manager = AssetPackManager(
        ref.watch(assetPackFacadeProvider),
        protectedPathsLoader: () => _loadProtectedAssetPaths(ref),
      );
      unawaited(manager.initialize());
      return manager;
    });

Future<Set<String>> _loadProtectedAssetPaths(Ref ref) async {
  final editor = ref.read(editorProvider);
  final projects = await ProjectLocalStorage.loadProjects();
  return collectAssetPackProtectedPaths(
    editor: editor,
    savedProjects: projects,
  );
}

@visibleForTesting
Set<String> collectAssetPackProtectedPaths({
  required EditorState editor,
  required Iterable<Project> savedProjects,
}) {
  final paths = <String>{};

  void addTimelinePaths(EditorTimeline timeline, {String? fallbackVideoPath}) {
    final fallback = fallbackVideoPath?.trim();
    if (fallback != null && fallback.isNotEmpty) paths.add(fallback);
    for (final asset in timeline.assets) {
      final sourcePath = asset.sourcePath?.trim();
      if (sourcePath != null && sourcePath.isNotEmpty) paths.add(sourcePath);
    }
  }

  addTimelinePaths(editor.timeline, fallbackVideoPath: editor.videoPath);
  for (final project in savedProjects) {
    addTimelinePaths(project.timeline, fallbackVideoPath: project.videoPath);
  }
  return paths;
}
