// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// BusinessPost: one signed post from a business — the polity SPEAKING, where
// its page is what it IS (Phase 3 P3.4). Incoming posts arrive from the AT core
// (AT_APP_EVENT_BUSINESS_POST), which has already verified the SENDER's Ed25519
// signature over the canonical bytes, dropped anything from a polity this node
// holds no page for, and deduped by content id.
//
// WHAT THE CORE COULD NOT CHECK, AND THIS LAYER MUST. The core holds no Ethne.
// It knows these exact bytes arrived unaltered from whoever sent them, and
// nothing whatever about whether that business said them — the peer it came
// from is a CARRIER (a post relays, unlike an ad), and being on a business's
// roll confers no right to speak for it either. The envoy signature sealed
// inside the bundle is the only thing that does, and checking it is this
// layer's job: ethne_business_post_verify_bundle, which needs no charter log.
//
// SO AN UNVERIFIED POST IS NOT THE BUSINESS'S WORD. It is not shown under the
// business's name — it is not shown at all, and counted instead, the same
// stance BusinessDirectory takes toward an unverified page. Rendering
// unauthenticated text beside a shopfront's name is precisely the impersonation
// the envoy signature exists to prevent.

import 'dart:convert';

import '../ffi/at_events_bindings.dart';

/// One business post, incoming or locally echoed.
class BusinessPost {
  const BusinessPost({
    required this.polity,
    required this.postId,
    required this.seq,
    required this.ts,
    required this.hops,
    required this.bundle,
    required this.outgoing,
  });

  /// The business's Ethne DID — the post's true author, and the key into
  /// [BusinessDirectory] for its page and its standing.
  final String polity;

  /// The blake2b content-address (lowercase hex) — the dedup/merge key.
  final String postId;

  /// The business's own post sequence. It ORDERS a business's posts; it does
  /// not version them (a post is never superseded, which is why it is its own
  /// Ethne payload rather than a field on the page).
  final int seq;

  /// Post time in epoch seconds (the sender's clock).
  final double ts;

  /// How far this copy travelled: 0 straight from the business, 1 relayed once.
  /// Display-relevant only as provenance — it says nothing about authority.
  final int hops;

  /// The OPAQUE Ethne `{post,delegation}` artifact. Verify before believing.
  final String bundle;

  /// True if this node published it (echoed locally), false if received.
  final bool outgoing;

  /// Build a BusinessPost from a decoded [agoraEventBusinessPost] event.
  factory BusinessPost.fromEvent(AtRawEvent e) => BusinessPost(
        polity: e.businessPostPolity,
        postId: e.businessPostId,
        seq: e.businessPostSeq,
        ts: e.businessPostTs,
        hops: e.businessPostHops,
        bundle: e.businessPostBundle,
        outgoing: false,
      );

  /// The body text, parsed out of the bundle FOR DISPLAY ONLY.
  ///
  /// This is not verification and is no substitute for it — exactly the stance
  /// [BusinessPage.parse] takes toward a page. Parsing tells you what the bytes
  /// SAY; only [EthneFfi.verifyBusinessPostBundle] tells you whether the
  /// business said it. Callers show this string only after that returned true.
  /// Empty when the bundle is not JSON or carries no post payload.
  String get body => parseBody(bundle);

  /// Parse the `{"post":{"payload":{"body":...}}}` half of an Ethne bundle.
  /// Returns '' when the bundle is not JSON or carries no post payload.
  static String parseBody(String bundleJson) {
    if (bundleJson.isEmpty) return '';
    Object? root;
    try {
      root = jsonDecode(bundleJson);
    } on FormatException {
      return '';
    }
    if (root is! Map) return '';
    final post = root['post'];
    if (post is! Map) return '';
    final payload = post['payload'];
    if (payload is! Map) return '';
    final body = payload['body'];
    return body is String ? body : '';
  }
}

/// The app-side store of business posts: verified ones kept, unverified ones
/// COUNTED and dropped.
///
/// The count is not bookkeeping for its own sake. A reader who is told nothing
/// cannot tell "this business has been quiet" from "something arrived claiming
/// to be this business and was refused", and those are very different facts
/// about a neighbourhood. So the feed says how many were refused without
/// showing a word of them — the same bargain `businesses_near_me` strikes with
/// its unverified-count banner.
class BusinessPostStore {
  /// Verified posts keyed by content id (the dedup key). Insertion-ordered.
  final Map<String, BusinessPost> _byId = {};

  int _unverified = 0;

  /// How many posts were refused by bundle verification since this store was
  /// created. Shown to the reader; never shown AS a post.
  int get unverifiedCount => _unverified;

  /// Record a post that failed envoy verification: counted, never stored.
  void recordUnverified() => _unverified++;

  /// Add a VERIFIED [post], deduped by [BusinessPost.postId]. Returns true if
  /// it was new. An outgoing echo with an empty id is stored under a synthetic
  /// key so a local publish is always visible, mirroring [FeedStore.add].
  ///
  /// Callers must verify first. This class deliberately holds no verifier: a
  /// store that quietly accepted unverified bundles would make the check
  /// optional, and [BusinessDirectory] already learned that lesson by refusing
  /// to have a default one.
  bool add(BusinessPost post) {
    final id = post.postId.isNotEmpty
        ? post.postId
        : 'local:bp:${post.polity}:${post.ts}:${post.bundle.hashCode}';
    if (_byId.containsKey(id)) return false;
    _byId[id] = post.postId.isNotEmpty
        ? post
        : BusinessPost(
            polity: post.polity,
            postId: id,
            seq: post.seq,
            ts: post.ts,
            hops: post.hops,
            bundle: post.bundle,
            outgoing: post.outgoing,
          );
    return true;
  }

  /// All stored (verified) posts in insertion order.
  List<BusinessPost> get posts => List<BusinessPost>.unmodifiable(_byId.values);

  int get length => _byId.length;

  /// True if a post with [postId] is already stored.
  bool contains(String postId) => _byId.containsKey(postId);
}
