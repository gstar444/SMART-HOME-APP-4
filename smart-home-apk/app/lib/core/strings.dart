/// English / Hindi texts for the main screens (the app keeps the bilingual feature of v3).
/// Anything not listed here is shown in English.
class Tr {
  const Tr(this.hi);
  final bool hi;
  String _t(String en, String hindi) => hi ? hindi : en;

  String get appName => _t('Smart Home', 'स्मार्ट होम');
  String get save => _t('Save', 'सेव करें');
  String get cancel => _t('Cancel', 'रद्द करें');
  String get delete => _t('Delete', 'हटाएँ');
  String get edit => _t('Edit', 'बदलें');
  String get retry => _t('Retry', 'फिर कोशिश करें');
  String get copy => _t('Copy', 'कॉपी');

  String get online => _t('Online', 'ऑनलाइन');
  String get offline => _t('Offline', 'ऑफ़लाइन');
  String get connecting => _t('Connecting…', 'जुड़ रहा है…');
  String get viaCloud => _t('Cloud', 'क्लाउड');
  String get viaLan => _t('Home Wi-Fi', 'होम वाई-फ़ाई');
  String get noConnection => _t('No connection', 'कनेक्शन नहीं');
  String get emergencyMode => _t('Emergency hotspot', 'इमरजेंसी हॉटस्पॉट');
  String get lanOnlyMode => _t('Local only', 'सिर्फ़ लोकल');

  String get addDevice => _t('Add device', 'डिवाइस जोड़ें');
  String get addBoard => _t('Add a board', 'बोर्ड जोड़ें');
  String get noBoardInRoom => _t('No board in this room yet', 'इस कमरे में अभी कोई बोर्ड नहीं');
  String get noBoardHint => _t('Add an ESP32 and assign it to this room.', 'ESP32 जोड़ें और इस कमरे में लगाएँ।');
  String get noDevices => _t('No devices yet', 'अभी कोई डिवाइस नहीं');
  String get allOff => _t('All off', 'सब बंद');
  String get goodNight => _t('Good night', 'गुड नाइट');
  String get dinner => _t('Dinner', 'डिनर');
  String get voice => _t('Voice', 'आवाज़');
  String get speakNow => _t('Say a command', 'कमांड बोलें');
  String get didNotUnderstand => _t('Did not understand', 'समझ नहीं आया');
  String get lockBlocked => _t('For safety doors cannot be unlocked by voice.', 'सुरक्षा के लिए आवाज़ से दरवाज़ा नहीं खुलेगा।');

  String get power => _t('Power', 'पावर');
  String get voltage => _t('Voltage', 'वोल्टेज');
  String get current => _t('Current', 'करंट');
  String get today => _t('Today', 'आज');
  String get total => _t('Total', 'कुल');
  String get estimate => _t('estimated', 'अनुमानित');
  String get automations => _t('Automations', 'ऑटोमेशन');
  String get energy => _t('Energy', 'ऊर्जा');
  String get settings => _t('Settings', 'सेटिंग्स');
  String get findBoards => _t('Find boards', 'बोर्ड खोजें');
  String get rooms => _t('Rooms', 'कमरे');
  String get language => _t('Language', 'भाषा');
  String get darkMode => _t('Theme', 'थीम');
  String get security => _t('Security', 'सुरक्षा');
  String get pairingCode => _t('Pairing code', 'पेयरिंग कोड');
  String get chooseWifi => _t('Choose Wi-Fi', 'वाई-फ़ाई चुनें');
  String get wifiPassword => _t('Wi-Fi password', 'वाई-फ़ाई पासवर्ड');
  String get setUp => _t('Set up', 'सेट अप');
  String get done => _t('Done', 'हो गया');
}
