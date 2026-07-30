import 'package:flutter/material.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/home/screens/home_screen.dart';
import 'features/auth/providers/auth_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CaptionCraftApp extends ConsumerWidget {
  const CaptionCraftApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        error: (e, st) => const LoginScreen(),
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
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: kAccent,
                    borderRadius: BorderRadius.circular(17),
                    boxShadow: [
                      BoxShadow(
                        color: kAccent.withValues(alpha: 0.2),
                        blurRadius: 28,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.content_cut_rounded,
                    color: kOnAccent,
                    size: 28,
                  ),
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
