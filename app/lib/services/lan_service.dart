import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

/// Talks to ONE board over the home Wi-Fi (or its emergency hotspot, 192.168.4.1).
/// Used when the cloud / broker is unreachable. Every call carries the per-home API key.
///
/// NOTE: this is plain HTTP on the local network (Wi-Fi WPA2/WPA3 encrypts it over the air).
/// Do not use it on open or untrusted Wi-Fi; the cloud path (MQTT-TLS) is the secure one.
class LanClient {
  LanClient(this.ip, this.apiKey);
  final String ip, apiKey;

  Uri _u(String path) => Uri.parse('http://$ip$path');
  Map<String, String> get _h => {'X-API-Key': apiKey, 'Content-Type': 'application/json'};

  /// {"meta":{..},"state":{..},"status":{..}}  or null when the board cannot be reached.
  Future<Map<String, dynamic>?> state() async {
    try {
      final r = await http.get(_u('/api/state'), headers: _h).timeout(const Duration(seconds: 3));
      if (r.statusCode != 200) return null;
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Same command JSON as the MQTT <node>/cmd topic.
  Future<bool> cmd(Map<String, dynamic> body) async {
    try {
      final r = await http.post(_u('/api/cmd'), headers: _h, body: jsonEncode(body)).timeout(const Duration(seconds: 4));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> info(String ip) async {
    try {
      final r = await http.get(Uri.parse('http://$ip/api/info')).timeout(const Duration(seconds: 3));
      return r.statusCode == 200 ? jsonDecode(r.body) as Map<String, dynamic> : null;
    } catch (_) {
      return null;
    }
  }
}

class LanNode {
  const LanNode({required this.nodeId, required this.ip, this.fw = '', this.home = '', this.provisioned = false});
  final String nodeId, ip, fw, home;
  final bool provisioned;
}

/// Finds boards that advertise the "_smarthome._tcp" mDNS service.
Future<List<LanNode>> discoverLanNodes({Duration timeout = const Duration(seconds: 4)}) async {
  final client = MDnsClient();
  final found = <String, LanNode>{};
  try {
    await client.start();
    await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer('_smarthome._tcp.local'),
        timeout: timeout)) {
      String? ip;
      await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
          timeout: const Duration(seconds: 2))) {
        await for (final IPAddressResourceRecord a in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
            timeout: const Duration(seconds: 2))) {
          ip = a.address.address;
          break;
        }
      }
      final txt = <String, String>{};
      await for (final TxtResourceRecord t in client.lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(ptr.domainName),
          timeout: const Duration(seconds: 2))) {
        for (final line in t.text.split('\n')) {
          final i = line.indexOf('=');
          if (i > 0) txt[line.substring(0, i)] = line.substring(i + 1);
        }
      }
      final id = txt['node'];
      if (ip != null && id != null) {
        found[id] = LanNode(nodeId: id, ip: ip, fw: txt['fw'] ?? '', home: txt['home'] ?? '', provisioned: txt['prov'] == '1');
      }
    }
  } catch (_) {
    // multicast can be blocked by the router / phone: just return what we have
  } finally {
    client.stop();
  }
  return found.values.toList();
}
