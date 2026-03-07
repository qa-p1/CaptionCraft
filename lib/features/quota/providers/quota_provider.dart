import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/device_quota_service.dart';
import '../../../core/constants/quota_constants.dart';

/// State for quota information.
class QuotaState {
  final int runsUsed;
  final int maxRuns;
  final bool isLoading;

  const QuotaState({
    this.runsUsed = 0,
    this.maxRuns = QuotaConstants.maxFreeRuns,
    this.isLoading = true,
  });

  int get remaining => (maxRuns - runsUsed).clamp(0, maxRuns).toInt();
  bool get canRun => remaining > 0;

  QuotaState copyWith({int? runsUsed, bool? isLoading}) {
    return QuotaState(
      runsUsed: runsUsed ?? this.runsUsed,
      maxRuns: maxRuns,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class QuotaNotifier extends StateNotifier<QuotaState> {
  QuotaNotifier() : super(const QuotaState());

  Future<void> loadQuota() async {
    state = state.copyWith(isLoading: true);
    try {
      final used = await DeviceQuotaService.getRunsUsed();
      state = state.copyWith(runsUsed: used, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<bool> consumeRun(String uid) async {
    if (!state.canRun) return false;
    try {
      final newCount = await DeviceQuotaService.consumeRun(uid);
      state = state.copyWith(runsUsed: newCount);
      return true;
    } catch (e) {
      return false;
    }
  }
}

final quotaProvider =
    StateNotifierProvider<QuotaNotifier, QuotaState>((ref) {
  return QuotaNotifier();
});
