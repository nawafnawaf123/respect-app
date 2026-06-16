import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'app/theme_provider.dart';
import 'app/app.dart';
import 'services/supabase_service.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'firebase_options.dart';

import 'app/app_language.dart';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final supabaseAnonToken = SupabaseService.requiredSupabaseAnonToken;
  await Supabase.initialize(
    url: SupabaseService.supabaseUrl,
    anonKey: supabaseAnonToken,
  );

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  if (!foundation.kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await NotificationService.initialize();
    await PushNotificationService.initialize();
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => ThemeProvider()),
        ChangeNotifierProvider(create: (context) => AppLanguageProvider()),
      ],
      child: const RPStreamHubApp(),
    ),
  );
}
