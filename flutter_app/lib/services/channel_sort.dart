import '../models/models.dart';

enum ChannelSortOrder { byName, byIndex }

int compareGroups(Group a, Group b) {
  if (a.isFavorite != b.isFavorite) {
    return a.isFavorite ? -1 : 1;
  }
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

int compareChannels(Channel a, Channel b, ChannelSortOrder order) {
  if (a.isFavorite != b.isFavorite) {
    return a.isFavorite ? -1 : 1;
  }
  switch (order) {
    case ChannelSortOrder.byIndex:
      final cmp = (a.sortOrder ?? 0).compareTo(b.sortOrder ?? 0);
      if (cmp != 0) return cmp;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    case ChannelSortOrder.byName:
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}

List<Group> sortGroups(Iterable<Group> values) {
  final list = values.toList();
  list.sort(compareGroups);
  return list;
}

List<Channel> sortChannels(Iterable<Channel> values, ChannelSortOrder order) {
  final list = values.toList();
  list.sort((a, b) => compareChannels(a, b, order));
  return list;
}
