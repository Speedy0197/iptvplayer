import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

bool isAndroidTv(BuildContext context) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return false;
  }

  final directionalNavigation =
      MediaQuery.maybeNavigationModeOf(context) == NavigationMode.directional;
  if (directionalNavigation) {
    return true;
  }

  final size = MediaQuery.sizeOf(context);
  return size.width >= 960 || size.height >= 960;
}

bool isMacOrWindowsDesktop() {
  if (kIsWeb) {
    return false;
  }
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;
}

bool isIosOrAndroidPhone(BuildContext context) {
  if (kIsWeb) {
    return false;
  }
  final isMobilePlatform =
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
  if (!isMobilePlatform) {
    return false;
  }

  // Keep tablets unchanged; apply only on phone-sized layouts.
  final size = MediaQuery.sizeOf(context);
  return size.shortestSide < 600;
}
