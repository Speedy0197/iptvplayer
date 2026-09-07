import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/casting/cast_transport.dart';
import '../../services/casting/casting_controller.dart';
import 'cast_player_surface.dart';
import 'airplay_route_picker.dart';

class CastDeviceSheet extends StatefulWidget {
  const CastDeviceSheet({super.key, required this.controller});
  final CastingController controller;

  @override
  State<CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends State<CastDeviceSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.startDiscovery());
    });
  }

  @override
  void dispose() {
    unawaited(widget.controller.stopDiscovery());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final devices = controller.devices
          .where((d) => d.kind == CastRouteKind.googleCast)
          .toList();
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Stream on TV',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Keep your phone and TV on the same Wi-Fi. No extra app is needed on compatible receivers.',
              ),
              if (controller.hasTarget) ...[
                const SizedBox(height: 20),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cast_connected),
                  title: Text(controller.target!.name),
                  subtitle: Text(castStatusLabel(controller)),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    PhonePlaybackButton(controller: controller),
                    TextButton(
                      onPressed: controller.disconnect,
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
              ],
              if (controller.status.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  controller.status.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: controller.retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry playback'),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              const Text(
                'Google Cast',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'NVIDIA Shield, Chromecast, Google TV and TVs with Google Cast.',
              ),
              if (controller.discovering && devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              for (final device in devices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.tv),
                  title: Text(device.name),
                  trailing: controller.target?.id == device.id
                      ? const Icon(Icons.check)
                      : const Icon(Icons.chevron_right),
                  onTap: () => controller.connect(device),
                ),
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    controller.discoveryError ??
                        (controller.discovering
                            ? 'Looking for TVs…'
                            : 'No TVs found yet. Turn on your TV and check local-network permission.'),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: controller.startDiscovery,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Find TVs again'),
                ),
              ),
              if (controller.supportsAirPlay) ...[
                const Divider(height: 28),
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'AirPlay',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Apple TV and TVs with AirPlay video support. If a TV is already selected in iOS, choose iPhone first, then select that TV here.',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Semantics(
                      label: 'Choose an AirPlay TV',
                      child: AirPlayRoutePicker(
                        onPickerOpening: controller.beginAirPlaySelection,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Some streams or formats may be unavailable on your TV. You can always return to phone playback.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
    },
  );
}
