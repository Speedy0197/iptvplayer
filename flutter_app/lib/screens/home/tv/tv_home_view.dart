import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../services/playlist_store.dart';
import '../widgets/channel_action_sheet.dart';
import '../widgets/channel_logo_avatar.dart';
import 'tv_programme_panel.dart';
import 'tv_remote_list.dart';

String tvChannelId(Channel channel) => '${channel.playlistId}:${channel.id}';

enum _Zone { groups, channels, programme }

class TvHomeView extends StatefulWidget {
  const TvHomeView({
    super.key,
    required this.store,
    required this.preview,
    required this.onWatch,
    required this.onSearch,
    required this.onManagePlaylists,
    required this.onLogout,
    required this.onExit,
  });

  final PlaylistStore store;
  final Widget preview;
  final Future<void> Function(Channel) onWatch;
  final Future<void> Function() onSearch;
  final Future<void> Function() onManagePlaylists;
  final Future<void> Function() onLogout;
  final VoidCallback onExit;

  @override
  State<TvHomeView> createState() => TvHomeViewState();
}

class TvHomeViewState extends State<TvHomeView> {
  final _groupsFocus = FocusNode(debugLabel: 'tvGroups');
  final _channelsFocus = FocusNode(debugLabel: 'tvChannels');
  final _programmeFocus = FocusNode(debugLabel: 'tvProgramme');
  final _menuFocus = FocusNode(debugLabel: 'tvMainMenu');
  final _channelMemory = <String, String>{};
  _Zone _zone = _Zone.channels;
  bool _menuVisible = false;
  bool _favorites = false;
  String _browseId = 'all';
  String _menuId = 'live';
  Channel? _focusedChannel;
  List<Channel> _playbackQueue = const [];

  String get _memoryKey => _favorites
      ? 'favorites'
      : '${widget.store.selectedPlaylistId}|${widget.store.selectedGroup ?? ''}';
  List<Channel> get _channels =>
      _favorites ? widget.store.favoriteChannels : widget.store.channels;

  void _focusZone(_Zone zone) {
    if (!mounted) return;
    setState(() => _zone = zone);
    switch (zone) {
      case _Zone.groups:
        _groupsFocus.requestFocus();
      case _Zone.channels:
        _channelsFocus.requestFocus();
      case _Zone.programme:
        _programmeFocus.requestFocus();
    }
  }

  void restoreChannelFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
      _focusZone(_Zone.channels);
    });
  }

  /// Search results enter this browser without visiting a mobile pager.
  void reveal({Channel? channel}) {
    setState(() {
      _favorites = false;
      _menuVisible = false;
      _browseId = widget.store.selectedGroup == null
          ? 'all'
          : 'group:${widget.store.selectedGroup}';
      if (channel != null) {
        _channelMemory[_memoryKey] = tvChannelId(channel);
        _focusedChannel = channel;
        _rememberPlaybackQueue(channel);
      }
    });
    restoreChannelFocus();
  }

  Future<void> _watch(Channel channel) async {
    _rememberPlaybackQueue(channel);
    try {
      await widget.onWatch(channel);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open this channel. Please try again.'),
          ),
        );
      }
    }
    if (mounted) restoreChannelFocus();
  }

  void _rememberPlaybackQueue(Channel channel) {
    _playbackQueue = List.of(_channels);
    if (!_playbackQueue.any((c) => tvChannelId(c) == tvChannelId(channel))) {
      _playbackQueue = [channel];
    }
  }

  void playAdjacent(int direction) {
    final playing = widget.store.nowPlaying;
    if (playing == null || _playbackQueue.isEmpty) return;
    final index = _playbackQueue.indexWhere(
      (channel) => tvChannelId(channel) == tvChannelId(playing),
    );
    if (index < 0) return;
    final next = _playbackQueue[(index + direction) % _playbackQueue.length];
    setState(() {
      _channelMemory[_memoryKey] = tvChannelId(next);
      _focusedChannel = next;
    });
    unawaited(widget.onWatch(next));
  }

  void _openMenu() {
    setState(() => _menuVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _menuVisible) _menuFocus.requestFocus();
    });
  }

  void _back() {
    if (_menuVisible) {
      widget.onExit();
    } else if (_zone == _Zone.programme) {
      _focusZone(_Zone.channels);
    } else if (_zone == _Zone.channels) {
      _focusZone(_Zone.groups);
    } else {
      _openMenu();
    }
  }

  Future<void> _browse(_BrowseGroup group, {bool retry = false}) async {
    if (_browseId == group.id && !retry) return;
    setState(() {
      _browseId = group.id;
      _favorites = group.id == 'favorites';
      _focusedChannel = null;
    });
    try {
      if (_favorites) {
        await widget.store.fetchFavoriteChannels();
      } else {
        await widget.store.selectGroup(
          group.group?.name,
          preservePlayback: true,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not load channels. Try selecting the group again.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _channelOptions(Channel channel) async {
    await showChannelActionSheet(
      context,
      channel: channel,
      store: widget.store,
      onPlay: () => _watch(channel),
    );
    if (mounted) restoreChannelFocus();
  }

  Future<void> _choosePlaylist() async {
    final playlists = widget.store.playlists;
    if (playlists.isEmpty) {
      await widget.onManagePlaylists();
      return;
    }
    final focus = FocusNode(debugLabel: 'tvPlaylistChooser');
    final route = DialogRoute<Playlist>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose playlist'),
        content: SizedBox(
          width: 460,
          height: 300,
          child: TvRemoteList<Playlist>(
            focusNode: focus,
            autofocus: true,
            items: playlists,
            memoryKey: 'playlists',
            selectedId: '${widget.store.selectedPlaylistId}',
            itemId: (p) => '${p.id}',
            onFocused: (_) {},
            onActivate: (p) => Navigator.of(ctx).pop(p),
            onLeft: () => Navigator.of(ctx).pop(),
            onRight: () {},
            onBack: () => Navigator.of(ctx).pop(),
            itemBuilder: (_, p, focused) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      ),
    );
    final result = await Navigator.of(context).push(route);
    // The popped future resolves before the exit animation releases Focus.
    await route.completed;
    focus.dispose();
    if (!mounted) return;
    if (result != null && result.id != widget.store.selectedPlaylistId) {
      setState(() {
        _browseId = 'all';
        _favorites = false;
        _focusedChannel = null;
      });
      await widget.store.selectPlaylist(result.id, preservePlayback: true);
    }
    if (mounted) _focusZone(_Zone.groups);
  }

  Future<void> _menuAction(String item) async {
    setState(() => _menuVisible = false);
    switch (item) {
      case 'live':
        await _browse(const _BrowseGroup('all', 'All channels'));
        restoreChannelFocus();
      case 'favorites':
        await _browse(const _BrowseGroup('favorites', 'Favorites'));
        restoreChannelFocus();
      case 'resume':
        final playing = widget.store.nowPlaying;
        if (playing != null) await _watch(playing);
      case 'source':
        await _choosePlaylist();
      case 'search':
        await widget.onSearch();
        if (mounted) restoreChannelFocus();
      case 'playlists':
        await widget.onManagePlaylists();
        if (mounted) _focusZone(_Zone.groups);
      case 'logout':
        await widget.onLogout();
        if (mounted) _focusZone(_Zone.groups);
    }
  }

  @override
  void dispose() {
    _groupsFocus.dispose();
    _channelsFocus.dispose();
    _programmeFocus.dispose();
    _menuFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final store = widget.store;
        final groups = [
          const _BrowseGroup('all', 'All channels'),
          const _BrowseGroup('favorites', 'Favorites'),
          ...store.groups.map(
            (g) => _BrowseGroup('group:${g.name}', g.name, group: g),
          ),
        ];
        final loading = _favorites
            ? store.loadingFavoriteChannels
            : store.loadingChannels;
        final channels = loading ? const <Channel>[] : _channels;
        final menu = <String, String>{
          'live': 'Live TV',
          'favorites': 'Favorites',
          if (store.nowPlaying != null) 'resume': 'Resume watching',
          'source': 'Choose playlist',
          'search': 'Search',
          'playlists': 'Manage playlists',
          'logout': 'Log out',
        };
        return PopScope(
          canPop: _menuVisible,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _back();
          },
          child: Scaffold(
            backgroundColor: const Color(0xff0c1420),
            body: SafeArea(
              child: Stack(
                children: [
                  ExcludeFocus(
                    excluding: _menuVisible,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
                      child: Column(
                        children: [
                          ExcludeFocus(
                            child: Row(
                              children: [
                                const Text(
                                  'stream',
                                  style: TextStyle(
                                    fontSize: 25,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const Text(
                                  'pilot',
                                  style: TextStyle(
                                    fontSize: 25,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xff75b9ff),
                                  ),
                                ),
                                const Spacer(),
                                Flexible(
                                  child: TextButton.icon(
                                    onPressed: _choosePlaylist,
                                    icon: const Icon(Icons.playlist_play),
                                    label: Text(
                                      store.selectedPlaylist?.name ??
                                          'Choose playlist',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: widget.onSearch,
                                  tooltip: 'Search',
                                  icon: const Icon(Icons.search),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  flex: 22,
                                  child: _column(
                                    'BROWSE',
                                    TvRemoteList<_BrowseGroup>(
                                      focusNode: _groupsFocus,
                                      items: groups,
                                      itemId: (g) => g.id,
                                      selectedId: _browseId,
                                      memoryKey:
                                          'groups:${store.selectedPlaylistId}',
                                      itemExtent: 60,
                                      onFocused: (g) {
                                        if (_groupsFocus.hasFocus) {
                                          _zone = _Zone.groups;
                                        }
                                        unawaited(_browse(g));
                                      },
                                      onActivate: (g) {
                                        unawaited(_browse(g, retry: true));
                                        _focusZone(_Zone.channels);
                                      },
                                      onLongPress: (g) async {
                                        if (g.group == null) return;
                                        await showGroupActionSheet(
                                          context,
                                          group: g.group!,
                                          store: store,
                                          onOpen: () async {
                                            await _browse(g);
                                            _focusZone(_Zone.channels);
                                          },
                                        );
                                        if (mounted && _zone == _Zone.groups) {
                                          _groupsFocus.requestFocus();
                                        }
                                      },
                                      onLeft: _openMenu,
                                      onRight: () => _focusZone(_Zone.channels),
                                      onBack: _back,
                                      itemBuilder: (_, g, focused) => Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        child: Row(
                                          children: [
                                            if (g.id == 'favorites' ||
                                                g.group?.isFavorite ==
                                                    true) ...[
                                              const Icon(Icons.star, size: 18),
                                              const SizedBox(width: 8),
                                            ],
                                            Expanded(
                                              child: Text(
                                                g.label,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 18,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  flex: 37,
                                  child: _column(
                                    _favorites ? 'FAVORITES' : 'CHANNELS',
                                    TvRemoteList<Channel>(
                                      focusNode: _channelsFocus,
                                      autofocus: true,
                                      items: channels,
                                      itemId: tvChannelId,
                                      selectedId: _channelMemory[_memoryKey],
                                      memoryKey: _memoryKey,
                                      onFocused: (c) {
                                        if (_channelsFocus.hasFocus) {
                                          _zone = _Zone.channels;
                                        }
                                        if (_focusedChannel == c &&
                                            _channelMemory[_memoryKey] ==
                                                tvChannelId(c)) {
                                          return;
                                        }
                                        setState(() {
                                          _focusedChannel = c;
                                          _channelMemory[_memoryKey] =
                                              tvChannelId(c);
                                        });
                                      },
                                      onActivate: (c) => unawaited(_watch(c)),
                                      onLongPress: (c) =>
                                          unawaited(_channelOptions(c)),
                                      onLeft: () => _focusZone(_Zone.groups),
                                      onRight: () =>
                                          _focusZone(_Zone.programme),
                                      onBack: _back,
                                      empty: Center(
                                        child: loading
                                            ? const CircularProgressIndicator()
                                            : Text(
                                                _favorites
                                                    ? 'No favorites yet.\nHold OK on a channel to add one.'
                                                    : store.channelsError ??
                                                          'No channels found.\nChoose a group or playlist.',
                                                textAlign: TextAlign.center,
                                              ),
                                      ),
                                      itemBuilder: (_, c, focused) => Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                        ),
                                        child: Row(
                                          children: [
                                            ChannelLogoAvatar(
                                              logoUrl: c.logoUrl,
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    c.name,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 20,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                  Text(
                                                    c.groupName,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      color: focused
                                                          ? const Color(
                                                              0xff43566c,
                                                            )
                                                          : const Color(
                                                              0xff9cadc1,
                                                            ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (store.nowPlaying != null &&
                                                tvChannelId(
                                                      store.nowPlaying!,
                                                    ) ==
                                                    tvChannelId(c))
                                              const Padding(
                                                padding: EdgeInsets.only(
                                                  left: 8,
                                                ),
                                                child: Icon(
                                                  Icons.equalizer,
                                                  color: Color(0xff39b78d),
                                                  size: 21,
                                                ),
                                              ),
                                            if (c.isFavorite)
                                              const Padding(
                                                padding: EdgeInsets.only(
                                                  left: 6,
                                                ),
                                                child: Icon(
                                                  Icons.star,
                                                  size: 17,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Expanded(
                                  flex: 38,
                                  child: TvProgrammePanel(
                                    store: store,
                                    channel: _focusedChannel,
                                    preview: widget.preview,
                                    focusNode: _programmeFocus,
                                    onReturn: () => _focusZone(_Zone.channels),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Divider(height: 1),
                          const SizedBox(height: 10),
                          DefaultTextStyle.merge(
                            style: const TextStyle(
                              fontSize: 14,
                              color: Color(0xffa2b4ca),
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 20,
                                runSpacing: 4,
                                children: [
                                  const Text('↑ ↓  Browse'),
                                  const Text('← →  Change column'),
                                  Text(switch (_zone) {
                                    _Zone.groups => 'OK  Open group',
                                    _Zone.channels => 'OK  Watch',
                                    _Zone.programme => 'OK  Details',
                                  }),
                                  if (_zone != _Zone.programme)
                                    const Text('Hold OK  Options'),
                                  const Text('BACK  Previous'),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_menuVisible)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black54,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: 300,
                            color: const Color(0xff142133),
                            padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'StreamPilot',
                                  style: TextStyle(
                                    fontSize: 25,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Expanded(
                                  child: TvRemoteList<String>(
                                    focusNode: _menuFocus,
                                    items: menu.keys.toList(),
                                    selectedId: _menuId,
                                    itemId: (id) => id,
                                    memoryKey: 'menu',
                                    itemExtent: 58,
                                    onFocused: (id) => _menuId = id,
                                    onActivate: (id) =>
                                        unawaited(_menuAction(id)),
                                    onLeft: () {},
                                    onRight: () {
                                      setState(() => _menuVisible = false);
                                      _focusZone(_Zone.groups);
                                    },
                                    onBack: _back,
                                    itemBuilder: (_, id, focused) => Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Text(
                                        menu[id]!,
                                        style: const TextStyle(fontSize: 20),
                                      ),
                                    ),
                                  ),
                                ),
                                const Text(
                                  '→  Back to browsing\nBACK  Exit to TV home',
                                  style: TextStyle(
                                    color: Color(0xffa2b4ca),
                                    height: 1.8,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _column(String title, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 12, bottom: 10),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            letterSpacing: 1.4,
            color: Color(0xff94a8c1),
          ),
        ),
      ),
      Expanded(child: child),
    ],
  );
}

class _BrowseGroup {
  const _BrowseGroup(this.id, this.label, {this.group});
  final String id;
  final String label;
  final Group? group;
}
