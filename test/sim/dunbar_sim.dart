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
    this.ratedFraction = 0.0,
    this.ratedScoreMin = 0.50,
    this.ratedScoreMax = 0.95,
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

  /// Share of newly-met peers who carry an EARNED reputation (AT tier 1..4).
  /// Zero — the default — reproduces the original all-unrated population, in
  /// which `tieStrength`'s tier term contributes nothing and S cannot exceed
  /// `wRecency + wProximity` (0.6 with the defaults). A non-zero fraction is
  /// what makes the kernel's `wTier` (0.4, the largest single weight) do work.
  final double ratedFraction;

  /// Uniform range for a rated peer's reputation score, mapped to a 0..4 tier
  /// through the REAL [trustTierForScore] / [tierFloors], so the sim tracks the
  /// shipping floors rather than a private copy of them. The default spans the
  /// whole rated range: 0.50 is the tier-1 floor, 0.95 clears tier 4 (0.90).
  final double ratedScoreMin;
  final double ratedScoreMax;

  final double startEpoch;
  final int seed;
  final AttentionBudgetParams params;
  final TieStrengthWeights weights;

  SimConfig copyWith({
    int? days,
    int? meetsPerDay,
    int? tendPerDay,
    double? localFraction,
    double? ratedFraction,
    AttentionBudgetParams? params,
  }) =>
      SimConfig(
        days: days ?? this.days,
        meetsPerDay: meetsPerDay ?? this.meetsPerDay,
        tendPerDay: tendPerDay ?? this.tendPerDay,
        localFraction: localFraction ?? this.localFraction,
        distantRttMinMs: distantRttMinMs,
        distantRttMaxMs: distantRttMaxMs,
        ratedFraction: ratedFraction ?? this.ratedFraction,
        ratedScoreMin: ratedScoreMin,
        ratedScoreMax: ratedScoreMax,
        startEpoch: startEpoch,
        seed: seed,
        params: params ?? this.params,
        weights: weights,
      );

  /// A population in which trust is real, unevenly distributed, and co-located
  /// people are SCARCE — a mostly-remote agent (a diaspora member, a remote
  /// worker) rather than the default's village.
  ///
  /// Both knobs are load-bearing, and the reason is the sharpest thing the sim
  /// has to say about §3.3:
  ///
  ///   `edgeCost` reads ONLY proximity and recency — never the trust tier. So
  ///   tier cannot change how many ties fit under B, only WHICH ones do. While
  ///   at least B/baseCost co-located, freshly-tended ties exist, they are both
  ///   the strongest and the cheapest, they win every budget slot, and the
  ///   plateau is pinned to the bare `B/baseCost` identity no matter how the
  ///   population is rated. Scarce locality is what forces the budget to buy
  ///   expensive ties, and only THEN does trust decide which expensive ties get
  ///   bought — which is the trust-versus-distance economics §3.3 describes.
  ///
  /// At these settings the plateau is genuinely emergent: it sits well below
  /// `B/baseCost`, it moves when the population's trust changes, and it has a
  /// real steady-state spread instead of being a pinned constant.
  static const SimConfig mixedTrust = SimConfig(
    ratedFraction: 0.45,
    localFraction: 0.08,
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
    required this.affordableMeanCost,
    required this.affordableMaxStrength,
    required this.affordableMeanTier,
    required this.overBudgetMeanTier,
    required this.affordableDistant,
    required this.affordableLocalMeanCost,
    required this.affordableDistantMeanCost,
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

  /// Mean budget cost of the ties INSIDE the budget line. Exactly [baseCost] in
  /// the all-local unrated population (which is why its plateau is the bare
  /// `B/baseCost` identity); strictly greater once trust funds ties that
  /// distance or neglect makes expensive.
  final double affordableMeanCost;

  /// Highest tie strength among affordable ties. Bounded by
  /// `wRecency + wProximity` (0.6) when nobody is rated — exceeding it is proof
  /// the tier term is live.
  final double affordableMaxStrength;

  /// Mean AT trust tier (0..4) inside the budget line, and beyond it. Budget is
  /// allocated strongest-first, so trust should concentrate INSIDE.
  final double affordableMeanTier;
  final double overBudgetMeanTier;

  /// Affordable ties that are not co-located — the ones trust bought in despite
  /// paying `1/p(d)` rent.
  final int affordableDistant;

  /// Mean affordable cost split by locality: distance is the discount, so the
  /// distant mean should sit well above the local one.
  final double affordableLocalMeanCost;
  final double affordableDistantMeanCost;
}

/// The result of a run: the full daily series plus convenience reducers.
class SimResult {
  SimResult(this.config, this.samples);

  final SimConfig config;
  final List<SimSample> samples;

  /// Mean affordable-strong-tie count over the final [window] days — the
  /// steady-state plateau height.
  double plateauAffordable({int window = 120}) =>
      plateauOf((s) => s.affordable.toDouble(), window: window);

  /// Steady-state mean of any per-day observable over the final [window] days.
  /// [plateauAffordable] is the count; this reads the same tail for costs,
  /// tiers and strengths.
  double plateauOf(double Function(SimSample) selector, {int window = 120}) =>
      _tailMean(samples.map(selector), window);

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

  /// The mixed-trust view: the same plateau, plus what the budget line is
  /// actually BUYING — cost heterogeneity, the reach of the tier term, and how
  /// trust and distance sort themselves either side of the line.
  String renderTrustCurve({int every = 60}) {
    final b = StringBuffer();
    b.writeln('  day  connections  strong  affordable  meanCost  maxS  '
        'tier(in/out)  distant');
    for (final s in samples) {
      if (s.day % every != 0 && s.day != samples.last.day) continue;
      b.writeln('${s.day.toString().padLeft(5)}'
          '${s.connections.toString().padLeft(13)}'
          '${s.strongTies.toString().padLeft(8)}'
          '${s.affordable.toString().padLeft(12)}'
          '${s.affordableMeanCost.toStringAsFixed(2).padLeft(10)}'
          '${s.affordableMaxStrength.toStringAsFixed(2).padLeft(6)}'
          '${'${s.affordableMeanTier.toStringAsFixed(2)}/'
              '${s.overBudgetMeanTier.toStringAsFixed(2)}'.padLeft(14)}'
          '${s.affordableDistant.toString().padLeft(9)}');
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
    // Earned reputation, when the population has any. The `> 0` guard
    // short-circuits so an all-unrated run consumes NO random values here and
    // reproduces the original seeded stream exactly.
    if (config.ratedFraction > 0 && rng.nextDouble() < config.ratedFraction) {
      p.reputationRated = true;
      p.reputationScore = config.ratedScoreMin +
          rng.nextDouble() * (config.ratedScoreMax - config.ratedScoreMin);
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
    final affordableTies = ledger.ties.where((t) => !t.overBudget).toList();
    final overTies = ledger.ties.where((t) => t.overBudget).toList();
    bool isLocal(TieCost t) => t.peer.geohash == kHere;
    final affLocal = affordableTies.where(isLocal).toList();
    final affDistant = affordableTies.where((t) => !isLocal(t)).toList();
    samples.add(SimSample(
      day: day,
      connections: peers.length,
      strongTies: ledger.strongTieCount,
      affordable: affordableTies.length,
      spent: ledger.spent,
      utilization: ledger.utilization,
      affordableMeanCost: _mean(affordableTies.map((t) => t.cost)),
      affordableMaxStrength: affordableTies.isEmpty
          ? 0.0
          : affordableTies.map((t) => t.strength).reduce(math.max),
      affordableMeanTier:
          _mean(affordableTies.map((t) => trustTier(t.peer).toDouble())),
      overBudgetMeanTier:
          _mean(overTies.map((t) => trustTier(t.peer).toDouble())),
      affordableDistant: affDistant.length,
      affordableLocalMeanCost: _mean(affLocal.map((t) => t.cost)),
      affordableDistantMeanCost: _mean(affDistant.map((t) => t.cost)),
    ));
  }

  return SimResult(config, samples);
}

/// Mean of [xs], or 0 for an empty set (an empty band is reported as 0 rather
/// than NaN so a sample is always printable).
double _mean(Iterable<double> xs) {
  var n = 0;
  var total = 0.0;
  for (final x in xs) {
    total += x;
    n++;
  }
  return n == 0 ? 0.0 : total / n;
}
