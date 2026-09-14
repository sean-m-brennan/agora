// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Pure-Dart tests for the post-reaction app surface (Increment 8): a received
// reaction (AT_APP_EVENT_REACTION) to one of our posts, routed by ingestEvents
// into the reaction tally and tending the reactor's tie. ingestEvents-driven and
// never loads the native shim, so it runs under `flutter test` without a built
// libagora_shim.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/model/post.dart';
import 'package:agora/src/node/peer_stream.dart';

AtRawEvent _reactionEvent(List<int> uuid, String postId, {int seq = 1}) =>
    AtRawEvent(
      kind: agoraEventReaction,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      reactionPostId: postId,
      reactionSeq: seq,
      reactionTs: 1000,
    );

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
  final reactor = List<int>.filled(16, 0x11);
  const postId = 'abcd1234';

  group('receiving reactions (ingestEvents)', () {
    test('a reaction to our post is tallied by content id', () {
      final svc = PeerService();
      svc.ingestEvents([_reactionEvent(reactor, postId)]);
      expect(svc.reactionsFor(postId), 1);
    });

    test('multiple reactions accumulate; unrelated posts stay zero', () {
      final svc = PeerService();
      svc.ingestEvents([
        _reactionEvent(reactor, postId),
        _reactionEvent(List<int>.filled(16, 0x22), postId, seq: 2),
      ]);
      expect(svc.reactionsFor(postId), 2);
      expect(svc.reactionsFor('other'), 0);
    });

    test('a reaction from a known peer tends the tie (interaction recency)', () {
      final svc = PeerService();
      // The reactor is first a known roster peer (via a reputation event).
      svc.ingestEvents([_repEvent(reactor, 0.7)]);
      final before = svc.peers.single.lastInteractionAt;
      svc.ingestEvents([_reactionEvent(reactor, postId)]);
      final after = svc.peers.single.lastInteractionAt;
      expect(after, greaterThanOrEqualTo(before));
      expect(after, greaterThan(0));
    });

    test('a reaction is not merged into the peer as an event', () {
      final svc = PeerService();
      svc.ingestEvents([_reactionEvent(reactor, postId)]);
      // A reaction is consumed by the tally, not surfaced as a roster peer.
      expect(svc.peers, isEmpty);
    });
  });

  group('reactToPost / blockPeer (no channel)', () {
    Post received(List<int> author, String pid) => Post(
          authorUuid: author,
          postId: pid,
          seq: 1,
          ts: 1000,
          requiredTier: 0,
          body: 'hi',
          outgoing: false,
        );

    test('reactToPost on a post with no author/content id returns -1', () {
      final svc = PeerService();
      expect(svc.reactToPost(received(const [], '')), -1);
      expect(svc.reactToPost(received(reactor, '')), -1);
    });

    test('reactToPost with a valid post but no open channel returns -1', () {
      final svc = PeerService();
      // No daemon/event channel in a pure-Dart test -> graceful -1, no throw.
      expect(svc.reactToPost(received(reactor, postId)), -1);
    });

    test('blockPeer with no open channel returns -1', () {
      final svc = PeerService();
      expect(svc.blockPeer(AgoraPeer(uuid: reactor)), -1);
    });
  });
}
