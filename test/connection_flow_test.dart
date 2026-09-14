// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Pure-Dart tests for the explicit-connection app surface (Increment 5): the
// edge-state transitions the AT core emits (CONNECTION_REQUEST / CONNECTION_STATE)
// decoded into AgoraPeer, and the interaction-recency term a connected peer feeds
// into the tie-strength kernel. These are ingestEvents-driven and never load the
// native shim, so they run under `flutter test` without a built libagora_shim.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/model/tie_strength.dart';
import 'package:agora/src/node/peer_stream.dart';

AtRawEvent _connEvent(List<int> uuid, int kind, int state) => AtRawEvent(
      kind: kind,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      connectionState: state,
    );

AtRawEvent _peerEvent(List<int> uuid) => AtRawEvent(
      kind: agoraEventPeer,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
    );

void main() {
  final u1 = List<int>.filled(16, 0x11);
  final u2 = List<int>.filled(16, 0x22);

  group('edge-state transitions (ingestEvents)', () {
    test('request → pending_out', () {
      final svc = PeerService();
      svc.ingestEvents([
        _peerEvent(u1),
        _connEvent(u1, agoraEventConnectionState, 1), // pending_out
      ]);
      final p = svc.peers.single;
      expect(p.connectionState, 1);
      expect(p.connection, ConnectionState.pendingOut);
      expect(p.isConnected, isFalse);
    });

    test('inbound request → pending_in and shows in inboundRequests', () {
      final svc = PeerService();
      svc.ingestEvents([
        _peerEvent(u1),
        _connEvent(u1, agoraEventConnectionRequest, 2), // pending_in
      ]);
      final p = svc.peers.single;
      expect(p.connection, ConnectionState.pendingIn);
      expect(p.hasInboundRequest, isTrue);
      expect(svc.inboundRequests.map((x) => x.uuid), [u1]);
    });

    test('accept → connected', () {
      final svc = PeerService();
      svc.ingestEvents([
        _peerEvent(u1),
        _connEvent(u1, agoraEventConnectionRequest, 2),
        _connEvent(u1, agoraEventConnectionState, 3), // connected
      ]);
      final p = svc.peers.single;
      expect(p.connection, ConnectionState.connected);
      expect(p.isConnected, isTrue);
      expect(p.hasInboundRequest, isFalse);
      expect(svc.inboundRequests, isEmpty);
    });

    test('decline → declined', () {
      final svc = PeerService();
      svc.ingestEvents([
        _peerEvent(u1),
        _connEvent(u1, agoraEventConnectionState, 4), // declined
      ]);
      expect(svc.peers.single.connection, ConnectionState.declined);
    });
  });

  group('request/respond without a channel', () {
    test('requestConnection with no channel returns -1 and stamps interaction', () {
      final svc = PeerService();
      final peer = AgoraPeer(uuid: u1);
      var notified = 0;
      svc.addListener(() => notified++);
      final rc = svc.requestConnection(peer);
      expect(rc, -1); // no event channel open yet
      expect(peer.lastInteractionAt, greaterThan(0)); // interaction stamped
      expect(notified, 1);
    });

    test('respondConnection accept with no channel returns -1 and stamps', () {
      final svc = PeerService();
      final peer = AgoraPeer(uuid: u1);
      final rc = svc.respondConnection(peer, true);
      expect(rc, -1);
      expect(peer.lastInteractionAt, greaterThan(0));
    });

    test('respondConnection decline with no channel returns -1, no stamp', () {
      final svc = PeerService();
      final peer = AgoraPeer(uuid: u1);
      final rc = svc.respondConnection(peer, false);
      expect(rc, -1);
      expect(peer.lastInteractionAt, 0); // decline is not an interaction
    });

    test('a none/declined state for a peer we never asked raises no rejection', () {
      final svc = PeerService();
      // The core echoes edge-state for many reasons; only a revert of an
      // optimistic connect WE initiated is a "connect rejected". A plain
      // none/declined for a peer we never asked must not be reported.
      svc.ingestEvents([
        _connEvent(u1, agoraEventConnectionState, 0), // none
        _connEvent(u2, agoraEventConnectionState, 4), // declined
      ]);
      expect(svc.consumeConnectRejection(), isNull);
    });
  });

  group('interaction recency feeds tie strength', () {
    test('a connected peer stamps a real interaction recency', () {
      final peer = AgoraPeer(uuid: u1);
      expect(peer.lastInteractionAt, 0);
      peer.applyEvent(_connEvent(u1, agoraEventConnectionState, 3));
      expect(peer.isConnected, isTrue);
      // A connection we tend records "now" as the last interaction.
      expect(peer.lastInteractionAt, greaterThan(0));
    });

    test('recencyFactor uses the interaction timestamp, not just presence', () {
      final peer = AgoraPeer(uuid: u1);
      // No presence (operatorAttestedAt == 0): the stand-in would give 0.
      expect(recencyFactor(peer, 1000.0), 0.0);
      // A recent interaction drives recency up even without presence.
      peer.markInteraction(1000.0);
      expect(recencyFactor(peer, 1000.0), 1.0);
      // And it decays with age.
      final aged = recencyFactor(peer, 1000.0 + 86400.0); // ~1 tau later
      expect(aged, lessThan(1.0));
      expect(aged, greaterThan(0.0));
    });

    test('a connected peer outranks an identical un-connected peer', () {
      final svc = PeerService();
      // Two bare peers with no reputation/position/presence: without a
      // connection both score 0. Connecting u2 gives it interaction recency, so
      // its tie strength must rise above the un-connected u1.
      svc.ingestEvents([
        _peerEvent(u1),
        _peerEvent(u2),
        _connEvent(u2, agoraEventConnectionState, 3), // u2 connected
      ]);
      expect(svc.strengthOf(svc.peers.firstWhere((p) => p.uuid == u2)),
          greaterThan(0));
      expect(svc.strengthOf(svc.peers.firstWhere((p) => p.uuid == u1)), 0);
      expect(svc.peers.first.uuid, u2); // connected peer ranks first
    });
  });
}
