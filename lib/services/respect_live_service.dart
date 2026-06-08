import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

class RespectLiveService {
  RespectLiveService._();

  static SupabaseClient get _client => SupabaseService.client;

  static String _cleanUsername(String value) => SupabaseService.displayUsername(value);

  static Future<Map<String, dynamic>?> currentUser() => SupabaseService.currentUser();

  static Future<List<Map<String, dynamic>>> getLiveStreams() async {
    final rows = await _client
        .from('respect_live_streams')
        .select()
        .eq('is_live', true)
        .order('viewers_count', ascending: false)
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(
      rows.map((e) => Map<String, dynamic>.from(e as Map)),
    );
  }

  static Future<Map<String, dynamic>?> getLiveStreamById(String streamId) async {
    try {
      final row = await _client
          .from('respect_live_streams')
          .select()
          .eq('id', streamId)
          .maybeSingle();
      if (row == null) return null;
      return Map<String, dynamic>.from(row as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> startLive({
    required String title,
    required bool video,
  }) async {
    final user = await currentUser();
    if (user == null) throw Exception('يجب تسجيل الدخول أولاً');

    final username = _cleanUsername((user['username'] ?? '').toString());
    final name = (user['name'] ?? user['profileName'] ?? username).toString();
    final avatar = (user['avatar_url'] ?? user['imagePath'] ?? user['profileImagePath'] ?? '').toString();

    await endMyActiveLives(username);

    final payload = <String, dynamic>{
      'host_username': username,
      'host_name': name,
      'host_avatar': avatar,
      'title': title.trim().isEmpty ? 'بث مباشر من Respect' : title.trim(),
      'is_live': true,
      'video_enabled': video,
      'viewers_count': 0,
      'started_at': DateTime.now().toUtc().toIso8601String(),
    };

    final inserted = await _client.from('respect_live_streams').insert(payload).select().single();
    return Map<String, dynamic>.from(inserted as Map);
  }

  static Future<void> endMyActiveLives(String username) async {
    await _client
        .from('respect_live_streams')
        .update({
      'is_live': false,
      'ended_at': DateTime.now().toUtc().toIso8601String(),
    })
        .eq('host_username', _cleanUsername(username))
        .eq('is_live', true);
  }

  static Future<void> endLive(String streamId) async {
    await _client
        .from('respect_live_streams')
        .update({
      'is_live': false,
      'ended_at': DateTime.now().toUtc().toIso8601String(),
    })
        .eq('id', streamId);
  }

  static Future<void> increaseViewer(String streamId) async {
    try {
      await _client.rpc('respect_live_add_viewer', params: {'p_stream_id': streamId});
      return;
    } catch (_) {}

    // Fallback لو دوال RPC غير موجودة في Supabase.
    try {
      final current = await getLiveStreamById(streamId);
      if (current == null) return;
      final count = int.tryParse((current['viewers_count'] ?? 0).toString()) ?? 0;
      await _client
          .from('respect_live_streams')
          .update({'viewers_count': count + 1})
          .eq('id', streamId)
          .eq('is_live', true);
    } catch (_) {}
  }

  static Future<void> decreaseViewer(String streamId) async {
    try {
      await _client.rpc('respect_live_remove_viewer', params: {'p_stream_id': streamId});
      return;
    } catch (_) {}

    // Fallback آمن يمنع نزول العدد تحت الصفر.
    try {
      final current = await getLiveStreamById(streamId);
      if (current == null) return;
      final count = int.tryParse((current['viewers_count'] ?? 0).toString()) ?? 0;
      await _client
          .from('respect_live_streams')
          .update({'viewers_count': count > 0 ? count - 1 : 0})
          .eq('id', streamId);
    } catch (_) {}
  }

  static Future<void> incrementLikes(String streamId) async {
    try {
      await _client.rpc('respect_live_add_like', params: {'p_stream_id': streamId});
      return;
    } catch (_) {}

    try {
      final current = await getLiveStreamById(streamId);
      if (current == null) return;
      final count = int.tryParse((current['likes_count'] ?? current['likes'] ?? 0).toString()) ?? 0;
      await _client
          .from('respect_live_streams')
          .update({'likes_count': count + 1})
          .eq('id', streamId);
    } catch (_) {
      // لو العمود غير موجود، سيبقى العداد المحلي والإشارة يعملان بدون كراش.
    }
  }

  static Future<List<Map<String, dynamic>>> getChatMessages(String streamId) async {
    final rows = await _client
        .from('respect_live_messages')
        .select()
        .eq('stream_id', streamId)
        .order('created_at', ascending: true)
        .limit(80);

    return List<Map<String, dynamic>>.from(
      rows.map((e) => Map<String, dynamic>.from(e as Map)),
    );
  }

  static Future<void> sendChatMessage({
    required String streamId,
    required String text,
  }) async {
    final user = await currentUser();
    if (user == null) throw Exception('يجب تسجيل الدخول أولاً');

    final cleanText = text.trim();
    if (cleanText.isEmpty) return;

    final username = _cleanUsername((user['username'] ?? '').toString());
    final name = (user['name'] ?? user['profileName'] ?? username).toString();
    final avatar = (user['avatar_url'] ?? user['imagePath'] ?? user['profileImagePath'] ?? '').toString();

    await _client.from('respect_live_messages').insert({
      'stream_id': streamId,
      'sender_username': username,
      'sender_name': name,
      'sender_avatar': avatar,
      'text': cleanText,
    });
  }

  static RealtimeChannel subscribeStreams({
    required void Function() onChanged,
  }) {
    return _client
        .channel('respect_live_streams_global')
        .onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'respect_live_streams',
      callback: (_) => onChanged(),
    )
        .subscribe();
  }

  static RealtimeChannel subscribeChat({
    required String streamId,
    required void Function(Map<String, dynamic> row) onMessage,
    required void Function(Map<String, dynamic> row) onStreamChanged,
  }) {
    return _client
        .channel('respect_live_chat_$streamId')
        .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'respect_live_messages',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'stream_id',
        value: streamId,
      ),
      callback: (payload) => onMessage(payload.newRecord),
    )
        .onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'respect_live_streams',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'id',
        value: streamId,
      ),
      callback: (payload) => onStreamChanged(Map<String, dynamic>.from(payload.newRecord)),
    )
        .subscribe();
  }

  static String _liveRoomId(String streamId) => 'respect_live_$streamId';

  static RealtimeChannel signalingChannel({
    required String streamId,
    required void Function(Map<String, dynamic> payload) onSignal,
  }) {
    return _client
        .channel('respect_live_signal_db_$streamId')
        .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'call_signals',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'room_id',
        value: _liveRoomId(streamId),
      ),
      callback: (payload) {
        final row = Map<String, dynamic>.from(payload.newRecord);
        final raw = row['payload'];
        final body = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        onSignal({
          'id': row['id']?.toString() ?? '',
          'stream_id': body['stream_id']?.toString() ?? streamId,
          'from': body['from']?.toString() ?? row['sender_id']?.toString() ?? '',
          'to': body['to']?.toString() ?? '',
          'type': row['type']?.toString() ?? body['type']?.toString() ?? '',
          'data': body['data'] is Map ? Map<String, dynamic>.from(body['data']) : <String, dynamic>{},
          'created_at': row['created_at']?.toString() ?? '',
        });
      },
    )
        .subscribe();
  }

  static Future<void> sendSignal({
    required RealtimeChannel channel,
    required String streamId,
    required String from,
    required String to,
    required String type,
    required Map<String, dynamic> data,
  }) async {
    await _client.from('call_signals').insert({
      'room_id': _liveRoomId(streamId),
      'sender_id': from,
      'type': type,
      'payload': {
        'stream_id': streamId,
        'from': from,
        'to': to,
        'type': type,
        'data': data,
      },
    });
  }

  static Future<void> sendLiveEvent({
    required RealtimeChannel? channel,
    required String streamId,
    required String from,
    required String type,
    Map<String, dynamic> data = const <String, dynamic>{},
    String to = '*',
  }) async {
    final ch = channel;
    if (ch == null) return;
    await sendSignal(
      channel: ch,
      streamId: streamId,
      from: from,
      to: to,
      type: type,
      data: data,
    );
  }
}
