import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

class SnackBarHelper {
  SnackBarHelper._();

  static void showSuccess(BuildContext context, String message) {
    _show(context, message, kSuccess, Icons.check_circle_rounded);
  }

  static void showError(BuildContext context, String message) {
    _show(context, message, kError, Icons.error_rounded);
  }

  static void showInfo(BuildContext context, String message) {
    _show(context, message, kAccent, Icons.info_rounded);
  }

  static void showWarning(BuildContext context, String message) {
    _show(context, message, kWarning, Icons.warning_rounded);
  }

  static void _show(
    BuildContext context,
    String message,
    Color color,
    IconData icon,
  ) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: kTextPrimary, fontSize: 14),
              ),
            ),
          ],
        ),
        backgroundColor: kSurfaceElevated,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color.withValues(alpha: 0.3)),
        ),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
