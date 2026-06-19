import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'notification_service.dart';
import 'supabase_service.dart';

void _scannerSafeIgnore() {}

void _respectSafeLog(Object error, [StackTrace? stackTrace]) {
  if (kDebugMode) {
    _scannerSafeIgnore();
    if (stackTrace != null) _scannerSafeIgnore();
  }
}

Future<void> _ensureFirebaseReady() async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
}

class PushNotificationService {
  PushNotificationService._();

  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static bool _ready = false;
  static bool _backgroundHandlerRegistered = false;
  static StreamSubscription<RemoteMessage>? _foregroundSub;
  static StreamSubscription<RemoteMessage>? _openedSub;
  static StreamSubscription<String>? _tokenRefreshSub;

  /// استدعها مبكرًا جدًا في main.dart قبل runApp قدر الإمكان.
  /// وجودها هنا أيضًا داخل initialize يمنع نسيان التسجيل في أغلب الحالات.
  static void registerBackgroundHandler() {
    if (_backgroundHandlerRegistered) return;
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    _backgroundHandlerRegistered = true;
  }

  static Future<void> initialize() async {
    if (_ready) {
      await syncDeviceAndToken();
      return;
    }

    registerBackgroundHandler();
    await _ensureFirebaseReady();
    await NotificationService.initialize();

    try {
      await SupabaseService.touchCurrentDeviceForCurrentUser();
    } catch (e, st) {
      _respectSafeLog(e, st);
    }

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

    await _foregroundSub?.cancel();
    _foregroundSub = FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      await _handleRemoteMessage(message, fromTap: false);
    });

    await _openedSub?.cancel();
    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
      await _handleRemoteMessage(message, fromTap: true);
    });

    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      Future.delayed(const Duration(milliseconds: 700), () async {
        await _handleRemoteMessage(initial, fromTap: true);
      });
    }

    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      await _syncDevicePushToken(token);
    });

    await syncDeviceAndToken();
    _ready = true;
  }

  /// يستدعى بعد تسجيل الدخول/تغيير الحساب حتى لا يبقى المستخدم بدون FCM token أو device id.
  static Future<void> syncDeviceAndToken() async {
    try {
      await SupabaseService.touchCurrentDeviceForCurrentUser();
    } catch (e, st) {
      _respectSafeLog(e, st);
    }
    await registerTokenForCurrentUser();
  }

  static Future<void> _syncDevicePushToken(String? token) {
    return SupabaseService.updateCurrentUserFcmToken(token);
  }

  static Future<void> registerTokenForCurrentUser() async {
    // على iOS يحتاج APNS token قبل FCM token، وعلى Android أحيانًا أول محاولة ترجع null.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (!kIsWeb && Platform.isIOS) {
          await _messaging.getAPNSToken();
        }
        final token = await _messaging.getToken();
        if (token != null && token.trim().isNotEmpty) {
          await _syncDevicePushToken(token.trim());
          return;
        }
      } catch (e, st) {
        _respectSafeLog(e, st);
      }
      await Future<void>.delayed(Duration(milliseconds: 450 + (attempt * 550)));
    }
  }

  static Future<void> removeCurrentToken() async {
    try {
      final token = await _messaging.getToken();
      await _syncDevicePushToken(null);
      if (token != null && token.trim().isNotEmpty) {
        await SupabaseService.clearFcmTokenValue(token.trim());
      }
      await _messaging.deleteToken();
    } catch (e, st) { _respectSafeLog(e, st); }
  }

  static Future<void> _handleRemoteMessage(RemoteMessage message, {required bool fromTap}) async {
    final data = _mergedData(message);

    if (fromTap) {
      NotificationService.handlePayload(jsonEncode(_payloadFromData(data)));
    } else {
      await NotificationService.showFromFcmData(data);
    }
  }

  static Map<String, dynamic> _mergedData(RemoteMessage message) {
    final data = Map<String, dynamic>.from(message.data);
    final notification = message.notification;
    if (notification != null) {
      data['title'] = (data['title'] ?? data['localizedTitle'] ?? notification.title ?? '').toString();
      data['body'] = (data['body'] ?? data['localizedBody'] ?? notification.body ?? '').toString();
    }
    data['type'] = (data['type'] ?? _fallbackTypeFromNotification(notification)).toString();
    return data;
  }

  static String _fallbackTypeFromNotification(RemoteNotification? notification) {
    final title = (notification?.title ?? '').toLowerCase();
    final body = (notification?.body ?? '').toLowerCase();
    if (title.contains('call') || body.contains('call') || title.contains('مكالمة') || body.contains('مكالمة')) return 'call';
    return 'message';
  }

  static Map<String, dynamic> _payloadFromData(Map<String, dynamic> data) {
    final type = data['type']?.toString();
    if (type == 'general_notification' || type == 'general') {
      return {
        'type': 'general_notification',
        'id': (data['id'] ?? data['notificationId'] ?? data['notification_id'] ?? '').toString(),
        'title': (data['localizedTitle'] ?? data['title'] ?? 'Respect').toString(),
        'body': (data['localizedBody'] ?? data['body'] ?? data['text'] ?? '').toString(),
      };
    }
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
  await _ensureFirebaseReady();
  await NotificationService.initialize();
  final data = Map<String, dynamic>.from(message.data);
  final notification = message.notification;
  if (notification != null) {
    // Android/iOS يعرضان notification payload تلقائيًا بالخلفية، لذلك لا نكرر إشعارًا محليًا.
    return;
  }
  data['type'] = (data['type'] ?? 'message').toString();

  // احتياط data-only: يظهر كإشعار محلي عندما لا يوجد notification payload.
  await NotificationService.showFromFcmData(data);
}
