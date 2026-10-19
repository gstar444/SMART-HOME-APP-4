/// Edits the board's runtime configuration (firmware runtime_config.h).
/// Works over any transport: HTTP (/api/cmd) or BLE - both speak the same
/// command language ({"op":"config_get"} / {"op":"config_set","cfg":{...}}).
/// Secrets are never shown: an empty secret field means "keep the stored one".
library;

import 'package:flutter/material.dart';

import '../settings.dart';
import 'advanced_page.dart' show toast, tx;

typedef BoardSend = Future<Map<String, dynamic>> Function(Map<String, dynamic> cmd);

class BoardConfigPage extends StatefulWidget {
  const BoardConfigPage({super.key, required this.settings, required this.send, required this.title, this.extraTop});

  final SettingsController settings;
  final BoardSend send;
  final String title;

  /// Optional widget shown above the form (e.g. Wi-Fi fields for BLE setup).
  final Widget? extraTop;

  @override
  State<BoardConfigPage> createState() => _BoardConfigPageState();
}

class _F {
  _F(this.path, this.label, {this.secret = false, this.number = false, this.hint, this.multiline = false});
  final List<String> path; // e.g. ['mqtt','host']
  final String label;
  final bool secret;
  final bool number;
  final bool multiline;
  final String? hint;
  final TextEditingController c = TextEditingController();
  bool storedSecret = false;
}

class _B {
  _B(this.path, this.label);
  final List<String> path;
  final String label;
  bool value = false;
}

class _BoardConfigPageState extends State<BoardConfigPage> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  Map<String, dynamic> _cfg = {};
  String _cloud = 'off';
  String _meter = 'none';

  String t(String hi, String en) => tx(widget.settings, hi, en);

  late final List<_F> _fields = [
    _F(['node'], 'Node id (a-z 0-9 - _)'),
    _F(['apiKey'], 'API key (board)', secret: true),
    _F(['mqtt', 'host'], 'MQTT broker host', hint: 'xxxx.s1.eu.hivemq.cloud'),
    _F(['mqtt', 'port'], 'MQTT port', number: true, hint: '8883'),
    _F(['mqtt', 'user'], 'MQTT username'),
    _F(['mqtt', 'pass'], 'MQTT password', secret: true),
    _F(['mqtt', 'base'], 'MQTT base topic', hint: 'smarthome'),
    _F(['mqtt', 'ca'], 'CA certificate (PEM, optional)', secret: true, multiline: true),
    _F(['telegram', 'token'], 'Telegram bot token', secret: true),
    _F(['telegram', 'chats'], 'Allowed chat IDs (comma separated)', hint: '123456789,-100123...'),
    _F(['ai', 'url'], 'AI endpoint (OpenAI compatible)'),
    _F(['ai', 'model'], 'AI model', hint: 'gpt-4o-mini'),
    _F(['ai', 'key'], 'AI API key', secret: true),
    _F(['sinric', 'key'], 'Sinric Pro APP KEY', secret: true),
    _F(['sinric', 'secret'], 'Sinric Pro APP SECRET', secret: true),
    _F(['sinric', 'map'], 'Sinric map: sinricId=deviceId,...'),
    _F(['cloud', 'url'], 'Cloud URL (https://...)'),
    _F(['cloud', 'key'], 'Cloud key (Firebase secret / Supabase key)', secret: true),
    _F(['cloud', 'interval'], 'Cloud sync interval (s)', number: true),
    _F(['otaPass'], 'OTA password', secret: true),
    _F(['meter', 'rx'], 'PZEM RX pin', number: true),
    _F(['meter', 'tx'], 'PZEM TX pin', number: true),
    _F(['meter', 'addrs'], 'PZEM addresses (CSV, 248 = single)'),
    _F(['meter', 'pins'], 'ACS712 ADC pins (CSV, 32-39)'),
    _F(['meter', 'rooms'], 'Room of each meter (CSV, 0 = Room 1)'),
    _F(['meter', 'mvPerA'], 'ACS712 mV per A (185/100/66)', number: true),
    _F(['meter', 'divider'], 'ACS712 divider ratio', number: true),
    _F(['meter', 'mainsV'], 'Mains voltage', number: true),
    _F(['offline', 'timeout'], 'Offline timeout (s) before emergency hotspot', number: true),
    _F(['tz'], 'Time zone (POSIX)', hint: 'IST-5:30'),
  ];

  late final List<_B> _bools = [
    _B(['mqtt', 'tls'], 'MQTT TLS (recommended)'),
    _B(['mqtt', 'insecure'], 'Skip certificate check (testing only)'),
    _B(['telegram', 'remoteUnlock'], 'Allow unlocking locks from Telegram/AI/voice'),
    _B(['offline', 'fallbackAp'], 'Emergency hotspot when internet/MQTT is down'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final f in _fields) {
      f.c.dispose();
    }
    super.dispose();
  }

  Object? _get(Map<String, dynamic> m, List<String> path) {
    Object? cur = m;
    for (final p in path) {
      if (cur is! Map) return null;
      cur = cur[p];
    }
    return cur;
  }

  void _put(Map<String, dynamic> m, List<String> path, Object? v) {
    var cur = m;
    for (final p in path.take(path.length - 1)) {
      cur = (cur[p] ??= <String, dynamic>{}) as Map<String, dynamic>;
    }
    cur[path.last] = v;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.send({'op': 'config_get'});
      final cfg = (r['cfg'] as Map?)?.cast<String, dynamic>() ?? {};
      _cfg = cfg;
      for (final f in _fields) {
        if (f.secret) {
          final setPath = [...f.path.take(f.path.length - 1), '${f.path.last}Set'];
          f.storedSecret = _get(cfg, setPath) == true;
          f.c.text = '';
        } else {
          final v = _get(cfg, f.path);
          f.c.text = v == null ? '' : '$v';
        }
      }
      for (final b in _bools) {
        b.value = _get(cfg, b.path) == true;
      }
      _cloud = (_get(cfg, ['cloud', 'provider']) as String?) ?? 'off';
      _meter = (_get(cfg, ['meter', 'type']) as String?) ?? 'none';
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final out = <String, dynamic>{};
    for (final f in _fields) {
      final text = f.c.text.trim();
      if (f.secret) {
        if (text.isEmpty) continue; // keep stored secret
        _put(out, f.path, text == '-' ? '' : text); // "-" clears it
        continue;
      }
      final old = _get(_cfg, f.path);
      if (f.number) {
        final n = num.tryParse(text);
        if (n != null && n != old) _put(out, f.path, n);
      } else if (text != (old ?? '').toString()) {
        _put(out, f.path, text);
      }
    }
    for (final b in _bools) {
      if (b.value != (_get(_cfg, b.path) == true)) _put(out, b.path, b.value);
    }
    if (_cloud != _get(_cfg, ['cloud', 'provider'])) _put(out, ['cloud', 'provider'], _cloud);
    if (_meter != _get(_cfg, ['meter', 'type'])) _put(out, ['meter', 'type'], _meter);
    if (out.isEmpty) {
      toast(context, t('कुछ नहीं बदला', 'Nothing changed'));
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await widget.send({'op': 'config_set', 'cfg': out});
      if (!mounted) return;
      toast(context, r['restart'] == true
          ? t('सेव हो गया - बोर्ड रीस्टार्ट हो रहा है', 'Saved - the board restarts to apply it')
          : t('सेव हो गया', 'Saved'));
      await _load();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    if (mounted) setState(() => _saving = false);
  }

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
      );

  Widget _field(String last, [String? group]) {
    final f = _fields.firstWhere((x) => x.path.last == last && (group == null || x.path.first == group));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextField(
        controller: f.c,
        obscureText: f.secret && !f.multiline,
        maxLines: f.multiline ? 4 : 1,
        keyboardType: f.number ? const TextInputType.numberWithOptions(decimal: true) : null,
        autocorrect: false,
        enableSuggestions: !f.secret,
        decoration: InputDecoration(
          labelText: f.label,
          border: const OutlineInputBorder(),
          isDense: true,
          hintText: f.secret
              ? (f.storedSecret ? t('सेव है - बदलने के लिए लिखें, "-" = हटाएँ', 'stored - type to replace, "-" = clear') : t('सेट नहीं', 'not set'))
              : f.hint,
        ),
      ),
    );
  }

  Widget _switch(String last, [String? group]) {
    final b = _bools.firstWhere((x) => x.path.last == last && (group == null || x.path.first == group));
    return SwitchListTile(
      title: Text(b.label),
      value: b.value,
      onChanged: (v) => setState(() => b.value = v),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: _loading || _error != null
          ? null
          : FloatingActionButton.extended(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined),
              label: Text(t('सेव करें', 'Save to board')),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ListView(children: [
                  if (widget.extraTop != null) widget.extraTop!,
                  Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
                  Center(child: FilledButton(onPressed: _load, child: Text(t('फिर कोशिश करें', 'Try again')))),
                ])
              : ListView(
                  padding: const EdgeInsets.only(bottom: 96),
                  children: [
                    if (widget.extraTop != null) widget.extraTop!,
                    _section(t('सामान्य', 'General')),
                    _field('node'),
                    _field('apiKey'),
                    _field('tz'),
                    _section('Secure MQTT'),
                    _field('host', 'mqtt'),
                    _field('port', 'mqtt'),
                    _field('user', 'mqtt'),
                    _field('pass', 'mqtt'),
                    _field('base', 'mqtt'),
                    _switch('tls', 'mqtt'),
                    _switch('insecure', 'mqtt'),
                    _field('ca', 'mqtt'),
                    _section(t('टेलीग्राम + AI', 'Telegram + AI')),
                    _field('token', 'telegram'),
                    _field('chats', 'telegram'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                          t('अपना chat id जानने के लिए बॉट को /myid भेजें (लिस्ट खाली होने पर ही जवाब देता है)।',
                              'Send /myid to your bot to get your chat id (answered only while the list is empty).'),
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    _switch('remoteUnlock', 'telegram'),
                    _field('url', 'ai'),
                    _field('model', 'ai'),
                    _field('key', 'ai'),
                    _section('Alexa / Google Home (Sinric Pro)'),
                    _field('key', 'sinric'),
                    _field('secret', 'sinric'),
                    _field('map', 'sinric'),
                    _section(t('क्लाउड डेटाबेस', 'Cloud database')),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'off', label: Text('Off')),
                          ButtonSegment(value: 'firebase', label: Text('Firebase')),
                          ButtonSegment(value: 'supabase', label: Text('Supabase')),
                        ],
                        selected: {_cloud},
                        onSelectionChanged: (s) => setState(() => _cloud = s.first),
                      ),
                    ),
                    _field('url', 'cloud'),
                    _field('key', 'cloud'),
                    _field('interval', 'cloud'),
                    _section(t('एनर्जी मीटर', 'Energy meter')),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'none', label: Text('None')),
                          ButtonSegment(value: 'pzem', label: Text('PZEM-004T')),
                          ButtonSegment(value: 'acs712', label: Text('ACS712')),
                        ],
                        selected: {_meter},
                        onSelectionChanged: (s) => setState(() => _meter = s.first),
                      ),
                    ),
                    if (_meter == 'pzem') ...[_field('rx'), _field('tx'), _field('addrs')],
                    if (_meter == 'acs712') ...[_field('pins'), _field('mvPerA'), _field('divider'), _field('mainsV')],
                    if (_meter != 'none') _field('rooms'),
                    _section(t('ऑफ़लाइन / इमरजेंसी मोड', 'Offline / emergency mode')),
                    _switch('fallbackAp'),
                    _field('timeout', 'offline'),
                    _section('OTA'),
                    _field('otaPass'),
                  ],
                ),
    );
  }
}
