// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Widget tests for the staff-roll page (Phase 3 P3.3). The PeerService is
// constructed but never started; the roll, this node's staff identity and the
// local description derivation are all injected, so the honest states are
// exercised with no charter log and no cdylib.
//
// What these tests are really pinning is that a state the charter ALLOWS is not
// drawn as a fault, and that a claim which does NOT hold up is.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/ethne_bindings.dart';
import 'package:agora/src/model/member_roll.dart';
import 'package:agora/src/model/staff_identity.dart';
import 'package:agora/src/model/staff_roster.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/businesses_near_me.dart';
import 'package:agora/src/ui/staff_roster.dart';

const _now = 1700000000;

StaffIdentity _identity() => StaffIdentity(
      polityDid: 'did:key:zCafe',
      self: EthneKeypair('did:key:zAda', const {}, const {}),
      archive: const {},
    );

StaffRoster _roster({
  int roll = 3,
  int seasoned = 3,
  int admitNeed = 2,
  int expelNeed = 3,
  bool canContract = true,
  bool machineMajority = false,
  bool? verified = true,
  List<Map<String, dynamic>>? members,
  List<Map<String, dynamic>> edges = const [],
  List<String> unguarded = const [],
}) =>
    StaffRoster.from(
      affirmation: {
        'polity_did': 'did:key:zCafe',
        'roll': roll,
        'seasoned': seasoned,
        'admit_need': admitNeed,
        'expel_need': expelNeed,
        'can_contract': canContract,
        'members': members ??
            [
              {'did': 'did:key:zAda', 'inducted': true},
              {'did': 'did:key:zBob', 'inducted': true},
              {'did': 'did:key:zCal', 'inducted': true},
            ],
      },
      guardian: {
        'derived': edges.length,
        'machine_majority': machineMajority,
        'unguarded': unguarded,
        'edges': edges,
      },
      nowEpochSeconds: _now,
      verified: verified,
    );

AtRawEvent _ask({
  String cid = 'b3:aaaa',
  String bytes = 'deadbeef',
  String op = 'admit',
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
      cosignRecord: 'membership',
      cosignOp: op,
      cosignPolity: 'did:key:zCafe',
      cosignCid: cid,
      cosignBytes: bytes,
      cosignTs: 10,
    );

Future<void> _pump(WidgetTester tester, PeerService svc) async {
  // A tall viewport, because the page is a lazy ListView: off-screen tiles are
  // never built, and a find that misses one would report "the UI does not say
  // this" when the truth is "you did not scroll". Reachability is a separate
  // concern from what these tests are about.
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: StaffRosterPage(service: svc)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a node that is staff of no polity says so', (tester) async {
    final svc = PeerService(bundleVerifier: (_) => true);
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    expect(find.byKey(const Key('roster-no-polity')), findsOneWidget);
    expect(find.textContaining('not staff of any polity'), findsOneWidget);
  });

  testWidgets('the roll says what a vote actually costs', (tester) async {
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(),
    );
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    expect(find.text('3 on the roll · 3 inducted'), findsOneWidget);
    expect(find.byKey(const Key('roster-admit-need')), findsOneWidget);
    expect(find.byKey(const Key('roster-expel-need')), findsOneWidget);
  });

  testWidgets('an expulsion that cannot close is called out rather than offered',
      (tester) async {
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(roll: 4, seasoned: 4, expelNeed: 4),
    );
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    expect(find.byKey(const Key('roster-expel-unreachable')), findsOneWidget);
    expect(find.textContaining('may not decide its own removal'), findsOneWidget);
  });

  testWidgets('a polity below the contraction floor is told it cannot shrink',
      (tester) async {
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(canContract: false),
    );
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    expect(find.byKey(const Key('roster-cannot-contract')), findsOneWidget);
  });

  testWidgets('a member on the roll with no deciding weight says so',
      (tester) async {
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(roll: 2, seasoned: 1, members: [
        {'did': 'did:key:zAda', 'inducted': true},
        {'did': 'did:key:zNew', 'inducted': false},
      ]),
    );
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    expect(find.byKey(const Key('member-no-weight')), findsOneWidget);
    expect(find.textContaining('no deciding weight yet'), findsOneWidget);
  });

  testWidgets('an unguarded machine is shown as a state, not as an error',
      (tester) async {
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(
        members: [
          {'did': 'did:key:zBot', 'inducted': true},
        ],
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
    );
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    expect(find.byKey(const Key('member-unguarded')), findsOneWidget);
    expect(find.text('unguarded'), findsOneWidget);
    // Nothing is raised against it. A release clears the edge and keeps the
    // designation; the machine has simply lost its human, which the charter
    // allows and this app therefore does not colour as a fault.
    expect(find.byKey(const Key('member-unbacked')), findsNothing);
  });

  testWidgets('an unbacked edge is shown with its reason, not hidden',
      (tester) async {
    const why = 'the observer is the polity or sits on its roll; '
        'a polity may not vouch for its own ground';
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(
        members: [
          {'did': 'did:key:zBot', 'inducted': true},
        ],
        edges: [
          {
            'member': 'did:key:zBot',
            'guardian': 'did:key:zAda',
            'guarded': true,
            'backed': false,
            'evidence': 'observed',
            'observer': 'did:key:zAda',
            'reason': why,
          },
        ],
      ),
    );
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    expect(find.byKey(const Key('member-unbacked')), findsOneWidget);
    // Verbatim: the log's own account of why, not this app's paraphrase.
    expect(find.textContaining('may not vouch for its own ground'),
        findsOneWidget);
    // And the edge itself is still reported as existing.
    expect(find.byKey(const Key('member-guardian')), findsOneWidget);
  });

  testWidgets('a stale stamp warns without escalating', (tester) async {
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(
        members: [
          {'did': 'did:key:zBot', 'inducted': true},
        ],
        edges: [
          {
            'member': 'did:key:zBot',
            'guardian': 'did:key:zAda',
            'guarded': true,
            'backed': true,
            'evidence': 'observed',
            'attested_at': _now - 5 * 86400,
          },
        ],
      ),
    );
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    final chip = find.byKey(const Key('member-stale-attested'));
    expect(chip, findsOneWidget);
    expect(find.textContaining('a stamp, not a verdict'), findsOneWidget);

    // It must not be drawn in the error role. This is the whole rule: a node
    // bound to a guardian with nobody at the keyboard for a week is normal.
    final scheme = Theme.of(tester.element(chip)).colorScheme;
    final box = tester.widget<Container>(chip);
    final colour = (box.decoration as BoxDecoration).color;
    expect(colour, scheme.surfaceContainerHigh);
    expect(colour, isNot(scheme.errorContainer));
  });

  testWidgets('a machine that never reported attendance is not called stale',
      (tester) async {
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(
        members: [
          {'did': 'did:key:zBot', 'inducted': true},
        ],
        edges: [
          {
            'member': 'did:key:zBot',
            'guardian': 'did:key:zAda',
            'guarded': true,
            'backed': true,
            'evidence': 'observed',
          },
        ],
      ),
    );
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    expect(find.byKey(const Key('member-no-stamp')), findsOneWidget);
    expect(find.byKey(const Key('member-stale-attested')), findsNothing);
    expect(find.text('no attendance stamp'), findsOneWidget);
  });

  testWidgets('a log that does not verify is said out loud', (tester) async {
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(verified: false),
    );
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    expect(find.textContaining('DOES NOT VERIFY'), findsOneWidget);
    // And the fold is still shown, because the two are different questions.
    expect(find.text('3 on the roll · 3 inducted'), findsOneWidget);
  });

  testWidgets('publishing a shorter roll removing nobody is stated, not smoothed',
      (tester) async {
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(),
    );
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    expect(find.byKey(const Key('roster-union-note')), findsOneWidget);
    expect(find.textContaining('removes nobody'), findsOneWidget);
  });

  group('co-signing', () {
    testWidgets('the wording is derived here, never taken from the asker',
        (tester) async {
      final svc = PeerService(
        bundleVerifier: (_) => true,
        staffIdentity: _identity(),
        staffRoster: _roster(),
        // The bytes actually say EXPEL…
        cosignDescriber: (record, bytes) => {
          'cid': 'b3:aaaa',
          'op': 'expel',
          'description': 'EXPEL did:key:zBob from did:key:zCafe',
        },
      );
      addTearDown(svc.dispose);
      // …while the ask claims to be an admission.
      svc.ingestEvents([_ask(op: 'admit')]);
      await _pump(tester, svc);

      expect(find.byKey(const Key('cosign-description')), findsOneWidget);
      expect(find.textContaining('EXPEL did:key:zBob'), findsOneWidget);
      expect(find.textContaining('The asking node sent no wording'),
          findsOneWidget);
    });

    testWidgets('bytes that cannot be read cannot be signed', (tester) async {
      final svc = PeerService(
        bundleVerifier: (_) => true,
        staffIdentity: _identity(),
        staffRoster: _roster(),
        cosignDescriber: (record, bytes) => null,
      );
      addTearDown(svc.dispose);
      svc.ingestEvents([_ask()]);
      await _pump(tester, svc);

      expect(find.byKey(const Key('cosign-unreadable')), findsOneWidget);
      final sign =
          tester.widget<FilledButton>(find.byKey(const Key('cosign-sign')));
      expect(sign.onPressed, isNull, reason: 'nothing here says what you sign');
    });

    testWidgets('an ask naming one act and carrying another cannot be signed',
        (tester) async {
      final svc = PeerService(
        bundleVerifier: (_) => true,
        staffIdentity: _identity(),
        staffRoster: _roster(),
        // The bytes recompute to a different cid than the ask advertised.
        cosignDescriber: (record, bytes) => {
          'cid': 'b3:something-else',
          'description': 'EXPEL did:key:zBob from did:key:zCafe',
        },
      );
      addTearDown(svc.dispose);
      svc.ingestEvents([_ask(cid: 'b3:aaaa')]);
      await _pump(tester, svc);

      expect(find.byKey(const Key('cosign-cid-mismatch')), findsOneWidget);
      final sign =
          tester.widget<FilledButton>(find.byKey(const Key('cosign-sign')));
      expect(sign.onPressed, isNull);
    });

    testWidgets('declining sends nothing and settles the ask', (tester) async {
      final svc = PeerService(
        bundleVerifier: (_) => true,
        staffIdentity: _identity(),
        staffRoster: _roster(),
        cosignDescriber: (record, bytes) =>
            {'cid': 'b3:aaaa', 'description': 'EXPEL did:key:zBob'},
      );
      addTearDown(svc.dispose);
      svc.ingestEvents([_ask()]);
      await _pump(tester, svc);
      expect(svc.pendingCosigns, hasLength(1));

      // The tile sits below the governance card, so bring it into view first:
      // a tap at an off-screen offset lands nowhere and silently proves nothing.
      await tester.ensureVisible(find.byKey(const Key('cosign-decline')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cosign-decline')));
      await tester.pumpAndSettle();

      expect(svc.pendingCosigns, isEmpty);
      expect(find.byKey(const Key('cosign-decline')), findsNothing);

      // And a replay of the same ask does not raise it again.
      svc.ingestEvents([_ask()]);
      await tester.pumpAndSettle();
      expect(svc.pendingCosigns, isEmpty);
    });
  });

  group('the published roll', () {
    PublishedRoll artifact({
      bool publisherProven = true,
      bool? auditedAgainstLog = true,
      int members = 3,
    }) =>
        PublishedRoll(
          rollJson: jsonEncode({
            'payload': {
              'community_did': 'did:key:zCafe',
              'members': List.generate(
                  members, (i) => {'member_did': 'did:key:zM$i'}),
              'as_of': _now,
              'published_at': _now,
            },
            'signatures': [
              {'signer_did': 'did:key:zCafe'}
            ],
          }),
          publisherProven: publisherProven,
          auditedAgainstLog: auditedAgainstLog,
        );

    PeerService svcWith({RollPublisher? publisher}) => PeerService(
          bundleVerifier: (_) => true,
          staffIdentity: _identity(),
          staffRoster: _roster(),
          rollPublisher: publisher,
        );

    testWidgets('a node without the polity root key is told so, and offered no '
        'button', (tester) async {
      final svc = svcWith();
      addTearDown(svc.dispose);
      await _pump(tester, svc);

      expect(svc.canPublishRoll, isFalse);
      expect(find.byKey(const Key('roll-no-root-key')), findsOneWidget);
      expect(find.byKey(const Key('roll-publish')), findsNothing);
      expect(find.textContaining('does not hold it'), findsOneWidget);
    });

    testWidgets('the limits on publishing are stated before you publish, not '
        'after', (tester) async {
      final svc = svcWith();
      addTearDown(svc.dispose);
      await _pump(tester, svc);

      expect(find.byKey(const Key('roll-union-is-one-way')), findsOneWidget);
      expect(find.byKey(const Key('roll-nothing-compels')), findsOneWidget);
      expect(find.byKey(const Key('roll-not-delivered')), findsOneWidget);
      // And nothing claims the button sends anything.
      expect(find.textContaining('sends nothing'), findsOneWidget);
    });

    testWidgets('publishing shows the artifact and keeps the two answers apart',
        (tester) async {
      final svc = svcWith(publisher: () => artifact());
      addTearDown(svc.dispose);
      await _pump(tester, svc);

      expect(svc.canPublishRoll, isTrue);
      await tester.ensureVisible(find.byKey(const Key('roll-publish')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('roll-publish')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('roll-artifact')), findsOneWidget);
      expect(find.textContaining('Names 3 members'), findsOneWidget);
      // Two separate verdicts, because they are two different questions.
      expect(find.byKey(const Key('roll-publisher-proven')), findsOneWidget);
      expect(find.byKey(const Key('roll-audited')), findsOneWidget);
      expect(find.textContaining('never whether what they say is true'),
          findsOneWidget);
      expect(find.textContaining('A compact cannot check this'), findsOneWidget);
      expect(find.byKey(const Key('roll-self-excluded')), findsOneWidget);
    });

    testWidgets('a roll that does not prove its publisher is the thing drawn in '
        'the error role', (tester) async {
      final svc = svcWith(publisher: () => artifact(publisherProven: false));
      addTearDown(svc.dispose);
      await _pump(tester, svc);
      await tester.ensureVisible(find.byKey(const Key('roll-publish')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('roll-publish')));
      await tester.pumpAndSettle();

      final line = find.byKey(const Key('roll-publisher-proven'));
      expect(find.textContaining('establishes nothing'), findsOneWidget);

      final scheme = Theme.of(tester.element(line)).colorScheme;
      final text = tester.widget<Text>(
          find.descendant(of: line, matching: find.byType(Text)));
      expect(text.style?.color, scheme.error);

      // …and the neutral limits beside it are NOT escalated with it.
      final notDelivered = find.byKey(const Key('roll-not-delivered'));
      expect(tester.widget<Text>(notDelivered).style?.color,
          isNot(scheme.error));
    });

    testWidgets('a roll nobody audited says so rather than implying it passed',
        (tester) async {
      final svc = svcWith(publisher: () => artifact(auditedAgainstLog: null));
      addTearDown(svc.dispose);
      await _pump(tester, svc);
      await tester.ensureVisible(find.byKey(const Key('roll-publish')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('roll-publish')));
      await tester.pumpAndSettle();

      expect(find.textContaining('was not checked against a charter log'),
          findsOneWidget);
      // Not checked is not the same as failed, so it is not error-coloured.
      final line = find.byKey(const Key('roll-audited'));
      final scheme = Theme.of(tester.element(line)).colorScheme;
      final text = tester.widget<Text>(
          find.descendant(of: line, matching: find.byType(Text)));
      expect(text.style?.color, isNot(scheme.error));
    });
  });

  testWidgets('the staff roll is reachable from the businesses page',
      (tester) async {
    final svc = PeerService(
      bundleVerifier: (_) => true,
      staffIdentity: _identity(),
      staffRoster: _roster(),
    );
    addTearDown(svc.dispose);
    await tester
        .pumpWidget(MaterialApp(home: BusinessesNearMePage(service: svc)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-staff-roster')));
    await tester.pumpAndSettle();

    expect(find.byType(StaffRosterPage), findsOneWidget);
    expect(find.text('Staff roll'), findsOneWidget);
  });
}
