// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_local_variable, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, prefer_const_literals_to_create_immutables, curly_braces_in_flow_control_structures, sized_box_for_whitespace, dead_code, unnecessary_type_check, unnecessary_non_null_assertion, use_build_context_synchronously, unnecessary_brace_in_string_interps, prefer_final_fields
// respect_live_screen.dart
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';
import '../services/respect_live_service.dart';
import '../services/supabase_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';

void _logIgnoredError(Object error, StackTrace stackTrace) {
  if (kDebugMode) {
    debugPrint('Ignored error: $error\n$stackTrace');
  }
}


// ---------- شاشة قائمة البثوث المحسنة ----------
class RespectLiveScreen extends StatefulWidget {
  const RespectLiveScreen({super.key});

  @override
  State<RespectLiveScreen> createState() => _RespectLiveScreenState();
}

class _RespectLiveScreenState extends State<RespectLiveScreen> {
  List<Map<String, dynamic>> _streams = <Map<String, dynamic>>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    RespectLiveService.subscribeStreams(onChanged: _load);
  }

  Future<void> _load() async {
    try {
      final rows = await RespectLiveService.getLiveStreams();
      if (!mounted) return;
      setState(() {
        _streams = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  ImageProvider? _avatar(String? path) {
    final value = path?.trim() ?? '';
    if (value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) return NetworkImage(value);
    final file = File(value);
    if (file.existsSync()) return FileImage(file);
    return null;
  }

  Future<void> _startLive() async {
    final titleCtrl = TextEditingController(text: 'بث مباشر من Respect');
    bool video = true;

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return StatefulBuilder(
          builder: (context, setSheet) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkBg : AppColors.lightBg,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 46, height: 5, decoration: BoxDecoration(color: isDark ? AppColors.darkBorder : AppColors.lightBorder, borderRadius: BorderRadius.circular(99))),
                      const SizedBox(height: 18),
                      const Text('ابدأ بث جديد', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: titleCtrl,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.title_rounded),
                          hintText: 'عنوان البث',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        value: video,
                        onChanged: (v) => setSheet(() => video = v),
                        title: const Text('تشغيل الكاميرا', style: TextStyle(fontWeight: FontWeight.w900)),
                        subtitle: const Text('يمكنك قلب الكاميرا وتشغيل الفلاش من داخل البث'),
                        activeThumbColor: AppColors.purple,
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.purple,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          ),
                          onPressed: () => Navigator.pop(context, {'title': titleCtrl.text, 'video': video}),
                          icon: const Icon(Icons.sensors_rounded),
                          label: const Text('بدء البث الآن', style: TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (result == null) return;

    try {
      final stream = await RespectLiveService.startLive(
        title: result['title']?.toString() ?? '',
        video: result['video'] == true,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RespectLiveRoomScreen(
            stream: stream,
            isHost: true,
            startWithVideo: result['video'] == true,
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('تعذر بدء البث: $e');
    }
  }

  Future<void> _openStream(Map<String, dynamic> stream) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RespectLiveRoomScreen(
          stream: stream,
          isHost: false,
          startWithVideo: (stream['video_enabled'] ?? true) == true,
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
        appBar: null,
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: AppColors.purple,
          foregroundColor: Colors.white,
          onPressed: _startLive,
          icon: const Icon(Icons.sensors_rounded),
          label: const Text('ابدأ بث', style: TextStyle(fontWeight: FontWeight.w900)),
        ),
        body: RefreshIndicator(
          onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.purple))
              : _streams.isEmpty
              ? _EmptyLiveList(isDark: isDark)
              : ListView.separated(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 110),
            itemCount: _streams.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _LiveStreamCard(
              stream: _streams[i],
              isDark: isDark,
              avatarProvider: _avatar,
              onTap: () => _openStream(_streams[i]),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyLiveList extends StatelessWidget {
  final bool isDark;
  const _EmptyLiveList({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 80, 18, 120),
      children: [
        Icon(Icons.live_tv_rounded, size: 80, color: AppColors.purple.withValues(alpha: 0.85)),
        const SizedBox(height: 18),
        const Text('لا توجد بثوث مباشرة الآن', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        Text('ابدأ بثك وسيظهر للجميع. حاليًا مفتوح للجميع للتجربة.', textAlign: TextAlign.center, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, height: 1.5)),
      ],
    );
  }
}

class _LiveStreamCard extends StatelessWidget {
  final Map<String, dynamic> stream;
  final bool isDark;
  final ImageProvider? Function(String?) avatarProvider;
  final VoidCallback onTap;

  const _LiveStreamCard({
    required this.stream,
    required this.isDark,
    required this.avatarProvider,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final title = (stream['title'] ?? 'بث مباشر').toString();
    final hostName = (stream['host_name'] ?? stream['host_username'] ?? 'مستخدم').toString();
    final viewers = int.tryParse((stream['viewers_count'] ?? 0).toString()) ?? 0;
    return GlassCard(
      onTap: onTap,
      child: Row(
        children: [
          Stack(
            children: [
              CircleAvatar(
                radius: 31,
                backgroundColor: AppColors.purple.withValues(alpha: 0.3),
                backgroundImage: avatarProvider(stream['host_avatar']?.toString()),
                child: const Icon(Icons.person_rounded, color: Colors.white),
              ),
              PositionedDirectional(
                bottom: 0,
                end: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(99)),
                  child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text(hostName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.visibility_rounded, size: 16, color: AppColors.purple),
                    const SizedBox(width: 4),
                    Text('$viewers مشاهدة', style: const TextStyle(fontWeight: FontWeight.w900)),
                    const SizedBox(width: 10),
                    Icon((stream['video_enabled'] ?? true) == true ? Icons.videocam_rounded : Icons.mic_rounded, size: 16, color: AppColors.purple),
                  ],
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_left_rounded),
        ],
      ),
    );
  }
}

// ---------- معلومات المشاهدين والأدوار ----------
class _ViewerInfo {
  final String username;
  String name;
  String avatarPath;
  _ViewerRole role;
  _ViewerInfo({
    required this.username,
    required this.name,
    required this.avatarPath,
    required this.role,
  });
}

enum _ViewerRole { viewer, guest, moderator, host }

// ---------- شاشة غرفة البث المباشر المحسّنة بالكامل ----------
class RespectLiveRoomScreen extends StatefulWidget {
  final Map<String, dynamic> stream;
  final bool isHost;
  final bool startWithVideo;

  const RespectLiveRoomScreen({
    super.key,
    required this.stream,
    required this.isHost,
    required this.startWithVideo,
  });

  @override
  State<RespectLiveRoomScreen> createState() => _RespectLiveRoomScreenState();
}

class _FloatingHeart {
  final int id;
  final double x;
  final IconData icon;
  _FloatingHeart(this.id, this.x, this.icon);
}

class _GuestState {
  final String username;
  String name;
  bool accepted;
  bool muted;
  bool cameraAllowed;
  bool cameraOn;
  _GuestState({
    required this.username,
    required this.name,
    this.accepted = false,
    this.muted = false,
    this.cameraAllowed = false,
    this.cameraOn = false,
  });
}

enum _GuestLayoutMode { floating, split }

String _guestLayoutName(_GuestLayoutMode mode) => mode == _GuestLayoutMode.split ? 'split' : 'floating';
_GuestLayoutMode _guestLayoutFrom(dynamic value) {
  return value?.toString() == 'split' ? _GuestLayoutMode.split : _GuestLayoutMode.floating;
}

class _RespectLiveRoomScreenState extends State<RespectLiveRoomScreen> with TickerProviderStateMixin {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _guestLocalRenderer = RTCVideoRenderer();
  final TextEditingController _chatCtrl = TextEditingController();
  final Random _random = Random();
  final GlobalKey<ScaffoldState> _roomScaffoldKey = GlobalKey<ScaffoldState>();

  final List<Map<String, dynamic>> _messages = <Map<String, dynamic>>[];
  final Map<String, RTCPeerConnection> _hostPeers = <String, RTCPeerConnection>{};
  final Map<String, RTCPeerConnection> _guestSenderPeers = <String, RTCPeerConnection>{};
  final Map<String, RTCPeerConnection> _guestReceiverPeers = <String, RTCPeerConnection>{};
  final Map<String, RTCVideoRenderer> _guestRemoteRenderers = <String, RTCVideoRenderer>{};
  final Map<String, _GuestLayoutMode> _guestLayoutModes = <String, _GuestLayoutMode>{};
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = <String, List<RTCIceCandidate>>{};
  final Map<String, List<RTCIceCandidate>> _guestPendingCandidates = <String, List<RTCIceCandidate>>{};
  final List<RTCIceCandidate> _viewerPendingCandidates = <RTCIceCandidate>[];
  final Set<String> _offeredViewers = <String>{};
  final Map<String, _GuestState> _guestRequests = <String, _GuestState>{};
  final Map<String, _ViewerInfo> _connectedViewers = <String, _ViewerInfo>{};
  final Set<String> _moderators = <String>{};
  final List<_FloatingHeart> _hearts = <_FloatingHeart>[];
  final Map<String, Offset> _guestFloatingOffsets = <String, Offset>{};

  Offset _myGuestFloatingOffset = Offset.zero;
  double _cameraZoom = 1.0;
  double _baseCameraZoom = 1.0;
  double _remoteHostZoom = 1.0;
  DateTime _lastZoomSignalAt = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _viewerJoinRetryTimer;
  Timer? _hostOfferRetryTimer;
  Timer? _statsPulseTimer;
  Timer? _viewerStatsTimer;
  dynamic _chatChannel;
  dynamic _signalChannel;
  MediaStream? _localStream;
  MediaStream? _guestLocalStream;
  RTCPeerConnection? _viewerPeer;

  String _myId = '';
  String _myName = '';
  bool _ready = false;
  bool _muted = false;
  bool _cameraOff = false;
  bool _flashOn = false;
  bool _commentsEnabled = true;
  bool _viewerRemoteDescriptionSet = false;
  bool _guestAccepted = false;
  bool _guestMutedByHost = false;
  bool _guestCameraAllowed = false;
  bool _guestCameraOn = false;
  bool _guestMicMutedLocal = false;
  bool _guestRequestPending = false;
  _GuestLayoutMode _myGuestLayoutMode = _GuestLayoutMode.floating;
  int _viewersCount = 0;
  int _likesCount = 0;
  DateTime _lastCommentAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastCommentText = '';

  String get _streamId => widget.stream['id'].toString();
  String get _hostUsername => SupabaseService.displayUsername((widget.stream['host_username'] ?? '').toString());

  @override
  void initState() {
    super.initState();
    _viewersCount = int.tryParse((widget.stream['viewers_count'] ?? 0).toString()) ?? 0;
    _likesCount = int.tryParse((widget.stream['likes_count'] ?? widget.stream['likes'] ?? 0).toString()) ?? 0;
    _myGuestFloatingOffset = const Offset(12, 168);
    _init();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    await _guestLocalRenderer.initialize();

    final user = await RespectLiveService.currentUser();
    _myId = SupabaseService.displayUsername((user?['username'] ?? DateTime.now().millisecondsSinceEpoch).toString());
    _myName = (user?['name'] ?? user?['profileName'] ?? _myId).toString();
// نحصل على رسائل الدردشة القديمة
    final oldMessages = await RespectLiveService.getChatMessages(_streamId);
    if (mounted) setState(() => _messages.addAll(oldMessages.take(80)));

    _chatChannel = RespectLiveService.subscribeChat(
      streamId: _streamId,
      onMessage: (row) {
        if (!mounted || !_commentsEnabled) return;
        setState(() {
          _messages.add(Map<String, dynamic>.from(row));
          if (_messages.length > 80) _messages.removeRange(0, _messages.length - 80);
        });
      },
      onStreamChanged: (row) {
        if (!mounted) return;
        if (row['is_live'] == false && !widget.isHost) {
          NotificationService.showTopNotification('انتهى البث');
          Navigator.of(context).maybePop();
          return;
        }
        setState(() {
          _viewersCount = int.tryParse((row['viewers_count'] ?? _viewersCount).toString()) ?? _viewersCount;
          _likesCount = int.tryParse((row['likes_count'] ?? row['likes'] ?? _likesCount).toString()) ?? _likesCount;
        });
      },
    );

    _signalChannel = RespectLiveService.signalingChannel(streamId: _streamId, onSignal: _onSignal);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    if (widget.isHost) {
      await _startHostMedia();
      _startHostOfferRetryLoop();
    } else {
      await RespectLiveService.increaseViewer(_streamId);
      if (mounted) setState(() => _viewersCount = max(1, _viewersCount));
      await _startViewer();
    }

    // إرسال إشارة الانضمام مع معلومات المستخدم
    await _sendViewerHello();

    _statsPulseTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      setState(() {});
    });

    _viewerStatsTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      await _refreshLiveCounters();
    });
    await _refreshLiveCounters();

    if (mounted) setState(() => _ready = true);
  }

  Future<void> _cleanup() async {
    _sendViewerBye();
    try {
      if (widget.isHost) {
        await RespectLiveService.endLive(_streamId);
      } else {
        await RespectLiveService.decreaseViewer(_streamId);
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    _viewerJoinRetryTimer?.cancel();
    _hostOfferRetryTimer?.cancel();
    _statsPulseTimer?.cancel();
    _viewerStatsTimer?.cancel();
    await _chatChannel?.unsubscribe();
    await _signalChannel?.unsubscribe();

    for (final pc in _hostPeers.values) {
      try { await pc.close(); } catch (e, st) { _logIgnoredError(e, st); }
    }
    _hostPeers.clear();
    for (final pc in _guestSenderPeers.values) {
      try { await pc.close(); } catch (e, st) { _logIgnoredError(e, st); }
    }
    _guestSenderPeers.clear();
    for (final pc in _guestReceiverPeers.values) {
      try { await pc.close(); } catch (e, st) { _logIgnoredError(e, st); }
    }
    _guestReceiverPeers.clear();
    try { await _viewerPeer?.close(); } catch (e, st) { _logIgnoredError(e, st); }
    try {
      for (final t in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _localStream?.dispose();
      for (final t in _guestLocalStream?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _guestLocalStream?.dispose();
    } catch (e, st) { _logIgnoredError(e, st); }

    await _localRenderer.dispose();
    await _remoteRenderer.dispose();
    await _guestLocalRenderer.dispose();
    for (final r in _guestRemoteRenderers.values) {
      try { await r.dispose(); } catch (e, st) { _logIgnoredError(e, st); }
    }
    _guestRemoteRenderers.clear();
    _chatCtrl.dispose();
  }


  Future<void> _refreshLiveCounters() async {
    try {
      final row = await RespectLiveService.getLiveStreamById(_streamId);
      if (row == null || !mounted) return;
      final serverViewers = int.tryParse((row['viewers_count'] ?? _viewersCount).toString()) ?? _viewersCount;
      final serverLikes = int.tryParse((row['likes_count'] ?? row['likes'] ?? _likesCount).toString()) ?? _likesCount;
      final realtimeViewers = _connectedViewers.values.where((v) => v.role != _ViewerRole.host).length;
      setState(() {
        _viewersCount = max(serverViewers, realtimeViewers);
        _likesCount = max(_likesCount, serverLikes);
      });
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _sendViewerHello() async {
    final user = await RespectLiveService.currentUser();
    final name = (user?['name'] ?? user?['profileName'] ?? _myId).toString();
    final avatar = (user?['avatar_url'] ?? user?['imagePath'] ?? user?['profileImagePath'] ?? '').toString();
    await _sendLiveEvent(type: 'viewer_hello', data: {
      'name': name,
      'avatar': avatar,
      'isHost': widget.isHost,
    });
  }

  Future<void> _sendViewerBye() async {
    if (_myId.isEmpty) return;
    await _sendLiveEvent(type: 'viewer_bye', data: {});
  }

  // إرسال حدث عبر قناة الإشارات
  Future<void> _sendLiveEvent({required String type, Map<String, dynamic> data = const <String, dynamic>{}, String to = '*'}) async {
    await RespectLiveService.sendLiveEvent(
      channel: _signalChannel,
      streamId: _streamId,
      from: _myId,
      to: to,
      type: type,
      data: data,
    );
  }

  // ---------- بدء البث كـ Host ----------
  Future<void> _startHostMedia() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) throw Exception('صلاحية المايك مطلوبة');
    if (widget.startWithVideo) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) throw Exception('صلاحية الكاميرا مطلوبة');
    }
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': widget.startWithVideo ? {'facingMode': 'user', 'width': {'ideal': 1080}, 'height': {'ideal': 1920}, 'frameRate': {'ideal': 30, 'max': 30}} : false,
    });
    _localRenderer.srcObject = _localStream;
    final localStream = _localStream;
    _cameraOff = localStream == null ? true : !localStream.getVideoTracks().any((t) => t.enabled);
  }

  Future<void> _startViewer() async {
    final pc = await _createPeer();
    _viewerPeer = pc;
    await _sendViewerJoin();
    var attempts = 0;
    _viewerJoinRetryTimer?.cancel();
    _viewerJoinRetryTimer = Timer.periodic(const Duration(milliseconds: 1300), (timer) async {
      attempts++;
      if (!mounted || _remoteRenderer.srcObject != null || attempts > 10) {
        timer.cancel();
        return;
      }
      await _sendViewerJoin();
    });
  }

  Future<void> _sendViewerJoin() async {
    await _sendLiveEvent(type: 'viewer_join', data: {'viewer': _myId, 'name': _myName});
  }

  void _startHostOfferRetryLoop() {
    _hostOfferRetryTimer?.cancel();
    _hostOfferRetryTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted || !widget.isHost || _localStream == null) return;
      for (final viewerId in List<String>.from(_offeredViewers)) {
        final pc = _hostPeers[viewerId];
        if (pc == null) continue;
        final connected = pc.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected || pc.iceConnectionState == RTCIceConnectionState.RTCIceConnectionStateConnected || pc.iceConnectionState == RTCIceConnectionState.RTCIceConnectionStateCompleted;
        if (!connected) await _createOfferForViewer(viewerId, forceNew: true);
      }
    });
  }

  // ---------- إدارة الأدوار ----------
  Future<void> _assignModerator(String username) async {
    if (username.trim().isEmpty || username == _hostUsername) return;
    setState(() => _moderators.add(username));
    await _sendLiveEvent(type: 'moderator_update', data: {
      'action': 'add',
      'username': username,
    });
    if (mounted) NotificationService.showTopNotification('تم تعيين المشرف');
  }

  Future<void> _removeModerator(String username) async {
    setState(() => _moderators.remove(username));
    await _sendLiveEvent(type: 'moderator_update', data: {
      'action': 'remove',
      'username': username,
    });
    if (mounted) NotificationService.showTopNotification('تمت إزالة المشرف');
  }

  Future<void> _deleteMessage(String messageId) async {
    setState(() {
      _messages.removeWhere((m) => (m['id'] ?? '').toString() == messageId);
    });
    await _sendLiveEvent(type: 'delete_message', data: {'message_id': messageId});
  }

  // ---------- إشارات WebRTC العامة ----------
  Future<void> _onSignal(Map<String, dynamic> payload) async {
    if (payload['stream_id']?.toString() != _streamId) return;
    final to = payload['to']?.toString() ?? '';
    final from = payload['from']?.toString() ?? '';
    if (from == _myId) return;
    if (to != _myId && to != '*' && !(widget.isHost && to == _hostUsername)) return;

    final type = payload['type']?.toString() ?? '';
    final data = Map<String, dynamic>.from((payload['data'] as Map?) ?? <String, dynamic>{});

    // التعامل مع إشارات الأدوار وإدارة البث الجديدة
    switch (type) {
      case 'viewer_hello':
        _connectedViewers[from] = _ViewerInfo(
          username: from,
          name: (data['name'] ?? from).toString(),
          avatarPath: (data['avatar'] ?? '').toString(),
          role: from == _hostUsername ? _ViewerRole.host : (_moderators.contains(from) ? _ViewerRole.moderator : _ViewerRole.viewer),
        );
        if (mounted) setState(() => _viewersCount = max(_viewersCount, _connectedViewers.values.where((v) => v.role != _ViewerRole.host).length));
        break;
      case 'viewer_bye':
        _connectedViewers.remove(from);
        if (mounted) setState(() => _viewersCount = max(0, _connectedViewers.values.where((v) => v.role != _ViewerRole.host).length));
        break;
      case 'moderator_update':
        final action = data['action']?.toString();
        final username = data['username']?.toString() ?? '';
        if (action == 'add') {
          _moderators.add(username);
          if (_connectedViewers.containsKey(username)) {
            final viewer = _connectedViewers[username];
            if (viewer != null) viewer.role = _ViewerRole.moderator;
          }
        } else if (action == 'remove') {
          _moderators.remove(username);
          if (_connectedViewers.containsKey(username)) {
            final viewer = _connectedViewers[username];
            if (viewer != null) viewer.role = _ViewerRole.viewer;
          }
        }
        if (mounted) setState(() {});
        break;
      case 'delete_message':
        final msgId = data['message_id']?.toString() ?? '';
        setState(() {
          _messages.removeWhere((m) => (m['id'] ?? '').toString() == msgId);
        });
        break;
    // rest handled as before
    }

    // تمرير إلى المنطق الأصلي
    _onOriginalSignal(type, data, from, to);
  }

  void _onOriginalSignal(String type, Map<String, dynamic> data, String from, String to) async {
    // إعادة توجيه إلى المنطق الموجود مسبقًا دون تغيير
    // (الكود الكامل موجود أدناه لأغراض الاختصار)
    // ... نفس الكود القديم للمكالمات والضيوف
    // سنقوم بدمج المعالجة الكاملة
    if (type == 'guest_layout_change') {
      final owner = data['owner']?.toString() ?? from;
      _guestLayoutModes[owner] = _guestLayoutFrom(data['layout']);
      if (mounted) setState(() {});
      return;
    }
    if (type == 'guest_media_ready') {
      final owner = from;
      _guestLayoutModes[owner] = _guestLayoutFrom(data['layout']);
      await _requestGuestStream(owner);
      return;
    }
    if (type == 'guest_viewer_join' && !widget.isHost && _guestAccepted && _guestLocalStream != null && to == _myId) {
      await _createGuestOfferForReceiver(from);
      return;
    }
    if (type == 'guest_viewer_join' && widget.isHost && false) {
      return;
    }
    if (type == 'guest_offer' && to == _myId) {
      final owner = data['owner']?.toString() ?? from;
      await _handleGuestOffer(owner, data);
      return;
    }
    if (type == 'guest_answer' && to == _myId) {
      final pc = _guestSenderPeers[from];
      final sdp = data['sdp']?.toString();
      final descType = data['type']?.toString();
      if (pc != null && sdp != null && sdp.trim().isNotEmpty && descType != null && descType.trim().isNotEmpty) {
        await pc.setRemoteDescription(RTCSessionDescription(sdp, descType));
        await _flushGuestPending(from, pc);
      }
      return;
    }
    if (type == 'guest_candidate') {
      await _handleGuestCandidate(from, data);
      return;
    }

    if (type == 'like_tap') {
      _receiveLikeBurst(animate: true);
      return;
    }
    if (type == 'host_zoom' && !widget.isHost) {
      final zoom = double.tryParse((data['zoom'] ?? '1').toString()) ?? 1.0;
      if (mounted) {
        setState(() => _remoteHostZoom = zoom.clamp(1.0, 4.0).toDouble());
      }
      return;
    }
    if (type == 'viewer_kick' && !widget.isHost && to == _myId) {
      if (mounted) {
        NotificationService.showTopNotification('تم إخراجك من البث');
        Navigator.of(context).maybePop();
      }
      return;
    }
    if (type == 'comments_toggle') {
      if (!widget.isHost && mounted) setState(() => _commentsEnabled = data['enabled'] == true);
      return;
    }
    if (type == 'guest_request' && widget.isHost) {
      _guestRequests[from] = _GuestState(username: from, name: (data['name'] ?? from).toString());
      if (mounted) setState(() {});
      return;
    }
    if (type == 'guest_accept' && !widget.isHost && to == _myId) {
      setState(() {
        _guestAccepted = true;
        _guestRequestPending = false;
        _guestMutedByHost = data['muted'] == true;
        _guestCameraAllowed = data['cameraAllowed'] == true;
        _guestCameraOn = data['cameraOn'] == true && _guestCameraAllowed;
        _myGuestLayoutMode = _guestLayoutFrom(data['layout']);
      });
      await _startGuestMedia();
      return;
    }
    if ((type == 'guest_reject' || type == 'guest_kick') && !widget.isHost && to == _myId) {
      setState(() {
        _guestAccepted = false;
        _guestRequestPending = false;
        _guestMutedByHost = false;
        _guestCameraAllowed = false;
        _guestCameraOn = false;
      });
      await _stopGuestMedia();
      return;
    }
    if (type == 'guest_mute' && !widget.isHost && to == _myId) {
      setState(() => _guestMutedByHost = data['muted'] == true);
      for (final t in _guestLocalStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
        t.enabled = !_guestMutedByHost && !_guestMicMutedLocal;
      }
      return;
    }
    if (type == 'guest_camera_mode' && !widget.isHost && to == _myId) {
      setState(() {
        _guestCameraAllowed = data['cameraAllowed'] == true;
        if (!_guestCameraAllowed) _guestCameraOn = false;
      });
      await _startGuestMedia();
      return;
    }

    if (widget.isHost) {
      if (type == 'viewer_join') {
        _offeredViewers.add(from);
        await _createOfferForViewer(from);
      } else if (type == 'answer') {
        final pc = _hostPeers[from];
        if (pc == null) return;
        final sdp = data['sdp']?.toString();
        final descType = data['type']?.toString();
        if (sdp == null || sdp.trim().isEmpty || descType == null || descType.trim().isEmpty) return;
        await pc.setRemoteDescription(RTCSessionDescription(sdp, descType));
        await _flushPending(from, pc);
      } else if (type == 'candidate') {
        final pc = _hostPeers[from];
        final c = _candidateFromData(data);
        if (c == null) return;
        if (pc == null) {
          _pendingCandidates.putIfAbsent(from, () => <RTCIceCandidate>[]).add(c);
        } else {
          try { await pc.addCandidate(c); } catch (_) { _pendingCandidates.putIfAbsent(from, () => <RTCIceCandidate>[]).add(c); }
        }
      }
    } else {
      if (type == 'offer') {
        await _handleOffer(data);
      } else if (type == 'candidate') {
        final c = _candidateFromData(data);
        if (c == null) return;
        final pc = _viewerPeer;
        if (pc != null && _viewerRemoteDescriptionSet) {
          try { await pc.addCandidate(c); } catch (_) { _viewerPendingCandidates.add(c); }
        } else {
          _viewerPendingCandidates.add(c);
        }
      }
    }
  }

  // تم إضافة باقي دوال WebRTC كاملة هنا...
  // (الكود مطابق للإصدار السابق مع تحسينات بسيطة)
  // سيتم تضمين الدوال بالكامل في الكود النهائي

  // ---------- باقي الدوال الضرورية ----------
  Future<RTCPeerConnection> _createPeer({String? viewerId}) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun2.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });

    pc.onIceCandidate = (c) {
      final candidate = c.candidate;
      final receiver = widget.isHost ? (viewerId ?? '') : _hostUsername;
      if (candidate == null || candidate.trim().isEmpty || receiver.trim().isEmpty) return;
      _sendLiveEvent(type: 'candidate', data: c.toMap(), to: receiver);
    };

    pc.onTrack = (event) async {
      MediaStream? stream = event.streams.isNotEmpty ? event.streams.first : null;
      if (stream == null) {
        stream = await createLocalMediaStream('respect_live_remote_${DateTime.now().millisecondsSinceEpoch}');
        stream.addTrack(event.track);
      }
      _remoteRenderer.srcObject = stream;
      _viewerJoinRetryTimer?.cancel();
      if (mounted) setState(() {});
    };
    return pc;
  }

  // ... (باقي الكود الخاص بـ Guest/PeerConnections...)

  // ---------- واجهة المستخدم الجديدة ----------
  @override
  Widget build(BuildContext context) {
    final isHost = widget.isHost;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        key: _roomScaffoldKey,
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        endDrawer: isHost ? _buildAdminDrawer() : null,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _tapLike,
          onScaleStart: _handleRoomScaleStart,
          onScaleUpdate: _handleRoomScaleUpdate,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              _videoStage(),
              if (!_ready) _loadingOverlay(),
              _heartLayer(),
              _myGuestPreview(),
              _topBar(),
              _rightControls(),
              _bottomCommentsArea(),
              _viewerCountBadge(),
              if (isHost) _adminFAB(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loadingOverlay() => const Center(
    child: Text('جاري الاتصال...', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
  );

  Widget _videoStage() {
    final splitGuests = _guestRemoteRenderers.entries
        .where((entry) => entry.value.srcObject != null && _guestLayoutModes[entry.key] == _GuestLayoutMode.split)
        .toList();
    final floatingGuests = _guestRemoteRenderers.entries
        .where((entry) => entry.value.srcObject != null && _guestLayoutModes[entry.key] != _GuestLayoutMode.split)
        .toList();
    final showMySplitGuest = _guestAccepted &&
        _myGuestLayoutMode == _GuestLayoutMode.split &&
        _guestLocalRenderer.srcObject != null;

    final hasSplit = splitGuests.isNotEmpty || showMySplitGuest;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasSplit)
          Column(
            children: [
              Expanded(child: _mainHostVideo(compactSplit: true)),
              Container(height: 1, color: Colors.white.withValues(alpha: 0.18)),
              Expanded(
                child: showMySplitGuest
                    ? _videoSurface(renderer: _guestLocalRenderer, name: 'أنت ضيف', mirror: true)
                    : _videoSurface(
                  renderer: splitGuests.first.value,
                  name: _guestRequests[splitGuests.first.key]?.name ?? splitGuests.first.key,
                ),
              ),
            ],
          )
        else
          _mainHostVideo(),
        for (final entry in floatingGuests)
          _guestVideoTile(
            guestId: entry.key,
            renderer: entry.value,
            name: _guestRequests[entry.key]?.name ?? entry.key,
            floating: true,
          ),
      ],
    );
  }

  Widget _mainHostVideo({bool compactSplit = false}) {
    final renderer = widget.isHost ? _localRenderer : _remoteRenderer;
    return RepaintBoundary(
      child: _videoSurface(
        renderer: renderer,
        name: compactSplit ? (widget.stream['host_name'] ?? 'صاحب البث').toString() : '',
        mirror: widget.isHost,
        zoom: widget.isHost ? _cameraZoom : _remoteHostZoom,
      ),
    );
  }

  Widget _videoSurface({required RTCVideoRenderer renderer, String name = '', bool mirror = false, double zoom = 1.0}) {
    final safeZoom = zoom.clamp(1.0, 4.0).toDouble();
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: Transform.scale(
            scale: safeZoom,
            child: RTCVideoView(renderer, mirror: mirror, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          ),
        ),
        if (name.trim().isNotEmpty)
          PositionedDirectional(
            start: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: Text(name, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900)),
            ),
          ),
      ],
    );
  }

  Widget _guestVideoTile({required String guestId, required RTCVideoRenderer renderer, required String name, required bool floating}) {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final tileWidth = min(138.0, size.width * 0.34);
    final tileHeight = tileWidth * 1.38;
    final defaultOffset = Offset(size.width - tileWidth - 12, padding.top + 220);
    final current = _clampFloatingOffset(
      _guestFloatingOffsets[guestId] ?? defaultOffset,
      tileWidth,
      tileHeight,
    );
    _guestFloatingOffsets[guestId] = current;

    return Positioned(
      left: current.dx,
      top: current.dy,
      width: tileWidth,
      height: tileHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          setState(() {
            _guestFloatingOffsets[guestId] = _clampFloatingOffset(
              (_guestFloatingOffsets[guestId] ?? current) + details.delta,
              tileWidth,
              tileHeight,
            );
          });
        },
        onDoubleTap: _tapLike,
        child: _floatingVideoBox(
          renderer: renderer,
          name: name,
          mirror: false,
          showMoveHint: true,
        ),
      ),
    );
  }

  Widget _floatingVideoBox({required RTCVideoRenderer renderer, required String name, bool mirror = false, bool showMoveHint = false}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: Colors.white.withValues(alpha: 0.24), width: 1.5),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.62), blurRadius: 18)],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RTCVideoView(renderer, mirror: mirror, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            PositionedDirectional(
              top: 6,
              end: 6,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: showMoveHint ? 1 : 0,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                  ),
                  child: const Icon(Icons.open_with_rounded, size: 15, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              bottom: 6,
              left: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.42),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  name,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _myGuestPreview() {
    if (!_guestAccepted || _myGuestLayoutMode == _GuestLayoutMode.split || _guestLocalRenderer.srcObject == null) return const SizedBox.shrink();
    final size = MediaQuery.of(context).size;
    final tileWidth = min(126.0, size.width * 0.32);
    final tileHeight = tileWidth * 1.36;
    final current = _clampFloatingOffset(_myGuestFloatingOffset, tileWidth, tileHeight);
    _myGuestFloatingOffset = current;

    return Positioned(
      left: current.dx,
      top: current.dy,
      width: tileWidth,
      height: tileHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          setState(() {
            _myGuestFloatingOffset = _clampFloatingOffset(
              _myGuestFloatingOffset + details.delta,
              tileWidth,
              tileHeight,
            );
          });
        },
        onDoubleTap: _tapLike,
        child: _floatingVideoBox(
          renderer: _guestLocalRenderer,
          name: 'أنت ضيف',
          mirror: true,
          showMoveHint: true,
        ),
      ),
    );
  }

  Offset _clampFloatingOffset(Offset offset, double width, double height) {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final minX = 8.0;
    final maxX = max(8.0, size.width - width - 8);
    final minY = padding.top + 82;
    final maxY = max(minY, size.height - height - padding.bottom - 92);
    return Offset(
      offset.dx.clamp(minX, maxX).toDouble(),
      offset.dy.clamp(minY, maxY).toDouble(),
    );
  }

  void _handleRoomScaleStart(ScaleStartDetails details) {
    if (!widget.isHost) return;
    _baseCameraZoom = _cameraZoom;
  }

  void _handleRoomScaleUpdate(ScaleUpdateDetails details) {
    if (!widget.isHost || details.pointerCount < 2) return;
    final nextZoom = (_baseCameraZoom * details.scale).clamp(1.0, 4.0).toDouble();
    if ((nextZoom - _cameraZoom).abs() < 0.02) return;
    setState(() => _cameraZoom = nextZoom);
    _applyCameraZoom(nextZoom);
    final now = DateTime.now();
    if (now.difference(_lastZoomSignalAt).inMilliseconds > 120) {
      _lastZoomSignalAt = now;
      _sendLiveEvent(type: 'host_zoom', data: {'zoom': nextZoom});
    }
  }

  Future<void> _applyCameraZoom(double zoom) async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    final safeZoom = zoom.clamp(1.0, 4.0).toDouble();
    try {
      await (tracks.first as dynamic).applyConstraints({
        'advanced': [
          {'zoom': safeZoom},
        ],
      });
    } catch (_) {
      try {
        await (tracks.first as dynamic).applyConstraints({'zoom': safeZoom});
      } catch (_) {
        // بعض الأجهزة لا تدعم hardware zoom، لذلك نرسل قيمة الزوم للمشاهدين
        // ويطبقون نفس التكبير على فيديو المضيف حتى يظهر عند الجميع.
      }
    }
  }


  Widget _topBar() {
    final title = (widget.stream['title'] ?? 'بث مباشر').toString();
    return PositionedDirectional(
      start: 0,
      end: 0,
      top: 0,
      child: Container(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 8, bottom: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.75), Colors.black.withValues(alpha: 0.0)],
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            _circleButton(icon: Icons.close_rounded, onTap: () => Navigator.pop(context)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(gradient: const LinearGradient(colors: [Colors.redAccent, Colors.pinkAccent]), borderRadius: BorderRadius.circular(99)),
              child: const Text('LIVE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16)),
                  Text(widget.stream['host_name'] ?? '', style: TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
            if (widget.isHost) IconButton(icon: const Icon(Icons.admin_panel_settings, color: Colors.amberAccent), onPressed: () => _roomScaffoldKey.currentState?.openEndDrawer()),
          ],
        ),
      ),
    );
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap, Color color = Colors.black54}) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12)],
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 22),
        onPressed: onTap,
        padding: EdgeInsets.zero,
      ),
    );
  }

  Widget _rightControls() {
    return PositionedDirectional(
      end: 12,
      top: MediaQuery.of(context).padding.top + 130,
      child: Column(
        children: [
          _actionButton(Icons.favorite_rounded, _compactNumber(_likesCount), color: Colors.pinkAccent, onTap: _tapLike),
          const SizedBox(height: 10),
          if (widget.isHost) ...[
            _actionButton(_muted ? Icons.mic_off_rounded : Icons.mic_rounded, '', onTap: _toggleMic),
            _actionButton(_cameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded, '', onTap: _toggleCamera),
            _actionButton(Icons.cameraswitch_rounded, '', onTap: _flipCamera),
            _actionButton(_flashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded, '', onTap: _toggleFlash),
            _actionButton(Icons.group_add_rounded, '', color: _guestRequests.values.any((g) => !g.accepted) ? AppColors.purple : Colors.black54, onTap: _showGuestPanel),
            _actionButton(_commentsEnabled ? Icons.chat_rounded : Icons.comments_disabled_rounded, '', onTap: _toggleComments),
          ] else ...[
            _actionButton(_guestAccepted ? Icons.groups_rounded : Icons.person_add_alt_1_rounded, _guestRequestPending ? 'طلب' : '', onTap: _requestGuest),
            if (_guestAccepted) _actionButton((_guestMutedByHost || _guestMicMutedLocal) ? Icons.mic_off_rounded : Icons.mic_rounded, '', onTap: _toggleGuestMicLocal),
            if (_guestAccepted) _actionButton(_guestCameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded, '', onTap: _toggleGuestCameraLocal),
          ],
        ],
      ),
    );
  }

  Widget _actionButton(IconData icon, String label, {Color color = Colors.black54, VoidCallback? onTap}) {
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 12)],
          ),
          child: IconButton(
            icon: Icon(icon, color: Colors.white, size: 26),
            onPressed: onTap ?? () {},
            padding: EdgeInsets.zero,
          ),
        ),
        if (label.isNotEmpty) Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _bottomCommentsArea() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _commentsLayer(),
          _chatInputBar(),
        ],
      ),
    );
  }

  Widget _commentsLayer() {
    if (!_commentsEnabled) {
      return Container(
        padding: const EdgeInsets.all(12),
        color: Colors.black.withValues(alpha: 0.6),
        child: const Text('التعليقات متوقفة من صاحب البث', style: TextStyle(color: Colors.white70)),
      );
    }
    return Container(
      height: MediaQuery.of(context).size.height * 0.25,
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _messages.length,
        itemBuilder: (context, index) {
          final msg = _messages[_messages.length - 1 - index];
          final msgId = (msg['id'] ?? '').toString();
          final sender = (msg['sender_name'] ?? msg['sender_username'] ?? 'مستخدم').toString();
          final text = (msg['text'] ?? '').toString();
          final canDelete = widget.isHost || _moderators.contains(_myId);

          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(text: '$sender  ', style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.bold)),
                          TextSpan(text: text, style: const TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                ),
                if (canDelete)
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline, size: 18, color: Colors.redAccent),
                    onPressed: () => _deleteMessage(msgId),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _chatInputBar() {
    if (widget.isHost) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: Colors.black.withValues(alpha: 0.8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _chatCtrl,
              style: const TextStyle(color: Colors.white),
              maxLength: 180,
              buildCounter: (_, {required currentLength, required isFocused, maxLength}) => const SizedBox.shrink(),
              decoration: InputDecoration(
                hintText: 'اكتب تعليق...',
                hintStyle: const TextStyle(color: Colors.white70),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.15),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              onSubmitted: (_) => _sendChat(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.send, color: AppColors.purple), onPressed: _sendChat),
        ],
      ),
    );
  }

  Widget _viewerCountBadge() {
    return PositionedDirectional(
      start: 12,
      top: MediaQuery.of(context).padding.top + 120,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            const Icon(Icons.visibility_rounded, size: 16, color: AppColors.purple),
            const SizedBox(width: 5),
            Text(_compactNumber(_viewersCount), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _adminFAB() {
    return PositionedDirectional(
      start: 16,
      bottom: 100,
      child: FloatingActionButton(
        heroTag: 'admin_panel',
        backgroundColor: AppColors.purple,
        onPressed: () => _roomScaffoldKey.currentState?.openEndDrawer(),
        child: const Icon(Icons.settings, color: Colors.white),
      ),
    );
  }

  // درج إدارة البث للمضيف
  Widget _buildAdminDrawer() {
    final viewers = _connectedViewers.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Drawer(
      backgroundColor: AppColors.darkBg,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('لوحة التحكم', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                  IconButton(
                    onPressed: () => _roomScaffoldKey.currentState?.closeEndDrawer(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _adminChip(Icons.visibility_rounded, '${_compactNumber(_viewersCount)} مشاهد'),
                  _adminChip(Icons.favorite_rounded, '${_compactNumber(_likesCount)} إعجاب'),
                  _adminChip(Icons.admin_panel_settings_rounded, '${_moderators.length} مشرف'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Divider(color: Colors.white12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('المشاهدون والمشرفون', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: viewers.isEmpty
                  ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('لا يوجد مشاهدون بعد', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w800)),
                ),
              )
                  : ListView.separated(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
                itemCount: viewers.length,
                separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                itemBuilder: (context, index) {
                  final v = viewers[index];
                  final isHostUser = v.username == _hostUsername || v.role == _ViewerRole.host;
                  final isMod = _moderators.contains(v.username) || v.role == _ViewerRole.moderator;
                  return ListTile(
                    leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: AppColors.purple.withValues(alpha: 0.3),
                      backgroundImage: v.avatarPath.startsWith('http') ? NetworkImage(v.avatarPath) : null,
                      child: v.avatarPath.startsWith('http') ? null : const Icon(Icons.person, color: Colors.white),
                    ),
                    title: Text(v.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                    subtitle: Text(
                      isHostUser ? 'صاحب البث' : (isMod ? 'مشرف' : (v.role == _ViewerRole.guest ? 'ضيف' : 'مشاهد')),
                      style: TextStyle(color: isMod ? Colors.amberAccent : Colors.white54),
                    ),
                    trailing: isHostUser
                        ? const Icon(Icons.verified_rounded, color: Colors.amberAccent)
                        : PopupMenuButton<String>(
                      color: const Color(0xFF1A1A2E),
                      iconColor: Colors.white,
                      onSelected: (action) {
                        if (action == 'mod') _assignModerator(v.username);
                        if (action == 'unmod') _removeModerator(v.username);
                        if (action == 'kick') _sendLiveEvent(type: 'viewer_kick', to: v.username);
                      },
                      itemBuilder: (_) => [
                        if (!isMod) const PopupMenuItem(value: 'mod', child: Text('تعيين مشرف')),
                        if (isMod) const PopupMenuItem(value: 'unmod', child: Text('إزالة مشرف')),
                        const PopupMenuItem(value: 'kick', child: Text('طرد')),
                      ],
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

  Widget _adminChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppColors.purple),
          const SizedBox(width: 5),
          Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
        ],
      ),
    );
  }

  // دوال مساعدة
  void _tapLike() {
    _receiveLikeBurst(animate: true);
    RespectLiveService.incrementLikes(_streamId);
    _sendLiveEvent(type: 'like_tap');
  }

  void _receiveLikeBurst({bool animate = false}) {
    setState(() {
      _likesCount++;
      if (animate) {
        final id = DateTime.now().microsecondsSinceEpoch;
        _hearts.add(_FloatingHeart(id, 50 + _random.nextDouble() * 200, Icons.favorite));
        if (_hearts.length > 20) _hearts.removeAt(0);
        Future.delayed(const Duration(seconds: 1), () => _hearts.removeWhere((h) => h.id == id));
      }
    });
  }

  Widget _heartLayer() {
    return IgnorePointer(
      child: Stack(
        children: _hearts.map((h) {
          return Positioned(
            right: h.x,
            bottom: 120,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(seconds: 1),
              builder: (context, value, child) {
                return Opacity(opacity: 1 - value, child: Transform.translate(offset: Offset(0, -200 * value), child: child));
              },
              child: Icon(h.icon, color: Colors.pinkAccent, size: 36),
            ),
          );
        }).toList(),
      ),
    );
  }

  void _toggleMic() {
    final tracks = _localStream?.getAudioTracks() ?? [];
    for (final t in tracks) t.enabled = !t.enabled;
    setState(() => _muted = tracks.isNotEmpty ? !tracks.first.enabled : false);
  }

  void _toggleCamera() {
    final tracks = _localStream?.getVideoTracks() ?? [];
    for (final t in tracks) t.enabled = !t.enabled;
    setState(() => _cameraOff = tracks.isNotEmpty ? !tracks.first.enabled : true);
  }

  void _flipCamera() {
    final tracks = _localStream?.getVideoTracks() ?? [];
    if (tracks.isNotEmpty) Helper.switchCamera(tracks.first);
    setState(() {
      _cameraZoom = 1.0;
      _baseCameraZoom = 1.0;
    });
  }

  void _toggleFlash() {
    _flashOn = !_flashOn;
    final tracks = _localStream?.getVideoTracks() ?? [];
    if (tracks.isNotEmpty) (tracks.first as dynamic).setTorch(_flashOn);
    setState(() {});
  }

  void _toggleComments() {
    _commentsEnabled = !_commentsEnabled;
    setState(() {});
    _sendLiveEvent(type: 'comments_toggle', data: {'enabled': _commentsEnabled});
  }

  void _showGuestPanel() {
    // تمثيل لوحة الضيوف باستخدام bottom sheet
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _GuestManagementSheet(
        guestRequests: _guestRequests.values.toList(),
        moderators: _moderators,
        onAccept: (guest, layout) async {
          await _acceptGuest(guest, layout: layout);
        },
        onMute: (guest) => _toggleGuestMute(guest),
        onCamera: (guest) => _toggleGuestCameraMode(guest),
        onAssignMod: _assignModerator,
        onRemoveMod: _removeModerator,
        onKick: _kickGuest,
      ),
    );
  }


  Future<void> _createOfferForViewer(String viewerId, {bool forceNew = false}) async {
    if (!widget.isHost || _localStream == null || viewerId.trim().isEmpty) return;
    RTCPeerConnection? old = _hostPeers[viewerId];
    if (forceNew && old != null) {
      try { await old.close(); } catch (e, st) { _logIgnoredError(e, st); }
      _hostPeers.remove(viewerId);
    }

    final pc = _hostPeers[viewerId] ?? await _createPeer(viewerId: viewerId);
    _hostPeers[viewerId] = pc;

    final senders = await pc.getSenders();
    if (senders.isEmpty) {
      final localStream = _localStream;
      if (localStream == null) return;
      for (final track in localStream.getTracks()) {
        try { await pc.addTrack(track, localStream); } catch (e, st) { _logIgnoredError(e, st); }
      }
    }

    final offer = await pc.createOffer(<String, dynamic>{
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await pc.setLocalDescription(offer);
    await _sendLiveEvent(
      type: 'offer',
      to: viewerId,
      data: {'sdp': offer.sdp, 'type': offer.type},
    );
    await _flushPending(viewerId, pc);
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    final sdp = data['sdp']?.toString();
    final descType = data['type']?.toString();
    if (sdp == null || sdp.trim().isEmpty || descType == null || descType.trim().isEmpty) return;

    final pc = _viewerPeer ?? await _createPeer();
    _viewerPeer = pc;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, descType));
    _viewerRemoteDescriptionSet = true;

    final answer = await pc.createAnswer(<String, dynamic>{
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await pc.setLocalDescription(answer);
    await _sendLiveEvent(type: 'answer', to: _hostUsername, data: {'sdp': answer.sdp, 'type': answer.type});

    for (final c in List<RTCIceCandidate>.from(_viewerPendingCandidates)) {
      try { await pc.addCandidate(c); } catch (e, st) { _logIgnoredError(e, st); }
    }
    _viewerPendingCandidates.clear();
  }

  Future<void> _flushPending(String owner, RTCPeerConnection pc) async {
    final list = _pendingCandidates.remove(owner) ?? <RTCIceCandidate>[];
    for (final c in list) {
      try { await pc.addCandidate(c); } catch (e, st) { _logIgnoredError(e, st); }
    }
  }

  RTCIceCandidate? _candidateFromData(Map<String, dynamic> data) {
    final candidate = data['candidate']?.toString();
    if (candidate == null || candidate.trim().isEmpty) return null;
    return RTCIceCandidate(
      candidate,
      data['sdpMid']?.toString(),
      data['sdpMLineIndex'] is int ? data['sdpMLineIndex'] as int : int.tryParse((data['sdpMLineIndex'] ?? '0').toString()),
    );
  }

  Future<void> _sendChat() async {
    final text = _chatCtrl.text.trim();
    if (text.isEmpty || widget.isHost || !_commentsEnabled) return;
    final now = DateTime.now();
    if (_lastCommentText == text && now.difference(_lastCommentAt).inMilliseconds < 900) return;
    _lastCommentText = text;
    _lastCommentAt = now;
    _chatCtrl.clear();
    try {
      await RespectLiveService.sendChatMessage(
        streamId: _streamId,
        text: text,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _messages.add({
          'id': 'local_${now.microsecondsSinceEpoch}',
          'sender_username': _myId,
          'sender_name': _myName,
          'text': text,
        });
        if (_messages.length > 80) _messages.removeRange(0, _messages.length - 80);
      });
    }
  }

  Future<void> _requestGuest() async {
    if (widget.isHost || _guestAccepted || _guestRequestPending) return;
    setState(() => _guestRequestPending = true);
    await _sendLiveEvent(type: 'guest_request', to: _hostUsername, data: {'name': _myName});
  }

  Future<void> _acceptGuest(_GuestState guest, {required _GuestLayoutMode layout}) async {
    if (!widget.isHost) return;
    guest.accepted = true;
    guest.cameraAllowed = true;
    guest.cameraOn = true;
    _guestLayoutModes[guest.username] = layout;
    _connectedViewers[guest.username]?.role = _ViewerRole.guest;
    if (mounted) setState(() {});
    await _sendLiveEvent(
      type: 'guest_accept',
      to: guest.username,
      data: {
        'muted': guest.muted,
        'cameraAllowed': guest.cameraAllowed,
        'cameraOn': guest.cameraOn,
        'layout': _guestLayoutName(layout),
      },
    );
  }

  Future<void> _kickGuest(_GuestState guest) async {
    guest.accepted = false;
    _guestLayoutModes.remove(guest.username);
    final renderer = _guestRemoteRenderers.remove(guest.username);
    try { await renderer?.dispose(); } catch (e, st) { _logIgnoredError(e, st); }
    final pc1 = _guestReceiverPeers.remove(guest.username);
    final pc2 = _guestSenderPeers.remove(guest.username);
    try { await pc1?.close(); } catch (e, st) { _logIgnoredError(e, st); }
    try { await pc2?.close(); } catch (e, st) { _logIgnoredError(e, st); }
    if (mounted) setState(() {});
    await _sendLiveEvent(type: 'guest_kick', to: guest.username);
  }

  Future<void> _toggleGuestMute(_GuestState guest) async {
    guest.muted = !guest.muted;
    if (mounted) setState(() {});
    await _sendLiveEvent(type: 'guest_mute', to: guest.username, data: {'muted': guest.muted});
  }

  Future<void> _toggleGuestCameraMode(_GuestState guest) async {
    guest.cameraAllowed = !guest.cameraAllowed;
    guest.cameraOn = guest.cameraAllowed;
    if (mounted) setState(() {});
    await _sendLiveEvent(
      type: 'guest_camera_mode',
      to: guest.username,
      data: {'cameraAllowed': guest.cameraAllowed, 'cameraOn': guest.cameraOn},
    );
  }

  Future<void> _toggleGuestMicLocal() async {
    _guestMicMutedLocal = !_guestMicMutedLocal;
    for (final t in _guestLocalStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !_guestMutedByHost && !_guestMicMutedLocal;
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleGuestCameraLocal() async {
    if (!_guestCameraAllowed) return;
    _guestCameraOn = !_guestCameraOn;
    for (final t in _guestLocalStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = _guestCameraOn;
    }
    if (_guestCameraOn && (_guestLocalStream?.getVideoTracks().isEmpty ?? true)) {
      await _startGuestMedia();
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _startGuestMedia() async {
    if (!_guestAccepted) return;
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return;
    if (_guestCameraAllowed && _guestCameraOn) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) _guestCameraOn = false;
    }

    await _stopGuestMedia(closeState: false);
    _guestLocalStream = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': (_guestCameraAllowed && _guestCameraOn)
          ? {'facingMode': 'user', 'width': {'ideal': 720}, 'height': {'ideal': 1280}, 'frameRate': {'ideal': 24, 'max': 30}}
          : false,
    });
    for (final t in _guestLocalStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !_guestMutedByHost && !_guestMicMutedLocal;
    }
    for (final t in _guestLocalStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = _guestCameraOn;
    }
    _guestLocalRenderer.srcObject = _guestLocalStream;
    if (mounted) setState(() {});
    await _sendLiveEvent(type: 'guest_media_ready', data: {'layout': _guestLayoutName(_myGuestLayoutMode)});
  }

  Future<void> _stopGuestMedia({bool closeState = true}) async {
    try {
      for (final t in _guestLocalStream?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _guestLocalStream?.dispose();
    } catch (e, st) { _logIgnoredError(e, st); }
    _guestLocalStream = null;
    _guestLocalRenderer.srcObject = null;
    for (final pc in _guestSenderPeers.values) {
      try { await pc.close(); } catch (e, st) { _logIgnoredError(e, st); }
    }
    _guestSenderPeers.clear();
    if (closeState && mounted) setState(() {});
  }

  Future<void> _requestGuestStream(String owner) async {
    if (owner.trim().isEmpty || owner == _myId) return;
    await _sendLiveEvent(type: 'guest_viewer_join', to: owner, data: {'viewer': _myId});
  }

  Future<RTCPeerConnection> _createGuestPeer({required String to, required bool sender}) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
    pc.onIceCandidate = (c) {
      final candidate = c.candidate;
      if (candidate == null || candidate.trim().isEmpty) return;
      _sendLiveEvent(type: 'guest_candidate', to: to, data: c.toMap());
    };
    if (!sender) {
      pc.onTrack = (event) async {
        MediaStream? stream = event.streams.isNotEmpty ? event.streams.first : null;
        if (stream == null) {
          stream = await createLocalMediaStream('respect_guest_remote_${DateTime.now().millisecondsSinceEpoch}');
          stream.addTrack(event.track);
        }
        final renderer = _guestRemoteRenderers[to] ?? RTCVideoRenderer();
        if (!_guestRemoteRenderers.containsKey(to)) await renderer.initialize();
        renderer.srcObject = stream;
        _guestRemoteRenderers[to] = renderer;
        if (mounted) setState(() {});
      };
    }
    return pc;
  }

  Future<void> _createGuestOfferForReceiver(String receiver) async {
    if (_guestLocalStream == null || receiver.trim().isEmpty) return;
    final old = _guestSenderPeers.remove(receiver);
    try { await old?.close(); } catch (e, st) { _logIgnoredError(e, st); }
    final pc = await _createGuestPeer(to: receiver, sender: true);
    _guestSenderPeers[receiver] = pc;
    final guestLocalStream = _guestLocalStream;
    if (guestLocalStream == null) return;
    for (final track in guestLocalStream.getTracks()) {
      try { await pc.addTrack(track, guestLocalStream); } catch (e, st) { _logIgnoredError(e, st); }
    }
    final offer = await pc.createOffer(<String, dynamic>{
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await pc.setLocalDescription(offer);
    await _sendLiveEvent(
      type: 'guest_offer',
      to: receiver,
      data: {'owner': _myId, 'sdp': offer.sdp, 'type': offer.type, 'layout': _guestLayoutName(_myGuestLayoutMode)},
    );
  }

  Future<void> _handleGuestOffer(String owner, Map<String, dynamic> data) async {
    final sdp = data['sdp']?.toString();
    final descType = data['type']?.toString();
    if (owner.trim().isEmpty || sdp == null || sdp.trim().isEmpty || descType == null || descType.trim().isEmpty) return;
    _guestLayoutModes[owner] = _guestLayoutFrom(data['layout']);
    final old = _guestReceiverPeers.remove(owner);
    try { await old?.close(); } catch (e, st) { _logIgnoredError(e, st); }
    final pc = await _createGuestPeer(to: owner, sender: false);
    _guestReceiverPeers[owner] = pc;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, descType));
    final answer = await pc.createAnswer(<String, dynamic>{
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await pc.setLocalDescription(answer);
    await _sendLiveEvent(type: 'guest_answer', to: owner, data: {'sdp': answer.sdp, 'type': answer.type});
    await _flushGuestPending(owner, pc);
  }

  Future<void> _handleGuestCandidate(String from, Map<String, dynamic> data) async {
    final c = _candidateFromData(data);
    if (c == null) return;
    final pc = _guestReceiverPeers[from] ?? _guestSenderPeers[from];
    if (pc == null) {
      _guestPendingCandidates.putIfAbsent(from, () => <RTCIceCandidate>[]).add(c);
      return;
    }
    try { await pc.addCandidate(c); } catch (_) { _guestPendingCandidates.putIfAbsent(from, () => <RTCIceCandidate>[]).add(c); }
  }

  Future<void> _flushGuestPending(String owner, RTCPeerConnection pc) async {
    final list = _guestPendingCandidates.remove(owner) ?? <RTCIceCandidate>[];
    for (final c in list) {
      try { await pc.addCandidate(c); } catch (e, st) { _logIgnoredError(e, st); }
    }
  }

  String _compactNumber(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return '$value';
  }
}

// واجهة إدارة الضيوف منفصلة للأناقة
class _GuestManagementSheet extends StatelessWidget {
  final List<_GuestState> guestRequests;
  final Set<String> moderators;
  final Function(_GuestState, _GuestLayoutMode) onAccept;
  final Function(_GuestState) onMute;
  final Function(_GuestState) onCamera;
  final Function(String) onAssignMod;
  final Function(String) onRemoveMod;
  final Function(_GuestState) onKick;

  const _GuestManagementSheet({
    required this.guestRequests,
    required this.moderators,
    required this.onAccept,
    required this.onMute,
    required this.onCamera,
    required this.onAssignMod,
    required this.onRemoveMod,
    required this.onKick,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'إدارة الضيوف',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: guestRequests.isEmpty
                    ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Center(
                    child: Text(
                      'لا توجد طلبات ضيوف الآن',
                      style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w800),
                    ),
                  ),
                )
                    : ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: guestRequests.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final guest = guestRequests[index];
                    return _GuestTile(
                      guest: guest,
                      isMod: moderators.contains(guest.username),
                      onAcceptFloating: () => onAccept(guest, _GuestLayoutMode.floating),
                      onAcceptSplit: () => onAccept(guest, _GuestLayoutMode.split),
                      onMute: () => onMute(guest),
                      onCamera: () => onCamera(guest),
                      onAssignMod: () => onAssignMod(guest.username),
                      onRemoveMod: () => onRemoveMod(guest.username),
                      onKick: () => onKick(guest),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuestTile extends StatelessWidget {
  final _GuestState guest;
  final bool isMod;
  final VoidCallback onAcceptFloating;
  final VoidCallback onAcceptSplit;
  final VoidCallback onMute;
  final VoidCallback onCamera;
  final VoidCallback onAssignMod;
  final VoidCallback onRemoveMod;
  final VoidCallback onKick;

  const _GuestTile({
    required this.guest,
    required this.isMod,
    required this.onAcceptFloating,
    required this.onAcceptSplit,
    required this.onMute,
    required this.onCamera,
    required this.onAssignMod,
    required this.onRemoveMod,
    required this.onKick,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          CircleAvatar(radius: 16, child: Icon(Icons.person, color: Colors.white)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(guest.name, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
          if (!guest.accepted) ...[
            IconButton(icon: Icon(Icons.picture_in_picture_alt, color: Colors.greenAccent), onPressed: onAcceptFloating),
            IconButton(icon: Icon(Icons.splitscreen, color: Colors.lightBlueAccent), onPressed: onAcceptSplit),
          ] else ...[
            IconButton(icon: Icon(guest.muted ? Icons.mic_off : Icons.mic, color: Colors.white), onPressed: onMute),
            IconButton(icon: Icon(guest.cameraAllowed ? Icons.videocam : Icons.videocam_off, color: Colors.white), onPressed: onCamera),
            IconButton(icon: Icon(isMod ? Icons.admin_panel_settings : Icons.person_add, color: Colors.amber), onPressed: isMod ? onRemoveMod : onAssignMod),
            IconButton(icon: Icon(Icons.block, color: Colors.redAccent), onPressed: onKick),
          ],
        ],
      ),
    );
  }
}
