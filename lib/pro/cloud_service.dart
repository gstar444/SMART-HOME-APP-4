/// Firebase Realtime Database / Supabase access from the app.
/// The app WRITES room names, automation rules and remote commands; the board
/// pulls them (cloud_sync.h). The app READS the state + energy the board pushes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pro_settings.dart';

class CloudService {
  CloudService(this.cfg);

  final ProSettings cfg;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 8);

  bool get _firebase => cfg.cloudProvider == 'firebase';

  Future<Object?> _req(String method, String path, {Object? body, String? prefer}) async {
    final base = cfg.cloudUrl.replaceAll(RegExp(r'/+$'), '');
    var url = '$base$path';
    if (_firebase) {
      url += '${path.contains('?') ? '&' : '?'}auth=${Uri.encodeQueryComponent(cfg.cloudKey)}';
    }
    final req = await _http.openUrl(method, Uri.parse(url)).timeout(const Duration(seconds: 10));
    req.headers.contentType = ContentType.json;
    if (!_firebase) {
      req.headers.set('apikey', cfg.cloudKey);
      req.headers.set('Authorization', 'Bearer ${cfg.cloudKey}');
      if (prefer != null) req.headers.set('Prefer', prefer);
    }
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(const Duration(seconds: 15));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Cloud HTTP ${res.statusCode}: ${text.length > 120 ? text.substring(0, 120) : text}');
    }
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  /// Latest state JSON of a board (as pushed by the firmware).
  Future<Map<String, dynamic>?> state(String node) async {
    if (_firebase) {
      final r = await _req('GET', '/smarthome/$node/state.json');
      return r is Map<String, dynamic> ? r : null;
    }
    final r = await _req('GET', '/rest/v1/smarthome_nodes?select=state&node_id=eq.$node');
    if (r is List && r.isNotEmpty && r.first is Map) {
      final s = (r.first as Map)['state'];
      return s is Map<String, dynamic> ? s : null;
    }
    return null;
  }

  Future<void> saveRules(String node, List<dynamic> rules) => _firebase
      ? _req('PUT', '/smarthome/$node/rules.json', body: rules)
      : _req('POST', '/rest/v1/smarthome_nodes?on_conflict=node_id',
          body: {'node_id': node, 'rules': rules}, prefer: 'resolution=merge-duplicates,return=minimal');

  Future<void> saveRooms(String node, List<String> rooms) => _firebase
      ? _req('PUT', '/smarthome/$node/rooms.json', body: rooms)
      : _req('POST', '/rest/v1/smarthome_nodes?on_conflict=node_id',
          body: {'node_id': node, 'rooms': rooms}, prefer: 'resolution=merge-duplicates,return=minimal');

  /// Queues a command; the board runs it on its next sync (default 15 s).
  Future<void> sendCommand(String node, Map<String, dynamic> cmd) => _firebase
      ? _req('POST', '/smarthome/$node/commands.json', body: cmd)
      : _req('POST', '/rest/v1/smarthome_commands',
          body: {'node_id': node, 'cmd': cmd}, prefer: 'return=minimal');

  void close() => _http.close(force: true);
}
