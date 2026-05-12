import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../../models/models.dart';
import '../../../services/playlist_store.dart';

class PlaylistManagementView extends StatefulWidget {
  final PlaylistStore store;
  final VoidCallback onCreate;
  final ValueChanged<Playlist> onEdit;
  final Future<void> Function(Playlist) onRefresh;
  final ValueChanged<Playlist> onDelete;
  final FocusNode? initialFocusNode;

  const PlaylistManagementView({
    super.key,
    required this.store,
    required this.onCreate,
    required this.onEdit,
    required this.onRefresh,
    required this.onDelete,
    this.initialFocusNode,
  });

  @override
  State<PlaylistManagementView> createState() => _PlaylistManagementViewState();
}

class _PlaylistManagementViewState extends State<PlaylistManagementView> {
  bool _isAndroidTv(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    final directionalNavigation =
        MediaQuery.maybeNavigationModeOf(context) == NavigationMode.directional;
    if (directionalNavigation) {
      return true;
    }

    final size = MediaQuery.sizeOf(context);
    return size.width >= 960 || size.height >= 960;
  }

  @override
  Widget build(BuildContext context) {
    final isAndroidTv = _isAndroidTv(context);

    return Card(
      child: Column(
        children: [
          ListTile(
            title: const Text('Manage Playlists'),
            subtitle: Text(
              isAndroidTv
                  ? 'Refresh playlist sources'
                  : 'Add, edit, refresh or delete playlist sources',
            ),
            trailing: isAndroidTv
                ? null
                : FilledButton.icon(
                    onPressed: widget.onCreate,
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                  ),
          ),
          const Divider(height: 1),
          Expanded(
            child: widget.store.playlists.isEmpty
                ? const Center(child: Text('No playlists yet'))
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: widget.store.playlists.length,
                    separatorBuilder: (_, index) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final p = widget.store.playlists[i];
                      final isRefreshing = widget.store.isRefreshingPlaylist(
                        p.id,
                      );
                      final isFirstItem = i == 0;
                      return Card(
                        child: ListTile(
                          title: Text(p.name),
                          subtitle: Text(p.type.toUpperCase()),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              if (!isAndroidTv)
                                IconButton(
                                  onPressed: isRefreshing
                                      ? null
                                      : () => widget.onEdit(p),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                              IconButton(
                                autofocus: isFirstItem && isAndroidTv,
                                onPressed: isRefreshing
                                    ? null
                                    : () => widget.onRefresh(p),
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
                              if (!isAndroidTv)
                                IconButton(
                                  onPressed: isRefreshing
                                      ? null
                                      : () => widget.onDelete(p),
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
