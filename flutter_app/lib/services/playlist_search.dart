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
  final matches = groups
      .where((g) => g.name.toLowerCase().contains(q))
      .toList();
  matches.sort((a, b) {
    final relevance = _nameRelevance(
      a.name,
      q,
    ).compareTo(_nameRelevance(b.name, q));
    return relevance != 0 ? relevance : compareGroups(a, b);
  });
  return matches;
}

List<Channel> filterChannels(
  List<Channel> channels,
  String query,
  ChannelSortOrder order,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return channels;
  final matches = channels
      .where(
        (c) =>
            c.name.toLowerCase().contains(q) ||
            c.groupName.toLowerCase().contains(q),
      )
      .toList();
  matches.sort((a, b) {
    final relevance = _nameRelevance(
      a.name,
      q,
    ).compareTo(_nameRelevance(b.name, q));
    return relevance != 0 ? relevance : compareChannels(a, b, order);
  });
  return matches;
}

int _nameRelevance(String name, String query) {
  final normalized = name.trim().toLowerCase();
  if (normalized == query) return 0;
  if (normalized.startsWith(query)) return 1;
  if (normalized
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .any((word) => word.startsWith(query))) {
    return 2;
  }
  if (normalized.contains(query)) return 3;
  return 4; // Group-only matches follow channel-name matches.
}
