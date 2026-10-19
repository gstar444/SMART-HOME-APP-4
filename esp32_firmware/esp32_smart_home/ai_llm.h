/*
  ai_llm.h  -  Cloud AI / LLM natural language -> relay commands.
  ----------------------------------------------------------------
  Any OpenAI-compatible "chat completions" endpoint works (OpenAI, Groq,
  OpenRouter, Together, a local Ollama/LM Studio server, ...). URL, model and
  API key are set in the app. The model gets the device list of THIS board and
  of the other boards seen on MQTT and must answer with JSON:
     {"actions":[{"node":"home-a1b2c3","id":"fan","on":true}],"reply":"Fan on"}
  Local devices are switched directly, devices of other boards through their
  MQTT topic <base>/<node>/<dev>/set.
*/
#pragma once
#if ENABLE_AI && ENABLE_TELEGRAM
#include <HTTPClient.h>
#include <NetworkClientSecure.h>

bool aiConfigured() { return cfg.aiKey.length() > 0 && cfg.aiUrl.length() > 0; }

String aiDeviceList(DevLite* devs, int n) {
  String s = "Board \"" + cfg.node + "\" (this board):\n";
  for (int i = 0; i < n; i++) {
    if (!strcmp(devs[i].type, "pir")) continue;
    s += "- id=" + String(devs[i].id) + " name=\"" + devs[i].name + "\" type=" + devs[i].type +
         " room=" + String(devs[i].room + 1) + " on=" + (devs[i].on ? "true" : "false") + "\n";
  }
#if ENABLE_MQTT
  for (int r = 0; r < nRemotes; r++) {
    s += "Board \"" + remotes[r].node + "\":\n";
    String d = remotes[r].devs;
    int p = 0;
    while (p < (int)d.length()) {
      int e = d.indexOf(';', p);
      if (e < 0) break;
      String it = d.substring(p, e);
      p = e + 1;
      int a = it.indexOf('|'), b = it.indexOf('|', a + 1), c = it.indexOf('|', b + 1);
      if (a < 0 || b < 0 || c < 0) continue;
      s += "- id=" + it.substring(0, a) + " name=\"" + it.substring(a + 1, b) + "\" room=" +
           String(it.substring(b + 1, c).toInt() + 1) + " on=" + (it.substring(c + 1) == "1" ? "true" : "false") + "\n";
    }
  }
#endif
  return s;
}

// Returns the text to send back to the user.
String aiHandle(const String& text, DevLite* devs, int n, const String& roomNames) {
  if (!aiConfigured()) return "";
  JsonDocument req;
  req["model"] = cfg.aiModel;
  req["temperature"] = 0;
  JsonArray msgs = req["messages"].to<JsonArray>();
  JsonObject sys = msgs.add<JsonObject>();
  sys["role"] = "system";
  sys["content"] =
      "You control a smart home. Understand English, Hindi and Hinglish. Rooms are numbered from 1"
      + (roomNames.length() ? String(" (names: ") + roomNames + ")" : String("")) +
      ". Answer ONLY with compact JSON: {\"actions\":[{\"node\":\"<board>\",\"id\":\"<device id>\",\"on\":true|false}],"
      "\"reply\":\"<short answer in the user's language>\"}. Use only ids from the list. "
      "Never unlock a lock. If nothing should change, return an empty actions list and answer the question.\n\n"
      + aiDeviceList(devs, n);
  JsonObject usr = msgs.add<JsonObject>();
  usr["role"] = "user";
  usr["content"] = text;
  String body;
  serializeJson(req, body);

  NetworkClientSecure tls;
  tls.useBuiltinCACertBundle();
  WiFiClient plain;
  HTTPClient http;
  bool https = cfg.aiUrl.startsWith("https://");
  if (!(https ? http.begin(tls, cfg.aiUrl) : http.begin(plain, cfg.aiUrl))) return "AI: bad URL";
  http.setTimeout(20000);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Authorization", "Bearer " + cfg.aiKey);
  int code = http.POST(body);
  String resp = code > 0 ? http.getString() : "";
  http.end();
  if (code != 200) return "AI error " + String(code);

  JsonDocument f;
  f["choices"][0]["message"]["content"] = true;
  JsonDocument r;
  if (deserializeJson(r, resp, DeserializationOption::Filter(f))) return "AI: bad answer";
  String content = r["choices"][0]["message"]["content"] | "";
  int a = content.indexOf('{'), b = content.lastIndexOf('}');
  if (a < 0 || b <= a) return content.length() ? content : "AI: empty answer";
  JsonDocument out;
  if (deserializeJson(out, content.substring(a, b + 1))) return "AI: bad JSON";
  int done = 0;
  for (JsonObject act : out["actions"].as<JsonArray>()) {
    String node = act["node"] | cfg.node.c_str();
    String id = act["id"] | "";
    bool on = act["on"] | false;
    if (!id.length()) continue;
    if (node == cfg.node || node.length() == 0) {
      String res = submitAndWait("{\"op\":\"set\",\"id\":\"" + id + "\",\"on\":" + (on ? "true" : "false") + "}", "ai");
      if (res.indexOf("\"ok\":true") >= 0) done++;
    } else if (mqttSetRemote(node, id, on)) done++;
  }
  String reply = out["reply"] | "";
  if (!reply.length()) reply = done ? "Done" : "OK";
  return reply;
}
#else
bool aiConfigured() { return false; }
#endif
