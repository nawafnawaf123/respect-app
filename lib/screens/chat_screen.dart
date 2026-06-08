import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'call_screen.dart';

import '../services/call_service.dart';
import '../services/supabase_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';

void _logIgnoredError(Object error, StackTrace stackTrace) {
  assert(() {
    debugPrint('Ignored recoverable error: $error');
    return true;
  }());
}


class ChatScreen extends StatefulWidget {
  final String? peerUsername;
  final String? peerName;
  final String? peerAvatarPath;
  final String? groupId;
  final ValueChanged<bool>? onConversationActiveChanged;

  const ChatScreen({
    super.key,
    this.peerUsername,
    this.peerName,
    this.peerAvatarPath,
    this.groupId,
    this.onConversationActiveChanged,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final TextEditingController _msgCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final AudioRecorder _voiceRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription<Duration>? _voicePositionSub;
  StreamSubscription<Duration>? _voiceDurationSub;
  StreamSubscription<void>? _voiceCompleteSub;
  Timer? _voiceAmplitudeTimer;

  String _currentUsername = '@user';
  String _currentName = 'User';
  String? _currentAvatarPath;

  String? _activePeerUsername;
  String? _activePeerName;
  String? _activePeerAvatarPath;
  String? _activeGroupId;
  String? _activeGroupName;
  String? _activeGroupAvatar;
  bool _activeGroupLocked = false;
  bool _activeGroupFounder = false;
  bool _activeGroupAdmin = false;

  List<Map<String, dynamic>> _users = [];
  List<_ChatThread> _threads = [];
  List<_DirectMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  bool _peerTyping = false;
  String _peerTypingMode = 'text';
  bool _recordingVoice = false;
  bool _lockedVoiceRecording = false;
  bool _voicePaused = false;
  bool _longPressVoiceStarted = false;
  bool _sendingVoice = false;
  bool _sendingMedia = false;
  final List<_PendingChatMedia> _pendingMedia = <_PendingChatMedia>[];
  int _pendingMediaMaxViews = 0;
  DateTime? _voiceRecordStartedAt;
  Duration _voicePausedElapsed = Duration.zero;
  String? _playingVoiceUrl;
  Duration _voicePosition = Duration.zero;
  Duration _voiceDuration = Duration.zero;
  double _voiceSpeed = 1.0;
  String? _pendingVoicePath;
  int _pendingVoiceSeconds = 0;
  List<double> _pendingVoiceWaveform = <double>[];
  final Map<String, List<double>> _voiceWaveformCache = <String, List<double>>{};
  List<double> _recordingVoiceWaveform = <double>[];
  bool _recordingFinishingForPreview = false;
  String? _typingName;

  RealtimeChannel? _messagesChannel;
  final CallService _callService = CallService();
  final Set<String> _shownIncomingCallIds = <String>{};
  Timer? _typingStopTimer;
  Timer? _typingSendDebounce;
  Timer? _typingIdleTimer;
  Timer? _voiceTypingKeepAliveTimer;
  Timer? _liveRefreshTimer;
  bool _silentRefreshing = false;

  final Set<String> _selectedMessageIds = <String>{};
  final Set<String> _locallyDeletedMessageIds = <String>{};
  _DirectMessage? _replyToMessage;
  _DirectMessage? _editingMessage;
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  String? _highlightMessageId;
  Timer? _highlightTimer;

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;
  List<_DirectMessage> get _selectedMessages => _activeMessages.where((m) => _selectedMessageIds.contains(m.id)).toList();
  bool get _canDeleteSelectedMessages => _selectedMessages.isNotEmpty && _selectedMessages.every((m) => m.senderUsername == _currentUsername);
  bool get _canEditSelectedMessage => _selectedMessages.length == 1 && _selectedMessages.first.senderUsername == _currentUsername && !_selectedMessages.first.hasVisualMedia && !_selectedMessages.first.isVoice;

  bool get _isGroup => _activeGroupId != null;
  bool get _canSend => !_isGroup || !_activeGroupLocked || _activeGroupFounder || _activeGroupAdmin;
  String get _conversationTitle => _isGroup ? (_activeGroupName ?? 'مجموعة') : (_activePeerName ?? _activePeerUsername ?? 'الرسائل');
  String get _conversationSubtitle {
    if (_isGroup) {
      if (_activeGroupLocked) return _canSend ? 'الدردشة مقفلة - المشرفون فقط' : 'الدردشة مقفلة';
      return _activeGroupAdmin || _activeGroupFounder ? 'مشرف في المجموعة' : 'مجموعة';
    }
    if (_peerTyping) {
      final name = _typingName ?? _activePeerName ?? 'المستخدم';
      return _peerTypingMode == 'voice' ? '$name يسجل رسالة صوتية...' : '$name يكتب الآن...';
    }
    return _activePeerUsername ?? '';
  }

  bool get _hasActiveConversation => _activePeerUsername != null || _activeGroupId != null;

  void _notifyConversationActive(bool active) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onConversationActiveChanged?.call(active);
    });
  }

  void _syncConversationActiveState() {
    _notifyConversationActive(_hasActiveConversation);
  }

  @override
  void initState() {
    super.initState();
    _activePeerUsername = widget.peerUsername == null ? null : SupabaseService.displayUsername(widget.peerUsername!);
    _activePeerName = widget.peerName;
    _activePeerAvatarPath = widget.peerAvatarPath;
    _activeGroupId = widget.groupId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncConversationActiveState());
    _msgCtrl.addListener(_onTextChanged);
    _voicePositionSub = _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _voicePosition = p);
    });
    _voiceDurationSub = _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _voiceDuration = d);
    });
    _voiceCompleteSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playingVoiceUrl = null;
          _voicePosition = Duration.zero;
        });
      }
    });
    _loadAll();
  }

  @override
  void dispose() {
    widget.onConversationActiveChanged?.call(false);
    _messagesChannel?.unsubscribe();
    _msgCtrl.removeListener(_onTextChanged);
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _typingStopTimer?.cancel();
    _typingSendDebounce?.cancel();
    _typingIdleTimer?.cancel();
    _voiceTypingKeepAliveTimer?.cancel();
    _voiceAmplitudeTimer?.cancel();
    _liveRefreshTimer?.cancel();
    _highlightTimer?.cancel();
    _audioPlayer.dispose();
    _voiceRecorder.dispose();
    _callService.dispose();
    super.dispose();
  }

  ImageProvider? _fileImage(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    if (path.startsWith('http')) return NetworkImage(path);
    final file = File(path);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  Future<void> _loadAll() async {
    if (mounted) setState(() => _loading = true);
    try {
      final current = await SupabaseService.currentUser();
      if (current != null) {
        _currentUsername = SupabaseService.displayUsername((current['username'] ?? '').toString());
        _currentName = (current['name'] ?? current['profileName'] ?? _currentUsername).toString();
        _currentAvatarPath = (current['avatar_url'] ?? current['imagePath'] ?? current['profileImagePath'])?.toString();
      }

      final users = await SupabaseService.getUsers();
      final directInbox = await SupabaseService.getInboxMessages(_currentUsername);
      final groupInbox = await SupabaseService.getMyChatGroups(_currentUsername);
      final threads = <_ChatThread>[
        ..._buildThreadsFromMessages(directInbox, users),
        ...groupInbox.map(_ChatThread.fromGroup),
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      _users = users;
      _threads = threads;

      await _loadLocallyDeletedMessages();

      if (_activeGroupId != null) {
        await _openGroupById(_activeGroupId!, setLoading: false);
      } else if (_activePeerUsername != null) {
        final peer = _accountByUsername(users, _activePeerUsername!);
        _activePeerName ??= (peer?['name'] ?? peer?['profileName'] ?? _activePeerUsername).toString();
        _activePeerAvatarPath ??= (peer?['avatar_url'] ?? peer?['imagePath'] ?? peer?['profileImagePath'])?.toString();
        final rows = await SupabaseService.getMessagesBetween(_currentUsername, _activePeerUsername!);
        _messages = rows.map(_DirectMessage.fromSupabase).where((m) => !_locallyDeletedMessageIds.contains(m.id)).toList();
        await _markVisibleMessagesRead();
      }

      if (!mounted) return;
      setState(() => _loading = false);
      _syncConversationActiveState();
      _subscribeToRealtime();
      _startLiveRefreshLoop();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      NotificationService.showTopNotification('خطأ الاتصال بالسيرفر: $e');
    }
  }

  void _subscribeToRealtime() {
    _messagesChannel?.unsubscribe();
    final meChannel = SupabaseService.realtimeUserChannel(_currentUsername);
    _messagesChannel = SupabaseService.client.channel(meChannel)
      ..onBroadcast(event: 'new_message', callback: (payload) async {
        final raw = payload['message'];
        if (raw is Map) await _handleIncomingMessage(Map<String, dynamic>.from(raw));
      })
      ..onBroadcast(event: 'group_message', callback: (payload) async {
        final raw = payload['message'];
        if (raw is Map) await _handleIncomingGroupMessage(Map<String, dynamic>.from(raw));
      })
      ..onBroadcast(event: 'message_status', callback: (payload) async => _handleMessageStatus(Map<String, dynamic>.from(payload)))
      ..onBroadcast(event: 'typing', callback: (payload) => _handleTyping(Map<String, dynamic>.from(payload)))
      ..onBroadcast(event: 'group_updated', callback: (_) async => _refreshThreadsOnly())
      ..onBroadcast(event: 'incoming_call', callback: (payload) {
        final callId = payload['call_id']?.toString();
        if (callId == null || callId.isEmpty || _shownIncomingCallIds.contains(callId)) return;
        _shownIncomingCallIds.add(callId);
        final callerUsername = SupabaseService.displayUsername((payload['caller_username'] ?? '').toString());
        final video = _payloadBool(payload['video']) || _payloadBool(payload['is_video']) || payload['call_type']?.toString() == 'video';
        NotificationService.showIncomingCallNotification(
          callId: callId,
          callerUsername: callerUsername,
          callerName: payload['caller_name']?.toString() ?? callerUsername,
          callerAvatarPath: payload['caller_avatar']?.toString(),
          video: video,
        );
        Future.delayed(const Duration(minutes: 2), () => _shownIncomingCallIds.remove(callId));
      })
      ..onPostgresChanges(event: PostgresChangeEvent.insert, schema: 'public', table: 'messages', callback: (payload) async {
        await _handleIncomingMessage(payload.newRecord);
      })
      ..onPostgresChanges(event: PostgresChangeEvent.insert, schema: 'public', table: 'respect_group_messages', callback: (payload) async {
        await _handleIncomingGroupMessage(payload.newRecord);
      })
      ..subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          _refreshActiveConversationSilently(scroll: false);
        }
      });
  }

  void _startLiveRefreshLoop() {
    _liveRefreshTimer?.cancel();
    _liveRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      if (_activePeerUsername == null && _activeGroupId == null) return;
      unawaited(_refreshActiveConversationSilently(scroll: false));
    });
  }

  Future<void> _refreshActiveConversationSilently({bool scroll = false}) async {
    if (_silentRefreshing || !mounted) return;
    final activeGroup = _activeGroupId;
    final activePeer = _activePeerUsername;
    if (activeGroup == null && activePeer == null) return;

    _silentRefreshing = true;
    try {
      List<_DirectMessage> freshMessages;
      if (activeGroup != null) {
        final rows = await SupabaseService.getGroupMessages(activeGroup);
        freshMessages = rows.map(_DirectMessage.fromGroupSupabase).where((m) => !_locallyDeletedMessageIds.contains(m.id)).toList();
      } else {
        final rows = await SupabaseService.getMessagesBetween(_currentUsername, activePeer!);
        freshMessages = rows.map(_DirectMessage.fromSupabase).where((m) => !_locallyDeletedMessageIds.contains(m.id)).toList();
      }

      if (!mounted) return;
      final oldIds = _messages.map((m) => m.id).toSet();
      final hasNew = freshMessages.any((m) => !oldIds.contains(m.id));
      final sameConversation = activeGroup == _activeGroupId && activePeer == _activePeerUsername;
      if (!sameConversation) return;

      setState(() {
        if (activeGroup != null) {
          _messages = [
            ..._messages.where((m) => m.groupId != activeGroup),
            ...freshMessages,
          ];
        } else {
          final me = SupabaseService.displayUsername(_currentUsername);
          final peer = SupabaseService.displayUsername(activePeer!);
          _messages = [
            ..._messages.where((m) => !((m.senderUsername == me && m.receiverUsername == peer) || (m.senderUsername == peer && m.receiverUsername == me))),
            ...freshMessages,
          ];
        }
      });

      if (hasNew || scroll) {
        await _markVisibleMessagesRead();
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } catch (_) {
      // fallback صامت: لو Realtime تأخر أو الانترنت ضعيف لا نزعج المستخدم.
    } finally {
      _silentRefreshing = false;
    }
  }

  Future<void> _handleIncomingMessage(Map<String, dynamic> row) async {
    final sender = SupabaseService.displayUsername((row['sender_username'] ?? '').toString());
    final receiver = SupabaseService.displayUsername((row['receiver_username'] ?? '').toString());
    final me = SupabaseService.displayUsername(_currentUsername);
    final peer = _activePeerUsername == null ? null : SupabaseService.displayUsername(_activePeerUsername!);
    if (sender != me && receiver != me) return;

    final msg = _DirectMessage.fromSupabase(row);
    final isOpen = !_isGroup && peer != null && ((sender == me && receiver == peer) || (sender == peer && receiver == me));

    if (sender != me) {
      await SupabaseService.markMessageDelivered(msg.id, me);
      if (isOpen) await SupabaseService.markMessageRead(msg.id, me);
    }

    if (sender != me && !isOpen) {
      final senderUser = _accountByUsername(_users, sender);
      await NotificationService.showMessageNotification(
        messageId: msg.id,
        senderUsername: sender,
        senderName: (senderUser?['name'] ?? senderUser?['profileName'] ?? sender).toString(),
        text: msg.text,
      );
    }

    if (!mounted) return;
    if (isOpen && !_messages.any((m) => m.id == msg.id)) {
      setState(() => _messages.add(msg.copyWith(status: sender == me ? msg.status : MessageStatus.read)));
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    await _refreshThreadsOnly();
  }

  Future<void> _handleIncomingGroupMessage(Map<String, dynamic> row) async {
    final groupId = (row['group_id'] ?? '').toString();
    if (groupId.isEmpty) return;
    final msg = _DirectMessage.fromGroupSupabase(row);
    final isOpen = _isGroup && _activeGroupId == groupId;

    if (msg.senderUsername != _currentUsername) {
      await SupabaseService.markGroupMessageDelivered(msg.id, _currentUsername);
      if (isOpen) await SupabaseService.markGroupMessageRead(msg.id, _currentUsername);
    }

    if (!mounted) return;
    if (isOpen && !_messages.any((m) => m.id == msg.id)) {
      setState(() => _messages.add(msg));
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    await _refreshThreadsOnly();
  }

  void _handleMessageStatus(Map<String, dynamic> payload) {
    final id = payload['message_id']?.toString();
    if (id == null || id.isEmpty) return;
    final status = MessageStatusX.fromText(payload['status']?.toString());
    if (!mounted) return;
    setState(() {
      _messages = _messages.map((m) => m.id == id ? m.copyWith(status: status) : m).toList();
    });
  }

  void _handleTyping(Map<String, dynamic> payload) {
    final from = SupabaseService.displayUsername((payload['from'] ?? '').toString());
    if (from == _currentUsername) return;
    final groupId = payload['group_id']?.toString();
    final peer = payload['peer']?.toString();
    final related = _isGroup
        ? groupId == _activeGroupId
        : SupabaseService.displayUsername(peer ?? from) == _activePeerUsername || from == _activePeerUsername;
    if (!related || !mounted) return;

    final typing = _payloadBool(payload['typing']);
    final mode = (payload['mode'] ?? payload['typing_mode'] ?? 'text').toString().toLowerCase().trim();

    setState(() {
      _peerTyping = typing;
      _peerTypingMode = mode == 'voice' ? 'voice' : 'text';
      _typingName = payload['name']?.toString() ?? callerNameFromUsername(from);
    });

    _typingStopTimer?.cancel();
    if (typing) {
      _typingStopTimer = Timer(Duration(seconds: _peerTypingMode == 'voice' ? 5 : 3), () {
        if (mounted) setState(() => _peerTyping = false);
      });
    }
  }

  Future<void> _refreshThreadsOnly() async {
    final inbox = await SupabaseService.getInboxMessages(_currentUsername);
    final groups = await SupabaseService.getMyChatGroups(_currentUsername);
    final threads = <_ChatThread>[
      ..._buildThreadsFromMessages(inbox, _users),
      ...groups.map(_ChatThread.fromGroup),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!mounted) return;
    setState(() => _threads = threads);
  }

  Map<String, dynamic>? _accountByUsername(List<Map<String, dynamic>> accounts, String username) {
    final clean = SupabaseService.displayUsername(username);
    for (final a in accounts) {
      final u = SupabaseService.displayUsername((a['username'] ?? '').toString());
      if (u == clean) return a;
    }
    return null;
  }

  List<_ChatThread> _buildThreadsFromMessages(List<Map<String, dynamic>> rows, List<Map<String, dynamic>> users) {
    final map = <String, _ChatThread>{};
    final me = SupabaseService.displayUsername(_currentUsername);
    for (final row in rows) {
      final sender = SupabaseService.displayUsername((row['sender_username'] ?? '').toString());
      final receiver = SupabaseService.displayUsername((row['receiver_username'] ?? '').toString());
      final peer = sender == me ? receiver : sender;
      final id = SupabaseService.threadId(me, peer);
      if (map.containsKey(id)) continue;
      final peerAccount = _accountByUsername(users, peer);
      map[id] = _ChatThread(
        id: id,
        peerUsername: peer,
        peerName: (peerAccount?['name'] ?? peerAccount?['profileName'] ?? peer).toString(),
        peerAvatarPath: (peerAccount?['avatar_url'] ?? peerAccount?['imagePath'] ?? peerAccount?['profileImagePath'])?.toString(),
        lastMessage: (row['text'] ?? '').toString(),
        updatedAt: (row['created_at'] ?? DateTime.now().toIso8601String()).toString(),
      );
    }
    return map.values.toList();
  }

  List<_DirectMessage> get _activeMessages {
    if (_isGroup) {
      return _messages.where((m) => m.groupId == _activeGroupId).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    final peer = _activePeerUsername;
    if (peer == null) return [];
    final me = SupabaseService.displayUsername(_currentUsername);
    final p = SupabaseService.displayUsername(peer);
    return _messages.where((m) => (m.senderUsername == me && m.receiverUsername == p) || (m.senderUsername == p && m.receiverUsername == me)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  Future<void> _openThread(_ChatThread thread) async {
    if (thread.isGroup) {
      await _openGroupById(thread.groupId!, setLoading: true);
      return;
    }
    setState(() {
      _activeGroupId = null;
      _activePeerUsername = thread.peerUsername;
      _activePeerName = thread.peerName;
      _activePeerAvatarPath = thread.peerAvatarPath;
      _loading = true;
    });
    _notifyConversationActive(true);
    final rows = await SupabaseService.getMessagesBetween(_currentUsername, thread.peerUsername);
    if (!mounted) return;
    setState(() {
      _messages = rows.map(_DirectMessage.fromSupabase).where((m) => !_locallyDeletedMessageIds.contains(m.id)).toList();
      _loading = false;
    });
    await _markVisibleMessagesRead();
    unawaited(_refreshActiveConversationSilently(scroll: true));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _openGroupById(String groupId, {required bool setLoading}) async {
    if (setLoading && mounted) setState(() => _loading = true);
    final group = await SupabaseService.getChatGroup(groupId, _currentUsername);
    final rows = await SupabaseService.getGroupMessages(groupId);
    if (!mounted) return;
    setState(() {
      _activePeerUsername = null;
      _activePeerName = null;
      _activePeerAvatarPath = null;
      _activeGroupId = groupId;
      _activeGroupName = (group?['name'] ?? 'مجموعة').toString();
      _activeGroupAvatar = group?['avatar_url']?.toString();
      _activeGroupLocked = group?['locked'] == true;
      _activeGroupFounder = SupabaseService.displayUsername((group?['founder_username'] ?? '').toString()) == _currentUsername;
      _activeGroupAdmin = group?['my_role'] == 'admin' || _activeGroupFounder;
      _messages = rows.map(_DirectMessage.fromGroupSupabase).where((m) => !_locallyDeletedMessageIds.contains(m.id)).toList();
      _loading = false;
    });
    _notifyConversationActive(true);
    await _markVisibleMessagesRead();
    unawaited(_refreshActiveConversationSilently(scroll: true));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _markVisibleMessagesRead() async {
    final me = _currentUsername;
    for (final m in _activeMessages.where((e) => e.senderUsername != me)) {
      if (_isGroup) {
        unawaited(SupabaseService.markGroupMessageRead(m.id, me));
      } else {
        unawaited(SupabaseService.markMessageRead(m.id, me));
      }
    }
  }

  void _onTextChanged() {
    final typing = _msgCtrl.text.trim().isNotEmpty;
    _typingSendDebounce?.cancel();

    if (typing) {
      _sendTypingState(typing: true, mode: 'text');
      _typingIdleTimer?.cancel();
      _typingIdleTimer = Timer(const Duration(milliseconds: 1400), () {
        if (!_recordingVoice) _sendTypingState(typing: false, mode: 'text');
      });
      return;
    }

    _typingIdleTimer?.cancel();
    if (!_recordingVoice) _sendTypingState(typing: false, mode: 'text');
  }

  void _sendTypingState({required bool typing, required String mode}) {
    _typingSendDebounce?.cancel();
    _typingSendDebounce = Timer(const Duration(milliseconds: 80), () {
      if (!mounted) return;
      if (_isGroup && _activeGroupId != null) {
        unawaited(SupabaseService.broadcastGroupTyping(
          groupId: _activeGroupId!,
          fromUsername: _currentUsername,
          fromName: _currentName,
          typing: typing,
          mode: mode,
        ));
      } else if (_activePeerUsername != null) {
        unawaited(SupabaseService.sendUserBroadcast(username: _activePeerUsername!, event: 'typing', payload: {
          'from': _currentUsername,
          'peer': _currentUsername,
          'name': _currentName,
          'typing': typing,
          'mode': mode,
        }));
      }
    });
  }

  void _startVoiceTypingBroadcast() {
    _voiceTypingKeepAliveTimer?.cancel();
    _sendTypingState(typing: true, mode: 'voice');
    _voiceTypingKeepAliveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _sendTypingState(typing: true, mode: 'voice');
    });
  }

  void _stopVoiceTypingBroadcast() {
    _voiceTypingKeepAliveTimer?.cancel();
    _voiceTypingKeepAliveTimer = null;
    _sendTypingState(typing: false, mode: 'voice');
  }


  String get _localDeletePrefsKey {
    if (_isGroup) return 'respect_deleted_chat_group_${_activeGroupId ?? 'none'}';
    final peer = _activePeerUsername ?? 'none';
    return 'respect_deleted_chat_direct_${SupabaseService.threadId(_currentUsername, peer)}';
  }

  Future<void> _loadLocallyDeletedMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _locallyDeletedMessageIds
        ..clear()
        ..addAll(prefs.getStringList(_localDeletePrefsKey) ?? const <String>[]);
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _saveLocallyDeletedMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_localDeletePrefsKey, _locallyDeletedMessageIds.toList());
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  void _toggleMessageSelection(_DirectMessage msg) {
    if (!mounted) return;
    setState(() {
      if (_selectedMessageIds.contains(msg.id)) {
        _selectedMessageIds.remove(msg.id);
      } else {
        _selectedMessageIds.add(msg.id);
      }
    });
  }

  void _clearSelection() {
    if (!mounted) return;
    setState(() => _selectedMessageIds.clear());
  }

  void _startEditSelectedMessage() {
    if (!_canEditSelectedMessage) return;
    final msg = _selectedMessages.first;
    HapticFeedback.lightImpact();
    setState(() {
      _editingMessage = msg;
      _replyToMessage = null;
      _selectedMessageIds.clear();
    });
    _msgCtrl.text = msg.text;
    _msgCtrl.selection = TextSelection.fromPosition(TextPosition(offset: _msgCtrl.text.length));
  }

  void _cancelEditingMessage() {
    if (!mounted) return;
    setState(() => _editingMessage = null);
    _msgCtrl.clear();
  }

  Future<bool> _submitEditedMessage(String text) async {
    final editing = _editingMessage;
    if (editing == null) return false;
    final newText = text.trim();
    if (newText.isEmpty) return true;
    if (newText == editing.text.trim()) {
      setState(() => _editingMessage = null);
      _msgCtrl.clear();
      return true;
    }

    setState(() => _sending = true);
    try {
      final table = _isGroup ? 'respect_group_messages' : 'messages';
      await SupabaseService.client.from(table).update({'text': newText}).eq('id', editing.id);
      if (!mounted) return true;
      setState(() {
        _messages = _messages.map((m) => m.id == editing.id ? m.copyWith(text: newText) : m).toList();
        _editingMessage = null;
      });
      _msgCtrl.clear();
      await _refreshThreadsOnly();
      NotificationService.showTopSuccess('تم تعديل الرسالة');
      return true;
    } catch (e) {
      if (mounted) NotificationService.showTopError('تعذر تعديل الرسالة: $e');
      return true;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _startReplyTo(_DirectMessage msg) {
    if (!mounted) return;
    HapticFeedback.lightImpact();
    setState(() {
      _replyToMessage = msg;
      _selectedMessageIds.clear();
    });
    FocusScope.of(context).requestFocus(FocusNode());
  }

  Future<void> _jumpToRepliedMessage(String? messageId) async {
    final id = messageId?.trim();
    if (id == null || id.isEmpty) return;

    final messages = _activeMessages;
    final index = messages.indexWhere((m) => m.id == id);
    if (index < 0) {
      NotificationService.showTopNotification('الرسالة الأصلية غير موجودة في هذه المحادثة');
      return;
    }

    Future<bool> ensureIfBuilt({Duration duration = const Duration(milliseconds: 420)}) async {
      final ctx = _messageKeys[id]?.currentContext;
      if (ctx == null) return false;
      await Scrollable.ensureVisible(
        ctx,
        duration: duration,
        curve: Curves.easeOutCubic,
        alignment: 0.42,
      );
      return true;
    }

    // لو الرسالة خارج الشاشة، حرّك القائمة أولاً لمكانها التقريبي حتى يتم بناؤها،
    // بعدها استخدم ensureVisible للوصول الدقيق عليها.
    if (!await ensureIfBuilt(duration: const Duration(milliseconds: 220))) {
      if (_scrollCtrl.hasClients && messages.length > 1) {
        final position = _scrollCtrl.position;
        final estimated = (position.maxScrollExtent * (index / (messages.length - 1))).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        await _scrollCtrl.animateTo(
          estimated.toDouble(),
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeInOutCubic,
        );
        await Future<void>.delayed(const Duration(milliseconds: 90));
      }

      if (!await ensureIfBuilt()) {
        // محاولة ثانية أكثر مباشرة إذا كان تقدير الارتفاع غير كافٍ بسبب اختلاف أحجام الرسائل.
        if (_scrollCtrl.hasClients) {
          final avgExtent = 92.0;
          final target = (index * avgExtent).clamp(
            _scrollCtrl.position.minScrollExtent,
            _scrollCtrl.position.maxScrollExtent,
          );
          await _scrollCtrl.animateTo(
            target.toDouble(),
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOutCubic,
          );
          await Future<void>.delayed(const Duration(milliseconds: 90));
        }
        await ensureIfBuilt();
      }
    }

    if (!mounted) return;
    HapticFeedback.selectionClick();
    _highlightTimer?.cancel();
    setState(() => _highlightMessageId = id);
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _highlightMessageId == id) {
        setState(() => _highlightMessageId = null);
      }
    });
  }

  String _messagePreview(_DirectMessage msg) {
    final txt = msg.text.trim();
    if (msg.isMediaGroup) return txt.isNotEmpty && !txt.endsWith('ملفات') ? txt : '${msg.mediaItems.length} ملفات';
    if (msg.isImage) return txt.isNotEmpty && txt != 'صورة' ? txt : 'صورة';
    if (msg.isVideo) return txt.isNotEmpty && txt != 'فيديو' ? txt : 'فيديو';
    if (msg.isVoice) return 'رسالة صوتية';
    return txt;
  }

  Future<void> _copySelectedMessages() async {
    final selected = _activeMessages.where((m) => _selectedMessageIds.contains(m.id)).toList();
    if (selected.isEmpty) return;
    final text = selected.map((m) => _messagePreview(m)).where((e) => e.trim().isNotEmpty).join('\n');
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _clearSelection();
    NotificationService.showTopSuccess('تم نسخ الرسائل');
  }

  String _safeDownloadName(_DirectMessage msg, Uri uri) {
    final fromUrl = uri.pathSegments.isNotEmpty ? uri.pathSegments.last.split('?').first : '';
    final firstMedia = msg.mediaItems.isNotEmpty ? msg.mediaItems.first : null;
    final ext = fromUrl.contains('.') ? fromUrl.split('.').last : (firstMedia?.isVideo == true ? 'mp4' : msg.isVoice ? 'm4a' : 'jpg');
    final kind = firstMedia?.isVideo == true ? 'video' : msg.isVoice ? 'voice' : 'image';
    return 'respect_${kind}_${DateTime.now().millisecondsSinceEpoch}.$ext';
  }

  Future<Directory> _downloadDirectory() async {
    if (Platform.isAndroid) {
      final downloads = Directory('/storage/emulated/0/Download');
      if (await downloads.exists()) return downloads;
    }
    return await getApplicationDocumentsDirectory();
  }

  Future<void> _downloadMessageMedia(_DirectMessage msg) async {
    final items = msg.mediaItems;
    final url = items.isNotEmpty ? items.first.url.trim() : (msg.mediaUrl?.trim() ?? '');
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    try {
      if (Platform.isAndroid) {
        final photos = await Permission.photos.request();
        final videos = await Permission.videos.request();
        final storage = await Permission.storage.request();
        if (!photos.isGranted && !videos.isGranted && !storage.isGranted && !storage.isLimited) {
          // بعض نسخ أندرويد لا تحتاج صلاحية للكتابة داخل Downloads، لذلك نكمل المحاولة.
        }
      }

      NotificationService.showTopNotification('بدأ التحميل...', icon: Icons.download_rounded);
      final res = await http.get(uri);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('HTTP ${res.statusCode}');
      }

      final dir = await _downloadDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}/${_safeDownloadName(msg, uri)}');
      await file.writeAsBytes(res.bodyBytes, flush: true);
      NotificationService.showTopSuccess('تم الحفظ في Downloads');
    } catch (e) {
      NotificationService.showTopError('تعذر تنزيل الملف: $e');
    }
  }

  Future<void> _downloadSelectedMedia() async {
    final selected = _activeMessages.where((m) => _selectedMessageIds.contains(m.id) && (m.mediaUrl?.trim().isNotEmpty ?? false)).toList();
    if (selected.isEmpty) {
      NotificationService.showTopNotification('حدد صورة أو فيديو أو صوت للتحميل');
      return;
    }
    await _downloadMessageMedia(selected.first);
    _clearSelection();
  }

  Future<void> _deleteSelectedForMe() async {
    if (_selectedMessageIds.isEmpty) return;
    setState(() {
      _locallyDeletedMessageIds.addAll(_selectedMessageIds);
      _messages.removeWhere((m) => _selectedMessageIds.contains(m.id));
      _selectedMessageIds.clear();
    });
    await _saveLocallyDeletedMessages();
    await _refreshThreadsOnly();
    NotificationService.showTopSuccess('تم الحذف لديك فقط');
  }

  Future<void> _deleteSelectedForEveryone() async {
    final selected = _activeMessages.where((m) => _selectedMessageIds.contains(m.id)).toList();
    if (selected.isEmpty) return;
    final allowed = selected.every((m) => m.senderUsername == _currentUsername || (_isGroup && (_activeGroupAdmin || _activeGroupFounder)));
    if (!allowed) {
      NotificationService.showTopError('حذف عند الجميع متاح لرسائلك فقط');
      return;
    }
    for (final m in selected) {
      await SupabaseService.deleteChatMessage(messageId: m.id, group: _isGroup);
    }
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((m) => selected.any((x) => x.id == m.id));
      _selectedMessageIds.clear();
    });
    await _refreshThreadsOnly();
    NotificationService.showTopSuccess('تم الحذف عند الجميع');
  }

  Future<void> _showDeleteSelectionSheet() async {
    if (_selectedMessageIds.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? AppColors.darkCard : AppColors.lightCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.person_remove_rounded, color: AppColors.purple),
              title: const Text('حذف لدي فقط', style: TextStyle(fontWeight: FontWeight.w900)),
              onTap: () { Navigator.pop(context); _deleteSelectedForMe(); },
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded, color: AppColors.danger),
              title: const Text('حذف عند الجميع', style: TextStyle(fontWeight: FontWeight.w900)),
              onTap: () { Navigator.pop(context); _deleteSelectedForEveryone(); },
            ),
          ]),
        ),
      ),
    );
  }

  String _limitedMediaPrefsKey(_DirectMessage msg) => 'respect_limited_media_views_${_currentUsername}_${msg.id}';

  Future<int> _limitedMediaViewedCount(_DirectMessage msg) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_limitedMediaPrefsKey(msg)) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _consumeLimitedMediaView(_DirectMessage msg) async {
    if (msg.senderUsername == _currentUsername || msg.limitedMediaMaxViews <= 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _limitedMediaPrefsKey(msg);
      final current = prefs.getInt(key) ?? 0;
      await prefs.setInt(key, current + 1);
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _openMediaViewer(_DirectMessage msg, {int initialIndex = 0}) async {
    final items = msg.mediaItems;
    if (items.isEmpty) return;

    final maxViews = msg.limitedMediaMaxViews;
    final isReceiver = msg.senderUsername != _currentUsername;
    if (isReceiver && maxViews > 0) {
      final viewed = await _limitedMediaViewedCount(msg);
      if (viewed >= maxViews) {
        NotificationService.showTopError('انتهت صلاحية عرض هذه الصورة');
        if (mounted) setState(() {});
        return;
      }
      await _consumeLimitedMediaView(msg);
    }

    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _MediaViewerPage(
        message: msg,
        title: items.length > 1 ? '${items.length} ملفات' : (items.first.isVideo ? 'فيديو' : 'صورة'),
        initialIndex: initialIndex,
        onDownload: () => _downloadMessageMedia(msg),
      ),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _sendMessage() async {
    if (!_canSend || _sending || _sendingVoice || _sendingMedia) return;
    final text = _msgCtrl.text.trim();
    if (_editingMessage != null) {
      if (text.isEmpty) return;
      await _submitEditedMessage(text);
      return;
    }
    if (_pendingMedia.isNotEmpty) {
      await _sendPendingMediaMessage();
      return;
    }
    if (text.isEmpty) return;
    final reply = _replyToMessage;
    _msgCtrl.clear();
    setState(() => _replyToMessage = null);
    _typingIdleTimer?.cancel();
    _sendTypingState(typing: false, mode: 'text');
    setState(() => _sending = true);

    try {
      if (_isGroup) {
        final row = await SupabaseService.sendGroupMessage(groupId: _activeGroupId!, sender: _currentUsername, text: text, replyToId: reply?.id, replyText: reply == null ? null : _messagePreview(reply), replySender: reply?.senderUsername);
        final msg = _DirectMessage.fromGroupSupabase(row).copyWith(status: MessageStatus.delivered);
        if (mounted && !_messages.any((m) => m.id == msg.id)) setState(() => _messages.add(msg));
        await SupabaseService.broadcastGroupMessage(groupId: _activeGroupId!, message: row, excludeUsername: _currentUsername);
      } else {
        final peer = _activePeerUsername;
        if (peer == null) return;
        final localId = 'local_${DateTime.now().microsecondsSinceEpoch}';
        final local = _DirectMessage(
          id: localId,
          senderUsername: _currentUsername,
          receiverUsername: peer,
          senderName: _currentName,
          senderAvatar: _currentAvatarPath,
          text: text,
          createdAt: DateTime.now().toIso8601String(),
          status: MessageStatus.sent,
          replyToId: reply?.id,
          replyText: reply == null ? null : _messagePreview(reply),
          replySender: reply?.senderUsername,
        );
        if (mounted) setState(() => _messages.add(local));
        final row = await SupabaseService.sendMessage(sender: _currentUsername, receiver: peer, text: text, replyToId: reply?.id, replyText: reply == null ? null : _messagePreview(reply), replySender: reply?.senderUsername);
        final msg = _DirectMessage.fromSupabase(row).copyWith(status: MessageStatus.delivered, senderName: _currentName, senderAvatar: _currentAvatarPath);
        if (mounted) {
          setState(() {
            _messages.removeWhere((m) => m.id == localId);
            if (!_messages.any((m) => m.id == msg.id)) _messages.add(msg);
          });
        }
        await SupabaseService.sendUserBroadcast(username: peer, event: 'new_message', payload: {'message': row});
        unawaited(SupabaseService.sendMessagePush(receiverUsername: peer, senderUsername: _currentUsername, senderName: _currentName, messageId: msg.id, text: text));
      }
      await _refreshThreadsOnly();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('فشل إرسال الرسالة: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _startVoiceRecording({bool locked = false}) async {
    if (!_canSend || _sending || _sendingVoice || _recordingVoice) return;
    try {
      final hasPermission = await _voiceRecorder.hasPermission();
      if (!hasPermission) {
        if (!mounted) return;
        NotificationService.showTopNotification('اسمح للمايك لإرسال رسالة صوتية');
        return;
      }

      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/respect_voice_${DateTime.now().microsecondsSinceEpoch}.m4a';
      await _voiceRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100),
        path: path,
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _recordingVoice = true;
        _lockedVoiceRecording = locked;
        _voicePaused = false;
        _voiceRecordStartedAt = DateTime.now();
        _voicePausedElapsed = Duration.zero;
        _recordingVoiceWaveform = <double>[];
      });
      _startVoiceAmplitudeCapture();
      _startVoiceTypingBroadcast();
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('فشل بدء التسجيل: $e');
    }
  }


  void _startVoiceAmplitudeCapture() {
    _voiceAmplitudeTimer?.cancel();
    _voiceAmplitudeTimer = Timer.periodic(const Duration(milliseconds: 70), (_) async {
      if (!_recordingVoice || _voicePaused) return;
      try {
        final amp = await _voiceRecorder.getAmplitude();
        final current = amp.current;
        // record package يعطي القيمة غالبًا بالديسيبل: -60 هدوء، 0 صوت عالي.
        final normalized = ((current + 60.0) / 60.0).clamp(0.04, 1.0).toDouble();
        if (!mounted) return;
        _recordingVoiceWaveform.add(normalized);
        // نخلي عدد الأعمدة معقول وخفيف حتى ما يثقل الواجهة.
        if (_recordingVoiceWaveform.length > 96) {
          final merged = <double>[];
          for (var i = 0; i < _recordingVoiceWaveform.length; i += 2) {
            final a = _recordingVoiceWaveform[i];
            final b = i + 1 < _recordingVoiceWaveform.length ? _recordingVoiceWaveform[i + 1] : a;
            merged.add(math.max(a, b));
          }
          _recordingVoiceWaveform = merged;
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    });
  }

  List<double> _compactWaveform(List<double> values, {int target = 56}) {
    final clean = values.where((v) => v.isFinite).map((v) => v.clamp(0.04, 1.0).toDouble()).toList();
    if (clean.isEmpty) return <double>[];
    if (clean.length <= target) return clean;
    final out = <double>[];
    final step = clean.length / target;
    for (var i = 0; i < target; i++) {
      final start = (i * step).floor();
      final end = math.min(clean.length, ((i + 1) * step).ceil());
      var peak = 0.04;
      for (var j = start; j < end; j++) {
        if (clean[j] > peak) peak = clean[j];
      }
      out.add(peak);
    }
    return out;
  }

  Future<void> _toggleVoiceRecording() async {
    if (!_canSend || _sending || _sendingVoice) return;
    if (_recordingVoice) {
      await _stopAndSendVoice();
    } else {
      await _startVoiceRecording(locked: true);
    }
  }

  void _handleVoicePressStart(DragDownDetails details) {
    if (!_canSend || _sending || _sendingVoice || _recordingVoice) return;
    _longPressVoiceStarted = true;
    HapticFeedback.selectionClick();
    unawaited(_startVoiceRecording());
  }

  void _handleVoicePressMove(DragUpdateDetails details) {
    if (!_recordingVoice || _lockedVoiceRecording) return;
    if (details.localPosition.dy < -34 || details.delta.dy < -8) {
      HapticFeedback.heavyImpact();
      setState(() => _lockedVoiceRecording = true);
      NotificationService.showTopNotification('تم تثبيت التسجيل، اضغط إرسال عند الانتهاء', icon: Icons.lock_rounded);
    }
  }

  void _handleVoicePressEnd(DragEndDetails details) {
    if (!_longPressVoiceStarted) return;
    _longPressVoiceStarted = false;
    if (_recordingVoice && !_lockedVoiceRecording) {
      unawaited(_stopAndSendVoice());
    }
  }

  void _handleVoicePressCancel() {
    if (!_longPressVoiceStarted) return;
    _longPressVoiceStarted = false;
    if (_recordingVoice && !_lockedVoiceRecording) {
      unawaited(_stopAndSendVoice());
    }
  }

  Future<void> _toggleVoicePause() async {
    if (!_recordingVoice) return;
    try {
      if (_voicePaused) {
        await _voiceRecorder.resume();
        final elapsed = _voicePausedElapsed;
        _voiceRecordStartedAt = DateTime.now().subtract(elapsed);
        _voicePausedElapsed = Duration.zero;
        _startVoiceTypingBroadcast();
      } else {
        final started = _voiceRecordStartedAt;
        _voicePausedElapsed = started == null ? Duration.zero : DateTime.now().difference(started);
        await _voiceRecorder.pause();
        _stopVoiceTypingBroadcast();
      }
      if (mounted) setState(() => _voicePaused = !_voicePaused);
    } catch (e) {
      NotificationService.showTopError('تعذر إيقاف/استكمال التسجيل: $e');
    }
  }

  Future<void> _cancelVoiceRecording() async {
    if (!_recordingVoice) return;
    try {
      await _voiceRecorder.stop();
    } catch (e, st) { _logIgnoredError(e, st); }
    _voiceAmplitudeTimer?.cancel();
    _stopVoiceTypingBroadcast();
    if (mounted) {
      setState(() {
        _recordingVoice = false;
        _lockedVoiceRecording = false;
        _voicePaused = false;
        _voiceRecordStartedAt = null;
        _voicePausedElapsed = Duration.zero;
        _recordingVoiceWaveform = <double>[];
      });
    }
  }

  Future<void> _finishVoiceForPreview() async {
    if (!_recordingVoice || _recordingFinishingForPreview) return;
    _recordingFinishingForPreview = true;
    try {
      final started = _voiceRecordStartedAt;
      final path = await _voiceRecorder.stop();
      final waveform = _compactWaveform(_recordingVoiceWaveform);
      _voiceAmplitudeTimer?.cancel();
      final elapsed = _voicePaused ? _voicePausedElapsed : (started == null ? Duration.zero : DateTime.now().difference(started));
      final seconds = elapsed.inSeconds.clamp(1, 600).toInt();
      _stopVoiceTypingBroadcast();
      if (!mounted) return;
      setState(() {
        _recordingVoice = false;
        _lockedVoiceRecording = false;
        _voicePaused = false;
        _voiceRecordStartedAt = null;
        _voicePausedElapsed = Duration.zero;
        _pendingVoicePath = path;
        _pendingVoiceSeconds = seconds;
        _pendingVoiceWaveform = waveform;
      });
    } catch (e) {
      if (mounted) NotificationService.showTopError('تعذر تجهيز المعاينة: $e');
    } finally {
      _recordingFinishingForPreview = false;
    }
  }

  Future<void> _sendPendingVoice() async {
    final path = _pendingVoicePath;
    if (path == null || path.trim().isEmpty) return;
    final seconds = _pendingVoiceSeconds <= 0 ? 1 : _pendingVoiceSeconds;
    final waveform = List<double>.from(_pendingVoiceWaveform);
    await _audioPlayer.stop();
    if (mounted) {
      setState(() {
        _playingVoiceUrl = null;
        _pendingVoicePath = null;
        _pendingVoiceSeconds = 0;
        _pendingVoiceWaveform = <double>[];
        _voicePosition = Duration.zero;
        _voiceDuration = Duration.zero;
      });
    }
    await _sendVoiceMessage(path, seconds: seconds, waveform: waveform);
  }

  Future<void> _cancelPendingVoice() async {
    final path = _pendingVoicePath;
    await _audioPlayer.stop();
    if (path != null && path.trim().isNotEmpty) {
      try { await File(path).delete(); } catch (e, st) { _logIgnoredError(e, st); }
    }
    if (mounted) {
      setState(() {
        _playingVoiceUrl = null;
        _pendingVoicePath = null;
        _pendingVoiceSeconds = 0;
        _pendingVoiceWaveform = <double>[];
        _voicePosition = Duration.zero;
        _voiceDuration = Duration.zero;
      });
    }
  }

  Future<void> _stopAndSendVoice() async {
    if (!_recordingVoice) return;
    try {
      final started = _voiceRecordStartedAt;
      final path = await _voiceRecorder.stop();
      final waveform = _compactWaveform(_recordingVoiceWaveform);
      _voiceAmplitudeTimer?.cancel();
      final elapsed = _voicePaused ? _voicePausedElapsed : (started == null ? Duration.zero : DateTime.now().difference(started));
      final seconds = elapsed.inSeconds.clamp(1, 600).toInt();
      if (!mounted) return;
      setState(() {
        _recordingVoice = false;
        _lockedVoiceRecording = false;
        _voicePaused = false;
        _voiceRecordStartedAt = null;
        _voicePausedElapsed = Duration.zero;
        _recordingVoiceWaveform = <double>[];
      });
      _stopVoiceTypingBroadcast();
      if (path == null || path.trim().isEmpty) return;
      await _sendVoiceMessage(path, seconds: seconds, waveform: waveform);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recordingVoice = false;
        _lockedVoiceRecording = false;
        _voicePaused = false;
        _voiceRecordStartedAt = null;
        _voicePausedElapsed = Duration.zero;
      });
      _voiceAmplitudeTimer?.cancel();
      _stopVoiceTypingBroadcast();
      NotificationService.showTopNotification('فشل إرسال الصوت: $e');
    }
  }

  Future<void> _sendVoiceMessage(String filePath, {required int seconds, List<double> waveform = const <double>[]}) async {
    if (!_canSend || _sendingVoice) return;
    setState(() => _sendingVoice = true);
    try {
      final voiceUrl = await SupabaseService.uploadChatVoice(username: _currentUsername, filePath: filePath);
      if (voiceUrl.trim().isEmpty) return;
      final realWaveform = _compactWaveform(waveform);
      if (realWaveform.isNotEmpty) _voiceWaveformCache[voiceUrl] = realWaveform;

      if (_isGroup) {
        final row = await SupabaseService.sendGroupMessage(
          groupId: _activeGroupId!,
          sender: _currentUsername,
          text: 'رسالة صوتية',
          mediaType: 'voice',
          mediaUrl: voiceUrl,
          voiceSeconds: seconds,
        );
        final msg = _DirectMessage.fromGroupSupabase(row).copyWith(status: MessageStatus.delivered);
        if (mounted && !_messages.any((m) => m.id == msg.id)) setState(() => _messages.add(msg));
        await SupabaseService.broadcastGroupMessage(groupId: _activeGroupId!, message: row, excludeUsername: _currentUsername);
      } else {
        final peer = _activePeerUsername;
        if (peer == null) return;
        final row = await SupabaseService.sendMessage(
          sender: _currentUsername,
          receiver: peer,
          text: 'رسالة صوتية',
          mediaType: 'voice',
          mediaUrl: voiceUrl,
          voiceSeconds: seconds,
        );
        final msg = _DirectMessage.fromSupabase(row).copyWith(status: MessageStatus.delivered, senderName: _currentName, senderAvatar: _currentAvatarPath);
        if (mounted && !_messages.any((m) => m.id == msg.id)) setState(() => _messages.add(msg));
        await SupabaseService.sendUserBroadcast(username: peer, event: 'new_message', payload: {'message': row});
        unawaited(SupabaseService.sendMessagePush(receiverUsername: peer, senderUsername: _currentUsername, senderName: _currentName, messageId: msg.id, text: 'رسالة صوتية'));
      }
      await _refreshThreadsOnly();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('فشل إرسال الرسالة الصوتية: $e');
    } finally {
      _stopVoiceTypingBroadcast();
      if (mounted) setState(() => _sendingVoice = false);
    }
  }


  String _chatMediaExtFromPath(String path, {required bool video}) {
    final clean = path.split('?').first;
    final ext = clean.contains('.') ? clean.split('.').last.toLowerCase() : (video ? 'mp4' : 'jpg');
    if (video) {
      if (['mp4', 'mov', 'm4v', 'webm', 'mkv'].contains(ext)) return ext;
      return 'mp4';
    }
    if (['png', 'webp', 'jpeg', 'jpg', 'gif'].contains(ext)) return ext == 'jpeg' ? 'jpg' : ext;
    return 'jpg';
  }

  String _chatMediaContentType(String ext, {required bool video}) {
    if (video) {
      switch (ext) {
        case 'webm':
          return 'video/webm';
        case 'mov':
          return 'video/quicktime';
        case 'm4v':
          return 'video/x-m4v';
        case 'mkv':
          return 'video/x-matroska';
        default:
          return 'video/mp4';
      }
    }
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      default:
        return 'image/jpeg';
    }
  }

  Future<String> _uploadChatMedia(String filePath, {required bool video}) async {
    final raw = filePath.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;

    final file = File(raw);
    if (!await file.exists()) throw Exception(video ? 'الفيديو غير موجود' : 'الصورة غير موجودة');

    final sizeMb = await file.length() / (1024 * 1024);
    if (video && sizeMb > 120) throw Exception('الفيديو كبير جدًا، اختر فيديو أقل من 120MB');
    if (!video && sizeMb > 25) throw Exception('الصورة كبيرة جدًا، اختر صورة أقل من 25MB');

    final clean = SupabaseService.normalizeUsername(_currentUsername);
    final ext = _chatMediaExtFromPath(raw, video: video);
    final storagePath = 'chat/$clean/${video ? 'videos' : 'images'}/${DateTime.now().microsecondsSinceEpoch}.$ext';

    await SupabaseService.client.storage.from('post-media').upload(
      storagePath,
      file,
      fileOptions: FileOptions(
        contentType: _chatMediaContentType(ext, video: video),
        cacheControl: '604800',
        upsert: true,
      ),
    );

    return SupabaseService.client.storage.from('post-media').getPublicUrl(storagePath);
  }

  Future<void> _showAttachmentSheet() async {
    if (!_canSend || _sending || _sendingVoice || _sendingMedia) return;
    FocusScope.of(context).unfocus();

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? AppColors.darkCard : AppColors.lightCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('إرسال مرفق', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _AttachmentActionButton(
                    icon: Icons.photo_library_rounded,
                    title: 'صور',
                    subtitle: 'واحدة أو أكثر',
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickAndSendImages();
                    },
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: _AttachmentActionButton(
                    icon: Icons.video_library_rounded,
                    title: 'صور وفيديوهات',
                    subtitle: 'تحديد متعدد',
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickAndSendMultipleMedia();
                    },
                  )),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _AttachmentActionButton(
                    icon: Icons.photo_camera_rounded,
                    title: 'كاميرا',
                    subtitle: 'تصوير صورة',
                    onTap: () {
                      Navigator.pop(ctx);
                      _openInAppCamera(video: false);
                    },
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: _AttachmentActionButton(
                    icon: Icons.videocam_rounded,
                    title: 'تصوير فيديو',
                    subtitle: 'من داخل التطبيق',
                    onTap: () {
                      Navigator.pop(ctx);
                      _openInAppCamera(video: true);
                    },
                  )),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }


  Future<void> _openInAppCamera({required bool video}) async {
    if (!_canSend || _sending || _sendingVoice || _sendingMedia) return;

    try {
      final captured = await Navigator.of(context).push<_CapturedChatMedia>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _InAppChatCameraPage(initialVideoMode: video),
        ),
      );
      if (captured == null || captured.path.trim().isEmpty) return;
      _setPendingMedia([
        _PendingChatMedia(
          path: captured.path,
          type: captured.isVideo ? 'video' : 'image',
        ),
      ]);
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('تعذر فتح كاميرا التطبيق: $e');
    }
  }

  Future<void> _pickAndSendImages() async {
    try {
      final picked = await ImagePicker().pickMultiImage(
        imageQuality: 82,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (picked.isEmpty) return;
      _setPendingMedia(picked.map((x) => _PendingChatMedia(path: x.path, type: 'image')).toList());
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('تعذر اختيار الصور: $e');
    }
  }

  Future<void> _pickAndSendMultipleMedia() async {
    try {
      final picked = await ImagePicker().pickMultipleMedia(
        imageQuality: 82,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (picked.isEmpty) return;
      _setPendingMedia(picked.map((x) => _PendingChatMedia(path: x.path, type: _looksLikeVideoPath(x.path) ? 'video' : 'image')).toList());
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('تعذر اختيار الملفات: $e');
    }
  }

  bool _looksLikeVideoPath(String path) {
    final clean = path.split('?').first.toLowerCase();
    return clean.endsWith('.mp4') || clean.endsWith('.mov') || clean.endsWith('.m4v') || clean.endsWith('.webm') || clean.endsWith('.mkv') || clean.endsWith('.avi');
  }

  void _setPendingMedia(List<_PendingChatMedia> items) {
    if (items.isEmpty || !mounted) return;
    setState(() {
      _pendingMedia
        ..clear()
        ..addAll(items);
      _pendingMediaMaxViews = 0;
    });
  }

  void _setPendingMediaMaxViews(int value) {
    if (!mounted) return;
    setState(() => _pendingMediaMaxViews = value.clamp(0, 2).toInt());
  }

  void _removePendingMediaAt(int index) {
    if (index < 0 || index >= _pendingMedia.length) return;
    setState(() => _pendingMedia.removeAt(index));
  }

  void _clearPendingMedia() {
    if (_pendingMedia.isEmpty) return;
    setState(() {
      _pendingMedia.clear();
      _pendingMediaMaxViews = 0;
    });
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        imageQuality: 82,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (picked == null) return;
      _setPendingMedia([_PendingChatMedia(path: picked.path, type: 'image')]);
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('تعذر اختيار/تصوير الصورة: $e');
    }
  }

  Future<void> _pickAndSendVideo(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickVideo(
        source: source,
        maxDuration: const Duration(minutes: 5),
      );
      if (picked == null) return;
      _setPendingMedia([_PendingChatMedia(path: picked.path, type: 'video')]);
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('تعذر اختيار/تصوير الفيديو: $e');
    }
  }

  Future<void> _sendPendingMediaMessage() async {
    if (!_canSend || _sendingMedia || _pendingMedia.isEmpty) return;

    final pending = List<_PendingChatMedia>.from(_pendingMedia);
    final caption = _msgCtrl.text.trim();
    final reply = _replyToMessage;
    if (mounted) setState(() => _sendingMedia = true);

    try {
      final uploaded = <_ChatMediaItem>[];
      for (final item in pending) {
        final url = await _uploadChatMedia(item.path, video: item.isVideo);
        if (url.trim().isNotEmpty) {
          uploaded.add(_ChatMediaItem(url: url, type: item.type, maxViews: _pendingMediaMaxViews));
        }
      }
      if (uploaded.isEmpty) return;

      final mediaType = uploaded.length > 1 || _pendingMediaMaxViews > 0 ? 'gallery' : uploaded.first.type;
      final mediaUrl = uploaded.length == 1 && _pendingMediaMaxViews <= 0
          ? uploaded.first.url
          : jsonEncode(uploaded.map((e) => e.toJson()).toList());
      final defaultText = uploaded.length == 1
          ? (uploaded.first.isVideo ? 'فيديو' : 'صورة')
          : '${uploaded.length} ملفات';
      final text = caption.isNotEmpty ? caption : defaultText;

      _msgCtrl.clear();
      _typingIdleTimer?.cancel();
      _sendTypingState(typing: false, mode: 'text');

      if (_isGroup) {
        final row = await SupabaseService.sendGroupMessage(
          groupId: _activeGroupId!,
          sender: _currentUsername,
          text: text,
          mediaType: mediaType,
          mediaUrl: mediaUrl,
          replyToId: reply?.id,
          replyText: reply == null ? null : _messagePreview(reply),
          replySender: reply?.senderUsername,
        );
        final msg = _DirectMessage.fromGroupSupabase(row).copyWith(status: MessageStatus.delivered);
        if (mounted && !_messages.any((m) => m.id == msg.id)) {
          setState(() => _messages.add(msg));
        }
        await SupabaseService.broadcastGroupMessage(groupId: _activeGroupId!, message: row, excludeUsername: _currentUsername);
      } else {
        final peer = _activePeerUsername;
        if (peer == null) return;
        final row = await SupabaseService.sendMessage(
          sender: _currentUsername,
          receiver: peer,
          text: text,
          mediaType: mediaType,
          mediaUrl: mediaUrl,
          replyToId: reply?.id,
          replyText: reply == null ? null : _messagePreview(reply),
          replySender: reply?.senderUsername,
        );
        final msg = _DirectMessage.fromSupabase(row).copyWith(status: MessageStatus.delivered, senderName: _currentName, senderAvatar: _currentAvatarPath);
        if (mounted && !_messages.any((m) => m.id == msg.id)) {
          setState(() => _messages.add(msg));
        }
        await SupabaseService.sendUserBroadcast(username: peer, event: 'new_message', payload: {'message': row});
        unawaited(SupabaseService.sendMessagePush(
          receiverUsername: peer,
          senderUsername: _currentUsername,
          senderName: _currentName,
          messageId: msg.id,
          text: caption.isNotEmpty ? caption : defaultText,
        ));
      }

      if (mounted) {
        setState(() {
          _pendingMedia.clear();
          _pendingMediaMaxViews = 0;
          _replyToMessage = null;
        });
      }
      await _refreshThreadsOnly();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('فشل إرسال المرفق: $e');
    } finally {
      if (mounted) setState(() => _sendingMedia = false);
    }
  }

  Future<void> _sendMediaMessage(String filePath, {required String mediaType, bool keepTypedTextForFirstOnly = true}) async {
    _setPendingMedia([_PendingChatMedia(path: filePath, type: mediaType)]);
    await _sendPendingMediaMessage();
  }


  Future<void> _playVoice(String url) async {
    final clean = url.trim();
    if (clean.isEmpty) return;
    try {
      if (_playingVoiceUrl == clean) {
        await _audioPlayer.pause();
        if (mounted) setState(() => _playingVoiceUrl = null);
        return;
      }
      await _audioPlayer.stop();
      if (mounted) {
        setState(() {
          _playingVoiceUrl = clean;
          _voicePosition = Duration.zero;
          _voiceDuration = Duration.zero;
        });
      }
      await _audioPlayer.setPlaybackRate(_voiceSpeed);
      final isRemote = clean.startsWith('http://') || clean.startsWith('https://');
      await _audioPlayer.play(isRemote ? UrlSource(clean) : DeviceFileSource(clean));
    } catch (e) {
      if (mounted) {
        setState(() => _playingVoiceUrl = null);
        NotificationService.showTopNotification('تعذر تشغيل الصوت: $e');
      }
    }
  }

  Future<void> _seekVoice(Duration position) async {
    try {
      await _audioPlayer.seek(position);
      if (mounted) setState(() => _voicePosition = position);
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _changeVoiceSpeed() async {
    final speeds = <double>[1.0, 1.25, 1.5, 2.0];
    final index = speeds.indexWhere((v) => (v - _voiceSpeed).abs() < .01);
    final next = speeds[(index + 1) % speeds.length];
    try {
      await _audioPlayer.setPlaybackRate(next);
    } catch (e, st) { _logIgnoredError(e, st); }
    if (mounted) setState(() => _voiceSpeed = next);
  }

  Future<void> _deleteMessage(_DirectMessage msg) async {
    _selectedMessageIds
      ..clear()
      ..add(msg.id);
    await _showDeleteSelectionSheet();
  }

  Future<String> _uploadGroupAvatar(String filePath) async {
    final raw = filePath.trim();
    if (raw.isEmpty) return '';
    final file = File(raw);
    if (!await file.exists()) throw Exception('الصورة غير موجودة');

    final cleanGroupId = (_activeGroupId ?? 'group').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final extRaw = raw.split('?').first.split('.').last.toLowerCase();
    final ext = ['jpg', 'jpeg', 'png', 'webp'].contains(extRaw) ? (extRaw == 'jpeg' ? 'jpg' : extRaw) : 'jpg';
    final contentType = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
        ? 'image/webp'
        : 'image/jpeg';
    final storagePath = 'groups/$cleanGroupId/avatar_${DateTime.now().millisecondsSinceEpoch}.$ext';

    await SupabaseService.client.storage.from('avatars').upload(
      storagePath,
      file,
      fileOptions: FileOptions(contentType: contentType, upsert: true),
    );
    return SupabaseService.client.storage.from('avatars').getPublicUrl(storagePath);
  }

  Future<void> _updateActiveGroupInfo({String? name, String? avatarUrl}) async {
    final groupId = _activeGroupId;
    if (groupId == null || groupId.trim().isEmpty) return;

    final payload = <String, dynamic>{
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    final cleanName = name?.trim();
    if (cleanName != null && cleanName.isNotEmpty) payload['name'] = cleanName;
    final cleanAvatar = avatarUrl?.trim();
    if (cleanAvatar != null && cleanAvatar.isNotEmpty) payload['avatar_url'] = cleanAvatar;

    await SupabaseService.client.from('respect_chat_groups').update(payload).eq('id', groupId);

    if (!mounted) return;
    setState(() {
      if (payload.containsKey('name')) _activeGroupName = payload['name']?.toString();
      if (payload.containsKey('avatar_url')) _activeGroupAvatar = payload['avatar_url']?.toString();
    });
    await SupabaseService.broadcastGroupUpdated(groupId);
    await _refreshThreadsOnly();
  }

  Future<void> _pickGroupAvatar() async {
    if (!_isGroup || !(_activeGroupAdmin || _activeGroupFounder)) return;
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 82, maxWidth: 900);
      if (picked == null) return;
      final url = await _uploadGroupAvatar(picked.path);
      await _updateActiveGroupInfo(avatarUrl: url);
      if (!mounted) return;
      NotificationService.showTopNotification('تم تحديث صورة المجموعة');
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('فشل تحديث الصورة: $e');
    }
  }

  Future<void> _renameActiveGroup() async {
    if (!_isGroup || !(_activeGroupAdmin || _activeGroupFounder)) return;

    // نستخدم context الأساسي للصفحة فقط، ونفتح النافذة بعد إغلاق أي BottomSheet.
    // هذا يمنع خطأ Flutter الأحمر: _dependents.isEmpty عند تغيير الاسم.
    final pageContext = this.context;
    final ctrl = TextEditingController(text: _activeGroupName ?? 'مجموعة');

    try {
      if (!mounted) return;
      final newName = await showDialog<String>(
        context: pageContext,
        useRootNavigator: true,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('تغيير اسم المجموعة'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 40,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'اسم المجموعة'),
            onSubmitted: (v) => Navigator.of(dialogCtx, rootNavigator: true).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(ctrl.text.trim()),
              child: const Text('حفظ'),
            ),
          ],
        ),
      );

      final clean = newName?.trim() ?? '';
      if (clean.isEmpty) return;
      await _updateActiveGroupInfo(name: clean);

      if (!mounted) return;
      NotificationService.showTopNotification('تم تغيير اسم المجموعة');
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('فشل تغيير اسم المجموعة: $e');
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _toggleGroupLock() async {
    if (!_isGroup || !(_activeGroupAdmin || _activeGroupFounder)) return;
    final locked = !_activeGroupLocked;
    await SupabaseService.setChatGroupLocked(groupId: _activeGroupId!, locked: locked);
    if (!mounted) return;
    setState(() => _activeGroupLocked = locked);
    await SupabaseService.broadcastGroupUpdated(_activeGroupId!);
  }

  Future<void> _showGroupAdminSheet() async {
    if (!_isGroup) return;
    final members = await SupabaseService.getChatGroupMembers(_activeGroupId!);
    if (!mounted) return;
    final groupAvatar = _fileImage(_activeGroupAvatar);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.78,
          minChildSize: 0.45,
          maxChildSize: 0.94,
          builder: (context, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 44,
                      backgroundColor: AppColors.purple.withOpacity(.22),
                      backgroundImage: groupAvatar,
                      child: groupAvatar == null ? const Icon(Icons.groups_rounded, color: Colors.white, size: 42) : null,
                    ),
                    if (_activeGroupAdmin || _activeGroupFounder)
                      PositionedDirectional(
                        end: -4,
                        bottom: -4,
                        child: InkWell(
                          onTap: () async {
                            Navigator.of(context).pop();
                            await Future<void>.delayed(const Duration(milliseconds: 280));
                            if (!mounted) return;
                            await _pickGroupAvatar();
                          },
                          borderRadius: BorderRadius.circular(999),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: const BoxDecoration(color: AppColors.purple, shape: BoxShape.circle),
                            child: const Icon(Icons.camera_alt_rounded, size: 17, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  _activeGroupName ?? 'مجموعة',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  _activeGroupFounder ? 'أنت مؤسس المجموعة' : (_activeGroupAdmin ? 'أنت مشرف' : 'عضو في المجموعة'),
                  style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 16),
              if (_activeGroupAdmin || _activeGroupFounder) ...[
                ListTile(
                  leading: const Icon(Icons.edit_rounded, color: AppColors.purple),
                  title: const Text('تغيير اسم المجموعة'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await Future<void>.delayed(const Duration(milliseconds: 280));
                    if (!mounted) return;
                    await _renameActiveGroup();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.image_rounded, color: AppColors.purple),
                  title: const Text('تغيير صورة المجموعة'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await Future<void>.delayed(const Duration(milliseconds: 280));
                    if (!mounted) return;
                    await _pickGroupAvatar();
                  },
                ),
                ListTile(
                  leading: Icon(_activeGroupLocked ? Icons.lock_open_rounded : Icons.lock_rounded, color: AppColors.purple),
                  title: Text(_activeGroupLocked ? 'فتح الدردشة للجميع' : 'قفل الدردشة للمشرفين فقط'),
                  subtitle: const Text('عند القفل، المؤسس والمشرفون فقط يقدرون يرسلون'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await Future<void>.delayed(const Duration(milliseconds: 280));
                    if (!mounted) return;
                    await _toggleGroupLock();
                  },
                ),
                const Divider(),
              ],
              Text('الأعضاء', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              ...members.map((m) {
                final username = SupabaseService.displayUsername((m['username'] ?? '').toString());
                final role = (m['role'] ?? 'member').toString();
                final user = _accountByUsername(_users, username);
                final avatar = _fileImage((user?['avatar_url'] ?? user?['imagePath'] ?? user?['profileImagePath'])?.toString());
                final canManageMember = _activeGroupFounder && username != _currentUsername && role != 'founder';
                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(backgroundImage: avatar, child: avatar == null ? const Icon(Icons.person_rounded) : null),
                    title: Text((user?['name'] ?? user?['profileName'] ?? username).toString(), style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(role == 'founder' ? 'المؤسس' : role == 'admin' ? 'مشرف' : 'عضو'),
                    trailing: canManageMember
                        ? PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'admin') {
                          await SupabaseService.setChatGroupMemberRole(
                            groupId: _activeGroupId!,
                            username: username,
                            role: role == 'admin' ? 'member' : 'admin',
                          );
                        }
                        if (v == 'remove') {
                          await SupabaseService.removeChatGroupMember(groupId: _activeGroupId!, username: username);
                        }
                        await SupabaseService.broadcastGroupUpdated(_activeGroupId!);
                        if (mounted) {
                          Navigator.pop(context);
                          await _showGroupAdminSheet();
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'admin', child: Text(role == 'admin' ? 'إزالة الإشراف' : 'جعله مشرف')),
                        const PopupMenuItem(value: 'remove', child: Text('طرد من المجموعة')),
                      ],
                    )
                        : null,
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateGroupDialog() async {
    final selected = <String>{};
    final nameCtrl = TextEditingController();
    final queryCtrl = TextEditingController();
    List<Map<String, dynamic>> visible = List<Map<String, dynamic>>.from(_users.where((u) => SupabaseService.displayUsername((u['username'] ?? '').toString()) != _currentUsername));

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('إنشاء مجموعة'),
          content: SizedBox(
            width: double.maxFinite,
            height: 430,
            child: Column(
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'اسم المجموعة')),
                const SizedBox(height: 8),
                TextField(
                  controller: queryCtrl,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'ابحث عن عضو'),
                  onChanged: (v) => setLocal(() {
                    final q = v.trim().toLowerCase();
                    visible = _users.where((u) {
                      final username = SupabaseService.displayUsername((u['username'] ?? '').toString());
                      if (username == _currentUsername) return false;
                      final name = (u['name'] ?? u['profileName'] ?? username).toString().toLowerCase();
                      return q.isEmpty || username.toLowerCase().contains(q) || name.contains(q);
                    }).toList();
                  }),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (_, i) {
                      final u = visible[i];
                      final username = SupabaseService.displayUsername((u['username'] ?? '').toString());
                      final avatar = _fileImage((u['avatar_url'] ?? u['imagePath'] ?? u['profileImagePath'])?.toString());
                      return CheckboxListTile(
                        value: selected.contains(username),
                        onChanged: (v) => setLocal(() => v == true ? selected.add(username) : selected.remove(username)),
                        title: Text((u['name'] ?? u['profileName'] ?? username).toString()),
                        subtitle: Text(username),
                        secondary: CircleAvatar(backgroundImage: avatar, child: avatar == null ? const Icon(Icons.person_rounded) : null),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () async {
                if (selected.isEmpty) return;
                final group = await SupabaseService.createChatGroup(
                  name: nameCtrl.text.trim().isEmpty ? 'مجموعة جديدة' : nameCtrl.text.trim(),
                  founderUsername: _currentUsername,
                  memberUsernames: selected.toList(),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                await _refreshThreadsOnly();
                await _openGroupById((group['id'] ?? '').toString(), setLoading: true);
              },
              child: const Text('إنشاء'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    queryCtrl.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  Future<void> _startCall({required bool video}) async {
    if (_isGroup) {
      await _showGroupCallPicker(video: video);
      return;
    }
    if (_activePeerUsername == null) return;
    await _startDirectCall(
      peerUsername: _activePeerUsername!,
      peerName: _activePeerName ?? _activePeerUsername!,
      peerAvatarPath: _activePeerAvatarPath,
      video: video,
      roomPrefix: 'direct',
    );
  }

  Future<void> _startDirectCall({
    required String peerUsername,
    required String peerName,
    String? peerAvatarPath,
    required bool video,
    String roomPrefix = 'direct',
  }) async {
    final cleanPeer = SupabaseService.displayUsername(peerUsername);
    final safeMe = SupabaseService.normalizeUsername(_currentUsername);
    final safePeer = SupabaseService.normalizeUsername(cleanPeer);
    final safePrefix = roomPrefix.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_');
    final callId = '${safePrefix}_${safeMe}_${safePeer}_${DateTime.now().millisecondsSinceEpoch}';

    await _sendCallInviteToUser(
      receiverUsername: cleanPeer,
      callId: callId,
      video: video,
      groupId: _activeGroupId,
      groupName: _activeGroupName,
    );

    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallScreen(
      callId: callId,
      peerName: peerName,
      peerAvatarPath: peerAvatarPath,
      video: video,
      isCaller: true,
      callService: CallService(),
      callerName: _currentName,
      callerUsername: _currentUsername,
      calleeUsername: cleanPeer,
    )));
  }

  Future<void> _sendCallInviteToUser({
    required String receiverUsername,
    required String callId,
    required bool video,
    String? groupId,
    String? groupName,
  }) async {
    final callType = video ? 'video' : 'audio';
    final receiver = SupabaseService.displayUsername(receiverUsername);
    final isGroupCall = groupId != null && groupId.trim().isNotEmpty;

    final payload = {
      'call_id': callId,
      'caller_name': isGroupCall ? '${_currentName} • ${groupName ?? 'مجموعة'}' : _currentName,
      'caller_username': _currentUsername,
      'caller_avatar': _currentAvatarPath ?? '',
      'video': video,
      'is_video': video,
      'call_type': callType,
      'kind': callType,
      'is_group_call': isGroupCall,
      'group_id': groupId ?? '',
      'group_name': groupName ?? '',
      'sent_at': DateTime.now().toIso8601String(),
    };

    await SupabaseService.sendUserBroadcast(username: receiver, event: 'incoming_call', payload: payload);
    unawaited(SupabaseService.sendIncomingCallPush(
      receiverUsername: receiver,
      callId: callId,
      callerUsername: _currentUsername,
      callerName: payload['caller_name'].toString(),
      callerAvatar: _currentAvatarPath ?? '',
      video: video,
    ));
  }

  Future<void> _showGroupCallPicker({required bool video}) async {
    if (!_isGroup || _activeGroupId == null) return;

    List<Map<String, dynamic>> members;
    try {
      members = await SupabaseService.getChatGroupMembers(_activeGroupId!);
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('تعذر تحميل أعضاء المجموعة: $e');
      return;
    }

    final candidates = members.where((m) {
      final username = SupabaseService.displayUsername((m['username'] ?? '').toString());
      return username.isNotEmpty && username != SupabaseService.displayUsername(_currentUsername);
    }).toList();

    if (candidates.isEmpty) {
      if (!mounted) return;
      NotificationService.showTopNotification('لا يوجد أعضاء آخرين للاتصال بهم');
      return;
    }

    final selected = candidates.map((m) => SupabaseService.displayUsername((m['username'] ?? '').toString())).toSet();

    final chosen = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.72,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: AppColors.purple.withOpacity(.18),
                        child: Icon(video ? Icons.videocam_rounded : Icons.call_rounded, color: AppColors.purple),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(video ? 'مكالمة فيديو جماعية' : 'مكالمة صوتية جماعية', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                            const SizedBox(height: 2),
                            Text('اختر أعضاء المجموعة الذين تريد الاتصال بهم', style: TextStyle(color: Theme.of(ctx).hintColor, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: () => setLocal(() {
                          selected
                            ..clear()
                            ..addAll(candidates.map((m) => SupabaseService.displayUsername((m['username'] ?? '').toString())));
                        }),
                        icon: const Icon(Icons.done_all_rounded),
                        label: const Text('تحديد الكل'),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => setLocal(selected.clear),
                        icon: const Icon(Icons.clear_rounded),
                        label: const Text('إلغاء التحديد'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: candidates.length,
                    separatorBuilder: (_, __) => Divider(color: AppColors.purple.withOpacity(.10)),
                    itemBuilder: (ctx, i) {
                      final u = candidates[i];
                      final username = SupabaseService.displayUsername((u['username'] ?? '').toString());
                      final name = (u['name'] ?? u['profileName'] ?? username).toString();
                      final avatarPath = (u['avatar_url'] ?? u['imagePath'] ?? u['profileImagePath'])?.toString();
                      final avatar = _fileImage(avatarPath);
                      return CheckboxListTile(
                        value: selected.contains(username),
                        onChanged: (v) => setLocal(() {
                          if (v == true) {
                            selected.add(username);
                          } else {
                            selected.remove(username);
                          }
                        }),
                        secondary: CircleAvatar(backgroundImage: avatar, child: avatar == null ? const Icon(Icons.person_rounded) : null),
                        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text(username),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('إلغاء'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: selected.isEmpty ? null : () => Navigator.pop(ctx, Set<String>.from(selected)),
                          icon: Icon(video ? Icons.videocam_rounded : Icons.call_rounded),
                          label: Text('اتصال (${selected.length})'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (chosen == null || chosen.isEmpty) return;
    await _startGroupCallWithMembers(video: video, selectedUsernames: chosen, members: candidates);
  }

  Future<void> _startGroupCallWithMembers({
    required bool video,
    required Set<String> selectedUsernames,
    required List<Map<String, dynamic>> members,
  }) async {
    final groupId = _activeGroupId;
    if (groupId == null || selectedUsernames.isEmpty) return;

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final safeGroup = groupId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_');
    final safeMe = SupabaseService.normalizeUsername(_currentUsername);
    final firstUsername = selectedUsernames.first;
    final firstMember = members.firstWhere(
          (m) => SupabaseService.displayUsername((m['username'] ?? '').toString()) == firstUsername,
      orElse: () => {'username': firstUsername},
    );

    for (final username in selectedUsernames) {
      final safePeer = SupabaseService.normalizeUsername(username);
      final callId = 'group_${safeGroup}_${safeMe}_${safePeer}_$stamp';
      await _sendCallInviteToUser(
        receiverUsername: username,
        callId: callId,
        video: video,
        groupId: groupId,
        groupName: _activeGroupName ?? 'مجموعة',
      );
    }

    if (!mounted) return;
    NotificationService.showTopNotification('تم إرسال دعوة المكالمة إلى ${selectedUsernames.length} عضو');

    // ملاحظة مهمة: خدمة WebRTC الحالية في المشروع مبنية على اتصال طرفين فقط.
    // لذلك يفتح التطبيق أول عضو الآن، وباقي الأعضاء تصلهم دعوة الاتصال.
    // عند إضافة SFU/mesh لاحقاً يمكن جمع كل المشاركين داخل شاشة واحدة.
    final firstCallId = 'group_${safeGroup}_${safeMe}_${SupabaseService.normalizeUsername(firstUsername)}_$stamp';
    final firstName = (firstMember['name'] ?? firstMember['profileName'] ?? firstUsername).toString();
    final firstAvatar = (firstMember['avatar_url'] ?? firstMember['imagePath'] ?? firstMember['profileImagePath'])?.toString();

    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallScreen(
      callId: firstCallId,
      peerName: selectedUsernames.length == 1 ? firstName : '${_activeGroupName ?? 'مجموعة'} • $firstName',
      peerAvatarPath: firstAvatar,
      video: video,
      isCaller: true,
      callService: CallService(),
      callerName: _currentName,
      callerUsername: _currentUsername,
      calleeUsername: firstUsername,
    )));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _threads.isEmpty && _activePeerUsername == null && _activeGroupId == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_activePeerUsername == null && _activeGroupId == null) return _buildInbox(context);
    return _buildConversation(context);
  }

  Widget _buildInbox(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: null,
      body: RefreshIndicator(
        onRefresh: _loadAll,
        child: Column(
          children: [
            // الشريط العلوي البديل (بدون AppBar)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBg : AppColors.lightBg,
                border: Border(
                  bottom: BorderSide(
                    color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                  ),
                ),
              ),
              child: Row(
                children: [
                  const Text(
                    'الرسائل',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: 'إنشاء مجموعة',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _showCreateGroupDialog,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.purple.withOpacity(.14),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.purple.withOpacity(.28)),
                        ),
                        child: const Icon(Icons.group_add_rounded, size: 22, color: AppColors.purple),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // قائمة المحادثات
            Expanded(
              child: _threads.isEmpty
                  ? ListView(
                children: [
                  SizedBox(height: MediaQuery.of(context).size.height * 0.32),
                  Icon(Icons.forum_rounded, size: 70, color: AppColors.purple.withOpacity(.55)),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      'لا توجد محادثات بعد',
                      style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                    ),
                  ),
                ],
              )
                  : ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 96),
                itemCount: _threads.length,
                itemBuilder: (context, i) {
                  final t = _threads[i];
                  final avatar = _fileImage(t.peerAvatarPath);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GlassCard(
                      onTap: () => _openThread(t),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 28,
                            backgroundColor: t.isGroup ? AppColors.purple : AppColors.purple,
                            backgroundImage: avatar,
                            child: avatar == null
                                ? Icon(t.isGroup ? Icons.groups_rounded : Icons.person_rounded, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t.peerName, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                                const SizedBox(height: 3),
                                Text(
                                  t.isGroup ? 'مجموعة' : t.peerUsername,
                                  style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontSize: 12),
                                ),
                                const SizedBox(height: 5),
                                Text(t.lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_left_rounded, color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversation(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final messages = _activeMessages;
    final avatar = _fileImage(_isGroup ? _activeGroupAvatar : _activePeerAvatarPath);

    return Scaffold(
      appBar: null,
      body: Column(children: [
        _buildConversationHeader(context, avatar),
        Expanded(
          child: messages.isEmpty
              ? Center(child: Text('ابدأ أول رسالة الآن', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)))
              : ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
            itemCount: messages.length + (_peerTyping ? 1 : 0),
            itemBuilder: (context, i) {
              if (_peerTyping && i == messages.length) return _TypingBubble(name: _typingName ?? 'مستخدم', mode: _peerTypingMode);
              return _buildMessageBubble(context, messages[i]);
            },
          ),
        ),
        if (!_canSend)
          Container(width: double.infinity, padding: const EdgeInsets.all(12), color: AppColors.danger.withOpacity(.10), child: const Text('الدردشة مقفلة، الإرسال متاح للمشرفين فقط', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800))),
        if (_editingMessage != null)
          _EditPreviewBar(
            text: _editingMessage?.text ?? '',
            onClose: _cancelEditingMessage,
          ),
        if (_replyToMessage != null && _editingMessage == null)
          Builder(
            builder: (_) {
              final reply = _replyToMessage;
              if (reply == null) return const SizedBox.shrink();
              return _ReplyPreviewBar(
                sender: reply.senderUsername == _currentUsername ? 'أنت' : (reply.senderName ?? reply.senderUsername),
                text: _messagePreview(reply),
                onClose: () => setState(() => _replyToMessage = null),
              );
            },
          ),
        if (_recordingVoice && _lockedVoiceRecording)
          _LockedVoiceRecorderBar(
            duration: _voicePaused
                ? _voicePausedElapsed
                : (_voiceRecordStartedAt == null
                ? Duration.zero
                : DateTime.now().difference(_voiceRecordStartedAt!)),
            paused: _voicePaused,
            startedAt: _voiceRecordStartedAt,
            pausedElapsed: _voicePausedElapsed,
            waveform: _recordingVoiceWaveform,
            onCancel: _cancelVoiceRecording,
            onPauseResume: _toggleVoicePause,
            onPreview: _finishVoiceForPreview,
            onSend: _stopAndSendVoice,
          ),
        if (_pendingVoicePath != null)
          _PendingVoicePreviewBar(
            path: _pendingVoicePath!,
            seconds: _pendingVoiceSeconds,
            isPlaying: _playingVoiceUrl == _pendingVoicePath,
            position: _playingVoiceUrl == _pendingVoicePath ? _voicePosition : Duration.zero,
            duration: _playingVoiceUrl == _pendingVoicePath ? _voiceDuration : Duration(seconds: _pendingVoiceSeconds <= 0 ? 1 : _pendingVoiceSeconds),
            speed: _voiceSpeed,
            waveform: _pendingVoiceWaveform,
            onPlay: () => _playVoice(_pendingVoicePath!),
            onSeek: _seekVoice,
            onSpeedTap: _changeVoiceSpeed,
            onCancel: _cancelPendingVoice,
            onSend: _sendPendingVoice,
          ),
        if (_pendingMedia.isNotEmpty)
          _PendingMediaPreviewBar(
            items: _pendingMedia,
            maxViews: _pendingMediaMaxViews,
            onMaxViewsChanged: _setPendingMediaMaxViews,
            onRemove: _removePendingMediaAt,
            onClear: _clearPendingMedia,
          ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: isDark ? AppColors.darkCard : AppColors.lightCard, border: Border(top: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder))),
          child: SafeArea(top: false, child: Row(children: [
            CircleAvatar(
              backgroundColor: _canSend ? AppColors.purple.withOpacity(.16) : Colors.grey.withOpacity(.20),
              child: IconButton(
                tooltip: 'إرسال صورة أو فيديو',
                icon: _sendingMedia
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.purple))
                    : const Icon(Icons.attach_file_rounded, color: AppColors.purple),
                onPressed: _canSend ? _showAttachmentSheet : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: TextField(
              controller: _msgCtrl,
              enabled: _canSend && !_sending,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
              decoration: InputDecoration(
                hintText: _editingMessage != null ? 'عدّل رسالتك...' : (_canSend ? 'اكتب رسالة...' : 'الدردشة مقفلة'),
                filled: true,
                fillColor: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
            )),
            const SizedBox(width: 8),
            GestureDetector(
              onPanDown: _handleVoicePressStart,
              onPanUpdate: _handleVoicePressMove,
              onPanEnd: _handleVoicePressEnd,
              onPanCancel: _handleVoicePressCancel,
              child: CircleAvatar(
                backgroundColor: _recordingVoice ? AppColors.danger : (_canSend ? AppColors.purple.withOpacity(.85) : Colors.grey),
                child: _sendingVoice
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(_recordingVoice ? (_lockedVoiceRecording ? Icons.lock_rounded : Icons.mic_rounded) : Icons.mic_rounded, color: Colors.white),
              ),
            ),
            const SizedBox(width: 8),
            CircleAvatar(backgroundColor: _canSend ? AppColors.purple : Colors.grey, child: IconButton(icon: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send_rounded, color: Colors.white), onPressed: _canSend ? _sendMessage : null)),
          ])),
        ),
      ]),
    );
  }

  Widget _buildConversationHeader(BuildContext context, ImageProvider? avatar) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = _conversationTitle.trim().isEmpty ? 'الرسائل' : _conversationTitle;
    final subtitle = _conversationSubtitle.trim();

    if (_selectionMode) {
      return SafeArea(
        bottom: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBg : AppColors.lightBg,
            border: Border(bottom: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder)),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'إلغاء التحديد',
                onPressed: _clearSelection,
                icon: const Icon(Icons.close_rounded),
              ),
              Text(
                '${_selectedMessageIds.length}',
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'رد',
                onPressed: _selectedMessages.length == 1 ? () => _startReplyTo(_selectedMessages.first) : null,
                icon: const Icon(Icons.reply_rounded),
              ),
              IconButton(
                tooltip: 'نسخ',
                onPressed: _copySelectedMessages,
                icon: const Icon(Icons.copy_rounded),
              ),
              IconButton(
                tooltip: 'تعديل',
                onPressed: _canEditSelectedMessage ? _startEditSelectedMessage : null,
                icon: const Icon(Icons.edit_rounded),
              ),
              IconButton(
                tooltip: 'تحميل',
                onPressed: _downloadSelectedMedia,
                icon: const Icon(Icons.download_rounded),
              ),
              IconButton(
                tooltip: 'حذف',
                onPressed: _showDeleteSelectionSheet,
                icon: const Icon(Icons.delete_rounded, color: AppColors.danger),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkBg : AppColors.lightBg,
          border: Border(bottom: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? .20 : .06),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'رجوع',
              onPressed: () {
                setState(() {
                  _activePeerUsername = null;
                  _activePeerName = null;
                  _activePeerAvatarPath = null;
                  _activeGroupId = null;
                  _activeGroupName = null;
                  _activeGroupAvatar = null;
                  _selectedMessageIds.clear();
                  _replyToMessage = null;
                  _editingMessage = null;
                });
                _notifyConversationActive(false);
                _refreshThreadsOnly();
              },
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            CircleAvatar(
              radius: 21,
              backgroundColor: _isGroup ? AppColors.purple : AppColors.purple,
              backgroundImage: avatar,
              child: avatar == null
                  ? Icon(_isGroup ? Icons.groups_rounded : Icons.person_rounded, color: Colors.white, size: 22)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                  if (subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _peerTyping ? AppColors.purple : (isDark ? AppColors.darkMuted : AppColors.lightMuted),
                          fontSize: 12,
                          fontWeight: _peerTyping ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (!_isGroup) ...[
              _HeaderActionButton(
                tooltip: 'اتصال صوتي',
                icon: Icons.call_rounded,
                onTap: () => _startCall(video: false),
              ),
              const SizedBox(width: 6),
              _HeaderActionButton(
                tooltip: 'مكالمة فيديو',
                icon: Icons.videocam_rounded,
                onTap: () => _startCall(video: true),
              ),
            ] else ...[
              _HeaderActionButton(
                tooltip: 'اتصال جماعي',
                icon: Icons.call_rounded,
                onTap: () => _startCall(video: false),
              ),
              const SizedBox(width: 6),
              _HeaderActionButton(
                tooltip: 'فيديو جماعي',
                icon: Icons.videocam_rounded,
                onTap: () => _startCall(video: true),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(BuildContext context, _DirectMessage msg) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMe = msg.senderUsername == _currentUsername;
    final user = _accountByUsername(_users, msg.senderUsername);
    final name = msg.senderName?.trim().isNotEmpty == true ? msg.senderName! : (user?['name'] ?? user?['profileName'] ?? msg.senderUsername).toString();
    final avatarPath = msg.senderAvatar ?? (user?['avatar_url'] ?? user?['imagePath'] ?? user?['profileImagePath'])?.toString();
    final avatar = _fileImage(avatarPath);
    final isHighlighted = _highlightMessageId == msg.id;
    final bubbleKey = _messageKeys.putIfAbsent(msg.id, () => GlobalKey());

    return Padding(
      key: bubbleKey,
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) CircleAvatar(radius: 16, backgroundImage: avatar, child: avatar == null ? const Icon(Icons.person_rounded, size: 16) : null),
          if (!isMe) const SizedBox(width: 6),
          Flexible(
            child: _SwipeReplyMessageShell(
              enabled: !_selectionMode,
              isMe: isMe,
              onReply: () => _startReplyTo(msg),
              child: GestureDetector(
                onTap: () {
                  if (_selectionMode) {
                    _toggleMessageSelection(msg);
                  } else if (msg.hasVisualMedia) {
                    _openMediaViewer(msg);
                  }
                },
                onLongPress: () => _toggleMessageSelection(msg),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
                  decoration: BoxDecoration(
                    color: _selectedMessageIds.contains(msg.id) ? AppColors.purple.withOpacity(.34) : (isMe ? AppColors.purple.withOpacity(0.88) : (isDark ? AppColors.darkCard : AppColors.lightCard2)),
                    border: Border.all(color: isHighlighted ? AppColors.purple.withOpacity(.95) : (_selectedMessageIds.contains(msg.id) ? Colors.white.withOpacity(.65) : Colors.transparent), width: isHighlighted ? 1.8 : 1.2),
                    boxShadow: isHighlighted
                        ? [
                      BoxShadow(
                        color: AppColors.purple.withOpacity(.72),
                        blurRadius: 26,
                        spreadRadius: 3,
                      ),
                      BoxShadow(
                        color: AppColors.purple.withOpacity(.35),
                        blurRadius: 42,
                        spreadRadius: 9,
                      ),
                    ]
                        : const [],
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: isMe ? const Radius.circular(18) : Radius.zero,
                      bottomRight: isMe ? Radius.zero : const Radius.circular(18),
                    ),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: isMe ? Colors.white70 : AppColors.purple)),
                    if ((msg.replyText ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 5),
                      _InlineReplyPreview(sender: msg.replySender ?? '', text: msg.replyText ?? '', isMe: isMe, onTap: () => _jumpToRepliedMessage(msg.replyToId)),
                    ],
                    const SizedBox(height: 3),
                    if (msg.isVoice)
                      _VoiceMessagePlayer(
                        isMe: isMe,
                        voiceSeconds: msg.voiceSeconds,
                        isPlaying: _playingVoiceUrl == msg.mediaUrl,
                        position: _playingVoiceUrl == msg.mediaUrl ? _voicePosition : Duration.zero,
                        duration: _playingVoiceUrl == msg.mediaUrl ? _voiceDuration : Duration(seconds: msg.voiceSeconds),
                        speed: _voiceSpeed,
                        waveform: _voiceWaveformCache[msg.mediaUrl ?? ''] ?? const <double>[],
                        onTap: () => _playVoice(msg.mediaUrl ?? ''),
                        onSeek: (p) => _seekVoice(p),
                        onSpeedTap: _changeVoiceSpeed,
                      )
                    else if (msg.isMediaGroup)
                      _ChatMediaGalleryMessage(
                        items: msg.mediaItems,
                        caption: msg.text,
                        isMe: isMe,
                        limitedMaxViews: msg.limitedMediaMaxViews,
                        onOpen: (index) => _openMediaViewer(msg, initialIndex: index),
                      )
                    else if (msg.isImage)
                        _ChatImageMessage(url: msg.mediaUrl ?? '', caption: msg.text, isMe: isMe, onTap: () => _openMediaViewer(msg), limitedMaxViews: msg.limitedMediaMaxViews)
                      else if (msg.isVideo)
                          _ChatVideoMessage(url: msg.mediaUrl ?? '', caption: msg.text, isMe: isMe, onTap: () => _openMediaViewer(msg), limitedMaxViews: msg.limitedMediaMaxViews)
                        else
                          Text(msg.text, style: TextStyle(color: isMe ? Colors.white : null, height: 1.35)),
                    const SizedBox(height: 4),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(_formatTime(msg.createdAt), style: TextStyle(fontSize: 10.5, color: isMe ? Colors.white70 : (isDark ? AppColors.darkMuted : AppColors.lightMuted))),
                      if (isMe) ...[
                        const SizedBox(width: 5),
                        _MessageStatusIcon(status: msg.status),
                      ],
                    ]),
                  ]),
                ),
              ),
            ),
          ),
          if (isMe) const SizedBox(width: 6),
          if (isMe) CircleAvatar(radius: 16, backgroundImage: avatar, child: avatar == null ? const Icon(Icons.person_rounded, size: 16) : null),
        ],
      ),
    );
  }

  String callerNameFromUsername(String username) {
    final clean = SupabaseService.displayUsername(username);
    final user = _accountByUsername(_users, clean);
    return (user?['name'] ?? user?['profileName'] ?? clean).toString();
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final suffix = dt.hour < 12 ? 'صباحًا' : 'مساءً';
      final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      return '${h.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} $suffix';
    } catch (_) {
      return 'الآن';
    }
  }

  bool _payloadBool(dynamic value) {
    if (value == true) return true;
    final text = value?.toString().toLowerCase().trim();
    return text == 'true' || text == '1' || text == 'yes' || text == 'video';
  }
}



class _EditPreviewBar extends StatelessWidget {
  final String text;
  final VoidCallback onClose;
  const _EditPreviewBar({required this.text, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
        borderRadius: BorderRadius.circular(16),
        border: Border(right: BorderSide(color: AppColors.purple, width: 4)),
      ),
      child: Row(children: [
        const Icon(Icons.edit_rounded, color: AppColors.purple, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('تعديل الرسالة', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: AppColors.purple)),
          Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black87)),
        ])),
        IconButton(onPressed: onClose, icon: const Icon(Icons.close_rounded, size: 18)),
      ]),
    );
  }
}

class _ReplyPreviewBar extends StatelessWidget {
  final String sender;
  final String text;
  final VoidCallback onClose;
  const _ReplyPreviewBar({required this.sender, required this.text, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
        borderRadius: BorderRadius.circular(16),
        border: Border(right: BorderSide(color: AppColors.purple, width: 4)),
      ),
      child: Row(children: [
        const Icon(Icons.reply_rounded, color: AppColors.purple, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(sender, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: AppColors.purple)),
          Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black87)),
        ])),
        IconButton(onPressed: onClose, icon: const Icon(Icons.close_rounded, size: 18)),
      ]),
    );
  }
}



class _PendingMediaPreviewBar extends StatelessWidget {
  final List<_PendingChatMedia> items;
  final int maxViews;
  final ValueChanged<int> onMaxViewsChanged;
  final ValueChanged<int> onRemove;
  final VoidCallback onClear;

  const _PendingMediaPreviewBar({
    required this.items,
    required this.maxViews,
    required this.onMaxViewsChanged,
    required this.onRemove,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.purple.withOpacity(.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.collections_rounded, size: 18, color: AppColors.purple),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                items.length == 1 ? 'جاهز للإرسال' : '${items.length} ملفات في رسالة واحدة',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            IconButton(
              tooltip: 'إلغاء',
              onPressed: onClear,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.visibility_rounded, color: AppColors.purple, size: 17),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                maxViews == 0 ? 'عرض عادي' : (maxViews == 1 ? 'عرض مرة واحدة للمستلم' : 'عرض مرتين للمستلم'),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: isDark ? Colors.white70 : Colors.black87),
              ),
            ),
            _MediaViewLimitChip(label: 'عادي', selected: maxViews == 0, onTap: () => onMaxViewsChanged(0)),
            const SizedBox(width: 6),
            _MediaViewLimitChip(label: '1', selected: maxViews == 1, onTap: () => onMaxViewsChanged(1)),
            const SizedBox(width: 6),
            _MediaViewLimitChip(label: '2', selected: maxViews == 2, onTap: () => onMaxViewsChanged(2)),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final item = items[i];
                return Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: item.isVideo
                          ? Container(
                        width: 84,
                        height: 84,
                        color: Colors.black.withOpacity(.22),
                        child: const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 34),
                      )
                          : Image.file(
                        File(item.path),
                        width: 84,
                        height: 84,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 84,
                          height: 84,
                          color: Colors.black.withOpacity(.12),
                          child: const Icon(Icons.broken_image_rounded),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: () => onRemove(i),
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(color: Colors.black.withOpacity(.62), shape: BoxShape.circle),
                          child: const Icon(Icons.close_rounded, color: Colors.white, size: 15),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}


class _MediaViewLimitChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MediaViewLimitChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.purple : Colors.white.withOpacity(.07),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? AppColors.purple : Colors.white.withOpacity(.12)),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 11)),
      ),
    );
  }
}


class _SwipeReplyMessageShell extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final bool isMe;
  final VoidCallback onReply;

  const _SwipeReplyMessageShell({
    required this.child,
    required this.enabled,
    required this.isMe,
    required this.onReply,
  });

  @override
  State<_SwipeReplyMessageShell> createState() => _SwipeReplyMessageShellState();
}

class _SwipeReplyMessageShellState extends State<_SwipeReplyMessageShell> {
  static const double _triggerDistance = 68;
  static const double _maxDrag = 112;

  double _dragOffset = 0;
  bool _replyHintHapticDone = false;

  void _resetDrag() {
    if (!mounted) return;
    setState(() {
      _dragOffset = 0;
      _replyHintHapticDone = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && _dragOffset.abs() > 0;
    final progress = (_dragOffset.abs() / _triggerDistance).clamp(0.0, 1.0);
    final direction = widget.isMe ? -1.0 : 1.0;
    final easedOffset = Curves.easeOutCubic.transform((_dragOffset.abs() / _maxDrag).clamp(0.0, 1.0)) * _maxDrag * direction;

    return Stack(
      alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
      clipBehavior: Clip.none,
      children: [
        PositionedDirectional(
          start: widget.isMe ? null : 12,
          end: widget.isMe ? 12 : null,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: active ? progress : 0,
            child: Transform.scale(
              scale: 0.72 + (progress * 0.28),
              child: Container(
                width: 34,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.purple.withOpacity(.22 + (progress * .26)),
                  border: Border.all(color: AppColors.purple.withOpacity(.45 + (progress * .35))),
                ),
                child: Icon(
                  Icons.reply_rounded,
                  size: 20,
                  color: Colors.white.withOpacity(.72 + (progress * .28)),
                ),
              ),
            ),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: widget.enabled
              ? (_) {
            _replyHintHapticDone = false;
          }
              : null,
          onHorizontalDragUpdate: widget.enabled
              ? (details) {
            final wantedDirection = widget.isMe ? -1.0 : 1.0;
            final delta = details.delta.dx * wantedDirection;
            if (delta < 0 && _dragOffset.abs() <= 0.5) return;
            final resistance = _dragOffset.abs() > _triggerDistance ? 0.36 : 0.94;
            final nextAbs = (_dragOffset.abs() + (delta * resistance)).clamp(0.0, _maxDrag).toDouble();
            final next = nextAbs * wantedDirection;
            if (nextAbs >= _triggerDistance && !_replyHintHapticDone) {
              _replyHintHapticDone = true;
              HapticFeedback.selectionClick();
            }
            if (next != _dragOffset) setState(() => _dragOffset = next);
          }
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (_) {
            final shouldReply = _dragOffset.abs() >= _triggerDistance;
            _resetDrag();
            if (shouldReply) widget.onReply();
          }
              : null,
          onHorizontalDragCancel: widget.enabled ? _resetDrag : null,
          child: AnimatedContainer(
            duration: _dragOffset == 0 ? const Duration(milliseconds: 220) : Duration.zero,
            curve: Curves.easeOutBack,
            transform: Matrix4.translationValues(easedOffset, 0, 0),
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _InlineReplyPreview extends StatelessWidget {
  final String sender;
  final String text;
  final bool isMe;
  final VoidCallback? onTap;
  const _InlineReplyPreview({required this.sender, required this.text, required this.isMe, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 210,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: isMe ? Colors.white.withOpacity(.14) : AppColors.purple.withOpacity(.10),
          borderRadius: BorderRadius.circular(12),
          border: Border(right: BorderSide(color: isMe ? Colors.white70 : AppColors.purple, width: 3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(sender.isEmpty ? 'رد' : sender, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10.5, color: isMe ? Colors.white : AppColors.purple)),
          const SizedBox(height: 2),
          Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: isMe ? Colors.white70 : null)),
        ]),
      ),
    );
  }
}

class _MediaViewerPage extends StatefulWidget {
  final _DirectMessage message;
  final String title;
  final int initialIndex;
  final VoidCallback onDownload;

  const _MediaViewerPage({
    required this.message,
    required this.title,
    this.initialIndex = 0,
    required this.onDownload,
  });

  @override
  State<_MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<_MediaViewerPage> {
  late final PageController _pageController;
  late int _index;
  VideoPlayerController? _controller;
  String? _videoUrl;
  bool _videoReady = false;
  bool _showControls = true;
  bool _muted = false;
  bool _videoError = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  List<_ChatMediaItem> get _items => widget.message.mediaItems;

  @override
  void initState() {
    super.initState();
    final count = _items.length;
    _index = count == 0 ? 0 : widget.initialIndex.clamp(0, count - 1).toInt();
    _pageController = PageController(initialPage: _index);
    _initCurrentIfVideo();
  }

  Future<void> _initCurrentIfVideo() async {
    final items = _items;
    if (items.isEmpty) return;
    final item = items[_index];
    await _disposeVideo();
    if (item.isVideo) await _initVideo(item.url);
  }

  Future<void> _disposeVideo() async {
    final c = _controller;
    _controller = null;
    _videoUrl = null;
    _videoReady = false;
    _videoError = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    if (c != null) {
      try { c.removeListener(_videoTick); } catch (e, st) { _logIgnoredError(e, st); }
      try { await c.dispose(); } catch (e, st) { _logIgnoredError(e, st); }
    }
  }

  Future<void> _initVideo(String url) async {
    try {
      _videoUrl = url;
      final c = VideoPlayerController.networkUrl(Uri.parse(url));
      _controller = c;
      c.addListener(_videoTick);
      await c.initialize();
      await c.setLooping(false);
      await c.play();
      if (!mounted || _videoUrl != url) return;
      setState(() {
        _videoReady = true;
        _duration = c.value.duration;
      });
    } catch (_) {
      if (mounted) setState(() => _videoError = true);
    }
  }

  void _videoTick() {
    final c = _controller;
    if (c == null || !mounted || !c.value.isInitialized) return;
    final nextPosition = c.value.position;
    final nextDuration = c.value.duration;
    if ((nextPosition - _position).abs() < const Duration(milliseconds: 250) && nextDuration == _duration) return;
    setState(() {
      _position = nextPosition;
      _duration = nextDuration;
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    final c = _controller;
    if (c != null) {
      c.removeListener(_videoTick);
      c.dispose();
    }
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$sec' : '$m:$sec';
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play();
    setState(() {});
  }

  Future<void> _seekVideo(double ms) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final d = Duration(milliseconds: ms.toInt());
    await c.seekTo(d);
    setState(() => _position = d);
  }

  Widget _buildVideo(_ChatMediaItem item) {
    final c = _controller;
    if (_videoError) {
      return Column(mainAxisSize: MainAxisSize.min, children: const [
        Icon(Icons.error_outline_rounded, color: Colors.white70, size: 46),
        SizedBox(height: 10),
        Text('تعذر تشغيل الفيديو', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
      ]);
    }
    if (!_videoReady || c == null || !c.value.isInitialized || _videoUrl != item.url) {
      return const Center(child: CircularProgressIndicator(color: AppColors.purple));
    }
    return GestureDetector(
      onTap: () => setState(() => _showControls = !_showControls),
      onDoubleTap: _togglePlay,
      child: Center(
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio <= 0 ? 16 / 9 : c.value.aspectRatio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: VideoPlayer(c),
          ),
        ),
      ),
    );
  }

  Widget _buildItem(_ChatMediaItem item) {
    if (item.isVideo) return _buildVideo(item);
    return InteractiveViewer(
      minScale: 0.7,
      maxScale: 4,
      child: Center(
        child: Image.network(
          item.url,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Text('تعذر عرض الصورة', style: TextStyle(color: Colors.white)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items.isEmpty) return const SizedBox.shrink();

    final current = items[_index];
    final caption = widget.message.text.trim();
    final showCaption = caption.isNotEmpty && caption != 'صورة' && caption != 'فيديو' && caption != '${items.length} ملفات';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(items.length > 1 ? '${_index + 1} / ${items.length}' : widget.title),
        actions: [IconButton(onPressed: widget.onDownload, icon: const Icon(Icons.download_rounded))],
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: items.length,
            onPageChanged: (i) async {
              setState(() => _index = i);
              await _initCurrentIfVideo();
            },
            itemBuilder: (_, i) => _buildItem(items[i]),
          ),
          if (current.isVideo && _videoReady && _showControls)
            Positioned(
              left: 14,
              right: 14,
              bottom: items.length > 1 ? 104 : 34,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: Colors.black.withOpacity(.55), borderRadius: BorderRadius.circular(16)),
                child: Row(children: [
                  IconButton(onPressed: _togglePlay, icon: Icon(_controller?.value.isPlaying == true ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white)),
                  Text(_fmt(_position), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  Expanded(
                    child: Slider(
                      value: _position.inMilliseconds.toDouble().clamp(0, math.max(1, _duration.inMilliseconds).toDouble()).toDouble(),
                      min: 0,
                      max: math.max(1, _duration.inMilliseconds).toDouble(),
                      onChanged: _seekVideo,
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      final c = _controller;
                      if (c == null) return;
                      _muted = !_muted;
                      await c.setVolume(_muted ? 0 : 1);
                      if (mounted) setState(() {});
                    },
                    icon: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: Colors.white),
                  ),
                ]),
              ),
            ),
          if (showCaption)
            Positioned(
              left: 18,
              right: 18,
              bottom: items.length > 1 ? 160 : 96,
              child: Text(caption, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
            ),
          if (items.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 18,
              child: SizedBox(
                height: 72,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final item = items[i];
                    final selected = i == _index;
                    return GestureDetector(
                      onTap: () => _pageController.animateToPage(i, duration: const Duration(milliseconds: 220), curve: Curves.easeOut),
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: selected ? AppColors.purple : Colors.white24, width: selected ? 2.2 : 1),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: item.isVideo
                            ? Container(color: Colors.white10, child: const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 26))
                            : Image.network(item.url, fit: BoxFit.cover),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HeaderActionButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  const _HeaderActionButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.purple.withOpacity(.14),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.purple.withOpacity(.28)),
          ),
          child: Icon(icon, color: AppColors.purple, size: 22),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatefulWidget {
  final String name;
  final String mode;
  const _TypingBubble({required this.name, this.mode = 'text'});
  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: FadeTransition(
        opacity: Tween<double>(begin: .45, end: 1).animate(_c),
        child: Container(
          margin: const EdgeInsets.only(left: 8, bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppColors.purple.withOpacity(.12), borderRadius: BorderRadius.circular(18)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.mode == 'voice' ? Icons.mic_rounded : Icons.edit_rounded, size: 15, color: AppColors.purple),
              const SizedBox(width: 6),
              Text(
                widget.mode == 'voice' ? '${widget.name} يسجل رسالة صوتية...' : '${widget.name} يكتب الآن...',
                style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w800, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageStatusIcon extends StatelessWidget {
  final MessageStatus status;
  const _MessageStatusIcon({required this.status});
  @override
  Widget build(BuildContext context) {
    if (status == MessageStatus.sent) {
      return const Icon(Icons.check_rounded, size: 16, color: Colors.white);
    }
    if (status == MessageStatus.delivered) {
      return const Icon(Icons.done_all_rounded, size: 16, color: Colors.white);
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        boxShadow: [BoxShadow(color: const Color(0xFF4C1D95).withOpacity(.75), blurRadius: 9, spreadRadius: 1)],
      ),
      child: const Icon(Icons.done_all_rounded, size: 16, color: Color(0xFF4C1D95)),
    );
  }
}


class _VoiceMessagePlayer extends StatelessWidget {
  final bool isMe;
  final int voiceSeconds;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final double speed;
  final List<double> waveform;
  final VoidCallback onTap;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onSpeedTap;

  const _VoiceMessagePlayer({
    required this.isMe,
    required this.voiceSeconds,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.speed,
    this.waveform = const <double>[],
    required this.onTap,
    required this.onSeek,
    required this.onSpeedTap,
  });

  String _fmt(Duration d) {
    final total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds > 0 ? duration : Duration(seconds: voiceSeconds <= 0 ? 1 : voiceSeconds);
    final progress = total.inMilliseconds <= 0 ? 0.0 : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0).toDouble();
    final accent = isMe ? Colors.white : AppColors.purple;
    return Container(
      width: 208,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
      decoration: BoxDecoration(
        color: isMe ? Colors.white.withOpacity(.10) : AppColors.purple.withOpacity(.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withOpacity(.16)),
      ),
      child: Row(children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(99),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isMe ? Colors.white.withOpacity(.18) : AppColors.purple.withOpacity(.16),
              shape: BoxShape.circle,
            ),
            child: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: accent, size: 22),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _SmoothVoiceWaveform(
              height: 26,
              progress: progress,
              accent: accent,
              seed: voiceSeconds + (isMe ? 17 : 31),
              waveform: waveform,
              onSeekFactor: (factor) => onSeek(Duration(milliseconds: (total.inMilliseconds * factor).round())),
            ),
            const SizedBox(height: 4),
            Row(children: [
              Text(_fmt(isPlaying ? position : Duration.zero), style: TextStyle(color: accent.withOpacity(.76), fontWeight: FontWeight.w800, fontSize: 10.5)),
              const Spacer(),
              Text(_fmt(total), style: TextStyle(color: accent.withOpacity(.76), fontWeight: FontWeight.w800, fontSize: 10.5)),
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        InkWell(
          onTap: onSpeedTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
            decoration: BoxDecoration(
              color: accent.withOpacity(.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accent.withOpacity(.15)),
            ),
            child: Text('${speed.toStringAsFixed(speed == speed.roundToDouble() ? 0 : 2)}x', style: TextStyle(color: accent, fontWeight: FontWeight.w900, fontSize: 11)),
          ),
        ),
      ]),
    );
  }
}


class _SmoothVoiceWaveform extends StatefulWidget {
  final double height;
  final double progress;
  final Color accent;
  final int seed;
  final List<double> waveform;
  final ValueChanged<double> onSeekFactor;

  const _SmoothVoiceWaveform({
    required this.height,
    required this.progress,
    required this.accent,
    required this.seed,
    this.waveform = const <double>[],
    required this.onSeekFactor,
  });

  @override
  State<_SmoothVoiceWaveform> createState() => _SmoothVoiceWaveformState();
}

class _SmoothVoiceWaveformState extends State<_SmoothVoiceWaveform> {
  double? _dragProgress;
  DateTime _lastSeekAt = DateTime.fromMillisecondsSinceEpoch(0);

  double get _visibleProgress => (_dragProgress ?? widget.progress).clamp(0.0, 1.0).toDouble();

  void _seek(Offset pos, double width, {bool force = false}) {
    if (width <= 0) return;
    final factor = (pos.dx / width).clamp(0.0, 1.0).toDouble();
    setState(() => _dragProgress = factor);

    final now = DateTime.now();
    if (force || now.difference(_lastSeekAt).inMilliseconds >= 55) {
      _lastSeekAt = now;
      widget.onSeekFactor(factor);
    }
  }

  List<double> _bars(int count) {
    final source = widget.waveform.where((v) => v.isFinite).map((v) => v.clamp(0.04, 1.0).toDouble()).toList();
    if (source.isEmpty) {
      return List<double>.generate(count, (i) {
        final a = math.sin((i + 1 + widget.seed) * .73).abs();
        final b = math.sin((i + 3 + widget.seed) * .31).abs();
        final c = math.sin((i + widget.seed) * .17).abs();
        final mixed = (a * .55) + (b * .30) + (c * .15);
        return .22 + (mixed * .78);
      });
    }
    if (source.length == count) return source;
    return List<double>.generate(count, (i) {
      final mapped = (i / math.max(1, count - 1)) * (source.length - 1);
      final low = mapped.floor();
      final high = math.min(source.length - 1, low + 1);
      final t = mapped - low;
      return source[low] + ((source[high] - source[low]) * t);
    });
  }

  @override
  void didUpdateWidget(covariant _SmoothVoiceWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragProgress != null && (widget.progress - _dragProgress!).abs() < .03) {
      _dragProgress = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth <= 0 ? 160.0 : constraints.maxWidth;
        const barWidth = 3.0;
        const gap = 2.0;
        final count = math.max(26, (width / (barWidth + gap)).floor());
        final bars = _bars(count);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _seek(d.localPosition, width, force: true),
          onHorizontalDragStart: (d) => _seek(d.localPosition, width, force: true),
          onHorizontalDragUpdate: (d) => _seek(d.localPosition, width),
          onHorizontalDragEnd: (_) => setState(() => _dragProgress = null),
          onHorizontalDragCancel: () => setState(() => _dragProgress = null),
          child: RepaintBoundary(
            child: SizedBox(
              height: widget.height,
              width: double.infinity,
              child: CustomPaint(
                painter: _TrueWaveformPainter(
                  bars: bars,
                  progress: _visibleProgress,
                  accent: widget.accent,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrueWaveformPainter extends CustomPainter {
  final List<double> bars;
  final double progress;
  final Color accent;

  const _TrueWaveformPainter({required this.bars, required this.progress, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty || size.width <= 0 || size.height <= 0) return;
    final played = Paint()..color = accent..style = PaintingStyle.fill;
    final remain = Paint()..color = accent.withOpacity(.24)..style = PaintingStyle.fill;
    final count = bars.length;
    final gap = 2.0;
    final barWidth = math.max(2.0, (size.width - (gap * (count - 1))) / count);
    final radius = Radius.circular(barWidth);
    final centerY = size.height / 2;
    final playedX = size.width * progress.clamp(0.0, 1.0);

    for (var i = 0; i < count; i++) {
      final x = i * (barWidth + gap);
      final level = bars[i].clamp(0.06, 1.0).toDouble();
      final h = (size.height * level).clamp(5.0, size.height).toDouble();
      final rect = Rect.fromLTWH(x, centerY - h / 2, barWidth, h);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), x <= playedX ? played : remain);
    }
  }

  @override
  bool shouldRepaint(covariant _TrueWaveformPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.accent != accent || oldDelegate.bars != bars;
  }
}


enum MessageStatus { sent, delivered, read }

extension MessageStatusX on MessageStatus {
  static MessageStatus fromText(String? value) {
    final v = value?.toLowerCase().trim();
    if (v == 'read') return MessageStatus.read;
    if (v == 'delivered') return MessageStatus.delivered;
    return MessageStatus.sent;
  }
}

class _ChatThread {
  final String id;
  final String peerUsername;
  final String peerName;
  final String? peerAvatarPath;
  final String lastMessage;
  final String updatedAt;
  final bool isGroup;
  final String? groupId;

  const _ChatThread({
    required this.id,
    required this.peerUsername,
    required this.peerName,
    required this.peerAvatarPath,
    required this.lastMessage,
    required this.updatedAt,
    this.isGroup = false,
    this.groupId,
  });

  factory _ChatThread.fromGroup(Map<String, dynamic> json) => _ChatThread(
    id: (json['id'] ?? '').toString(),
    groupId: (json['id'] ?? '').toString(),
    peerUsername: '',
    peerName: (json['name'] ?? 'مجموعة').toString(),
    peerAvatarPath: json['avatar_url']?.toString(),
    lastMessage: (json['last_message'] ?? 'مجموعة جديدة').toString(),
    updatedAt: (json['updated_at'] ?? json['created_at'] ?? DateTime.now().toIso8601String()).toString(),
    isGroup: true,
  );
}


class _PendingChatMedia {
  final String path;
  final String type;

  const _PendingChatMedia({required this.path, required this.type});

  bool get isVideo => type == 'video';
}

class _ChatMediaItem {
  final String url;
  final String type;
  final int maxViews;

  const _ChatMediaItem({required this.url, required this.type, this.maxViews = 0});

  bool get isVideo => type == 'video';

  Map<String, dynamic> toJson() => {'url': url, 'type': type, if (maxViews > 0) 'max_views': maxViews};

  factory _ChatMediaItem.fromJson(Map<String, dynamic> json) {
    final type = (json['type'] ?? '').toString() == 'video' ? 'video' : 'image';
    final maxViews = int.tryParse((json['max_views'] ?? json['maxViews'] ?? 0).toString()) ?? 0;
    return _ChatMediaItem(url: (json['url'] ?? '').toString(), type: type, maxViews: maxViews.clamp(0, 2).toInt());
  }
}


class _DirectMessage {
  final String id;
  final String senderUsername;
  final String receiverUsername;
  final String? groupId;
  final String? senderName;
  final String? senderAvatar;
  final String text;
  final String createdAt;
  final MessageStatus status;
  final String? mediaType;
  final String? mediaUrl;
  final int voiceSeconds;
  final String? replyToId;
  final String? replyText;
  final String? replySender;

  const _DirectMessage({
    required this.id,
    required this.senderUsername,
    this.receiverUsername = '',
    this.groupId,
    this.senderName,
    this.senderAvatar,
    required this.text,
    required this.createdAt,
    this.status = MessageStatus.delivered,
    this.mediaType,
    this.mediaUrl,
    this.voiceSeconds = 0,
    this.replyToId,
    this.replyText,
    this.replySender,
  });

  bool get isVoice => mediaType == 'voice' && (mediaUrl?.trim().isNotEmpty ?? false);
  bool get isImage => mediaType == 'image' && (mediaUrl?.trim().isNotEmpty ?? false);
  bool get isVideo => mediaType == 'video' && (mediaUrl?.trim().isNotEmpty ?? false);
  bool get isMediaGroup => mediaItems.length > 1 || mediaType == 'gallery';
  bool get hasVisualMedia => mediaItems.isNotEmpty;
  int get limitedMediaMaxViews {
    var max = 0;
    for (final item in mediaItems) {
      if (item.maxViews > max) max = item.maxViews;
    }
    return max.clamp(0, 2).toInt();
  }

  List<_ChatMediaItem> get mediaItems {
    final raw = mediaUrl?.trim() ?? '';
    if (raw.isEmpty) return const <_ChatMediaItem>[];
    if (mediaType == 'gallery' || raw.startsWith('[')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map((e) => _ChatMediaItem.fromJson(Map<String, dynamic>.from(e)))
              .where((e) => e.url.trim().isNotEmpty)
              .toList();
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    if (mediaType == 'image' || mediaType == 'video') {
      return <_ChatMediaItem>[_ChatMediaItem(url: raw, type: mediaType == 'video' ? 'video' : 'image')];
    }
    return const <_ChatMediaItem>[];
  }

  _DirectMessage copyWith({String? id, MessageStatus? status, String? senderName, String? senderAvatar, String? text}) => _DirectMessage(
    id: id ?? this.id,
    senderUsername: senderUsername,
    receiverUsername: receiverUsername,
    groupId: groupId,
    senderName: senderName ?? this.senderName,
    senderAvatar: senderAvatar ?? this.senderAvatar,
    text: text ?? this.text,
    createdAt: createdAt,
    status: status ?? this.status,
    mediaType: mediaType,
    mediaUrl: mediaUrl,
    voiceSeconds: voiceSeconds,
    replyToId: replyToId,
    replyText: replyText,
    replySender: replySender,
  );

  factory _DirectMessage.fromSupabase(Map<String, dynamic> json) => _DirectMessage(
    id: (json['id'] ?? '').toString(),
    senderUsername: SupabaseService.displayUsername((json['sender_username'] ?? '').toString()),
    receiverUsername: SupabaseService.displayUsername((json['receiver_username'] ?? '').toString()),
    senderName: json['sender_name']?.toString(),
    senderAvatar: json['sender_avatar']?.toString(),
    text: (json['text'] ?? '').toString(),
    createdAt: (json['created_at'] ?? DateTime.now().toIso8601String()).toString(),
    mediaType: json['media_type']?.toString(),
    mediaUrl: json['media_url']?.toString(),
    voiceSeconds: int.tryParse((json['voice_seconds'] ?? 0).toString()) ?? 0,
    replyToId: json['reply_to_id']?.toString(),
    replyText: json['reply_text']?.toString(),
    replySender: json['reply_sender']?.toString(),
    status: json['read_at'] != null || json['is_read'] == true || json['status']?.toString() == 'read'
        ? MessageStatus.read
        : (json['delivered_at'] != null || json['status']?.toString() == 'delivered'
        ? MessageStatus.delivered
        : MessageStatus.sent),
  );

  factory _DirectMessage.fromGroupSupabase(Map<String, dynamic> json) => _DirectMessage(
    id: (json['id'] ?? '').toString(),
    groupId: (json['group_id'] ?? '').toString(),
    senderUsername: SupabaseService.displayUsername((json['sender_username'] ?? '').toString()),
    senderName: (json['sender_name'] ?? json['name'])?.toString(),
    senderAvatar: (json['sender_avatar'] ?? json['avatar_url'])?.toString(),
    text: (json['text'] ?? '').toString(),
    createdAt: (json['created_at'] ?? DateTime.now().toIso8601String()).toString(),
    mediaType: json['media_type']?.toString(),
    mediaUrl: json['media_url']?.toString(),
    voiceSeconds: int.tryParse((json['voice_seconds'] ?? 0).toString()) ?? 0,
    replyToId: json['reply_to_id']?.toString(),
    replyText: json['reply_text']?.toString(),
    replySender: json['reply_sender']?.toString(),
    status: MessageStatusX.fromText(json['status']?.toString() ?? 'delivered'),
  );
}

class _AttachmentActionButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Color? color;

  const _AttachmentActionButton({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = color ?? AppColors.purple;
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white.withOpacity(0.62) : AppColors.lightMuted;
    final tileColor = isDark ? Colors.white.withOpacity(0.07) : AppColors.lightCard2;
    final borderColor = isDark ? Colors.white.withOpacity(0.08) : AppColors.lightBorder;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        decoration: BoxDecoration(
          color: tileColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accent.withOpacity(isDark ? 0.18 : 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: accent, size: 24),
            ),
            const SizedBox(height: 9),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: titleColor,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
            if ((subtitle ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: subtitleColor,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LockedVoiceRecorderBar extends StatelessWidget {
  final Duration duration;
  final DateTime? startedAt;
  final bool paused;
  final bool locked;
  final List<double>? waveform;
  final VoidCallback? onStop;
  final VoidCallback? onCancel;
  final VoidCallback? onPauseResume;
  final VoidCallback? onPreview;
  final VoidCallback? onSend;
  final Duration? pausedElapsed;

  const _LockedVoiceRecorderBar({
    required this.duration,
    this.startedAt,
    this.paused = false,
    this.locked = false,
    this.waveform,
    this.onStop,
    this.onCancel,
    this.onPauseResume,
    this.onPreview,
    this.onSend,
    this.pausedElapsed,
  });

  String get _time {
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final wave = waveform;
    final bars = (wave == null || wave.isEmpty)
        ? List<double>.filled(22, 0.35)
        : wave.take(28).toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF17121F),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.fiber_manual_record_rounded, color: paused ? Colors.orangeAccent : Colors.redAccent, size: 18),
          const SizedBox(width: 8),
          Text(
            _time,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 28,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: bars.map((v) {
                  final h = 6 + (v.clamp(0.05, 1.0) * 20);
                  return Container(
                    width: 3,
                    height: h,
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(paused ? 0.35 : 0.8),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          IconButton(
            tooltip: paused ? 'متابعة' : 'إيقاف مؤقت',
            onPressed: onPauseResume,
            icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, color: Colors.white),
          ),
          IconButton(
            tooltip: 'إلغاء',
            onPressed: onCancel,
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
          ),
          if (onPreview != null)
            IconButton(
              tooltip: 'معاينة',
              onPressed: onPreview,
              icon: const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF38BDF8)),
            ),
          IconButton(
            tooltip: 'إرسال',
            onPressed: onSend ?? onStop,
            icon: const Icon(Icons.send_rounded, color: Color(0xFF22C55E)),
          ),
        ],
      ),
    );
  }
}

class _PendingVoicePreviewBar extends StatelessWidget {
  final String path;
  final int seconds;
  final bool isPlaying;
  final double speed;
  final Duration? position;
  final Duration? duration;
  final List<double>? waveform;
  final VoidCallback? onPlayPause;
  final VoidCallback? onPlay;
  final ValueChanged<Duration>? onSeek;
  final VoidCallback? onSpeedTap;
  final VoidCallback? onSend;
  final VoidCallback? onDelete;
  final VoidCallback? onCancel;

  const _PendingVoicePreviewBar({
    required this.path,
    required this.seconds,
    this.isPlaying = false,
    this.speed = 1.0,
    this.position,
    this.duration,
    this.waveform,
    this.onPlayPause,
    this.onPlay,
    this.onSeek,
    this.onSpeedTap,
    this.onSend,
    this.onDelete,
    this.onCancel,
  });

  String _fmt(int totalSeconds) {
    final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final shownSeconds = duration?.inSeconds ?? seconds;
    final wave = waveform;
    final bars = (wave == null || wave.isEmpty)
        ? List<double>.filled(24, 0.38)
        : wave.take(30).toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF17121F),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onPlayPause ?? onPlay,
            icon: Icon(
              isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 30,
              child: Row(
                children: bars.map((v) {
                  final h = 7 + (v.clamp(0.05, 1.0) * 19);
                  return Expanded(
                    child: Center(
                      child: Container(
                        width: 3,
                        height: h,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.75),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onSpeedTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${speed.toStringAsFixed(speed % 1 == 0 ? 0 : 2)}x',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 11),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _fmt(shownSeconds),
            style: TextStyle(color: Colors.white.withOpacity(0.75), fontWeight: FontWeight.w700),
          ),
          IconButton(
            onPressed: onDelete ?? onCancel,
            icon: const Icon(Icons.close_rounded, color: Colors.redAccent),
          ),
          IconButton(
            onPressed: onSend,
            icon: const Icon(Icons.send_rounded, color: Color(0xFF22C55E)),
          ),
        ],
      ),
    );
  }
}


class _LimitedMediaBadge extends StatelessWidget {
  final int maxViews;
  const _LimitedMediaBadge({required this.maxViews});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.58),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(.18)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.visibility_rounded, color: Colors.white, size: 14),
        const SizedBox(width: 4),
        Text(maxViews == 1 ? 'مرة' : 'مرتين', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 10)),
      ]),
    );
  }
}

class _ChatImageMessage extends StatelessWidget {
  final String url;
  final String? caption;
  final bool isMe;
  final VoidCallback? onTap;
  final int limitedMaxViews;

  const _ChatImageMessage({
    required this.url,
    this.caption,
    required this.isMe,
    this.onTap,
    this.limitedMaxViews = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              children: [
                Image.network(
                  url,
                  width: 230,
                  height: 260,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 230,
                    height: 180,
                    color: Colors.black26,
                    child: const Center(child: Icon(Icons.broken_image_rounded, color: Colors.white70)),
                  ),
                ),
                if (limitedMaxViews > 0)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _LimitedMediaBadge(maxViews: limitedMaxViews),
                  ),
              ],
            ),
          ),
        ),
        if ((caption ?? '').trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              caption!,
              style: const TextStyle(color: Colors.white),
            ),
          ),
      ],
    );
  }
}

class _ChatVideoMessage extends StatelessWidget {
  final String url;
  final String? caption;
  final bool isMe;
  final VoidCallback? onTap;
  final int limitedMaxViews;

  const _ChatVideoMessage({
    required this.url,
    this.caption,
    required this.isMe,
    this.onTap,
    this.limitedMaxViews = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 230,
            height: 230,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(Icons.videocam_rounded, color: Colors.white.withOpacity(0.28), size: 72),
                const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 62),
                if (limitedMaxViews > 0)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _LimitedMediaBadge(maxViews: limitedMaxViews),
                  ),
              ],
            ),
          ),
        ),
        if ((caption ?? '').trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              caption!,
              style: const TextStyle(color: Colors.white),
            ),
          ),
      ],
    );
  }
}

class _ChatMediaGalleryMessage extends StatelessWidget {
  final List<dynamic> items;
  final List<String>? mediaUrls;
  final bool isMe;
  final String? caption;
  final int limitedMaxViews;
  final void Function(int index)? onOpen;

  const _ChatMediaGalleryMessage({
    this.items = const [],
    this.mediaUrls,
    required this.isMe,
    this.caption,
    this.limitedMaxViews = 0,
    this.onOpen,
  });

  _ChatMediaItem _mediaItemOf(dynamic item) {
    if (item is _ChatMediaItem) return item;
    if (item is Map) {
      final map = Map<String, dynamic>.from(item);
      final url = (map['url'] ?? map['media_url'] ?? map['path'] ?? '').toString();
      final rawType = (map['type'] ?? map['media_type'] ?? '').toString().toLowerCase();
      final type = rawType.contains('video') || _looksVideo(url) ? 'video' : 'image';
      return _ChatMediaItem(url: url, type: type);
    }
    final url = item.toString();
    return _ChatMediaItem(url: url, type: _looksVideo(url) ? 'video' : 'image');
  }

  bool _looksVideo(String url) {
    final s = url.split('?').first.toLowerCase();
    return s.endsWith('.mp4') || s.endsWith('.mov') || s.endsWith('.webm') || s.endsWith('.m4v') || s.endsWith('.mkv') || s.endsWith('.avi');
  }

  Widget _tile(_ChatMediaItem item, int index, {int hidden = 0, BorderRadius? radius}) {
    return GestureDetector(
      onTap: () => onOpen?.call(index),
      child: ClipRRect(
        borderRadius: radius ?? BorderRadius.circular(13),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.isVideo)
              Container(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Icon(Icons.videocam_rounded, color: Colors.white.withOpacity(0.18), size: 54),
                    const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 44)),
                  ],
                ),
              )
            else
              Image.network(
                item.url,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return Container(
                    color: Colors.black12,
                    child: const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
                  );
                },
                errorBuilder: (_, __, ___) => Container(
                  color: Colors.black26,
                  child: const Center(child: Icon(Icons.broken_image_rounded, color: Colors.white70, size: 30)),
                ),
              ),
            if (limitedMaxViews > 0 && hidden <= 0)
              const Positioned(
                top: 7,
                left: 7,
                child: Icon(Icons.visibility_rounded, color: Colors.white, size: 18),
              ),
            if (hidden > 0)
              Container(
                color: Colors.black.withOpacity(0.60),
                child: Center(
                  child: Text(
                    '+$hidden',
                    style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _mediaLayout(List<_ChatMediaItem> media) {
    const gap = 5.0;
    final count = media.length;

    if (count == 1) {
      return SizedBox(width: 218, height: 158, child: _tile(media[0], 0));
    }

    if (count == 2) {
      return SizedBox(
        width: 218,
        height: 154,
        child: Row(children: [
          Expanded(child: _tile(media[0], 0)),
          const SizedBox(width: gap),
          Expanded(child: _tile(media[1], 1)),
        ]),
      );
    }

    if (count == 3) {
      return SizedBox(
        width: 218,
        height: 168,
        child: Row(children: [
          Expanded(child: _tile(media[0], 0)),
          const SizedBox(width: gap),
          Expanded(
            child: Column(children: [
              Expanded(child: _tile(media[1], 1)),
              const SizedBox(height: gap),
              Expanded(child: _tile(media[2], 2)),
            ]),
          ),
        ]),
      );
    }

    final hidden = count - 4;
    return SizedBox(
      width: 218,
      height: 178,
      child: Column(children: [
        Expanded(
          child: Row(children: [
            Expanded(child: _tile(media[0], 0)),
            const SizedBox(width: gap),
            Expanded(child: _tile(media[1], 1)),
          ]),
        ),
        const SizedBox(height: gap),
        Expanded(
          child: Row(children: [
            Expanded(child: _tile(media[2], 2)),
            const SizedBox(width: gap),
            Expanded(child: _tile(media[3], 3, hidden: hidden)),
          ]),
        ),
      ]),
    );
  }

  bool _isDefaultCaption(String text, int count) {
    final t = text.trim();
    return t == 'صورة' || t == 'فيديو' || t == '$count ملفات';
  }

  @override
  Widget build(BuildContext context) {
    final urls = mediaUrls;
    final rawItems = urls != null ? urls.map((e) => _ChatMediaItem(url: e, type: _looksVideo(e) ? 'video' : 'image')).toList() : items;
    final media = rawItems
        .map(_mediaItemOf)
        .where((e) => e.url.trim().isNotEmpty && !e.url.startsWith('Instance of'))
        .toList();

    if (media.isEmpty) {
      return const Text('تعذر عرض الملف', style: TextStyle(color: Colors.white70));
    }

    final cleanCaption = (caption ?? '').trim();
    final showCaption = cleanCaption.isNotEmpty && !_isDefaultCaption(cleanCaption, media.length);

    return Column(
      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _mediaLayout(media),
        if (showCaption) ...[
          const SizedBox(height: 7),
          Container(
            width: 218,
            height: 1,
            color: Colors.white.withOpacity(isMe ? .22 : .10),
          ),
          const SizedBox(height: 7),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 218),
            child: Text(
              cleanCaption,
              style: TextStyle(color: isMe ? Colors.white : null, height: 1.35),
            ),
          ),
        ],
      ],
    );
  }
}


class _CapturedChatMedia {
  final String path;
  final bool isVideo;

  const _CapturedChatMedia({
    required this.path,
    required this.isVideo,
  });
}

class _InAppChatCameraPage extends StatefulWidget {
  final bool initialVideoMode;

  const _InAppChatCameraPage({required this.initialVideoMode});

  @override
  State<_InAppChatCameraPage> createState() => _InAppChatCameraPageState();
}

class _InAppChatCameraPageState extends State<_InAppChatCameraPage> with WidgetsBindingObserver {
  List<CameraDescription> _cameras = <CameraDescription>[];
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _loading = true;
  bool _videoMode = false;
  bool _recording = false;
  bool _flashOn = false;
  DateTime? _recordStartedAt;
  DateTime? _recordPausedAt;
  Timer? _recordTimer;
  Duration _recordElapsed = Duration.zero;
  Duration _recordPausedAccum = Duration.zero;
  bool _recordPaused = false;
  bool _recordBusy = false;
  String? _error;

  ResolutionPreset _resolutionPreset = ResolutionPreset.high;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minExposure = 0.0;
  double _maxExposure = 0.0;
  double _currentExposure = 0.0;
  Offset? _focusPoint;
  bool _showExposureControl = false;
  Timer? _focusTimer;
  Timer? _exposureTimer;
  Timer? _zoomApplyTimer;
  Timer? _exposureApplyTimer;
  bool _pinchInProgress = false;
  double _pendingZoom = 1.0;
  double _pendingExposure = 0.0;

  static const Color _cameraPurple = Color(0xFF7C3AED);
  static const Color _cameraPurpleDark = Color(0xFF5B21B6);

  static const List<ResolutionPreset> _resolutionPresets = <ResolutionPreset>[
    ResolutionPreset.max,
    ResolutionPreset.ultraHigh,
    ResolutionPreset.veryHigh,
    ResolutionPreset.high,
    ResolutionPreset.medium,
    ResolutionPreset.low,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lockCameraPortrait();
    _videoMode = widget.initialVideoMode;
    _initializeCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _recordTimer?.cancel();
      _recording = false;
      _recordPaused = false;
      _recordPausedAt = null;
      _recordPausedAccum = Duration.zero;
      controller.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera(keepIndex: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _focusTimer?.cancel();
    _exposureTimer?.cancel();
    _zoomApplyTimer?.cancel();
    _exposureApplyTimer?.cancel();
    _controller?.dispose();
    _restoreAppPortrait();
    super.dispose();
  }

  Future<void> _lockCameraPortrait() async {
    try {
      // نثبت صفحة الكاميرا على PortraitUp فقط بدون تدوير داخلي للمعاينة.
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _restoreAppPortrait() async {
    try {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _initializeCamera({bool keepIndex = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final cameraPermission = await Permission.camera.request();
      final micPermission = _videoMode ? await Permission.microphone.request() : PermissionStatus.granted;
      if (!cameraPermission.isGranted || (_videoMode && !micPermission.isGranted)) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = _videoMode ? 'اسمح للكاميرا والمايك لتصوير الفيديو' : 'اسمح للكاميرا لتصوير الصورة';
        });
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'لا توجد كاميرا متاحة على هذا الجهاز';
        });
        return;
      }

      _cameras = cameras;
      if (!keepIndex) {
        final backIndex = cameras.indexWhere((camera) => camera.lensDirection == CameraLensDirection.back);
        _cameraIndex = backIndex >= 0 ? backIndex : 0;
      }
      if (_cameraIndex >= cameras.length) _cameraIndex = 0;

      await _controller?.dispose();
      final controller = CameraController(
        cameras[_cameraIndex],
        _resolutionPreset,
        enableAudio: _videoMode,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      _controller = controller;
      await controller.initialize();
      try { await _lockCameraPortrait(); } catch (e, st) { _logIgnoredError(e, st); }
      try {
        _minZoom = await controller.getMinZoomLevel();
        _maxZoom = await controller.getMaxZoomLevel();
        _currentZoom = _currentZoom.clamp(_minZoom, _maxZoom).toDouble();
        _pendingZoom = _currentZoom;
        await controller.setZoomLevel(_currentZoom);
      } catch (_) {
        _minZoom = 1.0;
        _maxZoom = 1.0;
        _currentZoom = 1.0;
      }
      try {
        _minExposure = await controller.getMinExposureOffset();
        _maxExposure = await controller.getMaxExposureOffset();
        _currentExposure = _currentExposure.clamp(_minExposure, _maxExposure).toDouble();
        _pendingExposure = _currentExposure;
        await controller.setExposureOffset(_currentExposure);
      } catch (_) {
        _minExposure = 0.0;
        _maxExposure = 0.0;
        _currentExposure = 0.0;
      }
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (e, st) { _logIgnoredError(e, st); }
      try {
        await controller.setExposureMode(ExposureMode.auto);
      } catch (e, st) { _logIgnoredError(e, st); }
      try {
        await controller.setFlashMode(_flashOn ? FlashMode.torch : FlashMode.off);
      } catch (e, st) { _logIgnoredError(e, st); }

      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'تعذر تشغيل الكاميرا: $e';
      });
    }
  }

  Future<void> _toggleCamera() async {
    if (_cameras.length < 2 || _recording || _recordBusy) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initializeCamera(keepIndex: true);
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      _flashOn = !_flashOn;
      await controller.setFlashMode(_flashOn ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() {});
    } catch (_) {
      _flashOn = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _toggleMode() async {
    if (_recording || _recordBusy) return;
    setState(() => _videoMode = !_videoMode);
    await _initializeCamera(keepIndex: true);
  }

  String _resolutionTitle(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.max:
        return 'أعلى جودة';
      case ResolutionPreset.ultraHigh:
        return '4K / Ultra';
      case ResolutionPreset.veryHigh:
        return '1080p';
      case ResolutionPreset.high:
        return '720p';
      case ResolutionPreset.medium:
        return '480p';
      case ResolutionPreset.low:
        return 'منخفض';
    }
  }

  String _resolutionSubtitle(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.max:
        return 'حسب الجهاز';
      case ResolutionPreset.ultraHigh:
        return 'أفضل دعم';
      case ResolutionPreset.veryHigh:
        return 'FPS تلقائي';
      case ResolutionPreset.high:
        return 'أخف وأسرع';
      case ResolutionPreset.medium:
        return 'توفير حجم';
      case ResolutionPreset.low:
        return 'سريع جدًا';
    }
  }

  Future<void> _setResolutionPreset(ResolutionPreset preset) async {
    if (_recording || _recordBusy || preset == _resolutionPreset) return;
    setState(() => _resolutionPreset = preset);
    await _initializeCamera(keepIndex: true);
  }

  void _setZoom(double value) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final next = value.clamp(_minZoom, _maxZoom).toDouble();
    _pendingZoom = next;
    if (mounted) setState(() => _currentZoom = next);

    // لا نرسل أمر الزوم للكاميرا مع كل pixel حتى لا يصير التطبيق ثقيل.
    _zoomApplyTimer?.cancel();
    _zoomApplyTimer = Timer(const Duration(milliseconds: 28), () async {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      try {
        await c.setZoomLevel(_pendingZoom);
      } catch (e, st) { _logIgnoredError(e, st); }
    });
  }

  void _setExposure(double value) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final next = value.clamp(_minExposure, _maxExposure).toDouble();
    _pendingExposure = next;
    if (mounted) setState(() => _currentExposure = next);

    // تأخير بسيط يخلّي السلايدر سلس بدل تنفيذ setExposureOffset على كل حركة.
    _exposureApplyTimer?.cancel();
    _exposureApplyTimer = Timer(const Duration(milliseconds: 34), () async {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      try {
        await c.setExposureOffset(_pendingExposure);
      } catch (e, st) { _logIgnoredError(e, st); }
    });
  }

  Future<void> _handlePreviewTap(Offset localPosition, Size size) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || size.width <= 0 || size.height <= 0) return;
    final normalized = Offset(
      (localPosition.dx / size.width).clamp(0.0, 1.0),
      (localPosition.dy / size.height).clamp(0.0, 1.0),
    );

    _focusTimer?.cancel();
    _exposureTimer?.cancel();
    if (mounted) {
      setState(() {
        _focusPoint = localPosition;
        _showExposureControl = true;
      });
    }

    try { await controller.setFocusPoint(normalized); } catch (e, st) { _logIgnoredError(e, st); }
    try { await controller.setExposurePoint(normalized); } catch (e, st) { _logIgnoredError(e, st); }

    _focusTimer = Timer(const Duration(milliseconds: 850), () {
      if (mounted) setState(() => _focusPoint = null);
    });
    _exposureTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showExposureControl = false);
    });
  }

  void _keepExposureVisible() {
    _exposureTimer?.cancel();
    _exposureTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showExposureControl = false);
    });
  }

  void _startRecordTicker() {
    _recordTimer?.cancel();
    _recordStartedAt = DateTime.now();
    _recordPausedAt = null;
    _recordPausedAccum = Duration.zero;
    _recordElapsed = Duration.zero;
    _recordPaused = false;
    _recordTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final started = _recordStartedAt;
      if (started == null || !mounted) return;
      final now = _recordPaused && _recordPausedAt != null ? _recordPausedAt! : DateTime.now();
      final elapsed = now.difference(started) - _recordPausedAccum;
      setState(() => _recordElapsed = elapsed.isNegative ? Duration.zero : elapsed);
    });
  }

  String _formatElapsed(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _capturePhoto() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _recording) return;
    try {
      final file = await controller.takePicture();
      if (!mounted) return;
      Navigator.pop(context, _CapturedChatMedia(path: file.path, isVideo: false));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر التقاط الصورة: $e')));
    }
  }

  Future<void> _toggleVideoRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _recordBusy) return;

    Future<T> guarded<T>(Future<T> future, Duration timeout, String message) {
      return future.timeout(timeout, onTimeout: () => throw TimeoutException(message));
    }

    if (mounted) setState(() => _recordBusy = true);

    try {
      if (_recording) {
        // إذا كان الفيديو موقوف مؤقتًا نرجعه أولًا ثم نحفظه.
        // بعض أجهزة Android تعلق إذا تم استدعاء stopVideoRecording وهي paused.
        if (_recordPaused) {
          try {
            await guarded(
              controller.resumeVideoRecording(),
              const Duration(seconds: 2),
              'تأخر استكمال التسجيل قبل الحفظ',
            );
            await Future<void>.delayed(const Duration(milliseconds: 180));
          } catch (e, st) { _logIgnoredError(e, st); }
        }

        final file = await guarded(
          controller.stopVideoRecording(),
          const Duration(seconds: 8),
          'تأخر حفظ الفيديو',
        );

        _recordTimer?.cancel();
        await _lockCameraPortrait();

        if (!mounted) return;
        setState(() {
          _recording = false;
          _recordPaused = false;
          _recordBusy = false;
          _recordPausedAt = null;
          _recordPausedAccum = Duration.zero;
          _recordStartedAt = null;
          _recordElapsed = Duration.zero;
        });
        Navigator.pop(context, _CapturedChatMedia(path: file.path, isVideo: true));
        return;
      }

      await _lockCameraPortrait();
      try { await controller.setFocusMode(FocusMode.auto); } catch (e, st) { _logIgnoredError(e, st); }
      try { await controller.setExposureMode(ExposureMode.auto); } catch (e, st) { _logIgnoredError(e, st); }

      await guarded(
        controller.prepareForVideoRecording(),
        const Duration(seconds: 4),
        'تأخر تجهيز الفيديو',
      );
      await guarded(
        controller.startVideoRecording(),
        const Duration(seconds: 5),
        'تأخر بدء التسجيل',
      );

      _startRecordTicker();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _recordPaused = false;
        _recordBusy = false;
      });
      await _lockCameraPortrait();
    } catch (e) {
      _recordTimer?.cancel();
      await _lockCameraPortrait();
      if (!mounted) return;
      setState(() {
        _recording = false;
        _recordPaused = false;
        _recordBusy = false;
        _recordPausedAt = null;
        _recordPausedAccum = Duration.zero;
        _recordStartedAt = null;
        _recordElapsed = Duration.zero;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تصوير الفيديو: $e')));
    }
  }

  Future<void> _cancelVideoRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || !_recording || _recordBusy) {
      if (!_recording && mounted) Navigator.pop(context);
      return;
    }

    Future<T> guarded<T>(Future<T> future, Duration timeout, String message) {
      return future.timeout(timeout, onTimeout: () => throw TimeoutException(message));
    }

    if (mounted) setState(() => _recordBusy = true);

    try {
      if (_recordPaused) {
        try {
          await guarded(
            controller.resumeVideoRecording(),
            const Duration(seconds: 2),
            'تأخر استكمال التسجيل قبل الإلغاء',
          );
          await Future<void>.delayed(const Duration(milliseconds: 120));
        } catch (e, st) { _logIgnoredError(e, st); }
      }

      XFile? file;
      try {
        file = await guarded(
          controller.stopVideoRecording(),
          const Duration(seconds: 6),
          'تأخر إلغاء التسجيل',
        );
      } catch (e, st) { _logIgnoredError(e, st); }

      _recordTimer?.cancel();
      await _lockCameraPortrait();

      if (file != null && file.path.trim().isNotEmpty) {
        try { await File(file.path).delete(); } catch (e, st) { _logIgnoredError(e, st); }
      }

      if (!mounted) return;
      setState(() {
        _recording = false;
        _recordPaused = false;
        _recordBusy = false;
        _recordPausedAt = null;
        _recordPausedAccum = Duration.zero;
        _recordStartedAt = null;
        _recordElapsed = Duration.zero;
      });
    } catch (e) {
      _recordTimer?.cancel();
      await _lockCameraPortrait();
      if (!mounted) return;
      setState(() {
        _recording = false;
        _recordPaused = false;
        _recordBusy = false;
        _recordPausedAt = null;
        _recordPausedAccum = Duration.zero;
        _recordStartedAt = null;
        _recordElapsed = Duration.zero;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم إلغاء التسجيل')));
    }
  }

  Future<void> _toggleVideoPause() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || !_recording || !_videoMode || _recordBusy) return;

    Future<T> guarded<T>(Future<T> future, Duration timeout, String message) {
      return future.timeout(timeout, onTimeout: () => throw TimeoutException(message));
    }

    if (mounted) setState(() => _recordBusy = true);

    try {
      if (_recordPaused) {
        final pausedAt = _recordPausedAt;
        await guarded(
          controller.resumeVideoRecording(),
          const Duration(seconds: 3),
          'تأخر استكمال التسجيل',
        );
        if (pausedAt != null) {
          _recordPausedAccum += DateTime.now().difference(pausedAt);
        }
        if (!mounted) return;
        setState(() {
          _recordPaused = false;
          _recordPausedAt = null;
          _recordBusy = false;
        });
      } else {
        await guarded(
          controller.pauseVideoRecording(),
          const Duration(seconds: 3),
          'تأخر إيقاف التسجيل مؤقتًا',
        );
        if (!mounted) return;
        setState(() {
          _recordPaused = true;
          _recordPausedAt = DateTime.now();
          _recordBusy = false;
        });
      }
      await _lockCameraPortrait();
    } catch (e) {
      if (!mounted) return;
      setState(() => _recordBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر إيقاف/استكمال التسجيل مؤقتًا: $e')));
    }
  }

  Widget _buildRawCameraPreview(CameraController controller) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) {
      return Positioned.fill(child: CameraPreview(controller));
    }

    // مهم: لا نلف CameraPreview أبدًا أثناء التسجيل.
    // المشكلة كانت أن المعاينة كانت تنقلب/تصير عكسية بسبب RotatedBox أو lockCaptureOrientation.
    // هنا نثبت عرض المعاينة بشكل عمودي فقط باستخدام أبعاد portrait، بدون أي تدوير.
    final rawW = previewSize.width;
    final rawH = previewSize.height;
    final previewWidth = math.min(rawW, rawH);
    final previewHeight = math.max(rawW, rawH);

    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.center,
          child: SizedBox(
            width: previewWidth,
            height: previewHeight,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  Widget _buildInteractiveCameraPreview(CameraController controller) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // الفوكس صار مع tap حقيقي فقط، وليس مع أي لمسة أو بداية زوم/سحب.
          onTapUp: (details) {
            if (_pinchInProgress) return;
            _handlePreviewTap(details.localPosition, size);
          },
          onScaleStart: (details) {
            _baseZoom = _currentZoom;
            _pinchInProgress = details.pointerCount > 1;
          },
          onScaleUpdate: (details) {
            if (details.pointerCount < 2 || _maxZoom <= _minZoom) return;
            _pinchInProgress = true;
            _setZoom(_baseZoom * details.scale);
          },
          onScaleEnd: (_) {
            Future.delayed(const Duration(milliseconds: 90), () {
              if (mounted) _pinchInProgress = false;
            });
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildRawCameraPreview(controller),
              if (_focusPoint != null)
                Builder(
                  builder: (_) {
                    final focusPoint = _focusPoint;
                    if (focusPoint == null) return const SizedBox.shrink();
                    return Positioned(
                      left: (focusPoint.dx - 34).clamp(10.0, math.max(10.0, size.width - 78)),
                      top: (focusPoint.dy - 34).clamp(10.0, math.max(10.0, size.height - 78)),
                      child: IgnorePointer(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: _cameraPurple, width: 2.4),
                            boxShadow: [BoxShadow(color: _cameraPurple.withOpacity(.45), blurRadius: 12)],
                          ),
                          child: Center(
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(color: _cameraPurple, shape: BoxShape.circle),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              if (_showExposureControl && _maxExposure > _minExposure)
                Positioned(
                  right: 14,
                  top: math.max(96.0, size.height * .22),
                  child: _CameraExposureSlider(
                    value: _currentExposure,
                    min: _minExposure,
                    max: _maxExposure,
                    onChanged: (value) {
                      _keepExposureVisible();
                      _setExposure(value);
                    },
                  ),
                ),
              if (_maxZoom > _minZoom && _currentZoom > _minZoom + .05)
                Positioned(
                  top: 126,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(color: Colors.black.withOpacity(.48), borderRadius: BorderRadius.circular(99), border: Border.all(color: _cameraPurple.withOpacity(.35))),
                        child: Text('${_currentZoom.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : _error != null
                  ? _CameraErrorView(message: _error!, onRetry: () => _initializeCamera(keepIndex: true))
                  : ready
                  ? _buildInteractiveCameraPreview(controller)
                  : const Center(child: Text('الكاميرا غير جاهزة', style: TextStyle(color: Colors.white))),
            ),
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  _CameraTopButton(icon: Icons.close_rounded, onTap: _recording ? _cancelVideoRecording : () => Navigator.pop(context)),
                  const Spacer(),
                  if (_recording)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: (_recordPaused ? _cameraPurpleDark : Colors.red).withOpacity(.88),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_recordPaused ? Icons.pause_rounded : Icons.fiber_manual_record_rounded, color: Colors.white, size: 14),
                          const SizedBox(width: 6),
                          Text(_recordPaused ? 'متوقف ${_formatElapsed(_recordElapsed)}' : _formatElapsed(_recordElapsed), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                        ],
                      ),
                    ),
                  const Spacer(),
                  _CameraTopButton(icon: _flashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded, onTap: _toggleFlash),
                ],
              ),
            ),
            Positioned(
              top: 64,
              left: 8,
              right: 8,
              child: IgnorePointer(
                ignoring: _recording,
                child: Opacity(
                  opacity: _recording ? .35 : 1,
                  child: SizedBox(
                    height: 42,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      itemCount: _resolutionPresets.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final preset = _resolutionPresets[index];
                        return _CameraResolutionChip(
                          title: _resolutionTitle(preset),
                          subtitle: _resolutionSubtitle(preset),
                          active: preset == _resolutionPreset,
                          onTap: () => _setResolutionPreset(preset),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 18,
              right: 18,
              bottom: 22,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: Colors.black.withOpacity(.48), borderRadius: BorderRadius.circular(99)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _CameraModePill(title: 'صورة', active: !_videoMode, onTap: _toggleMode),
                        _CameraModePill(title: 'فيديو', active: _videoMode, onTap: _toggleMode),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _CameraRoundButton(
                        icon: _recording ? Icons.close_rounded : Icons.cameraswitch_rounded,
                        onTap: _recording ? _cancelVideoRecording : _toggleCamera,
                        enabled: _recording ? !_recordBusy : (_cameras.length > 1 && !_recordBusy),
                      ),
                      GestureDetector(
                        onTap: _recordBusy ? null : (_videoMode ? _toggleVideoRecording : _capturePhoto),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 82,
                          height: 82,
                          padding: EdgeInsets.all(_recording ? 20 : 6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                            color: Colors.white.withOpacity(_recording ? .2 : .05),
                          ),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            decoration: BoxDecoration(
                              color: _videoMode ? Colors.redAccent : _cameraPurple,
                              shape: _recording ? BoxShape.rectangle : BoxShape.circle,
                              borderRadius: _recording ? BorderRadius.circular(10) : null,
                            ),
                          ),
                        ),
                      ),
                      _CameraRoundButton(
                        icon: _recording
                            ? (_recordPaused ? Icons.play_arrow_rounded : Icons.pause_rounded)
                            : (_videoMode ? Icons.videocam_rounded : Icons.photo_camera_rounded),
                        onTap: _toggleVideoPause,
                        enabled: _recording && _videoMode && !_recordBusy,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _videoMode
                        ? (_recording
                        ? (_recordBusy ? 'جاري تنفيذ العملية...' : (_recordPaused ? 'متوقف مؤقتًا - تشغيل للإكمال، الأحمر للحفظ، والإكس للإلغاء' : 'تقدر تعمل فوكس أثناء التصوير، البنفسجي إيقاف مؤقت، والإكس إلغاء'))
                        : 'اضغط لتصوير فيديو')
                        : 'اضغط لالتقاط صورة',
                    style: TextStyle(
                      color: Colors.white.withOpacity(.9),
                      fontWeight: FontWeight.w800,
                      shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraExposureSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _CameraExposureSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 220,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.48),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: _InAppChatCameraPageState._cameraPurple.withOpacity(.55)),
      ),
      child: Column(
        children: [
          const Icon(Icons.wb_sunny_rounded, color: _InAppChatCameraPageState._cameraPurple, size: 20),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor: _InAppChatCameraPageState._cameraPurple,
                  inactiveTrackColor: Colors.white30,
                  thumbColor: _InAppChatCameraPageState._cameraPurple,
                  overlayColor: _InAppChatCameraPageState._cameraPurple.withOpacity(.24),
                ),
                child: Slider(
                  value: value.clamp(min, max).toDouble(),
                  min: min,
                  max: max,
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
          Text(value.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _CameraResolutionChip extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool active;
  final VoidCallback onTap;

  const _CameraResolutionChip({
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: active ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? _InAppChatCameraPageState._cameraPurple : Colors.black.withOpacity(.42),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: active ? _InAppChatCameraPageState._cameraPurple : _InAppChatCameraPageState._cameraPurple.withOpacity(.55)),
          boxShadow: active ? [BoxShadow(color: _InAppChatCameraPageState._cameraPurple.withOpacity(.35), blurRadius: 10)] : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900)),
            if (active) ...[
              const SizedBox(width: 5),
              const Icon(Icons.check_circle_rounded, color: Colors.white, size: 14),
            ],
          ],
        ),
      ),
    );
  }
}

class _CameraErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _CameraErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_rounded, color: Colors.white, size: 48),
            const SizedBox(height: 14),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.purple, foregroundColor: Colors.white),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraTopButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _CameraTopButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _InAppChatCameraPageState._cameraPurple.withOpacity(.82),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 44, height: 44, child: Icon(icon, color: Colors.white)),
      ),
    );
  }
}

class _CameraRoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

  const _CameraRoundButton({required this.icon, required this.onTap, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : .38,
      child: Material(
        color: enabled ? _InAppChatCameraPageState._cameraPurple.withOpacity(.82) : Colors.black.withOpacity(.45),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(width: 56, height: 56, child: Icon(icon, color: Colors.white, size: 28)),
        ),
      ),
    );
  }
}

class _CameraModePill extends StatelessWidget {
  final String title;
  final bool active;
  final VoidCallback onTap;

  const _CameraModePill({required this.title, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: active ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: active ? _InAppChatCameraPageState._cameraPurple : Colors.transparent,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}
