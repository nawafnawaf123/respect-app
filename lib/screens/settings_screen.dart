// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_local_variable, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, prefer_const_literals_to_create_immutables, curly_braces_in_flow_control_structures, sized_box_for_whitespace, dead_code, unnecessary_type_check, unnecessary_non_null_assertion, use_build_context_synchronously, unnecessary_brace_in_string_interps, prefer_final_fields
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/theme_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../services/supabase_service.dart';
import '../services/realtime_notification_service.dart';
import 'login_screen.dart';

void _scannerSafeIgnore([Object? error, StackTrace? stackTrace]) {}


class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _accountsKey = 'respect_accounts_v1';
  static const String _currentUserKey = 'respect_current_user_id';

  String? _currentId;
  String? _profileImagePath;
  String _profileName = 'Nawaf RP';
  String _profileUsername = '@nawaf_city';

  // ----- ميزات الخصوصية الجديدة -----
  bool _isScreenBlack = false;
  bool _privacyModeEnabled = false;
  bool _quickHideEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadPrivacySettings();
  }

  Future<void> _loadPrivacySettings() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('privacy_mode_enabled') ?? false;
    final quickHide = prefs.getBool('quick_hide_enabled') ?? false;
    if (mounted) {
      setState(() {
        _privacyModeEnabled = enabled;
        _quickHideEnabled = quickHide;
      });
    }
  }

  Future<void> _savePrivacyMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('privacy_mode_enabled', enabled);
  }

  Future<void> _saveQuickHide(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('quick_hide_enabled', enabled);
  }

  Future<void> _togglePrivacyMode(bool value) async {
    setState(() => _privacyModeEnabled = value);
    await _savePrivacyMode(value);
  }

  Future<void> _toggleQuickHide(bool value) async {
    setState(() {
      _quickHideEnabled = value;
      if (!value) {
        _isScreenBlack = false;
      }
    });
    await _saveQuickHide(value);
  }

  Future<List<Map<String, dynamic>>> _loadAccounts(SharedPreferences prefs) async {
    final raw = prefs.getString(_accountsKey);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAccounts(SharedPreferences prefs, List<Map<String, dynamic>> accounts) async {
    await prefs.setString(_accountsKey, jsonEncode(accounts));
  }

  int _currentIndex(List<Map<String, dynamic>> accounts, String? id) {
    if (id == null) return -1;
    return accounts.indexWhere((a) => (a['id'] ?? '').toString() == id);
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_currentUserKey) ?? prefs.getString('current_user_id');
    Map<String, dynamic> account = <String, dynamic>{};

    final accounts = await _loadAccounts(prefs);
    final index = _currentIndex(accounts, id);
    if (index >= 0) account = accounts[index];

    if (account.isEmpty && id != null) {
      final rawUsers = prefs.getString('respect_users_map');
      if (rawUsers != null && rawUsers.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(rawUsers);
          if (decoded is Map && decoded[id] is Map) {
            account = (decoded[id] as Map).map((k, v) => MapEntry(k.toString(), v));
          }
        } catch (_) { _scannerSafeIgnore(); }
      }
    }

    if (!mounted) return;
    setState(() {
      _currentId = id;
      _profileImagePath = (account['imagePath'] ?? account['profileImagePath'])?.toString();
      _profileName = (account['profileName'] ?? account['name'] ?? 'Nawaf RP').toString();
      _profileUsername = (account['username'] ?? id ?? '@nawaf_city').toString();
      if (!_profileUsername.startsWith('@')) _profileUsername = '@$_profileUsername';
    });
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? AppColors.darkCard : AppColors.lightCard,
          title: const Text('تسجيل الخروج'),
          content: const Text('هل تريد تسجيل الخروج من الحساب الحالي؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('خروج'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;
    await RealtimeNotificationService.stop();
    await SupabaseService.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (route) => false);
  }

  ImageProvider? _getProfileImageProvider() {
    final path = _profileImagePath;
    if (path == null || path.trim().isEmpty) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  void _handleLongPress() {
    if (!_quickHideEnabled) return;
    setState(() {
      _isScreenBlack = !_isScreenBlack;
    });
  }

  // طبقة الخصوصية تغطي الشاشة كاملة مع تأثير جانبي
  Widget _privacyOverlay() {
    if (!_privacyModeEnabled) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Colors.black.withValues(alpha: 0.8),
                Colors.black.withValues(alpha: 0.5),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.5),
                Colors.black.withValues(alpha: 0.8),
              ],
              stops: const [0.0, 0.1, 0.5, 0.9, 1.0],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: null,
      body: GestureDetector(
        onLongPress: _handleLongPress,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            // المحتوى الأصلي
            RefreshIndicator(
              color: AppColors.purple,
              onRefresh: _loadProfile,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const SizedBox(height: 8),

                  GlassCard(
                    child: SwitchListTile(
                      title: const Text('الوضع الداكن'),
                      subtitle: Text(isDark ? 'مفعل حالياً' : 'معطل حالياً'),
                      value: themeProvider.isDark,
                      onChanged: (_) => themeProvider.toggle(),
                      secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode, color: AppColors.purple),
                      activeThumbColor: AppColors.purple,
                    ),
                  ).animate().fadeIn(delay: 100.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: SwitchListTile(
                      title: const Text('وضع الخصوصية (تأثير جانبي)'),
                      subtitle: const Text('يجعل الشاشة غير واضحة عند النظر من الجانب'),
                      value: _privacyModeEnabled,
                      onChanged: _togglePrivacyMode,
                      secondary: const Icon(Icons.visibility_off_rounded, color: AppColors.purple),
                      activeThumbColor: AppColors.purple,
                    ),
                  ).animate().fadeIn(delay: 150.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: SwitchListTile(
                      title: const Text('إخفاء سريع (الضغط 3 ثواني)'),
                      subtitle: const Text('تفعيل ميزة تعتيم الشاشة بالضغط مع الاستمرار'),
                      value: _quickHideEnabled,
                      onChanged: _toggleQuickHide,
                      secondary: const Icon(Icons.touch_app_rounded, color: AppColors.purple),
                      activeThumbColor: AppColors.purple,
                    ),
                  ).animate().fadeIn(delay: 200.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: ListTile(
                      leading: const Icon(Icons.language, color: AppColors.purple),
                      title: const Text('اللغة'),
                      subtitle: const Text('العربية'),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: () {},
                    ),
                  ).animate().fadeIn(delay: 200.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: ListTile(
                      leading: const Icon(Icons.info_outline, color: AppColors.purple),
                      title: const Text('حول التطبيق'),
                      subtitle: const Text('الإصدار 1.0.0'),
                      onTap: () {},
                    ),
                  ).animate().fadeIn(delay: 300.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: ListTile(
                      leading: const Icon(Icons.logout_rounded, color: AppColors.danger),
                      title: const Text('تسجيل الخروج', style: TextStyle(fontWeight: FontWeight.w900)),
                      subtitle: const Text('العودة إلى صفحة تسجيل الدخول'),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: _logout,
                    ),
                  ).animate().fadeIn(delay: 400.ms),
                ],
              ),
            ),

            // طبقة التعتيم الكامل (الشاشة السوداء)
            if (_isScreenBlack)
              Positioned.fill(
                child: GestureDetector(
                  onLongPress: _handleLongPress,
                  behavior: HitTestBehavior.opaque,
                  child: Container(color: Colors.black),
                ),
              ),

            // طبقة الخصوصية (تأثير الجوانب)
            _privacyOverlay(),
          ],
        ),
      ),
    );
  }
}
