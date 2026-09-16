// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Widget test for the nested-circles view (Phase 2, §3.4). The PeerService is
// constructed but never started; peers are injected via ingestEvents.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/circles_view.dart';

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

AtRawEvent _connectionEvent(List<int> uuid, int state) => AtRawEvent(
      kind: agoraEventConnectionState,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      connectionState: state,
    );

void main() {
  testWidgets('groups peers into circles with size-vs-target badges',
      (tester) async {
    final connected = List<int>.filled(16, 0x11);
    final seen = List<int>.filled(16, 0x22);
    final svc = PeerService();
    svc.ingestEvents([
      _peerEvent(connected),
      _connectionEvent(connected, 3), // connected, tier 0 => Acquaintance
      _peerEvent(seen), // unconnected => Recognition
    ]);

    await tester.pumpWidget(MaterialApp(home: CirclesPage(service: svc)));

    // The inner Dunbar layers are labelled, and the connected peer lands in
    // Acquaintance (tier 0) with a "count / target" badge.
    expect(find.text('Support clique'), findsOneWidget);
    expect(find.text('Active network'), findsOneWidget);
    expect(find.text('Acquaintance'), findsOneWidget);
    expect(find.text('1 / 500'), findsOneWidget); // Acquaintance: 1 of 500

    // Recognition is the outermost (lazy, off-screen) layer — scroll to it and
    // confirm the unconnected peer landed there.
    await tester.scrollUntilVisible(find.text('Recognition'), 300);
    expect(find.text('Recognition'), findsOneWidget);
    expect(find.text('1 / 1500'), findsOneWidget); // Recognition: 1 of 1500
  });
}
