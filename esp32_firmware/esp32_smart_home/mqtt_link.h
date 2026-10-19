/*
  mqtt_link.h  -  secure MQTT (runs in the network task).
  --------------------------------------------------------
  Security: username + password AND TLS (WiFiClientSecure / NetworkClientSecure).
  The broker certificate is checked against the ESP32 built-in root CA bundle
  (Let's Encrypt, DigiCert, Amazon, Google ... - works with HiveMQ Cloud, EMQX
  Cloud, AWS, Mosquitto with Let's Encrypt). A private CA can be pasted in the
  app ("CA certificate"). "insecure" skips the check - only for testing.

  Topics  (<b> = base, default "smarthome", <n> = node id of this board)
    <b>/<n>/status        "online" / "offline"  (retained, last will)
    <b>/<n>/state         full state JSON       (retained)
    <b>/<n>/meter         energy JSON every 10 s
    <b>/<n>/<dev>/state   "ON" / "OFF"          (retained)
    <b>/<n>/<dev>/set     <- "ON" "OFF" "1" "0" "TOGGLE"
    <b>/<n>/cmd           <- command JSON (see commands.h), answer on <b>/<n>/resp
  Other boards: <b>/+/state is followed so Telegram/AI can switch relays on
  ANY board of the house by publishing to that board's <dev>/set topic.
*/
#pragma once
#if ENABLE_MQTT
#include <PubSubClient.h>
#include <NetworkClientSecure.h>

NetworkClientSecure mqttTls;
WiFiClient          mqttPlain;
PubSubClient        mqtt;
uint32_t mqttNextTry = 0, mqttBackoff = 2000, mqttLastMeter = 0;

struct RemoteNode { String node; String devs; };   // devs: "id|name|room|on;"
#define MAX_REMOTE 6
RemoteNode remotes[MAX_REMOTE];
int nRemotes = 0;

String topic(const String& tail) { return cfg.mqttBase + "/" + cfg.node + "/" + tail; }

bool mqttConfigured() { return cfg.mqttHost.length() > 0; }

bool mqttPublish(const String& t, const String& payload, bool retain) {
  if (!mqtt.connected()) return false;
  return mqtt.publish(t.c_str(), (const uint8_t*)payload.c_str(), payload.length(), retain);
}

// Publish "set" for a device on another board (used by AI / Telegram).
bool mqttSetRemote(const String& node, const String& dev, bool on) {
  return mqttPublish(cfg.mqttBase + "/" + node + "/" + dev + "/set", on ? "ON" : "OFF", false);
}

static void rememberRemote(const String& node, const char* payload, size_t len) {
  JsonDocument f;
  f["devices"][0]["id"] = true; f["devices"][0]["name"] = true;
  f["devices"][0]["room"] = true; f["devices"][0]["on"] = true; f["devices"][0]["type"] = true;
  JsonDocument d;
  if (deserializeJson(d, payload, len, DeserializationOption::Filter(f))) return;
  String devs;
  for (JsonObject o : d["devices"].as<JsonArray>()) {
    if (strcmp(o["type"] | "", "pir") == 0) continue;
    devs += (const char*)(o["id"] | ""); devs += '|';
    devs += (const char*)(o["name"] | ""); devs += '|';
    devs += (int)(o["room"] | 0); devs += '|';
    devs += (o["on"] | false) ? '1' : '0'; devs += ';';
    if (devs.length() > 1200) break;
  }
  for (int i = 0; i < nRemotes; i++) if (remotes[i].node == node) { remotes[i].devs = devs; return; }
  if (nRemotes < MAX_REMOTE) remotes[nRemotes++] = {node, devs};
}

static void onMqtt(char* t, byte* payload, unsigned int len) {
  String tp(t);
  String msg;                                   // copy: the buffer is reused by publish()
  msg.reserve(len);
  for (unsigned int i = 0; i < len; i++) msg += (char)payload[i];
  String mine = cfg.mqttBase + "/" + cfg.node + "/";
  if (tp.startsWith(mine)) {
    String tail = tp.substring(mine.length());
    if (tail == "cmd") {
      mqttPublish(topic("resp"), submitAndWait(msg, "mqtt"), false);
    } else if (tail.endsWith("/set")) {
      String dev = tail.substring(0, tail.length() - 4);
      String v = msg; v.trim(); v.toUpperCase();
      String cmd = (v == "TOGGLE") ? "{\"op\":\"toggle\",\"id\":\"" + dev + "\"}"
                 : "{\"op\":\"set\",\"id\":\"" + dev + "\",\"on\":" +
                   ((v == "ON" || v == "1" || v == "TRUE") ? "true" : "false") + "}";
      submitAndWait(cmd, "mqtt");
    }
    return;
  }
  // <base>/<other>/state -> directory of other boards
  if (tp.endsWith("/state")) {
    int a = cfg.mqttBase.length() + 1;
    int b = tp.indexOf('/', a);
    if (b > a && tp.substring(b) == "/state") rememberRemote(tp.substring(a, b), msg.c_str(), msg.length());
  }
}

void mqttSetup() {
  if (!mqttConfigured()) return;
  if (cfg.mqttTls) {
    if (cfg.mqttCa.length()) mqttTls.setCACert(cfg.mqttCa.c_str());
    else if (cfg.mqttInsecure) mqttTls.setInsecure();
    else mqttTls.useBuiltinCACertBundle();
    mqtt.setClient(mqttTls);
  } else {
    mqtt.setClient(mqttPlain);
    Serial.println("WARNING: MQTT without TLS - password is sent in clear text");
  }
  mqtt.setServer(cfg.mqttHost.c_str(), cfg.mqttPort);
  mqtt.setBufferSize(8192);
  mqtt.setKeepAlive(30);
  mqtt.setSocketTimeout(6);
  mqtt.setCallback(onMqtt);
}

void mqttLoop(uint32_t now) {
  if (!mqttConfigured()) return;
  if (mqtt.connected()) { mqtt.loop(); mqttUp = true; return; }
  mqttUp = false;
  if ((int32_t)(now - mqttNextTry) < 0) return;
  String id = cfg.node + "-" + String((uint32_t)esp_random(), HEX);
  String will = topic("status");
  bool ok = mqtt.connect(id.c_str(),
                         cfg.mqttUser.length() ? cfg.mqttUser.c_str() : nullptr,
                         cfg.mqttPass.length() ? cfg.mqttPass.c_str() : nullptr,
                         will.c_str(), 1, true, "offline");
  if (!ok) {
    Serial.printf("MQTT connect failed (state %d), retry in %lus\n", mqtt.state(), (unsigned long)mqttBackoff / 1000);
    mqttNextTry = now + mqttBackoff;
    mqttBackoff = min<uint32_t>(mqttBackoff * 2, 60000);
    return;
  }
  mqttBackoff = 2000;
  mqttUp = true;
  Serial.println("MQTT connected");
  mqttPublish(will, "online", true);
  mqtt.subscribe(topic("cmd").c_str(), 1);
  mqtt.subscribe(topic("+/set").c_str(), 1);
  mqtt.subscribe((cfg.mqttBase + "/+/state").c_str(), 0);
}

// Called by the network task when the snapshot changed.
void mqttPublishState(const String& snap, DevLite* devs, int n, bool full) {
  if (!mqtt.connected()) return;
  mqttPublish(topic("state"), snap, true);
  if (full) for (int i = 0; i < n; i++)
    mqttPublish(topic(String(devs[i].id) + "/state"), devs[i].on ? "ON" : "OFF", true);
}

void mqttPublishMeter(uint32_t now, const String& snap) {
  if (!mqtt.connected() || now - mqttLastMeter < 10000) return;
  mqttLastMeter = now;
  int a = snap.indexOf("\"meter\":");
  if (a < 0) return;
  int b = snap.indexOf("]", snap.indexOf("\"meters\":", a));
  if (b < 0) return;
  mqttPublish(topic("meter"), "{" + snap.substring(a, b + 1) + "}", false);
}
#else
bool mqttConfigured() { return false; }
bool mqttSetRemote(const String&, const String&, bool) { return false; }
#endif
