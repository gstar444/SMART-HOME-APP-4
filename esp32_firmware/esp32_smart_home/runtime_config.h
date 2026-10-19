/*
  runtime_config.h  -  settings that the app changes at runtime.
  ---------------------------------------------------------------
  Stored as one JSON document in Preferences (namespace "smhcfg", key "cfg").
  GET  -> secrets are never sent back, only "<name>Set": true/false.
  SET  -> partial JSON, a missing key keeps the old value, "" clears it.

  Thread rule: the network task only READS the network fields and those are
  only changed by a restart (configSet() schedules one), so no lock is needed.
*/
#pragma once
#include <ArduinoJson.h>

struct RuntimeConfig {
  String node;                         // unique board name, used in MQTT/cloud paths
  String apiKey;                       // overrides API_KEY when not empty
  // MQTT
  String mqttHost, mqttUser, mqttPass, mqttBase, mqttCa;
  uint16_t mqttPort = DEF_MQTT_PORT;
  bool   mqttTls = true, mqttInsecure = false;
  // Telegram + AI
  String tgToken, tgChats;             // chats = "123,-1001234" (whitelist)
  String aiUrl, aiKey, aiModel;
  bool   remoteUnlock = false;         // allow Telegram/AI/voice to UNLOCK a lock
  // Sinric Pro (Alexa / Google Home)
  String sinricKey, sinricSecret, sinricMap;   // map = "sinricId=localId,..."
  // Cloud
  String cloudProvider = "off", cloudUrl, cloudKey;
  uint16_t cloudInterval = DEF_CLOUD_INTERVAL;
  // OTA
  String otaPass;
  // Energy meter
  String meterType = "none";          // none | pzem | acs712
  int    pzemRx = DEF_PZEM_RX, pzemTx = DEF_PZEM_TX;
  String meterAddrs = "248";           // PZEM modbus addresses, CSV (248 = single meter)
  String meterPins;                    // ACS712 ADC pins, CSV
  String meterRooms = "0";             // room of each meter, CSV
  uint16_t acsMvPerA = DEF_ACS_MV_PER_A;
  float  acsDivider = 1.5f;            // sensor volts / ADC volts (5V sensor -> 3.3V ADC)
  uint16_t mainsV = DEF_MAINS_V;
  // Offline / emergency mode + time
  bool   fallbackAp = true;
  uint16_t offlineTimeout = DEF_OFFLINE_TIMEOUT;
  String tz = DEF_TZ;
};

RuntimeConfig cfg;
String rulesJson = "[]";               // raw rules array (rules_engine.h parses it)
bool   configRestartPending = false;

#define CFG_NS "smhcfg"

String defaultNodeId() {
  uint8_t mac[6];
  WiFi.macAddress(mac);
  char b[16];
  snprintf(b, sizeof(b), "home-%02x%02x%02x", mac[3], mac[4], mac[5]);
  return String(b);
}

const char* effectiveApiKey() { return cfg.apiKey.length() ? cfg.apiKey.c_str() : API_KEY; }

// Node ids end up in MQTT topics and URLs: keep them to [a-z0-9_-].
String cleanNode(const String& s) {
  String o;
  for (size_t i = 0; i < s.length() && o.length() < 24; i++) {
    char c = tolower(s[i]);
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') o += c;
  }
  return o;
}

// ---- helpers to read one field from a JSON object, only when present
template <typename T>
static bool takeField(JsonVariantConst o, const char* key, T& out) {
  JsonVariantConst v = o[key];
  if (v.isNull() || !v.is<T>()) return false;
  T nv = v.as<T>();
  if (nv == out) return false;
  out = nv;
  return true;
}
static bool takeStr(JsonVariantConst o, const char* key, String& out) {
  JsonVariantConst v = o[key];
  if (v.isNull()) return false;
  String nv = v.is<const char*>() ? String(v.as<const char*>()) : v.as<String>();
  nv.trim();
  if (nv == out) return false;
  out = nv;
  return true;
}

void configToDoc(JsonDocument& d, bool withSecrets) {
  d["node"] = cfg.node;
  JsonObject m = d["mqtt"].to<JsonObject>();
  m["host"] = cfg.mqttHost; m["port"] = cfg.mqttPort; m["user"] = cfg.mqttUser;
  m["tls"] = cfg.mqttTls;   m["insecure"] = cfg.mqttInsecure; m["base"] = cfg.mqttBase;
  JsonObject t = d["telegram"].to<JsonObject>();
  t["chats"] = cfg.tgChats; t["remoteUnlock"] = cfg.remoteUnlock;
  JsonObject a = d["ai"].to<JsonObject>();
  a["url"] = cfg.aiUrl; a["model"] = cfg.aiModel;
  JsonObject s = d["sinric"].to<JsonObject>();
  s["map"] = cfg.sinricMap;
  JsonObject c = d["cloud"].to<JsonObject>();
  c["provider"] = cfg.cloudProvider; c["url"] = cfg.cloudUrl; c["interval"] = cfg.cloudInterval;
  JsonObject me = d["meter"].to<JsonObject>();
  me["type"] = cfg.meterType; me["rx"] = cfg.pzemRx; me["tx"] = cfg.pzemTx;
  me["addrs"] = cfg.meterAddrs; me["pins"] = cfg.meterPins; me["rooms"] = cfg.meterRooms;
  me["mvPerA"] = cfg.acsMvPerA; me["divider"] = cfg.acsDivider; me["mainsV"] = cfg.mainsV;
  JsonObject e = d["offline"].to<JsonObject>();
  e["fallbackAp"] = cfg.fallbackAp; e["timeout"] = cfg.offlineTimeout;
  d["tz"] = cfg.tz;
  if (withSecrets) {                   // only used for the flash copy, never sent out
    d["apiKey"] = cfg.apiKey;
    m["pass"] = cfg.mqttPass; m["ca"] = cfg.mqttCa;
    t["token"] = cfg.tgToken; a["key"] = cfg.aiKey;
    s["key"] = cfg.sinricKey; s["secret"] = cfg.sinricSecret;
    c["key"] = cfg.cloudKey;  d["otaPass"] = cfg.otaPass;
  } else {                             // tell the app which secrets are stored
    d["apiKeySet"] = cfg.apiKey.length() > 0;
    m["passSet"] = cfg.mqttPass.length() > 0; m["caSet"] = cfg.mqttCa.length() > 0;
    t["tokenSet"] = cfg.tgToken.length() > 0; a["keySet"] = cfg.aiKey.length() > 0;
    s["keySet"] = cfg.sinricKey.length() > 0; s["secretSet"] = cfg.sinricSecret.length() > 0;
    c["keySet"] = cfg.cloudKey.length() > 0;  d["otaPassSet"] = cfg.otaPass.length() > 0;
  }
}

// Applies a (partial) config. Returns "" on success or an error text.
// *netChanged is set when a network-task setting changed (needs a restart).
String applyConfig(JsonVariantConst d, bool* netChanged) {
  bool net = false;
  String node = cfg.node;
  if (takeStr(d, "node", node)) {
    node = cleanNode(node);
    if (node.length() == 0) return "node must use a-z 0-9 _ -";
    if (node != cfg.node) { cfg.node = node; net = true; }
  }
  takeStr(d, "apiKey", cfg.apiKey);
  JsonVariantConst m = d["mqtt"];
  if (m.is<JsonObjectConst>()) {
    net |= takeStr(m, "host", cfg.mqttHost);  net |= takeField<uint16_t>(m, "port", cfg.mqttPort);
    net |= takeStr(m, "user", cfg.mqttUser);  net |= takeStr(m, "pass", cfg.mqttPass);
    net |= takeField<bool>(m, "tls", cfg.mqttTls); net |= takeField<bool>(m, "insecure", cfg.mqttInsecure);
    net |= takeStr(m, "ca", cfg.mqttCa);
    if (takeStr(m, "base", cfg.mqttBase)) { net = true; if (!cfg.mqttBase.length()) cfg.mqttBase = DEF_MQTT_BASE; }
  }
  JsonVariantConst t = d["telegram"];
  if (t.is<JsonObjectConst>()) {
    net |= takeStr(t, "token", cfg.tgToken); net |= takeStr(t, "chats", cfg.tgChats);
    takeField<bool>(t, "remoteUnlock", cfg.remoteUnlock);
  }
  JsonVariantConst a = d["ai"];
  if (a.is<JsonObjectConst>()) {
    net |= takeStr(a, "url", cfg.aiUrl); net |= takeStr(a, "key", cfg.aiKey); net |= takeStr(a, "model", cfg.aiModel);
  }
  JsonVariantConst s = d["sinric"];
  if (s.is<JsonObjectConst>()) {
    net |= takeStr(s, "key", cfg.sinricKey); net |= takeStr(s, "secret", cfg.sinricSecret);
    net |= takeStr(s, "map", cfg.sinricMap);
  }
  JsonVariantConst c = d["cloud"];
  if (c.is<JsonObjectConst>()) {
    String p = cfg.cloudProvider;
    if (takeStr(c, "provider", p)) {
      if (p != "off" && p != "firebase" && p != "supabase") return "cloud.provider: off|firebase|supabase";
      cfg.cloudProvider = p; net = true;
    }
    if (takeStr(c, "url", cfg.cloudUrl)) { net = true; while (cfg.cloudUrl.endsWith("/")) cfg.cloudUrl.remove(cfg.cloudUrl.length() - 1); }
    net |= takeStr(c, "key", cfg.cloudKey);
    if (takeField<uint16_t>(c, "interval", cfg.cloudInterval)) cfg.cloudInterval = constrain(cfg.cloudInterval, 5, 3600);
  }
  takeStr(d, "otaPass", cfg.otaPass);
  JsonVariantConst me = d["meter"];
  if (me.is<JsonObjectConst>()) {
    String ty = cfg.meterType;
    if (takeStr(me, "type", ty)) {
      if (ty != "none" && ty != "pzem" && ty != "acs712") return "meter.type: none|pzem|acs712";
      cfg.meterType = ty;
    }
    takeField<int>(me, "rx", cfg.pzemRx);  takeField<int>(me, "tx", cfg.pzemTx);
    takeStr(me, "addrs", cfg.meterAddrs);  takeStr(me, "pins", cfg.meterPins);
    takeStr(me, "rooms", cfg.meterRooms);
    takeField<uint16_t>(me, "mvPerA", cfg.acsMvPerA); takeField<float>(me, "divider", cfg.acsDivider);
    takeField<uint16_t>(me, "mainsV", cfg.mainsV);
    if (cfg.acsMvPerA < 10) cfg.acsMvPerA = DEF_ACS_MV_PER_A;
    if (cfg.acsDivider < 1.0f || cfg.acsDivider > 5.0f) cfg.acsDivider = 1.5f;
  }
  JsonVariantConst e = d["offline"];
  if (e.is<JsonObjectConst>()) {
    takeField<bool>(e, "fallbackAp", cfg.fallbackAp);
    if (takeField<uint16_t>(e, "timeout", cfg.offlineTimeout)) cfg.offlineTimeout = constrain(cfg.offlineTimeout, 15, 3600);
  }
  if (takeStr(d, "tz", cfg.tz)) configTzTime(cfg.tz.c_str(), "pool.ntp.org", "time.google.com");
  if (netChanged) *netChanged = net;
  return "";
}

void saveConfig() {
  JsonDocument d;
  configToDoc(d, true);
  String out;
  serializeJson(d, out);
  Preferences p;
  p.begin(CFG_NS, false);
  p.putString("cfg", out);
  p.end();
}

void saveRules() {
  Preferences p;
  p.begin(CFG_NS, false);
  p.putString("rules", rulesJson);
  p.end();
}

void loadConfig() {
  cfg.mqttBase = DEF_MQTT_BASE;
  cfg.aiUrl    = DEF_AI_URL;
  cfg.aiModel  = DEF_AI_MODEL;
  Preferences p;
  p.begin(CFG_NS, true);
  String raw = p.getString("cfg", "");
  rulesJson  = p.getString("rules", "[]");
  p.end();
  if (raw.length()) {
    JsonDocument d;
    if (!deserializeJson(d, raw)) applyConfig(d.as<JsonVariantConst>(), nullptr);
  }
  if (cfg.node.length() == 0) cfg.node = defaultNodeId();
}

// True when chatId (as text) is in the whitelist (CSV in cfg.tgChats).
bool chatAllowed(const String& chatId) {
  if (chatId.length() == 0) return false;
  int s = 0;
  String list = cfg.tgChats + ",";
  while (s < (int)list.length()) {
    int e = list.indexOf(',', s);
    String one = list.substring(s, e);
    one.trim();
    if (one.length() && one == chatId) return true;
    s = e + 1;
  }
  return false;
}

// "a,b,c" -> item i ("" when missing)
String csvItem(const String& csv, int i) {
  int s = 0, n = 0;
  while (s <= (int)csv.length()) {
    int e = csv.indexOf(',', s);
    if (e < 0) e = csv.length();
    if (n == i) { String v = csv.substring(s, e); v.trim(); return v; }
    n++;
    s = e + 1;
  }
  return "";
}
