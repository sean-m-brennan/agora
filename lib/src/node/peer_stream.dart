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

  /// Peers, strongest rank first (a stand-in ordering until proximity/tie
  /// strength lands with the AT-core event extension — see §5.1).
  List<AgoraPeer> get peers {
    final list = _peers.values.toList();
    list.sort((a, b) => b.rank.compareTo(a.rank));
    return list;
  }

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
  /// sighting; subsequent events (reputation, RTT, position, profile) merge in.
  @visibleForTesting
  void ingestEvents(List<AtRawEvent> batch) {
    if (batch.isEmpty) return;
    for (final e in batch) {
      final key = _hex(e.uuid);
      final peer = _peers.putIfAbsent(key, () => AgoraPeer(uuid: e.uuid));
      peer.applyEvent(e);
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
