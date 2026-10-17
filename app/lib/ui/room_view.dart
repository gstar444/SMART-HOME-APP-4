import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../state/home_controller.dart';
import 'ble_control_page.dart';
import 'device_editor.dart';
import 'discovery_page.dart';
import 'widgets.dart';

/// One tab of the dashboard. It shows ONLY the boards assigned to this room, each with its own
/// devices, sensors and power metrics. Built lazily by the TabBarView when the tab is visited.
class RoomView extends ConsumerWidget {
  const RoomView({super.key, required this.room});
  final int room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = ref.watch(trProvider);
    final loaded = ref.watch(homeProvider.select((s) => s.cacheLoaded));
    final nodes = ref.watch(homeProvider.select((s) => s.nodesInRoom(room)));
    final cfg = ref.watch(settingsProvider).valueOrNull;

    return RefreshIndicator(
      onRefresh: () => ref.read(homeProvider.notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          if (!loaded) ...[const SkeletonCard(height: 180), const SizedBox(height: 14), const SkeletonCard()]
          else if (nodes.isEmpty)
            _EmptyRoom(tr: tr, onAdd: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DiscoveryPage())))
          else
            for (final n in nodes) ...[NodeCard(node: n, cfg: cfg), const SizedBox(height: 14)],
        ],
      ),
    );
  }
}

class _EmptyRoom extends StatelessWidget {
  const _EmptyRoom({required this.tr, required this.onAdd});
  final Tr tr;
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Column(children: [
          Icon(Icons.developer_board, size: 64, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
          const SizedBox(height: 14),
          Text(tr.noBoardInRoom, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(tr.noBoardHint, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: Text(tr.addBoard)),
        ]),
      );
}

class NodeCard extends ConsumerWidget {
  const NodeCard({super.key, required this.node, required this.cfg});
  final NodeInfo node;
  final AppSettings? cfg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = ref.watch(trProvider);
    final ctl = ref.read(homeProvider.notifier);
    final history = ref.watch(homeProvider.select((s) => s.history[node.id] ?? const <double>[]));
    final link = ref.watch(homeProvider.select((s) => s.anyLink));
    final live = node.online && link;
    final mode = node.mode;
    final modeLabel = mode == 'emergency' ? tr.emergencyMode : mode == 'lan' ? tr.lanOnlyMode : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(node.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text([if (node.hub) 'HUB', if (node.fw.isNotEmpty) 'v${node.fw}', if (node.ip.isNotEmpty) node.ip].join(' · '),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55))),
              ]),
            ),
            StatusPill(live ? (modeLabel ?? tr.online) : tr.offline, live ? (modeLabel == null ? kGood : kWarn) : kBad),
            PopupMenuButton<String>(
              onSelected: (v) => _menu(context, ref, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'room', child: Text('Move to another room')),
                PopupMenuItem(value: 'limit', child: Text('Overload limit (W)')),
                PopupMenuItem(value: 'reset', child: Text('Reset energy counter')),
                PopupMenuItem(value: 'ble', child: Text('Control via Bluetooth')),
                PopupMenuItem(value: 'ota', child: Text('Check for firmware update')),
                PopupMenuItem(value: 'reboot', child: Text('Restart board')),
                PopupMenuItem(value: 'forget', child: Text('Remove from app')),
              ],
            ),
          ]),
          if (node.temp != null || node.hum != null) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              if (node.temp != null) Chip(avatar: const Icon(Icons.thermostat, size: 18), label: Text('${node.temp!.toStringAsFixed(1)} °C')),
              if (node.hum != null) Chip(avatar: const Icon(Icons.water_drop_outlined, size: 18), label: Text('${node.hum!.toStringAsFixed(0)} %')),
            ]),
          ],
          if (node.hasPower) ...[
            const SizedBox(height: 10),
            PowerCard(node: node, history: history, tr: tr, tariff: cfg?.tariff ?? 0, currency: cfg?.currency ?? ''),
          ],
          const SizedBox(height: 12),
          if (node.devices.isEmpty)
            Text(tr.noDevices, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)))
          else
            LayoutBuilder(builder: (context, c) {
              final w = (c.maxWidth - 12) / 2;
              return Wrap(spacing: 12, runSpacing: 12, children: [
                for (final d in node.devices)
                  SizedBox(
                    width: w,
                    child: DeviceTile(
                      device: d,
                      enabled: live || link,
                      onToggle: () => _toggle(context, ctl, d),
                      onMenu: () => _deviceMenu(context, ref, d),
                    ),
                  ),
              ]);
            }),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DeviceEditorPage(nodeId: node.id))),
            icon: const Icon(Icons.add),
            label: Text(tr.addDevice),
          ),
        ]),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, HomeController ctl, DeviceInfo d) async {
    if (d.isLock && d.on) {
      if (!await confirm(context, 'Unlock ${d.name}?', 'The door will be unlocked.', action: 'Unlock')) return;
    }
    await ctl.setDevice(node.id, d.id, !d.on);
  }

  void _deviceMenu(BuildContext context, WidgetRef ref, DeviceInfo d) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.edit), title: const Text('Edit device'), onTap: () {
            Navigator.pop(ctx);
            Navigator.push(context, MaterialPageRoute(builder: (_) => DeviceEditorPage(nodeId: node.id, device: d)));
          }),
          ListTile(leading: const Icon(Icons.delete_outline, color: kBad), title: const Text('Delete device'), onTap: () async {
            Navigator.pop(ctx);
            if (await confirm(context, 'Delete ${d.name}?', 'The GPIO pin becomes free again.', action: 'Delete')) {
              final ok = await ref.read(homeProvider.notifier).deleteDevice(node.id, d.id);
              if (context.mounted && !ok) toast(context, 'Could not reach the board');
            }
          }),
        ]),
      ),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, String v) async {
    final ctl = ref.read(homeProvider.notifier);
    final settings = ref.read(settingsProvider).valueOrNull;
    switch (v) {
      case 'rename':
        final name = await askText(context, title: 'Board name', initial: node.title);
        if (name != null && name.isNotEmpty) await ctl.setNode(node.id, {'name': name});
        break;
      case 'room':
        final names = settings?.roomNames ?? const ['Room 1', 'Room 2', 'Room 3', 'Room 4'];
        final idx = await showDialog<int>(
          context: context,
          builder: (ctx) => SimpleDialog(title: const Text('Move to room'), children: [
            for (var i = 0; i < names.length; i++) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, i), child: Text(names[i])),
          ]),
        );
        if (idx != null) await ctl.setNode(node.id, {'room': idx, 'rn': names[idx]});
        break;
      case 'limit':
        final t = await askText(context, title: 'Overload limit in watts (0 = off)', hint: 'e.g. 2500', type: TextInputType.number);
        final w = int.tryParse(t ?? '');
        if (w != null) await ctl.setNode(node.id, {'maxw': w});
        break;
      case 'reset':
        if (await confirm(context, 'Reset energy counter?', 'The kWh counter of this board starts again from zero.', action: 'Reset')) {
          await ctl.sendCmd(node.id, {'op': 'resetEnergy'});
        }
        break;
      case 'ble':
        Navigator.push(context, MaterialPageRoute(builder: (_) => BleControlPage(node: node)));
        break;
      case 'ota':
        final ok = await ctl.sendCmd(node.id, {'op': 'ota'});
        if (context.mounted) toast(context, ok ? 'Asked the board to check for updates' : 'Could not reach the board');
        break;
      case 'reboot':
        await ctl.sendCmd(node.id, {'op': 'reboot'});
        break;
      case 'forget':
        ctl.forget(node.id);
        break;
    }
  }
}
