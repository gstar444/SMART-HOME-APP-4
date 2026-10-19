import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'models.dart';
import 'settings.dart';
import 'strings.dart';

enum ApiErrorKind { network, auth, server, firmware }

class ApiException implements Exception {
  ApiException(this.kind, [this.detail]);

  final ApiErrorKind kind;
  final String? detail;

  @override
  String toString() => 'ApiException($kind, $detail)';
}

/// Result of a call that returns data: either [data] or a user-readable [error].
class ApiResult<T> {
  const ApiResult.ok(this.data) : error = null;
  const ApiResult.fail(this.error) : data = null;

  final T? data;
  final String? error;

  bool get ok => error == null;
}

/// Talks to the ESP32 firmware over plain HTTP on the local network.
///
///   GET  /api/state                     -> everything (sensors, devices, wifi)
///   POST /api/set?id=light&on=1         -> turn one relay on / off
///   POST /api/dnd?on=1                  -> Do-Not-Disturb flag
///   POST /api/scene?id=alloff|goodnight|dinner
///   POST /api/device/add|update|delete  -> manage the saved device list
///   GET  /api/wifi/status|scan          -> Wi-Fi state / nearby networks
///   POST /api/wifi/connect|reset        -> join a new network / forget Wi-Fi
///
/// The controller polls /api/state every few seconds, applies changes
/// optimistically (the tile reacts instantly) and rolls back on failure.
class Esp32Controller extends ChangeNotifier with WidgetsBindingObserver {
  Esp32Controller(this._settings) {
    _applied = _settings.value;
    _settings.addListener(_onSettings);
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
    refresh();
  }

  final SettingsController _settings;
  late AppSettings _applied;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  Timer? _timer;
  bool _refreshing = false;
  bool _disposed = false;
  int _failures = 0;
  DateTime _lastWrite = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastSample;

  Esp32State? _state;
  bool _online = false;
  bool _loaded = false; // true after the first answer *or* the first failure
  String? _error;
  final Set<String> _pending = <String>{};
  final List<Map<String, double>> _samples = <Map<String, double>>[];

  Esp32State? get state => _state;
  bool get online => _online;
  bool get loaded => _loaded;
  String? get error => _error;
  bool isBusy(String key) => _pending.contains(key);

  /// Recent power samples (one every ~15 s, newest last): device id -> watts.
  /// The dashboard sums them per room to draw the small bar chart.
  List<Map<String, double>> get samples => List.unmodifiable(_samples);

  Tr get _tr => Tr.of(_settings.value);

  // ------------------------------------------------------------ lifecycle
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      refresh();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(seconds: _settings.value.pollSeconds),
      (_) => refresh(),
    );
  }

  void _onSettings() {
    final prev = _applied;
    final next = _settings.value;
    _applied = next;
    if (prev.activeUrl != next.activeUrl || prev.apiKey != next.apiKey) {
      _state = null;
      _online = false;
      _loaded = false;
      _error = null;
      _failures = 0;
      _samples.clear();
      _lastSample = null;
      notifyListeners();
      refresh();
    }
    if (prev.pollSeconds != next.pollSeconds) _startTimer();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _settings.removeListener(_onSettings);
    WidgetsBinding.instance.removeObserver(this);
    _http.close(force: true);
    super.dispose();
  }

  // -------------------------------------------------------------- polling
  Future<void> refresh() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    final startedAt = DateTime.now();
    final urlAtStart = _settings.value.activeUrl;
    try {
      final json = await _call('GET', 'state');
      if (urlAtStart == _settings.value.activeUrl) {
        final next = Esp32State.fromJson(json);
        // An answer that left before our latest write may still contain the
        // old value, so it must not overwrite the optimistic state.
        if (!startedAt.isBefore(_lastWrite)) {
          _state = next;
          _recordSample(next);
        }
        _online = true;
        _failures = 0;
        _error = null;
      }
    } catch (e) {
      if (urlAtStart == _settings.value.activeUrl) {
        _failures++;
        _error = _friendly(e);
        if (_failures >= 2 || _state == null) _online = false;
      }
    } finally {
      _refreshing = false;
      if (urlAtStart == _settings.value.activeUrl) _loaded = true;
      if (!_disposed) notifyListeners();
    }
  }

  void _recordSample(Esp32State s) {
    final now = DateTime.now();
    final last = _lastSample;
    if (last != null && now.difference(last) < const Duration(seconds: 15)) {
      return;
    }
    _lastSample = now;
    _samples.add({
      for (final d in s.devices)
        if (d.on && d.watts > 0) d.id: d.watts,
    });
    if (_samples.length > 20) _samples.removeAt(0);
  }

  // --------------------------------------------------------------- writes
  /// Returns null on success, otherwise a message that can be shown to the user.
  Future<String?> setDevice(String id, bool on) => _write(
        'set',
        {'id': id, 'on': on ? '1' : '0'},
        busyKey: id,
        optimistic: (s) => s.withDevice(id, on: on),
        revert: (s) => s.withDevice(id, on: !on),
      );

  Future<String?> setDnd(bool on) => _write(
        'dnd',
        {'on': on ? '1' : '0'},
        busyKey: 'dnd',
        optimistic: (s) => s.withDnd(on),
        revert: (s) => s.withDnd(!on),
      );

  Future<String?> runScene(String id) =>
      _write('scene', {'id': id}, busyKey: 'scene:$id');

  // ------------------------------------------------------- device list
  /// Adds a new device to the list saved on the ESP32.
  Future<String?> addDevice({
    required String name,
    required String icon,
    required int pin,
    required int room,
    int? watts,
  }) =>
      _write(
        'device/add',
        {
          'name': name,
          'icon': icon,
          'pin': '$pin',
          'room': '$room',
          if (watts != null) 'watts': '$watts',
        },
        busyKey: 'device:add',
      );

  /// Changes name / icon / GPIO pin / room of a saved device.
  Future<String?> updateDevice(
    String id, {
    String? name,
    String? icon,
    int? pin,
    int? room,
    int? watts,
  }) =>
      _write(
        'device/update',
        {
          'id': id,
          if (name != null) 'name': name,
          if (icon != null) 'icon': icon,
          if (pin != null) 'pin': '$pin',
          if (room != null) 'room': '$room',
          if (watts != null) 'watts': '$watts',
        },
        busyKey: id,
      );

  /// Removes a device from the list saved on the ESP32.
  Future<String?> deleteDevice(String id) =>
      _write('device/delete', {'id': id}, busyKey: id);

  // --------------------------------------------------------------- Wi-Fi
  // These talk to the ESP32 directly (not through the polled state), so they
  // also work while the ESP32 is in setup mode.

  /// Asks the ESP32 for nearby networks. Pass [rescan] on the first call, then
  /// call again (without it) until the result says `scanning == false`.
  Future<ApiResult<WifiScan>> wifiScan({bool rescan = false}) async {
    try {
      final json = await _call('GET', 'wifi/scan', rescan ? {'rescan': '1'} : null);
      return ApiResult<WifiScan>.ok(WifiScan.fromJson(json));
    } catch (e) {
      return ApiResult<WifiScan>.fail(_friendly(e));
    }
  }

  Future<ApiResult<WifiStatus>> wifiStatus() async {
    try {
      final json = await _call('GET', 'wifi/status');
      return ApiResult<WifiStatus>.ok(WifiStatus.fromJson(json));
    } catch (e) {
      return ApiResult<WifiStatus>.fail(_friendly(e));
    }
  }

  /// Tells the ESP32 to join [ssid]. Returns null when the request was
  /// accepted; the ESP32 then switches networks, so poll [wifiStatus].
  Future<String?> wifiConnect(String ssid, String password) async {
    try {
      final json = await _call('POST', 'wifi/connect', {'ssid': ssid, 'pass': password});
      if (json['ok'] == false) {
        return json['error']?.toString() ?? _tr.errServer;
      }
      return null;
    } catch (e) {
      return _friendly(e);
    }
  }

  /// Forgets the saved Wi-Fi; the ESP32 restarts in setup (hotspot) mode.
  Future<String?> wifiReset() async {
    try {
      final json = await _call('POST', 'wifi/reset');
      if (json['ok'] == false) {
        return json['error']?.toString() ?? _tr.errServer;
      }
      return null;
    } catch (e) {
      return _friendly(e);
    }
  }

  Future<String?> _write(
    String name,
    Map<String, String> query, {
    required String busyKey,
    Esp32State Function(Esp32State s)? optimistic,
    Esp32State Function(Esp32State s)? revert,
  }) async {
    final before = _state;
    if (before == null) return _tr.notConnected;
    _pending.add(busyKey);
    if (optimistic != null) _state = optimistic(before);
    _lastWrite = DateTime.now();
    notifyListeners();
    try {
      final json = await _call('POST', name, query);
      if (json['ok'] == false) {
        throw ApiException(ApiErrorKind.server, json['error']?.toString());
      }
      _online = true;
      _failures = 0;
      _error = null;
      return null;
    } catch (e) {
      final current = _state;
      if (revert != null && current != null) _state = revert(current);
      return _friendly(e);
    } finally {
      _pending.remove(busyKey);
      _lastWrite = DateTime.now();
      if (!_disposed) notifyListeners();
      // Re-read the real state shortly after, so the UI always converges.
      unawaited(Future<void>.delayed(const Duration(milliseconds: 300), refresh));
    }
  }

  // ----------------------------------------------------------------- http
  Future<Map<String, dynamic>> _call(
    String method,
    String name, [
    Map<String, String>? query,
  ]) async {
    try {
      final base = Uri.parse(_settings.value.activeUrl);
      final uri = base.replace(path: '/api/$name', queryParameters: query);
      final req = await _http
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 5));
      final key = _settings.value.apiKey;
      if (key.isNotEmpty) req.headers.set('X-API-Key', key);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (method != 'GET') req.contentLength = 0;
      final res = await req.close().timeout(const Duration(seconds: 6));
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 6));

      if (res.statusCode == 401 || res.statusCode == 403) {
        throw ApiException(ApiErrorKind.auth);
      }
      Map<String, dynamic>? json;
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {
        // handled below
      }
      // The ESP32 answered, but with a web page / 404 page instead of JSON:
      // it is still running an old firmware that has no /api/ endpoints.
      if (json == null && (res.statusCode == 404 || res.statusCode == 200)) {
        throw ApiException(ApiErrorKind.firmware);
      }
      // A JSON 404 "not found" means this endpoint does not exist: the ESP32
      // still runs an older firmware (e.g. v2 has no /api/device or /api/wifi).
      if (res.statusCode == 404 && json != null && json['error'] == 'not found') {
        throw ApiException(ApiErrorKind.firmware);
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw ApiException(
          ApiErrorKind.server,
          json?['error']?.toString() ?? 'HTTP ${res.statusCode}',
        );
      }
      if (json == null) throw ApiException(ApiErrorKind.firmware);
      return json;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(ApiErrorKind.network, 'timeout');
    } on SocketException catch (e) {
      throw ApiException(ApiErrorKind.network, e.message);
    } on HttpException catch (e) {
      throw ApiException(ApiErrorKind.network, e.message);
    } on FormatException catch (e) {
      throw ApiException(ApiErrorKind.network, e.message);
    }
  }

  String _friendly(Object e) {
    final tr = _tr;
    if (e is ApiException) {
      final detail = e.detail;
      return switch (e.kind) {
        ApiErrorKind.auth => tr.errAuth,
        ApiErrorKind.server => detail == null ? tr.errServer : tr.fwError(detail),
        ApiErrorKind.firmware => tr.errFirmware,
        ApiErrorKind.network => tr.errNetwork,
      };
    }
    return tr.errNetwork;
  }
}
