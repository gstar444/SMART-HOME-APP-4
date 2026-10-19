/// JSON helper for the v4 firmware endpoints (/api/config, /api/rules,
/// /api/energy, /api/cmd, /api/ota/...). Uses the same board URL and
/// X-API-Key as the dashboard, without touching the dashboard's controller.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../settings.dart';

class BoardApiException implements Exception {
  BoardApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BoardApi {
  BoardApi(this.settings);

  final SettingsController settings;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(settings.value.activeUrl);
    return base.replace(path: path, queryParameters: query);
  }

  Future<Map<String, dynamic>> get(String path) => _send('GET', path);

  Future<Map<String, dynamic>> post(String path, [Object? body]) => _send('POST', path, body);

  /// Runs one command from the firmware's command language (commands.h).
  Future<Map<String, dynamic>> cmd(Map<String, dynamic> command) => post('/api/cmd', command);

  Future<Map<String, dynamic>> _send(String method, String path, [Object? body]) async {
    try {
      final req = await _http.openUrl(method, _uri(path)).timeout(const Duration(seconds: 6));
      final key = settings.value.apiKey;
      if (key.isNotEmpty) req.headers.set('X-API-Key', key);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      } else if (method != 'GET') {
        req.contentLength = 0;
      }
      final res = await req.close().timeout(const Duration(seconds: 10));
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
      if (res.statusCode == 401) throw BoardApiException('Wrong API key');
      Map<String, dynamic>? json;
      try {
        final d = jsonDecode(text);
        if (d is Map<String, dynamic>) json = d;
      } catch (_) {}
      if (json == null) {
        throw BoardApiException(res.statusCode == 404
            ? 'This board runs an older firmware - flash v4 first'
            : 'HTTP ${res.statusCode}');
      }
      if (json['ok'] == false) throw BoardApiException(json['error']?.toString() ?? 'error');
      return json;
    } on BoardApiException {
      rethrow;
    } on TimeoutException {
      throw BoardApiException('Board not reachable (timeout)');
    } on SocketException {
      throw BoardApiException('Board not reachable');
    } on HttpException catch (e) {
      throw BoardApiException(e.message);
    }
  }

  /// Uploads a firmware .bin (multipart field "firmware").
  Future<void> uploadFirmware(List<int> bytes, String filename) async {
    const boundary = '----esp32fwboundary7d1e';
    final head = utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="firmware"; '
        'filename="$filename"\r\nContent-Type: application/octet-stream\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final req = await _http.postUrl(_uri('/api/ota/upload'));
    final key = settings.value.apiKey;
    if (key.isNotEmpty) req.headers.set('X-API-Key', key);
    req.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
    req.contentLength = head.length + bytes.length + tail.length;
    req
      ..add(head)
      ..add(bytes)
      ..add(tail);
    final res = await req.close().timeout(const Duration(minutes: 3));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw BoardApiException('Upload failed: $text');
  }

  void close() => _http.close(force: true);
}
