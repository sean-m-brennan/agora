// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Unit tests for the staff-roll fold and the co-signature exchange store
// (Phase 3 P3.3). Both models take plain maps and an injected describer, so
// every state below is reached with no cdylib and no charter log.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/model/cosign_exchanges.dart';
import 'package:agora/src/model/member_roll.dart';
import 'package:agora/src/model/staff_roster.dart';

const _now = 1700000000;

Map<String, dynamic> _affirmation({
  String polity = 'did:key:zCafe',
  int roll = 3,
  int seasoned = 3,
  int admitNeed = 2,
  int expelNeed = 3,
  bool canContract = true,
  List<Map<String, dynamic>>? members,
}) =>
    {
      'polity_did': polity,
      'roll': roll,
      'seasoned': seasoned,
      'admit_need': admitNeed,
      'expel_need': expelNeed,
      'can_contract': canContract,
      'members': members ??
          [
            {'did': 'did:key:zAda', 'inducted': true, 'last_affirmed_at': _now},
            {'did': 'did:key:zBob', 'inducted': true, 'last_affirmed_at': _now},
            {'did': 'did:key:zCal', 'inducted': true, 'last_affirmed_at': _now},
          ],
    };

Map<String, dynamic> _guardian({
  int derived = 0,
  bool machineMajority = false,
  List<String> unguarded = const [],
  List<Map<String, dynamic>> edges = const [],
}) =>
    {
      'roll': 3,
      'derived': derived,
      'machine_majority': machineMajority,
      'unguarded': unguarded,
      'edges': edges,
    };

void main() {
  group('StaffRoster — what a vote costs', () {
    test('an admitted member carries no deciding weight until inducted', () {
      final r = StaffRoster.from(
        affirmation: _affirmation(roll: 4, seasoned: 3, members: [
          {'did': 'did:key:zAda', 'inducted': true},
          {'did': 'did:key:zBob', 'inducted': true},
          {'did': 'did:key:zCal', 'inducted': true},
          {'did': 'did:key:zNew', 'inducted': false},
        ]),
        guardian: _guardian(),
        nowEpochSeconds: _now,
      );
      expect(r.roll, 4);
      expect(r.seasoned, 3);
      expect(r.uninducted.map((m) => m.did), ['did:key:zNew']);
    });

    test('an expulsion needing more deciders than are eligible cannot close',
        () {
      // Four seasoned: majority+1 is four, and the target may not decide its
      // own removal, so four deciders must come from three eligible.
      final r = StaffRoster.from(
        affirmation: _affirmation(roll: 4, seasoned: 4, expelNeed: 4),
        guardian: _guardian(),
        nowEpochSeconds: _now,
      );
      expect(r.expelEligible, 3);
      expect(r.expelReachable, isFalse);
    });

    test('at five seasoned an expulsion is exactly reachable', () {
      final r = StaffRoster.from(
        affirmation: _affirmation(roll: 5, seasoned: 5, expelNeed: 4),
        guardian: _guardian(),
        nowEpochSeconds: _now,
      );
      expect(r.expelEligible, 4);
      expect(r.expelReachable, isTrue);
    });

    test('the contraction floor is carried through as the log reported it', () {
      final r = StaffRoster.from(
        affirmation: _affirmation(canContract: false),
        guardian: _guardian(),
        nowEpochSeconds: _now,
      );
      expect(r.canContract, isFalse);
    });

    test('the verify result is carried beside the fold, not merged into it',
        () {
      final unchecked = StaffRoster.from(
        affirmation: _affirmation(),
        guardian: _guardian(),
        nowEpochSeconds: _now,
      );
      expect(unchecked.verified, isNull);

      final failed = StaffRoster.from(
        affirmation: _affirmation(),
        guardian: _guardian(),
        nowEpochSeconds: _now,
        verified: false,
      );
      // The fold still reports what the log claims; only `verified` says the
      // claims do not hold.
      expect(failed.seasoned, 3);
      expect(failed.verified, isFalse);
    });

    test('the roll keeps the order the log gave it', () {
      final r = StaffRoster.from(
        affirmation: _affirmation(members: [
          {'did': 'did:key:zZed', 'inducted': true},
          {'did': 'did:key:zAda', 'inducted': false},
          {'did': 'did:key:zMid', 'inducted': true},
        ]),
        guardian: _guardian(),
        nowEpochSeconds: _now,
      );
      expect(r.members.map((m) => m.did),
          ['did:key:zZed', 'did:key:zAda', 'did:key:zMid']);
    });
  });

  group('StaffRoster — guardianship', () {
    test('an unguarded machine is a state, not a missing value', () {
      final r = StaffRoster.from(
        affirmation: _affirmation(members: [
          {'did': 'did:key:zAda', 'inducted': true},
          {'did': 'did:key:zBot', 'inducted': true},
        ]),
        guardian: _guardian(
          derived: 1,
          unguarded: ['did:key:zBot'],
          edges: [
            {
              'member': 'did:key:zBot',
              'guardian': null,
              'guarded': false,
              'backed': false,
              'evidence': 'none',
            },
          ],
        ),
        nowEpochSeconds: _now,
      );
      final bot = r.members.firstWhere((m) => m.did == 'did:key:zBot');
      expect(bot.isMachine, isTrue);
      expect(bot.isUnguardedMachine, isTrue);
      expect(bot.evidence, 'none');
      expect(r.anyUnguardedMachine, isTrue);

      // A human member is not a machine that happens to lack a guardian.
      final ada = r.members.firstWhere((m) => m.did == 'did:key:zAda');
      expect(ada.isMachine, isFalse);
      expect(ada.isUnguardedMachine, isFalse);
    });

    test('a valid edge nobody outside the roll grounded is unbacked, with why',
        () {
      const why = 'the observer is the polity or sits on its roll; '
          'a polity may not vouch for its own ground';
      final r = StaffRoster.from(
        affirmation: _affirmation(members: [
          {'did': 'did:key:zBot', 'inducted': true},
        ]),
        guardian: _guardian(derived: 1, edges: [
          {
            'member': 'did:key:zBot',
            'guardian': 'did:key:zAda',
            'guarded': true,
            'backed': false,
            'evidence': 'observed',
            'observer': 'did:key:zAda',
            'observed_at': _now,
            'reason': why,
          },
        ]),
        nowEpochSeconds: _now,
      );
      final bot = r.members.single;
      expect(bot.guarded, isTrue, reason: 'the edge exists and is valid');
      expect(bot.backed, isFalse, reason: 'it is simply not grounded');
      expect(bot.reason, why);
      expect(r.unbackedEdges.map((m) => m.did), ['did:key:zBot']);
    });

    test('machine majority is counted over the whole roll', () {
      final r = StaffRoster.from(
        affirmation: _affirmation(),
        guardian: _guardian(derived: 2, machineMajority: true),
        nowEpochSeconds: _now,
      );
      expect(r.machineMajority, isTrue);
    });
  });

  group('StaffRoster — the attendance stamp', () {
    StaffRoster rosterWithStamp(Object? attestedAt) => StaffRoster.from(
          affirmation: _affirmation(members: [
            {'did': 'did:key:zBot', 'inducted': true},
          ]),
          guardian: _guardian(derived: 1, edges: [
            {
              'member': 'did:key:zBot',
              'guardian': 'did:key:zAda',
              'guarded': true,
              'backed': true,
              'evidence': 'observed',
              'attested_at': attestedAt,
            },
          ]),
          nowEpochSeconds: _now,
        );

    test('a stamp inside the threshold is not stale', () {
      final m = rosterWithStamp(_now - 3600).members.single;
      expect(m.hasAttendanceStamp, isTrue);
      expect(m.attendanceStale, isFalse);
    });

    test('a stamp aged past the threshold is stale', () {
      final m = rosterWithStamp(_now - 3 * 86400).members.single;
      expect(m.hasAttendanceStamp, isTrue);
      expect(m.attendanceStale, isTrue);
    });

    test('no stamp at all is not a stale stamp', () {
      final m = rosterWithStamp(null).members.single;
      expect(m.hasAttendanceStamp, isFalse);
      // Never reported and long ago are different facts, and only one of them
      // is about the passage of time.
      expect(m.attendanceStale, isFalse);
    });

    test('a stamp of zero reads the same as no stamp at all', () {
      final m = rosterWithStamp(0).members.single;
      expect(m.hasAttendanceStamp, isFalse);
      expect(m.attendanceStale, isFalse);
    });

    test('an aging stamp never touches the guardian edge', () {
      final m = rosterWithStamp(_now - 30 * 86400).members.single;
      expect(m.attendanceStale, isTrue);
      // Bound is durable; attended is live. Staleness of the second says
      // nothing whatever about the first.
      expect(m.guarded, isTrue);
      expect(m.backed, isTrue);
    });
  });

  group('CosignExchanges', () {
    AtRawEvent ask({
      String cid = 'b3:aaaa',
      String bytes = 'deadbeef',
      String op = 'expel',
      String record = 'membership',
      double ts = 100,
      List<int> uuid = const [1, 2, 3],
    }) =>
        AtRawEvent(
          kind: agoraEventCosignRequest,
          uuid: uuid,
          signingPubkey: const [],
          rank: 0,
          operatorBound: false,
          operatorAttestedAt: 0,
          operatorPubkey: const [],
          repScore: 0,
          repRated: false,
          rttMs: 0,
          cosignRecord: record,
          cosignOp: op,
          cosignPolity: 'did:key:zCafe',
          cosignCid: cid,
          cosignBytes: bytes,
          cosignTs: ts,
        );

    CosignExchanges store({CosignDescriber? describer}) => CosignExchanges(
        describeBytes:
            describer ?? (r, b) => {'cid': 'b3:aaaa', 'description': 'EXPEL'});

    test('an ask is held once, however often it is replayed', () {
      final s = store();
      expect(s.addRequest(CosignExchange.fromEvent(ask())), isTrue);
      expect(s.addRequest(CosignExchange.fromEvent(ask())), isFalse);
      expect(s.pendingCount, 1);
    });

    test('different bytes under a held cid are refused, not merged', () {
      final s = store();
      s.addRequest(CosignExchange.fromEvent(ask()));
      expect(
        s.addRequest(CosignExchange.fromEvent(ask(bytes: 'f00d'))),
        isFalse,
      );
      // The bytes a signer was shown are the ones still held.
      expect(s.pending.single.bytes, 'deadbeef');
    });

    test('an ask with no bytes is not something anyone can be asked to sign',
        () {
      final s = store();
      expect(s.addRequest(CosignExchange.fromEvent(ask(bytes: ''))), isFalse);
      expect(s.pendingCount, 0);
    });

    test('a declined ask is not raised again by a replay', () {
      final s = store();
      s.addRequest(CosignExchange.fromEvent(ask()));
      expect(s.settle('b3:aaaa'), isTrue);
      expect(s.pendingCount, 0);
      expect(s.isSettled('b3:aaaa'), isTrue);
      expect(s.addRequest(CosignExchange.fromEvent(ask())), isFalse);
      expect(s.pendingCount, 0);
    });

    test('a signature is counted once per signer', () {
      final s = store();
      const sig = CosignSignature(
          cid: 'b3:aaaa', signerDid: 'did:key:zAda', sig: 'ab', ts: 1);
      expect(s.addSignature(sig), isTrue);
      expect(s.addSignature(sig), isFalse);
      expect(s.signaturesFor('b3:aaaa'), hasLength(1));
    });

    test('bytes that cannot be described yield null, never the asker\'s word',
        () {
      final s = store(describer: (r, b) => null);
      final e = CosignExchange.fromEvent(ask());
      s.addRequest(e);
      expect(s.describe(e), isNull);
    });

    test('a describer that throws is a refusal, not a crash', () {
      final s = store(describer: (r, b) => throw StateError('bad bytes'));
      final e = CosignExchange.fromEvent(ask());
      s.addRequest(e);
      expect(s.describe(e), isNull);
    });

    test('pending is newest first, tie-broken by cid', () {
      final s = store();
      s.addRequest(CosignExchange.fromEvent(ask(cid: 'b3:b', ts: 50)));
      s.addRequest(CosignExchange.fromEvent(ask(cid: 'b3:c', ts: 200)));
      s.addRequest(CosignExchange.fromEvent(ask(cid: 'b3:a', ts: 200)));
      expect(s.pending.map((e) => e.cid), ['b3:a', 'b3:c', 'b3:b']);
    });

    test('the oldest asks are dropped past the cap', () {
      final s = CosignExchanges(
          describeBytes: (r, b) => null, cap: 2);
      for (var i = 0; i < 4; i++) {
        s.addRequest(
            CosignExchange.fromEvent(ask(cid: 'b3:$i', ts: i.toDouble())));
      }
      expect(s.pendingCount, 2);
      expect(s.pending.map((e) => e.cid), ['b3:3', 'b3:2']);
    });
  });

  group('PublishedRoll', () {
    String rollJson({int members = 3, int asOf = _now}) => jsonEncode({
          'payload': {
            'community_did': 'did:key:zCafe',
            'members':
                List.generate(members, (i) => {'member_did': 'did:key:zM$i'}),
            'as_of': asOf,
            'published_at': asOf,
          },
          'signatures': [
            {'signer_did': 'did:key:zCafe'}
          ],
        });

    test('reads the artifact without pretending to verify it', () {
      final r = PublishedRoll(
          rollJson: rollJson(), publisherProven: true, auditedAgainstLog: true);
      expect(r.communityDid, 'did:key:zCafe');
      expect(r.memberCount, 3);
      expect(r.asOf, _now);
    });

    test('an unaudited roll is not a failed one', () {
      final r = PublishedRoll(rollJson: rollJson(), publisherProven: true);
      // Null means nobody asked; it must never read as false.
      expect(r.auditedAgainstLog, isNull);
      expect(r.auditedAgainstLog == false, isFalse);
    });

    test('an artifact it cannot read reports nothing rather than throwing', () {
      const r = PublishedRoll(rollJson: 'not json', publisherProven: false);
      expect(r.communityDid, isNull);
      expect(r.memberCount, 0);
      expect(r.asOf, isNull);
    });
  });
}
