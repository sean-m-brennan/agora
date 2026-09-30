/********************
 *  Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 *******************/

/**
 * at_agora.h — the Agora social feature's half of the flat app-event ABI.
 *
 * app_events.h is the core's surface and is the same in every build. This
 * header adds what the social feature carries over it: the event kinds 4..17,
 * their flat payload structs, kind-checked accessors, and the app→AT social
 * verbs. It is installed only by a core built with AT_SOCIAL.
 *
 * A social event arrives in @ref at_app_event_t's fixed-size payload arm.
 * Read it through the accessor for its kind, which returns NULL for any other
 * kind -- so a consumer never reinterprets one struct as another:
 *
 *   const at_app_post_t *post = at_agora_event_post(&batch[i]);
 *   if (post != NULL) { ... post->body ... }
 *
 * Kind numbers are the ones this ABI has always used; they are frozen and
 * only ever appended (16..99 are Agora's to append into).
 *
 * See doc/architecture/app-peer-carrier.md and doc/architecture/extensions.md.
 */

#ifndef AT_AGORA_H
#define AT_AGORA_H

/** @addtogroup public_api
 *  @{
 */

#include "app_events.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Max geohash length carried across the app boundary. The app shares a
 *  ~5-char geohash (~5km "neighborhood" bucket); the buffer allows finer later
 *  without an ABI change. MUST match AT_GEOHASH_MAX_LEN in social/social_msg_types.h. */
#define AT_APP_GEOHASH_LEN 12
/** Max bytes of the compact profile JSON carried across the app boundary
 *  (Increment 3). MUST match AT_PROFILE_JSON_LEN in social/social_msg_types.h,
 *  AT_PROFILE_JSON_MAX in social/profile.h, and AGORA_PROFILE_JSON_MAX in the
 *  shim / cohort ctypes. */
#define AT_APP_PROFILE_JSON_LEN 2560
/** Max bytes of a DM body carried across the app boundary (Increment 6). MUST
 *  match AT_DM_TEXT_LEN (social/social_msg_types.h), AT_DM_TEXT_MAX (social/dm.h), and
 *  AGORA_DM_TEXT_MAX in the shim / cohort ctypes. */
#define AT_APP_DM_TEXT_LEN 1024
/** Max bytes of a feed-post body carried across the app boundary (Increment 7).
 *  MUST match AT_POST_BODY_LEN (social/social_msg_types.h), AT_POST_BODY_MAX (social/post.h),
 *  and AGORA_POST_BODY_MAX in the shim / cohort ctypes. */
#define AT_APP_POST_BODY_LEN 4096
/** Length of a post content id (blake2b-256 lowercase hex). MUST match
 *  AT_POST_ID_LEN (social/social_msg_types.h), AT_POST_ID_HEX_LEN (social/post.h), and
 *  AGORA_POST_ID_MAX in the shim / cohort ctypes. */
#define AT_APP_POST_ID_LEN 64
/** The community a post is made in (a polity DID). MUST match
 *  AT_POST_COMMUNITY_LEN (social_msg_types.h). */
#define AT_APP_POST_COMMUNITY_LEN 95
/** A post's labels joined with ','. MUST match AT_POST_LABELS_LEN. */
#define AT_APP_POST_LABELS_LEN 263
/** A community's opaque policy artifact. MUST match
 *  AT_COMMUNITY_POLICY_BUNDLE_LEN. */
#define AT_APP_COMMUNITY_POLICY_BUNDLE_LEN 4096
/** A moderator's opaque label. MUST match AT_POST_LABEL_BUNDLE_LEN. */
#define AT_APP_POST_LABEL_BUNDLE_LEN 1536

/** Max bytes of the opaque Ethne page bundle carried on a business ad (Phase 3
 *  P3.2). MUST match AT_BUSINESS_BUNDLE_MAX in social/business_ad.h,
 *  AT_BUSINESS_BUNDLE_LEN in social/social_msg_types.h, and AGORA_BUSINESS_BUNDLE_MAX in the
 *  shim / cohort ctypes. */
#define AT_APP_BUSINESS_BUNDLE_LEN 3072

/** Max bytes of a polity DID. MUST match AT_BUSINESS_DID_MAX / AT_BUSINESS_DID_LEN
 *  and AGORA_BUSINESS_DID_MAX. */
#define AT_APP_BUSINESS_DID_LEN 95

/** Ad content id: blake2b-256 as lowercase hex. MUST match
 *  AT_BUSINESS_AD_ID_HEX_LEN / AT_BUSINESS_AD_ID_LEN and AGORA_BUSINESS_AD_ID_MAX. */
#define AT_APP_BUSINESS_AD_ID_LEN 64

/** A business advertising its OWN page, rather than a customer rating it. MUST
 *  match AT_BUSINESS_SAT_SELF in social/business_ad.h. */
#define AT_APP_BUSINESS_SAT_SELF 0xFF

/** Max bytes of the opaque Ethne {post,delegation} bundle carried on a business
 *  post (Phase 3 P3.4). LARGER than the page bundle's 3072 because the body
 *  rides inside it; the measured worst case is 3550. MUST match
 *  AT_BUSINESS_POST_BUNDLE_MAX in social/business_post.h,
 *  AT_BUSINESS_POST_BUNDLE_LEN in social/social_msg_types.h, and
 *  AGORA_BUSINESS_POST_BUNDLE_MAX in the shim / cohort ctypes. */
#define AT_APP_BUSINESS_POST_BUNDLE_LEN 4096

/** Post content id: blake2b-256 as lowercase hex. MUST match
 *  AT_BUSINESS_POST_ID_HEX_LEN / AT_BUSINESS_POST_ID_LEN and
 *  AGORA_BUSINESS_POST_ID_MAX. */
#define AT_APP_BUSINESS_POST_ID_LEN 64

/** Max hex characters of a detached exchange's exported canonical bytes (Phase 3
 *  P3.3), so half this many bytes of CBOR. MUST match AT_COSIGN_BYTES_MAX in
 *  social/cosign.h, AT_COSIGN_BYTES_LEN in social/social_msg_types.h, COSIGN_BYTES_HEX_MAX
 *  in the agora ethne_ffi crate, and AGORA_COSIGN_BYTES_MAX in the shim / cohort
 *  ctypes.
 *
 *  MEASURED against real exchanges: a membership admission is 666 hex, a
 *  guardian designation carrying an observation 2142 for a small polity and 4192
 *  for a majority of thirty staff with a long rationale. The evidence is what
 *  grows it — roughly 372 hex per extra reading — so an exchange cites an
 *  observation scoped to the member concerned, and the authoring side refuses an
 *  oversized one outright rather than letting it truncate. */
#define AT_APP_COSIGN_BYTES_LEN 6144
/** Max bytes of a polity DID or a signer's did:key. MUST match AT_COSIGN_DID_MAX
 *  (social/cosign.h), AT_COSIGN_DID_LEN (social/social_msg_types.h) and AGORA_COSIGN_DID_MAX. */
#define AT_APP_COSIGN_DID_LEN 95
/** Exchange content id, "b3:" + 64 lowercase hex. MUST match AT_COSIGN_CID_MAX
 *  (social/cosign.h), AT_COSIGN_CID_LEN (social/social_msg_types.h) and AGORA_COSIGN_CID_MAX. */
#define AT_APP_COSIGN_CID_LEN 67
/** An Ed25519 signature as lowercase hex. MUST match AT_COSIGN_SIG_MAX
 *  (social/cosign.h), AT_COSIGN_SIG_LEN (social/social_msg_types.h) and AGORA_COSIGN_SIG_MAX. */
#define AT_APP_COSIGN_SIG_LEN 128
/** A record-class or op token. MUST match AT_COSIGN_TOKEN_MAX
 *  (social/cosign.h), AT_COSIGN_TOKEN_LEN (social/social_msg_types.h) and AGORA_COSIGN_TOKEN_MAX. */
#define AT_APP_COSIGN_TOKEN_LEN 15

/** The Agora event kinds, carried in @ref at_app_event_t::kind. */
enum {
    /** A peer's shared coarse position (@ref at_agora_event_position), as an opt-in geohash
     *  bucket. Empty geohash = the peer shared none (the default). The consumer
     *  computes geographic distance from its own opted-in bucket. */
    AT_APP_EVENT_PEER_POSITION = 4,
    /** A peer's shared agora.profile (@ref at_agora_event_profile), as compact field JSON. The
     *  core already bound-validated and signature-verified it before emitting;
     *  an empty profile_json = the peer shared none (the default). */
    AT_APP_EVENT_PEER_PROFILE = 5,
    /** An inbound connection ASK from a peer (@ref at_agora_event_connection; Increment 5). The
     *  peer requested an explicit connection; its @c state is pending_in.
     *  The app surfaces an accept/decline affordance. */
    AT_APP_EVENT_CONNECTION_REQUEST = 6,
    /** This node's connection edge-state toward a peer changed (@ref at_agora_event_connection;
     *  Increment 5): none=0, pending_out=1, pending_in=2, connected=3,
     *  declined=4. A connection is EXPLICIT and separate from reputation; the
     *  app derives trust tier from reputation, not from this. */
    AT_APP_EVENT_CONNECTION_STATE = 7,
    /** A directed text message received from a peer (@ref at_agora_event_dm; Increment 6). A DM
     *  is a single directed, ENCRYPTED peer→peer message; crypto_box already
     *  authenticated the sender, so its @c peer_uuid is trustworthy. Delivered on
     *  arrival — a live stream, never replayed as roster state. */
    AT_APP_EVENT_DM = 8,
    /** A signed feed post received over the group channel (@ref at_agora_event_post; Increment 7).
     *  The core verified the author's Ed25519 signature, tier-gated it against
     *  this node's view of the author's tier, and content-id-deduped it before
     *  emitting; its @c author_uuid is the signature-bound author. Distributed
     *  by encrypted group multicast and gossip-forwarded a bounded number of
     *  hops — a live stream, never replayed as roster state. */
    AT_APP_EVENT_POST = 9,
    /** A peer reacted to one of THIS node's posts (@ref at_agora_event_reaction; Increment 8). A
     *  reaction is a single directed, ENCRYPTED reactor→author message; crypto_box
     *  authenticated the reactor, so its @c peer_uuid is trustworthy. It is
     *  the return signal a fire-and-forget post lacks, and it accrues reputation
     *  for both peers. Delivered on arrival — a live stream. */
    AT_APP_EVENT_REACTION = 10,

    /** The coarse distance BAND to a CONNECTED peer (@ref at_agora_event_proximity; Phase 2),
     *  learned by a private-proximity probe. Carries only the band (near / mid /
     *  far), never coordinates — the exact position never crosses this boundary.
     *  Emitted for both sides of a probe once tags are exchanged. */
    AT_APP_EVENT_PROXIMITY = 11,

    /** A signed business ad — one opaque, self-verifying Ethne page bundle plus
     *  the advertiser's declared satisfaction (Phase 3 P3.2, @ref
     *  at_app_business_ad_t). The advertiser is either the business itself or
     *  one of its CUSTOMERS re-advertising from cache in the first person;
     *  nobody else carries a page, so what reaches you came through people who
     *  actually patronize the place. */
    AT_APP_EVENT_BUSINESS_AD = 12,

    /** A peer asks THIS node to co-sign one staff-roll or guardianship record
     *  (Phase 3 P3.3, @ref at_app_cosign_request_t). The keys never travel; the
     *  record does. What it commits to, in words, is NOT carried — derive it on
     *  this node from @c bytes, which is what will actually be signed. */
    AT_APP_EVENT_COSIGN_REQUEST = 13,

    /** A signer returns their detached signature over an exchange THIS node is
     *  authoring (Phase 3 P3.3, @ref at_app_cosign_sig_t). Check it against the
     *  payload before appending — the core neither did nor could. */
    AT_APP_EVENT_COSIGN_SIGNATURE = 14,

    /** A signed business post — one opaque, self-verifying Ethne
     *  {post,delegation} bundle the business's ENVOY signed (Phase 3 P3.4,
     *  @ref at_app_business_post_t). Unlike an ad, it is GOSSIP-RELAYED, so the
     *  peer it arrives from is a carrier and not the authority; the authority is
     *  the envoy signature inside the bundle, which only the app can check. It
     *  reaches you at all only because this node already holds the business's
     *  page — the core drops a post from a polity it knows nothing about. */
    AT_APP_EVENT_BUSINESS_POST = 15,

    /** A community's content policy, carried by a node that follows it (Phase
     *  4, @ref at_app_community_policy_t). The core verified only the
     *  CARRIER's signature; the policy's authority is the community's root
     *  signature inside @c bundle, which the app verifies before following it
     *  or trusting it over one it holds. */
    AT_APP_EVENT_COMMUNITY_POLICY = 16,

    /** A moderator's labels on one post (Phase 4, @ref at_app_post_label_t).
     *  It reaches you only because this node follows the community. Whether it
     *  COUNTS is decided against the policy you hold, which must list the
     *  moderator who signed it. */
    AT_APP_EVENT_POST_LABEL = 17
};

/** One peer's shared coarse position. Mirrors `peer_position_msg_t`. */
typedef struct {
    uint8_t peer_uuid[AT_APP_UUID_LEN];
    /** NUL-terminated geohash bucket the peer opted to share; empty string ""
     *  means the peer shared none (opted out) — the ordinary, default case.
     *  Opaque and untrusted; the consumer decodes it to compute distance from
     *  its own opted-in bucket. */
    char    geohash[AT_APP_GEOHASH_LEN + 1];
} at_app_position_t;

/** The coarse distance BAND to a CONNECTED peer (Phase 2). Mirrors
 *  `peer_proximity_msg_t`. No coordinates — only the band. */
typedef struct {
    uint8_t peer_uuid[AT_APP_UUID_LEN];
    /** 0 = unknown (a side had no exact position), 1 = near (~1 km), 2 = mid
     *  (~5 km), 3 = far. Matches at_prox_band_t. */
    int32_t band;
} at_app_proximity_t;

/** One peer's shared agora.profile. Mirrors `peer_profile_msg_t`. */
typedef struct {
    uint8_t peer_uuid[AT_APP_UUID_LEN];
    /** NUL-terminated compact JSON object of the peer's profile fields; empty
     *  string "" means the peer shared none (opted out). The core already
     *  bound-validated the fields and verified the peer's Ed25519 signature, so
     *  the consumer may trust this without re-checking; the signature does not
     *  cross. */
    char    profile_json[AT_APP_PROFILE_JSON_LEN + 1];
} at_app_profile_t;

/** One connection edge event toward a peer (Increment 5). Mirrors
 *  `peer_connection_msg_t`. Carried by both AT_APP_EVENT_CONNECTION_REQUEST
 *  (an inbound ask; @c state == 2 pending_in) and AT_APP_EVENT_CONNECTION_STATE
 *  (any edge transition). @c state: none=0, pending_out=1, pending_in=2,
 *  connected=3, declined=4. NO trust tier here — the app derives that from
 *  reputation; a connection is an explicit, separate axis. */
typedef struct {
    uint8_t peer_uuid[AT_APP_UUID_LEN];
    int32_t state;
} at_app_connection_t;

/** One directed text message received from a peer (Increment 6). @c peer_uuid is
 *  the SENDER (crypto_box authenticated it, so it is trustworthy); @c seq is the
 *  sender's freshness sequence; @c ts the sender's send time (epoch seconds);
 *  @c text the NUL-terminated body, bound-truncated to AT_APP_DM_TEXT_LEN bytes.
 *  Carried by AT_APP_EVENT_DM. A live stream — delivered on arrival, not roster
 *  state. */
typedef struct {
    uint8_t peer_uuid[AT_APP_UUID_LEN];
    int64_t seq;
    double  ts;
    char    text[AT_APP_DM_TEXT_LEN + 1];
} at_app_dm_t;

/** One signed feed post received over the group channel (Increment 7).
 *  @c author_uuid is the SIGNATURE-BOUND author (the core verified the Ed25519
 *  signature over the canonical form, so it is trustworthy even though the post
 *  was gossip-relayed by other peers); @c post_id is the blake2b content-address
 *  (the dedup/merge key); @c seq the author's post sequence; @c ts the author's
 *  post time (epoch seconds); @c required_tier the audience floor (0..4);
 *  @c body the NUL-terminated body, bound-truncated to AT_APP_POST_BODY_LEN
 *  bytes. Carried by AT_APP_EVENT_POST. A live stream — delivered on arrival,
 *  not roster state. */
typedef struct {
    uint8_t author_uuid[AT_APP_UUID_LEN];
    char    post_id[AT_APP_POST_ID_LEN + 1];
    int64_t seq;
    double  ts;
    int32_t required_tier;
    char    body[AT_APP_POST_BODY_LEN + 1];
    /** The community the post is made in (Phase 4); "" = none. Appended, so
     *  every earlier field keeps its offset. */
    char    community[AT_APP_POST_COMMUNITY_LEN + 1];
    /** The author's signed labels, joined with ','; "" = none. */
    char    labels[AT_APP_POST_LABELS_LEN + 1];
} at_app_post_t;

/** A community's content policy, heard from a carrier (Phase 4). Mirrors
 *  `peer_community_policy_msg_t`. Carried by AT_APP_EVENT_COMMUNITY_POLICY. */
typedef struct {
    uint8_t carrier_uuid[AT_APP_UUID_LEN];
    char    community[AT_APP_POST_COMMUNITY_LEN + 1];
    char    policy_id[AT_APP_POST_ID_LEN + 1];
    int64_t seq;
    double  ts;
    char    bundle[AT_APP_COMMUNITY_POLICY_BUNDLE_LEN + 1];
} at_app_community_policy_t;

/** A moderator's labels on one post (Phase 4). Mirrors
 *  `peer_post_label_msg_t`. Carried by AT_APP_EVENT_POST_LABEL. */
typedef struct {
    uint8_t publisher_uuid[AT_APP_UUID_LEN];
    char    community[AT_APP_POST_COMMUNITY_LEN + 1];
    char    post_id[AT_APP_POST_ID_LEN + 1];
    char    label_id[AT_APP_POST_ID_LEN + 1];
    int64_t seq;
    double  ts;
    int32_t hops;
    char    bundle[AT_APP_POST_LABEL_BUNDLE_LEN + 1];
} at_app_post_label_t;

/** One reaction to one of THIS node's posts (Increment 8). @c peer_uuid is the
 *  REACTOR (crypto_box-authenticated, so trustworthy); @c post_id is the
 *  content-id of the post reacted to; @c seq the reactor's freshness sequence;
 *  @c ts the reactor's send time (epoch seconds). Carried by AT_APP_EVENT_REACTION.
 *  A live stream — delivered on arrival, not roster state. */
typedef struct {
    uint8_t peer_uuid[AT_APP_UUID_LEN];
    char    post_id[AT_APP_POST_ID_LEN + 1];
    int64_t seq;
    double  ts;
} at_app_reaction_t;

/** One signed business ad (Phase 3 P3.2). @c advertiser_uuid is the
 *  SIGNATURE-BOUND advertiser — the business's own node, or a CUSTOMER speaking
 *  for it in the first person (an ad is never relayed, only re-advertised, so
 *  this is always someone vouching with their own key). @c polity is the
 *  business's Ethne DID; @c ad_id the blake2b content-address (the dedup key);
 *  @c satisfaction the advertiser's 0..4 rating, or @ref AT_APP_BUSINESS_SAT_SELF
 *  when the business is advertising itself; @c seq the page version; @c ts the
 *  advertiser's send time (epoch seconds).
 *
 *  @c bundle is the OPAQUE Ethne page artifact. The core did NOT verify it — it
 *  cannot, it holds no Ethne — so the APP must, via the self-contained bundle
 *  verifier (polity root -> envoy -> page) before showing or trusting the page.
 *  What the core DID verify is the ad's Ed25519 signature: that this advertiser
 *  really vouched for these exact page bytes at this satisfaction.
 *
 *  Carried by AT_APP_EVENT_BUSINESS_AD. A live stream — delivered on arrival,
 *  not roster state. */
typedef struct {
    uint8_t advertiser_uuid[AT_APP_UUID_LEN];
    char    polity[AT_APP_BUSINESS_DID_LEN + 1];
    char    ad_id[AT_APP_BUSINESS_AD_ID_LEN + 1];
    int32_t satisfaction;
    int64_t seq;
    double  ts;
    char    bundle[AT_APP_BUSINESS_BUNDLE_LEN + 1];
} at_app_business_ad_t;

/** One peer's ask that this node co-sign a record (Phase 3 P3.3).
 *
 *  A staff roll act — admitting, expelling, designating a machine, moving or
 *  releasing its guardian — is decided by several people who are not at the same
 *  keyboard. Their PRIVATE KEYS DO NOT TRAVEL: the record's canonical bytes do,
 *  each signer signs them where their key already lives, and the authoring node
 *  reassembles the signatures.
 *
 *  @c requester_uuid is crypto_box-authenticated, so an ask cannot be put in
 *  somebody else's mouth. @c record is "membership" or "guardian", @c op the act
 *  within it, @c polity the Ethne DID, @c cid the exchange's content address,
 *  and @c bytes the exported canonical CBOR as lowercase hex.
 *
 *  @c bytes is OPAQUE and NOT verified by the core — it holds no Ethne, exactly
 *  as it holds no verifier for a page bundle. What the core did check is the
 *  shape: a known op, and an even-length lowercase-hex payload within bounds.
 *
 *  **No description is carried, deliberately.** Derive what these bytes commit
 *  to on THIS node (`ethne_describe`) and show the operator that. If the asking
 *  node supplied the wording too, it would choose both what you sign and what
 *  you are told you are signing — a friendly sentence over hostile bytes, with a
 *  real signature on the end. Recompute @c cid from @c bytes while you are
 *  there; it is carried for reference, never as proof.
 *
 *  Carried by AT_APP_EVENT_COSIGN_REQUEST. A live stream — delivered on
 *  arrival, not roster state. */
typedef struct {
    uint8_t requester_uuid[AT_APP_UUID_LEN];
    char    record[AT_APP_COSIGN_TOKEN_LEN + 1];
    char    op[AT_APP_COSIGN_TOKEN_LEN + 1];
    char    polity[AT_APP_COSIGN_DID_LEN + 1];
    char    cid[AT_APP_COSIGN_CID_LEN + 1];
    int64_t seq;
    double  ts;
    char    bytes[AT_APP_COSIGN_BYTES_LEN + 1];
} at_app_cosign_request_t;

/** One signer's detached signature, returned to the authoring node (Phase 3
 *  P3.3). @c signer_uuid is crypto_box-authenticated; @c cid names the exchange;
 *  @c signer_did is the signing did:key, which EMBEDS its public key, so no
 *  registry is needed to check the signature; @c sig is the detached Ed25519
 *  signature over the exported bytes, as lowercase hex.
 *
 *  The core did not verify @c sig and could not — it does not hold the payload.
 *  Verification belongs to the assembling node, which refuses a wrong key or a
 *  tampered payload before anything is appended.
 *
 *  Carried by AT_APP_EVENT_COSIGN_SIGNATURE. A live stream. */
typedef struct {
    uint8_t signer_uuid[AT_APP_UUID_LEN];
    char    cid[AT_APP_COSIGN_CID_LEN + 1];
    char    signer_did[AT_APP_COSIGN_DID_LEN + 1];
    char    sig[AT_APP_COSIGN_SIG_LEN + 1];
    int64_t seq;
    double  ts;
} at_app_cosign_sig_t;

/** One signed business post received over the group channel (Phase 3 P3.4).
 *
 *  @c publisher_uuid is the node that PUBLISHED these bytes — always the
 *  original, never a relay, because a relay forwards the envelope untouched
 *  and changes only @c hops. It is bound by the Ed25519 signature the core
 *  verified before emitting, and IT IS NOT THE AUTHORITY: being on a
 *  business's roll, or publishing on its behalf, does not let anyone speak for
 *  it. Only the envoy signature inside @c bundle does, and only the app can
 *  check that (`ethne_business_post_verify_bundle`, which needs no charter
 *  log, or `_verify_full` where the log is held). Render nothing under the
 *  business's name until it verifies.
 *
 *  @c polity is the business's Ethne DID, @c seq the business's own post
 *  sequence, @c ts the publisher's time, @c hops how far THIS COPY travelled
 *  (0 = straight from the business, 1 = through one relay). @c post_id is the blake2b content-address
 *  of the canonical form — the dedup key that makes gossip converge.
 *
 *  Carried by AT_APP_EVENT_BUSINESS_POST. A live stream — delivered on arrival,
 *  not roster state. */
typedef struct {
    uint8_t publisher_uuid[AT_APP_UUID_LEN];
    char    polity[AT_APP_BUSINESS_DID_LEN + 1];
    char    post_id[AT_APP_BUSINESS_POST_ID_LEN + 1];
    int64_t seq;
    double  ts;
    int32_t hops;
    char    bundle[AT_APP_BUSINESS_POST_BUNDLE_LEN + 1];
} at_app_business_post_t;

AT_APP_STATIC_ASSERT(sizeof(at_app_position_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_position_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_profile_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_profile_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_connection_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_connection_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_dm_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_dm_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_post_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_post_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_reaction_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_reaction_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_proximity_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_proximity_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_business_ad_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_business_ad_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_cosign_request_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_cosign_request_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_cosign_sig_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_cosign_sig_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_business_post_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_business_post_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_community_policy_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_community_policy_t outgrew AT_APP_EVENT_PAYLOAD_MAX");
AT_APP_STATIC_ASSERT(sizeof(at_app_post_label_t) <= AT_APP_EVENT_PAYLOAD_MAX, "at_app_post_label_t outgrew AT_APP_EVENT_PAYLOAD_MAX");

/** @brief Keep the Agora event decoders in a STATIC link.
 *
 *  They register from constructors, which a static link drops unless their
 *  object is referenced. A consumer that links the static archive and polls
 *  social events without calling any social sender must call this once (or
 *  link with `-Wl,--whole-archive`). No-op at run time; unnecessary for the
 *  shared library. */
void at_agora_link(void);

/** @name Kind-checked accessors
 *  Each returns the event's payload as its struct, or NULL if @p ev is NULL
 *  or of another kind. @{ */
static inline const at_app_position_t *at_agora_event_position(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_PEER_POSITION) ? (const at_app_position_t *)(const void *)ev->data.payload : NULL;
}

static inline const at_app_profile_t *at_agora_event_profile(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_PEER_PROFILE) ? (const at_app_profile_t *)(const void *)ev->data.payload : NULL;
}

static inline const at_app_connection_t *at_agora_event_connection(const at_app_event_t *ev)
{
    return (ev != NULL && (ev->kind == AT_APP_EVENT_CONNECTION_REQUEST || ev->kind == AT_APP_EVENT_CONNECTION_STATE)) ? (const at_app_connection_t *)(const void *)ev->data.payload : NULL;
}

static inline const at_app_dm_t *at_agora_event_dm(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_DM) ? (const at_app_dm_t *)(const void *)ev->data.payload : NULL;
}

static inline const at_app_post_t *at_agora_event_post(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_POST) ? (const at_app_post_t *)(const void *)ev->data.payload : NULL;
}

static inline const at_app_reaction_t *at_agora_event_reaction(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_REACTION) ? (const at_app_reaction_t *)(const void *)ev->data.payload : NULL;
}

static inline const at_app_proximity_t *at_agora_event_proximity(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_PROXIMITY) ? (const at_app_proximity_t *)(const void *)ev->data.payload : NULL;
}

static inline const at_app_business_ad_t *at_agora_event_business_ad(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_BUSINESS_AD) ? (const at_app_business_ad_t *)(const void *)ev->data.payload : NULL;
}

static inline const at_app_cosign_request_t *at_agora_event_cosign_request(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_COSIGN_REQUEST) ? (const at_app_cosign_request_t *)(const void *)ev->data.payload : NULL;
}

static inline const at_app_cosign_sig_t *at_agora_event_cosign_sig(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_COSIGN_SIGNATURE) ? (const at_app_cosign_sig_t *)(const void *)ev->data.payload : NULL;
}

static inline const at_app_business_post_t *at_agora_event_business_post(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_BUSINESS_POST) ? (const at_app_business_post_t *)(const void *)ev->data.payload : NULL;
}
static inline const at_app_community_policy_t *at_agora_event_community_policy(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_COMMUNITY_POLICY) ? (const at_app_community_policy_t *)(const void *)ev->data.payload : NULL;
}
static inline const at_app_post_label_t *at_agora_event_post_label(const at_app_event_t *ev)
{
    return (ev != NULL && ev->kind == AT_APP_EVENT_POST_LABEL) ? (const at_app_post_label_t *)(const void *)ev->data.payload : NULL;
}
/** @} */

/**
 * @brief Set (or clear) THIS node's own opt-in coarse position.
 *
 * Sends the app→AT `AT_APP_SET_POSITION` verb on @p q_out (same queue as the
 * roster request). @p geohash is the operator's chosen bucket; NULL or "" opts
 * out (clears it). STRICTLY OPT-IN: until this is called with a non-empty
 * geohash, the node advertises and answers nothing geographic.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound yet,
 *         -1 on any other failure.
 */
int at_app_events_set_position(at_app_events_t *handle, const char *q_out,
                               const char *geohash);

/**
 * @brief Set (or clear) THIS node's own opt-in agora.profile (Increment 3).
 *
 * Sends the app→AT `AT_APP_SET_PROFILE` verb on @p q_out. @p profile_json is a
 * JSON object of the profile fields ({display_name, handle, bio, avatar_ref,
 * links}); NULL or "" clears the profile (opts out). The identity process
 * truncates each field to its bound and shares the result, signed, only with
 * admitted peers that ask.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound yet,
 *         -1 on any other failure (including malformed @p profile_json).
 */
int at_app_events_set_profile(at_app_events_t *handle, const char *q_out,
                              const char *profile_json);

/**
 * @brief Request an explicit connection to a peer (Increment 5).
 *
 * Sends the app→AT `AT_APP_CONNECT_REQUEST` verb on @p q_out. @p peer_uuid is
 * the 16-byte identity of the peer to connect to. The identity process sets our
 * edge to pending_out and sends a directed encrypted peer_connection_request;
 * an AT_APP_EVENT_CONNECTION_STATE(pending_out) is emitted back. A connection is
 * EXPLICIT and revocable, and SEPARATE from reputation.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound yet,
 *         -1 on any other failure.
 */
int at_app_events_connect_request(at_app_events_t *handle, const char *q_out,
                                  const uint8_t peer_uuid[AT_APP_UUID_LEN]);

/**
 * @brief Respond to an inbound connection request (Increment 5).
 *
 * Sends the app→AT `AT_APP_CONNECT_RESPOND` verb on @p q_out. @p peer_uuid is
 * the requester's 16-byte identity; @p accept true connects, false declines. The
 * identity process sets our edge accordingly and sends a directed encrypted,
 * SIGNED peer_connection_response; an AT_APP_EVENT_CONNECTION_STATE is emitted
 * back.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound yet,
 *         -1 on any other failure.
 */
int at_app_events_connect_respond(at_app_events_t *handle, const char *q_out,
                                  const uint8_t peer_uuid[AT_APP_UUID_LEN],
                                  bool accept);

/**
 * @brief Pull a fresh operator-attendance attestation from a peer NOW (Phase 2,
 *        presence).
 *
 * Sends the app→AT `AT_APP_REQUEST_ATTEND` verb on @p q_out. @p peer_uuid is the
 * peer to probe. The identity process issues a nonce-fresh operator_attest_query
 * to that peer and, on the response, updates the peer's operator_attested_at and
 * re-emits an AT_APP_EVENT_PEER_OBSERVED so the app's presence indicator
 * refreshes. Fire-and-forget: no direct return event, the refresh rides the
 * next peer-observed.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound yet,
 *         -1 on any other failure.
 */
int at_app_events_request_attend(at_app_events_t *handle, const char *q_out,
                                 const uint8_t peer_uuid[AT_APP_UUID_LEN]);

/**
 * @brief Set or clear THIS node's opt-in EXACT position (Phase 2, private
 *        proximity).
 *
 * Sends the app→AT `AT_APP_SET_EXACT_POSITION` verb on @p q_out. When @p opt_in
 * is true the (@p lat, @p lon) degrees are stored; when false the exact position
 * is cleared (opt out). The identity process keeps it LOCAL-ONLY and never
 * advertises it — it feeds only the pairwise proximity probe.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound yet,
 *         -1 on any other failure.
 */
int at_app_events_set_exact_position(at_app_events_t *handle, const char *q_out,
                                     bool opt_in, double lat, double lon);

/**
 * @brief Run a private-proximity probe against a CONNECTED peer (Phase 2).
 *
 * Sends the app→AT `AT_APP_REQUEST_PROXIMITY` verb on @p q_out. @p peer_uuid is
 * the connected peer. The identity process exchanges pairwise-keyed grid tags so
 * both sides learn only a coarse distance BAND (an AT_APP_EVENT_PROXIMITY),
 * never coordinates. Fire-and-forget: the band rides a later proximity event.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound yet,
 *         -1 on any other failure.
 */
int at_app_events_request_proximity(at_app_events_t *handle, const char *q_out,
                                    const uint8_t peer_uuid[AT_APP_UUID_LEN]);

/**
 * @brief Send a directed text message to a peer (Increment 6).
 *
 * Sends the app→AT `AT_APP_SEND_DM` verb on @p q_out. @p peer_uuid is the
 * recipient's 16-byte identity; @p text is the message body (truncated to
 * AT_APP_DM_TEXT_LEN bytes). The identity process sends a directed encrypted
 * peer_dm carrying {text, seq, ts} to that peer. The core does NOT echo the
 * outgoing message back — the app echoes it locally.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound yet,
 *         -1 on any other failure.
 */
int at_app_events_send_dm(at_app_events_t *handle, const char *q_out,
                          const uint8_t peer_uuid[AT_APP_UUID_LEN],
                          const char *text);

/**
 * @brief Publish a feed post to the local group (Increment 7).
 *
 * Sends the app→AT `AT_APP_PUBLISH_POST` verb on @p q_out. @p body is the post
 * body (truncated to AT_APP_POST_BODY_LEN bytes); @p required_tier is the
 * audience floor (0..4) — a reader delivers the post only when its own view of
 * this node's tier meets it. The identity process signs the post with this
 * node's Ed25519 key, group-encrypts it, and multicasts it on the group channel;
 * inbound copies are verified, tier-gated, content-id-deduped and gossip-
 * forwarded a bounded number of hops. The core does NOT echo the outgoing post
 * back — the app echoes it locally.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound yet,
 *         -1 on any other failure.
 */
int at_app_events_publish_post(at_app_events_t *handle, const char *q_out,
                               const char *body, int required_tier);

/**
 * @brief Publish THIS node's own business page (Phase 3 P3.2).
 *
 * Sends the app→AT `AT_APP_ADVERTISE_BUSINESS` verb on @p q_out with
 * {"polity", "bundle", "seq"}; identity signs the canonical ad with this node's
 * Ed25519 key, marks it as the business's own (@ref AT_APP_BUSINESS_SAT_SELF),
 * and group-multicasts it. @p bundle is the OPAQUE, self-verifying Ethne page
 * artifact the app built through Ethne — the core never parses it.
 *
 * Reach comes from customers, not from this call: the business's own ad travels
 * one group, and it is each CUSTOMER's re-advertisement (see
 * @ref at_app_events_set_customer) that carries the page further.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_advertise_business(at_app_events_t *handle, const char *q_out,
                                     const char *polity_did, const char *bundle,
                                     int64_t seq);

/**
 * @brief Declare, update or clear THIS node's CUSTOMER edge to a business
 * (Phase 3 P3.2).
 *
 * Sends the app→AT `AT_APP_SET_CUSTOMER` verb on @p q_out with
 * {"polity", "satisfaction", "bundle", "seq"}. A customer edge is what
 * authorizes this node to CARRY a business's page: on set, identity caches the
 * bundle and immediately advertises it in the FIRST PERSON — signed with this
 * node's key, carrying this node's satisfaction — and does so again whenever a
 * fresh ad for that business arrives. Nobody else relays a page, so a business's
 * reach is exactly the sum of its customers' voices.
 *
 * @param satisfaction 0..4, or NEGATIVE to clear the edge. Clearing is how an
 *        unhappy customer withdraws: this node simply goes quiet about the
 *        business. No negative is ever published, so there is nothing to
 *        brigade with.
 * @param bundle The page to carry, or NULL/"" to carry the page this node has
 *        already learned (so a person can become a customer straight from a page
 *        that reached them through someone else).
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_set_customer(at_app_events_t *handle, const char *q_out,
                               const char *polity_did, int satisfaction,
                               const char *bundle, int64_t seq);

/**
 * @brief Publish a business post — the polity speaking — to the local group
 * (Phase 3 P3.4).
 *
 * Sends the app→AT `AT_APP_PUBLISH_BUSINESS_POST` verb on @p q_out with
 * {"polity", "bundle", "seq"}. Identity signs the canonical post with this
 * node's Ed25519 key and group-multicasts it; inbound copies are verified,
 * GATED on the receiver holding this polity's page, content-id-deduped and
 * gossip-forwarded a bounded number of hops. The core does NOT echo the
 * outgoing post back — the app echoes it locally.
 *
 * @p bundle is the OPAQUE, self-verifying Ethne {post,delegation} artifact the
 * app built through Ethne (`ethne_business_post_sign` paired with
 * `ethne_envoy_delegation`). The core never parses it and cannot tell an envoy
 * from anyone else: THIS CALL DOES NOT CONFER AUTHORITY. A node that signs a
 * bundle it has no envoy delegation for will put a post on the wire that every
 * receiver refuses.
 *
 * Unlike a business AD, a post relays: its authority comes from inside the
 * bundle rather than from who passed it along, so any reader who holds the page
 * may carry it further.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_publish_business_post(at_app_events_t *handle, const char *q_out,
                                        const char *polity_did, const char *bundle,
                                        int64_t seq);

/**
 * @brief React to a peer's post (Increment 8). Sends AT_APP_REACT_POST with
 * {"author", "post_id"}; identity delivers a directed encrypted reaction to the
 * author and both peers accrue reputation for the engagement.
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_react_post(at_app_events_t *handle, const char *q_out,
                             const uint8_t author_uuid[AT_APP_UUID_LEN],
                             const char *post_id);

/**
 * @brief Locally block a peer (Increment 8). Sends AT_APP_BLOCK with {"peer"};
 * identity clamps the peer's effective trust tier to 0 for this node only. Purely
 * local — no wire traffic, no reputation transaction.
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_block(at_app_events_t *handle, const char *q_out,
                        const uint8_t peer_uuid[AT_APP_UUID_LEN]);

/**
 * @brief Lift a local block (Phase 4 P4.1). Sends AT_APP_UNBLOCK with {"peer"};
 * identity removes the record and re-emits the peer, whose `blocked` flag then
 * reads 0. The peer is told nothing, as they were told nothing of the block.
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_unblock(at_app_events_t *handle, const char *q_out,
                          const uint8_t peer_uuid[AT_APP_UUID_LEN]);

/**
 * @brief Report a peer (Phase 4 P4.1). Sends AT_APP_REPORT_PEER with {"peer"};
 * identity sends the peer a directed encrypted peer_report and, if it went,
 * stages a low first-person score about them. No reason travels.
 *
 * Fire-and-forget like every verb here: a 0 means the ask was queued, NOT that
 * the report was accepted. The daily caps are applied in the core, after this
 * returns, and a capped report is refused there with a log line.
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_report_peer(at_app_events_t *handle, const char *q_out,
                              const uint8_t peer_uuid[AT_APP_UUID_LEN]);


/**
 * @brief Ask named peers to co-sign one record (Phase 3 P3.3).
 *
 * Sends the app→AT `AT_APP_REQUEST_COSIGN` verb on @p q_out with
 * {"peers", "record", "op", "polity", "cid", "bytes"}; identity sends each named
 * peer a directed ENCRYPTED `peer_cosign_request`, and each of them answers with
 * @ref at_app_events_return_cosign. No private key moves: that is the whole
 * point of exporting the bytes rather than gathering the keys.
 *
 * @p bytes is the exchange's canonical CBOR as lowercase hex, and it must be
 * reproduced EXACTLY — the signatures are over these bytes, so anything that
 * truncates or re-encodes them produces signatures over nothing. An oversized
 * exchange is refused rather than shortened; keep the cited observation scoped
 * to the member concerned (see @ref AT_APP_COSIGN_BYTES_LEN).
 *
 * The core carries the payload and verifies nothing about it, and it carries NO
 * description: each signer's own node derives what the bytes commit to. Do not
 * add one here — a wording chosen by the asking node is how a human comes to
 * sign something other than what they were shown.
 *
 * @param[in] peer_uuids  @p n_peers × 16-byte identities to ask.
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 on
 *         any other failure (including a malformed op or non-hex @p bytes).
 */
int at_app_events_request_cosign(at_app_events_t *handle, const char *q_out,
                                 const uint8_t *peer_uuids, size_t n_peers,
                                 const char *record, const char *op,
                                 const char *polity_did, const char *cid,
                                 const char *bytes);

/**
 * @brief Return this node's detached signature to the authoring peer (Phase 3
 * P3.3).
 *
 * Sends the app→AT `AT_APP_RETURN_COSIGN` verb on @p q_out with
 * {"peer", "cid", "signer", "sig"}; identity sends the requester a directed
 * ENCRYPTED `peer_cosign_sig`. @p signer_did is this signer's did:key (it embeds
 * the public key, so the assembling node needs no registry) and @p sig_hex the
 * detached Ed25519 signature over the exported bytes.
 *
 * Sign only after deriving, on this node, what those bytes actually commit to.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_return_cosign(at_app_events_t *handle, const char *q_out,
                                const uint8_t peer_uuid[AT_APP_UUID_LEN],
                                const char *cid, const char *signer_did,
                                const char *sig_hex);

/**
 * @brief Publish a feed post in a community's name (Phase 4).
 *
 * As at_app_events_publish_post, adding the community's DID and the author's
 * own labels, both signed with the post. @p labels_csv is the labels joined
 * with ',' (each 1..32 of [a-z0-9_-], at most eight), or NULL/"" for none;
 * labels need a community. A malformed scope is refused by the identity process
 * and nothing is published. The community's policy is applied by READERS that
 * follow it; the core applies none.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_publish_post_scoped(at_app_events_t *handle, const char *q_out,
                                      const char *body, int required_tier,
                                      const char *community, const char *labels_csv);

/**
 * @brief Follow a community, holding its policy (Phase 4).
 *
 * Sends `AT_APP_FOLLOW_COMMUNITY` with {"community","bundle","seq"}. VERIFY
 * @p bundle first (ethne_content_policy_verify): the core cannot, and will carry
 * it in this node's name. Call again with a newer bundle to replace it.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_follow_community(at_app_events_t *handle, const char *q_out,
                                   const char *community, const char *bundle,
                                   int64_t seq);

/** @brief Stop following a community (Phase 4): `AT_APP_UNFOLLOW_COMMUNITY`. */
int at_app_events_unfollow_community(at_app_events_t *handle, const char *q_out,
                                     const char *community);

/**
 * @brief Publish a moderator's label on a post (Phase 4).
 *
 * Sends `AT_APP_PUBLISH_POST_LABEL` with {"community","post_id","bundle","seq"}.
 * @p bundle is the member-signed label (ethne_post_label_sign); THIS CALL
 * CONFERS NOTHING — a reader counts the label only while the policy it holds
 * lists the moderator who signed it.
 *
 * @return 0 on success, @ref AT_APP_NOT_READY if @p q_out is not bound, -1 otherwise.
 */
int at_app_events_publish_post_label(at_app_events_t *handle, const char *q_out,
                                     const char *community, const char *post_id,
                                     const char *bundle, int64_t seq);

#ifdef __cplusplus
}
#endif

/** @} */ /* end of public_api */

#endif /* AT_AGORA_H */
