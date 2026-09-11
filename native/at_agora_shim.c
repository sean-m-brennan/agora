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
/* ABI lockstep: the Dart AgoraEvent struct and the ctypes Ev in the cohort
 * tests (test/cohort/two_node_cohort.sh, two_node_gui.sh) all assert this exact
 * size. Growing agora_event_t REQUIRES bumping all three together. Grew from
 * 2704 to 3752 with the Increment 6 DM tail (dm_seq@2704, dm_ts, dm_text);
 * every prior field offset is unchanged (connection_state stays at 2696). */
_Static_assert(sizeof(agora_event_t) == 3752,
               "agora_event_t size changed — update the Dart struct and both "
               "cohort ctypes Ev asserts in lockstep");

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

int agora_events_poll(void *handle, agora_event_t *out, int max)
{
    if (handle == NULL || out == NULL || max <= 0)
        return 0;

    /* Drain in fixed-size batches to keep the raw union buffer off the heap. */
    at_app_event_t raw[64];
    int want = max < 64 ? max : 64;

    int n = at_app_events_poll((at_app_events_t *)handle, raw, (size_t)want);
    if (n <= 0)
        return n; /* 0 = none, -1 = error, AT_APP_NOT_READY (-2) = daemon not up */

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
            w++;
            break;

        case AT_APP_EVENT_PEER_REPUTATION:
            e->kind = AGORA_EVENT_REPUTATION;
            memcpy(e->peer_uuid, raw[i].data.reputation.peer_uuid, AGORA_UUID_LEN);
            e->rep_score = raw[i].data.reputation.score;
            e->rep_rated = raw[i].data.reputation.rated ? 1 : 0;
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
