/// Live energy monitor: real meter values (PZEM-004T / ACS712) per room, or
/// the relay based estimate when no meter is fitted.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../settings.dart';
import 'advanced_page.dart' show toast, tx;
import 'board_api.dart';

class EnergyPage extends StatefulWidget {
  const EnergyPage({super.key, required this.settings});
  final SettingsController settings;

  @override
  State<EnergyPage> createState() => _EnergyPageState();
}

class _EnergyPageState extends State<EnergyPage> {
  late final BoardApi _api = BoardApi(widget.settings);
  Timer? _timer;
  Map<String, dynamic>? _data;
  String? _error;

  String t(String hi, String en) => tx(widget.settings, hi, en);

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _api.close();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final d = await _api.get('/api/energy');
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _n(Object? v, int digits, String unit) => v is num ? '${v.toStringAsFixed(digits)} $unit' : '—';

  Widget _card(String title, Map<String, dynamic> m) {
    final theme = Theme.of(context);
    Widget cell(String label, String value) => Expanded(
          child: Column(children: [
            Text(value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label, style: theme.textTheme.bodySmall),
          ]),
        );
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
            if (m['ok'] == false) Text(t('मीटर जवाब नहीं दे रहा', 'meter not answering'), style: theme.textTheme.bodySmall),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            cell(t('वोल्टेज', 'Voltage'), _n(m['v'], 1, 'V')),
            cell(t('करंट', 'Current'), _n(m['a'], 2, 'A')),
            cell(t('पावर', 'Power'), _n(m['w'], 0, 'W')),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            cell(t('एनर्जी', 'Energy'), _n(m['kwh'], 2, 'kWh')),
            cell('PF', _n(m['pf'], 2, '')),
            cell(t('फ़्रीक्वेंसी', 'Frequency'), _n(m['hz'], 1, 'Hz')),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rooms = widget.settings.value.rooms;
    final d = _data;
    final meter = d?['meter'];
    final meters = (d?['meters'] as List?) ?? const [];
    return Scaffold(
      appBar: AppBar(title: Text(t('एनर्जी मॉनिटर', 'Energy monitor')), actions: [
        IconButton(
          tooltip: t('kWh रीसेट', 'Reset kWh'),
          icon: const Icon(Icons.restart_alt),
          onPressed: meter == null
              ? null
              : () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      content: Text(t('सभी kWh काउंटर 0 करें?', 'Reset all kWh counters to 0?')),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK')),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  try {
                    await _api.post('/api/meter/reset');
                    if (context.mounted) toast(context, 'OK');
                  } catch (e) {
                    if (context.mounted) toast(context, '$e');
                  }
                },
        ),
      ]),
      body: d == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
              if (meter is Map<String, dynamic>) ...[
                _card(t('पूरा घर', 'Whole board'), meter),
                for (final m in meters)
                  if (m is Map<String, dynamic>)
                    _card(
                      (m['room'] is int && (m['room'] as int) < rooms.length) ? rooms[m['room'] as int] : 'Room ${(m['room'] ?? 0) + 1}',
                      m,
                    ),
              ] else
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    t('कोई मीटर सेट नहीं है। अनुमान: ${_n(d['estimateW'], 0, 'W')}\nबोर्ड सेटिंग्स → एनर्जी मीटर में PZEM-004T या ACS712 चुनें।',
                        'No meter configured. Estimate: ${_n(d['estimateW'], 0, 'W')}\nChoose PZEM-004T or ACS712 in Board settings → Energy meter.'),
                  ),
                ),
            ]),
    );
  }
}
