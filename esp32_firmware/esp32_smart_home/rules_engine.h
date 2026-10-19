/*
  rules_engine.h  -  condition based automations (synced with the cloud / app).
  -----------------------------------------------------------------------------
  Rule JSON (array stored in flash, edited in the app, synced via Firebase/Supabase):
    {"id":"r1","name":"Hot -> fan","on":true,
     "when":{"src":"temp","op":">","val":30},
     "do":[{"id":"fan","on":true}],
     "cool":300}
  src : temp | hum | power (meter W, or estimate) | dev:<id> (1/0) | motion:<id>
        | time (val "HH:MM", local time from NTP)
  op  : > < >= <= == !=
  do  : {"id":"<device>","on":true}  or {"scene":"alloff"}  or {"room":1,"on":false}
  A rule fires once when its condition BECOMES true (edge), then waits `cool`
  seconds before it may fire again. Rules run on the board, also offline.
*/
#pragma once

enum RuleSrc : uint8_t { RS_TEMP, RS_HUM, RS_POWER, RS_DEV, RS_MOTION, RS_TIME };
enum RuleOp  : uint8_t { RO_GT, RO_LT, RO_GE, RO_LE, RO_EQ, RO_NE };

struct RuleAction { char id[12]; char scene[12]; int8_t room; bool on; };
struct Rule {
  char       id[12];
  bool       enabled;
  RuleSrc    src;
  RuleOp     op;
  char       dev[12];
  float      val;
  int16_t    minuteOfDay;
  uint32_t   coolMs;
  RuleAction act[MAX_RULE_ACTIONS];
  uint8_t    nAct;
  bool       lastTrue;
  uint32_t   lastFire;
  int32_t    lastMinuteFired;
};

Rule     rules[MAX_RULES];
int      nRules = 0;
uint32_t lastRuleTick = 0;
uint32_t rulesFired = 0;

// forward (core firmware)
bool runSceneById(const String& id);
void setRoom(int room, bool on, const char* src);

static RuleOp parseOp(const char* s) {
  if (!strcmp(s, "<"))  return RO_LT;
  if (!strcmp(s, ">=")) return RO_GE;
  if (!strcmp(s, "<=")) return RO_LE;
  if (!strcmp(s, "==") || !strcmp(s, "=")) return RO_EQ;
  if (!strcmp(s, "!=")) return RO_NE;
  return RO_GT;
}

// Parses rulesJson into rules[]. Returns "" or an error.
String loadRules(const String& json) {
  JsonDocument d;
  if (deserializeJson(d, json) || !d.is<JsonArray>()) return "rules must be a JSON array";
  int n = 0;
  for (JsonObject r : d.as<JsonArray>()) {
    if (n >= MAX_RULES) break;
    Rule& x = rules[n];
    memset(&x, 0, sizeof(x));
    copyStr(x.id, sizeof(x.id), r["id"] | "");
    x.enabled = r["on"] | true;
    String src = r["when"]["src"] | "temp";
    x.op = parseOp(r["when"]["op"] | ">");
    x.minuteOfDay = -1;
    x.lastMinuteFired = -1;
    if (src == "temp") x.src = RS_TEMP;
    else if (src == "hum") x.src = RS_HUM;
    else if (src == "power") x.src = RS_POWER;
    else if (src.startsWith("dev:"))    { x.src = RS_DEV;    copyStr(x.dev, sizeof(x.dev), src.substring(4).c_str()); }
    else if (src.startsWith("motion:")) { x.src = RS_MOTION; copyStr(x.dev, sizeof(x.dev), src.substring(7).c_str()); }
    else if (src == "time") {
      x.src = RS_TIME;
      String t = r["when"]["val"] | "00:00";
      int c = t.indexOf(':');
      if (c < 0) continue;
      x.minuteOfDay = t.substring(0, c).toInt() * 60 + t.substring(c + 1).toInt();
    } else continue;
    JsonVariant v = r["when"]["val"];
    x.val = v.is<bool>() ? (v.as<bool>() ? 1 : 0) : v.as<float>();
    x.coolMs = (uint32_t)(r["cool"] | 60) * 1000UL;
    for (JsonObject a : r["do"].as<JsonArray>()) {
      if (x.nAct >= MAX_RULE_ACTIONS) break;
      RuleAction& ac = x.act[x.nAct++];
      copyStr(ac.id, sizeof(ac.id), a["id"] | "");
      copyStr(ac.scene, sizeof(ac.scene), a["scene"] | "");
      ac.room = a["room"].is<int>() ? (int8_t)a["room"].as<int>() : -1;
      ac.on = a["on"] | false;
    }
    n++;
  }
  nRules = n;
  return "";
}

static bool cmp(float a, RuleOp op, float b) {
  if (isnan(a)) return false;
  switch (op) {
    case RO_GT: return a > b;   case RO_LT: return a < b;
    case RO_GE: return a >= b;  case RO_LE: return a <= b;
    case RO_EQ: return fabsf(a - b) < 0.001f;
    default:    return fabsf(a - b) >= 0.001f;
  }
}

float estimatedPowerW();

static bool ruleCondition(Rule& r, int minuteNow) {
  switch (r.src) {
    case RS_TEMP:  return cmp(tempC, r.op, r.val);
    case RS_HUM:   return cmp(humidity, r.op, r.val);
    case RS_POWER: { float w = meterTotalW(); if (isnan(w)) w = estimatedPowerW(); return cmp(w, r.op, r.val); }
    case RS_DEV:
    case RS_MOTION: { Device* d = findDevice(r.dev); return d && cmp(d->on ? 1 : 0, r.op, r.val); }
    case RS_TIME:  return minuteNow >= 0 && minuteNow == r.minuteOfDay && r.lastMinuteFired != minuteNow;
  }
  return false;
}

static void ruleFire(Rule& r) {
  for (int i = 0; i < r.nAct; i++) {
    RuleAction& a = r.act[i];
    if (a.scene[0]) runSceneById(a.scene);
    else if (a.room >= 0) setRoom(a.room, a.on, "rule");
    else if (a.id[0]) {
      Device* d = findDevice(a.id);
      if (!d || !strcmp(d->type, "pir")) continue;
      if (dnd && a.on && !strcmp(d->icon, "siren")) continue;
      setDevice(*d, a.on);
    }
  }
  rulesFired++;
  Serial.printf("Rule %s fired\n", r.id);
}

void rulesTick(uint32_t now) {
  if (nRules == 0 || now - lastRuleTick < 1000) return;
  lastRuleTick = now;
  int minuteNow = -1;
  struct tm t;
  if (getLocalTime(&t, 0)) minuteNow = t.tm_hour * 60 + t.tm_min;
  for (int i = 0; i < nRules; i++) {
    Rule& r = rules[i];
    if (!r.enabled) continue;
    bool c = ruleCondition(r, minuteNow);
    bool rising = c && !r.lastTrue;
    r.lastTrue = r.src == RS_TIME ? false : c;
    if (!rising) continue;
    if (r.lastFire && now - r.lastFire < r.coolMs) continue;
    r.lastFire = now;
    if (r.src == RS_TIME) r.lastMinuteFired = minuteNow;
    ruleFire(r);
  }
}
