import 'dart:async';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../constants/quota_constants.dart';
import 'firebase_service.dart';

/// Service for device-level quota enforcement.
/// Each app installation gets a stable allowance shared across its accounts.
class DeviceQuotaService {
  DeviceQuotaService._();

  static const _storage = FlutterSecureStorage();
  static Future<String>? _fingerprintFuture;
  static Future<void> _quotaOperationTail = Future<void>.value();

  /// Get or create a stable device fingerprint.
  static Future<String> getDeviceFingerprint() {
    final pending = _fingerprintFuture;
    if (pending != null) return pending;
    final operation = _loadOrCreateDeviceFingerprint();
    _fingerprintFuture = operation;
    operation.catchError((Object _) {
      if (identical(_fingerprintFuture, operation)) {
        _fingerprintFuture = null;
      }
      return '';
    });
    return operation;
  }

  static Future<String> _loadOrCreateDeviceFingerprint() async {
    // Check if already stored
    String? fingerprint = await _storage.read(
      key: QuotaConstants.deviceFingerprintKey,
    );
    if (fingerprint != null) return fingerprint;

    // Device build identifiers are not unique and can collide across thousands
    // of phones. A securely stored random installation id is stable without
    // collecting hardware identifiers.
    final rawId = const Uuid().v4();
    fingerprint = sha256.convert(utf8.encode(rawId)).toString();

    // Store permanently
    await _storage.write(
      key: QuotaConstants.deviceFingerprintKey,
      value: fingerprint,
    );

    return fingerprint;
  }

  /// Get the current number of runs used (max of local and server).
  static Future<int> getRunsUsed() => _serializeQuotaOperation(_getRunsUsed);

  static Future<int> _getRunsUsed() async {
    final fingerprint = await getDeviceFingerprint();

    // Local count
    final localCount = await _readLocalRunsUsed();

    // Server count
    int serverCount;
    try {
      serverCount = await FirebaseService.getDeviceRunsUsed(
        fingerprint,
      ).timeout(const Duration(seconds: 6));
    } catch (e) {
      // Offline — use local count
      serverCount = localCount;
    }

    // Use the higher value to prevent bypass via local storage clearing
    final resolvedCount = _boundedRunsUsed(
      localCount > serverCount ? localCount : serverCount,
    );
    if (resolvedCount != localCount) {
      await _writeLocalRunsUsed(resolvedCount);
    }
    return resolvedCount;
  }

  /// Check if a transcription run is allowed.
  static Future<bool> canRun() async {
    final used = await getRunsUsed();
    return used < QuotaConstants.maxFreeRuns;
  }

  /// Get remaining free runs.
  static Future<int> getRemainingRuns() async {
    final used = await getRunsUsed();
    return (QuotaConstants.maxFreeRuns - used)
        .clamp(0, QuotaConstants.maxFreeRuns)
        .toInt();
  }

  /// Consume one transcription run. Returns the new total used count.
  static Future<int> consumeRun(String uid) =>
      _serializeQuotaOperation(() => _consumeRun(uid));

  static Future<int> _consumeRun(String uid) async {
    final fingerprint = await getDeviceFingerprint();
    final localCount = await _readLocalRunsUsed();
    if (localCount >= QuotaConstants.maxFreeRuns) {
      throw QuotaLimitReachedException(QuotaConstants.maxFreeRuns);
    }

    // Increment on server (atomic)
    int newCount;
    try {
      newCount = await FirebaseService.incrementDeviceQuota(
        fingerprint,
        uid,
        minimumRunsUsed: localCount,
        maxRuns: QuotaConstants.maxFreeRuns,
      ).timeout(const Duration(seconds: 8));
    } on QuotaLimitReachedException {
      await _writeLocalRunsUsed(QuotaConstants.maxFreeRuns);
      rethrow;
    } catch (_) {
      // Offline fallback — increment locally
      newCount = localCount + 1;
    }

    // A stale server response can never lower the monotonic local count.
    newCount = _boundedRunsUsed(newCount < localCount ? localCount : newCount);
    await _writeLocalRunsUsed(newCount);

    // Bind UID to device if not already
    final existingUid = await _storage.read(key: QuotaConstants.boundUidKey);
    if (existingUid == null) {
      await _storage.write(key: QuotaConstants.boundUidKey, value: uid);
    }

    return newCount;
  }

  static Future<int> _readLocalRunsUsed() async {
    final localValue = await _storage.read(key: QuotaConstants.runsUsedKey);
    return _boundedRunsUsed(int.tryParse(localValue ?? '0') ?? 0);
  }

  static Future<void> _writeLocalRunsUsed(int count) {
    return _storage.write(
      key: QuotaConstants.runsUsedKey,
      value: _boundedRunsUsed(count).toString(),
    );
  }

  static int _boundedRunsUsed(int count) {
    return count.clamp(0, QuotaConstants.maxFreeRuns).toInt();
  }

  static Future<T> _serializeQuotaOperation<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _quotaOperationTail = _quotaOperationTail.catchError((Object _) {}).then((
      _,
    ) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Store the current user UID in secure storage.
  static Future<void> storeCurrentUid(String uid) async {
    await _storage.write(key: QuotaConstants.currentUidKey, value: uid);
  }

  /// Clear current UID on logout (but keep device fingerprint and runs_used).
  static Future<void> clearCurrentUid() async {
    await _storage.delete(key: QuotaConstants.currentUidKey);
  }

  /// Get the locally bound UID for this device, if available.
  static Future<String?> getBoundUid() async {
    return _storage.read(key: QuotaConstants.boundUidKey);
  }
}
