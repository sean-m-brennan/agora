// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// FeedPage: the basic feed (Increment 7, extended by Phase 3 P3.4). Posts are
// listed ranked by S × recency (the tie-strength kernel × post freshness), so
// local, tended, trusted authors posting recently surface first. A compose box
// publishes a new post with a PostAudience selector (the Inc-4 audience bands →
// the required trust tier the core enforces). Incoming posts are already
// verified, tier-gated and deduped by the core; outgoing posts are echoed
// locally at publish time.
//
// BUSINESSES APPEAR IN THE SAME SCROLL, RENDERED DIFFERENTLY (P3.4 box 5). The
// shop down the road and the friend down the road are both things happening
// near you, so they share one feed; what separates them is the tile, not a
// segregated section. A business tile says three things a person's does not:
// that the words are the POLITY's (a storefront mark, the business's name off
// its verified page — never a node's uuid), that the envoy chain CHECKED OUT
// against the charter, and, when it travelled, that it reached you through a
// relay rather than straight from the business.
//
// AND IT SAYS WHAT IT REFUSED. A post whose envoy signature does not verify is
// never rendered under a business's name — it is counted in a banner instead.
// A reader told nothing cannot tell "the cafe has been quiet" from "something
// claiming to be the cafe was refused", and those are different facts about a
// neighbourhood.

import 'package:flutter/material.dart';

import '../model/business_post.dart';
import '../model/feed_entry.dart';
import '../model/post.dart';
import '../model/tie_strength.dart';
import '../node/peer_stream.dart';

class FeedPage extends StatefulWidget {
  const FeedPage({super.key, required this.service});

  final PeerService service;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  final TextEditingController _compose = TextEditingController();
  PostAudience _audience = PostAudience.public;

  @override
  void dispose() {
    _compose.dispose();
    super.dispose();
  }

  void _publish() {
    final body = _compose.text.trim();
    if (body.isEmpty) return;
    widget.service.publishPost(body, _audience);
    _compose.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Feed')),
      body: Column(
        children: [
          Expanded(
            child: AnimatedBuilder(
              animation: widget.service,
              builder: (context, _) {
                final entries = widget.service.feed;
                final refused = widget.service.businessPostsUnverified;
                final hidden = widget.service.feedHiddenByBlock;
                if (entries.isEmpty && refused == 0 && hidden == 0) {
                  return const Center(
                    child: Text('No posts yet — share something.'),
                  );
                }
                // The banner counts business posts that failed envoy
                // verification. It sits ABOVE the list and shows even when the
                // list is empty, because "nothing here" and "nothing here that
                // proved itself" are different things to be told.
                //
                // The same holds for posts hidden by a block (Phase 4 P4.1): a
                // block must never read as "nobody posted".
                final banners = <Widget>[
                  if (refused > 0) _UnverifiedBanner(count: refused),
                  if (hidden > 0) _HiddenByBlockBanner(count: hidden),
                ];
                if (entries.isEmpty) {
                  return ListView(
                    padding: const EdgeInsets.all(8),
                    children: [
                      ...banners,
                      const SizedBox(height: 12),
                      const Center(
                        child: Text('No posts yet — share something.'),
                      ),
                    ],
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: entries.length + banners.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    if (i < banners.length) return banners[i];
                    i -= banners.length;
                    final entry = entries[i];
                    return switch (entry) {
                      PersonEntry(:final post) =>
                        _PostTile(post: post, service: widget.service),
                      BusinessEntry() => _BusinessPostTile(entry: entry),
                    };
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Text('Audience:'),
                    const SizedBox(width: 8),
                    DropdownButton<PostAudience>(
                      value: _audience,
                      onChanged: (a) {
                        if (a != null) setState(() => _audience = a);
                      },
                      items: PostAudience.values
                          .map((a) => DropdownMenuItem<PostAudience>(
                                value: a,
                                child: Text(audienceLabel(a)),
                              ))
                          .toList(),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _compose,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _publish(),
                        decoration: const InputDecoration(
                          hintText: "What's happening?",
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.send),
                      tooltip: 'Post',
                      onPressed: _publish,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How many business posts were refused, and why that is worth saying.
class _UnverifiedBanner extends StatelessWidget {
  const _UnverifiedBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      margin: EdgeInsets.zero,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.gpp_maybe, color: scheme.onErrorContainer),
        title: Text(
          count == 1
              ? '1 business post could not be verified'
              : '$count business posts could not be verified',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
        subtitle: Text(
          'Their envoy signature did not check out against the charter, so '
          'they are not shown as any business\'s words.',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
      ),
    );
  }
}

/// How many held posts a block is hiding (Phase 4 P4.1). On the neutral
/// surface, not an error colour: a block is the operator's choice, not a
/// failure.
class _HiddenByBlockBanner extends StatelessWidget {
  const _HiddenByBlockBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('hidden-by-block'),
      color: scheme.surfaceContainerHighest,
      margin: EdgeInsets.zero,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.visibility_off_outlined,
            color: scheme.onSurfaceVariant),
        title: Text(count == 1
            ? '1 post hidden from someone you blocked'
            : '$count posts hidden from people you blocked'),
        subtitle: const Text('Unblock them to see these again.'),
      ),
    );
  }
}

/// A business post: the polity speaking, and visibly not a person.
class _BusinessPostTile extends StatelessWidget {
  const _BusinessPostTile({required this.entry});

  final BusinessEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final BusinessPost post = entry.post;
    // The name comes off the VERIFIED page. With no page held there is no name
    // to show, and we show the DID rather than invent one — a business that
    // has not proved who it is does not get to be called anything.
    final who = entry.displayName.isNotEmpty
        ? entry.displayName
        : (post.polity.length <= 20
            ? post.polity
            : '${post.polity.substring(0, 20)}…');
    final provenance = entry.outgoing
        ? 'posted as this business'
        : (post.hops == 0 ? 'direct from the business' : 'relayed');
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.tertiaryContainer,
        child: Icon(Icons.storefront,
            size: 18, color: scheme.onTertiaryContainer),
      ),
      title: Text(post.body),
      subtitle: Row(
        children: [
          Flexible(
            child: Text('$who · $provenance',
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          // Not decoration: this is the claim the reader is being asked to
          // rely on, so it is stated rather than implied by the post's mere
          // presence.
          Icon(Icons.verified, size: 14, color: scheme.primary),
          const SizedBox(width: 2),
          Text('envoy-signed',
              style: TextStyle(fontSize: 11, color: scheme.primary)),
        ],
      ),
      dense: true,
    );
  }
}

class _PostTile extends StatelessWidget {
  const _PostTile({required this.post, required this.service});

  final Post post;
  final PeerService service;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final who = post.outgoing
        ? 'you'
        : (post.authorHex.length <= 12
            ? post.authorHex
            : post.authorHex.substring(0, 12));
    final audience = audienceLabel(audienceForTier(post.requiredTier));
    // A received post (not our own echo) that carries an author + content id can
    // be reacted to (Increment 8): a reaction is the directed return signal that
    // lets the engagement accrue reputation for both peers. Our own posts have no
    // content id at the app boundary, so no react affordance there.
    final canReact =
        !post.outgoing && post.authorUuid.isNotEmpty && post.postId.isNotEmpty;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            post.outgoing ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        child: Icon(post.outgoing ? Icons.person : Icons.public, size: 18),
      ),
      title: Text(post.body),
      subtitle: Text('$who · $audience'),
      trailing: canReact
          ? IconButton(
              icon: const Icon(Icons.favorite_border, size: 20),
              tooltip: 'React',
              onPressed: () {
                final rc = service.reactToPost(post);
                final msg = rc == 0
                    ? 'Reaction sent'
                    : (rc == -2 ? 'Not connected yet' : 'Could not react');
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(msg)));
              },
            )
          : null,
      dense: true,
    );
  }
}
