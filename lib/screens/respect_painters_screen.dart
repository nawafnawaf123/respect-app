// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_local_variable, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, prefer_const_literals_to_create_immutables, curly_braces_in_flow_control_structures, sized_box_for_whitespace, dead_code, unnecessary_type_check, unnecessary_non_null_assertion, use_build_context_synchronously, unnecessary_brace_in_string_interps, prefer_final_fields
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/notification_service.dart';
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';

class RespectPaintersScreen extends StatefulWidget {
  const RespectPaintersScreen({super.key});

  @override
  State<RespectPaintersScreen> createState() => _RespectPaintersScreenState();
}

class _RespectPaintersScreenState extends State<RespectPaintersScreen> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  Timer? _refreshTimer;

  bool _loading = true;
  bool _submitting = false;
  bool _runningTournament = false;
  bool _isAdmin = false;
  File? _selectedImage;
  String _weekKey = SupabaseService.currentArtWeekKey();
  String _statusText = 'جاري التحميل...';

  Map<String, dynamic>? _currentUser;
  List<Map<String, dynamic>> _drawings = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _matches = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _topThree = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _loadAll(showLoader: true);
    _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) => _loadAll(showLoader: false));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  String _displayUsername(dynamic value) => SupabaseService.displayUsername((value ?? '').toString());

  bool _hasSubmittedThisWeek([Map<String, dynamic>? user]) {
    final u = user ?? _currentUser;
    if (u == null) return false;
    final me = _displayUsername(u['username']);
    if (me == '@user' || me.trim().isEmpty) return false;

    return _drawings.any((drawing) {
      final drawingUser = _displayUsername(drawing['username']);
      final status = (drawing['status'] ?? '').toString().toLowerCase().trim();
      return drawingUser == me && status != 'rejected' && status != 'deleted';
    });
  }

  Map<String, dynamic>? _myDrawingThisWeek([Map<String, dynamic>? user]) {
    final u = user ?? _currentUser;
    if (u == null) return null;
    final me = _displayUsername(u['username']);
    for (final drawing in _drawings) {
      final drawingUser = _displayUsername(drawing['username']);
      final status = (drawing['status'] ?? '').toString().toLowerCase().trim();
      if (drawingUser == me && status != 'rejected' && status != 'deleted') return drawing;
    }
    return null;
  }

  void _showAlreadySubmittedMessage([Map<String, dynamic>? user]) {
    final drawing = _myDrawingThisWeek(user);
    final title = (drawing == null ? '' : (drawing['title'] ?? '').toString()).trim();
    final extra = title.isEmpty ? '' : ' رسمتك الحالية: $title';
    NotificationService.showTopNotification('لا يمكنك نشر أكثر من رسمة واحدة في نفس الأسبوع.$extra');
  }

  bool _truthy(dynamic value) {
    if (value == true) return true;
    final v = (value ?? '').toString().trim().toLowerCase();
    return v == 'true' || v == '1' || v == 'admin' || v == 'owner' || v == 'super_admin';
  }

  Future<void> _loadAll({required bool showLoader}) async {
    if (showLoader && mounted) setState(() => _loading = true);
    try {
      final user = await SupabaseService.currentUser();
      final drawings = await SupabaseService.getArtDrawings(weekKey: _weekKey);
      final matches = await SupabaseService.getArtTournamentMatches(weekKey: _weekKey);
      final top = await SupabaseService.getArtTopThree(weekKey: _weekKey);

      final username = _displayUsername(user == null ? '' : user['username']);
      final role = (user == null ? '' : (user['role'] ?? user['user_role'] ?? '')).toString().toLowerCase();
      final isAdmin = username == '@nawafrp' || role == 'admin' || role == 'owner' || _truthy(user == null ? false : user['is_admin']);

      if (!mounted) return;
      setState(() {
        _currentUser = user;
        _drawings = drawings;
        _matches = matches;
        _topThree = top;
        _isAdmin = isAdmin;
        _statusText = _buildStatusText();
      });
    } catch (e) {
      if (mounted) NotificationService.showTopNotification('تعذر تحميل رسامين ريسبكت: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _buildStatusText() {
    if (_matches.any((m) => (m['status'] ?? '').toString() == 'analyzing')) {
      return 'الذكاء الاصطناعي يحلل المواجهات الآن...';
    }
    if (_topThree.isNotEmpty) return 'تم اختيار الفائزين لهذا الأسبوع';
    if (_drawings.isEmpty) return 'ارفع أول رسمة وادخل البطولة الأسبوعية';
    return 'البطولة مفتوحة لاستقبال الرسمات هذا الأسبوع';
  }

  Future<void> _pickImage() async {
    if (_hasSubmittedThisWeek()) {
      _showAlreadySubmittedMessage();
      return;
    }

    final image = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 92);
    if (image == null) return;
    setState(() => _selectedImage = File(image.path));
  }

  void _openDrawingViewer(Map<String, dynamic> drawing) {
    final image = (drawing['image_url'] ?? '').toString().trim();
    if (image.isEmpty) return;

    final title = (drawing['title'] ?? 'رسمة').toString();
    final name = (drawing['name'] ?? drawing['username'] ?? '').toString();
    final rank = int.tryParse((drawing['rank'] ?? 0).toString()) ?? 0;

    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (context) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Dialog.fullscreen(
            backgroundColor: Colors.black,
            child: SafeArea(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: InteractiveViewer(
                      minScale: 0.75,
                      maxScale: 5,
                      child: Center(
                        child: Image.network(
                          image,
                          fit: BoxFit.contain,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const Center(child: CircularProgressIndicator());
                          },
                          errorBuilder: (context, error, stackTrace) {
                            return const Center(
                              child: Icon(Icons.broken_image_rounded, color: Colors.white54, size: 60),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    left: 12,
                    child: Row(
                      children: [
                        IconButton.filled(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                          style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.14), foregroundColor: Colors.white),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  rank > 0 ? '$title  •  المركز $rank' : title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15),
                                ),
                                if (name.trim().isNotEmpty)
                                  Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                                  ),
                              ],
                            ),
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
      },
    );
  }

  Future<void> _submitDrawing() async {
    final user = _currentUser ?? await SupabaseService.currentUser();
    if (user == null) {
      NotificationService.showTopNotification('سجل دخولك أولاً');
      return;
    }
    if (_hasSubmittedThisWeek(user)) {
      _showAlreadySubmittedMessage(user);
      return;
    }
    if (_selectedImage == null) {
      NotificationService.showTopNotification('اختر صورة الرسمة أولاً');
      return;
    }
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      NotificationService.showTopNotification('اكتب عنوان للرسمة');
      return;
    }

    setState(() {
      _submitting = true;
      _statusText = 'رفع الصورة وفحصها بالذكاء الاصطناعي...';
    });

    try {
      final username = _displayUsername(user['username']);
      final name = (user['name'] ?? user['profileName'] ?? username).toString();
      final avatar = (user['avatar_url'] ?? user['imagePath'] ?? user['profileImagePath'] ?? '').toString();

      final result = await SupabaseService.submitArtDrawing(
        username: username,
        name: name,
        avatarUrl: avatar,
        title: title,
        description: _descriptionController.text.trim(),
        imagePath: _selectedImage!.path,
        weekKey: _weekKey,
      );

      final accepted = result['accepted'] == true;
      if (accepted) {
        NotificationService.showTopSuccess('تم نشر الرسمة داخل بطولة رسامين ريسبكت');
        _titleController.clear();
        _descriptionController.clear();
        setState(() => _selectedImage = null);
      } else {
        NotificationService.showTopNotification((result['reason'] ?? 'لم يتم قبول الصورة كرسمة حقيقية').toString());
      }
      await _loadAll(showLoader: false);
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('23505') ||
          msg.contains('duplicate') ||
          msg.contains('unique') ||
          msg.contains('already') ||
          msg.contains('أكثر من رسمة') ||
          msg.contains('رسمة واحدة')) {
        _showAlreadySubmittedMessage(user);
      } else {
        NotificationService.showTopNotification('فشل نشر الرسمة: $e');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _runTournament() async {
    setState(() {
      _runningTournament = true;
      _statusText = 'بدء تصفيات رسامين ريسبكت...';
    });
    try {
      final result = await SupabaseService.runArtWeeklyTournament(weekKey: _weekKey);
      final ok = result['ok'] == true;
      NotificationService.showTopNotification(ok ? 'انتهت التصفيات وتم اختيار الفائز' : (result['reason'] ?? 'تعذر تشغيل التصفيات').toString());
      await _loadAll(showLoader: false);
    } catch (e) {
      NotificationService.showTopNotification('فشل تشغيل التصفيات: $e');
    } finally {
      if (mounted) setState(() => _runningTournament = false);
    }
  }

  Future<void> _changeWeek(int delta) async {
    final parts = _weekKey.split('-W');
    final year = int.tryParse(parts.first) ?? DateTime.now().year;
    final week = int.tryParse(parts.length > 1 ? parts[1] : '') ?? SupabaseService.isoWeekNumber(DateTime.now());
    final date = SupabaseService.dateFromIsoWeek(year, week).add(Duration(days: delta * 7));
    setState(() => _weekKey = SupabaseService.artWeekKeyFor(date));
    await _loadAll(showLoader: true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
          onRefresh: () => _loadAll(showLoader: false),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 105),
            children: [
              _buildHero(isDark),
              const SizedBox(height: 14),
              _buildWinnerPodium(isDark),
              const SizedBox(height: 14),
              _buildComposer(isDark),
              const SizedBox(height: 14),
              _buildLiveMatches(isDark),
              const SizedBox(height: 14),
              _buildDrawingsGrid(isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHero(bool isDark) {
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [AppColors.purple, Color(0xFFEC4899)]),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.palette_rounded, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('رسامين ريسبكت', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
                    Text(_statusText, style: TextStyle(fontSize: 13, color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _StatPill(title: 'الأسبوع', value: _weekKey, icon: Icons.calendar_month_rounded),
              const SizedBox(width: 8),
              _StatPill(title: 'الرسمات', value: '${_drawings.length}', icon: Icons.image_rounded),
              const SizedBox(width: 8),
              _StatPill(title: 'المواجهات', value: '${_matches.length}', icon: Icons.sports_mma_rounded),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _changeWeek(-1),
                  icon: const Icon(Icons.chevron_right_rounded),
                  label: const Text('الأسبوع السابق'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _changeWeek(1),
                  icon: const Icon(Icons.chevron_left_rounded),
                  label: const Text('الأسبوع التالي'),
                ),
              ),
            ],
          ),
          if (_isAdmin) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: (_runningTournament || _drawings.length < 2) ? null : _runTournament,
                icon: _runningTournament
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome_rounded),
                label: Text(_runningTournament ? 'جاري تشغيل التصفيات...' : 'تشغيل تصفيات الأسبوع بالذكاء الاصطناعي'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWinnerPodium(bool isDark) {
    final first = _topThree.isNotEmpty ? _topThree[0] : null;
    final second = _topThree.length > 1 ? _topThree[1] : null;
    final third = _topThree.length > 2 ? _topThree[2] : null;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.emoji_events_rounded, color: Color(0xFFF59E0B)),
              const SizedBox(width: 8),
              Text('منصة الفائزين', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            // كان الارتفاع 210 وهذا يسبب RenderFlex overflow لأن الكرت يحتوي:
            // صورة + عنوان + اسم + المنصة نفسها. رفعنا الارتفاع وخففنا أحجام العناصر داخل _PodiumPlace.
            height: 286,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: _PodiumPlace(rank: 2, height: 116, drawing: second, color: const Color(0xFF94A3B8), onTap: second == null ? null : () => _openDrawingViewer(second))),
                const SizedBox(width: 8),
                Expanded(child: _PodiumPlace(rank: 1, height: 148, drawing: first, color: const Color(0xFFF59E0B), onTap: first == null ? null : () => _openDrawingViewer(first))),
                const SizedBox(width: 8),
                Expanded(child: _PodiumPlace(rank: 3, height: 98, drawing: third, color: const Color(0xFFFB923C), onTap: third == null ? null : () => _openDrawingViewer(third))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(bool isDark) {
    final hasSubmitted = _hasSubmittedThisWeek();

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('انشر رسمتك', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
          const SizedBox(height: 10),
          if (hasSubmitted) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.purple.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.purpleLight.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_rounded, color: AppColors.purpleLight),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'مسموح لكل حساب بنشر رسمة واحدة فقط في الأسبوع. تقدر تشارك من جديد الأسبوع القادم.',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: isDark ? Colors.white : Colors.black87),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          InkWell(
            onTap: _submitting ? null : () {
              if (hasSubmitted) {
                _showAlreadySubmittedMessage();
                return;
              }
              _pickImage();
            },
            borderRadius: BorderRadius.circular(22),
            child: Container(
              height: 210,
              width: double.infinity,
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AppColors.purple.withValues(alpha: 0.28)),
              ),
              clipBehavior: Clip.antiAlias,
              child: _selectedImage == null
                  ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_photo_alternate_rounded, size: 46, color: AppColors.purple.withValues(alpha: 0.9)),
                  const SizedBox(height: 8),
                  Text('اختر صورة الرسمة', style: TextStyle(fontWeight: FontWeight.w800, color: isDark ? Colors.white : Colors.black87)),
                  const SizedBox(height: 4),
                  Text('سيتم فحصها للتأكد أنها رسمة وليست تصميم AI', style: TextStyle(fontSize: 12, color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                ],
              )
                  : Image.file(_selectedImage!, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _titleController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.title_rounded), hintText: 'عنوان الرسمة'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _descriptionController,
            maxLines: 3,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.notes_rounded), hintText: 'وصف اختياري للرسمه'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 52,
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (_submitting || hasSubmitted) ? null : _submitDrawing,
              icon: _submitting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload_rounded),
              label: Text(hasSubmitted ? 'تمت المشاركة هذا الأسبوع' : (_submitting ? 'جاري الرفع والفحص...' : 'نشر الرسمة في البطولة')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveMatches(bool isDark) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.psychology_rounded, color: AppColors.purpleLight),
              const SizedBox(width: 8),
              Text('تحليل المواجهات مباشر', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
            ],
          ),
          const SizedBox(height: 12),
          if (_matches.isEmpty)
            Text('عند نهاية الأسبوع أو تشغيل الأدمن للتصفيات ستظهر هنا المقارنات: صورة ضد صورة، مميزات، عيوب، ثم الفائز.', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted))
          else
            ..._matches.take(20).map((m) => _MatchCard(match: m)),
        ],
      ),
    );
  }

  Widget _buildDrawingsGrid(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text('رسمات الأسبوع', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
        ),
        if (_drawings.isEmpty)
          GlassCard(child: Center(child: Padding(padding: const EdgeInsets.all(18), child: Text('لا توجد رسمات بعد', style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted)))))
        else
          GridView.builder(
            itemCount: _drawings.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.72,
            ),
            itemBuilder: (context, i) => _DrawingCard(
              drawing: _drawings[i],
              onTap: () => _openDrawingViewer(_drawings[i]),
            ),
          ),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;

  const _StatPill({required this.title, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: AppColors.purpleLight),
            const SizedBox(height: 4),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87, fontSize: 12)),
            Text(title, style: TextStyle(fontSize: 10, color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
          ],
        ),
      ),
    );
  }
}

class _PodiumPlace extends StatelessWidget {
  final int rank;
  final double height;
  final Map<String, dynamic>? drawing;
  final Color color;
  final VoidCallback? onTap;

  const _PodiumPlace({required this.rank, required this.height, required this.drawing, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final image = (drawing == null ? '' : (drawing!['image_url'] ?? '')).toString();
    final title = (drawing == null ? 'بانتظار الفائز' : (drawing!['title'] ?? 'رسمة').toString());
    final name = (drawing == null ? '' : (drawing!['name'] ?? drawing!['username'] ?? '').toString());

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxH = constraints.maxHeight.isFinite ? constraints.maxHeight : 286.0;

        // أحجام مرنة حتى لا يحصل overflow على الشاشات الصغيرة.
        final imageSize = maxH < 260 ? 54.0 : 62.0;
        const titleHeight = 17.0;
        const nameHeight = 15.0;
        const gap1 = 6.0;
        const gap2 = 3.0;
        const gap3 = 6.0;

        final usedWithoutPodium = imageSize + titleHeight + nameHeight + gap1 + gap2 + gap3;
        final availableForPodium = maxH - usedWithoutPodium;
        final podiumHeight = availableForPodium <= 64
            ? 64.0
            : availableForPodium < height
            ? availableForPodium
            : height;

        return Column(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.max,
          children: [
            GestureDetector(
              onTap: image.isEmpty ? null : onTap,
              child: Container(
                width: imageSize,
                height: imageSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
                  border: Border.all(color: color, width: 2.6),
                  image: image.isEmpty ? null : DecorationImage(image: NetworkImage(image), fit: BoxFit.cover),
                ),
                child: image.isEmpty ? Icon(Icons.brush_rounded, color: color, size: imageSize * 0.46) : null,
              ),
            ),
            const SizedBox(height: gap1),
            SizedBox(
              height: titleHeight,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87),
              ),
            ),
            const SizedBox(height: gap2),
            SizedBox(
              height: nameHeight,
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9.5, color: isDark ? AppColors.darkMuted : AppColors.lightMuted),
              ),
            ),
            const SizedBox(height: gap3),
            Container(
              height: podiumHeight,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withValues(alpha: 0.95), color.withValues(alpha: 0.45)]),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Text('$rank', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.white)),
            ),
          ],
        );
      },
    );
  }
}

class _DrawingCard extends StatelessWidget {
  final Map<String, dynamic> drawing;
  final VoidCallback? onTap;

  const _DrawingCard({required this.drawing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final image = (drawing['image_url'] ?? '').toString();
    final title = (drawing['title'] ?? 'رسمة').toString();
    final name = (drawing['name'] ?? drawing['username'] ?? '').toString();
    final rank = int.tryParse((drawing['rank'] ?? 0).toString()) ?? 0;
    final status = (drawing['status'] ?? 'pending').toString();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard : AppColors.lightCard,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: rank > 0 ? AppColors.purpleLight.withValues(alpha: 0.8) : (isDark ? AppColors.darkBorder : AppColors.lightBorder)),
          boxShadow: [BoxShadow(color: AppColors.purple.withValues(alpha: isDark ? 0.14 : 0.08), blurRadius: 22, offset: const Offset(0, 8))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  image.isEmpty
                      ? const Center(child: Icon(Icons.image_rounded))
                      : Image.network(image, fit: BoxFit.cover),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.48), borderRadius: BorderRadius.circular(20)),
                      child: Text(rank > 0 ? 'المركز $rank' : status, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900)),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
                  const SizedBox(height: 2),
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: isDark ? AppColors.darkMuted : AppColors.lightMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MatchCard extends StatelessWidget {
  final Map<String, dynamic> match;

  const _MatchCard({required this.match});

  String _s(String key) => (match[key] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = _s('status');
    final analyzing = status == 'analyzing';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard2 : AppColors.lightCard2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: analyzing ? AppColors.purpleLight : (isDark ? AppColors.darkBorder : AppColors.lightBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(analyzing ? Icons.autorenew_rounded : Icons.check_circle_rounded, color: analyzing ? AppColors.purpleLight : AppColors.success),
              const SizedBox(width: 8),
              Expanded(child: Text('الجولة ${_s('round_number')} — ${_s('drawing_a_title')} ضد ${_s('drawing_b_title')}', style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87))),
            ],
          ),
          const SizedBox(height: 10),
          if (analyzing) const LinearProgressIndicator(),
          if (_s('analysis_summary').isNotEmpty) ...[
            Text(_s('analysis_summary'), style: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.lightMuted, height: 1.45)),
            const SizedBox(height: 8),
          ],
          if (_s('drawing_a_pros').isNotEmpty) _AnalysisLine(title: 'مميزات الأولى', text: _s('drawing_a_pros')),
          if (_s('drawing_a_cons').isNotEmpty) _AnalysisLine(title: 'عيوب الأولى', text: _s('drawing_a_cons')),
          if (_s('drawing_b_pros').isNotEmpty) _AnalysisLine(title: 'مميزات الثانية', text: _s('drawing_b_pros')),
          if (_s('drawing_b_cons').isNotEmpty) _AnalysisLine(title: 'عيوب الثانية', text: _s('drawing_b_cons')),
          if (_s('winner_title').isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: AppColors.success.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
              child: Row(
                children: [
                  const Icon(Icons.emoji_events_rounded, color: AppColors.success, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text('الفائز: ${_s('winner_title')}', style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.success))),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AnalysisLine extends StatelessWidget {
  final String title;
  final String text;

  const _AnalysisLine({required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          style: TextStyle(fontFamily: 'Cairo', color: isDark ? AppColors.darkMuted : AppColors.lightMuted, height: 1.4),
          children: [
            TextSpan(text: '$title: ', style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontWeight: FontWeight.w900)),
            TextSpan(text: text),
          ],
        ),
      ),
    );
  }
}
