import 'package:flutter/material.dart';
import '../../../services/playlist_store.dart';
import 'browse_picker.dart';

/// Selection changes browse the source without interrupting the current stream.
class SourceSelector extends StatelessWidget {
  final PlaylistStore store;
  const SourceSelector({super.key, required this.store});
  @override
  Widget build(BuildContext context) {
    final selected = store.playlists
        .where((p) => p.id == store.selectedPlaylistId)
        .firstOrNull;
    return BrowsePicker<int>(
      title: 'Choose source',
      tooltip: 'Switch source',
      searchHint: 'Find a source',
      value: store.selectedPlaylistId ?? -1,
      enabled: store.playlists.isNotEmpty,
      onSelected: (id) => store.selectPlaylist(id, preservePlayback: true),
      choices: [for (final p in store.playlists) BrowseChoice(p.id, p.name)],
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
  Widget build(BuildContext context) => BrowsePicker<String>(
    title: 'Channel groups',
    tooltip: 'Select group',
    searchHint: 'Find a group',
    value: store.selectedGroup ?? '',
    onSelected: (name) =>
        store.selectGroup(name.isEmpty ? null : name, preservePlayback: true),
    choices: [
      const BrowseChoice('', 'All channels'),
      for (final g in store.groups)
        BrowseChoice(g.name, g.name, channelCount: g.channelCount),
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
