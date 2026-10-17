import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../models/models.dart';
import '../state/home_controller.dart';

/// Daily energy per board (kWh), read from Firebase where each board stores one value per day.
class EnergyPage extends ConsumerStatefulWidget {
  const EnergyPage({super.key});
  @override
  ConsumerState<EnergyPage> createState() => _EnergyPageState();
}

class _EnergyPageState extends ConsumerState<EnergyPage> {
  final Map<String, Map<String, double>> _data = {};
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final fb = ref.read(firebaseProvider);
    final cfg = ref.read(settingsProvider).valueOrNull;
    final nodes = ref.read(homeProvider).nodes.values.where((n) => n.hasPower).toList();
    if (fb == null || cfg == null) {
      setState(() { _loading = false; _error = 'Energy history is stored in the cloud database. Set up Firebase in Settings.'; });
      return;
    }
    try {
      for (final n in nodes) {
        _data[n.id] = await fb.energy(cfg.homeId, n.id);
      }
      if (mounted) setState(() { _loading = false; _error = null; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = ref.watch(trProvider);
    final cfg = ref.watch(settingsProvider).valueOrNull;
    final nodes = ref.watch(homeProvider.select((s) => s.nodes.values.where((n) => n.hasPower).toList()));
    return Scaffold(
      appBar: AppBar(title: Text(tr.energy), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
              : nodes.isEmpty
                  ? const Center(child: Text('No board reports power yet.'))
                  : ListView(padding: const EdgeInsets.all(16), children: [
                      for (final n in nodes) ...[_NodeEnergy(node: n, days: _data[n.id] ?? const {}, tariff: cfg?.tariff ?? 0, currency: cfg?.currency ?? ''), const SizedBox(height: 14)],
                    ]),
    );
  }
}

class _NodeEnergy extends StatelessWidget {
  const _NodeEnergy({required this.node, required this.days, required this.tariff, required this.currency});
  final NodeInfo node;
  final Map<String, double> days;
  final double tariff;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final keys = days.keys.toList()..sort();
    final values = [for (final k in keys) days[k]!];
    final total = values.fold<double>(0, (a, b) => a + b);
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(node.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          Text('${total.toStringAsFixed(2)} kWh in ${values.length} day(s)${tariff > 0 ? '  ≈ $currency${(total * tariff).toStringAsFixed(0)}' : ''}'),
          const SizedBox(height: 12),
          if (values.isEmpty)
            const Text('No history yet. Boards upload one value per day.')
          else
            SizedBox(height: 120, child: CustomPaint(painter: _BarPainter(values, keys, cs.primary, cs.onSurface), size: Size.infinite)),
        ]),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.v, this.keys, this.color, this.text);
  final List<double> v;
  final List<String> keys;
  final Color color, text;

  @override
  void paint(Canvas canvas, Size size) {
    final hi = v.reduce((a, b) => a > b ? a : b);
    final top = hi <= 0 ? 1.0 : hi;
    final slot = size.width / v.length;
    final barW = slot * 0.6;
    for (var i = 0; i < v.length; i++) {
      final h = (size.height - 18) * (v[i] / top);
      final x = i * slot + (slot - barW) / 2;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - 18 - h, barW, h < 2 ? 2 : h), const Radius.circular(4)), Paint()..color = color.withValues(alpha: 0.85));
      if (v.length <= 8 || i % 2 == 0) {
        final tp = TextPainter(text: TextSpan(text: keys[i].substring(6), style: TextStyle(fontSize: 9, color: text.withValues(alpha: 0.6))), textDirection: TextDirection.ltr)..layout();
        tp.paint(canvas, Offset(x + (barW - tp.width) / 2, size.height - 14));
      }
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.v != v;
}
