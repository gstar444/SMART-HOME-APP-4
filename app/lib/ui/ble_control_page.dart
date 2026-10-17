import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../models/models.dart';
import '../services/ble_service.dart';
import 'widgets.dart';

/// Direct Bluetooth control: works when the router, the internet and the broker are all gone.
/// The board switches Bluetooth on by itself when it loses its connection (or in a 5-minute
/// window after holding BOOT for 3 s). Uses the per-home key stored in this phone's keystore.
class BleControlPage extends ConsumerStatefulWidget {
  const BleControlPage({super.key, required this.node});
  final NodeInfo node;
  @override
  ConsumerState<BleControlPage> createState() => _BleControlPageState();
}

class _BleControlPageState extends ConsumerState<BleControlPage> {
  BleSession? _session;
  Timer? _poll;
  String _status = 'Looking for the board…';
  Map<String, bool> _on = {};
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _session?.close();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      if (!await ensureBlePermissions()) throw BleException('Bluetooth permission denied');
      final cfg = ref.read(settingsProvider).valueOrNull;
      final wanted = 'SH-${widget.node.id}';
      final dev = await scanBoards().firstWhere((d) => d.name == wanted).timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw BleException('The board is not advertising. It only does so when it is offline or after holding BOOT for 3 s.'),
          );
      setState(() => _status = 'Connecting…');
      final s = BleSession(dev.id);
      _session = s;
      await s.connect();
      await s.authenticate(homeKey: cfg?.bleKey);
      setState(() { _ready = true; _status = 'Connected over Bluetooth'; });
      await _refresh();
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    } on BleException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } catch (e) {
      if (mounted) setState(() => _status = 'Bluetooth error: $e');
    }
  }

  Future<void> _refresh() async {
    try {
      final r = await _session!.request({'op': 'state'});
      final d = (r['state'] as Map?)?['d'] as Map? ?? const {};
      if (mounted) setState(() => _on = {for (final e in d.entries) e.key as String: e.value == 1});
    } catch (_) {}
  }

  Future<void> _toggle(DeviceInfo d) async {
    final next = !(_on[d.id] ?? false);
    setState(() => _on = {..._on, d.id: next});
    try {
      await _session!.request({'op': 'set', 'id': d.id, 'on': next});
    } on BleException catch (e) {
      if (mounted) toast(context, e.message);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.node.devices.where((d) => d.controllable).toList();
    return Scaffold(
      appBar: AppBar(title: Text('${widget.node.title} · Bluetooth')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [Icon(_ready ? Icons.bluetooth_connected : Icons.bluetooth_searching), const SizedBox(width: 8), Expanded(child: Text(_status))]),
        const SizedBox(height: 12),
        if (_ready)
          for (final d in devices)
            Card(
              child: SwitchListTile(
                secondary: Icon(iconFor(d.icon, _on[d.id] ?? false)),
                title: Text(d.name),
                subtitle: Text(d.isLock ? ((_on[d.id] ?? false) ? 'Locked' : 'Unlocked') : ((_on[d.id] ?? false) ? 'On' : 'Off')),
                value: _on[d.id] ?? false,
                onChanged: (_) => _toggle(d),
              ),
            ),
      ]),
    );
  }
}
