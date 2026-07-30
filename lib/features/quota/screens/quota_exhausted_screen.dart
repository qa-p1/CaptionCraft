import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/quota_provider.dart';

class QuotaExhaustedScreen extends ConsumerWidget {
  const QuotaExhaustedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quota = ref.watch(quotaProvider);

    return Scaffold(
      backgroundColor: kBackground,
      body: Stack(
        children: [
          const Positioned.fill(child: CustomPaint(painter: _LimitBackdrop())),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 18, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back to editor',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: kAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'CAPTIONCRAFT / CAPTIONS',
                        style: TextStyle(
                          color: kTextSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight - 50,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 640),
                              child: Container(
                                padding: EdgeInsets.all(
                                  constraints.maxWidth < 430 ? 22 : 32,
                                ),
                                decoration: BoxDecoration(
                                  color: kSurface.withValues(alpha: 0.96),
                                  borderRadius: BorderRadius.circular(28),
                                  border: Border.all(color: kBorder),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.3,
                                      ),
                                      blurRadius: 40,
                                      offset: const Offset(0, 20),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          width: 58,
                                          height: 58,
                                          decoration: BoxDecoration(
                                            color: kWarning.withValues(
                                              alpha: 0.12,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                            border: Border.all(
                                              color: kWarning.withValues(
                                                alpha: 0.28,
                                              ),
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.graphic_eq_rounded,
                                            color: kWarning,
                                            size: 29,
                                          ),
                                        ),
                                        const Spacer(),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: kSurfaceElevated,
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            border: Border.all(color: kBorder),
                                          ),
                                          child: Text(
                                            '${quota.runsUsed.clamp(0, quota.maxRuns)} / ${quota.maxRuns}',
                                            style: const TextStyle(
                                              fontFamily: 'monospace',
                                              color: kWarning,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 28),
                                    const Text(
                                      'Automatic transcription\nlimit reached.',
                                      style: TextStyle(
                                        color: kTextPrimary,
                                        fontSize: 30,
                                        height: 1.08,
                                        letterSpacing: -0.9,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    const Text(
                                      'Only new automatic transcriptions are paused on this device. '
                                      'Your project, timeline, captions, styling tools, and exports remain fully available.',
                                      style: TextStyle(
                                        color: kTextSecondary,
                                        fontSize: 15,
                                        height: 1.55,
                                      ),
                                    ),
                                    const SizedBox(height: 28),
                                    Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: kBackground,
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(color: kBorder),
                                      ),
                                      child: const Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'KEEP CUTTING',
                                            style: TextStyle(
                                              color: kAccentSecondary,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: 1.3,
                                            ),
                                          ),
                                          SizedBox(height: 13),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              _CapabilityPill(
                                                icon: Icons.edit_note_rounded,
                                                label: 'Manual captions',
                                              ),
                                              _CapabilityPill(
                                                icon:
                                                    Icons.file_upload_outlined,
                                                label: 'SRT / VTT import',
                                              ),
                                              _CapabilityPill(
                                                icon: Icons.palette_outlined,
                                                label: 'Caption styling',
                                              ),
                                              _CapabilityPill(
                                                icon: Icons
                                                    .movie_creation_outlined,
                                                label: 'Full video export',
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 26),
                                    SizedBox(
                                      width: double.infinity,
                                      height: 52,
                                      child: FilledButton.icon(
                                        onPressed: () =>
                                            Navigator.of(context).maybePop(),
                                        icon: const Icon(
                                          Icons.arrow_back_rounded,
                                          size: 19,
                                        ),
                                        label: const Text('Continue editing'),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    const Center(
                                      child: Text(
                                        'No project data or existing caption is removed.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: kTextSecondary,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
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

class _CapabilityPill extends StatelessWidget {
  const _CapabilityPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: kAccent, size: 16),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(
              color: kTextPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _LimitBackdrop extends CustomPainter {
  const _LimitBackdrop();

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = kBorder.withValues(alpha: 0.26)
      ..strokeWidth = 1;
    const step = 48.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final accent = Paint()
      ..color = kAccent.withValues(alpha: 0.07)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width * 0.86, size.height * 0.16),
      size.shortestSide * 0.28,
      accent,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
