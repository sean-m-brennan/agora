// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Proximity hubs (SOCIAL_APP_PLAN Phase 4, §4.1 band 2): people nearby, found
// at a followed community's area hubs. The model and the service's wiring run
// on decoded events alone; the last group runs the real ethne_agora cdylib to
// show a community's roster riding inside the policy its followers verify.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/ethne_bindings.dart';
import 'package:agora/src/model/community_policy.dart';
import 'package:agora/src/model/hub_directory.dart';
import 'package:agora/src/node/peer_stream.dart';

const _garden = 'did:key:zGarden';
const _hint = 'relay://0f1e2d3c-4b5a-4968-8776-655443322110:'
    'abababababababababababababababab@hub.example.org:27790';
const _alice = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];

AtRawEvent _ev(int kind,
        {int fcKind = 0,
        List<int> uuid = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        String area = 'u4pr',
        String bucket = '',
        String name = '',
        String ref = '',
        String handle = '',
        String nickname = '',
        String reason = '',
        String issuer = '',
        String policyBundle = ''}) =>
    AtRawEvent(
      kind: kind,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      fcKind: fcKind,
      area: area,
      areaBucket: bucket,
      areaName: name,
      fcRef: ref,
      fcHandle: handle,
      fcNickname: nickname,
      fcReason: reason,
      areaIssuer: issuer,
      fcRelay: 'hub.example.org:27790',
      policyCommunity: policyBundle.isEmpty ? '' : _garden,
      policySeq: policyBundle.isEmpty ? 0 : 3,
      policyBundle: policyBundle,
    );

/// A decoded policy the way the fake below "verifies" it: the bundle IS the
/// verified map, so the app's wiring is exercised over the fields it reads.
String _policyWithHubs(Map<String, List<String>> hubAreas) => jsonEncode({
      'community_did': _garden,
      'seq': 3,
      'policy': {
        'operator_bound_required': false,
        'min_tier': 0,
        'daily_post_cap': null,
        'labels': {},
      },
      'moderators': [],
      'hubs': hubAreas.isEmpty ? null : '{"body":"{}","sig":""}',
      'hub_areas': hubAreas,
    });

class _Decode implements CommunityCrypto {
  @override
  Map<String, dynamic>? verifyPolicy(String bundle) =>
      jsonDecode(bundle) as Map<String, dynamic>;

  @override
  Map<String, dynamic> verdict({
    required String policyBundle,
    required String postId,
    required List<String> authorLabels,
    required List<String> labels,
    required int authorTier,
    required bool authorOperatorBound,
    required int authorPostIndexToday,
  }) =>
      {'action': 'show', 'reasons': [], 'labels_refused': 0};

  @override
  String signLabel({
    required String communityDid,
    required String postId,
    required List<String> labels,
    required int seq,
    required Map<String, dynamic> moderatorPriv,
    required String moderatorDid,
  }) =>
      '';
}

void main() {
  group('HubDirectory', () {
    test('a listing, the cards a lookup found, and a withdrawal', () {
      final d = HubDirectory();
      final now = DateTime(2026, 9, 30, 12);
      expect(d.ingest(_ev(agoraEventArea, fcKind: atAreaPublished), now: now), isTrue);
      expect(d.listed, {'u4pr'});
      d.ingest(
          _ev(agoraEventArea,
              fcKind: atAreaCard, uuid: _alice, bucket: 'u4pru', name: 'Alice B.'),
          now: now);
      final [card] = d.cardsIn('u4pr', now: now);
      expect((card.name, card.bucket, card.uuid), ('Alice B.', 'u4pru', _alice));
      expect(card.distanceKmFrom('u4pru'), lessThan(0.01));
      expect(d.cardsIn('u4pr', now: now.add(const Duration(hours: 1))), isEmpty,
          reason: 'a card no lookup confirmed lately is not shown');
      d.ingest(_ev(agoraEventArea, fcKind: atAreaWithdrawn), now: now);
      expect(d.listed, isEmpty);
      expect(d.cardsIn('u4pr', now: now), isEmpty);
    });

    test('a refusal is kept per area until the area is listed again', () {
      final d = HubDirectory();
      d.ingest(_ev(agoraEventArea, fcKind: atAreaRefused, reason: 'area'));
      expect(d.refusals, {'u4pr': 'area'});
      d.ingest(_ev(agoraEventArea, fcKind: atAreaPublished));
      expect(d.refusals, isEmpty);
    });

    test('a request to answer, and a handshake done', () {
      final d = HubDirectory();
      d.ingest(_ev(agoraEventContact,
          fcKind: atDirContactRequest,
          uuid: _alice,
          ref: 'n1',
          handle: 'area:u4pr',
          nickname: 'alice'));
      expect(d.incoming['n1']?.foundBy, 'area:u4pr');
      d.ingest(_ev(agoraEventContact, fcKind: atFcEstablished, uuid: _alice));
      expect(d.incoming, isEmpty, reason: 'answered by the handshake');
      expect(d.outgoing.values.single, ContactStage.established);
    });

    test('only an area that holds our bucket is listable, and only 5 chars leave',
        () {
      expect(areasHolding('u4pruydq', ['u4pr', 'gcpv', 'u4']), ['u4', 'u4pr']);
      expect(areasHolding(null, ['u4pr']), isEmpty);
      expect(hubBucket('u4pruydq'), 'u4pru');
      expect(hubBucket('u4p'), 'u4p');
    });
  });

  group('PeerService and hubs', () {
    test('a followed community with hubs makes our own area listable', () {
      final s = PeerService(communityCrypto: _Decode());
      s.ingestEvents([
        _ev(agoraEventCommunityPolicy,
            policyBundle: _policyWithHubs({_hint: ['u4pr', 'gcpv']})),
      ]);
      expect(s.hubAreas, isEmpty, reason: 'heard, not followed');
      expect(s.followCommunity(_garden), isTrue);
      expect(s.hubAreas, ['gcpv', 'u4pr']);
      expect(s.listableAreas, isEmpty, reason: 'no bucket shared yet');
      s.setOwnPosition('u4pruydq');
      expect(s.listableAreas, ['u4pr']);
      final held = s.communities.followed[_garden]!;
      expect(held.hubRoster, isNotNull);
      expect(held.areas, ['gcpv', 'u4pr']);
    });

    test('area and contact events reach the directory', () {
      final s = PeerService(communityCrypto: _Decode());
      var told = 0;
      s.addListener(() => told++);
      s.ingestEvents([
        _ev(agoraEventArea, fcKind: atAreaPublished),
        _ev(agoraEventArea, fcKind: atAreaCard, uuid: _alice, bucket: 'u4pru'),
        _ev(agoraEventContact,
            fcKind: atDirContactRequest, uuid: _alice, ref: 'n1', handle: 'area:u4pr'),
      ]);
      expect(s.listedAtHubs, isTrue);
      expect(s.hubs.allCards().single.uuid, _alice);
      expect(s.hubs.incoming.keys, ['n1']);
      expect(told, greaterThan(0));
      // No hub events are mistaken for peers.
      expect(s.peers, isEmpty);
    });

    test('a community with no hubs lists nothing', () {
      final s = PeerService(communityCrypto: _Decode());
      s.ingestEvents([_ev(agoraEventCommunityPolicy, policyBundle: _policyWithHubs({}))]);
      s.followCommunity(_garden);
      s.setOwnPosition('u4pruydq');
      expect(s.communities.followed[_garden]!.hubRoster, isNull);
      expect(s.listableAreas, isEmpty);
    });
  });

  final libPath = EthneFfi.resolveLibraryPath();
  group('through the real cdylib', () {
    if (libPath == null) {
      test('skipped — ethne_agora not built', () {},
          skip: 'set AGORA_ETHNE_PATH '
              '(build native/build/libethne_agora.{so,dylib} via ./build.sh)');
      return;
    }

    test('a hub the roll seated rides inside the policy its followers verify', () {
      final ffi = EthneFfi.open(libPath);
      final polity = ffi.generateKeypair();
      final f = List.generate(5, (_) => ffi.generateKeypair());
      final arc = ffi.newArchive();
      addTearDown(arc.dispose);
      arc.foundPolity(
        polityDid: polity.did,
        name: 'Riverside Commons',
        statement: 'Neighbours who garden.',
        memberDids: f.map((m) => m.did).toList(),
        ratifiers: f,
      );
      arc.conferOffice(
          polityDid: polity.did,
          office: 'RendezvousOperator',
          holder: f[3],
          deciders: f.sublist(0, 3));
      arc.declareRelayEndpoint(
          polityDid: polity.did,
          member: f[3],
          atUuid: '0f1e2d3c-4b5a-4968-8776-655443322110',
          host: 'hub.example.org',
          port: 27790,
          areas: ['u4pr']);
      expect(arc.verify(), isTrue, reason: arc.lastError());

      final bundle = arc.signContentPolicy(polityDid: polity.did, root: polity, hubs: true);
      final read = ffi.verifyContentPolicy(bundle)!;
      final p = CommunityPolicy.fromVerified(read, bundle);
      expect(p.areas, ['u4pr']);
      final roster = jsonDecode(p.hubRoster!) as Map<String, dynamic>;
      final body = jsonDecode(roster['body'] as String) as Map<String, dynamic>;
      expect(body['typename'], 'at-relay-roster');
      expect(body['issuer'], isNotEmpty);
      expect((body['areas'] as Map).values.single, ['u4pr']);

      final plain = arc.signContentPolicy(polityDid: polity.did, root: polity);
      expect(CommunityPolicy.fromVerified(ffi.verifyContentPolicy(plain)!, plain).hubRoster,
          isNull);
    });
  });
}
