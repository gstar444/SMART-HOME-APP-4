/// Finds v4 boards on the local network via mDNS (service `_smarthome._tcp`,
/// TXT `node=<id> fw=<version>`) and falls back to the classic esp32-home.local.
library;

import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

class FoundBoard {
  const FoundBoard({required this.name, required this.host, required this.port, this.ip});
  final String name;
  final String host;
  final int port;
  final String? ip;

  String get url => 'http://${ip ?? host}${port == 80 ? '' : ':$port'}/';
}

Future<List<FoundBoard>> discoverBoards({Duration timeout = const Duration(seconds: 4)}) async {
  final found = <String, FoundBoard>{};
  final client = MDnsClient(rawDatagramSocketFactory: (dynamic host, int port,
      {bool reuseAddress = true, bool reusePort = false, int ttl = 1}) {
    // reusePort is not supported on Android.
    return RawDatagramSocket.bind(host, port, reuseAddress: true, reusePort: false, ttl: ttl);
  });
  try {
    await client.start();
    for (final service in const ['_smarthome._tcp.local', '_http._tcp.local']) {
      await for (final ptr in client
          .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(service), timeout: timeout)) {
        await for (final srv in client.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName),
            timeout: const Duration(seconds: 2))) {
          if (service == '_http._tcp.local' && !srv.target.startsWith('esp32')) continue;
          String? ip;
          await for (final a in client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target),
              timeout: const Duration(seconds: 2))) {
            ip = a.address.address;
            break;
          }
          final name = ptr.domainName.split('.').first;
          found[ip ?? srv.target] = FoundBoard(name: name, host: srv.target, port: srv.port, ip: ip);
        }
      }
    }
  } catch (_) {
    // mDNS can fail on some networks; the list is simply empty then.
  } finally {
    client.stop();
  }
  return found.values.toList();
}
