import 'package:flutter/foundation.dart';

class AppConfig {
  static const String debugApiBase = 'http://localhost:8080/api/v1';
  static const String releaseApiBase = 'http://192.168.178.5:8080/api/v1';

  static bool get allowsCustomApiBase => kDebugMode;

  static String get apiBase =>
      allowsCustomApiBase ? debugApiBase : releaseApiBase;
}
