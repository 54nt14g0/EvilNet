import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'screens/auth_screen.dart';
import 'screens/menu_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    await _setupFirewall();
  }

  runApp(const App());
}

Future<void> _setupFirewall() async {
  final rules = {
    'EvilNet PeerService': '45000',
    'EvilNet StudyRoom': '45001',
    'EvilNet Material': '45002',
  };

  // Construir un script de PowerShell que agregue todas las reglas
  final scriptLines = rules.entries.map((e) => '''
if (-not (Get-NetFirewallRule -DisplayName '${e.key}' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName '${e.key}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort ${e.value}
  Write-Host 'Added: ${e.key}'
} else {
  Write-Host 'Exists: ${e.key}'
}
''').join('\n');

  try {
    // Ejecutar PowerShell elevado
    final result = await Process.run(
      'powershell',
      [
        '-Command',
        'Start-Process powershell -Verb RunAs -Wait -ArgumentList \'-Command $scriptLines\'',
      ],
      runInShell: true,
    );
    print('[Firewall] Setup result: ${result.stdout}');
  } catch (e) {
    print('[Firewall] Could not setup firewall: $e');
  }
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EvilNet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF020A06),
        fontFamily: 'monospace',
      ),
      localizationsDelegates: const [
        quill.FlutterQuillLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'),
        Locale('es'),
      ],
      home: const AuthScreen(),
      routes: {
        '/menu': (context) => const MenuScreen(),
      },
    );
  }
}