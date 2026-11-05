import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'agenda_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gezi Ajandam',
      debugShowCheckedModeBanner: false,
      // Tarih seçici vb. Türkçe görünsün
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const AgendaPage(),
    );
  }
}
