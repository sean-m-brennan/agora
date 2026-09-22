// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// FeedEntry: one item in the merged feed — a person's post or a business's
// (Phase 3 P3.4). ONE feed, two kinds of item, because that is what the reader
// has: the shop down the road and the friend down the road appear in the same
// scroll, and the difference between them is rendered, not segregated.
//
// THE TWO KINDS RANK ON DIFFERENT LEDGERS, deliberately. A person's post is
// weighted by TIE STRENGTH — the Dunbar kernel, an attention budget that a
// person's attention is genuinely scarce against. A business's post is weighted
// by its DIRECTORY STANDING (distance, then customers you trust who vouched,
// then how current your knowledge of it is), which draws on no attention budget
// at all. That separation is P3.2's locked decision and it survives here: a
// business cannot crowd out your friends by posting, and cannot buy its way up
// by paying anyone, because the only thing that lifts it is people you already
// trust having actually been there.
//
// Both terms are then multiplied by the POST's own freshness, so the feed is
// "who matters to me × how current this is" in both cases.

import 'business_post.dart';
import 'post.dart';

/// One item in the merged feed.
sealed class FeedEntry {
  const FeedEntry({required this.score});

  /// The rank score this entry was merged at: standing × recency.
  final double score;

  /// The stable dedup/sort key.
  String get id;

  /// Post time in epoch seconds.
  double get ts;

  /// The display text.
  String get body;

  /// True if this node published it (echoed locally).
  bool get outgoing;
}

/// A person's post, weighted by tie strength.
final class PersonEntry extends FeedEntry {
  const PersonEntry(this.post, {required super.score});

  final Post post;

  @override
  String get id => post.postId;

  @override
  double get ts => post.ts;

  @override
  String get body => post.body;

  @override
  bool get outgoing => post.outgoing;
}

/// A business's post, weighted by its directory standing.
///
/// [displayName] is the business's name as read off the VERIFIED page, or an
/// empty string when this node holds no page to read it from — in which case
/// the UI shows the DID rather than inventing a name. [verifiedAgainstCharter]
/// records that the envoy chain checked out; an entry never reaches the feed
/// with it false, and it is carried so the tile can SAY so rather than leave
/// the reader to assume it.
final class BusinessEntry extends FeedEntry {
  const BusinessEntry(
    this.post, {
    required super.score,
    required this.displayName,
    required this.verifiedAgainstCharter,
  });

  final BusinessPost post;
  final String displayName;
  final bool verifiedAgainstCharter;

  @override
  String get id => post.postId;

  @override
  double get ts => post.ts;

  @override
  String get body => post.body;

  @override
  bool get outgoing => post.outgoing;
}

/// Merge and rank the two kinds into one feed.
///
/// [strengthOfAuthor] is the tie-strength kernel for a person's post;
/// [standingOfBusiness] is the directory score for a business's, in [0,1];
/// [recency] grades a post's freshness (FeedStore's decay, shared so the two
/// kinds are compared on the same time scale). An outgoing echo of either kind
/// is treated as maximal standing, so your own words never sink.
///
/// Ties break by post time (newest first) then by id, so the order is
/// deterministic — the same discipline FeedStore.ranked keeps.
///
/// [isHiddenAuthor] leaves out a PERSON's posts when the operator has blocked
/// them (Phase 4 P4.1). This is the seam that matters: rankFeed is the live
/// feed, so a filter anywhere else would pass its tests while the app showed
/// blocked posts. Hidden, not deleted — the stores keep them, so an unblock
/// restores them immediately. Business posts are not filtered by it: a
/// business is a polity, not a peer, and a block names a peer.
List<FeedEntry> rankFeed({
  required List<Post> posts,
  required List<BusinessPost> businessPosts,
  required double Function(List<int> authorUuid) strengthOfAuthor,
  required double Function(String polity) standingOfBusiness,
  required String Function(String polity) nameOfBusiness,
  required double Function(double ts) recency,
  bool Function(List<int> authorUuid)? isHiddenAuthor,
}) {
  final entries = <FeedEntry>[
    for (final p in posts)
      if (p.outgoing || isHiddenAuthor == null || !isHiddenAuthor(p.authorUuid))
        PersonEntry(p,
            score: (p.outgoing ? 1.0 : strengthOfAuthor(p.authorUuid)) *
                recency(p.ts)),
    for (final b in businessPosts)
      BusinessEntry(b,
          score: (b.outgoing ? 1.0 : standingOfBusiness(b.polity)) *
              recency(b.ts),
          displayName: nameOfBusiness(b.polity),
          verifiedAgainstCharter: true),
  ];
  entries.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byTs = b.ts.compareTo(a.ts);
    if (byTs != 0) return byTs;
    return a.id.compareTo(b.id);
  });
  return entries;
}
