import 'package:flutter/material.dart';
import 'app_theme.dart';

class AppTextStyles {
  AppTextStyles._();

  // ─── Headings ───
  static TextStyle get heading1 => TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w700,
    color: kTextPrimary,
    letterSpacing: -0.5,
  );

  static TextStyle get heading2 => TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    color: kTextPrimary,
    letterSpacing: -0.3,
  );

  static TextStyle get heading3 =>
      TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: kTextPrimary);

  // ─── Body ───
  static TextStyle get bodyLarge =>
      TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: kTextPrimary);

  static TextStyle get bodyMedium =>
      TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: kTextPrimary);

  static TextStyle get bodySmall => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: kTextSecondary,
  );

  // ─── Labels ───
  static TextStyle get label => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: kTextSecondary,
    letterSpacing: 0.5,
  );

  static TextStyle get button =>
      TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white);

  // ─── Monospace (for timecodes) ───
  static TextStyle get timecode => TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: kTextPrimary,
  );

  static TextStyle get timecodeSmall => TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: kTextSecondary,
  );
}
