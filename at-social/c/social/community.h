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
 * @file community.h
 * @brief A community's content policy on the wire, and a moderator's label on a
 *        post (Phase 4, Ethne D37): canonical forms, Ed25519 sign/verify,
 *        blake2b content ids and the JSON envelopes.
 *
 * A community is an Ethne polity, and how content posted in its name is
 * moderated is its roll's decision. Two artifacts carry that decision, and the
 * core parses NEITHER: each is opaque bytes here, verified by the app
 * (business_post.h draws the same line for a business's words).
 *
 *   POLICY AD (peer_community_policy) — the community's root-signed policy
 *     artifact, CARRIED IN THE FIRST PERSON by a node that follows the community,
 *     exactly as a customer carries a business page (business_ad.h). Never
 *     relayed: whoever you hear it from is vouching with its own key that it
 *     holds this. The AT signature binds the CARRIER to these bytes; the
 *     community's authority is the root signature inside them.
 *
 *       canonical = carrier_uuid[16]
 *                 || u32le(did_len) || community_did_bytes
 *                 || u64le(seq) || f64le(ts)
 *                 || u32le(bundle_len) || bundle_bytes
 *
 *   POST LABEL (peer_post_label) — a moderator's member-signed labels on one
 *     post, GOSSIP-RELAYED like a business post (business_post.h): its authority
 *     is inside the bundle, so carrying it launders nothing. The AT signature
 *     binds the node that first PUBLISHED these bytes, and relays forward the
 *     envelope untouched, changing only the hop count, which sits outside the
 *     signature for that reason.
 *
 *       canonical = author_uuid[16]
 *                 || u32le(did_len) || community_did_bytes
 *                 || post_id[64]      (the labelled post's content id, ASCII hex)
 *                 || u64le(seq) || f64le(ts)
 *                 || u32le(bundle_len) || bundle_bytes
 *
 * The blake2b-256 of each canonical form, lowercase hex, is its content id and
 * dedup key. MUST stay in lockstep with the Python policy_ad_* / post_label_*
 * in social/codec.py.
 */

#ifndef AUTONOMOUS_TRUST_IDENTITY_COMMUNITY_H
#define AUTONOMOUS_TRUST_IDENTITY_COMMUNITY_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <uuid/uuid.h>
#include <sodium.h>
#include <jansson.h>

/* Max bytes of a community's policy artifact (excluding NUL). MEASURED worst
 * case 2980 (ethne_ffi). Pinned against AT_COMMUNITY_POLICY_BUNDLE_LEN
 * (social_msg_types.h) in the .c. */
#define AT_COMMUNITY_POLICY_BUNDLE_MAX 4096

/* Max bytes of a moderator's label (excluding NUL). MEASURED worst case 969.
 * Pinned against AT_POST_LABEL_BUNDLE_LEN in the .c. */
#define AT_POST_LABEL_BUNDLE_MAX 1536

/* Max bytes of a community DID: a polity, bounded as a business is. */
#define AT_COMMUNITY_DID_MAX 95

/* Content ids: blake2b-256, lowercase hex. */
#define AT_COMMUNITY_ID_HEX_LEN 64

/* Detached Ed25519 signature as lowercase hex. */
#define AT_COMMUNITY_SIG_HEX_LEN (crypto_sign_BYTES * 2)

#define AT_POLICY_AD_CANON_MAX \
    (16 + 4 + AT_COMMUNITY_DID_MAX + 8 + 8 + 4 + AT_COMMUNITY_POLICY_BUNDLE_MAX)
#define AT_POST_LABEL_CANON_MAX \
    (16 + 4 + AT_COMMUNITY_DID_MAX + AT_COMMUNITY_ID_HEX_LEN + 8 + 8 + 4 \
     + AT_POST_LABEL_BUNDLE_MAX)

/* Bound-copies: truncate to the named bound AND to fit @p out_sz, always
 * NUL-terminating. Return the bytes written. */
size_t at_community_bound_did(const char *in, char *out, size_t out_sz);
size_t at_community_bound_policy(const char *in, char *out, size_t out_sz);
size_t at_community_bound_label(const char *in, char *out, size_t out_sz);

/* Whether @p id is AT_COMMUNITY_ID_HEX_LEN lowercase hex (a post content id). */
bool at_community_post_id_valid(const char *id);

/* ---- The policy ad -------------------------------------------------------- */

size_t at_policy_ad_canonical(const uuid_t carrier_uuid, const char *community,
                              int64_t seq, double ts, const char *bundle,
                              uint8_t *out, size_t outcap);
int at_policy_ad_id(const uuid_t carrier_uuid, const char *community, int64_t seq,
                    double ts, const char *bundle, char *id_hex_out);
int at_policy_ad_sign(const unsigned char sk[crypto_sign_SECRETKEYBYTES],
                      const uuid_t carrier_uuid, const char *community,
                      int64_t seq, double ts, const char *bundle,
                      char *sig_hex_out);
bool at_policy_ad_verify(const unsigned char pk[crypto_sign_PUBLICKEYBYTES],
                         const uuid_t carrier_uuid, const char *community,
                         int64_t seq, double ts, const char *bundle,
                         const char *sig_hex);
/* {"carrier","carrier_pk","community","seq","ts","bundle","sig"}; NEW object. */
json_t *at_policy_ad_to_json(const uuid_t carrier_uuid, const char *carrier_pk_hex,
                             const char *community, int64_t seq, double ts,
                             const char *bundle, const char *sig_hex);
/* Parse an envelope. Every field is required; an empty community or bundle, a
 * key or signature of the wrong length, or a bad uuid is malformed (non-zero). */
int at_policy_ad_from_json(const json_t *obj, uuid_t carrier_out,
                           char carrier_pk_out[AT_COMMUNITY_SIG_HEX_LEN + 1],
                           char *community_out, size_t community_sz,
                           int64_t *seq_out, double *ts_out,
                           char *bundle_out, size_t bundle_sz,
                           char sig_out[AT_COMMUNITY_SIG_HEX_LEN + 1]);

/* ---- The post label --------------------------------------------------------- */

size_t at_post_label_canonical(const uuid_t author_uuid, const char *community,
                               const char *post_id, int64_t seq, double ts,
                               const char *bundle, uint8_t *out, size_t outcap);
int at_post_label_id(const uuid_t author_uuid, const char *community,
                     const char *post_id, int64_t seq, double ts,
                     const char *bundle, char *id_hex_out);
int at_post_label_sign(const unsigned char sk[crypto_sign_SECRETKEYBYTES],
                       const uuid_t author_uuid, const char *community,
                       const char *post_id, int64_t seq, double ts,
                       const char *bundle, char *sig_hex_out);
bool at_post_label_verify(const unsigned char pk[crypto_sign_PUBLICKEYBYTES],
                          const uuid_t author_uuid, const char *community,
                          const char *post_id, int64_t seq, double ts,
                          const char *bundle, const char *sig_hex);
/* {"author","author_pk","community","post_id","seq","ts","bundle","sig","hops"}. */
json_t *at_post_label_to_json(const uuid_t author_uuid, const char *author_pk_hex,
                              const char *community, const char *post_id,
                              int64_t seq, double ts, const char *bundle,
                              const char *sig_hex, int hops);
/* Parse an envelope; as at_policy_ad_from_json, plus a post id that is not 64
 * lowercase hex or a negative hop count is malformed. @p post_id_out holds
 * AT_COMMUNITY_ID_HEX_LEN + 1. */
int at_post_label_from_json(const json_t *obj, uuid_t author_out,
                            char author_pk_out[AT_COMMUNITY_SIG_HEX_LEN + 1],
                            char *community_out, size_t community_sz,
                            char post_id_out[AT_COMMUNITY_ID_HEX_LEN + 1],
                            int64_t *seq_out, double *ts_out,
                            char *bundle_out, size_t bundle_sz,
                            char sig_out[AT_COMMUNITY_SIG_HEX_LEN + 1],
                            int *hops_out);

#endif /* AUTONOMOUS_TRUST_IDENTITY_COMMUNITY_H */
