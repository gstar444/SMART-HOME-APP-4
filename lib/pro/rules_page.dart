/// Remote rules engine editor. Rules run ON THE BOARD (rules_engine.h), are
/// saved there over HTTP and, when a cloud is configured, also written to the
/// cloud database so every board/phone stays in sync.
library;

import 'package:flutter/material.dart';

import '../esp32_api.dart';
import '../settings.dart';
import 'advanced_page.dart' show toast, tx;
import 'board_api.dart';
import 'cloud_service.dart';
import 'pro_settings.dart';

/// One automation rule (same JSON as the firmware).
class AutoRule {
  AutoRule({
    required this.id,
    this.name = '',
    this.enabled = true,
    this.src = 'temp',
    this.op = '>',
    this.val = '30',
    List<Map<String, dynamic>>? actions,
    this.cool = 60,
  }) : actions = actions ?? [];

  String id;
  String name;
  bool enabled;
  String src; // temp | hum | power | dev:<id> | motion:<id> | time
  String op;
  String val; // number, 1/0 or HH:MM
  List<Map<String, dynamic>> actions;
  int cool;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'on': enabled,
        'when': {
          'src': src,
          'op': op,
          'val': src == 'time' ? val : (num.tryParse(val) ?? 0),
        },
        'do': actions,
        'cool': cool,
      };

  factory AutoRule.fromJson(Map<String, dynamic> j) {
    final w = (j['when'] as Map?)?.cast<String, dynamic>() ?? {};
    return AutoRule(
      id: '${j['id'] ?? ''}',
      name: '${j['name'] ?? ''}',
      enabled: j['on'] != false,
      src: '${w['src'] ?? 'temp'}',
      op: '${w['op'] ?? '>'}',
      val: '${w['val'] ?? ''}',
      actions: [
        for (final a in (j['do'] as List? ?? const []))
          if (a is Map) a.cast<String, dynamic>(),
      ],
      cool: (j['cool'] as num?)?.toInt() ?? 60,
    );
  }

  String describe() {
    final what = actions.map((a) {
      if (a['scene'] != null) return 'scene ${a['scene']}';
      if (a['room'] != null) return 'Room ${(a['room'] as num) + 1} ${a['on'] == true ? 'ON' : 'OFF'}';
      return '${a['id']} ${a['on'] == true ? 'ON' : 'OFF'}';
    }).join(', ');
    return 'IF $src $op $val  →  $what';
  }
}

class RulesPage extends StatefulWidget {
  const RulesPage({super.key, required this.settings, this.esp});
  final SettingsController settings;
  final Esp32Controller? esp;

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  late final BoardApi _api = BoardApi(widget.settings);
  List<AutoRule> _rules = [];
  bool _loading = true;
  String? _error;

  String t(String hi, String en) => tx(widget.settings, hi, en);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await _api.get('/api/rules');
      _rules = [
        for (final x in (r['rules'] as List? ?? const []))
          if (x is Map) AutoRule.fromJson(x.cast<String, dynamic>()),
      ];
      _error = null;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final list = [for (final r in _rules) r.toJson()];
    try {
      await _api.post('/api/rules', list);
      final pro = await ProController.instance();
      final node = widget.esp?.state?.node ?? pro.value.node;
      if (pro.value.cloudReady && node.isNotEmpty) {
        final cloud = CloudService(pro.value);
        try {
          await cloud.saveRules(node, list);
        } finally {
          cloud.close();
        }
      }
      if (mounted) toast(context, t('नियम सेव हुए', 'Rules saved'));
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<void> _edit(AutoRule? rule) async {
    final devices = widget.esp?.state?.devices ?? const [];
    final r = rule ??
        AutoRule(id: 'r${DateTime.now().millisecondsSinceEpoch % 100000}', actions: [
          if (devices.isNotEmpty) {'id': devices.first.id, 'on': true},
        ]);
    final edited = await showDialog<AutoRule>(
      context: context,
      builder: (_) => _RuleDialog(rule: AutoRule.fromJson(r.toJson()), devices: devices, t: t),
    );
    if (edited == null) return;
    setState(() {
      final i = _rules.indexWhere((x) => x.id == edited.id);
      if (i >= 0) {
        _rules[i] = edited;
      } else {
        _rules.add(edited);
      }
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('ऑटोमेशन नियम', 'Automation rules'))),
      floatingActionButton: FloatingActionButton(
        onPressed: _loading || _error != null ? null : () => _edit(null),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
              : _rules.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(t('अभी कोई नियम नहीं। + दबाएँ, जैसे "तापमान > 30 तो पंखा चालू"।',
                            'No rules yet. Tap + e.g. "temperature > 30 → fan ON".')),
                      ),
                    )
                  : ListView(children: [
                      for (final r in _rules)
                        ListTile(
                          leading: Switch(
                            value: r.enabled,
                            onChanged: (v) {
                              setState(() => r.enabled = v);
                              _save();
                            },
                          ),
                          title: Text(r.name.isEmpty ? r.id : r.name),
                          subtitle: Text(r.describe()),
                          onTap: () => _edit(r),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              setState(() => _rules.remove(r));
                              _save();
                            },
                          ),
                        ),
                    ]),
    );
  }
}

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({required this.rule, required this.devices, required this.t});
  final AutoRule rule;
  final List<dynamic> devices;
  final String Function(String, String) t;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final AutoRule r = widget.rule;
  late final TextEditingController _name = TextEditingController(text: r.name);
  late final TextEditingController _val = TextEditingController(text: r.val);
  late final TextEditingController _cool = TextEditingController(text: '${r.cool}');

  @override
  void dispose() {
    _name.dispose();
    _val.dispose();
    _cool.dispose();
    super.dispose();
  }

  List<DropdownMenuItem<String>> get _sources => [
        const DropdownMenuItem(value: 'temp', child: Text('Temperature °C')),
        const DropdownMenuItem(value: 'hum', child: Text('Humidity %')),
        const DropdownMenuItem(value: 'power', child: Text('Power W')),
        const DropdownMenuItem(value: 'time', child: Text('Time HH:MM')),
        for (final d in widget.devices)
          DropdownMenuItem(
            value: d.type == 'pir' ? 'motion:${d.id}' : 'dev:${d.id}',
            child: Text('${d.name} (1/0)', overflow: TextOverflow.ellipsis),
          ),
      ];

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final sources = _sources;
    if (!sources.any((s) => s.value == r.src)) r.src = 'temp';
    final controllable = [for (final d in widget.devices) if (d.type != 'pir') d];
    return AlertDialog(
      title: Text(t('नियम', 'Rule')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _name, decoration: InputDecoration(labelText: t('नाम', 'Name'))),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              flex: 3,
              child: DropdownButton<String>(
                isExpanded: true,
                value: r.src,
                items: sources,
                onChanged: (v) => setState(() => r.src = v ?? 'temp'),
              ),
            ),
            const SizedBox(width: 8),
            if (r.src != 'time')
              DropdownButton<String>(
                value: r.op,
                items: const ['>', '<', '>=', '<=', '==', '!=']
                    .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                    .toList(),
                onChanged: (v) => setState(() => r.op = v ?? '>'),
              ),
          ]),
          TextField(
            controller: _val,
            decoration: InputDecoration(labelText: r.src == 'time' ? 'HH:MM' : t('मान', 'Value')),
          ),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: Text(t('तब करें:', 'Then:'))),
          for (var i = 0; i < r.actions.length; i++)
            Row(children: [
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: controllable.any((d) => d.id == r.actions[i]['id']) ? r.actions[i]['id'] as String : null,
                  items: [
                    for (final d in controllable)
                      DropdownMenuItem(value: d.id as String, child: Text(d.name as String, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => r.actions[i] = {'id': v, 'on': r.actions[i]['on'] == true}),
                ),
              ),
              Switch(
                value: r.actions[i]['on'] == true,
                onChanged: (v) => setState(() => r.actions[i] = {...r.actions[i], 'on': v}),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => r.actions.removeAt(i)),
              ),
            ]),
          if (controllable.isNotEmpty && r.actions.length < 4)
            TextButton.icon(
              onPressed: () => setState(() => r.actions.add({'id': controllable.first.id, 'on': true})),
              icon: const Icon(Icons.add),
              label: Text(t('एक्शन जोड़ें', 'Add action')),
            ),
          TextField(
            controller: _cool,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: t('दोबारा चलने से पहले (सेकंड)', 'Cool-down (s)')),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t('रद्द', 'Cancel'))),
        FilledButton(
          onPressed: () {
            r
              ..name = _name.text.trim()
              ..val = _val.text.trim()
              ..cool = int.tryParse(_cool.text.trim()) ?? 60;
            Navigator.pop(context, r);
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}
