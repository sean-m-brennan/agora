// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Widget tests for the DM thread page (Increment 6): incoming/outgoing messages
// render on the correct side, and the compose field sends. The PeerService is
// constructed but never started (no daemon, no native shim); the thread is
// seeded via ingestEvents / sendDm.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/dm_thread.dart';

AtRawEvent _dmEvent(List<int> uuid, int seq, String text) => AtRawEvent(
      kind: agoraEventDm,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      dmSeq: seq,
      dmTs: 1000,
      dmText: text,
    );

void main() {
  final u1 = List<int>.filled(16, 0x11);

  Future<void> pumpThread(WidgetTester tester, PeerService svc, AgoraPeer peer) {
    return tester.pumpWidget(MaterialApp(
      home: DmThreadPage(peer: peer, service: svc),
    ));
  }

  testWidgets('renders an incoming and an outgoing message', (tester) async {
    final svc = PeerService();
    svc.ingestEvents([_dmEvent(u1, 1, 'hi from peer')]);
    final peer = svc.peers.single;
    svc.sendDm(peer, 'hi back'); // outgoing echo (no channel; still local)

    await pumpThread(tester, svc, peer);
    expect(find.text('hi from peer'), findsOneWidget);
    expect(find.text('hi back'), findsOneWidget);
  });

  testWidgets('empty thread shows a hint', (tester) async {
    final svc = PeerService();
    final peer = AgoraPeer(uuid: u1);
    await pumpThread(tester, svc, peer);
    expect(find.textContaining('No messages yet'), findsOneWidget);
  });

  testWidgets('the compose field sends a message into the thread', (tester) async {
    final svc = PeerService();
    final peer = AgoraPeer(uuid: u1);
    await pumpThread(tester, svc, peer);

    await tester.enterText(find.byType(TextField), 'typed message');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    // It landed in the store as an outgoing message, and renders.
    expect(svc.messagesFor(peer).single.text, 'typed message');
    expect(svc.messagesFor(peer).single.outgoing, isTrue);
    expect(find.text('typed message'), findsOneWidget);
  });

  testWidgets('opening the thread clears the unread flag', (tester) async {
    final svc = PeerService();
    svc.ingestEvents([_dmEvent(u1, 1, 'unread!')]);
    final peer = svc.peers.single;
    expect(svc.hasUnread(peer), isTrue);

    await pumpThread(tester, svc, peer);
    expect(svc.hasUnread(peer), isFalse);
  });
}
