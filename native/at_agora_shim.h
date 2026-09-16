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
/* Max DM body length. MUST match AT_APP_DM_TEXT_LEN (app_events.h) /
 * AT_DM_TEXT_LEN (msg_types.h). */
#define AGORA_DM_TEXT_MAX 1024
/* Max feed-post body length. MUST match AT_APP_POST_BODY_LEN (app_events.h) /
 * AT_POST_BODY_LEN (msg_types.h). */
#define AGORA_POST_BODY_MAX 4096
/* Post content-id length (blake2b-256 lowercase hex). MUST match
 * AT_APP_POST_ID_LEN (app_events.h) / AT_POST_ID_LEN (msg_types.h). */
#define AGORA_POST_ID_MAX 64

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
int agora_request_proximity(void *handle, const char *send_queue,
                            const uint8_t *peer_uuid);

/** Set (`opt_in` != 0) or clear THIS node's opt-in EXACT position (Phase 2).
 *  `lat`/`lon` are degrees. Stored LOCAL-ONLY by identity and never advertised —
 *  it feeds only the pairwise proximity probe. Returns 0 on success, negative on
 *  error (AT_APP_NOT_READY == -2). */
int agora_set_exact_position(void *handle, const char *send_queue, int opt_in,
                             double lat, double lon);

/** Non-blocking poll. Writes up to @p max flattened events into @p out. Returns
 *  the count written (0 = nothing arrived), or a negative AT error code. */
int agora_events_poll(void *handle, agora_event_t *out, int max);

/** Close the handle opened by agora_events_open(). */
void agora_events_close(void *handle);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* AT_AGORA_SHIM_H */
