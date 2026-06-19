// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import, unused_element_parameter, prefer_const_constructors, prefer_const_declarations, use_build_context_synchronously, unnecessary_this, unnecessary_brace_in_string_interps, curly_braces_in_flow_control_structures, prefer_final_fields, unnecessary_type_check, unnecessary_non_null_assertion
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/call_service.dart';

import '../widgets/app_dialog.dart';

import '../app/app_language.dart';
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
  bool _flashOn = false;
  bool _changingFlash = false;
  bool _answered = false;
  String _lastEndReason = 'missed';

  String _callStatus = 'جاري الاتصال...';
  String _callPhase = 'connecting';
  String _screenShareStatus = '';
  Timer? _timer;
  Timer? _remoteVideoWatchTimer;
  int _seconds = 0;

  Offset _pipOffset = const Offset(16, 60);
  static const double _pipWidth = 120;
  static const double _pipHeight = 180;

  final AudioPlayer _tonePlayer = AudioPlayer();
  Timer? _toneTimer;
  String? _connectingTonePath;
  String? _ringingTonePath;
  String _toneMode = 'silent';
  CameraController? _flashController;

  @override
  void initState() {
    super.initState();
    _callService = widget.callService;
    _speaker = widget.video;
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
      setState(() {
        _screenSharing = enabled;
        _screenShareStatus = enabled ? 'أنت تشارك الشاشة الآن' : '';
      });
    };

    _callService.onCallPhaseChanged = (phase) {
      if (!mounted) return;
      _handleCallPhase(phase);
    };

    _callService.onRemoteStream = (stream) {
      _remoteRenderer.srcObject = stream;
      _remoteVideoAvailable = _hasVideoTrack(stream);
      _answered = true;
      _lastEndReason = 'answered';
      _setToneMode('silent');
      _startRemoteVideoWatch();
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

    _callService.onCallEnded = (reason) {
      if (!mounted || _ending) return;
      _ending = true;
      _lastEndReason = reason;
      _setToneMode('silent');
      unawaited(_setFlashEnabled(false));
      Future<void>.microtask(() {
        if (!mounted) return;
        final navigator = Navigator.of(context);
        if (navigator.canPop()) navigator.pop(_callResult(reason));
      });
    };

    await _startCall();
  }

  bool _hasEnabledVideo(MediaStream? stream) {
    if (stream == null) return false;
    return stream.getVideoTracks().any((track) => track.enabled);
  }

  bool _hasVideoTrack(MediaStream? stream) {
    if (stream == null) return false;
    return stream.getVideoTracks().isNotEmpty;
  }

  void _startRemoteVideoWatch() {
    _remoteVideoWatchTimer?.cancel();
    _remoteVideoWatchTimer = Timer.periodic(const Duration(milliseconds: 700), (timer) {
      if (!mounted || _ending) {
        timer.cancel();
        return;
      }
      final stream = _remoteRenderer.srcObject;
      final hasVideo = _hasVideoTrack(stream);
      if (hasVideo != _remoteVideoAvailable) {
        setState(() => _remoteVideoAvailable = hasVideo);
      }
      if (hasVideo && _remoteRenderer.srcObject != null) {
        // لا نوقفه مباشرة؛ بعض الأجهزة تحتاج ثواني قليلة حتى يبدأ أول Frame.
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (mounted) _remoteVideoWatchTimer?.cancel();
        });
      }
    });
  }

  bool get _hasLocalVideoPreview {
    final stream = _localRenderer.srcObject;
    if (stream == null) return false;
    return stream.getVideoTracks().any((track) => track.enabled);
  }

  String _callResult(String reason) {
    final clean = reason.trim().isEmpty ? _lastEndReason : reason.trim();
    if (clean == 'rejected') return 'rejected';
    if (clean == 'missed') return _answered || _seconds > 0 ? 'answered' : 'missed';
    if (clean == 'cancelled') return _answered || _seconds > 0 ? 'answered' : 'cancelled';
    if (clean == 'disconnected') return _answered || _seconds > 0 ? 'answered' : 'missed';
    if (_answered || _seconds > 0 || clean == 'answered') return 'answered';
    return widget.isCaller ? 'cancelled' : 'missed';
  }

  Future<void> _startCall() async {
    try {
      if (widget.isCaller) {
        _setToneMode('connecting');
        await _callService.startCall(
          widget.callId,
          widget.video,
          callerUsername: widget.callerUsername,
          calleeUsername: widget.calleeUsername,
        );
      } else {
        _setToneMode('silent');
        if (mounted) setState(() => _callStatus = 'جاري تجهيز الصوت...');
        await _callService.acceptCall(
          widget.callId,
          widget.video,
          callerUsername: widget.callerUsername,
          calleeUsername: widget.calleeUsername,
        );
      }
      _callService.toggleSpeaker(_speaker);
    } catch (e) {
      if (!mounted || _ending) return;
      _setToneMode('silent');
      setState(() => _callStatus = 'فشل الاتصال');
      _showError('تعذر بدء المكالمة: $e');
    }
  }

  void _handleCallPhase(String phase) {
    _callPhase = phase;
    if (phase == 'connecting') {
      _callStatus = widget.isCaller ? 'جاري تجهيز المكالمة...' : 'جاري تجهيز الصوت...';
      if (widget.isCaller && !_answered) _setToneMode('connecting');
    } else if (phase == 'ringing') {
      _callStatus = 'يرن الآن...';
      if (widget.isCaller && !_answered) _setToneMode('ringing');
    } else if (phase == 'waiting_offer') {
      _callStatus = 'تم الرد، جاري توصيل المكالمة...';
      _setToneMode('silent');
    } else if (phase == 'answered_waiting_media') {
      _callStatus = 'تم الرد، جاري توصيل الصوت...';
      _setToneMode('silent');
    } else if (phase == 'reconnecting') {
      _callStatus = 'نعيد توصيل المكالمة...';
      _setToneMode('silent');
    } else if (phase == 'starting_video') {
      _callStatus = 'تم توصيل الصوت، جاري تشغيل الفيديو...';
      _setToneMode('silent');
    } else if (phase == 'connected') {
      _callStatus = 'متصل';
      _setToneMode('silent');
    } else if (phase == 'screen_share_on') {
      _screenShareStatus = 'أنت تشارك الشاشة الآن';
    } else if (phase == 'screen_share_off') {
      _screenShareStatus = '';
    }
    setState(() {});
  }

  Future<void> _ensureToneFiles() async {
    if (_connectingTonePath != null && _ringingTonePath != null) return;
    final dir = await getTemporaryDirectory();
    final connecting = File('${dir.path}/respect_connecting_tone.wav');
    final ringing = File('${dir.path}/respect_ringing_tone.wav');
    if (!await connecting.exists()) {
      await connecting.writeAsBytes(_makeToneWav(durationMs: 260, frequencyA: 520, frequencyB: 740, volume: 0.32), flush: true);
    }
    if (!await ringing.exists()) {
      await ringing.writeAsBytes(_makeToneWav(durationMs: 980, frequencyA: 430, frequencyB: 480, volume: 0.28), flush: true);
    }
    _connectingTonePath = connecting.path;
    _ringingTonePath = ringing.path;
  }

  Uint8List _makeToneWav({required int durationMs, required double frequencyA, required double frequencyB, required double volume}) {
    const sampleRate = 16000;
    final samples = (sampleRate * durationMs / 1000).round();
    final pcm = BytesBuilder();
    for (var i = 0; i < samples; i++) {
      final t = i / sampleRate;
      final envelope = math.sin(math.pi * i / samples).clamp(0.0, 1.0);
      final wave = (math.sin(2 * math.pi * frequencyA * t) * 0.65) + (math.sin(2 * math.pi * frequencyB * t) * 0.35);
      final value = (wave * envelope * volume * 32767).round().clamp(-32768, 32767);
      pcm.addByte(value & 0xff);
      pcm.addByte((value >> 8) & 0xff);
    }
    final data = pcm.toBytes();
    final out = BytesBuilder();
    void ascii(String v) => out.add(v.codeUnits);
    void u16(int v) => out.add([v & 0xff, (v >> 8) & 0xff]);
    void u32(int v) => out.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    ascii('RIFF');
    u32(36 + data.length);
    ascii('WAVEfmt ');
    u32(16);
    u16(1);
    u16(1);
    u32(sampleRate);
    u32(sampleRate * 2);
    u16(2);
    u16(16);
    ascii('data');
    u32(data.length);
    out.add(data);
    return out.toBytes();
  }

  void _setToneMode(String mode) {
    if (!widget.isCaller || _ending || _answered) mode = 'silent';
    if (_toneMode == mode && _toneTimer?.isActive == true) return;
    _toneMode = mode;
    _toneTimer?.cancel();
    _toneTimer = null;
    if (mode == 'silent') {
      unawaited(_tonePlayer.stop());
      return;
    }
    unawaited(_playToneTick(mode));
    _toneTimer = Timer.periodic(Duration(milliseconds: mode == 'ringing' ? 2300 : 1450), (_) => unawaited(_playToneTick(mode)));
  }

  Future<void> _playToneTick(String mode) async {
    if (_toneMode != mode || _ending || _answered) return;
    try {
      await _ensureToneFiles();
      final path = mode == 'ringing' ? _ringingTonePath : _connectingTonePath;
      if (path == null) return;
      await _tonePlayer.stop();
      await _tonePlayer.setVolume(mode == 'ringing' ? 0.82 : 0.62);
      await _tonePlayer.play(DeviceFileSource(path));
    } catch (_) {}
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

  Future<void> _toggleFlash() async {
    if (_changingFlash) return;
    setState(() => _changingFlash = true);
    final next = !_flashOn;
    final ok = await _setFlashEnabled(next);
    if (!mounted) return;
    setState(() {
      if (ok) _flashOn = next;
      _changingFlash = false;
    });
  }

  Future<bool> _setFlashEnabled(bool enabled) async {
    try {
      if (!enabled) {
        try { await _flashController?.setFlashMode(FlashMode.off); } catch (_) {}
        try { await _flashController?.dispose(); } catch (_) {}
        _flashController = null;
        _flashOn = false;
        return true;
      }
      final permission = await Permission.camera.request();
      if (!permission.isGranted) {
        _showError('يجب السماح للكاميرا لتشغيل الفلاش');
        return false;
      }
      final cameras = await availableCameras();
      final backCameras = cameras.where((c) => c.lensDirection == CameraLensDirection.back).toList();
      final CameraDescription? backCamera = backCameras.isNotEmpty ? backCameras.first : (cameras.isNotEmpty ? cameras.first : null);
      if (backCamera == null) {
        _showError('لا توجد كاميرا خلفية لتشغيل الفلاش');
        return false;
      }
      final controller = CameraController(backCamera, ResolutionPreset.low, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await controller.initialize();
      await controller.setFlashMode(FlashMode.torch);
      _flashController = controller;
      return true;
    } catch (e) {
      _showError('تعذر تشغيل الفلاش. قد تكون الكاميرا مستخدمة أثناء مكالمة الفيديو: $e');
      return false;
    }
  }

  Future<void> _toggleScreenShare() async {
    if (_changingScreenShare) return;
    setState(() {
      _changingScreenShare = true;
      _screenShareStatus = _screenSharing ? 'جاري إيقاف مشاركة الشاشة...' : 'اختر الشاشة التي تريد مشاركتها...';
    });

    final ok = await _callService.toggleScreenShare();

    if (!mounted) return;
    setState(() {
      if (ok) {
        _screenSharing = _callService.screenSharing;
        _screenShareStatus = _screenSharing ? 'أنت تشارك الشاشة الآن' : '';
      } else if (!_screenSharing) {
        _screenShareStatus = '';
      }
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
    final result = _callResult(_answered || _seconds > 0 ? 'answered' : (widget.isCaller ? 'cancelled' : 'rejected'));
    _ending = true;
    _setToneMode('silent');
    await _setFlashEnabled(false);
    await _callService.endCall(reason: result == 'rejected' ? 'rejected' : (result == 'cancelled' ? 'cancelled' : 'ended'));
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop(result);
  }

  void _showError(String error) {
    if (!mounted) return;
    AppDialog.error(
      context,
      title: 'خطأ في المكالمة',
      message: error,
      buttonText: 'إغلاق',
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _remoteVideoWatchTimer?.cancel();
    _toneTimer?.cancel();
    unawaited(_tonePlayer.dispose());
    unawaited(_setFlashEnabled(false));
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
            AppText(
              widget.peerName,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            AppText(_callStatus, style: const TextStyle(color: Colors.white70, fontSize: 16)),
            if (_seconds > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: AppText(_formatTime(), style: const TextStyle(color: Colors.white60, fontSize: 16)),
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
              AppText(widget.peerName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 3),
              AppText(_seconds > 0 ? _formatTime() : _callStatus, style: const TextStyle(color: Colors.white70)),
              if (_screenShareStatus.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: AppText(_screenShareStatus, style: const TextStyle(color: Color(0xFFBFA7FF), fontSize: 11, fontWeight: FontWeight.w700)),
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
              mirror: !_screenSharing,
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
    final showRemoteVideo = widget.video && _remoteVideoAvailable && _remoteRenderer.srcObject != null;

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

                if (_localVideoEnabled && _hasLocalVideoPreview) _buildDraggablePip(constraints),

                if (_screenShareStatus.trim().isNotEmpty)
                  Positioned(
                    left: 18,
                    right: 18,
                    bottom: 126,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: Container(
                        key: ValueKey(_screenShareStatus),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0x558B5CF6)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_screenSharing ? Icons.screen_share_rounded : Icons.hourglass_top_rounded, color: const Color(0xFFBFA7FF), size: 20),
                            const SizedBox(width: 8),
                            Expanded(child: AppText(_screenShareStatus, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12))),
                          ],
                        ),
                      ),
                    ),
                  ),

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
                          icon: _flashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                          active: _flashOn,
                          onTap: _toggleFlash,
                          label: _changingFlash ? '...' : (_flashOn ? 'الفلاش' : 'فلاش'),
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


class GroupCallParticipant {
  final String callId;
  final String username;
  final String name;
  final String? avatarPath;

  const GroupCallParticipant({
    required this.callId,
    required this.username,
    required this.name,
    this.avatarPath,
  });
}

class GroupCallScreen extends StatefulWidget {
  final String groupName;
  final bool video;
  final String currentUsername;
  final String currentName;
  final String? currentAvatarPath;
  final List<GroupCallParticipant> participants;

  const GroupCallScreen({
    super.key,
    required this.groupName,
    required this.video,
    required this.currentUsername,
    required this.currentName,
    this.currentAvatarPath,
    required this.participants,
  });

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  final List<_GroupPeerTileState> _peers = <_GroupPeerTileState>[];
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  MediaStream? _localPreviewStream;
  bool _muted = false;
  bool _speaker = true;
  bool _ending = false;
  int _seconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _speaker = widget.video;
    _boot();
  }

  Future<void> _boot() async {
    await _localRenderer.initialize();
    if (!mounted) return;

    for (final p in widget.participants) {
      final service = CallService();
      final tile = _GroupPeerTileState(participant: p, callService: service);
      await tile.remoteRenderer.initialize();
      service.onLocalStream = (stream) {
        _localPreviewStream ??= stream;
        _localRenderer.srcObject ??= stream;
        if (mounted) setState(() {});
      };
      service.onRemoteStream = (stream) {
        tile.remoteRenderer.srcObject = stream;
        tile.connected = true;
        tile.hasVideo = stream.getVideoTracks().isNotEmpty;
        if (mounted) setState(() {});
      };
      service.onCallPhaseChanged = (phase) {
        tile.phase = phase;
        if (mounted) setState(() {});
      };
      service.onCallEnded = (reason) {
        tile.phase = 'ended';
        tile.connected = false;
        if (mounted) setState(() {});
      };
      service.onError = (error) {
        tile.phase = 'failed';
        if (mounted) setState(() {});
      };
      _peers.add(tile);
    }

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_ending) setState(() => _seconds++);
    });

    for (final tile in _peers) {
      unawaited(tile.callService.startCall(
        tile.participant.callId,
        widget.video,
        callerUsername: widget.currentUsername,
        calleeUsername: tile.participant.username,
      ).then((_) => tile.callService.toggleSpeaker(_speaker)));
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
  }

  String _formatTime() {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  ImageProvider? _imageProvider(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    if (path.startsWith('http')) return NetworkImage(path);
    final file = File(path);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  Future<void> _endAll() async {
    if (_ending) return;
    setState(() => _ending = true);
    for (final tile in _peers) {
      unawaited(tile.callService.endCall(reason: 'ended'));
    }
    if (!mounted) return;
    Navigator.of(context).pop('answered');
  }

  void _toggleMute() {
    final next = !_muted;
    for (final tile in _peers) {
      tile.callService.toggleMute();
    }
    if (mounted) setState(() => _muted = next);
  }

  void _toggleSpeaker() {
    final next = !_speaker;
    for (final tile in _peers) {
      tile.callService.toggleSpeaker(next);
    }
    if (mounted) setState(() => _speaker = next);
  }

  int _crossAxisCount(int count) {
    if (count <= 1) return 1;
    if (count <= 4) return 2;
    return 3;
  }

  Widget _buildLocalTile() {
    final avatar = _imageProvider(widget.currentAvatarPath);
    return _GroupCallTile(
      name: '${widget.currentName} • أنت',
      avatar: avatar,
      video: widget.video,
      renderer: _localRenderer,
      mirror: true,
      hasVideo: widget.video && _localRenderer.srcObject != null,
      status: 'متصل',
      isMe: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[_buildLocalTile(), ..._peers.map((p) => _GroupCallTile(
      name: p.participant.name,
      avatar: _imageProvider(p.participant.avatarPath),
      video: widget.video,
      renderer: p.remoteRenderer,
      hasVideo: widget.video && p.hasVideo && p.remoteRenderer.srcObject != null,
      status: p.connected ? 'متصل' : _phaseText(p.phase),
      isMe: false,
    ))];

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 82, 10, 118),
                child: GridView.count(
                  crossAxisCount: _crossAxisCount(tiles.length),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: widget.video ? .78 : .92,
                  children: tiles,
                ),
              ),
            ),
            Positioned(
              top: 14,
              left: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .56),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    Icon(widget.video ? Icons.videocam_rounded : Icons.call_rounded, color: const Color(0xFFBFA7FF)),
                    const SizedBox(width: 9),
                    Expanded(child: AppText('${widget.groupName} • ${_formatTime()}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900))),
                    AppText('${tiles.length} أشخاص', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 28,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _CallButton(icon: _muted ? Icons.mic_off : Icons.mic, active: !_muted, onTap: _toggleMute, label: _muted ? 'مكتوم' : 'مايك'),
                  const SizedBox(width: 14),
                  _CallButton(icon: _speaker ? Icons.volume_up : Icons.volume_off, active: _speaker, onTap: _toggleSpeaker, label: 'مكبر'),
                  const SizedBox(width: 14),
                  _CallButton(icon: Icons.call_end, active: false, onTap: _endAll, label: 'إنهاء', color: Colors.red),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _phaseText(String phase) {
    switch (phase) {
      case 'ringing': return 'يرن الآن';
      case 'connected': return 'متصل';
      case 'waiting_offer': return 'ينتظر الاتصال';
      case 'answered_waiting_media': return 'جاري توصيل الصوت';
      case 'reconnecting': return 'إعادة اتصال';
      case 'ended': return 'خرج';
      case 'failed': return 'فشل';
      default: return 'جاري الاتصال';
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final tile in _peers) {
      tile.remoteRenderer.srcObject = null;
      tile.remoteRenderer.dispose();
      tile.callService.dispose();
    }
    _localRenderer.srcObject = null;
    _localRenderer.dispose();
    super.dispose();
  }
}

class _GroupPeerTileState {
  final GroupCallParticipant participant;
  final CallService callService;
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool connected = false;
  bool hasVideo = false;
  String phase = 'connecting';

  _GroupPeerTileState({required this.participant, required this.callService});
}

class _GroupCallTile extends StatelessWidget {
  final String name;
  final ImageProvider? avatar;
  final bool video;
  final RTCVideoRenderer renderer;
  final bool hasVideo;
  final bool mirror;
  final String status;
  final bool isMe;

  const _GroupCallTile({
    required this.name,
    required this.avatar,
    required this.video,
    required this.renderer,
    required this.hasVideo,
    this.mirror = false,
    required this.status,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0B0611),
          border: Border.all(color: isMe ? const Color(0xFF8B5CF6) : Colors.white12, width: isMe ? 2 : 1),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (video && hasVideo)
              RTCVideoView(renderer, mirror: mirror, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            else
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF170026), Colors.black]),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(radius: 42, backgroundImage: avatar, backgroundColor: Colors.white12, child: avatar == null ? const Icon(Icons.person_rounded, color: Colors.white, size: 42) : null),
                      const SizedBox(height: 12),
                      AppText(status, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: .56), borderRadius: BorderRadius.circular(14)),
                child: AppText(name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
              ),
            ),
          ],
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
        AppText(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
