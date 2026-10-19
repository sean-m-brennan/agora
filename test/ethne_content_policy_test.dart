// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Phase 4 integration test: a community's content policy (Ethne D37), through
// the ethne_agora cdylib over dart:ffi. The roll sets the policy (a majority to
// tighten, more than a majority to loosen), a Moderator labels alone, the
// polity's root key signs what readers follow, and the verdict a reader shows is
// computed natively — the same code the live cohort's driver runs.
//
// Needs the cdylib built (set AGORA_ETHNE_PATH; test.sh does), else self-skips.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/ethne_bindings.dart';

const _post =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const _strict = {
  'operator_bound_required': true,
  'min_tier': 2,
  'daily_post_cap': 3,
  'labels': {'nsfw': 'Hide', 'spoiler': 'Warn'},
};

void main() {
  final libPath = EthneFfi.resolveLibraryPath();

  group('Ethne content policy (D37)', () {
    if (libPath == null) {
      test('skipped — ethne_agora not built', () {},
          skip: 'set AGORA_ETHNE_PATH '
              '(build native/build/libethne_agora.{so,dylib} via ./build.sh)');
      return;
    }

    late EthneFfi ffi;
    setUp(() => ffi = EthneFfi.open(libPath));

    /// Five founders, all ratifying: a majority is 3, more than one is 4.
    ({EthneArchive arc, EthneKeypair polity, List<EthneKeypair> f}) founded() {
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
      return (arc: arc, polity: polity, f: f);
    }

    test('a majority sets it; a loosening at a bare majority is refused', () {
      final c = founded();
      c.arc.amendContentPolicy(
          polityDid: c.polity.did,
          policy: _strict,
          deciders: c.f.sublist(0, 3));
      expect(c.arc.verify(), isTrue, reason: c.arc.lastError());
      expect(c.arc.contentPolicyState(c.polity.did)['policy'], _strict);

      final looser = {..._strict, 'daily_post_cap': null};
      c.arc.amendContentPolicy(
          polityDid: c.polity.did, policy: looser, deciders: c.f.sublist(0, 3));
      expect(c.arc.verify(), isFalse);
      expect(c.arc.lastError(), contains('more than a majority'));
      expect(c.arc.contentPolicyState(c.polity.did)['policy'], _strict);
    });

    test('the artifact carries the policy and its moderators', () {
      final c = founded();
      c.arc.amendContentPolicy(
          polityDid: c.polity.did,
          policy: _strict,
          deciders: c.f.sublist(0, 3));
      c.arc.conferOffice(
          polityDid: c.polity.did,
          office: 'Moderator',
          holder: c.f[4],
          deciders: c.f.sublist(0, 3));
      final json =
          c.arc.signContentPolicy(polityDid: c.polity.did, root: c.polity);
      final read = ffi.verifyContentPolicy(json)!;
      expect(read['community_did'], c.polity.did);
      expect(read['policy'], _strict);
      expect(read['moderators'], [c.f[4].did]);

      expect(
          ffi.verifyContentPolicy(
              json.replaceFirst('"min_tier":2', '"min_tier":0')),
          isNull,
          reason: 'a reader cannot be handed a looser policy');
    });

    test('the verdict hides, warns and shows, and names why', () {
      final c = founded();
      c.arc.amendContentPolicy(
          polityDid: c.polity.did,
          policy: _strict,
          deciders: c.f.sublist(0, 3));
      c.arc.conferOffice(
          polityDid: c.polity.did,
          office: 'Moderator',
          holder: c.f[4],
          deciders: c.f.sublist(0, 3));
      final policy =
          c.arc.signContentPolicy(polityDid: c.polity.did, root: c.polity);

      Map<String, dynamic> v(
              {List<String> author = const [],
              List<String> labels = const [],
              int tier = 2,
              bool bound = true,
              int index = 1}) =>
          ffi.contentPolicyVerdict(
              policyJson: policy,
              postId: _post,
              authorLabels: author,
              labels: labels,
              authorTier: tier,
              authorOperatorBound: bound,
              authorPostIndexToday: index);

      expect(v()['action'], 'show');
      expect(v(bound: false)['reasons'][0]['code'], 'operator_unbound');
      expect(v(tier: 1)['action'], 'hide');
      expect(v(index: 4)['reasons'][0]['code'], 'over_daily_cap');
      expect(v(author: ['spoiler'])['action'], 'warn');

      final hide = ffi.signPostLabel(
          communityDid: c.polity.did,
          postId: _post,
          labels: ['nsfw'],
          seq: 1,
          moderator: c.f[4]);
      expect(
          ffi.verifyPostLabel(labelJson: hide, policyJson: policy)?['labels'],
          ['nsfw']);
      expect(v(labels: [hide])['action'], 'hide');

      final forged = ffi.signPostLabel(
          communityDid: c.polity.did,
          postId: _post,
          labels: ['nsfw'],
          seq: 1,
          moderator: c.f[0]);
      expect(
          ffi.verifyPostLabel(labelJson: forged, policyJson: policy), isNull);
      final r = v(labels: [forged]);
      expect((r['action'], r['labels_refused']), ('show', 1));
    });

    test('a policy and a moderator cross detached signing', () {
      final c = founded();
      final deciders = c.f.sublist(0, 3);
      final p = c.arc.pendingChange(
          record: 'content_policy',
          op: 'amend',
          polityDid: c.polity.did,
          memberDid: '',
          deciderDids: deciders.map((d) => d.did).toList(),
          policy: _strict);
      final shown =
          ffi.describe(record: 'content_policy', bytesHex: p['bytes']);
      expect(shown['policy'], _strict);
      c.arc.assembleSigned(
          record: 'content_policy',
          payload: p['payload'] as Map<String, dynamic>,
          signatures: [
            for (final d in deciders)
              (
                did: d.did,
                sig: ffi.signDetached(priv: d.priv, bytesHex: p['bytes'])
              )
          ]);

      final o = c.arc.pendingChange(
          record: 'office',
          op: 'confer',
          office: 'Moderator',
          polityDid: c.polity.did,
          memberDid: c.f[4].did,
          deciderDids: deciders.map((d) => d.did).toList());
      expect(o['signers_required'], contains(c.f[4].did));
      c.arc.assembleSigned(
          record: 'office',
          payload: o['payload'] as Map<String, dynamic>,
          signatures: [
            for (final d in [...deciders, c.f[4]])
              (
                did: d.did,
                sig: ffi.signDetached(priv: d.priv, bytesHex: o['bytes'])
              )
          ]);

      expect(c.arc.verify(), isTrue, reason: c.arc.lastError());
      expect(
          c.arc.contentPolicyState(c.polity.did)['moderators'], [c.f[4].did]);
    });
  });
}
