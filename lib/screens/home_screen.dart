// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, use_build_context_synchronously, unnecessary_this, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures, prefer_final_fields, unnecessary_type_check, unnecessary_non_null_assertion
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/notification_service.dart';
import '../services/realtime_notification_service.dart';
import '../services/supabase_service.dart';
import 'feed_screen.dart';
import 'streamers_screen.dart';
import 'respect_live_screen.dart';
import 'respect_painters_screen.dart';
import 'search_screen.dart';
import 'chat_screen.dart';
import 'notifications_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'saved_posts_screen.dart';
import 'admin_screen.dart';

import '../app/app_language.dart';
void _scannerSafeIgnore([Object? error, StackTrace? stackTrace]) {}


class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // indexes:
  // 0 = الرئيسية / الدردشة
  // 1 = الستريمرز
  // 2 = الرسائل
  // 3 = الإشعارات
  // 4 = حسابي
  // 5 = الإعدادات
  // 6 = الإدارة
  // 8 = المحفوظات
  // 9 = بثوث ريسبكت
  // 10 = رسامين ريسبكت
  int index = 0;

  String _profileName = 'Respect App';
  String _profileUsername = 'القائمة الرئيسية';
  String? _profileImagePath;
  bool _isAdmin = false;
  bool _chatConversationActive = false;
  int _unreadMessagesCount = 0;
  int _unreadNotificationsCount = 0;

  RealtimeChannel? _adminUserChannel;
  Timer? _adminStatusFallbackTimer;
  String? _watchedAdminUserKey;
  bool _adminWatcherStarting = false;
  bool _profileRefreshBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshHeaderData();
    _bootNotifications();
    _startAdminStatusWatcher();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _adminStatusFallbackTimer?.cancel();
    final channel = _adminUserChannel;
    _adminUserChannel = null;
    if (channel != null) {
      try {
        channel.unsubscribe();
      } catch (e, st) {
        _scannerSafeIgnore(e, st);
      }
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshHeaderData();
      _bootNotifications();
      _startAdminStatusWatcher(force: true);
    }
  }

  Future<void> _bootNotifications() async {
    await NotificationService.initialize();
    await RealtimeNotificationService.start();
    await NotificationService.openLaunchPayloadIfAny();
  }

  Future<void> _refreshHeaderData() async {
    _loadProfile();
    _loadUnreadMessagesCount();
    _loadUnreadNotificationsCount();
    _startAdminStatusWatcher();
  }

  Future<void> _startAdminStatusWatcher({bool force = false}) async {
    if (_adminWatcherStarting) return;
    _adminWatcherStarting = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentId = prefs.getString('respect_current_user_id') ?? prefs.getString('current_user_id');
      if (currentId == null || currentId.trim().isEmpty) return;

      final watchKey = _normalizeUserId(currentId);
      if (!force && _watchedAdminUserKey == watchKey && _adminUserChannel != null) return;

      final oldChannel = _adminUserChannel;
      _adminUserChannel = null;
      if (oldChannel != null) {
        try {
          await oldChannel.unsubscribe();
        } catch (e, st) {
          _scannerSafeIgnore(e, st);
        }
      }

      _watchedAdminUserKey = watchKey;
      _adminUserChannel = SupabaseService.client
          .channel('home_admin_user_watch_${watchKey}_${DateTime.now().millisecondsSinceEpoch}')
          .onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'users',
        callback: (payload) async {
          final row = Map<String, dynamic>.from(payload.newRecord);
          if (_liveUserRowMatchesCurrent(row, currentId)) {
            await _applyLiveUserRow(row, showToast: true);
          }
        },
      )
          .onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'users',
        callback: (payload) async {
          final row = Map<String, dynamic>.from(payload.newRecord);
          if (_liveUserRowMatchesCurrent(row, currentId)) {
            await _applyLiveUserRow(row, showToast: true);
          }
        },
      )
          .subscribe();

      // احتياط مهم: لو Realtime غير مفعّل على جدول users من Supabase،
      // هذا التايمر يحدث حالة الأدمن تلقائيًا بدون تسجيل خروج/دخول.
      _adminStatusFallbackTimer?.cancel();
      _adminStatusFallbackTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted) _loadProfile(silent: true);
      });
    } catch (e, st) {
      _scannerSafeIgnore(e, st);
    } finally {
      _adminWatcherStarting = false;
    }
  }

  bool _liveUserRowMatchesCurrent(Map<String, dynamic> row, String currentId) {
    final target = _normalizeUserId(currentId);
    final profileTarget = _normalizeUserId(_profileUsername);
    final candidates = <String>{
      (row['id'] ?? '').toString(),
      (row['username'] ?? '').toString(),
      (row['email'] ?? '').toString(),
      (row['user_id'] ?? '').toString(),
    }.map(_normalizeUserId).where((e) => e.isNotEmpty).toSet();

    return candidates.contains(target) ||
        (profileTarget.isNotEmpty && candidates.contains(profileTarget));
  }

  Future<void> _applyLiveUserRow(Map<String, dynamic> row, {bool showToast = false}) async {
    try {
      await SupabaseService.saveCurrentUser(row);
    } catch (e, st) {
      _scannerSafeIgnore(e, st);
    }

    if (!mounted) return;

    final wasAdmin = _isAdmin;
    final prefs = await SharedPreferences.getInstance();
    final currentId = prefs.getString('respect_current_user_id') ??
        prefs.getString('current_user_id') ??
        (row['username'] ?? row['id'] ?? '').toString();
    final isAdmin = _accountIsAdmin(currentId, row);

    final image = (row['avatar_url'] ?? row['profileImagePath'] ?? row['imagePath'])
        ?.toString()
        .trim();
    final profileName = (row['profileName'] ?? row['name'] ?? _profileName).toString();
    final rawUsername = (row['username'] ?? row['id'] ?? _profileUsername).toString();

    setState(() {
      _profileName = profileName;
      _profileUsername = rawUsername.startsWith('@') ? rawUsername : '@$rawUsername';
      _profileImagePath = image != null && image.isNotEmpty ? image : _profileImagePath;
      _isAdmin = isAdmin;
      if (!isAdmin && index == 6) index = 0;
    });

    if (showToast && !wasAdmin && isAdmin) {
      NotificationService.showTopNotification(context.tr('تم تفعيل صلاحية الأدمن لحسابك'),
        title: 'Respect Admin',
        icon: Icons.admin_panel_settings_rounded,
      );
    } else if (showToast && wasAdmin && !isAdmin) {
      NotificationService.showTopNotification(context.tr('تم إلغاء صلاحية الأدمن من حسابك'),
        title: 'Respect Admin',
        icon: Icons.lock_rounded,
      );
    }
  }

  String _normalizeUserId(String value) {
    return value.trim().toLowerCase().replaceAll('@', '').replaceAll(RegExp(r'\s+'), '_');
  }

  bool _truthy(dynamic value) {
    if (value == true) return true;
    final text = value?.toString().toLowerCase().trim() ?? '';
    return text == 'true' ||
        text == '1' ||
        text == 'yes' ||
        text == 'admin' ||
        text == 'owner' ||
        text == 'active';
  }

  bool _accountIsAdmin(String currentId, Map<String, dynamic>? account) {
    final id = _normalizeUserId(currentId);
    if (id == 'nawafrp') return true;
    if (account == null) return false;

    final role = (account['role'] ?? account['user_role'] ?? account['account_role'] ?? '').toString().toLowerCase().trim();
    return _truthy(account['is_admin']) ||
        _truthy(account['isAdmin']) ||
        _truthy(account['admin']) ||
        _truthy(account['is_super_admin']) ||
        _truthy(account['isSuperAdmin']) ||
        role == 'admin' ||
        role == 'owner' ||
        role == 'super_admin';
  }

  Future<void> _loadProfile({bool silent = false}) async {
    if (_profileRefreshBusy) return;
    _profileRefreshBusy = true;
    final previousAdminState = _isAdmin;
    try {
    final prefs = await SharedPreferences.getInstance();
    final currentId = prefs.getString('respect_current_user_id') ?? prefs.getString('current_user_id');
    if (currentId == null || currentId.trim().isEmpty) return;

    Map<String, dynamic>? account;

    try {
      final serverUser = await SupabaseService.currentUser();
      if (serverUser != null) {
        account = Map<String, dynamic>.from(serverUser);
        // مهم: لو فعلت is_admin من Supabase أثناء أن المستخدم مسجل دخول،
        // نحدّث الكاش المحلي فورًا حتى تظهر صفحة الإدارة بدون تسجيل خروج/دخول.
        try {
          await SupabaseService.saveCurrentUser(account);
        } catch (e) {
          _scannerSafeIgnore();
        }
      }
    } catch (e) {
      _scannerSafeIgnore();
    }

    final accountsRaw = prefs.getString('respect_accounts_v1');
    if (account == null && accountsRaw != null && accountsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(accountsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map &&
                _normalizeUserId((item['id'] ?? item['username'] ?? '').toString()) ==
                    _normalizeUserId(currentId)) {
              account = item.map((k, v) => MapEntry(k.toString(), v));
              break;
            }
          }
        }
      } catch (e) {
        _scannerSafeIgnore();
      }
    }

    if (account == null) {
      final usersRaw = prefs.getString('respect_users_map');
      if (usersRaw != null && usersRaw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(usersRaw);
          if (decoded is Map) {
            final direct = decoded[currentId];
            if (direct is Map) {
              account = direct.map((k, v) => MapEntry(k.toString(), v));
            } else {
              for (final item in decoded.values) {
                if (item is Map &&
                    _normalizeUserId((item['id'] ?? item['username'] ?? '').toString()) ==
                        _normalizeUserId(currentId)) {
                  account = item.map((k, v) => MapEntry(k.toString(), v));
                  break;
                }
              }
            }
          }
        } catch (e) {
          _scannerSafeIgnore();
        }
      }
    }

    if (!mounted) return;
    final resolvedAccount = account;
    if (resolvedAccount == null) {
      setState(() => _isAdmin = currentId.trim().toLowerCase().replaceAll('@', '') == 'nawafrp');
      return;
    }

    final image = (resolvedAccount['avatar_url'] ??
            resolvedAccount['profileImagePath'] ??
            resolvedAccount['imagePath'])
        ?.toString()
        .trim();
    final profileName = (resolvedAccount['profileName'] ??
            resolvedAccount['name'] ??
            'Respect App')
        .toString();
    final rawUsername = (resolvedAccount['username'] ??
            resolvedAccount['id'] ??
            'القائمة الرئيسية')
        .toString();
    final isAdmin = _accountIsAdmin(currentId, resolvedAccount);

    setState(() {
      _profileName = profileName;
      _profileUsername = rawUsername.startsWith('@') ? rawUsername : '@$rawUsername';
      _profileImagePath = image != null && image.isNotEmpty ? image : null;
      _isAdmin = isAdmin;
      if (!isAdmin && index == 6) index = 0;
    });

    if (silent && mounted && !previousAdminState && isAdmin) {
      NotificationService.showTopNotification(context.tr('تم تفعيل صلاحية الأدمن لحسابك'),
        title: 'Respect Admin',
        icon: Icons.admin_panel_settings_rounded,
      );
    }
    } finally {
      _profileRefreshBusy = false;
    }
  }

  String _cleanUsername(String value) {
    final v = value.trim().replaceAll(RegExp(r'\s+'), '_').replaceAll('@', '').toLowerCase();
    return v.isEmpty ? '@user' : '@$v';
  }

  Future<void> _loadUnreadMessagesCount() async {
    final prefs = await SharedPreferences.getInstance();
    final currentId = prefs.getString('respect_current_user_id') ?? prefs.getString('current_user_id');
    if (currentId == null || currentId.trim().isEmpty) return;

    String currentUsername = _cleanUsername(currentId);
    final accountsRaw = prefs.getString('respect_accounts_v1');
    if (accountsRaw != null && accountsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(accountsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map && (item['id'] ?? '').toString() == currentId) {
              currentUsername = _cleanUsername((item['username'] ?? item['id'] ?? currentId).toString());
              break;
            }
          }
        }
      } catch (e) {
        _scannerSafeIgnore();
      }
    }

    final lastReadRaw = prefs.getString('respect_dm_last_read_$currentUsername');
    final lastRead = DateTime.tryParse(lastReadRaw ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
    final messagesRaw = prefs.getString('respect_direct_messages_v1');
    int count = 0;

    if (messagesRaw != null && messagesRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(messagesRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final receiver = _cleanUsername((item['receiverUsername'] ?? '').toString());
            final sender = _cleanUsername((item['senderUsername'] ?? '').toString());
            final createdAt = DateTime.tryParse((item['createdAt'] ?? '').toString()) ?? DateTime.now();
            if (receiver == currentUsername && sender != currentUsername && createdAt.isAfter(lastRead)) {
              count++;
            }
          }
        }
      } catch (e) {
        _scannerSafeIgnore();
      }
    }

    if (!mounted) return;
    setState(() => _unreadMessagesCount = count);
  }

  Future<void> _markMessagesAsRead() async {
    final prefs = await SharedPreferences.getInstance();
    final currentId = prefs.getString('respect_current_user_id') ?? prefs.getString('current_user_id');
    if (currentId == null || currentId.trim().isEmpty) return;

    String currentUsername = _cleanUsername(currentId);
    final accountsRaw = prefs.getString('respect_accounts_v1');
    if (accountsRaw != null && accountsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(accountsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map && (item['id'] ?? '').toString() == currentId) {
              currentUsername = _cleanUsername((item['username'] ?? item['id'] ?? currentId).toString());
              break;
            }
          }
        }
      } catch (e) {
        _scannerSafeIgnore();
      }
    }

    await prefs.setString('respect_dm_last_read_$currentUsername', DateTime.now().toIso8601String());
    if (!mounted) return;
    setState(() => _unreadMessagesCount = 0);
  }

  Future<String> _currentUsernameForNotifications(SharedPreferences prefs) async {
    final currentId = prefs.getString('respect_current_user_id') ?? prefs.getString('current_user_id');
    if (currentId == null || currentId.trim().isEmpty) return '@user';
    try {
      final user = await SupabaseService.currentUser();
      if (user != null) return SupabaseService.displayUsername((user['username'] ?? currentId).toString());
    } catch (e) {
      _scannerSafeIgnore();
    }
    return _cleanUsername(currentId);
  }

  Future<Set<String>> _followedUsersFor(String currentUsername, SharedPreferences prefs) async {
    final raw = prefs.getString('respect_following_v1');
    if (raw == null || raw.trim().isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final list = decoded[currentUsername] ?? decoded[_cleanUsername(currentUsername)];
        if (list is List) return list.map((e) => _cleanUsername(e.toString())).toSet();
      }
    } catch (e) {
      _scannerSafeIgnore();
    }
    return <String>{};
  }

  Future<void> _loadUnreadNotificationsCount() async {
    final prefs = await SharedPreferences.getInstance();
    final currentUsername = await _currentUsernameForNotifications(prefs);
    final lastSeen = DateTime.tryParse(prefs.getString('respect_notifications_last_seen_$currentUsername') ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
    final followed = await _followedUsersFor(currentUsername, prefs);
    int count = 0;

    try {
      final mentions = await SupabaseService.getMentionNotificationsForUser(currentUsername);
      for (final m in mentions) {
        final createdAt = DateTime.tryParse((m['created_at'] ?? '').toString()) ?? DateTime.now();
        if (createdAt.isAfter(lastSeen)) count++;
      }
    } catch (e) {
      _scannerSafeIgnore();
    }

    try {
      final reposts = await SupabaseService.getRepostNotificationsForUser(currentUsername);
      for (final r in reposts) {
        final createdAt = DateTime.tryParse((r['created_at'] ?? '').toString()) ?? DateTime.now();
        if (createdAt.isAfter(lastSeen)) count++;
      }
    } catch (e) {
      _scannerSafeIgnore();
    }

    try {
      final events = await SupabaseService.getPostEventNotificationsForUser(currentUsername);
      for (final e in events) {
        final createdAt = DateTime.tryParse((e['created_at'] ?? '').toString()) ?? DateTime.now();
        if (createdAt.isAfter(lastSeen)) count++;
      }
    } catch (e) {
      _scannerSafeIgnore();
    }

    try {
      final posts = await SupabaseService.getPosts();
      for (final p in posts) {
        final author = _cleanUsername((p['username'] ?? '').toString());
        if (author == currentUsername || !followed.contains(author)) continue;
        final createdAt = DateTime.tryParse((p['created_at'] ?? '').toString()) ?? DateTime.now();
        if (createdAt.isAfter(lastSeen)) count++;
      }
    } catch (e) {
      _scannerSafeIgnore();
    }

    if (!mounted) return;
    setState(() => _unreadNotificationsCount = count);
  }

  Future<void> _markNotificationsAsRead() async {
    final prefs = await SharedPreferences.getInstance();
    final currentUsername = await _currentUsernameForNotifications(prefs);
    await prefs.setString('respect_notifications_last_seen_$currentUsername', DateTime.now().toIso8601String());
    if (!mounted) return;
    setState(() => _unreadNotificationsCount = 0);
  }

  ImageProvider? _profileImageProvider() {
    final path = _profileImagePath;
    if (path == null || path.trim().isEmpty) return null;
    final value = path.trim();

    if (value.startsWith('http://') || value.startsWith('https://')) {
      return NetworkImage(value);
    }

    final file = File(value);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  List<_MenuItem> get drawerItems => [
    const _MenuItem(title: 'بثوث ريسبكت', icon: Icons.sensors_rounded, pageIndex: 9),
    const _MenuItem(title: 'رسامين ريسبكت', icon: Icons.palette_rounded, pageIndex: 10),
    const _MenuItem(title: 'الإشعارات', icon: Icons.notifications, pageIndex: 3),
    const _MenuItem(title: 'المحفوظات', icon: Icons.bookmarks_rounded, pageIndex: 8),
    const _MenuItem(title: 'الإعدادات', icon: Icons.settings, pageIndex: 5),
    if (_isAdmin) const _MenuItem(title: 'الإدارة', icon: Icons.admin_panel_settings, pageIndex: 6),
  ];

  List<_BottomItem> get bottomItems => [
    const _BottomItem(title: 'الرئيسية', icon: Icons.home_rounded, pageIndex: 0),
    const _BottomItem(title: 'البحث', icon: Icons.search_rounded, pageIndex: 7),
    const _BottomItem(title: 'البثوث', icon: Icons.live_tv_rounded, pageIndex: 1),
    const _BottomItem(title: 'بثوث ريسبكت', icon: Icons.sensors_rounded, pageIndex: 9),
    const _BottomItem(title: 'رسامين', icon: Icons.palette_rounded, pageIndex: 10),
    const _BottomItem(title: 'الرسائل', icon: Icons.chat_bubble_rounded, pageIndex: 2),
    const _BottomItem(title: 'الإشعارات', icon: Icons.notifications_rounded, pageIndex: 3),
    const _BottomItem(title: 'حسابي', icon: Icons.person_rounded, pageIndex: 4),
    const _BottomItem(title: 'المحفوظات', icon: Icons.bookmarks_rounded, pageIndex: 8),
    const _BottomItem(title: 'الإعدادات', icon: Icons.settings_rounded, pageIndex: 5),
    if (_isAdmin) const _BottomItem(title: 'الإدارة', icon: Icons.admin_panel_settings_rounded, pageIndex: 6),
  ];

  void _changePage(int newIndex) {
    if (newIndex == 6 && !_isAdmin) {
      NotificationService.showTopNotification(context.tr('صفحة الإدارة متاحة للأدمن فقط'));
      return;
    }
    if (newIndex != 2 && _chatConversationActive) {
      _chatConversationActive = false;
    }
    if (newIndex == index) return;
    setState(() => index = newIndex);
    if (newIndex == 2) {
      _markMessagesAsRead().then((_) {
        if (mounted) _loadUnreadMessagesCount();
      });
    } else if (newIndex == 3) {
      _markNotificationsAsRead().then((_) {
        if (mounted) _loadUnreadNotificationsCount();
      });
    } else {
      _loadUnreadMessagesCount();
      _loadUnreadNotificationsCount();
    }
  }

  int _bottomSelectedIndex() {
    final i = bottomItems.indexWhere((item) => item.pageIndex == index);
    return i < 0 ? 0 : i;
  }

  void _setChatConversationActive(bool active) {
    if (!mounted || _chatConversationActive == active) return;
    setState(() => _chatConversationActive = active);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hideMainHeader = index == 2 && _chatConversationActive;

    return Scaffold(
      drawerEnableOpenDragGesture: false,
      appBar: hideMainHeader ? null : AppBar(
        title: null,
        leading: Padding(
          padding: const EdgeInsets.only(right: 8.0),
          child: InkWell(
            onTap: () => setState(() => index = 4),
            borderRadius: BorderRadius.circular(12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.purple.withValues(alpha: 0.25),
                  backgroundImage: _profileImageProvider(),
                  child: _profileImageProvider() == null
                      ? const Icon(Icons.person_rounded, color: Colors.white, size: 20)
                      : null,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText(
                        _profileName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      AppText(
                        _profileUsername,
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        leadingWidth: 220,
        elevation: 0,
        backgroundColor: isDark ? AppColors.darkBg.withValues(alpha: 0.85) : AppColors.lightBg.withValues(alpha: 0.9),
      ),
      body: IndexedStack(
        index: index,
        children: [
          const FeedScreen(),
          const StreamersScreen(),
          ChatScreen(onConversationActiveChanged: _setChatConversationActive),
          const NotificationsScreen(),
          ProfileScreen(onProfileUpdated: _refreshHeaderData),
          const SettingsScreen(),
          _isAdmin ? const AdminScreen() : const _AdminAccessDeniedScreen(),
          const SearchScreen(),
          const SavedPostsScreen(),
          const RespectLiveScreen(),
          const RespectPaintersScreen(),
        ],
      ),
      bottomNavigationBar: _BottomNavBar(
        items: bottomItems,
        selectedIndex: _bottomSelectedIndex(),
        unreadMessagesCount: _unreadMessagesCount,
        unreadNotificationsCount: _unreadNotificationsCount,
        onTap: (bottomIndex) {
          final items = bottomItems;
          if (bottomIndex < 0 || bottomIndex >= items.length) return;
          _changePage(items[bottomIndex].pageIndex);
        },
      ),
    );
  }
}

// ==================== كلاسات الواجهة (لم تتغير) ====================
class _BottomNavBar extends StatefulWidget {
  final List<_BottomItem> items;
  final int selectedIndex;
  final int unreadMessagesCount;
  final int unreadNotificationsCount;
  final ValueChanged<int> onTap;

  const _BottomNavBar({
    required this.items,
    required this.selectedIndex,
    required this.unreadMessagesCount,
    required this.unreadNotificationsCount,
    required this.onTap,
  });

  @override
  State<_BottomNavBar> createState() => _BottomNavBarState();
}

class _BottomNavBarState extends State<_BottomNavBar> {
  final ScrollController _scrollController = ScrollController();
  bool _showLeftArrow = false;
  bool _showRightArrow = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateArrowVisibility);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerSelectedItem();
      _updateArrowVisibility();
    });
  }

  @override
  void didUpdateWidget(covariant _BottomNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex || oldWidget.items.length != widget.items.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _centerSelectedItem();
        _updateArrowVisibility();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateArrowVisibility);
    _scrollController.dispose();
    super.dispose();
  }

  void _centerSelectedItem() {
    if (!_scrollController.hasClients || widget.items.isEmpty) return;
    const itemWidth = 88.0;
    final viewport = _scrollController.position.viewportDimension;
    final target = (widget.selectedIndex * itemWidth) - (viewport / 2) + (itemWidth / 2);
    final safeTarget = target.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      safeTarget.toDouble(),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    ).whenComplete(_updateArrowVisibility);
  }

  void _updateArrowVisibility() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final canGoRight = position.pixels > position.minScrollExtent + 2;
    final canGoLeft = position.pixels < position.maxScrollExtent - 2;

    if (_showRightArrow == canGoRight && _showLeftArrow == canGoLeft) return;
    if (!mounted) return;
    setState(() {
      _showRightArrow = canGoRight;
      _showLeftArrow = canGoLeft;
    });
  }

  void _scrollNav({required bool right}) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final delta = MediaQuery.of(context).size.width * 0.48;
    final target = (position.pixels + (right ? -delta : delta)).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target.toDouble(),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    ).whenComplete(_updateArrowVisibility);
  }

  Widget _dragHintArrow({
    required bool right,
    required bool isDark,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        borderRadius: BorderRadius.horizontal(
          right: right ? const Radius.circular(24) : Radius.zero,
          left: right ? Radius.zero : const Radius.circular(24),
        ),
        onTap: () => _scrollNav(right: right),
        child: Container(
          width: 38,
          height: double.infinity,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: right ? Alignment.centerRight : Alignment.centerLeft,
              end: right ? Alignment.centerLeft : Alignment.centerRight,
              colors: [
                isDark ? AppColors.darkCard.withValues(alpha: 0.98) : AppColors.lightCard.withValues(alpha: 0.98),
                isDark ? AppColors.darkCard.withValues(alpha: 0.0) : AppColors.lightCard.withValues(alpha: 0.0),
              ],
            ),
            borderRadius: BorderRadius.horizontal(
              right: right ? const Radius.circular(24) : Radius.zero,
              left: right ? Radius.zero : const Radius.circular(24),
            ),
          ),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: AppColors.purple.withValues(alpha: isDark ? 0.24 : 0.16),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.purple.withValues(alpha: 0.35)),
            ),
            child: Icon(
              right ? Icons.keyboard_arrow_right_rounded : Icons.keyboard_arrow_left_rounded,
              size: 22,
              color: AppColors.purple.withValues(alpha: 0.98),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Container(
        height: 78,
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard.withValues(alpha: 0.96) : AppColors.lightCard.withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
          boxShadow: [
            BoxShadow(
              color: AppColors.purple.withValues(alpha: isDark ? 0.18 : 0.1),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Stack(
          children: [
            Directionality(
              textDirection: context.appTextDirection,
              child: ListView.separated(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 22),
                itemCount: widget.items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final item = widget.items[i];
                  final selected = i == widget.selectedIndex;

                  return SizedBox(
                    width: 82,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => widget.onTap(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: selected ? AppColors.purple.withValues(alpha: 0.18) : Colors.transparent,
                          border: selected
                              ? Border.all(color: AppColors.purple.withValues(alpha: 0.35))
                              : Border.all(color: Colors.transparent),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _BottomIconWithBadge(
                              icon: item.icon,
                              showBadge: (item.pageIndex == 2 && widget.unreadMessagesCount > 0) ||
                                  (item.pageIndex == 3 && widget.unreadNotificationsCount > 0),
                              count: item.pageIndex == 3 ? widget.unreadNotificationsCount : widget.unreadMessagesCount,
                              selected: selected,
                              isDark: isDark,
                            ),
                            const SizedBox(height: 3),
                            AppText(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                                color: selected ? AppColors.purple : (isDark ? AppColors.darkMuted : AppColors.lightMuted),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_showLeftArrow)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _dragHintArrow(right: false, isDark: isDark),
              ),
            if (_showRightArrow)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _dragHintArrow(right: true, isDark: isDark),
              ),
          ],
        ),
      ),
    );
  }
}

class _BottomIconWithBadge extends StatelessWidget {
  final IconData icon;
  final bool showBadge;
  final int count;
  final bool selected;
  final bool isDark;

  const _BottomIconWithBadge({
    required this.icon,
    required this.showBadge,
    required this.count,
    required this.selected,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(
          icon,
          size: 22,
          color: selected ? AppColors.purple : (isDark ? AppColors.darkMuted : AppColors.lightMuted),
        ),
        if (showBadge)
          PositionedDirectional(
            top: -8,
            end: -11,
            child: Container(
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.danger,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: isDark ? AppColors.darkCard : AppColors.lightCard, width: 2),
              ),
              child: AppText(
                count > 99 ? '99+' : '$count',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900, height: 1),
              ),
            ),
          ),
      ],
    );
  }
}

class _AdminAccessDeniedScreen extends StatelessWidget {
  const _AdminAccessDeniedScreen();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const AppText('الإدارة', style: TextStyle(fontWeight: FontWeight.w900))),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_rounded, color: AppColors.purple, size: 72),
              const SizedBox(height: 14),
              const AppText('هذه الصفحة للأدمن فقط', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              AppText(
                'يجب ترقية حسابك من لوحة الإدارة حتى تظهر لك هذه الصفحة.',
                textAlign: TextAlign.center,
                style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppSideBar extends StatelessWidget {
  final int currentIndex;
  final List<_MenuItem> items;
  final ValueChanged<int> onItemTap;
  final String profileName;
  final String profileUsername;
  final ImageProvider? profileImage;
  final VoidCallback onProfileTap;

  const _AppSideBar({
    required this.currentIndex,
    required this.items,
    required this.onItemTap,
    required this.profileName,
    required this.profileUsername,
    required this.profileImage,
    required this.onProfileTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final width = MediaQuery.of(context).size.width;

    return Directionality(
      textDirection: context.appTextDirection,
      child: Drawer(
        width: width > 420 ? 330 : width * 0.82,
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBg : AppColors.lightBg,
            border: Border(
              right: BorderSide(
                color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
                blurRadius: 35,
                offset: const Offset(8, 0),
              ),
            ],
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                  child: Row(
                    children: [
                      InkWell(
                        onTap: onProfileTap,
                        borderRadius: BorderRadius.circular(99),
                        child: CircleAvatar(
                          radius: 27,
                          backgroundColor: AppColors.purple,
                          backgroundImage: profileImage,
                          child: profileImage == null
                              ? const Icon(Icons.person_rounded, color: Colors.white, size: 30)
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: InkWell(
                          onTap: onProfileTap,
                          borderRadius: BorderRadius.circular(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppText(
                                profileName,
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 2),
                              AppText(
                                profileUsername,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: Icon(
                          Icons.close_rounded,
                          color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final item = items[i];
                      final selected = item.pageIndex == currentIndex;

                      return _SideBarTile(
                        item: item,
                        selected: selected,
                        onTap: () => onItemTap(item.pageIndex),
                      );
                    },
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

class _SideBarTile extends StatelessWidget {
  final _MenuItem item;
  final bool selected;
  final VoidCallback onTap;

  const _SideBarTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: selected
              ? const LinearGradient(
            colors: [AppColors.purple, Color(0xFF6D28D9)],
          )
              : null,
          color: selected ? null : (isDark ? AppColors.darkCard.withValues(alpha: 0.72) : AppColors.lightCard),
          border: Border.all(
            color: selected
                ? AppColors.purple.withValues(alpha: 0.45)
                : (isDark ? AppColors.darkBorder : AppColors.lightBorder),
          ),
          boxShadow: selected
              ? [
            BoxShadow(
              color: AppColors.purple.withValues(alpha: 0.28),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          ]
              : [],
        ),
        child: Row(
          children: [
            Icon(
              item.icon,
              color: selected ? Colors.white : AppColors.purple,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AppText(
                item.title,
                style: TextStyle(
                  color: selected ? Colors.white : (isDark ? Colors.white : Colors.black87),
                  fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            Icon(
              selected ? Icons.check_circle_rounded : Icons.arrow_back_ios_new_rounded,
              size: selected ? 20 : 15,
              color: selected ? Colors.white : (isDark ? AppColors.darkMuted : AppColors.lightMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuItem {
  final String title;
  final IconData icon;
  final int pageIndex;

  const _MenuItem({required this.title, required this.icon, required this.pageIndex});
}

class _BottomItem {
  final String title;
  final IconData icon;
  final int pageIndex;

  const _BottomItem({required this.title, required this.icon, required this.pageIndex});
}
