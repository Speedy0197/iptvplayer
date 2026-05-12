import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../services/playlist_store.dart';

/// Bottom-sheet action menu opened by long-pressing a channel or group tile
/// on Android TV. Each row is a large, D-pad-focusable button.
class ChannelActionSheet extends StatelessWidget {
  final Channel channel;
  final PlaylistStore store;
  final Future<void> Function()? onPlay;

  const ChannelActionSheet({
    super.key,
    required this.channel,
    required this.store,
    this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final isFav = channel.isFavorite;
    final theme = Theme.of(context);

    return _ActionSheetBody(
      title: channel.name,
      titleStyle: theme.textTheme.titleLarge,
      children: [
        _ActionButton(
          icon: Icons.play_arrow,
          label: 'Play',
          autofocus: true,
          onPressed: () async {
            await _dismissSheetThenRun(context, () async {
              if (onPlay != null) {
                await onPlay!();
              } else {
                await store.play(channel);
              }
            });
          },
        ),
        const SizedBox(height: 8),
        _ActionButton(
          icon: isFav ? Icons.star : Icons.star_border,
          iconColor: isFav ? Colors.amber : null,
          label: isFav ? 'Remove from favorites' : 'Add to favorites',
          onPressed: () async {
            Navigator.of(context).pop();
            try {
              await store.toggleFavorite(channel);
            } on ApiException catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(e.message)));
            }
          },
        ),
        const SizedBox(height: 8),
        _ActionButton(
          icon: Icons.close,
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// Action menu opened by long-pressing a favorite-group tile.
class GroupActionSheet extends StatelessWidget {
  final Group group;
  final PlaylistStore store;
  final Future<void> Function()? onOpen;

  const GroupActionSheet({
    super.key,
    required this.group,
    required this.store,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final isFav = group.isFavorite;
    final theme = Theme.of(context);

    return _ActionSheetBody(
      title: group.name,
      titleStyle: theme.textTheme.titleLarge,
      children: [
        if (onOpen != null) ...[
          _ActionButton(
            icon: Icons.folder_open,
            label: 'Open group',
            autofocus: true,
            onPressed: () async {
              await _dismissSheetThenRun(context, onOpen!);
            },
          ),
          const SizedBox(height: 8),
        ],
        _ActionButton(
          icon: isFav ? Icons.star : Icons.star_border,
          iconColor: isFav ? Colors.amber : null,
          label: isFav ? 'Remove from favorites' : 'Add to favorites',
          autofocus: onOpen == null,
          onPressed: () async {
            Navigator.of(context).pop();
            try {
              await store.toggleFavoriteGroup(group);
            } on ApiException catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(e.message)));
            }
          },
        ),
        const SizedBox(height: 8),
        _ActionButton(
          icon: Icons.close,
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _ActionSheetBody extends StatelessWidget {
  final String title;
  final TextStyle? titleStyle;
  final List<Widget> children;

  const _ActionSheetBody({
    required this.title,
    required this.titleStyle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Text(
                title,
                style: titleStyle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;
  final Color? iconColor;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: FilledButton.tonalIcon(
        autofocus: autofocus,
        onPressed: onPressed,
        icon: Icon(icon, color: iconColor),
        label: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: const TextStyle(fontSize: 20),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        style: FilledButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
      ),
    );
  }
}

Future<void> _dismissSheetThenRun(
  BuildContext context,
  Future<void> Function() action,
) async {
  Navigator.of(context).pop();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    action();
  });
}

Future<void> showChannelActionSheet(
  BuildContext context, {
  required Channel channel,
  required PlaylistStore store,
  Future<void> Function()? onPlay,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) =>
        ChannelActionSheet(channel: channel, store: store, onPlay: onPlay),
  );
}

Future<void> showGroupActionSheet(
  BuildContext context, {
  required Group group,
  required PlaylistStore store,
  Future<void> Function()? onOpen,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) =>
        GroupActionSheet(group: group, store: store, onOpen: onOpen),
  );
}
