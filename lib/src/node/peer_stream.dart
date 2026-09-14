// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// PeerService: wires the agorad daemon + the app-events client + a poll timer
// into a ChangeNotifier the UI can bind to. It maintains the merged peer roster
// (identity/presence from PEER_OBSERVED, score from PEER_REPUTATION).

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../ffi/at_events_bindings.dart';
import '../ffi/at_peer.dart';
import '../model/dm.dart';
import '../model/feed_store.dart';
import '../model/post.dart';
import '../model/tie_strength.dart';
import 'agora_daemon.dart';

class PeerService extends ChangeNotifier {
  PeerService({
    AgoraDaemon? daemon,
    this.pollInterval = const Duration(milliseconds: 300),
  }) : _daemon = daemon ?? _defaultDaemon();

  /// Build the default daemon. When $AGORA_EXTERNAL_DAEMON is set (to a non-empty
  /// value other than "0"/"false"), attach to an already-running `agorad` under
  /// $AUTONOMOUS_TRUST_ROOT instead of spawning one — see AgoraDaemon.external.
  static AgoraDaemon _defaultDaemon() {
    final v = Platform.environment['AGORA_EXTERNAL_DAEMON']?.toLowerCase();
    final external = v != null && v.isNotEmpty && v != '0' && v != 'false';
    return AgoraDaemon(
      queues: AgoraQueues.forThisInstance(),
      external: external,
    );
  }

  final AgoraDaemon _daemon;
  final Duration pollInterval;

  AtEvents? _events;
  Timer? _timer;
  final Map<String, AgoraPeer> _peers = {};
  String _status = 'idle';

  /// Per-peer direct-message threads (Increment 6), keyed by peer uuid hex.
  /// Incoming messages arrive via ingestEvents (AT_APP_EVENT_DM); outgoing ones
  /// are echoed locally at send time (the core does not echo them). A live
  /// stream, not roster state — never re-requested.
  final Map<String, List<DmMessage>> _dms = {};

  /// Peers with unread incoming DMs (uuid hex). Cleared by [markThreadRead] when
  /// the operator opens the thread.
  final Set<String> _unreadPeers = {};

  /// The merged feed (Increment 7). Posts arrive via ingestEvents
  /// (AT_APP_EVENT_POST, already verified/tier-gated/deduped by the core);
  /// outgoing posts are echoed locally at publish time (the core does not echo
  /// them). Deduped by post content id, ranked by S × recency (the Inc-4 kernel).
  /// A live stream, not roster state.
  final FeedStore _feed = FeedStore();

  /// Reaction tallies for OUR posts (Increment 8), keyed by post content id.
  /// A reaction is a peer engaging with one of our posts; the count is display
  /// state (the reputation effect flows separately through the earned score).
  final Map<String, int> _reactionCounts = {};

  /// Peers whose connect request we optimistically flipped to pending_out and are
  /// still awaiting the core's confirming (or reverting) edge-state echo for.
  final Set<String> _awaitingConnect = {};

  /// Hex id of a peer whose connect request the core could NOT issue — it echoed
  /// the edge back to `none`/`declined` (the peer is not an admitted identity), so
  /// the optimistic pending was reverted. The UI consumes this once to tell the
  /// operator why the request bounced. Null when there is nothing to report.
  String? _connectRejectedHex;

  /// Poll ticks between roster re-requests. A single roster pull races with the
  /// daemon: peers/positions/profiles already exchanged (common when attaching
  /// to an already-running daemon) arrive as a burst of app-events datagrams,
  /// and any dropped under that burst are otherwise never re-sent. Re-requesting
  /// the roster periodically re-emits the full stored roster (identity_emit_all_*
  /// in id_proc.c), so a late or dropped position/profile is picked up. Cheap:
  /// it walks the peer table and emits current state, deduped by applyEvent.
  static const int _rosterEveryTicks = 10; // ~3 s at the 300 ms default
  int _ticksSinceRoster = 0;

  /// This node's own opt-in coarse geohash bucket, or null when opted out (the
  /// default). Used to compute distance to peers who also opted in. Kept here so
  /// the UI can render distance and toggle sharing.
  String? _ownGeohash;
  String? get ownGeohash => _ownGeohash;

  /// This node's own opt-in agora.profile fields, or null when opted out (the
  /// default). Pushed to the daemon via AT_APP_SET_PROFILE and kept here so the
  /// UI can show/edit the operator's own profile.
  Map<String, dynamic>? _ownProfile;
  Map<String, dynamic>? get ownProfile =>
      _ownProfile == null ? null : Map<String, dynamic>.unmodifiable(_ownProfile!);

  String get status => _status;

  /// Opt in (set) or out (null/empty) of sharing a coarse position. Tells the
  /// daemon via AT_APP_SET_POSITION so it can answer peers' directed queries,
  /// and keeps it locally for distance computation. Returns the shim rc (0 ok,
  /// -2 daemon not ready), or -1 if no event channel is open yet.
  int setOwnPosition(String? geohash) {
    final ev = _events;
    final normalized = (geohash == null || geohash.isEmpty) ? null : geohash;
    if (ev == null) {
      _ownGeohash = normalized; // remember; pushed on next start
      notifyListeners();
      return -1;
    }
    final rc = ev.setPosition(_daemon.queues.appToAt, normalized ?? '');
    _ownGeohash = normalized;
    notifyListeners();
    return rc;
  }

  /// Opt in (set) or out (null/empty) of sharing an agora.profile. Serializes
  /// the fields to JSON and tells the daemon via AT_APP_SET_PROFILE so it can
  /// sign and answer peers' directed queries. Returns the shim rc (0 ok, -2
  /// daemon not ready), or -1 if no event channel is open yet.
  int setOwnProfile(Map<String, dynamic>? profile) {
    final normalized =
        (profile == null || profile.isEmpty) ? null : Map<String, dynamic>.of(profile);
    _ownProfile = normalized;
    final ev = _events;
    if (ev == null) {
      notifyListeners(); // remember; pushed on next start
      return -1;
    }
    final rc =
        ev.setProfile(_daemon.queues.appToAt, normalized == null ? '' : jsonEncode(normalized));
    notifyListeners();
    return rc;
  }

  /// Peers with an inbound connection request awaiting our response
  /// (pending_in). The UI surfaces an accept/decline affordance for each.
  List<AgoraPeer> get inboundRequests =>
      _peers.values.where((p) => p.hasInboundRequest).toList();

  /// Ask to connect to [peer] (Increment 5). A connection is EXPLICIT and
  /// revocable, SEPARATE from reputation. Stamps a real interaction recency now
  /// (a tie we tend outranks mere presence) and tells the daemon, which sets our
  /// edge to pending_out and sends a directed encrypted request. Returns the
  /// shim rc (0 ok, -2 daemon not ready), or -1 if no channel is open yet.
  int requestConnection(AgoraPeer peer) {
    peer.markInteraction(DateTime.now().millisecondsSinceEpoch / 1000.0);
    final ev = _events;
    if (ev == null) {
      notifyListeners();
      return -1;
    }
    final rc = ev.connectRequest(_daemon.queues.appToAt, peer.uuid);
    if (rc == 0) {
      // Optimistic: flip to pending_out immediately so the UI responds on tap
      // rather than waiting for the core's echo. The core emits the confirming
      // PEER_CONNECTION_STATE_OBSERVED(pending_out) shortly after — or a NONE if
      // the peer is not admitted and the request could not go out, which reverts
      // this and is reported via [consumeConnectRejection].
      peer.connectionState = ConnectionState.pendingOut.index;
      _awaitingConnect.add(_hex(peer.uuid));
    }
    notifyListeners();
    return rc;
  }

  /// The hex id of a peer whose connect request the core could not issue (it
  /// reverted the optimistic pending to none/declined). Returned once, then
  /// cleared — the UI calls this to surface a one-time message.
  String? consumeConnectRejection() {
    final r = _connectRejectedHex;
    _connectRejectedHex = null;
    return r;
  }

  /// Respond to an inbound connection request from [peer]: [accept] true
  /// connects, false declines. On accept, stamps an interaction recency. The
  /// daemon sets our edge and sends a directed encrypted, SIGNED response.
  /// Returns the shim rc (0 ok, -2 daemon not ready), or -1 if no channel.
  int respondConnection(AgoraPeer peer, bool accept) {
    if (accept) {
      peer.markInteraction(DateTime.now().millisecondsSinceEpoch / 1000.0);
    }
    final ev = _events;
    if (ev == null) {
      notifyListeners();
      return -1;
    }
    final rc = ev.connectRespond(_daemon.queues.appToAt, peer.uuid, accept);
    if (rc == 0) {
      // Optimistic: reflect the decision immediately; the core echoes the same
      // PEER_CONNECTION_STATE_OBSERVED, re-applied idempotently by applyEvent.
      peer.connectionState = (accept
              ? ConnectionState.connected
              : ConnectionState.declined)
          .index;
    }
    notifyListeners();
    return rc;
  }

  /// The DM thread with [peer] (Increment 6), oldest first. Empty if none yet.
  List<DmMessage> messagesFor(AgoraPeer peer) =>
      List<DmMessage>.unmodifiable(_dms[_hex(peer.uuid)] ?? const []);

  /// True if [peer] has unread incoming DMs (cleared by [markThreadRead]).
  bool hasUnread(AgoraPeer peer) => _unreadPeers.contains(_hex(peer.uuid));

  /// Total peers with unread DMs — a badge count for the roster.
  int get unreadPeerCount => _unreadPeers.length;

  /// Mark [peer]'s thread read (call when the operator opens it).
  void markThreadRead(AgoraPeer peer) {
    if (_unreadPeers.remove(_hex(peer.uuid))) notifyListeners();
  }

  /// Send a direct message to [peer] (Increment 6). A DM is one-way and
  /// ENCRYPTED. The outgoing message is echoed into the local thread IMMEDIATELY
  /// (the core does not echo it back), and sending a DM tends the tie — it stamps
  /// interaction recency, feeding the tie-strength kernel. Returns the shim rc
  /// (0 ok, -2 daemon not ready), or -1 if no channel is open yet.
  int sendDm(AgoraPeer peer, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return -1;
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    peer.markInteraction(now);
    (_dms[_hex(peer.uuid)] ??= <DmMessage>[]).add(DmMessage(
      peerUuidHex: _hex(peer.uuid),
      seq: 0, // the wire seq is stamped by the core and never returns to the app
      ts: now,
      text: trimmed,
      outgoing: true,
    ));
    final ev = _events;
    if (ev == null) {
      notifyListeners();
      return -1;
    }
    final rc = ev.sendDm(_daemon.queues.appToAt, peer.uuid, trimmed);
    notifyListeners();
    return rc;
  }

  /// The feed ranked by S × recency (Increment 7), newest/strongest first. S is
  /// the tie strength to each post's author (the Inc-4 kernel); recency is post
  /// freshness. Empty until posts arrive or one is published locally.
  List<Post> get feed => _feed.ranked(
        strengthOfAuthor: _strengthOfAuthor,
        nowEpochSeconds: DateTime.now().millisecondsSinceEpoch / 1000.0,
      );

  /// Total posts held in the feed store.
  int get feedCount => _feed.length;

  /// Tie strength to a post's author by uuid: the roster peer's S if we know
  /// them, else 0 (an author we cannot place is not "near"). Reuses the same
  /// [tieStrength] kernel the roster ranking uses.
  double _strengthOfAuthor(List<int> authorUuid) {
    final peer = _peers[_hex(authorUuid)];
    if (peer == null) return 0.0;
    return strengthOf(peer);
  }

  /// Publish a feed post to the local group (Increment 7) with the given
  /// [audience] band (mapped to a required trust tier the core enforces). The
  /// post is echoed into the local feed IMMEDIATELY (the core does not echo it
  /// back). Returns the shim rc (0 ok, -2 daemon not ready), or -1 if no channel
  /// is open yet or the body is empty.
  int publishPost(String body, PostAudience audience) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return -1;
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final tier = minTierForAudience(audience);
    _feed.add(Post(
      authorUuid: const [],
      postId: '', // the core computes the real content id; not returned to app
      seq: 0,
      ts: now,
      requiredTier: tier,
      body: trimmed,
      outgoing: true,
    ));
    final ev = _events;
    if (ev == null) {
      notifyListeners();
      return -1;
    }
    final rc = ev.publishPost(_daemon.queues.appToAt, trimmed, tier);
    notifyListeners();
    return rc;
  }

  /// React to [post] (Increment 8). Sends a directed encrypted reaction to the
  /// post's author; both peers accrue reputation for the engagement (the effect
  /// surfaces later through the earned score the tie-strength kernel reads).
  /// Reacting also tends the tie locally (interaction recency). Returns the shim
  /// rc (0 ok, -2 daemon not ready), or -1 if no channel is open or the post has
  /// no author/content id (e.g. our own not-yet-addressed echo).
  int reactToPost(Post post) {
    if (post.authorUuid.isEmpty || post.postId.isEmpty) return -1;
    final author = _peers[_hex(post.authorUuid)];
    if (author != null) {
      author.markInteraction(DateTime.now().millisecondsSinceEpoch / 1000.0);
    }
    final ev = _events;
    if (ev == null) {
      notifyListeners();
      return -1;
    }
    final rc = ev.reactToPost(_daemon.queues.appToAt, post.authorUuid, post.postId);
    notifyListeners();
    return rc;
  }

  /// Locally block [peer] (Increment 8): asks the core to clamp the peer's
  /// effective trust tier to 0 for this node only. Purely local — no wire traffic
  /// and no reputation transaction. Returns the shim rc (0 ok, -2 daemon not
  /// ready), or -1 if no channel is open yet.
  int blockPeer(AgoraPeer peer) {
    final ev = _events;
    if (ev == null) return -1;
    final rc = ev.block(_daemon.queues.appToAt, peer.uuid);
    notifyListeners();
    return rc;
  }

  /// Reaction tally for one of our posts by content id (Increment 8); 0 if none.
  int reactionsFor(String postId) => _reactionCounts[postId] ?? 0;

  /// Route one decoded reaction event (Increment 8): a peer reacted to one of OUR
  /// posts. Tally it for display and tend the tie to the reactor (a reaction is a
  /// bilateral interaction). Returns true if the event was a reaction (consumed
  /// here rather than by [AgoraPeer.applyEvent]).
  bool _ingestReaction(AtRawEvent e) {
    if (e.kind != agoraEventReaction) return false;
    if (e.reactionPostId.isNotEmpty) {
      _reactionCounts.update(e.reactionPostId, (c) => c + 1, ifAbsent: () => 1);
    }
    final peer = _peers[_hex(e.uuid)];
    if (peer != null) {
      peer.markInteraction(DateTime.now().millisecondsSinceEpoch / 1000.0);
    }
    return true;
  }

  /// Route one decoded post event into the feed store, deduped by content id.
  /// Returns true if the event was a post (consumed here rather than by
  /// [AgoraPeer.applyEvent]). A post is a live-stream feed item, not peer state.
  bool _ingestPost(AtRawEvent e) {
    if (e.kind != agoraEventPost) return false;
    // Ensure the author is at least a known roster entry, so tie-strength ranking
    // can place their posts (the peer's other events fill in richer state).
    _peers.putIfAbsent(_hex(e.uuid), () => AgoraPeer(uuid: e.uuid));
    _feed.add(Post.fromEvent(e));
    return true;
  }

  /// Route one decoded DM event into the per-peer thread. Appends an incoming
  /// message (deduped by (peer, seq)), stamps interaction recency on the peer
  /// (a received DM tends the tie), and flags it unread. Returns true if the
  /// event was a DM (consumed here rather than by [AgoraPeer.applyEvent]).
  bool _ingestDm(AtRawEvent e) {
    if (e.kind != agoraEventDm) return false;
    final key = _hex(e.uuid);
    final peer = _peers.putIfAbsent(key, () => AgoraPeer(uuid: e.uuid));
    final thread = _dms[key] ??= <DmMessage>[];
    // Dedup by seq: the core may re-deliver, but incoming seqs are monotone per
    // sender (the freshness gate guarantees it), so an already-seen incoming
    // seq is a duplicate.
    final seen = thread.any((m) => !m.outgoing && m.seq == e.dmSeq);
    if (!seen) {
      thread.add(DmMessage(
        peerUuidHex: key,
        seq: e.dmSeq,
        ts: e.dmTs,
        text: e.dmText,
        outgoing: false,
      ));
      _unreadPeers.add(key);
      peer.markInteraction(DateTime.now().millisecondsSinceEpoch / 1000.0);
    }
    return true;
  }

  /// Peers ordered by tie strength (§3.2) descending — the proximity-weighted
  /// social ranking that makes local, tended, trusted ties surface first. Ties
  /// break by topology rank then a stable id, so the order is deterministic.
  /// The strength itself is exposed via [strengthOf] for the UI.
  List<AgoraPeer> get peers {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final list = _peers.values.toList();
    list.sort((a, b) {
      final sa = tieStrength(a, ownGeohash: _ownGeohash, nowEpochSeconds: now);
      final sb = tieStrength(b, ownGeohash: _ownGeohash, nowEpochSeconds: now);
      final byStrength = sb.compareTo(sa);
      if (byStrength != 0) return byStrength;
      final byRank = b.rank.compareTo(a.rank);
      if (byRank != 0) return byRank;
      return _hex(a.uuid).compareTo(_hex(b.uuid));
    });
    return list;
  }

  /// Tie strength S ∈ [0,1] for [peer] from this node's viewpoint (own opt-in
  /// bucket + current time), for the UI to render alongside the roster.
  double strengthOf(AgoraPeer peer) => tieStrength(
        peer,
        ownGeohash: _ownGeohash,
        nowEpochSeconds: DateTime.now().millisecondsSinceEpoch / 1000.0,
      );

  Future<void> start() async {
    _setStatus('starting daemon…');
    await _daemon.start();

    // Resolve our in-process event sockets under the same config root as the
    // daemon (Dart cannot setenv its own process; the shim does it in C).
    AtEvents.setRoot(_daemon.root);

    // The daemon binds the AT->app queue asynchronously after fork; retry.
    for (var i = 0; i < 25 && _events == null; i++) {
      _events = AtEvents.open(_daemon.queues.atToApp);
      if (_events == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    if (_events == null) {
      _setStatus('could not open event queue');
      return;
    }

    _events!.requestRoster(_daemon.queues.appToAt);
    // If the operator opted in before the channel was ready, push it now.
    if (_ownGeohash != null) {
      _events!.setPosition(_daemon.queues.appToAt, _ownGeohash!);
    }
    if (_ownProfile != null) {
      _events!.setProfile(_daemon.queues.appToAt, jsonEncode(_ownProfile!));
    }
    _setStatus('connected');
    _timer = Timer.periodic(pollInterval, (_) => _tick());
  }

  void _tick() {
    final ev = _events;
    if (ev == null) return;
    // Periodically re-pull the full roster so positions/profiles exchanged just
    // before we attached (or dropped under the initial emit burst) are surfaced.
    if (++_ticksSinceRoster >= _rosterEveryTicks) {
      _ticksSinceRoster = 0;
      ev.requestRoster(_daemon.queues.appToAt);
    }
    ingestEvents(ev.poll());
  }

  /// Merge a batch of decoded events into the roster, notifying listeners if
  /// any arrived. Extracted from the poll tick so it can be driven directly in
  /// tests (which never load the native shim). A new peer is created on first
  /// sighting; subsequent events (reputation, RTT, position, profile, and
  /// connection request/state — all peer-scoped, handled by applyEvent) merge in.
  @visibleForTesting
  void ingestEvents(List<AtRawEvent> batch) {
    if (batch.isEmpty) return;
    for (final e in batch) {
      // A DM is a live-stream message, not peer state — routed into the per-peer
      // thread rather than merged into the AgoraPeer by applyEvent.
      if (_ingestDm(e)) continue;
      // A post is a live-stream feed item — routed into the FeedStore.
      if (_ingestPost(e)) continue;
      // A reaction to one of our posts — tallied, not merged into a peer.
      if (_ingestReaction(e)) continue;
      final key = _hex(e.uuid);
      final peer = _peers.putIfAbsent(key, () => AgoraPeer(uuid: e.uuid));
      peer.applyEvent(e);
      // Resolve an optimistic connect (Increment 5 UX): the core echoes the real
      // edge state after handle_app_connect_request. pending_out/connected confirm
      // the request; a revert to none/declined means it could not be issued (the
      // peer is not admitted), which we surface once to the operator.
      if (e.kind == agoraEventConnectionState && _awaitingConnect.remove(key)) {
        final st = peer.connection;
        if (st != ConnectionState.pendingOut &&
            st != ConnectionState.connected) {
          _connectRejectedHex = key;
        }
      }
    }
    notifyListeners();
  }

  Future<void> shutdown() async {
    _timer?.cancel();
    _timer = null;
    _events?.close();
    _events = null;
    await _daemon.stop();
    _setStatus('stopped');
  }

  void _setStatus(String s) {
    _status = s;
    notifyListeners();
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
