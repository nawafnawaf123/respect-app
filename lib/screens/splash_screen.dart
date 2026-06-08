import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../theme/app_theme.dart';

class SplashScreen<T> extends StatefulWidget {
  final Future<T> Function() onInitialize;
  final Widget Function(BuildContext context, T result) destinationBuilder;
  final String logoAsset;
  final String title;
  final String subtitle;

  const SplashScreen({
    super.key,
    required this.onInitialize,
    required this.destinationBuilder,
    this.logoAsset = 'assets/logo.png',
    this.title = 'Respect App',
    this.subtitle = 'Preparing your feed before opening...',
  });

  @override
  State<SplashScreen<T>> createState() => _SplashScreenState<T>();
}

class _SplashScreenState<T> extends State<SplashScreen<T>> with TickerProviderStateMixin {
  late final AnimationController _logoController;
  late final AnimationController _pulseController;
  late final AnimationController _coverController;
  late final AnimationController _progressController;

  Timer? _statusTimer;
  bool _finished = false;
  String _status = 'تشغيل الخدمات...';

  final List<String> _statuses = const [
    'تشغيل الخدمات...',
    'فحص الجلسة...',
    'تحميل بيانات الحساب...',
    'تحميل التغريدات...',
    'تجهيز الصور والفيديوهات...',
    'ترتيب الفيد للفتح...',
    'مزامنة الإشعارات...',
    'فتح التطبيق...',
  ];
  int _statusIndex = 0;

  static const Duration _minimumSplashDuration = Duration(milliseconds: 2600);
  static const Duration _transitionDuration = Duration(milliseconds: 760);

  @override
  void initState() {
    super.initState();

    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _coverController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1450),
    )..forward();

    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5200),
      upperBound: 0.92,
    )..forward();

    _statusTimer = Timer.periodic(const Duration(milliseconds: 520), (_) {
      if (!mounted || _finished) return;
      setState(() {
        _statusIndex = (_statusIndex + 1).clamp(0, _statuses.length - 1);
        _status = _statuses[_statusIndex];
      });
    });

    _start();
  }

  Future<void> _start() async {
    final startedAt = DateTime.now();
    final T result = await widget.onInitialize();

    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed < _minimumSplashDuration) {
      await Future.delayed(_minimumSplashDuration - elapsed);
    }

    if (!mounted) return;
    setState(() {
      _finished = true;
      _status = 'جاهز...';
    });

    await _progressController.animateTo(
      1.0,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => widget.destinationBuilder(context, result),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.035), end: Offset.zero).animate(curved),
              child: child,
            ),
          );
        },
        transitionDuration: _transitionDuration,
      ),
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _logoController.dispose();
    _pulseController.dispose();
    _coverController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.of(context).size;
    final maxWidth = math.min(size.width * 0.76, 360.0);

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF08040F),
              Color(0xFF150A24),
              Color(0xFF250D45),
              Color(0xFF08040F),
            ],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -120,
              right: -90,
              child: _GlowOrb(size: 280, color: AppColors.purple.withOpacity(0.44)),
            ),
            Positioned(
              bottom: -110,
              left: -90,
              child: _GlowOrb(size: 260, color: AppColors.purple.withOpacity(0.28)),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: _SplashGridPainter(color: Colors.white.withOpacity(isDark ? 0.045 : 0.035)),
              ),
            ),
            SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 26),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _AnimatedLogo(
                        logoAsset: widget.logoAsset,
                        logoController: _logoController,
                        pulseController: _pulseController,
                        coverController: _coverController,
                      ),
                      const SizedBox(height: 28),
                      Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          height: 1.05,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ).animate().fadeIn(delay: 280.ms, duration: 520.ms).slideY(begin: 0.14, end: 0),
                      const SizedBox(height: 10),
                      Text(
                        widget.subtitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.68),
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.15,
                        ),
                      ).animate().fadeIn(delay: 420.ms, duration: 520.ms),
                      const SizedBox(height: 38),
                      SizedBox(
                        width: maxWidth,
                        child: Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: AnimatedBuilder(
                                animation: _progressController,
                                builder: (context, _) {
                                  return LinearProgressIndicator(
                                    minHeight: 9,
                                    value: Curves.easeOutCubic.transform(_progressController.value),
                                    backgroundColor: Colors.white.withOpacity(0.10),
                                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF9B5CFF)),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 12),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 260),
                              child: Text(
                                _status,
                                key: ValueKey(_status),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.74),
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ).animate().fadeIn(delay: 620.ms, duration: 520.ms).slideY(begin: 0.16, end: 0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedLogo extends StatelessWidget {
  final String logoAsset;
  final AnimationController logoController;
  final AnimationController pulseController;
  final AnimationController coverController;

  const _AnimatedLogo({
    required this.logoAsset,
    required this.logoController,
    required this.pulseController,
    required this.coverController,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([logoController, pulseController, coverController]),
      builder: (context, _) {
        final spin = math.sin(logoController.value * math.pi * 2) * 0.035;
        final pulse = 1.0 + (pulseController.value * 0.055);
        final reveal = Curves.easeInOutCubic.transform(coverController.value);

        return Transform.rotate(
          angle: spin,
          child: Transform.scale(
            scale: pulse,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.purple.withOpacity(0.55),
                        blurRadius: 86,
                        spreadRadius: 8,
                      ),
                      BoxShadow(
                        color: Colors.white.withOpacity(0.08),
                        blurRadius: 24,
                        spreadRadius: -2,
                      ),
                    ],
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(44),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      width: 138,
                      height: 138,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(44),
                        border: Border.all(color: Colors.white.withOpacity(0.16)),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withOpacity(0.16),
                            Colors.white.withOpacity(0.04),
                          ],
                        ),
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Image.asset(
                              logoAsset,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.bolt_rounded,
                                color: Colors.white,
                                size: 74,
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: FractionalTranslation(
                              translation: Offset(-1.15 * reveal, 0),
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(36),
                                  gradient: LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    colors: [
                                      const Color(0xFF7C3BFF).withOpacity(0.96),
                                      const Color(0xFF41108E).withOpacity(0.94),
                                      Colors.white.withOpacity(0.18),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).animate().fadeIn(duration: 540.ms).scale(begin: const Offset(0.82, 0.82), curve: Curves.easeOutBack);
  }
}

class _GlowOrb extends StatelessWidget {
  final double size;
  final Color color;

  const _GlowOrb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [BoxShadow(color: color, blurRadius: 110, spreadRadius: 40)],
        ),
      ),
    );
  }
}

class _SplashGridPainter extends CustomPainter {
  final Color color;

  const _SplashGridPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    const spacing = 38.0;
    for (double x = 0; x <= size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SplashGridPainter oldDelegate) => oldDelegate.color != color;
}
