import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void _secureSafeLog(Object error, [StackTrace? stackTrace]) {
  if (kDebugMode) {
    // لا نطبع مفاتيح أو نصوص حساسة في وضع الإنتاج.
  }
}

class SecureCryptoService {
  SecureCryptoService._();

  static final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  static final X25519 _x25519 = X25519();
  static final AesGcm _aesGcm = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static const String encryptionVersion = 'respect_e2ee_x25519_aesgcm_v1';
  static const String encryptedTextPlaceholder = '🔒 رسالة مشفرة';
  static const String encryptedCallPlaceholder = '🔒 سجل مكالمة مشفر';
  static const String encryptedMediaPlaceholder = '🔒 ملف مشفر';

  static final Map<String, SimplePublicKey?> _publicKeyCache = <String, SimplePublicKey?>{};
  static final Map<String, String> _decryptedMediaCache = <String, String>{};

  static String displayUsername(String value) {
    final clean = value.trim().toLowerCase().replaceAll('@', '');
    return clean.isEmpty ? '@user' : '@$clean';
  }

  static String normalizeUsername(String value) => displayUsername(value).replaceAll('@', '');

  // ================= Database field protection =================
  // يستخدم لتخزين حقول حساسة في public.users بدون نص واضح.
  // مرر السر وقت البناء:
  // flutter build apk --dart-define=RESPECT_DB_FIELD_SECRET=your_long_random_secret
  static const String databaseFieldEncryptionVersion = 'respect_db_field_aesgcm_v1';
  static const String _defaultSecretWarning = 'respect_dev_db_field_secret_change_me';
  static const String _dbFieldSecret =
      String.fromEnvironment('RESPECT_DB_FIELD_SECRET', defaultValue: _defaultSecretWarning);

  static bool get isDatabaseFieldSecretConfigured {
    final secret = _dbFieldSecret.trim();
    return secret.isNotEmpty && secret != _defaultSecretWarning;
  }

  // كان التطبيق ينهار إذا تم تشغيله بدون:
  // --dart-define=RESPECT_DB_FIELD_SECRET=...
  //
  // الحل هنا:
  // - لا نرمي StateError أثناء فتح الصفحات مثل رسامين ريسبكت.
  // - إذا السر غير موجود نستخدم قيمة تطوير ثابتة كاحتياط حتى لا يتعطل التطبيق.
  // - للإنتاج الأفضل تمرير RESPECT_DB_FIELD_SECRET في أوامر build للحفاظ على حماية الحقول.
  static String get _effectiveDbFieldSecret {
    final secret = _dbFieldSecret.trim();
    if (secret.isEmpty || secret == _defaultSecretWarning) {
      return _defaultSecretWarning;
    }
    return secret;
  }

  static void _ensureDbFieldSecretConfigured() {
    if (!isDatabaseFieldSecretConfigured) {
      _secureSafeLog(
        StateError('RESPECT_DB_FIELD_SECRET is missing. Using development fallback to keep app running.'),
      );
    }
  }

  static Future<SecretKey> _databaseFieldKey() {
    _ensureDbFieldSecretConfigured();
    return _hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(_effectiveDbFieldSecret)),
      nonce: utf8.encode('respect-app|database-fields|$databaseFieldEncryptionVersion'),
    );
  }

  static Future<String> databaseLookupHash(String label, String value) async {
    final clean = value.trim().toLowerCase();
    if (clean.isEmpty) return '';
    _ensureDbFieldSecretConfigured();
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode('${label.trim().toLowerCase()}|$clean'),
      secretKey: SecretKey(utf8.encode(_effectiveDbFieldSecret)),
    );
    return base64UrlEncode(mac.bytes).replaceAll('=', '');
  }

  static Future<String> encryptDatabaseField(String label, String value) async {
    final cleanValue = value.trim();
    if (cleanValue.isEmpty) return '';
    final key = await _databaseFieldKey();
    final nonce = _randomNonce();
    final aad = utf8.encode('${label.trim().toLowerCase()}|$databaseFieldEncryptionVersion');
    final box = await _aesGcm.encrypt(
      utf8.encode(cleanValue),
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    final payload = <String, dynamic>{
      'v': databaseFieldEncryptionVersion,
      'n': base64Encode(box.nonce),
      'c': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    };
    return 'enc:${base64UrlEncode(utf8.encode(jsonEncode(payload))).replaceAll('=', '')}';
  }

  static Future<String> decryptDatabaseField(String label, String value) async {
    final raw = value.trim();
    if (raw.isEmpty || !raw.startsWith('enc:')) return raw;
    try {
      var b64 = raw.substring(4);
      while (b64.length % 4 != 0) {
        b64 += '=';
      }
      final decoded = jsonDecode(utf8.decode(base64Url.decode(b64)));
      if (decoded is! Map) return raw;
      final map = decoded.map((k, v) => MapEntry(k.toString(), v));
      final key = await _databaseFieldKey();
      final aad = utf8.encode('${label.trim().toLowerCase()}|$databaseFieldEncryptionVersion');
      final clear = await _aesGcm.decrypt(
        SecretBox(
          base64Decode((map['c'] ?? '').toString()),
          nonce: base64Decode((map['n'] ?? '').toString()),
          mac: Mac(base64Decode((map['m'] ?? '').toString())),
        ),
        secretKey: key,
        aad: aad,
      );
      return utf8.decode(clear);
    } catch (e, st) {
      _secureSafeLog(e, st);
      return raw;
    }
  }

  static Future<String> passwordDatabaseHash(String password) async {
    final pass = password.trim();
    if (pass.isEmpty) return '';
    final saltBytes = _randomNonce(16);
    final keySeed = _effectiveDbFieldSecret;
    final mac = await Hmac.sha256().calculateMac(
      <int>[...saltBytes, ...utf8.encode(pass)],
      secretKey: SecretKey(utf8.encode('respect-app-password-field|$keySeed')),
    );
    return 'hash:v1:${base64UrlEncode(saltBytes).replaceAll('=', '')}:${base64UrlEncode(mac.bytes).replaceAll('=', '')}';
  }


  static String _privateKeyKey(String username) => 'respect_e2ee_${normalizeUsername(username)}_private_v1';
  static String _publicKeyKey(String username) => 'respect_e2ee_${normalizeUsername(username)}_public_v1';

  static Future<SimpleKeyPair> _loadOrCreateLocalKeyPair(String username) async {
    final user = displayUsername(username);
    final privateKeyName = _privateKeyKey(user);
    final publicKeyName = _publicKeyKey(user);

    final privateRaw = await _storage.read(key: privateKeyName);
    final publicRaw = await _storage.read(key: publicKeyName);

    if (privateRaw != null && privateRaw.trim().isNotEmpty && publicRaw != null && publicRaw.trim().isNotEmpty) {
      final privateBytes = base64Decode(privateRaw);
      final publicBytes = base64Decode(publicRaw);
      return SimpleKeyPairData(
        privateBytes,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
    }

    final pair = await _x25519.newKeyPair();
    final privateBytes = await pair.extractPrivateKeyBytes();
    final publicKey = await pair.extractPublicKey();

    await _storage.write(key: privateKeyName, value: base64Encode(privateBytes));
    await _storage.write(key: publicKeyName, value: base64Encode(publicKey.bytes));
    return pair;
  }

  static Future<String> ensureCurrentUserPublicKey(String username) async {
    final user = displayUsername(username);
    if (user == '@user') return '';

    final pair = await _loadOrCreateLocalKeyPair(user);
    final publicKey = await pair.extractPublicKey();
    final publicKeyB64 = base64Encode(publicKey.bytes);

    try {
      final clean = normalizeUsername(user);
      await Supabase.instance.client
          .from('users')
          .update({
        'e2ee_public_key': publicKeyB64,
        'e2ee_key_type': 'x25519',
        'e2ee_key_version': 1,
        'e2ee_updated_at': DateTime.now().toUtc().toIso8601String(),
      })
          .or('username.eq.$user,username.eq.$clean')
          .timeout(const Duration(seconds: 8));
    } catch (e, st) {
      _secureSafeLog(e, st);
    }

    _publicKeyCache[user] = publicKey;
    return publicKeyB64;
  }

  
  static Future<Map<String, dynamic>> localPublicKeyPayloadForUser(String username) async {
    final user = displayUsername(username);
    if (user == '@user') return <String, dynamic>{};

    final pair = await _loadOrCreateLocalKeyPair(user);
    final publicKey = await pair.extractPublicKey();
    final publicKeyB64 = base64Encode(publicKey.bytes);
    _publicKeyCache[user] = publicKey;

    return <String, dynamic>{
      'e2ee_public_key': publicKeyB64,
      'e2ee_key_type': 'x25519',
      'e2ee_key_version': 1,
      'e2ee_updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  static Future<bool> hasPublicKeyForUsername(String username) async {
    final key = await publicKeyForUsername(username);
    return key != null;
  }

  static Future<void> clearPublicKeyCache([String? username]) async {
    if (username == null || username.trim().isEmpty) {
      _publicKeyCache.clear();
      return;
    }
    _publicKeyCache.remove(displayUsername(username));
  }

static Future<SimplePublicKey?> publicKeyForUsername(String username) async {
    final user = displayUsername(username);
    if (user == '@user') return null;
    if (_publicKeyCache.containsKey(user)) return _publicKeyCache[user];

    try {
      final clean = normalizeUsername(user);
      final row = await Supabase.instance.client
          .from('users')
          .select('e2ee_public_key,username')
          .or('username.eq.$user,username.eq.$clean')
          .limit(1)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      final raw = row == null ? '' : (row['e2ee_public_key'] ?? '').toString().trim();
      if (raw.isEmpty) {
        _publicKeyCache[user] = null;
        return null;
      }
      final key = SimplePublicKey(base64Decode(raw), type: KeyPairType.x25519);
      _publicKeyCache[user] = key;
      return key;
    } catch (e, st) {
      _secureSafeLog(e, st);
      return null;
    }
  }

  static Future<SecretKey> _conversationKey({
    required String myUsername,
    required String peerUsername,
    required String context,
  }) async {
    final me = displayUsername(myUsername);
    final peer = displayUsername(peerUsername);
    final pair = await _loadOrCreateLocalKeyPair(me);
    final peerPublic = await publicKeyForUsername(peer);
    if (peerPublic == null) throw StateError('peer_public_key_missing');

    final shared = await _x25519.sharedSecretKey(keyPair: pair, remotePublicKey: peerPublic);
    final sharedBytes = await shared.extractBytes();
    final participants = <String>[me, peer]..sort();
    final salt = utf8.encode('respect-app|$encryptionVersion|${participants.join('|')}|$context');
    return _hkdf.deriveKey(secretKey: SecretKey(sharedBytes), nonce: salt);
  }

  static List<int> _randomNonce([int length = 12]) {
    final r = Random.secure();
    return List<int>.generate(length, (_) => r.nextInt(256));
  }

  static Future<Map<String, String>> _encryptString({
    required String myUsername,
    required String peerUsername,
    required String plainText,
    required String context,
  }) async {
    final key = await _conversationKey(myUsername: myUsername, peerUsername: peerUsername, context: context);
    final nonce = _randomNonce();
    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plainText),
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(context),
    );
    return <String, String>{
      'ciphertext': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(secretBox.nonce),
      'mac': base64Encode(secretBox.mac.bytes),
    };
  }

  static Future<String> _decryptString({
    required String myUsername,
    required String peerUsername,
    required String ciphertextB64,
    required String nonceB64,
    required String macB64,
    required String context,
  }) async {
    final key = await _conversationKey(myUsername: myUsername, peerUsername: peerUsername, context: context);
    final clear = await _aesGcm.decrypt(
      SecretBox(
        base64Decode(ciphertextB64),
        nonce: base64Decode(nonceB64),
        mac: Mac(base64Decode(macB64)),
      ),
      secretKey: key,
      aad: utf8.encode(context),
    );
    return utf8.decode(clear);
  }

  static Future<Map<String, dynamic>> encryptedDirectFields({
    required String sender,
    required String receiver,
    required String text,
    String? replyText,
  }) async {
    final senderUser = displayUsername(sender);
    final receiverUser = displayUsername(receiver);
    await ensureCurrentUserPublicKey(senderUser);

    final cleanText = text.trim();
    final out = <String, dynamic>{
      'encrypted': false,
      'encryption_version': 'none',
      'text': cleanText,
    };

    if (cleanText.isEmpty && (replyText == null || replyText.trim().isEmpty)) return out;

    try {
      final encryptedText = await _encryptString(
        myUsername: senderUser,
        peerUsername: receiverUser,
        plainText: cleanText,
        context: 'direct_message_text',
      );
      out
        ..['encrypted'] = true
        ..['encryption_version'] = encryptionVersion
        ..['text'] = encryptedTextPlaceholder
        ..['ciphertext'] = encryptedText['ciphertext']
        ..['nonce'] = encryptedText['nonce']
        ..['mac'] = encryptedText['mac'];

      final reply = replyText?.trim() ?? '';
      if (reply.isNotEmpty) {
        final encryptedReply = await _encryptString(
          myUsername: senderUser,
          peerUsername: receiverUser,
          plainText: reply,
          context: 'direct_message_reply',
        );
        out
          ..['reply_text'] = encryptedTextPlaceholder
          ..['reply_ciphertext'] = encryptedReply['ciphertext']
          ..['reply_nonce'] = encryptedReply['nonce']
          ..['reply_mac'] = encryptedReply['mac'];
      }
    } catch (e, st) {
      // أمان عالي: لا نرسل الرسالة كنص عادي إذا فشل التشفير.
      // غالبًا السبب أن الطرف الثاني لم يفتح النسخة الجديدة بعد ولم يرفع e2ee_public_key.
      _secureSafeLog(e, st);
      throw StateError('E2EE_NOT_READY: لا يمكن إرسال الرسالة قبل تجهيز مفتاح التشفير العام للطرف الآخر. للحسابات الجديدة سيتم تجهيز المفتاح تلقائيًا عند إنشاء الحساب، أما الحسابات القديمة فيجب فتح التطبيق مرة واحدة بعد التحديث.');
    }
    return out;
  }

  static Future<Map<String, dynamic>> decryptDirectRow(Map<String, dynamic> row, String currentUsername) async {
    final encrypted = row['encrypted'] == true || row['encrypted']?.toString() == 'true';
    if (!encrypted) return row;
    final version = (row['encryption_version'] ?? '').toString();
    if (version != encryptionVersion) return row;

    final me = displayUsername(currentUsername);
    final sender = displayUsername((row['sender_username'] ?? '').toString());
    final receiver = displayUsername((row['receiver_username'] ?? '').toString());
    final peer = sender == me ? receiver : sender;

    try {
      await ensureCurrentUserPublicKey(me);
      final cipher = (row['ciphertext'] ?? '').toString();
      final nonce = (row['nonce'] ?? '').toString();
      final mac = (row['mac'] ?? '').toString();
      if (cipher.isNotEmpty && nonce.isNotEmpty && mac.isNotEmpty) {
        row['text'] = await _decryptString(
          myUsername: me,
          peerUsername: peer,
          ciphertextB64: cipher,
          nonceB64: nonce,
          macB64: mac,
          context: 'direct_message_text',
        );
      }

      final replyCipher = (row['reply_ciphertext'] ?? '').toString();
      final replyNonce = (row['reply_nonce'] ?? '').toString();
      final replyMac = (row['reply_mac'] ?? '').toString();
      if (replyCipher.isNotEmpty && replyNonce.isNotEmpty && replyMac.isNotEmpty) {
        row['reply_text'] = await _decryptString(
          myUsername: me,
          peerUsername: peer,
          ciphertextB64: replyCipher,
          nonceB64: replyNonce,
          macB64: replyMac,
          context: 'direct_message_reply',
        );
      }

      await _decryptDirectMediaInRow(row, me, peer);
    } catch (e, st) {
      _secureSafeLog(e, st);
      row['text'] = encryptedTextPlaceholder;
      final reply = (row['reply_text'] ?? '').toString();
      if (reply.isNotEmpty) row['reply_text'] = encryptedTextPlaceholder;
    }
    return row;
  }

  static Future<List<Map<String, dynamic>>> decryptDirectRows(List<Map<String, dynamic>> rows, String currentUsername) async {
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      out.add(await decryptDirectRow(Map<String, dynamic>.from(row), currentUsername));
    }
    return out;
  }

  static bool isEncryptedMediaPayload(dynamic value) {
    if (value is Map) return value['e2ee_media'] == true || value['e2ee_media']?.toString() == 'true';
    if (value is String) {
      final raw = value.trim();
      if (!raw.startsWith('{')) return false;
      try {
        final decoded = jsonDecode(raw);
        return decoded is Map && (decoded['e2ee_media'] == true || decoded['e2ee_media']?.toString() == 'true');
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  static String _safeExtFromPath(String path, String mediaType) {
    final clean = path.split('?').first.toLowerCase();
    final ext = clean.contains('.') ? clean.split('.').last.replaceAll(RegExp(r'[^a-z0-9]'), '') : '';
    final allowed = <String>{'jpg', 'jpeg', 'png', 'webp', 'gif', 'mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi', 'm4a', 'aac', 'mp3', 'wav', 'ogg'};
    if (allowed.contains(ext)) return ext == 'jpeg' ? 'jpg' : ext;
    final t = mediaType.toLowerCase();
    if (t == 'voice' || t.contains('audio')) return 'm4a';
    if (t == 'video') return 'mp4';
    return 'jpg';
  }

  static Future<File> _writeTempFile(List<int> bytes, String prefix, String ext) async {
    final root = Directory('${Directory.systemTemp.path}/respect_secure_media');
    if (!await root.exists()) await root.create(recursive: true);
    final name = '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}.$ext';
    final file = File('${root.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<Map<String, dynamic>> encryptMediaFileForPeer({
    required String sender,
    required String receiver,
    required String filePath,
    required String mediaType,
  }) async {
    final senderUser = displayUsername(sender);
    final receiverUser = displayUsername(receiver);
    await ensureCurrentUserPublicKey(senderUser);

    final source = File(filePath.trim());
    if (!await source.exists()) throw StateError('MEDIA_FILE_NOT_FOUND');

    final plainBytes = await source.readAsBytes();
    final key = await _conversationKey(
      myUsername: senderUser,
      peerUsername: receiverUser,
      context: 'direct_media_file',
    );
    final nonce = _randomNonce();
    final ext = _safeExtFromPath(filePath, mediaType);
    final aad = utf8.encode('direct_media_file|${displayUsername(senderUser)}|${displayUsername(receiverUser)}|${mediaType.toLowerCase()}|$ext');
    final box = await _aesGcm.encrypt(
      plainBytes,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );

    final encryptedFile = await _writeTempFile(box.cipherText, 'upload', 'renc');
    return <String, dynamic>{
      'file': encryptedFile,
      'metadata': <String, dynamic>{
        'e2ee_media': true,
        'version': encryptionVersion,
        'media_type': mediaType.toLowerCase(),
        'ext': ext,
        'nonce': base64Encode(box.nonce),
        'mac': base64Encode(box.mac.bytes),
        'size': plainBytes.length,
      },
    };
  }

  static Future<List<int>> _downloadBytes(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('MEDIA_DOWNLOAD_FAILED_${response.statusCode}');
      }
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
      }
      return chunks;
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> decryptMediaPayloadForPeer({
    required String currentUsername,
    required String peerUsername,
    required Map<String, dynamic> payload,
  }) async {
    final me = displayUsername(currentUsername);
    final peer = displayUsername(peerUsername);
    final url = (payload['url'] ?? payload['media_url'] ?? '').toString().trim();
    final nonceB64 = (payload['nonce'] ?? '').toString().trim();
    final macB64 = (payload['mac'] ?? '').toString().trim();
    final mediaType = (payload['media_type'] ?? payload['type'] ?? 'file').toString().toLowerCase();
    final ext = _safeExtFromPath((payload['ext'] ?? '').toString(), mediaType);
    if (url.isEmpty || nonceB64.isEmpty || macB64.isEmpty) throw StateError('INVALID_ENCRYPTED_MEDIA_PAYLOAD');

    final cacheKey = '$url|$nonceB64|$macB64|$me|$peer';
    final cached = _decryptedMediaCache[cacheKey];
    if (cached != null && await File(cached).exists()) return cached;

    await ensureCurrentUserPublicKey(me);
    final encryptedBytes = await _downloadBytes(url);
    final key = await _conversationKey(myUsername: me, peerUsername: peer, context: 'direct_media_file');
    // نحاول أولاً AAD التفصيلي المطابق للإرسال، ثم fallback قديم للتوافق.
    final sender = displayUsername((payload['sender'] ?? payload['sender_username'] ?? '').toString());
    final receiver = displayUsername((payload['receiver'] ?? payload['receiver_username'] ?? '').toString());
    final aadDetailed = utf8.encode('direct_media_file|${sender == '@user' ? peer : sender}|${receiver == '@user' ? me : receiver}|$mediaType|$ext');

    List<int> clear;
    try {
      clear = await _aesGcm.decrypt(
        SecretBox(encryptedBytes, nonce: base64Decode(nonceB64), mac: Mac(base64Decode(macB64))),
        secretKey: key,
        aad: aadDetailed,
      );
    } catch (_) {
      // fallback لملفات أُنشئت بنسخة قديمة من AAD إن وجدت.
      clear = await _aesGcm.decrypt(
        SecretBox(encryptedBytes, nonce: base64Decode(nonceB64), mac: Mac(base64Decode(macB64))),
        secretKey: key,
        aad: utf8.encode('direct_media_file'),
      );
    }

    final output = await _writeTempFile(clear, 'decrypted', ext);
    _decryptedMediaCache[cacheKey] = output.path;
    return output.path;
  }

  static Map<String, dynamic>? encryptedMediaPayloadFromRaw(String raw) {
    final value = raw.trim();
    if (value.isEmpty || !value.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map && isEncryptedMediaPayload(decoded)) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static Future<void> _decryptDirectMediaInRow(Map<String, dynamic> row, String me, String peer) async {
    final rawType = (row['media_type'] ?? '').toString().trim().toLowerCase();
    final rawUrl = (row['media_url'] ?? '').toString().trim();
    if (rawType.isEmpty || rawUrl.isEmpty) return;

    try {
      if (rawType == 'gallery' || rawUrl.startsWith('[')) {
        final decoded = jsonDecode(rawUrl);
        if (decoded is! List) return;
        final out = <Map<String, dynamic>>[];
        for (final item in decoded) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          Map<String, dynamic>? encryptedMap;
          if (isEncryptedMediaPayload(map)) {
            encryptedMap = map;
          } else {
            final nestedRaw = (map['url'] ?? map['media_url'] ?? '').toString();
            encryptedMap = encryptedMediaPayloadFromRaw(nestedRaw);
            if (encryptedMap != null) {
              encryptedMap['type'] = encryptedMap['type'] ?? map['type'];
              encryptedMap['media_type'] = encryptedMap['media_type'] ?? map['media_type'] ?? map['type'];
              encryptedMap['max_views'] = encryptedMap['max_views'] ?? map['max_views'];
            }
          }

          if (encryptedMap != null) {
            encryptedMap['sender'] = encryptedMap['sender'] ?? row['sender_username'];
            encryptedMap['receiver'] = encryptedMap['receiver'] ?? row['receiver_username'];
            final local = await decryptMediaPayloadForPeer(currentUsername: me, peerUsername: peer, payload: encryptedMap);
            out.add(<String, dynamic>{
              'url': local,
              'type': (encryptedMap['media_type'] ?? encryptedMap['type'] ?? map['type'] ?? 'image').toString(),
              if ((encryptedMap['max_views'] ?? map['max_views']) != null) 'max_views': encryptedMap['max_views'] ?? map['max_views'],
            });
          } else {
            out.add(map);
          }
        }
        row['media_url'] = jsonEncode(out);
        return;
      }

      final payload = encryptedMediaPayloadFromRaw(rawUrl);
      if (payload == null) return;
      payload['sender'] = payload['sender'] ?? row['sender_username'];
      payload['receiver'] = payload['receiver'] ?? row['receiver_username'];
      row['media_url'] = await decryptMediaPayloadForPeer(currentUsername: me, peerUsername: peer, payload: payload);
      row['media_type'] = (payload['media_type'] ?? payload['type'] ?? rawType).toString();
    } catch (e, st) {
      _secureSafeLog(e, st);
      row['media_url'] = '';
      row['text'] = encryptedMediaPlaceholder;
    }
  }


  // ================= Group E2EE =================
  // تشفير المجموعات هنا لا يستخدم مفتاحًا جماعيًا واحدًا.
  // بدل ذلك يتم إنشاء نسخة مشفرة مستقلة لكل عضو باستخدام X25519 + AES-GCM 256.
  // هذا يمنع تخزين النص الحقيقي في قاعدة البيانات، ويجعل كل عضو يفك نسخته فقط.
  static const String groupEnvelopeVersion = 'respect_group_e2ee_per_member_v1';

  static bool isEncryptedGroupTextPayload(dynamic value) {
    if (value is Map) {
      return value['respect_group_e2ee'] == true || value['respect_group_e2ee']?.toString() == 'true';
    }
    if (value is String) {
      final raw = value.trim();
      if (!raw.startsWith('{')) return false;
      try {
        final decoded = jsonDecode(raw);
        return decoded is Map && isEncryptedGroupTextPayload(decoded);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  static bool isEncryptedGroupMediaPayload(dynamic value) {
    if (value is Map) {
      return value['respect_group_e2ee_media'] == true || value['respect_group_e2ee_media']?.toString() == 'true';
    }
    if (value is String) {
      final raw = value.trim();
      if (!raw.startsWith('{')) return false;
      try {
        final decoded = jsonDecode(raw);
        return decoded is Map && isEncryptedGroupMediaPayload(decoded);
      } catch (_) {
        return false;
      }
    }
    return false;
  }



  // ================= Respect Call Signaling E2EE =================
  // تشفير إشارات WebRTC الحساسة: offer / answer / ICE candidates / renegotiation.
  // قاعدة البيانات ترى فقط envelope مشفر ولا ترى SDP أو ICE الحقيقي.
  static const String callSignalEnvelopeVersion = 'respect_call_signal_e2ee_v1';

  static bool isEncryptedCallSignalPayload(dynamic value) {
    if (value is Map) return value['respect_call_signal_e2ee'] == true;
    if (value is String) {
      final raw = value.trim();
      if (!raw.startsWith('{')) return false;
      try {
        final decoded = jsonDecode(raw);
        return decoded is Map && decoded['respect_call_signal_e2ee'] == true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  static Future<Map<String, dynamic>> encryptCallSignalPayload({
    required String sender,
    required String receiver,
    required String roomId,
    required String signalType,
    required Map<String, dynamic> payload,
  }) async {
    final me = displayUsername(sender);
    final peer = displayUsername(receiver);
    if (me == '@user' || peer == '@user') throw StateError('CALL_E2EE_INVALID_PARTICIPANTS');

    await ensureCurrentUserPublicKey(me);
    final hasPeerKey = await hasPublicKeyForUsername(peer);
    if (!hasPeerKey) throw StateError('CALL_E2EE_PEER_KEY_MISSING');

    final context = 'call_signal_${roomId.trim()}_${signalType.trim()}';
    final clear = jsonEncode(<String, dynamic>{
      'type': signalType,
      'payload': payload,
      'room_id': roomId.trim(),
      'sender': me,
      'receiver': peer,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final box = await _encryptString(
      myUsername: me,
      peerUsername: peer,
      plainText: clear,
      context: context,
    );

    return <String, dynamic>{
      'respect_call_signal_e2ee': true,
      'version': callSignalEnvelopeVersion,
      'crypto_version': encryptionVersion,
      'room_id': roomId.trim(),
      'sender': me,
      'receiver': peer,
      'signal_type': signalType,
      'context': context,
      'ciphertext': box['ciphertext'],
      'nonce': box['nonce'],
      'mac': box['mac'],
    };
  }

  static Future<Map<String, dynamic>> decryptCallSignalPayload({
    required String currentUsername,
    required Map<String, dynamic> envelope,
  }) async {
    if (!isEncryptedCallSignalPayload(envelope)) {
      return <String, dynamic>{
        'type': (envelope['type'] ?? '').toString(),
        'payload': envelope['payload'] is Map ? Map<String, dynamic>.from(envelope['payload'] as Map) : <String, dynamic>{},
      };
    }

    final me = displayUsername(currentUsername);
    final sender = displayUsername((envelope['sender'] ?? '').toString());
    final receiver = displayUsername((envelope['receiver'] ?? '').toString());
    final context = (envelope['context'] ?? '').toString();
    if (me == '@user' || sender == '@user' || receiver == '@user' || context.isEmpty) {
      throw StateError('INVALID_CALL_E2EE_PAYLOAD');
    }

    final peer = sender == me ? receiver : sender;
    final clear = await _decryptString(
      myUsername: me,
      peerUsername: peer,
      ciphertextB64: (envelope['ciphertext'] ?? '').toString(),
      nonceB64: (envelope['nonce'] ?? '').toString(),
      macB64: (envelope['mac'] ?? '').toString(),
      context: context,
    );
    final decoded = jsonDecode(clear);
    if (decoded is! Map) throw StateError('INVALID_CALL_E2EE_CLEAR_PAYLOAD');
    final map = Map<String, dynamic>.from(decoded as Map);
    final payloadRaw = map['payload'];
    return <String, dynamic>{
      'type': (map['type'] ?? envelope['signal_type'] ?? '').toString(),
      'payload': payloadRaw is Map ? Map<String, dynamic>.from(payloadRaw as Map) : <String, dynamic>{},
    };
  }

  static List<String> _cleanGroupMembers(Iterable<String> usernames, String sender) {
    final out = usernames
        .map(displayUsername)
        .where((u) => u != '@user')
        .toSet()
        .toList();
    final senderUser = displayUsername(sender);
    if (senderUser != '@user' && !out.contains(senderUser)) out.add(senderUser);
    out.sort();
    return out;
  }

  static Future<String> encryptGroupTextPayload({
    required String sender,
    required String groupId,
    required Iterable<String> memberUsernames,
    required String plainText,
    required String purpose,
  }) async {
    final cleanText = plainText.trim();
    if (cleanText.isEmpty) return '';

    final senderUser = displayUsername(sender);
    await ensureCurrentUserPublicKey(senderUser);
    final members = _cleanGroupMembers(memberUsernames, senderUser);
    if (members.isEmpty) throw StateError('GROUP_E2EE_NO_MEMBERS');

    final context = 'group_${purpose}_${groupId.trim()}';
    final recipients = <String, dynamic>{};
    final missing = <String>[];

    for (final member in members) {
      try {
        final key = await publicKeyForUsername(member);
        if (key == null) {
          missing.add(member);
          continue;
        }
        final box = await _encryptString(
          myUsername: senderUser,
          peerUsername: member,
          plainText: cleanText,
          context: context,
        );
        recipients[member] = box;
      } catch (e, st) {
        _secureSafeLog(e, st);
        missing.add(member);
      }
    }

    if (recipients.isEmpty) {
      throw StateError('GROUP_E2EE_NOT_READY: لا يمكن إرسال رسالة مشفرة للمجموعة قبل تجهيز مفاتيح الأعضاء. افتح التطبيق من حسابات الأعضاء مرة واحدة بعد التحديث.');
    }

    return jsonEncode(<String, dynamic>{
      'respect_group_e2ee': true,
      'version': groupEnvelopeVersion,
      'crypto_version': encryptionVersion,
      'group_id': groupId.trim(),
      'sender': senderUser,
      'purpose': purpose,
      'context': context,
      'recipients': recipients,
      if (missing.isNotEmpty) 'missing': missing,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<String> decryptGroupTextPayload({
    required String currentUsername,
    required String rawPayload,
  }) async {
    final raw = rawPayload.trim();
    if (raw.isEmpty || !raw.startsWith('{')) return rawPayload;

    final decoded = jsonDecode(raw);
    if (decoded is! Map || !isEncryptedGroupTextPayload(decoded)) return rawPayload;

    final map = Map<String, dynamic>.from(decoded);
    final me = displayUsername(currentUsername);
    final sender = displayUsername((map['sender'] ?? '').toString());
    final context = (map['context'] ?? '').toString();
    final recipientsRaw = map['recipients'];
    if (context.isEmpty || recipientsRaw is! Map) throw StateError('INVALID_GROUP_E2EE_PAYLOAD');

    final recipients = Map<String, dynamic>.from(recipientsRaw as Map);
    dynamic mine = recipients[me];
    if (mine == null && sender == me) mine = recipients[sender];
    if (mine is! Map) throw StateError('GROUP_E2EE_NO_RECIPIENT_COPY');

    final mineMap = Map<String, dynamic>.from(mine as Map);
    return _decryptString(
      myUsername: me,
      peerUsername: sender == me ? me : sender,
      ciphertextB64: (mineMap['ciphertext'] ?? '').toString(),
      nonceB64: (mineMap['nonce'] ?? '').toString(),
      macB64: (mineMap['mac'] ?? '').toString(),
      context: context,
    );
  }

  static Future<Map<String, dynamic>> encryptedGroupFields({
    required String sender,
    required String groupId,
    required Iterable<String> memberUsernames,
    required String text,
    String? replyText,
  }) async {
    final out = <String, dynamic>{
      'text': text.trim(),
    };

    final cleanText = text.trim();
    final cleanReply = replyText?.trim() ?? '';
    if (cleanText.isNotEmpty) {
      out['text'] = await encryptGroupTextPayload(
        sender: sender,
        groupId: groupId,
        memberUsernames: memberUsernames,
        plainText: cleanText,
        purpose: 'message_text',
      );
    }
    if (cleanReply.isNotEmpty) {
      out['reply_text'] = await encryptGroupTextPayload(
        sender: sender,
        groupId: groupId,
        memberUsernames: memberUsernames,
        plainText: cleanReply,
        purpose: 'message_reply',
      );
    }
    return out;
  }

  static Future<Map<String, dynamic>> decryptGroupRow(Map<String, dynamic> row, String currentUsername) async {
    final me = displayUsername(currentUsername);
    try {
      await ensureCurrentUserPublicKey(me);
      final rawText = (row['text'] ?? '').toString();
      if (isEncryptedGroupTextPayload(rawText)) {
        row['text'] = await decryptGroupTextPayload(currentUsername: me, rawPayload: rawText);
      }

      final rawReply = (row['reply_text'] ?? '').toString();
      if (isEncryptedGroupTextPayload(rawReply)) {
        row['reply_text'] = await decryptGroupTextPayload(currentUsername: me, rawPayload: rawReply);
      }

      await _decryptGroupMediaInRow(row, me);
    } catch (e, st) {
      _secureSafeLog(e, st);
      final rawText = (row['text'] ?? '').toString();
      if (isEncryptedGroupTextPayload(rawText)) row['text'] = encryptedTextPlaceholder;
      final rawReply = (row['reply_text'] ?? '').toString();
      if (isEncryptedGroupTextPayload(rawReply)) row['reply_text'] = encryptedTextPlaceholder;
    }
    return row;
  }

  static Future<List<Map<String, dynamic>>> decryptGroupRows(List<Map<String, dynamic>> rows, String currentUsername) async {
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      out.add(await decryptGroupRow(Map<String, dynamic>.from(row), currentUsername));
    }
    return out;
  }

  static Map<String, dynamic>? encryptedGroupMediaPayloadFromRaw(String raw) {
    final value = raw.trim();
    if (value.isEmpty || !value.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map && isEncryptedGroupMediaPayload(decoded)) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static Future<String> decryptGroupMediaPayload({
    required String currentUsername,
    required Map<String, dynamic> payload,
  }) async {
    final me = displayUsername(currentUsername);
    final sender = displayUsername((payload['sender'] ?? '').toString());
    final recipientsRaw = payload['recipients'];
    if (sender == '@user' || recipientsRaw is! Map) throw StateError('INVALID_GROUP_MEDIA_PAYLOAD');

    final recipients = Map<String, dynamic>.from(recipientsRaw as Map);
    dynamic mine = recipients[me];
    if (mine == null && sender == me) mine = recipients[sender];
    if (mine is! Map) throw StateError('GROUP_MEDIA_NO_RECIPIENT_COPY');

    final mineMap = Map<String, dynamic>.from(mine as Map);
    mineMap['sender'] = sender;
    mineMap['receiver'] = me;
    mineMap['media_type'] = mineMap['media_type'] ?? payload['media_type'];
    mineMap['type'] = mineMap['type'] ?? payload['media_type'];
    return decryptMediaPayloadForPeer(
      currentUsername: me,
      peerUsername: sender == me ? me : sender,
      payload: mineMap,
    );
  }

  static Future<void> _decryptGroupMediaInRow(Map<String, dynamic> row, String me) async {
    final rawType = (row['media_type'] ?? '').toString().trim().toLowerCase();
    final rawUrl = (row['media_url'] ?? '').toString().trim();
    if (rawType.isEmpty || rawUrl.isEmpty) return;

    try {
      if (rawType == 'gallery' || rawUrl.startsWith('[')) {
        final decoded = jsonDecode(rawUrl);
        if (decoded is! List) return;
        final out = <Map<String, dynamic>>[];
        for (final item in decoded) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final nestedRaw = (map['url'] ?? map['media_url'] ?? '').toString();
          final encryptedMap = isEncryptedGroupMediaPayload(map)
              ? map
              : encryptedGroupMediaPayloadFromRaw(nestedRaw);

          if (encryptedMap != null) {
            final local = await decryptGroupMediaPayload(currentUsername: me, payload: Map<String, dynamic>.from(encryptedMap));
            out.add(<String, dynamic>{
              'url': local,
              'type': (encryptedMap['media_type'] ?? encryptedMap['type'] ?? map['type'] ?? 'image').toString(),
              if ((encryptedMap['max_views'] ?? map['max_views']) != null) 'max_views': encryptedMap['max_views'] ?? map['max_views'],
            });
          } else {
            out.add(map);
          }
        }
        row['media_url'] = jsonEncode(out);
        return;
      }

      final payload = encryptedGroupMediaPayloadFromRaw(rawUrl);
      if (payload == null) return;
      row['media_url'] = await decryptGroupMediaPayload(currentUsername: me, payload: payload);
      row['media_type'] = (payload['media_type'] ?? payload['type'] ?? rawType).toString();
    } catch (e, st) {
      _secureSafeLog(e, st);
      row['media_url'] = '';
      row['text'] = encryptedMediaPlaceholder;
    }
  }


  // ─── Stories E2EE ─────────────────────────────────────────────────────────
  static const String storyMediaEnvelopeVersion = 'respect_story_media_e2ee_v1';

  static bool isEncryptedStoryMediaPayload(dynamic value) {
    try {
      if (value is String) {
        final raw = value.trim();
        if (raw.isEmpty || !raw.startsWith('{')) return false;
        value = jsonDecode(raw);
      }
      return value is Map && value['respect_story_media_e2ee'] == true;
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic>? encryptedStoryMediaPayloadFromRaw(String raw) {
    final value = raw.trim();
    if (value.isEmpty || !value.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map && isEncryptedStoryMediaPayload(decoded)) {
        return Map<String, dynamic>.from(decoded as Map);
      }
    } catch (_) {}
    return null;
  }

  static Future<Map<String, dynamic>> encryptStoryMediaFile({
    required String sender,
    required Iterable<String> viewerUsernames,
    required String filePath,
    required String mediaType,
  }) async {
    final senderUser = displayUsername(sender);
    if (senderUser == '@user') throw StateError('STORY_E2EE_INVALID_SENDER');
    await ensureCurrentUserPublicKey(senderUser);

    final source = File(filePath.trim());
    if (!await source.exists()) throw StateError('STORY_MEDIA_FILE_NOT_FOUND');

    final viewers = viewerUsernames
        .map(displayUsername)
        .where((u) => u != '@user')
        .toSet()
        .toList();
    if (!viewers.contains(senderUser)) viewers.add(senderUser);
    viewers.sort();
    if (viewers.isEmpty) throw StateError('STORY_E2EE_NO_VIEWERS');

    final plainBytes = await source.readAsBytes();
    final storyKey = await _aesGcm.newSecretKey();
    final storyKeyBytes = await storyKey.extractBytes();
    final dataNonce = _randomNonce();
    final ext = _safeExtFromPath(filePath, mediaType);
    final keyId = base64UrlEncode(_randomNonce(18));
    final media = mediaType.toLowerCase().contains('video') ? 'video' : 'image';
    final aad = utf8.encode('story_media_file|$senderUser|$keyId|$media|$ext');
    final encrypted = await _aesGcm.encrypt(
      plainBytes,
      secretKey: storyKey,
      nonce: dataNonce,
      aad: aad,
    );

    final encryptedFile = await _writeTempFile(encrypted.cipherText, 'story_upload', 'renc');
    final keyContext = 'story_media_key_${senderUser}_${keyId}';
    final recipients = <String, dynamic>{};
    final missing = <String>[];
    final wrappedKey = base64Encode(storyKeyBytes);

    for (final viewer in viewers) {
      try {
        final public = await publicKeyForUsername(viewer);
        if (public == null) {
          missing.add(viewer);
          continue;
        }
        recipients[viewer] = await _encryptString(
          myUsername: senderUser,
          peerUsername: viewer,
          plainText: wrappedKey,
          context: keyContext,
        );
      } catch (e, st) {
        _secureSafeLog(e, st);
        missing.add(viewer);
      }
    }

    if (recipients.isEmpty) {
      throw StateError('STORY_E2EE_NOT_READY: لا يمكن نشر ستوري مشفر قبل تجهيز مفاتيح الأشخاص المختارين. افتح التطبيق من حساباتهم مرة واحدة بعد التحديث.');
    }

    return <String, dynamic>{
      'file': encryptedFile,
      'metadata': <String, dynamic>{
        'respect_story_media_e2ee': true,
        'version': storyMediaEnvelopeVersion,
        'crypto_version': encryptionVersion,
        'sender': senderUser,
        'key_id': keyId,
        'key_context': keyContext,
        'media_type': media,
        'type': media,
        'ext': ext,
        'nonce': base64Encode(encrypted.nonce),
        'mac': base64Encode(encrypted.mac.bytes),
        'size': plainBytes.length,
        'recipients': recipients,
        if (missing.isNotEmpty) 'missing': missing,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
    };
  }

  static Future<String> decryptStoryMediaPayload({
    required String currentUsername,
    required Map<String, dynamic> payload,
  }) async {
    final me = displayUsername(currentUsername);
    final sender = displayUsername((payload['sender'] ?? '').toString());
    final url = (payload['url'] ?? payload['media_url'] ?? '').toString().trim();
    final nonceB64 = (payload['nonce'] ?? '').toString().trim();
    final macB64 = (payload['mac'] ?? '').toString().trim();
    final mediaType = (payload['media_type'] ?? payload['type'] ?? 'image').toString().toLowerCase();
    final ext = _safeExtFromPath((payload['ext'] ?? '').toString(), mediaType);
    final keyContext = (payload['key_context'] ?? '').toString().trim();
    final recipientsRaw = payload['recipients'];
    if (me == '@user' || sender == '@user' || url.isEmpty || nonceB64.isEmpty || macB64.isEmpty || keyContext.isEmpty || recipientsRaw is! Map) {
      throw StateError('INVALID_STORY_E2EE_PAYLOAD');
    }

    final cacheKey = 'story|$url|$nonceB64|$macB64|$me';
    final cached = _decryptedMediaCache[cacheKey];
    if (cached != null && await File(cached).exists()) return cached;

    final recipients = Map<String, dynamic>.from(recipientsRaw as Map);
    dynamic mine = recipients[me];
    if (mine == null && sender == me) mine = recipients[sender];
    if (mine is! Map) throw StateError('STORY_MEDIA_NO_RECIPIENT_COPY');

    final mineMap = Map<String, dynamic>.from(mine as Map);
    final wrappedKeyB64 = await _decryptString(
      myUsername: me,
      peerUsername: sender == me ? me : sender,
      ciphertextB64: (mineMap['ciphertext'] ?? '').toString(),
      nonceB64: (mineMap['nonce'] ?? '').toString(),
      macB64: (mineMap['mac'] ?? '').toString(),
      context: keyContext,
    );

    final storyKey = SecretKey(base64Decode(wrappedKeyB64));
    final encryptedBytes = await _downloadBytes(url);
    final keyId = (payload['key_id'] ?? '').toString();
    final aad = utf8.encode('story_media_file|$sender|$keyId|$mediaType|$ext');
    final clear = await _aesGcm.decrypt(
      SecretBox(encryptedBytes, nonce: base64Decode(nonceB64), mac: Mac(base64Decode(macB64))),
      secretKey: storyKey,
      aad: aad,
    );
    final output = await _writeTempFile(clear, 'story_decrypted', ext);
    _decryptedMediaCache[cacheKey] = output.path;
    return output.path;
  }

  static Future<Map<String, dynamic>> decryptStoryRow(Map<String, dynamic> row, String currentUsername) async {
    final rawUrl = (row['media_url'] ?? '').toString().trim();
    final payload = encryptedStoryMediaPayloadFromRaw(rawUrl);
    if (payload == null) return row;
    try {
      final local = await decryptStoryMediaPayload(currentUsername: currentUsername, payload: payload);
      row['media_url'] = local;
      row['media_type'] = (payload['media_type'] ?? payload['type'] ?? row['media_type'] ?? '').toString();
      row['privacy'] = row['privacy'] ?? payload['privacy'];
      row['is_private'] = row['is_private'] ?? payload['is_private'];
      row['allowed_viewers'] = row['allowed_viewers'] ?? payload['allowed_viewers'];
      row['encrypted_media'] = true;
      row['e2ee_unlocked'] = true;
    } catch (e, st) {
      _secureSafeLog(e, st);
      row['media_url'] = '';
      row['e2ee_unlocked'] = false;
      row['text'] = encryptedMediaPlaceholder;
    }
    return row;
  }

  static Future<List<Map<String, dynamic>>> decryptStoryRows(List<Map<String, dynamic>> rows, String currentUsername) async {
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      out.add(await decryptStoryRow(Map<String, dynamic>.from(row), currentUsername));
    }
    return out;
  }

}
