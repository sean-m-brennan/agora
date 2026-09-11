// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Unit tests for the tie-strength kernel (Increment 4, SOCIAL_APP_PLAN.md §3.2).
// Pure and deterministic — no daemon, no FFI.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/model/tie_strength.dart';

AgoraPeer _peer({
  double repScore = 0,
  bool repRated = false,
  String geohash = '',
  int rttMs = 0,
  double attestedAt = 0,
}) {
  final p = AgoraPeer(uuid: List<int>.filled(16, 0x11));
  p.reputationScore = repScore;
  p.reputationRated = repRated;
  p.geohash = geohash;
  p.rttMs = rttMs;
  p.operatorAttestedAt = attestedAt;
  return p;
}

void main() {
  const w = TieStrengthWeights.defaults;

  group('trustTierForScore (floors mirror rep_proc.c TIER_FLOORS)', () {
    test('unrated is always tier 0', () {
      expect(trustTierForScore(0.99, false), 0);
    });
    test('below the first floor is tier 0', () {
      expect(trustTierForScore(0.49, true), 0);
    });
    test('each floor promotes exactly one tier', () {
      expect(trustTierForScore(0.50, true), 1);
      expect(trustTierForScore(0.64, true), 1);
      expect(trustTierForScore(0.65, true), 2);
      expect(trustTierForScore(0.79, true), 2);
      expect(trustTierForScore(0.80, true), 3);
      expect(trustTierForScore(0.89, true), 3);
      expect(trustTierForScore(0.90, true), 4);
      expect(trustTierForScore(1.00, true), 4);
    });
  });

  group('proximityFactor', () {
    test('same shared bucket ⇒ p ≈ 1', () {
      final p = _peer(geohash: 'u4pruy');
      expect(proximityFactor(p, 'u4pruy'), closeTo(1.0, 0.02));
    });
    test('a few km apart ⇒ exp(-d/d0), well below 1', () {
      final p = _peer(geohash: 'u4prv0');
      final f = proximityFactor(p, 'u4pruy'); // ~4 km, d0=2 km ⇒ ~0.13
      expect(f, lessThan(0.4));
      expect(f, greaterThan(0.0));
    });
    test('no shared bucket falls back to RTT proximity', () {
      final p = _peer(rttMs: 50); // exp(-50/100) ≈ 0.607
      expect(proximityFactor(p, null), closeTo(math.exp(-0.5), 0.001));
    });
    test('neither position nor RTT ⇒ 0 (cannot place ⇒ not near)', () {
      expect(proximityFactor(_peer(), null), 0.0);
    });
    test('one-sided position (own opted out) uses RTT, not distance', () {
      final p = _peer(geohash: 'u4pruy', rttMs: 100);
      expect(proximityFactor(p, null), closeTo(math.exp(-1.0), 0.001));
    });
  });

  group('recencyFactor (Phase-1 stand-in)', () {
    test('never attended ⇒ 0', () {
      expect(recencyFactor(_peer(attestedAt: 0), 1000), 0.0);
    });
    test('attended right now ⇒ 1', () {
      expect(recencyFactor(_peer(attestedAt: 1000), 1000), closeTo(1.0, 1e-9));
    });
    test('decays with age', () {
      const now = 1000000.0;
      final recent = recencyFactor(_peer(attestedAt: now - 3600), now);
      final old = recencyFactor(_peer(attestedAt: now - 3600 * 48), now);
      expect(recent, greaterThan(old));
      expect(old, greaterThan(0.0));
    });
  });

  group('tieStrength', () {
    test('a local, tended, trusted peer scores near 1', () {
      const now = 1000000.0;
      final p = _peer(
        repScore: 0.95, // tier 4 ⇒ tierTerm 1
        repRated: true,
        geohash: 'u4pruy', // same bucket ⇒ proximity ~1
        attestedAt: now, // recency ~1
      );
      final s = tieStrength(p, ownGeohash: 'u4pruy', nowEpochSeconds: now);
      expect(s, closeTo(w.wTier + w.wRecency + w.wProximity, 0.03));
    });

    test('a distant, unrated, absent peer scores ~0', () {
      final p = _peer(); // nothing known
      expect(tieStrength(p, ownGeohash: 'u4pruy', nowEpochSeconds: 1000),
          closeTo(0.0, 1e-9));
    });

    test('proximity makes a closer peer stronger, all else equal', () {
      const now = 1000000.0;
      final near = _peer(repScore: 0.9, repRated: true, geohash: 'u4pruy', attestedAt: now);
      final far = _peer(repScore: 0.9, repRated: true, geohash: 'u4prv0', attestedAt: now);
      final sNear = tieStrength(near, ownGeohash: 'u4pruy', nowEpochSeconds: now);
      final sFar = tieStrength(far, ownGeohash: 'u4pruy', nowEpochSeconds: now);
      expect(sNear, greaterThan(sFar));
    });

    test('stays within [0,1] even with custom non-normalized weights', () {
      const heavy = TieStrengthWeights(wTier: 2, wRecency: 2, wProximity: 2);
      const now = 1000000.0;
      final p = _peer(repScore: 1, repRated: true, geohash: 'u4pruy', attestedAt: now);
      final s = tieStrength(p, ownGeohash: 'u4pruy', nowEpochSeconds: now, weights: heavy);
      expect(s, lessThanOrEqualTo(1.0));
      expect(s, greaterThanOrEqualTo(0.0));
    });
  });
}
