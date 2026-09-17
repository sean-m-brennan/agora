// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Phase 2 exit artifact (SOCIAL_APP_PLAN.md §6): the graph demonstrably
// self-limits near ~150 strong ties in simulation. Drives the real
// attention-budget models via test/sim/dunbar_sim.dart. Pure + deterministic.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/model/attention_budget.dart';

import 'sim/dunbar_sim.dart';

void main() {
  group('Dunbar self-limit (Phase 2 exit)', () {
    test('active network plateaus near ~150 while connections grow unbounded',
        () {
      final r = runDunbarSim(const SimConfig());

      // The visible demonstration.
      // ignore: avoid_print
      print('\nDunbar self-limit — default engaged agent '
          '(meets ${r.config.meetsPerDay}/day, B=${r.config.params.budget}):\n'
          '${r.renderCurve()}');

      final plateau = r.plateauAffordable();
      // ignore: avoid_print
      print('  plateau (mean affordable, last 120 days): '
          '${plateau.toStringAsFixed(1)} '
          '| final connections: ${r.finalConnections} '
          '| plateau spread: ${r.plateauSpread()}');

      // 1. Intake is unbounded — nothing caps the raw friend list.
      expect(r.finalConnections, greaterThan(1000),
          reason: 'the agent kept meeting people; connections must grow');

      // 2. Yet the affordable ACTIVE network self-limits in the Dunbar band.
      expect(plateau, inInclusiveRange(120, 160),
          reason: 'active strong-tie network should self-limit near ~150');

      // 3. And it is a genuine plateau, not still drifting.
      expect(r.plateauSpread(), lessThanOrEqualTo(8),
          reason: 'the self-limit should be a stable steady state');

      // 4. The active network is a small fraction of everyone met — the whole
      //    point: you know thousands, you actively tend ~150.
      expect(plateau / r.finalConnections, lessThan(0.15));
    });

    test('the budget B is the knob: doubling B ~doubles the plateau', () {
      final base = runDunbarSim(const SimConfig());
      final wide = runDunbarSim(SimConfig(
        params: AttentionBudgetParams.defaults.copyWith(budget: 300.0),
      ));
      final pBase = base.plateauAffordable();
      final pWide = wide.plateauAffordable();
      // ignore: avoid_print
      print('\nB knob: B=150 → ${pBase.toStringAsFixed(1)}, '
          'B=300 → ${pWide.toStringAsFixed(1)} '
          '(ratio ${(pWide / pBase).toStringAsFixed(2)})');

      // Emergent, not hard-capped: the plateau tracks B, roughly linearly.
      expect(pWide / pBase, inInclusiveRange(1.7, 2.2),
          reason: '~150 is not a hard cap — it follows the budget B');
    });

    test('distance economics: a distant population self-limits LOWER', () {
      final local = runDunbarSim(const SimConfig(localFraction: 1.0));
      final distant = runDunbarSim(const SimConfig(localFraction: 0.0));
      final pLocal = local.plateauAffordable();
      final pDistant = distant.plateauAffordable();
      // ignore: avoid_print
      print('\nDistance economics: all-local → ${pLocal.toStringAsFixed(1)}, '
          'all-distant → ${pDistant.toStringAsFixed(1)}');

      // A distant tie costs more budget, so fewer fit under B: distance is the
      // discount, exactly as §3.3 intends.
      expect(pDistant, lessThan(pLocal));
      expect(pLocal, inInclusiveRange(140, 160),
          reason: 'an all-local engaged agent should fill the budget near B');
    });

    test('is deterministic (same seed ⇒ identical plateau)', () {
      final a = runDunbarSim(const SimConfig(days: 200));
      final b = runDunbarSim(const SimConfig(days: 200));
      expect(a.samples.last.affordable, equals(b.samples.last.affordable));
      expect(a.plateauAffordable(window: 60),
          equals(b.plateauAffordable(window: 60)));
    });
  });

  // The default population is all-unrated, so `tieStrength`'s tier term — the
  // kernel's LARGEST weight at 0.4 — contributes nothing there and S cannot
  // exceed wRecency + wProximity = 0.6. These runs give peers earned
  // reputation and make co-located people scarce, which together move the
  // plateau off the `B/baseCost` identity and let trust compete with distance
  // for budget.
  group('Dunbar self-limit (mixed-trust population)', () {
    const baseCost = 1.0; // AttentionBudgetParams.defaults.baseCost
    const identity = 150.0; // B / baseCost — the default population's plateau

    test('the plateau is emergent, not the B/baseCost identity', () {
      final r = runDunbarSim(SimConfig.mixedTrust);

      // ignore: avoid_print
      print('\nMixed-trust population '
          '(rated ${SimConfig.mixedTrust.ratedFraction}, '
          'local ${SimConfig.mixedTrust.localFraction}):\n'
          '${r.renderTrustCurve()}');
      final plateau = r.plateauAffordable();
      final meanCost = r.plateauOf((s) => s.affordableMeanCost);
      // ignore: avoid_print
      print('  plateau ${plateau.toStringAsFixed(1)} '
          '(identity would be $identity) | spread ${r.plateauSpread()} '
          '| mean affordable cost ${meanCost.toStringAsFixed(2)}');

      // Intake is still unbounded.
      expect(r.finalConnections, greaterThan(1000));

      // Still a self-limited active network, but NOT the arithmetic identity:
      // the budget is now buying ties that cost more than baseCost.
      expect(plateau, lessThan(identity - 5),
          reason: 'a mixed population must not reproduce B/baseCost exactly');
      expect(plateau, inInclusiveRange(90, 135),
          reason: 'still a self-limited active network, just a dearer one');

      // Heterogeneous costs are the mechanism.
      expect(meanCost, greaterThan(baseCost * 1.05),
          reason: 'affordable ties are no longer uniformly the cheapest kind');

      // A live steady state rather than a pinned constant — the default
      // population's spread is exactly 0.
      expect(r.plateauSpread(), greaterThan(0),
          reason: 'the plateau should breathe, not be pinned by arithmetic');
      expect(r.plateauSpread(), lessThanOrEqualTo(20),
          reason: 'but it must still be a plateau, not a drift');
    });

    test('the tier term is live — strengths exceed the unrated ceiling', () {
      final r = runDunbarSim(SimConfig.mixedTrust);
      final maxS = r.plateauOf((s) => s.affordableMaxStrength);

      // 0.6 = wRecency + wProximity: unreachable without a trust tier, so this
      // fails the moment the population silently regresses to all-unrated.
      expect(maxS, greaterThan(0.6),
          reason: 'S > 0.6 is only reachable when the tier term contributes');
    });

    test('trust buys priority, distance pays rent', () {
      final r = runDunbarSim(SimConfig.mixedTrust);
      final tierIn = r.plateauOf((s) => s.affordableMeanTier);
      final tierOut = r.plateauOf((s) => s.overBudgetMeanTier);
      final distant = r.plateauOf((s) => s.affordableDistant.toDouble());
      final localCost = r.plateauOf((s) => s.affordableLocalMeanCost);
      final distantCost = r.plateauOf((s) => s.affordableDistantMeanCost);
      // ignore: avoid_print
      print('\nTrust vs distance: mean tier inside the budget line '
          '${tierIn.toStringAsFixed(2)} vs outside ${tierOut.toStringAsFixed(2)}'
          ' | ${distant.toStringAsFixed(0)} distant ties funded at '
          '${distantCost.toStringAsFixed(2)} vs ${localCost.toStringAsFixed(2)}'
          ' for local');

      // Budget is allocated strongest-first, so trust concentrates INSIDE the
      // line and the ties that fall over it are the less-trusted ones.
      expect(tierIn, greaterThan(tierOut),
          reason: 'strongest-first allocation should fund trust before it '
              'funds proximity');

      // Trust genuinely buys distant ties in — they cannot win on proximity.
      expect(distant, greaterThan(10),
          reason: 'trusted distant ties should clear the budget line');

      // And they pay for it: cost = baseCost/(p(d)*recency), so a distant tie
      // consumes a multiple of what the co-located one does.
      expect(distantCost, greaterThan(localCost),
          reason: 'distance is the discount — a distant tie costs more budget');
    });

    test('trust is what moved it — the same population unrated returns to the '
        'identity', () {
      final rated = runDunbarSim(SimConfig.mixedTrust);
      final unrated = runDunbarSim(SimConfig.mixedTrust.copyWith(
        ratedFraction: 0.0,
      ));

      // Same locality scarcity, same intake, same tending: the ONLY difference
      // is whether anyone has earned reputation. Unrated, the cheapest local
      // ties win every slot and the plateau snaps back to B/baseCost.
      expect(unrated.plateauAffordable(), closeTo(identity, 1.0),
          reason: 'without trust, the cheapest ties win and 150 is arithmetic');
      expect(unrated.plateauSpread(), equals(0),
          reason: 'the identity is a pinned constant, not a steady state');
      expect(rated.plateauAffordable(), lessThan(unrated.plateauAffordable()),
          reason: 'trust redirects budget to dearer ties, lowering the count');
    });

    test('is deterministic (same seed ⇒ identical plateau)', () {
      final a = runDunbarSim(SimConfig.mixedTrust.copyWith(days: 200));
      final b = runDunbarSim(SimConfig.mixedTrust.copyWith(days: 200));
      expect(a.samples.last.affordable, equals(b.samples.last.affordable));
      expect(a.plateauOf((s) => s.affordableMeanCost, window: 60),
          equals(b.plateauOf((s) => s.affordableMeanCost, window: 60)));
    });
  });
}
