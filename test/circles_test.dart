// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Unit tests for the nested Dunbar circles (Phase 2, §3.4). Pure — no daemon.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/model/circles.dart';

AgoraPeer _peer({
  double repScore = 0,
  bool repRated = false,
  bool connected = false,
  int seed = 0x11,
}) {
  final p = AgoraPeer(uuid: List<int>.filled(16, seed));
  p.reputationScore = repScore;
  p.reputationRated = repRated;
  p.connectionState = connected ? 3 : 0;
  return p;
}

void main() {
  group('targets follow Dunbar 5/15/50/150/500/1500', () {
    test('each layer has its canonical target size', () {
      expect(DunbarCircle.support.targetSize, 5);
      expect(DunbarCircle.sympathy.targetSize, 15);
      expect(DunbarCircle.band.targetSize, 50);
      expect(DunbarCircle.active.targetSize, 150);
      expect(DunbarCircle.acquaintance.targetSize, 500);
      expect(DunbarCircle.recognition.targetSize, 1500);
    });
  });

  group('circleForPeer', () {
    test('unconnected peer is only recognized (seen, not admitted)', () {
      expect(circleForPeer(_peer(repScore: 0.95, repRated: true)),
          DunbarCircle.recognition);
    });
    test('connected tier bands map onto the inner circles', () {
      expect(circleForPeer(_peer(connected: true)), DunbarCircle.acquaintance); // tier 0
      expect(circleForPeer(_peer(connected: true, repScore: 0.50, repRated: true)),
          DunbarCircle.active); // tier 1
      expect(circleForPeer(_peer(connected: true, repScore: 0.65, repRated: true)),
          DunbarCircle.band); // tier 2
      expect(circleForPeer(_peer(connected: true, repScore: 0.80, repRated: true)),
          DunbarCircle.sympathy); // tier 3
      expect(circleForPeer(_peer(connected: true, repScore: 0.90, repRated: true)),
          DunbarCircle.support); // tier 4
    });
  });

  group('CircleGrouping', () {
    test('buckets peers and preserves input order within a circle', () {
      final a = _peer(connected: true, seed: 1);
      final b = _peer(connected: true, seed: 2);
      final seen = _peer(seed: 3);
      final g = CircleGrouping.from([a, b, seen]);
      expect(g.countIn(DunbarCircle.acquaintance), 2);
      expect(g.peersIn(DunbarCircle.acquaintance), [a, b]);
      expect(g.countIn(DunbarCircle.recognition), 1);
    });

    test('overTarget flags a layer past its Dunbar size', () {
      // 6 tier-4 connected peers > support target of 5.
      final peers = List.generate(
          6, (i) => _peer(connected: true, repScore: 0.95, repRated: true, seed: i + 1));
      final g = CircleGrouping.from(peers);
      expect(g.countIn(DunbarCircle.support), 6);
      expect(g.overTarget(DunbarCircle.support), isTrue);
      expect(g.overTarget(DunbarCircle.active), isFalse);
    });
  });
}
