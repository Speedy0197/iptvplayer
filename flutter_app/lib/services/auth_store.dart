import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/models.dart';
import 'api_client.dart';

class AuthStore extends ChangeNotifier {
  static const _tokenKey = 'jwt_token';
  static const _usernameKey = 'username'; // stores email as display identity
  static const _userIdKey = 'user_id';
  static const _apiBaseKey = 'api_base';

  final ApiClient api;

  String? token;
  String? username;
  int? userId;
  bool initializing = true;
  bool busy = false;

  AuthStore({required this.api});

  bool get isLoggedIn => token != null && token!.isNotEmpty;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    if (AppConfig.allowsCustomApiBase) {
      final savedApiBase = prefs.getString(_apiBaseKey);
      api.setBaseUrl(
        savedApiBase?.trim().isNotEmpty == true
            ? savedApiBase!
            : AppConfig.apiBase,
      );
    } else {
      await prefs.remove(_apiBaseKey);
      api.setBaseUrl(AppConfig.apiBase);
    }
    token = prefs.getString(_tokenKey);
    username = prefs.getString(_usernameKey);
    userId = prefs.getInt(_userIdKey);
    api.setToken(token);
    initializing = false;
    notifyListeners();
  }

  Future<void> setApiBase(String value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!AppConfig.allowsCustomApiBase) {
      await prefs.remove(_apiBaseKey);
      api.setBaseUrl(AppConfig.apiBase);
      notifyListeners();
      return;
    }

    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(_apiBaseKey);
      api.setBaseUrl(AppConfig.apiBase);
    } else {
      await prefs.setString(_apiBaseKey, trimmed);
      api.setBaseUrl(trimmed);
    }
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    busy = true;
    notifyListeners();
    try {
      final json =
          await api.post('/auth/login', {'email': email, 'password': password})
              as Map<String, dynamic>;
      await _persist(AuthResponse.fromJson(json));
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> register(String email, String password) async {
    busy = true;
    notifyListeners();
    try {
      await api.post('/auth/register', {'email': email, 'password': password});
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> verifyEmail(String email, String code) async {
    busy = true;
    notifyListeners();
    try {
      await api.post('/auth/verify-email', {'email': email, 'code': code});
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> resendVerification(String email) async {
    busy = true;
    notifyListeners();
    try {
      await api.post('/auth/resend-verification', {'email': email});
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> requestPasswordReset(String email) async {
    await api.post('/auth/request-reset', {'email': email});
  }

  Future<void> verifyResetToken(String email, String code) async {
    await api.post('/auth/verify-reset', {'email': email, 'code': code});
  }

  Future<void> resetPassword(
    String email,
    String code,
    String newPassword,
  ) async {
    await api.post('/auth/reset-password', {
      'email': email,
      'code': code,
      'new_password': newPassword,
    });
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_userIdKey);
    token = null;
    username = null;
    userId = null;
    api.setToken(null);
    notifyListeners();
  }

  Future<void> _persist(AuthResponse auth) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, auth.token);
    await prefs.setString(_usernameKey, auth.username);
    await prefs.setInt(_userIdKey, auth.userId);
    token = auth.token;
    username = auth.username;
    userId = auth.userId;
    api.setToken(auth.token);
  }
}
