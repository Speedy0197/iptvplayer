import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/services/playlist_search.dart';
import 'package:flutter_app/services/channel_sort.dart';

Channel channel(int id, String name, {bool favorite = false, int index = 0}) =>
    Channel(
      id: id,
      playlistId: 1,
      streamId: '',
      name: name,
      groupName: 'News',
      streamUrl: '',
      logoUrl: '',
      epgChannelId: '',
      isFavorite: favorite,
      sortOrder: index,
    );

void main() {
  test('name relevance precedes favorite and alphabetical tie breakers', () {
    final channels = [
      channel(1, 'Antennews', favorite: true),
      channel(2, 'World News'),
      channel(3, 'Newsroom'),
      channel(4, 'News'),
      channel(5, 'Bulletin'),
    ];
    expect(
      filterChannels(
        channels,
        ' news ',
        ChannelSortOrder.byName,
      ).map((c) => c.id),
      [4, 3, 2, 1, 5],
    );
  });
  test('equal relevance keeps the chosen channel ordering', () {
    expect(
      filterChannels(
        [channel(1, 'News Alpha', index: 9), channel(2, 'News Beta', index: 2)],
        'news',
        ChannelSortOrder.byIndex,
      ).map((c) => c.id),
      [2, 1],
    );
  });
  test('groups put exact and prefix matches ahead of substrings', () {
    final groups = [
      const Group(
        playlistId: 1,
        name: 'A News',
        channelCount: 1,
        isFavorite: true,
      ),
      const Group(
        playlistId: 1,
        name: 'News',
        channelCount: 2,
        isFavorite: false,
      ),
      const Group(
        playlistId: 1,
        name: 'News Europe',
        channelCount: 3,
        isFavorite: false,
      ),
    ];
    expect(filterGroups(groups, 'news').map((g) => g.name), [
      'News',
      'News Europe',
      'A News',
    ]);
  });
}
