/*
  snapshot.h  -  thread-safe copy of the state JSON for the network task.
  loop() rebuilds it when something changed (or every 3 s for sensor/meter
  values); the network task only ever reads this copy, never the live arrays.
*/
#pragma once

SemaphoreHandle_t snapMutex = nullptr;
String   snapJson;
uint32_t snapChange = 0, lastSnapBuild = 0, lastFingerprint = 0;

static uint32_t stateFingerprint() {
  uint32_t h = 2166136261u;
  auto mix = [&](uint32_t v) { h = (h ^ v) * 16777619u; };
  mix(nDevices); mix(dnd);
  for (size_t i = 0; i < nDevices; i++) {
    const Device& d = devices[i];
    for (const char* p = d.id; *p; p++) mix(*p);
    for (const char* p = d.name; *p; p++) mix(*p);
    mix(d.on); mix(d.room);
  }
  return h;
}

// loop()
void snapshotTick(uint32_t now) {
  uint32_t fp = stateFingerprint();
  bool changed = fp != lastFingerprint;
  if (changed) { lastFingerprint = fp; changeVersion++; }
  if (!changed && now - lastSnapBuild < 3000) return;
  lastSnapBuild = now;
  String j = stateJson();
  xSemaphoreTake(snapMutex, portMAX_DELAY);
  snapJson = j;
  snapChange = changeVersion;
  xSemaphoreGive(snapMutex);
}

// any task
String getSnapshot(uint32_t* change = nullptr) {
  if (!snapMutex) return "{}";
  xSemaphoreTake(snapMutex, portMAX_DELAY);
  String j = snapJson;
  if (change) *change = snapChange;
  xSemaphoreGive(snapMutex);
  return j;
}

// Small device record parsed from the snapshot (network task side).
struct DevLite { char id[12]; char name[48]; char icon[12]; char type[8]; int room; bool on; };

int parseDevices(const String& snap, DevLite* out, int max) {
  JsonDocument f;
  f["devices"][0]["id"] = true; f["devices"][0]["name"] = true; f["devices"][0]["icon"] = true;
  f["devices"][0]["type"] = true; f["devices"][0]["room"] = true; f["devices"][0]["on"] = true;
  JsonDocument d;
  if (deserializeJson(d, snap, DeserializationOption::Filter(f))) return 0;
  int n = 0;
  for (JsonObject o : d["devices"].as<JsonArray>()) {
    if (n >= max) break;
    DevLite& x = out[n++];
    copyStr(x.id, sizeof(x.id), o["id"] | "");
    copyStr(x.name, sizeof(x.name), o["name"] | "");
    copyStr(x.icon, sizeof(x.icon), o["icon"] | "");
    copyStr(x.type, sizeof(x.type), o["type"] | "");
    x.room = o["room"] | 0;
    x.on = o["on"] | false;
  }
  return n;
}
