import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';

class SavedPostsScreen extends StatefulWidget {
  const SavedPostsScreen({super.key});

  @override
  State<SavedPostsScreen> createState() => _SavedPostsScreenState();
}

class _SavedPostsScreenState extends State<SavedPostsScreen> {
  static const String _savedPostsKey = 'respect_saved_posts_v1';
  bool _loading = true;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _loadSavedPosts();
  }

  Future<void> _loadSavedPosts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_savedPostsKey);
    final loaded = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          loaded.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (_) {}
    }
    loaded.sort((a, b) => (b['savedAt'] ?? '').toString().compareTo((a['savedAt'] ?? '').toString()));
    if (!mounted) return;
    setState(() {
      _items = loaded;
      _loading = false;
    });
  }

  Future<void> _removeSavedPost(String postId) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _items.removeWhere((e) => (e['id'] ?? '').toString() == postId));
    await prefs.setString(_savedPostsKey, jsonEncode(_items));
    if (!mounted) return;
    NotificationService.showTopNotification('تمت إزالة التغريدة من المحفوظات');
  }

  ImageProvider? _imageProvider(String? path) {
    final value = path?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) return NetworkImage(value);
    final file = File(value);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  String _displayUsername(String value) {
    final clean = value.trim().replaceAll('@', '').replaceAll(RegExp(r'\s+'), '_').toLowerCase();
    return clean.isEmpty ? '@user' : '@$clean';
  }

  String _savedDate(String raw) {
    final date = DateTime.tryParse(raw);
    if (date == null) return '';
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: null,
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.purple))
            : RefreshIndicator(
          color: AppColors.purple,
          onRefresh: _loadSavedPosts,
          child: _items.isEmpty
              ? ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 120),
              Icon(Icons.bookmarks_rounded, size: 80, color: AppColors.purple.withOpacity(.85)),
              const SizedBox(height: 16),
              const Center(
                child: Text('لا توجد تغريدات محفوظة بعد', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              ),
              const SizedBox(height: 8),
              Text(
                'اضغط زر الحفظ على أي تغريدة وستظهر هنا مباشرة.',
                textAlign: TextAlign.center,
                style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700),
              ),
            ],
          )
              : ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 100),
            itemCount: _items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final post = _items[index];
              return _SavedPostCard(
                post: post,
                isDark: isDark,
                avatarProvider: _imageProvider((post['avatar_url'] ?? post['avatarPath'])?.toString()),
                mediaProvider: _imageProvider((post['image_url'] ?? post['mediaPath'])?.toString()),
                username: _displayUsername((post['username'] ?? '').toString()),
                savedAt: _savedDate((post['savedAt'] ?? '').toString()),
                onRemove: () => _removeSavedPost((post['id'] ?? '').toString()),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SavedPostCard extends StatelessWidget {
  final Map<String, dynamic> post;
  final bool isDark;
  final ImageProvider? avatarProvider;
  final ImageProvider? mediaProvider;
  final String username;
  final String savedAt;
  final VoidCallback onRemove;

  const _SavedPostCard({
    required this.post,
    required this.isDark,
    required this.avatarProvider,
    required this.mediaProvider,
    required this.username,
    required this.savedAt,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final name = (post['name'] ?? post['user'] ?? 'User').toString();
    final text = (post['text'] ?? '').toString();
    final video = (post['video_url'] ?? '').toString().trim();
    final mediaPath = (post['mediaPath'] ?? '').toString().trim();
    final hasVideo = video.isNotEmpty || (post['mediaType']?.toString() == 'video');

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 23,
                backgroundColor: AppColors.purple,
                backgroundImage: avatarProvider,
                child: avatarProvider == null
                    ? Text(name.isNotEmpty ? name.characters.first.toUpperCase() : '?', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900))
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(
                      savedAt.isEmpty ? username : '$username · محفوظة $savedAt',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'إزالة من المحفوظات',
                onPressed: onRemove,
                icon: const Icon(Icons.bookmark_remove_rounded, color: AppColors.purple),
              ),
            ],
          ),
          if (text.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(text, style: const TextStyle(fontSize: 15, height: 1.45, fontWeight: FontWeight.w700)),
          ],
          if (mediaProvider != null || hasVideo || mediaPath.isNotEmpty) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Container(
                height: 180,
                width: double.infinity,
                color: AppColors.purple.withOpacity(.14),
                child: mediaProvider != null
                    ? Image(image: mediaProvider!, fit: BoxFit.cover)
                    : Center(
                  child: Icon(hasVideo ? Icons.play_circle_fill_rounded : Icons.image_rounded, color: AppColors.purple, size: 54),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              _MiniStat(icon: Icons.favorite_rounded, value: (post['likes'] ?? 0).toString()),
              const SizedBox(width: 12),
              _MiniStat(icon: Icons.repeat_rounded, value: (post['reposts'] ?? 0).toString()),
              const SizedBox(width: 12),
              _MiniStat(icon: Icons.chat_bubble_outline_rounded, value: ((post['replies'] is List) ? (post['replies'] as List).length : 0).toString()),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final String value;
  const _MiniStat({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: AppColors.purple, size: 17),
        const SizedBox(width: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
      ],
    );
  }
}
