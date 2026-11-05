import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Giriş yapmış kullanıcı ve oturum anahtarı. Telefonda saklanır,
/// böylece uygulama her açıldığında tekrar giriş istenmez.
class Session extends ChangeNotifier {
  Session._();
  static final Session instance = Session._();

  static const _kToken = 'auth_token';
  static const _kUser = 'auth_user';

  final PhotoApi _api = PhotoApi();

  AppUser? user;
  bool loaded = false;

  /// Oturum kapandığında gösterilecek açıklama (ör. süresi doldu).
  String? signedOutReason;

  bool get isSignedIn => user != null && PhotoApi.token != null;

  Future<void> load() async {
    PhotoApi.onUnauthorized = () => signOut(reason: 'Oturumun sona erdi, tekrar giriş yap.');
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_kToken);
      final userJson = prefs.getString(_kUser);
      if (token != null && userJson != null) {
        PhotoApi.token = token;
        user = AppUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
      }
    } catch (_) {
      // Saklanan veri bozuksa girişsiz başla
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> login(String email, String password) async =>
      _save(await _api.login(email, password));

  Future<void> register(String email, String password, String name) async =>
      _save(await _api.register(email, password, name));

  Future<void> _save(AuthResult r) async {
    PhotoApi.token = r.token;
    user = r.user;
    signedOutReason = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, r.token);
    await prefs.setString(_kUser, jsonEncode(r.user.toJson()));
    notifyListeners();
  }

  Future<void> signOut({String? reason}) async {
    if (user == null && PhotoApi.token == null) return;
    PhotoApi.token = null;
    user = null;
    signedOutReason = reason;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kUser);
    notifyListeners();
  }
}
