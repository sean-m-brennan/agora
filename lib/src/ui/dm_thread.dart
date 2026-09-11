// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// DmThreadPage: a one-to-one direct-message thread (Increment 6). Incoming
// messages (from the peer, sender-authenticated by the core) render on the left;
// outgoing (locally echoed at send time) on the right. A compose field sends a
// new DM through PeerService.sendDm. A DM is one-way and ENCRYPTED; there is no
// delivery receipt, so an outgoing bubble means "sent", not "read".

import 'package:flutter/material.dart' hide ConnectionState;

import '../ffi/at_peer.dart';
import '../model/dm.dart';
import '../node/peer_stream.dart';

class DmThreadPage extends StatefulWidget {
  const DmThreadPage({super.key, required this.peer, required this.service});

  final AgoraPeer peer;
  final PeerService service;

  @override
  State<DmThreadPage> createState() => _DmThreadPageState();
}

class _DmThreadPageState extends State<DmThreadPage> {
  final TextEditingController _compose = TextEditingController();

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.peer.displayLabel)),
      body: Column(
        children: [
          Expanded(
            child: AnimatedBuilder(
              animation: widget.service,
              builder: (context, _) {
                final messages = widget.service.messagesFor(widget.peer);
                if (messages.isEmpty) {
                  return const Center(
                    child: Text('No messages yet — say hello.'),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: messages.length,
                  itemBuilder: (context, i) => _MessageBubble(msg: messages[i]),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
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
    );
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
