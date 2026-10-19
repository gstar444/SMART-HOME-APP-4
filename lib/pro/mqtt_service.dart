/// Remote control over the internet through the same secure MQTT broker the
/// boards use (TLS + username/password). Used when the phone is away from home
/// and the board cannot be reached over the local network.
///
/// Topics (see firmware mqtt_link.h):
/// `<base>/<node>/state      retained full state JSON  (subscribed)`
/// `<base>/<node>/<dev>/set  "ON" / "OFF"              (published)`
/// `<base>/<node>/cmd        command JSON              (published)`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'pro_settings.dart';

class MqttService extends ChangeNotifier {
  MqttService._();
  static final MqttService instance = MqttService._();

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _sub;
  ProSettings? _cfg;
  String status = 'off';

  /// node id -> latest state JSON published by that board.
  final Map<String, Map<String, dynamic>> boards = <String, Map<String, dynamic>>{};

  bool get connected => _client?.connectionStatus?.state == MqttConnectionState.connected;

  Future<String?> connect(ProSettings cfg) async {
    await disconnect();
    if (!cfg.mqttReady) return 'Broker not set';
    _cfg = cfg;
    final id = 'app-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final c = MqttServerClient.withPort(cfg.mqttHost, id, cfg.mqttPort)
      ..secure = cfg.mqttTls
      ..keepAlivePeriod = 30
      ..autoReconnect = true
      ..logging(on: false)
      ..connectTimeoutPeriod = 8000;
    if (cfg.mqttTls) c.securityContext = SecurityContext.defaultContext;
    c.connectionMessage = MqttConnectMessage().withClientIdentifier(id).startClean();
    c.onDisconnected = () {
      status = 'offline';
      notifyListeners();
    };
    c.onConnected = () {
      status = 'connected';
      notifyListeners();
    };
    _client = c;
    status = 'connecting';
    notifyListeners();
    try {
      await c.connect(
        cfg.mqttUser.isEmpty ? null : cfg.mqttUser,
        cfg.mqttPass.isEmpty ? null : cfg.mqttPass,
      );
    } catch (e) {
      status = 'error';
      notifyListeners();
      c.disconnect();
      return 'MQTT: $e';
    }
    if (!connected) {
      status = 'refused';
      notifyListeners();
      return 'MQTT: connection refused (check user/password)';
    }
    c.subscribe('${cfg.mqttBase}/+/state', MqttQos.atLeastOnce);
    _sub = c.updates?.listen(_onMessages);
    status = 'connected';
    notifyListeners();
    return null;
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> list) {
    final base = _cfg?.mqttBase ?? '';
    for (final m in list) {
      final msg = m.payload;
      if (msg is! MqttPublishMessage) continue;
      final parts = m.topic.split('/');
      if (parts.length != 3 || parts[0] != base || parts[2] != 'state') continue;
      try {
        final text = utf8.decode(msg.payload.message.toList(), allowMalformed: true);
        final json = jsonDecode(text);
        if (json is Map<String, dynamic>) boards[parts[1]] = json;
      } catch (_) {}
    }
    notifyListeners();
  }

  bool _publish(String topic, String payload) {
    final c = _client;
    if (c == null || !connected) return false;
    final b = MqttClientPayloadBuilder()..addUTF8String(payload);
    c.publishMessage(topic, MqttQos.atLeastOnce, b.payload!);
    return true;
  }

  bool setDevice(String node, String id, bool on) =>
      _publish('${_cfg!.mqttBase}/$node/$id/set', on ? 'ON' : 'OFF');

  bool command(String node, Map<String, dynamic> cmd) =>
      _publish('${_cfg!.mqttBase}/$node/cmd', jsonEncode(cmd));

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    _client?.disconnect();
    _client = null;
    status = 'off';
  }
}
