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
 * @file at_agora_shim.h
 * @brief Flat, union-free FFI surface over AutonomousTrust's app-events API.
 *
 * Dart's dart:ffi can bind the raw `at_app_event_t` (a tagged union) directly,
 * but doing so couples the Dart struct layout to AT's frozen-but-appendable
 * event enum and its union ABI. This shim flattens each event into a single
 * fixed-layout `agora_event_t`, and silently drops event kinds it does not yet
 * understand — so a newer AT that appends event kinds cannot break the app.
 *
 * All four calls wrap the fork-free app-events *client* subset (AF_UNIX socket
 * I/O only); nothing here forks. The AT daemon runs in a separate process
 * (`agorad`), so the GUI process never calls `fork()`.
 */

#ifndef AT_AGORA_SHIM_H
#define AT_AGORA_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Mirror of AT_APP_UUID_LEN / AT_APP_SIGNING_KEY_LEN (app_events.h). Kept in
 * sync via the compile-time assertions in at_agora_shim.c. */
#define AGORA_UUID_LEN 16
#define AGORA_KEY_LEN  32
/* Max geohash length. MUST match AT_APP_GEOHASH_LEN (at_agora.h). */
#define AGORA_GEOHASH_LEN 12
/* Max compact-profile-JSON length. MUST match AT_APP_PROFILE_JSON_LEN
 * (at_agora.h) / AT_PROFILE_JSON_LEN (social_msg_types.h). */
#define AGORA_PROFILE_JSON_MAX 2560
/* Max DM body length. MUST match AT_APP_DM_TEXT_LEN (at_agora.h) /
 * AT_DM_TEXT_LEN (social_msg_types.h). */
#define AGORA_DM_TEXT_MAX 1024
/* Max feed-post body length. MUST match AT_APP_POST_BODY_LEN (at_agora.h) /
 * AT_POST_BODY_LEN (social_msg_types.h). */
#define AGORA_POST_BODY_MAX 4096
/* Post content-id length (blake2b-256 lowercase hex). MUST match
 * AT_APP_POST_ID_LEN (at_agora.h) / AT_POST_ID_LEN (social_msg_types.h). */
#define AGORA_POST_ID_MAX 64
/* Max opaque Ethne page-bundle length on a business ad (Phase 3 P3.2). MUST
 * match AT_APP_BUSINESS_BUNDLE_LEN (at_agora.h) / AT_BUSINESS_BUNDLE_LEN
 * (social_msg_types.h). */
#define AGORA_BUSINESS_BUNDLE_MAX 3072
/* Max polity DID length. MUST match AT_APP_BUSINESS_DID_LEN / AT_BUSINESS_DID_LEN. */
#define AGORA_BUSINESS_DID_MAX 95
/* Business-ad content-id length (blake2b-256 lowercase hex). MUST match
 * AT_APP_BUSINESS_AD_ID_LEN / AT_BUSINESS_AD_ID_LEN. */
#define AGORA_BUSINESS_AD_ID_MAX 64
/* A business advertising its OWN page rather than a customer rating it. MUST
 * match AT_APP_BUSINESS_SAT_SELF (at_agora.h) / AT_BUSINESS_SAT_SELF. */
#define AGORA_BUSINESS_SAT_SELF 0xFF
/* Max opaque Ethne {post,delegation} bundle length on a business post (Phase 3
 * P3.4). Larger than the page bundle because the body rides inside it; the
 * measured worst case is 3550. MUST match AT_APP_BUSINESS_POST_BUNDLE_LEN
 * (at_agora.h) / AT_BUSINESS_POST_BUNDLE_LEN (social_msg_types.h) /
 * AT_BUSINESS_POST_BUNDLE_MAX (social/business_post.h). */
#define AGORA_BUSINESS_POST_BUNDLE_MAX 4096
/* Business-post content-id length (blake2b-256 lowercase hex). MUST match
 * AT_APP_BUSINESS_POST_ID_LEN / AT_BUSINESS_POST_ID_LEN. */
#define AGORA_BUSINESS_POST_ID_MAX 64
/* Max hex characters of a detached exchange's exported canonical bytes (Phase 3
 * P3.3). MUST match AT_APP_COSIGN_BYTES_LEN (at_agora.h) /
 * AT_COSIGN_BYTES_LEN (social_msg_types.h) / AT_COSIGN_BYTES_MAX (social/cosign.h) /
 * COSIGN_BYTES_HEX_MAX (ethne_ffi). */
#define AGORA_COSIGN_BYTES_MAX 6144
/* Max polity DID or signer did:key length. MUST match AT_APP_COSIGN_DID_LEN. */
#define AGORA_COSIGN_DID_MAX 95
/* Exchange content id ("b3:" + 64 hex). MUST match AT_APP_COSIGN_CID_LEN. */
#define AGORA_COSIGN_CID_MAX 67
/* Detached Ed25519 signature as lowercase hex. MUST match AT_APP_COSIGN_SIG_LEN. */
#define AGORA_COSIGN_SIG_MAX 128
/* Record-class or op token. MUST match AT_APP_COSIGN_TOKEN_LEN. */
#define AGORA_COSIGN_TOKEN_MAX 15

/* Phase 4 communities. A post's community is a polity DID (AGORA_BUSINESS_DID_MAX);
 * its labels cross joined with ','. MUST match AT_APP_POST_LABELS_LEN. */
#define AGORA_POST_LABELS_MAX 263
/* A community's opaque, root-signed policy artifact. MUST match
 * AT_APP_COMMUNITY_POLICY_BUNDLE_LEN; measured worst case 2980 (ethne_ffi). */
#define AGORA_COMMUNITY_POLICY_BUNDLE_MAX 4096
/* A moderator's opaque, member-signed label. MUST match
 * AT_APP_POST_LABEL_BUNDLE_LEN; measured worst case 969. */
#define AGORA_POST_LABEL_BUNDLE_MAX 1536

/* kind discriminator (a superset-safe subset of at_app_event_kind_t). */
#define AGORA_EVENT_PEER               1
#define AGORA_EVENT_REPUTATION         2
#define AGORA_EVENT_RTT                3
#define AGORA_EVENT_POSITION           4
#define AGORA_EVENT_PROFILE            5
#define AGORA_EVENT_CONNECTION_REQUEST 6
#define AGORA_EVENT_CONNECTION_STATE   7
#define AGORA_EVENT_DM                 8
#define AGORA_EVENT_POST               9
#define AGORA_EVENT_REACTION           10
#define AGORA_EVENT_PROXIMITY          11
#define AGORA_EVENT_BUSINESS_AD        12
#define AGORA_EVENT_COSIGN_REQUEST     13
#define AGORA_EVENT_COSIGN_SIGNATURE   14
#define AGORA_EVENT_BUSINESS_POST      15
#define AGORA_EVENT_COMMUNITY_POLICY   16
#define AGORA_EVENT_POST_LABEL         17
/* Proximity hubs (Phase 4, SOCIAL_APP_PLAN §4.1). fc_kind is the AT
 * first-contact kind (at_first_contact.h) the event came from. */
#define AGORA_EVENT_AREA               18  /* fc_kind 1023..1030: listings, cards, rosters */
#define AGORA_EVENT_CONTACT            19  /* fc_kind 1000..1022: links, the address book,
                                              asking/answering, devices, siblings */
/* The encrypted backup (Phase 4, multi-device). fc_kind is 1031..1033. */
#define AGORA_EVENT_BACKUP             20
/* File sharing in a DM thread: one transfer's state (the file_* fields). */
#define AGORA_EVENT_FILE               21

/* File-sharing bounds; MUST match AT_APP_FILE_*_LEN in at_agora.h. */
#define AGORA_FILE_ID_MAX     32
#define AGORA_FILE_NAME_MAX   255
#define AGORA_FILE_PATH_MAX   4095
#define AGORA_FILE_REASON_MAX 31
/* file_state; MUST match AT_APP_FILE_* and the Dart FileTransferState. */
#define AGORA_FILE_OFFERED   0
#define AGORA_FILE_ACCEPTED  1
#define AGORA_FILE_DONE      2
#define AGORA_FILE_DECLINED  3
#define AGORA_FILE_CANCELLED 4
#define AGORA_FILE_FAILED    5
#define AGORA_FILE_TOO_LARGE 6

/* First-contact field bounds; MUST match at_first_contact.h. */
#define AGORA_FC_REF_MAX      63
#define AGORA_FC_HANDLE_MAX   128
#define AGORA_FC_NICKNAME_MAX 128
#define AGORA_FC_RELAY_MAX    79
#define AGORA_FC_REASON_MAX   31
#define AGORA_AREA_MAX        7
#define AGORA_AREA_NAME_MAX   64
#define AGORA_FC_ISSUER_MAX   64
/* Address book, devices and backup (Phase 4 multi-device); MUST match
 * at_first_contact.h (AT_FC_BLOB_LEN, _SAFETY_NUMBER_LEN, _PATH_LEN,
 * _PASSPHRASE_LEN, each a NUL past these). */
#define AGORA_FC_BLOB_MAX          7679
#define AGORA_FC_SAFETY_NUMBER_MAX 71
#define AGORA_BACKUP_PATH_MAX      4095
#define AGORA_BACKUP_PASSPHRASE_MAX 31
/* fc_origin: where an address-book change came from. */
#define AGORA_FC_ORIGIN_LOCAL   0
#define AGORA_FC_ORIGIN_SIBLING 1   /* another of our own devices */
#define AGORA_FC_ORIGIN_BACKUP  2   /* a restored backup */

/**
 * One flattened app event. Field order is ABI-significant: the Dart
 * `AgoraEvent` struct in lib/src/ffi/at_events_bindings.dart mirrors it exactly.
 */
typedef struct {
    int32_t kind;                              /* AGORA_EVENT_* */
    uint8_t peer_uuid[AGORA_UUID_LEN];
    uint8_t signing_pubkey[AGORA_KEY_LEN];
    int32_t rank;
    uint8_t operator_bound;                    /* 0/1 */
    double  operator_attested_at;              /* epoch seconds; 0 = none */
    uint8_t operator_pubkey[AGORA_KEY_LEN];
    double  rep_score;                         /* valid only when rep_rated */
    uint8_t rep_rated;                         /* 0/1 */
    /* Appended after the earlier fields; every PRIOR field offset is unchanged
     * (rtt_ms stays at offset 116), so only the tail grew. Field order is
     * ABI-significant — the Dart `AgoraEvent` struct and the ctypes `Ev` in
     * test/cohort/two_node_cohort.sh mirror it exactly. */
    int32_t rtt_ms;                            /* AGORA_EVENT_RTT; 0 = unknown */
    /* AGORA_EVENT_POSITION: peer's shared coarse geohash bucket; "" = none.
     * Appended after rtt_ms (offset 120); with it sizeof(agora_event_t) == 136.
     * The Dart AgoraEvent and the ctypes Ev in the cohort test mirror this
     * order and total size exactly (both re-check sizeof). */
    char    geohash[AGORA_GEOHASH_LEN + 1];
    /* AGORA_EVENT_PROFILE: peer's shared agora.profile as compact field JSON;
     * "" = none. Appended after geohash; the Dart AgoraEvent and the ctypes Ev
     * in the cohort test mirror this order and the new total size exactly (both
     * re-check sizeof). The core already verified the signature, so this is
     * trusted data — the signature itself does not cross this boundary. */
    char    profile_json[AGORA_PROFILE_JSON_MAX + 1];
    /* AGORA_EVENT_CONNECTION_REQUEST / AGORA_EVENT_CONNECTION_STATE (Increment
     * 5): this node's local connection edge state toward the peer — none=0,
     * pending_out=1, pending_in=2, connected=3, declined=4. Appended LAST after
     * profile_json so every prior field offset is unchanged; the Dart AgoraEvent
     * and the ctypes Ev in the cohort tests mirror this order and the new total
     * size exactly (all re-check sizeof). A connection is EXPLICIT and separate
     * from reputation — NO trust tier crosses here. */
    int32_t connection_state;
    /* AGORA_EVENT_DM (Increment 6): a directed text message received from the
     * peer. Appended LAST after connection_state so every prior field offset is
     * unchanged; the Dart AgoraEvent and the ctypes Ev in the cohort test mirror
     * this order and the new total size exactly (all re-check sizeof). A DM is a
     * live stream — dm_seq is the sender's freshness sequence (a replay guard),
     * dm_ts the sender's send time (epoch seconds), dm_text the NUL-terminated
     * body (bound-truncated to AGORA_DM_TEXT_MAX). crypto_box already
     * authenticated the sender, so peer_uuid is trustworthy. */
    int64_t dm_seq;
    double  dm_ts;
    char    dm_text[AGORA_DM_TEXT_MAX + 1];
    /* AGORA_EVENT_POST (Increment 7): a signed feed post received over the group
     * channel. Appended LAST after dm_text so every prior field offset is
     * unchanged; the Dart AgoraEvent and the ctypes Ev in the cohort test mirror
     * this order and the new total size exactly (all re-check sizeof). peer_uuid
     * carries the SIGNATURE-BOUND author. post_id is the blake2b content-address
     * (dedup key); post_seq the author's post sequence; post_ts the author's post
     * time (epoch seconds); post_required_tier the audience floor (0..4);
     * post_body the NUL-terminated body (bound-truncated to AGORA_POST_BODY_MAX).
     * The core verified the author's signature, tier-gated and deduped the post
     * before it crossed, so this is trusted data; the signature does not cross. */
    char    post_id[AGORA_POST_ID_MAX + 1];
    int64_t post_seq;
    double  post_ts;
    int32_t post_required_tier;
    char    post_body[AGORA_POST_BODY_MAX + 1];
    /* AGORA_EVENT_REACTION (Increment 8): a peer reacted to one of OUR posts.
     * Appended LAST after post_body so every prior field offset is unchanged; the
     * Dart AgoraEvent and the ctypes Ev in the cohort test mirror this order and
     * the new total size exactly (all re-check sizeof). peer_uuid carries the
     * REACTOR (crypto_box-authenticated); reaction_post_id is the content-id of the
     * post reacted to; reaction_seq the reactor's freshness sequence; reaction_ts
     * the reactor's send time (epoch seconds). */
    char    reaction_post_id[AGORA_POST_ID_MAX + 1];
    int64_t reaction_seq;
    double  reaction_ts;
    /* AGORA_EVENT_PEER: true iff this peer shares OUR group (its address is in
     * our group's address_map). Appended LAST after reaction_ts so every prior
     * field offset is unchanged; the Dart AgoraEvent and the ctypes Ev in the
     * cohort tests mirror this order and the new total size exactly (all re-check
     * sizeof). Distinct from connection_state: an "in your group" indicator, not
     * an explicit connection edge. */
    uint8_t in_group;                          /* AGORA_EVENT_PEER; 0/1 */
    /* AGORA_EVENT_PROXIMITY: the coarse distance band to a CONNECTED peer
     * (0 unknown, 1 near ~1km, 2 mid ~5km, 3 far). Appended LAST after in_group
     * (Phase 2); the Dart AgoraEvent and the cohort ctypes Ev mirror this order
     * and re-check the new sizeof. No coordinates cross this boundary. */
    int32_t proximity_band;                    /* AGORA_EVENT_PROXIMITY */
    /* AGORA_EVENT_BUSINESS_AD (Phase 3 P3.2): a signed business ad — one opaque
     * Ethne page bundle plus the advertiser's satisfaction. Appended LAST after
     * proximity_band so every prior field offset is unchanged; the Dart
     * AgoraEvent and the cohort ctypes Ev mirror this order and re-check the new
     * sizeof. peer_uuid carries the SIGNATURE-BOUND advertiser — the business
     * itself, or a CUSTOMER re-advertising in the first person (an ad is never
     * relayed, so an advertiser always vouches with its own key).
     *
     * business_satisfaction is 0..4, or AGORA_BUSINESS_SAT_SELF for the
     * business's own ad. business_bundle is OPAQUE and NOT verified by the core:
     * the app must run the self-contained Ethne verifier (polity root -> envoy ->
     * page) on it before trusting the page. What the core DID verify is the ad
     * signature — that this advertiser vouched for these exact bytes. */
    char    business_polity[AGORA_BUSINESS_DID_MAX + 1];
    char    business_ad_id[AGORA_BUSINESS_AD_ID_MAX + 1];
    int32_t business_satisfaction;
    int64_t business_seq;
    double  business_ts;
    char    business_bundle[AGORA_BUSINESS_BUNDLE_MAX + 1];
    /* AGORA_EVENT_COSIGN_REQUEST / AGORA_EVENT_COSIGN_SIGNATURE (Phase 3 P3.3):
     * the detached co-signing exchange. Appended LAST after business_bundle so
     * every prior field offset is unchanged; the Dart AgoraEvent and the cohort
     * ctypes Ev mirror this order and re-check the new sizeof.
     *
     * peer_uuid carries the REQUESTER on a request and the SIGNER on a
     * signature, crypto_box-authenticated either way. cosign_record is
     * "membership" or "guardian" and cosign_op the act within it; cosign_polity
     * the Ethne DID; cosign_cid the exchange's content address; cosign_bytes the
     * exported canonical CBOR as lowercase hex, on a request only.
     *
     * cosign_bytes is OPAQUE and NOT verified by the core, exactly like
     * business_bundle: derive what it commits to HERE (ethne_describe) and show
     * the operator that. NO description crosses this boundary on purpose — if
     * the asking node supplied the wording as well as the payload, it would
     * choose both what you sign and what you are told you are signing.
     *
     * On a signature, cosign_signer_did is the signing did:key (it embeds the
     * public key, so no registry is needed) and cosign_sig the detached Ed25519
     * signature over those bytes. The core did not check it and could not: it
     * does not hold the payload. The assembling node does. */
    char    cosign_record[AGORA_COSIGN_TOKEN_MAX + 1];
    char    cosign_op[AGORA_COSIGN_TOKEN_MAX + 1];
    char    cosign_polity[AGORA_COSIGN_DID_MAX + 1];
    char    cosign_cid[AGORA_COSIGN_CID_MAX + 1];
    char    cosign_signer_did[AGORA_COSIGN_DID_MAX + 1];
    char    cosign_sig[AGORA_COSIGN_SIG_MAX + 1];
    int64_t cosign_seq;
    double  cosign_ts;
    char    cosign_bytes[AGORA_COSIGN_BYTES_MAX + 1];
    /* AGORA_EVENT_BUSINESS_POST (Phase 3 P3.4): the business speaking, in the
     * feed. Appended LAST after cosign_bytes so every prior field offset is
     * unchanged; the Dart AgoraEvent and the cohort ctypes Ev mirror this order
     * and re-check the new sizeof.
     *
     * peer_uuid is the node that PUBLISHED the post — always the original,
     * never a relay, since a relay forwards the envelope untouched and changes
     * only business_post_hops. It is NOT the authority. business_post_polity
     * names the business, business_post_seq is its own post counter,
     * business_post_hops how far THIS COPY travelled, business_post_id the
     * blake2b content address (the dedup key, one per post however many paths
     * it took).
     *
     * business_post_bundle is OPAQUE and NOT verified by the core, exactly like
     * business_bundle: it is the Ethne {post,delegation} artifact, and the
     * ENVOY signature inside it is the only thing that makes these the
     * business's words. Run ethne_business_post_verify_bundle before rendering
     * anything under the business's name — being on the roll, or having
     * published it, confers nothing. What the core DID verify is the sender's
     * signature: that these exact bytes arrived unaltered. */
    char    business_post_polity[AGORA_BUSINESS_DID_MAX + 1];
    char    business_post_id[AGORA_BUSINESS_POST_ID_MAX + 1];
    int64_t business_post_seq;
    double  business_post_ts;
    int32_t business_post_hops;
    char    business_post_bundle[AGORA_BUSINESS_POST_BUNDLE_MAX + 1];
    /* Moderation (Phase 4 P4.1). Appended LAST after business_post_bundle, so
     * every prior field offset is unchanged; the Dart AgoraEvent and the cohort
     * ctypes Ev mirror this order and re-check the new sizeof.
     *
     * blocked rides AGORA_EVENT_PEER — identity's own state, since identity is
     * what holds the block. rep_tier and rep_ceiling ride
     * AGORA_EVENT_REPUTATION — reputation's. Compose them exactly as the core
     * does: a blocked peer's effective tier is 0 whatever they have earned.
     *
     * Before P4.1 a block emitted NOTHING and the app derived a peer's tier
     * from the score, which a block does not touch — so a blocked peer went on
     * rendering exactly as before. These three fields are what make a block,
     * and a community's bound, visible at all.
     *
     * rep_ceiling is AGORA_NO_CEILING (-1) when the peer is unbounded. It is
     * written on every reputation event and left at that sentinel elsewhere —
     * READ IT ONLY ON AGORA_EVENT_REPUTATION. The flatten path memsets each
     * event, so an unwritten 0.0 would read as "floored at zero". */
    uint8_t blocked;                           /* AGORA_EVENT_PEER; 0/1 */
    int32_t rep_tier;                          /* AGORA_EVENT_REPUTATION; 0..4 */
    double  rep_ceiling;                       /* AGORA_EVENT_REPUTATION */
    /* Communities (Phase 4, Ethne D37). Appended LAST after rep_ceiling, so
     * every prior field offset is unchanged; the Dart AgoraEvent and the cohort
     * ctypes Ev mirror this order and re-check the new sizeof.
     *
     * post_community / post_labels ride AGORA_EVENT_POST: the community a post
     * was made in ("" = none) and the author's labels joined with ','. Both are
     * SIGNED with the post. The core applied no policy; the app does, and only
     * for communities it follows.
     *
     * policy_* ride AGORA_EVENT_COMMUNITY_POLICY: a policy carried by a node that
     * follows the community; peer_uuid is the CARRIER. policy_bundle is OPAQUE
     * and NOT verified by the core — run ethne_content_policy_verify on it, and
     * keep the highest seq that verifies, before following or trusting it.
     *
     * label_* ride AGORA_EVENT_POST_LABEL: a moderator's labels on post
     * label_post_id; peer_uuid is the PUBLISHER. label_bundle is OPAQUE — it
     * counts only if ethne_post_label_verify accepts it against the policy you
     * hold. */
    char    post_community[AGORA_BUSINESS_DID_MAX + 1];
    char    post_labels[AGORA_POST_LABELS_MAX + 1];
    char    policy_community[AGORA_BUSINESS_DID_MAX + 1];
    char    policy_id[AGORA_POST_ID_MAX + 1];
    int64_t policy_seq;
    double  policy_ts;
    char    policy_bundle[AGORA_COMMUNITY_POLICY_BUNDLE_MAX + 1];
    char    label_community[AGORA_BUSINESS_DID_MAX + 1];
    char    label_post_id[AGORA_POST_ID_MAX + 1];
    char    label_id[AGORA_POST_ID_MAX + 1];
    int64_t label_seq;
    double  label_ts;
    int32_t label_hops;
    char    label_bundle[AGORA_POST_LABEL_BUNDLE_MAX + 1];
    /* Proximity hubs (Phase 4, §4.1). Appended LAST after label_bundle, so every
     * prior offset is unchanged; the Dart AgoraEvent and the cohort ctypes Ev
     * mirror this order and re-check the new sizeof.
     *
     * AGORA_EVENT_AREA: fc_kind is AT_APP_EVENT_AREA_* / _ROSTER_*. On a CARD,
     * peer_uuid is the person found, area_bucket their coarse bucket, area_name
     * what they list under, fc_relay the hub; ask them with agora_area_request.
     * On DONE, fc_count is how many CARDs the lookup sent and fc_reason
     * "limited" when a hub rate-limited it. On ROSTER_*, area_issuer is the
     * community key.
     *
     * AGORA_EVENT_CONTACT: fc_kind is AT_APP_EVENT_DIR_* (a request sent, a
     * CONTACT_REQUEST to answer with agora_contact_accept / _decline by fc_ref,
     * accepted, declined, refused) or AT_APP_EVENT_FC_* (hello sent,
     * ESTABLISHED: the two are now direct peers, never group members).
     * fc_handle is where the requester found us, "area:<area>" for a hub. */
    int32_t fc_kind;
    char    fc_ref[AGORA_FC_REF_MAX + 1];
    char    fc_handle[AGORA_FC_HANDLE_MAX + 1];
    char    fc_nickname[AGORA_FC_NICKNAME_MAX + 1];
    char    fc_relay[AGORA_FC_RELAY_MAX + 1];
    char    fc_reason[AGORA_FC_REASON_MAX + 1];
    char    area[AGORA_AREA_MAX + 1];
    char    area_bucket[AGORA_AREA_MAX + 1];
    char    area_name[AGORA_AREA_NAME_MAX + 1];
    char    area_issuer[AGORA_FC_ISSUER_MAX + 1];
    int64_t fc_seq;
    int32_t fc_count;
    /* Address book, devices and backup (Phase 4 multi-device). Appended LAST
     * after fc_count, so every prior offset is unchanged; the Dart AgoraEvent
     * and the cohort ctypes Ev mirror this order and re-check the new sizeof.
     *
     * AGORA_EVENT_CONTACT, fc_kind AT_APP_EVENT_FC_*:
     *   INVITATION: fc_blob is the link to share (`at+contact:`), fc_expiry
     *     when it stops working (0 = never). A pairing link looks the same.
     *   REFUSED: fc_count is the at_fc_reason_t (NOT_SIBLING = a pairing that
     *     did not make two siblings); ESTABLISHED / REFUSED carry fc_role.
     *   CONTACT / VERIFIED / SAFETY_NUMBER / REMOVED / DEVICE_LINKED: peer_uuid
     *     is the record (its first device), fc_nickname / fc_petname /
     *     fc_verified / fc_provenance / fc_added_at / fc_verified_at describe
     *     it. fc_safety_number on SAFETY_NUMBER, fc_method on VERIFIED,
     *     fc_peer_dropped on REMOVED, fc_device_uuid on DEVICE_LINKED (the
     *     further device; a list sends one per device after the record),
     *     fc_origin on CONTACT / REMOVED (AGORA_FC_ORIGIN_*). CONTACTS_DONE:
     *     fc_count records.
     *   SIBLING_PAIRED: peer_uuid / fc_nickname the device paired. SIBLING:
     *     one of ours (fc_added_at). SIBLINGS_DONE: fc_count. SIBLING_REMOVED:
     *     fc_peer_dropped.
     * AGORA_EVENT_BACKUP, fc_kind AT_APP_EVENT_BACKUP_*: backup_path; on
     *   WRITTEN, backup_passphrase if the node made one (show it ONCE; it is
     *   never stored) and backup_contacts / _siblings in the file; on RESTORED,
     *   backup_added / _updated / _removed / _siblings and backup_contacts now
     *   in the book; on REFUSED, fc_reason ("weak_passphrase", ...). */
    char    fc_blob[AGORA_FC_BLOB_MAX + 1];
    int64_t fc_expiry;
    int32_t fc_role;
    char    fc_petname[AGORA_FC_NICKNAME_MAX + 1];
    uint8_t fc_verified;                       /* 0/1 */
    int32_t fc_provenance;                     /* 0 in person .. 5 backup */
    double  fc_added_at;
    double  fc_verified_at;
    char    fc_safety_number[AGORA_FC_SAFETY_NUMBER_MAX + 1];
    int32_t fc_method;
    uint8_t fc_peer_dropped;                   /* 0/1 */
    uint8_t fc_device_uuid[AGORA_UUID_LEN];
    int32_t fc_origin;
    char    backup_path[AGORA_BACKUP_PATH_MAX + 1];
    char    backup_passphrase[AGORA_BACKUP_PASSPHRASE_MAX + 1];
    int32_t backup_contacts;
    int32_t backup_siblings;
    int32_t backup_added;
    int32_t backup_updated;
    int32_t backup_removed;
    /* File sharing in a DM thread. Appended LAST after backup_removed, so
     * every prior offset is unchanged; the Dart AgoraEvent and the cohort
     * ctypes Ev mirror this order and re-check the new sizeof.
     *
     * AGORA_EVENT_FILE: peer_uuid is the other end (crypto_box-authenticated)
     * and with file_xfer_id names the transfer. file_outgoing is 1 when we
     * send. file_state is AGORA_FILE_*; file_done the bytes held (incoming)
     * or served (outgoing); file_reason a token on FAILED. file_name is a
     * bare, sanitized name, never a path. file_path is the source on an
     * outgoing transfer and the finished file on an incoming one once DONE.
     * The bytes never cross this boundary. */
    int64_t file_size;
    int64_t file_done;
    double  file_ts;
    int32_t file_state;
    int32_t file_outgoing;                     /* 0/1 */
    char    file_xfer_id[AGORA_FILE_ID_MAX + 1];
    char    file_name[AGORA_FILE_NAME_MAX + 1];
    char    file_reason[AGORA_FILE_REASON_MAX + 1];
    char    file_path[AGORA_FILE_PATH_MAX + 1];
} agora_event_t;

/* ---- Proximity hubs (Phase 4, §4.1). Each needs first contact on in the
 * daemon (AT_FIRST_CONTACT=1) and answers with AGORA_EVENT_AREA / _CONTACT. */
/** List us in @p area at its hubs, under @p bucket (inside it) and @p name. */
int agora_area_publish(void *handle, const char *send_queue, const char *ref,
                       const char *area, const char *bucket, const char *name);
int agora_area_withdraw(void *handle, const char *send_queue, const char *ref,
                        const char *area);
/** Who else is listed in @p area (only while we are). */
int agora_area_lookup(void *handle, const char *send_queue, const char *ref,
                      const char *area);
/** Ask @p peer_uuid (16 bytes), found in @p area, to become a contact. */
int agora_area_request(void *handle, const char *send_queue, const char *ref,
                       const char *area, const uint8_t *peer_uuid);
/** Answer a CONTACT_REQUEST, by the fc_ref it carried. */
int agora_contact_accept(void *handle, const char *send_queue, const char *request_ref);
int agora_contact_decline(void *handle, const char *send_queue, const char *request_ref);
/** Trust a community's relay roster (the file text a verified policy carries). */
int agora_relay_roster_install(void *handle, const char *send_queue, const char *ref,
                               const char *roster);
int agora_relay_roster_remove(void *handle, const char *send_queue, const char *ref,
                              const char *issuer);

/* ---- Address book, devices and backup (Phase 4 multi-device). Each needs
 * first contact on in the daemon and answers with AGORA_EVENT_CONTACT /
 * _BACKUP, tagged with @p ref. A peer is its 16-byte uuid. */
/** Mint a link for someone to add us; @p ttl_seconds <0 = a week, 0 = never. */
int agora_fc_invite(void *handle, const char *send_queue, const char *ref,
                    long ttl_seconds);
/** Mint a PAIRING link for another device of ours (needs a device cert). */
int agora_fc_pair_invite(void *handle, const char *send_queue, const char *ref,
                         long ttl_seconds);
/** Redeem a link (a contact's, or our own device's pairing link). @p in_person
 *  ONLY when it crossed face to face; @p petname NULL = derived. */
int agora_fc_initiate(void *handle, const char *send_queue, const char *ref,
                      const char *invitation, int in_person, const char *petname);
int agora_fc_list(void *handle, const char *send_queue, const char *ref);
int agora_fc_safety_number(void *handle, const char *send_queue, const char *ref,
                           const uint8_t *peer_uuid);
/** @p presented: digits typed from their screen; or NULL with @p confirmed 1. */
int agora_fc_verify(void *handle, const char *send_queue, const char *ref,
                    const uint8_t *peer_uuid, const char *presented, int confirmed);
int agora_fc_rename(void *handle, const char *send_queue, const char *ref,
                    const uint8_t *peer_uuid, const char *petname);
int agora_fc_remove(void *handle, const char *send_queue, const char *ref,
                    const uint8_t *peer_uuid);
int agora_sibling_list(void *handle, const char *send_queue, const char *ref);
int agora_sibling_remove(void *handle, const char *send_queue, const char *ref,
                         const uint8_t *peer_uuid);
/** Seal the book to @p path (absolute); @p passphrase NULL = the node makes one. */
int agora_backup_export(void *handle, const char *send_queue, const char *ref,
                        const char *path, const char *passphrase);
int agora_backup_import(void *handle, const char *send_queue, const char *ref,
                        const char *path, const char *passphrase);

/** Set $AUTONOMOUS_TRUST_ROOT for THIS process, so the app-events client below
 *  resolves its queue sockets under the same $root/var/at/ as the `agorad`
 *  daemon. The GUI process and the daemon must agree on the root; the Dart side
 *  cannot setenv its own process, so it calls this once before agora_events_open.
 *  No-op if @p root is NULL/empty. */
void agora_set_root(const char *root);

/** Open the receive queue (AT -> app; this is `q_in` in at_node_config_t
 *  terms). Pass a BARE name (e.g. "at_to_extern"); it is rooted under
 *  $AUTONOMOUS_TRUST_ROOT/var/at/. Returns an opaque handle, or NULL on failure. */
void *agora_events_open(const char *recv_queue);

/** Ask the daemon to (re)send the current roster. `send_queue` is the app -> AT
 *  queue (`q_out` in at_node_config_t terms). Returns 0 on success, negative on
 *  error (including AT_APP_NOT_READY == -2 if the daemon is not up yet). */
int agora_events_request_roster(void *handle, const char *send_queue);

/** Set (or clear) THIS node's own opt-in coarse position. `send_queue` is the
 *  app -> AT queue; `geohash` is the operator's chosen bucket, or NULL/"" to opt
 *  out. STRICTLY OPT-IN: nothing geographic is shared until this is called with a
 *  non-empty geohash. Returns 0 on success, negative on error (AT_APP_NOT_READY
 *  == -2 if the daemon is not up yet). */
int agora_set_position(void *handle, const char *send_queue, const char *geohash);

/** Set (or clear) THIS node's own opt-in agora.profile. `send_queue` is the
 *  app -> AT queue; `profile_json` is a JSON object of the profile fields
 *  ({display_name, handle, bio, avatar_ref, links}), or NULL/"" to opt out. The
 *  identity process truncates each field to its bound and shares the result,
 *  signed, only with admitted peers that ask. Returns 0 on success, negative on
 *  error (AT_APP_NOT_READY == -2 if the daemon is not up yet). */
int agora_set_profile(void *handle, const char *send_queue, const char *profile_json);

/** Request an explicit connection to a peer (Increment 5). `send_queue` is the
 *  app -> AT queue; `peer_uuid` is the peer's 16 raw identity bytes. The identity
 *  process sets our edge to pending_out and sends a directed encrypted request.
 *  Returns 0 on success, negative on error (AT_APP_NOT_READY == -2). */
int agora_connect_request(void *handle, const char *send_queue,
                          const uint8_t *peer_uuid);

/** Respond to an inbound connection request (Increment 5). `send_queue` is the
 *  app -> AT queue; `peer_uuid` is the requester's 16 raw identity bytes;
 *  `accept` non-zero connects, zero declines. The identity process sets our edge
 *  and sends a directed encrypted, SIGNED response. Returns 0 on success,
 *  negative on error (AT_APP_NOT_READY == -2). */
int agora_connect_respond(void *handle, const char *send_queue,
                          const uint8_t *peer_uuid, int accept);

/** Send a directed text message to a peer (Increment 6). `send_queue` is the
 *  app -> AT queue; `peer_uuid` is the recipient's 16 raw identity bytes; `text`
 *  is the message body (truncated to AGORA_DM_TEXT_MAX bytes). The identity
 *  process sends a directed encrypted peer_dm; the core does NOT echo it back.
 *  Returns 0 on success, negative on error (AT_APP_NOT_READY == -2). */
int agora_send_dm(void *handle, const char *send_queue,
                  const uint8_t *peer_uuid, const char *text);

/** Offer a file to one device of a peer (DM file sharing). `xfer_id` is 32
 *  lowercase hex the app chose, the SAME for every device of the person;
 *  `path` a regular file this node can read. Nothing moves until the peer
 *  accepts; an AGORA_EVENT_FILE (outgoing, OFFERED) comes back, or FAILED
 *  with a reason. Returns 0, AGORA_NOT_READY, or -1. */
int agora_file_offer(void *handle, const char *send_queue, const uint8_t *peer_uuid,
                     const char *xfer_id, const char *path);
/** Accept / decline an inbound offer, or cancel a transfer either way. */
int agora_file_accept(void *handle, const char *send_queue, const uint8_t *peer_uuid,
                      const char *xfer_id);
int agora_file_decline(void *handle, const char *send_queue, const uint8_t *peer_uuid,
                       const char *xfer_id);
int agora_file_cancel(void *handle, const char *send_queue, const uint8_t *peer_uuid,
                      const char *xfer_id);

/** Publish a feed post to the local group (Increment 7). `send_queue` is the
 *  app -> AT queue; `body` is the post body (truncated to AGORA_POST_BODY_MAX
 *  bytes); `required_tier` is the audience floor (0..4). The identity process
 *  signs the post, group-encrypts it and multicasts it on the group channel; the
 *  core does NOT echo it back. Returns 0 on success, negative on error
 *  (AT_APP_NOT_READY == -2). */
int agora_publish_post(void *handle, const char *send_queue,
                       const char *body, int required_tier);

/** React to a peer's post (Increment 8). `send_queue` is the app -> AT queue;
 *  `author_uuid` is the post author's 16 raw identity bytes; `post_id` is the
 *  post's content-id hex. The identity process sends a directed encrypted reaction
 *  to the author, and both peers accrue reputation for the engagement. Returns 0
 *  on success, negative on error (AT_APP_NOT_READY == -2). */
int agora_react_post(void *handle, const char *send_queue,
                     const uint8_t *author_uuid, const char *post_id);

/** Locally block a peer (Increment 8). `send_queue` is the app -> AT queue;
 *  `peer_uuid` is the peer's 16 raw identity bytes. The identity process clamps
 *  that peer's effective trust tier to 0 for THIS node only — purely local, no
 *  wire traffic and no reputation transaction. Returns 0 on success, negative on
 *  error (AT_APP_NOT_READY == -2). */
int agora_block(void *handle, const char *send_queue, const uint8_t *peer_uuid);

/** Lift a local block (Phase 4 P4.1). The core re-emits the peer, whose
 *  `blocked` flag then reads 0; the peer is told nothing. Returns 0 on success,
 *  negative on error (AT_APP_NOT_READY == -2). */
int agora_unblock(void *handle, const char *send_queue, const uint8_t *peer_uuid);

/** Report a peer (Phase 4 P4.1). `send_queue` is the app -> AT queue;
 *  `peer_uuid` is the peer's 16 raw identity bytes. The identity process sends
 *  the peer a directed encrypted report and stages a low first-person score
 *  about them. NO REASON TRAVELS: whatever the operator picked stays in the app.
 *
 *  A 0 means the ask was queued, not that the report was accepted: the daily
 *  caps (one report per peer per day, plus the shared accrual budget) are
 *  applied in the core afterwards, so the app keeps its own advisory count to
 *  grey the action out. A report does not block, and a block does not stop a
 *  report. Returns 0 on success, negative on error (AT_APP_NOT_READY == -2). */
int agora_report_peer(void *handle, const char *send_queue,
                      const uint8_t *peer_uuid);

/** Hand the core an AUTHORITY FINDING about a peer's standing (Phase 4 P4.1).
 *
 *  `standing` is "proved", "capped" or "failed"; `ceiling` is in [0, 1] or
 *  negative for "no bound"; `source` names the authority ("ethne").
 *
 *  A CEILING, NEVER A SCORE. The app has decided something AT's [0, 1] scale
 *  cannot express — a polity expelled this member — and a scalar penalty has no
 *  representation on that scale at all. The bound closes every tier-gate while
 *  leaving the peer above the network-layer cut-off, so an expulsion is a
 *  reputation event rather than a hard cut, and is reversible by the same
 *  authority: "proved" from the app means REINSTATED and lifts only THIS
 *  source's ceiling.
 *
 *  The core verifies NOTHING about the finding — an Ethne expulsion is proved
 *  by co-signatures inside a record it cannot parse, exactly as a page bundle
 *  is. It trusts that this arrived on the local app queue, and checks the shape.
 *  `source` may not be "zta": an app cannot know what a credential authority
 *  proved. Returns 0 on success, negative on error (AT_APP_NOT_READY == -2). */
int agora_peer_standing(void *handle, const char *send_queue,
                        const uint8_t *peer_uuid, const char *standing,
                        double ceiling, const char *source, const char *reason);

/** Pull a fresh operator-attendance attestation from a peer NOW (Phase 2,
 *  presence). `send_queue` is the app -> AT queue; `peer_uuid` is the peer's 16
 *  raw identity bytes. The identity process issues a nonce-fresh attest query;
 *  the refreshed operator_attested_at rides the next peer-observed event.
 *  Returns 0 on success, negative on error (AT_APP_NOT_READY == -2). */
int agora_request_attend(void *handle, const char *send_queue,
                         const uint8_t *peer_uuid);

/** Run a private-proximity probe against a CONNECTED peer (Phase 2). The
 *  identity process exchanges pairwise-keyed grid tags; both sides learn a
 *  coarse distance BAND (an AGORA_EVENT_PROXIMITY), never coordinates. Returns 0
 *  on success, negative on error (AT_APP_NOT_READY == -2). */
/** Publish THIS node's own business page (Phase 3 P3.2). `polity_did` is the
 *  business's Ethne DID, `bundle` the OPAQUE self-verifying page artifact the
 *  app built through Ethne, `seq` its version. Sends AT_APP_ADVERTISE_BUSINESS
 *  on the app -> AT queue; identity signs and group-multicasts it. Reach comes
 *  from customers re-advertising, not from this one call.
 *  @return 0 on success, AGORA_NOT_READY if the queue is not bound, -1 otherwise. */
int agora_advertise_business(void *handle, const char *send_queue,
                             const char *polity_did, const char *bundle,
                             int64_t seq);

/** Declare, update or clear THIS node's CUSTOMER edge to a business (Phase 3
 *  P3.2). The edge is what authorizes this node to CARRY the page: on set,
 *  identity caches `bundle` and advertises it in the FIRST PERSON, with
 *  `satisfaction` (0..4), and re-advertises whenever a fresh ad arrives. Pass a
 *  NEGATIVE `satisfaction` to clear the edge — an unhappy customer goes quiet
 *  rather than publishing anything negative. Pass NULL/"" for `bundle` to carry
 *  the page this node already learned. Sends AT_APP_SET_CUSTOMER.
 *  @return 0 on success, AGORA_NOT_READY if the queue is not bound, -1 otherwise. */
int agora_set_customer(void *handle, const char *send_queue,
                       const char *polity_did, int satisfaction,
                       const char *bundle, int64_t seq);

/** Publish a business POST — the polity speaking (Phase 3 P3.4). `polity_did`
 *  is the business's Ethne DID, `bundle` the OPAQUE self-verifying
 *  {post,delegation} artifact the app built through Ethne
 *  (ethne_business_post_sign paired with ethne_envoy_delegation), `seq` the
 *  business's own post counter. Sends AT_APP_PUBLISH_BUSINESS_POST; identity
 *  signs the canonical post with this node's key and group-multicasts it, and
 *  readers relay it one bounded hop.
 *
 *  THIS CALL CONFERS NO AUTHORITY. The core cannot tell an envoy from anyone
 *  else; a node that signs a bundle it holds no delegation for will put a post
 *  on the wire that every receiver refuses. Readers also drop a post from a
 *  polity they hold no page for, so an audience is reached through P3.2's ads
 *  first.
 *  @return 0 on success, AGORA_NOT_READY if the queue is not bound, -1 otherwise. */
int agora_publish_business_post(void *handle, const char *send_queue,
                                const char *polity_did, const char *bundle,
                                int64_t seq);

/** Publish a feed post in a community's name (Phase 4). As agora_publish_post,
 *  plus @p community (a polity DID, or NULL/"" for none) and @p labels_csv (the
 *  author's labels joined with ',', each 1..32 of [a-z0-9_-], at most eight;
 *  labels need a community). A malformed scope publishes nothing. */
int agora_publish_post_scoped(void *handle, const char *send_queue,
                              const char *body, int required_tier,
                              const char *community, const char *labels_csv);

/** Follow a community holding @p bundle (its root-signed policy, VERIFIED first
 *  with ethne_content_policy_verify) at @p seq; call again with a newer one to
 *  replace it. The node carries the policy and relays the community's labels. */
int agora_follow_community(void *handle, const char *send_queue,
                           const char *community, const char *bundle, int64_t seq);

/** Stop following a community. */
int agora_unfollow_community(void *handle, const char *send_queue,
                             const char *community);

/** Publish a moderator's label (ethne_post_label_sign) on post @p post_id. Confers
 *  nothing: a reader counts it only while its policy lists the moderator. */
int agora_publish_post_label(void *handle, const char *send_queue,
                             const char *community, const char *post_id,
                             const char *bundle, int64_t seq);

int agora_request_proximity(void *handle, const char *send_queue,
                            const uint8_t *peer_uuid);

/** Set (`opt_in` != 0) or clear THIS node's opt-in EXACT position (Phase 2).
 *  `lat`/`lon` are degrees. Stored LOCAL-ONLY by identity and never advertised —
 *  it feeds only the pairwise proximity probe. Returns 0 on success, negative on
 *  error (AT_APP_NOT_READY == -2). */
int agora_set_exact_position(void *handle, const char *send_queue, int opt_in,
                             double lat, double lon);

/** Ask named peers to co-sign one staff-roll or guardianship record (Phase 3
 *  P3.3). `peer_uuids` is `n_peers` × 16 raw identity bytes, laid out
 *  contiguously; `record`/`op` name the act; `cid` and `bytes` are the exchange
 *  as Ethne exported it, the bytes being canonical CBOR in lowercase hex.
 *
 *  No private key travels — that is the whole point of sending the record
 *  instead of gathering the keys. `bytes` must be reproduced EXACTLY: the
 *  signatures are over these bytes, so anything that truncates or re-encodes
 *  them yields signatures over nothing. An unknown op or a non-hex payload is
 *  refused here rather than carried. Deliberately no description parameter.
 *  @return 0 on success, AGORA_NOT_READY if the queue is not bound, -1 otherwise. */
int agora_request_cosign(void *handle, const char *send_queue,
                         const uint8_t *peer_uuids, int n_peers,
                         const char *record, const char *op,
                         const char *polity_did, const char *cid,
                         const char *bytes);

/** Return THIS node's detached signature to the peer authoring an exchange
 *  (Phase 3 P3.3). `peer_uuid` is the requester's 16 raw identity bytes; `cid`
 *  names the exchange; `signer_did` is this signer's did:key; `sig_hex` the
 *  detached Ed25519 signature over the exported bytes.
 *
 *  Sign only after deriving, on this node, what those bytes actually commit to.
 *  @return 0 on success, AGORA_NOT_READY if the queue is not bound, -1 otherwise. */
int agora_return_cosign(void *handle, const char *send_queue,
                        const uint8_t *peer_uuid, const char *cid,
                        const char *signer_did, const char *sig_hex);

/** @c rep_ceiling when no authority bounds the peer. Mirrors PEER_NO_CEILING.
 *  Any negative value means the same thing; this is the one written. */
#define AGORA_NO_CEILING (-1.0)

/** Non-blocking poll. Writes up to @p max flattened events into @p out. Returns
 *  the count written (0 = nothing arrived), or a negative AT error code. */
int agora_events_poll(void *handle, agora_event_t *out, int max);

/** Close the handle opened by agora_events_open(). */
void agora_events_close(void *handle);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* AT_AGORA_SHIM_H */
