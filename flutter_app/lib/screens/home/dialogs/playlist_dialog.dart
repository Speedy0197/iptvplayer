import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../services/playlist_store.dart';

Future<void> showPlaylistDialog(
  BuildContext context, {
  Playlist? editing,
}) async {
  final successMessage = await showDialog<String>(
    context: context,
    builder: (ctx) {
      return _PlaylistDialog(editing: editing);
    },
  );

  if (successMessage != null && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(successMessage)));
  }
}

class _PlaylistDialog extends StatefulWidget {
  final Playlist? editing;

  const _PlaylistDialog({required this.editing});

  @override
  State<_PlaylistDialog> createState() => _PlaylistDialogState();
}

class _PlaylistDialogState extends State<_PlaylistDialog> {
  late final TextEditingController nameCtrl;
  late final TextEditingController epgUrlCtrl;
  late final TextEditingController m3uUrlCtrl;
  late final TextEditingController xtreamServerCtrl;
  late final TextEditingController xtreamUserCtrl;
  late final TextEditingController xtreamPassCtrl;
  late final TextEditingController vuplusIpCtrl;
  late final TextEditingController vuplusPortCtrl;

  late String selectedType;
  late String m3uSource;
  String? m3uContent;
  String? m3uFileName;
  String? error;
  String? vuplusDiscoveryStatus;
  bool submitting = false;
  bool discoveringVuplus = false;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    nameCtrl = TextEditingController(text: editing?.name ?? '');
    epgUrlCtrl = TextEditingController(text: editing?.epgUrl ?? '');
    m3uUrlCtrl = TextEditingController(text: editing?.m3uUrl ?? '');
    xtreamServerCtrl = TextEditingController(text: editing?.xtreamServer ?? '');
    xtreamUserCtrl = TextEditingController(text: editing?.xtreamUsername ?? '');
    xtreamPassCtrl = TextEditingController();
    vuplusIpCtrl = TextEditingController(text: editing?.vuplusIp ?? '');
    vuplusPortCtrl = TextEditingController(text: editing?.vuplusPort ?? '80');

    selectedType = editing?.type ?? 'xtream';
    m3uSource = editing?.type == 'm3u' && ((editing?.m3uUrl ?? '').isEmpty)
        ? 'file'
        : 'url';
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    epgUrlCtrl.dispose();
    m3uUrlCtrl.dispose();
    xtreamServerCtrl.dispose();
    xtreamUserCtrl.dispose();
    xtreamPassCtrl.dispose();
    vuplusIpCtrl.dispose();
    vuplusPortCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isSmallDevice = media.size.width < 640;

    return Dialog(
      insetPadding: isSmallDevice
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 12)
          : const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isSmallDevice ? media.size.width - 24 : 520,
          maxHeight: isSmallDevice ? media.size.height * 0.92 : 560,
        ),
        child: SafeArea(
          top: isSmallDevice,
          bottom: isSmallDevice,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              isSmallDevice ? 16 : 20,
              isSmallDevice ? 16 : 20,
              isSmallDevice ? 16 : 20,
              isSmallDevice ? 12 : 16,
            ),
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.editing == null
                              ? 'Add playlist'
                              : 'Edit playlist',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        onPressed: submitting
                            ? null
                            : () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: 'Close',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'xtream', label: Text('Xtream')),
                      ButtonSegment(value: 'vuplus', label: Text('VU+')),
                      ButtonSegment(value: 'm3u', label: Text('M3U')),
                    ],
                    selected: {selectedType},
                    onSelectionChanged: widget.editing != null
                        ? null
                        : (next) {
                            setState(() {
                              selectedType = next.first;
                              error = null;
                            });
                          },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Name'),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 8),
                  if (selectedType == 'm3u')
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: 'url', label: Text('URL')),
                            ButtonSegment(
                              value: 'file',
                              label: Text('File Upload'),
                            ),
                          ],
                          selected: {m3uSource},
                          onSelectionChanged: (next) {
                            setState(() {
                              m3uSource = next.first;
                              error = null;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        if (m3uSource == 'url')
                          TextField(
                            controller: m3uUrlCtrl,
                            decoration: const InputDecoration(
                              labelText: 'M3U URL',
                            ),
                          )
                        else ...[
                          OutlinedButton.icon(
                            onPressed: () async {
                              final result = await FilePicker.platform
                                  .pickFiles(
                                    type: FileType.custom,
                                    allowedExtensions: const [
                                      'm3u',
                                      'm3u8',
                                      'txt',
                                    ],
                                    withData: true,
                                  );
                              if (result == null || result.files.isEmpty) {
                                return;
                              }

                              final pickedFile = result.files.first;
                              final bytes = pickedFile.bytes;
                              if (bytes == null || bytes.isEmpty) {
                                setState(() {
                                  error =
                                      'Could not read the selected M3U file';
                                });
                                return;
                              }

                              setState(() {
                                m3uContent = utf8.decode(
                                  bytes,
                                  allowMalformed: true,
                                );
                                m3uFileName = pickedFile.name;
                                error = null;
                              });
                            },
                            icon: const Icon(Icons.upload_file),
                            label: Text(
                              m3uFileName == null
                                  ? 'Choose M3U File'
                                  : 'Replace File',
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              m3uFileName ??
                                  'No file selected. Upload an M3U file from this device.',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ],
                    )
                  else if (selectedType == 'xtream') ...[
                    TextField(
                      controller: xtreamServerCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Xtream server URL',
                        hintText: 'http://provider.example.com:8080',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: xtreamUserCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Xtream username',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: xtreamPassCtrl,
                      decoration: InputDecoration(
                        labelText: widget.editing == null
                            ? 'Xtream password'
                            : 'Xtream password (optional)',
                      ),
                      obscureText: true,
                    ),
                  ] else ...[
                    OutlinedButton.icon(
                      onPressed: submitting || discoveringVuplus
                          ? null
                          : _discoverVuplus,
                      icon: discoveringVuplus
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.travel_explore),
                      label: Text(
                        discoveringVuplus
                            ? 'Searching network...'
                            : 'Auto search VU+ in network',
                      ),
                    ),
                    if (vuplusDiscoveryStatus != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          vuplusDiscoveryStatus!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: vuplusIpCtrl,
                      decoration: const InputDecoration(
                        labelText: 'VU+ IP / host',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: vuplusPortCtrl,
                      decoration: const InputDecoration(labelText: 'VU+ port'),
                    ),
                  ],
                  if (selectedType != 'vuplus') ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: epgUrlCtrl,
                      decoration: const InputDecoration(
                        labelText: 'EPG XMLTV URL (optional)',
                        hintText: 'https://example.com/epg.xml',
                      ),
                    ),
                  ],
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                        onPressed: submitting
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: submitting ? null : _submit,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (submitting) ...[
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Text(
                                submitting
                                    ? (widget.editing == null
                                          ? 'Creating...'
                                          : 'Saving...')
                                    : (widget.editing == null
                                          ? 'Create'
                                          : 'Save'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    setState(() {
      submitting = true;
      error = null;
    });

    try {
      final store = context.read<PlaylistStore>();
      final name = nameCtrl.text.trim();
      final epgUrl = selectedType == 'vuplus' ? null : epgUrlCtrl.text.trim();
      if (name.isEmpty) {
        throw const ApiException('Name is required');
      }

      if (selectedType == 'm3u') {
        if (m3uSource == 'url' && m3uUrlCtrl.text.trim().isEmpty) {
          throw const ApiException('M3U URL is required');
        }
        if (m3uSource == 'file' &&
            (m3uContent == null || m3uContent!.trim().isEmpty)) {
          throw const ApiException('Please choose an M3U file');
        }
      }

      if (widget.editing == null) {
        if (selectedType == 'm3u') {
          await store.createM3uPlaylist(
            name: name,
            m3uUrl: m3uSource == 'url' ? m3uUrlCtrl.text.trim() : null,
            m3uContent: m3uSource == 'file' ? m3uContent : null,
            epgUrl: epgUrl,
          );
        } else if (selectedType == 'xtream') {
          await store.createXtreamPlaylist(
            name: name,
            server: xtreamServerCtrl.text.trim(),
            username: xtreamUserCtrl.text.trim(),
            password: xtreamPassCtrl.text,
            epgUrl: epgUrl,
          );
        } else {
          await store.createVuplusPlaylist(
            name: name,
            ip: vuplusIpCtrl.text.trim(),
            port: vuplusPortCtrl.text.trim().isEmpty
                ? '80'
                : vuplusPortCtrl.text.trim(),
          );
        }
      } else {
        await store.updatePlaylist(
          id: widget.editing!.id,
          type: selectedType,
          name: name,
          m3uUrl: selectedType == 'm3u' && m3uSource == 'url'
              ? m3uUrlCtrl.text.trim()
              : null,
          m3uContent: selectedType == 'm3u' && m3uSource == 'file'
              ? m3uContent
              : null,
          xtreamServer: xtreamServerCtrl.text.trim(),
          xtreamUsername: xtreamUserCtrl.text.trim(),
          xtreamPassword: xtreamPassCtrl.text,
          vuplusIp: vuplusIpCtrl.text.trim(),
          vuplusPort: vuplusPortCtrl.text.trim(),
          epgUrl: selectedType == 'vuplus' ? '' : epgUrl,
        );
      }

      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(widget.editing == null ? 'Playlist created' : 'Playlist updated');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => error = 'Could not save playlist');
    } finally {
      if (mounted) {
        setState(() => submitting = false);
      }
    }
  }

  Future<void> _discoverVuplus() async {
    setState(() {
      discoveringVuplus = true;
      error = null;
      vuplusDiscoveryStatus = 'Scanning local network for VU+ devices...';
    });

    try {
      final candidateIps = await _buildCandidateIps();
      if (candidateIps.isEmpty) {
        throw const ApiException('Could not detect local network interface');
      }

      final discovered = await _findVuplus(candidateIps);
      if (!mounted) return;

      if (discovered == null) {
        setState(() {
          vuplusDiscoveryStatus =
              'No VU+ box found. Please enter IP / host manually.';
        });
        return;
      }

      setState(() {
        vuplusIpCtrl.text = discovered.ip;
        vuplusPortCtrl.text = discovered.port;
        if (nameCtrl.text.trim().isEmpty) {
          nameCtrl.text = 'VU+ ${discovered.ip}';
        }
        vuplusDiscoveryStatus =
            'Found VU+ at ${discovered.ip}:${discovered.port}';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        vuplusDiscoveryStatus = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        vuplusDiscoveryStatus =
            'Auto search failed. Please enter IP / host manually.';
      });
    } finally {
      if (mounted) {
        setState(() {
          discoveringVuplus = false;
        });
      }
    }
  }

  Future<List<String>> _buildCandidateIps() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );

    final ordered = <String>[];
    final seen = <String>{};
    final prefixes = <String>{};

    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!_isPrivateIPv4(addr.address)) {
          continue;
        }

        final octets = addr.address.split('.');
        if (octets.length != 4) {
          continue;
        }

        final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
        final host = int.tryParse(octets[3]);
        prefixes.add(prefix);
        if (host == null) {
          continue;
        }

        for (var step = 1; step <= 20; step++) {
          final high = host + step;
          final low = host - step;
          if (high >= 1 && high <= 254) {
            final ip = '$prefix.$high';
            if (seen.add(ip)) {
              ordered.add(ip);
            }
          }
          if (low >= 1 && low <= 254) {
            final ip = '$prefix.$low';
            if (seen.add(ip)) {
              ordered.add(ip);
            }
          }
        }
      }
    }

    if (prefixes.isEmpty) {
      prefixes.addAll(const ['192.168.1', '192.168.0', '10.0.0']);
    }

    for (final prefix in prefixes) {
      for (var host = 1; host <= 254; host++) {
        final ip = '$prefix.$host';
        if (seen.add(ip)) {
          ordered.add(ip);
        }
      }
    }

    return ordered;
  }

  Future<_VuplusDiscoveryResult?> _findVuplus(List<String> candidateIps) async {
    final targets = <_VuplusDiscoveryResult>[
      for (final ip in candidateIps) _VuplusDiscoveryResult(ip: ip, port: '80'),
      for (final ip in candidateIps)
        _VuplusDiscoveryResult(ip: ip, port: '8080'),
    ];

    const batchSize = 24;
    for (var i = 0; i < targets.length; i += batchSize) {
      final end = math.min(i + batchSize, targets.length);
      final batch = targets.sublist(i, end);
      final checks = await Future.wait(batch.map(_isVuplusEndpoint));
      for (var j = 0; j < checks.length; j++) {
        if (checks[j]) {
          return batch[j];
        }
      }
    }

    return null;
  }

  Future<bool> _isVuplusEndpoint(_VuplusDiscoveryResult target) async {
    final candidates = [
      Uri.parse('http://${target.ip}:${target.port}/web/deviceinfo'),
      Uri.parse('http://${target.ip}:${target.port}/web/getservices'),
    ];

    for (final uri in candidates) {
      try {
        final response = await http
            .get(uri)
            .timeout(const Duration(milliseconds: 600));
        if (response.statusCode != 200) {
          continue;
        }
        final body = response.body.toLowerCase();
        if (body.contains('enigma2') ||
            body.contains('<e2deviceinfo') ||
            body.contains('<e2servicelist')) {
          return true;
        }
      } catch (_) {
        // Ignore connection errors while scanning candidates.
      }
    }

    return false;
  }

  bool _isPrivateIPv4(String address) {
    final parts = address.split('.');
    if (parts.length != 4) {
      return false;
    }

    final octets = parts.map(int.tryParse).toList();
    if (octets.any((value) => value == null)) {
      return false;
    }

    final a = octets[0]!;
    final b = octets[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }
}

class _VuplusDiscoveryResult {
  final String ip;
  final String port;

  const _VuplusDiscoveryResult({required this.ip, required this.port});
}
