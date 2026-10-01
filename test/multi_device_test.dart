// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// One person, several devices (SOCIAL_APP_PLAN Phase 4): devices the address
// book files under one record are one person to the rest of the app. One tile,
// one Dunbar tie, one block, one DM thread. Reputation stays per device, so
// only the app's grouping is tested here; the core's per-node state is not
// touched. Our own other devices (siblings) are us, not peers.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/model/address_book.dart';
import 'package:agora/src/model/post.dart';
import 'package:agora/src/node/moderation_verbs.dart';
import 'package:agora/src/node/peer_stream.dart';

List<int> _u(int n) => [for (var i = 0; i < 15; i++) 0, n];
String _h(int n) => hexOf(_u(n));

AtRawEvent _raw(int kind,
        {int who = 0,
        int fcKind = 0,
        int device = 0,
        String ref = '',
        String petname = '',
        bool verified = true,
        int state = 0,
        bool blocked = false,
        int dmSeq = 0,
        String dmText = ''}) =>
    AtRawEvent(
      kind: kind,
      uuid: _u(who),
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      connectionState: state,
      blocked: blocked,
      dmSeq: dmSeq,
      dmTs: 1.0,
      dmText: dmText,
      fcKind: fcKind,
      fcRef: ref,
      fcPetname: petname,
      fcVerified: verified,
      fcDeviceUuid: device == 0 ? const [] : _u(device),
    );

AtRawEvent _peer(int who, {bool blocked = false}) =>
    _raw(agoraEventPeer, who: who, blocked: blocked);
AtRawEvent _state(int who, int state) =>
    _raw(agoraEventConnectionState, who: who, state: state);

/// A well-reputed device (tier 4), so a connected, tended tie is strong.
AtRawEvent _trusted(int who) => AtRawEvent(
      kind: agoraEventReputation,
      uuid: _u(who),
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0.95,
      repRated: true,
      rttMs: 0,
      repTier: 4,
    );

/// Ann is one record (device 1) with a second device (2), both peers.
List<AtRawEvent> _annWithTwoDevices() => [
      _raw(agoraEventContact,
          who: 1, fcKind: atFcContact, ref: refBookList, petname: 'Ann'),
      _raw(agoraEventContact,
          who: 1, fcKind: atFcDeviceLinked, device: 2, ref: refBookList),
      _raw(agoraEventContact, fcKind: atFcContactsDone, ref: refBookList),
      _peer(1),
      _peer(2),
    ];

class _Verbs implements ModerationVerbs {
  final List<String> calls = [];
  @override
  int block(List<int> peerUuid) {
    calls.add('block ${hexOf(peerUuid)}');
    return 0;
  }

  @override
  int unblock(List<int> peerUuid) {
    calls.add('unblock ${hexOf(peerUuid)}');
    return 0;
  }

  @override
  int report(List<int> peerUuid) => 0;

  @override
  int peerStanding(List<int> peerUuid,
          {required String standing,
          required double ceiling,
          required String reason}) =>
      0;

  @override
  int requestCosign(List<List<int>> peerUuids,
          {required String record,
          required String op,
          required String polityDid,
          required String cid,
          required String bytes}) =>
      0;
}

void main() {
  test('two devices of one person are one tile, with both behind it', () {
    final s = PeerService();
    s.ingestEvents([..._annWithTwoDevices(), _peer(3)]);
    expect(s.peers.length, 2, reason: 'Ann (two devices) and a stranger');
    final ann = s.peers.firstWhere((p) => s.personKey(hexOf(p.uuid)) == _h(1));
    expect(s.devicesOfPeer(ann).map((p) => hexOf(p.uuid)).toSet(), {_h(1), _h(2)});
    expect(s.deviceCountOf(ann), 2);
    expect(s.contactOf(ann)!.label, 'Ann');
  });

  test('without the address book they are two people', () {
    final s = PeerService();
    s.ingestEvents([_peer(1), _peer(2)]);
    expect(s.peers.length, 2);
  });

  test('a person with two connected devices is ONE strong tie', () {
    final split = PeerService();
    split.ingestEvents(
        [_peer(1), _peer(2), _trusted(1), _trusted(2), _state(1, 3), _state(2, 3)]);
    for (final p in split.peers) {
      split.sendDm(p, 'hi'); // tends each tie: recency now
    }
    final merged = PeerService();
    merged.ingestEvents([
      ..._annWithTwoDevices(),
      _trusted(1),
      _trusted(2),
      _state(1, 3),
      _state(2, 3)
    ]);
    merged.sendDm(merged.peers.single, 'hi');

    final two = split.budgetLedger.strongTieCount;
    expect(two, 2, reason: 'the control: two separate people, both strong');
    expect(merged.budgetLedger.strongTieCount, 1);
  });

  test('connected on any device is connected', () {
    final s = PeerService();
    s.ingestEvents([..._annWithTwoDevices(), _state(2, 3)]);
    expect(s.peers.single.isConnected, isTrue);
  });

  test('a block covers every device, and unblocking lifts all of them', () {
    final v = _Verbs();
    final s = PeerService(moderationVerbs: v);
    s.ingestEvents(_annWithTwoDevices());
    s.blockPeer(s.peers.single);
    expect(v.calls, ['block ${_h(1)}', 'block ${_h(2)}']);
    v.calls.clear();
    s.unblockPeer(s.peers.single);
    expect(v.calls, ['unblock ${_h(1)}', 'unblock ${_h(2)}']);
  });

  test('a blocked person shows blocked, and hides every device', () {
    final s = PeerService();
    s.ingestEvents([..._annWithTwoDevices(), _peer(1, blocked: true)]);
    expect(s.peers.single.blocked, isTrue, reason: 'the representative is the blocked one');
    expect(s.isBlockedUuid(_u(2)), isTrue, reason: "the other device's posts are hidden too");
    expect(s.blockedPeers.length, 1);
    s.ingestEvents([_raw(agoraEventDm, who: 2, dmSeq: 1, dmText: 'psst')]);
    expect(s.dmsDroppedFromBlocked, 1);
  });

  test('a device linked to a blocked person is blocked at once', () {
    final v = _Verbs();
    final s = PeerService(moderationVerbs: v);
    s.ingestEvents([
      _raw(agoraEventContact, who: 1, fcKind: atFcContact, ref: refBookList),
      _raw(agoraEventContact, fcKind: atFcContactsDone, ref: refBookList),
      _peer(1, blocked: true),
      _raw(agoraEventContact, who: 1, fcKind: atFcDeviceLinked, device: 5),
    ]);
    expect(v.calls, ['block ${_h(5)}']);
  });

  test('one DM thread per person, whichever device wrote', () {
    final s = PeerService();
    s.ingestEvents([
      ..._annWithTwoDevices(),
      _raw(agoraEventDm, who: 1, dmSeq: 1, dmText: 'from the phone'),
      _raw(agoraEventDm, who: 2, dmSeq: 1, dmText: 'from the laptop'),
      _raw(agoraEventDm, who: 2, dmSeq: 1, dmText: 'from the laptop'),
    ]);
    final ann = s.peers.single;
    expect(s.messagesFor(ann).map((m) => m.text), ['from the phone', 'from the laptop'],
        reason: 'same seq from two devices is two messages; a re-delivery is one');
    expect(s.unreadPeerCount, 1);
    for (final d in s.devicesOfPeer(ann)) {
      expect(s.hasUnread(d), isTrue);
    }
    s.markThreadRead(s.devicesOfPeer(ann).last);
    expect(s.unreadPeerCount, 0);
  });

  test('our own other devices are us, not peers', () {
    final s = PeerService();
    s.ingestEvents([
      _raw(agoraEventContact, who: 7, fcKind: atFcSibling, ref: refSiblingList),
      _raw(agoraEventContact, fcKind: atFcSiblingsDone, ref: refSiblingList),
      _peer(7),
      _peer(3),
    ]);
    expect(s.peers.map((p) => hexOf(p.uuid)), [_h(3)]);
    final post = Post(
        authorUuid: _u(7), seq: 1, ts: 1, requiredTier: 0, body: 'x', postId: 'p', outgoing: false);
    expect(s.authorLabel(post), 'you · other device');
  });

  test("a post's author is named by the address book", () {
    final s = PeerService();
    s.ingestEvents(_annWithTwoDevices());
    final post = Post(
        authorUuid: _u(2), seq: 1, ts: 1, requiredTier: 0, body: 'x', postId: 'p', outgoing: false);
    expect(s.authorLabel(post), 'Ann');
  });

  test('hub cards from two devices of one person show once; ours not at all', () {
    final s = PeerService();
    s.ingestEvents([
      ..._annWithTwoDevices(),
      _raw(agoraEventContact, who: 7, fcKind: atFcSiblingPaired),
      for (final who in [1, 2, 7])
        AtRawEvent(
          kind: agoraEventArea,
          uuid: _u(who),
          signingPubkey: const [],
          rank: 0,
          operatorBound: false,
          operatorAttestedAt: 0,
          operatorPubkey: const [],
          repScore: 0,
          repRated: false,
          rttMs: 0,
          fcKind: atAreaCard,
          area: 'u4pr',
          areaBucket: 'u4pru',
        ),
    ]);
    expect(s.hubs.allCards().length, 3, reason: 'without grouping');
    expect(s.hubs.allCards(personOf: s.personKey).length, 1);
  });
}
