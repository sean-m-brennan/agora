// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Phase-0 "People near me" view. Shows each observed peer's identity (signed
// agora.profile when shared, else short id), rank, operator-attended presence,
// reputation, RTT, and opt-in coarse distance (see SOCIAL_APP_PLAN.md §5.1).

import 'package:flutter/material.dart';

import '../node/peer_stream.dart';
import '../ffi/at_peer.dart';

class PeopleNearMePage extends StatelessWidget {
  const PeopleNearMePage({super.key, required this.service});

  final PeerService service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('People near me'),
        actions: [
          ListenableBuilder(
            listenable: service,
            builder: (context, _) {
              final sharing = service.ownProfile != null;
              return IconButton(
                icon: Icon(sharing ? Icons.badge : Icons.badge_outlined),
                tooltip: sharing
                    ? 'Sharing your profile — tap to edit'
                    : 'Profile not shared — tap to set one',
                onPressed: () => _editOwnProfile(context, service),
              );
            },
          ),
          ListenableBuilder(
            listenable: service,
            builder: (context, _) {
              final sharing = service.ownGeohash != null;
              return IconButton(
                icon: Icon(sharing ? Icons.location_on : Icons.location_off),
                tooltip: sharing
                    ? 'Sharing location (~5 km bucket) — tap to change'
                    : 'Location not shared — tap to opt in',
                onPressed: () => _editOwnPosition(context, service),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final peers = service.peers;
          final own = service.ownGeohash;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _PendingCapabilitiesBanner(),
              _StatusBar(status: service.status, count: peers.length),
              Expanded(
                child: peers.isEmpty
                    ? const Center(
                        child: Text('No peers observed yet…'),
                      )
                    : ListView.separated(
                        itemCount: peers.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) =>
                            _PeerTile(peer: peers[i], ownGeohash: own),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Opt in (enter a coarse geohash bucket) or out (clear) of sharing location.
  /// Strictly opt-in: closing without sharing changes nothing.
  Future<void> _editOwnPosition(BuildContext context, PeerService service) async {
    final controller = TextEditingController(text: service.ownGeohash ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share coarse location'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Opt in to share a ~5 km geohash bucket with connected peers only. '
              'This is a coarse area, not your exact location, and is never '
              'broadcast. Leave empty (or Stop sharing) to opt out.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Geohash bucket (e.g. 9q8yy)',
                hintText: '~5 chars',
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, '__optout__'),
            child: const Text('Stop sharing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Share'),
          ),
        ],
      ),
    );
    if (result == null) return; // cancelled — no change
    service.setOwnPosition(result == '__optout__' ? null : result);
  }

  /// Set or edit this node's opt-in agora.profile. Strictly opt-in: cancelling
  /// changes nothing; "Stop sharing" clears it. Fields are all optional; the
  /// daemon truncates each to its bound and signs the result.
  Future<void> _editOwnProfile(BuildContext context, PeerService service) async {
    final existing = service.ownProfile ?? const {};
    String s(String k) => (existing[k] is String) ? existing[k] as String : '';
    final name = TextEditingController(text: s('display_name'));
    final handle = TextEditingController(text: s('handle'));
    final bio = TextEditingController(text: s('bio'));
    final avatar = TextEditingController(text: s('avatar_ref'));
    final links = TextEditingController(
      text: (existing['links'] is List)
          ? (existing['links'] as List).whereType<String>().join(', ')
          : '',
    );
    final action = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your profile'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Optional fields shared, signed, with connected peers only. '
                'Leave all empty (or Stop sharing) to opt out.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Display name'),
              ),
              TextField(
                controller: handle,
                decoration: const InputDecoration(
                  labelText: 'Handle', hintText: 'letters, digits, _.- only'),
              ),
              TextField(
                controller: bio,
                decoration: const InputDecoration(labelText: 'Bio'),
                maxLines: 2,
              ),
              TextField(
                controller: avatar,
                decoration: const InputDecoration(
                  labelText: 'Avatar reference (URL)'),
              ),
              TextField(
                controller: links,
                decoration: const InputDecoration(
                  labelText: 'Links', hintText: 'comma-separated URLs'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, '__optout__'),
            child: const Text('Stop sharing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, '__save__'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (action == null) return; // cancelled
    if (action == '__optout__') {
      service.setOwnProfile(null);
      return;
    }
    final profile = <String, dynamic>{};
    void put(String k, String v) {
      if (v.trim().isNotEmpty) profile[k] = v.trim();
    }
    put('display_name', name.text);
    put('handle', handle.text);
    put('bio', bio.text);
    put('avatar_ref', avatar.text);
    final linkList = links.text
        .split(',')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    if (linkList.isNotEmpty) profile['links'] = linkList;
    service.setOwnProfile(profile.isEmpty ? null : profile);
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, this.ownGeohash});

  final AgoraPeer peer;
  final String? ownGeohash;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final present = peer.operatorBound && peer.operatorAttestedAt > 0;
    final title = peer.hasProfile
        ? Text(peer.displayLabel)
        : Text(peer.shortId, style: const TextStyle(fontFamily: 'monospace'));
    // Keep the subtitle to at most two lines so it fits a three-line ListTile.
    // Line 1 is presence, plus — when a display name is the title — the @handle
    // and short id, so identity stays verifiable (the profile is signed, but a
    // name is not a key). Line 2, if present, is the bio.
    final subtitleLines = <Widget>[];
    if (peer.hasProfile) {
      final bits = <String>[
        peer.presenceLabel(now),
        if (peer.handle.isNotEmpty && peer.displayName.isNotEmpty) '@${peer.handle}',
        peer.shortId,
      ];
      subtitleLines.add(Text(bits.join(' · '),
          maxLines: 1, overflow: TextOverflow.ellipsis));
      if (peer.bio.isNotEmpty) {
        subtitleLines.add(Text(peer.bio,
            maxLines: 1, overflow: TextOverflow.ellipsis));
      }
    } else {
      subtitleLines.add(Text(peer.presenceLabel(now)));
    }
    return ListTile(
      isThreeLine: peer.hasProfile,
      leading: peer.avatarRef.isNotEmpty
          ? CircleAvatar(child: Text(peer.displayLabel.characters.first))
          : Icon(
              present ? Icons.circle : Icons.circle_outlined,
              size: 14,
              color: present ? Colors.green : Theme.of(context).disabledColor,
            ),
      title: title,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: subtitleLines,
      ),
      // Kept to three compact lines so the trailing column fits the ListTile
      // height (rtt and distance share a line — both are proximity signals).
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('rank ${peer.rank}'),
          Text('rep ${peer.reputationLabel}',
              style: Theme.of(context).textTheme.bodySmall),
          Text('${peer.rttLabel} · ${peer.distanceLabel(ownGeohash)}',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.status, required this.count});

  final String status;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(child: Text('Status: $status')),
          Text('$count peer${count == 1 ? '' : 's'}'),
        ],
      ),
    );
  }
}

class _PendingCapabilitiesBanner extends StatelessWidget {
  const _PendingCapabilitiesBanner();

  @override
  Widget build(BuildContext context) {
    return const MaterialBanner(
      content: Text(
        'Presence, reputation, RTT, opt-in distance, and opt-in signed profiles '
        'are live. RTT is a network-latency proxy (ms); distance is a coarse '
        '(~5 km) estimate shown only when BOTH sides opt in (location icon). '
        'Profiles (agora.profile) are shared, signed, only with connected peers '
        '(badge icon to set yours). (SOCIAL_APP_PLAN.md §5.1)',
      ),
      leading: Icon(Icons.info_outline),
      actions: [SizedBox.shrink()],
    );
  }
}
