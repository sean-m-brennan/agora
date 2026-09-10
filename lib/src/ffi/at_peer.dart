// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// AgoraPeer: the app-facing, merged view of one observed peer, assembled from
// the PEER_OBSERVED and PEER_REPUTATION events the C event surface exposes.
//
// Carries peer + presence + reputation and, since the first AT-core proximity
// increment, per-peer RTT (a network-latency proxy in ms — NOT a geographic
// distance). NOTE: profile fields (agora.profile) and true geographic
// distance are still absent — the AT C event surface does not carry them yet.
// See SOCIAL_APP_PLAN.md §5.1 ("the gap"): true distance needs a further
// AT-core extension. RTT is the phased first step.

import 'at_events_bindings.dart';
import '../geo/geohash.dart';

class AgoraPeer {
  AgoraPeer({required this.uuid});

  /// Raw 16-byte identity UUID.
  final List<int> uuid;

  List<int> signingPubkey = const [];
  int rank = 0;

  /// A human guardian is bound behind this node (verified against the operator
  /// anchor). Our anti-bot signal — behavioural, not a CAPTCHA.
  bool operatorBound = false;

  /// Epoch seconds of the last verified operator session; 0 == nobody attending
  /// or could not confirm. A stamp, not a state — grade it against local time.
  double operatorAttestedAt = 0;

  List<int> operatorPubkey = const [];

  /// AT's earned reputation, only meaningful when [reputationRated].
  double reputationScore = 0;
  bool reputationRated = false;

  /// Latest round-trip time to the peer in milliseconds, as AT measures it;
  /// 0 == unknown / not yet measured (a fast-LAN default, not "0 ms"). A
  /// network-latency proximity proxy — do NOT present it as geographic distance.
  int rttMs = 0;

  /// Peer's shared coarse geohash bucket; empty == not shared (opted out), the
  /// default. Populated only when the peer opts in and shares with us.
  String geohash = '';

  /// Short hex form of the UUID, for display.
  String get shortId {
    final hex = uuid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return hex.length <= 12 ? hex : hex.substring(0, 12);
  }

  bool get hasNamedGuardian => operatorPubkey.any((b) => b != 0);

  /// Presence label, graded against [nowEpochSeconds]. Mirrors the honest
  /// "active now" semantics: a bound node with nobody at the keyboard for a
  /// while is normal, not offline.
  String presenceLabel(double nowEpochSeconds) {
    if (!operatorBound) return 'unattended (no guardian)';
    if (operatorAttestedAt <= 0) return 'bound · nobody attending';
    final ago = nowEpochSeconds - operatorAttestedAt;
    if (ago < 0) return 'attended';
    if (ago < 120) return 'active now';
    if (ago < 3600) return 'attended ${(ago / 60).floor()}m ago';
    if (ago < 86400) return 'attended ${(ago / 3600).floor()}h ago';
    return 'attended ${(ago / 86400).floor()}d ago';
  }

  String get reputationLabel =>
      reputationRated ? reputationScore.toStringAsFixed(2) : 'unrated';

  /// RTT for display; 0 renders as unknown ("—"), never as "0 ms".
  String get rttLabel => rttMs > 0 ? '${rttMs}ms' : '—';

  /// Geographic distance in km from [ownGeohash] to this peer's shared bucket,
  /// or null when either side hasn't opted in (one-sided opt-in = no distance,
  /// the intended privacy behavior).
  double? distanceKmFrom(String? ownGeohash) {
    if (ownGeohash == null || ownGeohash.isEmpty || geohash.isEmpty) return null;
    return geohashDistanceKm(ownGeohash, geohash);
  }

  /// Coarse distance for display given this node's own bucket; "—" when not
  /// shared by both sides. Rounded, prefixed "~" to signal bucket coarseness.
  String distanceLabel(String? ownGeohash) {
    final d = distanceKmFrom(ownGeohash);
    if (d == null) return '—';
    if (d < 1.0) return '~${(d * 1000).round()} m';
    return '~${d.round()} km';
  }

  /// Apply a decoded event to this peer, returning true if it was consumed.
  bool applyEvent(AtRawEvent e) {
    switch (e.kind) {
      case agoraEventPeer:
        signingPubkey = e.signingPubkey;
        rank = e.rank;
        operatorBound = e.operatorBound;
        operatorAttestedAt = e.operatorAttestedAt;
        operatorPubkey = e.operatorPubkey;
        return true;
      case agoraEventReputation:
        reputationScore = e.repScore;
        reputationRated = e.repRated;
        return true;
      case agoraEventRtt:
        rttMs = e.rttMs;
        return true;
      case agoraEventPosition:
        geohash = e.geohash;
        return true;
      default:
        return false;
    }
  }
}
