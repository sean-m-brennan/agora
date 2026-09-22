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

#include "at_agora_shim.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include "autonomous_trust/app_events.h"

void agora_set_root(const char *root)
{
    if (root == NULL || root[0] == '\0')
        return;
    setenv("AUTONOMOUS_TRUST_ROOT", root, 1);
}

/* The shim's constants must match AT's. If AT ever changes these, the build
 * fails here rather than silently corrupting the Dart-side struct decode. */
_Static_assert(AGORA_UUID_LEN == AT_APP_UUID_LEN,
               "AGORA_UUID_LEN out of sync with AT_APP_UUID_LEN");
_Static_assert(AGORA_KEY_LEN == AT_APP_SIGNING_KEY_LEN,
               "AGORA_KEY_LEN out of sync with AT_APP_SIGNING_KEY_LEN");
_Static_assert(AGORA_GEOHASH_LEN == AT_APP_GEOHASH_LEN,
               "AGORA_GEOHASH_LEN out of sync with AT_APP_GEOHASH_LEN");
_Static_assert(AGORA_PROFILE_JSON_MAX == AT_APP_PROFILE_JSON_LEN,
               "AGORA_PROFILE_JSON_MAX out of sync with AT_APP_PROFILE_JSON_LEN");
_Static_assert(AGORA_DM_TEXT_MAX == AT_APP_DM_TEXT_LEN,
               "AGORA_DM_TEXT_MAX out of sync with AT_APP_DM_TEXT_LEN");
_Static_assert(AGORA_POST_BODY_MAX == AT_APP_POST_BODY_LEN,
               "AGORA_POST_BODY_MAX out of sync with AT_APP_POST_BODY_LEN");
_Static_assert(AGORA_POST_ID_MAX == AT_APP_POST_ID_LEN,
               "AGORA_POST_ID_MAX out of sync with AT_APP_POST_ID_LEN");
_Static_assert(AGORA_BUSINESS_BUNDLE_MAX == AT_APP_BUSINESS_BUNDLE_LEN,
               "AGORA_BUSINESS_BUNDLE_MAX out of sync with AT_APP_BUSINESS_BUNDLE_LEN");
_Static_assert(AGORA_BUSINESS_DID_MAX == AT_APP_BUSINESS_DID_LEN,
               "AGORA_BUSINESS_DID_MAX out of sync with AT_APP_BUSINESS_DID_LEN");
_Static_assert(AGORA_BUSINESS_AD_ID_MAX == AT_APP_BUSINESS_AD_ID_LEN,
               "AGORA_BUSINESS_AD_ID_MAX out of sync with AT_APP_BUSINESS_AD_ID_LEN");
_Static_assert(AGORA_BUSINESS_SAT_SELF == AT_APP_BUSINESS_SAT_SELF,
               "AGORA_BUSINESS_SAT_SELF out of sync with AT_APP_BUSINESS_SAT_SELF");
_Static_assert(AGORA_COSIGN_BYTES_MAX == AT_APP_COSIGN_BYTES_LEN,
               "AGORA_COSIGN_BYTES_MAX out of sync with AT_APP_COSIGN_BYTES_LEN");
_Static_assert(AGORA_COSIGN_DID_MAX == AT_APP_COSIGN_DID_LEN,
               "AGORA_COSIGN_DID_MAX out of sync with AT_APP_COSIGN_DID_LEN");
_Static_assert(AGORA_COSIGN_CID_MAX == AT_APP_COSIGN_CID_LEN,
               "AGORA_COSIGN_CID_MAX out of sync with AT_APP_COSIGN_CID_LEN");
_Static_assert(AGORA_COSIGN_SIG_MAX == AT_APP_COSIGN_SIG_LEN,
               "AGORA_COSIGN_SIG_MAX out of sync with AT_APP_COSIGN_SIG_LEN");
_Static_assert(AGORA_COSIGN_TOKEN_MAX == AT_APP_COSIGN_TOKEN_LEN,
               "AGORA_COSIGN_TOKEN_MAX out of sync with AT_APP_COSIGN_TOKEN_LEN");
_Static_assert(AGORA_BUSINESS_POST_BUNDLE_MAX == AT_APP_BUSINESS_POST_BUNDLE_LEN,
               "AGORA_BUSINESS_POST_BUNDLE_MAX out of sync with "
               "AT_APP_BUSINESS_POST_BUNDLE_LEN");
_Static_assert(AGORA_BUSINESS_POST_ID_MAX == AT_APP_BUSINESS_POST_ID_LEN,
               "AGORA_BUSINESS_POST_ID_MAX out of sync with "
               "AT_APP_BUSINESS_POST_ID_LEN");
/* ABI lockstep: the Dart AgoraEvent struct and the ctypes Ev in the cohort
 * tests (test/cohort/two_node_cohort.sh, two_node_gui.sh) all assert this exact
 * size. Growing agora_event_t REQUIRES bumping all three together. Grew from
 * 3752 to 7936 with the Increment 7 post tail (post_id@3745, post_seq@3752,
 * post_ts, post_required_tier, post_body); every prior field offset is unchanged
 * (dm_seq stays at 2704, connection_state at 2696). Grew again from 7936 to 8016
 * with the Increment 8 reaction tail (reaction_post_id, reaction_seq, reaction_ts)
 * appended after post_body; every prior field offset is unchanged. */
/* Grew again from 8016 to 8024 with the in_group flag (a uint8 + tail padding
 * to the struct's 8-byte alignment) appended after reaction_ts; every prior
 * field offset is unchanged. */
/* Grew again from 8024 to 11288 with the Phase 3 P3.2 business-ad tail
 * (business_polity, business_ad_id, business_satisfaction, business_seq,
 * business_ts, business_bundle) appended after proximity_band; every prior field
 * offset is unchanged (in_group stays at 8016, proximity_band at 8020). The
 * bundle dominates the growth: it is an opaque Ethne artifact (~2.4 KB at its
 * Ethne-side bounds) that must cross whole, because only the APP can verify it. */
/* Grew again from 11288 to 17872 with the Phase 3 P3.3 co-signing tail
 * (cosign_record, cosign_op, cosign_polity, cosign_cid, cosign_signer_did,
 * cosign_sig, cosign_seq, cosign_ts, cosign_bytes) appended after
 * business_bundle; every prior field offset is unchanged (business_bundle stays
 * at 8208). cosign_bytes dominates, for the same reason the bundle did: it is
 * opaque Ethne canonical CBOR that must cross WHOLE. The signatures are over
 * exactly those bytes, so a payload that arrives a byte short verifies against
 * nothing at all — which is why the authoring side refuses an oversized exchange
 * rather than letting anything truncate it. The bound is MEASURED; see
 * AT_APP_COSIGN_BYTES_LEN in app_events.h. */
/* Grew again from 17872 to 22152 with the Phase 3 P3.4 business-post tail
 * (business_post_polity, business_post_id, business_post_seq, business_post_ts,
 * business_post_hops, business_post_bundle) appended after cosign_bytes; every
 * prior field offset is unchanged (business_bundle stays at 8208,
 * cosign_bytes at 11720). The bundle
 * dominates, for the third time and the same reason: it is an opaque Ethne
 * artifact that must cross WHOLE, because only the app can verify it and a
 * signature over bytes that arrive short verifies against nothing. Its bound is
 * MEASURED — worst case 3550 of 4096, printed by
 * the_worst_case_post_bundle_fits_the_wire_bound in ethne_ffi.
 *
 * NOTE WHAT DID NOT GROW: at_app_event_t is a UNION and at_app_business_post_t
 * (~4.3 KB) stays under at_app_cosign_request_t's 6145, so agora_events_poll's
 * 16-event batch budget is exactly what it was. This flat struct is the only
 * thing that widened.
 *
 * 22152 -> 22168 at Phase 4 P4.1 (blocked + rep_tier + rep_ceiling). The union
 * again did NOT grow: at_app_reputation_t is ~40 bytes against
 * at_app_cosign_request_t's 6145, so the batch budget is untouched a second
 * time. Offsets, measured not assumed: blocked 22149, rep_tier 22152,
 * rep_ceiling 22160. */
_Static_assert(sizeof(agora_event_t) == 22168,
               "agora_event_t size changed — update the Dart struct and ALL "
               "FIVE cohort ctypes Ev asserts in lockstep");

void *agora_events_open(const char *recv_queue)
{
    return (void *)at_app_events_open(recv_queue);
}

int agora_events_request_roster(void *handle, const char *send_queue)
{
    return at_app_events_request_roster((at_app_events_t *)handle, send_queue);
}

int agora_set_position(void *handle, const char *send_queue, const char *geohash)
{
    return at_app_events_set_position((at_app_events_t *)handle, send_queue, geohash);
}

int agora_set_profile(void *handle, const char *send_queue, const char *profile_json)
{
    return at_app_events_set_profile((at_app_events_t *)handle, send_queue, profile_json);
}

int agora_connect_request(void *handle, const char *send_queue,
                          const uint8_t *peer_uuid)
{
    return at_app_events_connect_request((at_app_events_t *)handle, send_queue,
                                         peer_uuid);
}

int agora_connect_respond(void *handle, const char *send_queue,
                          const uint8_t *peer_uuid, int accept)
{
    return at_app_events_connect_respond((at_app_events_t *)handle, send_queue,
                                         peer_uuid, accept != 0);
}

int agora_send_dm(void *handle, const char *send_queue,
                  const uint8_t *peer_uuid, const char *text)
{
    return at_app_events_send_dm((at_app_events_t *)handle, send_queue,
                                 peer_uuid, text);
}

int agora_publish_post(void *handle, const char *send_queue,
                       const char *body, int required_tier)
{
    return at_app_events_publish_post((at_app_events_t *)handle, send_queue,
                                      body, required_tier);
}

int agora_react_post(void *handle, const char *send_queue,
                     const uint8_t *author_uuid, const char *post_id)
{
    return at_app_events_react_post((at_app_events_t *)handle, send_queue,
                                    author_uuid, post_id);
}

int agora_block(void *handle, const char *send_queue, const uint8_t *peer_uuid)
{
    return at_app_events_block((at_app_events_t *)handle, send_queue, peer_uuid);
}

int agora_unblock(void *handle, const char *send_queue, const uint8_t *peer_uuid)
{
    return at_app_events_unblock((at_app_events_t *)handle, send_queue, peer_uuid);
}

int agora_report_peer(void *handle, const char *send_queue,
                      const uint8_t *peer_uuid)
{
    return at_app_events_report_peer((at_app_events_t *)handle, send_queue,
                                     peer_uuid);
}

int agora_peer_standing(void *handle, const char *send_queue,
                        const uint8_t *peer_uuid, const char *standing,
                        double ceiling, const char *source, const char *reason)
{
    return at_app_events_peer_standing((at_app_events_t *)handle, send_queue,
                                       peer_uuid, standing, ceiling, source,
                                       reason);
}

int agora_request_attend(void *handle, const char *send_queue,
                         const uint8_t *peer_uuid)
{
    return at_app_events_request_attend((at_app_events_t *)handle, send_queue,
                                        peer_uuid);
}

int agora_request_proximity(void *handle, const char *send_queue,
                            const uint8_t *peer_uuid)
{
    return at_app_events_request_proximity((at_app_events_t *)handle, send_queue,
                                           peer_uuid);
}

int agora_advertise_business(void *handle, const char *send_queue,
                             const char *polity_did, const char *bundle,
                             int64_t seq)
{
    return at_app_events_advertise_business((at_app_events_t *)handle,
                                            send_queue, polity_did, bundle, seq);
}

int agora_set_customer(void *handle, const char *send_queue,
                       const char *polity_did, int satisfaction,
                       const char *bundle, int64_t seq)
{
    return at_app_events_set_customer((at_app_events_t *)handle, send_queue,
                                      polity_did, satisfaction, bundle, seq);
}

int agora_publish_business_post(void *handle, const char *send_queue,
                                const char *polity_did, const char *bundle,
                                int64_t seq)
{
    return at_app_events_publish_business_post((at_app_events_t *)handle,
                                               send_queue, polity_did, bundle,
                                               seq);
}

int agora_set_exact_position(void *handle, const char *send_queue, int opt_in,
                             double lat, double lon)
{
    return at_app_events_set_exact_position((at_app_events_t *)handle,
                                            send_queue, opt_in != 0, lat, lon);
}

int agora_request_cosign(void *handle, const char *send_queue,
                         const uint8_t *peer_uuids, int n_peers,
                         const char *record, const char *op,
                         const char *polity_did, const char *cid,
                         const char *bytes)
{
    if (n_peers <= 0)
        return -1;
    return at_app_events_request_cosign((at_app_events_t *)handle, send_queue,
                                        peer_uuids, (size_t)n_peers, record, op,
                                        polity_did, cid, bytes);
}

int agora_return_cosign(void *handle, const char *send_queue,
                        const uint8_t *peer_uuid, const char *cid,
                        const char *signer_did, const char *sig_hex)
{
    return at_app_events_return_cosign((at_app_events_t *)handle, send_queue,
                                       peer_uuid, cid, signer_did, sig_hex);
}

int agora_events_poll(void *handle, agora_event_t *out, int max)
{
    if (handle == NULL || out == NULL || max <= 0)
        return 0;

    /* Drain in fixed-size batches to keep the raw union buffer off the heap.
     * The batch SHRANK from 64 to 16 at P3.3: at_app_event_t's union now holds
     * the co-signing request, whose opaque payload alone is 6 KB, so 64 slots
     * would put ~420 KB on the stack of whatever thread Dart calls from. The
     * buffer is what is bounded here, not the drain — a caller asking for more
     * than one batch simply polls again. */
    at_app_event_t raw[16];
    int want = max < 16 ? max : 16;

    int n = at_app_events_poll((at_app_events_t *)handle, raw, (size_t)want);
    if (n <= 0)
        return n; /* 0 = none, -1 = error, AT_APP_NOT_READY (-2) = daemon not up */

    /* w IS THE RETURN VALUE, and a case that fills `e` but forgets to advance it
     * does not fail — it CONVERTS the event correctly and then discards it: the
     * next event overwrites the slot, and a batch holding only such events polls
     * as 0, which every caller reads as "the queue is empty". Both co-signing
     * cases shipped that way (P3.3), and it cost five live cohort runs: the
     * signer's daemon logged the ask arriving and its app saw nothing. EVERY
     * case below must end `w++; break;`. */
    int w = 0;
    for (int i = 0; i < n; i++) {
        agora_event_t *e = &out[w];
        memset(e, 0, sizeof(*e));

        switch (raw[i].kind) {
        case AT_APP_EVENT_PEER_OBSERVED:
            e->kind = AGORA_EVENT_PEER;
            memcpy(e->peer_uuid, raw[i].data.peer.peer_uuid, AGORA_UUID_LEN);
            memcpy(e->signing_pubkey, raw[i].data.peer.signing_pubkey, AGORA_KEY_LEN);
            e->rank = raw[i].data.peer.rank;
            e->operator_bound = raw[i].data.peer.operator_bound ? 1 : 0;
            e->operator_attested_at = raw[i].data.peer.operator_attested_at;
            memcpy(e->operator_pubkey, raw[i].data.peer.operator_pubkey, AGORA_KEY_LEN);
#ifdef AT_SOCIAL_ENABLED
            e->in_group = raw[i].data.peer.in_group ? 1 : 0;
            e->blocked = raw[i].data.peer.blocked ? 1 : 0;
#endif /* AT_SOCIAL_ENABLED */
            w++;
            break;

        case AT_APP_EVENT_PEER_REPUTATION:
            e->kind = AGORA_EVENT_REPUTATION;
            memcpy(e->peer_uuid, raw[i].data.reputation.peer_uuid, AGORA_UUID_LEN);
            e->rep_score = raw[i].data.reputation.score;
            e->rep_rated = raw[i].data.reputation.rated ? 1 : 0;
            e->rep_tier = raw[i].data.reputation.effective_tier;
            /* Written EXPLICITLY, including when unbounded. The event was
             * memset above, so leaving it would report 0.0 — "floored at zero"
             * — for every unbounded peer, which is the most likely defect in
             * this whole change. */
            e->rep_ceiling = raw[i].data.reputation.standing_ceiling < 0.0
                                 ? AGORA_NO_CEILING
                                 : raw[i].data.reputation.standing_ceiling;
            w++;
            break;

        case AT_APP_EVENT_PEER_RTT:
            e->kind = AGORA_EVENT_RTT;
            memcpy(e->peer_uuid, raw[i].data.rtt.peer_uuid, AGORA_UUID_LEN);
            e->rtt_ms = raw[i].data.rtt.rtt_ms;   /* 0 = unknown / not yet measured */
            w++;
            break;

        case AT_APP_EVENT_PEER_POSITION:
            e->kind = AGORA_EVENT_POSITION;
            memcpy(e->peer_uuid, raw[i].data.position.peer_uuid, AGORA_UUID_LEN);
            /* raw geohash is already NUL-bounded by AT; copy and re-terminate. */
            memcpy(e->geohash, raw[i].data.position.geohash, AGORA_GEOHASH_LEN);
            e->geohash[AGORA_GEOHASH_LEN] = '\0';
            w++;
            break;

        case AT_APP_EVENT_PEER_PROFILE:
            e->kind = AGORA_EVENT_PROFILE;
            memcpy(e->peer_uuid, raw[i].data.profile.peer_uuid, AGORA_UUID_LEN);
            /* raw profile_json is already NUL-bounded by AT; copy and re-terminate. */
            memcpy(e->profile_json, raw[i].data.profile.profile_json,
                   AGORA_PROFILE_JSON_MAX);
            e->profile_json[AGORA_PROFILE_JSON_MAX] = '\0';
            w++;
            break;

        case AT_APP_EVENT_CONNECTION_REQUEST:
            e->kind = AGORA_EVENT_CONNECTION_REQUEST;
            memcpy(e->peer_uuid, raw[i].data.connection.peer_uuid, AGORA_UUID_LEN);
            e->connection_state = raw[i].data.connection.state;
            w++;
            break;

        case AT_APP_EVENT_CONNECTION_STATE:
            e->kind = AGORA_EVENT_CONNECTION_STATE;
            memcpy(e->peer_uuid, raw[i].data.connection.peer_uuid, AGORA_UUID_LEN);
            e->connection_state = raw[i].data.connection.state;
            w++;
            break;

        case AT_APP_EVENT_DM:
            e->kind = AGORA_EVENT_DM;
            memcpy(e->peer_uuid, raw[i].data.dm.peer_uuid, AGORA_UUID_LEN);
            e->dm_seq = raw[i].data.dm.seq;
            e->dm_ts = raw[i].data.dm.ts;
            /* raw text is already NUL-bounded by AT; copy and re-terminate. */
            memcpy(e->dm_text, raw[i].data.dm.text, AGORA_DM_TEXT_MAX);
            e->dm_text[AGORA_DM_TEXT_MAX] = '\0';
            w++;
            break;

        case AT_APP_EVENT_POST:
            e->kind = AGORA_EVENT_POST;
            memcpy(e->peer_uuid, raw[i].data.post.author_uuid, AGORA_UUID_LEN);
            /* raw strings are already NUL-bounded by AT; copy and re-terminate. */
            memcpy(e->post_id, raw[i].data.post.post_id, AGORA_POST_ID_MAX);
            e->post_id[AGORA_POST_ID_MAX] = '\0';
            e->post_seq = raw[i].data.post.seq;
            e->post_ts = raw[i].data.post.ts;
            e->post_required_tier = raw[i].data.post.required_tier;
            memcpy(e->post_body, raw[i].data.post.body, AGORA_POST_BODY_MAX);
            e->post_body[AGORA_POST_BODY_MAX] = '\0';
            w++;
            break;

        case AT_APP_EVENT_REACTION:
            e->kind = AGORA_EVENT_REACTION;
            memcpy(e->peer_uuid, raw[i].data.reaction.peer_uuid, AGORA_UUID_LEN);
            /* raw id is already NUL-bounded by AT; copy and re-terminate. */
            memcpy(e->reaction_post_id, raw[i].data.reaction.post_id,
                   AGORA_POST_ID_MAX);
            e->reaction_post_id[AGORA_POST_ID_MAX] = '\0';
            e->reaction_seq = raw[i].data.reaction.seq;
            e->reaction_ts = raw[i].data.reaction.ts;
            w++;
            break;

        case AT_APP_EVENT_PROXIMITY:
            e->kind = AGORA_EVENT_PROXIMITY;
            memcpy(e->peer_uuid, raw[i].data.proximity.peer_uuid, AGORA_UUID_LEN);
            e->proximity_band = raw[i].data.proximity.band;
            w++;
            break;

        case AT_APP_EVENT_COSIGN_REQUEST:
            e->kind = AGORA_EVENT_COSIGN_REQUEST;
            memcpy(e->peer_uuid, raw[i].data.cosign_request.requester_uuid,
                   AGORA_UUID_LEN);
            /* The core NUL-caps every string and the event was memset, so a
             * short string stays terminated after the bounded copy. */
            memcpy(e->cosign_record, raw[i].data.cosign_request.record,
                   AGORA_COSIGN_TOKEN_MAX);
            e->cosign_record[AGORA_COSIGN_TOKEN_MAX] = '\0';
            memcpy(e->cosign_op, raw[i].data.cosign_request.op,
                   AGORA_COSIGN_TOKEN_MAX);
            e->cosign_op[AGORA_COSIGN_TOKEN_MAX] = '\0';
            memcpy(e->cosign_polity, raw[i].data.cosign_request.polity,
                   AGORA_COSIGN_DID_MAX);
            e->cosign_polity[AGORA_COSIGN_DID_MAX] = '\0';
            memcpy(e->cosign_cid, raw[i].data.cosign_request.cid,
                   AGORA_COSIGN_CID_MAX);
            e->cosign_cid[AGORA_COSIGN_CID_MAX] = '\0';
            e->cosign_seq = raw[i].data.cosign_request.seq;
            e->cosign_ts = raw[i].data.cosign_request.ts;
            memcpy(e->cosign_bytes, raw[i].data.cosign_request.bytes,
                   AGORA_COSIGN_BYTES_MAX);
            e->cosign_bytes[AGORA_COSIGN_BYTES_MAX] = '\0';
            w++;
            break;
        case AT_APP_EVENT_COSIGN_SIGNATURE:
            e->kind = AGORA_EVENT_COSIGN_SIGNATURE;
            memcpy(e->peer_uuid, raw[i].data.cosign_sig.signer_uuid,
                   AGORA_UUID_LEN);
            memcpy(e->cosign_cid, raw[i].data.cosign_sig.cid, AGORA_COSIGN_CID_MAX);
            e->cosign_cid[AGORA_COSIGN_CID_MAX] = '\0';
            memcpy(e->cosign_signer_did, raw[i].data.cosign_sig.signer_did,
                   AGORA_COSIGN_DID_MAX);
            e->cosign_signer_did[AGORA_COSIGN_DID_MAX] = '\0';
            memcpy(e->cosign_sig, raw[i].data.cosign_sig.sig, AGORA_COSIGN_SIG_MAX);
            e->cosign_sig[AGORA_COSIGN_SIG_MAX] = '\0';
            e->cosign_seq = raw[i].data.cosign_sig.seq;
            e->cosign_ts = raw[i].data.cosign_sig.ts;
            w++;
            break;
        case AT_APP_EVENT_BUSINESS_POST:
            e->kind = AGORA_EVENT_BUSINESS_POST;
            memcpy(e->peer_uuid, raw[i].data.business_post.publisher_uuid,
                   AGORA_UUID_LEN);
            /* The core NUL-caps every string and the event was memset, so a
             * short string stays terminated after the bounded copy. */
            memcpy(e->business_post_polity, raw[i].data.business_post.polity,
                   AGORA_BUSINESS_DID_MAX);
            e->business_post_polity[AGORA_BUSINESS_DID_MAX] = '\0';
            memcpy(e->business_post_id, raw[i].data.business_post.post_id,
                   AGORA_BUSINESS_POST_ID_MAX);
            e->business_post_id[AGORA_BUSINESS_POST_ID_MAX] = '\0';
            e->business_post_seq = raw[i].data.business_post.seq;
            e->business_post_ts = raw[i].data.business_post.ts;
            e->business_post_hops = raw[i].data.business_post.hops;
            memcpy(e->business_post_bundle, raw[i].data.business_post.bundle,
                   AGORA_BUSINESS_POST_BUNDLE_MAX);
            e->business_post_bundle[AGORA_BUSINESS_POST_BUNDLE_MAX] = '\0';
            w++;
            break;
        case AT_APP_EVENT_BUSINESS_AD:
            e->kind = AGORA_EVENT_BUSINESS_AD;
            memcpy(e->peer_uuid, raw[i].data.business_ad.advertiser_uuid,
                   AGORA_UUID_LEN);
            /* raw strings are already NUL-bounded by AT; copy and re-terminate.
             * The bundle crosses UNVERIFIED by design — the core holds no Ethne,
             * so the Dart side runs the self-contained verifier on it. */
            memcpy(e->business_polity, raw[i].data.business_ad.polity,
                   AGORA_BUSINESS_DID_MAX);
            e->business_polity[AGORA_BUSINESS_DID_MAX] = '\0';
            memcpy(e->business_ad_id, raw[i].data.business_ad.ad_id,
                   AGORA_BUSINESS_AD_ID_MAX);
            e->business_ad_id[AGORA_BUSINESS_AD_ID_MAX] = '\0';
            e->business_satisfaction = raw[i].data.business_ad.satisfaction;
            e->business_seq = raw[i].data.business_ad.seq;
            e->business_ts = raw[i].data.business_ad.ts;
            memcpy(e->business_bundle, raw[i].data.business_ad.bundle,
                   AGORA_BUSINESS_BUNDLE_MAX);
            e->business_bundle[AGORA_BUSINESS_BUNDLE_MAX] = '\0';
            w++;
            break;

        default:
            /* Unknown/appended kind: drop it. Forward-compatible by design. */
            break;
        }
    }
    return w;
}

void agora_events_close(void *handle)
{
    at_app_events_close((at_app_events_t *)handle);
}
