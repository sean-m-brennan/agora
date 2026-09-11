// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The tie-strength kernel (Increment 4) — the research core of Agora
// (SOCIAL_APP_PLAN.md §3). Each directed edge carries a strength S ∈ [0,1]
// computed locally from three factors:
//
//     S = w_t · tier(peer)        # AT trust tier, 0..1 normalized
//       + w_i · recency(peer)     # decays since last real interaction
//       + w_p · p(d)              # proximity factor
//
// Local ties are "born strong" because proximity dominates; distance is the
// discount. Phase-1 ranks "people near me" by S. The full attention-budget
// tuning that makes Dunbar emerge (§3.3) is Phase 2 — here we deliver the
// kernel and the four audience tiers it feeds, all app-side (no native change).
//
// Everything here is pure and deterministic given its inputs, so it is unit
// tested directly without the daemon or FFI.

import 'dart:math' as math;

import '../ffi/at_peer.dart';

/// Reputation-score floors for AT trust tiers 1..4, mirroring the C core's
/// `TIER_FLOORS` (reputation/rep_proc.c:64-76). A rated score at/above a floor
/// is that tier; below 0.50 (and any unrated peer) is tier 0 (admitted/presence
/// only). Tier is NOT on the app event surface today (at_app_peer_t.rank is
/// topology rank, a different axis), so Agora derives it app-side from the
/// PEER_REPUTATION score. A dedicated tier event is a possible later upgrade.
const List<double> tierFloors = [0.50, 0.65, 0.80, 0.90];

/// The 0..4 trust tier for a peer's reputation. Unrated => 0 (we have no earned
/// trust yet, only presence).
int trustTierForScore(double score, bool rated) {
  if (!rated) return 0;
  var tier = 0;
  for (var i = 0; i < tierFloors.length; i++) {
    if (score >= tierFloors[i]) {
      tier = i + 1;
    } else {
      break;
    }
  }
  return tier;
}

/// Trust tier for a peer (convenience over [trustTierForScore]).
int trustTier(AgoraPeer peer) =>
    trustTierForScore(peer.reputationScore, peer.reputationRated);

/// The post-audience bands (§3.4). A post is addressed to a minimum tier; these
/// name the bands the tie-strength tiers map onto. Ordered widest→narrowest.
enum PostAudience {
  /// Everyone (tier 0+): public.
  public,

  /// Acquaintances (tier 1+): the active-network band.
  acquaintance,

  /// Friends (tier 2+): the sympathy group.
  friend,

  /// Close ties (tier 3+): the support clique.
  close,
}

/// Map a 0..4 trust tier to its audience band (§3.4). Tiers 3 and 4 are both the
/// "close" band (highest trust); tier 0 is public.
PostAudience audienceForTier(int tier) {
  if (tier >= 3) return PostAudience.close;
  if (tier == 2) return PostAudience.friend;
  if (tier == 1) return PostAudience.acquaintance;
  return PostAudience.public;
}

/// The minimum trust tier a reader must hold to receive a post of this audience
/// — the inverse of [audienceForTier], used to gate feed posts (Inc 7).
int minTierForAudience(PostAudience audience) {
  switch (audience) {
    case PostAudience.public:
      return 0;
    case PostAudience.acquaintance:
      return 1;
    case PostAudience.friend:
      return 2;
    case PostAudience.close:
      return 3;
  }
}

/// Short human label for an audience band.
String audienceLabel(PostAudience audience) {
  switch (audience) {
    case PostAudience.public:
      return 'public';
    case PostAudience.acquaintance:
      return 'acquaintance';
    case PostAudience.friend:
      return 'friend';
    case PostAudience.close:
      return 'close';
  }
}

/// Weights and scales for the tie-strength kernel. Defaults sum to 1 so S stays
/// in [0,1]. Per-user tuning and the attention-budget costs (§3.3) are Phase 2.
class TieStrengthWeights {
  const TieStrengthWeights({
    this.wTier = 0.4,
    this.wRecency = 0.3,
    this.wProximity = 0.3,
    this.localityScaleKm = 2.0,
    this.rttScaleMs = 100.0,
    this.recencyTauSeconds = 86400.0, // ~1 day
  });

  /// Weight on the trust-tier term.
  final double wTier;

  /// Weight on the interaction-recency term.
  final double wRecency;

  /// Weight on the proximity term.
  final double wProximity;

  /// Locality scale d0 (km) in p(d) = exp(-d/d0). ~a neighbourhood (§3.2).
  final double localityScaleKm;

  /// Fallback proximity scale (ms) when no shared geohash: p_rtt = exp(-rtt/r0).
  final double rttScaleMs;

  /// Decay constant (seconds) for the recency STAND-IN (see [tieStrength]).
  final double recencyTauSeconds;

  static const TieStrengthWeights defaults = TieStrengthWeights();
}

/// The proximity factor p(d) = exp(-d/d0) from a peer's shared coarse position,
/// or, when no geohash is shared, an RTT-derived fallback exp(-rtt/r0). Returns
/// 0 when neither signal is available (a peer we cannot place is not "near").
double proximityFactor(AgoraPeer peer, String? ownGeohash,
    {TieStrengthWeights weights = TieStrengthWeights.defaults}) {
  final d = peer.distanceKmFrom(ownGeohash);
  if (d != null) {
    return math.exp(-d / weights.localityScaleKm);
  }
  if (peer.rttMs > 0) {
    return math.exp(-peer.rttMs / weights.rttScaleMs);
  }
  return 0.0;
}

/// The interaction-recency term, in [0,1]. Phase-1 STAND-IN: derived from the
/// operator-attended freshness (`operatorAttestedAt`) as a proxy for "recently
/// active with me", decaying as exp(-age/tau). Increment 5 (connections) and 6
/// (DMs) introduce a real per-peer last-interaction timestamp that REPLACES this
/// proxy — a relationship you actually tend should drive recency, not mere
/// presence.
// TODO(inc5/6): replace with a real per-peer last-interaction timestamp.
double recencyFactor(AgoraPeer peer, double nowEpochSeconds,
    {TieStrengthWeights weights = TieStrengthWeights.defaults}) {
  if (peer.operatorAttestedAt <= 0) return 0.0;
  final age = nowEpochSeconds - peer.operatorAttestedAt;
  if (age <= 0) return 1.0;
  return math.exp(-age / weights.recencyTauSeconds);
}

/// Compute the tie strength S ∈ [0,1] for [peer] from this node's viewpoint.
/// [ownGeohash] is this node's own opt-in bucket (null => opted out, so no
/// geographic proximity and the RTT fallback is used). [nowEpochSeconds] grades
/// the recency term.
double tieStrength(
  AgoraPeer peer, {
  required String? ownGeohash,
  required double nowEpochSeconds,
  TieStrengthWeights weights = TieStrengthWeights.defaults,
}) {
  final tierTerm = trustTier(peer) / 4.0; // normalize 0..4 → 0..1
  final recencyTerm = recencyFactor(peer, nowEpochSeconds, weights: weights);
  final proximityTerm = proximityFactor(peer, ownGeohash, weights: weights);
  final s = weights.wTier * tierTerm +
      weights.wRecency * recencyTerm +
      weights.wProximity * proximityTerm;
  // Clamp defensively in case weights were customized to not sum to 1.
  return s.clamp(0.0, 1.0);
}
