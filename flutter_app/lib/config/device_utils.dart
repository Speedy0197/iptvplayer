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
