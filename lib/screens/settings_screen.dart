// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_local_variable, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, prefer_const_literals_to_create_immutables, curly_braces_in_flow_control_structures, sized_box_for_whitespace, dead_code, unnecessary_type_check, unnecessary_non_null_assertion, use_build_context_synchronously, unnecessary_brace_in_string_interps, prefer_final_fields
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

import '../app/theme_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/app_dialog.dart';
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
  final ImagePicker _feedbackMediaPicker = ImagePicker();
  XFile? _feedbackMediaFile;
  bool _feedbackMediaIsVideo = false;
  String _phoneE164 = '';
  bool _phoneVerified = false;
  bool _smsSecurityEnabled = false;
  bool _phoneCodeSent = false;
  bool _savingPhoneSecurity = false;
  bool _messagesEnabled = true;
  bool _verifiedOnlyMessages = false;
  bool _callsEnabled = true;
  bool _chatRequestsRequired = true;
  bool _canUseVerifiedOnlyMessages = false;
  bool _savingMessagingPrivacy = false;

  bool _sendingAppFeedback = false;
  Map<String, dynamic>? _latestAppFeedbackResult;

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
      _loadMessagingPrivacySettings(),
      _loadPhoneSecuritySettings(),
    ]);
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
    final confirm = await AppDialog.confirm(
      context,
      title: 'تسجيل الخروج',
      message: 'هل تريد تسجيل الخروج من الحساب الحالي؟',
      confirmText: 'خروج',
      cancelText: 'إلغاء',
      type: AppDialogType.danger,
      destructive: true,
      icon: Icons.logout_rounded,
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



  String _appFeedbackStatusText(String status) {
    switch (status.trim().toLowerCase()) {
      case 'pending':
      case 'submitted':
        return 'بانتظار مراجعة الإدارة';
      case 'resolved':
      case 'done':
        return 'تم حل المشكلة';
      case 'rejected':
      case 'deleted':
        return 'تم رفض البلاغ';
      default:
        return status.isEmpty ? 'بانتظار مراجعة الإدارة' : status;
    }
  }


  String _feedbackMediaFileName() {
    final file = _feedbackMediaFile;
    if (file == null) return '';
    final rawName = file.name.trim();
    if (rawName.isNotEmpty) return rawName;
    final cleanPath = file.path.replaceAll('\\', '/');
    final parts = cleanPath.split('/').where((e) => e.trim().isNotEmpty).toList();
    if (parts.isNotEmpty) return parts.last;
    return _feedbackMediaIsVideo ? 'feedback_video.mp4' : 'feedback_image.jpg';
  }

  String _feedbackMediaLabel() {
    if (_feedbackMediaFile == null) return 'لا يوجد مرفق';
    return _feedbackMediaIsVideo ? 'فيديو مرفق' : 'صورة مرفقة';
  }

  Future<void> _pickAppFeedbackMedia({required bool video}) async {
    if (_sendingAppFeedback) return;
    try {
      final picked = video
          ? await _feedbackMediaPicker.pickVideo(
              source: ImageSource.gallery,
              maxDuration: const Duration(minutes: 3),
            )
          : await _feedbackMediaPicker.pickImage(
              source: ImageSource.gallery,
              imageQuality: 88,
              maxWidth: 1920,
            );
      if (picked == null) return;

      final file = File(picked.path);
      final sizeMb = await file.length() / (1024 * 1024);
      if (video && sizeMb > 120) {
        _showSettingsError('الفيديو كبير جدًا، اختر فيديو أقل من 120MB');
        return;
      }
      if (!video && sizeMb > 20) {
        _showSettingsError('الصورة كبيرة جدًا، اختر صورة أقل من 20MB');
        return;
      }

      if (!mounted) return;
      setState(() {
        _feedbackMediaFile = picked;
        _feedbackMediaIsVideo = video;
      });
      _showSettingsInfo(
        video ? 'تم إرفاق الفيديو مع البلاغ' : 'تم إرفاق الصورة مع البلاغ',
        title: 'تم اختيار المرفق',
        icon: video ? Icons.video_file_rounded : Icons.image_rounded,
      );
    } catch (e) {
      if (!mounted) return;
      _showSettingsError('تعذر اختيار المرفق: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _showAppFeedbackMediaPicker() async {
    if (_sendingAppFeedback) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkCard : AppColors.lightCard,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: (isDark ? AppColors.darkMuted : AppColors.lightMuted).withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 14),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.attach_file_rounded, color: AppColors.purple),
                  title: AppText('إضافة مرفق للبلاغ', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: AppText('اختر صورة أو فيديو يوضح المشكلة للإدارة'),
                ),
                const SizedBox(height: 6),
                ListTile(
                  leading: const Icon(Icons.image_rounded, color: AppColors.purple),
                  title: const AppText('اختيار صورة'),
                  subtitle: const AppText('لقطة شاشة أو صورة توضح المشكلة'),
                  onTap: () {
                    Navigator.pop(context);
                    _pickAppFeedbackMedia(video: false);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.video_file_rounded, color: AppColors.purple),
                  title: const AppText('اختيار فيديو'),
                  subtitle: const AppText('تسجيل شاشة أو فيديو قصير للمشكلة'),
                  onTap: () {
                    Navigator.pop(context);
                    _pickAppFeedbackMedia(video: true);
                  },
                ),
                if (_feedbackMediaFile != null)
                  ListTile(
                    leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                    title: const AppText('حذف المرفق الحالي'),
                    onTap: () {
                      Navigator.pop(context);
                      setState(() {
                        _feedbackMediaFile = null;
                        _feedbackMediaIsVideo = false;
                      });
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAppFeedbackMediaPicker() {
    final file = _feedbackMediaFile;
    final hasMedia = file != null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = hasMedia ? AppColors.purple.withValues(alpha: 0.35) : (isDark ? AppColors.darkBorder : AppColors.lightBorder);
    final title = hasMedia ? _feedbackMediaLabel() : 'إرفاق صورة أو فيديو';
    final subtitle = hasMedia
        ? _feedbackMediaFileName()
        : 'اختياري: أضف لقطة شاشة أو فيديو حتى تظهر المشكلة للإدارة بوضوح';

    Widget preview;
    if (hasMedia && !_feedbackMediaIsVideo && File(file.path).existsSync()) {
      preview = ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image.file(
          File(file.path),
          width: 58,
          height: 58,
          fit: BoxFit.cover,
        ),
      );
    } else {
      preview = Container(
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          color: AppColors.purple.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.purple.withValues(alpha: 0.18)),
        ),
        child: Icon(
          hasMedia
              ? (_feedbackMediaIsVideo ? Icons.play_circle_fill_rounded : Icons.image_rounded)
              : Icons.add_photo_alternate_rounded,
          color: AppColors.purple,
          size: 30,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.purple.withValues(alpha: hasMedia ? 0.08 : 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          preview,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(title, style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                AppText(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            style: IconButton.styleFrom(
              backgroundColor: AppColors.purple.withValues(alpha: 0.10),
              foregroundColor: AppColors.purple,
            ),
            onPressed: _sendingAppFeedback ? null : _showAppFeedbackMediaPicker,
            icon: Icon(hasMedia ? Icons.edit_rounded : Icons.add_rounded),
            tooltip: hasMedia ? 'تغيير المرفق' : 'إضافة مرفق',
          ),
          if (hasMedia)
            IconButton(
              onPressed: _sendingAppFeedback
                  ? null
                  : () => setState(() {
                        _feedbackMediaFile = null;
                        _feedbackMediaIsVideo = false;
                      }),
              icon: const Icon(Icons.close_rounded, color: AppColors.danger),
              tooltip: 'حذف المرفق',
            ),
        ],
      ),
    );
  }

  Future<void> _submitAppFeedbackReport() async {
    if (_sendingAppFeedback) return;
    final note = _feedbackNoteCtrl.text.trim();
    if (note.length < 8) {
      _showSettingsError('اكتب وصف المشكلة بتفاصيل أكثر');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _sendingAppFeedback = true);
    try {
      final selectedMedia = _feedbackMediaFile;
      String mediaUrl = '';
      String mediaType = '';
      String mediaName = '';
      if (selectedMedia != null) {
        mediaType = _feedbackMediaIsVideo ? 'video' : 'image';
        mediaName = _feedbackMediaFileName();
        mediaUrl = await SupabaseService.uploadAppFeedbackMedia(
          username: _profileUsername,
          filePath: selectedMedia.path,
          video: _feedbackMediaIsVideo,
        );
      }

      final result = await SupabaseService.submitAppFeedbackReport(
        username: _profileUsername,
        name: _profileName,
        title: _feedbackTitleCtrl.text,
        note: note,
        screen: _feedbackScreenCtrl.text,
        appVersion: '1.0.0',
        mediaUrl: mediaUrl,
        mediaType: mediaType,
        mediaName: mediaName,
      );
      if (!mounted) return;
      setState(() {
        _latestAppFeedbackResult = result;
        _feedbackNoteCtrl.clear();
        _feedbackMediaFile = null;
        _feedbackMediaIsVideo = false;
      });
      await NotificationService.showGeneralNotification(
        id: 'app_feedback_submitted_${DateTime.now().microsecondsSinceEpoch}',
        title: 'تم إرسال الملاحظة',
        body: 'تم إرسال الملاحظة، شكرًا لتعاونكم',
        senderName: 'Respect',
        showSystemNotification: false,
      );
    } catch (e) {
      if (!mounted) return;
      _showSettingsError('تعذر إرسال الملاحظة: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _sendingAppFeedback = false);
    }
  }

  Widget _buildAppFeedbackCard() {
    final result = _latestAppFeedbackResult;
    final status = (result?['status'] ?? '').toString();
    final reportId = (result?['id'] ?? result?['reportId'] ?? '').toString();

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
              subtitle: AppText('اكتب المشكلة أو أرفق صورة/فيديو وسيتم إرسالها مباشرة للإدارة بدون ذكاء اصطناعي'),
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
            _buildAppFeedbackMediaPicker(),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _sendingAppFeedback ? null : _submitAppFeedbackReport,
              icon: _sendingAppFeedback
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
              label: AppText(_sendingAppFeedback ? 'جاري الإرسال...' : 'إرسال للإدارة'),
            ),
            if (result != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.success.withValues(alpha: 0.22)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AppText('تم حفظ الملاحظة وإرسالها للإدارة.', style: TextStyle(fontWeight: FontWeight.w900)),
                    if (reportId.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      AppText('رقم البلاغ: $reportId', textDirection: TextDirection.ltr),
                    ],
                    if (status.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      AppText('الحالة: ${_appFeedbackStatusText(status)}'),
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

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final languageProvider = context.watch<AppLanguageProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: null,
      body: RefreshIndicator(
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

                  _buildAppFeedbackCard().animate().fadeIn(delay: 220.ms),

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
    );
  }
}
