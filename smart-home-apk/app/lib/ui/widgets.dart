import 'package:flutter/material.dart';

import '../core/strings.dart';
import '../core/theme.dart';
import '../models/models.dart';

const List<String> kSwitchIcons = ['light', 'fan', 'heater', 'curtain', 'purifier', 'siren', 'plug'];
const List<String> kAllIcons = [...kSwitchIcons, 'lock', 'pir'];

String typeForIcon(String icon) => icon == 'lock' ? 'lock' : icon == 'pir' ? 'pir' : 'switch';

List<String> iconsForType(String type) => type == 'lock' ? const ['lock'] : type == 'pir' ? const ['pir'] : kSwitchIcons;

IconData iconFor(String icon, bool on) {
  switch (icon) {
    case 'light':
      return on ? Icons.lightbulb : Icons.lightbulb_outline;
    case 'fan':
      return Icons.toys;
    case 'heater':
      return Icons.local_fire_department;
    case 'curtain':
      return Icons.blinds;
    case 'purifier':
      return Icons.air;
    case 'siren':
      return Icons.notifications_active;
    case 'lock':
      return on ? Icons.lock : Icons.lock_open;
    case 'pir':
      return Icons.sensors;
    default:
      return Icons.power;
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.label, this.color, {super.key, this.onTap});
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

/// Tiny line chart (no chart package: keeps the app small and starts faster).
class Sparkline extends StatelessWidget {
  const Sparkline(this.values, {super.key, this.color = kAccent, this.height = 42});
  final List<double> values;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: values.length < 2 ? const SizedBox.shrink() : CustomPaint(painter: _SparkPainter(values, color)),
      );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.v, this.color);
  final List<double> v;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = v.reduce((a, b) => a < b ? a : b);
    final hi = v.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo).abs() < 0.001 ? 1.0 : hi - lo;
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final x = size.width * i / (v.length - 1);
      final y = size.height - 4 - (size.height - 8) * ((v[i] - lo) / span);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.12));
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.v != v || old.color != color;
}

class PowerCard extends StatelessWidget {
  const PowerCard({super.key, required this.node, required this.history, required this.tr, this.tariff = 0, this.currency = ''});
  final NodeInfo node;
  final List<double> history;
  final Tr tr;
  final double tariff;
  final String currency;

  String _f(double? v, int d, String unit) => v == null ? '–' : '${v.toStringAsFixed(d)} $unit';

  @override
  Widget build(BuildContext context) {
    final p = node.power!;
    final cs = Theme.of(context).colorScheme;
    Widget stat(String label, String value) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Icon(Icons.bolt, color: kWarn, size: 22),
          const SizedBox(width: 4),
          Text(p.w == null ? '–' : p.w!.toStringAsFixed(p.w! < 100 ? 1 : 0),
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, height: 1)),
          const SizedBox(width: 4),
          Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(p.src == 'acs' ? 'VA' : 'W', style: const TextStyle(fontSize: 14))),
          const Spacer(),
          if (p.estimated || p.src == 'acs')
            Text(p.estimated ? tr.estimate : 'apparent', style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.5))),
        ]),
        const SizedBox(height: 6),
        Sparkline(history, color: cs.primary),
        const SizedBox(height: 8),
        Row(children: [
          stat(tr.voltage, _f(p.v, 0, 'V')),
          stat(tr.current, _f(p.i, 2, 'A')),
          stat(p.src == 'pzem' ? 'PF · Hz' : '', p.src == 'pzem' ? '${p.pf?.toStringAsFixed(2) ?? '–'} · ${p.hz?.toStringAsFixed(0) ?? '–'}' : ''),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          stat(tr.today, '${p.kwhToday.toStringAsFixed(2)} kWh${tariff > 0 ? '  ≈ $currency${(p.kwhToday * tariff).toStringAsFixed(1)}' : ''}'),
          stat(tr.total, '${p.kwh.toStringAsFixed(1)} kWh'),
        ]),
      ]),
    );
  }
}

class DeviceTile extends StatelessWidget {
  const DeviceTile({super.key, required this.device, required this.onToggle, required this.onMenu, required this.enabled});
  final DeviceInfo device;
  final VoidCallback onToggle, onMenu;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = device.on;
    final accent = device.isLock ? (on ? kGood : kWarn) : cs.primary;
    final active = device.isPir ? on : on;
    final status = device.isPir
        ? (on ? 'Motion' : 'Clear')
        : device.isLock
            ? (on ? 'Locked' : 'Unlocked')
            : (on ? 'On' : 'Off');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: device.controllable && enabled ? onToggle : null,
        onLongPress: onMenu,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: active ? accent.withValues(alpha: 0.18) : cs.onSurface.withValues(alpha: 0.07), shape: BoxShape.circle),
                child: Icon(iconFor(device.icon, on), color: active ? accent : cs.onSurface.withValues(alpha: 0.5)),
              ),
              const Spacer(),
              if (device.controllable)
                Switch(value: on, onChanged: enabled ? (_) => onToggle() : null, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
              InkWell(onTap: onMenu, borderRadius: BorderRadius.circular(20), child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.more_vert, size: 18))),
            ]),
            const SizedBox(height: 10),
            Text(device.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(status, style: TextStyle(fontSize: 12, color: active ? accent : cs.onSurface.withValues(alpha: 0.5))),
          ]),
        ),
      ),
    );
  }
}

class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key, this.height = 140});
  final double height;
  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(20)),
      );
}

Future<String?> askText(BuildContext context, {required String title, String initial = '', String? hint, TextInputType? type}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, keyboardType: type, decoration: InputDecoration(hintText: hint)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String message, {String action = 'Yes'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return r == true;
}

void toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
