// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// dart:ffi bindings for the fork-free AutonomousTrust app-events client,
// exposed through the flat shim in native/at_agora_shim.{h,c}.
//
// Only the client subset (open/poll/request_roster/close) is bound — all
// AF_UNIX socket I/O, no fork(). The heavy AT node runs in the separate
// `agorad` process (see node/agora_daemon.dart).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const int agoraUuidLen = 16;
const int agoraKeyLen = 32;
const int agoraGeohashLen = 12; // must match AGORA_GEOHASH_LEN (at_agora_shim.h)
// must match AGORA_PROFILE_JSON_MAX (at_agora_shim.h)
const int agoraProfileJsonMax = 2560;
// must match AGORA_DM_TEXT_MAX (at_agora_shim.h)
const int agoraDmTextMax = 1024;
// must match AGORA_POST_BODY_MAX (at_agora_shim.h)
const int agoraPostBodyMax = 4096;
// must match AGORA_POST_ID_MAX (at_agora_shim.h)
const int agoraPostIdMax = 64;

const int agoraEventPeer = 1;
const int agoraEventReputation = 2;
const int agoraEventRtt = 3;
const int agoraEventPosition = 4;
const int agoraEventProfile = 5;
const int agoraEventConnectionRequest = 6;
const int agoraEventConnectionState = 7;
const int agoraEventDm = 8;
const int agoraEventPost = 9;
const int agoraEventReaction = 10;
const int agoraEventProximity = 11;

/// dart:ffi mirror of `agora_event_t` (native/at_agora_shim.h). Field order and
/// element counts MUST match the C struct exactly — the layout is the ABI
/// contract, and the C side asserts the lengths against AT's own constants.
final class AgoraEvent extends Struct {
  @Int32()
  external int kind;

  @Array(agoraUuidLen)
  external Array<Uint8> peerUuid;

  @Array(agoraKeyLen)
  external Array<Uint8> signingPubkey;

  @Int32()
  external int rank;

  @Uint8()
  external int operatorBound;

  @Double()
  external double operatorAttestedAt;

  @Array(agoraKeyLen)
  external Array<Uint8> operatorPubkey;

  @Double()
  external double repScore;

  @Uint8()
  external int repRated;

  /// Only meaningful when [kind] == [agoraEventRtt]; 0 = unknown / not yet
  /// measured.
  @Int32()
  external int rttMs;

  /// Peer's shared coarse geohash bucket (NUL-terminated, "" = none). Only
  /// meaningful when [kind] == [agoraEventPosition].
  @Array(agoraGeohashLen + 1)
  external Array<Uint8> geohash;

  /// Peer's shared agora.profile as compact JSON (NUL-terminated UTF-8, "" =
  /// none). Appended LAST to mirror the C `agora_event_t`. Only meaningful when
  /// [kind] == [agoraEventProfile]. The core already verified the signature, so
  /// this is trusted data.
  @Array(agoraProfileJsonMax + 1)
  external Array<Uint8> profileJson;

  /// This node's connection edge state toward the peer (Increment 5): none=0,
  /// pending_out=1, pending_in=2, connected=3, declined=4. Appended LAST to
  /// mirror the C `agora_event_t`. Only meaningful when [kind] is
  /// [agoraEventConnectionRequest] or [agoraEventConnectionState].
  @Int32()
  external int connectionState;

  /// A directed message received from the peer (Increment 6). Appended LAST to
  /// mirror the C `agora_event_t`. Only meaningful when [kind] ==
  /// [agoraEventDm]: [dmSeq] the sender's freshness sequence, [dmTs] the
  /// sender's send time (epoch seconds), [dmText] the NUL-terminated body.
  @Int64()
  external int dmSeq;

  @Double()
  external double dmTs;

  @Array(agoraDmTextMax + 1)
  external Array<Uint8> dmText;

  /// A signed feed post received over the group channel (Increment 7). Appended
  /// LAST to mirror the C `agora_event_t`. Only meaningful when [kind] ==
  /// [agoraEventPost]: [peerUuid] carries the SIGNATURE-BOUND author, [postId] is
  /// the blake2b content-address (dedup key), [postSeq] the author's post
  /// sequence, [postTs] the author's post time (epoch seconds),
  /// [postRequiredTier] the audience floor (0..4), [postBody] the NUL-terminated
  /// body. The core already verified the signature, tier-gated and deduped the
  /// post before it crossed, so this is trusted data; the signature does not
  /// cross.
  @Array(agoraPostIdMax + 1)
  external Array<Uint8> postId;

  @Int64()
  external int postSeq;

  @Double()
  external double postTs;

  @Int32()
  external int postRequiredTier;

  @Array(agoraPostBodyMax + 1)
  external Array<Uint8> postBody;

  /// A reaction to one of THIS node's posts (Increment 8). Appended LAST to
  /// mirror the C `agora_event_t`. Only meaningful when [kind] ==
  /// [agoraEventReaction]: [peerUuid] carries the REACTOR (crypto_box-
  /// authenticated), [reactionPostId] the content-id of the post reacted to,
  /// [reactionSeq] the reactor's freshness sequence, [reactionTs] the reactor's
  /// send time (epoch seconds).
  @Array(agoraPostIdMax + 1)
  external Array<Uint8> reactionPostId;

  @Int64()
  external int reactionSeq;

  @Double()
  external double reactionTs;

  /// AGORA_EVENT_PEER: 1 iff this peer shares OUR group (its address is in our
  /// group's address_map). Appended LAST after reactionTs so every prior field
  /// offset is unchanged; the C `agora_event_t` and the cohort ctypes Ev mirror
  /// this order and total size (8024) exactly.
  @Uint8()
  external int inGroup;

  /// AGORA_EVENT_PROXIMITY: coarse distance band to a CONNECTED peer (0 unknown,
  /// 1 near, 2 mid, 3 far). Appended LAST after inGroup (Phase 2); it occupies
  /// the struct's former tail padding, so the total size stays 8024 and every
  /// prior offset is unchanged. No coordinates cross this boundary.
  @Int32()
  external int proximityBand;
}

/// A pure-Dart copy of one decoded event. Decoupled from native memory so it
/// survives after the poll buffer is freed.
class AtRawEvent {
  AtRawEvent({
    required this.kind,
    required this.uuid,
    required this.signingPubkey,
    required this.rank,
    required this.operatorBound,
    required this.operatorAttestedAt,
    required this.operatorPubkey,
    required this.repScore,
    required this.repRated,
    required this.rttMs,
    this.geohash = '',
    this.profileJson = '',
    this.connectionState = 0,
    this.dmSeq = 0,
    this.dmTs = 0,
    this.dmText = '',
    this.postId = '',
    this.postSeq = 0,
    this.postTs = 0,
    this.postRequiredTier = 0,
    this.postBody = '',
    this.reactionPostId = '',
    this.reactionSeq = 0,
    this.reactionTs = 0,
    this.inGroup = false,
    this.proximityBand = 0,
  });

  final int kind;
  final List<int> uuid;
  final List<int> signingPubkey;
  final int rank;
  final bool operatorBound;
  final double operatorAttestedAt;
  final List<int> operatorPubkey;
  final double repScore;
  final bool repRated;

  /// Latest RTT to the peer in milliseconds; 0 = unknown / not yet measured.
  /// Only set for [agoraEventRtt] events. A network-latency proximity proxy,
  /// not a geographic distance.
  final int rttMs;

  /// Peer's shared coarse geohash bucket ("" = none). Only set for
  /// [agoraEventPosition] events. Opt-in: empty unless the peer chose to share.
  final String geohash;

  /// Peer's shared agora.profile as compact JSON ("" = none). Only set for
  /// [agoraEventProfile] events. Opt-in; already signature-verified by the core.
  final String profileJson;

  /// This node's connection edge state toward the peer (Increment 5): none=0,
  /// pending_out=1, pending_in=2, connected=3, declined=4. Set for
  /// [agoraEventConnectionRequest] and [agoraEventConnectionState] events.
  final int connectionState;

  /// A directed message received from the peer (Increment 6). Set only for
  /// [agoraEventDm] events: [dmSeq] the sender's freshness sequence, [dmTs] the
  /// sender's send time (epoch seconds), [dmText] the message body.
  final int dmSeq;
  final double dmTs;
  final String dmText;

  /// A signed feed post received over the group channel (Increment 7). Set only
  /// for [agoraEventPost] events: [uuid] is the SIGNATURE-BOUND author, [postId]
  /// the blake2b content-address (dedup key), [postSeq] the author's post
  /// sequence, [postTs] the author's post time (epoch seconds),
  /// [postRequiredTier] the audience floor (0..4), [postBody] the body. Already
  /// verified, tier-gated and deduped by the core.
  final String postId;
  final int postSeq;
  final double postTs;
  final int postRequiredTier;
  final String postBody;

  /// A reaction to one of THIS node's posts (Increment 8). Set only for
  /// [agoraEventReaction] events: [uuid] is the REACTOR, [reactionPostId] the
  /// content-id of the post reacted to, [reactionSeq] the reactor's freshness
  /// sequence, [reactionTs] the reactor's send time (epoch seconds).
  final String reactionPostId;
  final int reactionSeq;
  final double reactionTs;

  /// AGORA_EVENT_PEER: true iff this peer shares OUR group. Surfaced by the UI
  /// as an "in your group" indicator, distinct from an explicit connection edge.
  final bool inGroup;

  /// AGORA_EVENT_PROXIMITY: coarse distance band to a CONNECTED peer (Phase 2):
  /// 0 unknown, 1 near (~1km), 2 mid (~5km), 3 far. Set only for
  /// [agoraEventProximity] events; no coordinates are ever carried.
  final int proximityBand;
}

typedef _SetRootC = Void Function(Pointer<Utf8>);
typedef _SetRootDart = void Function(Pointer<Utf8>);

typedef _OpenC = Pointer<Void> Function(Pointer<Utf8>);
typedef _OpenDart = Pointer<Void> Function(Pointer<Utf8>);

typedef _RosterC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _RosterDart = int Function(Pointer<Void>, Pointer<Utf8>);

typedef _SetPosC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetPosDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

typedef _SetProfC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetProfDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

typedef _ConnReqC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>);
typedef _ConnReqDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>);

typedef _ConnRespC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Int32);
typedef _ConnRespDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, int);

typedef _SendDmC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Utf8>);
typedef _SendDmDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Utf8>);

typedef _PublishPostC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _PublishPostDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int);

typedef _ReactC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Utf8>);
typedef _ReactDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Utf8>);

typedef _BlockC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>);
typedef _BlockDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>);

typedef _AttendC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>);
typedef _AttendDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>);

typedef _ProxC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>);
typedef _ProxDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>);

typedef _SetExactC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Int32, Double, Double);
typedef _SetExactDart = int Function(
    Pointer<Void>, Pointer<Utf8>, int, double, double);

typedef _PollC = Int32 Function(Pointer<Void>, Pointer<AgoraEvent>, Int32);
typedef _PollDart = int Function(Pointer<Void>, Pointer<AgoraEvent>, int);

typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

DynamicLibrary _loadShim() {
  final override = Platform.environment['AGORA_SHIM_PATH'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isLinux || Platform.isMacOS) {
    final base = Platform.isMacOS ? 'libagora_shim.dylib' : 'libagora_shim.so';
    // Bundled build: the shim ships in the app's lib/ dir, next to the
    // executable (linux/CMakeLists.txt install rules). Load it by explicit path
    // so it resolves without LD_LIBRARY_PATH; its $ORIGIN rpath then finds
    // libautonomous_trust in the same dir.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir/lib/$base';
    if (File(bundled).existsSync()) return DynamicLibrary.open(bundled);
    // Dev fallback: rely on the loader search path (RUNPATH / LD_LIBRARY_PATH).
    return DynamicLibrary.open(base);
  }
  throw UnsupportedError(
      'Agora native shim: unsupported platform ${Platform.operatingSystem}');
}

List<int> _copyArray(Array<Uint8> src, int len) =>
    List<int>.generate(len, (i) => src[i], growable: false);

/// Decode a NUL-terminated ASCII geohash from the fixed byte array.
String _geohashString(Array<Uint8> src) {
  final bytes = <int>[];
  for (var i = 0; i < agoraGeohashLen; i++) {
    final b = src[i];
    if (b == 0) break;
    bytes.add(b);
  }
  return String.fromCharCodes(bytes);
}

/// Decode a NUL-terminated UTF-8 profile JSON string from the fixed byte array.
/// Malformed bytes are tolerated (allowMalformed) rather than throwing in poll.
String _profileJsonString(Array<Uint8> src) {
  final bytes = <int>[];
  for (var i = 0; i < agoraProfileJsonMax; i++) {
    final b = src[i];
    if (b == 0) break;
    bytes.add(b);
  }
  if (bytes.isEmpty) return '';
  return utf8.decode(bytes, allowMalformed: true);
}

/// Decode a NUL-terminated UTF-8 DM body from the fixed byte array (Increment 6).
/// Malformed bytes are tolerated (allowMalformed) rather than throwing in poll.
String _dmTextString(Array<Uint8> src) {
  final bytes = <int>[];
  for (var i = 0; i < agoraDmTextMax; i++) {
    final b = src[i];
    if (b == 0) break;
    bytes.add(b);
  }
  if (bytes.isEmpty) return '';
  return utf8.decode(bytes, allowMalformed: true);
}

/// Decode a NUL-terminated ASCII post content-id (lowercase hex) from the fixed
/// byte array (Increment 7).
String _postIdString(Array<Uint8> src) {
  final bytes = <int>[];
  for (var i = 0; i < agoraPostIdMax; i++) {
    final b = src[i];
    if (b == 0) break;
    bytes.add(b);
  }
  return String.fromCharCodes(bytes);
}

/// Decode a NUL-terminated UTF-8 post body from the fixed byte array
/// (Increment 7). Malformed bytes are tolerated rather than throwing in poll.
String _postBodyString(Array<Uint8> src) {
  final bytes = <int>[];
  for (var i = 0; i < agoraPostBodyMax; i++) {
    final b = src[i];
    if (b == 0) break;
    bytes.add(b);
  }
  if (bytes.isEmpty) return '';
  return utf8.decode(bytes, allowMalformed: true);
}

/// Thin, fork-free client over the AutonomousTrust app-events queue.
class AtEvents {
  AtEvents._(this._handle);

  final Pointer<Void> _handle;

  static final DynamicLibrary _lib = _loadShim();
  static final _SetRootDart _setRoot =
      _lib.lookupFunction<_SetRootC, _SetRootDart>('agora_set_root');
  static final _OpenDart _open =
      _lib.lookupFunction<_OpenC, _OpenDart>('agora_events_open');
  static final _RosterDart _roster = _lib
      .lookupFunction<_RosterC, _RosterDart>('agora_events_request_roster');
  static final _SetPosDart _setPos =
      _lib.lookupFunction<_SetPosC, _SetPosDart>('agora_set_position');
  static final _SetProfDart _setProf =
      _lib.lookupFunction<_SetProfC, _SetProfDart>('agora_set_profile');
  static final _ConnReqDart _connReq =
      _lib.lookupFunction<_ConnReqC, _ConnReqDart>('agora_connect_request');
  static final _ConnRespDart _connResp =
      _lib.lookupFunction<_ConnRespC, _ConnRespDart>('agora_connect_respond');
  static final _SendDmDart _sendDm =
      _lib.lookupFunction<_SendDmC, _SendDmDart>('agora_send_dm');
  static final _PublishPostDart _publishPost = _lib
      .lookupFunction<_PublishPostC, _PublishPostDart>('agora_publish_post');
  static final _ReactDart _react =
      _lib.lookupFunction<_ReactC, _ReactDart>('agora_react_post');
  static final _BlockDart _block =
      _lib.lookupFunction<_BlockC, _BlockDart>('agora_block');
  static final _AttendDart _requestAttend =
      _lib.lookupFunction<_AttendC, _AttendDart>('agora_request_attend');
  static final _ProxDart _requestProximity =
      _lib.lookupFunction<_ProxC, _ProxDart>('agora_request_proximity');
  static final _SetExactDart _setExactPosition = _lib
      .lookupFunction<_SetExactC, _SetExactDart>('agora_set_exact_position');
  static final _PollDart _poll =
      _lib.lookupFunction<_PollC, _PollDart>('agora_events_poll');
  static final _CloseDart _close =
      _lib.lookupFunction<_CloseC, _CloseDart>('agora_events_close');

  /// Point this process's AutonomousTrust config root at [root], so the queue
  /// sockets opened below resolve under the same `$root/var/at/` the `agorad`
  /// daemon uses. Must be called before [open]. No-op for an empty root.
  static void setRoot(String root) {
    if (root.isEmpty) return;
    final p = root.toNativeUtf8();
    try {
      _setRoot(p);
    } finally {
      calloc.free(p);
    }
  }

  /// Open the AT->app receive queue (a bare name, e.g. "at_to_extern"). Returns
  /// null if it cannot be bound.
  static AtEvents? open(String recvQueue) {
    final namePtr = recvQueue.toNativeUtf8();
    try {
      final h = _open(namePtr);
      if (h == nullptr) return null;
      return AtEvents._(h);
    } finally {
      calloc.free(namePtr);
    }
  }

  /// Ask the daemon to (re)send the roster on the app->AT queue. Returns 0 on
  /// success, negative on error (-2 == daemon not ready yet).
  int requestRoster(String sendQueue) {
    final p = sendQueue.toNativeUtf8();
    try {
      return _roster(_handle, p);
    } finally {
      calloc.free(p);
    }
  }

  /// Set (or clear) this node's opt-in coarse position. [geohash] empty/null
  /// opts out. STRICTLY OPT-IN: nothing geographic is shared until this is
  /// called with a non-empty geohash. Returns 0 on success, negative on error
  /// (-2 == daemon not ready yet).
  int setPosition(String sendQueue, String? geohash) {
    final q = sendQueue.toNativeUtf8();
    final g = (geohash ?? '').toNativeUtf8();
    try {
      return _setPos(_handle, q, g);
    } finally {
      calloc.free(q);
      calloc.free(g);
    }
  }

  /// Set (or clear) this node's opt-in agora.profile. [profileJson] is a JSON
  /// object of the profile fields, or empty/null to opt out. The identity
  /// process truncates each field to its bound and shares the result, signed,
  /// only with admitted peers that ask. Returns 0 on success, negative on error
  /// (-2 == daemon not ready yet).
  int setProfile(String sendQueue, String? profileJson) {
    final q = sendQueue.toNativeUtf8();
    final p = (profileJson ?? '').toNativeUtf8();
    try {
      return _setProf(_handle, q, p);
    } finally {
      calloc.free(q);
      calloc.free(p);
    }
  }

  /// Request an explicit connection to [peerUuid] (16 raw identity bytes). The
  /// core sets our edge to pending_out and sends a directed encrypted request.
  /// Returns 0 on success, negative on error (-2 == daemon not ready yet). A
  /// connection is EXPLICIT and revocable, and SEPARATE from reputation.
  int connectRequest(String sendQueue, List<int> peerUuid) {
    final q = sendQueue.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen);
    try {
      for (var i = 0; i < agoraUuidLen && i < peerUuid.length; i++) {
        u[i] = peerUuid[i];
      }
      return _connReq(_handle, q, u);
    } finally {
      calloc.free(q);
      calloc.free(u);
    }
  }

  /// Respond to an inbound connection request from [peerUuid] (16 raw identity
  /// bytes): [accept] true connects, false declines. The core sets our edge and
  /// sends a directed encrypted, SIGNED response. Returns 0 on success, negative
  /// on error (-2 == daemon not ready yet).
  int connectRespond(String sendQueue, List<int> peerUuid, bool accept) {
    final q = sendQueue.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen);
    try {
      for (var i = 0; i < agoraUuidLen && i < peerUuid.length; i++) {
        u[i] = peerUuid[i];
      }
      return _connResp(_handle, q, u, accept ? 1 : 0);
    } finally {
      calloc.free(q);
      calloc.free(u);
    }
  }

  /// Send a directed text message to [peerUuid] (16 raw identity bytes). The
  /// core sends a directed encrypted peer_dm and does NOT echo it back — the app
  /// echoes locally. Returns 0 on success, negative on error (-2 == daemon not
  /// ready yet).
  int sendDm(String sendQueue, List<int> peerUuid, String text) {
    final q = sendQueue.toNativeUtf8();
    final t = text.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen);
    try {
      for (var i = 0; i < agoraUuidLen && i < peerUuid.length; i++) {
        u[i] = peerUuid[i];
      }
      return _sendDm(_handle, q, u, t);
    } finally {
      calloc.free(q);
      calloc.free(t);
      calloc.free(u);
    }
  }

  /// Publish a feed post to the local group (Increment 7). [requiredTier] is the
  /// audience floor (0..4). The core signs the post, group-encrypts it and
  /// multicasts it; it does NOT echo it back — the app echoes locally. Returns 0
  /// on success, negative on error (-2 == daemon not ready yet).
  int publishPost(String sendQueue, String body, int requiredTier) {
    final q = sendQueue.toNativeUtf8();
    final b = body.toNativeUtf8();
    try {
      return _publishPost(_handle, q, b, requiredTier);
    } finally {
      calloc.free(q);
      calloc.free(b);
    }
  }

  /// React to a post authored by [authorUuid] (16 raw identity bytes),
  /// identified by its content-id [postId] (Increment 8). The core sends a
  /// directed encrypted reaction to the author, and both peers accrue reputation
  /// for the engagement. Returns 0 on success, negative on error (-2 == daemon
  /// not ready yet).
  int reactToPost(String sendQueue, List<int> authorUuid, String postId) {
    final q = sendQueue.toNativeUtf8();
    final p = postId.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen);
    try {
      for (var i = 0; i < agoraUuidLen && i < authorUuid.length; i++) {
        u[i] = authorUuid[i];
      }
      return _react(_handle, q, u, p);
    } finally {
      calloc.free(q);
      calloc.free(p);
      calloc.free(u);
    }
  }

  /// Locally block [peerUuid] (16 raw identity bytes) (Increment 8): clamps the
  /// peer's effective trust tier to 0 for THIS node only. Purely local — no wire
  /// traffic, no reputation transaction. Returns 0 on success, negative on error
  /// (-2 == daemon not ready yet).
  int block(String sendQueue, List<int> peerUuid) {
    final q = sendQueue.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen);
    try {
      for (var i = 0; i < agoraUuidLen && i < peerUuid.length; i++) {
        u[i] = peerUuid[i];
      }
      return _block(_handle, q, u);
    } finally {
      calloc.free(q);
      calloc.free(u);
    }
  }

  /// Pull a fresh operator-attendance attestation from [peerUuid] (16 raw
  /// identity bytes) NOW (Phase 2, presence). The identity process issues a
  /// nonce-fresh attest query; the refreshed operator_attested_at rides the next
  /// peer-observed event. Returns 0 on success, negative on error (-2 == daemon
  /// not ready yet).
  int requestAttend(String sendQueue, List<int> peerUuid) {
    final q = sendQueue.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen);
    try {
      for (var i = 0; i < agoraUuidLen && i < peerUuid.length; i++) {
        u[i] = peerUuid[i];
      }
      return _requestAttend(_handle, q, u);
    } finally {
      calloc.free(q);
      calloc.free(u);
    }
  }

  /// Run a private-proximity probe against [peerUuid] (16 raw identity bytes), a
  /// CONNECTED peer (Phase 2). The coarse distance band arrives later as an
  /// [agoraEventProximity] event. Returns 0 on success, negative on error
  /// (-2 == daemon not ready yet).
  int requestProximity(String sendQueue, List<int> peerUuid) {
    final q = sendQueue.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen);
    try {
      for (var i = 0; i < agoraUuidLen && i < peerUuid.length; i++) {
        u[i] = peerUuid[i];
      }
      return _requestProximity(_handle, q, u);
    } finally {
      calloc.free(q);
      calloc.free(u);
    }
  }

  /// Set ([optIn] true) or clear ([optIn] false) THIS node's opt-in EXACT
  /// position (Phase 2, private proximity). [lat]/[lon] are degrees. The core
  /// keeps it LOCAL-ONLY and never advertises it — it feeds only the pairwise
  /// distance-band probe. Returns 0 on success, negative on error (-2 == daemon
  /// not ready yet).
  int setExactPosition(String sendQueue,
      {required bool optIn, double lat = 0, double lon = 0}) {
    final q = sendQueue.toNativeUtf8();
    try {
      return _setExactPosition(_handle, q, optIn ? 1 : 0, lat, lon);
    } finally {
      calloc.free(q);
    }
  }

  /// Non-blocking drain. Returns decoded events (possibly empty). Copies out of
  /// native memory before freeing the buffer, so the results are safe to keep.
  List<AtRawEvent> poll({int max = 64}) {
    final buf = calloc<AgoraEvent>(max);
    try {
      final n = _poll(_handle, buf, max);
      if (n <= 0) return const [];
      return List<AtRawEvent>.generate(n, (i) {
        final e = buf[i];
        return AtRawEvent(
          kind: e.kind,
          uuid: _copyArray(e.peerUuid, agoraUuidLen),
          signingPubkey: _copyArray(e.signingPubkey, agoraKeyLen),
          rank: e.rank,
          operatorBound: e.operatorBound != 0,
          operatorAttestedAt: e.operatorAttestedAt,
          operatorPubkey: _copyArray(e.operatorPubkey, agoraKeyLen),
          repScore: e.repScore,
          repRated: e.repRated != 0,
          rttMs: e.rttMs,
          geohash: _geohashString(e.geohash),
          profileJson: _profileJsonString(e.profileJson),
          connectionState: e.connectionState,
          dmSeq: e.dmSeq,
          dmTs: e.dmTs,
          dmText: _dmTextString(e.dmText),
          postId: _postIdString(e.postId),
          postSeq: e.postSeq,
          postTs: e.postTs,
          postRequiredTier: e.postRequiredTier,
          postBody: _postBodyString(e.postBody),
          reactionPostId: _postIdString(e.reactionPostId),
          reactionSeq: e.reactionSeq,
          reactionTs: e.reactionTs,
          inGroup: e.inGroup != 0,
          proximityBand: e.proximityBand,
        );
      }, growable: false);
    } finally {
      calloc.free(buf);
    }
  }

  void close() => _close(_handle);
}
