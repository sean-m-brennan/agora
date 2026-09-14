// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Pure-Dart tests for the Increment 8 payoff: social interactions accrue earned
// reputation in the AT core, and that score surfaces to the app as a
// PEER_REPUTATION event which the tie-strength kernel already reads. Here we
// assert the app SIDE of that loop — as a peer's ingested reputation rises (the
// observable effect of accrual), its tie strength and roster rank rise with it.
// ingestEvents-driven; no native shim required.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/node/peer_stream.dart';

AtRawEvent _repEvent(List<int> uuid, double score) => AtRawEvent(
      kind: agoraEventReputation,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: score,
      repRated: true,
      rttMs: 0,
    );

void main() {
  final a = List<int>.filled(16, 0xAA);
  final b = List<int>.filled(16, 0xBB);

  group('reputation drives tie strength (the accrual payoff)', () {
    test('a higher-reputation peer has the greater tie strength', () {
      final svc = PeerService();
      svc.ingestEvents([_repEvent(a, 0.90), _repEvent(b, 0.50)]);
      final pa = svc.peers.firstWhere((p) => p.reputationScore == 0.90);
      final pb = svc.peers.firstWhere((p) => p.reputationScore == 0.50);
      expect(svc.strengthOf(pa), greaterThan(svc.strengthOf(pb)));
    });

    test('raising a peer\'s reputation raises its tie strength', () {
      final svc = PeerService();
      svc.ingestEvents([_repEvent(a, 0.50)]);
      final before = svc.strengthOf(svc.peers.single);
      // A sustained interaction accrues: the peer's earned score climbs.
      svc.ingestEvents([_repEvent(a, 0.90)]);
      final after = svc.strengthOf(svc.peers.single);
      expect(after, greaterThan(before));
    });

    test('the roster ranks the higher-reputation peer first', () {
      final svc = PeerService();
      svc.ingestEvents([_repEvent(b, 0.50), _repEvent(a, 0.90)]);
      // peers is sorted by tie strength descending.
      expect(svc.peers.first.reputationScore, 0.90);
    });
  });
}
