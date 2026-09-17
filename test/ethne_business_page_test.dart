// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// P3.1 integration test: envoy office + the business-page border artifact,
// through the ethne_agora cdylib over dart:ffi (SOCIAL_APP_PLAN.md §2.2 /
// Phase 3 box 2). Proves both verification models a person's app uses:
//   * self-contained bundle {page, delegation} — polity-root → envoy → page
//     with NO charter log (open discovery);
//   * full-log — page signature + charter validity + the signer being a
//     current authorized envoy (strongest).
//
// Needs the cdylib built (set AGORA_ETHNE_PATH; test.sh does), else self-skips.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/ethne_bindings.dart';

void main() {
  final libPath = EthneFfi.resolveLibraryPath();

  group('Ethne business page (P3.1)', () {
    if (libPath == null) {
      test('skipped — ethne_agora not built', () {}, skip: 'set AGORA_ETHNE_PATH '
          '(build native/build/libethne_agora.so via ./build.sh)');
      return;
    }

    late EthneFfi ffi;
    setUp(() => ffi = EthneFfi.open(libPath));

    /// Found a 3-founder business and authorize `founders[2]` as its envoy by a
    /// majority of the roll. Returns (archive, polity, root keys, founders).
    ({EthneArchive arc, EthneKeypair polity, List<EthneKeypair> founders})
        foundedWithEnvoy() {
      final polity = ffi.generateKeypair();
      final founders = List.generate(3, (_) => ffi.generateKeypair());
      final arc = ffi.newArchive();
      addTearDown(arc.dispose);
      arc.foundPolity(
        polityDid: polity.did,
        name: 'Corner Café',
        statement: 'A neighborhood coffee shop.',
        memberDids: founders.map((f) => f.did).toList(),
        ratifiers: [founders[0], founders[1]],
      );
      // Envoy = founders[2] (not an authorizer); authorized by a majority.
      arc.authorizeEnvoy(
        polityDid: polity.did,
        envoy: founders[2],
        rationale: 'store manager speaks for the shop',
        authorizers: [founders[0], founders[1]],
      );
      return (arc: arc, polity: polity, founders: founders);
    }

    /// Bundle a signed page and delegation into `{"page","delegation"}`.
    String bundle(String pageJson, String delegationJson) => jsonEncode({
          'page': jsonDecode(pageJson),
          'delegation': jsonDecode(delegationJson),
        });

    test('envoy page verifies both ways (bundle + full log)', () {
      final f = foundedWithEnvoy();
      final envoy = f.founders[2];

      // The envoy is the one live speaker for the polity.
      expect(f.arc.envoyState(f.polity.did), [envoy.did]);
      // Charter is still authority-clean after the authorization.
      expect(f.arc.verify(), isTrue, reason: f.arc.lastError());

      // Border artifacts emit (the community identity self-verifies on build).
      final identity = f.arc
          .communityIdentity(polityDid: f.polity.did, name: 'Corner Café', root: f.polity);
      expect(identity, contains('Corner Café'));
      final delegation = f.arc.envoyDelegation(
          polityDid: f.polity.did, envoyDid: envoy.did, root: f.polity);

      final page = ffi.signBusinessPage(
        polityDid: f.polity.did,
        envoy: envoy,
        name: 'Corner Café',
        category: 'cafe',
        description: 'Best beans in town',
        seq: 1,
      );

      // Self-contained bundle (no log) AND full-log both accept.
      expect(ffi.verifyBusinessPageBundle(bundle(page, delegation)), isTrue,
          reason: ffi.lastError());
      expect(f.arc.verifyBusinessPageFull(page), isTrue,
          reason: f.arc.lastError());
    });

    test('a page signed by a non-envoy member is rejected', () {
      final f = foundedWithEnvoy();
      final envoy = f.founders[2];
      // founders[0] is a member but NOT an envoy.
      final rogue = ffi.signBusinessPage(
          polityDid: f.polity.did, envoy: f.founders[0], name: 'Corner Café');

      expect(f.arc.verifyBusinessPageFull(rogue), isFalse,
          reason: 'full-log must reject a non-envoy signer');
      // Even paired with the real envoy's delegation, the bundle must reject:
      // the page signer is not the delegated speaker.
      final delegation = f.arc.envoyDelegation(
          polityDid: f.polity.did, envoyDid: envoy.did, root: f.polity);
      expect(ffi.verifyBusinessPageBundle(bundle(rogue, delegation)), isFalse,
          reason: 'bundle must reject a page whose signer is not the envoy');
    });

    test('a tampered page fails both verifiers', () {
      final f = foundedWithEnvoy();
      final envoy = f.founders[2];
      final delegation = f.arc.envoyDelegation(
          polityDid: f.polity.did, envoyDid: envoy.did, root: f.polity);
      final page = ffi.signBusinessPage(
          polityDid: f.polity.did, envoy: envoy, name: 'Corner Café', seq: 1);

      // Mutate the signed payload after signing — the signature no longer covers it.
      final v = jsonDecode(page) as Map<String, dynamic>;
      (v['payload'] as Map<String, dynamic>)['name'] = 'Impostor Café';
      final tampered = jsonEncode(v);

      expect(ffi.verifyBusinessPageBundle(bundle(tampered, delegation)), isFalse,
          reason: 'a tampered page must fail signature verification');
      expect(f.arc.verifyBusinessPageFull(tampered), isFalse,
          reason: 'a tampered page must fail full-log verification too');
    });
  });
}
