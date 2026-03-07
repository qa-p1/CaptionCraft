import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_button.dart';

class QuotaExhaustedScreen extends StatelessWidget {
  const QuotaExhaustedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icon
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: kWarning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.hourglass_empty_rounded,
                  color: kWarning,
                  size: 40,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Free Runs Exhausted',
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: kTextPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'You\'ve used all 3 free transcription runs on this device. '
                'Upgrade to continue creating subtitles.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  color: kTextSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),
              AppButton(
                label: 'Upgrade',
                icon: Icons.rocket_launch_rounded,
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: kSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      title: Text(
                        'Coming Soon',
                        style: GoogleFonts.inter(
                          color: kTextPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      content: Text(
                        'Premium subscriptions are coming soon! '
                        'Stay tuned for unlimited transcriptions.',
                        style: GoogleFonts.inter(
                          color: kTextSecondary,
                          fontSize: 14,
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                },
                width: 200,
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Go Back',
                  style: GoogleFonts.inter(
                    color: kTextSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
