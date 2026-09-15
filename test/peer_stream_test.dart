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

    test('equal tie strength falls back to rank, strongest first', () {
      final svc = PeerService();
      // Two bare peers (no reputation, position, or attendance) both score S=0,
      // so the deterministic tiebreak is topology rank descending.
      svc.ingestEvents([
        _peerEvent(u1, rank: 1),
        _peerEvent(u2, rank: 5),
      ]);
      expect(svc.peers.map((p) => p.rank).toList(), [5, 1]);
    });

    test('tie strength outranks topology rank', () {
      final svc = PeerService();
      // u1 has high topology rank but no trust; u2 has low rank but a tier-4
      // reputation. Tie strength (trust-weighted) must place u2 first.
      svc.ingestEvents([
        _peerEvent(u1, rank: 9),
        _peerEvent(u2, rank: 1),
        _repEvent(u2, 0.95),
      ]);
      expect(svc.strengthOf(svc.peers.first), greaterThan(0));
      expect(svc.peers.first.uuid, u2);
      expect(svc.peers.last.uuid, u1);
    });
  });

  group('own identity + group co-membership', () {
    String hex(List<int> b) =>
        b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

    test('own identity is never surfaced as a peer', () {
      final svc = PeerService();
      svc.setOwnIdentityForTest(hex(u1), 'agora-node-1');
      // u1 is us; u2 is a real peer. The self event must be dropped.
      svc.ingestEvents([_peerEvent(u1), _peerEvent(u2)]);
      expect(svc.peers.length, 1);
      expect(svc.peers.single.uuid, u2);
    });

    test('own short id and display name (nickname fallback then profile)', () {
      final svc = PeerService();
      svc.setOwnIdentityForTest(hex(u2), 'agora-node-2');
      expect(svc.ownShortId, hex(u2).substring(0, 12));
      // No profile yet -> nickname.
      expect(svc.ownDisplayName, 'agora-node-2');
      // With a shared profile -> its display name wins.
      svc.setOwnProfile({'display_name': 'Bob'});
      expect(svc.ownDisplayName, 'Bob');
    });

    test('inGroup flag on a peer event surfaces on the peer', () {
      final svc = PeerService();
      svc.ingestEvents([
        _peerEvent(u1),
        AtRawEvent(
          kind: agoraEventPeer,
          uuid: u2,
          signingPubkey: const [],
          rank: 0,
          operatorBound: false,
          operatorAttestedAt: 0,
          operatorPubkey: const [],
          repScore: 0,
          repRated: false,
          rttMs: 0,
          inGroup: true,
        ),
      ]);
      expect(svc.peers.firstWhere((p) => p.uuid == u1).inGroup, isFalse);
      expect(svc.peers.firstWhere((p) => p.uuid == u2).inGroup, isTrue);
    });
  });
}
