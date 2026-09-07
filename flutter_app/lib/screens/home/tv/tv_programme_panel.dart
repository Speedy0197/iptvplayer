import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../services/playlist_store.dart';
import 'tv_remote_list.dart';

/// Video follows playback; programme information follows the channel cursor.
class TvProgrammePanel extends StatefulWidget {
  const TvProgrammePanel({
    super.key,
    required this.store,
    required this.channel,
    required this.preview,
    required this.focusNode,
    required this.onReturn,
  });

  final PlaylistStore store;
  final Channel? channel;
  final Widget preview;
  final FocusNode focusNode;
  final VoidCallback onReturn;

  @override
  State<TvProgrammePanel> createState() => _TvProgrammePanelState();
}

class _TvProgrammePanelState extends State<TvProgrammePanel> {
  Timer? _debounce;
  int _generation = 0;
  List<EpgEntry> _entries = const [];
  bool _loading = false;
  bool _failed = false;
  String? _selectedEntry;
  bool _dialogOpen = false;

  String _entryId(EpgEntry entry) =>
      '${entry.channelEpgId}:${entry.startTime.toIso8601String()}';
  String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(covariant TvProgrammePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel?.id != widget.channel?.id ||
        oldWidget.channel?.playlistId != widget.channel?.playlistId ||
        oldWidget.store != widget.store) {
      _scheduleLoad();
    }
  }

  void _scheduleLoad() {
    _debounce?.cancel();
    final generation = ++_generation;
    final channel = widget.channel;
    _entries = const [];
    _selectedEntry = null;
    _loading = channel != null;
    _failed = false;
    if (channel == null) return;
    _debounce = Timer(const Duration(milliseconds: 180), () async {
      try {
        final entries = await widget.store.loadChannelEpg(channel);
        if (!mounted || generation != _generation) return;
        final now = DateTime.now();
        setState(() {
          _entries = entries
              .where((entry) => entry.endTime.isAfter(now))
              .take(4)
              .toList();
          _loading = false;
        });
      } catch (_) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    });
  }

  Future<void> _showEntry(EpgEntry entry) async {
    final channel = widget.channel;
    if (_dialogOpen || channel == null) return;
    _dialogOpen = true;
    final playlist = widget.store.playlists
        .where((p) => p.id == channel.playlistId)
        .firstOrNull;
    final canRecord = playlist?.type == 'vuplus';
    final timers = canRecord
        ? widget.store.loadChannelTimers(channel)
        : Future.value(const <VuplusTimer>[]);
    var saving = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) {
            return FutureBuilder<List<VuplusTimer>>(
              future: timers,
              builder: (ctx, snapshot) {
                final scheduled =
                    snapshot.data?.any(
                      (timer) =>
                          timer.beginUnix ==
                              entry.startTime.toUtc().millisecondsSinceEpoch ~/
                                  1000 &&
                          timer.channelEpgId.trim().toLowerCase() ==
                              entry.channelEpgId.trim().toLowerCase(),
                    ) ??
                    false;
                return AlertDialog(
                  title: Text(entry.title),
                  content: SizedBox(
                    width: 560,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${channel.name} · ${_time(entry.startTime)} – ${_time(entry.endTime)}',
                          ),
                          const SizedBox(height: 16),
                          Text(
                            entry.description.trim().isEmpty
                                ? 'No description available.'
                                : entry.description,
                          ),
                          if (canRecord && snapshot.hasError) ...[
                            const SizedBox(height: 16),
                            const Text(
                              'Recording options are unavailable right now.',
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      autofocus: true,
                      onPressed: saving ? null : () => Navigator.of(ctx).pop(),
                      child: const Text('Close'),
                    ),
                    if (canRecord && !snapshot.hasError)
                      FilledButton.icon(
                        icon: Icon(
                          scheduled
                              ? Icons.cancel_outlined
                              : Icons.fiber_manual_record,
                        ),
                        label: Text(
                          saving
                              ? 'Saving…'
                              : !snapshot.hasData
                              ? 'Loading timers…'
                              : scheduled
                              ? 'Remove timer'
                              : 'Record',
                        ),
                        onPressed: saving || !snapshot.hasData
                            ? null
                            : () async {
                                update(() => saving = true);
                                try {
                                  if (scheduled) {
                                    await widget.store.removeEpgTimer(
                                      entry,
                                      playlistId: channel.playlistId,
                                    );
                                  } else {
                                    await widget.store.recordEpgEntry(
                                      entry,
                                      playlistId: channel.playlistId,
                                    );
                                  }
                                  if (ctx.mounted) Navigator.of(ctx).pop();
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          scheduled
                                              ? 'Recording timer removed'
                                              : 'Recording scheduled',
                                        ),
                                      ),
                                    );
                                  }
                                } catch (_) {
                                  if (ctx.mounted) update(() => saving = false);
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Could not update the recording timer.',
                                        ),
                                      ),
                                    );
                                  }
                                }
                              },
                      ),
                  ],
                );
              },
            );
          },
        ),
      );
    } finally {
      _dialogOpen = false;
      if (mounted) widget.focusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playing = widget.store.nowPlaying;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            playing == null ? 'PREVIEW' : 'PLAYING · ${playing.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xff9cadc1),
              letterSpacing: .5,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: constraints.maxHeight * .42,
            width: double.infinity,
            child: ExcludeFocus(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ColoredBox(color: Colors.black, child: widget.preview),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            widget.channel?.name ?? 'Choose a channel',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            'PROGRAMME GUIDE · OK for details',
            style: TextStyle(fontSize: 12, color: Color(0xff9cadc1)),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: TvRemoteList<EpgEntry>(
              focusNode: widget.focusNode,
              items: _entries,
              itemId: _entryId,
              selectedId: _selectedEntry,
              memoryKey:
                  'epg:${widget.channel?.playlistId}:${widget.channel?.id}',
              itemExtent: 74,
              onFocused: (entry) => _selectedEntry = _entryId(entry),
              onActivate: (entry) => unawaited(_showEntry(entry)),
              onLeft: widget.onReturn,
              onRight: () {},
              onBack: widget.onReturn,
              empty: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : Text(
                        _failed
                            ? 'Programme information unavailable'
                            : 'No programme information',
                        style: const TextStyle(color: Color(0xff9cadc1)),
                        textAlign: TextAlign.center,
                      ),
              ),
              itemBuilder: (_, entry, focused) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${_time(entry.startTime)} – ${_time(entry.endTime)}',
                      style: TextStyle(
                        fontSize: 13,
                        color: focused
                            ? const Color(0xff43566c)
                            : const Color(0xff9cadc1),
                      ),
                    ),
                    Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
