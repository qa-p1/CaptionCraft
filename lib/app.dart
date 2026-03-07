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
        loading: () => const Scaffold(
          backgroundColor: kBackground,
          body: Center(
            child: CircularProgressIndicator(
              color: kAccent,
              strokeWidth: 2,
            ),
          ),
        ),
        error: (e, st) => const LoginScreen(),
      ),
    );
  }
}
