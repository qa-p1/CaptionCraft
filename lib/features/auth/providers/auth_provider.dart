import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../../core/utils/firebase_service.dart';
import '../../../core/utils/device_quota_service.dart';

/// Stream of auth state changes — null means signed out.
final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseService.authStateChanges;
});

/// Convenience provider for the current user.
final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(authStateProvider).asData?.value;
});

/// Notifier for auth operations (sign in, register, sign out, Google).
final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AsyncValue<void>>((ref) {
      return AuthNotifier();
    });

class AuthNotifier extends StateNotifier<AsyncValue<void>> {
  AuthNotifier() : super(const AsyncData(null));

  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  bool _googleInitialized = false;

  Future<void> _initializeGoogleSignInIfNeeded() async {
    if (_googleInitialized) return;
    await _googleSignIn.initialize(
      serverClientId:
          '241322582096-j050snpnngiat8brn22va6ln4fk7a370.apps.googleusercontent.com',
    );
    _googleInitialized = true;
  }

  Future<void> signIn(String email, String password) async {
    state = const AsyncLoading();
    try {
      await FirebaseService.signIn(email, password);
      final uid = FirebaseService.currentUser?.uid;
      if (uid != null) {
        await DeviceQuotaService.storeCurrentUid(uid);
        await FirebaseService.updateLastLogin();
      }
      state = const AsyncData(null);
    } on FirebaseAuthException catch (e) {
      state = AsyncError(_mapFirebaseError(e.code), StackTrace.current);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> register(String name, String email, String password) async {
    state = const AsyncLoading();
    try {
      await FirebaseService.register(email, password, name);
      final uid = FirebaseService.currentUser?.uid;
      if (uid != null) {
        await DeviceQuotaService.storeCurrentUid(uid);
      }
      state = const AsyncData(null);
    } on FirebaseAuthException catch (e) {
      state = AsyncError(_mapFirebaseError(e.code), StackTrace.current);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> signInWithGoogle() async {
    state = const AsyncLoading();
    try {
      await _initializeGoogleSignInIfNeeded();
      final googleUser = await _googleSignIn.authenticate();

      final googleAuth = googleUser.authentication;
      if (googleAuth.idToken == null || googleAuth.idToken!.isEmpty) {
        throw Exception('Google sign-in failed: missing ID token.');
      }
      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(credential);
      final uid = FirebaseService.currentUser?.uid;
      if (uid != null) {
        await DeviceQuotaService.storeCurrentUid(uid);
        await FirebaseService.updateLastLogin();
      }
      state = const AsyncData(null);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        state = const AsyncData(null);
        return;
      }
      state = AsyncError(
        e.description ?? 'Google sign-in failed.',
        StackTrace.current,
      );
    } on FirebaseAuthException catch (e) {
      state = AsyncError(_mapFirebaseError(e.code), StackTrace.current);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> signOut() async {
    state = const AsyncLoading();
    try {
      // Firebase sign-out must not depend on the optional Google SDK. Email
      // accounts and devices without a configured Google provider still need
      // a reliable way out of the session.
      try {
        await _initializeGoogleSignInIfNeeded();
        await _googleSignIn.signOut();
      } catch (_) {
        // Clearing the Firebase session below is the authoritative sign-out.
      }
      await DeviceQuotaService.clearCurrentUid();
      await FirebaseService.signOut();
      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> sendPasswordReset(String email) async {
    state = const AsyncLoading();
    try {
      await FirebaseService.sendPasswordReset(email);
      state = const AsyncData(null);
    } on FirebaseAuthException catch (e) {
      state = AsyncError(_mapFirebaseError(e.code), StackTrace.current);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  /// Map Firebase error codes to user-friendly messages.
  static String _mapFirebaseError(String code) {
    switch (code) {
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'user-not-found':
        return 'No account found with this email.';
      case 'email-already-in-use':
        return 'An account with this email already exists.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'too-many-requests':
        return 'Too many login attempts. Please wait a few minutes and try again.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'operation-not-allowed':
        return 'This sign-in method is not enabled.';
      default:
        return 'Authentication error. Please try again.';
    }
  }
}
