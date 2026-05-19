import 'package:flutter/material.dart';
import 'screens/auth_screen.dart';        // 🔐 MERGE: Pantalla de login/register
import 'screens/menu_screen.dart';         // 🔐 MERGE: Menú principal (destino post-login)

void main() async {
  // 🔐 MERGE: Asegurar que Flutter esté inicializado antes de usar plugins
  WidgetsFlutterBinding.ensureInitialized();
  
  // 🔐 MERGE: Iniciar servicios en background antes de mostrar UI
  // Nota: PeerService y AuthService deben manejar su propia inicialización segura
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EvilNet', // 🔐 MERGE: Nombre consistente con la app autenticada
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF020A06),
        // 🔐 MERGE: Tipografía monospace para consistencia con la estética cyberpunk
        fontFamily: 'monospace',
      ),
      // 🔐 MERGE: AuthScreen como entrada principal (flujo seguro)
      // El usuario debe loguearse antes de acceder al menú
      home: const AuthScreen(),
      
      // 🔐 MERGE: Rutas con nombre para navegación limpia y testeable
      routes: {
        '/menu': (context) => const MenuScreen(),
        // Puedes añadir más rutas aquí según crezca la app:
        // '/profile': (context) => const ProfileScreen(),
        // '/control': (context) => const ControlPanelScreen(),
      },
    );
  }
}