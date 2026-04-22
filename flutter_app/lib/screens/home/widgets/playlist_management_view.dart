import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../services/playlist_store.dart';

class PlaylistManagementView extends StatelessWidget {
  final PlaylistStore store;
  final VoidCallback onCreate;
  final ValueChanged<Playlist> onEdit;
  final Future<void> Function(Playlist) onRefresh;
  final ValueChanged<Playlist> onDelete;

  const PlaylistManagementView({
    super.key,
    required this.store,
    required this.onCreate,
    required this.onEdit,
    required this.onRefresh,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            title: const Text('Manage Playlists'),
            subtitle: const Text(
              'Add, edit, refresh or delete playlist sources',
            ),
            trailing: FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: store.playlists.isEmpty
                ? const Center(child: Text('No playlists yet'))
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: store.playlists.length,
                    separatorBuilder: (_, index) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final p = store.playlists[i];
                      final isRefreshing = store.isRefreshingPlaylist(p.id);
                      return Card(
                        child: ListTile(
                          title: Text(p.name),
                          subtitle: Text(p.type.toUpperCase()),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              IconButton(
                                onPressed: isRefreshing
                                    ? null
                                    : () => onEdit(p),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                onPressed: isRefreshing
                                    ? null
                                    : () => onRefresh(p),
                                tooltip: isRefreshing
                                    ? 'Updating playlist...'
                                    : 'Reload playlist',
                                icon: isRefreshing
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.refresh),
                              ),
                              IconButton(
                                onPressed: isRefreshing
                                    ? null
                                    : () => onDelete(p),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
