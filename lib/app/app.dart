// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, use_build_context_synchronously, unnecessary_this, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures, prefer_final_fields, unnecessary_type_check, unnecessary_non_null_assertion
import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../screens/home_screen.dart';
import '../screens/feed_screen.dart';
import '../screens/login_screen.dart';
import '../screens/splash_screen.dart';
import '../services/supabase_service.dart';
import '../services/notification_service.dart';
import '../services/push_notification_service.dart';
import '../services/realtime_notification_service.dart';
import '../services/call_action_handler.dart';
import '../theme/app_theme.dart';
import 'theme_provider.dart';

import 'app_language.dart';
void _respectSafeLog(Object error, [StackTrace? stackTrace]) {
  if (kDebugMode) {
    developer.log('Respect safe catch', error: error, stackTrace: stackTrace, name: 'respect.safe');
  }
}


class RPStreamHubApp extends StatelessWidget {
  const RPStreamHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<ThemeProvider>().themeMode;
    final languageProvider = context.watch<AppLanguageProvider>();

    return MaterialApp(
      navigatorKey: NotificationService.navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Respect App',
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLanguageProvider.supportedLocales,
      locale: languageProvider.locale,
      theme: AppTheme.lightTheme.copyWith(
        textTheme: GoogleFonts.cairoTextTheme(AppTheme.lightTheme.textTheme),
      ),
      darkTheme: AppTheme.darkTheme.copyWith(
        textTheme: GoogleFonts.cairoTextTheme(AppTheme.darkTheme.textTheme),
      ),
      themeMode: themeMode,

      builder: (context, child) {
        return Directionality(
          textDirection: languageProvider.textDirection,
          child: child ?? const SizedBox.shrink(),
        );
      },

      // مهم جدًا للويب و TestSprite:
      // لا نستخدم home فقط، لأن فتح /login مباشرة قد يعطي صفحة بيضاء.
      initialRoute: '/',
      onGenerateRoute: _generateRoute,
      onUnknownRoute: (settings) {
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const AuthGate(),
        );
      },
    );
  }

  static Route<dynamic> _generateRoute(RouteSettings settings) {
    final rawName = settings.name ?? '/';
    final uri = Uri.tryParse(rawName);
    final path = uri?.path ?? rawName;

    Widget page;

    switch (path) {
      case '/':
      case '':
        page = const AuthGate();
        break;

      case '/login':
      case '/signin':
      case '/auth':
      // هذا يحل مشكلة TestSprite عندما يفتح /login مباشرة.
        page = const LoginScreen();
        break;

      case '/home':
      case '/feed':
        page = const HomeScreen();
        break;

      default:
      // أي رابط غير معروف يرجع للتطبيق بدل صفحة بيضاء.
        page = const AuthGate();
        break;
    }

    return MaterialPageRoute(
      settings: settings,
      builder: (_) => page,
    );
  }
}

class AuthBootResult {
  final bool loggedIn;
  final bool deviceBanned;
  final String blockReason;

  const AuthBootResult({
    required this.loggedIn,
    this.deviceBanned = false,
    this.blockReason = '',
  });
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Future<AuthBootResult>? _bootFuture;

  @override
  void initState() {
    super.initState();
    _bootFuture = _bootstrapApp();
  }

  Future<AuthBootResult> _bootstrapApp() async {
    final ban = await SupabaseService.currentDeviceBan();
    if (ban != null) {
      await SupabaseService.clearLocalSessionOnly();
      return AuthBootResult(
        loggedIn: false,
        deviceBanned: true,
        blockReason: (ban['reason'] ?? 'تم حظر هذا الجهاز من استخدام Respect App').toString(),
      );
    }

    bool validSession = false;
    try {
      validSession = await SupabaseService.hasSavedSession();
    } catch (e, st) {
      _respectSafeLog(e, st);
      validSession = false;
    }

    if (!validSession) {
      return const AuthBootResult(loggedIn: false);
    }

    await Future.wait<void>([
      // على الويب نخلي الإشعارات والمكالمات خارج التشغيل حتى لا تعطل TestSprite.
      if (!kIsWeb) _safe(() => PushNotificationService.registerTokenForCurrentUser()),
      _safe(() => RealtimeNotificationService.start()),
      _safe(() => FeedScreen.preloadForSplash(limit: 24)),
    ]);

    if (!kIsWeb) {
      CallActionHandler.initialize();
      await _safe(() => NotificationService.openLaunchPayloadIfAny());
    }

    return const AuthBootResult(loggedIn: true);
  }

  Future<void> _safe(Future<void> Function() task) async {
    try {
      await task();
    } catch (e, st) { _respectSafeLog(e, st); }
  }

  @override
  Widget build(BuildContext context) {
    final boot = _bootFuture ??= _bootstrapApp();
    return SplashScreen<AuthBootResult>(
      onInitialize: () => boot,
      logoAsset: 'assets/logo.png',
      title: 'Respect App',
      subtitle: 'Loading your world...',
      destinationBuilder: (context, result) {
        if (result.deviceBanned) {
          return BlockedDeviceScreen(reason: result.blockReason);
        }
        return result.loggedIn ? const HomeScreen() : const LoginScreen();
      },
    );
  }
}

class BlockedDeviceScreen extends StatelessWidget {
  final String reason;

  const BlockedDeviceScreen({super.key, required this.reason});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              isDark ? const Color(0xFF12081F) : const Color(0xFFF6F0FF),
              isDark ? const Color(0xFF08050D) : Colors.white,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 118,
                height: 118,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.danger.withValues(alpha: 0.12),
                  border: Border.all(color: AppColors.danger.withValues(alpha: 0.45), width: 2),
                  boxShadow: [
                    BoxShadow(color: AppColors.danger.withValues(alpha: 0.18), blurRadius: 32, spreadRadius: 4),
                  ],
                ),
                child: const Icon(Icons.phonelink_lock_rounded, color: AppColors.danger, size: 56),
              ),
              const SizedBox(height: 24),
              const AppText(
                'تم حظر هذا الجهاز',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              AppText(
                reason.trim().isEmpty ? 'لا يمكنك فتح Respect App من هذا الجهاز.' : reason,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.7,
                  color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 26),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: AppColors.purple.withValues(alpha: 0.10),
                  border: Border.all(color: AppColors.purple.withValues(alpha: 0.22)),
                ),
                child: const AppText(
                  'تواصل مع إدارة Respect إذا تعتقد أن الحظر تم بالخطأ.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}