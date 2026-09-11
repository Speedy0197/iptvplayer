import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/services/xmltv_guide.dart';
import 'package:flutter_test/flutter_test.dart';

Channel channel(String id, {String name = 'News One HD'}) => Channel(
  id: 1,
  playlistId: 1,
  streamId: '1',
  name: name,
  groupName: '',
  streamUrl: '',
  logoUrl: '',
  epgChannelId: id,
  isFavorite: false,
);

void main() {
  test(
    'preserves matching, text, offsets, sorting and duplicate removal',
    () async {
      final guide = await parseXmltvGuide('''
<tv>
  <channel id="news.one"><display-name>News One HD</display-name></channel>
  <channel id="news.other"><display-name>News One HD Extra</display-name></channel>
  <channel id="empty"/>
  <programme channel="news.one" start="20260911150000 +0200" stop="20260911160000 +0200">
    <title>Later</title>
  </programme>
  <programme channel=" NEWS.ONE " start="20260911140000 +0200" stop="20260911150000 +0200">
    <title>News &amp; <![CDATA[weather]]></title><title>Ignored translation</title>
    <desc>Before <b>bold</b> after</desc>
  </programme>
  <programme channel="news.one" start="20260911080000 -0400" stop="20260911090000 -0400">
    <title>News &amp; weather</title><desc>Before <b>bold</b> after</desc>
  </programme>
  <programme channel="news.one" start="bad" stop="bad"><title>Invalid</title></programme>
  <programme channel="news.one" start="20260911140000" stop="20260911130000"/>
  <programme channel="news.other" start="20260911140000" stop="20260911150000"><title>Other</title></programme>
</tv>
''');
      final entries = guide.entriesFor(channel('NEWS.ONE'));
      expect(entries.map((e) => e.title), ['News & weather', 'Later']);
      expect(entries.first.description, 'Before bold after');
      expect(entries.first.startTime.toUtc(), DateTime.utc(2026, 9, 11, 12));
      expect(entries.first.endTime.toUtc(), DateTime.utc(2026, 9, 11, 13));
      expect(entries.map((e) => e.channelEpgId), everyElement('NEWS.ONE'));
      expect(guide.entriesFor(channel('missing')), isEmpty);

      final fallback = guide.entriesFor(channel(''));
      expect(fallback.map((e) => e.title), [
        'News & weather',
        'Later',
        'Other',
      ]);
      expect(guide.entriesFor(channel('', name: 'Empty')), isEmpty);
    },
  );

  test('parses programmes and Unicode text across XML chunks', () async {
    final description = '${'x' * 17000} 📺 & weather';
    final guide = await parseXmltvGuide('''
<tv><channel id="news.one"/>
<programme channel="news.one" start="20260911120000" stop="20260911130000">
  <title>News 📺</title><desc><![CDATA[$description]]></desc>
</programme></tv>
''');
    final entry = guide.entriesFor(channel('news.one')).single;
    expect(entry.title, 'News 📺');
    expect(entry.description, description);
  });

  test('rejects malformed or multiple-root XML', () async {
    for (final xml in ['<tv><programme></tv>', '<tv/><tv/>', '<tv>']) {
      await expectLater(parseXmltvGuide(xml), throwsA(anything));
    }
  });
}
