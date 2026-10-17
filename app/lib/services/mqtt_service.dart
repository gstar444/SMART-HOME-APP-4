import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttIncoming {
  const MqttIncoming(this.topic, this.payload);
  final String topic, payload;
}

enum MqttState { disconnected, connecting, connected, failed }

/// Secure MQTT client: TLS (certificate checked against the phone's trusted roots) + username /
/// password. The broker address, credentials and home id all come from the runtime settings.
///
/// Topics (see firmware/publish.h):  sh/<home>/<node>/{status,meta,state,evt,cmd}   sh/<home>/all/cmd
class MqttService {
  MqttService({required this.host, required this.port, required this.user, required this.pass, required this.homeId});

  final String host, user, pass, homeId;
  final int port;

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _sub;
  final _incoming = StreamController<MqttIncoming>.broadcast();
  final _state = StreamController<MqttState>.broadcast();
  MqttState current = MqttState.disconnected;
  String? lastError;

  Stream<MqttIncoming> get messages => _incoming.stream;
  Stream<MqttState> get states => _state.stream;
  bool get isConnected => current == MqttState.connected;

  void _set(MqttState s) {
    current = s;
    if (!_state.isClosed) _state.add(s);
  }

  Future<void> connect() async {
    if (current == MqttState.connecting || current == MqttState.connected) return;
    _set(MqttState.connecting);
    lastError = null;
    final short = homeId.length < 6 ? homeId : homeId.substring(0, 6);
    final clientId = 'app-$short-${DateTime.now().millisecondsSinceEpoch % 100000}';
    final c = MqttServerClient.withPort(host, clientId, port)
      ..secure = true
      ..securityContext = SecurityContext.defaultContext
      ..keepAlivePeriod = 30
      ..connectTimeoutPeriod = 8000
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..logging(on: false);
    c.onConnected = () => _set(MqttState.connected);
    c.onAutoReconnect = () => _set(MqttState.connecting);
    c.onAutoReconnected = () => _set(MqttState.connected);
    c.onDisconnected = () {
      if (current != MqttState.failed) _set(MqttState.disconnected);
    };
    c.connectionMessage = MqttConnectMessage().withClientIdentifier(clientId).startClean();
    _client = c;
    try {
      await c.connect(user.isEmpty ? null : user, pass.isEmpty ? null : pass);
    } on Exception catch (e) {
      lastError = e.toString();
      c.disconnect();
      _set(MqttState.failed);
      return;
    }
    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      lastError = 'Broker refused the connection (${c.connectionStatus?.returnCode})';
      c.disconnect();
      _set(MqttState.failed);
      return;
    }
    _sub = c.updates?.listen(_onData);
    for (final leaf in const ['status', 'meta', 'state', 'evt']) {
      c.subscribe('sh/$homeId/+/$leaf', MqttQos.atLeastOnce);
    }
    _set(MqttState.connected);
  }

  void _onData(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final e in events) {
      final msg = e.payload;
      if (msg is! MqttPublishMessage) continue;
      // utf8.decode, NOT bytesToStringAsString: Hindi device names are multi-byte
      final text = utf8.decode(msg.payload.message.toList(), allowMalformed: true);
      _incoming.add(MqttIncoming(e.topic, text));
    }
  }

  /// Fire-and-forget. Returns false when there is no broker connection.
  bool publish(String topic, String payload, {bool retain = false}) {
    final c = _client;
    if (c == null || !isConnected) return false;
    final b = MqttClientPayloadBuilder()..addUTF8String(payload);
    c.publishMessage(topic, MqttQos.atLeastOnce, b.payload!, retain: retain);
    return true;
  }

  bool sendCmd(String node, Map<String, dynamic> cmd) => publish('sh/$homeId/$node/cmd', jsonEncode(cmd));

  Future<void> dispose() async {
    await _sub?.cancel();
    _client?.autoReconnect = false;
    _client?.disconnect();
    await _incoming.close();
    await _state.close();
  }
}
