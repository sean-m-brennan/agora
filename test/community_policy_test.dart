// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// A community's content policy in the app (Phase 4, Ethne D37): the reader's
// book of policies, and the feed applying the policy of a community it follows.
//
// Two layers. The first half fakes the Ethne calls ([CommunityCrypto]) so every
// honest state is reachable with no cdylib: which policy is held, when one is
// replaced, what the feed hides and says. The last group runs the REAL cdylib
// end to end — a polity sets a policy, a moderator labels, and the feed of a
// PeerService that has only been handed events hides what the policy hides —
// and self-skips when the library is not built.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/ethne_bindings.dart';
import 'package:agora/src/model/community_policy.dart';
import 'package:agora/src/model/feed_entry.dart';
import 'package:agora/src/model/post.dart';
import 'package:agora/src/model/staff_identity.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/feed_view.dart';

const _garden = 'did:key:zGarden';
const _other = 'did:key:zOther';
const _author = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];

/// A fake policy bundle: the JSON of what verifyPolicy would report, so the
/// fake can "verify" it by decoding. A bundle starting with 'BAD' fails.
String _bundle(String did, int seq,
        {bool operatorBound = false,
        int minTier = 0,
        int? cap,
        Map<String, String> labels = const {},
        List<String> moderators = const []}) =>
    jsonEncode({
      'community_did': did,
      'seq': seq,
      'policy': {
        'operator_bound_required': operatorBound,
        'min_tier': minTier,
        'daily_post_cap': cap,
        'labels': labels,
      },
      'moderators': moderators,
    });

/// Decodes fake bundles and computes a verdict the way the library does, over
/// the decoded rules — enough to exercise the app's wiring, while the real
/// verdict is pinned in ethne_ffi and, end to end, in the last group here.
class _FakeCrypto implements CommunityCrypto {
  final List<Map<String, Object?>> verdictCalls = [];

  @override
  Map<String, dynamic>? verifyPolicy(String bundle) {
    if (bundle.startsWith('BAD')) return null;
    try {
      return jsonDecode(bundle) as Map<String, dynamic>;
    } on Object {
      return null;
    }
  }

  @override
  Map<String, dynamic> verdict({
    required String policyBundle,
    required String postId,
    required List<String> authorLabels,
    required List<String> labels,
    required int authorTier,
    required bool authorOperatorBound,
    required int authorPostIndexToday,
  }) {
    verdictCalls.add({
      'post': postId,
      'labels': labels,
      'index': authorPostIndexToday,
    });
    final p = (jsonDecode(policyBundle) as Map)['policy'] as Map;
    final reasons = <Map<String, Object?>>[];
    var action = 'show';
    if (p['operator_bound_required'] == true && !authorOperatorBound) {
      reasons.add({'code': 'operator_unbound'});
      action = 'hide';
    }
    if (authorTier < (p['min_tier'] as int)) {
      reasons.add({'code': 'below_min_tier', 'min_tier': p['min_tier']});
      action = 'hide';
    }
    final cap = p['daily_post_cap'] as int?;
    if (cap != null && authorPostIndexToday > cap) {
      reasons.add({'code': 'over_daily_cap', 'cap': cap});
      action = 'hide';
    }
    // Moderator labels arrive as 'label:<name>' strings in this fake.
    final applied = [
      ...authorLabels,
      for (final l in labels) l.replaceFirst('label:', ''),
    ];
    for (final l in applied) {
      final a = (p['labels'] as Map)[l];
      if (a == 'Hide') {
        action = 'hide';
        reasons.add({'code': 'label', 'label': l, 'by': 'author'});
      } else if (a == 'Warn') {
        if (action == 'show') action = 'warn';
        reasons.add({'code': 'label', 'label': l, 'by': 'author'});
      }
    }
    return {
      'community_did': (jsonDecode(policyBundle) as Map)['community_did'],
      'action': action,
      'reasons': reasons,
      'tags': applied,
    };
  }

  @override
  String signLabel({
    required String communityDid,
    required String postId,
    required List<String> labels,
    required int seq,
    required Map<String, dynamic> moderatorPriv,
    required String moderatorDid,
  }) =>
      'label:${labels.join(',')}';
}

AtRawEvent _policyEvent(String bundle, {String did = _garden}) => AtRawEvent(
      kind: agoraEventCommunityPolicy,
      uuid: const [9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9],
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      policyCommunity: did,
      policySeq: bundle.startsWith('BAD')
          ? 0
          : (jsonDecode(bundle) as Map)['seq'] as int? ?? 0,
      policyBundle: bundle,
    );

AtRawEvent _postEvent(String id,
        {String community = _garden,
        List<String> labels = const [],
        double ts = 1750000000,
        List<int> author = _author}) =>
    AtRawEvent(
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
      postId: id,
      postSeq: 1,
      postTs: ts,
      postBody: 'body of $id',
      postCommunity: community,
      postLabels: labels,
    );

AtRawEvent _labelEvent(String postId, String bundle, {String id = 'l1'}) =>
    AtRawEvent(
      kind: agoraEventPostLabel,
      uuid: const [8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8],
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      labelCommunity: _garden,
      labelPostId: postId,
      labelId: id,
      labelBundle: bundle,
    );

PeerService _svc(_FakeCrypto crypto, {String? ownPolity}) => PeerService(
      communityCrypto: crypto,
      staffIdentity: ownPolity == null
          ? null
          : StaffIdentity(
              polityDid: ownPolity,
              self: EthneKeypair('did:key:zMe', const {}, const {}),
              archive: const {}),
    );

List<String> _shown(PeerService s) => [
      for (final e in s.feed)
        if (e is PersonEntry) e.post.postId,
    ];

void main() {
  group('CommunityBook', () {
    CommunityPolicy p(int seq) => CommunityPolicy.fromVerified(
        jsonDecode(_bundle(_garden, seq)) as Map<String, dynamic>,
        _bundle(_garden, seq));

    test('keeps the newest heard, and says when a followed one is replaced',
        () {
      final b = CommunityBook();
      expect(b.hear(p(3)), isFalse, reason: 'not followed yet');
      expect(b.follow(_garden)?.seq, 3);
      expect(b.hear(p(2)), isFalse, reason: 'an older policy replaces nothing');
      expect(b.followed[_garden]!.seq, 3);
      expect(b.hear(p(5)), isTrue);
      expect(b.followed[_garden]!.seq, 5);
      expect(b.follow(_other), isNull, reason: 'nothing heard to follow');
    });

    test('a post keeps its place in its author\'s day', () {
      final b = CommunityBook();
      Post post(String id, double ts, {String c = _garden}) => Post(
          authorUuid: _author,
          postId: id,
          seq: 1,
          ts: ts,
          requiredTier: 0,
          body: '',
          outgoing: false,
          community: c);
      expect(b.indexToday(post('a', 1750000000)), 1);
      expect(b.indexToday(post('b', 1750000100)), 2);
      expect(b.indexToday(post('a', 1750000000)), 1, reason: 'idempotent');
      expect(b.indexToday(post('c', 1750000000 + 86400)), 1,
          reason: 'a new UTC day starts again');
      expect(b.indexToday(post('d', 1750000000, c: _other)), 1,
          reason: 'counted per community');
    });

    test('a post is placed by when it was made, not when it arrived', () {
      final b = CommunityBook();
      Post post(String id, double ts) => Post(
          authorUuid: _author,
          postId: id,
          seq: 1,
          ts: ts,
          requiredTier: 0,
          body: '',
          outgoing: false,
          community: _garden);
      // Received b, c, then a (a backfilled late), made a, b, c.
      expect(b.indexToday(post('pb', 1750000001)), 1);
      expect(b.indexToday(post('pc', 1750000002)), 2);
      expect(b.indexToday(post('pa', 1750000000)), 1);
      expect(b.indexToday(post('pb', 1750000001)), 2,
          reason: 'the earlier post moved b down');
      expect(b.indexToday(post('pc', 1750000002)), 3);
      expect(b.indexToday(post('z', 1750000002)), 4,
          reason: 'post id breaks a timestamp tie');
      expect(b.indexToday(post('pc', 1750000002)), 3);
    });

    test('restoring re-verifies every bundle', () {
      final b = CommunityBook()
        ..hear(p(3))
        ..follow(_garden)
        ..disabled.add(_garden);
      final json = b.toJson();
      final back = CommunityBook.fromJson(json, _FakeCrypto().verifyPolicy);
      expect(back.followed[_garden]?.seq, 3);
      expect(back.disabled, contains(_garden));
      final tampered = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      (tampered['followed'] as Map)[_garden]['bundle'] = 'BAD';
      (tampered['heard'] as Map)[_garden]['bundle'] = 'BAD';
      final none = CommunityBook.fromJson(tampered, _FakeCrypto().verifyPolicy);
      expect(none.followed, isEmpty);
      expect(none.disabled, isEmpty,
          reason: 'a switch for a policy not held means nothing');
    });
  });

  group('the feed under a followed policy', () {
    test('a post in an unfollowed community is shown unmoderated', () {
      final crypto = _FakeCrypto();
      final s = _svc(crypto);
      s.ingestEvents([
        _policyEvent(_bundle(_garden, 3, operatorBound: true)),
        _postEvent('p1'),
      ]);
      expect(s.communities.heard, contains(_garden));
      expect(_shown(s), ['p1']);
      expect(crypto.verdictCalls, isEmpty);
    });

    test('following applies the policy, and the hidden post is counted', () {
      final s = _svc(_FakeCrypto());
      s.ingestEvents([
        _policyEvent(_bundle(_garden, 3, operatorBound: true)),
        _postEvent('p1'),
        _postEvent('p2', community: ''),
      ]);
      expect(s.followCommunity(_garden), isTrue);
      expect(_shown(s), ['p2'], reason: 'p1 has no operator bound');
      final hidden = s.feedHiddenByPolicy;
      expect(hidden.map((h) => h.post.postId), ['p1']);
      expect(hidden.single.verdict.reasons.single.code, 'operator_unbound');
    });

    test('setting the policy aside restores what it hid, at once', () {
      final s = _svc(_FakeCrypto());
      s.ingestEvents(
          [_policyEvent(_bundle(_garden, 3, minTier: 2)), _postEvent('p1')]);
      s.followCommunity(_garden);
      expect(_shown(s), isEmpty);
      s.setCommunityPolicyApplied(_garden, false);
      expect(_shown(s), ['p1']);
      s.setCommunityPolicyApplied(_garden, true);
      expect(_shown(s), isEmpty);
    });

    test('the daily cap counts posts by when they were made', () {
      final s = _svc(_FakeCrypto());
      s.ingestEvents([_policyEvent(_bundle(_garden, 3, cap: 2))]);
      s.followCommunity(_garden);
      s.ingestEvents([
        _postEvent('p1', ts: 1750000001),
        _postEvent('p2', ts: 1750000002),
        _postEvent('p3', ts: 1750000003),
      ]);
      expect(_shown(s).toSet(), {'p1', 'p2'});
    });

    test('a first post that arrives last is still within the cap', () {
      final s = _svc(_FakeCrypto());
      s.ingestEvents([_policyEvent(_bundle(_garden, 3, cap: 2))]);
      s.followCommunity(_garden);
      s.ingestEvents([
        _postEvent('p2', ts: 1750000002),
        _postEvent('p3', ts: 1750000003),
      ]);
      expect(_shown(s).toSet(), {'p2', 'p3'});
      s.ingestEvents([_postEvent('p1', ts: 1750000001)]);
      expect(_shown(s).toSet(), {'p1', 'p2'},
          reason: 'the late first post moves p3 over the cap');
    });

    test('a warn label shows the post behind its verdict', () {
      final s = _svc(_FakeCrypto());
      s.ingestEvents([
        _policyEvent(_bundle(_garden, 3, labels: {'spoiler': 'Warn'}))
      ]);
      s.followCommunity(_garden);
      s.ingestEvents([
        _postEvent('p1', labels: ['spoiler'])
      ]);
      final e = s.feed.whereType<PersonEntry>().single;
      expect(e.verdict?.action, PolicyAction.warn);
    });

    test('a moderator label reaches the verdict and can hide', () {
      final crypto = _FakeCrypto();
      final s = _svc(crypto);
      s.ingestEvents([
        _policyEvent(_bundle(_garden, 3, labels: {'nsfw': 'Hide'}))
      ]);
      s.followCommunity(_garden);
      s.ingestEvents([_postEvent('p1')]);
      expect(_shown(s), ['p1']);
      s.ingestEvents([
        _labelEvent('p1', 'label:nsfw'),
        _labelEvent('p1', 'label:nsfw'), // the same label id: kept once
      ]);
      expect(_shown(s), isEmpty);
      expect(crypto.verdictCalls.last['labels'], ['label:nsfw']);
    });

    test('an unverifiable policy is dropped, and a newer one replaces', () {
      final s = _svc(_FakeCrypto());
      s.ingestEvents([_policyEvent('BAD')]);
      expect(s.communities.heard, isEmpty);
      s.ingestEvents([_policyEvent(_bundle(_garden, 3))]);
      s.followCommunity(_garden);
      s.ingestEvents([_policyEvent(_bundle(_garden, 7, minTier: 4))]);
      expect(s.communities.followed[_garden]!.seq, 7);
    });

    test('a member follows its own community\'s policy on sight', () {
      final s = _svc(_FakeCrypto(), ownPolity: _garden);
      s.ingestEvents([_policyEvent(_bundle(_garden, 3))]);
      expect(s.communities.followed, contains(_garden));
    });

    test('only a listed moderator may label, and your own label counts', () {
      final crypto = _FakeCrypto();
      final s = _svc(crypto, ownPolity: _garden);
      s.ingestEvents([
        _policyEvent(_bundle(_garden, 3,
            labels: {'nsfw': 'Hide'}, moderators: ['did:key:zMe'])),
        _postEvent('p1'),
      ]);
      expect(s.canModerate(_garden), isTrue);
      expect(s.canModerate(_other), isFalse);
      final post = s.feed.whereType<PersonEntry>().single.post;
      s.labelPost(post, ['nsfw']);
      expect(_shown(s), isEmpty,
          reason: 'the label is held here even before it comes back round');
    });
  });

  group('the feed view', () {
    testWidgets('says what a policy hid, and can show it anyway', (t) async {
      final s = _svc(_FakeCrypto());
      s.ingestEvents([_policyEvent(_bundle(_garden, 3, operatorBound: true))]);
      s.followCommunity(_garden);
      s.ingestEvents([_postEvent('p1')]);
      await t.pumpWidget(MaterialApp(home: FeedPage(service: s)));
      expect(find.byKey(const Key('hidden-by-policy')), findsOneWidget);
      await t.tap(find.textContaining('hidden by'));
      await t.pumpAndSettle();
      expect(find.textContaining('no operator answering'), findsOneWidget);
      await t.tap(find.byKey(const Key('policy-off-$_garden')));
      await t.pumpAndSettle();
      expect(find.text('body of p1'), findsOneWidget);
    });

    testWidgets('a warning is tapped through', (t) async {
      final s = _svc(_FakeCrypto());
      s.ingestEvents([
        _policyEvent(_bundle(_garden, 3, labels: {'spoiler': 'Warn'}))
      ]);
      s.followCommunity(_garden);
      s.ingestEvents([
        _postEvent('p1', labels: ['spoiler'])
      ]);
      await t.pumpWidget(MaterialApp(home: FeedPage(service: s)));
      expect(find.byKey(const Key('policy-warning')), findsOneWidget);
      expect(find.text('body of p1'), findsNothing);
      await t.tap(find.byKey(const Key('policy-warning')));
      await t.pump();
      expect(find.text('body of p1'), findsOneWidget);
    });
  });

  group('end to end through the real cdylib', () {
    final libPath = EthneFfi.resolveLibraryPath();
    if (libPath == null) {
      test('skipped — ethne_agora not built', () {},
          skip: 'set AGORA_ETHNE_PATH');
      return;
    }

    test('a policy the roll set hides what it says, and a moderator labels',
        () {
      final ffi = EthneFfi.open(libPath);
      final polity = ffi.generateKeypair();
      final f = List.generate(3, (_) => ffi.generateKeypair());
      final arc = ffi.newArchive();
      addTearDown(arc.dispose);
      arc.foundPolity(
          polityDid: polity.did,
          name: 'Garden',
          statement: 'Neighbours who garden.',
          memberDids: f.map((m) => m.did).toList(),
          ratifiers: f);
      arc.amendContentPolicy(
          polityDid: polity.did,
          policy: {
            'operator_bound_required': false,
            'min_tier': 0,
            'daily_post_cap': null,
            'labels': {'nsfw': 'Hide'},
          },
          deciders: f.sublist(0, 2));
      arc.conferOffice(
          polityDid: polity.did,
          office: 'Moderator',
          holder: f[2],
          deciders: f.sublist(0, 2));
      final bundle = arc.signContentPolicy(polityDid: polity.did, root: polity);

      // A PeerService that has only been handed events, verifying with the
      // real library (no crypto override).
      final s = PeerService();
      s.ingestEvents([_policyEvent(bundle, did: polity.did)]);
      expect(s.followCommunity(polity.did), isTrue);
      final pid = 'c' * 64;
      s.ingestEvents([_postEvent(pid, community: polity.did)]);
      expect(_shown(s), [pid]);

      final label = ffi.signPostLabel(
          communityDid: polity.did,
          postId: pid,
          labels: ['nsfw'],
          seq: 1,
          moderator: f[2]);
      s.ingestEvents([
        AtRawEvent(
          kind: agoraEventPostLabel,
          uuid: const [],
          signingPubkey: const [],
          rank: 0,
          operatorBound: false,
          operatorAttestedAt: 0,
          operatorPubkey: const [],
          repScore: 0,
          repRated: false,
          rttMs: 0,
          labelCommunity: polity.did,
          labelPostId: pid,
          labelId: 'x',
          labelBundle: label,
        )
      ]);
      expect(_shown(s), isEmpty, reason: 'the moderator\'s label hides it');
      expect(s.feedHiddenByPolicy.single.verdict.reasons.single.labelledBy,
          f[2].did);

      // A label signed by a member who is NOT a moderator does nothing.
      final s2 = PeerService();
      s2.ingestEvents([_policyEvent(bundle, did: polity.did)]);
      s2.followCommunity(polity.did);
      s2.ingestEvents([_postEvent(pid, community: polity.did)]);
      final forged = ffi.signPostLabel(
          communityDid: polity.did,
          postId: pid,
          labels: ['nsfw'],
          seq: 1,
          moderator: f[0]);
      s2.ingestEvents([
        AtRawEvent(
          kind: agoraEventPostLabel,
          uuid: const [],
          signingPubkey: const [],
          rank: 0,
          operatorBound: false,
          operatorAttestedAt: 0,
          operatorPubkey: const [],
          repScore: 0,
          repRated: false,
          rttMs: 0,
          labelCommunity: polity.did,
          labelPostId: pid,
          labelId: 'y',
          labelBundle: forged,
        )
      ]);
      expect(_shown(s2), [pid]);
    });
  });
}
