import 'package:flutter/material.dart';
import '../../../services/playlist_store.dart';

/// Selection changes browse the source without interrupting the current stream.
class SourceSelector extends StatelessWidget {
  final PlaylistStore store;
  const SourceSelector({super.key, required this.store});
  @override
  Widget build(BuildContext context) {
    final selected = store.playlists
        .where((p) => p.id == store.selectedPlaylistId)
        .firstOrNull;
    return PopupMenuButton<int>(
      tooltip: 'Switch source',
      enabled: store.playlists.isNotEmpty,
      onSelected: (id) => store.selectPlaylist(id, preservePlayback: true),
      itemBuilder: (_) => store.playlists
          .map(
            (p) => CheckedPopupMenuItem<int>(
              value: p.id,
              checked: p.id == store.selectedPlaylistId,
              child: Text(p.name),
            ),
          )
          .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.dns_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                selected?.name ?? 'Choose source',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.expand_more),
          ],
        ),
      ),
    );
  }
}

class GroupSelector extends StatelessWidget {
  final PlaylistStore store;
  const GroupSelector({super.key, required this.store});
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Select group',
    onSelected: (name) =>
        store.selectGroup(name.isEmpty ? null : name, preservePlayback: true),
    itemBuilder: (_) => [
      const PopupMenuItem(value: '', child: Text('All channels')),
      ...store.groups.map(
        (g) => PopupMenuItem(
          value: g.name,
          child: Text('${g.name} · ${g.channelCount}'),
        ),
      ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              store.selectedGroup ?? 'All channels',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(Icons.expand_more),
        ],
      ),
    ),
  );
}
