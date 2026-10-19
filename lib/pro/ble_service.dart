/// BLE link to a v4 board (firmware ble_link.h).
///
/// * Finds boards advertising the Smart Home service.
/// * Commands/answers are JSON lines ('\n' terminated) split into MTU sized
///   chunks. The RX/TX characteristics need an ENCRYPTED + authenticated link:
///   Android shows the pairing dialog and asks for the board PIN (BLE_PASSKEY).
/// * Used to provision Wi-Fi, MQTT, Telegram token, cloud keys ... to a new
///   board without USB, and as a local control path when there is no router.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

final Guid bleServiceUuid = Guid('6e3a0001-5f1c-4c1b-9d1e-8b5a3c2d1e00');
final Guid _infoUuid = Guid('6e3a0002-5f1c-4c1b-9d1e-8b5a3c2d1e00');
final Guid _rxUuid = Guid('6e3a0003-5f1c-4c1b-9d1e-8b5a3c2d1e00');
final Guid _txUuid = Guid('6e3a0004-5f1c-4c1b-9d1e-8b5a3c2d1e00');

class BleBoard {
  BleBoard(this.device);

  final BluetoothDevice device;
  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _tx;
  BluetoothCharacteristic? _info;
  StreamSubscription<List<int>>? _sub;
  final StringBuffer _buf = StringBuffer();
  final List<Completer<Map<String, dynamic>>> _waiting = [];
  int _mtu = 23;

  String get name => device.platformName.isEmpty ? device.remoteId.str : device.platformName;

  static Future<bool> get supported => FlutterBluePlus.isSupported;

  /// Scans for boards for [timeout]. Emits the growing list.
  static Stream<List<BleBoard>> scan({Duration timeout = const Duration(seconds: 6)}) async* {
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
    }
    final seen = <String, BleBoard>{};
    final controller = StreamController<List<BleBoard>>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        seen.putIfAbsent(r.device.remoteId.str, () => BleBoard(r.device));
      }
      controller.add(seen.values.toList());
    });
    unawaited(FlutterBluePlus.startScan(withServices: [bleServiceUuid], timeout: timeout).then((_) async {
      await FlutterBluePlus.isScanning.where((s) => !s).first;
      await sub.cancel();
      await controller.close();
    }).catchError((Object e) async {
      await sub.cancel();
      controller.addError(e);
      await controller.close();
    }));
    yield* controller.stream;
  }

  Future<void> connect() async {
    await device.connect(timeout: const Duration(seconds: 15), mtu: null);
    try {
      _mtu = await device.requestMtu(247);
    } catch (_) {
      _mtu = 23;
    }
    final services = await device.discoverServices();
    for (final s in services) {
      if (s.uuid != bleServiceUuid) continue;
      for (final c in s.characteristics) {
        if (c.uuid == _rxUuid) _rx = c;
        if (c.uuid == _txUuid) _tx = c;
        if (c.uuid == _infoUuid) _info = c;
      }
    }
    if (_rx == null || _tx == null) {
      await disconnect();
      throw Exception('Not a Smart Home v4 board');
    }
    // Subscribing to the encrypted TX characteristic triggers pairing (PIN).
    _sub = _tx!.onValueReceived.listen(_onData);
    device.cancelWhenDisconnected(_sub!);
    await _tx!.setNotifyValue(true);
  }

  void _onData(List<int> chunk) {
    _buf.write(utf8.decode(chunk, allowMalformed: true));
    var text = _buf.toString();
    var nl = text.indexOf('\n');
    while (nl >= 0) {
      final line = text.substring(0, nl).trim();
      text = text.substring(nl + 1);
      if (line.isNotEmpty && _waiting.isNotEmpty) {
        final c = _waiting.removeAt(0);
        try {
          final j = jsonDecode(line);
          c.complete(j is Map<String, dynamic> ? j : {'ok': false, 'error': 'bad answer'});
        } catch (_) {
          c.complete({'ok': false, 'error': 'bad answer'});
        }
      }
      nl = text.indexOf('\n');
    }
    _buf
      ..clear()
      ..write(text);
  }

  /// Public, unencrypted info: name, node id, firmware, provisioned.
  Future<Map<String, dynamic>> info() async {
    final c = _info;
    if (c == null) return {};
    final v = await c.read();
    try {
      return jsonDecode(utf8.decode(v)) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Sends one command and waits for its answer.
  Future<Map<String, dynamic>> send(Map<String, dynamic> cmd,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final rx = _rx;
    if (rx == null) throw Exception('Not connected');
    final c = Completer<Map<String, dynamic>>();
    _waiting.add(c);
    final bytes = utf8.encode('${jsonEncode(cmd)}\n');
    final size = (_mtu - 3).clamp(20, 244);
    for (var i = 0; i < bytes.length; i += size) {
      final end = (i + size < bytes.length) ? i + size : bytes.length;
      await rx.write(bytes.sublist(i, end), withoutResponse: false);
    }
    return c.future.timeout(timeout, onTimeout: () {
      _waiting.remove(c);
      return {'ok': false, 'error': 'no answer over BLE'};
    });
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    for (final c in _waiting) {
      if (!c.isCompleted) c.complete({'ok': false, 'error': 'disconnected'});
    }
    _waiting.clear();
    await device.disconnect();
  }
}
