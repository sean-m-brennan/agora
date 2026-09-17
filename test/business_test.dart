// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Pure-Dart tests for the businesses-near-me app surface (Phase 3 P3.2): bundle
// parsing, the directory's Ethne verification gate, the page/endorser merge, the
// ranking kernel, and the PeerService wiring that routes AT_APP_EVENT_BUSINESS_AD
// into the directory. These are ingestEvents-driven and never load the native
// shim or the Ethne cdylib, so they run under `flutter test` unbuilt.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/model/business.dart';
import 'package:agora/src/model/business_directory.dart';
import 'package:agora/src/node/peer_stream.dart';

/// A stand-in for an Ethne page bundle with the real nesting
/// ({"page":{"payload":{...}}}), which is all the app parses. Authenticity is
/// the verifier's business, not the parser's.
String _bundle({
  String polity = 'did:key:zCafe',
  String name = 'Corner Cafe',
  String category = 'cafe',
  String locality = '9q8yyk8y',
  int seq = 1,
}) =>
    jsonEncode({
      'page': {
        'payload': {
          'polity': polity,
          'name': name,
          'category': category,
          'description': 'coffee and a chair',
          'locality': locality,
          'contact': 'hello@cafe',
          'seq': seq,
        },
        'sig': 'stub',
      },
      'delegation': {
        'payload': {'polity': polity},
        'sig': 'stub',
      },
    });

BusinessAd _ad(
  List<int> advertiser, {
  String polity = 'did:key:zCafe',
  required String adId,
  int sat = agoraBusinessSatSelf,
  int seq = 1,
  double ts = 1000,
  String? bundle,
}) =>
    BusinessAd(
      advertiserUuid: advertiser,
      polity: polity,
      adId: adId,
      satisfaction: sat,
      seq: seq,
      ts: ts,
      bundle: bundle ?? _bundle(polity: polity, seq: seq),
    );

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
  final cust1 = List<int>.filled(16, 0xC1);
  final cust2 = List<int>.filled(16, 0xC2);

  group('BusinessPage.parse', () {
    test('reads the page payload out of a bundle', () {
      final p = BusinessPage.parse(_bundle(seq: 4))!;
      expect(p.name, 'Corner Cafe');
      expect(p.category, 'cafe');
      expect(p.locality, '9q8yyk8y');
      expect(p.contact, 'hello@cafe');
      expect(p.seq, 4);
    });

    test('returns null for non-JSON, empty, or page-less bundles', () {
      expect(BusinessPage.parse(''), isNull);
      expect(BusinessPage.parse('not json'), isNull);
      expect(BusinessPage.parse('{"delegation":{}}'), isNull);
      expect(BusinessPage.parse('{"page":{"nopayload":1}}'), isNull);
    });
  });

  group('the Ethne verification gate', () {
    test('a bundle the verifier rejects never enters the directory', () {
      final dir = BusinessDirectory(verifyBundle: (_) => false);
      expect(dir.add(_ad(biz, adId: 'a1')), isFalse);
      expect(dir.length, 0);
      expect(dir.rejectedUnverified, 1);
    });

    test('a bundle the verifier accepts is stored with its parsed page', () {
      final dir = BusinessDirectory(verifyBundle: (_) => true);
      expect(dir.add(_ad(biz, adId: 'a1')), isTrue);
      expect(dir.length, 1);
      expect(dir.rejectedUnverified, 0);
      expect(dir['did:key:zCafe']!.displayName, 'Corner Cafe');
    });

    test('the verifier sees the exact bundle bytes', () {
      String? seen;
      final dir = BusinessDirectory(verifyBundle: (b) {
        seen = b;
        return true;
      });
      final ad = _ad(biz, adId: 'a1');
      dir.add(ad);
      expect(seen, ad.bundle);
    });
  });

  group('merge', () {
    test('a duplicate ad id is dropped', () {
      final dir = BusinessDirectory.unverified();
      expect(dir.add(_ad(biz, adId: 'same')), isTrue);
      expect(dir.add(_ad(biz, adId: 'same')), isFalse);
      expect(dir.length, 1);
      expect(dir.containsAd('same'), isTrue);
    });

    test('a newer page version replaces the one held; an older one does not',
        () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz, adId: 'v2', seq: 2, bundle: _bundle(name: 'Cafe v2', seq: 2)));
      dir.add(_ad(cust1,
          adId: 'v1', sat: 3, seq: 1, bundle: _bundle(name: 'Cafe v1', seq: 1)));
      final b = dir['did:key:zCafe']!;
      expect(b.seq, 2);
      expect(b.displayName, 'Cafe v2');
    });

    test("the business's own ad is not an endorsement", () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz, adId: 'self'));
      final b = dir['did:key:zCafe']!;
      expect(b.endorsers, isEmpty);
      expect(b.selfAdvertised, isTrue);
    });

    test('each customer endorses once, keeping their most recent ad', () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(cust1, adId: 'c1a', sat: 2, ts: 1000));
      dir.add(_ad(cust1, adId: 'c1b', sat: 4, ts: 2000));
      dir.add(_ad(cust2, adId: 'c2', sat: 3, ts: 1500));
      final b = dir['did:key:zCafe']!;
      expect(b.endorsers.length, 2);
      expect(b.endorsers[b.endorsers.keys.first]!.satisfaction, 4);
      expect(b.lastHeardAt, 2000);
    });

    test('an ad with no bundle can still endorse a page already held', () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz, adId: 'self'));
      expect(dir.add(_ad(cust1, adId: 'c1', sat: 4, bundle: '')), isTrue);
      expect(dir['did:key:zCafe']!.endorsers.length, 1);
    });

    test('an ad with no bundle for an unknown business is dropped', () {
      final dir = BusinessDirectory.unverified();
      expect(dir.add(_ad(cust1, adId: 'c1', sat: 4, bundle: '')), isFalse);
      expect(dir.length, 0);
    });

    test('an ad with no polity is dropped', () {
      final dir = BusinessDirectory.unverified();
      expect(dir.add(_ad(biz, adId: 'x', polity: '')), isFalse);
      expect(dir.length, 0);
    });

    test('the ad-id ring is bounded', () {
      final dir = BusinessDirectory.unverified(adDedupCap: 4);
      for (var i = 0; i < 6; i++) {
        dir.add(_ad(cust1, adId: 'ad$i', sat: 1, ts: 1000.0 + i));
      }
      expect(dir.containsAd('ad5'), isTrue);
      expect(dir.containsAd('ad0'), isFalse); // evicted
    });
  });

  group('ranking', () {
    const here = '9q8yyk8y';
    double strong(List<int> _) => 1.0;
    double none(List<int> _) => 0.0;

    test('self-vouching is worth exactly zero', () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz, adId: 'self'));
      final b = dir['did:key:zCafe']!;
      expect(dir.vouch(b, strong), 0.0);
    });

    test('a happy customer you trust raises the vouch term', () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz, adId: 'self'));
      final before = dir.vouch(dir['did:key:zCafe']!, strong);
      dir.add(_ad(cust1, adId: 'c1', sat: 4));
      final after = dir.vouch(dir['did:key:zCafe']!, strong);
      expect(before, 0.0);
      expect(after, greaterThan(0.0));
    });

    test("a stranger's rave counts for nothing (S = 0)", () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz, adId: 'self'));
      dir.add(_ad(cust1, adId: 'c1', sat: 4));
      expect(dir.vouch(dir['did:key:zCafe']!, none), 0.0);
    });

    test('a nearer business scores above a farther one, all else equal', () {
      final dir = BusinessDirectory.unverified();
      // '9q8yyk8y' is San Francisco; '9q5ctr18' is Los Angeles.
      dir.add(_ad(biz,
          polity: 'did:key:zNear',
          adId: 'n',
          bundle: _bundle(polity: 'did:key:zNear', name: 'Near', locality: here)));
      dir.add(_ad(biz,
          polity: 'did:key:zFar',
          adId: 'f',
          bundle: _bundle(
              polity: 'did:key:zFar', name: 'Far', locality: '9q5ctr18')));
      final ranked = dir.ranked(
          strengthOfAdvertiser: strong, ownGeohash: here, nowEpochSeconds: 1000);
      expect(ranked.first.polity, 'did:key:zNear');
    });

    test('with no own position, distance contributes nothing to anyone', () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz, adId: 'n'));
      final b = dir['did:key:zCafe']!;
      expect(dir.distanceFactor(b, null), 0.0);
      expect(dir.distanceFactor(b, ''), 0.0);
    });

    test('an unplaced page cannot rank by distance', () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz, adId: 'n', bundle: _bundle(locality: '')));
      expect(dir.distanceFactor(dir['did:key:zCafe']!, here), 0.0);
    });

    test('at equal distance, the endorsed business outranks the unendorsed one',
        () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz,
          polity: 'did:key:zA',
          adId: 'a',
          bundle: _bundle(polity: 'did:key:zA', name: 'A', locality: here)));
      dir.add(_ad(biz,
          polity: 'did:key:zB',
          adId: 'b',
          bundle: _bundle(polity: 'did:key:zB', name: 'B', locality: here)));
      dir.add(_ad(cust1,
          polity: 'did:key:zB',
          adId: 'bc',
          sat: 4,
          bundle: _bundle(polity: 'did:key:zB', name: 'B', locality: here)));
      final ranked = dir.ranked(
          strengthOfAdvertiser: strong, ownGeohash: here, nowEpochSeconds: 1000);
      expect(ranked.first.polity, 'did:key:zB');
    });

    test('recency decays a business nobody has mentioned lately', () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz, adId: 'n', ts: 1000));
      final b = dir['did:key:zCafe']!;
      final fresh = dir.recency(b, 1000);
      final stale = dir.recency(b, 1000 + 30 * 86400);
      expect(fresh, 1.0);
      expect(stale, lessThan(0.1));
    });

    test('the score stays in [0,1] and the order is deterministic', () {
      final dir = BusinessDirectory.unverified();
      dir.add(_ad(biz, adId: 'n'));
      dir.add(_ad(cust1, adId: 'c1', sat: 4));
      final b = dir['did:key:zCafe']!;
      final s = dir.score(b,
          strengthOfAdvertiser: strong, ownGeohash: here, nowEpochSeconds: 1000);
      expect(s, inInclusiveRange(0.0, 1.0));
      final r1 = dir.ranked(
          strengthOfAdvertiser: strong, ownGeohash: here, nowEpochSeconds: 1000);
      final r2 = dir.ranked(
          strengthOfAdvertiser: strong, ownGeohash: here, nowEpochSeconds: 1000);
      expect(r1.map((b) => b.polity).toList(), r2.map((b) => b.polity).toList());
    });
  });

  group('PeerService wiring (ingestEvents)', () {
    test('a business ad lands in the directory and rosters the advertiser', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([_adEvent(biz, adId: 'a1')]);
      expect(svc.businessCount, 1);
      expect(svc.businesses.single.displayName, 'Corner Cafe');
      // The advertiser is rostered so the vouch term can weight them.
      expect(svc.peers.length, 1);
    });

    test('an unverifiable ad is dropped and counted', () {
      final svc = PeerService(bundleVerifier: (_) => false);
      svc.ingestEvents([_adEvent(biz, adId: 'a1')]);
      expect(svc.businessCount, 0);
      expect(svc.businessesUnverified, 1);
    });

    test('markCustomer records our own satisfaction; clearCustomer drops it',
        () {
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([_adEvent(biz, adId: 'a1')]);
      expect(svc.customerSatisfaction('did:key:zCafe'), isNull);
      // No channel is open in a unit test, so the rc is -1; the local mirror is
      // still what the UI reads back.
      expect(svc.markCustomer('did:key:zCafe', 4), -1);
      expect(svc.customerSatisfaction('did:key:zCafe'), 4);
      expect(svc.clearCustomer('did:key:zCafe'), -1);
      expect(svc.customerSatisfaction('did:key:zCafe'), isNull);
    });

    test('markCustomer clamps satisfaction into 0..4', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([_adEvent(biz, adId: 'a1')]);
      svc.markCustomer('did:key:zCafe', 9);
      expect(svc.customerSatisfaction('did:key:zCafe'), 4);
    });

    test('advertiseBusiness refuses an empty polity or bundle', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      expect(svc.advertiseBusiness('', _bundle()), -1);
      expect(svc.advertiseBusiness('did:key:zCafe', ''), -1);
    });

    test('a duplicate ad id from the wire is deduped app-side too', () {
      final svc = PeerService(bundleVerifier: (_) => true);
      svc.ingestEvents([
        _adEvent(biz, adId: 'dup'),
        _adEvent(biz, adId: 'dup'),
      ]);
      expect(svc.businessCount, 1);
    });
  });
}
