import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/settings.dart';
import '../models/models.dart';
import '../services/firebase_rest.dart';
import '../services/lan_service.dart';
import '../services/mqtt_service.dart';

class HomeState {
  const HomeState({
    this.nodes = const {},
    this.mqtt = MqttState.disconnected,
    this.mqttError,
    this.lanOk = false,
    this.cacheLoaded = false,
    this.history = const {},
  });

  final Map<String, NodeInfo> nodes;
  final MqttState mqtt;
  final String? mqttError;
  final bool lanOk;
  final bool cacheLoaded;
  final Map<String, List<double>> history; // last watt readings per node, for the sparkline

  bool get cloudUp => mqtt == MqttState.connected;
  bool get anyLink => cloudUp || lanOk;

  List<NodeInfo> nodesInRoom(int room) =>
      (nodes.values.where((n) => n.room == room).toList()..sort((a, b) => a.title.compareTo(b.title)));

  HomeState copyWith({
    Map<String, NodeInfo>? nodes, MqttState? mqtt, String? mqttError, bool clearError = false,
    bool? lanOk, bool? cacheLoaded, Map<String, List<double>>? history,
  }) =>
      HomeState(
        nodes: nodes ?? this.nodes, mqtt: mqtt ?? this.mqtt,
        mqttError: clearError ? null : (mqttError ?? this.mqttError),
        lanOk: lanOk ?? this.lanOk, cacheLoaded: cacheLoaded ?? this.cacheLoaded, history: history ?? this.history,
      );
}

/// Owns the live picture of the house. Everything here is started LAZILY: the dashboard paints
/// immediately from the cache, then MQTT / LAN data replace it as it arrives.
class HomeController extends Notifier<HomeState> {
  MqttService? _mqtt;
  StreamSubscription<MqttIncoming>? _msgSub;
  StreamSubscription<MqttState>? _stSub;
  Timer? _lanTimer, _saveTimer, _retryTimer;
  final _events = StreamController<String>.broadcast();
  AppSettings? _cfg;
  int _lanTick = 0;

  Stream<String> get events => _events.stream;

  @override
  HomeState build() {
    ref.onDispose(() {
      _teardown();
      _lanTimer?.cancel();
      _saveTimer?.cancel();
      _events.close();
    });
    ref.listen<AsyncValue<AppSettings>>(settingsProvider, (prev, next) {
      final s = next.valueOrNull;
      if (s == null) return;
      final old = prev?.valueOrNull;
      _cfg = s;
      if (old == null || !old.sameConnection(s)) Future.microtask(() => _connect(s));
    }, fireImmediately: true);
    Future.microtask(_loadCache);
    return const HomeState();
  }

  // ------------------------------------------------------------------ cache (instant first paint)
  Future<void> _loadCache() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('nodesCache');
      if (raw != null && state.nodes.isEmpty) {
        final list = jsonDecode(raw) as List;
        final nodes = {
          for (final m in list)
            if (m is Map) (m['id'] as String): NodeInfo.fromCache(m),
        };
        state = state.copyWith(nodes: nodes, cacheLoaded: true);
        return;
      }
    } catch (_) {}
    state = state.copyWith(cacheLoaded: true);
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () async {
      final p = await SharedPreferences.getInstance();
      await p.setString('nodesCache', jsonEncode(state.nodes.values.map((n) => n.toJson()).toList()));
    });
  }

  // ------------------------------------------------------------------ connections
  Future<void> _teardown() async {
    _retryTimer?.cancel();
    await _msgSub?.cancel();
    await _stSub?.cancel();
    final m = _mqtt;
    _mqtt = null;
    await m?.dispose();
  }

  Future<void> _connect(AppSettings s) async {
    await _teardown();
    _startLanLoop();
    if (!s.mqttConfigured) {
      state = state.copyWith(mqtt: MqttState.disconnected, clearError: true);
      return;
    }
    final m = MqttService(host: s.mqttHost, port: s.mqttPort, user: s.mqttUser, pass: s.mqttPass, homeId: s.homeId);
    _mqtt = m;
    _msgSub = m.messages.listen(_onMessage);
    _stSub = m.states.listen((st) {
      state = state.copyWith(mqtt: st, mqttError: m.lastError, clearError: st == MqttState.connected);
      if (st == MqttState.connected) {
        _retryTimer?.cancel();
      } else if (st == MqttState.failed) {
        _retryTimer?.cancel();
        _retryTimer = Timer(const Duration(seconds: 10), () => _mqtt?.connect());
      }
    });
    state = state.copyWith(mqtt: MqttState.connecting, clearError: true);
    await m.connect();
  }

  void reconnect() {
    final s = _cfg;
    if (s != null) _connect(s);
  }

  // ------------------------------------------------------------------ MQTT -> state
  void _onMessage(MqttIncoming m) {
    final parts = m.topic.split('/');
    if (parts.length != 4 || parts[0] != 'sh') return;
    final nodeId = parts[2], leaf = parts[3];
    Map json;
    try {
      final d = jsonDecode(m.payload);
      if (d is! Map) return;
      json = d;
    } catch (_) {
      return; // an empty retained message (cleared topic) or garbage
    }
    if (leaf == 'evt') {
      _events.add(_describeEvent(state.nodes[nodeId]?.title ?? nodeId, json));
      return;
    }
    var n = state.nodes[nodeId] ?? NodeInfo(id: nodeId);
    var history = state.history;
    switch (leaf) {
      case 'status':
        n = n.withStatus(json);
        break;
      case 'meta':
        n = n.withMeta(json);
        break;
      case 'state':
        n = n.withState(json);
        final w = n.power?.w;
        if (w != null) {
          final h = [...(history[nodeId] ?? const <double>[]), w];
          history = {...history, nodeId: h.length > 60 ? h.sublist(h.length - 60) : h};
        }
        break;
      default:
        return;
    }
    state = state.copyWith(nodes: {...state.nodes, nodeId: n}, history: history);
    _scheduleSave();
  }

  String _describeEvent(String who, Map e) {
    switch (e['t']) {
      case 'overload':
        return '$who: overload - switched off "${e['id']}"';
      case 'rule':
        return '$who: automation "${e['id']}" ran';
      default:
        return '$who: ${e['t']}';
    }
  }

  // ------------------------------------------------------------------ LAN fallback
  void _startLanLoop() {
    _lanTimer?.cancel();
    _lanTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (state.cloudUp) {
        if (state.lanOk) state = state.copyWith(lanOk: false);
        return;
      }
      _lanTick++;
      _pollLan(discover: _lanTick % 12 == 1);
    });
  }

  Future<void> _pollLan({bool discover = false}) async {
    final key = _cfg?.apiKey ?? '';
    if (key.isEmpty) return;
    var ips = {for (final n in state.nodes.values) if (n.ip.isNotEmpty) n.id: n.ip};
    if (discover) {
      for (final f in await discoverLanNodes()) {
        if (f.home.isEmpty || f.home == _cfg?.homeId) ips[f.nodeId] = f.ip;
      }
    }
    var any = false;
    final nodes = {...state.nodes};
    for (final e in ips.entries) {
      final r = await LanClient(e.value, key).state();
      if (r == null) continue;
      any = true;
      var n = nodes[e.key] ?? NodeInfo(id: e.key);
      if (r['meta'] is Map) n = n.withMeta(r['meta'] as Map);
      if (r['state'] is Map) n = n.withState(r['state'] as Map);
      if (r['status'] is Map) n = n.withStatus(r['status'] as Map);
      nodes[e.key] = n.copyWith(ip: e.value);
    }
    if (any || state.lanOk) {
      state = state.copyWith(nodes: nodes, lanOk: any);
      if (any) _scheduleSave();
    }
  }

  Future<void> refresh() => _pollLan(discover: true);

  // ------------------------------------------------------------------ commands
  /// Cloud first (MQTT-TLS), home Wi-Fi second. Returns false when neither path worked.
  Future<bool> sendCmd(String nodeId, Map<String, dynamic> cmd) async {
    final body = {...cmd, 'src': 'app'};
    final m = _mqtt;
    if (m != null && m.isConnected && m.sendCmd(nodeId, body)) return true;
    final n = state.nodes[nodeId];
    final key = _cfg?.apiKey ?? '';
    if (n != null && n.ip.isNotEmpty && key.isNotEmpty) return LanClient(n.ip, key).cmd(body);
    return false;
  }

  void _put(NodeInfo n) => state = state.copyWith(nodes: {...state.nodes, n.id: n});

  Future<void> setDevice(String nodeId, String devId, bool on) async {
    final before = state.nodes[nodeId];
    if (before == null) return;
    _put(before.withDevice(devId, on)); // optimistic: the switch moves at once
    final ok = await sendCmd(nodeId, {'op': 'set', 'id': devId, 'on': on});
    if (!ok) {
      _put(before);
      _events.add('Cannot reach ${before.title}. Check Wi-Fi / internet, or use Bluetooth.');
    }
  }

  Future<void> runScene(String scene) async {
    final m = _mqtt;
    final body = {'op': 'scene', 'id': scene, 'src': 'app'};
    if (m != null && m.isConnected && m.publish('sh/${_cfg!.homeId}/all/cmd', jsonEncode(body))) return;
    for (final n in state.nodes.values) {
      await sendCmd(n.id, {'op': 'scene', 'id': scene});
    }
  }

  /// Send one command to every board: over the broker's "all" topic, or board by board on the LAN.
  Future<void> _broadcast(String op) async {
    final m = _mqtt;
    if (m != null && m.isConnected && m.publish('sh/${_cfg!.homeId}/all/cmd', jsonEncode({'op': op, 'src': 'app'}))) return;
    for (final n in state.nodes.values) {
      await sendCmd(n.id, {'op': op});
    }
  }

  /// Tell every board to pull its config + rules from Firebase now.
  Future<void> runSyncAll() => _broadcast('sync');

  /// Tell every board to look at the firmware manifest now (instead of waiting up to 6 hours).
  Future<void> runOtaAll() => _broadcast('ota');

  Future<bool> addDevice(String nodeId, Map<String, dynamic> dev) => sendCmd(nodeId, {'op': 'dev.add', ...dev});
  Future<bool> updateDevice(String nodeId, Map<String, dynamic> dev) => sendCmd(nodeId, {'op': 'dev.upd', ...dev});
  Future<bool> deleteDevice(String nodeId, String devId) => sendCmd(nodeId, {'op': 'dev.del', 'id': devId});
  Future<bool> setNode(String nodeId, Map<String, dynamic> fields) => sendCmd(nodeId, {'op': 'node.set', ...fields});

  void forget(String nodeId) {
    state = state.copyWith(nodes: {...state.nodes}..remove(nodeId));
    _scheduleSave();
  }
}

final homeProvider = NotifierProvider<HomeController, HomeState>(HomeController.new);

final homeEventsProvider = StreamProvider<String>((ref) => ref.read(homeProvider.notifier).events);

/// Firebase REST client built from the runtime settings; null until the cloud DB is configured.
final firebaseProvider = Provider<FirebaseRest?>((ref) {
  final s = ref.watch(settingsProvider).valueOrNull;
  if (s == null || !s.cloudConfigured) return null;
  return FirebaseRest(apiKey: s.fbApiKey, dbUrl: s.fbDbUrl, email: s.fbUserEmail, password: s.fbUserPass);
});
