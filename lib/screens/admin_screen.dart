import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../services/supabase_service.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  static const String _usersKey = 'respect_users_map';
  static const String _accountsKey = 'respect_accounts_v1';
  static const String _postsKey = 'respect_city_posts_v1';
  static const String _communitiesKey = 'respect_communities_v1';
  static const String _followingKey = 'respect_following_v1';
  static const String _blockedKey = 'respect_blocked_users_v1';
  static const String _currentUserKey = 'respect_current_user_id';
  static const String _legacyCurrentUserKey = 'current_user_id';
  static const String _postReportsKey = 'respect_post_reports_v1';
  static const String _primaryAdminId = 'nawafrp';
  static const String _primaryAdminPassword = '123456789';

  final TextEditingController _searchCtrl = TextEditingController();

  bool _loading = true;
  String _query = '';

  Map<String, dynamic> _usersMap = <String, dynamic>{};
  List<Map<String, dynamic>> _accounts = <Map<String, dynamic>>[];
  List<dynamic> _posts = <dynamic>[];
  List<dynamic> _communities = <dynamic>[];
  List<Map<String, dynamic>> _postReports = <Map<String, dynamic>>[];
  final Set<String> _reviewingReportIds = <String>{};
  Map<String, dynamic> _following = <String, dynamic>{};
  Set<String> _blocked = <String>{};

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text.trim().toLowerCase()));
    _loadAdminData();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAdminData() async {
    if (mounted) setState(() => _loading = true);

    final prefs = await SharedPreferences.getInstance();

    final usersRaw = prefs.getString(_usersKey);
    final accountsRaw = prefs.getString(_accountsKey);
    final postsRaw = prefs.getString(_postsKey);
    final communitiesRaw = prefs.getString(_communitiesKey);
    final followingRaw = prefs.getString(_followingKey);
    final blockedRaw = prefs.getString(_blockedKey);
    final reportsRaw = prefs.getString(_postReportsKey);

    final users = _decodeMap(usersRaw);
    final accounts = _decodeList(accountsRaw)
        .whereType<Map>()
        .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
        .toList();

    if (users.isEmpty && accounts.isNotEmpty) {
      for (final acc in accounts) {
        final id = _userIdFrom(acc);
        if (id.isEmpty) continue;
        users[id] = {
          ...acc,
          'id': id,
          'username': _cleanUsername((acc['username'] ?? id).toString()),
          'name': (acc['name'] ?? acc['profileName'] ?? id).toString(),
        };
      }
    }

    // نقرأ المستخدمين من Supabase حتى تظهر حالات is_admin / is_blocked / device_banned مباشرة.
    try {
      final serverUsers = await SupabaseService.getUsers();
      for (final u in serverUsers) {
        final id = _userIdFrom(u);
        if (id.isEmpty) continue;
        users[id] = {
          ..._asStringMap(users[id]),
          ...u,
          'id': id,
          'username': _cleanUsername((u['username'] ?? id).toString()),
          'name': (u['name'] ?? u['profileName'] ?? id).toString(),
        };
      }
    } catch (_) {}

    _ensurePrimaryAdminUser(users);

    final blockedSet = _decodeBlocked(blockedRaw);
    blockedSet.remove(_primaryAdminId);
    blockedSet.remove(_cleanUsername(_primaryAdminId));
    for (final entry in users.entries) {
      final user = _asStringMap(entry.value);
      if (_isBlockedMap(user)) {
        blockedSet.add(_userIdFrom({...user, 'id': entry.key}));
        blockedSet.add(_cleanUsername((user['username'] ?? entry.key).toString()));
      }
    }

    if (!mounted) return;
    setState(() {
      _usersMap = users;
      _accounts = accounts;
      _posts = _decodeList(postsRaw);
      _communities = _decodeList(communitiesRaw);
      _postReports = _decodeList(reportsRaw).whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))).toList();
      _following = _decodeMap(followingRaw);
      _blocked = blockedSet.where((e) => e.trim().isNotEmpty).toSet();
      _loading = false;
    });
  }

  Map<String, dynamic> _decodeMap(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {}
    return <String, dynamic>{};
  }

  List<dynamic> _decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <dynamic>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
    } catch (_) {}
    return <dynamic>[];
  }

  Set<String> _decodeBlocked(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toSet();
      if (decoded is Map) return decoded.keys.map((e) => e.toString()).toSet();
    } catch (_) {}
    return <String>{};
  }

  Map<String, dynamic> _asStringMap(dynamic raw) {
    if (raw is Map) return raw.map((k, v) => MapEntry(k.toString(), v));
    return <String, dynamic>{};
  }

  void _ensurePrimaryAdminUser(Map<String, dynamic> users) {
    final now = DateTime.now().toIso8601String();
    final existing = _asStringMap(users[_primaryAdminId]);
    users[_primaryAdminId] = {
      ...existing,
      'id': _primaryAdminId,
      'username': _cleanUsername(_primaryAdminId),
      'password': (existing['password'] ?? _primaryAdminPassword).toString().isEmpty
          ? _primaryAdminPassword
          : existing['password'],
      'name': (existing['name'] ?? existing['profileName'] ?? 'Nawaf RP').toString(),
      'profileName': (existing['profileName'] ?? existing['name'] ?? 'Nawaf RP').toString(),
      'bio': (existing['bio'] ?? 'Respect App admin').toString(),
      'isAdmin': true,
      'role': 'admin',
      'isBlocked': false,
      'blocked': false,
      'banned': false,
      'disabled': false,
      'canLogin': true,
      'blockedReason': '',
      'createdAt': existing['createdAt'] ?? now,
      'updatedAt': now,
    };
  }


  List<_AdminUser> get _users {
    final list = <_AdminUser>[];

    _usersMap.forEach((key, value) {
      final map = _asStringMap(value);
      if (map.isEmpty) return;
      final merged = {...map, 'id': (map['id'] ?? key).toString()};
      list.add(_AdminUser.fromMap(merged, blockedList: _blocked));
    });

    final knownIds = list.map((u) => u.id).toSet();
    for (final account in _accounts) {
      final id = _userIdFrom(account);
      if (id.isEmpty || knownIds.contains(id)) continue;
      list.add(_AdminUser.fromMap(account, blockedList: _blocked));
    }

    list.sort((a, b) {
      if (a.isBlocked != b.isBlocked) return a.isBlocked ? -1 : 1;
      if (a.isAdmin != b.isAdmin) return a.isAdmin ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    if (_query.isEmpty) return list;

    return list.where((u) {
      final haystack = '${u.id} ${u.name} ${u.username} ${u.streamUrl} ${u.role}'.toLowerCase();
      return haystack.contains(_query);
    }).toList();
  }

  int get _streamersCount {
    final ids = <String>{};
    for (final u in _users) {
      if (u.streamUrl.trim().isNotEmpty) ids.add(u.id);
    }
    for (final acc in _accounts) {
      if ((acc['streamUrl'] ?? '').toString().trim().isNotEmpty) ids.add(_userIdFrom(acc));
    }
    ids.removeWhere((e) => e.trim().isEmpty);
    return ids.length;
  }

  int get _liveStreamersCount {
    var count = 0;
    final seen = <String>{};
    for (final acc in _accounts) {
      final id = _userIdFrom(acc);
      if (id.isEmpty || seen.contains(id)) continue;
      final live = acc['streamIsLive'] == true || acc['streamIsLive']?.toString() == 'true';
      final hasUrl = (acc['streamUrl'] ?? '').toString().trim().isNotEmpty;
      if (hasUrl && live) {
        seen.add(id);
        count++;
      }
    }
    return count;
  }

  int get _reportsCount {
    var total = _postReports.length;

    for (final post in _posts) {
      final map = _asStringMap(post);
      final reports = map['reports'] ?? map['reportCount'] ?? map['reportsCount'];
      if (reports is List) total += reports.length;
      if (reports is int) total += reports;
      if (reports is String) total += int.tryParse(reports) ?? 0;
      if (map['isReported'] == true || map['reported'] == true) total++;
    }

    for (final user in _users) {
      if (user.isReported) total++;
    }

    return total;
  }

  int get _messagesCount {
    var count = 0;
    for (final c in _communities) {
      final map = _asStringMap(c);
      final messages = map['messages'];
      if (messages is List) count += messages.length;
    }
    return count;
  }

  String _formatNumber(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(value >= 10000000 ? 0 : 1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(value >= 10000 ? 0 : 1)}K';
    return value.toString();
  }

  static String _cleanUsername(String value) {
    final clean = value.trim().replaceAll(RegExp(r'\s+'), '_');
    if (clean.isEmpty) return '@user';
    return clean.startsWith('@') ? clean : '@$clean';
  }

  static String _cleanId(String value) {
    return value.trim().replaceAll('@', '').replaceAll(RegExp(r'\s+'), '_').toLowerCase();
  }

  static String _userIdFrom(Map<String, dynamic> map) {
    final raw = (map['id'] ?? map['userId'] ?? map['uid'] ?? map['username'] ?? '').toString();
    return _cleanId(raw);
  }

  bool _isBlockedMap(Map<String, dynamic> map) {
    return map['isBlocked'] == true ||
        map['blocked'] == true ||
        map['banned'] == true ||
        map['disabled'] == true ||
        map['canLogin'] == false ||
        map['device_banned'] == true ||
        map['device_blocked'] == true ||
        _blocked.contains(_userIdFrom(map)) ||
        _blocked.contains(_cleanUsername((map['username'] ?? map['id'] ?? '').toString()));
  }

  Future<void> _saveAll() async {
    _ensurePrimaryAdminUser(_usersMap);
    _blocked.remove(_primaryAdminId);
    _blocked.remove(_cleanUsername(_primaryAdminId));
    await _syncAccountFromUser(_primaryAdminId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usersKey, jsonEncode(_usersMap));
    await prefs.setString(_accountsKey, jsonEncode(_accounts));
    await prefs.setString(_blockedKey, jsonEncode(_blocked.toList()..sort()));
  }

  Future<void> _syncAccountFromUser(String userId) async {
    final user = _asStringMap(_usersMap[userId]);
    if (user.isEmpty) return;

    final idx = _accounts.indexWhere((a) => _userIdFrom(a) == userId);
    final normalized = {
      ...user,
      'id': userId,
      'profileName': (user['profileName'] ?? user['name'] ?? 'User').toString(),
      'username': _cleanUsername((user['username'] ?? userId).toString()),
      'imagePath': (user['imagePath'] ?? user['profileImagePath'])?.toString(),
      'streamName': (user['streamName'] ?? user['streamerName'] ?? '').toString(),
      'streamUrl': (user['streamUrl'] ?? '').toString(),
      'isBlocked': user['isBlocked'] == true || user['is_blocked'] == true,
      'device_banned': user['device_banned'] == true || user['device_blocked'] == true,
      'device_id': (user['device_id'] ?? user['current_device_id'] ?? user['last_device_id'] ?? '').toString(),
      'current_device_id': (user['current_device_id'] ?? user['device_id'] ?? user['last_device_id'] ?? '').toString(),
      'blocked': user['blocked'] == true,
      'banned': user['banned'] == true,
      'canLogin': user['canLogin'] != false,
      'role': (user['role'] ?? 'user').toString(),
      'isAdmin': user['isAdmin'] == true || user['is_admin'] == true || user['admin'] == true,
    };

    if (idx >= 0) {
      _accounts[idx] = {..._accounts[idx], ...normalized};
    } else {
      _accounts.add(normalized);
    }
  }

  Future<void> _setUserBlocked(_AdminUser user, bool blocked, {String reason = ''}) async {
    final id = user.id;
    if (id == _primaryAdminId && blocked) {
      _snack('لا يمكن حظر حساب الأدمن الأساسي nawafrp');
      return;
    }
    final existing = _asStringMap(_usersMap[id]);
    final now = DateTime.now().toIso8601String();

    final updated = {
      ...existing,
      'id': id,
      'username': user.username,
      'name': existing['name'] ?? user.name,
      'profileName': existing['profileName'] ?? user.name,
      'isBlocked': blocked,
      'blocked': blocked,
      'banned': blocked,
      'disabled': blocked,
      'canLogin': !blocked,
      'device_banned': blocked,
      'device_blocked': blocked,
      'blockedAt': blocked ? now : null,
      'blockedReason': blocked ? (reason.trim().isEmpty ? 'Blocked by admin' : reason.trim()) : '',
      'updatedAt': now,
    };

    _usersMap[id] = updated;
    if (blocked) {
      _blocked
        ..add(id)
        ..add(user.username);
    } else {
      _blocked
        ..remove(id)
        ..remove(user.username);
    }

    await _syncAccountFromUser(id);
    await _saveAll();

    try {
      final adminUser = await SupabaseService.currentUser();
      await SupabaseService.setUserBlockedAndDeviceBan(
        username: user.username,
        blocked: blocked,
        reason: reason,
        adminUsername: (adminUser?['username'] ?? 'admin').toString(),
      );
    } catch (e) {
      _snack('تم تحديث الحظر محليًا، لكن تعذر مزامنته مع السيرفر: ${e.toString().replaceFirst('Exception: ', '')}');
    }

    final prefs = await SharedPreferences.getInstance();
    final currentId = prefs.getString(_currentUserKey) ?? prefs.getString(_legacyCurrentUserKey);
    if (blocked && currentId != null && _cleanId(currentId) == id) {
      await prefs.remove(_currentUserKey);
      await prefs.remove(_legacyCurrentUserKey);
    }

    if (!mounted) return;
    setState(() {});
    _snack(blocked ? 'تم حظر ${user.name} بالكامل' : 'تم إلغاء حظر ${user.name}');
  }

  Future<void> _setUserAdmin(_AdminUser user, bool admin) async {
    final id = user.id;
    if (id == _primaryAdminId && !admin) {
      _snack('لا يمكن إزالة صلاحية الأدمن من nawafrp');
      return;
    }
    final existing = _asStringMap(_usersMap[id]);
    final updated = {
      ...existing,
      'id': id,
      'username': user.username,
      'name': existing['name'] ?? user.name,
      'profileName': existing['profileName'] ?? user.name,
      'isAdmin': admin,
      'role': admin ? 'admin' : 'user',
      'updatedAt': DateTime.now().toIso8601String(),
    };

    _usersMap[id] = updated;
    await _syncAccountFromUser(id);
    await _saveAll();

    if (!mounted) return;
    setState(() {});
    _snack(admin ? 'تمت ترقية ${user.name} إلى أدمن' : 'تم إرجاع ${user.name} كمستخدم عادي');
  }

  Future<void> _deleteUserContent(_AdminUser user) async {
    final ok = await _confirm(
      title: 'حذف محتوى المستخدم؟',
      message: 'سيتم حذف منشورات المستخدم وإزالته من المتابعات والمجتمعات. الحساب نفسه سيبقى موجودًا.',
      danger: true,
    );
    if (!ok) return;

    final prefs = await SharedPreferences.getInstance();
    final username = user.username;

    _posts.removeWhere((post) {
      final map = _asStringMap(post);
      return _cleanUsername((map['username'] ?? '').toString()) == username;
    });

    _following.remove(username);
    _following.updateAll((key, value) {
      if (value is List) return value.where((e) => _cleanUsername(e.toString()) != username).toList();
      return value;
    });

    for (var i = 0; i < _communities.length; i++) {
      final map = _asStringMap(_communities[i]);
      if (map.isEmpty) continue;
      final members = (map['members'] is List ? map['members'] as List : const [])
          .where((e) => _cleanUsername(e.toString()) != username)
          .toList();
      final moderators = (map['moderators'] is List ? map['moderators'] as List : const [])
          .where((e) => _cleanUsername(e.toString()) != username)
          .toList();
      _communities[i] = {...map, 'members': members, 'moderators': moderators};
    }

    await prefs.setString(_postsKey, jsonEncode(_posts));
    await prefs.setString(_followingKey, jsonEncode(_following));
    await prefs.setString(_communitiesKey, jsonEncode(_communities));

    if (!mounted) return;
    setState(() {});
    _snack('تم حذف محتوى ${user.name}');
  }

  Future<void> _showBlockSheet(_AdminUser user) async {
    final reasonCtrl = TextEditingController(text: user.blockedReason);
    final blocked = user.isBlocked;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
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
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: blocked ? AppColors.danger : AppColors.purple,
                    backgroundImage: _avatarProvider(user.avatarPath),
                    child: _avatarProvider(user.avatarPath) == null
                        ? Text(user.name.isEmpty ? '?' : user.name.characters.first,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20))
                        : null,
                  ),
                  const SizedBox(height: 10),
                  Text(user.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                  Text(user.username, style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (blocked || user.deviceBanned ? AppColors.danger : AppColors.purple).withOpacity(0.10),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: (blocked || user.deviceBanned ? AppColors.danger : AppColors.purple).withOpacity(0.25)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.phone_android_rounded, color: blocked || user.deviceBanned ? AppColors.danger : AppColors.purple),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            user.deviceId.trim().isEmpty
                                ? 'لا يوجد جهاز مسجل لهذا المستخدم حتى الآن'
                                : 'الجهاز المسجل: ${user.deviceId}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: reasonCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.notes_rounded),
                      hintText: 'سبب الحظر',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: blocked ? AppColors.success : AppColors.danger,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            minimumSize: const Size.fromHeight(50),
                          ),
                          icon: Icon(blocked ? Icons.lock_open_rounded : Icons.block_rounded),
                          label: Text(blocked ? 'إلغاء الحظر' : 'حظر الحساب والجهاز',
                              style: const TextStyle(fontWeight: FontWeight.w900)),
                          onPressed: () async {
                            Navigator.pop(context);
                            await _setUserBlocked(user, !blocked, reason: reasonCtrl.text);
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            minimumSize: const Size.fromHeight(50),
                          ),
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('إلغاء', style: TextStyle(fontWeight: FontWeight.w900)),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    reasonCtrl.dispose();
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: danger ? AppColors.danger : AppColors.purple,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('تأكيد'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  String _reportValue(Map<String, dynamic> report, String key, [String fallback = '']) {
    return (report[key] ?? fallback).toString();
  }


  Map<String, dynamic>? _postMapForReport(Map<String, dynamic> report) {
    final postId = _reportValue(report, 'postId', _reportValue(report, 'post_id'));
    if (postId.trim().isEmpty) return null;

    for (final raw in _posts) {
      final map = _asStringMap(raw);
      if (map.isEmpty) continue;
      final id = (map['id'] ?? map['postId'] ?? map['post_id'] ?? '').toString();
      if (id == postId) return map;
    }
    return null;
  }

  Future<void> _openReportDetails(Map<String, dynamic> report) async {
    final id = _reportValue(report, 'id');
    final postId = _reportValue(report, 'postId', _reportValue(report, 'post_id'));
    final reviewKey = id.isEmpty ? postId : id;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ReportDetailsScreen(
          report: report,
          post: _postMapForReport(report),
          reviewing: _reviewingReportIds.contains(reviewKey),
          onReview: () => _reviewReportWithRespectAi(report),
          onDelete: () async {
            await _deleteReport(report);
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
    );
  }

  Future<void> _reviewReportWithRespectAi(Map<String, dynamic> report) async {
    final id = _reportValue(report, 'id');
    final postId = _reportValue(report, 'postId', _reportValue(report, 'post_id'));
    final reporter = _reportValue(report, 'reporterUsername', _reportValue(report, 'reporter_username', '@user'));
    final reported = _reportValue(report, 'postUsername', _reportValue(report, 'post_username', _reportValue(report, 'postUser', '@user')));
    final reason = _reportValue(report, 'type', _reportValue(report, 'reason', 'بلاغ'));
    final details = _reportValue(report, 'details');
    final postText = _reportValue(report, 'postText', _reportValue(report, 'post_text'));
    final communityId = _reportValue(report, 'communityId', _reportValue(report, 'community_id'));
    final communityName = _reportValue(report, 'communityName', _reportValue(report, 'community_name'));

    if (postId.trim().isEmpty) {
      _snack('لا يوجد معرف للتغريدة داخل البلاغ');
      return;
    }

    if (mounted) setState(() => _reviewingReportIds.add(id.isEmpty ? postId : id));
    try {
      final result = await SupabaseService.reviewPostReportWithAi(
        reportId: id,
        postId: postId,
        reporterUsername: reporter,
        reportedUsername: reported,
        reason: reason,
        details: details,
        postText: postText,
        communityId: communityId,
        communityName: communityName,
      );

      final valid = result['validReport'] == true || result['shouldDelete'] == true;
      final aiReason = (result['reason'] ?? '').toString().trim();
      final cleanReason = aiReason.isEmpty ? reason : aiReason;

      final index = _postReports.indexWhere((r) => (r['id'] ?? '').toString() == id);
      if (index >= 0) {
        _postReports[index] = {
          ..._postReports[index],
          'status': valid ? 'accepted' : 'rejected',
          'aiStatus': valid ? 'accepted' : 'rejected',
          'aiDecision': valid ? 'accepted' : 'rejected',
          'aiReason': cleanReason,
          'reviewedAt': DateTime.now().toIso8601String(),
        };
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_postReportsKey, jsonEncode(_postReports));

      if (mounted) setState(() {});
      _snack(valid ? 'تم قبول البلاغ وحذف التغريدة' : 'تم رفض البلاغ والتغريدة سليمة');
    } catch (e) {
      _snack('تعذرت مراجعة البلاغ: $e');
    } finally {
      if (mounted) setState(() => _reviewingReportIds.remove(id.isEmpty ? postId : id));
    }
  }

  Future<void> _deleteReport(Map<String, dynamic> report) async {
    final id = (report['id'] ?? '').toString();
    if (id.isEmpty) return;
    setState(() => _postReports.removeWhere((r) => (r['id'] ?? '').toString() == id));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_postReportsKey, jsonEncode(_postReports));
    _snack('تم حذف البلاغ');
  }

  Future<void> _clearReports() async {
    final ok = await _confirm(
      title: 'حذف كل البلاغات؟',
      message: 'سيتم حذف سجل بلاغات التغريدات بالكامل من لوحة الإدارة.',
      danger: true,
    );
    if (!ok) return;
    setState(() => _postReports.clear());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_postReportsKey, jsonEncode(_postReports));
    _snack('تم حذف كل البلاغات');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  ImageProvider? _avatarProvider(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  @override
  Widget build(BuildContext context) {
    final users = _users;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: null,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.purple))
          : RefreshIndicator(
        color: AppColors.purple,
        onRefresh: _loadAdminData,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
          children: [
            _AdminHeader(
              users: _users.length,
              blocked: _users.where((u) => u.isBlocked).length,
              admins: _users.where((u) => u.isAdmin).length,
            ).animate().fadeIn(duration: 250.ms).slideY(begin: -0.02),
            const SizedBox(height: 12),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.38,
              children: [
                _StatCard(
                  title: 'المستخدمين',
                  value: _formatNumber(_users.length),
                  icon: Icons.people_alt_rounded,
                  subtitle: '${_users.where((u) => !u.isBlocked).length} نشط',
                ),
                _StatCard(
                  title: 'المنشورات',
                  value: _formatNumber(_posts.length),
                  icon: Icons.article_rounded,
                  subtitle: '${_formatNumber(_messagesCount)} رسالة مجتمع',
                ),
                _StatCard(
                  title: 'الستريمرز',
                  value: _formatNumber(_streamersCount),
                  icon: Icons.live_tv_rounded,
                  subtitle: '$_liveStreamersCount مباشر الآن',
                ),
                _StatCard(
                  title: 'بلاغات/محظورين',
                  value: _formatNumber(_reportsCount + _users.where((u) => u.isBlocked).length),
                  icon: Icons.report_rounded,
                  subtitle: '${_formatNumber(_postReports.length)} بلاغ · ${_users.where((u) => u.isBlocked).length} محظور',
                  danger: _reportsCount > 0 || _users.any((u) => u.isBlocked),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text('بلاغات التغريدات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
                ),
                if (_postReports.isNotEmpty)
                  TextButton.icon(
                    onPressed: _clearReports,
                    icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                    label: const Text('حذف الكل'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_postReports.isEmpty)
              GlassCard(
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: AppColors.success.withOpacity(0.14), shape: BoxShape.circle),
                      child: const Icon(Icons.verified_rounded, color: AppColors.success),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text('لا توجد بلاغات حالياً', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700))),
                  ],
                ),
              )
            else
              ...List.generate(_postReports.take(6).length, (i) {
                final report = _postReports[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ReportCard(
                    report: report,
                    reviewing: _reviewingReportIds.contains((report['id'] ?? report['postId'] ?? '').toString()),
                    onOpen: () => _openReportDetails(report),
                    onReview: () => _reviewReportWithRespectAi(report),
                    onDelete: () => _deleteReport(report),
                  ),
                );
              }),
            const SizedBox(height: 16),
            TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'بحث عن مستخدم، اسم، يوزر، رابط بث...',
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                  onPressed: _searchCtrl.clear,
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Expanded(
                  child: Text('إدارة المستخدمين',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                ),
                Text('${users.length} نتيجة',
                    style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
              ],
            ),
            const SizedBox(height: 10),
            if (users.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 80),
                child: Center(
                  child: Text('لا يوجد مستخدمين',
                      style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                ),
              )
            else
              ...List.generate(users.length, (i) {
                final user = users[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _UserAdminCard(
                    user: user,
                    avatarProvider: _avatarProvider(user.avatarPath),
                    onBlock: () => _showBlockSheet(user),
                    onAdmin: () => _setUserAdmin(user, !user.isAdmin),
                    onDeleteContent: () => _deleteUserContent(user),
                  ),
                ).animate().fadeIn(delay: (35 * i).ms).slideY(begin: 0.025);
              }),
          ],
        ),
      ),
    );
  }
}



class _ReportDetailsScreen extends StatelessWidget {
  final Map<String, dynamic> report;
  final Map<String, dynamic>? post;
  final bool reviewing;
  final Future<void> Function() onReview;
  final Future<void> Function() onDelete;

  const _ReportDetailsScreen({
    required this.report,
    required this.post,
    required this.reviewing,
    required this.onReview,
    required this.onDelete,
  });

  String _value(String key, [String fallback = '']) => (report[key] ?? fallback).toString();
  String _postValue(String key, [String fallback = '']) => (post?[key] ?? fallback).toString();

  String get _postId => _value('postId', _value('post_id', _postValue('id')));
  String get _postUser => _value('postUsername', _value('postUser', _value('post_username', _postValue('username', '@user'))));
  String get _reporter => _value('reporterUsername', _value('reporter_username', '@unknown'));
  String get _reason => _value('type', _value('reason', 'بلاغ'));
  String get _details => _value('details', _value('description'));
  String get _postText {
    final fromReport = _value('postText', _value('post_text'));
    if (fromReport.trim().isNotEmpty) return fromReport;
    return _postValue('text', 'تغريدة تحتوي على وسائط فقط');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    final status = _value('status', _value('aiStatus', 'pending'));
    final aiReason = _value('aiReason');
    final communityName = _value('communityName', _value('community_name'));
    final createdAt = _value('createdAt', _value('created_at'));
    final mediaPath = _value('mediaPath', _value('imageUrl', _value('image_url', _postValue('image_url', _postValue('mediaPath')))));
    final videoPath = _value('videoUrl', _value('video_url', _postValue('video_url')));

    return Scaffold(
      appBar: AppBar(
        title: const Text('تفاصيل البلاغ', style: TextStyle(fontWeight: FontWeight.w900)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: AppColors.purple.withOpacity(0.16),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.article_rounded, color: AppColors.purple),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('التغريدة المبلّغ عنها', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                          const SizedBox(height: 2),
                          Text('صاحب التغريدة: $_postUser', style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                  ),
                  child: Text(
                    _postText.trim().isEmpty ? 'تغريدة تحتوي على وسائط فقط' : _postText,
                    style: const TextStyle(fontSize: 15, height: 1.55, fontWeight: FontWeight.w700),
                  ),
                ),
                if (mediaPath.trim().isNotEmpty || videoPath.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(videoPath.trim().isNotEmpty ? Icons.videocam_rounded : Icons.image_rounded, color: AppColors.purple, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          videoPath.trim().isNotEmpty ? 'التغريدة تحتوي على فيديو مرفق' : 'التغريدة تحتوي على صورة مرفقة',
                          style: TextStyle(color: muted, fontWeight: FontWeight.w800, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MiniChip(text: _postId.trim().isEmpty ? 'بدون ID' : 'ID: $_postId', color: AppColors.purple),
                    if (createdAt.trim().isNotEmpty) _MiniChip(text: createdAt.split('T').first, color: muted),
                    if (communityName.trim().isNotEmpty) _MiniChip(text: communityName, color: AppColors.success),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: AppColors.danger.withOpacity(0.16),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.report_rounded, color: AppColors.danger),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('البلاغ', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                          const SizedBox(height: 2),
                          Text('المبلّغ: $_reporter', style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _DetailLine(label: 'نوع البلاغ', value: _reason),
                const SizedBox(height: 10),
                _DetailLine(label: 'تفاصيل البلاغ', value: _details.trim().isEmpty ? 'لا توجد تفاصيل إضافية' : _details),
                if (aiReason.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: status == 'accepted' ? AppColors.danger.withOpacity(0.10) : AppColors.success.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      status == 'accepted'
                          ? 'قرار Respect AI: البلاغ صحيح\n$aiReason'
                          : 'قرار Respect AI: البلاغ غير مؤكد\n$aiReason',
                      style: TextStyle(
                        color: status == 'accepted' ? AppColors.danger : AppColors.success,
                        fontWeight: FontWeight.w900,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: reviewing ? null : onReview,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.purple,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                ),
                icon: reviewing
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.smart_toy_rounded),
                label: Text(reviewing ? 'جاري المراجعة...' : 'مراجعة Respect AI', style: const TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'حذف البلاغ',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_rounded, color: AppColors.danger),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _DetailLine({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(value, style: const TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final bool reviewing;
  final VoidCallback onOpen;
  final VoidCallback onReview;
  final VoidCallback onDelete;

  const _ReportCard({
    required this.report,
    required this.reviewing,
    required this.onOpen,
    required this.onReview,
    required this.onDelete,
  });

  String _value(String key, [String fallback = '']) => (report[key] ?? fallback).toString();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    final type = _value('type', 'بلاغ');
    final postUser = _value('postUsername', _value('postUser', '@user'));
    final reporter = _value('reporterUsername', '@unknown');
    final communityName = _value('communityName');
    final source = _value('source', 'feed');
    final text = _value('postText', 'تغريدة بدون نص');
    final createdAt = _value('createdAt');
    final status = _value('status', _value('aiStatus', 'pending'));
    final aiReason = _value('aiReason');
    final reviewed = status == 'accepted' || status == 'rejected';

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onOpen,
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(color: AppColors.danger.withOpacity(0.14), shape: BoxShape.circle),
                  child: const Icon(Icons.report_rounded, color: AppColors.danger),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(type, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text('المبلِّغ: $reporter · على: $postUser', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted, fontSize: 12)),
                    ],
                  ),
                ),
                if (reviewing)
                  const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.purple))
                else
                  IconButton(
                    tooltip: reviewed ? 'إعادة مراجعة البلاغ بالذكاء الاصطناعي' : 'مراجعة البلاغ بالذكاء الاصطناعي',
                    onPressed: onReview,
                    icon: Icon(reviewed ? Icons.refresh_rounded : Icons.smart_toy_rounded, color: AppColors.purple),
                  ),
                IconButton(
                  tooltip: 'حذف البلاغ',
                  onPressed: onDelete,
                  icon: const Icon(Icons.close_rounded, color: AppColors.danger),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
              ),
              child: Text(text.trim().isEmpty ? 'تغريدة تحتوي على وسائط فقط' : text, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(height: 1.35)),
            ),
            if (aiReason.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: status == 'accepted' ? AppColors.danger.withOpacity(0.10) : AppColors.success.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  status == 'accepted' ? 'قرار Respect AI: البلاغ صحيح · $aiReason' : 'قرار Respect AI: البلاغ غير مؤكد · $aiReason',
                  style: TextStyle(
                    color: status == 'accepted' ? AppColors.danger : AppColors.success,
                    fontWeight: FontWeight.w800,
                    height: 1.35,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _MiniChip(text: source == 'community' ? 'مجتمع' : 'الرئيسية', color: AppColors.purple),
                if (communityName.trim().isNotEmpty) _MiniChip(text: communityName, color: AppColors.success),
                if (createdAt.trim().isNotEmpty) _MiniChip(text: createdAt.split('T').first, color: muted),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminHeader extends StatelessWidget {
  final int users;
  final int blocked;
  final int admins;

  const _AdminHeader({
    required this.users,
    required this.blocked,
    required this.admins,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GlassCard(
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: AppColors.purple.withOpacity(0.18),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.admin_panel_settings_rounded, color: AppColors.purple, size: 30),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('لوحة تحكم حقيقية', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 3),
                Text(
                  '$users مستخدم · $admins أدمن · $blocked محظور',
                  style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final bool danger;

  const _StatCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = danger ? AppColors.danger : AppColors.purple;

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 128;
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: SizedBox(
              width: constraints.maxWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: compact ? 26 : 30),
                  SizedBox(height: compact ? 5 : 7),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: compact ? 20 : 22, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: compact ? 12 : 13),
                  ),
                  SizedBox(height: compact ? 2 : 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontSize: compact ? 10.5 : 11.5),
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

class _UserAdminCard extends StatelessWidget {
  final _AdminUser user;
  final ImageProvider? avatarProvider;
  final VoidCallback onBlock;
  final VoidCallback onAdmin;
  final VoidCallback onDeleteContent;

  const _UserAdminCard({
    required this.user,
    required this.avatarProvider,
    required this.onBlock,
    required this.onAdmin,
    required this.onDeleteContent,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    return GlassCard(
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: user.isBlocked ? AppColors.danger : AppColors.purple,
                backgroundImage: avatarProvider,
                child: avatarProvider == null
                    ? Text(
                  user.name.isEmpty ? '?' : user.name.characters.first,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20),
                )
                    : null,
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
                            user.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                          ),
                        ),
                        if (user.isAdmin) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.verified_user_rounded, color: AppColors.purple, size: 18),
                        ],
                        if (user.isBlocked) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.block_rounded, color: AppColors.danger, size: 18),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(user.username, style: TextStyle(color: muted, fontSize: 12)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _MiniChip(
                          text: user.isBlocked ? 'محظور بالكامل' : 'نشط',
                          color: user.isBlocked ? AppColors.danger : AppColors.success,
                        ),
                        _MiniChip(
                          text: user.isAdmin ? 'Admin' : user.role,
                          color: user.isAdmin ? AppColors.purple : muted,
                        ),
                        if (user.streamUrl.trim().isNotEmpty)
                          const _MiniChip(text: 'Streamer', color: AppColors.purple),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'block') onBlock();
                  if (value == 'admin') onAdmin();
                  if (value == 'delete_content') onDeleteContent();
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'block',
                    child: Row(
                      children: [
                        Icon(user.isBlocked ? Icons.lock_open_rounded : Icons.block_rounded,
                            color: user.isBlocked ? AppColors.success : AppColors.danger),
                        const SizedBox(width: 8),
                        Text(user.isBlocked ? 'إلغاء الحظر' : 'حظر كامل'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'admin',
                    child: Row(
                      children: [
                        Icon(user.isAdmin ? Icons.person_remove_rounded : Icons.add_moderator_rounded,
                            color: AppColors.purple),
                        const SizedBox(width: 8),
                        Text(user.isAdmin ? 'إزالة الأدمن' : 'ترقية أدمن'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete_content',
                    child: Row(
                      children: [
                        Icon(Icons.cleaning_services_rounded, color: AppColors.danger),
                        SizedBox(width: 8),
                        Text('حذف محتواه'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (user.streamUrl.trim().isNotEmpty || user.blockedReason.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (user.streamUrl.trim().isNotEmpty)
                    Text(
                      'البث: ${user.streamUrl}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  if (user.blockedReason.trim().isNotEmpty)
                    Text(
                      'سبب الحظر: ${user.blockedReason}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.danger, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: user.isBlocked ? AppColors.success : AppColors.danger,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: onBlock,
                  icon: Icon(user.isBlocked ? Icons.lock_open_rounded : Icons.block_rounded, size: 18),
                  label: Text(user.isBlocked ? 'فك الحظر' : 'حظر', style: const TextStyle(fontWeight: FontWeight.w900)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.purple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: onAdmin,
                  icon: Icon(user.isAdmin ? Icons.person_remove_rounded : Icons.add_moderator_rounded, size: 18),
                  label: Text(user.isAdmin ? 'إزالة' : 'ترقية', style: const TextStyle(fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String text;
  final Color color;

  const _MiniChip({
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _AdminUser {
  final String id;
  final String name;
  final String username;
  final String role;
  final String avatarPath;
  final String streamUrl;
  final bool isAdmin;
  final bool isBlocked;
  final bool isReported;
  final String blockedReason;
  final String deviceId;
  final bool deviceBanned;

  const _AdminUser({
    required this.id,
    required this.name,
    required this.username,
    required this.role,
    required this.avatarPath,
    required this.streamUrl,
    required this.isAdmin,
    required this.isBlocked,
    required this.isReported,
    required this.blockedReason,
    required this.deviceId,
    required this.deviceBanned,
  });

  factory _AdminUser.fromMap(Map<String, dynamic> map, {required Set<String> blockedList}) {
    final id = _AdminScreenState._userIdFrom(map);
    final username = _AdminScreenState._cleanUsername((map['username'] ?? id).toString());
    final isAdmin = map['isAdmin'] == true || map['is_admin'] == true || map['admin'] == true || map['role']?.toString().toLowerCase() == 'admin';
    final isBlocked = map['isBlocked'] == true ||
        map['blocked'] == true ||
        map['banned'] == true ||
        map['disabled'] == true ||
        map['canLogin'] == false ||
        map['device_banned'] == true ||
        map['device_blocked'] == true ||
        blockedList.contains(id) ||
        blockedList.contains(username);

    return _AdminUser(
      id: id,
      name: (map['profileName'] ?? map['name'] ?? username).toString(),
      username: username,
      role: (map['role'] ?? (isAdmin ? 'admin' : 'user')).toString(),
      avatarPath: (map['imagePath'] ?? map['profileImagePath'] ?? '').toString(),
      streamUrl: (map['streamUrl'] ?? '').toString(),
      isAdmin: isAdmin,
      isBlocked: isBlocked,
      isReported: map['isReported'] == true || map['reported'] == true,
      blockedReason: (map['blockedReason'] ?? map['blocked_reason'] ?? '').toString(),
      deviceId: (map['current_device_id'] ?? map['device_id'] ?? map['last_device_id'] ?? '').toString(),
      deviceBanned: map['device_banned'] == true || map['device_blocked'] == true,
    );
  }
}
