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

import 'native_paths.dart';

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
/// bound in at_agora.h, social_msg_types.h, cosign.h and ethne_ffi). MEASURED against
/// real exchanges: the evidence carried by a guardian change is what grows it.
const int agoraCosignBytesMax = 6144;

/// Max polity DID or signer did:key length (must match AGORA_COSIGN_DID_MAX).
/// Max opaque Ethne {post,delegation} bundle on a business post (Phase 3 P3.4).
/// Larger than the page bundle because the body rides inside it; the measured
/// worst case is 3550. Mirrors AGORA_BUSINESS_POST_BUNDLE_MAX in the shim.
const int agoraBusinessPostBundleMax = 4096;

/// Business-post content-id length (blake2b-256 lowercase hex).
const int agoraBusinessPostIdMax = 64;

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

/// A signed business POST — the polity speaking, in the feed (Phase 3 P3.4).
/// [AgoraEvent.peerUuid] is the node that PUBLISHED it — always the original,
/// since a relay forwards the envelope untouched and changes only the hop
/// count — and is NOT the authority: the envoy signature inside
/// [AtRawEvent.businessPostBundle] is, and only this side can check it.
const int agoraEventBusinessPost = 15;

/// A community's content policy, carried by a node that follows it (Phase 4).
/// [AtRawEvent.policyBundle] is OPAQUE: verify it with
/// `EthneFfi.verifyContentPolicy` before following or trusting it.
const int agoraEventCommunityPolicy = 16;

/// A moderator's labels on one post (Phase 4). [AtRawEvent.labelBundle] counts
/// only if `EthneFfi.verifyPostLabel` accepts it against the policy you hold.
const int agoraEventPostLabel = 17;

/// Proximity hubs (Phase 4, SOCIAL_APP_PLAN §4.1): a listing, a card, the end
/// of a lookup, or a roster installed. [AtRawEvent.fcKind] says which
/// (the `atArea*` / `atRoster*` kinds below).
const int agoraEventArea = 18;

/// The contact flow and the address book: a link minted, a request sent or to
/// answer, the handshake done, a contact record, a device filed under one, one
/// of our own devices paired ([AtRawEvent.fcKind] is an `atDir*` / `atFc*`
/// kind).
const int agoraEventContact = 19;

/// The encrypted backup (Phase 4 multi-device): written, restored or refused
/// ([AtRawEvent.fcKind] is an `atBackup*` kind).
const int agoraEventBackup = 20;

/// AT first-contact kinds (at_first_contact.h) carried in [AtRawEvent.fcKind].
const int atFcInvitation = 1000;
const int atFcHelloSent = 1001;
const int atFcRefused = 1002;
const int atFcEstablished = 1003;
const int atFcContact = 1004;
const int atFcContactsDone = 1005;
const int atFcSafetyNumber = 1006;
const int atFcVerified = 1007;
const int atFcRemoved = 1008;
const int atDirRefused = 1010;
const int atDirRequestSent = 1014;
const int atDirContactRequest = 1015;
const int atDirAccepted = 1016;
const int atDirDeclined = 1017;
const int atFcDeviceLinked = 1018;
const int atFcSiblingPaired = 1019;
const int atFcSibling = 1020;
const int atFcSiblingsDone = 1021;
const int atFcSiblingRemoved = 1022;
const int atAreaPublished = 1023;
const int atAreaRefused = 1024;
const int atAreaWithdrawn = 1025;
const int atAreaCard = 1026;
const int atAreaDone = 1027;
const int atRosterInstalled = 1028;
const int atRosterRefused = 1029;
const int atRosterRemoved = 1030;
const int atBackupWritten = 1031;
const int atBackupRestored = 1032;
const int atBackupRefused = 1033;

/// at_fc_reason_t values carried in [AtRawEvent.fcCount] on an [atFcRefused].
const int atFcReasonMismatch = 8;
const int atFcReasonUnknownContact = 9;
const int atFcReasonNotSibling = 10;

/// [AtRawEvent.fcOrigin]: where an address-book change came from.
const int atFcOriginLocal = 0;
const int atFcOriginSibling = 1;
const int atFcOriginBackup = 2;

/// First-contact field bounds. MUST match AGORA_FC_* / AGORA_AREA_*.
const int agoraFcRefMax = 63;
const int agoraFcHandleMax = 128;
const int agoraFcNicknameMax = 128;
const int agoraFcRelayMax = 79;
const int agoraFcReasonMax = 31;
const int agoraAreaMax = 7;
const int agoraAreaNameMax = 64;
const int agoraFcIssuerMax = 64;
const int agoraFcBlobMax = 7679;
const int agoraFcSafetyNumberMax = 71;
const int agoraBackupPathMax = 4095;
const int agoraBackupPassphraseMax = 31;

/// A post's labels joined with ','. MUST match AGORA_POST_LABELS_MAX.
const int agoraPostLabelsMax = 263;

/// A community's policy artifact. MUST match AGORA_COMMUNITY_POLICY_BUNDLE_MAX.
const int agoraCommunityPolicyBundleMax = 4096;

/// A moderator's label. MUST match AGORA_POST_LABEL_BUNDLE_MAX.
const int agoraPostLabelBundleMax = 1536;

/// [AtRawEvent.repCeiling] when no authority bounds the peer (Phase 4 P4.1).
/// Mirrors the C `AGORA_NO_CEILING`. Any negative value means the same; this
/// is the one the shim writes.
const double agoraNoCeiling = -1.0;

/// [AtRawEvent.repTier] when the event carries no tier — one built by a test or
/// any producer that predates Phase 4 P4.1. The app then falls back to deriving
/// the tier from the score. The shim always writes a real 0..4.
const int agoraTierUnknown = -1;

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

  /// [agoraEventBusinessPost] (Phase 3 P3.4). Appended after [cosignBytes] to
  /// mirror the C `agora_event_t`, which grew from 17872 to 22152 to 22168
  /// bytes; every
  /// prior field offset is unchanged (businessBundle stays at 8208,
  /// cosignBytes at 11720).
  ///
  /// [peerUuid] carries the PUBLISHER, signature-bound and never a relay;
  /// [businessPostHops] says how far this copy travelled. It is not the
  /// authority.
  /// [businessPostBundle] is OPAQUE and UNVERIFIED here, exactly like
  /// [businessBundle]: run `ethne_business_post_verify_bundle` (no charter log
  /// needed) before rendering a word of it under the business's name.
  @Array(agoraBusinessDidMax + 1)
  external Array<Uint8> businessPostPolity;

  @Array(agoraBusinessPostIdMax + 1)
  external Array<Uint8> businessPostId;

  @Int64()
  external int businessPostSeq;

  @Double()
  external double businessPostTs;

  @Int32()
  external int businessPostHops;

  @Array(agoraBusinessPostBundleMax + 1)
  external Array<Uint8> businessPostBundle;

  /// Moderation (Phase 4 P4.1). Appended LAST, so every prior offset is
  /// unchanged.
  ///
  /// [blocked] rides [agoraEventPeer] — identity holds the block, so identity
  /// reports it. [repTier] and [repCeiling] ride [agoraEventReputation] —
  /// reputation's own truth. Compose them exactly as the core does: a blocked
  /// peer's effective tier is 0 whatever they have earned.
  ///
  /// Before P4.1 a block emitted nothing at all and this app derived a peer's
  /// tier from the score, which a block does not touch — so a blocked peer
  /// went on ranking exactly as before. These three fields are what make a
  /// block, and a community's bound, visible.
  @Uint8()
  external int blocked;

  /// The tier reputation actually used, after any ceiling. 0..4.
  @Int32()
  external int repTier;

  /// The ceiling in force, or [agoraNoCeiling] when the peer is unbounded.
  ///
  /// READ ONLY ON [agoraEventReputation]. The native flatten path memsets each
  /// event and writes this explicitly on the reputation case alone, so on any
  /// other kind it is 0.0 — which would read as "floored at zero".
  @Double()
  external double repCeiling;

  /// Communities (Phase 4). Appended LAST, so every prior offset is unchanged
  /// (the struct grew 22168 -> 28600). [postCommunity] and [postLabels] ride
  /// [agoraEventPost]; the policy tail rides [agoraEventCommunityPolicy]; the
  /// label tail rides [agoraEventPostLabel]. Both bundles are OPAQUE.
  @Array(agoraBusinessDidMax + 1)
  external Array<Uint8> postCommunity;

  @Array(agoraPostLabelsMax + 1)
  external Array<Uint8> postLabels;

  @Array(agoraBusinessDidMax + 1)
  external Array<Uint8> policyCommunity;

  @Array(agoraPostIdMax + 1)
  external Array<Uint8> policyId;

  @Int64()
  external int policySeq;

  @Double()
  external double policyTs;

  @Array(agoraCommunityPolicyBundleMax + 1)
  external Array<Uint8> policyBundle;

  @Array(agoraBusinessDidMax + 1)
  external Array<Uint8> labelCommunity;

  @Array(agoraPostIdMax + 1)
  external Array<Uint8> labelPostId;

  @Array(agoraPostIdMax + 1)
  external Array<Uint8> labelId;

  @Int64()
  external int labelSeq;

  @Double()
  external double labelTs;

  @Int32()
  external int labelHops;

  @Array(agoraPostLabelBundleMax + 1)
  external Array<Uint8> labelBundle;

  /// Proximity hubs (Phase 4, §4.1). Appended LAST, so every prior offset is
  /// unchanged (the struct grew 28600 -> 29200). Rides [agoraEventArea] and
  /// [agoraEventContact]; [fcKind] is the AT first-contact kind.
  @Int32()
  external int fcKind;

  @Array(agoraFcRefMax + 1)
  external Array<Uint8> fcRef;

  @Array(agoraFcHandleMax + 1)
  external Array<Uint8> fcHandle;

  @Array(agoraFcNicknameMax + 1)
  external Array<Uint8> fcNickname;

  @Array(agoraFcRelayMax + 1)
  external Array<Uint8> fcRelay;

  @Array(agoraFcReasonMax + 1)
  external Array<Uint8> fcReason;

  @Array(agoraAreaMax + 1)
  external Array<Uint8> area;

  @Array(agoraAreaMax + 1)
  external Array<Uint8> areaBucket;

  @Array(agoraAreaNameMax + 1)
  external Array<Uint8> areaName;

  @Array(agoraFcIssuerMax + 1)
  external Array<Uint8> areaIssuer;

  @Int64()
  external int fcSeq;

  @Int32()
  external int fcCount;

  /// Address book, devices and backup (Phase 4 multi-device). Appended LAST,
  /// so every prior offset is unchanged (the struct grew 29200 -> 41296).
  @Array(agoraFcBlobMax + 1)
  external Array<Uint8> fcBlob;

  @Int64()
  external int fcExpiry;

  @Int32()
  external int fcRole;

  @Array(agoraFcNicknameMax + 1)
  external Array<Uint8> fcPetname;

  @Uint8()
  external int fcVerified;

  @Int32()
  external int fcProvenance;

  @Double()
  external double fcAddedAt;

  @Double()
  external double fcVerifiedAt;

  @Array(agoraFcSafetyNumberMax + 1)
  external Array<Uint8> fcSafetyNumber;

  @Int32()
  external int fcMethod;

  @Uint8()
  external int fcPeerDropped;

  @Array(agoraUuidLen)
  external Array<Uint8> fcDeviceUuid;

  @Int32()
  external int fcOrigin;

  @Array(agoraBackupPathMax + 1)
  external Array<Uint8> backupPath;

  @Array(agoraBackupPassphraseMax + 1)
  external Array<Uint8> backupPassphrase;

  @Int32()
  external int backupContacts;

  @Int32()
  external int backupSiblings;

  @Int32()
  external int backupAdded;

  @Int32()
  external int backupUpdated;

  @Int32()
  external int backupRemoved;
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
    this.businessPostPolity = '',
    this.businessPostId = '',
    this.businessPostSeq = 0,
    this.businessPostTs = 0,
    this.businessPostHops = 0,
    this.businessPostBundle = '',
    this.blocked = false,
    this.repTier = agoraTierUnknown,
    this.repCeiling = agoraNoCeiling,
    this.postCommunity = '',
    this.postLabels = const [],
    this.policyCommunity = '',
    this.policyId = '',
    this.policySeq = 0,
    this.policyTs = 0,
    this.policyBundle = '',
    this.labelCommunity = '',
    this.labelPostId = '',
    this.labelId = '',
    this.labelSeq = 0,
    this.labelTs = 0,
    this.labelHops = 0,
    this.labelBundle = '',
    this.fcKind = 0,
    this.fcRef = '',
    this.fcHandle = '',
    this.fcNickname = '',
    this.fcRelay = '',
    this.fcReason = '',
    this.area = '',
    this.areaBucket = '',
    this.areaName = '',
    this.areaIssuer = '',
    this.fcSeq = 0,
    this.fcCount = 0,
    this.fcBlob = '',
    this.fcExpiry = 0,
    this.fcRole = 0,
    this.fcPetname = '',
    this.fcVerified = false,
    this.fcProvenance = 0,
    this.fcAddedAt = 0,
    this.fcVerifiedAt = 0,
    this.fcSafetyNumber = '',
    this.fcMethod = 0,
    this.fcPeerDropped = false,
    this.fcDeviceUuid = const [],
    this.fcOrigin = 0,
    this.backupPath = '',
    this.backupPassphrase = '',
    this.backupContacts = 0,
    this.backupSiblings = 0,
    this.backupAdded = 0,
    this.backupUpdated = 0,
    this.backupRemoved = 0,
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

  /// [agoraEventBusinessPost] (Phase 3 P3.4): the business speaking.
  /// [businessPostPolity] names it, [businessPostId] is the blake2b content
  /// address (the dedup key), [businessPostSeq] the business's own post
  /// counter, [businessPostHops] how far this copy travelled.
  ///
  /// [businessPostBundle] is the OPAQUE Ethne {post,delegation} artifact and is
  /// UNVERIFIED at this boundary. The core checked only that these bytes are
  /// exactly what the publisher signed; that the BUSINESS said them is the
  /// envoy signature's job, and checking it is this side's. A post that
  /// does not verify is not the business's word and must never be rendered as
  /// one.
  final String businessPostPolity;
  final String businessPostId;
  final int businessPostSeq;
  final double businessPostTs;
  final int businessPostHops;
  final String businessPostBundle;

  /// True iff THIS node has locally blocked the peer (Phase 4 P4.1). Rides
  /// [agoraEventPeer]; identity holds the block, so identity reports it.
  final bool blocked;

  /// The tier reputation actually used for this peer, after any ceiling
  /// (0..4), or [agoraTierUnknown]. Rides [agoraEventReputation]. The app's own tier floors are a
  /// FALLBACK for a core that predates P4.1 — a ceiling is not a function of
  /// the score, so the app cannot derive this one.
  final int repTier;

  /// The ceiling bounding this peer, or [agoraNoCeiling] when unbounded.
  /// Rides [agoraEventReputation]; meaningless on any other kind.
  ///
  /// Lets the app tell "low because they have earned little" from "bounded by
  /// a community decision" — different things to show a person.
  final double repCeiling;

  /// [agoraEventPost] (Phase 4): the community the post was made in ("" for
  /// none) and the author's own labels, both SIGNED with the post. The core
  /// applied no policy; this app does, for communities it follows.
  final String postCommunity;
  final List<String> postLabels;

  /// [agoraEventCommunityPolicy] (Phase 4). [uuid] is the CARRIER. [policySeq]
  /// is the carrier's claim; the version that counts is the one inside the
  /// verified [policyBundle].
  final String policyCommunity;
  final String policyId;
  final int policySeq;
  final double policyTs;
  final String policyBundle;

  /// [agoraEventPostLabel] (Phase 4). [uuid] is the PUBLISHER, not the
  /// authority: the moderator's signature inside [labelBundle] is, and it
  /// counts only against a policy that lists that moderator.
  final String labelCommunity;
  final String labelPostId;
  final String labelId;
  final int labelSeq;
  final double labelTs;
  final int labelHops;
  final String labelBundle;

  /// [agoraEventArea] / [agoraEventContact] (proximity hubs). [fcKind] is the
  /// AT kind. On an area CARD, [uuid] is the person found, [areaBucket] their
  /// coarse bucket, [areaName] what they list under, [fcRelay] the hub. On a
  /// CONTACT_REQUEST, [fcRef] is what to answer with and [fcHandle] where they
  /// found us ("area:<area>" for a hub). On ESTABLISHED the two are direct
  /// peers, never group members.
  final int fcKind;
  final String fcRef;
  final String fcHandle;
  final String fcNickname;
  final String fcRelay;
  final String fcReason;
  final String area;
  final String areaBucket;
  final String areaName;
  final String areaIssuer;
  final int fcSeq;
  final int fcCount;

  /// The address book (Phase 4 multi-device), on [agoraEventContact]. On an
  /// INVITATION, [fcBlob] is the link and [fcExpiry] when it stops working (0 =
  /// never). On CONTACT / VERIFIED / SAFETY_NUMBER / REMOVED / DEVICE_LINKED,
  /// [uuid] is the record (its first device); [fcDeviceUuid] is the further
  /// device on DEVICE_LINKED (a list sends one per device after its record);
  /// [fcOrigin] says whether a CONTACT / REMOVED came from another of our own
  /// devices or a backup. CONTACTS_DONE / SIBLINGS_DONE: [fcCount].
  final String fcBlob;
  final int fcExpiry;
  final int fcRole;
  final String fcPetname;
  final bool fcVerified;
  final int fcProvenance;
  final double fcAddedAt;
  final double fcVerifiedAt;
  final String fcSafetyNumber;
  final int fcMethod;
  final bool fcPeerDropped;
  final List<int> fcDeviceUuid;
  final int fcOrigin;

  /// [agoraEventBackup]. [backupPassphrase] is set only on a WRITTEN the node
  /// generated a code for: show it once, never store it. On REFUSED the reason
  /// is in [fcReason].
  final String backupPath;
  final String backupPassphrase;
  final int backupContacts;
  final int backupSiblings;
  final int backupAdded;
  final int backupUpdated;
  final int backupRemoved;
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
// agora_unblock and agora_report_peer share block's shape: (handle, queue, uuid).
typedef _PeerStandingC = Int32 Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Uint8>, Pointer<Utf8>, Double, Pointer<Utf8>, Pointer<Utf8>);
typedef _PeerStandingDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Uint8>, Pointer<Utf8>, double, Pointer<Utf8>, Pointer<Utf8>);

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

typedef _PublishPostScopedC = Int32 Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, Int32, Pointer<Utf8>, Pointer<Utf8>);
typedef _PublishPostScopedDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, int, Pointer<Utf8>, Pointer<Utf8>);

typedef _FollowCommunityC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int64);
typedef _FollowCommunityDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int);

typedef _UnfollowCommunityC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _UnfollowCommunityDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

/// Senders taking the send queue and two / three / four strings.
typedef _Str2C = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Str2Dart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Str3C = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Str3Dart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Str5C = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Str5Dart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Str4C = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>);
typedef _Str4Dart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>);
typedef _InviteC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Long);
typedef _InviteDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _InitiateC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Int32, Pointer<Utf8>);
typedef _InitiateDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>);
typedef _PeerVerbC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>);
typedef _PeerVerbDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>);
typedef _VerifyC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Uint8>, Pointer<Utf8>, Int32);
typedef _VerifyDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Uint8>, Pointer<Utf8>, int);
typedef _RenameC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Uint8>, Pointer<Utf8>);
typedef _RenameDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Utf8>);
typedef _AreaRequestC = Int32 Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>);
typedef _AreaRequestDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>);

typedef _PublishPostLabelC = Int32 Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int64);
typedef _PublishPostLabelDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int);

typedef _PublishBusinessPostC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int64);
typedef _PublishBusinessPostDart = int Function(
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
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    final base = nativeLibName('agora_shim');
    // Bundled build: the shim ships beside the AT libraries (lib/ on Linux,
    // Contents/Frameworks on macOS; see native_paths.dart). Load it by explicit
    // path so it resolves with no LD_LIBRARY_PATH / DYLD_* (which the hardened
    // runtime strips anyway); its rpath then finds libautonomous_trust there.
    final bundled = '${bundledLibDir()}/$base';
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

/// Decode the NUL-terminated opaque Ethne post bundle from the fixed byte
/// array. The bytes are UNVERIFIED here — see [AtRawEvent.businessPostBundle].
String _businessPostBundleString(Array<Uint8> src) {
  final bytes = <int>[];
  for (var i = 0; i < agoraBusinessPostBundleMax; i++) {
    final b = src[i];
    if (b == 0) break;
    bytes.add(b);
  }
  if (bytes.isEmpty) return '';
  return utf8.decode(bytes, allowMalformed: true);
}

/// The ','-joined labels of a post as a list ('' -> none).
List<String> _labelsList(String joined) =>
    joined.isEmpty ? const [] : joined.split(',');

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
  static final _BlockDart _unblock =
      _lib.lookupFunction<_BlockC, _BlockDart>('agora_unblock');
  static final _BlockDart _reportPeer =
      _lib.lookupFunction<_BlockC, _BlockDart>('agora_report_peer');
  static final _PeerStandingDart _peerStanding = _lib
      .lookupFunction<_PeerStandingC, _PeerStandingDart>('agora_peer_standing');
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
  static final _PublishBusinessPostDart _publishBusinessPost =
      _lib.lookupFunction<_PublishBusinessPostC, _PublishBusinessPostDart>(
          'agora_publish_business_post');
  static final _PublishPostScopedDart _publishPostScoped =
      _lib.lookupFunction<_PublishPostScopedC, _PublishPostScopedDart>(
          'agora_publish_post_scoped');
  static final _FollowCommunityDart _followCommunity =
      _lib.lookupFunction<_FollowCommunityC, _FollowCommunityDart>(
          'agora_follow_community');
  static final _UnfollowCommunityDart _unfollowCommunity =
      _lib.lookupFunction<_UnfollowCommunityC, _UnfollowCommunityDart>(
          'agora_unfollow_community');
  static final _Str5Dart _areaPublish =
      _lib.lookupFunction<_Str5C, _Str5Dart>('agora_area_publish');
  static final _Str3Dart _areaWithdraw =
      _lib.lookupFunction<_Str3C, _Str3Dart>('agora_area_withdraw');
  static final _Str3Dart _areaLookup =
      _lib.lookupFunction<_Str3C, _Str3Dart>('agora_area_lookup');
  static final _AreaRequestDart _areaRequest =
      _lib.lookupFunction<_AreaRequestC, _AreaRequestDart>('agora_area_request');
  static final _Str2Dart _contactAccept =
      _lib.lookupFunction<_Str2C, _Str2Dart>('agora_contact_accept');
  static final _Str2Dart _contactDecline =
      _lib.lookupFunction<_Str2C, _Str2Dart>('agora_contact_decline');
  static final _Str3Dart _rosterInstall =
      _lib.lookupFunction<_Str3C, _Str3Dart>('agora_relay_roster_install');
  static final _Str3Dart _rosterRemove =
      _lib.lookupFunction<_Str3C, _Str3Dart>('agora_relay_roster_remove');
  static final _PublishPostLabelDart _publishPostLabel =
      _lib.lookupFunction<_PublishPostLabelC, _PublishPostLabelDart>(
          'agora_publish_post_label');
  static final _InviteDart _fcInvite =
      _lib.lookupFunction<_InviteC, _InviteDart>('agora_fc_invite');
  static final _InviteDart _fcPairInvite =
      _lib.lookupFunction<_InviteC, _InviteDart>('agora_fc_pair_invite');
  static final _InitiateDart _fcInitiate =
      _lib.lookupFunction<_InitiateC, _InitiateDart>('agora_fc_initiate');
  static final _Str2Dart _fcList =
      _lib.lookupFunction<_Str2C, _Str2Dart>('agora_fc_list');
  static final _PeerVerbDart _fcSafetyNumber =
      _lib.lookupFunction<_PeerVerbC, _PeerVerbDart>('agora_fc_safety_number');
  static final _VerifyDart _fcVerify =
      _lib.lookupFunction<_VerifyC, _VerifyDart>('agora_fc_verify');
  static final _RenameDart _fcRename =
      _lib.lookupFunction<_RenameC, _RenameDart>('agora_fc_rename');
  static final _PeerVerbDart _fcRemove =
      _lib.lookupFunction<_PeerVerbC, _PeerVerbDart>('agora_fc_remove');
  static final _Str2Dart _siblingList =
      _lib.lookupFunction<_Str2C, _Str2Dart>('agora_sibling_list');
  static final _PeerVerbDart _siblingRemove =
      _lib.lookupFunction<_PeerVerbC, _PeerVerbDart>('agora_sibling_remove');
  static final _Str4Dart _backupExport =
      _lib.lookupFunction<_Str4C, _Str4Dart>('agora_backup_export');
  static final _Str4Dart _backupImport =
      _lib.lookupFunction<_Str4C, _Str4Dart>('agora_backup_import');
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

  /// Publish a post in [community]'s name with the author's own [labels]
  /// (Phase 4). Labels need a community and are 1..32 of [a-z0-9_-], at most
  /// eight; a malformed scope publishes nothing. Returns 0, negative on error.
  int publishPostScoped(String sendQueue, String body, int requiredTier,
      {required String community, List<String> labels = const []}) {
    final q = sendQueue.toNativeUtf8();
    final b = body.toNativeUtf8();
    final c = community.toNativeUtf8();
    final l = labels.join(',').toNativeUtf8();
    try {
      return _publishPostScoped(_handle, q, b, requiredTier, c, l);
    } finally {
      calloc.free(q);
      calloc.free(b);
      calloc.free(c);
      calloc.free(l);
    }
  }

  /// Follow [community], holding [bundle] — its root-signed policy, which the
  /// caller has ALREADY VERIFIED — at [seq]. Call again with a newer bundle to
  /// replace it. The node then carries the policy and relays the community's
  /// labels. Returns 0, negative on error.
  int followCommunity(String sendQueue, String community, String bundle,
      {int seq = 0}) {
    final q = sendQueue.toNativeUtf8();
    final c = community.toNativeUtf8();
    final b = bundle.toNativeUtf8();
    try {
      return _followCommunity(_handle, q, c, b, seq);
    } finally {
      calloc.free(q);
      calloc.free(c);
      calloc.free(b);
    }
  }

  /// Run [f] over native copies of [strs], freeing them after.
  int _withStrs(List<String> strs, int Function(List<Pointer<Utf8>>) f) {
    final ps = [for (final s in strs) s.toNativeUtf8()];
    try {
      return f(ps);
    } finally {
      for (final p in ps) {
        calloc.free(p);
      }
    }
  }

  /// List us in [area] at its hubs, under our coarse [bucket] (inside it) and
  /// [name]. Needs first contact on in the daemon. Answered per hub with an
  /// [agoraEventArea] PUBLISHED or REFUSED; refreshed while listed.
  int areaPublish(String sendQueue, String ref, String area, String bucket,
          String name) =>
      _withStrs([sendQueue, ref, area, bucket, name],
          (p) => _areaPublish(_handle, p[0], p[1], p[2], p[3], p[4]));

  /// Stop listing us in [area].
  int areaWithdraw(String sendQueue, String ref, String area) =>
      _withStrs([sendQueue, ref, area],
          (p) => _areaWithdraw(_handle, p[0], p[1], p[2]));

  /// Who else is listed in [area]: one CARD per person, then DONE. A hub answers
  /// only while we are listed there ourselves.
  int areaLookup(String sendQueue, String ref, String area) =>
      _withStrs([sendQueue, ref, area],
          (p) => _areaLookup(_handle, p[0], p[1], p[2]));

  /// Ask [peerUuid] (16 bytes), found by a lookup of [area], to become a
  /// contact. Answered with [agoraEventContact] events.
  int areaRequest(String sendQueue, String ref, String area, List<int> peerUuid) {
    final u = calloc<Uint8>(16);
    try {
      for (var i = 0; i < 16; i++) {
        u[i] = i < peerUuid.length ? peerUuid[i] : 0;
      }
      return _withStrs(
          [sendQueue, ref, area], (p) => _areaRequest(_handle, p[0], p[1], p[2], u));
    } finally {
      calloc.free(u);
    }
  }

  /// Accept / decline a CONTACT_REQUEST, by the [AtRawEvent.fcRef] it carried.
  int contactAccept(String sendQueue, String requestRef) =>
      _withStrs([sendQueue, requestRef], (p) => _contactAccept(_handle, p[0], p[1]));
  int contactDecline(String sendQueue, String requestRef) =>
      _withStrs([sendQueue, requestRef], (p) => _contactDecline(_handle, p[0], p[1]));

  /// Trust a community's relay [roster] (the file text a VERIFIED policy
  /// carries): the node pins its issuer and registers with its hubs.
  int relayRosterInstall(String sendQueue, String ref, String roster) =>
      _withStrs([sendQueue, ref, roster],
          (p) => _rosterInstall(_handle, p[0], p[1], p[2]));

  /// Run [f] over a native 16-byte copy of [peerUuid], freeing it after.
  int _withUuid(List<int> peerUuid, int Function(Pointer<Uint8>) f) {
    final u = calloc<Uint8>(16);
    try {
      for (var i = 0; i < 16; i++) {
        u[i] = i < peerUuid.length ? peerUuid[i] : 0;
      }
      return f(u);
    } finally {
      calloc.free(u);
    }
  }

  /// Mint a link for someone to add us ([ttlSeconds] < 0: a week; 0: never).
  /// Answered with an INVITATION carrying [AtRawEvent.fcBlob], or REFUSED.
  int fcInvite(String sendQueue, String ref, {int ttlSeconds = -1}) =>
      _withStrs([sendQueue, ref], (p) => _fcInvite(_handle, p[0], p[1], ttlSeconds));

  /// Mint a PAIRING link for another device of ours. Needs a device cert;
  /// refused with [atFcReasonNotSibling] otherwise.
  int fcPairInvite(String sendQueue, String ref, {int ttlSeconds = -1}) =>
      _withStrs(
          [sendQueue, ref], (p) => _fcPairInvite(_handle, p[0], p[1], ttlSeconds));

  /// Redeem [invitation] (a contact's link, or our own device's pairing link).
  /// [inPerson] ONLY when it crossed face to face: the contact is then verified
  /// at once. [petname] '' lets the node derive one.
  int fcInitiate(String sendQueue, String ref, String invitation,
      {bool inPerson = false, String petname = ''}) {
    final strs = [sendQueue, ref, invitation, if (petname.isNotEmpty) petname];
    return _withStrs(
        strs,
        (p) => _fcInitiate(_handle, p[0], p[1], p[2], inPerson ? 1 : 0,
            petname.isNotEmpty ? p[3] : nullptr));
  }

  /// The whole address book: CONTACT per record (each followed by a
  /// DEVICE_LINKED per further device), then CONTACTS_DONE.
  int fcList(String sendQueue, String ref) =>
      _withStrs([sendQueue, ref], (p) => _fcList(_handle, p[0], p[1]));

  int fcSafetyNumber(String sendQueue, String ref, List<int> peerUuid) =>
      _withUuid(peerUuid, (u) => _withStrs([sendQueue, ref],
          (p) => _fcSafetyNumber(_handle, p[0], p[1], u)));

  /// Mark [peerUuid] verified: [presented] digits typed from THEIR screen (the
  /// node compares), or [confirmed] when the user compared by eye.
  int fcVerify(String sendQueue, String ref, List<int> peerUuid,
      {String? presented, bool confirmed = false}) {
    final strs = [sendQueue, ref, if (presented != null) presented];
    return _withUuid(
        peerUuid,
        (u) => _withStrs(
            strs,
            (p) => _fcVerify(_handle, p[0], p[1], u,
                presented != null ? p[2] : nullptr, confirmed ? 1 : 0)));
  }

  int fcRename(String sendQueue, String ref, List<int> peerUuid, String petname) =>
      _withUuid(peerUuid, (u) => _withStrs([sendQueue, ref, petname],
          (p) => _fcRename(_handle, p[0], p[1], u, p[2])));

  int fcRemove(String sendQueue, String ref, List<int> peerUuid) =>
      _withUuid(peerUuid, (u) => _withStrs([sendQueue, ref],
          (p) => _fcRemove(_handle, p[0], p[1], u)));

  /// Our own paired devices: SIBLING per device, then SIBLINGS_DONE.
  int siblingList(String sendQueue, String ref) =>
      _withStrs([sendQueue, ref], (p) => _siblingList(_handle, p[0], p[1]));

  /// Unpair [peerUuid] on this device only.
  int siblingRemove(String sendQueue, String ref, List<int> peerUuid) =>
      _withUuid(peerUuid, (u) => _withStrs([sendQueue, ref],
          (p) => _siblingRemove(_handle, p[0], p[1], u)));

  /// Seal the address book and sibling list to [path] (absolute). A null
  /// [passphrase] asks the node to generate one, returned once on WRITTEN.
  int backupExport(String sendQueue, String ref, String path,
      {String? passphrase}) {
    final strs = [sendQueue, ref, path, if (passphrase != null) passphrase];
    return _withStrs(
        strs,
        (p) => _backupExport(
            _handle, p[0], p[1], p[2], passphrase != null ? p[3] : nullptr));
  }

  /// Merge the backup at [path] into the address book.
  int backupImport(String sendQueue, String ref, String path, String passphrase) =>
      _withStrs([sendQueue, ref, path, passphrase],
          (p) => _backupImport(_handle, p[0], p[1], p[2], p[3]));

  /// Stop trusting [issuer]'s roster (hex key).
  int relayRosterRemove(String sendQueue, String ref, String issuer) =>
      _withStrs([sendQueue, ref, issuer],
          (p) => _rosterRemove(_handle, p[0], p[1], p[2]));

  /// Stop following [community]. Returns 0, negative on error.
  int unfollowCommunity(String sendQueue, String community) {
    final q = sendQueue.toNativeUtf8();
    final c = community.toNativeUtf8();
    try {
      return _unfollowCommunity(_handle, q, c);
    } finally {
      calloc.free(q);
      calloc.free(c);
    }
  }

  /// Publish a moderator's label [bundle] on [postId] in [community]. Confers
  /// nothing: a reader counts it only while its policy lists the moderator.
  int publishPostLabel(String sendQueue, String community, String postId,
      String bundle,
      {int seq = 0}) {
    final q = sendQueue.toNativeUtf8();
    final c = community.toNativeUtf8();
    final p = postId.toNativeUtf8();
    final b = bundle.toNativeUtf8();
    try {
      return _publishPostLabel(_handle, q, c, p, b, seq);
    } finally {
      calloc.free(q);
      calloc.free(c);
      calloc.free(p);
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

  /// Run one peer-uuid verb ([block], [unblock], [reportPeer]): marshal the
  /// queue name and the 16 raw uuid bytes, call, free.
  int _peerVerb(_BlockDart fn, String sendQueue, List<int> peerUuid) {
    final q = sendQueue.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen);
    try {
      for (var i = 0; i < agoraUuidLen && i < peerUuid.length; i++) {
        u[i] = peerUuid[i];
      }
      return fn(_handle, q, u);
    } finally {
      calloc.free(q);
      calloc.free(u);
    }
  }

  /// Lift a local block on [peerUuid] (Phase 4 P4.1). The core re-emits the
  /// peer, whose [AtRawEvent.blocked] then reads false. Returns 0 on success,
  /// negative on error (-2 == daemon not ready yet).
  int unblock(String sendQueue, List<int> peerUuid) =>
      _peerVerb(_unblock, sendQueue, peerUuid);

  /// Report [peerUuid] (Phase 4 P4.1): the core sends them a directed report
  /// and stages a low first-person score. No reason travels. A 0 means QUEUED,
  /// not accepted — the core applies its daily caps afterwards. Returns 0 on
  /// success, negative on error (-2 == daemon not ready yet).
  int reportPeer(String sendQueue, List<int> peerUuid) =>
      _peerVerb(_reportPeer, sendQueue, peerUuid);

  /// Hand the core an authority finding about [peerUuid]'s standing (Phase 4
  /// P4.1) — a CEILING, never a score. [standing] is "proved" (reinstated,
  /// lifts this source's ceiling), "capped" or "failed"; [ceiling] in [0, 1] or
  /// negative for none; [source] names the authority ("ethne"). Returns 0 on
  /// success, negative on error (-2 == daemon not ready yet).
  int peerStanding(String sendQueue, List<int> peerUuid, String standing,
      double ceiling, String source, String reason) {
    final q = sendQueue.toNativeUtf8();
    final u = calloc<Uint8>(agoraUuidLen);
    final st = standing.toNativeUtf8();
    final src = source.toNativeUtf8();
    final why = reason.toNativeUtf8();
    try {
      for (var i = 0; i < agoraUuidLen && i < peerUuid.length; i++) {
        u[i] = peerUuid[i];
      }
      return _peerStanding(_handle, q, u, st, ceiling, src, why);
    } finally {
      calloc.free(q);
      calloc.free(u);
      calloc.free(st);
      calloc.free(src);
      calloc.free(why);
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

  /// Publish a business POST — the polity speaking (Phase 3 P3.4). [bundle] is
  /// the OPAQUE Ethne {post,delegation} artifact, already ENVOY-signed by the
  /// app; [seq] is the business's own post counter. Returns 0 on success,
  /// negative on error (-2 == daemon not ready).
  ///
  /// THIS CONFERS NO AUTHORITY. The core cannot tell an envoy from anyone else:
  /// sign a bundle this node holds no delegation for and every receiver will
  /// refuse the post. Readers also drop a post from a business they hold no
  /// page for, so reach begins with an ad ([advertiseBusiness]) and grows one
  /// relayed hop at a time.
  int publishBusinessPost(String sendQueue, String polityDid, String bundle,
      {int seq = 0}) {
    final q = sendQueue.toNativeUtf8();
    final d = polityDid.toNativeUtf8();
    final b = bundle.toNativeUtf8();
    try {
      return _publishBusinessPost(_handle, q, d, b, seq);
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
          businessPostPolity: _businessDidString(e.businessPostPolity),
          businessPostId: _postIdString(e.businessPostId),
          businessPostSeq: e.businessPostSeq,
          businessPostTs: e.businessPostTs,
          businessPostHops: e.businessPostHops,
          businessPostBundle: _businessPostBundleString(e.businessPostBundle),
          blocked: e.blocked != 0,
          repTier: e.repTier,
          // Only the reputation event carries a ceiling; every other kind
          // leaves the field at the memset zero, which would read as "floored
          // at zero" rather than "unbounded".
          repCeiling:
              e.kind == agoraEventReputation ? e.repCeiling : agoraNoCeiling,
          postCommunity: _boundedString(e.postCommunity, agoraBusinessDidMax),
          postLabels: _labelsList(
              _boundedString(e.postLabels, agoraPostLabelsMax)),
          policyCommunity:
              _boundedString(e.policyCommunity, agoraBusinessDidMax),
          policyId: _postIdString(e.policyId),
          policySeq: e.policySeq,
          policyTs: e.policyTs,
          policyBundle:
              _boundedString(e.policyBundle, agoraCommunityPolicyBundleMax),
          labelCommunity: _boundedString(e.labelCommunity, agoraBusinessDidMax),
          labelPostId: _postIdString(e.labelPostId),
          labelId: _postIdString(e.labelId),
          labelSeq: e.labelSeq,
          labelTs: e.labelTs,
          labelHops: e.labelHops,
          labelBundle: _boundedString(e.labelBundle, agoraPostLabelBundleMax),
          fcKind: e.fcKind,
          fcRef: _boundedString(e.fcRef, agoraFcRefMax),
          fcHandle: _boundedString(e.fcHandle, agoraFcHandleMax),
          fcNickname: _boundedString(e.fcNickname, agoraFcNicknameMax),
          fcRelay: _boundedString(e.fcRelay, agoraFcRelayMax),
          fcReason: _boundedString(e.fcReason, agoraFcReasonMax),
          area: _boundedString(e.area, agoraAreaMax),
          areaBucket: _boundedString(e.areaBucket, agoraAreaMax),
          areaName: _boundedString(e.areaName, agoraAreaNameMax),
          areaIssuer: _boundedString(e.areaIssuer, agoraFcIssuerMax),
          fcSeq: e.fcSeq,
          fcCount: e.fcCount,
          fcBlob: _boundedString(e.fcBlob, agoraFcBlobMax),
          fcExpiry: e.fcExpiry,
          fcRole: e.fcRole,
          fcPetname: _boundedString(e.fcPetname, agoraFcNicknameMax),
          fcVerified: e.fcVerified != 0,
          fcProvenance: e.fcProvenance,
          fcAddedAt: e.fcAddedAt,
          fcVerifiedAt: e.fcVerifiedAt,
          fcSafetyNumber:
              _boundedString(e.fcSafetyNumber, agoraFcSafetyNumberMax),
          fcMethod: e.fcMethod,
          fcPeerDropped: e.fcPeerDropped != 0,
          fcDeviceUuid: _copyArray(e.fcDeviceUuid, agoraUuidLen),
          fcOrigin: e.fcOrigin,
          backupPath: _boundedString(e.backupPath, agoraBackupPathMax),
          backupPassphrase:
              _boundedString(e.backupPassphrase, agoraBackupPassphraseMax),
          backupContacts: e.backupContacts,
          backupSiblings: e.backupSiblings,
          backupAdded: e.backupAdded,
          backupUpdated: e.backupUpdated,
          backupRemoved: e.backupRemoved,
        );
      }, growable: false);
    } finally {
      calloc.free(buf);
    }
  }

  void close() => _close(_handle);
}
