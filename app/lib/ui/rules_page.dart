import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../core/theme.dart';
import '../core/util.dart';
import '../models/models.dart';
import '../state/home_controller.dart';
import 'widgets.dart';

/// Remote rules engine. Rules live in Firebase (homes/<home>/rules); each board downloads the
/// rules that belong to it and runs them LOCALLY - so automations keep working without internet.
/// Editing needs the cloud database, running does not.
class RulesPage extends ConsumerStatefulWidget {
  const RulesPage({super.key});
  @override
  ConsumerState<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends ConsumerState<RulesPage> {
  List<RuleModel>? _rules;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final fb = ref.read(firebaseProvider);
    final cfg = ref.read(settingsProvider).valueOrNull;
    if (fb == null || cfg == null) {
      setState(() => _error = 'Set up the cloud database in Settings first (Firebase).');
      return;
    }
    try {
      final map = await fb.rules(cfg.homeId);
      if (!mounted) return;
      setState(() {
        _rules = [for (final e in map.entries) if (e.value is Map) RuleModel.fromJson(e.key, e.value as Map)];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save(RuleModel r, {bool delete = false}) async {
    final fb = ref.read(firebaseProvider);
    final cfg = ref.read(settingsProvider).valueOrNull;
    if (fb == null || cfg == null) return;
    try {
      await fb.saveRule(cfg.homeId, r.id, delete ? null : r.toJson());
      // tell every board to pull the new rules right now
      await ref.read(homeProvider.notifier).runSyncAll();
      await _load();
    } catch (e) {
      if (mounted) toast(context, 'Could not save: $e');
    }
  }

  Future<void> _edit(RuleModel? existing) async {
    final nodes = ref.read(homeProvider).nodes.values.toList();
    if (nodes.isEmpty) return toast(context, 'Add a board first');
    final r = await Navigator.push<RuleModel>(
      context,
      MaterialPageRoute(builder: (_) => RuleEditorPage(rule: existing ?? RuleModel(id: randomId(8), node: nodes.first.id))),
    );
    if (r != null) await _save(r);
  }

  @override
  Widget build(BuildContext context) {
    final tr = ref.watch(trProvider);
    final nodes = ref.watch(homeProvider.select((s) => s.nodes));
    return Scaffold(
      appBar: AppBar(title: Text(tr.automations), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(null), icon: const Icon(Icons.add), label: const Text('New rule')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
          : _rules == null
              ? const Center(child: CircularProgressIndicator())
              : _rules!.isEmpty
                  ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No automations yet.\nExample: "Fan on when temperature is above 30 °C".', textAlign: TextAlign.center)))
                  : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
                      for (final r in _rules!)
                        Card(
                          child: ListTile(
                            title: Text(r.name.isEmpty ? r.id : r.name),
                            subtitle: Text('${nodes[r.node]?.title ?? r.node} · ${r.describe()}\n→ ${r.then.map((a) => a.scene.isNotEmpty ? 'scene ${a.scene}' : '${a.dev} ${a.on ? 'on' : 'off'}').join(', ')}'),
                            isThreeLine: true,
                            onTap: () => _edit(r),
                            trailing: Switch(value: r.enabled, onChanged: (v) { r.enabled = v; _save(r); }),
                            onLongPress: () async {
                              if (await confirm(context, 'Delete rule?', r.name, action: 'Delete')) _save(r, delete: true);
                            },
                          ),
                        ),
                    ]),
    );
  }
}

class RuleEditorPage extends ConsumerStatefulWidget {
  const RuleEditorPage({super.key, required this.rule});
  final RuleModel rule;
  @override
  ConsumerState<RuleEditorPage> createState() => _RuleEditorPageState();
}

class _RuleEditorPageState extends ConsumerState<RuleEditorPage> {
  late RuleModel r;
  late final TextEditingController _name, _value;
  RuleAction _act = const RuleAction();

  static const _dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

  @override
  void initState() {
    super.initState();
    r = widget.rule;
    _name = TextEditingController(text: r.name);
    _value = TextEditingController(text: r.value == 0 && r.cType == 'time' ? '' : r.value.toStringAsFixed(0));
    if (r.then.isNotEmpty) _act = r.then.first;
  }

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<String?> _pickTime(String initial) async {
    final p = initial.split(':');
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.tryParse(p[0]) ?? 18, minute: int.tryParse(p.length > 1 ? p[1] : '0') ?? 0));
    if (t == null) return null;
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final nodes = ref.watch(homeProvider.select((s) => s.nodes));
    final node = nodes[r.node];
    final devs = node?.devices ?? const <DeviceInfo>[];
    final switches = devs.where((d) => d.controllable && !d.isLock).toList();
    final sensors = devs.where((d) => d.isPir).toList();
    final numeric = r.cType == 'temp' || r.cType == 'hum' || r.cType == 'power';

    return Scaffold(
      appBar: AppBar(title: const Text('Automation')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name', hintText: 'Fan when hot')),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: nodes.containsKey(r.node) ? r.node : null,
          decoration: const InputDecoration(labelText: 'Runs on board (uses its sensors)'),
          items: [for (final n in nodes.values) DropdownMenuItem(value: n.id, child: Text(n.title))],
          onChanged: (v) => setState(() { r.node = v ?? r.node; _act = const RuleAction(); }),
        ),
        const SizedBox(height: 18),
        const Text('IF', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: r.cType,
          decoration: const InputDecoration(labelText: 'Condition'),
          items: const [
            DropdownMenuItem(value: 'time', child: Text('At a time of day')),
            DropdownMenuItem(value: 'temp', child: Text('Temperature')),
            DropdownMenuItem(value: 'hum', child: Text('Humidity')),
            DropdownMenuItem(value: 'power', child: Text('Power use (W)')),
            DropdownMenuItem(value: 'motion', child: Text('Motion detected')),
            DropdownMenuItem(value: 'dev', child: Text('A device is on / off')),
          ],
          onChanged: (v) => setState(() => r.cType = v ?? 'time'),
        ),
        const SizedBox(height: 10),
        if (r.cType == 'time')
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.schedule), title: Text('At ${r.at}'), onTap: () async {
            final t = await _pickTime(r.at);
            if (t != null) setState(() => r.at = t);
          }),
        if (numeric)
          Row(children: [
            SizedBox(
              width: 110,
              child: DropdownButtonFormField<String>(
                initialValue: r.op,
                items: const [DropdownMenuItem(value: '>', child: Text('above')), DropdownMenuItem(value: '<', child: Text('below'))],
                onChanged: (v) => setState(() => r.op = v ?? '>'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _value, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: InputDecoration(labelText: r.cType == 'temp' ? '°C' : r.cType == 'hum' ? '%' : 'Watts'))),
          ]),
        if (r.cType == 'motion')
          DropdownButtonFormField<String>(
            initialValue: sensors.any((d) => d.id == r.cDev) ? r.cDev : null,
            decoration: InputDecoration(labelText: 'Motion sensor', helperText: sensors.isEmpty ? 'Add a PIR device to this board first' : null),
            items: [for (final d in sensors) DropdownMenuItem(value: d.id, child: Text(d.name))],
            onChanged: (v) => setState(() => r.cDev = v ?? ''),
          ),
        if (r.cType == 'dev') ...[
          DropdownButtonFormField<String>(
            initialValue: devs.any((d) => d.id == r.cDev) ? r.cDev : null,
            decoration: const InputDecoration(labelText: 'Device'),
            items: [for (final d in devs) DropdownMenuItem(value: d.id, child: Text(d.name))],
            onChanged: (v) => setState(() => r.cDev = v ?? ''),
          ),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(r.value > 0.5 ? 'is ON' : 'is OFF'), value: r.value > 0.5, onChanged: (v) => setState(() => r.value = v ? 1 : 0)),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 6, children: [
          for (var i = 0; i < 7; i++)
            FilterChip(label: Text(_dayNames[i]), selected: (r.days >> i) & 1 == 1, onSelected: (s) => setState(() => r.days = s ? r.days | (1 << i) : r.days & ~(1 << i))),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(r.from == null ? 'Only between certain hours' : 'Only between ${r.from} and ${r.to}'),
          value: r.from != null,
          onChanged: (v) => setState(() { r.from = v ? '18:00' : null; r.to = v ? '23:00' : null; }),
        ),
        if (r.from != null)
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () async { final t = await _pickTime(r.from!); if (t != null) setState(() => r.from = t); }, child: Text('From ${r.from}'))),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton(onPressed: () async { final t = await _pickTime(r.to!); if (t != null) setState(() => r.to = t); }, child: Text('To ${r.to}'))),
          ]),
        const SizedBox(height: 18),
        const Text('THEN', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: _act.scene.isNotEmpty ? 'scene:${_act.scene}' : (switches.any((d) => d.id == _act.dev) ? _act.dev : null),
          decoration: const InputDecoration(labelText: 'Do this'),
          items: [
            for (final d in switches) DropdownMenuItem(value: d.id, child: Text(d.name)),
            const DropdownMenuItem(value: 'scene:alloff', child: Text('Scene: all off')),
            const DropdownMenuItem(value: 'scene:goodnight', child: Text('Scene: good night')),
          ],
          onChanged: (v) => setState(() {
            if (v == null) return;
            _act = v.startsWith('scene:') ? RuleAction(scene: v.substring(6)) : RuleAction(dev: v, on: _act.on, forSec: _act.forSec);
          }),
        ),
        if (_act.scene.isEmpty) ...[
          SwitchListTile(contentPadding: EdgeInsets.zero, title: Text('Switch ${_act.on ? 'ON' : 'OFF'}'), value: _act.on, onChanged: (v) => setState(() => _act = RuleAction(dev: _act.dev, on: v, forSec: _act.forSec))),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Revert when the condition ends'), subtitle: const Text('e.g. fan off again when it cools down'), value: r.revert, onChanged: (v) => setState(() => r.revert = v)),
        ],
        const SizedBox(height: 18),
        Text('Doors are never unlocked by automations.', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
        const SizedBox(height: 12),
        FilledButton(onPressed: _done, child: const Text('Save automation')),
      ]),
    );
  }

  void _done() {
    if (_name.text.trim().isEmpty) return toast(context, 'Please name the automation');
    if (_act.dev.isEmpty && _act.scene.isEmpty) return toast(context, 'Choose what should happen');
    if ((r.cType == 'motion' || r.cType == 'dev') && r.cDev.isEmpty) return toast(context, 'Choose the device for the condition');
    if (r.cType == 'temp' || r.cType == 'hum' || r.cType == 'power') {
      final v = double.tryParse(_value.text.trim());
      if (v == null) return toast(context, 'Enter a number for the condition');
      r.value = v;
    }
    if (r.days == 0) return toast(context, 'Choose at least one day');
    r.name = cleanName(_name.text);
    r.then = [_act];
    Navigator.pop(context, r);
  }
}
