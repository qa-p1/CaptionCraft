import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

/// Single source of truth wrapper for Firebase Auth + Firestore operations.
class FirebaseService {
  FirebaseService._();

  static const Duration _authTimeout = Duration(seconds: 20);
  static const Duration _requestTimeout = Duration(seconds: 12);
  static const Duration _projectListTimeout = Duration(seconds: 35);
  static final Map<String, Future<void>> _projectWriteQueues = {};
  static final Map<String, DateTime> _latestQueuedProjectWrite = {};

  static bool get isAvailable => Firebase.apps.isNotEmpty;

  static FirebaseAuth get _auth {
    if (!isAvailable) {
      throw StateError('Firebase is not initialized.');
    }
    return FirebaseAuth.instance;
  }

  static FirebaseFirestore get _firestore {
    if (!isAvailable) {
      throw StateError('Firebase is not initialized.');
    }
    return FirebaseFirestore.instance;
  }

  // ─── Auth ───

  static User? get currentUser => isAvailable ? _auth.currentUser : null;

  static Stream<User?> get authStateChanges {
    if (!isAvailable) {
      return Stream<User?>.value(null);
    }
    return _auth.authStateChanges();
  }

  static Future<UserCredential> signIn(String email, String password) async {
    return _auth
        .signInWithEmailAndPassword(email: email.trim(), password: password)
        .timeout(_authTimeout);
  }

  static Future<UserCredential> register(
    String email,
    String password,
    String displayName,
  ) async {
    final credential = await _auth
        .createUserWithEmailAndPassword(email: email.trim(), password: password)
        .timeout(_authTimeout);
    try {
      await credential.user
          ?.updateDisplayName(displayName.trim())
          .timeout(_requestTimeout);
    } catch (_) {
      // Account creation is already committed. Keep registration successful
      // and let the profile document preserve the requested display name.
    }

    // Create user profile document in Firestore
    try {
      await _firestore
          .collection('users')
          .doc(credential.user!.uid)
          .set({
            'email': email.trim(),
            'displayName': displayName.trim(),
            'createdAt': FieldValue.serverTimestamp(),
            'lastLoginAt': FieldValue.serverTimestamp(),
          })
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Auth account creation should still succeed even if profile sync is delayed.
    }

    return credential;
  }

  static Future<void> signOut() async {
    await _auth.signOut().timeout(_authTimeout);
  }

  static Future<void> sendPasswordReset(String email) async {
    await _auth
        .sendPasswordResetEmail(email: email.trim())
        .timeout(_authTimeout);
  }

  static Future<void> updateDisplayName(String displayName) async {
    final user = currentUser;
    if (user == null) {
      throw StateError('No signed-in account is available.');
    }
    final normalizedName = displayName.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(displayName, 'displayName', 'Cannot be empty.');
    }
    await user.updateDisplayName(normalizedName).timeout(_requestTimeout);
    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .set({'displayName': normalizedName}, SetOptions(merge: true))
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Auth remains the source of truth while profile sync is offline.
    }
  }

  static Future<void> updateLastLogin() async {
    final uid = currentUser?.uid;
    if (uid == null) return;
    try {
      await _firestore
          .collection('users')
          .doc(uid)
          .set({
            'email': currentUser?.email ?? '',
            'displayName':
                currentUser?.displayName ??
                currentUser?.email?.split('@').first ??
                '',
            'lastLoginAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true))
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Authentication is successful even when profile telemetry is offline.
    }
  }

  // ─── Projects ───

  static CollectionReference<Map<String, dynamic>> _userProjectsRef(
    String uid,
  ) {
    return _firestore
        .collection('projects')
        .doc(uid)
        .collection('user_projects');
  }

  static Future<void> saveProject(
    String uid,
    String projectId,
    Map<String, dynamic> data,
  ) async {
    final queueKey = '$uid::$projectId';
    final payload = Map<String, dynamic>.from(data);
    final ownerUid = payload['ownerUid'];
    if (ownerUid != null && ownerUid != uid) {
      throw StateError('Cannot save a project owned by another account.');
    }
    payload['ownerUid'] = uid;
    final captions = payload['subtitles'];
    if (captions is List) {
      payload['captionCount'] = captions.length;
    }

    final incomingModifiedAt = _projectModifiedAt(payload['lastModifiedAt']);
    final latestQueuedAt = _latestQueuedProjectWrite[queueKey];
    if (incomingModifiedAt != null &&
        latestQueuedAt != null &&
        incomingModifiedAt.isBefore(latestQueuedAt)) {
      return;
    }
    if (incomingModifiedAt != null) {
      _latestQueuedProjectWrite[queueKey] = incomingModifiedAt;
    }

    final previousWrite = _projectWriteQueues[queueKey] ?? Future<void>.value();
    final nextWrite = () async {
      try {
        await previousWrite;
      } catch (_) {
        // A newer snapshot must still be allowed to repair a failed sync.
      }
      await _userProjectsRef(uid)
          .doc(projectId)
          .set(payload, SetOptions(merge: true))
          .timeout(const Duration(seconds: 8));
    }();
    _projectWriteQueues[queueKey] = nextWrite;

    try {
      await nextWrite;
    } finally {
      if (identical(_projectWriteQueues[queueKey], nextWrite)) {
        _projectWriteQueues.remove(queueKey);
      }
    }
  }

  static Future<void> deleteProject(String uid, String projectId) async {
    final queueKey = '$uid::$projectId';
    final previousWrite = _projectWriteQueues[queueKey] ?? Future<void>.value();
    final deletion = () async {
      try {
        await previousWrite;
      } catch (_) {
        // A delete should still proceed after an unsuccessful pending write.
      }
      await _userProjectsRef(
        uid,
      ).doc(projectId).delete().timeout(_requestTimeout);
    }();
    _projectWriteQueues[queueKey] = deletion;
    try {
      await deletion;
    } finally {
      if (identical(_projectWriteQueues[queueKey], deletion)) {
        _projectWriteQueues.remove(queueKey);
        _latestQueuedProjectWrite.remove(queueKey);
      }
    }
  }

  static Future<List<Map<String, dynamic>>> loadProjects(String uid) async {
    return _loadProjects(uid).timeout(_projectListTimeout);
  }

  static Future<List<Map<String, dynamic>>> _loadProjects(String uid) async {
    const pageSize = 100;
    final projects = <Map<String, dynamic>>[];
    QueryDocumentSnapshot<Map<String, dynamic>>? cursor;

    while (true) {
      Query<Map<String, dynamic>> query = _userProjectsRef(
        uid,
      ).orderBy('lastModifiedAt', descending: true).limit(pageSize);
      if (cursor != null) query = query.startAfterDocument(cursor);

      final snapshot = await query.get().timeout(_requestTimeout);
      projects.addAll(
        snapshot.docs.map((doc) => {...doc.data(), 'id': doc.id}),
      );
      if (snapshot.docs.length < pageSize) break;
      cursor = snapshot.docs.last;
    }

    return projects;
  }

  static Future<Map<String, dynamic>?> loadProject(
    String uid,
    String projectId,
  ) async {
    final doc = await _userProjectsRef(
      uid,
    ).doc(projectId).get().timeout(_requestTimeout);
    if (!doc.exists) return null;
    return {...doc.data()!, 'id': doc.id};
  }

  static DateTime? _projectModifiedAt(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    return null;
  }

  // ─── Quota ───

  static Future<int> getDeviceRunsUsed(String deviceFingerprint) async {
    final doc = await _firestore
        .collection('device_quotas')
        .doc(deviceFingerprint)
        .get()
        .timeout(_requestTimeout);

    if (!doc.exists) return 0;
    return (doc.data()?['runs_used'] as num?)?.toInt() ?? 0;
  }

  /// Atomically increment the device quota. Creates the document if needed.
  static Future<int> incrementDeviceQuota(
    String deviceFingerprint,
    String uid, {
    required int minimumRunsUsed,
    required int maxRuns,
  }) async {
    final docRef = _firestore
        .collection('device_quotas')
        .doc(deviceFingerprint);

    return _firestore
        .runTransaction<int>((transaction) async {
          final snapshot = await transaction.get(docRef);

          final storedRuns =
              (snapshot.data()?['runs_used'] as num?)?.toInt() ?? 0;
          final currentRuns = math.max(storedRuns, minimumRunsUsed);
          if (currentRuns >= maxRuns) {
            throw QuotaLimitReachedException(maxRuns);
          }
          final newRuns = currentRuns + 1;

          if (!snapshot.exists) {
            transaction.set(docRef, {
              'runs_used': newRuns,
              'bound_uid': uid,
              'created_at': FieldValue.serverTimestamp(),
              'last_used_at': FieldValue.serverTimestamp(),
            });
            return newRuns;
          }

          transaction.update(docRef, {
            'runs_used': newRuns,
            'last_used_at': FieldValue.serverTimestamp(),
          });

          return newRuns;
        })
        .timeout(_requestTimeout);
  }
}

class QuotaLimitReachedException implements Exception {
  final int maxRuns;

  const QuotaLimitReachedException(this.maxRuns);

  @override
  String toString() => 'The device quota of $maxRuns runs has been reached.';
}
