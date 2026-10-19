/// App-side settings for the "Advanced / Pro" features.
///
/// Stored separately from the original settings (key `pro_v1`) so the
/// existing settings format is untouched. Secrets (MQTT password, cloud key)
/// live only on this phone in the app's private storage and are never logged.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _proKey = 'pro_v1';

@immutable
class ProSettings {
  const ProSettings({
    this.mqttHost = '',
    this.mqttPort = 8883,
    this.mqttUser = '',
    this.mqttPass = '',
    this.mqttTls = true,
    this.mqttBase = 'smarthome',
    this.mqttRemote = false,
    this.cloudProvider = 'off',
    this.cloudUrl = '',
    this.cloudKey = '',
    this.node = '',
    this.bleDeviceId = '',
  });

  /// Broker the PHONE uses when it is away from home (remote control).
  final String mqttHost;
  final int mqttPort;
  final String mqttUser;
  final String mqttPass;
  final bool mqttTls;
  final String mqttBase;

  /// Use MQTT automatically when the board cannot be reached over local HTTP.
  final bool mqttRemote;

  /// off | firebase | supabase (same database the board syncs with).
  final String cloudProvider;
  final String cloudUrl;
  final String cloudKey;

  /// Node id of the active board (filled from /api/state automatically).
  final String node;
  final String bleDeviceId;

  bool get mqttReady => mqttHost.isNotEmpty;
  bool get cloudReady =>
      cloudProvider != 'off' && cloudUrl.startsWith('https://') && cloudKey.isNotEmpty;

  ProSettings copyWith({
    String? mqttHost,
    int? mqttPort,
    String? mqttUser,
    String? mqttPass,
    bool? mqttTls,
    String? mqttBase,
    bool? mqttRemote,
    String? cloudProvider,
    String? cloudUrl,
    String? cloudKey,
    String? node,
    String? bleDeviceId,
  }) =>
      ProSettings(
        mqttHost: mqttHost ?? this.mqttHost,
        mqttPort: mqttPort ?? this.mqttPort,
        mqttUser: mqttUser ?? this.mqttUser,
        mqttPass: mqttPass ?? this.mqttPass,
        mqttTls: mqttTls ?? this.mqttTls,
        mqttBase: mqttBase ?? this.mqttBase,
        mqttRemote: mqttRemote ?? this.mqttRemote,
        cloudProvider: cloudProvider ?? this.cloudProvider,
        cloudUrl: cloudUrl ?? this.cloudUrl,
        cloudKey: cloudKey ?? this.cloudKey,
        node: node ?? this.node,
        bleDeviceId: bleDeviceId ?? this.bleDeviceId,
      );

  Map<String, dynamic> toJson() => {
        'mqttHost': mqttHost,
        'mqttPort': mqttPort,
        'mqttUser': mqttUser,
        'mqttPass': mqttPass,
        'mqttTls': mqttTls,
        'mqttBase': mqttBase,
        'mqttRemote': mqttRemote,
        'cloudProvider': cloudProvider,
        'cloudUrl': cloudUrl,
        'cloudKey': cloudKey,
        'node': node,
        'bleDeviceId': bleDeviceId,
      };

  factory ProSettings.fromJson(Map<String, dynamic> j) {
    const d = ProSettings();
    String s(String k, String def) => j[k] is String ? j[k] as String : def;
    bool b(String k, bool def) => j[k] is bool ? j[k] as bool : def;
    final provider = s('cloudProvider', d.cloudProvider);
    return ProSettings(
      mqttHost: s('mqttHost', d.mqttHost),
      mqttPort: j['mqttPort'] is num ? (j['mqttPort'] as num).toInt() : d.mqttPort,
      mqttUser: s('mqttUser', d.mqttUser),
      mqttPass: s('mqttPass', d.mqttPass),
      mqttTls: b('mqttTls', d.mqttTls),
      mqttBase: s('mqttBase', d.mqttBase),
      mqttRemote: b('mqttRemote', d.mqttRemote),
      cloudProvider:
          const ['off', 'firebase', 'supabase'].contains(provider) ? provider : 'off',
      cloudUrl: s('cloudUrl', d.cloudUrl),
      cloudKey: s('cloudKey', d.cloudKey),
      node: s('node', d.node),
      bleDeviceId: s('bleDeviceId', d.bleDeviceId),
    );
  }
}

/// Loads lazily (first use of an advanced screen), never before the first frame.
class ProController extends ValueNotifier<ProSettings> {
  ProController._(super.value);

  static ProController? _instance;
  static Future<ProController>? _loading;

  /// Shared instance; the first call reads shared_preferences asynchronously.
  static Future<ProController> instance() {
    final ready = _instance;
    if (ready != null) return Future.value(ready);
    return _loading ??= () async {
      final prefs = await SharedPreferences.getInstance();
      var s = const ProSettings();
      final raw = prefs.getString(_proKey);
      if (raw != null) {
        try {
          s = ProSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        } catch (_) {
          // corrupt -> defaults
        }
      }
      return _instance = ProController._(s);
    }();
  }

  Future<void> update(ProSettings next) async {
    value = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_proKey, jsonEncode(next.toJson()));
  }
}
