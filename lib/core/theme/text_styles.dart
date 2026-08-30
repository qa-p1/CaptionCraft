import 'package:flutter/material.dart';
import 'app_theme.dart';

class AppTextStyles {
  AppTextStyles._();

  // ─── Headings ───
  static TextStyle get heading1 => TextStyle(
    fontSize: 30,
    height: 1.08,
    fontWeight: FontWeight.w800,
    color: kTextPrimary,
    letterSpacing: -0.8,
  );

  static TextStyle get heading2 => TextStyle(
    fontSize: 24,
    height: 1.12,
    fontWeight: FontWeight.w800,
    color: kTextPrimary,
    letterSpacing: -0.55,
  );

  static TextStyle get heading3 => TextStyle(
    fontSize: 19,
    height: 1.2,
    fontWeight: FontWeight.w700,
    color: kTextPrimary,
    letterSpacing: -0.3,
  );

  // ─── Body ───
  static TextStyle get bodyLarge => TextStyle(
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: kTextPrimary,
  );

  static TextStyle get bodyMedium => TextStyle(
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: kTextPrimary,
  );

  static TextStyle get bodySmall => TextStyle(
    fontSize: 11.5,
    height: 1.35,
    fontWeight: FontWeight.w400,
    color: kTextSecondary,
  );

  // ─── Labels ───
  static TextStyle get label => TextStyle(
    fontSize: 9.5,
    fontWeight: FontWeight.w800,
    color: kTextSecondary,
    letterSpacing: 0.95,
  );

  static TextStyle get button =>
      TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white);

  // ─── Monospace (for timecodes) ───
  static TextStyle get timecode => TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: kTextPrimary,
  );

  static TextStyle get timecodeSmall => TextStyle(
    fontFamily: 'monospace',
    fontSize: 10.5,
    fontWeight: FontWeight.w400,
    color: kTextSecondary,
  );
}
