import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../services/auth_store.dart';
import '../services/playlist_store.dart';
import '../widgets/channel_player.dart';

enum _HomeSection { watch, favorites, playlists }

typedef _GroupTapCallback = Future<void> Function(Group group);
typedef _ChannelTapCallback = Future<void> Function(Channel channel);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchCtrl = TextEditingController();
  static const double _compactBreakpoint = 900;
  static const int _watchViewPlaylists = 0;
  static const int _watchViewGroups = 1;
  static const int _watchViewChannels = 2;
  static const int _watchViewPlayer = 3;
  _HomeSection _section = _HomeSection.watch;
  int _compactWatchView = 0;
  int _compactFavoritesView = 0;
  late final PageController _compactWatchController;
  late final PageController _compactFavoritesController;
  bool _searchDialogOpen = false;
  bool _searchDialogPending = false;

  @override
  void initState() {
    super.initState();
    _compactWatchController = PageController(initialPage: _compactWatchView);
    _compactFavoritesController = PageController(
      initialPage: _compactFavoritesView,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PlaylistStore>().bootstrap();
    });
  }

  @override
  void dispose() {
    _compactWatchController.dispose();
    _compactFavoritesController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openCompactPlayer(PlaylistStore store) async {
    if (!mounted) return;

    final isSmallCompact =
        MediaQuery.sizeOf(context).width < _compactBreakpoint;
    final favoritesPlayerPage = isSmallCompact ? 2 : 1;

    if (_section == _HomeSection.favorites) {
      setState(() => _compactFavoritesView = favoritesPlayerPage);
      if (_compactFavoritesController.hasClients) {
        await _compactFavoritesController.animateToPage(
          favoritesPlayerPage,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
      return;
    }

    if (_section != _HomeSection.watch) {
      setState(() {
        _section = _HomeSection.watch;
        _compactWatchView = _watchViewPlayer;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_compactWatchController.hasClients) return;
        _compactWatchController.animateToPage(
          _watchViewPlayer,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
      return;
    }

    setState(() => _compactWatchView = _watchViewPlayer);
    if (_compactWatchController.hasClients) {
      await _compactWatchController.animateToPage(
        _watchViewPlayer,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _goToCompactWatchPage(int page) async {
    if (!mounted) return;
    if (_compactWatchView != page) {
      setState(() => _compactWatchView = page);
    }
    if (_compactWatchController.hasClients) {
      await _compactWatchController.animateToPage(
        page,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  void _cleanupSearch() {
    _searchCtrl.clear();
    if (mounted) {
      context.read<PlaylistStore>().setSearchQuery('');
    }
  }

  Future<void> _handleGlobalSearchInput(String query) async {
    final store = context.read<PlaylistStore>();
    store.setSearchQuery(query);

    if (_searchDialogOpen || _searchDialogPending) {
      return;
    }

    if (query.trim().isEmpty) {
      return;
    }

    if (!_searchDialogPending) {
      _searchDialogPending = true;
      unawaited(
        store.ensureGlobalSearchData().whenComplete(() {
          _searchDialogPending = false;
        }),
      );
    }

    if (!mounted || _searchDialogOpen) return;
    await _showSearchDialog();
  }

  Future<void> _jumpToSearchResult(SearchResultItem item) async {
    if (!mounted) return;

    final store = context.read<PlaylistStore>();

    try {
      if (item.type == SearchResultType.group) {
        final g = item.group!;
        final groupPlaylistId = g.playlistId > 0
            ? g.playlistId
            : store.selectedPlaylistId;
        if (groupPlaylistId != null) {
          if (store.selectedPlaylistId != groupPlaylistId) {
            await store.selectPlaylist(groupPlaylistId);
          }
          await store.selectGroup(g.name);
        }
      } else {
        final c = item.channel!;
        if (store.selectedPlaylistId != c.playlistId) {
          await store.selectPlaylist(c.playlistId);
        }
        await store.play(c);
      }

      if (mounted) {
        setState(() => _section = _HomeSection.watch);
        if (item.type == SearchResultType.group) {
          final isSmallCompact =
              MediaQuery.sizeOf(context).width < _compactBreakpoint;
          if (isSmallCompact) {
            await _goToCompactWatchPage(_watchViewChannels);
          }
        }
      }
    } catch (e) {
      // Ignore errors during navigation
    }
  }

  Future<void> _openFavoriteGroup(Group group) async {
    if (!mounted) return;

    final store = context.read<PlaylistStore>();
    final isSmallCompact =
        MediaQuery.sizeOf(context).width < _compactBreakpoint;

    if (_section != _HomeSection.watch) {
      setState(() => _section = _HomeSection.watch);
    }

    try {
      final normalizedGroup = await store.normalizeFavoriteGroupPlaylist(group);
      final targetPlaylistId = normalizedGroup.playlistId;
      if (targetPlaylistId <= 0) {
        throw const ApiException('Group is not available in any playlist');
      }

      if (store.selectedPlaylistId != targetPlaylistId) {
        await store.selectPlaylist(targetPlaylistId);
      }
      await store.selectGroup(normalizedGroup.name);

      if (!mounted) return;

      if (isSmallCompact) {
        if (_compactWatchView != _watchViewChannels) {
          setState(() => _compactWatchView = _watchViewChannels);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_compactWatchController.hasClients) return;
          _compactWatchController.animateToPage(
            _watchViewChannels,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open group: $e')));
    }
  }

  Future<void> _openFavoriteChannel(Channel channel) async {
    if (!mounted) return;

    final store = context.read<PlaylistStore>();

    try {
      await store.play(channel);

      if (!mounted) return;

      final isCompact = MediaQuery.sizeOf(context).width < _compactBreakpoint;
      if (isCompact) {
        await _openCompactPlayer(store);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not play channel: $e')));
    }
  }

  Future<void> _refreshPlaylistWithFeedback(Playlist playlist) async {
    if (!mounted) return;

    final store = context.read<PlaylistStore>();
    if (store.isRefreshingPlaylist(playlist.id)) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final progressBar = messenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 1),
        content: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Updating "${playlist.name}"...')),
          ],
        ),
      ),
    );

    try {
      final pulledCount = await store.refreshPlaylist(playlist.id);
      if (!mounted) return;
      progressBar.close();

      final message = pulledCount == null
          ? 'Playlist "${playlist.name}" updated.'
          : 'Playlist "${playlist.name}" updated: $pulledCount channels pulled.';
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } on ApiException catch (e) {
      if (!mounted) return;
      progressBar.close();
      messenger.showSnackBar(
        SnackBar(content: Text('Update failed: ${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      progressBar.close();
      messenger.showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _showSearchDialog() async {
    if (!mounted || _searchDialogOpen) return;

    if (!_searchDialogPending) {
      _searchDialogPending = true;
      unawaited(
        context.read<PlaylistStore>().ensureGlobalSearchData().whenComplete(() {
          _searchDialogPending = false;
        }),
      );
    }

    if (!mounted) return;
    _searchDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (didPop) return;
              _cleanupSearch();
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
              }
            },
            child: Dialog(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 760,
                  maxHeight: 620,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      TextFormField(
                        initialValue: _searchCtrl.text,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: 'Search channels, groups',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (value) {
                          _searchCtrl.text = value;
                          context.read<PlaylistStore>().setSearchQuery(value);
                        },
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Consumer<PlaylistStore>(
                          builder: (context, store, _) {
                            final groups = store.globalFilteredGroups;
                            final channels = store.globalFilteredChannels;

                            if (!store.hasActiveSearch) {
                              return const Center(
                                child: Text('Type to search'),
                              );
                            }

                            if (store.loadingGlobalSearch) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }

                            if (groups.isEmpty && channels.isEmpty) {
                              return const Center(
                                child: Text('No matches found'),
                              );
                            }

                            final children = <Widget>[];

                            void addSectionDivider() {
                              if (children.isNotEmpty) {
                                children.add(const Divider(height: 20));
                              }
                            }

                            if (groups.isNotEmpty) {
                              addSectionDivider();
                              children.add(
                                Text(
                                  'Groups',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              );
                              children.add(const SizedBox(height: 6));
                              for (final g in groups) {
                                children.add(
                                  ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.folder_open),
                                    title: Text(g.name),
                                    subtitle: Text(
                                      '${g.channelCount} channels',
                                    ),
                                    onTap: () {
                                      Navigator.of(ctx).pop();
                                      Future.microtask(
                                        () => _jumpToSearchResult(
                                          SearchResultItem.group(g),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              }
                            }

                            if (channels.isNotEmpty) {
                              addSectionDivider();
                              children.add(
                                Text(
                                  'Channels',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              );
                              children.add(const SizedBox(height: 6));
                              for (final c in channels) {
                                final playlistName = store.playlists
                                    .firstWhere(
                                      (p) => p.id == c.playlistId,
                                      orElse: () => Playlist(
                                        id: c.playlistId,
                                        name: 'Unknown',
                                        type: 'm3u',
                                      ),
                                    )
                                    .name;
                                children.add(
                                  _SearchChannelResultTile(
                                    key: ValueKey(c.id),
                                    channel: c,
                                    playlistName: playlistName,
                                    onTap: () {
                                      Navigator.of(ctx).pop();
                                      Future.microtask(
                                        () => _jumpToSearchResult(
                                          SearchResultItem.channel(c),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              }
                            }

                            return ListView(children: children);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    } finally {
      _cleanupSearch();
      _searchDialogOpen = false;
    }
  }

  Future<void> _showPlaylistDialog(
    BuildContext context, {
    Playlist? editing,
  }) async {
    final nameCtrl = TextEditingController(text: editing?.name ?? '');
    final m3uUrlCtrl = TextEditingController(text: editing?.m3uUrl ?? '');
    final xtreamServerCtrl = TextEditingController(
      text: editing?.xtreamServer ?? '',
    );
    final xtreamUserCtrl = TextEditingController(
      text: editing?.xtreamUsername ?? '',
    );
    final xtreamPassCtrl = TextEditingController();
    final vuplusIpCtrl = TextEditingController(text: editing?.vuplusIp ?? '');
    final vuplusPortCtrl = TextEditingController(
      text: editing?.vuplusPort ?? '80',
    );

    var selectedType = editing?.type ?? 'xtream';
    var m3uSource = editing?.type == 'm3u' && ((editing?.m3uUrl ?? '').isEmpty)
        ? 'file'
        : 'url';
    String? m3uContent;
    String? m3uFileName;
    String? error;
    var submitting = false;
    String? successMessage;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            final dialogWidth = MediaQuery.sizeOf(ctx).width;
            return AlertDialog(
              title: Text(editing == null ? 'Add playlist' : 'Edit playlist'),
              content: SizedBox(
                width: dialogWidth > 640 ? 520 : dialogWidth - 64,
                height: 340,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'xtream', label: Text('Xtream')),
                        ButtonSegment(value: 'vuplus', label: Text('VU+')),
                        ButtonSegment(value: 'm3u', label: Text('M3U')),
                      ],
                      selected: {selectedType},
                      onSelectionChanged: editing != null
                          ? null
                          : (next) {
                              setState(() {
                                selectedType = next.first;
                                error = null;
                              });
                            },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (selectedType == 'm3u')
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SegmentedButton<String>(
                                  showSelectedIcon: false,
                                  segments: const [
                                    ButtonSegment(
                                      value: 'url',
                                      label: Text('URL'),
                                    ),
                                    ButtonSegment(
                                      value: 'file',
                                      label: Text('File Upload'),
                                    ),
                                  ],
                                  selected: {m3uSource},
                                  onSelectionChanged: (next) {
                                    setState(() {
                                      m3uSource = next.first;
                                      error = null;
                                    });
                                  },
                                ),
                                const SizedBox(height: 12),
                                if (m3uSource == 'url')
                                  TextField(
                                    controller: m3uUrlCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'M3U URL',
                                    ),
                                  )
                                else ...[
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      final result = await FilePicker.platform
                                          .pickFiles(
                                            type: FileType.custom,
                                            allowedExtensions: const [
                                              'm3u',
                                              'm3u8',
                                              'txt',
                                            ],
                                            withData: true,
                                          );
                                      if (result == null ||
                                          result.files.isEmpty) {
                                        return;
                                      }

                                      final pickedFile = result.files.first;
                                      final bytes = pickedFile.bytes;
                                      if (bytes == null || bytes.isEmpty) {
                                        setState(() {
                                          error =
                                              'Could not read the selected M3U file';
                                        });
                                        return;
                                      }

                                      setState(() {
                                        m3uContent = utf8.decode(
                                          bytes,
                                          allowMalformed: true,
                                        );
                                        m3uFileName = pickedFile.name;
                                        error = null;
                                      });
                                    },
                                    icon: const Icon(Icons.upload_file),
                                    label: Text(
                                      m3uFileName == null
                                          ? 'Choose M3U File'
                                          : 'Replace File',
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.outlineVariant,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      m3uFileName ??
                                          'No file selected. Upload an M3U file from this device.',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ),
                                ],
                              ],
                            )
                          else if (selectedType == 'xtream') ...[
                            TextField(
                              controller: xtreamServerCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Xtream server URL',
                                hintText: 'http://provider.example.com:8080',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: xtreamUserCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Xtream username',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: xtreamPassCtrl,
                              decoration: InputDecoration(
                                labelText: editing == null
                                    ? 'Xtream password'
                                    : 'Xtream password (optional)',
                              ),
                              obscureText: true,
                            ),
                          ] else ...[
                            TextField(
                              controller: vuplusIpCtrl,
                              decoration: const InputDecoration(
                                labelText: 'VU+ IP / host',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: vuplusPortCtrl,
                              decoration: const InputDecoration(
                                labelText: 'VU+ port',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 30,
                      child: error == null
                          ? null
                          : Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                error!,
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          setState(() {
                            submitting = true;
                            error = null;
                          });

                          try {
                            final store = context.read<PlaylistStore>();
                            final name = nameCtrl.text.trim();
                            if (name.isEmpty) {
                              throw const ApiException('Name is required');
                            }

                            if (selectedType == 'm3u') {
                              if (m3uSource == 'url' &&
                                  m3uUrlCtrl.text.trim().isEmpty) {
                                throw const ApiException('M3U URL is required');
                              }
                              if (m3uSource == 'file' &&
                                  (m3uContent == null ||
                                      m3uContent!.trim().isEmpty)) {
                                throw const ApiException(
                                  'Please choose an M3U file',
                                );
                              }
                            }

                            if (editing == null) {
                              if (selectedType == 'm3u') {
                                await store.createM3uPlaylist(
                                  name: name,
                                  m3uUrl: m3uSource == 'url'
                                      ? m3uUrlCtrl.text.trim()
                                      : null,
                                  m3uContent: m3uSource == 'file'
                                      ? m3uContent
                                      : null,
                                );
                              } else if (selectedType == 'xtream') {
                                await store.createXtreamPlaylist(
                                  name: name,
                                  server: xtreamServerCtrl.text.trim(),
                                  username: xtreamUserCtrl.text.trim(),
                                  password: xtreamPassCtrl.text,
                                );
                              } else {
                                await store.createVuplusPlaylist(
                                  name: name,
                                  ip: vuplusIpCtrl.text.trim(),
                                  port: vuplusPortCtrl.text.trim().isEmpty
                                      ? '80'
                                      : vuplusPortCtrl.text.trim(),
                                );
                              }
                            } else {
                              await store.updatePlaylist(
                                id: editing.id,
                                type: selectedType,
                                name: name,
                                m3uUrl:
                                    selectedType == 'm3u' && m3uSource == 'url'
                                    ? m3uUrlCtrl.text.trim()
                                    : null,
                                m3uContent:
                                    selectedType == 'm3u' && m3uSource == 'file'
                                    ? m3uContent
                                    : null,
                                xtreamServer: xtreamServerCtrl.text.trim(),
                                xtreamUsername: xtreamUserCtrl.text.trim(),
                                xtreamPassword: xtreamPassCtrl.text,
                                vuplusIp: vuplusIpCtrl.text.trim(),
                                vuplusPort: vuplusPortCtrl.text.trim(),
                              );
                            }

                            if (!ctx.mounted) return;
                            successMessage = editing == null
                                ? 'Playlist created'
                                : 'Playlist updated';
                            Navigator.of(ctx).pop();
                          } on ApiException catch (e) {
                            setState(() => error = e.message);
                          } catch (_) {
                            setState(() => error = 'Could not save playlist');
                          } finally {
                            if (ctx.mounted && successMessage == null) {
                              setState(() => submitting = false);
                            }
                          }
                        },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (submitting) ...[
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        submitting
                            ? (editing == null ? 'Creating...' : 'Saving...')
                            : (editing == null ? 'Create' : 'Save'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (successMessage != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage!)));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameCtrl.dispose();
      m3uUrlCtrl.dispose();
      xtreamServerCtrl.dispose();
      xtreamUserCtrl.dispose();
      xtreamPassCtrl.dispose();
      vuplusIpCtrl.dispose();
      vuplusPortCtrl.dispose();
    });
  }

  Future<void> _confirmDeletePlaylist(BuildContext context, Playlist p) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Delete playlist'),
          content: Text('Delete "${p.name}" and all imported channels?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;

    try {
      await context.read<PlaylistStore>().deletePlaylist(p.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted ${p.name}')));
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _handleSectionChange(_HomeSection next) {
    setState(() {
      _section = next;
      if (next == _HomeSection.favorites) {
        _compactFavoritesView = 0;
      }
    });
    if (next == _HomeSection.watch) {
      context.read<PlaylistStore>().fetchFavoriteGroups();
    }
    if (next == _HomeSection.favorites) {
      final store = context.read<PlaylistStore>();
      store.fetchFavoriteChannels();
      store.fetchFavoriteGroups();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_compactFavoritesController.hasClients) return;
        _compactFavoritesController.jumpToPage(0);
      });
    }
  }

  Widget _buildCompactTabStrip({
    required int selectedIndex,
    required List<IconData> icons,
    required List<String> labels,
    required ValueChanged<int> onSelected,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.7),
          ),
        ),
        child: Row(
          children: List.generate(icons.length, (index) {
            final isSelected = index == selectedIndex;
            return Expanded(
              flex: isSelected ? 4 : 2,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  color: isSelected
                      ? Theme.of(context).colorScheme.surfaceContainerHighest
                      : Colors.transparent,
                  border: index == 0
                      ? null
                      : Border(
                          left: BorderSide(
                            color: Theme.of(
                              context,
                            ).colorScheme.outline.withValues(alpha: 0.45),
                          ),
                        ),
                ),
                child: InkWell(
                  onTap: () => onSelected(index),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icons[index], size: isSelected ? 19 : 17),
                        if (isSelected) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              labels[index],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildCompactWatchSection(PlaylistStore store) {
    final isSmallCompact =
        MediaQuery.sizeOf(context).width < _compactBreakpoint;

    return Column(
      children: [
        SizedBox(
          width: isSmallCompact ? double.infinity : null,
          child: isSmallCompact
              ? _buildCompactTabStrip(
                  selectedIndex: _compactWatchView,
                  icons: const [
                    Icons.playlist_play,
                    Icons.folder_open,
                    Icons.tv,
                    Icons.smart_display,
                  ],
                  labels: const ['Playlists', 'Groups', 'Channels', 'Player'],
                  onSelected: (index) {
                    _goToCompactWatchPage(index);
                  },
                )
              : SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<int>(
                      value: _watchViewPlaylists,
                      icon: Icon(Icons.playlist_play),
                      label: Text('Playlists'),
                    ),
                    ButtonSegment<int>(
                      value: _watchViewGroups,
                      icon: Icon(Icons.folder_open),
                      label: Text('Groups'),
                    ),
                    ButtonSegment<int>(
                      value: _watchViewChannels,
                      icon: Icon(Icons.tv),
                      label: Text('Channels'),
                    ),
                    ButtonSegment<int>(
                      value: _watchViewPlayer,
                      icon: Icon(Icons.smart_display),
                      label: Text('Player'),
                    ),
                  ],
                  selected: {_compactWatchView},
                  onSelectionChanged: (next) async {
                    final page = next.first;
                    await _goToCompactWatchPage(page);
                  },
                ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: PageView(
            controller: _compactWatchController,
            onPageChanged: (index) {
              if (_compactWatchView != index) {
                setState(() => _compactWatchView = index);
              }
            },
            children: [
              _WatchPlaylistsPane(
                store: store,
                compact: true,
                fullscreen: true,
                mode: _WatchBrowseMode.playlistsOnly,
                onPlaylistSelected: () =>
                    _goToCompactWatchPage(_watchViewGroups),
              ),
              _WatchPlaylistsPane(
                store: store,
                compact: true,
                fullscreen: true,
                mode: _WatchBrowseMode.groupsOnly,
                onGroupSelected: () =>
                    _goToCompactWatchPage(_watchViewChannels),
              ),
              _ChannelsPane(
                store: store,
                compact: true,
                fullscreen: true,
                onChannelSelected: () =>
                    _goToCompactWatchPage(_watchViewPlayer),
              ),
              _PlayerPane(store: store),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCompactFavoritesSection(PlaylistStore store) {
    final isSmallCompact =
        MediaQuery.sizeOf(context).width < _compactBreakpoint;

    return Column(
      children: [
        SizedBox(
          width: isSmallCompact ? double.infinity : null,
          child: isSmallCompact
              ? _buildCompactTabStrip(
                  selectedIndex: _compactFavoritesView,
                  icons: const [
                    Icons.folder_open,
                    Icons.tv,
                    Icons.smart_display,
                  ],
                  labels: const ['Groups', 'Channels', 'Player'],
                  onSelected: (index) async {
                    setState(() => _compactFavoritesView = index);
                    if (_compactFavoritesController.hasClients) {
                      await _compactFavoritesController.animateToPage(
                        index,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                )
              : SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<int>(
                      value: 0,
                      icon: Icon(Icons.star),
                      label: Text('Favorites'),
                    ),
                    ButtonSegment<int>(
                      value: 1,
                      icon: Icon(Icons.smart_display),
                      label: Text('Player'),
                    ),
                  ],
                  selected: {_compactFavoritesView},
                  onSelectionChanged: (next) async {
                    final page = next.first;
                    setState(() => _compactFavoritesView = page);
                    if (_compactFavoritesController.hasClients) {
                      await _compactFavoritesController.animateToPage(
                        page,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: PageView(
            controller: _compactFavoritesController,
            onPageChanged: (index) {
              if (_compactFavoritesView != index) {
                setState(() => _compactFavoritesView = index);
              }
            },
            children: [
              if (isSmallCompact) ...[
                _FavoriteGroupsList(
                  store: store,
                  onGroupTap: _openFavoriteGroup,
                ),
                _FavoriteChannelsList(
                  store: store,
                  onChannelTap: _openFavoriteChannel,
                ),
                _PlayerPane(store: store),
              ] else ...[
                _FavoritesView(
                  store: store,
                  onGroupTap: _openFavoriteGroup,
                  onChannelTap: _openFavoriteChannel,
                  compact: true,
                  withPlayer: false,
                ),
                _PlayerPane(store: store),
              ],
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PlaylistStore>();
    final isCompact = MediaQuery.sizeOf(context).width < _compactBreakpoint;
    final isSmallCompact = isCompact;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    BottomNavigationBarItem buildBottomNavItem({
      required IconData icon,
      required IconData activeIcon,
      required String label,
    }) {
      return BottomNavigationBarItem(
        icon: Icon(icon),
        activeIcon: isSmallCompact
            ? _CompactBottomNavActiveIcon(icon: activeIcon)
            : Icon(activeIcon),
        label: label,
      );
    }

    Widget bodyContent = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          if (!isCompact) ...[
            _GlobalSearchBar(
              searchCtrl: _searchCtrl,
              store: store,
              onChanged: _handleGlobalSearchInput,
              onTap: _showSearchDialog,
            ),
            const SizedBox(height: 10),
          ],
          Expanded(
            child: isCompact
                ? _buildSection(context, store)
                : Row(
                    children: [
                      _LeftMenu(
                        section: _section,
                        onChanged: _handleSectionChange,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: _buildSection(context, store)),
                    ],
                  ),
          ),
        ],
      ),
    );

    if (isSmallCompact) {
      final base = Theme.of(context);
      bodyContent = Theme(
        data: base.copyWith(
          textTheme: base.textTheme.apply(fontSizeFactor: 1.08),
          listTileTheme: base.listTileTheme.copyWith(
            minTileHeight: 56,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
          ),
          iconButtonTheme: IconButtonThemeData(
            style: IconButton.styleFrom(
              minimumSize: const Size(44, 44),
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
          ),
        ),
        child: bodyContent,
      );
    }

    return Scaffold(
      appBar: isCompact
          ? AppBar(
              title: isSmallCompact
                  ? _GlobalSearchBar(
                      searchCtrl: _searchCtrl,
                      store: store,
                      onChanged: _handleGlobalSearchInput,
                      onTap: _showSearchDialog,
                      inAppBar: true,
                    )
                  : null,
              actions: [
                if (!isSmallCompact)
                  IconButton(
                    tooltip: 'Search',
                    onPressed: () {
                      if (_searchDialogOpen || _searchDialogPending) {
                        return;
                      }
                      _showSearchDialog();
                    },
                    icon: const Icon(Icons.search),
                  ),
              ],
            )
          : null,
      body: bodyContent,
      bottomNavigationBar: isCompact
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 150),
                  alignment: Alignment.topCenter,
                  child: store.nowPlaying != null
                      ? _CompactMiniPlayerBar(
                          channel: store.nowPlaying!,
                          iosCompact: isSmallCompact,
                          onTap: () => _openCompactPlayer(store),
                          onStop: store.stopPlayback,
                        )
                      : const SizedBox.shrink(),
                ),
                MediaQuery.removeViewPadding(
                  context: context,
                  removeBottom: true,
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: isSmallCompact ? bottomInset * 0.5 : 0,
                    ),
                    child: BottomNavigationBar(
                      currentIndex: _HomeSection.values.indexOf(_section),
                      onTap: (index) {
                        if (isSmallCompact && index == 3) {
                          context.read<AuthStore>().logout();
                          return;
                        }
                        _handleSectionChange(_HomeSection.values[index]);
                      },
                      type: BottomNavigationBarType.fixed,
                      showSelectedLabels: !isSmallCompact,
                      showUnselectedLabels: !isSmallCompact,
                      items: [
                        buildBottomNavItem(
                          icon: Icons.ondemand_video_outlined,
                          activeIcon: Icons.ondemand_video,
                          label: 'Watch',
                        ),
                        buildBottomNavItem(
                          icon: Icons.star_border,
                          activeIcon: Icons.star,
                          label: 'Favorites',
                        ),
                        buildBottomNavItem(
                          icon: Icons.playlist_play_outlined,
                          activeIcon: Icons.playlist_play,
                          label: 'Playlists',
                        ),
                        if (isSmallCompact)
                          buildBottomNavItem(
                            icon: Icons.logout,
                            activeIcon: Icons.logout,
                            label: 'Logout',
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          : null,
    );
  }

  Widget _buildSection(BuildContext context, PlaylistStore store) {
    final isCompact = MediaQuery.sizeOf(context).width < _compactBreakpoint;

    switch (_section) {
      case _HomeSection.watch:
        if (isCompact) {
          return _buildCompactWatchSection(store);
        }
        return Row(
          children: [
            _WatchPlaylistsPane(store: store),
            const SizedBox(width: 10),
            _ChannelsPane(store: store),
            const SizedBox(width: 10),
            Expanded(child: _PlayerPane(store: store)),
          ],
        );
      case _HomeSection.favorites:
        if (isCompact) {
          return _buildCompactFavoritesSection(store);
        }
        return _FavoritesView(
          store: store,
          onGroupTap: _openFavoriteGroup,
          onChannelTap: _openFavoriteChannel,
        );
      case _HomeSection.playlists:
        return _PlaylistManagementView(
          store: store,
          onCreate: () => _showPlaylistDialog(context),
          onEdit: (p) => _showPlaylistDialog(context, editing: p),
          onRefresh: _refreshPlaylistWithFeedback,
          onDelete: (p) => _confirmDeletePlaylist(context, p),
        );
    }
  }
}

class _GlobalSearchBar extends StatelessWidget {
  final TextEditingController searchCtrl;
  final PlaylistStore store;
  final ValueChanged<String> onChanged;
  final VoidCallback onTap;
  final bool inAppBar;

  const _GlobalSearchBar({
    required this.searchCtrl,
    required this.store,
    required this.onChanged,
    required this.onTap,
    this.inAppBar = false,
  });

  @override
  Widget build(BuildContext context) {
    if (inAppBar) {
      final colorScheme = Theme.of(context).colorScheme;
      return TextField(
        controller: searchCtrl,
        autofocus: false,
        readOnly: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search channels, groups',
          prefixIcon: const Icon(Icons.search, size: 20),
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          isDense: true,
        ),
        onTap: onTap,
      );
    }
    return TextField(
      controller: searchCtrl,
      readOnly: true,
      decoration: InputDecoration(
        labelText: 'Search channels, groups',
        prefixIcon: const Icon(Icons.search),
      ),
      onTap: onTap,
    );
  }
}

class _CompactBottomNavActiveIcon extends StatelessWidget {
  final IconData icon;

  const _CompactBottomNavActiveIcon({required this.icon});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.35)),
      ),
      child: Icon(icon, color: colorScheme.primary),
    );
  }
}

class _SearchChannelResultTile extends StatelessWidget {
  final Channel channel;
  final String playlistName;
  final VoidCallback onTap;

  const _SearchChannelResultTile({
    required Key key,
    required this.channel,
    required this.playlistName,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: _ChannelLogoAvatar(
        logoUrl: channel.logoUrl,
        radius: 14,
        iconSize: 16,
      ),
      title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Chip(
              label: Text(playlistName, style: const TextStyle(fontSize: 11)),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            Chip(
              label: Text(
                channel.groupName,
                style: const TextStyle(fontSize: 11),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
      onTap: onTap,
    );
  }
}

class _ChannelLogoAvatar extends StatelessWidget {
  final String logoUrl;
  final double radius;
  final double iconSize;

  const _ChannelLogoAvatar({
    required this.logoUrl,
    this.radius = 20,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      radius: radius,
      child: Icon(Icons.tv, size: iconSize),
    );

    if (logoUrl.isEmpty) {
      return fallback;
    }

    return ClipOval(
      child: SizedBox(
        width: radius * 2,
        height: radius * 2,
        child: Image.network(
          logoUrl,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => fallback,
        ),
      ),
    );
  }
}

class _LeftMenu extends StatelessWidget {
  final _HomeSection section;
  final ValueChanged<_HomeSection> onChanged;

  const _LeftMenu({required this.section, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Expanded(
                child: NavigationRail(
                  selectedIndex: _HomeSection.values.indexOf(section),
                  onDestinationSelected: (index) =>
                      onChanged(_HomeSection.values[index]),
                  labelType: NavigationRailLabelType.none,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.ondemand_video_outlined),
                      selectedIcon: Icon(Icons.ondemand_video),
                      label: Text('Watch'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.star_border),
                      selectedIcon: Icon(Icons.star),
                      label: Text('Favorites'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.playlist_play_outlined),
                      selectedIcon: Icon(Icons.playlist_play),
                      label: Text('Playlists'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                button: true,
                label: 'Logout',
                child: InkResponse(
                  onTap: () => context.read<AuthStore>().logout(),
                  radius: 24,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.logout),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WatchPlaylistsPane extends StatefulWidget {
  final PlaylistStore store;
  final bool compact;
  final bool fullscreen;
  final _WatchBrowseMode mode;
  final Future<void> Function()? onPlaylistSelected;
  final Future<void> Function()? onGroupSelected;

  const _WatchPlaylistsPane({
    required this.store,
    this.compact = false,
    this.fullscreen = false,
    this.mode = _WatchBrowseMode.both,
    this.onPlaylistSelected,
    this.onGroupSelected,
  });

  @override
  State<_WatchPlaylistsPane> createState() => _WatchPlaylistsPaneState();
}

class _WatchPlaylistsPaneState extends State<_WatchPlaylistsPane> {
  final ScrollController _groupsScrollController = ScrollController();
  static const double _groupRowExtent = 56;
  static const double _groupTopInset = 10;
  String? _lastSelectedGroup;
  int _lastGroupCount = -1;
  String _lastSearchQuery = '';

  @override
  void dispose() {
    _groupsScrollController.dispose();
    super.dispose();
  }

  void _scrollToSelectedGroup(
    String? selectedGroup,
    List<Group> visibleGroups,
  ) {
    if (!mounted || !_groupsScrollController.hasClients) return;

    int targetIndex = 0; // All channels row
    if (selectedGroup != null) {
      final groupIndex = visibleGroups.indexWhere(
        (g) => g.name == selectedGroup,
      );
      if (groupIndex < 0) return;
      targetIndex = groupIndex + 1;
    }

    final targetOffset = ((targetIndex * _groupRowExtent) - _groupTopInset)
        .clamp(0, _groupsScrollController.position.maxScrollExtent)
        .toDouble();

    _groupsScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final playlists = store.playlists;
    final groups = store.filteredGroups;
    final showPlaylists = widget.mode != _WatchBrowseMode.groupsOnly;
    final showGroups = widget.mode != _WatchBrowseMode.playlistsOnly;

    final shouldRefocus =
        _lastSelectedGroup != store.selectedGroup ||
        _lastGroupCount != groups.length ||
        _lastSearchQuery != store.searchQuery;

    if (shouldRefocus) {
      _lastSelectedGroup = store.selectedGroup;
      _lastGroupCount = groups.length;
      _lastSearchQuery = store.searchQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToSelectedGroup(store.selectedGroup, groups);
        Future<void>.delayed(const Duration(milliseconds: 80), () {
          if (!mounted) return;
          _scrollToSelectedGroup(store.selectedGroup, groups);
        });
      });
    }

    return SizedBox(
      width: widget.compact ? null : 280,
      child: Card(
        child: Column(
          mainAxisSize: widget.compact && !widget.fullscreen
              ? MainAxisSize.min
              : MainAxisSize.max,
          children: [
            if (showPlaylists) ...[
              const ListTile(title: Text('Playlists'), dense: true),
              if (!widget.compact || widget.fullscreen)
                Expanded(
                  flex: showGroups ? 2 : 1,
                  child: ListView(
                    children: [
                      for (final p in playlists)
                        ListTile(
                          title: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(p.type.toUpperCase()),
                          selected: p.id == store.selectedPlaylistId,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          onTap: () async {
                            await store.selectPlaylist(p.id);
                            await widget.onPlaylistSelected?.call();
                          },
                        ),
                    ],
                  ),
                )
              else
                SizedBox(
                  height: 220,
                  child: ListView(
                    shrinkWrap: widget.compact,
                    children: [
                      for (final p in playlists)
                        ListTile(
                          title: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(p.type.toUpperCase()),
                          selected: p.id == store.selectedPlaylistId,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          onTap: () async {
                            await store.selectPlaylist(p.id);
                            await widget.onPlaylistSelected?.call();
                          },
                        ),
                    ],
                  ),
                ),
            ],
            if (showPlaylists && showGroups) const Divider(height: 1),
            if (showGroups) ...[
              const ListTile(title: Text('Groups'), dense: true),
              if (!widget.compact || widget.fullscreen)
                Expanded(
                  flex: showPlaylists ? 3 : 1,
                  child: store.loadingGroups
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          controller: _groupsScrollController,
                          itemExtent: _groupRowExtent,
                          itemCount: groups.length + 1,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return ListTile(
                                title: const Text('All channels'),
                                selected: store.selectedGroup == null,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                onTap: () async {
                                  await store.selectGroup(null);
                                  await widget.onGroupSelected?.call();
                                },
                              );
                            }

                            final g = groups[index - 1];
                            final isFavorite = store.isGroupFavorite(
                              g.playlistId,
                              g.name,
                            );
                            return ListTile(
                              title: Text(
                                g.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('${g.channelCount}'),
                                  IconButton(
                                    onPressed: () async {
                                      try {
                                        await store.toggleFavoriteGroup(
                                          g.copyWith(isFavorite: isFavorite),
                                        );
                                      } on ApiException catch (e) {
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(content: Text(e.message)),
                                        );
                                      }
                                    },
                                    icon: Icon(
                                      isFavorite
                                          ? Icons.star
                                          : Icons.star_border,
                                      color: isFavorite ? Colors.amber : null,
                                    ),
                                  ),
                                ],
                              ),
                              selected: store.selectedGroup == g.name,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              onTap: () async {
                                await store.selectGroup(g.name);
                                await widget.onGroupSelected?.call();
                              },
                            );
                          },
                        ),
                )
              else
                SizedBox(
                  height: 320,
                  child: store.loadingGroups
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          shrinkWrap: widget.compact,
                          controller: _groupsScrollController,
                          itemExtent: _groupRowExtent,
                          itemCount: groups.length + 1,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return ListTile(
                                title: const Text('All channels'),
                                selected: store.selectedGroup == null,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                onTap: () async {
                                  await store.selectGroup(null);
                                  await widget.onGroupSelected?.call();
                                },
                              );
                            }

                            final g = groups[index - 1];
                            final isFavorite = store.isGroupFavorite(
                              g.playlistId,
                              g.name,
                            );
                            return ListTile(
                              title: Text(
                                g.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('${g.channelCount}'),
                                  IconButton(
                                    onPressed: () async {
                                      try {
                                        await store.toggleFavoriteGroup(
                                          g.copyWith(isFavorite: isFavorite),
                                        );
                                      } on ApiException catch (e) {
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(content: Text(e.message)),
                                        );
                                      }
                                    },
                                    icon: Icon(
                                      isFavorite
                                          ? Icons.star
                                          : Icons.star_border,
                                      color: isFavorite ? Colors.amber : null,
                                    ),
                                  ),
                                ],
                              ),
                              selected: store.selectedGroup == g.name,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              onTap: () async {
                                await store.selectGroup(g.name);
                                await widget.onGroupSelected?.call();
                              },
                            );
                          },
                        ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _WatchBrowseMode { both, playlistsOnly, groupsOnly }

class _ChannelsPane extends StatelessWidget {
  final PlaylistStore store;
  final bool compact;
  final bool fullscreen;
  final Future<void> Function()? onChannelSelected;

  const _ChannelsPane({
    required this.store,
    this.compact = false,
    this.fullscreen = false,
    this.onChannelSelected,
  });

  @override
  Widget build(BuildContext context) {
    final channels = store.channels;

    return SizedBox(
      width: compact ? null : 360,
      child: Card(
        child: Column(
          mainAxisSize: compact && !fullscreen
              ? MainAxisSize.min
              : MainAxisSize.max,
          children: [
            ListTile(
              title: const Text('Channels'),
              dense: true,
              trailing: IconButton(
                icon: Icon(
                  store.channelSortOrder == ChannelSortOrder.byName
                      ? Icons.sort_by_alpha
                      : Icons.sort,
                ),
                tooltip: store.channelSortOrder == ChannelSortOrder.byName
                    ? 'Sort by name (tap to sort by index)'
                    : 'Sort by index (tap to sort by name)',
                onPressed: () => store.toggleChannelSortOrder(),
              ),
            ),
            if (!compact || fullscreen)
              Expanded(
                child: store.loadingChannels
                    ? const Center(child: CircularProgressIndicator())
                    : channels.isEmpty
                    ? const Center(child: Text('No channels found'))
                    : ListView.builder(
                        itemCount: channels.length,
                        itemBuilder: (context, i) {
                          final c = channels[i];
                          final selected = store.nowPlaying?.id == c.id;
                          return ListTile(
                            selected: selected,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            leading: _ChannelLogoAvatar(logoUrl: c.logoUrl),
                            title: Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              c.groupName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              onPressed: () async {
                                try {
                                  await store.toggleFavorite(c);
                                } on ApiException catch (e) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(e.message)),
                                  );
                                }
                              },
                              icon: Icon(
                                c.isFavorite ? Icons.star : Icons.star_border,
                                color: c.isFavorite ? Colors.amber : null,
                              ),
                            ),
                            onTap: () async {
                              await store.play(c);
                              await onChannelSelected?.call();
                            },
                          );
                        },
                      ),
              )
            else
              SizedBox(
                height: 360,
                child: store.loadingChannels
                    ? const Center(child: CircularProgressIndicator())
                    : channels.isEmpty
                    ? const Center(child: Text('No channels found'))
                    : ListView.builder(
                        shrinkWrap: compact,
                        itemCount: channels.length,
                        itemBuilder: (context, i) {
                          final c = channels[i];
                          final selected = store.nowPlaying?.id == c.id;
                          return ListTile(
                            selected: selected,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            leading: _ChannelLogoAvatar(logoUrl: c.logoUrl),
                            title: Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              c.groupName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              onPressed: () async {
                                try {
                                  await store.toggleFavorite(c);
                                } on ApiException catch (e) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(e.message)),
                                  );
                                }
                              },
                              icon: Icon(
                                c.isFavorite ? Icons.star : Icons.star_border,
                                color: c.isFavorite ? Colors.amber : null,
                              ),
                            ),
                            onTap: () async {
                              await store.play(c);
                              await onChannelSelected?.call();
                            },
                          );
                        },
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FavoritesView extends StatelessWidget {
  final PlaylistStore store;
  final _GroupTapCallback onGroupTap;
  final _ChannelTapCallback onChannelTap;
  final bool compact;
  final bool withPlayer;

  const _FavoritesView({
    required this.store,
    required this.onGroupTap,
    required this.onChannelTap,
    this.compact = false,
    this.withPlayer = true,
  });

  @override
  Widget build(BuildContext context) {
    final compactFullscreen = compact && !withPlayer;

    String playlistNameFor(int playlistId) {
      for (final p in store.playlists) {
        if (p.id == playlistId) return p.name;
      }
      return 'Playlist $playlistId';
    }

    final favoriteLists = Column(
      children: [
        const ListTile(
          dense: true,
          leading: Icon(Icons.folder_open),
          title: Text('Favorite Groups'),
        ),
        Expanded(
          child: store.loadingFavoriteGroups
              ? const Center(child: CircularProgressIndicator())
              : store.favoriteGroups.isEmpty
              ? const Center(child: Text('No favorite groups yet'))
              : ListView.builder(
                  itemCount: store.favoriteGroups.length,
                  itemBuilder: (context, i) {
                    final g = store.favoriteGroups[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        g.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${playlistNameFor(g.playlistId)} • ${g.channelCount} channels',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        onPressed: () async {
                          try {
                            await store.toggleFavoriteGroup(g);
                          } on ApiException catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(e.message)));
                          }
                        },
                        icon: const Icon(Icons.star, color: Colors.amber),
                      ),
                      onTap: () async {
                        await onGroupTap(g);
                      },
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        const ListTile(
          dense: true,
          leading: Icon(Icons.tv),
          title: Text('Favorite Channels'),
        ),
        Expanded(
          child: store.loadingFavoriteChannels
              ? const Center(child: CircularProgressIndicator())
              : store.favoriteChannels.isEmpty
              ? const Center(child: Text('No favorite channels yet'))
              : ListView.builder(
                  itemCount: store.favoriteChannels.length,
                  itemBuilder: (context, i) {
                    final c = store.favoriteChannels[i];
                    final selected = store.nowPlaying?.id == c.id;
                    return ListTile(
                      selected: selected,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      leading: _ChannelLogoAvatar(logoUrl: c.logoUrl),
                      title: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        c.groupName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        onPressed: () async {
                          try {
                            await store.toggleFavorite(c);
                          } on ApiException catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(e.message)));
                          }
                        },
                        icon: const Icon(Icons.star, color: Colors.amber),
                      ),
                      onTap: () => onChannelTap(c),
                    );
                  },
                ),
        ),
      ],
    );

    final favoritesCard = Card(
      child: Column(
        mainAxisSize: compactFullscreen
            ? MainAxisSize.max
            : (compact ? MainAxisSize.min : MainAxisSize.max),
        children: [
          ListTile(
            title: const Text('Favorites'),
            subtitle: const Text('Channels and groups'),
            trailing: IconButton(
              onPressed: () {
                store.fetchFavoriteGroups();
                store.fetchFavoriteChannels();
              },
              icon: const Icon(Icons.refresh),
            ),
          ),
          if (!compact || compactFullscreen)
            Expanded(child: favoriteLists)
          else
            SizedBox(height: 520, child: favoriteLists),
        ],
      ),
    );

    if (compact) {
      if (!withPlayer) {
        return favoritesCard;
      }
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          favoritesCard,
          const SizedBox(height: 10),
          SizedBox(height: 420, child: _PlayerPane(store: store)),
        ],
      );
    }

    return Row(
      children: [
        SizedBox(width: 480, child: favoritesCard),
        const SizedBox(width: 10),
        Expanded(child: _PlayerPane(store: store)),
      ],
    );
  }
}

class _FavoriteGroupsList extends StatelessWidget {
  final PlaylistStore store;
  final _GroupTapCallback onGroupTap;

  const _FavoriteGroupsList({required this.store, required this.onGroupTap});

  @override
  Widget build(BuildContext context) {
    String playlistNameFor(int playlistId) {
      for (final p in store.playlists) {
        if (p.id == playlistId) return p.name;
      }
      return 'Playlist $playlistId';
    }

    return Card(
      child: Column(
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_open),
            title: const Text('Favorite Groups'),
            trailing: IconButton(
              onPressed: store.fetchFavoriteGroups,
              icon: const Icon(Icons.refresh),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: store.loadingFavoriteGroups
                ? const Center(child: CircularProgressIndicator())
                : store.favoriteGroups.isEmpty
                ? const Center(child: Text('No favorite groups yet'))
                : ListView.builder(
                    itemCount: store.favoriteGroups.length,
                    itemBuilder: (context, i) {
                      final g = store.favoriteGroups[i];
                      return ListTile(
                        dense: true,
                        title: Text(
                          g.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${playlistNameFor(g.playlistId)} • ${g.channelCount} channels',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          onPressed: () async {
                            try {
                              await store.toggleFavoriteGroup(g);
                            } on ApiException catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.message)),
                              );
                            }
                          },
                          icon: const Icon(Icons.star, color: Colors.amber),
                        ),
                        onTap: () async {
                          await onGroupTap(g);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _FavoriteChannelsList extends StatelessWidget {
  final PlaylistStore store;
  final _ChannelTapCallback onChannelTap;

  const _FavoriteChannelsList({
    required this.store,
    required this.onChannelTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.tv),
            title: const Text('Favorite Channels'),
            trailing: IconButton(
              onPressed: store.fetchFavoriteChannels,
              icon: const Icon(Icons.refresh),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: store.loadingFavoriteChannels
                ? const Center(child: CircularProgressIndicator())
                : store.favoriteChannels.isEmpty
                ? const Center(child: Text('No favorite channels yet'))
                : ListView.builder(
                    itemCount: store.favoriteChannels.length,
                    itemBuilder: (context, i) {
                      final c = store.favoriteChannels[i];
                      final selected = store.nowPlaying?.id == c.id;
                      return ListTile(
                        selected: selected,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        leading: _ChannelLogoAvatar(logoUrl: c.logoUrl),
                        title: Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          c.groupName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          onPressed: () async {
                            try {
                              await store.toggleFavorite(c);
                            } on ApiException catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.message)),
                              );
                            }
                          },
                          icon: const Icon(Icons.star, color: Colors.amber),
                        ),
                        onTap: () => onChannelTap(c),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CompactMiniPlayerBar extends StatelessWidget {
  final Channel channel;
  final bool iosCompact;
  final VoidCallback onTap;
  final VoidCallback onStop;

  const _CompactMiniPlayerBar({
    required this.channel,
    required this.iosCompact,
    required this.onTap,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: iosCompact ? 58 : 62,
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onTap,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      _ChannelLogoAvatar(
                        logoUrl: channel.logoUrl,
                        radius: 16,
                        iconSize: 16,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              channel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              channel.groupName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.expand_less),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Stop playback',
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistManagementView extends StatelessWidget {
  final PlaylistStore store;
  final VoidCallback onCreate;
  final ValueChanged<Playlist> onEdit;
  final Future<void> Function(Playlist) onRefresh;
  final ValueChanged<Playlist> onDelete;

  const _PlaylistManagementView({
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

class _PlayerPane extends StatelessWidget {
  final PlaylistStore store;

  const _PlayerPane({required this.store});

  String _fmtTime(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final Channel? channel = store.nowPlaying;
    final isCompactLayout = MediaQuery.sizeOf(context).width < 900;

    if (channel == null) {
      return const Card(
        child: Center(child: Text('Select a channel to start playback')),
      );
    }

    final headerContent = [
      ChannelPlayer(streamUrl: channel.streamUrl),
      const SizedBox(height: 12),
      Text(
        channel.name,
        style: Theme.of(context).textTheme.titleLarge,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      Text(channel.groupName, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      const Text('EPG', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
    ];

    if (isCompactLayout) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            children: [
              ...headerContent,
              if (store.loadingEpg)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (store.epgEntries.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No EPG data available'),
                )
              else
                ...store.epgEntries.map(
                  (entry) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(entry.title),
                      subtitle: Text(entry.description),
                      trailing: Text(
                        '${_fmtTime(entry.startTime)} - ${_fmtTime(entry.endTime)}',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...headerContent,
            Expanded(
              child: store.loadingEpg
                  ? const Center(child: CircularProgressIndicator())
                  : store.epgEntries.isEmpty
                  ? const Text('No EPG data available')
                  : ListView.builder(
                      itemCount: store.epgEntries.length,
                      itemBuilder: (context, i) {
                        final e = store.epgEntries[i];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(e.title),
                            subtitle: Text(e.description),
                            trailing: Text(
                              '${_fmtTime(e.startTime)} - ${_fmtTime(e.endTime)}',
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
