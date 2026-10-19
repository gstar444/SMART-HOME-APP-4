/// Firmware update without a cable: the board downloads a .bin from a URL
/// (HTTP OTA), or you use the browser upload page / ArduinoOTA.
library;

import 'package:flutter/material.dart';

import '../settings.dart';
import 'advanced_page.dart' show toast, tx;
import 'board_api.dart';

class OtaPage extends StatefulWidget {
  const OtaPage({super.key, required this.settings});
  final SettingsController settings;

  @override
  State<OtaPage> createState() => _OtaPageState();
}

class _OtaPageState extends State<OtaPage> {
  final _url = TextEditingController();
  bool _busy = false;
  String _fw = '';

  String t(String hi, String en) => tx(widget.settings, hi, en);

  @override
  void initState() {
    super.initState();
    final api = BoardApi(widget.settings);
    api.get('/api/info').then((i) {
      if (mounted) setState(() => _fw = '${i['node'] ?? ''}  •  firmware ${i['fw'] ?? '?'}');
    }).catchError((Object _) {}).whenComplete(api.close);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _pull() async {
    final url = _url.text.trim();
    if (!url.startsWith('http')) {
      toast(context, t('सही URL डालें', 'Enter a valid http(s) URL'));
      return;
    }
    setState(() => _busy = true);
    final api = BoardApi(widget.settings);
    try {
      await api.post('/api/ota/url', {'url': url});
      if (mounted) toast(context, t('बोर्ड अपडेट डाउनलोड कर रहा है, फिर रीस्टार्ट होगा', 'The board is downloading the update and will restart'));
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings.value;
    final base = s.activeUrl.endsWith('/') ? s.activeUrl : '${s.activeUrl}/';
    final small = Theme.of(context).textTheme.bodySmall;
    return Scaffold(
      appBar: AppBar(title: Text(t('फर्मवेयर अपडेट', 'Firmware update'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_fw.isNotEmpty) Text(_fw),
        const SizedBox(height: 12),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Firmware URL (.bin)',
            hintText: 'https://github.com/<you>/<repo>/releases/download/v4/firmware.bin',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _pull,
          icon: const Icon(Icons.system_update_alt),
          label: Text(t('URL से अपडेट करें', 'Update from URL')),
        ),
        const SizedBox(height: 24),
        Text(t('दूसरे तरीके:', 'Other ways:'), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        SelectableText(
          '1) Browser: ${base}update?key=<API key>\n'
          '2) Arduino IDE: Tools → Port → "esp32-home" (network), password = OTA password\n'
          '3) Arduino IDE: Sketch → Export compiled binary → upload the .bin with (1) or host it for (URL).',
          style: small,
        ),
        const SizedBox(height: 12),
        Text(
          t('बोर्ड सेटिंग: Partition Scheme = "Minimal SPIFFS (1.9MB APP with OTA)". अपडेट के समय सभी रिले बंद हो जाते हैं।',
              'Board setting: Partition Scheme = "Minimal SPIFFS (1.9MB APP with OTA)". All relays switch off during an update.'),
          style: small,
        ),
      ]),
    );
  }
}
