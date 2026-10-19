import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../core/util.dart';
import '../services/firebase_rest.dart';
import '../state/home_controller.dart';
import 'widgets.dart';

/// Runtime configuration. Nothing here is compiled into the app: change the broker, tokens or
/// keys and the app reconnects at once. Harmless values live in shared_preferences, secrets in
/// the Android Keystore / iOS Keychain (flutter_secure_storage).
///
/// These values are also what the app SENDS to a new board during Bluetooth set-up. To change
/// them on a board that is already installed, hold its BOOT button 3 s and run "Set up" again.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final Map<String, TextEditingController> _c = {};
  late List<TextEditingController> _rooms;
  late bool _hindi;
  late ThemeMode _theme;
  bool _loaded = false, _busy = false;
  AppSettings? _orig;

  TextEditingController _ctl(String key, String initial) => _c.putIfAbsent(key, () => TextEditingController(text: initial));
  String _v(String k) => (_c[k]?.text ?? '').trim();

  void _init(AppSettings s) {
    _orig = s;
    _ctl('homeName', s.homeName);
    _ctl('mqttHost', s.mqttHost);
    _ctl('mqttPort', '${s.mqttPort}');
    _ctl('mqttUser', s.mqttUser);
    _ctl('mqttPass', s.mqttPass);
    _ctl('fbApiKey', s.fbApiKey);
    _ctl('fbDbUrl', s.fbDbUrl);
    _ctl('fbUserEmail', s.fbUserEmail);
    _ctl('fbUserPass', s.fbUserPass);
    _ctl('fbDeviceEmail', s.fbDeviceEmail);
    _ctl('fbDevicePass', s.fbDevicePass);
    _ctl('tgToken', s.tgToken);
    _ctl('tgChats', s.tgChats);
    _ctl('aiUrl', s.aiUrl);
    _ctl('aiKey', s.aiKey);
    _ctl('sinricKey', s.sinricKey);
    _ctl('sinricSecret', s.sinricSecret);
    _ctl('tariff', s.tariff == 0 ? '' : '${s.tariff}');
    _ctl('currency', s.currency);
    _ctl('otaVersion', '');
    _ctl('otaUrl', '');
    _ctl('otaMd5', '');
    _rooms = [for (final r in s.roomNames) TextEditingController(text: r)];
    _hindi = s.hindi;
    _theme = s.themeMode;
    _loaded = true;
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    if (_loaded) {
      for (final c in _rooms) {
        c.dispose();
      }
    }
    super.dispose();
  }

  AppSettings _collect() {
    final names = [for (final c in _rooms) cleanName(c.text)].where((e) => e.isNotEmpty).toList();
    return _orig!.copyWith(
      homeName: _v('homeName').isEmpty ? 'My Home' : _v('homeName'),
      mqttHost: _v('mqttHost'),
      mqttPort: int.tryParse(_v('mqttPort')) ?? 8883,
      mqttUser: _v('mqttUser'),
      mqttPass: _c['mqttPass']!.text,
      fbApiKey: _v('fbApiKey'),
      fbDbUrl: _v('fbDbUrl'),
      fbUserEmail: _v('fbUserEmail'),
      fbUserPass: _c['fbUserPass']!.text,
      fbDeviceEmail: _v('fbDeviceEmail'),
      fbDevicePass: _c['fbDevicePass']!.text,
      tgToken: _v('tgToken'),
      tgChats: parseChatIds(_v('tgChats')).join(', '),
      aiUrl: _v('aiUrl'),
      aiKey: _v('aiKey'),
      sinricKey: _v('sinricKey'),
      sinricSecret: _v('sinricSecret'),
      tariff: double.tryParse(_v('tariff')) ?? 0,
      currency: _v('currency'),
      roomNames: names.isEmpty ? const ['Room 1'] : names,
      hindi: _hindi,
      themeMode: _theme,
    );
  }

  Future<AppSettings> _save({bool quiet = false}) async {
    var s = _collect();
    if (s.mqttHost.isNotEmpty && !s.hasHomeKeys) s = s.withHomeKeys();
    _orig = s;
    await ref.read(settingsProvider.notifier).saveSettings(s);
    final fb = ref.read(firebaseProvider);
    if (fb != null) {
      fb.saveRooms(s.homeId, s.roomNames).catchError((Object _) {}); // best effort: rooms follow the user to other phones
    }
    if (!quiet && mounted) toast(context, 'Saved');
    return s;
  }

  /// First-time cloud set-up: creates the device login the boards use and registers this home.
  Future<void> _bootstrapCloud() async {
    final s = await _save(quiet: true);
    if (!s.cloudConfigured || s.fbDeviceEmail.isEmpty || s.fbDevicePass.length < 8) {
      toast(context, 'Fill in API key, database URL, your login and a device login (password 8+ characters).');
      return;
    }
    setState(() => _busy = true);
    try {
      final deviceUid = await FirebaseRest.ensureAccount(s.fbApiKey, s.fbDeviceEmail, s.fbDevicePass);
      final me = FirebaseRest(apiKey: s.fbApiKey, dbUrl: s.fbDbUrl, email: s.fbUserEmail, password: s.fbUserPass);
      try {
        await me.signIn();
      } on FirebaseException catch (e) {
        if (!e.message.contains('EMAIL_NOT_FOUND') && !e.message.contains('INVALID_LOGIN')) rethrow;
        await FirebaseRest.ensureAccount(s.fbApiKey, s.fbUserEmail, s.fbUserPass);
      }
      await me.createHome(homeId: s.homeId, homeName: s.homeName, deviceUid: deviceUid);
      await me.saveRooms(s.homeId, s.roomNames);
      if (mounted) toast(context, 'Cloud ready. Now publish cloud/firebase/database.rules.json if you have not yet.');
    } catch (e) {
      if (mounted) toast(context, 'Cloud set-up failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Firmware over the air: publish a manifest to Firebase and nudge every board.
  Future<void> _publishOta() async {
    final fb = ref.read(firebaseProvider);
    final cfg = _orig!;
    final v = _v('otaVersion'), url = _v('otaUrl'), md5 = _v('otaMd5').toLowerCase();
    if (fb == null) return toast(context, 'Set up Firebase first');
    if (!RegExp(r'^\d+(\.\d+){0,3}$').hasMatch(v)) return toast(context, 'Version like 5.0.1');
    if (!url.startsWith('https://')) return toast(context, 'The firmware URL must be https://');
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(md5)) return toast(context, 'MD5 must be 32 hex characters (md5sum of the .bin file)');
    if (!await confirm(context, 'Publish firmware $v?', 'Every board that is older will download and install it, then restart.', action: 'Publish')) return;
    setState(() => _busy = true);
    try {
      await fb.pushOta(homeId: cfg.homeId, version: v, url: url, md5: md5);
      await ref.read(homeProvider.notifier).runOtaAll();
      if (mounted) toast(context, 'Published. Boards update within a minute or two.');
    } catch (e) {
      if (mounted) toast(context, 'Could not publish (only the home admin may): $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _tf(String key, String label, {bool secret = false, bool number = false, String? hint, String? helper}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _SecretAwareField(controller: _c[key]!, label: label, secret: secret, number: number, hint: hint, helper: helper),
      );

  Widget _section(String title, List<Widget> children, {String? note}) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              if (note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(note, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)))),
              const SizedBox(height: 12),
              ...children,
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(settingsProvider);
    final s = async.valueOrNull;
    if (s == null) return Scaffold(appBar: AppBar(title: const Text('Settings')), body: const Center(child: CircularProgressIndicator()));
    if (!_loaded) _init(s);
    final tr = ref.watch(trProvider);

    return Scaffold(
      appBar: AppBar(title: Text(tr.settings), actions: [TextButton(onPressed: _busy ? null : _save, child: Text(tr.save))]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _section('Home', [
          _tf('homeName', 'Home name'),
          InputDecorator(
            decoration: const InputDecoration(labelText: 'Home id (used in MQTT topics and the cloud)'),
            child: Row(children: [
              Expanded(child: SelectableText(_orig!.homeId)),
              IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () => Clipboard.setData(ClipboardData(text: _orig!.homeId))),
            ]),
          ),
          const SizedBox(height: 14),
          Text(tr.rooms, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (var i = 0; i < _rooms.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(child: TextField(controller: _rooms[i], decoration: InputDecoration(labelText: 'Room ${i + 1}'))),
                if (_rooms.length > 1) IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => setState(() => _rooms.removeAt(i).dispose())),
              ]),
            ),
          if (_rooms.length < 8) TextButton.icon(onPressed: () => setState(() => _rooms.add(TextEditingController(text: 'Room ${_rooms.length + 1}'))), icon: const Icon(Icons.add), label: const Text('Add room')),
        ]),
        _section('MQTT broker (secure)', [
          _tf('mqttHost', 'Broker host', hint: 'xxxx.s1.eu.hivemq.cloud'),
          _tf('mqttPort', 'Port (TLS)', number: true),
          _tf('mqttUser', 'Username'),
          _tf('mqttPass', 'Password', secret: true),
        ], note: 'TLS is always on. The connection is verified against the phone\'s trusted certificate authorities.'),
        _section('Cloud database (Firebase)', [
          _tf('fbApiKey', 'Web API key', secret: true),
          _tf('fbDbUrl', 'Realtime Database URL', hint: 'https://xxxx-default-rtdb.firebaseio.com'),
          _tf('fbUserEmail', 'Your login (email)'),
          _tf('fbUserPass', 'Your password', secret: true),
          _tf('fbDeviceEmail', 'Device login (email) - used by the boards', hint: 'boards@myhome.example'),
          _tf('fbDevicePass', 'Device password (8+ characters)', secret: true),
          FilledButton.tonalIcon(onPressed: _busy ? null : _bootstrapCloud, icon: const Icon(Icons.cloud_done_outlined), label: Text(_busy ? 'Working…' : 'Create logins and register this home')),
        ], note: 'Stores rooms, device configuration, energy history and automation rules. The boards sign in with the device login only.'),
        _section('Telegram', [
          _tf('tgToken', 'Bot token (from @BotFather)', secret: true),
          _tf('tgChats', 'Authorised chat ids', hint: '123456789, -100987654321', helper: 'Only these chats may control the house. Send /start to @userinfobot to learn yours. Empty list = bot stays off.'),
        ], note: 'Sent to the HUB board only.'),
        _section('AI commands', [
          _tf('aiUrl', 'AI worker URL', hint: 'https://smarthome-ai.xxxx.workers.dev'),
          _tf('aiKey', 'Worker key', secret: true),
        ], note: 'Deploy cloud/ai-worker once. Natural language from Telegram is turned into device commands there.'),
        _section('Voice assistants (Alexa / Google)', [
          _tf('sinricKey', 'Sinric Pro app key', secret: true),
          _tf('sinricSecret', 'Sinric Pro app secret', secret: true),
        ], note: 'Sent to the HUB board only. Paste each device\'s Sinric id in the device editor.'),
        _section('Firmware update (admin)', [
          _tf('otaVersion', 'Version', hint: '5.0.1'),
          _tf('otaUrl', 'Firmware URL (https)', hint: 'https://github.com/you/repo/releases/download/v5.0.1/smarthome_node.ino.bin'),
          _tf('otaMd5', 'MD5 of the .bin file'),
          FilledButton.tonalIcon(onPressed: _busy ? null : _publishOta, icon: const Icon(Icons.system_update), label: const Text('Publish to all boards')),
        ], note: 'Arduino IDE: Sketch -> Export Compiled Binary, upload the .ino.bin file somewhere with an https link, run md5sum on it.'),
        _section('Energy cost', [
          Row(children: [
            SizedBox(width: 90, child: _tf('currency', 'Currency')),
            const SizedBox(width: 12),
            Expanded(child: _tf('tariff', 'Price per kWh', number: true)),
          ]),
        ]),
        _section('Security keys (shared by all boards of this home)', [
          for (final e in [('LAN API key', _orig!.apiKey), ('Emergency hotspot password', _orig!.apPass), ('Bluetooth key', _orig!.bleKey)])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.$1),
              subtitle: Text(e.$2.isEmpty ? 'created when you set up the first board' : '••••••••${e.$2.substring(e.$2.length - 3)}'),
              trailing: e.$2.isEmpty ? null : IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () { Clipboard.setData(ClipboardData(text: e.$2)); toast(context, '${e.$1} copied'); }),
            ),
          const Text('Regenerating keys would lock you out of existing boards until each one is set up again, so there is no button for it.', style: TextStyle(fontSize: 12)),
        ]),
        _section('Appearance', [
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('हिंदी'), subtitle: Text(tr.language), value: _hindi, onChanged: (v) => setState(() => _hindi = v)),
          DropdownButtonFormField<ThemeMode>(
            initialValue: _theme,
            decoration: InputDecoration(labelText: tr.darkMode),
            items: const [DropdownMenuItem(value: ThemeMode.system, child: Text('System')), DropdownMenuItem(value: ThemeMode.light, child: Text('Light')), DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark'))],
            onChanged: (v) => setState(() => _theme = v ?? ThemeMode.system),
          ),
        ]),
        FilledButton(onPressed: _busy ? null : _save, child: Text(tr.save)),
        const SizedBox(height: 40),
      ]),
    );
  }
}

class _SecretAwareField extends StatefulWidget {
  const _SecretAwareField({required this.controller, required this.label, required this.secret, required this.number, this.hint, this.helper});
  final TextEditingController controller;
  final String label;
  final bool secret, number;
  final String? hint, helper;
  @override
  State<_SecretAwareField> createState() => _SecretAwareFieldState();
}

class _SecretAwareFieldState extends State<_SecretAwareField> {
  bool _hide = true;
  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        obscureText: widget.secret && _hide,
        keyboardType: widget.number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        autocorrect: false,
        enableSuggestions: !widget.secret,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          helperText: widget.helper,
          helperMaxLines: 3,
          suffixIcon: widget.secret ? IconButton(icon: Icon(_hide ? Icons.visibility_off : Icons.visibility, size: 20), onPressed: () => setState(() => _hide = !_hide)) : null,
        ),
      );
}

