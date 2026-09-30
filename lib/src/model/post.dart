// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Post: one signed feed item (Increment 7). A post is a signed, content-addressed
// feed item distributed by encrypted GROUP MULTICAST and gossip-forwarded a
// bounded number of hops. Incoming posts arrive from the AT core
// (AT_APP_EVENT_POST), which has ALREADY verified the author's Ed25519 signature,
// tier-gated the post against this node's view of the author's tier, and deduped
// it by content id. Outgoing posts are echoed locally at publish time (the core
// does NOT echo them back). The feed is a LIVE STREAM kept in a FeedStore — not
// roster state.

import '../ffi/at_events_bindings.dart';

/// One feed post, incoming or locally echoed.
class Post {
  const Post({
    required this.authorUuid,
    required this.postId,
    required this.seq,
    required this.ts,
    required this.requiredTier,
    required this.body,
    required this.outgoing,
    this.community = '',
    this.labels = const [],
  });

  /// The author's raw 16-byte identity uuid. For an incoming post this is the
  /// SIGNATURE-BOUND author the core verified; for a locally-echoed outgoing post
  /// it is this node's own uuid (or empty when unknown app-side).
  final List<int> authorUuid;

  /// The blake2b content-address (lowercase hex) — the dedup/merge key. For a
  /// locally-echoed outgoing post the core computes the real id (never returned
  /// to the app), so this is a synthetic local key.
  final String postId;

  /// The author's post sequence. 0 for a locally-echoed outgoing post (the core
  /// stamps the real wire seq, which never returns to the app).
  final int seq;

  /// Post time in epoch seconds (the author's clock for incoming; local time for
  /// outgoing).
  final double ts;

  /// The audience floor (0..4) the author addressed this post to.
  final int requiredTier;

  /// The post body.
  final String body;

  /// True if this node published it (echoed locally), false if received.
  final bool outgoing;

  /// The community (polity DID) the post was made in, or '' for none (Phase
  /// 4). Signed with the post; a follower of the community applies its policy.
  final String community;

  /// The author's own labels, signed with the post (Phase 4).
  final List<String> labels;

  /// Author uuid as lowercase hex.
  String get authorHex =>
      authorUuid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Build a Post from a decoded [agoraEventPost] event (an incoming post).
  factory Post.fromEvent(AtRawEvent e) => Post(
        authorUuid: e.uuid,
        postId: e.postId,
        seq: e.postSeq,
        ts: e.postTs,
        requiredTier: e.postRequiredTier,
        body: e.postBody,
        outgoing: false,
        community: e.postCommunity,
        labels: e.postLabels,
      );
}
