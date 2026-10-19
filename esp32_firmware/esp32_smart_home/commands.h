/*
  commands.h  -  ONE command language for every channel.
  -------------------------------------------------------
  HTTP (/api/cmd), MQTT (<base>/<node>/cmd), BLE, Telegram, AI, Sinric Pro and
  the cloud all send the same small JSON commands, e.g.
     {"op":"set","id":"light","on":true}      {"op":"toggle","id":"fan"}
     {"op":"room","room":1,"on":false}        {"op":"all","on":false}
     {"op":"scene","id":"goodnight"}          {"op":"dnd","on":true}
     {"op":"state"}  {"op":"info"}  {"op":"ping"}
     {"op":"config_get"}  {"op":"config_set","cfg":{...}}
     {"op":"rules_get"}   {"op":"rules_set","rules":[...]}
     {"op":"wifi","ssid":"..","pass":".."}    {"op":"meter_reset"}
     {"op":"ota","url":"https://.../fw.bin"}  {"op":"restart"}
  The relays are ONLY touched by loop() (core 1). Other tasks (network task,
  BLE host task) push a CmdJob into a queue and loop() runs it - no races.
*/
#pragma once

// ---- status shared between the tasks (written by one task, read by others)
volatile bool     netInternet   = false;   // internet reachable (network task)
volatile uint32_t lastOnlineMs  = 0;       // last time internet + broker were fine
volatile bool     mqttUp        = false;
volatile bool     tgUp          = false;
volatile bool     sinricUp      = false;
volatile bool     bleClient     = false;
volatile bool     emergencyMode = false;
char              cloudStatus[24] = "off";
volatile bool     otaRequested  = false;
char              otaUrl[256]   = "";
volatile uint32_t changeVersion = 1;       // bumps whenever a device / dnd changes

enum CmdSink : uint8_t { SINK_WAIT, SINK_BLE, SINK_NONE };
struct CmdJob {
  String            in;
  String            src;
  String            out;
  CmdSink           sink;
  SemaphoreHandle_t done;
};
QueueHandle_t cmdQueue = nullptr;

String okJson(const char* extra = nullptr) {
  String s = "{\"ok\":true";
  if (extra) { s += ','; s += extra; }
  return s + "}";
}
String errJson(const String& e) { return String("{\"ok\":false,\"error\":\"") + esc(e) + "\"}"; }

float estimatedPowerW() {
  float w = 0;
  for (size_t i = 0; i < nDevices; i++)
    if (devices[i].on && !strcmp(devices[i].type, "switch")) w += devices[i].watts;
  return w;
}

void setRoom(int room, bool on, const char* src) {
  for (size_t i = 0; i < nDevices; i++) {
    Device& d = devices[i];
    if (d.room != room || strcmp(d.type, "switch")) continue;
    if (on && dnd && !strcmp(d.icon, "siren")) continue;
    setDevice(d, on);
  }
}

bool sourceIsRemote(const String& src) {
  return src == "telegram" || src == "ai" || src == "sinric" || src == "voice" || src == "cloud";
}

String setOne(const char* id, bool on, const String& src) {
  Device* d = findDevice(id);
  if (!d || !strcmp(d->type, "pir")) return errJson("unknown device");
  if (dnd && on && !strcmp(d->icon, "siren")) return errJson("DND mode is on");
  if (!strcmp(d->type, "lock") && !on && sourceIsRemote(src) && !cfg.remoteUnlock)
    return errJson("unlocking from " + src + " is disabled");
  setDevice(*d, on);
  return okJson();
}

String infoJson() {
  String j = "{\"ok\":true,\"name\":\""; j += esc(DEVICE_NAME);
  j += "\",\"node\":\""; j += cfg.node;
  j += "\",\"fw\":\"";   j += FW_VERSION;
  j += "\",\"ip\":\"";   j += ipString();
  j += "\",\"mac\":\"";  j += WiFi.macAddress();
  j += "\",\"provisioned\":"; j += jsonBool(savedSsid.length() > 0 || hasBuiltInWifi());
  j += ",\"features\":[";
  bool first = true;
  auto add = [&](const char* f) { if (!first) j += ','; first = false; j += '"'; j += f; j += '"'; };
#if ENABLE_MQTT
  add("mqtt");
#endif
#if ENABLE_TELEGRAM
  add("telegram");
#endif
#if ENABLE_AI
  add("ai");
#endif
#if ENABLE_SINRIC
  add("sinric");
#endif
#if ENABLE_CLOUD
  add("cloud");
#endif
#if ENABLE_OTA
  add("ota");
#endif
#if ENABLE_BLE
  add("ble");
#endif
#if ENABLE_METER
  add("meter");
#endif
  j += "]}";
  return j;
}

String configGetJson() {
  JsonDocument c;
  configToDoc(c, false);
  String body;
  serializeJson(c, body);                  // ArduinoJson 7 replaces the string
  return "{\"ok\":true,\"cfg\":" + body + "}";
}

String configSet(JsonVariantConst c) {
  if (!c.is<JsonObjectConst>()) return errJson("cfg object required");
  String oldMeter = cfg.meterType + cfg.meterAddrs + cfg.meterPins + cfg.meterRooms + cfg.pzemRx + cfg.pzemTx;
  bool net = false;
  String e = applyConfig(c, &net);
  if (e.length()) return errJson(e);
  saveConfig();
  String newMeter = cfg.meterType + cfg.meterAddrs + cfg.meterPins + cfg.meterRooms + cfg.pzemRx + cfg.pzemTx;
  if (newMeter != oldMeter) { saveAcsEnergy(); meterSetup(); }
  if (net) {                                       // network settings: clean restart
    configRestartPending = true;
    restartPending = true;
    restartAt = millis() + 1500;
  }
  return okJson(net ? "\"restart\":true" : "\"restart\":false");
}

String rulesSet(JsonVariantConst r) {
  String raw;
  if (r.is<const char*>()) raw = r.as<const char*>();
  else serializeJson(r, raw);
  if (raw.length() > 6000) return errJson("rules too large");
  String e = loadRules(raw);
  if (e.length()) { loadRules(rulesJson); return errJson(e); }
  if (raw != rulesJson) { rulesJson = raw; saveRules(); }
  return okJson((String("\"rules\":") + nRules).c_str());
}

String wifiFromCommand(const String& ssid, const String& pass) {
  if (ssid.length() == 0 || ssid.length() > 32) return errJson("Wi-Fi name must be 1 to 32 bytes");
  if (pass.length() != 0 && (pass.length() < 8 || pass.length() > 63)) return errJson("password must be 8 to 63 characters");
  if (connState != CS_IDLE) return errJson("already connecting");
  pendSsid = ssid; pendPass = pass;
  pendAt = millis() + 1000;
  connState = CS_PENDING;
  lastWifiError = "";
  return okJson("\"pending\":true");
}

// Runs one command. ONLY call from loop() (core 1).
String runCommand(const String& json, const String& src) {
  JsonDocument d;
  if (deserializeJson(d, json)) return errJson("bad JSON");
  String op = d["op"] | "";
  if (op == "ping")  return okJson("\"pong\":true");
  if (op == "info")  return infoJson();
  if (op == "state") return stateJson();
  if (op == "set" || op == "toggle") {
    String id = d["id"] | "";
    Device* dv = findDevice(id.c_str());
    bool on = op == "toggle" ? (dv ? !dv->on : false) : (d["on"] | false);
    return setOne(id.c_str(), on, src);
  }
  if (op == "room") { setRoom(d["room"] | 0, d["on"] | false, src.c_str()); return okJson(); }
  if (op == "all")  {
    bool on = d["on"] | false;
    if (on) for (size_t i = 0; i < nDevices; i++) { if (!strcmp(devices[i].type, "switch") && strcmp(devices[i].icon, "siren")) setDevice(devices[i], true); }
    else allSwitchesOff();
    return okJson();
  }
  if (op == "scene") return runSceneById(d["id"] | "") ? okJson() : errJson("unknown scene");
  if (op == "dnd")   { setDndMode(d["on"] | false); return okJson(); }
  if (op == "config_get") return configGetJson();
  if (op == "config_set") return configSet(d["cfg"]);
  if (op == "rules_get")  return String("{\"ok\":true,\"rules\":") + rulesJson + "}";
  if (op == "rules_set")  return rulesSet(d["rules"]);
  if (op == "meter_reset") return meterResetEnergy() ? okJson() : errJson("meter did not answer");
  if (op == "wifi")  return wifiFromCommand(d["ssid"] | "", d["pass"] | "");
  if (op == "ota") {
    String url = d["url"] | "";
    if (!url.startsWith("http://") && !url.startsWith("https://")) return errJson("url must start with http(s)://");
    if (url.length() >= sizeof(otaUrl)) return errJson("url too long");
    copyStr(otaUrl, sizeof(otaUrl), url.c_str());
    otaRequested = true;
    return okJson("\"updating\":true");
  }
  if (op == "restart") { restartPending = true; restartAt = millis() + 1000; return okJson(); }
  return errJson("unknown op");
}

// ---- called from OTHER tasks
// Waits until loop() ran the command and returns its JSON answer.
String submitAndWait(const String& json, const char* src, uint32_t timeoutMs = 4000) {
  if (!cmdQueue) return errJson("not ready");
  CmdJob* job = new CmdJob{json, src, "", SINK_WAIT, xSemaphoreCreateBinary()};
  if (xQueueSend(cmdQueue, &job, pdMS_TO_TICKS(500)) != pdTRUE) {
    vSemaphoreDelete(job->done);
    delete job;
    return errJson("busy");
  }
  // loop() always answers quickly; the long timeout is only a safety net.
  if (xSemaphoreTake(job->done, pdMS_TO_TICKS(timeoutMs * 10)) != pdTRUE) return errJson("timeout");
  String out = job->out;
  vSemaphoreDelete(job->done);
  delete job;
  return out;
}

// Fire and forget; the answer goes to the given sink (e.g. BLE notify).
bool submitAsync(const String& json, const char* src, CmdSink sink) {
  if (!cmdQueue) return false;
  CmdJob* job = new CmdJob{json, src, "", sink, nullptr};
  if (xQueueSend(cmdQueue, &job, 0) != pdTRUE) { delete job; return false; }
  return true;
}

void bleSendResponse(const String& s);   // ble_link.h

// loop(): run everything that is waiting.
void processCommands() {
  CmdJob* job;
  while (cmdQueue && xQueueReceive(cmdQueue, &job, 0) == pdTRUE) {
    job->out = runCommand(job->in, job->src);
    if (job->sink == SINK_WAIT) { xSemaphoreGive(job->done); continue; }
    if (job->sink == SINK_BLE) bleSendResponse(job->out);
    delete job;
  }
}
