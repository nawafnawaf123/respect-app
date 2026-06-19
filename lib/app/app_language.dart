import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/supabase_service.dart';

class RespectAppLanguage {
  final String code;
  final String countryCode;
  final String nativeName;
  final String englishName;

  const RespectAppLanguage({
    required this.code,
    required this.countryCode,
    required this.nativeName,
    required this.englishName,
  });

  Locale get locale => Locale(code, countryCode);
}

class AppLanguageProvider extends ChangeNotifier {
  static const String storageKey = 'respect_app_language_code_v2';

  static const List<RespectAppLanguage> supportedLanguages = <RespectAppLanguage>[
    RespectAppLanguage(code: 'ar', countryCode: 'SA', nativeName: 'العربية', englishName: 'Arabic'),
    RespectAppLanguage(code: 'en', countryCode: 'US', nativeName: 'English', englishName: 'English'),
    RespectAppLanguage(code: 'fr', countryCode: 'FR', nativeName: 'Français', englishName: 'French'),
    RespectAppLanguage(code: 'es', countryCode: 'ES', nativeName: 'Español', englishName: 'Spanish'),
    RespectAppLanguage(code: 'de', countryCode: 'DE', nativeName: 'Deutsch', englishName: 'German'),
    RespectAppLanguage(code: 'tr', countryCode: 'TR', nativeName: 'Türkçe', englishName: 'Turkish'),
    RespectAppLanguage(code: 'id', countryCode: 'ID', nativeName: 'Indonesia', englishName: 'Indonesian'),
    RespectAppLanguage(code: 'hi', countryCode: 'IN', nativeName: 'हिन्दी', englishName: 'Hindi'),
    RespectAppLanguage(code: 'ur', countryCode: 'PK', nativeName: 'اردو', englishName: 'Urdu'),
    RespectAppLanguage(code: 'fa', countryCode: 'IR', nativeName: 'فارسی', englishName: 'Persian'),
    RespectAppLanguage(code: 'ru', countryCode: 'RU', nativeName: 'Русский', englishName: 'Russian'),
    RespectAppLanguage(code: 'pt', countryCode: 'BR', nativeName: 'Português', englishName: 'Portuguese'),
  ];

  static List<Locale> get supportedLocales => supportedLanguages.map((e) => e.locale).toList(growable: false);

  String _languageCode = 'ar';
  bool _loaded = false;

  AppLanguageProvider() {
    _loadSavedLanguage();
  }

  String get languageCode => _languageCode;
  bool get loaded => _loaded;

  RespectAppLanguage get currentLanguage {
    return supportedLanguages.firstWhere(
      (lang) => lang.code == _languageCode,
      orElse: () => supportedLanguages.first,
    );
  }

  Locale get locale => currentLanguage.locale;

  bool get isRtl => const <String>{'ar', 'fa', 'ur'}.contains(_languageCode);
  TextDirection get textDirection => isRtl ? TextDirection.rtl : TextDirection.ltr;

  Future<void> _loadSavedLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedV2 = prefs.getString(storageKey);
      final savedV1 = prefs.getString('respect_app_language_code_v1');
      final saved = savedV2 ?? savedV1;
      if (saved != null && _isSupported(saved)) {
        _languageCode = saved;
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  bool _isSupported(String code) => supportedLanguages.any((lang) => lang.code == code);

  Future<void> setLanguageCode(String code) async {
    final next = code.trim().toLowerCase();
    if (!_isSupported(next)) return;
    if (_languageCode == next && _loaded) return;
    _languageCode = next;
    _loaded = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, next);
      await prefs.setString('respect_app_language_code_v1', next);
    } catch (_) {}

    // مهم للإشعارات الخارجية:
    // نخزن لغة المستخدم الحالية في Supabase حتى يرسل السيرفر FCM بلغة المستقبل،
    // وليس بلغة الشخص الذي أرسل الرسالة أو لغة الأدمن.
    unawaited(SupabaseService.updateCurrentUserLanguage(next));
  }

  String translate(String text) => RespectTranslations.translate(text, _languageCode);
}

extension RespectTranslateContext on BuildContext {
  // للاستخدام داخل build فقط، لأنه يستمع لتغيير اللغة ويعيد بناء الواجهة.
  AppLanguageProvider get appLanguage => watch<AppLanguageProvider>();

  // للاستخدام داخل onPressed / async callbacks / timers / streams / notifications.
  // مهم جدًا: بدون listen حتى لا يظهر خطأ Provider خارج شجرة البناء.
  AppLanguageProvider get appLanguageRead => read<AppLanguageProvider>();

  // جعل الترجمة الافتراضية آمنة في كل الأماكن؛ لأنها لا تستمع للـ Provider.
  // MaterialApp نفسه يعيد بناء التطبيق عند تغيير اللغة من RPStreamHubApp.
  String tr(String text) => appLanguageRead.translate(text);

  // نسخة تستمع للتغيير، استخدمها فقط داخل build عند الحاجة.
  String trWatch(String text) => appLanguage.translate(text);

  TextDirection get appTextDirection => appLanguageRead.textDirection;
  TextDirection get appTextDirectionWatch => appLanguage.textDirection;
}

class AppText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  const AppText(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });

  @override
  Widget build(BuildContext context) {
    final language = context.watch<AppLanguageProvider>();
    return Text(
      language.translate(data),
      key: key,
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection ?? language.textDirection,
      locale: locale ?? language.locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel == null ? null : language.translate(semanticsLabel!),
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}

class RespectTranslations {
  RespectTranslations._();

  static final RegExp _arabicRegex = RegExp(r'[؀-ۿ]');
  static bool _hasArabic(String value) => _arabicRegex.hasMatch(value);

  static String translate(String text, String code) {
    final clean = text.trim();
    if (clean.isEmpty || code == 'ar') return text;

    final exact = _lookupExact(clean);
    final english = exact ?? _templateToEnglish(clean) ?? _phraseToEnglish(clean);

    if (code == 'en') {
      return english == null ? text : _preserveEdgeSpaces(text, english);
    }

    if (english != null) {
      return _preserveEdgeSpaces(text, _englishToLanguage(code, english));
    }

    if (!_hasArabic(clean)) {
      return _preserveEdgeSpaces(text, _translateEnglishLoose(code, clean));
    }

    return text;
  }

  static String? _lookupExact(String clean) {
    final normalized = _normalizeArabic(clean);
    return _enExact[clean] ?? _enExactNormalized[normalized];
  }

  static String? _templateToEnglish(String clean) {
    final normalized = _normalizeArabic(clean);
    final countPatterns = <RegExp, String Function(Match)> {
      RegExp(r'^البلاغات\s+(.+)$'): (m) => 'Reports ${m.group(1)}',
      RegExp(r'^المستخدمين\s+(.+)$'): (m) => 'Users ${m.group(1)}',
      RegExp(r'^المنشورات\s+(.+)$'): (m) => 'Posts ${m.group(1)}',
      RegExp(r'^الستريمرز\s+(.+)$'): (m) => 'Streamers ${m.group(1)}',
      RegExp(r'^الحالة:\s*(.+)$'): (m) => 'Status: ${m.group(1)}',
      RegExp(r'^فشل نشر الرسمة:\s*(.+)$'): (m) => 'Failed to post drawing: ${m.group(1)}',
      RegExp(r'^فشل تشغيل التصفيات:\s*(.+)$'): (m) => 'Failed to run qualifiers: ${m.group(1)}',
      RegExp(r'^اكتب ردك على\s+(.+)$'): (m) => 'Write your reply to ${m.group(1)}',
      RegExp(r'^اكتب ردك على\s+(.+)\.\.\.$'): (m) => 'Write your reply to ${m.group(1)}...',
      RegExp(r'^قبل\s+(.+)$'): (m) => '${m.group(1)} ago',
      RegExp(r'^منذ\s+(.+)$'): (m) => '${m.group(1)} ago',
    };
    for (final entry in countPatterns.entries) {
      final match = entry.key.firstMatch(normalized);
      if (match != null) return entry.value(match);
    }
    return null;
  }

  static String? _phraseToEnglish(String clean) {
    if (!_hasArabic(clean)) return null;
    final normalized = _normalizeArabic(clean);
    var result = normalized;
    final terms = _enTerms.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final term in terms) {
      result = result.replaceAll(term, _enTerms[term]!);
    }
    result = _cleanupEnglish(result);

    if (result == normalized) {
      return _looksLikeUiText(normalized) ? _removeUnknownArabic(normalized) : null;
    }
    if (_hasArabic(result)) result = _removeUnknownArabic(result);
    return result.trim().isEmpty ? null : result;
  }

  static bool _looksLikeUiText(String value) {
    const signals = <String>[
      'تم', 'تعذر', 'فشل', 'جاري', 'حفظ', 'إرسال', 'إلغاء', 'حذف', 'تعديل', 'تسجيل', 'اكتب', 'اختر', 'لا توجد', 'إضافة', 'إزالة', 'بلاغ', 'منشور', 'تغريدة', 'رسالة', 'إشعار', 'اللغة', 'الإعدادات', 'الحساب', 'الخصوصية', 'الأمان', 'البحث', 'الملف الشخصي', 'المجتمع', 'المجتمعات', 'رمز', 'كلمة المرور', 'البريد الإلكتروني', 'الهاتف', 'المظهر', 'الوضع الليلي', 'عنوان', 'وصف', 'سبب', 'نوع', 'مثال', 'الصفحة', 'الفيد', 'الرد', 'الستوري', 'البث', 'المشاهدين', 'المنصة'
    ];
    return signals.any(value.contains);
  }

  static String _removeUnknownArabic(String value) {
    var result = value;
    result = result.replaceAll(RegExp(r'[ً-ٰٟـ]'), '');
    result = result.replaceAll(RegExp(r'[؀-ۿ]+'), '');
    return _cleanupEnglish(result);
  }

  static String _translateEnglishLoose(String code, String value) {
    if (code == 'en') return value;

    final direct = _fromEnglish[code]?[value];
    if (direct != null) return direct;

    var result = value;
    final terms = (_englishTermsByLanguage[code] ?? const <String, String>{}).entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));

    for (final entry in terms) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }

  static String _englishToLanguage(String code, String english) {
    if (code == 'en') return english;

    final direct = _fromEnglish[code]?[english];
    if (direct != null) return direct;

    return _translateEnglishLoose(code, english);
  }

  static String _normalizeArabic(String value) {
    return value
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي')
        .replaceAll(RegExp(r'[ً-ٰٟـ]'), '')
        .replaceAll('،', ',')
        .trim();
  }

  static String _cleanupEnglish(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(' ,', ',')
        .replaceAll(' .', '.')
        .replaceAll(' :', ':')
        .replaceAll(' ...', '...')
        .replaceAll(' / ', ' / ')
        .replaceAll(RegExp(r'\s+-\s+'), ' - ')
        .trim();
  }

  static String _preserveEdgeSpaces(String original, String translated) {
    final leading = RegExp(r'^\s+').firstMatch(original)?.group(0) ?? '';
    final trailing = RegExp(r'\s+$').firstMatch(original)?.group(0) ?? '';
    return '$leading$translated$trailing';
  }

  static final Map<String, String> _enExact = <String, String>{
    "اللغة": "Language",
    "اختر لغة التطبيق": "Choose app language",
    "تتغير اللغة فورًا في كل صفحات التطبيق": "The language changes instantly across the whole app",
    "تم تغيير لغة التطبيق": "App language changed",
    "الإعدادات": "Settings",
    "الحساب": "Account",
    "الخصوصية": "Privacy",
    "الأمان": "Security",
    "الإشعارات": "Notifications",
    "حول التطبيق": "About the app",
    "الإصدار 1.0.0": "Version 1.0.0",
    "تسجيل الخروج": "Log out",
    "العودة إلى صفحة تسجيل الدخول": "Return to login screen",
    "هل تريد تسجيل الخروج من الحساب الحالي؟": "Do you want to log out of the current account?",
    "إلغاء": "Cancel",
    "خروج": "Log out",
    "حفظ": "Save",
    "تعديل": "Edit",
    "حذف": "Delete",
    "تأكيد": "Confirm",
    "تم": "Done",
    "رجوع": "Back",
    "بحث": "Search",
    "الرئيسية": "Home",
    "البحث": "Search",
    "الرسائل": "Messages",
    "الإدارة": "Admin",
    "المحفوظات": "Saved",
    "حسابي": "My profile",
    "الستريمرز": "Streamers",
    "البثوث": "Streams",
    "بثوث ريسبكت": "Respect Live",
    "رسامين ريسبكت": "Respect Painters",
    "رسامين": "Painters",
    "القائمة الرئيسية": "Main menu",
    "Respect App": "Respect App",
    "Loading your world...": "Loading your world...",
    "تشغيل الخدمات...": "Starting services...",
    "فحص الجلسة...": "Checking session...",
    "تحميل بيانات الحساب...": "Loading account data...",
    "تحميل التغريدات...": "Loading tweets...",
    "تجهيز الصور والفيديوهات...": "Preparing photos and videos...",
    "ترتيب الفيد للفتح...": "Preparing the feed...",
    "مزامنة الإشعارات...": "Syncing notifications...",
    "فتح التطبيق...": "Opening app...",
    "تم حظر هذا الجهاز": "This device has been blocked",
    "لا يمكنك فتح Respect App من هذا الجهاز.": "You cannot open Respect App from this device.",
    "تواصل مع إدارة Respect إذا تعتقد أن الحظر تم بالخطأ.": "Contact Respect support if you think this block was a mistake.",
    "تسجيل الدخول": "Log in",
    "إنشاء حساب": "Create account",
    "اسم المستخدم": "Username",
    "البريد الإلكتروني": "Email",
    "كلمة المرور": "Password",
    "تأكيد كلمة المرور": "Confirm password",
    "الاسم": "Name",
    "تاريخ الميلاد": "Birth date",
    "متابعة": "Follow",
    "إلغاء المتابعة": "Unfollow",
    "متابعون": "Followers",
    "يتابع": "Following",
    "المتابعين": "Following",
    "المتابَعين": "Following",
    "المنشورات": "Posts",
    "التغريدات": "Tweets",
    "الوسائط": "Media",
    "الردود": "Replies",
    "الأشخاص": "People",
    "الأعضاء": "Members",
    "البلاغات": "Reports",
    "المطرودين": "Removed",
    "تعديل الملف الشخصي": "Edit profile",
    "حفظ التعديلات": "Save changes",
    "اكتب شيئًا...": "Write something...",
    "نشر": "Post",
    "إعجاب": "Like",
    "رد": "Reply",
    "إعادة نشر": "Repost",
    "مشاركة": "Share",
    "حفظ المنشور": "Save post",
    "إزالة من المحفوظات": "Remove from saved",
    "لك": "For you",
    "مجتمعات تتابعها": "Communities you follow",
    "المجتمعات": "Communities",
    "مجتمع": "Community",
    "كل المجتمعات": "All communities",
    "المجتمعات التي تتابعها": "Communities you follow",
    "لا توجد منشورات بعد": "No posts yet",
    "لا توجد تغريدات بعد": "No tweets yet",
    "لا توجد تغريدات من المتابَعين": "No tweets from people you follow",
    "لا توجد تغريدات في المجتمع بعد": "No tweets in this community yet",
    "تابع المجتمع لمشاهدة التفاعل والنشر": "Follow the community to see activity and post",
    "لا توجد صور أو فيديوهات بعد": "No photos or videos yet",
    "لا توجد مجتمعات بعد": "No communities yet",
    "جاري التحميل...": "Loading...",
    "جاري التحليل.": "Analyzing.",
    "جاري التصحيح...": "Fixing...",
    "جاري الإرسال...": "Sending...",
    "تحديث": "Refresh",
    "إرسال": "Send",
    "اكتب رسالة...": "Write a message...",
    "مجموعة": "Group",
    "الدردشة مقفلة": "Chat is locked",
    "مشرف في المجموعة": "Group admin",
    "جاري الاتصال...": "Calling...",
    "إنهاء": "End",
    "كتم": "Mute",
    "السماعة": "Speaker",
    "الكاميرا": "Camera",
    "إخفاء الإحصائيات": "Hide statistics",
    "إظهار الإحصائيات": "Show statistics",
    "إشعار عام": "General notification",
    "العنوان": "Title",
    "النص": "Text",
    "إرسال الإشعار": "Send notification",
    "إرسال لكل المستخدمين": "Send to all users",
    "ملاحظات / بلاغ مشكلة": "Feedback / bug report",
    "عنوان المشكلة": "Issue title",
    "مكان المشكلة / الصفحة": "Issue place / screen",
    "وصف المشكلة": "Issue description",
    "إرسال وتشغيل Qwen3-Coder": "Send and run Qwen3-Coder",
    "الموافقة وبدء التصحيح": "Approve and start fixing",
    "الملفات المتوقعة:": "Expected files:",
    "حفظ خصوصية الرسائل": "Save message privacy",
    "تفعيل الرسائل": "Enable messages",
    "استقبال الرسائل من الموثقين فقط": "Receive messages from verified users only",
    "طلب دردشة قبل أول رسالة": "Require chat request before first message",
    "السماح بالمكالمات": "Allow calls",
    "الوضع الليلي": "Dark mode",
    "المظهر": "Appearance",
    "رقم الهاتف": "Phone number",
    "رمز التحقق": "Verification code",
    "إرسال الرمز": "Send code",
    "تحقق": "Verify",
    "الدولة": "Country",
    "رقم الجوال": "Mobile number",
    "رمز SMS": "SMS code",
    "إعدادات الخصوصية": "Privacy settings",
    "طلبات الدردشة": "Chat requests",
    "رفض": "Decline",
    "قبول": "Accept",
    "رد على الستوري...": "Reply to the story...",
    "إلغاء التحديد": "Clear selection",
    "نسخ": "Copy",
    "تحميل": "Download",
    "اتصال صوتي": "Voice call",
    "مكالمة فيديو": "Video call",
    "اتصال جماعي": "Group voice call",
    "فيديو جماعي": "Group video call",
    "خيارات المجموعة": "Group options",
    "اسم المجموعة": "Group name",
    "ابحث عن عضو": "Search for a member",
    "إرسال صورة أو فيديو": "Send photo or video",
    "عدّل رسالتك...": "Edit your message...",
    "إيقاف مؤقت": "Pause",
    "معاينة": "Preview",
    "إضافة صورة أو فيديو": "Add photo or video",
    "تسجيل صوتي": "Record voice",
    "إيقاف التسجيل": "Stop recording",
    "اكتب رد...": "Write a reply...",
    "نشر ردّك": "Post your reply",
    "إضافة مع الرد": "Add with reply",
    "صوت / صورة / فيديو": "Voice / photo / video",
    "اكتب تعليق...": "Write a comment...",
    "اكتب نص التغريدة": "Write tweet text",
    "حذف التسجيل": "Delete recording",
    "حذف التغريدة": "Delete tweet",
    "هل تريد حذف هذه التغريدة نهائيًا؟": "Do you want to permanently delete this tweet?",
    "تم تعديل التغريدة": "Tweet updated",
    "تم حذف التغريدة": "Tweet deleted",
    "عضو في مجتمع Respect App": "Member of Respect App community",
    "نتيجة البلاغ": "Report result",
    "نوع البلاغ": "Report type",
    "بلاغ مخصص": "Custom report",
    "اكتب البلاغ الذي تريده": "Write the report you want",
    "اشرح البلاغ بالتفصيل": "Explain the report in detail",
    "مثال: اشرح للمشرفين المشكلة كاملة...": "Example: explain the whole issue to the moderators...",
    "اختياري، لكن يساعد المشرفين والذكاء الاصطناعي": "Optional, but it helps moderators and AI",
    "اختياري، لكنه يساعد المشرفين والذكاء الاصطناعي": "Optional, but it helps moderators and AI",
    "اكتب بلاغك كامل هنا": "Write your full report here",
    "إضافة مشرف": "Add moderator",
    "المالك والمشرفون": "Owner and moderators",
    "مالك المجتمع": "Community owner",
    "مشرف": "Moderator",
    "أنت مالك المجتمع": "You are the community owner",
    "أنت عضو - إلغاء المتابعة": "You are a member - unfollow",
    "متابعة المجتمع": "Follow community",
    "اسم المجتمع": "Community name",
    "وصف المجتمع": "Community description",
    "أنت المالك وسيتم إضافتك كمشرف تلقائيًا": "You are the owner and will be added as a moderator automatically",
    "وش ودك تنشر اليوم؟": "What do you want to post today?",
    "تظهر في تبويب لك والملف الشخصي": "Appears in For you and your profile",
    "تظهر فقط في تبويب المتابعين": "Appears only in Following",
    "المجتمعات المنضم لها": "Joined communities",
    "لا توجد بلاغات حالياً": "No reports right now",
    "أي بلاغ جديد سيظهر هنا للمراجعة السريعة.": "Any new report will appear here for quick review.",
    "بلاغات التغريدات": "Tweet reports",
    "حذف الكل": "Delete all",
    "حذف المنشور": "Delete post",
    "حذف البلاغ": "Delete report",
    "إعادة مراجعة البلاغ بالذكاء الاصطناعي": "Review the report again with AI",
    "مراجعة البلاغ بالذكاء الاصطناعي": "Review report with AI",
    "بحث سريع داخل الإدارة...": "Quick search inside admin...",
    "عنوان الإشعار": "Notification title",
    "مثال: تحديث جديد": "Example: new update",
    "نص الإشعار": "Notification text",
    "اكتب الرسالة التي ستصل لكل مستخدمي التطبيق...": "Write the message that will reach every app user...",
    "الإشعار يصل للأجهزة التي سجلت FCM Token. المستخدم الذي يكون داخل التطبيق سيشاهد تنبيه علوي، وسيظهر أيضاً في صفحة الإشعارات.": "The notification reaches devices that registered an FCM token. Users inside the app will see a top alert, and it will also appear on the notifications page.",
    "رابط البث الثابت": "Permanent stream link",
    "اسم الستريمر / القناة": "Streamer / channel name",
    "عنوان البث": "Stream title",
    "عدد المشاهدين": "Viewer count",
    "المنصة: kick / twitch": "Platform: kick / twitch",
    "رابط صورة البث / المصغرة": "Stream image / thumbnail link",
    "سبب الحظر": "Ban reason",
    "مثال: https://kick.com/channel أو twitch.tv/name": "Example: https://kick.com/channel or twitch.tv/name",
    "الصفحة المباشرة": "Live page",
    "المشغل الذكي": "Smart player",
    "صفحة الموبايل": "Mobile page",
    "فتح في المتصفح": "Open in browser",
    "مباشر الآن": "Live now",
    "القنوات": "Channels",
    "عنوان الرسمة": "Drawing title",
    "وصف اختياري للرسمه": "Optional drawing description",
    "تم نشر الرسمة داخل بطولة رسامين ريسبكت": "The drawing was posted in the Respect Painters tournament",
    "لم يتم قبول الصورة كرسمة حقيقية": "The image was not accepted as a real drawing",
    "فشل نشر الرسمة": "Failed to post drawing",
    "بدء تصفيات رسامين ريسبكت...": "Starting Respect Painters qualifiers...",
    "انتهت التصفيات وتم اختيار الفائز": "Qualifiers finished and the winner was selected",
    "تعذر تشغيل التصفيات": "Could not run qualifiers",
    "فشل تشغيل التصفيات": "Failed to run qualifiers",
    "عرض الإشعار كامل": "Show full notification",
    "إغلاق": "Close",
    "دردشة": "Chat",
    "إيقاف إشعارات التغريدات": "Turn off tweet notifications",
    "تفعيل إشعارات التغريدات": "Turn on tweet notifications",
    "بحث ذكي: عصابة الكفن، سيرفر ريسبكت، #هاشتاق...": "Smart search: clan name, Respect server, #hashtag...",
    "هذه الصفحة للأدمن فقط": "This page is for admins only",
    "صفحة الإدارة متاحة للأدمن فقط": "The admin page is available only to admins",
    "مثلاً: زر تعديل الملف الشخصي لا يعمل": "Example: edit profile button does not work",
    "مثلاً: الملف الشخصي، الفيد، الرسائل": "Example: profile, feed, messages",
    "اشرح ماذا حدث، ماذا توقعت، وهل ظهر خطأ معين": "Explain what happened, what you expected, and whether an error appeared",
    "مشكلة في التطبيق": "App issue",
    "القوانين": "Rules",
    "الاستخدام": "Use",
    "شروط الاستخدام": "Terms of use",
    "سياسة الخصوصية": "Privacy policy",
    "قوانين Respect App": "Respect App rules",
    "000000": "000000",
    "اكتب التعديل هنا...": "Write the edit here...",
    "اكتب تعليق على الستوري...": "Write a comment on the story...",
    "لا توجد إشعارات بعد": "No notifications yet",
    "لا توجد محفوظات بعد": "No saved posts yet",
    "حذف من المحفوظات": "Remove from saved"
  };

  static final Map<String, String> _enExactNormalized = <String, String>{
    for (final entry in _enExact.entries) _normalizeArabic(entry.key): entry.value,
  };

  static final Map<String, String> _enTerms = <String, String>{
    "اعاده تعيين كلمه المرور": "Reset password",
    "كلمه المرور الجديده": "New password",
    "اكتب كلمه المرور الجديده": "Write the new password",
    "اعد كتابه كلمه المرور": "Re-enter the password",
    "حفظ كلمه المرور": "Save password",
    "كلمتا المرور غير متطابقتان": "Passwords do not match",
    "كلمه المرور لازم تكون 6 احرف علي الاقل": "Password must be at least 6 characters",
    "بعد نجاح العمليه": "After it succeeds",
    "ارجع الي تطبيق Respect": "go back to the Respect app",
    "وسجل دخولك": "and log in",
    "بكلمه المرور الجديده": "with the new password",
    "تم": "Done",
    "تعذر": "Could not",
    "فشل": "Failed",
    "جاري": "Loading",
    "تحميل": "download",
    "تشغيل": "Start",
    "حفظ": "Save",
    "ارسال": "Send",
    "الغاء": "Cancel",
    "حذف": "Delete",
    "تعديل": "Edit",
    "تسجيل": "Login",
    "الخروج": "logout",
    "الدخول": "login",
    "الحساب": "account",
    "الرسايل": "messages",
    "رساله": "message",
    "منشور": "post",
    "منشورات": "posts",
    "التغريده": "tweet",
    "تغريده": "tweet",
    "التغريدات": "tweets",
    "تغريدات": "tweets",
    "الردود": "replies",
    "ردود": "replies",
    "الوسايط": "media",
    "المتابعين": "following",
    "متابعون": "followers",
    "يتابع": "following",
    "الاشعارات": "notifications",
    "اشعارات": "notifications",
    "الاعدادات": "settings",
    "البحث": "search",
    "بحث": "search",
    "اللغه": "language",
    "العربيه": "Arabic",
    "الانجليزيه": "English",
    "الخصوصيه": "privacy",
    "الامان": "security",
    "المكالمات": "calls",
    "مكالمه": "call",
    "اتصال": "call",
    "الكاميرا": "camera",
    "الصوت": "audio",
    "صوت": "voice",
    "الفيديو": "video",
    "فيديو": "video",
    "صوره": "photo",
    "صور": "photos",
    "مجموعه": "group",
    "المجموعه": "group",
    "مجتمعات": "communities",
    "المجتمعات": "communities",
    "مجتمع": "community",
    "المستخدم": "user",
    "المستخدمين": "users",
    "الادمن": "admin",
    "بلاغ": "report",
    "البلاغ": "report",
    "بلاغات": "reports",
    "مشكله": "issue",
    "التطبيق": "app",
    "صفحه": "screen",
    "الصفحه": "page",
    "الفيد": "feed",
    "الملف الشخصي": "profile",
    "الرييسيه": "home",
    "المحفوظات": "saved",
    "بثوث": "streams",
    "بث": "live",
    "مباشر": "live",
    "الستريمرز": "streamers",
    "ستريمر": "streamer",
    "القنوات": "channels",
    "قناه": "channel",
    "رمز": "code",
    "التحقق": "verification",
    "كلمه المرور": "password",
    "البريد الالكتروني": "email",
    "اسم المستخدم": "username",
    "الاسم": "name",
    "تاريخ الميلاد": "birth date",
    "رقم الهاتف": "phone number",
    "رقم الجوال": "mobile number",
    "الوضع الليلي": "dark mode",
    "المظهر": "appearance",
    "العنوان": "title",
    "النص": "text",
    "الوصف": "description",
    "وصف": "description",
    "اختياري": "optional",
    "المشرفين": "moderators",
    "المشرفون": "moderators",
    "المشرف": "moderator",
    "المالك": "owner",
    "مالك": "owner",
    "عضو": "member",
    "الاعضاء": "members",
    "المطرودين": "removed",
    "المطرود": "removed",
    "متابعه": "follow",
    "الغاء المتابعه": "unfollow",
    "تابع": "follow",
    "تتابعها": "you follow",
    "كل": "all",
    "لا توجد": "No",
    "لا يوجد": "No",
    "بعد": "yet",
    "قبل": "before",
    "الان": "now",
    "اليوم": "today",
    "الامس": "yesterday",
    "غدا": "tomorrow",
    "داخل": "inside",
    "خارج": "outside",
    "علوي": "top",
    "سيظهر": "will appear",
    "يظهر": "appears",
    "تظهر": "appears",
    "فقط": "only",
    "كامل": "full",
    "كامله": "full",
    "سريع": "quick",
    "ذكي": "smart",
    "الذكاء الاصطناعي": "AI",
    "الموافقه": "approve",
    "بدء": "start",
    "التصحيح": "fixing",
    "التحليل": "analysis",
    "الحاله": "status",
    "المتوقعه": "expected",
    "مكان": "place",
    "اشرح": "explain",
    "اكتب": "write",
    "اختر": "choose",
    "اضافه": "add",
    "ازاله": "remove",
    "نسخ": "copy",
    "عرض": "show",
    "فتح": "open",
    "اغلاق": "close",
    "رفض": "decline",
    "قبول": "accept",
    "تاكيد": "confirm",
    "رجوع": "back",
    "رجع": "back",
    "مشاهده": "view",
    "المشاهدات": "views",
    "عدد": "count",
    "سبب": "reason",
    "نوع": "type",
    "مخصص": "custom",
    "مثال": "example",
    "الرابط": "link",
    "رابط": "link",
    "المنصه": "platform",
    "البث": "stream",
    "المصغره": "thumbnail",
    "الصوره": "image",
    "الرسمه": "drawing",
    "بطوله": "tournament",
    "تصفيات": "qualifiers",
    "الفايز": "winner",
    "من": "from",
    "الي": "to",
    "علي": "on",
    "في": "in",
    "مع": "with",
    "او": "or",
    "و": "and",
    "لكن": "but",
    "للمستخدمين": "users",
    "لكل": "all",
    "انت": "you",
    "انا": "I",
    "هو": "he",
    "هي": "she",
    "هذا": "this",
    "هذه": "this",
    "ذلك": "that",
    "التي": "that",
    "الذي": "that",
    "اذا": "if",
    "هل": "do",
    "ماذا": "what",
    "وش": "what",
    "ودك": "you want",
    "تنشر": "post",
    "نشر": "post",
    "ردك": "your reply",
    "تعليق": "comment",
    "ستوري": "story",
    "القصه": "story",
    "الستوري": "story",
    "الكل": "all",
    "للعامه": "public",
    "للمراجعه": "for review",
    "السريعه": "quick",
    "حاليا": "right now"
  };

  static final Map<String, Map<String, String>> _fromEnglish = <String, Map<String, String>>{
    'fr': <String, String>{
      "Language": "Langue",
      "Choose app language": "Choisir la langue de l’application",
      "The language changes instantly across the whole app": "La langue change immédiatement dans toute l’application",
      "App language changed": "Langue de l’application modifiée",
      "Settings": "Paramètres",
      "Account": "Compte",
      "Privacy": "Confidentialité",
      "Security": "Sécurité",
      "Notifications": "Notifications",
      "About the app": "À propos",
      "Log out": "Déconnexion",
      "Cancel": "Annuler",
      "Save": "Enregistrer",
      "Search": "Recherche",
      "Home": "Accueil",
      "Messages": "Messages",
      "Admin": "Admin",
      "Saved": "Enregistrés",
      "My profile": "Mon profil",
      "Posts": "Publications",
      "Tweets": "Tweets",
      "Media": "Médias",
      "Replies": "Réponses",
      "People": "Personnes",
      "Communities": "Communautés",
      "Follow": "Suivre",
      "Following": "Abonnements",
      "Followers": "Abonnés",
      "Edit profile": "Modifier le profil",
      "Post": "Publier",
      "Reply": "Répondre",
      "Like": "J’aime",
      "Repost": "Republier",
      "Share": "Partager",
      "Send": "Envoyer",
      "Loading...": "Chargement...",
      "For you": "Pour vous",
      "Respect Live": "Respect Live",
      "Respect Painters": "Respect Painters",
      "Streamers": "Streamers",
      "Dark mode": "Mode sombre",
      "Appearance": "Apparence"
    },
    'es': <String, String>{
      "Language": "Idioma",
      "Choose app language": "Elegir idioma de la app",
      "The language changes instantly across the whole app": "El idioma cambia al instante en toda la app",
      "App language changed": "Idioma de la app cambiado",
      "Settings": "Configuración",
      "Account": "Cuenta",
      "Privacy": "Privacidad",
      "Security": "Seguridad",
      "Notifications": "Notificaciones",
      "About the app": "Acerca de la app",
      "Log out": "Cerrar sesión",
      "Cancel": "Cancelar",
      "Save": "Guardar",
      "Search": "Buscar",
      "Home": "Inicio",
      "Messages": "Mensajes",
      "Admin": "Admin",
      "Saved": "Guardados",
      "My profile": "Mi perfil",
      "Posts": "Publicaciones",
      "Tweets": "Tweets",
      "Media": "Medios",
      "Replies": "Respuestas",
      "People": "Personas",
      "Communities": "Comunidades",
      "Follow": "Seguir",
      "Following": "Siguiendo",
      "Followers": "Seguidores",
      "Edit profile": "Editar perfil",
      "Post": "Publicar",
      "Reply": "Responder",
      "Like": "Me gusta",
      "Repost": "Repostear",
      "Share": "Compartir",
      "Send": "Enviar",
      "Loading...": "Cargando...",
      "For you": "Para ti",
      "Respect Live": "Respect Live",
      "Respect Painters": "Respect Painters",
      "Streamers": "Streamers",
      "Dark mode": "Modo oscuro",
      "Appearance": "Apariencia"
    },
    'de': <String, String>{
      "Language": "Sprache",
      "Choose app language": "App-Sprache auswählen",
      "The language changes instantly across the whole app": "Die Sprache ändert sich sofort in der ganzen App",
      "App language changed": "App-Sprache geändert",
      "Settings": "Einstellungen",
      "Account": "Konto",
      "Privacy": "Datenschutz",
      "Security": "Sicherheit",
      "Notifications": "Benachrichtigungen",
      "About the app": "Über die App",
      "Log out": "Abmelden",
      "Cancel": "Abbrechen",
      "Save": "Speichern",
      "Search": "Suchen",
      "Home": "Startseite",
      "Messages": "Nachrichten",
      "Admin": "Admin",
      "Saved": "Gespeichert",
      "My profile": "Mein Profil",
      "Posts": "Beiträge",
      "Tweets": "Tweets",
      "Media": "Medien",
      "Replies": "Antworten",
      "People": "Personen",
      "Communities": "Communities",
      "Follow": "Folgen",
      "Following": "Folge ich",
      "Followers": "Follower",
      "Edit profile": "Profil bearbeiten",
      "Post": "Posten",
      "Reply": "Antworten",
      "Like": "Gefällt mir",
      "Repost": "Reposten",
      "Share": "Teilen",
      "Send": "Senden",
      "Loading...": "Wird geladen...",
      "For you": "Für dich",
      "Streamers": "Streamers",
      "Dark mode": "Dunkler Modus",
      "Appearance": "Darstellung"
    },
    'tr': <String, String>{
      "Language": "Dil",
      "Choose app language": "Uygulama dilini seç",
      "The language changes instantly across the whole app": "Dil tüm uygulamada anında değişir",
      "App language changed": "Uygulama dili değiştirildi",
      "Settings": "Ayarlar",
      "Account": "Hesap",
      "Privacy": "Gizlilik",
      "Security": "Güvenlik",
      "Notifications": "Bildirimler",
      "About the app": "Uygulama hakkında",
      "Log out": "Çıkış yap",
      "Cancel": "İptal",
      "Save": "Kaydet",
      "Search": "Ara",
      "Home": "Ana sayfa",
      "Messages": "Mesajlar",
      "Admin": "Yönetim",
      "Saved": "Kaydedilenler",
      "My profile": "Profilim",
      "Posts": "Gönderiler",
      "Tweets": "Tweetler",
      "Media": "Medya",
      "Replies": "Yanıtlar",
      "People": "Kişiler",
      "Communities": "Topluluklar",
      "Follow": "Takip et",
      "Following": "Takip edilenler",
      "Followers": "Takipçiler",
      "Edit profile": "Profili düzenle",
      "Post": "Paylaş",
      "Reply": "Yanıtla",
      "Like": "Beğen",
      "Repost": "Yeniden paylaş",
      "Share": "Paylaş",
      "Send": "Gönder",
      "Loading...": "Yükleniyor...",
      "For you": "Senin için",
      "Streamers": "Yayıncılar",
      "Dark mode": "Karanlık mod",
      "Appearance": "Görünüm"
    },
    'id': <String, String>{
      "Language": "Bahasa",
      "Settings": "Pengaturan",
      "Account": "Akun",
      "Privacy": "Privasi",
      "Security": "Keamanan",
      "Notifications": "Notifikasi",
      "Log out": "Keluar",
      "Cancel": "Batal",
      "Save": "Simpan",
      "Search": "Cari",
      "Home": "Beranda",
      "Messages": "Pesan",
      "Posts": "Postingan",
      "Tweets": "Tweet",
      "Communities": "Komunitas",
      "Follow": "Ikuti",
      "Send": "Kirim",
      "Loading...": "Memuat..."
    },
    'hi': <String, String>{
      "Language": "भाषा",
      "Settings": "सेटिंग्स",
      "Account": "खाता",
      "Privacy": "गोपनीयता",
      "Security": "सुरक्षा",
      "Notifications": "सूचनाएँ",
      "Log out": "लॉग आउट",
      "Cancel": "रद्द करें",
      "Save": "सहेजें",
      "Search": "खोज",
      "Home": "होम",
      "Messages": "संदेश",
      "Posts": "पोस्ट",
      "Send": "भेजें",
      "Loading...": "लोड हो रहा है..."
    },
    'ur': <String, String>{
      "Language": "زبان",
      "Settings": "ترتیبات",
      "Account": "اکاؤنٹ",
      "Privacy": "رازداری",
      "Security": "سیکیورٹی",
      "Notifications": "اطلاعات",
      "Log out": "لاگ آؤٹ",
      "Cancel": "منسوخ",
      "Save": "محفوظ کریں",
      "Search": "تلاش",
      "Home": "ہوم",
      "Messages": "پیغامات",
      "Posts": "پوسٹس",
      "Send": "بھیجیں",
      "Loading...": "لوڈ ہو رہا ہے..."
    },
    'fa': <String, String>{
      "Language": "زبان",
      "Settings": "تنظیمات",
      "Account": "حساب",
      "Privacy": "حریم خصوصی",
      "Security": "امنیت",
      "Notifications": "اعلان‌ها",
      "Log out": "خروج",
      "Cancel": "لغو",
      "Save": "ذخیره",
      "Search": "جستجو",
      "Home": "خانه",
      "Messages": "پیام‌ها",
      "Posts": "پست‌ها",
      "Send": "ارسال",
      "Loading...": "در حال بارگیری..."
    },
    'ru': <String, String>{
      "Language": "Язык",
      "Settings": "Настройки",
      "Account": "Аккаунт",
      "Privacy": "Конфиденциальность",
      "Security": "Безопасность",
      "Notifications": "Уведомления",
      "Log out": "Выйти",
      "Cancel": "Отмена",
      "Save": "Сохранить",
      "Search": "Поиск",
      "Home": "Главная",
      "Messages": "Сообщения",
      "Posts": "Посты",
      "Send": "Отправить",
      "Loading...": "Загрузка..."
    },
    'pt': <String, String>{
      "Language": "Idioma",
      "Settings": "Configurações",
      "Account": "Conta",
      "Privacy": "Privacidade",
      "Security": "Segurança",
      "Notifications": "Notificações",
      "Log out": "Sair",
      "Cancel": "Cancelar",
      "Save": "Salvar",
      "Search": "Pesquisar",
      "Home": "Início",
      "Messages": "Mensagens",
      "Posts": "Posts",
      "Tweets": "Tweets",
      "Communities": "Comunidades",
      "Follow": "Seguir",
      "Send": "Enviar",
      "Loading...": "Carregando..."
    },
  };

  static const Map<String, Map<String, String>> _englishTermsByLanguage = <String, Map<String, String>>{
    'fr': <String, String>{'Search': 'Recherche', 'Messages': 'Messages', 'Home': 'Accueil', 'Save': 'Enregistrer', 'Cancel': 'Annuler', 'Send': 'Envoyer', 'Post': 'Publier', 'Posts': 'Publications', 'Tweets': 'Tweets', 'Communities': 'Communautés', 'Settings': 'Paramètres'},
    'es': <String, String>{'Search': 'Buscar', 'Messages': 'Mensajes', 'Home': 'Inicio', 'Save': 'Guardar', 'Cancel': 'Cancelar', 'Send': 'Enviar', 'Post': 'Publicar', 'Posts': 'Publicaciones', 'Tweets': 'Tweets', 'Communities': 'Comunidades', 'Settings': 'Configuración'},
    'de': <String, String>{'Search': 'Suchen', 'Messages': 'Nachrichten', 'Home': 'Startseite', 'Save': 'Speichern', 'Cancel': 'Abbrechen', 'Send': 'Senden', 'Post': 'Posten', 'Posts': 'Beiträge', 'Settings': 'Einstellungen'},
    'tr': <String, String>{'Search': 'Ara', 'Messages': 'Mesajlar', 'Home': 'Ana sayfa', 'Save': 'Kaydet', 'Cancel': 'İptal', 'Send': 'Gönder', 'Post': 'Paylaş', 'Posts': 'Gönderiler', 'Settings': 'Ayarlar'},
    'pt': <String, String>{'Search': 'Pesquisar', 'Messages': 'Mensagens', 'Home': 'Início', 'Save': 'Salvar', 'Cancel': 'Cancelar', 'Send': 'Enviar', 'Post': 'Postar', 'Posts': 'Posts', 'Settings': 'Configurações'},
  };
}
