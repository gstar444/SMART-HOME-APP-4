import 'package:esp32_controller/models/models.dart';
import 'package:esp32_controller/voice.dart';
import 'package:flutter_test/flutter_test.dart';

NodeInfo _node(String id, int room, List<Map<String, Object>> devs) =>
    NodeInfo(id: id).withMeta({'name': 'Board $id', 'room': room, 'rn': 'Room ${room + 1}', 'devices': devs});

void main() {
  group('NodeInfo', () {
    test('meta + state build the picture; offline LWT keeps the data', () {
      var n = NodeInfo(id: 'n1').withMeta({
        'name': 'Hall', 'room': 1, 'rn': 'Hall', 'rev': 3,
        'devices': [
          {'id': 'd1', 'name': 'Light', 'icon': 'light', 'type': 'switch', 'pin': 23, 'w': 12},
          {'id': 'd2', 'name': 'Motion', 'icon': 'pir', 'type': 'pir', 'pin': 34},
        ],
      }).withState({'d': {'d1': 1, 'd2': 0}, 't': 23.5, 'h': 55, 'p': {'w': 120.5, 'kd': 1.25, 'kwh': 8.0, 'src': 'pzem'}});
      expect(n.room, 1);
      expect(n.devices.first.on, true);
      expect(n.devices.last.isPir, true);
      expect(n.power!.w, 120.5);
      expect(n.power!.estimated, false);
      n = n.withStatus({'online': true, 'fw': '5.0.0', 'lm': 'lan'});
      expect(n.online, true);
      expect(n.mode, 'lan');
      n = n.withStatus({'online': false});
      expect(n.online, false);
      expect(n.devices.length, 2); // data survives the "offline" message
    });

    test('a fresh meta message keeps the live on/off flags', () {
      var n = _node('n1', 0, [{'id': 'd1', 'name': 'Light', 'icon': 'light'}]).withState({'d': {'d1': 1}});
      n = n.withMeta({'devices': [{'id': 'd1', 'name': 'Lamp', 'icon': 'light'}]});
      expect(n.devices.single.name, 'Lamp');
      expect(n.devices.single.on, true);
    });

    test('cache round trip', () {
      final n = _node('n1', 2, [{'id': 'd1', 'name': 'Fan', 'icon': 'fan'}]).withState({'d': {'d1': 1}, 't': 30.0});
      final back = NodeInfo.fromCache(n.toJson());
      expect(back.id, 'n1');
      expect(back.room, 2);
      expect(back.devices.single.on, true);
      expect(back.online, false); // cached data is never shown as live
    });
  });

  group('RuleModel (JSON the firmware reads)', () {
    test('temperature rule with automatic revert', () {
      final r = RuleModel(id: 'r1', name: 'Fan when hot', node: 'n1', cType: 'temp', op: '>', value: 30, hyst: 1, then: [const RuleAction(dev: 'fan', on: true)]);
      final j = r.toJson();
      expect((j['c'] as Map)['t'], 'temp');
      expect((j['c'] as Map)['v'], 30);
      expect(((j['then'] as List).first as Map)['id'], 'fan');
      expect(((j['else'] as List).first as Map)['on'], 0); // inverse of "then"
      final back = RuleModel.fromJson('r1', j);
      expect(back.revert, true);
      expect(back.value, 30);
      expect(back.then.single.dev, 'fan');
    });

    test('time rule with window and days; scene actions are never inverted', () {
      final r = RuleModel(id: 'r2', node: 'n1', cType: 'time', at: '22:30', days: 62, from: '22:00', to: '06:00', then: [const RuleAction(scene: 'alloff')]);
      final j = r.toJson();
      expect((j['c'] as Map)['at'], '22:30');
      expect(j['days'], 62);
      expect(j['w'], ['22:00', '06:00']);
      expect(j['else'], isEmpty);
    });
  });

  group('voice', () {
    final n1 = _node('n1', 0, [{'id': 'd1', 'name': 'Light', 'icon': 'light'}, {'id': 'd9', 'name': 'Front door', 'icon': 'lock', 'type': 'lock'}]);
    final n2 = _node('n2', 1, [{'id': 'd2', 'name': 'Light', 'icon': 'light'}, {'id': 'd3', 'name': 'Fan', 'icon': 'fan'}]);
    final nodes = [n1, n2];
    const rooms = ['Room 1', 'Room 2', 'Room 3', 'Room 4'];

    test('no room named: only the room on screen', () {
      final a = parseVoice('light on', nodes, currentRoom: 0, roomNames: rooms)!;
      expect(a.targets.map((t) => '${t.nodeId}/${t.devId}/${t.on}'), ['n1/d1/true']);
    });
    test('named room wins, Hindi and Hinglish work', () {
      expect(parseVoice('room 2 light off', nodes, currentRoom: 0, roomNames: rooms)!.targets.single.nodeId, 'n2');
      final f = parseVoice('पंखा बंद करो room 2', nodes, currentRoom: 0, roomNames: rooms)!;
      expect(f.targets.single.devId, 'd3');
      expect(f.targets.single.on, false);
    });
    test('everywhere reaches every room', () {
      final a = parseVoice('light on everywhere', nodes, currentRoom: 0, roomNames: rooms)!;
      expect(a.targets.length, 2);
    });
    test('doors can be locked but never unlocked by voice', () {
      final unlock = parseVoice('unlock the door', nodes, currentRoom: 0, roomNames: rooms)!;
      expect(unlock.lockBlocked, true);
      expect(unlock.targets, isEmpty);
      final lock = parseVoice('lock the door', nodes, currentRoom: 0, roomNames: rooms)!;
      expect(lock.targets.single.on, true);
    });
    test('scenes and nonsense', () {
      expect(parseVoice('turn everything off, all off please', nodes, currentRoom: 0, roomNames: rooms)!.scene, 'alloff');
      expect(parseVoice('what is the weather', nodes, currentRoom: 0, roomNames: rooms), isNull);
    });
  });
}
