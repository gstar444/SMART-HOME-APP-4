import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../core/theme.dart';
import '../services/ble_service.dart';
import '../services/lan_service.dart';
import '../state/home_controller.dart';
import 'ble_control_page.dart';
import 'provision_page.dart';
import 'widgets.dart';

/// Dynamic device manager: finds boards on the home Wi-Fi (mDNS) and nearby over Bluetooth.
/// New boards are set up from here - no USB cable, no code changes.
class DiscoveryPage extends ConsumerStatefulWidget {
  const DiscoveryPage({super.key});
  @override
  ConsumerState<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends ConsumerState<DiscoveryPage> {
  List<LanNode> _lan = const [];
  bool _scanningLan = false;

  final Map<String, DiscoveredDevice> _ble = {};
  StreamSubscription<DiscoveredDevice>? _bleSub;
  bool _scanningBle = false;
  String? _bleError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scanLan());
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    super.dispose();
  }

  Future<void> _scanLan() async {
    setState(() => _scanningLan = true);
    final found = await discoverLanNodes();
    if (!mounted) return;
    setState(() {
      _lan = found;
      _scanningLan = false;
    });
    await ref.read(homeProvider.notifier).refresh(); // lets the controller adopt boards of this home
  }

  Future<void> _scanBle() async {
    if (!await ensureBlePermissions()) {
      setState(() => _bleError = 'Bluetooth permission is needed to find new boards.');
      return;
    }
    await _bleSub?.cancel();
    setState(() {
      _ble.clear();
      _bleError = null;
      _scanningBle = true;
    });
    _bleSub = scanBoards().listen((d) {
      if (mounted) setState(() => _ble[d.id] = d);
    }, onError: (Object e) {
      if (mounted) setState(() { _bleError = 'Bluetooth scan failed: $e'; _scanningBle = false; });
    });
    Future.delayed(const Duration(seconds: 12), () async {
      await _bleSub?.cancel();
      if (mounted) setState(() => _scanningBle = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = ref.watch(trProvider);
    final cfg = ref.watch(settingsProvider).valueOrNull;
    final known = ref.watch(homeProvider.select((s) => s.nodes.keys.toSet()));
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(title: Text(tr.findBoards), bottom: const TabBar(tabs: [Tab(text: 'Wi-Fi'), Tab(text: 'Bluetooth')])),
        body: TabBarView(children: [
          // ------------------------------------------------ Wi-Fi (mDNS)
          RefreshIndicator(
            onRefresh: _scanLan,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (_scanningLan) const LinearProgressIndicator(),
              if (!_scanningLan && _lan.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('No boards found on this Wi-Fi. Pull down to search again.\nNew boards must be set up over Bluetooth first.', textAlign: TextAlign.center)),
              for (final n in _lan)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.developer_board),
                    title: Text(n.nodeId),
                    subtitle: Text('${n.ip} · v${n.fw}${!n.provisioned ? ' · not set up' : n.home == cfg?.homeId ? '' : ' · another home'}'),
                    trailing: known.contains(n.nodeId) ? const Icon(Icons.check_circle, color: kGood) : null,
                  ),
                ),
            ]),
          ),
          // ------------------------------------------------ Bluetooth
          ListView(padding: const EdgeInsets.all(16), children: [
            FilledButton.icon(onPressed: _scanningBle ? null : _scanBle, icon: const Icon(Icons.bluetooth_searching), label: Text(_scanningBle ? 'Scanning…' : 'Scan for boards')),
            const SizedBox(height: 6),
            const Text('A brand-new board advertises automatically. For a board that is already set up, hold its BOOT button for 3 seconds to open a 5-minute pairing window.', style: TextStyle(fontSize: 12)),
            if (_bleError != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_bleError!, style: const TextStyle(color: kBad))),
            const SizedBox(height: 12),
            for (final d in _ble.values)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: Text(d.name.isEmpty ? d.id : d.name),
                  subtitle: Text('signal ${d.rssi} dBm'),
                  trailing: FilledButton(
                    onPressed: () {
                      _bleSub?.cancel();
                      Navigator.push(context, MaterialPageRoute(builder: (_) => ProvisionPage(bleDeviceId: d.id, bleName: d.name)));
                    },
                    child: Text(tr.setUp),
                  ),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}
