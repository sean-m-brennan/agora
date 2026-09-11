// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Tests for PeerService's roster merge and the opt-in own-position / own-profile
// state, driven directly (ingestEvents) without starting the daemon or loading
// the native shim.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/node/peer_stream.dart';

AtRawEvent _peerEvent(List<int> uuid, {int rank = 0, double attested = 0}) =>
    AtRawEvent(
      kind: agoraEventPeer,
      uuid: uuid,
      signingPubkey: const [],
      rank: rank,
      operatorBound: attested > 0,
      operatorAttestedAt: attested,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
    );

AtRawEvent _profileEvent(List<int> uuid, String json) => AtRawEvent(
      kind: agoraEventProfile,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      profileJson: json,
    );

void main() {
  final u1 = List<int>.filled(16, 0x11);
  final u2 = List<int>.filled(16, 0x22);

  group('own profile (opt-in)', () {
    test('setOwnProfile before channel open remembers it', () {
      final svc = PeerService();
      var notified = 0;
      svc.addListener(() => notified++);

      // No event channel open yet: returns -1 and remembers for push on start.
      final rc = svc.setOwnProfile({'display_name': 'Ada', 'handle': 'ada'});
      expect(rc, -1);
      expect(svc.ownProfile, {'display_name': 'Ada', 'handle': 'ada'});
      expect(notified, 1);
    });

    test('ownProfile getter returns an unmodifiable copy', () {
      final svc = PeerService();
      svc.setOwnProfile({'display_name': 'Ada'});
      final got = svc.ownProfile!;
      expect(() => got['x'] = 'y', throwsUnsupportedError);
    });

    test('empty or null profile opts out', () {
      final svc = PeerService();
      svc.setOwnProfile({'display_name': 'Ada'});
      expect(svc.ownProfile, isNotNull);
      svc.setOwnProfile(<String, dynamic>{});
      expect(svc.ownProfile, isNull);
      svc.setOwnProfile({'display_name': 'Ada'});
      svc.setOwnProfile(null);
      expect(svc.ownProfile, isNull);
    });

    test('setOwnPosition before channel open remembers it', () {
      final svc = PeerService();
      final rc = svc.setOwnPosition('u4pruy');
      expect(rc, -1);
      expect(svc.ownGeohash, 'u4pruy');
      svc.setOwnPosition(null);
      expect(svc.ownGeohash, isNull);
    });
  });

  group('roster merge (ingestEvents)', () {
    test('a peer event creates a peer; a profile event merges into it', () {
      final svc = PeerService();
      var notified = 0;
      svc.addListener(() => notified++);

      svc.ingestEvents([
        _peerEvent(u1, rank: 3),
        _profileEvent(u1, '{"display_name":"Ada","handle":"ada","bio":"math"}'),
      ]);

      expect(svc.peers, hasLength(1));
      final p = svc.peers.single;
      expect(p.rank, 3);
      expect(p.displayName, 'Ada');
      expect(p.handle, 'ada');
      expect(p.bio, 'math');
      expect(p.hasProfile, isTrue);
      expect(notified, 1); // one batch => one notification
    });

    test('empty batch does not notify', () {
      final svc = PeerService();
      var notified = 0;
      svc.addListener(() => notified++);
      svc.ingestEvents(const []);
      expect(notified, 0);
    });

    test('peers are sorted by rank, strongest first', () {
      final svc = PeerService();
      svc.ingestEvents([
        _peerEvent(u1, rank: 1),
        _peerEvent(u2, rank: 5),
      ]);
      expect(svc.peers.map((p) => p.rank).toList(), [5, 1]);
    });
  });
}
