// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Business posts in the feed (Phase 3 P3.4, box 5). The PeerService is
// constructed but never started; posts are injected via ingestEvents with a
// stub bundle verifier standing in for the Ethne cdylib — which is also how
// the REFUSAL path is exercised, since a verifier that says no is the only
// difference between a post that is read and one that is counted.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/model/business_post.dart';
import 'package:agora/src/model/feed_entry.dart';
import 'package:agora/src/model/post.dart';
import 'package:agora/src/node/peer_stream.dart';

const _cafe = 'did:key:zCafe';

String _postBundle({
  String polity = _cafe,
  String body = 'Fresh croissants at seven.',
  int seq = 1,
}) =>
    jsonEncode({
      'post': {
        'payload': {'polity': polity, 'body': body, 'seq': seq},
        'sig': 'stub',
      },
      'delegation': {
        'payload': {'polity': polity},
        'sig': 'stub',
      },
    });

String _pageBundle({String polity = _cafe, String name = 'Corner Cafe'}) =>
    jsonEncode({
      'page': {
        'payload': {
          'polity': polity,
          'name': name,
          'category': 'cafe',
          'description': 'coffee and a chair',
          'locality': '9q8yyk8y',
          'contact': 'hello@cafe',
          'seq': 1,
        },
        'sig': 'stub',
      },
      'delegation': {
        'payload': {'polity': polity},
        'sig': 'stub',
      },
    });

AtRawEvent _postEvent(
  List<int> sender, {
  String polity = _cafe,
  required String postId,
  int seq = 1,
  double ts = 1000,
  int hops = 0,
  String? bundle,
}) =>
    AtRawEvent(
      kind: agoraEventBusinessPost,
      uuid: sender,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      businessPostPolity: polity,
      businessPostId: postId,
      businessPostSeq: seq,
      businessPostTs: ts,
      businessPostHops: hops,
      businessPostBundle: bundle ?? _postBundle(polity: polity, seq: seq),
    );

AtRawEvent _adEvent(
  List<int> advertiser, {
  String polity = _cafe,
  required String adId,
  double ts = 900,
}) =>
    AtRawEvent(
      kind: agoraEventBusinessAd,
      uuid: advertiser,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      businessPolity: polity,
      businessAdId: adId,
      businessSatisfaction: agoraBusinessSatSelf,
      businessSeq: 1,
      businessTs: ts,
      businessBundle: _pageBundle(polity: polity),
    );

AtRawEvent _personPost(List<int> author, String id, String body,
        {double ts = 1000}) =>
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
      postSeq: 1,
      postTs: ts,
      postRequiredTier: 0,
      postBody: body,
    );

void main() {
  final biz = List<int>.filled(16, 0xB1);
  final relay = List<int>.filled(16, 0xA9);
  final person = List<int>.filled(16, 0x77);

  group('the bundle is parsed for display, never for trust', () {
    test('the body comes out of the post payload', () {
      expect(BusinessPost.parseBody(_postBundle(body: 'Closing at four.')),
          'Closing at four.');
    });

    test('a bundle that is not JSON, or is a page, yields no body', () {
      // A page bundle is well-formed JSON and perfectly valid — as a PAGE. It
      // is not a post, and must not be rendered as one.
      expect(BusinessPost.parseBody('not json at all'), '');
      expect(BusinessPost.parseBody(_pageBundle()), '');
      expect(BusinessPost.parseBody(''), '');
    });
  });

  group('receiving business posts (ingestEvents)', () {
    test('a verified post reaches the feed, named off its page', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([
        _adEvent(biz, adId: 'ad1'), // how this node comes to know the cafe
        _postEvent(biz, postId: 'p1'),
      ]);
      expect(svc.feedCount, 1);
      final entry = svc.feed.single as BusinessEntry;
      expect(entry.body, 'Fresh croissants at seven.');
      expect(entry.displayName, 'Corner Cafe');
      expect(entry.verifiedAgainstCharter, isTrue);
      expect(entry.post.hops, 0);
      expect(svc.businessPostsUnverified, 0);
    });

    test('an unverified post is counted and shown to nobody', () {
      // THE LOAD-BEARING ONE. The post is well-formed and the core accepted
      // it; only the envoy chain fails. Nothing of it may appear in the feed,
      // and the reader must still be told it happened.
      final svc = PeerService(bundleVerifier: (_) => false);
      svc.ingestEvents([_postEvent(biz, postId: 'p1')]);
      expect(svc.feed, isEmpty);
      expect(svc.feedCount, 0);
      expect(svc.businessPostsUnverified, 1);
    });

    test('a post with a duplicate content id is deduped', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([
        _postEvent(biz, postId: 'dup'),
        _postEvent(biz, postId: 'dup'), // the same post by another gossip path
      ]);
      expect(svc.feedCount, 1);
    });

    test('a relayed post is carried, and says it was relayed', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([
        _adEvent(biz, adId: 'ad1'),
        _postEvent(relay, postId: 'p1', hops: 1),
      ]);
      final entry = svc.feed.single as BusinessEntry;
      // The sender is NOT the authority — a relay is just a carrier — so the
      // post is still the cafe's, and the hop count is kept as provenance.
      expect(entry.displayName, 'Corner Cafe');
      expect(entry.post.hops, 1);
    });

    test('with no page held, the DID stands in for a name', () {
      // The core drops these, so this is the app's second refusal to invent
      // anything: no verified page, no name.
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([_postEvent(biz, postId: 'p1')]);
      final entry = svc.feed.single as BusinessEntry;
      expect(entry.displayName, isEmpty);
    });
  });

  group('the merged feed', () {
    test('holds both kinds at once', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([
        _adEvent(biz, adId: 'ad1'),
        _postEvent(biz, postId: 'bp1'),
        _personPost(person, 'pp1', 'from a friend'),
      ]);
      expect(svc.feedCount, 2);
      expect(svc.feed.whereType<BusinessEntry>().length, 1);
      expect(svc.feed.whereType<PersonEntry>().length, 1);
    });

    test('a business post does not draw on the Dunbar attention budget', () {
      // P3.2's locked decision, surviving into the feed: business ties keep
      // their own ledger. The proof is that an UNKNOWN person's post and a
      // business post rank on different terms — the person at strength 0
      // (nobody we can place), the business on its directory standing — so
      // the business is not competing for the same scarce attention.
      //
      // Both timestamps are NOW, because both terms carry a recency decay and
      // an hour-old fixture would read as "no standing" when what it means is
      // "long ago". (An unplaced business with no customers and a stale ad
      // genuinely does score 0 — it appears, ordered by freshness among its
      // equals, and outranks nothing.)
      final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([
        _adEvent(biz, adId: 'ad1', ts: now),
        _postEvent(biz, postId: 'bp1', ts: now),
        _personPost(person, 'pp1', 'from a stranger', ts: now),
      ]);
      final entries = svc.feed;
      final business = entries.whereType<BusinessEntry>().single;
      final stranger = entries.whereType<PersonEntry>().single;
      expect(stranger.score, 0.0,
          reason: 'an unplaceable author has no tie strength');
      expect(business.score, greaterThan(0.0),
          reason: 'a known business still has standing of its own');
    });

    test('ranking is deterministic', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([
        _adEvent(biz, adId: 'ad1'),
        _postEvent(biz, postId: 'bp1'),
        _personPost(person, 'pp1', 'from a friend'),
      ]);
      expect(svc.feed.map((e) => e.id).toList(),
          svc.feed.map((e) => e.id).toList());
    });
  });

  group('publishing as the business (no channel)', () {
    test('a verified post is echoed locally at once', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      var notified = 0;
      svc.addListener(() => notified++);
      final rc = svc.publishBusinessPost(_cafe, _postBundle());
      expect(rc, -1); // no event channel open yet
      final entry = svc.feed.single as BusinessEntry;
      expect(entry.outgoing, isTrue);
      expect(entry.body, 'Fresh croissants at seven.');
      expect(notified, greaterThan(0));
    });

    test('a bundle this node cannot prove is refused before the wire', () {
      // Publishing does not confer authority, and the app says so on the
      // operator's OWN screen rather than letting them find out from everyone
      // else's silence.
      final svc = PeerService(bundleVerifier: (_) => false);
      final rc = svc.publishBusinessPost(_cafe, _postBundle());
      expect(rc, -1);
      expect(svc.feed, isEmpty);
      expect(svc.businessPostsUnverified, 1);
    });

    test('empty arguments are refused', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      expect(svc.publishBusinessPost('', _postBundle()), -1);
      expect(svc.publishBusinessPost(_cafe, ''), -1);
      expect(svc.feed, isEmpty);
      expect(svc.businessPostsUnverified, 0,
          reason: 'an empty argument is a caller bug, not a failed proof');
    });
  });

  group('BusinessPostStore', () {
    test('counts refusals separately from what it holds', () {
      final store = BusinessPostStore();
      store.recordUnverified();
      store.recordUnverified();
      expect(store.length, 0);
      expect(store.unverifiedCount, 2);
    });

    test('an outgoing echo with no content id is still visible', () {
      final store = BusinessPostStore();
      final added = store.add(const BusinessPost(
        polity: _cafe,
        postId: '',
        seq: 0,
        ts: 1000,
        hops: 0,
        bundle: '{}',
        outgoing: true,
      ));
      expect(added, isTrue);
      expect(store.length, 1);
      expect(store.posts.single.postId, isNotEmpty,
          reason: 'a synthetic key so a local publish is never lost');
    });
  });

  group('rankFeed', () {
    test('an outgoing post of either kind never sinks', () {
      final entries = rankFeed(
        posts: [
          const Post(
            authorUuid: [],
            postId: 'mine',
            seq: 0,
            ts: 1000,
            requiredTier: 0,
            body: 'mine',
            outgoing: true,
          ),
        ],
        businessPosts: [
          const BusinessPost(
            polity: _cafe,
            postId: 'theirs',
            seq: 1,
            ts: 1000,
            hops: 0,
            bundle: '{}',
            outgoing: false,
          ),
        ],
        strengthOfAuthor: (_) => 0.0,
        standingOfBusiness: (_) => 0.1,
        nameOfBusiness: (_) => 'Corner Cafe',
        recency: (_) => 1.0,
      );
      expect(entries.first.id, 'mine');
    });
  });
}
