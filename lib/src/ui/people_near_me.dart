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
      appBar: AppBar(
        title: const Text('People near me'),
        actions: [
          ListenableBuilder(
            listenable: service,
            builder: (context, _) {
              final sharing = service.ownGeohash != null;
              return IconButton(
                icon: Icon(sharing ? Icons.location_on : Icons.location_off),
                tooltip: sharing
                    ? 'Sharing location (~5 km bucket) — tap to change'
                    : 'Location not shared — tap to opt in',
                onPressed: () => _editOwnPosition(context, service),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final peers = service.peers;
          final own = service.ownGeohash;
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
                        itemBuilder: (context, i) =>
                            _PeerTile(peer: peers[i], ownGeohash: own),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Opt in (enter a coarse geohash bucket) or out (clear) of sharing location.
  /// Strictly opt-in: closing without sharing changes nothing.
  Future<void> _editOwnPosition(BuildContext context, PeerService service) async {
    final controller = TextEditingController(text: service.ownGeohash ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share coarse location'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Opt in to share a ~5 km geohash bucket with connected peers only. '
              'This is a coarse area, not your exact location, and is never '
              'broadcast. Leave empty (or Stop sharing) to opt out.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Geohash bucket (e.g. 9q8yy)',
                hintText: '~5 chars',
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, '__optout__'),
            child: const Text('Stop sharing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Share'),
          ),
        ],
      ),
    );
    if (result == null) return; // cancelled — no change
    service.setOwnPosition(result == '__optout__' ? null : result);
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, this.ownGeohash});

  final AgoraPeer peer;
  final String? ownGeohash;

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
          Text('rtt ${peer.rttLabel}',
              style: Theme.of(context).textTheme.bodySmall),
          Text('dist ${peer.distanceLabel(ownGeohash)}',
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
        'Presence, reputation, RTT, and opt-in distance are live. RTT is a '
        'network-latency proxy (ms); distance is a coarse (~5 km) geographic '
        'estimate shown only when BOTH you and the peer opt in (tap the '
        'location icon). Profile fields (agora.profile) are not shown yet. '
        '(SOCIAL_APP_PLAN.md §5.1)',
      ),
      leading: Icon(Icons.info_outline),
      actions: [SizedBox.shrink()],
    );
  }
}
