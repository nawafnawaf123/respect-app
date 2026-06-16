// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, use_build_context_synchronously, unnecessary_this, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures, prefer_final_fields, unnecessary_type_check, unnecessary_non_null_assertion
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

import '../app/app_language.dart';
/// هذا الملف كان يسبب ظهور شاشة قبول/رفض القديمة داخل Flutter
/// خلف شاشة المكالمة البنفسجية Native.
///
/// النظام الجديد يعتمد على شاشة Native:
/// IncomingCallFullScreenActivity.kt
/// لذلك هذه الشاشة أصبحت مجرد حماية: إذا تم فتحها من أي كود قديم،
/// تغلق نفسها فورًا حتى لا تظهر شاشة ثانية.
class IncomingCallScreen extends StatefulWidget {
  final String callId;
  final String callerName;
  final String callerUsername;
  final String? callerAvatarPath;
  final bool video;

  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.callerName,
    required this.callerUsername,
    this.callerAvatarPath,
    required this.video,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _closeOldFlutterScreen());
  }

  Future<void> _closeOldFlutterScreen() async {
    if (_closed) return;
    _closed = true;

    // لا نلغي إشعار المكالمة هنا حتى لا نقطع شاشة Native البنفسجية.
    // فقط نغلق شاشة Flutter القديمة لو انفتحت بالغلط.
    if (!mounted) return;

    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.darkBg,
      body: SizedBox.expand(),
    );
  }
}
