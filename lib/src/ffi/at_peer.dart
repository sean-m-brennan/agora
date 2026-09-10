// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// AgoraPeer: the app-facing, merged view of one observed peer, assembled from
// the PEER_OBSERVED and PEER_REPUTATION events the C event surface exposes.
//
// NOTE: profile fields (agora.profile) and position/distance are deliberately
// absent — the AT C event surface does not carry them yet. See
// SOCIAL_APP_PLAN.md §5.1 ("the gap"): surfacing those needs an AT-core event
// extension, so this model is intentionally limited to peer + presence +
// reputation for the first increment.

import 'at_events_bindings.dart';

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
      default:
        return false;
    }
  }
}
