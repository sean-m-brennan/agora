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
}
