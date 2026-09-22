// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// PeerService: wires the agorad daemon + the app-events client + a poll timer
// into a ChangeNotifier the UI can bind to. It maintains the merged peer roster
// (identity/presence from PEER_OBSERVED, score from PEER_REPUTATION).

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';

import '../ffi/at_events_bindings.dart';
import '../ffi/at_peer.dart';
import '../ffi/ethne_bindings.dart';
import '../model/attention_budget.dart';
import '../model/business.dart';
import '../model/business_directory.dart';
import '../model/business_post.dart';
import '../model/cosign_exchanges.dart';
import '../model/dm.dart';
import '../model/feed_entry.dart';
import '../model/member_roll.dart';
import '../model/moderation.dart';
import '../model/moderation_store.dart';
import '../model/feed_store.dart';
import '../model/post.dart';
import '../model/staff_identity.dart';
import '../model/staff_roster.dart';
import '../model/tie_settings.dart';
import '../model/tie_strength.dart';
import 'agora_daemon.dart';
import 'moderation_verbs.dart';
import 'polity_acts.dart';

/// The app-side rc for a report the advisory cap refused before anything was
/// sent (Phase 4 P4.1). Distinct from AT_APP_NOT_READY (-2) and -1 (no channel),
/// so the UI can say what actually happened instead of lying or going silent.
const int reportRefusedCap = -3;

class PeerService extends ChangeNotifier {
  PeerService({
    AgoraDaemon? daemon,
    this.pollInterval = const Duration(milliseconds: 300),
    @visibleForTesting BundleVerifier? bundleVerifier,
    @visibleForTesting StaffIdentity? staffIdentity,
    @visibleForTesting StaffRoster? staffRoster,
    @visibleForTesting CosignDescriber? cosignDescriber,
    @visibleForTesting RollPublisher? rollPublisher,
    @visibleForTesting ModerationVerbs? moderationVerbs,
    @visibleForTesting PolityActs? polityActs,
  })  : _daemon = daemon ?? _defaultDaemon(),
        _polityActsOverride = polityActs,
        _moderationVerbsOverride = moderationVerbs,
        _bundleVerifierOverride = bundleVerifier,
        _staffOverride = staffIdentity,
        _rosterOverride = staffRoster,
        _cosignDescriberOverride = cosignDescriber,
        _rollPublisherOverride = rollPublisher;

  /// Test-only stand-in for the Ethne bundle verifier. Null in the app, where
  /// the real cdylib does the proving.
  final BundleVerifier? _bundleVerifierOverride;

  /// Test-only stand-ins for the staff surface (Phase 3 P3.3). Both are plain
  /// data — a keypair is three strings and two maps, and a roster is a fold of
  /// two JSON maps — so the whole surface, including every honest state, is
  /// exercised with no charter log and no cdylib present.
  final StaffIdentity? _staffOverride;
  final StaffRoster? _rosterOverride;

  /// Test-only stand-in for the local description derivation, which otherwise
  /// needs the cdylib. Null in the app, where the bytes are read for real.
  final CosignDescriber? _cosignDescriberOverride;

  /// Test-only stand-in for minting and checking a member roll. Null in the app,
  /// where the root key signs and the cdylib checks.
  final RollPublisher? _rollPublisherOverride;

  /// Test-only stand-in for the four moderation verbs. Null in the app, where
  /// they go to the core over the shim.
  final ModerationVerbs? _moderationVerbsOverride;
  late final ModerationVerbs _moderationVerbs =
      _moderationVerbsOverride ?? _ShimModerationVerbs(this);

  /// Test-only stand-in for the polity acts an expulsion needs. Null in the
  /// app, where they are the cdylib over this node's charter archive.
  final PolityActs? _polityActsOverride;

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

  /// Per-user persisted tuning + durable per-peer last-interaction (Phase 2,
  /// §3.3). Loaded in [start]; null until then (unit tests that never start the
  /// daemon simply run on the in-memory defaults). Writes are debounced.
  TieSettingsStore? _settings;
  Timer? _saveTimer;

  /// The tie-strength weights currently in force (persisted tuning if loaded,
  /// else the defaults).
  TieStrengthWeights get _weights =>
      _settings?.settings.weights ?? TieStrengthWeights.defaults;

  /// The attention-budget parameters currently in force.
  AttentionBudgetParams get budgetParams =>
      _settings?.settings.budget ?? AttentionBudgetParams.defaults;

  /// Create a peer, seeding its last-interaction time from durable storage so a
  /// tie we tended before this launch does not spuriously read as "cold".
  AgoraPeer _newPeer(List<int> uuid) {
    final p = AgoraPeer(uuid: uuid);
    final durable = _settings?.lastInteractionFor(_hex(uuid));
    if (durable != null && durable > p.lastInteractionAt) {
      p.lastInteractionAt = durable;
    }
    return p;
  }

  /// Stamp an interaction with [peer] (tends the tie, feeding the recency term),
  /// and persist it durably so the tie survives a restart. Debounced save.
  void _tend(AgoraPeer peer, [double? nowSec]) {
    // A blocked tie is not an attended tie (Phase 4 P4.1): nothing we do or
    // receive while they are blocked may warm it.
    if (peer.blocked) return;
    final now = nowSec ?? DateTime.now().millisecondsSinceEpoch / 1000.0;
    peer.markInteraction(now);
    final s = _settings;
    if (s != null) {
      s.recordInteraction(_hex(peer.uuid), now);
      _scheduleSave();
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () => _settings?.save());
  }

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

  /// The businesses this node has learned about (Phase 3 P3.2). Ads arrive via
  /// ingestEvents (AT_APP_EVENT_BUSINESS_AD), already signature-verified and
  /// content-id-deduped by the core — but the core does NOT verify the Ethne
  /// page bundle it carried, so the directory does that here before storing
  /// anything. Ranked distance → vouch → recency. A live stream, not roster
  /// state.
  late final BusinessDirectory _businesses =
      BusinessDirectory(verifyBundle: _verifyBusinessBundle);

  /// Business posts, verified against the envoy chain before they are kept
  /// (Phase 3 P3.4). An unverified post is counted here and shown to nobody.
  final BusinessPostStore _businessPosts = BusinessPostStore();

  /// The Ethne cdylib, opened lazily on the first bundle we are asked to verify.
  /// Absent when the library was not built or found — see
  /// [businessesUnverified].
  EthneFfi? _ethne;
  bool _ethneTried = false;

  /// This node's staff membership (Phase 3 P3.3): the key it signs governance
  /// acts with and the polity charter log it reads the roll out of. Loaded in
  /// [start]; null when this node is staff of no polity, which is the ordinary
  /// case and not an error.
  StaffIdentityStore? _staff;

  /// The live charter log, opened from the stored dump. Null when there is no
  /// identity, or when the cdylib could not be loaded.
  EthneArchive? _polityArchive;

  /// The two Ethne state maps, read once per archive rather than once per frame
  /// — folding them is cheap and pure, reading them crosses the FFI. Cleared
  /// whenever the archive is replaced.
  Map<String, dynamic>? _affirmationState;
  Map<String, dynamic>? _guardianStateMap;
  bool? _polityVerified;

  /// Co-signature exchanges in flight (Phase 3 P3.3). The describer derives each
  /// act's wording HERE, from its bytes, because none crosses the wire.
  late final CosignExchanges _cosign =
      CosignExchanges(describeBytes: _describeCosignBytes);

  /// THIS node's own customer edges: polity DID → declared satisfaction (0..4).
  /// The core holds the authoritative edge (it is what authorizes us to carry a
  /// page) and never echoes it back, so the operator's own rating is mirrored
  /// here for display. Clearing an edge removes the entry — nothing negative is
  /// ever recorded, here or on the wire.
  final Map<String, int> _customerSatisfaction = {};

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

  /// This node's own identity, read once from `<root>/etc/at/identity.cfg.json`
  /// (the daemon's config). Empty until [start] has loaded it. Used for the
  /// window header (so Bob's window is distinguishable from Ada's) and to filter
  /// our own identity out of the roster — belt to the core's self-peer guard.
  String _ownUuidHex = '';
  String _ownNickname = '';

  /// The node nickname (e.g. "agora-node-2"), or '' if not yet loaded.
  String get ownNickname => _ownNickname;

  /// Our own identity uuid as 32 lowercase hex chars (no dashes), matching the
  /// [_hex] roster keys; '' until loaded.
  String get ownUuidHex => _ownUuidHex;

  /// A short, human-scannable form of our own uuid (first 12 hex), matching the
  /// short id shown for peers. '' until loaded.
  String get ownShortId =>
      _ownUuidHex.length >= 12 ? _ownUuidHex.substring(0, 12) : _ownUuidHex;

  /// The best human label for THIS node: the operator's own profile display
  /// name when shared, else the node nickname. '' only before [start].
  String get ownDisplayName {
    final dn = _ownProfile?['display_name'];
    if (dn is String && dn.trim().isNotEmpty) return dn.trim();
    return _ownNickname;
  }

  /// Inject this node's own identity directly, for tests that drive
  /// [ingestEvents] without starting the daemon (which is where
  /// [_loadOwnIdentity] normally runs). [uuidHex] is the 32-char hex form.
  @visibleForTesting
  void setOwnIdentityForTest(String uuidHex, String nickname) {
    _ownUuidHex = uuidHex;
    _ownNickname = nickname;
  }

  /// Load our own uuid + nickname from the daemon's identity config. Best-effort:
  /// a missing/malformed file just leaves the fields empty (the header falls back
  /// gracefully and the self-filter simply does nothing).
  Future<void> _loadOwnIdentity() async {
    try {
      final f = File('${_daemon.root}/etc/at/identity.cfg.json');
      if (!await f.exists()) return;
      final obj = jsonDecode(await f.readAsString());
      if (obj is Map) {
        final uuid = obj['uuid'];
        if (uuid is String) {
          _ownUuidHex = uuid.replaceAll('-', '').toLowerCase();
        }
        final nick = obj['nickname'];
        if (nick is String) _ownNickname = nick;
      }
    } catch (_) {
      // Best-effort: leave own identity empty on any read/parse error.
    }
  }

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
    _tend(peer);
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
      _tend(peer);
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
    _tend(peer, now);
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

  /// Ask [peers] to co-sign one staff-roll or guardianship record (Phase 3
  /// P3.3). [bytes] is the exchange exactly as Ethne exported it — pass it
  /// through UNCHANGED; the signatures are over these bytes, so re-encoding
  /// them yields signatures over nothing.
  ///
  /// No private key travels and no description travels: each signer's own node
  /// derives what the bytes commit to. Returns the shim rc (0 accepted, -2 the
  /// daemon is not bound yet, -1 otherwise).
  int requestCosign(
    List<AgoraPeer> peers, {
    required String record,
    required String op,
    required String polityDid,
    required String cid,
    required String bytes,
  }) {
    if (peers.isEmpty) return -1;
    final ev = _events;
    if (ev == null) return -1;
    return ev.requestCosign(
      _daemon.queues.appToAt,
      peers.map((p) => p.uuid).toList(growable: false),
      record: record,
      op: op,
      polityDid: polityDid,
      cid: cid,
      bytes: bytes,
    );
  }

  /// Return this node's detached signature to the peer authoring an exchange
  /// (Phase 3 P3.3). Sign only after deriving, on this node, what the bytes
  /// actually commit to. Returns the shim rc.
  int returnCosign(
    AgoraPeer requester, {
    required String cid,
    required String signerDid,
    required String sigHex,
  }) {
    final ev = _events;
    if (ev == null) return -1;
    return ev.returnCosign(
      _daemon.queues.appToAt,
      requester.uuid,
      cid: cid,
      signerDid: signerDid,
      sigHex: sigHex,
    );
  }

  /// The merged feed, newest/strongest first (Increment 7, extended by Phase 3
  /// P3.4). ONE feed, two kinds of item: a person's post weighted by TIE
  /// STRENGTH (the Inc-4 Dunbar kernel) and a business's weighted by its
  /// DIRECTORY STANDING (distance, then customers you trust who vouched, then
  /// how current our knowledge of it is), each multiplied by that post's own
  /// freshness.
  ///
  /// The two ledgers stay separate, which is P3.2's locked decision surviving
  /// into the feed: a business cannot crowd out your friends by posting, and
  /// cannot buy its way up at all — only people you already trust having been
  /// there lifts it.
  List<FeedEntry> get feed {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    return rankFeed(
      posts: _feed.posts,
      businessPosts: _businessPosts.posts,
      strengthOfAuthor: _strengthOfAuthor,
      standingOfBusiness: _standingOfBusiness,
      nameOfBusiness: _nameOfBusiness,
      recency: (ts) => _feed.recency(ts, now),
      isHiddenAuthor: isBlockedUuid,
    );
  }

  /// True iff the peer with [uuid] is locally blocked, as the core reports it.
  bool isBlockedUuid(List<int> uuid) => _peers[_hex(uuid)]?.blocked ?? false;

  /// How many held posts the feed is hiding because their author is blocked —
  /// shown so a block never reads as "nothing arrived". Counted, not deleted:
  /// unblocking restores them at once.
  int get feedHiddenByBlock => _feed.posts
      .where((p) => !p.outgoing && isBlockedUuid(p.authorUuid))
      .length;

  /// Total items held across both feed stores.
  int get feedCount => _feed.length + _businessPosts.length;

  /// How many business posts were refused by envoy verification — including
  /// every one of them when the Ethne library is missing. The feed shows this
  /// so silence is never mistaken for nothing having arrived.
  int get businessPostsUnverified => _businessPosts.unverifiedCount;

  /// The directory standing of the business behind a post, in [0,1]; 0 for a
  /// polity we hold no page for (which the core should have dropped anyway, so
  /// this is the second of two independent refusals rather than the only one).
  double _standingOfBusiness(String polity) {
    final b = _businesses[polity];
    if (b == null) return 0.0;
    return _businesses.score(
      b,
      strengthOfAdvertiser: _strengthOfAuthor,
      ownGeohash: _ownGeohash,
      nowEpochSeconds: DateTime.now().millisecondsSinceEpoch / 1000.0,
    );
  }

  /// The business's name off its VERIFIED page, or '' when we hold no page —
  /// in which case the UI shows the DID rather than inventing a name.
  String _nameOfBusiness(String polity) =>
      _businesses[polity]?.page?.name ?? '';

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

  /// Publish a business post — the polity speaking (Phase 3 P3.4). [bundle] is
  /// the OPAQUE Ethne {post,delegation} artifact the caller built and
  /// ENVOY-signed; this node signs the wire copy and the core multicasts it.
  ///
  /// The post is echoed locally IMMEDIATELY, like a person's, but only after
  /// it verifies: an operator who has just signed something unverifiable
  /// should see that at once, on their own screen, rather than learn it from
  /// the silence of everyone else's. Returns the shim rc (0 ok, -2 daemon not
  /// ready), or -1 if no channel is open, the arguments are empty, or the
  /// bundle does not verify.
  int publishBusinessPost(String polityDid, String bundle, {int seq = 0}) {
    if (polityDid.isEmpty || bundle.isEmpty) return -1;
    if (!_verifyBusinessPostBundle(bundle)) {
      _businessPosts.recordUnverified();
      notifyListeners();
      return -1;
    }
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    _businessPosts.add(BusinessPost(
      polity: polityDid,
      postId: '', // the core computes the real content id; not returned here
      seq: seq,
      ts: now,
      hops: 0,
      bundle: bundle,
      outgoing: true,
    ));
    final ev = _events;
    if (ev == null) {
      notifyListeners();
      return -1;
    }
    final rc = ev.publishBusinessPost(_daemon.queues.appToAt, polityDid, bundle,
        seq: seq);
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
      _tend(author);
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

  // --- moderation (Phase 4 P4.1) --------------------------------------------

  /// This device's moderation memory: why the operator reported whom, and the
  /// advisory daily count. Persisted in [start]; in-memory until then.
  ModerationStore? _moderationStore;
  ModerationState _moderationFallback = ModerationState();
  ModerationState get moderation =>
      _moderationStore?.state ?? _moderationFallback;

  @visibleForTesting
  set moderationForTest(ModerationState s) => _moderationFallback = s;

  /// Locally block [peer]: the core clamps their effective tier to 0 on this
  /// node, drops their directed traffic and hides their posts. Nothing crosses
  /// the wire. The block becomes VISIBLE when the core re-emits the peer with
  /// `blocked` set — not here, so the UI never shows a block that did not land.
  /// Returns the shim rc (0 queued, -2 not ready, -1 no channel).
  int blockPeer(AgoraPeer peer) {
    final rc = _moderationVerbs.block(peer.uuid);
    notifyListeners();
    return rc;
  }

  /// Lift a local block. The peer is told nothing, as they were told nothing
  /// of the block. Returns the shim rc.
  int unblockPeer(AgoraPeer peer) {
    final rc = _moderationVerbs.unblock(peer.uuid);
    notifyListeners();
    return rc;
  }

  /// True when the Report action should be offered for [peer] now (the
  /// advisory cap; the core's own check is the authority).
  bool canReport(AgoraPeer peer) =>
      moderation.canReport(_hex(peer.uuid), _nowSec());

  /// Report [peer] for [reason]. The REASON STAYS ON THIS DEVICE — the core is
  /// sent the peer and nothing else. Returns [reportRefusedCap] without sending
  /// when this device already reported them today, else the shim rc; the
  /// reason is remembered only once the core has the ask on its queue.
  ///
  /// A report does not block, and blocking does not stop a report.
  int reportPeer(AgoraPeer peer, ReportReason reason) {
    final key = _hex(peer.uuid);
    final now = _nowSec();
    if (!moderation.canReport(key, now)) return reportRefusedCap;
    final rc = _moderationVerbs.report(peer.uuid);
    if (rc == 0) {
      moderation.recordReport(key, reason, now);
      _moderationStore?.save();
    }
    notifyListeners();
    return rc;
  }

  /// "Block · Report · Both": two verbs, never one with a hidden second
  /// effect. Reports first so a refused report is reported back to the
  /// operator rather than masked by a block that went through. Returns the
  /// report's rc when it failed, else the block's.
  int blockAndReport(AgoraPeer peer, ReportReason reason) {
    final rrc = reportPeer(peer, reason);
    final brc = blockPeer(peer);
    return rrc != 0 ? rrc : brc;
  }

  /// Peers this node has blocked, for the blocked list.
  List<AgoraPeer> get blockedPeers =>
      _peers.values.where((p) => p.blocked).toList()
        ..sort((a, b) => a.displayLabel.compareTo(b.displayLabel));

  /// Peers bounded by an authority finding — the only place the generalized
  /// ceiling is legible as itself rather than as a low tier.
  List<AgoraPeer> get standingBoundedPeers =>
      _peers.values.where((p) => p.isStandingBounded).toList()
        ..sort((a, b) => a.displayLabel.compareTo(b.displayLabel));

  /// Hand the core the consequence of an expulsion that has ALREADY LANDED in
  /// the polity's log: a ceiling, never a score. Callers must only call this
  /// after the signed act verified — see [StaffRosterPage]'s expel flow.
  int applyExpulsionStanding(AgoraPeer peer, {String reason = 'expelled'}) =>
      _moderationVerbs.peerStanding(peer.uuid,
          standing: 'capped', ceiling: ethneExpelCeiling, reason: reason);

  /// Reinstate: lift the community's ceiling, and nothing else — any other
  /// authority's bound on the peer stays.
  int liftExpulsionStanding(AgoraPeer peer, {String reason = 'reinstated'}) =>
      _moderationVerbs.peerStanding(peer.uuid,
          standing: 'proved', ceiling: -1, reason: reason);

  static double _nowSec() => DateTime.now().millisecondsSinceEpoch / 1000.0;

  /// Pull a FRESH attendance attestation from [peer] NOW (Phase 2, presence):
  /// asks the core to issue a nonce-fresh operator_attest_query. The refreshed
  /// operator_attested_at (and thus the presence dot) arrives on the next
  /// peer-observed event, not synchronously. Returns the shim rc (0 ok, -2
  /// daemon not ready), or -1 if no channel is open yet.
  int pingPresence(AgoraPeer peer) {
    final ev = _events;
    if (ev == null) return -1;
    return ev.requestAttend(_daemon.queues.appToAt, peer.uuid);
  }

  /// Run a private-proximity probe against [peer] (Phase 2): the coarse distance
  /// band arrives later as a proximity event and updates [AgoraPeer.proximityBand].
  /// Only meaningful for a CONNECTED peer (the core refuses others). Returns the
  /// shim rc (0 ok, -2 daemon not ready), or -1 if no channel is open yet.
  int requestProximity(AgoraPeer peer) {
    final ev = _events;
    if (ev == null) return -1;
    return ev.requestProximity(_daemon.queues.appToAt, peer.uuid);
  }

  /// This node's opt-in EXACT-position state (Phase 2). Local-only in the core;
  /// kept here so the UI can reflect whether sharing is on.
  bool _ownExactOptIn = false;
  double _ownExactLat = 0;
  double _ownExactLon = 0;
  bool get ownExactOptIn => _ownExactOptIn;

  /// Opt in to (or out of, [optIn] false) sharing an EXACT position for private-
  /// proximity probes with connected peers. Stored LOCAL-ONLY by the core and
  /// never advertised. Remembered so it is pushed once the channel opens.
  /// Returns the shim rc (0 ok, -2 daemon not ready), or -1 if no channel yet.
  int setOwnExactPosition({required bool optIn, double lat = 0, double lon = 0}) {
    _ownExactOptIn = optIn;
    _ownExactLat = optIn ? lat : 0;
    _ownExactLon = optIn ? lon : 0;
    final ev = _events;
    if (ev == null) {
      notifyListeners();
      return -1;
    }
    final rc = ev.setExactPosition(_daemon.queues.appToAt,
        optIn: optIn, lat: _ownExactLat, lon: _ownExactLon);
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
    // The core already drops a blocked peer's reaction; this is the second of
    // two refusals. Not tallied, not tended.
    if (isBlockedUuid(e.uuid)) return true;
    if (e.reactionPostId.isNotEmpty) {
      _reactionCounts.update(e.reactionPostId, (c) => c + 1, ifAbsent: () => 1);
    }
    final peer = _peers[_hex(e.uuid)];
    if (peer != null) {
      _tend(peer);
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
    _peers.putIfAbsent(_hex(e.uuid), () => _newPeer(e.uuid));
    _feed.add(Post.fromEvent(e));
    return true;
  }

  /// Route one decoded business-ad event into the directory (Phase 3 P3.2).
  /// Returns true if the event was a business ad (consumed here rather than by
  /// [AgoraPeer.applyEvent]).
  ///
  /// The advertiser is put on the roster first, because the vouch term is
  /// weighted by the tie strength to whoever vouched — a recommendation is only
  /// as good as your relationship with the person making it, so we have to be
  /// able to place them.
  bool _ingestBusinessAd(AtRawEvent e) {
    if (e.kind != agoraEventBusinessAd) return false;
    _peers.putIfAbsent(_hex(e.uuid), () => _newPeer(e.uuid));
    _businesses.add(BusinessAd.fromEvent(e));
    return true;
  }

  /// A business post (Phase 3 P3.4). The core verified that these bytes arrived
  /// unaltered from the peer that sent them — no more than that. The peer is a
  /// CARRIER: a post relays, so it is routinely handed on by someone with no
  /// standing to speak for the business at all, and even a member of its staff
  /// has none. The envoy signature inside the bundle is the authority, and it
  /// is checked HERE, before a word of the post can reach the feed.
  ///
  /// A post that fails is counted, not shown. Silence with a number beside it
  /// is honest; unauthenticated text under a business's name is not.
  bool _ingestBusinessPost(AtRawEvent e) {
    if (e.kind != agoraEventBusinessPost) return false;
    _peers.putIfAbsent(_hex(e.uuid), () => _newPeer(e.uuid));
    final post = BusinessPost.fromEvent(e);
    if (!_verifyBusinessPostBundle(post.bundle)) {
      _businessPosts.recordUnverified();
      return true;
    }
    _businessPosts.add(post);
    return true;
  }

  /// An inbound ask to co-sign a governance act (Phase 3 P3.3). A live exchange
  /// like a DM, not peer state, so it is routed here rather than merged by
  /// applyEvent. Everything it carries is a CLAIM: the core is a courier that
  /// holds no Ethne, so nothing upstream has read these bytes. The wording is
  /// derived locally, on demand, before anyone is asked to sign.
  bool _ingestCosignRequest(AtRawEvent e) {
    if (e.kind != agoraEventCosignRequest) return false;
    _peers.putIfAbsent(_hex(e.uuid), () => _newPeer(e.uuid));
    _cosign.addRequest(CosignExchange.fromEvent(e));
    return true;
  }

  /// A signature returned for an act this node asked about. The core cannot
  /// check it — it does not hold the payload — so it is collected here and
  /// proven only when Ethne assembles the record.
  bool _ingestCosignSignature(AtRawEvent e) {
    if (e.kind != agoraEventCosignSignature) return false;
    _peers.putIfAbsent(_hex(e.uuid), () => _newPeer(e.uuid));
    _cosign.addSignature(CosignSignature.fromEvent(e));
    return true;
  }

  /// Verify an opaque Ethne page bundle through the cdylib: does it prove
  /// polity-root → envoy → page? Opens the library on first use.
  ///
  /// When Ethne is unavailable this returns FALSE rather than waving the page
  /// through. Nothing else in the system checks the bundle — the AT core carries
  /// it as bytes — so an unverifiable page is one nobody has vouched for in the
  /// only way that counts.
  bool _verifyBusinessBundle(String bundleJson) {
    final override = _bundleVerifierOverride;
    if (override != null) return override(bundleJson);
    final e = _ethneLib();
    if (e == null) return false;
    try {
      return e.verifyBusinessPageBundle(bundleJson);
    } on Object {
      return false;
    }
  }

  /// Verify a business POST's bundle: polity root -> envoy -> post, with no
  /// charter log, which is what a reader holds. Same shape as
  /// [_verifyBusinessBundle] and same honesty about failure — no library, no
  /// verification, and therefore no post. The test override applies to both,
  /// so a suite that fakes one is not silently trusting the other.
  bool _verifyBusinessPostBundle(String bundleJson) {
    final override = _bundleVerifierOverride;
    if (override != null) return override(bundleJson);
    final e = _ethneLib();
    if (e == null) return false;
    try {
      return e.verifyBusinessPostBundle(bundleJson);
    } on Object {
      return false;
    }
  }

  /// The Ethne cdylib, opened on first use and remembered, including the
  /// failure: a library that was not built does not become built by asking
  /// again. Null when it could not be loaded.
  EthneFfi? _ethneLib() {
    if (!_ethneTried) {
      _ethneTried = true;
      try {
        _ethne = EthneFfi.open();
      } on Object {
        _ethne = null;
      }
    }
    return _ethne;
  }

  /// Businesses ranked for "near me" (Phase 3 P3.2): distance from this node's
  /// own coarse bucket, then who you trust that vouched, then freshness.
  List<Business> get businesses => _businesses.ranked(
        strengthOfAdvertiser: _strengthOfAuthor,
        ownGeohash: _ownGeohash,
        nowEpochSeconds: DateTime.now().millisecondsSinceEpoch / 1000.0,
      );

  /// Total businesses held.
  int get businessCount => _businesses.length;

  /// How many ads were dropped because their page bundle could not be verified
  /// — including every ad, when the Ethne library is missing. The UI shows this
  /// so an empty directory is never read as "no businesses nearby".
  int get businessesUnverified => _businesses.rejectedUnverified;

  /// The ranking score for [business], for the UI to render alongside the entry.
  double businessScore(Business business) => _businesses.score(
        business,
        strengthOfAdvertiser: _strengthOfAuthor,
        ownGeohash: _ownGeohash,
        nowEpochSeconds: DateTime.now().millisecondsSinceEpoch / 1000.0,
      );

  /// This node's own declared satisfaction with [polityDid] (0..4), or null when
  /// it holds no customer edge — and so carries nothing for that business.
  int? customerSatisfaction(String polityDid) => _customerSatisfaction[polityDid];

  /// Publish THIS node's own business page (Phase 3 P3.2). [bundle] is the
  /// opaque self-verifying Ethne artifact the app built through Ethne. Returns
  /// the shim rc (0 ok, -2 daemon not ready), or -1 if no channel is open or the
  /// arguments are empty.
  ///
  /// This reaches one group. The page travels further only as customers
  /// re-advertise it — a business cannot buy reach it has not earned.
  int advertiseBusiness(String polityDid, String bundle, {int seq = 0}) {
    if (polityDid.isEmpty || bundle.isEmpty) return -1;
    final ev = _events;
    if (ev == null) return -1;
    final rc =
        ev.advertiseBusiness(_daemon.queues.appToAt, polityDid, bundle, seq: seq);
    notifyListeners();
    return rc;
  }

  /// Declare or update THIS node's CUSTOMER edge to [polityDid] at
  /// [satisfaction] (0..4). The edge is what authorizes this node to carry the
  /// page: the core caches the bundle and re-advertises it in the FIRST PERSON
  /// with our own satisfaction. Passing an empty [bundle] carries the page we
  /// already learned, so a person can vouch straight from a page that reached
  /// them through someone else. Returns the shim rc, or -1 if no channel is open.
  int markCustomer(String polityDid, int satisfaction,
      {String bundle = '', int seq = 0}) {
    if (polityDid.isEmpty) return -1;
    final sat = satisfaction.clamp(0, 4);
    final known = _businesses[polityDid];
    final carry = bundle.isNotEmpty ? bundle : (known?.bundle ?? '');
    final carrySeq = bundle.isNotEmpty ? seq : (known?.seq ?? seq);
    _customerSatisfaction[polityDid] = sat;
    final ev = _events;
    if (ev == null) {
      notifyListeners();
      return -1;
    }
    final rc = ev.setCustomer(_daemon.queues.appToAt, polityDid,
        satisfaction: sat, bundle: carry, seq: carrySeq);
    notifyListeners();
    return rc;
  }

  /// Withdraw this node's customer edge to [polityDid]. This node simply goes
  /// QUIET about the business — it stops carrying the page. Nothing negative is
  /// published, so there is nothing to brigade with; silence is the only
  /// negative signal the design has.
  int clearCustomer(String polityDid) {
    if (polityDid.isEmpty) return -1;
    _customerSatisfaction.remove(polityDid);
    final ev = _events;
    if (ev == null) {
      notifyListeners();
      return -1;
    }
    final rc =
        ev.setCustomer(_daemon.queues.appToAt, polityDid, satisfaction: -1);
    notifyListeners();
    return rc;
  }

  /// Route one decoded DM event into the per-peer thread. Appends an incoming
  /// message (deduped by (peer, seq)), stamps interaction recency on the peer
  /// (a received DM tends the tie), and flags it unread. Returns true if the
  /// event was a DM (consumed here rather than by [AgoraPeer.applyEvent]).
  bool _ingestDm(AtRawEvent e) {
    if (e.kind != agoraEventDm) return false;
    final key = _hex(e.uuid);
    // The core drops a blocked peer's DMs before they get here; should one
    // arrive anyway, it is dropped and COUNTED, never silently shown.
    if (_peers[key]?.blocked ?? false) {
      _dmsDroppedFromBlocked++;
      return true;
    }
    final peer = _peers.putIfAbsent(key, () => _newPeer(e.uuid));
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
      _tend(peer);
    }
    return true;
  }

  int _dmsDroppedFromBlocked = 0;

  /// DMs dropped here because their sender is blocked. Should stay 0 — the core
  /// drops them first — so a non-zero count is worth seeing.
  int get dmsDroppedFromBlocked => _dmsDroppedFromBlocked;

  /// Peers ordered by tie strength (§3.2) descending — the proximity-weighted
  /// social ranking that makes local, tended, trusted ties surface first. Ties
  /// break by topology rank then a stable id, so the order is deterministic.
  /// The strength itself is exposed via [strengthOf] for the UI.
  ///
  /// Blocked peers STAY in the roster and sort last (Phase 4 P4.1). A blocked
  /// neighbour vanishing would be a lie about who is on the segment, and the
  /// operator has to be able to find them to unblock.
  List<AgoraPeer> get peers {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final list = _peers.values.toList();
    list.sort((a, b) {
      if (a.blocked != b.blocked) return a.blocked ? 1 : -1;
      final sa = tieStrength(a,
          ownGeohash: _ownGeohash, nowEpochSeconds: now, weights: _weights);
      final sb = tieStrength(b,
          ownGeohash: _ownGeohash, nowEpochSeconds: now, weights: _weights);
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
        weights: _weights,
      );

  /// The attention-budget ledger over this node's strong ties (§3.3): how much
  /// of the budget the tended, proximity-weighted connections consume, and which
  /// weakest ties are over the line (advisory — never severed). The UI reads this
  /// for the "stretched" indicator and to fade over-budget tiles.
  ///
  /// Blocked peers are left out: a blocked tie is not an attended tie, and it
  /// must not spend budget or be the tie the ledger fades.
  BudgetLedger get budgetLedger => BudgetLedger.compute(
        _peers.values.where((p) => !p.blocked),
        ownGeohash: _ownGeohash,
        nowEpochSeconds: DateTime.now().millisecondsSinceEpoch / 1000.0,
        weights: _weights,
        params: budgetParams,
      );

  // --- the staff surface (Phase 3 P3.3) -------------------------------------

  /// Open the stored charter log through the cdylib. Best-effort: with no
  /// identity, no cdylib, or an unreadable dump, this node simply reads no roll
  /// — which the surface reports as having none, not as an error.
  void _openPolityArchive() {
    _polityArchive?.dispose();
    _polityArchive = null;
    _affirmationState = null;
    _guardianStateMap = null;
    _polityVerified = null;
    final id = _staff?.identity;
    final lib = _ethneLib();
    if (id == null || lib == null) return;
    try {
      _polityArchive = lib.loadArchive(jsonEncode(id.archive));
    } on Object {
      _polityArchive = null;
    }
  }

  /// The polity this node is staff of, or null when it is staff of none.
  String? get ownPolityDid =>
      _staffOverride?.polityDid ?? _staff?.identity?.polityDid;

  /// The keypair this node signs governance acts with. Null when this node is
  /// not staff anywhere — in which case it can read a roll but not co-sign.
  EthneKeypair? get staffIdentity =>
      _staffOverride?.self ?? _staff?.identity?.self;

  /// The roll of [ownPolityDid], folded for display, or null when there is no
  /// polity on this node or its log could not be read.
  ///
  /// The two state maps are read once per archive and re-folded on each call so
  /// the attendance judgment tracks the clock. Twenty-four hours is this app's
  /// threshold and nothing deeper: the stamp itself is carried through unreduced.
  StaffRoster? get staffRoster {
    final override = _rosterOverride;
    if (override != null) return override;
    if (!_readPolityState()) return null;
    return StaffRoster.from(
      affirmation: _affirmationState!,
      guardian: _guardianStateMap!,
      nowEpochSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      verified: _polityVerified,
    );
  }

  /// Read the polity's state maps across the FFI, once. Returns whether they are
  /// in hand.
  bool _readPolityState() {
    if (_affirmationState != null && _guardianStateMap != null) return true;
    final arc = _polityArchive;
    final polity = _staff?.identity?.polityDid;
    if (arc == null || polity == null) return false;
    try {
      _affirmationState = arc.affirmationState(polity);
      _guardianStateMap = arc.guardianState(polity);
      // The fold reports what the log CLAIMS; this is the adjudication that sits
      // beside it, and the UI shows both.
      _polityVerified = arc.verify();
    } on Object {
      _affirmationState = null;
      _guardianStateMap = null;
      _polityVerified = null;
      return false;
    }
    return true;
  }

  /// The POLITY's own keypair, held only by the node that publishes its roll.
  /// Null nearly everywhere, which is the ordinary case.
  EthneKeypair? get polityRootKey =>
      _staffOverride?.root ?? _staff?.identity?.root;

  /// Whether this node can publish the polity's roll at all. Publishing is
  /// signing under the polity's ROOT key, so only its holder can — and nothing
  /// compels a polity to publish in the first place.
  bool get canPublishRoll =>
      _rollPublisherOverride != null ||
      (polityRootKey != null && _polityArchive != null);

  /// The last roll minted on this node, with what could be established about it.
  /// Held in memory only: publication is the polity's act, and this app is not a
  /// place a roll is kept on anyone's behalf.
  PublishedRoll? get publishedRoll => _publishedRoll;
  PublishedRoll? _publishedRoll;

  /// Mint the polity's roll under its root key, then check it BOTH ways and keep
  /// the two answers apart. Returns whether an artifact was produced.
  ///
  /// Nothing is sent anywhere. No compact tier is wired up here, so publishing
  /// means minting the artifact and checking it; handing it to a consumer is not
  /// something this app does.
  bool publishRoll() {
    final override = _rollPublisherOverride;
    if (override != null) {
      final r = override();
      if (r == null) return false;
      _publishedRoll = r;
      notifyListeners();
      return true;
    }
    final arc = _polityArchive;
    final polity = ownPolityDid;
    final root = polityRootKey;
    if (arc == null || polity == null || root == null) return false;
    try {
      final json = arc.signMemberRoll(polityDid: polity, root: root);
      _publishedRoll = PublishedRoll(
        rollJson: json,
        // What a compact tier could establish on its own…
        publisherProven: _ethneLib()?.verifyMemberRoll(json) ?? false,
        // …and what only a holder of the log can.
        auditedAgainstLog: arc.verifyMemberRollFull(json),
      );
    } on Object {
      return false;
    }
    notifyListeners();
    return true;
  }

  /// Co-signature asks waiting on this node, newest first.
  List<CosignExchange> get pendingCosigns => _cosign.pending;

  /// What [e] actually commits to, derived on THIS node from its bytes. Null
  /// when they cannot be read as the record class they claim — a reason to
  /// refuse, never a reason to fall back to what the asker said it was.
  Map<String, dynamic>? describeCosign(CosignExchange e) => _cosign.describe(e);

  /// Signatures returned for the act [cid].
  List<CosignSignature> cosignSignatures(String cid) =>
      _cosign.signaturesFor(cid);

  Map<String, dynamic>? _describeCosignBytes(String record, String bytesHex) {
    final override = _cosignDescriberOverride;
    if (override != null) return override(record, bytesHex);
    final e = _ethneLib();
    if (e == null) return null;
    try {
      return e.describe(
        record: record.isEmpty ? null : record,
        bytesHex: bytesHex,
      );
    } on Object {
      return null;
    }
  }

  /// Sign [e] with this node's own key and return the signature to whoever
  /// asked. Returns whether a signature went out.
  ///
  /// The key never leaves this process: signDetached takes the bytes and the
  /// key and nothing else — no archive, no polity, no network.
  bool signCosign(CosignExchange e) {
    final id = staffIdentity;
    final lib = _ethneLib();
    if (id == null || lib == null) return false;
    final peer = _peers[_hex(e.requesterUuid)];
    if (peer == null) return false;
    final String sig;
    try {
      sig = lib.signDetached(priv: id.priv, bytesHex: e.bytes);
    } on Object {
      return false;
    }
    if (returnCosign(peer, cid: e.cid, signerDid: id.did, sigHex: sig) < 0) {
      return false;
    }
    _cosign.settle(e.cid);
    notifyListeners();
    return true;
  }

  // --- expulsion, initiated here (Phase 4 P4.1) ------------------------------

  PolityActs? get _polityActs {
    final o = _polityActsOverride;
    if (o != null) return o;
    final arc = _polityArchive;
    final lib = _ethneLib();
    final self = staffIdentity;
    if (arc == null || lib == null || self == null) return null;
    return _ArchivePolityActs(arc, lib, self);
  }

  /// Whether this node can start an expulsion: it is staff of a polity and can
  /// read and sign its log.
  bool get canExpel => ownPolityDid != null && _polityActs != null;

  /// Why the last expulsion step was refused, in the library's words.
  String? get lastExpulsionError => _lastExpulsionError;
  String? _lastExpulsionError;

  /// Expulsions this node started, newest first.
  List<AuthoredExchange> get authoredExchanges => _cosign.authored;

  /// Start expelling [memberDid]: open the exchange, sign this node's own
  /// share if it is a decider, and ask [askPeers] for theirs.
  ///
  /// [targetPeer] is the peer the operator says IS this member, or null. There
  /// is no DID→peer mapping, so it is a manual pick; nothing is done with it
  /// until the act has landed (see [completeExpulsion]).
  ///
  /// Returns the exchange, or null with [lastExpulsionError] set.
  AuthoredExchange? beginExpulsion({
    required String memberDid,
    required String rationale,
    required List<String> deciderDids,
    required List<AgoraPeer> askPeers,
    AgoraPeer? targetPeer,
  }) {
    _lastExpulsionError = null;
    final acts = _polityActs;
    final polity = ownPolityDid;
    if (acts == null || polity == null) {
      _lastExpulsionError = 'This node cannot sign for a polity.';
      return null;
    }
    final Map<String, dynamic> pending;
    try {
      pending = acts.pendingExpel(
        polityDid: polity,
        memberDid: memberDid,
        rationale: rationale,
        deciderDids: deciderDids,
      );
    } on Object catch (e) {
      _lastExpulsionError = '$e';
      notifyListeners();
      return null;
    }
    final ax = AuthoredExchange.fromPending(pending,
        memberDid: memberDid,
        createdAt: _nowSec(),
        targetPeerUuid: targetPeer?.uuid);
    final own = staffIdentity?.did;
    final othersNeeded = ax.signersRequired.any((d) => d != own);
    if (othersNeeded && askPeers.isEmpty) {
      _lastExpulsionError = 'Pick at least one peer to ask for a signature.';
      notifyListeners();
      return null;
    }
    // This node's own share, signed where its key lives.
    if (own != null && ax.signersRequired.contains(own)) {
      try {
        _cosign.addSignature(CosignSignature(
            cid: ax.cid, signerDid: own, sig: acts.signOwn(ax.bytes), ts: 0));
      } on Object catch (e) {
        _lastExpulsionError = '$e';
        notifyListeners();
        return null;
      }
    }
    if (othersNeeded) {
      final rc = _moderationVerbs.requestCosign(
          [for (final p in askPeers) p.uuid],
          record: ax.record,
          op: ax.op,
          polityDid: ax.polityDid,
          cid: ax.cid,
          bytes: ax.bytes);
      if (rc != 0) {
        _lastExpulsionError = rc == -2
            ? 'Not connected yet — the ask was not sent.'
            : 'The ask could not be sent.';
        notifyListeners();
        return null;
      }
    }
    _cosign.addAuthored(ax);
    notifyListeners();
    return ax;
  }

  /// Signatures counted toward [ax] so far.
  List<CosignSignature> countedSignatures(AuthoredExchange ax) =>
      ax.countedFrom(_cosign.signaturesFor(ax.cid));

  /// Whether every required signer has signed [ax].
  bool expulsionReady(AuthoredExchange ax) =>
      ax.status == AuthoredStatus.collecting &&
      ax.readyFrom(_cosign.signaturesFor(ax.cid));

  /// Close [ax], in the order the decision requires:
  ///
  ///   1. assemble the signatures onto the payload EXACTLY as it was returned;
  ///   2. re-read the log and re-verify — the act must verify AND the member
  ///      must be gone from the roll;
  ///   3. only then persist the log, and
  ///   4. only then hand the core the reputation consequence.
  ///
  /// The reputation consequence follows the decision landing in the log, never
  /// the intent. A log that did not verify after the append is discarded, not
  /// saved, and nothing is sent to the core. Returns whether the act landed.
  bool completeExpulsion(AuthoredExchange ax) {
    _lastExpulsionError = null;
    final acts = _polityActs;
    if (acts == null || !expulsionReady(ax)) {
      _lastExpulsionError = 'Not every decider has signed yet.';
      notifyListeners();
      return false;
    }
    final sigs = countedSignatures(ax);
    try {
      acts.assemble(
          ax.payload, [for (final s in sigs) (did: s.signerDid, sig: s.sig)]);
    } on Object catch (e) {
      return _expulsionFailed(ax, '$e');
    }
    // The cached fold describes the log BEFORE the append.
    _affirmationState = null;
    _guardianStateMap = null;
    _polityVerified = null;
    final bool verified;
    final bool stillOnRoll;
    try {
      verified = acts.verify();
      stillOnRoll = acts.rollDids(ax.polityDid).contains(ax.memberDid);
    } on Object catch (e) {
      _openPolityArchive(); // drop the unverified append
      return _expulsionFailed(ax, '$e');
    }
    if (!verified || stillOnRoll) {
      _openPolityArchive();
      return _expulsionFailed(
          ax,
          !verified
              ? 'The log did not verify after the append; nothing was kept.'
              : 'The member is still on the roll; nothing was kept.');
    }
    try {
      final dump = acts.dump();
      _staff?.updateArchive(dump);
      _staff?.save();
    } on Object {
      // The act landed in memory; losing durability is reported by the save.
    }
    ax.status = AuthoredStatus.landed;
    final target = ax.targetPeerUuid;
    if (target != null) {
      ax.standingRc = _moderationVerbs.peerStanding(target,
          standing: 'capped',
          ceiling: ethneExpelCeiling,
          reason: 'expelled from ${ax.polityDid}');
    }
    notifyListeners();
    return true;
  }

  bool _expulsionFailed(AuthoredExchange ax, String why) {
    ax.status = AuthoredStatus.failed;
    ax.error = why;
    _lastExpulsionError = why;
    notifyListeners();
    return false;
  }

  /// Decline [e]. NOTHING is sent: a refusal is silence, the same posture the
  /// unhappy customer takes. The ask is settled so a replay does not raise it
  /// again.
  void declineCosign(CosignExchange e) {
    _cosign.settle(e.cid);
    notifyListeners();
  }

  Future<void> start() async {
    _setStatus('starting daemon…');
    await _daemon.start();

    // Learn our own identity (nickname + uuid) from the daemon's config, for the
    // window header and the self-filter below. Best-effort; never fatal.
    await _loadOwnIdentity();

    // Load per-user tuning + durable last-interaction (Phase 2, §3.3), from a
    // small JSON file under the config root. Best-effort — defaults on any error.
    _settings = await TieSettingsStore(
            File('${_daemon.root}/etc/at/agora.settings.json'))
        .load();
    // Why the operator reported whom (Phase 4 P4.1). Local-only; the core never
    // sees a reason.
    _moderationStore = await ModerationStore(
            File('${_daemon.root}/etc/at/agora.moderation.json'))
        .load();

    // This node's staff membership, if it has one (Phase 3 P3.3). Staff of no
    // polity is the ordinary case and not an error — the roster surface says so
    // plainly rather than failing.
    _staff = await StaffIdentityStore(
            File('${_daemon.root}/etc/at/agora.polity.json'))
        .load();
    _openPolityArchive();

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
    if (_ownExactOptIn) {
      _events!.setExactPosition(_daemon.queues.appToAt,
          optIn: true, lat: _ownExactLat, lon: _ownExactLon);
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
      // A business ad — routed into the directory after Ethne verification.
      if (_ingestBusinessAd(e)) continue;
      if (_ingestBusinessPost(e)) continue;
      // A co-signature ask, and a signature coming back — a live exchange.
      if (_ingestCosignRequest(e)) continue;
      if (_ingestCosignSignature(e)) continue;
      final key = _hex(e.uuid);
      // Never surface our own identity as a peer. The core already guards this
      // (a `peer_accepted` naming us no longer self-adds), but a stale roster
      // from before that fix, or any other producer, could still emit self —
      // drop it here so the UI never shows a self tile. Cheap defense-in-depth.
      if (_ownUuidHex.isNotEmpty && key == _ownUuidHex) continue;
      final peer = _peers.putIfAbsent(key, () => _newPeer(e.uuid));
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
    _saveTimer?.cancel();
    _saveTimer = null;
    await _settings?.save(); // flush any pending durable-recency writes
    // The staff identity is NOT rewritten here. S8 only reads the log and signs
    // with the key; nothing appends, so there is nothing to flush — and the file
    // holds a private key, which is not worth rewriting for no reason.
    _polityArchive?.dispose();
    _polityArchive = null;
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

/// The polity acts over the cdylib and this node's charter archive.
class _ArchivePolityActs implements PolityActs {
  _ArchivePolityActs(this._arc, this._lib, this._self);
  final EthneArchive _arc;
  final EthneFfi _lib;
  final EthneKeypair _self;

  @override
  Map<String, dynamic> pendingExpel({
    required String polityDid,
    required String memberDid,
    required String rationale,
    required List<String> deciderDids,
  }) =>
      _arc.pendingChange(
          op: 'expel',
          polityDid: polityDid,
          memberDid: memberDid,
          rationale: rationale,
          deciderDids: deciderDids);

  @override
  String signOwn(String bytesHex) =>
      _lib.signDetached(priv: _self.priv, bytesHex: bytesHex);

  @override
  void assemble(Map<String, dynamic> payload,
          List<({String did, String sig})> signatures) =>
      _arc.assembleSigned(payload: payload, signatures: signatures);

  @override
  bool verify() => _arc.verify();

  @override
  List<String> rollDids(String polityDid) {
    final members = _arc.affirmationState(polityDid)['members'];
    if (members is! List) return const [];
    return [
      for (final m in members)
        if (m is Map && m['did'] is String) m['did'] as String,
    ];
  }

  @override
  Map<String, dynamic> dump() =>
      jsonDecode(_arc.dumpJson()) as Map<String, dynamic>;
}

/// The moderation verbs over the shim. -1 while no event channel is open.
class _ShimModerationVerbs implements ModerationVerbs {
  _ShimModerationVerbs(this._svc);
  final PeerService _svc;

  String get _q => _svc._daemon.queues.appToAt;

  @override
  int block(List<int> peerUuid) => _svc._events?.block(_q, peerUuid) ?? -1;

  @override
  int unblock(List<int> peerUuid) => _svc._events?.unblock(_q, peerUuid) ?? -1;

  @override
  int report(List<int> peerUuid) =>
      _svc._events?.reportPeer(_q, peerUuid) ?? -1;

  @override
  int peerStanding(List<int> peerUuid,
          {required String standing,
          required double ceiling,
          required String reason}) =>
      _svc._events?.peerStanding(
          _q, peerUuid, standing, ceiling, standingSourceEthne, reason) ??
      -1;

  @override
  int requestCosign(List<List<int>> peerUuids,
          {required String record,
          required String op,
          required String polityDid,
          required String cid,
          required String bytes}) =>
      _svc._events?.requestCosign(_q, peerUuids,
          record: record,
          op: op,
          polityDid: polityDid,
          cid: cid,
          bytes: bytes) ??
      -1;
}
