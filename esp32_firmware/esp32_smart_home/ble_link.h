/*
  ble_link.h  -  BLE provisioning + local control (NimBLE).
  ---------------------------------------------------------
  Service  6e3a0001-5f1c-4c1b-9d1e-8b5a3c2d1e00
    ...0002  INFO  read          {"name","node","fw","provisioned"}  (no secrets)
    ...0003  RX    write (ENCRYPTED + MITM)  command JSON lines, '\n' terminated,
                   may arrive in several chunks (same commands as commands.h,
                   e.g. {"op":"wifi",...} {"op":"config_set","cfg":{...}})
    ...0004  TX    notify (ENCRYPTED)  answers, chunked, '\n' terminated
  Security: LE Secure Connections + bonding + MITM with a static 6-digit
  passkey (BLE_PASSKEY in config.h). Android asks for the PIN on first use.
  Works without any router -> the app can always reach the board locally.
*/
#pragma once
#if ENABLE_BLE
#include <NimBLEDevice.h>

#define BLE_SVC  "6e3a0001-5f1c-4c1b-9d1e-8b5a3c2d1e00"
#define BLE_INFO "6e3a0002-5f1c-4c1b-9d1e-8b5a3c2d1e00"
#define BLE_RX   "6e3a0003-5f1c-4c1b-9d1e-8b5a3c2d1e00"
#define BLE_TX   "6e3a0004-5f1c-4c1b-9d1e-8b5a3c2d1e00"

NimBLECharacteristic* bleTx = nullptr;
NimBLECharacteristic* bleInfo = nullptr;
NimBLEServer* bleServer = nullptr;
String bleRxBuf;
uint16_t bleMtu = 23;

class BleServerCb : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& c) override { bleClient = true; bleRxBuf = ""; }
  void onDisconnect(NimBLEServer* s, NimBLEConnInfo& c, int reason) override {
    bleClient = s->getConnectedCount() > 0;
    NimBLEDevice::startAdvertising();
  }
  void onMTUChange(uint16_t mtu, NimBLEConnInfo& c) override { bleMtu = mtu; }
};

class BleRxCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* ch, NimBLEConnInfo& c) override {
    if (!c.isEncrypted() || !c.isAuthenticated()) return;   // belt and braces
    std::string v = ch->getValue();
    bleRxBuf += String(v.c_str(), v.length());
    if (bleRxBuf.length() > 8192) { bleRxBuf = ""; return; }
    int nl;
    while ((nl = bleRxBuf.indexOf('\n')) >= 0) {
      String line = bleRxBuf.substring(0, nl);
      bleRxBuf.remove(0, nl + 1);
      line.trim();
      if (line.length()) submitAsync(line, "ble", SINK_BLE);
    }
  }
};

// loop(): send an answer in MTU sized pieces.
void bleSendResponse(const String& s) {
  if (!bleTx || !bleClient) return;
  String msg = s + "\n";
  size_t chunk = bleMtu > 23 ? bleMtu - 3 : 20;
  for (size_t i = 0; i < msg.length(); i += chunk) {
    size_t n = min(chunk, msg.length() - i);
    bleTx->notify((const uint8_t*)msg.c_str() + i, n);
    delay(4);
  }
}

void bleUpdateInfo() {
  if (!bleInfo) return;
  String j = "{\"name\":\"" + esc(DEVICE_NAME) + "\",\"node\":\"" + cfg.node + "\",\"fw\":\"" FW_VERSION "\",\"ip\":\"" +
             ipString() + "\",\"provisioned\":" + jsonBool(savedSsid.length() > 0 || hasBuiltInWifi()) + "}";
  bleInfo->setValue(j.c_str());
}

void bleSetup() {
  String name = "SmartHome-" + cfg.node.substring(cfg.node.length() > 6 ? cfg.node.length() - 6 : 0);
  NimBLEDevice::init(name.c_str());
  NimBLEDevice::setMTU(247);
  NimBLEDevice::setSecurityAuth(true, true, true);          // bonding, MITM, secure connections
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);   // phone enters our static PIN
  NimBLEDevice::setSecurityPasskey(BLE_PASSKEY);
  bleServer = NimBLEDevice::createServer();
  bleServer->setCallbacks(new BleServerCb());
  NimBLEService* svc = bleServer->createService(BLE_SVC);
  bleInfo = svc->createCharacteristic(BLE_INFO, NIMBLE_PROPERTY::READ);
  NimBLECharacteristic* rx = svc->createCharacteristic(
      BLE_RX, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC | NIMBLE_PROPERTY::WRITE_AUTHEN);
  rx->setCallbacks(new BleRxCb());
  bleTx = svc->createCharacteristic(BLE_TX, NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ |
                                                NIMBLE_PROPERTY::READ_ENC | NIMBLE_PROPERTY::READ_AUTHEN);
  svc->start();
  bleUpdateInfo();
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->setName(name.c_str());
  adv->addServiceUUID(BLE_SVC);
  adv->enableScanResponse(true);
  adv->start();
  Serial.printf("BLE ready as \"%s\" (PIN %06d)\n", name.c_str(), BLE_PASSKEY);
}
#else
void bleSendResponse(const String&) {}
void bleUpdateInfo() {}
#endif
