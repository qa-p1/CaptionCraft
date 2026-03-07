import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../constants/quota_constants.dart';
import 'firebase_service.dart';

/// Service for device-level quota enforcement.
/// Each physical device gets exactly 3 free transcription runs,
/// regardless of accounts.
class DeviceQuotaService {
  DeviceQuotaService._();

  static const _storage = FlutterSecureStorage();

  /// Get or create a stable device fingerprint.
  static Future<String> getDeviceFingerprint() async {
    // Check if already stored
    String? fingerprint =
        await _storage.read(key: QuotaConstants.deviceFingerprintKey);
    if (fingerprint != null) return fingerprint;

    // Generate from device info
    final deviceInfo = DeviceInfoPlugin();
    String rawId;

    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      rawId = androidInfo.id; // Android ID
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      rawId = iosInfo.identifierForVendor ?? 'unknown_ios';
    } else {
      rawId = 'unknown_platform';
    }

    // Hash with SHA-256
    fingerprint = sha256.convert(utf8.encode(rawId)).toString();

    // Store permanently
    await _storage.write(
      key: QuotaConstants.deviceFingerprintKey,
      value: fingerprint,
    );

    return fingerprint;
  }

  /// Get the current number of runs used (max of local and server).
  static Future<int> getRunsUsed() async {
    final fingerprint = await getDeviceFingerprint();

    // Local count
    final localStr =
        await _storage.read(key: QuotaConstants.runsUsedKey);
    final localCount = int.tryParse(localStr ?? '0') ?? 0;

    // Server count
    int serverCount;
    try {
      serverCount = await FirebaseService.getDeviceRunsUsed(fingerprint)
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      // Offline — use local count
      serverCount = 0;
    }

    // Use the higher value to prevent bypass via local storage clearing
    return localCount > serverCount ? localCount : serverCount;
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
  static Future<int> consumeRun(String uid) async {
    final fingerprint = await getDeviceFingerprint();

    // Increment on server (atomic)
    int newCount;
    try {
      newCount =
          await FirebaseService.incrementDeviceQuota(fingerprint, uid)
              .timeout(const Duration(seconds: 8));
    } catch (e) {
      // Offline fallback — increment locally
      final localStr =
          await _storage.read(key: QuotaConstants.runsUsedKey);
      newCount = (int.tryParse(localStr ?? '0') ?? 0) + 1;
    }

    // Update local count
    await _storage.write(
      key: QuotaConstants.runsUsedKey,
      value: newCount.toString(),
    );

    // Bind UID to device if not already
    final existingUid =
        await _storage.read(key: QuotaConstants.boundUidKey);
    if (existingUid == null) {
      await _storage.write(
        key: QuotaConstants.boundUidKey,
        value: uid,
      );
    }

    return newCount;
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
