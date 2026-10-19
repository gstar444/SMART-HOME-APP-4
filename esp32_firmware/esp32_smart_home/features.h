/*
  features.h  -  glue between the original v3 core (.ino) and the v4 modules.
*/
#pragma once
#include "runtime_config.h"
#include "power_meter.h"
#include "rules_engine.h"
#include "commands.h"
#include "snapshot.h"
#include "mqtt_link.h"
#include "ai_llm.h"
#include "telegram_bot.h"
#include "voice_sinric.h"
#include "cloud_sync.h"
#include "ota_update.h"
#include "ble_link.h"
#include "net_task.h"
#include "http_api.h"

// Extra fields appended to /api/state (older apps simply ignore them).
String extraStateJson() {
  String j = ",\"node\":\""; j += cfg.node;
  j += "\",\"net\":{\"internet\":"; j += jsonBool(netInternet);
  j += ",\"mqtt\":\"";   j += !mqttConfigured() ? "off" : (mqttUp ? "connected" : "offline");
  j += "\",\"cloud\":\""; j += cloudStatus;
  j += "\",\"telegram\":"; j += jsonBool(tgUp);
  j += ",\"voice\":";    j += jsonBool(sinricUp);
  j += ",\"ble\":";      j += jsonBool(bleClient);
  j += ",\"emergency\":"; j += jsonBool(emergencyMode);
  j += "},\"rules\":";   j += String(nRules);
  j += ",\"estimateW\":"; j += String(estimatedPowerW(), 1);
  j += meterJson();
  return j;
}

// Emergency / local mode: Wi-Fi is up but internet or the MQTT broker is gone
// for longer than the timeout -> open the local hotspot too (STA keeps retrying).
bool emergencyWanted(uint32_t now) {
  if (!cfg.fallbackAp || !staUp()) { emergencyMode = false; return false; }
  bool want = lastOnlineMs != 0 ? (now - lastOnlineMs > (uint32_t)cfg.offlineTimeout * 1000UL)
                                : (now > (uint32_t)cfg.offlineTimeout * 1000UL + 30000UL);
  emergencyMode = want;
  return want;
}

void featuresMdns() {
  MDNS.addService("smarthome", "tcp", 80);               // used by the app's auto-discovery
  MDNS.addServiceTxt("smarthome", "tcp", "node", cfg.node.c_str());
  MDNS.addServiceTxt("smarthome", "tcp", "fw", FW_VERSION);
#if ENABLE_OTA
  MDNS.enableArduino(3232, otaPassword() != nullptr);
#endif
}

void featuresSetup() {
  snapMutex = xSemaphoreCreateMutex();
  cmdQueue = xQueueCreate(16, sizeof(CmdJob*));
  loadRules(rulesJson);
  meterSetup();
  registerProRoutes();
#if ENABLE_BLE
  bleSetup();
#endif
  snapshotTick(millis());
  netTaskStart();
}

uint32_t lastInfoUpdate = 0;
void featuresLoop(uint32_t now) {
  processCommands();
  meterTick(now);
  rulesTick(now);
  snapshotTick(now);
#if ENABLE_OTA
  otaLoop();
#endif
  if (now - lastInfoUpdate > 10000) { lastInfoUpdate = now; bleUpdateInfo(); }
}
