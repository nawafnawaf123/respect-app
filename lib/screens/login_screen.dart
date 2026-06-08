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

  StreamSubscription<AuthState>? _authSub;

  bool _isCreateMode = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _acceptedTerms = false;
  bool _loading = false;
  bool _navigated = false;
  bool _googleLoginInProgress = false;
  bool _handlingAuthState = false;

  @override
  void initState() {
    super.initState();

    // احتياط فقط لو رجعت جلسة Google من Supabase بدون ضغط الزر.
    // أثناء ضغط زر Google نفسه لا نشغل sync مرتين، لأن _loginWithGoogle يعالج الدخول مباشرة.
    _authSub = SupabaseService.client.auth.onAuthStateChange.listen((state) async {
      if (!mounted) return;
      if (_googleLoginInProgress || _handlingAuthState || _navigated) return;
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
        _showMessage('كلمتا المرور غير متطابقتين');
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

    setState(() => _loading = true);

    try {
      if (_isCreateMode) {
        await SupabaseService.register(
          username: username,
          email: email,
          password: password,
          name: fullName,
          birthDate: birthDate,
          acceptedTerms: _acceptedTerms,
        );
        _showMessage('تم إنشاء الحساب بنجاح');
      } else {
        final user = await SupabaseService.login(loginInput, password);
        if (user == null) {
          _showMessage('اسم المستخدم/الإيميل أو كلمة المرور غير صحيحة أو الحساب محظور');
          return;
        }
      }

      _goHome();
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      _showMessage(msg);
    } finally {
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
      if (!_isCreateMode) {
        _nameCtrl.clear();
        _emailCtrl.clear();
        _birthDateCtrl.clear();
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
              label: 'كلمة المرور',
              hint: _isCreateMode ? '6 أحرف على الأقل' : 'كلمة المرور',
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
              text: _loading ? 'جاري المعالجة...' : (_isCreateMode ? 'إنشاء الحساب' : 'تسجيل الدخول'),
              icon: _isCreateMode ? Icons.person_add_alt_1_rounded : Icons.login_rounded,
              onPressed: _loading ? () {} : _submit,
            ).animate().fadeIn(delay: 300.ms),
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
