/*
  cloud_sync.h  -  Firebase Realtime Database  or  Supabase  sync.
  ----------------------------------------------------------------
  The board PUSHES   state (devices, sensors, energy) + hourly energy log
  and PULLS          rules, room names and queued remote commands.

  Firebase RTDB  (url = https://<project>-default-rtdb.firebaseio.com,
                  key = database secret or ID token -> sent as ?auth=)
    /smarthome/<node>/state          <- board  (full state JSON)
    /smarthome/<node>/energy/<YYYYMMDDHH> <- board {kwh,w}
    /smarthome/<node>/rules          -> board  (array, written by the app)
    /smarthome/<node>/rooms          -> board  (array of names, written by the app)
    /smarthome/<node>/commands/<id>  -> board  (command JSON, deleted after run)

  Supabase       (url = https://<ref>.supabase.co, key = anon/service key)
    tables (SQL in README):  smarthome_nodes(node_id pk, state, rules, rooms, updated_at)
                             smarthome_commands(id, node_id, cmd)
                             smarthome_energy(node_id, ts, kwh, w)
  Everything goes over HTTPS with certificate checking (built-in CA bundle).
*/
#pragma once
#if ENABLE_CLOUD
#include <HTTPClient.h>
#include <NetworkClientSecure.h>

uint32_t cloudLastSync = 0, cloudLastChange = 0, cloudLastHour = 0xFFFFFFFF;
String   cloudRulesHash;

bool cloudConfigured() { return cfg.cloudProvider != "off" && cfg.cloudUrl.startsWith("https://") && cfg.cloudKey.length(); }
bool isFirebase() { return cfg.cloudProvider == "firebase"; }

// One HTTPS request. Returns the HTTP code (<=0 = network error).
int cloudRequest(const char* method, const String& path, const String& body, String* resp, const char* prefer = nullptr) {
  NetworkClientSecure tls;
  tls.useBuiltinCACertBundle();
  HTTPClient http;
  String url = cfg.cloudUrl + path;
  if (isFirebase()) url += (path.indexOf('?') >= 0 ? "&auth=" : "?auth=") + cfg.cloudKey;
  if (!http.begin(tls, url)) return -1;
  http.setTimeout(8000);
  http.addHeader("Content-Type", "application/json");
  if (!isFirebase()) {
    http.addHeader("apikey", cfg.cloudKey);
    http.addHeader("Authorization", "Bearer " + cfg.cloudKey);
    if (prefer) http.addHeader("Prefer", prefer);
  }
  int code = http.sendRequest(method, body);
  if (resp) *resp = code > 0 ? http.getString() : "";
  http.end();
  return code;
}

static void cloudApplyRules(const String& rules) {
  if (rules.length() == 0 || rules == "null") return;
  if (rules == cloudRulesHash) return;
  cloudRulesHash = rules;
  submitAndWait("{\"op\":\"rules_set\",\"rules\":" + rules + "}", "cloud");
}

static void cloudApplyRooms(JsonVariantConst arr) {
  if (!arr.is<JsonArrayConst>()) return;
  String s;
  for (JsonVariantConst v : arr.as<JsonArrayConst>()) { if (s.length()) s += ','; s += v.as<String>(); }
#if ENABLE_TELEGRAM
  roomNames = s;
#endif
}

static void firebaseSync(const String& snap, bool changed, uint32_t now) {
  String base = "/smarthome/" + cfg.node;
  int code = 200;
  if (changed || now - cloudLastSync >= (uint32_t)cfg.cloudInterval * 1000UL)
    code = cloudRequest("PUT", base + "/state.json", snap, nullptr);
  String r;
  if (cloudRequest("GET", base + "/rules.json", "", &r) == 200) cloudApplyRules(r);
  if (cloudRequest("GET", base + "/rooms.json", "", &r) == 200) {
    JsonDocument d;
    if (!deserializeJson(d, r)) cloudApplyRooms(d.as<JsonVariantConst>());
  }
  if (cloudRequest("GET", base + "/commands.json", "", &r) == 200 && r != "null") {
    JsonDocument d;
    if (!deserializeJson(d, r) && d.is<JsonObject>()) {
      for (JsonPair kv : d.as<JsonObject>()) {
        String c;
        serializeJson(kv.value(), c);
        submitAndWait(c, "cloud");
        cloudRequest("DELETE", base + "/commands/" + kv.key().c_str() + ".json", "", nullptr);
      }
    }
  }
  copyStr(cloudStatus, sizeof(cloudStatus), code == 200 ? "ok" : ("error " + String(code)).c_str());
}

static void supabaseSync(const String& snap, bool changed, uint32_t now) {
  int code = 200;
  if (changed || now - cloudLastSync >= (uint32_t)cfg.cloudInterval * 1000UL) {
    String body = "{\"node_id\":\"" + cfg.node + "\",\"state\":" + snap + ",\"updated_at\":\"now()\"}";
    code = cloudRequest("POST", "/rest/v1/smarthome_nodes?on_conflict=node_id", body, nullptr,
                        "resolution=merge-duplicates,return=minimal");
  }
  String r;
  if (cloudRequest("GET", "/rest/v1/smarthome_nodes?select=rules,rooms&node_id=eq." + cfg.node, "", &r) == 200) {
    JsonDocument d;
    if (!deserializeJson(d, r) && d[0].is<JsonObject>()) {
      if (!d[0]["rules"].isNull()) { String rules; serializeJson(d[0]["rules"], rules); cloudApplyRules(rules); }
      cloudApplyRooms(d[0]["rooms"]);
    }
  }
  if (cloudRequest("GET", "/rest/v1/smarthome_commands?select=id,cmd&order=id&node_id=eq." + cfg.node, "", &r) == 200) {
    JsonDocument d;
    if (!deserializeJson(d, r)) {
      long maxId = -1;
      for (JsonObject o : d.as<JsonArray>()) {
        String c;
        serializeJson(o["cmd"], c);
        submitAndWait(c, "cloud");
        maxId = max(maxId, o["id"].as<long>());
      }
      if (maxId >= 0)
        cloudRequest("DELETE", "/rest/v1/smarthome_commands?node_id=eq." + cfg.node + "&id=lte." + String(maxId), "", nullptr);
    }
  }
  copyStr(cloudStatus, sizeof(cloudStatus), (code >= 200 && code < 300) ? "ok" : ("error " + String(code)).c_str());
}

// Hourly energy log (needs NTP time).
static void cloudEnergyLog(const String& snap) {
  struct tm t;
  if (!getLocalTime(&t, 0)) return;
  uint32_t hourKey = (t.tm_year + 1900) * 1000000UL + (t.tm_mon + 1) * 10000UL + t.tm_mday * 100UL + t.tm_hour;
  if (hourKey == cloudLastHour) return;
  JsonDocument f; f["meter"] = true; f["powerW"] = true;
  JsonDocument d;
  if (deserializeJson(d, snap, DeserializationOption::Filter(f))) return;
  float w = d["meter"]["ok"] | false ? d["meter"]["w"].as<float>() : d["powerW"].as<float>();
  float kwh = d["meter"]["kwh"] | 0.0f;
  String body = "{\"kwh\":" + String(kwh, 3) + ",\"w\":" + String(w, 1);
  int code;
  if (isFirebase()) code = cloudRequest("PUT", "/smarthome/" + cfg.node + "/energy/" + String(hourKey) + ".json", body + "}", nullptr);
  else code = cloudRequest("POST", "/rest/v1/smarthome_energy", body + ",\"node_id\":\"" + cfg.node + "\"}", nullptr, "return=minimal");
  if (code >= 200 && code < 300) cloudLastHour = hourKey;
}

// Network task.
void cloudTick(uint32_t now, const String& snap, uint32_t change) {
  if (!cloudConfigured()) return;
  bool changed = change != cloudLastChange;
  bool due = now - cloudLastSync >= (uint32_t)cfg.cloudInterval * 1000UL;
  if (!changed && !due) return;
  if (changed && !due && now - cloudLastSync < 2000) return;      // max one push per 2 s
  cloudLastChange = change;
  if (isFirebase()) firebaseSync(snap, changed, now); else supabaseSync(snap, changed, now);
  cloudEnergyLog(snap);
  cloudLastSync = now;
}
#else
bool cloudConfigured() { return false; }
#endif
