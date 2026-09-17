// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// BusinessDirectory: the app-side merged directory behind "businesses near me"
// (Phase 3 P3.2). Business ads arrive from the AT core
// (AT_APP_EVENT_BUSINESS_AD) already signature-verified and content-id-deduped
// at the AT layer. The directory adds the three things the core cannot do:
//
//   1. ETHNE VERIFICATION. The core carries the page bundle as opaque bytes; it
//      holds no Ethne. Here every bundle must prove polity-root → envoy → page
//      before it is stored, so an ad whose signature is perfectly good but whose
//      page does not actually speak for the polity is rejected.
//   2. MERGE. One page per business (the newest version by seq), and one
//      endorsement per customer (their most recent ad). The business's own ad is
//      never an endorsement — self-vouching is free.
//   3. RANKING. distance → vouch → recency, which is the order a person
//      actually shops in.
//
// Pure and deterministic given its inputs (a verifier callback, a strength
// callback, this node's own bucket and a clock), so it is unit tested directly
// without the daemon or FFI.

import 'dart:math' as math;

import '../geo/geohash.dart';
import 'business.dart';

/// Weights and scales for the business ranking kernel. Defaults sum to 1 so the
/// score stays in [0,1].
class BusinessRankWeights {
  const BusinessRankWeights({
    this.wDistance = 0.5,
    this.wVouch = 0.35,
    this.wRecency = 0.15,
    this.localityScaleKm = 2.0,
    this.recencyTauSeconds = 604800.0, // ~1 week
    this.vouchK = 1.0,
  });

  /// Weight on the distance term. Highest by default: "near me" is the request.
  final double wDistance;

  /// Weight on the customer-vouch term.
  final double wVouch;

  /// Weight on the recency term.
  final double wRecency;

  /// Locality scale d0 (km) in p(d) = exp(-d/d0), matching the tie-strength
  /// kernel's neighbourhood scale.
  final double localityScaleKm;

  /// Decay constant (seconds) for the recency term. Far slower than the feed's:
  /// a shop that was there last week is still there, while a week-old post is
  /// stale.
  final double recencyTauSeconds;

  /// Smoothing constant K in the vouch term. One strong tie's endorsement
  /// reaches about half credit; a crowd of weak ties cannot out-shout it.
  final double vouchK;

  static const BusinessRankWeights defaults = BusinessRankWeights();
}

/// Verifier for an opaque Ethne page bundle: true iff the bundle proves
/// polity-root → envoy → page. In the app this is
/// `EthneFfi.verifyBusinessPageBundle`.
typedef BundleVerifier = bool Function(String bundleJson);

class BusinessDirectory {
  /// [verifyBundle] is REQUIRED and has no default on purpose: the AT core does
  /// not verify Ethne, so if this class quietly accepted unverified bundles
  /// nothing in the system would ever check them. When Ethne is unavailable at
  /// runtime, pass a verifier that returns false — the directory then stays
  /// empty and [rejectedUnverified] says why, which is the honest outcome.
  BusinessDirectory({
    required this.verifyBundle,
    this.weights = BusinessRankWeights.defaults,
    this.adDedupCap = 256,
  });

  /// Test-only: accept every bundle without verification. Never use this in the
  /// app — it defeats the Ethne layer.
  BusinessDirectory.unverified({
    this.weights = BusinessRankWeights.defaults,
    this.adDedupCap = 256,
  }) : verifyBundle = _acceptAll;

  static bool _acceptAll(String _) => true;

  final BundleVerifier verifyBundle;
  final BusinessRankWeights weights;

  /// Bound on the local ad-id ring, mirroring the core's own dedup cap.
  final int adDedupCap;

  final Map<String, Business> _byPolity = {};
  final List<String> _seenAdIds = [];
  final Set<String> _seenAdIdSet = {};

  /// How many ads were dropped because their bundle failed Ethne verification.
  /// Surfaced in the UI so an empty directory is never mistaken for "nobody
  /// nearby" when it actually means "nothing could be verified".
  int rejectedUnverified = 0;

  /// Add [ad] to the directory. Returns true if it changed anything.
  ///
  /// Dropped, in order: an ad with no polity; a repeat of an ad id we have
  /// already merged (the core dedups too, but a page can reach us again across
  /// sessions); and an ad whose bundle fails Ethne verification.
  bool add(BusinessAd ad) {
    if (ad.polity.isEmpty) return false;
    if (ad.adId.isNotEmpty && _seenAdIdSet.contains(ad.adId)) return false;

    final existing = _byPolity[ad.polity];
    // A bundle-less ad can still endorse a page we already hold; one that
    // carries bytes must prove them.
    final hasBundle = ad.bundle.isNotEmpty;
    if (hasBundle && !verifyBundle(ad.bundle)) {
      rejectedUnverified++;
      return false;
    }
    if (!hasBundle && existing == null) return false;

    if (ad.adId.isNotEmpty) {
      _seenAdIdSet.add(ad.adId);
      _seenAdIds.add(ad.adId);
      while (_seenAdIds.length > adDedupCap) {
        _seenAdIdSet.remove(_seenAdIds.removeAt(0));
      }
    }

    final Business entry;
    if (existing == null) {
      entry = Business(
        polity: ad.polity,
        bundle: ad.bundle,
        seq: ad.seq,
        ts: ad.ts,
        page: BusinessPage.parse(ad.bundle),
      );
      _byPolity[ad.polity] = entry;
    } else {
      entry = existing;
      // A newer page version replaces the one we hold; an older one is ignored
      // (a customer may still be carrying last week's page).
      if (hasBundle && ad.seq > entry.seq) {
        entry.bundle = ad.bundle;
        entry.seq = ad.seq;
        entry.ts = ad.ts;
        entry.page = BusinessPage.parse(ad.bundle);
      } else if (ad.seq == entry.seq && ad.ts > entry.ts) {
        entry.ts = ad.ts;
      }
    }

    if (ad.isSelfAd) {
      entry.selfAdvertised = true;
    } else {
      // One endorsement per customer — their most recent one.
      final prior = entry.endorsers[ad.advertiserHex];
      if (prior == null || ad.ts >= prior.ts) {
        entry.endorsers[ad.advertiserHex] = ad;
      }
    }
    return true;
  }

  /// The business known under [polity], or null.
  Business? operator [](String polity) => _byPolity[polity];

  /// Every business held, in insertion order (unranked).
  List<Business> get businesses => List<Business>.unmodifiable(_byPolity.values);

  int get length => _byPolity.length;

  /// True if an ad with [adId] has already been merged.
  bool containsAd(String adId) => _seenAdIdSet.contains(adId);

  /// The distance term p(d) = exp(-d/d0) between this node's own coarse bucket
  /// and the page's locality. Returns 0 when either side is unplaced: a business
  /// we cannot place is not "near me", and neither is any business when we have
  /// opted out of position ourselves.
  double distanceFactor(Business b, String? ownGeohash) {
    final here = ownGeohash ?? '';
    if (here.isEmpty || b.locality.isEmpty) return 0.0;
    final d = geohashDistanceKm(here, b.locality);
    if (d == null) return 0.0;
    return math.exp(-d / weights.localityScaleKm);
  }

  /// The customer-vouch term in [0,1]:
  ///
  ///     vouch = Σ S(a)·(sat_a/4) / (K + Σ S(a))
  ///
  /// summed over CUSTOMER endorsers only, where S(a) is the tie strength to
  /// that advertiser. Two properties are the point. A stranger's rave counts
  /// for almost nothing, because S is almost nothing — the recommendation is
  /// only as good as your relationship with whoever made it. And the business's
  /// own ad never appears in the sum, so self-vouching is worth exactly zero.
  double vouch(
      Business b, double Function(List<int> advertiserUuid) strengthOfAdvertiser) {
    var num = 0.0;
    var den = 0.0;
    for (final ad in b.endorsers.values) {
      final s = strengthOfAdvertiser(ad.advertiserUuid).clamp(0.0, 1.0);
      if (s <= 0) continue;
      final sat = (ad.satisfaction.clamp(0, 4)) / 4.0;
      num += s * sat;
      den += s;
    }
    if (den <= 0) return 0.0;
    return (num / (weights.vouchK + den)).clamp(0.0, 1.0);
  }

  /// The recency term in [0,1], decaying as exp(-age/tau) from the last time
  /// anyone vouched for this business.
  double recency(Business b, double nowEpochSeconds) {
    final at = b.lastHeardAt;
    if (at <= 0) return 0.0;
    final age = nowEpochSeconds - at;
    if (age <= 0) return 1.0;
    return math.exp(-age / weights.recencyTauSeconds);
  }

  /// The ranking score for one business, in [0,1].
  double score(
    Business b, {
    required double Function(List<int> advertiserUuid) strengthOfAdvertiser,
    required String? ownGeohash,
    required double nowEpochSeconds,
  }) {
    final s = weights.wDistance * distanceFactor(b, ownGeohash) +
        weights.wVouch * vouch(b, strengthOfAdvertiser) +
        weights.wRecency * recency(b, nowEpochSeconds);
    return s.clamp(0.0, 1.0);
  }

  /// The directory ranked by [score] descending — distance first, then who you
  /// trust that vouched, then freshness. Ties break by endorser count (more
  /// customers first), then name, then DID, so the order is deterministic.
  List<Business> ranked({
    required double Function(List<int> advertiserUuid) strengthOfAdvertiser,
    required String? ownGeohash,
    required double nowEpochSeconds,
  }) {
    final list = _byPolity.values.toList();
    final scores = <String, double>{
      for (final b in list)
        b.polity: score(b,
            strengthOfAdvertiser: strengthOfAdvertiser,
            ownGeohash: ownGeohash,
            nowEpochSeconds: nowEpochSeconds),
    };
    list.sort((a, b) {
      final byScore = scores[b.polity]!.compareTo(scores[a.polity]!);
      if (byScore != 0) return byScore;
      final byEndorsers = b.endorsers.length.compareTo(a.endorsers.length);
      if (byEndorsers != 0) return byEndorsers;
      final byName = a.displayName.compareTo(b.displayName);
      if (byName != 0) return byName;
      return a.polity.compareTo(b.polity);
    });
    return list;
  }
}
