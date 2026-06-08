import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class PrimaryButton extends StatelessWidget {
  final String text;
  final IconData? icon;
  final VoidCallback onPressed;
  final bool outline;

  const PrimaryButton({
    super.key,
    required this.text,
    this.icon,
    required this.onPressed,
    this.outline = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgGradient = const LinearGradient(colors: [AppColors.purple, Color(0xFF6D28D9)]);
    return SizedBox(
      height: 54,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: outline ? null : bgGradient,
          color: outline
              ? (isDark ? AppColors.darkCard : AppColors.lightCard)
              : null,
          borderRadius: BorderRadius.circular(18),
          border: outline ? Border.all(color: AppColors.purple) : null,
          boxShadow: outline
              ? []
              : [BoxShadow(color: AppColors.purple.withOpacity(0.4), blurRadius: 24)],
        ),
        child: outline
            ? OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  side: BorderSide.none,
                ),
                onPressed: onPressed,
                icon: Icon(icon ?? Icons.arrow_forward_rounded, color: AppColors.purple),
                label: Text(text,
                    style: TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900, fontSize: 16)),
              )
            : ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                ),
                onPressed: onPressed,
                icon: Icon(icon ?? Icons.arrow_forward_rounded, color: AppColors.white),
                label: Text(text,
                    style: const TextStyle(color: AppColors.white, fontWeight: FontWeight.w900, fontSize: 16)),
              ),
      ),
    );
  }
}
