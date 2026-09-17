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

/// Max opaque Ethne page-bundle length on a business ad (must match
/// AGORA_BUSINESS_BUNDLE_MAX in at_agora_shim.h).
const int agoraBusinessBundleMax = 3072;

/// Max polity DID length (must match AGORA_BUSINESS_DID_MAX).
const int agoraBusinessDidMax = 95;

/// Business-ad content-id length (must match AGORA_BUSINESS_AD_ID_MAX).
const int agoraBusinessAdIdMax = 64;

/// Satisfaction marker for a business advertising its OWN page rather than a
/// customer rating it (must match AGORA_BUSINESS_SAT_SELF).
const int agoraBusinessSatSelf = 0xFF;

/// Max hex characters of a detached exchange's exported canonical bytes, Phase 3
/// P3.3 (must match AGORA_COSIGN_BYTES_MAX in at_agora_shim.h, and the same
/// bound in app_events.h, msg_types.h, cosign.h and ethne_ffi). MEASURED against
/// real exchanges: the evidence carried by a guardian change is what grows it.
const int agoraCosignBytesMax = 6144;

/// Max polity DID or signer did:key length (must match AGORA_COSIGN_DID_MAX).
const int agoraCosignDidMax = 95;

/// Exchange content id, `b3:` + 64 hex (must match AGORA_COSIGN_CID_MAX).
const int agoraCosignCidMax = 67;

/// Detached Ed25519 signature as lowercase hex (must match AGORA_COSIGN_SIG_MAX).
const int agoraCosignSigMax = 128;

/// Record-class or op token (must match AGORA_COSIGN_TOKEN_MAX).
const int agoraCosignTokenMax = 15;

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

/// Phase 3 P3.2 — a signed business ad: one opaque, self-verifying Ethne page
/// bundle plus the advertiser's satisfaction. The advertiser is the business
/// itself or a CUSTOMER re-advertising in the first person.
const int agoraEventBusinessAd = 12;

/// Phase 3 P3.3 — a peer asks THIS node to co-sign one staff-roll or
/// guardianship record. The keys never travel; the record's exported bytes do.
/// What those bytes commit to, in words, is NOT carried — derive it here.
const int agoraEventCosignRequest = 13;

/// Phase 3 P3.3 — a signer returns their detached signature over an exchange
/// THIS node is authoring. Verify it against the payload before appending; the
/// core neither did nor could.
const int agoraEventCosignSignature = 14;

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
  /// offset is unchanged (it sits at offset 8016); the C `agora_event_t` and the
  /// cohort ctypes Ev mirror this order and the total size exactly.
  @Uint8()
  external int inGroup;

  /// AGORA_EVENT_PROXIMITY: coarse distance band to a CONNECTED peer (0 unknown,
  /// 1 near, 2 mid, 3 far). Appended after inGroup (Phase 2) at offset 8020; it
  /// occupies the struct's former tail padding, so it cost no size at the time
  /// and every prior offset is unchanged. No coordinates cross this boundary.
  @Int32()
  external int proximityBand;

  /// A signed business ad (Phase 3 P3.2). Appended LAST after [proximityBand] to
  /// mirror the C `agora_event_t`, which grew from 8024 to 11288 bytes; every
  /// prior field offset is unchanged. Only meaningful when [kind] ==
  /// [agoraEventBusinessAd]: [peerUuid] carries the SIGNATURE-BOUND advertiser —
  /// the business itself, or a customer re-advertising in the first person.
  ///
  /// [businessBundle] is OPAQUE and NOT verified by the core (it holds no
  /// Ethne): the Dart side must run the self-contained bundle verifier on it
  /// before trusting the page. What the core DID verify is the ad signature.
  @Array(agoraBusinessDidMax + 1)
  external Array<Uint8> businessPolity;

  @Array(agoraBusinessAdIdMax + 1)
  external Array<Uint8> businessAdId;

  @Int32()
  external int businessSatisfaction;

  @Int64()
  external int businessSeq;

  @Double()
  external double businessTs;

  @Array(agoraBusinessBundleMax + 1)
  external Array<Uint8> businessBundle;

  /// The detached co-signing exchange (Phase 3 P3.3). Appended LAST after
  /// [businessBundle] to mirror the C `agora_event_t`, which grew from 11288 to
  /// 17872 bytes; every prior field offset is unchanged (businessBundle stays at
  /// 8208). Meaningful when [kind] is [agoraEventCosignRequest] (where
  /// [peerUuid] is the REQUESTER) or [agoraEventCosignSignature] (where it is
  /// the SIGNER); crypto_box authenticated either way.
  ///
  /// [cosignBytes] is OPAQUE and NOT verified by the core, exactly like
  /// [businessBundle]. Derive what it commits to HERE, with `ethne_describe`
  /// over these same bytes, and show the operator that. No description crosses
  /// this boundary on purpose: if the asking node supplied the wording as well
  /// as the payload, it would choose both what you sign and what you are told
  /// you are signing. Recompute [cosignCid] from the bytes while you are there —
  /// it is carried for reference, never as proof.
  @Array(agoraCosignTokenMax + 1)
  external Array<Uint8> cosignRecord;

  @Array(agoraCosignTokenMax + 1)
  external Array<Uint8> cosignOp;

  @Array(agoraCosignDidMax + 1)
  external Array<Uint8> cosignPolity;

  @Array(agoraCosignCidMax + 1)
  external Array<Uint8> cosignCid;

  @Array(agoraCosignDidMax + 1)
  external Array<Uint8> cosignSignerDid;

  @Array(agoraCosignSigMax + 1)
  external Array<Uint8> cosignSig;

  @Int64()
  external int cosignSeq;

  @Double()
  external double cosignTs;

  @Array(agoraCosignBytesMax + 1)
  external Array<Uint8> cosignBytes;
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
    this.businessPolity = '',
    this.businessAdId = '',
    this.businessSatisfaction = 0,
    this.businessSeq = 0,
    this.businessTs = 0,
    this.businessBundle = '',
    this.cosignRecord = '',
    this.cosignOp = '',
    this.cosignPolity = '',
    this.cosignCid = '',
    this.cosignSignerDid = '',
    this.cosignSig = '',
    this.cosignSeq = 0,
    this.cosignTs = 0,
    this.cosignBytes = '',
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

  /// A signed business ad (Phase 3 P3.2). Set only for [agoraEventBusinessAd]
  /// events: [uuid] is the SIGNATURE-BOUND advertiser — the business itself or a
  /// CUSTOMER speaking for it in the first person, since an ad is never relayed.
  /// [businessPolity] is the business's Ethne DID (the directory key),
  /// [businessAdId] the blake2b content-address (dedup key),
  /// [businessSatisfaction] the advertiser's 0..4 rating or
  /// [agoraBusinessSatSelf] for the business's own ad, [businessSeq] the page
  /// version, [businessTs] the advertiser's send time.
  ///
  /// [businessBundle] is the OPAQUE Ethne page artifact, UNVERIFIED at this
  /// boundary — the core verified only that this advertiser signed these exact
  /// bytes. Run the self-contained bundle verifier (polity root -> envoy -> page)
  /// before showing or trusting the page.
  final String businessPolity;
  final String businessAdId;
  final int businessSatisfaction;
  final int businessSeq;
  final double businessTs;
  final String businessBundle;

  /// A detached co-signing exchange (Phase 3 P3.3). Set for
  /// [agoraEventCosignRequest], where [uuid] is the REQUESTER, and for
  /// [agoraEventCosignSignature], where it is the SIGNER; crypto_box
  /// authenticated either way, so neither can be put in somebody else's mouth.
  ///
  /// On a request: [cosignRecord] is `membership` or `guardian`, [cosignOp] the
  /// act within it, [cosignPolity] the Ethne DID, [cosignCid] the exchange's
  /// content address and [cosignBytes] the exported canonical CBOR as hex.
  ///
  /// [cosignBytes] is OPAQUE and UNVERIFIED at this boundary — the core holds no
  /// Ethne. Derive what it commits to here (`ethne_describe` over these bytes)
  /// and show the operator THAT, never a wording supplied by whoever is asking.
  /// No description is carried, on purpose. Recompute [cosignCid] from the bytes
  /// too: it is carried for reference, never as proof.
  ///
  /// On a signature: [cosignSignerDid] is the signing did:key, which embeds the
  /// public key (so no registry is needed), and [cosignSig] the detached Ed25519
  /// signature over the exported bytes. The core did not check it and could not —
  /// it does not hold the payload. The assembling node does, and refuses a wrong
  /// key or a tampered payload there.
  final String cosignRecord;
  final String cosignOp;
  final String cosignPolity;
  final String cosignCid;
  final String cosignSignerDid;
  final String cosignSig;
  final int cosignSeq;
  final double cosignTs;
  final String cosignBytes;
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

typedef _RequestCosignC = Int32 Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Uint8>, Int32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>);
typedef _RequestCosignDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Uint8>, int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>);

typedef _ReturnCosignC = Int32 Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Uint8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _ReturnCosignDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Uint8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

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

typedef _AdvertiseBusinessC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int64);
typedef _AdvertiseBusinessDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int);

typedef _SetCustomerC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Utf8>, Int64);
typedef _SetCustomerDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>, int);

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

/// Decode a NUL-terminated polity DID from the fixed byte array.
String _businessDidString(Array<Uint8> src) {
  final bytes = <int>[];
  for (var i = 0; i < agoraBusinessDidMax; i++) {
    final b = src[i];
    if (b == 0) break;
    bytes.add(b);
  }
  if (bytes.isEmpty) return '';
  return utf8.decode(bytes, allowMalformed: true);
}

/// Decode a NUL-terminated fixed byte array of at most [max] bytes. Used for the
/// co-signing fields, which differ only in width.
String _boundedString(Array<Uint8> src, int max) {
  final bytes = <int>[];
  for (var i = 0; i < max; i++) {
    final b = src[i];
    if (b == 0) break;
    bytes.add(b);
  }
  if (bytes.isEmpty) return '';
  return utf8.decode(bytes, allowMalformed: true);
}

/// Decode the NUL-terminated opaque Ethne page bundle from the fixed byte array.
/// The bytes are UNVERIFIED here — see [AtRawEvent.businessBundle].
String _businessBundleString(Array<Uint8> src) {
  final bytes = <int>[];
  for (var i = 0; i < agoraBusinessBundleMax; i++) {
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
  static final _RequestCosignDart _requestCosign = _lib
      .lookupFunction<_RequestCosignC, _RequestCosignDart>('agora_request_cosign');
  static final _ReturnCosignDart _returnCosign = _lib
      .lookupFunction<_ReturnCosignC, _ReturnCosignDart>('agora_return_cosign');
  static final _AttendDart _requestAttend =
      _lib.lookupFunction<_AttendC, _AttendDart>('agora_request_attend');
  static final _ProxDart _requestProximity =
      _lib.lookupFunction<_ProxC, _ProxDart>('agora_request_proximity');
  static final _SetExactDart _setExactPosition = _lib
      .lookupFunction<_SetExactC, _SetExactDart>('agora_set_exact_position');
  static final _AdvertiseBusinessDart _advertiseBusiness =
      _lib.lookupFunction<_AdvertiseBusinessC, _AdvertiseBusinessDart>(
          'agora_advertise_business');
  static final _SetCustomerDart _setCustomer = _lib
      .lookupFunction<_SetCustomerC, _SetCustomerDart>('agora_set_customer');
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

  /// Ask each peer in [peerUuids] (16 raw identity bytes apiece) to co-sign one
  /// staff-roll or guardianship record (Phase 3 P3.3).
  ///
  /// [record] is `membership` or `guardian` and [op] the act within it;
  /// [cid] and [bytes] are the exchange exactly as Ethne exported it. No private
  /// key travels — that is the point of sending the record instead of gathering
  /// the keys. [bytes] must be passed through UNCHANGED: the signatures are over
  /// exactly these bytes, so anything that truncates or re-encodes them produces
  /// signatures over nothing. An unknown op or non-hex payload is refused by the
  /// core rather than carried.
  ///
  /// There is deliberately no description parameter. Each signer's own node
  /// derives what the bytes commit to; a wording chosen by the asking node is
  /// how somebody comes to sign something other than what they were shown.
  ///
  /// Returns 0 on success, negative on error (-2 == daemon not ready yet).
  int requestCosign(
    String sendQueue,
    List<List<int>> peerUuids, {
    required String record,
    required String op,
    required String polityDid,
    required String cid,
    required String bytes,
  }) {
    if (peerUuids.isEmpty) return -1;
    final q = sendQueue.toNativeUtf8();
    final r = record.toNativeUtf8();
    final o = op.toNativeUtf8();
    final p = polityDid.toNativeUtf8();
    final c = cid.toNativeUtf8();
    final b = bytes.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen * peerUuids.length);
    try {
      for (var n = 0; n < peerUuids.length; n++) {
        for (var i = 0; i < agoraUuidLen && i < peerUuids[n].length; i++) {
          u[n * agoraUuidLen + i] = peerUuids[n][i];
        }
      }
      return _requestCosign(_handle, q, u, peerUuids.length, r, o, p, c, b);
    } finally {
      calloc.free(q);
      calloc.free(r);
      calloc.free(o);
      calloc.free(p);
      calloc.free(c);
      calloc.free(b);
      calloc.free(u);
    }
  }

  /// Return this node's detached signature to the peer authoring an exchange
  /// (Phase 3 P3.3). [peerUuid] is the requester's 16 raw identity bytes, [cid]
  /// names the exchange, [signerDid] is this signer's did:key and [sigHex] the
  /// detached Ed25519 signature over the exported bytes.
  ///
  /// Sign only after deriving, on THIS node, what those bytes actually commit
  /// to. Returns 0 on success, negative on error (-2 == daemon not ready yet).
  int returnCosign(String sendQueue, List<int> peerUuid,
      {required String cid,
      required String signerDid,
      required String sigHex}) {
    final q = sendQueue.toNativeUtf8();
    final c = cid.toNativeUtf8();
    final d = signerDid.toNativeUtf8();
    final g = sigHex.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen);
    try {
      for (var i = 0; i < agoraUuidLen && i < peerUuid.length; i++) {
        u[i] = peerUuid[i];
      }
      return _returnCosign(_handle, q, u, c, d, g);
    } finally {
      calloc.free(q);
      calloc.free(c);
      calloc.free(d);
      calloc.free(g);
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

  /// Publish THIS node's own business page (Phase 3 P3.2). [polityDid] is the
  /// business's Ethne DID, [bundle] the opaque self-verifying page artifact
  /// (built app-side through Ethne — the core never parses it), [seq] its
  /// version. Returns 0 on success, negative on error (-2 == daemon not ready).
  ///
  /// This call reaches one group. The page travels further only as CUSTOMERS
  /// re-advertise it ([setCustomer]) — a business cannot buy reach it has not
  /// earned.
  int advertiseBusiness(String sendQueue, String polityDid, String bundle,
      {int seq = 0}) {
    final q = sendQueue.toNativeUtf8();
    final d = polityDid.toNativeUtf8();
    final b = bundle.toNativeUtf8();
    try {
      return _advertiseBusiness(_handle, q, d, b, seq);
    } finally {
      calloc.free(q);
      calloc.free(d);
      calloc.free(b);
    }
  }

  /// Declare, update or clear THIS node's CUSTOMER edge to a business (Phase 3
  /// P3.2). The edge is what authorizes this node to CARRY the page: the core
  /// caches [bundle] and advertises it in the FIRST PERSON with [satisfaction]
  /// (0..4), and re-advertises whenever a fresh ad for that business arrives.
  ///
  /// Pass a NEGATIVE [satisfaction] to clear the edge. That is how an unhappy
  /// customer withdraws: this node goes quiet about the business. Nothing
  /// negative is ever published, so there is nothing to brigade with.
  ///
  /// Pass an empty [bundle] to carry the page this node already learned — so a
  /// person can become a customer straight from a page that reached them through
  /// someone else. Returns 0 on success, negative on error (-2 == not ready).
  int setCustomer(String sendQueue, String polityDid,
      {required int satisfaction, String bundle = '', int seq = 0}) {
    final q = sendQueue.toNativeUtf8();
    final d = polityDid.toNativeUtf8();
    final b = bundle.toNativeUtf8();
    try {
      return _setCustomer(_handle, q, d, satisfaction, b, seq);
    } finally {
      calloc.free(q);
      calloc.free(d);
      calloc.free(b);
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
          businessPolity: _businessDidString(e.businessPolity),
          businessAdId: _postIdString(e.businessAdId),
          businessSatisfaction: e.businessSatisfaction,
          businessSeq: e.businessSeq,
          businessTs: e.businessTs,
          businessBundle: _businessBundleString(e.businessBundle),
          cosignRecord: _boundedString(e.cosignRecord, agoraCosignTokenMax),
          cosignOp: _boundedString(e.cosignOp, agoraCosignTokenMax),
          cosignPolity: _boundedString(e.cosignPolity, agoraCosignDidMax),
          cosignCid: _boundedString(e.cosignCid, agoraCosignCidMax),
          cosignSignerDid:
              _boundedString(e.cosignSignerDid, agoraCosignDidMax),
          cosignSig: _boundedString(e.cosignSig, agoraCosignSigMax),
          cosignSeq: e.cosignSeq,
          cosignTs: e.cosignTs,
          cosignBytes: _boundedString(e.cosignBytes, agoraCosignBytesMax),
        );
      }, growable: false);
    } finally {
      calloc.free(buf);
    }
  }

  void close() => _close(_handle);
}
