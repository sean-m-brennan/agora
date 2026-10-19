// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// P3.3 S9 integration test: the member-roll border artifact (D26), through the
// ethne_agora cdylib over dart:ffi. Border artifact #6 — the polity's roll under
// its ROOT key, which is what gives its members a real anonymous channel in a
// compact tier that models communities and speakers but no member roster.
//
// Proves both verification models, and that they answer DIFFERENT questions:
//   * self-contained — signed by the polity it names and well-formed, with no
//     charter log. This is the whole reach a compact tier has: it establishes
//     the PUBLISHER, and cannot say whether the roll is true.
//   * full-log — additionally checks the roll against what this log says the
//     membership was at the roll's `as_of`. A compact tier cannot do this; a
//     polity's own node can.
//
// Needs the cdylib built (set AGORA_ETHNE_PATH; test.sh does), else self-skips.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/ethne_bindings.dart';

void main() {
  final libPath = EthneFfi.resolveLibraryPath();

  group('Ethne member roll (P3.3 S9)', () {
    if (libPath == null) {
      test('skipped — ethne_agora not built', () {},
          skip: 'set AGORA_ETHNE_PATH '
              '(build native/build/libethne_agora.{so,dylib} via ./build.sh)');
      return;
    }

    late EthneFfi ffi;
    setUp(() => ffi = EthneFfi.open(libPath));

    /// Found a 3-founder polity. Returns the archive, the polity's own keypair
    /// (whose private half is the ROOT key a roll is published under) and the
    /// founders.
    ({EthneArchive arc, EthneKeypair polity, List<EthneKeypair> founders})
        founded() {
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
      return (arc: arc, polity: polity, founders: founders);
    }

    test('a published roll verifies both ways and names the whole roll', () {
      final f = founded();
      final roll = f.arc.signMemberRoll(polityDid: f.polity.did, root: f.polity);

      expect(ffi.verifyMemberRoll(roll), isTrue, reason: ffi.lastError());
      expect(f.arc.verifyMemberRollFull(roll), isTrue,
          reason: f.arc.lastError());

      final decoded = jsonDecode(roll) as Map<String, dynamic>;
      final payload = decoded['payload'] as Map<String, dynamic>;
      final members = (payload['members'] as List).cast<Map<String, dynamic>>();
      expect(payload['community_did'], f.polity.did);
      expect(members.map((m) => m['member_did']).toSet(),
          f.founders.map((x) => x.did).toSet());
    });

    test('the polity is not named on its own roll', () {
      final f = founded();
      final roll = f.arc.signMemberRoll(polityDid: f.polity.did, root: f.polity);
      final payload =
          (jsonDecode(roll) as Map<String, dynamic>)['payload'] as Map<String, dynamic>;
      final members = (payload['members'] as List).cast<Map<String, dynamic>>();
      // Its root key is already an insider; a second entry would be a repeated
      // ring position. A true reading, not a gap.
      expect(members.any((m) => m['member_did'] == f.polity.did), isFalse);
    });

    test('only the root key can publish — a member key is refused', () {
      final f = founded();
      // A member's keypair is a perfectly good keypair; it is simply not the
      // polity's, and the roll is the polity speaking.
      expect(
        () => f.arc.signMemberRoll(polityDid: f.polity.did, root: f.founders[0]),
        throwsA(isA<EthneException>()),
      );
    });

    test('a tampered roll is rejected by both verifiers', () {
      final f = founded();
      final roll = f.arc.signMemberRoll(polityDid: f.polity.did, root: f.polity);
      final v = jsonDecode(roll) as Map<String, dynamic>;
      (v['payload'] as Map<String, dynamic>)['members'] =
          ((v['payload'] as Map<String, dynamic>)['members'] as List).sublist(1);
      final tampered = jsonEncode(v);

      expect(ffi.verifyMemberRoll(tampered), isFalse);
      expect(f.arc.verifyMemberRollFull(tampered), isFalse);
    });

    test('a roll is a snapshot: an older one still proves its publisher, and '
        'as_of says which reading it was', () {
      final f = founded();
      final stranger = ffi.generateKeypair();
      // Mint honestly, then admit the stranger to the LOG only — so the log and
      // the published roll now disagree, with the roll being the stale one.
      final roll = f.arc.signMemberRoll(polityDid: f.polity.did, root: f.polity);
      f.arc.admitMember(
        polityDid: f.polity.did,
        memberDid: stranger.did,
        deciders: [f.founders[0], f.founders[1]],
        joiner: stranger,
      );

      // The roll is still authentically the polity's, and still says what it
      // said. A compact tier would accept it, because establishing the publisher
      // is the whole of what it can do — and the full verifier accepts it too,
      // because `as_of` names the reading it was taken at and the log agreed
      // with it THEN. Provenance, not authority: nothing gates on the stamp.
      expect(f.arc.verifyMemberRollFull(roll), isTrue, reason: f.arc.lastError());
      expect(ffi.verifyMemberRoll(roll), isTrue, reason: ffi.lastError());

      // And a later roll, taken now, does name them — publication is a snapshot,
      // and `as_of` is the provenance that says which one.
      final later = f.arc.signMemberRoll(polityDid: f.polity.did, root: f.polity);
      final laterMembers =
          (((jsonDecode(later) as Map<String, dynamic>)['payload']
                  as Map<String, dynamic>)['members'] as List)
              .cast<Map<String, dynamic>>();
      expect(laterMembers.map((m) => m['member_did']), contains(stranger.did));
      expect(f.arc.verifyMemberRollFull(later), isTrue,
          reason: f.arc.lastError());
    });
  });
}
