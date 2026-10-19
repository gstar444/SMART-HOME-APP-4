/// Data classes for the JSON that the ESP32 firmware returns.

double? _num(Object? v) => v is num ? v.toDouble() : null;
int? _int(Object? v) => v is num ? v.toInt() : null;

/// GPIO pins offered when an older firmware does not report its own list.
const List<int> defaultOutPins = <int>[
  5, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33,
];
const List<int> defaultInPins = <int>[34, 35, 36, 39];

List<int> _intList(Object? v, List<int> fallback) {
  if (v is! List) return fallback;
  return <int>[
    for (final item in v)
      if (item is num) item.toInt(),
  ];
}

class Esp32Device {
  const Esp32Device({
    required this.id,
    required this.name,
    required this.type,
    required this.group,
    required this.icon,
    required this.room,
    required this.on,
    this.watts = 0,
    this.wh = 0,
    this.pin = -1,
  });

  final String id;
  final String name;

  /// "switch" (relay), "lock" (on = locked) or "pir" (on = motion, read-only).
  final String type;
  final String group;
  final String icon;
  final int room;
  final bool on;
  final double watts; // typical load, used for the energy estimate
  final double wh; // energy used since the ESP32 booted
  final int pin; // GPIO pin, -1 = unknown (old firmware)

  bool get isLock => type == 'lock';
  bool get isSwitch => type == 'switch';
  bool get controllable => type == 'switch' || type == 'lock';

  Esp32Device copyWith({bool? on}) => Esp32Device(
        id: id,
        name: name,
        type: type,
        group: group,
        icon: icon,
        room: room,
        on: on ?? this.on,
        watts: watts,
        wh: wh,
        pin: pin,
      );

  factory Esp32Device.fromJson(Map<String, dynamic> j) => Esp32Device(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? (j['id'] as String?) ?? 'Device',
        type: (j['type'] as String?) ?? 'switch',
        group: (j['group'] as String?) ?? 'Other',
        icon: (j['icon'] as String?) ?? 'plug',
        room: _int(j['room']) ?? 0,
        on: j['on'] == true || j['on'] == 1,
        watts: _num(j['watts']) ?? 0,
        wh: _num(j['wh']) ?? 0,
        pin: _int(j['pin']) ?? -1,
      );
}

class Esp32State {
  const Esp32State({
    required this.name,
    required this.fw,
    required this.ssid,
    required this.ip,
    required this.rssi,
    required this.uptime,
    required this.temp,
    required this.hum,
    required this.dnd,
    required this.camera,
    required this.powerW,
    required this.devices,
    this.mode = 'sta',
    this.apSsid = '',
    this.pinsOut = defaultOutPins,
    this.pinsIn = defaultInPins,
    this.maxDevices = 24,
    this.node = '',
    this.net = const <String, dynamic>{},
    this.meter,
    this.meters = const <PowerMeter>[],
  });

  final String name;
  final String fw;
  final String ssid; // Wi-Fi the ESP32 has joined ('' = none)
  final String ip;
  final int rssi;
  final int uptime; // seconds
  final double? temp; // null = no sensor / read failed
  final double? hum;
  final bool dnd;
  final String camera; // stream URL, empty = not configured
  final double powerW;
  final List<Esp32Device> devices;

  /// "sta" (joined a router), "ap" (setup hotspot only), "ap+sta" or "offline".
  final String mode;
  final String apSsid; // name of the setup hotspot while it is on
  final List<int> pinsOut; // GPIO pins a relay can use
  final List<int> pinsIn; // extra input-only pins (PIR sensors)
  final int maxDevices;

  // ---- v4 firmware extras (empty / null with older firmware)
  final String node; // board id used in MQTT / cloud paths
  final Map<String, dynamic> net; // internet, mqtt, cloud, telegram, voice, ble, emergency
  final PowerMeter? meter; // whole-board totals from a real energy meter
  final List<PowerMeter> meters; // one per room/channel

  /// Measured values of [room], or null when no meter covers that room.
  PowerMeter? meterForRoom(int room) {
    final list = [for (final m in meters) if (m.room == room && m.ok) m];
    if (list.isEmpty) return null;
    return PowerMeter(
      room: room,
      ok: true,
      volts: list.first.volts,
      amps: list.fold<double>(0, (s, m) => s + (m.amps ?? 0)),
      watts: list.fold<double>(0, (s, m) => s + (m.watts ?? 0)),
      kwh: list.fold<double>(0, (s, m) => s + m.kwh),
    );
  }

  bool get wifiConnected => mode == 'sta' || mode == 'ap+sta';
  bool get apActive => mode == 'ap' || mode == 'ap+sta';

  Esp32State withDevice(String id, {required bool on}) => _copy(
        devices: [for (final d in devices) d.id == id ? d.copyWith(on: on) : d],
      );

  Esp32State withDnd(bool value) => _copy(dnd: value);

  Esp32State _copy({bool? dnd, List<Esp32Device>? devices}) => Esp32State(
        name: name,
        fw: fw,
        ssid: ssid,
        ip: ip,
        rssi: rssi,
        uptime: uptime,
        temp: temp,
        hum: hum,
        dnd: dnd ?? this.dnd,
        camera: camera,
        powerW: powerW,
        devices: devices ?? this.devices,
        mode: mode,
        apSsid: apSsid,
        pinsOut: pinsOut,
        pinsIn: pinsIn,
        maxDevices: maxDevices,
        node: node,
        net: net,
        meter: meter,
        meters: meters,
      );

  factory Esp32State.fromJson(Map<String, dynamic> j) {
    final raw = j['devices'];
    final list = <Esp32Device>[
      if (raw is List)
        for (final item in raw)
          if (item is Map) Esp32Device.fromJson(Map<String, dynamic>.from(item)),
    ].where((d) => d.id.isNotEmpty).toList();
    return Esp32State(
      name: (j['name'] as String?) ?? 'ESP32',
      fw: (j['fw'] as String?) ?? '',
      ssid: (j['ssid'] as String?) ?? '',
      ip: (j['ip'] as String?) ?? '',
      rssi: _int(j['rssi']) ?? 0,
      uptime: _int(j['uptime']) ?? 0,
      temp: _num(j['temp']),
      hum: _num(j['hum']),
      dnd: j['dnd'] == true,
      camera: (j['camera'] as String?) ?? '',
      powerW: _num(j['powerW']) ?? 0,
      devices: list,
      mode: (j['mode'] as String?) ?? 'sta',
      apSsid: (j['apSsid'] as String?) ?? '',
      pinsOut: _intList(j['pinsOut'], defaultOutPins),
      pinsIn: _intList(j['pinsIn'], defaultInPins),
      maxDevices: _int(j['maxDevices']) ?? 24,
      node: (j['node'] as String?) ?? '',
      net: j['net'] is Map ? Map<String, dynamic>.from(j['net'] as Map) : const <String, dynamic>{},
      meter: j['meter'] is Map ? PowerMeter.fromJson(Map<String, dynamic>.from(j['meter'] as Map)) : null,
      meters: [
        if (j['meters'] is List)
          for (final m in j['meters'] as List)
            if (m is Map) PowerMeter.fromJson(Map<String, dynamic>.from(m)),
      ],
    );
  }
}

/// Reading of a PZEM-004T / ACS712 energy meter (firmware power_meter.h).
class PowerMeter {
  const PowerMeter({
    this.room = 0,
    this.ok = false,
    this.volts,
    this.amps,
    this.watts,
    this.kwh = 0,
    this.hz,
    this.pf,
  });

  final int room;
  final bool ok;
  final double? volts;
  final double? amps;
  final double? watts;
  final double kwh;
  final double? hz;
  final double? pf;

  factory PowerMeter.fromJson(Map<String, dynamic> j) => PowerMeter(
        room: _int(j['room']) ?? 0,
        ok: j['ok'] == true,
        volts: _num(j['v']),
        amps: _num(j['a']),
        watts: _num(j['w']),
        kwh: _num(j['kwh']) ?? 0,
        hz: _num(j['hz']),
        pf: _num(j['pf']),
      );
}

/// One Wi-Fi network found by the ESP32 scan.
class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.secure,
  });

  final String ssid;
  final int rssi; // dBm, closer to 0 = stronger
  final bool secure; // needs a password

  factory WifiNetwork.fromJson(Map<String, dynamic> j) => WifiNetwork(
        ssid: (j['ssid'] as String?) ?? '',
        rssi: _int(j['rssi']) ?? -100,
        secure: j['secure'] != false,
      );
}

/// Answer of GET /api/wifi/scan. The ESP32 scans in the background, so the
/// app asks again until [scanning] becomes false.
class WifiScan {
  const WifiScan({required this.scanning, required this.networks});

  final bool scanning;
  final List<WifiNetwork> networks;

  factory WifiScan.fromJson(Map<String, dynamic> j) {
    final raw = j['networks'];
    final list = <WifiNetwork>[
      if (raw is List)
        for (final item in raw)
          if (item is Map) WifiNetwork.fromJson(Map<String, dynamic>.from(item)),
    ].where((n) => n.ssid.isNotEmpty).toList();
    return WifiScan(scanning: j['scanning'] == true, networks: list);
  }
}

/// Answer of GET /api/wifi/status.
class WifiStatus {
  const WifiStatus({
    required this.state,
    required this.connected,
    required this.ssid,
    required this.ip,
    required this.rssi,
    required this.mode,
    required this.apSsid,
    required this.target,
    required this.error,
    required this.saved,
  });

  /// "idle", "trying" (joining a new network) or "failed" (last attempt failed).
  final String state;
  final bool connected;
  final String ssid;
  final String ip;
  final int rssi;
  final String mode;
  final String apSsid;
  final String target; // network being joined while state == "trying"
  final String error;
  final bool saved; // a Wi-Fi is saved in the ESP32's flash

  factory WifiStatus.fromJson(Map<String, dynamic> j) => WifiStatus(
        state: (j['state'] as String?) ?? 'idle',
        connected: j['connected'] == true,
        ssid: (j['ssid'] as String?) ?? '',
        ip: (j['ip'] as String?) ?? '',
        rssi: _int(j['rssi']) ?? 0,
        mode: (j['mode'] as String?) ?? 'sta',
        apSsid: (j['apSsid'] as String?) ?? '',
        target: (j['target'] as String?) ?? '',
        error: (j['error'] as String?) ?? '',
        saved: j['saved'] == true,
      );
}
