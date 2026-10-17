import 'package:flutter/services.dart';

import 'models/models.dart';

/// Android's built-in speech dialog, opened through MainActivity.kt (kept from v3).
/// No extra Flutter plugin or microphone permission: the system recognizer UI does the listening.
const MethodChannel _voiceChannel = MethodChannel('esp32_controller/voice');

class VoiceUnavailable implements Exception {}

/// Opens the speech dialog once and returns what the user said (null = cancelled).
Future<String?> listenOnce({required bool hindi, required String prompt}) async {
  try {
    return await _voiceChannel.invokeMethod<String>('listen', {'locale': hindi ? 'hi-IN' : 'en-IN', 'prompt': prompt});
  } on MissingPluginException {
    throw VoiceUnavailable();
  } on PlatformException catch (e) {
    if (e.code == 'unavailable') throw VoiceUnavailable();
    return null;
  }
}

class VoiceTarget {
  const VoiceTarget(this.nodeId, this.devId, this.on);
  final String nodeId, devId;
  final bool on;
}

class VoiceAction {
  const VoiceAction({this.scene, this.targets = const [], this.lockBlocked = false});
  final String? scene;
  final List<VoiceTarget> targets;
  final bool lockBlocked; // the user asked to unlock a door by voice: we never do that
}

const Map<String, List<String>> _aliases = {
  'light': ['light', 'lights', 'lamp', 'bulb', 'batti', 'लाइट', 'लैंप', 'बत्ती'],
  'fan': ['fan', 'pankha', 'pankhe', 'पंखा', 'पंखे'],
  'heater': ['heater', 'geyser', 'हीटर', 'गीजर'],
  'curtain': ['curtain', 'curtains', 'parda', 'parde', 'पर्दा', 'परदा', 'पर्दे'],
  'purifier': ['purifier', 'प्यूरीफायर', 'प्यूरिफायर'],
  'siren': ['siren', 'alarm', 'सायरन', 'अलार्म'],
  'lock': ['lock', 'door', 'tala', 'taala', 'darwaza', 'ताला', 'दरवाजा', 'दरवाज़ा'],
  'plug': ['plug', 'socket', 'प्लग', 'सॉकेट'],
};

const Set<String> _onWords = {
  'on', 'start', 'open', 'chalu', 'chala', 'chalao', 'jala', 'jalao', 'चालू', 'ऑन', 'चला', 'चलाओ', 'जला', 'जलाओ', 'खोल', 'खोलो',
};
const Set<String> _offWords = {
  'off', 'stop', 'close', 'band', 'bandh', 'bujha', 'bujhao', 'बंद', 'बन्द', 'ऑफ', 'ऑफ़', 'बुझा', 'बुझाओ',
};
const Set<String> _unlockWords = {'unlock', 'open', 'khol', 'kholo', 'खोल', 'खोलो', 'खोलिए'};
const List<String> _everywhere = ['everywhere', 'all rooms', 'every room', 'whole house', 'sab kamre', 'सब कमरे', 'पूरे घर'];

final RegExp _wordRe = RegExp(r'[\p{L}\p{M}]+', unicode: true);
final RegExp _roomNumRe = RegExp(r'room\s*(\d)');

/// Turns a spoken sentence into an action across ALL rooms. Understands English, Hindi
/// (Devanagari) and Hinglish: "light on", "पंखा बंद करो", "room 2 fan chalu", "heater off everywhere".
///
/// Which room? 1) a room named in the sentence ("room 2", "bedroom"), 2) "everywhere", otherwise
/// 3) the room tab that is on screen ([currentRoom]) - "light on" must not light the whole house.
VoiceAction? parseVoice(String raw, List<NodeInfo> nodes, {required int currentRoom, required List<String> roomNames}) {
  final text = raw.toLowerCase().trim();
  if (text.isEmpty) return null;
  final tokens = _wordRe.allMatches(text).map((m) => m.group(0)!).toList();
  bool hasAny(Iterable<String> words) => tokens.any(words.contains);
  bool saysPhrase(List<String> phrases) => phrases.any(text.contains);

  if (saysPhrase(['all off', 'everything off', 'sab band', 'sab bandh', 'सब बंद', 'सब बन्द', 'सभी बंद'])) {
    return const VoiceAction(scene: 'alloff');
  }
  if (saysPhrase(['good night', 'goodnight', 'गुड नाइट', 'शुभ रात्रि'])) return const VoiceAction(scene: 'goodnight');
  if (saysPhrase(['dinner', 'डिनर'])) return const VoiceAction(scene: 'dinner');

  // ---- which rooms?
  final named = <int>{};
  final m = _roomNumRe.firstMatch(text);
  if (m != null) named.add(int.parse(m.group(1)!) - 1);
  for (var i = 0; i < roomNames.length; i++) {
    final n = roomNames[i].toLowerCase();
    if (n.length > 2 && text.contains(n)) named.add(i);
  }
  for (final n in nodes) {
    final rn = n.roomName.toLowerCase();
    if (rn.length > 2 && text.contains(rn)) named.add(n.room);
  }
  final everywhere = saysPhrase(_everywhere);
  final candidates = nodes.where((n) => everywhere || (named.isNotEmpty ? named.contains(n.room) : n.room == currentRoom)).toList();

  final wantsOn = hasAny(_onWords);
  final wantsOff = hasAny(_offWords);
  final wantsUnlock = hasAny(_unlockWords);
  final result = <VoiceTarget>[];
  var lockBlocked = false;

  // A device called by its own name ("bulb 2 on") means only that device.
  bool nameOf(DeviceInfo d) => d.name.isNotEmpty && text.contains(d.name.toLowerCase());
  final anyNamed = candidates.any((n) => n.devices.any((d) => d.controllable && nameOf(d)));

  for (final n in candidates) {
    for (final d in n.devices) {
      if (!d.controllable) continue;
      final nameHit = nameOf(d);
      if (anyNamed && !nameHit) continue;
      final aliasHit = (_aliases[d.icon] ?? const <String>[]).any(tokens.contains) || (d.isLock && tokens.contains('unlock'));
      if (!nameHit && !aliasHit) continue;

      if (d.isLock) {
        if (wantsUnlock) {
          lockBlocked = true;
        } else if (wantsOff || tokens.contains('lock') || tokens.contains('ताला')) {
          result.add(VoiceTarget(n.id, d.id, true)); // locking is always safe
        }
        continue;
      }
      if (!wantsOn && !wantsOff) continue;
      result.add(VoiceTarget(n.id, d.id, wantsOn && !wantsOff));
    }
  }
  if (result.isEmpty && !lockBlocked) return null;
  return VoiceAction(targets: result, lockBlocked: lockBlocked);
}
