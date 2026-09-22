// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// FeedStore: the app-side merged feed (Increment 7). Posts arrive from the AT
// core (AT_APP_EVENT_POST) already verified, tier-gated and content-id-deduped;
// the store adds a SECOND, local dedup by postId (a post can reach us over more
// than one gossip path across sessions) and ranks the feed locally by S × recency
// — S being the tie strength to the author (the Inc-4 tie_strength kernel, reused
// via a strength callback) and recency being how fresh the post is. Local ties
// posting recently surface first, exactly like "people near me" surfaces local,
// tended, trusted peers first.
//
// Pure and deterministic given its inputs (the strength callback + a clock), so
// it is unit tested directly without the daemon or FFI.

import 'dart:math' as math;

import 'post.dart';

class FeedStore {
  FeedStore({this.recencyTauSeconds = 86400.0}); // ~1 day, matches the kernel

  /// Decay constant (seconds) for the post-recency term, mirroring the
  /// tie-strength kernel's recency decay shape.
  final double recencyTauSeconds;

  /// Posts keyed by content id (the dedup key). Insertion-ordered.
  final Map<String, Post> _byId = {};

  /// Add [post], deduped by [Post.postId]. Returns true if it was new (stored),
  /// false if already present (a duplicate merge — dropped). An outgoing echo
  /// with an empty/duplicate id is still stored under a synthetic key so a local
  /// publish is always visible.
  bool add(Post post) {
    final id = post.postId.isNotEmpty
        ? post.postId
        : 'local:${post.outgoing ? 'out' : 'in'}:${post.ts}:${post.body.hashCode}';
    if (_byId.containsKey(id)) return false;
    _byId[id] = post.postId.isNotEmpty
        ? post
        : Post(
            authorUuid: post.authorUuid,
            postId: id,
            seq: post.seq,
            ts: post.ts,
            requiredTier: post.requiredTier,
            body: post.body,
            outgoing: post.outgoing,
          );
    return true;
  }

  /// All posts in insertion order (unranked).
  List<Post> get posts => List<Post>.unmodifiable(_byId.values);

  int get length => _byId.length;

  /// True if a post with [postId] is already stored.
  bool contains(String postId) => _byId.containsKey(postId);

  /// The post-recency term in [0,1], decaying as exp(-age/tau) from [ts].
  double recency(double ts, double nowEpochSeconds) {
    if (ts <= 0) return 0.0;
    final age = nowEpochSeconds - ts;
    if (age <= 0) return 1.0;
    return math.exp(-age / recencyTauSeconds);
  }

  /// The feed ranked by S × recency descending. [strengthOfAuthor] returns the
  /// tie strength S ∈ [0,1] to a post's author (PeerService supplies the Inc-4
  /// [tieStrength] kernel here); [nowEpochSeconds] grades post recency. Ties
  /// break by post time (newest first) then a stable id, so the order is
  /// deterministic. An outgoing echo is always shown near the top (its author is
  /// self, S treated as maximal so your own post never sinks).
  ///
  /// [isHiddenAuthor] leaves out posts by an author the operator has blocked
  /// (Phase 4 P4.1) — omitted from the result, NOT removed from the store, so
  /// an unblock restores them at once rather than waiting for a redelivery the
  /// dedup map would refuse anyway.
  ///
  /// TEST-ONLY IN PRACTICE: the live feed is [rankFeed], which merges business
  /// posts in. The predicate is here too so the two cannot disagree about what
  /// a block hides.
  List<Post> ranked({
    required double Function(List<int> authorUuid) strengthOfAuthor,
    required double nowEpochSeconds,
    bool Function(List<int> authorUuid)? isHiddenAuthor,
  }) {
    double score(Post p) {
      final s = p.outgoing ? 1.0 : strengthOfAuthor(p.authorUuid);
      return s * recency(p.ts, nowEpochSeconds);
    }

    final list = _byId.values
        .where((p) =>
            p.outgoing ||
            isHiddenAuthor == null ||
            !isHiddenAuthor(p.authorUuid))
        .toList();
    list.sort((a, b) {
      final byScore = score(b).compareTo(score(a));
      if (byScore != 0) return byScore;
      final byTs = b.ts.compareTo(a.ts);
      if (byTs != 0) return byTs;
      return a.postId.compareTo(b.postId);
    });
    return list;
  }
}
