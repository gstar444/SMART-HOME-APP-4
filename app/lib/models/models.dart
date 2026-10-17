/// Data classes shared by the whole app. Plain immutable objects; the JSON shapes match the
/// firmware (publish.h / devices.h / rules.h).

double? _d(Object? v) => v is num ? v.toDouble() : null;
int _i(Object? v, [int def = 0]) => v is num ? v.toInt() : def;
bool _b(Object? v) => v == true || v == 1;
String _s(Object? v, [String def = '']) => v is String ? v : def;

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    this.type = 'switch',
    this.icon = 'plug',
    this.on = false,
    this.pin = -1,
    this.watts = 0,
    this.autoOffMin = 0,
    this.invert = false,
    this.persist = false,
    this.sinricId = '',
  });

  final String id, name, type, icon, sinricId;
  final bool on, invert, persist;
  final int pin, watts, autoOffMin;

  bool get isLock => type == 'lock';
  bool get isPir => type == 'pir';
  bool get controllable => !isPir;

  DeviceInfo copyWith({bool? on}) => DeviceInfo(
        id: id, name: name, type: type, icon: icon, on: on ?? this.on, pin: pin, watts: watts,
        autoOffMin: autoOffMin, invert: invert, persist: persist, sinricId: sinricId,
      );

  factory DeviceInfo.fromMeta(Map m, {bool on = false}) => DeviceInfo(
        id: _s(m['id']),
        name: _s(m['name'], _s(m['id'])),
        type: _s(m['type'], 'switch'),
        icon: _s(m['icon'], 'plug'),
        on: on,
        pin: _i(m['pin'], -1),
        watts: _i(m['w']),
        autoOffMin: _i(m['ao']),
        invert: _b(m['inv']),
        persist: _b(m['per']),
        sinricId: _s(m['sin']),
      );

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'type': type, 'icon': icon, 'on': on ? 1 : 0, 'pin': pin,
        'w': watts, 'ao': autoOffMin, 'inv': invert ? 1 : 0, 'per': persist ? 1 : 0, 'sin': sinricId,
      };
}

class PowerStats {
  const PowerStats({this.v, this.i, this.w, this.pf, this.hz, this.kwh = 0, this.kwhToday = 0, this.src = 'est'});
  final double? v, i, w, pf, hz;
  final double kwh, kwhToday;
  final String src; // pzem | acs | est

  bool get estimated => src == 'est';

  factory PowerStats.fromJson(Map m) => PowerStats(
        v: _d(m['v']), i: _d(m['i']), w: _d(m['w']), pf: _d(m['pf']), hz: _d(m['hz']),
        kwh: _d(m['kwh']) ?? 0, kwhToday: _d(m['kd']) ?? 0, src: _s(m['src'], 'est'),
      );

  Map<String, dynamic> toJson() => {'v': v, 'i': i, 'w': w, 'pf': pf, 'hz': hz, 'kwh': kwh, 'kd': kwhToday, 'src': src};
}

/// One ESP32 = one room. Built up from three retained MQTT topics: status, meta and state.
class NodeInfo {
  const NodeInfo({
    required this.id,
    this.name = '',
    this.room = 0,
    this.roomName = '',
    this.hub = false,
    this.online = false,
    this.fw = '',
    this.ip = '',
    this.rssi = 0,
    this.mode = 'online',
    this.powerSensor = 0,
    this.devices = const [],
    this.temp,
    this.hum,
    this.power,
    this.dnd = false,
    this.pinsOut = const [],
    this.pinsIn = const [],
    this.rev = 0,
    this.lastSeen,
  });

  final String id, name, roomName, fw, ip, mode;
  final int room, rssi, powerSensor, rev;
  final bool hub, online, dnd;
  final List<DeviceInfo> devices;
  final double? temp, hum;
  final PowerStats? power;
  final List<int> pinsOut, pinsIn;
  final DateTime? lastSeen;

  String get title => name.isNotEmpty ? name : id;
  bool get hasPower => power != null;
  List<DeviceInfo> get switches => devices.where((d) => !d.isPir).toList();

  NodeInfo copyWith({
    String? name, int? room, String? roomName, bool? hub, bool? online, String? fw, String? ip, int? rssi,
    String? mode, int? powerSensor, List<DeviceInfo>? devices, double? temp, double? hum, PowerStats? power,
    bool? dnd, List<int>? pinsOut, List<int>? pinsIn, int? rev, DateTime? lastSeen,
  }) =>
      NodeInfo(
        id: id, name: name ?? this.name, room: room ?? this.room, roomName: roomName ?? this.roomName,
        hub: hub ?? this.hub, online: online ?? this.online, fw: fw ?? this.fw, ip: ip ?? this.ip,
        rssi: rssi ?? this.rssi, mode: mode ?? this.mode, powerSensor: powerSensor ?? this.powerSensor,
        devices: devices ?? this.devices, temp: temp ?? this.temp, hum: hum ?? this.hum, power: power ?? this.power,
        dnd: dnd ?? this.dnd, pinsOut: pinsOut ?? this.pinsOut, pinsIn: pinsIn ?? this.pinsIn, rev: rev ?? this.rev,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  /// <node>/status  {"online":true,"fw":..,"ip":..,"rssi":..,"lm":..,"name":..,"room":..,"hub":..}
  NodeInfo withStatus(Map m) {
    final on = _b(m['online']);
    return copyWith(
      online: on,
      fw: m.containsKey('fw') ? _s(m['fw']) : null,
      ip: m.containsKey('ip') ? _s(m['ip']) : null,
      rssi: m.containsKey('rssi') ? _i(m['rssi']) : null,
      mode: m.containsKey('lm') ? _s(m['lm'], 'online') : null,
      name: m.containsKey('name') ? _s(m['name']) : null,
      room: m.containsKey('room') ? _i(m['room']) : null,
      hub: m.containsKey('hub') ? _b(m['hub']) : null,
      powerSensor: m.containsKey('ps') ? _i(m['ps']) : null,
      lastSeen: on ? DateTime.now() : null,
    );
  }

  /// <node>/meta  {"rev":..,"name":..,"room":..,"rn":..,"hub":..,"devices":[...],"pinsOut":[..],"pinsIn":[..]}
  NodeInfo withMeta(Map m) {
    final onById = {for (final d in devices) d.id: d.on};
    final list = <DeviceInfo>[
      for (final d in (m['devices'] as List? ?? const []))
        if (d is Map) DeviceInfo.fromMeta(d, on: onById[_s(d['id'])] ?? false),
    ];
    return copyWith(
      name: _s(m['name'], name),
      room: _i(m['room'], room),
      roomName: _s(m['rn'], roomName),
      hub: _b(m['hub']),
      fw: m.containsKey('fw') ? _s(m['fw']) : null,
      powerSensor: m.containsKey('ps') ? _i(m['ps']) : null,
      devices: list,
      pinsOut: m['pinsOut'] is List ? [for (final p in m['pinsOut'] as List) _i(p)] : null,
      pinsIn: m['pinsIn'] is List ? [for (final p in m['pinsIn'] as List) _i(p)] : null,
      rev: _i(m['rev'], rev),
    );
  }

  /// <node>/state  {"d":{"light":1},"t":23.5,"h":55,"p":{...},"dnd":0}
  NodeInfo withState(Map m) {
    final flags = m['d'] is Map ? m['d'] as Map : const {};
    final updated = [for (final d in devices) flags.containsKey(d.id) ? d.copyWith(on: _b(flags[d.id])) : d];
    return copyWith(
      devices: updated,
      temp: _d(m['t']),
      hum: _d(m['h']),
      power: m['p'] is Map ? PowerStats.fromJson(m['p'] as Map) : null,
      dnd: _b(m['dnd']),
      lastSeen: DateTime.now(),
    );
  }

  /// Optimistic update while a command is on its way.
  NodeInfo withDevice(String devId, bool on) =>
      copyWith(devices: [for (final d in devices) d.id == devId ? d.copyWith(on: on) : d]);

  // ---- cache so the dashboard can paint instantly on the next cold start
  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'room': room, 'rn': roomName, 'hub': hub ? 1 : 0, 'fw': fw, 'ip': ip,
        'ps': powerSensor, 'rev': rev, 'devices': devices.map((d) => d.toJson()).toList(),
        'pinsOut': pinsOut, 'pinsIn': pinsIn, 't': temp, 'h': hum, 'p': power?.toJson(),
      };

  factory NodeInfo.fromCache(Map m) {
    final n = NodeInfo(id: _s(m['id'])).withMeta({...m, 'devices': m['devices']});
    final flags = {for (final d in (m['devices'] as List? ?? const [])) if (d is Map) _s(d['id']): d['on']};
    return n.copyWith(ip: _s(m['ip']), online: false).withState({'d': flags, 't': m['t'], 'h': m['h'], 'p': m['p']}).copyWith(online: false);
  }
}

// ======================================================================= automation rules

class RuleAction {
  const RuleAction({this.node = '', this.dev = '', this.scene = '', this.on = true, this.forSec = 0});
  final String node, dev, scene;
  final bool on;
  final int forSec;

  RuleAction inverse() => RuleAction(node: node, dev: dev, scene: scene, on: !on);

  Map<String, dynamic> toJson() => {
        if (node.isNotEmpty) 'node': node,
        if (dev.isNotEmpty) 'id': dev,
        if (scene.isNotEmpty) 'scene': scene,
        'on': on ? 1 : 0,
        if (forSec > 0) 'for': forSec,
      };

  factory RuleAction.fromJson(Map m) => RuleAction(
        node: _s(m['node']), dev: _s(m['id']), scene: _s(m['scene']), on: _b(m['on']), forSec: _i(m['for']),
      );
}

class RuleModel {
  RuleModel({
    required this.id,
    this.name = '',
    this.enabled = true,
    this.node = '',
    this.cType = 'time',
    this.op = '>',
    this.value = 0,
    this.hyst = 1,
    this.at = '18:30',
    this.cDev = '',
    this.days = 127,
    this.from,
    this.to,
    this.then = const [],
    this.revert = true,
    this.otherwise = const [],
  });

  String id, name, node, cType, op, at, cDev;
  bool enabled, revert;
  double value, hyst;
  int days; // bit0 = Sunday ... bit6 = Saturday
  String? from, to;
  List<RuleAction> then, otherwise;

  static const condTypes = ['time', 'temp', 'hum', 'power', 'motion', 'dev'];

  List<RuleAction> get elseActions => revert ? then.map((a) => a.scene.isNotEmpty ? null : a.inverse()).whereType<RuleAction>().toList() : otherwise;

  /// Exactly the JSON the firmware's parseRule() reads.
  Map<String, dynamic> toJson() => {
        'id': id, 'n': name, 'en': enabled ? 1 : 0, 'node': node,
        'c': {
          't': cType,
          if (cType == 'time') 'at': at,
          if (cType == 'temp' || cType == 'hum' || cType == 'power') ...{'op': op, 'v': value, 'h': hyst},
          if (cType == 'motion' || cType == 'dev') 'dev': cDev,
          if (cType == 'dev') 'v': value > 0.5 ? 1 : 0,
        },
        'days': days,
        if (from != null && to != null) 'w': [from, to],
        'then': then.map((a) => a.toJson()).toList(),
        'else': elseActions.map((a) => a.toJson()).toList(),
        'rv': revert ? 1 : 0,
      };

  factory RuleModel.fromJson(String id, Map m) {
    final c = m['c'] is Map ? m['c'] as Map : const {};
    final w = m['w'] is List && (m['w'] as List).length == 2 ? m['w'] as List : null;
    final then = [for (final a in (m['then'] as List? ?? const [])) if (a is Map) RuleAction.fromJson(a)];
    final other = [for (final a in (m['else'] as List? ?? const [])) if (a is Map) RuleAction.fromJson(a)];
    return RuleModel(
      id: _s(m['id'], id), name: _s(m['n']), enabled: m['en'] == null ? true : _b(m['en']), node: _s(m['node']),
      cType: _s(c['t'], 'time'), op: _s(c['op'], '>'), value: _d(c['v']) ?? 0, hyst: _d(c['h']) ?? 1,
      at: _s(c['at'], '18:30'), cDev: _s(c['dev']), days: _i(m['days'], 127),
      from: w == null ? null : _s(w[0]), to: w == null ? null : _s(w[1]),
      then: then, revert: _b(m['rv']), otherwise: other,
    );
  }

  String describe() {
    switch (cType) {
      case 'time':
        return 'At $at';
      case 'temp':
        return 'Temperature $op ${value.toStringAsFixed(0)} °C';
      case 'hum':
        return 'Humidity $op ${value.toStringAsFixed(0)} %';
      case 'power':
        return 'Power $op ${value.toStringAsFixed(0)} W';
      case 'motion':
        return 'Motion on $cDev';
      default:
        return '$cDev is ${value > 0.5 ? 'on' : 'off'}';
    }
  }
}
