/*
  voice_sinric.h  -  Alexa + Google Home via Sinric Pro (free for 3 devices).
  ---------------------------------------------------------------------------
  1) Create an account on https://sinric.pro, add "Switch" devices.
  2) In the app: Settings -> Advanced -> Voice assistants: paste APP KEY,
     APP SECRET and the map "sinricDeviceId=localDeviceId" (one per relay).
  3) Link the "Sinric Pro" skill in the Alexa app / Google Home app.
  "Alexa, turn on the fan" -> Sinric cloud -> this board -> relay.
  Manual switching (app, Telegram, rules) is reported back to Alexa/Google.
  Locks are NOT exposed (no voice unlocking).
*/
#pragma once
#if ENABLE_SINRIC
#include <SinricPro.h>
#include <SinricProSwitch.h>

#define MAX_SINRIC 12
String sinricIds[MAX_SINRIC], sinricLocal[MAX_SINRIC];
bool   sinricLast[MAX_SINRIC];
int    nSinric = 0;

bool sinricConfigured() { return cfg.sinricKey.length() && cfg.sinricSecret.length() && cfg.sinricMap.length(); }

static bool onSinricPower(const String& deviceId, bool& state) {
  for (int i = 0; i < nSinric; i++) {
    if (sinricIds[i] != deviceId) continue;
    String r = submitAndWait("{\"op\":\"set\",\"id\":\"" + sinricLocal[i] + "\",\"on\":" + (state ? "true" : "false") + "}", "sinric");
    if (r.indexOf("\"ok\":true") < 0) return false;
    sinricLast[i] = state;
    return true;
  }
  return false;
}

void sinricSetup() {
  if (!sinricConfigured()) return;
  for (int i = 0; i < MAX_SINRIC; i++) {
    String pair = csvItem(cfg.sinricMap, i);
    if (!pair.length()) break;
    int eq = pair.indexOf('=');
    if (eq <= 0) continue;
    sinricIds[nSinric] = pair.substring(0, eq);
    sinricLocal[nSinric] = pair.substring(eq + 1);
    sinricIds[nSinric].trim(); sinricLocal[nSinric].trim();
    SinricProSwitch& sw = SinricPro[sinricIds[nSinric]];
    sw.onPowerState(onSinricPower);
    nSinric++;
  }
  SinricPro.onConnected([] { sinricUp = true; Serial.println("Sinric Pro connected"); });
  SinricPro.onDisconnected([] { sinricUp = false; });
  SinricPro.begin(cfg.sinricKey, cfg.sinricSecret);
}

void sinricLoop() { if (nSinric) SinricPro.handle(); }

// Tell Alexa/Google about changes made somewhere else.
void sinricReport(DevLite* devs, int n) {
  if (!nSinric || !sinricUp) return;
  for (int i = 0; i < nSinric; i++)
    for (int k = 0; k < n; k++)
      if (sinricLocal[i] == devs[k].id && devs[k].on != sinricLast[i]) {
        sinricLast[i] = devs[k].on;
        SinricProSwitch& sw = SinricPro[sinricIds[i]];
        sw.sendPowerStateEvent(devs[k].on);
      }
}
#endif
