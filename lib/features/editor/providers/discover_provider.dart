import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/discover_download_manager.dart';
import '../models/discover_models.dart';

class DiscoverState {
  const DiscoverState({
    this.downloads = const <DiscoverDownloadItem>[],
    this.youtubeInfo,
    this.isInitialized = false,
    this.isInspectingYoutube = false,
    this.isEnqueuing = false,
    this.permittedContentAcknowledged = false,
    this.errorMessage,
  });

  final List<DiscoverDownloadItem> downloads;
  final YoutubeVideoInfo? youtubeInfo;
  final bool isInitialized;
  final bool isInspectingYoutube;
  final bool isEnqueuing;
  final bool permittedContentAcknowledged;
  final String? errorMessage;

  bool get hasActiveDownloads => downloads.any(
    (item) =>
        item.status == DiscoverDownloadStatus.queued ||
        item.status == DiscoverDownloadStatus.downloading ||
        item.status == DiscoverDownloadStatus.processing,
  );

  DiscoverState copyWith({
    List<DiscoverDownloadItem>? downloads,
    YoutubeVideoInfo? youtubeInfo,
    bool? isInitialized,
    bool? isInspectingYoutube,
    bool? isEnqueuing,
    bool? permittedContentAcknowledged,
    String? errorMessage,
    bool clearYoutubeInfo = false,
    bool clearErrorMessage = false,
  }) {
    return DiscoverState(
      downloads: downloads ?? this.downloads,
      youtubeInfo: clearYoutubeInfo ? null : youtubeInfo ?? this.youtubeInfo,
      isInitialized: isInitialized ?? this.isInitialized,
      isInspectingYoutube: isInspectingYoutube ?? this.isInspectingYoutube,
      isEnqueuing: isEnqueuing ?? this.isEnqueuing,
      permittedContentAcknowledged:
          permittedContentAcknowledged ?? this.permittedContentAcknowledged,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
    );
  }
}

class DiscoverNotifier extends StateNotifier<DiscoverState> {
  DiscoverNotifier(this._facade) : super(const DiscoverState()) {
    _subscription = _facade.items.listen(
      (items) {
        if (!mounted) return;
        state = state.copyWith(
          downloads: List<DiscoverDownloadItem>.unmodifiable(items),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted) return;
        state = state.copyWith(errorMessage: _errorText(error));
      },
    );
  }

  final DiscoverDownloadFacade _facade;
  late final StreamSubscription<List<DiscoverDownloadItem>> _subscription;
  Future<void>? _initialization;
  int _youtubeInspectionGeneration = 0;
  int _enqueueOperations = 0;

  Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _facade.initialize();
      if (!mounted) return;
      state = state.copyWith(
        downloads: _facade.currentItems,
        isInitialized: true,
        clearErrorMessage: true,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        isInitialized: true,
        errorMessage: _errorText(error),
      );
    }
  }

  Future<DiscoverDownloadItem?> enqueueDirect(
    DiscoverDownloadRequest request,
  ) async {
    _beginEnqueue();
    try {
      await initialize();
      return await _facade.enqueueDirect(request);
    } catch (error) {
      if (mounted) state = state.copyWith(errorMessage: _errorText(error));
      return null;
    } finally {
      _endEnqueue();
    }
  }

  Future<YoutubeVideoInfo?> inspectYoutube(String url) async {
    final generation = ++_youtubeInspectionGeneration;
    state = state.copyWith(
      isInspectingYoutube: true,
      permittedContentAcknowledged: false,
      clearYoutubeInfo: true,
      clearErrorMessage: true,
    );
    try {
      final info = await _facade.inspectYoutube(url);
      if (mounted && generation == _youtubeInspectionGeneration) {
        state = state.copyWith(youtubeInfo: info);
      }
      return info;
    } catch (error) {
      if (mounted && generation == _youtubeInspectionGeneration) {
        state = state.copyWith(errorMessage: _errorText(error));
      }
      return null;
    } finally {
      if (mounted && generation == _youtubeInspectionGeneration) {
        state = state.copyWith(isInspectingYoutube: false);
      }
    }
  }

  Future<DiscoverDownloadItem?> enqueueYoutube({
    required YoutubeVideoInfo info,
    required YoutubeFormatOption format,
    String? outputFileName,
  }) async {
    final acknowledged = state.permittedContentAcknowledged;
    _beginEnqueue();
    try {
      await initialize();
      final item = await _facade.enqueueYoutube(
        info: info,
        format: format,
        permittedContentAcknowledged: acknowledged,
        outputFileName: outputFileName,
      );
      if (mounted) {
        state = state.copyWith(permittedContentAcknowledged: false);
      }
      return item;
    } catch (error) {
      if (mounted) state = state.copyWith(errorMessage: _errorText(error));
      return null;
    } finally {
      _endEnqueue();
    }
  }

  void setPermittedContentAcknowledged(bool value) {
    state = state.copyWith(
      permittedContentAcknowledged: value,
      clearErrorMessage: value,
    );
  }

  void clearYoutubeInspection() {
    _youtubeInspectionGeneration++;
    state = state.copyWith(
      clearYoutubeInfo: true,
      isInspectingYoutube: false,
      permittedContentAcknowledged: false,
    );
  }

  void _beginEnqueue() {
    _enqueueOperations++;
    state = state.copyWith(isEnqueuing: true, clearErrorMessage: true);
  }

  void _endEnqueue() {
    if (_enqueueOperations > 0) _enqueueOperations--;
    if (mounted) {
      state = state.copyWith(isEnqueuing: _enqueueOperations > 0);
    }
  }

  void clearError() {
    state = state.copyWith(clearErrorMessage: true);
  }

  Future<void> cancel(String id) => _runAction(() => _facade.cancel(id));

  Future<void> retry(String id) => _runAction(() => _facade.retry(id));

  Future<void> delete(String id) => _runAction(() => _facade.delete(id));

  Future<bool> open(String id) async {
    try {
      return await _facade.open(id);
    } catch (error) {
      if (mounted) state = state.copyWith(errorMessage: _errorText(error));
      return false;
    }
  }

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) state = state.copyWith(errorMessage: _errorText(error));
    }
  }

  static String _errorText(Object error) {
    final value = error.toString().replaceFirst(
      RegExp(r'^(?:Bad state|Invalid argument|FormatException):\s*'),
      '',
    );
    return value.length <= 300 ? value : '${value.substring(0, 297)}...';
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

final discoverDownloadFacadeProvider = Provider<DiscoverDownloadFacade>((ref) {
  final facade = DiscoverDownloadManager();
  ref.onDispose(facade.dispose);
  return facade;
});

final discoverProvider = StateNotifierProvider<DiscoverNotifier, DiscoverState>(
  (ref) {
    final notifier = DiscoverNotifier(
      ref.watch(discoverDownloadFacadeProvider),
    );
    unawaited(notifier.initialize());
    return notifier;
  },
);
