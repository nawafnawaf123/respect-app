import 'package:flutter/material.dart';

class AppColors {
  // Dark
  static const Color darkBg = Color(0xFF07040F);
  static const Color darkCard = Color(0xFF11101A);
  static const Color darkCard2 = Color(0xFF181326);
  static const Color darkBorder = Color(0xFF2D2540);
  static const Color darkMuted = Color(0xFFA1A1AA);
  static const Color darkText = Color(0xFFF8FAFC);

  // Light
  static const Color lightBg = Color(0xFFF8F9FC);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightCard2 = Color(0xFFF0F0F7);
  static const Color lightBorder = Color(0xFFE2E2F0);
  static const Color lightMuted = Color(0xFF6B7280);
  static const Color lightText = Color(0xFF111827);

  // Shared
  static const Color purple = Color(0xFF7C3AED);
  static const Color purpleDark = Color(0xFF5B21B6);
  static const Color purpleLight = Color(0xFFA78BFA);
  static const Color success = Color(0xFF22C55E);
  static const Color danger = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);
  static const Color white = Color(0xFFF8FAFC);

  // Compatibility aliases
  static const Color darkSurface = darkCard;
  static const Color darkSurface2 = darkCard2;
  static const Color lightSurface = lightCard;
  static const Color lightSurface2 = lightCard2;
  static const Color darkSubtle = darkMuted;
  static const Color lightSubtle = lightMuted;
}

class AppTheme {
  static ThemeData _base(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final textColor = isDark ? AppColors.darkText : AppColors.lightText;
    final mutedTextColor = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    final cardColor = isDark ? AppColors.darkCard : AppColors.lightCard;
    final surfaceColor = isDark ? AppColors.darkSurface : AppColors.lightSurface;
    final borderColor = isDark ? AppColors.darkBorder : AppColors.lightBorder;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
      cardColor: cardColor,
      dividerColor: borderColor,
      colorScheme: isDark
          ? const ColorScheme.dark(
              primary: AppColors.purple,
              secondary: AppColors.purpleLight,
              surface: AppColors.darkCard,
              error: AppColors.danger,
              onPrimary: Colors.white,
              onSecondary: Colors.white,
              onSurface: AppColors.darkText,
            )
          : const ColorScheme.light(
              primary: AppColors.purple,
              secondary: AppColors.purpleLight,
              surface: AppColors.lightCard,
              error: AppColors.danger,
              onPrimary: Colors.white,
              onSecondary: Colors.white,
              onSurface: AppColors.lightText,
            ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        foregroundColor: textColor,
        iconTheme: IconThemeData(color: textColor),
        titleTextStyle: TextStyle(
          color: textColor,
          fontSize: 18,
          fontWeight: FontWeight.w900,
        ),
      ),
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
            bodyColor: textColor,
            displayColor: textColor,
          ),
      iconTheme: IconThemeData(color: textColor),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? AppColors.darkCard : AppColors.lightCard2,
        hintStyle: TextStyle(color: mutedTextColor),
        labelStyle: TextStyle(color: mutedTextColor),
        prefixIconColor: mutedTextColor,
        suffixIconColor: mutedTextColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AppColors.purple, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    );
  }

  static ThemeData darkTheme = _base(Brightness.dark);
  static ThemeData lightTheme = _base(Brightness.light);
}