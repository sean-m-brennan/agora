// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Dunbar self-limiting simulation (Phase 2 exit artifact, SOCIAL_APP_PLAN.md §6
// / §3.3). A pure, deterministic simulation that drives the REAL shipping models
// — `tieStrength`, `edgeCost`, and `BudgetLedger` over real `AgoraPeer`s — to
// show that the *active strong-tie network* self-limits near Dunbar's ~150 even
// as the raw connection count grows without bound.
//
// The self-limit is NOT a cap on the friend list. It emerges from the attention
// budget: a strong tie costs `base·(1/p(d))·(1/recency)`, so a well-tended local
// tie costs ≈ base and B/base ≈ 150 of them fit, while a neglected tie's cost
// balloons (recency → floor ⇒ up to 50×) and it falls *over the budget line* —
// flagged, faded, never severed. An agent with finite tending throughput can
// therefore keep only ~B ties fresh enough to stay affordable, however many
// people it meets. This file makes that dynamic observable and testable.
//
// Everything here is pure given (config, seed): no daemon, no FFI, no clock.

import 'dart:math' as math;

import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/model/attention_budget.dart';
import 'package:agora/src/model/tie_strength.dart';

/// One simulated node's own coarse bucket. A co-located ("local") peer shares
/// it, giving proximity factor p(0) = 1 — the ideal, cheapest tie.
const String kHere = 'u4pruy';

/// Seconds per simulated day (matches the recency kernel's ~1-day tau).
const double _kDay = 86400.0;

/// Parameters for one run of the Dunbar simulation.
class SimConfig {
  const SimConfig({
    this.days = 730, // ~2 years
    this.meetsPerDay = 8, // new acquaintances met per day (unbounded intake)
    // Ties refreshed per day, strongest-first. Set generously (well above B) so
    // the binding constraint is the attention BUDGET, not raw touch-count — the
    // budget is the property under test. A lower throughput would plateau lower
    // (a less-engaged agent keeps fewer ties warm); see the doc.
    this.tendPerDay = 500,
    this.localFraction = 0.85, // share of new peers who are co-located
    this.distantRttMinMs = 40, // distant peers' RTT spread (drives p(d) via rtt)
    this.distantRttMaxMs = 240,
    this.startEpoch = 1000000000.0,
    this.seed = 0x51E,
    this.params = AttentionBudgetParams.defaults,
    this.weights = TieStrengthWeights.defaults,
  });

  final int days;
  final int meetsPerDay;

  /// How many ties the agent refreshes per day (stamps a fresh interaction on),
  /// chosen strongest-first — the finite attention throughput that, together
  /// with recency decay, produces the self-limit.
  final int tendPerDay;

  /// Fraction of newly-met peers who are co-located (geohash == [kHere]); the
  /// rest are distant (no shared bucket, an RTT in [distantRttMinMs,
  /// distantRttMaxMs], so p(d) < 1 and their tended cost exceeds base).
  final double localFraction;
  final int distantRttMinMs;
  final int distantRttMaxMs;

  final double startEpoch;
  final int seed;
  final AttentionBudgetParams params;
  final TieStrengthWeights weights;

  SimConfig copyWith({
    int? days,
    int? meetsPerDay,
    int? tendPerDay,
    double? localFraction,
    AttentionBudgetParams? params,
  }) =>
      SimConfig(
        days: days ?? this.days,
        meetsPerDay: meetsPerDay ?? this.meetsPerDay,
        tendPerDay: tendPerDay ?? this.tendPerDay,
        localFraction: localFraction ?? this.localFraction,
        distantRttMinMs: distantRttMinMs,
        distantRttMaxMs: distantRttMaxMs,
        startEpoch: startEpoch,
        seed: seed,
        params: params ?? this.params,
        weights: weights,
      );
}

/// One day's snapshot of the graph.
class SimSample {
  const SimSample({
    required this.day,
    required this.connections,
    required this.strongTies,
    required this.affordable,
    required this.spent,
    required this.utilization,
  });

  /// Simulated day index (0-based).
  final int day;

  /// Total connected peers held (the unbounded raw friend list).
  final int connections;

  /// Connected peers whose tie strength S ≥ the strong-tie threshold.
  final int strongTies;

  /// Strong ties that fit WITHIN the attention budget B — the active network,
  /// the quantity that self-limits. (Strong ties beyond B are the faded,
  /// over-budget ones; never severed.)
  final int affordable;

  /// Total budget consumed by all strong ties (≥ B once stretched).
  final double spent;

  /// spent / B.
  final double utilization;
}

/// The result of a run: the full daily series plus convenience reducers.
class SimResult {
  SimResult(this.config, this.samples);

  final SimConfig config;
  final List<SimSample> samples;

  /// Mean affordable-strong-tie count over the final [window] days — the
  /// steady-state plateau height.
  double plateauAffordable({int window = 120}) =>
      _tailMean(samples.map((s) => s.affordable.toDouble()), window);

  /// Peak-to-peak spread of the affordable count over the final [window] days —
  /// small ⇒ the plateau is stable, not still drifting.
  int plateauSpread({int window = 120}) {
    final tail = samples.length <= window
        ? samples
        : samples.sublist(samples.length - window);
    var lo = 1 << 30, hi = -(1 << 30);
    for (final s in tail) {
      lo = math.min(lo, s.affordable);
      hi = math.max(hi, s.affordable);
    }
    return hi - lo;
  }

  int get finalConnections => samples.last.connections;

  double _tailMean(Iterable<double> xs, int window) {
    final list = xs.toList();
    final tail =
        list.length <= window ? list : list.sublist(list.length - window);
    if (tail.isEmpty) return 0;
    return tail.reduce((a, b) => a + b) / tail.length;
  }

  /// A compact human-readable curve, one row every [every] days — the visible
  /// "demonstration" printed by the test.
  String renderCurve({int every = 60}) {
    final b = StringBuffer();
    b.writeln('  day  connections  strong  affordable  utilization');
    for (final s in samples) {
      if (s.day % every != 0 && s.day != samples.last.day) continue;
      b.writeln('${s.day.toString().padLeft(5)}'
          '${s.connections.toString().padLeft(13)}'
          '${s.strongTies.toString().padLeft(8)}'
          '${s.affordable.toString().padLeft(12)}'
          '${s.utilization.toStringAsFixed(2).padLeft(13)}');
    }
    return b.toString();
  }
}

/// Run the simulation. Pure and deterministic given (`config`) — the RNG is
/// seeded from `config.seed`.
SimResult runDunbarSim(SimConfig config) {
  final rng = math.Random(config.seed);
  final peers = <AgoraPeer>[];
  var now = config.startEpoch;
  var nextSeed = 1;
  final samples = <SimSample>[];

  AgoraPeer meetOne() {
    // A distinct 16-byte uuid per peer (little-endian counter), so no two ties
    // collide in the ledger.
    final id = nextSeed++;
    final uuid = List<int>.filled(16, 0);
    uuid[0] = id & 0xff;
    uuid[1] = (id >> 8) & 0xff;
    uuid[2] = (id >> 16) & 0xff;
    final p = AgoraPeer(uuid: uuid);
    p.connectionState = 3; // connected: both sides consented
    // You just connected, so the tie is born freshly-tended.
    p.lastInteractionAt = now;
    if (rng.nextDouble() < config.localFraction) {
      p.geohash = kHere; // co-located ⇒ p(d) = 1
    } else {
      p.geohash = ''; // distant ⇒ RTT-derived proximity < 1
      p.rttMs = config.distantRttMinMs +
          rng.nextInt(config.distantRttMaxMs - config.distantRttMinMs + 1);
    }
    return p;
  }

  for (var day = 0; day < config.days; day++) {
    // 1. Time passes: yesterday's ties age (recency decays).
    now += _kDay;

    // 2. Meet new people — intake is unbounded; nothing caps the list.
    for (var i = 0; i < config.meetsPerDay; i++) {
      peers.add(meetOne());
    }

    // 3. Spend the day's finite attention on the strongest ties first: touch
    //    base with up to tendPerDay of them, refreshing their recency. Everyone
    //    else is left to decay — the realistic constraint that makes ~150 bind.
    final byStrength = [...peers]..sort((a, b) {
        final sa = tieStrength(a,
            ownGeohash: kHere,
            nowEpochSeconds: now,
            weights: config.weights);
        final sb = tieStrength(b,
            ownGeohash: kHere,
            nowEpochSeconds: now,
            weights: config.weights);
        return sb.compareTo(sa);
      });
    final tend = math.min(config.tendPerDay, byStrength.length);
    for (var i = 0; i < tend; i++) {
      byStrength[i].lastInteractionAt = now;
    }

    // 4. Read the ledger.
    final ledger = BudgetLedger.compute(
      peers,
      ownGeohash: kHere,
      nowEpochSeconds: now,
      weights: config.weights,
      params: config.params,
    );
    final affordable = ledger.ties.where((t) => !t.overBudget).length;
    samples.add(SimSample(
      day: day,
      connections: peers.length,
      strongTies: ledger.strongTieCount,
      affordable: affordable,
      spent: ledger.spent,
      utilization: ledger.utilization,
    ));
  }

  return SimResult(config, samples);
}
