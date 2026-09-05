import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum ApiService {
  groq('Groq', 'Automatic captions', 'https://console.groq.com/keys'),
  giphy(
    'GIPHY',
    'GIFs and stickers',
    'https://developers.giphy.com/dashboard/',
  ),
  pexels('Pexels', 'Stock photos and videos', 'https://www.pexels.com/api/'),
  pixabay(
    'Pixabay',
    'Photos, illustrations and videos',
    'https://pixabay.com/api/docs/',
  );

  const ApiService(this.label, this.description, this.signupUrl);
  final String label;
  final String description;
  final String signupUrl;
}

/// Storage is injectable so encryption, offline saves and account isolation can
/// be verified without native plugins or a live user account.
abstract interface class VaultStorage {
  Future<Map<String, dynamic>?> readLocal();
  Future<void> writeLocal(Map<String, dynamic> record);
  Future<Map<String, dynamic>?> readCloud();
  Future<void> writeCloud(Map<String, dynamic> envelope, int expectedRevision);
}

class DeviceVaultStorage implements VaultStorage {
  DeviceVaultStorage(this.uid);
  final String uid;
  static const _secure = FlutterSecureStorage();
  String get _localKey =>
      'captioncraft_api_vault_v1_${base64Url.encode(utf8.encode(uid))}';
  DocumentReference<Map<String, dynamic>> get _document => FirebaseFirestore
      .instance
      .collection('users')
      .doc(uid)
      .collection('private')
      .doc('apiKeys');

  @override
  Future<Map<String, dynamic>?> readLocal() async {
    final raw = await _secure.read(key: _localKey);
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  @override
  Future<void> writeLocal(Map<String, dynamic> record) =>
      _secure.write(key: _localKey, value: jsonEncode(record));

  @override
  Future<Map<String, dynamic>?> readCloud() async =>
      (await _document
              .get(const GetOptions(source: Source.server))
              .timeout(const Duration(seconds: 8)))
          .data();

  @override
  Future<void> writeCloud(
    Map<String, dynamic> envelope,
    int expectedRevision,
  ) => FirebaseFirestore.instance
      .runTransaction((transaction) async {
        final current = await transaction.get(_document);
        if (current.data()?['nonce'] == envelope['nonce'] &&
            current.data()?['ciphertext'] == envelope['ciphertext'] &&
            current.data()?['mac'] == envelope['mac'] &&
            current.data()?['revision'] == envelope['revision']) {
          return;
        }
        if ((current.data()?['revision'] ?? 0) != expectedRevision) {
          throw StateError('The cloud backup changed on another device.');
        }
        transaction.set(_document, envelope);
      })
      .timeout(const Duration(seconds: 10));
}

/// Only the currently signed-in account is exposed to API clients. Changing
/// accounts retires the old vault synchronously, even during an async restore.
class ApiKeys {
  ApiKeys._();
  static ApiKeyVault? _active;
  static ApiKeyVault? get active => _active;
  static String key(ApiService service) => _active?.key(service) ?? '';

  static void selectOwner(String? uid, {bool cloud = true}) {
    if (_active?.uid == uid && _active?.cloud == cloud) return;
    _active?.retire();
    _active = uid == null
        ? null
        : ApiKeyVault(uid: uid, cloud: cloud, storage: DeviceVaultStorage(uid));
    if (_active != null) unawaited(_active!.initialize());
  }
}

class ApiKeyVault extends ChangeNotifier {
  ApiKeyVault({required this.uid, required this.cloud, required this.storage});
  final String uid;
  final bool cloud;
  final VaultStorage storage;
  final _cipher = AesGcm.with256bits();
  Map<String, String> _keys = {};
  Map<String, dynamic>? _envelope;
  String _secret = '';
  int _revision = 0;
  bool _retired = false;
  bool _disposed = false;
  bool ready = false;
  bool loading = true;
  bool busy = false;
  bool seenSetup = false;
  bool locked = false;
  bool pendingSync = false;
  String? error;
  Future<void>? _initializing;

  String key(ApiService service) => _retired ? '' : _keys[service.name] ?? '';
  String get recoveryCode => _retired ? '' : _secret;
  bool get isRetired => _retired;

  void retire() {
    _retired = true;
    _keys = {};
    _secret = '';
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _retired = true;
    _keys = {};
    _secret = '';
    super.dispose();
  }

  void _checkSession() {
    if (_retired) throw StateError('Account changed. Reopen Settings.');
  }

  static String normalize(String value) {
    var result = value.trim();
    if (result.length >= 2 &&
        ((result.startsWith('"') && result.endsWith('"')) ||
            (result.startsWith("'") && result.endsWith("'")))) {
      result = result.substring(1, result.length - 1).trim();
    }
    if (result.length > 512 || RegExp(r'[^\x21-\x7e]').hasMatch(result)) {
      throw const FormatException(
        'Paste only the API key, without spaces or line breaks.',
      );
    }
    return result;
  }

  Future<void> initialize() => _initializing ??= _load();

  Future<void> _load() async {
    try {
      final record = await storage.readLocal();
      _checkSession();
      if (record != null) {
        _secret = record['secret'] as String? ?? '';
        seenSetup = record['seen'] == true;
        pendingSync = record['pending'] == true;
        _revision = record['revision'] as int? ?? 0;
        final envelope = record['envelope'];
        if (envelope is Map) {
          _envelope = Map<String, dynamic>.from(envelope);
          final keys = await _decrypt(_envelope!, _secret);
          _checkSession();
          _keys = keys;
        }
      }
      ready = true;
      if (!_retired) notifyListeners();
      if (cloud && !pendingSync) {
        try {
          final remote = await storage.readCloud();
          _checkSession();
          if (remote != null) {
            seenSetup = true;
            _envelope = remote;
            _revision = remote['revision'] as int;
            try {
              final keys = await _decrypt(remote, _secret);
              _checkSession();
              _keys = keys;
            } catch (_) {
              _checkSession();
              _keys = {};
              locked = true;
              error =
                  'Unlock your encrypted backup with your recovery code in Settings.';
            }
            if (!locked) {
              // A disk failure must not be mistaken for an invalid recovery
              // code or erase keys that were successfully decrypted.
              try {
                await _persist();
              } catch (_) {
                _checkSession();
                error =
                    'Cloud keys loaded, but could not be remembered on this device. Check device storage and save again.';
              }
            }
          }
        } catch (_) {
          _checkSession();
          error =
              'Cloud backup is unavailable. Saved keys on this device still work.';
        }
      }
    } catch (_) {
      if (!_retired) {
        error =
            'Secure storage could not be opened. Restart the app to try again; editing still works.';
      }
    } finally {
      loading = false;
      if (!_retired) notifyListeners();
    }
  }

  Future<Map<String, String>> _decrypt(
    Map<String, dynamic> envelope,
    String code,
  ) async {
    if (envelope['version'] != 1) {
      throw const FormatException('Unsupported vault');
    }
    final keyBytes = base64Url.decode(code.trim());
    if (keyBytes.length != 32) {
      throw const FormatException('Invalid recovery code');
    }
    final clear = await _cipher.decrypt(
      SecretBox(
        base64Decode(envelope['ciphertext'] as String),
        nonce: base64Decode(envelope['nonce'] as String),
        mac: Mac(base64Decode(envelope['mac'] as String)),
      ),
      secretKey: SecretKey(keyBytes),
      aad: utf8.encode('captioncraft:api-keys:v1:$uid'),
    );
    final data = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(clear)) as Map,
    );
    return {
      for (final service in ApiService.values)
        service.name: normalize(data[service.name] as String? ?? ''),
    };
  }

  Future<void> _persist() {
    _checkSession();
    return storage.writeLocal({
      'secret': _secret,
      'envelope': _envelope,
      'revision': _revision,
      'seen': seenSetup,
      'pending': pendingSync,
    });
  }

  Future<void> dismissSetup() async {
    await initialize();
    _checkSession();
    if (!ready || busy) return;
    seenSetup = true;
    await _persist();
  }

  /// Saves locally before attempting the cloud. A failed/conflicting cloud
  /// write leaves a durable pending record; it never overwrites a newer vault.
  Future<void> save(Map<ApiService, String> values) async {
    await _save(values);
  }

  /// Requires an explicit destructive confirmation in Settings. The previous
  /// cloud revision is still checked, so another device cannot be overwritten
  /// silently. This does not revoke keys at their providers.
  Future<void> replaceLockedBackup() => _save({}, replaceBackup: true);

  Future<void> _save(
    Map<ApiService, String> values, {
    bool replaceBackup = false,
  }) async {
    await initialize();
    _checkSession();
    if (!ready ||
        (locked && !replaceBackup) ||
        busy ||
        (replaceBackup && (!cloud || !locked))) {
      throw StateError('Unlock secure storage before saving.');
    }
    final normalized = {
      for (final s in ApiService.values) s.name: normalize(values[s] ?? ''),
    };
    busy = true;
    error = null;
    notifyListeners();
    try {
      final secret = _secret.isEmpty || replaceBackup
          ? base64Url.encode(
              await (await _cipher.newSecretKey()).extractBytes(),
            )
          : _secret;
      final box = await _cipher.encrypt(
        utf8.encode(jsonEncode(normalized)),
        secretKey: SecretKey(base64Url.decode(secret)),
        aad: utf8.encode('captioncraft:api-keys:v1:$uid'),
      );
      _checkSession();
      final envelope = <String, dynamic>{
        'version': 1,
        'revision': _revision + 1,
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      };
      await storage.writeLocal({
        'secret': secret,
        'envelope': envelope,
        'revision': _revision,
        'seen': true,
        'pending': cloud,
      });
      _checkSession();
      _secret = secret;
      _envelope = envelope;
      _keys = normalized;
      locked = false;
      seenSetup = true;
      pendingSync = cloud;
      if (cloud) await _sync();
    } catch (_) {
      _checkSession();
      error =
          'Keys could not be saved securely. Your previous saved keys are unchanged.';
      rethrow;
    } finally {
      busy = false;
      if (!_retired) notifyListeners();
    }
  }

  Future<void> _sync() async {
    try {
      await storage.writeCloud(_envelope!, _revision);
      _checkSession();
      _revision = _envelope!['revision'] as int;
      pendingSync = false;
      await _persist();
    } catch (_) {
      _checkSession();
      pendingSync = true;
      error =
          'Keys saved on this device. Cloud backup is pending. Retry when online. If another device changed the backup, restore it before editing.';
    }
  }

  Future<void> retrySync() async {
    await initialize();
    _checkSession();
    if (!pendingSync || busy || _envelope == null) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _sync();
    } finally {
      busy = false;
      if (!_retired) notifyListeners();
    }
  }

  /// Explicit restore, including after a conflict. Caller confirms replacement
  /// of local edits. A wrong code never destroys the local record.
  Future<void> restore(String code) async {
    await initialize();
    _checkSession();
    if (!cloud || busy) return;
    busy = true;
    notifyListeners();
    try {
      final remote = await storage.readCloud();
      if (remote == null) throw const FormatException('No backup');
      final keys = await _decrypt(remote, code);
      _checkSession();
      await storage.writeLocal({
        'secret': code.trim(),
        'envelope': remote,
        'revision': remote['revision'],
        'seen': true,
        'pending': false,
      });
      _checkSession();
      _keys = keys;
      _secret = code.trim();
      _envelope = remote;
      _revision = remote['revision'] as int;
      ready = true;
      locked = false;
      seenSetup = true;
      pendingSync = false;
      error = null;
    } catch (_) {
      _checkSession();
      error =
          'Could not unlock the backup. Check your recovery code and connection.';
      rethrow;
    } finally {
      busy = false;
      if (!_retired) notifyListeners();
    }
  }
}
