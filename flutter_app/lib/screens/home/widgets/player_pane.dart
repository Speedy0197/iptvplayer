import 'package:flutter/material.dart';

import '../../../config/device_utils.dart';
import '../../../config/ui_constants.dart';
import '../../../models/models.dart';
import '../../../services/playlist_store.dart';
import '../../../widgets/channel_player.dart';
import '../../../widgets/tv_focusable_tile.dart';

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

  Future<void> _playNextChannel() async {
    final channels = store.channels;
    final nowPlaying = store.nowPlaying;
    if (channels.isEmpty || nowPlaying == null) return;

    final currentIndex = channels.indexWhere((c) => c.id == nowPlaying.id);
    if (currentIndex < 0) return;

    final nextIndex = (currentIndex + 1) % channels.length;
    await store.play(channels[nextIndex]);
  }

  Future<void> _playPreviousChannel() async {
    final channels = store.channels;
    final nowPlaying = store.nowPlaying;
    if (channels.isEmpty || nowPlaying == null) return;

    final currentIndex = channels.indexWhere((c) => c.id == nowPlaying.id);
    if (currentIndex < 0) return;

    final nextIndex = currentIndex == 0
        ? channels.length - 1
        : currentIndex - 1;
    await store.play(channels[nextIndex]);
  }

  Widget _buildEpgEntryCard(BuildContext context, EpgEntry entry, bool isTv) {
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
      isTv: isTv,
      onRecord: () => store.recordEpgEntry(entry),
      onRemoveTimer: () => store.removeEpgTimer(entry),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Channel? channel = store.nowPlaying;
    final isCompactLayout =
        MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    final isTv = isAndroidTv(context);
    final epgLimit = isTv ? kTvEpgEntriesToShow : kDesktopEpgEntriesToShow;

    if (channel == null) {
      return const Card(
        child: Center(child: Text('Select a channel to start playback')),
      );
    }

    final headerContent = [
      ChannelPlayer(
        streamUrl: channel.streamUrl,
        isActiveRecording: store.isChannelActivelyRecording(channel),
        onNextChannel: _playNextChannel,
        onPreviousChannel: _playPreviousChannel,
      ),
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

    final now = DateTime.now();
    final allEpg = store.epgEntries;
    // Find the currently airing entry (or the next upcoming if none is live)
    final nowIndex = allEpg.indexWhere(
      (e) => e.startTime.isBefore(now) && e.endTime.isAfter(now),
    );
    final startIndex = nowIndex >= 0
        ? nowIndex
        : allEpg.indexWhere((e) => e.startTime.isAfter(now));
    final epgToShow = startIndex >= 0
        ? allEpg.skip(startIndex).take(epgLimit).toList()
        : allEpg.take(epgLimit).toList();
    final epgContent = store.loadingEpg
        ? const Center(child: CircularProgressIndicator())
        : store.epgSourceMissing
        ? const Text('No EPG source configured for this channel')
        : epgToShow.isEmpty
        ? const Text('No EPG data available')
        : ListView.builder(
            itemCount: epgToShow.length,
            itemBuilder: (context, i) {
              final entry = epgToShow[i];
              return _buildEpgEntryCard(context, entry, isTv);
            },
          );

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
                ...epgToShow.map(
                  (entry) => _buildEpgEntryCard(context, entry, isTv),
                ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Ensure we have valid constraints; fallback to reasonable defaults if not
          final availableWidth = constraints.maxWidth > 0
              ? constraints.maxWidth
              : 500;
          final availableHeight = constraints.maxHeight > 0
              ? constraints.maxHeight
              : 600;
          final maxPlayerWidth = isTv
              ? ((availableHeight * 0.48) * 16 / 9).clamp(
                  200.0,
                  availableWidth * 0.82,
                )
              : (availableWidth * 0.95).clamp(200.0, 1500.0);
          // On TV, keep the current visual height and let width follow it.
          final playerHeight = (maxPlayerWidth / 16 * 9).clamp(
            160.0,
            availableHeight * (isTv ? 0.48 : 0.6),
          );
          final tvInfoWidth = (availableWidth * 0.48).clamp(280.0, 720.0);

          return Padding(
            padding: const EdgeInsets.all(16),
            child: isTv
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: tvInfoWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: maxPlayerWidth,
                              height: playerHeight,
                              child: ChannelPlayer(
                                streamUrl: channel.streamUrl,
                                isActiveRecording: store
                                    .isChannelActivelyRecording(channel),
                                onNextChannel: _playNextChannel,
                                onPreviousChannel: _playPreviousChannel,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              channel.name,
                              style: Theme.of(context).textTheme.titleLarge,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              channel.groupName,
                              style: Theme.of(context).textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'EPG',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Expanded(child: epgContent),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: maxPlayerWidth,
                          height: playerHeight,
                          child: ChannelPlayer(
                            streamUrl: channel.streamUrl,
                            isActiveRecording: store.isChannelActivelyRecording(
                              channel,
                            ),
                            onNextChannel: _playNextChannel,
                            onPreviousChannel: _playPreviousChannel,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        channel.name,
                        style: Theme.of(context).textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        channel.groupName,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'EPG',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Expanded(child: epgContent),
                    ],
                  ),
          );
        },
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
  final bool isTv;
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
    required this.isTv,
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

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
    });
  }

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
      if (mounted) {
        setState(() {
          _removingTimer = false;
        });
      }
    }
  }

  Future<void> _saveRecording() async {
    if (_savingRecording) return;
    setState(() {
      _savingRecording = true;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.onRecord();
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Recording timer added')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not add timer: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingRecording = false;
        });
      }
    }
  }

  Future<void> _handleTvLongPress() async {
    if (!widget.canRecord) return;
    if (widget.isTimerScheduled) {
      await _removeTimer();
      return;
    }
    if (!widget.hasEnded) {
      await _saveRecording();
    }
  }

  Widget _buildRecordAction(BuildContext context) {
    if (widget.isTimerScheduled) {
      return Tooltip(
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
      );
    }

    return SizedBox(
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
              onPressed: widget.hasEnded ? null : _saveRecording,
              color: widget.hasEnded ? null : Colors.red,
              icon: const Icon(Icons.fiber_manual_record),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = widget.isTv
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)
        : null;
    final timeStyle = widget.isTv
        ? theme.textTheme.titleSmall
        : theme.textTheme.bodyMedium;
    final card = Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        key: PageStorageKey<String>(widget.storageKey),
        initiallyExpanded: _expanded,
        tilePadding: widget.isTv
            ? const EdgeInsets.symmetric(horizontal: 20, vertical: 12)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        onExpansionChanged: (value) {
          setState(() {
            _expanded = value;
          });
        },
        title: LayoutBuilder(
          builder: (context, constraints) {
            final controls = widget.canRecord
                ? _buildRecordAction(context)
                : const SizedBox.shrink();
            final isNarrow = constraints.maxWidth < 420;

            if (isNarrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.timeRange,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: timeStyle,
                        ),
                      ),
                      if (widget.canRecord) ...[
                        const SizedBox(width: 4),
                        controls,
                      ],
                    ],
                  ),
                ],
              );
            }

            return Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    widget.timeRange,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: timeStyle,
                  ),
                ),
                if (widget.canRecord) ...[const SizedBox(width: 4), controls],
              ],
            );
          },
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

    if (!widget.isTv) {
      return card;
    }

    return TvFocusableTile(
      margin: const EdgeInsets.only(bottom: 8),
      onTap: _toggleExpanded,
      onLongPress: widget.canRecord ? _handleTvLongPress : null,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: _expanded ? 3 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.timeRange,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: timeStyle,
                        ),
                      ],
                    ),
                  ),
                  if (widget.canRecord) ...[
                    const SizedBox(width: 12),
                    _buildRecordAction(context),
                  ],
                  const SizedBox(width: 8),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                widget.description,
                maxLines: _expanded ? null : 2,
                overflow: _expanded ? null : TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
