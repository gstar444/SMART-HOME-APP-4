/*
  net_task.h  -  everything that may block on the internet runs here, on core 0:
  MQTT, Sinric Pro, Telegram, Cloud AI, cloud sync, HTTP OTA, internet check.
  The relays / HTTP server / BLE answers keep running on core 1 without lag.
*/
#pragma once

uint32_t netLastCheck = 0, netLastChange = 0, netLastStatePub = 0;
bool     ntpStarted = false;

static bool internetCheck() {
  WiFiClient c;
  bool ok = c.connect(IPAddress(1, 1, 1, 1), 53, 2500) || c.connect(IPAddress(8, 8, 8, 8), 53, 2500);
  c.stop();
  return ok;
}

void netTask(void*) {
#if ENABLE_MQTT
  mqttSetup();
#endif
#if ENABLE_TELEGRAM
  telegramSetup();
#endif
  bool sinricStarted = false;
  static DevLite devs[MAX_DEVICES];
  for (;;) {
    uint32_t now = millis();
    if (!staUp()) {
      netInternet = false;
      mqttUp = false;
      vTaskDelay(pdMS_TO_TICKS(500));
      continue;
    }
    if (!ntpStarted) { configTzTime(cfg.tz.c_str(), "pool.ntp.org", "time.google.com"); ntpStarted = true; }
#if ENABLE_SINRIC
    if (!sinricStarted) { sinricSetup(); sinricStarted = true; }
    sinricLoop();
#endif
#if ENABLE_MQTT
    mqttLoop(now);
#endif
    // ---- internet / broker health (drives the emergency hotspot)
    if (now - netLastCheck > 15000) {
      netLastCheck = now;
      netInternet = mqttUp || internetCheck();
    }
    bool healthy = netInternet && (!mqttConfigured() || mqttUp);
    if (healthy) lastOnlineMs = now;

    uint32_t change;
    String snap = getSnapshot(&change);
    if (change != netLastChange || now - netLastStatePub > 30000) {
      bool full = change != netLastChange;
      int n = parseDevices(snap, devs, MAX_DEVICES);
#if ENABLE_MQTT
      mqttPublishState(snap, devs, n, true);
#endif
#if ENABLE_SINRIC
      if (full) sinricReport(devs, n);
#endif
      netLastChange = change;
      netLastStatePub = now;
    }
#if ENABLE_MQTT
    mqttPublishMeter(now, snap);
#endif
#if ENABLE_TELEGRAM
    telegramTick(now);
#endif
#if ENABLE_CLOUD
    cloudTick(now, snap, change);
#endif
#if ENABLE_OTA
    otaPullTick();
#endif
    vTaskDelay(pdMS_TO_TICKS(20));
  }
}

void netTaskStart() {
  xTaskCreatePinnedToCore(netTask, "net", NET_TASK_STACK, nullptr, 1, nullptr, 0);
}
