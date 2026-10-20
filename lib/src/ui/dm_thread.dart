// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// DmThreadPage: a one-to-one direct-message thread (Increment 6). Incoming
// messages (from the peer, sender-authenticated by the core) render on the left;
// outgoing (locally echoed at send time) on the right. A compose field sends a
// new DM through PeerService.sendDm. A DM is one-way and ENCRYPTED; there is no
// delivery receipt, so an outgoing bubble means "sent", not "read".
//
// Files share the thread. Drop files anywhere on it, or pick them with the
// paperclip, and after a confirmation each is OFFERED to the person; nothing
// moves until they accept. A file bubble shows where a transfer is and what
// can be done with it: accept or decline an offer, cancel one under way, and
// open, show or save a file that arrived.

import 'dart:io' show FileSystemEntity, FileSystemEntityType;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart' hide ConnectionState;

import '../ffi/at_peer.dart';
import '../model/dm.dart';
import '../model/file_transfer.dart';
import '../node/peer_stream.dart';
import 'file_actions.dart';

class DmThreadPage extends StatefulWidget {
  const DmThreadPage({
    super.key,
    required this.peer,
    required this.service,
    @visibleForTesting this.pickFiles = pickFilesToSend,
  });

  final AgoraPeer peer;
  final PeerService service;

  /// The paperclip's file picker. Tests replace it.
  final Future<List<String>> Function() pickFiles;

  @override
  State<DmThreadPage> createState() => _DmThreadPageState();
}

class _DmThreadPageState extends State<DmThreadPage> {
  final TextEditingController _compose = TextEditingController();
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    // Opening the thread clears its unread flag.
    widget.service.markThreadRead(widget.peer);
  }

  @override
  void dispose() {
    _compose.dispose();
    super.dispose();
  }

  void _send() {
    final text = _compose.text.trim();
    if (text.isEmpty) return;
    widget.service.sendDm(widget.peer, text);
    _compose.clear();
  }

  /// Confirm, then offer each of [paths]. Folders are skipped and said so.
  Future<void> _offer(List<String> paths) async {
    final files = [
      for (final p in paths)
        if (FileSystemEntity.typeSync(p) == FileSystemEntityType.file) p,
    ];
    final skipped = paths.length - files.length;
    final messenger = ScaffoldMessenger.of(context);
    if (files.isEmpty) {
      if (skipped > 0) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Only files can be sent, not folders.')));
      }
      return;
    }
    final who = widget.peer.displayLabel;
    final n = files.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(n == 1 ? 'Send 1 file to $who?' : 'Send $n files to $who?'),
        content: Text([
          for (final p in files) _baseName(p),
          if (skipped > 0) '($skipped folder${skipped == 1 ? '' : 's'} skipped)',
        ].join('\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (ok != true) return;
    var failed = 0;
    for (final p in files) {
      if (widget.service.offerFile(widget.peer, p) != 0) failed++;
    }
    if (failed > 0) {
      messenger.showSnackBar(SnackBar(
          content: Text(failed == n
              ? 'Could not offer ${n == 1 ? 'the file' : 'the files'} — '
                  'is the connection up?'
              : 'Could not offer $failed of $n files.')));
    }
  }

  Future<void> _attach() async {
    final paths = await widget.pickFiles();
    if (!mounted || paths.isEmpty) return;
    await _offer(paths);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.peer.displayLabel)),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (detail) {
          setState(() => _dragging = false);
          _offer([for (final f in detail.files) f.path]);
        },
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: AnimatedBuilder(
                    animation: widget.service,
                    builder: (context, _) {
                      final items = widget.service.threadItems(widget.peer);
                      if (items.isEmpty) {
                        return const Center(
                          child: Text('No messages yet — say hello, or drop a '
                              'file here.'),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final item = items[i];
                          return item.message != null
                              ? _MessageBubble(msg: item.message!)
                              : _FileBubble(
                                  file: item.file!,
                                  peer: widget.peer,
                                  service: widget.service);
                        },
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.attach_file),
                        tooltip: 'Send a file',
                        onPressed: _attach,
                      ),
                      Expanded(
                        child: TextField(
                          controller: _compose,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: 'Message',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.send),
                        tooltip: 'Send',
                        onPressed: _send,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    key: const ValueKey('drop-highlight'),
                    margin: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.6),
                      border: Border.all(color: scheme.primary, width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Drop to send to ${widget.peer.displayLabel}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _baseName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.lastWhere((p) => p.isNotEmpty, orElse: () => path);
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.msg});

  final DmMessage msg;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = msg.outgoing ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    return Align(
      alignment: msg.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(msg.text),
      ),
    );
  }
}

class _FileBubble extends StatelessWidget {
  const _FileBubble(
      {required this.file, required this.peer, required this.service});

  final FileTransfer file;
  final AgoraPeer peer;
  final PeerService service;

  String _status() {
    final who = peer.displayLabel;
    switch (file.state) {
      case FileTransferState.offered:
        return file.outgoing
            ? 'Waiting for $who to accept'
            : '$who wants to send you this file';
      case FileTransferState.accepted:
        return '${humanSize(file.bytesDone)} of ${humanSize(file.size)}';
      case FileTransferState.done:
        return file.outgoing ? 'Sent' : 'Received';
      case FileTransferState.declined:
        return file.outgoing ? '$who declined' : 'Declined';
      case FileTransferState.cancelled:
        return 'Cancelled';
      case FileTransferState.failed:
        return 'Failed${_reasonText(file.reason)}';
      case FileTransferState.tooLarge:
        return 'Too large to receive here';
    }
  }

  static String _reasonText(String reason) => switch (reason) {
        '' => '',
        'hash_mismatch' => ': the file arrived damaged',
        'source_changed' => ': the file changed after it was offered',
        'unreadable' => ': the file could not be read',
        'cannot_write' || 'cannot_place' => ': it could not be saved here',
        'blocked' => '',
        _ => ' ($reason)',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final f = file;
    final bg = f.outgoing ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final actions = <Widget>[
      if (!f.outgoing && f.state == FileTransferState.offered) ...[
        TextButton(
            onPressed: () => service.declineFile(f),
            child: const Text('Decline')),
        FilledButton(
            onPressed: () => service.acceptFile(f),
            child: const Text('Accept')),
      ],
      if (f.state == FileTransferState.accepted ||
          (f.outgoing && f.state == FileTransferState.offered))
        TextButton(
            onPressed: () => service.cancelFile(f), child: const Text('Cancel')),
      if (!f.outgoing && f.state == FileTransferState.done && f.path.isNotEmpty) ...[
        TextButton(
            onPressed: () => openWithSystem(f.path), child: const Text('Open')),
        TextButton(
            onPressed: () => revealInFolder(f.path),
            child: const Text('Show in folder')),
        TextButton(
            onPressed: () => saveCopyAs(f.path, f.name),
            child: const Text('Save as…')),
      ],
    ];
    return Align(
      alignment: f.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.all(10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.insert_drive_file_outlined, size: 20),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(f.name,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                Text(humanSize(f.size), style: theme.textTheme.bodySmall),
              ],
            ),
            if (f.state == FileTransferState.accepted)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SizedBox(
                  width: 220,
                  child: LinearProgressIndicator(value: f.progress),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_status(), style: theme.textTheme.bodySmall),
            ),
            if (actions.isNotEmpty)
              Wrap(spacing: 4, children: actions),
          ],
        ),
      ),
    );
  }
}
