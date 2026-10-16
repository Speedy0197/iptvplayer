import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config/device_utils.dart';
import '../config/ui_constants.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/auth_store.dart';
import '../widgets/channel_player.dart';
import '../services/playlist_store.dart';
import 'home/dialogs/confirm_dialog.dart';
import 'home/dialogs/playlist_dialog.dart';
import 'home/home_types.dart';
import 'home/widgets/channels_pane.dart';
import 'home/widgets/browse_controls.dart';
import 'home/widgets/browse_picker.dart';
import 'account_screen.dart';
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
import 'home/tv/tv_home_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _searchCtrl = TextEditingController();
  final _searchFieldFocusNode = FocusNode(debugLabel: 'globalSearchField');
  final _searchBarActiveFocusNode = FocusNode(debugLabel: 'searchBarActive');
  final _firstSearchResultFocusNode = FocusNode(
    debugLabel: 'firstSearchResult',
  );
  late final FocusNode _watchSectionFocusNode;
  late final FocusNode _favoritesSectionFocusNode;
  late final FocusNode _playlistsSectionFocusNode;
  double _lastKeyboardInsetBottom = 0;
  HomeSection _section = HomeSection.watch;
  int _compactWatchView = 0;
  int _compactFavoritesView = 0;
  late final PageController _compactWatchController;
  late final PageController _compactFavoritesController;
  bool _groupsExpanded = true;
  bool _searchDialogOpen = false;
  bool _searchDialogPending = false;
  final _tvHomeKey = GlobalKey<TvHomeViewState>();
  final _playerKey = GlobalKey(debugLabel: 'persistentChannelPlayer');
  int _tvFullscreenRequest = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) {
      _lastKeyboardInsetBottom = views.first.viewInsets.bottom;
    }
    _compactWatchController = PageController(initialPage: _compactWatchView);
    _compactFavoritesController = PageController(
      initialPage: _compactFavoritesView,
    );
    _watchSectionFocusNode = FocusNode(debugLabel: 'watchSection');
    _favoritesSectionFocusNode = FocusNode(debugLabel: 'favoritesSection');
    _playlistsSectionFocusNode = FocusNode(debugLabel: 'playlistsSection');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PlaylistStore>().bootstrap();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _compactWatchController.dispose();
    _compactFavoritesController.dispose();
    _searchCtrl.dispose();
    _searchFieldFocusNode.dispose();
    _searchBarActiveFocusNode.dispose();
    _firstSearchResultFocusNode.dispose();
    _watchSectionFocusNode.dispose();
    _favoritesSectionFocusNode.dispose();
    _playlistsSectionFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _handleMetricsChanged();
  }

  void _handleMetricsChanged() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) {
      return;
    }

    final currentInsetBottom = views.first.viewInsets.bottom;
    final keyboardJustClosed =
        _lastKeyboardInsetBottom > 0 && currentInsetBottom == 0;
    _lastKeyboardInsetBottom = currentInsetBottom;

    if (keyboardJustClosed &&
        _searchDialogOpen &&
        _searchFieldFocusNode.hasFocus) {
      // Keyboard closed: move focus to non-text node so Android doesn't reopen IME
      _searchBarActiveFocusNode.requestFocus();
    }
  }

  Future<void> _openCompactPlayer(PlaylistStore store) async {
    if (!mounted) return;
    setState(() {
      if (_section == HomeSection.favorites) {
        _compactFavoritesView = 1;
      } else {
        _section = HomeSection.watch;
        _compactWatchView = CompactWatchSection.viewPlayer;
      }
    });
  }

  Future<void> _goToCompactWatchPage(int page) async {
    if (mounted) setState(() => _compactWatchView = page);
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

  bool get _usesTvHome => isAndroidTv(context);

  Future<void> _jumpToSearchResult(SearchResultItem item) async {
    if (!mounted) return;

    final store = context.read<PlaylistStore>();
    final isCompact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    final isTv = _usesTvHome;

    try {
      if (_section != HomeSection.watch) {
        setState(() => _section = HomeSection.watch);
      }

      if (item.type == SearchResultType.group) {
        final g = item.group!;
        final groupPlaylistId = g.playlistId > 0
            ? g.playlistId
            : store.selectedPlaylistId;
        if (groupPlaylistId != null) {
          if (store.selectedPlaylistId != groupPlaylistId) {
            await store.selectPlaylist(groupPlaylistId, preservePlayback: true);
          }
          await store.selectGroup(g.name, preservePlayback: true);
        }
      } else {
        final c = item.channel!;
        if (store.selectedPlaylistId != c.playlistId) {
          await store.selectPlaylist(c.playlistId, preservePlayback: true);
        }

        final channelGroup = c.groupName.trim();
        await store.selectGroup(
          channelGroup.isEmpty ? null : channelGroup,
          preservePlayback: true,
        );
        if (!isTv) await store.play(c);
      }

      if (mounted) {
        if (isTv) {
          _tvHomeKey.currentState?.reveal(channel: item.channel);
          if (item.channel != null) await _playTvChannel(item.channel!);
        } else if (isCompact) {
          await _goToCompactWatchPage(
            item.type == SearchResultType.channel
                ? CompactWatchSection.viewPlayer
                : CompactWatchSection.viewChannels,
          );
        }
      }
    } catch (e) {
      // Ignore errors during navigation
    } finally {
      _cleanupSearch();
    }
  }

  Future<void> _openFavoriteGroup(Group group) async {
    if (!mounted) return;

    final store = context.read<PlaylistStore>();
    final isCompact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    final isTv = isAndroidTv(context);

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
        await store.selectPlaylist(targetPlaylistId, preservePlayback: true);
      }
      await store.selectGroup(normalizedGroup.name, preservePlayback: true);

      if (!mounted) return;

      if (isCompact || isTv) {
        await _goToCompactWatchPage(CompactWatchSection.viewChannels);
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

    // Don't await play() before navigating — EPG fetch can take seconds or
    // fail, but nowPlaying is set synchronously so the player is ready.
    store.play(channel);

    if (!mounted) return;

    final isCompact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    final isTv = isAndroidTv(context);
    if (isCompact || isTv) {
      await _openCompactPlayer(store);
    }
  }

  Future<void> _refreshPlaylistWithFeedback(Playlist playlist) async {
    if (!mounted) return;

    final store = context.read<PlaylistStore>();
    if (store.isRefreshingPlaylist(playlist.id)) {
      return;
    }

    await store.refreshPlaylist(playlist.id);
  }

  Future<void> _showSearchDialog() async {
    if (!mounted || _searchDialogOpen) return;
    var initialized = false;
    var searchType = 'all';
    int? searchSource;
    _firstSearchResultFocusNode.unfocus();

    void reopenKeyboard() {
      if (!_searchFieldFocusNode.hasFocus) {
        _searchFieldFocusNode.requestFocus();
      }
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }

    void dismissSearchKeyboard(bool tvMode) {
      if (tvMode) {
        // Keep the TV search bar reachable without reopening its keyboard.
        _searchBarActiveFocusNode.requestFocus();
      } else {
        _searchFieldFocusNode.unfocus();
      }
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }

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
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            final tvMode = isAndroidTv(ctx);
            final showDesktopTooltips = isMacOrWindowsDesktop();
            if (!initialized) {
              initialized = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || !_searchDialogOpen) return;
                _searchFieldFocusNode.requestFocus();
                if (tvMode) {
                  reopenKeyboard();
                }
              });
            }

            void focusFirstSearchResult() {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || !_searchDialogOpen) return;
                if (_firstSearchResultFocusNode.context != null) {
                  _firstSearchResultFocusNode.requestFocus();
                }
              });
            }

            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) {
                if (didPop) return;
                _searchFieldFocusNode.unfocus();
                SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
                if (ctx.mounted) {
                  Navigator.of(ctx).pop();
                }
              },
              child: Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) {
                    return KeyEventResult.ignored;
                  }

                  final key = event.logicalKey;
                  final isBack =
                      key == LogicalKeyboardKey.goBack ||
                      key == LogicalKeyboardKey.escape;
                  final isArrowDown = key == LogicalKeyboardKey.arrowDown;
                  final isArrowUp = key == LogicalKeyboardKey.arrowUp;
                  final isSelect =
                      key == LogicalKeyboardKey.select ||
                      key == LogicalKeyboardKey.gameButtonA;

                  // Back from text field or active search bar
                  final searchAreaHasFocus =
                      _searchFieldFocusNode.hasFocus ||
                      _searchBarActiveFocusNode.hasFocus;
                  if (searchAreaHasFocus && isBack) {
                    _searchFieldFocusNode.unfocus();
                    _searchBarActiveFocusNode.unfocus();
                    SystemChannels.textInput.invokeMethod<void>(
                      'TextInput.hide',
                    );
                    return KeyEventResult.handled;
                  }

                  // OK/Select on non-text search bar node reopens keyboard
                  if (tvMode &&
                      _searchBarActiveFocusNode.hasPrimaryFocus &&
                      isSelect) {
                    _searchFieldFocusNode.requestFocus();
                    SystemChannels.textInput.invokeMethod<void>(
                      'TextInput.show',
                    );
                    return KeyEventResult.handled;
                  }

                  // Down arrow: from text field or active search bar → first result
                  if (tvMode && searchAreaHasFocus && isArrowDown) {
                    _searchFieldFocusNode.unfocus();
                    _searchBarActiveFocusNode.unfocus();
                    SystemChannels.textInput.invokeMethod<void>(
                      'TextInput.hide',
                    );
                    focusFirstSearchResult();
                    return KeyEventResult.handled;
                  }

                  if (tvMode &&
                      _firstSearchResultFocusNode.hasPrimaryFocus &&
                      isArrowUp) {
                    // Return to non-text bar node (not text field) to avoid IME reopen
                    _searchBarActiveFocusNode.requestFocus();
                    return KeyEventResult.handled;
                  }

                  return KeyEventResult.ignored;
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
                          Focus(
                            focusNode: _searchBarActiveFocusNode,
                            child: Row(
                              children: [
                                Expanded(
                                  child:
                                      ValueListenableBuilder<TextEditingValue>(
                                        valueListenable: _searchCtrl,
                                        builder: (context, value, _) {
                                          return TextFormField(
                                            controller: _searchCtrl,
                                            focusNode: _searchFieldFocusNode,
                                            autofocus: true,
                                            textInputAction:
                                                TextInputAction.search,
                                            onTap: tvMode
                                                ? reopenKeyboard
                                                : null,
                                            onEditingComplete: () =>
                                                dismissSearchKeyboard(tvMode),
                                            onFieldSubmitted: (_) =>
                                                dismissSearchKeyboard(tvMode),
                                            onTapOutside: tvMode
                                                ? null
                                                : (_) => dismissSearchKeyboard(
                                                    false,
                                                  ),
                                            decoration: InputDecoration(
                                              labelText:
                                                  'Search channels, groups',
                                              prefixIcon: const Icon(
                                                Icons.search,
                                              ),
                                              suffixIcon:
                                                  !tvMode &&
                                                      value.text.isNotEmpty
                                                  ? IconButton(
                                                      tooltip: 'Clear search',
                                                      onPressed: () {
                                                        _searchCtrl.clear();
                                                        context
                                                            .read<
                                                              PlaylistStore
                                                            >()
                                                            .setSearchQuery('');
                                                      },
                                                      icon: const Icon(
                                                        Icons.clear,
                                                      ),
                                                    )
                                                  : null,
                                            ),
                                            onChanged: (searchValue) {
                                              context
                                                  .read<PlaylistStore>()
                                                  .setSearchQuery(searchValue);
                                            },
                                          );
                                        },
                                      ),
                                ),
                                IconButton(
                                  tooltip: 'Close search',
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    _cleanupSearch();
                                    Navigator.of(ctx).pop();
                                  },
                                ),
                              ],
                            ), // end Row
                          ), // end Focus(searchBarActiveFocusNode)
                          const SizedBox(height: 12),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                ChoiceChip(
                                  label: const Text('All results'),
                                  selected: searchType == 'all',
                                  onSelected: (_) =>
                                      setDialogState(() => searchType = 'all'),
                                ),
                                const SizedBox(width: 8),
                                ChoiceChip(
                                  label: const Text('Channels only'),
                                  selected: searchType == 'channels',
                                  onSelected: (_) => setDialogState(
                                    () => searchType = 'channels',
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ChoiceChip(
                                  label: const Text('Groups only'),
                                  selected: searchType == 'groups',
                                  onSelected: (_) => setDialogState(
                                    () => searchType = 'groups',
                                  ),
                                ),
                                const SizedBox(width: 12),
                                BrowsePicker<int>(
                                  title: 'Search sources',
                                  tooltip: 'Filter search by source',
                                  searchHint: 'Find a source',
                                  value: searchSource ?? -1,
                                  onSelected: (id) => setDialogState(
                                    () => searchSource = id == -1 ? null : id,
                                  ),
                                  choices: [
                                    const BrowseChoice(-1, 'All sources'),
                                    ...context
                                        .read<PlaylistStore>()
                                        .playlists
                                        .map((p) => BrowseChoice(p.id, p.name)),
                                  ],
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Text(
                                      searchSource == null
                                          ? 'All sources'
                                          : context
                                                .read<PlaylistStore>()
                                                .playlists
                                                .firstWhere(
                                                  (p) => p.id == searchSource,
                                                )
                                                .name,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: Consumer<PlaylistStore>(
                              builder: (context, store, _) {
                                final groups = searchType == 'channels'
                                    ? <Group>[]
                                    : store.globalFilteredGroups
                                          .where(
                                            (g) =>
                                                searchSource == null ||
                                                g.playlistId == searchSource,
                                          )
                                          .toList();
                                final channels = searchType == 'groups'
                                    ? <Channel>[]
                                    : store.globalFilteredChannels
                                          .where(
                                            (c) =>
                                                searchSource == null ||
                                                c.playlistId == searchSource,
                                          )
                                          .toList();

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
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                  );
                                  children.add(const SizedBox(height: 6));
                                  var firstResultAssigned = false;
                                  for (final g in groups) {
                                    final isFirstResult =
                                        tvMode && !firstResultAssigned;
                                    if (isFirstResult) {
                                      firstResultAssigned = true;
                                    }

                                    children.add(
                                      ListTile(
                                        focusNode: isFirstResult
                                            ? _firstSearchResultFocusNode
                                            : null,
                                        dense: true,
                                        leading: const Icon(Icons.folder_open),
                                        title: showDesktopTooltips
                                            ? Tooltip(
                                                message: g.name,
                                                child: Text(
                                                  g.name,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              )
                                            : Text(
                                                g.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                        subtitle: Text(
                                          '${store.playlists.where((p) => p.id == g.playlistId).firstOrNull?.name ?? 'Source'} · ${g.channelCount} channels',
                                        ),
                                        onTap: () {
                                          _searchFieldFocusNode.unfocus();
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
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                  );
                                  children.add(const SizedBox(height: 6));
                                  var firstResultAssigned = groups.isNotEmpty;
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
                                    final tile = SearchChannelResultTile(
                                      key: ValueKey(c.id),
                                      channel: c,
                                      playlistName: playlistName,
                                      focusNode: tvMode && !firstResultAssigned
                                          ? _firstSearchResultFocusNode
                                          : null,
                                      onTap: () {
                                        _searchFieldFocusNode.unfocus();
                                        Navigator.of(ctx).pop();
                                        Future.microtask(
                                          () => _jumpToSearchResult(
                                            SearchResultItem.channel(c),
                                          ),
                                        );
                                      },
                                    );

                                    if (tvMode && !firstResultAssigned) {
                                      firstResultAssigned = true;
                                    }

                                    children.add(tile);
                                  }
                                }

                                return ListView(
                                  keyboardDismissBehavior: tvMode
                                      ? ScrollViewKeyboardDismissBehavior.manual
                                      : ScrollViewKeyboardDismissBehavior
                                            .onDrag,
                                  children: children,
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    } finally {
      _searchFieldFocusNode.unfocus();
      FocusManager.instance.primaryFocus?.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      _searchDialogOpen = false;
    }
  }

  Future<void> _confirmDeletePlaylist(BuildContext context, Playlist p) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Delete source'),
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
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _section = next);
    if (next == HomeSection.favorites) {
      context.read<PlaylistStore>().fetchFavoriteChannels();
      context.read<PlaylistStore>().fetchFavoriteGroups();
    }
  }

  Widget _buildSection(BuildContext context, PlaylistStore store) {
    final isCompact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    switch (_section) {
      case HomeSection.watch:
        if (!store.loadingPlaylists && store.playlists.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.live_tv, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Add a source to start watching',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () =>
                        _handleSectionChange(HomeSection.playlists),
                    icon: const Icon(Icons.add),
                    label: const Text('Add source'),
                  ),
                ],
              ),
            ),
          );
        }
        if (isCompact) {
          return CompactWatchSection(
            store: store,
            playerKey: _playerKey,
            controller: _compactWatchController,
            currentPage: _compactWatchView,
            onGoToPage: _goToCompactWatchPage,
            onPageChanged: (index) => setState(() => _compactWatchView = index),
            initialFocusNode: _watchSectionFocusNode,
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final groupWidth = constraints.maxWidth > 1100 ? 200.0 : 170.0;
            final channelWidth = (constraints.maxWidth * .27).clamp(
              230.0,
              300.0,
            );
            return Row(
              children: [
                if (_groupsExpanded)
                  SizedBox(
                    width: groupWidth,
                    child: WatchPlaylistsPane(
                      key: const PageStorageKey('watch-groups'),
                      store: store,
                      mode: WatchBrowseMode.groupsOnly,
                      initialItemFocusNode: _watchSectionFocusNode,
                    ),
                  ),
                if (_groupsExpanded) const SizedBox(width: 8),
                SizedBox(
                  width: channelWidth,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            tooltip: _groupsExpanded
                                ? 'Hide groups'
                                : 'Show groups',
                            onPressed: () => setState(
                              () => _groupsExpanded = !_groupsExpanded,
                            ),
                            icon: const Icon(Icons.view_sidebar_outlined),
                          ),
                          Expanded(child: GroupSelector(store: store)),
                        ],
                      ),
                      Expanded(
                        child: ChannelsPane(
                          key: const PageStorageKey('desktop-watch-channels'),
                          store: store,
                          initialChannelFocusNode: _watchSectionFocusNode,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: PlayerPane(store: store, playerKey: _playerKey),
                ),
              ],
            );
          },
        );
      case HomeSection.favorites:
        if (isCompact) {
          return CompactFavoritesSection(
            store: store,
            playerKey: _playerKey,
            controller: _compactFavoritesController,
            currentPage: _compactFavoritesView,
            onGroupTap: _openFavoriteGroup,
            onChannelTap: _openFavoriteChannel,
            onPageChanged: (index) =>
                setState(() => _compactFavoritesView = index),
            onGoToPage: (page) async =>
                setState(() => _compactFavoritesView = page),
            onBrowse: () => _handleSectionChange(HomeSection.watch),
            initialFocusNode: _favoritesSectionFocusNode,
          );
        }
        return FavoritesView(
          store: store,
          playerKey: _playerKey,
          onGroupTap: _openFavoriteGroup,
          onChannelTap: _openFavoriteChannel,
          initialFocusNode: _favoritesSectionFocusNode,
          onBrowse: () => _handleSectionChange(HomeSection.watch),
        );
      case HomeSection.playlists:
        return PlaylistManagementView(
          store: store,
          onCreate: () => showPlaylistDialog(context),
          onEdit: (p) => showPlaylistDialog(context, editing: p),
          onRefresh: _refreshPlaylistWithFeedback,
          onDelete: (p) => _confirmDeletePlaylist(context, p),
          initialFocusNode: _playlistsSectionFocusNode,
        );
    }
  }

  bool _hasVisiblePlayerPane(PlaylistStore store, bool compact) {
    return switch (_section) {
      HomeSection.watch =>
        (store.loadingPlaylists || store.playlists.isNotEmpty) &&
            (!compact || _compactWatchView == CompactWatchSection.viewPlayer),
      HomeSection.favorites => !compact || _compactFavoritesView == 1,
      HomeSection.playlists => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PlaylistStore>();
    if (_usesTvHome) return _buildTvHome(store);
    final isCompact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    final title = switch (_section) {
      HomeSection.watch => 'Watch',
      HomeSection.favorites => 'Favorites',
      HomeSection.playlists => 'Sources',
    };
    void openAccount() => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AccountScreen()));
    return Scaffold(
      appBar: isCompact
          ? AppBar(
              title: Text(title),
              actions: [
                IconButton(
                  tooltip: 'Search',
                  onPressed: _showSearchDialog,
                  icon: const Icon(Icons.search),
                ),
                IconButton(
                  tooltip: 'Account',
                  onPressed: openAccount,
                  icon: const Icon(Icons.person_outline),
                ),
              ],
            )
          : null,
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: EdgeInsets.all(isCompact ? 8 : 12),
              child: Column(
                children: [
                  if (!isCompact) ...[
                    Row(
                      children: [
                        const Icon(Icons.play_circle_outline, size: 28),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'StreamPilot',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 24),
                        SizedBox(
                          width: 220,
                          child: SourceSelector(store: store),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 280,
                          child: HomeSearchBar(
                            searchCtrl: _searchCtrl,
                            store: store,
                            onChanged: _handleGlobalSearchInput,
                            onTap: _showSearchDialog,
                            inAppBar: true,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Account',
                          onPressed: openAccount,
                          icon: const Icon(Icons.person_outline),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
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
                              const SizedBox(width: 8),
                              Expanded(child: _buildSection(context, store)),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
          if (store.nowPlaying != null &&
              !_hasVisiblePlayerPane(store, isCompact))
            Offstage(
              child: ExcludeFocus(
                child: SizedBox(
                  width: 640,
                  height: 360,
                  child: ChannelPlayer(
                    key: _playerKey,
                    store: store,
                    streamUrl: store.nowPlaying!.streamUrl,
                    resolveStreamUrl: () =>
                        store.resolveChannelStreamUrl(store.nowPlaying!),
                    isActiveRecording: store.isChannelActivelyRecording(
                      store.nowPlaying!,
                    ),
                    previewFocusable: false,
                  ),
                ),
              ),
            ),
        ],
      ),

      bottomNavigationBar: isCompact
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (store.nowPlaying != null)
                  CompactMiniPlayerBar(
                    channel: store.nowPlaying!,
                    iosCompact: true,
                    store: store,
                    onTap: () => _openCompactPlayer(store),
                    onStop: store.stopPlayback,
                  ),
                NavigationBar(
                  selectedIndex: HomeSection.values.indexOf(_section),
                  onDestinationSelected: (index) =>
                      _handleSectionChange(HomeSection.values[index]),
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.ondemand_video_outlined),
                      selectedIcon: Icon(Icons.ondemand_video),
                      label: 'Watch',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.star_border),
                      selectedIcon: Icon(Icons.star),
                      label: 'Favorites',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.dns_outlined),
                      selectedIcon: Icon(Icons.dns),
                      label: 'Sources',
                    ),
                  ],
                ),
              ],
            )
          : null,
    );
  }

  Future<void> _playTvChannel(Channel channel) async {
    final store = context.read<PlaylistStore>();
    if (store.nowPlaying?.id != channel.id ||
        store.nowPlaying?.playlistId != channel.playlistId) {
      // Playback starts when ChannelPlayer receives the stream. EPG must never
      // delay the fullscreen transition, and a failed EPG request is non-fatal.
      unawaited(store.play(channel).catchError((Object _) {}));
    }
    if (mounted) setState(() => _tvFullscreenRequest++);
  }

  Widget _buildTvHome(PlaylistStore store) {
    final playing = store.nowPlaying;
    return TvHomeView(
      key: _tvHomeKey,
      store: store,
      preview: playing == null
          ? const Center(
              child: Text(
                'Select a channel to watch',
                style: TextStyle(color: Colors.white60),
              ),
            )
          : ChannelPlayer(
              key: _playerKey,
              store: store,
              streamUrl: playing.streamUrl,
              resolveStreamUrl: () => store.resolveChannelStreamUrl(playing),
              isActiveRecording: store.isChannelActivelyRecording(playing),
              previewFocusable: false,
              fullscreenRequest: _tvFullscreenRequest,
              onFullscreenClosed: () {
                if (!mounted) return;
                setState(() => _tvFullscreenRequest = 0);
                _tvHomeKey.currentState?.restoreChannelFocus();
              },
              onNextChannel: () => _tvHomeKey.currentState?.playAdjacent(1),
              onPreviousChannel: () =>
                  _tvHomeKey.currentState?.playAdjacent(-1),
            ),
      onWatch: _playTvChannel,
      onSearch: _showSearchDialog,
      onExit: () => SystemNavigator.pop(),
      onManagePlaylists: () => showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: MediaQuery.sizeOf(ctx).width,
            height: MediaQuery.sizeOf(ctx).height * .85,
            child: ListenableBuilder(
              listenable: store,
              builder: (ctx, _) => PlaylistManagementView(
                store: store,
                onCreate: () => showPlaylistDialog(ctx),
                onEdit: (p) => showPlaylistDialog(ctx, editing: p),
                onRefresh: _refreshPlaylistWithFeedback,
                onDelete: (p) => _confirmDeletePlaylist(ctx, p),
              ),
            ),
          ),
        ),
      ),
      onLogout: () async {
        final confirmed = await showConfirmDialog(
          context,
          title: 'Log out',
          message: 'Log out of StreamPilot?',
          confirmLabel: 'Log out',
          confirmIcon: Icons.logout,
        );
        if (confirmed == true && mounted) {
          await context.read<AuthStore>().logout();
        }
      },
    );
  }
}
