import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// Cold start is deliberately empty: no awaits, no plugin initialisation, no network.
/// The native splash (Android launch theme / iOS launch screen) stays up until the first
/// Flutter frame, and that frame is painted from the on-device cache. Settings, MQTT, LAN
/// discovery and Firebase all start AFTER the first frame, on demand (see state/*.dart).
void main() => runApp(const ProviderScope(child: SmartHomeApp()));
