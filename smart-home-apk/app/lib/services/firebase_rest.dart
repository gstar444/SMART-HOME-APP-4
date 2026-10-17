import 'dart:convert';

import 'package:http/http.dart' as http;

class FirebaseException implements Exception {
  FirebaseException(this.message, [this.code]);
  final String message;
  final int? code;
  @override
  String toString() => message;
}

/// Firebase Auth + Realtime Database over plain REST - no FlutterFire, no native plugins, no
/// google-services.json. That keeps cold start fast (nothing initialises until the first call) and
/// uses exactly the same protocol as the ESP32 (firmware/fb.h).
class FirebaseRest {
  FirebaseRest({required this.apiKey, required this.dbUrl, required this.email, required this.password});

  final String apiKey, dbUrl, email, password;
  String? _idToken, _refreshToken;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);
  String? uid;

  String get _base => dbUrl.replaceAll(RegExp(r'/+$'), '');

  // ------------------------------------------------------------------ auth
  static Future<Map<String, dynamic>> _identity(String apiKey, String action, String email, String password) async {
    final r = await http
        .post(
          Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:$action?key=$apiKey'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password, 'returnSecureToken': true}),
        )
        .timeout(const Duration(seconds: 12));
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) {
      final msg = (body['error'] is Map ? (body['error'] as Map)['message'] : null)?.toString() ?? 'HTTP ${r.statusCode}';
      throw FirebaseException(msg, r.statusCode);
    }
    return body;
  }

  Future<void> signIn() async {
    final b = await _identity(apiKey, 'signInWithPassword', email, password);
    _store(b['idToken'], b['refreshToken'], b['expiresIn']);
    uid = b['localId'] as String?;
  }

  /// Creates the account (first time) or signs in (already exists). Returns the uid.
  /// Used for the DEVICE account whose login is sent to the boards.
  static Future<String> ensureAccount(String apiKey, String email, String password) async {
    try {
      final b = await _identity(apiKey, 'signUp', email, password);
      return b['localId'] as String;
    } on FirebaseException catch (e) {
      if (e.message.contains('EMAIL_EXISTS')) {
        final b = await _identity(apiKey, 'signInWithPassword', email, password);
        return b['localId'] as String;
      }
      rethrow;
    }
  }

  void _store(Object? id, Object? refresh, Object? expiresIn) {
    _idToken = id as String?;
    _refreshToken = (refresh as String?) ?? _refreshToken;
    final secs = int.tryParse('$expiresIn') ?? 3600;
    _expires = DateTime.now().add(Duration(seconds: secs - 120));
  }

  Future<String> _token() async {
    if (_idToken != null && DateTime.now().isBefore(_expires)) return _idToken!;
    if (_refreshToken != null) {
      final r = await http.post(
        Uri.parse('https://securetoken.googleapis.com/v1/token?key=$apiKey'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(_refreshToken!)}',
      ).timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        final b = jsonDecode(r.body) as Map<String, dynamic>;
        _store(b['id_token'], b['refresh_token'], b['expires_in']);
        return _idToken!;
      }
    }
    await signIn();
    return _idToken!;
  }

  // ------------------------------------------------------------------ database
  Future<dynamic> _call(String method, String path, {Object? body, Map<String, String>? query}) async {
    final token = await _token();
    final uri = Uri.parse('$_base/$path.json').replace(queryParameters: {'auth': token, ...?query});
    final headers = {'Content-Type': 'application/json'};
    late http.Response r;
    final t = const Duration(seconds: 12);
    switch (method) {
      case 'GET':
        r = await http.get(uri, headers: headers).timeout(t);
        break;
      case 'PUT':
        r = await http.put(uri, headers: headers, body: jsonEncode(body)).timeout(t);
        break;
      case 'PATCH':
        r = await http.patch(uri, headers: headers, body: jsonEncode(body)).timeout(t);
        break;
      default:
        r = await http.delete(uri, headers: headers).timeout(t);
    }
    if (r.statusCode == 401) _idToken = null;
    if (r.statusCode != 200) throw FirebaseException('Database says ${r.statusCode} ${r.reasonPhrase ?? ''}'.trim(), r.statusCode);
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) => _call('GET', path, query: query);
  Future<void> put(String path, Object? value) => _call('PUT', path, body: value);
  Future<void> patch(String path, Map<String, dynamic> value) => _call('PATCH', path, body: value);
  Future<void> delete(String path) => _call('DELETE', path);

  // ------------------------------------------------------------------ home helpers
  /// First-time setup: this user becomes admin + member, the device account may write telemetry.
  Future<void> createHome({required String homeId, required String homeName, required String deviceUid}) async {
    await signIn();
    final me = uid!;
    await put('homes/$homeId/admins/$me', true);
    await put('homes/$homeId/members/$me', true);
    await put('homes/$homeId/devices/$deviceUid', true);
    await put('homes/$homeId/meta', {'name': homeName, 'created': DateTime.now().toUtc().toIso8601String()});
  }

  Future<Map<String, dynamic>> rules(String homeId) async {
    final v = await get('homes/$homeId/rules');
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  /// Writes (or deletes, when [rule] is null) one rule, then bumps rulesRev so every board re-syncs.
  Future<void> saveRule(String homeId, String ruleId, Map<String, dynamic>? rule) async {
    if (rule == null) {
      await delete('homes/$homeId/rules/$ruleId');
    } else {
      await put('homes/$homeId/rules/$ruleId', rule);
    }
    final cur = await get('homes/$homeId/rulesRev');
    await put('homes/$homeId/rulesRev', (cur is num ? cur.toInt() : 0) + 1);
  }

  /// kWh per day for one node, newest 14 days: {"20261017": 1.23, ...}
  Future<Map<String, double>> energy(String homeId, String nodeId) async {
    final v = await get('homes/$homeId/nodes/$nodeId/energy', query: {'orderBy': '"\$key"', 'limitToLast': '14'});
    if (v is! Map) return {};
    return {for (final e in v.entries) e.key as String: (e.value as num).toDouble()};
  }

  Future<void> pushOta({required String homeId, required String version, required String url, required String md5}) =>
      put('homes/$homeId/ota', {'v': version, 'url': url, 'md5': md5});

  Future<void> saveRooms(String homeId, List<String> names) => put('homes/$homeId/rooms', names);
}
