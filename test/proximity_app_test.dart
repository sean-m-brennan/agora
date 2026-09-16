// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// App-side private-proximity (Phase 2): the kind-11 event updates the peer's
// band + label, ingest routes it, and the PeerService verbs no-op safely before
// the channel is open.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/node/peer_stream.dart';

AtRawEvent _proximityEvent(List<int> uuid, int band) => AtRawEvent(
      kind: agoraEventProximity,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      proximityBand: band,
    );

void main() {
  final u1 = List<int>.filled(16, 0x11);

  group('AgoraPeer proximity band', () {
    test('applyEvent sets the band; label maps the value', () {
      final p = AgoraPeer(uuid: u1);
      expect(p.proximityBand, 0);
      expect(p.proximityLabel, isNull);

      p.applyEvent(_proximityEvent(u1, 1));
      expect(p.proximityBand, 1);
      expect(p.proximityLabel, '<1 km');

      p.applyEvent(_proximityEvent(u1, 2));
      expect(p.proximityLabel, '<5 km');

      p.applyEvent(_proximityEvent(u1, 3));
      expect(p.proximityLabel, 'far');

      p.applyEvent(_proximityEvent(u1, 0));
      expect(p.proximityLabel, isNull); // unknown
    });
  });

  group('PeerService proximity', () {
    test('a proximity event routes to the peer and updates its band', () {
      final svc = PeerService();
      svc.ingestEvents([_proximityEvent(u1, 2)]);
      final peer = svc.peers.firstWhere((p) => p.uuid == u1);
      expect(peer.proximityBand, 2);
      expect(peer.proximityLabel, '<5 km');
    });

    test('requestProximity before channel open returns -1', () {
      final svc = PeerService();
      expect(svc.requestProximity(AgoraPeer(uuid: u1)), -1);
    });

    test('setOwnExactPosition before channel open remembers opt-in', () {
      final svc = PeerService();
      expect(svc.ownExactOptIn, isFalse);
      final rc = svc.setOwnExactPosition(optIn: true, lat: 37.0, lon: -122.0);
      expect(rc, -1); // no channel yet
      expect(svc.ownExactOptIn, isTrue);
      svc.setOwnExactPosition(optIn: false);
      expect(svc.ownExactOptIn, isFalse);
    });
  });
}
