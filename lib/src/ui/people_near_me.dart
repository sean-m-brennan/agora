// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Phase-0 "People near me" view. Shows each observed peer's short id, rank,
// operator-attended presence, and reputation. Profile and distance are shown
// as explicitly pending AT-core support (see SOCIAL_APP_PLAN.md §5.1).

import 'package:flutter/material.dart';

import '../node/peer_stream.dart';
import '../ffi/at_peer.dart';

class PeopleNearMePage extends StatelessWidget {
  const PeopleNearMePage({super.key, required this.service});

  final PeerService service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('People near me')),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final peers = service.peers;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _PendingCapabilitiesBanner(),
              _StatusBar(status: service.status, count: peers.length),
              Expanded(
                child: peers.isEmpty
                    ? const Center(
                        child: Text('No peers observed yet…'),
                      )
                    : ListView.separated(
                        itemCount: peers.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) => _PeerTile(peer: peers[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer});

  final AgoraPeer peer;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final present = peer.operatorBound && peer.operatorAttestedAt > 0;
    return ListTile(
      leading: Icon(
        present ? Icons.circle : Icons.circle_outlined,
        size: 14,
        color: present ? Colors.green : Theme.of(context).disabledColor,
      ),
      title: Text(peer.shortId, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Text(peer.presenceLabel(now)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('rank ${peer.rank}'),
          Text('rep ${peer.reputationLabel}',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.status, required this.count});

  final String status;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(child: Text('Status: $status')),
          Text('$count peer${count == 1 ? '' : 's'}'),
        ],
      ),
    );
  }
}

class _PendingCapabilitiesBanner extends StatelessWidget {
  const _PendingCapabilitiesBanner();

  @override
  Widget build(BuildContext context) {
    return const MaterialBanner(
      content: Text(
        'Profile and distance are not shown yet: the AutonomousTrust C event '
        'surface does not expose agora.profile or peer position. Presence and '
        'reputation are live. (SOCIAL_APP_PLAN.md §5.1)',
      ),
      leading: Icon(Icons.info_outline),
      actions: [SizedBox.shrink()],
    );
  }
}
