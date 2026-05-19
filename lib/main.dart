import 'package:flutter/material.dart';
import 'screens/menu_screen.dart';
 
void main() => runApp(const App());
 
class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshNet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF020A06),
      ),
      home: const MenuScreen(),
    );
  }
}
 