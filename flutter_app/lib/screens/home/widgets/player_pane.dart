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

  String _descriptionPreview(String description) {
    final normalized = description.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return 'No description available';
    }
    return normalized;
  }

  Widget _buildEpgEntryCard(BuildContext context, EpgEntry entry) {
    final timeRange =
        '${_fmtTime(entry.startTime)} - ${_fmtTime(entry.endTime)}';
    final description = _descriptionPreview(entry.description);

    return _EpgEntryCard(
      storageKey: '${entry.channelEpgId}_${entry.startTime.toIso8601String()}',
      title: entry.title,
      timeRange: timeRange,
      description: description,
      canRecord: store.isSelectedPlaylistVuplus,
      hasEnded: entry.endTime.isBefore(DateTime.now()),
      isTimerScheduled: store.isTimerScheduled(entry),
      onRecord: () => store.recordEpgEntry(entry),
      onRemoveTimer: () => store.removeEpgTimer(entry),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Channel? channel = store.nowPlaying;
    final isCompactLayout =
        MediaQuery.sizeOf(context).width < kCompactBreakpoint;

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

    final epgToShow = store.epgEntries.take(3).toList();

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
              else if (store.epgSourceMissing)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No EPG source configured for this channel'),
                )
              else if (epgToShow.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No EPG data available'),
                )
              else
                ...epgToShow.map((entry) => _buildEpgEntryCard(context, entry)),
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
                  : store.epgSourceMissing
                  ? const Text('No EPG source configured for this channel')
                  : epgToShow.isEmpty
                  ? const Text('No EPG data available')
                  : ListView.builder(
                      itemCount: epgToShow.length,
                      itemBuilder: (context, i) {
                        final e = epgToShow[i];
                        return _buildEpgEntryCard(context, e);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EpgEntryCard extends StatefulWidget {
  final String storageKey;
  final String title;
  final String timeRange;
  final String description;
  final bool canRecord;
  final bool hasEnded;
  final bool isTimerScheduled;
  final Future<void> Function() onRecord;
  final Future<void> Function() onRemoveTimer;

  const _EpgEntryCard({
    required this.storageKey,
    required this.title,
    required this.timeRange,
    required this.description,
    required this.canRecord,
    required this.hasEnded,
    required this.isTimerScheduled,
    required this.onRecord,
    required this.onRemoveTimer,
  });

  @override
  State<_EpgEntryCard> createState() => _EpgEntryCardState();
}

class _EpgEntryCardState extends State<_EpgEntryCard> {
  bool _expanded = false;
  bool _savingRecording = false;
  bool _removingTimer = false;

  Future<void> _removeTimer() async {
    if (_removingTimer) return;
    setState(() {
      _removingTimer = true;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.onRemoveTimer();
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Recording timer removed')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not remove timer: $e')),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _removingTimer = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        key: PageStorageKey<String>(widget.storageKey),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        onExpansionChanged: (value) {
          setState(() {
            _expanded = value;
          });
        },
        title: Row(
          children: [
            Expanded(
              child: Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              widget.timeRange,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (widget.canRecord) ...[
              const SizedBox(width: 4),
              if (widget.isTimerScheduled)
                Tooltip(
                  message: 'Recording scheduled',
                  child: _removingTimer
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: Padding(
                            padding: EdgeInsets.all(2),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : InkWell(
                          onTap: _removeTimer,
                          child: Icon(
                            Icons.check_circle,
                            size: 20,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                )
              else
                SizedBox(
                  width: 32,
                  height: 32,
                  child: _savingRecording
                      ? const Padding(
                          padding: EdgeInsets.all(6),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 20,
                          tooltip: widget.hasEnded ? 'Program ended' : 'Record',
                          onPressed: widget.hasEnded
                              ? null
                              : () async {
                                  if (_savingRecording) return;
                                  setState(() {
                                    _savingRecording = true;
                                  });
                                  final messenger = ScaffoldMessenger.of(
                                    context,
                                  );
                                  try {
                                    await widget.onRecord();
                                    if (!mounted) return;
                                    messenger.showSnackBar(
                                      const SnackBar(
                                        content: Text('Recording timer added'),
                                      ),
                                    );
                                  } catch (e) {
                                    if (!mounted) return;
                                    messenger.showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Could not add timer: $e',
                                        ),
                                      ),
                                    );
                                  } finally {
                                    if (!mounted) return;
                                    setState(() {
                                      _savingRecording = false;
                                    });
                                  }
                                },
                          color: widget.hasEnded
                              ? null
                              : Theme.of(context).colorScheme.error,
                          icon: const Icon(Icons.fiber_manual_record),
                        ),
                ),
            ],
          ],
        ),
        subtitle: _expanded
            ? null
            : Text(
                widget.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(widget.description),
          ),
        ],
      ),
    );
  }
}
