import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../screens/chat_screen.dart';
import '../screens/incoming_call_screen.dart';
import '../screens/feed_screen.dart';
import '../theme/app_theme.dart';
import 'supabase_service.dart';

void _scannerSafeIgnore([Object? error, StackTrace? stackTrace]) {}


void _respectSafeLog(Object error, [StackTrace? stackTrace]) {
  if (kDebugMode) {
    _scannerSafeIgnore();
    if (stackTrace != null) _scannerSafeIgnore();
  }
}


class NotificationService {
  NotificationService._();

  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _messagesChannel = AndroidNotificationChannel(
    'respect_messages_channel',
    'Respect Messages',
    description: 'إشعارات الرسائل الخاصة',
    importance: Importance.high,
  );

  static const AndroidNotificationChannel _postsChannel = AndroidNotificationChannel(
    'respect_posts_channel',
    'Respect Post Alerts',
    description: 'إشعارات التغريدات الجديدة من المستخدمين الذين فعّلت إشعاراتهم',
    importance: Importance.high,
  );

  static const AndroidNotificationChannel _callsChannel = AndroidNotificationChannel(
    'respect_calls_channel',
    'Respect Incoming Calls',
    description: 'إشعارات ورنين المكالمات الواردة',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  static bool _ready = false;
  static String? _launchPayload;
  static final Set<String> _shownIds = <String>{};

  static OverlayEntry? _topNotificationEntry;
  static Timer? _topNotificationTimer;

  /// إشعار داخلي عالمي يظهر من أعلى الشاشة ويعمل في كل الصفحات.
  /// استخدمه بدل ScaffoldMessenger/SnackBar:
  /// NotificationService.showTopNotification('تم الحفظ');
  static void showTopNotification(
      String message, {
        String title = 'Respect',
        IconData icon = Icons.notifications_rounded,
        Color? accentColor,
        Duration duration = const Duration(milliseconds: 2800),
        VoidCallback? onTap,
      }) {
    final navigator = navigatorKey.currentState;
    final overlay = navigator?.overlay;
    if (overlay == null) return;

    final cleanMessage = message.trim();
    if (cleanMessage.isEmpty) return;

    _topNotificationTimer?.cancel();
    _topNotificationEntry?.remove();
    _topNotificationEntry = null;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _RespectTopNotificationOverlay(
        title: title,
        message: cleanMessage,
        icon: icon,
        accentColor: accentColor ?? AppColors.purpleLight,
        duration: duration,
        onTap: onTap,
        onDismissed: () {
          if (_topNotificationEntry == entry) {
            _topNotificationEntry = null;
          }
          try {
            entry.remove();
          } catch (e, st) { _respectSafeLog(e, st); }
        },
      ),
    );

    _topNotificationEntry = entry;
    overlay.insert(entry);

    _topNotificationTimer = Timer(duration + const Duration(milliseconds: 520), () {
      try {
        entry.remove();
      } catch (e, st) { _respectSafeLog(e, st); }
      if (_topNotificationEntry == entry) _topNotificationEntry = null;
    });
  }

  static void showTopSuccess(String message, {String title = 'تم بنجاح'}) {
    showTopNotification(
      message,
      title: title,
      icon: Icons.check_circle_rounded,
      accentColor: AppColors.success,
    );
  }

  static void showTopError(String message, {String title = 'حدث خطأ'}) {
    showTopNotification(
      message,
      title: title,
      icon: Icons.error_rounded,
      accentColor: AppColors.danger,
      duration: const Duration(milliseconds: 3600),
    );
  }


  static Future<void> initialize() async {
    if (_ready) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.trim().isEmpty) return;
        handlePayload(payload);
      },
    );

    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_messagesChannel);
    await android?.createNotificationChannel(_postsChannel);
    await android?.createNotificationChannel(_callsChannel);
    await android?.requestNotificationsPermission();
    await android?.requestFullScreenIntentPermission();

    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    final payload = launchDetails?.notificationResponse?.payload;
    if (launchDetails?.didNotificationLaunchApp == true && payload != null && payload.trim().isNotEmpty) {
      _launchPayload = payload;
    }

    _ready = true;
  }

  static Future<void> openLaunchPayloadIfAny() async {
    final payload = _launchPayload;
    if (payload == null || payload.trim().isEmpty) return;
    _launchPayload = null;
    await Future<void>.delayed(const Duration(milliseconds: 450));
    handlePayload(payload);
  }

  static int _stableId(String value) {
    var hash = 0;
    for (final unit in value.codeUnits) {
      hash = 0x1fffffff & (hash + unit);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= (hash >> 6);
    }
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash ^= (hash >> 11);
    hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
    return max(1, hash);
  }

  static Future<void> showMessageNotification({
    required String messageId,
    required String senderUsername,
    required String senderName,
    required String text,
  }) async {
    await initialize();
    if (_shownIds.contains('msg_$messageId')) return;
    _shownIds.add('msg_$messageId');

    final payload = jsonEncode({
      'type': 'message',
      'peerUsername': SupabaseService.displayUsername(senderUsername),
      'peerName': senderName.trim().isEmpty ? SupabaseService.displayUsername(senderUsername) : senderName.trim(),
    });

    const androidDetails = AndroidNotificationDetails(
      'respect_messages_channel',
      'Respect Messages',
      channelDescription: 'إشعارات الرسائل الخاصة',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      ticker: 'رسالة جديدة',
      autoCancel: true,
    );

    await _plugin.show(
      _stableId('msg_$messageId'),
      senderName.trim().isEmpty ? SupabaseService.displayUsername(senderUsername) : senderName.trim(),
      text.trim().isEmpty ? 'أرسل لك رسالة' : text.trim(),
      const NotificationDetails(android: androidDetails),
      payload: payload,
    );

    showTopNotification(
      text.trim().isEmpty ? 'أرسل لك رسالة' : text.trim(),
      title: senderName.trim().isEmpty ? SupabaseService.displayUsername(senderUsername) : senderName.trim(),
      icon: Icons.chat_bubble_rounded,
      accentColor: AppColors.purpleLight,
      duration: const Duration(milliseconds: 4200),
      onTap: () => handlePayload(payload),
    );
  }

  static Future<void> showIncomingCallNotification({
    required String callId,
    required String callerUsername,
    required String callerName,
    String? callerAvatarPath,
    required bool video,
  }) async {
    await initialize();
    if (_shownIds.contains('call_$callId')) return;
    _shownIds.add('call_$callId');

    final payload = jsonEncode({
      'type': 'call',
      'callId': callId,
      'callerUsername': SupabaseService.displayUsername(callerUsername),
      'callerName': callerName.trim().isEmpty ? SupabaseService.displayUsername(callerUsername) : callerName.trim(),
      'callerAvatarPath': callerAvatarPath ?? '',
      'video': video,
    });

    final androidDetails = AndroidNotificationDetails(
      'respect_calls_channel',
      'Respect Incoming Calls',
      channelDescription: 'إشعارات ورنين المكالمات الواردة',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      ticker: video ? 'مكالمة فيديو واردة' : 'مكالمة صوتية واردة',
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      playSound: true,
      enableVibration: true,
      timeoutAfter: 45000,
      visibility: NotificationVisibility.public,
    );

    await _plugin.show(
      _stableId('call_$callId'),
      video ? 'مكالمة فيديو واردة' : 'مكالمة صوتية واردة',
      callerName.trim().isEmpty ? SupabaseService.displayUsername(callerUsername) : callerName.trim(),
      NotificationDetails(android: androidDetails),
      payload: payload,
    );
  }

  static Future<void> cancelCallNotification(String callId) async {
    await _plugin.cancel(_stableId('call_$callId'));
  }

  static void handlePayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      final type = decoded['type']?.toString();
      final nav = navigatorKey.currentState;
      if (nav == null) return;

      if (type == 'message') {
        final peerUsername = decoded['peerUsername']?.toString();
        final peerName = decoded['peerName']?.toString();
        if (peerUsername == null || peerUsername.trim().isEmpty) return;
        nav.push(MaterialPageRoute(
          builder: (_) => ChatScreen(
            peerUsername: peerUsername,
            peerName: peerName,
          ),
        ));
      } else if (type == 'post_reply') {
        final postId = decoded['postId']?.toString() ?? decoded['post_id']?.toString();
        final replyId = decoded['replyId']?.toString() ?? decoded['reply_id']?.toString();
        if (postId == null || postId.trim().isEmpty) return;
        nav.push(MaterialPageRoute(
          builder: (_) => FeedScreen(
            openPostId: postId,
            openReplyId: replyId,
          ),
        ));
      } else if (type == 'post') {
        final postId = decoded['postId']?.toString() ?? decoded['post_id']?.toString();
        if (postId == null || postId.trim().isEmpty) return;
        nav.push(MaterialPageRoute(
          builder: (_) => FeedScreen(openPostId: postId),
        ));
      } else if (type == 'call') {
        final callId = decoded['callId']?.toString();
        final callerUsername = decoded['callerUsername']?.toString();
        final callerName = decoded['callerName']?.toString() ?? 'مستخدم';
        final callerAvatarPath = decoded['callerAvatarPath']?.toString();
        final video = decoded['video'] == true || decoded['video']?.toString() == 'true';
        if (callId == null || callId.trim().isEmpty || callerUsername == null || callerUsername.trim().isEmpty) return;
        nav.push(MaterialPageRoute(
          builder: (_) => IncomingCallScreen(
            callId: callId,
            callerName: callerName,
            callerUsername: callerUsername,
            callerAvatarPath: callerAvatarPath,
            video: video,
          ),
        ));
      }
    } catch (e, st) { _respectSafeLog(e, st); }
  }



  static Future<void> showReplyInAppNotification({
    required String replyId,
    required String postId,
    required String authorUsername,
    required String authorName,
    required String text,
  }) async {
    final safeReplyId = replyId.trim().isEmpty
        ? 'reply_${postId}_${authorUsername}_${text.hashCode}'
        : replyId.trim();
    if (_shownIds.contains('inapp_reply_$safeReplyId')) return;
    _shownIds.add('inapp_reply_$safeReplyId');

    final titleName = authorName.trim().isEmpty
        ? SupabaseService.displayUsername(authorUsername)
        : authorName.trim();
    final body = text.trim().isEmpty ? 'رد على تغريدتك' : text.trim();
    final payload = jsonEncode({
      'type': 'post_reply',
      'replyId': safeReplyId,
      'postId': postId,
      'authorUsername': SupabaseService.displayUsername(authorUsername),
      'authorName': titleName,
      'text': text,
    });

    showTopNotification(
      body.length > 120 ? '${body.substring(0, 120)}...' : body,
      title: '$titleName رد عليك',
      icon: Icons.reply_rounded,
      accentColor: AppColors.purpleLight,
      duration: const Duration(milliseconds: 4800),
      onTap: () => handlePayload(payload),
    );
  }

  static Future<void> showPostNotification({
    required String postId,
    required String authorUsername,
    required String authorName,
    required String text,
  }) async {
    await initialize();
    final safeId = postId.trim().isEmpty ? '${authorUsername}_${text.hashCode}' : postId.trim();
    if (_shownIds.contains('post_$safeId')) return;
    _shownIds.add('post_$safeId');

    final titleName = authorName.trim().isEmpty ? SupabaseService.displayUsername(authorUsername) : authorName.trim();
    final body = text.trim().isEmpty
        ? 'نشر تغريدة جديدة'
        : (text.trim().length > 110 ? '${text.trim().substring(0, 110)}...' : text.trim());

    final payload = jsonEncode({
      'type': 'post',
      'postId': safeId,
      'authorUsername': SupabaseService.displayUsername(authorUsername),
      'authorName': titleName,
      'text': text,
    });

    const androidDetails = AndroidNotificationDetails(
      'respect_posts_channel',
      'Respect Post Alerts',
      channelDescription: 'إشعارات التغريدات الجديدة من المستخدمين الذين فعّلت إشعاراتهم',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    await _plugin.show(
      _stableId('post_$safeId'),
      '$titleName نشر تغريدة جديدة',
      body,
      const NotificationDetails(android: androidDetails),
      payload: payload,
    );
  }

  static Future<void> showFromFcmData(Map<String, dynamic> data) async {
    final type = data['type']?.toString();
    if (type == 'call') {
      await showIncomingCallNotification(
        callId: (data['callId'] ?? data['call_id'] ?? '').toString(),
        callerUsername: (data['callerUsername'] ?? data['caller_username'] ?? '').toString(),
        callerName: (data['callerName'] ?? data['caller_name'] ?? 'مستخدم').toString(),
        callerAvatarPath: (data['callerAvatarPath'] ?? data['caller_avatar'] ?? '').toString(),
        video: data['video'] == true || data['video']?.toString() == 'true' || data['call_type']?.toString() == 'video',
      );
      return;
    }
    if (type == 'message') {
      await showMessageNotification(
        messageId: (data['messageId'] ?? data['message_id'] ?? DateTime.now().millisecondsSinceEpoch).toString(),
        senderUsername: (data['senderUsername'] ?? data['sender_username'] ?? '').toString(),
        senderName: (data['senderName'] ?? data['sender_name'] ?? '').toString(),
        text: (data['text'] ?? data['body'] ?? 'رسالة جديدة').toString(),
      );
      return;
    }
    if (type == 'post') {
      await showPostNotification(
        postId: (data['postId'] ?? data['post_id'] ?? DateTime.now().millisecondsSinceEpoch).toString(),
        authorUsername: (data['authorUsername'] ?? data['author_username'] ?? '').toString(),
        authorName: (data['authorName'] ?? data['author_name'] ?? data['title'] ?? '').toString(),
        text: (data['text'] ?? data['body'] ?? 'تغريدة جديدة').toString(),
      );
      return;
    }
    if (type == 'post_event' ||
        type == 'community_report_rejected' ||
        type == 'community_report_accepted' ||
        type == 'report_rejected_reporter' ||
        type == 'report_accepted_reporter' ||
        type == 'report_accepted_owner') {
      final eventType = (data['eventType'] ?? data['event_type'] ?? type).toString();
      final defaultTitle = eventType == 'report_accepted_owner'
          ? 'تم حذف تغريدتك'
          : (eventType == 'community_report_accepted' || eventType == 'report_accepted_reporter')
          ? 'تم قبول البلاغ'
          : 'نتيجة البلاغ';
      final defaultBody = eventType == 'report_accepted_owner'
          ? 'تم حذف تغريدتك بعد قبول بلاغ عليها.'
          : (eventType == 'community_report_accepted' || eventType == 'report_accepted_reporter')
          ? 'راجعنا البلاغ وتم حذف التغريدة.'
          : 'راجعنا البلاغ والتغريدة سليمة.';
      final title = (data['title'] ?? defaultTitle).toString();
      final body = (data['body'] ?? data['text'] ?? defaultBody).toString();
      const androidDetails = AndroidNotificationDetails(
        'respect_posts_channel',
        'Respect Post Alerts',
        channelDescription: 'إشعارات التغريدات والبلاغات',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      );
      await _plugin.show(
        _stableId('event_${data['postId'] ?? data['post_id'] ?? DateTime.now().millisecondsSinceEpoch}'),
        title,
        body,
        const NotificationDetails(android: androidDetails),
        payload: jsonEncode({
          'type': 'post',
          'postId': (data['postId'] ?? data['post_id'] ?? '').toString(),
        }),
      );
      return;
    }
  }

}



class _RespectTopNotificationOverlay extends StatefulWidget {
  final String title;
  final String message;
  final IconData icon;
  final Color accentColor;
  final Duration duration;
  final VoidCallback? onTap;
  final VoidCallback onDismissed;

  const _RespectTopNotificationOverlay({
    required this.title,
    required this.message,
    required this.icon,
    required this.accentColor,
    required this.duration,
    this.onTap,
    required this.onDismissed,
  });

  @override
  State<_RespectTopNotificationOverlay> createState() => _RespectTopNotificationOverlayState();
}

class _RespectTopNotificationOverlayState extends State<_RespectTopNotificationOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  Timer? _dismissTimer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
      reverseDuration: const Duration(milliseconds: 420),
    );

    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );

    _slide = Tween<Offset>(
      begin: const Offset(0, -1.25),
      end: Offset.zero,
    ).animate(curved);

    _fade = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _scale = Tween<double>(
      begin: 0.96,
      end: 1,
    ).animate(curved);

    _controller.forward();
    _dismissTimer = Timer(widget.duration, _close);
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;

    try {
      await _controller.reverse();
    } catch (e, st) { _respectSafeLog(e, st); }

    if (mounted) {
      widget.onDismissed();
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark ? const Color(0xE6110B1F) : const Color(0xF7FFFFFF);
    final textColor = isDark ? Colors.white : const Color(0xFF17131F);
    final mutedColor = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    final borderColor = widget.accentColor.withValues(alpha: isDark ? 0.34 : 0.25);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: false,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              14,
              media.padding.top > 0 ? 8 : 14,
              14,
              0,
            ),
            child: SlideTransition(
              position: _slide,
              child: FadeTransition(
                opacity: _fade,
                child: ScaleTransition(
                  scale: _scale,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                    onVerticalDragEnd: (details) {
                      if ((details.primaryVelocity ?? 0) < -80) {
                        _close();
                      }
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(26),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: Material(
                          type: MaterialType.transparency,
                          child: Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(minHeight: 76),
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(26),
                              border: Border.all(color: borderColor),
                              boxShadow: [
                                BoxShadow(
                                  color: widget.accentColor.withValues(alpha: isDark ? 0.32 : 0.22),
                                  blurRadius: 34,
                                  spreadRadius: 1,
                                  offset: const Offset(0, 14),
                                ),
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.10),
                                  blurRadius: 18,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Row(
                              textDirection: TextDirection.rtl,
                              children: [
                                Container(
                                  width: 46,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        widget.accentColor.withValues(alpha: 0.95),
                                        AppColors.purple.withValues(alpha: 0.92),
                                      ],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: widget.accentColor.withValues(alpha: 0.45),
                                        blurRadius: 18,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                  ),
                                  child: Icon(widget.icon, color: Colors.white, size: 24),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        widget.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textDirection: TextDirection.rtl,
                                        style: TextStyle(
                                          color: textColor,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        widget.message,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textDirection: TextDirection.rtl,
                                        style: TextStyle(
                                          color: mutedColor,
                                          fontSize: 12.5,
                                          height: 1.35,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                InkWell(
                                  borderRadius: BorderRadius.circular(999),
                                  onTap: _close,
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.07),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.close_rounded,
                                      color: mutedColor,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
