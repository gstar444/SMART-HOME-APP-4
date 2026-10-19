# ESP32 Smart Home (Flutter + ESP32 firmware) - v4.0

Native Android dashboard jo ESP32 ko Wi-Fi (HTTP/JSON) se control karta hai.
Project me do hisse hain:

| Folder | Kya hai |
|---|---|
| `lib/`, `android/`, `assets/` | Flutter app (APK yahin se banta hai) |
| `esp32_firmware/esp32_smart_home/` | ESP32 ka Arduino sketch (API server) |


> **v4.0 – Pro features.** App ka purana UI bilkul waisa hi hai. Saare naye features
> **Settings → "Advanced / Pro features"** me hain. Neeche v4 ka poora setup hai; v3 ka
> purana guide uske baad hai (wo ab bhi valid hai).

## v4.0 me naya kya hai

| Feature | Kahan | Kaise |
|---|---|---|
| Fast startup | App | Android native splash (Android 12+ SplashScreen API + purana launch screen), saare v4 screens **deferred import** (lazy load) – startup par sirf settings padhi jati hain |
| Energy monitor | Firmware + App | PZEM-004T v3 (V, A, W, kWh, Hz, PF, ek bus par 4 meter = 4 room) ya ACS712. Dashboard ka energy card meter ho to asli value dikhata hai, warna purana estimate |
| Alexa + Google Home | Firmware | Sinric Pro (free 3 devices). Locks voice se unlock nahi hote |
| Offline / emergency mode | Firmware | Router gaya → hotspot `SmartHome-Setup`. Router hai par internet/MQTT broker 60 s se down → hotspot bhi ON (local control `http://192.168.4.1/`). BLE hamesha ON |
| OTA | Firmware + App | ArduinoOTA (password), browser upload `http://<ip>/update?key=<API key>`, ya URL se download (`Advanced → Firmware update`) |
| Cloud sync | Firmware + App | Firebase Realtime DB **ya** Supabase: state, energy (hourly), rules, room names, remote commands |
| Telegram | Firmware | `UniversalTelegramBot`, **chat-id whitelist** – baaki sab messages drop. `/myid` sirf tab jab list khali ho |
| Secure MQTT | Firmware + App | TLS (`WiFiClientSecure`/`NetworkClientSecure`) + username/password, certificate check built-in CA bundle se |
| AI / LLM | Firmware | Telegram ka free text → OpenAI-compatible API → JSON actions → local relay ya doosre board ka MQTT topic |
| Multi-room | App | 4 rooms default, room chips + ab tiles par **left/right swipe** se room badlo |
| BLE provisioning | Firmware + App | Encrypted + PIN (passkey) BLE link par Wi-Fi, MQTT, Telegram token, cloud keys bhejo – USB nahi chahiye |
| Device manager | App | mDNS (`_smarthome._tcp`) + BLE scan, ek tap me board add |
| Rules engine | Firmware + App | "temp > 30 → fan ON", "22:30 → goodnight", board par chalte hain (offline bhi), cloud se sync |

### v4 firmware flash karna

1. Arduino IDE 2.x → Boards Manager → **esp32 by Espressif 3.x** (3.3 par test-compiled).
2. Library Manager se install karo:
   `PubSubClient`, `UniversalTelegramBot`, `ArduinoJson` (7.x), `SinricPro` (+ `WebSockets`),
   `NimBLE-Arduino` (2.x), `DHT sensor library` + `Adafruit Unified Sensor`.
   Koi feature nahi chahiye? `config.h` me `ENABLE_... 0` karo – uski library bhi nahi chahiye.
3. **Tools → Partition Scheme → "Minimal SPIFFS (1.9MB APP with OTA)"** (zaroori – sketch ~1.6 MB hai).
4. `esp32_firmware/esp32_smart_home/config.h` me **`BLE_PASSKEY` badlo** (6 digit PIN).
5. Upload. Iske baad sab kuch app se set hota hai – koi password/token code me nahi likhna.

Command line (CI ke liye):
```
arduino-cli compile -b esp32:esp32:esp32:PartitionScheme=min_spiffs esp32_firmware/esp32_smart_home
```

Firmware files (sab `esp32_firmware/esp32_smart_home/` me):

| File | Kaam |
|---|---|
| `esp32_smart_home.ino` | purana v3 core (relays, devices, Wi-Fi, REST) + v4 hooks |
| `config.h` | feature on/off, BLE PIN, defaults |
| `runtime_config.h` | app se aane wali settings (flash me, secrets kabhi wapas nahi bheje jate) |
| `power_meter.h` | PZEM-004T (Modbus) / ACS712 |
| `rules_engine.h` | automations |
| `commands.h` | sab channels (HTTP/MQTT/BLE/Telegram/AI/Sinric/cloud) ki ek command language + queue |
| `snapshot.h` | network task ke liye thread-safe state copy |
| `mqtt_link.h`, `telegram_bot.h`, `ai_llm.h`, `voice_sinric.h`, `cloud_sync.h` | network features (core 0 task) |
| `ota_update.h`, `ble_link.h`, `http_api.h`, `net_task.h`, `features.h` | OTA, BLE, naye endpoints, glue |

Relays sirf `loop()` (core 1) me switch hote hain; internet wala sab kaam (TLS, Telegram, cloud, AI)
alag FreeRTOS task (core 0) me – isliye dashboard kabhi slow nahi hota.

### Naye API endpoints (same `X-API-Key`)

```
GET  /api/info                 naam, node id, firmware, features (bina key, bina secret)
GET  /api/config               runtime settings (secrets sirf "...Set": true/false)
POST /api/config   {json}      partial update (key nahi = purana value, "" = clear)
GET  /api/rules  | POST /api/rules [..]
GET  /api/energy | POST /api/meter/reset
POST /api/cmd      {"op":"set","id":"fan","on":true}   (commands.h me poori list)
POST /api/ota/url  {"url":"https://.../firmware.bin"}
POST /api/ota/upload (multipart "firmware")   GET /update (browser page)
POST /api/restart
```
`/api/state` me naye fields: `node`, `net{internet,mqtt,cloud,telegram,voice,ble,emergency}`,
`meter{v,a,w,kwh}`, `meters[]` (har room), `estimateW`, `rules`. Purani app inhe ignore karti hai.

### Energy meter wiring

**PZEM-004T v3 (recommended)** – 5V, GND, PZEM TX → GPIO **25**, PZEM RX → GPIO **26**
(app me badal sakte ho). CT clamp sirf LIVE taar par. 1 meter: address `248`.
Har room ka alag meter: har PZEM ko pehle alag address (1,2,3,4) do, phir app me
`addrs = 1,2,3,4`, `rooms = 0,1,2,3`.

**ACS712** – OUT ko divider (10k/20k) se ADC1 pin (32–39, default **34**) par. `mvPerA`:
5A=185, 20A=100, 30A=66. Ye sirf current naapta hai: W = mains V (setting) × A; kWh
board khud jodta hai aur har 10 min flash me save karta hai.

> ⚠️ 230 V: insulated box, fuse, aur shak ho to electrician.

### Secure MQTT

HiveMQ Cloud / EMQX Cloud (free) ya apna Mosquitto (Let's Encrypt cert) – port **8883**,
TLS ON. Board: `Advanced → Board settings → Secure MQTT`. Phone (bahar se control):
`Advanced → Remote access`. Private CA ho to PEM paste karo; "Skip certificate check"
sirf testing ke liye.

Topics (`<b>` = base, default `smarthome`; `<n>` = board ka node id):
```
<b>/<n>/status   online/offline (retained, last-will)     <b>/<n>/state  poora JSON (retained)
<b>/<n>/meter    energy har 10 s                           <b>/<n>/<dev>/state  ON/OFF
<b>/<n>/<dev>/set  ← ON | OFF | TOGGLE                     <b>/<n>/cmd ← command JSON → <b>/<n>/resp
```
Broker par ACL lagao: har board ka user sirf `<b>/#` use kare.

### Telegram + AI

1. @BotFather → `/newbot` → token. App: Board settings → Telegram bot token.
2. Bot ko `/myid` bhejo → chat id → "Allowed chat IDs" me daalo (comma se kai). Ab
   doosre kisi chat ka message **drop** hota hai (Serial par log).
3. Commands: `/status /devices /on <naam> /off <naam> /scene goodnight /alloff /energy`,
   ya seedha likho: *"room 2 ki light band karo"*, *"turn on the fan"*.
4. AI (optional): endpoint (OpenAI / Groq / OpenRouter / Ollama – OpenAI-compatible), model, key.
   Local parser na samjhe to AI decide karta hai; doosre boards ke devices MQTT topic se.
5. Lock ko Telegram/AI/Alexa se **unlock** karna default band hai ("Allow unlocking" switch).

### Alexa / Google Home (Sinric Pro)

sinric.pro par account → har relay ke liye "Switch" device → APP KEY, APP SECRET aur map
`sinricDeviceId=light,sinricDeviceId2=fan` app me daalo → Alexa / Google Home app me
"Sinric Pro" skill link karo → *"Alexa, fan chalu karo"*.

### Cloud database

**Firebase Realtime Database** – URL `https://<project>-default-rtdb.firebaseio.com`,
key = Database secret (Project settings → Service accounts → Database secrets) ya ID token.
Rules me `/smarthome` ko sirf authenticated access do. Paths:
`/smarthome/<node>/state | energy/<YYYYMMDDHH> | rules | rooms | commands/<id>`.

**Supabase** – URL `https://<ref>.supabase.co`, key = service role key (sirf board/aapke
phone me) ya RLS ke saath anon key. SQL editor me chalao:
```sql
create table smarthome_nodes (node_id text primary key, state jsonb, rules jsonb,
  rooms jsonb, updated_at timestamptz default now());
create table smarthome_commands (id bigserial primary key, node_id text not null,
  cmd jsonb not null, created_at timestamptz default now());
create table smarthome_energy (id bigserial primary key, node_id text not null,
  ts timestamptz default now(), kwh real, w real);
alter table smarthome_nodes enable row level security;
alter table smarthome_commands enable row level security;
alter table smarthome_energy enable row level security;
-- anon key use kar rahe ho to apni policy banao; service role key RLS bypass karti hai.
```
Board har 15 s (setting) state push karta hai, rules/rooms/commands pull karta hai.
App: Rules save → board + cloud; Remote access → "Save + test" room names bhi bhejta hai.

### BLE provisioning (naya board, bina USB)

Naya board flash karo → app: `Advanced → Find boards / BLE provisioning` → Bluetooth
board chuno → phone PIN maangega (`BLE_PASSKEY`) → Wi-Fi naam/password bhejo, neeche
MQTT/Telegram/cloud bhi bhar ke "Save to board". Link encrypted + MITM protected hai.

### Security checklist

- API key set karo (Board settings → API key, phir app Settings → API key me wahi).
- OTA password set karo – bina password ArduinoOTA band rehta hai.
- `BLE_PASSKEY` aur hotspot password (`AP_PASS`) badlo.
- MQTT hamesha TLS + user/password; Telegram whitelist khali mat chhodo.
- Secrets sirf ESP32 flash aur phone ke private storage me – GitHub par kuch nahi jata.
- Release APK abhi debug key se sign hota hai (GitHub Actions) – Play Store ke liye apni keystore lagao.

---

### v3.0 me naya kya hai

1. **Wi-Fi connection setting (app se)**: nayi Wi-Fi chunna + password dalna, ESP32 ko naye router se jodna,
   connection status aur IP dekhna, zaroorat par Wi-Fi reset karna. Wi-Fi ESP32 ki flash me save hoti hai.
2. **Jitne chahein utne bulb / fan / device**: dashboard par **Add Bulb**, **Add Fan**, **Add Device** buttons.
   Device ka naam, kamra, icon aur GPIO pin chunein; baad me icon/pin badal sakte hain ya device hata sakte hain.
   Ek hi kamre me kai bulb ho sakte hain. Device ki list ab firmware ke code me fixed nahi hai -
   wo ESP32 ki flash me **configuration ki tarah save** hoti hai aur restart ke baad bhi rehti hai.

> **Zaroori:** nayi features ke liye ESP32 par naya `esp32_smart_home.ino` (v3.0.0) ek baar flash karna hoga.
> Purane firmware (v2) ke saath app chalti hai, par Wi-Fi aur Add Device buttons "firmware purana hai" ka message denge.

> Is project ko banate waqt Flutter/Dart SDK aur asli ESP32 available nahi tha.
> Firmware ko PC par stub headers ke saath compile + API logic test kiya gaya hai,
> lekin `flutter analyze / test / build` aur asli board par test aapko chalana hoga.
> Koi error aaye to error text bhej do, theek kar denge.

---------------------------------------------------------------------------

## 1. ESP32 firmware flash karna

1. Arduino IDE -> Boards Manager -> **esp32 by Espressif** install karein.
2. Library Manager -> **DHT sensor library** (Adafruit) + **Adafruit Unified Sensor** install karein
   (DHT22 nahi hai to sketch me `#define HAS_DHT 0` kar dein).
3. `esp32_firmware/esp32_smart_home/esp32_smart_home.ino` kholein. "YOUR SETTINGS" me (sab optional):
   - `WIFI_SSID`, `WIFI_PASS` - pehli baar ke liye. **Khali (YOUR_WIFI_NAME) chhod dein to ESP32 seedha setup hotspot
     chalu karega aur Wi-Fi aap app se set karenge** (neeche section 1A).
   - `STATIC_IP` (default `192.168.1.37`, apne router ke hisaab se `GATEWAY` bhi) - sirf upar wali pehli Wi-Fi ke liye.
     App se chuni gayi Wi-Fi hamesha DHCP (router se IP) leti hai.
   - `AP_SSID` / `AP_PASS` - setup hotspot ka naam/password (default `SmartHome-Setup` / `12345678`).
   - `API_KEY` (optional password; app Settings me wahi daalna hoga)
4. Board: **ESP32 Dev Module** -> Upload. Serial Monitor (115200) me IP dikhega.
5. Browser me `http://192.168.1.37/` kholkar test page dekh sakte hain.

### Shuruaati (default) devices

Pehli baar chalne par ESP32 ye 8 devices banata hai (`DEFAULT_DEVICES[]`). Uske baad list app se badli jati hai
(add / edit / delete) aur flash me save rehti hai - sketch dobara flash karne par bhi list wahi rehti hai.

| Tile | GPIO | Note |
|---|---|---|
| Main Light | 23 | relay |
| Ceiling Fan | 22 | relay |
| Smart Curtains | 19 | relay (abhi simple on/off) |
| Heater | 21 | relay, 180 min safety auto-off |
| Air Purifier | 18 | relay |
| Alarm Siren | 17 | relay/buzzer, 5 min auto-off, DND me block |
| Smart Lock | 16 | relay (energised = unlocked) |
| PIR Sensor | 27 | input |
| DHT22 (temp/humidity) | 4 | |

Relay board "active LOW" hai to `RELAY_ACTIVE_LOW 1` (default) rakhein.

**Safety:** 220 V ke load (heater, fan, light) sirf sahi rating ke relay/SSR se, fuse aur insulated box me
chalayein. Heater ko hobby relay se na chalayein.

### API

```
GET  /api/state                         sab kuch (wifi, sensor, devices, khali GPIO pins)
POST /api/set?id=light&on=1             ek device on/off
POST /api/dnd?on=1                      Do-Not-Disturb
POST /api/scene?id=alloff|goodnight|dinner

POST /api/device/add?name=..&icon=light&pin=23&room=0[&watts=12]
POST /api/device/update?id=..[&name=..][&icon=..][&pin=..][&room=..][&watts=..]
POST /api/device/delete?id=..

GET  /api/wifi/status                   Wi-Fi ki sthiti (idle / trying / failed), IP, hotspot
GET  /api/wifi/scan[?rescan=1]          aas-paas ke networks (scan background me chalta hai)
POST /api/wifi/connect?ssid=..&pass=..  naya Wi-Fi (fail hone par purana apne-aap wapas)
POST /api/wifi/reset                    saved Wi-Fi mita do, setup (hotspot) mode me restart
```
`API_KEY` set ho to header `X-API-Key: <key>` zaroori hai.
Naya control jodna ho to app me **Add Device** dabayein - firmware me koi line add karne ki zaroorat nahi.

**Kaun se GPIO pin milte hain:** 5, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33
(DHT22 chalu ho to 4 reserved). PIR sensor ke liye input-only 34, 35, 36, 39 bhi.
Boot/flash wale pins (0, 2, 12, 15, 1, 3, 6-11) jaan-boojhkar nahi diye gaye. Ek pin do devices ko nahi mil sakta.
Zyada se zyada 24 devices.

### 1A. Wi-Fi app se set karna

1. App kholo -> upar ka **Wi-Fi icon** (ya Settings -> *Wi-Fi कनेक्शन सेटिंग*, ya dashboard ka Wi-Fi status card).
2. **Wi-Fi नेटवर्क खोजें** -> apna network chuno -> password daalo -> **कनेक्ट करें**.
3. ESP32 naye router se judta hai (30 sec tak). App nayi IP dikha deti hai aur ESP32 ka pata khud update kar leti hai.
   Agar app ESP32 tak nahi pahunch paayi (phone doosri Wi-Fi par hai), to phone ko bhi usi nayi Wi-Fi se jodein aur
   *नया IP डालें* se IP likh dein (router ki device list ya Arduino Serial Monitor me dikhta hai).
4. Galat password/naam ho to ESP32 **apne-aap purani Wi-Fi par wapas** aa jata hai - kuch bigadta nahi.
5. Hamesha wahi IP chahiye to router me ESP32 ke liye *DHCP reservation* kar dein.

**Setup hotspot:** ESP32 kisi Wi-Fi se na jud paye (ya Wi-Fi reset ho) to wo apna hotspot `SmartHome-Setup`
(password `12345678`) chalu karta hai. Phone ko usse jodein, app me Wi-Fi page par *ऐप को सेटअप पते (192.168.4.1) से जोड़ें*
dabayein, phir ghar ki Wi-Fi chunein. Na jude to phone ka mobile data band karke dekhein.

**Wi-Fi reset:** Wi-Fi page ke neeche *Wi-Fi रीसेट करें*. Saved Wi-Fi mit jati hai, ESP32 setup mode me restart hota hai.
Devices ki list nahi mitti.

---------------------------------------------------------------------------

## 2. Logo (`app_logo.png`)

| File | Kaam |
|---|---|
| `assets/images/app_logo.png` | app ke andar (loading screen, top bar) + launcher icon ka source |
| `assets/icon/app_logo_foreground.png` | adaptive icon ka foreground (source copy) |
| `android/app/src/main/res/mipmap-*/ic_launcher.png` | purane Android ke icons |
| `android/app/src/main/res/drawable-nodpi/ic_launcher_foreground.png` | adaptive icon foreground |
| `android/app/src/main/res/drawable-nodpi/ic_launcher_monochrome.png` | Android 13 themed icon |
| `android/app/src/main/res/drawable-nodpi/smart_home_logo.png` | splash screen |
| `android/app/src/main/res/values/smart_home_colors.xml` | icon/splash ka cream background |

`pubspec.yaml` me `assets: - assets/images/app_logo.png` declared hai, isliye
`Image.asset('assets/images/app_logo.png')` chalta hai.

Logo baad me badalna ho to sabse aasaan tareeqa `flutter_launcher_icons`:

```yaml
# pubspec.yaml
dev_dependencies:
  flutter_launcher_icons: ^0.14.4

flutter_launcher_icons:
  android: true
  ios: false
  image_path: "assets/images/app_logo.png"
  adaptive_icon_background: "#F3EADB"
  adaptive_icon_foreground: "assets/icon/app_logo_foreground.png"
```
```
dart run flutter_launcher_icons
```
(iOS/macOS/Windows ke icons abhi Flutter default hain - sirf Android target hai.)

---------------------------------------------------------------------------

## 3. APK banana (Windows)

```bat
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build apk --release --split-per-abi
```
APK: `build\app\outputs\flutter-apk\app-arm64-v8a-release.apk`
(ek hi bada APK chahiye to `--split-per-abi` hata dein -> `app-release.apk`).

Gradle cache wala `.aar` error aaye: VS Code band karein, `android` folder me `gradlew --stop`, phir dobara build.

---------------------------------------------------------------------------

### PC par Flutter nahi hai? GitHub se APK banwayein

1. github.com par free account -> New repository (private rakh sakte hain).
2. Is project folder ke *andar ki* saari files/folders (jisme `pubspec.yaml` hai, `.github` folder samet) repo me upload karein.
3. Repo me **Actions** tab -> **Build APK** -> **Run workflow**.
4. 5-10 minute baad run khologe to neeche **Artifacts -> smart-home-apk** milega (zip me APK). Log me `flutter analyze`/`test` ke errors bhi dikhenge.

---------------------------------------------------------------------------

## 4. App kaise kaam karti hai

- **Dashboard**: clock, Wi-Fi/ESP32 status, voice button, day/night switch, Room tabs, energy card,
  Lighting / Climate / Security / Scenes tiles.
- Tile dabao = relay on/off (turant dikhta hai, fail ho to wapas ho jata hai).
- Tile **long-press** = menu: **badlo** (naam, icon, GPIO pin, kamra), **doosre kamre me bhejo**, **device hatao**.
- **Add Bulb / Add Fan / Add Device**: *Create Device* form khulta hai - naam, kamra, icon, GPIO pin (aur optional watts).
  Jo pin kisi aur device ke paas hai wo grey dikhta hai. Device turant ESP32 ki flash me save ho jata hai.
- Room tab long-press = rename / delete. **Add Room** = naya room (rooms sirf app me save hote hain).
- **Voice**: mic dabao, bolo "light on", "पंखा बंद करो", "sab band", "good night". ताला voice se sirf lock hota hai, unlock nahi.
- **Energy**: ESP32 relay-ON-time x `watts` se *anumaanit* kWh nikalta hai (asli meter nahi). ESP32 reboot par reset hota hai.
- **Security Cam**: firmware me `CAMERA_URL` (ESP32-CAM stream) set karein.
- Top bar ka globe icon = purana ESP32 web page (WebView) fallback.
- Wi-Fi icon (upar) / Settings -> Wi-Fi कनेक्शन सेटिंग: Wi-Fi chunna, status + IP, reset.
- Settings (tune icon): Wi-Fi, ESP32 IP/devices, API key, theme, accent colour, live-update interval, language.

## 5. Ghar ke bahar se use

Phone ko ghar ke LAN se private VPN (jaise Tailscale subnet routing) ke zariye jodein.
ESP32 ka HTTP port seedha internet par kabhi na kholein; local network par bhi `API_KEY` lagana behtar hai.
