import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'agenda_page.dart';
import 'login_page.dart';
import 'session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Session.instance.load();
  runApp(const MyApp());
}

final navigatorKey = GlobalKey<NavigatorState>();

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
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
      home: ListenableBuilder(
        listenable: Session.instance,
        builder: (context, _) {
          final s = Session.instance;
          if (!s.loaded) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          if (!s.isSignedIn) {
            // Oturum kapandıysa üstte açık kalan ekranları kapat
            WidgetsBinding.instance.addPostFrameCallback((_) {
              navigatorKey.currentState?.popUntil((r) => r.isFirst);
            });
          }
          // Hesap değişince ajanda ekranı sıfırdan kurulsun
          return s.isSignedIn
              ? AgendaPage(key: ValueKey(s.user!.id))
              : const LoginPage();
        },
      ),
    );
  }
}
