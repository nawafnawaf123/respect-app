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

import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/primary_button.dart';
import '../services/supabase_service.dart';
import '../services/notification_service.dart';

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

  @override
  void initState() {
    super.initState();
    _loadProfile().then((_) {
      if (!mounted) return;
      _loadProfileContent();
      _refreshSavedStream(silent: true);
      _streamRefreshTimer = Timer.periodic(const Duration(seconds: 25), (_) {
        if (mounted) _refreshSavedStream(silent: true);
      });
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
      } catch (_) {}
    }

    await patchListKey(_postsKey);
    await patchListKey('respect_local_quote_posts_v1');
  }

  Future<void> _syncProfileAvatarToServer(String username, String? avatarUrl) async {
    final url = avatarUrl?.trim();
    if (url == null || url.isEmpty) return;
    try {
      await SupabaseService.updateUserAvatar(username: username, avatarUrl: url);
    } catch (_) {}
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
        } catch (_) {}
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
      } catch (_) {}
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
      } catch (_) {}
    }

    if (!mounted) return;
    _currentId = id;
    _nameCtrl.text = (account['profileName'] ?? account['name'] ?? 'Nawaf RP').toString();
    _usernameCtrl.text = (account['username'] ?? id ?? '@nawaf_city').toString();
    _bioCtrl.text = (account['bio'] ?? 'لاعب ومتابع لمجتمع Respect App').toString();
    _locationCtrl.text = (account['location'] ?? 'Respect City').toString();
    _websiteCtrl.text = (account['website'] ?? '').toString();
    _streamUrlCtrl.text = (account['streamUrl'] ?? '').toString();
    _streamerNameCtrl.text = (account['streamName'] ?? account['streamerName'] ?? '').toString();
    _streamTitleCtrl.text = (account['streamTitle'] ?? '').toString();
    _streamViewersCtrl.text = (account['streamViewers'] ?? '0').toString();
    setState(() {
      final accountSafeId = _safeFileId(id ?? _usernameCtrl.text);
      // نفضّل رابط السيرفر حتى تظهر الصورة من كل الأجهزة، ونبقي المحلي كاحتياط.
      _profileImagePath = (account['avatar_url'] ??
          account['profileImagePath'] ??
          account['localAvatarPath_$accountSafeId'] ??
          account['imagePath'])
          ?.toString();
      _coverPath = (account['cover_url'] ?? account['coverPath'] ?? account['localCoverPath_$accountSafeId'])?.toString();
      _streamThumbnailPath = (account['streamThumbnailPath'] ?? account['streamThumbnailUrl'])?.toString();
      _streamIsLive = account['streamIsLive'] == true || account['streamIsLive']?.toString() == 'true';
      _profileVerified = SupabaseService.isVerifiedUser(account);
      _verifiedUntil = SupabaseService.verifiedUntilForUser(account);
      _loading = false;
      _following = loadedFollowing;
      _postsCount = loadedPostsCount;
    });
    try {
      final warnings = await SupabaseService.activeWarningCount(_cleanUsername(_usernameCtrl.text));
      if (mounted) setState(() => _activeWarnings = warnings);
    } catch (_) {}
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
      } catch (_) {}
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
    } catch (_) {}

    Set<String> likedIds = <String>{};
    Set<String> repostedIds = <String>{};
    Set<String> savedIds = <String>{};
    try { likedIds = await SupabaseService.getUserLikedPostIds(username); } catch (_) {}
    try { repostedIds = await SupabaseService.getUserRepostedPostIds(username); } catch (_) {}
    try { savedIds = await SupabaseService.getUserSavedPostIds(username); } catch (_) {}

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
    } catch (_) {}

    try {
      followers = await SupabaseService.getUserFollowers(username);
    } catch (_) {}
    try {
      following = await SupabaseService.getUserFollowing(username);
    } catch (_) {}

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
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: users.isEmpty
                        ? Center(child: Text('لا توجد حسابات هنا', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)))
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
                                child: avatar == null ? Text(name.isNotEmpty ? name.characters.first.toUpperCase() : '?', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)) : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                                    const SizedBox(height: 2),
                                    Text(username, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700)),
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
        return StatefulBuilder(
          builder: (context, setSheet) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: Container(
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(child: Container(width: 46, height: 5, decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .55), borderRadius: BorderRadius.circular(99)))),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .15), shape: BoxShape.circle),
                            child: const Icon(Icons.verified_rounded, color: AppColors.purple),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('توثيق حساب Respect', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'التوثيق يفتح الستوري، علامة التوثيق، 2000 حرف للتغريدة، و 50 رد Respect AI يوميًا.',
                        style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, height: 1.45, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 14),
                      ...SupabaseService.verificationPlans.map((plan) {
                        final id = (plan['id'] ?? '').toString();
                        final title = (plan['title'] ?? '').toString();
                        final months = (plan['months'] ?? 1).toString();
                        final price = double.tryParse((plan['price'] ?? 0).toString()) ?? 0;
                        final badge = (plan['badge'] ?? '').toString();
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white.withValues(alpha: .04) : Colors.white.withValues(alpha: .78),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.purple.withValues(alpha: .20)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFFC084FC)]),
                                  boxShadow: [BoxShadow(color: AppColors.purple.withValues(alpha: .28), blurRadius: 14)],
                                ),
                                child: const Icon(Icons.workspace_premium_rounded, color: Colors.white),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                                    const SizedBox(height: 3),
                                    Text('$months شهر • $badge', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: _activatingVerification
                                    ? null
                                    : () async {
                                  setSheet(() => _activatingVerification = true);
                                  await _activateVerificationPlan(id);
                                  if (mounted && Navigator.canPop(context)) Navigator.pop(context);
                                },
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.purple,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                                ),
                                child: Text('\$${price.toStringAsFixed(price.truncateToDouble() == price ? 0 : 2)}', style: const TextStyle(fontWeight: FontWeight.w900)),
                              ),
                            ],
                          ),
                        );
                      }),
                      const SizedBox(height: 4),
                      Text(
                        'ملاحظة: الزر الحالي يفعّل الاشتراك داخل قاعدة البيانات مباشرة. لاحقًا اربطه ببوابة دفع حقيقية قبل إطلاق التطبيق.',
                        style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontSize: 12, height: 1.35),
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
    if (mounted) setState(() => _activatingVerification = false);
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
      NotificationService.showTopNotification('تم توثيق الحساب بنجاح حتى ${_formatVerifiedUntil(_verifiedUntil)}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _activatingVerification = false);
      NotificationService.showTopError('تعذر تفعيل التوثيق: $e');
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
    } catch (_) {}
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
                    Expanded(child: Text('أضف عناصر للستوري', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900))),
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
                      label: const Text('نشر العناصر المختارة', style: TextStyle(fontWeight: FontWeight.w900)),
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
      NotificationService.showTopNotification('الستوري متاحة للحسابات الموثقة فقط');
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
          title: const Text('إضافة عنصر آخر؟', style: TextStyle(fontWeight: FontWeight.w900)),
          content: Text('تم اختيار ${items.length} عنصر. تقدر تضيف صور أو فيديوهات زيادة قبل النشر.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('نشر الآن')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إضافة المزيد')),
          ],
        ),
      );

      if (keepAdding != true) break;
    }

    if (items.isEmpty) return;
    setState(() => _loadingStory = true);
    try {
      await SupabaseService.addStoryMediaItems(
        username: _cleanUsername(_usernameCtrl.text),
        name: _nameCtrl.text.trim().isEmpty ? _cleanUsername(_usernameCtrl.text) : _nameCtrl.text.trim(),
        mediaItems: items,
        avatarUrl: _profileImagePath ?? '',
      );
      await _refreshMyStories();
      if (!mounted) return;
      NotificationService.showTopNotification('تم نشر ${items.length} عنصر في الستوري لمدة 24 ساعة');
    } catch (e) {
      if (mounted) NotificationService.showTopError('تعذر نشر الستوري: $e');
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
      if (mounted) NotificationService.showTopError('تعذر تحديث الإعجاب: $e');
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
      if (mounted) NotificationService.showTopError('تعذر تحديث إعادة النشر: $e');
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
      if (mounted) NotificationService.showTopError('تعذر تحديث الحفظ: $e');
    } finally {
      if (mounted) setState(() => _pendingPostActionIds.remove('save_$id'));
    }
  }

  Future<void> _copyPostText(Map<String, dynamic> post) async {
    final text = _postText(post).trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) NotificationService.showTopNotification('تم نسخ نص التغريدة');
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
                  const Text('تعديل التغريدة', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    minLines: 4,
                    maxLines: 8,
                    maxLength: _profileVerified ? SupabaseService.verifiedPostMaxChars : SupabaseService.freePostMaxChars,
                    decoration: InputDecoration(
                      hintText: 'اكتب التعديل هنا...',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                      icon: const Icon(Icons.save_rounded),
                      label: const Text('حفظ التعديل', style: TextStyle(fontWeight: FontWeight.w900)),
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
      NotificationService.showTopNotification('تم تعديل التغريدة');
    } catch (e) {
      if (mounted) NotificationService.showTopError('تعذر تعديل التغريدة: $e');
    }
  }

  Future<void> _deletePostFromProfile(Map<String, dynamic> post) async {
    final id = _postId(post);
    if (id.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف التغريدة؟'),
        content: const Text('سيتم حذف التغريدة وتفاعلاتها وردودها. لا يمكن التراجع عن هذا الإجراء.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), style: FilledButton.styleFrom(backgroundColor: Colors.red), child: const Text('حذف')),
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
      NotificationService.showTopNotification('تم حذف التغريدة');
    } catch (e) {
      if (mounted) NotificationService.showTopError('تعذر حذف التغريدة: $e');
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
                  title: const Text('تعديل التغريدة', style: TextStyle(fontWeight: FontWeight.w900)),
                  onTap: () { Navigator.pop(context); _editPost(post); },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded, color: AppColors.purple),
                  title: const Text('نسخ النص', style: TextStyle(fontWeight: FontWeight.w900)),
                  onTap: () { Navigator.pop(context); _copyPostText(post); },
                ),
                ListTile(
                  leading: Icon(_savedPostIds.contains(_postId(post)) ? Icons.bookmark_remove_rounded : Icons.bookmark_add_rounded, color: AppColors.purple),
                  title: Text(_savedPostIds.contains(_postId(post)) ? 'إزالة من الحفظ' : 'حفظ التغريدة', style: const TextStyle(fontWeight: FontWeight.w900)),
                  onTap: () { Navigator.pop(context); _toggleSavePost(post); },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_rounded, color: Colors.red),
                  title: const Text('حذف التغريدة', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.red)),
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
    if (mounted) NotificationService.showTopNotification('تم تحديث الملف الشخصي');
  }

  Future<void> _saveProfile() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _checkingStream = _streamUrlCtrl.text.trim().isNotEmpty;
    });

    final name = _nameCtrl.text.trim().isEmpty ? 'Nawaf RP' : _nameCtrl.text.trim();
    final username = _cleanUsername(_usernameCtrl.text);
    final streamUrl = _cleanStreamUrl(_streamUrlCtrl.text);
    final metadata =
    streamUrl.isEmpty ? _StreamMetadata.empty() : await _fetchStreamMetadata(streamUrl, fallbackName: name);
    final cachedThumbnailPath = metadata.thumbnailUrl.trim().isEmpty
        ? ''
        : await _cacheBestStreamThumbnail(metadata.thumbnailUrl,
        platform: metadata.platform, channel: _channelFromUrl(streamUrl));
    final finalThumbnailPath = _safeStreamThumbnailValue(
      cachedPath: cachedThumbnailPath,
      remoteUrl: metadata.thumbnailUrl,
      previousValue: _streamThumbnailPath,
    );

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
      } catch (_) {}
    }

    if (pendingCover != null && pendingCover.trim().isNotEmpty) {
      profileUpdates['coverPath'] = pendingCover;
      try {
        final coverUrl = await SupabaseService.uploadProfileCover(
          username: username,
          filePath: pendingCover,
        );
        profileUpdates['cover_url'] = coverUrl;
      } catch (_) {}
    }

    await _updateAccount({
      'profileName': name,
      'username': username,
      'bio': _bioCtrl.text.trim(),
      'location': _locationCtrl.text.trim(),
      'website': _websiteCtrl.text.trim(),
      'streamUrl': streamUrl,
      'streamName':
      metadata.channelName.isNotEmpty ? metadata.channelName : _streamerNameCtrl.text.trim(),
      'streamTitle': metadata.title,
      'streamIsLive': metadata.isLive,
      'streamViewers': metadata.viewers,
      'streamThumbnailUrl': metadata.thumbnailUrl,
      'streamThumbnailPath': finalThumbnailPath,
      'streamPlatform': metadata.platform,
      'streamLastCheckedAt': DateTime.now().toIso8601String(),
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
    } catch (_) {}

    if (!mounted) return;
    _usernameCtrl.text = username;
    _streamUrlCtrl.text = streamUrl;
    _streamerNameCtrl.text =
    metadata.channelName.isNotEmpty ? metadata.channelName : _streamerNameCtrl.text.trim();
    _streamTitleCtrl.text = metadata.title;
    _streamViewersCtrl.text = metadata.viewers.toString();
    setState(() {
      _streamIsLive = metadata.isLive;
      _streamThumbnailPath = finalThumbnailPath;
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
      _checkingStream = false;
    });
    await _loadProfileContent();
    NotificationService.showTopNotification(streamUrl.isEmpty
        ? 'تم حفظ بيانات البروفايل'
        : 'تم فحص رابط البث وحفظ البيانات تلقائيًا');
  }

  int _followersCount(String username) {
    return _following.values.where((list) => list.contains(username)).length;
  }

  int _followingCount(String username) {
    return (_following[username] ?? const <String>[]).length;
  }

  @override
  Widget build(BuildContext context) {
    // Premium profile layout: improved cover, avatar, stats card, tabs height without duplicating the file.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final profileImage = _fileImage(_pendingProfileImagePath ?? _profileImagePath);
    final coverImage = _fileImage(_pendingCoverPath ?? _coverPath);
    final streamThumbnail = _streamThumbnailPath;

    return Scaffold(
      appBar: null,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.purple))
          : ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 26),
        children: [
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    InkWell(
                      onTap: _editing ? () => _pickImage(cover: true) : null,
                      child: Container(
                        height: 178,
                        decoration: BoxDecoration(
                          borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(30)),
                          gradient: const LinearGradient(
                              begin: Alignment.topRight,
                              end: Alignment.bottomLeft,
                              colors: [Color(0xFF160A2E), AppColors.purple, Color(0xFF05040A)]),
                          image: coverImage == null
                              ? null
                              : DecorationImage(image: coverImage, fit: BoxFit.cover),
                        ),
                        child: _editing
                            ? Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: .50),
                                  border: Border.all(color: Colors.white.withValues(alpha: .18)),
                                  borderRadius: BorderRadius.circular(999)),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.image_rounded, color: Colors.white, size: 16),
                                  SizedBox(width: 5),
                                  Text('تغيير الغلاف',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w900)),
                                ],
                              ),
                            ),
                          ),
                        )
                            : Container(
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black.withValues(alpha: .32)],
                            ),
                          ),
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      start: 18,
                      bottom: -54,
                      child: InkWell(
                        onTap: _handleProfileAvatarTap,
                        borderRadius: BorderRadius.circular(99),
                        child: Stack(
                          children: [
                            Container(
                              padding: EdgeInsets.all(_myStories.isNotEmpty ? 3 : 0),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: _myStories.isEmpty
                                    ? null
                                    : (_myStoriesFullySeen
                                    ? const LinearGradient(colors: [Color(0xFF7A7A7A), Color(0xFF4B5563)])
                                    : const LinearGradient(colors: [Color(0xFFFFD166), AppColors.purple, Color(0xFF06D6A0)])),
                              ),
                              child: CircleAvatar(
                                radius: 58,
                                backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
                                child: CircleAvatar(
                                  radius: 51,
                                  backgroundColor: AppColors.purple,
                                  backgroundImage: profileImage,
                                  child: profileImage == null
                                      ? const Icon(Icons.person, color: Colors.white, size: 46)
                                      : null,
                                ),
                              ),
                            ),
                            if (_editing)
                              PositionedDirectional(
                                end: 2,
                                bottom: 2,
                                child: Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: const BoxDecoration(
                                      color: AppColors.purple, shape: BoxShape.circle),
                                  child: const Icon(Icons.camera_alt_rounded,
                                      color: Colors.white, size: 16),
                                ),
                              )
                            else if (_myStories.isNotEmpty)
                              PositionedDirectional(
                                end: 2,
                                bottom: 2,
                                child: Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: BoxDecoration(
                                      color: _myStoriesFullySeen ? Colors.grey.shade700 : AppColors.purple,
                                      shape: BoxShape.circle),
                                  child: const Icon(Icons.play_arrow_rounded,
                                      color: Colors.white, size: 17),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 66),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              _nameCtrl.text.trim().isEmpty ? 'Nawaf RP' : _nameCtrl.text.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: -.4),
                            ),
                          ),
                          if (_isRespectAiUsername(_usernameCtrl.text) || _profileVerified) const _RespectAiVerifiedBadge(),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(_cleanUsername(_usernameCtrl.text),
                          style: TextStyle(
                              color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      Text(
                          _bioCtrl.text.trim().isEmpty
                              ? 'أضف نبذة شخصية ليظهر حسابك بشكل أجمل'
                              : _bioCtrl.text.trim(),
                          style: const TextStyle(height: 1.45)),
                      if (_activeWarnings > 0) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.danger.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded, color: AppColors.danger),
                              const SizedBox(width: 10),
                              Expanded(child: Text('لديك $_activeWarnings تحذير من أصل 3. التحذير يختفي تلقائيًا بعد شهر بدون مخالفات.', style: const TextStyle(fontWeight: FontWeight.w900))),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_locationCtrl.text.trim().isNotEmpty)
                            _InfoChip(
                                icon: Icons.location_on_outlined,
                                text: _locationCtrl.text.trim()),
                          if (_websiteCtrl.text.trim().isNotEmpty)
                            _InfoChip(
                                icon: Icons.link_rounded, text: _websiteCtrl.text.trim()),
                          if (_streamerNameCtrl.text.trim().isNotEmpty)
                            _InfoChip(
                                icon: Icons.live_tv_rounded,
                                text: _streamerNameCtrl.text.trim()),
                          if (_streamUrlCtrl.text.trim().isNotEmpty)
                            _InfoChip(
                                icon: _streamIsLive
                                    ? Icons.radio_button_checked
                                    : Icons.tv_off_rounded,
                                text: _streamIsLive ? 'يبث الآن' : 'قناة محفوظة'),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          gradient: LinearGradient(
                            colors: [
                              AppColors.purple.withValues(alpha: isDark ? .18 : .10),
                              Colors.white.withValues(alpha: isDark ? .04 : .55),
                            ],
                          ),
                          border: Border.all(color: AppColors.purple.withValues(alpha: .12)),
                        ),
                        child: Row(children: [
                          _StatBox(label: 'منشورات', value: '$_postsCount'),
                          const SizedBox(width: 10),
                          _StatBox(
                              label: 'متابعون',
                              value: '${_followersUsers.length}',
                              onTap: () => _showUsersSheet('المتابعون', _followersUsers)),
                          const SizedBox(width: 10),
                          _StatBox(
                              label: 'يتابع',
                              value: '${_followingUsers.length}',
                              onTap: () => _showUsersSheet('يتابع', _followingUsers)),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _activatingVerification ? null : _openVerificationSheet,
                          style: FilledButton.styleFrom(
                            backgroundColor: _profileVerified ? AppColors.purple.withValues(alpha: .14) : AppColors.purple,
                            foregroundColor: _profileVerified ? AppColors.purple : Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                          ),
                          icon: Icon(_profileVerified ? Icons.verified_rounded : Icons.workspace_premium_rounded, size: 18),
                          label: Text(
                            _activatingVerification
                                ? 'جاري التفعيل...'
                                : (_profileVerified ? 'الحساب موثق حتى ${_formatVerifiedUntil(_verifiedUntil)}' : 'توثيق الحساب'),
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _loadingStory ? null : (_profileVerified ? (_myStories.isEmpty ? _pickStory : _openMyStory) : _openVerificationSheet),
                          style: FilledButton.styleFrom(
                            backgroundColor: !_profileVerified
                                ? Colors.grey.withValues(alpha: .16)
                                : (_myStories.isEmpty ? AppColors.purple.withValues(alpha: .16) : AppColors.purple),
                            foregroundColor: !_profileVerified
                                ? (isDark ? AppColors.darkMuted : AppColors.lightMuted)
                                : (_myStories.isEmpty ? AppColors.purple : Colors.white),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                          ),
                          icon: Icon(!_profileVerified ? Icons.lock_rounded : (_myStories.isEmpty ? Icons.add_circle_outline_rounded : Icons.auto_stories_rounded), size: 18),
                          label: Text(
                            _loadingStory
                                ? 'جاري النشر...'
                                : (!_profileVerified ? 'الستوري للحسابات الموثقة فقط' : (_myStories.isEmpty ? 'إضافة ستوري' : 'عرض الستوري / إضافة جديد')),
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(),
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(child: _SectionTitle('الملف الشخصي')),
              FilledButton.icon(
                onPressed: _saving ? null : () async {
                  if (_editing) {
                    await _saveProfile();
                  } else {
                    setState(() => _editing = true);
                  }
                },
                style: FilledButton.styleFrom(
                  backgroundColor: _editing ? AppColors.purple : AppColors.purple.withValues(alpha: 0.18),
                  foregroundColor: _editing ? Colors.white : AppColors.purple,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                ),
                icon: Icon(_editing ? Icons.save_rounded : Icons.edit_rounded, size: 18),
                label: Text(_editing ? 'حفظ' : 'ابدأ التعديل', style: const TextStyle(fontWeight: FontWeight.w900)),
              ),
            ],
          ),
          if (_editing) ...[
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
                    Expanded(child: Text('في صور مختارة تنتظر الحفظ. اضغط حفظ لتطبيق كل التعديلات.', style: TextStyle(fontWeight: FontWeight.w900))),
                  ],
                ),
              ),
            ],
          ],
          const SizedBox(height: 14),
          _ProfileContentTabs(
            loading: _loadingProfileContent,
            posts: _profilePosts,
            media: _profileMedia,
            replies: _profileReplies,
            isDark: isDark,
            imageProvider: _fileImage,
            displayName: _nameCtrl.text.trim().isEmpty ? _cleanUsername(_usernameCtrl.text) : _nameCtrl.text.trim(),
            username: _cleanUsername(_usernameCtrl.text),
            avatarPath: _profileImagePath,
            verified: _profileVerified,
            likedPostIds: _likedPostIds,
            repostedPostIds: _repostedPostIds,
            savedPostIds: _savedPostIds,
            pendingActionIds: _pendingPostActionIds,
            onLike: _toggleLikePost,
            onRepost: _toggleRepostPost,
            onSave: _toggleSavePost,
            onOptions: _openPostOptions,
            onRefresh: _refreshProfileTimeline,
          ),
          const SizedBox(height: 14),
          const _SectionTitle('بيانات البث'),
          const SizedBox(height: 10),
          _ProfileField(
              controller: _streamUrlCtrl,
              icon: Icons.link,
              hint: 'ضع رابط Twitch أو Kick فقط وسيتم جلب البيانات تلقائيًا'),
          const SizedBox(height: 10),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                        _streamIsLive
                            ? Icons.radio_button_checked
                            : Icons.tv_off_rounded,
                        color: _streamIsLive
                            ? AppColors.success
                            : (isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _checkingStream
                            ? 'يتم فحص رابط البث...'
                            : (_streamUrlCtrl.text.trim().isEmpty
                            ? 'أضف رابط البث ثم اضغط حفظ'
                            : (_streamIsLive
                            ? 'البث مباشر الآن'
                            : 'القناة محفوظة / غير مباشر')),
                        style: const TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 16),
                      ),
                    ),
                    if (_checkingStream)
                      const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.purple)),
                  ],
                ),
                const SizedBox(height: 12),
                _AutoStreamPreview(
                  thumbnailUrl: streamThumbnail,
                  title: _streamTitleCtrl.text.trim(),
                  channelName: _streamerNameCtrl.text.trim(),
                  viewers:
                  int.tryParse(_streamViewersCtrl.text.trim().replaceAll(',', '')) ?? 0,
                  isLive: _streamIsLive,
                  isDark: isDark,
                ),
                const SizedBox(height: 10),
                Text(
                  'ملاحظة: البيانات تُجلب تلقائيًا من صفحة الرابط. بعض المنصات قد لا تعرض عدد المشاهدين إلا عبر API رسمي، لذلك يظهر 0 إذا لم يكن الرقم متاحًا في الصفحة.',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                ),
              ],
            ),
          ),
          if (_editing) ...[
            const SizedBox(height: 18),
            PrimaryButton(
                text: _saving ? 'جاري الحفظ...' : 'حفظ بيانات الحساب',
                icon: Icons.save,
                onPressed: _saveProfile)
                .animate()
                .fadeIn(delay: 200.ms),
          ],
        ],
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
    } catch (_) {}
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
    } catch (_) {}
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

  Future<void> _deleteCurrentStoryItem() async {
    if (!widget.ownerMode || _storyId.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('حذف هذا العنصر؟', style: TextStyle(fontWeight: FontWeight.w900)),
        content: const Text('سيتم حذف الصورة أو الفيديو الحالي فقط من الستوري.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف')),
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
        title: const Text('حذف الستوري كامل؟', style: TextStyle(fontWeight: FontWeight.w900)),
        content: const Text('سيتم حذف كل صور وفيديوهات الستوري الحالية.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف الكل')),
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
    if (_isVideo) {
      if (_controller?.value.isInitialized != true) {
        return const Center(child: CircularProgressIndicator(color: AppColors.purple));
      }
      return FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: _controller!.value.size.width,
          height: _controller!.value.size.height,
          child: VideoPlayer(_controller!),
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
                                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15)),
                                    Text(username, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: .65), fontWeight: FontWeight.w700, fontSize: 12)),
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
                                    PopupMenuItem(value: 'delete_item', child: Text('حذف هذا العنصر', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
                                    PopupMenuItem(value: 'delete_all', child: Text('حذف الستوري كامل', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
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
                                  child: Text('$_likes إعجاب · $_comments تعليق', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
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
                                      hintText: 'اكتب تعليق على الستوري...',
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
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        subtitle: Text(subtitle),
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
              const Text('تفاعل الستوري', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
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
          Row(children: [Icon(icon, color: AppColors.purple), const SizedBox(width: 8), Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))]),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(empty, style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700)),
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
                title: Text(textBuilder(row), style: const TextStyle(fontWeight: FontWeight.w900)),
                subtitle: Text(subBuilder(row), maxLines: 2, overflow: TextOverflow.ellipsis),
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
    } catch (_) {}
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
  } catch (_) {}

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
  } catch (_) {}

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
    } catch (_) {}
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
  } catch (_) {}
  try {
    final html = await _readUrl(url);
    final generic = _metadataFromHtml(html, fallbackName: fallbackName, platform: 'YouTube', channel: channelName);
    title = _firstNonEmpty([title, generic.title]);
    thumbnail = _firstNonEmpty([thumbnail, generic.thumbnailUrl]);
    viewers = generic.viewers;
    isLive = generic.isLive;
    channelName = _firstNonEmpty([channelName, generic.channelName, fallbackName]);
  } catch (_) {}
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
  if (_isLocalImagePath(previousValue)) return previousValue!.trim();
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
      } catch (_) {}
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
              child: Text(isLive ? 'LIVE' : 'OFFLINE',
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
                Text(title.isEmpty ? 'سيظهر عنوان البث تلقائيًا هنا' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
                const SizedBox(height: 3),
                Text('${channelName.isEmpty ? 'اسم القناة' : channelName} · $viewers مشاهد',
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
      Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900));
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
        Text(text,
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
    required this.likedPostIds,
    required this.repostedPostIds,
    required this.savedPostIds,
    required this.pendingActionIds,
    required this.onLike,
    required this.onRepost,
    required this.onSave,
    required this.onOptions,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: DefaultTabController(
        length: 3,
        child: SizedBox(
          height: 720,
          child: Column(
            children: [
              Container(
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppColors.purple.withValues(alpha: .12))),
                ),
                child: TabBar(
                  labelColor: AppColors.purple,
                  unselectedLabelColor: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                  indicatorColor: AppColors.purple,
                  indicatorWeight: 4,
                  labelStyle: const TextStyle(fontWeight: FontWeight.w900),
                  tabs: const [
                    Tab(text: 'التغريدات'),
                    Tab(text: 'الوسائط'),
                    Tab(text: 'الردود'),
                  ],
                ),
              ),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator(color: AppColors.purple))
                    : TabBarView(
                  children: [
                    _ProfilePostsList(
                      items: posts,
                      emptyText: 'ما عندك تغريدات بعد',
                      isDark: isDark,
                      imageProvider: imageProvider,
                      displayName: displayName,
                      username: username,
                      avatarPath: avatarPath,
                      verified: verified,
                      likedPostIds: likedPostIds,
                      repostedPostIds: repostedPostIds,
                      savedPostIds: savedPostIds,
                      pendingActionIds: pendingActionIds,
                      onLike: onLike,
                      onRepost: onRepost,
                      onSave: onSave,
                      onOptions: onOptions,
                      onRefresh: onRefresh,
                    ),
                    _ProfilePostsList(
                      items: media,
                      emptyText: 'ما عندك وسائط بعد',
                      isDark: isDark,
                      imageProvider: imageProvider,
                      mediaOnly: true,
                      displayName: displayName,
                      username: username,
                      avatarPath: avatarPath,
                      verified: verified,
                      likedPostIds: likedPostIds,
                      repostedPostIds: repostedPostIds,
                      savedPostIds: savedPostIds,
                      pendingActionIds: pendingActionIds,
                      onLike: onLike,
                      onRepost: onRepost,
                      onSave: onSave,
                      onOptions: onOptions,
                      onRefresh: onRefresh,
                    ),
                    _ProfileRepliesList(items: replies, isDark: isDark, imageProvider: imageProvider),
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

class _ProfilePostsList extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final String emptyText;
  final bool isDark;
  final bool mediaOnly;
  final String displayName;
  final String username;
  final String? avatarPath;
  final bool verified;
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
            SizedBox(height: 220, child: Center(child: Text(emptyText, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w900)))),
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
                      child: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15.5)),
                    ),
                    if (verified) const _RespectAiVerifiedBadge(),
                    const SizedBox(width: 4),
                    Flexible(child: Text('$username · ${_timeLabel()}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted, fontWeight: FontWeight.w600, fontSize: 12.2))),
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
                  Text('تغريدة بدون محتوى', style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
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

  static final RegExp _urlRegex = RegExp(
    r'(https?:\/\/[^\s]+|www\.[^\s]+)',
    caseSensitive: false,
  );

  String _stripTrailingUrlPunctuation(String value) {
    var v = value;
    while (v.isNotEmpty && RegExp(r'[\.,،؛:!؟\)\]\}]$').hasMatch(v)) {
      v = v.substring(0, v.length - 1);
    }
    return v;
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

    for (final match in _urlRegex.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: text.substring(index, match.start)));
      }
      final original = match.group(0)!;
      final clean = _stripTrailingUrlPunctuation(original);
      final trailing = clean.length < original.length ? original.substring(clean.length) : '';
      spans.add(TextSpan(
        text: clean,
        recognizer: TapGestureRecognizer()..onTap = () => _openUrl(clean),
        style: const TextStyle(
          color: Colors.blueAccent,
          fontWeight: FontWeight.w800,
          decoration: TextDecoration.underline,
          decorationColor: Colors.blueAccent,
        ),
      ));
      if (trailing.isNotEmpty) spans.add(TextSpan(text: trailing));
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
                Text(_compact(value), style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
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
      return Center(child: Text('لا توجد ردود بعد', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w900)));
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


class _RespectAiVerifiedBadge extends StatelessWidget {
  const _RespectAiVerifiedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsetsDirectional.only(start: 5),
      padding: const EdgeInsets.all(2.2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFF7C3AED), Color(0xFFC084FC)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [BoxShadow(color: AppColors.purple.withValues(alpha: 0.35), blurRadius: 8)],
      ),
      child: const Icon(Icons.check_rounded, color: Colors.white, size: 12),
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
        Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
        Text(
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