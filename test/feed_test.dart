// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Pure-Dart tests for the feed app surface (Increment 7): a received post
// (AT_APP_EVENT_POST) decoded and routed into the FeedStore by ingestEvents,
// content-id dedup, local publish echo, and S × recency ranking. These are
// ingestEvents-driven and never load the native shim, so they run under
// `flutter test` without a built libagora_shim.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/model/feed_store.dart';
import 'package:agora/src/model/post.dart';
import 'package:agora/src/model/tie_strength.dart';
import 'package:agora/src/node/peer_stream.dart';

AtRawEvent _postEvent(
  List<int> author,
  String id,
  String body, {
  int seq = 1,
  double ts = 1000,
  int tier = 0,
}) =>
    AtRawEvent(
      kind: agoraEventPost,
      uuid: author,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      postId: id,
      postSeq: seq,
      postTs: ts,
      postRequiredTier: tier,
      postBody: body,
    );

void main() {
  final u1 = List<int>.filled(16, 0x11);
  final u2 = List<int>.filled(16, 0x22);

  group('receiving posts (ingestEvents)', () {
    test('a received post appears in the feed with its fields', () {
      final svc = PeerService();
      svc.ingestEvents([_postEvent(u1, 'id1', 'hello feed', seq: 3, tier: 1)]);
      expect(svc.feedCount, 1);
      final p = svc.feed.single;
      expect(p.body, 'hello feed');
      expect(p.seq, 3);
      expect(p.requiredTier, 1);
      expect(p.outgoing, isFalse);
      expect(p.authorHex, List<int>.filled(16, 0x11).map((b) => '11').join());
    });

    test('a post with a duplicate content id is deduped', () {
      final svc = PeerService();
      svc.ingestEvents([
        _postEvent(u1, 'dup', 'once'),
        _postEvent(u1, 'dup', 'once'), // same content id — a gossip re-delivery
      ]);
      expect(svc.feedCount, 1);
    });

    test('distinct posts from distinct authors both land', () {
      final svc = PeerService();
      svc.ingestEvents([
        _postEvent(u1, 'a', 'from u1'),
        _postEvent(u2, 'b', 'from u2'),
      ]);
      expect(svc.feedCount, 2);
      expect(svc.feed.map((p) => p.body).toSet(), {'from u1', 'from u2'});
    });
  });

  group('publishing posts (no channel)', () {
    test('publishPost echoes an outgoing post into the feed', () {
      final svc = PeerService();
      var notified = 0;
      svc.addListener(() => notified++);
      final rc = svc.publishPost('my post', PostAudience.friend);
      expect(rc, -1); // no event channel open yet
      final p = svc.feed.single;
      expect(p.body, 'my post');
      expect(p.outgoing, isTrue);
      expect(p.requiredTier, minTierForAudience(PostAudience.friend));
      expect(notified, greaterThan(0));
    });

    test('an empty/whitespace body is not published', () {
      final svc = PeerService();
      expect(svc.publishPost('   ', PostAudience.public), -1);
      expect(svc.feedCount, 0);
    });
  });

  group('FeedStore dedup + ranking', () {
    test('add returns false for a duplicate id', () {
      final store = FeedStore();
      final p = Post(
        authorUuid: u1,
        postId: 'x',
        seq: 1,
        ts: 1,
        requiredTier: 0,
        body: 'b',
        outgoing: false,
      );
      expect(store.add(p), isTrue);
      expect(store.add(p), isFalse);
      expect(store.length, 1);
    });

    test('ranked orders by S × recency, strongest/newest first', () {
      final store = FeedStore();
      // Two authors: strong (S=1.0) and weak (S=0.1), same post time.
      store.add(Post(
        authorUuid: u1,
        postId: 'weak',
        seq: 1,
        ts: 1000,
        requiredTier: 0,
        body: 'weak author',
        outgoing: false,
      ));
      store.add(Post(
        authorUuid: u2,
        postId: 'strong',
        seq: 1,
        ts: 1000,
        requiredTier: 0,
        body: 'strong author',
        outgoing: false,
      ));
      double strength(List<int> a) => a == u2 ? 1.0 : 0.1;
      final ranked = store.ranked(
        strengthOfAuthor: strength,
        nowEpochSeconds: 1000,
      );
      expect(ranked.first.body, 'strong author');
      expect(ranked.last.body, 'weak author');
    });

    test('recency decays an older post below a newer one from the same author',
        () {
      final store = FeedStore();
      store.add(Post(
        authorUuid: u1,
        postId: 'old',
        seq: 1,
        ts: 0,
        requiredTier: 0,
        body: 'old',
        outgoing: false,
      ));
      store.add(Post(
        authorUuid: u1,
        postId: 'new',
        seq: 2,
        ts: 86000,
        requiredTier: 0,
        body: 'new',
        outgoing: false,
      ));
      final ranked = store.ranked(
        strengthOfAuthor: (_) => 1.0,
        nowEpochSeconds: 86000,
      );
      expect(ranked.first.body, 'new');
    });
  });
}
