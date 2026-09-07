import 'package:flutter/material.dart';

import '../../services/casting/cast_transport.dart';
import '../../services/casting/casting_controller.dart';
import 'cast_device_sheet.dart';

class CastButton extends StatelessWidget {
  const CastButton({super.key, required this.controller});
  final CastingController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final connected =
          controller.hasTarget &&
          controller.status.state != CastPlaybackState.connecting &&
          controller.status.state != CastPlaybackState.failed;
      final actionLabel = connected
          ? 'Stream on TV · ${controller.target!.name}'
          : 'Stream on TV';
      return Semantics(
        label: actionLabel,
        child: IconButton(
          tooltip: actionLabel,
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) => CastDeviceSheet(controller: controller),
          ),
          icon: Icon(
            connected ? Icons.cast_connected : Icons.cast,
            color: connected ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
      );
    },
  );
}
