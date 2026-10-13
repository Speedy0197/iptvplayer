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

  Map<int, String> get _feedback => widget.store.playlistRefreshFeedback;
  final Set<int> _refreshing = {};

  Future<void> _refresh(Playlist source) async {
    setState(() {
      _refreshing.add(source.id);
      _feedback[source.id] = 'Updating source…';
    });
    try {
      await widget.onRefresh(source);
      _feedback[source.id] = 'Source updated';
      if (mounted) setState(() {});
    } catch (_) {
      _feedback[source.id] = 'Update failed. Try again.';
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _refreshing.remove(source.id));
    }
  }

  String _updated(Playlist source) {
    final date = DateTime.tryParse(source.lastRefreshed ?? '')?.toLocal();
    if (date == null) return 'Not updated yet';
    return 'Last updated ${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isTv = _isAndroidTv(context);
    return Card(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sources',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Connect a provider, playlist or home receiver.',
                      ),
                    ],
                  ),
                ),
                if (!isTv)
                  IconButton.filled(
                    tooltip: 'Add source',
                    onPressed: widget.onCreate,
                    icon: const Icon(Icons.add),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: widget.store.playlists.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.dns_outlined, size: 40),
                          const SizedBox(height: 12),
                          const Text('Add your first source'),
                          if (!isTv)
                            TextButton(
                              onPressed: widget.onCreate,
                              child: const Text('Add source'),
                            ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    key: const PageStorageKey('sources-list'),
                    padding: const EdgeInsets.all(12),
                    itemCount: widget.store.playlists.length,
                    separatorBuilder: (_, i) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final p = widget.store.playlists[i];
                      final busy =
                          _refreshing.contains(p.id) ||
                          widget.store.isRefreshingPlaylist(p.id);
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text('${p.type.toUpperCase()} · ${_updated(p)}'),
                              if (busy)
                                const Padding(
                                  padding: EdgeInsets.only(top: 12),
                                  child: LinearProgressIndicator(),
                                ),
                              if (_feedback[p.id] != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Semantics(
                                    liveRegion: true,
                                    child: Text(_feedback[p.id]!),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children:
                                    [
                                          OutlinedButton.icon(
                                            autofocus: isTv && i == 0,
                                            onPressed: busy
                                                ? null
                                                : () => _refresh(p),
                                            icon: const Icon(Icons.refresh),
                                            label: const Text('Refresh'),
                                          ),
                                          if (!isTv) ...[
                                            IconButton(
                                              tooltip: 'Edit source',
                                              onPressed: busy
                                                  ? null
                                                  : () => widget.onEdit(p),
                                              icon: const Icon(
                                                Icons.edit_outlined,
                                              ),
                                            ),
                                            IconButton(
                                              tooltip: 'Delete source',
                                              onPressed: busy
                                                  ? null
                                                  : () => widget.onDelete(p),
                                              icon: const Icon(
                                                Icons.delete_outline,
                                              ),
                                            ),
                                          ],
                                        ]
                                        .map(
                                          (action) => action is OutlinedButton
                                              ? Tooltip(
                                                  message: 'Refresh source',
                                                  child: action,
                                                )
                                              : action,
                                        )
                                        .toList(),
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
