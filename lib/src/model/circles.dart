// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Nested Dunbar circles (Phase 2, SOCIAL_APP_PLAN.md §3.4). Dunbar's layered
// structure (5 / 15 / 50 / 150 / 500 / 1500) maps directly onto the AT trust
// tiers Agora already derives, so circles are LABELS on the machinery that
// exists — not a new consent primitive. A circle assignment is DERIVED and
// display-only: the connection edge (Increment 5) stays the sole consent, and
// the trust tier (from reputation) picks the band. Pure and deterministic, so
// it is unit tested without the daemon.

import '../ffi/at_peer.dart';
import 'tie_strength.dart';

/// The Dunbar layers, innermost (smallest, most trusted) first.
enum DunbarCircle { support, sympathy, band, active, acquaintance, recognition }

const List<int> _targets = [5, 15, 50, 150, 500, 1500];
const List<String> _labels = [
  'Support clique',
  'Sympathy group',
  'Band',
  'Active network',
  'Acquaintance',
  'Recognition',
];
const List<String> _blurbs = [
  'Your innermost few — share freely.',
  'Close ties.',
  'The wider group you keep up with.',
  'Your active network — the Dunbar ~150.',
  'People you know one-off; low, earned trust.',
  'Seen but not admitted — discovery only.',
];

extension DunbarCircleInfo on DunbarCircle {
  /// The Dunbar target size for this layer (5 / 15 / 50 / 150 / 500 / 1500).
  int get targetSize => _targets[index];

  /// Human label for the circle.
  String get label => _labels[index];

  /// One-line description of the circle's meaning.
  String get blurb => _blurbs[index];
}

/// The circle a peer sits in, derived from its connection state and trust tier
/// (§3.4). A peer we have not connected to is only *recognized* (seen, not
/// admitted); a connected peer's tier band picks the inner circle.
DunbarCircle circleForPeer(AgoraPeer peer) {
  if (!peer.isConnected) return DunbarCircle.recognition;
  switch (trustTier(peer)) {
    case 4:
      return DunbarCircle.support;
    case 3:
      return DunbarCircle.sympathy;
    case 2:
      return DunbarCircle.band;
    case 1:
      return DunbarCircle.active;
    default:
      return DunbarCircle.acquaintance; // connected, tier 0
  }
}

/// Peers bucketed into their Dunbar circles, with sizes vs. targets.
class CircleGrouping {
  const CircleGrouping(this._byCircle);

  final Map<DunbarCircle, List<AgoraPeer>> _byCircle;

  /// Peers in [circle] (empty list if none), in the order supplied to [from].
  List<AgoraPeer> peersIn(DunbarCircle circle) =>
      _byCircle[circle] ?? const [];

  /// Number of peers in [circle].
  int countIn(DunbarCircle circle) => peersIn(circle).length;

  /// True when the circle holds more peers than its Dunbar target — the visible
  /// sign that a layer is over-full (advisory; see the attention budget, §3.3).
  bool overTarget(DunbarCircle circle) =>
      countIn(circle) > circle.targetSize;

  /// Bucket [peers] into their circles, preserving the input order within each
  /// (callers pass the tie-strength-ranked roster, so each circle stays ranked).
  static CircleGrouping from(Iterable<AgoraPeer> peers) {
    final m = <DunbarCircle, List<AgoraPeer>>{
      for (final c in DunbarCircle.values) c: <AgoraPeer>[],
    };
    for (final p in peers) {
      m[circleForPeer(p)]!.add(p);
    }
    return CircleGrouping(m);
  }
}
