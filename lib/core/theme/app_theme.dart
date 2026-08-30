import 'package:flutter/material.dart';

// Professional editing-suite palette: neutral graphite, ember, and signal lime.
const Color kBackground = Color(0xFF080A0C);
const Color kSurface = Color(0xFF101316);
const Color kSurfaceElevated = Color(0xFF171B1F);
const Color kSurfaceHigh = Color(0xFF20262B);
const Color kSurfaceOverlay = Color(0xFF272D34);
const Color kAccent = Color(0xFFFF7548);
const Color kAccentSecondary = Color(0xFFC7F36B);
const Color kOnAccent = Color(0xFFFFFFFF);
const Color kTextPrimary = Color(0xFFF3F4F2);
const Color kTextSecondary = Color(0xFF9BA3A9);
const Color kTextTertiary = Color(0xFF6F7881);
const Color kBorder = Color(0xFF2A3036);
const Color kBorderStrong = Color(0xFF3A424B);
const Color kSuccess = Color(0xFF6ED69A);
const Color kWarning = Color(0xFFF3C35A);
const Color kError = Color(0xFFFF6B68);
const Color kInfo = Color(0xFF72C7EA);

const double kRadiusSmall = 8;
const double kRadiusMedium = 12;
const double kRadiusLarge = 16;
const double kRadiusSheet = 26;

class AppTheme {
  AppTheme._();

  static ThemeData get darkTheme {
    final baseTextTheme = ThemeData.dark(useMaterial3: true).textTheme
        .apply(
          fontFamily: 'Inter',
          bodyColor: kTextPrimary,
          displayColor: kTextPrimary,
        )
        .copyWith(
          displayLarge: const TextStyle(
            fontSize: 48,
            height: 1.02,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.8,
          ),
          displayMedium: const TextStyle(
            fontSize: 38,
            height: 1.05,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.25,
          ),
          headlineLarge: const TextStyle(
            fontSize: 30,
            height: 1.1,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.8,
          ),
          headlineMedium: const TextStyle(
            fontSize: 24,
            height: 1.15,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.55,
          ),
          titleLarge: const TextStyle(
            fontSize: 19,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
          titleMedium: const TextStyle(
            fontSize: 15,
            height: 1.25,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.1,
          ),
          bodyLarge: const TextStyle(
            fontSize: 15,
            height: 1.45,
            fontWeight: FontWeight.w400,
          ),
          bodyMedium: const TextStyle(
            fontSize: 13,
            height: 1.4,
            fontWeight: FontWeight.w400,
          ),
          bodySmall: const TextStyle(
            color: kTextSecondary,
            fontSize: 11.5,
            height: 1.35,
            fontWeight: FontWeight.w400,
          ),
          labelLarge: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.05,
          ),
          labelMedium: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
          labelSmall: const TextStyle(
            color: kTextSecondary,
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.45,
          ),
        );

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
          outlineVariant: kBorder,
          scrim: Colors.black,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: kBackground,
      primaryColor: kAccent,
      colorScheme: scheme,
      textTheme: baseTextTheme,
      splashFactory: InkRipple.splashFactory,
      splashColor: kAccent.withValues(alpha: 0.08),
      highlightColor: Colors.white.withValues(alpha: 0.035),
      hoverColor: Colors.white.withValues(alpha: 0.045),
      focusColor: kAccent.withValues(alpha: 0.12),
      visualDensity: const VisualDensity(horizontal: -0.25, vertical: -0.25),
      appBarTheme: AppBarTheme(
        backgroundColor: kBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 60,
        titleTextStyle: const TextStyle(
          fontFamily: 'Inter',
          color: kTextPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.25,
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
          borderRadius: BorderRadius.circular(kRadiusLarge),
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
          borderRadius: BorderRadius.circular(kRadiusMedium),
          borderSide: const BorderSide(color: kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadiusMedium),
          borderSide: const BorderSide(color: kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadiusMedium),
          borderSide: const BorderSide(color: kAccent, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadiusMedium),
          borderSide: const BorderSide(color: kError),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadiusMedium),
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
            borderRadius: BorderRadius.circular(kRadiusMedium),
          ),
          minimumSize: const Size(48, 46),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: kAccent,
          foregroundColor: kOnAccent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusMedium),
          ),
          minimumSize: const Size(48, 44),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: kTextPrimary,
          side: const BorderSide(color: kBorder),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusMedium),
          ),
          minimumSize: const Size(48, 44),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: kAccent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusSmall),
          ),
          minimumSize: const Size(40, 40),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: kTextPrimary,
          backgroundColor: Colors.transparent,
          highlightColor: kAccent.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusSmall),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: kSurfaceElevated,
        selectedColor: kAccent.withValues(alpha: 0.15),
        disabledColor: kSurfaceElevated.withValues(alpha: 0.5),
        side: const BorderSide(color: kBorder),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusSmall),
        ),
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
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: kAccent,
        inactiveTrackColor: kBorder,
        thumbColor: kAccent,
        overlayColor: kAccent.withValues(alpha: 0.12),
        trackHeight: 3.5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
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
      checkboxTheme: CheckboxThemeData(
        visualDensity: VisualDensity.compact,
        side: const BorderSide(color: kBorderStrong, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? kAccent : null,
        ),
        checkColor: const WidgetStatePropertyAll(kOnAccent),
      ),
      radioTheme: RadioThemeData(
        visualDensity: VisualDensity.compact,
        fillColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? kAccent : kTextTertiary,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: kTextSecondary,
        textColor: kTextPrimary,
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        minTileHeight: 48,
        minLeadingWidth: 28,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(kRadiusMedium)),
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: kAccent,
        dividerColor: kBorder,
        labelColor: kTextPrimary,
        unselectedLabelColor: kTextSecondary,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        unselectedLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 66,
        elevation: 0,
        backgroundColor: kSurface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: kAccent.withValues(alpha: 0.14),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? kAccent
                : kTextSecondary,
            size: 21,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? kTextPrimary
                : kTextSecondary,
            fontSize: 10,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w600,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: kAccent,
        foregroundColor: kOnAccent,
        elevation: 4,
        focusElevation: 5,
        hoverElevation: 5,
        highlightElevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(15)),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.dragged)
              ? kBorderStrong
              : kBorder.withValues(alpha: 0.8),
        ),
        radius: const Radius.circular(99),
        thickness: const WidgetStatePropertyAll(4),
        crossAxisMargin: 3,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: kSurface,
        modalBackgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        showDragHandle: false,
        elevation: 0,
        modalElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(kRadiusSheet),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: kSurfaceHigh,
        contentTextStyle: TextStyle(color: kTextPrimary, fontSize: 13),
        actionTextColor: kAccentSecondary,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusMedium),
          side: const BorderSide(color: kBorder),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: const DividerThemeData(color: kBorder, thickness: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: kSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 18,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: kBorder),
        ),
        titleTextStyle: const TextStyle(
          color: kTextPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
        contentTextStyle: const TextStyle(
          color: kTextSecondary,
          fontSize: 13,
          height: 1.45,
        ),
        actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: kSurfaceHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusMedium),
          side: const BorderSide(color: kBorder),
        ),
        textStyle: const TextStyle(color: kTextPrimary, fontSize: 13),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(color: kTextPrimary, fontSize: 13),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: kSurfaceOverlay,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kBorderStrong),
        ),
        textStyle: const TextStyle(color: kTextPrimary, fontSize: 11),
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
