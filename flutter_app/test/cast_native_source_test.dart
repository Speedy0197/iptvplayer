import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// Source-level privacy and lifecycle checks; not native compilation/runtime tests.
void main() {
  test(
    'AirPlay selection and shared audio cleanup require actual ownership',
    () {
      final native = File('ios/Runner/AirPlayPlugin.swift').readAsStringSync();
      expect(native.contains('routeAtPickerOpening'), isTrue);
      expect(native.contains('guard ownsAudioSession else { return }'), isTrue);
      expect(native.contains('phoneOutputConfirmed'), isTrue);
      expect(native.contains('output.portType == .builtInSpeaker'), isTrue);
    },
  );
  final root = Directory('packages/flutter_chrome_cast');
  test('iOS context initialization and listener registration are repeat-safe', () {
    final plugin = File(
      '${root.path}/ios/flutter_chrome_cast/Sources/flutter_chrome_cast/SwiftGoogleCastPlugin.swift',
    ).readAsStringSync();
    expect(
      RegExp(
        r'if !GCKCastContext.isSharedInstanceInitialized\(\)\s*\{[^}]*GCKCastContext.setSharedInstanceWith\(option\)',
        dotAll: true,
      ).hasMatch(plugin),
      isTrue,
    );
    expect(
      RegExp(
        r'if !castListenersRegistered\s*\{[^}]*discoveryManager.add\([^}]*sessionManager.add\([^}]*castListenersRegistered = true',
        dotAll: true,
      ).hasMatch(plugin),
      isTrue,
    );
    expect(plugin, contains('guard !lifecycleObserversAdded else { return }'));
  });
  test('vendored runtime contains no unstructured native or Dart logging', () {
    final sources = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => ['.swift', '.kt', '.dart'].any(file.path.endsWith));
    for (final file in sources) {
      expect(
        RegExp(
          r'^\s*(?:print|debugPrint|NSLog|Log\.[vdiew])\(',
          multiLine: true,
        ).hasMatch(file.readAsStringSync()),
        isFalse,
        reason: file.path,
      );
    }
    final plugin = File(
      '${root.path}/ios/flutter_chrome_cast/Sources/flutter_chrome_cast/SwiftGoogleCastPlugin.swift',
    ).readAsStringSync();
    expect(plugin, contains('consoleLoggingEnabled = false'));
    expect(plugin, isNot(contains('GCKLoggerLevel.verbose')));
  });
  test(
    'iOS status identity comes from receiver and suspension preserves session',
    () {
      final base =
          '${root.path}/ios/flutter_chrome_cast/Sources/flutter_chrome_cast';
      expect(
        File('$base/RemoteMediaClienteMethodChannel.swift').readAsStringSync(),
        isNot(contains('lastLoadedContentID')),
      );
      expect(
        File('$base/SessionManagerMethodChannel.swift').readAsStringSync(),
        contains('emitSuspended(session)'),
      );
      final plugin = File(
        '$base/SwiftGoogleCastPlugin.swift',
      ).readAsStringSync();
      final initialization = plugin.substring(
        plugin.indexOf('private func setSharedInstanceWithOption'),
        plugin.indexOf('private func setSharedInstanceWithOption') + 2200,
      );
      expect(
        initialization,
        isNot(contains('discoveryManager.startDiscovery()')),
      );
    },
  );
}
