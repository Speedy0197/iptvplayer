import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/screens/tv_pairing_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tv_pairing_screen_test.dart' show PairingApi;

const token = 'abcdef0123456789abcdef0123456789abcdef0123456789';

class RouteApi extends PairingApi {
  final reads = <String>[];
  @override
  Future<dynamic> get(String path) async {
    reads.add(path);
    if (!path.startsWith('/auth/tv/')) return <dynamic>[];
    return super.get(path);
  }
}

void main() {
  Future<RouteApi> mount(WidgetTester tester, {String initial = '/'}) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'synthetic-phone-session',
      'username': 'viewer@example.test',
    });
    tester.binding.platformDispatcher.defaultRouteNameTestValue = initial;
    addTearDown(
      tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final api = RouteApi();
    await tester.pumpWidget(IptvFlutterApp(api: api));
    await tester.pumpAndSettle();
    return api;
  }

  Future<void> open(WidgetTester tester, String location) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(
        MethodCall('pushRouteInformation', {'location': location}),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  for (final initial in [
    'https://iptv.florian-zug.de/tv/activate#pairing_token=$token',
    'streampilot://tv/activate?pairing_token=$token',
  ]) {
    testWidgets('cold pairing URL opens a pending approval', (tester) async {
      final api = await mount(tester, initial: initial);
      expect(find.byType(TvPairingScreen), findsOneWidget);
      expect(find.text('123456'), findsOneWidget);
      expect(api.actions, isEmpty);
    });
  }
  testWidgets('warm custom app link preserves its token before normalization', (
    tester,
  ) async {
    final api = await mount(tester);
    await open(tester, 'streampilot://tv/activate?pairing_token=$token');
    expect(find.text('123456'), findsOneWidget);
    expect(api.reads, contains('/auth/tv/session?pairing_token=$token'));
    expect(api.actions, isEmpty);
  });
  for (final location in [
    'streampilot://evil/tv/activate#pairing_token=$token',
    'https://untrusted.example/tv/activate#pairing_token=$token',
  ]) {
    testWidgets('warm links validate their original authority', (tester) async {
      final api = await mount(tester);
      await open(tester, location);
      expect(find.text('This link is not supported.'), findsOneWidget);
      expect(find.byType(TvPairingScreen), findsNothing);
      expect(api.reads.where((path) => path.contains('/auth/tv/')), isEmpty);
    });
  }
}
