import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'strings.dart';
import 'util.dart';

/// Everything the user can configure at runtime. NO value here is compiled into the app.
///
/// Stored in two places:
///   shared_preferences      - harmless values (host names, ids, room names, language, theme)
///   flutter_secure_storage  - secrets (passwords, tokens, API keys) in the Android Keystore / iOS Keychain
class AppSettings {
  const AppSettings({
    this.homeId = '',
    this.homeName = 'My Home',
    this.mqttHost = '',
    this.mqttPort = 8883,
    this.mqttUser = '',
    this.fbApiKey = '',
    this.fbDbUrl = '',
    this.fbUserEmail = '',
    this.fbDeviceEmail = '',
    this.tgChats = '',
    this.aiUrl = '',
    this.hindi = false,
    this.themeMode = ThemeMode.system,
    this.roomNames = const ['Room 1', 'Room 2', 'Room 3', 'Room 4'],
    this.tariff = 0,
    this.currency = '₹',
    // secrets
    this.mqttPass = '',
    this.fbUserPass = '',
    this.fbDevicePass = '',
    this.tgToken = '',
    this.aiKey = '',
    this.sinricKey = '',
    this.sinricSecret = '',
    this.apiKey = '',
    this.apPass = '',
    this.bleKey = '',
  });

  final String homeId, homeName;
  final String mqttHost;
  final int mqttPort;
  final String mqttUser;
  final String fbApiKey, fbDbUrl, fbUserEmail, fbDeviceEmail;
  final String tgChats, aiUrl;
  final bool hindi;
  final ThemeMode themeMode;
  final List<String> roomNames;
  final double tariff;
  final String currency;

  final String mqttPass, fbUserPass, fbDevicePass, tgToken, aiKey, sinricKey, sinricSecret;
  final String apiKey, apPass, bleKey;

  bool get mqttConfigured => mqttHost.isNotEmpty && homeId.isNotEmpty;
  bool get cloudConfigured => fbApiKey.isNotEmpty && fbDbUrl.isNotEmpty && fbUserEmail.isNotEmpty && fbUserPass.isNotEmpty;
  bool get hasHomeKeys => apiKey.length >= 16 && bleKey.length >= 16 && apPass.length >= 8;
  Tr get tr => Tr(hindi);

  String roomName(int i) => i >= 0 && i < roomNames.length ? roomNames[i] : 'Room ${i + 1}';

  AppSettings copyWith({
    String? homeId, String? homeName, String? mqttHost, int? mqttPort, String? mqttUser,
    String? fbApiKey, String? fbDbUrl, String? fbUserEmail, String? fbDeviceEmail,
    String? tgChats, String? aiUrl, bool? hindi, ThemeMode? themeMode, List<String>? roomNames,
    double? tariff, String? currency,
    String? mqttPass, String? fbUserPass, String? fbDevicePass, String? tgToken, String? aiKey,
    String? sinricKey, String? sinricSecret, String? apiKey, String? apPass, String? bleKey,
  }) =>
      AppSettings(
        homeId: homeId ?? this.homeId, homeName: homeName ?? this.homeName,
        mqttHost: mqttHost ?? this.mqttHost, mqttPort: mqttPort ?? this.mqttPort, mqttUser: mqttUser ?? this.mqttUser,
        fbApiKey: fbApiKey ?? this.fbApiKey, fbDbUrl: fbDbUrl ?? this.fbDbUrl,
        fbUserEmail: fbUserEmail ?? this.fbUserEmail, fbDeviceEmail: fbDeviceEmail ?? this.fbDeviceEmail,
        tgChats: tgChats ?? this.tgChats, aiUrl: aiUrl ?? this.aiUrl, hindi: hindi ?? this.hindi,
        themeMode: themeMode ?? this.themeMode, roomNames: roomNames ?? this.roomNames,
        tariff: tariff ?? this.tariff, currency: currency ?? this.currency,
        mqttPass: mqttPass ?? this.mqttPass, fbUserPass: fbUserPass ?? this.fbUserPass,
        fbDevicePass: fbDevicePass ?? this.fbDevicePass, tgToken: tgToken ?? this.tgToken,
        aiKey: aiKey ?? this.aiKey, sinricKey: sinricKey ?? this.sinricKey, sinricSecret: sinricSecret ?? this.sinricSecret,
        apiKey: apiKey ?? this.apiKey, apPass: apPass ?? this.apPass, bleKey: bleKey ?? this.bleKey,
      );

  /// Settings that need a new MQTT connection when they change.
  bool sameConnection(AppSettings o) =>
      homeId == o.homeId && mqttHost == o.mqttHost && mqttPort == o.mqttPort && mqttUser == o.mqttUser && mqttPass == o.mqttPass;

  /// Creates the per-home secrets the first time they are needed. They are shared by all boards
  /// of the home: LAN API key, emergency hotspot password and the Bluetooth key.
  AppSettings withHomeKeys() => copyWith(
        homeId: homeId.isEmpty ? randomId(8) : homeId,
        apiKey: apiKey.length >= 16 ? apiKey : randomSecret(24),
        apPass: apPass.length >= 8 ? apPass : randomSecret(12),
        bleKey: bleKey.length >= 16 ? bleKey : randomSecret(24),
      );
}

class SettingsStore {
  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const _secretKeys = [
    'mqttPass', 'fbUserPass', 'fbDevicePass', 'tgToken', 'aiKey', 'sinricKey', 'sinricSecret', 'apiKey', 'apPass', 'bleKey',
  ];

  Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    Map<String, String> s = const {};
    try {
      s = await _secure.readAll();
    } catch (_) {
      // a keystore that cannot be read (restored backup, new phone) just means "no secrets yet"
    }
    final rooms = p.getStringList('roomNames');
    return AppSettings(
      homeId: p.getString('homeId') ?? '',
      homeName: p.getString('homeName') ?? 'My Home',
      mqttHost: p.getString('mqttHost') ?? '',
      mqttPort: p.getInt('mqttPort') ?? 8883,
      mqttUser: p.getString('mqttUser') ?? '',
      fbApiKey: p.getString('fbApiKey') ?? '',
      fbDbUrl: p.getString('fbDbUrl') ?? '',
      fbUserEmail: p.getString('fbUserEmail') ?? '',
      fbDeviceEmail: p.getString('fbDeviceEmail') ?? '',
      tgChats: p.getString('tgChats') ?? '',
      aiUrl: p.getString('aiUrl') ?? '',
      hindi: p.getBool('hindi') ?? false,
      themeMode: ThemeMode.values[(p.getInt('themeMode') ?? 0).clamp(0, 2).toInt()],
      roomNames: rooms == null || rooms.isEmpty ? const ['Room 1', 'Room 2', 'Room 3', 'Room 4'] : rooms,
      tariff: p.getDouble('tariff') ?? 0,
      currency: p.getString('currency') ?? '₹',
      mqttPass: s['mqttPass'] ?? '',
      fbUserPass: s['fbUserPass'] ?? '',
      fbDevicePass: s['fbDevicePass'] ?? '',
      tgToken: s['tgToken'] ?? '',
      aiKey: s['aiKey'] ?? '',
      sinricKey: s['sinricKey'] ?? '',
      sinricSecret: s['sinricSecret'] ?? '',
      apiKey: s['apiKey'] ?? '',
      apPass: s['apPass'] ?? '',
      bleKey: s['bleKey'] ?? '',
    );
  }

  Future<void> save(AppSettings a) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('homeId', a.homeId);
    await p.setString('homeName', a.homeName);
    await p.setString('mqttHost', a.mqttHost.trim());
    await p.setInt('mqttPort', a.mqttPort);
    await p.setString('mqttUser', a.mqttUser.trim());
    await p.setString('fbApiKey', a.fbApiKey.trim());
    await p.setString('fbDbUrl', a.fbDbUrl.trim());
    await p.setString('fbUserEmail', a.fbUserEmail.trim());
    await p.setString('fbDeviceEmail', a.fbDeviceEmail.trim());
    await p.setString('tgChats', a.tgChats);
    await p.setString('aiUrl', a.aiUrl.trim());
    await p.setBool('hindi', a.hindi);
    await p.setInt('themeMode', a.themeMode.index);
    await p.setStringList('roomNames', a.roomNames);
    await p.setDouble('tariff', a.tariff);
    await p.setString('currency', a.currency);
    final values = <String, String>{
      'mqttPass': a.mqttPass, 'fbUserPass': a.fbUserPass, 'fbDevicePass': a.fbDevicePass, 'tgToken': a.tgToken,
      'aiKey': a.aiKey, 'sinricKey': a.sinricKey, 'sinricSecret': a.sinricSecret,
      'apiKey': a.apiKey, 'apPass': a.apPass, 'bleKey': a.bleKey,
    };
    for (final k in _secretKeys) {
      final v = values[k] ?? '';
      if (v.isEmpty) {
        await _secure.delete(key: k);
      } else {
        await _secure.write(key: k, value: v);
      }
    }
  }
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  final _store = SettingsStore();

  @override
  Future<AppSettings> build() async {
    var s = await _store.load();
    if (s.homeId.isEmpty) {                       // very first start: invent the home id
      s = s.copyWith(homeId: randomId(8));
      await _store.save(s);
    }
    return s;
  }

  Future<void> update(AppSettings s) async {
    state = AsyncData(s);
    await _store.save(s);
  }

  /// Makes sure the LAN key / hotspot password / BLE key exist (needed before provisioning a board).
  Future<AppSettings> ensureKeys() async {
    final cur = state.valueOrNull ?? await future;
    if (cur.hasHomeKeys && cur.homeId.isNotEmpty) return cur;
    final next = cur.withHomeKeys();
    await update(next);
    return next;
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// Texts in the chosen language. Falls back to English while settings are still loading.
final trProvider = Provider<Tr>((ref) => ref.watch(settingsProvider).valueOrNull?.tr ?? const Tr(false));

// Used by the cache + a tiny helper for lists in prefs.
String encodeJson(Object o) => jsonEncode(o);
