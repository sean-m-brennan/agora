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

void *agora_events_open(const char *recv_queue)
{
    return (void *)at_app_events_open(recv_queue);
}

int agora_events_request_roster(void *handle, const char *send_queue)
{
    return at_app_events_request_roster((at_app_events_t *)handle, send_queue);
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
