/*
  http_api.h  -  extra REST endpoints for the v4 features (same X-API-Key auth).
    GET  /api/info                 board name, node id, features (no auth, no secrets)
    GET  /api/config               runtime config, secrets masked
    POST /api/config   body JSON   partial config (missing key = keep, "" = clear)
    GET  /api/rules                rules array
    POST /api/rules    body JSON   replace rules array
    GET  /api/energy               meter readings
    POST /api/meter/reset          reset kWh counters
    POST /api/cmd      body JSON   any command from commands.h
    POST /api/ota/url  body {"url":..}  download + install firmware
    POST /api/ota/upload  multipart     upload firmware .bin
    GET  /update                   browser upload page
    POST /api/restart
*/
#pragma once

static String body() { return server.hasArg("plain") ? server.arg("plain") : String(""); }

static void sendCmd(const String& json) {
  String r = runCommand(json, "http");
  sendJson(r.indexOf("\"ok\":false") >= 0 ? 400 : 200, r);
}

void handleInfo() { sendJson(200, infoJson()); }
void handleConfig() {
  REQUIRE_AUTH();
  if (server.method() == HTTP_GET) { sendJson(200, configGetJson()); return; }
  sendCmd("{\"op\":\"config_set\",\"cfg\":" + body() + "}");
}
void handleRules() {
  REQUIRE_AUTH();
  if (server.method() == HTTP_GET) { sendJson(200, String("{\"ok\":true,\"rules\":") + rulesJson + "}"); return; }
  sendCmd("{\"op\":\"rules_set\",\"rules\":" + body() + "}");
}
void handleEnergy() {
  REQUIRE_AUTH();
  String m = meterJson();
  sendJson(200, String("{\"ok\":true,\"estimateW\":") + String(estimatedPowerW(), 1) + (m.length() ? m : String(",\"meter\":null,\"meters\":[]")) + "}");
}
void handleMeterReset() { REQUIRE_AUTH(); sendCmd("{\"op\":\"meter_reset\"}"); }
void handleCmd() { REQUIRE_AUTH(); sendCmd(body()); }
void handleOtaUrl() {
  REQUIRE_AUTH();
  JsonDocument d;
  if (deserializeJson(d, body())) { sendError(400, "bad JSON"); return; }
  String cmd;
  d["op"] = "ota";
  serializeJson(d, cmd);
  sendCmd(cmd);
}
void handleRestart() { REQUIRE_AUTH(); sendCmd("{\"op\":\"restart\"}"); }

void registerProRoutes() {
  server.on("/api/info",        HTTP_GET, handleInfo);
  server.on("/api/config",      HTTP_ANY, handleConfig);
  server.on("/api/rules",       HTTP_ANY, handleRules);
  server.on("/api/energy",      HTTP_ANY, handleEnergy);
  server.on("/api/meter/reset", HTTP_ANY, handleMeterReset);
  server.on("/api/cmd",         HTTP_POST, handleCmd);
  server.on("/api/restart",     HTTP_ANY, handleRestart);
#if ENABLE_OTA
  server.on("/api/ota/url",     HTTP_POST, handleOtaUrl);
  server.on("/api/ota/upload",  HTTP_POST, handleOtaUploadDone, handleOtaUploadData);
  server.on("/update",          HTTP_GET, handleOtaPage);
#endif
}
