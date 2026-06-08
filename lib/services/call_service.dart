import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void _logIgnoredError(Object error, StackTrace stackTrace) {
  assert(() {
    debugPrint('Ignored recoverable error: $error');
    return true;
  }());
}


class CallService {
  static final SupabaseClient _client = Supabase.instance.client;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RealtimeChannel? _signalChannel;

  String? _currentRoomId;
  bool _isCallActive = false;
  bool _isDisposed = false;
  bool _ending = false;
  bool _remoteDescriptionSet = false;
  bool _localDescriptionSet = false;
  bool _listening = false;
  bool _offerHandled = false;
  bool _answerHandled = false;
  bool _makingOffer = false;
  bool _localVideoEnabled = false;
  bool _microphoneMuted = false;
  bool _screenSharing = false;
  MediaStream? _screenStream;
  MediaStreamTrack? _cameraVideoTrack;
  MediaStreamTrack? _screenVideoTrack;

  final String _instanceId = DateTime.now().microsecondsSinceEpoch.toString();
  final Set<String> _handledSignals = <String>{};
  final List<RTCIceCandidate> _pendingCandidates = <RTCIceCandidate>[];
  final List<Map<String, dynamic>> _earlySignals = <Map<String, dynamic>>[];

  Timer? _connectTimeout;
  Timer? _healthTimer;
  Timer? _deferredCloseTimer;

  Function(MediaStream)? onLocalStream;
  Function(MediaStream)? onRemoteStream;
  Function(String error)? onError;
  Function()? onCallEnded;
  Function(bool enabled)? onLocalVideoChanged;
  Function(bool muted)? onMicrophoneMuteChanged;
  Function(bool enabled)? onScreenShareChanged;

  bool get isCallActive => _isCallActive;
  bool get localVideoEnabled => _localVideoEnabled;
  bool get microphoneMuted => _microphoneMuted;
  bool get screenSharing => _screenSharing;

  Future<bool> requestPermissions({required bool video}) async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;

    if (video) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) return false;
    }

    return true;
  }

  Future<bool> requestCameraPermissionOnly() async {
    final cam = await Permission.camera.request();
    return cam.isGranted;
  }

  Map<String, dynamic> _audioConstraints() {
    return <String, dynamic>{
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
      'googEchoCancellation': true,
      'googNoiseSuppression': true,
      'googAutoGainControl': true,
      'googHighpassFilter': true,
    };
  }

  Map<String, dynamic> _videoConstraints() {
    return <String, dynamic>{
      'facingMode': 'user',
      'width': <String, dynamic>{'ideal': 640, 'max': 960},
      'height': <String, dynamic>{'ideal': 360, 'max': 540},
      'frameRate': <String, dynamic>{'ideal': 20, 'max': 24},
    };
  }

  Future<MediaStream?> _createLocalStream(bool video) async {
    final constraints = <String, dynamic>{
      'audio': _audioConstraints(),
      'video': video ? _videoConstraints() : false,
    };

    try {
      final stream = await navigator.mediaDevices.getUserMedia(constraints);
      _localVideoEnabled = stream.getVideoTracks().isNotEmpty;
      _microphoneMuted = false;
      _cameraVideoTrack = stream.getVideoTracks().isNotEmpty ? stream.getVideoTracks().first : null;
      await Helper.setSpeakerphoneOn(true);
      return stream;
    } catch (e) {
      _safeError('تعذر تشغيل المايك/الكاميرا: $e');
      return null;
    }
  }

  Future<void> _createPeerConnection() async {
    final config = <String, dynamic>{
      'iceServers': <Map<String, dynamic>>[
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun2.l.google.com:19302'},
        {'urls': 'stun:stun3.l.google.com:19302'},
        {'urls': 'stun:stun4.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'iceTransportPolicy': 'all',
    };

    final constraints = <String, dynamic>{
      'mandatory': <String, dynamic>{},
      'optional': <Map<String, dynamic>>[
        {'DtlsSrtpKeyAgreement': true},
      ],
    };

    _peerConnection = await createPeerConnection(config, constraints);
    final pc = _peerConnection;
    if (pc == null) return;

    pc.onIceCandidate = (candidate) {
      final raw = candidate.candidate;
      if (_currentRoomId == null || raw == null || raw.trim().isEmpty || _ending) return;
      unawaited(_sendSignal('candidate', candidate.toMap()));
    };

    pc.onTrack = (event) {
      if (_ending) return;

      MediaStream? stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams.first;
      } else {
        stream = _remoteStream;
      }

      if (stream == null) return;
      _remoteStream = stream;
      _markConnected();
      onRemoteStream?.call(stream);
    };

    pc.onAddStream = (stream) {
      if (_ending) return;
      _remoteStream = stream;
      _markConnected();
      onRemoteStream?.call(stream);
    };

    pc.onConnectionState = (state) {
      if (_ending) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _markConnected();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(_tryRestartIceOrEnd());
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _finishCall(notify: true);
      }
    };

    pc.onIceConnectionState = (state) {
      if (_ending) return;
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _markConnected();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        unawaited(_tryRestartIceOrEnd());
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _scheduleDeferredClose();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _finishCall(notify: true);
      }
    };
  }

  Future<bool> _prepareMediaAndPeer(bool video) async {
    final hasPermissions = await requestPermissions(video: video);
    if (!hasPermissions) {
      _safeError(video ? 'يجب السماح للمايك والكاميرا' : 'يجب السماح للمايك');
      return false;
    }

    _localStream = await _createLocalStream(video);
    if (_localStream == null) return false;
    final localStream = _localStream;
    if (localStream == null) return false;
    onLocalStream?.call(localStream);
    onLocalVideoChanged?.call(_localVideoEnabled);

    await _createPeerConnection();
    final pc = _peerConnection;
    if (pc == null) return false;

    // مهم جدًا: نستقبل الفيديو دائمًا حتى لو بدأت المكالمة صوت فقط.
    // هذا يحل مشكلة أن صورة الطرف الثاني لا تظهر إذا كان أحد الطرفين بدأ صوت.

    for (final track in localStream.getTracks()) {
      await pc.addTrack(track, localStream);
    }

    await Future<void>.delayed(const Duration(milliseconds: 250));
    return true;
  }

  Future<void> startCall(String roomId, bool video) async {
    _resetRuntimeFlags();
    _currentRoomId = roomId;

    final ok = await _prepareMediaAndPeer(video);
    if (!ok || _peerConnection == null || _ending) return;

    await _listenForSignals(roomId);
    await _clearOldSignals(roomId);
    await _createAndSendOffer(video, signalType: 'offer');
    await _loadExistingSignals(roomId);
    _startConnectTimeout();
    _startHealthWatch();
  }

  Future<void> acceptCall(String roomId, bool video) async {
    _resetRuntimeFlags();
    _currentRoomId = roomId;

    final ok = await _prepareMediaAndPeer(video);
    if (!ok || _peerConnection == null || _ending) return;

    await _listenForSignals(roomId);
    await _sendSignal('receiver_ready', {'video': video, 'ready': true});
    await _loadExistingSignals(roomId);
    await _drainEarlySignals();
    _startConnectTimeout();
    _startHealthWatch();
  }

  void _resetRuntimeFlags() {
    _isDisposed = false;
    _ending = false;
    _isCallActive = false;
    _remoteDescriptionSet = false;
    _localDescriptionSet = false;
    _listening = false;
    _offerHandled = false;
    _answerHandled = false;
    _makingOffer = false;
    _localVideoEnabled = false;
    _microphoneMuted = false;
    _screenSharing = false;
    _screenStream = null;
    _cameraVideoTrack = null;
    _screenVideoTrack = null;
    _handledSignals.clear();
    _pendingCandidates.clear();
    _earlySignals.clear();
    _connectTimeout?.cancel();
    _healthTimer?.cancel();
    _deferredCloseTimer?.cancel();
  }

  Future<void> _listenForSignals(String roomId) async {
    if (_listening) return;
    _listening = true;

    try {
      await _signalChannel?.unsubscribe();
    } catch (e, st) { _logIgnoredError(e, st); }

    _signalChannel = _client.channel('call_signals_${roomId}_$_instanceId');

    _signalChannel!
        .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'call_signals',
      callback: (payload) {
        final row = Map<String, dynamic>.from(payload.newRecord);
        unawaited(_handleSignalRow(row));
      },
    )
        .subscribe();

    await Future<void>.delayed(const Duration(milliseconds: 450));
  }

  Future<void> _clearOldSignals(String roomId) async {
    try {
      await _client.from('call_signals').delete().eq('room_id', roomId);
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  Future<void> _loadExistingSignals(String roomId) async {
    try {
      final rows = await _client
          .from('call_signals')
          .select()
          .eq('room_id', roomId)
          .order('created_at', ascending: true);

      for (final item in rows) {
        await _handleSignalRow(Map<String, dynamic>.from(item));
      }
    } catch (e) {
      _safeError('تعذر قراءة إشارات المكالمة: $e');
    }
  }

  Future<void> _sendSignal(String type, dynamic data) async {
    final roomId = _currentRoomId;
    if (roomId == null || _ending) return;

    try {
      await _client.from('call_signals').insert({
        'room_id': roomId,
        'sender_id': _instanceId,
        'type': type,
        'payload': data,
      });
    } catch (e) {
      _safeError('فشل إرسال إشارة المكالمة: $e');
    }
  }

  Future<void> _handleSignalRow(Map<String, dynamic> row) async {
    if (_ending) return;
    if (row['room_id']?.toString() != _currentRoomId) return;
    if (row['sender_id']?.toString() == _instanceId) return;

    final signalId = (row['id'] ?? '${row['type']}_${row['created_at']}_${row['sender_id']}').toString();
    if (_handledSignals.contains(signalId)) return;
    _handledSignals.add(signalId);

    if (_peerConnection == null) {
      _earlySignals.add(row);
      return;
    }

    final type = row['type']?.toString();
    final payload = row['payload'];
    final data = payload is Map ? Map<String, dynamic>.from(payload) : <String, dynamic>{};
    await _handleSignal(type, data);
  }

  Future<void> _drainEarlySignals() async {
    if (_earlySignals.isEmpty) return;
    final copy = List<Map<String, dynamic>>.from(_earlySignals);
    _earlySignals.clear();
    for (final row in copy) {
      final type = row['type']?.toString();
      final payload = row['payload'];
      final data = payload is Map ? Map<String, dynamic>.from(payload) : <String, dynamic>{};
      await _handleSignal(type, data);
    }
  }

  Future<void> _createAndSendOffer(bool video, {required String signalType}) async {
    final pc = _peerConnection;
    if (pc == null || _ending || _makingOffer) return;

    _makingOffer = true;
    try {
      final offer = await pc.createOffer(<String, dynamic>{
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      await pc.setLocalDescription(offer);
      _localDescriptionSet = true;

      await _sendSignal(signalType, {
        'sdp': offer.sdp,
        'type': offer.type,
        'video': video,
        'localVideoEnabled': _localVideoEnabled,
      });
    } finally {
      _makingOffer = false;
    }
  }

  Future<void> _processOffer(Map<String, dynamic> data, {required bool renegotiate}) async {
    final pc = _peerConnection;
    if (pc == null || _ending) return;
    if (!renegotiate && _offerHandled) return;

    final sdp = data['sdp']?.toString();
    final descType = data['type']?.toString();
    if (sdp == null || sdp.trim().isEmpty || descType == null || descType.trim().isEmpty) return;

    final stable = await _waitForSignalingState(
      allowed: const {RTCSignalingState.RTCSignalingStateStable},
      allowNullAsReady: true,
      timeout: const Duration(seconds: 8),
    );

    if (!stable || _ending || _peerConnection == null) {
      _safeError('تعذر تجهيز الاتصال لاستقبال المكالمة. حاول مرة ثانية.');
      _finishCall(notify: true);
      return;
    }

    try {
      if (!renegotiate) _offerHandled = true;
      await pc.setRemoteDescription(RTCSessionDescription(sdp, descType));
      _remoteDescriptionSet = true;
      await _flushPendingCandidates();

      final answer = await pc.createAnswer(<String, dynamic>{
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      await pc.setLocalDescription(answer);
      _localDescriptionSet = true;

      await _sendSignal(renegotiate ? 'renegotiate_answer' : 'answer', {
        'sdp': answer.sdp,
        'type': answer.type,
        'localVideoEnabled': _localVideoEnabled,
      });
    } catch (e) {
      _safeError('خطأ في معالجة عرض المكالمة: $e');
      _finishCall(notify: true);
    }
  }

  Future<void> _processAnswer(Map<String, dynamic> data, {required bool renegotiate}) async {
    final pc = _peerConnection;
    if (pc == null || _ending) return;
    if (!renegotiate && (_answerHandled || _remoteDescriptionSet)) return;

    final sdp = data['sdp']?.toString();
    final descType = data['type']?.toString();
    if (sdp == null || sdp.trim().isEmpty || descType == null || descType.trim().isEmpty) return;

    final ready = await _waitForSignalingState(
      allowed: const {RTCSignalingState.RTCSignalingStateHaveLocalOffer},
      allowNullAsReady: false,
      timeout: const Duration(seconds: 8),
    );

    if (!ready || _ending || _peerConnection == null) {
      _safeError('وصل رد المكالمة لكن الاتصال المحلي غير جاهز. حاول مرة ثانية.');
      _finishCall(notify: true);
      return;
    }

    try {
      if (!renegotiate) _answerHandled = true;
      await pc.setRemoteDescription(RTCSessionDescription(sdp, descType));
      _remoteDescriptionSet = true;
      await _flushPendingCandidates();
    } catch (e) {
      _safeError('خطأ في معالجة رد المكالمة: $e');
      _finishCall(notify: true);
    }
  }

  Future<void> _handleSignal(String? type, Map<String, dynamic> data) async {
    if (type == null || _ending) return;

    try {
      switch (type) {
        case 'offer':
          await _processOffer(data, renegotiate: false);
          break;
        case 'answer':
          await _processAnswer(data, renegotiate: false);
          break;
        case 'renegotiate_offer':
          await _processOffer(data, renegotiate: true);
          break;
        case 'renegotiate_answer':
          await _processAnswer(data, renegotiate: true);
          break;
        case 'candidate':
          await _handleCandidate(data);
          break;
        case 'camera_state':
          break;
        case 'receiver_ready':
          break;
        case 'end':
        case 'reject':
        case 'cancel':
          _finishCall(notify: true);
          break;
      }
    } catch (e) {
      _safeError('خطأ في معالجة إشارة المكالمة: $e');
    }
  }

  Future<void> _handleCandidate(Map<String, dynamic> data) async {
    final pc = _peerConnection;
    if (pc == null || _ending) return;

    final raw = data['candidate']?.toString();
    if (raw == null || raw.trim().isEmpty) return;

    final candidate = RTCIceCandidate(
      raw,
      data['sdpMid']?.toString(),
      data['sdpMLineIndex'] is int ? data['sdpMLineIndex'] as int : int.tryParse('${data['sdpMLineIndex']}'),
    );

    if (_remoteDescriptionSet) {
      try {
        await pc.addCandidate(candidate);
      } catch (e, st) { _logIgnoredError(e, st); }
    } else {
      _pendingCandidates.add(candidate);
    }
  }

  Future<void> _flushPendingCandidates() async {
    final pc = _peerConnection;
    if (pc == null || !_remoteDescriptionSet) return;

    final list = List<RTCIceCandidate>.from(_pendingCandidates);
    _pendingCandidates.clear();

    for (final candidate in list) {
      try {
        await pc.addCandidate(candidate);
      } catch (e, st) { _logIgnoredError(e, st); }
    }
  }

  Future<bool> _waitForSignalingState({
    required Set<RTCSignalingState> allowed,
    required bool allowNullAsReady,
    required Duration timeout,
  }) async {
    final started = DateTime.now();

    while (!_ending && _peerConnection != null) {
      final state = _peerConnection?.signalingState;
      if (state == null && allowNullAsReady) return true;
      if (state != null && allowed.contains(state)) return true;

      if (DateTime.now().difference(started) >= timeout) return false;
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }

    return false;
  }

  void _markConnected() {
    if (_ending) return;
    _isCallActive = true;
    _connectTimeout?.cancel();
    _deferredCloseTimer?.cancel();
  }

  void _startConnectTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(const Duration(seconds: 45), () {
      if (!_isCallActive && !_ending) {
        _safeError('انتهت مهلة الاتصال، تحقق من الإنترنت وأن الطرف الثاني فتح المكالمة.');
        _finishCall(notify: true);
      }
    });
  }

  void _startHealthWatch() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 6), (_) async {
      if (_ending) return;
      final pc = _peerConnection;
      if (pc == null) return;
      final ice = pc.iceConnectionState;
      final conn = pc.connectionState;
      if (ice == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          ice == RTCIceConnectionState.RTCIceConnectionStateCompleted ||
          conn == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _markConnected();
      }
    });
  }

  void _scheduleDeferredClose() {
    _deferredCloseTimer?.cancel();
    _deferredCloseTimer = Timer(const Duration(seconds: 12), () {
      if (!_ending && !_isCallActive) {
        _finishCall(notify: true);
      }
    });
  }

  Future<void> _tryRestartIceOrEnd() async {
    final pc = _peerConnection;
    if (pc == null || _ending) return;

    try {
      await pc.restartIce();
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!_isCallActive && !_ending) {
        _finishCall(notify: true);
      }
    } catch (_) {
      _finishCall(notify: true);
    }
  }

  Future<bool> setVideoEnabled(bool enable) async {
    if (_ending || _peerConnection == null || _localStream == null) return false;

    if (!enable) {
      final localStream = _localStream;
      if (localStream == null) return false;
      for (final track in localStream.getVideoTracks()) {
        track.enabled = false;
      }
      _localVideoEnabled = false;
      onLocalVideoChanged?.call(false);
      await _sendSignal('camera_state', {'enabled': false});
      return true;
    }

    final hasPermission = await requestCameraPermissionOnly();
    if (!hasPermission) {
      _safeError('يجب السماح للكاميرا لتشغيل الفيديو');
      return false;
    }

    final currentVideoTracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (currentVideoTracks.isNotEmpty) {
      _cameraVideoTrack ??= currentVideoTracks.first;
      for (final track in currentVideoTracks) {
        track.enabled = true;
      }
      _localVideoEnabled = true;
      onLocalVideoChanged?.call(true);
      await _sendSignal('camera_state', {'enabled': true});
      return true;
    }

    try {
      final videoStream = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': false,
        'video': _videoConstraints(),
      });

      final newTracks = videoStream.getVideoTracks();
      if (newTracks.isEmpty) {
        await videoStream.dispose();
        _safeError('لم يتم العثور على مسار فيديو من الكاميرا');
        return false;
      }

      final pc = _peerConnection;
      final local = _localStream;
      if (pc == null || local == null) return false;

      for (final track in newTracks) {
        await local.addTrack(track, addToNative: true);
        await pc.addTrack(track, local);
        _cameraVideoTrack ??= track;
      }

      _localVideoEnabled = true;
      onLocalStream?.call(local);
      onLocalVideoChanged?.call(true);

      // عند تشغيل الفيديو أثناء مكالمة صوت فقط، لازم نعيد التفاوض كي يظهر عند الطرف الآخر.
      await _createAndSendOffer(true, signalType: 'renegotiate_offer');
      await _sendSignal('camera_state', {'enabled': true});
      return true;
    } catch (e) {
      _safeError('تعذر تشغيل الفيديو أثناء المكالمة: $e');
      return false;
    }
  }

  Future<void> endCall() async {
    if (_ending) return;
    await _sendSignal('end', {'ended': true});
    _finishCall(notify: true);
  }

  void _finishCall({required bool notify}) {
    if (_ending && _peerConnection == null && _localStream == null && _remoteStream == null) return;

    _ending = true;
    _isCallActive = false;
    _connectTimeout?.cancel();
    _healthTimer?.cancel();
    _deferredCloseTimer?.cancel();

    try {
      _signalChannel?.unsubscribe();
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
        track.stop();
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      for (final track in _screenStream?.getTracks() ?? <MediaStreamTrack>[]) {
        track.stop();
      }
      _screenStream?.dispose();
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      _localStream?.dispose();
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      _remoteStream?.dispose();
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      _peerConnection?.close();
    } catch (e, st) { _logIgnoredError(e, st); }

    _localStream = null;
    _remoteStream = null;
    _peerConnection = null;
    _signalChannel = null;
    _currentRoomId = null;
    _remoteDescriptionSet = false;
    _localDescriptionSet = false;
    _offerHandled = false;
    _answerHandled = false;
    _makingOffer = false;
    _localVideoEnabled = false;
    _microphoneMuted = false;
    _screenSharing = false;
    _screenStream = null;
    _cameraVideoTrack = null;
    _screenVideoTrack = null;
    _pendingCandidates.clear();
    _earlySignals.clear();

    if (notify && !_isDisposed) {
      Future<void>.microtask(() {
        if (!_isDisposed) onCallEnded?.call();
      });
    }
  }

  void dispose() {
    _isDisposed = true;
    _finishCall(notify: false);
    onLocalStream = null;
    onRemoteStream = null;
    onError = null;
    onCallEnded = null;
    onLocalVideoChanged = null;
    onMicrophoneMuteChanged = null;
    onScreenShareChanged = null;
  }

  bool setMicrophoneMuted(bool muted) {
    final tracks = _localStream?.getAudioTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) {
      _safeError('لا يوجد مسار صوت لتطبيق الكتم');
      return _microphoneMuted;
    }

    for (final track in tracks) {
      track.enabled = !muted;
    }

    _microphoneMuted = muted;
    onMicrophoneMuteChanged?.call(_microphoneMuted);
    return _microphoneMuted;
  }

  bool toggleMute() => setMicrophoneMuted(!_microphoneMuted);

  bool setRemoteAudioMuted(bool muted) {
    final tracks = _remoteStream?.getAudioTracks() ?? <MediaStreamTrack>[];
    for (final track in tracks) {
      track.enabled = !muted;
    }
    return muted;
  }

  Future<RTCRtpSender?> _videoSender() async {
    final pc = _peerConnection;
    if (pc == null) return null;
    final senders = await pc.getSenders();
    for (final sender in senders) {
      final track = sender.track;
      if (track != null && track.kind == 'video') return sender;
    }
    return null;
  }

  Future<bool> startScreenShare() async {
    if (_ending || _peerConnection == null || _localStream == null) return false;
    if (_screenSharing) return true;

    MediaStream? displayStream;

    try {
      // Android 14+ يقتل التطبيق إذا بدأ الالتقاط بدون MediaProjection permission الصحيح.
      // لذلك نطلب إذن مشاركة الشاشة صراحة قبل getDisplayMedia حتى لا يحصل crash كامل للتطبيق.
      if (Platform.isAndroid) {
        try {
          final granted = await Helper.requestCapturePermission();
          if (!granted) {
            _safeError('تم إلغاء إذن مشاركة الشاشة');
            return false;
          }
          await Future<void>.delayed(const Duration(milliseconds: 350));
        } catch (e) {
          _safeError('تعذر طلب إذن مشاركة الشاشة من النظام: $e');
          return false;
        }
      }

      displayStream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
        // أبقينا القيود بسيطة لأن بعض أجهزة Android تنهار مع قيود width/height/frameRate المعقدة.
        'video': true,
        'audio': false,
      });

      final tracks = displayStream.getVideoTracks();
      if (tracks.isEmpty) {
        try { await displayStream.dispose(); } catch (e, st) { _logIgnoredError(e, st); }
        _safeError('تعذر الحصول على مسار مشاركة الشاشة');
        return false;
      }

      _screenStream = displayStream;
      _screenVideoTrack = tracks.first;

      final localVideoTracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
      _cameraVideoTrack ??= localVideoTracks.isNotEmpty ? localVideoTracks.first : null;

      final sender = await _videoSender();
      if (sender != null) {
        await sender.replaceTrack(_screenVideoTrack);
      } else {
        final pc = _peerConnection;
        final screenVideoTrack = _screenVideoTrack;
        final screenStream = _screenStream;
        if (pc == null || screenVideoTrack == null || screenStream == null) return false;
        await pc.addTrack(screenVideoTrack, screenStream);
        await _createAndSendOffer(true, signalType: 'renegotiate_offer');
      }

      _screenSharing = true;
      final activeScreenStream = _screenStream;
      if (activeScreenStream != null) onLocalStream?.call(activeScreenStream);
      onScreenShareChanged?.call(true);
      await _sendSignal('screen_share_state', {'enabled': true});
      return true;
    } catch (e) {
      try {
        for (final track in displayStream?.getTracks() ?? <MediaStreamTrack>[]) {
          track.stop();
        }
        await displayStream?.dispose();
      } catch (e, st) { _logIgnoredError(e, st); }
      _screenStream = null;
      _screenVideoTrack = null;
      _screenSharing = false;
      onScreenShareChanged?.call(false);
      _safeError('تعذر تشغيل مشاركة الشاشة. إذا كان جهازك Android 14 أو أعلى تأكد من إضافة صلاحيات MediaProjection في AndroidManifest: $e');
      return false;
    }
  }

  Future<bool> stopScreenShare() async {
    if (!_screenSharing) return true;

    try {
      final sender = await _videoSender();
      final cameraTrack = _cameraVideoTrack ?? (_localStream?.getVideoTracks().isNotEmpty == true ? _localStream?.getVideoTracks().first : null);

      if (sender != null && cameraTrack != null) {
        await sender.replaceTrack(cameraTrack);
      }

      for (final track in _screenStream?.getTracks() ?? <MediaStreamTrack>[]) {
        track.stop();
      }
      await _screenStream?.dispose();

      _screenStream = null;
      _screenVideoTrack = null;
      _screenSharing = false;

      final localStream = _localStream;
      if (localStream != null) onLocalStream?.call(localStream);
      onScreenShareChanged?.call(false);
      await _sendSignal('screen_share_state', {'enabled': false});
      return true;
    } catch (e) {
      _safeError('تعذر إيقاف مشاركة الشاشة: $e');
      return false;
    }
  }

  Future<bool> toggleScreenShare() async {
    return _screenSharing ? stopScreenShare() : startScreenShare();
  }

  void toggleSpeaker(bool enable) {
    Helper.setSpeakerphoneOn(enable);
  }

  void switchCamera() {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isNotEmpty) {
      Helper.switchCamera(tracks.first);
    }
  }

  void _safeError(String message) {
    if (_isDisposed || _ending) return;
    onError?.call(message);
  }

  bool _payloadBool(dynamic value) {
    if (value == true) return true;
    final text = value?.toString().toLowerCase().trim();
    return text == 'true' || text == '1' || text == 'yes' || text == 'video';
  }
}
