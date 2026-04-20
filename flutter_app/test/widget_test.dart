import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/main.dart';
import 'package:flutter_app/services/api_client.dart';

void main() {
  testWidgets('renders auth gate', (WidgetTester tester) async {
    await tester.pumpWidget(
      IptvFlutterApp(api: ApiClient(baseUrl: 'http://localhost:8080/api/v1')),
    );

    expect(find.byType(IptvFlutterApp), findsOneWidget);
  });
}
