// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Pure-Dart tests for the app-side geo layer (Increment 2, the "with-distance"
// feature): geohash decode, haversine distance, and the peer position event.
// These never load the native shim, so they run under `flutter test` with no
// built libagora_shim. The AT core treats the geohash as opaque; ALL distance
// reasoning lives here, so this is where it is pinned.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/geo/geohash.dart';
import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/at_peer.dart';

void main() {
  group('decodeGeohash', () {
    test('decodes the canonical geohash to its cell center', () {
      // geohash.org's textbook example: "u4pruydqqvj" -> (57.64911, 10.40744).
      final b = decodeGeohash('u4pruydqqvj');
      expect(b, isNotNull);
      expect(b!.lat, closeTo(57.64911, 0.0005));
      expect(b.lon, closeTo(10.40744, 0.0005));
    });

    test('is case-insensitive', () {
      final lower = decodeGeohash('u4pruy')!;
      final upper = decodeGeohash('U4PRUY')!;
      expect(upper.lat, closeTo(lower.lat, 1e-9));
      expect(upper.lon, closeTo(lower.lon, 1e-9));
    });

    test('a shorter geohash is a coarser (larger) cell', () {
      final coarse = decodeGeohash('u4')!;
      final fine = decodeGeohash('u4pruy')!;
      expect(coarse.latErr, greaterThan(fine.latErr));
      expect(coarse.lonErr, greaterThan(fine.lonErr));
    });

    test('empty geohash decodes to null (opted out, not a point)', () {
      expect(decodeGeohash(''), isNull);
    });

    test('an invalid character yields null (a/i/l/o are not in the alphabet)',
        () {
      expect(decodeGeohash('abc'), isNull); // 'a' invalid
      expect(decodeGeohash('u4?ruy'), isNull);
    });
  });

  group('haversineKm', () {
    test('one degree of longitude at the equator is ~111.2 km', () {
      expect(haversineKm(0, 0, 0, 1), closeTo(111.195, 0.05));
    });

    test('a point to itself is zero', () {
      expect(haversineKm(57.6, 10.4, 57.6, 10.4), closeTo(0, 1e-9));
    });
  });

  group('geohashDistanceKm', () {
    test('identical buckets are zero distance', () {
      expect(geohashDistanceKm('u4pruy', 'u4pruy'), closeTo(0, 1e-9));
    });

    test('far-apart buckets are a large distance (Denmark vs Spain)', () {
      // u4pruy ~ (57.6, 10.4); ezs42 ~ (42.6, -5.6): well over 1500 km.
      final d = geohashDistanceKm('u4pruy', 'ezs42');
      expect(d, isNotNull);
      expect(d!, greaterThan(1500));
    });

    test('one-sided (either empty) yields null — the privacy behavior', () {
      expect(geohashDistanceKm('', 'u4pruy'), isNull);
      expect(geohashDistanceKm('u4pruy', ''), isNull);
      expect(geohashDistanceKm('', ''), isNull);
    });
  });

  group('AgoraPeer position event', () {
    test('a position event records the opaque geohash', () {
      final peer = AgoraPeer(uuid: List<int>.filled(16, 0));
      expect(peer.geohash, ''); // opted out until an event arrives
      final consumed = peer.applyEvent(AtRawEvent(
        kind: agoraEventPosition,
        uuid: List<int>.filled(16, 0),
        signingPubkey: const [],
        rank: 0,
        operatorBound: false,
        operatorAttestedAt: 0,
        operatorPubkey: const [],
        repScore: 0,
        repRated: false,
        rttMs: 0,
        geohash: 'u4pruy',
      ));
      expect(consumed, isTrue);
      expect(peer.geohash, 'u4pruy');
    });

    test('distanceKmFrom needs BOTH sides opted in', () {
      final peer = AgoraPeer(uuid: List<int>.filled(16, 0));
      // Peer has no position yet -> null regardless of our own.
      expect(peer.distanceKmFrom('u4pruy'), isNull);
      peer.geohash = 'u4pruy';
      // Now peer has one, but WE are opted out -> still null.
      expect(peer.distanceKmFrom(''), isNull);
      expect(peer.distanceKmFrom(null), isNull);
      // Both opted in -> a real distance (same bucket => ~0).
      expect(peer.distanceKmFrom('u4pruy'), closeTo(0, 1e-9));
    });

    test('distanceLabel formats coarse distance, or "—" when unknown', () {
      final peer = AgoraPeer(uuid: List<int>.filled(16, 0));
      expect(peer.distanceLabel('u4pruy'), '—'); // peer opted out
      peer.geohash = 'u4pruy';
      expect(peer.distanceLabel('u4pruy'), '~0 m'); // same bucket, <1km
      final farLabel = peer.distanceLabel('ezs42'); // Denmark vs Spain
      expect(farLabel.startsWith('~'), isTrue);
      expect(farLabel.endsWith(' km'), isTrue);
    });
  });
}
