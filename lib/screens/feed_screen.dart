// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, use_build_context_synchronously, unnecessary_this, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures, prefer_final_fields, unnecessary_type_check, unnecessary_non_null_assertion
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_video_player_plus/cached_video_player_plus.dart';
import 'package:video_compress/video_compress.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../services/supabase_service.dart';
import '../services/notification_service.dart';
import 'chat_screen.dart';
import 'search_screen.dart';

void _scannerSafeIgnore([Object? error, StackTrace? stackTrace]) {}


void _logIgnoredError(Object error, StackTrace stackTrace) {
  assert(() {
    assert(() { _scannerSafeIgnore(); return true; }());
    return true;
  }());
}



class _PreloadedFeedData {
  final List<Map<String, dynamic>> postRows;
  final List<Map<String, dynamic>> repostRows;
  final List<Map<String, dynamic>> extraRows;
  final DateTime createdAt;

  const _PreloadedFeedData({
    required this.postRows,
    required this.repostRows,
    required this.extraRows,
    required this.createdAt,
  });

  bool get isFresh => DateTime.now().difference(createdAt) < const Duration(seconds: 45);
}

class FeedScreen extends StatefulWidget {
  final VoidCallback? onMenuTap;
  final String? openPostId;
  final String? openReplyId;

  const FeedScreen({
    super.key,
    this.onMenuTap,
    this.openPostId,
    this.openReplyId,
  });

  static _PreloadedFeedData? _preloadedFeedData;

  /// يستدعى من السبلاش قبل فتح HomeScreen.
  /// الهدف: أول صفحة من الفيد تكون جاهزة في الذاكرة، وليس مجرد اتصال تجريبي بالسيرفر.
  static Future<void> preloadForSplash({int limit = 24}) async {
    try {
      final rows = await _preloadFetchPostPage(from: 0, to: limit - 1);
      final ids = rows
          .map((e) => (e['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      await _preloadMergeCounters(rows, ids);

      final repostRows = await _preloadFetchTimelineReposts();
      final currentIds = ids.toSet();
      final missingRepostIds = repostRows
          .map((e) => (e['post_id'] ?? '').toString())
          .where((id) => id.isNotEmpty && !currentIds.contains(id))
          .toSet()
          .toList();
      final extraRows = await _preloadFetchPostsByIds(missingRepostIds);
      await _preloadMergeCounters(extraRows, missingRepostIds);

      _preloadedFeedData = _PreloadedFeedData(
        postRows: rows,
        repostRows: repostRows,
        extraRows: extraRows,
        createdAt: DateTime.now(),
      );
    } catch (_) {
      _preloadedFeedData = null;
    }
  }

  static _PreloadedFeedData? _consumePreloadedFeedData() {
    final data = _preloadedFeedData;
    _preloadedFeedData = null;
    if (data == null || !data.isFresh) return null;
    return data;
  }

  static _PreloadedFeedData? _peekPreloadedFeedData() {
    final data = _preloadedFeedData;
    if (data == null || !data.isFresh) return null;
    return data;
  }

  static Map<String, dynamic> _preloadSafeRow(Map raw) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  static int _preloadSafeInt(dynamic value) => int.tryParse((value ?? 0).toString()) ?? 0;

  static Future<List<Map<String, dynamic>>> _preloadFetchPostPage({required int from, required int to}) async {
    try {
      final rows = await SupabaseService.client
          .from('posts')
          .select('id,username,name,user,text,created_at,time,avatar_url,avatarPath,image_url,video_url,voice_url,voicePath,voice_seconds,voiceSeconds,likes,reposts,shares,views,replies')
          .order('created_at', ascending: false)
          .range(from, to)
          .timeout(const Duration(seconds: 10));
      return List<Map<String, dynamic>>.from(rows.map((e) => _preloadSafeRow(e as Map)));
    } catch (_) {
      final rows = await SupabaseService.client
          .from('posts')
          .select()
          .order('created_at', ascending: false)
          .range(from, to)
          .timeout(const Duration(seconds: 10));
      return List<Map<String, dynamic>>.from(rows.map((e) => _preloadSafeRow(e as Map)));
    }
  }

  static Future<List<Map<String, dynamic>>> _preloadFetchPostsByIds(List<String> ids) async {
    final uniqueIds = ids.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (uniqueIds.isEmpty) return <Map<String, dynamic>>[];
    try {
      final rows = await SupabaseService.client
          .from('posts')
          .select('id,username,name,user,text,created_at,time,avatar_url,avatarPath,image_url,video_url,voice_url,voicePath,voice_seconds,voiceSeconds,likes,reposts,shares,views,replies')
          .inFilter('id', uniqueIds)
          .timeout(const Duration(seconds: 8));
      return List<Map<String, dynamic>>.from(rows.map((e) => _preloadSafeRow(e as Map)));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<List<Map<String, dynamic>>> _preloadFetchTimelineReposts() async {
    try {
      final current = await SupabaseService.currentUser();
      final me = SupabaseService.displayUsername(((current == null ? null : current['username']) ?? '@user').toString());
      final followed = <String>{};
      try {
        followed.addAll((await SupabaseService.getFollowingUsernames(me)).map(SupabaseService.displayUsername));
      } catch (e, st) { _logIgnoredError(e, st); }
      if (me != '@user') followed.add(me);
      if (followed.isEmpty) return <Map<String, dynamic>>[];

      final rows = await SupabaseService.client
          .from('post_reposts')
          .select('post_id,username,created_at')
          .inFilter('username', followed.toList())
          .order('created_at', ascending: false)
          .limit(80)
          .timeout(const Duration(seconds: 7));
      return List<Map<String, dynamic>>.from(rows.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<Map<String, int>> _preloadCountTable(String table, List<String> ids) async {
    if (ids.isEmpty) return <String, int>{};
    try {
      final rows = await SupabaseService.client
          .from(table)
          .select('post_id')
          .inFilter('post_id', ids)
          .timeout(const Duration(seconds: 6));
      final counts = <String, int>{};
      for (final raw in rows) {
        if (raw is! Map) continue;
        final id = (raw['post_id'] ?? '').toString();
        if (id.isEmpty) continue;
        counts[id] = (counts[id] ?? 0) + 1;
      }
      return counts;
    } catch (_) {
      return <String, int>{};
    }
  }

  static Future<void> _preloadMergeCounters(List<Map<String, dynamic>> rows, List<String> ids) async {
    if (rows.isEmpty || ids.isEmpty) return;
    final results = await Future.wait<Map<String, int>>([
      _preloadCountTable('post_likes', ids),
      _preloadCountTable('post_reposts', ids),
      _preloadCountTable('post_views', ids),
      _preloadCountTable('post_replies', ids),
    ]);
    final likeCounts = results[0];
    final repostCounts = results[1];
    final viewCounts = results[2];
    final replyCounts = results[3];
    for (final row in rows) {
      final id = (row['id'] ?? '').toString();
      if (id.isEmpty) continue;
      row['likes'] = likeCounts.containsKey(id) ? likeCounts[id] : _preloadSafeInt(row['likes']);
      row['reposts'] = repostCounts.containsKey(id) ? repostCounts[id] : _preloadSafeInt(row['reposts']);
      row['views'] = viewCounts.containsKey(id) ? viewCounts[id] : _preloadSafeInt(row['views']);
      row['reply_count'] = replyCounts.containsKey(id) ? replyCounts[id] : (row['replies'] is List ? (row['replies'] as List).length : _preloadSafeInt(row['reply_count'] ?? row['replyCount']));
      row['shares'] = _preloadSafeInt(row['shares']);
    }
  }

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  static const String _accountsKey = 'respect_accounts_v1';
  static const String _currentUserKey = 'respect_current_user_id';
  static const String _postsKey = 'respect_city_posts_v1';
  static const String _followingKey = 'respect_following_v1';
  static const String _communitiesKey = 'respect_communities_v1';
  static const String _postReportsKey = 'respect_post_reports_v1';
  static const String _mutedUsersKey = 'respect_muted_users_v1';
  static const String _localBlockedUsersKey = 'respect_local_blocked_users_v1';
  static const String _repostedPostsKey = 'respect_reposted_posts_v1';
  static const String _likedPostsKey = 'respect_liked_posts_v1';
  static const String _viewedPostsKey = 'respect_viewed_posts_v1';
  static const String _localQuotePostsKey = 'respect_local_quote_posts_v1';
  static const String _postStatsKey = 'respect_post_stats_v1';
  static const String _deletedPostsKey = 'respect_deleted_posts_v1';
  static const String _editedPostsKey = 'respect_edited_posts_v1';
  static const String _savedPostsKey = 'respect_saved_posts_v1';

  String _profileName = 'Nawaf RP';
  String _profileUsername = '@nawaf_city';
  String _profileBio = 'Respect App user';
  String? _profileImagePath;
  bool _profileVerified = false;
  int _profilePostMaxChars = SupabaseService.freePostMaxChars;
  final Map<String, List<Map<String, dynamic>>> _activeStoriesByUser = <String, List<Map<String, dynamic>>>{};
  Set<String> _seenStoryIds = <String>{};

  final List<CityPost> _posts = [];
  Map<String, List<String>> _following = {};
  final List<CityCommunity> _communities = [];
  Set<String> _mutedUsers = <String>{};
  Set<String> _localBlockedUsers = <String>{};
  final List<Map<String, String>> _refreshAvatars = <Map<String, String>>[];
  final Map<String, String> _communitySortModes = <String, String>{};
  bool _showRefreshAvatars = false;
  Timer? _hideRefreshAvatarsTimer;
  Timer? _loadMoreDebounceTimer;
  Set<String> _repostedPostIds = <String>{};
  Set<String> _repostedReplyIds = <String>{};
  Set<String> _likedPostIds = <String>{};
  Set<String> _viewedPostIds = <String>{};
  final Map<String, Map<String, int>> _localPostStats = <String, Map<String, int>>{};
  Set<String> _deletedPostIds = <String>{};
  Set<String> _savedPostIds = <String>{};
  Set<String> _postNotificationTargets = <String>{};
  bool _syncingSavedState = false;
  final Set<String> _pendingLikePostIds = <String>{};
  final Set<String> _pendingRepostPostIds = <String>{};
  final Set<String> _pendingSavePostIds = <String>{};
  final Set<String> _pendingViewPostIds = <String>{};
  final Map<String, String> _editedPostTexts = <String, String>{};
  final List<CityPost> _localQuotePosts = <CityPost>[];

  Map<String, String>? _cachedAvatarMap;
  final Map<String, Map<String, String>> _cachedRepostActors = <String, Map<String, String>>{};

  final ScrollController _forYouScrollController = ScrollController();
  final ScrollController _followingScrollController = ScrollController();
  RealtimeChannel? _replyNotificationChannel;
  StreamSubscription<String>? _respectAiDeletedPostSub;
  bool _openedInitialTarget = false;

  static const int _feedPageSize = 12;
  int _postsLoadedLimit = _feedPageSize;
  bool _loadingPosts = false;
  bool _loadingMorePosts = false;
  bool _hasMorePosts = true;

  bool _isNearBottom(ScrollController controller) {
    if (!controller.hasClients) return false;
    final position = controller.position;
    return position.pixels >= position.maxScrollExtent - 900;
  }

  void _onFeedScroll() {
    if (_loadingPosts || _loadingMorePosts || !_hasMorePosts) return;
    if (!_isNearBottom(_forYouScrollController) && !_isNearBottom(_followingScrollController)) return;

    // Debounce مهم جدًا أثناء السحب السريع حتى لا نطلق تحميلات متكررة وتعمل Drop Frames.
    if (_loadMoreDebounceTimer?.isActive == true) return;
    _loadMoreDebounceTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted) _loadMorePosts();
    });
  }

  bool _looksLikeMissingColumnError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('column') || msg.contains('replies') || msg.contains('voice_seconds') || msg.contains('avatar_url');
  }

  Map<String, dynamic> _safePostRow(Map raw) {
    final row = raw.map((key, value) => MapEntry(key.toString(), value));
    return row;
  }

  int _safeInt(dynamic value) => int.tryParse((value ?? 0).toString()) ?? 0;

  Future<Map<String, int>> _readInteractionCountsForPage({
    required String table,
    required List<String> postIds,
  }) async {
    if (postIds.isEmpty) return <String, int>{};

    try {
      final rows = await SupabaseService.client
          .from(table)
          .select('post_id')
          .inFilter('post_id', postIds);

      final counts = <String, int>{};
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = (row['post_id'] ?? '').toString();
        if (id.isEmpty) continue;
        counts[id] = (counts[id] ?? 0) + 1;
      }
      return counts;
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> _mergeGlobalPostCounters(List<Map<String, dynamic>> posts) async {
    final ids = posts
        .map((p) => (p['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return;

    final likeCounts = await _readInteractionCountsForPage(table: 'post_likes', postIds: ids);
    final repostCounts = await _readInteractionCountsForPage(table: 'post_reposts', postIds: ids);
    final viewCounts = await _readInteractionCountsForPage(table: 'post_views', postIds: ids);
    final replyCounts = await _readInteractionCountsForPage(table: 'post_replies', postIds: ids);

    for (final post in posts) {
      final id = (post['id'] ?? '').toString();
      if (id.isEmpty) continue;

      // مهم جدًا:
      // حالة القلب الأحمر تأتي من post_likes، لذلك لازم العدد أيضًا يأتي من نفس الجدول.
      // سابقًا الفيد كان يقرأ posts.likes فقط، فإذا العمود صار 0 يبقى القلب أحمر لكن العدد يختفي.
      post['likes'] = likeCounts.containsKey(id) ? likeCounts[id] : _safeInt(post['likes']);
      post['reposts'] = repostCounts.containsKey(id) ? repostCounts[id] : _safeInt(post['reposts']);
      post['views'] = viewCounts.containsKey(id) ? viewCounts[id] : _safeInt(post['views']);
      post['reply_count'] = replyCounts.containsKey(id) ? replyCounts[id] : (post['replies'] is List ? (post['replies'] as List).length : _safeInt(post['reply_count'] ?? post['replyCount']));
      post['shares'] = _safeInt(post['shares']);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchPostPage({required int from, required int to}) async {
    try {
      final rows = await SupabaseService.client
          .from('posts')
          .select('id,username,name,user,text,created_at,time,avatar_url,avatarPath,image_url,video_url,voice_url,voicePath,voice_seconds,voiceSeconds,likes,reposts,shares,views,replies')
          .order('created_at', ascending: false)
          .range(from, to);
      final posts = List<Map<String, dynamic>>.from(
        rows.map((e) => _safePostRow(e as Map)),
      );
      await _mergeGlobalPostCounters(posts);
      return posts;
    } catch (e) {
      // بعض قواعد البيانات القديمة لا تحتوي كل الأعمدة، لذلك نرجع لتحديد عام مع نفس pagination.
      if (!_looksLikeMissingColumnError(e)) rethrow;
      final rows = await SupabaseService.client
          .from('posts')
          .select()
          .order('created_at', ascending: false)
          .range(from, to);
      final posts = List<Map<String, dynamic>>.from(
        rows.map((e) => _safePostRow(e as Map)),
      );
      await _mergeGlobalPostCounters(posts);
      return posts;
    }
  }

  Future<List<Map<String, dynamic>>> _fetchRepostRowsForTimeline() async {
    final me = SupabaseService.displayUsername(_profileUsername);
    final followed = (_following[me] ?? const <String>[])
        .map(SupabaseService.displayUsername)
        .where((u) => u != '@user')
        .toSet();
    // نضيف حسابي أيضًا حتى أشوف إعادة النشر الخاصة بي فورًا،
    // وأي شخص يتابعني سيجلبها عنده لأن اسمي سيكون ضمن followed.
    if (me != '@user') followed.add(me);
    final timelineUsers = followed.toList();

    if (timelineUsers.isEmpty) return <Map<String, dynamic>>[];

    try {
      final rows = await SupabaseService.client
          .from('post_reposts')
          .select('post_id,username,created_at')
          .inFilter('username', timelineUsers)
          .order('created_at', ascending: false)
          .limit(120);

      return List<Map<String, dynamic>>.from(
        rows.map((e) => Map<String, dynamic>.from(e as Map)),
      );
    } catch (_) {
      try {
        // احتياط لو جدول post_reposts قديم وما فيه created_at.
        final rows = await SupabaseService.client
            .from('post_reposts')
            .select('post_id,username')
            .inFilter('username', timelineUsers)
            .limit(120);
        return List<Map<String, dynamic>>.from(
          rows.map((e) => Map<String, dynamic>.from(e as Map)),
        );
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    }
  }


  List<String> _timelineUsersForReposts() {
    final me = SupabaseService.displayUsername(_profileUsername);
    final users = (_following[me] ?? const <String>[])
        .map(SupabaseService.displayUsername)
        .where((u) => u != '@user')
        .toSet();
    if (me != '@user') users.add(me);
    return users.toList();
  }

  Future<List<Map<String, dynamic>>> _fetchReplyRepostRowsForTimeline() async {
    try {
      return await SupabaseService.getReplyRepostsForTimeline(_timelineUsersForReposts());
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<List<CityPost>> _buildReplyRepostTimelinePosts(
      List<Map<String, dynamic>> replyRepostRows,
      Map<String, String> avatarMap,
      ) async {
    if (replyRepostRows.isEmpty) return <CityPost>[];

    final replyIds = replyRepostRows
        .map((e) => (e['reply_id'] ?? '').toString())
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .toList();

    final replyRows = await SupabaseService.getRepliesByIds(
      replyIds,
      currentUsername: _profileUsername,
    );

    final replyById = <String, CityReply>{
      for (final row in replyRows)
        if ((row['id'] ?? '').toString().trim().isNotEmpty)
          (row['id'] ?? '').toString(): CityReply.fromJson(row),
    };

    final actorInfo = await _loadRepostActors(
      replyRepostRows.map((row) => {
        'username': row['username'],
        'post_id': row['reply_id'],
        'created_at': row['created_at'],
      }).toList(),
    );

    final out = <CityPost>[];
    final seen = <String>{};

    for (final row in replyRepostRows) {
      final replyId = (row['reply_id'] ?? '').toString();
      final actor = SupabaseService.displayUsername((row['username'] ?? '').toString());
      final key = '${actor}_reply_$replyId';
      if (replyId.isEmpty || actor == '@user' || seen.contains(key)) continue;
      seen.add(key);

      final reply = replyById[replyId];
      if (reply == null) continue;

      final rawCreated = (row['created_at'] ?? '').toString();
      final parsedCreated = DateTime.tryParse(rawCreated);
      final info = actorInfo[actor] ?? {'name': actor, 'avatar': ''};

      // نحول الرد إلى كرت في الفيد حتى يظهر بالضبط مثل إعادة نشر التغريدة.
      // نخلي الـ id هو id الرد حتى لا تضيع حالة إعادة النشر الخاصة بالرد.
      final replyAsPost = CityPost(
        id: reply.id,
        user: reply.user,
        username: reply.username,
        text: reply.text,
        time: reply.time,
        avatarPath: reply.avatarPath ?? avatarMap[SupabaseService.displayUsername(reply.username)],
        mediaPath: reply.mediaPath,
        mediaType: reply.mediaType,
        voicePath: reply.voicePath,
        voiceSeconds: reply.voiceSeconds,
        likes: reply.likes,
        reposts: reply.reposts,
        shares: reply.shares,
        views: reply.views,
        replyCount: 0,
        isLiked: reply.isLiked,
        isFavorite: reply.isFavorite,
        isReposted: _repostedReplyIds.contains(reply.id) || reply.isReposted,
        timelineSortMillis: reply.sortMillis,
      );

      out.add(replyAsPost.copyAsRepost(
        repostedByUsername: actor,
        repostedByName: (info['name'] ?? actor).trim().isEmpty ? actor : (info['name'] ?? actor),
        repostedByAvatarPath: (info['avatar'] ?? '').trim().isEmpty ? null : info['avatar'],
        repostedAt: _formatPostTime(rawCreated),
        timelineSortMillis: parsedCreated?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
      ));
    }

    return out;
  }

  Future<List<Map<String, dynamic>>> _fetchPostsByIds(List<String> ids) async {
    final uniqueIds = ids.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (uniqueIds.isEmpty) return <Map<String, dynamic>>[];

    try {
      final rows = await SupabaseService.client
          .from('posts')
          .select('id,username,name,user,text,created_at,time,avatar_url,avatarPath,image_url,video_url,voice_url,voicePath,voice_seconds,voiceSeconds,likes,reposts,shares,views,replies')
          .inFilter('id', uniqueIds);
      final posts = List<Map<String, dynamic>>.from(
        rows.map((e) => _safePostRow(e as Map)),
      );
      await _mergeGlobalPostCounters(posts);
      return posts;
    } catch (e) {
      if (!_looksLikeMissingColumnError(e)) return <Map<String, dynamic>>[];
      try {
        final rows = await SupabaseService.client
            .from('posts')
            .select()
            .inFilter('id', uniqueIds);
        final posts = List<Map<String, dynamic>>.from(
          rows.map((e) => _safePostRow(e as Map)),
        );
        await _mergeGlobalPostCounters(posts);
        return posts;
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    }
  }

  Future<Map<String, Map<String, String>>> _loadRepostActors(List<Map<String, dynamic>> repostRows) async {
    final actors = repostRows
        .map((r) => SupabaseService.displayUsername((r['username'] ?? '').toString()))
        .where((u) => u != '@user')
        .toSet()
        .toList();

    final out = <String, Map<String, String>>{};
    final missing = <String>[];
    for (final actor in actors) {
      final cached = _cachedRepostActors[actor];
      if (cached != null) {
        out[actor] = cached;
      } else {
        missing.add(actor);
      }
    }

    // جلب بيانات أصحاب الريبوست بالتوازي بدل await داخل loop حتى لا يعلّق الفيد.
    final fetched = await Future.wait(missing.map((actor) async {
      var name = actor;
      String? avatar;
      try {
        final user = await SupabaseService.getUserByUsername(actor);
        if (user != null) {
          name = (user['name'] ?? user['profileName'] ?? actor).toString();
          avatar = (user['avatar_url'] ?? user['imagePath'] ?? user['profileImagePath'])?.toString();
        }
      } catch (e, st) { _logIgnoredError(e, st); }
      final data = <String, String>{
        'name': name.trim().isEmpty ? actor : name,
        'avatar': avatar?.trim() ?? '',
      };
      return MapEntry(actor, data);
    }));

    for (final entry in fetched) {
      _cachedRepostActors[entry.key] = entry.value;
      out[entry.key] = entry.value;
    }
    return out;
  }

  int _timelineSortValue(CityPost post) {
    if (post.timelineSortMillis != null) return post.timelineSortMillis!;
    final parsed = DateTime.tryParse(post.time);
    if (parsed != null) return parsed.millisecondsSinceEpoch;
    return int.tryParse(post.id.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  bool _publishingPost = false;
  double _publishProgress = 0.0;
  String _publishStatus = '';

  void _setPublishProgress(double value, String status) {
    if (!mounted) return;
    setState(() {
      _publishingPost = true;
      _publishProgress = value.clamp(0.0, 1.0);
      _publishStatus = status;
    });
  }

  void _hidePublishProgress() {
    if (!mounted) return;
    setState(() {
      _publishingPost = false;
      _publishProgress = 0.0;
      _publishStatus = '';
    });
  }

  @override
  void initState() {
    super.initState();
    _paintPreloadedFeedBeforeFirstFrame();
    _forYouScrollController.addListener(_onFeedScroll);
    _followingScrollController.addListener(_onFeedScroll);
    _respectAiDeletedPostSub = SupabaseService.respectAiDeletedPostStream.listen(_hideRespectAiDeletedPostImmediately);
    _loadInitialData();
  }

  void _hideRespectAiDeletedPostImmediately(String postId) {
    final id = postId.trim();
    if (id.isEmpty) return;

    _deletedPostIds.add(id);

    if (!mounted) return;
    var removed = false;
    setState(() {
      final before = _posts.length;
      _posts.removeWhere((post) => post.id == id || post.quotedPost?.id == id);
      removed = before != _posts.length;
    });

    unawaited(_saveLocalPostState());
    unawaited(_savePosts());

    if (removed) {
      NotificationService.showTopNotification(
        'تم حذف التغريدة بواسطة Respect AI',
        title: 'مراجعة المحتوى',
        icon: Icons.auto_delete_rounded,
        accentColor: AppColors.danger,
      );
    }
  }

  void _paintPreloadedFeedBeforeFirstFrame() {
    // هذا هو الجزء المهم: لا ننتظر _loadInitialData بعد فتح HomeScreen.
    // طالما السبلاش جهز أول صفحة من الفيد، نرسمها مباشرة قبل أول frame
    // ثم نكمل المزامنة بالخلفية بدون شاشة فارغة.
    final preloaded = FeedScreen._peekPreloadedFeedData();
    if (preloaded == null) return;

    final readyPosts = _buildPostsFromPreloadedData(preloaded);
    if (readyPosts.isEmpty) return;

    _posts
      ..clear()
      ..addAll(readyPosts);
    _refreshAvatars
      ..clear()
      ..addAll(_latestPostAvatars(readyPosts));
    _postsLoadedLimit = preloaded.postRows.length;
    _hasMorePosts = preloaded.postRows.length >= _feedPageSize;
    _loadingPosts = false;
    _loadingMorePosts = false;
  }

  List<CityPost> _buildPostsFromPreloadedData(_PreloadedFeedData preloaded) {
    final avatarMap = <String, String>{};
    final rows = preloaded.postRows;
    final repostRows = preloaded.repostRows;
    final currentIds = rows
        .map((e) => (e['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();

    final allServerRows = <Map<String, dynamic>>[
      ...rows,
      ...preloaded.extraRows.where((e) => !currentIds.contains((e['id'] ?? '').toString())),
    ];

    final loaded = rows
        .where((e) => !_deletedPostIds.contains((e['id'] ?? '').toString()))
        .map((e) => _postFromServerRow(e, avatarMap))
        .toList();

    final postById = <String, CityPost>{
      for (final row in allServerRows)
        if (!_deletedPostIds.contains((row['id'] ?? '').toString()))
          (row['id'] ?? '').toString(): _postFromServerRow(row, avatarMap),
    };

    final repostTimelinePosts = <CityPost>[];
    final seenRepostKeys = <String>{};
    for (final row in repostRows) {
      final postId = (row['post_id'] ?? '').toString();
      final actor = SupabaseService.displayUsername((row['username'] ?? '').toString());
      final key = '${actor}_$postId';
      if (postId.isEmpty || actor == '@user' || seenRepostKeys.contains(key)) continue;
      seenRepostKeys.add(key);

      final original = postById[postId];
      if (original == null) continue;

      final rawCreated = (row['created_at'] ?? '').toString();
      final parsedCreated = DateTime.tryParse(rawCreated);
      repostTimelinePosts.add(original.copyAsRepost(
        repostedByUsername: actor,
        repostedByName: actor,
        repostedAt: _formatPostTime(rawCreated),
        timelineSortMillis: parsedCreated?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
      ));
    }

    return <CityPost>[
      ..._localQuotePosts.where((p) => !_deletedPostIds.contains(p.id)).map(_applyLocalState),
      ...repostTimelinePosts,
      ...loaded,
    ]..sort((a, b) => _timelineSortValue(b).compareTo(_timelineSortValue(a)));
  }

  @override
  void dispose() {
    _replyNotificationChannel?.unsubscribe();
    _respectAiDeletedPostSub?.cancel();
    _hideRefreshAvatarsTimer?.cancel();
    _loadMoreDebounceTimer?.cancel();
    _forYouScrollController.removeListener(_onFeedScroll);
    _followingScrollController.removeListener(_onFeedScroll);
    _forYouScrollController.dispose();
    _followingScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    await _loadProfile();
    await _loadLocalPostState();
    // المتابعات لازم تنقرأ قبل الفيد حتى نقدر نظهر إعادة النشر من الأشخاص الذين أتابعهم مثل تويتر.
    await _loadFollowing();
    await _loadPosts();
    await _subscribeReplyNotifications();
    await _openInitialTargetPostIfAny();
    await _loadPostNotificationTargets();
    await _loadCommunities();
    await _loadLocalModeration();
    unawaited(_createRespectAiDailyPostSilently());
  }

  Future<void> _createRespectAiDailyPostSilently() async {
    try {
      final post = await SupabaseService.createRespectAiDailyPostIfNeeded();
      if (post != null && mounted) {
        await _loadPosts();
        NotificationService.showTopSuccess('Respect AI نشر سؤال اليوم من سؤال متكرر');
      }
    } catch (e) {
      assert(() { _scannerSafeIgnore(); return true; }());
    }
  }

  CityPost? _findLoadedPost(String postId) {
    for (final post in _posts) {
      if (post.id == postId) return post;
      if (post.quotedPost?.id == postId) return post.quotedPost;
    }
    return null;
  }

  Future<CityPost?> _loadPostForNavigation(String postId) async {
    final loaded = _findLoadedPost(postId);
    if (loaded != null) return loaded;
    try {
      final row = await SupabaseService.getPostById(postId);
      if (row == null) return null;
      final avatarMap = _cachedAvatarMap ??= await _localAvatarMap();
      final post = _postFromServerRow(row, avatarMap);
      if (mounted && !_posts.any((p) => p.id == post.id)) {
        setState(() => _posts.insert(0, post));
      }
      return post;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openInitialTargetPostIfAny() async {
    final postId = widget.openPostId;
    if (_openedInitialTarget || postId == null || postId.trim().isEmpty) return;
    _openedInitialTarget = true;
    final post = await _loadPostForNavigation(postId.trim());
    if (post == null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _openReplies(post);
    });
  }

  Future<void> _subscribeReplyNotifications() async {
    final me = SupabaseService.displayUsername(_profileUsername);
    if (me == '@user') return;
    try {
      await _replyNotificationChannel?.unsubscribe();
    } catch (e, st) { _logIgnoredError(e, st); }
    _replyNotificationChannel = SupabaseService.client
        .channel('respect_reply_notifications_${me}_${DateTime.now().microsecondsSinceEpoch}')
        .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'post_replies',
      callback: (payload) {
        unawaited(_handleIncomingReplyNotification(Map<String, dynamic>.from(payload.newRecord)));
      },
    )
        .subscribe();
  }

  bool _isReplyTargetingMe(Map<String, dynamic> row, CityPost post) {
    final me = SupabaseService.displayUsername(_profileUsername);
    final postOwner = SupabaseService.displayUsername(post.username);
    if (postOwner == me) return true;

    final parent = (row['parent_user'] ?? row['parentUser'] ?? '').toString().trim().toLowerCase();
    if (parent.isEmpty) return false;
    final myName = _profileName.trim().toLowerCase();
    final myUsername = me.trim().toLowerCase();
    if (parent == myName || parent == myUsername || parent == myUsername.replaceFirst('@', '')) return true;

    return post.replies.any((reply) {
      final replyByMe = SupabaseService.displayUsername(reply.username) == me;
      return replyByMe && parent == reply.user.trim().toLowerCase();
    });
  }

  Future<void> _handleIncomingReplyNotification(Map<String, dynamic> row) async {
    final postId = (row['post_id'] ?? row['postId'] ?? '').toString();
    if (postId.trim().isEmpty) return;

    final authorUsername = SupabaseService.displayUsername((row['author_username'] ?? row['username'] ?? '').toString());
    final me = SupabaseService.displayUsername(_profileUsername);
    if (authorUsername == me) return;

    final post = await _loadPostForNavigation(postId);
    if (!mounted || post == null) return;

    try {
      final freshReplies = await SupabaseService.getPostReplies(postId, currentUsername: _profileUsername);
      post.replies
        ..clear()
        ..addAll(_sortedReplies(freshReplies.map(CityReply.fromJson)));
      post.replyCount = post.replies.length;
    } catch (e, st) { _logIgnoredError(e, st); }

    if (!_isReplyTargetingMe(row, post)) return;

    final replyId = (row['id'] ?? '').toString();
    final authorName = (row['author_name'] ?? row['user'] ?? authorUsername).toString();
    final text = (row['text'] ?? '').toString();

    NotificationService.showReplyInAppNotification(
      replyId: replyId,
      postId: postId,
      authorUsername: authorUsername,
      authorName: authorName,
      text: text,
    );

    if (mounted) setState(() {});
  }


  Future<Set<String>> _readStringSet(SharedPreferences prefs, String key) async {
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toSet();
    } catch (e, st) { _logIgnoredError(e, st); }
    return <String>{};
  }

  Future<void> _loadLocalPostState() async {
    final prefs = await SharedPreferences.getInstance();
    _repostedPostIds = await _readStringSet(prefs, _repostedPostsKey);
    _likedPostIds = await _readStringSet(prefs, _likedPostsKey);
    _viewedPostIds = await _readStringSet(prefs, _viewedPostsKey);
    _deletedPostIds = await _readStringSet(prefs, _deletedPostsKey);
    _savedPostIds = await _readSavedPostIds(prefs);

    _editedPostTexts.clear();
    final editsRaw = prefs.getString(_editedPostsKey);
    if (editsRaw != null && editsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(editsRaw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            final id = key.toString();
            final text = value?.toString() ?? '';
            if (id.isNotEmpty && text.trim().isNotEmpty) _editedPostTexts[id] = text;
          });
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    _localPostStats.clear();
    final statsRaw = prefs.getString(_postStatsKey);
    if (statsRaw != null && statsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(statsRaw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is Map) {
              _localPostStats[key.toString()] = {
                'likes': int.tryParse((value['likes'] ?? 0).toString()) ?? 0,
                'reposts': int.tryParse((value['reposts'] ?? 0).toString()) ?? 0,
                'shares': int.tryParse((value['shares'] ?? 0).toString()) ?? 0,
                'views': int.tryParse((value['views'] ?? 0).toString()) ?? 0,
              };
            }
          });
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    _localQuotePosts.clear();
    final quoteRaw = prefs.getString(_localQuotePostsKey);
    if (quoteRaw != null && quoteRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(quoteRaw);
        if (decoded is List) {
          _localQuotePosts.addAll(decoded.whereType<Map>().map((e) => CityPost.fromJson(e.map((k, v) => MapEntry(k.toString(), v)))));
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    // مزامنة حالة اللايك وإعادة النشر من السيرفر حسب المستخدم الحالي.
    try {
      final serverLiked = await SupabaseService.getUserLikedPostIds(_profileUsername);
      final serverReposted = await SupabaseService.getUserRepostedPostIds(_profileUsername);
      final serverSaved = await SupabaseService.getUserSavedPostIds(_profileUsername);
      final serverReplyReposted = await SupabaseService.getUserRepostedReplyIds(_profileUsername);
      _likedPostIds
        ..clear()
        ..addAll(serverLiked);
      _repostedPostIds
        ..clear()
        ..addAll(serverReposted);
      if (serverSaved.isNotEmpty) {
        _savedPostIds
          ..clear()
          ..addAll(serverSaved);
      }
      _repostedReplyIds
        ..clear()
        ..addAll(serverReplyReposted);
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _saveLocalPostState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_repostedPostsKey, jsonEncode(_repostedPostIds.toList()));
    await prefs.setString(_likedPostsKey, jsonEncode(_likedPostIds.toList()));
    await prefs.setString(_viewedPostsKey, jsonEncode(_viewedPostIds.toList()));
    await prefs.setString(_postStatsKey, jsonEncode(_localPostStats));
    await prefs.setString(_deletedPostsKey, jsonEncode(_deletedPostIds.toList()));
    await prefs.setString(_editedPostsKey, jsonEncode(_editedPostTexts));
    await _writeSavedPostIds(prefs);
    await prefs.setString(_localQuotePostsKey, jsonEncode(_localQuotePosts.where((p) => !_deletedPostIds.contains(p.id)).map((p) => p.toJson()).toList()));
  }

  CityPost _applyLocalState(CityPost post) {
    // CityPost.text معرف final، لذلك لا نعدله مباشرة.
    // إذا فيه تعديل محلي محفوظ، ننشئ نسخة جديدة بنفس بيانات التغريدة ونبدل النص فقط.
    final editedText = _editedPostTexts[post.id];
    final nextPost = editedText == null
        ? post
        : CityPost(
      id: post.id,
      user: post.user,
      username: post.username,
      text: editedText,
      time: post.time,
      avatarPath: post.avatarPath,
      mediaPath: post.mediaPath,
      mediaType: post.mediaType,
      voicePath: post.voicePath,
      voiceSeconds: post.voiceSeconds,
      replies: List<CityReply>.from(post.replies),
      likes: post.likes,
      reposts: post.reposts,
      shares: post.shares,
      views: post.views,
      replyCount: post.replyCount,
      isLiked: post.isLiked,
      isFavorite: post.isFavorite,
      isReposted: post.isReposted,
      quotedPost: post.quotedPost,
      repostedByUsername: post.repostedByUsername,
      repostedByName: post.repostedByName,
      repostedByAvatarPath: post.repostedByAvatarPath,
      repostedAt: post.repostedAt,
      timelineSortMillis: post.timelineSortMillis,
      authorVerified: post.authorVerified,
    );

    nextPost.isLiked = _likedPostIds.contains(nextPost.id);
    nextPost.isFavorite = _savedPostIds.contains(nextPost.id);
    nextPost.isReposted = _repostedPostIds.contains(nextPost.id);
    return nextPost;
  }

  void _rememberStats(CityPost post) {
    _localPostStats[post.id] = {
      'likes': post.likes,
      'reposts': post.reposts,
      'shares': post.shares,
      'views': post.views,
    };
  }

  void _updateLoadedPostInteraction(
      String postId, {
        bool? isLiked,
        bool? isReposted,
        bool? isFavorite,
        int? likes,
        int? reposts,
        int? shares,
        int? views,
      }) {
    void apply(CityPost p) {
      if (p.id == postId) {
        if (isLiked != null) p.isLiked = isLiked;
        if (isReposted != null) p.isReposted = isReposted;
        if (isFavorite != null) p.isFavorite = isFavorite;
        if (likes != null) p.likes = likes;
        if (reposts != null) p.reposts = reposts;
        if (shares != null) p.shares = shares;
        if (views != null) p.views = views;
        _rememberStats(p);
      }
      final q = p.quotedPost;
      if (q != null && q.id == postId) {
        if (isLiked != null) q.isLiked = isLiked;
        if (isReposted != null) q.isReposted = isReposted;
        if (isFavorite != null) q.isFavorite = isFavorite;
        if (likes != null) q.likes = likes;
        if (reposts != null) q.reposts = reposts;
        if (shares != null) q.shares = shares;
        if (views != null) q.views = views;
        _rememberStats(q);
      }
    }

    for (final p in _posts) {
      apply(p);
    }
    for (final p in _localQuotePosts) {
      apply(p);
    }
  }


  Future<Map<String, String>> _localAvatarMap() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, String>{};

    String avatarKey(String value) => SupabaseService.displayUsername(value);

    void addUser(Map item) {
      final username = (item['username'] ?? item['id'] ?? '').toString();
      final key = avatarKey(username);
      final avatar = (item['avatar_url'] ?? item['imagePath'] ?? item['profileImagePath'] ?? '').toString().trim();

      // مهم: لا نربط صورة الحساب الحالي بأي مستخدم ثاني.
      // كل صورة تُحفظ وتُقرأ حسب username فقط.
      if (key.isNotEmpty && avatar.isNotEmpty) {
        out[key] = avatar;
      }
    }

    for (final key in const [_accountsKey, 'respect_users_map']) {
      final raw = prefs.getString(key);
      if (raw == null || raw.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded.whereType<Map>()) addUser(item);
        } else if (decoded is Map) {
          for (final item in decoded.values.whereType<Map>()) addUser(item);
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    return out;
  }

  CityPost _postFromServerRow(Map<String, dynamic> e, Map<String, String> avatarMap) {
    final imageUrl = (e['image_url'] ?? '').toString();
    final videoUrl = (e['video_url'] ?? '').toString();
    final voiceUrl = (e['voice_url'] ?? e['voicePath'] ?? '').toString();
    final postId = (e['id'] ?? DateTime.now().microsecondsSinceEpoch).toString();
    final post = CityPost(
      id: postId,
      user: (e['name'] ?? e['user'] ?? 'User').toString(),
      username: SupabaseService.displayUsername((e['username'] ?? '@user').toString()),
      text: _editedPostTexts[postId] ?? (e['text'] ?? '').toString(),
      time: _formatPostTime((e['created_at'] ?? e['time'] ?? '').toString()),
      avatarPath: ((e['avatar_url'] ?? e['avatarPath'])?.toString().trim().isNotEmpty == true
          ? (e['avatar_url'] ?? e['avatarPath'])?.toString().trim()
          : avatarMap[SupabaseService.displayUsername((e['username'] ?? '@user').toString())]),
      mediaPath: imageUrl.isNotEmpty ? imageUrl : (videoUrl.isNotEmpty ? videoUrl : null),
      mediaType: imageUrl.isNotEmpty ? CityMediaType.image : (videoUrl.isNotEmpty ? CityMediaType.video : null),
      likes: int.tryParse((e['likes'] ?? 0).toString()) ?? 0,
      reposts: int.tryParse((e['reposts'] ?? 0).toString()) ?? 0,
      shares: int.tryParse((e['shares'] ?? 0).toString()) ?? 0,
      views: int.tryParse((e['views'] ?? 0).toString()) ?? 0,
      replyCount: int.tryParse((e['reply_count'] ?? e['replyCount'] ?? '').toString()) ?? (e['replies'] is List ? (e['replies'] as List).length : 0),
      replies: (e['replies'] is List)
          ? (e['replies'] as List)
          .whereType<Map>()
          .map((r) => CityReply.fromJson(r.map((k, v) => MapEntry(k.toString(), v))))
          .toList()
          : <CityReply>[],
      voicePath: voiceUrl.trim().isNotEmpty ? voiceUrl.trim() : null,
      voiceSeconds: int.tryParse((e['voice_seconds'] ?? e['voiceSeconds'] ?? 0).toString()) ?? 0,
      isReposted: _repostedPostIds.contains(postId),
      timelineSortMillis: DateTime.tryParse((e['created_at'] ?? e['time'] ?? '').toString())?.toLocal().millisecondsSinceEpoch,
      authorVerified: SupabaseService.truthy(e['author_verified'] ?? e['authorVerified'] ?? e['is_verified'] ?? e['verified']),
    );
    return _applyLocalState(post);
  }

  Future<void> _loadPosts({bool reset = true}) async {
    if (_loadingPosts) return;
    _loadingPosts = true;
    try {
      if (reset) {
        _postsLoadedLimit = _feedPageSize;
        _hasMorePosts = true;
        if (mounted) setState(() => _loadingMorePosts = false);
      }

      final preloaded = reset ? FeedScreen._consumePreloadedFeedData() : null;
      final avatarMap = _cachedAvatarMap ??= await _localAvatarMap();
      final rows = preloaded?.postRows ?? await _fetchPostPage(from: 0, to: _postsLoadedLimit - 1);

      final repostRows = preloaded?.repostRows ?? await _fetchRepostRowsForTimeline();
      final replyRepostRows = await _fetchReplyRepostRowsForTimeline();
      final currentIds = rows
          .map((e) => (e['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      final missingRepostIds = repostRows
          .map((e) => (e['post_id'] ?? '').toString())
          .where((id) => id.isNotEmpty && !currentIds.contains(id))
          .toSet()
          .toList();
      final extraRows = preloaded?.extraRows ?? await _fetchPostsByIds(missingRepostIds);
      final allServerRows = <Map<String, dynamic>>[
        ...rows,
        ...extraRows.where((e) => !currentIds.contains((e['id'] ?? '').toString())),
      ];

      final loaded = rows
          .where((e) => !_deletedPostIds.contains((e['id'] ?? '').toString()))
          .map((e) => _postFromServerRow(e, avatarMap))
          .toList();

      final postById = <String, CityPost>{
        for (final row in allServerRows)
          if (!_deletedPostIds.contains((row['id'] ?? '').toString()))
            (row['id'] ?? '').toString(): _postFromServerRow(row, avatarMap),
      };

      final actorInfo = await _loadRepostActors(repostRows);
      final replyRepostTimelinePosts = await _buildReplyRepostTimelinePosts(replyRepostRows, avatarMap);
      final repostTimelinePosts = <CityPost>[];
      final seenRepostKeys = <String>{};
      for (final row in repostRows) {
        final postId = (row['post_id'] ?? '').toString();
        final actor = SupabaseService.displayUsername((row['username'] ?? '').toString());
        final key = '${actor}_$postId';
        if (postId.isEmpty || actor == '@user' || seenRepostKeys.contains(key)) continue;
        seenRepostKeys.add(key);

        final original = postById[postId];
        if (original == null) continue;
        final info = actorInfo[actor] ?? {'name': actor, 'avatar': ''};
        final rawCreated = (row['created_at'] ?? '').toString();
        final parsedCreated = DateTime.tryParse(rawCreated);
        repostTimelinePosts.add(original.copyAsRepost(
          repostedByUsername: actor,
          repostedByName: (info['name'] ?? actor).trim().isEmpty ? actor : (info['name'] ?? actor),
          repostedByAvatarPath: (info['avatar'] ?? '').trim().isEmpty ? null : info['avatar'],
          repostedAt: _formatPostTime(rawCreated),
          timelineSortMillis: parsedCreated?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
        ));
      }

      final allPosts = <CityPost>[
        ..._localQuotePosts.where((p) => !_deletedPostIds.contains(p.id)).map(_applyLocalState),
        ...replyRepostTimelinePosts,
        ...repostTimelinePosts,
        ...loaded,
      ]..sort((a, b) => _timelineSortValue(b).compareTo(_timelineSortValue(a)));

      final storyUsers = allPosts.map((p) => SupabaseService.displayUsername(p.username)).toSet().toList();
      final storyRows = await SupabaseService.getActiveStories(usernames: storyUsers);
      final seenStoryIds = await SupabaseService.getSeenStoryIds();
      final storyMap = <String, List<Map<String, dynamic>>>{};
      for (final row in storyRows) {
        final u = SupabaseService.displayUsername((row['username'] ?? '').toString());
        if (u == '@user') continue;
        storyMap.putIfAbsent(u, () => <Map<String, dynamic>>[]).add(row);
      }

      if (!mounted) return;
      setState(() {
        _posts
          ..clear()
          ..addAll(allPosts);
        _refreshAvatars
          ..clear()
          ..addAll(_latestPostAvatars(allPosts));
        if (preloaded != null) _postsLoadedLimit = rows.length;
        _hasMorePosts = rows.length >= _feedPageSize;
        _activeStoriesByUser
          ..clear()
          ..addAll(storyMap);
        _seenStoryIds = seenStoryIds;
      });
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopNotification('تعذر تحميل المنشورات من الخادم: $e');
    } finally {
      _loadingPosts = false;
      if (mounted) setState(() => _loadingMorePosts = false);
    }
  }


  Future<void> _openStoriesForUsername(String username) async {
    final user = SupabaseService.displayUsername(username);
    var stories = _activeStoriesByUser[user] ?? const <Map<String, dynamic>>[];
    if (stories.isEmpty) {
      stories = await SupabaseService.getActiveStoriesForUser(user);
    }
    if (!mounted || stories.isEmpty) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoryViewerScreen(stories: stories)));
    if (!mounted) return;
    await SupabaseService.markStoriesSeen(stories);
    final seen = await SupabaseService.getSeenStoryIds();
    if (mounted) setState(() => _seenStoryIds = seen);
    unawaited(_loadPosts(reset: false));
  }

  Future<void> _loadMorePosts() async {
    if (_loadingPosts || _loadingMorePosts || !_hasMorePosts) return;
    if (!mounted) return;

    setState(() => _loadingMorePosts = true);
    final from = _postsLoadedLimit;
    final to = from + _feedPageSize - 1;

    try {
      final avatarMap = _cachedAvatarMap ??= await _localAvatarMap();
      final rows = await _fetchPostPage(from: from, to: to);
      final existingKeys = _posts
          .map((p) => '${p.repostedByUsername ?? ''}_${p.id}')
          .toSet();

      final newPosts = rows
          .where((e) => !_deletedPostIds.contains((e['id'] ?? '').toString()))
          .map((e) => _postFromServerRow(e, avatarMap))
          .where((p) => !existingKeys.contains('_${p.id}'))
          .toList();

      if (!mounted) return;
      setState(() {
        _posts.addAll(newPosts);
        _postsLoadedLimit += rows.length;
        _hasMorePosts = rows.length >= _feedPageSize;
        _loadingMorePosts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMorePosts = false);
      NotificationService.showTopNotification('تعذر تحميل المزيد: $e');
    }
  }


  static String _formatPostTime(String raw) => FeedScreenStateHelper.formatPostTime(raw);


  List<Map<String, String>> _latestPostAvatars(List<CityPost> posts) {
    final seen = <String>{};
    final out = <Map<String, String>>[];
    for (final p in posts) {
      if (seen.contains(p.username)) continue;
      seen.add(p.username);
      out.add({'name': p.user, 'username': p.username, 'avatar': p.avatarPath ?? '', 'postId': p.id});
      if (out.length >= 8) break;
    }
    return out;
  }

  Future<void> _refreshFeed() async {
    _cachedAvatarMap = null;
    _cachedRepostActors.clear();
    await _loadInitialData();
    if (!mounted) return;
    setState(() => _showRefreshAvatars = _refreshAvatars.isNotEmpty);
    _hideRefreshAvatarsTimer?.cancel();
    _hideRefreshAvatarsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showRefreshAvatars = false);
    });
    NotificationService.showTopNotification('تم تحديث الفيد');
  }

  Future<void> _scrollToTop(ScrollController controller) async {
    if (!controller.hasClients) return;
    await controller.animateTo(
      0,
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
    );
  }

  void _openPostFromRefresh(String postId) {
    // لم نعد نفتح التغريدة عند الضغط على كبسولة التحديث.
    // التمرير للأعلى يتم من كل تبويب عبر ScrollController الخاص به.
  }

  Future<void> _openQuotedPost(CityPost quotedPost) async {
    final matches = _posts.where((p) => p.id == quotedPost.id).toList();
    await _openReplies(matches.isNotEmpty ? matches.first : quotedPost);
  }

  Future<void> _saveMentionNotifications(CityPost post) async {
    final mentioned = RegExp(r'@([a-zA-Z0-9_\.]+)').allMatches(post.text)
        .map((m) => '@${(m.group(1) ?? '').toLowerCase()}')
        .where((s) => s.length > 1)
        .toSet()
        .toList();
    if (mentioned.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('respect_mentions_v1');
    final items = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) items.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    final now = DateTime.now().toIso8601String();
    for (final target in mentioned) {
      items.insert(0, {
        'id': '${post.id}_$target',
        'targetUsername': target,
        'postId': post.id,
        'authorName': post.user,
        'authorUsername': post.username,
        'text': post.text,
        'createdAt': now,
      });
    }

    // حفظ محلي احتياطي + حفظ عالمي في Supabase حتى يظهر الإشعار عند الحساب المذكور من أي جهاز.
    await prefs.setString('respect_mentions_v1', jsonEncode(items.take(300).toList()));
    try {
      await SupabaseService.createMentionNotifications(
        targets: mentioned,
        postId: post.id,
        authorUsername: post.username,
        authorName: post.user,
        text: post.text,
      );
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  String _postShareText(CityPost post) => '${post.user} ${post.username}\n${post.text}\nrespect://post/${post.id}';

  Future<void> _savePostEventNotification({
    required String type,
    required String targetUsername,
    required String postId,
    required String text,
  }) async {
    final target = SupabaseService.displayUsername(targetUsername);
    final author = SupabaseService.displayUsername(_profileUsername);
    if (target == author) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('respect_post_events_v1');
    final items = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) items.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    items.insert(0, {
      'id': '${type}_${postId}_${DateTime.now().microsecondsSinceEpoch}',
      'type': type,
      'targetUsername': target,
      'authorUsername': author,
      'authorName': _profileName,
      'postId': postId,
      'text': text,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString('respect_post_events_v1', jsonEncode(items.take(300).toList()));
    try {
      await SupabaseService.createPostEventNotification(
        type: type,
        targetUsername: target,
        actorUsername: author,
        actorName: _profileName,
        postId: postId,
        text: text,
      );
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _repostPost(CityPost post) async {
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

    if (action == 'quote') {
      final quote = await Navigator.of(context).push<CityPost>(
        MaterialPageRoute(
          builder: (_) => ComposePostScreen(profileName: _profileName, username: _profileUsername, profileImagePath: _profileImagePath, verified: _profileVerified, maxChars: _profilePostMaxChars),
        ),
      );
      if (quote != null) {
        final quoted = CityPost(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          user: quote.user,
          username: quote.username,
          avatarPath: quote.avatarPath,
          text: quote.text,
          time: 'الآن',
          mediaPath: quote.mediaPath,
          mediaType: quote.mediaType,
          voicePath: quote.voicePath,
          voiceSeconds: quote.voiceSeconds,
          quotedPost: post.copyForEmbed(),
          authorVerified: _profileVerified,
        );
        setState(() {
          _localQuotePosts.insert(0, quoted);
          _posts.insert(0, quoted);
        });
        await _saveMentionNotifications(quoted);
        await _savePosts();
      }
      return;
    }

    if (action != 'repost') return;
    if (_pendingRepostPostIds.contains(post.id)) return;
    _pendingRepostPostIds.add(post.id);

    final previousReposted = post.isReposted;
    final previousReposts = post.reposts;
    final nextReposted = !previousReposted;
    final nextReposts = (previousReposts + (nextReposted ? 1 : -1)).clamp(0, 1 << 30).toInt();

    setState(() {
      if (nextReposted) {
        _repostedPostIds.add(post.id);
      } else {
        _repostedPostIds.remove(post.id);
      }
      _updateLoadedPostInteraction(post.id, isReposted: nextReposted, reposts: nextReposts);
    });

    try {
      final result = await SupabaseService.setPostRepost(
        postId: post.id,
        username: _profileUsername,
        reposted: nextReposted,
      );
      if (!mounted) return;
      setState(() {
        final serverReposted = result['isReposted'] == true;
        final serverReposts = int.tryParse((result['reposts'] ?? post.reposts).toString()) ?? post.reposts;
        if (serverReposted) {
          _repostedPostIds.add(post.id);
        } else {
          _repostedPostIds.remove(post.id);
        }
        _updateLoadedPostInteraction(
          post.id,
          isReposted: serverReposted,
          reposts: serverReposts,
          likes: int.tryParse((result['likes'] ?? post.likes).toString()),
          shares: int.tryParse((result['shares'] ?? post.shares).toString()),
          views: int.tryParse((result['views'] ?? post.views).toString()),
        );
      });
      if (post.isReposted && SupabaseService.displayUsername(post.username) != SupabaseService.displayUsername(_profileUsername)) {
        await _savePostEventNotification(
          type: 'repost',
          targetUsername: post.username,
          postId: post.id,
          text: post.text,
        );
      }
      await _savePosts();
      unawaited(_loadPosts(reset: false));
      NotificationService.showTopNotification(post.isReposted ? 'تمت إعادة النشر وظهرت لمتابعيك' : 'تم إلغاء إعادة النشر');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (previousReposted) {
          _repostedPostIds.add(post.id);
        } else {
          _repostedPostIds.remove(post.id);
        }
        _updateLoadedPostInteraction(post.id, isReposted: previousReposted, reposts: previousReposts);
      });
      NotificationService.showTopNotification('تعذر تحديث إعادة النشر على السيرفر');
    } finally {
      _pendingRepostPostIds.remove(post.id);
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
    setState(() => post.shares += 1);
    try {
      final counters = await SupabaseService.incrementPostShare(post.id);
      if (mounted) {
        setState(() {
          post.shares = counters['shares'] ?? post.shares;
        });
      }
    } catch (e, st) { _logIgnoredError(e, st); }
    await Clipboard.setData(ClipboardData(text: _postShareText(post)));
    await _savePosts();
    if (!mounted) return;
    NotificationService.showTopNotification(choice == 'whatsapp' ? 'تم نسخ التغريدة، افتح واتساب والصقها' : 'تم نسخ رابط التغريدة');
  }

  void _openMedia(CityPost post) {
    final mediaPath = post.mediaPath?.trim();
    final mediaType = post.mediaType;
    if (mediaPath == null || mediaPath.isEmpty || mediaType == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => FullscreenMediaViewer(
      path: mediaPath,
      type: mediaType,
      post: post,
      onLike: () => _toggleLike(post),
      onReply: () => _openReplies(post),
      onRepost: () => _repostPost(post),
      onFavorite: () => _toggleFavorite(post),
    )));
  }
  Future<void> _savePosts() async {
    await _saveLocalPostState();
  }


  Future<void> _loadLocalModeration() async {
    final prefs = await SharedPreferences.getInstance();
    Set<String> readSet(String key) {
      final raw = prefs.getString(key);
      if (raw == null || raw.trim().isEmpty) return <String>{};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded.map((e) => _cleanUsername(e.toString())).toSet();
      } catch (e, st) { _logIgnoredError(e, st); }
      return <String>{};
    }
    if (!mounted) return;
    setState(() {
      _mutedUsers = readSet(_mutedUsersKey);
      _localBlockedUsers = readSet(_localBlockedUsersKey);
    });
  }

  Future<void> _saveLocalModeration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mutedUsersKey, jsonEncode(_mutedUsers.toList()..sort()));
    await prefs.setString(_localBlockedUsersKey, jsonEncode(_localBlockedUsers.toList()..sort()));
  }

  bool _isAuthorHidden(String username) {
    final clean = _cleanUsername(username);
    return _mutedUsers.contains(clean) || _localBlockedUsers.contains(clean);
  }

  List<CityPost> get _visiblePosts => _posts.where((p) => !_isAuthorHidden(p.username)).toList();

  Future<Map<String, String>?> _askCommunityReportDetails(CityPost post, {String title = 'بلاغ للمشرفين'}) async {
    String reason = 'محتوى مخالف';
    String details = '';
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        content: StatefulBuilder(
          builder: (context, setLocal) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: reason,
                  decoration: const InputDecoration(labelText: 'نوع البلاغ'),
                  items: const [
                    DropdownMenuItem(value: 'محتوى مخالف', child: Text('محتوى مخالف')),
                    DropdownMenuItem(value: 'سرقة محتوى', child: Text('سرقة محتوى')),
                    DropdownMenuItem(value: 'سبام أو إزعاج', child: Text('سبام أو إزعاج')),
                    DropdownMenuItem(value: 'تحرش أو إساءة', child: Text('تحرش أو إساءة')),
                    DropdownMenuItem(value: 'معلومات مضللة', child: Text('معلومات مضللة')),
                    DropdownMenuItem(value: 'بلاغ مخصص', child: Text('بلاغ مخصص')),
                  ],
                  onChanged: (v) => setLocal(() => reason = v ?? reason),
                ),
                const SizedBox(height: 12),
                TextField(
                  minLines: 3,
                  maxLines: 6,
                  onChanged: (value) => details = value,
                  decoration: InputDecoration(
                    labelText: reason == 'بلاغ مخصص' ? 'اكتب البلاغ الذي تريده' : 'اشرح البلاغ بالتفصيل',
                    hintText: reason == 'بلاغ مخصص' ? 'مثال: اشرح للمشرفين المشكلة كاملة...' : 'اختياري، لكن يساعد المشرفين والذكاء الاصطناعي',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إرسال')),
        ],
      ),
    );
    details = details.trim();
    if (submitted != true) return null;
    if (reason == 'بلاغ مخصص' && details.isEmpty) {
      NotificationService.showTopError('اكتب تفاصيل البلاغ المخصص أولاً');
      return null;
    }
    return {'reason': reason, 'details': details};
  }

  Future<void> _saveReportResultNotification({
    required String targetUsername,
    required String postId,
    required String text,
    required String communityName,
    required bool validReport,
    required String aiReason,
  }) async {
    final target = SupabaseService.displayUsername(targetUsername);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('respect_post_events_v1');
    final items = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          items.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    final type = validReport ? 'community_report_accepted' : 'community_report_rejected';
    items.insert(0, {
      'id': '${type}_${postId}_${DateTime.now().microsecondsSinceEpoch}',
      'type': type,
      'targetUsername': target,
      'authorUsername': SupabaseService.respectAiUsername,
      'authorName': SupabaseService.respectAiName,
      'postId': postId,
      'text': text,
      'communityName': communityName,
      'aiReason': aiReason,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString('respect_post_events_v1', jsonEncode(items.take(300).toList()));
  }

  Future<void> _reviewCommunityReportFromFeedWithAi(CityCommunity community, CommunityReport report, CityPost post) async {
    try {
      final result = await SupabaseService.reviewPostReportWithAi(
        reportId: report.id,
        postId: post.id,
        reporterUsername: report.reporterUsername,
        reportedUsername: post.username,
        reason: report.reason,
        details: report.details,
        postText: post.text,
        communityId: community.id,
        communityName: community.name,
      );
      final valid = result['validReport'] == true || result['shouldDelete'] == true || result['action'] == 'hide';
      if (!mounted) return;
      setState(() {
        report.status = valid ? 'accepted' : 'rejected';
        report.aiDecision = valid ? 'accepted' : 'rejected';
        report.aiReason = (result['reason'] ?? '').toString();
        if (valid) post.hiddenFromCommunity = true;
      });
      await _saveCommunities();
      await _saveReportResultNotification(
        targetUsername: report.reporterUsername,
        postId: post.id,
        text: post.text,
        communityName: community.name,
        validReport: valid,
        aiReason: report.aiReason,
      );
      try {
        await SupabaseService.createPostEventNotification(
          type: valid ? 'community_report_accepted' : 'community_report_rejected',
          targetUsername: report.reporterUsername,
          actorUsername: SupabaseService.respectAiUsername,
          actorName: SupabaseService.respectAiName,
          postId: post.id,
          text: post.text,
        );
      } catch (e, st) { _logIgnoredError(e, st); }
      if (!valid && SupabaseService.displayUsername(report.reporterUsername) == SupabaseService.displayUsername(_profileUsername)) {
        NotificationService.showTopNotification(
          'راجعنا البلاغ داخل ${community.name}، والتغريدة سليمة ولا يوجد عليها إجراء.',
          title: 'نتيجة البلاغ',
          icon: Icons.verified_user_rounded,
          accentColor: AppColors.success,
        );
      }
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _reportCommunityPostFromFeed(CityCommunity community, CityPost post) async {
    final data = await _askCommunityReportDetails(post);
    if (data == null) return;
    final report = CommunityReport(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      postId: post.id,
      reporterUsername: _profileUsername,
      reporterName: _profileName,
      postUsername: post.username,
      postUser: post.user,
      reason: data['reason'] ?? 'محتوى مخالف',
      details: data['details'] ?? '',
      createdAt: DateTime.now().toIso8601String(),
    );
    setState(() => community.reports.insert(0, report));
    await _saveCommunities();
    try {
      await SupabaseService.reportPost(
        postId: post.id,
        reporterUsername: _profileUsername,
        reason: report.reason,
        details: report.details,
        communityId: community.id,
        communityName: community.name,
        postUsername: post.username,
        postText: post.text,
      );
    } catch (e, st) { _logIgnoredError(e, st); }
    unawaited(_reviewCommunityReportFromFeedWithAi(community, report, post));
    if (!mounted) return;
    NotificationService.showTopSuccess('تم إرسال البلاغ للمشرفين');
  }

  Future<void> _toggleCommunityPostPinFromFeed(CityCommunity community, CityPost post) async {
    final isMod = community.ownerUsername == _profileUsername || community.moderators.contains(_profileUsername);
    if (!isMod) {
      NotificationService.showTopError('هذا الخيار للمشرفين فقط');
      return;
    }

    final pinned = community.posts.where((p) => p.pinnedInCommunity && !p.hiddenFromCommunity).length;
    if (!post.pinnedInCommunity && pinned >= 3) {
      NotificationService.showTopError('مسموح 3 تغريدات مثبتة فقط');
      return;
    }

    setState(() {
      final target = community.posts.where((p) => p.id == post.id).toList();
      if (target.isNotEmpty) {
        target.first.pinnedInCommunity = !target.first.pinnedInCommunity;
        post.pinnedInCommunity = target.first.pinnedInCommunity;
      } else {
        post.pinnedInCommunity = !post.pinnedInCommunity;
      }
    });

    await _saveCommunities();
    if (!mounted) return;
    NotificationService.showTopSuccess(post.pinnedInCommunity ? 'تم تثبيت التغريدة' : 'تم إلغاء تثبيت التغريدة');
  }

  Future<void> _showCommunityQuickPostActions(CityCommunity community, CityPost post) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
        return SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkBg : AppColors.lightBg,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: AppColors.purple.withValues(alpha: 0.25)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 46, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(99))),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.flag_rounded, color: Colors.orange),
                  title: const Text('إبلاغ المشرفين', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text('سيظهر البلاغ مباشرة داخل تبويب البلاغات في المجتمع', style: TextStyle(color: muted, fontSize: 12)),
                  onTap: () => Navigator.pop(sheetContext, 'report'),
                ),
                if (community.ownerUsername == _profileUsername || community.moderators.contains(_profileUsername))
                  ListTile(
                    leading: const Icon(Icons.push_pin_rounded, color: AppColors.purple),
                    title: Text(
                      post.pinnedInCommunity ? 'إلغاء تثبيت التغريدة' : 'تثبيت التغريدة',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    subtitle: Text('تظهر التغريدة أعلى تبويب المجتمع', style: TextStyle(color: muted, fontSize: 12)),
                    onTap: () => Navigator.pop(sheetContext, 'pin'),
                  ),
                ListTile(
                  leading: const Icon(Icons.open_in_new_rounded, color: AppColors.purple),
                  title: const Text('فتح المجتمع', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text('انتقل إلى صفحة المجتمع والإدارة', style: TextStyle(color: muted, fontSize: 12)),
                  onTap: () => Navigator.pop(sheetContext, 'open'),
                ),
                ListTile(
                  leading: const Icon(Icons.more_horiz_rounded, color: AppColors.purple),
                  title: const Text('خيارات التغريدة العامة', style: TextStyle(fontWeight: FontWeight.w900)),
                  onTap: () => Navigator.pop(sheetContext, 'general'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (choice == 'report') await _reportCommunityPostFromFeed(community, post);
    if (choice == 'pin') await _toggleCommunityPostPinFromFeed(community, post);
    if (choice == 'open') await _openCommunity(community);
    if (choice == 'general') await _showPostActions(post);
  }

  Future<void> _reviewNormalReportWithAi({
    required Map<String, dynamic> report,
    required CityPost post,
    required String reportReason,
    required String reportDetails,
    required String source,
    required String communityId,
    required String communityName,
  }) async {
    try {
      final reportId = (report['id'] ?? report['report_id'] ?? '').toString();
      final result = await SupabaseService.reviewPostReportWithAi(
        reportId: reportId,
        postId: post.id,
        reporterUsername: _profileUsername,
        reportedUsername: post.username,
        reason: reportReason,
        details: reportDetails,
        postText: post.text,
        communityId: communityId,
        communityName: communityName,
      );

      final valid = result['validReport'] == true || result['shouldDelete'] == true;
      final aiReason = (result['reason'] ?? '').toString().trim();
      final cleanReason = aiReason.isEmpty ? reportReason : aiReason;

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_postReportsKey);
      final reports = <Map<String, dynamic>>[];
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            reports.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
          }
        } catch (e, st) { _logIgnoredError(e, st); }
      }
      for (final r in reports) {
        if ((r['id'] ?? '').toString() == (report['id'] ?? '').toString()) {
          r['status'] = valid ? 'accepted' : 'rejected';
          r['aiStatus'] = valid ? 'accepted' : 'rejected';
          r['aiDecision'] = valid ? 'accepted' : 'rejected';
          r['aiReason'] = cleanReason;
          r['reviewedAt'] = DateTime.now().toIso8601String();
          break;
        }
      }
      await prefs.setString(_postReportsKey, jsonEncode(reports));

      if (valid) {
        if (mounted) {
          setState(() {
            _deletedPostIds.add(post.id);
            _posts.removeWhere((p) => p.id == post.id || p.quotedPost?.id == post.id);
          });
        }
        unawaited(_saveLocalPostState());
        unawaited(_savePosts());

        if (mounted) {
          NotificationService.showTopNotification(
            'تم قبول البلاغ وحذف التغريدة. السبب: $cleanReason',
            title: 'Respect AI',
            icon: Icons.gpp_good_rounded,
            accentColor: AppColors.danger,
          );
        }
      } else {
        if (mounted) {
          NotificationService.showTopNotification(
            'راجعنا البلاغ، والتغريدة سليمة ولا يوجد عليها إجراء.',
            title: 'نتيجة البلاغ',
            icon: Icons.verified_user_rounded,
            accentColor: AppColors.success,
          );
        }
      }
    } catch (e) {
      assert(() { _scannerSafeIgnore(); return true; }());
    }
  }

  Future<void> _reportPost(CityPost post, {String source = 'feed', String communityId = '', String communityName = ''}) async {
    final type = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final reasons = <Map<String, dynamic>>[
          {'title': 'محتوى مسيء', 'icon': Icons.report_problem_rounded},
          {'title': 'سبام أو إزعاج', 'icon': Icons.mark_email_unread_rounded},
          {'title': 'تحرش أو إساءة', 'icon': Icons.front_hand_rounded},
          {'title': 'معلومات مضللة', 'icon': Icons.warning_amber_rounded},
          {'title': 'محتوى مخالف', 'icon': Icons.gpp_bad_rounded},
          {'title': 'بلاغ مخصص', 'icon': Icons.edit_note_rounded},
        ];
        return Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBg : AppColors.lightBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
          ),
          child: SafeArea(
            top: false,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Center(child: Container(width: 46, height: 5, decoration: BoxDecoration(color: isDark ? AppColors.darkBorder : AppColors.lightBorder, borderRadius: BorderRadius.circular(99)))),
                const SizedBox(height: 16),
                const Text('الإبلاغ عن التغريدة', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 12),
                ...reasons.map((r) => ListTile(
                  leading: Icon(r['icon'] as IconData, color: AppColors.danger),
                  title: Text(r['title'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
                  onTap: () => Navigator.pop(context, r['title'] as String),
                )),
              ],
            ),
          ),
        );
      },
    );

    if (type == null || type.trim().isEmpty) return;
    var reportReason = type.trim();
    var reportDetails = '';
    if (reportReason == 'بلاغ مخصص') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('بلاغ مخصص', style: TextStyle(fontWeight: FontWeight.w900)),
          content: TextField(
            minLines: 3,
            maxLines: 6,
            onChanged: (value) => reportDetails = value,
            decoration: const InputDecoration(labelText: 'اكتب البلاغ الذي تريده', border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إرسال')),
          ],
        ),
      );
      reportDetails = reportDetails.trim();
      if (ok != true || reportDetails.isEmpty) {
        NotificationService.showTopError('اكتب تفاصيل البلاغ المخصص أولاً');
        return;
      }
    }

    Map<String, dynamic> serverReport = <String, dynamic>{};
    try {
      serverReport = await SupabaseService.reportPost(
        postId: post.id,
        reporterUsername: _profileUsername,
        reason: reportReason,
        details: reportDetails,
        communityId: communityId,
        communityName: communityName,
        postUsername: post.username,
        postText: post.text,
      );
    } catch (e, st) { _logIgnoredError(e, st); }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_postReportsKey);
    final reports = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) reports.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    final localReport = <String, dynamic>{
      'id': (serverReport['id'] ?? DateTime.now().microsecondsSinceEpoch).toString(),
      'type': reportReason,
      'details': reportDetails,
      'source': source,
      'communityId': communityId,
      'communityName': communityName,
      'postId': post.id,
      'postText': post.text,
      'postUser': post.user,
      'postUsername': post.username,
      'postTime': post.time,
      'reporterUsername': _profileUsername,
      'reporterName': _profileName,
      'status': 'pending',
      'aiStatus': 'pending',
      'createdAt': DateTime.now().toIso8601String(),
    };
    reports.insert(0, localReport);
    await prefs.setString(_postReportsKey, jsonEncode(reports));
    if (!mounted) return;
    NotificationService.showTopNotification('تم إرسال البلاغ للإدارة وبدأت مراجعة Respect AI');
    unawaited(_reviewNormalReportWithAi(
      report: localReport,
      post: post,
      reportReason: reportReason,
      reportDetails: reportDetails,
      source: source,
      communityId: communityId,
      communityName: communityName,
    ));
  }

  Future<void> _showPostActions(CityPost post) async {
    final authorUsername = _cleanUsername(post.username);
    final isMe = authorUsername == _profileUsername;
    final isMuted = _mutedUsers.contains(authorUsername);
    final isBlocked = _localBlockedUsers.contains(authorUsername);

    Future<void> showSelfMessage(String action) async {
      if (!mounted) return;
      NotificationService.showTopNotification('لا يمكنك $action حسابك أنت');
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final mutedText = isDark ? AppColors.darkMuted : AppColors.lightMuted;
        return Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBg : AppColors.lightBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
          ),
          child: SafeArea(
            top: false,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
                const SizedBox(height: 14),
                Center(
                  child: _RespectAuthorName(
                    name: post.user,
                    username: post.username,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                ),
                Text(authorUsername, textAlign: TextAlign.center, style: TextStyle(color: mutedText)),
                const SizedBox(height: 12),
                if (isMe) ...[
                  ListTile(
                    leading: const Icon(Icons.edit_rounded, color: AppColors.purple),
                    title: const Text('تعديل التغريدة'),
                    subtitle: Text('تعديل النص وسيظهر فورًا في الفيد', style: TextStyle(color: mutedText, fontSize: 12)),
                    onTap: () async {
                      Navigator.pop(context);
                      await _editOwnPostFromFeed(post);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.delete_rounded, color: AppColors.danger),
                    title: const Text('حذف التغريدة'),
                    subtitle: Text('حذفها من البروفايل والفيد والسيرفر', style: TextStyle(color: mutedText, fontSize: 12)),
                    onTap: () async {
                      Navigator.pop(context);
                      await _deleteOwnPostFromFeed(post);
                    },
                  ),
                  Divider(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                ],
                ListTile(
                  leading: Icon(
                    isMuted ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                    color: isMe ? mutedText : AppColors.purple,
                  ),
                  title: Text(isMuted ? 'إلغاء كتم المستخدم' : 'كتم المستخدم'),
                  subtitle: Text(
                    isMe ? 'غير متاح على حسابك' : 'إخفاء تغريدات هذا المستخدم من الصفحة',
                    style: TextStyle(color: mutedText, fontSize: 12),
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    if (isMe) {
                      await showSelfMessage('كتم');
                      return;
                    }
                    setState(() {
                      if (isMuted) {
                        _mutedUsers.remove(authorUsername);
                      } else {
                        _mutedUsers.add(authorUsername);
                      }
                    });
                    await _saveLocalModeration();
                    if (!mounted) return;
                    NotificationService.showTopNotification(isMuted ? 'تم إلغاء كتم ${post.user}' : 'تم كتم ${post.user}');
                  },
                ),
                ListTile(
                  leading: Icon(
                    isBlocked ? Icons.lock_open_rounded : Icons.block_rounded,
                    color: isMe ? mutedText : AppColors.danger,
                  ),
                  title: Text(isBlocked ? 'إلغاء حظر المستخدم' : 'حظر المستخدم'),
                  subtitle: Text(
                    isMe ? 'غير متاح على حسابك' : 'إخفاء المستخدم وتغريداته محليًا من التطبيق',
                    style: TextStyle(color: mutedText, fontSize: 12),
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    if (isMe) {
                      await showSelfMessage('حظر');
                      return;
                    }
                    setState(() {
                      if (isBlocked) {
                        _localBlockedUsers.remove(authorUsername);
                      } else {
                        _localBlockedUsers.add(authorUsername);
                      }
                    });
                    await _saveLocalModeration();
                    if (!mounted) return;
                    NotificationService.showTopNotification(isBlocked ? 'تم إلغاء حظر ${post.user}' : 'تم حظر ${post.user}');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share_rounded, color: AppColors.purple),
                  title: const Text('مشاركة التغريدة'),
                  subtitle: Text('نسخ الرابط أو إرسال التغريدة', style: TextStyle(color: mutedText, fontSize: 12)),
                  onTap: () async {
                    Navigator.pop(context);
                    await _sharePost(post);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.report_rounded, color: AppColors.danger),
                  title: const Text('الإبلاغ عن التغريدة'),
                  subtitle: Text('إرسال البلاغ إلى لوحة الإدارة', style: TextStyle(color: mutedText, fontSize: 12)),
                  onTap: () async {
                    Navigator.pop(context);
                    await _reportPost(post);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }



  Future<void> _loadFollowing() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_followingKey);
    final data = <String, List<String>>{};
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is List) data[key.toString()] = value.map((e) => e.toString()).toSet().toList();
          });
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    // مزامنة المتابعات من Supabase حتى تكون عالمية بين كل الأجهزة.
    try {
      final serverFollowing = await SupabaseService.getFollowingUsernames(_profileUsername);
      data[SupabaseService.displayUsername(_profileUsername)] = serverFollowing.toSet().toList();
    } catch (e, st) { _logIgnoredError(e, st); }

    if (!mounted) return;
    setState(() => _following = data);
  }

  Future<void> _saveFollowing() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_followingKey, jsonEncode(_following));
  }


  Future<void> _loadPostNotificationTargets() async {
    try {
      final targets = await SupabaseService.getEnabledPostNotificationTargets(_profileUsername);
      if (!mounted) return;
      setState(() => _postNotificationTargets = targets);
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _togglePostNotificationForUser(String targetUsername) async {
    final target = SupabaseService.displayUsername(targetUsername);
    final me = SupabaseService.displayUsername(_profileUsername);
    if (target == me || target == '@user') return;

    final following = (_following[me] ?? const <String>[]).contains(target);
    if (!following) {
      NotificationService.showTopNotification('تابع المستخدم أولًا لتفعيل إشعاراته');
      return;
    }

    final enabled = !_postNotificationTargets.contains(target);
    setState(() {
      if (enabled) {
        _postNotificationTargets.add(target);
      } else {
        _postNotificationTargets.remove(target);
      }
    });

    try {
      await SupabaseService.setUserPostNotification(
        followerUsername: me,
        targetUsername: target,
        enabled: enabled,
      );
      if (!mounted) return;
      NotificationService.showTopNotification(enabled ? 'تم تفعيل إشعارات تغريدات هذا المستخدم' : 'تم إيقاف إشعارات تغريدات هذا المستخدم');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (enabled) {
          _postNotificationTargets.remove(target);
        } else {
          _postNotificationTargets.add(target);
        }
      });
      NotificationService.showTopNotification('تعذر تحديث إشعارات المستخدم');
    }
  }

  Future<void> _toggleFollowUser(String targetUsername) async {
    final target = SupabaseService.displayUsername(targetUsername);
    final me = SupabaseService.displayUsername(_profileUsername);
    if (target == me) return;

    final list = List<String>.from(_following[me] ?? const <String>[]);
    final wasFollowing = list.contains(target);

    if (wasFollowing) {
      list.remove(target);
    } else {
      list.add(target);
    }

    setState(() => _following[me] = list.toSet().toList());
    await _saveFollowing();

    // حفظ المتابعة عالميًا في Supabase حتى يظهر إشعار متابعة لصاحب الحساب من أي جهاز.
    try {
      final result = await SupabaseService.setUserFollow(
        followerUsername: me,
        targetUsername: target,
        follow: !wasFollowing,
      );
      final isFollowing = result['isFollowing'] == true;
      if (!mounted) return;
      final synced = List<String>.from(_following[me] ?? const <String>[]);
      if (isFollowing) {
        if (!synced.contains(target)) synced.add(target);
      } else {
        synced.remove(target);
        _postNotificationTargets.remove(target);
      }
      setState(() => _following[me] = synced.toSet().toList());
      await _saveFollowing();
    } catch (_) {
      // إذا كان جدول المتابعة غير موجود، يبقى التطبيق يعمل محليًا.
    }
  }

  Future<void> _loadCommunities() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_communitiesKey);
    final loaded = <CityCommunity>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          loaded.addAll(decoded.whereType<Map>().map((e) => CityCommunity.fromJson(e.map((k, v) => MapEntry(k.toString(), v)))));
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    if (!mounted) return;
    setState(() {
      _communities
        ..clear()
        ..addAll(loaded);
    });
  }

  Future<void> _saveCommunities() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_communitiesKey, jsonEncode(_communities.map((c) => c.toJson()).toList()));
  }

  Future<void> _createCommunity() async {
    if (!mounted) return;

    final community = await Navigator.of(context).push<CityCommunity>(
      MaterialPageRoute(
        builder: (_) => CreateCommunityScreen(
          ownerUsername: _profileUsername,
        ),
      ),
    );

    if (community == null || !mounted) return;
    setState(() => _communities.insert(0, community));
    await _saveCommunities();
  }

  Future<void> _openCommunity(CityCommunity community) async {
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => CommunityScreen(
      community: community,
      currentUsername: _profileUsername,
      currentName: _profileName,
      currentAvatarPath: _profileImagePath,
      avatarProviderForPath: _profileImageProvider,
      onChanged: () async {
        setState(() {});
        await _saveCommunities();
      },
    )));
    await _saveCommunities();
    if (mounted) setState(() {});
  }

  List<CityPost> get _followingPosts {
    final me = SupabaseService.displayUsername(_profileUsername);
    final list = (_following[me] ?? const <String>[]).map(SupabaseService.displayUsername).toSet();
    final posts = _visiblePosts.where((p) {
      final author = SupabaseService.displayUsername(p.username);
      final reposter = p.repostedByUsername == null ? null : SupabaseService.displayUsername(p.repostedByUsername!);
      return author == me || list.contains(author) || reposter == me || (reposter != null && list.contains(reposter));
    }).toList()..sort((a, b) => _timelineSortValue(b).compareTo(_timelineSortValue(a)));
    return posts;
  }

  Future<void> _loadProfile() async {
    Map<String, dynamic>? account;

    try {
      account = await SupabaseService.currentUser();
    } catch (e, st) { _logIgnoredError(e, st); }

    final prefs = await SharedPreferences.getInstance();
    final localAccount = _currentAccountFromPrefs(prefs);
    account ??= localAccount;
    final localImagePath = ((localAccount == null ? null : localAccount['avatar_url']) ?? (localAccount == null ? null : localAccount['imagePath']) ?? (localAccount == null ? null : localAccount['profileImagePath']))?.toString();
    if (!mounted) return;

    setState(() {
      _profileName = ((account == null ? null : account['name']) ?? (account == null ? null : account['profileName']) ?? 'Nawaf RP').toString().trim().isNotEmpty
          ? ((account == null ? null : account['name']) ?? (account == null ? null : account['profileName']) ?? 'Nawaf RP').toString().trim()
          : 'Nawaf RP';
      _profileUsername = SupabaseService.displayUsername(((account == null ? null : account['username']) ?? '@nawaf_city').toString());
      _profileBio = ((account == null ? null : account['bio']) ?? 'Respect App user').toString().trim().isNotEmpty
          ? ((account == null ? null : account['bio']) ?? 'Respect App user').toString().trim()
          : 'Respect App user';
      _profileImagePath = (localImagePath != null && localImagePath.trim().isNotEmpty) ? localImagePath : ((account == null ? null : account['avatar_url']) ?? (account == null ? null : account['imagePath']) ?? (account == null ? null : account['profileImagePath']))?.toString();
      _profileVerified = SupabaseService.isVerifiedUser(account);
      _profilePostMaxChars = SupabaseService.postMaxCharsForUser(account);
    });
  }

  Map<String, dynamic>? _currentAccountFromPrefs(SharedPreferences prefs) {
    final currentId = prefs.getString(_currentUserKey) ?? prefs.getString('current_user_id');
    if (currentId == null || currentId.trim().isEmpty) return null;

    final accountsRaw = prefs.getString(_accountsKey);
    if (accountsRaw != null && accountsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(accountsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map && (item['id'] ?? '').toString() == currentId) {
              return _normalizeAccount(item);
            }
          }
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    final usersRaw = prefs.getString('respect_users_map');
    if (usersRaw != null && usersRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(usersRaw);
        if (decoded is Map) {
          final item = decoded[currentId];
          if (item is Map) return _normalizeAccount(item);
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    return null;
  }

  Map<String, dynamic> _normalizeAccount(Map raw) {
    final map = raw.map((key, value) => MapEntry(key.toString(), value));
    final username = (map['username'] ?? map['id'] ?? '@user').toString();
    return {
      ...map,
      'profileName': (map['profileName'] ?? map['name'] ?? 'Nawaf RP').toString(),
      'username': _cleanUsername(username),
      'bio': (map['bio'] ?? 'Respect App user').toString(),
      'imagePath': (map['avatar_url'] ?? map['imagePath'] ?? map['profileImagePath'])?.toString(),
      'avatar_url': (map['avatar_url'] ?? map['imagePath'] ?? map['profileImagePath'])?.toString(),
      'coverPath': map['coverPath']?.toString(),
    };
  }

  static String _cleanUsername(String value) {
    final v = value.trim().replaceAll(' ', '_');
    if (v.isEmpty) return '@nawaf_city';
    return v.startsWith('@') ? v : '@$v';
  }

  ImageProvider? _profileImageProvider([String? path]) {
    // لا تستخدم صورة الحساب الحالي كبديل للمنشورات.
    // إذا post.avatarPath فاضي، لازم يظهر الأيقونة الافتراضية وليس صورة حساب آخر.
    final p = path?.trim();
    if (p == null || p.isEmpty) return null;

    final lowerPath = p.split('?').first.toLowerCase();
    final looksLikeVideo = lowerPath.endsWith('.mp4') ||
        lowerPath.endsWith('.mov') ||
        lowerPath.endsWith('.m4v') ||
        lowerPath.endsWith('.webm') ||
        lowerPath.endsWith('.mkv');
    if (looksLikeVideo) return null;

    // لو الصورة رابط من السيرفر.
    if (p.startsWith('http://') || p.startsWith('https://')) {
      return NetworkImage(p);
    }

    final file = File(p);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  Future<void> _toggleLike(CityPost post) async {
    if (_pendingLikePostIds.contains(post.id)) return;
    _pendingLikePostIds.add(post.id);

    final previousLiked = post.isLiked;
    final previousLikes = post.likes;
    final nextLiked = !previousLiked;
    final nextLikes = (previousLikes + (nextLiked ? 1 : -1)).clamp(0, 1 << 30).toInt();

    setState(() {
      if (nextLiked) {
        _likedPostIds.add(post.id);
      } else {
        _likedPostIds.remove(post.id);
      }
      _updateLoadedPostInteraction(
        post.id,
        isLiked: nextLiked,
        likes: nextLikes,
      );
    });

    try {
      final result = await SupabaseService.setPostLike(
        postId: post.id,
        username: _profileUsername,
        liked: nextLiked,
      );
      if (!mounted) return;
      final serverLiked = result['isLiked'] == true;
      final serverLikes = int.tryParse((result['likes'] ?? nextLikes).toString()) ?? nextLikes;
      setState(() {
        if (serverLiked) {
          _likedPostIds.add(post.id);
        } else {
          _likedPostIds.remove(post.id);
        }
        _updateLoadedPostInteraction(
          post.id,
          isLiked: serverLiked,
          likes: serverLikes,
          reposts: int.tryParse((result['reposts'] ?? post.reposts).toString()),
          shares: int.tryParse((result['shares'] ?? post.shares).toString()),
          views: int.tryParse((result['views'] ?? post.views).toString()),
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (previousLiked) {
          _likedPostIds.add(post.id);
        } else {
          _likedPostIds.remove(post.id);
        }
        _updateLoadedPostInteraction(
          post.id,
          isLiked: previousLiked,
          likes: previousLikes,
        );
      });
      NotificationService.showTopNotification('تعذر تحديث اللايك على السيرفر');
    } finally {
      _pendingLikePostIds.remove(post.id);
    }

    await _savePosts();
  }

  Future<Set<String>> _readSavedPostIds(SharedPreferences prefs) async {
    final raw = prefs.getString(_savedPostsKey);
    if (raw == null || raw.trim().isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => (e['id'] ?? '').toString())
            .where((id) => id.isNotEmpty)
            .toSet();
      }
    } catch (e, st) { _logIgnoredError(e, st); }
    return <String>{};
  }

  Future<void> _writeSavedPostIds(SharedPreferences prefs) async {
    final raw = prefs.getString(_savedPostsKey);
    final items = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          items.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    final filtered = items.where((e) => _savedPostIds.contains((e['id'] ?? '').toString())).toList();
    await prefs.setString(_savedPostsKey, jsonEncode(filtered));
  }

  Map<String, dynamic> _savedPostPayload(CityPost post) {
    final data = post.toJson();
    data['savedAt'] = DateTime.now().toIso8601String();
    data['name'] = post.user;
    data['user'] = post.user;
    data['avatar_url'] = post.avatarPath;
    data['image_url'] = post.mediaType == CityMediaType.image ? post.mediaPath : null;
    data['video_url'] = post.mediaType == CityMediaType.video ? post.mediaPath : null;
    return data;
  }



  Future<void> _syncSavedStateFromPrefs({bool force = false}) async {
    if (_syncingSavedState) return;
    _syncingSavedState = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final latest = await _readSavedPostIds(prefs);
      final changed = force || latest.length != _savedPostIds.length || !latest.containsAll(_savedPostIds);
      if (!changed) return;
      if (!mounted) {
        _savedPostIds = latest;
        return;
      }
      setState(() {
        _savedPostIds = latest;
        for (final p in _posts) {
          p.isFavorite = _savedPostIds.contains(p.id);
        }
        for (final p in _localQuotePosts) {
          p.isFavorite = _savedPostIds.contains(p.id);
        }
      });
    } finally {
      _syncingSavedState = false;
    }
  }

  Future<void> _toggleFavorite(CityPost post) async {
    if (_pendingSavePostIds.contains(post.id)) return;
    _pendingSavePostIds.add(post.id);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_savedPostsKey);
    final items = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          items.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    final wasSaved = _savedPostIds.contains(post.id) || post.isFavorite;
    final nextSaved = !wasSaved;
    if (wasSaved) {
      _savedPostIds.remove(post.id);
      items.removeWhere((e) => (e['id'] ?? '').toString() == post.id);
    } else {
      _savedPostIds.add(post.id);
      items.removeWhere((e) => (e['id'] ?? '').toString() == post.id);
      items.insert(0, _savedPostPayload(post));
    }

    setState(() {
      _updateLoadedPostInteraction(post.id, isFavorite: nextSaved);
    });

    await prefs.setString(_savedPostsKey, jsonEncode(items.take(500).toList()));

    try {
      final result = await SupabaseService.togglePostSave(
        postId: post.id,
        username: _profileUsername,
      );
      if (!mounted) return;
      final serverSaved = result['isSaved'] == true;
      setState(() {
        if (serverSaved) {
          _savedPostIds.add(post.id);
        } else {
          _savedPostIds.remove(post.id);
        }
        _updateLoadedPostInteraction(post.id, isFavorite: serverSaved);
      });
      await _savePosts();
      NotificationService.showTopNotification(serverSaved ? 'تم حفظ التغريدة في المحفوظات' : 'تمت إزالة التغريدة من المحفوظات');
    } catch (_) {
      await _savePosts();
      if (!mounted) return;
      NotificationService.showTopNotification('تم تحديث الحفظ محليًا، وتعذرت مزامنته مع السيرفر');
    } finally {
      _pendingSavePostIds.remove(post.id);
    }
  }

  Future<String> _prepareVideoForUpload(String path) async {
    final raw = path.trim();
    if (raw.isEmpty || raw.startsWith('http://') || raw.startsWith('https://')) return raw;

    final original = File(raw);
    if (!await original.exists()) return raw;

    final originalMb = await original.length() / (1024 * 1024);
    if (originalMb <= 8) return raw;

    try {
      _setPublishProgress(0.16, 'ضغط الفيديو لتسريع الرفع والتشغيل...');
      await VideoCompress.setLogLevel(0);
      final info = await VideoCompress.compressVideo(
        raw,
        quality: VideoQuality.LowQuality,
        deleteOrigin: false,
        includeAudio: true,
        frameRate: 24,
      );

      final compressedPath = info?.path;
      if (compressedPath == null || compressedPath.trim().isEmpty) return raw;

      final compressedFile = File(compressedPath);
      if (!await compressedFile.exists()) return raw;

      final compressedMb = await compressedFile.length() / (1024 * 1024);
      if (compressedMb > 90) {
        throw Exception('الفيديو كبير جدًا بعد الضغط، اختر فيديو أقصر أو أقل من 90MB');
      }

      _setPublishProgress(0.24, 'تم ضغط الفيديو من ${originalMb.toStringAsFixed(1)}MB إلى ${compressedMb.toStringAsFixed(1)}MB');
      return compressedPath;
    } catch (e) {
      _setPublishProgress(0.20, 'تعذر ضغط الفيديو، سيتم رفع النسخة الأصلية...');
      return raw;
    }
  }

  Future<void> _openCompose({String initialText = ''}) async {
    await _loadProfile();
    if (!mounted) return;

    final cleanInitialText = initialText.trim();
    final post = await Navigator.of(context).push<CityPost>(
      MaterialPageRoute(
        builder: (_) => ComposePostScreen(
          profileName: _profileName,
          username: _profileUsername,
          profileImagePath: _profileImagePath,
          verified: _profileVerified,
          maxChars: _profilePostMaxChars,
          availableCommunities: _communities,
          initialText: cleanInitialText.length > _profilePostMaxChars
              ? cleanInitialText.substring(0, _profilePostMaxChars)
              : cleanInitialText,
        ),
      ),
    );

    if (post == null) return;
    await _loadProfile();
    if (!mounted) return;

    try {
      _setPublishProgress(0.08, 'تجهيز التغريدة...');
      final mediaPath = post.mediaPath?.trim() ?? '';
      final hasMedia = mediaPath.isNotEmpty;
      final hasVideo = post.mediaType == CityMediaType.video;
      final hasVoice = (post.voicePath?.trim().isNotEmpty ?? false);

      if (hasVideo) {
        _setPublishProgress(0.18, 'جاري رفع الفيديو...');
      } else if (hasMedia) {
        _setPublishProgress(0.22, 'جاري رفع الصورة...');
      } else if (hasVoice) {
        _setPublishProgress(0.28, 'جاري رفع التسجيل الصوتي...');
      }

      String uploadImagePath = post.mediaType == CityMediaType.image || post.mediaType == CityMediaType.gif ? (post.mediaPath ?? '') : '';
      String uploadVideoPath = post.mediaType == CityMediaType.video ? (post.mediaPath ?? '') : '';
      if (uploadVideoPath.trim().isNotEmpty) {
        uploadVideoPath = await _prepareVideoForUpload(uploadVideoPath);
      }

      await SupabaseService.enforcePostCharacterLimit(username: _profileUsername, text: post.text);

      final inserted = await SupabaseService.addPost(
        username: _profileUsername,
        name: _profileName,
        text: post.text,
        imageUrl: uploadImagePath,
        videoUrl: uploadVideoPath,
        voiceUrl: post.voicePath ?? '',
        voiceSeconds: post.voiceSeconds,
        audience: post.audience,
        communityId: post.communityId,
        communityName: post.communityName,
        onProgress: (progress, status) => _setPublishProgress(progress, status),
      );
      _setPublishProgress(0.92, 'تحديث الفيد...');
      final imageUrl = (inserted['image_url'] ?? '').toString();
      final videoUrl = (inserted['video_url'] ?? '').toString();
      final voiceUrl = (inserted['voice_url'] ?? '').toString();
      final publishedPost = CityPost(
        id: (inserted['id'] ?? post.id).toString(),
        user: _profileName,
        username: _profileUsername,
        avatarPath: _profileImagePath,
        text: post.text,
        time: 'الآن',
        mediaPath: imageUrl.isNotEmpty ? imageUrl : (videoUrl.isNotEmpty ? videoUrl : post.mediaPath),
        mediaType: imageUrl.isNotEmpty ? CityMediaType.image : (videoUrl.isNotEmpty ? CityMediaType.video : post.mediaType),
        voicePath: voiceUrl.isNotEmpty ? voiceUrl : post.voicePath,
        voiceSeconds: int.tryParse((inserted['voice_seconds'] ?? post.voiceSeconds).toString()) ?? post.voiceSeconds,
        authorVerified: _profileVerified,
        audience: post.audience,
        communityId: post.communityId,
        communityName: post.communityName,
      );
      if (mounted) {
        setState(() {
          if (publishedPost.audience != 'community') {
            _posts.insert(0, _applyLocalState(publishedPost));
          } else {
            final idx = _communities.indexWhere((c) => c.id == publishedPost.communityId);
            if (idx >= 0) _communities[idx].posts.insert(0, publishedPost);
          }
          _refreshAvatars.insert(0, {
            'username': _profileUsername,
            'name': _profileName,
            'avatar': _profileImagePath ?? '',
          });
          _showRefreshAvatars = true;
        });
      }

      // إشعارات المنشن لا توقف النشر.
      unawaited(_saveMentionNotifications(publishedPost));

      // Respect AI: إذا المستخدم منشن @RespectAI داخل منشور جديد، يرد كتعليق رسمي بعد النشر.
      if (SupabaseService.hasRespectAiMention(post.text)) {
        unawaited(() async {
          try {
            await SupabaseService.createRespectAiReplyIfNeeded(
              postId: publishedPost.id,
              triggerText: post.text,
              askerUsername: _profileUsername,
              postText: post.text,
            );
            if (mounted) {
              await _loadPosts();
              NotificationService.showTopSuccess('Respect AI رد على التغريدة');
            }
          } catch (e) {
            assert(() { _scannerSafeIgnore(); return true; }());
            if (mounted) NotificationService.showTopError(e.toString().replaceFirst('Exception: ', ''));
          }
        }());
      }

      _setPublishProgress(1.0, 'تم نشر التغريدة');
      unawaited(_loadPosts());
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _hidePublishProgress();
    } catch (e) {
      _hidePublishProgress();
      if (!mounted) return;
      NotificationService.showTopNotification('تعذر نشر التغريدة على الخادم: $e');
    }
  }

  Future<void> _markPostViewed(CityPost post) async {
    if (_viewedPostIds.contains(post.id) || _pendingViewPostIds.contains(post.id)) return;
    _pendingViewPostIds.add(post.id);
    _viewedPostIds.add(post.id);

    try {
      final result = await SupabaseService.markPostViewed(
        postId: post.id,
        username: _profileUsername,
      );
      if (!mounted) return;
      final serverViews = int.tryParse((result['views'] ?? post.views).toString()) ?? post.views;
      setState(() {
        _updateLoadedPostInteraction(post.id, views: serverViews);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _updateLoadedPostInteraction(post.id, views: post.views + 1);
      });
    } finally {
      _pendingViewPostIds.remove(post.id);
    }

    await _savePosts();
  }

  Future<void> _openReplies(CityPost post) async {
    // لا ننتظر الشبكة قبل فتح الشاشة؛ هذا كان سبب التأخير والتعليق عند الضغط على التغريدة.
    unawaited(_markPostViewed(post));
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RepliesScreen(
          post: post,
          currentName: _profileName,
          currentUsername: _profileUsername,
          currentAvatarPath: _profileImagePath,
          currentAvatarProvider: _profileImageProvider(_profileImagePath),
          avatarProviderForPath: _profileImageProvider,
          onLike: _toggleLike,
          onFavorite: _toggleFavorite,
          onRepost: _repostPost,
          onShare: _sharePost,
          onChanged: () async {
            if (mounted) setState(() {});
            await _savePosts();
          },
        ),
      ),
    );
    if (!mounted) return;
    await _syncSavedStateFromPrefs(force: true);
    await _loadPosts(reset: false);
    if (mounted) setState(() {});
    await _savePosts();
  }


  Future<void> _openUserProfileByUsername(String username, {String? fallbackName, String? fallbackBio, String? fallbackAvatarPath}) async {
    final target = SupabaseService.displayUsername(username);
    await _loadFollowing();
    List<CityPost> userPosts = _posts.where((p) => SupabaseService.displayUsername(p.username) == target).toList();
    String displayName = fallbackName ?? target;
    String bio = fallbackBio ?? (target == _profileUsername ? _profileBio : 'عضو في مجتمع Respect App');
    String? avatarPath = fallbackAvatarPath;
    String? coverPath;

    try {
      final user = await SupabaseService.getUserByUsername(target);
      if (user != null) {
        displayName = (user['name'] ?? user['profileName'] ?? displayName).toString();
        bio = (user['bio'] ?? bio).toString();
        avatarPath = (user['avatar_url'] ?? user['imagePath'] ?? user['profileImagePath'] ?? avatarPath)?.toString();
        coverPath = (user['cover_url'] ?? user['coverPath'] ?? user['cover_path'])?.toString();
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      final serverPosts = await SupabaseService.getUserPosts(target);
      if (serverPosts.isNotEmpty) {
        userPosts = serverPosts.map((e) {
          final imageUrl = (e['image_url'] ?? '').toString();
          final videoUrl = (e['video_url'] ?? '').toString();
          final postId = (e['id'] ?? DateTime.now().microsecondsSinceEpoch).toString();
          return _applyLocalState(CityPost(
            id: postId,
            user: (e['name'] ?? e['user'] ?? displayName).toString(),
            username: SupabaseService.displayUsername((e['username'] ?? target).toString()),
            text: (e['text'] ?? '').toString(),
            time: _formatPostTime((e['created_at'] ?? e['time'] ?? '').toString()),
            avatarPath: ((e['avatar_url'] ?? e['avatarPath'] ?? avatarPath)?.toString()),
            mediaPath: imageUrl.isNotEmpty ? imageUrl : (videoUrl.isNotEmpty ? videoUrl : null),
            mediaType: imageUrl.isNotEmpty ? CityMediaType.image : (videoUrl.isNotEmpty ? CityMediaType.video : null),
            likes: int.tryParse((e['likes'] ?? 0).toString()) ?? 0,
            reposts: int.tryParse((e['reposts'] ?? 0).toString()) ?? 0,
            shares: int.tryParse((e['shares'] ?? 0).toString()) ?? 0,
            views: int.tryParse((e['views'] ?? 0).toString()) ?? 0,
            replies: (e['replies'] is List)
                ? (e['replies'] as List).whereType<Map>().map((r) => CityReply.fromJson(r.map((k, v) => MapEntry(k.toString(), v)))).toList()
                : <CityReply>[],
            isReposted: _repostedPostIds.contains(postId),
          ));
        }).toList();
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserProfileViewScreen(
      user: displayName,
      username: target,
      bio: bio,
      avatarPath: avatarPath,
      coverPath: coverPath,
      posts: userPosts,
      currentUsername: _profileUsername,
      following: _following,
      notificationTargets: _postNotificationTargets,
      onToggleFollow: _toggleFollowUser,
      onTogglePostNotification: _togglePostNotificationForUser,
      onEditPost: _editPostFromProfile,
      onDeletePost: _deletePostFromProfile,
      onMentionTap: (u) => _openUserProfileByUsername(u),
    )));
    if (mounted) {
      await _loadProfile();
      await _loadPosts();
      await _loadFollowing();
    }
  }

  Future<void> _editPostFromProfile(CityPost post, String newText) async {
    final text = newText.trim();
    if (text.isEmpty) return;
    _editedPostTexts[post.id] = text;
    setState(() {
      final index = _posts.indexWhere((p) => p.id == post.id);
      if (index >= 0) {
        _posts[index] = CityPost(
          id: post.id,
          user: post.user,
          username: post.username,
          text: text,
          time: post.time,
          avatarPath: post.avatarPath,
          mediaPath: post.mediaPath,
          mediaType: post.mediaType,
          voicePath: post.voicePath,
          voiceSeconds: post.voiceSeconds,
          replies: List<CityReply>.from(post.replies),
          likes: post.likes,
          reposts: post.reposts,
          shares: post.shares,
          views: post.views,
          isLiked: post.isLiked,
          isFavorite: post.isFavorite,
          isReposted: post.isReposted,
          quotedPost: post.quotedPost,
        );
      }
    });
    try { await SupabaseService.updatePostText(postId: post.id, text: text); } catch (e, st) { _logIgnoredError(e, st); }
    await _savePosts();
    await _loadPosts();
  }

  Future<void> _deletePostFromProfile(CityPost post) async {
    _deletedPostIds.add(post.id);
    _editedPostTexts.remove(post.id);
    _localQuotePosts.removeWhere((p) => p.id == post.id || p.quotedPost?.id == post.id);
    setState(() => _posts.removeWhere((p) => p.id == post.id || p.quotedPost?.id == post.id));
    await _savePosts();
    try { await SupabaseService.deletePost(post.id); } catch (e, st) { _logIgnoredError(e, st); }
    if (!mounted) return;
    await _loadPosts();
  }

  Future<void> _editOwnPostFromFeed(CityPost post) async {
    final editedPost = await Navigator.of(context).push<CityPost>(
      MaterialPageRoute(
        builder: (_) => ComposePostScreen(
          profileName: _profileName,
          username: _profileUsername,
          profileImagePath: _profileImagePath,
          initialText: post.text,
          editMode: true,
        ),
      ),
    );

    final text = editedPost?.text.trim() ?? '';
    if (text.isEmpty || text == post.text.trim()) return;
    await _editPostFromProfile(post, text);
    if (!mounted) return;
    NotificationService.showTopNotification('تم تعديل التغريدة');
  }

  Future<void> _deleteOwnPostFromFeed(CityPost post) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).brightness == Brightness.dark ? AppColors.darkCard : AppColors.lightCard,
        title: const Text('حذف التغريدة', style: TextStyle(fontWeight: FontWeight.w900)),
        content: const Text('هل تريد حذف هذه التغريدة نهائيًا؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true) return;
    await _deletePostFromProfile(post);
    if (!mounted) return;
    NotificationService.showTopNotification('تم حذف التغريدة');
  }

  void _openAuthorProfile(CityPost post) {
    _openUserProfileByUsername(
      post.username,
      fallbackName: post.user,
      fallbackBio: post.username == _profileUsername ? _profileBio : 'عضو في مجتمع Respect App',
      fallbackAvatarPath: post.avatarPath,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final followedCommunities = _communities.where((c) => c.members.contains(_profileUsername)).toList();
    // ترتيب إجباري RTL مثل X:
    // لك أقصى اليمين، المتابَعين بالوسط، تبويبات المجتمعات المتابعة بعدها،
    // وتبويب المجتمعات العام أقصى اليسار.
    final tabs = <Widget>[
      const Tab(text: 'لك'),
      const Tab(text: 'المتابَعين'),
      ...followedCommunities.map((c) => Tab(text: c.name)),
      const Tab(text: 'المجتمعات'),
    ];

    final pages = <Widget>[
      _PostsList(
        scrollController: _forYouScrollController,
        posts: _visiblePosts,
        emptyText: 'لا توجد تغريدات بعد',
        isDark: isDark,
        refreshAvatars: _showRefreshAvatars ? _refreshAvatars : const [],
        onRefresh: _refreshFeed,
        onRefreshAvatarTap: (_) => _scrollToTop(_forYouScrollController),
        avatarProviderForPath: _profileImageProvider,
        onLike: _toggleLike,
        onFavorite: _toggleFavorite,
        onRepost: _repostPost,
        onShare: _sharePost,
        onMediaTap: _openMedia,
        onReplies: _openReplies,
        onViewed: _markPostViewed,
        onQuotedPostTap: _openQuotedPost,
        onMentionTap: (u) => _openUserProfileByUsername(u),
        activeStoriesByUser: _activeStoriesByUser,
        seenStoryIds: _seenStoryIds,
        onStoryTap: _openStoriesForUsername,
        onAuthorTap: _openAuthorProfile,
        onMore: _showPostActions,
        isLoadingMore: _loadingMorePosts,
        hasMore: _hasMorePosts,
        onLoadMore: _loadMorePosts,
      ),
      _PostsList(
        scrollController: _followingScrollController,
        posts: _followingPosts,
        emptyText: 'لا توجد تغريدات من المتابَعين',
        isDark: isDark,
        refreshAvatars: _showRefreshAvatars ? _refreshAvatars : const [],
        onRefresh: _refreshFeed,
        onRefreshAvatarTap: (_) => _scrollToTop(_followingScrollController),
        avatarProviderForPath: _profileImageProvider,
        onLike: _toggleLike,
        onFavorite: _toggleFavorite,
        onRepost: _repostPost,
        onShare: _sharePost,
        onMediaTap: _openMedia,
        onReplies: _openReplies,
        onViewed: _markPostViewed,
        onQuotedPostTap: _openQuotedPost,
        onMentionTap: (u) => _openUserProfileByUsername(u),
        activeStoriesByUser: _activeStoriesByUser,
        seenStoryIds: _seenStoryIds,
        onStoryTap: _openStoriesForUsername,
        onAuthorTap: _openAuthorProfile,
        onMore: _showPostActions,
        isLoadingMore: _loadingMorePosts,
        hasMore: _hasMorePosts,
        onLoadMore: _loadMorePosts,
      ),
      ...followedCommunities.map((c) {
        final mode = _communitySortModes[c.id] ?? 'latest';
        final posts = List<CityPost>.from(c.posts)
          ..sort((a, b) {
            if (a.pinnedInCommunity != b.pinnedInCommunity) {
              return a.pinnedInCommunity ? -1 : 1;
            }
            return mode == 'likes' ? b.likes.compareTo(a.likes) : b.id.compareTo(a.id);
          });
        return _CommunityQuickTab(
          community: c,
          posts: posts,
          sortMode: mode,
          onSortChanged: (value) => setState(() => _communitySortModes[c.id] = value),
          onOpenCommunity: () => _openCommunity(c),
          onRefresh: _refreshFeed,
          avatarProviderForPath: _profileImageProvider,
          onLike: _toggleLike,
          onFavorite: _toggleFavorite,
          onRepost: _repostPost,
          onShare: _sharePost,
          onMediaTap: _openMedia,
          onReplies: _openReplies,
          onViewed: _markPostViewed,
          onQuotedPostTap: _openQuotedPost,
          onMentionTap: (u) => _openUserProfileByUsername(u),
          onAuthorTap: _openAuthorProfile,
          onMore: (post) => _showCommunityQuickPostActions(c, post),
        );
      }),
      _CommunitiesTab(
        communities: _communities,
        currentUsername: _profileUsername,
        isDark: isDark,
        onRefresh: _refreshFeed,
        onCreate: _createCommunity,
        onOpen: _openCommunity,
      ),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: null,
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButton: DragTarget<String>(
          onWillAccept: (text) => (text ?? '').trim().isNotEmpty,
          onAccept: (text) {
            HapticFeedback.heavyImpact();
            _openCompose(initialText: text);
          },
          builder: (context, candidateData, rejectedData) {
            final hovering = candidateData.isNotEmpty;
            return AnimatedScale(
              scale: hovering ? 1.10 : 1.0,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutBack,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: hovering
                      ? [
                    BoxShadow(
                      color: AppColors.purple.withValues(alpha: 0.42),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ]
                      : const [],
                ),
                child: FloatingActionButton.extended(
                  heroTag: 'feed_compose_fab',
                  backgroundColor: hovering ? Colors.white : AppColors.purple,
                  foregroundColor: hovering ? AppColors.purple : Colors.white,
                  elevation: hovering ? 16 : 10,
                  onPressed: () => _openCompose(),
                  icon: Icon(hovering ? Icons.content_paste_go_rounded : Icons.edit_rounded),
                  label: Text(
                    hovering ? 'إفلات للصق' : 'نشر',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            );
          },
        ),
        body: Directionality(
          textDirection: TextDirection.rtl,
          child: Column(
            children: [
              // ===== إضافة التبويبات هنا بدلاً من AppBar =====
              Container(
                color: isDark ? AppColors.darkBg : AppColors.lightBg,
                padding: const EdgeInsets.only(top: 8), // تبعد قليلاً عن الحافة
                child: TabBar(
                  isScrollable: true,
                  labelColor: AppColors.purple,
                  unselectedLabelColor: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                  indicatorColor: AppColors.purple,
                  indicatorWeight: 3,
                  tabs: tabs,
                ),
              ),
              // ==============================================
              if (_publishingPost)
                _PublishProgressBar(
                  progress: _publishProgress,
                  status: _publishStatus,
                  isDark: isDark,
                ),
              Expanded(child: TabBarView(children: pages)),
            ],
          ),
        ),
      ),
    );
  }
}


class _PublishProgressBar extends StatelessWidget {
  final double progress;
  final String status;
  final bool isDark;

  const _PublishProgressBar({
    required this.progress,
    required this.status,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).clamp(0, 100).round();
    return Material(
      color: isDark ? AppColors.darkCard : AppColors.lightCard,
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.purple),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    status.trim().isEmpty ? 'جاري نشر التغريدة...' : status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12.5),
                  ),
                ),
                Text('$pct%', style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900)),
              ],
            ),
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: progress <= 0 ? null : progress,
                color: AppColors.purple,
                backgroundColor: AppColors.purple.withValues(alpha: isDark ? 0.20 : 0.14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _PostsList extends StatelessWidget {
  final ScrollController? scrollController;
  final List<CityPost> posts;
  final String emptyText;
  final bool isDark;
  final ImageProvider? Function(String? path) avatarProviderForPath;
  final List<Map<String, String>> refreshAvatars;
  final Future<void> Function() onRefresh;
  final void Function(String postId)? onRefreshAvatarTap;
  final Future<void> Function(CityPost post) onLike;
  final Future<void> Function(CityPost post) onFavorite;
  final Future<void> Function(CityPost post) onRepost;
  final Future<void> Function(CityPost post) onShare;
  final void Function(CityPost post) onMediaTap;
  final Future<void> Function(CityPost post) onReplies;
  final Future<void> Function(CityPost post)? onViewed;
  final Future<void> Function(CityPost post)? onQuotedPostTap;
  final Future<void> Function(String username)? onMentionTap;
  final Map<String, List<Map<String, dynamic>>> activeStoriesByUser;
  final Set<String> seenStoryIds;
  final Future<void> Function(String username)? onStoryTap;
  final void Function(CityPost post) onAuthorTap;
  final Future<void> Function(CityPost post)? onMore;
  final bool isLoadingMore;
  final bool hasMore;
  final Future<void> Function()? onLoadMore;

  const _PostsList({
    this.scrollController,
    required this.posts,
    required this.emptyText,
    required this.isDark,
    required this.avatarProviderForPath,
    required this.refreshAvatars,
    required this.onRefresh,
    this.onRefreshAvatarTap,
    required this.onLike,
    required this.onFavorite,
    required this.onRepost,
    required this.onShare,
    required this.onMediaTap,
    required this.onReplies,
    this.onViewed,
    this.onQuotedPostTap,
    this.onMentionTap,
    this.activeStoriesByUser = const <String, List<Map<String, dynamic>>>{},
    this.seenStoryIds = const <String>{},
    this.onStoryTap,
    required this.onAuthorTap,
    this.onMore,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    Widget overlay() {
      if (refreshAvatars.isEmpty) return const SizedBox.shrink();
      return Positioned(
        top: 10,
        left: 0,
        right: 0,
        child: IgnorePointer(
          ignoring: false,
          child: Center(
            child: _RefreshAvatarsStrip(
              items: refreshAvatars,
              avatarProviderForPath: avatarProviderForPath,
              onAvatarTap: onRefreshAvatarTap,
            ),
          ),
        ),
      );
    }

    if (posts.isEmpty) {
      return Stack(
        children: [
          RefreshIndicator(
            color: AppColors.purple,
            onRefresh: onRefresh,
            child: ListView(
              controller: scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 120),
                Icon(Icons.public_rounded, size: 76, color: AppColors.purple.withValues(alpha: 0.9)),
                const SizedBox(height: 14),
                Center(child: Text(emptyText, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
                const SizedBox(height: 6),
                Text(
                  hasMore ? 'نحمّل التغريدات المناسبة تدريجيًا بدون ضغط على التطبيق' : 'اضغط زر نشر واكتب أول تغريدة في المجتمع',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                ),
                if (hasMore) ...[
                  const SizedBox(height: 18),
                  Center(
                    child: isLoadingMore
                        ? const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.6, color: AppColors.purple),
                    )
                        : FilledButton.icon(
                      onPressed: onLoadMore,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      label: const Text('تحميل المزيد'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          overlay(),
        ],
      );
    }

    return Stack(
      children: [
        RefreshIndicator(
          color: AppColors.purple,
          onRefresh: onRefresh,
          child: ListView.builder(
            controller: scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            cacheExtent: 280,
            addAutomaticKeepAlives: false,
            addSemanticIndexes: false,
            addRepaintBoundaries: true,
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
            itemCount: posts.length + ((isLoadingMore || hasMore) ? 1 : 0),
            itemBuilder: (context, i) {
              if (i >= posts.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  child: Center(
                    child: isLoadingMore
                        ? const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.6, color: AppColors.purple),
                    )
                        : Text(
                      hasMore ? 'جاري تجهيز المزيد...' : 'وصلت للنهاية',
                      style: TextStyle(
                        color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                );
              }
              final post = posts[i];
              final activeStories = activeStoriesByUser[SupabaseService.displayUsername(post.username)];
              final storyIds = (activeStories ?? const <Map<String, dynamic>>[])
                  .map((e) => (e['id'] ?? '').toString().trim())
                  .where((id) => id.isNotEmpty)
                  .toSet();
              final storiesSeen = storyIds.isNotEmpty && storyIds.every(seenStoryIds.contains);
              return _PostCard(
                post: post,
                avatarProvider: avatarProviderForPath(post.avatarPath),
                onLike: () => onLike(post),
                onFavorite: () => onFavorite(post),
                onRepost: () => onRepost(post),
                onShare: () => onShare(post),
                onMediaTap: () => onMediaTap(post),
                onReplies: () => onReplies(post),
                onViewed: onViewed == null ? null : () => onViewed!(post),
                onMentionTap: onMentionTap,
                activeStoriesForUser: activeStories,
                storiesSeen: storiesSeen,
                onStoryTap: onStoryTap == null ? null : () => onStoryTap!(post.username),
                onQuoteTap: post.quotedPost == null ? null : () async {
                  if (onQuotedPostTap != null) {
                    await onQuotedPostTap!(post.quotedPost!);
                  } else {
                    await onReplies(post.quotedPost!);
                  }
                },
                onAuthorTap: () => onAuthorTap(post),
                onMore: onMore == null ? null : () => onMore!(post),
              );
            },
          ),
        ),
        overlay(),
      ],
    );
  }
}



class _RefreshAvatarsStrip extends StatelessWidget {
  final List<Map<String, String>> items;
  final ImageProvider? Function(String? path) avatarProviderForPath;
  final void Function(String postId)? onAvatarTap;

  const _RefreshAvatarsStrip({required this.items, required this.avatarProviderForPath, this.onAvatarTap});

  @override
  Widget build(BuildContext context) {
    final shown = items.take(3).toList();
    final firstPostId = shown.isNotEmpty ? shown.first['postId'] : null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          if (firstPostId != null && firstPostId.isNotEmpty) onAvatarTap?.call(firstPostId);
        },
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(18, 9, 12, 9),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [
                Color(0xFF7C3AED),
                Color(0xFF4C1D95),
                Color(0xFF24103F),
              ],
            ),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.purple.withValues(alpha: 0.70), width: 1.2),
            boxShadow: [
              BoxShadow(
                color: AppColors.purple.withValues(alpha: 0.42),
                blurRadius: 22,
                spreadRadius: 1,
                offset: const Offset(0, 8),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.rtl,
            children: [
              const Text(
                'تحديث جديد',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: shown.length <= 1 ? 34 : (34 + ((shown.length - 1) * 24)).toDouble(),
                height: 34,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (int i = 0; i < shown.length; i++)
                      PositionedDirectional(
                        start: (i * 24).toDouble(),
                        child: GestureDetector(
                          onTap: () {
                            final postId = shown[i]['postId'];
                            if (postId != null && postId.isNotEmpty) onAvatarTap?.call(postId);
                          },
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: AppColors.purple.withValues(alpha: 0.95), width: 2),
                            ),
                            child: CircleAvatar(
                              radius: 15,
                              backgroundColor: AppColors.purple.withValues(alpha: 0.55),
                              backgroundImage: avatarProviderForPath(shown[i]['avatar']),
                              child: avatarProviderForPath(shown[i]['avatar']) == null
                                  ? const Icon(Icons.person_rounded, size: 17, color: Colors.white)
                                  : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
                ),
                child: const Icon(Icons.keyboard_double_arrow_up_rounded, color: Colors.white, size: 21),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommunityQuickTab extends StatelessWidget {
  final CityCommunity community;
  final List<CityPost> posts;
  final String sortMode;
  final ValueChanged<String> onSortChanged;
  final VoidCallback onOpenCommunity;
  final Future<void> Function() onRefresh;
  final ImageProvider? Function(String? path) avatarProviderForPath;
  final Future<void> Function(CityPost post) onLike;
  final Future<void> Function(CityPost post) onFavorite;
  final Future<void> Function(CityPost post) onRepost;
  final Future<void> Function(CityPost post) onShare;
  final void Function(CityPost post) onMediaTap;
  final Future<void> Function(CityPost post) onReplies;
  final Future<void> Function(CityPost post)? onViewed;
  final Future<void> Function(CityPost post)? onQuotedPostTap;
  final Future<void> Function(String username)? onMentionTap;
  final void Function(CityPost post) onAuthorTap;
  final Future<void> Function(CityPost post)? onMore;
  const _CommunityQuickTab({required this.community, required this.posts, required this.sortMode, required this.onSortChanged, required this.onOpenCommunity, required this.onRefresh, required this.avatarProviderForPath, required this.onLike, required this.onFavorite, required this.onRepost, required this.onShare, required this.onMediaTap, required this.onReplies, this.onViewed, this.onQuotedPostTap, this.onMentionTap, required this.onAuthorTap, this.onMore});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.purple.withValues(alpha: 0.20)))),
          child: Row(
            children: [
              Expanded(child: InkWell(onTap: onOpenCommunity, child: Text('# ${community.name}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)))),
              PopupMenuButton<String>(
                initialValue: sortMode,
                onSelected: onSortChanged,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'latest', child: Text('الأحدث')),
                  PopupMenuItem(value: 'likes', child: Text('الأكثر إعجاباً')),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
                  child: Text(sortMode == 'likes' ? 'الأكثر إعجاباً' : 'الأحدث', style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _PostsList(
            posts: posts,
            emptyText: 'لا توجد تغريدات في هذا المجتمع',
            isDark: isDark,
            refreshAvatars: const [],
            onRefresh: onRefresh,
            avatarProviderForPath: avatarProviderForPath,
            onLike: onLike,
            onFavorite: onFavorite,
            onRepost: onRepost,
            onShare: onShare,
            onMediaTap: onMediaTap,
            onReplies: onReplies,
            onViewed: onViewed,
            onQuotedPostTap: onQuotedPostTap,
            onMentionTap: onMentionTap,
            onAuthorTap: onAuthorTap,
            onMore: onMore,
          ),
        ),
      ],
    );
  }
}

class _CommunitiesTab extends StatelessWidget {
  final List<CityCommunity> communities;
  final String currentUsername;
  final bool isDark;
  final Future<void> Function() onRefresh;
  final VoidCallback onCreate;
  final void Function(CityCommunity community) onOpen;

  const _CommunitiesTab({
    required this.communities,
    required this.currentUsername,
    required this.isDark,
    required this.onRefresh,
    required this.onCreate,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final followed = communities.where((c) => c.members.contains(currentUsername)).toList();
    final others = communities.where((c) => !c.members.contains(currentUsername)).toList();

    return RefreshIndicator(
        color: AppColors.purple,
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 96),
          children: [
            GlassCard(
              onTap: onCreate,
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.16), shape: BoxShape.circle),
                    child: const Icon(Icons.add_rounded, color: AppColors.purple),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('إنشاء مجتمع جديد', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900))),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _CommunitySectionTitle(title: 'المجتمعات التي تتابعها', isDark: isDark),
            const SizedBox(height: 10),
            if (followed.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text('لم تتابع أي مجتمع بعد، ابحث عن مجتمع وتابعه ليظهر هنا.', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
              )
            else
              ...followed.map((c) => _CommunityTile(community: c, currentUsername: currentUsername, isDark: isDark, onOpen: onOpen)),
            const SizedBox(height: 12),
            _CommunitySectionTitle(title: 'كل المجتمعات', isDark: isDark),
            const SizedBox(height: 10),
            if (communities.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 80),
                child: Center(child: Text('لا توجد مجتمعات بعد', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted))),
              )
            else
              ...[...followed, ...others].map((c) => _CommunityTile(community: c, currentUsername: currentUsername, isDark: isDark, onOpen: onOpen)),
          ],
        ));
  }
}

class _CommunitySectionTitle extends StatelessWidget {
  final String title;
  final bool isDark;
  const _CommunitySectionTitle({required this.title, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87));
  }
}

class _CommunityTile extends StatelessWidget {
  final CityCommunity community;
  final String currentUsername;
  final bool isDark;
  final void Function(CityCommunity community) onOpen;

  const _CommunityTile({required this.community, required this.currentUsername, required this.isDark, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final isMod = community.ownerUsername == currentUsername || community.moderators.contains(currentUsername);
    final isFollowing = community.members.contains(currentUsername);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        onTap: () => onOpen(community),
        child: Row(
          children: [
            CircleAvatar(backgroundColor: AppColors.purple, child: Text(community.name.characters.first, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(community.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17))),
                      if (isFollowing) const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 18),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(community.description.isEmpty ? 'مجتمع Respect App' : community.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                  const SizedBox(height: 6),
                  Text('${community.members.length} عضو · ${community.moderators.length} مشرف · ${community.posts.length} تغريدة', style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w800, fontSize: 12)),
                ],
              ),
            ),
            if (isMod) const Padding(padding: EdgeInsetsDirectional.only(start: 8), child: Icon(Icons.verified_user_rounded, color: AppColors.purple)),
          ],
        ),
      ),
    );
  }
}


class CreateCommunityScreen extends StatefulWidget {
  final String ownerUsername;

  const CreateCommunityScreen({
    super.key,
    required this.ownerUsername,
  });

  @override
  State<CreateCommunityScreen> createState() => _CreateCommunityScreenState();
}

class _CreateCommunityScreenState extends State<CreateCommunityScreen> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  final FocusNode _descFocus = FocusNode();
  bool _canCreate = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(_updateCanCreate);
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_updateCanCreate);
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _nameFocus.dispose();
    _descFocus.dispose();
    super.dispose();
  }

  void _updateCanCreate() {
    final next = _nameCtrl.text.trim().isNotEmpty;
    if (next != _canCreate && mounted) {
      setState(() => _canCreate = next);
    }
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      NotificationService.showTopNotification('اكتب اسم المجتمع أولاً');
      return;
    }

    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(
      CityCommunity(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        description: _descCtrl.text.trim(),
        ownerUsername: widget.ownerUsername,
        moderators: [widget.ownerUsername],
        members: [widget.ownerUsername],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('إنشاء مجتمع', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 10),
            child: FilledButton(
              onPressed: _canCreate ? _submit : null,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.purple,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppColors.purple.withValues(alpha: 0.28),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              child: const Text('إنشاء', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: AppColors.purple.withValues(alpha: 0.16),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.groups_2_rounded, color: AppColors.purple, size: 30),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('مجتمع جديد', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                            const SizedBox(height: 4),
                            Text(
                              'أنت المالك وسيتم إضافتك كمشرف تلقائيًا',
                              style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _nameCtrl,
                    focusNode: _nameFocus,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => FocusScope.of(context).requestFocus(_descFocus),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.badge_rounded),
                      hintText: 'اسم المجتمع',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _descCtrl,
                    focusNode: _descFocus,
                    maxLines: 4,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.short_text_rounded),
                      hintText: 'وصف المجتمع',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _canCreate ? _submit : null,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.purple,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('إنشاء المجتمع', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}

class FeedScreenStateHelper {
  static bool _looksLikeVideoPath(String value) {
    final lower = value.trim().split('?').first.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mkv');
  }

  static ImageProvider? profileImageProvider(String? path) {
    final p = path?.trim();
    if (p == null || p.isEmpty) return null;
    // حماية من تمرير رابط فيديو إلى NetworkImage. هذا كان سبب Invalid image data والتعليق عند فتح التغريدة.
    if (_looksLikeVideoPath(p)) return null;
    if (p.startsWith('http://') || p.startsWith('https://')) {
      return NetworkImage(p);
    }
    final file = File(p);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  static String formatPostTime(String raw) {
    if (raw.trim().isEmpty) return 'الآن';
    final date = DateTime.tryParse(raw);
    if (date == null) {
      if (raw == 'الآن' || raw.startsWith('قبل ')) return raw;
      return raw;
    }
    return relativeTime(date.toLocal());
  }

  static String relativeTime(DateTime date) {
    final now = DateTime.now();
    var diff = now.difference(date);
    if (diff.isNegative) diff = Duration.zero;

    if (diff.inSeconds < 45) return 'الآن';
    if (diff.inMinutes < 60) {
      final v = diff.inMinutes;
      return 'قبل $v ${v == 1 ? 'دقيقة' : 'دقائق'}';
    }
    if (diff.inHours < 24) {
      final v = diff.inHours;
      return 'قبل $v ${v == 1 ? 'ساعة' : 'ساعات'}';
    }
    if (diff.inDays < 7) {
      final v = diff.inDays;
      return 'قبل $v ${v == 1 ? 'يوم' : 'أيام'}';
    }
    if (diff.inDays < 30) {
      final v = (diff.inDays / 7).floor().clamp(1, 4);
      return 'قبل $v ${v == 1 ? 'أسبوع' : 'أسابيع'}';
    }
    if (diff.inDays < 365) {
      final v = (diff.inDays / 30).floor().clamp(1, 12);
      return 'قبل $v ${v == 1 ? 'شهر' : 'أشهر'}';
    }
    final v = (diff.inDays / 365).floor().clamp(1, 1000);
    return 'قبل $v ${v == 1 ? 'سنة' : 'سنوات'}';
  }
}

int _replySortValue(CityReply reply) {
  if (reply.sortMillis != null) return reply.sortMillis!;
  if (reply.time.trim() == 'الآن') return DateTime.now().millisecondsSinceEpoch;
  final parsed = DateTime.tryParse(reply.time);
  if (parsed != null) return parsed.toLocal().millisecondsSinceEpoch;
  return 0;
}

List<CityReply> _sortedReplies(Iterable<CityReply> replies) {
  final items = List<CityReply>.from(replies);
  items.sort((a, b) => _replySortValue(b).compareTo(_replySortValue(a)));
  return items;
}

bool _isRespectAiUserName(String username) {
  return SupabaseService.displayUsername(username) == SupabaseService.respectAiUsername;
}

class _RespectAiVerifiedBadge extends StatelessWidget {
  const _RespectAiVerifiedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsetsDirectional.only(start: 4),
      padding: const EdgeInsets.all(2.2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFF7C3AED), Color(0xFFC084FC)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.purple.withValues(alpha: 0.38),
            blurRadius: 8,
            spreadRadius: 0.5,
          ),
        ],
      ),
      child: const Icon(Icons.check_rounded, color: Colors.white, size: 12),
    );
  }
}

class _RespectAuthorName extends StatelessWidget {
  final String name;
  final String username;
  final TextStyle? style;
  final int maxLines;
  final bool verified;

  const _RespectAuthorName({
    required this.name,
    required this.username,
    this.style,
    this.maxLines = 1,
    this.verified = false,
  });

  @override
  Widget build(BuildContext context) {
    final isVerified = verified || _isRespectAiUserName(username);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: name),
          if (isVerified)
            const WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _RespectAiVerifiedBadge(),
            ),
        ],
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: style ?? const TextStyle(fontWeight: FontWeight.w900),
    );
  }
}

class RepliesScreen extends StatefulWidget {
  final CityPost post;
  final String currentName;
  final String currentUsername;
  final String? currentAvatarPath;
  final ImageProvider? currentAvatarProvider;
  final ImageProvider? Function(String? path) avatarProviderForPath;
  final Future<void> Function(CityPost post) onLike;
  final Future<void> Function(CityPost post) onFavorite;
  final Future<void> Function(CityPost post) onRepost;
  final Future<void> Function(CityPost post) onShare;
  final Future<void> Function() onChanged;

  const RepliesScreen({
    super.key,
    required this.post,
    required this.currentName,
    required this.currentUsername,
    required this.currentAvatarPath,
    required this.currentAvatarProvider,
    required this.avatarProviderForPath,
    required this.onLike,
    required this.onFavorite,
    required this.onRepost,
    required this.onShare,
    required this.onChanged,
  });

  @override
  State<RepliesScreen> createState() => _RepliesScreenState();
}

class _RepliesScreenState extends State<RepliesScreen> {
  final TextEditingController _replyCtrl = TextEditingController();
  final FocusNode _replyFocus = FocusNode();
  final ImagePicker _picker = ImagePicker();
  final AudioRecorder _replyRecorder = AudioRecorder();

  bool _sending = false;
  bool _recordingReply = false;
  String? _replyVoicePath;
  int _replyVoiceSeconds = 0;
  Timer? _replyRecordTimer;
  CityReply? _replyingToReply;
  XFile? _selectedMedia;
  CityMediaType? _selectedMediaType;

  final List<CityReply> _replyStack = <CityReply>[];
  final Set<String> _pendingReplyLikeIds = <String>{};
  final Set<String> _pendingReplyRepostIds = <String>{};
  final Set<String> _pendingReplyViewIds = <String>{};

  CityReply? get _openedReply => _replyStack.isEmpty ? null : _replyStack.last;
  bool get _insideReplyThread => _openedReply != null;

  @override
  void initState() {
    super.initState();
    // افتح شاشة التغريدة فورًا، ثم حدّث الردود والعدادات بالخلفية بدون تعليق الواجهة.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_refreshRepliesFromServer().then((_) {
        if (mounted) setState(() {});
      }));
    });
  }

  @override
  void dispose() {
    _replyRecordTimer?.cancel();
    _replyRecorder.dispose();
    _replyFocus.unfocus();
    _replyFocus.dispose();
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickReplyAttachment() async {
    final choice = await showModalBottomSheet<_AttachmentChoice>(
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
                Container(
                  width: 46,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 18),
                const Text('إضافة للرد', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 14),
                _SheetOption(
                  icon: Icons.mic_rounded,
                  title: _recordingReply ? 'إيقاف التسجيل الصوتي' : 'رسالة صوتية',
                  subtitle: _recordingReply ? 'إيقاف التسجيل ثم أرسل الرد' : 'تسجيل صوتية مع الرد',
                  onTap: () => Navigator.pop(context, _AttachmentChoice.audio),
                ),
                const SizedBox(height: 10),
                _SheetOption(
                  icon: Icons.image_rounded,
                  title: 'صورة',
                  subtitle: 'إرفاق صورة مع الرد',
                  onTap: () => Navigator.pop(context, _AttachmentChoice.image),
                ),
                const SizedBox(height: 10),
                _SheetOption(
                  icon: Icons.videocam_rounded,
                  title: 'فيديو',
                  subtitle: 'إرفاق فيديو مع الرد',
                  onTap: () => Navigator.pop(context, _AttachmentChoice.video),
                ),
                const SizedBox(height: 10),
                _SheetOption(
                  icon: Icons.gif_box_rounded,
                  title: 'GIF',
                  subtitle: 'إرفاق GIF مع الرد',
                  onTap: () => Navigator.pop(context, _AttachmentChoice.gif),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (choice == null) return;
    if (choice == _AttachmentChoice.audio) {
      if (_recordingReply) {
        await _stopReplyRecording();
      } else {
        await _startReplyRecording();
      }
      return;
    }
    if (choice == _AttachmentChoice.video) {
      final file = await _picker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      setState(() {
        _selectedMedia = file;
        _selectedMediaType = CityMediaType.video;
      });
    } else {
      final file = await _picker.pickImage(source: ImageSource.gallery, imageQuality: choice == _AttachmentChoice.gif ? null : 85);
      if (file == null) return;
      setState(() {
        _selectedMedia = file;
        _selectedMediaType = choice == _AttachmentChoice.gif ? CityMediaType.gif : CityMediaType.image;
      });
    }
  }


  Future<void> _startReplyRecording() async {
    try {
      final hasPermission = await _replyRecorder.hasPermission();
      if (!hasPermission) {
        NotificationService.showTopError('اسمح للمايك أولاً');
        return;
      }

      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/respect_reply_${DateTime.now().microsecondsSinceEpoch}.m4a';

      await _replyRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 96000,
          sampleRate: 44100,
        ),
        path: path,
      );

      _replyRecordTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _recordingReply = true;
        _replyVoicePath = null;
        _replyVoiceSeconds = 0;
      });

      _replyRecordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _replyVoiceSeconds++);
      });
      NotificationService.showTopNotification('بدأ تسجيل الصوتية');
    } catch (e) {
      assert(() { _scannerSafeIgnore(); return true; }());
      NotificationService.showTopError('تعذر بدء التسجيل');
    }
  }

  Future<void> _stopReplyRecording() async {
    try {
      final path = await _replyRecorder.stop();
      _replyRecordTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _recordingReply = false;
        if (path != null && path.trim().isNotEmpty) {
          _replyVoicePath = path;
        }
      });
      if (path != null && path.trim().isNotEmpty) {
        NotificationService.showTopSuccess('تم حفظ الصوتية، اضغط إرسال');
      }
    } catch (e) {
      assert(() { _scannerSafeIgnore(); return true; }());
      if (mounted) setState(() => _recordingReply = false);
      NotificationService.showTopError('تعذر إيقاف التسجيل');
    }
  }

  bool _isRootReply(CityReply reply) {
    return (reply.parentReplyId ?? '').trim().isEmpty;
  }

  bool _isChildOf(CityReply reply, CityReply parent) {
    return (reply.parentReplyId ?? '').trim() == parent.id;
  }

  List<CityReply> _visibleReplies() {
    final parent = _openedReply;
    final all = _sortedReplies(widget.post.replies);
    if (parent == null) {
      return all.where(_isRootReply).toList();
    }
    return all.where((reply) => _isChildOf(reply, parent)).toList();
  }

  int _childRepliesCount(CityReply parent) {
    return widget.post.replies.where((reply) => _isChildOf(reply, parent)).length;
  }

  CityReply? _findReplyById(String id) {
    final clean = id.trim();
    if (clean.isEmpty) return null;
    for (final reply in widget.post.replies) {
      if (reply.id == clean) return reply;
    }
    return null;
  }

  Future<void> _refreshRepliesFromServer() async {
    try {
      final freshReplies = await SupabaseService
          .getPostReplies(widget.post.id, currentUsername: widget.currentUsername)
          .timeout(const Duration(seconds: 8));

      final fresh = _sortedReplies(freshReplies.map(CityReply.fromJson));
      widget.post.replies
        ..clear()
        ..addAll(fresh);
      widget.post.replyCount = widget.post.replies.length;

      for (var i = 0; i < _replyStack.length; i++) {
        final updated = _findReplyById(_replyStack[i].id);
        if (updated != null) _replyStack[i] = updated;
      }
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _saveReplyNotification(String text) async {
    final target = SupabaseService.displayUsername(widget.post.username);
    final author = SupabaseService.displayUsername(widget.currentUsername);
    if (target == author) return;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('respect_post_events_v1');
    final items = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) items.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    items.insert(0, {
      'id': 'reply_${widget.post.id}_${DateTime.now().microsecondsSinceEpoch}',
      'type': 'reply',
      'targetUsername': target,
      'authorUsername': author,
      'authorName': widget.currentName,
      'postId': widget.post.id,
      'parentReplyId': _replyingToReply?.id,
      'text': text,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString('respect_post_events_v1', jsonEncode(items.take(300).toList()));
  }

  Future<void> _addReply() async {
    if (_sending) return;

    final text = _replyCtrl.text.trim();
    if (_recordingReply) {
      NotificationService.showTopNotification('اضغط إيقاف التسجيل أولًا ثم أرسل الرد');
      return;
    }
    if (text.isEmpty && _selectedMedia == null && _replyVoicePath == null) return;

    FocusScope.of(context).unfocus();

    if (mounted) setState(() => _sending = true);

    final targetReply = _replyingToReply ?? _openedReply;
    final parentReplyId = targetReply?.id;
    final parentUser = targetReply?.user;

    try {
      final now = DateTime.now();
      CityReply reply = CityReply(
        id: 'reply_${widget.post.id}_${now.microsecondsSinceEpoch}',
        user: widget.currentName,
        username: widget.currentUsername,
        text: text,
        time: 'الآن',
        avatarPath: widget.currentAvatarPath,
        parentUser: parentUser,
        parentReplyId: parentReplyId,
        mediaPath: _selectedMedia?.path,
        mediaType: _selectedMediaType,
        voicePath: _replyVoicePath,
        voiceSeconds: _replyVoiceSeconds,
      );

      try {
        final inserted = await SupabaseService.addPostReply(
          postId: widget.post.id,
          authorUsername: widget.currentUsername,
          authorName: widget.currentName,
          text: text,
          parentUser: parentUser,
          parentReplyId: parentReplyId,
          mediaUrl: _replyVoicePath ?? _selectedMedia?.path ?? '',
          mediaType: _replyVoicePath != null ? 'voice' : (_selectedMediaType?.name ?? ''),
        ).timeout(const Duration(seconds: 55));

        reply = CityReply.fromJson(inserted);
      } catch (e) {
        assert(() { _scannerSafeIgnore(); return true; }());
        if (mounted) {
          final msg = e.toString().contains('Respect AI') || e.toString().contains('تم حذف') || e.toString().contains('تم رفض')
              ? e.toString().replaceFirst('Exception: ', '')
              : 'تعذر إرسال الرد على الخادم: $e';
          NotificationService.showTopError(msg);
        }
        return;
      }

      widget.post.replies.add(reply);
      widget.post.replies
        ..clear()
        ..addAll(_sortedReplies(widget.post.replies));
      widget.post.replyCount = widget.post.replies.length;

      // تحديث السيرفر والإشعارات بالخلفية حتى لا يتأخر إرسال الرد.
      unawaited(_refreshRepliesFromServer());
      unawaited(_saveReplyNotification(text));

      // Respect AI: إذا المستخدم منشن @RespectAI داخل الرد، ننشئ ردًا تلقائيًا من الحساب الرسمي.
      if (SupabaseService.hasRespectAiMention(text)) {
        final aiParentReplyId = reply.id;
        final aiParentReplyText = reply.text;
        unawaited(() async {
          try {
            final aiReply = await SupabaseService.createRespectAiReplyIfNeeded(
              postId: widget.post.id,
              triggerText: text,
              askerUsername: widget.currentUsername,
              postText: widget.post.text,
              parentReplyId: aiParentReplyId,
              parentReplyText: aiParentReplyText,
            );

            if (aiReply != null && mounted) {
              await _refreshRepliesFromServer();
              await widget.onChanged();
              NotificationService.showTopSuccess('Respect AI رد على تعليقك');
            }
          } catch (e) {
            assert(() { _scannerSafeIgnore(); return true; }());
            if (mounted) {
              NotificationService.showTopError(e.toString().replaceFirst('Exception: ', ''));
            }
          }
        }());
      }

      _replyCtrl.clear();
      _selectedMedia = null;
      _selectedMediaType = null;
      _replyVoicePath = null;
      _replyVoiceSeconds = 0;
      _replyingToReply = null;

      unawaited(widget.onChanged());

      if (mounted) setState(() => _sending = false);
    } catch (e) {
      assert(() { _scannerSafeIgnore(); return true; }());
      if (mounted) setState(() => _sending = false);
      NotificationService.showTopError('تعذر إرسال الرد');
    }
  }

  void _replyTo(CityReply reply) {
    setState(() {
      final alreadyOpen = _openedReply?.id == reply.id;
      if (!alreadyOpen) {
        _replyStack.add(reply);
      }
      _replyingToReply = reply;
      _replyCtrl.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).requestFocus(_replyFocus);
    });
  }

  Future<void> _markReplyViewed(CityReply reply) async {
    if (_pendingReplyViewIds.contains(reply.id)) return;
    _pendingReplyViewIds.add(reply.id);
    try {
      final result = await SupabaseService.markReplyViewed(
        replyId: reply.id,
        username: widget.currentUsername,
      );
      if (!mounted) return;
      setState(() {
        reply.views = int.tryParse((result['views'] ?? reply.views).toString()) ?? reply.views;
        reply.likes = int.tryParse((result['likes'] ?? reply.likes).toString()) ?? reply.likes;
        reply.reposts = int.tryParse((result['reposts'] ?? reply.reposts).toString()) ?? reply.reposts;
      });
      await widget.onChanged();
    } catch (_) {
      if (mounted) setState(() => reply.views += 1);
    } finally {
      _pendingReplyViewIds.remove(reply.id);
    }
  }

  void _openReplyThread(CityReply reply) {
    setState(() {
      if (_openedReply?.id != reply.id) {
        _replyStack.add(reply);
      }
      _replyingToReply = reply;
      _replyCtrl.clear();
    });
    unawaited(_markReplyViewed(reply));
  }

  Future<bool> _handleBack() async {
    if (_replyStack.isNotEmpty) {
      setState(() {
        _replyStack.removeLast();
        _replyingToReply = _openedReply;
        _replyCtrl.clear();
      });
      return false;
    }
    return true;
  }


  Future<void> _toggleReplyLike(CityReply reply) async {
    if (_pendingReplyLikeIds.contains(reply.id)) return;
    _pendingReplyLikeIds.add(reply.id);

    final previousLiked = reply.isLiked;
    final previousLikes = reply.likes;
    final nextLiked = !previousLiked;
    final nextLikes = (previousLikes + (nextLiked ? 1 : -1)).clamp(0, 1 << 30).toInt();

    setState(() {
      reply.isLiked = nextLiked;
      reply.likes = nextLikes;
    });

    try {
      final result = await SupabaseService.toggleReplyLike(
        replyId: reply.id,
        username: widget.currentUsername,
      );
      if (!mounted) return;
      setState(() {
        reply.isLiked = result['isLiked'] == true;
        reply.likes = int.tryParse((result['likes'] ?? reply.likes).toString()) ?? reply.likes;
        reply.reposts = int.tryParse((result['reposts'] ?? reply.reposts).toString()) ?? reply.reposts;
        reply.views = int.tryParse((result['views'] ?? reply.views).toString()) ?? reply.views;
      });
      await widget.onChanged();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        reply.isLiked = previousLiked;
        reply.likes = previousLikes;
      });
      NotificationService.showTopError('تعذر تحديث لايك الرد');
    } finally {
      _pendingReplyLikeIds.remove(reply.id);
    }
  }

  void _toggleReplySave(CityReply reply) {
    setState(() => reply.isFavorite = !reply.isFavorite);
    NotificationService.showTopNotification(reply.isFavorite ? 'تم حفظ الرد' : 'تمت إزالة الرد من المحفوظات');
    unawaited(widget.onChanged());
  }

  Future<void> _repostReply(CityReply reply) async {
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
            border: Border.all(
              color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 46,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: Icon(
                    Icons.repeat_rounded,
                    color: reply.isReposted ? AppColors.purple : AppColors.purple,
                  ),
                  title: Text(
                    reply.isReposted ? 'إلغاء إعادة النشر' : 'إعادة نشر الرد',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    'إظهار الرد لمتابعيك',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(context, 'repost'),
                ),
                ListTile(
                  leading: const Icon(Icons.format_quote_rounded, color: AppColors.purple),
                  title: const Text('اقتباس الرد', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text(
                    'اكتب تغريدة مقتبسة من هذا الرد',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(context, 'quote'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (action == 'quote') {
      NotificationService.showTopNotification('تم اختيار اقتباس الرد');
      return;
    }

    if (action != 'repost') return;
    if (_pendingReplyRepostIds.contains(reply.id)) return;
    _pendingReplyRepostIds.add(reply.id);

    final previousReposted = reply.isReposted;
    final previousReposts = reply.reposts;

    setState(() {
      reply.isReposted = !reply.isReposted;
      reply.reposts = (reply.reposts + (reply.isReposted ? 1 : -1)).clamp(0, 1 << 30).toInt();
    });

    try {
      final result = await SupabaseService.toggleReplyRepost(
        replyId: reply.id,
        username: widget.currentUsername,
      );

      if (!mounted) return;
      setState(() {
        reply.isReposted = result['isReposted'] == true;
        reply.likes = int.tryParse((result['likes'] ?? reply.likes).toString()) ?? reply.likes;
        reply.reposts = int.tryParse((result['reposts'] ?? reply.reposts).toString()) ?? reply.reposts;
        reply.views = int.tryParse((result['views'] ?? reply.views).toString()) ?? reply.views;
      });

      await widget.onChanged();
      NotificationService.showTopNotification(
        reply.isReposted ? 'تمت إعادة نشر الرد' : 'تم إلغاء إعادة نشر الرد',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        reply.isReposted = previousReposted;
        reply.reposts = previousReposts;
      });
      NotificationService.showTopError('تعذر حفظ إعادة نشر الرد في السيرفر: $e');
    } finally {
      _pendingReplyRepostIds.remove(reply.id);
    }
  }

  String _countText(int value) => value <= 0 ? '' : value.toString();

  Widget _buildReplyThreadHeader(bool isDark) {
    final opened = _openedReply;
    if (opened == null) {
      return _PostDetailsHeader(
        post: widget.post,
        avatarProvider: widget.avatarProviderForPath(widget.post.avatarPath),
        onLike: () {
          widget.onLike(widget.post).then((_) {
            if (mounted) setState(() {});
          });
        },
        onFavorite: () {
          widget.onFavorite(widget.post).then((_) {
            if (mounted) setState(() {});
          });
        },
        onRepost: () {
          widget.onRepost(widget.post).then((_) {
            if (mounted) setState(() {});
          });
        },
        onShare: () => widget.onShare(widget.post),
      );
    }

    final children = _childRepliesCount(opened);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      borderRadius: BorderRadius.circular(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProfileAvatar(radius: 24, imageProvider: widget.avatarProviderForPath(opened.avatarPath)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(opened.user, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                    Text(opened.username, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                  ],
                ),
              ),
            ],
          ),
          if ((opened.parentUser?.trim().isNotEmpty ?? false)) ...[
            const SizedBox(height: 8),
            Text('ردًا على ${opened.parentUser}', style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w800)),
          ],
          if (opened.text.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            _MentionText(opened.text, style: const TextStyle(fontSize: 18, height: 1.45), onMentionTap: (u) async {}),
          ],
          if ((opened.mediaPath ?? '').trim().isNotEmpty && opened.mediaType != null) ...[
            const SizedBox(height: 12),
            _PostMedia(path: opened.mediaPath!, type: opened.mediaType!),
          ],
          if ((opened.voicePath ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            _VoiceBubble(path: opened.voicePath!, durationText: _PostCard._formatStaticSeconds(opened.voiceSeconds)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Flexible(
                child: Text(
                  opened.time,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _TweetActionRow(
            isDark: isDark,
            liked: opened.isLiked,
            saved: opened.isFavorite,
            reposted: opened.isReposted,
            likes: opened.likes,
            replies: children,
            reposts: opened.reposts,
            views: opened.views,
            onReply: () => _replyTo(opened),
            onLike: () => _toggleReplyLike(opened),
            onRepost: () => _repostReply(opened),
            onSave: () => _toggleReplySave(opened),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyCard(CityReply r, bool isDark) {
    final children = _childRepliesCount(r);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => _openReplyThread(r),
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkCard : AppColors.lightCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProfileAvatar(radius: 18, imageProvider: widget.avatarProviderForPath(r.avatarPath)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _RespectAuthorName(
                          name: r.user,
                          username: r.username,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        Text(r.username, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontSize: 12)),
                        Text(r.time, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontSize: 11)),
                      ],
                    ),
                    if ((r.parentUser?.trim().isNotEmpty ?? false)) ...[
                      const SizedBox(height: 4),
                      Text('ردًا على ${r.parentUser}', style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w700, fontSize: 12)),
                    ],
                    if (r.text.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(r.text),
                    ],
                    if ((r.mediaPath ?? '').trim().isNotEmpty && r.mediaType != null) ...[
                      const SizedBox(height: 10),
                      _PostMedia(path: r.mediaPath!, type: r.mediaType!),
                    ],
                    if ((r.voicePath ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _VoiceBubble(path: r.voicePath!, durationText: _PostCard._formatStaticSeconds(r.voiceSeconds)),
                    ],
                    const SizedBox(height: 8),
                    _TweetActionRow(
                      isDark: isDark,
                      liked: r.isLiked,
                      saved: r.isFavorite,
                      reposted: r.isReposted,
                      likes: r.likes,
                      replies: children,
                      reposts: r.reposts,
                      views: r.views,
                      onReply: () => _replyTo(r),
                      onLike: () => _toggleReplyLike(r),
                      onRepost: () => _repostReply(r),
                      onSave: () => _toggleReplySave(r),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final visibleReplies = _visibleReplies();
    final targetName = (_replyingToReply ?? _openedReply)?.user;

    return WillPopScope(
      onWillPop: _handleBack,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          leading: _replyStack.isEmpty
              ? null
              : IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => _handleBack(),
          ),
          title: Text(
            _insideReplyThread ? 'ردود الرد' : 'التغريدة',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    await _refreshRepliesFromServer();
                    if (mounted) setState(() {});
                  },
                  child: ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    children: [
                      _buildReplyThreadHeader(isDark),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(
                            _insideReplyThread ? 'الردود على هذا الرد' : 'الردود',
                            style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87),
                          ),
                          const Spacer(),
                          Text(
                            '${visibleReplies.length}',
                            style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (visibleReplies.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text(
                              _insideReplyThread ? 'لا توجد ردود على هذا الرد بعد' : 'لا توجد ردود بعد',
                              style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                            ),
                          ),
                        )
                      else
                        ...visibleReplies.map((r) => _buildReplyCard(r, isDark)),
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkBg : AppColors.lightBg,
                  border: Border(top: BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (targetName != null && targetName.trim().isNotEmpty) ...[
                      Row(
                        children: [
                          Expanded(child: Text('ردًا على $targetName', style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w800))),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: () => setState(() => _replyingToReply = _openedReply),
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                        ],
                      ),
                    ],
                    if (_recordingReply || _replyVoicePath != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.purple.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.purple.withValues(alpha: 0.22)),
                        ),
                        child: Row(
                          children: [
                            Icon(_recordingReply ? Icons.fiber_manual_record_rounded : Icons.mic_rounded, color: _recordingReply ? AppColors.danger : AppColors.purple, size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_recordingReply ? 'جاري التسجيل $_replyVoiceSeconds ث' : 'صوتية جاهزة $_replyVoiceSeconds ث', style: const TextStyle(fontWeight: FontWeight.w800))),
                            if (_recordingReply)
                              TextButton(onPressed: _stopReplyRecording, child: const Text('إيقاف'))
                            else
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                onPressed: () => setState(() { _replyVoicePath = null; _replyVoiceSeconds = 0; }),
                                icon: const Icon(Icons.close_rounded, size: 18),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    if (_selectedMedia != null && _selectedMediaType != null) ...[
                      SizedBox(
                        height: 86,
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: _selectedMediaType == CityMediaType.video
                                  ? Container(
                                width: 130,
                                height: 80,
                                color: Colors.black26,
                                child: const Icon(Icons.videocam_rounded, color: AppColors.purple),
                              )
                                  : Image.file(File(_selectedMedia?.path ?? ''), width: 130, height: 80, fit: BoxFit.cover),
                            ),
                            PositionedDirectional(
                              top: 4,
                              end: 4,
                              child: InkWell(
                                onTap: () => setState(() { _selectedMedia = null; _selectedMediaType = null; }),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                  child: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    Row(
                      children: [
                        _SmallPurpleAction(icon: Icons.add_rounded, tooltip: 'صوت / صورة / فيديو', onTap: _pickReplyAttachment),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _replyCtrl,
                            focusNode: _replyFocus,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _addReply(),
                            decoration: InputDecoration(
                              hintText: targetName == null ? 'اكتب رد...' : 'اكتب ردك على $targetName...',
                              filled: true,
                              fillColor: isDark ? AppColors.darkCard : AppColors.lightCard,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        CircleAvatar(
                          backgroundColor: AppColors.purple,
                          child: IconButton(
                            onPressed: _sending ? null : _addReply,
                            icon: _sending
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.send_rounded, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}



class _TweetActionRow extends StatelessWidget {
  final bool isDark;
  final bool liked;
  final bool saved;
  final bool reposted;
  final int likes;
  final int replies;
  final int reposts;
  final int views;
  final VoidCallback onReply;
  final VoidCallback onLike;
  final VoidCallback onRepost;
  final VoidCallback onSave;
  final VoidCallback? onShare;

  const _TweetActionRow({
    required this.isDark,
    required this.liked,
    required this.saved,
    required this.reposted,
    required this.likes,
    required this.replies,
    required this.reposts,
    required this.views,
    required this.onReply,
    required this.onLike,
    required this.onRepost,
    required this.onSave,
    this.onShare,
  });

  String _label(int value) => value <= 0 ? '' : value.toString();

  @override
  Widget build(BuildContext context) {
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _LuxuryActionButton(
          icon: Icons.forum_outlined,
          activeIcon: Icons.forum_rounded,
          onTap: onReply,
          color: muted,
          activeColor: AppColors.purple,
          count: _label(replies),
          isActive: replies > 0,
          isDark: isDark,
        ),
        _LuxuryActionButton(
          icon: Icons.cached_rounded,
          activeIcon: Icons.autorenew_rounded,
          onTap: onRepost,
          color: muted,
          activeColor: AppColors.success,
          count: _label(reposts),
          isActive: reposted,
          isDark: isDark,
          rotateOnTap: true,
        ),
        _LuxuryActionButton(
          icon: Icons.favorite_border_rounded,
          activeIcon: Icons.favorite_rounded,
          onTap: onLike,
          color: muted,
          activeColor: AppColors.danger,
          count: _label(likes),
          isActive: liked,
          isDark: isDark,
          heartBurst: true,
        ),
        _LuxuryActionButton(
          icon: Icons.bookmark_add_outlined,
          activeIcon: Icons.bookmark_added_rounded,
          onTap: onSave,
          color: muted,
          activeColor: AppColors.purple,
          isActive: saved,
          isDark: isDark,
        ),
        _LuxuryActionButton(
          icon: Icons.remove_red_eye_outlined,
          activeIcon: Icons.visibility_rounded,
          onTap: () {},
          color: muted,
          activeColor: AppColors.purple,
          count: _label(views),
          isActive: views > 0,
          isDark: isDark,
          passive: true,
        ),
      ],
    );
  }
}

class _LuxuryActionButton extends StatefulWidget {
  final IconData icon;
  final IconData activeIcon;
  final VoidCallback onTap;
  final Color color;
  final Color activeColor;
  final String? count;
  final bool isActive;
  final bool isDark;
  final bool heartBurst;
  final bool rotateOnTap;
  final bool passive;

  const _LuxuryActionButton({
    required this.icon,
    required this.activeIcon,
    required this.onTap,
    required this.color,
    required this.activeColor,
    required this.isActive,
    required this.isDark,
    this.count,
    this.heartBurst = false,
    this.rotateOnTap = false,
    this.passive = false,
  });

  @override
  State<_LuxuryActionButton> createState() => _LuxuryActionButtonState();
}

class _LuxuryActionButtonState extends State<_LuxuryActionButton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _rotation;
  bool _showBurst = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 430),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.34).chain(CurveTween(curve: Curves.easeOutBack)), weight: 45),
      TweenSequenceItem(tween: Tween(begin: 1.34, end: 1.0).chain(CurveTween(curve: Curves.easeOutCubic)), weight: 55),
    ]).animate(_controller);
    _rotation = Tween<double>(begin: 0, end: 0.92).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_controller);
  }

  @override
  void didUpdateWidget(covariant _LuxuryActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.heartBurst && !oldWidget.isActive && widget.isActive) {
      _playBurst();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _playBurst() {
    if (!mounted) return;
    setState(() => _showBurst = true);
    _controller
      ..reset()
      ..forward();
    Future<void>.delayed(const Duration(milliseconds: 620), () {
      if (mounted) setState(() => _showBurst = false);
    });
  }

  void _handleTap() {
    HapticFeedback.selectionClick();
    if (!widget.passive) {
      _controller
        ..reset()
        ..forward();
      if (widget.heartBurst) {
        setState(() => _showBurst = true);
        Future<void>.delayed(const Duration(milliseconds: 620), () {
          if (mounted) setState(() => _showBurst = false);
        });
      }
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.isActive;
    final color = active ? widget.activeColor : widget.color;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: const BoxDecoration(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  if (_showBurst && widget.heartBurst) ...[
                    _HeartSpark(offset: const Offset(-15, -14), delay: 0, color: widget.activeColor),
                    _HeartSpark(offset: const Offset(15, -13), delay: 80, color: widget.activeColor),
                    _HeartSpark(offset: const Offset(-12, 13), delay: 120, color: widget.activeColor),
                    _HeartSpark(offset: const Offset(14, 12), delay: 40, color: widget.activeColor),
                    Positioned(
                      child: IgnorePointer(
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: widget.activeColor.withValues(alpha: 0.45), width: 1.4),
                          ),
                        )
                            .animate(key: ValueKey('ring_${DateTime.now().microsecondsSinceEpoch}'))
                            .scale(begin: const Offset(0.55, 0.55), end: const Offset(1.35, 1.35), duration: 460.ms, curve: Curves.easeOutCubic)
                            .fadeOut(duration: 420.ms),
                      ),
                    ),
                  ],
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      final turns = widget.rotateOnTap ? _rotation.value : 0.0;
                      return Transform.rotate(
                        angle: turns,
                        child: Transform.scale(
                          scale: _scale.value,
                          child: child,
                        ),
                      );
                    },
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 190),
                      transitionBuilder: (child, animation) => ScaleTransition(
                        scale: animation,
                        child: FadeTransition(opacity: animation, child: child),
                      ),
                      child: Icon(
                        active ? widget.activeIcon : widget.icon,
                        key: ValueKey('${widget.icon.codePoint}_${active}_${widget.count ?? ''}'),
                        size: 20,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if ((widget.count ?? '').isNotEmpty) ...[
              const SizedBox(width: 5),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: animation, child: child),
                ),
                child: Text(
                  widget.count!,
                  key: ValueKey(widget.count),
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                    letterSpacing: 0.15,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeartSpark extends StatelessWidget {
  final Offset offset;
  final int delay;
  final Color color;

  const _HeartSpark({
    required this.offset,
    required this.delay,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      child: Icon(Icons.favorite_rounded, size: 8, color: color)
          .animate(delay: Duration(milliseconds: delay))
          .move(begin: Offset.zero, end: offset, duration: 520.ms, curve: Curves.easeOutCubic)
          .scale(begin: const Offset(0.35, 0.35), end: const Offset(1, 1), duration: 320.ms, curve: Curves.easeOutBack)
          .fadeOut(delay: 190.ms, duration: 330.ms),
    );
  }
}

class _PostDetailsHeader extends StatelessWidget {
  final CityPost post;
  final ImageProvider? avatarProvider;
  final VoidCallback onLike;
  final VoidCallback onFavorite;
  final VoidCallback onRepost;
  final VoidCallback onShare;

  const _PostDetailsHeader({
    required this.post,
    required this.avatarProvider,
    required this.onLike,
    required this.onFavorite,
    required this.onRepost,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      borderRadius: BorderRadius.circular(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProfileAvatar(radius: 24, imageProvider: avatarProvider),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _RespectAuthorName(
                      name: post.user,
                      username: post.username,
                      verified: post.authorVerified,
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                    ),
                    Text(post.username, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                  ],
                ),
              ),
            ],
          ),
          if (post.text.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            _MentionText(post.text, style: const TextStyle(fontSize: 18, height: 1.45), onMentionTap: (u) async {}),
          ],
          if ((post.mediaPath ?? '').trim().isNotEmpty && post.mediaType != null) ...[
            const SizedBox(height: 12),
            _PostMedia(path: post.mediaPath!, type: post.mediaType!),
          ],
          if ((post.voicePath ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            _VoiceBubble(path: post.voicePath!, durationText: _PostCard._formatStaticSeconds(post.voiceSeconds)),
          ],
          if (post.quotedPost != null) ...[
            const SizedBox(height: 12),
            _QuotedPostPreview(post: post.quotedPost!),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Flexible(
                child: Text(
                  post.time,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _TweetActionRow(
            isDark: isDark,
            liked: post.isLiked,
            saved: post.isFavorite,
            reposted: post.isReposted,
            likes: post.likes,
            replies: post.replyCount,
            reposts: post.reposts,
            views: post.views,
            onReply: () {},
            onLike: onLike,
            onRepost: onRepost,
            onSave: onFavorite,
            onShare: onShare,
          ),
        ],
      ),
    );
  }
}


class _MentionText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final Future<void> Function(String username)? onMentionTap;
  final Future<void> Function(String hashtag)? onHashtagTap;

  const _MentionText(
      this.text, {
        this.style,
        this.maxLines,
        this.overflow,
        this.textAlign,
        this.onMentionTap,
        this.onHashtagTap,
      });

  static final RegExp _tokenRegex = RegExp(
    r'(https?:\/\/[^\s]+|www\.[^\s]+|@[a-zA-Z0-9_\.]+|#[^\s#@]+)',
    caseSensitive: false,
  );

  bool _isUrl(String value) {
    final v = value.toLowerCase().trim();
    return v.startsWith('http://') || v.startsWith('https://') || v.startsWith('www.');
  }

  String _stripTrailingUrlPunctuation(String value) {
    var v = value;
    while (v.isNotEmpty && RegExp(r'[\.,،؛:!؟\)\]\}]$').hasMatch(v)) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  String _trailingPart(String original, String clean) {
    if (clean.length >= original.length) return '';
    return original.substring(clean.length);
  }

  Future<void> _openUrl(String rawUrl) async {
    final clean = _stripTrailingUrlPunctuation(rawUrl.trim());
    if (clean.isEmpty) return;
    final normalized = clean.startsWith('http://') || clean.startsWith('https://') ? clean : 'https://$clean';
    final uri = Uri.tryParse(normalized);
    if (uri == null) return;

    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        await Clipboard.setData(ClipboardData(text: normalized));
        NotificationService.showTopError('تعذر فتح الرابط، تم نسخه بدلًا من ذلك');
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: normalized));
      NotificationService.showTopError('تعذر فتح الرابط، تم نسخه بدلًا من ذلك');
    }
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style.merge(style);
    final spans = <TextSpan>[];
    var index = 0;

    for (final match in _tokenRegex.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: text.substring(index, match.start)));
      }

      final token = match.group(0)!;
      if (_isUrl(token)) {
        final cleanUrl = _stripTrailingUrlPunctuation(token);
        final trailing = _trailingPart(token, cleanUrl);
        spans.add(TextSpan(
          text: cleanUrl,
          recognizer: TapGestureRecognizer()..onTap = () => _openUrl(cleanUrl),
          style: const TextStyle(
            color: Colors.blueAccent,
            fontWeight: FontWeight.w800,
            decoration: TextDecoration.underline,
            decorationColor: Colors.blueAccent,
          ),
        ));
        if (trailing.isNotEmpty) spans.add(TextSpan(text: trailing));
      } else if (token.startsWith('#')) {
        final hashtag = token;
        spans.add(TextSpan(
          text: hashtag,
          recognizer: TapGestureRecognizer()
            ..onTap = () async {
              if (onHashtagTap != null) {
                await onHashtagTap!(hashtag);
                return;
              }
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SearchScreen(
                    initialQuery: hashtag,
                    initialTimeFilter: 'all',
                  ),
                ),
              );
            },
          style: const TextStyle(
            color: AppColors.purple,
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.none,
          ),
        ));
      } else {
        final mention = token;
        spans.add(TextSpan(
          text: mention,
          recognizer: onMentionTap == null ? null : (TapGestureRecognizer()..onTap = () => onMentionTap!(mention)),
          style: const TextStyle(
            color: AppColors.purple,
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.none,
          ),
        ));
      }
      index = match.end;
    }

    if (index < text.length) spans.add(TextSpan(text: text.substring(index)));

    return RichText(
      textAlign: textAlign ?? TextAlign.start,
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
      text: TextSpan(style: baseStyle, children: spans),
    );
  }
}

class _MentionSuggestionsBox extends StatelessWidget {
  final List<Map<String, dynamic>> users;
  final bool loading;
  final bool isDark;
  final ImageProvider? Function(String? path) avatarProvider;
  final ValueChanged<String> onPick;

  const _MentionSuggestionsBox({
    required this.users,
    required this.loading,
    required this.isDark,
    required this.avatarProvider,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard.withValues(alpha: 0.98) : AppColors.lightCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.purple.withValues(alpha: 0.35)),
        boxShadow: [BoxShadow(color: AppColors.purple.withValues(alpha: 0.16), blurRadius: 22, offset: const Offset(0, 10))],
      ),
      child: loading && users.isEmpty
          ? const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.purple))),
      )
          : users.isEmpty
          ? Padding(
        padding: const EdgeInsets.all(14),
        child: Text('لا يوجد مستخدمين مطابقين', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700)),
      )
          : ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: users.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
        itemBuilder: (context, i) {
          final user = users[i];
          final username = SupabaseService.displayUsername((user['username'] ?? user['id'] ?? '').toString());
          final name = (user['name'] ?? user['profileName'] ?? username).toString();
          final avatar = (user['avatar_url'] ?? user['imagePath'] ?? user['profileImagePath'] ?? '').toString();
          return ListTile(
            dense: true,
            leading: CircleAvatar(
              backgroundColor: AppColors.purple.withValues(alpha: 0.25),
              backgroundImage: avatarProvider(avatar),
              child: avatarProvider(avatar) == null ? const Icon(Icons.person_rounded, color: Colors.white) : null,
            ),
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900)),
            subtitle: Text(username, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
            onTap: () => onPick(username),
          );
        },
      ),
    );
  }
}



class _HashtagQuickChips extends StatelessWidget {
  final ValueChanged<String> onPick;
  final bool isDark;

  const _HashtagQuickChips({
    required this.onPick,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    const suggestions = <String>[
      '#ترند',
      '#سؤال',
      '#النصر',
      '#رياضة',
      '#تقنية',
      '#Respect',
    ];

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: suggestions.map((tag) {
            return Padding(
              padding: const EdgeInsetsDirectional.only(end: 7),
              child: InkWell(
                onTap: () => onPick(tag),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppColors.purple.withValues(alpha: isDark ? 0.16 : 0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.purple.withValues(alpha: 0.22)),
                  ),
                  child: Text(
                    tag,
                    style: const TextStyle(
                      color: AppColors.purple,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _PostCharacterLimitCircle extends StatelessWidget {
  final int used;
  final int max;
  final bool verified;

  const _PostCharacterLimitCircle({required this.used, required this.max, required this.verified});

  @override
  Widget build(BuildContext context) {
    final remaining = (max - used).clamp(0, max);
    final progress = max <= 0 ? 1.0 : (used / max).clamp(0.0, 1.0);
    final danger = remaining <= 40;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (verified) ...[
          const Icon(Icons.verified_rounded, color: AppColors.purple, size: 17),
          const SizedBox(width: 5),
        ],
        Text('$remaining', style: TextStyle(fontWeight: FontWeight.w900, color: danger ? AppColors.danger : AppColors.purple)),
        const SizedBox(width: 8),
        SizedBox(
          width: 34,
          height: 34,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: progress,
                strokeWidth: 4,
                color: danger ? AppColors.danger : AppColors.purple,
                backgroundColor: AppColors.purple.withValues(alpha: .16),
              ),
              Icon(danger ? Icons.priority_high_rounded : Icons.edit_rounded, size: 15, color: danger ? AppColors.danger : AppColors.purple),
            ],
          ),
        ),
      ],
    );
  }
}

class ComposePostScreen extends StatefulWidget {
  final String profileName;
  final String username;
  final String? profileImagePath;
  final String initialText;
  final bool editMode;
  final bool verified;
  final int maxChars;
  final List<CityCommunity> availableCommunities;
  final String initialAudience;
  final String initialCommunityId;
  final String initialCommunityName;

  const ComposePostScreen({
    super.key,
    required this.profileName,
    required this.username,
    required this.profileImagePath,
    this.initialText = '',
    this.editMode = false,
    this.verified = false,
    this.maxChars = SupabaseService.freePostMaxChars,
    this.availableCommunities = const <CityCommunity>[],
    this.initialAudience = 'public',
    this.initialCommunityId = '',
    this.initialCommunityName = '',
  });

  @override
  State<ComposePostScreen> createState() => _ComposePostScreenState();
}

class _ComposePostScreenState extends State<ComposePostScreen> {
  final TextEditingController _ctrl = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  final AudioRecorder _recorder = AudioRecorder();

  XFile? _selectedMedia;
  CityMediaType? _selectedMediaType;
  String? _voicePath;
  bool _isRecording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  Timer? _mentionDebounce;
  final FocusNode _textFocusNode = FocusNode();
  List<Map<String, dynamic>> _mentionSuggestions = <Map<String, dynamic>>[];
  bool _loadingMentionSuggestions = false;
  late String _audience;
  String _communityId = '';
  String _communityName = '';

  @override
  void initState() {
    super.initState();
    _audience = widget.initialAudience.trim().isEmpty ? 'public' : widget.initialAudience.trim();
    _communityId = widget.initialCommunityId.trim();
    _communityName = widget.initialCommunityName.trim();
    if (_audience == 'community' && _communityId.isEmpty && widget.availableCommunities.isNotEmpty) {
      _communityId = widget.availableCommunities.first.id;
      _communityName = widget.availableCommunities.first.name;
    }
    if (widget.initialText.trim().isNotEmpty) {
      _ctrl.text = widget.initialText;
      _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    }
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _mentionDebounce?.cancel();
    _textFocusNode.dispose();
    _recorder.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  ImageProvider? _avatarProvider() {
    final p = widget.profileImagePath?.trim();
    if (p == null || p.isEmpty) return null;
    final lowerPath = p.split('?').first.toLowerCase();
    final looksLikeVideo = lowerPath.endsWith('.mp4') ||
        lowerPath.endsWith('.mov') ||
        lowerPath.endsWith('.m4v') ||
        lowerPath.endsWith('.webm') ||
        lowerPath.endsWith('.mkv');
    if (looksLikeVideo) return null;
    if (p.startsWith('http://') || p.startsWith('https://')) return NetworkImage(p);
    final f = File(p);
    if (!f.existsSync()) return null;
    return FileImage(f);
  }


  String? _activeMentionQuery() {
    final selection = _ctrl.selection;
    if (!selection.isValid) return null;
    final end = selection.baseOffset.clamp(0, _ctrl.text.length);
    final beforeCursor = _ctrl.text.substring(0, end);
    final match = RegExp(r'(?:^|\s)@([a-zA-Z0-9_\.]*)$').firstMatch(beforeCursor);
    if (match == null) return null;
    return match.group(1) ?? '';
  }

  Future<void> _updateMentionSuggestions() async {
    final query = _activeMentionQuery();
    _mentionDebounce?.cancel();

    if (query == null) {
      if (_mentionSuggestions.isNotEmpty || _loadingMentionSuggestions) {
        setState(() {
          _mentionSuggestions = <Map<String, dynamic>>[];
          _loadingMentionSuggestions = false;
        });
      }
      return;
    }

    setState(() => _loadingMentionSuggestions = true);
    _mentionDebounce = Timer(const Duration(milliseconds: 180), () async {
      try {
        final users = query.trim().isEmpty
            ? await SupabaseService.getUsers()
            : await SupabaseService.searchUsers(query.trim());
        if (!mounted || _activeMentionQuery() != query) return;
        final seen = <String>{};
        final cleaned = <Map<String, dynamic>>[];
        for (final raw in users) {
          final username = SupabaseService.displayUsername((raw['username'] ?? raw['id'] ?? '').toString());
          if (username == '@user' || !seen.add(username)) continue;
          cleaned.add({
            ...raw,
            'username': username,
            'name': (raw['name'] ?? raw['profileName'] ?? username).toString(),
            'avatar_url': (raw['avatar_url'] ?? raw['imagePath'] ?? raw['profileImagePath'] ?? '').toString(),
          });
          if (cleaned.length >= 8) break;
        }
        setState(() {
          _mentionSuggestions = cleaned;
          _loadingMentionSuggestions = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _mentionSuggestions = <Map<String, dynamic>>[];
          _loadingMentionSuggestions = false;
        });
      }
    });
  }

  void _insertMention(String username) {
    final selection = _ctrl.selection;
    if (!selection.isValid) return;
    final end = selection.baseOffset.clamp(0, _ctrl.text.length);
    final beforeCursor = _ctrl.text.substring(0, end);
    final afterCursor = _ctrl.text.substring(end);
    final match = RegExp(r'(?:^|\s)@([a-zA-Z0-9_\.]*)$').firstMatch(beforeCursor);
    if (match == null) return;

    final clean = SupabaseService.displayUsername(username);
    final start = match.start;
    final keepPrefix = beforeCursor.substring(0, start);
    final hasLeadingSpace = match.group(0)?.startsWith(' ') == true;
    final replacement = '${hasLeadingSpace ? ' ' : ''}$clean ';
    final nextText = '$keepPrefix$replacement$afterCursor';
    final cursor = (keepPrefix + replacement).length;

    _ctrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: cursor),
    );
    setState(() => _mentionSuggestions = <Map<String, dynamic>>[]);
    _textFocusNode.requestFocus();
  }

  ImageProvider? _mentionAvatarProvider(String? path) {
    final p = path?.trim();
    if (p == null || p.isEmpty) return null;
    if (p.startsWith('http://') || p.startsWith('https://')) return NetworkImage(p);
    final f = File(p);
    if (!f.existsSync()) return null;
    return FileImage(f);
  }

  void _insertHashtag(String hashtag) {
    final clean = hashtag.trim().startsWith('#') ? hashtag.trim() : '#${hashtag.trim()}';
    if (clean.length <= 1) return;

    final selection = _ctrl.selection;
    final pos = selection.isValid ? selection.baseOffset.clamp(0, _ctrl.text.length) : _ctrl.text.length;
    final before = _ctrl.text.substring(0, pos);
    final after = _ctrl.text.substring(pos);
    final needSpaceBefore = before.isNotEmpty && !before.endsWith(' ') && !before.endsWith('\n');
    final needSpaceAfter = after.isNotEmpty && !after.startsWith(' ') && !after.startsWith('\n');
    final insert = '${needSpaceBefore ? ' ' : ''}$clean${needSpaceAfter ? ' ' : ' '}';

    _ctrl.value = TextEditingValue(
      text: '$before$insert$after',
      selection: TextSelection.collapsed(offset: (before + insert).length),
    );
    _textFocusNode.requestFocus();
  }


  Future<void> _pickAttachment() async {
    final result = await showModalBottomSheet<_AttachmentChoice>(
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
                Container(
                  width: 46,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 18),
                const Text('اختر مرفق', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 14),
                _SheetOption(
                  icon: Icons.image_rounded,
                  title: 'صورة',
                  subtitle: 'اختيار صورة من المعرض',
                  onTap: () => Navigator.pop(context, _AttachmentChoice.image),
                ),
                const SizedBox(height: 10),
                _SheetOption(
                  icon: Icons.videocam_rounded,
                  title: 'فيديو',
                  subtitle: 'اختيار فيديو من المعرض',
                  onTap: () => Navigator.pop(context, _AttachmentChoice.video),
                ),
                const SizedBox(height: 10),
                _SheetOption(
                  icon: Icons.gif_box_rounded,
                  title: 'GIF',
                  subtitle: 'اختيار GIF من المعرض',
                  onTap: () => Navigator.pop(context, _AttachmentChoice.gif),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (result == null) return;

    if (result == _AttachmentChoice.image || result == _AttachmentChoice.gif) {
      final file = await _picker.pickImage(source: ImageSource.gallery, imageQuality: result == _AttachmentChoice.gif ? null : 85);
      if (file == null) return;
      setState(() {
        _selectedMedia = file;
        _selectedMediaType = result == _AttachmentChoice.gif ? CityMediaType.gif : CityMediaType.image;
      });
    } else {
      final file = await _picker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      setState(() {
        _selectedMedia = file;
        _selectedMediaType = CityMediaType.video;
      });
    }
  }

  void _removeMedia() {
    setState(() {
      _selectedMedia = null;
      _selectedMediaType = null;
    });
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
      return;
    }

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (!mounted) return;
      NotificationService.showTopNotification('يجب السماح للتطبيق باستخدام المايكروفون');
      return;
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/respect_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: path,
    );

    setState(() {
      _isRecording = true;
      _voicePath = null;
      _recordSeconds = 0;
    });

    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordSeconds++);
    });
  }

  Future<void> _stopRecording() async {
    _recordTimer?.cancel();
    final path = await _recorder.stop();
    if (!mounted) return;

    setState(() {
      _isRecording = false;
      _voicePath = path;
    });
  }

  Future<void> _removeVoice() async {
    _recordTimer?.cancel();
    if (_isRecording) {
      await _recorder.stop();
    }
    final path = _voicePath;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _voicePath = null;
      _recordSeconds = 0;
    });
  }


  Future<void> _chooseAudience() async {
    final chosen = await showModalBottomSheet<Map<String, String>>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
        final joined = widget.availableCommunities
            .where((c) => c.members.contains(SupabaseService.displayUsername(widget.username)))
            .toList();
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBg : AppColors.lightBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
          ),
          child: SafeArea(
            top: false,
            child: ListView(
              shrinkWrap: true,
              children: [
                Center(child: Container(width: 46, height: 5, decoration: BoxDecoration(color: isDark ? AppColors.darkBorder : AppColors.lightBorder, borderRadius: BorderRadius.circular(99)))),
                const SizedBox(height: 16),
                const Text('مكان نشر التغريدة', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 10),
                ListTile(
                  leading: const Icon(Icons.public_rounded, color: AppColors.purple),
                  title: const Text('تغريدة عامة', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text('تظهر في تبويب لك والملف الشخصي', style: TextStyle(color: muted, fontSize: 12)),
                  trailing: _audience == 'public' ? const Icon(Icons.check_circle_rounded, color: AppColors.success) : null,
                  onTap: () => Navigator.pop(context, {'audience': 'public', 'communityId': '', 'communityName': ''}),
                ),
                ListTile(
                  leading: const Icon(Icons.group_rounded, color: AppColors.purple),
                  title: const Text('للمتابعين فقط', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text('تظهر فقط في تبويب المتابعين', style: TextStyle(color: muted, fontSize: 12)),
                  trailing: _audience == 'followers' ? const Icon(Icons.check_circle_rounded, color: AppColors.success) : null,
                  onTap: () => Navigator.pop(context, {'audience': 'followers', 'communityId': '', 'communityName': ''}),
                ),
                if (joined.isNotEmpty) ...[
                  Divider(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text('المجتمعات المنضم لها', style: TextStyle(color: muted, fontWeight: FontWeight.w800)),
                  ),
                  ...joined.map((c) => ListTile(
                    leading: const Icon(Icons.forum_rounded, color: AppColors.purple),
                    title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w900)),
                    subtitle: Text('${c.members.length} عضو · ${c.moderators.length} مشرف', style: TextStyle(color: muted, fontSize: 12)),
                    trailing: _audience == 'community' && _communityId == c.id ? const Icon(Icons.check_circle_rounded, color: AppColors.success) : null,
                    onTap: () => Navigator.pop(context, {'audience': 'community', 'communityId': c.id, 'communityName': c.name}),
                  )),
                ],
              ],
            ),
          ),
        );
      },
    );
    if (chosen == null) return;
    setState(() {
      _audience = chosen['audience'] ?? 'public';
      _communityId = chosen['communityId'] ?? '';
      _communityName = chosen['communityName'] ?? '';
    });
  }

  String get _audienceLabel {
    if (_audience == 'followers') return 'للمتابعين فقط';
    if (_audience == 'community') return _communityName.trim().isEmpty ? 'داخل مجتمع' : 'داخل $_communityName';
    return 'عام';
  }

  Future<void> _publish() async {
    final text = _ctrl.text.trim();
    if (_isRecording) {
      await _stopRecording();
    }
    if (!mounted) return;
    if (text.isEmpty && _selectedMedia == null && _voicePath == null) return;
    if (text.runes.length > widget.maxChars) {
      NotificationService.showTopError('تجاوزت حد ${widget.maxChars} حرف');
      return;
    }

    Navigator.pop(
      context,
      CityPost(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        user: widget.profileName,
        username: widget.username,
        avatarPath: widget.profileImagePath,
        text: text,
        time: 'الآن',
        mediaPath: _selectedMedia?.path,
        mediaType: _selectedMediaType,
        voicePath: _voicePath,
        voiceSeconds: _recordSeconds,
        audience: _audience,
        communityId: _communityId,
        communityName: _communityName,
      ),
    );
  }

  String _formatSeconds(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasContent = _ctrl.text.trim().isNotEmpty || _selectedMedia != null || _voicePath != null || _isRecording;
    final textColor = isDark ? Colors.white : const Color(0xFF171225);
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    final cardColor = isDark ? Colors.white.withValues(alpha: 0.075) : Colors.white.withValues(alpha: 0.78);
    final borderColor = isDark ? Colors.white.withValues(alpha: 0.12) : AppColors.purple.withValues(alpha: 0.14);
    final bgTop = isDark ? const Color(0xFF12091F) : const Color(0xFFF8F2FF);
    final bgBottom = isDark ? const Color(0xFF050308) : const Color(0xFFFFFFFF);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: bgBottom,
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    bgTop,
                    isDark ? const Color(0xFF0D0715) : const Color(0xFFFFFBFF),
                    bgBottom,
                  ],
                  stops: const [0.0, 0.48, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            top: -90,
            right: -70,
            child: IgnorePointer(
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppColors.purple.withValues(alpha: isDark ? 0.34 : 0.22),
                      AppColors.purple.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 80,
            left: -110,
            child: IgnorePointer(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF8B5CF6).withValues(alpha: isDark ? 0.22 : 0.13),
                      const Color(0xFF8B5CF6).withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                  child: Row(
                    children: [
                      Material(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(18),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: borderColor),
                            ),
                            child: Icon(Icons.close_rounded, color: textColor),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.editMode ? 'تعديل التغريدة' : 'نشر تغريدة',
                              style: TextStyle(
                                color: textColor,
                                fontSize: 21,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.4,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.editMode ? 'رتّبها وخليها تظهر بأفضل شكل' : 'اكتب شيئًا يستحق الظهور',
                              style: TextStyle(
                                color: muted,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedScale(
                        scale: hasContent ? 1 : 0.96,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutBack,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: hasContent
                                ? [
                              BoxShadow(
                                color: AppColors.purple.withValues(alpha: 0.34),
                                blurRadius: 22,
                                offset: const Offset(0, 10),
                              ),
                            ]
                                : const [],
                          ),
                          child: FilledButton.icon(
                            onPressed: hasContent ? _publish : null,
                            icon: Icon(widget.editMode ? Icons.check_rounded : Icons.send_rounded, size: 18),
                            label: Text(widget.editMode ? 'حفظ' : 'نشر'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.purple,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: AppColors.purple.withValues(alpha: 0.22),
                              disabledForegroundColor: Colors.white.withValues(alpha: 0.55),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ).animate().fadeIn(duration: 240.ms).slideY(begin: -0.08, end: 0),
                Expanded(
                  child: ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 112),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: borderColor),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.07),
                              blurRadius: 28,
                              offset: const Offset(0, 18),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(2.5),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: [
                                    AppColors.purple.withValues(alpha: 0.95),
                                    const Color(0xFFEC4899).withValues(alpha: 0.78),
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.purple.withValues(alpha: 0.26),
                                    blurRadius: 18,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: _ProfileAvatar(radius: 25, imageProvider: _avatarProvider()),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          widget.profileName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: textColor,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 15.5,
                                          ),
                                        ),
                                      ),
                                      if (widget.verified) ...[
                                        const SizedBox(width: 5),
                                        const Icon(Icons.verified_rounded, color: AppColors.purple, size: 18),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    widget.username,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: muted, fontWeight: FontWeight.w700, fontSize: 12.5),
                                  ),
                                ],
                              ),
                            ),
                            Material(
                              color: AppColors.purple.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(999),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(999),
                                onTap: _chooseAudience,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(color: AppColors.purple.withValues(alpha: 0.26)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _audience == 'community'
                                            ? Icons.groups_2_rounded
                                            : (_audience == 'followers' ? Icons.lock_person_rounded : Icons.public_rounded),
                                        color: AppColors.purple,
                                        size: 17,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        _audienceLabel,
                                        style: const TextStyle(
                                          color: AppColors.purple,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(width: 2),
                                      const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.purple, size: 18),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ).animate().fadeIn(duration: 280.ms).slideY(begin: 0.08, end: 0),
                      const SizedBox(height: 14),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(34),
                          border: Border.all(
                            color: _textFocusNode.hasFocus
                                ? AppColors.purple.withValues(alpha: 0.42)
                                : borderColor,
                            width: _textFocusNode.hasFocus ? 1.4 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.purple.withValues(alpha: _textFocusNode.hasFocus ? 0.16 : 0.07),
                              blurRadius: _textFocusNode.hasFocus ? 32 : 20,
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: AppColors.purple.withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.auto_awesome_rounded, color: AppColors.purple, size: 16),
                                      SizedBox(width: 5),
                                      Text(
                                        'Respect Compose',
                                        style: TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900, fontSize: 11.5),
                                      ),
                                    ],
                                  ),
                                ),
                                const Spacer(),
                                _PostCharacterLimitCircle(
                                  used: _ctrl.text.runes.length,
                                  max: widget.maxChars,
                                  verified: widget.verified,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _ctrl,
                              focusNode: _textFocusNode,
                              autofocus: true,
                              minLines: 7,
                              maxLines: 15,
                              inputFormatters: [LengthLimitingTextInputFormatter(widget.maxChars)],
                              onTap: () => setState(() {}),
                              onChanged: (_) {
                                setState(() {});
                                _updateMentionSuggestions();
                              },
                              cursorColor: AppColors.purple,
                              cursorWidth: 2.3,
                              decoration: InputDecoration(
                                hintText: 'وش ودك تنشر اليوم؟',
                                hintStyle: TextStyle(
                                  color: muted.withValues(alpha: 0.78),
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  height: 1.25,
                                ),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                filled: false,
                              ),
                              style: TextStyle(
                                color: textColor,
                                fontSize: 19,
                                height: 1.48,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.15,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _HashtagQuickChips(
                              onPick: _insertHashtag,
                              isDark: isDark,
                            ),
                            const SizedBox(height: 10),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                value: widget.maxChars == 0 ? 0 : (_ctrl.text.runes.length / widget.maxChars).clamp(0.0, 1.0),
                                minHeight: 5,
                                backgroundColor: AppColors.purple.withValues(alpha: 0.10),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  _ctrl.text.runes.length > widget.maxChars * 0.9
                                      ? AppColors.danger
                                      : AppColors.purple,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ).animate().fadeIn(duration: 320.ms, delay: 60.ms).slideY(begin: 0.08, end: 0),
                      if (_loadingMentionSuggestions || _mentionSuggestions.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _MentionSuggestionsBox(
                          users: _mentionSuggestions,
                          loading: _loadingMentionSuggestions,
                          isDark: isDark,
                          avatarProvider: _mentionAvatarProvider,
                          onPick: _insertMention,
                        ).animate().fadeIn(duration: 180.ms).scale(begin: const Offset(0.98, 0.98), end: const Offset(1, 1)),
                      ],
                      if (_selectedMedia != null && _selectedMediaType != null) ...[
                        const SizedBox(height: 14),
                        _MediaPreview(
                          path: _selectedMedia?.path ?? '',
                          type: _selectedMediaType!,
                          onRemove: _removeMedia,
                        ).animate().fadeIn(duration: 240.ms).slideY(begin: 0.08, end: 0),
                      ],
                      if (_isRecording || _voicePath != null) ...[
                        const SizedBox(height: 14),
                        _VoicePreview(
                          isRecording: _isRecording,
                          path: _voicePath,
                          durationText: _formatSeconds(_recordSeconds),
                          onRemove: _removeVoice,
                        ).animate().fadeIn(duration: 240.ms).slideY(begin: 0.08, end: 0),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Container(
                margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xE6100919) : const Color(0xF7FFFFFF),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: borderColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.32 : 0.10),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    _SmallPurpleAction(
                      icon: Icons.add_photo_alternate_rounded,
                      tooltip: 'إضافة صورة أو فيديو',
                      onTap: _pickAttachment,
                    ),
                    const SizedBox(width: 8),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: _isRecording
                            ? [
                          BoxShadow(
                            color: AppColors.danger.withValues(alpha: 0.28),
                            blurRadius: 18,
                            offset: const Offset(0, 7),
                          ),
                        ]
                            : const [],
                      ),
                      child: _SmallPurpleAction(
                        icon: _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                        tooltip: _isRecording ? 'إيقاف التسجيل' : 'تسجيل صوتي',
                        onTap: _toggleRecording,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: _isRecording
                            ? Row(
                          key: const ValueKey('recording'),
                          children: [
                            Container(
                              width: 9,
                              height: 9,
                              decoration: const BoxDecoration(
                                color: AppColors.danger,
                                shape: BoxShape.circle,
                              ),
                            ).animate(onPlay: (controller) => controller.repeat(reverse: true)).fade(begin: 0.35, end: 1, duration: 520.ms),
                            const SizedBox(width: 8),
                            Text(
                              'تسجيل ${_formatSeconds(_recordSeconds)}',
                              style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w900, fontSize: 12.5),
                            ),
                          ],
                        )
                            : Text(
                          _selectedMedia != null
                              ? (_selectedMediaType == CityMediaType.video
                              ? 'الفيديو جاهز للنشر'
                              : (_selectedMediaType == CityMediaType.gif ? 'GIF جاهز للنشر' : 'الصورة جاهزة للنشر'))
                              : (_voicePath != null ? 'المقطع الصوتي جاهز' : 'أضف مرفق أو سجّل صوت'),
                          key: ValueKey('${_selectedMedia?.path}_${_voicePath ?? ''}_$_isRecording'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted, fontWeight: FontWeight.w800, fontSize: 12.5),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: hasContent ? _publish : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.purple,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppColors.purple.withValues(alpha: 0.20),
                        disabledForegroundColor: Colors.white.withValues(alpha: 0.55),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                      ),
                      child: Text(widget.editMode ? 'حفظ' : 'نشر'),
                    ),
                  ],
                ),
              ).animate().fadeIn(duration: 260.ms).slideY(begin: 0.12, end: 0),
            ),
          ),
        ],
      ),
    );
  }
}


class UserProfileViewScreen extends StatefulWidget {
  final String user;
  final String username;
  final String bio;
  final String? avatarPath;
  final String? coverPath;
  final List<CityPost> posts;
  final String currentUsername;
  final Map<String, List<String>> following;
  final Set<String> notificationTargets;
  final Future<void> Function(String username) onToggleFollow;
  final Future<void> Function(String username) onTogglePostNotification;
  final Future<void> Function(CityPost post, String newText)? onEditPost;
  final Future<void> Function(CityPost post)? onDeletePost;
  final Future<void> Function(String username)? onMentionTap;
  final List<Map<String, dynamic>>? activeStoriesForUser;
  final bool storiesSeen;
  final VoidCallback? onStoryTap;

  const UserProfileViewScreen({
    super.key,
    required this.user,
    required this.username,
    required this.bio,
    required this.avatarPath,
    this.coverPath,
    required this.posts,
    required this.currentUsername,
    required this.following,
    required this.notificationTargets,
    required this.onToggleFollow,
    required this.onTogglePostNotification,
    this.onEditPost,
    this.onDeletePost,
    this.onMentionTap,
    this.activeStoriesForUser,
    this.storiesSeen = false,
    this.onStoryTap,
  });

  @override
  State<UserProfileViewScreen> createState() => _UserProfileViewScreenState();
}

class _UserProfileViewScreenState extends State<UserProfileViewScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 3, vsync: this);
  late List<CityPost> _posts = List<CityPost>.from(widget.posts);
  late Map<String, List<String>> _followingMap = Map<String, List<String>>.from(widget.following);
  late Set<String> _notificationTargets = Set<String>.from(widget.notificationTargets);
  List<Map<String, dynamic>> _followers = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _followingUsers = <Map<String, dynamic>>[];
  bool _muted = false;
  bool _blocked = false;
  bool _loadingFollowLists = false;

  @override
  void initState() {
    super.initState();
    _loadFollowLists();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  ImageProvider? _avatar([String? path]) {
    final p = (path ?? widget.avatarPath)?.trim();
    if (p == null || p.isEmpty) return null;
    if (p.startsWith('http://') || p.startsWith('https://')) return NetworkImage(p);
    final file = File(p);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  ImageProvider? _coverImage() {
    final p = widget.coverPath?.trim();
    if (p == null || p.isEmpty) return null;
    if (p.startsWith('http://') || p.startsWith('https://')) return NetworkImage(p);
    final file = File(p);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  bool get _isMe => SupabaseService.displayUsername(widget.username) == SupabaseService.displayUsername(widget.currentUsername);
  bool get _isFollowing => (_followingMap[SupabaseService.displayUsername(widget.currentUsername)] ?? const <String>[])
      .contains(SupabaseService.displayUsername(widget.username));
  bool get _postNotificationsEnabled => _notificationTargets.contains(SupabaseService.displayUsername(widget.username));
  int get _followersCount => _followers.isNotEmpty ? _followers.length : _followingMap.values.where((list) => list.contains(SupabaseService.displayUsername(widget.username))).length;
  int get _followingCount => _followingUsers.isNotEmpty ? _followingUsers.length : (_followingMap[SupabaseService.displayUsername(widget.username)] ?? const <String>[]).length;

  List<CityPost> get _mediaPosts => _posts.where((p) => p.mediaPath != null || p.voicePath != null).toList();
  List<CityReply> get _replies => _posts.expand((p) => p.replies).where((r) => SupabaseService.displayUsername(r.username) == SupabaseService.displayUsername(widget.username)).toList();

  Future<void> _loadFollowLists() async {
    if (mounted) setState(() => _loadingFollowLists = true);
    try {
      final followers = await SupabaseService.getUserFollowers(widget.username);
      final following = await SupabaseService.getUserFollowing(widget.username);
      final currentFollowing = await SupabaseService.getFollowingUsernames(widget.currentUsername);
      final notificationTargets = await SupabaseService.getEnabledPostNotificationTargets(widget.currentUsername);
      _followingMap[SupabaseService.displayUsername(widget.currentUsername)] = currentFollowing;
      if (!mounted) return;
      setState(() {
        _followers = followers;
        _followingUsers = following;
        _notificationTargets = notificationTargets;
        _loadingFollowLists = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingFollowLists = false);
    }
  }

  void _showAction(String text) => NotificationService.showTopNotification(text);

  void _openChat() {
    if (_isMe) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(
      peerUsername: widget.username,
      peerName: widget.user,
      peerAvatarPath: widget.avatarPath,
    )));
  }

  Future<void> _toggleFollow() async {
    await widget.onToggleFollow(widget.username);
    final me = SupabaseService.displayUsername(widget.currentUsername);
    final target = SupabaseService.displayUsername(widget.username);
    final list = List<String>.from(_followingMap[me] ?? const <String>[]);
    final nowUnfollowed = list.contains(target);
    if (nowUnfollowed) {
      list.remove(target);
      _notificationTargets.remove(target);
    } else {
      list.add(target);
    }
    if (mounted) setState(() => _followingMap[me] = list.toSet().toList());
    await _loadFollowLists();
  }


  Future<void> _togglePostNotifications() async {
    if (!_isFollowing) {
      _showAction('تابع المستخدم أولًا لتفعيل الإشعارات');
      return;
    }
    await widget.onTogglePostNotification(widget.username);
    final target = SupabaseService.displayUsername(widget.username);
    if (!mounted) return;
    setState(() {
      if (_notificationTargets.contains(target)) {
        _notificationTargets.remove(target);
      } else {
        _notificationTargets.add(target);
      }
    });
  }

  Future<void> _editPost(CityPost post) async {
    String draftText = post.text;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).brightness == Brightness.dark ? AppColors.darkCard : AppColors.lightCard,
        title: const Text('تعديل التغريدة', style: TextStyle(fontWeight: FontWeight.w900)),
        content: TextFormField(
          initialValue: post.text,
          maxLines: 5,
          autofocus: true,
          onChanged: (value) => draftText = value,
          decoration: const InputDecoration(hintText: 'اكتب نص التغريدة'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, draftText), child: const Text('حفظ')),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    await widget.onEditPost?.call(post, result.trim());
    if (!mounted) return;
    setState(() {
      final index = _posts.indexWhere((p) => p.id == post.id);
      if (index >= 0) {
        _posts[index] = CityPost(
          id: post.id,
          user: post.user,
          username: post.username,
          text: result.trim(),
          time: post.time,
          avatarPath: post.avatarPath,
          mediaPath: post.mediaPath,
          mediaType: post.mediaType,
          voicePath: post.voicePath,
          voiceSeconds: post.voiceSeconds,
          replies: List<CityReply>.from(post.replies),
          likes: post.likes,
          reposts: post.reposts,
          shares: post.shares,
          views: post.views,
          isLiked: post.isLiked,
          isFavorite: post.isFavorite,
          isReposted: post.isReposted,
          quotedPost: post.quotedPost,
        );
      }
    });
    _showAction('تم تعديل التغريدة');
  }

  Future<void> _deletePost(CityPost post) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).brightness == Brightness.dark ? AppColors.darkCard : AppColors.lightCard,
        title: const Text('حذف التغريدة', style: TextStyle(fontWeight: FontWeight.w900)),
        content: const Text('هل تريد حذف هذه التغريدة نهائيًا؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.onDeletePost?.call(post);
    if (mounted) {
      setState(() => _posts.removeWhere((p) => p.id == post.id));
      _showAction('تم حذف التغريدة');
    }
  }

  void _showUsersSheet({required String title, required List<Map<String, dynamic>> users}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        constraints: const BoxConstraints(maxHeight: 520),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkBg : AppColors.lightBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: AppColors.purple.withValues(alpha: 0.28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(width: 44, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(99))),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              ),
              Expanded(
                child: users.isEmpty
                    ? Center(child: Text(_loadingFollowLists ? 'جاري التحميل...' : 'لا توجد نتائج'))
                    : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
                  itemCount: users.length,
                  separatorBuilder: (_, __) => Divider(color: AppColors.purple.withValues(alpha: 0.12)),
                  itemBuilder: (context, i) {
                    final u = users[i];
                    final username = SupabaseService.displayUsername((u['username'] ?? u['follower_username'] ?? u['target_username'] ?? '').toString());
                    final name = (u['name'] ?? u['profileName'] ?? username).toString();
                    final avatar = (u['avatar_url'] ?? u['imagePath'] ?? u['profileImagePath'])?.toString();
                    return ListTile(
                      leading: CircleAvatar(backgroundColor: AppColors.purple, backgroundImage: _avatar(avatar), child: _avatar(avatar) == null ? const Icon(Icons.person, color: Colors.white) : null),
                      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w900)),
                      subtitle: Text(username),
                      onTap: () {
                        Navigator.pop(context);
                        widget.onMentionTap?.call(username);
                      },
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final avatar = _avatar();
    final cover = _coverImage();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.user, style: const TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'mute') {
                setState(() => _muted = !_muted);
                _showAction(_muted ? 'تم كتم الحساب' : 'تم إلغاء الكتم');
              } else if (value == 'block') {
                setState(() => _blocked = !_blocked);
                _showAction(_blocked ? 'تم حظر الحساب' : 'تم إلغاء الحظر');
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'mute', child: Text(_muted ? 'إلغاء الكتم' : 'كتم')),
              PopupMenuItem(value: 'block', child: Text(_blocked ? 'إلغاء الحظر' : 'حظر')),
            ],
          ),
        ],
      ),
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 128,
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                        gradient: const LinearGradient(colors: [Color(0xFF24103F), AppColors.purple, Color(0xFF7C3AED)]),
                        image: cover == null ? null : DecorationImage(image: cover, fit: BoxFit.cover),
                        boxShadow: [BoxShadow(color: AppColors.purple.withValues(alpha: 0.22), blurRadius: 28, offset: const Offset(0, 10))],
                      ),
                      child: cover == null ? null : Container(
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.black.withValues(alpha: 0.06), Colors.black.withValues(alpha: 0.42)],
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Transform.translate(
                            offset: const Offset(0, -38),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    _ProfileAvatar(radius: 48, imageProvider: avatar),
                                    const Spacer(),
                                  ],
                                ),
                                if (!_isMe) ...[
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: _ProfileActionButtons(
                                      isDark: isDark,
                                      isFollowing: _isFollowing,
                                      notificationsEnabled: _postNotificationsEnabled,
                                      blocked: _blocked,
                                      onChat: _openChat,
                                      onFollow: _toggleFollow,
                                      onNotify: _togglePostNotifications,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Transform.translate(
                            offset: Offset(0, _isMe ? -22 : -14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _RespectAuthorName(
                                  name: widget.user,
                                  username: widget.username,
                                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                                ),
                                const SizedBox(height: 2),
                                Text(SupabaseService.displayUsername(widget.username), style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 10),
                                Text(widget.bio.trim().isEmpty ? 'لا توجد نبذة شخصية' : widget.bio, style: const TextStyle(height: 1.45)),
                                const SizedBox(height: 14),
                                Wrap(
                                  spacing: 16,
                                  runSpacing: 8,
                                  children: [
                                    _MiniStat(value: '${_posts.length}', label: 'منشورات'),
                                    _MiniStat(value: '${_replies.length}', label: 'ردود'),
                                    _MiniStat(value: '${_mediaPosts.length}', label: 'وسائط'),
                                    InkWell(onTap: () => _showUsersSheet(title: 'المتابعون', users: _followers), child: _MiniStat(value: '$_followersCount', label: 'متابعون')),
                                    InkWell(onTap: () => _showUsersSheet(title: 'يتابع', users: _followingUsers), child: _MiniStat(value: '$_followingCount', label: 'يتابع')),
                                  ],
                                ),
                              ],
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
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabsHeaderDelegate(
              TabBar(
                controller: _tabController,
                labelColor: AppColors.purple,
                unselectedLabelColor: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                indicatorColor: AppColors.purple,
                tabs: const [Tab(text: 'المنشورات'), Tab(text: 'الردود'), Tab(text: 'الوسائط')],
              ),
              isDark: isDark,
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabController,
          children: [
            _ProfilePostsList(posts: _posts, empty: 'لا توجد منشورات', isMe: _isMe, onEdit: _editPost, onDelete: _deletePost, onMentionTap: widget.onMentionTap),
            _RepliesList(replies: _replies, avatarProvider: _avatar, onMentionTap: widget.onMentionTap),
            _ProfilePostsList(posts: _mediaPosts, empty: 'لا توجد وسائط', isMe: _isMe, onEdit: _editPost, onDelete: _deletePost, onMentionTap: widget.onMentionTap),
          ],
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String text;
  final Color color;

  const _MiniChip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w900)),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String value;
  final String label;
  const _MiniStat({required this.value, required this.label});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RichText(
      text: TextSpan(
        style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
        children: [
          TextSpan(text: '$value ', style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontWeight: FontWeight.w900)),
          TextSpan(text: label),
        ],
      ),
    );
  }
}

class _TabsHeaderDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  final bool isDark;
  const _TabsHeaderDelegate(this.tabBar, {required this.isDark});
  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => Container(color: isDark ? AppColors.darkBg : AppColors.lightBg, child: tabBar);
  @override
  bool shouldRebuild(covariant _TabsHeaderDelegate oldDelegate) => oldDelegate.isDark != isDark || oldDelegate.tabBar != tabBar;
}

class _ProfilePostsList extends StatelessWidget {
  final List<CityPost> posts;
  final String empty;
  final bool isMe;
  final Future<void> Function(CityPost post)? onEdit;
  final Future<void> Function(CityPost post)? onDelete;
  final Future<void> Function(String username)? onMentionTap;

  const _ProfilePostsList({required this.posts, required this.empty, this.isMe = false, this.onEdit, this.onDelete, this.onMentionTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (posts.isEmpty) return Center(child: Text(empty));
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 20),
      itemCount: posts.length,
      separatorBuilder: (_, __) => Divider(height: 1, thickness: 0.7, color: AppColors.purple.withValues(alpha: 0.32)),
      itemBuilder: (context, i) {
        final post = posts[i];
        final avatar = FeedScreenStateHelper.profileImageProvider(post.avatarPath);
        return InkWell(
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(99),
                  onTap: () => onMentionTap?.call(post.username),
                  child: CircleAvatar(
                    radius: 23,
                    backgroundColor: AppColors.purple.withValues(alpha: .35),
                    backgroundImage: avatar,
                    child: avatar == null ? const Icon(Icons.person_rounded, color: Colors.white) : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: () => onMentionTap?.call(post.username),
                              child: Text(
                                '${post.user}  ${post.username}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                              ),
                            ),
                          ),
                          Text(post.time, style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                          if (isMe)
                            PopupMenuButton<String>(
                              padding: EdgeInsets.zero,
                              icon: Icon(Icons.more_horiz_rounded, color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                              onSelected: (v) {
                                if (v == 'edit') onEdit?.call(post);
                                if (v == 'delete') onDelete?.call(post);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'edit', child: Text('تعديل التغريدة')),
                                PopupMenuItem(value: 'delete', child: Text('حذف التغريدة')),
                              ],
                            ),
                        ],
                      ),
                      if (post.text.trim().isNotEmpty) ...[
                        const SizedBox(height: 5),
                        _MentionText(post.text, style: const TextStyle(height: 1.45, fontSize: 15), onMentionTap: onMentionTap),
                      ],
                      if ((post.mediaPath ?? '').trim().isNotEmpty && post.mediaType != null) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: SizedBox(height: 190, width: double.infinity, child: _PostMedia(path: post.mediaPath!, type: post.mediaType!)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ProfileActionButtons extends StatelessWidget {
  final bool isDark;
  final bool isFollowing;
  final bool notificationsEnabled;
  final bool blocked;
  final VoidCallback onChat;
  final VoidCallback onFollow;
  final VoidCallback onNotify;

  const _ProfileActionButtons({
    required this.isDark,
    required this.isFollowing,
    required this.notificationsEnabled,
    required this.blocked,
    required this.onChat,
    required this.onFollow,
    required this.onNotify,
  });

  @override
  Widget build(BuildContext context) {
    // التصميم الجديد:
    // السطر الأول: زر المتابعة + زر الجرس بجانب بعض.
    // السطر الثاني: زر الدردشة بعرض كامل. هكذا تبقى الأزرار كبيرة بدون overflow.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _RoundProfileButton(
                icon: isFollowing ? Icons.person_remove_alt_1_rounded : Icons.person_add_alt_1_rounded,
                label: isFollowing ? 'إلغاء المتابعة' : 'متابعة',
                onTap: blocked ? null : onFollow,
                color: isFollowing ? (isDark ? Colors.white70 : Colors.black87) : Colors.white,
                background: isFollowing ? (isDark ? AppColors.darkCard2 : AppColors.lightCard2) : AppColors.purple,
                filled: true,
              ),
            ),
            if (isFollowing) ...[
              const SizedBox(width: 10),
              _AnimatedBellButton(enabled: notificationsEnabled, disabled: blocked, onTap: onNotify),
            ],
          ],
        ),
        const SizedBox(height: 10),
        _RoundProfileButton(
          icon: Icons.chat_bubble_rounded,
          label: 'دردشة',
          onTap: onChat,
          color: AppColors.purple,
          filled: false,
          centerContent: true,
        ),
      ],
    );
  }
}

class _RoundProfileButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color color;
  final Color? background;
  final bool filled;
  final bool centerContent;

  const _RoundProfileButton({required this.icon, required this.label, required this.onTap, required this.color, this.background, required this.filled, this.centerContent = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: filled ? background : AppColors.purple.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: filled ? (background ?? AppColors.purple) : AppColors.purple.withValues(alpha: 0.65)),
          boxShadow: filled ? [BoxShadow(color: AppColors.purple.withValues(alpha: 0.20), blurRadius: 16)] : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 7),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13.5, color: color))),
          ],
        ),
      ),
    );
  }
}

class _AnimatedBellButton extends StatelessWidget {
  final bool enabled;
  final bool disabled;
  final VoidCallback onTap;

  const _AnimatedBellButton({required this.enabled, required this.disabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final child = InkWell(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        width: 56,
        height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled ? Colors.amberAccent.withValues(alpha: 0.17) : AppColors.purple.withValues(alpha: 0.12),
          border: Border.all(color: enabled ? Colors.amberAccent : AppColors.purple.withValues(alpha: 0.65), width: enabled ? 1.5 : 1),
          boxShadow: enabled ? [BoxShadow(color: Colors.amberAccent.withValues(alpha: 0.22), blurRadius: 18)] : null,
        ),
        child: Icon(enabled ? Icons.notifications_active_rounded : Icons.notifications_none_rounded, color: enabled ? Colors.amberAccent : AppColors.purple, size: 23),
      ),
    );
    return enabled
        ? child.animate(onPlay: (controller) => controller.repeat(reverse: true)).shake(duration: 900.ms, hz: 2, rotation: .08)
        : child.animate().fadeIn(duration: 180.ms).scale(begin: const Offset(.95, .95));
  }
}

class _RepliesList extends StatelessWidget {
  final List<CityReply> replies;
  final ImageProvider? Function(String? path) avatarProvider;
  final Future<void> Function(String username)? onMentionTap;
  const _RepliesList({required this.replies, required this.avatarProvider, this.onMentionTap});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (replies.isEmpty) return const Center(child: Text('لا توجد ردود'));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
      itemCount: replies.length,
      itemBuilder: (context, i) {
        final r = replies[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassCard(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(
                borderRadius: BorderRadius.circular(99),
                onTap: () => onMentionTap?.call(r.username),
                child: _ProfileAvatar(radius: 19, imageProvider: avatarProvider(r.avatarPath)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                InkWell(onTap: () => onMentionTap?.call(r.username), child: Text('${r.user}  ${r.username}', style: const TextStyle(fontWeight: FontWeight.w900))),
                const SizedBox(height: 4),
                _MentionText(r.text, onMentionTap: onMentionTap),
                const SizedBox(height: 4),
                Text(r.time, style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
              ])),
            ]),
          ),
        );
      },
    );
  }
}

class _QuotedPostPreview extends StatelessWidget {
  final CityPost post;
  final VoidCallback? onTap;
  const _QuotedPostPreview({required this.post, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.purple.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.purple.withValues(alpha: 0.30)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: AppColors.purple.withValues(alpha: 0.25),
                  backgroundImage: FeedScreenStateHelper.profileImageProvider(post.avatarPath),
                  child: FeedScreenStateHelper.profileImageProvider(post.avatarPath) == null
                      ? const Icon(Icons.person_rounded, size: 14, color: Colors.white)
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: _RespectAuthorName(
                          name: post.user,
                          username: post.username,
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          post.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (post.text.trim().isNotEmpty) ...[
              const SizedBox(height: 7),
              _MentionText(post.text, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, height: 1.35)),
            ],
            if ((post.mediaPath ?? '').trim().isNotEmpty && post.mediaType != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(height: 130, width: double.infinity, child: _PostMedia(path: post.mediaPath!, type: post.mediaType!)),
              ),
            ],
            const SizedBox(height: 6),
            Text(post.time, style: TextStyle(color: muted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  final CityPost post;
  final ImageProvider? avatarProvider;
  final VoidCallback onLike;
  final VoidCallback onFavorite;
  final VoidCallback onRepost;
  final VoidCallback onShare;
  final VoidCallback onMediaTap;
  final VoidCallback onReplies;
  final VoidCallback? onViewed;
  final VoidCallback? onQuoteTap;
  final Future<void> Function(String username)? onMentionTap;
  final List<Map<String, dynamic>>? activeStoriesForUser;
  final bool storiesSeen;
  final VoidCallback? onStoryTap;
  final VoidCallback onAuthorTap;
  final VoidCallback? onMore;
  final VoidCallback? onDelete;
  final bool disableCardTap;

  const _PostCard({
    required this.post,
    required this.avatarProvider,
    required this.onLike,
    required this.onFavorite,
    required this.onRepost,
    required this.onShare,
    required this.onMediaTap,
    required this.onReplies,
    this.onViewed,
    this.onQuoteTap,
    this.onMentionTap,
    this.activeStoriesForUser,
    this.storiesSeen = false,
    this.onStoryTap,
    required this.onAuthorTap,
    this.onMore,
    this.onDelete,
    this.disableCardTap = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mutedColor = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    final isTimelineRepost = post.repostedByUsername != null;
    final dimmedOpacity = isTimelineRepost ? 0.68 : 1.0;
    final repostTint = isDark
        ? Colors.white.withValues(alpha: 0.018)
        : Colors.black.withValues(alpha: 0.018);
    final repostBorderColor = isTimelineRepost
        ? AppColors.purple.withValues(alpha: 0.16)
        : AppColors.purple.withValues(alpha: 0.24);

    Widget dimRepostContent(Widget child) {
      if (!isTimelineRepost) return child;
      return Opacity(
        opacity: dimmedOpacity,
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(
            isDark ? Colors.black.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.12),
            BlendMode.srcATop,
          ),
          child: child,
        ),
      );
    }

    final card = Padding(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: disableCardTap
            ? null
            : () {
          onViewed?.call();
          onReplies();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          decoration: BoxDecoration(
            color: isTimelineRepost ? repostTint : Colors.transparent,
            border: Border(bottom: BorderSide(color: repostBorderColor, width: 0.8)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (post.pinnedInCommunity) ...[
                Container(
                  margin: const EdgeInsetsDirectional.only(start: 32, bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.purple.withValues(alpha: isDark ? 0.18 : 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.purple.withValues(alpha: 0.25)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.push_pin_rounded, size: 15, color: AppColors.purple),
                      SizedBox(width: 5),
                      Text(
                        'تغريدة مثبتة من قبل المشرفين',
                        style: TextStyle(color: AppColors.purple, fontSize: 12.5, fontWeight: FontWeight.w900),
                      ),
                    ],
                  ),
                ),
              ],
              if (isTimelineRepost) ...[
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 32, bottom: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.repeat_rounded, size: 17, color: AppColors.purple),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '${post.repostedByName ?? post.repostedByUsername} أعاد النشر',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: AppColors.purple, fontSize: 12.5, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              dimRepostContent(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: onAuthorTap,
                          borderRadius: BorderRadius.circular(99),
                          child: _ProfileAvatar(
                            radius: 22,
                            imageProvider: avatarProvider,
                            hasStory: activeStoriesForUser?.isNotEmpty == true,
                            storySeen: storiesSeen,
                            onStoryTap: onStoryTap,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              InkWell(
                                onTap: onAuthorTap,
                                borderRadius: BorderRadius.circular(8),
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    return Wrap(
                                      spacing: 5,
                                      runSpacing: 1,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      children: [
                                        ConstrainedBox(
                                          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.45),
                                          child: _RespectAuthorName(
                                            name: post.user,
                                            username: post.username,
                                            verified: post.authorVerified,
                                            style: const TextStyle(fontWeight: FontWeight.w900),
                                          ),
                                        ),
                                        ConstrainedBox(
                                          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.35),
                                          child: Text(
                                            post.username,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(color: mutedColor),
                                          ),
                                        ),
                                        Text('· ${post.time}', style: TextStyle(color: mutedColor, fontSize: 12)),
                                      ],
                                    );
                                  },
                                ),
                              ),
                              if (post.text.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                _MentionText(post.text, style: const TextStyle(fontSize: 15.5, height: 1.45), onMentionTap: onMentionTap),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          // مهم: سابقًا كان العرض 38 لكن زر الثلاث نقاط داخله 42،
                          // وهذا سبب RenderFlex overflowed by 4 pixels على اليمين.
                          width: onDelete != null ? 76 : 38,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (onDelete != null)
                                SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: IconButton(
                                    tooltip: 'حذف التغريدة',
                                    onPressed: onDelete,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger, size: 22),
                                  ),
                                ),
                              SizedBox(
                                width: 38,
                                height: 38,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (onMore != null) {
                                      onMore?.call();
                                    }
                                  },
                                  child: Center(
                                    child: Icon(Icons.more_horiz_rounded, color: mutedColor, size: 22),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if ((post.mediaPath ?? '').trim().isNotEmpty && post.mediaType != null) ...[
                      const SizedBox(height: 12),
                      GestureDetector(onTap: onMediaTap, child: _PostMedia(path: post.mediaPath!, type: post.mediaType!)),
                    ],
                    if ((post.voicePath ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _VoiceBubble(path: post.voicePath!, durationText: _formatStaticSeconds(post.voiceSeconds)),
                    ],
                    if (post.quotedPost != null) ...[
                      const SizedBox(height: 12),
                      _QuotedPostPreview(post: post.quotedPost!, onTap: onQuoteTap),
                    ],
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: _TweetActionRow(
                        isDark: isDark,
                        liked: post.isLiked,
                        saved: post.isFavorite,
                        reposted: post.isReposted,
                        likes: post.likes,
                        replies: post.replyCount,
                        reposts: post.reposts,
                        views: post.views,
                        onReply: onReplies,
                        onLike: onLike,
                        onRepost: onRepost,
                        onSave: onFavorite,
                        onShare: onShare,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final draggableText = post.text.trim();
    if (draggableText.isEmpty) return card;

    return LongPressDraggable<String>(
      data: draggableText,
      delay: const Duration(milliseconds: 280),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () => HapticFeedback.mediumImpact(),
      feedback: _PostTextDragFeedback(text: draggableText),
      childWhenDragging: Opacity(opacity: 0.62, child: card),
      child: card,
    );
  }

  static String _formatStaticSeconds(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}



class _PostTextDragFeedback extends StatelessWidget {
  final String text;

  const _PostTextDragFeedback({required this.text});

  @override
  Widget build(BuildContext context) {
    final preview = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final shortPreview = preview.length > 70 ? '${preview.substring(0, 70)}...' : preview;

    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.82, end: 1.0),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutBack,
          builder: (context, value, child) => Transform.scale(scale: value, child: child),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 250),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.purple.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white.withValues(alpha: 0.34)),
              boxShadow: [
                BoxShadow(
                  color: AppColors.purple.withValues(alpha: 0.45),
                  blurRadius: 28,
                  spreadRadius: 2,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.text_fields_rounded, color: Colors.white, size: 19),
                ),
                const SizedBox(width: 9),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'اسحب للنشر',
                        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        shortPreview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.rtl,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: 12.5, height: 1.25),
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
  }
}

class _SheetOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SheetOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard : AppColors.lightCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.purple.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: AppColors.purple),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
          ],
        ),
      ),
    );
  }
}

class _SmallPurpleAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _SmallPurpleAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppColors.purple.withValues(alpha: .18),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.purple.withValues(alpha: .35)),
          ),
          child: Icon(icon, color: AppColors.purple, size: 21),
        ),
      ),
    );
  }
}

class _BrokenMedia extends StatelessWidget {
  final bool isDark;

  const _BrokenMedia({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 190,
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_rounded, color: isDark ? AppColors.darkMuted : AppColors.lightMuted, size: 34),
          const SizedBox(height: 8),
          Text(
            'تعذر عرض الملف',
            style: TextStyle(
              color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _PostAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color? activeColor;
  final VoidCallback? onTap;
  final bool centerContent;

  const _PostAction({
    required this.icon,
    required this.label,
    this.active = false,
    this.activeColor,
    this.onTap,
    this.centerContent = false,
  });

  const _PostAction.compact({
    required this.icon,
    required this.label,
    this.active = false,
    this.activeColor,
    this.onTap,
  }) : centerContent = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = active ? (activeColor ?? AppColors.purple) : (isDark ? AppColors.darkMuted : AppColors.lightMuted);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
        child: Row(
          mainAxisSize: centerContent ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: centerContent ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 19),
            if (label.trim().isNotEmpty) ...[
              const SizedBox(width: 3),
              Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800)),
            ],
          ],
        ),
      ),
    );
  }
}

class _MediaPreview extends StatelessWidget {
  final String path;
  final CityMediaType type;
  final VoidCallback onRemove;

  const _MediaPreview({
    required this.path,
    required this.type,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isVideo = type == CityMediaType.video;
    final isRemote = path.startsWith('http://') || path.startsWith('https://');
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: double.infinity,
            height: 190,
            color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
            child: isVideo
                ? const Center(child: Icon(Icons.play_circle_fill_rounded, color: AppColors.purple, size: 56))
                : (isRemote
                ? Image.network(path, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _BrokenMedia(isDark: isDark))
                : Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => _BrokenMedia(isDark: isDark))),
          ),
        ),
        PositionedDirectional(
          top: 8,
          end: 8,
          child: InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded, color: Colors.white, size: 18),
            ),
          ),
        ),
        if (isVideo)
          PositionedDirectional(
            bottom: 10,
            start: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.videocam_rounded, color: Colors.white, size: 16),
                  SizedBox(width: 5),
                  Text('فيديو', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _VoicePreview extends StatelessWidget {
  final bool isRecording;
  final String? path;
  final String durationText;
  final VoidCallback onRemove;

  const _VoicePreview({
    required this.isRecording,
    required this.path,
    required this.durationText,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      child: Row(
        children: [
          Icon(isRecording ? Icons.fiber_manual_record_rounded : Icons.mic_rounded, color: isRecording ? AppColors.danger : AppColors.purple),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isRecording ? 'جاري التسجيل... $durationText' : 'تسجيل صوتي $durationText',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          IconButton(
            tooltip: 'حذف التسجيل',
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _VoiceBubble extends StatefulWidget {
  final String path;
  final String durationText;

  const _VoiceBubble({required this.path, required this.durationText});

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  bool _loading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription? _stateSub;
  StreamSubscription? _posSub;
  StreamSubscription? _durSub;

  bool get _isRemote {
    final v = widget.path.trim().toLowerCase();
    return v.startsWith('http://') || v.startsWith('https://');
  }

  @override
  void initState() {
    super.initState();
    _stateSub = _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() {
        _playing = state == PlayerState.playing;
        if (state != PlayerState.playing) _loading = false;
      });
    });
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    try {
      setState(() => _loading = true);
      if (_isRemote) {
        await _player.play(UrlSource(widget.path.trim()));
      } else {
        await _player.play(DeviceFileSource(widget.path.trim()));
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final total = _duration.inMilliseconds <= 0 ? widget.durationText : _PostCard._formatStaticSeconds(_duration.inSeconds);
    final pos = _PostCard._formatStaticSeconds(_position.inSeconds);
    final progress = _duration.inMilliseconds <= 0 ? 0.0 : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: _loading ? null : _toggle,
            borderRadius: BorderRadius.circular(999),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: AppColors.purple,
              child: _loading
                  ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    backgroundColor: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                    color: AppColors.purple,
                  ),
                ),
                const SizedBox(height: 5),
                Text('$pos / $total', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontSize: 11.5, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  final double radius;
  final ImageProvider? imageProvider;
  final bool hasStory;
  final bool storySeen;
  final VoidCallback? onStoryTap;

  const _ProfileAvatar({required this.radius, required this.imageProvider, this.hasStory = false, this.storySeen = false, this.onStoryTap});

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.purple,
      backgroundImage: imageProvider,
      child: imageProvider == null ? Icon(Icons.person, color: Colors.white, size: radius) : null,
    );
    if (!hasStory) return avatar;
    return InkWell(
      onTap: onStoryTap,
      customBorder: const CircleBorder(),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: storySeen
              ? const LinearGradient(colors: [Color(0xFF777777), Color(0xFF4B5563)])
              : const LinearGradient(colors: [Color(0xFFFFD166), AppColors.purple, Color(0xFF06D6A0)]),
          boxShadow: [BoxShadow(color: (storySeen ? Colors.grey : AppColors.purple).withValues(alpha: .28), blurRadius: 14, spreadRadius: 1)],
        ),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkBg : AppColors.lightBg),
          child: avatar,
        ),
      ),
    );
  }
}

class _PostMedia extends StatelessWidget {
  final String path;
  final CityMediaType type;

  const _PostMedia({required this.path, required this.type});

  static bool _isRemote(String value) {
    final v = value.trim().toLowerCase();
    return v.startsWith('http://') || v.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mediaPath = path.trim();

    if (mediaPath.isEmpty) return _BrokenMedia(isDark: isDark);

    final lowerPath = mediaPath.split('?').first.toLowerCase();
    final looksLikeVideo = lowerPath.endsWith('.mp4') ||
        lowerPath.endsWith('.mov') ||
        lowerPath.endsWith('.m4v') ||
        lowerPath.endsWith('.webm') ||
        lowerPath.endsWith('.mkv');

    // حماية إضافية:
    // أحيانًا يرجع رابط فيديو داخل حقل صورة بسبب بيانات قديمة أو إعادة نشر.
    // لا تسمح أبدًا بتمرير فيديو إلى Image.network حتى لا تعلق الواجهة.
    if (looksLikeVideo) {
      return _VideoPlayerBox(path: mediaPath);
    }

    if (type == CityMediaType.image || type == CityMediaType.gif) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: _isRemote(mediaPath)
            ? Image.network(
          mediaPath,
          width: double.infinity,
          fit: BoxFit.cover,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              height: 190,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const CircularProgressIndicator(color: AppColors.purple),
            );
          },
          errorBuilder: (_, __, ___) => _BrokenMedia(isDark: isDark),
        )
            : Image.file(
          File(mediaPath),
          width: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _BrokenMedia(isDark: isDark),
        ),
      );
    }

    return _VideoPlayerBox(path: mediaPath);
  }
}


class _VideoPlayerBox extends StatelessWidget {
  final String path;

  const _VideoPlayerBox({required this.path});

  bool get _isRemote {
    final v = path.trim().toLowerCase();
    return v.startsWith('http://') || v.startsWith('https://');
  }

  String get _cleanFileName {
    final raw = path.trim().split('?').first;
    final parts = raw.split('/').where((e) => e.trim().isNotEmpty).toList();
    final name = parts.isEmpty ? 'video' : parts.last;
    return name.length > 34 ? '${name.substring(0, 31)}...' : name;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 230,
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.black.withValues(alpha: .78),
            AppColors.purple.withValues(alpha: .34),
            Colors.black.withValues(alpha: .88),
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Icon(
                Icons.movie_creation_rounded,
                size: 118,
                color: Colors.white.withValues(alpha: .08),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: .45),
                border: Border.all(color: Colors.white.withValues(alpha: .22)),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.purple.withValues(alpha: .24),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 46),
            ),
          ),
          PositionedDirectional(
            start: 14,
            end: 14,
            bottom: 14,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .42),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withValues(alpha: .12)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.videocam_rounded, color: Colors.white, size: 16),
                      SizedBox(width: 6),
                      Text(
                        'فيديو',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isRemote ? 'اضغط للتشغيل' : _cleanFileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .78),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}



class StoryViewerScreen extends StatefulWidget {
  final List<Map<String, dynamic>> stories;
  const StoryViewerScreen({super.key, required this.stories});

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  late List<Map<String, dynamic>> _stories;
  int _index = 0;
  bool _muted = false;
  bool _liked = false;
  bool _busy = false;
  int _likes = 0;
  int _comments = 0;
  String _currentUsername = '@user';
  VideoPlayerController? _videoController;
  final TextEditingController _commentCtrl = TextEditingController();

  Map<String, dynamic> get _story => _stories[_index];
  String get _storyId => (_story['id'] ?? '').toString();
  String get _ownerUsername => SupabaseService.displayUsername((_story['username'] ?? '').toString());

  @override
  void initState() {
    super.initState();
    _stories = widget.stories.map((e) => Map<String, dynamic>.from(e)).toList();
    _boot();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _commentCtrl.dispose();
    super.dispose();
  }

  bool _isVideo(Map<String, dynamic> story) => (story['media_type'] ?? '').toString().toLowerCase().contains('video');

  Future<void> _boot() async {
    try {
      final me = await SupabaseService.currentUser();
      _currentUsername = SupabaseService.displayUsername((me?['username'] ?? '').toString());
    } catch (e, st) { _logIgnoredError(e, st); }
    await _setupVideoIfNeeded();
    await _loadStats();
    unawaited(SupabaseService.markStoriesSeen([_story]));
  }

  Future<void> _loadStats() async {
    final id = _storyId;
    if (id.isEmpty) return;
    try {
      final results = await Future.wait([
        SupabaseService.storyLikeCount(id),
        SupabaseService.storyCommentCount(id),
        SupabaseService.hasLikedStory(storyId: id, username: _currentUsername),
      ]);
      if (!mounted) return;
      setState(() {
        _likes = results[0] as int;
        _comments = results[1] as int;
        _liked = results[2] as bool;
      });
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _setupVideoIfNeeded() async {
    await _videoController?.dispose();
    _videoController = null;
    final url = (_story['media_url'] ?? '').toString();
    if (!_isVideo(_story) || url.trim().isEmpty) {
      if (mounted) setState(() {});
      return;
    }
    final c = url.startsWith('http') ? VideoPlayerController.networkUrl(Uri.parse(url)) : VideoPlayerController.file(File(url));
    _videoController = c;
    await c.initialize();
    await c.setLooping(true);
    await c.setVolume(_muted ? 0 : 1);
    await c.play();
    if (mounted) setState(() {});
  }

  void _next() {
    if (_index >= _stories.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _index++;
      _liked = false;
      _likes = 0;
      _comments = 0;
    });
    unawaited(_setupVideoIfNeeded());
    unawaited(_loadStats());
    unawaited(SupabaseService.markStoriesSeen([_story]));
  }

  void _previous() {
    if (_index <= 0) return;
    setState(() {
      _index--;
      _liked = false;
      _likes = 0;
      _comments = 0;
    });
    unawaited(_setupVideoIfNeeded());
    unawaited(_loadStats());
    unawaited(SupabaseService.markStoriesSeen([_story]));
  }

  Future<void> _toggleMute() async {
    setState(() => _muted = !_muted);
    await _videoController?.setVolume(_muted ? 0 : 1);
  }

  Future<void> _toggleLike() async {
    if (_busy || _storyId.isEmpty) return;
    setState(() {
      _busy = true;
      _liked = !_liked;
      _likes += _liked ? 1 : -1;
      if (_likes < 0) _likes = 0;
    });
    try {
      final result = await SupabaseService.toggleStoryLike(
        storyId: _storyId,
        ownerUsername: _ownerUsername,
        actorUsername: _currentUsername,
      );
      if (!mounted) return;
      setState(() {
        _liked = result['liked'] == true;
        _likes = int.tryParse((result['likes'] ?? _likes).toString()) ?? _likes;
        _comments = int.tryParse((result['comments'] ?? _comments).toString()) ?? _comments;
      });
    } catch (_) {
      if (mounted) NotificationService.showTopError('تعذر تحديث إعجاب الستوري');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty || _storyId.isEmpty) return;
    _commentCtrl.clear();
    HapticFeedback.lightImpact();
    try {
      await SupabaseService.addStoryComment(
        storyId: _storyId,
        ownerUsername: _ownerUsername,
        actorUsername: _currentUsername,
        text: text,
      );
      if (!mounted) return;
      setState(() => _comments++);
      NotificationService.showTopNotification('تم إرسال التعليق');
    } catch (e) {
      if (mounted) NotificationService.showTopError('تعذر إرسال التعليق: $e');
    }
  }

  ImageProvider? _imageProvider(String? path) {
    final p = path?.trim();
    if (p == null || p.isEmpty) return null;
    if (p.startsWith('http://') || p.startsWith('https://')) return NetworkImage(p);
    final f = File(p);
    if (!f.existsSync()) return null;
    return FileImage(f);
  }

  Widget _media(String url) {
    if (_isVideo(_story)) {
      final controller = _videoController;
      if (controller == null || !controller.value.isInitialized) {
        return const Center(child: CircularProgressIndicator(color: AppColors.purple));
      }
      return FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: controller.value.size.width,
          height: controller.value.size.height,
          child: VideoPlayer(controller),
        ),
      );
    }
    if (url.startsWith('http')) {
      return Image.network(url, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 72));
    }
    final f = File(url);
    return f.existsSync()
        ? Image.file(f, fit: BoxFit.contain)
        : const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 72);
  }

  @override
  Widget build(BuildContext context) {
    if (_stories.isEmpty) return const Scaffold(backgroundColor: Colors.black);
    final url = (_story['media_url'] ?? '').toString();
    final name = (_story['name'] ?? _story['username'] ?? 'Story').toString();
    final username = SupabaseService.displayUsername((_story['username'] ?? '').toString());
    final avatar = (_story['avatar_url'] ?? '').toString();
    final avatarProvider = _imageProvider(avatar);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topRight,
            radius: 1.2,
            colors: [Color(0xFF7C3AED), Color(0xFF160B2E), Colors.black],
            stops: [0, .42, 1],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    final w = MediaQuery.of(context).size.width;
                    if (d.localPosition.dx < w * .35) {
                      _previous();
                    } else if (d.localPosition.dx > w * .65) {
                      _next();
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 72, 8, 118),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .38),
                          border: Border.all(color: Colors.white.withValues(alpha: .12)),
                          boxShadow: [BoxShadow(color: AppColors.purple.withValues(alpha: .25), blurRadius: 42)],
                        ),
                        child: Center(child: _media(url)),
                      ),
                    ),
                  ),
                ),
              ),
              PositionedDirectional(
                top: 10,
                start: 12,
                end: 12,
                child: Column(
                  children: [
                    Row(
                      children: List.generate(_stories.length, (i) => Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          height: 4,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            gradient: i <= _index ? const LinearGradient(colors: [AppColors.purpleLight, Colors.white]) : null,
                            color: i <= _index ? null : Colors.white24,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      )),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(2.2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(colors: [AppColors.purpleLight, AppColors.purple, Color(0xFFFF4FD8)]),
                            boxShadow: [BoxShadow(color: AppColors.purple.withValues(alpha: .45), blurRadius: 18)],
                          ),
                          child: CircleAvatar(
                            radius: 20,
                            backgroundColor: AppColors.purple,
                            backgroundImage: avatarProvider,
                            child: avatarProvider == null ? const Icon(Icons.person_rounded, color: Colors.white) : null,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15)),
                              Text(username, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: .65), fontWeight: FontWeight.w700, fontSize: 12)),
                            ],
                          ),
                        ),
                        _FeedStoryRoundButton(icon: _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, onTap: _toggleMute),
                        _FeedStoryRoundButton(icon: Icons.close_rounded, onTap: () => Navigator.of(context).pop()),
                      ],
                    ),
                  ],
                ),
              ),
              PositionedDirectional(
                bottom: 12 + bottomInset,
                start: 12,
                end: 12,
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white.withValues(alpha: .16)),
                        ),
                        child: TextField(
                          controller: _commentCtrl,
                          minLines: 1,
                          maxLines: 3,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                          decoration: InputDecoration(
                            hintText: 'اكتب تعليق...',
                            hintStyle: TextStyle(color: Colors.white.withValues(alpha: .58)),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                          onSubmitted: (_) => _sendComment(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _FeedStoryRoundButton(icon: Icons.send_rounded, onTap: _sendComment, filled: true),
                    const SizedBox(width: 8),
                    _FeedStoryRoundButton(icon: _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, onTap: _toggleLike, filled: _liked),
                  ],
                ),
              ),
              PositionedDirectional(
                bottom: 78 + bottomInset,
                start: 18,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .30),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withValues(alpha: .13)),
                  ),
                  child: Text('$_likes إعجاب · $_comments تعليق', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeedStoryRoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;
  const _FeedStoryRoundButton({required this.icon, required this.onTap, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? AppColors.purple : Colors.white.withValues(alpha: .12),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 43,
          height: 43,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: .14)),
            boxShadow: filled ? [BoxShadow(color: AppColors.purple.withValues(alpha: .38), blurRadius: 18)] : null,
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

class FullscreenMediaViewer extends StatefulWidget {
  final String path;
  final CityMediaType type;
  final CityPost? post;
  final Future<void> Function()? onLike;
  final Future<void> Function()? onReply;
  final Future<void> Function()? onRepost;
  final Future<void> Function()? onFavorite;

  const FullscreenMediaViewer({
    super.key,
    required this.path,
    required this.type,
    this.post,
    this.onLike,
    this.onReply,
    this.onRepost,
    this.onFavorite,
  });

  @override
  State<FullscreenMediaViewer> createState() => _FullscreenMediaViewerState();
}

class _FullscreenMediaViewerState extends State<FullscreenMediaViewer> {
  bool _expandedText = false;

  bool get _isImage => widget.type == CityMediaType.image || widget.type == CityMediaType.gif;

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: _isImage
                          ? InteractiveViewer(
                        minScale: 0.7,
                        maxScale: 4,
                        child: _FullscreenImage(path: widget.path),
                      )
                          : _FullscreenVideoPlayer(path: widget.path),
                    ),
                  ),
                  if (post != null) _FullscreenTweetInfo(
                    post: post,
                    expanded: _expandedText,
                    onToggle: () => setState(() => _expandedText = !_expandedText),
                    onLike: widget.onLike == null ? null : () async {
                      await widget.onLike!();
                      if (mounted) setState(() {});
                    },
                    onReply: widget.onReply,
                    onRepost: widget.onRepost == null ? null : () async {
                      await widget.onRepost!();
                      if (mounted) setState(() {});
                    },
                    onFavorite: widget.onFavorite == null ? null : () async {
                      await widget.onFavorite!();
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
            ),
            PositionedDirectional(
              top: 8,
              start: 8,
              child: CircleAvatar(
                backgroundColor: Colors.black.withValues(alpha: 0.45),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenImage extends StatelessWidget {
  final String path;
  const _FullscreenImage({required this.path});

  bool get _isRemote {
    final v = path.trim().toLowerCase();
    return v.startsWith('http://') || v.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final p = path.trim();
    if (p.isEmpty) return const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 72);
    final lowerPath = p.split('?').first.toLowerCase();
    final looksLikeVideo = lowerPath.endsWith('.mp4') ||
        lowerPath.endsWith('.mov') ||
        lowerPath.endsWith('.m4v') ||
        lowerPath.endsWith('.webm') ||
        lowerPath.endsWith('.mkv');
    if (looksLikeVideo) {
      return _FullscreenVideoPlayer(path: p);
    }
    return _isRemote
        ? Image.network(
      p,
      fit: BoxFit.contain,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return const Center(child: CircularProgressIndicator(color: AppColors.purple));
      },
      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 72),
    )
        : Image.file(
      File(p),
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 72),
    );
  }
}

class _FullscreenVideoPlayer extends StatefulWidget {
  final String path;
  const _FullscreenVideoPlayer({required this.path});

  @override
  State<_FullscreenVideoPlayer> createState() => _FullscreenVideoPlayerState();
}

class _FullscreenVideoPlayerState extends State<_FullscreenVideoPlayer> {
  CachedVideoPlayerPlusController? _cachedController;
  VideoPlayerController? _networkController;
  VideoPlayerController? _fileController;
  bool _ready = false;
  bool _hasError = false;
  bool _usingNetworkFallback = false;
  bool _showControls = true;

  bool get _isRemote {
    final v = widget.path.trim().toLowerCase();
    return v.startsWith('http://') || v.startsWith('https://');
  }

  dynamic get _controller {
    if (_isRemote) {
      return _usingNetworkFallback ? _networkController : _cachedController;
    }
    return _fileController;
  }

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      if (_isRemote) {
        await _initCachedRemoteVideo();
      } else {
        final fileController = VideoPlayerController.file(
          File(widget.path.trim()),
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
        _fileController = fileController;
        await fileController.initialize();
      }
      final controller = _controller;
      if (controller == null) throw Exception('Video controller was not initialized');
      await controller.setLooping(false);
      controller.addListener(_onVideoChanged);
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _hasError = true);
    }
  }

  Future<void> _initCachedRemoteVideo() async {
    final uri = Uri.parse(widget.path.trim());
    try {
      final cachedController = CachedVideoPlayerPlusController.networkUrl(
        uri,
        invalidateCacheIfOlderThan: const Duration(days: 7),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _cachedController = cachedController;
      await cachedController.initialize().timeout(const Duration(seconds: 8));
      _usingNetworkFallback = false;
    } catch (_) {
      try { await _cachedController?.dispose(); } catch (e, st) { _logIgnoredError(e, st); }
      _cachedController = null;
      _usingNetworkFallback = true;
      final safeUri = uri.replace(
        queryParameters: <String, String>{
          ...uri.queryParameters,
          'respect_cache_fix': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );
      final networkController = VideoPlayerController.networkUrl(
        safeUri,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _networkController = networkController;
      await networkController.initialize().timeout(const Duration(seconds: 12));
    }
  }

  void _onVideoChanged() {
    if (!mounted) return;
    try {
      final controller = _controller;
      if (controller == null) return;
      if (controller.value.hasError) {
        setState(() => _hasError = true);
        return;
      }
    } catch (e, st) { _logIgnoredError(e, st); }
    setState(() {});
  }

  @override
  void dispose() {
    try { _cachedController?.removeListener(_onVideoChanged); } catch (e, st) { _logIgnoredError(e, st); }
    try { _networkController?.removeListener(_onVideoChanged); } catch (e, st) { _logIgnoredError(e, st); }
    try { _fileController?.removeListener(_onVideoChanged); } catch (e, st) { _logIgnoredError(e, st); }
    _cachedController?.dispose();
    _networkController?.dispose();
    _fileController?.dispose();
    super.dispose();
  }

  String _format(Duration duration) {
    final total = duration.inSeconds;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _videoWidget() {
    if (_isRemote) {
      if (_usingNetworkFallback) {
        final controller = _networkController;
        return controller == null ? const SizedBox.shrink() : VideoPlayer(controller);
      }
      final controller = _cachedController;
      return controller == null ? const SizedBox.shrink() : CachedVideoPlayerPlus(controller);
    }
    final controller = _fileController;
    return controller == null ? const SizedBox.shrink() : VideoPlayer(controller);
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) return const Center(child: Icon(Icons.broken_image_rounded, color: Colors.white54, size: 72));
    if (!_ready) return const Center(child: CircularProgressIndicator(color: AppColors.purple));

    final controller = _controller;
    if (controller == null) return const Center(child: CircularProgressIndicator(color: AppColors.purple));
    final value = controller.value;
    final duration = value.duration;
    final position = value.position;
    final aspect = value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _showControls = !_showControls),
      child: Stack(
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: aspect,
              child: _videoWidget(),
            ),
          ),
          if (value.isBuffering)
            Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator(color: AppColors.purple)),
            ),
          Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: _showControls ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => value.isPlaying ? controller.pause() : controller.play(),
                    child: Container(
                      width: 74,
                      height: 74,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.42),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Icon(value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 54),
                    ),
                  ),
                ),
              ),
            ),
          ),
          PositionedDirectional(
            start: 20,
            end: 20,
            bottom: 18,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: _showControls ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8)),
                      child: Slider(
                        min: 0,
                        max: duration.inMilliseconds <= 0 ? 1 : duration.inMilliseconds.toDouble(),
                        value: position.inMilliseconds.clamp(0, duration.inMilliseconds <= 0 ? 1 : duration.inMilliseconds).toDouble(),
                        onChanged: (v) => controller.seekTo(Duration(milliseconds: v.toInt())),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_format(position), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
                        Text(_format(duration), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FullscreenTweetInfo extends StatelessWidget {
  final CityPost post;
  final bool expanded;
  final VoidCallback onToggle;
  final Future<void> Function()? onLike;
  final Future<void> Function()? onReply;
  final Future<void> Function()? onRepost;
  final Future<void> Function()? onFavorite;

  const _FullscreenTweetInfo({
    required this.post,
    required this.expanded,
    required this.onToggle,
    this.onLike,
    this.onReply,
    this.onRepost,
    this.onFavorite,
  });

  @override
  Widget build(BuildContext context) {
    final text = post.text.trim();
    final hasMore = text.length > 110;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.92),
        border: const Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.purple.withValues(alpha: 0.35),
                backgroundImage: _avatarProvider(post.avatarPath),
                child: _avatarProvider(post.avatarPath) == null ? const Icon(Icons.person_rounded, color: Colors.white, size: 18) : null,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(post.user, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16))),
              Text(post.username, style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w700)),
            ],
          ),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              text,
              maxLines: expanded ? 12 : 2,
              overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.35),
              textDirection: TextDirection.rtl,
            ),
            if (hasMore)
              TextButton(
                onPressed: onToggle,
                child: Text(expanded ? 'عرض أقل' : 'المزيد', style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900)),
              ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              _FullscreenAction(
                icon: Icons.chat_bubble_outline_rounded,
                label: '${post.replyCount}',
                onTap: onReply == null ? null : () async {
                  Navigator.of(context).pop();
                  await onReply!();
                },
              ),
              const SizedBox(width: 18),
              _FullscreenAction(
                icon: Icons.repeat_rounded,
                label: '${post.reposts}',
                color: post.isReposted ? AppColors.purple : Colors.white70,
                onTap: onRepost == null ? null : () async => onRepost!(),
              ),
              const SizedBox(width: 18),
              _FullscreenAction(
                icon: post.isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                label: '${post.likes}',
                color: post.isLiked ? AppColors.danger : Colors.white70,
                onTap: onLike == null ? null : () async => onLike!(),
              ),
              const SizedBox(width: 18),
              _FullscreenAction(
                icon: post.isFavorite ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                label: '',
                color: post.isFavorite ? AppColors.purple : Colors.white70,
                onTap: onFavorite == null ? null : () async => onFavorite!(),
              ),
              const Spacer(),
              _FullscreenAction(icon: Icons.bar_chart_rounded, label: '${post.views}'),
            ],
          ),
        ],
      ),
    );
  }

  ImageProvider? _avatarProvider(String? path) {
    final p = path?.trim();
    if (p == null || p.isEmpty) return null;
    if (FeedScreenStateHelper._looksLikeVideoPath(p)) return null;
    if (p.startsWith('http://') || p.startsWith('https://')) return NetworkImage(p);
    final file = File(p);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }
}


class _FullscreenAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Future<void> Function()? onTap;

  const _FullscreenAction({
    required this.icon,
    required this.label,
    this.color = Colors.white70,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
      ],
    );
    if (onTap == null) return child;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () async => onTap!(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
        child: child,
      ),
    );
  }
}

class PostDetailsScreen extends StatefulWidget {
  final CityPost post;
  final ImageProvider? Function(String? path) avatarProviderForPath;
  final String currentName;
  final String currentUsername;
  final String? currentAvatarPath;
  final VoidCallback onLike;
  final VoidCallback onFavorite;
  final VoidCallback onRepost;
  final VoidCallback onShare;
  final VoidCallback onMediaTap;
  final VoidCallback? onQuoteTap;
  final Future<void> Function(String username)? onOpenProfile;
  final Future<void> Function() onChanged;

  const PostDetailsScreen({
    super.key,
    required this.post,
    required this.avatarProviderForPath,
    required this.currentName,
    required this.currentUsername,
    required this.currentAvatarPath,
    required this.onLike,
    required this.onFavorite,
    required this.onRepost,
    required this.onShare,
    required this.onMediaTap,
    this.onQuoteTap,
    this.onOpenProfile,
    required this.onChanged,
  });

  @override
  State<PostDetailsScreen> createState() => _PostDetailsScreenState();
}

class _PostDetailsScreenState extends State<PostDetailsScreen> {
  final TextEditingController _replyCtrl = TextEditingController();
  final FocusNode _replyFocus = FocusNode();
  final ImagePicker _replyPicker = ImagePicker();
  final AudioRecorder _replyRecorder = AudioRecorder();
  XFile? _replyMedia;
  CityMediaType? _replyMediaType;
  String? _replyVoicePath;
  bool _recordingReply = false;
  int _replyVoiceSeconds = 0;
  Timer? _replyRecordTimer;
  bool _sendingReply = false;
  String? _replyingToUser;
  String? _replyingToUsername;

  @override
  void dispose() {
    _replyRecordTimer?.cancel();
    if (_recordingReply) {
      unawaited(_replyRecorder.stop());
    }
    _replyRecorder.dispose();
    _replyFocus.dispose();
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshReplies() async {
    try {
      final freshReplies = await SupabaseService
          .getPostReplies(widget.post.id, currentUsername: widget.currentUsername)
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        widget.post.replies
          ..clear()
          ..addAll(_sortedReplies(freshReplies.map(CityReply.fromJson)));
        widget.post.replyCount = widget.post.replies.length;
      });
      await widget.onChanged();
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _pickInlineReplyAttachment(_AttachmentChoice choice) async {
    if (choice == _AttachmentChoice.video) {
      final file = await _replyPicker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      setState(() {
        _replyMedia = file;
        _replyMediaType = CityMediaType.video;
        _replyVoicePath = null;
        _replyVoiceSeconds = 0;
      });
      return;
    }

    final file = await _replyPicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: choice == _AttachmentChoice.gif ? null : 85,
    );
    if (file == null) return;
    setState(() {
      _replyMedia = file;
      _replyMediaType = choice == _AttachmentChoice.gif ? CityMediaType.gif : CityMediaType.image;
      _replyVoicePath = null;
      _replyVoiceSeconds = 0;
    });
  }

  Future<void> _toggleInlineReplyRecording() async {
    if (_recordingReply) {
      _replyRecordTimer?.cancel();
      final path = await _replyRecorder.stop();
      if (!mounted) return;
      setState(() {
        _recordingReply = false;
        _replyVoicePath = path;
        _replyMedia = null;
        _replyMediaType = null;
      });
      return;
    }

    final hasPermission = await _replyRecorder.hasPermission();
    if (!hasPermission) {
      NotificationService.showTopNotification('يجب السماح للتطبيق باستخدام المايكروفون');
      return;
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/respect_reply_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _replyRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
      path: path,
    );
    setState(() {
      _recordingReply = true;
      _replyVoicePath = null;
      _replyVoiceSeconds = 0;
      _replyMedia = null;
      _replyMediaType = null;
    });
    _replyRecordTimer?.cancel();
    _replyRecordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _replyVoiceSeconds++);
    });
  }

  void _clearInlineReplyAttachment() {
    _replyRecordTimer?.cancel();
    if (_recordingReply) {
      unawaited(_replyRecorder.stop());
    }
    setState(() {
      _recordingReply = false;
      _replyMedia = null;
      _replyMediaType = null;
      _replyVoicePath = null;
      _replyVoiceSeconds = 0;
    });
  }

  void _startReplyToReply(CityReply reply) {
    setState(() {
      _replyingToUser = reply.user;
      _replyingToUsername = reply.username;
    });
    _replyFocus.requestFocus();
  }

  void _cancelReplyToReply() {
    setState(() {
      _replyingToUser = null;
      _replyingToUsername = null;
    });
  }

  Future<void> _toggleReplyLike(CityReply reply) async {
    final previousLiked = reply.isLiked;
    final previousLikes = reply.likes;
    setState(() {
      reply.isLiked = !reply.isLiked;
      reply.likes = (reply.likes + (reply.isLiked ? 1 : -1)).clamp(0, 1 << 30);
    });

    try {
      final result = await SupabaseService.toggleReplyLike(
        replyId: reply.id,
        username: widget.currentUsername,
      );
      if (!mounted) return;
      setState(() {
        reply.isLiked = result['isLiked'] == true;
        reply.likes = int.tryParse((result['likes'] ?? reply.likes).toString()) ?? reply.likes;
        reply.reposts = int.tryParse((result['reposts'] ?? reply.reposts).toString()) ?? reply.reposts;
        reply.views = int.tryParse((result['views'] ?? reply.views).toString()) ?? reply.views;
      });
      await widget.onChanged();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        reply.isLiked = previousLiked;
        reply.likes = previousLikes;
      });
      NotificationService.showTopError('تعذر تحديث لايك الرد');
    }
  }

  Future<void> _toggleReplyFavorite(CityReply reply) async {
    setState(() => reply.isFavorite = !reply.isFavorite);
    await widget.onChanged();
    NotificationService.showTopNotification(reply.isFavorite ? 'تم حفظ الرد' : 'تم إزالة الرد من المحفوظات');
  }

  Future<void> _toggleReplyRepost(CityReply reply) async {
    final previousReposted = reply.isReposted;
    final previousReposts = reply.reposts;
    setState(() {
      reply.isReposted = !reply.isReposted;
      reply.reposts = (reply.reposts + (reply.isReposted ? 1 : -1)).clamp(0, 1 << 30).toInt();
    });

    try {
      final result = await SupabaseService.toggleReplyRepost(
        replyId: reply.id,
        username: widget.currentUsername,
      );
      if (!mounted) return;
      setState(() {
        reply.isReposted = result['isReposted'] == true;
        reply.likes = int.tryParse((result['likes'] ?? reply.likes).toString()) ?? reply.likes;
        reply.reposts = int.tryParse((result['reposts'] ?? reply.reposts).toString()) ?? reply.reposts;
        reply.views = int.tryParse((result['views'] ?? reply.views).toString()) ?? reply.views;
      });
      await widget.onChanged();
      NotificationService.showTopNotification(reply.isReposted ? 'تمت إعادة نشر الرد' : 'تم إلغاء إعادة نشر الرد');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        reply.isReposted = previousReposted;
        reply.reposts = previousReposts;
      });
      NotificationService.showTopError('تعذر حفظ إعادة نشر الرد في السيرفر: $e');
    }
  }

  Future<void> _quoteReply(CityReply reply) async {
    setState(() {
      _replyingToUser = reply.user;
      _replyingToUsername = reply.username;
      final quoteText = reply.text.trim().isEmpty ? 'اقتباس رد' : 'اقتباس: ${reply.text.trim()}';
      _replyCtrl.text = quoteText.length > 120 ? '${quoteText.substring(0, 120)}… ' : '$quoteText ';
      _replyCtrl.selection = TextSelection.collapsed(offset: _replyCtrl.text.length);
    });
    _replyFocus.requestFocus();
  }

  Future<void> _showInlineReplyPlusMenu() async {
    final choice = await showModalBottomSheet<_AttachmentChoice>(
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
                const SizedBox(height: 18),
                const Text('إضافة مع الرد', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 14),
                _SheetOption(icon: Icons.image_rounded, title: 'إضافة صورة', subtitle: 'إرفاق صورة مع الرد', onTap: () => Navigator.pop(context, _AttachmentChoice.image)),
                const SizedBox(height: 10),
                _SheetOption(icon: Icons.mic_rounded, title: _recordingReply ? 'إيقاف الصوتية' : 'إضافة صوتية', subtitle: _recordingReply ? 'إنهاء التسجيل الصوتي' : 'تسجيل رد صوتي قصير', onTap: () => Navigator.pop(context, _AttachmentChoice.audio)),
                const SizedBox(height: 10),
                _SheetOption(icon: Icons.videocam_rounded, title: 'إضافة فيديو', subtitle: 'إرفاق فيديو مع الرد', onTap: () => Navigator.pop(context, _AttachmentChoice.video)),
              ],
            ).animate().fadeIn(duration: 180.ms).slideY(begin: .10, end: 0, duration: 220.ms, curve: Curves.easeOutCubic),
          ),
        );
      },
    );

    if (choice == null) return;
    if (choice == _AttachmentChoice.audio) {
      await _toggleInlineReplyRecording();
    } else {
      await _pickInlineReplyAttachment(choice);
    }
  }

  Future<void> _sendInlineReply() async {
    if (_sendingReply) return;
    if (_recordingReply) {
      NotificationService.showTopNotification('اضغط إيقاف التسجيل أولًا ثم أرسل الرد');
      return;
    }
    final text = _replyCtrl.text.trim();
    if (text.isEmpty && _replyMedia == null && _replyVoicePath == null) return;

    FocusScope.of(context).unfocus();
    setState(() => _sendingReply = true);

    try {
      final now = DateTime.now();
      CityReply reply = CityReply(
        id: 'reply_${widget.post.id}_${now.microsecondsSinceEpoch}',
        user: widget.currentName,
        username: widget.currentUsername,
        text: text,
        time: 'الآن',
        avatarPath: widget.currentAvatarPath,
        mediaPath: _replyMedia?.path,
        mediaType: _replyMediaType,
        voicePath: _replyVoicePath,
        voiceSeconds: _replyVoiceSeconds,
        parentUser: _replyingToUser,
        sortMillis: now.millisecondsSinceEpoch,
      );

      try {
        final inserted = await SupabaseService.addPostReply(
          postId: widget.post.id,
          authorUsername: widget.currentUsername,
          authorName: widget.currentName,
          text: text,
          parentUser: _replyingToUser,
          mediaUrl: _replyVoicePath ?? _replyMedia?.path ?? '',
          mediaType: _replyVoicePath != null ? 'voice' : (_replyMediaType?.name ?? ''),
        ).timeout(const Duration(seconds: 12));
        reply = CityReply.fromJson(inserted);
      } catch (e) {
        assert(() { _scannerSafeIgnore(); return true; }());
      }

      if (!mounted) return;
      setState(() {
        widget.post.replies.add(reply);
        widget.post.replies
          ..clear()
          ..addAll(_sortedReplies(widget.post.replies));
        widget.post.replyCount = widget.post.replies.length;
        _replyCtrl.clear();
        _replyMedia = null;
        _replyMediaType = null;
        _replyVoicePath = null;
        _replyVoiceSeconds = 0;
        _replyingToUser = null;
        _replyingToUsername = null;
      });

      await _refreshReplies();
      if (!mounted) return;
      NotificationService.showTopSuccess('تم نشر الرد');
    } catch (e) {
      assert(() { _scannerSafeIgnore(); return true; }());
      if (mounted) {
        NotificationService.showTopError('تعذر نشر الرد');
      }
    } finally {
      if (mounted) setState(() => _sendingReply = false);
    }
  }

  Widget _replyComposer(bool isDark) {
    final borderColor = isDark ? AppColors.darkBorder : AppColors.lightBorder;
    final cardColor = isDark ? AppColors.darkCard : AppColors.lightCard;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyingToUser != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.purple.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.purple.withValues(alpha: 0.28)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.reply_rounded, color: AppColors.purple, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'ردًا على ${_replyingToUser!}${(_replyingToUsername ?? '').trim().isNotEmpty ? '  ${_replyingToUsername}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900, fontSize: 12),
                      ),
                    ),
                    InkWell(
                      onTap: _cancelReplyToReply,
                      borderRadius: BorderRadius.circular(99),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close_rounded, color: AppColors.purple, size: 18),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (_replyMedia != null && _replyMediaType != null) ...[
              _InlineReplyAttachmentPreview(
                mediaPath: _replyMedia?.path ?? '',
                mediaType: _replyMediaType!,
                onRemove: _clearInlineReplyAttachment,
              ),
              const SizedBox(height: 8),
            ],
            if (_recordingReply || _replyVoicePath != null) ...[
              _InlineReplyVoicePreview(
                isRecording: _recordingReply,
                path: _replyVoicePath,
                durationText: _PostCard._formatStaticSeconds(_replyVoiceSeconds),
                onRemove: _clearInlineReplyAttachment,
                onStop: _recordingReply ? () => unawaited(_toggleInlineReplyRecording()) : null,
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                _SmallPurpleAction(icon: Icons.add_rounded, tooltip: 'إضافة مع الرد', onTap: _showInlineReplyPlusMenu),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _replyCtrl,
                    focusNode: _replyFocus,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendInlineReply(),
                    decoration: InputDecoration(
                      hintText: _replyingToUser == null ? 'نشر ردّك' : 'اكتب ردك على ${_replyingToUser!}',
                      hintStyle: TextStyle(color: muted, fontWeight: FontWeight.w700),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: AppColors.purple,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _sendingReply ? null : _sendInlineReply,
                    child: SizedBox(
                      width: 42,
                      height: 42,
                      child: Center(
                        child: _sendingReply
                            ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                            : const Icon(Icons.send_rounded, color: Colors.white, size: 21),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل التغريدة', style: TextStyle(fontWeight: FontWeight.w900))),
      body: RefreshIndicator(
        onRefresh: _refreshReplies,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _PostCard(
              post: widget.post,
              avatarProvider: widget.avatarProviderForPath(widget.post.avatarPath),
              onLike: widget.onLike,
              onFavorite: widget.onFavorite,
              onRepost: widget.onRepost,
              onShare: widget.onShare,
              onMediaTap: widget.onMediaTap,
              onReplies: () => _replyFocus.requestFocus(),
              onQuoteTap: widget.onQuoteTap,
              onMentionTap: widget.onOpenProfile,
              onAuthorTap: () { widget.onOpenProfile?.call(widget.post.username); },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  _StatPill(icon: Icons.visibility_rounded, text: '${widget.post.views}'),
                  const SizedBox(width: 8),
                  _StatPill(icon: Icons.chat_bubble_rounded, text: '${widget.post.replyCount} ردود'),
                  const SizedBox(width: 8),
                  _StatPill(icon: Icons.repeat_rounded, text: '${widget.post.reposts}'),
                ],
              ),
            ),
            _replyComposer(isDark),
            Divider(color: AppColors.purple.withValues(alpha: 0.28)),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('الردود', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: isDark ? Colors.white : Colors.black87)),
            ),
            if (widget.post.replies.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: Text('لا توجد ردود بعد', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted))),
              )
            else
              ...List.generate(_sortedReplies(widget.post.replies).length, (index) {
                final r = _sortedReplies(widget.post.replies)[index];
                final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
                return Column(
                  children: [
                    if (index > 0) Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Divider(color: AppColors.purple.withValues(alpha: 0.45), thickness: 1),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(99),
                            onTap: () => widget.onOpenProfile?.call(r.username),
                            child: CircleAvatar(
                              backgroundColor: AppColors.purple.withValues(alpha: 0.25),
                              backgroundImage: widget.avatarProviderForPath(r.avatarPath),
                              child: widget.avatarProviderForPath(r.avatarPath) == null
                                  ? const Icon(Icons.person_rounded, color: Colors.white, size: 18)
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 2,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    InkWell(
                                      onTap: () => widget.onOpenProfile?.call(r.username),
                                      child: _RespectAuthorName(
                                        name: r.user,
                                        username: r.username,
                                        style: const TextStyle(fontWeight: FontWeight.w900),
                                      ),
                                    ),
                                    Text(r.username, style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w700)),
                                    Text(r.time, style: TextStyle(color: muted, fontSize: 11, fontWeight: FontWeight.w700)),
                                  ],
                                ),
                                if ((r.parentUser?.trim().isNotEmpty ?? false)) ...[
                                  const SizedBox(height: 4),
                                  Text('ردًا على ${r.parentUser}', style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w800, fontSize: 12)),
                                ],
                                if (r.text.trim().isNotEmpty) ...[
                                  const SizedBox(height: 5),
                                  _MentionText(r.text, onMentionTap: widget.onOpenProfile),
                                ],
                                if ((r.mediaPath ?? '').trim().isNotEmpty && r.mediaType != null) ...[
                                  const SizedBox(height: 10),
                                  _PostMedia(path: r.mediaPath!, type: r.mediaType!),
                                ],
                                if ((r.voicePath ?? '').trim().isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  _VoiceBubble(path: r.voicePath!, durationText: _PostCard._formatStaticSeconds(r.voiceSeconds)),
                                ],
                                const SizedBox(height: 8),
                                _ReplyActionBar(
                                  reply: r,
                                  onReply: () => _startReplyToReply(r),
                                  onLike: () => _toggleReplyLike(r),
                                  onRepost: () => _toggleReplyRepost(r),
                                  onQuote: () => _quoteReply(r),
                                  onFavorite: () => _toggleReplyFavorite(r),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }),
          ],
        ),
      ),
    );
  }
}



class _ReplyActionBar extends StatelessWidget {
  final CityReply reply;
  final VoidCallback onReply;
  final VoidCallback onLike;
  final VoidCallback onRepost;
  final VoidCallback onQuote;
  final VoidCallback onFavorite;

  const _ReplyActionBar({
    required this.reply,
    required this.onReply,
    required this.onLike,
    required this.onRepost,
    required this.onQuote,
    required this.onFavorite,
  });

  @override
  Widget build(BuildContext context) {
    Widget item({required IconData icon, required String label, required VoidCallback onTap, Color? color}) {
      final c = color ?? (Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black54);
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(99),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: c),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w900, fontSize: 12)),
            ],
          ),
        ),
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        item(icon: Icons.chat_bubble_outline_rounded, label: 'رد', onTap: onReply, color: AppColors.purple),
        item(icon: reply.isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded, label: '${reply.likes}', onTap: onLike, color: reply.isLiked ? AppColors.danger : null),
        item(icon: Icons.repeat_rounded, label: '${reply.reposts}', onTap: onRepost, color: reply.isReposted ? AppColors.success : null),
        item(icon: Icons.visibility_outlined, label: '${reply.views}', onTap: () {}, color: null),
        item(icon: Icons.format_quote_rounded, label: 'اقتباس', onTap: onQuote, color: AppColors.purple),
        item(icon: reply.isFavorite ? Icons.bookmark_rounded : Icons.bookmark_border_rounded, label: '', onTap: onFavorite, color: reply.isFavorite ? AppColors.purple : null),
      ],
    );
  }
}

class _InlineReplyAttachmentPreview extends StatelessWidget {
  final String mediaPath;
  final CityMediaType mediaType;
  final VoidCallback onRemove;

  const _InlineReplyAttachmentPreview({
    required this.mediaPath,
    required this.mediaType,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        height: 86,
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: mediaType == CityMediaType.video
                  ? Container(
                width: 132,
                height: 82,
                color: Colors.black26,
                child: const Icon(Icons.videocam_rounded, color: AppColors.purple),
              )
                  : Image.file(File(mediaPath), width: 132, height: 82, fit: BoxFit.cover),
            ),
            PositionedDirectional(
              top: 4,
              end: 4,
              child: InkWell(
                onTap: onRemove,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineReplyVoicePreview extends StatelessWidget {
  final bool isRecording;
  final String? path;
  final String durationText;
  final VoidCallback onRemove;
  final VoidCallback? onStop;

  const _InlineReplyVoicePreview({
    required this.isRecording,
    required this.path,
    required this.durationText,
    required this.onRemove,
    this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.purple.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.purple.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(isRecording ? Icons.fiber_manual_record_rounded : Icons.mic_rounded, color: isRecording ? AppColors.danger : AppColors.purple),
          const SizedBox(width: 8),
          Expanded(child: Text(isRecording ? 'جاري التسجيل $durationText' : 'صوتية مرفقة $durationText', style: const TextStyle(fontWeight: FontWeight.w900))),
          if (isRecording)
            TextButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_rounded, size: 18),
              label: const Text('إيقاف'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: AppColors.danger,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              ),
            ),
          IconButton(visualDensity: VisualDensity.compact, onPressed: onRemove, icon: const Icon(Icons.close_rounded)),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String text;
  const _StatPill({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, color: AppColors.purple, size: 17), const SizedBox(width: 5), Text(text, style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900, fontSize: 12))]),
  );
}

class CityPost {
  final String id;
  final String user;
  final String username;
  final String text;
  final String time;
  final String? avatarPath;
  final String? mediaPath;
  final CityMediaType? mediaType;
  final String? voicePath;
  final int voiceSeconds;
  final List<CityReply> replies;
  int likes;
  int reposts;
  int shares;
  int views;
  int replyCount;
  bool isLiked;
  bool isFavorite;
  bool isReposted;
  final CityPost? quotedPost;
  final String? repostedByUsername;
  final String? repostedByName;
  final String? repostedByAvatarPath;
  final String? repostedAt;
  final int? timelineSortMillis;
  final bool authorVerified;
  final String audience;
  final String communityId;
  final String communityName;
  bool hiddenFromCommunity;
  bool pinnedInCommunity;

  CityPost({
    required this.id,
    required this.user,
    required this.username,
    required this.text,
    required this.time,
    this.avatarPath,
    this.mediaPath,
    this.mediaType,
    this.voicePath,
    this.voiceSeconds = 0,
    List<CityReply>? replies,
    this.likes = 0,
    this.reposts = 0,
    this.shares = 0,
    this.views = 0,
    int? replyCount,
    this.isLiked = false,
    this.isFavorite = false,
    this.isReposted = false,
    this.quotedPost,
    this.repostedByUsername,
    this.repostedByName,
    this.repostedByAvatarPath,
    this.repostedAt,
    this.timelineSortMillis,
    this.authorVerified = false,
    this.audience = 'public',
    this.communityId = '',
    this.communityName = '',
    this.hiddenFromCommunity = false,
    this.pinnedInCommunity = false,
  })  : replies = List<CityReply>.of(replies ?? const <CityReply>[]),
        replyCount = replyCount ?? (replies?.length ?? 0);

  factory CityPost.fromJson(Map<String, dynamic> json) {
    return CityPost(
      id: (json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString()).toString(),
      user: (json['user'] ?? 'User').toString(),
      username: (json['username'] ?? '@user').toString(),
      text: (json['text'] ?? '').toString(),
      time: (json['time'] ?? 'الآن').toString(),
      avatarPath: json['avatarPath']?.toString(),
      mediaPath: json['mediaPath']?.toString(),
      mediaType: json['mediaType'] == null ? null : CityMediaType.values.firstWhere(
            (e) => e.name == json['mediaType'].toString(),
        orElse: () => CityMediaType.image,
      ),
      voicePath: json['voicePath']?.toString(),
      voiceSeconds: int.tryParse((json['voiceSeconds'] ?? 0).toString()) ?? 0,
      likes: int.tryParse((json['likes'] ?? 0).toString()) ?? 0,
      reposts: int.tryParse((json['reposts'] ?? 0).toString()) ?? 0,
      shares: int.tryParse((json['shares'] ?? 0).toString()) ?? 0,
      views: int.tryParse((json['views'] ?? 0).toString()) ?? 0,
      replyCount: int.tryParse((json['replyCount'] ?? json['reply_count'] ?? '').toString()) ?? (json['replies'] is List ? (json['replies'] as List).length : 0),
      isLiked: json['isLiked'] == true,
      isFavorite: json['isFavorite'] == true,
      isReposted: json['isReposted'] == true,
      quotedPost: json['quotedPost'] is Map ? CityPost.fromJson(Map<String, dynamic>.from((json['quotedPost'] as Map).map((k, v) => MapEntry(k.toString(), v)))) : null,
      repostedByUsername: json['repostedByUsername']?.toString(),
      repostedByName: json['repostedByName']?.toString(),
      repostedByAvatarPath: json['repostedByAvatarPath']?.toString(),
      repostedAt: json['repostedAt']?.toString(),
      timelineSortMillis: int.tryParse((json['timelineSortMillis'] ?? '').toString()),
      authorVerified: SupabaseService.truthy(json['author_verified'] ?? json['authorVerified'] ?? json['is_verified'] ?? json['verified']),
      audience: (json['audience'] ?? 'public').toString(),
      communityId: (json['communityId'] ?? json['community_id'] ?? '').toString(),
      communityName: (json['communityName'] ?? json['community_name'] ?? '').toString(),
      hiddenFromCommunity: json['hiddenFromCommunity'] == true || json['hidden_from_community'] == true || json['community_hidden'] == true,
      pinnedInCommunity: json['pinnedInCommunity'] == true || json['pinned_in_community'] == true || json['community_pinned'] == true,
      replies: (json['replies'] is List)
          ? (json['replies'] as List)
          .whereType<Map>()
          .map((e) => CityReply.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList()
          : [],
    );
  }

  CityPost copyForEmbed() => CityPost(
    id: id,
    user: user,
    username: username,
    text: text,
    time: time,
    avatarPath: avatarPath,
    mediaPath: mediaPath,
    mediaType: mediaType,
    voicePath: voicePath,
    voiceSeconds: voiceSeconds,
    likes: likes,
    reposts: reposts,
    shares: shares,
    views: views,
    replyCount: replyCount,
    authorVerified: authorVerified,
    audience: audience,
    communityId: communityId,
    communityName: communityName,
    hiddenFromCommunity: hiddenFromCommunity,
    pinnedInCommunity: pinnedInCommunity,
  );

  CityPost copyAsRepost({
    required String repostedByUsername,
    required String repostedByName,
    String? repostedByAvatarPath,
    String? repostedAt,
    int? timelineSortMillis,
  }) => CityPost(
    id: id,
    user: user,
    username: username,
    text: text,
    time: time,
    avatarPath: avatarPath,
    mediaPath: mediaPath,
    mediaType: mediaType,
    voicePath: voicePath,
    voiceSeconds: voiceSeconds,
    replies: replies,
    likes: likes,
    reposts: reposts,
    shares: shares,
    views: views,
    replyCount: replyCount,
    isLiked: isLiked,
    isFavorite: isFavorite,
    isReposted: isReposted,
    quotedPost: quotedPost,
    repostedByUsername: repostedByUsername,
    repostedByName: repostedByName,
    repostedByAvatarPath: repostedByAvatarPath,
    repostedAt: repostedAt,
    timelineSortMillis: timelineSortMillis,
    authorVerified: authorVerified,
    audience: audience,
    communityId: communityId,
    communityName: communityName,
    hiddenFromCommunity: hiddenFromCommunity,
    pinnedInCommunity: pinnedInCommunity,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'user': user,
    'username': username,
    'text': text,
    'time': time,
    'avatarPath': avatarPath,
    'mediaPath': mediaPath,
    'mediaType': mediaType?.name,
    'voicePath': voicePath,
    'voiceSeconds': voiceSeconds,
    'likes': likes,
    'reposts': reposts,
    'shares': shares,
    'views': views,
    'replyCount': replyCount,
    'isLiked': isLiked,
    'isFavorite': isFavorite,
    'isReposted': isReposted,
    'quotedPost': quotedPost?.toJson(),
    'repostedByUsername': repostedByUsername,
    'repostedByName': repostedByName,
    'repostedByAvatarPath': repostedByAvatarPath,
    'repostedAt': repostedAt,
    'timelineSortMillis': timelineSortMillis,
    'authorVerified': authorVerified,
    'audience': audience,
    'communityId': communityId,
    'communityName': communityName,
    'hiddenFromCommunity': hiddenFromCommunity,
    'pinnedInCommunity': pinnedInCommunity,
    'replies': replies.map((r) => r.toJson()).toList(),
  };
}

class CityReply {
  final String id;
  final String user;
  final String username;
  final String text;
  final String time;
  final String? avatarPath;
  final String? parentUser;
  final String? parentReplyId;
  final String? mediaPath;
  final CityMediaType? mediaType;
  final String? voicePath;
  final int voiceSeconds;
  final int? sortMillis;
  int likes;
  int reposts;
  int shares;
  int views;
  bool isLiked;
  bool isFavorite;
  bool isReposted;

  CityReply({
    String? id,
    required this.user,
    this.username = '@user',
    required this.text,
    required this.time,
    this.avatarPath,
    this.parentUser,
    this.parentReplyId,
    this.mediaPath,
    this.mediaType,
    this.voicePath,
    this.voiceSeconds = 0,
    this.sortMillis,
    this.likes = 0,
    this.reposts = 0,
    this.shares = 0,
    this.views = 0,
    this.isLiked = false,
    this.isFavorite = false,
    this.isReposted = false,
  }) : id = (id == null || id.trim().isEmpty)
      ? 'reply_${DateTime.now().microsecondsSinceEpoch}'
      : id;

  factory CityReply.fromJson(Map<String, dynamic> json) {
    String? clean(dynamic value) {
      final v = value?.toString().trim();
      if (v == null || v.isEmpty || v.toLowerCase() == 'null') return null;
      return v;
    }

    final createdAt = clean(json['created_at'] ?? json['createdAt']) ?? '';
    final parsedCreatedAt = DateTime.tryParse(createdAt);
    final sortMillis = parsedCreatedAt?.toLocal().millisecondsSinceEpoch ??
        int.tryParse((json['sortMillis'] ?? json['sort_millis'] ?? '').toString());

    var rawMediaType = clean(json['mediaType'] ?? json['media_type'])?.toLowerCase();
    final rawMediaPath = clean(json['mediaPath'] ?? json['media_url']);
    final rawVoicePath = clean(json['voicePath'] ?? json['voice_url']);
    if (rawMediaPath != null) {
      final lowerMedia = rawMediaPath.split('?').first.toLowerCase();
      final looksVideo = lowerMedia.endsWith('.mp4') || lowerMedia.endsWith('.mov') || lowerMedia.endsWith('.m4v') || lowerMedia.endsWith('.webm') || lowerMedia.endsWith('.mkv');
      final looksImage = lowerMedia.endsWith('.jpg') || lowerMedia.endsWith('.jpeg') || lowerMedia.endsWith('.png') || lowerMedia.endsWith('.webp') || lowerMedia.endsWith('.gif');
      if (looksVideo) rawMediaType = 'video';
      if ((rawMediaType == null || rawMediaType.isEmpty) && looksImage) rawMediaType = lowerMedia.endsWith('.gif') ? 'gif' : 'image';
    }
    final isVoice = rawMediaType == 'voice' || rawMediaType == 'audio';
    final hasNormalMedia = !isVoice && rawMediaPath != null && rawMediaType != null;

    return CityReply(
      id: (json['id'] ?? json['reply_id'] ?? json['replyId'] ?? '').toString(),
      user: (json['user'] ?? json['author_name'] ?? json['authorName'] ?? 'User').toString(),
      username: SupabaseService.displayUsername((json['username'] ?? json['author_username'] ?? json['authorUsername'] ?? '@user').toString()),
      text: (json['text'] ?? '').toString(),
      time: (json['time'] ?? (createdAt.trim().isEmpty ? 'الآن' : FeedScreenStateHelper.formatPostTime(createdAt))).toString(),
      avatarPath: clean(json['avatarPath'] ?? json['avatar_url'] ?? json['author_avatar_url']),
      parentUser: clean(json['parentUser'] ?? json['parent_user']),
      parentReplyId: clean(json['parentReplyId'] ?? json['parent_reply_id'] ?? json['parent_replyId']),
      mediaPath: hasNormalMedia ? rawMediaPath : null,
      mediaType: hasNormalMedia
          ? CityMediaType.values.firstWhere(
            (e) => e.name == rawMediaType,
        orElse: () => CityMediaType.image,
      )
          : null,
      voicePath: rawVoicePath ?? (isVoice ? rawMediaPath : null),
      voiceSeconds: int.tryParse((json['voiceSeconds'] ?? json['voice_seconds'] ?? 0).toString()) ?? 0,
      sortMillis: sortMillis,
      likes: int.tryParse((json['likes'] ?? json['reply_likes'] ?? 0).toString()) ?? 0,
      reposts: int.tryParse((json['reposts'] ?? json['reply_reposts'] ?? 0).toString()) ?? 0,
      shares: int.tryParse((json['shares'] ?? 0).toString()) ?? 0,
      views: int.tryParse((json['views'] ?? 0).toString()) ?? 0,
      isLiked: json['isLiked'] == true || json['is_liked'] == true,
      isFavorite: json['isFavorite'] == true || json['is_favorite'] == true,
      isReposted: json['isReposted'] == true || json['is_reposted'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user': user,
    'username': username,
    'text': text,
    'time': time,
    'avatarPath': avatarPath,
    'parentUser': parentUser,
    'parentReplyId': parentReplyId,
    'mediaPath': mediaPath,
    'mediaType': mediaType?.name,
    'voicePath': voicePath,
    'voiceSeconds': voiceSeconds,
    'sortMillis': sortMillis,
    'likes': likes,
    'reposts': reposts,
    'shares': shares,
    'views': views,
    'isLiked': isLiked,
    'isFavorite': isFavorite,
    'isReposted': isReposted,
  };
}




class CommunityScreen extends StatefulWidget {
  final CityCommunity community;
  final String currentUsername;
  final String currentName;
  final String? currentAvatarPath;
  final ImageProvider? Function(String? path) avatarProviderForPath;
  final Future<void> Function() onChanged;

  const CommunityScreen({
    super.key,
    required this.community,
    required this.currentUsername,
    required this.currentName,
    required this.currentAvatarPath,
    required this.avatarProviderForPath,
    required this.onChanged,
  });

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 5, vsync: this);

  bool get _isOwner => widget.community.ownerUsername == widget.currentUsername;
  bool get _isMod => _isOwner || widget.community.moderators.contains(widget.currentUsername);
  bool get _isMember => widget.community.members.contains(widget.currentUsername);

  List<CityPost> get _posts {
    final visible = widget.community.posts.where((p) => !p.hiddenFromCommunity).toList();
    visible.sort((a, b) {
      if (a.pinnedInCommunity != b.pinnedInCommunity) return a.pinnedInCommunity ? -1 : 1;
      return 0;
    });
    return visible;
  }
  List<CityPost> get _mediaPosts => _posts.where((p) => p.mediaPath != null || p.voicePath != null).toList();

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _joinLeave() async {
    setState(() {
      if (_isMember) {
        if (!_isOwner) {
          widget.community.members.remove(widget.currentUsername);
          widget.community.moderators.remove(widget.currentUsername);
        }
      } else {
        if (widget.community.kickedMembers.contains(widget.currentUsername)) {
          NotificationService.showTopError('تم طردك من هذا المجتمع ولا يمكنك الرجوع');
          return;
        }
        widget.community.members.add(widget.currentUsername);
      }
    });
    await widget.onChanged();
  }

  Future<void> _addModerator() async {
    final candidates = widget.community.members.where((u) => !widget.community.moderators.contains(u)).toList();
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBg : AppColors.lightBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
          ),
          child: SafeArea(
            top: false,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
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
                const SizedBox(height: 16),
                const Text('إضافة مشرف', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 12),
                if (candidates.isEmpty)
                  const ListTile(title: Text('لا يوجد أعضاء لإضافتهم كمشرفين'))
                else
                  ...candidates.map((u) => ListTile(
                    title: Text(u),
                    leading: const Icon(Icons.person_add_alt_1_rounded, color: AppColors.purple),
                    onTap: () => Navigator.pop(context, u),
                  )),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null) return;
    setState(() => widget.community.moderators.add(selected));
    await widget.onChanged();
  }

  Future<void> _removeModerator(String username) async {
    if (!_isOwner || username == widget.community.ownerUsername) return;
    setState(() => widget.community.moderators.remove(username));
    await widget.onChanged();
  }

  Future<void> _removeMember(String username) async {
    if (!_isMod || username == widget.community.ownerUsername) return;
    setState(() {
      widget.community.members.remove(username);
      widget.community.moderators.remove(username);
      if (!widget.community.kickedMembers.contains(username)) widget.community.kickedMembers.add(username);
    });
    await widget.onChanged();
  }

  Future<void> _composeCommunityPost() async {
    if (!_isMember) {
      NotificationService.showTopNotification('تابع المجتمع أولاً حتى تستطيع النشر');
      return;
    }

    final post = await Navigator.of(context).push<CityPost>(
      MaterialPageRoute(
        builder: (_) => ComposePostScreen(
          profileName: widget.currentName,
          username: widget.currentUsername,
          profileImagePath: widget.currentAvatarPath,
        ),
      ),
    );

    if (post == null) return;
    setState(() => widget.community.posts.insert(0, post));
    await widget.onChanged();
  }

  Future<void> _toggleLike(CityPost post) async {
    setState(() {
      post.isLiked = !post.isLiked;
      post.likes += post.isLiked ? 1 : -1;
      if (post.likes < 0) post.likes = 0;
    });
    await widget.onChanged();
  }

  Future<void> _toggleFavorite(CityPost post) async {
    setState(() => post.isFavorite = !post.isFavorite);
    await widget.onChanged();
  }

  String _postShareText(CityPost post) => '${post.user} ${post.username}\n${post.text}\nrespect://post/${post.id}';

  Future<void> _savePostEventNotification({
    required String type,
    required String targetUsername,
    required String postId,
    required String text,
  }) async {
    final target = SupabaseService.displayUsername(targetUsername);
    final author = SupabaseService.displayUsername(widget.currentUsername);
    if (target == author) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('respect_post_events_v1');
    final items = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) items.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    items.insert(0, {
      'id': '${type}_${postId}_${DateTime.now().microsecondsSinceEpoch}',
      'type': type,
      'targetUsername': target,
      'authorUsername': author,
      'authorName': widget.currentName,
      'postId': postId,
      'text': text,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString('respect_post_events_v1', jsonEncode(items.take(300).toList()));
  }

  Future<void> _repostPost(CityPost post) async {
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
    if (action == 'quote') {
      final quote = await Navigator.of(context).push<CityPost>(
        MaterialPageRoute(builder: (_) => ComposePostScreen(profileName: widget.currentName, username: widget.currentUsername, profileImagePath: widget.currentAvatarPath)),
      );
      if (quote != null) {
        setState(() => widget.community.posts.insert(0, CityPost(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          user: quote.user,
          username: quote.username,
          avatarPath: quote.avatarPath,
          text: '${quote.text}\n\nاقتباس من ${post.username}: ${post.text}',
          time: 'الآن',
          mediaPath: quote.mediaPath,
          mediaType: quote.mediaType,
          voicePath: quote.voicePath,
          voiceSeconds: quote.voiceSeconds,
        )));
        await widget.onChanged();
      }
      return;
    }
    if (action != 'repost') return;
    if (post.isReposted) {
      if (!mounted) return;
      NotificationService.showTopNotification('أنت أعدت نشر هذه التغريدة مسبقًا');
      return;
    }
    setState(() { post.isReposted = true; post.reposts += 1; });
    await widget.onChanged();
    if (!mounted) return;
    NotificationService.showTopNotification('تمت إعادة النشر');
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
                ListTile(leading: const Icon(Icons.chat_rounded, color: AppColors.success), title: const Text('إرسال للواتس', style: TextStyle(fontWeight: FontWeight.w900)), subtitle: const Text('سيتم نسخ نص التغريدة لتلصقه في واتساب'), onTap: () => Navigator.pop(context, 'whatsapp')),
                ListTile(leading: const Icon(Icons.link_rounded, color: AppColors.purple), title: const Text('نسخ رابط التغريدة', style: TextStyle(fontWeight: FontWeight.w900)), onTap: () => Navigator.pop(context, 'copy')),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null) return;
    setState(() => post.shares += 1);
    await Clipboard.setData(ClipboardData(text: _postShareText(post)));
    await widget.onChanged();
    if (!mounted) return;
    NotificationService.showTopNotification(choice == 'whatsapp' ? 'تم نسخ التغريدة، افتح واتساب والصقها' : 'تم نسخ رابط التغريدة');
  }

  void _openMedia(CityPost post) {
    final mediaPath = post.mediaPath?.trim();
    final mediaType = post.mediaType;
    if (mediaPath == null || mediaPath.isEmpty || mediaType == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => FullscreenMediaViewer(
      path: mediaPath,
      type: mediaType,
      post: post,
      onLike: () => _toggleLike(post),
      onReply: () => _openReplies(post),
      onFavorite: () => _toggleFavorite(post),
    )));
  }

  Future<void> _openReplies(CityPost post) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RepliesScreen(
          post: post,
          currentName: widget.currentName,
          currentUsername: widget.currentUsername,
          currentAvatarPath: widget.currentAvatarPath,
          currentAvatarProvider: widget.avatarProviderForPath(widget.currentAvatarPath),
          avatarProviderForPath: widget.avatarProviderForPath,
          onLike: _toggleLike,
          onFavorite: _toggleFavorite,
          onRepost: _repostPost,
          onShare: _sharePost,
          onChanged: () async {
            if (mounted) setState(() {});
            await widget.onChanged();
          },
        ),
      ),
    );
    if (mounted) setState(() {});
    await widget.onChanged();
  }

  void _openAuthorFromCommunity(CityPost post) {
    NotificationService.showTopNotification('${post.user} ${post.username}');
  }

  Future<void> _hidePost(CityPost post) async {
    if (!_isMod && post.username != widget.currentUsername) return;
    setState(() => post.hiddenFromCommunity = true);
    await widget.onChanged();
    if (mounted) NotificationService.showTopSuccess('تم إخفاء التغريدة من المجتمع');
  }

  Future<void> _togglePinPost(CityPost post) async {
    if (!_isMod) return;
    final pinned = widget.community.posts.where((p) => p.pinnedInCommunity && !p.hiddenFromCommunity).length;
    if (!post.pinnedInCommunity && pinned >= 3) {
      NotificationService.showTopError('مسموح 3 تغريدات مثبتة فقط');
      return;
    }
    setState(() => post.pinnedInCommunity = !post.pinnedInCommunity);
    await widget.onChanged();
    if (mounted) NotificationService.showTopSuccess(post.pinnedInCommunity ? 'تم تثبيت التغريدة' : 'تم إلغاء التثبيت');
  }

  Future<void> _saveReportResultNotification({
    required String targetUsername,
    required String postId,
    required String text,
    required String communityName,
    required bool validReport,
    required String aiReason,
  }) async {
    final target = SupabaseService.displayUsername(targetUsername);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('respect_post_events_v1');
    final items = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          items.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    final type = validReport ? 'community_report_accepted' : 'community_report_rejected';
    items.insert(0, {
      'id': '${type}_${postId}_${DateTime.now().microsecondsSinceEpoch}',
      'type': type,
      'targetUsername': target,
      'authorUsername': SupabaseService.respectAiUsername,
      'authorName': SupabaseService.respectAiName,
      'postId': postId,
      'text': text,
      'communityName': communityName,
      'aiReason': aiReason,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString('respect_post_events_v1', jsonEncode(items.take(300).toList()));
  }

  Future<void> _reportCommunityPost(CityPost post) async {
    String reason = 'محتوى مخالف';
    String details = '';
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('بلاغ للمشرفين', style: TextStyle(fontWeight: FontWeight.w900)),
        content: StatefulBuilder(
          builder: (context, setLocal) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: reason,
                  decoration: const InputDecoration(labelText: 'نوع البلاغ'),
                  items: const [
                    DropdownMenuItem(value: 'محتوى مخالف', child: Text('محتوى مخالف')),
                    DropdownMenuItem(value: 'سرقة محتوى', child: Text('سرقة محتوى')),
                    DropdownMenuItem(value: 'سبام أو إزعاج', child: Text('سبام أو إزعاج')),
                    DropdownMenuItem(value: 'تحرش أو إساءة', child: Text('تحرش أو إساءة')),
                    DropdownMenuItem(value: 'معلومات مضللة', child: Text('معلومات مضللة')),
                    DropdownMenuItem(value: 'بلاغ مخصص', child: Text('بلاغ مخصص')),
                  ],
                  onChanged: (v) => setLocal(() => reason = v ?? reason),
                ),
                const SizedBox(height: 12),
                TextField(
                  minLines: 3,
                  maxLines: 6,
                  onChanged: (value) => details = value,
                  decoration: InputDecoration(
                    labelText: reason == 'بلاغ مخصص' ? 'اكتب البلاغ الذي تريده' : 'اشرح البلاغ بالتفصيل',
                    hintText: reason == 'بلاغ مخصص' ? 'اكتب بلاغك كامل هنا' : 'اختياري، لكنه يساعد المشرفين والذكاء الاصطناعي',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إرسال')),
        ],
      ),
    );
    details = details.trim();
    if (submitted != true) return;
    if (reason == 'بلاغ مخصص' && details.isEmpty) {
      NotificationService.showTopError('اكتب تفاصيل البلاغ المخصص أولاً');
      return;
    }
    final report = CommunityReport(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      postId: post.id,
      reporterUsername: widget.currentUsername,
      reporterName: widget.currentName,
      postUsername: post.username,
      postUser: post.user,
      reason: reason,
      details: details,
      createdAt: DateTime.now().toIso8601String(),
    );
    setState(() => widget.community.reports.insert(0, report));
    await widget.onChanged();
    try {
      await SupabaseService.reportPost(
        postId: post.id,
        reporterUsername: widget.currentUsername,
        reason: report.reason,
        details: report.details,
        communityId: widget.community.id,
        communityName: widget.community.name,
        postUsername: post.username,
        postText: post.text,
      );
    } catch (e, st) { _logIgnoredError(e, st); }
    unawaited(_reviewCommunityReportWithAi(report, post));
    if (mounted) NotificationService.showTopSuccess('تم إرسال البلاغ للمشرفين');
  }

  Future<void> _reviewCommunityReportWithAi(CommunityReport report, CityPost post) async {
    try {
      final result = await SupabaseService.reviewPostReportWithAi(
        reportId: report.id,
        postId: post.id,
        reporterUsername: report.reporterUsername,
        reportedUsername: post.username,
        reason: report.reason,
        details: report.details,
        postText: post.text,
        communityId: widget.community.id,
        communityName: widget.community.name,
      );
      final valid = result['validReport'] == true || result['shouldDelete'] == true || result['action'] == 'hide';
      setState(() {
        report.status = valid ? 'accepted' : 'rejected';
        report.aiDecision = valid ? 'accepted' : 'rejected';
        report.aiReason = (result['reason'] ?? '').toString();
        if (valid) post.hiddenFromCommunity = true;
      });
      await widget.onChanged();
      await _saveReportResultNotification(
        targetUsername: report.reporterUsername,
        postId: post.id,
        text: post.text,
        communityName: widget.community.name,
        validReport: valid,
        aiReason: report.aiReason,
      );
      try {
        await SupabaseService.createPostEventNotification(
          type: valid ? 'community_report_accepted' : 'community_report_rejected',
          targetUsername: report.reporterUsername,
          actorUsername: SupabaseService.respectAiUsername,
          actorName: SupabaseService.respectAiName,
          postId: post.id,
          text: post.text,
        );
      } catch (e, st) { _logIgnoredError(e, st); }
      try {
        await SupabaseService.sendPushToUser(
          receiverUsername: report.reporterUsername,
          type: 'post_event',
          title: valid ? 'تم قبول البلاغ' : 'نتيجة البلاغ',
          body: valid
              ? 'راجعنا البلاغ داخل ${widget.community.name} وتم اتخاذ إجراء.'
              : 'راجعنا البلاغ داخل ${widget.community.name} والتغريدة سليمة.',
          data: {
            'postId': post.id,
            'post_id': post.id,
            'eventType': valid ? 'community_report_accepted' : 'community_report_rejected',
            'communityName': widget.community.name,
            'text': post.text,
          },
        );
      } catch (e, st) { _logIgnoredError(e, st); }
      if (!valid && SupabaseService.displayUsername(report.reporterUsername) == SupabaseService.displayUsername(widget.currentUsername)) {
        NotificationService.showTopNotification(
          'راجعنا البلاغ داخل ${widget.community.name}، والتغريدة سليمة ولا يوجد عليها أي مشكلة.',
          title: 'نتيجة البلاغ',
          icon: Icons.verified_user_rounded,
          accentColor: AppColors.success,
        );
      }
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _deletePost(CityPost post) => _hidePost(post);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
      appBar: AppBar(
        title: Text(widget.community.name, style: const TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          if (_isMod)
            IconButton(
              tooltip: 'إضافة مشرف',
              onPressed: _addModerator,
              icon: const Icon(Icons.admin_panel_settings_rounded),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'community_compose_${widget.community.id}',
        backgroundColor: _isMember ? AppColors.purple : AppColors.purple.withValues(alpha: 0.35),
        foregroundColor: Colors.white,
        onPressed: _composeCommunityPost,
        icon: const Icon(Icons.edit_rounded),
        label: const Text('نشر', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: _CommunityHeroCard(
                community: widget.community,
                isMember: _isMember,
                isOwner: _isOwner,
                isMod: _isMod,
                onJoinLeave: _joinLeave,
              ),
            ),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabsHeaderDelegate(
              TabBar(
                controller: _tabController,
                labelColor: AppColors.purple,
                unselectedLabelColor: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                indicatorColor: AppColors.purple,
                tabs: const [
                  Tab(text: 'التغريدات'),
                  Tab(text: 'الوسائط'),
                  Tab(text: 'الأعضاء'),
                  Tab(text: 'البلاغات'),
                  Tab(text: 'المطرودين'),
                ],
              ),
              isDark: isDark,
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabController,
          children: [
            _CommunityPostsTab(
              posts: _posts,
              emptyText: _isMember ? 'لا توجد تغريدات في المجتمع بعد' : 'تابع المجتمع لمشاهدة التفاعل والنشر',
              avatarProviderForPath: widget.avatarProviderForPath,
              canModerate: _isMod,
              currentUsername: widget.currentUsername,
              onLike: _toggleLike,
              onFavorite: _toggleFavorite,
              onRepost: _repostPost,
              onShare: _sharePost,
              onMediaTap: _openMedia,
              onReplies: _openReplies,
              onAuthorTap: _openAuthorFromCommunity,
              onDelete: _hidePost,
              onReport: _reportCommunityPost,
              onPin: _togglePinPost,
            ),
            _CommunityPostsTab(
              posts: _mediaPosts,
              emptyText: 'لا توجد صور أو فيديوهات بعد',
              avatarProviderForPath: widget.avatarProviderForPath,
              canModerate: _isMod,
              currentUsername: widget.currentUsername,
              onLike: _toggleLike,
              onFavorite: _toggleFavorite,
              onRepost: _repostPost,
              onShare: _sharePost,
              onMediaTap: _openMedia,
              onReplies: _openReplies,
              onAuthorTap: _openAuthorFromCommunity,
              onDelete: _hidePost,
              onReport: _reportCommunityPost,
              onPin: _togglePinPost,
            ),
            _CommunityMembersTab(
              community: widget.community,
              currentUsername: widget.currentUsername,
              isOwner: _isOwner,
              isMod: _isMod,
              isDark: isDark,
              onAddModerator: _addModerator,
              onRemoveModerator: _removeModerator,
              onRemoveMember: _removeMember,
            ),
            _CommunityReportsTab(community: widget.community, isMod: _isMod, isDark: isDark),
            _CommunityKickedTab(community: widget.community, isMod: _isMod, isDark: isDark, onUnkick: (u) async { setState(() => widget.community.kickedMembers.remove(u)); await widget.onChanged(); }),
          ],
        ),
      ),
    );
  }
}

class _CommunityHeroCard extends StatelessWidget {
  final CityCommunity community;
  final bool isMember;
  final bool isOwner;
  final bool isMod;
  final Future<void> Function() onJoinLeave;

  const _CommunityHeroCard({
    required this.community,
    required this.isMember,
    required this.isOwner,
    required this.isMod,
    required this.onJoinLeave,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 122,
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              gradient: LinearGradient(colors: [AppColors.purple, Color(0xFF312E81)]),
            ),
            child: Stack(
              children: [
                PositionedDirectional(
                  end: -14,
                  top: -20,
                  child: Icon(Icons.groups_3_rounded, size: 145, color: Colors.white.withValues(alpha: 0.08)),
                ),
                const PositionedDirectional(
                  start: 18,
                  bottom: 16,
                  child: Icon(Icons.forum_rounded, color: Colors.white, size: 42),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        community.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                      ),
                    ),
                    if (isMod)
                      const _MiniChip(text: 'مشرف', color: AppColors.purple),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  community.description.isEmpty ? 'مجتمع Respect App للنقاش والتغريدات والوسائط' : community.description,
                  style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, height: 1.45),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 14,
                  runSpacing: 8,
                  children: [
                    _MiniStat(value: '${community.posts.length}', label: 'تغريدة'),
                    _MiniStat(value: '${community.mediaCount}', label: 'وسائط'),
                    _MiniStat(value: '${community.members.length}', label: 'عضو'),
                    _MiniStat(value: '${community.moderators.length}', label: 'مشرف'),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: isOwner ? null : onJoinLeave,
                    style: FilledButton.styleFrom(
                      backgroundColor: isMember ? (isDark ? AppColors.darkCard2 : AppColors.lightCard2) : AppColors.purple,
                      foregroundColor: isMember ? (isDark ? Colors.white : Colors.black87) : Colors.white,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    icon: Icon(isOwner ? Icons.workspace_premium_rounded : (isMember ? Icons.check_circle_rounded : Icons.group_add_rounded)),
                    label: Text(
                      isOwner ? 'أنت مالك المجتمع' : (isMember ? 'أنت عضو - إلغاء المتابعة' : 'متابعة المجتمع'),
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CommunityPostsTab extends StatelessWidget {
  final List<CityPost> posts;
  final String emptyText;
  final ImageProvider? Function(String? path) avatarProviderForPath;
  final bool canModerate;
  final String currentUsername;
  final Future<void> Function(CityPost post) onLike;
  final Future<void> Function(CityPost post) onFavorite;
  final Future<void> Function(CityPost post) onRepost;
  final Future<void> Function(CityPost post) onShare;
  final void Function(CityPost post) onMediaTap;
  final Future<void> Function(CityPost post) onReplies;
  final Future<void> Function(CityPost post)? onViewed;
  final void Function(CityPost post) onAuthorTap;
  final Future<void> Function(CityPost post) onDelete;
  final Future<void> Function(CityPost post)? onReport;
  final Future<void> Function(CityPost post)? onPin;

  const _CommunityPostsTab({
    required this.posts,
    required this.emptyText,
    required this.avatarProviderForPath,
    required this.canModerate,
    required this.currentUsername,
    required this.onLike,
    required this.onFavorite,
    required this.onRepost,
    required this.onShare,
    required this.onMediaTap,
    required this.onReplies,
    this.onViewed,
    required this.onAuthorTap,
    required this.onDelete,
    this.onReport,
    this.onPin,
  });

  Future<void> _showCommunityPostActions(BuildContext context, CityPost post, bool canDelete) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
        return SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkBg : AppColors.lightBg,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: AppColors.purple.withValues(alpha: 0.25)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 46,
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppColors.purple.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.flag_rounded, color: Colors.orange),
                  title: const Text('إبلاغ المشرفين', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text('إرسال بلاغ عن هذه التغريدة داخل المجتمع', style: TextStyle(color: muted, fontSize: 12)),
                  onTap: () => Navigator.pop(sheetContext, 'report'),
                ),
                if (canModerate)
                  ListTile(
                    leading: const Icon(Icons.push_pin_rounded, color: AppColors.purple),
                    title: Text(post.pinnedInCommunity ? 'إلغاء التثبيت' : 'تثبيت التغريدة', style: const TextStyle(fontWeight: FontWeight.w900)),
                    subtitle: Text('يمكن تثبيت حتى 3 تغريدات داخل المجتمع', style: TextStyle(color: muted, fontSize: 12)),
                    onTap: () => Navigator.pop(sheetContext, 'pin'),
                  ),
                if (canDelete || canModerate)
                  ListTile(
                    leading: const Icon(Icons.visibility_off_rounded, color: AppColors.danger),
                    title: const Text('إخفاء من المجتمع', style: TextStyle(fontWeight: FontWeight.w900)),
                    subtitle: Text('لن تظهر هذه التغريدة داخل المجتمع', style: TextStyle(color: muted, fontSize: 12)),
                    onTap: () => Navigator.pop(sheetContext, 'hide'),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (choice == 'report') await onReport?.call(post);
    if (choice == 'hide') await onDelete(post);
    if (choice == 'pin') await onPin?.call(post);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (posts.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 90),
          Icon(Icons.mode_comment_rounded, size: 76, color: AppColors.purple.withValues(alpha: 0.9)),
          const SizedBox(height: 14),
          Center(child: Text(emptyText, textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900))),
          const SizedBox(height: 6),
          Text(
            'انشر تغريدة، صورة، فيديو، GIF أو تسجيل صوتي داخل المجتمع.',
            textAlign: TextAlign.center,
            style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 110),
      itemCount: posts.length,
      itemBuilder: (context, i) {
        final post = posts[i];
        final canDelete = canModerate || post.username == currentUsername;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            _PostCard(
              post: post,
              avatarProvider: avatarProviderForPath(post.avatarPath),
              onLike: () => onLike(post),
              onFavorite: () => onFavorite(post),
              onRepost: () => onRepost(post),
              onShare: () => onShare(post),
              onMediaTap: () => onMediaTap(post),
              onReplies: () => onReplies(post),
              onQuoteTap: post.quotedPost == null ? null : () => onReplies(post.quotedPost!),
              onAuthorTap: () => onAuthorTap(post),
              // داخل تبويب المجتمع نستخدم زر خيارات خارجي فوق الكرت،
              // لأن زر الكرت الداخلي أحيانًا يدخل في Gesture arena مع فتح الردود.
              onMore: null,
              disableCardTap: true,
            ),
            PositionedDirectional(
              top: 12,
              end: 8,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _showCommunityPostActions(context, post, canDelete),
                  borderRadius: BorderRadius.circular(99),
                  child: Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? AppColors.darkBg.withValues(alpha: 0.68)
                          : AppColors.lightBg.withValues(alpha: 0.86),
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.purple.withValues(alpha: 0.10)),
                    ),
                    child: Icon(
                      Icons.more_horiz_rounded,
                      size: 23,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? AppColors.darkMuted
                          : AppColors.lightMuted,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CommunityReportsTab extends StatelessWidget {
  final CityCommunity community;
  final bool isMod;
  final bool isDark;
  const _CommunityReportsTab({required this.community, required this.isMod, required this.isDark});
  @override
  Widget build(BuildContext context) {
    if (!isMod) return const Center(child: Text('قسم البلاغات للمشرفين فقط'));
    if (community.reports.isEmpty) return const Center(child: Text('لا توجد بلاغات داخل المجتمع'));
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 110),
      itemCount: community.reports.length,
      itemBuilder: (context, i) {
        final r = community.reports[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.report_rounded, color: AppColors.danger),
                const SizedBox(width: 8),
                Expanded(child: Text(r.reason, style: const TextStyle(fontWeight: FontWeight.w900))),
                _MiniChip(text: r.status == 'accepted' ? 'صحيح' : r.status == 'rejected' ? 'مرفوض' : 'قيد المراجعة', color: r.status == 'accepted' ? AppColors.success : r.status == 'rejected' ? AppColors.danger : AppColors.purple),
              ]),
              const SizedBox(height: 8),
              Text('على: ${r.postUser} ${r.postUsername}', style: const TextStyle(fontWeight: FontWeight.w800)),
              Text('من: ${r.reporterName} ${r.reporterUsername}', style: TextStyle(color: muted, fontSize: 12)),
              if (r.details.trim().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(r.details)),
              if (r.aiReason.trim().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('قرار AI: ${r.aiReason}', style: TextStyle(color: muted, fontSize: 12))),
            ]),
          ),
        );
      },
    );
  }
}

class _CommunityKickedTab extends StatelessWidget {
  final CityCommunity community;
  final bool isMod;
  final bool isDark;
  final Future<void> Function(String username) onUnkick;
  const _CommunityKickedTab({required this.community, required this.isMod, required this.isDark, required this.onUnkick});
  @override
  Widget build(BuildContext context) {
    if (!isMod) return const Center(child: Text('قسم المطرودين للمشرفين فقط'));
    if (community.kickedMembers.isEmpty) return const Center(child: Text('لا يوجد أعضاء مطرودين'));
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 110),
      children: community.kickedMembers.map((u) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: GlassCard(
          child: Row(children: [
            const CircleAvatar(backgroundColor: AppColors.danger, child: Icon(Icons.person_off_rounded, color: Colors.white)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(u, style: const TextStyle(fontWeight: FontWeight.w900)),
              Text('لا يستطيع الرجوع للمجتمع إلا إذا أزلت الطرد', style: TextStyle(color: muted, fontSize: 12)),
            ])),
            TextButton(onPressed: () => onUnkick(u), child: const Text('إلغاء الطرد')),
          ]),
        ),
      )).toList(),
    );
  }
}

class _CommunityMembersTab extends StatelessWidget {
  final CityCommunity community;
  final String currentUsername;
  final bool isOwner;
  final bool isMod;
  final bool isDark;
  final Future<void> Function() onAddModerator;
  final Future<void> Function(String username) onRemoveModerator;
  final Future<void> Function(String username) onRemoveMember;

  const _CommunityMembersTab({
    required this.community,
    required this.currentUsername,
    required this.isOwner,
    required this.isMod,
    required this.isDark,
    required this.onAddModerator,
    required this.onRemoveModerator,
    required this.onRemoveMember,
  });

  @override
  Widget build(BuildContext context) {
    final moderators = community.moderators.toSet().toList();
    final members = community.members.where((u) => !moderators.contains(u)).toSet().toList();
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 110),
      children: [
        if (isMod)
          GlassCard(
            onTap: onAddModerator,
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: const Icon(Icons.add_moderator_rounded, color: AppColors.purple),
                ),
                const SizedBox(width: 12),
                const Expanded(child: Text('إضافة مشرف من الأعضاء', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900))),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Text('المالك والمشرفون', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
        const SizedBox(height: 10),
        ...moderators.map((u) => _CommunityMemberTile(
          username: u,
          subtitle: u == community.ownerUsername ? 'مالك المجتمع' : 'مشرف',
          icon: u == community.ownerUsername ? Icons.workspace_premium_rounded : Icons.verified_user_rounded,
          color: AppColors.purple,
          trailing: isOwner && u != community.ownerUsername
              ? IconButton(onPressed: () => onRemoveModerator(u), icon: const Icon(Icons.remove_moderator_rounded, color: AppColors.danger))
              : null,
        )),
        const SizedBox(height: 14),
        Text('الأعضاء', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
        const SizedBox(height: 10),
        if (members.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text('لا يوجد أعضاء عاديين بعد', style: TextStyle(color: muted)),
          )
        else
          ...members.map((u) => _CommunityMemberTile(
            username: u,
            subtitle: 'عضو',
            icon: Icons.person_rounded,
            color: u == currentUsername ? AppColors.success : muted,
            trailing: isMod && u != currentUsername
                ? IconButton(onPressed: () => onRemoveMember(u), icon: const Icon(Icons.person_remove_rounded, color: AppColors.danger))
                : null,
          )),
      ],
    );
  }
}

class _CommunityMemberTile extends StatelessWidget {
  final String username;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Widget? trailing;

  const _CommunityMemberTile({
    required this.username,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.18),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(username, style: const TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class CityCommunity {
  final String id;
  String name;
  String description;
  final String ownerUsername;
  final List<String> moderators;
  final List<String> members;
  final List<CommunityMessage> messages;
  final List<CityPost> posts;
  final List<String> kickedMembers;
  final List<CommunityReport> reports;

  CityCommunity({
    required this.id,
    required this.name,
    required this.description,
    required this.ownerUsername,
    List<String>? moderators,
    List<String>? members,
    List<CommunityMessage>? messages,
    List<CityPost>? posts,
    List<String>? kickedMembers,
    List<CommunityReport>? reports,
  })  : moderators = moderators ?? [],
        members = members ?? [],
        messages = messages ?? [],
        posts = posts ?? [],
        kickedMembers = kickedMembers ?? [],
        reports = reports ?? [];

  int get mediaCount => posts.where((p) => p.mediaPath != null || p.voicePath != null).length;

  factory CityCommunity.fromJson(Map<String, dynamic> json) => CityCommunity(
    id: (json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString()).toString(),
    name: (json['name'] ?? 'مجتمع').toString(),
    description: (json['description'] ?? '').toString(),
    ownerUsername: (json['ownerUsername'] ?? '@user').toString(),
    moderators: (json['moderators'] is List) ? (json['moderators'] as List).map((e) => e.toString()).toSet().toList() : [],
    members: (json['members'] is List) ? (json['members'] as List).map((e) => e.toString()).toSet().toList() : [],
    kickedMembers: (json['kickedMembers'] is List) ? (json['kickedMembers'] as List).map((e) => SupabaseService.displayUsername(e.toString())).toSet().toList() : [],
    reports: (json['reports'] is List)
        ? (json['reports'] as List).whereType<Map>().map((e) => CommunityReport.fromJson(e.map((k, v) => MapEntry(k.toString(), v)))).toList()
        : [],
    messages: (json['messages'] is List)
        ? (json['messages'] as List)
        .whereType<Map>()
        .map((e) => CommunityMessage.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
        .toList()
        : [],
    posts: (json['posts'] is List)
        ? (json['posts'] as List)
        .whereType<Map>()
        .map((e) => CityPost.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
        .toList()
        : _legacyMessagesToPosts(json),
  );

  static List<CityPost> _legacyMessagesToPosts(Map<String, dynamic> json) {
    if (json['messages'] is! List) return <CityPost>[];
    return (json['messages'] as List).whereType<Map>().map((raw) {
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      return CityPost(
        id: (m['id'] ?? DateTime.now().microsecondsSinceEpoch.toString()).toString(),
        user: (m['user'] ?? 'User').toString(),
        username: (m['username'] ?? '@user').toString(),
        avatarPath: m['avatarPath']?.toString(),
        text: (m['text'] ?? '').toString(),
        time: (m['time'] ?? 'الآن').toString(),
      );
    }).toList();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'ownerUsername': ownerUsername,
    'moderators': moderators.toSet().toList(),
    'members': members.toSet().toList(),
    'kickedMembers': kickedMembers.toSet().toList(),
    'reports': reports.map((r) => r.toJson()).toList(),
    'messages': messages.map((m) => m.toJson()).toList(),
    'posts': posts.map((p) => p.toJson()).toList(),
  };
}

class CommunityReport {
  final String id;
  final String postId;
  final String reporterUsername;
  final String reporterName;
  final String postUsername;
  final String postUser;
  final String reason;
  final String details;
  final String createdAt;
  String status;
  String aiDecision;
  String aiReason;

  CommunityReport({
    required this.id,
    required this.postId,
    required this.reporterUsername,
    required this.reporterName,
    required this.postUsername,
    required this.postUser,
    required this.reason,
    required this.details,
    required this.createdAt,
    this.status = 'pending',
    this.aiDecision = 'pending',
    this.aiReason = '',
  });

  factory CommunityReport.fromJson(Map<String, dynamic> json) => CommunityReport(
    id: (json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString()).toString(),
    postId: (json['postId'] ?? json['post_id'] ?? '').toString(),
    reporterUsername: SupabaseService.displayUsername((json['reporterUsername'] ?? json['reporter_username'] ?? '@user').toString()),
    reporterName: (json['reporterName'] ?? json['reporter_name'] ?? 'User').toString(),
    postUsername: SupabaseService.displayUsername((json['postUsername'] ?? json['post_username'] ?? '@user').toString()),
    postUser: (json['postUser'] ?? json['post_user'] ?? 'User').toString(),
    reason: (json['reason'] ?? json['type'] ?? '').toString(),
    details: (json['details'] ?? '').toString(),
    createdAt: (json['createdAt'] ?? json['created_at'] ?? DateTime.now().toIso8601String()).toString(),
    status: (json['status'] ?? 'pending').toString(),
    aiDecision: (json['aiDecision'] ?? json['ai_decision'] ?? 'pending').toString(),
    aiReason: (json['aiReason'] ?? json['ai_reason'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'postId': postId,
    'reporterUsername': reporterUsername,
    'reporterName': reporterName,
    'postUsername': postUsername,
    'postUser': postUser,
    'reason': reason,
    'details': details,
    'createdAt': createdAt,
    'status': status,
    'aiDecision': aiDecision,
    'aiReason': aiReason,
  };
}

class CommunityMessage {
  final String id;
  final String user;
  final String username;
  final String text;
  final String time;
  final String? avatarPath;

  const CommunityMessage({
    required this.id,
    required this.user,
    required this.username,
    required this.text,
    required this.time,
    this.avatarPath,
  });

  factory CommunityMessage.fromJson(Map<String, dynamic> json) => CommunityMessage(
    id: (json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString()).toString(),
    user: (json['user'] ?? 'User').toString(),
    username: (json['username'] ?? '@user').toString(),
    text: (json['text'] ?? '').toString(),
    time: (json['time'] ?? 'الآن').toString(),
    avatarPath: json['avatarPath']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'user': user,
    'username': username,
    'text': text,
    'time': time,
    'avatarPath': avatarPath,
  };
}

enum CityMediaType { image, video, gif }
enum _AttachmentChoice { image, video, gif, audio }
