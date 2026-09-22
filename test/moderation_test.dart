// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Moderation, the app's half (Phase 4 P4.1): the report model and its store,
// how a block and a community ceiling reach the tier the app ranks by, the feed
// seam that hides a blocked author, and PeerService's four verbs. Pure Dart,
// driven through ingestEvents and a recording ModerationVerbs — no shim.
//
// Most of what is pinned here is the ABSENCE of an effect: a blocked peer's
// post not shown, their DM not threaded, their tie not warmed, the report not
// sent twice. Each such test has a positive twin in the same run, so a change
// that simply stopped doing the thing altogether cannot pass.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/model/business_post.dart';
import 'package:agora/src/model/feed_entry.dart';
import 'package:agora/src/model/feed_store.dart';
import 'package:agora/src/model/moderation.dart';
import 'package:agora/src/model/moderation_store.dart';
import 'package:agora/src/model/post.dart';
import 'package:agora/src/model/tie_strength.dart';
import 'package:agora/src/node/moderation_verbs.dart';
import 'package:agora/src/node/peer_stream.dart';

/// Records every verb, in order, and answers with [rc].
class RecordingVerbs implements ModerationVerbs {
  RecordingVerbs({this.rc = 0});
  int rc;
  final List<String> calls = [];

  String _h(List<int> u) => u.first.toRadixString(16);

  @override
  int block(List<int> peerUuid) {
    calls.add('block:${_h(peerUuid)}');
    return rc;
  }

  @override
  int unblock(List<int> peerUuid) {
    calls.add('unblock:${_h(peerUuid)}');
    return rc;
  }

  @override
  int report(List<int> peerUuid) {
    calls.add('report:${_h(peerUuid)}');
    return rc;
  }

  @override
  int peerStanding(List<int> peerUuid,
      {required String standing,
      required double ceiling,
      required String reason}) {
    calls.add('standing:${_h(peerUuid)}:$standing:$ceiling');
    return rc;
  }

  @override
  int requestCosign(List<List<int>> peerUuids,
      {required String record,
      required String op,
      required String polityDid,
      required String cid,
      required String bytes}) {
    calls.add('ask:${peerUuids.map(_h).join(',')}:$op:$cid');
    return rc;
  }
}

AtRawEvent _ev(int kind, List<int> uuid,
        {bool blocked = false,
        double repScore = 0,
        bool repRated = false,
        int repTier = agoraTierUnknown,
        double repCeiling = agoraNoCeiling,
        int connectionState = 0,
        String postId = '',
        String postBody = '',
        double postTs = 0,
        int dmSeq = 0,
        String dmText = '',
        String reactionPostId = ''}) =>
    AtRawEvent(
      kind: kind,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: repScore,
      repRated: repRated,
      rttMs: 0,
      connectionState: connectionState,
      postId: postId,
      postSeq: 1,
      postTs: postTs,
      postBody: postBody,
      dmSeq: dmSeq,
      dmTs: 1,
      dmText: dmText,
      reactionPostId: reactionPostId,
      blocked: blocked,
      repTier: repTier,
      repCeiling: repCeiling,
    );

double _now() => DateTime.now().millisecondsSinceEpoch / 1000.0;

Post _post(List<int> author, String id, {bool outgoing = false}) => Post(
      authorUuid: author,
      postId: id,
      seq: 1,
      ts: _now(),
      requiredTier: 0,
      body: 'b$id',
      outgoing: outgoing,
    );

void main() {
  final ada = List<int>.filled(16, 0xad);
  final bob = List<int>.filled(16, 0xb0);
  final carol = List<int>.filled(16, 0xca);
  String hex(List<int> u) =>
      u.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  // --- the report model ----------------------------------------------------

  group('ReportReason', () {
    test('codes are frozen and unique', () {
      // Changing one relabels every report already on disk.
      expect(ReportReason.values.map((r) => r.code).toList(), [1, 2, 3, 4, 5]);
    });

    test('an unknown code (a newer build wrote it) reads as other', () {
      expect(ReportReason.fromCode(99), ReportReason.other);
      expect(ReportReason.fromCode(2), ReportReason.spam);
    });
  });

  group('ModerationState', () {
    test('one report per peer per UTC day, advisory', () {
      final st = ModerationState();
      const day = 20000 * 86400.0;
      expect(st.canReport('p', day + 10), isTrue);
      st.recordReport('p', ReportReason.spam, day + 10);
      expect(st.reportsLeftToday('p', day + 20), 0);
      expect(st.canReport('p', day + 86399), isFalse);
      // The cap is per peer, and it rolls over on the core's day boundary.
      expect(st.canReport('q', day + 20), isTrue);
      expect(st.canReport('p', day + 86400), isTrue);
    });

    test('keeps only the last report about each peer', () {
      final st = ModerationState();
      st.recordReport('p', ReportReason.spam, 1);
      st.recordReport('p', ReportReason.harassment, 2);
      expect(st.lastReportOf('p')!.reason, ReportReason.harassment);
      expect(st.reports.length, 1);
    });

    test('round-trips through JSON and drops malformed entries', () {
      final st = ModerationState()
        ..recordReport('p', ReportReason.deception, 1234.5);
      final back = ModerationState.fromJson({
        ...st.toJson(),
        'reports': {
          ...(st.toJson()['reports'] as Map),
          'bad': {'at': 'yesterday', 'reason': 1},
          'worse': 7,
        },
      });
      expect(back.reports.keys, ['p']);
      expect(back.lastReportOf('p')!.at, 1234.5);
      expect(back.lastReportOf('p')!.reason, ReportReason.deception);
    });

    test('tolerates a missing reports key', () {
      expect(ModerationState.fromJson({'version': 9}).reports, isEmpty);
    });
  });

  group('ModerationStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('agora-mod-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('save then load restores the reports', () async {
      final f = File('${dir.path}/etc/at/agora.moderation.json');
      final s = ModerationStore(f)
        ..state.recordReport('p', ReportReason.unsafe, 42);
      await s.save();
      final back = await ModerationStore(f).load();
      expect(back.state.lastReportOf('p')!.reason, ReportReason.unsafe);
    });

    test('a missing or corrupt file is an empty state, never a throw',
        () async {
      final missing =
          await ModerationStore(File('${dir.path}/nope.json')).load();
      expect(missing.state.reports, isEmpty);
      final f = File('${dir.path}/bad.json')..writeAsStringSync('{not json');
      expect((await ModerationStore(f).load()).state.reports, isEmpty);
    });
  });

  // --- the tier the app ranks by -------------------------------------------

  group('trustTier composition', () {
    test('falls back to the score until the core sends a tier', () {
      final p = AgoraPeer(uuid: ada)
        ..applyEvent(
            _ev(agoraEventReputation, ada, repScore: 0.9, repRated: true));
      expect(p.reputationTier, isNull);
      expect(trustTier(p), 4);
    });

    test('the core tier wins — a ceiling is not a function of the score', () {
      // Score says tier 4; the core applied a community ceiling and used 0.
      final p = AgoraPeer(uuid: ada)
        ..applyEvent(_ev(agoraEventReputation, ada,
            repScore: 0.9, repRated: true, repTier: 0, repCeiling: 0.2));
      expect(trustTier(p), 0);
      expect(p.isStandingBounded, isTrue);
      expect(p.standingCeiling, closeTo(0.2, 1e-9));
    });

    test('a block reads tier 0 whatever was earned, and lifts cleanly', () {
      final p = AgoraPeer(uuid: ada)
        ..applyEvent(_ev(agoraEventReputation, ada,
            repScore: 0.9, repRated: true, repTier: 4))
        ..applyEvent(_ev(agoraEventPeer, ada, blocked: true));
      expect(p.blocked, isTrue);
      expect(trustTier(p), 0);
      p.applyEvent(_ev(agoraEventPeer, ada));
      expect(trustTier(p), 4);
    });

    test('no ceiling unless the reputation event says so', () {
      final p = AgoraPeer(uuid: ada)
        ..applyEvent(_ev(agoraEventReputation, ada, repTier: 2));
      expect(p.isStandingBounded, isFalse);
    });
  });

  // --- the feed seam -------------------------------------------------------

  group('rankFeed hides a blocked author', () {
    List<FeedEntry> rank(List<Post> posts, Set<String> hidden) => rankFeed(
          posts: posts,
          businessPosts: const <BusinessPost>[],
          strengthOfAuthor: (_) => 0.5,
          standingOfBusiness: (_) => 0.5,
          nameOfBusiness: (_) => '',
          recency: (_) => 1.0,
          isHiddenAuthor: (u) => hidden.contains(hex(u)),
        );

    test('omits the blocked author and keeps everyone else', () {
      final out = rank([_post(ada, 'a1'), _post(bob, 'b1')], {hex(ada)});
      expect(out.map((e) => e.id), ['b1']);
    });

    test('never hides your own words', () {
      final out = rank([_post(ada, 'mine', outgoing: true)], {hex(ada)});
      expect(out.map((e) => e.id), ['mine']);
    });

    test('with no predicate nothing is hidden', () {
      final out = rankFeed(
        posts: [_post(ada, 'a1')],
        businessPosts: const <BusinessPost>[],
        strengthOfAuthor: (_) => 0.5,
        standingOfBusiness: (_) => 0.5,
        nameOfBusiness: (_) => '',
        recency: (_) => 1.0,
      );
      expect(out, hasLength(1));
    });
  });

  test('FeedStore.ranked applies the same predicate, and keeps the post', () {
    final store = FeedStore()
      ..add(_post(ada, 'a1'))
      ..add(_post(bob, 'b1'));
    final shown = store.ranked(
        strengthOfAuthor: (_) => 0.5,
        nowEpochSeconds: _now(),
        isHiddenAuthor: (u) => hex(u) == hex(ada));
    expect(shown.map((p) => p.postId), ['b1']);
    expect(store.length, 2); // hidden, not deleted
  });

  // --- PeerService ---------------------------------------------------------

  group('PeerService moderation', () {
    late RecordingVerbs verbs;
    late PeerService svc;
    setUp(() {
      verbs = RecordingVerbs();
      svc = PeerService(moderationVerbs: verbs);
      svc.ingestEvents([
        _ev(agoraEventPeer, ada),
        _ev(agoraEventPeer, bob),
      ]);
    });

    AgoraPeer peer(List<int> u) =>
        svc.peers.firstWhere((p) => hex(p.uuid) == hex(u));

    test('block and unblock go to the core; the flag comes BACK from it', () {
      expect(svc.blockPeer(peer(ada)), 0);
      // Not optimistic: nothing is shown blocked until the core says so.
      expect(peer(ada).blocked, isFalse);
      svc.ingestEvents([_ev(agoraEventPeer, ada, blocked: true)]);
      expect(peer(ada).blocked, isTrue);
      expect(svc.unblockPeer(peer(ada)), 0);
      expect(verbs.calls, ['block:ad', 'unblock:ad']);
    });

    test('blocked peers stay in the roster and sort last', () {
      svc.ingestEvents([
        _ev(agoraEventReputation, ada,
            repScore: 0.95, repRated: true, repTier: 4),
        _ev(agoraEventPeer, ada, blocked: true),
      ]);
      expect(svc.peers.map((p) => hex(p.uuid)), [hex(bob), hex(ada)]);
      expect(svc.blockedPeers.map((p) => hex(p.uuid)), [hex(ada)]);
    });

    test('a report sends the peer and nothing else, then remembers why', () {
      expect(svc.canReport(peer(ada)), isTrue);
      expect(svc.reportPeer(peer(ada), ReportReason.harassment), 0);
      expect(verbs.calls, ['report:ad']);
      expect(svc.moderation.lastReportOf(hex(ada))!.reason,
          ReportReason.harassment);
      expect(svc.canReport(peer(ada)), isFalse);
    });

    test('a second report today is refused BEFORE anything is sent', () {
      svc.reportPeer(peer(ada), ReportReason.spam);
      expect(svc.reportPeer(peer(ada), ReportReason.spam), reportRefusedCap);
      expect(verbs.calls, ['report:ad']);
      // Per target: bob is still reportable.
      expect(svc.reportPeer(peer(bob), ReportReason.spam), 0);
    });

    test('a report the core never queued is not remembered', () {
      verbs.rc = -2;
      expect(svc.reportPeer(peer(ada), ReportReason.spam), -2);
      expect(svc.moderation.lastReportOf(hex(ada)), isNull);
      expect(svc.canReport(peer(ada)), isTrue);
    });

    test('Both is two verbs, report first', () {
      expect(svc.blockAndReport(peer(ada), ReportReason.unsafe), 0);
      expect(verbs.calls, ['report:ad', 'block:ad']);
    });

    test('Both still blocks when the report is capped, and says so', () {
      svc.reportPeer(peer(ada), ReportReason.unsafe);
      verbs.calls.clear();
      expect(
          svc.blockAndReport(peer(ada), ReportReason.unsafe), reportRefusedCap);
      expect(verbs.calls, ['block:ad']);
    });

    test('expulsion is a ceiling from ethne; reinstatement lifts it', () {
      svc.applyExpulsionStanding(peer(ada));
      svc.liftExpulsionStanding(peer(ada));
      expect(verbs.calls, [
        'standing:ad:capped:$ethneExpelCeiling',
        'standing:ad:proved:-1.0',
      ]);
    });

    test('a community-bounded peer is listed as such', () {
      svc.ingestEvents(
          [_ev(agoraEventReputation, bob, repTier: 0, repCeiling: 0.2)]);
      expect(svc.standingBoundedPeers.map((p) => hex(p.uuid)), [hex(bob)]);
    });

    test('the live feed hides a blocked author and counts it honestly', () {
      final now = _now();
      svc.ingestEvents([
        _ev(agoraEventPost, ada, postId: 'a' * 64, postBody: 'x', postTs: now),
        _ev(agoraEventPost, bob, postId: 'b' * 64, postBody: 'y', postTs: now),
      ]);
      expect(svc.feed, hasLength(2));
      svc.ingestEvents([_ev(agoraEventPeer, ada, blocked: true)]);
      expect(svc.feed.map((e) => e.id), ['b' * 64]);
      expect(svc.feedHiddenByBlock, 1);
      // Unblock restores it at once — from the store, not a redelivery.
      svc.ingestEvents([_ev(agoraEventPeer, ada)]);
      expect(svc.feed, hasLength(2));
      expect(svc.feedHiddenByBlock, 0);
    });

    test('a DM from a blocked peer is dropped and counted', () {
      svc.ingestEvents([_ev(agoraEventPeer, ada, blocked: true)]);
      svc.ingestEvents([
        _ev(agoraEventDm, ada, dmSeq: 1, dmText: 'hi'),
        _ev(agoraEventDm, bob, dmSeq: 1, dmText: 'hi'),
      ]);
      expect(svc.messagesFor(peer(ada)), isEmpty);
      expect(svc.messagesFor(peer(bob)), hasLength(1));
      expect(svc.dmsDroppedFromBlocked, 1);
      expect(svc.hasUnread(peer(ada)), isFalse);
    });

    test('a blocked peer\'s reaction is not tallied', () {
      svc.ingestEvents([_ev(agoraEventPeer, ada, blocked: true)]);
      svc.ingestEvents([
        _ev(agoraEventReaction, ada, reactionPostId: 'p1'),
        _ev(agoraEventReaction, bob, reactionPostId: 'p1'),
      ]);
      expect(svc.reactionsFor('p1'), 1);
    });

    test('nothing warms a blocked tie', () {
      // Reacting to a blocked author's post is the path where _tend is the only
      // guard: nothing upstream drops it.
      svc.ingestEvents([_ev(agoraEventPeer, ada, blocked: true)]);
      svc.reactToPost(_post(ada, 'a' * 64));
      svc.reactToPost(_post(bob, 'b' * 64));
      expect(peer(ada).lastInteractionAt, 0);
      expect(peer(bob).lastInteractionAt, greaterThan(0));
    });

    test('a blocked peer spends no attention budget', () {
      svc.ingestEvents([
        _ev(agoraEventReputation, ada, repScore: 0.95, repRated: true),
        _ev(agoraEventReputation, bob, repScore: 0.95, repRated: true),
        _ev(agoraEventConnectionState, ada, connectionState: 3),
        _ev(agoraEventConnectionState, bob, connectionState: 3),
      ]);
      final before = svc.budgetLedger.ties.map((t) => hex(t.peer.uuid)).toSet();
      expect(before, containsAll([hex(ada), hex(bob)]));
      svc.ingestEvents([_ev(agoraEventPeer, ada, blocked: true)]);
      final after = svc.budgetLedger.ties.map((t) => hex(t.peer.uuid)).toSet();
      expect(after, {hex(bob)});
    });
  });

  test('without a channel every verb reports -1, not success', () {
    final svc = PeerService();
    final p = AgoraPeer(uuid: carol);
    expect(svc.blockPeer(p), -1);
    expect(svc.unblockPeer(p), -1);
    expect(svc.reportPeer(p, ReportReason.other), -1);
    expect(svc.applyExpulsionStanding(p), -1);
    expect(svc.liftExpulsionStanding(p), -1);
  });
}
