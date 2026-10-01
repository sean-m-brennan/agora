// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Federation through kith-covenant compacts (SOCIAL_APP_PLAN Phase 5; Ethne D39,
// D40), from the app's side: the views communities publish, what a reader makes
// of them (badges, reach, a policy acting on standing), and the engine a staff
// node carries the roll's acts out with. The cdylib's own suite (ethne_ffi kc.rs)
// runs three communities over the wire; here the seams are fakes, and the last
// group runs the real library when it is built.

import 'dart:convert';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/ethne_bindings.dart';
import 'package:agora/src/model/community_policy.dart';
import 'package:agora/src/model/compact_book.dart';
import 'package:agora/src/model/post.dart';
import 'package:agora/src/node/compact_engine.dart';
import 'package:agora/src/node/peer_stream.dart';

const _a = 'did:key:zAlpha';
const _b = 'did:key:zBeta';
const _c = 'did:key:zGamma';
const _nodeA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _nodeB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _nodeC = 'cccccccccccccccccccccccccccccccc';

/// A view "bundle" the fake verifier reads back as the verified map.
String _view(String did, int seq, Map<String, String> standings,
        {String node = _nodeA, List<Map<String, dynamic>> compacts = const []}) =>
    jsonEncode({
      'community_did': did,
      'node': node,
      'seq': seq,
      'as_of': 0,
      'compacts': compacts,
      'standings': standings,
    });

Map<String, dynamic>? _fakeVerify(String bundle) {
  try {
    final m = jsonDecode(bundle) as Map<String, dynamic>;
    return m['forged'] == true ? null : m;
  } on Object {
    return null;
  }
}

AtRawEvent _policyEvent(String community, String bundle, {int seq = 1}) => AtRawEvent(
      kind: agoraEventCommunityPolicy,
      uuid: const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      policyCommunity: community,
      policySeq: seq,
      policyBundle: bundle,
    );

/// The fake community crypto: a policy bundle IS its verified map.
class _Decode implements CommunityCrypto {
  @override
  Map<String, dynamic>? verifyPolicy(String bundle) => jsonDecode(bundle) as Map<String, dynamic>;

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

String _policy(String did, {Map<String, String> standing = const {}}) => jsonEncode({
      'community_did': did,
      'seq': 1,
      'policy': {
        'operator_bound_required': false,
        'min_tier': 0,
        'daily_post_cap': null,
        'labels': {},
        if (standing.isNotEmpty) 'standing': standing,
      },
      'moderators': [],
    });

Post _post(String community) => Post(
    authorUuid: const [9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9],
    postId: 'p-$community',
    seq: 1,
    ts: 1,
    requiredTier: 0,
    body: 'hello',
    outgoing: false,
    community: community);

// --- fakes for the engine ------------------------------------------------------

class _Border implements CompactBorder {
  final List<String> calls = [];
  final List<String> ingested = [];
  int sealLandsAt = 3;

  @override
  String get polityDid => _a;
  @override
  String get selfDid => 'did:key:zAlphaEnvoy';
  @override
  bool get governs => true;

  Map<String, dynamic> _out(String kind, [int n = 1]) => {
        'deliveries': [
          for (var i = 0; i < n; i++) {'kind': kind, 'cid': 'b3:$kind$i', 'hex': 'ab$i'}
        ]
      };

  @override
  Map<String, dynamic> border() => _out('identity', 2);
  @override
  Map<String, dynamic> riteDraft(String inductorDid) => {
        ..._out('reciter', 2),
        'recitation': {'r': 1},
        'recitation_bytes': 'aa',
        'attest': [
          {'witness_did': selfDid, 'payload': {'w': 1}, 'bytes': 'bb'},
          {'witness_did': 'did:key:zAlphaWitness0001', 'payload': {'w': 2}, 'bytes': 'cc'},
        ],
        'at': 7,
      };
  @override
  Map<String, dynamic> riteSeal(Map<String, dynamic> spec) {
    calls.add('riteSeal ${(spec['attestations'] as List).length}');
    return _out('rite');
  }

  @override
  Map<String, dynamic> claims(String compact, List<String> counterparties) => _out('claim', 5);
  @override
  Map<String, dynamic> verdicts(String compact, String presenter, bool accepted) => _out('verdict', 5);
  @override
  Map<String, dynamic> sponsor(String compact, String entrant) => _out('sponsorship');
  @override
  Map<String, dynamic> examiners(List<Map<String, dynamic>> seats) => _out('examiners');
  @override
  Map<String, dynamic> sealDraft(String compact, List<String> participants) =>
      {'manifest': 'mf', 'cid': 'b3:seal', 'kind': 'sealed', 'sitting': []};
  @override
  Map<String, dynamic> sealSign(String manifest) => {'cid': 'b3:seal', 'kind': 'sealed', 'sig': 'sig-$selfDid'};
  @override
  Map<String, dynamic> sealAssemble(String manifest, List<Map<String, dynamic>> sigs) {
    calls.add('sealAssemble ${sigs.length}');
    if (sigs.length < sealLandsAt) throw Exception('does not authorize yet');
    return {'cid': 'b3:sealed', 'sealed': 'note'};
  }

  @override
  Map<String, dynamic> sealIngest(String sealed) {
    calls.add('sealIngest $sealed');
    return {'cid': 'b3:sealed'};
  }

  @override
  Map<String, dynamic> conductDraft(String kind, String compact, List<String> reporters, String subject,
          {String? designation}) =>
      {'payload': {'subject': subject}, 'bytes': 'cd', 'cid': 'b3:conduct'};
  @override
  Map<String, dynamic> conductSign(String compact, {Map<String, dynamic>? payload, String? bytes}) {
    if (compact != 'river') throw Exception('no act in $compact');
    return {'did': selfDid, 'sig': 'csig'};
  }

  @override
  Map<String, dynamic> conductAssemble(Map<String, dynamic> payload, List<Map<String, dynamic>> sigs) {
    calls.add('conductAssemble ${sigs.length}');
    return _out('conduct');
  }

  @override
  Map<String, dynamic> ingest(String hex) {
    if (hex == 'bad') throw Exception('never lands');
    ingested.add(hex);
    return {'status': 'landed'};
  }

  @override
  List<Map<String, dynamic>> deliveries() => [
        for (final h in ingested) {'record': 'kc_record', 'op': 'deliver', 'cid': 'b3:in-$h', 'hex': h},
        {'record': 'kc_seal', 'op': 'sealed', 'cid': 'b3:sealed', 'hex': 'note'},
      ];

  @override
  String signOwn(String bytesHex) => 'own-$bytesHex';
  @override
  String receiptSign(String cid) => 'rcpt-$cid';
  @override
  bool receiptVerify(String cid, String did, String sig) => sig == 'rcpt-$cid';
  @override
  String viewSign(String node) {
    calls.add('viewSign');
    return '{"view":1}';
  }

  @override
  String dump() => '{"replica":true}';
}

class _Wire implements CompactTransport {
  final List<String> asks = [];
  final List<String> answers = [];
  final List<String> views = [];

  @override
  int ask(List<String> nodes, {required String record, required String op, required String cid, required String bytes}) {
    asks.add('$record/$op $cid -> ${nodes.join(',')}');
    return 0;
  }

  @override
  int answer(String node, {required String cid, required String signerDid, required String sig}) {
    answers.add('$node $cid $signerDid $sig');
    return 0;
  }

  @override
  void publishView(String bundle) => views.add(bundle);
}

CompactEngine _engine(_Border b, _Wire w, {List<String> members = const [_nodeB]}) =>
    CompactEngine(border: b, transport: w, ownNode: _nodeA, members: () => members);

void main() {
  group('CompactBook', () {
    CompactView v(String did, int seq, Map<String, String> st) =>
        CompactView.fromVerified(_fakeVerify(_view(did, seq, st))!, _view(did, seq, st));

    test('keeps the highest seq per community', () {
      final b = CompactBook();
      expect(b.hear(v(_a, 2, {_b: 'in_compact'})), isTrue);
      expect(b.hear(v(_a, 1, {_b: 'anathema'})), isFalse, reason: 'an older view never replaces a newer');
      expect(b.views[_a]!.standings[_b], CompactStanding.inCompact);
    });

    test('a bad reading from a followed community wins; a good one otherwise', () {
      final b = CompactBook()
        ..hear(v(_a, 1, {_c: 'in_compact'}))
        ..hear(v(_b, 1, {_c: 'anathema'}));
      expect(b.standingOf(_c, [_a]), CompactStanding.inCompact);
      expect(b.standingOf(_c, [_a, _b]), CompactStanding.anathema);
      expect(b.standingOf(_a, [_a]), isNull, reason: 'a community is not judged against itself');
      expect(b.compactMates([_a]), {_c});
      expect(b.nodeOf(_a), _nodeA);
    });

    test('reload re-verifies every view and drops one that no longer does', () {
      final b = CompactBook()..hear(v(_a, 1, {_c: 'probationary'}));
      final j = b.toJson();
      (j['views'] as Map)[_b] = jsonEncode({'forged': true});
      final back = CompactBook.fromJson(j, _fakeVerify);
      expect(back.views.keys, [_a]);
    });

    test('a view key names its community', () {
      expect(communityOfViewKey(compactViewKey(_a)), _a);
      expect(communityOfViewKey(_a), isNull);
    });
  });

  group('PeerService and compact views', () {
    test('a view rides the policy carrier and a reader badges by it', () {
      final s = PeerService(communityCrypto: _Decode(), viewVerifier: _fakeVerify);
      s.ingestEvents([
        _policyEvent(_a, _policy(_a)),
        _policyEvent(compactViewKey(_a), _view(_a, 3, {_b: 'in_compact', _c: 'probationary'})),
      ]);
      expect(s.compactBook.views[_a]!.seq, 3);
      expect(s.communities.heard.containsKey(compactViewKey(_a)), isFalse,
          reason: 'a view is not a policy');
      expect(s.standingOfCommunity(_b), isNull, reason: 'heard, not followed');
      s.followCommunity(_a);
      expect(s.standingOfCommunity(_b), CompactStanding.inCompact);
      expect(s.standingOfCommunity(_c), CompactStanding.probationary);
      expect(s.compactMates, {_b, _c});
    });

    test('a view that does not verify, or names another community, is dropped', () {
      final s = PeerService(communityCrypto: _Decode(), viewVerifier: _fakeVerify);
      s.ingestEvents([
        _policyEvent(compactViewKey(_a), jsonEncode({'forged': true})),
        _policyEvent(compactViewKey(_a), _view(_b, 1, {})),
      ]);
      expect(s.compactBook.views, isEmpty);
    });

    test("a followed community's policy hides posts from an anathema community (D39)", () {
      final s = PeerService(communityCrypto: _Decode(), viewVerifier: _fakeVerify);
      s.ingestEvents([
        _policyEvent(_a, _policy(_a, standing: {'Anathema': 'Hide', 'Outside': 'Warn'})),
        _policyEvent(compactViewKey(_a), _view(_a, 1, {_b: 'in_compact', _c: 'anathema'})),
      ]);
      s.followCommunity(_a);
      expect(s.verdictFor(_post(_c))!.action, PolicyAction.hide);
      expect(s.verdictFor(_post(_c))!.reasons.single.code, 'compact_standing');
      expect(s.verdictFor(_post(_b)), isNull, reason: 'in compact: no rule applies');
      expect(s.verdictFor(_post('did:key:zStranger'))!.action, PolicyAction.warn,
          reason: 'outside every compact of ours');
      expect(s.verdictFor(_post(_a))?.action ?? PolicyAction.show, PolicyAction.show,
          reason: "a post in A's own name is A's own policy's business, not its standing rules'");
      s.setCommunityPolicyApplied(_a, false);
      expect(s.verdictFor(_post(_c)), isNull, reason: 'a reader may set the policy aside');
    });
  });

  test("a policy's rules carry its standing rules into an amendment", () {
    final read = jsonDecode(_policy(_a, standing: {'Anathema': 'Hide'})) as Map<String, dynamic>;
    final p = CommunityPolicy.fromVerified(read, '');
    expect(p.rules['standing'], {'Anathema': 'Hide'});
    expect(p.actionForStanding('anathema'), LabelAction.hide);
    expect(p.actionForStanding('in_compact'), LabelAction.allow);
    final none = CommunityPolicy.fromVerified(jsonDecode(_policy(_a)) as Map<String, dynamic>, '');
    expect(none.rules.containsKey('standing'), isFalse, reason: 'a D37 policy amends as it did');
  });

  group('CompactEngine', () {
    test('a delivery is re-sent until its receipt verifies', () {
      final b = _Border();
      final w = _Wire();
      final e = _engine(b, w);
      expect(e.present('river', [_b]), isTrue);
      expect(w.asks.length, 5, reason: 'five claims delivered');
      expect(e.unacknowledged, 5);
      expect(e.partners, {_b});
      e.onSignature(fromNode: _nodeB, cid: 'b3:claim0', signerDid: 'x', sig: 'rcpt-b3:claim0');
      e.onSignature(fromNode: _nodeB, cid: 'b3:claim1', signerDid: 'x', sig: 'forged');
      expect(e.unacknowledged, 4, reason: 'a receipt that does not verify acknowledges nothing');
      w.asks.clear();
      for (var i = 0; i < CompactEngine.resendEveryTicks; i++) {
        e.tick();
      }
      expect(w.asks.length, 4, reason: 'only the unacknowledged are re-sent');
    });

    test('a delivery that lands is answered with a receipt; one that never will is not', () {
      final b = _Border();
      final w = _Wire();
      final e = _engine(b, w);
      expect(e.onRequest(fromNode: _nodeB, record: 'kc_record', op: 'deliver', cid: 'b3:x', bytes: 'ff'), isTrue);
      expect(b.ingested, ['ff']);
      expect(w.answers.single, '$_nodeB b3:x ${b.selfDid} rcpt-b3:x');
      e.onRequest(fromNode: _nodeB, record: 'kc_record', op: 'deliver', cid: 'b3:y', bytes: 'bad');
      expect(w.answers.length, 1);
      expect(e.lastError, contains('refused'));
      expect(e.onRequest(fromNode: _nodeB, record: 'membership', op: 'admit', cid: 'b3:z', bytes: 'aa'), isFalse,
          reason: 'a roll act is a person\'s to sign, not the engine\'s');
    });

    test('a seal lands once enough signatures arrive, and the sealed note goes to every member', () {
      final b = _Border()..sealLandsAt = 3;
      final w = _Wire();
      final e = _engine(b, w);
      expect(e.convene('river', [_a, _b], [_nodeB]), isTrue);
      expect(w.asks.single, 'kc_seal/sign b3:seal -> $_nodeB');
      e.onSignature(fromNode: _nodeB, cid: 'b3:seal', signerDid: 'did:key:zBetaEnvoy', sig: 's2');
      expect(e.seals['b3:seal']!.landed, isFalse, reason: 'two signatures do not authorize it yet');
      e.onSignature(fromNode: _nodeB, cid: 'b3:seal', signerDid: 'did:key:zBetaExaminer', sig: 's3');
      expect(e.seals['b3:seal']!.landed, isTrue);
      expect(w.asks.last, 'kc_seal/sealed b3:sealed -> $_nodeB');
    });

    test('a seal ask and a sealed note from another node are answered', () {
      final b = _Border();
      final w = _Wire();
      final e = _engine(b, w);
      e.onRequest(fromNode: _nodeB, record: 'kc_seal', op: 'sign', cid: 'b3:s', bytes: 'mf');
      expect(w.answers.single, '$_nodeB b3:s ${b.selfDid} sig-${b.selfDid}');
      e.onRequest(fromNode: _nodeB, record: 'kc_seal', op: 'sealed', cid: 'b3:n', bytes: 'note');
      expect(b.calls, contains('sealIngest note'));
    });

    test('an anathema is assembled once every reporter has signed', () {
      final b = _Border();
      final w = _Wire();
      final e = _engine(b, w);
      expect(e.report('anathema', 'river', {_b: _nodeB}, _c), isTrue);
      expect(w.asks.single, 'kc_conduct/sign b3:conduct -> $_nodeB');
      e.onSignature(fromNode: _nodeB, cid: 'b3:conduct', signerDid: 'did:key:zBetaEnvoy', sig: 'bs');
      expect(b.calls, contains('conductAssemble 2'));
      expect(w.asks.last, startsWith('kc_record/deliver b3:conduct0'));
    });

    test("a co-reporter's node signs under whichever compact covers it", () {
      final b = _Border();
      final w = _Wire();
      final e = _engine(b, w)..compactsWeSitIn = ['lake', 'river'];
      e.onRequest(fromNode: _nodeB, record: 'kc_conduct', op: 'sign', cid: 'b3:k', bytes: 'cd');
      expect(w.answers.single, '$_nodeB b3:k ${b.selfDid} csig');
    });

    test('the rite seals once the Inductor has recited and its witnesses have attested', () {
      final b = _Border();
      final w = _Wire();
      final e = _engine(b, w);
      const inductor = 'did:key:zAlphaInductor00001';
      expect(e.crossBorder(inductorDid: b.selfDid), isFalse,
          reason: 'the envoy cannot also be the Inductor: KC holds one delegation per speaker');
      expect(e.crossBorder(inductorDid: inductor, witnessNodes: [_nodeB]), isTrue);
      expect(w.asks.where((a) => a.startsWith('kc_attest/recite')).length, 1);
      expect(w.asks.where((a) => a.startsWith('kc_attest/attest')).length, 1,
          reason: 'this node signs its own attestation; the other witness is asked');
      final attest = w.asks.firstWhere((a) => a.startsWith('kc_attest/attest')).split(' ')[1];
      final recite = w.asks.firstWhere((a) => a.startsWith('kc_attest/recite')).split(' ')[1];
      e.onSignature(fromNode: _nodeB, cid: attest, signerDid: 'did:key:zSomeoneElse', sig: 'x');
      e.onSignature(fromNode: _nodeB, cid: attest, signerDid: 'did:key:zAlphaWitness0001', sig: 'w2');
      expect(e.rite, isNotNull, reason: 'the recitation is not in yet');
      e.onSignature(fromNode: _nodeB, cid: recite, signerDid: 'did:key:zSomeoneElse', sig: 'x');
      expect(e.rite, isNotNull, reason: 'only the Inductor recites');
      e.onSignature(fromNode: _nodeB, cid: recite, signerDid: inductor, sig: 'r');
      expect(e.rite, isNull);
      expect(b.calls, contains('riteSeal 2'));
    });

    test('the view is re-minted after a change, on the governance node', () {
      final b = _Border();
      final w = _Wire();
      final e = _engine(b, w);
      e.tick();
      expect(w.views, ['{"view":1}']);
      e.tick();
      expect(w.views.length, 1, reason: 'nothing changed');
      e.onRequest(fromNode: _nodeB, record: 'kc_record', op: 'deliver', cid: 'b3:x', bytes: 'ff');
      e.tick();
      expect(w.views.length, 2);
    });

    test('an examiner seated on another node is handed every record, seals last', () {
      final b = _Border();
      final w = _Wire();
      final e = _engine(b, w);
      e.onRequest(fromNode: _nodeB, record: 'kc_record', op: 'deliver', cid: 'b3:in-ff', bytes: 'ff');
      w.asks.clear();
      e.seat([
        {'did': 'did:key:zExaminer', 'node': _nodeC}
      ]);
      final toC = [for (final a in w.asks) if (a.endsWith(_nodeC)) a.split(' ').take(2).join(' ')];
      expect(toC.take(2), ['kc_record/deliver b3:in-ff', 'kc_seal/sealed b3:sealed'],
          reason: "another community's record and the seal reach the examiner, the seal after its part");
      expect(toC, contains('kc_record/deliver b3:examiners0'));
      // A record that arrives afterwards is passed on as it lands.
      w.asks.clear();
      e.onRequest(fromNode: _nodeB, record: 'kc_record', op: 'deliver', cid: 'b3:in-ee', bytes: 'ee');
      expect(w.asks, contains('kc_record/deliver b3:in-ee -> $_nodeC'));
    });

    test('its state survives a restart', () {
      final b = _Border();
      final w = _Wire();
      final e = _engine(b, w);
      e.present('river', [_b]);
      e.convene('river', [_a, _b], [_nodeB]);
      e.seat([
        {'did': 'did:key:zExaminer', 'node': _nodeB}
      ]);
      final again = _engine(_Border(), _Wire())
        ..restore(jsonDecode(e.toJsonString()) as Map<String, dynamic>);
      expect(again.unacknowledged, e.unacknowledged);
      expect(again.seals.keys, ['b3:seal']);
      expect(again.examinerNodes, {_nodeB});
      expect(again.partners, {_b});
    });
  });

  final libPath = EthneFfi.resolveLibraryPath();
  // A library built before Phase 5 has no KC border: skip, and say so.
  bool hasKc() {
    try {
      DynamicLibrary.open(libPath!).lookup<NativeFunction<Pointer<Void> Function()>>('ethne_kc_new');
      return true;
    } on Object {
      return false;
    }
  }

  group('through the real cdylib', () {
    test('a replica round-trips, a receipt verifies, and junk is no view', () {
      final ffi = EthneFfi.open(libPath);
      final kc = EthneKc.create(ffi);
      expect(kc.verify(), isTrue);
      final again = EthneKc.load(ffi, kc.dump());
      expect(again.verify(), isTrue);
      final me = ffi.generateKeypair();
      final sig = ffi.kcReceiptSign('b3:00', me.priv);
      expect(ffi.kcReceiptVerify(cid: 'b3:00', did: me.did, sig: sig), isTrue);
      expect(ffi.kcReceiptVerify(cid: 'b3:01', did: me.did, sig: sig), isFalse);
      expect(ffi.compactViewVerify('{"payload":{}}'), isNull);
      expect(() => kc.ingest('00'), throwsA(isA<EthneException>()));
      kc.dispose();
      again.dispose();
    });
  },
      skip: libPath == null
          ? 'ethne_agora not built (set AGORA_ETHNE_PATH)'
          : (hasKc() ? false : 'ethne_agora at $libPath predates Phase 5 (rebuild: ./build.sh)'));
}
