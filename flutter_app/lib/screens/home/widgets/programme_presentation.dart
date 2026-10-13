import 'package:flutter/material.dart';
import '../../../models/models.dart';

bool isProgrammeOnNow(EpgEntry entry, DateTime now) =>
    !entry.startTime.isAfter(now) && entry.endTime.isAfter(now);

double programmeProgress(EpgEntry entry, DateTime now) {
  final duration = entry.endTime.difference(entry.startTime).inMilliseconds;
  if (duration <= 0) return 0;
  return (now.difference(entry.startTime).inMilliseconds / duration).clamp(
    0.0,
    1.0,
  );
}

String programmeRemaining(EpgEntry entry, DateTime now) {
  final milliseconds = entry.endTime.difference(now).inMilliseconds;
  if (milliseconds <= 0) return 'Ended';
  return '${(milliseconds / 60000).ceil()} min remaining';
}

Future<bool> confirmRecordingCancellation(
  BuildContext context,
  String title,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel recording?'),
        content: Text(
          'Remove the scheduled recording of “$title” from the receiver?',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep recording'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel recording'),
          ),
        ],
      ),
    ) ??
    false;
