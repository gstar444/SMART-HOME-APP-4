/*
  ota_update.h  -  firmware updates without USB.
  ----------------------------------------------
  1) ArduinoOTA  : Arduino IDE -> Tools -> Port -> "esp32-home at <ip>" (network port).
                   Password = OTA password from the app (falls back to the API key).
                   Disabled while neither is set (nobody can flash your board).
  2) Browser/App : http://<ip>/update?key=<api key>  -> choose the .bin -> Upload
                   (the app's "Firmware update" screen does the same).
  3) URL pull    : {"op":"ota","url":"https://example.com/firmware.bin"} from the
                   app / MQTT / cloud -> the board downloads and installs it.
  Board setting: Tools -> Partition Scheme -> "Minimal SPIFFS (1.9MB APP with OTA)".
*/
#pragma once
#if ENABLE_OTA
#include <ArduinoOTA.h>
#include <Update.h>
#include <HTTPUpdate.h>
#include <NetworkClientSecure.h>

bool otaStarted = false;
String otaError;

const char* otaPassword() {
  if (cfg.otaPass.length()) return cfg.otaPass.c_str();
  const char* k = effectiveApiKey();
  return k[0] ? k : nullptr;
}

void otaSetup() {
  if (otaStarted) return;
  const char* pw = otaPassword();
  if (!pw) { Serial.println("ArduinoOTA disabled: set an OTA password or API key in the app"); return; }
  ArduinoOTA.setHostname("esp32-home");
  ArduinoOTA.setPassword(pw);
  ArduinoOTA.setMdnsEnabled(false);                 // mDNS is managed by startMdns()
  ArduinoOTA.onStart([] { allSwitchesOff(); Serial.println("OTA start - relays off"); });
  ArduinoOTA.onError([](ota_error_t e) { Serial.printf("OTA error %u\n", e); });
  ArduinoOTA.begin();
  otaStarted = true;
}

void otaLoop() {
  if (!otaStarted && (staUp() || apActive)) otaSetup();
  if (otaStarted) ArduinoOTA.handle();
}

// Network task: download + flash from a URL.
void otaPullTick() {
  if (!otaRequested) return;
  otaRequested = false;
  String url = otaUrl;
  Serial.printf("HTTP OTA from %s\n", url.c_str());
  httpUpdate.rebootOnUpdate(true);
  t_httpUpdate_return r;
  if (url.startsWith("https://")) {
    NetworkClientSecure tls;
    tls.useBuiltinCACertBundle();
    r = httpUpdate.update(tls, url);
  } else {
    WiFiClient plain;
    r = httpUpdate.update(plain, url);
  }
  if (r == HTTP_UPDATE_FAILED) otaError = httpUpdate.getLastErrorString();
  else if (r == HTTP_UPDATE_NO_UPDATES) otaError = "no update";
  Serial.println("OTA result: " + otaError);
}

// ---- HTTP upload (/api/ota/upload, multipart "firmware" field)
bool otaUploadAuthorized = false;

void handleOtaUploadData() {
  HTTPUpload& up = server.upload();
  if (up.status == UPLOAD_FILE_START) {
    otaUploadAuthorized = authorized();
    otaError = "";
    if (!otaUploadAuthorized) return;
    Serial.printf("OTA upload: %s\n", up.filename.c_str());
    allSwitchesOff();
    if (!Update.begin(UPDATE_SIZE_UNKNOWN)) otaError = Update.errorString();
  } else if (up.status == UPLOAD_FILE_WRITE) {
    if (otaUploadAuthorized && otaError.length() == 0 && Update.write(up.buf, up.currentSize) != up.currentSize)
      otaError = Update.errorString();
  } else if (up.status == UPLOAD_FILE_END) {
    if (otaUploadAuthorized && otaError.length() == 0 && !Update.end(true)) otaError = Update.errorString();
  } else if (up.status == UPLOAD_FILE_ABORTED) {
    Update.abort();
    otaError = "aborted";
  }
}

void handleOtaUploadDone() {
  if (!otaUploadAuthorized) { sendError(401, "unauthorized"); return; }
  if (otaError.length()) { sendJson(500, errJson(otaError)); return; }
  sendJson(200, okJson("\"restart\":true"));
  restartPending = true;
  restartAt = millis() + 1500;
}

const char OTA_HTML[] PROGMEM = R"HTML(<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Firmware update</title>
<style>body{font-family:sans-serif;background:#0b1220;color:#e5e9f0;padding:20px}button{padding:12px 20px;border-radius:10px;border:0;background:#2f7bff;color:#fff}</style>
</head><body><h2>Firmware update</h2><p>Choose the .bin file exported by Arduino IDE (Sketch -> Export compiled binary).</p>
<form id="f" method="POST" enctype="multipart/form-data"><input type="file" name="firmware" accept=".bin"><br><br><button>Upload</button></form>
<p id="s"></p><script>const k=new URLSearchParams(location.search).get('key')||'';
document.getElementById('f').action='/api/ota/upload?key='+encodeURIComponent(k);</script></body></html>)HTML";

void handleOtaPage() { server.send_P(200, "text/html; charset=utf-8", OTA_HTML); }
#endif
