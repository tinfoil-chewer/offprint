import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Inter font'], await rootBundle.loadString('assets/fonts/Inter-LICENSE.txt'));
  });
  printerService.load();
  runApp(const OffprintApp());
}

ThemeData offprintTheme(Brightness brightness) => ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter', // bundled; the print renderer uses it too
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF808080),
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome, // black, greys and white
      ),
    );

class OffprintApp extends StatelessWidget {
  const OffprintApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offprint',
      debugShowCheckedModeBanner: false,
      theme: offprintTheme(Brightness.light),
      darkTheme: offprintTheme(Brightness.dark),
      home: const HomeScreen(),
    );
  }
}
