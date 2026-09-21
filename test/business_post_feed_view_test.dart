// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Widget tests for business posts IN the feed (Phase 3 P3.4, box 5). Box 5
// asks for two things — that a business's post appears in the ordinary feed,
// and that it is visually distinct from a person's — so these tests assert on
// what a reader can actually see: the storefront mark, the business's name off
// its verified page, the envoy-signed claim stated rather than implied, and
// the banner that counts what was refused.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/feed_view.dart';

const _cafe = 'did:key:zCafeLongEnoughToBeTruncatedInTheUi';

String _postBundle({String body = 'Fresh croissants at seven.', int seq = 1}) =>
    jsonEncode({
      'post': {
        'payload': {'polity': _cafe, 'body': body, 'seq': seq},
        'sig': 'stub',
      },
      'delegation': {
        'payload': {'polity': _cafe},
        'sig': 'stub',
      },
    });

String _pageBundle({String name = 'Corner Cafe'}) => jsonEncode({
      'page': {
        'payload': {
          'polity': _cafe,
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
        'payload': {'polity': _cafe},
        'sig': 'stub',
      },
    });

AtRawEvent _adEvent(List<int> advertiser) => AtRawEvent(
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
      businessPolity: _cafe,
      businessAdId: 'ad1',
      businessSatisfaction: agoraBusinessSatSelf,
      businessSeq: 1,
      businessTs: 1000,
      businessBundle: _pageBundle(),
    );

AtRawEvent _businessPostEvent(List<int> sender,
        {String postId = 'bp1', int hops = 0, String? bundle}) =>
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
      businessPostPolity: _cafe,
      businessPostId: postId,
      businessPostSeq: 1,
      businessPostTs: 1000,
      businessPostHops: hops,
      businessPostBundle: bundle ?? _postBundle(),
    );

AtRawEvent _personPostEvent(List<int> author) => AtRawEvent(
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
      postId: 'pp1',
      postSeq: 1,
      postTs: 1000,
      postRequiredTier: 0,
      postBody: 'a friend says hello',
    );

Future<void> _pumpFeed(WidgetTester tester, PeerService svc) async {
  // A tall viewport: ListView is lazy, so an off-screen tile is never built
  // and a find on it would fail for the wrong reason.
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: FeedPage(service: svc)));
  await tester.pump();
}

void main() {
  final biz = List<int>.filled(16, 0xB1);
  final relay = List<int>.filled(16, 0xA9);
  final person = List<int>.filled(16, 0x77);

  testWidgets('a business post renders as the business, not as a person',
      (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    svc.ingestEvents([_adEvent(biz), _businessPostEvent(biz)]);
    await _pumpFeed(tester, svc);

    expect(find.text('Fresh croissants at seven.'), findsOneWidget);
    // The storefront mark is the visual distinction box 5 asks for; a person's
    // post carries Icons.public or Icons.person and never this.
    expect(find.byIcon(Icons.storefront), findsOneWidget);
    expect(find.byIcon(Icons.person), findsNothing);
    // Named off the VERIFIED page, and said to be direct.
    expect(find.textContaining('Corner Cafe'), findsOneWidget);
    expect(find.textContaining('direct from the business'), findsOneWidget);
    // The claim the reader relies on is stated, not implied by mere presence.
    expect(find.text('envoy-signed'), findsOneWidget);
    expect(find.byIcon(Icons.verified), findsOneWidget);
  });

  testWidgets('both kinds share one feed, told apart by their tiles',
      (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    svc.ingestEvents(
        [_adEvent(biz), _businessPostEvent(biz), _personPostEvent(person)]);
    await _pumpFeed(tester, svc);

    expect(find.text('Fresh croissants at seven.'), findsOneWidget);
    expect(find.text('a friend says hello'), findsOneWidget);
    expect(find.byIcon(Icons.storefront), findsOneWidget);
    expect(find.byIcon(Icons.public), findsOneWidget);
  });

  testWidgets('a relayed post says so', (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    svc.ingestEvents([_adEvent(biz), _businessPostEvent(relay, hops: 1)]);
    await _pumpFeed(tester, svc);

    expect(find.textContaining('relayed'), findsOneWidget);
    expect(find.textContaining('direct from the business'), findsNothing);
  });

  testWidgets('with no page held, the DID shows rather than a made-up name',
      (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    svc.ingestEvents([_businessPostEvent(biz)]); // no ad, so no page
    await _pumpFeed(tester, svc);

    // Truncated for the tile, but unmistakably the DID and not a name.
    expect(find.textContaining('did:key:zCafeLongEno'), findsOneWidget);
    expect(find.textContaining('Corner Cafe'), findsNothing);
  });

  testWidgets('an unverified post is counted in the banner, never rendered',
      (tester) async {
    final svc = PeerService(bundleVerifier: (_) => false);
    svc.ingestEvents([_businessPostEvent(biz)]);
    await _pumpFeed(tester, svc);

    // Not one word of it appears anywhere.
    expect(find.text('Fresh croissants at seven.'), findsNothing);
    expect(find.byIcon(Icons.storefront), findsNothing);
    // And the reader is told, so silence is not mistaken for nothing arriving.
    expect(find.textContaining('1 business post could not be verified'),
        findsOneWidget);
  });

  testWidgets('the banner counts every refusal, not just the first',
      (tester) async {
    // A count that stopped at one would read as "something went wrong once"
    // when what happened is that a business is being impersonated repeatedly.
    var calls = 0;
    final svc = PeerService(bundleVerifier: (_) {
      calls++;
      return calls == 1; // the first verifies, the rest do not
    });
    svc.ingestEvents([
      _adEvent(biz), // consumes the one truthy verification (the page)
      _businessPostEvent(biz, postId: 'bad1'),
      _businessPostEvent(biz, postId: 'bad2'),
    ]);
    await _pumpFeed(tester, svc);

    expect(find.textContaining('2 business posts could not be verified'),
        findsOneWidget);
    expect(find.text('Fresh croissants at seven.'), findsNothing);
  });

  testWidgets('an empty feed with refusals says both things', (tester) async {
    final svc = PeerService(bundleVerifier: (_) => false);
    svc.ingestEvents([_businessPostEvent(biz)]);
    await _pumpFeed(tester, svc);

    expect(find.textContaining('could not be verified'), findsOneWidget);
    expect(find.textContaining('No posts yet'), findsOneWidget);
  });
}
