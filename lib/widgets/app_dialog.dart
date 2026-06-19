import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';

enum AppDialogType {
  info,
  success,
  warning,
  danger,
  question,
}

class AppDialogAction<T> {
  const AppDialogAction({
    required this.text,
    this.value,
    this.onPressed,
    this.primary = false,
    this.destructive = false,
    this.icon,
  });

  final String text;
  final T? value;
  final VoidCallback? onPressed;
  final bool primary;
  final bool destructive;
  final IconData? icon;

  const AppDialogAction.primary({
    required this.text,
    this.value,
    this.onPressed,
    this.destructive = false,
    this.icon,
  }) : primary = true;

  const AppDialogAction.secondary({
    required this.text,
    this.value,
    this.onPressed,
    this.icon,
  })  : primary = false,
        destructive = false;

  const AppDialogAction.danger({
    required this.text,
    this.value,
    this.onPressed,
    this.icon,
  })  : primary = true,
        destructive = true;
}

class AppDialog {
  const AppDialog._();

  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = 'تأكيد',
    String cancelText = 'إلغاء',
    AppDialogType type = AppDialogType.question,
    bool destructive = false,
    bool barrierDismissible = true,
    IconData? icon,
  }) async {
    final result = await _showAppDialog<bool>(
      context,
      barrierDismissible: barrierDismissible,
      child: _AppDialogCard(
        title: title,
        message: message,
        type: destructive ? AppDialogType.danger : type,
        confirmText: confirmText,
        cancelText: cancelText,
        showCancel: true,
        destructive: destructive,
        icon: icon,
        onConfirm: () => Navigator.of(context, rootNavigator: true).pop(true),
        onCancel: () => Navigator.of(context, rootNavigator: true).pop(false),
      ),
    );

    return result ?? false;
  }

  static Future<bool> delete(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = 'حذف',
    String cancelText = 'إلغاء',
    bool barrierDismissible = true,
  }) {
    return confirm(
      context,
      title: title,
      message: message,
      confirmText: confirmText,
      cancelText: cancelText,
      type: AppDialogType.danger,
      destructive: true,
      barrierDismissible: barrierDismissible,
      icon: Icons.delete_rounded,
    );
  }

  static Future<void> success(
    BuildContext context, {
    required String title,
    required String message,
    String buttonText = 'تم',
    bool barrierDismissible = true,
  }) {
    return info(
      context,
      title: title,
      message: message,
      buttonText: buttonText,
      type: AppDialogType.success,
      barrierDismissible: barrierDismissible,
      icon: Icons.check_circle_rounded,
    );
  }

  static Future<void> warning(
    BuildContext context, {
    required String title,
    required String message,
    String buttonText = 'حسنًا',
    bool barrierDismissible = true,
  }) {
    return info(
      context,
      title: title,
      message: message,
      buttonText: buttonText,
      type: AppDialogType.warning,
      barrierDismissible: barrierDismissible,
      icon: Icons.warning_amber_rounded,
    );
  }

  static Future<void> error(
    BuildContext context, {
    required String title,
    required String message,
    String buttonText = 'حسنًا',
    bool barrierDismissible = true,
  }) {
    return info(
      context,
      title: title,
      message: message,
      buttonText: buttonText,
      type: AppDialogType.danger,
      barrierDismissible: barrierDismissible,
      icon: Icons.error_rounded,
    );
  }

  static Future<void> info(
    BuildContext context, {
    required String title,
    required String message,
    String buttonText = 'حسنًا',
    AppDialogType type = AppDialogType.info,
    bool barrierDismissible = true,
    IconData? icon,
  }) async {
    await _showAppDialog<void>(
      context,
      barrierDismissible: barrierDismissible,
      child: _AppDialogCard(
        title: title,
        message: message,
        type: type,
        confirmText: buttonText,
        showCancel: false,
        destructive: type == AppDialogType.danger,
        icon: icon,
        onConfirm: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    );
  }

  static Future<T?> custom<T>(
    BuildContext context, {
    required String title,
    required Widget content,
    List<AppDialogAction<T>> actions = const [],
    AppDialogType type = AppDialogType.info,
    IconData? icon,
    bool showIcon = true,
    bool barrierDismissible = true,
    bool useRootNavigator = true,
    double maxWidth = 440,
    double? maxContentHeight,
  }) {
    return _showAppDialog<T>(
      context,
      barrierDismissible: barrierDismissible,
      useRootNavigator: useRootNavigator,
      child: _AppCustomDialogCard<T>(
        title: title,
        content: content,
        actions: actions,
        type: type,
        icon: icon,
        showIcon: showIcon,
        maxWidth: maxWidth,
        maxContentHeight: maxContentHeight,
      ),
    );
  }

  static Future<T?> fullscreen<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    Color? barrierColor,
    bool barrierDismissible = true,
    bool useRootNavigator = true,
  }) {
    return showGeneralDialog<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: barrierColor ?? Colors.black.withOpacity(0.62),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return builder(dialogContext);
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(opacity: curved, child: child);
      },
    );
  }
}

Future<T?> showAppConfirmDialog<T>(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = 'تأكيد',
  String cancelText = 'إلغاء',
  AppDialogType type = AppDialogType.question,
  bool destructive = false,
  bool barrierDismissible = true,
  IconData? icon,
}) {
  return _showAppDialog<T>(
    context,
    barrierDismissible: barrierDismissible,
    child: _AppDialogCard(
      title: title,
      message: message,
      type: destructive ? AppDialogType.danger : type,
      confirmText: confirmText,
      cancelText: cancelText,
      showCancel: true,
      destructive: destructive,
      icon: icon,
      onConfirm: () => Navigator.of(context, rootNavigator: true).pop(true),
      onCancel: () => Navigator.of(context, rootNavigator: true).pop(false),
    ),
  );
}

Future<bool> showAppDeleteDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = 'حذف',
  String cancelText = 'إلغاء',
  bool barrierDismissible = true,
}) {
  return AppDialog.delete(
    context,
    title: title,
    message: message,
    confirmText: confirmText,
    cancelText: cancelText,
    barrierDismissible: barrierDismissible,
  );
}

Future<void> showAppSuccessDialog(
  BuildContext context, {
  required String title,
  required String message,
  String buttonText = 'تم',
  bool barrierDismissible = true,
}) {
  return AppDialog.success(
    context,
    title: title,
    message: message,
    buttonText: buttonText,
    barrierDismissible: barrierDismissible,
  );
}

Future<T?> _showAppDialog<T>(
  BuildContext context, {
  required Widget child,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withOpacity(0.62),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return SafeArea(
        child: Directionality(
          textDirection: Directionality.of(context),
          child: Center(child: child),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.035),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

class _AppCustomDialogCard<T> extends StatelessWidget {
  const _AppCustomDialogCard({
    required this.title,
    required this.content,
    required this.actions,
    required this.type,
    required this.showIcon,
    required this.maxWidth,
    this.icon,
    this.maxContentHeight,
  });

  final String title;
  final Widget content;
  final List<AppDialogAction<T>> actions;
  final AppDialogType type;
  final IconData? icon;
  final bool showIcon;
  final double maxWidth;
  final double? maxContentHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final style = _DialogStyle.from(type, isDark, type == AppDialogType.danger);
    final width = math.min(media.size.width - 32, maxWidth);
    final resolvedMaxHeight = maxContentHeight ?? (media.size.height * 0.64);

    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: math.max(media.viewInsets.bottom, 0),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(34),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                decoration: _dialogDecoration(isDark, style),
                child: Stack(
                  children: [
                    PositionedDirectional(
                      top: -54,
                      end: -48,
                      child: _GlowCircle(
                        color: style.accent.withOpacity(isDark ? 0.18 : 0.12),
                        size: 148,
                      ),
                    ),
                    PositionedDirectional(
                      bottom: -72,
                      start: -60,
                      child: _GlowCircle(
                        color: AppColors.purple.withOpacity(isDark ? 0.13 : 0.08),
                        size: 178,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (showIcon) ...[
                            _DialogIcon(
                              icon: icon ?? style.icon,
                              accent: style.accent,
                              isDark: isDark,
                            ),
                            const SizedBox(height: 18),
                          ],
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.ibmPlexSansArabic(
                              color: isDark ? AppColors.darkText : AppColors.lightText,
                              fontSize: 22,
                              height: 1.2,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.45,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: resolvedMaxHeight),
                            child: SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              child: content,
                            ),
                          ),
                          if (actions.isNotEmpty) ...[
                            const SizedBox(height: 22),
                            _DialogActionsRow<T>(
                              actions: actions,
                              isDark: isDark,
                              accent: style.accent,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogActionsRow<T> extends StatelessWidget {
  const _DialogActionsRow({
    required this.actions,
    required this.isDark,
    required this.accent,
  });

  final List<AppDialogAction<T>> actions;
  final bool isDark;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final children = actions
        .map(
          (action) => Expanded(
            child: _DialogButton.action(
              context: context,
              action: action,
              accent: action.destructive ? AppColors.danger : accent,
              isDark: isDark,
            ),
          ),
        )
        .toList();

    if (children.length == 1) {
      return SizedBox(width: double.infinity, child: children.first);
    }

    return Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          children[i],
        ],
      ],
    );
  }
}

class _AppDialogCard extends StatelessWidget {
  const _AppDialogCard({
    required this.title,
    required this.message,
    required this.type,
    required this.confirmText,
    required this.showCancel,
    required this.destructive,
    required this.onConfirm,
    this.cancelText = 'إلغاء',
    this.onCancel,
    this.icon,
  });

  final String title;
  final String message;
  final AppDialogType type;
  final String confirmText;
  final String cancelText;
  final bool showCancel;
  final bool destructive;
  final VoidCallback onConfirm;
  final VoidCallback? onCancel;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final style = _DialogStyle.from(type, isDark, destructive);
    final width = math.min(media.size.width - 32, 430.0);

    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: math.max(media.viewInsets.bottom, 0),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(34),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                decoration: _dialogDecoration(isDark, style),
                child: Stack(
                  children: [
                    PositionedDirectional(
                      top: -54,
                      end: -48,
                      child: _GlowCircle(
                        color: style.accent.withOpacity(isDark ? 0.18 : 0.12),
                        size: 148,
                      ),
                    ),
                    PositionedDirectional(
                      bottom: -72,
                      start: -60,
                      child: _GlowCircle(
                        color: AppColors.purple.withOpacity(isDark ? 0.13 : 0.08),
                        size: 178,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _DialogIcon(
                            icon: icon ?? style.icon,
                            accent: style.accent,
                            isDark: isDark,
                          ),
                          const SizedBox(height: 18),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.ibmPlexSansArabic(
                              color: isDark ? AppColors.darkText : AppColors.lightText,
                              fontSize: 23,
                              height: 1.2,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.45,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            message,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.ibmPlexSansArabic(
                              color: isDark
                                  ? AppColors.darkMuted.withOpacity(0.96)
                                  : AppColors.lightMuted.withOpacity(0.98),
                              fontSize: 15.8,
                              height: 1.7,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.15,
                            ),
                          ),
                          const SizedBox(height: 24),
                          if (showCancel)
                            Row(
                              children: [
                                Expanded(
                                  child: _DialogButton.secondary(
                                    text: cancelText,
                                    isDark: isDark,
                                    onPressed: onCancel ??
                                        () => Navigator.of(context, rootNavigator: true).pop(false),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _DialogButton.primary(
                                    text: confirmText,
                                    accent: style.accent,
                                    isDark: isDark,
                                    destructive: destructive,
                                    onPressed: onConfirm,
                                  ),
                                ),
                              ],
                            )
                          else
                            SizedBox(
                              width: double.infinity,
                              child: _DialogButton.primary(
                                text: confirmText,
                                accent: style.accent,
                                isDark: isDark,
                                destructive: destructive,
                                onPressed: onConfirm,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

BoxDecoration _dialogDecoration(bool isDark, _DialogStyle style) {
  return BoxDecoration(
    borderRadius: BorderRadius.circular(34),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? [
              const Color(0xFF1A1228).withOpacity(0.96),
              const Color(0xFF0E0B16).withOpacity(0.98),
            ]
          : [
              Colors.white.withOpacity(0.98),
              const Color(0xFFF7F2FF).withOpacity(0.96),
            ],
    ),
    border: Border.all(
      color: style.borderColor,
      width: 1.15,
    ),
    boxShadow: [
      BoxShadow(
        color: style.accent.withOpacity(isDark ? 0.28 : 0.16),
        blurRadius: 42,
        offset: const Offset(0, 22),
      ),
      BoxShadow(
        color: Colors.black.withOpacity(isDark ? 0.34 : 0.09),
        blurRadius: 34,
        offset: const Offset(0, 18),
      ),
    ],
  );
}

class _DialogIcon extends StatelessWidget {
  const _DialogIcon({
    required this.icon,
    required this.accent,
    required this.isDark,
  });

  final IconData icon;
  final Color accent;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 74,
      height: 74,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            accent.withOpacity(isDark ? 0.28 : 0.18),
            accent.withOpacity(isDark ? 0.13 : 0.10),
            Colors.transparent,
          ],
        ),
        border: Border.all(
          color: accent.withOpacity(isDark ? 0.34 : 0.25),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(isDark ? 0.22 : 0.16),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent.withOpacity(isDark ? 0.16 : 0.12),
          ),
          child: Icon(icon, color: accent, size: 29),
        ),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  const _DialogButton._({
    required this.text,
    required this.onPressed,
    required this.isDark,
    required this.isPrimary,
    required this.accent,
    required this.destructive,
    this.icon,
  });

  factory _DialogButton.primary({
    required String text,
    required VoidCallback onPressed,
    required Color accent,
    required bool isDark,
    bool destructive = false,
    IconData? icon,
  }) {
    return _DialogButton._(
      text: text,
      onPressed: onPressed,
      isDark: isDark,
      isPrimary: true,
      accent: accent,
      destructive: destructive,
      icon: icon,
    );
  }

  factory _DialogButton.secondary({
    required String text,
    required VoidCallback onPressed,
    required bool isDark,
    IconData? icon,
  }) {
    return _DialogButton._(
      text: text,
      onPressed: onPressed,
      isDark: isDark,
      isPrimary: false,
      accent: AppColors.purple,
      destructive: false,
      icon: icon,
    );
  }

  factory _DialogButton.action({
    required BuildContext context,
    required AppDialogAction<dynamic> action,
    required Color accent,
    required bool isDark,
  }) {
    return _DialogButton._(
      text: action.text,
      onPressed: action.onPressed ??
          () => Navigator.of(context, rootNavigator: true).pop(action.value),
      isDark: isDark,
      isPrimary: action.primary,
      accent: accent,
      destructive: action.destructive,
      icon: action.icon,
    );
  }

  final String text;
  final VoidCallback onPressed;
  final bool isDark;
  final bool isPrimary;
  final Color accent;
  final bool destructive;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {

    final foreground = isPrimary
        ? Colors.white
        : (isDark ? AppColors.darkText : AppColors.lightText);

    final background = isPrimary
        ? accent
        : (isDark ? Colors.white.withOpacity(0.07) : AppColors.lightCard.withOpacity(0.95));

    final borderColor = isPrimary
        ? accent.withOpacity(0.24)
        : (isDark ? Colors.white.withOpacity(0.10) : AppColors.lightBorder.withOpacity(0.9));

    final buttonChild = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 7),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.ibmPlexSansArabic(
              color: foreground,
              fontSize: 15.8,
              fontWeight: FontWeight.w900,
              height: 1.1,
              letterSpacing: -0.15,
            ),
          ),
        ),
      ],
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: isPrimary
            ? [
                BoxShadow(
                  color: accent.withOpacity(isDark ? 0.34 : 0.22),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ]
            : null,
      ),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onPressed,
          child: Container(
            height: 52,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor, width: 1),
              gradient: isPrimary
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        accent.withOpacity(0.96),
                        destructive
                            ? const Color(0xFFB91C1C)
                            : AppColors.purpleDark.withOpacity(0.94),
                      ],
                    )
                  : null,
            ),
            child: buttonChild,
          ),
        ),
      ),
    );
  }
}

class _GlowCircle extends StatelessWidget {
  const _GlowCircle({
    required this.color,
    required this.size,
  });

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }
}

class _DialogStyle {
  const _DialogStyle({
    required this.accent,
    required this.borderColor,
    required this.icon,
  });

  final Color accent;
  final Color borderColor;
  final IconData icon;

  factory _DialogStyle.from(
    AppDialogType type,
    bool isDark,
    bool destructive,
  ) {
    final resolvedType = destructive ? AppDialogType.danger : type;

    switch (resolvedType) {
      case AppDialogType.success:
        return _DialogStyle(
          accent: AppColors.success,
          borderColor: AppColors.success.withOpacity(isDark ? 0.30 : 0.22),
          icon: Icons.check_rounded,
        );
      case AppDialogType.warning:
        return _DialogStyle(
          accent: AppColors.warning,
          borderColor: AppColors.warning.withOpacity(isDark ? 0.32 : 0.24),
          icon: Icons.warning_amber_rounded,
        );
      case AppDialogType.danger:
        return _DialogStyle(
          accent: AppColors.danger,
          borderColor: AppColors.danger.withOpacity(isDark ? 0.34 : 0.24),
          icon: Icons.close_rounded,
        );
      case AppDialogType.question:
        return _DialogStyle(
          accent: AppColors.purpleLight,
          borderColor: AppColors.purpleLight.withOpacity(isDark ? 0.30 : 0.20),
          icon: Icons.help_rounded,
        );
      case AppDialogType.info:
        return _DialogStyle(
          accent: AppColors.purple,
          borderColor: AppColors.purple.withOpacity(isDark ? 0.30 : 0.18),
          icon: Icons.info_rounded,
        );
    }
  }
}
