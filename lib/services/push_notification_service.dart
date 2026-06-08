import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'notification_service.dart';
import 'supabase_service.dart';

void _respectSafeLog(Object error, [StackTrace? stackTrace]) {
  if (kDebugMode) {
    debugPrint('Respect safe catch: $error');
    if (stackTrace != null) debugPrintStack(stackTrace: stackTrace);
  }
}


class PushNotificationService {
  PushNotificationService._();

  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static bool _ready = false;

  static Future<void> initialize() async {
    if (_ready) return;

    await Firebase.initializeApp();
    await NotificationService.initialize();

    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      criticalAlert: true,
      announcement: false,
      carPlay: false,
      provisional: false,
    );

    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      await _handleRemoteMessage(message, fromTap: false);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
      await _handleRemoteMessage(message, fromTap: true);
    });

    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      Future.delayed(const Duration(milliseconds: 700), () async {
        await _handleRemoteMessage(initial, fromTap: true);
      });
    }

    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      await SupabaseService.updateCurrentUserFcmToken(token);
    });

    await registerTokenForCurrentUser();
    _ready = true;
  }

  static Future<void> registerTokenForCurrentUser() async {
    try {
      final token = await _messaging.getToken();
      if (token != null && token.trim().isNotEmpty) {
        await SupabaseService.updateCurrentUserFcmToken(token);
      }
    } catch (e, st) {
      _respectSafeLog(e, st);
    }
  }

  static Future<void> removeCurrentToken() async {
    try {
      await SupabaseService.updateCurrentUserFcmToken(null);
      await _messaging.deleteToken();
    } catch (e, st) { _respectSafeLog(e, st); }
  }

  static Future<void> _handleRemoteMessage(RemoteMessage message, {required bool fromTap}) async {
    final data = Map<String, dynamic>.from(message.data);
    if (data.isEmpty && message.notification != null) {
      data['type'] = data['type'] ?? 'message';
      data['title'] = message.notification?.title ?? '';
      data['body'] = message.notification?.body ?? '';
    }

    if (fromTap) {
      NotificationService.handlePayload(jsonEncode(_payloadFromData(data)));
    } else {
      await NotificationService.showFromFcmData(data);
    }
  }

  static Map<String, dynamic> _payloadFromData(Map<String, dynamic> data) {
    final type = data['type']?.toString();
    if (type == 'call') {
      return {
        'type': 'call',
        'callId': (data['callId'] ?? data['call_id'] ?? '').toString(),
        'callerUsername': (data['callerUsername'] ?? data['caller_username'] ?? '').toString(),
        'callerName': (data['callerName'] ?? data['caller_name'] ?? 'مستخدم').toString(),
        'callerAvatarPath': (data['callerAvatarPath'] ?? data['caller_avatar'] ?? '').toString(),
        'video': data['video']?.toString() == 'true' || data['call_type']?.toString() == 'video',
      };
    }
    return {
      'type': 'message',
      'peerUsername': (data['senderUsername'] ?? data['sender_username'] ?? data['peerUsername'] ?? '').toString(),
      'peerName': (data['senderName'] ?? data['sender_name'] ?? data['peerName'] ?? '').toString(),
    };
  }
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await NotificationService.initialize();
  await NotificationService.showFromFcmData(Map<String, dynamic>.from(message.data));
}
