// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Phase-0 "People near me" view. Shows each observed peer's identity (signed
// agora.profile when shared, else short id), rank, operator-attended presence,
// reputation, RTT, and opt-in coarse distance (see SOCIAL_APP_PLAN.md §5.1).

// Hide Flutter's own ConnectionState (FutureBuilder/StreamBuilder) — this file
// uses the peer-edge ConnectionState from at_peer.dart (Increment 5), and does
// not use async builders.
import 'package:flutter/material.dart' hide ConnectionState;

import '../node/peer_stream.dart';
import '../ffi/at_peer.dart';
import '../model/tie_strength.dart';
import 'dm_thread.dart';
import 'feed_view.dart';

class PeopleNearMePage extends StatefulWidget {
  const PeopleNearMePage({super.key, required this.service});

  final PeerService service;

  @override
  State<PeopleNearMePage> createState() => _PeopleNearMePageState();
}

class _PeopleNearMePageState extends State<PeopleNearMePage> {
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onServiceChanged);
    super.dispose();
  }

  /// Surface a one-time message when the core could not issue a connect request
  /// (it reverted the optimistic pending). Runs after the frame so it can show a
  /// SnackBar without mutating state during build.
  void _onServiceChanged() {
    final hex = widget.service.consumeConnectRejection();
    if (hex == null || !mounted) return;
    final short = hex.length <= 12 ? hex : hex.substring(0, 12);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not connect to $short — peer is not admitted yet'),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    return Scaffold(
      appBar: AppBar(
        title: const Text('People near me'),
        actions: [
          IconButton(
            icon: const Icon(Icons.dynamic_feed),
            tooltip: 'Feed',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => FeedPage(service: service),
              ),
            ),
          ),
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
              _OwnerBanner(
                name: service.ownDisplayName,
                shortId: service.ownShortId,
              ),
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
                        itemBuilder: (context, i) => _PeerTile(
                            peer: peers[i], ownGeohash: own, service: service),
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
  const _PeerTile({required this.peer, required this.service, this.ownGeohash});

  final AgoraPeer peer;
  final PeerService service;
  final String? ownGeohash;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final present = peer.operatorBound && peer.operatorAttestedAt > 0;
    final strength =
        tieStrength(peer, ownGeohash: ownGeohash, nowEpochSeconds: now);
    final audience = audienceLabel(audienceForTier(trustTier(peer)));
    final nameText = peer.hasProfile
        ? Text(peer.displayLabel)
        : Text(peer.shortId, style: const TextStyle(fontFamily: 'monospace'));
    // Group co-membership indicator (distinct from a connection edge): shown
    // once the cohort converges and this peer's address is in our group. A quiet
    // badge next to the name, not a peer you "connect" to.
    final title = peer.inGroup
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: nameText),
            const SizedBox(width: 6),
            Tooltip(
              message: 'In your group',
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.group,
                    size: 14, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 2),
                Text('in your group',
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.primary)),
              ]),
            ),
          ])
        : nameText;
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
      // Three compact lines: the tie strength (§3.2) that drives the ordering,
      // then the trust band this peer sits in (its post audience), then the
      // proximity signals (rtt · coarse distance) that feed the strength.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PeerOverflowMenu(peer: peer, service: service),
          _MessageButton(peer: peer, service: service),
          _ConnectControl(peer: peer, service: service),
          const SizedBox(width: 4),
          Builder(builder: (context) {
            // Compact line style: three signals must fit the trailing box of a
            // three-line ListTile without overflowing (a taller default line
            // height spilled it by a few px), so tighten the line height.
            final small = Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(height: 1.15);
            return Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('tie ${strength.toStringAsFixed(2)}',
                    style: small?.copyWith(fontWeight: FontWeight.w600)),
                Text('rep ${peer.reputationLabel} · $audience', style: small),
                Text('${peer.rttLabel} · ${peer.distanceLabel(ownGeohash)}',
                    style: small),
              ],
            );
          }),
        ],
      ),
    );
  }
}

/// The per-peer overflow menu. Holds the local BLOCK action (Increment 8): a
/// block clamps this peer's effective trust tier to 0 for THIS node only — purely
/// local, no wire traffic and no reputation transaction, so it is a self-protection
/// affordance distinct from a decline (which is a shared, accruing signal).
class _PeerOverflowMenu extends StatelessWidget {
  const _PeerOverflowMenu({required this.peer, required this.service});

  final AgoraPeer peer;
  final PeerService service;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      tooltip: 'More',
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value == 'block') {
          final rc = service.blockPeer(peer);
          final msg = rc == 0
              ? 'Peer blocked (local)'
              : (rc == -2 ? 'Not connected yet' : 'Could not block');
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem<String>(
          value: 'block',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.block, size: 18),
            title: Text('Block'),
          ),
        ),
      ],
    );
  }
}

/// The per-peer message affordance (Increment 6): opens the DM thread with this
/// peer. A DM needs no connection or tier — it is allowed between any two peers —
/// so this sits alongside the connect control, always available. A dot marks an
/// unread incoming message.
class _MessageButton extends StatelessWidget {
  const _MessageButton({required this.peer, required this.service});

  final AgoraPeer peer;
  final PeerService service;

  void _open(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DmThreadPage(peer: peer, service: service),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final icon = IconButton(
      icon: const Icon(Icons.chat_bubble_outline),
      tooltip: 'Message',
      visualDensity: VisualDensity.compact,
      onPressed: () => _open(context),
    );
    if (!service.hasUnread(peer)) return icon;
    // A small unread dot in the corner of the icon.
    return Stack(
      alignment: Alignment.center,
      children: [
        icon,
        Positioned(
          right: 6,
          top: 6,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    );
  }
}

/// The per-peer connection affordance (Increment 5). Reflects the explicit,
/// revocable edge state and offers the next action: connect when there is no
/// edge, accept/decline an inbound request (pending_in), a pending indicator
/// after we asked (pending_out), and a connected/declined marker otherwise. A
/// connection is SEPARATE from reputation — this never changes trust.
class _ConnectControl extends StatelessWidget {
  const _ConnectControl({required this.peer, required this.service});

  final AgoraPeer peer;
  final PeerService service;

  /// Report a failed connection action. Success is silent — the tile itself
  /// flips to the new state (optimistically, then confirmed by the core's echo).
  void _report(BuildContext context, int rc, String action) {
    if (rc == 0) return;
    final msg = rc == -2
        ? 'Not connected to the daemon yet — try again in a moment'
        : 'Could not $action (no channel)';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    switch (peer.connection) {
      case ConnectionState.pendingIn:
        // They asked us: accept / decline.
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.check_circle, color: Colors.green),
              tooltip: 'Accept connection',
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  _report(context, service.respondConnection(peer, true), 'accept'),
            ),
            IconButton(
              icon: const Icon(Icons.cancel_outlined),
              tooltip: 'Decline connection',
              visualDensity: VisualDensity.compact,
              onPressed: () => _report(
                  context, service.respondConnection(peer, false), 'decline'),
            ),
          ],
        );
      case ConnectionState.pendingOut:
        return const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Tooltip(
            message: 'Request sent — awaiting response',
            child: Icon(Icons.hourglass_top, size: 18),
          ),
        );
      case ConnectionState.connected:
        return Tooltip(
          message: 'Connected',
          child: Icon(Icons.link, color: Theme.of(context).colorScheme.primary),
        );
      case ConnectionState.declined:
        // Declined — allow a fresh ask (connections are revocable).
        return IconButton(
          icon: const Icon(Icons.person_off_outlined),
          tooltip: 'Declined — tap to ask again',
          visualDensity: VisualDensity.compact,
          onPressed: () =>
              _report(context, service.requestConnection(peer), 'connect'),
        );
      case ConnectionState.none:
        return IconButton(
          icon: const Icon(Icons.person_add_alt_1),
          tooltip: 'Connect',
          visualDensity: VisualDensity.compact,
          onPressed: () =>
              _report(context, service.requestConnection(peer), 'connect'),
        );
    }
  }
}

/// A prominent banner at the very top of the window identifying WHOSE node this
/// is — the operator's own display name (or nickname) plus a short id — so two
/// cohort windows on one screen are never confused. Empty until the identity
/// config has loaded, in which case it shows a neutral placeholder.
class _OwnerBanner extends StatelessWidget {
  const _OwnerBanner({required this.name, required this.shortId});

  final String name;
  final String shortId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = name.isNotEmpty ? name : 'This node';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: scheme.primaryContainer,
      child: Row(
        children: [
          Icon(Icons.account_circle, size: 20, color: scheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: scheme.onPrimaryContainer,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (shortId.isNotEmpty)
            Text(
              shortId,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: scheme.onPrimaryContainer.withValues(alpha: 0.75),
              ),
            ),
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
        'Ranked by TIE STRENGTH (§3.2): trust tier + interaction recency + '
        'proximity, so local, tended, trusted ties surface first. "tie" is that '
        'score; the band beside "rep" is the peer\'s post audience (public → '
        'close). RTT is a network-latency proxy (ms); distance is a coarse '
        '(~5 km) estimate shown only when BOTH sides opt in (location icon). '
        'Profiles are shared, signed, only with connected peers (badge icon). '
        '(SOCIAL_APP_PLAN.md §3, §5.1)',
      ),
      leading: Icon(Icons.info_outline),
      actions: [SizedBox.shrink()],
    );
  }
}
