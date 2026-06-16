import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../services/supabase_service.dart';
import '../services/notification_service.dart';

import '../app/app_language.dart';
void _respectSafeLog(Object error, [StackTrace? stackTrace]) {
  if (kDebugMode) {
    developer.log('Respect safe catch', error: error, stackTrace: stackTrace, name: 'respect.safe');
  }
}


class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  static const String _usersKey = 'respect_users_map';
  static const String _accountsKey = 'respect_accounts_v1';
  static const String _streamersKey = 'respect_streamers_v1';
  static const String _postsKey = 'respect_city_posts_v1';
  static const String _communitiesKey = 'respect_communities_v1';
  static const String _followingKey = 'respect_following_v1';
  static const String _blockedKey = 'respect_blocked_users_v1';
  static const String _currentUserKey = 'respect_current_user_id';
  static const String _legacyCurrentUserKey = 'current_user_id';
  static const String _postReportsKey = 'respect_post_reports_v1';
  static const String _hideStatsKey = 'respect_admin_hide_statistics_cards_v1';
  static const String _primaryAdminId = 'nawafrp';
  static const String _primaryAdminPassword = '123456789';

  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _generalTitleCtrl = TextEditingController(text: 'إشعار من Respect');
  final TextEditingController _generalBodyCtrl = TextEditingController();


  bool _loading = true;
  bool _sendingGeneralNotification = false;
  bool _hideStatisticsCards = false;
  String _query = '';

  Map<String, dynamic> _usersMap = <String, dynamic>{};
  List<Map<String, dynamic>> _accounts = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _streamerChannels = <Map<String, dynamic>>[];
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
    _generalTitleCtrl.dispose();
    _generalBodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAdminData() async {
    if (mounted) setState(() => _loading = true);

    final prefs = await SharedPreferences.getInstance();

    final usersRaw = prefs.getString(_usersKey);
    final accountsRaw = prefs.getString(_accountsKey);
    final streamersRaw = prefs.getString(_streamersKey);
    final postsRaw = prefs.getString(_postsKey);
    final communitiesRaw = prefs.getString(_communitiesKey);
    final followingRaw = prefs.getString(_followingKey);
    final blockedRaw = prefs.getString(_blockedKey);
    final reportsRaw = prefs.getString(_postReportsKey);
    final hideStatsCards = prefs.getBool(_hideStatsKey) ?? false;

    final users = _decodeMap(usersRaw);
    final accounts = _decodeList(accountsRaw)
        .whereType<Map>()
        .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
    final storedStreamers = _decodeList(streamersRaw)
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
    } catch (e, st) { _respectSafeLog(e, st); }

    final dedupedUsers = _dedupeUsersMap(users);
    final dedupedAccounts = _dedupeAccountsList(accounts);
    final legacyStreamers = _extractLegacyAdminStreamerChannels(dedupedUsers, dedupedAccounts);
    final streamerChannels = _dedupeStreamerChannels([...storedStreamers, ...legacyStreamers]);
    final removedLegacyStreamers = _removeLegacyAdminStreamerRecords(dedupedUsers, dedupedAccounts);
    _ensurePrimaryAdminUser(dedupedUsers);

    if (legacyStreamers.isNotEmpty || removedLegacyStreamers) {
      try {
        await prefs.setString(_streamersKey, jsonEncode(streamerChannels));
        await prefs.setString(_usersKey, jsonEncode(dedupedUsers));
        await prefs.setString(_accountsKey, jsonEncode(dedupedAccounts));
      } catch (e, st) { _respectSafeLog(e, st); }
    }

    final blockedSet = _decodeBlocked(blockedRaw);
    blockedSet.remove(_primaryAdminId);
    blockedSet.remove(_cleanUsername(_primaryAdminId));
    for (final entry in dedupedUsers.entries) {
      final user = _asStringMap(entry.value);
      if (_isBlockedMap(user)) {
        blockedSet.add(_userIdFrom({...user, 'id': entry.key}));
        blockedSet.add(_cleanUsername((user['username'] ?? entry.key).toString()));
      }
    }

    if (!mounted) return;
    setState(() {
      _usersMap = dedupedUsers;
      _accounts = dedupedAccounts;
      _streamerChannels = streamerChannels;
      _posts = _decodeList(postsRaw);
      _communities = _decodeList(communitiesRaw);
      _postReports = _decodeList(reportsRaw).whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))).toList();
      _hideStatisticsCards = hideStatsCards;
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
    } catch (e, st) { _respectSafeLog(e, st); }
    return <String, dynamic>{};
  }

  List<dynamic> _decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <dynamic>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
    } catch (e, st) { _respectSafeLog(e, st); }
    return <dynamic>[];
  }

  Set<String> _decodeBlocked(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toSet();
      if (decoded is Map) return decoded.keys.map((e) => e.toString()).toSet();
    } catch (e, st) { _respectSafeLog(e, st); }
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
    final byKey = <String, _AdminUser>{};

    void addUser(Map<String, dynamic> raw, String fallbackKey) {
      final map = _asStringMap(raw);
      if (map.isEmpty) return;
      final canonical = _canonicalUserKeyFromMap(map, fallbackKey);
      final user = _AdminUser.fromMap({...map, 'id': (map['id'] ?? canonical).toString()}, blockedList: _blocked);
      final existing = byKey[canonical];
      if (existing == null || _adminUserScore(user) >= _adminUserScore(existing)) {
        byKey[canonical] = user;
      }
    }

    _usersMap.forEach((key, value) => addUser(_asStringMap(value), key));
    for (final account in _accounts) {
      addUser(account, _userIdFrom(account));
    }

    final list = byKey.values.toList();
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

  int _adminUserScore(_AdminUser user) {
    var score = 0;
    if (user.username.trim().isNotEmpty && user.username != '@user') score += 10;
    if (user.name.trim().isNotEmpty && user.name.toLowerCase() != 'user') score += 8;
    if (user.avatarPath.trim().isNotEmpty) score += 3;
    if (user.streamUrl.trim().isNotEmpty) score += 3;
    if (user.deviceId.trim().isNotEmpty) score += 3;
    if (user.isAdmin) score += 2;
    if (user.isBlocked) score += 2;
    return score;
  }

  int get _streamersCount => _streamerChannels.where((s) => (s['streamUrl'] ?? '').toString().trim().isNotEmpty).length;

  int get _liveStreamersCount {
    final seen = <String>{};
    for (final streamer in _streamerChannels) {
      final key = _streamerKeyForMap(streamer);
      if (key.isEmpty || seen.contains(key)) continue;
      final live = streamer['streamIsLive'] == true || streamer['streamIsLive']?.toString() == 'true';
      final hasUrl = (streamer['streamUrl'] ?? '').toString().trim().isNotEmpty;
      if (hasUrl && live) seen.add(key);
    }
    return seen.length;
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

  static String _firstText(List<String> values) {
    return values.firstWhere((v) => v.trim().isNotEmpty, orElse: () => '').trim();
  }

  static String _streamerIdFromUrlAndName(String url, String name, String channelKey) {
    final channelId = _cleanId(channelKey);
    if (channelId.isNotEmpty && channelId != 'user') return channelId;
    final nameId = _cleanId(name);
    if (nameId.isNotEmpty && nameId != 'user') return nameId;
    final encoded = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    final short = encoded.length > 12 ? encoded.substring(0, 12) : encoded;
    return 'streamer_$short';
  }

  static String _normalizedStreamerUrl(String url) {
    final clean = SupabaseService.cleanStreamerUrl(url).trim();
    if (clean.isEmpty) return '';
    return clean.replaceAll(RegExp(r'/+$'), '').toLowerCase();
  }

  static String _streamerKeyForMap(Map<String, dynamic> map) {
    final urlKey = _normalizedStreamerUrl((map['streamUrl'] ?? '').toString());
    if (urlKey.isNotEmpty) return urlKey;
    return _cleanId((map['id'] ?? map['streamChannelKey'] ?? map['username'] ?? '').toString());
  }

  String? _existingStreamerIdByUrl(String url) {
    final target = _normalizedStreamerUrl(url);
    if (target.isEmpty) return null;

    for (final streamer in _streamerChannels) {
      final current = _normalizedStreamerUrl((streamer['streamUrl'] ?? '').toString());
      if (current == target) return (streamer['id'] ?? '').toString();
    }
    return null;
  }

  bool _isLegacyAdminStreamerRecord(Map<String, dynamic> map) {
    final url = (map['streamUrl'] ?? '').toString().trim();
    if (url.isEmpty) return false;
    final id = _cleanId((map['id'] ?? map['userId'] ?? map['uid'] ?? map['username'] ?? '').toString());
    final role = (map['role'] ?? '').toString().trim().toLowerCase();
    final email = (map['email'] ?? '').toString().trim();
    final password = (map['password'] ?? '').toString().trim();

    return map['streamManagedByAdmin'] == true ||
        map['isStandaloneStreamer'] == true ||
        map['streamerOnly'] == true ||
        id.startsWith('streamer_') ||
        (role == 'streamer' && email.isEmpty && password.isEmpty);
  }

  Map<String, dynamic> _streamerChannelFromMap(Map<String, dynamic> raw) {
    final streamUrl = SupabaseService.cleanStreamerUrl((raw['streamUrl'] ?? '').toString());
    final channelKey = _firstText([
      (raw['streamChannelKey'] ?? '').toString(),
      SupabaseService.streamerChannelFromUrl(streamUrl),
    ]);
    final name = _firstText([
      (raw['streamName'] ?? '').toString(),
      (raw['streamerName'] ?? '').toString(),
      (raw['profileName'] ?? '').toString(),
      (raw['name'] ?? '').toString(),
      channelKey,
      'Streamer',
    ]);
    final id = _firstText([
      (raw['id'] ?? '').toString(),
      _streamerIdFromUrlAndName(streamUrl, name, channelKey),
    ]);
    final usernameSource = _firstText([
      (raw['username'] ?? '').toString(),
      channelKey,
      id,
    ]);
    final thumbnail = _firstText([
      (raw['streamThumbnailPath'] ?? '').toString(),
      (raw['streamThumbnailUrl'] ?? '').toString(),
      (raw['avatar_url'] ?? '').toString(),
      (raw['imagePath'] ?? '').toString(),
      (raw['profileImagePath'] ?? '').toString(),
    ]);
    final platform = _firstText([
      (raw['streamPlatform'] ?? '').toString(),
      SupabaseService.streamerPlatformFromUrl(streamUrl),
    ]);
    final now = DateTime.now().toIso8601String();

    return <String, dynamic>{
      'id': _cleanId(id).isEmpty ? _streamerIdFromUrlAndName(streamUrl, name, channelKey) : _cleanId(id),
      'type': 'streamer_channel',
      'isStandaloneStreamer': true,
      'streamerOnly': true,
      'streamManagedByAdmin': true,
      'username': _cleanUsername(usernameSource),
      'name': name,
      'profileName': name,
      'streamUrl': streamUrl,
      'streamName': name,
      'streamerName': name,
      'streamTitle': (raw['streamTitle'] ?? '').toString(),
      'streamIsLive': raw['streamIsLive'] == true || raw['streamIsLive']?.toString() == 'true',
      'streamViewers': int.tryParse((raw['streamViewers'] ?? 0).toString().replaceAll(',', '')) ?? 0,
      'streamThumbnailUrl': thumbnail,
      'streamThumbnailPath': thumbnail,
      'streamPlatform': platform,
      'streamChannelKey': channelKey,
      'createdAt': (raw['createdAt'] ?? raw['created_at'] ?? now).toString(),
      'updatedAt': (raw['updatedAt'] ?? raw['updated_at'] ?? now).toString(),
      'streamLastCheckedAt': (raw['streamLastCheckedAt'] ?? now).toString(),
    };
  }

  Map<String, dynamic> _mergeStreamerChannel(Map<String, dynamic> oldValue, Map<String, dynamic> newValue) {
    final merged = <String, dynamic>{...oldValue, ...newValue};
    for (final key in <String>[
      'streamName',
      'streamerName',
      'name',
      'profileName',
      'streamTitle',
      'streamThumbnailUrl',
      'streamThumbnailPath',
      'streamPlatform',
      'streamChannelKey',
      'username',
    ]) {
      final current = (merged[key] ?? '').toString().trim();
      final old = (oldValue[key] ?? '').toString().trim();
      if (current.isEmpty && old.isNotEmpty) merged[key] = old;
    }
    return _streamerChannelFromMap(merged);
  }

  List<Map<String, dynamic>> _dedupeStreamerChannels(List<Map<String, dynamic>> streamers) {
    final byKey = <String, Map<String, dynamic>>{};
    for (final raw in streamers) {
      final map = _streamerChannelFromMap(raw);
      final key = _streamerKeyForMap(map);
      if (key.isEmpty || (map['streamUrl'] ?? '').toString().trim().isEmpty) continue;
      final existing = byKey[key];
      byKey[key] = existing == null ? map : _mergeStreamerChannel(existing, map);
    }
    final values = byKey.values.toList();
    values.sort((a, b) {
      final liveA = a['streamIsLive'] == true || a['streamIsLive']?.toString() == 'true';
      final liveB = b['streamIsLive'] == true || b['streamIsLive']?.toString() == 'true';
      if (liveA != liveB) return liveA ? -1 : 1;
      return (a['streamName'] ?? a['name'] ?? '').toString().toLowerCase().compareTo((b['streamName'] ?? b['name'] ?? '').toString().toLowerCase());
    });
    return values;
  }

  List<Map<String, dynamic>> _extractLegacyAdminStreamerChannels(
    Map<String, dynamic> users,
    List<Map<String, dynamic>> accounts,
  ) {
    final found = <Map<String, dynamic>>[];
    for (final entry in users.entries) {
      final map = _asStringMap(entry.value);
      if (_isLegacyAdminStreamerRecord(map)) {
        found.add(_streamerChannelFromMap({...map, 'id': (map['id'] ?? entry.key).toString()}));
      }
    }
    for (final account in accounts) {
      if (_isLegacyAdminStreamerRecord(account)) {
        found.add(_streamerChannelFromMap(account));
      }
    }
    return _dedupeStreamerChannels(found);
  }

  bool _removeLegacyAdminStreamerRecords(Map<String, dynamic> users, List<Map<String, dynamic>> accounts) {
    var changed = false;
    final idsToRemove = <String>{};
    users.removeWhere((key, value) {
      final map = _asStringMap(value);
      final remove = _isLegacyAdminStreamerRecord({...map, 'id': (map['id'] ?? key).toString()});
      if (remove) {
        idsToRemove.add(_cleanId((map['id'] ?? key).toString()));
        changed = true;
      }
      return remove;
    });
    final before = accounts.length;
    accounts.removeWhere((account) {
      final id = _cleanId((account['id'] ?? account['username'] ?? '').toString());
      return idsToRemove.contains(id) || _isLegacyAdminStreamerRecord(account);
    });
    if (accounts.length != before) changed = true;
    return changed;
  }

  void _upsertStreamerChannel(Map<String, dynamic> raw) {
    final normalized = _streamerChannelFromMap(raw);
    final key = _streamerKeyForMap(normalized);
    if (key.isEmpty) return;
    final idx = _streamerChannels.indexWhere((streamer) => _streamerKeyForMap(streamer) == key || (streamer['id'] ?? '').toString() == (normalized['id'] ?? '').toString());
    if (idx >= 0) {
      _streamerChannels[idx] = _mergeStreamerChannel(_streamerChannels[idx], normalized);
    } else {
      _streamerChannels.add(normalized);
    }
    _streamerChannels = _dedupeStreamerChannels(_streamerChannels);
  }

  static String _canonicalUserKeyFromMap(Map<String, dynamic> map, [String fallback = '']) {
    final usernameRaw = (map['username'] ?? map['userName'] ?? map['handle'] ?? '').toString().trim();
    final usernameId = _cleanId(usernameRaw);
    if (usernameId.isNotEmpty && usernameId != 'user') return usernameId;

    final idRaw = (map['id'] ?? map['userId'] ?? map['uid'] ?? fallback).toString().trim();
    final id = _cleanId(idRaw);
    if (id.isNotEmpty && id != 'user') return id;

    final emailRaw = (map['email'] ?? map['mail'] ?? '').toString().trim().toLowerCase();
    if (emailRaw.isNotEmpty) return emailRaw;

    return fallback.trim().isEmpty ? 'unknown_${DateTime.now().microsecondsSinceEpoch}' : _cleanId(fallback);
  }

  static int _profileCompletenessScore(Map<String, dynamic> map) {
    var score = 0;
    final username = (map['username'] ?? '').toString().trim();
    final name = (map['name'] ?? map['profileName'] ?? '').toString().trim();
    final avatar = (map['avatar_url'] ?? map['imagePath'] ?? map['profileImagePath'] ?? '').toString().trim();
    final streamUrl = (map['streamUrl'] ?? '').toString().trim();
    final deviceId = (map['current_device_id'] ?? map['device_id'] ?? map['last_device_id'] ?? '').toString().trim();

    if (username.isNotEmpty) score += 12;
    if (name.isNotEmpty && name.toLowerCase() != 'user') score += 8;
    if (avatar.isNotEmpty) score += 4;
    if (streamUrl.isNotEmpty) score += 3;
    if (deviceId.isNotEmpty) score += 3;
    if (map['is_admin'] == true || map['isAdmin'] == true || map['admin'] == true) score += 2;
    if (map['created_at'] != null || map['updated_at'] != null || map['last_seen_at'] != null) score += 5; // غالبًا بيانات Supabase
    return score;
  }

  Map<String, dynamic> _mergeUserRecords(Map<String, dynamic> oldValue, Map<String, dynamic> newValue, String canonicalKey) {
    final oldScore = _profileCompletenessScore(oldValue);
    final newScore = _profileCompletenessScore(newValue);
    final base = newScore >= oldScore ? oldValue : newValue;
    final override = newScore >= oldScore ? newValue : oldValue;

    final merged = <String, dynamic>{...base, ...override};
    final username = _cleanUsername((merged['username'] ?? canonicalKey).toString());
    final id = _cleanId((merged['id'] ?? canonicalKey).toString());

    merged['id'] = id.isEmpty || id == 'user' ? canonicalKey : id;
    merged['username'] = username;
    merged['name'] = (merged['name'] ?? merged['profileName'] ?? username).toString();
    merged['profileName'] = (merged['profileName'] ?? merged['name'] ?? username).toString();
    return merged;
  }

  Map<String, dynamic> _dedupeUsersMap(Map<String, dynamic> users) {
    final byKey = <String, Map<String, dynamic>>{};

    users.forEach((key, value) {
      final map = _asStringMap(value);
      if (map.isEmpty) return;
      final normalized = <String, dynamic>{...map, 'id': (map['id'] ?? key).toString()};
      final canonical = _canonicalUserKeyFromMap(normalized, key);
      final existing = byKey[canonical];
      byKey[canonical] = existing == null ? normalized : _mergeUserRecords(existing, normalized, canonical);
    });

    return byKey.map((key, value) => MapEntry(key, <String, dynamic>{
      ...value,
      'id': _cleanId((value['id'] ?? key).toString()).isEmpty ? key : _cleanId((value['id'] ?? key).toString()),
      'username': _cleanUsername((value['username'] ?? key).toString()),
      'name': (value['name'] ?? value['profileName'] ?? key).toString(),
      'profileName': (value['profileName'] ?? value['name'] ?? key).toString(),
    }));
  }

  List<Map<String, dynamic>> _dedupeAccountsList(List<Map<String, dynamic>> accounts) {
    final byKey = <String, Map<String, dynamic>>{};
    for (final account in accounts) {
      final map = account.map((k, v) => MapEntry(k.toString(), v));
      if (map.isEmpty) continue;
      final canonical = _canonicalUserKeyFromMap(map, _userIdFrom(map));
      final existing = byKey[canonical];
      byKey[canonical] = existing == null ? map : _mergeUserRecords(existing, map, canonical);
    }
    return byKey.values.toList();
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
    _removeLegacyAdminStreamerRecords(_usersMap, _accounts);
    _ensurePrimaryAdminUser(_usersMap);
    _blocked.remove(_primaryAdminId);
    _blocked.remove(_cleanUsername(_primaryAdminId));
    await _syncAccountFromUser(_primaryAdminId);
    _streamerChannels = _dedupeStreamerChannels(_streamerChannels);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usersKey, jsonEncode(_usersMap));
    await prefs.setString(_accountsKey, jsonEncode(_accounts));
    await prefs.setString(_streamersKey, jsonEncode(_streamerChannels));
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
      'streamerName': (user['streamerName'] ?? user['streamName'] ?? '').toString(),
      'streamUrl': (user['streamUrl'] ?? '').toString(),
      'streamTitle': (user['streamTitle'] ?? '').toString(),
      'streamIsLive': user['streamIsLive'] == true || user['streamIsLive']?.toString() == 'true',
      'streamViewers': user['streamViewers'] ?? 0,
      'streamThumbnailUrl': (user['streamThumbnailUrl'] ?? '').toString(),
      'streamThumbnailPath': (user['streamThumbnailPath'] ?? user['streamThumbnailUrl'] ?? '').toString(),
      'streamPlatform': (user['streamPlatform'] ?? '').toString(),
      'streamChannelKey': (user['streamChannelKey'] ?? '').toString(),
      'isStreamer': user['isStreamer'] == true || (user['streamUrl'] ?? '').toString().trim().isNotEmpty,
      'manualStreamer': user['manualStreamer'] == true,
      'streamManualMode': user['streamManualMode'] == true || user['manualStreamer'] == true,
      'streamManagedByAdmin': user['streamManagedByAdmin'] == true,
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
      _snack('لا يمكن حظر حساب الأدمن الأساسي nawafrp', error: true);
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
    _snack(blocked ? 'تم حظر ${user.name} بالكامل' : 'تم إلغاء حظر ${user.name}', success: true);
  }

  Future<void> _setUserAdmin(_AdminUser user, bool admin) async {
    final id = user.id;
    if (id == _primaryAdminId && !admin) {
      _snack('لا يمكن إزالة صلاحية الأدمن من nawafrp', error: true);
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
    _snack(admin ? 'تمت ترقية ${user.name} إلى أدمن' : 'تم إرجاع ${user.name} كمستخدم عادي', success: true);
  }

  Future<void> _openAddStreamerSheet() async {
    final rawStreamUrl = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _AddStreamerSheet(),
    );

    if (!mounted || rawStreamUrl == null) return;

    final streamUrl = SupabaseService.cleanStreamerUrl(rawStreamUrl.trim());

    if (streamUrl.isEmpty) {
      _snack('ضع رابط القناة أولاً', error: true);
      return;
    }

    _snack('جاري جلب بيانات القناة تلقائيًا...');

    try {
      final meta = await SupabaseService.fetchStreamerMetadata(streamUrl, fallbackName: 'Streamer');
      if (!mounted) return;

      final channelKey = (meta['streamChannelKey'] ?? SupabaseService.streamerChannelFromUrl(streamUrl)).toString().trim();
      final name = _firstText([
        (meta['streamName'] ?? '').toString(),
        (meta['streamerName'] ?? '').toString(),
        channelKey,
        'Streamer',
      ]);
      final id = _existingStreamerIdByUrl(streamUrl) ?? _streamerIdFromUrlAndName(streamUrl, name, channelKey);
      if (id.trim().isEmpty || id == 'user') {
        _snack('تعذر إنشاء معرف مناسب للقناة', error: true);
        return;
      }

      final now = DateTime.now().toIso8601String();
      final thumbnail = _firstText([
        (meta['streamThumbnailUrl'] ?? '').toString(),
        (meta['streamThumbnailPath'] ?? '').toString(),
      ]);
      final platform = _firstText([
        (meta['streamPlatform'] ?? '').toString(),
        SupabaseService.streamerPlatformFromUrl(streamUrl),
      ]);

      _upsertStreamerChannel(<String, dynamic>{
        'id': id,
        'username': _cleanUsername(channelKey.isNotEmpty ? channelKey : id),
        'name': name,
        'profileName': name,
        'type': 'streamer_channel',
        'isStandaloneStreamer': true,
        'streamerOnly': true,
        'streamManagedByAdmin': true,
        'createdAt': now,
        'updatedAt': now,
        'streamUrl': streamUrl,
        'streamName': name,
        'streamerName': name,
        'streamTitle': (meta['streamTitle'] ?? '').toString(),
        'streamIsLive': meta['streamIsLive'] == true || meta['streamIsLive']?.toString() == 'true',
        'streamViewers': int.tryParse((meta['streamViewers'] ?? 0).toString().replaceAll(',', '')) ?? 0,
        'streamThumbnailUrl': thumbnail,
        'streamThumbnailPath': thumbnail,
        'streamPlatform': platform,
        'streamChannelKey': channelKey,
        'streamLastCheckedAt': now,
      });
      await _saveAll();

      if (!mounted) return;
      setState(() {});
      _snack('تمت إضافة $name كقناة مستقلة في صفحة الستريمرز', success: true);
    } catch (e, st) {
      _respectSafeLog(e, st);
      if (!mounted) return;
      _snack('تعذرت إضافة الستريمر: ${e.toString().replaceFirst('Exception: ', '')}', error: true);
    }
  }

  Future<void> _openStreamEditorSheet(_AdminUser user) async {
    final streamNameCtrl = TextEditingController(text: user.streamName.trim().isEmpty ? user.name : user.streamName);
    final streamUrlCtrl = TextEditingController(text: user.streamUrl);
    final streamTitleCtrl = TextEditingController(text: user.streamTitle);
    final viewersCtrl = TextEditingController(text: user.streamViewers.toString());
    final thumbnailCtrl = TextEditingController(text: user.streamThumbnailPath.trim().isNotEmpty ? user.streamThumbnailPath : user.streamThumbnailUrl);
    final platformCtrl = TextEditingController(text: user.streamPlatform);
    bool isLive = user.streamIsLive;

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
          child: DraggableScrollableSheet(
            initialChildSize: 0.82,
            minChildSize: 0.45,
            maxChildSize: 0.96,
            expand: false,
            builder: (context, scrollController) {
              return StatefulBuilder(
                builder: (context, setSheet) {
                  return Container(
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.darkBg : AppColors.lightBg,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                      border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
                          blurRadius: 30,
                          offset: const Offset(0, -8),
                        ),
                      ],
                    ),
                    child: SingleChildScrollView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                      child: SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Center(
                              child: Container(
                                width: 48,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 25,
                                  backgroundColor: AppColors.purple,
                                  backgroundImage: _avatarProvider(user.avatarPath),
                                  child: _avatarProvider(user.avatarPath) == null
                                      ? AppText(user.name.isEmpty ? '?' : user.name.characters.first,
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900))
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const AppText('بيانات البث', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                                      AppText('${user.name} • ${user.username}', style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: streamUrlCtrl,
                              keyboardType: TextInputType.url,
                              decoration: InputDecoration(
                                prefixIcon: Icon(Icons.link_rounded),
                                hintText: context.tr('رابط البث الثابت'),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: streamNameCtrl,
                              decoration: InputDecoration(
                                prefixIcon: Icon(Icons.badge_rounded),
                                hintText: context.tr('اسم الستريمر / القناة'),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: streamTitleCtrl,
                              decoration: InputDecoration(
                                prefixIcon: Icon(Icons.title_rounded),
                                hintText: context.tr('عنوان البث'),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: viewersCtrl,
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      prefixIcon: Icon(Icons.visibility_rounded),
                                      hintText: context.tr('عدد المشاهدين'),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: platformCtrl,
                                    decoration: InputDecoration(
                                      prefixIcon: Icon(Icons.live_tv_rounded),
                                      hintText: context.tr('المنصة: kick / twitch'),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: thumbnailCtrl,
                              keyboardType: TextInputType.url,
                              decoration: InputDecoration(
                                prefixIcon: Icon(Icons.image_rounded),
                                hintText: context.tr('رابط صورة البث / المصغرة'),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SwitchListTile.adaptive(
                              value: isLive,
                              onChanged: (value) => setSheet(() => isLive = value),
                              activeColor: AppColors.purple,
                              contentPadding: EdgeInsets.zero,
                              title: const AppText('البث مباشر الآن', style: TextStyle(fontWeight: FontWeight.w900)),
                              subtitle: AppText('يمكن ترك الحقول فارغة وسيتم جلب الاسم والصورة والحالة تلقائيًا من الرابط.', style: TextStyle(color: muted, fontSize: 12)),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.purple,
                                      foregroundColor: Colors.white,
                                      minimumSize: const Size.fromHeight(52),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                    ),
                                    onPressed: () => Navigator.of(sheetContext).pop('save'),
                                    icon: const Icon(Icons.save_rounded),
                                    label: const AppText('حفظ بيانات البث', style: TextStyle(fontWeight: FontWeight.w900)),
                                  ),
                                ),
                                if (user.streamUrl.trim().isNotEmpty) ...[
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: AppColors.danger,
                                        minimumSize: const Size.fromHeight(52),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                      ),
                                      onPressed: () => Navigator.of(sheetContext).pop('remove'),
                                      icon: const Icon(Icons.delete_rounded),
                                      label: const AppText('إزالة البث', style: TextStyle(fontWeight: FontWeight.w900)),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );

    if (action == 'save') {
      final streamUrl = SupabaseService.cleanStreamerUrl(streamUrlCtrl.text.trim());
      if (streamUrl.isEmpty) {
        _snack('ضع رابط البث أولاً أو استخدم إزالة البث', error: true);
        return;
      }

      _snack('جاري تحديث بيانات القناة تلقائيًا...');
      final meta = await SupabaseService.fetchStreamerMetadata(streamUrl, fallbackName: user.name);
      final autoName = _firstText([
        streamNameCtrl.text.trim(),
        (meta['streamName'] ?? '').toString(),
        (meta['streamerName'] ?? '').toString(),
        user.name,
      ]);
      final autoThumbnail = _firstText([
        thumbnailCtrl.text.trim(),
        (meta['streamThumbnailUrl'] ?? '').toString(),
        (meta['streamThumbnailPath'] ?? '').toString(),
      ]);
      final autoPlatform = _firstText([
        platformCtrl.text.trim(),
        (meta['streamPlatform'] ?? '').toString(),
        SupabaseService.streamerPlatformFromUrl(streamUrl),
      ]);
      final typedViewers = int.tryParse(viewersCtrl.text.trim().replaceAll(',', '')) ?? 0;
      final autoViewers = typedViewers > 0 ? typedViewers : (int.tryParse((meta['streamViewers'] ?? 0).toString().replaceAll(',', '')) ?? 0);
      await _setUserStreamData(
        user,
        streamUrl: streamUrl,
        streamName: autoName,
        streamTitle: _firstText([streamTitleCtrl.text.trim(), (meta['streamTitle'] ?? '').toString()]),
        streamIsLive: isLive || meta['streamIsLive'] == true || meta['streamIsLive']?.toString() == 'true',
        streamViewers: autoViewers,
        streamThumbnailUrl: autoThumbnail,
        streamPlatform: autoPlatform,
        streamChannelKey: (meta['streamChannelKey'] ?? SupabaseService.streamerChannelFromUrl(streamUrl)).toString(),
      );
    } else if (action == 'remove') {
      await _setUserStreamData(user, clear: true);
    }
  }

  Future<void> _setUserStreamData(
    _AdminUser user, {
    bool clear = false,
    String streamUrl = '',
    String streamName = '',
    String streamTitle = '',
    bool streamIsLive = false,
    int streamViewers = 0,
    String streamThumbnailUrl = '',
    String streamPlatform = '',
    String streamChannelKey = '',
  }) async {
    final id = user.id;
    if (clear) {
      final targetUrl = _normalizedStreamerUrl(user.streamUrl);
      _streamerChannels.removeWhere((streamer) {
        final sameId = (streamer['id'] ?? '').toString() == id;
        final sameUrl = targetUrl.isNotEmpty && _normalizedStreamerUrl((streamer['streamUrl'] ?? '').toString()) == targetUrl;
        return sameId || sameUrl;
      });
      await _saveAll();

      if (!mounted) return;
      setState(() {});
      _snack('تم حذف قناة ${user.name} من صفحة الستريمرز', success: true);
      return;
    }

    final now = DateTime.now().toIso8601String();
    _upsertStreamerChannel(<String, dynamic>{
      'id': id,
      'username': user.username,
      'name': streamName.trim().isEmpty ? user.name : streamName.trim(),
      'profileName': streamName.trim().isEmpty ? user.name : streamName.trim(),
      'type': 'streamer_channel',
      'isStandaloneStreamer': true,
      'streamerOnly': true,
      'streamManagedByAdmin': true,
      'updatedAt': now,
      'streamUrl': streamUrl.trim(),
      'streamName': streamName.trim(),
      'streamerName': streamName.trim(),
      'streamTitle': streamTitle.trim(),
      'streamIsLive': streamIsLive,
      'streamViewers': streamViewers < 0 ? 0 : streamViewers,
      'streamThumbnailUrl': streamThumbnailUrl.trim(),
      'streamThumbnailPath': streamThumbnailUrl.trim(),
      'streamPlatform': streamPlatform.trim(),
      'streamChannelKey': streamChannelKey.trim(),
      'streamLastCheckedAt': now,
    });
    await _saveAll();

    if (!mounted) return;
    setState(() {});
    _snack('تم حفظ بيانات قناة ${user.name}', success: true);
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
    _snack('تم حذف محتوى ${user.name}', success: true);
  }

  Future<void> _showBlockSheet(_AdminUser user) async {
    var reason = user.blockedReason;
    final blocked = user.isBlocked;

    final action = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
          child: DraggableScrollableSheet(
            initialChildSize: 0.58,
            minChildSize: 0.30,
            maxChildSize: 0.86,
            expand: false,
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkBg : AppColors.lightBg,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                  border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
                      blurRadius: 30,
                      offset: const Offset(0, -8),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 48,
                          height: 5,
                          decoration: BoxDecoration(
                            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                        const SizedBox(height: 18),
                        CircleAvatar(
                          radius: 31,
                          backgroundColor: blocked ? AppColors.danger : AppColors.purple,
                          backgroundImage: _avatarProvider(user.avatarPath),
                          child: _avatarProvider(user.avatarPath) == null
                              ? AppText(
                            user.name.isEmpty ? '?' : user.name.characters.first,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20),
                          )
                              : null,
                        ),
                        const SizedBox(height: 10),
                        AppText(user.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                        AppText(user.username, style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 14),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: (blocked || user.deviceBanned ? AppColors.danger : AppColors.purple).withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: (blocked || user.deviceBanned ? AppColors.danger : AppColors.purple).withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.phone_android_rounded, color: blocked || user.deviceBanned ? AppColors.danger : AppColors.purple),
                              const SizedBox(width: 10),
                              Expanded(
                                child: AppText(
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
                        TextFormField(
                          initialValue: reason,
                          maxLines: 3,
                          onChanged: (value) => reason = value,
                          decoration: InputDecoration(
                            prefixIcon: Icon(Icons.notes_rounded),
                            hintText: context.tr('سبب الحظر'),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: blocked ? AppColors.success : AppColors.danger,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                  minimumSize: const Size.fromHeight(52),
                                ),
                                icon: Icon(blocked ? Icons.lock_open_rounded : Icons.block_rounded),
                                label: AppText(
                                  blocked ? 'إلغاء الحظر' : 'حظر الحساب والجهاز',
                                  style: const TextStyle(fontWeight: FontWeight.w900),
                                ),
                                onPressed: () => Navigator.of(sheetContext).pop(true),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                  minimumSize: const Size.fromHeight(52),
                                ),
                                icon: const Icon(Icons.close_rounded),
                                label: const AppText('إلغاء', style: TextStyle(fontWeight: FontWeight.w900)),
                                onPressed: () => Navigator.of(sheetContext).pop(false),
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
          ),
        );
      },
    );

    if (action == true) {
      await _setUserBlocked(user, !blocked, reason: reason);
    }
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
          title: AppText(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          content: AppText(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const AppText('إلغاء')),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: danger ? AppColors.danger : AppColors.purple,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const AppText('تأكيد'),
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
      _snack('لا يوجد معرف للتغريدة داخل البلاغ', error: true);
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
      _snack(valid ? 'تم قبول البلاغ وحذف التغريدة' : 'تم رفض البلاغ والتغريدة سليمة', success: true);
    } catch (e) {
      _snack('تعذرت مراجعة البلاغ: $e', error: true);
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
    _snack('تم حذف البلاغ', success: true);
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
    _snack('تم حذف كل البلاغات', success: true);
  }

  void _snack(String message, {bool success = false, bool error = false}) {
    if (!mounted) return;
    final clean = message.trim();
    if (clean.isEmpty) return;
    if (error) {
      NotificationService.showTopError(clean);
    } else if (success) {
      NotificationService.showTopSuccess(clean);
    } else {
      NotificationService.showTopNotification(clean);
    }
  }

  ImageProvider? _avatarProvider(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    final value = path.trim();
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return NetworkImage(value);
    }
    final file = File(value);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  List<Map<String, dynamic>> get _postMaps {
    return _posts
        .whereType<Map>()
        .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  List<Map<String, dynamic>> get _filteredPosts {
    final q = _query.trim().toLowerCase();
    final posts = _postMaps;
    if (q.isEmpty) return posts;
    return posts.where((post) {
      final haystack = [
        post['id'],
        post['postId'],
        post['post_id'],
        post['username'],
        post['author'],
        post['name'],
        post['text'],
        post['content'],
        post['communityName'],
        post['community_name'],
      ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
      return haystack.contains(q);
    }).toList();
  }

  List<_AdminUser> get _streamerUsers {
    return _streamerChannels
        .map((streamer) => _AdminUser.fromMap(streamer, blockedList: const <String>{}))
        .where((u) => u.streamUrl.trim().isNotEmpty)
        .toList();
  }

  List<_AdminUser> get _filteredStreamerUsers {
    final q = _query.trim().toLowerCase();
    final streamers = _streamerUsers;
    if (q.isEmpty) return streamers;
    return streamers.where((u) {
      final haystack = '${u.id} ${u.name} ${u.username} ${u.streamUrl} ${u.role}'.toLowerCase();
      return haystack.contains(q);
    }).toList();
  }

  String _postValue(Map<String, dynamic> post, List<String> keys, [String fallback = '']) {
    for (final key in keys) {
      final value = post[key];
      if (value != null && value.toString().trim().isNotEmpty) return value.toString();
    }
    return fallback;
  }

  int _postReportCount(Map<String, dynamic> post) {
    final reports = post['reports'] ?? post['reportCount'] ?? post['reportsCount'];
    if (reports is List) return reports.length;
    if (reports is int) return reports;
    if (reports is String) return int.tryParse(reports) ?? 0;
    if (post['isReported'] == true || post['reported'] == true) return 1;
    return 0;
  }

  Future<void> _deletePost(Map<String, dynamic> post) async {
    final postId = _postValue(post, const ['id', 'postId', 'post_id']);
    final ok = await _confirm(
      title: 'حذف المنشور؟',
      message: 'سيتم حذف المنشور من لوحة الإدارة ومن التخزين المحلي، ومحاولة حذفه من السيرفر إذا كان متاحًا.',
      danger: true,
    );
    if (!ok) return;

    setState(() {
      _posts.removeWhere((raw) {
        final map = _asStringMap(raw);
        if (postId.trim().isNotEmpty) {
          final id = _postValue(map, const ['id', 'postId', 'post_id']);
          return id == postId;
        }
        return identical(raw, post) || jsonEncode(map) == jsonEncode(post);
      });
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_postsKey, jsonEncode(_posts));

    if (postId.trim().isNotEmpty) {
      try {
        await SupabaseService.client.from('posts').delete().eq('id', postId).timeout(const Duration(seconds: 8));
      } catch (e, st) {
        _respectSafeLog(e, st);
      }
    }

    _snack('تم حذف المنشور', success: true);
  }

  Future<void> _toggleStatisticsCards() async {
    final nextValue = !_hideStatisticsCards;
    if (mounted) setState(() => _hideStatisticsCards = nextValue);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_hideStatsKey, nextValue);
    } catch (e, st) {
      _respectSafeLog(e, st);
    }
  }

  Widget _buildTopSummary(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          _AdminHeader(
            users: _users.length,
            blocked: _users.where((u) => u.isBlocked).length,
            admins: _users.where((u) => u.isAdmin).length,
          ).animate().fadeIn(duration: 250.ms).slideY(begin: -0.02),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _toggleStatisticsCards,
              icon: Icon(_hideStatisticsCards ? Icons.visibility_rounded : Icons.visibility_off_rounded),
              label: AppText(_hideStatisticsCards ? 'إظهار الإحصائيات' : 'إخفاء الإحصائيات'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.purple,
                side: BorderSide(color: AppColors.purple.withValues(alpha: .30)),
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13.5),
              ),
            ),
          ).animate().fadeIn(duration: 220.ms).slideY(begin: -0.01),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              return SizeTransition(
                sizeFactor: animation,
                axisAlignment: -1,
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: _hideStatisticsCards
                ? const SizedBox.shrink(key: ValueKey('stats-hidden'))
                : Padding(
                    key: const ValueKey('stats-visible'),
                    padding: const EdgeInsets.only(top: 12),
                    child: GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1.42,
                      children: [
                        _StatCard(
                          title: 'المستخدمين',
                          value: _formatNumber(_users.length),
                          icon: Icons.people_alt_rounded,
                          subtitle: '${_users.where((u) => !u.isBlocked).length} نشط',
                        ),
                        _StatCard(
                          title: 'البلاغات',
                          value: _formatNumber(_postReports.length),
                          icon: Icons.report_rounded,
                          subtitle: '${_reviewingReportIds.length} قيد المراجعة',
                          danger: _postReports.isNotEmpty,
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
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBox(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: TextField(
        controller: _searchCtrl,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded),
          hintText: context.tr('بحث سريع داخل الإدارة...'),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
            onPressed: _searchCtrl.clear,
            icon: const Icon(Icons.close_rounded),
          ),
        ),
      ),
    );
  }


  Future<void> _sendGeneralNotificationToAll() async {
    final title = _generalTitleCtrl.text.trim();
    final body = _generalBodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      NotificationService.showTopError(context.tr('اكتب عنوان ونص الإشعار أولاً'));
      return;
    }
    if (_sendingGeneralNotification) return;

    setState(() => _sendingGeneralNotification = true);
    try {
      final result = await SupabaseService.sendGeneralNotificationToAll(
        title: title,
        body: body,
      );
      if (!mounted) return;
      final sent = int.tryParse((result['sent'] ?? 0).toString()) ?? 0;
      final total = int.tryParse((result['total'] ?? 0).toString()) ?? 0;
      _generalBodyCtrl.clear();
      NotificationService.showTopSuccess(
        total > 0 ? 'تم إرسال الإشعار إلى $sent من $total جهاز' : 'تم حفظ الإشعار، ولا يوجد أجهزة مسجلة حالياً',
        title: 'تم الإرسال',
      );
    } catch (e) {
      if (!mounted) return;
      NotificationService.showTopError(context.tr('تعذر إرسال الإشعار العام: $e'));
    } finally {
      if (mounted) setState(() => _sendingGeneralNotification = false);
    }
  }

  Widget _buildGeneralNotificationTab() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    return _tabRefresh(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(colors: [AppColors.purple, Color(0xFF7C3AED)]),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.purple.withValues(alpha: .28),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.campaign_rounded, color: Colors.white, size: 26),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText('إشعار عام لكل المستخدمين', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                          SizedBox(height: 3),
                          AppText('يرسل Push خارج التطبيق ويظهر كتنبيه داخلي داخل Respect.', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _generalTitleCtrl,
                  maxLength: 60,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: context.tr('عنوان الإشعار'),
                    hintText: context.tr('مثال: تحديث جديد'),
                    prefixIcon: Icon(Icons.title_rounded),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _generalBodyCtrl,
                  minLines: 5,
                  maxLines: 8,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: context.tr('نص الإشعار'),
                    hintText: context.tr('اكتب الرسالة التي ستصل لكل مستخدمي التطبيق...'),
                    alignLabelWithHint: true,
                    prefixIcon: Padding(
                      padding: EdgeInsets.only(bottom: 88),
                      child: Icon(Icons.notes_rounded),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.purple.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.purple.withValues(alpha: .18)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_rounded, color: AppColors.purple, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: AppText(
                          'الإشعار يصل للأجهزة التي سجلت FCM Token. المستخدم الذي يكون داخل التطبيق سيشاهد تنبيه علوي، وسيظهر أيضاً في صفحة الإشعارات.',
                          style: TextStyle(color: muted, fontWeight: FontWeight.w700, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _sendingGeneralNotification ? null : _sendGeneralNotificationToAll,
                    icon: _sendingGeneralNotification
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send_rounded),
                    label: AppText(_sendingGeneralNotification ? 'جاري الإرسال...' : 'إرسال لكل المستخدمين'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.purple,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppColors.purple.withValues(alpha: .45),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                    ),
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(duration: 260.ms).slideY(begin: .02),
        ],
      ),
    );
  }

  Widget _buildTabs(bool isDark) {
    final labelColor = isDark ? Colors.white : Colors.black87;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard.withValues(alpha: .88) : AppColors.lightCard.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      child: TabBar(
        isScrollable: true,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: Colors.white,
        unselectedLabelColor: labelColor.withValues(alpha: .68),
        labelStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        indicator: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(colors: [AppColors.purple, Color(0xFF6D28D9)]),
          boxShadow: [
            BoxShadow(
              color: AppColors.purple.withValues(alpha: .28),
              blurRadius: 18,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        tabs: [
          Tab(icon: const Icon(Icons.report_rounded, size: 19), child: AppText('البلاغات ${_postReports.length}')),
          Tab(icon: const Icon(Icons.people_alt_rounded, size: 19), child: AppText('المستخدمين ${_users.length}')),
          Tab(icon: const Icon(Icons.article_rounded, size: 19), child: AppText('المنشورات ${_posts.length}')),
          Tab(icon: const Icon(Icons.live_tv_rounded, size: 19), child: AppText('الستريمرز $_streamersCount')),
          const Tab(icon: Icon(Icons.campaign_rounded, size: 19), child: AppText('إشعار عام')),
        ],
      ),
    );
  }

  Widget _emptyStateCard({
    required IconData icon,
    required String title,
    required String subtitle,
    bool danger = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = danger ? AppColors.danger : AppColors.purple;
    return GlassCard(
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .13),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 32),
          ),
          const SizedBox(height: 14),
          AppText(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
          const SizedBox(height: 6),
          AppText(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    bool danger = false,
  }) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 34, 16, 120),
      children: [
        _emptyStateCard(icon: icon, title: title, subtitle: subtitle, danger: danger),
      ],
    );
  }

  Widget _tabRefresh({required Widget child}) {
    return RefreshIndicator(
      color: AppColors.purple,
      onRefresh: _loadAdminData,
      child: child,
    );
  }

  Widget _buildReportsTab() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_postReports.isEmpty) {
      return _tabRefresh(
        child: _emptyState(
          icon: Icons.verified_rounded,
          title: 'لا توجد بلاغات حالياً',
          subtitle: 'أي بلاغ جديد سيظهر هنا للمراجعة السريعة.',
        ),
      );
    }

    return _tabRefresh(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
        children: [
          Row(
            children: [
              Expanded(
                child: AppText('بلاغات التغريدات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
              ),
              TextButton.icon(
                onPressed: _clearReports,
                icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                label: const AppText('حذف الكل'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...List.generate(_postReports.length, (i) {
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
            ).animate().fadeIn(delay: (25 * i).ms).slideY(begin: .02);
          }),
        ],
      ),
    );
  }

  Widget _buildUsersTab() {
    final users = _users;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (users.isEmpty) {
      return _tabRefresh(
        child: _emptyState(
          icon: Icons.person_search_rounded,
          title: 'لا يوجد مستخدمين',
          subtitle: _query.isEmpty ? 'سيظهر المستخدمون هنا بعد تحميلهم.' : 'لا توجد نتائج مطابقة للبحث.',
        ),
      );
    }

    return _tabRefresh(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
        children: [
          Row(
            children: [
              const Expanded(
                child: AppText('إدارة المستخدمين', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              ),
              AppText('${users.length} نتيجة', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
            ],
          ),
          const SizedBox(height: 10),
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
                onEditStream: () => _openStreamEditorSheet(user),
              ),
            ).animate().fadeIn(delay: (25 * i).ms).slideY(begin: 0.025);
          }),
        ],
      ),
    );
  }

  Widget _buildPostsTab() {
    final posts = _filteredPosts;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (posts.isEmpty) {
      return _tabRefresh(
        child: _emptyState(
          icon: Icons.article_outlined,
          title: 'لا توجد منشورات',
          subtitle: _query.isEmpty ? 'لا توجد منشورات محفوظة حالياً.' : 'لا توجد منشورات مطابقة للبحث.',
        ),
      );
    }

    return _tabRefresh(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
        children: [
          Row(
            children: [
              const Expanded(
                child: AppText('إدارة المنشورات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              ),
              AppText('${posts.length} منشور', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
            ],
          ),
          const SizedBox(height: 10),
          ...List.generate(posts.length, (i) {
            final post = posts[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _AdminPostCard(
                post: post,
                author: _postValue(post, const ['username', 'author', 'postUsername'], '@user'),
                text: _postValue(post, const ['text', 'content', 'body'], 'منشور يحتوي على وسائط فقط'),
                createdAt: _postValue(post, const ['createdAt', 'created_at', 'time']),
                communityName: _postValue(post, const ['communityName', 'community_name']),
                reportCount: _postReportCount(post),
                onDelete: () => _deletePost(post),
              ),
            ).animate().fadeIn(delay: (20 * i).ms).slideY(begin: 0.02);
          }),
        ],
      ),
    );
  }

  Widget _buildStreamersHeader({required bool isDark, required int count}) {
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(colors: [AppColors.purple, Color(0xFF7C3AED)]),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.purple.withValues(alpha: .22),
                      blurRadius: 16,
                      offset: const Offset(0, 7),
                    ),
                  ],
                ),
                child: const Icon(Icons.live_tv_rounded, color: Colors.white, size: 23),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AppText('إدارة الستريمرز', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                    AppText(
                      count == 0 ? 'أضف القناة بالرابط فقط وتظهر في صفحة الستريمرز' : '$count قناة مضافة',
                      style: TextStyle(color: muted, fontWeight: FontWeight.w700, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _openAddStreamerSheet,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.purple,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
            ),
            icon: const Icon(Icons.add_link_rounded),
            label: const AppText('إضافة ستريمر جديد'),
          ),
        ],
      ),
    );
  }

  Widget _buildStreamersTab() {
    final streamers = _filteredStreamerUsers;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (streamers.isEmpty) {
      return _tabRefresh(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
          children: [
            _buildStreamersHeader(isDark: isDark, count: 0),
            const SizedBox(height: 14),
            _emptyStateCard(
              icon: Icons.live_tv_rounded,
              title: 'لا يوجد ستريمرز',
              subtitle: _query.isEmpty ? 'اضغط زر إضافة ستريمر جديد بالأعلى، وحط رابط القناة فقط.' : 'لا يوجد ستريمر مطابق للبحث.',
            ),
          ],
        ),
      );
    }

    return _tabRefresh(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
        children: [
          _buildStreamersHeader(isDark: isDark, count: streamers.length),
          const SizedBox(height: 10),
          ...List.generate(streamers.length, (i) {
            final user = streamers[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _StreamerAdminCard(
                user: user,
                avatarProvider: _avatarProvider(user.avatarPath),
                onEditStream: () => _openStreamEditorSheet(user),
                onRemoveStream: () => _setUserStreamData(user, clear: true),
              ),
            ).animate().fadeIn(delay: (25 * i).ms).slideY(begin: 0.02);
          }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgTop = isDark ? const Color(0xFF0B0714) : const Color(0xFFF7F4FF);
    final bgBottom = isDark ? AppColors.darkBg : AppColors.lightBg;

    return Scaffold(
      appBar: null,
      backgroundColor: bgBottom,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.purple))
          : DefaultTabController(
        length: 5,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [bgTop, bgBottom],
            ),
          ),
          child: SafeArea(
            child: NestedScrollView(
              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              headerSliverBuilder: (context, innerBoxIsScrolled) {
                return [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        _buildTopSummary(isDark),
                        _buildSearchBox(isDark),
                      ],
                    ),
                  ),
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _AdminPinnedTabsHeaderDelegate(
                      height: 96,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [bgTop, bgBottom.withValues(alpha: .96)],
                          ),
                        ),
                        child: _buildTabs(isDark),
                      ),
                    ),
                  ),
                ];
              },
              body: TabBarView(
                physics: const BouncingScrollPhysics(),
                children: [
                  _buildReportsTab(),
                  _buildUsersTab(),
                  _buildPostsTab(),
                  _buildStreamersTab(),
                  _buildGeneralNotificationTab(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

}






class _AdminPinnedTabsHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;

  const _AdminPinnedTabsHeaderDelegate({
    required this.height,
    required this.child,
  });

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      color: Colors.transparent,
      child: child,
    );
  }

  @override
  bool shouldRebuild(covariant _AdminPinnedTabsHeaderDelegate oldDelegate) {
    return oldDelegate.height != height || oldDelegate.child != child;
  }
}


class _AdminPostCard extends StatelessWidget {
  final Map<String, dynamic> post;
  final String author;
  final String text;
  final String createdAt;
  final String communityName;
  final int reportCount;
  final VoidCallback onDelete;

  const _AdminPostCard({
    required this.post,
    required this.author,
    required this.text,
    required this.createdAt,
    required this.communityName,
    required this.reportCount,
    required this.onDelete,
  });

  String _value(List<String> keys, [String fallback = '']) {
    for (final key in keys) {
      final value = post[key];
      if (value != null && value.toString().trim().isNotEmpty) return value.toString();
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;
    final id = _value(const ['id', 'postId', 'post_id']);
    final image = _value(const ['imageUrl', 'image_url', 'mediaPath', 'media_url']);
    final video = _value(const ['videoUrl', 'video_url']);
    final hasMedia = image.trim().isNotEmpty || video.trim().isNotEmpty;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.purple.withValues(alpha: .14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.article_rounded, color: AppColors.purple),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                    const SizedBox(height: 2),
                    AppText(
                      id.trim().isEmpty ? 'منشور بدون ID' : 'ID: $id',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: context.tr('حذف المنشور'),
                onPressed: onDelete,
                icon: const Icon(Icons.delete_rounded, color: AppColors.danger),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
            ),
            child: AppText(
              text.trim().isEmpty ? 'منشور يحتوي على وسائط فقط' : text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(height: 1.45, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 7,
            children: [
              if (createdAt.trim().isNotEmpty) _MiniChip(text: createdAt.split('T').first, color: muted),
              if (communityName.trim().isNotEmpty) _MiniChip(text: communityName, color: AppColors.success),
              if (reportCount > 0) _MiniChip(text: '$reportCount بلاغ', color: AppColors.danger),
              if (hasMedia) _MiniChip(text: video.trim().isNotEmpty ? 'فيديو' : 'صورة', color: AppColors.purple),
            ],
          ),
        ],
      ),
    );
  }
}

class _StreamerAdminCard extends StatelessWidget {
  final _AdminUser user;
  final ImageProvider? avatarProvider;
  final VoidCallback onEditStream;
  final VoidCallback onRemoveStream;

  const _StreamerAdminCard({
    required this.user,
    required this.avatarProvider,
    required this.onEditStream,
    required this.onRemoveStream,
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
                backgroundColor: AppColors.purple,
                backgroundImage: avatarProvider,
                child: avatarProvider == null
                    ? AppText(
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
                    AppText(user.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                    const SizedBox(height: 3),
                    AppText(user.username, style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              _MiniChip(text: 'قناة مستقلة', color: AppColors.success),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
            ),
            child: Row(
              children: [
                const Icon(Icons.link_rounded, color: AppColors.purple, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: AppText(
                    user.streamUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted, fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _MiniChip(text: user.streamIsLive ? 'مباشر الآن' : 'غير مباشر', color: user.streamIsLive ? AppColors.success : muted),
              _MiniChip(text: '${user.streamViewers} مشاهد', color: AppColors.purple),
              if (user.streamPlatform.trim().isNotEmpty) _MiniChip(text: user.streamPlatform, color: muted),
            ],
          ),
          if (user.streamTitle.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppText(
                user.streamTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onEditStream,
                icon: const Icon(Icons.edit_rounded, color: AppColors.purple),
                label: const AppText('تعديل', style: TextStyle(fontWeight: FontWeight.w900)),
              ),
              OutlinedButton.icon(
                onPressed: onRemoveStream,
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                icon: const Icon(Icons.delete_rounded),
                label: const AppText('حذف', style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


class _AddStreamerSheet extends StatefulWidget {
  const _AddStreamerSheet();

  @override
  State<_AddStreamerSheet> createState() => _AddStreamerSheetState();
}

class _AddStreamerSheetState extends State<_AddStreamerSheet> {
  late final TextEditingController _streamUrlCtrl;

  @override
  void initState() {
    super.initState();
    _streamUrlCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _streamUrlCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(_streamUrlCtrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.38,
        maxChildSize: 0.82,
        expand: false,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkBg : AppColors.lightBg,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
              border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
                  blurRadius: 30,
                  offset: const Offset(0, -8),
                ),
              ],
            ),
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 48,
                        height: 5,
                        decoration: BoxDecoration(
                          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFFB678FF)]),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.purple.withValues(alpha: .22),
                                blurRadius: 18,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(Icons.add_link_rounded, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const AppText('إضافة ستريمر بالرابط', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                              AppText(
                                'حط رابط القناة فقط، وRespect يجلب الاسم والصورة والمنصة تلقائيًا.',
                                style: TextStyle(color: muted, fontWeight: FontWeight.w700, fontSize: 12.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _streamUrlCtrl,
                      autofocus: true,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.link_rounded),
                        hintText: context.tr('مثال: https://kick.com/channel أو twitch.tv/name'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: AppColors.purple.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: AppColors.purple.withValues(alpha: .12)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.auto_awesome_rounded, color: AppColors.purple, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: AppText(
                              'سيتم حفظ القناة في تبويب الستريمرز وتظهر مباشرة في صفحة البث. الحذف والتعديل من نفس الكرت.',
                              style: TextStyle(color: muted, fontWeight: FontWeight.w800, fontSize: 12.5, height: 1.35),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.purple,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(54),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                        onPressed: _submit,
                        icon: const Icon(Icons.cloud_download_rounded),
                        label: const AppText('جلب البيانات وإضافة الستريمر', style: TextStyle(fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
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
        title: const AppText('تفاصيل البلاغ', style: TextStyle(fontWeight: FontWeight.w900)),
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
                        color: AppColors.purple.withValues(alpha: 0.16),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.article_rounded, color: AppColors.purple),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppText('التغريدة المبلّغ عنها', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                          const SizedBox(height: 2),
                          AppText('صاحب التغريدة: $_postUser', style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w700)),
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
                  child: AppText(
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
                        child: AppText(
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
                        color: AppColors.danger.withValues(alpha: 0.16),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.report_rounded, color: AppColors.danger),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppText('البلاغ', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                          const SizedBox(height: 2),
                          AppText('المبلّغ: $_reporter', style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w700)),
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
                      color: status == 'accepted' ? AppColors.danger.withValues(alpha: 0.10) : AppColors.success.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: AppText(
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
                label: AppText(reviewing ? 'جاري المراجعة...' : 'مراجعة Respect AI', style: const TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: context.tr('حذف البلاغ'),
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
          AppText(label, style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          AppText(value, style: const TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w800)),
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
                  decoration: BoxDecoration(color: AppColors.danger.withValues(alpha: 0.14), shape: BoxShape.circle),
                  child: const Icon(Icons.report_rounded, color: AppColors.danger),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText(type, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                      const SizedBox(height: 2),
                      AppText('المبلِّغ: $reporter · على: $postUser', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted, fontSize: 12)),
                    ],
                  ),
                ),
                if (reviewing)
                  const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.purple))
                else
                  IconButton(
                    tooltip: reviewed ? context.tr('إعادة مراجعة البلاغ بالذكاء الاصطناعي') : context.tr('مراجعة البلاغ بالذكاء الاصطناعي'),
                    onPressed: onReview,
                    icon: Icon(reviewed ? Icons.refresh_rounded : Icons.smart_toy_rounded, color: AppColors.purple),
                  ),
                IconButton(
                  tooltip: context.tr('حذف البلاغ'),
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
              child: AppText(text.trim().isEmpty ? 'تغريدة تحتوي على وسائط فقط' : text, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(height: 1.35)),
            ),
            if (aiReason.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: status == 'accepted' ? AppColors.danger.withValues(alpha: 0.10) : AppColors.success.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: AppText(
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
              color: AppColors.purple.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.admin_panel_settings_rounded, color: AppColors.purple, size: 30),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppText('لوحة تحكم حقيقية', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 3),
                AppText(
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
                  AppText(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: compact ? 20 : 22, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 1),
                  AppText(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: compact ? 12 : 13),
                  ),
                  SizedBox(height: compact ? 2 : 3),
                  AppText(
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
  final VoidCallback onEditStream;

  const _UserAdminCard({
    required this.user,
    required this.avatarProvider,
    required this.onBlock,
    required this.onAdmin,
    required this.onDeleteContent,
    required this.onEditStream,
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
                    ? AppText(
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
                          child: AppText(
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
                    AppText(user.username, style: TextStyle(color: muted, fontSize: 12)),
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
                  if (value == 'stream') onEditStream();
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'block',
                    child: Row(
                      children: [
                        Icon(user.isBlocked ? Icons.lock_open_rounded : Icons.block_rounded,
                            color: user.isBlocked ? AppColors.success : AppColors.danger),
                        const SizedBox(width: 8),
                        AppText(user.isBlocked ? 'إلغاء الحظر' : 'حظر كامل'),
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
                        AppText(user.isAdmin ? 'إزالة الأدمن' : 'ترقية أدمن'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'stream',
                    child: Row(
                      children: [
                        Icon(Icons.live_tv_rounded, color: AppColors.purple),
                        SizedBox(width: 8),
                        AppText('بيانات البث'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete_content',
                    child: Row(
                      children: [
                        Icon(Icons.cleaning_services_rounded, color: AppColors.danger),
                        SizedBox(width: 8),
                        AppText('حذف محتواه'),
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
                    AppText(
                      'البث: ${user.streamUrl}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  if (user.blockedReason.trim().isNotEmpty)
                    AppText(
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
                  label: AppText(user.isBlocked ? 'فك الحظر' : 'حظر', style: const TextStyle(fontWeight: FontWeight.w900)),
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
                  label: AppText(user.isAdmin ? 'إزالة' : 'ترقية', style: const TextStyle(fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onEditStream,
              icon: const Icon(Icons.live_tv_rounded, color: AppColors.purple, size: 18),
              label: AppText(
                user.streamUrl.trim().isEmpty ? 'إضافة بيانات بث' : 'تعديل بيانات البث',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
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
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: AppText(
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
  final String streamName;
  final String streamTitle;
  final bool streamIsLive;
  final int streamViewers;
  final String streamThumbnailUrl;
  final String streamThumbnailPath;
  final String streamPlatform;
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
    required this.streamName,
    required this.streamTitle,
    required this.streamIsLive,
    required this.streamViewers,
    required this.streamThumbnailUrl,
    required this.streamThumbnailPath,
    required this.streamPlatform,
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
      avatarPath: (map['avatar_url'] ?? map['imagePath'] ?? map['profileImagePath'] ?? map['streamThumbnailPath'] ?? map['streamThumbnailUrl'] ?? '').toString(),
      streamUrl: (map['streamUrl'] ?? '').toString(),
      streamName: (map['streamName'] ?? map['streamerName'] ?? '').toString(),
      streamTitle: (map['streamTitle'] ?? '').toString(),
      streamIsLive: map['streamIsLive'] == true || map['streamIsLive']?.toString() == 'true',
      streamViewers: int.tryParse((map['streamViewers'] ?? 0).toString().replaceAll(',', '')) ?? 0,
      streamThumbnailUrl: (map['streamThumbnailUrl'] ?? '').toString(),
      streamThumbnailPath: (map['streamThumbnailPath'] ?? map['streamThumbnailUrl'] ?? '').toString(),
      streamPlatform: (map['streamPlatform'] ?? '').toString(),
      isAdmin: isAdmin,
      isBlocked: isBlocked,
      isReported: map['isReported'] == true || map['reported'] == true,
      blockedReason: (map['blockedReason'] ?? map['blocked_reason'] ?? '').toString(),
      deviceId: (map['current_device_id'] ?? map['device_id'] ?? map['last_device_id'] ?? '').toString(),
      deviceBanned: map['device_banned'] == true || map['device_blocked'] == true,
    );
  }
}
