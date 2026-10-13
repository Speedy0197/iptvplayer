import 'package:flutter/material.dart';
import 'package:flutter_app/screens/forgot_password_screen.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/auth_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class RecoveryApi extends ApiClient {
  RecoveryApi() : super(baseUrl: 'http://fixture.invalid');
  final actions = <String>[];
  bool rejectCode = false;
  bool rejectReset = false;
  @override
  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    actions.add(path);
    if (path == '/auth/reset-password' && rejectReset) {
      throw const ApiException('Reset code expired');
    }
    if (path == '/auth/verify-reset' && rejectCode) {
      throw const ApiException('Invalid code');
    }
    return {'message': 'ok'};
  }
}

Future<void> pumpRecovery(WidgetTester tester, RecoveryApi api) async {
  final auth = AuthStore(api: api)..initializing = false;
  addTearDown(auth.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: auth,
      child: const MaterialApp(home: ForgotPasswordScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'password entry can return to code entry and resend after expiry',
    (tester) async {
      final api = RecoveryApi()..rejectReset = true;
      await pumpRecovery(tester, api);
      await tester.enterText(
        find.byType(TextFormField).first,
        'viewer@example.test',
      );
      await tester.tap(find.text('Send reset code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '1234');
      await tester.tap(find.text('Verify code'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'new-fixture-password',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'new-fixture-password',
      );
      await tester.ensureVisible(find.text('Update password'));
      await tester.tap(find.text('Update password'));
      await tester.pumpAndSettle();
      expect(find.text('Reset code expired'), findsOneWidget);
      await tester.ensureVisible(find.text('Use another code'));
      await tester.tap(find.text('Use another code'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resend code'));
      await tester.pumpAndSettle();
      expect(api.actions.last, '/auth/request-reset');
    },
  );
  testWidgets(
    'recovery shows one task at a time and verifies before password entry',
    (tester) async {
      final api = RecoveryApi();
      await pumpRecovery(tester, api);
      expect(find.text('New password'), findsNothing);
      await tester.enterText(
        find.byType(TextFormField).first,
        'viewer@example.test',
      );
      await tester.tap(find.text('Send reset code'));
      await tester.pumpAndSettle();
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.text('New password'), findsNothing);
      await tester.enterText(find.byType(TextFormField).first, '1234');
      await tester.tap(find.text('Verify code'));
      await tester.pumpAndSettle();
      expect(find.text('New password'), findsOneWidget);
      expect(api.actions, ['/auth/request-reset', '/auth/verify-reset']);
    },
  );

  testWidgets('a rejected recovery code keeps the code step visible', (
    tester,
  ) async {
    final api = RecoveryApi()..rejectCode = true;
    await pumpRecovery(tester, api);
    await tester.enterText(
      find.byType(TextFormField).first,
      'viewer@example.test',
    );
    await tester.tap(find.text('Send reset code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '1234');
    await tester.tap(find.text('Verify code'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid code'), findsOneWidget);
    expect(find.text('New password'), findsNothing);
  });
}
