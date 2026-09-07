import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:flutter_app/services/casting/casting_controller.dart';
import 'package:flutter_app/widgets/casting/casting_scope.dart';

void main() {
  for (final scenario in [
    (
      name: 'desktop',
      platform: TargetPlatform.windows,
      tv: false,
      height: 844.0,
      enabled: false,
    ),
    (
      name: 'Android TV',
      platform: TargetPlatform.android,
      tv: true,
      height: 844.0,
      enabled: false,
    ),
    (
      name: 'tall Android phone',
      platform: TargetPlatform.android,
      tv: false,
      height: 1000.0,
      enabled: true,
    ),
  ]) {
    testWidgets('${scenario.name} uses the native sender eligibility', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = scenario.platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = Size(390, scenario.height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const channel = MethodChannel('streampilot/platform');
      final queries = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        queries.add(call.method);
        return scenario.tv;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final store = PlaylistStore(
        api: ApiClient(baseUrl: 'http://backend.test'),
      );
      var enabled = false;
      await tester.pumpWidget(
        ChangeNotifierProvider<PlaylistStore>.value(
          value: store,
          child: MaterialApp(
            home: CastingScope(
              child: Builder(
                builder: (context) {
                  enabled = context.watch<CastingController?>() != null;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(enabled, scenario.enabled);
      expect(
        queries,
        scenario.platform == TargetPlatform.android ? ['isAndroidTv'] : isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
