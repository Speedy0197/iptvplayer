import '../models/models.dart';
import 'channel_sort.dart';

enum SearchResultType { channel, group }

class SearchResultItem {
  final SearchResultType type;
  final String title;
  final String subtitle;
  final Channel? channel;
  final Group? group;

  const SearchResultItem._({
    required this.type,
    required this.title,
    required this.subtitle,
    this.channel,
    this.group,
  });

  factory SearchResultItem.channel(Channel c) {
    return SearchResultItem._(
      type: SearchResultType.channel,
      title: c.name,
      subtitle: c.groupName,
      channel: c,
    );
  }

  factory SearchResultItem.group(Group g) {
    return SearchResultItem._(
      type: SearchResultType.group,
      title: g.name,
      subtitle: '${g.channelCount} channels',
      group: g,
    );
  }
}

List<Group> filterGroups(List<Group> groups, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return groups;
  return sortGroups(groups.where((g) => g.name.toLowerCase().contains(q)));
}

List<Channel> filterChannels(
  List<Channel> channels,
  String query,
  ChannelSortOrder order,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return channels;
  return sortChannels(
    channels.where(
      (c) =>
          c.name.toLowerCase().contains(q) ||
          c.groupName.toLowerCase().contains(q),
    ),
    order,
  );
}
