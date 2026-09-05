import 'dart:async';
import 'dart:convert';

import 'package:caption_craft/core/utils/api_key_vault.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic>? copyRecord(Map<String, dynamic>? value) => value == null
    ? null
    : Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

class MemoryVaultStorage implements VaultStorage {
  Map<String, dynamic>? local;
  Map<String, dynamic>? remote;
  bool offline = false;
  bool failLocalWrite = false;
  Completer<void>? readGate;
  Completer<void>? cloudReadGate;

  @override
  Future<Map<String, dynamic>?> readLocal() async {
    await readGate?.future;
    return copyRecord(local);
  }

  @override
  Future<void> writeLocal(Map<String, dynamic> record) async {
    if (failLocalWrite) throw StateError('disk unavailable');
    local = copyRecord(record);
  }

  @override
  Future<Map<String, dynamic>?> readCloud() async {
    await cloudReadGate?.future;
    if (offline) throw StateError('offline');
    return copyRecord(remote);
  }

  @override
  Future<void> writeCloud(Map<String, dynamic> record, int revision) async {
    if (offline) throw StateError('offline');
    if ((remote?['revision'] ?? 0) != revision) throw StateError('conflict');
    remote = copyRecord(record);
  }
}

void main() {
  late MemoryVaultStorage storage;
  late ApiKeyVault vault;
  setUp(() {
    storage = MemoryVaultStorage();
    vault = ApiKeyVault(uid: 'alice', cloud: true, storage: storage);
  });

  test(
    'keys are encrypted before cloud upload and restored on same device',
    () async {
      await vault.save({
        ApiService.groq: 'gsk_private-user-key',
        ApiService.pexels: 'photo-key',
      });
      expect(jsonEncode(storage.remote), isNot(contains('private-user-key')));
      expect(jsonEncode(storage.remote), isNot(contains(vault.recoveryCode)));
      expect(storage.remote!.keys.toSet(), {
        'version',
        'revision',
        'nonce',
        'ciphertext',
        'mac',
      });
      expect(base64Decode(storage.remote!['nonce'] as String), hasLength(12));
      expect(base64Decode(storage.remote!['mac'] as String), hasLength(16));
      final reopened = ApiKeyVault(uid: 'alice', cloud: true, storage: storage);
      await reopened.initialize();
      expect(reopened.key(ApiService.groq), 'gsk_private-user-key');
      expect(reopened.seenSetup, isTrue);
      expect(reopened.locked, isFalse);
    },
  );

  test(
    'new device unlocks encrypted cloud keys once with recovery code',
    () async {
      await vault.save({ApiService.groq: 'gsk_user'});
      final device = MemoryVaultStorage()..remote = copyRecord(storage.remote);
      final next = ApiKeyVault(uid: 'alice', cloud: true, storage: device);
      await next.initialize();
      expect(next.locked, isTrue);
      expect(next.key(ApiService.groq), isEmpty);
      await expectLater(next.restore('wrong'), throwsA(anything));
      expect(device.local, isNull);
      await next.restore(vault.recoveryCode);
      expect(next.key(ApiService.groq), 'gsk_user');
      final reopened = ApiKeyVault(uid: 'alice', cloud: true, storage: device);
      await reopened.initialize();
      expect(reopened.key(ApiService.groq), 'gsk_user');
    },
  );

  test(
    'authenticated encryption rejects tampering and another account',
    () async {
      await vault.save({ApiService.groq: 'gsk_user'});
      final otherStorage = MemoryVaultStorage()
        ..remote = copyRecord(storage.remote);
      final other = ApiKeyVault(uid: 'bob', cloud: true, storage: otherStorage);
      await expectLater(other.restore(vault.recoveryCode), throwsA(anything));
      expect(other.key(ApiService.groq), isEmpty);
      storage.remote!['mac'] = base64Encode(List.filled(16, 0));
      await expectLater(vault.restore(vault.recoveryCode), throwsA(anything));
      expect(vault.key(ApiService.groq), 'gsk_user');
    },
  );

  test('offline saves survive restart and can sync later', () async {
    storage.offline = true;
    await vault.save({ApiService.giphy: 'gif-key'});
    expect(vault.pendingSync, isTrue);
    expect(vault.key(ApiService.giphy), 'gif-key');
    expect(storage.remote, isNull);
    final reopened = ApiKeyVault(uid: 'alice', cloud: true, storage: storage);
    await reopened.initialize();
    expect(reopened.key(ApiService.giphy), 'gif-key');
    storage.offline = false;
    await reopened.retrySync();
    expect(reopened.pendingSync, isFalse);
    expect(storage.remote!['revision'], 1);
  });

  test(
    'conflicting cloud writes preserve remote and local pending changes',
    () async {
      await vault.save({ApiService.groq: 'first'});
      final oldRemote = copyRecord(storage.remote)!;
      storage.remote!['revision'] = 2;
      await vault.save({ApiService.groq: 'local-new'});
      expect(vault.key(ApiService.groq), 'local-new');
      expect(vault.pendingSync, isTrue);
      expect(storage.remote!['ciphertext'], oldRemote['ciphertext']);
      expect(storage.local!['pending'], isTrue);
    },
  );

  test(
    'secure storage write failure preserves previously saved keys',
    () async {
      await vault.save({ApiService.groq: 'first'});
      storage.failLocalWrite = true;
      await expectLater(
        vault.save({ApiService.groq: 'new'}),
        throwsA(anything),
      );
      expect(vault.key(ApiService.groq), 'first');
      expect(storage.remote!['revision'], 1);
    },
  );

  test(
    'removing keys persists and every encryption gets a fresh nonce',
    () async {
      await vault.save({ApiService.groq: 'first'});
      final nonce = storage.remote!['nonce'];
      await vault.save({});
      expect(vault.key(ApiService.groq), isEmpty);
      expect(storage.remote!['nonce'], isNot(nonce));
      final next = ApiKeyVault(uid: 'alice', cloud: true, storage: storage);
      await next.initialize();
      expect(next.key(ApiService.groq), isEmpty);
    },
  );

  test('account retirement during restore never exposes prior keys', () async {
    await vault.save({ApiService.groq: 'first'});
    storage.readGate = Completer<void>();
    final next = ApiKeyVault(uid: 'alice', cloud: true, storage: storage);
    final pending = next.initialize();
    next.retire();
    storage.readGate!.complete();
    await pending;
    expect(next.key(ApiService.groq), isEmpty);
    expect(next.recoveryCode, isEmpty);
    await expectLater(next.save({ApiService.groq: 'other'}), throwsStateError);
  });

  test(
    'skip remembered locally without needing any service or cloud',
    () async {
      final local = ApiKeyVault(uid: 'local', cloud: false, storage: storage);
      await local.dismissSetup();
      expect(storage.remote, isNull);
      final reopened = ApiKeyVault(
        uid: 'local',
        cloud: false,
        storage: storage,
      );
      await reopened.initialize();
      expect(reopened.seenSetup, isTrue);
      for (final s in ApiService.values) {
        expect(reopened.key(s), isEmpty);
      }
    },
  );

  test('keys normalize surrounding quotes and reject header injection', () {
    expect(ApiKeyVault.normalize(' "gsk_key" '), 'gsk_key');
    expect(ApiKeyVault.normalize(''), isEmpty);
    expect(
      () => ApiKeyVault.normalize('key\r\nAuthorization: injected'),
      throwsFormatException,
    );
    expect(() => ApiKeyVault.normalize('a' * 513), throwsFormatException);
  });

  test('cloud hydration disk failure keeps decrypted keys usable', () async {
    await vault.save({ApiService.groq: 'remembered'});
    storage.failLocalWrite = true;
    final reopened = ApiKeyVault(uid: 'alice', cloud: true, storage: storage);
    await reopened.initialize();
    expect(reopened.key(ApiService.groq), 'remembered');
    expect(reopened.locked, isFalse);
    expect(reopened.error, contains('could not be remembered'));
  });

  test(
    'lost recovery code replacement creates a new encrypted empty backup',
    () async {
      await vault.save({ApiService.groq: 'old-key'});
      final device = MemoryVaultStorage()..remote = copyRecord(storage.remote);
      final next = ApiKeyVault(uid: 'alice', cloud: true, storage: device);
      await next.initialize();
      expect(next.locked, isTrue);
      await next.replaceLockedBackup();
      expect(next.locked, isFalse);
      expect(next.recoveryCode, isNot(vault.recoveryCode));
      expect(device.remote!['revision'], 2);
      await expectLater(next.restore(vault.recoveryCode), throwsA(anything));
      await next.save({ApiService.groq: 'replacement'});
      expect(next.key(ApiService.groq), 'replacement');
    },
  );

  test('failed replacement preserves the locked backup', () async {
    await vault.save({ApiService.groq: 'old-key'});
    final device = MemoryVaultStorage()
      ..remote = copyRecord(storage.remote)
      ..failLocalWrite = true;
    final next = ApiKeyVault(uid: 'alice', cloud: true, storage: device);
    await next.initialize();
    await expectLater(next.replaceLockedBackup(), throwsA(anything));
    expect(next.locked, isTrue);
    expect(device.remote, storage.remote);
  });
}
