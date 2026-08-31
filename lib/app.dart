import 'package:flutter/material.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/firebase_service.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/home/screens/home_screen.dart';
import 'features/auth/providers/auth_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'shared/widgets/app_surface.dart';
import 'shared/widgets/captioncraft_brand.dart';

class CaptionCraftApp extends ConsumerWidget {
  const CaptionCraftApp({super.key, this.startupFailure = false});

  final bool startupFailure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (startupFailure) {
      return MaterialApp(
        title: 'CaptionCraft',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const _AppStartupErrorScreen(),
      );
    }
    final authState = ref.watch(authStateProvider);

    return MaterialApp(
      title: 'CaptionCraft',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: authState.when(
        data: (user) {
          if (user == null) {
            return const LoginScreen();
          }
          return const HomeScreen();
        },
        loading: () => const _AppBootScreen(),
        error: (error, _) {
          // A transient auth-stream failure is not a sign-out event. Keep an
          // already restored Firebase session usable; otherwise offer retry.
          if (FirebaseService.currentUser != null) {
            return const HomeScreen();
          }
          return _AppAuthErrorScreen(
            message: error.toString(),
            onRetry: () => ref.invalidate(authStateProvider),
          );
        },
      ),
    );
  }
}

class _AppStartupErrorScreen extends StatelessWidget {
  const _AppStartupErrorScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 430),
            child: Padding(
              padding: EdgeInsets.all(24),
              child: AppPanel(
                elevated: true,
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: CaptionCraftMark(size: 42, radius: 11),
                    ),
                    AppEmptyState(
                      icon: Icons.cloud_off_rounded,
                      title: 'CaptionCraft could not start securely',
                      message:
                          'Account services could not be initialized. Close and reopen the app. If this continues, install the latest build or contact support.',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppAuthErrorScreen extends StatelessWidget {
  const _AppAuthErrorScreen({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: AppPanel(
                elevated: true,
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: CaptionCraftMark(size: 42, radius: 11),
                    ),
                    AppEmptyState(
                      icon: Icons.cloud_off_rounded,
                      title: 'Could not restore your session',
                      message: message.replaceFirst('Exception: ', ''),
                      action: FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Try again'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppBootScreen extends StatelessWidget {
  const _AppBootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      body: Stack(
        children: [
          const Positioned.fill(
            child: CustomPaint(painter: _BootTimelinePainter()),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(color: Color(0x33FF7548), blurRadius: 28),
                    ],
                  ),
                  child: CaptionCraftMark(size: 62, radius: 17),
                ),
                const SizedBox(height: 20),
                const Text(
                  'CaptionCraft',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  'OPENING YOUR CUT',
                  style: TextStyle(
                    color: kTextSecondary,
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.45,
                  ),
                ),
                const SizedBox(height: 24),
                const SizedBox(
                  width: 88,
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    borderRadius: BorderRadius.all(Radius.circular(999)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BootTimelinePainter extends CustomPainter {
  const _BootTimelinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = kBorder.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    final centerY = size.height * 0.72;
    canvas.drawLine(Offset(0, centerY), Offset(size.width, centerY), line);
    for (var x = 0.0; x < size.width; x += 44) {
      canvas.drawLine(Offset(x, centerY - 10), Offset(x, centerY + 10), line);
    }
    final playhead = Paint()
      ..color = kAccent.withValues(alpha: 0.55)
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(size.width * 0.5, centerY - 30),
      Offset(size.width * 0.5, centerY + 30),
      playhead,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
