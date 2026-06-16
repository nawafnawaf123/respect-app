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
import '../services/notification_service.dart';
import 'login_screen.dart';

import '../app/app_language.dart';
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

  bool _sendingAiFeedback = false;
  bool _approvingAiFeedbackFix = false;
  Map<String, dynamic>? _latestAiFeedbackResult;

  @override
  void initState() {
    super.initState();
    _loadSettingsBootstrap();
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
      _showSettingsSuccess(
        'تم إرسال رمز SMS إلى $phone',
        title: 'رمز التحقق',
      );
    } catch (e) {
      if (!mounted) return;
      _showSettingsError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _savingPhoneSecurity = false);
    }
  }

  Future<void> _verifyPhoneSecurityCode() async {
    if (_savingPhoneSecurity) return;
    final code = _phoneCodeCtrl.text.trim();
    if (code.length < 4) {
      _showSettingsError('اكتب رمز SMS');
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
      _showSettingsSuccess(
        'تم تفعيل الأمان عبر الرقم بنجاح',
        title: 'تم تفعيل الأمان',
      );
    } catch (e) {
      if (!mounted) return;
      _showSettingsError(e.toString().replaceFirst('Exception: ', ''));
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
      _showSettingsSuccess(
        'تم حفظ خصوصية الرسائل',
        title: 'تم الحفظ',
      );
    } catch (e) {
      if (!mounted) return;
      _showSettingsError('تعذر حفظ خصوصية الرسائل: $e');
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
          title: const AppText('تسجيل الخروج'),
          content: const AppText('هل تريد تسجيل الخروج من الحساب الحالي؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const AppText('إلغاء')),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.logout_rounded),
              label: const AppText('خروج'),
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

  void _showSettingsSuccess(
    String message, {
    String title = 'تم بنجاح',
  }) {
    NotificationService.showTopSuccess(message, title: title);
  }

  void _showSettingsError(
    String message, {
    String title = 'حدث خطأ',
  }) {
    NotificationService.showTopError(message, title: title);
  }

  void _showSettingsInfo(
    String message, {
    String title = 'Respect',
    IconData icon = Icons.info_rounded,
  }) {
    NotificationService.showTopNotification(
      message,
      title: title,
      icon: icon,
      accentColor: AppColors.purple,
    );
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
      _showSettingsError('اكتب وصف المشكلة بتفاصيل أكثر');
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
      _showSettingsSuccess(
        'تم إرسال البلاغ وبدأ تحليل Qwen3-Coder',
        title: 'تم إرسال البلاغ',
      );
    } catch (e) {
      if (!mounted) return;
      _showSettingsError('تعذر تحليل البلاغ: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _sendingAiFeedback = false);
    }
  }

  Future<void> _approveAiFeedbackFix() async {
    if (_approvingAiFeedbackFix) return;
    final reportId = (_latestAiFeedbackResult?['id'] ?? _latestAiFeedbackResult?['reportId'] ?? '').toString();
    if (reportId.trim().isEmpty) {
      _showSettingsError('لا يوجد بلاغ محلل للموافقة عليه');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('تأكيد التصحيح'),
        content: const AppText('سيتم طلب التصحيح من Qwen3-Coder ثم إنشاء Pull Request في GitHub إذا كانت مفاتيح GitHub مضبوطة على السيرفر.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const AppText('إلغاء')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.auto_fix_high_rounded),
            label: const AppText('ابدأ التصحيح'),
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
      _showSettingsSuccess(
        prUrl.isNotEmpty ? 'تم إنشاء Pull Request للتصحيح' : 'تم تجهيز نتيجة التصحيح',
        title: 'نتيجة التصحيح',
      );
    } catch (e) {
      if (!mounted) return;
      _showSettingsError('تعذر تنفيذ التصحيح: ${e.toString().replaceFirst('Exception: ', '')}');
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
              title: AppText('ملاحظات / بلاغ مشكلة', style: TextStyle(fontWeight: FontWeight.w900)),
              subtitle: AppText('اكتب المشكله او الملاحظه وسيتم المراجعة والاصلاح في اقرب وقت ممكن '),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _feedbackTitleCtrl,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: context.tr('عنوان المشكلة'),
                hintText: context.tr('مثلاً: زر تعديل الملف الشخصي لا يعمل'),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _feedbackScreenCtrl,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: context.tr('مكان المشكلة / الصفحة'),
                hintText: context.tr('مثلاً: الملف الشخصي، الفيد، الرسائل'),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _feedbackNoteCtrl,
              minLines: 4,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: context.tr('وصف المشكلة'),
                hintText: context.tr('اشرح ماذا حدث، ماذا توقعت، وهل ظهر خطأ معين'),
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
              label: AppText(_sendingAiFeedback ? 'جاري التحليل...' : 'إرسال'),
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
                    AppText('الحالة: ${_aiFeedbackStatusText(status)}', style: const TextStyle(fontWeight: FontWeight.w900)),
                    if (summary.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      AppText(summary),
                    ],
                    if (suspectedFiles.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const AppText('الملفات المتوقعة:', style: TextStyle(fontWeight: FontWeight.w900)),
                      const SizedBox(height: 4),
                      ...suspectedFiles.map((file) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: AppText('• $file', textDirection: TextDirection.ltr),
                      )),
                    ],
                    if (prUrl.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      AppText('Pull Request: $prUrl', textDirection: TextDirection.ltr),
                    ],
                    if (_canApproveAiFeedbackFix && status.toLowerCase() == 'analyzed') ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _approvingAiFeedbackFix ? null : _approveAiFeedbackFix,
                        icon: _approvingAiFeedbackFix
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.auto_fix_high_rounded),
                        label: AppText(_approvingAiFeedbackFix ? 'جاري التصحيح...' : 'الموافقة وبدء التصحيح'),
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


  Future<void> _showLanguagePicker() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        final languageProvider = sheetContext.watch<AppLanguageProvider>();
        return Directionality(
          textDirection: languageProvider.textDirection,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.82,
            ),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard : AppColors.lightCard,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 46,
                    height: 5,
                    decoration: BoxDecoration(
                      color: (isDark ? AppColors.darkMuted : AppColors.lightMuted).withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppColors.purple.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(Icons.language_rounded, color: AppColors.purple),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppText('اختر لغة التطبيق', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                              SizedBox(height: 3),
                              AppText('تتغير اللغة فورًا في كل صفحات التطبيق', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 18),
                      itemCount: AppLanguageProvider.supportedLanguages.length,
                      itemBuilder: (context, index) {
                        final language = AppLanguageProvider.supportedLanguages[index];
                        final selected = language.code == languageProvider.languageCode;
                        return Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: selected ? AppColors.purple.withValues(alpha: 0.13) : Colors.transparent,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: selected ? AppColors.purple.withValues(alpha: 0.45) : Colors.transparent,
                            ),
                          ),
                          child: RadioListTile<String>(
                            value: language.code,
                            groupValue: languageProvider.languageCode,
                            activeColor: AppColors.purple,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                            title: Text(language.nativeName, style: const TextStyle(fontWeight: FontWeight.w900)),
                            subtitle: Text(language.englishName),
                            secondary: selected ? const Icon(Icons.check_circle_rounded, color: AppColors.purple) : const Icon(Icons.translate_rounded),
                            onChanged: (value) async {
                              if (value == null) return;
                              await languageProvider.setLanguageCode(value);
                              if (!mounted) return;
                              Navigator.pop(sheetContext);
                              _showSettingsSuccess(
                                'تم تغيير لغة التطبيق',
                                title: 'اللغة',
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
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
    final languageProvider = context.watch<AppLanguageProvider>();
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
                      title: const AppText('الوضع الداكن'),
                      subtitle: AppText(isDark ? 'مفعل حالياً' : 'معطل حالياً'),
                      value: themeProvider.isDark,
                      onChanged: (_) => themeProvider.toggle(),
                      secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode, color: AppColors.purple),
                      activeThumbColor: AppColors.purple,
                    ),
                  ).animate().fadeIn(delay: 100.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: SwitchListTile(
                      title: const AppText('وضع الخصوصية (تأثير جانبي)'),
                      subtitle: const AppText('يجعل الشاشة غير واضحة عند النظر من الجانب'),
                      value: _privacyModeEnabled,
                      onChanged: _togglePrivacyMode,
                      secondary: const Icon(Icons.visibility_off_rounded, color: AppColors.purple),
                      activeThumbColor: AppColors.purple,
                    ),
                  ).animate().fadeIn(delay: 150.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: SwitchListTile(
                      title: const AppText('إخفاء سريع (الضغط 3 ثواني)'),
                      subtitle: const AppText('تفعيل ميزة تعتيم الشاشة بالضغط مع الاستمرار'),
                      value: _quickHideEnabled,
                      onChanged: _toggleQuickHide,
                      secondary: const Icon(Icons.touch_app_rounded, color: AppColors.purple),
                      activeThumbColor: AppColors.purple,
                    ),
                  ).animate().fadeIn(delay: 200.ms),

                  const SizedBox(height: 12),

                  _buildAiFeedbackCard().animate().fadeIn(delay: 220.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(_phoneVerified ? Icons.verified_user_rounded : Icons.phone_iphone_rounded, color: AppColors.purple),
                            title: const AppText('الأمان عبر رقم الجوال', style: TextStyle(fontWeight: FontWeight.w900)),
                            subtitle: AppText(_phoneVerified
                                ? 'مفعل على الرقم $_phoneE164 ويمكن استخدام SMS لاستعادة الدخول'
                                : 'أضف رقمك واستقبل رمز SMS لتفعيل حماية إضافية للحساب'),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              SizedBox(
                                width: 95,
                                child: TextField(
                                  controller: _phoneCountryCtrl,
                                  keyboardType: TextInputType.phone,
                                  decoration: InputDecoration(
                                    labelText: context.tr('الدولة'),
                                    hintText: context.tr('+961'),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _phoneCtrl,
                                  keyboardType: TextInputType.phone,
                                  decoration: InputDecoration(
                                    labelText: context.tr('رقم الجوال'),
                                    hintText: context.tr('70123456'),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          FilledButton.icon(
                            onPressed: _savingPhoneSecurity ? null : _sendPhoneSecurityCode,
                            icon: _savingPhoneSecurity
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.sms_rounded),
                            label: AppText(_phoneVerified ? 'تغيير الرقم وإرسال رمز جديد' : 'إرسال رمز التحقق SMS'),
                          ),
                          if (_phoneCodeSent) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: _phoneCodeCtrl,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              decoration: InputDecoration(
                                labelText: context.tr('رمز SMS'),
                                hintText: context.tr('000000'),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: _savingPhoneSecurity ? null : _verifyPhoneSecurityCode,
                              icon: const Icon(Icons.check_circle_rounded),
                              label: const AppText('تأكيد وتفعيل الأمان'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ).animate().fadeIn(delay: 230.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.chat_bubble_outline_rounded, color: AppColors.purple),
                          title: const AppText('خصوصية الرسائل', style: TextStyle(fontWeight: FontWeight.w900)),
                          subtitle: AppText(_canUseVerifiedOnlyMessages
                              ? 'يمكنك قفل الرسائل على الحسابات الموثقة فقط'
                              : 'ميزة الموثقين فقط تحتاج الباقة الذهبية أو المميزة'),
                        ),
                        SwitchListTile(
                          title: const AppText('تفعيل الرسائل'),
                          subtitle: const AppText('عند الإيقاف لا أحد يستطيع إرسال رسالة جديدة لك'),
                          value: _messagesEnabled,
                          onChanged: (v) => setState(() => _messagesEnabled = v),
                          activeThumbColor: AppColors.purple,
                        ),
                        SwitchListTile(
                          title: const AppText('استقبال الرسائل من الموثقين فقط'),
                          subtitle: AppText(_canUseVerifiedOnlyMessages
                              ? 'غير الموثق سيُمنع من إرسال الرسالة'
                              : 'مقفلة للحسابات الذهبية والمميزة فقط'),
                          value: _verifiedOnlyMessages && _canUseVerifiedOnlyMessages,
                          onChanged: _messagesEnabled && _canUseVerifiedOnlyMessages
                              ? (v) => setState(() => _verifiedOnlyMessages = v)
                              : null,
                          activeThumbColor: AppColors.purple,
                        ),
                        SwitchListTile(
                          title: const AppText('طلب دردشة قبل أول رسالة'),
                          subtitle: const AppText('يفتح المحادثة بعد قبول الطلب'),
                          value: _chatRequestsRequired,
                          onChanged: _messagesEnabled ? (v) => setState(() => _chatRequestsRequired = v) : null,
                          activeThumbColor: AppColors.purple,
                        ),
                        SwitchListTile(
                          title: const AppText('السماح بالمكالمات'),
                          subtitle: const AppText('عند الإيقاف لا أحد يستطيع الاتصال بك'),
                          value: _callsEnabled,
                          onChanged: (v) => setState(() => _callsEnabled = v),
                          activeThumbColor: AppColors.purple,
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _savingMessagingPrivacy ? null : _saveMessagingPrivacySettings,
                              icon: _savingMessagingPrivacy
                                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.save_rounded),
                              label: const AppText('حفظ خصوصية الرسائل'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ).animate().fadeIn(delay: 250.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: ListTile(
                      leading: const Icon(Icons.language, color: AppColors.purple),
                      title: const AppText('اللغة'),
                      subtitle: Text(languageProvider.currentLanguage.nativeName),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: _showLanguagePicker,
                    ),
                  ).animate().fadeIn(delay: 200.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: ListTile(
                      leading: const Icon(Icons.info_outline, color: AppColors.purple),
                      title: const AppText('حول التطبيق'),
                      subtitle: const AppText('الإصدار 1.0.0'),
                      onTap: () {},
                    ),
                  ).animate().fadeIn(delay: 300.ms),

                  const SizedBox(height: 12),

                  GlassCard(
                    child: ListTile(
                      leading: const Icon(Icons.logout_rounded, color: AppColors.danger),
                      title: const AppText('تسجيل الخروج', style: TextStyle(fontWeight: FontWeight.w900)),
                      subtitle: const AppText('العودة إلى صفحة تسجيل الدخول'),
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
