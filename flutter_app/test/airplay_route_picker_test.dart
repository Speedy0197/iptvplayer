import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/widgets/casting/airplay_route_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('forwards the native picker-opening delegate callback', (
    tester,
  ) async {
    var openingCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AirPlayRoutePicker(
          onPickerOpening: () => openingCalls++,
          platformViewBuilder: (onPlatformViewCreated) {
            onPlatformViewCreated(27);
            return const SizedBox(width: 44, height: 44);
          },
        ),
      ),
    );
    await tester.pump();

    await _sendNativeMethodCall(
      AirPlayRoutePicker.channelNameForView(27),
      'pickerOpening',
    );

    expect(openingCalls, 1);
  });

  testWidgets('uses no native surface away from iOS', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AirPlayRoutePicker()));

    expect(find.byType(UiKitView), findsNothing);
    expect(find.byType(SizedBox), findsWidgets);
  });
}

Future<void> _sendNativeMethodCall(String channel, String method) async {
  final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channel, data, null);
}
