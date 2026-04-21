import 'package:flutter/foundation.dart';

class AppConfig {
  static const String debugApiBase = 'http://localhost:8080/api/v1';
  static const String releaseApiBase = 'https://iptv.florian-zug.de/api/v1';
    static const String latestVersionUrl =
            'https://flodev.github.io/IptvPlayer/version.json';

  static bool get allowsCustomApiBase => kDebugMode;

  static String get apiBase =>
      allowsCustomApiBase ? debugApiBase : releaseApiBase;
}
