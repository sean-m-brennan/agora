// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Widget tests for the moderation surface (Phase 4 P4.1): the roster's menu,
// the block confirmation, the report sheet, the blocked list, and the feed's
// hidden-by-block banner. The PeerService is never started; peers arrive via
// ingestEvents and verbs land in a recording ModerationVerbs.
//
// The load-bearing assertions are about honesty: a block is not shown until
// the core reports it, a cancelled dialog sends nothing, a capped report says
// so, and a hidden post is counted rather than silently missing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/node/moderation_verbs.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/blocked_list.dart';
import 'package:agora/src/ui/feed_view.dart';
import 'package:agora/src/ui/people_near_me.dart';

class _Verbs implements ModerationVerbs {
  final List<String> calls = [];

  int _record(String verb) {
    calls.add(verb);
    return 0;
  }

  @override
  int block(List<int> u) => _record('block');
  @override
  int unblock(List<int> u) => _record('unblock');
  @override
  int report(List<int> u) => _record('report');
  @override
  int peerStanding(List<int> u,
          {required String standing,
          required double ceiling,
          required String reason}) =>
      _record('standing:$standing');
  @override
  int requestCosign(List<List<int>> u,
          {required String record,
          required String op,
          required String polityDid,
          required String cid,
          required String bytes}) =>
      _record('ask:$op');
}

AtRawEvent _ev(int kind, List<int> uuid,
        {bool blocked = false,
        int repTier = agoraTierUnknown,
        double repCeiling = agoraNoCeiling,
        String postId = '',
        double postTs = 0}) =>
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
      postId: postId,
      postSeq: 1,
      postTs: postTs,
      postBody: 'hello',
      blocked: blocked,
      repTier: repTier,
      repCeiling: repCeiling,
    );

void main() {
  final ada = List<int>.filled(16, 0xad);
  const adaId = 'adadadadadad';
  late _Verbs verbs;
  late PeerService svc;

  setUp(() {
    verbs = _Verbs();
    svc = PeerService(moderationVerbs: verbs);
    svc.ingestEvents([_ev(agoraEventPeer, ada)]);
  });

  Future<void> pumpRoster(WidgetTester tester) =>
      tester.pumpWidget(MaterialApp(home: PeopleNearMePage(service: svc)));

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  group('block', () {
    testWidgets('asks first, and a cancel sends nothing', (tester) async {
      await pumpRoster(tester);
      await openMenu(tester);
      await tester.tap(find.text('Block…'));
      await tester.pumpAndSettle();
      expect(find.textContaining('they are not told'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(verbs.calls, isEmpty);
    });

    testWidgets('confirming sends the block', (tester) async {
      await pumpRoster(tester);
      await openMenu(tester);
      await tester.tap(find.text('Block…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-block')));
      await tester.pumpAndSettle();
      expect(verbs.calls, ['block']);
      expect(find.text('Peer blocked (local)'), findsOneWidget);
    });

    testWidgets(
        'a blocked peer is labelled, loses DM/connect, and can be '
        'unblocked', (tester) async {
      await pumpRoster(tester);
      expect(find.byKey(const Key('flag-$adaId')), findsNothing);
      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);

      svc.ingestEvents([_ev(agoraEventPeer, ada, blocked: true)]);
      await tester.pump();
      expect(find.text('blocked'), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);

      await openMenu(tester);
      expect(find.text('Block…'), findsNothing);
      await tester.tap(find.text('Unblock'));
      await tester.pumpAndSettle();
      expect(verbs.calls, ['unblock']);
    });

    testWidgets('a community-bounded peer says so on the tile', (tester) async {
      svc.ingestEvents(
          [_ev(agoraEventReputation, ada, repTier: 0, repCeiling: 0.2)]);
      await pumpRoster(tester);
      expect(find.text('limited by community'), findsOneWidget);
    });
  });

  group('report', () {
    Future<void> openSheet(WidgetTester tester) async {
      await pumpRoster(tester);
      await openMenu(tester);
      await tester.tap(find.text('Report…'));
      await tester.pumpAndSettle();
    }

    testWidgets('says what a report is, and needs a reason', (tester) async {
      await openSheet(tester);
      final statement =
          tester.widget<Text>(find.byKey(const Key('report-statement'))).data!;
      expect(statement, contains('stays on this device'));
      expect(statement, contains('does not block'));
      final send =
          tester.widget<FilledButton>(find.byKey(const Key('report-send')));
      expect(send.onPressed, isNull);
    });

    testWidgets('sends a report, then the menu says it went', (tester) async {
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('reason-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('report-send')));
      await tester.pumpAndSettle();
      expect(verbs.calls, ['report']);
      expect(find.text('Reported'), findsOneWidget);

      await openMenu(tester);
      expect(find.text('Reported today'), findsOneWidget);
      expect(find.text('Report…'), findsNothing);
    });

    testWidgets('report and block sends both, report first', (tester) async {
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('reason-4')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('report-and-block')));
      await tester.pumpAndSettle();
      expect(verbs.calls, ['report', 'block']);
      expect(find.text('Reported and blocked'), findsOneWidget);
    });

    testWidgets('cancel sends nothing', (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(verbs.calls, isEmpty);
    });
  });

  group('blocked list', () {
    Future<void> pumpList(WidgetTester tester) =>
        tester.pumpWidget(MaterialApp(home: BlockedListPage(service: svc)));

    testWidgets('empty states for both sections', (tester) async {
      await pumpList(tester);
      expect(find.text('You have not blocked anyone.'), findsOneWidget);
      expect(
          find.textContaining('No one you can see is limited'), findsOneWidget);
    });

    testWidgets('lists a block with an unblock button', (tester) async {
      svc.ingestEvents([_ev(agoraEventPeer, ada, blocked: true)]);
      await pumpList(tester);
      expect(find.byKey(const Key('blocked-$adaId')), findsOneWidget);
      await tester.tap(find.byKey(const Key('unblock-$adaId')));
      await tester.pumpAndSettle();
      expect(verbs.calls, ['unblock']);
      expect(find.textContaining('Unblocked'), findsOneWidget);
    });

    testWidgets('a community bound is its own section, with the ceiling',
        (tester) async {
      svc.ingestEvents(
          [_ev(agoraEventReputation, ada, repTier: 0, repCeiling: 0.2)]);
      await pumpList(tester);
      expect(find.byKey(const Key('bounded-$adaId')), findsOneWidget);
      expect(find.textContaining('capped at 0.20'), findsOneWidget);
      // Not the operator's to lift from here: no unblock on it.
      expect(find.byKey(const Key('unblock-$adaId')), findsNothing);
    });

    testWidgets('reachable from the roster app bar', (tester) async {
      await pumpRoster(tester);
      await tester.tap(find.byKey(const Key('open-blocked')));
      await tester.pumpAndSettle();
      expect(find.byType(BlockedListPage), findsOneWidget);
    });
  });

  testWidgets('the feed counts posts hidden by a block', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    svc.ingestEvents([
      _ev(agoraEventPost, ada, postId: 'a' * 64, postTs: now),
      _ev(agoraEventPeer, ada, blocked: true),
    ]);
    await tester.pumpWidget(MaterialApp(home: FeedPage(service: svc)));
    expect(find.byKey(const Key('hidden-by-block')), findsOneWidget);
    expect(find.text('1 post hidden from someone you blocked'), findsOneWidget);
    expect(find.text('hello'), findsNothing);
  });
}
