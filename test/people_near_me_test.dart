// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Widget tests for the People-near-me page: profile rendering in a peer tile and
// the opt-in profile editor. The PeerService is constructed but never started
// (no daemon, no native shim); peers are injected via ingestEvents.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/people_near_me.dart';

AtRawEvent _peerEvent(List<int> uuid, {int rank = 0}) => AtRawEvent(
      kind: agoraEventPeer,
      uuid: uuid,
      signingPubkey: const [],
      rank: rank,
      operatorBound: true,
      operatorAttestedAt: 1.0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
    );

AtRawEvent _profileEvent(List<int> uuid, String json) => AtRawEvent(
      kind: agoraEventProfile,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      profileJson: json,
    );

Future<void> _pump(WidgetTester tester, PeerService svc) =>
    tester.pumpWidget(MaterialApp(home: PeopleNearMePage(service: svc)));

void main() {
  final u1 = List<int>.filled(16, 0x11);

  testWidgets('empty roster shows the placeholder', (tester) async {
    await _pump(tester, PeerService());
    expect(find.text('No peers observed yet…'), findsOneWidget);
  });

  testWidgets('a peer with a profile renders its name and bio', (tester) async {
    final svc = PeerService();
    svc.ingestEvents([
      _peerEvent(u1, rank: 2),
      _profileEvent(u1, '{"display_name":"Ada","handle":"ada","bio":"math"}'),
    ]);
    await _pump(tester, svc);

    expect(find.text('Ada'), findsOneWidget); // title = display name
    expect(find.text('math'), findsOneWidget); // bio in the subtitle
    expect(find.textContaining('@ada'), findsOneWidget); // handle + id line
  });

  testWidgets('a peer without a profile shows its short id', (tester) async {
    final svc = PeerService();
    svc.ingestEvents([_peerEvent(u1, rank: 1)]);
    await _pump(tester, svc);
    expect(find.text('111111111111'), findsOneWidget); // shortId fallback
  });

  testWidgets('the profile editor opts in via the badge action', (tester) async {
    final svc = PeerService();
    await _pump(tester, svc);

    // Not sharing yet -> the outlined badge icon.
    expect(svc.ownProfile, isNull);
    await tester.tap(find.byIcon(Icons.badge_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Your profile'), findsOneWidget); // dialog title
    await tester.enterText(
        find.widgetWithText(TextField, 'Display name'), 'Grace');
    await tester.enterText(find.widgetWithText(TextField, 'Handle'), 'grace_h');
    await tester.enterText(
        find.widgetWithText(TextField, 'Links'), 'https://a, https://b');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(svc.ownProfile, isNotNull);
    expect(svc.ownProfile!['display_name'], 'Grace');
    expect(svc.ownProfile!['handle'], 'grace_h');
    expect(svc.ownProfile!['links'], ['https://a', 'https://b']);
  });

  testWidgets('the editor can opt back out via Stop sharing', (tester) async {
    final svc = PeerService();
    svc.setOwnProfile({'display_name': 'Ada'});
    await _pump(tester, svc);

    await tester.tap(find.byIcon(Icons.badge)); // filled = sharing
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop sharing'));
    await tester.pumpAndSettle();

    expect(svc.ownProfile, isNull);
  });

  testWidgets('a peer tile offers a local Block action (Increment 8)',
      (tester) async {
    final svc = PeerService();
    svc.ingestEvents([_peerEvent(u1, rank: 1)]);
    await _pump(tester, svc);

    // Open the per-peer overflow menu and choose Block.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Block'), findsOneWidget);
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    // No channel in a pure-Dart test -> a SnackBar reports the outcome, no throw.
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('an inbound connection request shows accept/decline buttons',
      (tester) async {
    // Reproduces exactly what a peer's daemon emits when it receives our connect
    // request: a connection event carrying pending_in (state 2). Bob's GUI must
    // render the accept/decline affordance for it.
    final svc = PeerService();
    svc.ingestEvents([
      _peerEvent(u1, rank: 1),
      AtRawEvent(
        kind: agoraEventConnectionRequest,
        uuid: u1,
        signingPubkey: const [],
        rank: 0,
        operatorBound: false,
        operatorAttestedAt: 0,
        operatorPubkey: const [],
        repScore: 0,
        repRated: false,
        rttMs: 0,
        connectionState: 2, // pending_in
      ),
    ]);
    await _pump(tester, svc);
    expect(find.byIcon(Icons.check_circle), findsOneWidget); // Accept
    expect(find.byIcon(Icons.cancel_outlined), findsOneWidget); // Decline
  });

  testWidgets('tapping Connect with no channel surfaces feedback', (tester) async {
    final svc = PeerService();
    svc.ingestEvents([_peerEvent(u1, rank: 1)]);
    await _pump(tester, svc);

    // A fresh peer shows the "Connect" (person_add) affordance.
    final connect = find.byIcon(Icons.person_add_alt_1);
    expect(connect, findsOneWidget);
    await tester.tap(connect);
    await tester.pump();
    // No daemon channel -> the request cannot be sent, so the user is told
    // (previously it failed silently). No optimistic pending on a failed send.
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
