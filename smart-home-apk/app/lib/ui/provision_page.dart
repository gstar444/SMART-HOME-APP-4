import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../core/util.dart';
import '../services/ble_service.dart';
import 'widgets.dart';

/// Sends Wi-Fi + MQTT + Firebase (+ Telegram / AI / voice for the hub) to a board over an
/// ENCRYPTED Bluetooth channel. The pairing code proves you own the board; the BLE link itself is
/// not trusted (see firmware/crypto.h).
class ProvisionPage extends ConsumerStatefulWidget {
  const ProvisionPage({super.key, required this.bleDeviceId, required this.bleName});
  final String bleDeviceId, bleName;

  @override
  ConsumerState<ProvisionPage> createState() => _ProvisionPageState();
}

class _ProvisionPageState extends ConsumerState<ProvisionPage> {
  final _code = TextEditingController();
  final _wifiPass = TextEditingController();
  final _name = TextEditingController();
  BleSession? _session;
  List<Map<String, dynamic>> _nets = [];
  String? _ssid;
  int _room = 0;
  bool _hub = false;
  bool _busy = false, _done = false;
  String? _error;
  bool _needsCode = true;

  @override
  void initState() {
    super.initState();
    final tail = widget.bleName.startsWith('SH-') ? widget.bleName.substring(3) : '';
    _name.text = tail.isEmpty ? 'New board' : 'Board ${tail.length > 6 ? tail.substring(0, 6) : tail}';
  }

  @override
  void dispose() {
    _session?.close();
    for (final c in [_code, _wifiPass, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() { _busy = true; _error = null; });
    try {
      await ensureBlePermissions();
      final cfg = await ref.read(settingsProvider.notifier).ensureKeys();
      final s = BleSession(widget.bleDeviceId);
      _session = s;
      final info = await s.connect();
      _needsCode = info['mode'] == 'pop';
      if (_needsCode && _code.text.trim().isEmpty) {
        setState(() { _busy = false; _error = 'Enter the pairing code of this board first.'; });
        return;
      }
      await s.authenticate(pairingCode: _code.text, homeKey: cfg.bleKey);
      final r = await s.request({'op': 'scan'}, timeout: const Duration(seconds: 20));
      final nets = [for (final n in (r['nets'] as List? ?? const [])) Map<String, dynamic>.from(n as Map)]
        ..sort((a, b) => (b['r'] as int).compareTo(a['r'] as int));
      setState(() { _nets = nets; _ssid = nets.isNotEmpty ? nets.first['s'] as String : null; _busy = false; });
    } on BleException catch (e) {
      setState(() { _error = e.message; _busy = false; });
    } catch (e) {
      setState(() { _error = '$e'; _busy = false; });
    }
  }

  Future<void> _send() async {
    final s = _session;
    if (s == null || _ssid == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final cfg = await ref.read(settingsProvider.notifier).ensureKeys();
      final rooms = cfg.roomNames;
      final fbOk = cfg.fbApiKey.isNotEmpty && cfg.fbDbUrl.isNotEmpty && cfg.fbDeviceEmail.isNotEmpty && cfg.fbDevicePass.isNotEmpty;
      final body = <String, dynamic>{
        'op': 'prov',
        'home': cfg.homeId,
        'wifi': {'s': _ssid, 'p': _wifiPass.text},
        'sec': {'api': cfg.apiKey, 'ap': cfg.apPass, 'key': cfg.bleKey},
        'node': {'name': cleanName(_name.text), 'room': _room, 'rn': rooms[_room], 'hub': _hub ? 1 : 0},
        'tz': posixTz(DateTime.now().timeZoneOffset),
        if (cfg.mqttHost.isNotEmpty) 'mqtt': {'h': cfg.mqttHost, 'p': cfg.mqttPort, 'u': cfg.mqttUser, 'w': cfg.mqttPass},
        if (fbOk) 'fb': {'k': cfg.fbApiKey, 'd': cfg.fbDbUrl, 'm': cfg.fbDeviceEmail, 'w': cfg.fbDevicePass},
        // chat bot, AI and voice run on the HUB only - other boards never receive those secrets
        if (_hub && cfg.tgToken.isNotEmpty) 'tg': {'t': cfg.tgToken, 'c': parseChatIds(cfg.tgChats).join(',')},
        if (_hub && cfg.aiUrl.isNotEmpty) 'ai': {'u': cfg.aiUrl, 'k': cfg.aiKey},
        if (_hub && cfg.sinricKey.isNotEmpty) 'sin': {'k': cfg.sinricKey, 's': cfg.sinricSecret},
      };
      if (utf8.encode(jsonEncode(body)).length > 1300) throw BleException('Settings are too long to send over Bluetooth. Shorten some values.');
      if (_hub && cfg.tgToken.isNotEmpty && parseChatIds(cfg.tgChats).isEmpty) {
        throw BleException('Telegram needs at least one authorised chat id (Settings -> Telegram). Without it the bot stays off.');
      }
      await s.request(body, timeout: const Duration(seconds: 15));
      await s.close();
      setState(() { _done = true; _busy = false; });
    } on BleException catch (e) {
      setState(() { _error = e.message; _busy = false; });
    } catch (e) {
      setState(() { _error = '$e'; _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(settingsProvider).valueOrNull;
    final rooms = cfg?.roomNames ?? const ['Room 1', 'Room 2', 'Room 3', 'Room 4'];
    if (_done) {
      return Scaffold(
        appBar: AppBar(title: const Text('Board set up')),
        body: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.check_circle, size: 72, color: Colors.green),
            const SizedBox(height: 16),
            const Text('The board is restarting and joining your Wi-Fi. It appears in the room tab within a few seconds.\n\nThe LED blinks slowly once it is online.', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton(onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst), child: const Text('Done')),
          ]),
        ),
      );
    }
    final connected = _nets.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text('Set up ${widget.bleName}')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        if (!connected) ...[
          const Text('1 · Connect', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Pairing code', hintText: 'ABCDE-FGHJK', helperText: 'Shown on the board\'s serial monitor at first start (not needed for a board you already set up in this app)'),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _busy ? null : _connect, child: Text(_busy ? 'Connecting…' : 'Connect and scan Wi-Fi')),
        ] else ...[
          const Text('2 · Wi-Fi for this board', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _ssid,
            decoration: const InputDecoration(labelText: 'Network'),
            items: [for (final n in _nets) DropdownMenuItem(value: n['s'] as String, child: Text('${n['s']}  (${n['r']} dBm)${n['x'] == 1 ? '' : '  open'}'))],
            onChanged: (v) => setState(() => _ssid = v),
          ),
          const SizedBox(height: 10),
          TextField(controller: _wifiPass, obscureText: true, decoration: const InputDecoration(labelText: 'Wi-Fi password')),
          const SizedBox(height: 22),
          const Text('3 · Room and role', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Board name')),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            initialValue: _room,
            decoration: const InputDecoration(labelText: 'Room'),
            items: [for (var i = 0; i < rooms.length; i++) DropdownMenuItem(value: i, child: Text(rooms[i]))],
            onChanged: (v) => setState(() => _room = v ?? 0),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hub board'),
            subtitle: const Text('Runs Telegram, AI and Alexa / Google voice for the whole house. Turn this on for ONE board only.'),
            value: _hub,
            onChanged: (v) => setState(() => _hub = v),
          ),
          const SizedBox(height: 14),
          FilledButton(onPressed: _busy ? null : _send, child: Text(_busy ? 'Sending…' : 'Send settings to board')),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!, style: const TextStyle(color: Colors.red))),
      ]),
    );
  }
}
