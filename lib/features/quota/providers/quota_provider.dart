import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/device_quota_service.dart';
import '../../../core/constants/quota_constants.dart';

/// State for quota information.
class QuotaState {
  final int runsUsed;
  final int maxRuns;
  final bool isLoading;
  final bool hasLoadError;

  const QuotaState({
    this.runsUsed = 0,
    this.maxRuns = QuotaConstants.maxFreeRuns,
    this.isLoading = true,
    this.hasLoadError = false,
  });

  int get remaining => (maxRuns - runsUsed).clamp(0, maxRuns).toInt();
  bool get canRun => !isLoading && !hasLoadError && remaining > 0;

  QuotaState copyWith({int? runsUsed, bool? isLoading, bool? hasLoadError}) {
    return QuotaState(
      runsUsed: runsUsed ?? this.runsUsed,
      maxRuns: maxRuns,
      isLoading: isLoading ?? this.isLoading,
      hasLoadError: hasLoadError ?? this.hasLoadError,
    );
  }
}

typedef QuotaLoader = Future<int> Function();
typedef QuotaConsumer = Future<int> Function(String uid);

class QuotaNotifier extends StateNotifier<QuotaState> {
  QuotaNotifier({QuotaLoader? loadRunsUsed, QuotaConsumer? consumeRun})
    : _loadRunsUsed = loadRunsUsed ?? DeviceQuotaService.getRunsUsed,
      _consumeRun = consumeRun ?? DeviceQuotaService.consumeRun,
      super(const QuotaState());

  final QuotaLoader _loadRunsUsed;
  final QuotaConsumer _consumeRun;
  Future<void> _operationTail = Future<void>.value();

  Future<void> loadQuota() => _serialize(() async {
    state = state.copyWith(isLoading: true, hasLoadError: false);
    try {
      final used = await _loadRunsUsed();
      state = state.copyWith(
        runsUsed: _normalizedCount(math.max(state.runsUsed, used)),
        isLoading: false,
        hasLoadError: false,
      );
    } catch (_) {
      // DeviceQuotaService already falls back to its secure local count when
      // Firebase is offline. Reaching this branch means no trustworthy count
      // is available, so generation remains disabled until a successful retry.
      state = state.copyWith(isLoading: false, hasLoadError: true);
    }
  });

  Future<bool> consumeRun(String uid) => _serialize(() async {
    if (!state.canRun) return false;
    final previousCount = state.runsUsed;
    try {
      final newCount = await _consumeRun(uid);
      final resolvedCount = _normalizedCount(math.max(previousCount, newCount));
      state = state.copyWith(runsUsed: resolvedCount);
      return resolvedCount > previousCount;
    } catch (_) {
      return false;
    }
  });

  int _normalizedCount(int count) => count.clamp(0, state.maxRuns).toInt();

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.catchError((Object _) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

final quotaProvider = StateNotifierProvider<QuotaNotifier, QuotaState>((ref) {
  return QuotaNotifier();
});
