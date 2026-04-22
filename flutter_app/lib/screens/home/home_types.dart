import '../../models/models.dart';

typedef GroupTapCallback = Future<void> Function(Group group);
typedef ChannelTapCallback = Future<void> Function(Channel channel);

enum HomeSection { watch, favorites, playlists }

enum WatchBrowseMode { both, playlistsOnly, groupsOnly }
