// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The moderation verbs PeerService sends to the core (Phase 4 P4.1), behind
// one seam so a test can see exactly which went out and in what order — the
// expulsion flow in particular, where the reputation consequence must follow
// the decision landing in the log and never precede it.
//
// Every verb returns the shim's rc: 0 queued, -2 daemon not ready, -1 no
// channel. A 0 means QUEUED, not accepted: nothing on this boundary is
// synchronous, and the core applies its own guards afterwards.

/// The ceiling an expulsion carries, mirroring the C `AT_ETHNE_EXPEL_CEILING`.
/// Below the tier-1 floor (0.50), so every tier-gated capability closes; above
/// the network cut-off (0.10), so the peer is not cut off. A reputation event,
/// not a hard cut.
const double ethneExpelCeiling = 0.20;

/// The standing source this app speaks for. The core refuses "zta" from an app.
const String standingSourceEthne = 'ethne';

abstract class ModerationVerbs {
  int block(List<int> peerUuid);
  int unblock(List<int> peerUuid);
  int report(List<int> peerUuid);

  /// An authority finding: [standing] is "capped" (bounded at [ceiling]) or
  /// "proved" (reinstated — lifts this source's ceiling and nothing else).
  int peerStanding(List<int> peerUuid,
      {required String standing,
      required double ceiling,
      required String reason});

  /// The ask an expulsion sends: co-sign [bytes] (the act [cid]), to each of
  /// [peerUuids]. Here rather than beside the other co-signing verbs so a test
  /// can see the ask go out BEFORE any standing does.
  int requestCosign(List<List<int>> peerUuids,
      {required String record,
      required String op,
      required String polityDid,
      required String cid,
      required String bytes});
}
