import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/models/processing_state.dart';

/// Fun facts shown while processing.
const _funFacts = [
  'The first subtitled film was "The Jazz Singer" in 1927.',
  'Over 5 billion videos are watched on YouTube every day.',
  'Subtitles increase video engagement by up to 40%.',
  'The average person reads 200-250 words per minute.',
  'Closed captions were first mandated in the US in 1993.',
];

/// Full-screen processing view shown during transcription.
class ProcessingScreen extends ConsumerStatefulWidget {
  final Stream<ProcessingProgress> progressStream;
  final VoidCallback onCancel;

  const ProcessingScreen({
    super.key,
    required this.progressStream,
    required this.onCancel,
  });

  @override
  ConsumerState<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends ConsumerState<ProcessingScreen>
    with TickerProviderStateMixin {
  late AnimationController _waveController;
  late AnimationController _factController;
  StreamSubscription<ProcessingProgress>? _progressSubscription;
  int _currentFactIndex = 0;
  ProcessingProgress _currentProgress = ProcessingProgress.initial();

  @override
  void initState() {
    super.initState();

    // Wave animation — loops continuously
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // Fact rotation — change every 8 seconds
    _factController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
    _factController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _currentFactIndex = (_currentFactIndex + 1) % _funFacts.length;
        });
        _factController.forward(from: 0);
      }
    });

    // Listen to progress
    _progressSubscription = widget.progressStream.listen(
      (progress) {
        if (mounted) {
          setState(() => _currentProgress = progress);
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {
            _currentProgress = ProcessingProgress(
              stage: ProcessingStage.error,
              progress: 0,
              message: error.toString(),
            );
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _waveController.dispose();
    _factController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isError = _currentProgress.stage == ProcessingStage.error;

    return Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 2),

              // Animated waveform
              SizedBox(
                height: 100,
                child: AnimatedBuilder(
                  animation: _waveController,
                  builder: (context, child) {
                    return CustomPaint(
                      size: const Size(double.infinity, 100),
                      painter: _WaveformPainter(
                        animationValue: _waveController.value,
                        color: isError ? kError : kAccent,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 40),

              // Circular progress
              CircularPercentIndicator(
                radius: 60,
                lineWidth: 6,
                percent: _currentProgress.progress.clamp(0, 1).toDouble(),
                center: Text(
                  '${(_currentProgress.progress * 100).round()}%',
                  style: GoogleFonts.spaceMono(
                    color: kTextPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                progressColor: isError ? kError : kAccent,
                backgroundColor: kBorder,
                circularStrokeCap: CircularStrokeCap.round,
                animation: false,
              ),
              const SizedBox(height: 24),

              // Stage label
              Text(
                _currentProgress.message,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: isError ? kError : kTextPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),

              // Chunk info
              if (_currentProgress.currentChunk != null)
                Text(
                  'Chunk ${_currentProgress.currentChunk! + 1} of ${_currentProgress.totalChunks}',
                  style: GoogleFonts.spaceMono(
                    color: kTextSecondary,
                    fontSize: 13,
                  ),
                ),

              const Spacer(),

              // Fun facts
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                child: Container(
                  key: ValueKey(_currentFactIndex),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: kSurface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kBorder),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.lightbulb_outline_rounded,
                          color: kWarning, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _funFacts[_currentFactIndex],
                          style: GoogleFonts.inter(
                            color: kTextSecondary,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Cancel button
              TextButton.icon(
                icon: const Icon(Icons.close_rounded, size: 18),
                label: Text(
                  'Cancel',
                  style: GoogleFonts.inter(fontWeight: FontWeight.w500),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: kError,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                onPressed: widget.onCancel,
              ),

              const Spacer(flex: 1),
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated waveform painter — pulsing sine wave.
class _WaveformPainter extends CustomPainter {
  final double animationValue;
  final Color color;

  _WaveformPainter({required this.animationValue, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final midY = size.height / 2;
    final path = Path();

    // Draw multiple overlapping sine waves
    for (var wave = 0; wave < 3; wave++) {
      final amplitude = (size.height * 0.3) * (1 - wave * 0.2);
      final frequency = 0.02 + wave * 0.005;
      final phase = animationValue * 2 * pi + wave * pi / 3;

      path.reset();
      for (var x = 0.0; x < size.width; x += 2) {
        final y = midY + amplitude * sin(frequency * x + phase);
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      paint.color = color.withValues(alpha: 0.3 + (wave * 0.15));
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.animationValue != animationValue;
}
