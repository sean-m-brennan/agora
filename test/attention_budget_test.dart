// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Unit tests for the attention budget (Phase 2, SOCIAL_APP_PLAN.md §3.3). Pure
// and deterministic — no daemon, no FFI. The load-bearing test is the
// calibration one: with the default params the budget knee lands at ~150 ideal
// (co-located, freshly-tended) strong ties, so Dunbar emerges rather than being
// hard-capped.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/model/attention_budget.dart';

const double _now = 1000000000.0;
const String _here = 'u4pruy'; // this node's own bucket

/// A connected peer. [connected] false leaves it merely observed.
AgoraPeer _peer({
  String geohash = '',
  double lastInteractionAt = 0,
  double repScore = 0,
  bool repRated = false,
  bool connected = true,
  int seed = 0x11,
}) {
  final p = AgoraPeer(uuid: List<int>.filled(16, seed));
  p.geohash = geohash;
  p.lastInteractionAt = lastInteractionAt;
  p.reputationScore = repScore;
  p.reputationRated = repRated;
  p.connectionState = connected ? 3 : 0; // 3 = connected
  return p;
}

/// The ideal strong tie: connected, co-located, tended right now.
AgoraPeer _idealTie({int seed = 0x22}) =>
    _peer(geohash: _here, lastInteractionAt: _now, seed: seed);

void main() {
  const params = AttentionBudgetParams.defaults;

  group('edgeCost', () {
    test('an ideal (co-located, tended) tie costs ≈ base_cost', () {
      final c = edgeCost(_idealTie(),
          ownGeohash: _here, nowEpochSeconds: _now, params: params);
      expect(c, closeTo(params.baseCost, 1e-9));
    });

    test('an unplaceable peer costs more, but stays finite (floored)', () {
      final c = edgeCost(_peer(lastInteractionAt: _now),
          ownGeohash: _here, nowEpochSeconds: _now, params: params);
      // p(d) → 0 floored to proximityFloor ⇒ cost = base/floor, finite.
      expect(c, closeTo(params.baseCost / params.proximityFloor, 1e-6));
      expect(c.isFinite, isTrue);
      expect(c, greaterThan(params.baseCost));
    });

    test('a long-neglected local tie costs more (recency discount)', () {
      final stale = _peer(geohash: _here, lastInteractionAt: _now - 86400 * 30);
      final c = edgeCost(stale,
          ownGeohash: _here, nowEpochSeconds: _now, params: params);
      expect(c, greaterThan(params.baseCost));
      expect(c.isFinite, isTrue);
    });
  });

  group('BudgetLedger.compute', () {
    test('only connected strong ties spend budget', () {
      final peers = [
        _idealTie(seed: 1), // strong
        _peer(geohash: _here, lastInteractionAt: _now, connected: false), // not connected
        _peer(connected: true, lastInteractionAt: 0, seed: 3), // connected but weak (S<0.5)
      ];
      final l = BudgetLedger.compute(peers,
          ownGeohash: _here, nowEpochSeconds: _now, params: params);
      expect(l.strongTieCount, 1);
      expect(l.spent, closeTo(params.baseCost, 1e-9));
      expect(l.isStretched, isFalse);
    });

    test('spent is the sum of strong-tie costs', () {
      final peers = List.generate(10, (i) => _idealTie(seed: i + 1));
      final l = BudgetLedger.compute(peers,
          ownGeohash: _here, nowEpochSeconds: _now, params: params);
      expect(l.spent, closeTo(10 * params.baseCost, 1e-9));
      expect(l.utilization, closeTo(10 / params.budget, 1e-9));
    });

    test('over budget flags the weakest ties, strongest kept, none severed', () {
      // Custom small budget so a handful of ties exceeds it. Strongest = rated
      // high (higher S); weakest = unrated. All co-located & tended so they are
      // all strong (S ≥ 0.5) and cost ≈ base_cost each.
      final tight = params.copyWith(budget: 3.0);
      final strongest = _peer(
          geohash: _here, lastInteractionAt: _now, repScore: 0.95, repRated: true, seed: 9);
      final peers = [
        strongest,
        _idealTie(seed: 1),
        _idealTie(seed: 2),
        _idealTie(seed: 3),
        _idealTie(seed: 4),
      ];
      final l = BudgetLedger.compute(peers,
          ownGeohash: _here, nowEpochSeconds: _now, params: tight);
      expect(l.isStretched, isTrue);
      expect(l.strongTieCount, 5); // nothing severed — all still present
      // Budget 3, each costs ~1 ⇒ first 3 within, last 2 over.
      expect(l.ties.where((t) => t.overBudget).length, 2);
      // The strongest tie is allocated first, never flagged over-budget.
      expect(l.ties.first.peer, same(strongest));
      expect(l.ties.first.overBudget, isFalse);
    });
  });

  group('Dunbar calibration (the §3.3 knee)', () {
    test('~150 ideal local ties fill the budget; 151 stretch it', () {
      final at150 = List.generate(150, (i) => _idealTie(seed: (i % 200) + 1));
      final l150 = BudgetLedger.compute(at150,
          ownGeohash: _here, nowEpochSeconds: _now, params: params);
      expect(l150.strongTieCount, 150);
      expect(l150.spent, closeTo(150 * params.baseCost, 1e-6));
      expect(l150.isStretched, isFalse); // exactly affordable

      final at151 = List.generate(151, (i) => _idealTie(seed: (i % 200) + 1));
      final l151 = BudgetLedger.compute(at151,
          ownGeohash: _here, nowEpochSeconds: _now, params: params);
      expect(l151.isStretched, isTrue);
      expect(l151.overBudgetTies.length, 1);
    });

    test('distant ties are costlier, so far fewer than 150 are affordable', () {
      // A distant tie is only STRONG (S ≥ 0.5) when reputation carries it — the
      // rare, effortful long-distance friendship. High-rep + tended but
      // unplaceable ⇒ S ≈ 0.7, cost = base/proximityFloor = 50× each.
      final distant = List.generate(
          10,
          (i) => _peer(
              lastInteractionAt: _now, repScore: 0.95, repRated: true, seed: i + 1));
      final l = BudgetLedger.compute(distant,
          ownGeohash: _here, nowEpochSeconds: _now, params: params);
      expect(l.strongTieCount, 10);
      // 10 distant ties already blow past a budget that holds 150 local ones.
      final affordable = params.budget / (params.baseCost / params.proximityFloor);
      expect(affordable, lessThan(10)); // can afford only ~3
      expect(l.isStretched, isTrue);
    });
  });
}
