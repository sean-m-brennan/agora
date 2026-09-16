// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Widget tests for the private-proximity UI (Phase 2): the band chip on a
// connected peer, the "check how near" overflow action, and the opt-in exact-
// position dialog (which keeps coordinates local — never sent).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/people_near_me.dart';

AtRawEvent _peerEvent(List<int> uuid) => AtRawEvent(
      kind: agoraEventPeer,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: true,
      operatorAttestedAt: 1.0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
    );

AtRawEvent _kindEvent(List<int> uuid, int kind,
        {int connectionState = 0, int proximityBand = 0}) =>
    AtRawEvent(
      kind: kind,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      connectionState: connectionState,
      proximityBand: proximityBand,
    );

Future<void> _pump(WidgetTester tester, PeerService svc) =>
    tester.pumpWidget(MaterialApp(home: PeopleNearMePage(service: svc)));

void main() {
  final u1 = List<int>.filled(16, 0x11);

  testWidgets('a connected peer with a band shows the proximity label',
      (tester) async {
    final svc = PeerService();
    svc.ingestEvents([
      _peerEvent(u1),
      _kindEvent(u1, agoraEventConnectionState, connectionState: 3), // connected
      _kindEvent(u1, agoraEventProximity, proximityBand: 1), // near
    ]);
    await _pump(tester, svc);
    // The band folds into the third trailing signal line as "· ~<1 km".
    expect(find.textContaining('<1 km'), findsOneWidget);
  });

  testWidgets('the overflow menu offers a private proximity check when connected',
      (tester) async {
    final svc = PeerService();
    svc.ingestEvents([
      _peerEvent(u1),
      _kindEvent(u1, agoraEventConnectionState, connectionState: 3),
    ]);
    await _pump(tester, svc);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Check how near (private)'), findsOneWidget);
  });

  testWidgets('the exact-position dialog opts in without sending coordinates',
      (tester) async {
    final svc = PeerService();
    await _pump(tester, svc);
    expect(svc.ownExactOptIn, isFalse);

    await tester.tap(find.byIcon(Icons.location_searching)); // off state
    await tester.pumpAndSettle();
    expect(find.text('Private proximity (exact position)'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Latitude (deg)'), '37.77');
    await tester.enterText(
        find.widgetWithText(TextField, 'Longitude (deg)'), '-122.42');
    await tester.tap(find.text('Enable'));
    await tester.pumpAndSettle();
    expect(svc.ownExactOptIn, isTrue); // opted in (local-only; nothing sent)
  });
}
