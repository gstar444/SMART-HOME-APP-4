import 'package:esp32_controller/models.dart';
import 'package:esp32_controller/pro/pro_settings.dart';
import 'package:esp32_controller/pro/rules_page.dart';
import 'package:esp32_controller/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('v4 firmware state', () {
    test('energy meter, node id and network status are parsed', () {
      final s = Esp32State.fromJson({
        'name': 'Home',
        'devices': [
          {'id': 'light', 'name': 'Light', 'type': 'switch', 'room': 0, 'on': true, 'watts': 12},
        ],
        'node': 'home-a1b2c3',
        'net': {'internet': true, 'mqtt': 'connected', 'emergency': false},
        'meter': {'type': 'pzem', 'ok': true, 'v': 231.4, 'a': 0.52, 'w': 118.0, 'kwh': 3.25},
        'meters': [
          {'room': 0, 'ok': true, 'v': 231.4, 'a': 0.3, 'w': 70.0, 'kwh': 2.0},
          {'room': 1, 'ok': true, 'v': 231.4, 'a': 0.22, 'w': 48.0, 'kwh': 1.25},
          {'room': 2, 'ok': false, 'v': null, 'a': null, 'w': null, 'kwh': 0.4},
        ],
      });
      expect(s.node, 'home-a1b2c3');
      expect(s.net['mqtt'], 'connected');
      expect(s.meter!.volts, closeTo(231.4, 0.01));
      expect(s.meters.length, 3);
      expect(s.meterForRoom(1)!.watts, 48.0);
      expect(s.meterForRoom(1)!.kwh, 1.25);
      expect(s.meterForRoom(2), isNull); // meter not answering -> estimate is used
      expect(s.meterForRoom(3), isNull);
      // optimistic updates keep the v4 fields
      expect(s.withDevice('light', on: false).meters.length, 3);
    });

    test('older firmware without the v4 fields still parses', () {
      final s = Esp32State.fromJson({'name': 'Old', 'devices': <dynamic>[]});
      expect(s.node, '');
      expect(s.meter, isNull);
      expect(s.meters, isEmpty);
    });
  });

  test('four rooms by default', () {
    expect(defaultRooms.length, 4);
  });

  test('pro settings round trip and reject an unknown cloud provider', () {
    const p = ProSettings(mqttHost: 'broker.example', mqttUser: 'u', mqttPass: 'p', cloudProvider: 'firebase',
        cloudUrl: 'https://x.firebaseio.com', cloudKey: 'k');
    final copy = ProSettings.fromJson(p.toJson());
    expect(copy.mqttHost, 'broker.example');
    expect(copy.mqttPort, 8883);
    expect(copy.mqttTls, isTrue);
    expect(copy.cloudReady, isTrue);
    expect(ProSettings.fromJson({'cloudProvider': 'evil'}).cloudProvider, 'off');
  });

  test('automation rules use the firmware JSON format', () {
    final r = AutoRule(id: 'r1', name: 'Hot', src: 'temp', op: '>', val: '30', actions: [
      {'id': 'fan', 'on': true},
    ], cool: 120);
    final j = r.toJson();
    expect(j['when'], {'src': 'temp', 'op': '>', 'val': 30});
    expect(j['do'], [
      {'id': 'fan', 'on': true},
    ]);
    final t = AutoRule(id: 'r2', src: 'time', val: '22:30').toJson();
    expect((t['when'] as Map)['val'], '22:30');
    final back = AutoRule.fromJson(j);
    expect(back.cool, 120);
    expect(back.describe(), contains('fan ON'));
  });
}
