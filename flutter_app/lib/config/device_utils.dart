import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool? _nativeAndroidTv;

Future<void> initializeDeviceType() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    _nativeAndroidTv = await const MethodChannel(
      'streampilot/platform',
    ).invokeMethod<bool>('isAndroidTv');
  } on PlatformException {
    // Fall back to layout information when native detection is unavailable.
  } on MissingPluginException {
    // Tests and unsupported embeddings use the layout fallback.
  }
}

bool isAndroidTv(BuildContext context) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return false;
  }

  if (_nativeAndroidTv != null) return _nativeAndroidTv!;

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
