import 'package:esp32_controller/device_icons.dart';
import 'package:esp32_controller/models.dart';
import 'package:esp32_controller/settings.dart';
import 'package:esp32_controller/voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('default ESP32 URL is an HTTP URL with an IP host', () {
    final uri = Uri.parse(esp32Url);
    expect(uri.scheme, 'http');
    expect(uri.host, '192.168.1.37');
    expect(uri.path, '/');
  });

  group('normalizeUrl', () {
    test('adds http:// to a bare IP', () {
      expect(normalizeUrl('192.168.1.50'), 'http://192.168.1.50');
    });
    test('keeps https URLs', () {
      expect(normalizeUrl(' https://esp32.local/ '), 'https://esp32.local/');
    });
    test('rejects empty and unsupported input', () {
      expect(normalizeUrl(''), isNull);
      expect(normalizeUrl('ftp://192.168.1.1'), isNull);
    });
  });

  test('settings survive a JSON round trip', () {
    const original = AppSettings(
      title: 'My Home',
      devices: [
        Device(name: 'Hall', url: 'http://192.168.1.10/'),
        Device(name: 'Garden', url: 'http://192.168.1.11/'),
      ],
      activeDevice: 1,
      themeMode: ThemeMode.dark,
      accent: 0xFF2563EB,
      showToolbar: false,
      pageZoom: 120,
      autoRefreshSeconds: 30,
      timeoutSeconds: 10,
      javaScript: false,
      hindi: false,
    );
    final copy = AppSettings.fromJson(original.toJson());
    expect(copy.title, 'My Home');
    expect(copy.devices.length, 2);
    expect(copy.activeUrl, 'http://192.168.1.11/');
    expect(copy.themeMode, ThemeMode.dark);
    expect(copy.accent, 0xFF2563EB);
    expect(copy.showToolbar, isFalse);
    expect(copy.pageZoom, 120);
    expect(copy.autoRefreshSeconds, 30);
    expect(copy.timeoutSeconds, 10);
    expect(copy.javaScript, isFalse);
    expect(copy.hindi, isFalse);
  });

  test('out-of-range saved values are clamped', () {
    final s = AppSettings.fromJson({'pageZoom': 999, 'activeDevice': 7});
    expect(s.pageZoom, 150);
    expect(s.activeUrl, defaultEsp32Url);
  });

  test('rooms, room assignments, API key and poll interval survive a JSON round trip', () {
    const original = AppSettings(
      apiKey: 'k1',
      pollSeconds: 5,
      rooms: ['Hall', 'Bedroom'],
      roomOf: {'fan': 1},
    );
    final copy = AppSettings.fromJson(original.toJson());
    expect(copy.apiKey, 'k1');
    expect(copy.pollSeconds, 5);
    expect(copy.rooms, ['Hall', 'Bedroom']);
    expect(copy.roomOf['fan'], 1);
  });

  group('ESP32 state JSON', () {
    final sample = <String, dynamic>{
      'name': 'Home',
      'fw': '2.0.0',
      'ssid': 'चाय वाला',
      'ip': '192.168.1.37',
      'rssi': -52,
      'uptime': 120,
      'temp': 22.5,
      'hum': null,
      'dnd': false,
      'camera': '',
      'powerW': 72.0,
      'devices': [
        {
          'id': 'light',
          'name': 'Main Light',
          'type': 'switch',
          'group': 'Lighting',
          'icon': 'light',
          'room': 0,
          'on': true,
          'watts': 12,
          'wh': 1.5,
        },
        {'id': 'lock', 'name': 'Smart Lock', 'type': 'lock', 'on': true},
        {'id': '', 'name': 'broken entry without id'},
      ],
    };

    test('parses fields and skips entries without an id', () {
      final st = Esp32State.fromJson(sample);
      expect(st.ssid, 'चाय वाला');
      expect(st.temp, 22.5);
      expect(st.hum, isNull);
      expect(st.devices.length, 2);
      expect(st.devices.first.watts, 12);
      expect(st.devices[1].isLock, isTrue);
      expect(st.devices[1].controllable, isTrue);
    });

    test('withDevice flips only the chosen device', () {
      final st = Esp32State.fromJson(sample).withDevice('light', on: false);
      expect(st.devices.first.on, isFalse);
      expect(st.devices[1].on, isTrue);
    });
  });

  group('voice commands', () {
    const devices = [
      Esp32Device(
          id: 'light', name: 'Main Light', type: 'switch', group: 'Lighting',
          icon: 'light', room: 0, on: false),
      Esp32Device(
          id: 'fan', name: 'Ceiling Fan', type: 'switch', group: 'Climate',
          icon: 'fan', room: 0, on: false),
      Esp32Device(
          id: 'lock', name: 'Smart Lock', type: 'lock', group: 'Security',
          icon: 'lock', room: 0, on: true),
    ];

    test('English and Hindi device commands', () {
      expect(parseVoice('light on', devices)?.set, {'light': true});
      expect(parseVoice('पंखा बंद करो', devices)?.set, {'fan': false});
      expect(parseVoice('light and fan off', devices)?.set,
          {'light': false, 'fan': false});
    });

    test('scenes', () {
      expect(parseVoice('sab band', devices)?.scene, 'alloff');
      expect(parseVoice('good night', devices)?.scene, 'goodnight');
    });

    test('a door can be locked but never unlocked by voice', () {
      expect(parseVoice('lock the door', devices)?.set, {'lock': true});
      final blocked = parseVoice('unlock the door', devices);
      expect(blocked?.lockBlocked, isTrue);
      expect(blocked?.set, isEmpty);
    });

    test('unknown or incomplete sentences return null', () {
      expect(parseVoice('hello there', devices), isNull);
      expect(parseVoice('light', devices), isNull);
    });
  });

  group('device list and Wi-Fi (firmware v3)', () {
    test('state from an old firmware still parses and gets default pins', () {
      final st = Esp32State.fromJson({'name': 'Home', 'devices': []});
      expect(st.mode, 'sta');
      expect(st.wifiConnected, isTrue);
      expect(st.apActive, isFalse);
      expect(st.pinsOut, defaultOutPins);
      expect(st.pinsIn, defaultInPins);
      expect(st.maxDevices, 24);
    });

    test('state from firmware v3 carries pins, mode and device GPIO', () {
      final st = Esp32State.fromJson({
        'mode': 'ap',
        'apSsid': 'SmartHome-Setup',
        'ip': '192.168.4.1',
        'maxDevices': 24,
        'pinsOut': [5, 13, 23],
        'pinsIn': [34],
        'devices': [
          {'id': 'd1', 'name': 'Bulb 2', 'icon': 'light', 'pin': 23, 'room': 1},
        ],
      });
      expect(st.apActive, isTrue);
      expect(st.wifiConnected, isFalse);
      expect(st.apSsid, 'SmartHome-Setup');
      expect(st.pinsOut, [5, 13, 23]);
      expect(st.pinsIn, [34]);
      expect(st.devices.single.pin, 23);
      expect(st.devices.single.room, 1);
      // toggling a device keeps the pin list and Wi-Fi mode
      final flipped = st.withDevice('d1', on: true);
      expect(flipped.devices.single.on, isTrue);
      expect(flipped.devices.single.pin, 23);
      expect(flipped.pinsOut, [5, 13, 23]);
      expect(flipped.apSsid, 'SmartHome-Setup');
    });

    test('Wi-Fi scan and status answers parse', () {
      final scan = WifiScan.fromJson({
        'scanning': false,
        'networks': [
          {'ssid': 'चाय वाला', 'rssi': -48, 'secure': true},
          {'ssid': 'Cafe', 'rssi': -70, 'secure': false},
          {'ssid': '', 'rssi': -80, 'secure': true},
        ],
      });
      expect(scan.scanning, isFalse);
      expect(scan.networks.length, 2);
      expect(scan.networks.first.ssid, 'चाय वाला');
      expect(scan.networks[1].secure, isFalse);

      final status = WifiStatus.fromJson({
        'state': 'failed',
        'connected': false,
        'ssid': '',
        'ip': '192.168.4.1',
        'mode': 'ap',
        'error': 'could not connect',
        'saved': true,
      });
      expect(status.state, 'failed');
      expect(status.connected, isFalse);
      expect(status.saved, isTrue);
    });

    test('icons decide the device type', () {
      expect(typeForIcon('light'), 'switch');
      expect(typeForIcon('plug'), 'switch');
      expect(typeForIcon('lock'), 'lock');
      expect(typeForIcon('pir'), 'pir');
      expect(iconsForType('pir'), ['pir']);
      expect(iconsForType('switch'), contains('fan'));
      expect(allIcons, containsAll(['light', 'fan', 'lock', 'pir']));
    });

    test('a device called by its own name is the only one switched', () {
      const devices = [
        Esp32Device(
            id: 'd1', name: 'Bulb 1', type: 'switch', group: 'Lighting',
            icon: 'light', room: 0, on: false),
        Esp32Device(
            id: 'd2', name: 'Bulb 2', type: 'switch', group: 'Lighting',
            icon: 'light', room: 0, on: false),
      ];
      expect(parseVoice('bulb 2 on', devices)?.set, {'d2': true});
      expect(parseVoice('light on', devices)?.set, {'d1': true, 'd2': true});
    });

    test('the active ESP32 address can be changed and the setup address added', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = await SettingsController.load();
      await controller.setActiveUrl('http://10.0.0.77/');
      expect(controller.value.activeUrl, 'http://10.0.0.77/');
      expect(controller.value.devices.length, 1);

      await controller.activateSetupDevice();
      expect(controller.value.devices.length, 2);
      expect(controller.value.activeUrl, setupEsp32Url);

      // asking again selects the same entry instead of adding another one
      await controller.activateSetupDevice();
      expect(controller.value.devices.length, 2);
    });
  });
}
