/*
  config.h  -  compile-time switches and defaults for the v4 "pro" features.
  ---------------------------------------------------------------------------
  Everything secret (MQTT password, Telegram token, cloud keys, AI key ...) is
  entered at RUNTIME from the app (Settings -> Advanced / Pro features) over
  Wi-Fi or BLE and stored in the ESP32 flash (Preferences). Nothing secret has
  to be written into this file, so the sketch can be published on GitHub.

  Turn a feature OFF (0) if you do not need it - it saves flash/RAM and you do
  not need to install its library.
*/
#pragma once

// --------------------------------------------------------------- features
#define ENABLE_MQTT      1   // secure MQTT (TLS + user/pass)    lib: PubSubClient
#define ENABLE_TELEGRAM  1   // Telegram bot + chat-id whitelist lib: UniversalTelegramBot, ArduinoJson
#define ENABLE_AI        1   // Cloud LLM for natural language   (needs ENABLE_TELEGRAM)
#define ENABLE_SINRIC    1   // Alexa + Google Home (Sinric Pro) lib: SinricPro (+WebSockets, ArduinoJson)
#define ENABLE_CLOUD     1   // Firebase RTDB / Supabase sync    (built-in HTTPClient)
#define ENABLE_OTA       1   // ArduinoOTA + HTTP upload + URL pull (built-in)
#define ENABLE_BLE       1   // BLE provisioning + local control lib: NimBLE-Arduino 2.x
#define ENABLE_METER     1   // PZEM-004T v3 / ACS712 energy meter (no extra lib)

// --------------------------------------------------------------- BLE security
// 6-digit PIN the phone asks for the first time it pairs with the board.
// All BLE characteristics that carry commands/secrets need an ENCRYPTED +
// AUTHENTICATED (MITM protected, LE Secure Connections) link.
// !! Change this before you flash the board.
#define BLE_PASSKEY      123456

// --------------------------------------------------------------- defaults
// (all of these can be changed later from the app at runtime)
#define DEF_MQTT_PORT        8883            // 8883 = TLS, 1883 = plain (not recommended)
#define DEF_MQTT_BASE        "smarthome"     // topics: smarthome/<node>/...
#define DEF_AI_URL           "https://api.openai.com/v1/chat/completions"
#define DEF_AI_MODEL         "gpt-4o-mini"
#define DEF_TZ               "IST-5:30"      // POSIX TZ string, used by time-based rules
#define DEF_CLOUD_INTERVAL   15              // seconds between cloud syncs
#define DEF_OFFLINE_TIMEOUT  60              // seconds without internet/MQTT -> emergency hotspot

// Energy meter defaults. Pins 25/26 are free in the default device table.
#define DEF_PZEM_RX          25              // ESP32 RX  <- PZEM TX
#define DEF_PZEM_TX          26              // ESP32 TX  -> PZEM RX
#define DEF_ACS_PIN          34              // ADC1 pin (input only) for ACS712 OUT (via divider!)
#define DEF_ACS_MV_PER_A     100             // 185 = 5A, 100 = 20A, 66 = 30A module
#define DEF_MAINS_V          230             // used by ACS712 (it measures current only)

#define MAX_METERS           4               // one meter per room (PZEM addresses 1..4)
#define MAX_RULES            16
#define MAX_RULE_ACTIONS     4

// Network task (TLS, Telegram, cloud) runs on core 0, the relays/HTTP on core 1.
#define NET_TASK_STACK       16384
