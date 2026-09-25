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

#ifndef SOCIAL_MSG_TYPES_H
#define SOCIAL_MSG_TYPES_H

/** @addtogroup internal_utilities
 *  @{
 */

/**
 * @file social_msg_types.h
 * @brief The Agora social feature's IPC message types and payloads.
 *
 * Registered with the core at load (utilities/msg_registry.h) rather than
 * compiled into `generic_msg_t`'s union, so the core does not change shape
 * with AT_SOCIAL. Payloads ride `generic_msg_t.info.payload`; read and write
 * them with AT_MSG_EXT(msg, T). All twelve are identity → app and app-bound.
 *
 * Ids are process-local and the NAMES are what cross IPC; do not rename a
 * type once it has shipped. Append a new id at the next offset.
 */

#include "utilities/msg_types.h"

/* Social message ids (reserved range AT_MSG_TYPE_SOCIAL_MIN..MAX). Typed
 * constants, not an anonymous enum: every use is a message_type_t, and GCC
 * -Wenum-conversion warns on each one passed from an unrelated enum. */
/** Identity → app: one peer's shared coarse position (opt-in geohash, @ref peer_position_msg_t). Local IPC only. */
#define PEER_POSITION_OBSERVED           ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 0))
/** Identity → app: one peer's shared agora.profile (opt-in, signature-verified, @ref peer_profile_msg_t). Local IPC only. */
#define PEER_PROFILE_OBSERVED            ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 1))
/** Identity → app: an inbound connection ASK from a peer (Increment 5, @ref peer_connection_msg_t). Local IPC only. */
#define PEER_CONNECTION_REQUEST_OBSERVED ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 2))
/** Identity → app: our connection edge-state toward a peer changed (Increment 5, @ref peer_connection_msg_t). Local IPC only. */
#define PEER_CONNECTION_STATE_OBSERVED   ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 3))
/** Identity → app: a directed text message received from a peer (Increment 6, @ref peer_dm_msg_t). Local IPC only. Live stream — delivered on arrival, never roster state. */
#define PEER_DM_OBSERVED                 ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 4))
/** Identity → app: a signed feed post received over the group channel (Increment 7, @ref peer_post_msg_t). Local IPC only. Signature-verified, tier-gated and content-id-deduped before emit. */
#define PEER_POST_OBSERVED               ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 5))
/** Identity → app: a peer reacted to one of our posts (Increment 8, @ref peer_reaction_msg_t). Local IPC only. Live stream — delivered on arrival. */
#define PEER_REACTION_OBSERVED           ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 6))
/** Identity → app: the coarse distance BAND to a CONNECTED peer, learned by a private-proximity probe (Phase 2, @ref peer_proximity_msg_t). Local IPC only. No coordinates — only the band. */
#define PEER_PROXIMITY_OBSERVED          ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 7))
/** Identity → app: a signed business ad — one opaque Ethne page bundle plus the advertiser's satisfaction (Phase 3 P3.2, @ref peer_business_ad_msg_t). Local IPC only. Signature-verified and content-id-deduped before emit; the BUNDLE is verified app-side, never by the core. */
#define PEER_BUSINESS_AD_OBSERVED        ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 8))
/** Identity → app: a peer asks this node to co-sign a staff-roll or guardianship record (Phase 3 P3.3, @ref peer_cosign_request_msg_t). Local IPC only. The core shape-checks the ask and carries the exported bytes; it holds no Ethne, so it verifies nothing about WHAT is being signed — and it never carries the wording, which the signer's own node derives from the bytes. */
#define PEER_COSIGN_REQUEST_OBSERVED     ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 9))
/** Identity → app: a signer returns their detached signature over an exchange this node is authoring (Phase 3 P3.3, @ref peer_cosign_sig_msg_t). Local IPC only. The signature is checked against the payload by the ASSEMBLING node, not by the core. */
#define PEER_COSIGN_SIG_OBSERVED         ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 10))
/** Identity → app: a signed business post — one opaque Ethne {post,delegation} bundle the ENVOY signed — received over the group channel (Phase 3 P3.4, @ref peer_business_post_msg_t). Local IPC only. Signature-verified, GATED on this node holding the polity's page, and content-id-deduped before emit; the BUNDLE is verified app-side, never by the core. */
#define PEER_BUSINESS_POST_OBSERVED      ((message_type_t)(AT_MSG_TYPE_SOCIAL_MIN + 11))

/* Max geohash length carried across the AT->app boundary. The app shares a
 * ~5-char geohash (the ~5km "neighborhood" bucket); the buffer allows finer
 * precision later without an ABI change. MUST match AT_APP_GEOHASH_LEN in
 * at_agora.h. */
#define AT_GEOHASH_MAX_LEN 12

/**
 * @brief AT → app: one peer's shared coarse position, as an opt-in geohash
 * bucket. Half of the geographic-distance feature (Increment 2); the app
 * computes distance from its own opted-in bucket. An empty @c geohash means the
 * peer shared none (opted out) — the ordinary, default case. Treat the geohash
 * as opaque and untrusted peer input. Local IPC only — the on-wire exchange is
 * the directed peer_position_query/response, not this message.
 */
typedef struct {
    uuid_t peer_uuid;
    /** NUL-terminated geohash; "" = none / opted out. */
    char   geohash[AT_GEOHASH_MAX_LEN + 1];
} peer_position_msg_t;

/*
 * A private-proximity result (Phase 2): the coarse distance BAND to one
 * CONNECTED peer, learned by exchanging pairwise-keyed grid tags. Carries NO
 * coordinates — only the band (see at_prox_band_t: 0 unknown, 1 near, 2 mid,
 * 3 far). Local IPC only; the on-wire exchange is the directed encrypted
 * peer_proximity_probe/reply, not this message.
 */
typedef struct {
    uuid_t peer_uuid;
    int    band; /**< at_prox_band_t */
} peer_proximity_msg_t;

/* Max bytes of the compact profile JSON carried across the AT->app boundary
 * (the sanitized field object; the signature stays in the core). MUST match
 * AT_PROFILE_JSON_MAX in social/profile.h and AT_APP_PROFILE_JSON_LEN in
 * at_agora.h. */
#define AT_PROFILE_JSON_LEN 2560

/**
 * @brief AT → app: one peer's shared agora.profile, as compact field JSON
 * (Increment 3). Emitted only AFTER the core has bound-validated the fields and
 * verified the peer's Ed25519 signature, so the app receives already-trusted
 * data; the signature itself does not cross. An empty @c profile_json means the
 * peer shared none (opted out). Local IPC only — the on-wire exchange is the
 * directed, signed peer_profile_query/response, not this message.
 */
typedef struct {
    uuid_t peer_uuid;
    /** NUL-terminated compact JSON object of profile fields; "" = none. */
    char   profile_json[AT_PROFILE_JSON_LEN + 1];
} peer_profile_msg_t;

/**
 * @brief AT → app: a connection edge event toward one peer (Increment 5).
 *
 * Carries the peer's uuid and this node's local edge state toward it
 * (@ref at_conn_state_t cast to int): none=0, pending_out=1, pending_in=2,
 * connected=3, declined=4. Used for BOTH @ref PEER_CONNECTION_REQUEST_OBSERVED
 * (an inbound ask; @c state is pending_in) and @ref PEER_CONNECTION_STATE_OBSERVED
 * (any edge transition). A connection is EXPLICIT and separate from reputation.
 * Local IPC only — the on-wire exchange is the directed peer_connection_request
 * / signed peer_connection_response, not this message.
 */
typedef struct {
    uuid_t  peer_uuid;
    int32_t state;   /**< @ref at_conn_state_t cast to int. */
} peer_connection_msg_t;

/* Max bytes of a DM body carried across the AT->app boundary (Increment 6).
 * MUST match AT_DM_TEXT_MAX in social/dm.h, AT_APP_DM_TEXT_LEN in at_agora.h,
 * and AGORA_DM_TEXT_MAX in the shim / cohort ctypes. */
#define AT_DM_TEXT_LEN 1024

/**
 * @brief AT → app: one directed text message received from a peer (Increment 6).
 *
 * A DM is a single directed, ENCRYPTED peer→peer message; crypto_box already
 * authenticates the sender, so no extra signature is needed and the sender uuid
 * is trustworthy. @c seq is the sender's freshness sequence (a replayed/stale
 * seq is dropped before this is emitted); @c ts is the sender's send time (epoch
 * seconds). @c text is bound-truncated to @ref AT_DM_TEXT_LEN bytes. Local IPC
 * only, and a LIVE STREAM — delivered on arrival, never replayed as roster
 * state. The on-wire form is the directed encrypted peer_dm verb, not this
 * message.
 */
typedef struct {
    uuid_t  peer_uuid;   /**< The SENDER's uuid. */
    int64_t seq;         /**< The sender's freshness sequence. */
    double  ts;          /**< The sender's send time (epoch seconds). */
    /** NUL-terminated message body, bound-truncated to AT_DM_TEXT_LEN bytes. */
    char    text[AT_DM_TEXT_LEN + 1];
} peer_dm_msg_t;

/* Max bytes of a post body carried across the AT->app boundary (Increment 7).
 * MUST match AT_POST_BODY_MAX in social/post.h, AT_APP_POST_BODY_LEN in
 * at_agora.h, and AGORA_POST_BODY_MAX in the shim / cohort ctypes. */
#define AT_POST_BODY_LEN 4096
/* Content id: blake2b-256 digest as lowercase hex (32 bytes -> 64 chars). MUST
 * match AT_POST_ID_HEX_LEN in social/post.h, AT_APP_POST_ID_LEN in
 * at_agora.h, and AGORA_POST_ID_MAX in the shim / cohort ctypes. */
#define AT_POST_ID_LEN 64

/**
 * @brief AT → app: one signed feed post received over the group channel
 * (Increment 7).
 *
 * A post is a signed, content-addressed feed item distributed by encrypted group
 * multicast and gossip-forwarded a bounded number of hops. @c peer_uuid is the
 * AUTHOR (bound by the Ed25519 signature the core verified before emitting, NOT
 * by the wire envelope). @c post_id is the blake2b content-address of the
 * canonical form — the dedup/merge key. @c seq is the author's post sequence,
 * @c ts the author's post time (epoch seconds), @c required_tier the audience
 * floor (0..4). @c body is bound-truncated to @ref AT_POST_BODY_LEN bytes. Local
 * IPC only; the on-wire form is the group-encrypted peer_post verb, not this
 * message.
 */
typedef struct {
    uuid_t  peer_uuid;   /**< The AUTHOR's uuid (signature-bound). */
    /** NUL-terminated blake2b content id (lowercase hex). */
    char    post_id[AT_POST_ID_LEN + 1];
    int64_t seq;         /**< The author's post sequence. */
    double  ts;          /**< The author's post time (epoch seconds). */
    int32_t required_tier; /**< Audience floor 0..4. */
    /** NUL-terminated post body, bound-truncated to AT_POST_BODY_LEN bytes. */
    char    body[AT_POST_BODY_LEN + 1];
} peer_post_msg_t;

/**
 * @brief AT → app: one reaction to one of OUR posts, received from a peer
 * (Increment 8).
 *
 * A reaction is a single directed, ENCRYPTED reactor→author message; crypto_box
 * authenticates the reactor, so no extra signature is needed and @c peer_uuid (the
 * REACTOR) is trustworthy. @c post_id is the content-id of the post reacted to.
 * @c seq is the reactor's freshness sequence (a stale/replayed seq is dropped
 * before this is emitted); @c ts is the reactor's send time. Local IPC only; the
 * on-wire form is the directed encrypted peer_reaction verb, not this message.
 */
typedef struct {
    uuid_t  peer_uuid;   /**< The REACTOR's uuid. */
    /** NUL-terminated content id of the post reacted to (lowercase hex). */
    char    post_id[AT_POST_ID_LEN + 1];
    int64_t seq;         /**< The reactor's freshness sequence. */
    double  ts;          /**< The reactor's send time (epoch seconds). */
} peer_reaction_msg_t;

/* Max bytes of the opaque Ethne page bundle carried across the AT->app boundary
 * (Phase 3 P3.2). MUST match AT_BUSINESS_BUNDLE_MAX in social/business_ad.h,
 * AT_APP_BUSINESS_BUNDLE_LEN in at_agora.h, and AGORA_BUSINESS_BUNDLE_MAX in
 * the shim / cohort ctypes. */
#define AT_BUSINESS_BUNDLE_LEN 3072
/* Max bytes of a polity DID. MUST match AT_BUSINESS_DID_MAX in
 * social/business_ad.h, AT_APP_BUSINESS_DID_LEN in at_agora.h, and
 * AGORA_BUSINESS_DID_MAX in the shim / cohort ctypes. */
#define AT_BUSINESS_DID_LEN 95
/* Ad content id: blake2b-256 digest as lowercase hex (32 bytes -> 64 chars).
 * MUST match AT_BUSINESS_AD_ID_HEX_LEN in social/business_ad.h,
 * AT_APP_BUSINESS_AD_ID_LEN in at_agora.h, and AGORA_BUSINESS_AD_ID_MAX in the
 * shim / cohort ctypes. */
#define AT_BUSINESS_AD_ID_LEN 64

/**
 * @brief AT → app: one signed business ad received over the group channel
 * (Phase 3 P3.2, "businesses near me").
 *
 * @c peer_uuid is the ADVERTISER — bound by the Ed25519 signature the core
 * verified before emitting, NOT by the wire envelope — and is either the
 * business's own node or a CUSTOMER re-advertising from its cache in the first
 * person. There is no relay and no hop count: only customers carry a page, and
 * they always speak for themselves (see social/business_ad.h).
 *
 * @c polity is the business's Ethne DID (the page store's key), @c satisfaction
 * the advertiser's declared 0..4 rating or @ref AT_BUSINESS_SAT_SELF for the
 * business's own ad, @c seq the page version, @c ts the advertiser's send time.
 * @c ad_id is the blake2b content-address of the canonical form — the dedup key.
 *
 * @c bundle is the OPAQUE, self-verifying Ethne page artifact ({page,delegation}
 * proving polity-root → envoy → page). The core never parses it; the APP
 * verifies it. Local IPC only; the on-wire form is the group-encrypted
 * peer_business_ad verb, not this message.
 */
typedef struct {
    uuid_t  peer_uuid;   /**< The ADVERTISER's uuid (signature-bound). */
    /** NUL-terminated polity DID — the business this ad is for. */
    char    polity[AT_BUSINESS_DID_LEN + 1];
    /** NUL-terminated blake2b ad content id (lowercase hex). */
    char    ad_id[AT_BUSINESS_AD_ID_LEN + 1];
    int32_t satisfaction; /**< 0..4, or AT_BUSINESS_SAT_SELF (255) for the business's own ad. */
    int64_t seq;         /**< The page version the advertiser is carrying. */
    double  ts;          /**< The advertiser's send time (epoch seconds). */
    /** NUL-terminated opaque Ethne bundle, bound-truncated to AT_BUSINESS_BUNDLE_LEN. */
    char    bundle[AT_BUSINESS_BUNDLE_LEN + 1];
} peer_business_ad_msg_t;

/* Max bytes of the opaque Ethne {post,delegation} bundle carried across the
 * AT->app boundary (Phase 3 P3.4). LARGER than the page bundle's 3072 because
 * the body rides inside it: the measured worst case is 3550 bytes (see
 * social/business_post.h). Still under AT_COSIGN_BYTES_LEN, so the
 * generic_msg_t and at_app_event_t unions do not widen. MUST match
 * AT_BUSINESS_POST_BUNDLE_MAX in social/business_post.h,
 * AT_APP_BUSINESS_POST_BUNDLE_LEN in at_agora.h, and
 * AGORA_BUSINESS_POST_BUNDLE_MAX in the shim / cohort ctypes. */
#define AT_BUSINESS_POST_BUNDLE_LEN 4096
/* Post content id: blake2b-256 digest as lowercase hex (32 bytes -> 64 chars).
 * MUST match AT_BUSINESS_POST_ID_HEX_LEN in social/business_post.h,
 * AT_APP_BUSINESS_POST_ID_LEN in at_agora.h, and AGORA_BUSINESS_POST_ID_MAX
 * in the shim / cohort ctypes. */
#define AT_BUSINESS_POST_ID_LEN 64

/**
 * @brief AT → app: one signed business post received over the group channel
 * (Phase 3 P3.4, "business posts in the feed").
 *
 * @c peer_uuid is the node that PUBLISHED these bytes — bound by the Ed25519
 * signature the core verified before emitting, and always the original, since
 * a relay forwards the envelope untouched and changes only @c hops. It is NOT
 * the authority behind the post: that is the envoy signature inside @c bundle,
 * and only the app can check it. Nobody can alter a word without breaking both
 * signatures at once.
 *
 * @c polity is the business's Ethne DID (and the key the page-cache gate was
 * answered with), @c seq the business's own post sequence, @c ts the sender's
 * time, @c hops how far this copy has travelled. @c post_id is the blake2b
 * content-address of the canonical form — the dedup key that makes gossip
 * converge.
 *
 * @c bundle is the OPAQUE, self-verifying Ethne post artifact
 * ({post,delegation} proving polity-root → envoy → post). The core never parses
 * it; the APP verifies it. Local IPC only; the on-wire form is the
 * group-encrypted peer_business_post verb, not this message.
 */
typedef struct {
    uuid_t  peer_uuid;   /**< The PUBLISHER (signature-bound), not the authority, and never a relay. */
    /** NUL-terminated polity DID — the business whose words these are. */
    char    polity[AT_BUSINESS_DID_LEN + 1];
    /** NUL-terminated blake2b post content id (lowercase hex). */
    char    post_id[AT_BUSINESS_POST_ID_LEN + 1];
    int64_t seq;         /**< The business's own post sequence. */
    double  ts;          /**< The sender's time (epoch seconds). */
    int32_t hops;        /**< How far this copy has travelled (0 = from the business). */
    /** NUL-terminated opaque Ethne bundle, bound-truncated to AT_BUSINESS_POST_BUNDLE_LEN. */
    char    bundle[AT_BUSINESS_POST_BUNDLE_LEN + 1];
} peer_business_post_msg_t;

/* Max hex characters of a detached exchange's exported canonical bytes (Phase 3
 * P3.3). MUST match AT_COSIGN_BYTES_MAX in social/cosign.h,
 * AT_APP_COSIGN_BYTES_LEN in at_agora.h, COSIGN_BYTES_HEX_MAX in the agora
 * ethne_ffi crate, and AGORA_COSIGN_BYTES_MAX in the shim / cohort ctypes. */
#define AT_COSIGN_BYTES_LEN 6144
/* Max bytes of a polity DID, or of a signer's did:key. MUST match
 * AT_COSIGN_DID_MAX in social/cosign.h, AT_APP_COSIGN_DID_LEN in
 * at_agora.h, and AGORA_COSIGN_DID_MAX in the shim / cohort ctypes. */
#define AT_COSIGN_DID_LEN 95
/* Exchange content id as Ethne prints it: "b3:" + 64 lowercase hex. MUST match
 * AT_COSIGN_CID_MAX in social/cosign.h, AT_APP_COSIGN_CID_LEN in
 * at_agora.h, and AGORA_COSIGN_CID_MAX in the shim / cohort ctypes. */
#define AT_COSIGN_CID_LEN 67
/* An Ed25519 signature as lowercase hex (64 bytes -> 128 chars). MUST match
 * AT_COSIGN_SIG_MAX in social/cosign.h, AT_APP_COSIGN_SIG_LEN in
 * at_agora.h, and AGORA_COSIGN_SIG_MAX in the shim / cohort ctypes. */
#define AT_COSIGN_SIG_LEN 128
/* A record-class or op token ("membership", "guardian", "designate", …). MUST
 * match AT_COSIGN_TOKEN_MAX in social/cosign.h, AT_APP_COSIGN_TOKEN_LEN in
 * at_agora.h, and AGORA_COSIGN_TOKEN_MAX in the shim / cohort ctypes. */
#define AT_COSIGN_TOKEN_LEN 15

/**
 * @brief AT → app: a peer asks this node to co-sign one record (Phase 3 P3.3).
 *
 * A staff roll act is decided by several people who are not at the same
 * keyboard, and their KEYS DO NOT TRAVEL. The record does: one node exports its
 * canonical bytes, each required signer signs those exact bytes on their own
 * node, and the authoring node reassembles the signatures.
 *
 * @c peer_uuid is the REQUESTER, bound by crypto_box on the directed encrypted
 * envelope — nobody can put an ask in somebody else's mouth. @c record is
 * "membership" or "guardian" and @c op the act within it; @c polity the Ethne
 * DID; @c cid the exchange's content address; @c bytes the exported canonical
 * CBOR as lowercase hex.
 *
 * **The core verifies nothing about what is being signed**, exactly as it
 * verifies nothing about a business page bundle: it holds no Ethne. It bounds
 * and shape-checks the fields (known op, even-length lowercase hex) so a
 * malformed ask is refused rather than carried.
 *
 * **No description travels.** What the record commits to, in words, is derived
 * on the SIGNER's node from these bytes. Carrying the wording would let the
 * asking node choose both what you sign and what you are told you are signing.
 *
 * Local IPC only; the on-wire form is the directed encrypted peer_cosign_request
 * verb, not this message.
 */
typedef struct {
    uuid_t  peer_uuid;   /**< The REQUESTER's uuid (crypto_box-authenticated). */
    /** NUL-terminated record class: "membership" or "guardian". */
    char    record[AT_COSIGN_TOKEN_LEN + 1];
    /** NUL-terminated op: admit/expel, or designate/rotate/release. */
    char    op[AT_COSIGN_TOKEN_LEN + 1];
    /** NUL-terminated polity DID this record belongs to. */
    char    polity[AT_COSIGN_DID_LEN + 1];
    /** NUL-terminated exchange content id ("b3:<hex>"), NOT recomputed here. */
    char    cid[AT_COSIGN_CID_LEN + 1];
    int64_t seq;         /**< The requester's freshness sequence. */
    double  ts;          /**< The requester's send time (epoch seconds). */
    /** NUL-terminated exported canonical bytes, lowercase hex. Opaque. */
    char    bytes[AT_COSIGN_BYTES_LEN + 1];
} peer_cosign_request_msg_t;

/**
 * @brief AT → app: a signer returns their detached signature (Phase 3 P3.3).
 *
 * @c peer_uuid is the returning peer (crypto_box-authenticated). @c cid names
 * the exchange, @c signer the signing did:key — which EMBEDS its public key, so
 * the assembling node needs no registry to check the signature — and @c sig the
 * detached Ed25519 signature over the exported bytes, as lowercase hex.
 *
 * The core does not check the signature, and could not: it does not hold the
 * payload. Verification happens where it belongs, on the ASSEMBLING node, which
 * refuses a wrong key or a tampered payload before anything is appended.
 *
 * Local IPC only; the on-wire form is the directed encrypted peer_cosign_sig
 * verb, not this message.
 */
typedef struct {
    uuid_t  peer_uuid;   /**< The SIGNER's uuid (crypto_box-authenticated). */
    /** NUL-terminated exchange content id this signature is for. */
    char    cid[AT_COSIGN_CID_LEN + 1];
    /** NUL-terminated signer did:key (embeds the public key). */
    char    signer[AT_COSIGN_DID_LEN + 1];
    /** NUL-terminated detached Ed25519 signature, lowercase hex. */
    char    sig[AT_COSIGN_SIG_LEN + 1];
    int64_t seq;         /**< The signer's freshness sequence. */
    double  ts;          /**< The signer's send time (epoch seconds). */
} peer_cosign_sig_msg_t;

/****************************
 * The app verbs (App → AT, local-only), moved from utilities/message.h when
 * social left the core (FEATURE_SPLIT_PLAN Phase 5). Each is routed to the
 * identity process by an AT_APP_VERB_REGISTER in social_msg_types.c.
 ****************************/
/**
 * @brief App → AT local-only verb: set (or clear) THIS node's own opt-in coarse
 * position, so the identity process can answer peers' directed position queries.
 *
 * The payload is the operator's chosen geohash bucket, or empty to opt out
 * (clears it). STRICTLY OPT-IN: absent this verb, `own_geohash` stays empty and
 * the node advertises and answers nothing geographic. Forwarded only to the
 * identity process. Second (and only other) verb on the app→AT allowlist.
 */
#define AT_APP_SET_POSITION "app_set_position"

/* App→AT: set/replace THIS node's opt-in agora.profile (Increment 3). The
 * payload is the profile object itself; empty clears it (opt out). Forwarded
 * only to the identity process. Third verb on the app→AT allowlist. */
#define AT_APP_SET_PROFILE "app_set_profile"

/* App→AT: request an explicit connection to a peer (Increment 5). The payload
 * is {"peer": "<uuid_str>"}; identity sets our edge to pending_out and sends a
 * directed encrypted peer_connection_request to that peer. Forwarded only to
 * the identity process. Fourth verb on the app→AT allowlist. */
#define AT_APP_CONNECT_REQUEST "app_connect_request"

/* App→AT: respond to an inbound connection request (Increment 5). The payload
 * is {"peer": "<uuid_str>", "accept": <bool>}; identity sets our edge to
 * connected/declined and sends a directed encrypted, SIGNED
 * peer_connection_response. Forwarded only to the identity process. Fifth verb
 * on the app→AT allowlist. */
#define AT_APP_CONNECT_RESPOND "app_connect_respond"

/* App→AT: send a directed text message to a peer (Increment 6). The payload is
 * {"peer": "<uuid_str>", "text": "<body>"}; identity sends a directed encrypted
 * peer_dm carrying {text, seq, ts} to that peer. The app echoes the outgoing
 * message locally (the core does not echo it back). Forwarded only to the
 * identity process. Sixth verb on the app→AT allowlist. */
#define AT_APP_SEND_DM "app_send_dm"

/* App→AT: publish a feed post to the local group (Increment 7). The payload is
 * {"body": "<body>", "tier": <int 0..4>}; identity signs the post with this
 * node's Ed25519 key, group-encrypts it and multicasts it on the group channel.
 * The app echoes the outgoing post locally (the core does not echo it back).
 * Forwarded only to the identity process. Seventh verb on the app→AT allowlist. */
#define AT_APP_PUBLISH_POST "app_publish_post"

/* App→AT: react to a feed post (Increment 8). The payload is {"author":
 * "<uuid_str>", "post_id": "<hex>"}; identity sends a directed encrypted
 * peer_reaction {post_id, seq, ts} to the post's author. The reaction is the
 * return signal a fire-and-forget post otherwise lacks, so both the reactor and
 * the author submit a reputation score for the same post-derived task and the
 * engagement accrues. Forwarded only to the identity process. Eighth verb on the
 * app→AT allowlist. */
#define AT_APP_REACT_POST "app_react_post"

/* App→AT: locally block a peer (Increment 8). The payload is {"peer":
 * "<uuid_str>"}; identity clamps that peer's effective trust tier to 0 for THIS
 * node only. Purely local: no reputation transaction and nothing on the wire
 * (unlike a decline). Forwarded only to the identity process. Ninth verb on the
 * app→AT allowlist. */
#define AT_APP_BLOCK "app_block"

/* App→AT: lift a local block (Phase 4 P4.1). The payload is {"peer":
 * "<uuid_str>"}; identity removes the record and re-emits peer_observed so the
 * app sees the change land.
 *
 * A SEPARATE VERB rather than a flag on AT_APP_BLOCK, matching the
 * CONNECT_REQUEST / CONNECT_RESPOND pair: moderation is a surface where "what
 * did the operator actually ask for" should be answerable from one grep of the
 * log, and an overloaded verb with a boolean loses that.
 *
 * The blocked peer is told nothing, exactly as they were told nothing about
 * the block. Forwarded only to the identity process. Nineteenth verb on the
 * app→AT allowlist. */
#define AT_APP_UNBLOCK "app_unblock"

/* App→AT: pull a FRESH operator-attendance attestation from a peer NOW (Phase 2,
 * presence). The payload is {"peer": "<uuid_str>"}; identity issues a
 * nonce-fresh operator_attest_query to that peer and, on the response, updates
 * the peer's operator_attested_at and re-emits peer_observed. Forwarded only to
 * the identity process. Tenth verb on the app→AT allowlist. */
#define AT_APP_REQUEST_ATTEND "app_request_attend"

/* App→AT: set (or clear) THIS node's opt-in EXACT position (Phase 2, private
 * proximity). The payload is {"lat": <deg>, "lon": <deg>} or empty to opt out.
 * STORED LOCAL-ONLY and NEVER advertised — it feeds only the pairwise, encrypted
 * distance-band probe with CONNECTED peers (it is never read by any query
 * handler). Forwarded only to the identity process. Eleventh verb on the
 * app→AT allowlist. */
#define AT_APP_SET_EXACT_POSITION "app_set_exact_position"

/* App→AT: run a private-proximity probe against a CONNECTED peer (Phase 2). The
 * payload is {"peer": "<uuid_str>"}; identity derives multi-resolution grid tags
 * keyed by the pairwise box secret and exchanges them so both sides learn only a
 * coarse distance BAND (near/mid/far), never coordinates. Forwarded only to the
 * identity process. Twelfth verb on the app→AT allowlist. */
#define AT_APP_REQUEST_PROXIMITY "app_request_proximity"

/* App→AT: publish (or re-publish) THIS node's OWN business page (Phase 3 P3.2).
 * The payload is {"polity": "<did>", "bundle": "<opaque ethne json>", "seq": <int>};
 * identity signs the canonical ad with this node's Ed25519 key, marks it as the
 * business's own (satisfaction AT_BUSINESS_SAT_SELF), group-encrypts it and
 * multicasts it. The bundle is opaque to the core — it is the app that proves
 * polity-root → envoy → page. Forwarded only to the identity process.
 * Thirteenth verb on the app→AT allowlist. */
#define AT_APP_ADVERTISE_BUSINESS "app_advertise_business"

/* App→AT: declare, update or clear THIS node's CUSTOMER edge to a business
 * (Phase 3 P3.2). The payload is {"polity": "<did>", "satisfaction": <0..4>,
 * "bundle": "<opaque ethne json>", "seq": <int>}, or {"polity": "<did>",
 * "satisfaction": -1} to clear it. A customer edge is what authorizes this node
 * to CARRY the page: on set, identity caches the bundle and advertises it in the
 * FIRST PERSON (signed by us, with our satisfaction); on clear, this node simply
 * goes quiet about that business — an unhappy customer publishes nothing
 * negative, so silence is the only negative signal. Forwarded only to the
 * identity process. Fourteenth verb on the app→AT allowlist. */
#define AT_APP_SET_CUSTOMER "app_set_customer"

/* App→AT: ask named peers to co-sign one staff-roll or guardianship record
 * (Phase 3 P3.3). The payload is {"peers": ["<uuid_str>", …], "record":
 * "membership"|"guardian", "op": "<act>", "polity": "<did>", "cid": "<b3:hex>",
 * "bytes": "<canonical cbor as hex>"}; identity sends each named peer a directed
 * ENCRYPTED peer_cosign_request. The KEYS NEVER TRAVEL — the record does, and
 * each signer signs it where their key already lives.
 *
 * The core carries the bytes and verifies nothing about them: it holds no Ethne,
 * just as it holds no verifier for a page bundle. It does bound and shape-check
 * the ask, and it deliberately carries NO description — what the record commits
 * to is derived on the signer's own node from these bytes, so the asking node
 * cannot choose both what you sign and what you are told you are signing.
 * Forwarded only to the identity process. Fifteenth verb on the app→AT
 * allowlist. */
#define AT_APP_REQUEST_COSIGN "app_request_cosign"

/* App→AT: return this node's detached signature over an exchange a peer is
 * authoring (Phase 3 P3.3). The payload is {"peer": "<uuid_str>", "cid":
 * "<b3:hex>", "signer": "<did:key>", "sig": "<hex>"}; identity sends the
 * requester a directed ENCRYPTED peer_cosign_sig. The signature is checked
 * against the payload by the ASSEMBLING node, which is the only one holding it.
 * Forwarded only to the identity process. Sixteenth verb on the app→AT
 * allowlist. */
#define AT_APP_RETURN_COSIGN "app_return_cosign"

/* App→AT: publish a business POST — the polity speaking (Phase 3 P3.4). The
 * payload is {"polity": "<did>", "bundle": "<opaque ethne {post,delegation}>",
 * "seq": <int>}; identity signs the canonical post with this node's Ed25519
 * key, group-encrypts it and multicasts it, and inbound copies are relayed a
 * bounded number of hops.
 *
 * The bundle is opaque to the core, exactly as a page bundle is: the ENVOY
 * signature inside it is what makes these the business's words, and only the
 * app can check it. Being on the roll — or running this verb at all — confers
 * nothing. Forwarded only to the identity process. Seventeenth verb on the
 * app→AT allowlist. */
#define AT_APP_PUBLISH_BUSINESS_POST "app_publish_business_post"

/* App→AT: report a peer (Phase 4 P4.1). The payload is {"peer": "<uuid_str>"};
 * identity sends that peer a directed ENCRYPTED peer_report {seq, ts} and, only
 * if the frame went, stages AT_SOCIAL_REPORT_SCORE about them on the
 * `first_person` channel.
 *
 * NO REASON TRAVELS, and none is accepted here. The reason the operator picked
 * stays in the app; on the wire it would turn a score into a published
 * accusation.
 *
 * A REPORT IS REFUSABLE. Reputation is bilateral, so it commits only when the
 * reported node stages its own half — which a node running forked code need
 * not do. That is the standing bargain of the model, not a hole in this verb,
 * and it is why an authority finding is a ceiling (AT_APP_PEER_STANDING) instead.
 *
 * A report does NOT imply a block, and a block does not stop a report: they are
 * two verbs, and "Block · Report · Both" is the app sending both. Forwarded
 * only to the identity process. Twentieth verb on the app→AT allowlist. */
#define AT_APP_REPORT_PEER "app_report_peer"

/**
 * @brief Pull the social type registrations into a static link.
 *
 * The registrations are constructors in social_msg_types.c; a static link
 * keeps that object only if something references it. Every core entry point
 * that handles social types (identity handler registration, the app-event
 * carrier) calls this. It does nothing at run time.
 */
void at_social_msg_types_link(void);

/** @} */ /* end of internal_utilities */

#endif  // SOCIAL_MSG_TYPES_H
