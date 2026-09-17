// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// P3.0 integration test: found and read a real Ethne polity (a "business")
// through the ethne_agora cdylib over dart:ffi — no Python. Proves the whole
// C-ABI-over-Rust bridge end to end (SOCIAL_APP_PLAN.md §2.2 / Phase 3 box 1).
//
// Needs the cdylib built: set AGORA_ETHNE_PATH (test.sh does when native/build
// exists), else the test self-skips like the daemon round-trip does. Build with
// ./build.sh (or the ethne_ffi CMake target).

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/ethne_bindings.dart';

/// Perform a full induction rite for [member] and complete it: the five
/// movements in order, attended and witnessed by [attending], then the
/// `Affirmation` citing exactly those five CIDs. Returns the movement CIDs.
///
/// Three movements carry content the core checks against this charter — the
/// substrate's name, the in-force commitment keys (none here), and the anchor
/// (none: `found_impl` builds a bare substrate). Two carry nothing checkable.
List<String> rite(
  EthneArchive arc,
  String polityDid,
  EthneKeypair member,
  List<EthneKeypair> attending, {
  String substrateName = 'Corner Café',
}) {
  final cids = <String>[
    arc.reciteMovement(
      polityDid: polityDid,
      member: member,
      movement: {'Substrate': {'names': substrateName}},
      statement: 'I name the ground we stand on.',
      attending: attending,
    ),
    arc.reciteMovement(
      polityDid: polityDid,
      member: member,
      movement: 'Fallenness',
      statement: 'I will fall short of it.',
      attending: attending,
    ),
    arc.reciteMovement(
      polityDid: polityDid,
      member: member,
      movement: 'Recognition',
      statement: 'I see the rest of the roll.',
      attending: attending,
    ),
    arc.reciteMovement(
      polityDid: polityDid,
      member: member,
      movement: {'CommonVirtue': {'commits_to': <String>[]}},
      statement: 'I commit to what this polity binds itself to.',
      attending: attending,
    ),
    arc.reciteMovement(
      polityDid: polityDid,
      member: member,
      movement: {'NonUltimacy': {'names_anchor': null}},
      statement: 'This polity is not the last word.',
      attending: attending,
    ),
  ];
  arc.inductMember(
    polityDid: polityDid,
    member: member,
    movementCids: cids,
    witnesses: attending,
  );
  return cids;
}

void main() {
  final libPath = EthneFfi.resolveLibraryPath();

  group('Ethne polity round-trip (P3.0)', () {
    if (libPath == null) {
      test('skipped — ethne_agora not built', () {}, skip: 'set AGORA_ETHNE_PATH '
          '(build native/build/libethne_agora.so via ./build.sh)');
      return;
    }

    late EthneFfi ffi;
    setUp(() => ffi = EthneFfi.open(libPath));

    test('found a business, admit staff, read the roll, verify', () {
      final polity = ffi.generateKeypair();
      final founders = List.generate(3, (_) => ffi.generateKeypair());

      final arc = ffi.newArchive();
      addTearDown(arc.dispose);

      // Found "Corner Café" with 3 founders, ratified by a majority (2 of 3).
      arc.foundPolity(
        polityDid: polity.did,
        name: 'Corner Café',
        statement: 'A neighborhood coffee shop.',
        memberDids: founders.map((f) => f.did).toList(),
        ratifiers: [founders[0], founders[1]],
      );

      // Hire a fourth: deciders = majority of the roll, the joiner consents.
      final barista = ffi.generateKeypair();
      arc.admitMember(
        polityDid: polity.did,
        memberDid: barista.did,
        rationale: 'new barista',
        deciders: [founders[0], founders[1]],
        joiner: barista,
      );

      // The roll is the four of them, and the business identity reads back.
      final state = arc.charterState(polity.did);
      expect(state['chartered'], isTrue);
      expect(state['substrate']['name'], 'Corner Café');
      final members = (state['members'] as List).cast<String>();
      expect(members, hasLength(4));
      for (final f in founders) {
        expect(members, contains(f.did));
      }
      expect(members, contains(barista.did));

      // Both verification passes hold (signatures + governance).
      expect(arc.verify(), isTrue, reason: arc.lastError());
    });

    test('the log persists and reloads with the roll intact', () {
      final polity = ffi.generateKeypair();
      final founders = List.generate(3, (_) => ffi.generateKeypair());
      final arc = ffi.newArchive();
      addTearDown(arc.dispose);
      arc.foundPolity(
        polityDid: polity.did,
        name: 'Persistent LLC',
        statement: 'Founded once, read forever.',
        memberDids: founders.map((f) => f.did).toList(),
        ratifiers: [founders[0], founders[1]],
      );

      final dumped = arc.dumpJson();
      final reloaded = ffi.loadArchive(dumped);
      addTearDown(reloaded.dispose);

      expect(reloaded.verify(), isTrue, reason: reloaded.lastError());
      final members =
          (reloaded.charterState(polity.did)['members'] as List).cast<String>();
      expect(members, hasLength(3));
    });

    // P3.3 S1 — D29 seasoning. Admission puts somebody on the roll; INDUCTION
    // is the separate step by which they acquire the substrate, and the core
    // counts every majority over ratifiers-or-inducted members only
    // (en-charter/src/authority.rs:437 seasoned_members, :453 deciding_weight).
    // So an admitted-but-un-inducted member is on the roll carrying a vote worth
    // nothing — which, left unbound, would cap a polity's deciders at its
    // founders forever and put expulsion (majority + 1) out of reach as it grew.
    test('an admitted member carries no deciding weight until inducted', () {
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

      // Ratifying IS a founding member's induction — but only the ratifiers'.
      // founders[2] is on the roll and was never seasoned.
      var st = arc.affirmationState(polity.did);
      expect(st['roll'], 3);
      expect(st['seasoned'], 2, reason: 'only the two ratifiers hold it');

      final barista = ffi.generateKeypair();
      arc.admitMember(
        polityDid: polity.did,
        memberDid: barista.did,
        rationale: 'new barista',
        deciders: [founders[0], founders[1]],
        joiner: barista,
      );

      // The roll grew; the electorate did not.
      st = arc.affirmationState(polity.did);
      expect(st['roll'], 4);
      expect(st['seasoned'], 2, reason: 'admission alone seasons nobody');
      final inducted = {
        for (final m in (st['members'] as List).cast<Map<String, dynamic>>())
          m['did'] as String: m['inducted'] as bool,
      };
      expect(inducted[barista.did], isFalse);
      expect(inducted[founders[2].did], isFalse,
          reason: 'a listed founder who never signed is on the roll, unseasoned');

      // This is the trap the binding exists to escape: expulsion needs
      // majority(2)+1 = 3 deciders drawn from a seasoned set of 2.
      expect(st['expel_need'], 3);
      expect(st['seasoned'], lessThan(st['expel_need'] as int),
          reason: 'expulsion is unreachable while nobody new is inducted');
      expect(st['can_contract'], isFalse,
          reason: 'and the self-govern floor blocks shrinking anyway');

      // Perform the rite: five movements in order, attended by the members who
      // hold the substrate. Three carry content the core checks against the
      // charter; two carry nothing checkable.
      final attending = [founders[0], founders[1]];
      final cids = rite(arc, polity.did, barista, attending);
      expect(cids, hasLength(5));
      expect(cids.toSet(), hasLength(5), reason: 'five distinct records');

      // NOW the electorate has grown, and the bar moves with it.
      st = arc.affirmationState(polity.did);
      expect(st['roll'], 4);
      expect(st['seasoned'], 3, reason: 'the rite is what seasons a member');
      expect(st['admit_need'], 2);
      expect(st['expel_need'], 3);
      expect(st['seasoned'], greaterThanOrEqualTo(st['expel_need'] as int),
          reason: 'expulsion is now reachable');
      // ...but the self-govern floor is counted over SEASONED members, not the
      // roll: dropping to two leaves majority(2)+1 = 3 deciders needed out of 2.
      // So a polity needs FOUR inducted members before anyone can leave at all.
      expect(st['can_contract'], isFalse,
          reason: 'three seasoned cannot drop to two and still self-govern');

      // Season the fourth (founders[2] was listed at founding but never signed,
      // so they are on the roll un-inducted) and the floor clears.
      rite(arc, polity.did, founders[2], attending);
      st = arc.affirmationState(polity.did);
      expect(st['seasoned'], 4);
      expect(st['can_contract'], isTrue,
          reason: 'four seasoned can drop to three and still self-govern');

      // And the whole log still passes both passes.
      expect(arc.verify(), isTrue, reason: arc.lastError());
    });

    test('an induction citing the wrong movements is refused', () {
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
      final barista = ffi.generateKeypair();
      arc.admitMember(
        polityDid: polity.did,
        memberDid: barista.did,
        deciders: [founders[0], founders[1]],
        joiner: barista,
      );

      // Only ONE movement recited, then an induction claiming the rite is done.
      final cid = arc.reciteMovement(
        polityDid: polity.did,
        member: barista,
        movement: {'Substrate': {'names': 'Corner Café'}},
        statement: 'I name the ground we stand on.',
        attending: [founders[0], founders[1]],
      );
      arc.inductMember(
        polityDid: polity.did,
        member: barista,
        movementCids: [cid],
        witnesses: [founders[0], founders[1]],
      );

      expect(arc.verify(), isFalse,
          reason: 'an induction must complete a full five-movement rite');

      // NOTE the division of labour, and do not mistake it for a bug:
      // `affirmationState` is a fold over what the log CLAIMS, so it reports the
      // member as seasoned. Judging the claim is the authority pass's job, and
      // that pass refuses it. A caller must therefore pair the readout with
      // `verify()` — the same reason P3.1 shipped verify_full alongside the
      // page read.
      expect(arc.affirmationState(polity.did)['seasoned'], 3,
          reason: 'the read model reports the claim, it does not adjudicate it');
    });

    // ---- P3.3 S2 — leaving the roll ------------------------------------
    // Departure and expulsion are deliberately NOT symmetric (charter.md): a
    // bare majority that can expel is a bare majority that can manufacture
    // itself a supermajority one departure at a time. Both bars are counted
    // over SEASONED members, so founding with every member ratifying is the
    // shortest route to a polity that can actually act.

    /// Found a polity of [n] members who ALL ratify, so all n are seasoned
    /// immediately (ratifying is a founding member's induction).
    (EthneKeypair, List<EthneKeypair>, EthneArchive) seasonedPolity(int n) {
      final polity = ffi.generateKeypair();
      final members = List.generate(n, (_) => ffi.generateKeypair());
      final arc = ffi.newArchive();
      arc.foundPolity(
        polityDid: polity.did,
        name: 'Corner Café',
        statement: 'A neighborhood coffee shop.',
        memberDids: members.map((m) => m.did).toList(),
        ratifiers: members,
      );
      return (polity, members, arc);
    }

    test('a member departs self-signed, and the roll shrinks', () {
      final (polity, members, arc) = seasonedPolity(4);
      addTearDown(arc.dispose);
      expect(arc.affirmationState(polity.did)['seasoned'], 4);
      expect(arc.affirmationState(polity.did)['can_contract'], isTrue);

      arc.departMember(
        polityDid: polity.did,
        member: members[3],
        rationale: 'moving away',
      );

      final roll = (arc.charterState(polity.did)['members'] as List).cast<String>();
      expect(roll, hasLength(3));
      expect(roll, isNot(contains(members[3].did)));
      expect(arc.verify(), isTrue, reason: arc.lastError());
    });

    test('a departure that would break self-governance is refused', () {
      final (polity, members, arc) = seasonedPolity(4);
      addTearDown(arc.dispose);
      arc.departMember(polityDid: polity.did, member: members[3]);
      expect(arc.verify(), isTrue, reason: 'three can still self-govern');

      // Three seasoned dropping to two cannot: majority(2)+1 = 3 deciders
      // would be needed out of 2.
      expect(arc.affirmationState(polity.did)['can_contract'], isFalse);
      arc.departMember(polityDid: polity.did, member: members[2]);
      expect(arc.verify(), isFalse,
          reason: 'a departure leaving two members must be refused');
    });

    test('expulsion takes majority plus one, with the target excluded', () {
      // FIVE is the floor for an expulsion, and the arithmetic is worth stating:
      // expel_need = majority(n)+1, and the target may not be a decider. At n=4
      // that needs 4 deciders from the 3 who are eligible — impossible. n=5
      // needs 4 of the 4 others, which is exactly reachable.
      final (polity, members, arc) = seasonedPolity(5);
      addTearDown(arc.dispose);
      final st = arc.affirmationState(polity.did);
      expect(st['seasoned'], 5);
      expect(st['admit_need'], 3);
      expect(st['expel_need'], 4);

      arc.expelMember(
        polityDid: polity.did,
        memberDid: members[4].did,
        rationale: 'persistent harm to the shop',
        deciders: [members[0], members[1], members[2], members[3]],
      );

      final roll = (arc.charterState(polity.did)['members'] as List).cast<String>();
      expect(roll, hasLength(4));
      expect(roll, isNot(contains(members[4].did)));
      expect(arc.verify(), isTrue, reason: arc.lastError());
    });

    test('a bare majority cannot expel', () {
      final (polity, members, arc) = seasonedPolity(5);
      addTearDown(arc.dispose);
      // majority(5) = 3 is enough to ADMIT and deliberately not enough to expel.
      arc.expelMember(
        polityDid: polity.did,
        memberDid: members[4].did,
        deciders: [members[0], members[1], members[2]],
      );
      expect(arc.verify(), isFalse,
          reason: 'expulsion needs majority + 1, not a bare majority');
    });

    test('the target of an expulsion cannot be one of its deciders', () {
      final (polity, members, arc) = seasonedPolity(5);
      addTearDown(arc.dispose);
      arc.expelMember(
        polityDid: polity.did,
        memberDid: members[4].did,
        deciders: [members[0], members[1], members[2], members[4]],
      );
      expect(arc.verify(), isFalse,
          reason: 'the expelled member cannot be among the deciders');
    });

    test('an un-inducted member cannot make up the numbers', () {
      // D29 de-weighting, on the expulsion path: an admitted-but-un-inducted
      // member may be named a decider and may sign — the record still says they
      // acted — and their signature simply does not count toward the threshold.
      final (polity, members, arc) = seasonedPolity(5);
      addTearDown(arc.dispose);
      final hire = ffi.generateKeypair();
      arc.admitMember(
        polityDid: polity.did,
        memberDid: hire.did,
        deciders: [members[0], members[1], members[2]],
        joiner: hire,
      );
      // Roll is 6, seasoned still 5, so the bar has not moved.
      final st = arc.affirmationState(polity.did);
      expect(st['roll'], 6);
      expect(st['seasoned'], 5);
      expect(st['expel_need'], 4);

      // Three seasoned deciders plus the un-inducted hire: four signatures,
      // three of which carry weight.
      arc.expelMember(
        polityDid: polity.did,
        memberDid: members[4].did,
        deciders: [members[0], members[1], members[2], hire],
      );
      expect(arc.verify(), isFalse,
          reason: 'an un-inducted decider adds a signature, not weight');
    });

    // ---- P3.3 S3 — detached two-phase signing (D15) ----------------------
    // Every other write here takes each signer's PRIVATE KEY in its spec, which
    // is only tolerable because one process holds them all. A real roll cannot
    // work that way: a decider's key lives on their own node. These prove the
    // exchange where the PAYLOAD travels and the keys do not.

    test('a roll act is co-signed without any private key changing hands', () {
      final (polity, members, arc) = seasonedPolity(5);
      addTearDown(arc.dispose);
      final hire = ffi.generateKeypair();

      // Phase 1 — the authoring side exports what is to be signed. Note the
      // deciders are named by DID only.
      final ex = arc.pendingChange(
        op: 'admit',
        polityDid: polity.did,
        memberDid: hire.did,
        rationale: 'new barista',
        deciderDids: [members[0].did, members[1].did, members[2].did],
      );
      expect(ex['record'], 'membership');
      expect(ex['cid'], startsWith('b3:'));
      // Admission needs the deciders AND the joiner's consent.
      expect((ex['signers_required'] as List).cast<String>(),
          containsAll([members[0].did, members[1].did, members[2].did, hire.did]));
      expect((ex['signers_required'] as List), hasLength(4));

      // Phase 2 — each signer signs the exported bytes in their own process,
      // with only their own key.
      final bytes = ex['bytes'] as String;
      final sigs = <({String did, String sig})>[
        for (final k in [members[0], members[1], members[2], hire])
          (did: k.did, sig: ffi.signDetached(priv: k.priv, bytesHex: bytes)),
      ];

      // Phase 3 — the authoring side reassembles and appends.
      arc.assembleSigned(
        payload: ex['payload'] as Map<String, dynamic>,
        signatures: sigs,
      );

      final roll = (arc.charterState(polity.did)['members'] as List).cast<String>();
      expect(roll, hasLength(6));
      expect(roll, contains(hire.did));
      expect(arc.verify(), isTrue, reason: arc.lastError());
    });

    test('the description says what is actually being asked', () {
      // Not decoration: a seam that asks a human to sign opaque bytes has
      // taught them to sign anything. An expulsion's description must say that
      // it is done TO somebody and that the bar is higher.
      final (polity, members, arc) = seasonedPolity(5);
      addTearDown(arc.dispose);
      final ex = arc.pendingChange(
        op: 'expel',
        polityDid: polity.did,
        memberDid: members[4].did,
        rationale: 'persistent harm to the shop',
        deciderDids: [
          members[0].did, members[1].did, members[2].did, members[3].did,
        ],
      );
      final d = ex['description'] as String;
      expect(d, contains('EXPEL'));
      expect(d, contains(members[4].did), reason: 'name who it happens to');
      expect(d, contains('majority PLUS ONE'), reason: 'state the bar');
      expect(d, contains('persistent harm to the shop'),
          reason: 'show the stated reason');
      expect(d, contains('4 decider(s)'), reason: 'show who else is deciding');
      // And the expelled member is not asked to sign their own expulsion.
      expect((ex['signers_required'] as List), hasLength(4));
      expect((ex['signers_required'] as List), isNot(contains(members[4].did)));
    });

    test('a tampered payload will not assemble', () {
      final (polity, members, arc) = seasonedPolity(5);
      addTearDown(arc.dispose);
      final hire = ffi.generateKeypair();
      final ex = arc.pendingChange(
        op: 'admit',
        polityDid: polity.did,
        memberDid: hire.did,
        rationale: 'as agreed',
        deciderDids: [members[0].did, members[1].did, members[2].did],
      );
      final sigs = <({String did, String sig})>[
        for (final k in [members[0], members[1], members[2], hire])
          (
            did: k.did,
            sig: ffi.signDetached(priv: k.priv, bytesHex: ex['bytes'] as String)
          ),
      ];

      // Someone edits the record between signing and appending.
      final tampered =
          Map<String, dynamic>.from(ex['payload'] as Map<String, dynamic>);
      tampered['rationale'] = 'not what anyone signed';

      expect(
        () => arc.assembleSigned(payload: tampered, signatures: sigs),
        throwsA(isA<EthneException>()),
        reason: 'signatures are checked against the payload, not taken on trust',
      );
    });

    test('a signature from the wrong key will not assemble', () {
      final (polity, members, arc) = seasonedPolity(5);
      addTearDown(arc.dispose);
      final hire = ffi.generateKeypair();
      final impostor = ffi.generateKeypair();
      final ex = arc.pendingChange(
        op: 'admit',
        polityDid: polity.did,
        memberDid: hire.did,
        deciderDids: [members[0].did, members[1].did, members[2].did],
      );
      final bytes = ex['bytes'] as String;
      // Claims members[2]'s DID, signs with somebody else's key.
      final sigs = <({String did, String sig})>[
        (did: members[0].did, sig: ffi.signDetached(priv: members[0].priv, bytesHex: bytes)),
        (did: members[1].did, sig: ffi.signDetached(priv: members[1].priv, bytesHex: bytes)),
        (did: members[2].did, sig: ffi.signDetached(priv: impostor.priv, bytesHex: bytes)),
        (did: hire.did, sig: ffi.signDetached(priv: hire.priv, bytesHex: bytes)),
      ];
      expect(
        () => arc.assembleSigned(
            payload: ex['payload'] as Map<String, dynamic>, signatures: sigs),
        throwsA(isA<EthneException>()),
        reason: 'a did:key embeds its public key, so this is caught with no registry',
      );
    });

    test('assembling checks the signatures, not the bar', () {
      // The division of labour again: assemble proves each signature is real;
      // whether enough of the right people signed is the authority pass's job.
      final (polity, members, arc) = seasonedPolity(5);
      addTearDown(arc.dispose);
      final hire = ffi.generateKeypair();
      final ex = arc.pendingChange(
        op: 'admit',
        polityDid: polity.did,
        memberDid: hire.did,
        deciderDids: [members[0].did], // one decider, below majority(5) = 3
      );
      final bytes = ex['bytes'] as String;
      final sigs = <({String did, String sig})>[
        (did: members[0].did, sig: ffi.signDetached(priv: members[0].priv, bytesHex: bytes)),
        (did: hire.did, sig: ffi.signDetached(priv: hire.priv, bytesHex: bytes)),
      ];

      // Assembles fine — every signature is genuine.
      arc.assembleSigned(
          payload: ex['payload'] as Map<String, dynamic>, signatures: sigs);
      // And is refused by the pass that actually counts.
      expect(arc.verify(), isFalse,
          reason: 'one decider does not make a majority of five');
    });

    // ---- P3.3 S4 — guardianship: who a machine answers to ----------------
    // A derived member is a machine on the roll; its guardian is the human who
    // answers for it. An edge that is CLAIMED must carry what the substrate
    // showed or say outright that nothing did (D15), and the grade turns on who
    // looked: an observation taken from inside the roll is real evidence and
    // still does not ground the edge, because a polity may not vouch for its own
    // ground. Both halves are tested, because only showing the flattering one is
    // how the UI would come to lie.

    test('a machine is designated, and the edge shows what backs it', () {
      final (polity, members, arc) = seasonedPolity(4);
      addTearDown(arc.dispose);
      final machine = members[3];
      final owner = ffi.generateKeypair(); // the guardian: off the roll
      final monitor = ffi.generateKeypair(); // whoever looked: also off the roll

      final ob = arc.observe(
        polityDid: polity.did,
        observer: monitor,
        readings: [
          (
            member: machine.did,
            reputation: 0.9,
            guardian: owner.did,
            attestedAt: 1700000000,
          ),
        ],
      );
      expect(ob['off_roll'], isTrue,
          reason: 'a monitor outside the roll can ground the edge');

      arc.designateDerived(
        polityDid: polity.did,
        memberDid: machine.did,
        guardian: owner,
        deciders: [members[0], members[1], members[2]],
        evidenceCid: ob['cid'] as String,
        rationale: 'the espresso machine answers to the owner',
      );
      expect(arc.verify(), isTrue);

      final st = arc.guardianState(polity.did);
      expect(st['derived'], 1);
      expect(st['machine_majority'], isFalse, reason: '1 of 4 is not a majority');
      final edge = (st['edges'] as List).single as Map<String, dynamic>;
      expect(edge['member'], machine.did);
      expect(edge['guardian'], owner.did);
      expect(edge['guarded'], isTrue);
      expect(edge['backed'], isTrue);
      expect(edge['evidence'], 'observed');
      expect(edge['observer'], monitor.did);
      // The attendance stamp is carried through as a stamp, never reduced here
      // to a freshness verdict — that judgment belongs to whoever displays it.
      expect(edge['attested_at'], 1700000000);
    });

    test('an observation from inside the roll does not ground the edge', () {
      final (polity, members, arc) = seasonedPolity(4);
      addTearDown(arc.dispose);
      final machine = members[3];
      final owner = ffi.generateKeypair();

      // members[0] is ON the roll. The observation is genuine and the charter
      // accepts it; what it cannot do is grade the edge as backed.
      final ob = arc.observe(
        polityDid: polity.did,
        observer: members[0],
        readings: [
          (member: machine.did, reputation: 0.9, guardian: owner.did, attestedAt: null),
        ],
      );
      expect(ob['off_roll'], isFalse);

      arc.designateDerived(
        polityDid: polity.did,
        memberDid: machine.did,
        guardian: owner,
        deciders: [members[0], members[1], members[2]],
        evidenceCid: ob['cid'] as String,
      );
      expect(arc.verify(), isTrue,
          reason: 'an on-roll observation is still valid evidence');

      final edge =
          (arc.guardianState(polity.did)['edges'] as List).single as Map<String, dynamic>;
      expect(edge['evidence'], 'observed');
      expect(edge['backed'], isFalse);
      expect(edge['reason'], contains('own ground'),
          reason: 'the UI has to be able to say WHY it is not backed');
    });

    test('a claimed edge with no evidence is refused; an override must say why', () {
      final (polity, members, arc) = seasonedPolity(4);
      addTearDown(arc.dispose);
      final owner = ffi.generateKeypair();

      // An unexplained override is refused at the seam, before anything is signed.
      expect(
        () => arc.designateDerived(
          polityDid: polity.did,
          memberDid: members[3].did,
          guardian: owner,
          deciders: [members[0], members[1], members[2]],
          unbackedReason: '   ',
        ),
        throwsA(isA<EthneException>()),
      );

      // Claiming an edge with nothing at all appends, and fails the pass that
      // actually counts — the check lives in the core because an emitter-side
      // guard is walked around by a hand-built record.
      arc.designateDerived(
        polityDid: polity.did,
        memberDid: members[3].did,
        guardian: owner,
        deciders: [members[0], members[1], members[2]],
      );
      expect(arc.verify(), isFalse);

      // A stated reason is accepted, and surfaces verbatim.
      final (polity2, members2, arc2) = seasonedPolity(4);
      addTearDown(arc2.dispose);
      arc2.designateDerived(
        polityDid: polity2.did,
        memberDid: members2[3].did,
        guardian: owner,
        deciders: [members2[0], members2[1], members2[2]],
        unbackedReason: 'no monitor was reachable at the counter',
      );
      expect(arc2.verify(), isTrue);
      final edge =
          (arc2.guardianState(polity2.did)['edges'] as List).single as Map<String, dynamic>;
      expect(edge['evidence'], 'unbacked');
      expect(edge['backed'], isFalse);
      expect(edge['reason'], 'no monitor was reachable at the counter');
    });

    test('nothing guards itself, and a machine cannot guard a machine', () {
      final (polity, members, arc) = seasonedPolity(4);
      addTearDown(arc.dispose);
      final deciders = [members[0], members[1], members[2]];

      arc.designateDerived(
        polityDid: polity.did,
        memberDid: members[3].did,
        guardian: members[3], // itself
        deciders: deciders,
        unbackedReason: 'self-guarding attempt',
      );
      expect(arc.verify(), isFalse, reason: 'a member cannot be its own guardian');

      final (polity2, members2, arc2) = seasonedPolity(4);
      addTearDown(arc2.dispose);
      final owner = ffi.generateKeypair();
      for (final m in [members2[2], members2[3]]) {
        arc2.designateDerived(
          polityDid: polity2.did,
          memberDid: m.did,
          guardian: owner,
          deciders: [members2[0], members2[1], members2[2]],
          unbackedReason: 'bench check',
        );
      }
      expect(arc2.verify(), isTrue, reason: 'two guarded machines are fine');
      arc2.rotateGuardian(
        polityDid: polity2.did,
        memberDid: members2[3].did,
        guardian: members2[2], // already a derived member
        deciders: [members2[0], members2[1], members2[2]],
        unbackedReason: 'machine-guards-machine attempt',
      );
      expect(arc2.verify(), isFalse);
    });

    test('a guardian is rotated, then steps away, and the machine stays derived', () {
      final (polity, members, arc) = seasonedPolity(4);
      addTearDown(arc.dispose);
      final machine = members[3];
      final deciders = [members[0], members[1], members[2]];
      final first = ffi.generateKeypair();
      final second = ffi.generateKeypair();

      arc.designateDerived(
        polityDid: polity.did,
        memberDid: machine.did,
        guardian: first,
        deciders: deciders,
        unbackedReason: 'first operator, bench check',
      );
      arc.rotateGuardian(
        polityDid: polity.did,
        memberDid: machine.did,
        guardian: second,
        deciders: deciders,
        unbackedReason: 'shift handover',
      );
      expect(arc.verify(), isTrue);
      expect(
        ((arc.guardianState(polity.did)['edges'] as List).single
            as Map<String, dynamic>)['guardian'],
        second.did,
      );

      // A release is the guardian's own act OR the roll's, never both, and it
      // carries no evidence: it claims the edge is gone.
      expect(
        () => arc.releaseGuardian(
          polityDid: polity.did,
          memberDid: machine.did,
          guardian: second,
          deciders: deciders,
        ),
        throwsA(isA<EthneException>()),
      );

      arc.releaseGuardian(
        polityDid: polity.did,
        memberDid: machine.did,
        guardian: second,
        rationale: 'stepping back from the counter',
      );
      expect(arc.verify(), isTrue);

      final st = arc.guardianState(polity.did);
      final edge = (st['edges'] as List).single as Map<String, dynamic>;
      expect(edge['guardian'], isNull);
      expect(edge['guarded'], isFalse);
      expect(edge['evidence'], 'none');
      // Released, not un-designated: a machine answering to nobody is an honest
      // state, and the read model names it rather than quietly dropping it.
      expect(st['derived'], 1);
      expect(st['unguarded'], [machine.did]);
    });

    test('a guardian change is co-signed without any private key changing hands', () {
      final (polity, members, arc) = seasonedPolity(4);
      addTearDown(arc.dispose);
      final machine = members[3];
      final owner = ffi.generateKeypair();
      final monitor = ffi.generateKeypair();
      final ob = arc.observe(
        polityDid: polity.did,
        observer: monitor,
        readings: [
          (member: machine.did, reputation: 0.9, guardian: owner.did, attestedAt: null),
        ],
      );

      // Phase one, on the authoring node: DIDs only, no keys.
      final ex = arc.pendingChange(
        record: 'guardian',
        op: 'designate',
        polityDid: polity.did,
        memberDid: machine.did,
        guardianDid: owner.did,
        deciderDids: [members[0].did, members[1].did, members[2].did],
        evidenceCid: ob['cid'] as String,
        rationale: 'the owner takes it on',
      );
      expect(ex['record'], 'guardian');
      // The guardian's consent is required BEYOND the majority, and the caller
      // is told so before anybody is asked to sign.
      expect(ex['signers_required'],
          [members[0].did, members[1].did, members[2].did, owner.did]);
      expect(ex['description'] as String, contains(owner.did));

      // Phase two: each signer signs in their own process, holding only bytes.
      final bytes = ex['bytes'] as String;
      final sigs = <({String did, String sig})>[
        for (final k in [members[0], members[1], members[2], owner])
          (did: k.did, sig: ffi.signDetached(priv: k.priv, bytesHex: bytes)),
      ];

      // Phase three: assemble over the VERBATIM payload and append.
      arc.assembleSigned(
        record: 'guardian',
        payload: ex['payload'] as Map<String, dynamic>,
        signatures: sigs,
      );
      expect(arc.verify(), isTrue);
      final edge =
          (arc.guardianState(polity.did)['edges'] as List).single as Map<String, dynamic>;
      expect(edge['guardian'], owner.did);
      expect(edge['backed'], isTrue);
    });

    test('a release exchange resolves the outgoing guardian from the log', () {
      final (polity, members, arc) = seasonedPolity(4);
      addTearDown(arc.dispose);
      final machine = members[3];
      final owner = ffi.generateKeypair();
      arc.designateDerived(
        polityDid: polity.did,
        memberDid: machine.did,
        guardian: owner,
        deciders: [members[0], members[1], members[2]],
        unbackedReason: 'bench check',
      );

      // The caller does not assert who the outgoing guardian is: asserting it
      // wrongly would only be found out after signatures had been collected.
      final ex = arc.pendingChange(
        record: 'guardian',
        op: 'release',
        polityDid: polity.did,
        memberDid: machine.did,
      );
      expect(ex['signers_required'], [owner.did]);

      // And a member who was never designated has no edge to release.
      expect(
        () => arc.pendingChange(
          record: 'guardian',
          op: 'release',
          polityDid: polity.did,
          memberDid: members[0].did,
        ),
        throwsA(isA<EthneException>()),
      );
    });

    test('a sub-majority founding fails verification (governance gate)', () {
      final polity = ffi.generateKeypair();
      final founders = List.generate(3, (_) => ffi.generateKeypair());
      final arc = ffi.newArchive();
      addTearDown(arc.dispose);
      // Only ONE ratifier for a 3-member roll — below majority(3)=2.
      arc.foundPolity(
        polityDid: polity.did,
        name: 'Under-ratified LLC',
        statement: 'Founded by too few.',
        memberDids: founders.map((f) => f.did).toList(),
        ratifiers: [founders[0]],
      );
      expect(arc.verify(), isFalse,
          reason: 'a sub-majority founding must fail the authority pass');
    });
  });
}
