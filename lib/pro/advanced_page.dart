/// "Advanced / Pro features" hub. Loaded lazily (deferred import from the
/// settings screen), so none of this code or its packages slows down startup.
library;

import 'package:flutter/material.dart';

import '../esp32_api.dart';
import '../settings.dart';
import 'board_api.dart';
import 'board_config_page.dart';
import 'energy_page.dart';
import 'ota_page.dart';
import 'provisioning_page.dart';
import 'remote_page.dart';
import 'rules_page.dart';

/// Tiny bilingual helper (the original Tr class is left untouched).
String tx(SettingsController s, String hi, String en) => s.value.hindi ? hi : en;

/// Shows a short message at the bottom.
void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

class AdvancedPage extends StatelessWidget {
  const AdvancedPage({super.key, required this.settings, this.esp});

  final SettingsController settings;
  final Esp32Controller? esp;

  @override
  Widget build(BuildContext context) {
    String t(String hi, String en) => tx(settings, hi, en);
    void open(Widget page) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    Future<Map<String, dynamic>> http(Map<String, dynamic> cmd) => BoardApi(settings).cmd(cmd);
    final net = esp?.state == null ? null : _netLine(esp!);

    return Scaffold(
      appBar: AppBar(title: Text(t('एडवांस्ड / प्रो फ़ीचर', 'Advanced / Pro features'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (net != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(net, style: Theme.of(context).textTheme.bodySmall),
            ),
          _tile(context, Icons.bolt_outlined, t('बिजली / एनर्जी मीटर', 'Energy & power monitor'),
              t('वोल्टेज, करंट, वॉट, kWh (PZEM-004T / ACS712)', 'Voltage, current, watts, kWh (PZEM-004T / ACS712)'),
              () => open(EnergyPage(settings: settings))),
          _tile(context, Icons.tune, t('बोर्ड सेटिंग्स (क्लाउड, MQTT, टेलीग्राम...)', 'Board settings (MQTT, Telegram, AI, cloud...)'),
              t('ESP32 पर Wi-Fi से सेव होती हैं', 'Stored on the ESP32, sent over Wi-Fi'),
              () => open(BoardConfigPage(settings: settings, send: http, title: t('बोर्ड सेटिंग्स', 'Board settings')))),
          _tile(context, Icons.bluetooth_searching, t('नया डिवाइस खोजें / BLE सेटअप', 'Find boards / BLE provisioning'),
              t('mDNS + ब्लूटूथ, बिना USB के Wi-Fi और टोकन भेजें', 'mDNS + Bluetooth, send Wi-Fi & tokens without USB'),
              () => open(ProvisioningPage(settings: settings))),
          _tile(context, Icons.rule, t('ऑटोमेशन नियम', 'Automation rules'),
              t('शर्त पर डिवाइस चालू/बंद, क्लाउड से सिंक', 'Condition based automations, cloud synced'),
              () => open(RulesPage(settings: settings, esp: esp))),
          _tile(context, Icons.cloud_outlined, t('रिमोट एक्सेस (MQTT / क्लाउड)', 'Remote access (MQTT / cloud)'),
              t('घर से बाहर कंट्रोल, Firebase / Supabase', 'Control from anywhere, Firebase / Supabase'),
              () => open(RemotePage(settings: settings, esp: esp))),
          _tile(context, Icons.system_update_alt, t('फर्मवेयर अपडेट (OTA)', 'Firmware update (OTA)'),
              t('बिना केबल के नया फर्मवेयर', 'New firmware without a cable'),
              () => open(OtaPage(settings: settings))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: Text(
              t('Alexa / Google Home: बोर्ड सेटिंग्स → Sinric Pro में चाबियाँ डालें, फिर Alexa/Google ऐप में "Sinric Pro" स्किल जोड़ें।',
                  'Alexa / Google Home: enter your Sinric Pro keys in Board settings, then link the "Sinric Pro" skill in the Alexa / Google Home app.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  String _netLine(Esp32Controller esp) {
    final n = esp.state!.net;
    if (n.isEmpty) return '';
    return 'Internet: ${n['internet'] == true ? 'OK' : '—'}   MQTT: ${n['mqtt'] ?? '—'}   '
        'Cloud: ${n['cloud'] ?? '—'}${n['emergency'] == true ? '   EMERGENCY HOTSPOT ON' : ''}';
  }

  Widget _tile(BuildContext context, IconData icon, String title, String sub, VoidCallback onTap) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
}
