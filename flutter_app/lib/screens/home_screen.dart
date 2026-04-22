import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/ui_constants.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/auth_store.dart';
import '../services/playlist_store.dart';
import 'home/dialogs/playlist_dialog.dart';
import 'home/home_types.dart';
import 'home/widgets/channels_pane.dart';
import 'home/widgets/compact_bottom_nav_icon.dart';
import 'home/widgets/compact_favorites_section.dart';
import 'home/widgets/compact_mini_player_bar.dart';
import 'home/widgets/compact_watch_section.dart';
import 'home/widgets/favorites_view.dart';
import 'home/widgets/home_left_menu.dart';
import 'home/widgets/home_search_bar.dart';
import 'home/widgets/player_pane.dart';
import 'home/widgets/playlist_management_view.dart';
import 'home/widgets/search_result_tile.dart';
import 'home/widgets/watch_playlists_pane.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchCtrl = TextEditingController();
  HomeSection _section = HomeSection.watch;
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
        MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    final favoritesPlayerPage = isSmallCompact ? 2 : 1;

    if (_section == HomeSection.favorites) {
      setState(() => _compactFavoritesView = favoritesPlayerPage);
      if (_compactFavoritesController.hasClients) {
        await _compactFavoritesController.animateToPage(
          favoritesPlayerPage,
          duration: kTabAnimation,
          curve: Curves.easeOut,
        );
      }
      return;
    }

    if (_section != HomeSection.watch) {
      setState(() {
        _section = HomeSection.watch;
        _compactWatchView = CompactWatchSection.viewPlayer;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_compactWatchController.hasClients) return;
        _compactWatchController.animateToPage(
          CompactWatchSection.viewPlayer,
          duration: kTabAnimation,
          curve: Curves.easeOut,
        );
      });
      return;
    }

    setState(() => _compactWatchView = CompactWatchSection.viewPlayer);
    if (_compactWatchController.hasClients) {
      await _compactWatchController.animateToPage(
        CompactWatchSection.viewPlayer,
        duration: kTabAnimation,
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
        duration: kTabAnimation,
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
        setState(() => _section = HomeSection.watch);
        if (item.type == SearchResultType.group) {
          final isSmallCompact =
              MediaQuery.sizeOf(context).width < kCompactBreakpoint;
          if (isSmallCompact) {
            await _goToCompactWatchPage(CompactWatchSection.viewChannels);
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
        MediaQuery.sizeOf(context).width < kCompactBreakpoint;

    if (_section != HomeSection.watch) {
      setState(() => _section = HomeSection.watch);
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
        if (_compactWatchView != CompactWatchSection.viewChannels) {
          setState(() => _compactWatchView = CompactWatchSection.viewChannels);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_compactWatchController.hasClients) return;
          _compactWatchController.animateToPage(
            CompactWatchSection.viewChannels,
            duration: kTabAnimation,
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

      final isCompact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
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
                                    subtitle: Text('${g.channelCount} channels'),
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
                                  SearchChannelResultTile(
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

  void _handleSectionChange(HomeSection next) {
    setState(() {
      _section = next;
      if (next == HomeSection.favorites) {
        _compactFavoritesView = 0;
      }
    });
    if (next == HomeSection.watch) {
      context.read<PlaylistStore>().fetchFavoriteGroups();
    }
    if (next == HomeSection.favorites) {
      final store = context.read<PlaylistStore>();
      store.fetchFavoriteChannels();
      store.fetchFavoriteGroups();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_compactFavoritesController.hasClients) return;
        _compactFavoritesController.jumpToPage(0);
      });
    }
  }

  Widget _buildSection(BuildContext context, PlaylistStore store) {
    final isCompact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;

    switch (_section) {
      case HomeSection.watch:
        if (isCompact) {
          return CompactWatchSection(
            store: store,
            controller: _compactWatchController,
            currentPage: _compactWatchView,
            onGoToPage: _goToCompactWatchPage,
            onPageChanged: (index) {
              if (_compactWatchView != index) {
                setState(() => _compactWatchView = index);
              }
            },
          );
        }
        return Row(
          children: [
            WatchPlaylistsPane(store: store),
            const SizedBox(width: 10),
            ChannelsPane(store: store),
            const SizedBox(width: 10),
            Expanded(child: PlayerPane(store: store)),
          ],
        );
      case HomeSection.favorites:
        if (isCompact) {
          return CompactFavoritesSection(
            store: store,
            controller: _compactFavoritesController,
            currentPage: _compactFavoritesView,
            onGroupTap: _openFavoriteGroup,
            onChannelTap: _openFavoriteChannel,
            onPageChanged: (index) {
              if (_compactFavoritesView != index) {
                setState(() => _compactFavoritesView = index);
              }
            },
            onGoToPage: (page) async {
              setState(() => _compactFavoritesView = page);
              if (_compactFavoritesController.hasClients) {
                await _compactFavoritesController.animateToPage(
                  page,
                  duration: kTabAnimation,
                  curve: Curves.easeOut,
                );
              }
            },
          );
        }
        return FavoritesView(
          store: store,
          onGroupTap: _openFavoriteGroup,
          onChannelTap: _openFavoriteChannel,
        );
      case HomeSection.playlists:
        return PlaylistManagementView(
          store: store,
          onCreate: () => showPlaylistDialog(context),
          onEdit: (p) => showPlaylistDialog(context, editing: p),
          onRefresh: _refreshPlaylistWithFeedback,
          onDelete: (p) => _confirmDeletePlaylist(context, p),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PlaylistStore>();
    final isCompact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
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
            ? CompactBottomNavActiveIcon(icon: activeIcon)
            : Icon(activeIcon),
        label: label,
      );
    }

    Widget bodyContent = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          if (!isCompact) ...[
            HomeSearchBar(
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
                      HomeLeftMenu(
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
                  ? HomeSearchBar(
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
                      ? CompactMiniPlayerBar(
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
                      currentIndex: HomeSection.values.indexOf(_section),
                      onTap: (index) {
                        if (isSmallCompact && index == 3) {
                          context.read<AuthStore>().logout();
                          return;
                        }
                        _handleSectionChange(HomeSection.values[index]);
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
}
