/// Device manager: finds boards via mDNS (Wi-Fi) and BLE, adds them to the
/// app, and provisions NEW boards over Bluetooth (Wi-Fi + MQTT + Telegram +
/// cloud credentials) without a USB cable.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../settings.dart';
import 'advanced_page.dart' show toast, tx;
import 'ble_service.dart';
import 'board_config_page.dart';
import 'discovery.dart';

class ProvisioningPage extends StatefulWidget {
  const ProvisioningPage({super.key, required this.settings});
  final SettingsController settings;

  @override
  State<ProvisioningPage> createState() => _ProvisioningPageState();
}

class _ProvisioningPageState extends State<ProvisioningPage> {
  List<FoundBoard> _lan = [];
  List<BleBoard> _ble = [];
  bool _scanningLan = false;
  bool _scanningBle = false;
  String? _bleError;
  StreamSubscription<List<BleBoard>>? _bleSub;

  String t(String hi, String en) => tx(widget.settings, hi, en);

  @override
  void initState() {
    super.initState();
    _scanLan();
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    super.dispose();
  }

  Future<void> _scanLan() async {
    setState(() => _scanningLan = true);
    final found = await discoverBoards();
    if (mounted) {
      setState(() {
        _lan = found;
        _scanningLan = false;
      });
    }
  }

  Future<void> _scanBle() async {
    if (!await BleBoard.supported) {
      setState(() => _bleError = t('यह फ़ोन BLE सपोर्ट नहीं करता', 'Bluetooth LE is not supported on this phone'));
      return;
    }
    await _bleSub?.cancel();
    setState(() {
      _scanningBle = true;
      _bleError = null;
      _ble = [];
    });
    _bleSub = BleBoard.scan().listen(
      (list) => setState(() => _ble = list),
      onError: (Object e) => setState(() {
        _bleError = '$e';
        _scanningBle = false;
      }),
      onDone: () => setState(() => _scanningBle = false),
    );
  }

  void _addLan(FoundBoard b) {
    final s = widget.settings.value;
    final url = normalizeUrl(b.url) ?? b.url;
    final i = s.devices.indexWhere((d) => d.url == url);
    if (i >= 0) {
      widget.settings.update(s.copyWith(activeDevice: i));
    } else {
      widget.settings.update(s.copyWith(
        devices: [...s.devices, Device(name: b.name, url: url)],
        activeDevice: s.devices.length,
      ));
    }
    toast(context, t('डिवाइस जोड़ा गया: ${b.name}', 'Board added: ${b.name}'));
  }

  Future<void> _openBle(BleBoard b) async {
    await _bleSub?.cancel();
    setState(() => _scanningBle = false);
    try {
      await b.connect();
    } catch (e) {
      if (mounted) toast(context, '$e');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BoardConfigPage(
        settings: widget.settings,
        title: b.name,
        send: (cmd) => b.send(cmd),
        extraTop: _BleWifiCard(board: b, t: t),
      ),
    ));
    await b.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget head(String text, bool busy, VoidCallback onScan) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 8, 4),
          child: Row(children: [
            Expanded(
              child: Text(text,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
            ),
            busy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(onPressed: onScan, icon: const Icon(Icons.search)),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: Text(t('डिवाइस मैनेजर', 'Device manager'))),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        head(t('Wi-Fi पर मिले बोर्ड (mDNS)', 'Boards on Wi-Fi (mDNS)'), _scanningLan, _scanLan),
        if (_lan.isEmpty && !_scanningLan)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(t('कोई नहीं मिला', 'None found'))),
        for (final b in _lan)
          ListTile(
            leading: const Icon(Icons.router_outlined),
            title: Text(b.name),
            subtitle: Text(b.url),
            trailing: const Icon(Icons.add_circle_outline),
            onTap: () => _addLan(b),
          ),
        head(t('ब्लूटूथ बोर्ड (नया सेटअप)', 'Bluetooth boards (new setup)'), _scanningBle, _scanBle),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            t('पहली बार जुड़ने पर फ़ोन PIN माँगेगा (फर्मवेयर config.h में BLE_PASSKEY, डिफ़ॉल्ट 123456 - बदल दें)।',
                'On first connect the phone asks for the PIN (BLE_PASSKEY in firmware config.h, default 123456 - change it).'),
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (_bleError != null) Padding(padding: const EdgeInsets.all(16), child: Text(_bleError!)),
        for (final b in _ble)
          ListTile(
            leading: const Icon(Icons.bluetooth),
            title: Text(b.name),
            subtitle: Text(b.device.remoteId.str),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openBle(b),
          ),
      ]),
    );
  }
}

/// Wi-Fi credentials sent over the encrypted BLE link.
class _BleWifiCard extends StatefulWidget {
  const _BleWifiCard({required this.board, required this.t});
  final BleBoard board;
  final String Function(String, String) t;

  @override
  State<_BleWifiCard> createState() => _BleWifiCardState();
}

class _BleWifiCardState extends State<_BleWifiCard> {
  final _ssid = TextEditingController();
  final _pass = TextEditingController();
  String _info = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.board.info().then((i) {
      if (mounted && i.isNotEmpty) {
        setState(() => _info = '${i['node'] ?? ''}  fw ${i['fw'] ?? ''}  IP ${i['ip'] ?? ''}');
      }
    });
  }

  @override
  void dispose() {
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    final r = await widget.board.send({'op': 'wifi', 'ssid': _ssid.text.trim(), 'pass': _pass.text});
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, r['ok'] == true
        ? widget.t('भेज दिया - बोर्ड Wi-Fi से जुड़ रहा है', 'Sent - the board is joining the Wi-Fi')
        : '${r['error']}');
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Wi-Fi', style: Theme.of(context).textTheme.titleSmall),
          if (_info.isNotEmpty) Text(_info, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          TextField(controller: _ssid, decoration: InputDecoration(labelText: t('Wi-Fi नाम', 'Wi-Fi name'))),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: InputDecoration(labelText: t('पासवर्ड', 'Password')),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.wifi),
            label: Text(t('BLE से Wi-Fi भेजें', 'Send Wi-Fi over BLE')),
          ),
        ]),
      ),
    );
  }
}
