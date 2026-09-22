// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Who this node is not hearing from, and why (Phase 4 P4.1). Two sections,
// because they are two different things and must never be mistaken for each
// other:
//
//   - PEOPLE YOU BLOCKED. Your own choice, local, reversible by you here.
//   - LIMITED BY A COMMUNITY DECISION. A standing ceiling from an authority —
//     a polity expelling a member. Not yours to lift from this screen, and this
//     is the only place the ceiling is legible as itself rather than as a low
//     tier.

import 'package:flutter/material.dart';

import '../ffi/at_peer.dart';
import '../node/peer_stream.dart';

class BlockedListPage extends StatelessWidget {
  const BlockedListPage({super.key, required this.service});

  final PeerService service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked and limited')),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final blocked = service.blockedPeers;
          final bounded = service.standingBoundedPeers;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const _Header('People you blocked'),
              if (blocked.isEmpty)
                const _Empty('You have not blocked anyone.')
              else
                for (final p in blocked)
                  ListTile(
                    key: Key('blocked-${p.shortId}'),
                    leading: const Icon(Icons.block),
                    title: Text(p.displayLabel),
                    subtitle:
                        const Text('Only on this device. They were not told.'),
                    trailing: TextButton(
                      key: Key('unblock-${p.shortId}'),
                      onPressed: () => _unblock(context, p),
                      child: const Text('Unblock'),
                    ),
                  ),
              const Divider(),
              const _Header('Limited by a community decision'),
              if (bounded.isEmpty)
                const _Empty('No one you can see is limited by a community.')
              else
                for (final p in bounded)
                  ListTile(
                    key: Key('bounded-${p.shortId}'),
                    leading: const Icon(Icons.gavel_outlined),
                    title: Text(p.displayLabel),
                    subtitle: Text(
                      'A community they belonged to removed them. Their '
                      'standing is capped at '
                      '${p.standingCeiling.toStringAsFixed(2)} until that '
                      'community reinstates them.',
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }

  void _unblock(BuildContext context, AgoraPeer peer) {
    final rc = service.unblockPeer(peer);
    final msg = rc == 0
        ? 'Unblocked ${peer.displayLabel}'
        : (rc == -2 ? 'Not connected yet' : 'Could not unblock');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      );
}
