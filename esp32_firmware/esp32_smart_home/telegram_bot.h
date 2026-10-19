/*
  telegram_bot.h  -  UniversalTelegramBot with a chat-id WHITELIST.
  ------------------------------------------------------------------
  * Only chats listed in the app ("Allowed chat IDs", CSV) are accepted.
    Every other message is DROPPED silently (logged on Serial only).
  * While the list is empty the bot answers ONLY /myid so you can find your id.
  * Commands: /help /status /devices /on <name> /off <name> /scene <id>
             /alloff /energy /myid
  * Free text ("bedroom ki light band karo", "turn on fan") is parsed locally;
    if that fails and an AI key is set, the Cloud LLM (ai_llm.h) decides.
  * Locks cannot be UNLOCKED from Telegram unless "remote unlock" is enabled.
*/
#pragma once
#if ENABLE_TELEGRAM
#include <UniversalTelegramBot.h>
#include <NetworkClientSecure.h>

NetworkClientSecure   tgClient;
UniversalTelegramBot* bot = nullptr;
uint32_t tgLastPoll = 0;
String   roomNames;                 // "Hall,Bedroom,..." from the cloud (optional)

bool tgConfigured() { return cfg.tgToken.length() > 20; }

void telegramSetup() {
  if (!tgConfigured()) return;
  tgClient.useBuiltinCACertBundle();
  bot = new UniversalTelegramBot(cfg.tgToken, tgClient);
  bot->waitForResponse = 4000;
}

static String lower(String s) { s.toLowerCase(); return s; }

static bool hasWord(const String& t, const char* const* words, size_t n) {
  for (size_t i = 0; i < n; i++) if (t.indexOf(words[i]) >= 0) return true;
  return false;
}

static int roomFromText(const String& t) {
  for (int i = 0; i < 12; i++) {
    String n = csvItem(roomNames, i);
    if (n.length() && t.indexOf(lower(n)) >= 0) return i;
  }
  for (int i = 1; i <= 9; i++) {
    String a = "room " + String(i), b = "room" + String(i), c = "kamra " + String(i), d = "कमरा " + String(i);
    if (t.indexOf(a) >= 0 || t.indexOf(b) >= 0 || t.indexOf(c) >= 0 || t.indexOf(d) >= 0) return i - 1;
  }
  return -1;
}

// Tries to understand simple sentences. Returns "" when not understood.
String localParse(const String& raw, DevLite* devs, int n) {
  static const char* const ON[]  = {" on", "chalu", "chalao", "jalao", "start", "open", "kholo", "चालू", "जला", "खोल", "ऑन"};
  static const char* const OFF[] = {" off", "band", "bujha", "stop", "close", "बंद", "बुझा", "ऑफ"};
  String t = " " + lower(raw) + " ";
  bool off = hasWord(t, OFF, sizeof(OFF) / sizeof(OFF[0]));
  bool on  = !off && hasWord(t, ON, sizeof(ON) / sizeof(ON[0]));
  if (!on && !off) return "";
  int room = roomFromText(t);
  bool all = t.indexOf(" all ") >= 0 || t.indexOf(" sab") >= 0 || t.indexOf("सब") >= 0 || t.indexOf("everything") >= 0;
  String said;
  int hits = 0;
  for (int i = 0; i < n; i++) {
    if (!strcmp(devs[i].type, "pir")) continue;
    String name = lower(devs[i].name), id = lower(devs[i].id), icon = lower(devs[i].icon);
    bool match = t.indexOf(name) >= 0 || t.indexOf(" " + id + " ") >= 0 || t.indexOf(icon) >= 0;
    if (!match) continue;
    if (room >= 0 && devs[i].room != room) continue;
    String r = submitAndWait("{\"op\":\"set\",\"id\":\"" + String(devs[i].id) + "\",\"on\":" + (on ? "true" : "false") + "}", "telegram");
    said += String(devs[i].name) + (r.indexOf("\"ok\":true") >= 0 ? (on ? " ON\n" : " OFF\n") : " - refused\n");
    hits++;
  }
  if (hits) return said;
  if (room >= 0) {
    submitAndWait("{\"op\":\"room\",\"room\":" + String(room) + ",\"on\":" + (on ? "true" : "false") + "}", "telegram");
    return "Room " + String(room + 1) + (on ? " ON" : " OFF");
  }
  if (all) {
    submitAndWait(String("{\"op\":\"all\",\"on\":") + (on ? "true" : "false") + "}", "telegram");
    return on ? "All ON" : "All OFF";
  }
  return "";
}

static String statusText(DevLite* devs, int n, const String& snap) {
  String s = String(DEVICE_NAME) + " (" + cfg.node + ")\n";
  JsonDocument f; f["temp"] = true; f["hum"] = true; f["powerW"] = true; f["meter"] = true;
  JsonDocument d;
  if (!deserializeJson(d, snap, DeserializationOption::Filter(f))) {
    if (!d["temp"].isNull()) s += "Temp " + String(d["temp"].as<float>(), 1) + " C  Hum " + String(d["hum"].as<float>(), 0) + " %\n";
    if (d["meter"]["ok"] | false)
      s += String(d["meter"]["v"].as<float>(), 1) + " V  " + String(d["meter"]["a"].as<float>(), 2) + " A  " +
           String(d["meter"]["w"].as<float>(), 0) + " W  " + String(d["meter"]["kwh"].as<float>(), 2) + " kWh\n";
    else s += "Power (estimate) " + String(d["powerW"].as<float>(), 0) + " W\n";
  }
  for (int i = 0; i < n; i++)
    s += String(devs[i].on ? "🟢 " : "⚪ ") + devs[i].name + " (" + devs[i].id + ", room " + (devs[i].room + 1) + ")\n";
  return s;
}

void handleTelegramMessage(const telegramMessage& m) {
  String chat = m.chat_id;
  String text = m.text;
  text.trim();
  bool emptyList = cfg.tgChats.length() == 0;
  if (text == "/myid" && (emptyList || chatAllowed(chat))) {
    bot->sendMessage(chat, "Your chat id: " + chat + "\nAdd it in the app: Settings -> Advanced -> Telegram.", "");
    return;
  }
  if (!chatAllowed(chat)) {                       // whitelist: drop everything else
    Serial.printf("Telegram: dropped message from unauthorised chat %s\n", chat.c_str());
    return;
  }
  String snap = getSnapshot();
  static DevLite devs[MAX_DEVICES];
  int n = parseDevices(snap, devs, MAX_DEVICES);
  String reply;
  String low = lower(text);
  if (low == "/start" || low == "/help") {
    reply = "Commands:\n/status\n/devices\n/on <name>\n/off <name>\n/scene alloff|goodnight|dinner\n/alloff\n/energy\n/myid\n"
            "Or just write: \"turn on the fan\", \"room 2 ki light band karo\".";
  } else if (low == "/status" || low == "/devices" || low == "/energy") {
    reply = statusText(devs, n, snap);
  } else if (low == "/alloff") {
    submitAndWait("{\"op\":\"all\",\"on\":false}", "telegram");
    reply = "All OFF";
  } else if (low.startsWith("/scene ")) {
    String r = submitAndWait("{\"op\":\"scene\",\"id\":\"" + text.substring(7) + "\"}", "telegram");
    reply = r.indexOf("\"ok\":true") >= 0 ? "Scene started" : "Unknown scene";
  } else {
    String t = text;
    if (low.startsWith("/on ")) t = text.substring(4) + " on";
    else if (low.startsWith("/off ")) t = text.substring(5) + " off";
    reply = localParse(t, devs, n);
#if ENABLE_AI
    if (!reply.length() && aiConfigured()) reply = aiHandle(text, devs, n, roomNames);
#endif
    if (!reply.length()) reply = "Sorry, I did not understand. Try /help";
  }
  bot->sendMessage(chat, reply, "");
}

// Network task: poll every 2 s (short HTTPS call, blocks only this task).
void telegramTick(uint32_t now) {
  if (!bot || now - tgLastPoll < 2000) return;
  tgLastPoll = now;
  int n = bot->getUpdates(bot->last_message_received + 1);
  tgUp = n >= 0;
  while (n > 0) {
    for (int i = 0; i < n; i++) handleTelegramMessage(bot->messages[i]);
    n = bot->getUpdates(bot->last_message_received + 1);
  }
}
#endif
