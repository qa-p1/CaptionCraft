import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
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

  var firebaseReady = false;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firebaseReady = true;
  } catch (error, stackTrace) {
    // Do not terminate before Flutter can render a useful recovery message.
    // The detailed exception remains in development logs without exposing
    // configuration values in the user-facing UI.
    debugPrint('Firebase initialization failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  }

  runApp(
    ProviderScope(
      child: CaptionCraftApp(startupFailure: !firebaseReady),
    ),
  );
}
