// ignore_for_file: deprecated_member_use, unused_element, unused_field, unused_import,
// unused_local_variable, unused_element_parameter, prefer_const_constructors,
// prefer_const_declarations, prefer_const_literals_to_create_immutables,
// curly_braces_in_flow_control_structures, sized_box_for_whitespace, dead_code,
// unnecessary_type_check, unnecessary_non_null_assertion, use_build_context_synchronously,
// unnecessary_brace_in_string_interps, prefer_final_fields
// VERSION: v102_remote_video_grid_fix - fixes late remote video track refresh + group-call helpers
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'secure_crypto_service.dart';
import 'supabase_service.dart';

void _logIgnoredError(Object error, StackTrace stackTrace) {
  if (kDebugMode) {
    debugPrint('Ignored error: $error\n$stackTrace');
  }
}

class CallService {
  static final SupabaseClient _client = Supabase.instance.client;
  static const _uuid = Uuid();

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RealtimeChannel? _signalChannel;
  bool _remoteStreamDelivered = false;

  String? _currentRoomId;
  String? _localUsername;
  String? _peerUsername;
  bool _callSignalingE2eeReady = false;
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

  bool _requestedVideoAtStart = false;
  bool _autoVideoUpgradeStarted = false;
  int _iceRestartAttempts = 0;
  Timer? _softIceRestartTimer;

  Completer<void>? _signalingStateCompleter;
  StreamSubscription<RTCSignalingState>? _signalingStateSub;

  final String _instanceId = DateTime.now().microsecondsSinceEpoch.toString();
  final Set<String> _handledSignals = <String>{};          // store signal_uuid
  final List<RTCIceCandidate> _pendingCandidates = <RTCIceCandidate>[];
  final List<Map<String, dynamic>> _earlySignals = <Map<String, dynamic>>[];

  int _nextSeq = 0;
  int _lastProcessedSeq = -1;
  bool _syncRequested = false;

  Timer? _connectTimeout;
  Timer? _healthTimer;
  Timer? _deferredCloseTimer;
  Timer? _offerResendTimer;
  Timer? _answerResendTimer;
  Timer? _readyResendTimer;

  bool _isCallerRole = false;
  RTCSessionDescription? _lastLocalOffer;
  RTCSessionDescription? _lastLocalAnswer;
  final List<Map<String, dynamic>> _recentLocalCandidates = <Map<String, dynamic>>[];

  Function(MediaStream)? onLocalStream;
  Function(MediaStream)? onRemoteStream;
  Function(String error)? onError;
  Function(String reason)? onCallEnded;
  Function(String phase)? onCallPhaseChanged;
  String _lastEndReason = 'none';
  String get lastEndReason => _lastEndReason;
  Function(bool enabled)? onLocalVideoChanged;
  Function(bool muted)? onMicrophoneMuteChanged;
  Function(bool enabled)? onScreenShareChanged;

  bool get isCallActive => _isCallActive;
  bool get localVideoEnabled => _localVideoEnabled;
  bool get microphoneMuted => _microphoneMuted;
  bool get screenSharing => _screenSharing;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  // ─── Permissions ───────────────────────────────────────────────────────────
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

  // ─── Media constraints ────────────────────────────────────────────────────
  Map<String, dynamic> _audioConstraints() => <String, dynamic>{
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'googEchoCancellation': true,
        'googNoiseSuppression': true,
        'googAutoGainControl': true,
        'googHighpassFilter': true,
      };

  Map<String, dynamic> _videoConstraints() => <String, dynamic>{
        'facingMode': 'user',
        'width': <String, dynamic>{'ideal': 640, 'max': 960},
        'height': <String, dynamic>{'ideal': 360, 'max': 540},
        'frameRate': <String, dynamic>{'ideal': 20, 'max': 24},
      };

  Future<MediaStream?> _createLocalStream(bool video) async {
    final constraints = <String, dynamic>{
      'audio': _audioConstraints(),
      'video': video ? _videoConstraints() : false,
    };
    try {
      final stream = await navigator.mediaDevices.getUserMedia(constraints);
      _localVideoEnabled = stream.getVideoTracks().isNotEmpty;
      _microphoneMuted = false;
      _cameraVideoTrack =
          stream.getVideoTracks().isNotEmpty ? stream.getVideoTracks().first : null;
      await Helper.setSpeakerphoneOn(video);
      return stream;
    } catch (e) {
      _safeError('تعذر تشغيل المايك/الكاميرا: $e');
      return null;
    }
  }

  // ─── PeerConnection ────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _fallbackIceServers() => <Map<String, dynamic>>[
        {'urls': 'stun:stun.cloudflare.com:3478'},
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun2.l.google.com:19302'},
        {'urls': 'stun:stun3.l.google.com:19302'},
      ];

  Map<String, String> _backendSecretHeaders() {
    final secret = SupabaseService.pushApiSecret.trim();
    return <String, String>{
      'Accept': 'application/json',
      if (secret.isNotEmpty) 'X-App-Secret': secret,
    };
  }

  Future<List<Map<String, dynamic>>> _fetchTurnIceServers() async {
    final fallback = _fallbackIceServers();

    try {
      final baseUrl = SupabaseService.authOtpBackendBaseUrl.trim();
      if (baseUrl.isEmpty) return fallback;

      final uri = Uri.parse('$baseUrl/turn/credentials');
      final response = await http
          .get(uri, headers: _backendSecretHeaders())
          .timeout(const Duration(seconds: 10));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return fallback;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List) return fallback;

      final out = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final server = Map<String, dynamic>.from(item as Map);
        final urls = server['urls'];
        if (urls == null) continue;
        if (urls is String && urls.trim().isEmpty) continue;
        if (urls is List && urls.isEmpty) continue;
        out.add(server);
      }

      final hasStun = out.any((e) => e['urls'].toString().toLowerCase().contains('stun:'));
      if (!hasStun) out.insert(0, {'urls': 'stun:stun.l.google.com:19302'});

      return out.isEmpty ? fallback : out;
    } catch (e, st) {
      _logIgnoredError(e, st);
      return fallback;
    }
  }

  Future<void> _createPeerConnection() async {
    final iceServers = await _fetchTurnIceServers();

    final config = <String, dynamic>{
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'iceTransportPolicy': 'all',
      'iceCandidatePoolSize': 0,
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

      final map = candidate.toMap();
      _recentLocalCandidates.add(Map<String, dynamic>.from(map));
      if (_recentLocalCandidates.length > 40) {
        _recentLocalCandidates.removeRange(0, _recentLocalCandidates.length - 40);
      }

      unawaited(_sendSignal('candidate', map));
    };

    pc.onTrack = (event) {
      if (_ending) return;
      final stream = event.streams.isNotEmpty ? event.streams.first : _remoteStream;
      if (stream == null) return;
      _remoteStream = stream;

      // مهم: أحيانًا يصل الصوت أولًا ثم يصل Track الفيديو لاحقًا، أو يتغير stream
      // بعد أن سلّمناه للواجهة. لذلك نرسل تحديثًا متكررًا للواجهة عند وصول أي Track.
      if (_isTransportConnected()) {
        _markConnected();
        _deliverRemoteStreamIfReady(forceRefresh: true);
        unawaited(Future<void>.delayed(const Duration(milliseconds: 350), () async {
          if (!_ending && _remoteStream != null) _deliverRemoteStreamIfReady(forceRefresh: true);
        }));
        unawaited(Future<void>.delayed(const Duration(milliseconds: 1200), () async {
          if (!_ending && _remoteStream != null) _deliverRemoteStreamIfReady(forceRefresh: true);
        }));
      } else {
        onCallPhaseChanged?.call('answered_waiting_media');
      }
    };

    pc.onAddStream = (stream) {
      if (_ending) return;
      _remoteStream = stream;
      if (_isTransportConnected()) {
        _markConnected();
        _deliverRemoteStreamIfReady(forceRefresh: true);
      } else {
        onCallPhaseChanged?.call('answered_waiting_media');
      }
    };

    pc.onConnectionState = (state) {
      if (_ending) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _markConnected();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _scheduleSoftIceRestart();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _finishCall(notify: true, reason: _isCallActive ? 'ended' : 'disconnected');
      }
    };

    pc.onIceConnectionState = (state) {
      if (_ending) return;
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _markConnected();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _scheduleSoftIceRestart();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _scheduleSoftIceRestart();
        _scheduleDeferredClose();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _finishCall(notify: true, reason: _isCallActive ? 'ended' : 'disconnected');
      }
      _signalingStateCompleter?.complete();
    };

    pc.onSignalingState = (state) {
      _signalingStateCompleter?.complete();
      _signalingStateCompleter = null;
    };
  }

  // ─── Media + Peer setup ───────────────────────────────────────────────────
  Future<bool> _prepareMediaAndPeer(bool video) async {
    final startAudioOnly = video;
    final hasPermissions = await requestPermissions(video: !startAudioOnly && video);
    if (!hasPermissions) {
      _safeError('يجب السماح للمايك');
      return false;
    }

    _localStream = await _createLocalStream(startAudioOnly ? false : video);
    if (_localStream == null) return false;
    final localStream = _localStream!;
    onLocalStream?.call(localStream);
    onLocalVideoChanged?.call(_localVideoEnabled);

    await _createPeerConnection();
    final pc = _peerConnection;
    if (pc == null) return false;

    for (final track in localStream.getTracks()) {
      await pc.addTrack(track, localStream);
    }

    await Future<void>.delayed(const Duration(milliseconds: 80));
    return true;
  }

  // ─── Start / Accept call ──────────────────────────────────────────────────
  Future<void> startCall(
    String roomId,
    bool video, {
    String? callerUsername,
    String? calleeUsername,
  }) async {
    _resetRuntimeFlags();
    _currentRoomId = roomId;
    _requestedVideoAtStart = video;
    _isCallerRole = true;
    _localUsername = SecureCryptoService.displayUsername(callerUsername ?? '');
    _peerUsername = SecureCryptoService.displayUsername(calleeUsername ?? '');
    onCallPhaseChanged?.call('connecting');

    final e2eeFuture = _prepareCallSignalE2ee();

    final ok = await _prepareMediaAndPeer(video);
    if (!ok || _peerConnection == null || _ending) return;

    await e2eeFuture.timeout(const Duration(seconds: 3), onTimeout: () {});

    await _listenForSignals(roomId);
    await _createAndSendOffer(video, signalType: 'offer');
    _startOfferResendLoop();
    onCallPhaseChanged?.call('ringing');
    _startConnectTimeout();
    _startHealthWatch();
  }

  Future<void> acceptCall(
    String roomId,
    bool video, {
    String? callerUsername,
    String? calleeUsername,
  }) async {
    _resetRuntimeFlags();
    _currentRoomId = roomId;
    _requestedVideoAtStart = video;
    _isCallerRole = false;
    _localUsername = SecureCryptoService.displayUsername(calleeUsername ?? '');
    _peerUsername = SecureCryptoService.displayUsername(callerUsername ?? '');
    onCallPhaseChanged?.call('connecting');

    final e2eeFuture = _prepareCallSignalE2ee();

    final ok = await _prepareMediaAndPeer(video);
    if (!ok || _peerConnection == null || _ending) return;

    await e2eeFuture.timeout(const Duration(seconds: 3), onTimeout: () {});

    await _listenForSignals(roomId);
    await _sendSignal('receiver_ready', {'video': video, 'ready': true});
    _startReadyResendLoop();
    onCallPhaseChanged?.call('waiting_offer');
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
    _lastEndReason = 'none';
    _callSignalingE2eeReady = false;
    _handledSignals.clear();
    _pendingCandidates.clear();
    _earlySignals.clear();
    _recentLocalCandidates.clear();
    _remoteStreamDelivered = false;
    _lastLocalOffer = null;
    _lastLocalAnswer = null;
    _isCallerRole = false;
    _connectTimeout?.cancel();
    _healthTimer?.cancel();
    _deferredCloseTimer?.cancel();
    _softIceRestartTimer?.cancel();
    _offerResendTimer?.cancel();
    _answerResendTimer?.cancel();
    _readyResendTimer?.cancel();
    _signalingStateCompleter?.complete();
    _signalingStateCompleter = null;
    _requestedVideoAtStart = false;
    _autoVideoUpgradeStarted = false;
    _iceRestartAttempts = 0;
    _nextSeq = 0;
    _lastProcessedSeq = -1;
    _syncRequested = false;
    _isCallerRole = false;
    _lastLocalOffer = null;
    _lastLocalAnswer = null;
    _recentLocalCandidates.clear();
  }

  // ─── Signaling via Broadcast ─────────────────────────────────────────────
  Future<void> _listenForSignals(String roomId) async {
    if (_listening) return;
    _listening = true;

    try {
      await _signalChannel?.unsubscribe();
    } catch (e, st) {
      _logIgnoredError(e, st);
    }

    // قناة واحدة مشتركة للطرفين + ack/self=false لتقليل فقدان/تكرار الإشارات.
    _signalChannel = _client.channel(
      'call_signals_$roomId',
      opts: const RealtimeChannelConfig(
        ack: true,
        self: false,
      ),
    );

    _signalChannel!
        .onBroadcast(
          event: 'signal',
          callback: (payload) async {
            final raw = payload['payload'];
            final data = raw is Map
                ? Map<String, dynamic>.from(raw as Map)
                : Map<String, dynamic>.from(payload);
            await _handleSignalRow(data);
          },
        )
        .subscribe((status, error) async {
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (!_syncRequested && !_ending && _peerConnection != null) {
              _syncRequested = true;
              await _sendSignal('sync_request', {
                'caller': _isCallerRole,
                'ready': !_isCallerRole,
                'needOffer': !_isCallerRole && !_offerHandled,
                'needAnswer': _isCallerRole && !_answerHandled,
              });
              Future.delayed(const Duration(seconds: 3), () => _syncRequested = false);
            }
          } else if (status == RealtimeSubscribeStatus.channelError) {
            Future.delayed(const Duration(seconds: 2), () {
              if (!_ending && _currentRoomId != null) {
                _listening = false;
                _listenForSignals(_currentRoomId!);
              }
            });
          }
        });

    await Future<void>.delayed(const Duration(milliseconds: 180));
  }

  // ─── E2EE Signaling ───────────────────────────────────────────────────────
  Future<void> _prepareCallSignalE2ee() async {
    final me = SecureCryptoService.displayUsername(_localUsername ?? '');
    final peer = SecureCryptoService.displayUsername(_peerUsername ?? '');
    _callSignalingE2eeReady = false;
    if (me == '@user' || peer == '@user' || me == peer) return;
    try {
      await SecureCryptoService.ensureCurrentUserPublicKey(me);
      _callSignalingE2eeReady =
          await SecureCryptoService.hasPublicKeyForUsername(peer);
    } catch (e, st) {
      _logIgnoredError(e, st);
      _callSignalingE2eeReady = false;
    }
  }

  Future<Map<String, dynamic>?> _encryptSignalForPeer(
      String type, Map<String, dynamic> data) async {
    final roomId = _currentRoomId;
    final me = SecureCryptoService.displayUsername(_localUsername ?? '');
    final peer = SecureCryptoService.displayUsername(_peerUsername ?? '');
    if (roomId == null ||
        !_callSignalingE2eeReady ||
        me == '@user' ||
        peer == '@user' ||
        me == peer) return null;
    try {
      return await SecureCryptoService.encryptCallSignalPayload(
        sender: me,
        receiver: peer,
        roomId: roomId,
        signalType: type,
        payload: data,
      );
    } catch (e, st) {
      _logIgnoredError(e, st);
      _callSignalingE2eeReady = false;
      return null;
    }
  }

  Future<Map<String, dynamic>> _decryptSignalEnvelope(
      String type, dynamic payload) async {
    if (payload is Map &&
        SecureCryptoService.isEncryptedCallSignalPayload(payload)) {
      final me = SecureCryptoService.displayUsername(_localUsername ?? '');
      final decrypted = await SecureCryptoService.decryptCallSignalPayload(
        currentUsername: me,
        envelope: Map<String, dynamic>.from(payload as Map),
      );
      return <String, dynamic>{
        'type': (decrypted['type'] ?? '').toString(),
        'data': decrypted['payload'] is Map
            ? Map<String, dynamic>.from(decrypted['payload'] as Map)
            : <String, dynamic>{},
      };
    }
    return <String, dynamic>{
      'type': type,
      'data': payload is Map
          ? Map<String, dynamic>.from(payload as Map)
          : <String, dynamic>{},
    };
  }

  Future<void> _sendSignal(String type, dynamic data) async {
    final roomId = _currentRoomId;
    final channel = _signalChannel;
    if (roomId == null || _ending || channel == null) return;

    final rawData = data is Map
        ? Map<String, dynamic>.from(data as Map)
        : <String, dynamic>{'value': data};
    final encryptedPayload = await _encryptSignalForPeer(type, rawData);

    final signalUuid = _uuid.v4();
    final seq = _nextSeq++;
    final payload = <String, dynamic>{
      'type': encryptedPayload == null ? type : 'encrypted_signal',
      'data': encryptedPayload ?? rawData,
      'signal_uuid': signalUuid,
      'seq': seq,
      'from_instance': _instanceId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    for (var attempt = 0; attempt < 3; attempt++) {
      if (_ending || _currentRoomId == null || _signalChannel == null) return;
      try {
        await _signalChannel!.sendBroadcastMessage(event: 'signal', payload: payload);
        return;
      } catch (e, st) {
        _logIgnoredError(e, st);
        await Future<void>.delayed(Duration(milliseconds: 300 + (attempt * 350)));
      }
    }

    if (!_ending) {
      _safeError('فشل إرسال إشارة المكالمة بسبب ضعف الاتصال. نحاول إعادة التوصيل...');
      onCallPhaseChanged?.call('reconnecting');
    }
  }

  Future<void> _handleSignalRow(Map<String, dynamic> payload) async {
    if (_ending) return;

    final signalId = (payload['signal_uuid'] ?? '').toString();
    if (signalId.isNotEmpty && _handledSignals.contains(signalId)) return;
    if (signalId.isNotEmpty) _handledSignals.add(signalId);

    // لا نعتمد على ترتيب seq لأن الشبكات الضعيفة قد توصل الرسائل بترتيب مختلف.
    final seq = (payload['seq'] as int?) ?? -1;
    if (seq > _lastProcessedSeq) _lastProcessedSeq = seq;

    if (_peerConnection == null) {
      _earlySignals.add(payload);
      return;
    }

    final rawType = payload['type']?.toString() ?? '';
    final rawData = payload['data'];
    try {
      final decoded = await _decryptSignalEnvelope(rawType, rawData);
      final type = (decoded['type'] ?? rawType).toString();
      final data = decoded['data'] is Map
          ? Map<String, dynamic>.from(decoded['data'] as Map)
          : <String, dynamic>{};
      await _handleSignal(type, data);
    } catch (e, st) {
      _logIgnoredError(e, st);
    }
  }

  Future<void> _drainEarlySignals() async {
    if (_earlySignals.isEmpty) return;
    final copy = List<Map<String, dynamic>>.from(_earlySignals);
    _earlySignals.clear();
    for (final payload in copy) {
      final rawType = payload['type']?.toString() ?? '';
      final rawData = payload['data'];
      try {
        final decoded = await _decryptSignalEnvelope(rawType, rawData);
        final type = (decoded['type'] ?? rawType).toString();
        final data = decoded['data'] is Map
            ? Map<String, dynamic>.from(decoded['data'] as Map)
            : <String, dynamic>{};
        await _handleSignal(type, data);
      } catch (e, st) {
        _logIgnoredError(e, st);
      }
    }
  }

  // ─── SDP ──────────────────────────────────────────────────────────────────
  Future<void> _createAndSendOffer(bool video,
      {required String signalType}) async {
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
      _lastLocalOffer = offer;

      await _sendSignal(signalType, {
        'sdp': offer.sdp,
        'type': offer.type,
        'video': video,
        'requestedVideo': _requestedVideoAtStart || video,
        'localVideoEnabled': _localVideoEnabled,
      });
    } finally {
      _makingOffer = false;
    }
  }

  Future<void> _processOffer(Map<String, dynamic> data,
      {required bool renegotiate}) async {
    final pc = _peerConnection;
    if (pc == null || _ending) return;
    if (!renegotiate && _offerHandled) return;

    final sdp = data['sdp']?.toString();
    final descType = data['type']?.toString();
    if (sdp == null ||
        sdp.trim().isEmpty ||
        descType == null ||
        descType.trim().isEmpty) return;

    final stable = await _waitForSignalingStateCompleter(
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
      scheduleMicrotask(() => unawaited(_flushPendingCandidates()));

      final answer = await pc.createAnswer(<String, dynamic>{
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      await pc.setLocalDescription(answer);
      _localDescriptionSet = true;
      _lastLocalAnswer = answer;
      _readyResendTimer?.cancel();

      await _sendSignal(renegotiate ? 'renegotiate_answer' : 'answer', {
        'sdp': answer.sdp,
        'type': answer.type,
        'localVideoEnabled': _localVideoEnabled,
      });
      _startAnswerResendLoop();
      await _resendLocalCandidates();
    } catch (e) {
      _safeError('خطأ في معالجة عرض المكالمة: $e');
      _finishCall(notify: true);
    }
  }

  Future<void> _processAnswer(Map<String, dynamic> data,
      {required bool renegotiate}) async {
    final pc = _peerConnection;
    if (pc == null || _ending) return;
    if (!renegotiate && (_answerHandled || _remoteDescriptionSet)) return;

    final sdp = data['sdp']?.toString();
    final descType = data['type']?.toString();
    if (sdp == null ||
        sdp.trim().isEmpty ||
        descType == null ||
        descType.trim().isEmpty) return;

    final ready = await _waitForSignalingStateCompleter(
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
      _offerResendTimer?.cancel();
      await pc.setRemoteDescription(RTCSessionDescription(sdp, descType));
      _remoteDescriptionSet = true;
      scheduleMicrotask(() => unawaited(_flushPendingCandidates()));
      await _resendLocalCandidates();
    } catch (e) {
      _safeError('خطأ في معالجة رد المكالمة: $e');
      _finishCall(notify: true);
    }
  }


  Future<void> _sendLastLocalDescription({required String preferredType}) async {
    if (_ending || _peerConnection == null || !_localDescriptionSet) return;

    final desc = preferredType.contains('answer')
        ? (_lastLocalAnswer ?? await _peerConnection?.getLocalDescription())
        : (_lastLocalOffer ?? await _peerConnection?.getLocalDescription());

    if (desc == null || (desc.sdp ?? '').trim().isEmpty || (desc.type ?? '').trim().isEmpty) {
      return;
    }

    final isAnswer = (desc.type ?? '').toLowerCase() == 'answer' || preferredType.contains('answer');
    await _sendSignal(isAnswer ? 'answer' : 'offer', {
      'sdp': desc.sdp,
      'type': desc.type,
      'video': _requestedVideoAtStart,
      'requestedVideo': _requestedVideoAtStart,
      'localVideoEnabled': _localVideoEnabled,
      'resend': true,
    });
  }

  void _startOfferResendLoop() {
    _offerResendTimer?.cancel();
    var ticks = 0;
    _offerResendTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_ending || _isCallActive || _answerHandled || !_isCallerRole || ticks >= 12) {
        timer.cancel();
        return;
      }
      ticks++;
      await _sendLastLocalDescription(preferredType: 'offer');
      await _resendLocalCandidates();
    });
  }

  void _startAnswerResendLoop() {
    _answerResendTimer?.cancel();
    var ticks = 0;
    _answerResendTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_ending || _isCallActive || _isCallerRole || ticks >= 10) {
        timer.cancel();
        return;
      }
      ticks++;
      await _sendLastLocalDescription(preferredType: 'answer');
      await _resendLocalCandidates();
    });
  }

  void _startReadyResendLoop() {
    _readyResendTimer?.cancel();
    var ticks = 0;
    _readyResendTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_ending || _isCallActive || _offerHandled || _isCallerRole || ticks >= 14) {
        timer.cancel();
        return;
      }
      ticks++;
      await _sendSignal('receiver_ready', {
        'video': _requestedVideoAtStart,
        'ready': true,
        'resend': true,
      });
    });
  }

  Future<void> _resendLocalCandidates() async {
    if (_ending || _recentLocalCandidates.isEmpty) return;
    final copy = List<Map<String, dynamic>>.from(_recentLocalCandidates);
    for (final candidate in copy) {
      if (_ending) return;
      await _sendSignal('candidate', candidate);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  Future<void> _handleSignal(String? type, Map<String, dynamic> data) async {
    if (type == null || _ending) return;

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
      case 'receiver_ready':
        onCallPhaseChanged?.call('answered_waiting_media');
        if (_isCallerRole) {
          await _sendLastLocalDescription(preferredType: 'offer');
          await Future<void>.delayed(const Duration(milliseconds: 350));
          await _sendLastLocalDescription(preferredType: 'offer');
          await _resendLocalCandidates();
          _startOfferResendLoop();
        }
        break;
      case 'sync_request':
        if (_isCallerRole) {
          await _sendLastLocalDescription(preferredType: 'offer');
        } else if (_lastLocalAnswer != null || _answerHandled || _localDescriptionSet) {
          await _sendLastLocalDescription(preferredType: 'answer');
        } else {
          await _sendSignal('receiver_ready', {
            'video': _requestedVideoAtStart,
            'ready': true,
            'sync': true,
          });
        }
        await _resendLocalCandidates();
        break;
      case 'end':
      case 'reject':
      case 'cancel':
        _finishCall(
          notify: true,
          reason: type == 'reject'
              ? 'rejected'
              : (type == 'cancel' ? 'cancelled' : 'ended'),
        );
        break;
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
      data['sdpMLineIndex'] is int
          ? data['sdpMLineIndex'] as int
          : int.tryParse('${data['sdpMLineIndex']}'),
    );

    if (_remoteDescriptionSet) {
      try {
        await pc.addCandidate(candidate);
      } catch (e, st) {
        _logIgnoredError(e, st);
      }
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
      } catch (e, st) {
        _logIgnoredError(e, st);
      }
    }
  }

  // ─── Signaling state wait (no leak) ─────────────────────────────────────
  Future<bool> _waitForSignalingStateCompleter({
    required Set<RTCSignalingState> allowed,
    required bool allowNullAsReady,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (!_ending && _peerConnection != null) {
      final state = _peerConnection?.signalingState;
      if (state == null && allowNullAsReady) return true;
      if (state != null && allowed.contains(state)) return true;
      if (DateTime.now().isAfter(deadline)) return false;

      final completer = Completer<void>();
      void listener(RTCSignalingState newState) {
        if (!completer.isCompleted) completer.complete();
      }
      _peerConnection?.onSignalingState = listener;

      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) return false;

      try {
        await completer.future.timeout(
          remaining > const Duration(milliseconds: 120) ? remaining : const Duration(milliseconds: 120),
        );
      } catch (_) {}
      _peerConnection?.onSignalingState = null;
    }
    return false;
  }

  // ─── Connected / Health ──────────────────────────────────────────────────
  bool _isTransportConnected() {
    final pc = _peerConnection;
    if (pc == null) return false;
    final ice = pc.iceConnectionState;
    final conn = pc.connectionState;
    return ice == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        ice == RTCIceConnectionState.RTCIceConnectionStateCompleted ||
        conn == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
  }

  void _deliverRemoteStreamIfReady({bool forceRefresh = false}) {
    if (_ending) return;
    final stream = _remoteStream;
    if (stream == null) return;
    if (_remoteStreamDelivered && !forceRefresh) return;
    _remoteStreamDelivered = true;
    onRemoteStream?.call(stream);
  }

  void _markConnected() {
    if (_ending) return;
    final firstConnect = !_isCallActive;
    _isCallActive = true;
    onCallPhaseChanged?.call('connected');
    _deliverRemoteStreamIfReady();
    _connectTimeout?.cancel();
    _deferredCloseTimer?.cancel();
    _softIceRestartTimer?.cancel();
    _offerResendTimer?.cancel();
    _answerResendTimer?.cancel();
    _readyResendTimer?.cancel();

    if (firstConnect) {
      _iceRestartAttempts = 0;
      _scheduleAutoVideoUpgrade();
    }
  }

  void _scheduleAutoVideoUpgrade() {
    if (!_requestedVideoAtStart ||
        _autoVideoUpgradeStarted ||
        _localVideoEnabled ||
        _ending) return;
    _autoVideoUpgradeStarted = true;
    onCallPhaseChanged?.call('starting_video');
    unawaited(Future<void>.delayed(const Duration(milliseconds: 900), () async {
      if (_ending || !_isCallActive || _localVideoEnabled) return;
      await setVideoEnabled(true);
    }));
  }

  void _startConnectTimeout() {
    _connectTimeout?.cancel();
    _softIceRestartTimer?.cancel();

    _softIceRestartTimer = Timer(const Duration(seconds: 10), () {
      if (!_isCallActive && !_ending) {
        unawaited(_tryRestartIceOrEnd(softOnly: true));
        unawaited(_sendSignal('sync_request', {
          'weakNetworkRetry': true,
          'caller': _isCallerRole,
        }));
      }
    });

    _connectTimeout = Timer(const Duration(seconds: 75), () {
      if (!_isCallActive && !_ending) {
        _safeError('تعذر توصيل المكالمة بسبب ضعف الاتصال. تأكد من الإنترنت أو جرّب مرة ثانية.');
        _finishCall(notify: true, reason: 'missed');
      }
    });
  }

  void _startHealthWatch() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      if (_ending) return;
      final pc = _peerConnection;
      if (pc == null) return;
      if (_isTransportConnected()) {
        _markConnected();
      }
    });
  }

  void _scheduleDeferredClose() {
    _deferredCloseTimer?.cancel();
    _deferredCloseTimer = Timer(const Duration(seconds: 18), () {
      if (!_ending && !_isCallActive) {
        unawaited(_sendSignal('sync_request', {
          'deferredCloseCheck': true,
          'caller': _isCallerRole,
        }));
        unawaited(_tryRestartIceOrEnd(softOnly: true));
      }
    });
  }

  void _scheduleSoftIceRestart() {
    if (_ending || _isCallActive) return;
    _softIceRestartTimer?.cancel();
    _softIceRestartTimer = Timer(const Duration(seconds: 4), () {
      if (!_isCallActive && !_ending) {
        unawaited(_tryRestartIceOrEnd(softOnly: true));
      }
    });
  }

  Future<void> _tryRestartIceOrEnd({bool softOnly = false}) async {
    final pc = _peerConnection;
    if (pc == null || _ending || _isCallActive) return;

    if (_iceRestartAttempts >= 6) {
      if (!softOnly) _finishCall(notify: true, reason: 'disconnected');
      return;
    }

    _iceRestartAttempts++;
    onCallPhaseChanged?.call('reconnecting');

    try {
      await _sendSignal('sync_request', {
        'iceRestartAttempt': _iceRestartAttempts,
        'caller': _isCallerRole,
      });

      await pc.restartIce();

      if (_localDescriptionSet) {
        if (_isCallerRole) {
          await _sendLastLocalDescription(preferredType: 'offer');
        } else if (_lastLocalAnswer != null) {
          await _sendLastLocalDescription(preferredType: 'answer');
        }
      }

      if (_localDescriptionSet && _remoteDescriptionSet) {
        await _createAndSendOffer(_requestedVideoAtStart,
            signalType: 'renegotiate_offer');
      }

      await _resendLocalCandidates();

      await Future<void>.delayed(const Duration(seconds: 7));
      if (!_isCallActive && !_ending && !softOnly && _iceRestartAttempts >= 6) {
        _finishCall(notify: true, reason: 'disconnected');
      }
    } catch (e, st) {
      _logIgnoredError(e, st);
      if (!softOnly && _iceRestartAttempts >= 6) {
        _finishCall(notify: true, reason: 'disconnected');
      }
    }
  }

  // ─── Video / Audio controls ───────────────────────────────────────────────
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

    final currentVideoTracks =
        _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
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
      final videoStream = await navigator.mediaDevices.getUserMedia(
          <String, dynamic>{'audio': false, 'video': _videoConstraints()});

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

      await _createAndSendOffer(true, signalType: 'renegotiate_offer');
      await _sendSignal('camera_state', {'enabled': true});
      return true;
    } catch (e) {
      _safeError('تعذر تشغيل الفيديو أثناء المكالمة: $e');
      return false;
    }
  }

  // ─── Screen share ─────────────────────────────────────────────────────────
  Future<bool> startScreenShare() async {
    if (_ending || _peerConnection == null || _localStream == null) return false;
    if (_screenSharing) return true;

    MediaStream? displayStream;

    try {
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

      displayStream = await navigator.mediaDevices
          .getDisplayMedia(<String, dynamic>{'video': true, 'audio': false});

      final tracks = displayStream.getVideoTracks();
      if (tracks.isEmpty) {
        try {
          await displayStream.dispose();
        } catch (e, st) {
          _logIgnoredError(e, st);
        }
        _safeError('تعذر الحصول على مسار مشاركة الشاشة');
        return false;
      }

      _screenStream = displayStream;
      _screenVideoTrack = tracks.first;
      _screenVideoTrack?.onEnded = () {
        if (_screenSharing && !_ending) {
          unawaited(stopScreenShare());
        }
      };

      final localVideoTracks =
          _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
      _cameraVideoTrack ??=
          localVideoTracks.isNotEmpty ? localVideoTracks.first : null;

      final sender = await _videoSender();
      if (sender != null) {
        await sender.replaceTrack(_screenVideoTrack);
      } else {
        final pc = _peerConnection;
        final screenVideoTrack = _screenVideoTrack;
        final screenStream = _screenStream;
        if (pc == null || screenVideoTrack == null || screenStream == null) {
          return false;
        }
        await pc.addTrack(screenVideoTrack, screenStream);
        await _createAndSendOffer(true, signalType: 'renegotiate_offer');
      }

      _screenSharing = true;
      onCallPhaseChanged?.call('screen_share_on');
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
      } catch (e, st) {
        _logIgnoredError(e, st);
      }
      _screenStream = null;
      _screenVideoTrack = null;
      _screenSharing = false;
      onCallPhaseChanged?.call('screen_share_off');
      onScreenShareChanged?.call(false);
      _safeError(
          'تعذر تشغيل مشاركة الشاشة. إذا كان جهازك Android 14 أو أعلى تأكد من إضافة صلاحيات MediaProjection في AndroidManifest: $e');
      return false;
    }
  }

  Future<bool> stopScreenShare() async {
    if (!_screenSharing) return true;

    try {
      final sender = await _videoSender();
      final cameraTrack = _cameraVideoTrack ??
          (_localStream?.getVideoTracks().isNotEmpty == true
              ? _localStream?.getVideoTracks().first
              : null);

      if (sender != null && cameraTrack != null) {
        await sender.replaceTrack(cameraTrack);
      } else if (sender != null && cameraTrack == null) {
        try {
          await sender.replaceTrack(null);
        } catch (e, st) {
          _logIgnoredError(e, st);
        }
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
      onCallPhaseChanged?.call('screen_share_off');
      onScreenShareChanged?.call(false);
      await _sendSignal('screen_share_state', {'enabled': false});
      if (cameraTrack == null) {
        await _createAndSendOffer(false, signalType: 'renegotiate_offer');
      }
      return true;
    } catch (e) {
      _safeError('تعذر إيقاف مشاركة الشاشة: $e');
      return false;
    }
  }

  Future<bool> toggleScreenShare() async =>
      _screenSharing ? stopScreenShare() : startScreenShare();

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

  // ─── Misc controls ────────────────────────────────────────────────────────
  void toggleSpeaker(bool enable) => Helper.setSpeakerphoneOn(enable);

  void switchCamera() {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isNotEmpty) Helper.switchCamera(tracks.first);
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

  // ─── End call ─────────────────────────────────────────────────────────────
  Future<void> endCall({String reason = 'ended'}) async {
    if (_ending) return;
    final signalType = reason == 'rejected'
        ? 'reject'
        : (reason == 'cancelled' ? 'cancel' : 'end');
    await _sendSignal(signalType, {
      'ended': true,
      'reason': reason,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
    });
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!_ending) {
      await _sendSignal(signalType, {
        'ended': true,
        'reason': reason,
        'retry': true,
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      });
    }
    _finishCall(notify: true, reason: reason);
  }

  void _finishCall({required bool notify, String reason = 'ended'}) {
    if (_ending &&
        _peerConnection == null &&
        _localStream == null &&
        _remoteStream == null) return;
    final finishedRoomId = _currentRoomId;

    _lastEndReason = reason;
    _ending = true;
    _isCallActive = false;
    _connectTimeout?.cancel();
    _healthTimer?.cancel();
    _deferredCloseTimer?.cancel();
    _softIceRestartTimer?.cancel();
    _offerResendTimer?.cancel();
    _answerResendTimer?.cancel();
    _readyResendTimer?.cancel();
    _signalingStateCompleter?.complete();
    _signalingStateCompleter = null;

    try {
      _signalChannel?.unsubscribe();
    } catch (e, st) {
      _logIgnoredError(e, st);
    }

    try {
      for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
        track.stop();
      }
    } catch (e, st) {
      _logIgnoredError(e, st);
    }

    try {
      for (final track in _screenStream?.getTracks() ?? <MediaStreamTrack>[]) {
        track.stop();
      }
      _screenStream?.dispose();
    } catch (e, st) {
      _logIgnoredError(e, st);
    }

    try {
      _localStream?.dispose();
    } catch (e, st) {
      _logIgnoredError(e, st);
    }

    try {
      _remoteStream?.dispose();
    } catch (e, st) {
      _logIgnoredError(e, st);
    }

    try {
      _peerConnection?.close();
    } catch (e, st) {
      _logIgnoredError(e, st);
    }

    _localStream = null;
    _remoteStream = null;
    _peerConnection = null;
    _signalChannel = null;
    _currentRoomId = null;
    _localUsername = null;
    _peerUsername = null;
    _callSignalingE2eeReady = false;
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
    _recentLocalCandidates.clear();
    _lastLocalOffer = null;
    _lastLocalAnswer = null;
    _isCallerRole = false;
    // لا حاجة لحذف الإشارات من قاعدة البيانات لأننا لم نخزنها
    // لذلك أزلنا _deleteSignalsForRoom تماماً

    if (notify && !_isDisposed) {
      Future<void>.microtask(() {
        if (!_isDisposed) onCallEnded?.call(_lastEndReason);
      });
    }
  }

  void dispose() {
    _isDisposed = true;
    _finishCall(notify: false, reason: 'disposed');
    onLocalStream = null;
    onRemoteStream = null;
    onError = null;
    onCallEnded = null;
    onCallPhaseChanged = null;
    onLocalVideoChanged = null;
    onMicrophoneMuteChanged = null;
    onScreenShareChanged = null;
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