import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'models/task_model.dart';
import 'models/task_provider.dart';
import 'views/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (context) => TaskProvider(),
      child: const MusicPianoApp(),
    ),
  );
}

class MusicPianoApp extends StatelessWidget {
  const MusicPianoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Piano App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2E86DE),
        brightness: Brightness.light,
        textTheme: GoogleFonts.notoSansTextTheme(),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2E86DE),
        brightness: Brightness.dark,
        textTheme: GoogleFonts.notoSansTextTheme(
          ThemeData(brightness: Brightness.dark).textTheme,
        ),
      ),
      home: const HomePage(),
    );
  }
}
