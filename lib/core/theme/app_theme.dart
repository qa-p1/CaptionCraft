import 'package:flutter/material.dart';

// Cinematic editing-suite palette: graphite, ember, and signal lime.
const Color kBackground = Color(0xFF090B0A);
const Color kSurface = Color(0xFF111412);
const Color kSurfaceElevated = Color(0xFF1A1F1B);
const Color kSurfaceHigh = Color(0xFF242B25);
const Color kAccent = Color(0xFFFF7548);
const Color kAccentSecondary = Color(0xFFC7F36B);
const Color kOnAccent = Color(0xFFFFFFFF);
const Color kTextPrimary = Color(0xFFF3F4EC);
const Color kTextSecondary = Color(0xFF98A098);
const Color kBorder = Color(0xFF2A312B);
const Color kSuccess = Color(0xFF6ED69A);
const Color kWarning = Color(0xFFF3C35A);
const Color kError = Color(0xFFFF6B68);
const Color kInfo = Color(0xFF72C7EA);

class AppTheme {
  AppTheme._();

  static ThemeData get darkTheme {
    final baseTextTheme = ThemeData.dark(
      useMaterial3: true,
    ).textTheme.apply(bodyColor: kTextPrimary, displayColor: kTextPrimary);

    final scheme =
        ColorScheme.fromSeed(
          seedColor: kAccent,
          brightness: Brightness.dark,
          surface: kSurface,
          error: kError,
        ).copyWith(
          primary: kAccent,
          onPrimary: kOnAccent,
          primaryContainer: const Color(0xFF442114),
          onPrimaryContainer: const Color(0xFFFFD8C9),
          secondary: kAccentSecondary,
          onSecondary: const Color(0xFF171C0D),
          secondaryContainer: const Color(0xFF293516),
          onSecondaryContainer: const Color(0xFFE3FFAA),
          surface: kSurface,
          onSurface: kTextPrimary,
          surfaceContainerLowest: kBackground,
          surfaceContainerLow: kSurface,
          surfaceContainer: kSurfaceElevated,
          surfaceContainerHigh: kSurfaceHigh,
          outline: kBorder,
          outlineVariant: const Color(0xFF202620),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: kBackground,
      primaryColor: kAccent,
      colorScheme: scheme,
      textTheme: baseTextTheme,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: kBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: kTextPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
        iconTheme: const IconThemeData(color: kTextPrimary),
        actionsIconTheme: const IconThemeData(color: kTextPrimary),
      ),
      cardTheme: CardThemeData(
        color: kSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: kBorder),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: kSurfaceElevated,
        hintStyle: TextStyle(color: kTextSecondary, fontSize: 14),
        labelStyle: TextStyle(color: kTextSecondary, fontSize: 13),
        floatingLabelStyle: TextStyle(
          color: kAccent,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 15,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kAccent, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kError),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kError, width: 1.4),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: kAccent,
          foregroundColor: kOnAccent,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: kAccent,
          foregroundColor: kOnAccent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: kTextPrimary,
          side: const BorderSide(color: kBorder),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: kAccent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: kTextPrimary,
          highlightColor: kAccent.withValues(alpha: 0.1),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: kSurfaceElevated,
        selectedColor: kAccent.withValues(alpha: 0.15),
        disabledColor: kSurfaceElevated.withValues(alpha: 0.5),
        side: const BorderSide(color: kBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        labelStyle: TextStyle(
          color: kTextSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: TextStyle(
          color: kAccent,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: kAccent,
        inactiveTrackColor: kBorder,
        thumbColor: kAccent,
        overlayColor: kAccent.withValues(alpha: 0.12),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? kAccent : kTextSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? kAccent.withValues(alpha: 0.35)
              : kSurfaceHigh,
        ),
        trackOutlineColor: WidgetStateProperty.all(kBorder),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: kSurface,
        modalBackgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        showDragHandle: false,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: kSurfaceHigh,
        contentTextStyle: TextStyle(color: kTextPrimary, fontSize: 13),
        actionTextColor: kAccentSecondary,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: const DividerThemeData(color: kBorder, thickness: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: kSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 18,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: TextStyle(
          color: kTextPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: kSurfaceHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: TextStyle(color: kTextPrimary, fontSize: 13),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF303830),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF444E45)),
        ),
        textStyle: TextStyle(color: kTextPrimary, fontSize: 11),
        waitDuration: const Duration(milliseconds: 450),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: kAccent,
        linearTrackColor: kBorder,
        circularTrackColor: kBorder,
      ),
    );
  }
}
