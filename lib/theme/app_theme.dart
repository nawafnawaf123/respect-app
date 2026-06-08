import 'package:flutter/material.dart';

class AppColors {
  // Dark
  static const darkBg = Color(0xFF07040F);
  static const darkCard = Color(0xFF11101A);
  static const darkCard2 = Color(0xFF181326);
  static const darkBorder = Color(0xFF2D2540);
  static const darkMuted = Color(0xFFA1A1AA);
  // Light
  static const lightBg = Color(0xFFF8F9FC);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightCard2 = Color(0xFFF0F0F7);
  static const lightBorder = Color(0xFFE2E2F0);
  static const lightMuted = Color(0xFF6B7280);
  // Shared
  static const purple = Color(0xFF7C3AED);
  static const purpleLight = Color(0xFFA78BFA);
  static const success = Color(0xFF22C55E);
  static const danger = Color(0xFFEF4444);
  static const white = Color(0xFFF8FAFC);
}

class AppTheme {
  static ThemeData _base(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
      colorScheme: isDark
          ? const ColorScheme.dark(
              primary: AppColors.purple,
              secondary: AppColors.purple,
              surface: AppColors.darkCard,
              error: AppColors.danger,
            )
          : const ColorScheme.light(
              primary: AppColors.purple,
              secondary: AppColors.purple,
              surface: AppColors.lightCard,
              error: AppColors.danger,
            ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        foregroundColor: isDark ? Colors.white : Colors.black87,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? AppColors.darkCard : AppColors.lightCard2,
        hintStyle: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AppColors.purple, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    );
  }

  static ThemeData darkTheme = _base(Brightness.dark);
  static ThemeData lightTheme = _base(Brightness.light);
}
