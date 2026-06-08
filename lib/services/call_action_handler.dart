import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/call_screen.dart';
import 'call_service.dart';
import 'supabase_service.dart';
import 'notification_service.dart';   // <-- import المفقود

class CallActionHandler {
  static const MethodChannel _channel = MethodChannel('incoming_call_channel');
  static bool _initialized = false;

  static void initialize() {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler(_handleMethodCall);
    _consumePendingAction();
  }

  static Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onCallAction':
        final args = call.arguments as Map<dynamic, dynamic>;
        final action = args['action'] as String?;
        final callId = args['callId'] as String?;
        final callerName = args['callerName'] as String? ?? 'مستخدم';
        final callerUsername = args['callerUsername'] as String? ?? '';
        final callerAvatarPath = args['callerAvatarPath'] as String?;
        final video = args['video'] as bool? ?? false;

        if (action == null || callId == null) return;

        if (action == 'accept') {
          _openCallScreen(
            callId: callId,
            callerName: callerName,
            callerUsername: callerUsername,
            callerAvatarPath: callerAvatarPath,
            video: video,
            isCaller: false,
          );
        } else if (action == 'reject') {
          await _rejectCall(callId);
        }
        break;

      default:
        break;
    }
  }

  static Future<void> _consumePendingAction() async {
    try {
      final result = await _channel.invokeMethod('consumePendingCallAction');
      if (result != null) {
        final args = result as Map<dynamic, dynamic>;
        final action = args['action'] as String?;
        final callId = args['callId'] as String?;
        final callerName = args['callerName'] as String? ?? 'مستخدم';
        final callerUsername = args['callerUsername'] as String? ?? '';
        final callerAvatarPath = args['callerAvatarPath'] as String?;
        final video = args['video'] as bool? ?? false;

        if (action == 'accept') {
          _openCallScreen(
            callId: callId!,
            callerName: callerName,
            callerUsername: callerUsername,
            callerAvatarPath: callerAvatarPath,
            video: video,
            isCaller: false,
          );
        }
      }
    } catch (e) {
      debugPrint('Error consuming pending call action: $e');
    }
  }

  static Future<void> _openCallScreen({
    required String callId,
    required String callerName,
    required String callerUsername,
    String? callerAvatarPath,
    required bool video,
    required bool isCaller,
  }) async {
    final navigatorKey = NotificationService.navigatorKey;
    final context = navigatorKey.currentContext;
    if (context == null) return;

    final callService = CallService();
    final currentUser = await SupabaseService.currentUser();
    final calleeUsername = SupabaseService.displayUsername((currentUser?['username'] ?? '').toString());

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          callId: callId,
          peerName: callerName,
          peerAvatarPath: callerAvatarPath,
          video: video,
          isCaller: isCaller,
          callService: callService,
          callerName: callerName,
          callerUsername: callerUsername,
          calleeUsername: calleeUsername,
        ),
      ),
    );
  }

  static Future<void> _rejectCall(String callId) async {
    try {
      final client = SupabaseService.client;
      final signalData = {
        'room_id': callId,
        'sender_id': 'reject_sender_${DateTime.now().millisecondsSinceEpoch}',
        'type': 'end',
        'payload': {'ended': true},
      };
      await client.from('call_signals').insert(signalData);
    } catch (e) {
      debugPrint('Error sending reject signal: $e');
    }
  }
}