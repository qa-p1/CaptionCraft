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
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: color, size: 17),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 12.5,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
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
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        showCloseIcon: true,
        closeIconColor: kTextSecondary,
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
