import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../config/device_utils.dart';
import '../../services/playlist_store.dart';
import '../../services/casting/casting_controller.dart';
import '../../services/casting/google_cast_transport.dart';
import '../../services/casting/airplay_transport.dart';
import '../../services/casting/playlist_casting_binding.dart';

/// An authenticated mobile session owns its casting adapters. Construction does
/// not initialize SDKs or discover devices; opening the picker starts discovery.
class CastingScope extends StatefulWidget {
  const CastingScope({super.key, required this.child});
  final Widget child;
  @override
  State<CastingScope> createState() => _CastingScopeState();
}

class _CastingScopeState extends State<CastingScope> {
  CastingController? _controller;
  PlaylistCastingBinding? _binding;
  bool _configured = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_configured) return;
    _configured = true;
    if (!isIosOrAndroidPhone(context)) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Use the device's actual UI mode; tall phone screens are not TVs.
      _configureAndroid();
      return;
    }
    _configure();
  }

  Future<void> _configureAndroid() async {
    try {
      final isTv = await const MethodChannel(
        'streampilot/platform',
      ).invokeMethod<bool>('isAndroidTv');
      if (mounted && isTv == false) setState(_configure);
    } on PlatformException {
      // Leave local playback available when the platform cannot identify itself.
    } on MissingPluginException {
      // Unsupported embeddings do not construct native casting adapters.
    }
  }

  void _configure() {
    final binding = PlaylistCastingBinding(context.read<PlaylistStore>());
    final controller = CastingController(
      local: binding,
      transports: [
        GoogleCastTransport(),
        if (defaultTargetPlatform == TargetPlatform.iOS) AirPlayTransport(),
      ],
    );
    binding.attach(controller);
    _binding = binding;
    _controller = controller;
  }

  @override
  void dispose() {
    _controller?.dispose();
    _binding?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ChangeNotifierProvider<CastingController?>.value(
        value: _controller,
        child: widget.child,
      );
}
