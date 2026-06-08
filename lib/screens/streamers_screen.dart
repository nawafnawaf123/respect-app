import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';

void _respectSafeLog(Object error, [StackTrace? stackTrace]) {
  if (kDebugMode) {
    debugPrint('Respect safe catch: $error');
    if (stackTrace != null) debugPrintStack(stackTrace: stackTrace);
  }
}


class StreamersScreen extends StatefulWidget {
  const StreamersScreen({super.key});

  @override
  State<StreamersScreen> createState() => _StreamersScreenState();
}

class _StreamersScreenState extends State<StreamersScreen> with SingleTickerProviderStateMixin {
  static const String _accountsKey = 'respect_accounts_v1';
  static const String _usersKey = 'respect_users_map';

  late final TabController _tabController = TabController(length: 2, vsync: this);
  final List<_StreamerVM> _streamers = [];
  Timer? _autoRefreshTimer;
  bool _loading = true;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _loadStreamers();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (mounted) _loadStreamers(silent: true);
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadStreamers({bool silent = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (!silent && mounted) setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    final accounts = <Map<String, dynamic>>[];

    final accountsRaw = prefs.getString(_accountsKey);
    if (accountsRaw != null && accountsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(accountsRaw);
        if (decoded is List) {
          accounts.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (e, st) { _respectSafeLog(e, st); }
    }

    if (accounts.isEmpty) {
      final usersRaw = prefs.getString(_usersKey);
      if (usersRaw != null && usersRaw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(usersRaw);
          if (decoded is Map) {
            decoded.forEach((key, value) {
              if (value is Map) {
                final item = value.map((k, v) => MapEntry(k.toString(), v));
                accounts.add({...item, 'id': (item['id'] ?? key).toString()});
              }
            });
          }
        } catch (e, st) { _respectSafeLog(e, st); }
      }
    }

    final refreshedAccounts = <Map<String, dynamic>>[];
    for (final account in accounts) {
      final url = (account['streamUrl'] ?? '').toString().trim();
      if (url.isEmpty) {
        refreshedAccounts.add(account);
        continue;
      }

      final fallbackName = (account['profileName'] ?? account['name'] ?? account['streamName'] ?? 'Streamer').toString();
      final meta = await _fetchStreamMetadata(url, fallbackName: fallbackName);
      final cachedThumbnailPath = meta.thumbnailUrl.trim().isEmpty
          ? ''
          : await _cacheBestStreamThumbnail(meta.thumbnailUrl, platform: meta.platform, channel: _channelFromUrl(url));
      final finalThumbnailPath = _safeStreamThumbnailValue(
        cachedPath: cachedThumbnailPath,
        remoteUrl: meta.thumbnailUrl,
        previousValue: (account['streamThumbnailPath'] ?? '').toString(),
      );
      refreshedAccounts.add({
        ...account,
        'streamName': meta.channelName.isNotEmpty
            ? meta.channelName
            : (account['streamName'] ?? account['streamerName'] ?? fallbackName).toString(),
        'streamTitle': meta.title,
        'streamIsLive': meta.isLive,
        'streamViewers': meta.viewers,
        'streamThumbnailUrl': meta.thumbnailUrl,
        'streamThumbnailPath': finalThumbnailPath,
        'streamPlatform': meta.platform,
        'streamLastCheckedAt': DateTime.now().toIso8601String(),
      });
    }

    if (refreshedAccounts.isNotEmpty) {
      await prefs.setString(_accountsKey, jsonEncode(refreshedAccounts));
      final usersRaw = prefs.getString(_usersKey);
      if (usersRaw != null && usersRaw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(usersRaw);
          if (decoded is Map) {
            for (final account in refreshedAccounts) {
              final id = (account['id'] ?? '').toString();
              if (id.isNotEmpty && decoded[id] is Map) {
                decoded[id] = {
                  ...Map<String, dynamic>.from((decoded[id] as Map).map((k, v) => MapEntry(k.toString(), v))),
                  ...account
                };
              }
            }
            await prefs.setString(_usersKey, jsonEncode(decoded));
          }
        } catch (e, st) { _respectSafeLog(e, st); }
      }
    }

    final loaded = refreshedAccounts
        .map(_StreamerVM.fromAccount)
        .where((s) => s.url.trim().isNotEmpty)
        .toList()
      ..sort((a, b) {
        if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
        return b.viewers.compareTo(a.viewers);
      });

    if (!mounted) return;
    setState(() {
      _streamers
        ..clear()
        ..addAll(loaded);
      _loading = false;
      _refreshing = false;
    });
  }

  void _openStreamOptions(String url) {
    final clean = url.trim();
    if (clean.isEmpty) return;
    final uri = clean.startsWith('http') ? clean : 'https://$clean';

    showModalBottomSheet(
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
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
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
                const Text('اختر طريقة المشاهدة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 14),
                ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.purple.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.open_in_browser_rounded, color: AppColors.purple),
                  ),
                  title: const Text('فتح في المتصفح', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: const Text('يفتح الرابط في تطبيق المتصفح الخارجي'),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  onTap: () async {
                    Navigator.pop(context);
                    await launchUrl(Uri.parse(uri), mode: LaunchMode.externalApplication);
                  },
                ),
                const SizedBox(height: 10),
                ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.purple.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.play_circle_fill_rounded, color: AppColors.purple),
                  ),
                  title: const Text('تشغيل داخل التطبيق', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: const Text('يفتح صفحة البث مباشرة (موصى به)'),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => StreamPlayerScreen(url: uri),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<_StreamerVM> get _liveStreamers {
    final list = _streamers.where((s) => s.isLive).toList();
    list.sort((a, b) => b.viewers.compareTo(a.viewers));
    return list;
  }

  List<_StreamerVM> get _allChannels {
    final list = _streamers.where((s) => !s.isLive).toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final live = _liveStreamers;
    final all = _allChannels;
    final bg = isDark ? const Color(0xFF0D0D12) : const Color(0xFFF5F5F7);
    final bgBottom = isDark ? const Color(0xFF080810) : Colors.white;

    return Scaffold(
      appBar: null,
      backgroundColor: bgBottom,
      body: _loading
          ? Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bg, bgBottom],
          ),
        ),
        child: const Center(child: CircularProgressIndicator(color: AppColors.purple, strokeWidth: 2.4)),
      )
          : Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bg, bgBottom],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: AppColors.purple,
            backgroundColor: isDark ? const Color(0xFF1A1A24) : Colors.white,
            onRefresh: _loadStreamers,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: const LinearGradient(
                            colors: [Color(0xFF7C3AED), Color(0xFFB678FF)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.purple.withValues(alpha: .22),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.live_tv_rounded, color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'البث المباشر',
                              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -.6),
                            ),
                            if (live.isNotEmpty)
                              Text(
                                '${live.length} بث نشط الآن',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? Colors.white54 : const Color(0xFF7B7286),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ).animate().fadeIn(duration: 260.ms),
                ),
                const SizedBox(height: 14),
                // ── Tab Bar ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    height: 46,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withValues(alpha: .055) : Colors.white.withValues(alpha: .80),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.purple.withValues(alpha: .12)),
                    ),
                    child: TabBar(
                      controller: _tabController,
                      dividerColor: Colors.transparent,
                      indicatorSize: TabBarIndicatorSize.tab,
                      indicator: BoxDecoration(
                        color: AppColors.purple,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.purple.withValues(alpha: .20),
                            blurRadius: 14,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      labelColor: Colors.white,
                      unselectedLabelColor: isDark ? Colors.white60 : const Color(0xFF6E6478),
                      labelStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                      tabs: const [
                        Tab(text: 'مباشر الآن'),
                        Tab(text: 'القنوات'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // ── Content ──
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _StreamersList(
                        streamers: live,
                        emptyTitle: 'لا يوجد بث مباشر الآن',
                        emptySubtitle: 'سيظهر هنا تلقائيًا أي بث نشط بعد الفحص.',
                        isDark: isDark,
                        onOpen: _openStreamOptions,
                        liveLayout: true,
                      ),
                      _StreamersList(
                        streamers: all,
                        emptyTitle: 'لا توجد قنوات بعد',
                        emptySubtitle: 'أضف رابط Twitch أو Kick أو YouTube من صفحة حسابك.',
                        isDark: isDark,
                        onOpen: _openStreamOptions,
                        liveLayout: false,
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

// ---------- عرض القوائم ----------

class _StreamersList extends StatelessWidget {
  final List<_StreamerVM> streamers;
  final String emptyTitle;
  final String emptySubtitle;
  final bool isDark;
  final void Function(String url) onOpen;
  final bool liveLayout;

  const _StreamersList({
    required this.streamers,
    required this.emptyTitle,
    required this.emptySubtitle,
    required this.isDark,
    required this.onOpen,
    required this.liveLayout,
  });

  @override
  Widget build(BuildContext context) {
    if (streamers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppColors.purple.withValues(alpha: .09),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: AppColors.purple.withValues(alpha: .14)),
                ),
                child: Icon(
                  liveLayout ? Icons.live_tv_rounded : Icons.video_library_rounded,
                  size: 34,
                  color: AppColors.purple,
                ),
              ),
              const SizedBox(height: 16),
              Text(emptyTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Text(
                emptySubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark ? AppColors.darkMuted : AppColors.lightMuted,
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: streamers.length,
      itemBuilder: (context, i) {
        final s = streamers[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: liveLayout && s.isLive
              ? _LiveStreamCard(streamer: s, isDark: isDark, onOpen: () => onOpen(s.url))
              : _ChannelCard(streamer: s, isDark: isDark, onOpen: () => onOpen(s.url)),
        ).animate().fadeIn(delay: (55 * i).ms).slideY(begin: 0.025);
      },
    );
  }
}

class _LiveStreamCard extends StatelessWidget {
  final _StreamerVM streamer;
  final bool isDark;
  final VoidCallback onOpen;

  const _LiveStreamCard({required this.streamer, required this.isDark, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final thumbnail = _streamImageProvider(streamer.thumbnailPath) ??
        _streamImageProvider(streamer.coverPath);
    final avatar = _streamImageProvider(streamer.avatarPath);

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (thumbnail != null)
                    Image(image: thumbnail, fit: BoxFit.cover, gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const _StreamFallbackBackground())
                  else
                    const _StreamFallbackBackground(),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black.withValues(alpha: 0.12), Colors.black.withValues(alpha: 0.72)],
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    top: 10,
                    start: 10,
                    child: _LiveBadge(viewers: streamer.viewers),
                  ),
                  PositionedDirectional(
                    bottom: 12,
                    start: 12,
                    end: 12,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        CircleAvatar(
                          radius: 26,
                          backgroundColor: AppColors.purple,
                          backgroundImage: avatar,
                          child: avatar == null
                              ? Text(streamer.name.characters.first,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900))
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                streamer.title.isEmpty ? 'بث مباشر الآن' : streamer.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(height: 2),
                              Text('${streamer.name} · ${streamer.platform}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.open_in_new_rounded, color: Colors.white),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    streamer.title.isEmpty ? streamer.name : streamer.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isDark ? Colors.white70 : const Color(0xFF4A4254),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                Text(
                  '${_formatNumber(streamer.viewers)} مشاهد',
                  style: const TextStyle(color: AppColors.purple, fontWeight: FontWeight.w900, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelCard extends StatelessWidget {
  final _StreamerVM streamer;
  final bool isDark;
  final VoidCallback onOpen;

  const _ChannelCard({required this.streamer, required this.isDark, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final avatar = _streamImageProvider(streamer.avatarPath);
    final muted = isDark ? AppColors.darkMuted : AppColors.lightMuted;

    return GlassCard(
      onTap: onOpen,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.purple.withValues(alpha: .18)),
            ),
            child: CircleAvatar(
              radius: 26,
              backgroundColor: AppColors.purple.withValues(alpha: .15),
              backgroundImage: avatar,
              child: avatar == null
                  ? Text(
                streamer.name.characters.first,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18),
              )
                  : null,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        streamer.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15.5),
                      ),
                    ),
                    if (streamer.isLive) const _MiniLiveBadge(),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  streamer.platform,
                  style: TextStyle(color: muted, fontWeight: FontWeight.w700, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Icon(Icons.open_in_new_rounded, color: AppColors.purple.withValues(alpha: .55), size: 20),
        ],
      ),
    );
  }
}

class _StreamFallbackBackground extends StatelessWidget {
  const _StreamFallbackBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [AppColors.purple, Color(0xFF3B0764)]),
      ),
      child: const Icon(Icons.live_tv_rounded, size: 72, color: Colors.white70),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  final int viewers;
  const _LiveBadge({required this.viewers});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(999)),
          child: const Text('LIVE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.58), borderRadius: BorderRadius.circular(999)),
          child: Text('${_formatNumber(viewers)} مشاهد',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
        ),
      ],
    );
  }
}

class _MiniLiveBadge extends StatelessWidget {
  const _MiniLiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(999)),
      child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900)),
    );
  }
}

class _StreamerVM {
  final String name;
  final String username;
  final String url;
  final String platform;
  final String title;
  final bool isLive;
  final int viewers;
  final String? avatarPath;
  final String? coverPath;
  final String? thumbnailPath;

  const _StreamerVM({
    required this.name,
    required this.username,
    required this.url,
    required this.platform,
    required this.title,
    required this.isLive,
    required this.viewers,
    required this.avatarPath,
    required this.coverPath,
    required this.thumbnailPath,
  });

  factory _StreamerVM.fromAccount(Map<String, dynamic> account) {
    final url = (account['streamUrl'] ?? '').toString().trim();
    final streamName = (account['streamName'] ?? account['streamerName'] ?? '').toString().trim();
    final profileName = (account['profileName'] ?? account['name'] ?? 'Streamer').toString().trim();
    final username = _cleanUsername((account['username'] ?? account['id'] ?? '@user').toString());
    final platform = _platformFromUrl(url);
    final viewers = int.tryParse((account['streamViewers'] ?? '0').toString().replaceAll(',', '')) ?? 0;

    return _StreamerVM(
      name: streamName.isEmpty ? profileName : streamName,
      username: username,
      url: url,
      platform: platform,
      title: (account['streamTitle'] ?? '').toString(),
      isLive: account['streamIsLive'] == true || account['streamIsLive']?.toString() == 'true',
      viewers: viewers < 0 ? 0 : viewers,
      avatarPath: (account['imagePath'] ?? account['profileImagePath'])?.toString(),
      coverPath: account['coverPath']?.toString(),
      thumbnailPath: (account['streamThumbnailPath'] ?? account['streamThumbnailUrl'])?.toString(),
    );
  }
}

// ---------- دوال الصور والبث ----------

ImageProvider? _streamImageProvider(String? path) {
  if (path == null || path.trim().isEmpty) return null;
  final clean = _normalizeStreamImageUrl(path);
  if (clean.startsWith('http://') || clean.startsWith('https://')) {
    if (_isKickProtectedThumbnailUrl(clean)) return null;
    return NetworkImage(clean, headers: _streamImageHeaders(clean));
  }
  final file = File(clean);
  if (!file.existsSync()) return null;
  return FileImage(file);
}

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
    HttpHeaders.userAgentHeader:
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
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

String _safeStreamThumbnailValue({
  required String cachedPath,
  required String remoteUrl,
  String? previousValue,
}) {
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
  final candidates = platform.toLowerCase() == 'kick'
      ? _kickThumbnailCandidates(url, channel)
      : <String>[_normalizeStreamImageUrl(url)];

  for (final candidate in candidates) {
    if (candidate.isEmpty) continue;
    if (platform.toLowerCase() == 'kick' && candidate.startsWith('https://kick.com/') && !candidate.contains('/thumbnail')) {
      try {
        final html = await _readUrl(candidate);
        final extracted = _firstNonEmpty([
          _meta(html, 'property', 'og:image'),
          _meta(html, 'property', 'og:image:secure_url'),
          _meta(html, 'name', 'twitter:image'),
          _jsonString(html, 'thumbnailUrl'),
          _jsonString(html, 'thumbnail_url'),
        ]);
        final path = await _cacheStreamThumbnail(extracted, platform: platform);
        if (path.isNotEmpty) return path;
      } catch (e, st) { _respectSafeLog(e, st); }
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
    final ext = clean.toLowerCase().contains('.png')
        ? 'png'
        : clean.toLowerCase().contains('.webp')
        ? 'webp'
        : 'jpg';
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

// ---------- دوال جلب بيانات البث ----------
String _cleanUsername(String value) {
  final v = value.trim().replaceAll(RegExp(r'\s+'), '_').replaceAll('@', '').toLowerCase();
  return v.isEmpty ? '@user' : '@$v';
}

String _platformFromUrl(String url) {
  final u = url.toLowerCase();
  if (u.contains('kick.com')) return 'Kick';
  if (u.contains('twitch.tv')) return 'Twitch';
  if (u.contains('youtube.com') || u.contains('youtu.be')) return 'YouTube';
  if (u.contains('facebook.com')) return 'Facebook';
  return 'Stream';
}

String _formatNumber(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(value >= 10000000 ? 0 : 1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(value >= 10000 ? 0 : 1)}K';
  return value.toString();
}

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
    return await _fetchGenericMetadata(cleanUrl, fallbackName: fallbackName, platform: platform, channel: channel);
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

Future<_StreamMetadata> _fetchKickMetadata(String url, String channel, {required String fallbackName}) async {
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
      final viewers = _toInt(_firstNonEmpty([
        liveMap['viewer_count']?.toString() ?? '',
        liveMap['viewers']?.toString() ?? '',
        data['viewer_count']?.toString() ?? ''
      ]));
      final title = _cleanHtml(_firstNonEmpty([
        liveMap['session_title']?.toString() ?? '',
        liveMap['title']?.toString() ?? ''
      ]));
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
      final name = _firstNonEmpty([
        data['slug']?.toString() ?? '',
        userMap['username']?.toString() ?? '',
        channel,
        fallbackName
      ]);
      return _StreamMetadata(
          platform: 'Kick',
          channelName: name,
          title: title,
          thumbnailUrl: thumbnail,
          isLive: isLive,
          viewers: viewers);
    } catch (e, st) { _respectSafeLog(e, st); }
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
  } catch (e, st) { _respectSafeLog(e, st); }

  try {
    final gqlBody = jsonEncode([
      {
        'operationName': 'StreamMetadata',
        'variables': {'channelLogin': channel.toLowerCase()},
        'extensions': {
          'persistedQuery': {
            'version': 1,
            'sha256Hash': 'a647c2a13599e5991e175155f798ca7f1ecddde73f7f341f39009c14dbf59962'
          }
        }
      }
    ]);
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
          thumbnail = _firstNonEmpty(
              [streamMap['previewImageURL']?.toString() ?? '', thumbnail, profileImage]);
        } else {
          thumbnail = _firstNonEmpty([thumbnail, profileImage]);
        }
        channelName = _firstNonEmpty([user['displayName']?.toString() ?? '', channelName, fallbackName]);
      }
    }
  } catch (e, st) { _respectSafeLog(e, st); }

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
    } catch (e, st) { _respectSafeLog(e, st); }
  }

  return _StreamMetadata(
      platform: 'Twitch',
      channelName: channelName,
      title: title,
      thumbnailUrl: thumbnail,
      isLive: isLive,
      viewers: viewers);
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
  } catch (e, st) { _respectSafeLog(e, st); }
  try {
    final html = await _readUrl(url);
    final generic = _metadataFromHtml(html, fallbackName: fallbackName, platform: 'YouTube', channel: channelName);
    title = _firstNonEmpty([title, generic.title]);
    thumbnail = _firstNonEmpty([thumbnail, generic.thumbnailUrl]);
    viewers = generic.viewers;
    isLive = generic.isLive;
    channelName = _firstNonEmpty([channelName, generic.channelName, fallbackName]);
  } catch (e, st) { _respectSafeLog(e, st); }
  return _StreamMetadata(
      platform: 'YouTube',
      channelName: channelName.isNotEmpty ? channelName : fallbackName,
      title: title,
      thumbnailUrl: thumbnail,
      isLive: isLive,
      viewers: viewers);
}

Future<_StreamMetadata> _fetchGenericMetadata(String url,
    {required String fallbackName, required String platform, required String channel}) async {
  final html = await _readUrl(url);
  return _metadataFromHtml(html, fallbackName: fallbackName, platform: platform, channel: channel);
}

_StreamMetadata _metadataFromHtml(String html,
    {required String fallbackName, required String platform, required String channel}) {
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
  return _StreamMetadata(
      platform: platform,
      channelName: channel.isNotEmpty ? channel : fallbackName,
      title: title,
      thumbnailUrl: image,
      isLive: live,
      viewers: viewers);
}

Future<String> _readUrl(String url, {bool json = false}) async {
  final uri = Uri.parse(url);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36 RespectApp/1.0');
    request.headers.set(HttpHeaders.acceptHeader,
        json ? 'application/json,text/plain,*/*' : 'text/html,application/xhtml+xml,application/json,text/plain,*/*');
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
  final patternA = RegExp(
      '<meta[^>]*$attrName=["\\\']$attrValue["\\\'][^>]*content=["\\\']([^"\\\']*)["\\\'][^>]*>',
      caseSensitive: false,
      dotAll: true);
  final patternB = RegExp(
      '<meta[^>]*content=["\\\']([^"\\\']*)["\\\'][^>]*$attrName=["\\\']$attrValue["\\\'][^>]*>',
      caseSensitive: false,
      dotAll: true);
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

String _firstNonEmpty(List<String> values) =>
    values.firstWhere((v) => v.trim().isNotEmpty, orElse: () => '').trim();

String _cleanHtml(String value) => value
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('\\/', '/')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

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
  return viewers > 0 ||
      h.contains('"is_live":true') ||
      h.contains('"islive":true') ||
      h.contains('"islivebroadcast":true') ||
      h.contains('"status":"live"') ||
      h.contains('live_user') ||
      h.contains('watching now') ||
      h.contains('is currently live') ||
      t.contains(' live') ||
      t.contains('مباشر');
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
  const _StreamMetadata({
    required this.platform,
    required this.channelName,
    required this.title,
    required this.thumbnailUrl,
    required this.isLive,
    required this.viewers,
  });
  bool get hasUsefulData =>
      title.trim().isNotEmpty ||
          thumbnailUrl.trim().isNotEmpty ||
          isLive ||
          viewers > 0 ||
          channelName.trim().isNotEmpty;
  factory _StreamMetadata.empty() => const _StreamMetadata(
      platform: '', channelName: '', title: '', thumbnailUrl: '', isLive: false, viewers: 0);
}

// -------------------------------------------------
// دوال تحويل الروابط لنسخة قابلة للتشغيل داخل WebView
// -------------------------------------------------
String _webViewUserAgentForStream(String url) {
  final u = url.toLowerCase();
  if (u.contains('kick.com') || u.contains('twitch.tv')) {
    return 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
  }
  return 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36 RespectApp/1.0';
}

String _directMobileStreamUrl(String value) {
  final clean = _cleanStreamUrl(value);
  if (clean.isEmpty) return '';
  try {
    final uri = Uri.parse(clean);
    final host = uri.host.toLowerCase();
    final parts = uri.pathSegments.where((e) => e.trim().isNotEmpty).toList();
    if (host.contains('twitch.tv') && parts.isNotEmpty) {
      final channel = parts.first.replaceAll('@', '').trim();
      if (channel.isNotEmpty && channel != 'videos' && channel != 'directory') return 'https://m.twitch.tv/$channel';
    }
    if (host.contains('kick.com') && parts.isNotEmpty) {
      final channel = parts.first.replaceAll('@', '').trim();
      if (channel.isNotEmpty && channel != 'video' && channel != 'categories') return 'https://kick.com/$channel';
    }
    return clean;
  } catch (_) {
    return clean;
  }
}

// ---------- شاشة تشغيل البث داخل التطبيق (محسّنة) ----------

class StreamPlayerScreen extends StatefulWidget {
  final String url;
  const StreamPlayerScreen({super.key, required this.url});

  @override
  State<StreamPlayerScreen> createState() => _StreamPlayerScreenState();
}

class _StreamPlayerScreenState extends State<StreamPlayerScreen> with WidgetsBindingObserver {
  late final WebViewController _controller;
  late String _originalUrl;
  Timer? _hideLoaderTimer;
  Timer? _antiBlackTimer;

  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';
  int _progress = 0;
  String _currentMode = 'direct'; // direct, smart, mobile

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _originalUrl = _cleanStreamUrl(widget.url);
    _initWebView();
    // الافتراضي: فتح صفحة البث المباشرة
    _loadChannelPage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideLoaderTimer?.cancel();
    _antiBlackTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _injectPlayerFixes();
    }
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress.clamp(0, 100).toInt());
            if (progress >= 35) _finishLoadingSoon(seconds: 1);
          },
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _isLoading = true;
              _hasError = false;
              _errorMessage = '';
            });
            _startAntiBlackTimer();
            _finishLoadingSoon(seconds: 4);
          },
          onPageFinished: (_) async {
            await _injectPlayerFixes();
            _finishLoadingSoon(seconds: 1);
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            if (error.isForMainFrame == true) {
              setState(() {
                _isLoading = false;
                _hasError = true;
                _errorMessage = error.description;
              });
            }
          },
          onNavigationRequest: (request) {
            final url = request.url.toLowerCase();
            final internal = url.startsWith('https://kick.com') ||
                url.startsWith('https://www.kick.com') ||
                url.startsWith('https://player.kick.com') ||
                url.startsWith('https://m.twitch.tv') ||
                url.startsWith('https://www.twitch.tv') ||
                url.startsWith('https://player.twitch.tv') ||
                url.startsWith('https://www.youtube.com') ||
                url.startsWith('https://m.youtube.com') ||
                url.startsWith('https://youtu.be') ||
                url.startsWith('about:blank') ||
                url.startsWith('data:text/html');
            return internal ? NavigationDecision.navigate : NavigationDecision.prevent;
          },
        ),
      );
  }

  // نستخدم WebViewWidget العادي بدون Hybrid Composition لتجنب مشاكل التوافق
  Widget _buildPlatformWebView() {
    return WebViewWidget(controller: _controller);
  }

  void _finishLoadingSoon({int seconds = 1}) {
    _hideLoaderTimer?.cancel();
    _hideLoaderTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted) return;
      setState(() => _isLoading = false);
    });
  }

  void _startAntiBlackTimer() {
    _antiBlackTimer?.cancel();
    _antiBlackTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _injectPlayerFixes());
  }

  Future<void> _injectPlayerFixes() async {
    try {
      await _controller.runJavaScript('''
        try{
          document.querySelectorAll('video').forEach(function(v){
            v.setAttribute('playsinline','true');
            v.setAttribute('webkit-playsinline','true');
            v.autoplay = true;
            v.style.opacity = '1';
            v.style.visibility = 'visible';
            v.style.display = 'block';
            v.style.background = '#000';
            v.style.objectFit = 'contain';
            try{v.play()}catch(e){}
          });
          document.querySelectorAll('iframe').forEach(function(f){
            f.allow = 'autoplay; fullscreen; picture-in-picture; encrypted-media';
            f.style.opacity = '1';
            f.style.visibility = 'visible';
            f.style.display = 'block';
            f.style.background = '#000';
          });
        }catch(e){}
      ''');
    } catch (e, st) { _respectSafeLog(e, st); }
  }

  // ----- طرق التحميل المختلفة -----

  // 1. الصفحة المباشرة (افتراضي) – تحميل رابط القناة الأصلي
  Future<void> _loadChannelPage() async {
    _currentMode = 'direct';
    final urlToLoad = _cleanStreamUrl(_originalUrl); // الرابط الأصلي كما هو
    await _loadRequest(urlToLoad);
  }

  // 2. صفحة الموبايل (للتوافق الأفضل)
  Future<void> _loadMobilePage() async {
    _currentMode = 'mobile';
    final mobileUrl = _directMobileStreamUrl(_originalUrl);
    await _loadRequest(mobileUrl);
  }

  // 3. المشغل الذكي: يحاول استخدام embedded player لـ YouTube، أو الصفحة المباشرة للمنصات الأخرى
  Future<void> _loadSmartPlayer() async {
    _currentMode = 'smart';
    final platform = _platformFromUrl(_originalUrl).toLowerCase();
    if (platform == 'youtube') {
      // لليوتيوب نستخدم embedded HTML
      final html = _youtubeEmbedHtml(_originalUrl);
      if (html != null) {
        await _loadHtml(html);
        return;
      }
    }
    // لباقي المنصات نحمّل الصفحة المباشرة
    await _loadChannelPage();
  }

  Future<void> _loadRequest(String url) async {
    final clean = _cleanStreamUrl(url);
    if (clean.isEmpty) return;
    if (mounted) setState(() {
      _isLoading = true;
      _hasError = false;
      _errorMessage = '';
      _progress = 0;
    });
    await _controller.setUserAgent(_webViewUserAgentForStream(clean));
    await _controller.loadRequest(Uri.parse(clean), headers: {
      HttpHeaders.userAgentHeader: _webViewUserAgentForStream(clean),
      HttpHeaders.acceptLanguageHeader: 'en-US,en;q=0.9,ar;q=0.8',
    });
    _startAntiBlackTimer();
    _finishLoadingSoon(seconds: 3);
  }

  Future<void> _loadHtml(String html) async {
    if (mounted) setState(() {
      _isLoading = true;
      _hasError = false;
      _errorMessage = '';
      _progress = 0;
    });
    await _controller.setUserAgent(_webViewUserAgentForStream(_originalUrl));
    await _controller.loadHtmlString(html, baseUrl: 'https://localhost');
    _startAntiBlackTimer();
    _finishLoadingSoon(seconds: 2);
  }

  // HTML خاص بـ YouTube فقط
  String? _youtubeEmbedHtml(String url) {
    try {
      final uri = Uri.parse(_cleanStreamUrl(url));
      final host = uri.host.toLowerCase();
      String? videoId;
      if (host.contains('youtube.com')) {
        videoId = uri.queryParameters['v'];
      } else if (host.contains('youtu.be')) {
        videoId = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
      }
      if (videoId == null || videoId.trim().isEmpty) return null;
      final safeSrc = 'https://www.youtube.com/embed/$videoId?autoplay=1&playsinline=1&rel=0&modestbranding=1';
      return '''
<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
*{box-sizing:border-box;margin:0;padding:0;}
html,body{width:100%;height:100%;background:#000;overflow:hidden;position:fixed;inset:0;}
iframe{position:absolute;inset:0;width:100%;height:100%;border:0;background:#000;display:block;}
</style></head><body>
<iframe src="${const HtmlEscape().convert(safeSrc)}" allow="autoplay; fullscreen; picture-in-picture; encrypted-media" allowfullscreen></iframe>
</body></html>
''';
    } catch (_) { return null; }
  }

  void _openExternal() async {
    final url = _cleanStreamUrl(_originalUrl);
    if (url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _currentMode == 'direct' ? 'صفحة البث' : (_currentMode == 'mobile' ? 'صفحة الموبايل' : 'المشغل الذكي'),
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
        ),
        actions: [
          IconButton(
            tooltip: 'الصفحة المباشرة',
            icon: const Icon(Icons.language),
            onPressed: _loadChannelPage,
          ),
          IconButton(
            tooltip: 'المشغل الذكي',
            icon: const Icon(Icons.smart_display_rounded),
            onPressed: _loadSmartPlayer,
          ),
          IconButton(
            tooltip: 'صفحة الموبايل',
            icon: const Icon(Icons.phone_android_rounded),
            onPressed: _loadMobilePage,
          ),
          IconButton(
            tooltip: 'فتح في المتصفح',
            icon: const Icon(Icons.open_in_browser_rounded),
            onPressed: _openExternal,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(children: [
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black,
              child: _buildPlatformWebView(),
            ),
          ),
          if (_isLoading)
            const PositionedDirectional(
              top: 0,
              start: 0,
              end: 0,
              child: LinearProgressIndicator(
                color: AppColors.purple,
                backgroundColor: Colors.black26,
                minHeight: 3,
              ),
            ),
          if (_hasError)
            Container(
              color: Colors.black.withValues(alpha: 0.86),
              padding: const EdgeInsets.all(18),
              child: Center(
                child: GlassCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: AppColors.purple, size: 44),
                      const SizedBox(height: 12),
                      const Text('تعذر تشغيل البث داخل التطبيق',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage.trim().isEmpty
                            ? 'جرّب أحد الأزرار في الأعلى (الصفحة المباشرة أو الموبايل)'
                            : _errorMessage,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: isDark ? AppColors.darkMuted : AppColors.lightMuted, height: 1.4),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _loadChannelPage,
                              icon: const Icon(Icons.refresh),
                              label: const Text('إعادة المحاولة'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _openExternal,
                              icon: const Icon(Icons.open_in_browser_rounded),
                              label: const Text('متصفح'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}