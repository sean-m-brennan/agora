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

#include "social/at_agora.h"   /* + app_events.h */
#include "social/at_social.h"  /* at_social_link */
/* First contact and rendezvous are AT extension libraries (libat_first_contact,
 * libat_rendezvous; AT FEATURE_SPLIT_PLAN Phase 7), and their consumers own
 * the link: the core references neither. */
#include "first_contact/at_first_contact.h"  /* proximity hubs, and the contact flow */
#include "rendezvous/at_rendezvous.h"        /* relay roster install/remove */
/* first_contact_app.c's link anchor (declared in AT's internal
 * first_contact/first_contact.h): referencing it keeps the first-contact event
 * decoders in a static link, as at_social_link does social's. */
void at_first_contact_app_link(void);

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
 * AT_APP_COSIGN_BYTES_LEN in at_agora.h. */
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
_Static_assert(AGORA_POST_LABELS_MAX == AT_APP_POST_LABELS_LEN,
               "AGORA_POST_LABELS_MAX out of sync with AT_APP_POST_LABELS_LEN");
_Static_assert(AGORA_BUSINESS_DID_MAX == AT_APP_POST_COMMUNITY_LEN,
               "a community DID is bounded as a business's (AT_APP_POST_COMMUNITY_LEN)");
_Static_assert(AGORA_COMMUNITY_POLICY_BUNDLE_MAX == AT_APP_COMMUNITY_POLICY_BUNDLE_LEN,
               "AGORA_COMMUNITY_POLICY_BUNDLE_MAX out of sync with "
               "AT_APP_COMMUNITY_POLICY_BUNDLE_LEN");
_Static_assert(AGORA_POST_LABEL_BUNDLE_MAX == AT_APP_POST_LABEL_BUNDLE_LEN,
               "AGORA_POST_LABEL_BUNDLE_MAX out of sync with AT_APP_POST_LABEL_BUNDLE_LEN");
/* 22168 -> 28600 at Phase 4 communities (post_community, post_labels, the
 * policy_* tail and the label_* tail); every prior offset is unchanged
 * (post_community lands at 22168, label_bundle at 27060). The union again did
 * NOT grow: at_app_community_policy_t (~4.3 KB) stays under
 * at_app_cosign_request_t's 6145, so the batch budget is untouched. Measured,
 * not assumed. */
_Static_assert(AGORA_FC_REF_MAX + 1 == AT_FC_REF_LEN
               && AGORA_FC_HANDLE_MAX + 1 == AT_FC_HANDLE_LEN
               && AGORA_FC_NICKNAME_MAX + 1 == AT_FC_NICKNAME_LEN
               && AGORA_FC_RELAY_MAX + 1 == AT_FC_RELAY_LEN
               && AGORA_FC_REASON_MAX + 1 == AT_FC_REASON_LEN
               && AGORA_AREA_MAX + 1 == AT_FC_AREA_LEN
               && AGORA_AREA_NAME_MAX + 1 == AT_FC_AREA_NAME_LEN
               && AGORA_FC_ISSUER_MAX + 1 == AT_FC_ISSUER_LEN,
               "the first-contact bounds are out of sync with at_first_contact.h");
/* Roster outcomes come from rendezvous (at_rendezvous.h) since AT's Phase 7
 * split, into the same fc_ref / area_issuer / fc_reason fields. */
_Static_assert(AGORA_FC_REF_MAX + 1 == AT_RDV_REF_LEN
               && AGORA_FC_REASON_MAX + 1 == AT_RDV_REASON_LEN
               && AGORA_FC_ISSUER_MAX + 1 == AT_RDV_ISSUER_LEN,
               "the roster bounds are out of sync with at_rendezvous.h");
/* 28600 -> 29200 at proximity hubs (the fc_* / area_* tail: fc_kind at 28600,
 * fc_count at 29192); every prior offset is unchanged. */
_Static_assert(AGORA_FC_BLOB_MAX + 1 == AT_FC_BLOB_LEN
               && AGORA_FC_SAFETY_NUMBER_MAX + 1 == AT_FC_SAFETY_NUMBER_LEN
               && AGORA_BACKUP_PATH_MAX + 1 == AT_FC_PATH_LEN
               && AGORA_BACKUP_PASSPHRASE_MAX + 1 == AT_FC_PASSPHRASE_LEN,
               "the address-book / backup bounds are out of sync with at_first_contact.h");
_Static_assert(AGORA_FC_ORIGIN_SIBLING == AT_FC_ORIGIN_SIBLING
               && AGORA_FC_ORIGIN_BACKUP == AT_FC_ORIGIN_BACKUP,
               "AGORA_FC_ORIGIN_* out of sync with AT_FC_ORIGIN_*");
/* 29200 -> 41296 at multi-device (the address-book / device / backup tail:
 * fc_blob at 29196, fc_petname 36892, fc_device_uuid 37125, backup_path 37148,
 * backup_removed 41292); every prior offset is unchanged. Measured, not
 * assumed. The union did not grow on AT's side: these payloads were already
 * in at_app_event_t. A batch of 16 is now ~660 KB, still heap-allocated by
 * every caller. */
_Static_assert(sizeof(agora_event_t) == 41296,
               "agora_event_t size changed — update the Dart struct and ALL "
               "NINE cohort ctypes Ev asserts in lockstep");

/* This file reads at_app_event_t through at_agora.h's accessors; a change to
 * that layout is announced by a bump of AT_APP_ABI_VERSION. Pinned here so the
 * bump fails this build and someone re-reads the conversion below. */
_Static_assert(AT_APP_ABI_VERSION == 2,
               "at_app_event_t ABI changed — review agora_events_poll");

void *agora_events_open(const char *recv_queue)
{
    /* A shim compiled against one app-event layout must not read another's
     * events: every slot after the first would be misaligned. */
    if (at_app_abi_version() != AT_APP_ABI_VERSION)
        return NULL;
    /* Social is its own library (libat_social); referencing it keeps it, and
     * the decoders this shim reads through, in the link. Present means on, so
     * a shim without it would silently lose every social event. */
    at_social_link();
    /* The first-contact decoders (area and contact events) likewise. */
    at_first_contact_app_link();
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

int agora_publish_post_scoped(void *handle, const char *send_queue,
                              const char *body, int required_tier,
                              const char *community, const char *labels_csv)
{
    return at_app_events_publish_post_scoped((at_app_events_t *)handle, send_queue,
                                             body, required_tier, community,
                                             labels_csv);
}

int agora_follow_community(void *handle, const char *send_queue,
                           const char *community, const char *bundle, int64_t seq)
{
    return at_app_events_follow_community((at_app_events_t *)handle, send_queue,
                                          community, bundle, seq);
}

int agora_unfollow_community(void *handle, const char *send_queue,
                             const char *community)
{
    return at_app_events_unfollow_community((at_app_events_t *)handle, send_queue,
                                            community);
}

int agora_publish_post_label(void *handle, const char *send_queue,
                             const char *community, const char *post_id,
                             const char *bundle, int64_t seq)
{
    return at_app_events_publish_post_label((at_app_events_t *)handle, send_queue,
                                            community, post_id, bundle, seq);
}

int agora_area_publish(void *handle, const char *send_queue, const char *ref,
                       const char *area, const char *bucket, const char *name)
{
    return at_app_area_publish((at_app_events_t *)handle, send_queue, ref, area, bucket, name);
}

int agora_area_withdraw(void *handle, const char *send_queue, const char *ref,
                        const char *area)
{
    return at_app_area_withdraw((at_app_events_t *)handle, send_queue, ref, area);
}

int agora_area_lookup(void *handle, const char *send_queue, const char *ref,
                      const char *area)
{
    return at_app_area_lookup((at_app_events_t *)handle, send_queue, ref, area);
}

int agora_area_request(void *handle, const char *send_queue, const char *ref,
                       const char *area, const uint8_t *peer_uuid)
{
    return at_app_area_request((at_app_events_t *)handle, send_queue, ref, area, peer_uuid);
}

int agora_contact_accept(void *handle, const char *send_queue, const char *request_ref)
{
    return at_app_first_contact_accept((at_app_events_t *)handle, send_queue, request_ref);
}

int agora_contact_decline(void *handle, const char *send_queue, const char *request_ref)
{
    return at_app_first_contact_decline((at_app_events_t *)handle, send_queue, request_ref);
}

int agora_relay_roster_install(void *handle, const char *send_queue, const char *ref,
                               const char *roster)
{
    return at_app_relay_roster_install((at_app_events_t *)handle, send_queue, ref, roster);
}

int agora_relay_roster_remove(void *handle, const char *send_queue, const char *ref,
                              const char *issuer)
{
    return at_app_relay_roster_remove((at_app_events_t *)handle, send_queue, ref, issuer);
}

int agora_fc_invite(void *handle, const char *send_queue, const char *ref,
                    long ttl_seconds)
{
    return at_app_first_contact_invite((at_app_events_t *)handle, send_queue, ref,
                                       ttl_seconds, NULL, 0);
}

int agora_fc_pair_invite(void *handle, const char *send_queue, const char *ref,
                         long ttl_seconds)
{
    return at_app_first_contact_pair_invite((at_app_events_t *)handle, send_queue,
                                            ref, ttl_seconds);
}

int agora_fc_initiate(void *handle, const char *send_queue, const char *ref,
                      const char *invitation, int in_person, const char *petname)
{
    return at_app_first_contact_initiate((at_app_events_t *)handle, send_queue, ref,
                                         invitation, NULL, in_person != 0, petname);
}

int agora_fc_list(void *handle, const char *send_queue, const char *ref)
{
    return at_app_first_contact_list((at_app_events_t *)handle, send_queue, ref);
}

int agora_fc_safety_number(void *handle, const char *send_queue, const char *ref,
                           const uint8_t *peer_uuid)
{
    return at_app_first_contact_safety_number((at_app_events_t *)handle, send_queue,
                                              ref, peer_uuid);
}

int agora_fc_verify(void *handle, const char *send_queue, const char *ref,
                    const uint8_t *peer_uuid, const char *presented, int confirmed)
{
    return at_app_first_contact_verify((at_app_events_t *)handle, send_queue, ref,
                                       peer_uuid, presented, confirmed != 0);
}

int agora_fc_rename(void *handle, const char *send_queue, const char *ref,
                    const uint8_t *peer_uuid, const char *petname)
{
    return at_app_first_contact_rename((at_app_events_t *)handle, send_queue, ref,
                                       peer_uuid, petname);
}

int agora_fc_remove(void *handle, const char *send_queue, const char *ref,
                    const uint8_t *peer_uuid)
{
    return at_app_first_contact_remove((at_app_events_t *)handle, send_queue, ref,
                                       peer_uuid);
}

int agora_sibling_list(void *handle, const char *send_queue, const char *ref)
{
    return at_app_sibling_list((at_app_events_t *)handle, send_queue, ref);
}

int agora_sibling_remove(void *handle, const char *send_queue, const char *ref,
                         const uint8_t *peer_uuid)
{
    return at_app_sibling_remove((at_app_events_t *)handle, send_queue, ref, peer_uuid);
}

int agora_backup_export(void *handle, const char *send_queue, const char *ref,
                        const char *path, const char *passphrase)
{
    return at_app_backup_export((at_app_events_t *)handle, send_queue, ref, path,
                                passphrase);
}

int agora_backup_import(void *handle, const char *send_queue, const char *ref,
                        const char *path, const char *passphrase)
{
    return at_app_backup_import((at_app_events_t *)handle, send_queue, ref, path,
                                passphrase);
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

    /* Drain in fixed-size batches to keep the raw event buffer off the heap.
     * The batch SHRANK from 64 to 16 at P3.3 (the co-signing request's opaque
     * payload alone is 6 KB). At app ABI v2 every at_app_event_t is a fixed
     * 8200 B (8 + AT_APP_EVENT_PAYLOAD_MAX), so 16 slots are ~131 KB on the
     * stack of whatever thread Dart calls from, up from ~100 KB. It stays 16
     * anyway: "at most 16 events per call" is a CONTRACT — the cohort drivers'
     * drain() loops stop on `n < 16`, so a smaller batch would silently end
     * every drain after its first batch. Change it only together with them.
     * The buffer is what is bounded here, not the drain — a caller asking for
     * more than one batch simply polls again. */
    enum { AGORA_POLL_BATCH = 16 };
    at_app_event_t raw[AGORA_POLL_BATCH];
    int want = max < AGORA_POLL_BATCH ? max : AGORA_POLL_BATCH;

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
            e->in_group = raw[i].data.peer.in_group ? 1 : 0;
            e->blocked = raw[i].data.peer.blocked ? 1 : 0;
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

        case AT_APP_EVENT_PEER_POSITION: {
            const at_app_position_t *ev = at_agora_event_position(&raw[i]);
            e->kind = AGORA_EVENT_POSITION;
            memcpy(e->peer_uuid, ev->peer_uuid, AGORA_UUID_LEN);
            /* raw geohash is already NUL-bounded by AT; copy and re-terminate. */
            memcpy(e->geohash, ev->geohash, AGORA_GEOHASH_LEN);
            e->geohash[AGORA_GEOHASH_LEN] = '\0';
            w++;
            break;
        }

        case AT_APP_EVENT_PEER_PROFILE: {
            const at_app_profile_t *ev = at_agora_event_profile(&raw[i]);
            e->kind = AGORA_EVENT_PROFILE;
            memcpy(e->peer_uuid, ev->peer_uuid, AGORA_UUID_LEN);
            /* raw profile_json is already NUL-bounded by AT; copy and re-terminate. */
            memcpy(e->profile_json, ev->profile_json,
                   AGORA_PROFILE_JSON_MAX);
            e->profile_json[AGORA_PROFILE_JSON_MAX] = '\0';
            w++;
            break;
        }

        case AT_APP_EVENT_CONNECTION_REQUEST: {
            const at_app_connection_t *ev = at_agora_event_connection(&raw[i]);
            e->kind = AGORA_EVENT_CONNECTION_REQUEST;
            memcpy(e->peer_uuid, ev->peer_uuid, AGORA_UUID_LEN);
            e->connection_state = ev->state;
            w++;
            break;
        }

        case AT_APP_EVENT_CONNECTION_STATE: {
            const at_app_connection_t *ev = at_agora_event_connection(&raw[i]);
            e->kind = AGORA_EVENT_CONNECTION_STATE;
            memcpy(e->peer_uuid, ev->peer_uuid, AGORA_UUID_LEN);
            e->connection_state = ev->state;
            w++;
            break;
        }

        case AT_APP_EVENT_DM: {
            const at_app_dm_t *ev = at_agora_event_dm(&raw[i]);
            e->kind = AGORA_EVENT_DM;
            memcpy(e->peer_uuid, ev->peer_uuid, AGORA_UUID_LEN);
            e->dm_seq = ev->seq;
            e->dm_ts = ev->ts;
            /* raw text is already NUL-bounded by AT; copy and re-terminate. */
            memcpy(e->dm_text, ev->text, AGORA_DM_TEXT_MAX);
            e->dm_text[AGORA_DM_TEXT_MAX] = '\0';
            w++;
            break;
        }

        case AT_APP_EVENT_POST: {
            const at_app_post_t *ev = at_agora_event_post(&raw[i]);
            e->kind = AGORA_EVENT_POST;
            memcpy(e->peer_uuid, ev->author_uuid, AGORA_UUID_LEN);
            /* raw strings are already NUL-bounded by AT; copy and re-terminate. */
            memcpy(e->post_id, ev->post_id, AGORA_POST_ID_MAX);
            e->post_id[AGORA_POST_ID_MAX] = '\0';
            e->post_seq = ev->seq;
            e->post_ts = ev->ts;
            e->post_required_tier = ev->required_tier;
            memcpy(e->post_body, ev->body, AGORA_POST_BODY_MAX);
            e->post_body[AGORA_POST_BODY_MAX] = '\0';
            memcpy(e->post_community, ev->community, AGORA_BUSINESS_DID_MAX);
            e->post_community[AGORA_BUSINESS_DID_MAX] = '\0';
            memcpy(e->post_labels, ev->labels, AGORA_POST_LABELS_MAX);
            e->post_labels[AGORA_POST_LABELS_MAX] = '\0';
            w++;
            break;
        }

        case AT_APP_EVENT_COMMUNITY_POLICY: {
            const at_app_community_policy_t *ev = at_agora_event_community_policy(&raw[i]);
            e->kind = AGORA_EVENT_COMMUNITY_POLICY;
            memcpy(e->peer_uuid, ev->carrier_uuid, AGORA_UUID_LEN);
            memcpy(e->policy_community, ev->community, AGORA_BUSINESS_DID_MAX);
            e->policy_community[AGORA_BUSINESS_DID_MAX] = '\0';
            memcpy(e->policy_id, ev->policy_id, AGORA_POST_ID_MAX);
            e->policy_id[AGORA_POST_ID_MAX] = '\0';
            e->policy_seq = ev->seq;
            e->policy_ts = ev->ts;
            memcpy(e->policy_bundle, ev->bundle, AGORA_COMMUNITY_POLICY_BUNDLE_MAX);
            e->policy_bundle[AGORA_COMMUNITY_POLICY_BUNDLE_MAX] = '\0';
            w++;
            break;
        }

        case AT_APP_EVENT_POST_LABEL: {
            const at_app_post_label_t *ev = at_agora_event_post_label(&raw[i]);
            e->kind = AGORA_EVENT_POST_LABEL;
            memcpy(e->peer_uuid, ev->publisher_uuid, AGORA_UUID_LEN);
            memcpy(e->label_community, ev->community, AGORA_BUSINESS_DID_MAX);
            e->label_community[AGORA_BUSINESS_DID_MAX] = '\0';
            memcpy(e->label_post_id, ev->post_id, AGORA_POST_ID_MAX);
            e->label_post_id[AGORA_POST_ID_MAX] = '\0';
            memcpy(e->label_id, ev->label_id, AGORA_POST_ID_MAX);
            e->label_id[AGORA_POST_ID_MAX] = '\0';
            e->label_seq = ev->seq;
            e->label_ts = ev->ts;
            e->label_hops = ev->hops;
            memcpy(e->label_bundle, ev->bundle, AGORA_POST_LABEL_BUNDLE_MAX);
            e->label_bundle[AGORA_POST_LABEL_BUNDLE_MAX] = '\0';
            w++;
            break;
        }

        case AT_APP_EVENT_REACTION: {
            const at_app_reaction_t *ev = at_agora_event_reaction(&raw[i]);
            e->kind = AGORA_EVENT_REACTION;
            memcpy(e->peer_uuid, ev->peer_uuid, AGORA_UUID_LEN);
            /* raw id is already NUL-bounded by AT; copy and re-terminate. */
            memcpy(e->reaction_post_id, ev->post_id,
                   AGORA_POST_ID_MAX);
            e->reaction_post_id[AGORA_POST_ID_MAX] = '\0';
            e->reaction_seq = ev->seq;
            e->reaction_ts = ev->ts;
            w++;
            break;
        }

        case AT_APP_EVENT_PROXIMITY: {
            const at_app_proximity_t *ev = at_agora_event_proximity(&raw[i]);
            e->kind = AGORA_EVENT_PROXIMITY;
            memcpy(e->peer_uuid, ev->peer_uuid, AGORA_UUID_LEN);
            e->proximity_band = ev->band;
            w++;
            break;
        }

        case AT_APP_EVENT_COSIGN_REQUEST: {
            const at_app_cosign_request_t *ev = at_agora_event_cosign_request(&raw[i]);
            e->kind = AGORA_EVENT_COSIGN_REQUEST;
            memcpy(e->peer_uuid, ev->requester_uuid,
                   AGORA_UUID_LEN);
            /* The core NUL-caps every string and the event was memset, so a
             * short string stays terminated after the bounded copy. */
            memcpy(e->cosign_record, ev->record,
                   AGORA_COSIGN_TOKEN_MAX);
            e->cosign_record[AGORA_COSIGN_TOKEN_MAX] = '\0';
            memcpy(e->cosign_op, ev->op,
                   AGORA_COSIGN_TOKEN_MAX);
            e->cosign_op[AGORA_COSIGN_TOKEN_MAX] = '\0';
            memcpy(e->cosign_polity, ev->polity,
                   AGORA_COSIGN_DID_MAX);
            e->cosign_polity[AGORA_COSIGN_DID_MAX] = '\0';
            memcpy(e->cosign_cid, ev->cid,
                   AGORA_COSIGN_CID_MAX);
            e->cosign_cid[AGORA_COSIGN_CID_MAX] = '\0';
            e->cosign_seq = ev->seq;
            e->cosign_ts = ev->ts;
            memcpy(e->cosign_bytes, ev->bytes,
                   AGORA_COSIGN_BYTES_MAX);
            e->cosign_bytes[AGORA_COSIGN_BYTES_MAX] = '\0';
            w++;
            break;
        }
        case AT_APP_EVENT_COSIGN_SIGNATURE: {
            const at_app_cosign_sig_t *ev = at_agora_event_cosign_sig(&raw[i]);
            e->kind = AGORA_EVENT_COSIGN_SIGNATURE;
            memcpy(e->peer_uuid, ev->signer_uuid,
                   AGORA_UUID_LEN);
            memcpy(e->cosign_cid, ev->cid, AGORA_COSIGN_CID_MAX);
            e->cosign_cid[AGORA_COSIGN_CID_MAX] = '\0';
            memcpy(e->cosign_signer_did, ev->signer_did,
                   AGORA_COSIGN_DID_MAX);
            e->cosign_signer_did[AGORA_COSIGN_DID_MAX] = '\0';
            memcpy(e->cosign_sig, ev->sig, AGORA_COSIGN_SIG_MAX);
            e->cosign_sig[AGORA_COSIGN_SIG_MAX] = '\0';
            e->cosign_seq = ev->seq;
            e->cosign_ts = ev->ts;
            w++;
            break;
        }
        case AT_APP_EVENT_BUSINESS_POST: {
            const at_app_business_post_t *ev = at_agora_event_business_post(&raw[i]);
            e->kind = AGORA_EVENT_BUSINESS_POST;
            memcpy(e->peer_uuid, ev->publisher_uuid,
                   AGORA_UUID_LEN);
            /* The core NUL-caps every string and the event was memset, so a
             * short string stays terminated after the bounded copy. */
            memcpy(e->business_post_polity, ev->polity,
                   AGORA_BUSINESS_DID_MAX);
            e->business_post_polity[AGORA_BUSINESS_DID_MAX] = '\0';
            memcpy(e->business_post_id, ev->post_id,
                   AGORA_BUSINESS_POST_ID_MAX);
            e->business_post_id[AGORA_BUSINESS_POST_ID_MAX] = '\0';
            e->business_post_seq = ev->seq;
            e->business_post_ts = ev->ts;
            e->business_post_hops = ev->hops;
            memcpy(e->business_post_bundle, ev->bundle,
                   AGORA_BUSINESS_POST_BUNDLE_MAX);
            e->business_post_bundle[AGORA_BUSINESS_POST_BUNDLE_MAX] = '\0';
            w++;
            break;
        }
        case AT_APP_EVENT_ROSTER_INSTALLED: case AT_APP_EVENT_ROSTER_REFUSED:
        case AT_APP_EVENT_ROSTER_REMOVED: {
            /* Rendezvous's own payload since AT's Phase 7 split: the area
             * decoder answers NULL for these kinds, which dropped every
             * roster outcome without a word (hub cohort hub-561981). Same
             * AgoraEvent fields as before, so the app reads no difference. */
            const at_app_roster_t *r = at_rendezvous_roster_event(&raw[i]);
            if (r != NULL) {
                e->kind = AGORA_EVENT_AREA;
                e->fc_kind = raw[i].kind;
                memcpy(e->fc_ref, r->ref, sizeof(e->fc_ref));
                memcpy(e->fc_reason, r->reason, sizeof(e->fc_reason));
                memcpy(e->area_issuer, r->issuer, sizeof(e->area_issuer));
                e->fc_seq = r->seq;
                e->fc_count = r->count;
                w++;
            }
            break;
        }
        case AT_APP_EVENT_AREA_PUBLISHED: case AT_APP_EVENT_AREA_REFUSED:
        case AT_APP_EVENT_AREA_WITHDRAWN: case AT_APP_EVENT_AREA_CARD:
        case AT_APP_EVENT_AREA_DONE: {
            const at_app_area_t *a = at_first_contact_area_event(&raw[i]);
            if (a != NULL) {
                e->kind = AGORA_EVENT_AREA;
                e->fc_kind = raw[i].kind;
                memcpy(e->peer_uuid, a->peer_uuid, 16);
                memcpy(e->fc_ref, a->ref, sizeof(e->fc_ref));
                memcpy(e->fc_relay, a->relay, sizeof(e->fc_relay));
                memcpy(e->fc_reason, a->reason, sizeof(e->fc_reason));
                memcpy(e->area, a->area, sizeof(e->area));
                memcpy(e->area_bucket, a->bucket, sizeof(e->area_bucket));
                memcpy(e->area_name, a->name, sizeof(e->area_name));
                memcpy(e->area_issuer, a->issuer, sizeof(e->area_issuer));
                e->fc_seq = a->seq;
                e->fc_count = a->count;
                w++;
            }
            break;
        }
        case AT_APP_EVENT_DIR_PUBLISHED: case AT_APP_EVENT_DIR_REFUSED:
        case AT_APP_EVENT_DIR_WITHDRAWN: case AT_APP_EVENT_DIR_FOUND:
        case AT_APP_EVENT_DIR_NOT_FOUND: case AT_APP_EVENT_DIR_REQUEST_SENT:
        case AT_APP_EVENT_DIR_CONTACT_REQUEST: case AT_APP_EVENT_DIR_ACCEPTED:
        case AT_APP_EVENT_DIR_DECLINED: {
            const at_app_directory_t *d = at_first_contact_directory_event(&raw[i]);
            if (d != NULL) {
                e->kind = AGORA_EVENT_CONTACT;
                e->fc_kind = raw[i].kind;
                memcpy(e->peer_uuid, d->peer_uuid, 16);
                memcpy(e->fc_ref, d->ref, sizeof(e->fc_ref));
                memcpy(e->fc_handle, d->handle, sizeof(e->fc_handle));
                memcpy(e->fc_nickname, d->nickname, sizeof(e->fc_nickname));
                memcpy(e->fc_relay, d->relay, sizeof(e->fc_relay));
                memcpy(e->fc_reason, d->reason, sizeof(e->fc_reason));
                e->fc_seq = d->seq;
                w++;
            }
            break;
        }
        case AT_APP_EVENT_FC_INVITATION: case AT_APP_EVENT_FC_HELLO_SENT:
        case AT_APP_EVENT_FC_REFUSED: case AT_APP_EVENT_FC_ESTABLISHED:
        case AT_APP_EVENT_FC_SIBLING_PAIRED: {
            const at_app_first_contact_t *f = at_first_contact_event(&raw[i]);
            if (f != NULL) {
                w++;
                e->kind = AGORA_EVENT_CONTACT;
                e->fc_kind = raw[i].kind;
                memcpy(e->peer_uuid, f->peer_uuid, 16);
                memcpy(e->fc_ref, f->ref, sizeof(e->fc_ref));
                memcpy(e->fc_nickname, f->nickname, sizeof(e->fc_nickname));
                e->fc_count = f->reason;    /* at_fc_reason_t on a REFUSED event */
                e->fc_role = f->role;
                e->fc_expiry = f->expiry;
                memcpy(e->fc_blob, f->blob, sizeof(e->fc_blob));
                e->fc_blob[AGORA_FC_BLOB_MAX] = '\0';
            }
            break;
        }
        case AT_APP_EVENT_FC_CONTACT: case AT_APP_EVENT_FC_CONTACTS_DONE:
        case AT_APP_EVENT_FC_SAFETY_NUMBER: case AT_APP_EVENT_FC_VERIFIED:
        case AT_APP_EVENT_FC_REMOVED: case AT_APP_EVENT_FC_DEVICE_LINKED:
        case AT_APP_EVENT_FC_SIBLING: case AT_APP_EVENT_FC_SIBLINGS_DONE:
        case AT_APP_EVENT_FC_SIBLING_REMOVED: {
            const at_app_contact_t *c = at_first_contact_contact_event(&raw[i]);
            if (c != NULL) {
                w++;
                e->kind = AGORA_EVENT_CONTACT;
                e->fc_kind = raw[i].kind;
                memcpy(e->peer_uuid, c->peer_uuid, 16);
                memcpy(e->fc_ref, c->ref, sizeof(e->fc_ref));
                memcpy(e->fc_nickname, c->nickname, sizeof(e->fc_nickname));
                memcpy(e->fc_petname, c->petname, sizeof(e->fc_petname));
                e->fc_verified = c->verified ? 1 : 0;
                e->fc_provenance = c->provenance;
                e->fc_added_at = c->added_at;
                e->fc_verified_at = c->verified_at;
                memcpy(e->fc_safety_number, c->safety_number,
                       sizeof(e->fc_safety_number));
                e->fc_safety_number[AGORA_FC_SAFETY_NUMBER_MAX] = '\0';
                e->fc_method = c->method;
                e->fc_peer_dropped = c->peer_dropped ? 1 : 0;
                e->fc_count = c->count;
                memcpy(e->fc_device_uuid, c->device_uuid, 16);
                e->fc_origin = c->origin;
            }
            break;
        }
        case AT_APP_EVENT_BACKUP_WRITTEN: case AT_APP_EVENT_BACKUP_RESTORED:
        case AT_APP_EVENT_BACKUP_REFUSED: {
            const at_app_backup_t *b = at_first_contact_backup_event(&raw[i]);
            if (b != NULL) {
                w++;
                e->kind = AGORA_EVENT_BACKUP;
                e->fc_kind = raw[i].kind;
                memcpy(e->fc_ref, b->ref, sizeof(e->fc_ref));
                memcpy(e->fc_reason, b->reason, sizeof(e->fc_reason));
                memcpy(e->backup_path, b->path, sizeof(e->backup_path));
                e->backup_path[AGORA_BACKUP_PATH_MAX] = '\0';
                memcpy(e->backup_passphrase, b->passphrase,
                       sizeof(e->backup_passphrase));
                e->backup_passphrase[AGORA_BACKUP_PASSPHRASE_MAX] = '\0';
                e->backup_contacts = b->contacts;
                e->backup_siblings = b->siblings;
                e->backup_added = b->added;
                e->backup_updated = b->updated;
                e->backup_removed = b->removed;
            }
            break;
        }
        case AT_APP_EVENT_BUSINESS_AD: {
            const at_app_business_ad_t *ev = at_agora_event_business_ad(&raw[i]);
            e->kind = AGORA_EVENT_BUSINESS_AD;
            memcpy(e->peer_uuid, ev->advertiser_uuid,
                   AGORA_UUID_LEN);
            /* raw strings are already NUL-bounded by AT; copy and re-terminate.
             * The bundle crosses UNVERIFIED by design — the core holds no Ethne,
             * so the Dart side runs the self-contained verifier on it. */
            memcpy(e->business_polity, ev->polity,
                   AGORA_BUSINESS_DID_MAX);
            e->business_polity[AGORA_BUSINESS_DID_MAX] = '\0';
            memcpy(e->business_ad_id, ev->ad_id,
                   AGORA_BUSINESS_AD_ID_MAX);
            e->business_ad_id[AGORA_BUSINESS_AD_ID_MAX] = '\0';
            e->business_satisfaction = ev->satisfaction;
            e->business_seq = ev->seq;
            e->business_ts = ev->ts;
            memcpy(e->business_bundle, ev->bundle,
                   AGORA_BUSINESS_BUNDLE_MAX);
            e->business_bundle[AGORA_BUSINESS_BUNDLE_MAX] = '\0';
            w++;
            break;
        }

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
