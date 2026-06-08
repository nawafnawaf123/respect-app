// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, use_build_context_synchronously, unnecessary_this, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures, prefer_final_fields, unnecessary_type_check, unnecessary_non_null_assertion
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_service.dart';

class CallScreen extends StatefulWidget {
  final String callId;
  final String peerName;
  final String? peerAvatarPath;
  final bool video;
  final bool isCaller;
  final CallService callService;
  final String? callerName;
  final String? callerUsername;
  final String? calleeUsername;

  const CallScreen({
    super.key,
    required this.callId,
    required this.peerName,
    this.peerAvatarPath,
    required this.video,
    this.isCaller = true,
    required this.callService,
    this.callerName,
    this.callerUsername,
    this.calleeUsername,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final CallService _callService;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool _muted = false;
  bool _speaker = true;
  bool _ending = false;
  bool _booted = false;
  bool _localVideoEnabled = false;
  bool _remoteVideoAvailable = false;
  bool _changingVideo = false;
  bool _remoteAudioMuted = false;
  bool _screenSharing = false;
  bool _changingScreenShare = false;

  String _callStatus = 'جاري الاتصال...';
  Timer? _timer;
  int _seconds = 0;

  Offset _pipOffset = const Offset(16, 60);
  static const double _pipWidth = 120;
  static const double _pipHeight = 180;

  @override
  void initState() {
    super.initState();
    _callService = widget.callService;
    _localVideoEnabled = widget.video;
    _bootCall();
  }

  Future<void> _bootCall() async {
    if (_booted) return;
    _booted = true;

    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (!mounted) return;

    _callService.onLocalStream = (stream) {
      _localRenderer.srcObject = stream;
      _localVideoEnabled = stream.getVideoTracks().any((t) => t.enabled);
      if (mounted) setState(() {});
    };

    _callService.onLocalVideoChanged = (enabled) {
      if (!mounted) return;
      setState(() => _localVideoEnabled = enabled);
    };

    _callService.onMicrophoneMuteChanged = (muted) {
      if (!mounted) return;
      setState(() => _muted = muted);
    };

    _callService.onScreenShareChanged = (enabled) {
      if (!mounted) return;
      setState(() => _screenSharing = enabled);
    };

    _callService.onRemoteStream = (stream) {
      _remoteRenderer.srcObject = stream;
      _remoteVideoAvailable = _hasEnabledVideo(stream);
      if (!mounted) return;
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds++);
      });
      setState(() => _callStatus = 'متصل');
    };

    _callService.onError = (error) {
      if (!mounted || _ending) return;
      setState(() => _callStatus = 'فشل الاتصال');
      _showError(error);
    };

    _callService.onCallEnded = () {
      if (!mounted || _ending) return;
      _ending = true;
      Future<void>.microtask(() {
        if (!mounted) return;
        final navigator = Navigator.of(context);
        if (navigator.canPop()) navigator.pop();
      });
    };

    await _startCall();
  }

  bool _hasEnabledVideo(MediaStream? stream) {
    if (stream == null) return false;
    return stream.getVideoTracks().isNotEmpty;
  }

  Future<void> _startCall() async {
    try {
      if (widget.isCaller) {
        await _callService.startCall(widget.callId, widget.video);
      } else {
        await _callService.acceptCall(widget.callId, widget.video);
      }
    } catch (e) {
      if (!mounted || _ending) return;
      setState(() => _callStatus = 'فشل الاتصال');
      _showError('تعذر بدء المكالمة: $e');
    }
  }

  void _toggleMute() {
    final muted = _callService.toggleMute();
    if (mounted) setState(() => _muted = muted);
  }

  void _toggleRemoteAudioMute() {
    final next = !_remoteAudioMuted;
    _callService.setRemoteAudioMuted(next);
    if (mounted) setState(() => _remoteAudioMuted = next);
  }

  void _toggleSpeaker() {
    final next = !_speaker;
    _callService.toggleSpeaker(next);
    if (mounted) setState(() => _speaker = next);
  }

  void _switchCamera() {
    _callService.switchCamera();
  }

  Future<void> _toggleScreenShare() async {
    if (_changingScreenShare) return;
    setState(() => _changingScreenShare = true);

    final ok = await _callService.toggleScreenShare();

    if (!mounted) return;
    setState(() {
      if (ok) _screenSharing = _callService.screenSharing;
      _changingScreenShare = false;
    });
  }

  Future<void> _toggleVideo() async {
    if (_changingVideo) return;
    setState(() => _changingVideo = true);

    final next = !_localVideoEnabled;
    final ok = await _callService.setVideoEnabled(next);

    if (!mounted) return;
    setState(() {
      if (ok) _localVideoEnabled = next;
      _changingVideo = false;
    });
  }

  Future<void> _endCall() async {
    if (_ending) return;
    _ending = true;
    await _callService.endCall();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  void _showError(String error) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('خطأ في المكالمة'),
        content: Text(error),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  String _formatTime() {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  ImageProvider? _peerAvatarImage() {
    final path = widget.peerAvatarPath;
    if (path == null || path.trim().isEmpty) return null;
    if (path.startsWith('http')) return NetworkImage(path);
    final file = File(path);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  Widget _buildAudioFallback(ImageProvider? avatar) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF12001F), Color(0xFF050008), Colors.black],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF8B5CF6), width: 2),
                boxShadow: const [
                  BoxShadow(color: Color(0x668B5CF6), blurRadius: 28, spreadRadius: 4),
                ],
              ),
              child: CircleAvatar(
                radius: 66,
                backgroundColor: Colors.grey[900],
                backgroundImage: avatar,
                child: avatar == null ? const Icon(Icons.person, size: 72, color: Colors.white) : null,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              widget.peerName,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(_callStatus, style: const TextStyle(color: Colors.white70, fontSize: 16)),
            if (_seconds > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_formatTime(), style: const TextStyle(color: Colors.white60, fontSize: 16)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Positioned(
      top: 30,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.48),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.peerName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 3),
              Text(_seconds > 0 ? _formatTime() : _callStatus, style: const TextStyle(color: Colors.white70)),
              if (_screenSharing)
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Text('مشاركة الشاشة تعمل الآن', style: TextStyle(color: Color(0xFFBFA7FF), fontSize: 11, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDraggablePip(BoxConstraints constraints) {
    final maxX = constraints.maxWidth - _pipWidth - 8;
    final maxY = constraints.maxHeight - _pipHeight - 110;
    final safeOffset = Offset(
      _pipOffset.dx.clamp(8.0, maxX < 8 ? 8 : maxX),
      _pipOffset.dy.clamp(8.0, maxY < 8 ? 8 : maxY),
    );

    return Positioned(
      left: safeOffset.dx,
      top: safeOffset.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _pipOffset = Offset(
              (_pipOffset.dx + details.delta.dx).clamp(8.0, maxX < 8 ? 8 : maxX),
              (_pipOffset.dy + details.delta.dy).clamp(8.0, maxY < 8 ? 8 : maxY),
            );
          });
        },
        child: Container(
          width: _pipWidth,
          height: _pipHeight,
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF8B5CF6), width: 2),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 8))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: _localVideoEnabled && _localRenderer.srcObject != null
                ? RTCVideoView(
              _localRenderer,
              mirror: true,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
                : Container(
              color: Colors.black,
              child: const Center(
                child: Icon(Icons.videocam_off, color: Colors.white70, size: 32),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final avatar = _peerAvatarImage();
    final showRemoteVideo = _remoteVideoAvailable && _remoteRenderer.srcObject != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                Positioned.fill(
                  child: showRemoteVideo
                      ? RTCVideoView(
                    _remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                      : _buildAudioFallback(avatar),
                ),

                if (showRemoteVideo)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.35),
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.55),
                          ],
                        ),
                      ),
                    ),
                  ),

                _buildHeader(),

                if (_localVideoEnabled || _localRenderer.srcObject != null) _buildDraggablePip(constraints),

                Positioned(
                  bottom: 32,
                  left: 0,
                  right: 0,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _CallButton(
                          icon: _muted ? Icons.mic_off : Icons.mic,
                          active: !_muted,
                          onTap: _toggleMute,
                          label: _muted ? 'مكتوم' : 'مايك',
                        ),
                        const SizedBox(width: 12),
                        _CallButton(
                          icon: _speaker ? Icons.volume_up : Icons.volume_off,
                          active: _speaker,
                          onTap: _toggleSpeaker,
                          label: 'مكبر',
                        ),
                        const SizedBox(width: 12),
                        _CallButton(
                          icon: _remoteAudioMuted ? Icons.volume_off_rounded : Icons.record_voice_over_rounded,
                          active: !_remoteAudioMuted,
                          onTap: _toggleRemoteAudioMute,
                          label: _remoteAudioMuted ? 'كتمه' : 'صوت الطرف',
                        ),
                        const SizedBox(width: 12),
                        _CallButton(
                          icon: _screenSharing ? Icons.stop_screen_share_rounded : Icons.screen_share_rounded,
                          active: _screenSharing,
                          onTap: _toggleScreenShare,
                          label: _changingScreenShare ? '...' : (_screenSharing ? 'إيقاف مشاركة' : 'مشاركة الشاشة'),
                        ),
                        const SizedBox(width: 12),
                        _CallButton(
                          icon: _localVideoEnabled ? Icons.videocam : Icons.videocam_off,
                          active: _localVideoEnabled,
                          onTap: _toggleVideo,
                          label: _changingVideo ? '...' : (_localVideoEnabled ? 'فيديو' : 'فتح فيديو'),
                        ),
                        const SizedBox(width: 12),
                        _CallButton(
                          icon: Icons.cameraswitch,
                          active: _localVideoEnabled,
                          onTap: _localVideoEnabled ? _switchCamera : () {},
                          label: 'قلب',
                        ),
                        const SizedBox(width: 12),
                        _CallButton(
                          icon: Icons.call_end,
                          active: false,
                          onTap: _endCall,
                          label: 'إنهاء',
                          color: Colors.red,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final String label;
  final Color? color;

  const _CallButton({
    required this.icon,
    required this.active,
    required this.onTap,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (active ? Colors.white : const Color(0xFF24212A));
    final fg = color == null ? (active ? Colors.black : Colors.white) : Colors.white;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(50),
          child: Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(color: active ? Colors.white : Colors.white12),
              boxShadow: [
                if (active && color == null)
                  const BoxShadow(color: Color(0x558B5CF6), blurRadius: 18, spreadRadius: 1),
              ],
            ),
            child: Icon(icon, color: fg),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
