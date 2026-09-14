// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// FeedPage: the basic feed (Increment 7). Posts are listed ranked by S × recency
// (the tie-strength kernel × post freshness), so local, tended, trusted authors
// posting recently surface first. A compose box publishes a new post with a
// PostAudience selector (the Inc-4 audience bands → the required trust tier the
// core enforces). Incoming posts are already verified, tier-gated and deduped by
// the core; outgoing posts are echoed locally at publish time.

import 'package:flutter/material.dart';

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
                final posts = widget.service.feed;
                if (posts.isEmpty) {
                  return const Center(
                    child: Text('No posts yet — share something.'),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: posts.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _PostTile(post: posts[i]),
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

class _PostTile extends StatelessWidget {
  const _PostTile({required this.post});

  final Post post;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final who = post.outgoing
        ? 'you'
        : (post.authorHex.length <= 12
            ? post.authorHex
            : post.authorHex.substring(0, 12));
    final audience = audienceLabel(audienceForTier(post.requiredTier));
    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            post.outgoing ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        child: Icon(post.outgoing ? Icons.person : Icons.public, size: 18),
      ),
      title: Text(post.body),
      subtitle: Text('$who · $audience'),
      dense: true,
    );
  }
}
