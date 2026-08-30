import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import 'app_surface.dart';

class LoadingOverlay extends StatelessWidget {
  final bool isLoading;
  final Widget child;
  final String? message;

  const LoadingOverlay({
    super.key,
    required this.isLoading,
    required this.child,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: isLoading
                ? ColoredBox(
                    key: const ValueKey('loading_overlay_visible'),
                    color: Colors.black.withValues(alpha: 0.72),
                    child: Center(
                      child: AppPanel(
                        elevated: true,
                        padding: const EdgeInsets.fromLTRB(18, 16, 20, 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Flexible(
                              child: Text(
                                message ?? 'Working…',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: kTextPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(
                    key: ValueKey('loading_overlay_hidden'),
                  ),
          ),
        ),
      ],
    );
  }
}
