import 'package:flutter/material.dart';

import 'dashboard_page.dart';
import 'esp32_api.dart';
import 'settings.dart';

export 'settings.dart' show esp32Url, defaultEsp32Url;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Settings are read once before the first frame, so the page URL is known
  // immediately and the app does not need a second "loading" screen.
  final controller = await SettingsController.load();
  final esp = Esp32Controller(controller);
  runApp(SmartHomeApp(controller: controller, esp: esp));
}

ThemeData buildTheme(Color accent, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness);
  final background = dark ? const Color(0xFF0C1117) : const Color(0xFFF5F8FC);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

class SmartHomeApp extends StatelessWidget {
  const SmartHomeApp({super.key, required this.controller, required this.esp});

  final SettingsController controller;
  final Esp32Controller esp;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final s = controller.value;
        final accent = Color(s.accent);
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: s.title,
          themeMode: s.themeMode,
          theme: buildTheme(accent, Brightness.light),
          darkTheme: buildTheme(accent, Brightness.dark),
          // The dashboard lives *below* MaterialApp, so dialogs, snack bars and
          // navigation get a valid Navigator / ScaffoldMessenger context.
          home: DashboardPage(settings: controller, esp: esp),
        );
      },
    );
  }
}
