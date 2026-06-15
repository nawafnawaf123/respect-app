import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../services/supabase_service.dart';
import '../services/notification_service.dart';
import 'feed_screen.dart';
import 'chat_screen.dart';

void _scannerSafeIgnore() {}


class SearchScreen extends StatefulWidget {
  final String initialQuery;
  final String initialTimeFilter;

  const SearchScreen({
    super.key,
    this.initialQuery = '',
    this.initialTimeFilter = 'all',
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with SingleTickerProviderStateMixin {
  static const String _accountsKey = 'respect_accounts_v1';
  static const String _usersKey = 'respect_users_map';
  static const String _currentUserKey = 'respect_current_user_id';
  static const String _communitiesKey = 'respect_communities_v1';
  static const String _followingKey = 'respect_following_v1';

  final TextEditingController _searchCtrl = TextEditingController();
  late final TabController _tabController = TabController(length: 3, vsync: this);
  Timer? _searchDebounce;

  String _query = '';
  String _timeFilter = 'today';
  String _currentUsername = '@user';
  String _currentName = 'User';
  String? _currentAvatarPath;

  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _userResults = [];
  List<Map<String, dynamic>> _postResults = [];
  List<Map<String, dynamic>> _trendingHashtags = [];
  List<Map<String, dynamic>> _featuredVerifiedUsers = [];
  bool _searchingUsers = false;
  bool _searchingPosts = false;

  List<CityCommunity> _communities = [];
  Map<String, List<String>> _following = {};
  Set<String> _postNotificationTargets = <String>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery.trim();
    if (initial.isNotEmpty) {
      _query = initial;
      _searchCtrl.text = initial;
      _searchCtrl.selection = TextSelection.collapsed(offset: initial.length);
      _timeFilter = widget.initialTimeFilter.trim().isEmpty ? 'all' : widget.initialTimeFilter.trim();
    }
    _loadData();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  String _cleanUsername(String value) {
    final v = value.trim().replaceAll(RegExp(r'\s+'), '_').replaceAll('@', '').toLowerCase();
    if (v.isEmpty) return '@user';
    return '@$v';
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final currentId = prefs.getString(_currentUserKey) ?? prefs.getString('current_user_id');

    final accounts = <Map<String, dynamic>>[];
    final accountsRaw = prefs.getString(_accountsKey);
    if (accountsRaw != null && accountsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(accountsRaw);
        if (decoded is List) {
          accounts.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (_) { _scannerSafeIgnore(); }
    }

    final usersRaw = prefs.getString(_usersKey);
    if (accounts.isEmpty && usersRaw != null && usersRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(usersRaw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is Map) {
              final item = value.map((k, v) => MapEntry(k.toString(), v));
              accounts.add({
                ...item,
                'id': (item['id'] ?? key).toString(),
                'profileName': (item['profileName'] ?? item['name'] ?? 'User').toString(),
                'username': _cleanUsername((item['username'] ?? key).toString()),
                'imagePath': (item['imagePath'] ?? item['profileImagePath'])?.toString(),
              });
            }
          });
        }
      } catch (_) { _scannerSafeIgnore(); }
    }

    Map<String, dynamic>? current;
    for (final a in accounts) {
      if ((a['id'] ?? '').toString() == currentId || _cleanUsername((a['username'] ?? '').toString()) == _cleanUsername(currentId ?? '')) {
        current = a;
        break;
      }
    }

    final communities = <CityCommunity>[];
    final communitiesRaw = prefs.getString(_communitiesKey);
    if (communitiesRaw != null && communitiesRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(communitiesRaw);
        if (decoded is List) {
          communities.addAll(decoded.whereType<Map>().map((e) => CityCommunity.fromJson(e.map((k, v) => MapEntry(k.toString(), v)))));
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
            if (value is List) following[key.toString()] = value.map((e) => e.toString()).toSet().toList();
          });
        }
      } catch (_) { _scannerSafeIgnore(); }
    }

    try {
      _postNotificationTargets = await SupabaseService.getEnabledPostNotificationTargets(_cleanUsername((current?['username'] ?? currentId ?? '@user').toString()));
    } catch (_) {
      _postNotificationTargets = <String>{};
    }

    List<Map<String, dynamic>> featuredVerified = <Map<String, dynamic>>[];
    try {
      featuredVerified = await SupabaseService.getFeaturedVerifiedUsers(limit: 12);
    } catch (_) { _scannerSafeIgnore(); }

    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _communities = communities;
      _following = following;
      _currentName = (current?['profileName'] ?? current?['name'] ?? 'User').toString();
      _currentUsername = _cleanUsername((current?['username'] ?? currentId ?? '@user').toString());
      _currentAvatarPath = (current?['imagePath'] ?? current?['profileImagePath'] ?? current?['avatar_url'])?.toString();
      _loading = false;
      _featuredVerifiedUsers = featuredVerified;
    });

    unawaited(_runExploreSearch());
  }

  Future<void> _runExploreSearch({bool includeUsers = false}) async {
    final query = _query.trim();
    setState(() {
      _searchingPosts = true;
      if (includeUsers && query.isNotEmpty) _searchingUsers = true;
    });

    try {
      final futures = await Future.wait<List<Map<String, dynamic>>>([
        SupabaseService.searchPosts(query: query, timeFilter: _timeFilter, limit: 80, smart: true),
        SupabaseService.getTrendingHashtags(timeFilter: _timeFilter, limit: 14),
        if (includeUsers && query.isNotEmpty) SupabaseService.searchUsers(query) else Future.value(<Map<String, dynamic>>[]),
      ]);

      if (!mounted) return;
      setState(() {
        _postResults = futures[0];
        _trendingHashtags = futures[1];
        if (includeUsers) _userResults = futures[2];
        _searchingPosts = false;
        _searchingUsers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchingPosts = false;
        _searchingUsers = false;
      });
      NotificationService.showTopNotification('تعذر تحديث البحث: $e');
    }
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    setState(() => _query = value);

    if (value.trim().isEmpty) {
      setState(() {
        _userResults = [];
        _searchingUsers = false;
      });
    }

    _searchDebounce = Timer(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      _runExploreSearch(includeUsers: true);
    });
  }

  void _selectTimeFilter(String value) {
    if (_timeFilter == value) return;
    setState(() => _timeFilter = value);
    _runExploreSearch(includeUsers: _query.trim().isNotEmpty);
  }

  void _openHashtag(String tag) {
    final clean = HashtagPostsScreen.normalizeHashtag(tag);
    if (clean.length <= 1) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HashtagPostsScreen(hashtag: clean)),
    );
  }

  Future<void> _saveCommunities() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_communitiesKey, jsonEncode(_communities.map((c) => c.toJson()).toList()));
  }

  Future<void> _saveFollowing() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_followingKey, jsonEncode(_following));
  }

  Future<void> _togglePostNotificationForUser(String username) async {
    final target = _cleanUsername(username);
    if (target == _currentUsername || target == '@user') return;

    final isFollowing = (_following[_currentUsername] ?? const <String>[]).contains(target);
    if (!isFollowing) {
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
        followerUsername: _currentUsername,
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

  Future<void> _toggleFollowUser(String username) async {
    final clean = _cleanUsername(username);
    if (clean == _currentUsername) return;
    final list = List<String>.from(_following[_currentUsername] ?? const <String>[]);
    if (list.contains(clean)) {
      list.remove(clean);
    } else {
      list.add(clean);
    }
    setState(() => _following[_currentUsername] = list.toSet().toList());
    await _saveFollowing();
  }

  Future<void> _toggleFollowCommunity(CityCommunity community) async {
    setState(() {
      if (community.members.contains(_currentUsername)) {
        if (community.ownerUsername != _currentUsername) {
          community.members.remove(_currentUsername);
          community.moderators.remove(_currentUsername);
        }
      } else {
        community.members.add(_currentUsername);
      }
    });
    await _saveCommunities();
  }

  ImageProvider? _imageProvider(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    final value = path.trim();
    if (value.startsWith('http://') || value.startsWith('https://')) return NetworkImage(value);
    final file = File(value);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  List<Map<String, dynamic>> get _displayedAccounts {
    if (_query.trim().isEmpty) {
      final seen = <String>{};
      final out = <Map<String, dynamic>>[];
      for (final user in [..._featuredVerifiedUsers, ..._accounts]) {
        final username = _cleanUsername((user['username'] ?? user['id'] ?? '').toString());
        if (username == '@user' || seen.contains(username)) continue;
        seen.add(username);
        out.add(user);
      }
      out.sort((a, b) => SupabaseService.searchPriorityWeightForUser(b).compareTo(SupabaseService.searchPriorityWeightForUser(a)));
      return out;
    }
    final out = List<Map<String, dynamic>>.from(_userResults);
    out.sort((a, b) => SupabaseService.searchPriorityWeightForUser(b).compareTo(SupabaseService.searchPriorityWeightForUser(a)));
    return out;
  }

  List<CityCommunity> get _filteredCommunities {
    final q = _query.trim().toLowerCase().replaceFirst('#', '');
    if (q.isEmpty) return _communities;
    return _communities.where((c) {
      return c.name.toLowerCase().contains(q) || c.description.toLowerCase().contains(q) || c.ownerUsername.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _openCommunity(CityCommunity community) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CommunityScreen(
          community: community,
          currentUsername: _currentUsername,
          currentName: _currentName,
          currentAvatarPath: _currentAvatarPath,
          avatarProviderForPath: _imageProvider,
          onChanged: () async {
            if (mounted) setState(() {});
            await _saveCommunities();
          },
        ),
      ),
    );
    await _saveCommunities();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgTop = isDark ? const Color(0xFF0D0D12) : const Color(0xFFF5F5F7);
    final bgBottom = isDark ? const Color(0xFF080810) : const Color(0xFFFFFFFF);

    return Scaffold(
      appBar: null,
      extendBody: true,
      backgroundColor: bgBottom,
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [bgTop, bgBottom]),
              ),
            ),
          ),

          SafeArea(
            child: _loading
                ? const _ExploreLoading()
                : Column(
              children: [
                _ExploreHeader(
                  isDark: isDark,
                  postCount: _postResults.length,
                  trendingCount: _trendingHashtags.length,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: _ExploreSearchField(
                    controller: _searchCtrl,
                    isDark: isDark,
                    searching: _searchingPosts || _searchingUsers,
                    onChanged: _onQueryChanged,
                    onClear: () {
                      _searchCtrl.clear();
                      _onQueryChanged('');
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: _TimeFilterStrip(
                    selected: _timeFilter,
                    onChanged: _selectTimeFilter,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: _ExploreTabBar(
                    controller: _tabController,
                    isDark: isDark,
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _PostsExploreList(
                        posts: _postResults,
                        trendingHashtags: _trendingHashtags,
                        searching: _searchingPosts,
                        isDark: isDark,
                        query: _query,
                        imageProvider: _imageProvider,
                        onHashtagTap: _openHashtag,
                      ),
                      _UsersResultsList(
                        users: _displayedAccounts,
                        currentUsername: _currentUsername,
                        following: _following,
                        isDark: isDark,
                        imageProvider: _imageProvider,
                        onToggleFollow: _toggleFollowUser,
                        notificationTargets: _postNotificationTargets,
                        onTogglePostNotification: _togglePostNotificationForUser,
                        isLoading: _searchingUsers,
                        query: _query,
                      ),
                      _CommunitiesResultsList(
                        communities: _filteredCommunities,
                        currentUsername: _currentUsername,
                        isDark: isDark,
                        onOpen: _openCommunity,
                        onToggleFollow: _toggleFollowCommunity,
                        query: _query,
                      ),
                    ],
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





class _ExploreLoading extends StatelessWidget {
  const _ExploreLoading();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        width: 86,
        height: 86,
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white.withValues(alpha: .82),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: AppColors.purple.withValues(alpha: .14)),
          boxShadow: [
            BoxShadow(
              color: AppColors.purple.withValues(alpha: .10),
              blurRadius: 34,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: const Center(child: CircularProgressIndicator(color: AppColors.purple, strokeWidth: 2.6)),
      ),
    );
  }
}

class _ExploreHeader extends StatelessWidget {
  final bool isDark;
  final int postCount;
  final int trendingCount;

  const _ExploreHeader({
    required this.isDark,
    required this.postCount,
    required this.trendingCount,
  });

  @override
  Widget build(BuildContext context) {
    final muted = isDark ? Colors.white60 : const Color(0xFF7B7286);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                colors: [Color(0xFF7C3AED), Color(0xFFB678FF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.purple.withValues(alpha: .28),
                  blurRadius: 22,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: const Icon(Icons.search_rounded, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'البحث',
                  style: TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'بحث ذكي بالتغريدات والهاشتاقات والمجتمعات',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: muted,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _HeaderSoftBadge(
            value: postCount,
            icon: Icons.forum_rounded,
            isDark: isDark,
          ),
          const SizedBox(width: 7),
          _HeaderSoftBadge(
            value: trendingCount,
            icon: Icons.local_fire_department_rounded,
            isDark: isDark,
          ),
        ],
      ),
    );
  }
}

class _HeaderSoftBadge extends StatelessWidget {
  final int value;
  final IconData icon;
  final bool isDark;

  const _HeaderSoftBadge({
    required this.value,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .055) : Colors.white.withValues(alpha: .70),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.purple.withValues(alpha: .13)),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.purple, size: 16),
          const SizedBox(width: 5),
          Text(
            value > 99 ? '+99' : '$value',
            style: const TextStyle(
              color: AppColors.purple,
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExploreSearchField extends StatelessWidget {
  final TextEditingController controller;
  final bool isDark;
  final bool searching;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _ExploreSearchField({
    required this.controller,
    required this.isDark,
    required this.searching,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final fill = isDark ? const Color(0xFF181020).withValues(alpha: .86) : Colors.white.withValues(alpha: .92);
    final textColor = isDark ? Colors.white : const Color(0xFF15111A);
    final hintColor = isDark ? Colors.white54 : const Color(0xFF8B8196);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: 58,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.purple.withValues(alpha: .16)),
        boxShadow: [
          BoxShadow(
            color: AppColors.purple.withValues(alpha: isDark ? .10 : .09),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Center(
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          style: TextStyle(color: textColor, fontWeight: FontWeight.w800, fontSize: 15),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 15),
            prefixIcon: Container(
              margin: const EdgeInsetsDirectional.only(start: 8, end: 6),
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.purple.withValues(alpha: .11),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.search_rounded, color: AppColors.purple, size: 21),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 52, minHeight: 38),
            hintText: 'بحث ذكي: عصابة الكفن، سيرفر ريسبكت، #هاشتاق...',
            hintStyle: TextStyle(color: hintColor, fontWeight: FontWeight.w700, fontSize: 13.5),
            suffixIcon: searching
                ? const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: AppColors.purple,
                ),
              ),
            )
                : controller.text.trim().isEmpty
                ? null
                : IconButton(
              onPressed: onClear,
              icon: Icon(Icons.close_rounded, color: hintColor),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimeFilterStrip extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;

  const _TimeFilterStrip({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const items = <Map<String, dynamic>>[
      {'key': 'today', 'label': 'اليوم', 'icon': Icons.today_rounded},
      {'key': 'week', 'label': 'الأسبوع', 'icon': Icons.date_range_rounded},
      {'key': 'month', 'label': 'الشهر', 'icon': Icons.calendar_month_rounded},
      {'key': 'all', 'label': 'الكل', 'icon': Icons.public_rounded},
    ];

    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          final key = item['key'] as String;
          final label = item['label'] as String;
          final icon = item['icon'] as IconData;
          final active = selected == key;

          return InkWell(
            onTap: () => onChanged(key),
            borderRadius: BorderRadius.circular(999),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                color: active
                    ? AppColors.purple
                    : (isDark ? Colors.white.withValues(alpha: .055) : Colors.white.withValues(alpha: .72)),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: active ? AppColors.purple : AppColors.purple.withValues(alpha: .12),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15.5, color: active ? Colors.white : AppColors.purple),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: active ? Colors.white : (isDark ? Colors.white70 : const Color(0xFF4A4254)),
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ExploreTabBar extends StatelessWidget {
  final TabController controller;
  final bool isDark;

  const _ExploreTabBar({
    required this.controller,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .055) : Colors.white.withValues(alpha: .78),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.purple.withValues(alpha: .12)),
      ),
      child: TabBar(
        controller: controller,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(
          color: AppColors.purple,
          borderRadius: BorderRadius.circular(15),
          boxShadow: [
            BoxShadow(
              color: AppColors.purple.withValues(alpha: .22),
              blurRadius: 16,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        labelColor: Colors.white,
        unselectedLabelColor: isDark ? Colors.white60 : const Color(0xFF6E6478),
        labelStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
        tabs: const [
          Tab(child: Text('التغريدات')),
          Tab(child: Text('الأشخاص')),
          Tab(child: Text('المجتمعات')),
        ],
      ),
    );
  }
}




class _PostsExploreList extends StatelessWidget {
  final List<Map<String, dynamic>> posts;
  final List<Map<String, dynamic>> trendingHashtags;
  final bool searching;
  final bool isDark;
  final String query;
  final ImageProvider? Function(String? path) imageProvider;
  final ValueChanged<String> onHashtagTap;

  const _PostsExploreList({
    required this.posts,
    required this.trendingHashtags,
    required this.searching,
    required this.isDark,
    required this.query,
    required this.imageProvider,
    required this.onHashtagTap,
  });

  @override
  Widget build(BuildContext context) {
    if (searching && posts.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: AppColors.purple, strokeWidth: 2.6));
    }

    return RefreshIndicator(
      color: AppColors.purple,
      onRefresh: () async {},
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 105),
        children: [
          _TrendingHashtagsSection(
            hashtags: trendingHashtags,
            isDark: isDark,
            onTap: onHashtagTap,
          ),
          if (query.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            _SmartSearchNotice(query: query, isDark: isDark),
          ],
          const SizedBox(height: 14),
          if (posts.isEmpty)
            _EmptyExploreState(
              icon: Icons.manage_search_rounded,
              title: query.trim().isEmpty ? 'ابدأ بالبحث عن موضوع' : 'لا توجد تغريدات مطابقة',
              subtitle: query.trim().isEmpty
                  ? ''
                  : 'البحث الذكي يطابق الكلمات القريبة والهاشتاقات. جرّب تغيير فلتر الوقت إلى الكل.',
            )
          else
            ...List.generate(posts.length, (i) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ExplorePostCard(
                  post: posts[i],
                  isDark: isDark,
                  imageProvider: imageProvider,
                  onHashtagTap: onHashtagTap,
                ),
              );
            }),
        ],
      ),
    );
  }
}


class _SmartSearchNotice extends StatelessWidget {
  final String query;
  final bool isDark;

  const _SmartSearchNotice({required this.query, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final clean = query.trim();
    final isHash = clean.startsWith('#');
    final muted = isDark ? Colors.white60 : const Color(0xFF7B7286);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.purple.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.purple.withValues(alpha: .13)),
      ),
      child: Row(
        children: [
          Icon(isHash ? Icons.tag_rounded : Icons.auto_awesome_rounded, color: AppColors.purple, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isHash
                  ? 'يعرض كل التغريدات المرتبطة بالهاشتاق $clean'
                  : 'بحث ذكي عن: $clean — يطابق الكلمات القريبة والمواضيع المرتبطة',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: muted, fontWeight: FontWeight.w800, fontSize: 12.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendingHashtagsSection extends StatelessWidget {
  final List<Map<String, dynamic>> hashtags;
  final bool isDark;
  final ValueChanged<String> onTap;

  const _TrendingHashtagsSection({
    required this.hashtags,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final muted = isDark ? Colors.white60 : const Color(0xFF7B7286);

    return _PremiumPanel(
      isDark: isDark,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.purple.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(Icons.local_fire_department_rounded, color: AppColors.purple, size: 20),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'الهاشتاقات المتصدرة',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15.5),
                ),
              ),
              if (hashtags.isNotEmpty)
                Text(
                  '${hashtags.length}',
                  style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (hashtags.isEmpty)
            Text(
              'لما يكتب المستخدمون هاشتاقات داخل التغريدات ستظهر هنا بشكل مرتب.',
              style: TextStyle(color: muted, height: 1.45, fontWeight: FontWeight.w700, fontSize: 12.5),
            )
          else
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: hashtags.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final raw = hashtags[index];
                  final tag = (raw['tag'] ?? '').toString();
                  final count = int.tryParse((raw['count'] ?? 0).toString()) ?? 0;
                  final score = int.tryParse((raw['score'] ?? 0).toString()) ?? 0;

                  return InkWell(
                    onTap: () => onTap(tag),
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.purple.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppColors.purple.withValues(alpha: .17)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(tag, style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900)),
                          const SizedBox(width: 7),
                          Text(
                            '$count',
                            style: TextStyle(color: muted, fontSize: 11, fontWeight: FontWeight.w900),
                          ),
                          if (score > count) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.trending_up_rounded, color: AppColors.purple, size: 14),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ExplorePostCard extends StatelessWidget {
  final Map<String, dynamic> post;
  final bool isDark;
  final ImageProvider? Function(String? path) imageProvider;
  final ValueChanged<String> onHashtagTap;

  const _ExplorePostCard({
    required this.post,
    required this.isDark,
    required this.imageProvider,
    required this.onHashtagTap,
  });

  int _int(dynamic value) => int.tryParse((value ?? 0).toString()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final username = SupabaseService.displayUsername((post['username'] ?? '@user').toString());
    final name = (post['name'] ?? post['user'] ?? username).toString();
    final text = (post['text'] ?? '').toString();
    final avatar = (post['avatar_url'] ?? post['avatarPath'] ?? '').toString();
    final image = (post['image_url'] ?? '').toString();
    final video = (post['video_url'] ?? '').toString();
    final voice = (post['voice_url'] ?? post['voicePath'] ?? '').toString();
    final muted = isDark ? Colors.white60 : const Color(0xFF7B7286);
    final imageProviderValue = imageProvider(avatar);
    final verified = SupabaseService.truthy(post['author_verified'] ?? post['is_verified'] ?? post['verified']);
    final rawTier = (post['author_subscription_tier'] ?? post['subscription_tier'] ?? post['tier'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final tier = rawTier == 'premium' || rawTier == 'gold' || rawTier == 'silver'
        ? rawTier
        : (verified ? 'premium' : 'free');

    return _PremiumPanel(
      isDark: isDark,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: tier == 'free' ? null : LinearGradient(colors: tier == 'premium' ? const [Color(0xFF5B21B6), Color(0xFFE879F9), Color(0xFF22D3EE)] : tier == 'gold' ? const [Color(0xFFF59E0B), Color(0xFFFDE68A)] : const [Color(0xFFCBD5E1), Color(0xFF94A3B8)]),
                  border: Border.all(color: AppColors.purple.withValues(alpha: .18)),
                ),
                child: CircleAvatar(
                  radius: 22,
                  backgroundColor: AppColors.purple.withValues(alpha: .16),
                  backgroundImage: imageProviderValue,
                  child: imageProviderValue == null ? const Icon(Icons.person_rounded, color: AppColors.purple) : null,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15.5),
                          ),
                        ),
                        if (verified) ...[
                          const SizedBox(width: 5),
                          const Icon(Icons.verified_rounded, color: AppColors.purple, size: 17),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$username · ${_formatTime((post['created_at'] ?? post['time'] ?? '').toString())}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.purple.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(Icons.chevron_left_rounded, color: AppColors.purple),
              ),
            ],
          ),
          if (text.trim().isNotEmpty) ...[
            const SizedBox(height: 13),
            _ExplorePostText(
              text: text,
              onHashtagTap: onHashtagTap,
              style: const TextStyle(fontSize: 15.7, height: 1.48, fontWeight: FontWeight.w600),
            ),
          ],
          if (image.trim().isNotEmpty || video.trim().isNotEmpty) ...[
            const SizedBox(height: 13),
            Container(
              height: 142,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: AppColors.purple.withValues(alpha: .075),
                border: Border.all(color: AppColors.purple.withValues(alpha: .14)),
              ),
              child: Center(
                child: Icon(
                  video.trim().isNotEmpty ? Icons.play_circle_fill_rounded : Icons.image_rounded,
                  color: AppColors.purple,
                  size: 42,
                ),
              ),
            ),
          ],
          if (voice.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.purple.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.purple.withValues(alpha: .12)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.graphic_eq_rounded, color: AppColors.purple, size: 19),
                  SizedBox(width: 7),
                  Text('تسجيل صوتي', style: TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900, fontSize: 12.5)),
                ],
              ),
            ),
          ],
          const SizedBox(height: 13),
          Row(
            children: [
              _MiniStatChip(icon: Icons.favorite_rounded, text: '${_int(post['likes'])}'),
              _MiniStatChip(icon: Icons.repeat_rounded, text: '${_int(post['reposts'])}'),
              _MiniStatChip(icon: Icons.remove_red_eye_rounded, text: '${_int(post['views'])}'),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatTime(String raw) {
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return raw.trim().isEmpty ? 'الآن' : raw;
    final diff = DateTime.now().difference(parsed);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'قبل ${diff.inMinutes} د';
    if (diff.inHours < 24) return 'قبل ${diff.inHours} س';
    if (diff.inDays < 7) return 'قبل ${diff.inDays} يوم';
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }
}

class _ExplorePostText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final ValueChanged<String> onHashtagTap;

  const _ExplorePostText({
    required this.text,
    required this.onHashtagTap,
    this.style,
  });

  static final RegExp _tokenRegex = RegExp(
    r'(#[^\s#@]+|@[a-zA-Z0-9_\.]+|https?:\/\/[^\s]+|www\.[^\s]+)',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final spans = <TextSpan>[];
    var index = 0;

    for (final match in _tokenRegex.allMatches(text)) {
      if (match.start > index) spans.add(TextSpan(text: text.substring(index, match.start)));
      final token = match.group(0)!;
      if (token.startsWith('#')) {
        spans.add(
          TextSpan(
            text: token,
            style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900),
            recognizer: TapGestureRecognizer()..onTap = () => onHashtagTap(token),
          ),
        );
      } else if (token.startsWith('@')) {
        spans.add(TextSpan(text: token, style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900)));
      } else {
        spans.add(
          TextSpan(
            text: token,
            style: const TextStyle(
              color: Colors.blueAccent,
              fontWeight: FontWeight.w800,
              decoration: TextDecoration.underline,
            ),
          ),
        );
      }
      index = match.end;
    }

    if (index < text.length) spans.add(TextSpan(text: text.substring(index)));
    return RichText(text: TextSpan(style: base, children: spans));
  }
}


class HashtagPostsScreen extends StatefulWidget {
  final String hashtag;

  const HashtagPostsScreen({
    super.key,
    required this.hashtag,
  });

  static String normalizeHashtag(String value) {
    var clean = value.trim();
    while (clean.isNotEmpty && RegExp(r'[\.,،؛:!؟\)\]\}]$').hasMatch(clean)) {
      clean = clean.substring(0, clean.length - 1);
    }
    clean = clean.replaceAll(RegExp(r'\s+'), '');
    if (clean.isEmpty) return '#';
    if (!clean.startsWith('#')) clean = '#$clean';
    return clean;
  }

  @override
  State<HashtagPostsScreen> createState() => _HashtagPostsScreenState();
}

class _HashtagPostsScreenState extends State<HashtagPostsScreen> {
  List<Map<String, dynamic>> _posts = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;

  String get _hashtag => HashtagPostsScreen.normalizeHashtag(widget.hashtag);

  @override
  void initState() {
    super.initState();
    _loadHashtagPosts();
  }

  bool _containsExactHashtag(String text, String hashtag) {
    final clean = HashtagPostsScreen.normalizeHashtag(hashtag).toLowerCase();
    if (clean.length <= 1) return false;
    final pattern = RegExp(
      '(^|[\\s\\n\\r\\t\\.,،؛:!؟\\(\\)\\[\\]\\{\\}])${RegExp.escape(clean)}(?=\$|[\\s\\n\\r\\t\\.,،؛:!؟\\(\\)\\[\\]\\{\\}])',
      caseSensitive: false,
      unicode: true,
    );
    return pattern.hasMatch(text.toLowerCase());
  }

  int _sortMillis(Map<String, dynamic> post) {
    final raw = (post['created_at'] ?? post['time'] ?? '').toString();
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed.millisecondsSinceEpoch;
    final id = (post['id'] ?? '').toString();
    return int.tryParse(id.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  Future<List<Map<String, dynamic>>> _fetchHashtagPosts() async {
    final tag = _hashtag;
    final rows = <Map<String, dynamic>>[];

    try {
      final found = await SupabaseService.searchPosts(
        query: tag,
        timeFilter: 'all',
        limit: 180,
        smart: false,
      );
      rows.addAll(found);
    } catch (_) {
      _scannerSafeIgnore();
    }

    if (rows.isEmpty) {
      try {
        final data = await SupabaseService.client
            .from('posts')
            .select('id,username,name,user,text,created_at,time,avatar_url,avatarPath,image_url,video_url,voice_url,voicePath,likes,reposts,views,replies,author_verified,author_subscription_tier')
            .ilike('text', '%$tag%')
            .order('created_at', ascending: false)
            .limit(180);
        rows.addAll(
          List<Map<String, dynamic>>.from(
            data.map((e) => Map<String, dynamic>.from(e as Map)),
          ),
        );
      } catch (_) {
        try {
          final data = await SupabaseService.client
              .from('posts')
              .select()
              .ilike('text', '%$tag%')
              .order('created_at', ascending: false)
              .limit(180);
          rows.addAll(
            List<Map<String, dynamic>>.from(
              data.map((e) => Map<String, dynamic>.from(e as Map)),
            ),
          );
        } catch (_) {
          _scannerSafeIgnore();
        }
      }
    }

    final seen = <String>{};
    final exact = <Map<String, dynamic>>[];
    for (final row in rows) {
      final id = (row['id'] ?? '').toString();
      final text = (row['text'] ?? '').toString();
      if (!_containsExactHashtag(text, tag)) continue;
      final key = id.trim().isEmpty ? '${row['username']}_${row['created_at']}_${text.hashCode}' : id;
      if (seen.contains(key)) continue;
      seen.add(key);
      exact.add(row);
    }
    exact.sort((a, b) => _sortMillis(b).compareTo(_sortMillis(a)));
    return exact;
  }

  Future<void> _loadHashtagPosts({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final posts = await _fetchHashtagPosts();
      if (!mounted) return;
      setState(() {
        _posts = posts;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  ImageProvider? _imageProvider(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    final value = path.trim();
    if (value.startsWith('http://') || value.startsWith('https://')) return NetworkImage(value);
    final file = File(value);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  void _openNestedHashtag(String tag) {
    final clean = HashtagPostsScreen.normalizeHashtag(tag);
    if (clean.length <= 1) return;
    if (clean.toLowerCase() == _hashtag.toLowerCase()) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HashtagPostsScreen(hashtag: clean)),
    );
  }

  Widget _buildHeader(bool isDark) {
    final muted = isDark ? Colors.white60 : const Color(0xFF7B7286);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Row(
        children: [
          InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white.withValues(alpha: .86),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.purple.withValues(alpha: .14)),
              ),
              child: const Icon(Icons.arrow_back_rounded, color: AppColors.purple),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _hashtag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -.4),
                ),
                const SizedBox(height: 2),
                Text(
                  _loading ? 'جاري تحميل التغريدات...' : '${_posts.length} تغريدة تحتوي على هذا الهاشتاق',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted, fontWeight: FontWeight.w800, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFFB678FF)]),
              borderRadius: BorderRadius.circular(17),
              boxShadow: [
                BoxShadow(
                  color: AppColors.purple.withValues(alpha: .24),
                  blurRadius: 18,
                  offset: const Offset(0, 9),
                ),
              ],
            ),
            child: const Icon(Icons.tag_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_loading && _posts.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 45, 16, 120),
        children: const [
          Center(child: CircularProgressIndicator(color: AppColors.purple, strokeWidth: 2.6)),
        ],
      );
    }

    if (_error != null && _posts.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
        children: [
          _EmptyExploreState(
            icon: Icons.wifi_off_rounded,
            title: 'تعذر تحميل الهاشتاق',
            subtitle: 'اسحب للأسفل للمحاولة مرة ثانية.',
          ),
        ],
      );
    }

    if (_posts.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
        children: [
          _EmptyExploreState(
            icon: Icons.tag_faces_rounded,
            title: 'لا توجد تغريدات لهذا الهاشتاق',
            subtitle: 'أي تغريدة تحتوي على $_hashtag ستظهر هنا تلقائيًا.',
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
      itemCount: _posts.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        return _ExplorePostCard(
          post: _posts[index],
          isDark: isDark,
          imageProvider: _imageProvider,
          onHashtagTap: _openNestedHashtag,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgTop = isDark ? const Color(0xFF0D0D12) : const Color(0xFFF5F5F7);
    final bgBottom = isDark ? const Color(0xFF080810) : const Color(0xFFFFFFFF);

    return Scaffold(
      appBar: null,
      extendBody: true,
      backgroundColor: bgBottom,
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [bgTop, bgBottom],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(isDark),
                Expanded(
                  child: RefreshIndicator(
                    color: AppColors.purple,
                    onRefresh: () => _loadHashtagPosts(silent: true),
                    child: _buildBody(isDark),
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

class _PremiumPanel extends StatelessWidget {
  final bool isDark;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _PremiumPanel({
    required this.isDark,
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF181020).withValues(alpha: .76) : Colors.white.withValues(alpha: .88),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.purple.withValues(alpha: .12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .035),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: AppColors.purple.withValues(alpha: .055),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _EmptyExploreState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyExploreState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white60 : const Color(0xFF7B7286);

    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 55, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: AppColors.purple.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: AppColors.purple.withValues(alpha: .14)),
              ),
              child: Icon(icon, color: AppColors.purple, size: 34),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
            ),
            const SizedBox(height: 7),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontWeight: FontWeight.w700, height: 1.45, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _RespectAiVerifiedBadge extends StatelessWidget {
  final String tier;
  final bool large;
  const _RespectAiVerifiedBadge({this.tier = 'premium', this.large = false});

  static String _tier(String value) {
    final v = value.trim().toLowerCase();
    if (v == 'premium' || v == 'gold' || v == 'silver') return v;
    return 'premium';
  }

  static List<Color> _colors(String value) {
    final t = _tier(value);
    if (t == 'premium') return const [Color(0xFF5B21B6), Color(0xFFE879F9), Color(0xFF22D3EE)];
    if (t == 'gold') return const [Color(0xFF92400E), Color(0xFFF59E0B), Color(0xFFFDE68A)];
    return const [Color(0xFF475569), Color(0xFFCBD5E1), Color(0xFF94A3B8)];
  }

  @override
  Widget build(BuildContext context) {
    final t = _tier(tier);
    return Container(
      margin: const EdgeInsetsDirectional.only(start: 5),
      padding: EdgeInsets.all(large ? 3.7 : 2.2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: _colors(t), begin: Alignment.topLeft, end: Alignment.bottomRight),
        border: Border.all(color: Colors.white.withValues(alpha: .72), width: large ? 1.2 : .7),
        boxShadow: [BoxShadow(color: _colors(t).first.withValues(alpha: 0.38), blurRadius: large ? 14 : 8)],
      ),
      child: Icon(t == 'premium' ? Icons.diamond_rounded : t == 'gold' ? Icons.workspace_premium_rounded : Icons.check_rounded, color: Colors.white, size: large ? 15 : 12),
    );
  }
}

bool _isRespectAiUsername(String username) {
  return SupabaseService.displayUsername(username) == SupabaseService.respectAiUsername;
}

class _UsersResultsList extends StatelessWidget {
  final List<Map<String, dynamic>> users;
  final String currentUsername;
  final Map<String, List<String>> following;
  final bool isDark;
  final ImageProvider? Function(String? path) imageProvider;
  final Future<void> Function(String username) onToggleFollow;
  final Set<String> notificationTargets;
  final Future<void> Function(String username) onTogglePostNotification;
  final bool isLoading;
  final String query;

  const _UsersResultsList({
    required this.users,
    required this.currentUsername,
    required this.following,
    required this.isDark,
    required this.imageProvider,
    required this.onToggleFollow,
    required this.notificationTargets,
    required this.onTogglePostNotification,
    this.isLoading = false,
    this.query = '',
  });


  @override
  Widget build(BuildContext context) {
    if (isLoading) return const Center(child: CircularProgressIndicator(color: AppColors.purple, strokeWidth: 2.6));
    if (users.isEmpty) {
      return _EmptyExploreState(
        icon: Icons.person_search_rounded,
        title: query.trim().isEmpty ? 'اكتب اسم شخص للبحث' : 'لا يوجد أشخاص مطابقين',
        subtitle: 'تقدر تبحث بالاسم أو اليوزر.',
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 105),
      itemCount: users.length,
      itemBuilder: (context, i) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _UserResultCard(
            user: users[i],
            currentUsername: currentUsername,
            following: following,
            isDark: isDark,
            imageProvider: imageProvider,
            onToggleFollow: onToggleFollow,
            notificationTargets: notificationTargets,
            onTogglePostNotification: onTogglePostNotification,
          ),
        );
      },
    );
  }
}

class _UserResultCard extends StatelessWidget {
  final Map<String, dynamic> user;
  final String currentUsername;
  final Map<String, List<String>> following;
  final bool isDark;
  final ImageProvider? Function(String? path) imageProvider;
  final Future<void> Function(String username) onToggleFollow;
  final Set<String> notificationTargets;
  final Future<void> Function(String username) onTogglePostNotification;

  const _UserResultCard({
    required this.user,
    required this.currentUsername,
    required this.following,
    required this.isDark,
    required this.imageProvider,
    required this.onToggleFollow,
    required this.notificationTargets,
    required this.onTogglePostNotification,
  });

  String _clean(String value) {
    final v = value.trim().replaceAll(RegExp(r'\s+'), '_').replaceAll('@', '').toLowerCase();
    return v.isEmpty ? '@user' : '@$v';
  }

  @override
  Widget build(BuildContext context) {
    final rawUsername = _clean((user['username'] ?? user['id'] ?? '@user').toString());
    final isRespectAi = _isRespectAiUsername(rawUsername);
    final tier = isRespectAi ? 'premium' : SupabaseService.subscriptionTierForUser(user);
    final isVerified = isRespectAi || SupabaseService.isVerifiedUser(user);
    final powerText = SupabaseService.tierPowerDescription(tier);
    final username = isRespectAi ? SupabaseService.respectAiUsername : rawUsername;
    final name = isRespectAi ? SupabaseService.respectAiName : (user['profileName'] ?? user['name'] ?? 'User').toString();
    final bio = isRespectAi ? 'مساعد ذكي رسمي وموثق داخل Respect App' : (user['bio'] ?? 'Respect App user').toString();
    final avatarPath = isRespectAi ? SupabaseService.respectAiAvatarUrl : (user['avatar_url'] ?? user['imagePath'] ?? user['profileImagePath'])?.toString();
    final image = imageProvider(avatarPath);
    final isMe = username == currentUsername;
    final isFollowing = (following[currentUsername] ?? const <String>[]).contains(username);
    final muted = isDark ? Colors.white60 : const Color(0xFF7B7286);

    return _PremiumPanel(
      isDark: isDark,
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => UserProfileViewScreen(
              user: name,
              username: username,
              bio: bio,
              avatarPath: avatarPath,
              coverPath: (user['cover_url'] ?? user['coverPath'] ?? user['cover_path'])?.toString(),
              posts: const [],
              currentUsername: currentUsername,
              following: following,
              notificationTargets: notificationTargets,
              onToggleFollow: onToggleFollow,
              onTogglePostNotification: onTogglePostNotification,
            ),
          ),
        ),
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(2.2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: tier == 'free' ? null : LinearGradient(
                    colors: tier == 'premium'
                        ? const [Color(0xFF5B21B6), Color(0xFFE879F9), Color(0xFF22D3EE)]
                        : tier == 'gold'
                            ? const [Color(0xFFF59E0B), Color(0xFFFDE68A)]
                            : const [Color(0xFFCBD5E1), Color(0xFF94A3B8)],
                  ),
                  border: Border.all(color: AppColors.purple.withValues(alpha: .18)),
                ),
                child: CircleAvatar(
                  radius: 26,
                  backgroundColor: AppColors.purple.withValues(alpha: .15),
                  backgroundImage: image,
                  child: image == null ? const Icon(Icons.person_rounded, color: AppColors.purple) : null,
                ),
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
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                          ),
                        ),
                        if (isVerified) _RespectAiVerifiedBadge(tier: tier),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(children: [Expanded(child: Text(username, style: TextStyle(color: muted, fontWeight: FontWeight.w800, fontSize: 12.5))), if (tier != 'free') Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3), decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: .10), borderRadius: BorderRadius.circular(999)), child: Text(SupabaseService.tierDisplayName(tier), style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900, fontSize: 10))) ]),
                    if (bio.trim().isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        bio,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isDark ? Colors.white.withValues(alpha: .82) : const Color(0xFF302A37),
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                    if (tier != 'free') ...[const SizedBox(height: 5), Text(powerText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppColors.purple.withValues(alpha: .92), fontWeight: FontWeight.w800, fontSize: 11.5))],
                  ],
                ),
              ),
              const SizedBox(width: 9),
              if (!isMe)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _CircleActionButton(
                          icon: Icons.chat_bubble_rounded,
                          tooltip: 'دردشة',
                          isDark: isDark,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ChatScreen(
                                peerUsername: username,
                                peerName: name,
                                peerAvatarPath: avatarPath,
                              ),
                            ),
                          ),
                        ),
                        if (isFollowing) ...[
                          const SizedBox(width: 6),
                          _CircleActionButton(
                            icon: notificationTargets.contains(username) ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
                            tooltip: notificationTargets.contains(username) ? 'إيقاف إشعارات التغريدات' : 'تفعيل إشعارات التغريدات',
                            isDark: isDark,
                            active: notificationTargets.contains(username),
                            onTap: () => onTogglePostNotification(username),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    _FollowButton(
                      isFollowing: isFollowing,
                      isDark: isDark,
                      onTap: () => onToggleFollow(username),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isDark;
  final bool active;
  final VoidCallback onTap;

  const _CircleActionButton({
    required this.icon,
    required this.tooltip,
    required this.isDark,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: active ? AppColors.purple.withValues(alpha: .16) : (isDark ? Colors.white.withValues(alpha: .06) : Colors.black.withValues(alpha: .035)),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.purple.withValues(alpha: active ? .22 : .10)),
          ),
          child: Icon(icon, color: active ? AppColors.purple : (isDark ? Colors.white70 : const Color(0xFF62586D)), size: 18),
        ),
      ),
    );
  }
}

class _CommunitiesResultsList extends StatelessWidget {
  final List<CityCommunity> communities;
  final String currentUsername;
  final bool isDark;
  final Future<void> Function(CityCommunity community) onOpen;
  final Future<void> Function(CityCommunity community) onToggleFollow;
  final String query;

  const _CommunitiesResultsList({
    required this.communities,
    required this.currentUsername,
    required this.isDark,
    required this.onOpen,
    required this.onToggleFollow,
    this.query = '',
  });

  @override
  Widget build(BuildContext context) {
    if (communities.isEmpty) {
      return _EmptyExploreState(
        icon: Icons.groups_2_rounded,
        title: query.trim().isEmpty ? 'لا توجد مجتمعات بعد' : 'لا توجد مجتمعات مطابقة',
        subtitle: 'جرّب اسم مجتمع أو وصف مختلف.',
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 105),
      itemCount: communities.length,
      itemBuilder: (context, i) {
        final c = communities[i];
        final isFollowing = c.members.contains(currentUsername);
        final muted = isDark ? Colors.white60 : const Color(0xFF7B7286);

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _PremiumPanel(
            isDark: isDark,
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () => onOpen(c),
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Row(
                  children: [
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(21),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF7C3AED), Color(0xFFC084FC)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.purple.withValues(alpha: .20),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Text(
                          c.name.trim().isEmpty ? 'R' : c.name.characters.first,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 21),
                        ),
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16.2),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            c.description.isEmpty ? 'مجتمع Respect App' : c.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: muted, fontWeight: FontWeight.w700, height: 1.35, fontSize: 12.5),
                          ),
                          const SizedBox(height: 9),
                          Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: [
                              _MiniStatChip(icon: Icons.people_alt_rounded, text: '${c.members.length} متابع'),
                              _MiniStatChip(icon: Icons.forum_rounded, text: '${c.messages.length} رسالة'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 9),
                    _FollowButton(
                      isFollowing: isFollowing,
                      isDark: isDark,
                      onTap: () => onToggleFollow(c),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FollowButton extends StatelessWidget {
  final bool isFollowing;
  final bool isDark;
  final VoidCallback onTap;

  const _FollowButton({
    required this.isFollowing,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          elevation: 0,
          backgroundColor: isFollowing ? (isDark ? Colors.white.withValues(alpha: .075) : Colors.black.withValues(alpha: .045)) : AppColors.purple,
          foregroundColor: isFollowing ? (isDark ? Colors.white : const Color(0xFF302A37)) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          minimumSize: const Size(0, 34),
        ),
        child: Text(
          isFollowing ? 'متابَع' : 'متابعة',
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
        ),
      ),
    );
  }
}

class _MiniStatChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MiniStatChip({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsetsDirectional.only(end: 7),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.purple.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.purple.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.purple),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
