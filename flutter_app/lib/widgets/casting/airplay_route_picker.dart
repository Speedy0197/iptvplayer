import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

typedef AirPlayPlatformViewBuilder =
    Widget Function(PlatformViewCreatedCallback onPlatformViewCreated);

class AirPlayRoutePicker extends StatefulWidget {
  const AirPlayRoutePicker({
    super.key,
    this.onPickerOpening,
    this.size = 44,
    @visibleForTesting this.platformViewBuilder,
  });

  static const viewType = 'streampilot/airplay/route_picker';

  final VoidCallback? onPickerOpening;
  final double size;

  @visibleForTesting
  final AirPlayPlatformViewBuilder? platformViewBuilder;

  @visibleForTesting
  static String channelNameForView(int viewId) =>
      'streampilot/airplay/route_picker/$viewId';

  @override
  State<AirPlayRoutePicker> createState() => _AirPlayRoutePickerState();
}

class _AirPlayRoutePickerState extends State<AirPlayRoutePicker> {
  MethodChannel? _viewChannel;

  @override
  Widget build(BuildContext context) {
    final testBuilder = widget.platformViewBuilder;
    if (testBuilder != null) {
      return testBuilder(_onPlatformViewCreated);
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return const SizedBox.shrink();
    }
    return SizedBox.square(
      dimension: widget.size,
      child: UiKitView(
        viewType: AirPlayRoutePicker.viewType,
        onPlatformViewCreated: _onPlatformViewCreated,
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }

  void _onPlatformViewCreated(int viewId) {
    _viewChannel?.setMethodCallHandler(null);
    final channel = MethodChannel(
      AirPlayRoutePicker.channelNameForView(viewId),
    );
    _viewChannel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'pickerOpening' && mounted) {
        widget.onPickerOpening?.call();
      }
    });
  }

  @override
  void dispose() {
    _viewChannel?.setMethodCallHandler(null);
    _viewChannel = null;
    super.dispose();
  }
}
