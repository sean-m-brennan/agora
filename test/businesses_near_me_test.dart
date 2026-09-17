// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Widget tests for the businesses-near-me page (Phase 3 P3.2). The PeerService
// is constructed but never started; business ads are injected via ingestEvents
// with a stub bundle verifier standing in for the Ethne cdylib.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/businesses_near_me.dart';

String _bundle({
  String polity = 'did:key:zCafe',
  String name = 'Corner Cafe',
  String category = 'cafe',
  String description = 'coffee and a chair',
  String locality = '9q8yyk8y',
  String contact = 'hello@cafe',
  int seq = 1,
}) =>
    jsonEncode({
      'page': {
        'payload': {
          'polity': polity,
          'name': name,
          'category': category,
          'description': description,
          'locality': locality,
          'contact': contact,
          'seq': seq,
        },
        'sig': 'stub',
      },
      'delegation': {
        'payload': {'polity': polity},
        'sig': 'stub',
      },
    });

AtRawEvent _adEvent(
  List<int> advertiser, {
  String polity = 'did:key:zCafe',
  required String adId,
  int sat = agoraBusinessSatSelf,
  int seq = 1,
  double ts = 1000,
  String? bundle,
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
      businessSatisfaction: sat,
      businessSeq: seq,
      businessTs: ts,
      businessBundle: bundle ?? _bundle(polity: polity, seq: seq),
    );

void main() {
  final biz = List<int>.filled(16, 0xB1);
  final cust = List<int>.filled(16, 0xC1);

  testWidgets('an empty directory says so rather than showing nothing',
      (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    await tester.pumpWidget(
        MaterialApp(home: BusinessesNearMePage(service: svc)));
    expect(find.textContaining('No businesses yet'), findsOneWidget);
  });

  testWidgets('a business renders its page fields and its locality bucket',
      (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    svc.ingestEvents([_adEvent(biz, adId: 'a1')]);
    await tester.pumpWidget(
        MaterialApp(home: BusinessesNearMePage(service: svc)));

    expect(find.text('Corner Cafe'), findsOneWidget);
    expect(find.text('cafe'), findsOneWidget);
    expect(find.text('coffee and a chair'), findsOneWidget);
    expect(find.text('9q8yyk8y'), findsOneWidget);
  });

  testWidgets('a business nobody patronizes shows zero customers vouching',
      (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    svc.ingestEvents([_adEvent(biz, adId: 'a1')]); // its OWN ad only
    await tester.pumpWidget(
        MaterialApp(home: BusinessesNearMePage(service: svc)));
    expect(find.text('no customers vouching yet'), findsOneWidget);
  });

  testWidgets('a customer ad is counted as a voucher', (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    svc.ingestEvents([
      _adEvent(biz, adId: 'a1'),
      _adEvent(cust, adId: 'a2', sat: 4, ts: 1001),
    ]);
    await tester.pumpWidget(
        MaterialApp(home: BusinessesNearMePage(service: svc)));
    expect(find.text('1 customer vouching'), findsOneWidget);
  });

  testWidgets('unverifiable pages are reported, not silently hidden',
      (tester) async {
    final svc = PeerService(bundleVerifier: (_) => false);
    svc.ingestEvents([_adEvent(biz, adId: 'a1')]);
    await tester.pumpWidget(
        MaterialApp(home: BusinessesNearMePage(service: svc)));
    expect(find.textContaining('could not be verified'), findsOneWidget);
    expect(find.textContaining('No businesses yet'), findsOneWidget);
  });

  testWidgets('rating a business records our own customer edge',
      (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    svc.ingestEvents([_adEvent(biz, adId: 'a1')]);
    await tester.pumpWidget(
        MaterialApp(home: BusinessesNearMePage(service: svc)));

    expect(find.byKey(const Key('business-my-vouch')), findsNothing);
    await tester.tap(find.byKey(const Key('business-vouch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('business-sat-4')));
    await tester.pumpAndSettle();

    expect(svc.customerSatisfaction('did:key:zCafe'), 4);
    expect(find.byKey(const Key('business-my-vouch')), findsOneWidget);
    expect(find.text('You vouch · 4'), findsOneWidget);
  });

  testWidgets('going quiet withdraws the edge without publishing anything',
      (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    svc.ingestEvents([_adEvent(biz, adId: 'a1')]);
    svc.markCustomer('did:key:zCafe', 3);
    await tester.pumpWidget(
        MaterialApp(home: BusinessesNearMePage(service: svc)));

    expect(find.byKey(const Key('business-go-quiet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('business-go-quiet')));
    await tester.pumpAndSettle();

    expect(svc.customerSatisfaction('did:key:zCafe'), isNull);
    expect(find.byKey(const Key('business-go-quiet')), findsNothing);
  });

  testWidgets('the nearer business is listed first', (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    svc.setOwnPosition('9q8yyk8y'); // San Francisco (no channel: kept locally)
    svc.ingestEvents([
      _adEvent(biz,
          polity: 'did:key:zFar',
          adId: 'f',
          bundle: _bundle(
              polity: 'did:key:zFar', name: 'Far Cafe', locality: '9q5ctr18')),
      _adEvent(biz,
          polity: 'did:key:zNear',
          adId: 'n',
          bundle: _bundle(
              polity: 'did:key:zNear', name: 'Near Cafe', locality: '9q8yyk8y')),
    ]);
    await tester.pumpWidget(
        MaterialApp(home: BusinessesNearMePage(service: svc)));

    final near = tester.getTopLeft(find.text('Near Cafe')).dy;
    final far = tester.getTopLeft(find.text('Far Cafe')).dy;
    expect(near, lessThan(far));
  });
}
