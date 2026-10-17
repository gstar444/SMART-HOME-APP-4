import 'dart:math';

final Random _rng = Random.secure();

const String _lower = 'abcdefghijklmnopqrstuvwxyz0123456789';
const String _mixed = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';

/// Random id for homes / rules (lower-case letters and digits only).
String randomId(int length) => List.generate(length, (_) => _lower[_rng.nextInt(_lower.length)]).join();

/// Random secret (API keys, hotspot password). Look-alike characters are left out.
String randomSecret(int length) => List.generate(length, (_) => _mixed[_rng.nextInt(_mixed.length)]).join();

/// POSIX time-zone string the ESP32 understands, from the phone's current UTC offset.
/// India (+05:30) -> "UTC-05:30". POSIX counts the offset the other way round.
/// (Daylight-saving changes are not applied on the board; re-provision if your zone uses DST.)
String posixTz(Duration offset) {
  final m = offset.inMinutes;
  final sign = m >= 0 ? '-' : '+';
  final a = m.abs();
  final hh = (a ~/ 60).toString().padLeft(2, '0');
  final mm = (a % 60).toString().padLeft(2, '0');
  return m == 0 ? 'UTC0' : 'UTC$sign$hh:$mm';
}

/// Telegram chat ids as a clean list: "123, 456\n-100789" -> ['123','456','-100789'].
List<String> parseChatIds(String csv) =>
    csv.split(RegExp(r'[\s,;]+')).where((e) => RegExp(r'^-?\d{3,}$').hasMatch(e)).toList();

/// Names go into JSON and chat messages on the board; mirror its cleanName().
String cleanName(String s) => s.replaceAll(RegExp(r'["\\<>\x00-\x1f]'), '').trim();
