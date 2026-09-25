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

#ifndef ID_SOCIAL_H
#define ID_SOCIAL_H

/**
 * @file id_social.h
 * @brief The social feature's entry points beside its verbs: the setters and
 *        getters the conformance adapter and tests drive, each the twin of a
 *        Python IdentityProcess method. Moved from id_proc_priv.h when social
 *        left id_proc.c (FEATURE_SPLIT_PLAN Phase 5).
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "identity/id_proc_priv.h"
#include "profile.h"
#include "connection.h"
#include "proximity.h"

/** Set (or clear) THIS node's opt-in coarse position (Increment 2, the
 *  "with-distance" feature) in the singleton id_state. A valid non-empty
 *  geohash opts in; NULL/""/invalid opts out (the default). The harness analog
 *  of the app's set-position IPC verb; conformance installs it from
 *  `fixtures.positions`. */
void identity_set_own_geohash(const char *geohash);

/** Copy the coarse geohash recorded for peer @p uuid_str (lowercased uuid
 *  string) into @p buf, always NUL-terminated. Returns true iff a position is
 *  stored. The map is filled by handle_position_response; conformance asserts
 *  via the `peer_position` expected_state key. */
bool identity_get_peer_position(const char *uuid_str, char *buf, size_t buflen);

/** Set (or clear) THIS node's opt-in agora.profile (Increment 3) in the
 *  singleton id_state, from a JSON object string of profile fields. NULL/""/an
 *  empty object opts out (the default). The harness analog of the app's
 *  set-profile IPC verb; conformance installs it from `fixtures.profiles`. */
void identity_set_own_profile(const char *profile_json);

/** Copy the compact profile JSON recorded for peer @p uuid_str (lowercased uuid
 *  string) into @p buf, always NUL-terminated. Returns true iff a (verified)
 *  profile is stored. The map is filled by handle_profile_response; conformance
 *  asserts via the `peer_profile` expected_state key. */
bool identity_get_peer_profile(const char *uuid_str, char *buf, size_t buflen);

/** The connection edge-state this node holds toward peer @p uuid_str (lowercased
 *  uuid string), as an at_conn_state_t int (Increment 5): none=0, pending_out=1,
 *  pending_in=2, connected=3, declined=4. 0 if no edge is recorded. The map is
 *  filled by handle_connection_request/response and the app connect verbs;
 *  conformance asserts via the `connection_state` expected_state key. Twin of
 *  Python IdentityProcess.get_connection_state. */
int identity_get_connection_state(const char *uuid_str);

/** Pre-seed THIS node's connection edge-state toward peer @p uuid_str (lowercased
 *  uuid string) as an at_conn_state_t int, standing in for a completed
 *  request/accept exchange. Conformance installs bilateral CONNECTED edges from
 *  `fixtures.connections` so a proximity scenario (connected-peers-only) need not
 *  re-run the handshake. Twin of the Python adapter setting connection_edges. */
void identity_set_connection_state(const char *uuid_str, int state);

/** Set (or clear) THIS node's opt-in EXACT position (Phase 2, private proximity)
 *  in the singleton id_state. @p set false clears it (opts out, the default);
 *  true with in-range lat/lon opts in. LOCAL-ONLY — never advertised; feeds only
 *  the pairwise distance-band probe. The harness analog of the app's
 *  AT_APP_SET_EXACT_POSITION IPC verb; conformance installs it from
 *  `fixtures.exact_positions`. Twin of setting Python own_exact. */
void identity_set_exact_position(bool set, double lat, double lon);

/** The coarse distance BAND this node last learned toward peer @p uuid_str
 *  (lowercased uuid string), as an at_prox_band_t int (Phase 2): unknown=0,
 *  near=1, mid=2, far=3. 0 if none recorded. The map is filled by the proximity
 *  handlers alongside the app emit; conformance asserts via the `peer_proximity`
 *  expected_state key. Twin of Python IdentityProcess.get_peer_proximity. */
int identity_get_peer_proximity(const char *uuid_str);

/** The most-recent DM this node received from peer @p uuid_str (Increment 6).
 *  Copies the body into @p text_buf (always NUL-terminated) and, when non-NULL,
 *  the sender's freshness seq into @p seq_out. Returns true iff a DM is recorded
 *  for that peer. The map is filled by handle_dm (observability only — a DM is a
 *  live stream, never roster-replayed); conformance asserts via the `dm_last`
 *  expected_state key. Twin of Python IdentityProcess.get_last_dm. */
bool identity_get_last_dm(const char *uuid_str, char *text_buf, size_t text_sz,
                          int64_t *seq_out);

/** The most-recent co-signing ask this node received from peer @p uuid_str
 *  (Phase 3 P3.3). Copies the exchange's fields into the caller's buffers (all
 *  always NUL-terminated) and, when non-NULL, the requester's freshness seq into
 *  @p seq_out. Returns true iff an ask is recorded for that peer. Filled by
 *  handle_cosign_request after the shape gate and the freshness gate
 *  (observability only — an exchange is a live stream, never roster-replayed);
 *  conformance asserts via the `cosign_request_last` expected_state key. Twin of
 *  Python IdentityProcess.get_last_cosign_request. Note there is no description
 *  field to read: the wording of what is being signed never crosses the wire —
 *  the signer's own node derives it from the bytes (see social/cosign.h). */
bool identity_get_last_cosign_request(const char *uuid_str, char *record_buf,
                                      size_t record_sz, char *op_buf,
                                      size_t op_sz, char *polity_buf,
                                      size_t polity_sz, char *cid_buf,
                                      size_t cid_sz, char *bytes_buf,
                                      size_t bytes_sz, int64_t *seq_out);

/** The most-recent co-signature peer @p uuid_str returned to this node (Phase 3
 *  P3.3). Returns true iff a signature is recorded for that peer. The core does
 *  NOT verify it — it does not hold the payload the signature is over, and the
 *  assembling node does; conformance asserts via the `cosign_sig_last`
 *  expected_state key. Twin of Python IdentityProcess.get_last_cosign_sig. */
bool identity_get_last_cosign_sig(const char *uuid_str, char *cid_buf,
                                  size_t cid_sz, char *signer_buf,
                                  size_t signer_sz, char *sig_buf,
                                  size_t sig_sz, int64_t *seq_out);

/** The most-recent feed post this node accepted from AUTHOR @p uuid_str
 *  (Increment 7). Copies the content id into @p post_id_buf and the body into
 *  @p body_buf (both always NUL-terminated) and, when non-NULL, the author's
 *  post seq into @p seq_out and the required audience tier into @p tier_out.
 *  Returns true iff a post is recorded for that author. Filled by handle_post
 *  after signature-verify + tier-gate + dedup (observability only — a post is a
 *  live stream, never roster-replayed); conformance asserts via the `post_last`
 *  expected_state key. Twin of Python IdentityProcess.get_last_post. */
bool identity_get_last_post(const char *uuid_str, char *post_id_buf,
                            size_t post_id_sz, char *body_buf, size_t body_sz,
                            int64_t *seq_out, int *tier_out);

/* Conformance/observability seam (Phase 3 P3.2): what this node knows about
 * business @p did — the page bundle it holds, that page's version, and how many
 * CUSTOMERS have vouched for it (the business's own ad is not an endorsement).
 * Returns true and fills the outputs if a page is held. Mirrors Python
 * get_business_page. */
bool identity_get_business_page(const char *did, char *bundle_buf,
                                size_t bundle_sz, int64_t *seq_out,
                                int *endorsers_out);

/* Conformance/observability seam (Phase 3 P3.4): the most-recent business post
 * this node ACCEPTED for polity @p did — keyed by the polity, not by whoever
 * relayed it, because the post is the business's and the carrier is incidental.
 * Copies the content id into @p post_id_buf and the opaque Ethne bundle into
 * @p bundle_buf (both always NUL-terminated) and, when non-NULL, the post's seq
 * into @p seq_out and the hop count it arrived at into @p hops_out. Returns
 * true iff a post is recorded. Filled by handle_business_post AFTER the
 * signature check, the page gate and dedup — so a scenario asserting on it is
 * asserting that all three passed. Twin of Python
 * IdentityProcess.get_last_business_post. */
bool identity_get_last_business_post(const char *did, char *post_id_buf,
                                     size_t post_id_sz, char *bundle_buf,
                                     size_t bundle_sz, int64_t *seq_out,
                                     int *hops_out);

/* Conformance/test seam (Phase 3 P3.2): install or clear THIS node's CUSTOMER
 * edge to business @p did WITHOUT putting an ad on the wire — the app's
 * AT_APP_SET_CUSTOMER verb minus its advertising half. A negative @p
 * satisfaction clears the edge. Conformance installs edges from
 * `fixtures.customers` so a scenario can separate a node that WILL carry a page
 * from one that will not, without the setup counting as an emission. Twin of
 * the Python adapter calling set_customer() with no queues. */
void identity_set_customer(const char *did, int satisfaction,
                           const char *bundle, int64_t seq);

/* Conformance/observability seam (Phase 3 P3.2): this node's OWN customer
 * satisfaction toward @p did (0..4), or -1 when it holds no customer edge — and
 * therefore carries nothing for that business. Mirrors Python
 * get_customer_satisfaction. */
int identity_get_customer_satisfaction(const char *did);

/** The last interaction score this node STAGED about subject peer @p uuid_str
 *  (Increment 8) — the deterministic accrual observable, recorded at submit time
 *  independent of the Paxos round. Copies the task_uuid hex into @p task_out
 *  (>= 37 bytes) and, when non-NULL, the score into @p score_out. Returns true iff
 *  a staged score is recorded for that subject. Twin of Python
 *  IdentityProcess.get_last_social_tx; conformance asserts via the
 *  `social_tx_last` expected_state key. */
bool identity_get_last_social_tx(const char *uuid_str, char *task_out,
                                 double *score_out);

/** The rest of the staged record identity_get_last_social_tx reads (Phase 4
 *  P4.1): the evidence channel the score was staged on (copied into
 *  @p channel_out, @p channel_len bytes, when non-NULL) and @p n_out, how many
 *  scores this node has staged about the subject in total. The channel is what
 *  tells a first-person report from every other staged score; the count is what
 *  tells a capped second attempt from none at all. Returns true iff a record
 *  exists. Conformance asserts via `social_tx_last`'s `channel` and `n`. */
bool identity_get_social_tx_detail(const char *uuid_str, char *channel_out,
                                   size_t channel_len, int *n_out);

/** Conformance/test seam: locally block @p uuid_str (lowercased peer uuid), the
 *  same record handle_app_block writes, callable without assembling an app
 *  message so a conformance step can drive the clamp. identity_get_peer_tier
 *  then returns 0 for this peer. Purely local — no wire, no reputation tx. Twin
 *  of Python IdentityProcess.block_peer. */
void identity_block_peer(const char *uuid_str);

/** Conformance/test seam: lift the block on @p uuid_str, the same record
 *  handle_app_unblock removes. A DELETE, not a second flag — "blocked" IS the
 *  presence of the key, so nothing can disagree with it and re-blocking is
 *  idempotent. Twin of Python IdentityProcess.unblock_peer. */
void identity_unblock_peer(const char *uuid_str);

/** Conformance/observability read-back: true iff @p uuid_str is locally
 *  blocked. Twin of Python IdentityProcess.is_blocked. */
bool identity_is_blocked(const char *uuid_str);

/** Conformance/test seam: save the block set and load it back — the round trip
 *  a restart performs, without needing one. A test that checked only the
 *  in-memory map would pass with no file written at all. @p cfg_dir is where
 *  to write; NULL means the process's own config directory. A conformance step
 *  passes a writable temp dir, because the harness's default root is /etc/at
 *  and nothing may be written there — without which this seam would prove
 *  nothing while appearing to pass. Twin of Python
 *  IdentityProcess.reload_social_blocks. */
void identity_reload_social_blocks(const char *cfg_dir);

#endif /* ID_SOCIAL_H */
