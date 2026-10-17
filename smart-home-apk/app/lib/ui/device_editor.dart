import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/util.dart';
import '../models/models.dart';
import '../state/home_controller.dart';
import 'widgets.dart';

/// "+ Add device" / "Edit device": assigns an appliance to a GPIO pin of a board (= a room).
/// The command goes to the board over MQTT (or the home Wi-Fi); the board saves it and mirrors the
/// new configuration to Firebase. No firmware change, no reflashing.
class DeviceEditorPage extends ConsumerStatefulWidget {
  const DeviceEditorPage({super.key, required this.nodeId, this.device});
  final String nodeId;
  final DeviceInfo? device;

  @override
  ConsumerState<DeviceEditorPage> createState() => _DeviceEditorPageState();
}

class _DeviceEditorPageState extends ConsumerState<DeviceEditorPage> {
  late final TextEditingController _name, _watts, _autoOff, _sinric;
  late String _icon;
  int? _pin;
  late bool _persist, _invert;
  bool _busy = false;

  bool get _editing => widget.device != null;

  @override
  void initState() {
    super.initState();
    final d = widget.device;
    _name = TextEditingController(text: d?.name ?? '');
    _watts = TextEditingController(text: d == null ? '' : '${d.watts}');
    _autoOff = TextEditingController(text: d == null ? '' : '${d.autoOffMin}');
    _sinric = TextEditingController(text: d?.sinricId ?? '');
    _icon = d?.icon ?? 'light';
    _pin = d?.pin;
    _persist = d?.persist ?? true;
    _invert = d?.invert ?? false;
  }

  @override
  void dispose() {
    for (final c in [_name, _watts, _autoOff, _sinric]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = ref.watch(homeProvider.select((s) => s.nodes[widget.nodeId]));
    if (node == null) return const Scaffold(body: Center(child: Text('Board not found')));
    final type = typeForIcon(_icon);
    final used = {for (final d in node.devices) if (d.id != widget.device?.id) d.pin};
    final pins = <int>[
      ...(node.pinsOut.isEmpty ? const [4, 5, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33] : node.pinsOut),
      if (type == 'pir') ...(node.pinsIn.isEmpty ? const [34, 35, 36, 39] : node.pinsIn),
    ].where((p) => !used.contains(p) || p == widget.device?.pin).toList()..sort();
    if (_pin != null && !pins.contains(_pin)) _pin = null;

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit device' : 'Add device to ${node.title}')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name', hintText: 'Ceiling light'), textCapitalization: TextCapitalization.sentences),
        const SizedBox(height: 18),
        const Text('Icon / type'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final i in (_editing ? iconsForType(widget.device!.type) : kAllIcons))
            ChoiceChip(
              selected: _icon == i,
              avatar: Icon(iconFor(i, true), size: 18),
              label: Text(i),
              onSelected: (_) => setState(() {
                _icon = i;
                if (!_editing) {
                  _watts.text = '';
                  _autoOff.text = '';
                }
              }),
            ),
        ]),
        const SizedBox(height: 18),
        DropdownButtonFormField<int>(
          key: ValueKey('pin-$type-${pins.length}'),
          initialValue: _pin,
          decoration: InputDecoration(labelText: type == 'pir' ? 'GPIO pin (sensor input)' : 'GPIO pin (relay output)'),
          items: [for (final p in pins) DropdownMenuItem(value: p, child: Text('GPIO $p'))],
          onChanged: (v) => setState(() => _pin = v),
        ),
        if (type == 'switch') ...[
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: TextField(controller: _watts, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Load (W)', hintText: 'for energy estimate'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _autoOff, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Auto-off (min)', hintText: '0 = never'))),
          ]),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Restore after power cut'), value: _persist, onChanged: (v) => setState(() => _persist = v)),
        ],
        if (type == 'switch')
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Invert output'), subtitle: const Text('Only for relays wired the other way round'), value: _invert, onChanged: (v) => setState(() => _invert = v)),
        if (type != 'pir') ...[
          const SizedBox(height: 6),
          TextField(controller: _sinric, decoration: const InputDecoration(labelText: 'Voice assistant ID (optional)', helperText: 'Sinric Pro device id for Alexa / Google Home')),
        ],
        const SizedBox(height: 24),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
        if (_editing) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : () async {
              if (!await confirm(context, 'Delete ${widget.device!.name}?', 'This frees GPIO ${widget.device!.pin}.', action: 'Delete')) return;
              setState(() => _busy = true);
              final ok = await ref.read(homeProvider.notifier).deleteDevice(widget.nodeId, widget.device!.id);
              if (!mounted) return;
              if (ok) { Navigator.pop(context); } else { setState(() => _busy = false); toast(context, 'Could not reach the board'); }
            },
            child: const Text('Delete device'),
          ),
        ],
      ]),
    );
  }

  Future<void> _save() async {
    final name = cleanName(_name.text);
    if (name.isEmpty) return toast(context, 'Please enter a name');
    if (_pin == null) return toast(context, 'Please choose a GPIO pin');
    final body = <String, dynamic>{
      'name': name,
      'icon': _icon,
      'pin': _pin,
      if (_watts.text.trim().isNotEmpty) 'w': int.tryParse(_watts.text.trim()) ?? 0,
      if (_autoOff.text.trim().isNotEmpty) 'ao': int.tryParse(_autoOff.text.trim()) ?? 0,
      'per': _persist ? 1 : 0,
      'inv': _invert ? 1 : 0,
      'sin': _sinric.text.trim(),
    };
    setState(() => _busy = true);
    final ctl = ref.read(homeProvider.notifier);
    final ok = _editing ? await ctl.updateDevice(widget.nodeId, {...body, 'id': widget.device!.id}) : await ctl.addDevice(widget.nodeId, body);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _busy = false);
      toast(context, 'The board did not accept this (offline, or the pin is already used).');
    }
  }
}
