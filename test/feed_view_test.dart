// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Widget tests for the feed page (Increment 7): received/echoed posts render,
// and the compose box publishes with the selected audience. The PeerService is
// constructed but never started (no daemon, no native shim); the feed is seeded
// via ingestEvents / publishPost.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/feed_view.dart';

AtRawEvent _postEvent(List<int> author, String id, String body) => AtRawEvent(
      kind: agoraEventPost,
      uuid: author,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      postId: id,
      postSeq: 1,
      postTs: 1000,
      postRequiredTier: 0,
      postBody: body,
    );

void main() {
  final u1 = List<int>.filled(16, 0x11);

  Future<void> pumpFeed(WidgetTester tester, PeerService svc) {
    return tester.pumpWidget(MaterialApp(home: FeedPage(service: svc)));
  }

  testWidgets('renders a received post', (tester) async {
    final svc = PeerService();
    svc.ingestEvents([_postEvent(u1, 'id1', 'hello from the feed')]);
    await pumpFeed(tester, svc);
    expect(find.text('hello from the feed'), findsOneWidget);
  });

  testWidgets('empty feed shows a hint', (tester) async {
    final svc = PeerService();
    await pumpFeed(tester, svc);
    expect(find.textContaining('No posts yet'), findsOneWidget);
  });

  testWidgets('the compose box publishes a post into the feed', (tester) async {
    final svc = PeerService();
    await pumpFeed(tester, svc);

    await tester.enterText(find.byType(TextField), 'a fresh post');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(svc.feed.single.body, 'a fresh post');
    expect(svc.feed.single.outgoing, isTrue);
    expect(find.text('a fresh post'), findsOneWidget);
  });
}
