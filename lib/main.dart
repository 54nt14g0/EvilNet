import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'screens/auth_screen.dart';
import 'screens/menu_screen.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService().init();
  if (Platform.isWindows) {
    await _setupFirewall();
  }

  runApp(const App());
}

Future<void> _setupFirewall() async {
  final rules = {
  'EvilNet Auth': '9001',
  'EvilNet PeerService': '45000',
  'EvilNet StudyRoom': '45001',
  'EvilNet Material': '45002',
  'EvilNet Chat': '45003',
  'EvilNet Universe': '45004',
  'EvilNet Nooks': '45005',
  'EvilNet Tasks': '45006',  // ← AGREGAR ESTA LÍNEA
};

  final scriptLines = StringBuffer();

  for (final entry in rules.entries) {
    scriptLines.writeln('''
\$exists = Get-NetFirewallRule -DisplayName '${entry.key}' -ErrorAction SilentlyContinue
if (-not \$exists) {
  New-NetFirewallRule `
    -DisplayName '${entry.key}' `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort ${entry.value} `
    -Profile Any `
    -InterfaceType Any | Out-Null
  Write-Host '✅ Creada regla: ${entry.key} puerto ${entry.value}'
} else {
  Write-Host '⏭️ Ya existe: ${entry.key}'
}
''');
  }

  // Al final del script, marcar que terminó
  scriptLines.writeln('Write-Host "FIREWALL_DONE"');

  try {
    final tempDir = Directory.systemTemp;
    final scriptFile = File('${tempDir.path}\\evilnet_fw.ps1');
    await scriptFile.writeAsString(scriptLines.toString());

    // Verificar si ya tenemos permisos (primera vez vs subsecuentes arranques)
    final checkResult = await Process.run('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      'Get-NetFirewallRule -DisplayName "EvilNet Auth" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Enabled',
    ], runInShell: true);

    final alreadyConfigured = checkResult.stdout.toString().trim().isNotEmpty;

    if (alreadyConfigured) {
      print('[Firewall] ✅ Reglas ya existen, saltando configuración');
      if (await scriptFile.exists()) await scriptFile.delete();
      return;
    }

    // Primera vez: necesitamos elevar permisos
    print('[Firewall] 🔧 Configurando reglas por primera vez...');

    final result = await Process.run('powershell', [
      '-ExecutionPolicy', 'Bypass',
      '-Command',
      // -Wait asegura que esperamos a que el proceso elevado termine
      'Start-Process powershell -Verb RunAs -Wait '
          '-ArgumentList \'-ExecutionPolicy Bypass -NonInteractive -File "${scriptFile.path}"\'',
    ], runInShell: true);

    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();

    if (stdout.isNotEmpty) print('[Firewall] stdout: $stdout');
    if (stderr.isNotEmpty) print('[Firewall] stderr: $stderr');

    if (await scriptFile.exists()) await scriptFile.delete();

    print('[Firewall] ✅ Configuración completada');
  } catch (e) {
    print('[Firewall] ❌ Error: $e');
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
      supportedLocales: const [Locale('en'), Locale('es')],
      home: const AuthScreen(),
      routes: {'/menu': (context) => const MenuScreen()},
    );
  }
}
