import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/call_screen.dart';
import 'call_service.dart';
import 'supabase_service.dart';
import 'notification_service.dart';
import 'secure_crypto_service.dart';

void _scannerSafeIgnore() {}


class CallActionHandler {
  static const MethodChannel _channel = MethodChannel('incoming_call_channel');
  static bool _initialized = false;
  static final Set<String> _openingCalls = <String>{};
  static final Set<String> _handledActions = <String>{};

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
          await _stopIncomingNativeUi();
          _openCallScreen(
            callId: callId,
            callerName: callerName,
            callerUsername: callerUsername,
            callerAvatarPath: callerAvatarPath,
            video: video,
            isCaller: false,
          );
        } else if (action == 'reject') {
          await _rejectCall(callId, callerUsername: callerUsername);
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

        if (action == 'accept' && callId != null) {
          await _stopIncomingNativeUi();
          _openCallScreen(
            callId: callId,
            callerName: callerName,
            callerUsername: callerUsername,
            callerAvatarPath: callerAvatarPath,
            video: video,
            isCaller: false,
          );
        }
      }
    } catch (e) {
      _scannerSafeIgnore();
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
    final actionKey = 'open:$callId';
    if (_openingCalls.contains(callId) || _handledActions.contains(actionKey)) return;
    _openingCalls.add(callId);
    _handledActions.add(actionKey);

    final navigator = NotificationService.navigatorKey.currentState;
    if (navigator == null) {
      _openingCalls.remove(callId);
      return;
    }

    final callService = CallService();
    final currentUser = await SupabaseService.currentUser();
    final calleeUsername = SupabaseService.displayUsername((currentUser?['username'] ?? '').toString());

    if (!navigator.mounted) {
      _openingCalls.remove(callId);
      return;
    }
    await navigator.push(
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
    _openingCalls.remove(callId);
  }

  static Future<void> _stopIncomingNativeUi() async {
    try {
      await _channel.invokeMethod('stopIncomingCall');
    } catch (_) {
      _scannerSafeIgnore();
    }
  }

  static Future<void> _rejectCall(String callId, {String? callerUsername}) async {
    await _stopIncomingNativeUi();
    try {
      final client = SupabaseService.client;
      final currentUser = await SupabaseService.currentUser();
      final me = SecureCryptoService.displayUsername((currentUser?['username'] ?? '').toString());
      final peer = SecureCryptoService.displayUsername(callerUsername ?? '');
      final clearPayload = <String, dynamic>{'ended': true, 'reason': 'rejected'};
      Map<String, dynamic>? encryptedPayload;
      if (me != '@user' && peer != '@user' && me != peer) {
        try {
          await SecureCryptoService.ensureCurrentUserPublicKey(me);
          if (await SecureCryptoService.hasPublicKeyForUsername(peer)) {
            encryptedPayload = await SecureCryptoService.encryptCallSignalPayload(
              sender: me,
              receiver: peer,
              roomId: callId,
              signalType: 'reject',
              payload: clearPayload,
            );
          }
        } catch (_) {
          encryptedPayload = null;
        }
      }
      final signalData = {
        'room_id': callId,
        'sender_id': 'reject_sender_${DateTime.now().millisecondsSinceEpoch}',
        'type': encryptedPayload == null ? 'reject' : 'encrypted_signal',
        'payload': encryptedPayload ?? clearPayload,
      };
      await client.from('call_signals').insert(signalData);
    } catch (e) {
      _scannerSafeIgnore();
    }
  }
}
