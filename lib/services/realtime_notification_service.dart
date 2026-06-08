import 'package:supabase_flutter/supabase_flutter.dart';

import 'notification_service.dart';
import 'supabase_service.dart';

void _scannerSafeIgnore([Object? error, StackTrace? stackTrace]) {}


class RealtimeNotificationService {
  RealtimeNotificationService._();

  static RealtimeChannel? _channel;
  static String? _currentUsername;
  static final Set<String> _handledMessages = <String>{};
  static final Set<String> _handledCalls = <String>{};
  static final Set<String> _handledPosts = <String>{};
  static final Set<String> _handledPostEvents = <String>{};

  static Future<void> start() async {
    final user = await SupabaseService.currentUser();
    if (user == null) return;

    final username = SupabaseService.displayUsername((user['username'] ?? '').toString());
    if (_currentUsername == username && _channel != null) return;

    await stop();
    _currentUsername = username;

    final channelName = SupabaseService.realtimeUserChannel(username);
    _channel = SupabaseService.client
        .channel('global_$channelName')
        .onBroadcast(
      event: 'new_message',
      callback: (payload) async {
        final raw = payload['message'];
        if (raw is Map) await _handleMessage(Map<String, dynamic>.from(raw));
      },
    )
        .onBroadcast(
      event: 'incoming_call',
      callback: (payload) async => _handleCall(Map<String, dynamic>.from(payload)),
    )
        .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'messages',
      callback: (payload) async => _handleMessage(payload.newRecord),
    )
        .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'posts',
      callback: (payload) async => _handlePost(payload.newRecord),
    )
        .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'post_events',
      callback: (payload) async => _handlePostEvent(payload.newRecord),
    )
        .subscribe();
  }

  static Future<void> stop() async {
    final channel = _channel;
    _channel = null;
    _currentUsername = null;
    if (channel != null) await channel.unsubscribe();
  }

  static Future<void> _handleMessage(Map<String, dynamic> row) async {
    final me = SupabaseService.displayUsername(_currentUsername ?? '');
    final sender = SupabaseService.displayUsername((row['sender_username'] ?? '').toString());
    final receiver = SupabaseService.displayUsername((row['receiver_username'] ?? '').toString());
    if (receiver != me || sender == me) return;

    final id = (row['id'] ?? '${sender}_${DateTime.now().millisecondsSinceEpoch}').toString();
    if (_handledMessages.contains(id)) return;
    _handledMessages.add(id);

    final senderUser = await SupabaseService.getUserByUsername(sender);
    final senderName = (senderUser?['name'] ?? senderUser?['profileName'] ?? sender).toString();

    await NotificationService.showMessageNotification(
      messageId: id,
      senderUsername: sender,
      senderName: senderName,
      text: (row['text'] ?? '').toString(),
    );
  }


  static Future<void> _handlePostEvent(Map<String, dynamic> row) async {
    final me = SupabaseService.displayUsername(_currentUsername ?? '');
    final target = SupabaseService.displayUsername((row['target_username'] ?? '').toString());
    if (target != me) return;

    final id = (row['id'] ?? '${row['type']}_${row['post_id']}_${DateTime.now().millisecondsSinceEpoch}').toString();
    if (_handledPostEvents.contains(id)) return;
    _handledPostEvents.add(id);

    final type = (row['type'] ?? 'post_event').toString();
    final text = (row['text'] ?? '').toString();
    await NotificationService.showFromFcmData({
      'type': type,
      'eventType': type,
      'postId': (row['post_id'] ?? '').toString(),
      'title': type == 'report_accepted_owner'
          ? 'تم حذف تغريدتك'
          : (type == 'report_accepted_reporter' || type == 'community_report_accepted')
          ? 'تم قبول البلاغ'
          : 'نتيجة البلاغ',
      'body': text,
      'text': text,
    });
  }

  static Future<void> _handlePost(Map<String, dynamic> row) async {
    final me = SupabaseService.displayUsername(_currentUsername ?? '');
    final author = SupabaseService.displayUsername((row['username'] ?? '').toString());
    if (author == '@user' || author == me) return;

    final enabledTargets = await SupabaseService.getEnabledPostNotificationTargets(me);
    if (!enabledTargets.contains(author)) return;

    final id = (row['id'] ?? '${author}_${DateTime.now().millisecondsSinceEpoch}').toString();
    if (_handledPosts.contains(id)) return;
    _handledPosts.add(id);

    Map<String, dynamic>? authorUser;
    try { authorUser = await SupabaseService.getUserByUsername(author); } catch (_) { _scannerSafeIgnore(); }
    final authorName = (authorUser?['name'] ?? authorUser?['profileName'] ?? row['name'] ?? row['user'] ?? author).toString();

    await NotificationService.showPostNotification(
      postId: id,
      authorUsername: author,
      authorName: authorName,
      text: (row['text'] ?? '').toString(),
    );
  }

  static Future<void> _handleCall(Map<String, dynamic> payload) async {
    final callId = payload['call_id']?.toString();
    if (callId == null || callId.trim().isEmpty) return;
    if (_handledCalls.contains(callId)) return;
    _handledCalls.add(callId);

    final callerUsername = SupabaseService.displayUsername((payload['caller_username'] ?? '').toString());
    final callerName = (payload['caller_name'] ?? callerUsername).toString();
    final callerAvatar = payload['caller_avatar']?.toString();
    final video = _payloadBool(payload['video']) ||
        _payloadBool(payload['is_video']) ||
        payload['call_type']?.toString() == 'video' ||
        payload['kind']?.toString() == 'video';

    await NotificationService.showIncomingCallNotification(
      callId: callId,
      callerUsername: callerUsername,
      callerName: callerName,
      callerAvatarPath: callerAvatar,
      video: video,
    );
  }

  static bool _payloadBool(dynamic value) {
    if (value == true) return true;
    final text = value?.toString().toLowerCase().trim();
    return text == 'true' || text == '1' || text == 'yes' || text == 'video';
  }
}
