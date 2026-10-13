import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/screens/home/dialogs/playlist_dialog.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:provider/provider.dart';

class RejectedSourceApi extends ApiClient {
  RejectedSourceApi() : super(baseUrl: 'https://fixture.invalid');
  @override
  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    throw const ApiException(
      'HTTP403 while fetching https://private-user:private-password@fixture.invalid/live/private-token/stream',
    );
  }
}

void main() {
  late PlaylistStore store;
  setUp(
    () => store = PlaylistStore(
      api: ApiClient(baseUrl: 'https://fixture.invalid'),
    ),
  );
  tearDown(() => store.dispose());
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: store,
        child: MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'add source explains provider choices and validates next to fields',
    (tester) async {
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showPlaylistDialog(context),
            child: const Text('Open'),
          ),
        ),
        size: const Size(320, 700),
        scale: 1.6,
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('provider'), findsWidgets);
      await tester.ensureVisible(find.text('Create'));
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.decoration?.errorText, 'Name is required');
      expect(find.text('Server URL is required'), findsOneWidget);
      expect(find.text('Username is required'), findsOneWidget);
    },
  );
  testWidgets('source save failures never display provider credentials', (
    tester,
  ) async {
    store.dispose();
    store = PlaylistStore(api: RejectedSourceApi());
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showPlaylistDialog(context),
          child: const Text('Open'),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    for (final field in find.byType(TextField).evaluate()) {
      final widget = field.widget as TextField;
      final label = widget.decoration?.labelText ?? '';
      if (label == 'Name') widget.controller!.text = 'Sample source';
      if (label.toLowerCase().contains('server')) {
        widget.controller!.text = 'https://fixture.invalid';
      }
      if (label.toLowerCase().contains('username')) {
        widget.controller!.text = 'sample-user';
      }
      if (label.toLowerCase().contains('password')) {
        widget.controller!.text = 'sample-password';
      }
    }
    await tester.ensureVisible(find.text('Create'));
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('private-password'), findsNothing);
    expect(find.textContaining('private-token'), findsNothing);
    expect(
      find.textContaining('Check its address and credentials'),
      findsOneWidget,
    );
  });
}
