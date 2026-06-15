// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, use_build_context_synchronously, unnecessary_this, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures, prefer_final_fields, unnecessary_type_check, unnecessary_non_null_assertion
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../services/supabase_service.dart';
import '../services/notification_service.dart';
import 'feed_screen.dart';

void _scannerSafeIgnore([Object? error, StackTrace? stackTrace]) {}


class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  static const String _accountsKey = 'respect_accounts_v1';
  static const String _currentUserKey = 'respect_current_user_id';
  static const String _followingKey = 'respect_following_v1';
  static const String _postsKey = 'respect_city_posts_v1';
  static const String _messagesKey = 'respect_direct_messages_v1';
  static const String _threadsKey = 'respect_direct_threads_v1';
  static const String _mentionsKey = 'respect_mentions_v1';
  static const String _generalNotificationsLocalKey = 'respect_general_notifications_local_v1';

  String _currentUsername = '@user';
  String _currentName = 'Respect App';
  String? _currentAvatarPath;
  Map<String, String> _namesByUsername = {};
  Map<String, List<String>> _following = {};
  List<_RespectNotification> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  String _cleanUsername(String value) {
    final v = value.trim().replaceAll(RegExp(r'\s+'), '_').replaceAll('@', '').toLowerCase();
    return v.isEmpty ? '@user' : '@$v';
  }

  // إضافة هذه الدوال داخل class _NotificationsScreenState

  Future<void> _toggleLike(CityPost post) async {
    final previousLiked = post.isLiked;
    final previousLikes = post.likes;
    setState(() {
      post.isLiked = !post.isLiked;
      post.likes += post.isLiked ? 1 : -1;
    });
    try {
      final result = await SupabaseService.togglePostLike(
        postId: post.id,
        username: _currentUsername,
      );
      if (!mounted) return;
      setState(() {
        post.isLiked = result['isLiked'] == true;
        post.likes = int.tryParse((result['likes'] ?? post.likes).toString()) ?? post.likes;
      });
    } catch (_) {
      setState(() {
        post.isLiked = previousLiked;
        post.likes = previousLikes;
      });
      NotificationService.showTopError('تعذر تحديث الإعجاب');
    }
  }

  Future<void> _toggleFavorite(CityPost post) async {
    final wasSaved = post.isFavorite;
    setState(() => post.isFavorite = !wasSaved);
    // إما حفظ أو إزالة من المحفوظات باستخدام SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final savedKey = 'respect_saved_posts_v1';
    final raw = prefs.getString(savedKey);
    List<Map<String, dynamic>> items = [];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) items = List<Map<String, dynamic>>.from(decoded);
      } catch (_) { _scannerSafeIgnore(); }
    }
    if (!wasSaved) {
      // حفظ
      final data = post.toJson();
      data['savedAt'] = DateTime.now().toIso8601String();
      items.insert(0, data);
    } else {
      items.removeWhere((e) => (e['id'] ?? '').toString() == post.id);
    }
    await prefs.setString(savedKey, jsonEncode(items));
    NotificationService.showTopNotification(wasSaved ? 'تمت إزالة التغريدة من المحفوظات' : 'تم حفظ التغريدة في المحفوظات');
  }

  Future<void> _repostPost(CityPost post) async {
    // نستخدم نفس الـ modal bottom sheet كما في FeedScreen
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
                const SizedBox(height: 16),
                ListTile(
                  leading: Icon(Icons.repeat_rounded, color: post.isReposted ? AppColors.purple : AppColors.purple),
                  title: Text(post.isReposted ? 'تمت إعادة النشر مسبقًا' : 'إعادة نشر', style: const TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text(post.isReposted ? 'لا يمكن إعادة نشر نفس التغريدة أكثر من مرة' : 'إظهار التغريدة لمتابعيك', style: TextStyle(color: muted, fontSize: 12)),
                  onTap: () => Navigator.pop(context, 'repost'),
                ),
                ListTile(
                  leading: const Icon(Icons.format_quote_rounded, color: AppColors.purple),
                  title: const Text('اقتباس', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text('اكتب تعليقك مع التغريدة', style: TextStyle(color: muted, fontSize: 12)),
                  onTap: () => Navigator.pop(context, 'quote'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (action == null) return;
    if (action == 'quote') {
      // فتح شاشة إنشاء تغريدة مقتبسة (يمكن فتح ComposePostScreen)
      NotificationService.showTopNotification('اقتباس التغريدة سيتم فتحه قريبًا');
      return;
    }
    if (action != 'repost') return;
    final previousReposted = post.isReposted;
    final previousReposts = post.reposts;
    setState(() {
      post.isReposted = !post.isReposted;
      post.reposts += post.isReposted ? 1 : -1;
    });
    try {
      final result = await SupabaseService.togglePostRepost(
        postId: post.id,
        username: _currentUsername,
      );
      if (!mounted) return;
      setState(() {
        post.isReposted = result['isReposted'] == true;
        post.reposts = int.tryParse((result['reposts'] ?? post.reposts).toString()) ?? post.reposts;
      });
      NotificationService.showTopNotification(post.isReposted ? 'تمت إعادة النشر' : 'تم إلغاء إعادة النشر');
    } catch (_) {
      setState(() {
        post.isReposted = previousReposted;
        post.reposts = previousReposts;
      });
      NotificationService.showTopError('تعذر تحديث إعادة النشر');
    }
  }

  Future<void> _sharePost(CityPost post) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.chat_rounded, color: AppColors.success),
                  title: const Text('إرسال للواتس', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: const Text('سيتم نسخ نص التغريدة لتلصقه في واتساب'),
                  onTap: () => Navigator.pop(context, 'whatsapp'),
                ),
                ListTile(
                  leading: const Icon(Icons.link_rounded, color: AppColors.purple),
                  title: const Text('نسخ رابط التغريدة', style: TextStyle(fontWeight: FontWeight.w900)),
                  onTap: () => Navigator.pop(context, 'copy'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null) return;
    final text = '${post.user} ${post.username}\n${post.text}\nrespect://post/${post.id}';
    await Clipboard.setData(ClipboardData(text: text));
    NotificationService.showTopNotification(choice == 'whatsapp' ? 'تم نسخ التغريدة، افتح واتساب والصقها' : 'تم نسخ رابط التغريدة');
  }

  Future<void> _loadNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final currentId = prefs.getString(_currentUserKey) ?? prefs.getString('current_user_id');
    final namesByUsername = <String, String>{};

    String currentUsername = _cleanUsername(currentId ?? '@user');
    String currentName = 'Respect App';
    String? currentAvatarPath;

    try {
      final serverUser = await SupabaseService.currentUser();
      if (serverUser != null) {
        currentUsername = SupabaseService.displayUsername((serverUser['username'] ?? currentUsername).toString());
        currentName = (serverUser['name'] ?? serverUser['profileName'] ?? currentUsername).toString();
        currentAvatarPath = (serverUser['avatar_url'] ?? serverUser['imagePath'] ?? serverUser['profileImagePath'])?.toString();
      }
    } catch (_) { _scannerSafeIgnore(); }

    final accountsRaw = prefs.getString(_accountsKey);
    if (accountsRaw != null && accountsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(accountsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final username = _cleanUsername((item['username'] ?? item['id'] ?? '').toString());
            final name = (item['profileName'] ?? item['name'] ?? username).toString();
            namesByUsername[username] = name;
            if ((item['id'] ?? '').toString() == currentId) {
              currentUsername = username;
              currentName = name;
              currentAvatarPath ??= (item['avatar_url'] ?? item['imagePath'] ?? item['profileImagePath'])?.toString();
            }
          }
        }
      } catch (_) { _scannerSafeIgnore(); }
    }

    final following = <String, List<String>>{};
    final followingRaw = prefs.getString(_followingKey);
    if (followingRaw != null && followingRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(followingRaw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is List) {
              following[_cleanUsername(key.toString())] = value.map((e) => _cleanUsername(e.toString())).toSet().toList();
            }
          });
        }
      } catch (_) { _scannerSafeIgnore(); }
    }

    final followedUsers = following[currentUsername] ?? const <String>[];
    final notifications = <_RespectNotification>[];

    final postsRaw = prefs.getString(_postsKey);
    if (postsRaw != null && postsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(postsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final username = _cleanUsername((item['username'] ?? '').toString());
            if (username == currentUsername || !followedUsers.contains(username)) continue;
            final name = (item['user'] ?? namesByUsername[username] ?? username).toString();
            final text = (item['text'] ?? '').toString().trim();
            final id = (item['id'] ?? '').toString();
            notifications.add(
              _RespectNotification(
                id: 'post_$id',
                title: 'منشور جديد',
                body: text.isEmpty ? '$name نشر مرفق جديد' : '$name نشر: $text',
                icon: Icons.forum_rounded,
                time: _timeFromId(id, fallbackText: (item['time'] ?? 'الآن').toString()),
                createdAt: _dateFromId(id),
                unread: true,
                postId: id,
              ),
            );
          }
        }
      } catch (_) { _scannerSafeIgnore(); }
    }


    // منشورات الأشخاص الذين تتابعهم من Supabase حتى تظهر من أي جهاز.
    try {
      final serverPosts = await SupabaseService.getPosts();
      for (final item in serverPosts) {
        final username = _cleanUsername((item['username'] ?? '').toString());
        if (username == currentUsername || !followedUsers.contains(username)) continue;
        final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString()) ?? DateTime.now();
        final name = (item['name'] ?? item['user'] ?? namesByUsername[username] ?? username).toString();
        final text = (item['text'] ?? '').toString().trim();
        final id = (item['id'] ?? '').toString();
        notifications.add(
          _RespectNotification(
            id: 'post_server_$id',
            title: 'منشور جديد',
            body: text.isEmpty ? '$name نشر مرفق جديد' : '$name نشر: $text',
            icon: Icons.forum_rounded,
            time: _relativeTime(createdAt),
            createdAt: createdAt,
            unread: true,
            postId: id,
          ),
        );
      }
    } catch (_) { _scannerSafeIgnore(); }

    // إشعارات المنشن العالمية من Supabase.
    try {
      final serverMentions = await SupabaseService.getMentionNotificationsForUser(currentUsername);
      for (final item in serverMentions) {
        final author = _cleanUsername((item['author_username'] ?? '').toString());
        // نسمح بالمنشن لنفسك أيضًا، لذلك لا نستبعد الكاتب إذا كان هو نفس المستخدم الحالي.
        final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString()) ?? DateTime.now();
        final name = (item['author_name'] ?? namesByUsername[author] ?? author).toString();
        final postId = (item['post_id'] ?? '').toString();
        notifications.add(
          _RespectNotification(
            id: 'mention_server_${item['id'] ?? postId}',
            title: 'تم ذكرك في تغريدة',
            body: '$name ذكرك: ${(item['text'] ?? '').toString()}',
            icon: Icons.alternate_email_rounded,
            time: _relativeTime(createdAt),
            createdAt: createdAt,
            unread: true,
            postId: postId,
          ),
        );
      }
    } catch (_) { _scannerSafeIgnore(); }

    // إشعارات المنشن المحلية احتياط.
    final mentionsRaw = prefs.getString(_mentionsKey);
    if (mentionsRaw != null && mentionsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(mentionsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final target = _cleanUsername((item['targetUsername'] ?? '').toString());
            final author = _cleanUsername((item['authorUsername'] ?? '').toString());
            if (target != currentUsername) continue;
            final createdAt = DateTime.tryParse((item['createdAt'] ?? '').toString()) ?? DateTime.now();
            final name = (item['authorName'] ?? namesByUsername[author] ?? author).toString();
            notifications.add(
              _RespectNotification(
                id: 'mention_${item['id'] ?? createdAt.microsecondsSinceEpoch}',
                title: 'تم ذكرك في تغريدة',
                body: '$name ذكرك: ${(item['text'] ?? '').toString()}',
                icon: Icons.alternate_email_rounded,
                time: _relativeTime(createdAt),
                createdAt: createdAt,
                unread: true,
                postId: (item['postId'] ?? '').toString(),
              ),
            );
          }
        }
      } catch (_) { _scannerSafeIgnore(); }
    }


    // إشعارات إعادة النشر لمنشوراتك.
    try {
      final reposts = await SupabaseService.getRepostNotificationsForUser(currentUsername);
      for (final item in reposts) {
        final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString()) ?? DateTime.now();
        final name = (item['actor_name'] ?? item['actor_username'] ?? 'مستخدم').toString();
        final postId = (item['post_id'] ?? '').toString();
        notifications.add(
          _RespectNotification(
            id: 'repost_${item['id'] ?? postId}',
            title: 'تمت إعادة نشر تغريدتك',
            body: '$name أعاد نشر تغريدتك: ${(item['post_text'] ?? '').toString()}',
            icon: Icons.repeat_rounded,
            time: _relativeTime(createdAt),
            createdAt: createdAt,
            unread: true,
            postId: postId,
          ),
        );
      }
    } catch (_) { _scannerSafeIgnore(); }

    // إشعارات الردود العالمية على تغريداتك.
    try {
      final replies = await SupabaseService.getReplyNotificationsForUser(currentUsername);
      for (final item in replies) {
        final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString()) ?? DateTime.now();
        final name = (item['actor_name'] ?? item['actor_username'] ?? 'مستخدم').toString();
        final postId = (item['post_id'] ?? '').toString();
        notifications.add(
          _RespectNotification(
            id: 'reply_server_${item['id'] ?? postId}',
            title: 'رد جديد على تغريدتك',
            body: '$name رد عليك: ${(item['text'] ?? '').toString()}',
            icon: Icons.reply_rounded,
            time: _relativeTime(createdAt),
            createdAt: createdAt,
            unread: true,
            postId: postId,
          ),
        );
      }
    } catch (_) { _scannerSafeIgnore(); }

    // إشعارات اللايك العالمية على تغريداتك.
    try {
      final likes = await SupabaseService.getLikeNotificationsForUser(currentUsername);
      for (final item in likes) {
        final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString()) ?? DateTime.now();
        final name = (item['actor_name'] ?? item['actor_username'] ?? 'مستخدم').toString();
        final postId = (item['post_id'] ?? '').toString();
        notifications.add(
          _RespectNotification(
            id: 'like_server_${item['id'] ?? postId}',
            title: 'إعجاب جديد',
            body: '$name أعجب بتغريدتك: ${(item['post_text'] ?? '').toString()}',
            icon: Icons.favorite_rounded,
            time: _relativeTime(createdAt),
            createdAt: createdAt,
            unread: true,
            postId: postId,
          ),
        );
      }
    } catch (_) { _scannerSafeIgnore(); }


    // إشعارات نتائج بلاغات المجتمعات وتفاعلات post_events العامة.
    try {
      final events = await SupabaseService.getPostEventNotificationsForUser(currentUsername);
      for (final item in events) {
        final type = (item['type'] ?? '').toString();
        final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString()) ?? DateTime.now();
        final name = (item['actor_name'] ?? item['actor_username'] ?? 'Respect AI').toString();
        final postId = (item['post_id'] ?? '').toString();
        final text = (item['text'] ?? '').toString();
        String title;
        String body;
        IconData icon;
        if (type == 'community_report_rejected' || type == 'report_rejected_reporter') {
          title = 'نتيجة البلاغ';
          body = text.trim().isEmpty ? 'راجعنا البلاغ، والتغريدة سليمة ولا يوجد عليها إجراء.' : text;
          icon = Icons.verified_user_rounded;
        } else if (type == 'community_report_accepted' || type == 'report_accepted_reporter') {
          title = 'تم قبول البلاغ';
          body = text.trim().isEmpty ? 'راجعنا البلاغ وتم حذف التغريدة.' : text;
          icon = Icons.gpp_good_rounded;
        } else if (type == 'report_accepted_owner') {
          title = 'تم حذف تغريدتك';
          body = text.trim().isEmpty ? 'تم حذف تغريدتك بعد قبول بلاغ عليها.' : text;
          icon = Icons.delete_forever_rounded;
        } else if (type == 'reply') {
          title = 'رد جديد على تغريدتك';
          body = '$name رد عليك: $text';
          icon = Icons.reply_rounded;
        } else if (type == 'repost') {
          title = 'إعادة نشر جديدة';
          body = '$name أعاد نشر تغريدتك';
          icon = Icons.repeat_rounded;
        } else {
          title = 'إشعار جديد';
          body = text.trim().isEmpty ? '$name أرسل لك إشعارًا' : text;
          icon = Icons.notifications_rounded;
        }
        notifications.add(_RespectNotification(
          id: 'post_event_${item['id'] ?? type}_$postId',
          title: title,
          body: body,
          icon: icon,
          time: _relativeTime(createdAt),
          createdAt: createdAt,
          unread: true,
          postId: postId,
        ));
      }
    } catch (_) { _scannerSafeIgnore(); }

    // إشعارات الستوري: لايكات وتعليقات على الستوري الخاصة بك.
    try {
      final storyEvents = await SupabaseService.getStoryNotificationsForUser(currentUsername);
      for (final item in storyEvents) {
        final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString()) ?? DateTime.now();
        final actorName = (item['actor_name'] ?? item['actor_username'] ?? 'مستخدم').toString();
        final type = (item['type'] ?? '').toString();
        final text = (item['text'] ?? '').toString();
        notifications.add(
          _RespectNotification(
            id: 'story_${item['id'] ?? item['story_id'] ?? createdAt.microsecondsSinceEpoch}',
            title: type == 'comment' ? 'تعليق جديد على الستوري' : 'إعجاب جديد على الستوري',
            body: type == 'comment' ? '$actorName علّق على الستوري: $text' : '$actorName أعجب بالستوري الخاص بك',
            icon: type == 'comment' ? Icons.mode_comment_rounded : Icons.favorite_rounded,
            time: _relativeTime(createdAt),
            createdAt: createdAt,
            unread: true,
          ),
        );
      }
    } catch (_) { _scannerSafeIgnore(); }

    // إشعارات المتابعة العالمية.
    try {
      final follows = await SupabaseService.getFollowNotificationsForUser(currentUsername);
      for (final item in follows) {
        final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString()) ?? DateTime.now();
        final name = (item['actor_name'] ?? item['actor_username'] ?? 'مستخدم').toString();
        notifications.add(
          _RespectNotification(
            id: 'follow_server_${item['id'] ?? item['actor_username']}',
            title: 'متابع جديد',
            body: '$name بدأ بمتابعتك',
            icon: Icons.person_add_alt_1_rounded,
            time: _relativeTime(createdAt),
            createdAt: createdAt,
            unread: true,
          ),
        );
      }
    } catch (_) { _scannerSafeIgnore(); }

    // إشعارات الاقتباس المحلية احتياط.
    try {
      final quoteRaw = prefs.getString('respect_local_quote_posts_v1');
      if (quoteRaw != null && quoteRaw.trim().isNotEmpty) {
        final decoded = jsonDecode(quoteRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final quoted = item['quotedPost'];
            if (quoted is! Map) continue;
            final quotedUsername = _cleanUsername((quoted['username'] ?? '').toString());
            final author = _cleanUsername((item['username'] ?? '').toString());
            if (quotedUsername != currentUsername || author == currentUsername) continue;
            final id = (item['id'] ?? '').toString();
            final name = (item['user'] ?? namesByUsername[author] ?? author).toString();
            notifications.add(_RespectNotification(
              id: 'quote_$id',
              title: 'تم اقتباس تغريدتك',
              body: '$name اقتبس تغريدتك: ${(item['text'] ?? '').toString()}',
              icon: Icons.format_quote_rounded,
              time: _timeFromId(id, fallbackText: (item['time'] ?? 'الآن').toString()),
              createdAt: _dateFromId(id),
              unread: true,
              postId: (quoted['id'] ?? '').toString(),
            ));
          }
        }
      }
    } catch (_) { _scannerSafeIgnore(); }


    // إشعارات الردود/إعادة النشر المحلية الاحتياطية.
    try {
      final eventsRaw = prefs.getString('respect_post_events_v1');
      if (eventsRaw != null && eventsRaw.trim().isNotEmpty) {
        final decoded = jsonDecode(eventsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final target = _cleanUsername((item['targetUsername'] ?? '').toString());
            if (target != currentUsername) continue;
            final type = (item['type'] ?? '').toString();
            final createdAt = DateTime.tryParse((item['createdAt'] ?? '').toString()) ?? DateTime.now();
            final name = (item['authorName'] ?? item['authorUsername'] ?? 'مستخدم').toString();
            final postId = (item['postId'] ?? '').toString();
            String title;
            String body;
            IconData icon;
            if (type == 'community_report_rejected' || type == 'report_rejected_reporter') {
              title = 'نتيجة البلاغ';
              body = (item['text'] ?? '').toString().trim().isEmpty
                  ? 'راجعنا البلاغ داخل ${(item['communityName'] ?? 'المجتمع').toString()}، والتغريدة سليمة ولا يوجد عليها إجراء.'
                  : (item['text'] ?? '').toString();
              icon = Icons.verified_user_rounded;
            } else if (type == 'community_report_accepted' || type == 'report_accepted_reporter') {
              title = 'تم قبول البلاغ';
              body = (item['text'] ?? '').toString().trim().isEmpty
                  ? 'راجعنا البلاغ وتم حذف التغريدة.'
                  : (item['text'] ?? '').toString();
              icon = Icons.gpp_good_rounded;
            } else if (type == 'report_accepted_owner') {
              title = 'تم حذف تغريدتك';
              body = (item['text'] ?? '').toString().trim().isEmpty
                  ? 'تم حذف تغريدتك بعد قبول بلاغ عليها.'
                  : (item['text'] ?? '').toString();
              icon = Icons.delete_forever_rounded;
            } else {
              title = type == 'reply' ? 'رد جديد على تغريدتك' : 'تفاعل جديد مع تغريدتك';
              body = type == 'reply' ? '$name رد عليك: ${(item['text'] ?? '').toString()}' : '$name تفاعل مع تغريدتك';
              icon = type == 'reply' ? Icons.reply_rounded : Icons.repeat_rounded;
            }
            notifications.add(_RespectNotification(
              id: 'event_${item['id'] ?? postId}',
              title: title,
              body: body,
              icon: icon,
              time: _relativeTime(createdAt),
              createdAt: createdAt,
              unread: true,
              postId: postId,
            ));
          }
        }
      }
    } catch (_) { _scannerSafeIgnore(); }


    // الإشعارات العامة من الإدارة: من السيرفر + نسخة محلية وصلت عبر FCM.
    try {
      final generalRows = await SupabaseService.getGeneralNotifications(limit: 80);
      for (final item in generalRows) {
        final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString()) ?? DateTime.now();
        final title = (item['title'] ?? 'Respect').toString();
        final body = (item['body'] ?? item['text'] ?? '').toString();
        notifications.add(_RespectNotification(
          id: 'general_server_${item['id'] ?? createdAt.microsecondsSinceEpoch}',
          title: title.trim().isEmpty ? 'Respect' : title,
          body: body.trim().isEmpty ? 'لديك إشعار عام جديد' : body,
          icon: Icons.campaign_rounded,
          time: _relativeTime(createdAt),
          createdAt: createdAt,
          unread: true,
        ));
      }
    } catch (_) { _scannerSafeIgnore(); }

    final generalRaw = prefs.getString(_generalNotificationsLocalKey);
    if (generalRaw != null && generalRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(generalRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString()) ?? DateTime.now();
            final title = (item['title'] ?? 'Respect').toString();
            final body = (item['body'] ?? item['text'] ?? '').toString();
            notifications.add(_RespectNotification(
              id: 'general_local_${item['id'] ?? createdAt.microsecondsSinceEpoch}',
              title: title.trim().isEmpty ? 'Respect' : title,
              body: body.trim().isEmpty ? 'لديك إشعار عام جديد' : body,
              icon: Icons.campaign_rounded,
              time: _relativeTime(createdAt),
              createdAt: createdAt,
              unread: true,
            ));
          }
        }
      } catch (_) { _scannerSafeIgnore(); }
    }

    final threadNames = await _threadNames(prefs);
    final lastReadRaw = prefs.getString('respect_dm_last_read_$currentUsername');
    final lastRead = DateTime.tryParse(lastReadRaw ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
    final messagesRaw = prefs.getString(_messagesKey);
    if (messagesRaw != null && messagesRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(messagesRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final receiver = _cleanUsername((item['receiverUsername'] ?? '').toString());
            final sender = _cleanUsername((item['senderUsername'] ?? '').toString());
            if (receiver != currentUsername || sender == currentUsername) continue;
            final createdAt = DateTime.tryParse((item['createdAt'] ?? '').toString()) ?? DateTime.now();
            final name = namesByUsername[sender] ?? threadNames[sender] ?? sender;
            notifications.add(
              _RespectNotification(
                id: 'dm_${item['id'] ?? createdAt.microsecondsSinceEpoch}',
                title: 'رسالة خاصة جديدة',
                body: '$name: ${(item['text'] ?? '').toString()}',
                icon: Icons.chat_bubble_rounded,
                time: _relativeTime(createdAt),
                createdAt: createdAt,
                unread: createdAt.isAfter(lastRead),
              ),
            );
          }
        }
      } catch (_) { _scannerSafeIgnore(); }
    }

    final seen = <String>{};
    final unique = <_RespectNotification>[];
    for (final n in notifications..sort((a, b) => b.createdAt.compareTo(a.createdAt))) {
      final key = '${n.id}_${n.postId ?? ''}';
      if (seen.add(key)) unique.add(n);
    }

    await prefs.setString('respect_notifications_last_seen_$currentUsername', DateTime.now().toIso8601String());

    if (!mounted) return;
    setState(() {
      _currentUsername = currentUsername;
      _currentName = currentName;
      _currentAvatarPath = currentAvatarPath;
      _namesByUsername = namesByUsername;
      _following = following;
      _items = unique.take(80).toList();
      _loading = false;
    });
  }

  Future<Map<String, String>> _threadNames(SharedPreferences prefs) async {
    final map = <String, String>{};
    final raw = prefs.getString(_threadsKey);
    if (raw == null || raw.trim().isEmpty) return map;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is! Map) continue;
          final username = _cleanUsername((item['peerUsername'] ?? '').toString());
          final name = (item['peerName'] ?? username).toString();
          map[username] = name;
        }
      }
    } catch (_) { _scannerSafeIgnore(); }
    return map;
  }

  DateTime _dateFromId(String id) {
    final numeric = int.tryParse(id);
    if (numeric != null && numeric > 1000000) {
      return DateTime.fromMicrosecondsSinceEpoch(numeric);
    }
    return DateTime.now();
  }

  String _timeFromId(String id, {required String fallbackText}) {
    final numeric = int.tryParse(id);
    if (numeric == null || numeric <= 1000000) return fallbackText;
    return _relativeTime(DateTime.fromMicrosecondsSinceEpoch(numeric));
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'قبل ${diff.inMinutes} د';
    if (diff.inHours < 24) return 'قبل ${diff.inHours} س';
    if (diff.inDays < 7) return 'قبل ${diff.inDays} يوم';
    return '${time.year}/${time.month.toString().padLeft(2, '0')}/${time.day.toString().padLeft(2, '0')}';
  }

  String _formatPostTime(String raw) {
    final date = DateTime.tryParse(raw);
    if (date == null) return raw.trim().isEmpty ? 'الآن' : raw;
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  ImageProvider? _avatarProvider(String? path) {
    final p = path?.trim();
    if (p == null || p.isEmpty) return null;
    if (p.startsWith('http://') || p.startsWith('https://')) return NetworkImage(p);
    final file = File(p);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  CityPost _postFromServerRow(Map<String, dynamic> row) {
    final imageUrl = (row['image_url'] ?? '').toString();
    final videoUrl = (row['video_url'] ?? '').toString();
    return CityPost(
      id: (row['id'] ?? '').toString(),
      user: (row['name'] ?? row['user'] ?? 'User').toString(),
      username: SupabaseService.displayUsername((row['username'] ?? '@user').toString()),
      text: (row['text'] ?? '').toString(),
      time: _formatPostTime((row['created_at'] ?? row['time'] ?? '').toString()),
      avatarPath: (row['avatar_url'] ?? row['avatarPath'])?.toString(),
      mediaPath: imageUrl.isNotEmpty ? imageUrl : (videoUrl.isNotEmpty ? videoUrl : null),
      mediaType: imageUrl.isNotEmpty ? CityMediaType.image : (videoUrl.isNotEmpty ? CityMediaType.video : null),
      likes: int.tryParse((row['likes'] ?? 0).toString()) ?? 0,
      reposts: int.tryParse((row['reposts'] ?? 0).toString()) ?? 0,
      shares: int.tryParse((row['shares'] ?? 0).toString()) ?? 0,
      views: int.tryParse((row['views'] ?? 0).toString()) ?? 0,
      replies: (row['replies'] is List)
          ? (row['replies'] as List)
          .whereType<Map>()
          .map((r) => CityReply.fromJson(r.map((k, v) => MapEntry(k.toString(), v))))
          .toList()
          : const <CityReply>[],
    );
  }


  Future<void> _openNotificationDetails(_RespectNotification notification) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.58,
          minChildSize: 0.35,
          maxChildSize: 0.92,
          expand: false,
          builder: (context, controller) {
            return Container(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBg : AppColors.lightBg,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
              ),
              child: SafeArea(
                top: false,
                child: ListView(
                  controller: controller,
                  children: [
                    Center(
                      child: Container(
                        width: 46,
                        height: 5,
                        decoration: BoxDecoration(
                          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 26,
                          backgroundColor: AppColors.purple.withValues(alpha: 0.18),
                          child: Icon(notification.icon, color: AppColors.purple),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(notification.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                              const SizedBox(height: 3),
                              Text(notification.time, style: TextStyle(color: muted, fontWeight: FontWeight.w700, fontSize: 12)),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'إغلاق',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                      ),
                      child: SelectableText(
                        notification.body.trim().isEmpty ? 'لا يوجد نص داخل هذا الإشعار' : notification.body,
                        textDirection: TextDirection.rtl,
                        style: const TextStyle(fontSize: 15, height: 1.65, fontWeight: FontWeight.w700),
                      ),
                    ),
                    if ((notification.postId ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _openPostFromNotification(notification);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.purple,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const Text('فتح التغريدة المرتبطة', style: TextStyle(fontWeight: FontWeight.w900)),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openPostFromNotification(_RespectNotification notification) async {
    final postId = notification.postId;
    if (postId == null || postId.trim().isEmpty) return;

    try {
      final row = await SupabaseService.getPostById(postId);
      if (row == null) {
        if (!mounted) return;
        NotificationService.showTopNotification('لم يتم العثور على التغريدة');
        return;
      }
      final post = _postFromServerRow(row);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RepliesScreen(
            post: post,
            currentName: _currentName,
            currentUsername: _currentUsername,
            currentAvatarPath: _currentAvatarPath,
            currentAvatarProvider: _avatarProvider(_currentAvatarPath),
            avatarProviderForPath: _avatarProvider,
            onLike: _toggleLike,        // 🔁 بدون () =>
            onFavorite: _toggleFavorite, // 🔁 بدون () =>
            onRepost: _repostPost,       // 🔁 بدون () =>
            onShare: _sharePost,         // 🔁 بدون () =>
            onChanged: () async {},
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('تعذر فتح التغريدة: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: null,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.purple))
          : RefreshIndicator(
        color: AppColors.purple,
        onRefresh: _loadNotifications,
        child: _items.isEmpty
            ? ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 130),
            Icon(Icons.notifications_none_rounded, size: 82, color: AppColors.purple.withValues(alpha: 0.9)),
            const SizedBox(height: 14),
            const Center(child: Text('لا توجد إشعارات بعد', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
            const SizedBox(height: 6),
            Text(
              'ستظهر هنا الرسائل، المنشورات، والردود أو التغريدات التي يتم ذكرك فيها بـ @.',
              textAlign: TextAlign.center,
              style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
            ),
          ],
        )
            : ListView.builder(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 96),
          itemCount: _items.length,
          itemBuilder: (context, i) {
            final n = _items[i];
            return InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: (n.postId ?? '').isEmpty ? () => _openNotificationDetails(n) : () => _openPostFromNotification(n),
              child: GlassCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CircleAvatar(
                        backgroundColor: AppColors.purple.withValues(alpha: 0.2),
                        child: Icon(n.icon, color: AppColors.purple),
                      ),
                      if (n.unread)
                        PositionedDirectional(
                          top: -2,
                          end: -2,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                          ),
                        ),
                    ],
                  ),
                  title: Text(n.title, style: const TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(n.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.35)),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(n.time, style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: 'عرض الإشعار كامل',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        onPressed: () => _openNotificationDetails(n),
                        icon: Icon(Icons.arrow_back_ios_new_rounded, size: 15, color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ).animate().fadeIn(delay: (45 * i).ms).slideX(begin: 0.04);
          },
        ),
      ),
    );
  }
}

class _RespectNotification {
  final String id;
  final String title;
  final String body;
  final IconData icon;
  final String time;
  final DateTime createdAt;
  final bool unread;
  final String? postId;

  const _RespectNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.icon,
    required this.time,
    required this.createdAt,
    required this.unread,
    this.postId,
  });
}
