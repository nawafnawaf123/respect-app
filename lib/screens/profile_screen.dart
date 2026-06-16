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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/primary_button.dart';
import '../services/supabase_service.dart';
import '../services/notification_service.dart';
import 'search_screen.dart';

import '../app/app_language.dart';
void _scannerSafeIgnore([Object? error, StackTrace? stackTrace]) {}


class ProfileScreen extends StatefulWidget {
  final Future<void> Function()? onProfileUpdated;

  const ProfileScreen({super.key, this.onProfileUpdated});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const String _accountsKey = 'respect_accounts_v1';
  static const String _currentUserKey = 'respect_current_user_id';
  static const String _followingKey = 'respect_following_v1';
  static const String _postsKey = 'respect_city_posts_v1';

  final _nameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _websiteCtrl = TextEditingController();
  final _streamUrlCtrl = TextEditingController();
  final _streamerNameCtrl = TextEditingController();
  final _streamTitleCtrl = TextEditingController();
  final _streamViewersCtrl = TextEditingController(text: '0');

  String? _currentId;
  String? _profileImagePath;
  String? _coverPath;
  String? _pendingProfileImagePath;
  String? _pendingCoverPath;
  String? _streamThumbnailPath;
  bool _streamIsLive = false;
  Timer? _streamRefreshTimer;
  bool _checkingStream = false;
  bool _autoRefreshingStream = false;
  bool _loading = true;
  bool _saving = false;
  bool _editing = false;
  Map<String, List<String>> _following = {};
  int _postsCount = 0;
  bool _loadingProfileContent = false;
  List<Map<String, dynamic>> _profilePosts = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _profileMedia = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _profileReplies = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _followersUsers = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _followingUsers = <Map<String, dynamic>>[];
  bool _profileVerified = false;
  String _profileSubscriptionTier = 'free';
  Map<String, int> _profileAnalytics = const <String, int>{};
  int _activeWarnings = 0;
  DateTime? _verifiedUntil;
  bool _activatingVerification = false;
  List<Map<String, dynamic>> _myStories = <Map<String, dynamic>>[];
  Set<String> _seenStoryIds = <String>{};
  bool _loadingStory = false;
  Set<String> _likedPostIds = <String>{};
  Set<String> _repostedPostIds = <String>{};
  Set<String> _savedPostIds = <String>{};
  final Set<String> _pendingPostActionIds = <String>{};
  int _selectedProfileTab = 0;

  @override
  void initState() {
    super.initState();
    _loadProfile().then((_) {
      if (!mounted) return;
      _loadProfileContent();
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _usernameCtrl.dispose();
    _bioCtrl.dispose();
    _locationCtrl.dispose();
    _websiteCtrl.dispose();
    _streamUrlCtrl.dispose();
    _streamerNameCtrl.dispose();
    _streamTitleCtrl.dispose();
    _streamRefreshTimer?.cancel();
    _streamViewersCtrl.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _loadAccounts(SharedPreferences prefs) async {
    final raw = prefs.getString(_accountsKey);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAccounts(SharedPreferences prefs, List<Map<String, dynamic>> accounts) async {
    await prefs.setString(_accountsKey, jsonEncode(accounts));
  }

  String _safeFileId(String value) {
    final clean = value.trim().toLowerCase().replaceAll('@', '').replaceAll(RegExp(r'[^a-z0-9_\-]+'), '_');
    return clean.isEmpty ? 'user' : clean;
  }

  bool _sameAccount(Map<String, dynamic> account, String id) {
    final cleanId = _safeFileId(id);
    final accountId = _safeFileId((account['id'] ?? '').toString());
    final accountUsername = _safeFileId((account['username'] ?? '').toString());
    return accountId == cleanId || accountUsername == cleanId;
  }

  Future<String> _copyPickedImageForCurrentAccount(String sourcePath, {required bool cover}) async {
    final id = _currentId ?? _usernameCtrl.text.trim();
    final userDirName = _safeFileId(id.isEmpty ? _usernameCtrl.text : id);
    final dir = await getApplicationDocumentsDirectory();
    final profileDir = Directory('${dir.path}/respect_profiles/$userDirName');
    if (!await profileDir.exists()) await profileDir.create(recursive: true);

    final source = File(sourcePath);
    final ext = source.path.split('.').last.toLowerCase();
    final safeExt = RegExp(r'^[a-z0-9]{2,5}\$').hasMatch(ext) ? ext : 'jpg';
    final fileName = cover ? 'cover.$safeExt' : 'avatar.$safeExt';
    final target = File('${profileDir.path}/$fileName');

    if (source.path == target.path) return target.path;
    if (await target.exists()) await target.delete();
    await source.copy(target.path);
    return target.path;
  }


  Future<void> _syncProfileAvatarEverywhere(SharedPreferences prefs, String username, String? imagePath) async {
    final cleanUsername = _cleanUsername(username);

    Future<void> patchListKey(String key) async {
      final raw = prefs.getString(key);
      if (raw == null || raw.trim().isEmpty) return;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) return;
        bool changed = false;
        final updated = decoded.map((item) {
          if (item is! Map) return item;
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final itemUsername = _cleanUsername((map['username'] ?? map['authorUsername'] ?? '').toString());
          if (itemUsername == cleanUsername) {
            map['avatarPath'] = imagePath;
            map['imagePath'] = imagePath;
            map['profileImagePath'] = imagePath;
            map['avatar_url'] = imagePath;
            changed = true;
          }
          final quoted = map['quotedPost'];
          if (quoted is Map) {
            final quotedMap = quoted.map((k, v) => MapEntry(k.toString(), v));
            final quotedUsername = _cleanUsername((quotedMap['username'] ?? '').toString());
            if (quotedUsername == cleanUsername) {
              quotedMap['avatarPath'] = imagePath;
              map['quotedPost'] = quotedMap;
              changed = true;
            }
          }
          return map;
        }).toList();
        if (changed) await prefs.setString(key, jsonEncode(updated));
      } catch (_) { _scannerSafeIgnore(); }
    }

    await patchListKey(_postsKey);
    await patchListKey('respect_local_quote_posts_v1');
  }

  Future<void> _syncProfileAvatarToServer(String username, String? avatarUrl) async {
    final url = avatarUrl?.trim();
    if (url == null || url.isEmpty) return;
    try {
      await SupabaseService.updateUserAvatar(username: username, avatarUrl: url);
    } catch (_) { _scannerSafeIgnore(); }
  }

  int _currentIndex(List<Map<String, dynamic>> accounts, String? id) {
    if (id == null) return -1;
    return accounts.indexWhere((a) => _sameAccount(a, id));
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_currentUserKey) ?? prefs.getString('current_user_id');
    Map<String, dynamic> account = <String, dynamic>{};

    final accounts = await _loadAccounts(prefs);
    final index = _currentIndex(accounts, id);
    if (index >= 0) account = accounts[index];

    if (account.isEmpty) {
      final rawUsers = prefs.getString('respect_users_map');
      if (rawUsers != null && rawUsers.trim().isNotEmpty && id != null) {
        try {
          final decoded = jsonDecode(rawUsers);
          if (decoded is Map && decoded[id] is Map) {
            account = (decoded[id] as Map).map((k, v) => MapEntry(k.toString(), v));
          }
        } catch (_) { _scannerSafeIgnore(); }
      }
    }

    final followingRaw = prefs.getString(_followingKey);
    final loadedFollowing = <String, List<String>>{};
    if (followingRaw != null && followingRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(followingRaw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is List) loadedFollowing[key.toString()] = value.map((e) => e.toString()).toSet().toList();
          });
        }
      } catch (_) { _scannerSafeIgnore(); }
    }

    int loadedPostsCount = 0;
    final postsRaw = prefs.getString(_postsKey);
    final currentUsername = _cleanUsername((account['username'] ?? id ?? '@nawaf_city').toString());
    if (postsRaw != null && postsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(postsRaw);
        if (decoded is List) {
          loadedPostsCount = decoded
              .whereType<Map>()
              .where((p) => (p['username'] ?? '').toString() == currentUsername)
              .length;
        }
      } catch (_) { _scannerSafeIgnore(); }
    }

    if (!mounted) return;
    _currentId = id;
    _nameCtrl.text = (account['profileName'] ?? account['name'] ?? 'Nawaf RP').toString();
    _usernameCtrl.text = (account['username'] ?? id ?? '@nawaf_city').toString();
    _bioCtrl.text = (account['bio'] ?? 'لاعب ومتابع لمجتمع Respect App').toString();
    _locationCtrl.text = (account['location'] ?? 'Respect City').toString();
    _websiteCtrl.text = (account['website'] ?? '').toString();
    setState(() {
      final accountSafeId = _safeFileId(id ?? _usernameCtrl.text);
      // نفضّل رابط السيرفر حتى تظهر الصورة من كل الأجهزة، ونبقي المحلي كاحتياط.
      _profileImagePath = (account['avatar_url'] ??
          account['profileImagePath'] ??
          account['localAvatarPath_$accountSafeId'] ??
          account['imagePath'])
          ?.toString();
      _coverPath = (account['cover_url'] ?? account['coverPath'] ?? account['localCoverPath_$accountSafeId'])?.toString();
      _profileVerified = SupabaseService.isVerifiedUser(account);
      _profileSubscriptionTier = SupabaseService.subscriptionTierForUser(account);
      _verifiedUntil = SupabaseService.verifiedUntilForUser(account);
      _loading = false;
      _following = loadedFollowing;
      _postsCount = loadedPostsCount;
    });
    try {
      final warnings = await SupabaseService.activeWarningCount(_cleanUsername(_usernameCtrl.text));
      if (mounted) setState(() => _activeWarnings = warnings);
    } catch (_) { _scannerSafeIgnore(); }
    try {
      final analytics = await SupabaseService.getPostAnalyticsSummary(_cleanUsername(_usernameCtrl.text));
      if (mounted) setState(() => _profileAnalytics = analytics);
    } catch (_) { _scannerSafeIgnore(); }
    unawaited(_refreshMyStories());
  }

  String _cleanUsername(String value) {
    final v = value.trim().replaceAll(RegExp(r'\s+'), '_').replaceAll('@', '').toLowerCase();
    if (v.isEmpty) return '@nawaf_city';
    return '@$v';
  }

  ImageProvider? _fileImage(String? path) {
    final p = path?.trim();
    if (p == null || p.isEmpty) return null;
    if (p.startsWith('http://') || p.startsWith('https://')) return NetworkImage(p);
    final file = File(p);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  Future<void> _updateAccount(Map<String, dynamic> values) async {
    final prefs = await SharedPreferences.getInstance();
    final id = _currentId ?? prefs.getString(_currentUserKey) ?? prefs.getString('current_user_id');
    if (id == null || id.trim().isEmpty) return;

    final safeId = _safeFileId(id);
    final accountValues = <String, dynamic>{...values};

    if (values.containsKey('imagePath')) {
      // مسار محلي خاص بالحساب الحالي فقط، لا نضعه كـ avatar_url عام.
      accountValues['imagePath'] = values['imagePath'];
      accountValues['localAvatarPath_$safeId'] = values['imagePath'];
    }
    if (values.containsKey('avatar_url')) {
      // رابط السيرفر هو الصورة العامة التي يراها كل المستخدمين.
      accountValues['avatar_url'] = values['avatar_url'];
      accountValues['profileImagePath'] = values['avatar_url'];
    }
    if (values.containsKey('coverPath')) {
      accountValues['coverPath'] = values['coverPath'];
      accountValues['localCoverPath_$safeId'] = values['coverPath'];
    }
    if (values.containsKey('cover_url')) {
      accountValues['cover_url'] = values['cover_url'];
      accountValues['coverPath'] = values['cover_url'];
    }

    final accounts = await _loadAccounts(prefs);
    final index = _currentIndex(accounts, id);
    if (index >= 0) {
      accounts[index] = {...accounts[index], ...accountValues, 'id': id};
    } else {
      accounts.add({...accountValues, 'id': id});
    }
    await _saveAccounts(prefs, accounts);

    final rawUsers = prefs.getString('respect_users_map');
    final decodedUsers = <String, dynamic>{};
    if (rawUsers != null && rawUsers.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawUsers);
        if (decoded is Map) decodedUsers.addAll(decoded.map((k, v) => MapEntry(k.toString(), v)));
      } catch (_) { _scannerSafeIgnore(); }
    }

    final currentUserRaw = decodedUsers[id];
    final user = currentUserRaw is Map
        ? Map<String, dynamic>.from(currentUserRaw.map((k, v) => MapEntry(k.toString(), v)))
        : <String, dynamic>{'id': id};

    final mappedValues = <String, dynamic>{...accountValues};
    if (values.containsKey('profileName')) mappedValues['name'] = values['profileName'];
    if (values.containsKey('streamName')) mappedValues['streamerName'] = values['streamName'];
    if (values.containsKey('streamThumbnailPath')) mappedValues['streamThumbnailPath'] = values['streamThumbnailPath'];
    if (values.containsKey('streamThumbnailUrl')) mappedValues['streamThumbnailUrl'] = values['streamThumbnailUrl'];
    if (values.containsKey('streamPlatform')) mappedValues['streamPlatform'] = values['streamPlatform'];
    if (values.containsKey('streamLastCheckedAt')) mappedValues['streamLastCheckedAt'] = values['streamLastCheckedAt'];
    if (values.containsKey('streamIsLive')) mappedValues['streamIsLive'] = values['streamIsLive'];
    if (values.containsKey('streamViewers')) mappedValues['streamViewers'] = values['streamViewers'];
    if (values.containsKey('streamTitle')) mappedValues['streamTitle'] = values['streamTitle'];

    decodedUsers[id] = {...user, ...mappedValues};
    await prefs.setString('respect_users_map', jsonEncode(decodedUsers));

    if (values.containsKey('avatar_url')) {
      final username = _usernameCtrl.text.trim().isNotEmpty ? _usernameCtrl.text.trim() : id;
      final avatarUrl = values['avatar_url']?.toString();
      await _syncProfileAvatarEverywhere(prefs, username, avatarUrl);
      await _syncProfileAvatarToServer(username, avatarUrl);
      await widget.onProfileUpdated?.call();
    } else if (values.containsKey('cover_url')) {
      await widget.onProfileUpdated?.call();
    } else if (values.containsKey('imagePath')) {
      await widget.onProfileUpdated?.call();
    }
  }

  Future<void> _pickStreamThumbnail() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1280,
      maxHeight: 720,
    );
    if (image == null) return;

    await _updateAccount({'streamThumbnailPath': image.path});
    if (!mounted) return;
    setState(() => _streamThumbnailPath = image.path);
  }

  Future<void> _pickImage({required bool cover}) async {
    if (!_editing) {
      if (!cover && _hasMyActiveStory) {
        await _openMyStory();
      }
      return;
    }

    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: cover ? 1400 : 900,
      maxHeight: cover ? 700 : 900,
    );
    if (image == null) return;

    final savedPath = await _copyPickedImageForCurrentAccount(image.path, cover: cover);

    if (!mounted) return;
    setState(() {
      if (cover) {
        _pendingCoverPath = savedPath;
      } else {
        _pendingProfileImagePath = savedPath;
      }
    });

    NotificationService.showTopNotification(
      cover
          ? 'تم اختيار غلاف جديد. اضغط حفظ لتطبيق التغيير'
          : 'تم اختيار صورة جديدة. اضغط حفظ لتطبيق التغيير',
    );
  }


  Future<void> _refreshSavedStream({bool silent = false}) async {
    if (_autoRefreshingStream || _streamUrlCtrl.text.trim().isEmpty) return;
    _autoRefreshingStream = true;
    if (!silent && mounted) setState(() => _checkingStream = true);

    try {
      final name = _nameCtrl.text.trim().isEmpty ? 'Nawaf RP' : _nameCtrl.text.trim();
      final streamUrl = _cleanStreamUrl(_streamUrlCtrl.text);
      final metadata = await _fetchStreamMetadata(streamUrl, fallbackName: name);
      final cachedThumbnailPath = metadata.thumbnailUrl.trim().isEmpty
          ? ''
          : await _cacheBestStreamThumbnail(metadata.thumbnailUrl,
          platform: metadata.platform, channel: _channelFromUrl(streamUrl));
      final finalThumbnailPath = _safeStreamThumbnailValue(
        cachedPath: cachedThumbnailPath,
        remoteUrl: metadata.thumbnailUrl,
        previousValue: _streamThumbnailPath,
      );

      await _updateAccount({
        'streamUrl': streamUrl,
        'streamName': metadata.channelName.isNotEmpty ? metadata.channelName : _streamerNameCtrl.text.trim(),
        'streamTitle': metadata.title,
        'streamIsLive': metadata.isLive,
        'streamViewers': metadata.viewers,
        'streamThumbnailUrl': metadata.thumbnailUrl,
        'streamThumbnailPath': finalThumbnailPath,
        'streamPlatform': metadata.platform,
        'streamLastCheckedAt': DateTime.now().toIso8601String(),
      });

      if (!mounted) return;
      _streamUrlCtrl.text = streamUrl;
      _streamerNameCtrl.text =
      metadata.channelName.isNotEmpty ? metadata.channelName : _streamerNameCtrl.text.trim();
      _streamTitleCtrl.text = metadata.title;
      _streamViewersCtrl.text = metadata.viewers.toString();
      setState(() {
        _streamIsLive = metadata.isLive;
        _streamThumbnailPath = finalThumbnailPath;
      });
    } finally {
      _autoRefreshingStream = false;
      if (mounted && !silent) setState(() => _checkingStream = false);
    }
  }


  Future<void> _loadProfileContent() async {
    if (_loadingProfileContent) return;
    final username = _cleanUsername(_usernameCtrl.text.trim().isNotEmpty ? _usernameCtrl.text : (_currentId ?? '@user'));
    setState(() => _loadingProfileContent = true);

    List<Map<String, dynamic>> posts = <Map<String, dynamic>>[];
    List<Map<String, dynamic>> replies = <Map<String, dynamic>>[];
    List<Map<String, dynamic>> followers = <Map<String, dynamic>>[];
    List<Map<String, dynamic>> following = <Map<String, dynamic>>[];

    try {
      posts = await SupabaseService.getUserPosts(username);
    } catch (_) { _scannerSafeIgnore(); }

    Set<String> likedIds = <String>{};
    Set<String> repostedIds = <String>{};
    Set<String> savedIds = <String>{};
    try { likedIds = await SupabaseService.getUserLikedPostIds(username); } catch (_) { _scannerSafeIgnore(); }
    try { repostedIds = await SupabaseService.getUserRepostedPostIds(username); } catch (_) { _scannerSafeIgnore(); }
    try { savedIds = await SupabaseService.getUserSavedPostIds(username); } catch (_) { _scannerSafeIgnore(); }

    try {
      final allPosts = await SupabaseService.getPosts();
      for (final p in allPosts) {
        final postId = (p['id'] ?? '').toString();
        final postText = (p['text'] ?? '').toString();
        final postUser = (p['name'] ?? p['user'] ?? '').toString();
        final rawReplies = p['replies'];
        if (rawReplies is List) {
          for (final r in rawReplies.whereType<Map>()) {
            final rm = r.map((k, v) => MapEntry(k.toString(), v));
            final ru = _cleanUsername((rm['username'] ?? rm['author_username'] ?? '').toString());
            if (ru == username) {
              replies.add({
                ...rm,
                'post_id': postId,
                'postText': postText,
                'postUser': postUser,
              });
            }
          }
        }
      }
    } catch (_) { _scannerSafeIgnore(); }

    try {
      followers = await SupabaseService.getUserFollowers(username);
    } catch (_) { _scannerSafeIgnore(); }
    try {
      following = await SupabaseService.getUserFollowing(username);
    } catch (_) { _scannerSafeIgnore(); }

    if (!mounted) return;
    final media = posts.where((p) {
      final image = (p['image_url'] ?? p['imageUrl'] ?? '').toString().trim();
      final video = (p['video_url'] ?? p['videoUrl'] ?? '').toString().trim();
      final mediaPath = (p['mediaPath'] ?? '').toString().trim();
      return image.isNotEmpty || video.isNotEmpty || mediaPath.isNotEmpty;
    }).toList();

    setState(() {
      _profilePosts = posts;
      _profileMedia = media;
      _profileReplies = replies;
      _followersUsers = followers;
      _followingUsers = following;
      _postsCount = posts.length;
      _likedPostIds = likedIds;
      _repostedPostIds = repostedIds;
      _savedPostIds = savedIds;
      _loadingProfileContent = false;
    });
  }

  void _showUsersSheet(String title, List<Map<String, dynamic>> users) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.72,
          minChildSize: 0.35,
          maxChildSize: 0.92,
          builder: (context, controller) {
            return Container(
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBg : AppColors.lightBg,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(width: 46, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .6), borderRadius: BorderRadius.circular(99))),
                  const SizedBox(height: 14),
                  AppText(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: users.isEmpty
                        ? Center(child: AppText('لا توجد حسابات هنا', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)))
                        : ListView.separated(
                      controller: controller,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: users.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final u = users[index];
                        final name = (u['name'] ?? u['profileName'] ?? u['username'] ?? 'User').toString();
                        final username = _cleanUsername((u['username'] ?? '').toString());
                        final avatar = _fileImage((u['avatar_url'] ?? u['imagePath'] ?? u['profileImagePath'])?.toString());
                        return GlassCard(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 24,
                                backgroundColor: AppColors.purple,
                                backgroundImage: avatar,
                                child: avatar == null ? AppText(name.isNotEmpty ? name.characters.first.toUpperCase() : '?', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)) : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    AppText(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                                    const SizedBox(height: 2),
                                    AppText(username, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }


  String _formatVerifiedUntil(DateTime? value) {
    if (value == null) return 'نشط';
    final d = value.toLocal();
    return '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _openVerificationSheet() async {
    if (_activatingVerification) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
        final plans = SupabaseService.verificationPlans;

        List<Map<String, dynamic>> plansForTier(String tierId) {
          return plans
              .where((p) => (p['tier'] ?? '').toString() == tierId)
              .map((p) => Map<String, dynamic>.from(p))
              .toList();
        }

        IconData tierIcon(String id) {
          if (id == 'premium') return Icons.diamond_rounded;
          if (id == 'gold') return Icons.workspace_premium_rounded;
          return Icons.star_rounded;
        }

        List<Color> tierGradient(String id) {
          if (id == 'premium') return const [Color(0xFF5B21B6), Color(0xFFE879F9), Color(0xFF22D3EE)];
          if (id == 'gold') return const [Color(0xFF92400E), Color(0xFFF59E0B), Color(0xFFFDE68A)];
          return const [Color(0xFF475569), Color(0xFFCBD5E1), Color(0xFF94A3B8)];
        }

        String priceText(dynamic value) {
          final price = double.tryParse((value ?? 0).toString()) ?? 0;
          return '\$${price.toStringAsFixed(price.truncateToDouble() == price ? 0 : 2)}';
        }

        Map<String, List<String>> benefitGroups(String tierId, String maxChars, String aiLimit) {
          if (tierId == 'premium') {
            return <String, List<String>>{
              'التوثيق والهوية': <String>[
                'توثيق ألماسي واضح يظهر بجانب اسمك في البروفايل والفيد والبحث',
                'إطار ألماسي للبروفايل والصورة والغلاف',
                'حماية أعلى لاسم المستخدم من التقليد',
              ],
              'الظهور والانتشار': <String>[
                'أقوى أولوية ظهور في الفيد مع الحفاظ على حداثة المنشورات',
                'أولوية أعلى في نتائج البحث وقسم الحسابات المميزة',
                'تواصل رسمي وظهور احترافي في البروفايل',
              ],
              'النشر والمحتوى': <String>[
                '$maxChars حرف للتغريدة الواحدة',
                'تثبيت 3 منشورات في البروفايل',
                'رفع فيديوهات أطول وجودة أعلى حسب إعدادات التطبيق',
                'فتح الستوري والميزات القادمة للموثقين',
              ],
              'الذكاء والخصوصية': <String>[
                '$aiLimit رد Respect AI يوميًا',
                'إحصائيات متقدمة للحساب والمنشورات',
                'استقبال الرسائل من الحسابات الموثقة فقط عند تفعيل الخصوصية',
                'أولوية دعم ومراجعة أسرع للبلاغات والمشاكل',
              ],
            };
          }
          if (tierId == 'gold') {
            return <String, List<String>>{
              'التوثيق والهوية': <String>[
                'توثيق ذهبي واضح بجانب الاسم في البروفايل والفيد والبحث',
                'إطار ذهبي للبروفايل والصورة',
                'زر تواصل رسمي في البروفايل',
              ],
              'الظهور والانتشار': <String>[
                'أولوية ظهور قوية في الفيد',
                'ظهور أفضل في نتائج البحث من الحسابات العادية والفضية',
                'مناسب لصناع المحتوى والحسابات النشطة',
              ],
              'النشر والمحتوى': <String>[
                '$maxChars حرف للتغريدة الواحدة',
                'تثبيت منشورين في البروفايل',
                'فتح الستوري وميزات الموثقين',
              ],
              'الذكاء والخصوصية': <String>[
                '$aiLimit رد Respect AI يوميًا',
                'إحصائيات للمنشورات والتفاعل',
                'استقبال الرسائل من الحسابات الموثقة فقط عند تفعيل الخصوصية',
              ],
            };
          }
          return <String, List<String>>{
            'التوثيق والهوية': <String>[
              'توثيق فضي يظهر بجانب الاسم في البروفايل والفيد والبحث',
              'إطار فضي للبروفايل والصورة',
              'شارة عضو موثق في التعليقات والرسائل',
            ],
            'الظهور والانتشار': <String>[
              'أولوية ظهور خفيفة في الفيد',
              'تمييز بسيط في نتائج البحث',
            ],
            'النشر والمحتوى': <String>[
              '$maxChars حرف للتغريدة الواحدة',
              'تثبيت منشور واحد في البروفايل',
              'فتح الستوري',
            ],
            'الذكاء والمساعدة': <String>[
              '$aiLimit رد Respect AI يوميًا',
              'مناسبة للمستخدمين الجدد والتجربة',
            ],
          };
        }

        String tierSummary(String tierId) {
          if (tierId == 'premium') return 'أقوى حضور وهيبة داخل Respect: توثيق ألماسي، أولوية ظهور، بروفايل مميز، وإحصائيات متقدمة.';
          if (tierId == 'gold') return 'أفضل خيار للحسابات النشطة: توثيق ذهبي، ظهور أعلى، رسائل موثقين فقط، وتثبيت منشورين.';
          return 'بداية قوية للتوثيق: علامة فضية، ستوري، حد كتابة أعلى، وظهور أفضل من الحسابات العادية.';
        }

        return StatefulBuilder(
          builder: (context, setSheet) {
            Widget featureChip(String text, List<Color> gradient) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: gradient.first.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: gradient.first.withValues(alpha: .18)),
                ),
                child: AppText(
                  text,
                  style: TextStyle(
                    color: isDark ? Colors.white.withValues(alpha: .90) : const Color(0xFF2D2338),
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                  ),
                ),
              );
            }

            Widget featureRow(String text, List<Color> gradient) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      margin: const EdgeInsets.only(top: 1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: gradient),
                      ),
                      child: const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppText(
                        text,
                        style: TextStyle(
                          height: 1.35,
                          fontWeight: FontWeight.w800,
                          color: isDark ? Colors.white.withValues(alpha: .92) : const Color(0xFF201726),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            Widget powerPreview(String tierId, List<Color> gradient) {
              final verifiedLabel = tierId == 'premium'
                  ? 'توثيق ألماسي'
                  : tierId == 'gold'
                      ? 'توثيق ذهبي'
                      : 'توثيق فضي';
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [gradient.first.withValues(alpha: .22), gradient.last.withValues(alpha: .08)],
                  ),
                  border: Border.all(color: gradient.first.withValues(alpha: .24)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: gradient),
                        boxShadow: [BoxShadow(color: gradient.first.withValues(alpha: .30), blurRadius: 18)],
                      ),
                      child: Icon(tierIcon(tierId), color: Colors.white),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: AppText(
                                  'اسمك يظهر بشكل مميز',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _RespectAiVerifiedBadge(tier: tierId, large: false),
                            ],
                          ),
                          const SizedBox(height: 3),
                          AppText(verifiedLabel, style: TextStyle(color: muted, fontWeight: FontWeight.w800, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            Widget tierCard(Map<String, dynamic> tier) {
              final tierId = (tier['id'] ?? '').toString();
              final title = (tier['title'] ?? '').toString();
              final badge = (tier['badge'] ?? '').toString();
              final maxChars = (tier['maxPostChars'] ?? '').toString();
              final aiLimit = (tier['aiDailyLimit'] ?? '').toString();
              final groupedBenefits = benefitGroups(tierId, maxChars, aiLimit);
              final tierPlans = plansForTier(tierId);
              final gradient = tierGradient(tierId);

              return Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withValues(alpha: .045) : Colors.white.withValues(alpha: .86),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: gradient.first.withValues(alpha: .38)),
                  boxShadow: [BoxShadow(color: gradient.first.withValues(alpha: .12), blurRadius: 24, offset: const Offset(0, 12))],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(colors: gradient),
                            boxShadow: [BoxShadow(color: gradient.first.withValues(alpha: .30), blurRadius: 18)],
                          ),
                          child: Icon(tierIcon(tierId), color: Colors.white, size: 27),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(child: AppText(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17))),
                                  const SizedBox(width: 7),
                                  _RespectAiVerifiedBadge(tier: tierId, large: false),
                                ],
                              ),
                              const SizedBox(height: 4),
                              AppText('$badge • $maxChars حرف • $aiLimit AI يوميًا', style: TextStyle(color: muted, fontWeight: FontWeight.w800, fontSize: 12.5)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    AppText(
                      tierSummary(tierId),
                      style: TextStyle(color: isDark ? Colors.white.withValues(alpha: .88) : const Color(0xFF2D2338), height: 1.45, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 12),
                    powerPreview(tierId, gradient),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        featureChip('شكل توثيق خاص', gradient),
                        featureChip('ظهور أقوى', gradient),
                        featureChip('بروفايل مميز', gradient),
                        if (tierId != 'silver') featureChip('رسائل موثقين فقط', gradient),
                        if (tierId == 'premium') featureChip('حماية الاسم', gradient),
                      ],
                    ),
                    const SizedBox(height: 14),
                    AppText('المزايا مرتبة حسب الاستخدام:', style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? Colors.white : const Color(0xFF201726))),
                    const SizedBox(height: 10),
                    for (final group in groupedBenefits.entries) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        child: AppText(
                          group.key,
                          style: TextStyle(
                            color: gradient.first,
                            fontWeight: FontWeight.w900,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      ...group.value.map((feature) => featureRow(feature, gradient)),
                    ],
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.black.withValues(alpha: .18) : Colors.white.withValues(alpha: .70),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: gradient.first.withValues(alpha: .16)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.payments_rounded, color: gradient.first),
                              const SizedBox(width: 8),
                              const AppText('اختر مدة الاشتراك', style: TextStyle(fontWeight: FontWeight.w900)),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: tierPlans.map((plan) {
                              final id = (plan['id'] ?? '').toString();
                              final duration = (plan['duration'] ?? '').toString();
                              final durationTitle = duration == 'yearly'
                                  ? 'سنة'
                                  : duration == 'quarterly'
                                      ? '3 أشهر'
                                      : 'شهر';
                              final planBadge = (plan['badge'] ?? '').toString();
                              return Expanded(
                                child: Padding(
                                  padding: const EdgeInsetsDirectional.only(end: 7),
                                  child: FilledButton(
                                    onPressed: _activatingVerification
                                        ? null
                                        : () async {
                                            setSheet(() => _activatingVerification = true);
                                            await _startVerificationCheckout(id);
                                            if (mounted) setSheet(() => _activatingVerification = false);
                                          },
                                    style: FilledButton.styleFrom(
                                      backgroundColor: gradient.first,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        AppText(durationTitle, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
                                        const SizedBox(height: 2),
                                        AppText(priceText(plan['price']), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                                        if (planBadge.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          AppText(planBadge, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 9.5, color: Colors.white.withValues(alpha: .88))),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            return DraggableScrollableSheet(
              initialChildSize: .92,
              minChildSize: .58,
              maxChildSize: .97,
              expand: false,
              builder: (context, scrollController) {
                return Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkBg : AppColors.lightBg,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                    border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                  ),
                  child: SafeArea(
                    top: false,
                    child: ListView(
                      controller: scrollController,
                      physics: const BouncingScrollPhysics(),
                      children: [
                        Center(child: Container(width: 46, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .55), borderRadius: BorderRadius.circular(99)))),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .15), shape: BoxShape.circle),
                              child: const _RespectAiVerifiedBadge(tier: 'premium', large: true),
                            ),
                            const SizedBox(width: 10),
                            const Expanded(child: AppText('اشتراكات Respect', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900))),
                          ],
                        ),
                        const SizedBox(height: 8),
                        AppText(
                          'كل باقة لها شكل توثيق مختلف ومزايا واضحة. اختر الباقة المناسبة لك، ثم اختر مدة الاشتراك: شهر، 3 أشهر، أو سنة.',
                          style: TextStyle(color: muted, height: 1.45, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(13),
                          decoration: BoxDecoration(
                            color: AppColors.purple.withValues(alpha: .10),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: AppColors.purple.withValues(alpha: .18)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.info_rounded, color: AppColors.purple),
                              const SizedBox(width: 9),
                              Expanded(
                                child: AppText(
                                  'بعد الاشتراك تظهر شارة الباقة على حسابك ومنشوراتك، وتتفعل حدود الكتابة وRespect AI والستوري وأولوية الظهور والميزات الخاصة حسب نوع الباقة.',
                                  style: TextStyle(color: isDark ? Colors.white.withValues(alpha: .90) : const Color(0xFF2D2338), height: 1.45, fontWeight: FontWeight.w800),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        ...SupabaseService.subscriptionTiers.map((tier) => tierCard(Map<String, dynamic>.from(tier))),
                        const SizedBox(height: 4),
                        AppText(
                          'ملاحظة: الدفع يتم عبر Paddle. التفعيل يصير تلقائيًا بعد تأكيد الدفع من السيرفر عبر Webhook.',
                          style: TextStyle(color: muted, fontSize: 12, height: 1.35),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
    if (mounted) setState(() => _activatingVerification = false);
  }


  Future<void> _startVerificationCheckout(String planId) async {
    try {
      final username = _cleanUsername(_usernameCtrl.text);
      final checkoutUrl = await SupabaseService.createVerificationCheckout(
        username: username,
        planId: planId,
      );

      if (!mounted) return;

      // iOS: نفتح الدفع خارج التطبيق بدل WebView لتقليل مشاكل WebKit/الدفع داخل التطبيق.
      // ملاحظة مهمة: لو سترفع التطبيق إلى App Store، اشتراكات الميزات الرقمية غالبًا تحتاج StoreKit/IAP.
      if (Platform.isIOS) {
        final opened = await launchUrl(Uri.parse(checkoutUrl), mode: LaunchMode.externalApplication);
        if (!mounted) return;
        NotificationService.showTopNotification(
          opened
              ? 'تم فتح صفحة الدفع في Safari. بعد إكمال الدفع ارجع للتطبيق وسيتم تحديث الاشتراك تلقائيًا.'
              : 'تعذر فتح صفحة الدفع خارج التطبيق.',
        );
        await Future<void>.delayed(const Duration(seconds: 4));
        await _refreshVerificationStatusFromServer();
        Future<void>.delayed(const Duration(seconds: 10), () async {
          await _refreshVerificationStatusFromServer();
        });
        return;
      }

      final paidOrClosed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _PaddleCheckoutWebViewScreen(
            checkoutUrl: checkoutUrl,
            title: 'دفع الاشتراك',
          ),
        ),
      );

      if (!mounted) return;

      if (paidOrClosed == true) {
        NotificationService.showTopNotification(context.tr('تم تأكيد الدفع داخل التطبيق. يتم الآن تحديث حالة الاشتراك...'),
        );
      } else {
        NotificationService.showTopNotification(context.tr('تم إغلاق صفحة الدفع. إذا أكملت الدفع سيتم تفعيل التوثيق تلقائيًا خلال لحظات.'),
        );
      }

      await Future<void>.delayed(const Duration(seconds: 2));
      await _refreshVerificationStatusFromServer();

      Future<void>.delayed(const Duration(seconds: 7), () async {
        await _refreshVerificationStatusFromServer();
      });
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopError(context.tr('تعذر إنشاء صفحة الدفع داخل التطبيق: $e'));
    } finally {
      if (mounted) setState(() => _activatingVerification = false);
    }
  }

  Future<void> _refreshVerificationStatusFromServer() async {
    try {
      final username = _cleanUsername(_usernameCtrl.text);
      final user = await SupabaseService.getUserByUsername(username);
      if (user == null) return;

      final verified = SupabaseService.isVerifiedUser(user);
      final until = SupabaseService.verifiedUntilForUser(user);

      final fresh = <String, dynamic>{
        'is_verified': user['is_verified'] ?? verified,
        'verified': user['verified'] ?? verified,
        'respect_verified': user['respect_verified'] ?? verified,
        'verification_status': user['verification_status'] ?? (verified ? 'active' : null),
        'subscription_tier': user['subscription_tier'] ?? (verified ? 'verified' : null),
        'verified_until': user['verified_until'],
        'verification_expires_at': user['verification_expires_at'],
        'subscription_expires_at': user['subscription_expires_at'],
        'verification_plan': user['verification_plan'],
      }..removeWhere((key, value) => value == null);

      await _updateAccount(fresh);
      if (!mounted) return;
      setState(() {
        _profileVerified = verified;
        _verifiedUntil = until;
      });

      if (verified) {
        await widget.onProfileUpdated?.call();
        NotificationService.showTopSuccess(context.tr('تم تفعيل التوثيق حتى ${_formatVerifiedUntil(_verifiedUntil)}'));
      }
    } catch (_) {
      _scannerSafeIgnore();
    }
  }

  Future<void> _activateVerificationPlan(String planId) async {
    try {
      final username = _cleanUsername(_usernameCtrl.text);
      final result = await SupabaseService.activateVerificationPlan(username: username, planId: planId);
      final fresh = <String, dynamic>{
        'is_verified': true,
        'verified': true,
        'respect_verified': true,
        'verification_status': 'active',
        'subscription_tier': 'verified',
        'verified_until': result['verified_until'],
        'verification_expires_at': result['verification_expires_at'],
        'subscription_expires_at': result['subscription_expires_at'],
        'verification_plan': planId,
      };
      await _updateAccount(fresh);
      if (!mounted) return;
      setState(() {
        _profileVerified = true;
        _verifiedUntil = SupabaseService.verifiedUntilForUser(result);
        _activatingVerification = false;
      });
      await widget.onProfileUpdated?.call();
      NotificationService.showTopNotification(context.tr('تم توثيق الحساب بنجاح حتى ${_formatVerifiedUntil(_verifiedUntil)}'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _activatingVerification = false);
      NotificationService.showTopError(context.tr('تعذر تفعيل التوثيق: $e'));
    }
  }

  Future<void> _refreshMyStories() async {
    final username = _cleanUsername(_usernameCtrl.text);
    try {
      final results = await Future.wait([
        SupabaseService.getActiveStoriesForUser(username),
        SupabaseService.getSeenStoryIds(),
      ]);
      final rows = List<Map<String, dynamic>>.from(results[0] as List);
      final seen = Set<String>.from(results[1] as Set);
      if (!mounted) return;
      setState(() {
        _myStories = rows;
        _seenStoryIds = seen;
      });
    } catch (_) { _scannerSafeIgnore(); }
  }

  bool get _hasMyActiveStory => _myStories.isNotEmpty;

  bool get _myStoriesFullySeen {
    final ids = _myStories
        .map((e) => (e['id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return false;
    return ids.every(_seenStoryIds.contains);
  }


  bool get _hasPrivateStory => _myStories.any((s) =>
      SupabaseService.truthy(s['is_private']) || (s['privacy'] ?? '').toString().toLowerCase() == 'private');

  Future<List<String>?> _choosePrivateStoryViewers() async {
    final current = _cleanUsername(_usernameCtrl.text);
    List<Map<String, dynamic>> following = <Map<String, dynamic>>[];
    try {
      following = await SupabaseService.getUserFollowing(current);
    } catch (_) { _scannerSafeIgnore(); }
    if (!mounted) return null;
    final selected = <String>{};
    return showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: .72,
              minChildSize: .45,
              maxChildSize: .92,
              builder: (_, controller) => Container(
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkCard : AppColors.lightCard,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  border: Border.all(color: AppColors.purple.withValues(alpha: .20)),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(width: 42, height: 5, decoration: BoxDecoration(color: Colors.grey.withValues(alpha: .45), borderRadius: BorderRadius.circular(99))),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                      child: Row(
                        children: [
                          const Icon(Icons.lock_rounded, color: Color(0xFF00C853)),
                          const SizedBox(width: 8),
                          const Expanded(child: AppText('ستوري خاص', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18))),
                          TextButton(onPressed: () => Navigator.pop(context, <String>[]), child: const AppText('عام')),
                          FilledButton(
                            onPressed: selected.isEmpty ? null : () => Navigator.pop(context, selected.toList()),
                            child: AppText('نشر خاص (${selected.length})'),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: AppText(
                        'اختر الأشخاص من الذين تتابعهم. سيظهر إطار الستوري عندهم باللون الأخضر ولن يستطيع غيرهم فتح الملف المشفر.',
                        style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, height: 1.45),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: following.isEmpty
                          ? const Center(child: AppText('لا يوجد أشخاص تتابعهم لاختيارهم'))
                          : ListView.builder(
                              controller: controller,
                              itemCount: following.length,
                              itemBuilder: (_, i) {
                                final user = following[i];
                                final username = SupabaseService.displayUsername((user['username'] ?? '').toString());
                                final name = (user['name'] ?? user['profileName'] ?? username).toString();
                                final avatar = (user['avatar_url'] ?? user['imagePath'] ?? user['profileImagePath'] ?? '').toString();
                                final checked = selected.contains(username);
                                return CheckboxListTile(
                                  value: checked,
                                  activeColor: const Color(0xFF00C853),
                                  onChanged: (_) => setSheetState(() {
                                    checked ? selected.remove(username) : selected.add(username);
                                  }),
                                  secondary: CircleAvatar(backgroundImage: _fileImage(avatar), child: _fileImage(avatar) == null ? const Icon(Icons.person) : null),
                                  title: AppText(name, style: const TextStyle(fontWeight: FontWeight.w900)),
                                  subtitle: AppText(username),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _handleProfileAvatarTap() async {
    if (_editing) {
      await _pickImage(cover: false);
      return;
    }
    if (_hasMyActiveStory) {
      await _openMyStory();
    }
  }

  Future<String?> _chooseStoryMediaType({required bool allowFinish}) async {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final bg = isDark ? AppColors.darkBg : AppColors.lightBg;
        final border = isDark ? AppColors.darkBorder : AppColors.lightBorder;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            border: Border.all(color: border),
            boxShadow: [BoxShadow(color: AppColors.purple.withValues(alpha: .20), blurRadius: 30, offset: const Offset(0, -12))],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 48, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .75), borderRadius: BorderRadius.circular(99))),
                const SizedBox(height: 16),
                const Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: AppColors.purple,
                      child: Icon(Icons.auto_stories_rounded, color: Colors.white),
                    ),
                    SizedBox(width: 12),
                    Expanded(child: AppText('أضف عناصر للستوري', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900))),
                  ],
                ),
                const SizedBox(height: 12),
                _StoryPickerTile(
                  icon: Icons.collections_rounded,
                  title: 'صور متعددة',
                  subtitle: 'اختر أكثر من صورة دفعة واحدة',
                  onTap: () => Navigator.pop(context, 'images'),
                ),
                _StoryPickerTile(
                  icon: Icons.image_rounded,
                  title: 'صورة واحدة',
                  subtitle: 'إضافة صورة منفردة للستوري',
                  onTap: () => Navigator.pop(context, 'image'),
                ),
                _StoryPickerTile(
                  icon: Icons.videocam_rounded,
                  title: 'فيديو',
                  subtitle: 'أضف فيديو للستوري، وبعدها تقدر تضيف فيديو آخر',
                  onTap: () => Navigator.pop(context, 'video'),
                ),
                if (allowFinish) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context, 'finish'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.purple,
                        side: BorderSide(color: AppColors.purple.withValues(alpha: .45)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      icon: const Icon(Icons.check_circle_rounded),
                      label: const AppText('نشر العناصر المختارة', style: TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickStory() async {
    if (_loadingStory) return;
    if (!_profileVerified) {
      NotificationService.showTopNotification(context.tr('الستوري متاحة للحسابات الموثقة فقط'));
      await _openVerificationSheet();
      return;
    }

    final picker = ImagePicker();
    final items = <Map<String, String>>[];

    while (mounted) {
      final choice = await _chooseStoryMediaType(allowFinish: items.isNotEmpty);
      if (choice == null || choice == 'finish') break;

      if (choice == 'images') {
        final images = await picker.pickMultiImage(imageQuality: 88, maxWidth: 1600, maxHeight: 1600);
        for (final image in images) {
          items.add({'path': image.path, 'type': 'image'});
        }
      } else if (choice == 'image') {
        final image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 88, maxWidth: 1600, maxHeight: 1600);
        if (image != null) items.add({'path': image.path, 'type': 'image'});
      } else if (choice == 'video') {
        final video = await picker.pickVideo(source: ImageSource.gallery);
        if (video != null) items.add({'path': video.path, 'type': 'video'});
      }

      if (items.isEmpty) continue;

      final keepAdding = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const AppText('إضافة عنصر آخر؟', style: TextStyle(fontWeight: FontWeight.w900)),
          content: AppText('تم اختيار ${items.length} عنصر. تقدر تضيف صور أو فيديوهات زيادة قبل النشر.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const AppText('نشر الآن')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const AppText('إضافة المزيد')),
          ],
        ),
      );

      if (keepAdding != true) break;
    }

    if (items.isEmpty) return;

    final privacy = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkCard : AppColors.lightCard,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 42, height: 5, decoration: BoxDecoration(color: Colors.grey.withValues(alpha: .45), borderRadius: BorderRadius.circular(99))),
            const SizedBox(height: 18),
            const AppText('نوع الستوري', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 19)),
            const SizedBox(height: 14),
            ListTile(
              leading: const Icon(Icons.public_rounded, color: AppColors.purple),
              title: const AppText('ستوري عادي مشفر', style: TextStyle(fontWeight: FontWeight.w900)),
              subtitle: const AppText('يظهر بشكل عادي لكن ملف الصورة/الفيديو يكون مشفرًا'),
              onTap: () => Navigator.pop(context, 'normal'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_rounded, color: Color(0xFF00C853)),
              title: const AppText('ستوري خاص', style: TextStyle(fontWeight: FontWeight.w900)),
              subtitle: const AppText('تختار أشخاص محددين ويظهر لهم بإطار أخضر'),
              onTap: () => Navigator.pop(context, 'private'),
            ),
          ],
        ),
      ),
    );
    if (privacy == null) return;
    var privateStory = privacy == 'private';
    var allowedViewers = <String>[];
    if (privateStory) {
      final selected = await _choosePrivateStoryViewers();
      if (selected == null) return;
      if (selected.isEmpty) {
        privateStory = false;
      } else {
        allowedViewers = selected;
      }
    }

    setState(() => _loadingStory = true);
    try {
      await SupabaseService.addStoryMediaItems(
        username: _cleanUsername(_usernameCtrl.text),
        name: _nameCtrl.text.trim().isEmpty ? _cleanUsername(_usernameCtrl.text) : _nameCtrl.text.trim(),
        mediaItems: items,
        avatarUrl: _profileImagePath ?? '',
        privateStory: privateStory,
        allowedViewers: allowedViewers,
      );
      await _refreshMyStories();
      if (!mounted) return;
      NotificationService.showTopNotification(privateStory
          ? 'تم نشر ستوري خاص مشفر لـ ${allowedViewers.length} شخص'
          : 'تم نشر ${items.length} عنصر مشفر في الستوري لمدة 24 ساعة');
    } catch (e) {
      if (mounted) NotificationService.showTopError(context.tr('تعذر نشر الستوري: $e'));
    } finally {
      if (mounted) setState(() => _loadingStory = false);
    }
  }

  Future<void> _openMyStory() async {
    await _refreshMyStories();
    if (!mounted) return;
    if (_myStories.isEmpty) {
      await _pickStory();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ProfileStoryViewer(stories: _myStories, ownerUsername: _cleanUsername(_usernameCtrl.text), ownerMode: true)));
    await SupabaseService.markStoriesSeen(_myStories);
    await _refreshMyStories();
  }

  int _safeInt(dynamic value) => int.tryParse((value ?? '0').toString()) ?? 0;

  String _postId(Map<String, dynamic> post) => (post['id'] ?? '').toString();

  String _postText(Map<String, dynamic> post) => (post['text'] ?? '').toString();

  void _patchPostCounters(String postId, Map<String, dynamic> result) {
    if (postId.trim().isEmpty) return;
    int indexIn(List<Map<String, dynamic>> list) => list.indexWhere((p) => _postId(p) == postId);
    void patch(List<Map<String, dynamic>> list) {
      final i = indexIn(list);
      if (i < 0) return;
      final next = Map<String, dynamic>.from(list[i]);
      for (final key in const ['likes', 'reposts', 'shares', 'views', 'reply_count', 'comments']) {
        if (result.containsKey(key)) next[key] = result[key];
      }
      list[i] = next;
    }
    patch(_profilePosts);
    patch(_profileMedia);
  }

  Future<void> _toggleLikePost(Map<String, dynamic> post) async {
    final id = _postId(post);
    if (id.isEmpty || _pendingPostActionIds.contains('like_$id')) return;
    final username = _cleanUsername(_usernameCtrl.text);
    final nextLiked = !_likedPostIds.contains(id);
    setState(() {
      _pendingPostActionIds.add('like_$id');
      if (nextLiked) {
        _likedPostIds.add(id);
        post['likes'] = _safeInt(post['likes']) + 1;
      } else {
        _likedPostIds.remove(id);
        post['likes'] = (_safeInt(post['likes']) - 1).clamp(0, 1 << 31);
      }
    });
    try {
      final res = await SupabaseService.setPostLike(postId: id, username: username, liked: nextLiked);
      if (!mounted) return;
      setState(() => _patchPostCounters(id, res));
    } catch (e) {
      if (mounted) NotificationService.showTopError(context.tr('تعذر تحديث الإعجاب: $e'));
    } finally {
      if (mounted) setState(() => _pendingPostActionIds.remove('like_$id'));
    }
  }

  Future<void> _toggleRepostPost(Map<String, dynamic> post) async {
    final id = _postId(post);
    if (id.isEmpty || _pendingPostActionIds.contains('repost_$id')) return;
    final username = _cleanUsername(_usernameCtrl.text);
    final nextReposted = !_repostedPostIds.contains(id);
    setState(() {
      _pendingPostActionIds.add('repost_$id');
      if (nextReposted) {
        _repostedPostIds.add(id);
        post['reposts'] = _safeInt(post['reposts']) + 1;
      } else {
        _repostedPostIds.remove(id);
        post['reposts'] = (_safeInt(post['reposts']) - 1).clamp(0, 1 << 31);
      }
    });
    try {
      final res = await SupabaseService.setPostRepost(postId: id, username: username, reposted: nextReposted);
      if (!mounted) return;
      setState(() => _patchPostCounters(id, res));
    } catch (e) {
      if (mounted) NotificationService.showTopError(context.tr('تعذر تحديث إعادة النشر: $e'));
    } finally {
      if (mounted) setState(() => _pendingPostActionIds.remove('repost_$id'));
    }
  }

  Future<void> _toggleSavePost(Map<String, dynamic> post) async {
    final id = _postId(post);
    if (id.isEmpty || _pendingPostActionIds.contains('save_$id')) return;
    final username = _cleanUsername(_usernameCtrl.text);
    setState(() => _pendingPostActionIds.add('save_$id'));
    try {
      final res = await SupabaseService.togglePostSave(postId: id, username: username);
      final saved = res['isSaved'] == true || res['isSaved']?.toString() == 'true';
      if (!mounted) return;
      setState(() {
        if (saved) {
          _savedPostIds.add(id);
        } else {
          _savedPostIds.remove(id);
        }
        _patchPostCounters(id, res);
      });
      NotificationService.showTopNotification(saved ? 'تم حفظ التغريدة' : 'تمت إزالة التغريدة من الحفظ');
    } catch (e) {
      if (mounted) NotificationService.showTopError(context.tr('تعذر تحديث الحفظ: $e'));
    } finally {
      if (mounted) setState(() => _pendingPostActionIds.remove('save_$id'));
    }
  }

  Future<void> _copyPostText(Map<String, dynamic> post) async {
    final text = _postText(post).trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) NotificationService.showTopNotification(context.tr('تم نسخ نص التغريدة'));
  }

  Future<void> _editPost(Map<String, dynamic> post) async {
    final id = _postId(post);
    if (id.isEmpty) return;
    final ctrl = TextEditingController(text: _postText(post));
    final newText = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkBg : AppColors.lightBg,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: Container(width: 46, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .55), borderRadius: BorderRadius.circular(99)))),
                  const SizedBox(height: 16),
                  const AppText('تعديل التغريدة', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    minLines: 4,
                    maxLines: 8,
                    maxLength: _profileVerified ? SupabaseService.verifiedPostMaxChars : SupabaseService.freePostMaxChars,
                    decoration: InputDecoration(
                      hintText: context.tr('اكتب التعديل هنا...'),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                      icon: const Icon(Icons.save_rounded),
                      label: const AppText('حفظ التعديل', style: TextStyle(fontWeight: FontWeight.w900)),
                      style: FilledButton.styleFrom(backgroundColor: AppColors.purple, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999))),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    ctrl.dispose();
    if (newText == null || newText.trim().isEmpty || newText.trim() == _postText(post).trim()) return;
    try {
      await SupabaseService.enforcePostCharacterLimit(username: _cleanUsername(_usernameCtrl.text), text: newText);
      await SupabaseService.updatePostText(postId: id, text: newText);
      if (!mounted) return;
      setState(() {
        for (final list in [_profilePosts, _profileMedia]) {
          final i = list.indexWhere((p) => _postId(p) == id);
          if (i >= 0) list[i] = {...list[i], 'text': newText, 'edited': true, 'edited_at': DateTime.now().toIso8601String()};
        }
      });
      NotificationService.showTopNotification(context.tr('تم تعديل التغريدة'));
    } catch (e) {
      if (mounted) NotificationService.showTopError(context.tr('تعذر تعديل التغريدة: $e'));
    }
  }

  Future<void> _deletePostFromProfile(Map<String, dynamic> post) async {
    final id = _postId(post);
    if (id.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('حذف التغريدة؟'),
        content: const AppText('سيتم حذف التغريدة وتفاعلاتها وردودها. لا يمكن التراجع عن هذا الإجراء.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const AppText('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), style: FilledButton.styleFrom(backgroundColor: Colors.red), child: const AppText('حذف')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await SupabaseService.deletePost(id);
      if (!mounted) return;
      setState(() {
        _profilePosts.removeWhere((p) => _postId(p) == id);
        _profileMedia.removeWhere((p) => _postId(p) == id);
        _postsCount = _profilePosts.length;
      });
      NotificationService.showTopNotification(context.tr('تم حذف التغريدة'));
    } catch (e) {
      if (mounted) NotificationService.showTopError(context.tr('تعذر حذف التغريدة: $e'));
    }
  }

  void _openPostOptions(Map<String, dynamic> post) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
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
                Container(width: 46, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .55), borderRadius: BorderRadius.circular(99))),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.edit_rounded, color: AppColors.purple),
                  title: const AppText('تعديل التغريدة', style: TextStyle(fontWeight: FontWeight.w900)),
                  onTap: () { Navigator.pop(context); _editPost(post); },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded, color: AppColors.purple),
                  title: const AppText('نسخ النص', style: TextStyle(fontWeight: FontWeight.w900)),
                  onTap: () { Navigator.pop(context); _copyPostText(post); },
                ),
                ListTile(
                  leading: Icon(_savedPostIds.contains(_postId(post)) ? Icons.bookmark_remove_rounded : Icons.bookmark_add_rounded, color: AppColors.purple),
                  title: AppText(_savedPostIds.contains(_postId(post)) ? 'إزالة من الحفظ' : 'حفظ التغريدة', style: const TextStyle(fontWeight: FontWeight.w900)),
                  onTap: () { Navigator.pop(context); _toggleSavePost(post); },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_rounded, color: Colors.red),
                  title: const AppText('حذف التغريدة', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.red)),
                  onTap: () { Navigator.pop(context); _deletePostFromProfile(post); },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _refreshProfileTimeline() async {
    await _loadProfileContent();
    if (mounted) NotificationService.showTopNotification(context.tr('تم تحديث الملف الشخصي'));
  }

  Future<void> _saveProfile() async {
    if (_saving) return;
    setState(() => _saving = true);

    final name = _nameCtrl.text.trim().isEmpty ? 'Nawaf RP' : _nameCtrl.text.trim();
    final username = _cleanUsername(_usernameCtrl.text);

    final profileUpdates = <String, dynamic>{};
    final pendingAvatar = _pendingProfileImagePath;
    final pendingCover = _pendingCoverPath;

    if (pendingAvatar != null && pendingAvatar.trim().isNotEmpty) {
      profileUpdates['imagePath'] = pendingAvatar;
      try {
        final avatarUrl = await SupabaseService.uploadProfileAvatar(
          username: username,
          filePath: pendingAvatar,
        );
        profileUpdates['avatar_url'] = avatarUrl;
      } catch (_) { _scannerSafeIgnore(); }
    }

    if (pendingCover != null && pendingCover.trim().isNotEmpty) {
      profileUpdates['coverPath'] = pendingCover;
      try {
        final coverUrl = await SupabaseService.uploadProfileCover(
          username: username,
          filePath: pendingCover,
        );
        profileUpdates['cover_url'] = coverUrl;
      } catch (_) { _scannerSafeIgnore(); }
    }

    await _updateAccount({
      'profileName': name,
      'username': username,
      'bio': _bioCtrl.text.trim(),
      'location': _locationCtrl.text.trim(),
      'website': _websiteCtrl.text.trim(),
      ...profileUpdates,
    });
    try {
      await SupabaseService.updateUserProfile(
        username: username,
        name: name,
        bio: _bioCtrl.text.trim(),
        location: _locationCtrl.text.trim(),
        website: _websiteCtrl.text.trim(),
      );
    } catch (_) { _scannerSafeIgnore(); }

    if (!mounted) return;
    _usernameCtrl.text = username;
    setState(() {
      if (profileUpdates['avatar_url'] != null) {
        _profileImagePath = profileUpdates['avatar_url']?.toString();
      } else if (profileUpdates['imagePath'] != null) {
        _profileImagePath = profileUpdates['imagePath']?.toString();
      }
      if (profileUpdates['cover_url'] != null) {
        _coverPath = profileUpdates['cover_url']?.toString();
      } else if (profileUpdates['coverPath'] != null) {
        _coverPath = profileUpdates['coverPath']?.toString();
      }
      _pendingProfileImagePath = null;
      _pendingCoverPath = null;
      _saving = false;
      _editing = false;
    });
    await _loadProfileContent();
    NotificationService.showTopNotification(context.tr('تم حفظ بيانات البروفايل'));
  }

  int _followersCount(String username) {
    return _following.values.where((list) => list.contains(username)).length;
  }

  int _followingCount(String username) {
    return (_following[username] ?? const <String>[]).length;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final profileImage = _fileImage(_pendingProfileImagePath ?? _profileImagePath);
    final coverImage = _fileImage(_pendingCoverPath ?? _coverPath);
    final tierFrameColors = _profileSubscriptionTier == 'premium'
        ? const [Color(0xFF5B21B6), Color(0xFFE879F9), Color(0xFF22D3EE)]
        : _profileSubscriptionTier == 'gold'
            ? const [Color(0xFF92400E), Color(0xFFF59E0B), Color(0xFFFDE68A)]
            : _profileSubscriptionTier == 'silver'
                ? const [Color(0xFF475569), Color(0xFFCBD5E1), Color(0xFF94A3B8)]
                : const <Color>[];

    final bg = isDark ? const Color(0xFF080810) : Colors.white;
    final cardBg = isDark ? const Color(0xFF0D0D14) : Colors.white;
    final border = isDark ? Colors.white.withValues(alpha: .10) : const Color(0xFFE6ECF0);
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    final displayName = _nameCtrl.text.trim().isEmpty ? 'Nawaf RP' : _nameCtrl.text.trim();
    final username = _cleanUsername(_usernameCtrl.text);

    Widget inlineStat({required String value, required String label, VoidCallback? onTap}) {
      final child = Text.rich(
        TextSpan(
          children: [
            TextSpan(text: value, style: TextStyle(color: isDark ? Colors.white : Colors.black, fontWeight: FontWeight.w900)),
            TextSpan(text: ' $label', style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
          ],
        ),
      );
      if (onTap == null) return child;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4), child: child),
      );
    }

    Widget actionPill({required IconData icon, required String text, required VoidCallback? onTap, bool filled = false}) {
      return OutlinedButton.icon(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: filled ? AppColors.purple : AppColors.purple.withValues(alpha: isDark ? .10 : .07),
          foregroundColor: filled ? Colors.white : AppColors.purple,
          side: BorderSide(color: filled ? AppColors.purple : AppColors.purple.withValues(alpha: .24)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          visualDensity: VisualDensity.compact,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        ),
        icon: Icon(icon, size: 17),
        label: AppText(text, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12.5)),
      );
    }

    return Scaffold(
      appBar: null,
      backgroundColor: bg,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.purple))
          : RefreshIndicator(
              color: AppColors.purple,
              onRefresh: _refreshProfileTimeline,
              child: ListView(
                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                padding: EdgeInsets.zero,
                children: [
                  Container(
                    color: cardBg,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 224,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                            InkWell(
                              onTap: _editing ? () => _pickImage(cover: true) : null,
                              child: Container(
                                height: 168,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topRight,
                                    end: Alignment.bottomLeft,
                                    colors: [Color(0xFF14051F), AppColors.purple, Color(0xFF040308)],
                                  ),
                                  image: coverImage == null ? null : DecorationImage(image: coverImage, fit: BoxFit.cover),
                                ),
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [Colors.transparent, Colors.black.withValues(alpha: .35)],
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (_editing)
                                      PositionedDirectional(
                                        top: 12,
                                        end: 12,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: .48),
                                            border: Border.all(color: Colors.white.withValues(alpha: .16)),
                                            borderRadius: BorderRadius.circular(999),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.image_rounded, color: Colors.white, size: 16),
                                              SizedBox(width: 5),
                                              AppText('تغيير الغلاف', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            PositionedDirectional(
                              start: 14,
                              bottom: 8,
                              child: InkWell(
                                onTap: _handleProfileAvatarTap,
                                borderRadius: BorderRadius.circular(999),
                                child: Stack(
                                  children: [
                                    Container(
                                      padding: EdgeInsets.all(_myStories.isNotEmpty || tierFrameColors.isNotEmpty ? 3.5 : 0),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: _myStories.isEmpty
                                            ? (tierFrameColors.isEmpty ? null : LinearGradient(colors: tierFrameColors))
                                            : (_myStoriesFullySeen
                                                ? const LinearGradient(colors: [Color(0xFF7A7A7A), Color(0xFF4B5563)])
                                                : (_hasPrivateStory
                                                    ? const LinearGradient(colors: [Color(0xFF00C853), Color(0xFF00E676), Color(0xFF1B5E20)])
                                                    : const LinearGradient(colors: [Color(0xFFFFD166), AppColors.purple, Color(0xFF06D6A0)]))),
                                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .20), blurRadius: 18, offset: const Offset(0, 8))],
                                      ),
                                      child: CircleAvatar(
                                        radius: 54,
                                        backgroundColor: cardBg,
                                        child: CircleAvatar(
                                          radius: 49,
                                          backgroundColor: AppColors.purple,
                                          backgroundImage: profileImage,
                                          child: profileImage == null ? const Icon(Icons.person, color: Colors.white, size: 44) : null,
                                        ),
                                      ),
                                    ),
                                    PositionedDirectional(
                                      end: 2,
                                      bottom: 2,
                                      child: Container(
                                        padding: const EdgeInsets.all(7),
                                        decoration: BoxDecoration(
                                          color: _editing
                                              ? AppColors.purple
                                              : (_myStories.isEmpty ? AppColors.purple.withValues(alpha: .92) : (_myStoriesFullySeen ? Colors.grey.shade700 : AppColors.purple)),
                                          shape: BoxShape.circle,
                                          border: Border.all(color: cardBg, width: 2),
                                        ),
                                        child: Icon(
                                          _editing ? Icons.camera_alt_rounded : (_myStories.isEmpty ? Icons.add_rounded : Icons.play_arrow_rounded),
                                          color: Colors.white,
                                          size: 17,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            PositionedDirectional(
                              end: 14,
                              bottom: 16,
                              child: OutlinedButton.icon(
                                onPressed: _saving
                                    ? null
                                    : () async {
                                        if (_editing) {
                                          await _saveProfile();
                                        } else {
                                          setState(() => _editing = true);
                                        }
                                      },
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: _editing ? AppColors.purple : cardBg,
                                  foregroundColor: _editing ? Colors.white : (isDark ? Colors.white : Colors.black),
                                  side: BorderSide(color: _editing ? AppColors.purple : border, width: 1.2),
                                  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                                ),
                                icon: Icon(_editing ? Icons.save_rounded : Icons.edit_rounded, size: 17),
                                label: AppText(_editing ? (_saving ? 'جاري الحفظ...' : 'حفظ التعديل') : 'تعديل الملف الشخصي', style: const TextStyle(fontWeight: FontWeight.w900)),
                              ),
                            ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(14, 0, 14, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: AppText(
                                            displayName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -.4),
                                          ),
                                        ),
                                        if (_isRespectAiUsername(_usernameCtrl.text) || _profileVerified)
                                          _RespectAiVerifiedBadge(
                                            tier: _isRespectAiUsername(_usernameCtrl.text) ? 'premium' : _profileSubscriptionTier,
                                            large: true,
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  AppText(username, style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
                                  if (_profileSubscriptionTier != 'free') ...[
                                    const SizedBox(width: 8),
                                    _SubscriptionTierMiniBadge(tier: _profileSubscriptionTier),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 10),
                              AppText(
                                _bioCtrl.text.trim().isEmpty ? 'أضف نبذة شخصية ليظهر حسابك بشكل أجمل' : _bioCtrl.text.trim(),
                                style: const TextStyle(height: 1.42, fontSize: 14.5, fontWeight: FontWeight.w600),
                              ),
                              if (_activeWarnings > 0) ...[
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.all(11),
                                  decoration: BoxDecoration(
                                    color: AppColors.danger.withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: AppColors.danger.withValues(alpha: 0.28)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.warning_amber_rounded, color: AppColors.danger),
                                      const SizedBox(width: 9),
                                      Expanded(child: AppText('لديك $_activeWarnings تحذير من أصل 3. التحذير يختفي تلقائيًا بعد شهر بدون مخالفات.', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12.5))),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 11),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (_locationCtrl.text.trim().isNotEmpty) _InfoChip(icon: Icons.location_on_outlined, text: _locationCtrl.text.trim()),
                                  if (_websiteCtrl.text.trim().isNotEmpty) _InfoChip(icon: Icons.link_rounded, text: _websiteCtrl.text.trim()),
                                  _InfoChip(icon: Icons.calendar_month_rounded, text: 'انضممت إلى Respect'),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 15,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  inlineStat(value: '$_postsCount', label: 'منشور'),
                                  inlineStat(value: '${_followingUsers.length}', label: 'يتابع', onTap: () => _showUsersSheet('يتابع', _followingUsers)),
                                  inlineStat(value: '${_followersUsers.length}', label: 'متابع', onTap: () => _showUsersSheet('المتابعون', _followersUsers)),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  actionPill(
                                    icon: _profileVerified ? Icons.verified_rounded : Icons.workspace_premium_rounded,
                                    text: _activatingVerification
                                        ? 'جاري التفعيل...'
                                        : (_profileVerified ? 'موثق حتى ${_formatVerifiedUntil(_verifiedUntil)}' : 'توثيق الحساب'),
                                    onTap: _activatingVerification ? null : _openVerificationSheet,
                                    filled: !_profileVerified,
                                  ),
                                  actionPill(
                                    icon: !_profileVerified ? Icons.lock_rounded : (_myStories.isEmpty ? Icons.add_circle_outline_rounded : Icons.auto_stories_rounded),
                                    text: _loadingStory
                                        ? 'جاري النشر...'
                                        : (!_profileVerified ? 'الستوري للموثقين' : (_myStories.isEmpty ? 'إضافة ستوري' : 'عرض الستوري')),
                                    onTap: _loadingStory ? null : (_profileVerified ? (_myStories.isEmpty ? _pickStory : _openMyStory) : _openVerificationSheet),
                                    filled: _profileVerified && _myStories.isNotEmpty,
                                  ),
                                ],
                              ),
                              if (_profileSubscriptionTier != 'free') ...[
                                const SizedBox(height: 10),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: AppColors.purple.withValues(alpha: isDark ? .12 : .07),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(color: AppColors.purple.withValues(alpha: .14)),
                                  ),
                                  child: Row(
                                    children: [
                                      _RespectAiVerifiedBadge(tier: _profileSubscriptionTier, large: true),
                                      const SizedBox(width: 9),
                                      Expanded(
                                        child: AppText(
                                          SupabaseService.tierPowerDescription(_profileSubscriptionTier),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontWeight: FontWeight.w900, height: 1.35, fontSize: 12.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_editing) ...[
                    Container(
                      width: double.infinity,
                      color: cardBg,
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _SectionTitle('تعديل بيانات الحساب'),
                          const SizedBox(height: 10),
                          _ProfileField(controller: _nameCtrl, icon: Icons.badge_rounded, hint: 'اسم البروفايل'),
                          const SizedBox(height: 10),
                          _ProfileField(controller: _usernameCtrl, icon: Icons.alternate_email_rounded, hint: 'اسم المستخدم'),
                          const SizedBox(height: 10),
                          _ProfileField(controller: _bioCtrl, icon: Icons.short_text_rounded, hint: 'نبذة شخصية', maxLines: 3),
                          const SizedBox(height: 10),
                          _ProfileField(controller: _locationCtrl, icon: Icons.location_on_outlined, hint: 'الموقع'),
                          const SizedBox(height: 10),
                          _ProfileField(controller: _websiteCtrl, icon: Icons.link_rounded, hint: 'رابط شخصي'),
                          if (_pendingProfileImagePath != null || _pendingCoverPath != null) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.purple.withValues(alpha: .10),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: AppColors.purple.withValues(alpha: .20)),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.info_rounded, color: AppColors.purple),
                                  SizedBox(width: 8),
                                  Expanded(child: AppText('في صور مختارة تنتظر الحفظ. اضغط حفظ لتطبيق كل التعديلات.', style: TextStyle(fontWeight: FontWeight.w900))),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  _ProfileContentTabs(
                    loading: _loadingProfileContent,
                    posts: _profilePosts,
                    media: _profileMedia,
                    replies: _profileReplies,
                    isDark: isDark,
                    imageProvider: _fileImage,
                    displayName: displayName,
                    username: username,
                    avatarPath: _profileImagePath,
                    verified: _profileVerified,
                    subscriptionTier: _profileSubscriptionTier,
                    likedPostIds: _likedPostIds,
                    repostedPostIds: _repostedPostIds,
                    savedPostIds: _savedPostIds,
                    pendingActionIds: _pendingPostActionIds,
                    selectedTab: _selectedProfileTab,
                    onTabChanged: (index) {
                      if (_selectedProfileTab == index) return;
                      setState(() => _selectedProfileTab = index);
                    },
                    onLike: _toggleLikePost,
                    onRepost: _toggleRepostPost,
                    onSave: _toggleSavePost,
                    onOptions: _openPostOptions,
                    onRefresh: _refreshProfileTimeline,
                  ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
    );
  }
}




class _ProfileStoryViewer extends StatefulWidget {
  final List<Map<String, dynamic>> stories;
  final String ownerUsername;
  final bool ownerMode;

  const _ProfileStoryViewer({
    required this.stories,
    required this.ownerUsername,
    this.ownerMode = false,
  });

  @override
  State<_ProfileStoryViewer> createState() => _ProfileStoryViewerState();
}

class _ProfileStoryViewerState extends State<_ProfileStoryViewer> {
  late List<Map<String, dynamic>> _stories;
  int _index = 0;
  bool _muted = false;
  bool _liked = false;
  bool _busy = false;
  int _likes = 0;
  int _comments = 0;
  String _currentUsername = '@user';
  VideoPlayerController? _controller;
  final TextEditingController _commentCtrl = TextEditingController();

  Map<String, dynamic> get _story => _stories[_index];
  String get _storyId => (_story['id'] ?? '').toString();
  String get _ownerUsername => SupabaseService.displayUsername((_story['username'] ?? widget.ownerUsername).toString());
  bool get _isVideo => (_story['media_type'] ?? '').toString().toLowerCase().contains('video');

  @override
  void initState() {
    super.initState();
    _stories = widget.stories.map((e) => Map<String, dynamic>.from(e)).toList();
    _boot();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final me = await SupabaseService.currentUser();
      _currentUsername = SupabaseService.displayUsername((me?['username'] ?? '').toString());
    } catch (_) { _scannerSafeIgnore(); }
    await _loadVideo();
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
    } catch (_) { _scannerSafeIgnore(); }
  }

  Future<void> _loadVideo() async {
    await _controller?.dispose();
    _controller = null;
    final url = (_story['media_url'] ?? '').toString();
    if (!_isVideo || url.isEmpty) {
      if (mounted) setState(() {});
      return;
    }
    final c = url.startsWith('http') ? VideoPlayerController.networkUrl(Uri.parse(url)) : VideoPlayerController.file(File(url));
    _controller = c;
    await c.initialize();
    await c.setLooping(true);
    await c.setVolume(_muted ? 0 : 1);
    await c.play();
    if (mounted) setState(() {});
  }

  void _go(int dir) {
    final next = _index + dir;
    if (next < 0) return;
    if (next >= _stories.length) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _index = next;
      _liked = false;
      _likes = 0;
      _comments = 0;
    });
    unawaited(_loadVideo());
    unawaited(_loadStats());
    unawaited(SupabaseService.markStoriesSeen([_story]));
  }

  Future<void> _toggleMute() async {
    setState(() => _muted = !_muted);
    await _controller?.setVolume(_muted ? 0 : 1);
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
    } catch (e) {
      if (mounted) NotificationService.showTopError(context.tr('تعذر تحديث إعجاب الستوري'));
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
      NotificationService.showTopNotification(context.tr('تم إرسال التعليق'));
    } catch (e) {
      if (mounted) NotificationService.showTopError(context.tr('تعذر إرسال التعليق: $e'));
    }
  }

  Future<void> _deleteCurrentStoryItem() async {
    if (!widget.ownerMode || _storyId.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const AppText('حذف هذا العنصر؟', style: TextStyle(fontWeight: FontWeight.w900)),
        content: const AppText('سيتم حذف الصورة أو الفيديو الحالي فقط من الستوري.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const AppText('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const AppText('حذف')),
        ],
      ),
    );
    if (ok != true) return;
    await SupabaseService.deleteStoryItem(storyId: _storyId, username: _ownerUsername);
    if (!mounted) return;
    setState(() {
      _stories.removeAt(_index);
      if (_index >= _stories.length) _index = _stories.length - 1;
    });
    if (_stories.isEmpty) {
      Navigator.pop(context);
      return;
    }
    await _loadVideo();
    await _loadStats();
  }

  Future<void> _deleteAllStories() async {
    if (!widget.ownerMode) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const AppText('حذف الستوري كامل؟', style: TextStyle(fontWeight: FontWeight.w900)),
        content: const AppText('سيتم حذف كل صور وفيديوهات الستوري الحالية.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const AppText('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const AppText('حذف الكل')),
        ],
      ),
    );
    if (ok != true) return;
    await SupabaseService.deleteAllActiveStoriesForUser(_ownerUsername);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _openActivitySheet() async {
    final likes = await SupabaseService.getStoryLikes(_storyId);
    final comments = await SupabaseService.getStoryComments(_storyId);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _StoryActivitySheet(
          likes: likes,
          comments: comments,
          imageProvider: _imageProvider,
        );
      },
    );
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
    if (url.trim().isEmpty) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, color: Colors.white70, size: 74),
          SizedBox(height: 12),
          AppText('هذا الستوري مشفر وغير متاح لهذا الحساب', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w800)),
        ],
      );
    }
    if (_isVideo) {
      if (_controller?.value.isInitialized != true) {
        return const Center(child: CircularProgressIndicator(color: AppColors.purple));
      }
      return FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: (_controller?.value.size.width ?? 16),
          height: (_controller?.value.size.height ?? 9),
          child: _controller == null ? const SizedBox.shrink() : VideoPlayer(_controller as VideoPlayerController),
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
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
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
                            _go(-1);
                          } else if (d.localPosition.dx > w * .65) {
                            _go(1);
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
                            children: List.generate(_stories.length, (i) {
                              return Expanded(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  height: 4,
                                  margin: const EdgeInsets.symmetric(horizontal: 2),
                                  decoration: BoxDecoration(
                                    gradient: i <= _index
                                        ? const LinearGradient(colors: [AppColors.purpleLight, Colors.white])
                                        : null,
                                    color: i <= _index ? null : Colors.white24,
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                ),
                              );
                            }),
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
                                    AppText(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15)),
                                    AppText(username, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: .65), fontWeight: FontWeight.w700, fontSize: 12)),
                                  ],
                                ),
                              ),
                              _StoryRoundButton(icon: _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, onTap: _toggleMute),
                              if (widget.ownerMode) _StoryRoundButton(icon: Icons.analytics_rounded, onTap: _openActivitySheet),
                              if (widget.ownerMode)
                                PopupMenuButton<String>(
                                  color: const Color(0xFF211235),
                                  icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
                                  onSelected: (v) {
                                    if (v == 'delete_item') _deleteCurrentStoryItem();
                                    if (v == 'delete_all') _deleteAllStories();
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'delete_item', child: AppText('حذف هذا العنصر', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
                                    PopupMenuItem(value: 'delete_all', child: AppText('حذف الستوري كامل', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
                                  ],
                                ),
                              _StoryRoundButton(icon: Icons.close_rounded, onTap: () => Navigator.pop(context)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    PositionedDirectional(
                      bottom: 12 + bottomInset,
                      start: 12,
                      end: 12,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.ownerMode)
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: GestureDetector(
                                onTap: _openActivitySheet,
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: .32),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(color: Colors.white.withValues(alpha: .14)),
                                  ),
                                  child: AppText('$_likes إعجاب · $_comments تعليق', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                                ),
                              ),
                            ),
                          Row(
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
                                      hintText: context.tr('اكتب تعليق على الستوري...'),
                                      hintStyle: TextStyle(color: Colors.white.withValues(alpha: .58)),
                                      border: InputBorder.none,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    ),
                                    onSubmitted: (_) => _sendComment(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _StoryRoundButton(icon: Icons.send_rounded, onTap: _sendComment, filled: true),
                              const SizedBox(width: 8),
                              _StoryRoundButton(icon: _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, onTap: _toggleLike, filled: _liked),
                            ],
                          ),
                        ],
                      ),
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

class _StoryRoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;
  const _StoryRoundButton({required this.icon, required this.onTap, this.filled = false});

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

class _StoryPickerTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _StoryPickerTile({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.purple.withValues(alpha: isDark ? .12 : .08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.purple.withValues(alpha: .16)),
      ),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: AppColors.purple.withValues(alpha: .18),
          child: Icon(icon, color: AppColors.purple),
        ),
        title: AppText(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        subtitle: AppText(subtitle),
        trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
      ),
    );
  }
}

class _StoryActivitySheet extends StatelessWidget {
  final List<Map<String, dynamic>> likes;
  final List<Map<String, dynamic>> comments;
  final ImageProvider? Function(String? path) imageProvider;

  const _StoryActivitySheet({
    required this.likes,
    required this.comments,
    required this.imageProvider,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DraggableScrollableSheet(
      initialChildSize: .62,
      minChildSize: .35,
      maxChildSize: .92,
      builder: (context, controller) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBg : AppColors.lightBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            border: Border.all(color: AppColors.purple.withValues(alpha: .18)),
            boxShadow: [BoxShadow(color: AppColors.purple.withValues(alpha: .20), blurRadius: 36, offset: const Offset(0, -14))],
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Center(child: Container(width: 50, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .65), borderRadius: BorderRadius.circular(99)))),
              const SizedBox(height: 16),
              const AppText('تفاعل الستوري', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              _StoryActivitySection(
                title: 'الإعجابات',
                icon: Icons.favorite_rounded,
                rows: likes,
                empty: 'ما في إعجابات بعد',
                imageProvider: imageProvider,
                textBuilder: (row) => (row['actor_name'] ?? row['actor_username'] ?? 'مستخدم').toString(),
                subBuilder: (row) => (row['actor_username'] ?? '').toString(),
              ),
              const SizedBox(height: 18),
              _StoryActivitySection(
                title: 'التعليقات',
                icon: Icons.mode_comment_rounded,
                rows: comments,
                empty: 'ما في تعليقات بعد',
                imageProvider: imageProvider,
                textBuilder: (row) => (row['actor_name'] ?? row['actor_username'] ?? 'مستخدم').toString(),
                subBuilder: (row) => (row['text'] ?? '').toString(),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StoryActivitySection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Map<String, dynamic>> rows;
  final String empty;
  final ImageProvider? Function(String? path) imageProvider;
  final String Function(Map<String, dynamic> row) textBuilder;
  final String Function(Map<String, dynamic> row) subBuilder;

  const _StoryActivitySection({
    required this.title,
    required this.icon,
    required this.rows,
    required this.empty,
    required this.imageProvider,
    required this.textBuilder,
    required this.subBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.purple.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.purple.withValues(alpha: .13)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [Icon(icon, color: AppColors.purple), const SizedBox(width: 8), AppText(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))]),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: AppText(empty, style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700)),
            )
          else
            ...rows.map((row) {
              final avatar = (row['actor_avatar'] ?? '').toString();
              final img = imageProvider(avatar);
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: AppColors.purple,
                  backgroundImage: img,
                  child: img == null ? const Icon(Icons.person_rounded, color: Colors.white) : null,
                ),
                title: AppText(textBuilder(row), style: const TextStyle(fontWeight: FontWeight.w900)),
                subtitle: AppText(subBuilder(row), maxLines: 2, overflow: TextOverflow.ellipsis),
              );
            }),
        ],
      ),
    );
  }
}

// ----------------------------------------------
//      دوال الصور والبث (مطابقة لنسخة البثوث)
// ----------------------------------------------

String _cleanStreamUrl(String value) {
  final v = value.trim();
  if (v.isEmpty) return '';
  return v.startsWith('http://') || v.startsWith('https://') ? v : 'https://$v';
}

Future<_StreamMetadata> _fetchStreamMetadata(String url, {required String fallbackName}) async {
  final cleanUrl = _cleanStreamUrl(url);
  final platform = _platformFromUrl(cleanUrl);
  final channel = _channelFromUrl(cleanUrl);

  if (cleanUrl.isEmpty) return _StreamMetadata.empty();

  try {
    if (platform == 'Kick' && channel.isNotEmpty) {
      final meta = await _fetchKickMetadata(cleanUrl, channel, fallbackName: fallbackName);
      if (meta.hasUsefulData) return meta;
    }
    if (platform == 'Twitch' && channel.isNotEmpty) {
      final meta = await _fetchTwitchMetadata(cleanUrl, channel, fallbackName: fallbackName);
      if (meta.hasUsefulData) return meta;
    }
    if (platform == 'YouTube') {
      final meta = await _fetchYouTubeMetadata(cleanUrl, fallbackName: fallbackName);
      if (meta.hasUsefulData) return meta;
    }
    return await _fetchGenericMetadata(cleanUrl,
        fallbackName: fallbackName, platform: platform, channel: channel);
  } catch (_) {
    return _StreamMetadata(
        platform: platform,
        channelName: channel.isNotEmpty ? channel : fallbackName,
        title: '',
        thumbnailUrl: '',
        isLive: false,
        viewers: 0);
  }
}

Future<_StreamMetadata> _fetchKickMetadata(String url, String channel,
    {required String fallbackName}) async {
  for (final api in ['https://kick.com/api/v2/channels/$channel', 'https://kick.com/api/v1/channels/$channel']) {
    try {
      final raw = await _readUrl(api, json: true);
      final decoded = jsonDecode(raw);
      if (decoded is! Map) continue;
      final data = decoded.map((k, v) => MapEntry(k.toString(), v));
      final livestream = data['livestream'];
      final liveMap = livestream is Map ? livestream.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};
      final user = data['user'];
      final userMap = user is Map ? user.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};
      final isLive = liveMap.isNotEmpty || (liveMap['playback_url']?.toString() ?? '').isNotEmpty;
      final viewers = _toInt(_firstNonEmpty([liveMap['viewer_count']?.toString() ?? '', liveMap['viewers']?.toString() ?? '', data['viewer_count']?.toString() ?? '']));
      final title = _cleanHtml(_firstNonEmpty([liveMap['session_title']?.toString() ?? '', liveMap['title']?.toString() ?? '']));
      var thumbnail = _firstNonEmpty([
        liveMap['thumbnail'] is Map ? ((liveMap['thumbnail'] as Map)['url']?.toString() ?? '') : '',
        liveMap['thumbnail']?.toString() ?? '',
        liveMap['thumbnail_url']?.toString() ?? '',
        liveMap['preview']?.toString() ?? '',
        liveMap['preview_url']?.toString() ?? '',
        data['banner_image'] is Map ? ((data['banner_image'] as Map)['url']?.toString() ?? '') : '',
        data['banner_image']?.toString() ?? '',
        userMap['profile_pic']?.toString() ?? '',
      ]);
      if (thumbnail.isEmpty && channel.isNotEmpty) {
        thumbnail = 'https://images.kick.com/video_thumbnails/$channel/thumbnail.jpg';
      }
      final name = _firstNonEmpty([data['slug']?.toString() ?? '', userMap['username']?.toString() ?? '', channel, fallbackName]);
      return _StreamMetadata(platform: 'Kick', channelName: name, title: title, thumbnailUrl: thumbnail, isLive: isLive, viewers: viewers);
    } catch (_) { _scannerSafeIgnore(); }
  }
  return await _fetchGenericMetadata(url, fallbackName: fallbackName, platform: 'Kick', channel: channel);
}

Future<_StreamMetadata> _fetchTwitchMetadata(String url, String channel, {required String fallbackName}) async {
  var channelName = channel;
  var title = '';
  var thumbnail = '';
  var isLive = false;
  var viewers = 0;

  try {
    final raw = await _readUrl('https://www.twitch.tv/oembed?url=${Uri.encodeComponent(url)}', json: true);
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      title = _cleanHtml((decoded['title'] ?? '').toString());
      channelName = _firstNonEmpty([(decoded['author_name'] ?? '').toString(), channelName, fallbackName]);
      thumbnail = (decoded['thumbnail_url'] ?? '').toString();
    }
  } catch (_) { _scannerSafeIgnore(); }

  try {
    final gqlBody = jsonEncode([{
      'operationName': 'StreamMetadata',
      'variables': {'channelLogin': channel.toLowerCase()},
      'extensions': {'persistedQuery': {'version': 1, 'sha256Hash': 'a647c2a13599e5991e175155f798ca7f1ecddde73f7f341f39009c14dbf59962'}}
    }]);
    final raw = await _postUrl('https://gql.twitch.tv/gql', gqlBody, headers: {
      'Client-ID': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
      'Content-Type': 'text/plain;charset=UTF-8',
    });
    final decoded = jsonDecode(raw);
    if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
      final data = (decoded.first as Map)['data'];
      final user = data is Map ? data['user'] : null;
      if (user is Map) {
        final stream = user['stream'];
        final streamMap = stream is Map ? stream.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};
        final profileImage = user['profileImageURL']?.toString() ?? '';
        if (streamMap.isNotEmpty) {
          isLive = true;
          viewers = _toInt(streamMap['viewersCount']?.toString() ?? streamMap['viewers']?.toString() ?? '0');
          title = _cleanHtml(_firstNonEmpty([streamMap['title']?.toString() ?? '', title]));
          thumbnail = _firstNonEmpty([streamMap['previewImageURL']?.toString() ?? '', thumbnail, profileImage]);
        } else {
          thumbnail = _firstNonEmpty([thumbnail, profileImage]);
        }
        channelName = _firstNonEmpty([user['displayName']?.toString() ?? '', channelName, fallbackName]);
      }
    }
  } catch (_) { _scannerSafeIgnore(); }

  if (thumbnail.contains('{width}')) thumbnail = thumbnail.replaceAll('{width}', '1280');
  if (thumbnail.contains('{height}')) thumbnail = thumbnail.replaceAll('{height}', '720');

  if (title.isEmpty || thumbnail.isEmpty || (!isLive && viewers == 0)) {
    try {
      final generic = await _fetchGenericMetadata(url, fallbackName: fallbackName, platform: 'Twitch', channel: channel);
      title = _firstNonEmpty([title, generic.title]);
      thumbnail = _firstNonEmpty([thumbnail, generic.thumbnailUrl]);
      isLive = isLive || generic.isLive;
      viewers = viewers > 0 ? viewers : generic.viewers;
      channelName = _firstNonEmpty([channelName, generic.channelName]);
    } catch (_) { _scannerSafeIgnore(); }
  }

  return _StreamMetadata(platform: 'Twitch', channelName: channelName, title: title, thumbnailUrl: thumbnail, isLive: isLive, viewers: viewers);
}

Future<_StreamMetadata> _fetchYouTubeMetadata(String url, {required String fallbackName}) async {
  var title = '';
  var thumbnail = '';
  var channelName = _channelFromUrl(url);
  var isLive = false;
  var viewers = 0;
  try {
    final raw = await _readUrl('https://www.youtube.com/oembed?url=${Uri.encodeComponent(url)}&format=json', json: true);
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      title = _cleanHtml((decoded['title'] ?? '').toString());
      channelName = _firstNonEmpty([(decoded['author_name'] ?? '').toString(), channelName, fallbackName]);
      thumbnail = (decoded['thumbnail_url'] ?? '').toString();
    }
  } catch (_) { _scannerSafeIgnore(); }
  try {
    final html = await _readUrl(url);
    final generic = _metadataFromHtml(html, fallbackName: fallbackName, platform: 'YouTube', channel: channelName);
    title = _firstNonEmpty([title, generic.title]);
    thumbnail = _firstNonEmpty([thumbnail, generic.thumbnailUrl]);
    viewers = generic.viewers;
    isLive = generic.isLive;
    channelName = _firstNonEmpty([channelName, generic.channelName, fallbackName]);
  } catch (_) { _scannerSafeIgnore(); }
  return _StreamMetadata(platform: 'YouTube', channelName: channelName.isNotEmpty ? channelName : fallbackName, title: title, thumbnailUrl: thumbnail, isLive: isLive, viewers: viewers);
}

Future<_StreamMetadata> _fetchGenericMetadata(String url, {required String fallbackName, required String platform, required String channel}) async {
  final html = await _readUrl(url);
  return _metadataFromHtml(html, fallbackName: fallbackName, platform: platform, channel: channel);
}

_StreamMetadata _metadataFromHtml(String html, {required String fallbackName, required String platform, required String channel}) {
  final title = _cleanHtml(_firstNonEmpty([
    _meta(html, 'property', 'og:title'),
    _meta(html, 'name', 'twitter:title'),
    _jsonString(html, 'title'),
    _firstMatch(html, RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true))
  ]));
  final image = _firstNonEmpty([
    _meta(html, 'property', 'og:image'),
    _meta(html, 'property', 'og:image:secure_url'),
    _meta(html, 'name', 'twitter:image'),
    _meta(html, 'name', 'twitter:image:src'),
    _jsonString(html, 'thumbnailUrl'),
    _jsonString(html, 'thumbnail_url')
  ]);
  final viewers = _extractViewers(html);
  final live = _looksLive(html, title, viewers);
  return _StreamMetadata(platform: platform, channelName: channel.isNotEmpty ? channel : fallbackName, title: title, thumbnailUrl: image, isLive: live, viewers: viewers);
}

Future<String> _readUrl(String url, {bool json = false}) async {
  final uri = Uri.parse(url);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36 RespectApp/1.0');
    request.headers.set(HttpHeaders.acceptHeader, json ? 'application/json,text/plain,*/*' : 'text/html,application/xhtml+xml,application/json,text/plain,*/*');
    request.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9,ar;q=0.8');
    if (uri.host.toLowerCase().contains('kick.com')) {
      request.headers.set(HttpHeaders.refererHeader, 'https://kick.com/');
      request.headers.set('Origin', 'https://kick.com');
    }
    request.followRedirects = true;
    final response = await request.close().timeout(const Duration(seconds: 10));
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

Future<String> _postUrl(String url, String body, {Map<String, String> headers = const {}}) async {
  final uri = Uri.parse(url);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.postUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 RespectApp/1.0');
    headers.forEach(request.headers.set);
    request.write(body);
    final response = await request.close().timeout(const Duration(seconds: 10));
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

String _meta(String html, String attrName, String attrValue) {
  final patternA = RegExp('<meta[^>]*$attrName=["\\\']$attrValue["\\\'][^>]*content=["\\\']([^"\\\']*)["\\\'][^>]*>', caseSensitive: false, dotAll: true);
  final patternB = RegExp('<meta[^>]*content=["\\\']([^"\\\']*)["\\\'][^>]*$attrName=["\\\']$attrValue["\\\'][^>]*>', caseSensitive: false, dotAll: true);
  final a = _firstMatch(html, patternA);
  return a.isNotEmpty ? a : _firstMatch(html, patternB);
}

String _jsonString(String text, String key) {
  final escaped = RegExp('"$key"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"', caseSensitive: false, dotAll: true);
  final m = escaped.firstMatch(text);
  if (m == null) return '';
  return _cleanHtml((m.group(1) ?? '').replaceAll('\\\\/', '/').replaceAll('\\\\u0026', '&'));
}

String _firstMatch(String text, RegExp regex) => regex.firstMatch(text)?.group(1)?.trim() ?? '';
String _firstNonEmpty(List<String> values) => values.firstWhere((v) => v.trim().isNotEmpty, orElse: () => '').trim();
String _cleanHtml(String value) => value.replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('\\/', '/').replaceAll(RegExp(r'\s+'), ' ').trim();

int _toInt(String value) {
  final clean = value.toLowerCase().replaceAll(',', '').trim();
  final match = RegExp(r'(\d+(?:\.\d+)?)\s*([km]?)').firstMatch(clean);
  if (match == null) return 0;
  final n = double.tryParse(match.group(1) ?? '0') ?? 0;
  final suffix = match.group(2) ?? '';
  if (suffix == 'm') return (n * 1000000).round();
  if (suffix == 'k') return (n * 1000).round();
  return n.round();
}

int _extractViewers(String html) {
  final patterns = [
    RegExp(r'"viewer_count"\s*:\s*(\d+)', caseSensitive: false),
    RegExp(r'"viewers"\s*:\s*(\d+)', caseSensitive: false),
    RegExp(r'"viewersCount"\s*:\s*(\d+)', caseSensitive: false),
    RegExp(r'"currentViewers"\s*:\s*(\d+)', caseSensitive: false),
    RegExp(r'"live_viewers"\s*:\s*(\d+)', caseSensitive: false),
    RegExp(r'"concurrentViewers"\s*:\s*(\d+)', caseSensitive: false),
    RegExp(r'(\d+(?:\.\d+)?\s*[kKmM]?)\s+(?:watching|viewers|مشاهد|مشاهدين)', caseSensitive: false),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(html);
    if (m != null) return _toInt(m.group(1) ?? '0');
  }
  return 0;
}

bool _looksLive(String html, String title, int viewers) {
  final h = html.toLowerCase();
  final t = title.toLowerCase();
  return viewers > 0 || h.contains('"is_live":true') || h.contains('"islive":true') || h.contains('"islivebroadcast":true') || h.contains('"status":"live"') || h.contains('live_user') || h.contains('watching now') || h.contains('is currently live') || t.contains(' live') || t.contains('مباشر');
}

String _platformFromUrl(String url) {
  final u = url.toLowerCase();
  if (u.contains('kick.com')) return 'Kick';
  if (u.contains('twitch.tv')) return 'Twitch';
  if (u.contains('youtube.com') || u.contains('youtu.be')) return 'YouTube';
  if (u.contains('facebook.com')) return 'Facebook';
  return 'Stream';
}

String _channelFromUrl(String url) {
  try {
    final uri = Uri.parse(_cleanStreamUrl(url));
    final parts = uri.pathSegments.where((p) => p.trim().isNotEmpty).toList();
    if (parts.isEmpty) return '';
    if (uri.host.contains('youtube') && parts.first.startsWith('@')) return parts.first;
    if (uri.host.contains('youtube') && parts.first == 'channel' && parts.length > 1) return parts[1];
    if (uri.host.contains('youtu.be')) return parts.first;
    return parts.first.replaceAll('@', '');
  } catch (_) {
    return '';
  }
}

class _StreamMetadata {
  final String platform;
  final String channelName;
  final String title;
  final String thumbnailUrl;
  final bool isLive;
  final int viewers;
  const _StreamMetadata({required this.platform, required this.channelName, required this.title, required this.thumbnailUrl, required this.isLive, required this.viewers});
  bool get hasUsefulData => title.trim().isNotEmpty || thumbnailUrl.trim().isNotEmpty || isLive || viewers > 0 || channelName.trim().isNotEmpty;
  factory _StreamMetadata.empty() => const _StreamMetadata(platform: '', channelName: '', title: '', thumbnailUrl: '', isLive: false, viewers: 0);
}

// ----------------------------------------------
// دوال الصور (نسخة مطابقة)
// ----------------------------------------------
Map<String, String> _streamImageHeaders(String url) {
  final u = url.toLowerCase();
  final referer = u.contains('kick.com')
      ? 'https://kick.com/'
      : u.contains('twitch')
      ? 'https://www.twitch.tv/'
      : u.contains('youtube') || u.contains('ytimg')
      ? 'https://www.youtube.com/'
      : 'https://www.google.com/';
  return {
    HttpHeaders.userAgentHeader: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    HttpHeaders.acceptHeader: 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
    HttpHeaders.acceptLanguageHeader: 'en-US,en;q=0.9,ar;q=0.8',
    HttpHeaders.refererHeader: referer,
    'Origin': referer.replaceAll(RegExp(r'/$'), ''),
    'Sec-Fetch-Dest': 'image',
    'Sec-Fetch-Mode': 'no-cors',
    'Sec-Fetch-Site': u.contains('kick.com') ? 'same-site' : 'cross-site',
  };
}

String _normalizeStreamImageUrl(String url) {
  final clean = url.trim();
  if (clean.isEmpty) return '';
  if (clean.startsWith('//')) return 'https:$clean';
  if (clean.startsWith('http://') || clean.startsWith('https://')) return clean;
  return clean;
}

bool _isKickProtectedThumbnailUrl(String url) {
  final u = url.toLowerCase();
  return u.contains('stream.kick.com/thumbnails/') ||
      (u.contains('/livestream/') && u.contains('/video_thumbnail/')) ||
      (u.contains('kick.com/api/v2/channels/') && u.contains('/livestream/thumbnail'));
}

bool _isLocalImagePath(String? path) {
  if (path == null || path.trim().isEmpty) return false;
  final clean = path.trim();
  if (clean.startsWith('http://') || clean.startsWith('https://')) return false;
  return File(clean).existsSync();
}

String _safeStreamThumbnailValue({required String cachedPath, required String remoteUrl, String? previousValue}) {
  if (cachedPath.trim().isNotEmpty) return cachedPath.trim();
  final previousClean = previousValue?.trim() ?? '';
  if (_isLocalImagePath(previousClean)) return previousClean;
  if (remoteUrl.trim().isNotEmpty && !_isKickProtectedThumbnailUrl(remoteUrl)) {
    return remoteUrl.trim();
  }
  return '';
}

List<String> _kickThumbnailCandidates(String original, String channel) {
  final cleanOriginal = _normalizeStreamImageUrl(original);
  final parts = channel.trim().replaceAll('@', '').split('/').where((e) => e.trim().isNotEmpty).toList();
  final cleanChannel = parts.isEmpty ? '' : parts.first;
  final list = <String>[];
  void add(String value) {
    final v = _normalizeStreamImageUrl(value);
    if (v.isEmpty) return;
    if (!list.contains(v)) list.add(v);
  }
  if (!_isKickProtectedThumbnailUrl(cleanOriginal)) add(cleanOriginal);
  final liveId = RegExp(r'/livestream/(\d+)/').firstMatch(cleanOriginal)?.group(1) ?? '';
  if (liveId.isNotEmpty) {
    add('https://images.kick.com/thumbnails/livestream/$liveId/thumb0/video_thumbnail/thumb0.jpg');
    add('https://images.kick.com/video_thumbnails/livestream/$liveId/thumbnail.jpg');
    add('https://kick.com/api/v2/livestreams/$liveId/thumbnail');
  }
  if (cleanChannel.isNotEmpty) {
    add('https://images.kick.com/video_thumbnails/$cleanChannel/thumbnail.jpg');
    add('https://kick.com/api/v2/channels/$cleanChannel/livestream/thumbnail');
    add('https://kick.com/$cleanChannel');
  }
  return list;
}

Future<String> _cacheBestStreamThumbnail(String url, {String platform = '', String channel = ''}) async {
  final candidates = platform.toLowerCase() == 'kick' ? _kickThumbnailCandidates(url, channel) : <String>[_normalizeStreamImageUrl(url)];
  for (final candidate in candidates) {
    if (candidate.isEmpty) continue;
    if (platform.toLowerCase() == 'kick' && candidate.startsWith('https://kick.com/') && !candidate.contains('/thumbnail')) {
      try {
        final html = await _readUrl(candidate);
        final extracted = _firstNonEmpty([_meta(html, 'property', 'og:image'), _meta(html, 'property', 'og:image:secure_url'), _meta(html, 'name', 'twitter:image'), _jsonString(html, 'thumbnailUrl'), _jsonString(html, 'thumbnail_url')]);
        final path = await _cacheStreamThumbnail(extracted, platform: platform);
        if (path.isNotEmpty) return path;
      } catch (_) { _scannerSafeIgnore(); }
      continue;
    }
    final path = await _cacheStreamThumbnail(candidate, platform: platform);
    if (path.isNotEmpty) return path;
  }
  return '';
}

Future<String> _cacheStreamThumbnail(String url, {String platform = ''}) async {
  final clean = _normalizeStreamImageUrl(url);
  if (clean.isEmpty || !(clean.startsWith('http://') || clean.startsWith('https://'))) return '';
  if (_isKickProtectedThumbnailUrl(clean)) return '';
  try {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/respect_stream_thumbs');
    if (!await folder.exists()) await folder.create(recursive: true);
    final safeName = base64Url.encode(utf8.encode(clean)).replaceAll('=', '');
    final ext = clean.toLowerCase().contains('.png') ? 'png' : clean.toLowerCase().contains('.webp') ? 'webp' : 'jpg';
    final file = File('${folder.path}/$safeName.$ext');
    if (await file.exists() && await file.length() > 100) return file.path;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(clean));
      _streamImageHeaders(clean).forEach(request.headers.set);
      request.followRedirects = true;
      final response = await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300) return '';
      final bytes = await response.fold<List<int>>(<int>[], (previous, chunk) => previous..addAll(chunk));
      if (bytes.length < 100) return '';
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } finally {
      client.close(force: true);
    }
  } catch (_) {
    return '';
  }
}

// ----------------------------------------------
// واجهة العرض
// ----------------------------------------------
class _AutoStreamPreview extends StatelessWidget {
  final String? thumbnailUrl;
  final String title;
  final String channelName;
  final int viewers;
  final bool isLive;
  final bool isDark;

  const _AutoStreamPreview({required this.thumbnailUrl, required this.title, required this.channelName, required this.viewers, required this.isLive, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final url = _normalizeStreamImageUrl(thumbnailUrl ?? '');
    return Container(
      height: 150,
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (url.startsWith('http') && !_isKickProtectedThumbnailUrl(url))
            Image.network(
              url,
              fit: BoxFit.cover,
              headers: _streamImageHeaders(url),
              gaplessPlayback: true,
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return const _StreamFallbackArt(showLoader: true);
              },
              errorBuilder: (_, __, ___) => const _StreamFallbackArt(),
            )
          else if (url.isNotEmpty && File(url).existsSync())
            Image.file(File(url), fit: BoxFit.cover, gaplessPlayback: true)
          else
            const _StreamFallbackArt(),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withValues(alpha: 0.08), Colors.black.withValues(alpha: 0.72)]),
            ),
          ),
          PositionedDirectional(
            top: 10,
            start: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: isLive ? AppColors.danger : Colors.black54,
                  borderRadius: BorderRadius.circular(999)),
              child: AppText(isLive ? 'LIVE' : 'OFFLINE',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
            ),
          ),
          PositionedDirectional(
            start: 12,
            end: 12,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppText(title.isEmpty ? 'سيظهر عنوان البث تلقائيًا هنا' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
                const SizedBox(height: 3),
                AppText('${channelName.isEmpty ? 'اسم القناة' : channelName} · $viewers مشاهد',
                    style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamFallbackArt extends StatelessWidget {
  final bool showLoader;
  const _StreamFallbackArt({this.showLoader = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [AppColors.purple, Color(0xFF3B0764)])),
      child: Center(
        child: showLoader
            ? const SizedBox(width: 24, height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
            : const Icon(Icons.live_tv_rounded, color: Colors.white70, size: 58),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) =>
      AppText(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900));
}

class _ProfileField extends StatelessWidget {
  final TextEditingController controller;
  final IconData icon;
  final String hint;
  final int maxLines;
  final TextInputType? keyboardType;
  const _ProfileField(
      {required this.controller,
        required this.icon,
        required this.hint,
        this.maxLines = 1,
        this.keyboardType});
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      onChanged: (_) => (context as Element).markNeedsBuild(),
      decoration: InputDecoration(prefixIcon: Icon(icon), hintText: hint),
    ).animate().fadeIn().slideX(begin: -0.04);
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoChip({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.purple.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.purple.withValues(alpha: 0.22)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: AppColors.purple, size: 16),
        const SizedBox(width: 5),
        AppText(text,
            style: TextStyle(
                color: isDark ? Colors.white : Colors.black87, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}


class _ProfileContentTabs extends StatelessWidget {
  final bool loading;
  final List<Map<String, dynamic>> posts;
  final List<Map<String, dynamic>> media;
  final List<Map<String, dynamic>> replies;
  final bool isDark;
  final String displayName;
  final String username;
  final String? avatarPath;
  final bool verified;
  final String subscriptionTier;
  final Set<String> likedPostIds;
  final Set<String> repostedPostIds;
  final Set<String> savedPostIds;
  final Set<String> pendingActionIds;
  final int selectedTab;
  final ValueChanged<int> onTabChanged;
  final ImageProvider? Function(String? path) imageProvider;
  final Future<void> Function(Map<String, dynamic> post) onLike;
  final Future<void> Function(Map<String, dynamic> post) onRepost;
  final Future<void> Function(Map<String, dynamic> post) onSave;
  final void Function(Map<String, dynamic> post) onOptions;
  final Future<void> Function() onRefresh;

  const _ProfileContentTabs({
    required this.loading,
    required this.posts,
    required this.media,
    required this.replies,
    required this.isDark,
    required this.imageProvider,
    required this.displayName,
    required this.username,
    required this.avatarPath,
    required this.verified,
    required this.subscriptionTier,
    required this.likedPostIds,
    required this.repostedPostIds,
    required this.savedPostIds,
    required this.pendingActionIds,
    required this.selectedTab,
    required this.onTabChanged,
    required this.onLike,
    required this.onRepost,
    required this.onSave,
    required this.onOptions,
    required this.onRefresh,
  });

  Widget _divider() => Divider(height: 1, color: AppColors.purple.withValues(alpha: .10));

  Widget _postCard(Map<String, dynamic> p, {bool mediaOnly = false}) {
    final id = (p['id'] ?? '').toString();
    return _ProfileTweetCard(
      post: p,
      isDark: isDark,
      mediaOnly: mediaOnly,
      displayName: (p['name'] ?? p['user'] ?? displayName).toString(),
      username: SupabaseService.displayUsername((p['username'] ?? username).toString()),
      avatarPath: (p['avatar_url'] ?? p['avatarPath'] ?? avatarPath ?? '').toString(),
      verified: verified || p['author_verified'] == true || p['author_verified']?.toString() == 'true',
      subscriptionTier: (p['author_subscription_tier'] ?? p['subscriptionTier'] ?? p['subscription_tier'] ?? subscriptionTier).toString(),
      liked: likedPostIds.contains(id) || p['isLiked'] == true || p['is_liked'] == true,
      reposted: repostedPostIds.contains(id) || p['isReposted'] == true || p['is_reposted'] == true,
      saved: savedPostIds.contains(id) || p['isSaved'] == true || p['is_saved'] == true,
      busy: pendingActionIds.any((e) => e.endsWith('_$id')),
      imageProvider: imageProvider,
      onLike: () => onLike(p),
      onRepost: () => onRepost(p),
      onSave: () => onSave(p),
      onOptions: () => onOptions(p),
    );
  }

  List<Widget> _postItems(List<Map<String, dynamic>> items, String emptyText, {bool mediaOnly = false}) {
    if (items.isEmpty) return [_ProfileInlineEmpty(text: emptyText, isDark: isDark)];
    final widgets = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      widgets.add(_postCard(items[i], mediaOnly: mediaOnly));
      if (i != items.length - 1) widgets.add(_divider());
    }
    return widgets;
  }

  List<Widget> _replyItems() {
    if (replies.isEmpty) return [_ProfileInlineEmpty(text: 'لا توجد ردود بعد', isDark: isDark)];
    final widgets = <Widget>[];
    for (var i = 0; i < replies.length; i++) {
      widgets.add(_ProfileInlineReplyCard(reply: replies[i], isDark: isDark, imageProvider: imageProvider));
      if (i != replies.length - 1) widgets.add(_divider());
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF0D0D14) : Colors.white;
    final border = isDark ? Colors.white.withValues(alpha: .10) : const Color(0xFFE6ECF0);
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    Widget tabLabel(int index, String title, int count) {
      final selected = selectedTab == index;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: loading ? null : () => onTabChanged(index),
          child: Container(
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? AppColors.purple : Colors.transparent,
                  width: selected ? 3 : 0,
                ),
              ),
            ),
            child: AppText(
              count > 0 ? '$title  $count' : title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? (isDark ? Colors.white : Colors.black) : muted,
                fontWeight: selected ? FontWeight.w900 : FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      color: bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: bg,
              border: Border(
                top: BorderSide(color: border),
                bottom: BorderSide(color: border),
              ),
            ),
            child: Row(
              children: [
                tabLabel(0, 'المنشورات', posts.length),
                tabLabel(1, 'الوسائط', media.length),
                tabLabel(2, 'الردود', replies.length),
                SizedBox(
                  width: 46,
                  child: IconButton(
                    onPressed: loading ? null : onRefresh,
                    tooltip: context.tr('تحديث'),
                    icon: Icon(Icons.refresh_rounded, size: 20, color: loading ? muted : AppColors.purple),
                  ),
                ),
              ],
            ),
          ),
          if (loading)
            const SizedBox(
              height: 230,
              child: Center(child: CircularProgressIndicator(color: AppColors.purple)),
            )
          else if (selectedTab == 0)
            ..._postItems(posts, 'ما عندك تغريدات بعد')
          else if (selectedTab == 1)
            ..._postItems(media, 'ما عندك وسائط بعد', mediaOnly: true)
          else
            ..._replyItems(),
        ],
      ),
    );
  }
}


class _ProfileInlineSectionHeader extends StatelessWidget {
  final String title;
  final int count;

  const _ProfileInlineSectionHeader({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 9),
      decoration: BoxDecoration(
        color: AppColors.purple.withValues(alpha: isDark ? .08 : .055),
        border: Border(
          top: BorderSide(color: AppColors.purple.withValues(alpha: .10)),
          bottom: BorderSide(color: AppColors.purple.withValues(alpha: .07)),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: AppText(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.purple.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: AppText('$count', style: TextStyle(color: count == 0 ? muted : AppColors.purple, fontWeight: FontWeight.w900, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _ProfileInlineEmpty extends StatelessWidget {
  final String text;
  final bool isDark;

  const _ProfileInlineEmpty({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      child: Center(
        child: AppText(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _ProfileInlineReplyCard extends StatelessWidget {
  final Map<String, dynamic> reply;
  final bool isDark;
  final ImageProvider? Function(String? path) imageProvider;

  const _ProfileInlineReplyCard({required this.reply, required this.isDark, required this.imageProvider});

  @override
  Widget build(BuildContext context) {
    final text = (reply['text'] ?? '').toString();
    final postText = (reply['postText'] ?? '').toString();
    final postUser = (reply['postUser'] ?? '').toString();
    final avatar = imageProvider((reply['avatarPath'] ?? reply['author_avatar_url'] ?? '').toString());
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    return Container(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.purple,
            backgroundImage: avatar,
            child: avatar == null ? const Icon(Icons.reply_rounded, color: Colors.white, size: 20) : null,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _LinkifiedText(text.isEmpty ? 'رد بدون نص' : text, style: const TextStyle(fontWeight: FontWeight.w800, height: 1.45, fontSize: 15)),
                if (postText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.purple.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.purple.withValues(alpha: 0.16)),
                    ),
                    child: _LinkifiedText(
                      'ردًا على ${postUser.isEmpty ? 'منشور' : postUser}: $postText',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12, height: 1.35, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfilePostsList extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final String emptyText;
  final bool isDark;
  final bool mediaOnly;
  final String displayName;
  final String username;
  final String? avatarPath;
  final bool verified;
  final String subscriptionTier;
  final Set<String> likedPostIds;
  final Set<String> repostedPostIds;
  final Set<String> savedPostIds;
  final Set<String> pendingActionIds;
  final ImageProvider? Function(String? path) imageProvider;
  final Future<void> Function(Map<String, dynamic> post) onLike;
  final Future<void> Function(Map<String, dynamic> post) onRepost;
  final Future<void> Function(Map<String, dynamic> post) onSave;
  final void Function(Map<String, dynamic> post) onOptions;
  final Future<void> Function() onRefresh;

  const _ProfilePostsList({
    required this.items,
    required this.emptyText,
    required this.isDark,
    required this.imageProvider,
    required this.displayName,
    required this.username,
    required this.avatarPath,
    required this.verified,
    required this.subscriptionTier,
    required this.likedPostIds,
    required this.repostedPostIds,
    required this.savedPostIds,
    required this.pendingActionIds,
    required this.onLike,
    required this.onRepost,
    required this.onSave,
    required this.onOptions,
    required this.onRefresh,
    this.mediaOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return RefreshIndicator(
        color: AppColors.purple,
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: 220, child: Center(child: AppText(emptyText, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w900)))),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: AppColors.purple,
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.purple.withValues(alpha: .10)),
        itemBuilder: (context, index) {
          final p = items[index];
          final id = (p['id'] ?? '').toString();
          return _ProfileTweetCard(
            post: p,
            isDark: isDark,
            mediaOnly: mediaOnly,
            displayName: (p['name'] ?? p['user'] ?? displayName).toString(),
            username: SupabaseService.displayUsername((p['username'] ?? username).toString()),
            avatarPath: (p['avatar_url'] ?? p['avatarPath'] ?? avatarPath ?? '').toString(),
            verified: verified || p['author_verified'] == true || p['author_verified']?.toString() == 'true',
            subscriptionTier: (p['author_subscription_tier'] ?? p['subscriptionTier'] ?? p['subscription_tier'] ?? subscriptionTier).toString(),
            liked: likedPostIds.contains(id) || p['isLiked'] == true || p['is_liked'] == true,
            reposted: repostedPostIds.contains(id) || p['isReposted'] == true || p['is_reposted'] == true,
            saved: savedPostIds.contains(id) || p['isSaved'] == true || p['is_saved'] == true,
            busy: pendingActionIds.any((e) => e.endsWith('_$id')),
            imageProvider: imageProvider,
            onLike: () => onLike(p),
            onRepost: () => onRepost(p),
            onSave: () => onSave(p),
            onOptions: () => onOptions(p),
          );
        },
      ),
    );
  }
}

class _ProfileTweetCard extends StatelessWidget {
  final Map<String, dynamic> post;
  final bool isDark;
  final bool mediaOnly;
  final String displayName;
  final String username;
  final String? avatarPath;
  final bool verified;
  final String subscriptionTier;
  final bool liked;
  final bool reposted;
  final bool saved;
  final bool busy;
  final ImageProvider? Function(String? path) imageProvider;
  final VoidCallback onLike;
  final VoidCallback onRepost;
  final VoidCallback onSave;
  final VoidCallback onOptions;

  const _ProfileTweetCard({
    required this.post,
    required this.isDark,
    required this.mediaOnly,
    required this.displayName,
    required this.username,
    required this.avatarPath,
    required this.verified,
    required this.subscriptionTier,
    required this.liked,
    required this.reposted,
    required this.saved,
    required this.busy,
    required this.imageProvider,
    required this.onLike,
    required this.onRepost,
    required this.onSave,
    required this.onOptions,
  });

  int _int(dynamic value) => int.tryParse((value ?? '0').toString()) ?? 0;

  String _timeLabel() {
    final raw = (post['created_at'] ?? post['time'] ?? '').toString();
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return raw;
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'قبل ${diff.inMinutes}د';
    if (diff.inHours < 24) return 'قبل ${diff.inHours}س';
    if (diff.inDays < 7) return 'قبل ${diff.inDays}ي';
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }

  String _mediaUrl(bool video) {
    if (video) return (post['video_url'] ?? post['videoUrl'] ?? '').toString().trim();
    final image = (post['image_url'] ?? post['imageUrl'] ?? '').toString().trim();
    if (image.isNotEmpty) return image;
    final mediaPath = (post['mediaPath'] ?? '').toString().trim();
    final mediaType = (post['mediaType'] ?? '').toString().toLowerCase();
    if (mediaPath.isNotEmpty && !mediaType.contains('video')) return mediaPath;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final text = (post['text'] ?? '').toString().trim();
    final image = _mediaUrl(false);
    final video = _mediaUrl(true);
    final avatar = imageProvider(avatarPath);
    final mediaProvider = imageProvider(image);
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    final hasMedia = image.isNotEmpty || video.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 12),
      color: Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: AppColors.purple,
            backgroundImage: avatar,
            child: avatar == null ? const Icon(Icons.person_rounded, color: Colors.white) : null,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: AppText(displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15.5)),
                    ),
                    if (verified || subscriptionTier != 'free') _RespectAiVerifiedBadge(tier: subscriptionTier == 'free' ? 'premium' : subscriptionTier),
                    const SizedBox(width: 4),
                    Flexible(child: AppText('$username · ${_timeLabel()}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted, fontWeight: FontWeight.w600, fontSize: 12.2))),
                    IconButton(onPressed: onOptions, icon: Icon(Icons.more_horiz_rounded, color: muted), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 34, minHeight: 34)),
                  ],
                ),
                if (!mediaOnly && text.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  _LinkifiedText(text, style: const TextStyle(fontWeight: FontWeight.w600, height: 1.45, fontSize: 15)),
                ],
                if (hasMedia) ...[
                  SizedBox(height: text.isNotEmpty && !mediaOnly ? 10 : 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      height: mediaOnly ? 230 : 190,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.purple.withValues(alpha: .10),
                        border: Border.all(color: AppColors.purple.withValues(alpha: .14)),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: image.isNotEmpty && mediaProvider != null
                          ? Image(image: mediaProvider, fit: BoxFit.cover)
                          : Center(child: Icon(video.isNotEmpty ? Icons.play_circle_fill_rounded : Icons.image_rounded, color: AppColors.purple, size: 52)),
                    ),
                  ),
                ],
                if (text.isEmpty && !hasMedia)
                  AppText('تغريدة بدون محتوى', style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _TweetAction(icon: Icons.chat_bubble_outline_rounded, value: _int(post['reply_count'] ?? post['comments']), color: muted),
                    _TweetAction(icon: reposted ? Icons.repeat_on_rounded : Icons.repeat_rounded, value: _int(post['reposts']), color: reposted ? AppColors.success : muted, onTap: busy ? null : onRepost),
                    _TweetAction(icon: liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, value: _int(post['likes']), color: liked ? Colors.pinkAccent : muted, onTap: busy ? null : onLike),
                    _TweetAction(icon: saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded, value: 0, color: saved ? AppColors.purple : muted, onTap: busy ? null : onSave, hideZero: true),
                    _TweetAction(icon: Icons.visibility_outlined, value: _int(post['views']), color: muted),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


class _LinkifiedText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  const _LinkifiedText(
      this.text, {
        this.style,
        this.maxLines,
        this.overflow,
        this.textAlign,
      });

  // نفس منطق الفيد: روابط + هاشتاقات قابلة للضغط.
  // الهاشتاق يدعم العربي والإنجليزي والأرقام والشرطة السفلية، مثل: #Respect أو #ريسبكت_لايف
  static final RegExp _tokenRegex = RegExp(
    r'(https?:\/\/[^\s]+|www\.[^\s]+|#[^\s#@]+)',
    caseSensitive: false,
  );

  bool _isUrl(String value) {
    final v = value.toLowerCase();
    return v.startsWith('http://') || v.startsWith('https://') || v.startsWith('www.');
  }

  String _stripTrailingUrlPunctuation(String value) {
    var v = value;
    while (v.isNotEmpty && RegExp(r'[\.,،؛:!؟\)\]\}]$').hasMatch(v)) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  String _stripTrailingHashtagPunctuation(String value) {
    var v = value.trim();
    while (v.isNotEmpty && RegExp(r'[\.,،؛:!؟\)\]\}]$').hasMatch(v)) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  Future<void> _openUrl(BuildContext context, String rawUrl) async {
    final clean = _stripTrailingUrlPunctuation(rawUrl.trim());
    if (clean.isEmpty) return;
    final normalized = clean.startsWith('http://') || clean.startsWith('https://') ? clean : 'https://$clean';
    final uri = Uri.tryParse(normalized);
    if (uri == null) return;

    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        await Clipboard.setData(ClipboardData(text: normalized));
        NotificationService.showTopError(context.tr('تعذر فتح الرابط، تم نسخه بدلًا من ذلك'));
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: normalized));
      NotificationService.showTopError(context.tr('تعذر فتح الرابط، تم نسخه بدلًا من ذلك'));
    }
  }

  Future<void> _openHashtag(BuildContext context, String rawHashtag) async {
    final hashtag = _stripTrailingHashtagPunctuation(rawHashtag);
    if (hashtag.length <= 1 || !hashtag.startsWith('#')) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HashtagPostsScreen(hashtag: hashtag),
      ),
    );
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

      final original = match.group(0)!;
      if (_isUrl(original)) {
        final clean = _stripTrailingUrlPunctuation(original);
        final trailing = clean.length < original.length ? original.substring(clean.length) : '';
        spans.add(TextSpan(
          text: clean,
          recognizer: TapGestureRecognizer()..onTap = () => _openUrl(context, clean),
          style: const TextStyle(
            color: Colors.blueAccent,
            fontWeight: FontWeight.w800,
            decoration: TextDecoration.underline,
            decorationColor: Colors.blueAccent,
          ),
        ));
        if (trailing.isNotEmpty) spans.add(TextSpan(text: trailing));
      } else if (original.startsWith('#')) {
        final hashtag = _stripTrailingHashtagPunctuation(original);
        final trailing = hashtag.length < original.length ? original.substring(hashtag.length) : '';
        spans.add(TextSpan(
          text: hashtag,
          recognizer: TapGestureRecognizer()..onTap = () => _openHashtag(context, hashtag),
          style: const TextStyle(
            color: AppColors.purple,
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.none,
          ),
        ));
        if (trailing.isNotEmpty) spans.add(TextSpan(text: trailing));
      } else {
        spans.add(TextSpan(text: original));
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

class _TweetAction extends StatelessWidget {
  final IconData icon;
  final int value;
  final Color color;
  final VoidCallback? onTap;
  final bool hideZero;

  const _TweetAction({required this.icon, required this.value, required this.color, this.onTap, this.hideZero = false});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              if (!(hideZero && value == 0)) ...[
                const SizedBox(width: 4),
                AppText(_compact(value), style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(n % 1000000 == 0 ? 0 : 1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}K';
    return '$n';
  }
}

class _ProfileRepliesList extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final bool isDark;
  final ImageProvider? Function(String? path) imageProvider;

  const _ProfileRepliesList({required this.items, required this.isDark, required this.imageProvider});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(child: AppText('لا توجد ردود بعد', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w900)));
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.purple.withValues(alpha: .10)),
      itemBuilder: (context, index) {
        final r = items[index];
        final text = (r['text'] ?? '').toString();
        final postText = (r['postText'] ?? '').toString();
        final postUser = (r['postUser'] ?? '').toString();
        final avatar = imageProvider((r['avatarPath'] ?? r['author_avatar_url'] ?? '').toString());
        final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
        return Container(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.purple,
                backgroundImage: avatar,
                child: avatar == null ? const Icon(Icons.reply_rounded, color: Colors.white, size: 20) : null,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _LinkifiedText(text.isEmpty ? 'رد بدون نص' : text, style: const TextStyle(fontWeight: FontWeight.w800, height: 1.45, fontSize: 15)),
                    if (postText.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.purple.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.purple.withValues(alpha: 0.16)),
                        ),
                        child: _LinkifiedText('ردًا على ${postUser.isEmpty ? 'منشور' : postUser}: $postText', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted, fontSize: 12, height: 1.35, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}



class _VerificationPowerCard extends StatelessWidget {
  final String tier;
  final String description;
  final Map<String, int> analytics;

  const _VerificationPowerCard({required this.tier, required this.description, required this.analytics});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = SupabaseService.tierDisplayName(tier);
    final pinLimit = tier == 'premium' ? 3 : tier == 'gold' ? 2 : 1;
    final views = analytics['views'] ?? 0;
    final engagement = analytics['engagement'] ?? 0;
    final colors = tier == 'premium'
        ? const [Color(0xFF5B21B6), Color(0xFFE879F9), Color(0xFF22D3EE)]
        : tier == 'gold'
            ? const [Color(0xFF92400E), Color(0xFFF59E0B), Color(0xFFFDE68A)]
            : const [Color(0xFF475569), Color(0xFFCBD5E1), Color(0xFF94A3B8)];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(colors: colors.map((c) => c.withValues(alpha: isDark ? .22 : .16)).toList()),
        border: Border.all(color: colors.first.withValues(alpha: .35)),
        boxShadow: [BoxShadow(color: colors.first.withValues(alpha: .14), blurRadius: 22)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _RespectAiVerifiedBadge(tier: tier, large: true),
            const SizedBox(width: 8),
            Expanded(child: AppText('قوة التوثيق $title', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15.5))),
            Icon(tier == 'premium' ? Icons.diamond_rounded : tier == 'gold' ? Icons.workspace_premium_rounded : Icons.star_rounded, color: colors.first),
          ]),
          const SizedBox(height: 8),
          AppText(description, style: TextStyle(color: isDark ? Colors.white70 : const Color(0xFF4B4455), fontWeight: FontWeight.w800, height: 1.35, fontSize: 12.5)),
          const SizedBox(height: 10),
          Wrap(spacing: 7, runSpacing: 7, children: [
            _PowerMiniPill(icon: Icons.push_pin_rounded, text: '$pinLimit تثبيت'),
            _PowerMiniPill(icon: Icons.visibility_rounded, text: '$views مشاهدة'),
            _PowerMiniPill(icon: Icons.bolt_rounded, text: '$engagement تفاعل'),
            if (tier == 'gold' || tier == 'premium') const _PowerMiniPill(icon: Icons.analytics_rounded, text: 'إحصائيات'),
            if (tier == 'premium') const _PowerMiniPill(icon: Icons.explore_rounded, text: 'قسم المميزين'),
          ]),
        ],
      ),
    );
  }
}

class _PowerMiniPill extends StatelessWidget {
  final IconData icon;
  final String text;
  const _PowerMiniPill({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .12), borderRadius: BorderRadius.circular(999)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, color: AppColors.purple, size: 15), const SizedBox(width: 4), AppText(text, style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900, fontSize: 11.5))]),
  );
}

class _RespectAiVerifiedBadge extends StatelessWidget {
  final String tier;
  final bool large;

  const _RespectAiVerifiedBadge({
    this.tier = 'premium',
    this.large = false,
  });

  static String normalizeTier(String value) {
    final v = value.trim().toLowerCase();
    if (v == 'premium' || v == 'gold' || v == 'silver') return v;
    return 'premium';
  }

  static List<Color> gradientForTier(String value) {
    final v = normalizeTier(value);
    if (v == 'premium') {
      return const [Color(0xFF5B21B6), Color(0xFFE879F9), Color(0xFF22D3EE)];
    }
    if (v == 'gold') {
      return const [Color(0xFF92400E), Color(0xFFF59E0B), Color(0xFFFDE68A)];
    }
    return const [Color(0xFF475569), Color(0xFFCBD5E1), Color(0xFF94A3B8)];
  }

  static Color accentForTier(String value) {
    final v = normalizeTier(value);
    if (v == 'premium') return const Color(0xFFC084FC);
    if (v == 'gold') return const Color(0xFFF59E0B);
    return const Color(0xFF94A3B8);
  }

  static IconData iconForTier(String value) {
    final v = normalizeTier(value);
    if (v == 'premium') return Icons.diamond_rounded;
    if (v == 'gold') return Icons.workspace_premium_rounded;
    return Icons.star_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final normalized = normalizeTier(tier);
    final accent = accentForTier(normalized);
    final size = large ? 18.0 : 12.0;
    final padding = large ? 3.8 : 2.3;

    return Container(
      margin: EdgeInsetsDirectional.only(start: large ? 7 : 5),
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: gradientForTier(normalized),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white.withValues(alpha: .72), width: large ? 1.2 : .8),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: normalized == 'premium' ? .52 : .42),
            blurRadius: large ? 16 : 9,
            spreadRadius: normalized == 'premium' ? 1.1 : .4,
          ),
        ],
      ),
      child: Icon(
        normalized == 'silver' ? Icons.check_rounded : iconForTier(normalized),
        color: Colors.white,
        size: size,
      ),
    );
  }
}

class _SubscriptionTierMiniBadge extends StatelessWidget {
  final String tier;

  const _SubscriptionTierMiniBadge({required this.tier});

  String get _label {
    final t = tier.trim().toLowerCase();
    if (t == 'premium') return 'مميزة';
    if (t == 'gold') return 'ذهبية';
    if (t == 'silver') return 'فضية';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    if (_label.isEmpty) return const SizedBox.shrink();
    final normalized = _RespectAiVerifiedBadge.normalizeTier(tier);
    final accent = _RespectAiVerifiedBadge.accentForTier(normalized);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: isDark ? .20 : .12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: .38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_RespectAiVerifiedBadge.iconForTier(normalized), color: accent, size: 13),
          const SizedBox(width: 4),
          AppText(_label, style: TextStyle(color: accent, fontWeight: FontWeight.w900, fontSize: 11)),
        ],
      ),
    );
  }
}

bool _isRespectAiUsername(String username) {
  return SupabaseService.displayUsername(username) == SupabaseService.respectAiUsername;
}

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _StatBox({
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final card = Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: onTap == null
              ? Colors.transparent
              : AppColors.purple.withValues(alpha: 0.22),
        ),
      ),
      child: Column(children: [
        AppText(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
        AppText(
          label,
          style: TextStyle(
            color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
            fontSize: 12,
          ),
        ),
      ]),
    );

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: card,
        ),
      ),
    );
  }
}


class _PaddleCheckoutWebViewScreen extends StatefulWidget {
  final String checkoutUrl;
  final String title;

  const _PaddleCheckoutWebViewScreen({
    required this.checkoutUrl,
    this.title = 'الدفع',
  });

  @override
  State<_PaddleCheckoutWebViewScreen> createState() => _PaddleCheckoutWebViewScreenState();
}

class _PaddleCheckoutWebViewScreenState extends State<_PaddleCheckoutWebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _paidSignalSeen = false;
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.checkoutUrl;

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _currentUrl = url;
            });
            _handleCheckoutUrl(url);
          },
          onPageFinished: (url) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _currentUrl = url;
            });
            _handleCheckoutUrl(url);
          },
          onNavigationRequest: (request) {
            final url = request.url.trim();
            if (url.isEmpty) return NavigationDecision.prevent;

            final lower = url.toLowerCase();

            // روابط غير الويب مثل تطبيق بنك / محفظة / tel / mailto
            // نفتحها خارج WebView فقط لأنها لا تعمل داخل WebView.
            if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
              unawaited(_openExternalIfNeeded(url));
              return NavigationDecision.prevent;
            }

            _handleCheckoutUrl(url);
            return NavigationDecision.navigate;
          },
          onWebResourceError: (_) {
            if (!mounted) return;
            setState(() => _loading = false);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.checkoutUrl));
  }

  bool _looksLikePaymentSuccess(String url) {
    final lower = url.toLowerCase();

    return lower.contains('checkout=success') ||
        lower.contains('payment=success') ||
        lower.contains('status=success') ||
        lower.contains('paddle_success') ||
        lower.contains('/success') ||
        lower.contains('success=true') ||
        lower.contains('paid=true') ||
        lower.contains('payment_success') ||
        lower.contains('verification_success');
  }

  bool _looksLikePaymentCancel(String url) {
    final lower = url.toLowerCase();

    return lower.contains('checkout=cancel') ||
        lower.contains('payment=cancel') ||
        lower.contains('status=cancel') ||
        lower.contains('/cancel') ||
        lower.contains('cancel=true') ||
        lower.contains('payment_cancel') ||
        lower.contains('verification_cancel');
  }

  void _handleCheckoutUrl(String url) {
    if (_paidSignalSeen || !mounted) return;

    if (_looksLikePaymentSuccess(url)) {
      _paidSignalSeen = true;
      Navigator.of(context).pop(true);
      return;
    }

    if (_looksLikePaymentCancel(url)) {
      Navigator.of(context).pop(false);
    }
  }

  Future<void> _openExternalIfNeeded(String url) async {
    try {
      final uri = Uri.parse(url);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      _scannerSafeIgnore();
    }
  }

  Future<bool> _confirmClose() async {
    if (_paidSignalSeen) return true;

    final close = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const AppText('إغلاق صفحة الدفع؟', style: TextStyle(fontWeight: FontWeight.w900)),
        content: const AppText(
          'إذا أغلقت الصفحة قبل إكمال الدفع لن يتم تفعيل الاشتراك. إذا أكملت الدفع فعلًا، سيقوم التطبيق بتحديث الحالة تلقائيًا.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const AppText('متابعة الدفع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.purple),
            child: const AppText('إغلاق'),
          ),
        ],
      ),
    );

    return close == true;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return WillPopScope(
      onWillPop: () async {
        final close = await _confirmClose();
        if (close && mounted) Navigator.of(context).pop(_paidSignalSeen);
        return false;
      },
      child: Scaffold(
        backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
        appBar: AppBar(
          elevation: 0,
          backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
          foregroundColor: isDark ? Colors.white : const Color(0xFF201726),
          title: AppText(widget.title, style: const TextStyle(fontWeight: FontWeight.w900)),
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () async {
              final close = await _confirmClose();
              if (close && mounted) Navigator.of(context).pop(_paidSignalSeen);
            },
          ),
          actions: [
            IconButton(
              tooltip: context.tr('تحديث'),
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => _controller.reload(),
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_loading)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    color: AppColors.purple,
                    backgroundColor: AppColors.purple.withValues(alpha: .12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
