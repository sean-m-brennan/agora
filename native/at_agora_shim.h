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
/* Max geohash length. MUST match AT_APP_GEOHASH_LEN (app_events.h). */
#define AGORA_GEOHASH_LEN 12
/* Max compact-profile-JSON length. MUST match AT_APP_PROFILE_JSON_LEN
 * (app_events.h) / AT_PROFILE_JSON_LEN (msg_types.h). */
#define AGORA_PROFILE_JSON_MAX 2560

/* kind discriminator (a superset-safe subset of at_app_event_kind_t). */
#define AGORA_EVENT_PEER       1
#define AGORA_EVENT_REPUTATION 2
#define AGORA_EVENT_RTT        3
#define AGORA_EVENT_POSITION   4
#define AGORA_EVENT_PROFILE    5

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
} agora_event_t;

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

/** Non-blocking poll. Writes up to @p max flattened events into @p out. Returns
 *  the count written (0 = nothing arrived), or a negative AT error code. */
int agora_events_poll(void *handle, agora_event_t *out, int max);

/** Close the handle opened by agora_events_open(). */
void agora_events_close(void *handle);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* AT_AGORA_SHIM_H */
