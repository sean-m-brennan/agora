// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Starting an expulsion from this app (Phase 4 P4.1), end to end without the
// cdylib: open the exchange, sign our own share, ask the other deciders,
// collect their signatures, assemble, re-verify, and ONLY THEN hand the core
// the reputation consequence.
//
// One ordered log is shared between the fake polity acts and the recording
// verbs, so the ORDER is what gets asserted — the standing must follow the act
// landing in the log, never the intent, and a log that does not verify after
// the append must cost the member nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/ethne_bindings.dart';
import 'package:agora/src/model/cosign_exchanges.dart';
import 'package:agora/src/model/staff_identity.dart';
import 'package:agora/src/model/staff_roster.dart';
import 'package:agora/src/node/moderation_verbs.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/node/polity_acts.dart';
import 'package:agora/src/ui/staff_roster.dart';

const _polity = 'did:key:zCafe';
const _ada = 'did:key:zAda'; // this node
const _bob = 'did:key:zBob';
const _cal = 'did:key:zCal';
const _dee = 'did:key:zDee'; // the member being expelled

class _Log {
  final List<String> entries = [];
}

class _Acts implements PolityActs {
  _Acts(this.log);
  final _Log log;
  bool verifies = true;
  bool removesMember = true;
  Object? pendingThrows;
  Object? assembleThrows;
  Map<String, dynamic>? assembledPayload;
  List<({String did, String sig})>? assembledSigs;
  final Map<String, dynamic> payload = {'decided_at': 1234, 'member': _dee};

  @override
  Map<String, dynamic> pendingExpel(
      {required String polityDid,
      required String memberDid,
      required String rationale,
      required List<String> deciderDids}) {
    if (pendingThrows != null) throw pendingThrows!;
    log.entries.add('pending:$memberDid');
    return {
      'record': 'membership',
      'op': 'expel',
      'polity_did': polityDid,
      'payload': payload,
      'bytes': 'cafe',
      'cid': 'b3:expel',
      'description': 'EXPEL $memberDid — majority PLUS ONE',
      'signers_required': deciderDids,
    };
  }

  @override
  String signOwn(String bytesHex) {
    log.entries.add('sign-own');
    return 'sig-ada';
  }

  @override
  void assemble(Map<String, dynamic> payload,
      List<({String did, String sig})> signatures) {
    if (assembleThrows != null) throw assembleThrows!;
    assembledPayload = payload;
    assembledSigs = signatures;
    log.entries.add('assemble:${signatures.map((s) => s.did).join(',')}');
  }

  @override
  bool verify() {
    log.entries.add('verify');
    return verifies;
  }

  @override
  List<String> rollDids(String polityDid) {
    log.entries.add('roll');
    return removesMember ? [_ada, _bob, _cal] : [_ada, _bob, _cal, _dee];
  }

  @override
  Map<String, dynamic> dump() {
    log.entries.add('dump');
    return const {};
  }
}

class _Verbs implements ModerationVerbs {
  _Verbs(this.log);
  final _Log log;
  int askRc = 0;

  int _r(String s) {
    log.entries.add(s);
    return 0;
  }

  @override
  int block(List<int> u) => _r('block');
  @override
  int unblock(List<int> u) => _r('unblock');
  @override
  int report(List<int> u) => _r('report');
  @override
  int peerStanding(List<int> u,
          {required String standing,
          required double ceiling,
          required String reason}) =>
      _r('standing:${u.first}:$standing:$ceiling');
  @override
  int requestCosign(List<List<int>> peerUuids,
      {required String record,
      required String op,
      required String polityDid,
      required String cid,
      required String bytes}) {
    log.entries.add('ask:${peerUuids.map((u) => u.first).join(',')}:$op');
    return askRc;
  }
}

StaffRoster _roster() => StaffRoster.from(
      affirmation: {
        'polity_did': _polity,
        'roll': 4,
        'seasoned': 4,
        'admit_need': 3,
        'expel_need': 3,
        'can_contract': true,
        'members': [
          for (final d in [_ada, _bob, _cal, _dee])
            {'did': d, 'inducted': true},
        ],
      },
      guardian: const {
        'derived': 0,
        'machine_majority': false,
        'unguarded': <String>[],
        'edges': <Map<String, dynamic>>[],
      },
      nowEpochSeconds: 1700000000,
      verified: true,
    );

AtRawEvent _peer(List<int> uuid) => AtRawEvent(
      kind: agoraEventPeer,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
    );

AtRawEvent _sig(String signer, {String cid = 'b3:expel'}) => AtRawEvent(
      kind: agoraEventCosignSignature,
      uuid: const [2],
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      cosignCid: cid,
      cosignSignerDid: signer,
      cosignSig: 'sig-$signer',
    );

void main() {
  final bobPeer = List<int>.filled(16, 0x0b);
  final calPeer = List<int>.filled(16, 0x0c);
  final deePeer = List<int>.filled(16, 0x0d);
  late _Log log;
  late _Acts acts;
  late _Verbs verbs;
  late PeerService svc;

  setUp(() {
    log = _Log();
    acts = _Acts(log);
    verbs = _Verbs(log);
    svc = PeerService(
      staffIdentity: StaffIdentity(
        polityDid: _polity,
        self: EthneKeypair(_ada, const {}, const {}),
        archive: const {},
      ),
      staffRoster: _roster(),
      polityActs: acts,
      moderationVerbs: verbs,
    );
    svc.ingestEvents([_peer(bobPeer), _peer(calPeer), _peer(deePeer)]);
  });

  AuthoredExchange begin({bool withTarget = true}) {
    final peers = svc.peers;
    final ax = svc.beginExpulsion(
      memberDid: _dee,
      rationale: 'persistent harm',
      deciderDids: [_ada, _bob, _cal],
      askPeers: peers.where((p) => p.uuid.first != 0x0d).toList(),
      targetPeer:
          withTarget ? peers.firstWhere((p) => p.uuid.first == 0x0d) : null,
    );
    expect(ax, isNotNull, reason: svc.lastExpulsionError);
    return ax!;
  }

  group('starting', () {
    test('opens, signs our share, and asks the others — nothing else', () {
      final ax = begin();
      expect(log.entries, ['pending:$_dee', 'sign-own', 'ask:11,12:expel']);
      expect(svc.countedSignatures(ax).map((s) => s.signerDid), [_ada]);
      expect(svc.expulsionReady(ax), isFalse);
      expect(svc.authoredExchanges, [ax]);
      expect(ax.status, AuthoredStatus.collecting);
    });

    test('refuses with nobody to ask when others must sign', () {
      final ax = svc.beginExpulsion(
          memberDid: _dee,
          rationale: 'x',
          deciderDids: [_ada, _bob, _cal],
          askPeers: const []);
      expect(ax, isNull);
      expect(svc.lastExpulsionError, contains('at least one peer'));
      expect(log.entries.where((e) => e.startsWith('ask')), isEmpty);
    });

    test('a refused exchange is reported in the library\'s words', () {
      acts.pendingThrows = EthneException('bar not reachable');
      expect(
          svc.beginExpulsion(
              memberDid: _dee,
              rationale: 'x',
              deciderDids: [_bob],
              askPeers: svc.peers),
          isNull);
      expect(svc.lastExpulsionError, contains('bar not reachable'));
    });

    test('an ask that could not be sent holds nothing', () {
      verbs.askRc = -2;
      expect(
          svc.beginExpulsion(
              memberDid: _dee,
              rationale: 'x',
              deciderDids: [_ada, _bob, _cal],
              askPeers: svc.peers),
          isNull);
      expect(svc.lastExpulsionError, contains('Not connected'));
      expect(svc.authoredExchanges, isEmpty);
    });

    test('no one else to ask when this node is the only decider', () {
      final ax = svc.beginExpulsion(
          memberDid: _dee,
          rationale: 'x',
          deciderDids: [_ada],
          askPeers: const []);
      expect(ax, isNotNull);
      expect(log.entries.where((e) => e.startsWith('ask')), isEmpty);
      expect(svc.expulsionReady(ax!), isTrue);
    });
  });

  group('collecting', () {
    test('only required signers count, once each', () {
      final ax = begin();
      svc.ingestEvents([
        _sig(_bob),
        _sig(_bob), // a replay
        _sig(_dee), // the target does not decide
        _sig('did:key:zStranger'),
        _sig(_cal, cid: 'b3:other'), // a different act
      ]);
      expect(svc.countedSignatures(ax).map((s) => s.signerDid).toSet(),
          {_ada, _bob});
      expect(ax.missingFrom(svc.cosignSignatures(ax.cid)), [_cal]);
      expect(svc.expulsionReady(ax), isFalse);
    });

    test('recording is refused until every decider has signed', () {
      final ax = begin();
      svc.ingestEvents([_sig(_bob)]);
      expect(svc.completeExpulsion(ax), isFalse);
      expect(log.entries.where((e) => e.startsWith('assemble')), isEmpty);
    });
  });

  group('recording', () {
    AuthoredExchange ready({bool withTarget = true}) {
      final ax = begin(withTarget: withTarget);
      svc.ingestEvents([_sig(_bob), _sig(_cal)]);
      log.entries.clear();
      return ax;
    }

    test('assemble, re-verify, persist — and only then the standing', () {
      final ax = ready();
      expect(svc.completeExpulsion(ax), isTrue);
      expect(log.entries, [
        'assemble:$_ada,$_bob,$_cal',
        'verify',
        'roll',
        'dump',
        'standing:13:capped:$ethneExpelCeiling',
      ]);
      expect(ax.status, AuthoredStatus.landed);
      expect(ax.standingRc, 0);
    });

    test('the payload goes back exactly as it was returned', () {
      final ax = ready();
      svc.completeExpulsion(ax);
      expect(identical(acts.assembledPayload, acts.payload), isTrue);
    });

    test('a signature that does not assemble costs the member nothing', () {
      final ax = ready();
      acts.assembleThrows = EthneException('signature does not verify');
      expect(svc.completeExpulsion(ax), isFalse);
      expect(ax.status, AuthoredStatus.failed);
      expect(ax.error, contains('does not verify'));
      expect(log.entries.where((e) => e.startsWith('standing')), isEmpty);
    });

    test('a log that does not verify after the append is not kept', () {
      final ax = ready();
      acts.verifies = false;
      expect(svc.completeExpulsion(ax), isFalse);
      expect(log.entries, isNot(contains('dump')));
      expect(log.entries.where((e) => e.startsWith('standing')), isEmpty);
      expect(ax.error, contains('did not verify'));
    });

    test('a member still on the roll means it did not land', () {
      final ax = ready();
      acts.removesMember = false;
      expect(svc.completeExpulsion(ax), isFalse);
      expect(log.entries.where((e) => e.startsWith('standing')), isEmpty);
      expect(ax.error, contains('still on the roll'));
    });

    test('with no peer picked it lands and changes no standing', () {
      final ax = ready(withTarget: false);
      expect(svc.completeExpulsion(ax), isTrue);
      expect(log.entries.where((e) => e.startsWith('standing')), isEmpty);
      expect(ax.standingRc, isNull);
    });

    test('a landed exchange cannot be recorded twice', () {
      final ax = ready();
      svc.completeExpulsion(ax);
      log.entries.clear();
      expect(svc.completeExpulsion(ax), isFalse);
      expect(log.entries, isEmpty);
    });
  });

  test('without polity acts this node cannot expel', () {
    final bare = PeerService(
        staffIdentity: StaffIdentity(
            polityDid: _polity,
            self: EthneKeypair(_ada, const {}, const {}),
            archive: const {}),
        staffRoster: _roster());
    expect(bare.canExpel, isFalse);
    expect(
        bare.beginExpulsion(
            memberDid: _dee, rationale: 'x', deciderDids: [_ada], askPeers: []),
        isNull);
  });

  group('the roster screen', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: StaffRosterPage(service: svc)));
    }

    testWidgets('offers Expel for others, never for yourself', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('expel-$_dee')), findsOneWidget);
      expect(find.byKey(const Key('expel-$_bob')), findsOneWidget);
      expect(find.byKey(const Key('expel-$_ada')), findsNothing);
    });

    testWidgets('no Expel on a node that cannot sign for the polity',
        (tester) async {
      svc = PeerService(
          staffIdentity: StaffIdentity(
              polityDid: _polity,
              self: EthneKeypair(_ada, const {}, const {}),
              archive: const {}),
          staffRoster: _roster());
      await pump(tester);
      expect(find.byKey(const Key('expel-$_dee')), findsNothing);
    });

    testWidgets('the dialog needs a reason and enough deciders, then asks',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('expel-$_dee')));
      await tester.pumpAndSettle();
      // The target is not offered as a decider; this node is pre-selected.
      expect(find.byKey(const Key('decider-$_dee')), findsNothing);
      FilledButton submit() =>
          tester.widget(find.byKey(const Key('expel-submit')));
      expect(submit().onPressed, isNull);

      await tester.enterText(
          find.byKey(const Key('expel-rationale')), 'persistent harm');
      await tester.tap(find.byKey(const Key('decider-$_bob')));
      await tester.pump();
      expect(submit().onPressed, isNull, reason: '2 of 3 deciders');
      await tester.tap(find.byKey(const Key('decider-$_cal')));
      await tester.pump();
      expect(submit().onPressed, isNotNull);

      // Submitting with nobody to ask shows the refusal in the dialog.
      await tester.tap(find.byKey(const Key('expel-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('expel-error')), findsOneWidget);

      await tester.tap(find.byKey(const Key('ask-0b0b0b0b0b0b')));
      await tester.tap(find.byKey(const Key('ask-0c0c0c0c0c0c')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('expel-submit')));
      await tester.pumpAndSettle();
      expect(log.entries.last, 'ask:11,12:expel');
      expect(find.text('1 of 3 signed'), findsOneWidget);
    });

    testWidgets('Record is offered only once every decider has signed',
        (tester) async {
      begin();
      await pump(tester);
      FilledButton record() =>
          tester.widget(find.byKey(const Key('authored-complete')));
      expect(record().onPressed, isNull);
      expect(find.textContaining('Waiting on'), findsOneWidget);

      svc.ingestEvents([_sig(_bob), _sig(_cal)]);
      await tester.pump();
      expect(record().onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('authored-complete')));
      await tester.pump();
      expect(find.textContaining('standing on this node is now capped'),
          findsOneWidget);
      expect(log.entries.last, startsWith('standing'));
    });

    testWidgets('a failed recording says why', (tester) async {
      final ax = begin();
      svc.ingestEvents([_sig(_bob), _sig(_cal)]);
      acts.verifies = false;
      svc.completeExpulsion(ax);
      await pump(tester);
      expect(find.textContaining('Not recorded: The log did not verify'),
          findsOneWidget);
    });
  });
}
