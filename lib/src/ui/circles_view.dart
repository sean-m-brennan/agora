// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The nested-circles view (Phase 2, SOCIAL_APP_PLAN.md §3.4): the roster grouped
// into the Dunbar layers (support / sympathy / band / active / acquaintance /
// recognition), each showing its size against its Dunbar target so an over-full
// inner circle is visible. Circles are DERIVED and display-only — the connection
// edge stays the sole consent; this only labels the trust tiers that exist.

import 'package:flutter/material.dart' hide ConnectionState;

import '../ffi/at_peer.dart';
import '../model/circles.dart';
import '../node/peer_stream.dart';

class CirclesPage extends StatelessWidget {
  const CirclesPage({super.key, required this.service});

  final PeerService service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Circles')),
      body: ListenableBuilder(
        listenable: service,
        // service.peers is tie-strength ranked; grouping preserves that order,
        // so each circle stays ranked strongest-first.
        builder: (context, _) {
          final grouping = CircleGrouping.from(service.peers);
          return ListView(
            children: [
              const _CirclesLegend(),
              for (final circle in DunbarCircle.values)
                _CircleSection(
                  circle: circle,
                  peers: grouping.peersIn(circle),
                  overTarget: grouping.overTarget(circle),
                  service: service,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CirclesLegend extends StatelessWidget {
  const _CirclesLegend();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        'Your graph in nested Dunbar circles (§3.4). Each layer shows its size '
        'against its natural target; an over-full inner circle is the sign a '
        'layer is stretched. Circles are derived from trust tier — connecting is '
        'still the only consent.',
        style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
      ),
    );
  }
}

class _CircleSection extends StatelessWidget {
  const _CircleSection({
    required this.circle,
    required this.peers,
    required this.overTarget,
    required this.service,
  });

  final DunbarCircle circle;
  final List<AgoraPeer> peers;
  final bool overTarget;
  final PeerService service;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: scheme.surfaceContainerHighest,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(circle.label,
                        style:
                            const TextStyle(fontWeight: FontWeight.bold)),
                    Text(circle.blurb,
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              _CountBadge(
                  count: peers.length,
                  target: circle.targetSize,
                  overTarget: overTarget),
            ],
          ),
        ),
        if (peers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('—',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          )
        else
          for (final peer in peers)
            ListTile(
              dense: true,
              title: Text(peer.displayLabel),
              subtitle: Text(peer.shortId),
              trailing: Text(
                'tie ${service.strengthOf(peer).toStringAsFixed(2)}',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
        const Divider(height: 1),
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.count,
    required this.target,
    required this.overTarget,
  });

  final int count;
  final int target;
  final bool overTarget;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: overTarget ? scheme.errorContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$count / $target',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color:
              overTarget ? scheme.onErrorContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
