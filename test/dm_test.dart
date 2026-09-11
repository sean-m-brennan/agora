// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Pure-Dart tests for the direct-message app surface (Increment 6): a received
// DM (AT_APP_EVENT_DM) routed into the per-peer thread by ingestEvents, and the
// local echo + interaction-recency stamp on send. These are ingestEvents-driven
// and never load the native shim, so they run under `flutter test` without a
// built libagora_shim.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/node/peer_stream.dart';

AtRawEvent _dmEvent(List<int> uuid, int seq, String text, {double ts = 1000}) =>
    AtRawEvent(
      kind: agoraEventDm,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      dmSeq: seq,
      dmTs: ts,
      dmText: text,
    );

void main() {
  final u1 = List<int>.filled(16, 0x11);
  final u2 = List<int>.filled(16, 0x22);

  group('receiving DMs (ingestEvents)', () {
    test('a received DM appears in messagesFor(peer) with its text/seq', () {
      final svc = PeerService();
      svc.ingestEvents([_dmEvent(u1, 1, 'hello there')]);
      final peer = svc.peers.single;
      final msgs = svc.messagesFor(peer);
      expect(msgs, hasLength(1));
      expect(msgs.single.text, 'hello there');
      expect(msgs.single.seq, 1);
      expect(msgs.single.outgoing, isFalse);
    });

    test('a received DM flags the peer unread and stamps interaction recency', () {
      final svc = PeerService();
      svc.ingestEvents([_dmEvent(u1, 1, 'hi')]);
      final peer = svc.peers.single;
      expect(svc.hasUnread(peer), isTrue);
      expect(svc.unreadPeerCount, 1);
      // A received DM tends the tie: interaction recency is stamped.
      expect(peer.lastInteractionAt, greaterThan(0));
    });

    test('markThreadRead clears the unread flag', () {
      final svc = PeerService();
      svc.ingestEvents([_dmEvent(u1, 1, 'hi')]);
      final peer = svc.peers.single;
      expect(svc.hasUnread(peer), isTrue);
      svc.markThreadRead(peer);
      expect(svc.hasUnread(peer), isFalse);
      expect(svc.unreadPeerCount, 0);
    });

    test('a repeated incoming seq is deduped', () {
      final svc = PeerService();
      svc.ingestEvents([
        _dmEvent(u1, 1, 'once'),
        _dmEvent(u1, 1, 'once'), // same seq — a re-delivery, not a new message
      ]);
      expect(svc.messagesFor(svc.peers.single), hasLength(1));
    });

    test('distinct seqs from the same peer both land, in order', () {
      final svc = PeerService();
      svc.ingestEvents([
        _dmEvent(u1, 1, 'first'),
        _dmEvent(u1, 2, 'second'),
      ]);
      final msgs = svc.messagesFor(svc.peers.single);
      expect(msgs.map((m) => m.text), ['first', 'second']);
    });

    test('DMs are threaded per peer', () {
      final svc = PeerService();
      svc.ingestEvents([
        _dmEvent(u1, 1, 'to u1'),
        _dmEvent(u2, 1, 'to u2'),
      ]);
      final p1 = svc.peers.firstWhere((p) => p.uuid == u1);
      final p2 = svc.peers.firstWhere((p) => p.uuid == u2);
      expect(svc.messagesFor(p1).single.text, 'to u1');
      expect(svc.messagesFor(p2).single.text, 'to u2');
    });
  });

  group('sending DMs (no channel)', () {
    test('sendDm echoes an outgoing message and stamps recency', () {
      final svc = PeerService();
      final peer = AgoraPeer(uuid: u1);
      var notified = 0;
      svc.addListener(() => notified++);
      final rc = svc.sendDm(peer, 'hey');
      expect(rc, -1); // no event channel open yet
      final msgs = svc.messagesFor(peer);
      expect(msgs, hasLength(1));
      expect(msgs.single.text, 'hey');
      expect(msgs.single.outgoing, isTrue);
      // Sending tends the tie.
      expect(peer.lastInteractionAt, greaterThan(0));
      expect(notified, greaterThan(0));
    });

    test('an empty/whitespace body is not sent', () {
      final svc = PeerService();
      final peer = AgoraPeer(uuid: u1);
      expect(svc.sendDm(peer, '   '), -1);
      expect(svc.messagesFor(peer), isEmpty);
    });

    test('a sent then received message interleave in one thread', () {
      final svc = PeerService();
      // Seed the peer so the received event lands on the same AgoraPeer.
      svc.ingestEvents([_dmEvent(u1, 5, 'incoming')]);
      final peer = svc.peers.single;
      svc.sendDm(peer, 'reply');
      final msgs = svc.messagesFor(peer);
      expect(msgs.map((m) => m.text), ['incoming', 'reply']);
      expect(msgs.map((m) => m.outgoing), [false, true]);
    });
  });
}
