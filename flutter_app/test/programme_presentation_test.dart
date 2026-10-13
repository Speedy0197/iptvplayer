import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/screens/home/widgets/programme_presentation.dart';
import 'package:flutter_app/widgets/playback_feedback.dart';

void main() {
  final start = DateTime.utc(2026, 1, 1, 18);
  EpgEntry entry(DateTime end) => EpgEntry(
    channelEpgId: 'fixture',
    startTime: start,
    endTime: end,
    title: 'Programme',
    description: '',
  );
  test('programme starts inclusively and ends exclusively', () {
    final programme = entry(start.add(const Duration(hours: 1)));
    expect(isProgrammeOnNow(programme, start), isTrue);
    expect(
      isProgrammeOnNow(programme, start.subtract(const Duration(seconds: 1))),
      isFalse,
    );
    expect(
      isProgrammeOnNow(programme, start.add(const Duration(hours: 1))),
      isFalse,
    );
    expect(
      programmeProgress(programme, start.add(const Duration(minutes: 15))),
      .25,
    );
    expect(
      programmeProgress(programme, start.subtract(const Duration(hours: 1))),
      0,
    );
    expect(
      programmeProgress(programme, start.add(const Duration(hours: 2))),
      1,
    );
  });
  test('invalid programme durations remain finite', () {
    expect(programmeProgress(entry(start), start), 0);
    expect(
      programmeProgress(
        entry(start.subtract(const Duration(minutes: 1))),
        start,
      ),
      0,
    );
  });
  test('remaining time rounds a partial minute upwards', () {
    final programme = entry(start.add(const Duration(seconds: 61)));
    expect(programmeRemaining(programme, start), '2 min remaining');
    expect(
      programmeRemaining(programme, start.add(const Duration(seconds: 61))),
      'Ended',
    );
    expect(
      programmeRemaining(
        programme,
        start.add(const Duration(milliseconds: 60900)),
      ),
      '1 min remaining',
    );
  });
  test('errors never echo native messages or credentials', () {
    for (final raw in [
      'Playback https://user:pass@fixture.invalid/path?token=secret',
      'username=secret password=private failed',
      'Unexpected private receiver name',
    ]) {
      expect(
        friendlyPlaybackError(raw),
        'This channel could not be played. Check your connection or try another channel.',
      );
    }
    expect(
      friendlyPlaybackError('HTTP 403 private-token'),
      contains('source account'),
    );
    expect(
      friendlyPlaybackError('connection timed out https://private.invalid'),
      contains('taking too long'),
    );
  });
}
