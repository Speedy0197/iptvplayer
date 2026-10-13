import 'package:flutter/material.dart';
import 'package:flutter_app/screens/tv_pairing_screen.dart';
import 'package:flutter_app/screens/login_screen.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/auth_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _token = 'abcdef0123456789abcdef0123456789abcdef0123456789';

class PairingApi extends ApiClient {
  PairingApi() : super(baseUrl: 'http://fixture.invalid');
  final List<String> actions = [];
  final List<Map<String, dynamic>?> bodies = [];
  bool expired = false;

  @override
  Future<dynamic> get(String path) async => {
    'user_code': '123456',
    'expires_at': expired ? '2000-01-01T00:00:00Z' : '2030-01-01T00:00:00Z',
    'status': 'pending',
    'device_name': 'Living room TV',
  };

  @override
  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    actions.add(path);
    bodies.add(body);
    if (path == '/auth/login') {
      return {
        'token': 'phone-session',
        'user_id': 1,
        'username': 'viewer@example.test',
        'email': 'viewer@example.test',
      };
    }
    return {'message': 'ok'};
  }
}

Future<AuthStore> pumpPairing(
  WidgetTester tester,
  PairingApi api, {
  bool signedIn = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final auth = AuthStore(api: api)..initializing = false;
  if (signedIn) {
    auth.token = 'existing-phone-session';
    auth.username = 'viewer@example.test';
  }
  addTearDown(auth.dispose);
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: auth,
      child: MaterialApp(home: TvPairingScreen(pairingToken: _token)),
    ),
  );
  await tester.pumpAndSettle();
  return auth;
}

void main() {
  testWidgets(
    'a signed-in account explicitly approves, without another login',
    (tester) async {
      final api = PairingApi();
      await pumpPairing(tester, api);
      expect(find.text('123456'), findsOneWidget);
      expect(find.text('Living room TV'), findsOneWidget);
      expect(api.actions, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Approve TV'));
      await tester.pumpAndSettle();
      expect(find.text('TV connected'), findsOneWidget);
      expect(api.actions, ['/auth/tv/approve-session']);
      expect(api.bodies.single, {'pairing_token': _token});
    },
  );

  testWidgets('decline is explicit and never approves the request', (
    tester,
  ) async {
    final api = PairingApi();
    await pumpPairing(tester, api);
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    expect(find.text('Request declined'), findsOneWidget);
    expect(api.actions, ['/auth/tv/decline-session']);
  });

  testWidgets('expired requests cannot be approved', (tester) async {
    final api = PairingApi()..expired = true;
    await pumpPairing(tester, api);
    expect(find.text('Pairing request expired'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Approve TV'), findsNothing);
    expect(api.actions, isEmpty);
  });

  testWidgets('sign-in returns to the pending approval without approving it', (
    tester,
  ) async {
    final api = PairingApi();
    await pumpPairing(tester, api, signedIn: false);
    expect(find.byType(LoginScreen), findsOneWidget);
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'viewer@example.test',
    );
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'fixture-password',
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign In'));
    await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
    await tester.pumpAndSettle();
    expect(find.text('123456'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Approve TV'), findsOneWidget);
    expect(api.actions, ['/auth/login']);
  });
}
