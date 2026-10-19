/*
  power_meter.h  -  real energy measurement.
  ------------------------------------------
  PZEM-004T v3.0 (recommended, measures V, A, W, kWh, Hz, PF)
     UART Modbus-RTU 9600 8N1 on Serial2. Several PZEMs can share one bus when
     each has its own address (set once with a PZEM tool) -> one meter per room.
     Wiring: PZEM 5V/GND, PZEM TX -> ESP32 RX (default GPIO 25),
             PZEM RX -> ESP32 TX (default GPIO 26). CT clamp around the LIVE wire.
  ACS712 (5A / 20A / 30A hall sensor, current only)
     OUT -> voltage divider (e.g. 10k/20k) -> ADC1 pin (default GPIO 34).
     Power = mains voltage (setting) x RMS current, kWh is integrated here and
     saved to flash every 10 minutes.

  !! MAINS SAFETY: these modules sit on 230 V. Use an insulated box and a fuse.
*/
#pragma once

struct Meter {
  int      room = 0;
  int      addr = 0xF8;      // PZEM address
  int      pin = -1;         // ACS712 ADC pin
  bool     ok = false;
  float    v = NAN, a = NAN, w = NAN, kwh = 0, hz = NAN, pf = NAN;
  float    kwhBase = 0;      // ACS712: energy saved in flash
  uint32_t lastOk = 0;
};

Meter    meters[MAX_METERS];
int      nMeters = 0;
int      meterKind = 0;      // 0 none, 1 pzem, 2 acs712
uint32_t lastMeterRead = 0, lastMeterSave = 0;
int      meterCursor = 0;
HardwareSerial& pzemSerial = Serial2;

static uint16_t modbusCrc(const uint8_t* b, size_t n) {
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < n; i++) {
    crc ^= b[i];
    for (int k = 0; k < 8; k++) crc = (crc & 1) ? (crc >> 1) ^ 0xA001 : crc >> 1;
  }
  return crc;
}

static void pzemSend(uint8_t* f, size_t n) {
  uint16_t c = modbusCrc(f, n - 2);
  f[n - 2] = c & 0xFF;
  f[n - 1] = c >> 8;
  while (pzemSerial.available()) pzemSerial.read();
  pzemSerial.write(f, n);
  pzemSerial.flush();
}

static size_t pzemRecv(uint8_t* buf, size_t want, uint32_t timeoutMs = 120) {
  size_t got = 0;
  uint32_t t0 = millis();
  while (got < want && millis() - t0 < timeoutMs) {
    if (pzemSerial.available()) buf[got++] = pzemSerial.read();
    else delay(1);
  }
  return got;
}

// Reads the 10 input registers of one PZEM-004T v3.
static bool pzemRead(Meter& m) {
  uint8_t req[8] = {(uint8_t)m.addr, 0x04, 0x00, 0x00, 0x00, 0x0A, 0, 0};
  pzemSend(req, 8);
  uint8_t r[25];
  if (pzemRecv(r, 25) != 25 || r[1] != 0x04 || r[2] != 20) return false;
  if (modbusCrc(r, 23) != (uint16_t)(r[23] | (r[24] << 8))) return false;
  auto reg = [&](int i) -> uint32_t { return ((uint32_t)r[3 + i * 2] << 8) | r[4 + i * 2]; };
  m.v   = reg(0) / 10.0f;
  m.a   = (reg(1) | (reg(2) << 16)) / 1000.0f;
  m.w   = (reg(3) | (reg(4) << 16)) / 10.0f;
  m.kwh = (reg(5) | (reg(6) << 16)) / 1000.0f;
  m.hz  = reg(7) / 10.0f;
  m.pf  = reg(8) / 100.0f;
  return true;
}

static bool pzemResetEnergy(const Meter& m) {
  uint8_t req[4] = {(uint8_t)m.addr, 0x42, 0, 0};
  pzemSend(req, 4);
  uint8_t r[4];
  return pzemRecv(r, 4, 300) == 4 && r[1] == 0x42;
}

// RMS current of an ACS712 over ~3 mains cycles (60 ms).
static bool acsRead(Meter& m, float dtSec) {
  if (m.pin < 0) return false;
  const int N = 300;
  static uint16_t mv[N];
  uint32_t sum = 0;
  uint32_t t0 = micros();
  for (int i = 0; i < N; i++) {
    mv[i] = analogReadMilliVolts(m.pin);
    sum += mv[i];
    while (micros() - t0 < (uint32_t)(i + 1) * 200) {}
  }
  float mean = sum / (float)N;            // zero-current offset (VCC/2 after divider)
  double sq = 0;
  for (int i = 0; i < N; i++) { float d = mv[i] - mean; sq += d * d; }
  float rmsMv = sqrt(sq / N) * cfg.acsDivider;          // back to sensor millivolts
  float amps = rmsMv / cfg.acsMvPerA;
  if (amps < 0.08f) amps = 0;             // noise floor
  m.a = amps;
  m.v = cfg.mainsV;
  m.w = amps * cfg.mainsV;
  m.pf = NAN;
  m.hz = NAN;
  m.kwh += m.w * dtSec / 3600000.0f;
  return true;
}

bool meterPinReserved(int pin) {
  if (meterKind == 1) return pin == cfg.pzemRx || pin == cfg.pzemTx;
  if (meterKind == 2) for (int i = 0; i < nMeters; i++) if (meters[i].pin == pin) return true;
  return false;
}

void saveAcsEnergy() {
  if (meterKind != 2) return;
  Preferences p;
  p.begin(CFG_NS, false);
  for (int i = 0; i < nMeters; i++) p.putFloat((String("kwh") + i).c_str(), meters[i].kwh);
  p.end();
}

void meterSetup() {
#if ENABLE_METER
  nMeters = 0;
  meterKind = cfg.meterType == "pzem" ? 1 : cfg.meterType == "acs712" ? 2 : 0;
  if (meterKind == 0) return;
  for (int i = 0; i < MAX_METERS; i++) {
    String key = csvItem(meterKind == 1 ? cfg.meterAddrs : cfg.meterPins, i);
    if (key.length() == 0) break;
    Meter& m = meters[nMeters];
    m = Meter();
    String rm = csvItem(cfg.meterRooms, i);
    m.room = rm.length() ? constrain(rm.toInt(), 0, 49) : i;
    if (meterKind == 1) m.addr = constrain(key.toInt(), 1, 0xF8);
    else {
      m.pin = key.toInt();
      if (m.pin < 32 || m.pin > 39) continue;     // ADC1 only (ADC2 is blocked by Wi-Fi)
      pinMode(m.pin, INPUT);
      analogSetPinAttenuation(m.pin, ADC_11db);
    }
    nMeters++;
  }
  if (meterKind == 1) pzemSerial.begin(9600, SERIAL_8N1, cfg.pzemRx, cfg.pzemTx);
  if (meterKind == 2) {
    Preferences p;
    p.begin(CFG_NS, true);
    for (int i = 0; i < nMeters; i++) meters[i].kwh = p.getFloat((String("kwh") + i).c_str(), 0);
    p.end();
  }
  lastMeterRead = millis();
  Serial.printf("Energy meter: %s, %d channel(s)\n", cfg.meterType.c_str(), nMeters);
#endif
}

// Called from loop(): one meter per call so the loop never blocks for long.
void meterTick(uint32_t now) {
  if (meterKind == 0 || nMeters == 0) return;
  uint32_t every = 2000 / nMeters;
  if (now - lastMeterRead < every) return;
  float dt = (now - lastMeterRead) / 1000.0f * nMeters;   // time since this meter's last read
  lastMeterRead = now;
  Meter& m = meters[meterCursor];
  bool ok = meterKind == 1 ? pzemRead(m) : acsRead(m, dt);
  if (ok) { m.ok = true; m.lastOk = now; }
  else if (now - m.lastOk > 10000) { m.ok = false; m.v = m.a = m.w = m.hz = m.pf = NAN; }
  meterCursor = (meterCursor + 1) % nMeters;
  if (meterKind == 2 && now - lastMeterSave > 600000UL) { lastMeterSave = now; saveAcsEnergy(); }
}

bool meterResetEnergy() {
  bool ok = true;
  for (int i = 0; i < nMeters; i++) {
    if (meterKind == 1) ok &= pzemResetEnergy(meters[i]);
    meters[i].kwh = 0;
  }
  saveAcsEnergy();
  return ok;
}

float meterTotalW() {
  float w = 0; bool any = false;
  for (int i = 0; i < nMeters; i++) if (meters[i].ok) { w += meters[i].w; any = true; }
  return any ? w : NAN;
}

float meterRoomW(int room) {
  float w = 0; bool any = false;
  for (int i = 0; i < nMeters; i++) if (meters[i].ok && meters[i].room == room) { w += meters[i].w; any = true; }
  return any ? w : NAN;
}

// ,"meter":{totals},"meters":[...]   (empty when no meter is configured)
String meterJson() {
  if (meterKind == 0 || nMeters == 0) return "";
  float v = NAN, a = 0, w = 0, kwh = 0;
  bool any = false;
  String list;
  for (int i = 0; i < nMeters; i++) {
    const Meter& m = meters[i];
    if (i) list += ',';
    list += "{\"room\":"; list += m.room;
    list += ",\"ok\":";   list += m.ok ? "true" : "false";
    list += ",\"v\":";    list += numOrNull(m.v, 1);
    list += ",\"a\":";    list += numOrNull(m.a, 3);
    list += ",\"w\":";    list += numOrNull(m.w, 1);
    list += ",\"kwh\":";  list += String(m.kwh, 3);
    list += ",\"hz\":";   list += numOrNull(m.hz, 1);
    list += ",\"pf\":";   list += numOrNull(m.pf, 2);
    list += "}";
    kwh += m.kwh;
    if (m.ok) { any = true; a += m.a; w += m.w; if (isnan(v)) v = m.v; }
  }
  String j = ",\"meter\":{\"type\":\"";
  j += cfg.meterType;
  j += "\",\"ok\":";  j += any ? "true" : "false";
  j += ",\"v\":";     j += numOrNull(v, 1);
  j += ",\"a\":";     j += any ? String(a, 3) : String("null");
  j += ",\"w\":";     j += any ? String(w, 1) : String("null");
  j += ",\"kwh\":";   j += String(kwh, 3);
  j += "},\"meters\":[";
  j += list;
  j += "]";
  return j;
}
