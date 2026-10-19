/// App side remote access: the phone's own MQTT broker login (to control
/// the boards from anywhere) and the cloud database used for sync.
library;

import 'package:flutter/material.dart';

import '../esp32_api.dart';
import '../settings.dart';
import 'advanced_page.dart' show toast, tx;
import 'cloud_service.dart';
import 'mqtt_service.dart';
import 'pro_settings.dart';

class RemotePage extends StatefulWidget {
  const RemotePage({super.key, required this.settings, this.esp});
  final SettingsController settings;
  final Esp32Controller? esp;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  ProController? _pro;
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _base = TextEditingController();
  final _cloudUrl = TextEditingController();
  final _cloudKey = TextEditingController();
  final _node = TextEditingController();
  bool _tls = true;
  bool _remote = false;
  String _provider = 'off';
  bool _busy = false;

  String t(String hi, String en) => tx(widget.settings, hi, en);

  @override
  void initState() {
    super.initState();
    ProController.instance().then((p) {
      final s = p.value;
      _host.text = s.mqttHost;
      _port.text = '${s.mqttPort}';
      _user.text = s.mqttUser;
      _pass.text = s.mqttPass;
      _base.text = s.mqttBase;
      _cloudUrl.text = s.cloudUrl;
      _cloudKey.text = s.cloudKey;
      _node.text = widget.esp?.state?.node.isNotEmpty == true ? widget.esp!.state!.node : s.node;
      if (mounted) {
        setState(() {
          _pro = p;
          _tls = s.mqttTls;
          _remote = s.mqttRemote;
          _provider = s.cloudProvider;
        });
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _pass, _base, _cloudUrl, _cloudKey, _node]) {
      c.dispose();
    }
    super.dispose();
  }

  ProSettings _collect() => _pro!.value.copyWith(
        mqttHost: _host.text.trim(),
        mqttPort: int.tryParse(_port.text.trim()) ?? 8883,
        mqttUser: _user.text.trim(),
        mqttPass: _pass.text,
        mqttBase: _base.text.trim().isEmpty ? 'smarthome' : _base.text.trim(),
        mqttTls: _tls,
        mqttRemote: _remote,
        cloudProvider: _provider,
        cloudUrl: _cloudUrl.text.trim(),
        cloudKey: _cloudKey.text.trim(),
        node: _node.text.trim(),
      );

  Future<void> _save({bool test = false}) async {
    final s = _collect();
    await _pro!.update(s);
    if (!test) {
      if (mounted) toast(context, t('सेव हो गया', 'Saved'));
      return;
    }
    setState(() => _busy = true);
    final msgs = <String>[];
    if (s.mqttReady) {
      final err = await MqttService.instance.connect(s);
      msgs.add(err ?? 'MQTT OK');
    }
    if (s.cloudReady && s.node.isNotEmpty) {
      final cloud = CloudService(s);
      try {
        final st = await cloud.state(s.node);
        msgs.add(st == null ? 'Cloud OK (no state yet)' : 'Cloud OK');
        await cloud.saveRooms(s.node, widget.settings.value.rooms);
      } catch (e) {
        msgs.add('$e');
      } finally {
        cloud.close();
      }
    }
    if (mounted) {
      setState(() => _busy = false);
      toast(context, msgs.isEmpty ? t('कुछ सेट नहीं है', 'Nothing configured') : msgs.join(' • '));
    }
  }

  Widget _tf(TextEditingController c, String label, {bool secret = false, TextInputType? kb}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: TextField(
          controller: c,
          obscureText: secret,
          keyboardType: kb,
          autocorrect: false,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        ),
      );

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
      );

  @override
  Widget build(BuildContext context) {
    if (_pro == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(t('रिमोट एक्सेस', 'Remote access'))),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            t('ये लॉगिन सिर्फ़ इस फ़ोन में सेव होते हैं। बोर्ड के लिए "बोर्ड सेटिंग्स" में अलग से डालें।',
                'These logins are stored only on this phone. The board has its own copy in "Board settings".'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        _section('MQTT'),
        _tf(_host, 'Broker host'),
        _tf(_port, 'Port', kb: TextInputType.number),
        _tf(_user, 'Username'),
        _tf(_pass, 'Password', secret: true),
        _tf(_base, 'Base topic'),
        SwitchListTile(title: const Text('TLS'), value: _tls, onChanged: (v) => setState(() => _tls = v)),
        SwitchListTile(
          title: Text(t('बोर्ड न मिले तो MQTT से कंट्रोल करें', 'Use MQTT when the board is not reachable')),
          value: _remote,
          onChanged: (v) => setState(() => _remote = v),
        ),
        _section(t('क्लाउड डेटाबेस', 'Cloud database')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'off', label: Text('Off')),
              ButtonSegment(value: 'firebase', label: Text('Firebase')),
              ButtonSegment(value: 'supabase', label: Text('Supabase')),
            ],
            selected: {_provider},
            onSelectionChanged: (s) => setState(() => _provider = s.first),
          ),
        ),
        _tf(_cloudUrl, 'URL (https://...)'),
        _tf(_cloudKey, 'Key', secret: true),
        _tf(_node, 'Board node id'),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _save(), child: Text(t('सेव', 'Save')))),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _save(test: true),
                child: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(t('सेव + टेस्ट', 'Save + test')),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
