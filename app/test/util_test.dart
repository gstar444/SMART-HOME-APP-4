import 'package:esp32_controller/core/util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('POSIX time zone (sign is inverted)', () {
    expect(posixTz(const Duration(hours: 5, minutes: 30)), 'UTC-05:30');
    expect(posixTz(const Duration(hours: -5)), 'UTC+05:00');
    expect(posixTz(Duration.zero), 'UTC0');
  });

  test('chat ids are cleaned', () {
    expect(parseChatIds('123, 456\n-100789 abc 12'), ['123', '456', '-100789']);
    expect(parseChatIds(''), isEmpty);
  });

  test('names are scrubbed like the firmware does', () {
    expect(cleanName('a"b<c>\\d'), 'abcd');
    expect(cleanName('  Lamp  '), 'Lamp');
  });

  test('secrets are random and the right length', () {
    expect(randomSecret(24).length, 24);
    expect(randomSecret(24), isNot(randomSecret(24)));
    expect(RegExp(r'^[a-z0-9]{8}$').hasMatch(randomId(8)), true);
  });
}
