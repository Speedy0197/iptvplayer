import 'package:flutter/material.dart';

import '../../../config/ui_constants.dart';
import '../../../models/models.dart';
import '../../../services/playlist_store.dart';
import '../../../widgets/channel_player.dart';

class PlayerPane extends StatelessWidget {
  final PlaylistStore store;

  const PlayerPane({super.key, required this.store});

  String _fmtTime(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final Channel? channel = store.nowPlaying;
    final isCompactLayout = MediaQuery.sizeOf(context).width < kCompactBreakpoint;

    if (channel == null) {
      return const Card(
        child: Center(child: Text('Select a channel to start playback')),
      );
    }

    final headerContent = [
      ChannelPlayer(streamUrl: channel.streamUrl),
      const SizedBox(height: 12),
      Text(
        channel.name,
        style: Theme.of(context).textTheme.titleLarge,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      Text(channel.groupName, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      const Text('EPG', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
    ];

    if (isCompactLayout) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            children: [
              ...headerContent,
              if (store.loadingEpg)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (store.epgEntries.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No EPG data available'),
                )
              else
                ...store.epgEntries.map(
                  (entry) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(entry.title),
                      subtitle: Text(entry.description),
                      trailing: Text(
                        '${_fmtTime(entry.startTime)} - ${_fmtTime(entry.endTime)}',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...headerContent,
            Expanded(
              child: store.loadingEpg
                  ? const Center(child: CircularProgressIndicator())
                  : store.epgEntries.isEmpty
                  ? const Text('No EPG data available')
                  : ListView.builder(
                      itemCount: store.epgEntries.length,
                      itemBuilder: (context, i) {
                        final e = store.epgEntries[i];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(e.title),
                            subtitle: Text(e.description),
                            trailing: Text(
                              '${_fmtTime(e.startTime)} - ${_fmtTime(e.endTime)}',
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
