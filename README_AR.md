# RP Stream Hub – النسخة المُطوَّرة

تطبيق مجتمعي كامل لخوادم الحياة الواقعية (Roleplay) بواجهة عصرية وتجربة سلسة.

## المميزات
- واجهة داكنة/فاتحة مع حركات أنيقة.
- دردشة المدينة (منشورات).
- بثوث الستريمرز مع رابط فتح مباشر.
- محادثة فورية بين الأعضاء.
- إشعارات.
- ملف شخصي.
- لوحة إدارة احترافية.
- إعدادات مع خيار الوضع الداكن.

## البداية
1. تأكد من وجود Flutter على جهازك.
2. شغّل السكربت: `python create_rp_stream_app.py`
3. في حال عدم وجود Flutter: سينشئ المجلد والملفات الأساسية،
   ثم افتح المجلد ونفذ: `flutter create .`
4. انتقل للمشروع: `cd rp_stream_hub`
5. ثبت الحزم: `flutter pub get`
6. شغّل: `flutter run`

## هيكل المشروع
    lib/
├── main.dart
├── app/
│ ├── app.dart
│ └── theme_provider.dart
├── data/
│ └── demo_data.dart
├── models/
│ ├── post.dart
│ ├── streamer.dart
│ └── message.dart
├── screens/
│ ├── splash_screen.dart
│ ├── login_screen.dart
│ ├── home_screen.dart
│ ├── feed_screen.dart
│ ├── streamers_screen.dart
│ ├── chat_screen.dart
│ ├── notifications_screen.dart
│ ├── profile_screen.dart
│ ├── settings_screen.dart
│ └── admin_screen.dart
├── theme/
│ └── app_theme.dart
└── widgets/
├── glass_card.dart
└── primary_button.dart

## التطوير المستقبلي
- ربط بـ FastAPI/Node.js.
- تسجيل دخول حقيقي.
- قاعدة بيانات PostgreSQL أو Firebase.
- إحصائيات البثوث الحية عبر API.
- نظام صلاحيات متقدم.
