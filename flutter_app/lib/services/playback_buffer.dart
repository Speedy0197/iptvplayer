import 'package:media_kit/media_kit.dart';

/// Start promptly; refill a larger buffer only after the network falls behind.
/// Apply before opening both the main player and recording handoff players.
Future<void> configureNetworkBuffering(Player player) async {
  final nativePlayer = player.platform;
  if (nativePlayer is! NativePlayer) return;

  const properties = <String, String>{
    'cache': 'yes',
    'cache-secs': '30',
    'cache-pause': 'yes',
    // Waiting here would add a fixed delay to every live channel and seek.
    'cache-pause-initial': 'no',
    'cache-pause-wait': '5',
    // media_kit defaults to five seconds, which can abort a recoverable dip.
    'network-timeout': '15',
  };
  for (final property in properties.entries) {
    await nativePlayer.setProperty(property.key, property.value);
  }
}
