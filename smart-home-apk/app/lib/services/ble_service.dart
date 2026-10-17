import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_crypto.dart';

final Uuid kBleService = Uuid.parse('a7c10000-5c1f-4b7a-9d2e-5348424c4501');
final Uuid kBleInfo = Uuid.parse('a7c10001-5c1f-4b7a-9d2e-5348424c4501');
final Uuid kBleRx = Uuid.parse('a7c10002-5c1f-4b7a-9d2e-5348424c4501');
final Uuid kBleTx = Uuid.parse('a7c10003-5c1f-4b7a-9d2e-5348424c4501');

class BleException implements Exception {
  BleException(this.message);
  final String message;
  @override
  String toString() => message;
}

final FlutterReactiveBle _ble = FlutterReactiveBle();

Future<bool> ensureBlePermissions() async {
  final res = await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
  // Android 12+ needs scan + connect; older versions need location. Either set is enough.
  final modern = res[Permission.bluetoothScan]?.isGranted == true && res[Permission.bluetoothConnect]?.isGranted == true;
  final legacy = res[Permission.locationWhenInUse]?.isGranted == true;
  return modern || legacy;
}

/// Boards that advertise the Smart Home service (new boards, boards in a pairing window, and
/// boards in offline mode).
Stream<DiscoveredDevice> scanBoards() => _ble.scanForDevices(withServices: [kBleService], scanMode: ScanMode.lowLatency);

/// One authenticated, encrypted conversation with a board.
class BleSession {
  BleSession(this.deviceId);
  final String deviceId;

  StreamSubscription<ConnectionStateUpdate>? _conn;
  StreamSubscription<List<int>>? _notif;
  final FrameAssembler _asm = FrameAssembler();
  Completer<Uint8List>? _waiting;
  SecretKey? _key;
  int _ctr = 0;
  Map<String, dynamic> info = const {};

  QualifiedCharacteristic _q(Uuid c) => QualifiedCharacteristic(serviceId: kBleService, characteristicId: c, deviceId: deviceId);

  /// Connects and reads the board's INFO (id, firmware, whether it wants the pairing code or the
  /// home key, and this connection's random salt).
  Future<Map<String, dynamic>> connect() async {
    final ready = Completer<void>();
    _conn = _ble.connectToDevice(id: deviceId, connectionTimeout: const Duration(seconds: 12)).listen((u) {
      if (u.connectionState == DeviceConnectionState.connected && !ready.isCompleted) ready.complete();
      if (u.connectionState == DeviceConnectionState.disconnected && !ready.isCompleted) {
        ready.completeError(BleException('Could not connect to the board'));
      }
    }, onError: (Object e) {
      if (!ready.isCompleted) ready.completeError(BleException('Bluetooth error: $e'));
    });
    await ready.future.timeout(const Duration(seconds: 15), onTimeout: () => throw BleException('Connection timed out'));
    try {
      await _ble.requestMtu(deviceId: deviceId, mtu: 247);
    } catch (_) {
      // iOS negotiates by itself; the 120-byte frames fit anyway on any modern phone
    }
    _notif = _ble.subscribeToCharacteristic(_q(kBleTx)).listen(_onNotify);
    final raw = await _ble.readCharacteristic(_q(kBleInfo));
    info = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    return info;
  }

  void _onNotify(List<int> frame) {
    try {
      final msg = _asm.push(frame);
      if (msg != null && _waiting != null && !_waiting!.isCompleted) _waiting!.complete(msg);
    } on FormatException catch (e) {
      if (_waiting != null && !_waiting!.isCompleted) _waiting!.completeError(BleException(e.message));
    }
  }

  /// Chooses the secret from INFO: "pop" = the pairing code, "key" = the per-home Bluetooth key.
  Future<void> authenticate({String? pairingCode, String? homeKey}) async {
    final mode = info['mode'];
    final secret = mode == 'pop' ? pairingCode?.replaceAll(RegExp(r'[\s-]'), '').toUpperCase() : homeKey;
    if (secret == null || secret.isEmpty) {
      throw BleException(mode == 'pop'
          ? 'This board needs its pairing code (printed on the serial monitor, or hold BOOT for 3 s).'
          : 'This board belongs to another home or this app has lost the home key.');
    }
    final salt = base64Decode(info['salt'] as String);
    _key = await BleCrypto.deriveKey(secret, salt);
  }

  /// Sends one request and returns the decrypted JSON answer.
  Future<Map<String, dynamic>> request(Map<String, dynamic> body, {Duration timeout = const Duration(seconds: 10)}) async {
    final key = _key;
    if (key == null) throw BleException('Not authenticated');
    _ctr++;
    final msg = await BleCrypto.seal(key, _ctr, 'SHREQ', utf8.encode(jsonEncode(body)));
    _asm.reset();
    _waiting = Completer<Uint8List>();
    for (final f in toFrames(msg)) {
      await _ble.writeCharacteristicWithResponse(_q(kBleRx), value: f);
    }
    final answer = await _waiting!.future.timeout(timeout, onTimeout: () => throw BleException('The board did not answer'));
    if (answer.length == 2 && answer[0] == 0xEE) {
      throw BleException('Wrong pairing code or key (the board refused the message).');
    }
    final opened = await BleCrypto.open(key, answer, 'SHRSP');
    final json = jsonDecode(utf8.decode(opened.plain)) as Map<String, dynamic>;
    if (json['ok'] == 0) throw BleException((json['e'] ?? 'The board refused the request').toString());
    return json;
  }

  Future<void> close() async {
    await _notif?.cancel();
    await _conn?.cancel();
  }
}
