// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, prefer_const_literals_to_create_immutables, curly_braces_in_flow_control_structures, sized_box_for_whitespace, dead_code, unnecessary_type_check, unnecessary_non_null_assertion, use_build_context_synchronously, unnecessary_brace_in_string_interps, prefer_final_fields
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

  final TextEditingController _phoneCountryCtrl = TextEditingController(text: '+961');
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _phoneCodeCtrl = TextEditingController();
  final TextEditingController _feedbackTitleCtrl = TextEditingController(text: 'مشكلة في التطبيق');
  final TextEditingController _feedbackNoteCtrl = TextEditingController();
  final TextEditingController _feedbackScreenCtrl = TextEditingController(text: 'الإعدادات');
  String _phoneE164 = '';
  bool _phoneVerified = false;
  bool _smsSecurityEnabled = false;
  bool _phoneCodeSent = false;
  bool _savingPhoneSecurity = false;

  // ----- ميزات الخصوصية الجديدة -----
  bool _isScreenBlack = false;
  bool _privacyModeEnabled = false;
  bool _quickHideEnabled = false;

  bool _messagesEnabled = true;
  bool _verifiedOnlyMessages = false;
  bool _callsEnabled = true;
  bool _chatRequestsRequired = true;
  bool _canUseVerifiedOnlyMessages = false;
  bool _savingMessagingPrivacy = false;

  // ----- إعدادات اللغة -----
  String _selectedLanguage = 'ar';

  bool _sendingAiFeedback = false;
  bool _approvingAiFeedbackFix = false;
  Map<String, dynamic>? _latestAiFeedbackResult;

  @override
  void initState() {
    super.initState();
    _loadSettingsBootstrap();
    _loadLanguageSetting();
  }

  @override
  void dispose() {
    _phoneCountryCtrl.dispose();
    _phoneCtrl.dispose();
    _phoneCodeCtrl.dispose();
    _feedbackTitleCtrl.dispose();
    _feedbackNoteCtrl.dispose();
    _feedbackScreenCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSettingsBootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    await _loadProfile(prefs);
    await Future.wait<void>([
      _loadPrivacySettings(prefs),
      _loadMessagingPrivacySettings(),
      _loadPhoneSecuritySettings(),
    ]);
  }

  Future<void> _loadLanguageSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final languageCode = prefs.getString('language_code') ?? 'ar';
    if (mounted) {
      setState(() {
        _selectedLanguage = languageCode;
      });
    }
  }

  Future<void> _changeLanguage(String languageCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language_code', languageCode);
    if (mounted) {
      setState(() {
        _selectedLanguage = languageCode;
      });
    }
    // إعادة تشغيل التطبيق أو تحديث واجهة المستخدم
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    themeProvider.toggleTheme();
    themeProvider.toggleTheme(); // تبديل مرة أخرى للعودة إلى نفس الوضع
  }

  Future<void> _loadPrivacySettings([SharedPreferences? cachedPrefs]) async {
    final prefs = cachedPrefs ?? await SharedPreferences.getInstance();
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

  Future<void> _loadPhoneSecuritySettings() async {
    try {
      final user = await SupabaseService.getUserByUsername(_profileUsername);
      if (user == null || !mounted) return;
      final phone = (user['phone_e164'] ?? '').toString();
      setState(() {
        _phoneE164 = phone;
        _phoneVerified = SupabaseService.truthy(user['phone_verified']);
        _smsSecurityEnabled = SupabaseService.truthy(user['sms_security_enabled']) || _phoneVerified;
        if (phone.isNotEmpty) {
          _phoneCtrl.text = phone;
          _phoneCountryCtrl.text = '';
        }
      });
    } catch (_) { _scannerSafeIgnore(); }
  }

  Future<void> _sendPhoneSecurityCode() async {
    if (_savingPhoneSecurity) return;
    FocusScope.of(context).unfocus();
    setState(() => _savingPhoneSecurity = true);
    try {
      final res = await SupabaseService.requestPhoneSecurityCode(
        username: _profileUsername,
        countryCode: _phoneCountryCtrl.text,
        phone: _phoneCtrl.text,
      );
      final phone = (res['phoneE164'] ?? '').toString();
      if (!mounted) return;
      setState(() {
        _phoneE164 = phone;
        _phoneCodeSent = true;
        _phoneVerified = false;
        _smsSecurityEnabled = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم إرسال رمز SMS إلى $phone')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _savingPhoneSecurity = false);
    }
  }

  Future<void> _verifyPhoneSecurityCode() async {
    if (_savingPhoneSecurity) return;
    final code = _phoneCodeCtrl.text.trim();
    if (code.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اكتب رمز SMS')));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _savingPhoneSecurity = true);
    try {
      final res = await SupabaseService.verifyPhoneSecurityCode(
        username: _profileUsername,
        phoneE164: _phoneE164,
        code: code,
      );
      if (!mounted) return;
      setState(() {
        _phoneVerified = res['verified'] == true;
        _smsSecurityEnabled = true;
        _phoneCodeSent = false;
        _phoneCodeCtrl.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تفعيل الأمان عبر الرقم بنجاح')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _savingPhoneSecurity = false);
    }
  }

  Future<void> _loadMessagingPrivacySettings() async {
    final username = _profileUsername.trim().isEmpty ? '@user' : _profileUsername;
    try {
      final results = await Future.wait<dynamic>([
        SupabaseService.getMessagingPrivacySettings(username),
        SupabaseService.getUserByUsername(username),
      ]);
      final settings = Map<String, dynamic>.from(results[0] as Map);
      final user = results[1] is Map ? Map<String, dynamic>.from(results[1] as Map) : null;
      final canUse = SupabaseService.canUseVerifiedOnlyMessagesFeature(user);
      if (!mounted) return;
      setState(() {
        _messagesEnabled = SupabaseService.truthy(settings['messages_enabled'] ?? true);
        _verifiedOnlyMessages = canUse && SupabaseService.truthy(settings['verified_only_messages']);
        _callsEnabled = SupabaseService.truthy(settings['calls_enabled'] ?? true);
        _chatRequestsRequired = SupabaseService.truthy(settings['chat_requests_required'] ?? true);
        _canUseVerifiedOnlyMessages = canUse;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _verifiedOnlyMessages = false;
        _canUseVerifiedOnlyMessages = false;
      });
    }
  }

  Future<void> _saveMessagingPrivacySettings() async {
    if (_savingMessagingPrivacy) return;
    setState(() => _savingMessagingPrivacy = true);
    try {
      final next = await SupabaseService.updateMessagingPrivacySettings(
        username: _profileUsername,
        messagesEnabled: _messagesEnabled,
        verifiedOnlyMessages: _verifiedOnlyMessages && _canUseVerifiedOnlyMessages,
        callsEnabled: _callsEnabled,
        chatRequestsRequired: _chatRequestsRequired,
      );
      if (!mounted) return;
      setState(() {
        _messagesEnabled = SupabaseService.truthy(next['messages_enabled'] ?? true);
        _verifiedOnlyMessages = _canUseVerifiedOnlyMessages && SupabaseService.truthy(next['verified_only_messages']);
        _callsEnabled = SupabaseService.truthy(next['calls_enabled'] ?? true);
        _chatRequestsRequired = SupabaseService.truthy(next['chat_requests_required'] ?? true);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ خصوصية الرسائل')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر حفظ خصوصية الرسائل: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingMessagingPrivacy = false);
    }
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

  Future<void> _loadProfile([SharedPreferences? cachedPrefs]) async {
    final prefs = cachedPrefs ?? await SharedPreferences.getInstance();
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



  bool get _canApproveAiFeedbackFix {
    final clean = _profileUsername.trim().toLowerCase().replaceAll('@', '');
    return clean == 'mjakcon8' || clean == 'nawafrp' || clean == 'nawaf_city' || clean == 'nawafnawaf123';
  }

  String _aiFeedbackStatusText(String status) {
    switch (status.trim().toLowerCase()) {
      case 'analyzed':
        return 'تم التحليل وينتظر موافقتك';
      case 'approved':
        return 'تمت الموافقة ويجري تجهيز التصحيح';
      case 'pull_request_created':
        return 'تم إنشاء Pull Request في GitHub';
      case 'applied':
        return 'تم تجهيز التصحيح';
      case 'failed':
        return 'فشل تنفيذ التصحيح';
      default:
        return status.isEmpty ? 'لم يتم الإرسال بعد' : status;
    }
  }

  Future<void> _submitAiFeedbackReport() async {
    if (_sendingAiFeedback) return;
    final note = _feedbackNoteCtrl.text.trim();
    if (note.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اكتب وصف المشكلة بتفاصيل أكثر')),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _sendingAiFeedback = true);
    try {
      final result = await SupabaseService.submitRespectAiAppFeedback(
        username: _profileUsername,
        name: _profileName,
        title: _feedbackTitleCtrl.text,
        note: note,
        screen: _feedbackScreenCtrl.text,
        appVersion: '1.0.0',
      );
      if (!mounted) return;
      setState(() => _latestAiFeedbackResult = result);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم إرسال البلاغ وبدأ تحليل Qwen3-Coder')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحليل البلاغ: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    } finally {
      if (mounted) setState(() => _sendingAiFeedback = false);
    }
  }

  Future<void> _approveAiFeedbackFix() async {
    if (_approvingAiFeedbackFix) return;
    final reportId = (_latestAiFeedbackResult?['id'] ?? _latestAiFeedbackResult?['reportId'] ?? '').toString();
    if (reportId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يوجد بلاغ محلل للموافقة عليه')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد التصحيح'),
        content: const Text('سيتم طلب التصحيح من Qwen3-Coder ثم إنشاء Pull Request في GitHub إذا كانت مفاتيح GitHub مضبوطة على السيرفر.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.auto_fix_high_rounded),
            label: const Text('ابدأ التصحيح'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _approvingAiFeedbackFix = true);
    try {
      final result = await SupabaseService.approveRespectAiAppFeedbackFix(
        reportId: reportId,
        approvedBy: _profileUsername,
      );
      if (!mounted) return;
      setState(() => _latestAiFeedbackResult = result);
      final prUrl = (result['pullRequestUrl'] ?? result['prUrl'] ?? '').toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(prUrl.isNotEmpty ? 'تم إنشاء Pull Request للتصحيح' : 'تم تجهيز نتيجة التصحيح')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تنفيذ التصحيح: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    } finally {
      if (mounted) setState(() => _approvingAiFeedbackFix = false);
    }
  }

  Widget _buildAiFeedbackCard() {
    final result = _latestAiFeedbackResult;
    final analysis = result == null ? null : Map<String, dynamic>.from((result['analysis'] is Map ? result['analysis'] : result) as Map);
    final status = (result?['status'] ?? analysis?['status'] ?? '').toString();
    final suspectedFilesRaw = analysis?['suspectedFiles'] ?? analysis?['files'] ?? result?['suspectedFiles'];
    final suspectedFiles = suspectedFilesRaw is List
        ? suspectedFilesRaw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).take(8).toList()
        : <String>[];
    final summary = (analysis?['summary'] ?? analysis?['problem'] ?? result?['summary'] ?? '').toString();
    final prUrl = (result?['pullRequestUrl'] ?? result?['prUrl'] ?? '').toString();

    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.bug_report_rounded, color: AppColors.purple),
              title: Text('ملاحظات / بلاغ مشكلة', style: TextStyle(fontWeight: FontWeight.w900)),
              subtitle: Text('اكتب المشكلة، وQwen3-Coder يراجع ملفات GitHub ويحدد سببها. التصحيح لا يبدأ إلا بعد موافقة الأدمن.'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _feedbackTitleCtrl,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'عنوان المشكلة',
                hintText: 'مثلاً: زر تعديل الملف الشخصي لا يعمل',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _feedbackScreenCtrl,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'مكان المشكلة / الصفحة',
                hintText: 'مثلاً: الملف الشخصي، الفيد، الرسائل',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _feedbackNoteCtrl,
              minLines: 4,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: 'وصف المشكلة',
                hintText: 'اشرح ماذا حدث، ماذا توقعت، وهل ظهر خطأ معين',
                alignLabelWithHint: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _sendingAiFeedback ? null : _submitAiFeedbackReport,
              icon: _sendingAiFeedback
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.psychology_alt_rounded),
              label: Text(_sendingAiFeedback ? 'جاري التحليل...' : 'إرسال وتشغيل Qwen3-Coder'),
            ),
            if (result != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.purple.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.purple.withValues(alpha: 0.22)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('الحالة: ${_aiFeedbackStatusText(status)}', style: const TextStyle(fontWeight: FontWeight.w900)),
                    if (summary.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(summary),
                    ],
                    if (suspectedFiles.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Text('الملفات المتوقعة:', style: TextStyle(fontWeight: FontWeight.w900)),
                      const SizedBox(height: 4),
                      ...suspectedFiles.map((file) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text('• $file', textDirection: TextDirection.ltr),
                      )),
                    ],
                    if (prUrl.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text('Pull Request: $prUrl', textDirection: TextDirection.ltr),
                    ],
                    if (_canApproveAiFeedbackFix && status.toLowerCase().trim() == 'analyzed') ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _approvingAiFeedbackFix ? null : _approveAiFeedbackFix,
                        icon: _approvingAiFeedbackFix
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.auto_fix_high_rounded),
                        label: Text(_approvingAiFeedbackFix ? 'جاري التنفيذ...' : 'الموافقة على التصحيح'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات'),
        backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        foregroundColor: isDark ? AppColors.darkOnSurface : AppColors.lightOnSurface,
        surfaceTintColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundImage: _getProfileImageProvider(),
                      child: _getProfileImageProvider() == null
                          ? const Icon(Icons.person_rounded, size: 32)
                          : null,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _profileName,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            _profileUsername,
                            style: TextStyle(
                              color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _logout,
                      icon: const Icon(Icons.logout_rounded),
                      tooltip: 'تسجيل الخروج',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('الخصوصية', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      value: _privacyModeEnabled,
                      onChanged: _togglePrivacyMode,
                      title: const Text('وضع الخصوصية'),
                      subtitle: const Text('إخفاء محتوى الشاشة عند التبديل بين التطبيقات'),
                    ),
                    SwitchListTile.adaptive(
                      value: _quickHideEnabled,
                      onChanged: _toggleQuickHide,
                      title: const Text('إخفاء سريع'),
                      subtitle: const Text('الضغط مطولًا على الشاشة لإخفائها مؤقتًا'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('الرسائل', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      value: _messagesEnabled,
                      onChanged: (value) => setState(() => _messagesEnabled = value),
                      title: const Text('السماح بالرسائل'),
                      subtitle: const Text('السماح للمستخدمين بإرسال رسائل إليك'),
                    ),
                    if (_canUseVerifiedOnlyMessages)
                      SwitchListTile.adaptive(
                        value: _verifiedOnlyMessages,
                        onChanged: (value) => setState(() => _verifiedOnlyMessages = value),
                        title: const Text('الرسائل من المستخدمين المعتمدين فقط'),
                        subtitle: const Text('السماح بالرسائل من المستخدمين المعتمدين فقط'),
                      ),
                    SwitchListTile.adaptive(
                      value: _callsEnabled,
                      onChanged: (value) => setState(() => _callsEnabled = value),
                      title: const Text('السماح بالمكالمات'),
                      subtitle: const Text('السماح للمستخدمين ببدء مكالمات معك'),
                    ),
                    SwitchListTile.adaptive(
                      value: _chatRequestsRequired,
                      onChanged: (value) => setState(() => _chatRequestsRequired = value),
                      title: const Text('الموافقة على طلبات المحادثة'),
                      subtitle: const Text('الموافقة على طلبات المحادثة قبل بدء المحادثة'),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _saveMessagingPrivacySettings,
                      child: const Text('حفظ إعدادات الخصوصية'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('الأمان', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      value: _smsSecurityEnabled,
                      onChanged: null,
                      title: const Text('التحقق عبر الرسائل القصيرة'),
                      subtitle: Text(_phoneVerified ? 'مفعل' : 'غير مفعل'),
                    ),
                    if (!_phoneVerified) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _phoneCountryCtrl,
                        decoration: const InputDecoration(
                          labelText: 'رمز الدولة',
                          prefixIcon: Icon(Icons.flag_rounded),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'رقم الهاتف',
                          prefixIcon: Icon(Icons.phone_rounded),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_phoneCodeSent) ...[
                        TextField(
                          controller: _phoneCodeCtrl,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          decoration: const InputDecoration(
                            labelText: 'رمز التحقق',
                            prefixIcon: Icon(Icons.code_rounded),
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: _verifyPhoneSecurityCode,
                          child: const Text('تحقق من الرمز'),
                        ),
                      ],
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _sendPhoneSecurityCode,
                        child: const Text('إرسال رمز التحقق'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // إضافة قسم تغيير اللغة
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('اللغة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _selectedLanguage,
                      decoration: const InputDecoration(
                        labelText: 'اختر اللغة',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'ar',
                          child: Text('العربية'),
                        ),
                        const DropdownMenuItem(
                          value: 'en',
                          child: Text('الإنجليزية'),
                        ),
                      ],
                      onChanged: (String? newValue) {
                        if (newValue != null) {
                          _changeLanguage(newValue);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildAiFeedbackCard(),
          ],
        ),
      ),
    );
  }
}
