import 'package:flutter/foundation.dart';

class AppConfig {
  static const String debugApiBase = 'http://localhost:8080/api/v1';
  static const String releaseApiBase = 'https://iptv.florian-zug.de/api/v1';
  static const String latestVersionUrl =
      'https://speedy0197.github.io/iptvplayer/version.json';
  static const String downloadPageUrl =
      'https://speedy0197.github.io/iptvplayer/';

  // Platform-specific download URLs (GitHub latest release)
  static const String _releaseBase =
      'https://github.com/speedy0197/iptvplayer/releases/latest/download';
  static const String androidDownloadUrl = '$_releaseBase/streampilot-android.apk';
  static const String macosDownloadUrl = '$_releaseBase/streampilot-macos.dmg';
    static const String windowsDownloadUrl = '$_releaseBase/streampilot-windows.exe';
  // Opens TestFlight app directly via its custom URL scheme.
  // Falls back to the https link if TestFlight is not installed.
  static const String iosTestFlightSchemeUrl = 'itms-beta://testflight.apple.com/join/fJb6nsgN';
  static const String iosTestFlightFallbackUrl = 'https://testflight.apple.com/join/fJb6nsgN';

  static bool get allowsCustomApiBase => kDebugMode;

  static String get apiBase => releaseApiBase;
}

