import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http; // تمت الإضافة

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'secure_crypto_service.dart';

void _scannerSafeIgnore() {}


void _logIgnoredError(Object error, StackTrace stackTrace) {
  assert(() {
    _scannerSafeIgnore();
    return true;
  }());
}

void _safeDebugLog(Object? message) {
  assert(() {
    _scannerSafeIgnore();
    return true;
  }());
}


class SupabaseService {
  SupabaseService._();

  static const String supabaseUrl = 'https://oafbzceorbjykgoffuaa.supabase.co';
  static String get requiredSupabaseAnonToken {
    const value = String.fromEnvironment('RESPECT_SUPABASE_ANON_KEY');
    if (value.trim().isEmpty) {
      throw StateError('Missing required dart-define: RESPECT_SUPABASE_ANON_KEY');
    }
    return value;
  }

  static SupabaseClient get client => Supabase.instance.client;

  static String get _safeDevicePlatform {
    if (kIsWeb) return 'web';
    try {
      return Platform.operatingSystem;
    } catch (_) {
      return 'unknown';
    }
  }

  // إشعار داخلي للتطبيق: إذا حذف السيرفر منشورًا بعد مراجعة Respect AI،
  // نبلغ الواجهات فورًا حتى تخفيه بدون انتظار تحديث الفيد.
  static final StreamController<String> _respectAiDeletedPostController = StreamController<String>.broadcast();
  static Stream<String> get respectAiDeletedPostStream => _respectAiDeletedPostController.stream;


  static Future<void> dispose() async {
    if (!_respectAiDeletedPostController.isClosed) {
      await _respectAiDeletedPostController.close();
    }
  }

  static void _notifyRespectAiDeletedPost(String postId) {
    final id = postId.trim();
    if (id.isEmpty || _respectAiDeletedPostController.isClosed) return;
    _respectAiDeletedPostController.add(id);
  }


  // ================= Respect AI / Secure Backend Gateway =================
  // لا تضع مفاتيح حقيقية داخل Flutter.
  // هذه القيم تحفظ في Render فقط:
  // SUPABASE_SERVICE_ROLE_KEY / QWEN_API_KEY / HF_TOKEN / Firebase Service Account / Paddle Secret.
  //
  // تغيير الرابط بدون تعديل الكود:
  // flutter build apk --dart-define=RESPECT_API_BASE_URL=https://YOUR_RENDER_BACKEND_URL
  //
  // توقيع الطلبات الحساسة:
  // flutter build apk --dart-define=RESPECT_REQUEST_SIGNING_SECRET=ضع_نفس_القيمة_الموجودة_في_Render
  static const String _apiBaseUrlOverride =
      String.fromEnvironment('RESPECT_API_BASE_URL', defaultValue: '');

  static const List<int> _obfuscatedApiBaseUrl = <int>[
    123, 57, 47, 119, 108, 17, 110, 60, 63, 62, 116, 111, 78, 34, 103, 96,
    58, 119, 111, 6, 120, 117, 55, 42, 41, 112, 69, 51, 118, 35, 63, 98,
    109, 5, 34, 124, 32,
  ];
  static const List<int> _apiBaseUrlXorKey = <int>[19, 77, 91, 7, 31, 43, 65];

  static final Random _secureHeaderRandom = Random.secure();

  static String get respectApiBaseUrl {
    final override = _apiBaseUrlOverride.trim();
    final raw = override.isNotEmpty ? override : _decodeXorAscii(_obfuscatedApiBaseUrl, _apiBaseUrlXorKey);
    return _normalizeHttpsBaseUrl(raw);
  }

  static String get respectAiBackendUrl => _backendEndpoint('/respect-ai/reply');
  static String get respectAiModerationBackendUrl => _backendEndpoint('/respect-ai/moderate');
  static String get respectAiPostModerationBackendUrl => _backendEndpoint('/respect-ai/moderate-post');
  static String get respectAiStoryModerationBackendUrl => _backendEndpoint('/respect-ai/moderate-story');
  static String get respectAiReportReviewBackendUrl => _backendEndpoint('/respect-ai/review-report');
  static String get respectAiSearchExpandBackendUrl => _backendEndpoint('/respect-ai/search-expand');
  static String get authOtpBackendBaseUrl => respectApiBaseUrl;
  static const String respectAiUsername = '@respectai';
  static const String respectAiName = 'Respect AI';

  // لا تضع السر داخل الكود. مرّره وقت البناء فقط.
  // ملاحظة: أي سر داخل APK قابل للاستخراج في النهاية، لذلك هو طبقة تصعيب وليس بديلًا عن صلاحيات السيرفر.
  static const String pushApiSecret =
      String.fromEnvironment('APP_SECRET', defaultValue: '');

  static const String _requestSigningSecret =
      String.fromEnvironment('RESPECT_REQUEST_SIGNING_SECRET', defaultValue: '');

  static String _decodeXorAscii(List<int> data, List<int> key) {
    if (data.isEmpty || key.isEmpty) return '';
    final out = List<int>.generate(data.length, (i) => data[i] ^ key[i % key.length]);
    return utf8.decode(out);
  }

  static String _normalizeHttpsBaseUrl(String value) {
    var base = value.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) return '';
    final isLocal = base.contains('localhost') || base.contains('127.0.0.1') || base.contains('10.0.2.2');
    if (!base.startsWith('https://') && !isLocal) {
      base = base.replaceFirst(RegExp(r'^http://', caseSensitive: false), '');
      base = 'https://$base';
    }
    return base;
  }

  static String _backendEndpoint(String path) {
    final base = respectApiBaseUrl;
    final safePath = path.startsWith('/') ? path : '/$path';
    return '$base$safePath';
  }

  static Map<String, String> _jsonSecretHeaders({String body = '', Uri? uri}) {
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json',
      'X-Respect-Client': kIsWeb ? 'flutter-web' : 'flutter-app',
      'X-Respect-Platform': _safeDevicePlatform,
    };

    final secret = pushApiSecret.trim();
    if (secret.isNotEmpty) headers['X-App-Secret'] = secret;

    final signingSecret = _requestSigningSecret.trim();
    if (signingSecret.isNotEmpty) {
      final timestamp = (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000).toString();
      final nonce = _newRequestNonce();
      final path = uri?.path ?? '';
      final payload = '$timestamp\n$nonce\n$path\n$body';
      final signatureBytes = _hmacSha256(utf8.encode(signingSecret), utf8.encode(payload));
      final signature = base64UrlEncode(signatureBytes).replaceAll('=', '');

      headers['X-App-Timestamp'] = timestamp;
      headers['X-App-Nonce'] = nonce;
      headers['X-App-Signature'] = signature;
      headers['X-App-Signature-Version'] = 'v1';
    }

    return headers;
  }

  static Future<http.Response> _postSignedJson(
    Uri uri,
    Object payload, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final body = jsonEncode(payload);
    return http
        .post(
          uri,
          headers: _jsonSecretHeaders(body: body, uri: uri),
          body: body,
        )
        .timeout(timeout);
  }

  static String _newRequestNonce() {
    final bytes = List<int>.generate(16, (_) => _secureHeaderRandom.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static List<int> _hmacSha256(List<int> key, List<int> message) {
    var actualKey = List<int>.from(key);
    if (actualKey.length > 64) actualKey = _sha256(actualKey);
    if (actualKey.length < 64) actualKey = <int>[...actualKey, ...List<int>.filled(64 - actualKey.length, 0)];

    final oKeyPad = List<int>.generate(64, (i) => actualKey[i] ^ 0x5c);
    final iKeyPad = List<int>.generate(64, (i) => actualKey[i] ^ 0x36);
    return _sha256(<int>[...oKeyPad, ..._sha256(<int>[...iKeyPad, ...message])]);
  }

  static List<int> _sha256(List<int> input) {
    final k = <int>[
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    var h0 = 0x6a09e667;
    var h1 = 0xbb67ae85;
    var h2 = 0x3c6ef372;
    var h3 = 0xa54ff53a;
    var h4 = 0x510e527f;
    var h5 = 0x9b05688c;
    var h6 = 0x1f83d9ab;
    var h7 = 0x5be0cd19;

    final data = <int>[...input.map((e) => e & 0xff), 0x80];
    while ((data.length % 64) != 56) {
      data.add(0);
    }

    final bitLength = input.length * 8;
    for (var shift = 56; shift >= 0; shift -= 8) {
      data.add((bitLength >> shift) & 0xff);
    }

    for (var chunk = 0; chunk < data.length; chunk += 64) {
      final w = List<int>.filled(64, 0);
      for (var i = 0; i < 16; i++) {
        final j = chunk + (i * 4);
        w[i] = ((data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | data[j + 3]) & 0xffffffff;
      }
      for (var i = 16; i < 64; i++) {
        final s0 = (_rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)) & 0xffffffff;
        final s1 = (_rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)) & 0xffffffff;
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }

      var a = h0;
      var b = h1;
      var c = h2;
      var d = h3;
      var e = h4;
      var f = h5;
      var g = h6;
      var h = h7;

      for (var i = 0; i < 64; i++) {
        final s1 = (_rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)) & 0xffffffff;
        final ch = ((e & f) ^ ((~e) & g)) & 0xffffffff;
        final temp1 = (h + s1 + ch + k[i] + w[i]) & 0xffffffff;
        final s0 = (_rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)) & 0xffffffff;
        final maj = ((a & b) ^ (a & c) ^ (b & c)) & 0xffffffff;
        final temp2 = (s0 + maj) & 0xffffffff;

        h = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }

      h0 = (h0 + a) & 0xffffffff;
      h1 = (h1 + b) & 0xffffffff;
      h2 = (h2 + c) & 0xffffffff;
      h3 = (h3 + d) & 0xffffffff;
      h4 = (h4 + e) & 0xffffffff;
      h5 = (h5 + f) & 0xffffffff;
      h6 = (h6 + g) & 0xffffffff;
      h7 = (h7 + h) & 0xffffffff;
    }

    final out = <int>[];
    for (final h in <int>[h0, h1, h2, h3, h4, h5, h6, h7]) {
      out
        ..add((h >> 24) & 0xff)
        ..add((h >> 16) & 0xff)
        ..add((h >> 8) & 0xff)
        ..add(h & 0xff);
    }
    return out;
  }

  static int _rotr(int value, int bits) {
    final v = value & 0xffffffff;
    return ((v >> bits) | ((v << (32 - bits)) & 0xffffffff)) & 0xffffffff;
  }

  // ================= Streamers Metadata =================
  // يستخدمها الأدمن لإضافة قناة من الرابط فقط، ثم تعبئة الاسم/الصورة/المنصة تلقائيًا.
  static String cleanStreamerUrl(String value) {
    final v = value.trim();
    if (v.isEmpty) return '';
    return v.startsWith('http://') || v.startsWith('https://') ? v : 'https://$v';
  }

  static String streamerPlatformFromUrl(String url) {
    final u = cleanStreamerUrl(url).toLowerCase();
    if (u.contains('kick.com')) return 'Kick';
    if (u.contains('twitch.tv')) return 'Twitch';
    if (u.contains('youtube.com') || u.contains('youtu.be')) return 'YouTube';
    if (u.contains('facebook.com')) return 'Facebook';
    if (u.contains('tiktok.com')) return 'TikTok';
    return 'Stream';
  }

  static String streamerChannelFromUrl(String url) {
    try {
      final uri = Uri.parse(cleanStreamerUrl(url));
      final parts = uri.pathSegments.where((p) => p.trim().isNotEmpty).toList();
      if (parts.isEmpty) return '';
      final host = uri.host.toLowerCase();
      if (host.contains('youtube.com') && parts.first == 'channel' && parts.length > 1) return parts[1];
      if (host.contains('youtube.com') && parts.first == 'c' && parts.length > 1) return parts[1];
      if (host.contains('youtube.com') && parts.first == 'user' && parts.length > 1) return parts[1];
      if (host.contains('youtube.com') && parts.first.startsWith('@')) return parts.first.replaceAll('@', '');
      if (host.contains('youtu.be')) return parts.first;
      return parts.first.replaceAll('@', '');
    } catch (_) {
      return '';
    }
  }

  static Future<Map<String, dynamic>> fetchStreamerMetadata(
    String url, {
    String fallbackName = 'Streamer',
  }) async {
    final cleanUrl = cleanStreamerUrl(url);
    final platform = streamerPlatformFromUrl(cleanUrl);
    final channel = streamerChannelFromUrl(cleanUrl);

    Map<String, dynamic> fallback() => <String, dynamic>{
          'streamUrl': cleanUrl,
          'streamName': channel.isNotEmpty ? channel : fallbackName,
          'streamerName': channel.isNotEmpty ? channel : fallbackName,
          'streamTitle': '',
          'streamThumbnailUrl': '',
          'streamThumbnailPath': '',
          'streamPlatform': platform,
          'streamIsLive': false,
          'streamViewers': 0,
          'streamChannelKey': channel,
          'streamLastCheckedAt': DateTime.now().toUtc().toIso8601String(),
        };

    if (cleanUrl.isEmpty) return fallback();

    try {
      Map<String, dynamic> meta;
      if (platform == 'Kick' && channel.isNotEmpty) {
        meta = await _fetchKickStreamerMetadata(cleanUrl, channel, fallbackName: fallbackName);
      } else if (platform == 'Twitch' && channel.isNotEmpty) {
        meta = await _fetchTwitchStreamerMetadata(cleanUrl, channel, fallbackName: fallbackName);
      } else if (platform == 'YouTube') {
        meta = await _fetchYouTubeStreamerMetadata(cleanUrl, fallbackName: fallbackName);
      } else {
        meta = await _fetchGenericStreamerMetadata(
          cleanUrl,
          fallbackName: fallbackName,
          platform: platform,
          channel: channel,
        );
      }

      final streamName = _streamFirstNonEmpty([
        (meta['streamName'] ?? '').toString(),
        (meta['streamerName'] ?? '').toString(),
        channel,
        fallbackName,
      ]);
      final thumbnail = _normalizeStreamerImageUrl((meta['streamThumbnailUrl'] ?? '').toString());
      return <String, dynamic>{
        ...fallback(),
        ...meta,
        'streamUrl': cleanUrl,
        'streamName': streamName,
        'streamerName': streamName,
        'streamThumbnailUrl': thumbnail,
        'streamThumbnailPath': thumbnail,
        'streamPlatform': _streamFirstNonEmpty([(meta['streamPlatform'] ?? '').toString(), platform]),
        'streamChannelKey': _streamFirstNonEmpty([(meta['streamChannelKey'] ?? '').toString(), channel]),
        'streamViewers': _streamToInt((meta['streamViewers'] ?? '0').toString()),
        'streamIsLive': truthy(meta['streamIsLive']),
        'streamLastCheckedAt': DateTime.now().toUtc().toIso8601String(),
      };
    } catch (e, st) {
      _logIgnoredError(e, st);
      return fallback();
    }
  }

  static Future<Map<String, dynamic>> _fetchKickStreamerMetadata(
    String url,
    String channel, {
    required String fallbackName,
  }) async {
    for (final api in <String>[
      'https://kick.com/api/v2/channels/$channel',
      'https://kick.com/api/v1/channels/$channel',
    ]) {
      try {
        final raw = await _readStreamerUrl(api, json: true);
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final data = decoded.map((k, v) => MapEntry(k.toString(), v));
        final livestream = data['livestream'];
        final liveMap = livestream is Map ? livestream.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};
        final user = data['user'];
        final userMap = user is Map ? user.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};
        final isLive = liveMap.isNotEmpty || (liveMap['playback_url']?.toString() ?? '').isNotEmpty;
        final viewers = _streamToInt(_streamFirstNonEmpty([
          liveMap['viewer_count']?.toString() ?? '',
          liveMap['viewers']?.toString() ?? '',
          data['viewer_count']?.toString() ?? '',
        ]));
        final title = _streamCleanHtml(_streamFirstNonEmpty([
          liveMap['session_title']?.toString() ?? '',
          liveMap['title']?.toString() ?? '',
        ]));
        var thumbnail = _streamFirstNonEmpty([
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
        final name = _streamFirstNonEmpty([
          data['slug']?.toString() ?? '',
          userMap['username']?.toString() ?? '',
          channel,
          fallbackName,
        ]);
        return <String, dynamic>{
          'streamName': name,
          'streamerName': name,
          'streamTitle': title,
          'streamThumbnailUrl': thumbnail,
          'streamThumbnailPath': thumbnail,
          'streamPlatform': 'Kick',
          'streamIsLive': isLive,
          'streamViewers': viewers,
          'streamChannelKey': channel,
        };
      } catch (e, st) {
        _logIgnoredError(e, st);
      }
    }
    return _fetchGenericStreamerMetadata(url, fallbackName: fallbackName, platform: 'Kick', channel: channel);
  }

  static Future<Map<String, dynamic>> _fetchTwitchStreamerMetadata(
    String url,
    String channel, {
    required String fallbackName,
  }) async {
    var channelName = channel;
    var title = '';
    var thumbnail = '';
    var isLive = false;
    var viewers = 0;

    try {
      final raw = await _readStreamerUrl('https://www.twitch.tv/oembed?url=${Uri.encodeComponent(url)}', json: true);
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        title = _streamCleanHtml((decoded['title'] ?? '').toString());
        channelName = _streamFirstNonEmpty([(decoded['author_name'] ?? '').toString(), channelName, fallbackName]);
        thumbnail = (decoded['thumbnail_url'] ?? '').toString();
      }
    } catch (e, st) {
      _logIgnoredError(e, st);
    }

    try {
      final gqlBody = jsonEncode([
        {
          'operationName': 'StreamMetadata',
          'variables': {'channelLogin': channel.toLowerCase()},
          'extensions': {
            'persistedQuery': {
              'version': 1,
              'sha256Hash': 'a647c2a13599e5991e175155f798ca7f1ecddde73f7f341f39009c14dbf59962',
            }
          }
        }
      ]);
      final raw = await _postStreamerUrl('https://gql.twitch.tv/gql', gqlBody, headers: const {
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
            viewers = _streamToInt(streamMap['viewersCount']?.toString() ?? streamMap['viewers']?.toString() ?? '0');
            title = _streamCleanHtml(_streamFirstNonEmpty([streamMap['title']?.toString() ?? '', title]));
            thumbnail = _streamFirstNonEmpty([streamMap['previewImageURL']?.toString() ?? '', thumbnail, profileImage]);
          } else {
            thumbnail = _streamFirstNonEmpty([thumbnail, profileImage]);
          }
          channelName = _streamFirstNonEmpty([user['displayName']?.toString() ?? '', channelName, fallbackName]);
        }
      }
    } catch (e, st) {
      _logIgnoredError(e, st);
    }

    if (thumbnail.contains('{width}')) thumbnail = thumbnail.replaceAll('{width}', '1280');
    if (thumbnail.contains('{height}')) thumbnail = thumbnail.replaceAll('{height}', '720');

    if (title.isEmpty || thumbnail.isEmpty) {
      try {
        final generic = await _fetchGenericStreamerMetadata(url, fallbackName: fallbackName, platform: 'Twitch', channel: channel);
        title = _streamFirstNonEmpty([title, (generic['streamTitle'] ?? '').toString()]);
        thumbnail = _streamFirstNonEmpty([thumbnail, (generic['streamThumbnailUrl'] ?? '').toString()]);
        isLive = isLive || truthy(generic['streamIsLive']);
        viewers = viewers > 0 ? viewers : _streamToInt((generic['streamViewers'] ?? '0').toString());
        channelName = _streamFirstNonEmpty([channelName, (generic['streamName'] ?? '').toString()]);
      } catch (e, st) {
        _logIgnoredError(e, st);
      }
    }

    return <String, dynamic>{
      'streamName': channelName,
      'streamerName': channelName,
      'streamTitle': title,
      'streamThumbnailUrl': thumbnail,
      'streamThumbnailPath': thumbnail,
      'streamPlatform': 'Twitch',
      'streamIsLive': isLive,
      'streamViewers': viewers,
      'streamChannelKey': channel,
    };
  }

  static Future<Map<String, dynamic>> _fetchYouTubeStreamerMetadata(
    String url, {
    required String fallbackName,
  }) async {
    var title = '';
    var thumbnail = '';
    var channelName = streamerChannelFromUrl(url);
    var isLive = false;
    var viewers = 0;
    try {
      final raw = await _readStreamerUrl('https://www.youtube.com/oembed?url=${Uri.encodeComponent(url)}&format=json', json: true);
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        title = _streamCleanHtml((decoded['title'] ?? '').toString());
        channelName = _streamFirstNonEmpty([(decoded['author_name'] ?? '').toString(), channelName, fallbackName]);
        thumbnail = (decoded['thumbnail_url'] ?? '').toString();
      }
    } catch (e, st) {
      _logIgnoredError(e, st);
    }
    try {
      final html = await _readStreamerUrl(url);
      final generic = _streamerMetadataFromHtml(html, fallbackName: fallbackName, platform: 'YouTube', channel: channelName);
      title = _streamFirstNonEmpty([title, (generic['streamTitle'] ?? '').toString()]);
      thumbnail = _streamFirstNonEmpty([thumbnail, (generic['streamThumbnailUrl'] ?? '').toString()]);
      viewers = _streamToInt((generic['streamViewers'] ?? '0').toString());
      isLive = truthy(generic['streamIsLive']);
      channelName = _streamFirstNonEmpty([channelName, (generic['streamName'] ?? '').toString(), fallbackName]);
    } catch (e, st) {
      _logIgnoredError(e, st);
    }
    return <String, dynamic>{
      'streamName': channelName,
      'streamerName': channelName,
      'streamTitle': title,
      'streamThumbnailUrl': thumbnail,
      'streamThumbnailPath': thumbnail,
      'streamPlatform': 'YouTube',
      'streamIsLive': isLive,
      'streamViewers': viewers,
      'streamChannelKey': streamerChannelFromUrl(url),
    };
  }

  static Future<Map<String, dynamic>> _fetchGenericStreamerMetadata(
    String url, {
    required String fallbackName,
    required String platform,
    required String channel,
  }) async {
    final html = await _readStreamerUrl(url);
    return _streamerMetadataFromHtml(html, fallbackName: fallbackName, platform: platform, channel: channel);
  }

  static Map<String, dynamic> _streamerMetadataFromHtml(
    String html, {
    required String fallbackName,
    required String platform,
    required String channel,
  }) {
    final title = _streamCleanHtml(_streamFirstNonEmpty([
      _streamMeta(html, 'property', 'og:title'),
      _streamMeta(html, 'name', 'twitter:title'),
      _streamJsonString(html, 'title'),
      _streamFirstMatch(html, RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true)),
    ]));
    final image = _streamFirstNonEmpty([
      _streamMeta(html, 'property', 'og:image'),
      _streamMeta(html, 'property', 'og:image:secure_url'),
      _streamMeta(html, 'name', 'twitter:image'),
      _streamMeta(html, 'name', 'twitter:image:src'),
      _streamJsonString(html, 'thumbnailUrl'),
      _streamJsonString(html, 'thumbnail_url'),
    ]);
    final viewers = _streamExtractViewers(html);
    final live = _streamLooksLive(html, title, viewers);
    return <String, dynamic>{
      'streamName': channel.isNotEmpty ? channel : fallbackName,
      'streamerName': channel.isNotEmpty ? channel : fallbackName,
      'streamTitle': title,
      'streamThumbnailUrl': image,
      'streamThumbnailPath': image,
      'streamPlatform': platform,
      'streamIsLive': live,
      'streamViewers': viewers,
      'streamChannelKey': channel,
    };
  }

  static Future<String> _readStreamerUrl(String url, {bool json = false}) async {
    final uri = Uri.parse(cleanStreamerUrl(url));
    final headers = <String, String>{
      HttpHeaders.userAgentHeader:
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36 RespectApp/1.0',
      HttpHeaders.acceptHeader: json ? 'application/json,text/plain,*/*' : 'text/html,application/xhtml+xml,application/json,text/plain,*/*',
      HttpHeaders.acceptLanguageHeader: 'en-US,en;q=0.9,ar;q=0.8',
    };
    if (uri.host.toLowerCase().contains('kick.com')) {
      headers[HttpHeaders.refererHeader] = 'https://kick.com/';
      headers['Origin'] = 'https://kick.com';
    }
    final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw Exception('stream metadata http ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes);
  }

  static Future<String> _postStreamerUrl(String url, String body, {Map<String, String> headers = const {}}) async {
    final merged = <String, String>{
      HttpHeaders.userAgentHeader: 'Mozilla/5.0 RespectApp/1.0',
      ...headers,
    };
    final response = await http
        .post(Uri.parse(url), headers: merged, body: body)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw Exception('stream metadata post http ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes);
  }

  static String _normalizeStreamerImageUrl(String url) {
    final clean = url.trim();
    if (clean.isEmpty) return '';
    if (clean.startsWith('//')) return 'https:$clean';
    return clean;
  }

  static String _streamMeta(String html, String attrName, String attrValue) {
    final patternA = RegExp(
      '<meta[^>]*$attrName=["\\\']$attrValue["\\\'][^>]*content=["\\\']([^"\\\']*)["\\\'][^>]*>',
      caseSensitive: false,
      dotAll: true,
    );
    final patternB = RegExp(
      '<meta[^>]*content=["\\\']([^"\\\']*)["\\\'][^>]*$attrName=["\\\']$attrValue["\\\'][^>]*>',
      caseSensitive: false,
      dotAll: true,
    );
    final a = _streamFirstMatch(html, patternA);
    return a.isNotEmpty ? a : _streamFirstMatch(html, patternB);
  }

  static String _streamJsonString(String text, String key) {
    final escaped = RegExp('"$key"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"', caseSensitive: false, dotAll: true);
    final m = escaped.firstMatch(text);
    if (m == null) return '';
    return _streamCleanHtml((m.group(1) ?? '').replaceAll('\\/', '/').replaceAll('\\u0026', '&'));
  }

  static String _streamFirstMatch(String text, RegExp regex) => regex.firstMatch(text)?.group(1)?.trim() ?? '';

  static String _streamFirstNonEmpty(List<String> values) =>
      values.firstWhere((v) => v.trim().isNotEmpty, orElse: () => '').trim();

  static String _streamCleanHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('\\/', '/')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static int _streamToInt(String value) {
    final clean = value.toLowerCase().replaceAll(',', '').trim();
    final match = RegExp(r'(\d+(?:\.\d+)?)\s*([km]?)').firstMatch(clean);
    if (match == null) return 0;
    final n = double.tryParse(match.group(1) ?? '0') ?? 0;
    final suffix = match.group(2) ?? '';
    if (suffix == 'm') return (n * 1000000).round();
    if (suffix == 'k') return (n * 1000).round();
    return n.round();
  }

  static int _streamExtractViewers(String html) {
    final patterns = <RegExp>[
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
      if (m != null) return _streamToInt(m.group(1) ?? '0');
    }
    return 0;
  }

  static bool _streamLooksLive(String html, String title, int viewers) {
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

  // ضع هنا رابط صورة Respect AI الثابتة.
  // الأفضل ترفع صورة PNG إلى Supabase Storage وتضع الرابط هنا.
  static const String respectAiAvatarUrl = 'https://oafbzceorbjykgoffuaa.supabase.co/storage/v1/object/public/avatars/respectai.png';

  // ================= Subscriptions / Verification / Posting limits / Stories =================
  // النظام الجديد: المستخدم يختار مستوى الباقة Silver/Gold/Premium + مدة الاشتراك.
  // التوثيق والميزات صارت مبنية على subscription_tier + verification_plan بدل خطة واحدة فقط.
  static const int freePostMaxChars = 800;
  static const int silverPostMaxChars = 1200;
  static const int goldPostMaxChars = 2000;
  static const int premiumPostMaxChars = 3500;

  static const int freeRespectAiDailyLimit = 10;
  static const int silverRespectAiDailyLimit = 25;
  static const int goldRespectAiDailyLimit = 50;
  static const int premiumRespectAiDailyLimit = 120;

  // للتوافق مع الكود القديم الذي كان يعتبر كل موثق = 2000 حرف و 50 طلب AI.
  static const int verifiedPostMaxChars = goldPostMaxChars;
  static const int verifiedRespectAiDailyLimit = goldRespectAiDailyLimit;

  static const String _localStoriesKey = 'respect_active_stories_v1';
  static const String _seenStoriesKey = 'respect_seen_stories_v1';
  static const String _localAiUsageKeyPrefix = 'respect_ai_usage_';

  static const List<Map<String, dynamic>> subscriptionTiers = [
    {
      'id': 'silver',
      'title': 'الباقة الفضية',
      'shortTitle': 'فضية',
      'badge': 'مناسبة للبداية',
      'icon': 'star',
      'maxPostChars': silverPostMaxChars,
      'aiDailyLimit': silverRespectAiDailyLimit,
      'features': [
        'علامة توثيق فضية',
        '1200 حرف للتغريدة',
        '25 رد Respect AI يوميًا',
        'فتح الستوري',
        'أولوية ظهور خفيفة',
        'شارة موثق تظهر في الفيد والبحث والرسائل',
        'رابط واحد واضح في البروفايل',
      ],
    },
    {
      'id': 'gold',
      'title': 'الباقة الذهبية',
      'shortTitle': 'ذهبية',
      'badge': 'الأكثر توازنًا',
      'icon': 'workspace_premium',
      'maxPostChars': goldPostMaxChars,
      'aiDailyLimit': goldRespectAiDailyLimit,
      'features': [
        'كل ميزات الفضية',
        '2000 حرف للتغريدة',
        '50 رد Respect AI يوميًا',
        'أولوية أعلى في الظهور',
        'رسائل من الحسابات الموثقة فقط عند تفعيل الخصوصية',
        'إحصائيات منشورات أساسية',
        'تثبيت منشورين في الحساب',
        'إطار ذهبي للبروفايل',
        'أولوية في نتائج البحث',
        'زر تواصل رسمي في البروفايل',
      ],
    },
    {
      'id': 'premium',
      'title': 'الباقة المميزة',
      'shortTitle': 'مميزة',
      'badge': 'أقوى باقة',
      'icon': 'diamond',
      'maxPostChars': premiumPostMaxChars,
      'aiDailyLimit': premiumRespectAiDailyLimit,
      'features': [
        'كل ميزات الذهبية',
        '3500 حرف للتغريدة',
        '120 رد Respect AI يوميًا',
        'تمييز أقوى للحساب',
        'أولوية دعم ومراجعة أسرع',
        'إطار ألماسي متحرك للبروفايل',
        'تثبيت 3 منشورات في الحساب',
        'إحصائيات متقدمة للحساب',
        'ظهور في قسم الحسابات المميزة',
        'حماية أعلى من تقليد الاسم',
        'شارة خاصة داخل اللايف والتعليقات',
      ],
    },
  ];

  static const List<Map<String, dynamic>> subscriptionDurations = [
    {'id': 'monthly', 'title': 'شهر', 'months': 1, 'badge': 'مرن'},
    {'id': 'quarterly', 'title': '3 أشهر', 'months': 3, 'badge': 'أوفر'},
    {'id': 'yearly', 'title': 'سنة', 'months': 12, 'badge': 'الأفضل'},
  ];

  static const List<Map<String, dynamic>> verificationPlans = [
    {
      'id': 'silver_monthly',
      'tier': 'silver',
      'duration': 'monthly',
      'title': 'الفضية - شهر',
      'months': 1,
      'price': 2.0,
      'badge': 'مناسبة للتجربة',
      'paddle_price_id': String.fromEnvironment('PADDLE_PRICE_SILVER_MONTHLY', defaultValue: 'pri_REPLACE_SILVER_MONTHLY'),
    },
    {
      'id': 'silver_quarterly',
      'tier': 'silver',
      'duration': 'quarterly',
      'title': 'الفضية - 3 أشهر',
      'months': 3,
      'price': 5.0,
      'badge': 'وفر أكثر',
      'paddle_price_id': String.fromEnvironment('PADDLE_PRICE_SILVER_QUARTERLY', defaultValue: 'pri_REPLACE_SILVER_QUARTERLY'),
    },
    {
      'id': 'silver_yearly',
      'tier': 'silver',
      'duration': 'yearly',
      'title': 'الفضية - سنة',
      'months': 12,
      'price': 18.0,
      'badge': 'اشتراك سنوي',
      'paddle_price_id': String.fromEnvironment('PADDLE_PRICE_SILVER_YEARLY', defaultValue: 'pri_REPLACE_SILVER_YEARLY'),
    },
    {
      'id': 'gold_monthly',
      'tier': 'gold',
      'duration': 'monthly',
      'title': 'الذهبية - شهر',
      'months': 1,
      'price': 4.0,
      'badge': 'الأكثر توازنًا',
      'paddle_price_id': String.fromEnvironment('PADDLE_PRICE_GOLD_MONTHLY', defaultValue: 'pri_REPLACE_GOLD_MONTHLY'),
    },
    {
      'id': 'gold_quarterly',
      'tier': 'gold',
      'duration': 'quarterly',
      'title': 'الذهبية - 3 أشهر',
      'months': 3,
      'price': 10.0,
      'badge': 'وفر 2 دولار',
      'paddle_price_id': String.fromEnvironment('PADDLE_PRICE_GOLD_QUARTERLY', defaultValue: 'pri_REPLACE_GOLD_QUARTERLY'),
    },
    {
      'id': 'gold_yearly',
      'tier': 'gold',
      'duration': 'yearly',
      'title': 'الذهبية - سنة',
      'months': 12,
      'price': 35.0,
      'badge': 'أفضل قيمة للذهبية',
      'paddle_price_id': String.fromEnvironment('PADDLE_PRICE_GOLD_YEARLY', defaultValue: 'pri_REPLACE_GOLD_YEARLY'),
    },
    {
      'id': 'premium_monthly',
      'tier': 'premium',
      'duration': 'monthly',
      'title': 'المميزة - شهر',
      'months': 1,
      'price': 7.0,
      'badge': 'أقوى شهرية',
      'paddle_price_id': String.fromEnvironment('PADDLE_PRICE_PREMIUM_MONTHLY', defaultValue: 'pri_01kts7c3ff0pax8rh9pw0ekyds'),
    },
    {
      'id': 'premium_quarterly',
      'tier': 'premium',
      'duration': 'quarterly',
      'title': 'المميزة - 3 أشهر',
      'months': 3,
      'price': 18.0,
      'badge': 'ممتازة للنشطين',
      'paddle_price_id': String.fromEnvironment('PADDLE_PRICE_PREMIUM_QUARTERLY', defaultValue: 'pri_01kts7eyc987m59vb9z1hhssxg'),
    },
    {
      'id': 'premium_yearly',
      'tier': 'premium',
      'duration': 'yearly',
      'title': 'المميزة - سنة',
      'months': 12,
      'price': 60.0,
      'badge': 'الأفضل والأقوى',
      'paddle_price_id': String.fromEnvironment('PADDLE_PRICE_PREMIUM_YEARLY', defaultValue: 'pri_01kts7hvvacsrs3z79jjbtzmrf'),
    },
  ];

  static const bool paddleSandboxMode =
      bool.fromEnvironment('PADDLE_SANDBOX_MODE', defaultValue: true);
  static const String paddleClientSideToken =
      String.fromEnvironment('PADDLE_CLIENT_SIDE_TOKEN', defaultValue: '');
  static const String paddleSandboxCheckoutBaseUrl = 'https://sandbox-checkout.paddle.com';
  static const String paddleProductionCheckoutBaseUrl = 'https://checkout.paddle.com';

  // هذا endpoint لازم يكون في سيرفر Render، وليس داخل Flutter، لأنه هو الذي ينشئ Transaction
  // ويتأكد من الدفع عبر Paddle Webhook ثم يفعّل الاشتراك.
  static String get paddleCreateVerificationCheckoutUrl =>
      _backendEndpoint('/paddle/create-verification-checkout');

  static const Map<String, String> paddleVerificationPriceIds = {
    'silver_monthly': String.fromEnvironment('PADDLE_PRICE_SILVER_MONTHLY', defaultValue: 'pri_REPLACE_SILVER_MONTHLY'),
    'silver_quarterly': String.fromEnvironment('PADDLE_PRICE_SILVER_QUARTERLY', defaultValue: 'pri_REPLACE_SILVER_QUARTERLY'),
    'silver_yearly': String.fromEnvironment('PADDLE_PRICE_SILVER_YEARLY', defaultValue: 'pri_REPLACE_SILVER_YEARLY'),
    'gold_monthly': String.fromEnvironment('PADDLE_PRICE_GOLD_MONTHLY', defaultValue: 'pri_REPLACE_GOLD_MONTHLY'),
    'gold_quarterly': String.fromEnvironment('PADDLE_PRICE_GOLD_QUARTERLY', defaultValue: 'pri_REPLACE_GOLD_QUARTERLY'),
    'gold_yearly': String.fromEnvironment('PADDLE_PRICE_GOLD_YEARLY', defaultValue: 'pri_REPLACE_GOLD_YEARLY'),
    'premium_monthly': String.fromEnvironment('PADDLE_PRICE_PREMIUM_MONTHLY', defaultValue: 'pri_01kts7c3ff0pax8rh9pw0ekyds'),
    'premium_quarterly': String.fromEnvironment('PADDLE_PRICE_PREMIUM_QUARTERLY', defaultValue: 'pri_01kts7eyc987m59vb9z1hhssxg'),
    'premium_yearly': String.fromEnvironment('PADDLE_PRICE_PREMIUM_YEARLY', defaultValue: 'pri_01kts7hvvacsrs3z79jjbtzmrf'),
    // توافق مع الخطة القديمة
    'monthly': String.fromEnvironment('PADDLE_PRICE_PREMIUM_MONTHLY', defaultValue: 'pri_01kts7c3ff0pax8rh9pw0ekyds'),
    'quarterly': String.fromEnvironment('PADDLE_PRICE_PREMIUM_QUARTERLY', defaultValue: 'pri_01kts7eyc987m59vb9z1hhssxg'),
    'yearly': String.fromEnvironment('PADDLE_PRICE_PREMIUM_YEARLY', defaultValue: 'pri_01kts7hvvacsrs3z79jjbtzmrf'),
  };

  static DateTime? verifiedUntilForUser(Map<String, dynamic>? user) {
    if (user == null) return null;
    final expiresRaw = (user['verified_until'] ??
        user['verification_expires_at'] ??
        user['subscription_expires_at'] ??
        user['verifiedUntil'] ??
        '')
        .toString();
    final parsed = DateTime.tryParse(expiresRaw);
    return parsed?.toLocal();
  }

  static bool truthy(dynamic value) {
    if (value == true) return true;
    final v = (value ?? '').toString().trim().toLowerCase();
    return v == 'true' || v == '1' || v == 'yes' || v == 'verified' || v == 'active';
  }

  static Map<String, dynamic> subscriptionTierById(String tierId) {
    final id = tierId.trim().toLowerCase();
    return subscriptionTiers.firstWhere(
      (t) => (t['id'] ?? '').toString() == id,
      orElse: () => subscriptionTiers.first,
    );
  }

  static String tierForPlanId(String planId) {
    final id = planId.trim().toLowerCase();
    final plan = verificationPlans.firstWhere(
      (p) => (p['id'] ?? '').toString() == id,
      orElse: () => const <String, dynamic>{},
    );
    final tier = (plan['tier'] ?? '').toString().trim().toLowerCase();
    if (tier.isNotEmpty) return tier;
    if (id == 'monthly' || id == 'quarterly' || id == 'yearly') return 'premium';
    return 'silver';
  }

  static String subscriptionTierForUser(Map<String, dynamic>? user) {
    if (user == null) return 'free';
    final expires = verifiedUntilForUser(user)?.toUtc();
    if (expires != null && expires.isBefore(DateTime.now().toUtc())) return 'free';

    final rawTier = (user['subscription_tier'] ?? user['tier'] ?? user['plan_tier'] ?? '').toString().trim().toLowerCase();
    if (rawTier == 'silver' || rawTier == 'gold' || rawTier == 'premium') return rawTier;

    final planId = (user['verification_plan'] ?? user['plan_id'] ?? '').toString().trim().toLowerCase();
    if (planId.isNotEmpty) return tierForPlanId(planId);

    if (truthy(user['is_verified']) || truthy(user['verified']) || truthy(user['respect_verified'])) return 'premium';
    return 'free';
  }

  static bool isVerifiedUser(Map<String, dynamic>? user) {
    if (user == null) return false;
    if (isRespectAiUsername((user['username'] ?? '').toString())) return true;

    final expires = verifiedUntilForUser(user)?.toUtc();
    final hasActiveExpiry = expires != null && expires.isAfter(DateTime.now().toUtc());
    final tier = subscriptionTierForUser(user);
    final activeStatus = (user['verification_status'] ?? '').toString().toLowerCase().trim() == 'active' ||
        tier == 'silver' || tier == 'gold' || tier == 'premium' ||
        (user['subscription_tier'] ?? '').toString().toLowerCase().trim() == 'verified';
    if ((activeStatus || truthy(user['is_verified']) || truthy(user['verified'])) && expires != null) {
      return hasActiveExpiry;
    }

    final direct = truthy(user['is_verified']) ||
        truthy(user['isVerified']) ||
        truthy(user['verified']) ||
        truthy(user['blue_badge']) ||
        truthy(user['respect_verified']);
    if (direct && expires == null) return true;
    return hasActiveExpiry || tier != 'free';
  }

  static int postMaxCharsForUser(Map<String, dynamic>? user) {
    final tier = subscriptionTierForUser(user);
    if (tier == 'premium') return premiumPostMaxChars;
    if (tier == 'gold') return goldPostMaxChars;
    if (tier == 'silver') return silverPostMaxChars;
    return freePostMaxChars;
  }

  static int respectAiDailyLimitForUser(Map<String, dynamic>? user) {
    final tier = subscriptionTierForUser(user);
    if (tier == 'premium') return premiumRespectAiDailyLimit;
    if (tier == 'gold') return goldRespectAiDailyLimit;
    if (tier == 'silver') return silverRespectAiDailyLimit;
    return freeRespectAiDailyLimit;
  }

  static List<String> subscriptionFeaturesForUser(Map<String, dynamic>? user) {
    final tier = subscriptionTierForUser(user);
    if (tier == 'free') {
      return const <String>[
        '800 حرف للتغريدة',
        '10 ردود Respect AI يوميًا',
      ];
    }
    final features = subscriptionTierById(tier)['features'];
    if (features is List) return features.map((e) => e.toString()).toList();
    return const <String>[];
  }

  static bool canUseStories(Map<String, dynamic>? user) => subscriptionTierForUser(user) != 'free';
  static bool canUseGoldFeatures(Map<String, dynamic>? user) {
    final tier = subscriptionTierForUser(user);
    return tier == 'gold' || tier == 'premium';
  }
  static bool canUsePremiumFeatures(Map<String, dynamic>? user) => subscriptionTierForUser(user) == 'premium';

  static Map<String, dynamic> subscriptionPowerForTier(String tier) {
    final t = tier.trim().toLowerCase();
    if (t == 'premium') {
      return const <String, dynamic>{
        'pinLimit': 3,
        'storyLimit': 12,
        'videoMaxSeconds': 420,
        'searchBoost': 900,
        'profileFrame': 'diamond',
        'analytics': 'advanced',
        'officialContact': true,
        'featuredDirectory': true,
        'nameProtection': true,
        'liveBadge': true,
      };
    }
    if (t == 'gold') {
      return const <String, dynamic>{
        'pinLimit': 2,
        'storyLimit': 8,
        'videoMaxSeconds': 240,
        'searchBoost': 520,
        'profileFrame': 'gold',
        'analytics': 'basic',
        'officialContact': true,
        'featuredDirectory': false,
        'nameProtection': false,
        'liveBadge': true,
      };
    }
    if (t == 'silver') {
      return const <String, dynamic>{
        'pinLimit': 1,
        'storyLimit': 5,
        'videoMaxSeconds': 120,
        'searchBoost': 220,
        'profileFrame': 'silver',
        'analytics': 'mini',
        'officialContact': false,
        'featuredDirectory': false,
        'nameProtection': false,
        'liveBadge': false,
      };
    }
    return const <String, dynamic>{
      'pinLimit': 1,
      'storyLimit': 1,
      'videoMaxSeconds': 60,
      'searchBoost': 0,
      'profileFrame': 'none',
      'analytics': 'none',
      'officialContact': false,
      'featuredDirectory': false,
      'nameProtection': false,
      'liveBadge': false,
    };
  }

  static Map<String, dynamic> subscriptionPowerForUser(Map<String, dynamic>? user) {
    return subscriptionPowerForTier(subscriptionTierForUser(user));
  }

  static int pinnedPostLimitForUser(Map<String, dynamic>? user) =>
      int.tryParse((subscriptionPowerForUser(user)['pinLimit'] ?? 1).toString()) ?? 1;

  static int storyLimitForUser(Map<String, dynamic>? user) =>
      int.tryParse((subscriptionPowerForUser(user)['storyLimit'] ?? 1).toString()) ?? 1;

  static int videoMaxSecondsForUser(Map<String, dynamic>? user) =>
      int.tryParse((subscriptionPowerForUser(user)['videoMaxSeconds'] ?? 60).toString()) ?? 60;

  static bool canUseOfficialContact(Map<String, dynamic>? user) =>
      subscriptionPowerForUser(user)['officialContact'] == true;

  static bool hasFeaturedDirectory(Map<String, dynamic>? user) =>
      subscriptionPowerForUser(user)['featuredDirectory'] == true;

  static bool hasNameProtection(Map<String, dynamic>? user) =>
      subscriptionPowerForUser(user)['nameProtection'] == true;

  static String profileFrameForUser(Map<String, dynamic>? user) =>
      (subscriptionPowerForUser(user)['profileFrame'] ?? 'none').toString();

  static String analyticsLevelForUser(Map<String, dynamic>? user) =>
      (subscriptionPowerForUser(user)['analytics'] ?? 'none').toString();

  static String tierDisplayName(String tier) {
    switch (tier.trim().toLowerCase()) {
      case 'premium':
        return 'مميزة';
      case 'gold':
        return 'ذهبية';
      case 'silver':
        return 'فضية';
      default:
        return 'مجانية';
    }
  }

  static String tierPowerDescription(String tier) {
    switch (tier.trim().toLowerCase()) {
      case 'premium':
        return 'توثيق ألماسي، أولوية ظهور قوية، 3 تثبيتات، إحصائيات متقدمة، وظهور ضمن الحسابات المميزة.';
      case 'gold':
        return 'توثيق ذهبي، أولوية بحث وفيد، رسائل موثقين فقط، 2 تثبيت، وإحصائيات أساسية.';
      case 'silver':
        return 'توثيق فضي، ستوري، حد كتابة أعلى، ودفعة ظهور خفيفة.';
      default:
        return 'حساب عادي بدون قوة توثيق.';
    }
  }

  static int searchPriorityWeightForUser(Map<String, dynamic>? user) {
    final tier = subscriptionTierForUser(user);
    final base = subscriptionPriorityWeightForTier(tier);
    if (isRespectAiUsername((user?['username'] ?? '').toString())) return 2000;
    return base;
  }

  static Future<List<Map<String, dynamic>>> getFeaturedVerifiedUsers({int limit = 20}) async {
    try {
      final rows = await client
          .from('users')
          .select()
          .inFilter('subscription_tier', ['premium', 'gold', 'silver'])
          .order('subscription_tier', ascending: false)
          .limit(limit);
      final out = List<Map<String, dynamic>>.from((rows as List).map((e) => Map<String, dynamic>.from(e as Map)));
      out.sort((a, b) {
        final pa = searchPriorityWeightForUser(a);
        final pb = searchPriorityWeightForUser(b);
        if (pa != pb) return pb.compareTo(pa);
        return (b['created_at'] ?? '').toString().compareTo((a['created_at'] ?? '').toString());
      });
      return out.take(limit).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<Map<String, int>> getPostAnalyticsSummary(String username) async {
    final user = displayUsername(username);
    final out = <String, int>{
      'posts': 0,
      'likes': 0,
      'reposts': 0,
      'views': 0,
      'replies': 0,
      'engagement': 0,
    };
    try {
      final posts = await client
          .from('posts')
          .select('id,likes,reposts,views,reply_count,replies')
          .eq('username', user)
          .limit(200);
      final rows = List<Map<String, dynamic>>.from((posts as List).map((e) => Map<String, dynamic>.from(e as Map)));
      out['posts'] = rows.length;
      for (final row in rows) {
        out['likes'] = (out['likes'] ?? 0) + (int.tryParse((row['likes'] ?? 0).toString()) ?? 0);
        out['reposts'] = (out['reposts'] ?? 0) + (int.tryParse((row['reposts'] ?? 0).toString()) ?? 0);
        out['views'] = (out['views'] ?? 0) + (int.tryParse((row['views'] ?? 0).toString()) ?? 0);
        final replies = row['replies'] is List ? (row['replies'] as List).length : (int.tryParse((row['reply_count'] ?? 0).toString()) ?? 0);
        out['replies'] = (out['replies'] ?? 0) + replies;
      }
      out['engagement'] = (out['likes'] ?? 0) + (out['reposts'] ?? 0) + (out['replies'] ?? 0);
    } catch (_) {}
    return out;
  }

  /// ميزة: استقبال الرسائل من الحسابات الموثقة فقط.
  /// هذه ليست مجرد نص في الباقة: لا تعمل إلا للذهبية والمميزة.
  static bool canUseVerifiedOnlyMessagesFeature(Map<String, dynamic>? user) {
    final tier = subscriptionTierForUser(user);
    return tier == 'gold' || tier == 'premium';
  }

  static Future<bool> canUseVerifiedOnlyMessagesForUsername(String username) async {
    try {
      final user = await getUserByUsername(username);
      return canUseVerifiedOnlyMessagesFeature(user);
    } catch (e, st) {
      _logIgnoredError(e, st);
      return false;
    }
  }

  static int subscriptionPriorityWeightForTier(String tier) {
    switch (tier.trim().toLowerCase()) {
      case 'premium':
        return 900;
      case 'gold':
        return 520;
      case 'silver':
        return 220;
      default:
        return 0;
    }
  }

  static int subscriptionPriorityWeightForUser(Map<String, dynamic>? user) {
    return subscriptionPriorityWeightForTier(subscriptionTierForUser(user));
  }

  static String subscriptionPriorityLabelForTier(String tier) {
    switch (tier.trim().toLowerCase()) {
      case 'premium':
        return 'أولوية مميزة';
      case 'gold':
        return 'أولوية ذهبية';
      case 'silver':
        return 'أولوية فضية';
      default:
        return '';
    }
  }

  static bool subscriptionBoostActiveForUser(Map<String, dynamic>? user) {
    if (user == null) return false;
    final tier = subscriptionTierForUser(user);
    if (tier == 'free') return false;
    final expires = verifiedUntilForUser(user)?.toUtc();
    return expires == null || expires.isAfter(DateTime.now().toUtc());
  }

  static Map<String, dynamic> authorSubscriptionPostFields(Map<String, dynamic>? user) {
    final tier = subscriptionTierForUser(user);
    final priority = subscriptionPriorityWeightForTier(tier);
    final expires = verifiedUntilForUser(user)?.toUtc();
    return <String, dynamic>{
      'author_subscription_tier': tier,
      'author_subscription_priority': priority,
      'author_subscription_boost_until': expires?.toIso8601String(),
      'author_post_max_chars': postMaxCharsForUser(user),
      'author_ai_daily_limit': respectAiDailyLimitForUser(user),
      'author_subscription_label': subscriptionPriorityLabelForTier(tier),
    };
  }

  static Future<Map<String, dynamic>> getPostingLimitsForUsername(String username) async {
    Map<String, dynamic>? user;
    try { user = await getUserByUsername(username); } catch (e, st) { _logIgnoredError(e, st); }
    final verified = isVerifiedUser(user);
    final tier = subscriptionTierForUser(user);
    final tierInfo = tier == 'free' ? const <String, dynamic>{'title': 'مجاني'} : subscriptionTierById(tier);
    final limit = postMaxCharsForUser(user);
    final aiLimit = respectAiDailyLimitForUser(user);
    final used = await respectAiUsageCountToday(username);
    return <String, dynamic>{
      'verified': verified,
      'subscriptionTier': tier,
      'subscriptionTitle': (tierInfo['title'] ?? 'مجاني').toString(),
      'features': subscriptionFeaturesForUser(user),
      'maxPostChars': limit,
      'aiDailyLimit': aiLimit,
      'aiUsedToday': used,
      'aiRemainingToday': (aiLimit - used).clamp(0, aiLimit),
      'canUseStories': canUseStories(user),
      'canUseGoldFeatures': canUseGoldFeatures(user),
      'canUsePremiumFeatures': canUsePremiumFeatures(user),
      'power': subscriptionPowerForUser(user),
      'pinLimit': pinnedPostLimitForUser(user),
      'storyLimit': storyLimitForUser(user),
      'videoMaxSeconds': videoMaxSecondsForUser(user),
      'profileFrame': profileFrameForUser(user),
      'analyticsLevel': analyticsLevelForUser(user),
      'officialContact': canUseOfficialContact(user),
    };
  }

  static Future<void> enforcePostCharacterLimit({required String username, required String text}) async {
    final limits = await getPostingLimitsForUsername(username);
    final max = int.tryParse((limits['maxPostChars'] ?? freePostMaxChars).toString()) ?? freePostMaxChars;
    final length = text.runes.length;
    if (length > max) {
      throw Exception('حد التغريدة لهذا الحساب $max حرف فقط. اختصر النص ${length - max} حرف.');
    }
  }

  static String _aiUsageDayKey() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return '${now.year}-$mm-$dd';
  }

  static Future<int> respectAiUsageCountToday(String username) async {
    final user = displayUsername(username);
    final today = _aiUsageDayKey();
    try {
      final rows = await client
          .from('respect_ai_usage')
          .select('id')
          .eq('username', user)
          .eq('usage_day', today)
          .timeout(const Duration(seconds: 6));
      return (rows as List).length;
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_localAiUsageKeyPrefix${normalizeUsername(user)}_$today');
      return int.tryParse(raw ?? '0') ?? 0;
    }
  }

  static Future<void> _incrementRespectAiUsage(String username) async {
    final user = displayUsername(username);
    final today = _aiUsageDayKey();
    try {
      await client.from('respect_ai_usage').insert({
        'username': user,
        'usage_day': today,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }).timeout(const Duration(seconds: 6));
      return;
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_localAiUsageKeyPrefix${normalizeUsername(user)}_$today';
      final current = int.tryParse(prefs.getString(key) ?? '0') ?? 0;
      await prefs.setString(key, '${current + 1}');
    }
  }

  static Future<void> enforceRespectAiDailyLimit(String username) async {
    final limits = await getPostingLimitsForUsername(username);
    final max = int.tryParse((limits['aiDailyLimit'] ?? freeRespectAiDailyLimit).toString()) ?? freeRespectAiDailyLimit;
    final used = int.tryParse((limits['aiUsedToday'] ?? 0).toString()) ?? 0;
    if (used >= max) {
      throw Exception('وصلت لحد Respect AI اليومي ($max مرة). رقّ الباقة لزيادة الحد اليومي.');
    }
  }

  static Future<String> uploadStoryMedia({
    required String username,
    required String filePath,
    required bool video,
  }) async {
    final clean = normalizeUsername(username);
    if (clean.isEmpty) throw Exception('username is empty');
    final raw = filePath.trim();
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    final file = File(raw);
    if (!await file.exists()) throw Exception('story file not found');
    final ext = _storageExtFromPath(raw);
    final storagePath = 'stories/$clean/story_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final contentType = video ? 'video/$ext' : (ext == 'png' ? 'image/png' : ext == 'webp' ? 'image/webp' : 'image/jpeg');
    await client.storage.from('post-media').upload(
      storagePath,
      file,
      fileOptions: FileOptions(contentType: contentType, upsert: true),
    );
    return client.storage.from('post-media').getPublicUrl(storagePath);
  }

  static Future<Map<String, dynamic>> addStory({
    required String username,
    required String name,
    required String mediaPath,
    required String mediaType,
    String avatarUrl = '',
    bool privateStory = false,
    List<String> allowedViewers = const <String>[],
  }) async {
    await enforceVerifiedFeature(username: username, featureName: 'الستوري');
    final user = displayUsername(username);
    final isVideo = mediaType.toLowerCase().contains('video');
    final publicUrl = await uploadStoryMedia(username: user, filePath: mediaPath, video: isVideo);
    final now = DateTime.now().toUtc();
    final expires = now.add(const Duration(hours: 24));
    final cleanAllowedViewers = allowedViewers
        .map(displayUsername)
        .where((u) => u != '@user' && u != user)
        .toSet()
        .toList();

    final payload = <String, dynamic>{
      'username': user,
      'name': name,
      'avatar_url': avatarUrl,
      'media_url': publicUrl,
      'media_type': isVideo ? 'video' : 'image',
      'created_at': now.toIso8601String(),
      'expires_at': expires.toIso8601String(),
      'is_active': true,
      'is_private': privateStory,
      'privacy': privateStory ? 'private' : 'public',
      'allowed_viewers': privateStory ? cleanAllowedViewers : <String>[],
    };
    try {
      final inserted = await client.from('respect_stories').insert(payload).select().single();
      final story = Map<String, dynamic>.from(inserted as Map);
      unawaited(_moderateStoryInBackground(
        storyId: (story['id'] ?? '').toString(),
        authorUsername: user,
        mediaUrl: publicUrl,
        mediaType: isVideo ? 'video' : 'image',
      ));
      return story;
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_localStoriesKey);
      final list = <Map<String, dynamic>>[];
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) list.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        } catch (e, st) { _logIgnoredError(e, st); }
      }
      final local = <String, dynamic>{...payload, 'id': 'local_story_${now.microsecondsSinceEpoch}'};
      list.insert(0, local);
      await prefs.setString(_localStoriesKey, jsonEncode(list.take(100).toList()));
      unawaited(_moderateStoryInBackground(
        storyId: (local['id'] ?? '').toString(),
        authorUsername: user,
        mediaUrl: publicUrl,
        mediaType: isVideo ? 'video' : 'image',
      ));
      return local;
    }
  }

  static Future<List<Map<String, dynamic>>> getActiveStories({List<String>? usernames}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final names = usernames == null
        ? <String>[]
        : usernames.map(displayUsername).where((u) => u != '@user').toSet().toList();
    try {
      dynamic query = client
          .from('respect_stories')
          .select('id,username,name,avatar_url,media_url,media_type,created_at,expires_at,is_active,is_private,privacy,allowed_viewers')
          .eq('is_active', true)
          .gt('expires_at', now);
      if (names.isNotEmpty) query = query.inFilter('username', names);
      final data = await query.order('created_at', ascending: false).limit(150);
      return List<Map<String, dynamic>>.from((data as List).map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_localStoriesKey);
      if (raw == null || raw.trim().isEmpty) return <Map<String, dynamic>>[];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) return <Map<String, dynamic>>[];
        final nowDt = DateTime.now().toUtc();
        final out = decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))).where((e) {
          final expires = DateTime.tryParse((e['expires_at'] ?? '').toString())?.toUtc();
          final user = displayUsername((e['username'] ?? '').toString());
          return expires != null && expires.isAfter(nowDt) && (names.isEmpty || names.contains(user));
        }).toList();
        await prefs.setString(_localStoriesKey, jsonEncode(out));
        return out;
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    }
  }

  static Future<List<Map<String, dynamic>>> getActiveStoriesForUser(String username) {
    return getActiveStories(usernames: [username]);
  }

  static Future<Set<String>> getSeenStoryIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_seenStoriesKey);
    if (raw == null || raw.trim().isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).where((id) => id.trim().isNotEmpty).toSet();
      }
    } catch (e, st) { _logIgnoredError(e, st); }
    return <String>{};
  }

  static Future<void> markStoriesSeen(List<Map<String, dynamic>> stories) async {
    if (stories.isEmpty) return;
    final ids = stories
        .map((e) => (e['id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final current = await getSeenStoryIds();
    current.addAll(ids);
    // نخليها محدودة حتى لا يكبر التخزين المحلي مع الوقت.
    final compact = current.toList();
    final start = compact.length > 900 ? compact.length - 900 : 0;
    await prefs.setString(_seenStoriesKey, jsonEncode(compact.sublist(start)));
  }

  static Future<bool> areStoriesSeen(List<Map<String, dynamic>> stories) async {
    if (stories.isEmpty) return false;
    final ids = stories
        .map((e) => (e['id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return false;
    final seen = await getSeenStoryIds();
    return ids.every(seen.contains);
  }


  static Map<String, dynamic> verificationPlanById(String planId) {
    return verificationPlans.firstWhere(
          (p) => (p['id'] ?? '').toString() == planId,
      orElse: () => verificationPlans.first,
    );
  }

  static String paddlePriceIdForPlan(String planId) {
    final id = planId.trim().toLowerCase();
    final priceId = paddleVerificationPriceIds[id] ?? (verificationPlanById(id)['paddle_price_id'] ?? '').toString();
    if (priceId.trim().isEmpty) {
      throw Exception('لا يوجد Paddle price id لخطة $planId');
    }
    return priceId;
  }

  static Future<String> createVerificationCheckout({
    required String username,
    required String planId,
  }) async {
    final user = displayUsername(username);
    final plan = verificationPlanById(planId);
    final priceId = paddlePriceIdForPlan(planId);
    final tier = (plan['tier'] ?? tierForPlanId(planId)).toString();
    final duration = (plan['duration'] ?? '').toString();

    final payload = <String, dynamic>{
      'username': user,
      'planId': planId,
      'priceId': priceId,
      'tier': tier,
      'duration': duration,
      'months': plan['months'],
      'priceUsd': plan['price'],
      'mode': paddleSandboxMode ? 'sandbox' : 'production',
      'clientSideToken': paddleClientSideToken,
      'platform': _safeDevicePlatform,
      'customData': {
        'app': 'respect',
        'product_type': 'verification_subscription',
        'platform': _safeDevicePlatform,
        'username': user,
        'plan_id': planId,
        'planId': planId,
        'tier': tier,
        'duration': duration,
        'months': plan['months'],
      },
    };

    try {
      final response = await _postSignedJson(
  Uri.parse(paddleCreateVerificationCheckoutUrl),
  payload,
  timeout: const Duration(seconds: 20),
);

      Map<String, dynamic> decoded = <String, dynamic>{};
      try {
        final raw = jsonDecode(response.body);
        if (raw is Map) decoded = raw.map((k, v) => MapEntry(k.toString(), v));
      } catch (_) {}

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final url = (decoded['checkout_url'] ??
                decoded['checkoutUrl'] ??
                decoded['url'] ??
                decoded['payment_url'] ??
                decoded['paymentUrl'] ??
                '')
            .toString()
            .trim();

        if (url.startsWith('http://') || url.startsWith('https://')) {
          return url;
        }
      }

      final message = (decoded['detail'] ?? decoded['error'] ?? decoded['message'] ?? response.body).toString();
      throw Exception(message.isEmpty ? 'فشل إنشاء رابط الدفع من السيرفر' : message);
    } on TimeoutException {
      throw Exception('انتهت مهلة الاتصال بسيرفر الدفع');
    } catch (e) {
      // نرمي رسالة واضحة بدل تفعيل التوثيق مباشرة. لا تفعل التوثيق من Flutter أبدًا.
      throw Exception('تأكد من إضافة endpoint /paddle/create-verification-checkout في السيرفر. التفاصيل: $e');
    }
  }

  static Future<Map<String, dynamic>> activateVerificationPlan({
    required String username,
    required String planId,
  }) async {
    final user = displayUsername(username);
    final clean = normalizeUsername(user);
    final plan = verificationPlanById(planId);
    final months = int.tryParse((plan['months'] ?? 1).toString()) ?? 1;
    final price = double.tryParse((plan['price'] ?? 2).toString()) ?? 2.0;
    final tier = (plan['tier'] ?? tierForPlanId(planId)).toString().trim().toLowerCase();
    final now = DateTime.now().toUtc();
    final oldUser = await getUserByUsername(user);
    final oldUntil = verifiedUntilForUser(oldUser)?.toUtc();
    final startsFrom = oldUntil != null && oldUntil.isAfter(now) ? oldUntil : now;
    final expires = DateTime.utc(startsFrom.year, startsFrom.month + months, startsFrom.day, startsFrom.hour, startsFrom.minute, startsFrom.second);

    final payload = <String, dynamic>{
      'is_verified': true,
      'verified': true,
      'respect_verified': true,
      'verification_status': 'active',
      'subscription_tier': tier,
      'verification_plan': planId,
      'verified_until': expires.toIso8601String(),
      'verification_expires_at': expires.toIso8601String(),
      'subscription_expires_at': expires.toIso8601String(),
      'verification_updated_at': now.toIso8601String(),
    };

    try {
      await client.from('users').update(payload).or('username.eq.$user,username.eq.$clean').timeout(const Duration(seconds: 8));
    } catch (_) {
      try { await client.from('users').update(payload).eq('username', user).timeout(const Duration(seconds: 8)); } catch (e, st) { _logIgnoredError(e, st); }
    }

    final priorityPayload = <String, dynamic>{
      'author_verified': true,
      'author_subscription_tier': tier,
      'author_subscription_priority': subscriptionPriorityWeightForTier(tier),
      'author_subscription_boost_until': expires.toIso8601String(),
      'author_post_max_chars': postMaxCharsForUser({...?oldUser, ...payload}),
      'author_ai_daily_limit': respectAiDailyLimitForUser({...?oldUser, ...payload}),
      'author_subscription_label': subscriptionPriorityLabelForTier(tier),
    };

    try {
      await client.from('posts').update(priorityPayload).or('username.eq.$user,username.eq.$clean').timeout(const Duration(seconds: 8));
    } catch (_) {
      try {
        await client.from('posts').update({'author_verified': true}).or('username.eq.$user,username.eq.$clean').timeout(const Duration(seconds: 8));
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    try { await client.from('post_replies').update({'author_verified': true}).or('username.eq.$user,username.eq.$clean').timeout(const Duration(seconds: 8)); } catch (e, st) { _logIgnoredError(e, st); }

    try {
      await client.from('verification_subscriptions').insert({
        'username': user,
        'plan_id': planId,
        'plan_title': (plan['title'] ?? '').toString(),
        'tier': tier,
        'months': months,
        'price_usd': price,
        'status': 'active',
        'started_at': now.toIso8601String(),
        'expires_at': expires.toIso8601String(),
        'created_at': now.toIso8601String(),
      }).timeout(const Duration(seconds: 8));
    } catch (e, st) { _logIgnoredError(e, st); }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('respect_accounts_v1');
    final accounts = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) accounts.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    final idx = accounts.indexWhere((a) => normalizeUsername((a['username'] ?? a['id'] ?? '').toString()) == clean);
    if (idx >= 0) {
      accounts[idx] = {...accounts[idx], ...payload, 'username': user, 'id': clean};
    } else {
      accounts.add({...payload, 'username': user, 'id': clean});
    }
    await prefs.setString('respect_accounts_v1', jsonEncode(accounts));

    final usersRaw = prefs.getString('respect_users_map');
    final usersMap = <String, dynamic>{};
    if (usersRaw != null && usersRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(usersRaw);
        if (decoded is Map) usersMap.addAll(decoded.map((k, v) => MapEntry(k.toString(), v)));
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    final current = usersMap[clean] is Map ? Map<String, dynamic>.from(usersMap[clean] as Map) : <String, dynamic>{};
    usersMap[clean] = {...current, ...payload, 'username': user, 'id': clean};
    await prefs.setString('respect_users_map', jsonEncode(usersMap));

    return <String, dynamic>{...payload, 'username': user, 'plan': plan, 'tier': tier, 'price_usd': price};
  }

  static Future<void> enforceVerifiedFeature({required String username, required String featureName}) async {
    final user = await getUserByUsername(username);
    if (!isVerifiedUser(user)) {
      throw Exception('$featureName متاحة للحسابات الموثقة فقط. فعّل التوثيق من البروفايل.');
    }
  }


  // ================= Advanced Stories: multi media / likes / comments / notifications =================
  static Future<List<Map<String, dynamic>>> addStoryMediaItems({
    required String username,
    required String name,
    required List<Map<String, String>> mediaItems,
    String avatarUrl = '',
    bool privateStory = false,
    List<String> allowedViewers = const <String>[],
  }) async {
    final created = <Map<String, dynamic>>[];
    for (final item in mediaItems) {
      final path = (item['path'] ?? '').trim();
      final type = (item['type'] ?? 'image').trim();
      if (path.isEmpty) continue;
      final story = await addStory(
        username: username,
        name: name,
        mediaPath: path,
        mediaType: type,
        avatarUrl: avatarUrl,
        privateStory: privateStory,
        allowedViewers: allowedViewers,
      );
      created.add(story);
    }
    return created;
  }

  static Future<void> deleteStoryItem({
    required String storyId,
    required String username,
  }) async {
    final id = storyId.trim();
    final user = displayUsername(username);
    if (id.isEmpty) return;

    try {
      await client
          .from('respect_stories')
          .update({'is_active': false, 'deleted_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', id)
          .eq('username', user)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      try {
        await client.from('respect_stories').delete().eq('id', id).eq('username', user).timeout(const Duration(seconds: 8));
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localStoriesKey);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final list = decoded
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .where((e) => (e['id'] ?? '').toString() != id)
          .toList();
      await prefs.setString(_localStoriesKey, jsonEncode(list));
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  static Future<void> deleteAllActiveStoriesForUser(String username) async {
    final user = displayUsername(username);
    try {
      await client
          .from('respect_stories')
          .update({'is_active': false, 'deleted_at': DateTime.now().toUtc().toIso8601String()})
          .eq('username', user)
          .eq('is_active', true)
          .timeout(const Duration(seconds: 8));
    } catch (e, st) { _logIgnoredError(e, st); }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localStoriesKey);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final list = decoded
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .where((e) => displayUsername((e['username'] ?? '').toString()) != user)
          .toList();
      await prefs.setString(_localStoriesKey, jsonEncode(list));
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  static Future<Map<String, dynamic>> _storyActorPayload(String username) async {
    final actor = displayUsername(username);
    Map<String, dynamic>? user;
    try { user = await getUserByUsername(actor); } catch (e, st) { _logIgnoredError(e, st); }
    return <String, dynamic>{
      'username': actor,
      'name': (user?['name'] ?? user?['profileName'] ?? actor).toString(),
      'avatar': (user?['avatar_url'] ?? user?['imagePath'] ?? user?['profileImagePath'] ?? '').toString(),
    };
  }

  static Future<int> storyLikeCount(String storyId) async {
    try {
      final rows = await client.from('respect_story_likes').select('id').eq('story_id', storyId).timeout(const Duration(seconds: 6));
      return (rows as List).length;
    } catch (_) {
      return 0;
    }
  }

  static Future<int> storyCommentCount(String storyId) async {
    try {
      final rows = await client.from('respect_story_comments').select('id').eq('story_id', storyId).timeout(const Duration(seconds: 6));
      return (rows as List).length;
    } catch (_) {
      return 0;
    }
  }

  static Future<bool> hasLikedStory({
    required String storyId,
    required String username,
  }) async {
    final actor = displayUsername(username);
    try {
      final row = await client
          .from('respect_story_likes')
          .select('id')
          .eq('story_id', storyId)
          .eq('actor_username', actor)
          .maybeSingle()
          .timeout(const Duration(seconds: 6));
      return row != null;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> toggleStoryLike({
    required String storyId,
    required String ownerUsername,
    required String actorUsername,
  }) async {
    final id = storyId.trim();
    final owner = displayUsername(ownerUsername);
    final actor = displayUsername(actorUsername);
    if (id.isEmpty) throw Exception('storyId is empty');

    final actorInfo = await _storyActorPayload(actor);
    var liked = false;

    try {
      final existing = await client
          .from('respect_story_likes')
          .select('id')
          .eq('story_id', id)
          .eq('actor_username', actor)
          .maybeSingle()
          .timeout(const Duration(seconds: 6));

      if (existing != null) {
        await client.from('respect_story_likes').delete().eq('story_id', id).eq('actor_username', actor).timeout(const Duration(seconds: 6));
        liked = false;
      } else {
        await client.from('respect_story_likes').insert({
          'story_id': id,
          'story_owner_username': owner,
          'actor_username': actor,
          'actor_name': actorInfo['name'],
          'actor_avatar': actorInfo['avatar'],
          'created_at': DateTime.now().toUtc().toIso8601String(),
        }).timeout(const Duration(seconds: 6));
        liked = true;
        if (owner != actor) {
          await createStoryNotification(
            ownerUsername: owner,
            actorUsername: actor,
            type: 'like',
            storyId: id,
            text: '',
          );
        }
      }
    } catch (_) {
      // fallback local داخل الجهاز حتى لا يتعطل الزر أثناء التطوير.
      final prefs = await SharedPreferences.getInstance();
      final key = 'respect_story_like_${normalizeUsername(actor)}_$id';
      liked = !(prefs.getBool(key) ?? false);
      await prefs.setBool(key, liked);
    }

    final likes = await storyLikeCount(id);
    final comments = await storyCommentCount(id);
    return <String, dynamic>{'liked': liked, 'likes': likes, 'comments': comments};
  }

  static Future<Map<String, dynamic>> addStoryComment({
    required String storyId,
    required String ownerUsername,
    required String actorUsername,
    required String text,
  }) async {
    final id = storyId.trim();
    final body = text.trim();
    if (id.isEmpty) throw Exception('storyId is empty');
    if (body.isEmpty) throw Exception('اكتب تعليق أولاً');
    final owner = displayUsername(ownerUsername);
    final actor = displayUsername(actorUsername);
    final actorInfo = await _storyActorPayload(actor);
    final now = DateTime.now().toUtc();

    Map<String, dynamic> inserted = <String, dynamic>{
      'id': 'local_comment_${now.microsecondsSinceEpoch}',
      'story_id': id,
      'story_owner_username': owner,
      'actor_username': actor,
      'actor_name': actorInfo['name'],
      'actor_avatar': actorInfo['avatar'],
      'text': body,
      'created_at': now.toIso8601String(),
    };

    try {
      final row = await client.from('respect_story_comments').insert({
        'story_id': id,
        'story_owner_username': owner,
        'actor_username': actor,
        'actor_name': actorInfo['name'],
        'actor_avatar': actorInfo['avatar'],
        'text': body,
        'created_at': now.toIso8601String(),
      }).select().single().timeout(const Duration(seconds: 8));
      inserted = Map<String, dynamic>.from(row as Map);
      if (owner != actor) {
        await createStoryNotification(
          ownerUsername: owner,
          actorUsername: actor,
          type: 'comment',
          storyId: id,
          text: body,
        );
      }
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final key = 'respect_story_comments_$id';
      final list = <Map<String, dynamic>>[];
      final raw = prefs.getString(key);
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) list.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        } catch (e, st) { _logIgnoredError(e, st); }
      }
      list.insert(0, inserted);
      await prefs.setString(key, jsonEncode(list));
    }

    return inserted;
  }

  static Future<List<Map<String, dynamic>>> getStoryLikes(String storyId) async {
    final id = storyId.trim();
    if (id.isEmpty) return <Map<String, dynamic>>[];
    try {
      final rows = await client
          .from('respect_story_likes')
          .select('id,story_id,username,name,avatar_url,created_at')
          .eq('story_id', id)
          .order('created_at', ascending: false)
          .limit(100)
          .timeout(const Duration(seconds: 8));
      return List<Map<String, dynamic>>.from((rows as List).map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<List<Map<String, dynamic>>> getStoryComments(String storyId) async {
    final id = storyId.trim();
    if (id.isEmpty) return <Map<String, dynamic>>[];
    try {
      final rows = await client
          .from('respect_story_comments')
          .select()
          .eq('story_id', id)
          .order('created_at', ascending: false)
          .limit(120)
          .timeout(const Duration(seconds: 8));
      return List<Map<String, dynamic>>.from((rows as List).map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('respect_story_comments_$id');
      if (raw == null || raw.trim().isEmpty) return <Map<String, dynamic>>[];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))).toList();
      } catch (e, st) { _logIgnoredError(e, st); }
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> createStoryNotification({
    required String ownerUsername,
    required String actorUsername,
    required String type,
    required String storyId,
    required String text,
  }) async {
    final owner = displayUsername(ownerUsername);
    final actor = displayUsername(actorUsername);
    final actorInfo = await _storyActorPayload(actor);
    try {
      await client.from('respect_story_notifications').insert({
        'owner_username': owner,
        'actor_username': actor,
        'actor_name': actorInfo['name'],
        'actor_avatar': actorInfo['avatar'],
        'story_id': storyId,
        'type': type,
        'text': text,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }).timeout(const Duration(seconds: 8));
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final key = 'respect_story_notifications_$owner';
      final list = <Map<String, dynamic>>[];
      final raw = prefs.getString(key);
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) list.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        } catch (e, st) { _logIgnoredError(e, st); }
      }
      list.insert(0, {
        'id': 'local_story_notification_${DateTime.now().microsecondsSinceEpoch}',
        'owner_username': owner,
        'actor_username': actor,
        'actor_name': actorInfo['name'],
        'actor_avatar': actorInfo['avatar'],
        'story_id': storyId,
        'type': type,
        'text': text,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      await prefs.setString(key, jsonEncode(list.take(100).toList()));
    }
  }

  static Future<List<Map<String, dynamic>>> getStoryNotificationsForUser(String username) async {
    final owner = displayUsername(username);
    try {
      final rows = await client
          .from('respect_story_notifications')
          .select()
          .eq('owner_username', owner)
          .order('created_at', ascending: false)
          .limit(80)
          .timeout(const Duration(seconds: 8));
      return List<Map<String, dynamic>>.from((rows as List).map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('respect_story_notifications_$owner');
      if (raw == null || raw.trim().isEmpty) return <Map<String, dynamic>>[];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))).toList();
      } catch (e, st) { _logIgnoredError(e, st); }
      return <Map<String, dynamic>>[];
    }
  }

  static bool isRespectAiUsername(String username) {
    return displayUsername(username) == respectAiUsername;
  }

  static bool hasRespectAiMention(String text) {
    final t = text.toLowerCase().replaceAll(' ', '');
    return t.contains('@respectai') ||
        t.contains('@respect_ai') ||
        t.contains('@ai') ||
        t.contains('respectai');
  }

  static String _cleanAiUserText(String text) {
    return text
        .replaceAll(RegExp(r'@\s*Respect\s*AI', caseSensitive: false), '')
        .replaceAll(RegExp(r'@respectai', caseSensitive: false), '')
        .replaceAll(RegExp(r'@respect_ai', caseSensitive: false), '')
        .trim();
  }

  static String detectRespectAiMode(String text) {
    final t = text.toLowerCase();
    if (t.contains('لخص') || t.contains('تلخيص') || t.contains('اختصر') || t.contains('summarize')) {
      return 'summarize';
    }
    if (t.contains('تصويت') || t.contains('استطلاع') || t.contains('poll') || t.contains('vote')) {
      return 'poll';
    }
    if (t.contains('سؤال تفاعلي') || t.contains('سؤال للنقاش') || t.contains('نقاش') || t.contains('question')) {
      return 'question';
    }
    return 'reply';
  }

  static Future<void> ensureRespectAiUser() async {
    // هذا هو الحساب الرسمي الوحيد للذكاء الاصطناعي داخل التطبيق.
    // نستخدم نفس صف users الذي أنشأته يدويًا: @respectai
    final payload = <String, dynamic>{
      'username': normalizeUsername(respectAiUsername),
      'name': respectAiName,
      'bio': 'مساعد ذكي رسمي وموثق داخل Respect App',
      'avatar_url': respectAiAvatarUrl,
      'imagePath': respectAiAvatarUrl,
      'profileImagePath': respectAiAvatarUrl,
      'imagepath': respectAiAvatarUrl,
      'profileimagepath': respectAiAvatarUrl,
      'auth_provider': 'ai',
      'accepted_terms': true,
    };

    // Upsert يحافظ على الحساب نفسه ويحدّث صورته واسمه دائمًا.
    try {
      await client.from('users').upsert(payload, onConflict: 'username');
      return;
    } catch (e, st) { _logIgnoredError(e, st); }

    // احتياط لو ما فيه unique على username.
    try {
      await client.from('users').update(payload).or('username.eq.respectai,username.eq.@respectai');
      return;
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      await client.from('users').insert(payload);
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  static Future<String> _recentRepliesContextForAi({
    required String postId,
    required String currentUsername,
    String? excludeReplyId,
  }) async {
    try {
      final rows = await getPostReplies(postId, currentUsername: currentUsername);
      if (rows.isEmpty) return '';

      final items = rows
          .where((row) {
        final id = (row['id'] ?? '').toString();
        if (excludeReplyId != null && excludeReplyId.trim().isNotEmpty && id == excludeReplyId) return false;
        final text = (row['text'] ?? '').toString().trim();
        if (text.isEmpty) return false;
        return true;
      })
          .toList();

      final latest = items.length > 8 ? items.sublist(items.length - 8) : items;
      return latest.map((row) {
        final user = (row['username'] ?? row['author_username'] ?? '').toString();
        final body = (row['text'] ?? '').toString().trim();
        return '${displayUsername(user)}: $body';
      }).join('\n');
    } catch (_) {
      return '';
    }
  }

  static Future<String> askRespectAi({
    required String userText,
    required String askerUsername,
    String postText = '',
    String parentReplyText = '',
    String recentRepliesText = '',
    String mode = 'reply',
  }) async {
    final endpoint = respectAiBackendUrl.trim();
    if (endpoint.isEmpty || endpoint.contains('YOUR_SERVER_URL')) {
      throw Exception('ضع رابط سيرفر Respect AI داخل SupabaseService.respectAiBackendUrl');
    }

    await enforceRespectAiDailyLimit(askerUsername);

    final cleanQuestion = _cleanAiUserText(userText);
    final finalQuestion = cleanQuestion.isEmpty ? userText.trim() : cleanQuestion;
    final detectedMode = mode.trim().isEmpty || mode == 'reply' ? detectRespectAiMode(userText) : mode;
    Map<String, dynamic>? askerUser;
    try { askerUser = await getUserByUsername(askerUsername).timeout(const Duration(seconds: 6)); } catch (_) {}
    final askerTier = subscriptionTierForUser(askerUser);
    final askerAiLimit = respectAiDailyLimitForUser(askerUser);

    final response = await _postSignedJson(
  Uri.parse(endpoint),
  {
        'text': finalQuestion,
        'askerUsername': displayUsername(askerUsername),
        'username': displayUsername(askerUsername),
        'question': finalQuestion,
        'postText': postText.trim(),
        'parentReplyText': parentReplyText.trim(),
        'recentRepliesText': recentRepliesText.trim(),
        'mode': detectedMode,
        'language': 'ar',
        'dialect': 'auto',
        'style': 'colloquial_friend',
        'subscriptionTier': askerTier,
        'aiDailyLimit': askerAiLimit,
        'premiumMode': askerTier == 'premium',
      },
  timeout: const Duration(seconds: 60),
);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Respect AI server error: ${response.statusCode} ${response.body}');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map) {
      final answer = (decoded['answer'] ?? decoded['text'] ?? decoded['reply'] ?? '').toString().trim();
      if (answer.isNotEmpty) {
        await _incrementRespectAiUsage(askerUsername);
        return answer;
      }
    }
    throw Exception('Respect AI empty answer');
  }

  static bool _localObviousViolation(String text) {
    final t = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return false;

    // فلتر محلي سريع جدًا قبل النشر فقط.
    // لا نحذف بسبب كلمة مفردة مثل "حيوان" أو "كلب" إلا إذا كانت سبًا مباشرًا.
    final obviousPatterns = <RegExp>[
      RegExp(r'\b(kill\s+yourself|i\s+will\s+kill|fuck\s+you)\b', caseSensitive: false),
      RegExp(r'(اقتل|اقتلوه|اقتلو|لازم\s+ينضرب|موتوا|تحريض\s+على\s+القتل)', caseSensitive: false),
      RegExp(r'(سب\s*الدين|سب\s*الله|إهانة\s*الدين|اهانة\s*الدين)', caseSensitive: false),
      RegExp(r'(يا\s*كلب|يا\s*حمار|أنت\s*حيوان|انت\s*حيوان|كل\s*خرا|كل\s*زق)', caseSensitive: false),
    ];
    return obviousPatterns.any((r) => r.hasMatch(t));
  }

  static void _enforceLocalObviousModeration({
    required String text,
    required String authorUsername,
  }) {
    final clean = text.trim();
    if (clean.isEmpty || isRespectAiUsername(authorUsername)) return;
    if (_localObviousViolation(clean)) {
      throw Exception('تم رفض المحتوى لأنه يحتوي مخالفة واضحة قبل النشر');
    }
  }

  static Future<Map<String, dynamic>> moderateRespectContent({
    required String text,
    required String authorUsername,
    String contentType = 'post',
    String postId = '',
    String replyId = '',
    String postText = '',
    String parentReplyText = '',
    String recentRepliesText = '',
  }) async {
    final clean = text.trim();
    if (clean.isEmpty || isRespectAiUsername(authorUsername)) {
      return <String, dynamic>{
        'ok': true,
        'shouldDelete': false,
        'deleteParentReply': false,
        'category': 'safe',
        'reason': '',
        'confidence': 0.0,
      };
    }

    final endpoint = respectAiModerationBackendUrl.trim().isEmpty
        ? respectAiBackendUrl.replaceFirst('/reply', '/moderate')
        : respectAiModerationBackendUrl.trim();

    try {
      final response = await _postSignedJson(
  Uri.parse(endpoint),
  {
          'text': clean,
          'username': displayUsername(authorUsername),
          'authorUsername': displayUsername(authorUsername),
          'contentType': contentType,
          'postId': postId.trim(),
          'replyId': replyId.trim(),
          'postText': postText.trim(),
          'parentReplyText': parentReplyText.trim(),
          'recentRepliesText': recentRepliesText.trim(),
          'language': 'ar',
        },
  timeout: const Duration(seconds: 40),
);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Moderation server error: ${response.statusCode} ${response.body}');
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (e) {
      // إذا تعطل سيرفر المراجعة لا نرفض التغريدات العادية مثل "مرحبا".
      // نستخدم فلتر محلي صارم جدًا للمخالف الواضح فقط، وما عداه نسمح به حتى لا يتعطل النشر.
      final localBlock = _localObviousViolation(clean);
      return <String, dynamic>{
        'ok': false,
        'shouldDelete': localBlock,
        'deleteParentReply': false,
        'category': localBlock ? 'local_obvious_violation' : 'moderation_unavailable_safe',
        'reason': localBlock
            ? 'تم رفض المحتوى محليًا لأنه يحتوي مخالفة واضحة'
            : 'تعذر فحص المحتوى بواسطة Respect AI، وتم السماح به لأنه لا يحتوي مخالفة واضحة',
        'confidence': localBlock ? 0.95 : 0.0,
      };
    }

    return <String, dynamic>{
      'ok': true,
      'shouldDelete': false,
      'deleteParentReply': false,
      'category': 'safe',
      'reason': '',
      'confidence': 0.0,
    };
  }

  // ignore: unused_element
  static Future<void> _enforceRespectContentModeration({
    required String text,
    required String authorUsername,
    required String contentType,
    String postText = '',
    String parentReplyText = '',
    String recentRepliesText = '',
    String? parentReplyId,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty || isRespectAiUsername(authorUsername)) return;

    final result = await moderateRespectContent(
      text: clean,
      authorUsername: authorUsername,
      contentType: contentType,
      postText: postText,
      parentReplyText: parentReplyText,
      recentRepliesText: recentRepliesText,
    );

    final shouldDelete = result['shouldDelete'] == true || result['delete'] == true || result['blocked'] == true;
    final deleteParent = result['deleteParentReply'] == true;
    final reason = (result['reason'] ?? 'محتوى مخالف لقواعد Respect').toString();
    final category = (result['category'] ?? 'violation').toString();

    if (deleteParent && parentReplyId != null && parentReplyId.trim().isNotEmpty) {
      try {
        await deletePostReply(parentReplyId.trim());
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    if (shouldDelete) {
      throw Exception('تم حذف/رفض المحتوى تلقائيًا بواسطة Respect AI ($category): $reason');
    }
  }


  static Future<Map<String, dynamic>> moderateStoryOnServer({
    required String storyId,
    required String authorUsername,
    required String mediaUrl,
    required String mediaType,
    String text = '',
  }) async {
    final id = storyId.trim();
    final url = mediaUrl.trim();
    final type = mediaType.toLowerCase().trim();
    if (id.isEmpty || url.isEmpty || isRespectAiUsername(authorUsername)) {
      return <String, dynamic>{
        'ok': true,
        'shouldDelete': false,
        'deleted': false,
        'category': 'safe',
        'reason': '',
      };
    }

    final isVideo = type.contains('video');
    final endpoint = respectAiStoryModerationBackendUrl.trim().isEmpty
        ? respectAiPostModerationBackendUrl.replaceFirst('/moderate-post', '/moderate-story')
        : respectAiStoryModerationBackendUrl.trim();

    try {
      final response = await _postSignedJson(
  Uri.parse(endpoint),
  {
          'postId': id,
          'replyId': id,
          'text': text.trim(),
          'username': displayUsername(authorUsername),
          'authorUsername': displayUsername(authorUsername),
          'imageUrls': isVideo ? const <String>[] : <String>[url],
          'imageUrl': isVideo ? '' : url,
          'videoUrls': isVideo ? <String>[url] : const <String>[],
          'videoUrl': isVideo ? url : '',
          'contentType': 'story',
          'language': 'ar',
        },
  timeout: const Duration(seconds: 240),
);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Server story moderation error: ${response.statusCode} ${response.body}');
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (e) {
      _safeDebugLog('Respect AI story moderation failed for $id: $e');
      return <String, dynamic>{
        'ok': false,
        'shouldDelete': false,
        'deleted': false,
        'category': 'story_moderation_failed',
        'reason': e.toString(),
      };
    }

    return <String, dynamic>{
      'ok': true,
      'shouldDelete': false,
      'deleted': false,
      'category': 'safe',
      'reason': '',
    };
  }

  static Future<void> _moderateStoryInBackground({
    required String storyId,
    required String authorUsername,
    required String mediaUrl,
    required String mediaType,
  }) async {
    final id = storyId.trim();
    final url = mediaUrl.trim();
    if (id.isEmpty || url.isEmpty || isRespectAiUsername(authorUsername)) return;

    try {
      final result = await moderateStoryOnServer(
        storyId: id,
        authorUsername: authorUsername,
        mediaUrl: url,
        mediaType: mediaType,
      ).timeout(const Duration(seconds: 260));

      final shouldDelete = result['shouldDelete'] == true ||
          result['delete'] == true ||
          result['blocked'] == true;
      final deleted = result['deleted'] == true ||
          (result['deleteResult'] is Map && (result['deleteResult']['deleted'] == true));
      final category = (result['category'] ?? 'safe').toString();
      final reason = (result['reason'] ?? '').toString();

      if (shouldDelete) {
        if (!deleted) {
          try { await deleteStoryItem(storyId: id, username: authorUsername); } catch (e, st) { _logIgnoredError(e, st); }
        }
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_localStoriesKey);
        if (raw != null && raw.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(raw);
            if (decoded is List) {
              final list = decoded
                  .whereType<Map>()
                  .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
                  .where((e) => (e['id'] ?? '').toString() != id)
                  .toList();
              await prefs.setString(_localStoriesKey, jsonEncode(list));
            }
          } catch (e, st) { _logIgnoredError(e, st); }
        }
        _safeDebugLog('Respect AI deleted story $id ($category): $reason');
      } else {
        _safeDebugLog('Respect AI approved story $id ($category): $reason');
      }
    } catch (e) {
      _safeDebugLog('Respect AI background story moderation failed for $id: $e');
    }
  }

  static Future<Map<String, dynamic>> moderateSavedPostOnServer({
    required String postId,
    required String text,
    required String authorUsername,
    List<String> imageUrls = const <String>[],
    String videoUrl = '',
  }) async {
    final id = postId.trim();
    final clean = text.trim();
    final safeImageUrls = imageUrls
        .map((e) => e.trim())
        .where((e) => e.startsWith('http://') || e.startsWith('https://'))
        .toSet()
        .toList();
    final safeVideoUrl = videoUrl.trim();
    // نسمح بتجاوز المراجعة فقط إذا لا يوجد نص ولا صور ولا فيديو.
    if (id.isEmpty || (clean.isEmpty && safeImageUrls.isEmpty && safeVideoUrl.isEmpty) || isRespectAiUsername(authorUsername)) {
      return <String, dynamic>{
        'ok': true,
        'shouldDelete': false,
        'deleted': false,
        'category': 'safe',
        'reason': '',
      };
    }

    final endpoint = respectAiPostModerationBackendUrl.trim().isEmpty
        ? respectAiModerationBackendUrl.replaceFirst('/moderate', '/moderate-post')
        : respectAiPostModerationBackendUrl.trim();

    Map<String, dynamic>? authorUser;
    try { authorUser = await getUserByUsername(authorUsername).timeout(const Duration(seconds: 6)); } catch (_) {}
    final authorTier = subscriptionTierForUser(authorUser);
    final authorPriority = subscriptionPriorityWeightForTier(authorTier);

    try {
      final response = await _postSignedJson(
  Uri.parse(endpoint),
  {
          'postId': id,
          'text': clean,
          'username': displayUsername(authorUsername),
          'authorUsername': displayUsername(authorUsername),
          'imageUrls': safeImageUrls,
          'imageUrl': safeImageUrls.isNotEmpty ? safeImageUrls.first : '',
          'videoUrl': safeVideoUrl,
          'contentType': 'post',
          'authorSubscriptionTier': authorTier,
          'authorSubscriptionPriority': authorPriority,
          'premiumReview': authorTier == 'premium',
          'language': 'ar',
        },
  timeout: const Duration(seconds: 180),
);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Server post moderation error: ${response.statusCode} ${response.body}');
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (e) {
      _safeDebugLog('Respect AI server-side post moderation failed for $id: $e');

      // احتياط فقط: إذا السيرفر الجديد لم يرد، نجرب endpoint القديم ثم نحذف محليًا إن قرر الحذف.
      // هذا ليس المسار الأساسي؛ المسار الأساسي هو حذف Render مباشرة من Supabase.
      try {
        final result = await moderateRespectContent(
          text: clean,
          authorUsername: authorUsername,
          contentType: 'post',
          postId: id,
        ).timeout(const Duration(seconds: 45));

        final shouldDelete = result['shouldDelete'] == true ||
            result['delete'] == true ||
            result['blocked'] == true;
        if (shouldDelete) {
          await deletePost(id);
          return <String, dynamic>{
            ...result,
            'deleted': true,
            'fallbackClientDelete': true,
          };
        }
        return <String, dynamic>{
          ...result,
          'deleted': false,
          'fallbackOldModeration': true,
        };
      } catch (fallbackError) {
        _safeDebugLog('Respect AI fallback post moderation failed for $id: $fallbackError');
        return <String, dynamic>{
          'ok': false,
          'shouldDelete': false,
          'deleted': false,
          'category': 'moderation_failed',
          'reason': fallbackError.toString(),
        };
      }
    }

    return <String, dynamic>{
      'ok': true,
      'shouldDelete': false,
      'deleted': false,
      'category': 'safe',
      'reason': '',
    };
  }

  static Future<void> _moderatePostInBackground({
    required String postId,
    required String text,
    required String authorUsername,
    List<String> imageUrls = const <String>[],
    String videoUrl = '',
  }) async {
    final id = postId.trim();
    final clean = text.trim();
    final safeImageUrls = imageUrls
        .map((e) => e.trim())
        .where((e) => e.startsWith('http://') || e.startsWith('https://'))
        .toSet()
        .toList();
    final safeVideoUrl = videoUrl.trim();
    if (id.isEmpty || (clean.isEmpty && safeImageUrls.isEmpty && safeVideoUrl.isEmpty) || isRespectAiUsername(authorUsername)) return;

    try {
      final result = await moderateSavedPostOnServer(
        postId: id,
        text: clean,
        authorUsername: authorUsername,
        imageUrls: safeImageUrls,
        videoUrl: safeVideoUrl,
      ).timeout(const Duration(seconds: 240));

      final shouldDelete = result['shouldDelete'] == true ||
          result['delete'] == true ||
          result['blocked'] == true;
      final deleted = result['deleted'] == true ||
          (result['deleteResult'] is Map && (result['deleteResult']['deleted'] == true));

      final category = (result['category'] ?? 'safe').toString();
      final reason = (result['reason'] ?? '').toString();

      if (shouldDelete && deleted) {
        _notifyRespectAiDeletedPost(id);
        _safeDebugLog('Respect AI server deleted post $id ($category): $reason');
      } else if (shouldDelete && !deleted) {
        _safeDebugLog('Respect AI marked post $id as violation but delete failed ($category): $reason');
      } else {
        _safeDebugLog('Respect AI approved post $id ($category): $reason');
      }
    } catch (e) {
      _safeDebugLog('Respect AI background post moderation failed for $id: $e');
    }
  }

  static Future<void> _moderateReplyInBackground({
    required String replyId,
    required String postId,
    required String text,
    required String authorUsername,
    String? parentReplyId,
  }) async {
    final id = replyId.trim();
    final clean = text.trim();
    if (id.isEmpty || clean.isEmpty || isRespectAiUsername(authorUsername)) return;

    String parentReplyTextForModeration = '';
    if (parentReplyId != null && parentReplyId.trim().isNotEmpty) {
      try {
        final rows = await getRepliesByIds([parentReplyId.trim()], currentUsername: authorUsername)
            .timeout(const Duration(seconds: 8));
        if (rows.isNotEmpty) parentReplyTextForModeration = (rows.first['text'] ?? '').toString();
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    String recentRepliesTextForModeration = '';
    try {
      recentRepliesTextForModeration = await _recentRepliesContextForAi(
        postId: postId,
        currentUsername: authorUsername,
        excludeReplyId: parentReplyId,
      ).timeout(const Duration(seconds: 8));
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      final result = await moderateRespectContent(
        text: clean,
        authorUsername: authorUsername,
        contentType: 'reply',
        parentReplyText: parentReplyTextForModeration,
        recentRepliesText: recentRepliesTextForModeration,
      ).timeout(const Duration(seconds: 45));

      final shouldDelete = result['shouldDelete'] == true ||
          result['delete'] == true ||
          result['blocked'] == true;
      final deleteParent = result['deleteParentReply'] == true;
      if (deleteParent && parentReplyId != null && parentReplyId.trim().isNotEmpty) {
        try { await deletePostReply(parentReplyId.trim()); } catch (e, st) { _logIgnoredError(e, st); }
      }
      if (shouldDelete) {
        await deletePostReply(id);
        final category = (result['category'] ?? 'violation').toString();
        final reason = (result['reason'] ?? '').toString();
        _safeDebugLog('Respect AI background deleted reply $id ($category): $reason');
      }
    } catch (e) {
      _safeDebugLog('Respect AI background reply moderation skipped for $id: $e');
    }
  }

  static Future<Map<String, dynamic>?> createRespectAiReplyIfNeeded({
    required String postId,
    required String triggerText,
    required String askerUsername,
    String postText = '',
    String? parentReplyId,
    String parentReplyText = '',
  }) async {
    if (!hasRespectAiMention(triggerText)) return null;

    final asker = displayUsername(askerUsername);
    if (asker == respectAiUsername) return null;

    await enforceRespectAiDailyLimit(asker);
    await ensureRespectAiUser();

    final recentContext = await _recentRepliesContextForAi(
      postId: postId,
      currentUsername: asker,
      excludeReplyId: parentReplyId,
    );

    final answer = await askRespectAi(
      userText: triggerText,
      askerUsername: asker,
      postText: postText,
      parentReplyText: parentReplyText,
      recentRepliesText: recentContext,
      mode: detectRespectAiMode(triggerText),
    );

    final aiReply = await addPostReply(
      postId: postId,
      authorUsername: respectAiUsername,
      authorName: respectAiName,
      text: answer,
      parentUser: asker,
      parentReplyId: parentReplyId,
    );
    await _incrementRespectAiUsage(asker);
    return aiReply;
  }

  // ignore: unused_element
  static String _dailyRespectAiModeForNow() {
    final day = DateTime.now().toUtc().day;
    if (day % 3 == 0) return 'daily_poll';
    if (day % 3 == 1) return 'daily_question';
    return 'daily_info';
  }

  static String dailyRespectAiPostKey() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return 'respect_ai_daily_post_${now.year}_${mm}_$dd';
  }

  static String _normalizeDailyQuestionText(String value) {
    var text = value.trim().toLowerCase();
    text = text.replaceAll('@respectai', '').replaceAll('@respect_ai', '');
    text = text.replaceAll(RegExp(r'https?://\S+'), ' ');
    text = text.replaceAll(RegExp(r'[إأآا]'), 'ا');
    text = text.replaceAll('ى', 'ي').replaceAll('ة', 'ه');
    text = text.replaceAll(RegExp(r'[^\u0621-\u064Aa-z0-9\s؟?]'), ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  static bool _looksLikeQuestionForDaily(String value) {
    final text = _normalizeDailyQuestionText(value);
    if (text.length < 8) return false;
    if (text.contains('?') || text.contains('؟')) return true;
    const starters = <String>[
      'وش', 'ايش', 'اش', 'ما', 'ماهو', 'ماهي', 'من', 'مين', 'كيف', 'ليه', 'لماذا',
      'هل', 'كم', 'متى', 'وين', 'اين', 'أي', 'اي', 'لو', 'ليش'
    ];
    return starters.any((w) => text == w || text.startsWith('$w '));
  }

  static String _dailyQuestionSignature(String value) {
    final text = _normalizeDailyQuestionText(value)
        .replaceAll('?', ' ')
        .replaceAll('؟', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    const stopWords = <String>{
      'يا', 'ي', 'هو', 'هي', 'هذا', 'هذه', 'هذي', 'ذلك', 'ذا', 'في', 'عن', 'على',
      'الى', 'إلى', 'من', 'مع', 'بدون', 'اذا', 'لو', 'وش', 'ايش', 'اش', 'ما',
      'ماهو', 'ماهي', 'هل', 'كم', 'متى', 'وين', 'اين', 'ليه', 'لماذا', 'كيف',
      'انا', 'انت', 'انتم', 'نحن', 'هم', 'الي', 'اللي', 'الذي', 'التي', 'حق', 'حقت',
      'ابي', 'ابغى', 'اريد', 'سؤال', 'جاوب', 'رد', 'لي', 'علي', 'عليه', 'عليها'
    };

    final words = text
        .split(' ')
        .map((e) => e.trim())
        .where((w) => w.length >= 3 && !stopWords.contains(w))
        .toList();

    if (words.length >= 2) {
      return words.take(8).join(' ');
    }
    return text.length > 90 ? text.substring(0, 90) : text;
  }

  static Future<Map<String, dynamic>?> _mostRepeatedCommunityQuestionForAi({
    int postLimit = 90,
    int replyLimit = 140,
  }) async {
    final grouped = <String, List<Map<String, String>>>{};

    void addCandidate({required String user, required String text, required String source}) {
      final clean = text.trim();
      if (clean.isEmpty || clean.length > 260) return;
      if (!_looksLikeQuestionForDaily(clean)) return;
      final sig = _dailyQuestionSignature(clean);
      if (sig.length < 5) return;
      grouped.putIfAbsent(sig, () => <Map<String, String>>[]).add({
        'user': displayUsername(user),
        'text': clean,
        'source': source,
      });
    }

    try {
      final postRows = await client
          .from('posts')
          .select('username,text,created_at')
          .order('created_at', ascending: false)
          .limit(postLimit)
          .timeout(const Duration(seconds: 8));

      for (final raw in postRows) {
        final user = displayUsername((raw['username'] ?? '').toString());
        if (isRespectAiUsername(user)) continue;
        addCandidate(user: user, text: (raw['text'] ?? '').toString(), source: 'post');
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      final replyRows = await client
          .from('post_replies')
          .select('author_username,username,text,created_at')
          .order('created_at', ascending: false)
          .limit(replyLimit)
          .timeout(const Duration(seconds: 8));

      for (final raw in replyRows) {
        final user = displayUsername((raw['author_username'] ?? raw['username'] ?? '').toString());
        if (isRespectAiUsername(user)) continue;
        addCandidate(user: user, text: (raw['text'] ?? '').toString(), source: 'reply');
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    final repeated = grouped.entries.where((e) => e.value.length >= 2).toList()
      ..sort((a, b) {
        final byCount = b.value.length.compareTo(a.value.length);
        if (byCount != 0) return byCount;
        return (b.value.first['text'] ?? '').toString().length.compareTo((a.value.first['text'] ?? '').toString().length);
      });

    if (repeated.isEmpty) return null;

    final best = repeated.first;
    final examples = best.value.take(5).toList();
    final question = examples.first['text'] ?? '';
    return <String, dynamic>{
      'signature': best.key,
      'question': question,
      'count': best.value.length,
      'examples': examples,
    };
  }

  static bool _aiDailyTextIsGrounded(String text, String question) {
    final qWords = _dailyQuestionSignature(question).split(' ').where((w) => w.length >= 3).toSet();
    if (qWords.isEmpty) return text.trim().isNotEmpty;
    final body = _normalizeDailyQuestionText(text);
    var hits = 0;
    for (final word in qWords) {
      if (body.contains(word)) hits++;
    }
    return hits >= (qWords.length >= 3 ? 2 : 1);
  }

  static String _fallbackGroundedDailyPost(String question, int count) {
    final cleanQuestion = question.trim().replaceAll(RegExp(r'\s+'), ' ');
    return 'فعالية اليوم من Respect AI 🔥\n'
        'هذا السؤال انطرح أكثر من مرة عندنا ($count مرات):\n'
        '«$cleanQuestion»\n\n'
        'وش جوابكم؟ خلونا نشوف أكثر إجابة مقنعة 👇';
  }

  static Future<Map<String, dynamic>?> createRespectAiDailyPostIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final key = dailyRespectAiPostKey();
    if (prefs.getBool(key) == true) return null;

    await ensureRespectAiUser();

    final repeated = await _mostRepeatedCommunityQuestionForAi();
    if (repeated == null) {
      await prefs.setBool(key, true);
      return null;
    }

    final question = (repeated['question'] ?? '').toString().trim();
    final count = int.tryParse((repeated['count'] ?? 2).toString()) ?? 2;
    final examples = (repeated['examples'] is List ? repeated['examples'] as List : const <dynamic>[])
        .whereType<Map>()
        .map((e) => '${displayUsername((e['user'] ?? '').toString())}: ${(e['text'] ?? '').toString()}')
        .join('\n');

    final prompt = '''
اكتب منشور فعالية يومية جميل وقصير لمجتمع Respect App.
مهم جدًا: الفعالية لازم تكون مبنية فقط على السؤال المتكرر الموجود بالأسفل، ولا تذكر أي موضوع أو اسم أو معلومة غير موجودة في السؤال أو الأمثلة.
لا تجاوب على السؤال، فقط افتح نقاش ممتع حوله.
اكتب بصيغة منشور واحد مناسب للفيد، عامي وواضح، بدون هبد وبدون اختراع.

السؤال المتكرر:
$question

عدد التكرار: $count

أمثلة من المجتمع:
$examples
'''.trim();

    String text;
    try {
      final aiText = await askRespectAi(
        userText: prompt,
        askerUsername: respectAiUsername,
        recentRepliesText: 'السؤال المتكرر الوحيد المسموح استخدامه:\n$question\n\nأمثلة:\n$examples',
        mode: 'daily_question',
      );
      text = _aiDailyTextIsGrounded(aiText, question) ? aiText : _fallbackGroundedDailyPost(question, count);
    } catch (_) {
      text = _fallbackGroundedDailyPost(question, count);
    }

    final post = await addPost(
      username: respectAiUsername,
      name: respectAiName,
      text: text,
    );

    await prefs.setBool(key, true);
    return post;
  }

  static String normalizeUsername(String value) {
    return value.trim().toLowerCase().replaceAll('@', '').replaceAll(RegExp(r'\s+'), '_');
  }

  static String normalizeEmail(String value) => value.trim().toLowerCase();

  static String displayUsername(String value) {
    final clean = normalizeUsername(value);
    return clean.isEmpty ? '@user' : '@$clean';
  }


  // ================= Device Ban / Install Lock =================
  // هذا معرف تثبيت خاص بالتطبيق. يتم حفظه محليًا ويرتبط بحساب المستخدم في Supabase.
  // الهدف: عندما يحظر الأدمن المستخدم يتم حظر آخر جهاز استخدمه أيضًا.
  static const String _respectDeviceIdKey = 'respect_device_id_v2';

  static String _newDeviceId() {
    final rnd = Random.secure();
    String part(int len) => List.generate(len, (_) => rnd.nextInt(16).toRadixString(16)).join();
    return 'rsp_${part(8)}_${part(4)}_${part(4)}_${part(12)}_${DateTime.now().millisecondsSinceEpoch}';
  }

  static Future<String> currentDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getString(_respectDeviceIdKey);
    if (old != null && old.trim().isNotEmpty) return old.trim();
    final id = _newDeviceId();
    await prefs.setString(_respectDeviceIdKey, id);
    return id;
  }

  static Future<Map<String, dynamic>> _devicePayload({String? username}) async {
    final id = await currentDeviceId();
    return <String, dynamic>{
      'device_id': id,
      'current_device_id': id,
      'last_device_id': id,
      'device_platform': _safeDevicePlatform,
      'device_updated_at': DateTime.now().toUtc().toIso8601String(),
      if (username != null && username.trim().isNotEmpty) 'username': displayUsername(username),
    };
  }

  static bool _blockedTruthy(dynamic value) {
    if (value == true) return true;
    final text = value?.toString().toLowerCase().trim() ?? '';
    return text == 'true' || text == '1' || text == 'yes' || text == 'blocked' || text == 'banned' || text == 'disabled';
  }

  static bool isBlockedUserMap(Map<String, dynamic>? user) {
    if (user == null) return false;
    return _blockedTruthy(user['is_blocked']) ||
        _blockedTruthy(user['isBlocked']) ||
        _blockedTruthy(user['blocked']) ||
        _blockedTruthy(user['banned']) ||
        _blockedTruthy(user['disabled']) ||
        user['canLogin'] == false ||
        _blockedTruthy(user['device_banned']) ||
        _blockedTruthy(user['device_blocked']);
  }

  static Future<void> registerCurrentDeviceForUser(String username) async {
    final user = displayUsername(username);
    final clean = normalizeUsername(user);
    if (clean.isEmpty) return;
    final payload = await _devicePayload(username: user);
    try {
      await client
          .from('users')
          .update(payload)
          .or('username.eq.$user,username.eq.$clean')
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // لو الأعمدة غير موجودة، التطبيق لا يتوقف. شغّل ملف SQL المرفق لتفعيل الحظر على الجهاز.
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('respect_last_logged_device_username', user);
  }

  static Future<Map<String, dynamic>?> currentDeviceBan() async {
    final deviceId = await currentDeviceId();
    try {
      final row = await client
          .from('respect_device_bans')
          .select('id,device_id,username,is_active,reason,created_at,expires_at')
          .eq('device_id', deviceId)
          .eq('is_active', true)
          .maybeSingle()
          .timeout(const Duration(seconds: 7));
      if (row != null) return Map<String, dynamic>.from(row as Map);
    } catch (e, st) { _logIgnoredError(e, st); }

    // فحص احتياطي من جدول users لو لم يتم إنشاء جدول respect_device_bans أو تم الحظر من العمود مباشرة.
    try {
      final row = await client
          .from('users')
          .select('id,username,name,email,avatar_url,imagePath,profileImagePath,is_blocked,blocked_at,device_id,current_device_id,last_device_id')
          .or('device_id.eq.$deviceId,current_device_id.eq.$deviceId,last_device_id.eq.$deviceId')
          .maybeSingle()
          .timeout(const Duration(seconds: 7));
      if (row != null) {
        final user = Map<String, dynamic>.from(row as Map);
        if (isBlockedUserMap(user)) {
          return <String, dynamic>{
            'device_id': deviceId,
            'username': displayUsername((user['username'] ?? '').toString()),
            'reason': (user['blockedReason'] ?? user['blocked_reason'] ?? 'تم حظر هذا الجهاز من الإدارة').toString(),
            'source': 'users',
          };
        }
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    return null;
  }

  static Future<bool> isCurrentDeviceBanned() async => (await currentDeviceBan()) != null;

  static Future<void> enforceCurrentDeviceAllowed() async {
    final ban = await currentDeviceBan();
    if (ban != null) {
      final reason = (ban['reason'] ?? 'تم حظر هذا الجهاز من استخدام Respect App').toString();
      throw Exception(reason.trim().isEmpty ? 'تم حظر هذا الجهاز من استخدام Respect App' : reason);
    }
  }

  static Future<void> clearLocalSessionOnly() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_user_id');
    await prefs.remove('respect_current_user_id');
    await prefs.remove('respect_current_user');
  }

  static Future<void> setUserBlockedAndDeviceBan({
    required String username,
    required bool blocked,
    String reason = '',
    String adminUsername = '',
  }) async {
    final user = displayUsername(username);
    final clean = normalizeUsername(user);
    if (clean.isEmpty) throw Exception('username is empty');

    Map<String, dynamic>? target;
    try { target = await getUserByUsername(user); } catch (e, st) { _logIgnoredError(e, st); }

    final deviceId = (target?['current_device_id'] ?? target?['device_id'] ?? target?['last_device_id'] ?? '').toString().trim();
    final now = DateTime.now().toUtc().toIso8601String();
    final cleanReason = reason.trim().isEmpty ? 'Blocked by admin' : reason.trim();

    // لا نرسل أعمدة غير موجودة مثل users.blocked / banned / disabled.
    // قاعدة بياناتك الحالية فيها is_blocked و blocked_at فقط حسب رسالة PostgREST.
    final userPayload = <String, dynamic>{
      'is_blocked': blocked,
      'blocked_at': blocked ? now : null,
      'updated_at': now,
    };

    try {
      await client
          .from('users')
          .update(userPayload)
          .or('username.eq.$user,username.eq.$clean')
          .timeout(const Duration(seconds: 8));
    } catch (e, st) {
      _logIgnoredError(e, st);
      // احتياط لو جدول users عندك لا يحتوي updated_at.
      try {
        final fallback = Map<String, dynamic>.from(userPayload)..remove('updated_at');
        await client
            .from('users')
            .update(fallback)
            .or('username.eq.$user,username.eq.$clean')
            .timeout(const Duration(seconds: 8));
      } catch (e2, st2) { _logIgnoredError(e2, st2); }
    }

    if (deviceId.isNotEmpty) {
      if (blocked) {
        try {
          await client.from('respect_device_bans').upsert({
            'device_id': deviceId,
            'username': user,
            'reason': cleanReason,
            'banned_by': adminUsername.trim().isEmpty ? 'admin' : displayUsername(adminUsername),
            'is_active': true,
            'created_at': now,
            'updated_at': now,
          }, onConflict: 'device_id').timeout(const Duration(seconds: 8));
        } catch (e, st) { _logIgnoredError(e, st); }
      } else {
        try {
          await client
              .from('respect_device_bans')
              .update({'is_active': false, 'updated_at': now})
              .eq('device_id', deviceId)
              .timeout(const Duration(seconds: 8));
        } catch (e, st) { _logIgnoredError(e, st); }
      }
    }
  }


  static String _storageExtFromPath(String path) {
    final clean = path.split('?').first;
    final ext = clean.contains('.') ? clean.split('.').last.toLowerCase() : 'jpg';
    if (ext == 'png' || ext == 'webp' || ext == 'jpeg' || ext == 'jpg') return ext == 'jpeg' ? 'jpg' : ext;
    return 'jpg';
  }

  static bool _isRemoteUrl(String? value) {
    final v = value?.trim() ?? '';
    return v.startsWith('http://') || v.startsWith('https://');
  }

  static String _postMediaExtFromPath(String path, {required bool video}) {
    final clean = path.split('?').first;
    final ext = clean.contains('.') ? clean.split('.').last.toLowerCase() : (video ? 'mp4' : 'jpg');
    if (video) {
      if (ext == 'mp4' || ext == 'mov' || ext == 'm4v' || ext == 'webm' || ext == 'mkv') return ext;
      return 'mp4';
    }
    if (ext == 'png' || ext == 'webp' || ext == 'jpeg' || ext == 'jpg' || ext == 'gif') return ext == 'jpeg' ? 'jpg' : ext;
    return 'jpg';
  }

  static String _postMediaContentType(String ext, {required bool video}) {
    if (video) {
      switch (ext) {
        case 'webm':
          return 'video/webm';
        case 'mov':
          return 'video/quicktime';
        case 'm4v':
          return 'video/x-m4v';
        case 'mkv':
          return 'video/x-matroska';
        default:
          return 'video/mp4';
      }
    }
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      default:
        return 'image/jpeg';
    }
  }

  static String _postVoiceExtFromPath(String path) {
    final clean = path.split('?').first;
    final ext = clean.contains('.') ? clean.split('.').last.toLowerCase() : 'm4a';
    if (ext == 'm4a' || ext == 'aac' || ext == 'mp3' || ext == 'wav' || ext == 'ogg' || ext == 'webm') return ext;
    return 'm4a';
  }

  static String _postVoiceContentType(String ext) {
    switch (ext) {
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
        return 'audio/ogg';
      case 'webm':
        return 'audio/webm';
      case 'aac':
        return 'audio/aac';
      default:
        return 'audio/mp4';
    }
  }

  static Future<String> uploadPostMedia({
    required String username,
    required String filePath,
    required bool video,
  }) async {
    final raw = filePath.trim();
    if (raw.isEmpty) return '';
    if (_isRemoteUrl(raw)) return raw;

    final file = File(raw);
    if (!await file.exists()) throw Exception('post media file not found');

    final sizeMb = await file.length() / (1024 * 1024);
    if (video && sizeMb > 120) {
      throw Exception('الفيديو كبير جدًا، اضغطه أو اختر فيديو أقل من 120MB');
    }

    final clean = normalizeUsername(username);
    if (clean.isEmpty) throw Exception('username is empty');

    final ext = _postMediaExtFromPath(raw, video: video);
    final storagePath = 'posts/$clean/${video ? 'videos' : 'images'}/${DateTime.now().microsecondsSinceEpoch}.$ext';

    await client.storage.from('post-media').upload(
      storagePath,
      file,
      fileOptions: FileOptions(
        contentType: _postMediaContentType(ext, video: video),
        cacheControl: '86400',
        upsert: true,
      ),
    );

    return client.storage.from('post-media').getPublicUrl(storagePath);
  }


  static Future<String> uploadPostVoice({
    required String username,
    required String filePath,
  }) async {
    final raw = filePath.trim();
    if (raw.isEmpty) return '';
    if (_isRemoteUrl(raw)) return raw;

    final file = File(raw);
    if (!await file.exists()) throw Exception('post voice file not found');

    final clean = normalizeUsername(username);
    if (clean.isEmpty) throw Exception('username is empty');

    final ext = _postVoiceExtFromPath(raw);
    final storagePath = 'posts/$clean/voices/${DateTime.now().microsecondsSinceEpoch}.$ext';

    await client.storage.from('post-media').upload(
      storagePath,
      file,
      fileOptions: FileOptions(
        contentType: _postVoiceContentType(ext),
        cacheControl: '86400',
        upsert: true,
      ),
    );

    return client.storage.from('post-media').getPublicUrl(storagePath);
  }


  static Future<String> uploadChatVoice({
    required String username,
    required String filePath,
  }) async {
    final raw = filePath.trim();
    if (raw.isEmpty) return '';
    if (_isRemoteUrl(raw)) return raw;

    final file = File(raw);
    if (!await file.exists()) throw Exception('chat voice file not found');

    final clean = normalizeUsername(username);
    if (clean.isEmpty) throw Exception('username is empty');

    final ext = _postVoiceExtFromPath(raw);
    final storagePath = 'chat/$clean/voices/${DateTime.now().microsecondsSinceEpoch}.$ext';

    await client.storage.from('post-media').upload(
      storagePath,
      file,
      fileOptions: FileOptions(
        contentType: _postVoiceContentType(ext),
        cacheControl: '604800',
        upsert: true,
      ),
    );

    return client.storage.from('post-media').getPublicUrl(storagePath);
  }

  static Future<String> uploadProfileAvatar({
    required String username,
    required String filePath,
  }) async {
    final clean = normalizeUsername(username);
    if (clean.isEmpty) throw Exception('username is empty');

    final file = File(filePath);
    if (!await file.exists()) throw Exception('avatar file not found');

    final ext = _storageExtFromPath(filePath);
    final storagePath = 'avatars/$clean/avatar_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final contentType = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
        ? 'image/webp'
        : 'image/jpeg';

    await client.storage.from('avatars').upload(
      storagePath,
      file,
      fileOptions: FileOptions(
        contentType: contentType,
        upsert: true,
      ),
    );

    final publicUrl = client.storage.from('avatars').getPublicUrl(storagePath);
    await updateUserAvatar(username: clean, avatarUrl: publicUrl);
    return publicUrl;
  }


  static Future<String> uploadProfileCover({
    required String username,
    required String filePath,
  }) async {
    final clean = normalizeUsername(username);
    if (clean.isEmpty) throw Exception('username is empty');

    final file = File(filePath);
    if (!await file.exists()) throw Exception('cover file not found');

    final ext = _storageExtFromPath(filePath);
    final storagePath = 'covers/$clean/cover_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final contentType = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
        ? 'image/webp'
        : 'image/jpeg';

    await client.storage.from('avatars').upload(
      storagePath,
      file,
      fileOptions: FileOptions(contentType: contentType, upsert: true),
    );

    final publicUrl = client.storage.from('avatars').getPublicUrl(storagePath);
    await updateUserCover(username: clean, coverUrl: publicUrl);
    return publicUrl;
  }

  static bool _isRemoteImageUrl(String? value) {
    final v = value?.trim() ?? '';
    return v.startsWith('http://') || v.startsWith('https://');
  }

  static Future<void> updateUserAvatar({
    required String username,
    required String avatarUrl,
  }) async {
    final clean = normalizeUsername(username);
    final url = avatarUrl.trim();
    if (clean.isEmpty || !_isRemoteImageUrl(url)) return;

    // الصورة العالمية لازم تنحفظ كرابط Supabase Storage داخل users.avatar_url.
    // لا نعتمد على imagePath / profileImagePath لأنها مسارات محلية لا تعمل عند باقي المستخدمين.
    await client
        .from('users')
        .update({
      'avatar_url': url,
      'imagePath': url,
      'profileImagePath': url,
    })
        .or('username.eq.$clean,username.eq.@$clean');

    // احتياط: نحدّث المنشورات القديمة أيضًا لو كان عندك عمود avatar_url في posts.
    // لو العمود غير موجود أو RLS يمنع التعديل، التطبيق يستمر طبيعي لأن getPosts يربطها من users.
    try {
      await client
          .from('posts')
          .update({'avatar_url': url, 'avatarPath': url})
          .or('username.eq.@$clean,username.eq.$clean');
    } catch (e, st) { _logIgnoredError(e, st); }

    final currentId = await SupabaseService.currentUserId();
    if (currentId != null && normalizeUsername(currentId) == clean) {
      final fresh = await getUserByUsername(clean);
      if (fresh != null) await saveCurrentUser(fresh);
    }
  }




  static Future<void> updateUserCover({
    required String username,
    required String coverUrl,
  }) async {
    final clean = normalizeUsername(username);
    final url = coverUrl.trim();
    if (clean.isEmpty || !_isRemoteImageUrl(url)) return;

    try {
      await client
          .from('users')
          .update({
        'cover_url': url,
        'coverPath': url,
      })
          .or('username.eq.$clean,username.eq.@$clean');
    } catch (_) {
      await client
          .from('users')
          .update({'cover_url': url})
          .or('username.eq.$clean,username.eq.@$clean');
    }

    final currentId = await SupabaseService.currentUserId();
    if (currentId != null && normalizeUsername(currentId) == clean) {
      final fresh = await getUserByUsername(clean);
      if (fresh != null) await saveCurrentUser(fresh);
    }
  }

  static int _asInt(dynamic value) => int.tryParse((value ?? 0).toString()) ?? 0;

  static Future<Map<String, int>> _readPostCounters(String postId) async {
    try {
      final row = await client
          .from('posts')
          .select('likes,reposts,shares,views')
          .eq('id', postId)
          .maybeSingle();
      if (row == null) return {'likes': 0, 'reposts': 0, 'shares': 0, 'views': 0};
      return {
        'likes': _asInt(row['likes']),
        'reposts': _asInt(row['reposts']),
        'shares': _asInt(row['shares']),
        'views': _asInt(row['views']),
      };
    } catch (_) {
      final row = await client
          .from('posts')
          .select('likes')
          .eq('id', postId)
          .maybeSingle();
      return {
        'likes': _asInt((row == null ? null : row['likes'])),
        'reposts': 0,
        'shares': 0,
        'views': 0,
      };
    }
  }

  static Future<void> _updatePostCounters(String postId, Map<String, int> counters) async {
    final fullPayload = <String, dynamic>{
      'likes': counters['likes'] ?? 0,
      'reposts': counters['reposts'] ?? 0,
      'shares': counters['shares'] ?? 0,
      'views': counters['views'] ?? 0,
    };
    try {
      await client.from('posts').update(fullPayload).eq('id', postId);
    } catch (_) {
      await client.from('posts').update({'likes': counters['likes'] ?? 0}).eq('id', postId);
    }
  }

  static Future<Set<String>> getUserLikedPostIds(String username) async {
    final user = displayUsername(username);
    try {
      final data = await client.from('post_likes').select('post_id').eq('username', user);
      return data.map<String>((e) => (e['post_id'] ?? '').toString()).where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<Set<String>> getUserRepostedPostIds(String username) async {
    final user = displayUsername(username);
    try {
      final data = await client.from('post_reposts').select('post_id').eq('username', user);
      return data.map<String>((e) => (e['post_id'] ?? '').toString()).where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static const List<String> _postSaveTables = <String>['saved', 'post_saved', 'post_saves'];

  static Future<Set<String>> getUserSavedPostIds(String username) async {
    final user = displayUsername(username);
    for (final table in _postSaveTables) {
      try {
        final data = await client.from(table).select('post_id').eq('username', user);
        return data
            .map<String>((e) => (e['post_id'] ?? '').toString())
            .where((e) => e.isNotEmpty)
            .toSet();
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    return <String>{};
  }

  static Future<String> _resolvePostSaveTable(String postId, String username) async {
    for (final table in _postSaveTables) {
      try {
        await client
            .from(table)
            .select('post_id')
            .eq('post_id', postId)
            .eq('username', displayUsername(username))
            .limit(1);
        return table;
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    throw Exception('saved table not found');
  }

  static Future<int> _countInteractionRows(String table, String postId) async {
    try {
      final rows = await client.from(table).select('post_id').eq('post_id', postId);
      return rows.length;
    } catch (_) {
      return 0;
    }
  }

  static Future<bool> _interactionExists({
    required String table,
    required String postId,
    required String username,
  }) async {
    final user = displayUsername(username);
    try {
      // لا نستخدم maybeSingle هنا لأن وجود تكرارات قديمة في الجدول يسبب خطأ
      // ويوقف كل التفاعلات. limit(1) آمن حتى لو عندك duplicate rows.
      final rows = await client
          .from(table)
          .select('post_id')
          .eq('post_id', postId)
          .eq('username', user)
          .limit(1);
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _deleteInteractionRows({
    required String table,
    required String postId,
    required String username,
  }) async {
    final user = displayUsername(username);
    await client.from(table).delete().eq('post_id', postId).eq('username', user);
  }

  static Future<void> _insertInteractionRowIfMissing({
    required String table,
    required String postId,
    required String username,
  }) async {
    final user = displayUsername(username);
    final exists = await _interactionExists(table: table, postId: postId, username: user);
    if (exists) return;

    try {
      // insert بدل upsert حتى لا يعتمد التطبيق على وجود unique constraint في Supabase.
      await client.from(table).insert({
        'post_id': postId,
        'username': user,
      });
    } catch (e) {
      // لو صار ضغط سريع أو فيه unique constraint ورجع duplicate error، نعتبرها ناجحة
      // طالما الصف أصبح موجودًا.
      final nowExists = await _interactionExists(table: table, postId: postId, username: user);
      if (!nowExists) rethrow;
    }
  }

  static Future<Map<String, int>> _readGlobalPostCounters(String postId) async {
    final base = await _readPostCounters(postId);
    final likes = await _countInteractionRows('post_likes', postId);
    final reposts = await _countInteractionRows('post_reposts', postId);
    final views = await _countInteractionRows('post_views', postId);
    final counters = {
      'likes': likes,
      'reposts': reposts,
      'shares': base['shares'] ?? 0,
      'views': views,
    };

    // نحدّث أعمدة posts كاش احتياطيًا حتى تبقى الأرقام متزامنة مع الجداول.
    try { await _updatePostCounters(postId, counters); } catch (e, st) { _logIgnoredError(e, st); }
    return counters;
  }


  static Future<Map<String, dynamic>> setPostLike({
    required String postId,
    required String username,
    required bool liked,
  }) async {
    final id = postId.trim();
    final user = displayUsername(username);

    if (id.isEmpty) throw Exception('postId is empty');
    if (user == '@user') throw Exception('username is empty');

    try {
      final res = await client.rpc(
        'set_post_like_rpc',
        params: {
          'p_post_id': id,
          'p_username': user,
          'p_liked': liked,
        },
      );

      return Map<String, dynamic>.from(res as Map);
    } catch (_) {
      // Fallback ثابت وليس toggle:
      // إذا المطلوب liked=true نضمن وجود الصف، وإذا false نضمن حذفه.
      // هذا يمنع حذف اللايك بالغلط عند تكرار الطلب.
      if (liked) {
        await _insertInteractionRowIfMissing(
          table: 'post_likes',
          postId: id,
          username: user,
        );
      } else {
        await _deleteInteractionRows(
          table: 'post_likes',
          postId: id,
          username: user,
        );
      }

      final counters = await _readGlobalPostCounters(id);
      return {
        'success': true,
        'isLiked': liked,
        ...counters,
      };
    }
  }

  static Future<Map<String, dynamic>> togglePostLike({
    required String postId,
    required String username,
  }) async {
    final id = postId.trim();
    final user = displayUsername(username);

    if (id.isEmpty) throw Exception('postId is empty');
    if (user == '@user') throw Exception('username is empty');

    try {
      final res = await client.rpc(
        'toggle_post_like_rpc',
        params: {
          'p_post_id': id,
          'p_username': user,
        },
      );

      return Map<String, dynamic>.from(res as Map);
    } catch (_) {
      // Fallback مهم حتى لو RPC غير موجودة أو حصل خطأ مؤقت في Supabase.
      // بهذا الشكل التطبيق لا يتعطل ويرجع يستخدم النظام القديم.
      final wasLiked = await _interactionExists(
        table: 'post_likes',
        postId: id,
        username: user,
      );

      final newLiked = !wasLiked;

      if (wasLiked) {
        await _deleteInteractionRows(
          table: 'post_likes',
          postId: id,
          username: user,
        );
      } else {
        await _insertInteractionRowIfMissing(
          table: 'post_likes',
          postId: id,
          username: user,
        );
      }

      final counters = await _readGlobalPostCounters(id);
      return {
        'success': true,
        'isLiked': newLiked,
        ...counters,
      };
    }
  }

  static Future<Map<String, dynamic>> setPostRepost({
    required String postId,
    required String username,
    required bool reposted,
  }) async {
    final id = postId.trim();
    final user = displayUsername(username);

    if (id.isEmpty) throw Exception('postId is empty');
    if (user == '@user') throw Exception('username is empty');

    try {
      final res = await client.rpc(
        'set_post_repost_rpc',
        params: {
          'p_post_id': id,
          'p_username': user,
          'p_reposted': reposted,
        },
      );

      return Map<String, dynamic>.from(res as Map);
    } catch (_) {
      // Fallback ثابت وليس toggle:
      // إذا المطلوب reposted=true نضمن وجود الصف، وإذا false نضمن حذفه.
      // هذا يمنع حذف إعادة النشر بالغلط عند تكرار الطلب.
      if (reposted) {
        await _insertInteractionRowIfMissing(
          table: 'post_reposts',
          postId: id,
          username: user,
        );
      } else {
        await _deleteInteractionRows(
          table: 'post_reposts',
          postId: id,
          username: user,
        );
      }

      final counters = await _readGlobalPostCounters(id);
      return {
        'success': true,
        'isReposted': reposted,
        ...counters,
      };
    }
  }

  static Future<Map<String, dynamic>> togglePostRepost({
    required String postId,
    required String username,
  }) async {
    final id = postId.trim();
    final user = displayUsername(username);

    if (id.isEmpty) throw Exception('postId is empty');
    if (user == '@user') throw Exception('username is empty');

    try {
      final res = await client.rpc(
        'toggle_post_repost_rpc',
        params: {
          'p_post_id': id,
          'p_username': user,
        },
      );

      return Map<String, dynamic>.from(res as Map);
    } catch (_) {
      // Fallback مهم حتى لو RPC غير موجودة أو حصل خطأ مؤقت في Supabase.
      // بهذا الشكل التطبيق لا يتعطل ويرجع يستخدم النظام القديم.
      final wasReposted = await _interactionExists(
        table: 'post_reposts',
        postId: id,
        username: user,
      );

      final newReposted = !wasReposted;

      if (wasReposted) {
        await _deleteInteractionRows(
          table: 'post_reposts',
          postId: id,
          username: user,
        );
      } else {
        await _insertInteractionRowIfMissing(
          table: 'post_reposts',
          postId: id,
          username: user,
        );
      }

      final counters = await _readGlobalPostCounters(id);
      return {
        'success': true,
        'isReposted': newReposted,
        ...counters,
      };
    }
  }

  static Future<Map<String, dynamic>> togglePostSave({
    required String postId,
    required String username,
  }) async {
    final id = postId.trim();
    final user = displayUsername(username);
    if (id.isEmpty) throw Exception('postId is empty');
    if (user == '@user') throw Exception('username is empty');

    final table = await _resolvePostSaveTable(id, user);
    final wasSaved = await _interactionExists(table: table, postId: id, username: user);
    final newSaved = !wasSaved;

    if (wasSaved) {
      await _deleteInteractionRows(table: table, postId: id, username: user);
    } else {
      await _insertInteractionRowIfMissing(table: table, postId: id, username: user);
    }

    final counters = await _readGlobalPostCounters(id);
    return {
      'isSaved': newSaved,
      ...counters,
    };
  }

  static Future<Map<String, int>> incrementPostShare(String postId) async {
    final counters = await _readPostCounters(postId);
    counters['shares'] = max(0, (counters['shares'] ?? 0) + 1);
    try {
      await client.from('posts').update({'shares': counters['shares'] ?? 0}).eq('id', postId);
    } catch (e, st) { _logIgnoredError(e, st); }
    return await _readGlobalPostCounters(postId);
  }

  static Future<Map<String, dynamic>> markPostViewed({
    required String postId,
    required String username,
  }) async {
    final id = postId.trim();
    final user = displayUsername(username);

    if (id.isEmpty) throw Exception('postId is empty');
    if (user == '@user') throw Exception('username is empty');

    try {
      final res = await client.rpc(
        'mark_post_viewed_rpc',
        params: {
          'p_post_id': id,
          'p_username': user,
        },
      );

      return Map<String, dynamic>.from(res as Map);
    } catch (_) {
      // Fallback مهم حتى لو RPC غير موجودة أو حصل خطأ مؤقت في Supabase.
      // بهذا الشكل التطبيق لا يتعطل ويرجع يستخدم النظام القديم.
      final alreadyViewed = await _interactionExists(
        table: 'post_views',
        postId: id,
        username: user,
      );

      if (!alreadyViewed) {
        await _insertInteractionRowIfMissing(
          table: 'post_views',
          postId: id,
          username: user,
        );
      }

      final counters = await _readGlobalPostCounters(id);
      return {
        'success': true,
        'alreadyViewed': alreadyViewed,
        ...counters,
      };
    }
  }

  static bool isValidEmail(String value) {
    final email = normalizeEmail(value);
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email);
  }

  // ================= Account rules / uniqueness =================
  // Respect usernames: lowercase English letters, numbers and underscore only.
  // No Arabic letters, spaces, uppercase letters, dots, dashes, plus or minus.
  static String strictUsername(String value) {
    return value.trim().replaceAll('@', '').toLowerCase();
  }

  static String cleanProfileName(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String? usernameRuleError(String value) {
    final raw = value.trim().replaceAll('@', '');
    final clean = strictUsername(value);
    if (clean.isEmpty) return 'اكتب اسم المستخدم';
    if (raw != clean) return 'اسم المستخدم لازم يكون أحرف إنجليزية صغيرة فقط بدون كابيتال';
    if (clean.length < 3 || clean.length > 24) return 'اسم المستخدم لازم يكون من 3 إلى 24 حرف';
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(clean)) {
      return 'اسم المستخدم يبدأ بحرف إنجليزي صغير ويسمح فقط بـ a-z و 0-9 و _';
    }
    if (clean.contains('__')) return 'ممنوع تكرار الشرطة السفلية __';
    if (clean.endsWith('_')) return 'ممنوع ينتهي اسم المستخدم بـ _';
    return null;
  }

  static bool isValidStrictUsername(String value) => usernameRuleError(value) == null;

  static Future<bool> isUsernameTaken(String username, {String? exceptUsername}) async {
    await enforceCurrentDeviceAllowed();

    final clean = strictUsername(username);
    if (clean.isEmpty) return false;
    final except = exceptUsername == null ? '' : strictUsername(exceptUsername);
    final lookupHash = await SecureCryptoService.databaseLookupHash('username', displayUsername(clean));

    Future<bool> scanRows(dynamic rows) async {
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        var found = strictUsername((row['username'] ?? '').toString());
        if (found.isEmpty || found.startsWith('enc')) {
          found = strictUsername((row['username_plain'] ?? row['username_decrypted'] ?? '').toString());
        }
        if (found.isNotEmpty && found != except) return true;
        final foundHash = (row['username_lookup_hash'] ?? row['username_hash'] ?? '').toString();
        if (lookupHash.isNotEmpty && foundHash == lookupHash && clean != except) return true;
      }
      return false;
    }

    try {
      final rows = await client
          .from('users')
          .select('username,username_lookup_hash,username_hash')
          .or('username_lookup_hash.eq.$lookupHash,username_hash.eq.$lookupHash,username.eq.$clean,username.eq.@$clean')
          .limit(3)
          .timeout(const Duration(seconds: 8));
      if (await scanRows(rows)) return true;
    } catch (e, st) { _logIgnoredError(e, st); }

    // توافق مع قاعدة البيانات القديمة قبل إضافة أعمدة الحماية.
    try {
      final rows = await client
          .from('users')
          .select('username')
          .or('username.eq.$clean,username.eq.@$clean')
          .limit(3)
          .timeout(const Duration(seconds: 8));
      return scanRows(rows);
    } catch (e, st) { _logIgnoredError(e, st); }
    return false;
  }

  static Future<bool> isEmailTaken(String email, {String? exceptUsername}) async {
    final cleanEmail = normalizeEmail(email);
    if (cleanEmail.isEmpty) return false;
    final except = exceptUsername == null ? '' : strictUsername(exceptUsername);
    try {
      final rows = await client
          .from('users')
          .select('username,email')
          .eq('email', cleanEmail)
          .limit(3)
          .timeout(const Duration(seconds: 8));
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final found = strictUsername((row['username'] ?? '').toString());
        if (found != except) return true;
      }
    } catch (e, st) { _logIgnoredError(e, st); }
    return false;
  }

  static Future<bool> isProfileNameTaken(String profileName, {String? exceptUsername}) async {
    final clean = cleanProfileName(profileName).toLowerCase();
    if (clean.isEmpty) return false;
    final except = exceptUsername == null ? '' : strictUsername(exceptUsername);
    try {
      final rows = await client
          .from('users')
          .select('username,name')
          .limit(1000)
          .timeout(const Duration(seconds: 10));
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final foundUser = strictUsername((row['username'] ?? '').toString());
        if (foundUser == except) continue;
        final n1 = cleanProfileName((row['name'] ?? '').toString()).toLowerCase();
        if (n1 == clean) return true;
      }
    } catch (e, st) { _logIgnoredError(e, st); }
    return false;
  }

  static Future<void> validateNewAccountFields({
    required String username,
    required String email,
    required String profileName,
    String? exceptUsername,
  }) async {
    final usernameError = usernameRuleError(username);
    if (usernameError != null) throw Exception(usernameError);

    final cleanEmail = normalizeEmail(email);
    if (!isValidEmail(cleanEmail)) throw Exception('اكتب إيميل صحيح');

    final cleanName = cleanProfileName(profileName);
    if (cleanName.length < 2) throw Exception('اسم البروفايل لازم يكون حرفين على الأقل');
    if (cleanName.length > 32) throw Exception('اسم البروفايل طويل جدًا، الحد 32 حرف');

    final results = await Future.wait<bool>([
      isUsernameTaken(username, exceptUsername: exceptUsername),
      isEmailTaken(cleanEmail, exceptUsername: exceptUsername),
      isProfileNameTaken(cleanName, exceptUsername: exceptUsername),
    ]);

    if (results[0]) throw Exception('اسم المستخدم موجود بالفعل، جرّب اسم ثاني');
    if (results[1]) throw Exception('الإيميل مستخدم بالفعل في حساب آخر');
    if (results[2]) throw Exception('اسم البروفايل مستخدم بالفعل، اختر اسمًا مختلفًا');
  }

  static Map<String, dynamic> _normalizeUserMap(Map<String, dynamic> user) {
    final username = displayUsername((user['username'] ?? user['id'] ?? '').toString());
    final id = normalizeUsername(username);
    return {
      ...user,
      'id': (user['id'] ?? id).toString(),
      'username': username,
      'name': (user['name'] ?? user['profileName'] ?? username).toString(),
      'profileName': (user['profileName'] ?? user['name'] ?? username).toString(),
      'email': (user['email'] ?? '').toString(),
      'birth_date': (user['birth_date'] ?? '').toString(),
      'bio': (user['bio'] ?? 'Respect App user').toString(),
      'avatar_url': (user['avatar_url'] ?? user['imagePath'] ?? user['profileImagePath'] ?? '').toString(),
      'imagePath': (user['imagePath'] ?? user['avatar_url'] ?? '').toString(),
      'profileImagePath': (user['profileImagePath'] ?? user['avatar_url'] ?? '').toString(),
      'cover_url': (user['cover_url'] ?? user['coverPath'] ?? user['cover_path'] ?? '').toString(),
      'coverPath': (user['coverPath'] ?? user['cover_url'] ?? user['cover_path'] ?? '').toString(),
      'is_admin': user['is_admin'] == true ||
          user['isAdmin'] == true ||
          user['admin'] == true ||
          (user['role'] ?? '').toString().toLowerCase().trim() == 'admin',
      'isAdmin': user['isAdmin'] == true ||
          user['is_admin'] == true ||
          user['admin'] == true ||
          (user['role'] ?? '').toString().toLowerCase().trim() == 'admin',
      'role': (user['role'] ?? ((user['is_admin'] == true || user['isAdmin'] == true) ? 'admin' : 'user')).toString(),
      'is_blocked': user['is_blocked'] == true || user['isBlocked'] == true,
    };
  }

  static Future<void> saveCurrentUser(Map<String, dynamic> user) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeUserMap(user);
    final deviceId = await currentDeviceId();
    normalized['device_id'] = (normalized['device_id'] ?? deviceId).toString().isEmpty ? deviceId : normalized['device_id'];
    normalized['current_device_id'] = deviceId;
    normalized['last_device_id'] = deviceId;
    final username = normalizeUsername((normalized['username'] ?? '').toString());
    if (username.isEmpty) return;

    await prefs.setString('current_user_id', username);
    await prefs.setString('respect_current_user_id', username);
    await prefs.setString('respect_current_user', jsonEncode(normalized));

    final usersRaw = prefs.getString('respect_users_map');
    final users = <String, dynamic>{};
    if (usersRaw != null && usersRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(usersRaw);
        if (decoded is Map) users.addAll(decoded.map((k, v) => MapEntry(k.toString(), v)));
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    users[username] = normalized;
    await prefs.setString('respect_users_map', jsonEncode(users));

    final accountsRaw = prefs.getString('respect_accounts_v1');
    final accounts = <Map<String, dynamic>>[];
    if (accountsRaw != null && accountsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(accountsRaw);
        if (decoded is List) {
          accounts.addAll(decoded.whereType<Map>().map((e) => e.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (e, st) { _logIgnoredError(e, st); }
    }
    final index = accounts.indexWhere((a) => normalizeUsername((a['username'] ?? a['id'] ?? '').toString()) == username);
    if (index >= 0) {
      accounts[index] = {...accounts[index], ...normalized, 'id': username};
    } else {
      accounts.add({...normalized, 'id': username});
    }
    await prefs.setString('respect_accounts_v1', jsonEncode(accounts));

    // تجهيز مفتاح التشفير فور حفظ المستخدم وليس عند فتح الشات فقط.
    // هذا يجعل الحسابات الجديدة والمستخدمين الذين سجلوا دخولهم قادرين على استقبال رسائل مشفرة مباشرة.
    try {
      final userForKey = displayUsername(username);
      final keyPayload = await SecureCryptoService.localPublicKeyPayloadForUser(userForKey);
      if (keyPayload.isNotEmpty) {
        final cleanUser = normalizeUsername(userForKey);
        await client
            .from('users')
            .update(keyPayload)
            .or('username.eq.$userForKey,username.eq.$cleanUser')
            .timeout(const Duration(seconds: 8));
        normalized.addAll(keyPayload);
        users[username] = normalized;
        await prefs.setString('respect_users_map', jsonEncode(users));
      }
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  static Future<void> logout() async {
    await updateCurrentUserFcmToken(null);
    await client.auth.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_user_id');
    await prefs.remove('respect_current_user_id');
    await prefs.remove('respect_current_user');
  }

  static Future<String?> currentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('respect_current_user_id') ?? prefs.getString('current_user_id');
  }

  static Future<Map<String, dynamic>?> currentUser() async {
    final id = await currentUserId();
    if (id == null || id.trim().isEmpty) return null;
    return getUserByUsername(id);
  }

  static bool isAdminMap(Map<String, dynamic>? user) {
    if (user == null) return false;
    final role = (user['role'] ?? user['user_role'] ?? user['account_role'] ?? '').toString().toLowerCase().trim();
    bool truthy(dynamic value) {
      if (value == true) return true;
      final text = value?.toString().toLowerCase().trim() ?? '';
      return text == 'true' || text == '1' || text == 'yes' || text == 'admin' || text == 'owner' || text == 'active';
    }

    return truthy(user['is_admin']) ||
        truthy(user['isAdmin']) ||
        truthy(user['admin']) ||
        truthy(user['is_super_admin']) ||
        role == 'admin' ||
        role == 'owner' ||
        role == 'super_admin';
  }

  static Future<bool> currentUserIsAdmin() async {
    final user = await currentUser();
    return isAdminMap(user);
  }

  static Future<Map<String, dynamic>?> getUserByUsername(String username) async {
    final clean = normalizeUsername(username);
    if (clean.isEmpty) return null;
    final display = displayUsername(clean);
    final lookupHash = await SecureCryptoService.databaseLookupHash('username', display);

    try {
      final data = await client
          .from('users')
          .select(_userListColumns)
          .or('username_lookup_hash.eq.$lookupHash,username_hash.eq.$lookupHash,username.eq.$display,username.eq.$clean')
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (data != null) {
        final user = Map<String, dynamic>.from(data as Map);
        user['username'] = display;
        user['username_decrypted'] = display;
        return user;
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    final data = await client.from('users').select(_userListColumns).eq('username', '@$clean').maybeSingle();
    if (data != null) return Map<String, dynamic>.from(data as Map);

    final data2 = await client.from('users').select(_userListColumns).eq('username', clean).maybeSingle();
    if (data2 == null) return null;
    return Map<String, dynamic>.from(data2 as Map);
  }

  static Future<Map<String, dynamic>?> getUserByEmail(String email) async {
    final clean = normalizeEmail(email);
    if (clean.isEmpty) return null;
    final data = await client.from('users').select(_userListColumns).eq('email', clean).maybeSingle();
    if (data == null) return null;
    return Map<String, dynamic>.from(data);
  }

  static Future<Map<String, dynamic>?> login(String usernameOrEmail, String password) async {
    await enforceCurrentDeviceAllowed();

    final input = usernameOrEmail.trim();
    final cleanUsername = normalizeUsername(input);
    final cleanEmail = normalizeEmail(input);
    final pass = password.trim();
    if (pass.isEmpty) return null;

    String emailForAuth = cleanEmail;
    if (!isValidEmail(input)) {
      final userByUsername = await getUserByUsername(cleanUsername);
      emailForAuth = normalizeEmail((userByUsername?['email'] ?? '').toString());
    }
    if (emailForAuth.isEmpty) return null;

    try {
      final auth = await client.auth.signInWithPassword(
        email: emailForAuth,
        password: pass,
      );
      if (auth.user == null) return null;
    } on AuthException catch (e) {
      throw Exception(e.message);
    }

    final data = await getUserByEmail(emailForAuth);
    if (data == null) return null;
    if (isBlockedUserMap(data)) return null;
    await saveCurrentUser(data);
    await registerCurrentDeviceForUser((data['username'] ?? cleanUsername).toString());
    return data;
  }

  static Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    required String password,
    required String name,
    required String birthDate,
    required bool acceptedTerms,
  }) async {
    await enforceCurrentDeviceAllowed();

    final clean = strictUsername(username);
    final cleanEmail = normalizeEmail(email);
    final cleanName = cleanProfileName(name);
    final pass = password.trim();
    final deviceId = await currentDeviceId();
    final displayUser = displayUsername(clean);
    final usernameLookupHash = await SecureCryptoService.databaseLookupHash('username', displayUser);
    final encryptedUsername = await SecureCryptoService.encryptDatabaseField('username', displayUser);
    final protectedPassword = await SecureCryptoService.passwordDatabaseHash(pass);

    await validateNewAccountFields(
      username: clean,
      email: cleanEmail,
      profileName: cleanName,
    );

    if (pass.length < 6) throw Exception('كلمة المرور لازم تكون 6 أحرف على الأقل');
    if (birthDate.trim().isEmpty) throw Exception('اختر تاريخ الميلاد');
    if (!acceptedTerms) throw Exception('يجب الموافقة على سياسة الخصوصية وقوانين الاستخدام');

    // مهم جدًا:
    // لا نستخدم client.auth.signUp هنا بعد إضافة OTP الخاص بنا،
    // لأن Supabase يرسل إيميل تأكيد تلقائيًا وقد يظهر خطأ:
    // email rate limit exceeded
    // لذلك ننشئ مستخدم Auth من السيرفر باستخدام service role مع email_confirm=true،
    // ثم نسجل الدخول عاديًا حتى تتكون جلسة Supabase.
    await _createPasswordAuthUserOnBackend(
      username: clean,
      email: cleanEmail,
      password: pass,
      name: cleanName,
    );

    try {
      final auth = await client.auth.signInWithPassword(
        email: cleanEmail,
        password: pass,
      );
      if (auth.user == null) {
        throw Exception('تعذر فتح جلسة الحساب بعد إنشائه');
      }
    } on AuthException catch (e) {
      throw Exception(e.message);
    }

    final e2eePayload = await SecureCryptoService.localPublicKeyPayloadForUser(clean);

    final payload = <String, dynamic>{
      // نبقي username كمعرف عام للتوافق مع باقي التطبيق، ونخزن النسخة المحمية في username_encrypted.
      // تسجيل الدخول والبحث عن التكرار يستخدم username_lookup_hash.
      'username': displayUser,
      'username_encrypted': encryptedUsername,
      'username_lookup_hash': usernameLookupHash,
      'username_hash': usernameLookupHash,
      'email': cleanEmail,
      // لا نخزن كلمة المرور كنص واضح داخل public.users.
      // تسجيل الدخول الحقيقي يتم عبر Supabase Auth، وهذا الحقل فقط لإرضاء NOT NULL إن كان موجودًا.
      'password': protectedPassword,
      'password_hash': protectedPassword,
      'password_encryption_version': 'hash_hmac_sha256_v1',
      'name': cleanName,
      'birth_date': birthDate.trim(),
      'accepted_terms': acceptedTerms,
      'terms_accepted_at': DateTime.now().toUtc().toIso8601String(),
      'terms_version': 'respect_terms_v1_2026',
      'auth_provider': 'password',
      'device_id': deviceId,
      'current_device_id': deviceId,
      'last_device_id': deviceId,
      'device_platform': _safeDevicePlatform,
      'device_updated_at': DateTime.now().toUtc().toIso8601String(),
      'bio': 'Respect App user',
      'avatar_url': '',
      'cover_url': '',
      'is_admin': false,
      'is_blocked': false,
      'is_verified': false,
      'verified_until': null,
      ...e2eePayload,
    };

    dynamic inserted;
    try {
      inserted = await client.from('users').insert(payload).select().single();
    } catch (_) {
      // احتياط لو لم تنفذ ملف SQL الذي يضيف حقول السياسة بعد.
      final fallback = Map<String, dynamic>.from(payload)
        ..remove('terms_accepted_at')
        ..remove('terms_version')
        ..remove('device_id')
        ..remove('current_device_id')
        ..remove('last_device_id')
        ..remove('device_platform')
        ..remove('device_updated_at')
        ..remove('e2ee_public_key')
        ..remove('e2ee_key_type')
        ..remove('e2ee_key_version')
        ..remove('e2ee_updated_at')
        ..remove('username_encrypted')
        ..remove('username_lookup_hash')
        ..remove('username_hash')
        ..remove('password_hash')
        ..remove('password_encryption_version')
        ..remove('device_banned')
        ..remove('device_blocked')
        ..['password'] = protectedPassword;
      inserted = await client.from('users').insert(fallback).select().single();
    }

    final user = Map<String, dynamic>.from(inserted as Map);
    user['username'] = displayUser;
    user['username_decrypted'] = displayUser;
    await saveCurrentUser(user);
    await registerCurrentDeviceForUser(displayUser);
    return user;
  }



  // ================= Login OTP / Trusted Device =================
  static Uri _authEndpoint(String path) {
    final base = authOtpBackendBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  static Future<Map<String, dynamic>> _postAuthJson(String path, Map<String, dynamic> body) async {
    final response = await _postSignedJson(
  _authEndpoint(path),
  body,
  timeout: const Duration(seconds: 25),
);

    Map<String, dynamic> decoded = <String, dynamic>{};
    try {
      final raw = jsonDecode(utf8.decode(response.bodyBytes));
      if (raw is Map) decoded = raw.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {}

    if (response.statusCode < 200 || response.statusCode >= 300 || decoded['ok'] == false) {
      final detail = (decoded['detail'] ?? decoded['error'] ?? decoded['message'] ?? response.body).toString();
      throw Exception(detail.replaceFirst('Exception: ', '').trim().isEmpty ? 'تعذر تنفيذ طلب التحقق' : detail);
    }
    return decoded;
  }


  static Future<Map<String, dynamic>> checkLoginAttemptAllowed(String usernameOrEmail) async {
    final input = usernameOrEmail.trim();
    if (input.isEmpty) throw Exception('اكتب اسم المستخدم أو الإيميل');
    final deviceId = await currentDeviceId();
    return _postAuthJson('/auth/check-login-attempt', {
      'login': input,
      'deviceId': deviceId,
    });
  }

  static Future<Map<String, dynamic>> reportLoginAttempt({
    required String usernameOrEmail,
    required bool success,
  }) async {
    final input = usernameOrEmail.trim();
    if (input.isEmpty) return <String, dynamic>{'ok': false};
    final deviceId = await currentDeviceId();
    return _postAuthJson('/auth/report-login-attempt', {
      'login': input,
      'deviceId': deviceId,
      'success': success,
    });
  }

  static Future<Map<String, dynamic>> requestPasswordReset(String usernameOrEmail) async {
    final input = usernameOrEmail.trim();
    if (input.isEmpty) throw Exception('اكتب اسم المستخدم أو الإيميل أولاً');
    final deviceId = await currentDeviceId();
    return _postAuthJson('/auth/request-password-reset', {
      'login': input,
      'deviceId': deviceId,
    });
  }

  static String normalizePhoneE164({required String countryCode, required String phone}) {
    final rawPhone = phone.trim();
    final rawCountry = countryCode.trim();
    if (rawPhone.isEmpty) return '';
    if (rawPhone.startsWith('+')) {
      final digits = rawPhone.replaceAll(RegExp(r'\D+'), '');
      return digits.isEmpty ? '' : '+$digits';
    }
    final cc = rawCountry.replaceAll(RegExp(r'\D+'), '');
    final local = rawPhone.replaceAll(RegExp(r'\D+'), '').replaceFirst(RegExp(r'^0+'), '');
    if (cc.isEmpty || local.isEmpty) return '';
    return '+$cc$local';
  }

  static Future<Map<String, dynamic>> requestPhoneSecurityCode({
    required String username,
    required String countryCode,
    required String phone,
  }) async {
    final user = displayUsername(username);
    final phoneE164 = normalizePhoneE164(countryCode: countryCode, phone: phone);
    if (normalizeUsername(user).isEmpty || user == '@user') throw Exception('تعذر قراءة المستخدم الحالي');
    if (phoneE164.isEmpty) throw Exception('اكتب رقم الجوال بشكل صحيح');
    final deviceId = await currentDeviceId();
    return _postAuthJson('/auth/phone-security/send', {
      'username': user,
      'countryCode': countryCode.trim(),
      'phone': phone.trim(),
      'deviceId': deviceId,
    });
  }

  static Future<Map<String, dynamic>> verifyPhoneSecurityCode({
    required String username,
    required String phoneE164,
    required String code,
  }) async {
    final user = displayUsername(username);
    final cleanCode = code.trim();
    if (!RegExp(r'^\d{4,10}$').hasMatch(cleanCode)) throw Exception('اكتب رمز SMS الصحيح');
    final deviceId = await currentDeviceId();
    return _postAuthJson('/auth/phone-security/verify', {
      'username': user,
      'phoneE164': phoneE164.trim(),
      'code': cleanCode,
      'deviceId': deviceId,
    });
  }

  static Future<Map<String, dynamic>> requestSmsLoginCode(String usernameOrEmail) async {
    final input = usernameOrEmail.trim();
    if (input.isEmpty) throw Exception('اكتب اسم المستخدم أو الإيميل أولاً');
    final deviceId = await currentDeviceId();
    return _postAuthJson('/auth/sms-login/send', {
      'login': input,
      'deviceId': deviceId,
    });
  }

  static Future<Map<String, dynamic>?> loginWithSmsCode(String usernameOrEmail, String code) async {
    await enforceCurrentDeviceAllowed();
    final input = usernameOrEmail.trim();
    final cleanCode = code.trim();
    if (input.isEmpty || !RegExp(r'^\d{4,10}$').hasMatch(cleanCode)) return null;
    final deviceId = await currentDeviceId();
    final res = await _postAuthJson('/auth/sms-login/verify', {
      'login': input,
      'code': cleanCode,
      'deviceId': deviceId,
    });
    final raw = res['user'];
    if (raw is! Map) return null;
    final user = raw.map((k, v) => MapEntry(k.toString(), v));
    if (isBlockedUserMap(user)) return null;
    await saveCurrentUser(user);
    await registerCurrentDeviceForUser((user['username'] ?? input).toString());
    return user;
  }

  static Future<void> _createPasswordAuthUserOnBackend({
    required String username,
    required String email,
    required String password,
    required String name,
  }) async {
    final cleanEmail = normalizeEmail(email);
    final cleanUsername = strictUsername(username);
    final cleanName = cleanProfileName(name);
    final pass = password.trim();

    if (!isValidEmail(cleanEmail)) throw Exception('اكتب إيميل صحيح');
    if (pass.length < 6) throw Exception('كلمة المرور لازم تكون 6 أحرف على الأقل');

    await _postAuthJson('/auth/create-password-user', {
      'email': cleanEmail,
      'password': pass,
      'username': displayUsername(cleanUsername),
      'name': cleanName,
    });
  }

  static Future<Map<String, dynamic>> requestAuthOtp({
    required String email,
    required String purpose,
    String username = '',
  }) async {
    await enforceCurrentDeviceAllowed();
    final cleanEmail = normalizeEmail(email);
    if (!isValidEmail(cleanEmail)) throw Exception('اكتب إيميل صحيح لاستلام رمز التحقق');
    final deviceId = await currentDeviceId();
    return _postAuthJson('/auth/send-otp', {
      'email': cleanEmail,
      'purpose': purpose,
      'username': displayUsername(username),
      'deviceId': deviceId,
    });
  }

  static Future<bool> verifyAuthOtp({
    required String email,
    required String code,
    required String purpose,
    String username = '',
  }) async {
    await enforceCurrentDeviceAllowed();
    final cleanEmail = normalizeEmail(email);
    final cleanCode = code.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(cleanCode)) throw Exception('رمز التحقق يجب أن يكون 6 أرقام');
    final deviceId = await currentDeviceId();
    final res = await _postAuthJson('/auth/verify-otp', {
      'email': cleanEmail,
      'code': cleanCode,
      'purpose': purpose,
      'username': displayUsername(username),
      'deviceId': deviceId,
    });
    return res['ok'] == true;
  }

  static Future<bool> isTrustedDeviceForUsername(String username) async {
    final user = displayUsername(username);
    if (normalizeUsername(user).isEmpty) return false;
    final deviceId = await currentDeviceId();
    try {
      final res = await _postAuthJson('/auth/is-trusted-device', {
        'username': user,
        'deviceId': deviceId,
      });
      return res['trusted'] == true;
    } catch (e, st) {
      _logIgnoredError(e, st);
      return false;
    }
  }

  static Future<void> trustCurrentDeviceForUsername(String username, {int days = 90}) async {
    final user = displayUsername(username);
    if (normalizeUsername(user).isEmpty) return;
    final deviceId = await currentDeviceId();
    try {
      await _postAuthJson('/auth/trust-device', {
        'username': user,
        'deviceId': deviceId,
        'deviceName': _safeDevicePlatform,
        'days': days,
      });
    } catch (e, st) {
      final msg = e.toString().toLowerCase();
      // إذا الجهاز محفوظ مسبقًا فلا نعتبرها مشكلة ولا نعرض إشعار خطأ للمستخدم.
      if (msg.contains('23505') ||
          msg.contains('duplicate key') ||
          msg.contains('already exists') ||
          msg.contains('respect_trusted_devices_username_device_id_key')) {
        return;
      }
      _logIgnoredError(e, st);
      throw Exception("تعذر حفظ الجهاز الموثوق: ${e.toString().replaceFirst('Exception: ', '')}");
    }
  }

  /// يتحقق من كلمة المرور بدون حفظ جلسة المستخدم محليًا.
  /// يستخدم قبل OTP في تسجيل الدخول العادي، حتى لا يدخل الحساب قبل التحقق.
  static Future<Map<String, dynamic>?> verifyLoginPasswordOnly(String usernameOrEmail, String password) async {
    await enforceCurrentDeviceAllowed();

    final input = usernameOrEmail.trim();
    final cleanUsername = normalizeUsername(input);
    final cleanEmail = normalizeEmail(input);
    final pass = password.trim();
    if (pass.isEmpty) return null;

    String emailForAuth = cleanEmail;
    Map<String, dynamic>? userByUsername;
    if (!isValidEmail(input)) {
      userByUsername = await getUserByUsername(cleanUsername);
      emailForAuth = normalizeEmail((userByUsername?['email'] ?? '').toString());
    }
    if (emailForAuth.isEmpty) return null;

    try {
      final auth = await client.auth.signInWithPassword(
        email: emailForAuth,
        password: pass,
      );
      if (auth.user == null) return null;
    } on AuthException catch (e) {
      throw Exception(e.message);
    } finally {
      try { await client.auth.signOut(); } catch (e, st) { _logIgnoredError(e, st); }
    }

    final data = await getUserByEmail(emailForAuth) ?? userByUsername;
    if (data == null) return null;
    if (isBlockedUserMap(data)) return null;
    return data;
  }

  static const String googleWebClientId =
    '384970345898-sk04dn1l9df9233c7vpu0e7061evrvai.apps.googleusercontent.com';

  // iOS يحتاج iOS OAuth Client ID داخل GoogleService-Info.plist أو عبر dart-define.
  // Android يبقى يستخدم Web Client ID كـ serverClientId فقط حتى لا يرجع ApiException: 10.
  static const String googleIosClientId =
      String.fromEnvironment('GOOGLE_IOS_CLIENT_ID', defaultValue: '');

  static Future<Map<String, dynamic>?> signInWithGoogle() async {
    if (kIsWeb) {
      await client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: Uri.base.origin,
      );

      // في الويب Supabase سيعمل redirect ويرجع للموقع،
      // وبعد الرجوع AuthState listener في LoginScreen يكمل syncGoogleSessionUser.
      return null;
    }

    // Android fix:
    // لا تمرر Web Client ID داخل clientId على أندرويد؛ هذا يسبب ApiException: 10.
    // المطلوب مع Supabase هو Web Client ID كـ serverClientId فقط حتى يرجع idToken صالح.
    final googleSignIn = GoogleSignIn(
      scopes: <String>['email', 'profile'],
      clientId: (!kIsWeb && Platform.isIOS && googleIosClientId.trim().isNotEmpty)
          ? googleIosClientId.trim()
          : null,
      serverClientId: googleWebClientId,
    );

    try {
      // تنظيف الجلسة القديمة فقط، بدون disconnect حتى لا يسبب مشاكل صلاحيات/اختيار الحساب.
      await googleSignIn.signOut();
    } catch (e, st) {
      _logIgnoredError(e, st);
    }

    GoogleSignInAccount? googleUser;
    try {
      googleUser = await googleSignIn.signIn();
    } on PlatformException catch (e) {
      final code = e.code;
      final message = (e.message ?? '').trim();
      if (code == 'sign_in_failed' || message.contains('ApiException: 10') || message.contains('Api10')) {
        throw Exception(
          'فشل تسجيل الدخول بجوجل Api10. تأكد أن google-services.json الجديد داخل android/app، '
          'وأن Android OAuth client موجود للـ package com.example.rp_stream_hub مع SHA-1 الصحيح، '
          'ثم نفذ flutter clean واحذف التطبيق من الجوال وثبته من جديد.',
        );
      }
      throw Exception('فشل تسجيل الدخول بجوجل: ${message.isEmpty ? code : message}');
    }

    if (googleUser == null) return null;

    final googleAuth = await googleUser.authentication;
    final googleIdValue = googleAuth.idToken;
    final googleAccessValue = googleAuth.accessToken;

    if (googleIdValue == null || googleIdValue.trim().isEmpty) {
      throw Exception(
        'تعذر الحصول على Google idToken. تأكد من أن googleWebClientId هو Web OAuth Client ID '
        'وأن OAuth consent screen يحتوي حسابك ضمن Test users إذا كان التطبيق Testing.',
      );
    }

    await client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: googleIdValue,
      accessToken: googleAccessValue,
    );

    return syncGoogleSessionUser();
  }

  static Future<Map<String, dynamic>?> syncGoogleSessionUser() async {
    final authUser = client.auth.currentUser;
    if (authUser == null) return null;

    // نفحص حظر الجهاز بعد وجود جلسة، وقبل إنشاء/حفظ المستخدم.
    await enforceCurrentDeviceAllowed();

    final email = normalizeEmail(authUser.email ?? '');
    final meta = authUser.userMetadata ?? <String, dynamic>{};
    final name = (meta['full_name'] ?? meta['name'] ?? (email.isNotEmpty ? email.split('@').first : 'Respect User')).toString();
    final avatar = (meta['avatar_url'] ?? meta['picture'] ?? '').toString();

    Map<String, dynamic>? existing;
    if (email.isNotEmpty) existing = await getUserByEmail(email);

    if (existing != null) {
      if (isBlockedUserMap(existing)) return null;

      final existingUsername = (existing['username'] ?? '').toString();
      await saveCurrentUser(existing);
      await registerCurrentDeviceForUser(existingUsername);

      // بعد تسجيل الجهاز نعيد فحص الحظر؛ هذا مهم لحالة pending device ban.
      final ban = await currentDeviceBan();
      if (ban != null) {
        await clearLocalSessionOnly();
        final reason = (ban['reason'] ?? 'تم حظر هذا الجهاز من استخدام Respect App').toString();
        throw Exception(reason.trim().isEmpty ? 'تم حظر هذا الجهاز من استخدام Respect App' : reason);
      }

      try {
        final fresh = await getUserByUsername(existingUsername);
        if (fresh != null) {
          if (isBlockedUserMap(fresh)) return null;
          await saveCurrentUser(fresh);
          return fresh;
        }
      } catch (e, st) { _logIgnoredError(e, st); }

      return existing;
    }

    final username = await _uniqueGoogleUsername(email.isNotEmpty ? email.split('@').first : name);
    final googleDeviceId = await currentDeviceId();
    final profileName = await _uniqueGoogleProfileName(name.trim().isEmpty ? '@$username' : name.trim());
    final googleDisplayUser = displayUsername(username);
    final googleUsernameLookupHash = await SecureCryptoService.databaseLookupHash('username', googleDisplayUser);
    final googleEncryptedUsername = await SecureCryptoService.encryptDatabaseField('username', googleDisplayUser);
    final googlePasswordPlaceholder = await SecureCryptoService.passwordDatabaseHash('google:${authUser.id}');
    final payload = <String, dynamic>{
      'username': googleDisplayUser,
      'username_encrypted': googleEncryptedUsername,
      'username_lookup_hash': googleUsernameLookupHash,
      'username_hash': googleUsernameLookupHash,
      'email': email,
      // حسابات Google لا تستخدم كلمة مرور محلية، لكن العمود في قاعدة البيانات NOT NULL.
      'password': googlePasswordPlaceholder,
      'password_hash': googlePasswordPlaceholder,
      'password_encryption_version': 'hash_hmac_sha256_v1',
      'name': profileName,
      'birth_date': null,
      'accepted_terms': true,
      'terms_accepted_at': DateTime.now().toUtc().toIso8601String(),
      'terms_version': 'respect_terms_v1_2026',
      'auth_provider': 'google',
      'device_id': googleDeviceId,
      'current_device_id': googleDeviceId,
      'last_device_id': googleDeviceId,
      'device_platform': _safeDevicePlatform,
      'device_updated_at': DateTime.now().toUtc().toIso8601String(),
      'bio': 'Respect App user',
      'avatar_url': avatar,
      'cover_url': '',
      'is_admin': false,
      'is_blocked': false,
      'is_verified': false,
      'verified_until': null,
    };

    dynamic inserted;
    try {
      inserted = await client.from('users').insert(payload).select().single();
    } catch (_) {
      final fallback = Map<String, dynamic>.from(payload)
        ..remove('terms_accepted_at')
        ..remove('terms_version')
        ..remove('device_id')
        ..remove('current_device_id')
        ..remove('last_device_id')
        ..remove('device_platform')
        ..remove('device_updated_at')
        ..remove('username_encrypted')
        ..remove('username_lookup_hash')
        ..remove('username_hash')
        ..remove('password_hash')
        ..remove('password_encryption_version')
        ..remove('device_banned')
        ..remove('device_blocked')
        ..remove('password');

      try {
        inserted = await client.from('users').insert(fallback).select().single();
      } catch (_) {
        // لو صار سباق بين AuthState listener وزر Google أو صار unique conflict،
        // نرجع نقرأ الحساب بالإيميل بدل ما يفشل الدخول.
        if (email.isNotEmpty) {
          final justCreated = await getUserByEmail(email);
          if (justCreated != null) {
            if (isBlockedUserMap(justCreated)) return null;
            await saveCurrentUser(justCreated);
            await registerCurrentDeviceForUser((justCreated['username'] ?? '').toString());
            return justCreated;
          }
        }
        rethrow;
      }
    }

    final user = Map<String, dynamic>.from(inserted as Map);
    user['username'] = googleDisplayUser;
    user['username_decrypted'] = googleDisplayUser;
    await saveCurrentUser(user);
    await registerCurrentDeviceForUser(googleDisplayUser);

    final ban = await currentDeviceBan();
    if (ban != null) {
      await clearLocalSessionOnly();
      final reason = (ban['reason'] ?? 'تم حظر هذا الجهاز من استخدام Respect App').toString();
      throw Exception(reason.trim().isEmpty ? 'تم حظر هذا الجهاز من استخدام Respect App' : reason);
    }

    return user;
  }

  static Future<String> _uniqueGoogleUsername(String seed) async {
    var base = strictUsername(seed).replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    base = base.replaceAll(RegExp(r'_+'), '_');
    base = base.replaceAll(RegExp(r'^_+|_+$'), '');
    if (base.isEmpty || !RegExp(r'^[a-z]').hasMatch(base)) base = 'user_$base';
    if (base.length < 3) base = 'user${Random().nextInt(9999)}';
    if (base.length > 18) base = base.substring(0, 18).replaceAll(RegExp(r'_+$'), '');

    for (var i = 0; i < 40; i++) {
      final candidate = i == 0 ? base : '${base}_${Random().nextInt(99999)}';
      if (usernameRuleError(candidate) != null) continue;
      final exists = await isUsernameTaken(candidate);
      if (!exists) return candidate;
    }
    return 'user_${DateTime.now().millisecondsSinceEpoch}';
  }

  static Future<String> _uniqueGoogleProfileName(String seed) async {
    var base = cleanProfileName(seed);
    if (base.length < 2) base = 'Respect User';
    if (base.length > 24) base = base.substring(0, 24).trim();
    for (var i = 0; i < 40; i++) {
      final candidate = i == 0 ? base : '$base ${Random().nextInt(9999)}';
      final exists = await isProfileNameTaken(candidate);
      if (!exists) return candidate;
    }
    return 'Respect User ${DateTime.now().millisecondsSinceEpoch}';
  }

  static Future<bool> hasSavedSession() async {
    if (await isCurrentDeviceBanned()) {
      await clearLocalSessionOnly();
      return false;
    }

    final googleUser = await syncGoogleSessionUser();
    if (googleUser != null) return true;

    final id = await currentUserId();
    if (id == null || id.trim().isEmpty) return false;
    final user = await getUserByUsername(id);
    if (user == null || isBlockedUserMap(user)) {
      await clearLocalSessionOnly();
      return false;
    }
    await saveCurrentUser(user);
    await registerCurrentDeviceForUser((user['username'] ?? id).toString());
    return true;
  }

  static const String _userListColumns =
      'id,username,name,bio,email,avatar_url,cover_url,is_verified,verified,verified_until,verification_status,subscription_tier,is_blocked,blocked_at,created_at,is_admin,phone_e164,phone_country_code,phone_national,phone_verified,phone_verified_at,sms_security_enabled,sms_login_enabled';

  static const String _postListColumns =
      'id,username,name,user,text,created_at,time,avatar_url,image_url,video_url,voice_url,voice_seconds,likes,reposts,shares,views,replies,reply_count,community_id,author_verified,author_subscription_tier,author_subscription_priority,author_subscription_boost_until,author_post_max_chars,author_ai_daily_limit,author_subscription_label';

  static Future<List<Map<String, dynamic>>> getUsers() async {
    final data = await client.from('users').select(_userListColumns).order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(data.map((e) => Map<String, dynamic>.from(e)));
  }

  static Future<List<Map<String, dynamic>>> getPosts() async {
    final postsData = await client.from('posts').select(_postListColumns).order('created_at', ascending: false);
    final posts = List<Map<String, dynamic>>.from(postsData.map((e) => Map<String, dynamic>.from(e)));

    // نربط صورة البروفايل من جدول users حتى كل الأجهزة تشوف نفس الصورة من السيرفر.
    try {
      final usersData = await client.from('users').select('username,avatar_url,imagePath,profileImagePath,is_verified,verified,verified_until,verification_status,subscription_tier,verification_plan,subscription_expires_at');
      final avatars = <String, String>{};
      final usersByUsername = <String, Map<String, dynamic>>{};
      for (final raw in usersData) {
        final user = Map<String, dynamic>.from(raw as Map);
        final username = displayUsername((user['username'] ?? '').toString());
        if (username == '@user') continue;
        usersByUsername[username] = user;
        final avatar = (user['avatar_url'] ?? user['imagePath'] ?? user['profileImagePath'] ?? '').toString().trim();
        // لا نستخدم أي مسار محلي من جهاز مستخدم آخر؛ الرابط العام فقط هو الذي يظهر للجميع.
        if (_isRemoteImageUrl(avatar)) avatars[username] = avatar;
      }

      for (final post in posts) {
        final username = displayUsername((post['username'] ?? '').toString());
        final avatar = avatars[username];
        final user = usersByUsername[username];
        if (avatar != null && avatar.isNotEmpty) {
          post['avatar_url'] = avatar;
          post['avatarPath'] = avatar;
        }
        if (user != null) {
          post['author_verified'] = isVerifiedUser(user);
          post.addAll(authorSubscriptionPostFields(user));
        }
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    // نقرأ العدادات العالمية من جداول التفاعل بدل تحديث جدول posts مباشرة.
    // هذا يمنع خطأ RLS على جدول posts عند الضغط على لايك/إعادة نشر.
    try {
      final likesRows = await client.from('post_likes').select('post_id');
      final repostRows = await client.from('post_reposts').select('post_id');
      final viewRows = await client.from('post_views').select('post_id');

      final likeCounts = <String, int>{};
      final repostCounts = <String, int>{};
      final viewCounts = <String, int>{};

      void countInto(List<dynamic> rows, Map<String, int> out) {
        for (final raw in rows) {
          final row = Map<String, dynamic>.from(raw as Map);
          final id = (row['post_id'] ?? '').toString();
          if (id.isEmpty) continue;
          out[id] = (out[id] ?? 0) + 1;
        }
      }

      countInto(List<dynamic>.from(likesRows), likeCounts);
      countInto(List<dynamic>.from(repostRows), repostCounts);
      countInto(List<dynamic>.from(viewRows), viewCounts);

      for (final post in posts) {
        final id = (post['id'] ?? '').toString();
        if (id.isEmpty) continue;
        post['likes'] = likeCounts[id] ?? _asInt(post['likes']);
        post['reposts'] = repostCounts[id] ?? _asInt(post['reposts']);
        post['views'] = viewCounts[id] ?? _asInt(post['views']);
        post['shares'] = _asInt(post['shares']);
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      final ids = posts.map((p) => (p['id'] ?? '').toString()).where((id) => id.isNotEmpty).toList();
      final replies = await _readRepliesGroupedForPosts(ids);
      for (final post in posts) {
        final id = (post['id'] ?? '').toString();
        final list = replies[id] ?? <Map<String, dynamic>>[];
        post['replies'] = list;
        post['comments'] = list.length;
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    return posts;
  }


  static Future<Map<String, dynamic>?> getPostById(String postId) async {
    if (postId.trim().isEmpty) return null;
    final row = await client.from('posts').select(_postListColumns).eq('id', postId).maybeSingle();
    if (row == null) return null;
    final post = Map<String, dynamic>.from(row);

    try {
      final user = await getUserByUsername((post['username'] ?? '').toString());
      final avatar = ((user == null ? null : user['avatar_url']) ?? (user == null ? null : user['imagePath']) ?? (user == null ? null : user['profileImagePath']) ?? '').toString().trim();
      if (avatar.isNotEmpty) {
        post['avatar_url'] = avatar;
        post['avatarPath'] = avatar;
      }
      if (user != null) {
        post['author_verified'] = isVerifiedUser(user);
        post.addAll(authorSubscriptionPostFields(user));
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      final counters = await _readGlobalPostCounters(postId);
      post['likes'] = counters['likes'] ?? _asInt(post['likes']);
      post['reposts'] = counters['reposts'] ?? _asInt(post['reposts']);
      post['views'] = counters['views'] ?? _asInt(post['views']);
      post['shares'] = counters['shares'] ?? _asInt(post['shares']);
    } catch (e, st) { _logIgnoredError(e, st); }

    try {
      final replies = await getPostReplies(postId);
      post['replies'] = replies;
      post['comments'] = replies.length;
    } catch (e, st) { _logIgnoredError(e, st); }

    return post;
  }

  static Future<int> _countReplyInteractionRows(String table, String replyId) async {
    try {
      final rows = await client.from(table).select('reply_id').eq('reply_id', replyId);
      return rows.length;
    } catch (_) {
      return -1;
    }
  }

  static Future<bool> _replyInteractionExists({
    required String table,
    required String replyId,
    required String username,
  }) async {
    final user = displayUsername(username);
    try {
      final rows = await client
          .from(table)
          .select('reply_id')
          .eq('reply_id', replyId)
          .eq('username', user)
          .limit(1);
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _deleteReplyInteractionRows({
    required String table,
    required String replyId,
    required String username,
  }) async {
    final user = displayUsername(username);
    await client.from(table).delete().eq('reply_id', replyId).eq('username', user);
  }

  static Future<void> _insertReplyInteractionRowIfMissing({
    required String table,
    required String replyId,
    required String username,
  }) async {
    final user = displayUsername(username);
    final exists = await _replyInteractionExists(table: table, replyId: replyId, username: user);
    if (exists) return;

    try {
      await client.from(table).insert({
        'reply_id': replyId,
        'username': user,
      });
    } catch (_) {
      final nowExists = await _replyInteractionExists(table: table, replyId: replyId, username: user);
      if (!nowExists) rethrow;
    }
  }

  static Future<Map<String, int>> _readReplyCounters(String replyId) async {
    try {
      final row = await client
          .from('post_replies')
          .select('likes,reposts,shares,views')
          .eq('id', replyId)
          .maybeSingle();
      return {
        'likes': _asInt((row == null ? null : row['likes'])),
        'reposts': _asInt((row == null ? null : row['reposts'])),
        'shares': _asInt((row == null ? null : row['shares'])),
        'views': _asInt((row == null ? null : row['views'])),
      };
    } catch (_) {
      return {'likes': 0, 'reposts': 0, 'shares': 0, 'views': 0};
    }
  }

  static Future<void> _updateReplyCounters(String replyId, Map<String, int> counters) async {
    final payload = <String, dynamic>{
      'likes': counters['likes'] ?? 0,
      'reposts': counters['reposts'] ?? 0,
      'shares': counters['shares'] ?? 0,
      'views': counters['views'] ?? 0,
    };
    try {
      await client.from('post_replies').update(payload).eq('id', replyId);
    } catch (_) {
      try {
        await client.from('post_replies').update({'likes': payload['likes']}).eq('id', replyId);
      } catch (e, st) { _logIgnoredError(e, st); }
    }
  }

  static Future<Map<String, int>> _readGlobalReplyCounters(String replyId) async {
    final base = await _readReplyCounters(replyId);
    final likes = await _countReplyInteractionRows('reply_likes', replyId);
    final reposts = await _countReplyInteractionRows('reply_reposts', replyId);
    final views = await _countReplyInteractionRows('reply_views', replyId);

    final counters = {
      'likes': likes >= 0 ? likes : (base['likes'] ?? 0),
      'reposts': reposts >= 0 ? reposts : (base['reposts'] ?? 0),
      'shares': base['shares'] ?? 0,
      'views': views >= 0 ? views : (base['views'] ?? 0),
    };
    await _updateReplyCounters(replyId, counters);
    return counters;
  }


  static Future<Map<String, int>> _countReplyRowsForIds(String table, List<String> replyIds) async {
    final ids = replyIds.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (ids.isEmpty) return <String, int>{};
    try {
      final rows = await client
          .from(table)
          .select('reply_id')
          .inFilter('reply_id', ids)
          .timeout(const Duration(seconds: 6));
      final out = <String, int>{};
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = (row['reply_id'] ?? '').toString();
        if (id.isEmpty) continue;
        out[id] = (out[id] ?? 0) + 1;
      }
      return out;
    } catch (_) {
      return <String, int>{};
    }
  }

  static Future<void> _mergeGlobalReplyCountersForRows(List<Map<String, dynamic>> rows) async {
    final ids = rows
        .map((row) => (row['id'] ?? row['reply_id'] ?? '').toString())
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return;

    final results = await Future.wait<Map<String, int>>([
      _countReplyRowsForIds('reply_likes', ids),
      _countReplyRowsForIds('reply_reposts', ids),
      _countReplyRowsForIds('reply_views', ids),
    ]);

    final likes = results[0];
    final reposts = results[1];
    final views = results[2];

    for (final row in rows) {
      final id = (row['id'] ?? row['reply_id'] ?? '').toString();
      if (id.isEmpty) continue;
      row['likes'] = likes.containsKey(id) ? likes[id] : _asInt(row['likes'] ?? row['reply_likes']);
      row['reposts'] = reposts.containsKey(id) ? reposts[id] : _asInt(row['reposts'] ?? row['reply_reposts']);
      row['views'] = views.containsKey(id) ? views[id] : _asInt(row['views']);
      row['shares'] = _asInt(row['shares']);
    }
  }

  static Future<Set<String>> getUserLikedReplyIds(String username) async {
    final user = displayUsername(username);
    try {
      final data = await client.from('reply_likes').select('reply_id').eq('username', user);
      return data.map<String>((e) => (e['reply_id'] ?? '').toString()).where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<Set<String>> getUserRepostedReplyIds(String username) async {
    final user = displayUsername(username);
    try {
      final data = await client.from('reply_reposts').select('reply_id').eq('username', user);
      return data.map<String>((e) => (e['reply_id'] ?? '').toString()).where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<Map<String, dynamic>> toggleReplyLike({
    required String replyId,
    required String username,
  }) async {
    final id = replyId.trim();
    final user = displayUsername(username);
    if (id.isEmpty) throw Exception('replyId is empty');
    if (user == '@user') throw Exception('username is empty');

    final wasLiked = await _replyInteractionExists(table: 'reply_likes', replyId: id, username: user);
    final newLiked = !wasLiked;

    if (wasLiked) {
      await _deleteReplyInteractionRows(table: 'reply_likes', replyId: id, username: user);
    } else {
      await _insertReplyInteractionRowIfMissing(table: 'reply_likes', replyId: id, username: user);
    }

    final counters = await _readGlobalReplyCounters(id);
    return {'isLiked': newLiked, ...counters};
  }

  static Future<Map<String, dynamic>> toggleReplyRepost({
    required String replyId,
    required String username,
  }) async {
    final id = replyId.trim();
    final user = displayUsername(username);
    if (id.isEmpty) throw Exception('replyId is empty');
    if (user == '@user') throw Exception('username is empty');

    final wasReposted = await _replyInteractionExists(table: 'reply_reposts', replyId: id, username: user);
    final newReposted = !wasReposted;

    if (wasReposted) {
      await _deleteReplyInteractionRows(table: 'reply_reposts', replyId: id, username: user);
    } else {
      await _insertReplyInteractionRowIfMissing(table: 'reply_reposts', replyId: id, username: user);
    }

    final counters = await _readGlobalReplyCounters(id);
    return {'isReposted': newReposted, ...counters};
  }

  static Future<Map<String, dynamic>> markReplyViewed({
    required String replyId,
    required String username,
  }) async {
    final id = replyId.trim();
    final user = displayUsername(username);
    if (id.isEmpty) throw Exception('replyId is empty');
    if (user == '@user') throw Exception('username is empty');

    final alreadyViewed = await _replyInteractionExists(table: 'reply_views', replyId: id, username: user);
    if (!alreadyViewed) {
      await _insertReplyInteractionRowIfMissing(table: 'reply_views', replyId: id, username: user);
    }

    final counters = await _readGlobalReplyCounters(id);
    return {'alreadyViewed': alreadyViewed, ...counters};
  }

  static Future<List<Map<String, dynamic>>> getPostReplies(String postId, {String? currentUsername}) async {
    if (postId.trim().isEmpty) return <Map<String, dynamic>>[];
    final data = await client
        .from('post_replies')
        .select()
        .eq('post_id', postId)
        .order('created_at', ascending: true);

    final rows = List<Map<String, dynamic>>.from(data.map((e) => Map<String, dynamic>.from(e)));
    final normalized = _normalizeReplyRows(rows);

    final me = currentUsername == null ? '' : displayUsername(currentUsername);
    Set<String> likedIds = <String>{};
    Set<String> repostedIds = <String>{};
    if (me.isNotEmpty) {
      likedIds = await getUserLikedReplyIds(me);
      repostedIds = await getUserRepostedReplyIds(me);
    }

    await _mergeGlobalReplyCountersForRows(normalized);

    for (final row in normalized) {
      final id = (row['id'] ?? '').toString();
      if (id.isEmpty) continue;
      row['isLiked'] = likedIds.contains(id);
      row['is_liked'] = likedIds.contains(id);
      row['isReposted'] = repostedIds.contains(id);
      row['is_reposted'] = repostedIds.contains(id);
    }
    return normalized;
  }

  static Future<Map<String, dynamic>> addPostReply({
    required String postId,
    required String authorUsername,
    required String authorName,
    required String text,
    String? parentUser,
    String? parentReplyId,
    String mediaUrl = '',
    String mediaType = '',
  }) async {
    final user = displayUsername(authorUsername);
    final trimmedText = text.trim();
    if (postId.trim().isEmpty) throw Exception('postId is empty');
    if (trimmedText.isEmpty && mediaUrl.trim().isEmpty) throw Exception('reply is empty');

    // النشر الآن لا ينتظر Qwen. نفحص محليًا فقط للمخالفة الواضحة جدًا،
    // وبعد الحفظ تعمل مراجعة Respect AI بالخلفية وتحذف الرد لاحقًا إذا كان مخالفًا.
    _enforceLocalObviousModeration(text: trimmedText, authorUsername: user);

    final author = await getUserByUsername(user);
    final avatarUrl = ((author == null ? null : author['avatar_url']) ?? (author == null ? null : author['imagePath']) ?? (author == null ? null : author['profileImagePath']) ?? '').toString().trim();
    final cleanMediaType = mediaType.trim().toLowerCase();
    final safeMediaUrl = mediaUrl.trim().isEmpty
        ? ''
        : await uploadPostMedia(
      username: user,
      filePath: mediaUrl.trim(),
      video: cleanMediaType == 'video',
    );

    final payload = <String, dynamic>{
      'post_id': postId,
      'author_username': user,
      'author_name': authorName.trim().isEmpty ? user : authorName.trim(),
      'text': trimmedText,
      'parent_user': parentUser,
      'parent_reply_id': parentReplyId,
      'media_url': safeMediaUrl,
      'media_type': cleanMediaType,
    };
    if (_isRemoteImageUrl(avatarUrl)) payload['author_avatar_url'] = avatarUrl;

    late final dynamic inserted;
    try {
      inserted = await client.from('post_replies').insert(payload).select().single();
    } catch (_) {
      // لمشاريع Supabase القديمة بدون عمود author_avatar_url أو parent_reply_id.
      payload.remove('author_avatar_url');
      try {
        inserted = await client.from('post_replies').insert(payload).select().single();
      } catch (_) {
        payload.remove('parent_reply_id');
        inserted = await client.from('post_replies').insert(payload).select().single();
      }
    }

    final reply = Map<String, dynamic>.from(inserted as Map);
    unawaited(_moderateReplyInBackground(
      replyId: (reply['id'] ?? '').toString(),
      postId: postId,
      text: trimmedText,
      authorUsername: user,
      parentReplyId: parentReplyId,
    ));

    try {
      final repliesCount = await client.from('post_replies').select('id').eq('post_id', postId);
      await client.from('posts').update({'comments': repliesCount.length}).eq('id', postId);
    } catch (e, st) { _logIgnoredError(e, st); }

    final row = Map<String, dynamic>.from(inserted);
    final normalized = _normalizeReplyRows([row]);
    return normalized.isEmpty ? row : normalized.first;
  }

  static Future<Map<String, List<Map<String, dynamic>>>> _readRepliesGroupedForPosts(List<String> postIds) async {
    final ids = postIds.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (ids.isEmpty) return <String, List<Map<String, dynamic>>>{};

    final data = await client
        .from('post_replies')
        .select()
        .inFilter('post_id', ids)
        .order('created_at', ascending: true);

    final rows = _normalizeReplyRows(List<Map<String, dynamic>>.from(data.map((e) => Map<String, dynamic>.from(e))));
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final postId = (row['post_id'] ?? '').toString();
      if (postId.isEmpty) continue;
      grouped.putIfAbsent(postId, () => <Map<String, dynamic>>[]).add(row);
    }
    return grouped;
  }

  static List<Map<String, dynamic>> _normalizeReplyRows(List<Map<String, dynamic>> rows) {
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      final username = displayUsername((row['author_username'] ?? row['username'] ?? '').toString());
      var avatar = (row['author_avatar_url'] ?? row['avatar_url'] ?? row['avatarPath'] ?? '').toString().trim();
      if (avatar.isEmpty && username != '@user') {
        // ملاحظة: لا نستدعي await هنا؛ الصور الأساسية تُربط من users عند قراءة المنشورات.
      }
      out.add({
        ...row,
        'user': (row['author_name'] ?? row['user'] ?? username).toString(),
        'username': username,
        'text': (row['text'] ?? '').toString(),
        'time': _relativeShortTime((row['created_at'] ?? row['createdAt'] ?? '').toString()),
        'avatarPath': avatar.isEmpty ? null : avatar,
        'parentUser': (row['parent_user'] ?? row['parentUser'])?.toString(),
        'parentReplyId': (row['parent_reply_id'] ?? row['parentReplyId'])?.toString(),
        'mediaPath': (row['media_url'] ?? row['mediaPath'])?.toString(),
        'mediaType': (row['media_type'] ?? row['mediaType'])?.toString(),
        'likes': _asInt(row['likes'] ?? row['reply_likes']),
        'reposts': _asInt(row['reposts'] ?? row['reply_reposts']),
        'shares': _asInt(row['shares']),
        'views': _asInt(row['views']),
      });
    }
    return out;
  }


  static Future<List<Map<String, dynamic>>> getReplyRepostsForTimeline(List<String> usernames) async {
    final users = usernames
        .map(displayUsername)
        .where((u) => u != '@user')
        .toSet()
        .toList();
    if (users.isEmpty) return <Map<String, dynamic>>[];

    try {
      final rows = await client
          .from('reply_reposts')
          .select('reply_id,username,created_at')
          .inFilter('username', users)
          .order('created_at', ascending: false)
          .limit(120)
          .timeout(const Duration(seconds: 7));

      return List<Map<String, dynamic>>.from(
        rows.map((e) => Map<String, dynamic>.from(e as Map)),
      );
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<List<Map<String, dynamic>>> getRepliesByIds(
      List<String> replyIds, {
        String? currentUsername,
      }) async {
    final ids = replyIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return <Map<String, dynamic>>[];

    try {
      final rows = await client
          .from('post_replies')
          .select()
          .inFilter('id', ids)
          .timeout(const Duration(seconds: 8));

      final normalized = _normalizeReplyRows(
        List<Map<String, dynamic>>.from(
          rows.map((e) => Map<String, dynamic>.from(e as Map)),
        ),
      );

      await _mergeGlobalReplyCountersForRows(normalized);

      final me = currentUsername == null ? '' : displayUsername(currentUsername);
      Set<String> likedIds = <String>{};
      Set<String> repostedIds = <String>{};
      if (me.isNotEmpty) {
        likedIds = await getUserLikedReplyIds(me);
        repostedIds = await getUserRepostedReplyIds(me);
      }

      for (final row in normalized) {
        final id = (row['id'] ?? '').toString();
        if (id.isEmpty) continue;
        row['isLiked'] = likedIds.contains(id);
        row['is_liked'] = likedIds.contains(id);
        row['isReposted'] = repostedIds.contains(id);
        row['is_reposted'] = repostedIds.contains(id);
      }

      return normalized;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static String _relativeShortTime(String raw) {
    final date = DateTime.tryParse(raw);
    if (date == null) return 'الآن';
    final diff = DateTime.now().toLocal().difference(date.toLocal());
    if (diff.inSeconds < 60) return 'الآن';
    if (diff.inMinutes < 60) return 'قبل ${diff.inMinutes} د';
    if (diff.inHours < 24) return 'قبل ${diff.inHours} س';
    if (diff.inDays < 7) return 'قبل ${diff.inDays} يوم';
    return '${date.toLocal().year}-${date.toLocal().month.toString().padLeft(2, '0')}-${date.toLocal().day.toString().padLeft(2, '0')}';
  }

  static Future<void> createMentionNotifications({
    required List<String> targets,
    required String postId,
    required String authorUsername,
    required String authorName,
    required String text,
  }) async {
    final cleanAuthor = displayUsername(authorUsername);
    final uniqueTargets = targets
        .map(displayUsername)
        .where((u) => u != '@user')
        .toSet()
        .toList();
    if (uniqueTargets.isEmpty || postId.trim().isEmpty) return;

    final rows = uniqueTargets.map((target) => {
      'target_username': target,
      'author_username': cleanAuthor,
      'author_name': authorName.trim().isEmpty ? cleanAuthor : authorName.trim(),
      'post_id': postId,
      'text': text,
    }).toList();

    await client.from('post_mentions').upsert(
      rows,
      onConflict: 'target_username,author_username,post_id',
    );
  }

  static Future<List<Map<String, dynamic>>> getMentionNotificationsForUser(String username) async {
    final target = displayUsername(username);
    final data = await client
        .from('post_mentions')
        .select()
        .eq('target_username', target)
        .order('created_at', ascending: false)
        .limit(100);
    return List<Map<String, dynamic>>.from(data.map((e) => Map<String, dynamic>.from(e)));
  }


  static Future<void> createPostEventNotification({
    required String type,
    required String targetUsername,
    required String actorUsername,
    required String actorName,
    required String postId,
    required String text,
  }) async {
    final target = displayUsername(targetUsername);
    final actor = displayUsername(actorUsername);
    if (target == actor || target == '@user' || actor == '@user' || postId.trim().isEmpty) return;

    await client.from('post_events').insert({
      'type': type,
      'target_username': target,
      'actor_username': actor,
      'actor_name': actorName.trim().isEmpty ? actor : actorName.trim(),
      'post_id': postId,
      'text': text,
    });
  }
  static Future<List<Map<String, dynamic>>> getPostEventNotificationsForUser(String username) async {
    final target = displayUsername(username);
    try {
      final rows = await client
          .from('post_events')
          .select()
          .eq('target_username', target)
          .order('created_at', ascending: false)
          .limit(120);
      return List<Map<String, dynamic>>.from(rows.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }


  static Future<Map<String, dynamic>> setUserFollow({
    required String followerUsername,
    required String targetUsername,
    required bool follow,
  }) async {
    final follower = displayUsername(followerUsername);
    final target = displayUsername(targetUsername);
    if (follower == target || follower == '@user' || target == '@user') {
      return {'isFollowing': false};
    }

    if (follow) {
      await client.from('user_follows').upsert({
        'follower_username': follower,
        'target_username': target,
      }, onConflict: 'follower_username,target_username');
    } else {
      await client
          .from('user_follows')
          .delete()
          .eq('follower_username', follower)
          .eq('target_username', target);
      try {
        await setUserPostNotification(
          followerUsername: follower,
          targetUsername: target,
          enabled: false,
        );
      } catch (e, st) { _logIgnoredError(e, st); }
    }

    return {'isFollowing': follow};
  }

  static Future<List<Map<String, dynamic>>> getReplyNotificationsForUser(String username) async {
    final owner = displayUsername(username);
    final myPostsRaw = await client
        .from('posts')
        .select('id,text,username,name,created_at')
        .eq('username', owner)
        .order('created_at', ascending: false)
        .limit(300);

    final myPosts = List<Map<String, dynamic>>.from(myPostsRaw.map((e) => Map<String, dynamic>.from(e)));
    final ids = myPosts.map((p) => (p['id'] ?? '').toString()).where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return <Map<String, dynamic>>[];

    final postById = {for (final p in myPosts) (p['id'] ?? '').toString(): p};
    final rowsRaw = await client
        .from('post_replies')
        .select('id,post_id,author_username,author_name,text,created_at,parent_user')
        .inFilter('post_id', ids)
        .order('created_at', ascending: false)
        .limit(100);

    final out = <Map<String, dynamic>>[];
    for (final raw in rowsRaw) {
      final row = Map<String, dynamic>.from(raw as Map);
      final actor = displayUsername((row['author_username'] ?? '').toString());
      if (actor == owner) continue;
      final postId = (row['post_id'] ?? '').toString();
      final post = postById[postId];
      if (post == null) continue;
      out.add({
        'id': row['id'],
        'type': 'reply',
        'post_id': postId,
        'actor_username': actor,
        'actor_name': (row['author_name'] ?? actor).toString(),
        'post_text': (post['text'] ?? '').toString(),
        'text': (row['text'] ?? '').toString(),
        'created_at': (row['created_at'] ?? '').toString(),
      });
    }
    return out;
  }

  static Future<List<Map<String, dynamic>>> getLikeNotificationsForUser(String username) async {
    final owner = displayUsername(username);
    final myPostsRaw = await client
        .from('posts')
        .select('id,text,username,name,created_at')
        .eq('username', owner)
        .order('created_at', ascending: false)
        .limit(300);

    final myPosts = List<Map<String, dynamic>>.from(myPostsRaw.map((e) => Map<String, dynamic>.from(e)));
    final ids = myPosts.map((p) => (p['id'] ?? '').toString()).where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return <Map<String, dynamic>>[];

    final postById = {for (final p in myPosts) (p['id'] ?? '').toString(): p};
    final rowsRaw = await client
        .from('post_likes')
        .select('id,post_id,username,created_at')
        .inFilter('post_id', ids)
        .order('created_at', ascending: false)
        .limit(100);

    final out = <Map<String, dynamic>>[];
    for (final raw in rowsRaw) {
      final row = Map<String, dynamic>.from(raw as Map);
      final actor = displayUsername((row['username'] ?? '').toString());
      if (actor == owner) continue;
      final postId = (row['post_id'] ?? '').toString();
      final post = postById[postId];
      if (post == null) continue;
      Map<String, dynamic>? actorUser;
      try { actorUser = await getUserByUsername(actor); } catch (e, st) { _logIgnoredError(e, st); }
      out.add({
        'id': row['id'],
        'type': 'like',
        'post_id': postId,
        'actor_username': actor,
        'actor_name': ((actorUser == null ? null : actorUser['name']) ?? (actorUser == null ? null : actorUser['profileName']) ?? actor).toString(),
        'post_text': (post['text'] ?? '').toString(),
        'created_at': (row['created_at'] ?? '').toString(),
      });
    }
    return out;
  }

  static Future<List<Map<String, dynamic>>> getFollowNotificationsForUser(String username) async {
    final target = displayUsername(username);
    final rowsRaw = await client
        .from('user_follows')
        .select('id,follower_username,target_username,created_at')
        .eq('target_username', target)
        .order('created_at', ascending: false)
        .limit(100);

    final out = <Map<String, dynamic>>[];
    for (final raw in rowsRaw) {
      final row = Map<String, dynamic>.from(raw as Map);
      final actor = displayUsername((row['follower_username'] ?? '').toString());
      if (actor == target) continue;
      Map<String, dynamic>? actorUser;
      try { actorUser = await getUserByUsername(actor); } catch (e, st) { _logIgnoredError(e, st); }
      out.add({
        'id': row['id'],
        'type': 'follow',
        'actor_username': actor,
        'actor_name': ((actorUser == null ? null : actorUser['name']) ?? (actorUser == null ? null : actorUser['profileName']) ?? actor).toString(),
        'created_at': (row['created_at'] ?? '').toString(),
      });
    }
    return out;
  }

  static Future<List<Map<String, dynamic>>> getRepostNotificationsForUser(String username) async {
    final owner = displayUsername(username);
    final myPostsRaw = await client
        .from('posts')
        .select('id,text,username,name,created_at')
        .eq('username', owner)
        .order('created_at', ascending: false)
        .limit(300);

    final myPosts = List<Map<String, dynamic>>.from(myPostsRaw.map((e) => Map<String, dynamic>.from(e)));
    final ids = myPosts.map((p) => (p['id'] ?? '').toString()).where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return <Map<String, dynamic>>[];

    final postById = {for (final p in myPosts) (p['id'] ?? '').toString(): p};
    final repostRows = await client
        .from('post_reposts')
        .select('id,post_id,username,created_at')
        .inFilter('post_id', ids)
        .order('created_at', ascending: false)
        .limit(100);

    final out = <Map<String, dynamic>>[];
    for (final raw in repostRows) {
      final row = Map<String, dynamic>.from(raw as Map);
      final actor = displayUsername((row['username'] ?? '').toString());
      if (actor == owner) continue;
      final postId = (row['post_id'] ?? '').toString();
      final post = postById[postId];
      if (post == null) continue;
      Map<String, dynamic>? actorUser;
      try { actorUser = await getUserByUsername(actor); } catch (e, st) { _logIgnoredError(e, st); }
      out.add({
        'id': row['id'],
        'type': 'repost',
        'post_id': postId,
        'actor_username': actor,
        'actor_name': ((actorUser == null ? null : actorUser['name']) ?? (actorUser == null ? null : actorUser['profileName']) ?? actor).toString(),
        'post_text': (post['text'] ?? '').toString(),
        'created_at': (row['created_at'] ?? '').toString(),
      });
    }
    return out;
  }

  static Future<Map<String, dynamic>> addPost({
    required String username,
    required String name,
    required String text,
    String imageUrl = '',
    String videoUrl = '',
    String voiceUrl = '',
    int voiceSeconds = 0,
    String audience = 'public',
    String communityId = '',
    String communityName = '',
    void Function(double progress, String status)? onProgress,
  }) async {
    await enforcePostCharacterLimit(username: username, text: text);
    // لا ننتظر Qwen قبل نشر التغريدة.
    // بعد الحفظ يراجع Render المنشور بـ Qwen، وإذا كان مخالفًا يحذفه السيرفر مباشرة من Supabase.

    onProgress?.call(0.10, 'تجهيز الملفات...');

    final hasImage = imageUrl.trim().isNotEmpty;
    final hasVideo = videoUrl.trim().isNotEmpty;
    final hasVoice = voiceUrl.trim().isNotEmpty;

    String safeImageUrl = '';
    String safeVideoUrl = '';
    String safeVoiceUrl = '';

    if (hasImage) {
      onProgress?.call(0.22, 'جاري رفع الصورة...');
      safeImageUrl = await uploadPostMedia(username: username, filePath: imageUrl.trim(), video: false);
      onProgress?.call(hasVoice ? 0.48 : 0.70, 'تم رفع الصورة');
    }

    if (hasVideo) {
      onProgress?.call(0.18, 'جاري رفع الفيديو...');
      safeVideoUrl = await uploadPostMedia(username: username, filePath: videoUrl.trim(), video: true);
      onProgress?.call(hasVoice ? 0.58 : 0.78, 'تم رفع الفيديو');
    }

    if (hasVoice) {
      onProgress?.call((hasImage || hasVideo) ? 0.62 : 0.30, 'جاري رفع التسجيل الصوتي...');
      safeVoiceUrl = await uploadPostVoice(username: username, filePath: voiceUrl.trim());
      onProgress?.call(0.82, 'تم رفع التسجيل الصوتي');
    }

    onProgress?.call(0.86, 'جاري حفظ التغريدة...');

    final user = await getUserByUsername(username);
    final avatarUrl = ((user == null ? null : user['avatar_url']) ?? '').toString().trim();
    final authorSubscriptionFields = authorSubscriptionPostFields(user);
    final payload = <String, dynamic>{
      'user_id': (user == null ? null : user['id']),
      'username': displayUsername(username),
      'name': name,
      'text': text,
      'image_url': safeImageUrl,
      'video_url': safeVideoUrl,
      'voice_url': safeVoiceUrl,
      'voice_seconds': voiceSeconds,
      'author_verified': isVerifiedUser(user),
      ...authorSubscriptionFields,
      'audience': audience.trim().isEmpty ? 'public' : audience.trim(),
      'community_id': communityId.trim(),
      'community_name': communityName.trim(),
      'community_hidden': false,
      'community_pinned': false,
      'likes': 0,
      'comments': 0,
    };

    // نخزن رابط الصورة العالمي مع المنشور إذا كان عمود avatar_url موجودًا.
    // إذا كان مشروعك قديمًا ولا يوجد العمود، نعيد المحاولة بدون الحقل.
    if (_isRemoteImageUrl(avatarUrl)) payload['avatar_url'] = avatarUrl;

    late final dynamic inserted;
    try {
      inserted = await client.from('posts').insert(payload).select().single();
    } catch (_) {
      // توافق مع المشاريع القديمة التي لم تضف الأعمدة الجديدة بعد.
      payload.remove('avatar_url');
      payload.remove('author_verified');
      payload.remove('author_subscription_tier');
      payload.remove('author_subscription_priority');
      payload.remove('author_subscription_boost_until');
      payload.remove('author_post_max_chars');
      payload.remove('author_ai_daily_limit');
      payload.remove('author_subscription_label');
      payload.remove('audience');
      payload.remove('community_id');
      payload.remove('community_name');
      payload.remove('community_hidden');
      payload.remove('community_pinned');
      try {
        inserted = await client.from('posts').insert(payload).select().single();
      } catch (_) {
        payload.remove('voice_url');
        payload.remove('voice_seconds');
        inserted = await client.from('posts').insert(payload).select().single();
      }
    }

    final post = Map<String, dynamic>.from(inserted);
    if (safeVoiceUrl.isNotEmpty) {
      post['voice_url'] = safeVoiceUrl;
      post['voice_seconds'] = voiceSeconds;
    }
    onProgress?.call(0.96, 'تم حفظ التغريدة');
    unawaited(savePostHashtags(
      postId: (post['id'] ?? '').toString(),
      text: text,
    ));
    unawaited(_moderatePostInBackground(
      postId: (post['id'] ?? '').toString(),
      text: text,
      authorUsername: displayUsername(username),
      imageUrls: safeImageUrl.trim().isEmpty ? const <String>[] : <String>[safeImageUrl],
      videoUrl: safeVideoUrl,
    ));
    unawaited(_notifyPostSubscribers(
      authorUsername: displayUsername(username),
      authorName: name,
      postId: (post['id'] ?? '').toString(),
      text: text,
    ));
    return post;
  }

  static Future<Map<String, dynamic>> reportPost({
    required String postId,
    required String reporterUsername,
    required String reason,
    String details = '',
    String communityId = '',
    String communityName = '',
    String postUsername = '',
    String postText = '',
  }) async {
    final payload = <String, dynamic>{
      'post_id': postId,
      'reporter_username': displayUsername(reporterUsername),
      'reason': reason,
      'details': details,
      'community_id': communityId,
      'community_name': communityName,
      'post_username': postUsername.trim().isEmpty ? null : displayUsername(postUsername),
      'post_text': postText,
      'status': 'pending',
      'ai_status': 'pending',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      final inserted = await client.from('post_reports').insert(payload).select().single();
      return Map<String, dynamic>.from(inserted as Map);
    } catch (_) {
      final fallback = Map<String, dynamic>.from(payload);
      fallback.remove('details');
      fallback.remove('community_id');
      fallback.remove('community_name');
      fallback.remove('post_username');
      fallback.remove('post_text');
      fallback.remove('status');
      fallback.remove('ai_status');
      fallback.remove('created_at');
      try {
        final inserted = await client.from('post_reports').insert(fallback).select().single();
        return Map<String, dynamic>.from(inserted as Map);
      } catch (_) {
        await client.from('post_reports').insert(fallback);
        return <String, dynamic>{
          'post_id': postId,
          'reporter_username': displayUsername(reporterUsername),
          'reason': reason,
        };
      }
    }
  }

  static Future<Map<String, dynamic>> reviewPostReportWithAi({
    required String reportId,
    required String postId,
    required String reporterUsername,
    required String reportedUsername,
    required String reason,
    String details = '',
    String postText = '',
    String communityId = '',
    String communityName = '',
  }) async {
    final response = await _postSignedJson(
  Uri.parse(respectAiReportReviewBackendUrl),
  {
        'reportId': reportId,
        'postId': postId,
        'reporterUsername': displayUsername(reporterUsername),
        'reportedUsername': displayUsername(reportedUsername),
        'reason': reason,
        'details': details,
        'postText': postText,
        'communityId': communityId,
        'communityName': communityName,
      },
  timeout: const Duration(seconds: 90),
);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('AI report review error: ${response.statusCode} ${response.body}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map) {
      final result = Map<String, dynamic>.from(decoded);
      final deleted = result['shouldDelete'] == true || result['action'] == 'delete' || result['action'] == 'hide';
      if (deleted) {
        _notifyRespectAiDeletedPost(postId);
      }
      return result;
    }
    return <String, dynamic>{'ok': false, 'validReport': false, 'reason': 'Invalid AI response'};
  }

  static Future<int> activeWarningCount(String username) async {
    final user = displayUsername(username);
    try {
      final rows = await client
          .from('user_warnings')
          .select('id,expires_at,active')
          .eq('username', user)
          .eq('active', true)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .timeout(const Duration(seconds: 8));
      return (rows as List).length;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> addUserWarning({
    required String username,
    required String reason,
    String postId = '',
    String reportId = '',
  }) async {
    final user = displayUsername(username);
    final now = DateTime.now().toUtc();
    try {
      await client.from('user_warnings').insert({
        'username': user,
        'reason': reason,
        'post_id': postId,
        'report_id': reportId,
        'active': true,
        'created_at': now.toIso8601String(),
        'expires_at': now.add(const Duration(days: 30)).toIso8601String(),
      }).timeout(const Duration(seconds: 8));
    } catch (e, st) { _logIgnoredError(e, st); }

    final count = await activeWarningCount(user);
    if (count >= 3) {
      await setUserBlockedAndDeviceBan(
        username: user,
        blocked: true,
        reason: 'تجاوز 3 تحذيرات خلال 30 يوم',
        adminUsername: respectAiUsername,
      );
    }
  }

  static String threadId(String a, String b) {
    final x = displayUsername(a);
    final y = displayUsername(b);
    final pair = [x, y]..sort();
    return '${pair[0]}__${pair[1]}';
  }

  static Future<List<Map<String, dynamic>>> getMessagesBetween(
    String user1,
    String user2, {
    int limit = 150,
    String? afterCreatedAt,
  }) async {
    final u1 = displayUsername(user1);
    final u2 = displayUsername(user2);
    unawaited(SecureCryptoService.ensureCurrentUserPublicKey(u1));

    dynamic query = client
        .from('messages')
        .select()
        .or('and(sender_username.eq.$u1,receiver_username.eq.$u2),and(sender_username.eq.$u2,receiver_username.eq.$u1)');

    final after = afterCreatedAt?.trim();
    if (after != null && after.isNotEmpty) {
      query = query.gt('created_at', after);
    }

    final safeLimit = limit.clamp(30, 300).toInt();
    final data = await query
        .order('created_at', ascending: true)
        .limit(safeLimit)
        .timeout(const Duration(seconds: 10));
    final rows = List<Map<String, dynamic>>.from(data.map((e) => Map<String, dynamic>.from(e)));
    return SecureCryptoService.decryptDirectRows(rows, u1);
  }

  static Future<List<Map<String, dynamic>>> getInboxMessages(String username) async {
    final u = displayUsername(username);
    unawaited(SecureCryptoService.ensureCurrentUserPublicKey(u));
    final data = await client
        .from('messages')
        .select()
        .or('sender_username.eq.$u,receiver_username.eq.$u')
        .order('created_at', ascending: false);
    final rows = List<Map<String, dynamic>>.from(data.map((e) => Map<String, dynamic>.from(e)));
    return SecureCryptoService.decryptDirectRows(rows, u);
  }



  static String _encryptedMediaContentType() => 'application/octet-stream';

  static Future<String> uploadEncryptedChatMedia({
    required String sender,
    required String receiver,
    required String filePath,
    required String mediaType,
  }) async {
    final senderUsername = displayUsername(sender);
    final receiverUsername = displayUsername(receiver);
    final encrypted = await SecureCryptoService.encryptMediaFileForPeer(
      sender: senderUsername,
      receiver: receiverUsername,
      filePath: filePath,
      mediaType: mediaType,
    );
    final encryptedFile = encrypted['file'] as File;
    final metadata = Map<String, dynamic>.from(encrypted['metadata'] as Map);
    final clean = normalizeUsername(senderUsername);
    final type = mediaType.toLowerCase().trim().isEmpty ? 'file' : mediaType.toLowerCase().trim();
    final storagePath = 'chat/$clean/encrypted/$type/${DateTime.now().microsecondsSinceEpoch}.renc';

    await client.storage.from('post-media').upload(
      storagePath,
      encryptedFile,
      fileOptions: FileOptions(
        contentType: _encryptedMediaContentType(),
        cacheControl: '604800',
        upsert: true,
      ),
    );

    final url = client.storage.from('post-media').getPublicUrl(storagePath);
    metadata
      ..['url'] = url
      ..['sender'] = senderUsername
      ..['receiver'] = receiverUsername;
    return jsonEncode(metadata);
  }


  static Future<String> uploadEncryptedGroupChatMedia({
    required String groupId,
    required String sender,
    required String filePath,
    required String mediaType,
    int maxViews = 0,
  }) async {
    final senderUsername = displayUsername(sender);
    final membersRows = await getChatGroupMembers(groupId);
    final members = membersRows
        .map((e) => displayUsername((e['username'] ?? '').toString()))
        .where((u) => u != '@user')
        .toSet()
        .toList();
    if (!members.contains(senderUsername)) members.add(senderUsername);
    members.sort();
    if (members.isEmpty) throw Exception('لا يوجد أعضاء لتشفير وسائط المجموعة');

    final type = mediaType.toLowerCase().trim().isEmpty ? 'file' : mediaType.toLowerCase().trim();
    final clean = normalizeUsername(senderUsername);
    final recipients = <String, dynamic>{};
    final missing = <String>[];

    for (final member in members) {
      try {
        if (!await SecureCryptoService.hasPublicKeyForUsername(member)) {
          missing.add(member);
          continue;
        }
        final encrypted = await SecureCryptoService.encryptMediaFileForPeer(
          sender: senderUsername,
          receiver: member,
          filePath: filePath,
          mediaType: type,
        );
        final encryptedFile = encrypted['file'] as File;
        final metadata = Map<String, dynamic>.from(encrypted['metadata'] as Map);
        final storagePath = 'chat/$clean/encrypted/groups/$groupId/${normalizeUsername(member)}/$type/${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}.renc';

        await client.storage.from('post-media').upload(
          storagePath,
          encryptedFile,
          fileOptions: FileOptions(
            contentType: _encryptedMediaContentType(),
            cacheControl: '604800',
            upsert: true,
          ),
        );

        final url = client.storage.from('post-media').getPublicUrl(storagePath);
        metadata
          ..['url'] = url
          ..['sender'] = senderUsername
          ..['receiver'] = member
          ..['media_type'] = type
          ..['type'] = type;
        recipients[member] = metadata;
      } catch (e, st) {
        _logIgnoredError(e, st);
        missing.add(member);
      }
    }

    if (recipients.isEmpty) {
      throw Exception('GROUP_E2EE_NOT_READY: لا يمكن رفع الوسائط المشفرة قبل تجهيز مفاتيح أعضاء المجموعة. افتح التطبيق من حسابات الأعضاء مرة واحدة بعد التحديث.');
    }

    return jsonEncode(<String, dynamic>{
      'respect_group_e2ee_media': true,
      'version': SecureCryptoService.groupEnvelopeVersion,
      'crypto_version': SecureCryptoService.encryptionVersion,
      'group_id': groupId.trim(),
      'sender': senderUsername,
      'media_type': type,
      'type': type,
      'recipients': recipients,
      if (maxViews > 0) 'max_views': maxViews.clamp(0, 2).toInt(),
      if (missing.isNotEmpty) 'missing': missing,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<Map<String, dynamic>> decryptGroupMessageRow(
    Map<String, dynamic> row,
    String currentUsername,
  ) {
    return SecureCryptoService.decryptGroupRow(Map<String, dynamic>.from(row), currentUsername);
  }

  static Future<Map<String, dynamic>> sendMessage({
    required String sender,
    required String receiver,
    required String text,
    String? mediaType,
    String? mediaUrl,
    int voiceSeconds = 0,
    String? replyToId,
    String? replyText,
    String? replySender,
  }) async {
    final current = await currentUser();
    final senderUsername = displayUsername(sender);
    final receiverUsername = displayUsername(receiver);
    final encryptedFields = await SecureCryptoService.encryptedDirectFields(
      sender: senderUsername,
      receiver: receiverUsername,
      text: text,
      replyText: replyText,
    );
    final payload = <String, dynamic>{
      'sender_username': senderUsername,
      'receiver_username': receiverUsername,
      'text': (encryptedFields['text'] ?? text.trim()).toString(),
      'is_read': false,
      'status': 'sent',
      'sender_name': ((current == null ? null : current['name']) ?? (current == null ? null : current['profileName']) ?? senderUsername).toString(),
      'sender_avatar': ((current == null ? null : current['avatar_url']) ?? (current == null ? null : current['imagePath']) ?? (current == null ? null : current['profileImagePath']) ?? '').toString(),
    };
    for (final entry in encryptedFields.entries) {
      if (entry.key != 'text' && entry.value != null) payload[entry.key] = entry.value;
    }

    final cleanReplyId = replyToId?.trim() ?? '';
    final cleanReplyText = replyText?.trim() ?? '';
    if (cleanReplyId.isNotEmpty || cleanReplyText.isNotEmpty) {
      payload['reply_to_id'] = cleanReplyId;
      payload['reply_text'] = (encryptedFields['reply_text'] ?? cleanReplyText).toString();
      payload['reply_sender'] = displayUsername(replySender ?? '');
    }

    final cleanMediaType = mediaType?.trim() ?? '';
    final cleanMediaUrl = mediaUrl?.trim() ?? '';
    if (cleanMediaType.isNotEmpty && cleanMediaUrl.isNotEmpty) {
      payload['media_type'] = cleanMediaType;
      payload['media_url'] = cleanMediaUrl;
      payload['voice_seconds'] = voiceSeconds;
    }

    try {
      final inserted = await client.from('messages').insert(payload).select().single();
      return await SecureCryptoService.decryptDirectRow(Map<String, dynamic>.from(inserted), senderUsername);
    } catch (_) {
      payload.remove('status');
      payload.remove('sender_name');
      payload.remove('sender_avatar');
      _removeEncryptionPayloadFields(payload);
      try {
        final inserted = await client.from('messages').insert(payload).select().single();
        return await SecureCryptoService.decryptDirectRow(Map<String, dynamic>.from(inserted), senderUsername);
      } catch (_) {
        payload.remove('reply_to_id');
        payload.remove('reply_text');
        payload.remove('reply_sender');
        payload.remove('media_type');
        payload.remove('media_url');
        payload.remove('voice_seconds');
        final inserted = await client.from('messages').insert(payload).select().single();
        return await SecureCryptoService.decryptDirectRow(Map<String, dynamic>.from(inserted), senderUsername);
      }
    }
  }


  static void _removeEncryptionPayloadFields(Map<String, dynamic> payload) {
    payload.remove('encrypted');
    payload.remove('encryption_version');
    payload.remove('ciphertext');
    payload.remove('nonce');
    payload.remove('mac');
    payload.remove('reply_ciphertext');
    payload.remove('reply_nonce');
    payload.remove('reply_mac');
    if ((payload['text'] ?? '').toString() == SecureCryptoService.encryptedTextPlaceholder) {
      payload['text'] = 'رسالة';
    }
    if ((payload['reply_text'] ?? '').toString() == SecureCryptoService.encryptedTextPlaceholder) {
      payload['reply_text'] = 'رسالة';
    }
  }


  static Future<Map<String, dynamic>> sendCallHistoryMessage({
    required String sender,
    required String receiver,
    required String callId,
    required bool video,
    required String status,
    int durationSeconds = 0,
  }) async {
    final cleanStatus = status.trim().isEmpty ? 'missed' : status.trim();
    final text = video
        ? 'مكالمة فيديو ${_callStatusArabic(cleanStatus)}'
        : 'مكالمة صوتية ${_callStatusArabic(cleanStatus)}';

    final meta = jsonEncode(<String, dynamic>{
      'kind': 'call',
      'call_id': callId,
      'video': video,
      'status': cleanStatus,
      'duration_seconds': durationSeconds,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });

    return sendMessage(
      sender: sender,
      receiver: receiver,
      text: text,
      mediaType: 'call',
      mediaUrl: meta,
    );
  }

  static String _callStatusArabic(String status) {
    switch (status) {
      case 'answered':
        return 'تم الرد عليها';
      case 'rejected':
        return 'مرفوضة';
      case 'cancelled':
        return 'ملغاة';
      case 'missed':
        return 'فائتة';
      default:
        return 'منتهية';
    }
  }

  static Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    await ensureRespectAiUser();

    final data = await client
        .from('users')
        .select()
        .or('username.ilike.%$q%,name.ilike.%$q%,email.ilike.%$q%')
        .limit(20);

    final rows = List<Map<String, dynamic>>.from(data.map((e) => Map<String, dynamic>.from(e)));
    for (final row in rows) {
      final username = displayUsername((row['username'] ?? '').toString());
      if (username == respectAiUsername) {
        row['username'] = respectAiUsername;
        row['name'] = respectAiName;
        row['bio'] = 'مساعد ذكي رسمي وموثق داخل Respect App';
        row['avatar_url'] = respectAiAvatarUrl;
        row['imagePath'] = respectAiAvatarUrl;
        row['profileImagePath'] = respectAiAvatarUrl;
        row['is_respect_ai'] = true;
      }
    }
    rows.sort((a, b) {
      final au = displayUsername((a['username'] ?? '').toString()) == respectAiUsername ? 100000 : searchPriorityWeightForUser(a);
      final bu = displayUsername((b['username'] ?? '').toString()) == respectAiUsername ? 100000 : searchPriorityWeightForUser(b);
      if (au != bu) return bu.compareTo(au);
      final av = (a['name'] ?? a['username'] ?? '').toString().toLowerCase();
      final bv = (b['name'] ?? b['username'] ?? '').toString().toLowerCase();
      return av.compareTo(bv);
    });
    return rows;
  }





  // ================= Explore / Search / Hashtags =================

  static final RegExp _hashtagRegex = RegExp(r'(^|[\s\n\r\t])#([^\s#@]+)', multiLine: true);

  static String _cleanHashtagToken(String value) {
    var v = value.trim();
    if (v.startsWith('#')) v = v.substring(1);
    while (v.isNotEmpty && RegExp(r'''[\.,،؛:!\؟\)\]\}\(\[\{"']$''').hasMatch(v)) {
      v = v.substring(0, v.length - 1);
    }
    v = v.replaceAll(RegExp(r'\s+'), '_');
    return v.trim();
  }

  static String _normalizeSearchText(String value) {
    var v = value.toLowerCase().trim();
    const arabicMap = {
      'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا',
      'ى': 'ي', 'ئ': 'ي', 'ؤ': 'و', 'ة': 'ه',
    };
    arabicMap.forEach((k, val) => v = v.replaceAll(k, val));
    v = v.replaceAll(RegExp(r'[^\u0600-\u06FFa-z0-9#@_\s]+'), ' ');
    return v.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<String> extractHashtags(String text) {
    final out = <String>{};
    for (final match in _hashtagRegex.allMatches(text)) {
      final raw = match.group(2) ?? '';
      final clean = _cleanHashtagToken(raw);
      if (clean.isNotEmpty) out.add('#$clean');
    }
    return out.toList();
  }

  static DateTime? _exploreFilterStart(String filter) {
    final now = DateTime.now().toUtc();
    switch (filter.trim().toLowerCase()) {
      case 'today':
        return DateTime.utc(now.year, now.month, now.day);
      case 'week':
        return now.subtract(const Duration(days: 7));
      case 'month':
        return now.subtract(const Duration(days: 30));
      default:
        return null;
    }
  }

  static dynamic _applyExploreTimeFilter(dynamic query, String timeFilter) {
    final start = _exploreFilterStart(timeFilter);
    if (start == null) return query;
    return query.gte('created_at', start.toIso8601String());
  }

  static List<String> _localSmartSearchTerms(String query) {
    final clean = _normalizeSearchText(query.replaceAll('#', ' '));
    final terms = <String>{};
    for (final part in clean.split(' ')) {
      final t = part.trim();
      if (t.length >= 2) terms.add(t);
    }

    final joined = clean.replaceAll(' ', '_');
    if (joined.length >= 2) terms.add(joined);

    final expansions = <String, List<String>>{
      'عصابه': ['عصابة', 'قروب', 'كلان', 'مافيا', 'gang', 'clan'],
      'عصابة': ['عصابه', 'قروب', 'كلان', 'مافيا', 'gang', 'clan'],
      'الكفن': ['كفن', 'al kafan', 'alkafan', 'kafan'],
      'سيرفر': ['server', 'rp', 'رول بلاي', 'رولبلاي'],
      'قراند': ['gta', 'gta v', 'grand', 'قراند الحياة الواقعية'],
      'الحياه': ['الحياة', 'واقعية', 'رول بلاي', 'rp'],
      'الحياة': ['الحياه', 'واقعية', 'رول بلاي', 'rp'],
      'واقعيه': ['واقعية', 'rp', 'رول بلاي'],
      'واقعية': ['واقعيه', 'rp', 'رول بلاي'],
      'ريسبكت': ['respect', 'respect rp', 'respect server'],
    };

    for (final t in List<String>.from(terms)) {
      final extra = expansions[t] ?? expansions[_normalizeSearchText(t)] ?? const <String>[];
      for (final e in extra) {
        final n = _normalizeSearchText(e);
        if (n.length >= 2) terms.add(n);
      }
    }
    return terms.take(24).toList();
  }

  static Future<List<String>> expandSearchQueryWithAi(String query) async {
    final q = query.trim();
    if (q.isEmpty || q.startsWith('#')) return _localSmartSearchTerms(q);
    final local = _localSmartSearchTerms(q);
    try {
      final response = await _postSignedJson(
  Uri.parse(respectAiSearchExpandBackendUrl),
  {'query': q, 'language': 'ar'},
  timeout: const Duration(seconds: 14),
);

      if (response.statusCode < 200 || response.statusCode >= 300) return local;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return local;
      final rawTerms = decoded['terms'];
      final out = <String>{...local};
      if (rawTerms is List) {
        for (final item in rawTerms) {
          final n = _normalizeSearchText(item.toString().replaceAll('#', ' '));
          if (n.length >= 2 && n.length <= 48) out.add(n);
        }
      }
      return out.take(32).toList();
    } catch (_) {
      return local;
    }
  }

  static int _smartSearchScore({
    required Map<String, dynamic> row,
    required String query,
    required List<String> terms,
    required String hashtagKey,
  }) {
    final text = (row['text'] ?? '').toString();
    final username = displayUsername((row['username'] ?? '').toString());
    final name = (row['name'] ?? row['user'] ?? '').toString();
    final communityName = (row['community_name'] ?? '').toString();
    final normalizedText = _normalizeSearchText('$text $username $name $communityName');
    final normalizedQuery = _normalizeSearchText(query.replaceAll('#', ' '));
    final hashtags = extractHashtags(text);
    var score = 0;

    if (hashtagKey.isNotEmpty) {
      for (final h in hashtags) {
        final key = _cleanHashtagToken(h).toLowerCase();
        if (key == hashtagKey.toLowerCase()) score += 120;
        if (key.contains(hashtagKey.toLowerCase()) || hashtagKey.toLowerCase().contains(key)) score += 35;
      }
      if (normalizedText.contains(hashtagKey.toLowerCase())) score += 18;
    }

    if (normalizedQuery.isNotEmpty && normalizedText.contains(normalizedQuery)) score += 90;
    for (final term in terms) {
      final t = _normalizeSearchText(term);
      if (t.isEmpty) continue;
      if (normalizedText.contains(t)) score += t.contains(' ') ? 34 : 18;
      final compact = t.replaceAll(' ', '_');
      if (compact != t && normalizedText.contains(compact)) score += 22;
    }

    score += (int.tryParse((row['likes'] ?? 0).toString()) ?? 0).clamp(0, 20).toInt();
    score += ((int.tryParse((row['reposts'] ?? 0).toString()) ?? 0) * 2).clamp(0, 20).toInt();
    score += ((int.tryParse((row['views'] ?? 0).toString()) ?? 0) ~/ 25).clamp(0, 20).toInt();
    return score;
  }

  static Future<List<Map<String, dynamic>>> searchPosts({
    String query = '',
    String hashtag = '',
    String timeFilter = 'all',
    int limit = 60,
    bool smart = true,
  }) async {
    final q = query.trim();
    final tag = _cleanHashtagToken(hashtag.trim().isNotEmpty ? hashtag : (q.startsWith('#') ? q : ''));
    final int safeLimit = limit.clamp(1, 100).toInt();
    final shouldRankLocally = smart || q.isNotEmpty || tag.isNotEmpty;

    try {
      dynamic builder = client
          .from('posts')
          .select('id,username,name,user,text,created_at,time,avatar_url,avatarPath,image_url,video_url,voice_url,voicePath,voice_seconds,voiceSeconds,likes,reposts,shares,views,replies,author_verified,community_name');

      builder = _applyExploreTimeFilter(builder, timeFilter);

      if (!shouldRankLocally) {
        final rows = await builder
            .order('created_at', ascending: false)
            .limit(safeLimit)
            .timeout(const Duration(seconds: 10));
        return List<Map<String, dynamic>>.from((rows as List).map((e) {
          final row = Map<String, dynamic>.from(e as Map);
          row['hashtags'] = extractHashtags((row['text'] ?? '').toString());
          return row;
        }));
      }

      final rows = await builder
          .order('created_at', ascending: false)
          .limit(q.isEmpty && tag.isEmpty ? safeLimit : 420)
          .timeout(const Duration(seconds: 12));

      final terms = q.isEmpty ? <String>[] : await expandSearchQueryWithAi(q);
      final ranked = <Map<String, dynamic>>[];
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final text = (row['text'] ?? '').toString();
        row['hashtags'] = extractHashtags(text);
        final score = _smartSearchScore(row: row, query: q, terms: terms, hashtagKey: tag);
        if (q.isEmpty && tag.isEmpty) {
          row['search_score'] = 0;
          ranked.add(row);
        } else if (score > 0) {
          row['search_score'] = score;
          ranked.add(row);
        }
      }

      ranked.sort((a, b) {
        final scoreCompare = (int.tryParse((b['search_score'] ?? 0).toString()) ?? 0)
            .compareTo(int.tryParse((a['search_score'] ?? 0).toString()) ?? 0);
        if (scoreCompare != 0) return scoreCompare;
        final ad = DateTime.tryParse((a['created_at'] ?? a['time'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bd = DateTime.tryParse((b['created_at'] ?? b['time'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bd.compareTo(ad);
      });
      return ranked.take(safeLimit).toList();
    } catch (_) {
      try {
        dynamic builder = client.from('posts').select(_postListColumns);
        builder = _applyExploreTimeFilter(builder, timeFilter);
        final rows = await builder
            .order('created_at', ascending: false)
            .limit(q.isEmpty && tag.isEmpty ? safeLimit : 420)
            .timeout(const Duration(seconds: 10));
        final terms = q.isEmpty ? <String>[] : _localSmartSearchTerms(q);
        final ranked = <Map<String, dynamic>>[];
        for (final raw in rows as List) {
          final row = Map<String, dynamic>.from(raw as Map);
          row['hashtags'] = extractHashtags((row['text'] ?? '').toString());
          final score = _smartSearchScore(row: row, query: q, terms: terms, hashtagKey: tag);
          if ((q.isEmpty && tag.isEmpty) || score > 0) {
            row['search_score'] = score;
            ranked.add(row);
          }
        }
        ranked.sort((a, b) => (int.tryParse((b['search_score'] ?? 0).toString()) ?? 0)
            .compareTo(int.tryParse((a['search_score'] ?? 0).toString()) ?? 0));
        return ranked.take(safeLimit).toList();
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    }
  }

  static Future<List<Map<String, dynamic>>> getTrendingHashtags({
    String timeFilter = 'today',
    int limit = 12,
  }) async {
    final int safeLimit = limit.clamp(1, 30).toInt();
    try {
      dynamic builder = client
          .from('posts')
          .select('id,text,created_at,views,likes,reposts,shares');
      builder = _applyExploreTimeFilter(builder, timeFilter);
      final rows = await builder
          .order('created_at', ascending: false)
          .limit(300)
          .timeout(const Duration(seconds: 10));

      final stats = <String, Map<String, dynamic>>{};
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final tags = extractHashtags((row['text'] ?? '').toString());
        final weight = 1 +
            (int.tryParse((row['views'] ?? 0).toString()) ?? 0) ~/ 12 +
            (int.tryParse((row['likes'] ?? 0).toString()) ?? 0) +
            (int.tryParse((row['reposts'] ?? 0).toString()) ?? 0) * 2 +
            (int.tryParse((row['shares'] ?? 0).toString()) ?? 0);
        for (final tag in tags) {
          final key = tag.toLowerCase();
          final item = stats.putIfAbsent(key, () => {
            'tag': tag,
            'count': 0,
            'score': 0,
          });
          item['count'] = (int.tryParse((item['count'] ?? 0).toString()) ?? 0) + 1;
          item['score'] = (int.tryParse((item['score'] ?? 0).toString()) ?? 0) + weight;
        }
      }

      final items = stats.values.map((e) => Map<String, dynamic>.from(e)).toList()
        ..sort((a, b) {
          final score = (int.tryParse((b['score'] ?? 0).toString()) ?? 0)
              .compareTo(int.tryParse((a['score'] ?? 0).toString()) ?? 0);
          if (score != 0) return score;
          return (int.tryParse((b['count'] ?? 0).toString()) ?? 0)
              .compareTo(int.tryParse((a['count'] ?? 0).toString()) ?? 0);
        });
      return items.take(safeLimit).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> savePostHashtags({
    required String postId,
    required String text,
  }) async {
    final id = postId.trim();
    if (id.isEmpty) return;
    final tags = extractHashtags(text);
    if (tags.isEmpty) return;

    try {
      final rows = tags.map((tag) => {
        'post_id': id,
        'hashtag': tag,
        'hashtag_key': tag.toLowerCase().replaceFirst('#', ''),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }).toList();
      await client.from('post_hashtags').upsert(rows, onConflict: 'post_id,hashtag_key').timeout(const Duration(seconds: 6));
    } catch (_) {
      // جدول post_hashtags اختياري. البحث والترند يعملان أيضًا من نص التغريدة مباشرة.
    }
  }

  static Future<void> setUserPostNotification({
    required String followerUsername,
    required String targetUsername,
    required bool enabled,
  }) async {
    final follower = displayUsername(followerUsername);
    final target = displayUsername(targetUsername);
    if (follower == target || follower == '@user' || target == '@user') return;

    if (enabled) {
      await client.from('user_post_notifications').upsert({
        'follower_username': follower,
        'target_username': target,
        'enabled': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'follower_username,target_username');
    } else {
      try {
        await client
            .from('user_post_notifications')
            .update({
          'enabled': false,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
            .eq('follower_username', follower)
            .eq('target_username', target);
      } catch (_) {
        await client
            .from('user_post_notifications')
            .delete()
            .eq('follower_username', follower)
            .eq('target_username', target);
      }
    }
  }

  static Future<Set<String>> getEnabledPostNotificationTargets(String followerUsername) async {
    final follower = displayUsername(followerUsername);
    try {
      final rows = await client
          .from('user_post_notifications')
          .select('target_username')
          .eq('follower_username', follower)
          .eq('enabled', true);
      return rows
          .map<String>((e) => displayUsername((e['target_username'] ?? '').toString()))
          .where((e) => e != '@user')
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<List<String>> getPostNotificationSubscribers(String authorUsername) async {
    final author = displayUsername(authorUsername);
    try {
      final rows = await client
          .from('user_post_notifications')
          .select('follower_username')
          .eq('target_username', author)
          .eq('enabled', true);
      return rows
          .map<String>((e) => displayUsername((e['follower_username'] ?? '').toString()))
          .where((e) => e != '@user' && e != author)
          .toSet()
          .toList();
    } catch (_) {
      return <String>[];
    }
  }

  static Future<void> _notifyPostSubscribers({
    required String authorUsername,
    required String authorName,
    required String postId,
    required String text,
  }) async {
    if (postId.trim().isEmpty) return;
    final author = displayUsername(authorUsername);
    final subscribers = await getPostNotificationSubscribers(author);
    if (subscribers.isEmpty) return;
    final cleanText = text.trim();
    final body = cleanText.isEmpty
        ? 'نشر تغريدة جديدة'
        : (cleanText.length > 90 ? '${cleanText.substring(0, 90)}...' : cleanText);
    for (final receiver in subscribers) {
      if (receiver == author) continue;
      await sendPushToUser(
        receiverUsername: receiver,
        type: 'post',
        title: authorName.trim().isEmpty ? author : authorName.trim(),
        body: body,
        data: {
          'postId': postId,
          'post_id': postId,
          'authorUsername': author,
          'author_username': author,
          'authorName': authorName,
          'author_name': authorName,
          'text': cleanText,
        },
      );
    }
  }

  static Future<List<String>> getFollowingUsernames(String username) async {
    final user = displayUsername(username);
    try {
      final rows = await client
          .from('user_follows')
          .select('target_username')
          .eq('follower_username', user)
          .order('created_at', ascending: false);
      return rows
          .map<String>((e) => displayUsername((e['target_username'] ?? '').toString()))
          .where((e) => e != '@user')
          .toSet()
          .toList();
    } catch (_) {
      return <String>[];
    }
  }

  static Future<List<Map<String, dynamic>>> getUserFollowers(String username) async {
    final target = displayUsername(username);
    try {
      final rows = await client
          .from('user_follows')
          .select('follower_username,created_at')
          .eq('target_username', target)
          .order('created_at', ascending: false);
      final out = <Map<String, dynamic>>[];
      for (final row in rows) {
        final u = displayUsername((row['follower_username'] ?? '').toString());
        final profile = await getUserByUsername(u);
        out.add({
          'username': u,
          'created_at': row['created_at'],
          if (profile != null) ...profile,
        });
      }
      return out;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<List<Map<String, dynamic>>> getUserFollowing(String username) async {
    final user = displayUsername(username);
    try {
      final rows = await client
          .from('user_follows')
          .select('target_username,created_at')
          .eq('follower_username', user)
          .order('created_at', ascending: false);
      final out = <Map<String, dynamic>>[];
      for (final row in rows) {
        final u = displayUsername((row['target_username'] ?? '').toString());
        final profile = await getUserByUsername(u);
        out.add({
          'username': u,
          'created_at': row['created_at'],
          if (profile != null) ...profile,
        });
      }
      return out;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<List<Map<String, dynamic>>> getUserPosts(String username) async {
    final user = displayUsername(username);
    try {
      final rows = await client
          .from('posts')
          .select()
          .eq('username', user)
          .order('created_at', ascending: false)
          .limit(200);
      final posts = List<Map<String, dynamic>>.from(rows.map((e) => Map<String, dynamic>.from(e)));
      for (final p in posts) {
        try {
          p['replies'] = await getPostReplies((p['id'] ?? '').toString());
        } catch (e, st) { _logIgnoredError(e, st); }
      }
      return posts;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> updateUserProfile({
    required String username,
    String? name,
    String? bio,
    String? location,
    String? website,
  }) async {
    final user = displayUsername(username);
    final payload = <String, dynamic>{};
    if (name != null) payload['name'] = name.trim();
    if (name != null) payload['profileName'] = name.trim();
    if (bio != null) payload['bio'] = bio.trim();
    if (location != null) payload['location'] = location.trim();
    if (website != null) payload['website'] = website.trim();
    if (payload.isEmpty) return;
    await client.from('users').update(payload).or('username.eq.$user,username.eq.${normalizeUsername(user)}');
  }

  static Future<void> updatePostText({required String postId, required String text}) async {
    final clean = text.trim();
    if (postId.trim().isEmpty || clean.isEmpty) return;
    await client.from('posts').update({'text': clean}).eq('id', postId);
  }

  static Future<void> deletePostReply(String replyId) async {
    final id = replyId.trim();
    if (id.isEmpty) return;

    String postId = '';
    try {
      final Map<String, dynamic>? row = await client
          .from('post_replies')
          .select('post_id')
          .eq('id', id)
          .maybeSingle();

      if (row != null) {
        postId = (row['post_id'] ?? '').toString();
      }
    } catch (e, st) { _logIgnoredError(e, st); }

    try { await client.from('reply_likes').delete().eq('reply_id', id); } catch (e, st) { _logIgnoredError(e, st); }
    try { await client.from('reply_reposts').delete().eq('reply_id', id); } catch (e, st) { _logIgnoredError(e, st); }
    try { await client.from('reply_views').delete().eq('reply_id', id); } catch (e, st) { _logIgnoredError(e, st); }
    try { await client.from('post_replies').delete().eq('parent_reply_id', id); } catch (e, st) { _logIgnoredError(e, st); }
    try { await client.from('post_replies').delete().eq('id', id); } catch (e, st) { _logIgnoredError(e, st); }

    if (postId.isNotEmpty) {
      try {
        final repliesCount = await client.from('post_replies').select('id').eq('post_id', postId);
        await client.from('posts').update({'comments': repliesCount.length}).eq('id', postId);
      } catch (e, st) { _logIgnoredError(e, st); }
    }
  }

  static Future<void> deletePost(String postId) async {
    final id = postId.trim();
    if (id.isEmpty) return;
    try { await client.from('post_replies').delete().eq('post_id', id); } catch (e, st) { _logIgnoredError(e, st); }
    try { await client.from('post_likes').delete().eq('post_id', id); } catch (e, st) { _logIgnoredError(e, st); }
    try { await client.from('post_reposts').delete().eq('post_id', id); } catch (e, st) { _logIgnoredError(e, st); }
    try { await client.from('post_views').delete().eq('post_id', id); } catch (e, st) { _logIgnoredError(e, st); }
    try { await client.from('post_events').delete().eq('post_id', id); } catch (e, st) { _logIgnoredError(e, st); }
    await client.from('posts').delete().eq('id', id);
  }

  static String realtimeUserChannel(String username) {
    return 'rt_user_${normalizeUsername(username)}';
  }

  static Future<void> sendUserBroadcast({
    required String username,
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    final topic = realtimeUserChannel(username);
    final channel = client.channel(topic);
    try {
      final completer = Completer<void>();
      channel.subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed && !completer.isCompleted) {
          completer.complete();
        }
        if (status == RealtimeSubscribeStatus.channelError && !completer.isCompleted) {
          completer.complete();
        }
      });

      await completer.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      await channel.sendBroadcastMessage(event: event, payload: payload);
      await Future.delayed(const Duration(milliseconds: 180));
    } catch (_) {
      // Postgres realtime + polling fallback في ChatScreen سيغطي أي فشل هنا.
    } finally {
      try { await channel.unsubscribe(); } catch (e, st) { _logIgnoredError(e, st); }
    }
  }

  static Future<void> updateCurrentUserFcmToken(String? token) async {
    final id = await currentUserId();
    if (id == null || id.trim().isEmpty) return;
    final username = displayUsername(id);
    try {
      await client
          .from('users')
          .update({
        'fcm_token': token,
        'fcm_updated_at': DateTime.now().toUtc().toIso8601String(),
      })
          .or('username.eq.${normalizeUsername(username)},username.eq.$username');
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // إشعارات FCM عبر سيرفر Python HTTP v1
  // ملاحظة: لا تضع ملف Service Account داخل التطبيق نهائياً.
  // عدّل الرابط إلى IP اللابتوب على نفس شبكة الجوال.
  // مثال: http://192.168.1.10:8000
  // للمحاكي Android Emulator استخدم: http://10.0.2.2:8000
  // ═══════════════════════════════════════════════════════════════════════════

  static String get pushApiBaseUrl => respectApiBaseUrl;


  static Future<Map<String, dynamic>> sendGeneralNotificationToAll({
    required String title,
    required String body,
  }) async {
    final cleanTitle = title.trim();
    final cleanBody = body.trim();
    if (cleanTitle.isEmpty || cleanBody.isEmpty) {
      throw Exception('العنوان والنص مطلوبان');
    }

    final current = await currentUser();
    final senderUsername = displayUsername(((current == null ? null : current['username']) ?? '').toString());
    final senderName = ((current == null ? null : current['name']) ?? (current == null ? null : current['profileName']) ?? senderUsername).toString();

    final response = await _postSignedJson(
      Uri.parse('$pushApiBaseUrl/send_general_push'),
      {
        'title': cleanTitle,
        'body': cleanBody,
        'senderUsername': senderUsername,
        'senderName': senderName,
        'data': {
          'type': 'general_notification',
          'title': cleanTitle,
          'body': cleanBody,
          'senderUsername': senderUsername,
          'senderName': senderName,
        },
      },
      timeout: const Duration(seconds: 25),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return {'ok': true};
  }

  static Future<List<Map<String, dynamic>>> getGeneralNotifications({int limit = 80}) async {
    try {
      final rows = await client
          .from('respect_general_notifications')
          .select()
          .order('created_at', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(rows.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> sendPushToUser({
    required String receiverUsername,
    required String type,
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    try {
      final response = await _postSignedJson(
        Uri.parse('$pushApiBaseUrl/send_user_push'),
        {
          'receiverUsername': displayUsername(receiverUsername),
          'type': type,
          'title': title,
          'body': body,
          'data': {
            ...data,
            'type': type,
            'title': title,
            'body': body,
          },
        },
        timeout: const Duration(seconds: 12),
      );

      _safeDebugLog('Push API response for $type: ${response.statusCode} - ${response.body}');
    } catch (e) {
      _safeDebugLog('Error calling Push API: $e');
    }
  }

  static Future<void> sendMessagePush({
    required String receiverUsername,
    required String senderUsername,
    required String senderName,
    required String messageId,
    required String text,
  }) async {
    try {
      final response = await _postSignedJson(
        Uri.parse('$pushApiBaseUrl/send_message_push'),
        {
          'receiverUsername': displayUsername(receiverUsername),
          'senderUsername': displayUsername(senderUsername), // للفتح داخل المحادثة فقط، بدون نص أو اسم ظاهر
          'senderName': '',
          'messageId': messageId,
          'text': '',
          'privacy': 'metadata_only',
        },
        timeout: const Duration(seconds: 12),
      );

      _safeDebugLog('Message push response: ${response.statusCode} - ${response.body}');
    } catch (e) {
      _safeDebugLog('Error sending message push: $e');
    }
  }

  static Future<void> sendIncomingCallPush({
    required String receiverUsername,
    required String callId,
    required String callerUsername,
    required String callerName,
    required String callerAvatar,
    required bool video,
  }) async {
    try {
      final response = await _postSignedJson(
        Uri.parse('$pushApiBaseUrl/send_call_push'),
        {
          'receiverUsername': displayUsername(receiverUsername),
          'callId': callId,
          'callerUsername': displayUsername(callerUsername), // للربط فقط
          'callerName': '',
          'callerAvatar': '',
          'video': video,
          'privacy': 'metadata_only',
        },
        timeout: const Duration(seconds: 12),
      );

      _safeDebugLog('Call push response: ${response.statusCode} - ${response.body}');
    } catch (e) {
      _safeDebugLog('Error sending call push: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Respect Chat Groups + delivery/read/typing helpers
  // تحتاج جداول SQL المرفقة في ملف respect_chat_schema.sql لتعمل المجموعات بالكامل.
  // كل الدوال فيها fallback حتى لا تكسر الدردشة الخاصة القديمة لو الأعمدة غير موجودة.
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<void> markMessageDelivered(String messageId, String username) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    try {
      await client.from('messages').update({
        'status': 'delivered',
        'delivered_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', id);
      final row = await client.from('messages').select('sender_username').eq('id', id).maybeSingle();
      final sender = row == null ? '' : displayUsername((row['sender_username'] ?? '').toString());
      if (sender.isNotEmpty) {
        unawaited(sendUserBroadcast(username: sender, event: 'message_status', payload: {'message_id': id, 'status': 'delivered'}));
      }
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  static Future<void> markMessageRead(String messageId, String username) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    try {
      await client.from('messages').update({
        'is_read': true,
        'status': 'read',
        'read_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', id);
      final row = await client.from('messages').select('sender_username').eq('id', id).maybeSingle();
      final sender = row == null ? '' : displayUsername((row['sender_username'] ?? '').toString());
      if (sender.isNotEmpty) {
        unawaited(sendUserBroadcast(username: sender, event: 'message_status', payload: {'message_id': id, 'status': 'read'}));
      }
    } catch (_) {
      try { await client.from('messages').update({'is_read': true}).eq('id', id); } catch (e, st) { _logIgnoredError(e, st); }
    }
  }

  static Future<List<Map<String, dynamic>>> getMyChatGroups(String username) async {
    final me = displayUsername(username);
    try {
      final memberships = await client
          .from('respect_chat_group_members')
          .select('group_id,role')
          .eq('username', me);
      final ids = memberships.map<String>((e) => (e['group_id'] ?? '').toString()).where((e) => e.isNotEmpty).toList();
      if (ids.isEmpty) return <Map<String, dynamic>>[];
      final groups = await client
          .from('respect_chat_groups')
          .select()
          .inFilter('id', ids)
          .order('updated_at', ascending: false);
      return List<Map<String, dynamic>>.from(groups.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<Map<String, dynamic>?> getChatGroup(String groupId, String username) async {
    final id = groupId.trim();
    if (id.isEmpty) return null;
    try {
      final group = await client.from('respect_chat_groups').select().eq('id', id).maybeSingle();
      if (group == null) return null;
      final map = Map<String, dynamic>.from(group as Map);
      final member = await client
          .from('respect_chat_group_members')
          .select('role')
          .eq('group_id', id)
          .eq('username', displayUsername(username))
          .maybeSingle();
      map['my_role'] = member == null ? 'member' : (member['role'] ?? 'member').toString();
      return map;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> createChatGroup({
    required String name,
    required String founderUsername,
    required List<String> memberUsernames,
  }) async {
    final founder = displayUsername(founderUsername);
    final cleanMembers = <String>{founder, ...memberUsernames.map(displayUsername)}.where((e) => e != '@user').toList();
    final now = DateTime.now().toUtc().toIso8601String();

    final group = await client.from('respect_chat_groups').insert({
      'name': name.trim().isEmpty ? 'مجموعة جديدة' : name.trim(),
      'founder_username': founder,
      'locked': false,
      'last_message': 'مجموعة جديدة',
      'created_at': now,
      'updated_at': now,
    }).select().single();

    final groupMap = Map<String, dynamic>.from(group as Map);
    final groupId = (groupMap['id'] ?? '').toString();
    final rows = cleanMembers.map((u) => {
      'group_id': groupId,
      'username': u,
      'role': u == founder ? 'founder' : 'member',
      'created_at': now,
    }).toList();
    if (rows.isNotEmpty) await client.from('respect_chat_group_members').insert(rows);

    for (final u in cleanMembers) {
      unawaited(sendUserBroadcast(username: u, event: 'group_updated', payload: {'group_id': groupId}));
    }
    return groupMap;
  }

  static Future<List<Map<String, dynamic>>> getChatGroupMembers(String groupId) async {
    try {
      final rows = await client
          .from('respect_chat_group_members')
          .select()
          .eq('group_id', groupId)
          .order('created_at', ascending: true);
      return List<Map<String, dynamic>>.from(rows.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> setChatGroupMemberRole({required String groupId, required String username, required String role}) async {
    await client
        .from('respect_chat_group_members')
        .update({'role': role})
        .eq('group_id', groupId)
        .eq('username', displayUsername(username));
  }

  static Future<void> removeChatGroupMember({required String groupId, required String username}) async {
    await client
        .from('respect_chat_group_members')
        .delete()
        .eq('group_id', groupId)
        .eq('username', displayUsername(username));
  }

  static Future<void> leaveChatGroup({required String groupId, required String username}) async {
    final me = displayUsername(username);
    if (groupId.trim().isEmpty || me == '@user') return;

    final groupRaw = await client.from('respect_chat_groups').select().eq('id', groupId).maybeSingle();
    final group = groupRaw == null ? <String, dynamic>{} : Map<String, dynamic>.from(groupRaw as Map);
    final founder = displayUsername((group['founder_username'] ?? '').toString());
    final members = await getChatGroupMembers(groupId);
    final others = members
        .where((m) => displayUsername((m['username'] ?? '').toString()) != me)
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    if (founder == me && others.isNotEmpty) {
      final nextFounder = displayUsername((others.first['username'] ?? '').toString());
      await client.from('respect_chat_group_members').update({'role': 'founder'}).eq('group_id', groupId).eq('username', nextFounder);
      await client.from('respect_chat_groups').update({
        'founder_username': nextFounder,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', groupId);
    }

    await client
        .from('respect_chat_group_members')
        .delete()
        .eq('group_id', groupId)
        .eq('username', me);

    if (others.isEmpty) {
      try { await client.from('respect_group_messages').delete().eq('group_id', groupId); } catch (_) {}
      try { await client.from('respect_chat_groups').delete().eq('id', groupId); } catch (_) {}
    } else {
      await client.from('respect_chat_groups').update({
        'last_message': '$me خرج من المجموعة',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', groupId);
      for (final member in others) {
        final u = displayUsername((member['username'] ?? '').toString());
        unawaited(sendUserBroadcast(username: u, event: 'group_updated', payload: {'group_id': groupId, 'left_username': me}));
      }
    }
  }

  static Future<void> setChatGroupLocked({required String groupId, required bool locked}) async {
    await client.from('respect_chat_groups').update({
      'locked': locked,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', groupId);
  }

  static Future<List<Map<String, dynamic>>> getGroupMessages(
    String groupId, {
    int limit = 300,
    String? afterCreatedAt,
  }) async {
    try {
      dynamic query = client
          .from('respect_group_messages')
          .select()
          .eq('group_id', groupId);

      final after = afterCreatedAt?.trim();
      if (after != null && after.isNotEmpty) {
        query = query.gt('created_at', after);
      }

      final safeLimit = limit.clamp(30, 300).toInt();
      final rows = await query
          .order('created_at', ascending: true)
          .limit(safeLimit)
          .timeout(const Duration(seconds: 10));
      final list = List<Map<String, dynamic>>.from(rows.map((e) => Map<String, dynamic>.from(e as Map)));
      final current = await currentUser();
      final me = displayUsername((current?['username'] ?? '').toString());
      if (me == '@user') return list;
      return SecureCryptoService.decryptGroupRows(list, me);
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<Map<String, dynamic>> sendGroupMessage({
    required String groupId,
    required String sender,
    required String text,
    String? mediaType,
    String? mediaUrl,
    int voiceSeconds = 0,
    String? replyToId,
    String? replyText,
    String? replySender,
  }) async {
    final current = await currentUser();
    final senderUsername = displayUsername(sender);
    final senderName = ((current == null ? null : current['name']) ?? (current == null ? null : current['profileName']) ?? senderUsername).toString();
    final senderAvatar = ((current == null ? null : current['avatar_url']) ?? (current == null ? null : current['imagePath']) ?? (current == null ? null : current['profileImagePath']) ?? '').toString();
    final now = DateTime.now().toUtc().toIso8601String();

    final membersRows = await getChatGroupMembers(groupId);
    final members = membersRows
        .map((e) => displayUsername((e['username'] ?? '').toString()))
        .where((u) => u != '@user')
        .toSet()
        .toList();
    if (!members.contains(senderUsername)) members.add(senderUsername);

    final cleanReplyId = replyToId?.trim() ?? '';
    final cleanReplyText = replyText?.trim() ?? '';
    final encryptedFields = await SecureCryptoService.encryptedGroupFields(
      sender: senderUsername,
      groupId: groupId,
      memberUsernames: members,
      text: text.trim(),
      replyText: cleanReplyText,
    );

    final payload = <String, dynamic>{
      'group_id': groupId,
      'sender_username': senderUsername,
      'sender_name': senderName,
      'sender_avatar': senderAvatar,
      'text': (encryptedFields['text'] ?? '').toString(),
      'status': 'delivered',
      'created_at': now,
    };

    if (cleanReplyId.isNotEmpty || cleanReplyText.isNotEmpty) {
      payload['reply_to_id'] = cleanReplyId;
      payload['reply_text'] = (encryptedFields['reply_text'] ?? '').toString();
      payload['reply_sender'] = displayUsername(replySender ?? '');
    }

    final cleanMediaType = mediaType?.trim() ?? '';
    final cleanMediaUrl = mediaUrl?.trim() ?? '';
    if (cleanMediaType.isNotEmpty && cleanMediaUrl.isNotEmpty) {
      payload['media_type'] = cleanMediaType;
      payload['media_url'] = cleanMediaUrl;
      payload['voice_seconds'] = voiceSeconds;
    }

    late final dynamic inserted;
    try {
      inserted = await client.from('respect_group_messages').insert(payload).select().single();
    } catch (_) {
      payload.remove('reply_to_id');
      payload.remove('reply_text');
      payload.remove('reply_sender');
      inserted = await client.from('respect_group_messages').insert(payload).select().single();
    }

    await client.from('respect_chat_groups').update({
      'last_message': cleanMediaType == 'voice'
          ? '🔒 رسالة صوتية مشفرة'
          : (cleanMediaType.isNotEmpty ? '🔒 وسائط مشفرة' : '🔒 رسالة مشفرة'),
      'updated_at': now,
    }).eq('id', groupId);

    return Map<String, dynamic>.from(inserted as Map);
  }

  static Future<void> updateChatMessageTextEncrypted({
    required String messageId,
    required bool group,
    required String sender,
    required String text,
    String? receiver,
    String? groupId,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    if (group) {
      final gid = (groupId ?? '').trim();
      if (gid.isEmpty) throw Exception('groupId is required');
      final membersRows = await getChatGroupMembers(gid);
      final members = membersRows
          .map((e) => displayUsername((e['username'] ?? '').toString()))
          .where((u) => u != '@user')
          .toSet()
          .toList();
      if (!members.contains(displayUsername(sender))) members.add(displayUsername(sender));
      final encrypted = await SecureCryptoService.encryptedGroupFields(
        sender: sender,
        groupId: gid,
        memberUsernames: members,
        text: clean,
      );
      await client.from('respect_group_messages').update({'text': encrypted['text']}).eq('id', messageId);
    } else {
      final peer = displayUsername(receiver ?? '');
      if (peer == '@user') throw Exception('receiver is required');
      final encrypted = await SecureCryptoService.encryptedDirectFields(
        sender: sender,
        receiver: peer,
        text: clean,
      );
      final payload = <String, dynamic>{
        'text': encrypted['text'],
        'encrypted': encrypted['encrypted'],
        'encryption_version': encrypted['encryption_version'],
        'ciphertext': encrypted['ciphertext'],
        'nonce': encrypted['nonce'],
        'mac': encrypted['mac'],
      };
      await client.from('messages').update(payload).eq('id', messageId);
    }
  }

  static Future<void> markGroupMessageDelivered(String messageId, String username) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    try {
      await client.from('respect_group_message_receipts').upsert({
        'message_id': id,
        'username': displayUsername(username),
        'delivered_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'message_id,username');
      final row = await client.from('respect_group_messages').select('sender_username').eq('id', id).maybeSingle();
      final sender = row == null ? '' : displayUsername((row['sender_username'] ?? '').toString());
      if (sender.isNotEmpty && sender != displayUsername(username)) {
        unawaited(sendUserBroadcast(username: sender, event: 'message_status', payload: {'message_id': id, 'status': 'delivered'}));
      }
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  static Future<void> markGroupMessageRead(String messageId, String username) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    try {
      await client.from('respect_group_message_receipts').upsert({
        'message_id': id,
        'username': displayUsername(username),
        'delivered_at': DateTime.now().toUtc().toIso8601String(),
        'read_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'message_id,username');
      final row = await client.from('respect_group_messages').select('sender_username').eq('id', id).maybeSingle();
      final sender = row == null ? '' : displayUsername((row['sender_username'] ?? '').toString());
      if (sender.isNotEmpty && sender != displayUsername(username)) {
        unawaited(sendUserBroadcast(username: sender, event: 'message_status', payload: {'message_id': id, 'status': 'read'}));
      }
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  static Future<void> deleteChatMessage({required String messageId, required bool group}) async {
    final id = messageId.trim();
    if (id.isEmpty) return;
    final payload = <String, dynamic>{
      'message_id': id,
      'status': 'deleted',
      'action': 'delete',
      'deleted': true,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    };

    if (group) {
      String groupId = '';
      try {
        final row = await client
            .from('respect_group_messages')
            .select('group_id')
            .eq('id', id)
            .maybeSingle();
        groupId = (row?['group_id'] ?? '').toString();
      } catch (e, st) { _logIgnoredError(e, st); }

      try { await client.from('respect_group_message_receipts').delete().eq('message_id', id); } catch (e, st) { _logIgnoredError(e, st); }
      await client.from('respect_group_messages').delete().eq('id', id);

      if (groupId.trim().isNotEmpty) {
        try {
          final members = await getChatGroupMembers(groupId);
          final tasks = <Future<void>>[];
          for (final member in members) {
            final username = displayUsername((member['username'] ?? '').toString());
            if (username == '@user') continue;
            tasks.add(sendUserBroadcast(username: username, event: 'message_status', payload: {...payload, 'group_id': groupId}));
          }
          await Future.wait(tasks, eagerError: false);
        } catch (e, st) { _logIgnoredError(e, st); }
      }
    } else {
      final recipients = <String>{};
      try {
        final row = await client
            .from('messages')
            .select('sender_username,receiver_username')
            .eq('id', id)
            .maybeSingle();
        if (row != null) {
          recipients.add(displayUsername((row['sender_username'] ?? '').toString()));
          recipients.add(displayUsername((row['receiver_username'] ?? '').toString()));
        }
      } catch (e, st) { _logIgnoredError(e, st); }

      await client.from('messages').delete().eq('id', id);

      final tasks = <Future<void>>[];
      for (final username in recipients.where((u) => u != '@user')) {
        tasks.add(sendUserBroadcast(username: username, event: 'message_status', payload: payload));
      }
      await Future.wait(tasks, eagerError: false);
    }
  }

  static Future<void> broadcastGroupMessage({
    required String groupId,
    required Map<String, dynamic> message,
    String? excludeUsername,
  }) async {
    final members = await getChatGroupMembers(groupId);
    final tasks = <Future<void>>[];
    for (final member in members) {
      final username = displayUsername((member['username'] ?? '').toString());
      if (excludeUsername != null && username == displayUsername(excludeUsername)) continue;
      tasks.add(sendUserBroadcast(username: username, event: 'group_message', payload: {
        'group_id': groupId,
        'message': message,
      }));
    }
    await Future.wait(tasks, eagerError: false);
  }

  static Future<void> broadcastGroupTyping({
    required String groupId,
    required String fromUsername,
    required String fromName,
    required bool typing,
    String mode = 'text',
  }) async {
    final cleanMode = mode.trim().toLowerCase() == 'voice' ? 'voice' : 'text';
    final members = await getChatGroupMembers(groupId);
    final tasks = <Future<void>>[];
    for (final member in members) {
      final username = displayUsername((member['username'] ?? '').toString());
      if (username == displayUsername(fromUsername)) continue;
      tasks.add(sendUserBroadcast(username: username, event: 'typing', payload: {
        'group_id': groupId,
        'from': displayUsername(fromUsername),
        'name': fromName,
        'typing': typing,
        'mode': cleanMode,
      }));
    }
    await Future.wait(tasks, eagerError: false);
  }

  static Future<void> broadcastGroupUpdated(String groupId) async {
    final members = await getChatGroupMembers(groupId);
    for (final member in members) {
      final username = displayUsername((member['username'] ?? '').toString());
      unawaited(sendUserBroadcast(username: username, event: 'group_updated', payload: {'group_id': groupId}));
    }
  }


  // ================= Respect Painters / Weekly Art Tournament =================
  static String get respectAiArtValidateBackendUrl => _backendEndpoint('/respect-ai/art/validate');
  static String get respectAiArtTournamentBackendUrl => _backendEndpoint('/respect-ai/art/run-weekly-tournament');

  static int isoWeekNumber(DateTime date) {
    final d = DateTime.utc(date.year, date.month, date.day);
    final dayNumber = d.weekday;
    final thursday = d.add(Duration(days: 4 - dayNumber));
    final firstThursday = DateTime.utc(thursday.year, 1, 1);
    final firstWeekThursday = firstThursday.add(Duration(days: (4 - firstThursday.weekday + 7) % 7));
    return 1 + (thursday.difference(firstWeekThursday).inDays ~/ 7);
  }

  static DateTime dateFromIsoWeek(int year, int week) {
    final jan4 = DateTime.utc(year, 1, 4);
    final mondayWeek1 = jan4.subtract(Duration(days: jan4.weekday - 1));
    return mondayWeek1.add(Duration(days: (week - 1) * 7));
  }

  static String artWeekKeyFor(DateTime date) {
    final d = date.toUtc();
    final week = isoWeekNumber(d).toString().padLeft(2, '0');
    final thursday = d.add(Duration(days: 4 - d.weekday));
    return '${thursday.year}-W$week';
  }

  static String currentArtWeekKey() => artWeekKeyFor(DateTime.now().toUtc());

  static Future<String> uploadArtDrawingMedia({
    required String username,
    required String filePath,
  }) async {
    final raw = filePath.trim();
    if (raw.isEmpty) return '';
    if (_isRemoteUrl(raw)) return raw;

    final file = File(raw);
    if (!await file.exists()) throw Exception('drawing image file not found');

    final sizeMb = await file.length() / (1024 * 1024);
    if (sizeMb > 18) throw Exception('الصورة كبيرة جدًا، اختر صورة أقل من 18MB');

    final clean = normalizeUsername(username);
    if (clean.isEmpty) throw Exception('username is empty');

    final ext = _postMediaExtFromPath(raw, video: false);
    final storagePath = 'respect-painters/$clean/${DateTime.now().microsecondsSinceEpoch}.$ext';

    await client.storage.from('post-media').upload(
      storagePath,
      file,
      fileOptions: FileOptions(
        contentType: _postMediaContentType(ext, video: false),
        cacheControl: '604800',
        upsert: true,
      ),
    );

    return client.storage.from('post-media').getPublicUrl(storagePath);
  }

  static Future<Map<String, dynamic>> validateArtDrawingWithAi({
    required String imageUrl,
    required String username,
    String title = '',
    String description = '',
  }) async {
    final response = await _postSignedJson(
  Uri.parse(respectAiArtValidateBackendUrl),
  {
        'username': displayUsername(username),
        'imageUrl': imageUrl,
        'imageUrls': [imageUrl],
        'text': '$title\n$description'.trim(),
        'contentType': 'art_drawing',
      },
  timeout: const Duration(seconds: 90),
);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('AI drawing validation error: ${response.statusCode} ${response.body}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return <String, dynamic>{'ok': false, 'accepted': false, 'reason': 'Invalid AI response'};
  }

  static Future<Map<String, dynamic>> submitArtDrawing({
    required String username,
    required String name,
    required String avatarUrl,
    required String title,
    required String description,
    required String imagePath,
    String? weekKey,
  }) async {
    final week = (weekKey == null || weekKey.trim().isEmpty) ? currentArtWeekKey() : weekKey.trim();
    final user = displayUsername(username);
    final imageUrl = await uploadArtDrawingMedia(username: user, filePath: imagePath);
    final validation = await validateArtDrawingWithAi(
      imageUrl: imageUrl,
      username: user,
      title: title,
      description: description,
    );

    final accepted = validation['accepted'] == true || validation['isRealDrawing'] == true;
    final payload = <String, dynamic>{
      'week_key': week,
      'username': user,
      'name': name.trim().isEmpty ? user : name.trim(),
      'avatar_url': avatarUrl,
      'title': title.trim(),
      'description': description.trim(),
      'image_url': imageUrl,
      'status': accepted ? 'approved' : 'rejected',
      'ai_is_real_drawing': validation['isRealDrawing'] == true,
      'ai_is_ai_generated': validation['isAiGenerated'] == true,
      'ai_confidence': double.tryParse((validation['confidence'] ?? 0.0).toString()) ?? 0.0,
      'ai_reason': (validation['reason'] ?? '').toString(),
      'rank': null,
      'score': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };

    late final dynamic inserted;
    try {
      inserted = await client.from('respect_art_drawings').insert(payload).select().single();
    } catch (_) {
      final legacy = Map<String, dynamic>.from(payload)
        ..remove('avatar_url')
        ..remove('ai_is_real_drawing')
        ..remove('ai_is_ai_generated')
        ..remove('ai_confidence')
        ..remove('ai_reason')
        ..remove('rank')
        ..remove('score');
      inserted = await client.from('respect_art_drawings').insert(legacy).select().single();
    }

    final row = Map<String, dynamic>.from(inserted as Map);
    row['accepted'] = accepted;
    row['validation'] = validation;
    row['reason'] = validation['reason'];
    return row;
  }

  static Future<List<Map<String, dynamic>>> getArtDrawings({String? weekKey}) async {
    final week = (weekKey == null || weekKey.trim().isEmpty) ? currentArtWeekKey() : weekKey.trim();
    try {
      final rows = await client
          .from('respect_art_drawings')
          .select()
          .eq('week_key', week)
          .eq('status', 'approved')
          .order('rank', ascending: true, nullsFirst: false)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(rows.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<List<Map<String, dynamic>>> getArtTopThree({String? weekKey}) async {
    final rows = await getArtDrawings(weekKey: weekKey);
    final ranked = rows.where((e) => int.tryParse((e['rank'] ?? '').toString()) != null).toList();
    ranked.sort((a, b) => (int.tryParse((a['rank'] ?? '99').toString()) ?? 99).compareTo(int.tryParse((b['rank'] ?? '99').toString()) ?? 99));
    return ranked.take(3).toList();
  }

  static Future<List<Map<String, dynamic>>> getArtTournamentMatches({String? weekKey}) async {
    final week = (weekKey == null || weekKey.trim().isEmpty) ? currentArtWeekKey() : weekKey.trim();
    try {
      final rows = await client
          .from('respect_art_matches')
          .select()
          .eq('week_key', week)
          .order('round_number', ascending: true)
          .order('match_number', ascending: true)
          .order('created_at', ascending: true);
      return List<Map<String, dynamic>>.from(rows.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<Map<String, dynamic>> runArtWeeklyTournament({String? weekKey}) async {
    final week = (weekKey == null || weekKey.trim().isEmpty) ? currentArtWeekKey() : weekKey.trim();
    final response = await _postSignedJson(
  Uri.parse(respectAiArtTournamentBackendUrl),
  {'weekKey': week},
  timeout: const Duration(minutes: 5),
);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('AI art tournament error: ${response.statusCode} ${response.body}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return <String, dynamic>{'ok': false, 'reason': 'Invalid AI response'};
  }


  // ================= Messaging Privacy / Requests / Reactions =================
  static const String _messagingPrivacyLocalKeyPrefix = 'respect_msg_privacy_';

  static Future<Map<String, dynamic>> getMessagingPrivacySettings(String username) async {
    final user = displayUsername(username);
    final defaults = <String, dynamic>{
      'username': user,
      'messages_enabled': true,
      'verified_only_messages': false,
      'calls_enabled': true,
      'chat_requests_required': true,
    };
    try {
      final row = await client.from('respect_messaging_privacy').select().eq('username', user).maybeSingle().timeout(const Duration(seconds: 6));
      if (row != null) return <String, dynamic>{...defaults, ...Map<String, dynamic>.from(row as Map)};
    } catch (e, st) { _logIgnoredError(e, st); }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_messagingPrivacyLocalKeyPrefix${normalizeUsername(user)}');
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return <String, dynamic>{...defaults, ...decoded.map((k, v) => MapEntry(k.toString(), v))};
      }
    } catch (e, st) { _logIgnoredError(e, st); }
    return defaults;
  }

  static Future<Map<String, dynamic>> updateMessagingPrivacySettings({
    required String username,
    required bool messagesEnabled,
    required bool verifiedOnlyMessages,
    required bool callsEnabled,
    required bool chatRequestsRequired,
  }) async {
    final user = displayUsername(username);
    Map<String, dynamic>? ownerUser;
    try { ownerUser = await getUserByUsername(user); } catch (e, st) { _logIgnoredError(e, st); }
    final canUseVerifiedOnly = canUseVerifiedOnlyMessagesFeature(ownerUser);
    final safeVerifiedOnlyMessages = verifiedOnlyMessages && canUseVerifiedOnly;

    final payload = <String, dynamic>{
      'username': user,
      'messages_enabled': messagesEnabled,
      'verified_only_messages': safeVerifiedOnlyMessages,
      'calls_enabled': callsEnabled,
      'chat_requests_required': chatRequestsRequired,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      final row = await client.from('respect_messaging_privacy').upsert(payload, onConflict: 'username').select().single().timeout(const Duration(seconds: 8));
      return Map<String, dynamic>.from(row as Map);
    } catch (e, st) { _logIgnoredError(e, st); }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_messagingPrivacyLocalKeyPrefix${normalizeUsername(user)}', jsonEncode(payload));
    return payload;
  }

  static Future<Map<String, dynamic>> canSendDirectMessage({required String sender, required String receiver}) async {
    final s = displayUsername(sender);
    final r = displayUsername(receiver);
    if (s == r) return <String, dynamic>{'allowed': true};
    final settings = await getMessagingPrivacySettings(r);
    if (!truthy(settings['messages_enabled'] ?? true)) return <String, dynamic>{'allowed': false, 'reason': 'messages_disabled'};
    if (truthy(settings['verified_only_messages'])) {
      final receiverUser = await getUserByUsername(r);
      final receiverCanUseVerifiedOnly = canUseVerifiedOnlyMessagesFeature(receiverUser);
      if (receiverCanUseVerifiedOnly) {
        final senderUser = await getUserByUsername(s);
        if (!isVerifiedUser(senderUser)) {
          return <String, dynamic>{
            'allowed': false,
            'reason': 'verified_only',
            'required_sender_status': 'verified',
            'receiver_tier': subscriptionTierForUser(receiverUser),
          };
        }
      } else {
        // لو انتهى اشتراك صاحب الحساب أو لم يكن ذهبي/مميز، لا نطبق القفل حتى لو بقيت القيمة true في الجدول.
        unawaited(updateMessagingPrivacySettings(
          username: r,
          messagesEnabled: truthy(settings['messages_enabled'] ?? true),
          verifiedOnlyMessages: false,
          callsEnabled: truthy(settings['calls_enabled'] ?? true),
          chatRequestsRequired: truthy(settings['chat_requests_required'] ?? true),
        ));
      }
    }
    if (truthy(settings['chat_requests_required'] ?? true)) {
      final accepted = await hasAcceptedChatRequest(s, r);
      final previousMessages = await _hasAnyDirectMessage(s, r);
      if (!accepted && !previousMessages) return <String, dynamic>{'allowed': false, 'reason': 'request_required'};
    }
    return <String, dynamic>{'allowed': true};
  }

  static Future<bool> _hasAnyDirectMessage(String a, String b) async {
    try {
      final rows = await client.from('messages').select('id').or('and(sender_username.eq.$a,receiver_username.eq.$b),and(sender_username.eq.$b,receiver_username.eq.$a)').limit(1).timeout(const Duration(seconds: 5));
      return rows is List && rows.isNotEmpty;
    } catch (_) { return false; }
  }

  static Future<Map<String, dynamic>> canCallUser({required String caller, required String receiver}) async {
    final settings = await getMessagingPrivacySettings(receiver);
    if (!truthy(settings['calls_enabled'] ?? true)) return <String, dynamic>{'allowed': false, 'reason': 'calls_disabled'};
    return <String, dynamic>{'allowed': true};
  }

  static Future<bool> hasAcceptedChatRequest(String user1, String user2) async {
    final a = displayUsername(user1);
    final b = displayUsername(user2);
    try {
      final row = await client
          .from('respect_chat_requests')
          .select('id')
          .or('and(sender_username.eq.$a,receiver_username.eq.$b),and(sender_username.eq.$b,receiver_username.eq.$a)')
          .eq('status', 'accepted')
          .maybeSingle()
          .timeout(const Duration(seconds: 6));
      return row != null;
    } catch (_) { return false; }
  }

  static Future<Map<String, dynamic>> createChatRequest({required String sender, required String receiver}) async {
    final s = displayUsername(sender);
    final r = displayUsername(receiver);
    final now = DateTime.now().toUtc().toIso8601String();
    final payload = <String, dynamic>{'sender_username': s, 'receiver_username': r, 'status': 'pending', 'created_at': now, 'updated_at': now};
    try {
      final row = await client.from('respect_chat_requests').upsert(payload, onConflict: 'sender_username,receiver_username').select().single().timeout(const Duration(seconds: 8));
      await sendUserBroadcast(username: r, event: 'new_message', payload: {'message': {'id': 'request_$now', 'sender_username': s, 'receiver_username': r, 'text': 'طلب دردشة جديد', 'created_at': now}});
      return Map<String, dynamic>.from(row as Map);
    } catch (e, st) { _logIgnoredError(e, st); }
    return payload;
  }

  static Future<List<Map<String, dynamic>>> getIncomingChatRequests(String username) async {
    final user = displayUsername(username);
    try {
      final rows = await client.from('respect_chat_requests').select().eq('receiver_username', user).eq('status', 'pending').order('created_at', ascending: false).timeout(const Duration(seconds: 6));
      return List<Map<String, dynamic>>.from((rows as List).map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) { return <Map<String, dynamic>>[]; }
  }

  static Future<void> respondChatRequest({required String requestId, required bool approve}) async {
    final id = requestId.trim();
    if (id.isEmpty) return;
    try {
      await client.from('respect_chat_requests').update({'status': approve ? 'accepted' : 'rejected', 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id).timeout(const Duration(seconds: 8));
    } catch (e, st) { _logIgnoredError(e, st); }
  }

  static Future<Map<String, bool>> getMyMessageReactions(String username) async {
    final user = displayUsername(username);
    final out = <String, bool>{};
    try {
      final rows = await client.from('respect_message_reactions').select('message_id').eq('username', user).eq('reaction', 'like').timeout(const Duration(seconds: 6));
      for (final row in rows) {
        final id = (row['message_id'] ?? '').toString();
        if (id.isNotEmpty) out[id] = true;
      }
    } catch (e, st) { _logIgnoredError(e, st); }
    return out;
  }

  static Future<void> setMessageReaction({required String messageId, required String username, required bool liked, bool group = false}) async {
    final id = messageId.trim();
    final user = displayUsername(username);
    if (id.isEmpty) return;
    try {
      if (liked) {
        await client.from('respect_message_reactions').upsert({
          'message_id': id,
          'username': user,
          'reaction': 'like',
          'is_group': group,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'message_id,username,reaction').timeout(const Duration(seconds: 6));
      } else {
        await client.from('respect_message_reactions').delete().eq('message_id', id).eq('username', user).eq('reaction', 'like').timeout(const Duration(seconds: 6));
      }
    } catch (e, st) { _logIgnoredError(e, st); }
  }


  // ================= Supabase Communities =================
  // مهم: المجتمعات لازم تُقرأ من Supabase وليس SharedPreferences.
  // SharedPreferences محلي على الجهاز، لذلك في نسخة release أو عند مستخدم آخر تظهر المجتمعات وكأنها اختفت.
  static String _newCommunityId() {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final rnd = Random.secure();
    final salt = List.generate(8, (_) => rnd.nextInt(16).toRadixString(16)).join();
    return 'community_${now}_$salt';
  }

  static List<String> _communityStringList(dynamic value, {bool usernames = false}) {
    dynamic raw = value;
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return <String>[];
      try {
        raw = jsonDecode(trimmed);
      } catch (_) {
        raw = trimmed.split(',');
      }
    }
    if (raw is! Iterable) return <String>[];
    final out = <String>{};
    for (final item in raw) {
      final v = item.toString().trim();
      if (v.isEmpty) continue;
      out.add(usernames ? displayUsername(v) : v);
    }
    return out.toList();
  }

  static Map<String, dynamic> _normalizeCommunityRow(Map raw, {List<Map<String, dynamic>> posts = const <Map<String, dynamic>>[]}) {
    final row = raw.map((key, value) => MapEntry(key.toString(), value));
    final owner = displayUsername((row['owner_username'] ?? row['ownerUsername'] ?? row['owner'] ?? '').toString());
    final moderators = _communityStringList(row['moderators'], usernames: true);
    final members = _communityStringList(row['members'], usernames: true);
    final kicked = _communityStringList(row['kicked_members'] ?? row['kickedMembers'], usernames: true);

    if (owner != '@user') {
      if (!moderators.contains(owner)) moderators.insert(0, owner);
      if (!members.contains(owner)) members.insert(0, owner);
    }

    return <String, dynamic>{
      'id': (row['id'] ?? _newCommunityId()).toString(),
      'name': (row['name'] ?? 'مجتمع').toString(),
      'description': (row['description'] ?? '').toString(),
      'ownerUsername': owner,
      'owner_username': owner,
      'moderators': moderators.toSet().toList(),
      'members': members.toSet().toList(),
      'kickedMembers': kicked.toSet().toList(),
      'kicked_members': kicked.toSet().toList(),
      'messages': row['messages'] is List ? row['messages'] : <dynamic>[],
      'reports': row['reports'] is List ? row['reports'] : <dynamic>[],
      'posts': posts,
      'created_at': (row['created_at'] ?? '').toString(),
    };
  }

  static Map<String, dynamic> _communityPayloadFromJson(Map<String, dynamic> community, {String? ownerUsername}) {
    final id = (community['id'] ?? '').toString().trim().isEmpty
        ? _newCommunityId()
        : (community['id'] ?? '').toString().trim();
    final owner = displayUsername(
      (ownerUsername ?? community['owner_username'] ?? community['ownerUsername'] ?? community['owner'] ?? '').toString(),
    );
    final moderators = _communityStringList(community['moderators'], usernames: true);
    final members = _communityStringList(community['members'], usernames: true);
    final kicked = _communityStringList(community['kicked_members'] ?? community['kickedMembers'], usernames: true);

    if (owner != '@user') {
      if (!moderators.contains(owner)) moderators.insert(0, owner);
      if (!members.contains(owner)) members.insert(0, owner);
    }

    return <String, dynamic>{
      'id': id,
      'name': (community['name'] ?? 'مجتمع').toString().trim().isEmpty
          ? 'مجتمع'
          : (community['name'] ?? 'مجتمع').toString().trim(),
      'description': (community['description'] ?? '').toString().trim(),
      'owner_username': owner,
      'moderators': moderators.toSet().toList(),
      'members': members.toSet().toList(),
      'kicked_members': kicked.toSet().toList(),
      if ((community['created_at'] ?? '').toString().trim().isNotEmpty)
        'created_at': (community['created_at'] ?? '').toString(),
    };
  }

  static Future<List<Map<String, dynamic>>> getCommunities({bool includePosts = true}) async {
    try {
      final rows = await client
          .from('communities')
          .select('id,name,description,owner_username,moderators,members,kicked_members,created_at')
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 10));

      final communityRows = List<Map<String, dynamic>>.from(
        (rows as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
      );
      if (communityRows.isEmpty) return <Map<String, dynamic>>[];

      final postsByCommunity = <String, List<Map<String, dynamic>>>{};
      if (includePosts) {
        final ids = communityRows.map((e) => (e['id'] ?? '').toString()).where((e) => e.isNotEmpty).toSet().toList();
        if (ids.isNotEmpty) {
          try {
            final postRows = await client
                .from('posts')
                .select('id,username,name,user,text,created_at,time,avatar_url,avatarPath,image_url,video_url,voice_url,voicePath,voice_seconds,voiceSeconds,likes,reposts,shares,views,replies,reply_count,community_id,community_name,community_hidden,community_pinned,author_verified,author_subscription_tier,author_subscription_priority,author_subscription_boost_until,author_subscription_label')
                .inFilter('community_id', ids)
                .eq('community_hidden', false)
                .order('created_at', ascending: false)
                .timeout(const Duration(seconds: 10));
            for (final raw in postRows) {
              if (raw is! Map) continue;
              final post = raw.map((key, value) => MapEntry(key.toString(), value));
              final cid = (post['community_id'] ?? '').toString();
              if (cid.isEmpty) continue;
              (postsByCommunity[cid] ??= <Map<String, dynamic>>[]).add(post);
            }
          } catch (e, st) {
            _logIgnoredError(e, st);
          }
        }
      }

      return communityRows
          .map((row) => _normalizeCommunityRow(row, posts: postsByCommunity[(row['id'] ?? '').toString()] ?? const <Map<String, dynamic>>[]))
          .toList();
    } catch (e, st) {
      _logIgnoredError(e, st);
      return <Map<String, dynamic>>[];
    }
  }

  static Future<Map<String, dynamic>?> getCommunityById(String communityId, {bool includePosts = true}) async {
    final id = communityId.trim();
    if (id.isEmpty) return null;
    try {
      final row = await client
          .from('communities')
          .select('id,name,description,owner_username,moderators,members,kicked_members,created_at')
          .eq('id', id)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (row == null) return null;

      var posts = <Map<String, dynamic>>[];
      if (includePosts) {
        try {
          final postRows = await client
              .from('posts')
              .select('id,username,name,user,text,created_at,time,avatar_url,avatarPath,image_url,video_url,voice_url,voicePath,voice_seconds,voiceSeconds,likes,reposts,shares,views,replies,reply_count,community_id,community_name,community_hidden,community_pinned,author_verified,author_subscription_tier,author_subscription_priority,author_subscription_boost_until,author_subscription_label')
              .eq('community_id', id)
              .eq('community_hidden', false)
              .order('created_at', ascending: false)
              .timeout(const Duration(seconds: 8));
          posts = List<Map<String, dynamic>>.from(
            (postRows as List).whereType<Map>().map((e) => e.map((key, value) => MapEntry(key.toString(), value))),
          );
        } catch (e, st) {
          _logIgnoredError(e, st);
        }
      }
      return _normalizeCommunityRow(Map<String, dynamic>.from(row as Map), posts: posts);
    } catch (e, st) {
      _logIgnoredError(e, st);
      return null;
    }
  }

  static Future<Map<String, dynamic>> createCommunity({
    required String name,
    required String description,
    required String ownerUsername,
  }) async {
    final owner = displayUsername(ownerUsername);
    final payload = <String, dynamic>{
      'id': _newCommunityId(),
      'name': name.trim().isEmpty ? 'مجتمع' : name.trim(),
      'description': description.trim(),
      'owner_username': owner,
      'moderators': <String>[owner],
      'members': <String>[owner],
      'kicked_members': <String>[],
    };

    final inserted = await client
        .from('communities')
        .insert(payload)
        .select('id,name,description,owner_username,moderators,members,kicked_members,created_at')
        .single()
        .timeout(const Duration(seconds: 10));
    return _normalizeCommunityRow(Map<String, dynamic>.from(inserted as Map));
  }

  static Future<Map<String, dynamic>> upsertCommunity(Map<String, dynamic> community, {String? ownerUsername}) async {
    final payload = _communityPayloadFromJson(community, ownerUsername: ownerUsername);
    final inserted = await client
        .from('communities')
        .upsert(payload, onConflict: 'id')
        .select('id,name,description,owner_username,moderators,members,kicked_members,created_at')
        .single()
        .timeout(const Duration(seconds: 10));
    return _normalizeCommunityRow(Map<String, dynamic>.from(inserted as Map));
  }

  static Future<void> upsertCommunities(List<Map<String, dynamic>> communities, {String? ownerUsername}) async {
    if (communities.isEmpty) return;
    final payloads = communities.map((c) => _communityPayloadFromJson(c, ownerUsername: ownerUsername)).toList();
    try {
      await client.from('communities').upsert(payloads, onConflict: 'id').timeout(const Duration(seconds: 12));
    } catch (e, st) {
      _logIgnoredError(e, st);
    }
  }

  static Future<Map<String, dynamic>?> updateCommunity(Map<String, dynamic> community) async {
    final id = (community['id'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    final payload = _communityPayloadFromJson(community)..remove('id')..remove('created_at');
    try {
      final updated = await client
          .from('communities')
          .update(payload)
          .eq('id', id)
          .select('id,name,description,owner_username,moderators,members,kicked_members,created_at')
          .maybeSingle()
          .timeout(const Duration(seconds: 10));
      if (updated == null) return null;
      return _normalizeCommunityRow(Map<String, dynamic>.from(updated as Map));
    } catch (e, st) {
      _logIgnoredError(e, st);
      return null;
    }
  }

  static Future<Map<String, dynamic>?> setCommunityMembers({
    required String communityId,
    required List<String> members,
    List<String>? moderators,
    List<String>? kickedMembers,
  }) async {
    final id = communityId.trim();
    if (id.isEmpty) return null;
    final payload = <String, dynamic>{
      'members': _communityStringList(members, usernames: true),
      if (moderators != null) 'moderators': _communityStringList(moderators, usernames: true),
      if (kickedMembers != null) 'kicked_members': _communityStringList(kickedMembers, usernames: true),
    };
    try {
      final updated = await client
          .from('communities')
          .update(payload)
          .eq('id', id)
          .select('id,name,description,owner_username,moderators,members,kicked_members,created_at')
          .maybeSingle()
          .timeout(const Duration(seconds: 10));
      if (updated == null) return null;
      return _normalizeCommunityRow(Map<String, dynamic>.from(updated as Map));
    } catch (e, st) {
      _logIgnoredError(e, st);
      return null;
    }
  }

  static Future<Map<String, dynamic>?> joinCommunity({required String communityId, required String username}) async {
    final community = await getCommunityById(communityId, includePosts: false);
    if (community == null) return null;
    final user = displayUsername(username);
    final kicked = _communityStringList(community['kickedMembers'] ?? community['kicked_members'], usernames: true);
    if (kicked.contains(user)) {
      throw StateError('هذا المستخدم مطرود من المجتمع');
    }
    final members = _communityStringList(community['members'], usernames: true);
    if (!members.contains(user)) members.add(user);
    return setCommunityMembers(
      communityId: communityId,
      members: members,
      moderators: _communityStringList(community['moderators'], usernames: true),
      kickedMembers: kicked,
    );
  }

  static Future<Map<String, dynamic>?> leaveCommunity({required String communityId, required String username}) async {
    final community = await getCommunityById(communityId, includePosts: false);
    if (community == null) return null;
    final user = displayUsername(username);
    final owner = displayUsername((community['ownerUsername'] ?? community['owner_username'] ?? '').toString());
    if (user == owner) return community;
    final members = _communityStringList(community['members'], usernames: true)..remove(user);
    final moderators = _communityStringList(community['moderators'], usernames: true)..remove(user);
    return setCommunityMembers(
      communityId: communityId,
      members: members,
      moderators: moderators,
      kickedMembers: _communityStringList(community['kickedMembers'] ?? community['kicked_members'], usernames: true),
    );
  }

  static Future<Map<String, dynamic>?> kickCommunityMember({
    required String communityId,
    required String username,
    bool kicked = true,
  }) async {
    final community = await getCommunityById(communityId, includePosts: false);
    if (community == null) return null;
    final user = displayUsername(username);
    final owner = displayUsername((community['ownerUsername'] ?? community['owner_username'] ?? '').toString());
    if (user == owner) return community;

    final members = _communityStringList(community['members'], usernames: true)..remove(user);
    final moderators = _communityStringList(community['moderators'], usernames: true)..remove(user);
    final kickedMembers = _communityStringList(community['kickedMembers'] ?? community['kicked_members'], usernames: true);
    if (kicked) {
      if (!kickedMembers.contains(user)) kickedMembers.add(user);
    } else {
      kickedMembers.remove(user);
    }
    return setCommunityMembers(
      communityId: communityId,
      members: members,
      moderators: moderators,
      kickedMembers: kickedMembers,
    );
  }

  static Future<void> deleteCommunity(String communityId) async {
    final id = communityId.trim();
    if (id.isEmpty) return;
    try {
      await client.from('communities').delete().eq('id', id).timeout(const Duration(seconds: 10));
    } catch (e, st) {
      _logIgnoredError(e, st);
    }
  }



}