import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// App side of the encrypted BLE channel. Mirrors firmware/smarthome_node/crypto.h and
/// firmware/tests/ble_protocol_reference.py (a known-answer test in test/ble_crypto_test.dart
/// proves both sides produce the same bytes).
///
///   key     = PBKDF2-HMAC-SHA256(secret, salt, 2048 iterations, 32 bytes)
///   message = ctr(4, big endian) | iv(12) | tag(16) | ciphertext        AES-256-GCM
///   AAD     = "SHREQ" + ctr  (app -> board)     "SHRSP" + ctr  (board -> app)
class BleCrypto {
  static final AesGcm _gcm = AesGcm.with256bits();
  static final Pbkdf2 _kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 2048, bits: 256);
  static final Random _rng = Random.secure();

  static Future<SecretKey> deriveKey(String secret, List<int> salt) =>
      _kdf.deriveKeyFromPassword(password: secret, nonce: salt);

  static Uint8List _aad(String label, int ctr) {
    final b = BytesBuilder()
      ..add(label.codeUnits)
      ..add([(ctr >> 24) & 255, (ctr >> 16) & 255, (ctr >> 8) & 255, ctr & 255]);
    return b.toBytes();
  }

  static Future<Uint8List> seal(SecretKey key, int ctr, String label, List<int> plain, {List<int>? iv}) async {
    final nonce = iv ?? List<int>.generate(12, (_) => _rng.nextInt(256));
    final box = await _gcm.encrypt(plain, secretKey: key, nonce: nonce, aad: _aad(label, ctr));
    final out = BytesBuilder()
      ..add([(ctr >> 24) & 255, (ctr >> 16) & 255, (ctr >> 8) & 255, ctr & 255])
      ..add(nonce)
      ..add(box.mac.bytes)
      ..add(box.cipherText);
    return out.toBytes();
  }

  /// Throws if the message was tampered with or the key is wrong.
  static Future<({int ctr, Uint8List plain})> open(SecretKey key, Uint8List msg, String label) async {
    if (msg.length < 32) throw const FormatException('message too short');
    final ctr = (msg[0] << 24) | (msg[1] << 16) | (msg[2] << 8) | msg[3];
    final iv = msg.sublist(4, 16);
    final tag = msg.sublist(16, 32);
    final ct = msg.sublist(32);
    final plain = await _gcm.decrypt(SecretBox(ct, nonce: iv, mac: Mac(tag)), secretKey: key, aad: _aad(label, ctr));
    return (ctr: ctr, plain: Uint8List.fromList(plain));
  }
}

/// [index][total][payload...] framing so a message can be larger than one BLE packet.
List<Uint8List> toFrames(Uint8List msg, {int chunk = 120}) {
  final total = (msg.length + chunk - 1) ~/ chunk;
  return [
    for (var i = 0; i < total; i++)
      Uint8List.fromList([i, total, ...msg.sublist(i * chunk, (i + 1) * chunk > msg.length ? msg.length : (i + 1) * chunk)])
  ];
}

class FrameAssembler {
  final BytesBuilder _buf = BytesBuilder();
  int _expect = 0;

  void reset() {
    _buf.clear();
    _expect = 0;
  }

  /// Returns the full message once the last frame arrived, otherwise null.
  /// Throws [FormatException] on a protocol error.
  Uint8List? push(List<int> frame) {
    if (frame.length < 3) {
      reset();
      throw const FormatException('short frame');
    }
    final idx = frame[0], total = frame[1];
    if (idx == 0) reset();
    if (total == 0 || idx >= total || idx != _expect) {
      reset();
      throw const FormatException('frame out of order');
    }
    _buf.add(frame.sublist(2));
    _expect++;
    if (_expect == total) {
      final out = _buf.toBytes();
      reset();
      return out;
    }
    return null;
  }
}
