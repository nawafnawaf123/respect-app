// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, use_build_context_synchronously, unnecessary_this, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures, prefer_final_fields, unnecessary_type_check, unnecessary_non_null_assertion
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/supabase_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/primary_button.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();
  final TextEditingController _confirmPasswordCtrl = TextEditingController();
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _birthDateCtrl = TextEditingController();
  final TextEditingController _signupPhoneCountryCtrl = TextEditingController(text: '+961');
  final TextEditingController _signupPhoneCtrl = TextEditingController();

  StreamSubscription<AuthState>? _authSub;

  bool _isCreateMode = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _acceptedTerms = false;
  bool _loading = false;
  bool _navigated = false;
  bool _googleLoginInProgress = false;
  bool _handlingAuthState = false;
  bool _manualAuthFlowInProgress = false;
  bool _rememberDevice = true;
  bool _resettingPassword = false;
  bool _smsCodeRequested = false;

  @override
  void initState() {
    super.initState();

    // احتياط فقط لو رجعت جلسة Google من Supabase بدون ضغط الزر.
    // أثناء ضغط زر Google نفسه لا نشغل sync مرتين، لأن _loginWithGoogle يعالج الدخول مباشرة.
    _authSub = SupabaseService.client.auth.onAuthStateChange.listen((state) async {
      if (!mounted) return;
      if (_googleLoginInProgress || _handlingAuthState || _manualAuthFlowInProgress || _navigated) return;
      if (state.event != AuthChangeEvent.signedIn || state.session == null) return;

      _handlingAuthState = true;
      setState(() => _loading = true);
      try {
        final user = await SupabaseService.syncGoogleSessionUser();
        if (user == null) {
          _showMessage('تعذر تسجيل الدخول بجوجل أو الحساب محظور');
          return;
        }
        _goHome();
      } catch (e) {
        _showMessage(e.toString().replaceFirst('Exception: ', ''));
      } finally {
        _handlingAuthState = false;
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    _nameCtrl.dispose();
    _birthDateCtrl.dispose();
    _signupPhoneCountryCtrl.dispose();
    _signupPhoneCtrl.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    NotificationService.showTopNotification(message);
  }

  Future<void> _pickBirthDate() async {
    FocusScope.of(context).unfocus();
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: now,
      helpText: 'اختر تاريخ الميلاد',
      cancelText: 'إلغاء',
      confirmText: 'اختيار',
    );
    if (picked == null) return;
    _birthDateCtrl.text =
    '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
  }

  Future<void> _submit() async {
    final loginInput = _usernameCtrl.text.trim();
    final username = SupabaseService.strictUsername(_usernameCtrl.text);
    final email = SupabaseService.normalizeEmail(_emailCtrl.text);
    final password = _passwordCtrl.text.trim();
    final confirmPassword = _confirmPasswordCtrl.text.trim();
    final fullName = SupabaseService.cleanProfileName(_nameCtrl.text);
    final birthDate = _birthDateCtrl.text.trim();
    final signupPhoneCountry = _signupPhoneCountryCtrl.text.trim();
    final signupPhone = _signupPhoneCtrl.text.trim();

    if (_isCreateMode) {
      final usernameError = SupabaseService.usernameRuleError(_usernameCtrl.text);
      if (usernameError != null) {
        _showMessage(usernameError);
        return;
      }
      if (fullName.isEmpty) {
        _showMessage('اكتب اسم البروفايل');
        return;
      }
      if (!SupabaseService.isValidEmail(email)) {
        _showMessage('اكتب إيميل صحيح');
        return;
      }
      if (birthDate.isEmpty) {
        _showMessage('اختر تاريخ الميلاد');
        return;
      }
      if (password.length < 6) {
        _showMessage('كلمة المرور لازم تكون 6 أحرف على الأقل');
        return;
      }
      if (password != confirmPassword) {
        _showMessage('كلمتا المرور غير متطابقتان');
        return;
      }
      if (!_acceptedTerms) {
        _showMessage('يجب الموافقة على سياسة الخصوصية وقوانين الاستخدام');
        return;
      }
    } else {
      if (loginInput.isEmpty || password.isEmpty) {
        _showMessage('اكتب اسم المستخدم/الإيميل وكلمة المرور');
        return;
      }
      if (password.length < 4) {
        _showMessage('كلمة المرور لازم تكون 4 أحرف على الأقل');
        return;
      }
    }

    FocusScope.of(context).unfocus();
    _manualAuthFlowInProgress = true;
    setState(() => _loading = true);

    try {
      if (_isCreateMode) {
        await SupabaseService.validateNewAccountFields(
          username: username,
          email: email,
          profileName: fullName,
        );

        await SupabaseService.requestAuthOtp(
          email: email,
          username: username,
          purpose: 'signup',
        );

        if (!mounted) return;
        setState(() => _loading = false);
        final otp = await _showOtpSheet(
          email: email,
          title: 'تأكيد إنشاء الحساب',
          subtitle: 'أرسلنا رمز تحقق مكون من 6 أرقام إلى بريدك. أدخله لإكمال إنشاء الحساب.',
          allowRememberDevice: true,
        );
        if (otp == null) return;

        setState(() => _loading = true);
        await SupabaseService.verifyAuthOtp(
          email: email,
          code: otp,
          username: username,
          purpose: 'signup',
        );

        await SupabaseService.register(
          username: username,
          email: email,
          password: password,
          name: fullName,
          birthDate: birthDate,
          acceptedTerms: _acceptedTerms,
        );

        if (_rememberDevice) {
          await SupabaseService.trustCurrentDeviceForUsername(username);
        }

        if (signupPhone.trim().isNotEmpty) {
          final phoneE164 = SupabaseService.normalizePhoneE164(
            countryCode: signupPhoneCountry,
            phone: signupPhone,
          );
          if (phoneE164.isNotEmpty) {
            await SupabaseService.requestPhoneSecurityCode(
              username: username,
              countryCode: signupPhoneCountry,
              phone: signupPhone,
            );
            if (!mounted) return;
            setState(() => _loading = false);
            final smsCode = await _showPhoneCodeSheet(
              phoneE164: phoneE164,
              title: 'تأكيد رقم الجوال',
              subtitle: 'أرسلنا رمز SMS إلى رقمك. أدخله لتفعيل الأمان عبر الرقم.',
              onResend: () => SupabaseService.requestPhoneSecurityCode(
                username: username,
                countryCode: signupPhoneCountry,
                phone: signupPhone,
              ),
            );
            if (smsCode != null) {
              setState(() => _loading = true);
              await SupabaseService.verifyPhoneSecurityCode(
                username: username,
                phoneE164: phoneE164,
                code: smsCode,
              );
              _showMessage('تم إنشاء الحساب وتفعيل الأمان عبر الرقم بنجاح');
            } else {
              _showMessage('تم إنشاء الحساب. يمكنك تفعيل رقم الجوال لاحقًا من الإعدادات');
            }
          }
        } else {
          _showMessage('تم إنشاء الحساب وتأكيد البريد بنجاح');
        }
      } else {
        if (_smsCodeRequested && RegExp(r'^\d{4,10}$').hasMatch(password)) {
          final user = await SupabaseService.loginWithSmsCode(loginInput, password);
          if (user == null) {
            _showMessage('رمز SMS غير صحيح أو الحساب لم يفعل الأمان عبر الرقم');
            return;
          }
          await SupabaseService.reportLoginAttempt(usernameOrEmail: loginInput, success: true);
          if (_rememberDevice) {
            await SupabaseService.trustCurrentDeviceForUsername((user['username'] ?? loginInput).toString());
          }
          _showMessage('تم تسجيل الدخول عبر رمز SMS');
          _goHome();
          return;
        }

        final allowed = await SupabaseService.checkLoginAttemptAllowed(loginInput);
        if (allowed['allowed'] == false) {
          final message = (allowed['message'] ?? 'تم إيقاف تسجيل الدخول مؤقتًا بعد 6 محاولات فاشلة. استخدم نسيت كلمة المرور أو حاول لاحقًا.').toString();
          _showMessage(message);
          return;
        }

        Map<String, dynamic>? candidate;
        try {
          candidate = await SupabaseService.verifyLoginPasswordOnly(loginInput, password);
        } catch (e) {
          final status = await SupabaseService.reportLoginAttempt(usernameOrEmail: loginInput, success: false);
          final remaining = int.tryParse((status['remainingAttempts'] ?? 0).toString()) ?? 0;
          if (status['allowed'] == false) {
            _showMessage('تم إيقاف تسجيل الدخول مؤقتًا بعد 6 محاولات فاشلة. اضغط نسيت كلمة المرور لاستعادة الحساب.');
          } else {
            _showMessage('كلمة المرور غير صحيحة. المتبقي $remaining محاولات.');
          }
          return;
        }

        if (candidate == null) {
          final status = await SupabaseService.reportLoginAttempt(usernameOrEmail: loginInput, success: false);
          final remaining = int.tryParse((status['remainingAttempts'] ?? 0).toString()) ?? 0;
          if (status['allowed'] == false) {
            _showMessage('تم إيقاف تسجيل الدخول مؤقتًا بعد 6 محاولات فاشلة. اضغط نسيت كلمة المرور لاستعادة الحساب.');
          } else {
            _showMessage('اسم المستخدم/الإيميل أو كلمة المرور غير صحيحة. المتبقي $remaining محاولات.');
          }
          return;
        }

        final candidateUsername = (candidate['username'] ?? loginInput).toString();
        final candidateEmail = SupabaseService.normalizeEmail((candidate['email'] ?? '').toString());
        if (candidateEmail.isEmpty) {
          _showMessage('هذا الحساب لا يحتوي على إيميل صالح للتحقق');
          return;
        }

        final trusted = await SupabaseService.isTrustedDeviceForUsername(candidateUsername);
        if (!trusted) {
          await SupabaseService.requestAuthOtp(
            email: candidateEmail,
            username: candidateUsername,
            purpose: 'login',
          );

          if (!mounted) return;
          setState(() => _loading = false);
          final otp = await _showOtpSheet(
            email: candidateEmail,
            title: 'تأكيد تسجيل الدخول',
            subtitle: 'هذا الجهاز غير موثوق بعد. أدخل رمز التحقق المرسل إلى بريدك للمتابعة.',
            allowRememberDevice: true,
          );
          if (otp == null) return;

          setState(() => _loading = true);
          await SupabaseService.verifyAuthOtp(
            email: candidateEmail,
            code: otp,
            username: candidateUsername,
            purpose: 'login',
          );
        }

        final user = await SupabaseService.login(loginInput, password);
        if (user == null) {
          await SupabaseService.reportLoginAttempt(usernameOrEmail: loginInput, success: false);
          _showMessage('اسم المستخدم/الإيميل أو كلمة المرور غير صحيحة أو الحساب محظور');
          return;
        }

        await SupabaseService.reportLoginAttempt(usernameOrEmail: loginInput, success: true);

        if (_rememberDevice && !trusted) {
          await SupabaseService.trustCurrentDeviceForUsername((user['username'] ?? candidateUsername).toString());
        }
      }

      _goHome();
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      _showMessage(msg);
    } finally {
      _manualAuthFlowInProgress = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loginWithGoogle() async {
    if (_loading || _googleLoginInProgress) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _googleLoginInProgress = true;
    });

    try {
      final user = await SupabaseService.signInWithGoogle();
      if (user == null) {
        _showMessage('تم إلغاء تسجيل الدخول بجوجل');
        return;
      }
      _goHome();
    } catch (e) {
      _showMessage(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      _googleLoginInProgress = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _requestPasswordReset() async {
    if (_loading || _resettingPassword || _isCreateMode) return;
    final input = _usernameCtrl.text.trim();
    if (input.isEmpty) {
      _showMessage('اكتب اسم المستخدم أو الإيميل أولاً ثم اضغط نسيت كلمة المرور');
      return;
    }
    FocusScope.of(context).unfocus();

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard : AppColors.lightCard,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 44, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .45), borderRadius: BorderRadius.circular(99))),
                const SizedBox(height: 14),
                const Text('استعادة الحساب', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text('اختر طريقة الاستعادة المناسبة لحسابك', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                ListTile(
                  leading: const CircleAvatar(backgroundColor: AppColors.purple, foregroundColor: Colors.white, child: Icon(Icons.email_rounded)),
                  title: const Text('رابط عبر البريد الإلكتروني', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: const Text('يصلك رابط تغيير كلمة المرور'),
                  onTap: () => Navigator.pop(context, 'email'),
                ),
                ListTile(
                  leading: const CircleAvatar(backgroundColor: AppColors.purple, foregroundColor: Colors.white, child: Icon(Icons.sms_rounded)),
                  title: const Text('رمز SMS عبر رقم الجوال', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: const Text('إذا كنت مفعّل الأمان عبر الرقم من الإعدادات'),
                  onTap: () => Navigator.pop(context, 'sms'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (action == null) return;

    setState(() => _resettingPassword = true);
    try {
      if (action == 'sms') {
        await SupabaseService.requestSmsLoginCode(input);
        if (!mounted) return;
        setState(() {
          _smsCodeRequested = true;
          _obscurePassword = false;
          _passwordCtrl.clear();
        });
        _showMessage('إذا كان الرقم مفعّلًا، وصل رمز SMS. اكتب الرمز في خانة كلمة المرور ثم اضغط تسجيل الدخول.');
      } else {
        await SupabaseService.requestPasswordReset(input);
        _showMessage('إذا كان الحساب موجودًا، وصل رابط إعادة تعيين كلمة المرور إلى البريد المرتبط به.');
      }
    } catch (e) {
      _showMessage(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _resettingPassword = false);
    }
  }

  void _goHome() {
    if (!mounted || _navigated) return;
    _navigated = true;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  void _toggleMode() {
    setState(() {
      _isCreateMode = !_isCreateMode;
      _passwordCtrl.clear();
      _confirmPasswordCtrl.clear();
      _smsCodeRequested = false;
      if (!_isCreateMode) {
        _nameCtrl.clear();
        _emailCtrl.clear();
        _birthDateCtrl.clear();
        _signupPhoneCtrl.clear();
        _acceptedTerms = false;
      }
    });
  }

  TextInputFormatter get _lowerUsernameFormatter => TextInputFormatter.withFunction((oldValue, newValue) {
    final lower = newValue.text.toLowerCase();
    return newValue.copyWith(text: lower, selection: TextSelection.collapsed(offset: lower.length));
  });

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    bool obscure = false,
    Widget? suffixIcon,
    VoidCallback? onTap,
    bool readOnly = false,
    ValueChanged<String>? onSubmitted,
    List<TextInputFormatter>? inputFormatters,
    String? helperText,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, bottom: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w900,
              color: isDark ? Colors.white.withValues(alpha: 0.86) : Colors.black.withValues(alpha: 0.75),
            ),
          ),
        ),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscure,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          onTap: onTap,
          readOnly: readOnly,
          inputFormatters: inputFormatters,
          decoration: InputDecoration(
            prefixIcon: Icon(icon),
            hintText: hint,
            helperText: helperText,
            helperMaxLines: 2,
            suffixIcon: suffixIcon,
            filled: true,
            fillColor: isDark ? Colors.white.withValues(alpha: 0.055) : Colors.white.withValues(alpha: 0.78),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: const BorderSide(color: AppColors.purple, width: 1.6),
            ),
          ),
        ),
      ],
    );
  }


  Future<String?> _showOtpSheet({
    required String email,
    required String title,
    required String subtitle,
    bool allowRememberDevice = true,
  }) async {
    final result = await Navigator.of(context).push<_OtpResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _OtpVerificationPage(
          email: email,
          title: title,
          subtitle: subtitle,
          allowRememberDevice: allowRememberDevice,
          initialRememberDevice: _rememberDevice,
          onResend: () async {
            await SupabaseService.requestAuthOtp(
              email: email,
              username: _isCreateMode
                  ? SupabaseService.strictUsername(_usernameCtrl.text)
                  : _usernameCtrl.text.trim(),
              purpose: _isCreateMode ? 'signup' : 'login',
            );
          },
        ),
      ),
    );

    if (result == null) return null;
    if (mounted) setState(() => _rememberDevice = result.rememberDevice);
    return result.code;
  }

  Future<String?> _showPhoneCodeSheet({
    required String phoneE164,
    required String title,
    required String subtitle,
    required Future<void> Function() onResend,
  }) async {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PhoneCodeVerificationPage(
          phoneE164: phoneE164,
          title: title,
          subtitle: subtitle,
          onResend: onResend,
        ),
      ),
    );
  }

  Future<void> _showPoliciesSheet({int initialIndex = 0}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return DraggableScrollableSheet(
          initialChildSize: 0.82,
          minChildSize: 0.55,
          maxChildSize: 0.94,
          builder: (context, controller) {
            return Container(
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBg : AppColors.lightBg,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
              ),
              child: DefaultTabController(
                length: 3,
                initialIndex: initialIndex,
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(width: 46, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(99))),
                    const SizedBox(height: 14),
                    const Text('سياسات Respect App', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 12),
                    TabBar(
                      labelColor: AppColors.purple,
                      unselectedLabelColor: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                      indicatorColor: AppColors.purple,
                      tabs: const [
                        Tab(text: 'الخصوصية'),
                        Tab(text: 'القوانين'),
                        Tab(text: 'الاستخدام'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _policyText(controller, _privacyPolicy),
                          _policyText(controller, _communityRules),
                          _policyText(controller, _termsOfUse),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _policyText(ScrollController controller, String text) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        Text(
          text,
          style: TextStyle(
            height: 1.65,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white.withValues(alpha: 0.88) : Colors.black.withValues(alpha: 0.78),
          ),
        ),
      ],
    );
  }

  Widget _brandHeader(bool isDark) {
    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: _isCreateMode ? 94 : 112,
              height: _isCreateMode ? 94 : 112,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    AppColors.purple.withValues(alpha: 0.15),
                    AppColors.purpleLight,
                    AppColors.purple,
                    AppColors.purple.withValues(alpha: 0.15),
                  ],
                ),
                boxShadow: [
                  BoxShadow(color: AppColors.purple.withValues(alpha: 0.35), blurRadius: 36, spreadRadius: 3),
                ],
              ),
            ),
            Container(
              width: _isCreateMode ? 74 : 88,
              height: _isCreateMode ? 74 : 88,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDark ? Colors.black.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.9),
                border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
              ),
              child: Image.asset(
                'assets/logo.png',
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Icon(Icons.hub_rounded, color: AppColors.purple, size: 46),
              ),
            ),
          ],
        ).animate().scale(duration: 360.ms, curve: Curves.easeOutBack),
        const SizedBox(height: 14),
        Text(
          _isCreateMode ? 'انضم إلى Respect' : 'أهلًا برجعتك',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: _isCreateMode ? 26 : 30,
            fontWeight: FontWeight.w900,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ).animate().fadeIn(duration: 360.ms).slideY(begin: 0.18, end: 0),
        const SizedBox(height: 7),
        Text(
          _isCreateMode
              ? 'حسابك يبدأ باسم مستخدم فريد واسم بروفايل لا يشبه أحد'
              : 'سجّل دخولك باسم المستخدم أو الإيميل',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
          ),
        ),
      ],
    );
  }

  Widget _modeSwitch(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.045),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      child: Row(
        children: [
          Expanded(child: _modeButton('دخول', !_isCreateMode, () => _isCreateMode ? _toggleMode() : null)),
          Expanded(child: _modeButton('حساب جديد', _isCreateMode, () => !_isCreateMode ? _toggleMode() : null)),
        ],
      ),
    );
  }

  Widget _modeButton(String text, bool active, VoidCallback? onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: active ? const LinearGradient(colors: [AppColors.purple, AppColors.purpleLight]) : null,
          boxShadow: active ? [BoxShadow(color: AppColors.purple.withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 8))] : null,
        ),
        alignment: Alignment.center,
        child: Text(
          text,
          style: TextStyle(
            color: active ? Colors.white : null,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _rulesHint(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AppColors.purple.withValues(alpha: isDark ? 0.13 : 0.08),
        border: Border.all(color: AppColors.purple.withValues(alpha: 0.22)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_user_rounded, color: AppColors.purple, size: 21),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'اسم المستخدم: أحرف إنجليزية صغيرة + أرقام + _ فقط. ممنوع العربي، الكابيتال، المسافات، النقاط، الشرطات، + و -.',
              style: TextStyle(fontSize: 12.2, fontWeight: FontWeight.w800, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _termsCheckbox() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
        color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.white.withValues(alpha: 0.55),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Checkbox(
            value: _acceptedTerms,
            onChanged: (v) => setState(() => _acceptedTerms = v ?? false),
            activeColor: AppColors.purple,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.start,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('أوافق على ', style: TextStyle(fontWeight: FontWeight.w800)),
                _policyLink('سياسة الخصوصية', 0),
                const Text(' و', style: TextStyle(fontWeight: FontWeight.w800)),
                _policyLink('القوانين', 1),
                const Text(' و', style: TextStyle(fontWeight: FontWeight.w800)),
                _policyLink('سياسة الاستخدام', 2),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _policyLink(String text, int index) {
    return InkWell(
      onTap: () => _showPoliciesSheet(initialIndex: index),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          text,
          style: const TextStyle(
            color: AppColors.purple,
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }

  Widget _authCard(bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(16, _isCreateMode ? 16 : 20, 16, 18),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.065) : Colors.white.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.09) : Colors.white.withValues(alpha: 0.75)),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.08), blurRadius: 28, offset: const Offset(0, 18)),
          ],
        ),
        child: Column(
          children: [
            _modeSwitch(isDark),
            const SizedBox(height: 16),
            if (_isCreateMode) ...[
              _field(
                controller: _nameCtrl,
                textInputAction: TextInputAction.next,
                icon: Icons.badge_rounded,
                label: 'اسم البروفايل',
                hint: 'مثال: Nawaf RP',
                helperText: 'لا يمكن أن يتكرر مع أي حساب آخر.',
              ).animate().fadeIn(duration: 240.ms).slideX(begin: -0.08),
              const SizedBox(height: 12),
              _field(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                icon: Icons.email_rounded,
                label: 'الإيميل',
                hint: 'name@email.com',
                helperText: 'ممنوع إنشاء أكثر من حساب بنفس الإيميل.',
              ).animate().fadeIn(delay: 40.ms, duration: 240.ms).slideX(begin: -0.08),
              const SizedBox(height: 12),
              _field(
                controller: _birthDateCtrl,
                icon: Icons.cake_rounded,
                label: 'تاريخ الميلاد',
                hint: 'YYYY-MM-DD',
                readOnly: true,
                onTap: _pickBirthDate,
                suffixIcon: IconButton(
                  onPressed: _pickBirthDate,
                  icon: const Icon(Icons.calendar_month_rounded),
                ),
              ).animate().fadeIn(delay: 80.ms, duration: 240.ms).slideX(begin: -0.08),
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 105,
                    child: _field(
                      controller: _signupPhoneCountryCtrl,
                      keyboardType: TextInputType.phone,
                      icon: Icons.flag_rounded,
                      label: 'الدولة',
                      hint: '+961',
                      helperText: 'اختياري',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _field(
                      controller: _signupPhoneCtrl,
                      keyboardType: TextInputType.phone,
                      icon: Icons.phone_iphone_rounded,
                      label: 'رقم الجوال للأمان',
                      hint: '70123456',
                      helperText: 'اختياري ويمكن تفعيله لاحقًا من الإعدادات.',
                    ),
                  ),
                ],
              ).animate().fadeIn(delay: 100.ms, duration: 240.ms).slideX(begin: -0.08),
              const SizedBox(height: 12),
            ],
            _field(
              controller: _usernameCtrl,
              textInputAction: TextInputAction.next,
              icon: Icons.alternate_email_rounded,
              label: _isCreateMode ? 'اسم المستخدم' : 'اسم المستخدم أو الإيميل',
              hint: _isCreateMode ? 'nawaf_rp' : 'nawaf_rp أو email@example.com',
              inputFormatters: _isCreateMode
                  ? [
                _lowerUsernameFormatter,
                FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_]')),
              ]
                  : null,
              helperText: _isCreateMode ? 'فريد ولا يقبل الحروف العربية أو الكابيتال أو الرموز.' : null,
            ).animate().fadeIn(delay: 120.ms, duration: 240.ms).slideX(begin: -0.08),
            const SizedBox(height: 12),
            _field(
              controller: _passwordCtrl,
              obscure: _obscurePassword,
              textInputAction: _isCreateMode ? TextInputAction.next : TextInputAction.done,
              onSubmitted: (_) => _isCreateMode ? null : _submit(),
              icon: Icons.lock_rounded,
              label: _smsCodeRequested && !_isCreateMode ? 'رمز SMS' : 'كلمة المرور',
              hint: _isCreateMode ? '6 أحرف على الأقل' : (_smsCodeRequested ? 'اكتب رمز SMS المكون من 6 أرقام' : 'كلمة المرور'),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                icon: Icon(_obscurePassword ? Icons.visibility_rounded : Icons.visibility_off_rounded),
              ),
            ).animate().fadeIn(delay: 160.ms, duration: 240.ms).slideX(begin: 0.08),
            if (_isCreateMode) ...[
              const SizedBox(height: 12),
              _field(
                controller: _confirmPasswordCtrl,
                obscure: _obscureConfirmPassword,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                icon: Icons.lock_reset_rounded,
                label: 'تأكيد كلمة المرور',
                hint: 'أعد كتابة كلمة المرور',
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                  icon: Icon(_obscureConfirmPassword ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                ),
              ).animate().fadeIn(delay: 200.ms, duration: 240.ms).slideX(begin: 0.08),
              const SizedBox(height: 12),
              _rulesHint(isDark).animate().fadeIn(delay: 240.ms),
              const SizedBox(height: 10),
              _termsCheckbox().animate().fadeIn(delay: 270.ms),
            ],
            const SizedBox(height: 18),
            PrimaryButton(
              text: _loading ? 'جاري المعالجة...' : (_isCreateMode ? 'إنشاء الحساب' : (_smsCodeRequested ? 'تسجيل الدخول برمز SMS' : 'تسجيل الدخول')), 
              icon: _isCreateMode ? Icons.person_add_alt_1_rounded : Icons.login_rounded,
              onPressed: _loading ? () {} : _submit,
            ).animate().fadeIn(delay: 300.ms),
            if (!_isCreateMode) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  onPressed: (_loading || _resettingPassword) ? null : _requestPasswordReset,
                  icon: _resettingPassword
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.lock_reset_rounded, size: 19),
                  label: Text(
                    _resettingPassword ? 'جاري إرسال الرابط...' : 'نسيت كلمة المرور؟',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            SizedBox(
              height: 52,
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _loading ? null : _loginWithGoogle,
                icon: const Icon(Icons.g_mobiledata_rounded, size: 34),
                label: const Text('المتابعة باستخدام Google', style: TextStyle(fontWeight: FontWeight.w900)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: isDark ? Colors.white : Colors.black87,
                  side: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                ),
              ),
            ).animate().fadeIn(delay: 340.ms),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppColors.darkBg : AppColors.lightBg;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: bg,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? [const Color(0xFF090511), const Color(0xFF130B22), const Color(0xFF05030A)]
                      : [const Color(0xFFF7F2FF), const Color(0xFFFFFFFF), const Color(0xFFF0E8FF)],
                ),
              ),
            ),
          ),
          Positioned(top: -90, right: -70, child: _glowCircle(220, AppColors.purple.withValues(alpha: isDark ? 0.32 : 0.18))),
          Positioned(bottom: -110, left: -80, child: _glowCircle(250, AppColors.purpleLight.withValues(alpha: isDark ? 0.25 : 0.15))),
          Positioned(top: 150, left: -40, child: Transform.rotate(angle: -math.pi / 8, child: _glassPill(isDark))),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.only(
                    left: 20,
                    right: 20,
                    top: _isCreateMode ? 10 : 22,
                    bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight - 40),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _brandHeader(isDark),
                        SizedBox(height: _isCreateMode ? 18 : 26),
                        _authCard(isDark),
                        const SizedBox(height: 14),
                        TextButton.icon(
                          onPressed: () => _showPoliciesSheet(),
                          icon: const Icon(Icons.policy_rounded, size: 18),
                          label: const Text('عرض سياسة الخصوصية وقوانين البرنامج', style: TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _glowCircle(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [BoxShadow(color: color, blurRadius: 70, spreadRadius: 16)],
      ),
    );
  }

  Widget _glassPill(bool isDark) {
    return Container(
      width: 150,
      height: 46,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.white.withValues(alpha: 0.42),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
    );
  }
}


class _OtpResult {
  final String code;
  final bool rememberDevice;

  const _OtpResult({
    required this.code,
    required this.rememberDevice,
  });
}

class _OtpVerificationPage extends StatefulWidget {
  final String email;
  final String title;
  final String subtitle;
  final bool allowRememberDevice;
  final bool initialRememberDevice;
  final Future<void> Function() onResend;

  const _OtpVerificationPage({
    required this.email,
    required this.title,
    required this.subtitle,
    required this.allowRememberDevice,
    required this.initialRememberDevice,
    required this.onResend,
  });

  @override
  State<_OtpVerificationPage> createState() => _OtpVerificationPageState();
}

class _OtpVerificationPageState extends State<_OtpVerificationPage> {
  String _code = '';
  late bool _rememberDevice;
  bool _submitting = false;
  bool _resending = false;

  @override
  void initState() {
    super.initState();
    _rememberDevice = widget.initialRememberDevice;
  }

  void _showMessage(String message, {bool success = false, bool error = false}) {
    final clean = message.trim();
    if (clean.isEmpty) return;
    if (error) {
      NotificationService.showTopError(clean);
    } else if (success) {
      NotificationService.showTopSuccess(clean);
    } else {
      NotificationService.showTopNotification(clean);
    }
  }

  void _confirm() {
    final clean = _code.trim();
    if (clean.length != 6) {
      _showMessage('اكتب رمز التحقق المكون من 6 أرقام', error: true);
      return;
    }
    if (_submitting) return;
    setState(() => _submitting = true);
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(_OtpResult(code: clean, rememberDevice: _rememberDevice));
  }

  Future<void> _resend() async {
    if (_resending || _submitting) return;
    setState(() => _resending = true);
    try {
      await widget.onResend();
      _showMessage('تم إرسال رمز جديد إلى بريدك', success: true);
    } catch (e) {
      _showMessage(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppColors.darkBg : AppColors.lightBg;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    return PopScope(
      canPop: !_submitting,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: bg,
        appBar: AppBar(
          title: const Text('رمز التحقق', style: TextStyle(fontWeight: FontWeight.w900)),
          centerTitle: true,
          leading: IconButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(null),
            icon: const Icon(Icons.close_rounded),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(20, 18, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
            child: Column(
              children: [
                Container(
                  width: 82,
                  height: 82,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(colors: [AppColors.purple, AppColors.purpleLight]),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.purple.withValues(alpha: .32),
                        blurRadius: 30,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.mark_email_read_rounded, color: Colors.white, size: 40),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 9),
                Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted, height: 1.5, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: AppColors.purple.withValues(alpha: .09),
                    border: Border.all(color: AppColors.purple.withValues(alpha: .18)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.email_rounded, color: AppColors.purple, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  enabled: !_submitting,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  textAlign: TextAlign.center,
                  maxLength: 6,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 8,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  onChanged: (value) {
                    _code = value.trim();
                    if (_code.length == 6) FocusScope.of(context).unfocus();
                  },
                  onSubmitted: (_) => _confirm(),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '000000',
                    prefixIcon: const Icon(Icons.pin_rounded),
                    filled: true,
                    fillColor: isDark ? Colors.white.withValues(alpha: .055) : Colors.white.withValues(alpha: .78),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: const BorderSide(color: AppColors.purple, width: 1.7),
                    ),
                  ),
                ),
                if (widget.allowRememberDevice) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: isDark ? Colors.white.withValues(alpha: .04) : Colors.white.withValues(alpha: .55),
                      border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                    ),
                    child: CheckboxListTile(
                      value: _rememberDevice,
                      onChanged: _submitting
                          ? null
                          : (value) => setState(() => _rememberDevice = value ?? true),
                      activeColor: AppColors.purple,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('تذكر هذا الجهاز', style: TextStyle(fontWeight: FontWeight.w900)),
                      subtitle: Text(
                        'لن نطلب رمز تحقق مرة أخرى على هذا الجهاز لمدة 90 يوم تقريبًا.',
                        style: TextStyle(color: muted, fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                PrimaryButton(
                  text: _submitting ? 'جاري التحقق...' : 'تأكيد الرمز',
                  icon: Icons.verified_rounded,
                  onPressed: _submitting ? () {} : _confirm,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _submitting ? null : () => Navigator.of(context).pop(null),
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('إلغاء', style: TextStyle(fontWeight: FontWeight.w900)),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextButton.icon(
                        onPressed: (_submitting || _resending) ? null : _resend,
                        icon: _resending
                            ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                            : const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(
                          _resending ? 'جاري الإرسال...' : 'إعادة الإرسال',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}



class _PhoneCodeVerificationPage extends StatefulWidget {
  final String phoneE164;
  final String title;
  final String subtitle;
  final Future<void> Function() onResend;

  const _PhoneCodeVerificationPage({
    required this.phoneE164,
    required this.title,
    required this.subtitle,
    required this.onResend,
  });

  @override
  State<_PhoneCodeVerificationPage> createState() => _PhoneCodeVerificationPageState();
}

class _PhoneCodeVerificationPageState extends State<_PhoneCodeVerificationPage> {
  String _code = '';
  bool _submitting = false;
  bool _resending = false;

  void _showMessage(String message, {bool success = false, bool error = false}) {
    final clean = message.trim();
    if (clean.isEmpty) return;
    if (error) {
      NotificationService.showTopError(clean);
    } else if (success) {
      NotificationService.showTopSuccess(clean);
    } else {
      NotificationService.showTopNotification(clean);
    }
  }

  void _confirm() {
    final clean = _code.trim();
    if (clean.length < 4 || clean.length > 10) {
      _showMessage('اكتب رمز SMS الصحيح', error: true);
      return;
    }
    if (_submitting) return;
    setState(() => _submitting = true);
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(clean);
  }

  Future<void> _resend() async {
    if (_resending || _submitting) return;
    setState(() => _resending = true);
    try {
      await widget.onResend();
      _showMessage('تم إرسال رمز SMS جديد', success: true);
    } catch (e) {
      _showMessage(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppColors.darkBg : AppColors.lightBg;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    return PopScope(
      canPop: !_submitting,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: bg,
        appBar: AppBar(
          title: const Text('تأكيد رقم الجوال', style: TextStyle(fontWeight: FontWeight.w900)),
          centerTitle: true,
          leading: IconButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(null),
            icon: const Icon(Icons.close_rounded),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(20, 18, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
            child: Column(
              children: [
                Container(
                  width: 82,
                  height: 82,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(colors: [AppColors.purple, AppColors.purpleLight]),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.purple.withValues(alpha: .32),
                        blurRadius: 30,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.sms_rounded, color: Colors.white, size: 40),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 9),
                Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted, height: 1.5, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: AppColors.purple.withValues(alpha: .09),
                    border: Border.all(color: AppColors.purple.withValues(alpha: .18)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.phone_iphone_rounded, color: AppColors.purple, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.phoneE164,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  enabled: !_submitting,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  textAlign: TextAlign.center,
                  maxLength: 10,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 6,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(10),
                  ],
                  onChanged: (value) {
                    _code = value.trim();
                    if (_code.length >= 6) FocusScope.of(context).unfocus();
                  },
                  onSubmitted: (_) => _confirm(),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '000000',
                    prefixIcon: const Icon(Icons.pin_rounded),
                    filled: true,
                    fillColor: isDark ? Colors.white.withValues(alpha: .055) : Colors.white.withValues(alpha: .78),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: const BorderSide(color: AppColors.purple, width: 1.7),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                PrimaryButton(
                  text: _submitting ? 'جاري التحقق...' : 'تأكيد الرمز',
                  icon: Icons.verified_rounded,
                  onPressed: _submitting ? () {} : _confirm,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _submitting ? null : () => Navigator.of(context).pop(null),
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('إلغاء', style: TextStyle(fontWeight: FontWeight.w900)),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextButton.icon(
                        onPressed: (_submitting || _resending) ? null : _resend,
                        icon: _resending
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(
                          _resending ? 'جاري الإرسال...' : 'إعادة الإرسال',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const String _privacyPolicy = '''
خصوصية المستخدمين داخل Respect App مهمة جدًا. نقوم بحفظ بيانات الحساب الأساسية مثل اسم المستخدم، اسم البروفايل، الإيميل، تاريخ الميلاد، الصورة، والغلاف حتى تعمل ميزات التطبيق بشكل صحيح.

لا نبيع بيانات المستخدمين. تستخدم البيانات فقط لتسجيل الدخول، عرض الحساب، التفاعل، الإشعارات، الحماية من الحسابات المكررة، ومنع إساءة الاستخدام.

الإيميل لا يظهر للعامة، واسم المستخدم واسم البروفايل والصورة والمحتوى المنشور قد يظهرون لباقي المستخدمين حسب طبيعة التطبيق.

قد يتم تخزين بيانات التفاعل مثل اللايكات، التعليقات، الستوري، الرسائل، المشاهدات، والإشعارات لتحسين تجربة المستخدم وإظهار النشاط داخل التطبيق.
''';

const String _communityRules = '''
قوانين Respect App:

1. ممنوع انتحال شخصية شخص آخر أو استخدام اسم بروفايل يسبب التباسًا مع مستخدم موجود.
2. ممنوع السب، التهديد، التحريض، الابتزاز، أو نشر محتوى مؤذٍ.
3. ممنوع نشر محتوى مخالف أو غير قانوني أو ينتهك خصوصية الآخرين.
4. ممنوع استخدام التطبيق للإزعاج أو الرسائل العشوائية أو الحسابات الوهمية.
5. اسم المستخدم يجب أن يكون فريدًا ويتكون من أحرف إنجليزية صغيرة وأرقام وشرطة سفلية فقط.
6. اسم البروفايل يجب أن يكون فريدًا وغير مستخدم من حساب آخر.
7. يحق لإدارة التطبيق حظر الحسابات المخالفة أو تقييدها لحماية المجتمع.
''';

const String _termsOfUse = '''
باستخدام Respect App أنت توافق على استخدام التطبيق بطريقة محترمة وقانونية.

أنت مسؤول عن كل محتوى تنشره أو ترسله داخل التطبيق. يمكن حذف المحتوى المخالف أو تقييد الحساب عند مخالفة القوانين.

ممنوع إنشاء أكثر من حساب بنفس الإيميل، وممنوع استخدام اسم مستخدم أو اسم بروفايل موجود مسبقًا.

قد تتغير القوانين والسياسات مع تحديثات التطبيق، واستمرار استخدامك للتطبيق يعني موافقتك على آخر نسخة من الشروط.
''';
