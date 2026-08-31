import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Browsing stock media can otherwise leave hundreds of full-size thumbnails
  // in Flutter's process-wide cache. Keep a bounded working set so returning
  // to the editor does not carry that memory (and heat) for the whole session.
  PaintingBinding.instance.imageCache
    ..maximumSize = 180
    ..maximumSizeBytes = 64 * 1024 * 1024;

  // The tracked template keeps clean checkouts buildable. Real credentials are
  // supplied with `--dart-define-from-file=.env` and are never committed.
  await dotenv.load(fileName: '.env.example');

  var launchMode = CaptionCraftLaunchMode.cloud;
  if (!kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows &&
      !DefaultFirebaseOptions.isConfiguredForCurrentPlatform) {
    // This repository has no provisioned Firebase desktop application. Run a
    // truthful local-first editor on Windows instead of crashing at startup or
    // inventing credentials from another platform.
    launchMode = CaptionCraftLaunchMode.localDesktop;
  } else {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      try {
        await FirebaseAppCheck.instance.activate(
          providerAndroid: kDebugMode
              ? AndroidProvider.debug
              : AndroidProvider.playIntegrity,
          providerApple: kDebugMode
              ? AppleProvider.debug
              : AppleProvider.appAttestWithDeviceCheckFallback,
        );
      } catch (error, stackTrace) {
        // Core auth and local editing remain available. Services that require
        // App Check (notably the production transcription proxy) will reject
        // requests with their own actionable message.
        debugPrint('Firebase App Check activation failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    } catch (error, stackTrace) {
      // Do not terminate before Flutter can render a useful recovery message.
      // The detailed exception remains in development logs without exposing
      // configuration values in the user-facing UI.
      debugPrint('Firebase initialization failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      launchMode = CaptionCraftLaunchMode.startupFailure;
    }
  }

  runApp(ProviderScope(child: CaptionCraftApp(launchMode: launchMode)));
}
