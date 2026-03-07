class QuotaConstants {
  QuotaConstants._();

  static const int maxFreeRuns = 3;
  static const String deviceFingerprintKey = 'device_fingerprint';
  static const String runsUsedKey = 'runs_used';
  static const String boundUidKey = 'bound_uid';
  static const String currentUidKey = 'current_uid';
  static const String firestoreCollection = 'device_quotas';
}
