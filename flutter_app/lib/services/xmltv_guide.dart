import 'dart:math' as math;

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../models/models.dart';

/// A compact guide index. It retains programme data, never the XML document.
class XmltvGuide {
  XmltvGuide(this._names, this._programmes);

  final Map<String, List<String>> _names;
  final Map<String, List<EpgEntry>> _programmes;

  List<EpgEntry> entriesFor(Channel channel) {
    final targetId = channel.epgChannelId.trim().toLowerCase();
    final ids = <String>{};
    if (targetId.isNotEmpty) {
      ids.add(targetId);
    } else {
      final name = _normalize(channel.name);
      for (final entry in _names.entries) {
        if (entry.value.any((candidate) => _matches(name, candidate))) {
          ids.add(entry.key);
        }
      }
    }

    final entries = [for (final id in ids) ...?_programmes[id]]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final seen = <DateTime>{};
    return [
      for (final entry in entries)
        if (seen.add(entry.startTime))
          EpgEntry(
            channelEpgId: channel.epgChannelId.isNotEmpty
                ? channel.epgChannelId
                : entry.channelEpgId,
            startTime: entry.startTime,
            endTime: entry.endTime,
            title: entry.title,
            description: entry.description,
          ),
    ];
  }
}

/// Run with compute: parse once per feed, away from remote input and rendering.
Future<XmltvGuide> parseXmltvGuide(String xml) async {
  final names = <String, List<String>>{};
  final programmes = <String, List<EpgEntry>>{};

  // Chunk before decoding events so neither the event list nor the node tree
  // grows to the size of a provider's complete guide.
  Iterable<String> chunks() sync* {
    const chunkSize = 16 * 1024;
    for (var offset = 0; offset < xml.length; offset += chunkSize) {
      yield xml.substring(offset, math.min(offset + chunkSize, xml.length));
    }
  }

  final elements = Stream.fromIterable(chunks())
      .toXmlEvents(validateNesting: true, validateDocument: true)
      .selectSubtreeEvents(
        (event) => event.name == 'channel' || event.name == 'programme',
      )
      .toXmlNodes()
      .expand((nodes) => nodes.whereType<XmlElement>());
  await for (final element in elements) {
    if (element.name.local == 'channel') {
      final id = (element.getAttribute('id') ?? '').trim().toLowerCase();
      if (id.isEmpty) continue;
      names
          .putIfAbsent(id, () => [_normalize(id)])
          .addAll(
            element
                .findElements('display-name')
                .map((e) => _normalize(e.innerText)),
          );
      continue;
    }

    final id = (element.getAttribute('channel') ?? '').trim().toLowerCase();
    final start = _parseDate(element.getAttribute('start') ?? '');
    final end = _parseDate(element.getAttribute('stop') ?? '');
    if (id.isEmpty || start == null || end == null || !end.isAfter(start)) {
      continue;
    }
    programmes
        .putIfAbsent(id, () => [])
        .add(
          EpgEntry(
            channelEpgId: id,
            startTime: start,
            endTime: end,
            title: element.getElement('title')?.innerText.trim() ?? '',
            description: element.getElement('desc')?.innerText.trim() ?? '',
          ),
        );
  }
  return XmltvGuide(names, programmes);
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

bool _matches(String left, String right) {
  if (left.isEmpty || right.isEmpty) return false;
  if (left == right) return true;
  if (left.length >= 5 && right.contains(left)) return true;
  if (right.length >= 5 && left.contains(right)) return true;
  return false;
}

DateTime? _parseDate(String value) {
  final match = RegExp(
    r'^(\d{14})(?:\s+([+-]\d{4}))?',
  ).firstMatch(value.trim());
  if (match == null) return null;
  final digits = match.group(1)!;
  final utc = DateTime.utc(
    int.parse(digits.substring(0, 4)),
    int.parse(digits.substring(4, 6)),
    int.parse(digits.substring(6, 8)),
    int.parse(digits.substring(8, 10)),
    int.parse(digits.substring(10, 12)),
    int.parse(digits.substring(12, 14)),
  );
  final offset = match.group(2);
  if (offset == null) return utc.toLocal();
  final sign = offset.startsWith('-') ? -1 : 1;
  final minutes =
      sign *
      (int.parse(offset.substring(1, 3)) * 60 +
          int.parse(offset.substring(3, 5)));
  return utc.subtract(Duration(minutes: minutes)).toLocal();
}
