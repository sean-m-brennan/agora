// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The address-book pages (SOCIAL_APP_PLAN Phase 4, multi-device): what a person
// sees, from decoded events alone (no node, so verbs return -1 and nothing is
// sent).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/model/address_book.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/contact_detail.dart';
import 'package:agora/src/ui/contacts_page.dart';
import 'package:agora/src/ui/my_devices_page.dart';

List<int> _u(int n) => [for (var i = 0; i < 15; i++) 0, n];

AtRawEvent _ev(int kind, int fcKind,
        {int who = 0,
        int device = 0,
        String ref = '',
        String petname = '',
        bool verified = false,
        String safety = '',
        String passphrase = '',
        String path = ''}) =>
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
      fcKind: fcKind,
      fcRef: ref,
      fcPetname: petname,
      fcVerified: verified,
      fcSafetyNumber: safety,
      fcDeviceUuid: device == 0 ? const [] : _u(device),
      backupPassphrase: passphrase,
      backupPath: path,
    );

void main() {
  testWidgets('contacts show once, with their devices and verification', (tester) async {
    final s = PeerService();
    s.ingestEvents([
      _ev(agoraEventContact, atFcContact, who: 1, ref: refBookList, petname: 'Ann', verified: true),
      _ev(agoraEventContact, atFcDeviceLinked, who: 1, device: 2, ref: refBookList, verified: true),
      _ev(agoraEventContact, atFcContact, who: 3, ref: refBookList, petname: 'Bob'),
      _ev(agoraEventContact, atFcContactsDone, ref: refBookList),
    ]);
    await tester.pumpWidget(MaterialApp(home: ContactsPage(service: s)));
    expect(find.text('Ann'), findsOneWidget);
    expect(find.text('verified · 2 devices · added in person'), findsOneWidget);
    expect(find.text('not verified yet · added in person'), findsOneWidget);
  });

  testWidgets('an unverified contact offers the safety number and both ways to verify',
      (tester) async {
    final s = PeerService();
    s.ingestEvents([
      _ev(agoraEventContact, atFcContact, who: 3, petname: 'Bob'),
      _ev(agoraEventContact, atFcSafetyNumber, who: 3, petname: 'Bob', safety: '11111 22222'),
    ]);
    await tester.pumpWidget(MaterialApp(
        home: ContactDetailPage(service: s, contact: s.book.contacts.values.single)));
    expect(find.text('11111 22222'), findsOneWidget);
    expect(find.byKey(const Key('contact-verify-confirm')), findsOneWidget);
    expect(find.byKey(const Key('contact-verify-typed')), findsOneWidget);
  });

  testWidgets('with no device cert, pairing is off and the command is shown', (tester) async {
    final s = PeerService();
    await tester.pumpWidget(MaterialApp(home: MyDevicesPage(service: s)));
    expect(find.text('No device cert'), findsOneWidget);
    expect(find.byKey(const Key('devices-cert-command')), findsOneWidget);
    final pair = tester.widget<ListTile>(find.byKey(const Key('devices-pair')));
    expect(pair.enabled, isFalse);
  });

  testWidgets('a generated backup passphrase is shown', (tester) async {
    final s = PeerService();
    s.ingestEvents([
      _ev(agoraEventBackup, atBackupWritten, passphrase: 'ABCD EFGH IJKL', path: '/r/b.atbk'),
    ]);
    await tester.pumpWidget(MaterialApp(home: MyDevicesPage(service: s)));
    await tester.scrollUntilVisible(
        find.byKey(const Key('backup-passphrase-shown')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('ABCD EFGH IJKL'), findsOneWidget);
  });
}
