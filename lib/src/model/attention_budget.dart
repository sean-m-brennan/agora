// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The attention budget (Phase 2, SOCIAL_APP_PLAN.md §3.3) — the mechanism that
// makes Dunbar's ~150 EMERGE instead of being hard-capped. We do not cap the
// friend list; instead each node has a finite attention budget B, and holding a
// *strong* tie costs budget in proportion to how much work distance and neglect
// imply:
//
//     cost(edge) = base_cost · (1 / p(d)) · (1 / recency)
//
// A local, frequently-tended tie costs ≈ base_cost, so B affords ≈ B/base_cost
// of them — B is tuned so that number lands near 150 (the active network). A
// distant or neglected tie costs multiples of that, so only a handful are
// affordable — exactly how real long-distance friendships work: rare and
// effortful. The budget is EMERGENT, not decreed.
//
// Over-budget behaviour is ADVISORY ONLY (locked decision): we surface a
// "stretched" state and flag the weakest strong ties so they fade / de-rank, but
// nothing is ever severed automatically — the user lets a tie decay, or does not.
// This mirrors AT's "ratify emergence, don't replace it."
//
// Everything here is pure and deterministic given its inputs (it reuses the
// tie-strength kernel's proximity/recency factors), so it is unit tested
// directly without the daemon or FFI.

import '../ffi/at_peer.dart';
import 'tie_strength.dart';

/// Tunable parameters for the attention budget. Per-user and persisted
/// (see `tie_settings.dart`); these are the defaults, calibrated so that ~150
/// local, tended strong ties consume the whole budget.
class AttentionBudgetParams {
  const AttentionBudgetParams({
    this.budget = 150.0,
    this.baseCost = 1.0,
    this.proximityFloor = 0.02,
    this.recencyFloor = 0.02,
    this.strongTieMinStrength = 0.5,
  });

  /// The total attention budget B. A local, tended tie costs ≈ [baseCost], so
  /// B / baseCost is the number of such ties the node can afford — the knee that
  /// lands near Dunbar's ~150 with the defaults.
  final double budget;

  /// The cost of one ideal (co-located, freshly-tended) strong tie.
  final double baseCost;

  /// Floor on the proximity factor p(d) when inverting it, so a peer we cannot
  /// place (p → 0) yields a large-but-finite cost rather than infinity.
  final double proximityFloor;

  /// Floor on the recency factor when inverting it — same rationale for a long-
  /// neglected tie.
  final double recencyFloor;

  /// Minimum tie strength S for a *connected* peer to count as a strong tie that
  /// spends budget. Below this a connection is held but not "strong".
  final double strongTieMinStrength;

  static const AttentionBudgetParams defaults = AttentionBudgetParams();

  AttentionBudgetParams copyWith({
    double? budget,
    double? baseCost,
    double? proximityFloor,
    double? recencyFloor,
    double? strongTieMinStrength,
  }) =>
      AttentionBudgetParams(
        budget: budget ?? this.budget,
        baseCost: baseCost ?? this.baseCost,
        proximityFloor: proximityFloor ?? this.proximityFloor,
        recencyFloor: recencyFloor ?? this.recencyFloor,
        strongTieMinStrength: strongTieMinStrength ?? this.strongTieMinStrength,
      );
}

/// The budget cost of maintaining a strong tie to [peer], from this node's
/// viewpoint. `cost = base_cost · (1/p(d)) · (1/recency)`, with p(d) and recency
/// floored so the result is always finite. Cost ≥ baseCost always.
double edgeCost(
  AgoraPeer peer, {
  required String? ownGeohash,
  required double nowEpochSeconds,
  TieStrengthWeights weights = TieStrengthWeights.defaults,
  AttentionBudgetParams params = AttentionBudgetParams.defaults,
}) {
  final p = proximityFactor(peer, ownGeohash, weights: weights)
      .clamp(params.proximityFloor, 1.0);
  final r = recencyFactor(peer, nowEpochSeconds, weights: weights)
      .clamp(params.recencyFloor, 1.0);
  return params.baseCost * (1.0 / p) * (1.0 / r);
}

/// One strong tie's contribution to the budget: the peer, its cost, its tie
/// strength S, and whether it sits *beyond* the budget line (the marginal,
/// weakest ties the node cannot afford when [BudgetLedger.isStretched]).
class TieCost {
  const TieCost({
    required this.peer,
    required this.cost,
    required this.strength,
    required this.overBudget,
  });

  final AgoraPeer peer;
  final double cost;
  final double strength;

  /// True when accumulating cost strongest-tie-first, this tie is the one that
  /// pushed cumulative spend past the budget (or came after). These are the ties
  /// the UI fades / de-ranks — never severed.
  final bool overBudget;
}

/// The spent-budget ledger over a node's strong ties (§3.3). Pure: computed from
/// the peer list, this node's own bucket, and the current time.
class BudgetLedger {
  const BudgetLedger._({
    required this.spent,
    required this.budget,
    required this.ties,
  });

  /// Total budget consumed by all strong ties.
  final double spent;

  /// The attention budget B in force.
  final double budget;

  /// Per-strong-tie costs, ordered STRONGEST first (the order in which budget is
  /// allocated). Weakest ties therefore appear last and are the first flagged
  /// [TieCost.overBudget].
  final List<TieCost> ties;

  /// The node is over its budget — more strong ties than B affords.
  bool get isStretched => spent > budget;

  /// Remaining budget (negative when stretched).
  double get headroom => budget - spent;

  /// Fraction of budget consumed (0..∞; ≥1 when stretched).
  double get utilization => budget <= 0 ? 0 : spent / budget;

  /// Count of strong ties.
  int get strongTieCount => ties.length;

  /// The weakest strong ties the node cannot afford (over the budget line),
  /// ordered weakest first — what the UI fades.
  List<TieCost> get overBudgetTies =>
      ties.where((t) => t.overBudget).toList().reversed.toList();

  /// Build the ledger. A *strong tie* is a connected peer whose tie strength
  /// S ≥ [AttentionBudgetParams.strongTieMinStrength]. Budget is allocated
  /// strongest-first; ties whose cumulative cost exceeds B are flagged
  /// [TieCost.overBudget]. Held-but-not-strong connections do not spend budget.
  static BudgetLedger compute(
    Iterable<AgoraPeer> peers, {
    required String? ownGeohash,
    required double nowEpochSeconds,
    TieStrengthWeights weights = TieStrengthWeights.defaults,
    AttentionBudgetParams params = AttentionBudgetParams.defaults,
  }) {
    final strong = <_Scored>[];
    for (final peer in peers) {
      if (!peer.isConnected) continue;
      final s = tieStrength(
        peer,
        ownGeohash: ownGeohash,
        nowEpochSeconds: nowEpochSeconds,
        weights: weights,
      );
      if (s < params.strongTieMinStrength) continue;
      final cost = edgeCost(
        peer,
        ownGeohash: ownGeohash,
        nowEpochSeconds: nowEpochSeconds,
        weights: weights,
        params: params,
      );
      strong.add(_Scored(peer, cost, s));
    }
    // Allocate budget strongest-first so the ties you can't afford are the
    // weakest ones.
    strong.sort((a, b) => b.strength.compareTo(a.strength));
    var running = 0.0;
    var total = 0.0;
    final ties = <TieCost>[];
    for (final sc in strong) {
      running += sc.cost;
      total += sc.cost;
      ties.add(TieCost(
        peer: sc.peer,
        cost: sc.cost,
        strength: sc.strength,
        overBudget: running > params.budget,
      ));
    }
    return BudgetLedger._(spent: total, budget: params.budget, ties: ties);
  }
}

class _Scored {
  _Scored(this.peer, this.cost, this.strength);
  final AgoraPeer peer;
  final double cost;
  final double strength;
}
