import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../services/mqtt_service.dart';
import '../state/home_controller.dart';
import '../voice.dart';
import 'device_editor.dart';
import 'discovery_page.dart';
import 'energy_page.dart';
import 'room_view.dart';
import 'rules_page.dart';
import 'settings_page.dart';
import 'widgets.dart';

/// Multi-room dashboard: a swipeable tab per room. Tabs are built lazily - a room's widgets
/// only exist once you swipe to it.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rooms = ref.watch(settingsProvider.select((s) => s.valueOrNull?.roomNames ?? const ['Room 1', 'Room 2', 'Room 3', 'Room 4']));
    ref.listen<AsyncValue<String>>(homeEventsProvider, (_, next) => next.whenData((m) => toast(context, m)));
    return DefaultTabController(key: ValueKey(rooms.join('|')), length: rooms.length, child: _Scaffold(rooms: rooms));
  }
}

class _Scaffold extends ConsumerWidget {
  const _Scaffold({required this.rooms});
  final List<String> rooms;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = ref.watch(trProvider);
    final cfg = ref.watch(settingsProvider).valueOrNull;
    final hasNodes = ref.watch(homeProvider.select((s) => s.nodes.isNotEmpty));
    final needsSetup = cfg != null && !cfg.mqttConfigured && !hasNodes;

    return Scaffold(
      appBar: AppBar(
        title: Text(cfg?.homeName ?? tr.appName, style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          const _ConnectionPill(),
          IconButton(tooltip: tr.voice, icon: const Icon(Icons.mic_none), onPressed: () => _voice(context, ref)),
          PopupMenuButton<String>(
            onSelected: (v) {
              final Widget page = switch (v) {
                'rules' => const RulesPage(),
                'energy' => const EnergyPage(),
                'find' => const DiscoveryPage(),
                _ => const SettingsPage(),
              };
              Navigator.push(context, MaterialPageRoute(builder: (_) => page));
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'find', child: Text(tr.findBoards)),
              PopupMenuItem(value: 'rules', child: Text(tr.automations)),
              PopupMenuItem(value: 'energy', child: Text(tr.energy)),
              PopupMenuItem(value: 'settings', child: Text(tr.settings)),
            ],
          ),
        ],
        bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final r in rooms) Tab(text: r)]),
      ),
      body: needsSetup
          ? _Welcome(tr: tr)
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final s in [('alloff', tr.allOff, Icons.power_settings_new), ('goodnight', tr.goodNight, Icons.nightlight_round), ('dinner', tr.dinner, Icons.restaurant)])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(avatar: Icon(s.$3, size: 18), label: Text(s.$2), onPressed: () => ref.read(homeProvider.notifier).runScene(s.$1)),
                      ),
                  ]),
                ),
              ),
              Expanded(child: TabBarView(children: [for (var i = 0; i < rooms.length; i++) RoomView(room: i)])),
            ]),
      floatingActionButton: needsSetup
          ? null
          : Builder(builder: (ctx) {
              return FloatingActionButton.extended(
                onPressed: () => _addDevice(ctx, ref),
                icon: const Icon(Icons.add),
                label: Text(tr.addDevice),
              );
            }),
    );
  }

  /// "+ Add device" for the room on screen: picks that room's board (or asks to add one).
  void _addDevice(BuildContext context, WidgetRef ref) {
    final room = DefaultTabController.of(context).index;
    final nodes = ref.read(homeProvider).nodesInRoom(room);
    if (nodes.isEmpty) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const DiscoveryPage()));
    } else if (nodes.length == 1) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => DeviceEditorPage(nodeId: nodes.first.id)));
    } else {
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final n in nodes)
              ListTile(
                leading: const Icon(Icons.developer_board),
                title: Text(n.title),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => DeviceEditorPage(nodeId: n.id)));
                },
              ),
          ]),
        ),
      );
    }
  }

  Future<void> _voice(BuildContext context, WidgetRef ref) async {
    final tr = ref.read(trProvider);
    final cfg = ref.read(settingsProvider).valueOrNull;
    final room = DefaultTabController.of(context).index;
    String? said;
    try {
      said = await listenOnce(hindi: tr.hi, prompt: tr.speakNow);
    } on VoiceUnavailable {
      if (context.mounted) toast(context, 'Speech recognition is not available on this phone');
      return;
    }
    if (said == null || !context.mounted) return;
    final state = ref.read(homeProvider);
    final action = parseVoice(said, state.nodes.values.toList(), currentRoom: room, roomNames: cfg?.roomNames ?? const []);
    if (action == null) {
      toast(context, '${tr.didNotUnderstand}: "$said"');
      return;
    }
    final ctl = ref.read(homeProvider.notifier);
    if (action.scene != null) await ctl.runScene(action.scene!);
    for (final t in action.targets) {
      // voice always carries src "app" from here (the person is holding the phone); locks can only be LOCKED
      await ctl.setDevice(t.nodeId, t.devId, t.on);
    }
    if (action.lockBlocked && context.mounted) toast(context, tr.lockBlocked);
  }
}

class _ConnectionPill extends ConsumerWidget {
  const _ConnectionPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = ref.watch(trProvider);
    final s = ref.watch(homeProvider.select((s) => (s.mqtt, s.lanOk, s.mqttError)));
    final (mqtt, lan, err) = s;
    late String label;
    late Color color;
    if (mqtt == MqttState.connected) {
      label = tr.viaCloud;
      color = kGood;
    } else if (lan) {
      label = tr.viaLan;
      color = kWarn;
    } else if (mqtt == MqttState.connecting) {
      label = tr.connecting;
      color = kWarn;
    } else {
      label = tr.noConnection;
      color = kBad;
    }
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: StatusPill(label, color, onTap: () {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(label),
            content: Text(err ?? (mqtt == MqttState.connected ? 'Connected to the broker over TLS.' : 'Broker not connected. Boards on the same Wi-Fi are still controllable over the local network.')),
            actions: [
              TextButton(onPressed: () { ref.read(homeProvider.notifier).reconnect(); Navigator.pop(ctx); }, child: Text(tr.retry)),
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
            ],
          ),
        );
      }),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.tr});
  final Tr tr;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.home_work_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('Welcome', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('1. Enter your MQTT broker (and optional Firebase / Telegram / AI) in Settings.\n2. Press "Find boards" to set up each ESP32 over Bluetooth.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())), icon: const Icon(Icons.settings), label: Text(tr.settings)),
            const SizedBox(height: 10),
            OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DiscoveryPage())), icon: const Icon(Icons.bluetooth_searching), label: Text(tr.findBoards)),
          ]),
        ),
      );
}
