import 'dart:convert';
import 'dart:typed_data';

import 'package:esp32_controller/services/ble_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Known-answer vector produced by firmware/tests/ble_protocol_reference.py (Python + the same
// algorithm as the firmware). If this test passes, app and board speak the same cipher.
const _key = '0247b50fa41108a36ef76c11c2049c07eddcef9ec8bcb718159c9fe1ab270212';
const _msg = '000000016465666768696a6b6c6d6e6f5b4b5f9f5c92a2ba37748b3f5c07ae4c315471d472fea5e27809d44f95';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

void main() {
  final salt = List<int>.generate(16, (i) => i);
  final iv = List<int>.generate(12, (i) => 100 + i);

  test('PBKDF2 key matches the reference', () async {
    final k = await BleCrypto.deriveKey('ABCDEFGHJK', salt);
    expect(_hex(await k.extractBytes()), _key);
  });

  test('seal() produces exactly the reference message', () async {
    final k = await BleCrypto.deriveKey('ABCDEFGHJK', salt);
    final m = await BleCrypto.seal(k, 1, 'SHREQ', utf8.encode('{"op":"info"}'), iv: iv);
    expect(_hex(m), _msg);
  });

  test('open() decrypts the reference message and rejects tampering / wrong label / wrong key', () async {
    final k = await BleCrypto.deriveKey('ABCDEFGHJK', salt);
    final r = await BleCrypto.open(k, _unhex(_msg), 'SHREQ');
    expect(r.ctr, 1);
    expect(utf8.decode(r.plain), '{"op":"info"}');

    final bad = _unhex(_msg)..[40] ^= 1;
    await expectLater(BleCrypto.open(k, bad, 'SHREQ'), throwsA(anything));
    await expectLater(BleCrypto.open(k, _unhex(_msg), 'SHRSP'), throwsA(anything)); // request replayed as answer
    final other = await BleCrypto.deriveKey('WRONGCODE1', salt);
    await expectLater(BleCrypto.open(other, _unhex(_msg), 'SHREQ'), throwsA(anything));
  });

  test('frames: split and reassemble a provisioning-sized message', () async {
    final k = await BleCrypto.deriveKey('ABCDEFGHJK', salt);
    final big = await BleCrypto.seal(k, 2, 'SHREQ', utf8.encode('x' * 925));
    final frames = toFrames(big);
    expect(frames.length, 8);
    expect(frames.every((f) => f.length <= 122), true);
    final asm = FrameAssembler();
    Uint8List? out;
    for (final f in frames) {
      out = asm.push(f);
    }
    expect(out, big);
  });

  test('frame assembler rejects out-of-order frames', () {
    final asm = FrameAssembler();
    expect(() => asm.push([1, 3, 65]), throwsFormatException);
    expect(asm.push([0, 2, 65, 66]), isNull);
    expect(() => asm.push([0, 2]), throwsFormatException);
  });
}
