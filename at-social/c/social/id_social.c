/********************
 *  Copyright 2024 TekFive, Inc., Sean M. Brennan, and contributors
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

/* The social feature on the identity process: position, proximity, profile,
 * connections, DMs, feed posts and reactions, reports and blocks, business
 * ads and posts, cosign (FEATURE_SPLIT_PLAN Phase 5). It keeps its own state
 * behind its own lock, follows identity through the hooks in identity/id_ext.h
 * (every one called with no identity lock held) and registers its verbs
 * through processes/extension.h. Moved here verbatim from id_proc.c; see
 * extensions.md, "Social". */

#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <sodium.h>

#include "processes/processes.h"
#include "processes/extension.h"
#include "structures/map.h"
#include "utilities/message.h"
#include "utilities/msg_types_priv.h"
#include "utilities/exception.h"
#include "utilities/probes.h"
#include "utilities/timeout.h"
#include "structures/data.h"
#include "network/net_message.h"
#include "network/network.h"
#include "config/configuration.h"
#include "identity/peers.h"
#include "identity/identity_priv.h"
#include "identity/id_proc_priv.h"
#include "identity/id_ext.h"
#include "id_social.h"
#include "at_social.h"
#include "at_agora.h"
#include "utilities/b64.h"
#include "utilities/freshness.h"
#include "social_msg_types.h"
#include "profile.h"
#include "connection.h"
#include "dm.h"
#include "post.h"
#include "business_ad.h"
#include "business_post.h"
#include "post_store.h"
#include "cosign.h"
#include "social_tx.h"
#include "social_store.h"
#include "community.h"
#include "proximity.h"
static bool _peer_shares_our_group(const process_t *proc, const char *peer_uuid_str);
static json_t *_business_map_load_json(map_t *map, const char *key);
static void _record_peer_group_uuid(const process_t *proc,
                                    const char *peer_uuid_str,
                                    const char *group_uuid_str);
/* Defined with the connection handlers below; the proximity handlers (earlier in
 * the file) need it to resolve a connected peer's public identity. */
static char ID_POSITION_QUERY[]    = "peer_position_query";
static char ID_POSITION_RESPONSE[] = "peer_position_response";
static char ID_PROFILE_QUERY[]     = "peer_profile_query";
static char ID_PROFILE_RESPONSE[]  = "peer_profile_response";
/* Private-proximity probe/reply (Phase 2). Directed + ENCRYPTED (never on the
 * plaintext allowlist): each carries {salt, tags} where tags are multi-
 * resolution grid tags keyed by the pairwise box secret (social/proximity.c).
 * The two CONNECTED peers each learn only a coarse distance BAND; neither the
 * exact position nor the cell is revealed, and a third party sees opaque tags. */
static char ID_PROXIMITY_PROBE[]   = "peer_proximity_probe";
static char ID_PROXIMITY_REPLY[]   = "peer_proximity_reply";
/* Explicit connection edge-state (Increment 5). Directed + ENCRYPTED (never on
 * the plaintext allowlist): the request is a bare ask, the response carries a
 * detached Ed25519 signature over the canonical (requester, accepter, decision,
 * seq) form (social/connection.c). USER-INITIATED — not auto-sent on confirm. */
static char ID_CONNECTION_REQUEST[]  = "peer_connection_request";
static char ID_CONNECTION_RESPONSE[] = "peer_connection_response";
/* Direct message (Increment 6). Directed + ENCRYPTED (never on the plaintext
 * allowlist): a single one-way peer→peer text message carrying {text, seq, ts}.
 * crypto_box authenticates the sender, so NO extra signature is needed. */
static char ID_DM[]          = "peer_dm";
/* Feed post (Increment 7). Encrypted GROUP MULTICAST (never on the plaintext
 * allowlist; rides NET_CHAN_GROUP, group_encrypt'd): a signed, content-addressed
 * feed item carrying {author, author_pk, seq, ts, tier, body, sig, hops}. The
 * detached Ed25519 signature (not crypto_box) authenticates the author, because a
 * post is gossip-forwarded by peers other than its author. */
static char ID_POST[]        = "peer_post";
/* Post reaction (Increment 8). Directed + ENCRYPTED (never on the plaintext
 * allowlist), exactly like a DM: a one-way reactor→author message carrying
 * {post_id, seq, ts}. crypto_box authenticates the reactor, so NO extra signature
 * is needed. It is the return signal a fire-and-forget post lacks, letting the
 * engagement accrue reputation for both peers. */
static char ID_REACTION[]    = "peer_reaction";
/* First-person report (Phase 4 P4.1). Directed + ENCRYPTED (never on the
 * plaintext allowlist), exactly like a reaction: {seq, ts} and NOTHING ELSE.
 * crypto_box authenticates the reporter, and no reason text travels — on the
 * wire a reason would make a score a published accusation. The reported node
 * stages its half of the bilateral transaction and tells its app nothing. */
static char ID_REPORT[]      = "peer_report";
/* Business ad (Phase 3 P3.2). Encrypted GROUP MULTICAST like a post (never on
 * the plaintext allowlist), carrying {advertiser, advertiser_pk, polity, sat,
 * seq, ts, bundle, sig}. The detached Ed25519 signature authenticates the
 * ADVERTISER — the business itself or one of its customers speaking in the first
 * person. There is no hop count: ads are re-advertised by customers, never
 * relayed (social/business_ad.h). */
static char ID_BUSINESS_AD[] = "peer_business_ad";
/* Business posts (Phase 3 P3.4). Encrypted GROUP MULTICAST like a feed post
 * (NOT on the plaintext allowlist: ID_UNENCRYPTED_VERBS does not name it),
 * carrying {author, author_pk, polity, seq, ts, bundle, sig, hops}. UNLIKE an
 * ad, a post IS relayed: its authority is the envoy signature sealed inside the
 * opaque bundle, so passing it along cannot launder it. The detached Ed25519
 * signature here authenticates only WHO SENT THIS COPY. */
static char ID_BUSINESS_POST[] = "peer_business_post";
/* STORE-AND-FORWARD (Agora Phase 4 DDIL, 2026-09-25). A post is a multicast,
 * and a multicast is fire-and-forget: a node that is not on the segment when it
 * goes out never hears it, so across a partition every post the other island
 * made was lost for good. Three verbs close that, with no partition detection
 * at all, because the first is periodic:
 *
 *   peer_post_digest    GROUP MULTICAST, encrypted: the content ids of our
 *                       recent stored posts, {"feed":[...], "biz":[...]};
 *   peer_post_want      DIRECTED, encrypted: the ids from a digest that our
 *                       dedup rings do not hold, back to its sender;
 *   peer_post_backfill  DIRECTED, encrypted: one stored post, its ORIGINAL
 *                       signed envelope, {"kind":"feed"|"biz","post":{...}}.
 *
 * A backfilled post re-verifies against its author's signature and passes the
 * same gate and dedup as the original (_ingest_post / _ingest_business_post),
 * so the node serving it vouches for nothing. It is terminal: never relayed.
 * Digest and want are honoured only from admitted peers. None of the three is
 * on the plaintext allowlist. See post_store.h. */
/* COMMUNITIES (Phase 4, Ethne D37). A community's content policy and a
 * moderator's labels, both opaque Ethne artifacts the core carries and never
 * parses (community.h):
 *
 *   peer_community_policy  GROUP MULTICAST, encrypted: a root-signed policy,
 *                          carried in the FIRST PERSON by a node that follows
 *                          the community, like a business ad. Never relayed.
 *   peer_post_label        GROUP MULTICAST, encrypted: a moderator's labels on
 *                          one post, relayed a bounded number of hops by nodes
 *                          that follow the community, like a business post.
 *
 * Neither is on the plaintext allowlist. */
static char ID_COMMUNITY_POLICY[] = "peer_community_policy";
static char ID_POST_LABEL[]       = "peer_post_label";
static char ID_POST_DIGEST[]   = "peer_post_digest";
static char ID_POST_WANT[]     = "peer_post_want";
static char ID_POST_BACKFILL[] = "peer_post_backfill";
/* Detached co-signing (Phase 3 P3.3). Both directed + ENCRYPTED (never on the
 * plaintext allowlist), exactly like a DM: crypto_box authenticates the sender,
 * so neither message carries a signature of its own. The request carries the
 * exported canonical bytes of a record somebody is being asked to sign; the
 * reply carries that signer's detached Ed25519 signature over those bytes.
 *
 * The core is a courier here and nothing more. It holds no Ethne, so it cannot
 * tell what the bytes mean, and it does not hold the payload the signature is
 * over, so it cannot check the signature either. Both judgments belong to the
 * nodes at the ends — which is also why no DESCRIPTION travels: the wording of
 * what a record commits to is derived by the signer, from the bytes. */
static char ID_COSIGN_REQUEST[] = "peer_cosign_request";
static char ID_COSIGN_SIG[]     = "peer_cosign_sig";
static char ID_APP_SET_POSITION[] = AT_APP_SET_POSITION;
static char ID_APP_SET_PROFILE[]  = AT_APP_SET_PROFILE;
static char ID_APP_CONNECT_REQUEST[] = AT_APP_CONNECT_REQUEST;
static char ID_APP_CONNECT_RESPOND[] = AT_APP_CONNECT_RESPOND;
static char ID_APP_SEND_DM[] = AT_APP_SEND_DM;
static char ID_APP_PUBLISH_POST[] = AT_APP_PUBLISH_POST;
static char ID_APP_REACT_POST[] = AT_APP_REACT_POST;
static char ID_APP_BLOCK[] = AT_APP_BLOCK;
static char ID_APP_UNBLOCK[] = AT_APP_UNBLOCK;
static char ID_APP_REPORT_PEER[] = AT_APP_REPORT_PEER;
static char ID_APP_REQUEST_ATTEND[] = AT_APP_REQUEST_ATTEND;
static char ID_APP_SET_EXACT_POSITION[] = AT_APP_SET_EXACT_POSITION;
static char ID_APP_REQUEST_PROXIMITY[] = AT_APP_REQUEST_PROXIMITY;
static char ID_APP_ADVERTISE_BUSINESS[] = AT_APP_ADVERTISE_BUSINESS;
static char ID_APP_SET_CUSTOMER[] = AT_APP_SET_CUSTOMER;
static char ID_APP_REQUEST_COSIGN[] = AT_APP_REQUEST_COSIGN;
static char ID_APP_RETURN_COSIGN[] = AT_APP_RETURN_COSIGN;
static char ID_APP_PUBLISH_BUSINESS_POST[] = AT_APP_PUBLISH_BUSINESS_POST;
static char ID_APP_FOLLOW_COMMUNITY[] = AT_APP_FOLLOW_COMMUNITY;
static char ID_APP_UNFOLLOW_COMMUNITY[] = AT_APP_UNFOLLOW_COMMUNITY;
static char ID_APP_PUBLISH_POST_LABEL[] = AT_APP_PUBLISH_POST_LABEL;
#define POST_MAX_HOPS 1
#define POST_DEDUP_CAP 256
/* Store-and-forward bounds. A digest offers only posts younger than
 * POST_BACKFILL_MAX_AGE (by the post's own signed ts); a want asks for, and a
 * backfill serves, at most POST_WANT_MAX ids per kind; and each peer is sent at
 * most one want, and served at most one, per POST_WANT_COOLDOWN seconds. The
 * digest goes out at most every $AT_SOCIAL_DIGEST_SEC seconds (default
 * POST_DIGEST_DEFAULT_SEC), checked on identity's ~20 s resync sweep. */
#define POST_BACKFILL_MAX_AGE   (24.0 * 3600.0)
#define POST_WANT_MAX           32
#define POST_WANT_COOLDOWN      10.0
#define POST_DIGEST_DEFAULT_SEC 60

/* Business-ad bounds (Phase 3 P3.2). There is deliberately NO max-hops twin of
 * POST_MAX_HOPS: a business ad is never relayed. Only a CUSTOMER carries a
 * business's page, and a customer re-advertises it in the FIRST PERSON (its own
 * key, its own satisfaction) rather than forwarding someone else's ad — so reach
 * is bounded by the customer base itself, not by a hop count, and distribution
 * and reputation are the same fact. BUSINESS_AD_DEDUP_CAP bounds the ad-content
 * dedup ring; BUSINESS_PAGE_CAP bounds how many distinct businesses this node
 * will hold pages for (a memory bound on unsolicited ads). */
#define BUSINESS_AD_DEDUP_CAP 256
#define BUSINESS_PAGE_CAP 128

/* Business-post bounds (Phase 3 P3.4). A post DOES relay, so it reuses
 * POST_MAX_HOPS rather than inventing a second bound: "active network + one
 * hop" is a statement about how far anything travels on this channel, not
 * about who said it. BUSINESS_POST_DEDUP_CAP bounds the post-content dedup
 * ring — the thing that makes gossip converge instead of echoing. */
#define BUSINESS_POST_DEDUP_CAP 256

/* Community bounds (Phase 4). A policy ad is first-person and never relayed,
 * like a business ad; a label relays under POST_MAX_HOPS, like a business post.
 * COMMUNITIES_MAX bounds how many communities one node follows (and so carries);
 * a follow past it is refused, not evicted. Holders re-advertise every
 * $AT_SOCIAL_POLICY_SEC seconds (default POLICY_AD_DEFAULT_SEC). */
#define COMMUNITY_POLICY_DEDUP_CAP 256
#define POST_LABEL_DEDUP_CAP 256
#define COMMUNITIES_MAX 64
#define POLICY_AD_DEFAULT_SEC 300

/* Forward decls: defined below beside the position handlers, but used earlier
 * (the query from the admission path, the validator from state init). */
static int _send_position_query(const process_t *proc, const public_identity_t *peer);
static bool _geohash_valid(const char *s);
/* Profile (Increment 3): the directed query is issued from the admission path
 * (handle_confirm_peer) and the resync sweep, both earlier than the definition. */
static int _send_profile_query(const process_t *proc, const public_identity_t *peer);
/* Social state, behind its own lock (a leaf: while holding it, social
 * calls nothing that takes a lock or dispatches a hook). */
static struct {
    /* This node's OWN opt-in coarse position — a geohash bucket the operator
     * chose to share (Increment 2, the "with-distance" feature). Empty = opted
     * out, which is the DEFAULT: while empty, handle_position_query answers
     * nothing and no position is ever advertised. Set/cleared at runtime via the
     * AT_APP_SET_POSITION app verb. mutex-guarded by social_state.lock. */
    char own_geohash[AT_GEOHASH_MAX_LEN + 1];
    /* This node's OWN opt-in EXACT position (Phase 2, private proximity). Stored
     * LOCAL-ONLY and NEVER advertised — no query handler reads it; it feeds ONLY
     * the pairwise, encrypted distance-band probe with CONNECTED peers
     * (handle_request_proximity / handle_proximity_probe). own_exact_set gates
     * it; while false the node runs no proximity probe. Set/cleared via the
     * AT_APP_SET_EXACT_POSITION app verb. mutex-guarded by social_state.lock. */
    bool own_exact_set;
    double own_exact_lat;
    double own_exact_lon;
    /* Peer positions recorded by handle_position_response. Keyed by lowercased
     * uuid string; values are string_data(geohash). Mirrors peer_caps_map.
     * Conformance/assertion surface via identity_get_peer_position. */
    map_t peer_position_map;
    /* Coarse distance BAND last learned per CONNECTED peer (Phase 2, private
     * proximity), keyed by lowercased peer uuid string; values are
     * string_data(a decimal at_prox_band_t). Written by the proximity handlers
     * alongside identity_emit_peer_proximity — the band is a LIVE app emit, so
     * this map exists purely as the conformance/observability surface for
     * identity_get_peer_proximity, the twin of Python get_peer_proximity (like
     * last_dm_map, never roster-replayed). Guarded by social_state.lock. */
    map_t peer_proximity_map;
    /* This node's OWN opt-in agora.profile (Increment 3): operator-set, bounded
     * fields shared only with admitted peers that ask, over the SIGNED
     * peer_profile_query/response exchange. Empty (at_profile_is_empty) = opted
     * out (the default): handle_profile_query answers nothing. Set at runtime via
     * AT_APP_SET_PROFILE (seeded from $AT_OWN_PROFILE for headless/conformance).
     * mutex-guarded by social_state.lock. Signed per-query from the node identity's
     * key, so no stored signature. */
    at_profile_t own_profile;
    /* Peer profiles recorded by handle_profile_response (after signature verify).
     * Keyed by lowercased uuid string; values are string_data(compact profile
     * JSON — the app-boundary form). Conformance surface via
     * identity_get_peer_profile. */
    map_t peer_profile_map;
    /* Explicit connection edges (Increment 5), keyed by lowercased peer uuid
     * string; values are string_data(compact JSON {"state","seq","ts"}) where
     * state is an at_conn_state_t (none/pending_out/pending_in/connected/
     * declined). A connection is EXPLICIT, revocable, and SEPARATE from
     * reputation. Filled by handle_connection_request/response and the app
     * connect verbs; conformance surface via identity_get_connection_state. */
    map_t connection_edges;
    /* Last group uuid each peer ADVERTISED to us (handle_group_update), keyed by
     * lowercased peer uuid string, value string_data(group uuid string). The
     * "in your group" app indicator is true only when this equals OUR current
     * group uuid — i.e. we and the peer actually converged on the same group.
     * A peer's address landing in our address_map (the mesh merge) happens well
     * before key convergence (the split-brain window), so address membership is
     * NOT a sound co-membership signal; the advertised-uuid match is. */
    map_t peer_group_uuids;
    /* Most-recent DM received per sender (Increment 6), keyed by lowercased
     * sender uuid string; values are string_data(compact JSON {"text","seq",
     * "ts"}). A DM is a LIVE STREAM delivered to the app on arrival, so this is
     * NOT roster-replayed state (unlike peer_profile_map): it exists purely as
     * the conformance/observability surface for identity_get_last_dm, the twin
     * of Python IdentityProcess.get_last_dm. Filled by handle_dm after the
     * freshness gate, right before the app emit. */
    map_t last_dm_map;
    /* Feed posts (Increment 7). post_seq is our own monotonic post counter, used
     * to make each published post's canonical form (and thus its content id)
     * unique. seen_post_ids is a bounded ring of content ids this node has
     * already accepted, the APP-CONTENT dedup store (distinct from net_proc's
     * transport dedup ring): a repeat is dropped rather than re-emitted or
     * re-forwarded. last_post_map is the conformance/observability surface for
     * identity_get_last_post (keyed by lowercased AUTHOR uuid, value string_data
     * of {"post_id","seq","ts","tier","body"}); like last_dm_map it is a live
     * stream, never roster-replayed. All guarded by social_state.lock. */
    int64_t post_seq;
    char    seen_post_ids[POST_DEDUP_CAP][AT_POST_ID_HEX_LEN + 1];
    size_t  seen_post_next;
    size_t  seen_post_count;
    map_t   last_post_map;
    /* Businesses (Phase 3 P3.2). business_customers is THIS node's own customer
     * edges, keyed by polity did; values are string_data of {"sat","since",
     * "bundle","seq"}. It is the RELAY GATE and the only thing that authorizes
     * this node to carry a page: no entry, no ad — a non-customer is silent, and
     * an unhappy customer clears its entry rather than publishing anything
     * negative. business_pages is what we have LEARNED about businesses, keyed by
     * polity did; values are string_data of {"bundle","seq","ts","endorsers":
     * {uuid: sat}} — newest page wins by seq, endorsers merge. seen_business_ads
     * is the bounded ad-content-id dedup ring (the twin of seen_post_ids). The
     * bundles held here are OPAQUE: the core never parses Ethne, the app does.
     * All guarded by social_state.lock. */
    map_t   business_customers;
    map_t   business_pages;
    char    seen_business_ads[BUSINESS_AD_DEDUP_CAP][AT_BUSINESS_AD_ID_HEX_LEN + 1];
    size_t  seen_business_ad_next;
    size_t  seen_business_ad_count;
    /* Business posts (Phase 3 P3.4). seen_business_posts is the post-content
     * dedup ring (the twin of seen_post_ids, and what stops a relayed post
     * echoing round the group); business_post_seq is THIS node's own publish
     * counter; last_business_post_map is the conformance/observability surface
     * for identity_get_last_business_post, keyed by POLITY DID rather than by
     * sender — a post belongs to the business, not to whoever relayed it —
     * with string_data of {"post_id","seq","ts","hops","bundle"}. Like the
     * other live streams it is never roster-replayed. Guarded by
     * social_state.lock. */
    char    seen_business_posts[BUSINESS_POST_DEDUP_CAP][AT_BUSINESS_POST_ID_HEX_LEN + 1];
    size_t  seen_business_post_next;
    size_t  seen_business_post_count;
    int64_t business_post_seq;
    map_t   last_business_post_map;
    /* Detached co-signing (Phase 3 P3.3). The most-recent ask received per
     * requester and the most-recent signature returned per signer, keyed by
     * lowercased peer uuid; values are string_data of the compact wire JSON.
     * Like last_dm_map these are LIVE STREAMS surfaced to the app on arrival,
     * never roster-replayed — they exist as the conformance/observability
     * surface for identity_get_last_cosign_request / _sig, twins of Python
     * IdentityProcess.get_last_cosign_request / get_last_cosign_sig. Nothing
     * here is judged: the payload is opaque Ethne bytes the core cannot read,
     * and the app answers both "am I a required signer" and "is this signature
     * good". Guarded by social_state.lock. */
    map_t   last_cosign_request_map;
    map_t   last_cosign_sig_map;
    /* Per-edge social-interaction accrual bookkeeping (Increment 8), keyed by
     * lowercased peer uuid string; values are string_data(compact JSON
     * {"count","last_out","last_in","day","day_count"}). count drives the
     * diminishing-returns positive score; last_out/last_in gate bilateral_recent;
     * day/day_count enforce the per-edge daily cap. A PARALLEL map to
     * connection_edges, not an extension of it: DMs and post reactions accrue with
     * peers there is no explicit connection edge to, and overloading the edge map
     * would corrupt identity_get_connection_state. Guarded by social_state.lock. */
    map_t social_edges;
    /* Conformance/observability surface (Increment 8): the last interaction score
     * WE staged about each subject peer, keyed by lowercased subject uuid string;
     * values are string_data(compact JSON {"task","score","channel","n"}), where
     * n counts every score staged about that subject (so a scenario can tell a
     * capped second attempt from a first). Written by
     * _submit_interaction_score at the moment we would move the peer's reputation,
     * so a scenario can assert the deterministic staged score without running the
     * Paxos round. Surface via identity_get_last_social_tx; twin of Python
     * get_last_social_tx. Guarded by social_state.lock. */
    map_t social_tx_observed;
    /* How many social accrual commits WE have submitted today, across all edges —
     * the global daily cap against a Sybil fan-out. Rolls over with social_day. */
    int   social_day;
    int   social_day_count;
    /* First-person reports (Phase 4 P4.1), keyed by lowercased peer uuid string;
     * values are string_data(compact JSON {"day","out","in"}): how many reports
     * WE made about that peer today, and how many FROM that peer we paired.
     * Its own map, not fields on social_edges, because the edge record is a
     * fixed-format positive-accrual ledger that every positive path rewrites.
     * Guarded by social_state.lock. */
    map_t social_reports;
    /* Locally blocked peers (Increment 8): lowercased uuid string -> integer_data(1).
     * A block is PURELY LOCAL — it clamps identity_get_peer_tier to 0 for this peer
     * (so our own tier-gates deny it) and emits/gossips nothing. No reputation
     * transaction, unlike a decline. Guarded by social_state.lock. */
    map_t social_blocks;
    /* Store-and-forward (Agora Phase 4 DDIL): the recent signed posts we can
     * backfill, one store per kind (post_store.h); when our last digest went
     * out (0 == due now); and, keyed by peer uuid, when we last sent that peer
     * a want and last served one of its wants (integer_data of epoch seconds),
     * the two rate limits. Guarded by social_state.lock. */
    post_store_t feed_store;
    post_store_t biz_store;
    /* Moderator labels kept for backfill (Phase 4): a label made while a
     * follower was on the other side of a split reaches it after the heal. */
    post_store_t label_store;
    double       last_digest_at;
    /* Communities (Phase 4). communities is what THIS node follows, keyed by
     * DID, string_data of {"bundle","seq"}: the policy the app verified and
     * handed us, which we carry and persist. The core never replaces it from
     * the wire. last_policy_map is the observability surface for what we HEARD,
     * keyed by DID, {"policy_id","seq","bundle","carrier"}; last_label_map the
     * same for labels, keyed by the LABELLED post's id, {"label_id",
     * "community","seq","hops","bundle"}. The two rings are the content-id
     * dedup for each verb. Guarded by social_state.lock. */
    map_t        communities;
    map_t        last_policy_map;
    map_t        last_label_map;
    char         seen_policy_ads[COMMUNITY_POLICY_DEDUP_CAP][AT_COMMUNITY_ID_HEX_LEN + 1];
    size_t       seen_policy_ad_next;
    size_t       seen_policy_ad_count;
    char         seen_post_labels[POST_LABEL_DEDUP_CAP][AT_COMMUNITY_ID_HEX_LEN + 1];
    size_t       seen_post_label_next;
    size_t       seen_post_label_count;
    double       last_policy_ad_at;
    map_t        want_sent_at;
    map_t        want_served_at;
    /* Report targets whose report AT is still holding for a full network
     * queue (ISSUES §2.40): the day's cap is spent only once it goes, so a
     * second report to the same target waits until the first is settled. */
    uuid_t       reports_in_flight[ID_SEND_RETRY_MAX];
    size_t       num_reports_in_flight;
    pthread_mutex_t lock;
    bool initialized;
} social_state = { .lock = PTHREAD_MUTEX_INITIALIZER };

/* THE one place that reads social_blocks (Phase 4 P4.1). Caller must hold
 * social_state.lock.
 *
 * Until P4.1 the block was read in exactly one place — the clamp inside
 * identity_get_peer_tier — and that was mistaken for the whole of what a block
 * does. It is not: a block is a REFUSAL, and a tier is a MEASUREMENT. The
 * clamp expresses the refusal only where a tier floor happens to be above
 * zero, which is why a blocked peer's PUBLIC posts (floor 0), DMs (no floor at
 * all) and reactions all sailed through. Every inbound path now asks this
 * question directly instead of inferring it from a number. */
static bool _is_blocked_locked(const char *uuid_str)
{
    if (uuid_str == NULL)
        return false;
    data_t *bdat = NULL;
    return map_get(&social_state.social_blocks, (map_key_t)uuid_str, &bdat) == 0
           && bdat != NULL;
}

/* Lock-taking wrapper for the inbound handlers, which hold nothing. */
static bool _is_blocked(const uuid_t uuid)
{
    if (!social_state.initialized)
        return false;
    char uuid_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(uuid, uuid_str);
    pthread_mutex_lock(&social_state.lock);
    bool blocked = _is_blocked_locked(uuid_str);
    pthread_mutex_unlock(&social_state.lock);
    return blocked;
}
/* Conformance/harness seam: set (or clear) THIS node's opt-in coarse position
 * in the singleton id_state (Increment 2, the "with-distance" feature). The
 * analog of the app's handle_set_position, but called directly by the harness,
 * which drives the wire handlers rather than the app IPC verb. A valid non-empty
 * geohash opts in; NULL/""/invalid opts out — the default. Mirrors the Python
 * adapter setting process.own_geohash from fixtures.positions. */
void identity_set_own_geohash(const char *geohash)
{
    identity_state_ensure_init();
    pthread_mutex_lock(&social_state.lock);
    if (geohash != NULL && _geohash_valid(geohash))
        snprintf(social_state.own_geohash, sizeof(social_state.own_geohash), "%s",
                 geohash);
    else
        social_state.own_geohash[0] = '\0';
    pthread_mutex_unlock(&social_state.lock);
}

/* Conformance seam: copy the stored coarse geohash for peer @p uuid_str into
 * @p buf (always NUL-terminated). Returns true if a position is stored, false
 * (and buf="") otherwise. The map is filled by handle_position_response on an
 * inbound peer_position_response; scenarios assert via the `peer_position`
 * expected_state key. Twin of Python IdentityProcess.get_peer_position. */
bool identity_get_peer_position(const char *uuid_str, char *buf, size_t buflen)
{
    if (buf != NULL && buflen > 0) buf[0] = '\0';
    if (uuid_str == NULL || buf == NULL || buflen == 0) return false;
    identity_state_ensure_init();
    bool found = false;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.peer_position_map, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL)
    {
        char *g = NULL;
        if (data_string_ptr(dat, &g) == 0 && g != NULL)
        {
            snprintf(buf, buflen, "%s", g);
            found = true;
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return found;
}

/* Conformance seam: the coarse distance BAND this node last learned toward peer
 * @p uuid_str (lowercased uuid string), as an at_prox_band_t int; AT_PROX_UNKNOWN
 * (0) if none recorded. The map is filled by the proximity handlers alongside
 * identity_emit_peer_proximity; scenarios assert via the `peer_proximity`
 * expected_state key. Twin of Python IdentityProcess.get_peer_proximity. */
int identity_get_peer_proximity(const char *uuid_str)
{
    if (uuid_str == NULL) return AT_PROX_UNKNOWN;
    identity_state_ensure_init();
    int band = AT_PROX_UNKNOWN;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.peer_proximity_map, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL)
    {
        char *s = NULL;
        if (data_string_ptr(dat, &s) == 0 && s != NULL)
            band = atoi(s);
    }
    pthread_mutex_unlock(&social_state.lock);
    return band;
}

/* Conformance seam: set (or clear) THIS node's opt-in EXACT position (Phase 2,
 * private proximity). @p set false clears it (opts out, the default); @p set
 * true with in-range lat/lon opts in. LOCAL-ONLY — it feeds only the pairwise
 * distance-band probe and is never advertised. The harness analog of the app's
 * AT_APP_SET_EXACT_POSITION IPC verb; conformance installs it from
 * `fixtures.exact_positions`. Twin of setting Python own_exact. */
void identity_set_exact_position(bool set, double lat, double lon)
{
    identity_state_ensure_init();
    bool ok = set && lat >= -90.0 && lat <= 90.0 && lon >= -180.0 && lon <= 180.0;
    pthread_mutex_lock(&social_state.lock);
    social_state.own_exact_set = ok;
    social_state.own_exact_lat = ok ? lat : 0.0;
    social_state.own_exact_lon = ok ? lon : 0.0;
    pthread_mutex_unlock(&social_state.lock);
}

/* Conformance seam: set (or clear) THIS node's opt-in agora.profile from a JSON
 * object string (Increment 3). Empty/invalid/empty-object opts out. The harness
 * analog of the AT_APP_SET_PROFILE IPC verb; scenarios install it from
 * `fixtures.profiles`. Twin of setting Python IdentityProcess.own_profile. */
void identity_set_own_profile(const char *profile_json)
{
    identity_state_ensure_init();
    at_profile_t p;
    memset(&p, 0, sizeof(p));
    if (profile_json != NULL && profile_json[0] != '\0') {
        json_error_t jerr;
        json_t *o = json_loads(profile_json, 0, &jerr);
        if (o != NULL) {
            at_profile_from_json(o, false, &p);   /* trusted: truncate */
            json_decref(o);
        }
    }
    pthread_mutex_lock(&social_state.lock);
    memcpy(&social_state.own_profile, &p, sizeof(p));
    pthread_mutex_unlock(&social_state.lock);
}

/* Conformance seam: copy the stored compact profile JSON for peer @p uuid_str
 * into @p buf (always NUL-terminated). Returns true iff a verified profile is
 * stored. The map is filled by handle_profile_response; scenarios assert via
 * the `peer_profile` expected_state key. Twin of Python get_peer_profile. */
bool identity_get_peer_profile(const char *uuid_str, char *buf, size_t buflen)
{
    if (buf != NULL && buflen > 0) buf[0] = '\0';
    if (uuid_str == NULL || buf == NULL || buflen == 0) return false;
    identity_state_ensure_init();
    bool found = false;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.peer_profile_map, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL)
    {
        char *g = NULL;
        if (data_string_ptr(dat, &g) == 0 && g != NULL)
        {
            snprintf(buf, buflen, "%s", g);
            found = true;
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return found;
}

/* Conformance seam: the connection edge-state this node holds toward peer
 * @p uuid_str (lowercased uuid string), as an at_conn_state_t int; 0 (none) if
 * no edge is recorded. The map is filled by handle_connection_request/response
 * and the app connect verbs; scenarios assert via the `connection_state`
 * expected_state key. Twin of Python IdentityProcess.get_connection_state. */
int identity_get_connection_state(const char *uuid_str)
{
    if (uuid_str == NULL) return AT_CONN_NONE;
    identity_state_ensure_init();
    int state = AT_CONN_NONE;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.connection_edges, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL)
    {
        char *s = NULL;
        if (data_string_ptr(dat, &s) == 0 && s != NULL) {
            json_error_t jerr;
            json_t *o = json_loads(s, 0, &jerr);
            if (o != NULL) {
                json_t *js = json_object_get(o, "state");
                if (json_is_integer(js)) state = (int)json_integer_value(js);
                json_decref(o);
            }
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return state;
}

/* Conformance seam: pre-seed the edge state this node holds toward peer
 * @p uuid_str (lowercased uuid string) as an at_conn_state_t int, standing in
 * for a completed request/accept exchange so a scenario exercising a DOWNSTREAM
 * connected-peers-only feature (proximity) need not re-run the handshake. Writes
 * the same {"state","seq","ts"} compact JSON as _connection_store, so
 * identity_get_connection_state reads it back. Self-contained (does not depend on
 * the AT_SOCIAL-gated handlers) so it links in any build; conformance installs
 * it from `fixtures.connections`. Twin of the Python adapter setting
 * connection_edges directly. */
void identity_set_connection_state(const char *uuid_str, int state)
{
    if (uuid_str == NULL) return;
    identity_state_ensure_init();
    char buf[96];
    int len = snprintf(buf, sizeof(buf),
                       "{\"state\":%d,\"seq\":%llu,\"ts\":%lld}",
                       state, 0ULL, (long long)time(NULL));
    if (len <= 0 || (size_t)len >= sizeof(buf)) return;
    char *dup = smrt_create((size_t)len + 1);
    if (dup == NULL) return;
    memcpy(dup, buf, (size_t)len + 1);
    data_t *dat = string_data(dup, (size_t)len + 1);
    if (dat == NULL) { smrt_deref(dup); return; }
    pthread_mutex_lock(&social_state.lock);
    map_set(&social_state.connection_edges, (map_key_t)uuid_str, dat);
    pthread_mutex_unlock(&social_state.lock);
}

/* Conformance seam: the most-recent DM this node received from peer @p uuid_str
 * (Increment 6). Copies the body into @p text_buf (always NUL-terminated) and,
 * when non-NULL, the sender's freshness seq into @p seq_out. Returns true iff a
 * DM is recorded for that peer. The map is filled by handle_dm; scenarios assert
 * via the `dm_last` expected_state key. Twin of Python get_last_dm. A DM is a
 * live stream, so this is observability only — never roster-replayed. */
bool identity_get_last_dm(const char *uuid_str, char *text_buf, size_t text_sz,
                          int64_t *seq_out)
{
    if (text_buf != NULL && text_sz > 0) text_buf[0] = '\0';
    if (seq_out != NULL) *seq_out = 0;
    if (uuid_str == NULL) return false;
    identity_state_ensure_init();
    bool found = false;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.last_dm_map, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL)
    {
        char *s = NULL;
        if (data_string_ptr(dat, &s) == 0 && s != NULL) {
            json_error_t jerr;
            json_t *o = json_loads(s, 0, &jerr);
            if (o != NULL) {
                json_t *jt = json_object_get(o, "text");
                json_t *js = json_object_get(o, "seq");
                if (json_is_string(jt) && text_buf != NULL && text_sz > 0)
                    snprintf(text_buf, text_sz, "%s", json_string_value(jt));
                if (json_is_integer(js) && seq_out != NULL)
                    *seq_out = (int64_t)json_integer_value(js);
                json_decref(o);
                found = true;
            }
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return found;
}

/* Read one string field of a recorded co-signing exchange into @p buf. */
static void _cosign_field(const json_t *o, const char *key, char *buf,
                          size_t buf_sz)
{
    if (buf == NULL || buf_sz == 0) return;
    buf[0] = '\0';
    const json_t *v = json_object_get((json_t*)o, key);
    if (json_is_string(v)) snprintf(buf, buf_sz, "%s", json_string_value(v));
}

/* The most-recent co-signing ask this node received from peer @p uuid_str
 * (Phase 3 P3.3). Conformance/observability seam, twin of Python
 * get_last_cosign_request; filled by handle_cosign_request after the shape gate
 * and the freshness gate. Returns true iff an ask is recorded for that peer. */
bool identity_get_last_cosign_request(const char *uuid_str, char *record_buf,
                                      size_t record_sz, char *op_buf,
                                      size_t op_sz, char *polity_buf,
                                      size_t polity_sz, char *cid_buf,
                                      size_t cid_sz, char *bytes_buf,
                                      size_t bytes_sz, int64_t *seq_out)
{
    if (record_buf != NULL && record_sz > 0) record_buf[0] = '\0';
    if (op_buf != NULL && op_sz > 0) op_buf[0] = '\0';
    if (polity_buf != NULL && polity_sz > 0) polity_buf[0] = '\0';
    if (cid_buf != NULL && cid_sz > 0) cid_buf[0] = '\0';
    if (bytes_buf != NULL && bytes_sz > 0) bytes_buf[0] = '\0';
    if (seq_out != NULL) *seq_out = 0;
    if (uuid_str == NULL) return false;
    identity_state_ensure_init();
    bool found = false;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.last_cosign_request_map, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL)
    {
        char *s = NULL;
        if (data_string_ptr(dat, &s) == 0 && s != NULL) {
            json_error_t jerr;
            json_t *o = json_loads(s, 0, &jerr);
            if (o != NULL) {
                _cosign_field(o, "record", record_buf, record_sz);
                _cosign_field(o, "op", op_buf, op_sz);
                _cosign_field(o, "polity", polity_buf, polity_sz);
                _cosign_field(o, "cid", cid_buf, cid_sz);
                _cosign_field(o, "bytes", bytes_buf, bytes_sz);
                json_t *js = json_object_get(o, "seq");
                if (json_is_integer(js) && seq_out != NULL)
                    *seq_out = (int64_t)json_integer_value(js);
                json_decref(o);
                found = true;
            }
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return found;
}

/* The most-recent co-signature peer @p uuid_str returned to this node (Phase 3
 * P3.3). Conformance/observability seam, twin of Python get_last_cosign_sig.
 * The core does NOT verify what it records here — it does not hold the payload
 * the signature is over; the assembling node does. */
bool identity_get_last_cosign_sig(const char *uuid_str, char *cid_buf,
                                  size_t cid_sz, char *signer_buf,
                                  size_t signer_sz, char *sig_buf,
                                  size_t sig_sz, int64_t *seq_out)
{
    if (cid_buf != NULL && cid_sz > 0) cid_buf[0] = '\0';
    if (signer_buf != NULL && signer_sz > 0) signer_buf[0] = '\0';
    if (sig_buf != NULL && sig_sz > 0) sig_buf[0] = '\0';
    if (seq_out != NULL) *seq_out = 0;
    if (uuid_str == NULL) return false;
    identity_state_ensure_init();
    bool found = false;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.last_cosign_sig_map, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL)
    {
        char *s = NULL;
        if (data_string_ptr(dat, &s) == 0 && s != NULL) {
            json_error_t jerr;
            json_t *o = json_loads(s, 0, &jerr);
            if (o != NULL) {
                _cosign_field(o, "cid", cid_buf, cid_sz);
                _cosign_field(o, "signer", signer_buf, signer_sz);
                _cosign_field(o, "sig", sig_buf, sig_sz);
                json_t *js = json_object_get(o, "seq");
                if (json_is_integer(js) && seq_out != NULL)
                    *seq_out = (int64_t)json_integer_value(js);
                json_decref(o);
                found = true;
            }
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return found;
}
/****************************
 * Opt-in coarse position (Increment 2, the "with-distance" feature).
 *
 * Design mirrors the caps directed exchange above: a node shares its own coarse
 * geohash bucket ONLY with admitted peers that ask, over an encrypted,
 * freshness-stamped {"pos", "seq"} response. STRICTLY OPT-IN: own_geohash is
 * empty by default, and while empty handle_position_query answers nothing — no
 * geographic datum leaves the node. The geohash is opaque here; the app decodes
 * it and computes distance. A received geohash is untrusted peer input, bounded
 * and charset-validated on the way in.
 ****************************/

/* Geohash base32 alphabet (a/i/l/o excluded). Validation only — never decoded. */
static bool _geohash_valid(const char *s)
{
    if (s == NULL) return false;
    size_t n = strlen(s);
    if (n == 0 || n > AT_GEOHASH_MAX_LEN) return false;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (!((c >= '0' && c <= '9') ||
              (c >= 'b' && c <= 'z' && c != 'i' && c != 'l' && c != 'o')))
            return false;
    }
    return true;
}

/* AT -> app: surface one peer's shared position as PEER_POSITION_OBSERVED to
 * AT_MAIN_QUEUE; the main loop forwards it to the app queue, where app_events.c
 * decodes it as AT_APP_EVENT_PEER_POSITION. Mirrors identity_emit_peer_observed's
 * route. @p geohash "" is valid (peer shared none). */
static int identity_emit_peer_position(const uuid_t peer_uuid, const char *geohash)
{
    generic_msg_t msg = {0};
    msg.type = PEER_POSITION_OBSERVED;
    peer_position_msg_t *ext = AT_MSG_EXT(&msg, peer_position_msg_t);
    msg.size = sizeof(peer_position_msg_t);
    memcpy(ext->peer_uuid, peer_uuid, 16);
    if (geohash != NULL)
        snprintf(ext->geohash,
                 sizeof(ext->geohash), "%s", geohash);
    return messaging_send(AT_MAIN_QUEUE, PEER_POSITION_OBSERVED, &msg, false);
}

/* Handler: a peer asks for our coarse position. Opted out (empty own_geohash) =>
 * answer NOTHING. Otherwise reply directed + encrypted with {"pos","seq"}. */
static bool handle_position_query(const process_t *proc, directory_t *queues, generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;

    char own[AT_GEOHASH_MAX_LEN + 1];
    pthread_mutex_lock(&social_state.lock);
    snprintf(own, sizeof(own), "%s", social_state.own_geohash);
    pthread_mutex_unlock(&social_state.lock);
    if (own[0] == '\0') {
        log_debug(proc->logger,
                  "Identity: position_query from %s; opted out, no answer\n",
                  nmsg->from_whom.nickname);
        return true;   /* opted out: share nothing */
    }

    generic_msg_t response = {0};
    response.type = NET_MESSAGE;
    strncpy(response.info.net_msg.process, "identity", PROC_NAME_LEN);
    response.info.net_msg.function = ID_POSITION_RESPONSE;
    response.info.net_msg.encrypt = true;
    memcpy(&response.info.net_msg.to_whom, &nmsg->from_whom,
           sizeof(public_identity_t));
    strncpy(response.info.net_msg.return_to, "identity", PROC_NAME_LEN);

    int64_t seq = identity_freshness_stamp(proc->logger);
    if (seq <= 0) {
        log_warn(proc->logger,
                 "Identity: no freshness sequence; not answering position query\n");
        return true;
    }
    json_t *env = json_object();
    if (env == NULL) return true;
    json_object_set_new(env, "pos", json_string(own));
    json_object_set_new(env, "seq", json_integer((json_int_t)seq));
    net_msg_pack_json(&response.info.net_msg, env);
    json_decref(env);
    messaging_send("network", NET_MESSAGE, &response, false);
    return true;
}

/* Handler: store a peer's position from a {"pos","seq"} response, freshness-
 * checked and validated, then surface it to the app. */
static bool handle_position_response(const process_t *proc, directory_t *queues, generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;

    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_pos = json_object_get(payload, "pos");
    json_t *j_seq = json_object_get(payload, "seq");
    if (!json_is_string(j_pos) || !json_is_integer(j_seq)) {
        json_decref(payload);
        log_warn(proc->logger,
                 "Identity: position_response unstamped/malformed, refusing\n");
        return true;
    }

    char sender[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, sender);
    int64_t seq = (int64_t)json_integer_value(j_seq);
    bool fresh = identity_freshness_accept(sender, ID_POSITION_RESPONSE, seq,
                                           proc->logger);
    if (!fresh) {
        json_decref(payload);
        log_debug(proc->logger,
                  "Identity: position_response from %s refused (replay)\n", sender);
        return true;
    }

    const char *pos = json_string_value(j_pos);
    if (!_geohash_valid(pos)) {
        json_decref(payload);
        log_warn(proc->logger,
                 "Identity: position_response from %s: invalid geohash, dropping\n",
                 sender);
        return true;
    }

    size_t len = strlen(pos);
    char *dup = smrt_create(len + 1);
    if (dup == NULL) { json_decref(payload); return true; }
    memcpy(dup, pos, len + 1);
    data_t *pos_dat = string_data(dup, len + 1);
    if (pos_dat == NULL) { smrt_deref(dup); json_decref(payload); return true; }
    pthread_mutex_lock(&social_state.lock);
    map_set(&social_state.peer_position_map, sender, pos_dat);
    pthread_mutex_unlock(&social_state.lock);
    json_decref(payload);

    identity_emit_peer_position(nmsg->from_whom.uuid, pos);
    log_debug(proc->logger, "Identity: recorded position for peer %s\n", sender);
    return true;
}

/* App -> AT verb (AT_APP_SET_POSITION): set or clear THIS node's opt-in coarse
 * position. Payload {"pos": "<geohash>"}; empty/missing/invalid clears it (opt
 * out). Runtime-updatable so the operator can toggle sharing live. */
static bool handle_set_position(const process_t *proc, directory_t *queues, generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    char geo[AT_GEOHASH_MAX_LEN + 1] = {0};
    if (net_msg_unpack_json(nmsg, &payload) == 0 && payload != NULL) {
        json_t *j_pos = json_object_get(payload, "pos");
        if (json_is_string(j_pos)) {
            const char *p = json_string_value(j_pos);
            if (_geohash_valid(p))
                snprintf(geo, sizeof(geo), "%s", p);
            /* invalid or empty -> geo stays "" (opt out) */
        }
        json_decref(payload);
    }
    pthread_mutex_lock(&social_state.lock);
    snprintf(social_state.own_geohash, sizeof(social_state.own_geohash), "%s", geo);
    pthread_mutex_unlock(&social_state.lock);
    log_info(proc->logger, "Identity: own position %s\n",
             geo[0] ? "set (opted in)" : "cleared (opted out)");
    return true;
}

/* Directed position query to one admitted peer (mirrors _send_caps_query).
 * Encrypt=true: peer_position_query is NOT on the plaintext allowlist, so a
 * known peer refuses it in plaintext; it must ride the encrypted leg. Matches
 * Python _send_position_query (default encrypt=True). */
static int _send_position_query(const process_t *proc, const public_identity_t *peer)
{
    generic_msg_t query = {0};
    query.type = NET_MESSAGE;
    strncpy(query.info.net_msg.process, "identity", PROC_NAME_LEN);
    query.info.net_msg.function = ID_POSITION_QUERY;
    query.info.net_msg.encrypt = true;
    memcpy(&query.info.net_msg.to_whom, peer, sizeof(public_identity_t));
    strncpy(query.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    messaging_send("network", NET_MESSAGE, &query, false);
    log_debug(proc->logger, "Identity: sent position_query to %s\n", peer->nickname);
    return 0;
}

/* ---- Private proximity (Phase 2, social/proximity.c) ------------------- */

/* AT -> app: surface the coarse distance BAND to one CONNECTED peer as
 * PEER_PROXIMITY_OBSERVED (no coordinates — only the band). */
static int identity_emit_peer_proximity(const uuid_t peer_uuid, int band)
{
    generic_msg_t msg = {0};
    msg.type = PEER_PROXIMITY_OBSERVED;
    peer_proximity_msg_t *ext = AT_MSG_EXT(&msg, peer_proximity_msg_t);
    msg.size = sizeof(peer_proximity_msg_t);
    memcpy(ext->peer_uuid, peer_uuid, 16);
    ext->band = band;
    return messaging_send(AT_MAIN_QUEUE, PEER_PROXIMITY_OBSERVED, &msg, false);
}

/* Record the coarse @p band learned toward peer @p uuid_str (lowercased uuid
 * string) into peer_proximity_map as a decimal string. Purely the
 * conformance/observability surface for identity_get_peer_proximity; the LIVE
 * signal is the app emit. Own locking, mirrors _connection_store. */
static void _proximity_store(const char *uuid_str, int band)
{
    char buf[16];
    int len = snprintf(buf, sizeof(buf), "%d", band);
    if (len <= 0 || (size_t)len >= sizeof(buf)) return;
    char *dup = smrt_create((size_t)len + 1);
    if (dup == NULL) return;
    memcpy(dup, buf, (size_t)len + 1);
    data_t *dat = string_data(dup, (size_t)len + 1);
    if (dat == NULL) { smrt_deref(dup); return; }
    pthread_mutex_lock(&social_state.lock);
    map_set(&social_state.peer_proximity_map, (map_key_t)uuid_str, dat);
    pthread_mutex_unlock(&social_state.lock);
}

/* True iff we hold a CONNECTED edge toward @p uuid_str (Increment 5). Proximity
 * is only ever run against a peer both sides consented to connect with. */
static bool _proximity_peer_connected(const char *uuid_str)
{
    return identity_get_connection_state(uuid_str) == AT_CONN_CONNECTED;
}

/* Compute this node's proximity tag set toward @p peer under @p salt, from our
 * opt-in exact position and the pairwise box secret (beforenm over our X25519
 * secret and the peer's public key). Returns false if we opted out (no exact
 * position) or key/tag derivation fails. The exact position never leaves here. */
static bool _proximity_own_tags(const process_t *proc,
                                const public_identity_t *peer,
                                const unsigned char salt[AT_PROX_SALT_LEN],
                                uint8_t tags[AT_PROX_NTAGS][AT_PROX_TAG_LEN])
{
    double lat, lon;
    bool have;
    pthread_mutex_lock(&social_state.lock);
    have = social_state.own_exact_set;
    lat = social_state.own_exact_lat;
    lon = social_state.own_exact_lon;
    pthread_mutex_unlock(&social_state.lock);
    if (!have)
        return false;
    const identity_t *self = identity_self_identity(proc);
    if (self == NULL)
        return false;
    log_debug(proc->logger,
              "Identity: proximity tags from own position lat=%.5f lon=%.5f\n",
              lat, lon);
    unsigned char key[crypto_box_BEFORENMBYTES];
    if (!proximity_derive_key(peer->encryptor.public, self->encryptor.private,
                              key))
        return false;
    bool ok = proximity_compute_tags(lat, lon, key, salt, tags);
    sodium_memzero(key, sizeof(key));
    return ok;
}

/* Send a directed, ENCRYPTED proximity message ({salt, tags}) to @p peer under
 * @p verb (ID_PROXIMITY_PROBE or ID_PROXIMITY_REPLY). */
static int _send_proximity_msg(const public_identity_t *peer, char *verb,
                               const unsigned char salt[AT_PROX_SALT_LEN],
                               const uint8_t tags[AT_PROX_NTAGS][AT_PROX_TAG_LEN])
{
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    char salt_hex[AT_PROX_SALT_LEN * 2 + 1];
    sodium_bin2hex(salt_hex, sizeof(salt_hex), salt, AT_PROX_SALT_LEN);
    json_object_set_new(env, "salt", json_string(salt_hex));
    json_t *tarr = proximity_tags_to_json(tags);
    if (tarr == NULL) {
        json_decref(env);
        return -1;
    }
    json_object_set_new(env, "tags", tarr);

    generic_msg_t m = {0};
    m.type = NET_MESSAGE;
    strncpy(m.info.net_msg.process, "identity", PROC_NAME_LEN);
    m.info.net_msg.function = verb;
    m.info.net_msg.encrypt = true;
    memcpy(&m.info.net_msg.to_whom, peer, sizeof(public_identity_t));
    strncpy(m.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    net_msg_pack_json(&m.info.net_msg, env);
    json_decref(env);
    messaging_send("network", NET_MESSAGE, &m, false);
    return 0;
}

/* Parse {salt, tags} from a probe/reply payload. Returns true on a well-formed
 * message, filling @p salt and @p their_tags. */
static bool _proximity_parse(const json_t *payload,
                             unsigned char salt[AT_PROX_SALT_LEN],
                             uint8_t their_tags[AT_PROX_NTAGS][AT_PROX_TAG_LEN])
{
    json_t *j_salt = json_object_get(payload, "salt");
    json_t *j_tags = json_object_get(payload, "tags");
    if (!json_is_string(j_salt))
        return false;
    const char *hex = json_string_value(j_salt);
    size_t sl = 0;
    if (sodium_hex2bin(salt, AT_PROX_SALT_LEN, hex, strlen(hex), NULL, &sl,
                       NULL) != 0 || sl != AT_PROX_SALT_LEN)
        return false;
    return proximity_tags_from_json(j_tags, their_tags);
}

/* App -> AT verb (AT_APP_SET_EXACT_POSITION): set or clear THIS node's opt-in
 * EXACT position. Payload {"lat": <deg>, "lon": <deg>}; empty/missing/invalid
 * clears it (opt out). Stored LOCAL-ONLY — nothing reads it but the proximity
 * probe, and nothing advertises it. */
static bool handle_set_exact_position(const process_t *proc,
                                      directory_t *queues, generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    bool set = false;
    double lat = 0, lon = 0;
    if (net_msg_unpack_json(nmsg, &payload) == 0 && payload != NULL) {
        json_t *jlat = json_object_get(payload, "lat");
        json_t *jlon = json_object_get(payload, "lon");
        if (json_is_number(jlat) && json_is_number(jlon)) {
            lat = json_number_value(jlat);
            lon = json_number_value(jlon);
            if (lat >= -90.0 && lat <= 90.0 && lon >= -180.0 && lon <= 180.0)
                set = true;
        }
        json_decref(payload);
    }
    pthread_mutex_lock(&social_state.lock);
    social_state.own_exact_set = set;
    social_state.own_exact_lat = set ? lat : 0.0;
    social_state.own_exact_lon = set ? lon : 0.0;
    pthread_mutex_unlock(&social_state.lock);
    if (set)
        log_info(proc->logger,
                 "Identity: own exact position set (opted in, local-only): "
                 "lat=%.5f lon=%.5f\n", lat, lon);
    else
        log_info(proc->logger,
                 "Identity: own exact position cleared (opted out)\n");
    return true;
}

/* App -> AT verb (AT_APP_REQUEST_PROXIMITY): run a private-proximity probe
 * against a CONNECTED peer. Payload {"peer": "<uuid_str>"}. Derive our tags and
 * send an encrypted probe; the reply drives the band emit on both sides. */
static bool handle_request_proximity(const process_t *proc, directory_t *queues,
                                     generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_peer = json_object_get(payload, "peer");
    if (!json_is_string(j_peer)) { json_decref(payload); return true; }
    uuid_t peer_uuid;
    int rc = uuid_parse(json_string_value(j_peer), peer_uuid);
    json_decref(payload);
    if (rc != 0)
        return true;
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer_uuid, peer_str);
    if (!_proximity_peer_connected(peer_str)) {
        log_warn(proc->logger,
                 "Identity: request_proximity: %s not connected; refusing\n",
                 peer_str);
        return true;
    }
    public_identity_t peer;
    if (!identity_find_peer_pub(proc, peer_uuid, &peer))
        return true;
    unsigned char salt[AT_PROX_SALT_LEN];
    randombytes_buf(salt, sizeof(salt));
    uint8_t tags[AT_PROX_NTAGS][AT_PROX_TAG_LEN];
    if (!_proximity_own_tags(proc, &peer, salt, tags)) {
        log_info(proc->logger,
                 "Identity: request_proximity: no own exact position; opted out\n");
        return true;
    }
    _send_proximity_msg(&peer, ID_PROXIMITY_PROBE, salt, tags);
    log_debug(proc->logger, "Identity: sent proximity probe to %s\n", peer_str);
    return true;
}

/* Handler (responder): a connected peer's proximity probe. Compute our band
 * from our tags + theirs under the probe's salt, emit it locally, and reply
 * with our tags so the initiator learns the same band. */
static bool handle_proximity_probe(const process_t *proc, directory_t *queues,
                                   generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    char sender[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, sender);
    if (!_proximity_peer_connected(sender)) {
        log_debug(proc->logger,
                  "Identity: proximity_probe from non-connected %s; ignoring\n",
                  sender);
        return true;
    }
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    unsigned char salt[AT_PROX_SALT_LEN];
    uint8_t their_tags[AT_PROX_NTAGS][AT_PROX_TAG_LEN];
    bool ok = _proximity_parse(payload, salt, their_tags);
    json_decref(payload);
    if (!ok) {
        log_warn(proc->logger, "Identity: malformed proximity_probe from %s\n",
                 sender);
        return true;
    }
    uint8_t our_tags[AT_PROX_NTAGS][AT_PROX_TAG_LEN];
    if (!_proximity_own_tags(proc, &nmsg->from_whom, salt, our_tags)) {
        /* We opted out of exact position — we cannot compute a band. Surface
         * unknown for our side; do not reply (nothing to compare against). */
        _proximity_store(sender, AT_PROX_UNKNOWN);
        identity_emit_peer_proximity(nmsg->from_whom.uuid, AT_PROX_UNKNOWN);
        return true;
    }
    at_prox_band_t band = proximity_band(our_tags, their_tags);
    _proximity_store(sender, (int)band);
    identity_emit_peer_proximity(nmsg->from_whom.uuid, (int)band);
    _send_proximity_msg(&nmsg->from_whom, ID_PROXIMITY_REPLY, salt, our_tags);
    log_debug(proc->logger, "Identity: proximity band %d with %s (probe)\n",
              (int)band, sender);
    return true;
}

/* Handler (initiator): the reply to our probe. Recompute our tags under the
 * (echoed) salt, compare with theirs, emit the band. */
static bool handle_proximity_reply(const process_t *proc, directory_t *queues,
                                   generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    char sender[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, sender);
    if (!_proximity_peer_connected(sender))
        return true;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    unsigned char salt[AT_PROX_SALT_LEN];
    uint8_t their_tags[AT_PROX_NTAGS][AT_PROX_TAG_LEN];
    bool ok = _proximity_parse(payload, salt, their_tags);
    json_decref(payload);
    if (!ok) {
        log_warn(proc->logger, "Identity: malformed proximity_reply from %s\n",
                 sender);
        return true;
    }
    uint8_t our_tags[AT_PROX_NTAGS][AT_PROX_TAG_LEN];
    if (!_proximity_own_tags(proc, &nmsg->from_whom, salt, our_tags)) {
        _proximity_store(sender, AT_PROX_UNKNOWN);
        identity_emit_peer_proximity(nmsg->from_whom.uuid, AT_PROX_UNKNOWN);
        return true;
    }
    at_prox_band_t band = proximity_band(our_tags, their_tags);
    _proximity_store(sender, (int)band);
    identity_emit_peer_proximity(nmsg->from_whom.uuid, (int)band);
    log_debug(proc->logger, "Identity: proximity band %d with %s (reply)\n",
              (int)band, sender);
    return true;
}

/* Emit the stored position for every known peer — the roster-pull answer for
 * the position half. Snapshot peer uuids under peers_read_lock, look each up in
 * peer_position_map, emit outside the peers lock. Returns count emitted. */
static int identity_emit_all_positions(const process_t *proc)
{
    if (proc == NULL) return 0;
    uuid_t uuids[DEFAULT_MAX_PEERS];
    peers_read_lock(proc);
    size_t n = proc->protocol.num_peers;
    if (n > DEFAULT_MAX_PEERS) n = DEFAULT_MAX_PEERS;
    for (size_t i = 0; i < n; i++)
        memcpy(uuids[i], proc->protocol.peers[i].uuid, sizeof(uuid_t));
    peers_read_unlock(proc);

    int emitted = 0;
    for (size_t i = 0; i < n; i++) {
        char uuid_str[UUID_STRING_LEN + 1];
        uuid_unparse_lower(uuids[i], uuid_str);
        char geo[AT_GEOHASH_MAX_LEN + 1] = {0};
        pthread_mutex_lock(&social_state.lock);
        data_t *dat = NULL;
        if (map_get(&social_state.peer_position_map, uuid_str, &dat) == 0 && dat != NULL) {
            char *g = NULL;
            if (data_string_ptr(dat, &g) == 0 && g != NULL)
                snprintf(geo, sizeof(geo), "%s", g);
        }
        pthread_mutex_unlock(&social_state.lock);
        if (geo[0] != '\0' && identity_emit_peer_position(uuids[i], geo) == 0)
            emitted++;
    }
    return emitted;
}

/****************************
 * Opt-in agora.profile (Increment 3, the "who is this peer" surface).
 *
 * Same directed shape as the position exchange, with one addition: the
 * response carries a DETACHED Ed25519 SIGNATURE over a canonical serialization
 * of the profile (social/profile.c), so a profile is self-verifying beyond
 * the transport. STRICTLY OPT-IN: own_profile is empty by default and while
 * empty handle_profile_query answers nothing. On receive the profile is
 * bound-validated (a misbehaving peer's over-bound field is dropped, like an
 * invalid geohash) and its signature verified against the SENDER's signing key
 * before anything is stored or surfaced. The app-boundary form is the compact
 * field JSON only — the signature, already verified here, does not cross.
 ****************************/

/* AT -> app: surface one peer's profile (compact JSON) as PEER_PROFILE_OBSERVED.
 * Mirrors identity_emit_peer_position. @p profile_json "" is valid. */
static int identity_emit_peer_profile(const uuid_t peer_uuid, const char *profile_json)
{
    generic_msg_t msg = {0};
    msg.type = PEER_PROFILE_OBSERVED;
    peer_profile_msg_t *ext = AT_MSG_EXT(&msg, peer_profile_msg_t);
    msg.size = sizeof(peer_profile_msg_t);
    memcpy(ext->peer_uuid, peer_uuid, 16);
    if (profile_json != NULL)
        snprintf(ext->profile_json,
                 sizeof(ext->profile_json), "%s", profile_json);
    return messaging_send(AT_MAIN_QUEUE, PEER_PROFILE_OBSERVED, &msg, false);
}

/* Handler: a peer asks for our profile. Opted out (empty own_profile) => answer
 * NOTHING. Otherwise reply directed + encrypted with {"profile","sig","seq"},
 * the signature computed fresh from our identity key over the canonical form. */
static bool handle_profile_query(const process_t *proc, directory_t *queues, generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;

    at_profile_t own;
    pthread_mutex_lock(&social_state.lock);
    memcpy(&own, &social_state.own_profile, sizeof(own));
    pthread_mutex_unlock(&social_state.lock);
    if (at_profile_is_empty(&own)) {
        log_debug(proc->logger,
                  "Identity: profile_query from %s; opted out, no answer\n",
                  nmsg->from_whom.nickname);
        return true;
    }

    const identity_t *self = identity_self_identity(proc);
    if (self == NULL) {
        log_debug(proc->logger,
                  "Identity: profile_query but self identity unresolved; skipping\n");
        return true;   /* bootstrap incomplete: cannot sign yet */
    }
    char sig_hex[AT_PROFILE_SIG_HEX_LEN + 1];
    if (at_profile_sign(self->signature.private, self->uuid, &own, sig_hex) != 0) {
        log_warn(proc->logger, "Identity: profile_query: signing failed\n");
        return true;
    }

    int64_t seq = identity_freshness_stamp(proc->logger);
    if (seq <= 0) {
        log_warn(proc->logger,
                 "Identity: no freshness sequence; not answering profile query\n");
        return true;
    }

    generic_msg_t response = {0};
    response.type = NET_MESSAGE;
    strncpy(response.info.net_msg.process, "identity", PROC_NAME_LEN);
    response.info.net_msg.function = ID_PROFILE_RESPONSE;
    response.info.net_msg.encrypt = true;
    memcpy(&response.info.net_msg.to_whom, &nmsg->from_whom,
           sizeof(public_identity_t));
    strncpy(response.info.net_msg.return_to, "identity", PROC_NAME_LEN);

    json_t *env = json_object();
    if (env == NULL) return true;
    json_t *prof = at_profile_to_json(&own);
    if (prof == NULL) { json_decref(env); return true; }
    json_object_set_new(env, "profile", prof);
    json_object_set_new(env, "sig", json_string(sig_hex));
    json_object_set_new(env, "seq", json_integer((json_int_t)seq));
    net_msg_pack_json(&response.info.net_msg, env);
    json_decref(env);
    messaging_send("network", NET_MESSAGE, &response, false);
    return true;
}

/* Handler: store a peer's profile from a {"profile","sig","seq"} response —
 * freshness-checked, bound-validated, and SIGNATURE-verified against the
 * sender's signing key — then surface it to the app. */
static bool handle_profile_response(const process_t *proc, directory_t *queues, generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;

    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_prof = json_object_get(payload, "profile");
    json_t *j_sig  = json_object_get(payload, "sig");
    json_t *j_seq  = json_object_get(payload, "seq");
    if (!json_is_object(j_prof) || !json_is_string(j_sig) || !json_is_integer(j_seq)) {
        json_decref(payload);
        log_warn(proc->logger,
                 "Identity: profile_response unstamped/malformed, refusing\n");
        return true;
    }

    char sender[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, sender);
    int64_t seq = (int64_t)json_integer_value(j_seq);
    bool fresh = identity_freshness_accept(sender, ID_PROFILE_RESPONSE, seq,
                                           proc->logger);
    if (!fresh) {
        json_decref(payload);
        log_debug(proc->logger,
                  "Identity: profile_response from %s refused (replay)\n", sender);
        return true;
    }

    at_profile_t p;
    if (at_profile_from_json(j_prof, true, &p) != 0) {
        json_decref(payload);
        log_warn(proc->logger,
                 "Identity: profile_response from %s: over-bound/invalid field, dropping\n",
                 sender);
        return true;
    }
    if (!at_profile_verify(nmsg->from_whom.signature.public, nmsg->from_whom.uuid,
                           &p, json_string_value(j_sig))) {
        json_decref(payload);
        log_warn(proc->logger,
                 "Identity: profile_response from %s: BAD SIGNATURE, dropping\n",
                 sender);
        return true;
    }
    json_decref(payload);

    char compact[AT_PROFILE_JSON_MAX + 1];
    if (at_profile_to_compact_str(&p, compact, sizeof(compact)) < 0)
        return true;
    size_t len = strlen(compact);
    char *dup = smrt_create(len + 1);
    if (dup == NULL) return true;
    memcpy(dup, compact, len + 1);
    data_t *prof_dat = string_data(dup, len + 1);
    if (prof_dat == NULL) { smrt_deref(dup); return true; }
    pthread_mutex_lock(&social_state.lock);
    map_set(&social_state.peer_profile_map, sender, prof_dat);
    pthread_mutex_unlock(&social_state.lock);

    identity_emit_peer_profile(nmsg->from_whom.uuid, compact);
    log_debug(proc->logger, "Identity: recorded profile for peer %s\n", sender);
    return true;
}

/* App -> AT verb (AT_APP_SET_PROFILE): set or clear THIS node's opt-in profile.
 * Payload is the profile object itself ({display_name, handle, bio, avatar_ref,
 * links}); an empty/missing object clears it (opt out). Locally-trusted input,
 * so fields are truncated (validate=false) rather than rejected. */
static bool handle_set_profile(const process_t *proc, directory_t *queues, generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    at_profile_t p;
    memset(&p, 0, sizeof(p));
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) == 0 && payload != NULL) {
        at_profile_from_json(payload, false, &p);   /* empty/invalid => cleared */
        json_decref(payload);
    }
    pthread_mutex_lock(&social_state.lock);
    memcpy(&social_state.own_profile, &p, sizeof(p));
    pthread_mutex_unlock(&social_state.lock);
    log_info(proc->logger, "Identity: own profile %s\n",
             at_profile_is_empty(&p) ? "cleared (opted out)" : "set (opted in)");
    return true;
}

/* Directed profile query to one admitted peer (mirrors _send_position_query). */
static int _send_profile_query(const process_t *proc, const public_identity_t *peer)
{
    generic_msg_t query = {0};
    query.type = NET_MESSAGE;
    strncpy(query.info.net_msg.process, "identity", PROC_NAME_LEN);
    query.info.net_msg.function = ID_PROFILE_QUERY;
    query.info.net_msg.encrypt = true;
    memcpy(&query.info.net_msg.to_whom, peer, sizeof(public_identity_t));
    strncpy(query.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    messaging_send("network", NET_MESSAGE, &query, false);
    log_debug(proc->logger, "Identity: sent profile_query to %s\n", peer->nickname);
    return 0;
}

/* Emit the stored profile for every known peer — the roster-pull answer for the
 * profile half. Mirrors identity_emit_all_positions. Returns count emitted. */
static int identity_emit_all_profiles(const process_t *proc)
{
    if (proc == NULL) return 0;
    uuid_t uuids[DEFAULT_MAX_PEERS];
    peers_read_lock(proc);
    size_t n = proc->protocol.num_peers;
    if (n > DEFAULT_MAX_PEERS) n = DEFAULT_MAX_PEERS;
    for (size_t i = 0; i < n; i++)
        memcpy(uuids[i], proc->protocol.peers[i].uuid, sizeof(uuid_t));
    peers_read_unlock(proc);

    int emitted = 0;
    for (size_t i = 0; i < n; i++) {
        char uuid_str[UUID_STRING_LEN + 1];
        uuid_unparse_lower(uuids[i], uuid_str);
        char compact[AT_PROFILE_JSON_MAX + 1] = {0};
        pthread_mutex_lock(&social_state.lock);
        data_t *dat = NULL;
        if (map_get(&social_state.peer_profile_map, uuid_str, &dat) == 0 && dat != NULL) {
            char *g = NULL;
            if (data_string_ptr(dat, &g) == 0 && g != NULL)
                snprintf(compact, sizeof(compact), "%s", g);
        }
        pthread_mutex_unlock(&social_state.lock);
        if (compact[0] != '\0' && identity_emit_peer_profile(uuids[i], compact) == 0)
            emitted++;
    }
    return emitted;
}

/****************************
 * Explicit connections (Increment 5, the "connect with this peer" surface).
 *
 * A connection is an EXPLICIT, revocable, bilateral edge kept SEPARATE from
 * reputation. USER-INITIATED: nothing is auto-sent on admission (unlike the
 * position/profile queries) — the app's CONNECT verb starts it. The request is
 * a bare directed encrypted ask; the response carries a detached Ed25519
 * SIGNATURE over the canonical (requester, accepter, decision, seq) form
 * (social/connection.c), freshness-stamped so a captured accept cannot be
 * replayed. States: none/pending_out/pending_in/connected/declined.
 ****************************/

/* AT -> app: surface a connection edge event. @p type is
 * PEER_CONNECTION_REQUEST_OBSERVED (inbound ask) or
 * PEER_CONNECTION_STATE_OBSERVED (any transition). */
static int identity_emit_connection(message_type_t type, const uuid_t peer_uuid,
                                    int state)
{
    generic_msg_t msg = {0};
    msg.type = type;
    msg.size = sizeof(peer_connection_msg_t);
    peer_connection_msg_t *ext = AT_MSG_EXT(&msg, peer_connection_msg_t);
    memcpy(ext->peer_uuid, peer_uuid, 16);
    ext->state = state;
    return messaging_send(AT_MAIN_QUEUE, type, &msg, false);
}

/* Record that peer @p peer_uuid_str advertised group @p group_uuid_str, stored
 * as "<their group>|<OUR group at record time>" (handle_group_update, BEFORE any
 * adopt this same update triggers). Capturing our own uuid is what makes the
 * signal robust to the symmetric-swap split-brain: when we later adopt a group
 * (our uuid changes), the second field no longer matches our current uuid, so
 * the stale record stops counting as co-membership until the peer re-advertises.
 * Own locking. See social_state.peer_group_uuids. */
static void _record_peer_group_uuid(const process_t *proc,
                                    const char *peer_uuid_str,
                                    const char *group_uuid_str)
{
    if (proc == NULL || peer_uuid_str == NULL || group_uuid_str == NULL) return;
    char ours[UUID_STRING_LEN + 1];
    uuid_unparse_lower(proc->protocol.group.uuid, ours);
    char buf[2 * UUID_STRING_LEN + 2];
    int len = snprintf(buf, sizeof(buf), "%s|%s", group_uuid_str, ours);
    if (len <= 0 || (size_t)len >= sizeof(buf)) return;
    char *dup = smrt_create((size_t)len + 1);
    if (dup == NULL) return;
    memcpy(dup, buf, (size_t)len + 1);
    data_t *dat = string_data(dup, (size_t)len + 1);
    if (dat == NULL) { smrt_deref(dup); return; }
    pthread_mutex_lock(&social_state.lock);
    map_set(&social_state.peer_group_uuids, (map_key_t)peer_uuid_str, dat);
    pthread_mutex_unlock(&social_state.lock);
}

/* True iff peer @p peer_uuid_str last advertised the SAME group uuid this node
 * currently holds AND we have not changed our own group since (both halves of
 * the stored "their|ours-at-record" must equal our current uuid). This is the
 * sound "in your group" signal: address membership is true from the mesh merge
 * on, and a bare their==ours match is fooled by the mutual-adopt swap (each side
 * records the other's PRE-swap uuid, which equals its own POST-adopt uuid). */
static bool _peer_shares_our_group(const process_t *proc, const char *peer_uuid_str)
{
    if (proc == NULL || peer_uuid_str == NULL) return false;
    char current[UUID_STRING_LEN + 1];
    uuid_unparse_lower(proc->protocol.group.uuid, current);
    bool same = false;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.peer_group_uuids, (map_key_t)peer_uuid_str, &dat) == 0
        && dat != NULL) {
        char *s = NULL;
        if (data_string_ptr(dat, &s) == 0 && s != NULL) {
            const char *bar = strchr(s, '|');
            if (bar != NULL) {
                size_t their_len = (size_t)(bar - s);
                const char *our_rec = bar + 1;
                same = (their_len == strlen(current)
                        && strncmp(s, current, their_len) == 0
                        && strcmp(our_rec, current) == 0);
            }
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return same;
}

/* Record our edge state toward peer @p uuid_str as compact JSON
 * {"state","seq","ts"} (string_data, like peer_profile_map). Own locking.
 * Returns 0 on success. */
static int _connection_store(const char *uuid_str, int state, uint64_t seq)
{
    char buf[96];
    int len = snprintf(buf, sizeof(buf),
                       "{\"state\":%d,\"seq\":%llu,\"ts\":%lld}",
                       state, (unsigned long long)seq, (long long)time(NULL));
    if (len <= 0 || (size_t)len >= sizeof(buf)) return -1;
    char *dup = smrt_create((size_t)len + 1);
    if (dup == NULL) return -1;
    memcpy(dup, buf, (size_t)len + 1);
    data_t *dat = string_data(dup, (size_t)len + 1);
    if (dat == NULL) { smrt_deref(dup); return -1; }
    pthread_mutex_lock(&social_state.lock);
    map_set(&social_state.connection_edges, (map_key_t)uuid_str, dat);
    pthread_mutex_unlock(&social_state.lock);
    return 0;
}

/**************** Increment 8: social-interaction reputation accrual ****************
 * A qualifying social interaction submits a diminishing-returns score into the
 * SAME bilateral transaction the counterparty submits into (shared task_uuid), so
 * a commit — and the reputation move it carries — happens only when both peers
 * actually take part. See social/social_tx.h for the model. The reputation
 * process owns Paxos + the earned-score algebra; here we only stage our half.
 ***********************************************************************************/

/* Stage OUR half of a bilateral social transaction: send a TRANSACTION_SCORE to
 * the reputation process for @p task_uuid, about subject @p subject (the peer this
 * score concerns). @p channel is one of TX_CHANNEL_*, or NULL for absent, which
 * the reputation process normalizes to TX_CHANNEL_TASK_OUTCOME; competence 0
 * means the authored weight verbatim. Mirrors
 * negotiation/neg_proc.c:_submit_tx_score. */
static void _submit_interaction_score(const process_t *proc,
                                      const uuid_t task_uuid, double score,
                                      const uuid_t subject, const char *channel)
{
    generic_msg_t msg = {0};
    msg.type = TRANSACTION_SCORE;
    msg.size = sizeof(tx_score_msg_t);
    uuid_copy(msg.info.tx_score.task_uuid, task_uuid);
    if (subject != NULL)
        uuid_copy(msg.info.tx_score.peer_uuid, subject);
    msg.info.tx_score.score = score;
    /* competence stays zeroed -> weight 1.0, resolved in the reputation
     * process. The channel is copied only when given; zeroed is how "absent"
     * is spelled on this struct. */
    if (channel != NULL)
        at_strlcpy(msg.info.tx_score.channel, channel,
                   sizeof(msg.info.tx_score.channel));
    /* Retried, and kept past a long burst, as identity_send_to does for every
     * one-shot (AT ISSUES §2.40). The moderation cohort (run 8, 2026-09-23)
     * lost ada's half of a report here: her reputation queue was full of
     * catch-up traffic, one EAGAIN dropped the score, and the report went out
     * anyway, so bob staged a half that could never pair. */
    char what[48];
    snprintf(what, sizeof(what), "social score %.3f", score);
    (void)identity_send_to(proc, "reputation", &msg, what, "reputation");

    /* Record the staged score as the conformance/observability surface — the
     * deterministic thing a scenario asserts, independent of the Paxos round. */
    if (subject != NULL) {
        char subj[UUID_STRING_LEN + 1];
        char task_hex[UUID_STRING_LEN + 1];
        uuid_unparse_lower(subject, subj);
        uuid_unparse_lower(task_uuid, task_hex);
        pthread_mutex_lock(&social_state.lock);
        int n = 0;
        data_t *prev = NULL;
        if (map_get(&social_state.social_tx_observed, (map_key_t)subj, &prev) == 0
            && prev != NULL) {
            char *ps = NULL;
            if (data_string_ptr(prev, &ps) == 0 && ps != NULL) {
                json_error_t jerr;
                json_t *po = json_loads(ps, 0, &jerr);
                if (po != NULL) {
                    json_t *jn = json_object_get(po, "n");
                    if (json_is_integer(jn))
                        n = (int)json_integer_value(jn);
                    json_decref(po);
                }
            }
        }
        char buf[192];
        int len = snprintf(buf, sizeof(buf),
                           "{\"task\":\"%s\",\"score\":%.6f,\"channel\":\"%s\","
                           "\"n\":%d}",
                           task_hex, score,
                           channel != NULL ? channel : TX_CHANNEL_DEFAULT, n + 1);
        if (len > 0 && (size_t)len < sizeof(buf)) {
            char *dup = smrt_create((size_t)len + 1);
            if (dup != NULL) {
                memcpy(dup, buf, (size_t)len + 1);
                data_t *dat = string_data(dup, (size_t)len + 1);
                if (dat != NULL)
                    map_set(&social_state.social_tx_observed, (map_key_t)subj, dat);
                else
                    smrt_deref(dup);
            }
        }
        pthread_mutex_unlock(&social_state.lock);
    }
}

/* Conformance seam: the last interaction score this node staged ABOUT peer
 * @p uuid_str (lowercased subject uuid). Copies the task_uuid hex into @p task_out
 * (>= 37 bytes) and the score into @p score_out when non-NULL. Returns true iff a
 * staged score is recorded. Twin of Python IdentityProcess.get_last_social_tx. */
bool identity_get_last_social_tx(const char *uuid_str, char *task_out,
                                 double *score_out)
{
    if (uuid_str == NULL) return false;
    bool found = false;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.social_tx_observed, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL) {
        char *s = NULL;
        if (data_string_ptr(dat, &s) == 0 && s != NULL) {
            json_error_t jerr;
            json_t *o = json_loads(s, 0, &jerr);
            if (o != NULL) {
                json_t *jt = json_object_get(o, "task");
                json_t *js = json_object_get(o, "score");
                if (json_is_string(jt) && task_out != NULL)
                    snprintf(task_out, 37, "%s", json_string_value(jt));
                if (json_is_number(js) && score_out != NULL)
                    *score_out = json_number_value(js);
                found = true;
                json_decref(o);
            }
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return found;
}

bool identity_get_social_tx_detail(const char *uuid_str, char *channel_out,
                                   size_t channel_len, int *n_out)
{
    if (uuid_str == NULL) return false;
    bool found = false;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.social_tx_observed, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL) {
        char *s = NULL;
        if (data_string_ptr(dat, &s) == 0 && s != NULL) {
            json_error_t jerr;
            json_t *o = json_loads(s, 0, &jerr);
            if (o != NULL) {
                json_t *jc = json_object_get(o, "channel");
                json_t *jn = json_object_get(o, "n");
                if (channel_out != NULL && channel_len > 0)
                    snprintf(channel_out, channel_len, "%s",
                             json_is_string(jc) ? json_string_value(jc) : "");
                if (n_out != NULL)
                    *n_out = json_is_integer(jn) ? (int)json_integer_value(jn) : 0;
                found = true;
                json_decref(o);
            }
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return found;
}

/* Conformance/test seam: locally block @p uuid_str (lowercased peer uuid),
 * writing the same social_blocks record handle_app_block does but callable
 * without assembling an app message. identity_get_peer_tier then clamps this
 * peer to 0. Purely local — no wire traffic, no reputation transaction. Twin of
 * Python IdentityProcess.block_peer. */
/* Write the block set to etc/at/social.cfg.json (Phase 4 P4.1).
 *
 * ON EVERY MUTATION, not at shutdown: the C identity process has no
 * tail-of-loop flush (the Python SIGTERM path persistent-cohort.md describes
 * has no C twin), and a block that survives only a graceful stop is not much of
 * a block. Failure is logged, never fatal — losing durability must not take
 * moderation itself down, and the operator needs to know the file is not being
 * written rather than discovering it after a restart. */
static void _persist_social_blocks(void)
{
    char cfg_dir[CFG_PATH_LEN + 1];
    if (get_cfg_dir(cfg_dir, sizeof(cfg_dir)) <= 0)
        return;
    pthread_mutex_lock(&social_state.lock);
    /* The blocks AND the followed communities: one document, so saving either
     * must write both, or a block would forget every follow. */
    int rc = social_store_save_all(&social_state.social_blocks,
                                   &social_state.communities, cfg_dir);
    pthread_mutex_unlock(&social_state.lock);
    if (rc != 0)
        log_warn(NULL, "Identity: could not persist social blocks to %s/%s\n",
                 cfg_dir, AT_SOCIAL_FILENAME);
}

void identity_block_peer(const char *uuid_str)
{
    if (uuid_str == NULL) return;
    /* The value is WHEN, not a flag: "blocked" is the presence of the key, so
     * the value is free to carry something the store can write back. A double
     * rather than an int so the epoch does not meet 2038. */
    data_t *when = floating_pt_dbl_data((double)time(NULL));
    if (when == NULL) return;
    pthread_mutex_lock(&social_state.lock);
    map_set(&social_state.social_blocks, (map_key_t)uuid_str, when);
    pthread_mutex_unlock(&social_state.lock);
    _persist_social_blocks();
}

/* Lift a local block (Phase 4 P4.1). A DELETE, not a second flag: "blocked"
 * is the presence of the key, so there is no way for the record and the
 * predicate to disagree, and re-blocking is idempotent.
 *
 * The peer is told nothing, exactly as they were told nothing about the block.
 * What they sent while blocked is gone — the inbound gates dropped it rather
 * than queueing it — so an unblock restores reach going forward and does not
 * replay the silence. */
void identity_unblock_peer(const char *uuid_str)
{
    if (uuid_str == NULL) return;
    pthread_mutex_lock(&social_state.lock);
    map_remove(&social_state.social_blocks, (map_key_t)uuid_str);
    pthread_mutex_unlock(&social_state.lock);
    _persist_social_blocks();
}

/* Conformance/test seam: save the block set and load it back, which is the
 * round trip a restart performs — without needing one.
 *
 * A restart is the thing that must not lose a block, but a conformance step
 * cannot restart a process, and a test that only checked the in-memory map
 * would pass with no file written at all. This drives the real writer and the
 * real reader. */
void identity_reload_social_blocks(const char *cfg_dir)
{
    char resolved[CFG_PATH_LEN + 1];
    if (cfg_dir == NULL) {
        if (get_cfg_dir(resolved, sizeof(resolved)) <= 0)
            return;
        cfg_dir = resolved;
    }
    pthread_mutex_lock(&social_state.lock);
    /* IF THE SAVE FAILED, DO NOT LOAD. social_store_load REPLACES the map, so
     * a failed write followed by a read of the file that is not there would
     * empty the block set — turning an unwritable config directory into a
     * silent mass unblock. Found by this seam wiping state in the conformance
     * harness, where the default root is /etc/at and nothing may be written;
     * the same shape would bite a real node with a read-only config mount. */
    int rc = social_store_save_all(&social_state.social_blocks,
                                   &social_state.communities, cfg_dir);
    if (rc == 0)
        (void)social_store_load_all(cfg_dir, &social_state.social_blocks,
                                    &social_state.communities);
    pthread_mutex_unlock(&social_state.lock);
}

/* Conformance/observability read-back: is @p uuid_str locally blocked? */
bool identity_is_blocked(const char *uuid_str)
{
    if (!social_state.initialized || uuid_str == NULL) return false;
    pthread_mutex_lock(&social_state.lock);
    bool blocked = _is_blocked_locked(uuid_str);
    pthread_mutex_unlock(&social_state.lock);
    return blocked;
}

/* Read the per-edge accrual record for @p uuid_str; absent => all zeros. Caller
 * MUST hold social_state.lock. */
static void _social_edge_get_locked(const char *uuid_str, int *count,
                                    long *last_out, long *last_in,
                                    int *day, int *day_count)
{
    *count = 0; *last_out = 0; *last_in = 0; *day = 0; *day_count = 0;
    data_t *dat = NULL;
    if (map_get(&social_state.social_edges, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL) {
        char *s = NULL;
        if (data_string_ptr(dat, &s) == 0 && s != NULL) {
            json_error_t jerr;
            json_t *o = json_loads(s, 0, &jerr);
            if (o != NULL) {
                json_t *j;
                if ((j = json_object_get(o, "count")) && json_is_integer(j))
                    *count = (int)json_integer_value(j);
                if ((j = json_object_get(o, "last_out")) && json_is_integer(j))
                    *last_out = (long)json_integer_value(j);
                if ((j = json_object_get(o, "last_in")) && json_is_integer(j))
                    *last_in = (long)json_integer_value(j);
                if ((j = json_object_get(o, "day")) && json_is_integer(j))
                    *day = (int)json_integer_value(j);
                if ((j = json_object_get(o, "day_count")) && json_is_integer(j))
                    *day_count = (int)json_integer_value(j);
                json_decref(o);
            }
        }
    }
}

/* Write the per-edge accrual record. Caller MUST hold social_state.lock. */
static int _social_edge_put_locked(const char *uuid_str, int count,
                                   long last_out, long last_in,
                                   int day, int day_count)
{
    char buf[128];
    int len = snprintf(buf, sizeof(buf),
                       "{\"count\":%d,\"last_out\":%ld,\"last_in\":%ld,"
                       "\"day\":%d,\"day_count\":%d}",
                       count, last_out, last_in, day, day_count);
    if (len <= 0 || (size_t)len >= sizeof(buf)) return -1;
    char *dup = smrt_create((size_t)len + 1);
    if (dup == NULL) return -1;
    memcpy(dup, buf, (size_t)len + 1);
    data_t *dat = string_data(dup, (size_t)len + 1);
    if (dat == NULL) { smrt_deref(dup); return -1; }
    map_set(&social_state.social_edges, (map_key_t)uuid_str, dat);
    return 0;
}

/* Stamp an interaction with peer @p uuid_str as having occurred now in the given
 * direction (inbound = they acted toward us). Updates only the recency clocks; the
 * accrual decision is separate (@ref _social_accrue). */
static void _social_stamp(const char *uuid_str, bool inbound, long now)
{
    pthread_mutex_lock(&social_state.lock);
    int count, day, dc; long lo, li;
    _social_edge_get_locked(uuid_str, &count, &lo, &li, &day, &dc);
    if (inbound) li = now; else lo = now;
    _social_edge_put_locked(uuid_str, count, lo, li, day, dc);
    pthread_mutex_unlock(&social_state.lock);
}

/* Decide whether to accrue positive reputation for an interaction with
 * @p uuid_str now, and if so bump the edge/daily counters and return the 1-based
 * interaction count to score with (via @p out_count). When @p require_bilateral is
 * true, accrual is refused unless BOTH directions were seen inside
 * AT_SOCIAL_RECENCY_WINDOW (the sustained-DM rule); connection accepts and post
 * reactions are structurally bilateral (the act itself makes both peers submit) and
 * pass false. Per-edge and global daily caps always apply. Returns true iff the
 * caller should submit S_pos(*out_count). */
static bool _social_accrue(const char *uuid_str, long now,
                           bool require_bilateral, int *out_count)
{
    bool ok = false;
    pthread_mutex_lock(&social_state.lock);
    /* A blocked peer accrues nothing with us (Phase 4 P4.1). Gated HERE rather
     * than at each caller because every positive path funnels through this
     * function, so one gate covers DMs, reactions and connections at once.
     *
     * Not merely tidiness: reputation here is BILATERAL, and our half can only
     * complete if the other side submits its own. We have told them nothing —
     * a block is purely local — so they have no reason to, and our submission
     * would sit in the chain as a permanent half-entry. That is the same
     * defect the 2026-09-21 cohort caught on the reaction path, arrived at
     * from the other direction. */
    if (_is_blocked_locked(uuid_str)) {
        pthread_mutex_unlock(&social_state.lock);
        return false;
    }
    int count, day, dc; long lo, li;
    _social_edge_get_locked(uuid_str, &count, &lo, &li, &day, &dc);

    bool recent = true;
    if (require_bilateral) {
        long win = (long)AT_SOCIAL_RECENCY_WINDOW;
        recent = (lo > 0 && li > 0 && (now - lo) < win && (now - li) < win);
    }
    if (recent) {
        int today = (int)(now / AT_SOCIAL_DAY_SECONDS);
        if (day != today) { day = today; dc = 0; }
        if (social_state.social_day != today) {
            social_state.social_day = today;
            social_state.social_day_count = 0;
        }
        if (dc < AT_SOCIAL_PER_EDGE_DAILY_CAP
            && social_state.social_day_count < AT_SOCIAL_GLOBAL_DAILY_CAP) {
            count++; dc++; social_state.social_day_count++;
            _social_edge_put_locked(uuid_str, count, lo, li, day, dc);
            *out_count = count;
            ok = true;
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return ok;
}

/* Accrue for a resolved connection between @p self_uuid and @p peer_uuid at the
 * shared signed @p seq. Both peers hold the identical {requester,accepter,decision,
 * seq} tuple, so the uuid-order-independent task_uuid pairs their two submissions
 * into one bilateral transaction. Connected => diminishing positive (structurally
 * bilateral, caps only); declined => the in-model bilateral negative. */
static void _social_accrue_connection(const process_t *proc,
                                      const uuid_t self_uuid,
                                      const uuid_t peer_uuid,
                                      uint64_t seq, bool connected)
{
    /* Gated separately from _social_accrue because the DECLINE branch below
     * bypasses it entirely and submits AT_SOCIAL_NEG_SCORE unconditionally.
     * Without this, blocking someone and then declining them would still cost
     * them 0.30 — a block must not become a way to grind a peer down, and the
     * submission could never pair anyway. */
    if (_is_blocked(peer_uuid))
        return;
    uuid_t task;
    uint8_t tail[8];
    for (int i = 0; i < 8; i++) tail[i] = (uint8_t)((seq >> (8 * i)) & 0xFF);
    if (at_social_task_uuid(AT_SOCIAL_DOMAIN_CONN, self_uuid, peer_uuid,
                            tail, sizeof(tail), task) != 0)
        return;
    if (connected) {
        long now = (long)time(NULL);
        int count = 0;
        char peer_str[UUID_STRING_LEN + 1];
        uuid_unparse_lower(peer_uuid, peer_str);
        if (_social_accrue(peer_str, now, false, &count))
            _submit_interaction_score(proc, task, at_social_pos_score(count),
                                      peer_uuid, NULL);
    } else {
        _submit_interaction_score(proc, task, AT_SOCIAL_NEG_SCORE, peer_uuid, NULL);
    }
}

/* Record a DM interaction with @p peer_uuid (inbound = received from them) and, if
 * the edge is now bilaterally recent, accrue. Unlike a connection, a single DM is
 * one-directional, so accrual is gated on BOTH directions inside the recency
 * window (the "sustained exchange" rule). Both peers key the transaction to the
 * same hourly bucket, so their scores pair when they exchange within one hour. */
static void _social_accrue_dm(const process_t *proc, const uuid_t peer_uuid,
                              bool inbound)
{
    const identity_t *self = identity_self_identity(proc);
    if (self == NULL) return;
    long now = (long)time(NULL);
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer_uuid, peer_str);
    _social_stamp(peer_str, inbound, now);

    uint64_t bucket = (uint64_t)(now / AT_SOCIAL_DM_BUCKET_SECONDS);
    uint8_t tail[8];
    for (int i = 0; i < 8; i++) tail[i] = (uint8_t)((bucket >> (8 * i)) & 0xFF);
    uuid_t task;
    if (at_social_task_uuid(AT_SOCIAL_DOMAIN_DM, self->uuid, peer_uuid,
                            tail, sizeof(tail), task) != 0)
        return;
    int count = 0;
    if (_social_accrue(peer_str, now, true, &count))
        _submit_interaction_score(proc, task, at_social_pos_score(count),
                                  peer_uuid, NULL);
}

/* Accrue for a post reaction between @p self_uuid and the counterparty
 * @p peer_uuid over the post @p post_id_hex. Both the reactor (on send) and the
 * author (on receipt) call this with the same two uuids and the same content id,
 * so the order-independent task pairs their submissions. A reaction is
 * structurally bilateral (the message itself makes both submit), so no recency
 * gate — caps only. */
static void _social_accrue_reaction(const process_t *proc, const uuid_t self_uuid,
                                    const uuid_t peer_uuid, const char *post_id_hex)
{
    if (post_id_hex == NULL) return;
    unsigned char id_bin[16];
    size_t binlen = 0;
    /* First 16 bytes of the 64-hex content id bind the task. */
    if (sodium_hex2bin(id_bin, sizeof(id_bin), post_id_hex, 32,
                       NULL, &binlen, NULL) != 0 || binlen != sizeof(id_bin))
        return;
    uuid_t task;
    if (at_social_task_uuid(AT_SOCIAL_DOMAIN_POST, self_uuid, peer_uuid,
                            id_bin, sizeof(id_bin), task) != 0)
        return;
    long now = (long)time(NULL);
    int count = 0;
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer_uuid, peer_str);
    if (_social_accrue(peer_str, now, false, &count))
        _submit_interaction_score(proc, task, at_social_pos_score(count),
                                  peer_uuid, NULL);
}

/* Copy the current public_identity_t of the admitted peer with @p uuid into
 * @p out (under peers_read_lock). Returns true iff found. */

/* Directed connection request to one admitted peer (a bare ask; mirrors
 * _send_profile_query but with no query payload). Encrypt=true: NOT on the
 * plaintext allowlist. */

static int _send_connection_request(const process_t *proc,
                                    const public_identity_t *peer)
{
    generic_msg_t query = {0};
    query.type = NET_MESSAGE;
    strncpy(query.info.net_msg.process, "identity", PROC_NAME_LEN);
    query.info.net_msg.function = ID_CONNECTION_REQUEST;
    query.info.net_msg.encrypt = true;
    memcpy(&query.info.net_msg.to_whom, peer, sizeof(public_identity_t));
    strncpy(query.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    int rc = identity_send_to_network(proc, &query, "a connection request",
                              peer->nickname);
    if (rc == 0)
        log_debug(proc->logger, "Identity: sent connection_request to %s\n",
                  peer->nickname);
    return rc;
}

/* Directed, signed connection response to one admitted peer: {decision,sig,seq}.
 * @p sig_hex is the detached signature over the canonical (requester=peer,
 * accepter=self, decision, seq) form. Encrypt=true. */
static int _send_connection_response(const process_t *proc,
                                     const public_identity_t *peer,
                                     int decision, int64_t seq,
                                     const char *sig_hex)
{
    generic_msg_t response = {0};
    response.type = NET_MESSAGE;
    strncpy(response.info.net_msg.process, "identity", PROC_NAME_LEN);
    response.info.net_msg.function = ID_CONNECTION_RESPONSE;
    response.info.net_msg.encrypt = true;
    memcpy(&response.info.net_msg.to_whom, peer, sizeof(public_identity_t));
    strncpy(response.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = json_object();
    if (env == NULL) return -1;
    json_object_set_new(env, "decision", json_integer(decision ? 1 : 0));
    json_object_set_new(env, "sig", json_string(sig_hex));
    json_object_set_new(env, "seq", json_integer((json_int_t)seq));
    net_msg_pack_json(&response.info.net_msg, env);
    json_decref(env);
    return identity_send_to_network(proc, &response, "a connection response",
                            peer->nickname);
}

/* Handler: a peer asks to connect. Set our edge to pending_in (idempotent; an
 * already-connected edge is left alone), then surface the inbound ask AND the
 * state to the app. No wire response here — the app decides (connections are
 * user-initiated). */
static bool handle_connection_request(const process_t *proc, directory_t *queues,
                                      generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    char requester[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, requester);
    /* A blocked peer cannot ask (Phase 4 P4.1). DROPPED at the top: the ask
     * is directed, and letting it through would move our edge to pending_in
     * and put a notification in front of the person who blocked them —
     * exactly the reach a block exists to remove. Note AT_CONN_DECLINED is
     * re-askable by design, so without this a blocked peer could ask again
     * indefinitely. */
    if (_is_blocked(nmsg->from_whom.uuid)) {
        log_debug(proc->logger,
                  "Identity: connection_request from %s dropped (locally "
                  "blocked)\n", requester);
        return true;
    }
    if (identity_get_connection_state(requester) == AT_CONN_CONNECTED) {
        log_debug(proc->logger,
                  "Identity: connection_request from %s; already connected\n",
                  requester);
        return true;
    }
    _connection_store(requester, AT_CONN_PENDING_IN, 0);
    identity_emit_connection(PEER_CONNECTION_REQUEST_OBSERVED,
                             nmsg->from_whom.uuid, AT_CONN_PENDING_IN);
    identity_emit_connection(PEER_CONNECTION_STATE_OBSERVED,
                             nmsg->from_whom.uuid, AT_CONN_PENDING_IN);
    log_debug(proc->logger, "Identity: connection request from peer %s\n",
              requester);
    return true;
}

/* Handler: the accepter's answer to OUR request — {decision,sig,seq}. Freshness-
 * checked, then SIGNATURE-verified against the accepter's signing key over the
 * canonical (requester=us, accepter=sender, decision, seq) form. On success set
 * our edge connected/declined and surface it. */
static bool handle_connection_response(const process_t *proc, directory_t *queues,
                                       generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;

    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_dec = json_object_get(payload, "decision");
    json_t *j_sig = json_object_get(payload, "sig");
    json_t *j_seq = json_object_get(payload, "seq");
    if (!json_is_integer(j_dec) || !json_is_string(j_sig) || !json_is_integer(j_seq)) {
        json_decref(payload);
        log_warn(proc->logger,
                 "Identity: connection_response unstamped/malformed, refusing\n");
        return true;
    }

    char accepter[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, accepter);
    int64_t seq = (int64_t)json_integer_value(j_seq);
    bool fresh = identity_freshness_accept(accepter, ID_CONNECTION_RESPONSE,
                                           seq, proc->logger);
    if (!fresh) {
        json_decref(payload);
        log_debug(proc->logger,
                  "Identity: connection_response from %s refused (replay)\n",
                  accepter);
        return true;
    }

    int decision = json_integer_value(j_dec) ? 1 : 0;
    char sig_hex[AT_CONNECTION_SIG_HEX_LEN + 1];
    snprintf(sig_hex, sizeof(sig_hex), "%s", json_string_value(j_sig));

    const identity_t *self = identity_self_identity(proc);
    if (self == NULL) {
        json_decref(payload);
        log_debug(proc->logger,
                  "Identity: connection_response but self identity unresolved; skipping\n");
        return true;
    }
    if (!at_connection_verify(nmsg->from_whom.signature.public,
                              self->uuid, nmsg->from_whom.uuid,
                              (uint8_t)decision, (uint64_t)seq, sig_hex)) {
        json_decref(payload);
        log_warn(proc->logger,
                 "Identity: connection_response from %s: BAD SIGNATURE, dropping\n",
                 accepter);
        return true;
    }
    json_decref(payload);

    int new_state = decision ? AT_CONN_CONNECTED : AT_CONN_DECLINED;
    _connection_store(accepter, new_state, (uint64_t)seq);
    identity_emit_connection(PEER_CONNECTION_STATE_OBSERVED,
                             nmsg->from_whom.uuid, new_state);
    log_debug(proc->logger, "Identity: connection with peer %s -> %s\n",
              accepter, decision ? "connected" : "declined");

    /* Increment 8 accrual (requester side). The signed tuple {requester=self,
     * accepter=peer, decision, seq} is identical on both peers, so both derive the
     * same task_uuid and their two scores pair into one bilateral transaction. */
    _social_accrue_connection(proc, self->uuid, nmsg->from_whom.uuid,
                              (uint64_t)seq, decision != 0);
    return true;
}

/* App -> AT verb (AT_APP_CONNECT_REQUEST): the operator asks to connect to a
 * peer. Payload {"peer": "<uuid_str>"}. Set our edge pending_out, send the
 * directed request, surface the state. */
static bool handle_app_connect_request(const process_t *proc, directory_t *queues,
                                       generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_peer = json_object_get(payload, "peer");
    if (!json_is_string(j_peer)) { json_decref(payload); return true; }
    uuid_t peer_uuid;
    int rc = uuid_parse(json_string_value(j_peer), peer_uuid);
    json_decref(payload);
    if (rc != 0) {
        log_warn(proc->logger, "Identity: app connect_request: bad peer uuid\n");
        return true;
    }
    public_identity_t peer;
    if (!identity_find_peer_pub(proc, peer_uuid, &peer)) {
        log_warn(proc->logger, "Identity: app connect_request: unknown peer\n");
        /* The peer is not an admitted identity, so no request can be sent. Signal
         * the app that the edge is (still) NONE so it can revert an optimistic
         * pending_out and tell the operator, rather than leave a pending state
         * that will never resolve (the request never went out). */
        identity_emit_connection(PEER_CONNECTION_STATE_OBSERVED, peer_uuid,
                                 AT_CONN_NONE);
        return true;
    }
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer_uuid, peer_str);
    _connection_store(peer_str, AT_CONN_PENDING_OUT, 0);
    _send_connection_request(proc, &peer);
    identity_emit_connection(PEER_CONNECTION_STATE_OBSERVED, peer_uuid,
                             AT_CONN_PENDING_OUT);
    log_info(proc->logger, "Identity: connection requested to %s\n", peer_str);
    return true;
}

/* App -> AT verb (AT_APP_REQUEST_ATTEND): the operator asks for a FRESH
 * operator-attendance attestation from a peer NOW (Phase 2, presence). Payload
 * {"peer": "<uuid_str>"}. Issue a nonce-fresh operator_attest_query to that
 * peer; handle_attest_response updates the peer's operator_attested_at and
 * re-emits peer_observed, so the app's presence dot refreshes. Non-const proc:
 * identity_request_attestation records the outstanding nonce in social_state. */
static bool handle_request_attend(process_t *proc, directory_t *queues,
                                  generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_peer = json_object_get(payload, "peer");
    if (!json_is_string(j_peer)) { json_decref(payload); return true; }
    uuid_t peer_uuid;
    int rc = uuid_parse(json_string_value(j_peer), peer_uuid);
    json_decref(payload);
    if (rc != 0) {
        log_warn(proc->logger, "Identity: app request_attend: bad peer uuid\n");
        return true;
    }
    public_identity_t peer;
    if (!identity_find_peer_pub(proc, peer_uuid, &peer)) {
        log_warn(proc->logger, "Identity: app request_attend: unknown peer\n");
        return true;
    }
    (void)identity_request_attestation(proc, &peer, NULL, 0);
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer_uuid, peer_str);
    log_info(proc->logger, "Identity: attendance pull requested from %s\n",
             peer_str);
    return true;
}

/* App -> AT verb (AT_APP_CONNECT_RESPOND): the operator accepts/declines an
 * inbound request. Payload {"peer": "<uuid_str>", "accept": <bool>}. Stamp a
 * freshness seq, SIGN the canonical (requester=peer, accepter=us, decision,
 * seq), set our edge, send the signed response, surface the state. */
static bool handle_app_connect_respond(const process_t *proc, directory_t *queues,
                                       generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_peer = json_object_get(payload, "peer");
    json_t *j_acc  = json_object_get(payload, "accept");
    if (!json_is_string(j_peer)) { json_decref(payload); return true; }
    bool accept = json_is_true(j_acc);
    uuid_t peer_uuid;
    int rc = uuid_parse(json_string_value(j_peer), peer_uuid);
    json_decref(payload);
    if (rc != 0) {
        log_warn(proc->logger, "Identity: app connect_respond: bad peer uuid\n");
        return true;
    }
    public_identity_t peer;
    if (!identity_find_peer_pub(proc, peer_uuid, &peer)) {
        log_warn(proc->logger, "Identity: app connect_respond: unknown peer\n");
        return true;
    }
    const identity_t *self = identity_self_identity(proc);
    if (self == NULL) {
        log_debug(proc->logger,
                  "Identity: app connect_respond but self identity unresolved\n");
        return true;
    }
    int64_t seq = identity_freshness_stamp(proc->logger);
    if (seq <= 0) {
        log_warn(proc->logger,
                 "Identity: no freshness sequence; not responding to connection\n");
        return true;
    }
    int decision = accept ? 1 : 0;
    char sig_hex[AT_CONNECTION_SIG_HEX_LEN + 1];
    if (at_connection_sign(self->signature.private, peer_uuid, self->uuid,
                           (uint8_t)decision, (uint64_t)seq, sig_hex) != 0) {
        log_warn(proc->logger, "Identity: connect_respond: signing failed\n");
        return true;
    }
    int new_state = accept ? AT_CONN_CONNECTED : AT_CONN_DECLINED;
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer_uuid, peer_str);
    _connection_store(peer_str, new_state, (uint64_t)seq);
    _send_connection_response(proc, &peer, decision, seq, sig_hex);
    identity_emit_connection(PEER_CONNECTION_STATE_OBSERVED, peer_uuid, new_state);
    log_info(proc->logger, "Identity: connection to %s -> %s\n", peer_str,
             accept ? "connected" : "declined");

    /* Increment 8 accrual (accepter side): same signed {requester=peer,
     * accepter=self, decision, seq} tuple as the requester verifies, so the
     * order-independent task_uuid pairs the two submissions into one transaction. */
    _social_accrue_connection(proc, self->uuid, peer_uuid, (uint64_t)seq,
                              accept != 0);
    return true;
}

/* Emit our edge state for every known peer that has one — the roster-pull answer
 * for the connection half. Mirrors identity_emit_all_profiles. */
static int identity_emit_all_connections(const process_t *proc)
{
    if (proc == NULL) return 0;
    uuid_t uuids[DEFAULT_MAX_PEERS];
    peers_read_lock(proc);
    size_t n = proc->protocol.num_peers;
    if (n > DEFAULT_MAX_PEERS) n = DEFAULT_MAX_PEERS;
    for (size_t i = 0; i < n; i++)
        memcpy(uuids[i], proc->protocol.peers[i].uuid, sizeof(uuid_t));
    peers_read_unlock(proc);

    int emitted = 0;
    for (size_t i = 0; i < n; i++) {
        char uuid_str[UUID_STRING_LEN + 1];
        uuid_unparse_lower(uuids[i], uuid_str);
        int state = identity_get_connection_state(uuid_str);
        if (state != AT_CONN_NONE
            && identity_emit_connection(PEER_CONNECTION_STATE_OBSERVED,
                                        uuids[i], state) == 0)
            emitted++;
    }
    return emitted;
}

/****************************
 * Direct messages (Increment 6, the "message this peer" surface).
 *
 * A DM is a single directed, ENCRYPTED, one-way peer→peer text message carrying
 * {text, seq, ts}. crypto_box already authenticates the sender (only the real
 * peer's key produces the frame), so — UNLIKE the connection accept — there is
 * NO extra Ed25519 signature. NO request/response and NO gossip: it is delivered
 * to the recipient's app on arrival and never replayed as roster state. DMs are
 * allowed between any two admitted peers (no connection/tier gate — that gates
 * the feed, Increment 7). The freshness seq is a per-sender replay guard.
 ****************************/

/* AT -> app: surface one received DM as PEER_DM_OBSERVED. @p sender_uuid is the
 * authenticated sender. Mirrors identity_emit_connection. */
static int identity_emit_dm(const uuid_t sender_uuid, int64_t seq, double ts,
                            const char *text)
{
    generic_msg_t msg = {0};
    msg.type = PEER_DM_OBSERVED;
    peer_dm_msg_t *ext = AT_MSG_EXT(&msg, peer_dm_msg_t);
    msg.size = sizeof(peer_dm_msg_t);
    memcpy(ext->peer_uuid, sender_uuid, 16);
    ext->seq = seq;
    ext->ts = ts;
    at_dm_bound_text(text, ext->text, sizeof(ext->text));
    return messaging_send(AT_MAIN_QUEUE, PEER_DM_OBSERVED, &msg, false);
}

/* Record the most-recent DM from @p sender_str for the conformance/observability
 * seam (identity_get_last_dm). A DM is a live stream, so this is NOT roster
 * state — it is never replayed. Own locking. */
static void _last_dm_store(const char *sender_str, const char *text,
                           int64_t seq, double ts)
{
    json_t *env = at_dm_to_json(text, seq, ts);
    if (env == NULL) return;
    char *compact = json_dumps(env, JSON_COMPACT);
    json_decref(env);
    if (compact == NULL) return;
    size_t len = strlen(compact);
    char *dup = smrt_create(len + 1);
    if (dup == NULL) { free(compact); return; }
    memcpy(dup, compact, len + 1);
    free(compact);
    data_t *dat = string_data(dup, len + 1);
    if (dat == NULL) { smrt_deref(dup); return; }
    pthread_mutex_lock(&social_state.lock);
    map_set(&social_state.last_dm_map, (map_key_t)sender_str, dat);
    pthread_mutex_unlock(&social_state.lock);
}

/* Directed, encrypted DM to one admitted peer: {text,seq,ts}. crypto_box
 * authenticates us, so no signature. Encrypt=true: NOT on the plaintext
 * allowlist. */
static int _send_dm(const process_t *proc, const public_identity_t *peer,
                    const char *text, int64_t seq, double ts)
{
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_DM;
    out.info.net_msg.encrypt = true;
    memcpy(&out.info.net_msg.to_whom, peer, sizeof(public_identity_t));
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = at_dm_to_json(text, seq, ts);
    if (env == NULL) return -1;
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    return identity_send_to_network(proc, &out, "a direct message", peer->nickname);
}

/* App -> AT verb (AT_APP_SEND_DM): the operator sends a text message to a peer.
 * Payload {"peer": "<uuid_str>", "text": "<body>"}. Stamp a freshness seq, set
 * ts=now, send the directed encrypted peer_dm. The core does NOT echo the
 * outgoing message back — the app echoes it locally. */
static bool handle_app_send_dm(const process_t *proc, directory_t *queues,
                               generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_peer = json_object_get(payload, "peer");
    json_t *j_text = json_object_get(payload, "text");
    if (!json_is_string(j_peer)) { json_decref(payload); return true; }
    uuid_t peer_uuid;
    int rc = uuid_parse(json_string_value(j_peer), peer_uuid);
    char text[AT_DM_TEXT_MAX + 1];
    at_dm_bound_text(json_is_string(j_text) ? json_string_value(j_text) : "",
                     text, sizeof(text));
    json_decref(payload);
    if (rc != 0) {
        log_warn(proc->logger, "Identity: app send_dm: bad peer uuid\n");
        return true;
    }
    public_identity_t peer;
    if (!identity_find_peer_pub(proc, peer_uuid, &peer)) {
        log_warn(proc->logger, "Identity: app send_dm: unknown peer\n");
        return true;
    }
    /* We do not write to someone we blocked (Phase 4 P4.1). REFUSED before any
     * wire traffic: a block is mutual in effect, and a DM they can answer but
     * whose answer we would drop is worse than no DM at all. */
    if (_is_blocked(peer_uuid)) {
        char blocked_str[UUID_STRING_LEN + 1];
        uuid_unparse_lower(peer_uuid, blocked_str);
        log_info(proc->logger,
                 "Identity: app send_dm refused: %s is locally blocked\n",
                 blocked_str);
        return true;
    }
    int64_t seq = identity_freshness_stamp(proc->logger);
    if (seq <= 0) {
        log_warn(proc->logger, "Identity: no freshness sequence; not sending DM\n");
        return true;
    }
    double ts = (double)time(NULL);
    _send_dm(proc, &peer, text, seq, ts);
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer_uuid, peer_str);
    log_info(proc->logger, "Identity: DM sent to %s\n", peer_str);
    _social_accrue_dm(proc, peer_uuid, false);   /* Increment 8: outbound stamp */
    return true;
}

/* Handler: an inbound directed DM from a peer — {text,seq,ts}. Freshness-checked
 * (per-sender replay guard), bound-truncated, then surfaced to the app. No wire
 * response and no echo. The sender is the authenticated envelope's from_whom. */
static bool handle_dm(const process_t *proc, directory_t *queues,
                      generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;

    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    char text[AT_DM_TEXT_MAX + 1];
    int64_t seq = 0;
    double ts = 0.0;
    if (at_dm_from_json(payload, text, sizeof(text), &seq, &ts) != 0) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: peer_dm unstamped/malformed, refusing\n");
        return true;
    }
    json_decref(payload);

    char sender[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, sender);
    bool fresh = identity_freshness_accept(sender, ID_DM, seq, proc->logger);
    if (!fresh) {
        log_debug(proc->logger, "Identity: peer_dm from %s refused (replay)\n",
                  sender);
        return true;
    }

    /* A blocked peer cannot reach us (Phase 4 P4.1). DROPPED, not hidden:
     * a DM has no third party whose interest is served by our keeping it, and
     * nothing is stored, emitted or accrued.
     *
     * AFTER freshness_accept, never before. The replay window must still
     * advance, or every DM sent during a block replays the moment it is
     * lifted. */
    if (_is_blocked(nmsg->from_whom.uuid)) {
        log_debug(proc->logger,
                  "Identity: peer_dm from %s dropped (locally blocked)\n",
                  sender);
        return true;
    }

    _last_dm_store(sender, text, seq, ts);
    identity_emit_dm(nmsg->from_whom.uuid, seq, ts, text);
    log_debug(proc->logger, "Identity: DM received from peer %s\n", sender);
    _social_accrue_dm(proc, nmsg->from_whom.uuid, true);  /* Increment 8: inbound */
    return true;
}

/****************************
 * Detached co-signing (Phase 3 P3.3): a roll act decided by people who are not
 * at the same keyboard. Their PRIVATE KEYS DO NOT TRAVEL — the record's exported
 * bytes do, each signer signs them where their key already lives, and the
 * authoring node reassembles the signatures onto the payload.
 *
 * Both messages are directed and ENCRYPTED, like a DM: crypto_box authenticates
 * each end, so neither carries a signature of its own. The core is a courier. It
 * holds no Ethne and cannot tell what the bytes mean; it does not hold the
 * payload and cannot check the returned signature. It bounds and shape-checks,
 * and it carries no description — see cosign.h for why that last one matters.
 ****************************/

/* Record one co-signing exchange for the conformance/observability seams
 * (identity_get_last_cosign_request / _sig). Like a DM this is a LIVE STREAM,
 * not roster state: it is never replayed, and nothing here is judged. Own
 * locking; takes ownership of nothing. */
static void _last_cosign_store(map_t *m, const char *peer_str, json_t *env)
{
    if (env == NULL) return;
    char *compact = json_dumps(env, JSON_COMPACT);
    if (compact == NULL) return;
    size_t len = strlen(compact);
    char *dup = smrt_create(len + 1);
    if (dup == NULL) { free(compact); return; }
    memcpy(dup, compact, len + 1);
    free(compact);
    data_t *dat = string_data(dup, len + 1);
    if (dat == NULL) { smrt_deref(dup); return; }
    pthread_mutex_lock(&social_state.lock);
    map_set(m, (map_key_t)peer_str, dat);
    pthread_mutex_unlock(&social_state.lock);
}

/* AT -> app: surface an inbound co-signing ask. @p requester_uuid is the
 * authenticated envelope's from_whom. */
static int identity_emit_cosign_request(const uuid_t requester_uuid,
                                        const char *record, const char *op,
                                        const char *polity, const char *cid,
                                        int64_t seq, double ts,
                                        const char *bytes)
{
    generic_msg_t msg = {0};
    msg.type = PEER_COSIGN_REQUEST_OBSERVED;
    peer_cosign_request_msg_t *ext = AT_MSG_EXT(&msg, peer_cosign_request_msg_t);
    msg.size = sizeof(peer_cosign_request_msg_t);
    memcpy(ext->peer_uuid, requester_uuid, 16);
    at_cosign_bound(record, ext->record,
                    sizeof(ext->record), AT_COSIGN_TOKEN_MAX);
    at_cosign_bound(op, ext->op,
                    sizeof(ext->op), AT_COSIGN_TOKEN_MAX);
    at_cosign_bound(polity, ext->polity,
                    sizeof(ext->polity), AT_COSIGN_DID_MAX);
    at_cosign_bound(cid, ext->cid,
                    sizeof(ext->cid), AT_COSIGN_CID_MAX);
    ext->seq = seq;
    ext->ts = ts;
    at_cosign_bound(bytes, ext->bytes,
                    sizeof(ext->bytes), AT_COSIGN_BYTES_MAX);
    return messaging_send(AT_MAIN_QUEUE, PEER_COSIGN_REQUEST_OBSERVED, &msg, false);
}

/* AT -> app: surface a returned signature to the node authoring the exchange. */
static int identity_emit_cosign_sig(const uuid_t signer_uuid, const char *cid,
                                    const char *signer, const char *sig,
                                    int64_t seq, double ts)
{
    generic_msg_t msg = {0};
    msg.type = PEER_COSIGN_SIG_OBSERVED;
    peer_cosign_sig_msg_t *ext = AT_MSG_EXT(&msg, peer_cosign_sig_msg_t);
    msg.size = sizeof(peer_cosign_sig_msg_t);
    memcpy(ext->peer_uuid, signer_uuid, 16);
    at_cosign_bound(cid, ext->cid,
                    sizeof(ext->cid), AT_COSIGN_CID_MAX);
    at_cosign_bound(signer, ext->signer,
                    sizeof(ext->signer), AT_COSIGN_DID_MAX);
    at_cosign_bound(sig, ext->sig,
                    sizeof(ext->sig), AT_COSIGN_SIG_MAX);
    ext->seq = seq;
    ext->ts = ts;
    return messaging_send(AT_MAIN_QUEUE, PEER_COSIGN_SIG_OBSERVED, &msg, false);
}

/* Directed, encrypted co-signing ask to one admitted peer. */
static int _send_cosign_request(const process_t *proc, const public_identity_t *peer,
                                const char *record, const char *op,
                                const char *polity, const char *cid,
                                const char *bytes, int64_t seq, double ts)
{
    (void)proc;
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_COSIGN_REQUEST;
    out.info.net_msg.encrypt = true;
    memcpy(&out.info.net_msg.to_whom, peer, sizeof(public_identity_t));
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = at_cosign_request_to_json(record, op, polity, cid, bytes, seq, ts);
    if (env == NULL) return -1;
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    messaging_send("network", NET_MESSAGE, &out, false);
    return 0;
}

/* Directed, encrypted signature return to the peer authoring the exchange. */
static int _send_cosign_sig(const process_t *proc, const public_identity_t *peer,
                            const char *cid, const char *signer, const char *sig,
                            int64_t seq, double ts)
{
    (void)proc;
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_COSIGN_SIG;
    out.info.net_msg.encrypt = true;
    memcpy(&out.info.net_msg.to_whom, peer, sizeof(public_identity_t));
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = at_cosign_sig_to_json(cid, signer, sig, seq, ts);
    if (env == NULL) return -1;
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    messaging_send("network", NET_MESSAGE, &out, false);
    return 0;
}

/* App -> AT verb (AT_APP_REQUEST_COSIGN): ask each named peer to co-sign one
 * record. Payload {"peers":[uuid…],"record","op","polity","cid","bytes"}. One
 * freshness stamp covers the whole ask, so every copy of it is the same ask. */
static bool handle_app_request_cosign(const process_t *proc, directory_t *queues,
                                      generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_peers  = json_object_get(payload, "peers");
    json_t *j_record = json_object_get(payload, "record");
    json_t *j_op     = json_object_get(payload, "op");
    json_t *j_polity = json_object_get(payload, "polity");
    json_t *j_cid    = json_object_get(payload, "cid");
    json_t *j_bytes  = json_object_get(payload, "bytes");
    if (!json_is_array(j_peers) || !json_is_string(j_record)
        || !json_is_string(j_op) || !json_is_string(j_polity)
        || !json_is_string(j_cid) || !json_is_string(j_bytes)) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: app request_cosign: malformed\n");
        return true;
    }
    char record[AT_COSIGN_TOKEN_MAX + 1], op[AT_COSIGN_TOKEN_MAX + 1];
    char polity[AT_COSIGN_DID_MAX + 1], cid[AT_COSIGN_CID_MAX + 1];
    at_cosign_bound(json_string_value(j_record), record, sizeof(record), AT_COSIGN_TOKEN_MAX);
    at_cosign_bound(json_string_value(j_op), op, sizeof(op), AT_COSIGN_TOKEN_MAX);
    at_cosign_bound(json_string_value(j_polity), polity, sizeof(polity), AT_COSIGN_DID_MAX);
    at_cosign_bound(json_string_value(j_cid), cid, sizeof(cid), AT_COSIGN_CID_MAX);
    const char *bytes = json_string_value(j_bytes);
    /* Refuse an unknown act or a payload no exporter produced, before anybody is
     * interrupted to look at it. */
    if (!at_cosign_op_ok(record, op) || !at_cosign_bytes_ok(bytes) || cid[0] == '\0') {
        json_decref(payload);
        log_warn(proc->logger, "Identity: app request_cosign: unknown op or bad payload\n");
        return true;
    }
    int64_t seq = identity_freshness_stamp(proc->logger);
    if (seq <= 0) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: no freshness sequence; not asking to co-sign\n");
        return true;
    }
    double ts = (double)time(NULL);
    size_t sent = 0;
    size_t n = json_array_size(j_peers);
    for (size_t i = 0; i < n; i++) {
        json_t *j_peer = json_array_get(j_peers, i);
        if (!json_is_string(j_peer)) continue;
        uuid_t peer_uuid;
        if (uuid_parse(json_string_value(j_peer), peer_uuid) != 0) {
            log_warn(proc->logger, "Identity: app request_cosign: bad peer uuid\n");
            continue;
        }
        public_identity_t peer;
        if (!identity_find_peer_pub(proc, peer_uuid, &peer)) {
            log_warn(proc->logger, "Identity: app request_cosign: unknown peer\n");
            continue;
        }
        if (_send_cosign_request(proc, &peer, record, op, polity, cid, bytes,
                                 seq, ts) == 0)
            sent++;
    }
    json_decref(payload);
    log_info(proc->logger, "Identity: co-signing ask (%s/%s) sent to %zu of %zu\n",
             record, op, sent, n);
    return true;
}

/* App -> AT verb (AT_APP_RETURN_COSIGN): return this node's signature to the
 * peer authoring the exchange. Payload {"peer","cid","signer","sig"}. */
static bool handle_app_return_cosign(const process_t *proc, directory_t *queues,
                                     generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_peer   = json_object_get(payload, "peer");
    json_t *j_cid    = json_object_get(payload, "cid");
    json_t *j_signer = json_object_get(payload, "signer");
    json_t *j_sig    = json_object_get(payload, "sig");
    if (!json_is_string(j_peer) || !json_is_string(j_cid)
        || !json_is_string(j_signer) || !json_is_string(j_sig)) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: app return_cosign: malformed\n");
        return true;
    }
    uuid_t peer_uuid;
    int rc = uuid_parse(json_string_value(j_peer), peer_uuid);
    char cid[AT_COSIGN_CID_MAX + 1], signer[AT_COSIGN_DID_MAX + 1];
    char sig[AT_COSIGN_SIG_MAX + 1];
    at_cosign_bound(json_string_value(j_cid), cid, sizeof(cid), AT_COSIGN_CID_MAX);
    at_cosign_bound(json_string_value(j_signer), signer, sizeof(signer), AT_COSIGN_DID_MAX);
    at_cosign_bound(json_string_value(j_sig), sig, sizeof(sig), AT_COSIGN_SIG_MAX);
    json_decref(payload);
    if (rc != 0) {
        log_warn(proc->logger, "Identity: app return_cosign: bad peer uuid\n");
        return true;
    }
    if (cid[0] == '\0' || signer[0] == '\0' || sig[0] == '\0') {
        log_warn(proc->logger, "Identity: app return_cosign: empty field\n");
        return true;
    }
    public_identity_t peer;
    if (!identity_find_peer_pub(proc, peer_uuid, &peer)) {
        log_warn(proc->logger, "Identity: app return_cosign: unknown peer\n");
        return true;
    }
    int64_t seq = identity_freshness_stamp(proc->logger);
    if (seq <= 0) {
        log_warn(proc->logger, "Identity: no freshness sequence; not returning signature\n");
        return true;
    }
    _send_cosign_sig(proc, &peer, cid, signer, sig, seq, (double)time(NULL));
    return true;
}

/* Handler: an inbound co-signing ask. Freshness-checked (per-sender replay
 * guard), shape-checked, then surfaced. The core does not judge the request:
 * whether this node is even a required signer is Ethne's question, answered on
 * the app side against the payload itself. */
static bool handle_cosign_request(const process_t *proc, directory_t *queues,
                                  generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    /* A blocked peer cannot ask us to co-sign (Phase 4 P4.1). DROPPED at the
     * top: a co-sign ask is directed and lands in front of a person as a
     * decision to make. Blocking is not a governance act — the roll is Ethne's
     * business, and this says nothing about whether the record is valid or
     * whether this node is a required signer. It says only that THIS person
     * will not be asked by THAT one. */
    if (_is_blocked(nmsg->from_whom.uuid)) {
        log_debug(proc->logger,
                  "Identity: peer_cosign_request from %s dropped (locally "
                  "blocked)\n", nmsg->from_whom.nickname);
        return true;
    }
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL) {
        /* Was a silent `return true`. An ask that dies here leaves NO trace on
         * the signer and the asking node cannot tell this from a lost frame —
         * which is exactly how a routing gap read as a network fault. */
        log_warn(proc->logger,
                 "Identity: peer_cosign_request from %s could not be unpacked,"
                 " dropping\n", nmsg->from_whom.nickname);
        return true;
    }
    char record[AT_COSIGN_TOKEN_MAX + 1], op[AT_COSIGN_TOKEN_MAX + 1];
    char polity[AT_COSIGN_DID_MAX + 1], cid[AT_COSIGN_CID_MAX + 1];
    char bytes[AT_COSIGN_BYTES_MAX + 1];
    int64_t seq = 0;
    double ts = 0.0;
    int prc = at_cosign_request_from_json(payload, record, sizeof(record),
                                          op, sizeof(op), polity, sizeof(polity),
                                          cid, sizeof(cid), bytes, sizeof(bytes),
                                          &seq, &ts);
    json_decref(payload);
    if (prc != 0) {
        log_warn(proc->logger,
                 "Identity: peer_cosign_request malformed/unknown op, refusing\n");
        return true;
    }
    char sender[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, sender);
    bool fresh = identity_freshness_accept(sender, ID_COSIGN_REQUEST, seq,
                                           proc->logger);
    if (!fresh) {
        log_debug(proc->logger,
                  "Identity: peer_cosign_request from %s refused (replay)\n", sender);
        return true;
    }
    json_t *rec_env = at_cosign_request_to_json(record, op, polity, cid, bytes,
                                                seq, ts);
    _last_cosign_store(&social_state.last_cosign_request_map, sender, rec_env);
    json_decref(rec_env);
    /* The emit result was DISCARDED. It is the last hop before the app queue,
     * so a failure here is the whole exchange failing with nothing said. */
    if (identity_emit_cosign_request(nmsg->from_whom.uuid, record, op, polity,
                                     cid, seq, ts, bytes) != 0) {
        log_warn(proc->logger,
                 "Identity: co-signing ask (%s/%s) from %s accepted but COULD NOT"
                 " BE EMITTED to the app queue\n", record, op, sender);
        return true;
    }
    /* INFO, not debug: a co-signing ask is rare and is the pivot of the whole
     * exchange. At debug it is invisible in a cohort run, which leaves "the
     * signer never saw it" and "the signer saw it and said nothing"
     * indistinguishable in the logs. */
    log_info(proc->logger, "Identity: co-signing ask (%s/%s) from peer %s\n",
             record, op, sender);
    return true;
}

/* Handler: a returned signature. Freshness-checked, then surfaced. The core does
 * NOT verify it: it does not hold the payload the signature is over. The
 * assembling node does, and refuses a wrong key or a tampered payload there. */
static bool handle_cosign_sig(const process_t *proc, directory_t *queues,
                              generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL) {
        log_warn(proc->logger,
                 "Identity: peer_cosign_sig from %s could not be unpacked,"
                 " dropping\n", nmsg->from_whom.nickname);
        return true;
    }
    char cid[AT_COSIGN_CID_MAX + 1], signer[AT_COSIGN_DID_MAX + 1];
    char sig[AT_COSIGN_SIG_MAX + 1];
    int64_t seq = 0;
    double ts = 0.0;
    int prc = at_cosign_sig_from_json(payload, cid, sizeof(cid), signer,
                                      sizeof(signer), sig, sizeof(sig), &seq, &ts);
    json_decref(payload);
    if (prc != 0) {
        log_warn(proc->logger, "Identity: peer_cosign_sig malformed, refusing\n");
        return true;
    }
    char sender[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, sender);
    bool fresh = identity_freshness_accept(sender, ID_COSIGN_SIG, seq,
                                           proc->logger);
    if (!fresh) {
        log_debug(proc->logger,
                  "Identity: peer_cosign_sig from %s refused (replay)\n", sender);
        return true;
    }
    json_t *sig_env = at_cosign_sig_to_json(cid, signer, sig, seq, ts);
    _last_cosign_store(&social_state.last_cosign_sig_map, sender, sig_env);
    json_decref(sig_env);
    if (identity_emit_cosign_sig(nmsg->from_whom.uuid, cid, signer, sig, seq,
                                 ts) != 0) {
        log_warn(proc->logger,
                 "Identity: co-signature from %s accepted but COULD NOT BE"
                 " EMITTED to the app queue\n", sender);
        return true;
    }
    log_info(proc->logger, "Identity: co-signature returned by peer %s\n", sender);
    return true;
}

/****************************
 * Post reactions (Increment 8): the return signal a fire-and-forget post lacks.
 * A reaction is a directed, ENCRYPTED reactor→author message {post_id, seq, ts},
 * exactly like a DM (crypto_box authenticates the reactor). Both peers submit a
 * reputation score for the same post-derived task, so the engagement accrues.
 ****************************/

/* AT -> app: surface a reaction to one of our posts. */
static int identity_emit_reaction(const uuid_t reactor_uuid, const char *post_id,
                                  int64_t seq, double ts)
{
    generic_msg_t msg = {0};
    msg.type = PEER_REACTION_OBSERVED;
    peer_reaction_msg_t *ext = AT_MSG_EXT(&msg, peer_reaction_msg_t);
    msg.size = sizeof(peer_reaction_msg_t);
    memcpy(ext->peer_uuid, reactor_uuid, 16);
    snprintf(ext->post_id,
             sizeof(ext->post_id), "%s",
             post_id != NULL ? post_id : "");
    ext->seq = seq;
    ext->ts = ts;
    return messaging_send(AT_MAIN_QUEUE, PEER_REACTION_OBSERVED, &msg, false);
}

/* What a reaction's on-sent callback needs to accrue our half. */
typedef struct {
    uuid_t reactor;
    uuid_t author;
    char   post_id[AT_POST_ID_LEN + 1];
} _reaction_sent_t;

/* The reaction's fate: accrue our (reactor) half only if it went. */
static void _on_reaction_sent(const process_t *proc, const void *ctx, bool sent)
{
    const _reaction_sent_t *r = ctx;
    if (sent)
        _social_accrue_reaction(proc, r->reactor, r->author, r->post_id);
    else
        log_warn(proc != NULL ? proc->logger : NULL,
                 "Identity: a kept reaction was given up on; not scoring it\n");
}

/* Directed, encrypted reaction to the post's author: {post_id, seq, ts}.
 * crypto_box authenticates us, so no signature. Encrypt=true. Our half of the
 * score is accrued once the frame is really out (see handle_app_react_post). */
static int _send_reaction(const process_t *proc, const public_identity_t *author,
                          const uuid_t reactor, const char *post_id, int64_t seq,
                          double ts)
{
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_REACTION;
    out.info.net_msg.encrypt = true;
    memcpy(&out.info.net_msg.to_whom, author, sizeof(public_identity_t));
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = json_object();
    if (env == NULL) return -1;
    json_object_set_new(env, "post_id", json_string(post_id));
    json_object_set_new(env, "seq", json_integer(seq));
    json_object_set_new(env, "ts", json_real(ts));
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    _reaction_sent_t sent = {0};
    uuid_copy(sent.reactor, reactor);
    uuid_copy(sent.author, author->uuid);
    snprintf(sent.post_id, sizeof(sent.post_id), "%s", post_id);
    return identity_send_to_network_then(proc, &out, "a post reaction",
                                         author->nickname, _on_reaction_sent,
                                         &sent, sizeof(sent));
}

/* App -> AT verb (AT_APP_REACT_POST): the operator reacts to a peer's post.
 * Payload {"author": "<uuid_str>", "post_id": "<hex>"}. Send the directed
 * encrypted reaction to the author and accrue our (reactor) half. */
static bool handle_app_react_post(const process_t *proc, directory_t *queues,
                                  generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_auth = json_object_get(payload, "author");
    json_t *j_pid = json_object_get(payload, "post_id");
    if (!json_is_string(j_auth) || !json_is_string(j_pid)) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: app react_post malformed, refusing\n");
        return true;
    }
    uuid_t author_uuid;
    int rc = uuid_parse(json_string_value(j_auth), author_uuid);
    char post_id[AT_POST_ID_LEN + 1];
    snprintf(post_id, sizeof(post_id), "%s", json_string_value(j_pid));
    json_decref(payload);
    if (rc != 0) {
        log_warn(proc->logger, "Identity: app react_post: bad author uuid\n");
        return true;
    }
    public_identity_t author;
    if (!identity_find_peer_pub(proc, author_uuid, &author)) {
        log_warn(proc->logger, "Identity: app react_post: unknown author\n");
        return true;
    }
    /* We do not react to someone we blocked (Phase 4 P4.1). Refused before any
     * wire traffic — see app send_dm. */
    if (_is_blocked(author_uuid)) {
        log_info(proc->logger,
                 "Identity: app react_post refused: author is locally blocked\n");
        return true;
    }
    const identity_t *self = identity_self_identity(proc);
    if (self == NULL) {
        log_debug(proc->logger,
                  "Identity: app react_post but self identity unresolved\n");
        return true;
    }
    int64_t seq = identity_freshness_stamp(proc->logger);
    if (seq <= 0) {
        log_warn(proc->logger, "Identity: no freshness sequence; not reacting\n");
        return true;
    }
    double ts = (double)time(NULL);
    /* ACCRUE ONLY IF IT ACTUALLY WENT. A reaction scores BILATERALLY: we
     * submit on send and the author submits on receipt, both against a task
     * uuid neither side sends. If our frame never leaves, our half sits in
     * the chain as a transaction that can never complete — a permanent
     * half-entry, and a score claimed for an interaction the other party
     * never had. Silently accruing anyway is what the 2026-09-21 cohort
     * caught: bob's half was submitted, alice never heard of the reaction,
     * and nothing could reconcile them.
     *
     * So the accrual is the send's on-sent callback, not this function's: a
     * frame a full queue made AT keep (ISSUES §2.40) is scored when the tick
     * gets it out, and never if it is given up on. */
    if (_send_reaction(proc, &author, self->uuid, post_id, seq, ts) != 0)
        log_warn(proc->logger,
                 "Identity: react_post to %s was not sent; not scoring it\n",
                 author.nickname);
    return true;
}

/* Handler: an inbound reaction to one of OUR posts — {post_id, seq, ts}.
 * Freshness-checked (per-sender replay guard), surfaced to the app, and accrued
 * (author side). The reactor is the authenticated envelope's from_whom. */
static bool handle_reaction(const process_t *proc, directory_t *queues,
                            generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_pid = json_object_get(payload, "post_id");
    json_t *j_seq = json_object_get(payload, "seq");
    json_t *j_ts = json_object_get(payload, "ts");
    if (!json_is_string(j_pid) || !json_is_integer(j_seq)) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: peer_reaction malformed, refusing\n");
        return true;
    }
    char post_id[AT_POST_ID_LEN + 1];
    snprintf(post_id, sizeof(post_id), "%s", json_string_value(j_pid));
    int64_t seq = (int64_t)json_integer_value(j_seq);
    double ts = json_is_number(j_ts) ? json_number_value(j_ts) : 0.0;
    json_decref(payload);

    char sender[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, sender);
    bool fresh = identity_freshness_accept(sender, ID_REACTION, seq,
                                           proc->logger);
    if (!fresh) {
        log_debug(proc->logger, "Identity: peer_reaction from %s refused (replay)\n",
                  sender);
        return true;
    }

    /* A blocked peer cannot reach us (Phase 4 P4.1). DROPPED after the
     * freshness window advances, for the reason handle_dm gives. Note this
     * path ACCRUED REPUTATION for a blocked peer before P4.1 — it is one of
     * the two the accrual gate closes, and the drop makes it moot. */
    if (_is_blocked(nmsg->from_whom.uuid)) {
        log_debug(proc->logger,
                  "Identity: peer_reaction from %s dropped (locally blocked)\n",
                  sender);
        return true;
    }

    identity_emit_reaction(nmsg->from_whom.uuid, post_id, seq, ts);
    log_debug(proc->logger, "Identity: reaction received from peer %s\n", sender);
    const identity_t *self = identity_self_identity(proc);
    if (self != NULL)
        _social_accrue_reaction(proc, self->uuid, nmsg->from_whom.uuid, post_id);
    return true;
}

/****************************
 * First-person reports (Phase 4 P4.1). A report is an INTERACTION OUTCOME — one
 * party's own account that an exchange went badly — so it is a low scalar through
 * the ordinary bilateral transaction, on the `first_person` channel. Not an
 * authority finding: those are ceilings (PEER_STANDING), never scores.
 *
 * The reporter sends a directed encrypted peer_report {seq, ts}; both sides
 * derive the same task from (reporter, reported, seq) and stage their halves:
 * the reporter AT_SOCIAL_REPORT_SCORE about the reported peer, the reported
 * node AT_SOCIAL_REPORTER_SCORE about the reporter. Nothing reaches the reported
 * node's app — the node learns, the person is not told, which is the whole
 * defence against retaliation.
 *
 * Refusable, and documented as such: a forked reported node need simply not
 * stage its half, and the report never commits.
 ****************************/

/* Read the report ledger for @p uuid_str, rolled over to @p today (a record from
 * an earlier day reads as zeros). Caller MUST hold social_state.lock. */
static void _social_report_get_locked(const char *uuid_str, int today,
                                      int *out_n, int *in_n)
{
    *out_n = 0; *in_n = 0;
    data_t *dat = NULL;
    if (map_get(&social_state.social_reports, (map_key_t)uuid_str, &dat) != 0
        || dat == NULL)
        return;
    char *s = NULL;
    if (data_string_ptr(dat, &s) != 0 || s == NULL)
        return;
    json_error_t jerr;
    json_t *o = json_loads(s, 0, &jerr);
    if (o == NULL)
        return;
    json_t *jd = json_object_get(o, "day");
    if (json_is_integer(jd) && (int)json_integer_value(jd) == today) {
        json_t *j;
        if ((j = json_object_get(o, "out")) && json_is_integer(j))
            *out_n = (int)json_integer_value(j);
        if ((j = json_object_get(o, "in")) && json_is_integer(j))
            *in_n = (int)json_integer_value(j);
    }
    json_decref(o);
}

/* Write the report ledger. Caller MUST hold social_state.lock. */
static void _social_report_put_locked(const char *uuid_str, int today,
                                      int out_n, int in_n)
{
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "{\"day\":%d,\"out\":%d,\"in\":%d}",
                       today, out_n, in_n);
    if (len <= 0 || (size_t)len >= sizeof(buf)) return;
    char *dup = smrt_create((size_t)len + 1);
    if (dup == NULL) return;
    memcpy(dup, buf, (size_t)len + 1);
    data_t *dat = string_data(dup, (size_t)len + 1);
    if (dat == NULL) { smrt_deref(dup); return; }
    map_set(&social_state.social_reports, (map_key_t)uuid_str, dat);
}

/* May we report @p uuid_str now — and, when @p spend, record that we did?
 *
 * Checked BEFORE the frame goes and spent only AFTER it went, so a refused
 * report never reaches the wire (the reported node would otherwise stage a half
 * we will never match) and an unsent one costs nothing.
 *
 * Three bounds, all of which must hold:
 *   - AT_SOCIAL_REPORT_DAILY_CAP about this peer today;
 *   - the SHARED per-edge budget (AT_SOCIAL_PER_EDGE_DAILY_CAP) and
 *   - the SHARED global budget (AT_SOCIAL_GLOBAL_DAILY_CAP).
 * Two consequences of sharing, both accepted: a report SPENDS budget a positive
 * interaction would have used — that is the anti-abuse property, since
 * report-spam costs the spammer their own ability to accrue — and it bumps the
 * per-edge count, so the next positive with this peer scores slightly lower.
 *
 * NOT gated by the block, unlike _social_accrue. A block governs what we see;
 * whether we also report is a separate decision, and "Block · Both" must work in
 * either order. The block gate exists in _social_accrue because a blocked peer
 * has no reason to stage the other half — here they do, because we tell them. */
static bool _social_report_outbound(const char *uuid_str, long now, bool spend)
{
    int today = (int)(now / AT_SOCIAL_DAY_SECONDS);
    bool ok = false;
    pthread_mutex_lock(&social_state.lock);
    int out_n, in_n;
    _social_report_get_locked(uuid_str, today, &out_n, &in_n);
    int count, day, dc; long lo, li;
    _social_edge_get_locked(uuid_str, &count, &lo, &li, &day, &dc);
    if (day != today) { day = today; dc = 0; }
    int global = (social_state.social_day == today) ? social_state.social_day_count : 0;
    if (out_n < AT_SOCIAL_REPORT_DAILY_CAP
        && dc < AT_SOCIAL_PER_EDGE_DAILY_CAP
        && global < AT_SOCIAL_GLOBAL_DAILY_CAP) {
        ok = true;
        if (spend) {
            _social_report_put_locked(uuid_str, today, out_n + 1, in_n);
            _social_edge_put_locked(uuid_str, count + 1, lo, li, day, dc + 1);
            social_state.social_day = today;
            social_state.social_day_count = global + 1;
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return ok;
}

/* Pair at most AT_SOCIAL_REPORT_DAILY_CAP reports from @p uuid_str per day,
 * recording this one when it fits. This is the only bound on a FORKED reporter,
 * whose own caps are whatever it claims.
 *
 * Deliberately NOT charged to our shared budget: if pairing a report cost the
 * reported node its own accrual budget, a node that had spent its budget on
 * ordinary interactions would be unreportable for the rest of the day. */
static bool _social_report_inbound(const char *uuid_str, long now)
{
    int today = (int)(now / AT_SOCIAL_DAY_SECONDS);
    bool ok = false;
    pthread_mutex_lock(&social_state.lock);
    int out_n, in_n;
    _social_report_get_locked(uuid_str, today, &out_n, &in_n);
    if (in_n < AT_SOCIAL_REPORT_DAILY_CAP) {
        _social_report_put_locked(uuid_str, today, out_n, in_n + 1);
        ok = true;
    }
    pthread_mutex_unlock(&social_state.lock);
    return ok;
}

/* The shared report task: domain "agora-report", the two uuids in canonical
 * order, and reporter_uuid[16] || seq u64le as the tail. See
 * AT_SOCIAL_DOMAIN_REPORT for why the reporter is in the tail. */
static int _social_report_task(const uuid_t reporter, const uuid_t reported,
                               uint64_t seq, uuid_t task)
{
    uint8_t tail[16 + 8];
    memcpy(tail, reporter, 16);
    for (int i = 0; i < 8; i++)
        tail[16 + i] = (uint8_t)((seq >> (8 * i)) & 0xFF);
    return at_social_task_uuid(AT_SOCIAL_DOMAIN_REPORT, reporter, reported,
                               tail, sizeof(tail), task);
}

/* What a report's on-sent callback needs to stage our half. */
typedef struct {
    uuid_t task;
    uuid_t peer;
    long   now;
} _report_sent_t;

/* Whether a report to @p peer is still held by AT; with @p set, mark it (true)
 * or settle it (false) instead. Takes social_state.lock. */
static bool _report_in_flight(const uuid_t peer, bool set, bool on)
{
    bool found = false;
    pthread_mutex_lock(&social_state.lock);
    size_t n = social_state.num_reports_in_flight;
    for (size_t i = 0; i < n && !found; i++) {
        if (uuid_compare(social_state.reports_in_flight[i], peer) != 0)
            continue;
        found = true;
        if (set && !on)
            uuid_copy(social_state.reports_in_flight[i],
                      social_state.reports_in_flight[--social_state.num_reports_in_flight]);
    }
    if (set && on && !found && n < ID_SEND_RETRY_MAX)
        uuid_copy(social_state.reports_in_flight[social_state.num_reports_in_flight++],
                  peer);
    pthread_mutex_unlock(&social_state.lock);
    return found;
}

/* The report's fate. If it went: count it against the day's cap and stage our
 * first-person half. If AT gave it up: nothing was spent, the operator may
 * report again. */
static void _on_report_sent(const process_t *proc, const void *ctx, bool sent)
{
    const _report_sent_t *r = ctx;
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(r->peer, peer_str);
    _report_in_flight(r->peer, true, false);
    if (!sent) {
        log_warn(proc != NULL ? proc->logger : NULL,
                 "Identity: a kept report of %s was given up on; not scoring"
                 " it\n", peer_str);
        return;
    }
    _social_report_outbound(peer_str, r->now, true);
    _submit_interaction_score(proc, r->task, AT_SOCIAL_REPORT_SCORE, r->peer,
                              TX_CHANNEL_FIRST_PERSON);
    log_info(proc != NULL ? proc->logger : NULL,
             "Identity: reported peer %s\n", peer_str);
}

/* Directed, encrypted report to @p target: {seq, ts}. Encrypt=true. Our half
 * is staged once the frame is really out (see handle_app_report_peer). */
static int _send_report(const process_t *proc, const public_identity_t *target,
                        const uuid_t task, long now, int64_t seq, double ts)
{
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_REPORT;
    out.info.net_msg.encrypt = true;
    memcpy(&out.info.net_msg.to_whom, target, sizeof(public_identity_t));
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = json_object();
    if (env == NULL) return -1;
    json_object_set_new(env, "seq", json_integer(seq));
    json_object_set_new(env, "ts", json_real(ts));
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    _report_sent_t sent = {0};
    uuid_copy(sent.task, task);
    uuid_copy(sent.peer, target->uuid);
    sent.now = now;
    return identity_send_to_network_then(proc, &out, "a report",
                                         target->nickname, _on_report_sent,
                                         &sent, sizeof(sent));
}

/* App -> AT verb (AT_APP_REPORT_PEER): the operator reports a peer. Payload
 * {"peer": "<uuid_str>"}; any other key is ignored — a reason in particular,
 * which stays in the app. */
static bool handle_app_report_peer(const process_t *proc, directory_t *queues,
                                   generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    /* A verb that lowers a peer's reputation must come from THIS device's app.
     * Unguarded, any admitted peer could report on our behalf. */
    if (!identity_is_local_app_verb(proc, nmsg))
        return identity_refuse_remote_app_verb(proc, nmsg, AT_APP_REPORT_PEER);
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_peer = json_object_get(payload, "peer");
    uuid_t peer_uuid;
    int rc = json_is_string(j_peer)
        ? uuid_parse(json_string_value(j_peer), peer_uuid) : -1;
    json_decref(payload);
    if (rc != 0) {
        log_warn(proc->logger, "Identity: app report_peer malformed, refusing\n");
        return true;
    }
    public_identity_t target;
    if (!identity_find_peer_pub(proc, peer_uuid, &target)) {
        log_warn(proc->logger, "Identity: app report_peer: unknown peer\n");
        return true;
    }
    const identity_t *self = identity_self_identity(proc);
    if (self == NULL) {
        log_debug(proc->logger,
                  "Identity: app report_peer but self identity unresolved\n");
        return true;
    }
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer_uuid, peer_str);
    long now = (long)time(NULL);
    if (_report_in_flight(peer_uuid, false, false)) {
        log_info(proc->logger,
                 "Identity: report of %s refused: an earlier one is still"
                 " waiting for the network queue\n", peer_str);
        return true;
    }
    if (!_social_report_outbound(peer_str, now, false)) {
        log_info(proc->logger,
                 "Identity: report of %s refused: daily report or accrual cap "
                 "reached\n", peer_str);
        return true;
    }
    int64_t seq = identity_freshness_stamp(proc->logger);
    if (seq <= 0) {
        log_warn(proc->logger, "Identity: no freshness sequence; not reporting\n");
        return true;
    }
    uuid_t task;
    if (_social_report_task(self->uuid, peer_uuid, (uint64_t)seq, task) != 0)
        return true;
    /* STAGE ONLY IF IT WENT — the reaction path's rule, for its reason: an
     * unsent report would leave our half in the chain for good. Staging (and
     * the cap) is the send's on-sent callback, so a report AT kept for a full
     * queue counts when it goes out and never if it is given up on. Until it
     * is settled the target is marked in flight, so a second report cannot
     * slip past the cap meanwhile. */
    _report_in_flight(peer_uuid, true, true);
    if (_send_report(proc, &target, task, now, seq, (double)time(NULL)) != 0) {
        _report_in_flight(peer_uuid, true, false);   /* no callback follows */
        log_warn(proc->logger,
                 "Identity: report of %s was not sent; not scoring it\n",
                 target.nickname);
    }
    return true;
}

/* Handler: a peer reported US — {seq, ts}. Freshness-checked, dropped if we
 * blocked the reporter, capped per reporter per day, then our half is staged so
 * the report can commit. The reporter is the authenticated envelope's from_whom.
 *
 * NOTHING IS EMITTED TO THE APP. The person being reported is not told, by
 * whom or at all; their node stages a transaction like any other. */
static bool handle_peer_report(const process_t *proc, directory_t *queues,
                               generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_seq = json_object_get(payload, "seq");
    if (!json_is_integer(j_seq)) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: peer_report malformed, refusing\n");
        return true;
    }
    int64_t seq = (int64_t)json_integer_value(j_seq);
    json_decref(payload);

    char sender[UUID_STRING_LEN + 1];
    uuid_unparse_lower(nmsg->from_whom.uuid, sender);
    bool fresh = identity_freshness_accept(sender, ID_REPORT, seq,
                                           proc->logger);
    if (!fresh) {
        log_debug(proc->logger, "Identity: peer_report from %s refused (replay)\n",
                  sender);
        return true;
    }
    /* Directed traffic from a blocked peer is DROPPED (after the freshness
     * window advances, for the reason handle_dm gives). Their report then never
     * pairs — a consequence of our block, and one they cannot observe. */
    if (_is_blocked(nmsg->from_whom.uuid)) {
        log_debug(proc->logger,
                  "Identity: peer_report from %s dropped (locally blocked)\n",
                  sender);
        return true;
    }
    if (!_social_report_inbound(sender, (long)time(NULL))) {
        log_info(proc->logger,
                 "Identity: peer_report from %s refused: daily report cap\n",
                 sender);
        return true;
    }
    const identity_t *self = identity_self_identity(proc);
    if (self == NULL)
        return true;
    uuid_t task;
    if (_social_report_task(nmsg->from_whom.uuid, self->uuid, (uint64_t)seq,
                            task) != 0)
        return true;
    _submit_interaction_score(proc, task, AT_SOCIAL_REPORTER_SCORE,
                              nmsg->from_whom.uuid, NULL);
    /* INFO, not debug: the reported side is the only place the pairing can be
     * seen from outside, and moderation_cohort.sh asserts on this line. */
    log_info(proc->logger, "Identity: report from peer %s staged\n", sender);
    return true;
}

/* Re-emit one peer_observed after its block state changed, so the app learns
 * (Phase 4 P4.1).
 *
 * THIS IS WHAT MADE A BLOCK VISIBLE AT ALL. handle_app_block wrote the record
 * and emitted nothing, and the app derives a peer's tier from its SCORE, which
 * a block does not touch — so a blocked peer went on rendering exactly as
 * before. The record was right and the UI was blind.
 *
 * Silent when the peer is unknown: a block may legitimately name a uuid this
 * node has never admitted, and there is nothing to re-emit for one. */
static void _reemit_peer_after_block(const process_t *proc,
                                     const char *peer_str)
{
    uuid_t peer_uuid;
    if (uuid_parse(peer_str, peer_uuid) != 0)
        return;
    public_identity_t pub;
    if (identity_find_peer_pub(proc, peer_uuid, &pub))
        identity_emit_peer_observed(proc, &pub);
}

/* App -> AT verb (AT_APP_BLOCK): locally block a peer. Payload {"peer":
 * "<uuid_str>"}. Purely local — records the peer in social_blocks so
 * identity_get_peer_tier clamps it to 0; no wire traffic, no reputation tx. */
static bool handle_app_block(const process_t *proc, directory_t *queues,
                             generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    if (!identity_is_local_app_verb(proc, nmsg))
        return identity_refuse_remote_app_verb(proc, nmsg, AT_APP_BLOCK);
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_peer = json_object_get(payload, "peer");
    if (!json_is_string(j_peer)) { json_decref(payload); return true; }
    char peer_str[UUID_STRING_LEN + 1];
    snprintf(peer_str, sizeof(peer_str), "%s", json_string_value(j_peer));
    json_decref(payload);

    /* Through the seam rather than writing the map here, so the handler and
     * the conformance path cannot diverge — and so persistence happens once,
     * in one place. */
    identity_block_peer(peer_str);
    log_info(proc->logger, "Identity: peer %s locally blocked\n", peer_str);
    _reemit_peer_after_block(proc, peer_str);
    return true;
}

/* App -> AT verb (AT_APP_UNBLOCK): lift a local block. Payload {"peer":
 * "<uuid_str>"}. Removes the record and re-emits peer_observed. Purely local —
 * the peer is told nothing, exactly as they were told nothing about the
 * block. */
static bool handle_app_unblock(const process_t *proc, directory_t *queues,
                               generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    if (!identity_is_local_app_verb(proc, nmsg))
        return identity_refuse_remote_app_verb(proc, nmsg, AT_APP_UNBLOCK);
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_peer = json_object_get(payload, "peer");
    if (!json_is_string(j_peer)) { json_decref(payload); return true; }
    char peer_str[UUID_STRING_LEN + 1];
    snprintf(peer_str, sizeof(peer_str), "%s", json_string_value(j_peer));
    json_decref(payload);

    identity_unblock_peer(peer_str);
    log_info(proc->logger, "Identity: peer %s unblocked\n", peer_str);
    _reemit_peer_after_block(proc, peer_str);
    return true;
}

/****************************
 * Feed posts (Increment 7, the "post to the feed" surface).
 *
 * A post is a signed, content-addressed feed item distributed by encrypted GROUP
 * MULTICAST (net_proc RECIPIENT_GROUP + group_encrypt + NET_CHAN_GROUP) and
 * gossip-forwarded a bounded number of hops. UNLIKE a DM, whose crypto_box
 * envelope authenticates the sender, a post is relayed by peers other than its
 * author, so authorship comes from a DETACHED Ed25519 SIGNATURE over the
 * canonical (author, seq, ts, required_tier, body) form (social/post.c), not
 * from the wire envelope. Inbound posts are signature-verified, TIER-GATED (drop
 * unless this node's view of the author's tier meets required_tier), content-id
 * DEDUPED in the app-content store, then emitted and gossip-forwarded (hops+1)
 * up to POST_MAX_HOPS. Confidentiality is the group key; non-repudiation is the
 * signature; replay is foreclosed by the content-id dedup (a replay carries an
 * already-seen id, and a new id cannot be minted without the author's key).
 ****************************/

/* AT -> app: surface one accepted post as PEER_POST_OBSERVED. @p author_uuid is
 * the signature-bound author. Mirrors identity_emit_dm. */
static int identity_emit_post(const uuid_t author_uuid, const char *post_id,
                              int64_t seq, double ts, int required_tier,
                              const char *body, const at_post_scope_t *scope)
{
    generic_msg_t msg = {0};
    msg.type = PEER_POST_OBSERVED;
    peer_post_msg_t *ext = AT_MSG_EXT(&msg, peer_post_msg_t);
    msg.size = sizeof(peer_post_msg_t);
    memcpy(ext->peer_uuid, author_uuid, 16);
    snprintf(ext->post_id, sizeof(ext->post_id),
             "%s", post_id != NULL ? post_id : "");
    ext->seq = seq;
    ext->ts = ts;
    ext->required_tier = required_tier;
    at_post_bound_body(body, ext->body,
                       sizeof(ext->body));
    if (scope != NULL) {
        snprintf(ext->community, sizeof(ext->community), "%s", scope->community);
        at_post_scope_labels_joined(scope, ext->labels, sizeof(ext->labels));
    }
    return messaging_send(AT_MAIN_QUEUE, PEER_POST_OBSERVED, &msg, false);
}

/* Whether @p id_hex is in the feed-post dedup ring, WITHOUT recording it: what
 * a digest is compared against. Own locking. */
static bool _post_seen_peek(const char *id_hex)
{
    bool seen = false;
    pthread_mutex_lock(&social_state.lock);
    for (size_t i = 0; i < social_state.seen_post_count && !seen; i++)
        seen = strncmp(social_state.seen_post_ids[i], id_hex,
                       AT_POST_ID_HEX_LEN) == 0;
    pthread_mutex_unlock(&social_state.lock);
    return seen;
}

/* Keep @p env (a post's wire envelope, borrowed) in @p store for backfill,
 * under content id @p id_hex. Own locking. */
static void _store_for_backfill(post_store_t *store, const char *id_hex,
                                double ts, const uuid_t author, json_t *env)
{
    if (env == NULL)
        return;
    char *compact = json_dumps(env, JSON_COMPACT);
    if (compact == NULL)
        return;
    pthread_mutex_lock(&social_state.lock);
    (void)post_store_put(store, id_hex, ts, author, compact);
    pthread_mutex_unlock(&social_state.lock);
    free(compact);
}

/* App-content dedup: return true if @p id_hex was ALREADY recorded (caller
 * drops), else record it in the bounded ring and return false. Own locking.
 * This is the app store; net_proc's transport dedup ring is a different thing. */
static bool _post_seen_or_record(const char *id_hex)
{
    bool seen = false;
    pthread_mutex_lock(&social_state.lock);
    for (size_t i = 0; i < social_state.seen_post_count; i++) {
        if (strncmp(social_state.seen_post_ids[i], id_hex, AT_POST_ID_HEX_LEN) == 0) {
            seen = true;
            break;
        }
    }
    if (!seen) {
        snprintf(social_state.seen_post_ids[social_state.seen_post_next],
                 AT_POST_ID_HEX_LEN + 1, "%s", id_hex);
        social_state.seen_post_next =
            (social_state.seen_post_next + 1) % POST_DEDUP_CAP;
        if (social_state.seen_post_count < POST_DEDUP_CAP)
            social_state.seen_post_count++;
    }
    pthread_mutex_unlock(&social_state.lock);
    return seen;
}

/* Record the most-recent post from @p author_str for the conformance/
 * observability seam (identity_get_last_post). NOT roster state. Own locking. */
static void _last_post_store(const char *author_str, const char *post_id,
                            int64_t seq, double ts, int required_tier,
                            const char *body, const at_post_scope_t *scope)
{
    char bounded[AT_POST_BODY_MAX + 1];
    at_post_bound_body(body, bounded, sizeof(bounded));
    json_t *env = json_object();
    if (env == NULL) return;
    json_t *labels = json_array();
    for (uint8_t i = 0; labels != NULL && scope != NULL && i < scope->n_labels; i++)
        json_array_append_new(labels, json_string(scope->labels[i]));
    if (labels == NULL
        || json_object_set_new(env, "post_id", json_string(post_id)) != 0
        || json_object_set_new(env, "seq", json_integer((json_int_t)seq)) != 0
        || json_object_set_new(env, "ts", json_real(ts)) != 0
        || json_object_set_new(env, "tier", json_integer(required_tier)) != 0
        || json_object_set_new(env, "body", json_string(bounded)) != 0
        || json_object_set_new(env, "community",
                               json_string(scope != NULL ? scope->community : "")) != 0
        || json_object_set_new(env, "labels", labels) != 0) {
        json_decref(env);
        return;
    }
    char *compact = json_dumps(env, JSON_COMPACT);
    json_decref(env);
    if (compact == NULL) return;
    size_t len = strlen(compact);
    char *dup = smrt_create(len + 1);
    if (dup == NULL) { free(compact); return; }
    memcpy(dup, compact, len + 1);
    free(compact);
    data_t *dat = string_data(dup, len + 1);
    if (dat == NULL) { smrt_deref(dup); return; }
    pthread_mutex_lock(&social_state.lock);
    map_set(&social_state.last_post_map, (map_key_t)author_str, dat);
    pthread_mutex_unlock(&social_state.lock);
}

/* Encrypted group multicast of one signed post. Builds the wire JSON payload and
 * hands it to network with group_multicast=true (RECIPIENT_GROUP). encrypt=false:
 * the group path does its own group_encrypt; the crypto_box peer path is not
 * used. Used for BOTH the initial publish (hops=0) and a gossip re-forward. */
static int _multicast_post(const process_t *proc, const uuid_t author_uuid,
                           const char *author_pk_hex, int64_t seq, double ts,
                           uint8_t required_tier, const char *body,
                           const at_post_scope_t *scope, const char *sig_hex,
                           int hops)
{
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_POST;
    out.info.net_msg.encrypt = false;
    out.info.net_msg.group_multicast = true;
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = at_post_to_json_scoped(author_uuid, author_pk_hex, seq, ts,
                                         required_tier, body, scope, sig_hex,
                                         hops);
    if (env == NULL) return -1;
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    /* Bounded retry, not a bare messaging_send: a multicast queued behind a
     * Paxos burst used to vanish on EAGAIN while the caller logged it as sent
     * (moderation cohort run 6: "published post" on the author, no group
     * multicast on its network process, nothing on either peer). */
    return identity_send_to_network(proc, &out, "a feed post", "the group");
}

/* App -> AT verb (AT_APP_PUBLISH_POST): the operator publishes a feed post.
 * Payload {"body": "<body>", "tier": <int 0..4>}. Stamp our own post seq, set
 * ts=now, sign the canonical form with our identity key, record the content id in
 * the dedup store (so a loopback copy is dropped), and group-multicast it. The
 * core does NOT echo the post back — the app echoes it locally. */
static bool handle_app_publish_post(const process_t *proc, directory_t *queues,
                                    generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_body = json_object_get(payload, "body");
    json_t *j_tier = json_object_get(payload, "tier");
    char body[AT_POST_BODY_MAX + 1];
    at_post_bound_body(json_is_string(j_body) ? json_string_value(j_body) : "",
                       body, sizeof(body));
    int required_tier = json_is_integer(j_tier)
                            ? (int)json_integer_value(j_tier) : 0;
    /* A post in a community's name (Phase 4): the community and the author's
     * own labels, which the signature will cover. Refused whole rather than
     * trimmed: a label the author asked for and did not get would be a post
     * the author did not write. */
    at_post_scope_t scope;
    memset(&scope, 0, sizeof(scope));
    json_t *j_comm = json_object_get(payload, "community");
    json_t *j_labels = json_object_get(payload, "labels");
    bool scope_ok = true;
    if (json_is_string(j_comm) && json_string_value(j_comm)[0] != '\0') {
        size_t clen = strlen(json_string_value(j_comm));
        scope_ok = clen <= AT_POST_COMMUNITY_MAX;
        if (scope_ok)
            memcpy(scope.community, json_string_value(j_comm), clen);
    }
    if (scope_ok && j_labels != NULL && json_array_size(j_labels) > 0) {
        size_t i;
        json_t *v;
        scope_ok = json_is_array(j_labels)
                   && json_array_size(j_labels) <= AT_POST_LABELS_MAX;
        json_array_foreach(j_labels, i, v) {
            if (!scope_ok) break;
            scope_ok = json_is_string(v) && at_post_label_valid(json_string_value(v));
            if (scope_ok)
                snprintf(scope.labels[scope.n_labels++], AT_POST_LABEL_MAX + 1, "%s",
                         json_string_value(v));
        }
    }
    json_decref(payload);
    at_post_scope_normalize(&scope);
    if (!scope_ok || !at_post_scope_valid(&scope)) {
        log_warn(proc->logger, "Identity: publish_post with a malformed community "
                 "or labels (labels need a community; [a-z0-9_-], at most %d), "
                 "refusing\n", AT_POST_LABELS_MAX);
        return true;
    }
    if (required_tier < AT_POST_TIER_MIN) required_tier = AT_POST_TIER_MIN;
    if (required_tier > AT_POST_TIER_MAX) required_tier = AT_POST_TIER_MAX;

    const identity_t *self = identity_self_identity(proc);
    if (self == NULL) {
        log_debug(proc->logger,
                  "Identity: publish_post but self identity unresolved; skipping\n");
        return true;
    }

    pthread_mutex_lock(&social_state.lock);
    int64_t seq = ++social_state.post_seq;
    pthread_mutex_unlock(&social_state.lock);
    double ts = (double)time(NULL);

    char sig_hex[AT_POST_SIG_HEX_LEN + 1];
    if (at_post_sign_scoped(self->signature.private, self->uuid, seq, ts,
                            (uint8_t)required_tier, body, &scope, sig_hex) != 0) {
        log_warn(proc->logger, "Identity: publish_post: signing failed\n");
        return true;
    }
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    sodium_bin2hex(pk_hex, sizeof(pk_hex), self->signature.public,
                   crypto_sign_PUBLICKEYBYTES);
    char id_hex[AT_POST_ID_HEX_LEN + 1];
    if (at_post_content_id_scoped(self->uuid, seq, ts, (uint8_t)required_tier,
                                  body, &scope, id_hex) != 0)
        return true;
    /* Record BEFORE sending so a loopback copy of our own multicast is deduped
     * rather than re-emitted. */
    (void)_post_seen_or_record(id_hex);
    /* Kept for backfill: a peer that was not on the segment asks for it later
     * (store-and-forward). */
    {
        json_t *own = at_post_to_json_scoped(self->uuid, pk_hex, seq, ts,
                                             (uint8_t)required_tier, body, &scope,
                                             sig_hex, 0);
        _store_for_backfill(&social_state.feed_store, id_hex, ts, self->uuid, own);
        json_decref(own);
    }

    if (_multicast_post(proc, self->uuid, pk_hex, seq, ts,
                        (uint8_t)required_tier, body, &scope, sig_hex, 0) != 0)
        return true; /* identity_send_to_network already said the post did not go */
    char self_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(self->uuid, self_str);
    if (scope.community[0] != '\0')
        log_info(proc->logger, "Identity: published post seq=%lld tier=%d in %s "
                 "with %u label(s) (%s)\n", (long long)seq, required_tier,
                 scope.community, (unsigned)scope.n_labels, id_hex);
    else
        log_info(proc->logger, "Identity: published post seq=%lld tier=%d (%s)\n",
                 (long long)seq, required_tier, id_hex);
    return true;
}

/* Handler: an inbound group-multicast post. Verify the author's signature (bound
 * to the author's key: for a KNOWN peer the stored signing key MUST match the
 * carried author_pk — an impersonation guard; an unknown author is accepted
 * best-effort against the carried key, which is how a post reaches one hop beyond
 * the author's cohort). Then TIER-GATE, content-id DEDUP, emit, and gossip-
 * forward (hops+1) while under POST_MAX_HOPS. */
/* The one inbound path for a feed post, whether it came as the group multicast
 * (handle_post, @p via_group true) or as a directed backfill after the fact
 * (handle_post_backfill, false): verify, key binding, tier gate, dedup, store,
 * emit. Two things only the group channel does. It records co-membership (a
 * backfilled copy did not decrypt with our group key, so it proves nothing
 * about where its author is), and it relays (a backfill is terminal, or every
 * heal would re-flood the group). @p payload is borrowed. */
static bool _ingest_post(const process_t *proc, json_t *payload, bool via_group)
{
    uuid_t author;
    char author_pk[AT_POST_SIG_HEX_LEN + 1];
    char sig_hex[AT_POST_SIG_HEX_LEN + 1];
    char body[AT_POST_BODY_MAX + 1];
    int64_t seq = 0;
    double ts = 0.0;
    uint8_t tier = 0;
    int hops = 0;
    at_post_scope_t scope;
    if (at_post_from_json_scoped(payload, author, author_pk, &seq, &ts, &tier,
                                 body, sizeof(body), &scope, sig_hex, &hops) != 0) {
        log_warn(proc->logger, "Identity: peer_post malformed, refusing\n");
        return true;
    }

    char author_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(author, author_str);

    /* Resolve the key to verify against, binding uuid <-> key where we can. */
    unsigned char verify_pk[crypto_sign_PUBLICKEYBYTES];
    public_identity_t known;
    bool have_known = identity_find_peer_pub(proc, author, &known);
    if (have_known) {
        char known_pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
        sodium_bin2hex(known_pk_hex, sizeof(known_pk_hex),
                       known.signature.public, crypto_sign_PUBLICKEYBYTES);
        if (strncmp(known_pk_hex, author_pk, crypto_sign_PUBLICKEYBYTES * 2) != 0) {
            log_warn(proc->logger,
                     "Identity: peer_post from %s: author_pk != known key, "
                     "dropping (impersonation)\n", author_str);
            return true;
        }
        memcpy(verify_pk, known.signature.public, sizeof(verify_pk));
    } else {
        size_t bin_len = 0;
        if (sodium_hex2bin(verify_pk, sizeof(verify_pk), author_pk,
                           strlen(author_pk), NULL, &bin_len, NULL) != 0
            || bin_len != sizeof(verify_pk)) {
            log_warn(proc->logger,
                     "Identity: peer_post from %s: bad author_pk, dropping\n",
                     author_str);
            return true;
        }
    }

    if (!at_post_verify_scoped(verify_pk, author, seq, ts, tier, body, &scope,
                               sig_hex)) {
        log_warn(proc->logger,
                 "Identity: peer_post from %s: BAD SIGNATURE, dropping\n",
                 author_str);
        return true;
    }

    /* Ground-truth co-membership for the "in your group" indicator: this post
     * arrived over the group channel and DECRYPTED with our group key, and its
     * author signature verified — so the author shares our group right now
     * (posts flow), whether or not we hold a fresh group_key_update advertising
     * our uuid from them. Those advertisements are sparse and timing-dependent:
     * the winner of a merge tiebreak can be left holding only the loser's STALE
     * pre-adoption advertisement, so its badge for that peer never lit even
     * though posts arrive. Record our own current group as "theirs" so the
     * swap-robust check (both halves == our current uuid) passes. Recorded
     * BEFORE the tier-gate/dedup: decrypt + signature already prove membership,
     * independent of whether we ultimately surface this particular post.
     * Only for the group channel: a backfill arrived directed. */
    if (via_group) {
        char ours_now[UUID_STRING_LEN + 1];
        uuid_unparse_lower(proc->protocol.group.uuid, ours_now);
        _record_peer_group_uuid(proc, author_str, ours_now);
    }

    /* Tier-gate: deliver only if this node's view of the author's tier meets the
     * post's required audience floor. An unknown author reads as tier 0, so only
     * their public posts pass. */
    int author_tier = identity_get_peer_tier(author);
    if (author_tier < (int)tier) {
        log_debug(proc->logger,
                  "Identity: peer_post from %s tier-gated (need %d, have %d)\n",
                  author_str, (int)tier, author_tier);
        return true;
    }

    /* Content-id dedup (the app-content store): compute the id from the verified
     * canonical and drop a repeat before emitting or re-forwarding. */
    char id_hex[AT_POST_ID_HEX_LEN + 1];
    if (at_post_content_id_scoped(author, seq, ts, tier, body, &scope, id_hex) != 0)
        return true;
    if (_post_seen_or_record(id_hex)) {
        log_debug(proc->logger, "Identity: peer_post %s already seen, dropping\n",
                  id_hex);
        return true;
    }
    /* Kept for backfill, the blocked author's too: a personal block governs
     * what WE see, not what our neighbours may (the reason the relay below
     * still runs). */
    _store_for_backfill(&social_state.feed_store, id_hex, ts, author, payload);

    /* A blocked author's post is HIDDEN, not dropped (Phase 4 P4.1), and the
     * relay below still runs.
     *
     * THE TIER-GATE ABOVE CANNOT DO THIS, which is the defect this increment
     * is named for: a PUBLIC post declares tier 0, a blocked peer clamps to
     * tier 0, and `0 < 0` is false — so every public post from a blocked peer
     * arrived. The comparison is right; it answers "does this author clear the
     * audience floor", and tier 0 is a floor everyone clears. A block is a
     * REFUSAL, not a low measurement, so it is asked as its own question.
     *
     * HIDE rather than DROP, and KEEP THE RELAY, because a post is GOSSIPED: a
     * personal block governs what WE see, not what our neighbours may see.
     * Withholding a community's feed traffic because one member muted the
     * author is community content POLICY — SOCIAL_APP_PLAN.md's box 5, which is
     * out of scope here and must stay open. Continuing to relay also means a
     * blocked peer cannot detect the block by watching propagation.
     *
     * Placed AFTER the dedup ring records the id, so a hidden post is not
     * re-considered on a second copy and the forward still happens at most
     * once. */
    if (_is_blocked(author)) {
        log_debug(proc->logger,
                  "Identity: peer_post %s from %s hidden (locally blocked); "
                  "still relaying\n", id_hex, author_str);
        if (via_group && hops < POST_MAX_HOPS)
            _multicast_post(proc, author, author_pk, seq, ts, tier, body,
                            &scope, sig_hex, hops + 1);
        return true;
    }

    /* A post in a community's name is shown here as any post is. The
     * community's policy is applied by the APP, which alone can verify it, and
     * a reader who does not follow the community sees the post unmoderated
     * (Phase 4): the core neither hides nor withholds by policy. */
    _last_post_store(author_str, id_hex, seq, ts, (int)tier, body, &scope);
    identity_emit_post(author, id_hex, seq, ts, (int)tier, body, &scope);
    /* A backfilled acceptance is rare (one per post missed across a split)
     * and is the only evidence the heal delivered it when no app is attached
     * to see the event, so it is said at INFO. The group path stays at DEBUG:
     * it fires for every post. */
    if (via_group)
        log_debug(proc->logger, "Identity: post %s from %s accepted (hops=%d)\n",
                  id_hex, author_str, hops);
    else
        log_info(proc->logger,
                 "Identity: post %s from %s accepted (hops=%d, backfilled)\n",
                 id_hex, author_str, hops);

    /* Gossip forward: relay one more hop while under the reach bound. The dedup
     * ring above guarantees we forward a given post at most once. A backfill is
     * never relayed. */
    if (via_group && hops < POST_MAX_HOPS)
        _multicast_post(proc, author, author_pk, seq, ts, tier, body, &scope,
                        sig_hex, hops + 1);
    return true;
}

static bool handle_post(const process_t *proc, directory_t *queues,
                        generic_msg_t *msg)
{
    (void)queues;
    json_t *payload = NULL;
    if (net_msg_unpack_json(&msg->info.net_msg, &payload) != 0 || payload == NULL)
        return true;
    _ingest_post(proc, payload, true);
    json_decref(payload);
    return true;
}

/* Conformance/observability twin of identity_get_last_dm: the most-recent post
 * this node accepted from @p uuid_str (the AUTHOR). Returns true and fills the
 * outputs if present. Mirrors Python get_last_post. */
bool identity_get_last_post(const char *uuid_str, char *post_id_buf,
                           size_t post_id_sz, char *body_buf, size_t body_sz,
                           int64_t *seq_out, int *tier_out)
{
    if (!social_state.initialized || uuid_str == NULL) return false;
    bool found = false;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(&social_state.last_post_map, (map_key_t)uuid_str, &dat) == 0
        && dat != NULL) {
        char *js = NULL;
        if (data_string_ptr(dat, &js) == 0 && js != NULL) {
            json_error_t jerr;
            json_t *obj = json_loads(js, 0, &jerr);
            if (obj != NULL) {
                json_t *j_id   = json_object_get(obj, "post_id");
                json_t *j_seq  = json_object_get(obj, "seq");
                json_t *j_tier = json_object_get(obj, "tier");
                json_t *j_body = json_object_get(obj, "body");
                if (post_id_buf != NULL && post_id_sz > 0)
                    snprintf(post_id_buf, post_id_sz, "%s",
                             json_is_string(j_id) ? json_string_value(j_id) : "");
                if (body_buf != NULL && body_sz > 0)
                    snprintf(body_buf, body_sz, "%s",
                             json_is_string(j_body) ? json_string_value(j_body) : "");
                if (seq_out != NULL)
                    *seq_out = json_is_integer(j_seq)
                                   ? (int64_t)json_integer_value(j_seq) : 0;
                if (tier_out != NULL)
                    *tier_out = json_is_integer(j_tier)
                                    ? (int)json_integer_value(j_tier) : 0;
                json_decref(obj);
                found = true;
            }
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return found;
}

/* The scope of the most-recent post accepted from @p uuid_str (Phase 4). */
bool identity_get_last_post_scope(const char *uuid_str, char *community_buf,
                                  size_t community_sz, char *labels_buf,
                                  size_t labels_sz)
{
    if (community_buf != NULL && community_sz > 0) community_buf[0] = '\0';
    if (labels_buf != NULL && labels_sz > 0) labels_buf[0] = '\0';
    if (!social_state.initialized || uuid_str == NULL) return false;
    json_t *obj = _business_map_load_json(&social_state.last_post_map, uuid_str);
    if (obj == NULL) return false;
    const char *c = json_string_value(json_object_get(obj, "community"));
    if (community_buf != NULL && community_sz > 0)
        snprintf(community_buf, community_sz, "%s", c != NULL ? c : "");
    json_t *arr = json_object_get(obj, "labels");
    size_t off = 0, i;
    json_t *v;
    if (labels_buf != NULL && labels_sz > 0 && json_is_array(arr)) {
        json_array_foreach(arr, i, v) {
            int n = snprintf(labels_buf + off, labels_sz - off, "%s%s", i ? "," : "",
                             json_string_value(v) ? json_string_value(v) : "");
            if (n < 0 || (size_t)n >= labels_sz - off) break;
            off += (size_t)n;
        }
    }
    json_decref(obj);
    return true;
}

/****************************
 * Businesses (Phase 3 P3.2, the "businesses near me" surface).
 *
 * A business is an Ethne polity; its PAGE is an opaque, self-verifying Ethne
 * bundle ({page, delegation} proving polity-root -> envoy -> page). The core
 * NEVER parses that bundle — it carries it as bytes and the app verifies it.
 * What the core does own is the AT layer: a detached Ed25519 signature binding
 * WHO advertised, HOW satisfied they are, and WHICH page bytes they meant.
 *
 * THE CUSTOMER GATE is the whole mechanism. A business ad is never relayed the
 * way a post is. Only a CUSTOMER carries a business's page, and a customer does
 * not forward someone else's ad — it re-advertises from its own cache in the
 * FIRST PERSON, signed with its own key and its own satisfaction. So:
 *   - a business's reach is exactly the sum of its customers' voices;
 *   - distribution and reputation are the same fact;
 *   - an unhappy customer simply clears its edge and goes quiet. Silence is the
 *     only negative signal, so there is nothing to brigade with.
 *
 * The reader ranks what arrives by its OWN tie strength to each advertiser
 * (app-side), which is why a stranger's enthusiasm is worth almost nothing and a
 * friend's counts — the trust path and the delivery path are the same edge.
 ****************************/

/* Ad-content dedup: return true if @p id_hex was ALREADY recorded (caller
 * drops), else record it in the bounded ring and return false. Own locking.
 * The twin of _post_seen_or_record; also what forecloses replay. */
static bool _business_ad_seen_or_record(const char *id_hex)
{
    bool seen = false;
    pthread_mutex_lock(&social_state.lock);
    for (size_t i = 0; i < social_state.seen_business_ad_count; i++) {
        if (strncmp(social_state.seen_business_ads[i], id_hex,
                    AT_BUSINESS_AD_ID_HEX_LEN) == 0) {
            seen = true;
            break;
        }
    }
    if (!seen) {
        snprintf(social_state.seen_business_ads[social_state.seen_business_ad_next],
                 AT_BUSINESS_AD_ID_HEX_LEN + 1, "%s", id_hex);
        social_state.seen_business_ad_next =
            (social_state.seen_business_ad_next + 1) % BUSINESS_AD_DEDUP_CAP;
        if (social_state.seen_business_ad_count < BUSINESS_AD_DEDUP_CAP)
            social_state.seen_business_ad_count++;
    }
    pthread_mutex_unlock(&social_state.lock);
    return seen;
}

/* Store @p obj (a NEW reference, consumed) as compact JSON under @p key in
 * @p map. Caller holds no lock; this takes social_state.lock itself. Shared by the
 * customer and page stores, which both keep small JSON records. */
static void _business_map_store_json(map_t *map, const char *key, json_t *obj)
{
    if (obj == NULL) return;
    char *compact = json_dumps(obj, JSON_COMPACT);
    json_decref(obj);
    if (compact == NULL) return;
    size_t len = strlen(compact);
    char *dup = smrt_create(len + 1);
    if (dup == NULL) { free(compact); return; }
    memcpy(dup, compact, len + 1);
    free(compact);
    data_t *dat = string_data(dup, len + 1);
    if (dat == NULL) { smrt_deref(dup); return; }
    pthread_mutex_lock(&social_state.lock);
    map_set(map, (map_key_t)key, dat);
    pthread_mutex_unlock(&social_state.lock);
}

/* Load the JSON record stored under @p key in @p map, or NULL. Caller decrefs.
 * Takes social_state.lock itself. */
static json_t *_business_map_load_json(map_t *map, const char *key)
{
    json_t *obj = NULL;
    pthread_mutex_lock(&social_state.lock);
    data_t *dat = NULL;
    if (map_get(map, (map_key_t)key, &dat) == 0 && dat != NULL) {
        char *js = NULL;
        if (data_string_ptr(dat, &js) == 0 && js != NULL) {
            json_error_t jerr;
            obj = json_loads(js, 0, &jerr);
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    return obj;
}

/* THE GATE: is this node a customer of @p did? Fills the cached bundle/seq/sat
 * when it is. A node with no customer edge for a business never carries its
 * page — that is the entire relay policy. */
static bool _business_is_customer(const char *did, int *sat_out,
                                  char *bundle_out, size_t bundle_sz,
                                  int64_t *seq_out)
{
    json_t *obj = _business_map_load_json(&social_state.business_customers, did);
    if (obj == NULL) return false;
    json_t *j_sat    = json_object_get(obj, "sat");
    json_t *j_seq    = json_object_get(obj, "seq");
    json_t *j_bundle = json_object_get(obj, "bundle");
    if (sat_out != NULL)
        *sat_out = json_is_integer(j_sat) ? (int)json_integer_value(j_sat) : 0;
    if (seq_out != NULL)
        *seq_out = json_is_integer(j_seq) ? (int64_t)json_integer_value(j_seq) : 0;
    if (bundle_out != NULL && bundle_sz > 0)
        at_business_bound_bundle(json_is_string(j_bundle)
                                     ? json_string_value(j_bundle) : "",
                                 bundle_out, bundle_sz);
    json_decref(obj);
    return true;
}

/* Merge one accepted ad into the learned page store. The NEWEST page wins by
 * seq, but the endorser is recorded either way: a customer still vouches even
 * when it is carrying a page version we have already bettered. Own locking (via
 * the load/store helpers). */
static void _business_page_store(const char *did, const char *bundle,
                                 int64_t seq, double ts,
                                 const char *advertiser_str, int sat)
{
    json_t *rec = _business_map_load_json(&social_state.business_pages, did);
    if (rec == NULL) {
        /* Bound the number of distinct businesses we will hold pages for, so
         * unsolicited ads cannot grow this map without limit. */
        pthread_mutex_lock(&social_state.lock);
        size_t held = map_size(&social_state.business_pages);
        pthread_mutex_unlock(&social_state.lock);
        if (held >= BUSINESS_PAGE_CAP) return;
        rec = json_object();
        if (rec == NULL) return;
        if (json_object_set_new(rec, "endorsers", json_object()) != 0) {
            json_decref(rec);
            return;
        }
        if (json_object_set_new(rec, "seq", json_integer(-1)) != 0) {
            json_decref(rec);
            return;
        }
    }

    json_t *j_seq = json_object_get(rec, "seq");
    int64_t held_seq = json_is_integer(j_seq) ? (int64_t)json_integer_value(j_seq) : -1;
    if (seq >= held_seq) {
        char bnd[AT_BUSINESS_BUNDLE_MAX + 1];
        at_business_bound_bundle(bundle, bnd, sizeof(bnd));
        if (json_object_set_new(rec, "bundle", json_string(bnd)) != 0
            || json_object_set_new(rec, "seq", json_integer((json_int_t)seq)) != 0
            || json_object_set_new(rec, "ts", json_real(ts)) != 0) {
            json_decref(rec);
            return;
        }
    }

    /* The advertiser's standing vouch. A business's own ad (SAT_SELF) is NOT an
     * endorsement — self-vouching is free, and recording it would let a business
     * manufacture its own social proof. */
    if (sat != AT_BUSINESS_SAT_SELF && advertiser_str != NULL) {
        json_t *endorsers = json_object_get(rec, "endorsers");
        if (!json_is_object(endorsers)) {
            endorsers = json_object();
            if (json_object_set_new(rec, "endorsers", endorsers) != 0) {
                json_decref(rec);
                return;
            }
        }
        json_object_set_new(endorsers, advertiser_str, json_integer(sat));
    }

    _business_map_store_json(&social_state.business_pages, did, rec);
}

/* AT -> app: surface one accepted business ad as PEER_BUSINESS_AD_OBSERVED.
 * @p advertiser_uuid is the signature-bound advertiser. Mirrors
 * identity_emit_post. */
static int identity_emit_business_ad(const uuid_t advertiser_uuid,
                                     const char *did, const char *ad_id,
                                     int satisfaction, int64_t seq, double ts,
                                     const char *bundle)
{
    generic_msg_t msg = {0};
    msg.type = PEER_BUSINESS_AD_OBSERVED;
    peer_business_ad_msg_t *ext = AT_MSG_EXT(&msg, peer_business_ad_msg_t);
    msg.size = sizeof(peer_business_ad_msg_t);
    memcpy(ext->peer_uuid, advertiser_uuid, 16);
    at_business_bound_did(did, ext->polity,
                          sizeof(ext->polity));
    snprintf(ext->ad_id,
             sizeof(ext->ad_id), "%s",
             ad_id != NULL ? ad_id : "");
    ext->satisfaction = satisfaction;
    ext->seq = seq;
    ext->ts = ts;
    at_business_bound_bundle(bundle, ext->bundle,
                             sizeof(ext->bundle));
    return messaging_send(AT_MAIN_QUEUE, PEER_BUSINESS_AD_OBSERVED, &msg, false);
}

/* Encrypted group multicast of one signed business ad. Same shape as
 * _multicast_post (RECIPIENT_GROUP + group_encrypt), minus the hop count: every
 * ad is first-person, so there is nothing to forward and nothing to count. */
static int _multicast_business_ad(const process_t *proc,
                                  const uuid_t advertiser_uuid,
                                  const char *advertiser_pk_hex,
                                  const char *did, uint8_t satisfaction,
                                  int64_t seq, double ts, const char *bundle,
                                  const char *sig_hex)
{
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_BUSINESS_AD;
    out.info.net_msg.encrypt = false;
    out.info.net_msg.group_multicast = true;
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = at_business_ad_to_json(advertiser_uuid, advertiser_pk_hex, did,
                                         satisfaction, seq, ts, bundle, sig_hex);
    if (env == NULL) return -1;
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    /* Bounded retry, not a bare messaging_send: a multicast queued behind a
     * Paxos burst used to vanish on EAGAIN while the caller logged it as sent
     * (moderation cohort run 6: "published post" on the author, no group
     * multicast on its network process, nothing on either peer). */
    return identity_send_to_network(proc, &out, "a business ad", "the group");
}

/* Speak for a business IN THE FIRST PERSON: sign the canonical ad with THIS
 * node's key and group-multicast it. @p satisfaction is our own 0..4 rating as a
 * customer, or AT_BUSINESS_SAT_SELF when this node IS the business. Shared by
 * the advertise verb, the set-customer verb, and the customer-gated
 * re-advertisement on the inbound path — which is why there is no "relay": all
 * three are this same act. Returns 0 on success. */
static int _business_advertise(const process_t *proc, const char *did,
                               uint8_t satisfaction, int64_t seq,
                               const char *bundle)
{
    const identity_t *self = identity_self_identity(proc);
    if (self == NULL) {
        log_debug(proc->logger,
                  "Identity: business advertise but self identity unresolved; skipping\n");
        return -1;
    }
    double ts = (double)time(NULL);
    char sig_hex[AT_BUSINESS_AD_SIG_HEX_LEN + 1];
    if (at_business_ad_sign(self->signature.private, self->uuid, did,
                            satisfaction, seq, ts, bundle, sig_hex) != 0) {
        log_warn(proc->logger, "Identity: business ad signing failed\n");
        return -1;
    }
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    sodium_bin2hex(pk_hex, sizeof(pk_hex), self->signature.public,
                   crypto_sign_PUBLICKEYBYTES);
    char id_hex[AT_BUSINESS_AD_ID_HEX_LEN + 1];
    if (at_business_ad_content_id(self->uuid, did, satisfaction, seq, ts, bundle,
                                  id_hex) != 0)
        return -1;
    /* Record BEFORE sending so a loopback copy of our own multicast is deduped
     * rather than re-emitted (and, crucially, not re-advertised in a loop). */
    (void)_business_ad_seen_or_record(id_hex);

    _multicast_business_ad(proc, self->uuid, pk_hex, did, satisfaction, seq, ts,
                           bundle, sig_hex);
    log_info(proc->logger,
             "Identity: advertised business %s seq=%lld sat=%u (%s)\n", did,
             (long long)seq, (unsigned)satisfaction, id_hex);
    return 0;
}

/* Write (or overwrite) THIS node's customer edge to @p did: the record that
 * authorizes this node to CARRY the business's page. Pure state — it does NOT
 * advertise, which is what lets the conformance fixture install an edge without
 * putting an ad on the wire. Returns false only on allocation failure. */
static bool _business_customer_record(const char *did, int sat,
                                      const char *bundle, int64_t seq)
{
    json_t *rec = json_object();
    if (rec == NULL) return false;
    if (json_object_set_new(rec, "sat", json_integer(sat)) != 0
        || json_object_set_new(rec, "since", json_real((double)time(NULL))) != 0
        || json_object_set_new(rec, "bundle", json_string(bundle)) != 0
        || json_object_set_new(rec, "seq", json_integer((json_int_t)seq)) != 0) {
        json_decref(rec);
        return false;
    }
    _business_map_store_json(&social_state.business_customers, did, rec);
    return true;
}

/* App -> AT verb (AT_APP_ADVERTISE_BUSINESS): the envoy operator publishes THIS
 * node's own business page. Payload {"polity":"<did>","bundle":"<json>",
 * "seq":<int>}. The bundle is opaque here — the app already built and signed it
 * through Ethne, and any reader verifies it the same way. */
static bool handle_app_advertise_business(const process_t *proc,
                                          directory_t *queues,
                                          generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_did    = json_object_get(payload, "polity");
    json_t *j_bundle = json_object_get(payload, "bundle");
    json_t *j_seq    = json_object_get(payload, "seq");
    char did[AT_BUSINESS_DID_MAX + 1];
    at_business_bound_did(json_is_string(j_did) ? json_string_value(j_did) : "",
                          did, sizeof(did));
    char bundle[AT_BUSINESS_BUNDLE_MAX + 1];
    at_business_bound_bundle(json_is_string(j_bundle)
                                 ? json_string_value(j_bundle) : "",
                             bundle, sizeof(bundle));
    int64_t seq = json_is_integer(j_seq) ? (int64_t)json_integer_value(j_seq) : 0;
    json_decref(payload);

    if (did[0] == '\0' || bundle[0] == '\0') {
        log_warn(proc->logger,
                 "Identity: advertise_business without polity/bundle, refusing\n");
        return true;
    }
    (void)_business_advertise(proc, did, AT_BUSINESS_SAT_SELF, seq, bundle);
    return true;
}

/* App -> AT verb (AT_APP_SET_CUSTOMER): declare, update or clear this node's
 * customer edge to a business. Payload {"polity":"<did>","satisfaction":<0..4>,
 * "bundle":"<json>","seq":<int>}, or satisfaction < 0 to clear.
 *
 * Declaring a customer edge is what authorizes this node to CARRY the page: on
 * set we cache the bundle and immediately advertise it in the first person. On
 * clear we remove the edge and say nothing further — an unhappy customer
 * publishes no negative, it just stops speaking for the business. */
static bool handle_app_set_customer(const process_t *proc, directory_t *queues,
                                    generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_did    = json_object_get(payload, "polity");
    json_t *j_sat    = json_object_get(payload, "satisfaction");
    json_t *j_bundle = json_object_get(payload, "bundle");
    json_t *j_seq    = json_object_get(payload, "seq");
    char did[AT_BUSINESS_DID_MAX + 1];
    at_business_bound_did(json_is_string(j_did) ? json_string_value(j_did) : "",
                          did, sizeof(did));
    int sat = json_is_integer(j_sat) ? (int)json_integer_value(j_sat) : -1;
    char bundle[AT_BUSINESS_BUNDLE_MAX + 1];
    at_business_bound_bundle(json_is_string(j_bundle)
                                 ? json_string_value(j_bundle) : "",
                             bundle, sizeof(bundle));
    int64_t seq = json_is_integer(j_seq) ? (int64_t)json_integer_value(j_seq) : 0;
    json_decref(payload);

    if (did[0] == '\0') {
        log_warn(proc->logger, "Identity: set_customer without polity, refusing\n");
        return true;
    }

    if (sat < 0) {
        pthread_mutex_lock(&social_state.lock);
        map_remove(&social_state.business_customers, (map_key_t)did);
        pthread_mutex_unlock(&social_state.lock);
        log_info(proc->logger,
                 "Identity: cleared customer edge to %s (going quiet)\n", did);
        return true;
    }
    if (sat > AT_BUSINESS_SAT_MAX) sat = AT_BUSINESS_SAT_MAX;

    /* No bundle supplied? Fall back to the page we already learned, so a person
     * can declare "I'm a customer here" straight from a page that reached them
     * through someone else. */
    if (bundle[0] == '\0') {
        json_t *rec = _business_map_load_json(&social_state.business_pages, did);
        if (rec != NULL) {
            json_t *j_b = json_object_get(rec, "bundle");
            json_t *j_s = json_object_get(rec, "seq");
            at_business_bound_bundle(json_is_string(j_b) ? json_string_value(j_b) : "",
                                     bundle, sizeof(bundle));
            if (json_is_integer(j_s)) seq = (int64_t)json_integer_value(j_s);
            json_decref(rec);
        }
    }
    if (bundle[0] == '\0') {
        log_warn(proc->logger,
                 "Identity: set_customer for %s but no page known, refusing\n", did);
        return true;
    }

    if (!_business_customer_record(did, sat, bundle, seq)) return true;
    log_info(proc->logger, "Identity: customer of %s at satisfaction %d\n", did, sat);

    /* Speak for them now, in the first person. */
    (void)_business_advertise(proc, did, (uint8_t)sat, seq, bundle);
    return true;
}

/* Handler: an inbound group-multicast business ad. Verify the advertiser's
 * signature (bound to their key exactly as handle_post does — a known peer's
 * stored key MUST match the carried one, an unknown advertiser is accepted
 * best-effort against the carried key so a page can reach beyond the business's
 * own cohort). Then content-id DEDUP, store, emit — and finally the CUSTOMER
 * GATE: if we are a customer of this business, we re-advertise it ourselves.
 *
 * Note what is deliberately absent: no tier-gate (a business page is public by
 * construction — the gate is patronage, not audience), and no hop count (we
 * never forward someone else's ad, we speak for ourselves or not at all). */
static bool handle_business_ad(const process_t *proc, directory_t *queues,
                               generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;

    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    uuid_t advertiser;
    char adv_pk[AT_BUSINESS_AD_SIG_HEX_LEN + 1];
    char sig_hex[AT_BUSINESS_AD_SIG_HEX_LEN + 1];
    char did[AT_BUSINESS_DID_MAX + 1];
    char bundle[AT_BUSINESS_BUNDLE_MAX + 1];
    uint8_t sat = 0;
    int64_t seq = 0;
    double ts = 0.0;
    if (at_business_ad_from_json(payload, advertiser, adv_pk, did, sizeof(did),
                                 &sat, &seq, &ts, bundle, sizeof(bundle),
                                 sig_hex) != 0) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: peer_business_ad malformed, refusing\n");
        return true;
    }
    json_decref(payload);

    char adv_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(advertiser, adv_str);

    /* Resolve the key to verify against, binding uuid <-> key where we can. */
    unsigned char verify_pk[crypto_sign_PUBLICKEYBYTES];
    public_identity_t known;
    bool have_known = identity_find_peer_pub(proc, advertiser, &known);
    if (have_known) {
        char known_pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
        sodium_bin2hex(known_pk_hex, sizeof(known_pk_hex),
                       known.signature.public, crypto_sign_PUBLICKEYBYTES);
        if (strncmp(known_pk_hex, adv_pk, crypto_sign_PUBLICKEYBYTES * 2) != 0) {
            log_warn(proc->logger,
                     "Identity: peer_business_ad from %s: advertiser_pk != known "
                     "key, dropping (impersonation)\n", adv_str);
            return true;
        }
        memcpy(verify_pk, known.signature.public, sizeof(verify_pk));
    } else {
        size_t bin_len = 0;
        if (sodium_hex2bin(verify_pk, sizeof(verify_pk), adv_pk, strlen(adv_pk),
                           NULL, &bin_len, NULL) != 0
            || bin_len != sizeof(verify_pk)) {
            log_warn(proc->logger,
                     "Identity: peer_business_ad from %s: bad advertiser_pk, "
                     "dropping\n", adv_str);
            return true;
        }
    }

    if (!at_business_ad_verify(verify_pk, advertiser, did, sat, seq, ts, bundle,
                               sig_hex)) {
        log_warn(proc->logger,
                 "Identity: peer_business_ad from %s: BAD SIGNATURE, dropping\n",
                 adv_str);
        return true;
    }

    /* Content-id dedup: compute the id from the VERIFIED canonical and drop a
     * repeat before storing, emitting or re-advertising. */
    char id_hex[AT_BUSINESS_AD_ID_HEX_LEN + 1];
    if (at_business_ad_content_id(advertiser, did, sat, seq, ts, bundle,
                                  id_hex) != 0)
        return true;
    if (_business_ad_seen_or_record(id_hex)) {
        log_debug(proc->logger,
                  "Identity: peer_business_ad %s already seen, dropping\n", id_hex);
        return true;
    }

    _business_page_store(did, bundle, seq, ts, adv_str, (int)sat);
    /* A blocked ADVERTISER's voice is hidden from us (Phase 4 P4.1): we do not
     * surface their endorsement to the app. The page itself is still stored
     * above, and the customer-carry gate below still runs.
     *
     * THE SENDER IS CHECKED, NEVER THE POLITY. A block is keyed by peer uuid;
     * a polity is a DID, and blocking a BUSINESS is an app-level question the
     * app can answer for itself because it holds the DID. The core must not
     * grow an opinion about the opaque bundle — it cannot parse Ethne, and
     * that is deliberate. */
    if (_is_blocked(advertiser)) {
        log_debug(proc->logger,
                  "Identity: business ad %s from %s hidden (advertiser locally "
                  "blocked)\n", id_hex, adv_str);
    } else {
        identity_emit_business_ad(advertiser, did, id_hex, (int)sat, seq, ts,
                                  bundle);
    }
    log_debug(proc->logger,
              "Identity: business ad %s for %s from %s accepted (sat=%u)\n",
              id_hex, did, adv_str, (unsigned)sat);

    /* THE CUSTOMER GATE. A non-customer stops here — it has the page, it can
     * show it to its operator, but it does not carry it onward. A customer
     * speaks up with its OWN satisfaction, over the page version it holds (or
     * this fresher one). */
    int own_sat = 0;
    char own_bundle[AT_BUSINESS_BUNDLE_MAX + 1];
    int64_t own_seq = 0;
    if (_business_is_customer(did, &own_sat, own_bundle, sizeof(own_bundle),
                              &own_seq)) {
        const char *carry = own_bundle;
        int64_t carry_seq = own_seq;
        if (seq > own_seq) {   /* the business updated its page; carry the new one */
            carry = bundle;
            carry_seq = seq;
        }
        (void)_business_advertise(proc, did, (uint8_t)own_sat, carry_seq, carry);
    }
    return true;
}

/* Conformance/observability seam: what this node knows about business @p did —
 * the page version it holds and how many customers have vouched for it. Returns
 * true and fills the outputs if a page is held. Mirrors Python
 * get_business_page. */
bool identity_get_business_page(const char *did, char *bundle_buf,
                                size_t bundle_sz, int64_t *seq_out,
                                int *endorsers_out)
{
    if (!social_state.initialized || did == NULL) return false;
    json_t *rec = _business_map_load_json(&social_state.business_pages, did);
    if (rec == NULL) return false;
    json_t *j_bundle    = json_object_get(rec, "bundle");
    json_t *j_seq       = json_object_get(rec, "seq");
    json_t *j_endorsers = json_object_get(rec, "endorsers");
    if (bundle_buf != NULL && bundle_sz > 0)
        snprintf(bundle_buf, bundle_sz, "%s",
                 json_is_string(j_bundle) ? json_string_value(j_bundle) : "");
    if (seq_out != NULL)
        *seq_out = json_is_integer(j_seq) ? (int64_t)json_integer_value(j_seq) : 0;
    if (endorsers_out != NULL)
        *endorsers_out = json_is_object(j_endorsers)
                             ? (int)json_object_size(j_endorsers) : 0;
    json_decref(rec);
    return true;
}

/* Conformance/test seam (Phase 3 P3.2): install or clear THIS node's CUSTOMER
 * edge to @p did WITHOUT advertising — the harness analog of the app's
 * AT_APP_SET_CUSTOMER verb minus its wire half, so `fixtures.customers` can set
 * up a node that is authorized to carry a page without that setup itself
 * counting as an emission. @p satisfaction < 0 clears the edge. Twin of the
 * Python adapter calling set_customer() with no queues. */
void identity_set_customer(const char *did, int satisfaction,
                           const char *bundle, int64_t seq)
{
    if (!social_state.initialized || did == NULL || did[0] == '\0') return;
    char bdid[AT_BUSINESS_DID_MAX + 1];
    at_business_bound_did(did, bdid, sizeof(bdid));
    if (bdid[0] == '\0') return;
    if (satisfaction < 0) {
        pthread_mutex_lock(&social_state.lock);
        map_remove(&social_state.business_customers, (map_key_t)bdid);
        pthread_mutex_unlock(&social_state.lock);
        return;
    }
    if (satisfaction > AT_BUSINESS_SAT_MAX) satisfaction = AT_BUSINESS_SAT_MAX;
    char bbundle[AT_BUSINESS_BUNDLE_MAX + 1];
    at_business_bound_bundle(bundle == NULL ? "" : bundle, bbundle,
                             sizeof(bbundle));
    (void)_business_customer_record(bdid, satisfaction, bbundle, seq);
}

/* Conformance/observability seam: this node's OWN customer satisfaction toward
 * @p did, or -1 when it holds no customer edge (and so carries nothing). */
int identity_get_customer_satisfaction(const char *did)
{
    if (!social_state.initialized || did == NULL) return -1;
    int sat = -1;
    if (!_business_is_customer(did, &sat, NULL, 0, NULL)) return -1;
    return sat;
}

/* ======================================================================
 * Business posts (Phase 3 P3.4) — the polity speaking, in the feed.
 *
 * An ad says "this place exists and I liked it"; a post is the business's own
 * words. So the two differ in exactly two ways, and both follow from where the
 * authority lives:
 *   - A post RELAYS (POST_MAX_HOPS), because its authority is the envoy
 *     signature sealed inside the opaque bundle and no carrier can launder it.
 *     A relay forwards the ORIGINAL envelope and changes only the hop count,
 *     so every copy of a post keeps one content id and gossip converges. An ad
 *     is first-person and therefore never forwarded at all.
 *   - A post is GATED ON THE PAGE, not on patronage: a node that holds no page
 *     for the polity drops it AND DOES NOT RELAY IT, so posts travel only
 *     through the part of the network that already knows the business. First
 *     contact is still an ad's job.
 * What the core verifies is the sender's Ed25519 signature over the canonical
 * bytes — that this copy arrived unaltered. WHO MAY SPEAK FOR THE BUSINESS is
 * not a question the core can answer; the app answers it against the bundle.
 * ====================================================================== */

/* Bounded content-id dedup for business posts — the twin of
 * _post_seen_or_record, and what stops a relayed post echoing round the group.
 * Returns true if @p id_hex was already seen; records it otherwise. */
static bool _business_post_seen_or_record(const char *id_hex)
{
    bool seen = false;
    pthread_mutex_lock(&social_state.lock);
    for (size_t i = 0; i < social_state.seen_business_post_count; i++) {
        if (strncmp(social_state.seen_business_posts[i], id_hex,
                    AT_BUSINESS_POST_ID_HEX_LEN) == 0) {
            seen = true;
            break;
        }
    }
    if (!seen) {
        snprintf(social_state.seen_business_posts[social_state.seen_business_post_next],
                 AT_BUSINESS_POST_ID_HEX_LEN + 1, "%s", id_hex);
        social_state.seen_business_post_next =
            (social_state.seen_business_post_next + 1) % BUSINESS_POST_DEDUP_CAP;
        if (social_state.seen_business_post_count < BUSINESS_POST_DEDUP_CAP)
            social_state.seen_business_post_count++;
    }
    pthread_mutex_unlock(&social_state.lock);
    return seen;
}

/* The business-post twin of _post_seen_peek. Own locking. */
static bool _business_post_seen_peek(const char *id_hex)
{
    bool seen = false;
    pthread_mutex_lock(&social_state.lock);
    for (size_t i = 0; i < social_state.seen_business_post_count && !seen; i++)
        seen = strncmp(social_state.seen_business_posts[i], id_hex,
                       AT_BUSINESS_POST_ID_HEX_LEN) == 0;
    pthread_mutex_unlock(&social_state.lock);
    return seen;
}

/* THE AUDIENCE GATE: does this node hold a page for @p did? A post from a
 * business we know nothing about is dropped unread and unrelayed — the reader
 * cannot verify it (it has no page to compare against and no reason to care),
 * and forwarding content nobody here is allowed to read is how a gossip channel
 * becomes an amplifier. */
static bool _business_page_held(const char *did)
{
    json_t *rec = _business_map_load_json(&social_state.business_pages, did);
    if (rec == NULL) return false;
    json_decref(rec);
    return true;
}

/* Conformance/observability surface, keyed by POLITY DID: a post belongs to the
 * business, not to whoever relayed it. NOT roster state. Own locking. */
static void _last_business_post_store(const char *did, const char *post_id,
                                      int64_t seq, double ts, int hops,
                                      const char *bundle)
{
    char bounded[AT_BUSINESS_POST_BUNDLE_MAX + 1];
    at_business_post_bound_bundle(bundle, bounded, sizeof(bounded));
    json_t *env = json_object();
    if (env == NULL) return;
    if (json_object_set_new(env, "post_id", json_string(post_id)) != 0
        || json_object_set_new(env, "seq", json_integer((json_int_t)seq)) != 0
        || json_object_set_new(env, "ts", json_real(ts)) != 0
        || json_object_set_new(env, "hops", json_integer(hops)) != 0
        || json_object_set_new(env, "bundle", json_string(bounded)) != 0) {
        json_decref(env);
        return;
    }
    _business_map_store_json(&social_state.last_business_post_map, did, env);
}

/* Conformance/observability twin of identity_get_last_post: the most-recent
 * business post this node accepted for polity @p did. Returns true and fills
 * the outputs if present. Mirrors Python get_last_business_post. */
bool identity_get_last_business_post(const char *did, char *post_id_buf,
                                     size_t post_id_sz, char *bundle_buf,
                                     size_t bundle_sz, int64_t *seq_out,
                                     int *hops_out)
{
    if (!social_state.initialized || did == NULL) return false;
    json_t *obj = _business_map_load_json(&social_state.last_business_post_map, did);
    if (obj == NULL) return false;
    json_t *j_id     = json_object_get(obj, "post_id");
    json_t *j_seq    = json_object_get(obj, "seq");
    json_t *j_hops   = json_object_get(obj, "hops");
    json_t *j_bundle = json_object_get(obj, "bundle");
    if (post_id_buf != NULL && post_id_sz > 0)
        snprintf(post_id_buf, post_id_sz, "%s",
                 json_is_string(j_id) ? json_string_value(j_id) : "");
    if (bundle_buf != NULL && bundle_sz > 0)
        snprintf(bundle_buf, bundle_sz, "%s",
                 json_is_string(j_bundle) ? json_string_value(j_bundle) : "");
    if (seq_out != NULL)
        *seq_out = json_is_integer(j_seq) ? (int64_t)json_integer_value(j_seq) : 0;
    if (hops_out != NULL)
        *hops_out = json_is_integer(j_hops) ? (int)json_integer_value(j_hops) : 0;
    json_decref(obj);
    return true;
}

/* Identity -> app: one accepted business post. */
static int identity_emit_business_post(const uuid_t sender_uuid, const char *did,
                                       const char *post_id, int64_t seq,
                                       double ts, int hops, const char *bundle)
{
    generic_msg_t msg = {0};
    msg.type = PEER_BUSINESS_POST_OBSERVED;
    peer_business_post_msg_t *ext = AT_MSG_EXT(&msg, peer_business_post_msg_t);
    msg.size = sizeof(peer_business_post_msg_t);
    memcpy(ext->peer_uuid, sender_uuid, 16);
    at_business_post_bound_did(did, ext->polity,
                               sizeof(ext->polity));
    snprintf(ext->post_id,
             sizeof(ext->post_id), "%s",
             post_id != NULL ? post_id : "");
    ext->seq = seq;
    ext->ts = ts;
    ext->hops = hops;
    at_business_post_bound_bundle(bundle, ext->bundle,
                                  sizeof(ext->bundle));
    return messaging_send(AT_MAIN_QUEUE, PEER_BUSINESS_POST_OBSERVED, &msg, false);
}

/* Encrypted group multicast of one signed business post. Same shape as
 * _multicast_post (RECIPIENT_GROUP + group_encrypt, hop count carried OUTSIDE
 * the signature); used for both the initial publish (hops=0) and a relay. */
static int _multicast_business_post(const process_t *proc,
                                    const uuid_t author_uuid,
                                    const char *author_pk_hex, const char *did,
                                    int64_t seq, double ts, const char *bundle,
                                    const char *sig_hex, int hops)
{
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_BUSINESS_POST;
    out.info.net_msg.encrypt = false;
    out.info.net_msg.group_multicast = true;
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = at_business_post_to_json(author_uuid, author_pk_hex, did, seq,
                                           ts, bundle, sig_hex, hops);
    if (env == NULL) return -1;
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    /* Bounded retry, not a bare messaging_send: a multicast queued behind a
     * Paxos burst used to vanish on EAGAIN while the caller logged it as sent
     * (moderation cohort run 6: "published post" on the author, no group
     * multicast on its network process, nothing on either peer). */
    return identity_send_to_network(proc, &out, "a business post", "the group");
}

/* PUBLISH a business post: sign the canonical form with THIS node's key and
 * group-multicast it at hops 0. Only the publishing node does this — a relay
 * forwards the original envelope instead (see handle_business_post), because
 * re-signing would change the content id and break the dedup that makes gossip
 * converge. Returns 0 on success. */
static int _business_post_publish(const process_t *proc, const char *did,
                                  int64_t seq, const char *bundle)
{
    const identity_t *self = identity_self_identity(proc);
    if (self == NULL) {
        log_debug(proc->logger,
                  "Identity: business post but self identity unresolved; skipping\n");
        return -1;
    }
    double ts = (double)time(NULL);
    char sig_hex[AT_BUSINESS_POST_SIG_HEX_LEN + 1];
    if (at_business_post_sign(self->signature.private, self->uuid, did, seq, ts,
                              bundle, sig_hex) != 0) {
        log_warn(proc->logger, "Identity: business post signing failed\n");
        return -1;
    }
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    sodium_bin2hex(pk_hex, sizeof(pk_hex), self->signature.public,
                   crypto_sign_PUBLICKEYBYTES);
    char id_hex[AT_BUSINESS_POST_ID_HEX_LEN + 1];
    if (at_business_post_content_id(self->uuid, did, seq, ts, bundle,
                                    id_hex) != 0)
        return -1;
    /* Record BEFORE sending so a loopback copy of our own multicast is deduped
     * rather than re-emitted and relayed back into the group. */
    (void)_business_post_seen_or_record(id_hex);
    {
        json_t *own = at_business_post_to_json(self->uuid, pk_hex, did, seq,
                                               ts, bundle, sig_hex, 0);
        _store_for_backfill(&social_state.biz_store, id_hex, ts, self->uuid, own);
        json_decref(own);
    }

    _multicast_business_post(proc, self->uuid, pk_hex, did, seq, ts, bundle,
                             sig_hex, 0);
    log_info(proc->logger, "Identity: published business post %s for %s seq=%lld\n",
             id_hex, did, (long long)seq);
    return 0;
}

/* App -> AT verb (AT_APP_PUBLISH_BUSINESS_POST): the envoy operator publishes
 * the business's words. Payload {"polity":"<did>","bundle":"<json>",
 * "seq":<int>}. The bundle is opaque here — the app built and ENVOY-signed it
 * through Ethne, and every reader checks that signature itself. This verb
 * confers nothing: a node with no delegation can run it and will simply have
 * its post refused everywhere. */
static bool handle_app_publish_business_post(const process_t *proc,
                                             directory_t *queues,
                                             generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *j_did    = json_object_get(payload, "polity");
    json_t *j_bundle = json_object_get(payload, "bundle");
    json_t *j_seq    = json_object_get(payload, "seq");
    char did[AT_BUSINESS_POST_DID_MAX + 1];
    at_business_post_bound_did(json_is_string(j_did) ? json_string_value(j_did) : "",
                               did, sizeof(did));
    char bundle[AT_BUSINESS_POST_BUNDLE_MAX + 1];
    at_business_post_bound_bundle(json_is_string(j_bundle)
                                      ? json_string_value(j_bundle) : "",
                                  bundle, sizeof(bundle));
    bool have_seq = json_is_integer(j_seq);
    int64_t seq = have_seq ? (int64_t)json_integer_value(j_seq) : 0;
    json_decref(payload);

    if (did[0] == '\0' || bundle[0] == '\0') {
        log_warn(proc->logger,
                 "Identity: publish_business_post without polity/bundle, refusing\n");
        return true;
    }
    if (!have_seq) {
        /* No seq offered: keep a monotonic one of our own, so two posts with
         * identical text do not collapse to one content id. */
        pthread_mutex_lock(&social_state.lock);
        seq = ++social_state.business_post_seq;
        pthread_mutex_unlock(&social_state.lock);
    } else {
        pthread_mutex_lock(&social_state.lock);
        if (seq > social_state.business_post_seq) social_state.business_post_seq = seq;
        pthread_mutex_unlock(&social_state.lock);
    }
    /* The business holds its own page by construction — it just wrote the post
     * — so record it before publishing. Without this the publisher's own relay
     * gate would refuse a copy of its own post coming back round. */
    _business_page_store(did, bundle, seq, (double)time(NULL), "", AT_BUSINESS_SAT_SELF);
    (void)_business_post_publish(proc, did, seq, bundle);
    return true;
}

/****************************
 * Handler: business_post (peer_business_post)
 * Inbound group multicast. Verify the sender's signature over the canonical
 * bytes, GATE on holding this polity's page, dedup by content id, emit, and
 * relay one more hop.
 *
 * ORDER MATTERS. The gate sits AFTER the signature check (so a forgery is
 * refused as a forgery, not as an unknown business) and BEFORE the emit and the
 * relay (so an ungated node neither shows nor spreads it).
 *
 * The core does NOT and CANNOT check that the publisher may speak for the
 * business: that lives in the envoy signature inside the opaque bundle, which
 * only the app can verify. The AT signature binds the PUBLISHING NODE and is
 * forwarded untouched by relays, so peer_uuid names whoever first put these
 * bytes on the wire — which is still not an authority, just a witness that the
 * bytes have not changed since.
 ****************************/
/* The one inbound path for a business post: the group multicast
 * (handle_business_post, @p via_group true) or a directed backfill
 * (handle_post_backfill, false). A backfill passes the same page gate and dedup
 * and is never relayed. @p payload is borrowed. */
static bool _ingest_business_post(const process_t *proc, json_t *payload,
                                  bool via_group)
{
    uuid_t author;
    char auth_pk[AT_BUSINESS_POST_SIG_HEX_LEN + 1];
    char sig_hex[AT_BUSINESS_POST_SIG_HEX_LEN + 1];
    char did[AT_BUSINESS_POST_DID_MAX + 1];
    char bundle[AT_BUSINESS_POST_BUNDLE_MAX + 1];
    int64_t seq = 0;
    double ts = 0.0;
    int hops = 0;
    if (at_business_post_from_json(payload, author, auth_pk, did, sizeof(did),
                                   &seq, &ts, bundle, sizeof(bundle), sig_hex,
                                   &hops) != 0) {
        log_warn(proc->logger,
                 "Identity: peer_business_post malformed, refusing\n");
        return true;
    }

    char auth_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(author, auth_str);

    /* Resolve the key to verify against, binding uuid <-> key where we can. */
    unsigned char verify_pk[crypto_sign_PUBLICKEYBYTES];
    public_identity_t known;
    bool have_known = identity_find_peer_pub(proc, author, &known);
    if (have_known) {
        char known_pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
        sodium_bin2hex(known_pk_hex, sizeof(known_pk_hex),
                       known.signature.public, crypto_sign_PUBLICKEYBYTES);
        if (strncmp(known_pk_hex, auth_pk, crypto_sign_PUBLICKEYBYTES * 2) != 0) {
            log_warn(proc->logger,
                     "Identity: peer_business_post from %s: author_pk != known "
                     "key, dropping (impersonation)\n", auth_str);
            return true;
        }
        memcpy(verify_pk, known.signature.public, sizeof(verify_pk));
    } else {
        size_t bin_len = 0;
        if (sodium_hex2bin(verify_pk, sizeof(verify_pk), auth_pk, strlen(auth_pk),
                           NULL, &bin_len, NULL) != 0
            || bin_len != sizeof(verify_pk)) {
            log_warn(proc->logger,
                     "Identity: peer_business_post from %s: bad author_pk, "
                     "dropping\n", auth_str);
            return true;
        }
    }

    if (!at_business_post_verify(verify_pk, author, did, seq, ts, bundle,
                                 sig_hex)) {
        log_warn(proc->logger,
                 "Identity: peer_business_post from %s: BAD SIGNATURE, dropping\n",
                 auth_str);
        return true;
    }

    /* THE AUDIENCE GATE (P3.4, user-locked): no page for this polity, no post.
     * Dropped here means not shown AND not relayed — a node that does not know
     * the business does not carry its words. */
    if (!_business_page_held(did)) {
        log_debug(proc->logger,
                  "Identity: business post for %s dropped — no page held for "
                  "that polity (not a customer, not advertised to)\n", did);
        return true;
    }

    /* Content-id dedup: compute the id from the VERIFIED canonical and drop a
     * repeat before emitting or relaying. */
    char id_hex[AT_BUSINESS_POST_ID_HEX_LEN + 1];
    if (at_business_post_content_id(author, did, seq, ts, bundle, id_hex) != 0)
        return true;
    if (_business_post_seen_or_record(id_hex)) {
        log_debug(proc->logger,
                  "Identity: peer_business_post %s already seen, dropping\n",
                  id_hex);
        return true;
    }
    _store_for_backfill(&social_state.biz_store, id_hex, ts, author, payload);

    _last_business_post_store(did, id_hex, seq, ts, hops, bundle);
    /* A blocked PUBLISHER's copy is hidden from us (Phase 4 P4.1) — the sender
     * of this envelope, not the polity, for the reason handle_business_ad
     * gives. The hop relay below still runs, as it does for a feed post: a
     * personal block is not community content policy. */
    if (_is_blocked(author)) {
        log_debug(proc->logger,
                  "Identity: business post %s from %s hidden (publisher "
                  "locally blocked)\n", id_hex, auth_str);
    } else {
        identity_emit_business_post(author, did, id_hex, seq, ts, hops, bundle);
    }
    log_info(proc->logger,
             "Identity: business post %s for %s from %s accepted (hops=%d%s)\n",
             id_hex, did, auth_str, hops, via_group ? "" : ", backfilled");

    /* Gossip one more hop, under the same bound as a feed post — FORWARDING
     * THE ORIGINAL ENVELOPE, exactly as handle_post does. Everything but the
     * hop count is passed through untouched: the publisher's uuid, key,
     * signature, seq and ts, and the bundle.
     *
     * A RELAY MUST NOT RE-SIGN. Signing as ourselves would change the
     * canonical bytes and therefore the content id, so the relayed copy would
     * dedup against nothing and every receiver would hold one copy per relay
     * of the same words. The content address is what makes gossip CONVERGE;
     * re-signing quietly destroys that. It is also why the hop count lives
     * outside the signature — so the one field a relay may change is the one
     * field the signature does not cover. */
    if (via_group && hops < POST_MAX_HOPS)
        (void)_multicast_business_post(proc, author, auth_pk, did, seq, ts,
                                       bundle, sig_hex, hops + 1);
    return true;
}

static bool handle_business_post(const process_t *proc, directory_t *queues,
                                 generic_msg_t *msg)
{
    (void)queues;
    json_t *payload = NULL;
    if (net_msg_unpack_json(&msg->info.net_msg, &payload) != 0 || payload == NULL)
        return true;
    _ingest_business_post(proc, payload, true);
    json_decref(payload);
    return true;
}
/* ======================================================================
 * COMMUNITIES (Phase 4, Ethne D37): a community's content policy and a
 * moderator's labels. See ID_COMMUNITY_POLICY above and community.h.
 *
 * WHAT THE CORE DOES NOT DO. It never parses a policy, never decides whether a
 * label counts, and never hides or withholds a post by policy: every one of
 * those is the app's call, against a policy only the app can verify, and a
 * reader who does not follow a community sees its posts unmoderated. What the
 * core owns is carriage: holding the policies the app told it to follow,
 * carrying them in the first person, and moving labels only between nodes to
 * whom they can matter.
 * ====================================================================== */

/* A bounded content-id ring: true if @p id was already there, else recorded.
 * Caller holds social_state.lock. */
static bool _ring_seen_or_record_locked(char ring[][AT_COMMUNITY_ID_HEX_LEN + 1],
                                        size_t cap, size_t *next, size_t *count,
                                        const char *id, bool record)
{
    for (size_t i = 0; i < *count; i++)
        if (strncmp(ring[i], id, AT_COMMUNITY_ID_HEX_LEN) == 0)
            return true;
    if (record) {
        snprintf(ring[*next], AT_COMMUNITY_ID_HEX_LEN + 1, "%s", id);
        *next = (*next + 1) % cap;
        if (*count < cap)
            (*count)++;
    }
    return false;
}

static bool _policy_ad_seen_or_record(const char *id)
{
    pthread_mutex_lock(&social_state.lock);
    bool seen = _ring_seen_or_record_locked(
        social_state.seen_policy_ads, COMMUNITY_POLICY_DEDUP_CAP,
        &social_state.seen_policy_ad_next, &social_state.seen_policy_ad_count, id,
        true);
    pthread_mutex_unlock(&social_state.lock);
    return seen;
}

static bool _post_label_seen_or_record(const char *id)
{
    pthread_mutex_lock(&social_state.lock);
    bool seen = _ring_seen_or_record_locked(
        social_state.seen_post_labels, POST_LABEL_DEDUP_CAP,
        &social_state.seen_post_label_next, &social_state.seen_post_label_count,
        id, true);
    pthread_mutex_unlock(&social_state.lock);
    return seen;
}

static bool _post_label_seen_peek(const char *id)
{
    pthread_mutex_lock(&social_state.lock);
    bool seen = _ring_seen_or_record_locked(
        social_state.seen_post_labels, POST_LABEL_DEDUP_CAP,
        &social_state.seen_post_label_next, &social_state.seen_post_label_count,
        id, false);
    pthread_mutex_unlock(&social_state.lock);
    return seen;
}

/* Whether this node follows @p did. */
bool identity_is_following(const char *did)
{
    if (!social_state.initialized || did == NULL || did[0] == '\0')
        return false;
    json_t *rec = _business_map_load_json(&social_state.communities, did);
    if (rec == NULL)
        return false;
    json_decref(rec);
    return true;
}

/* The policy this node holds for @p did: true and fills @p seq_out and
 * @p bundle_buf when following. Conformance/observability seam. */
bool identity_get_followed_community(const char *did, int64_t *seq_out,
                                     char *bundle_buf, size_t bundle_sz)
{
    if (!social_state.initialized || did == NULL) return false;
    json_t *rec = _business_map_load_json(&social_state.communities, did);
    if (rec == NULL) return false;
    json_t *j_b = json_object_get(rec, "bundle");
    json_t *j_s = json_object_get(rec, "seq");
    if (seq_out != NULL)
        *seq_out = json_is_integer(j_s) ? (int64_t)json_integer_value(j_s) : 0;
    if (bundle_buf != NULL && bundle_sz > 0)
        snprintf(bundle_buf, bundle_sz, "%s",
                 json_is_string(j_b) ? json_string_value(j_b) : "");
    json_decref(rec);
    return true;
}

/* Follow @p did, holding @p bundle (the app verified it) at @p seq, and persist.
 * Replaces a held policy: this is also how the app hands over a newer one.
 * Returns 0, or -1 on bad input or when COMMUNITIES_MAX are already followed. */
int identity_follow_community(const char *did, const char *bundle, int64_t seq)
{
    if (!social_state.initialized || did == NULL || bundle == NULL
        || did[0] == '\0' || bundle[0] == '\0'
        || strlen(did) > AT_COMMUNITY_DID_MAX
        || strlen(bundle) > AT_COMMUNITY_POLICY_BUNDLE_MAX)
        return -1;
    bool already = identity_is_following(did);
    pthread_mutex_lock(&social_state.lock);
    size_t n = map_size(&social_state.communities);
    pthread_mutex_unlock(&social_state.lock);
    if (!already && n >= COMMUNITIES_MAX)
        return -1;
    json_t *rec = json_pack("{s:s, s:I}", "bundle", bundle, "seq", (json_int_t)seq);
    if (rec == NULL)
        return -1;
    _business_map_store_json(&social_state.communities, did, rec);
    _persist_social_blocks();
    return 0;
}

/* Stop following @p did, and persist. Idempotent. */
void identity_unfollow_community(const char *did)
{
    if (!social_state.initialized || did == NULL) return;
    pthread_mutex_lock(&social_state.lock);
    map_remove(&social_state.communities, (map_key_t)did);
    pthread_mutex_unlock(&social_state.lock);
    _persist_social_blocks();
}

/* Identity -> app: one policy ad heard. */
static int identity_emit_community_policy(const uuid_t carrier, const char *did,
                                          const char *policy_id, int64_t seq,
                                          double ts, const char *bundle)
{
    generic_msg_t msg = {0};
    msg.type = PEER_COMMUNITY_POLICY_OBSERVED;
    peer_community_policy_msg_t *ext = AT_MSG_EXT(&msg, peer_community_policy_msg_t);
    msg.size = sizeof(peer_community_policy_msg_t);
    memcpy(ext->peer_uuid, carrier, 16);
    at_community_bound_did(did, ext->community, sizeof(ext->community));
    snprintf(ext->policy_id, sizeof(ext->policy_id), "%s",
             policy_id != NULL ? policy_id : "");
    ext->seq = seq;
    ext->ts = ts;
    at_community_bound_policy(bundle, ext->bundle, sizeof(ext->bundle));
    return messaging_send(AT_MAIN_QUEUE, PEER_COMMUNITY_POLICY_OBSERVED, &msg, false);
}

/* Identity -> app: one label accepted. */
static int identity_emit_post_label(const uuid_t author, const char *did,
                                    const char *post_id, const char *label_id,
                                    int64_t seq, double ts, int hops,
                                    const char *bundle)
{
    generic_msg_t msg = {0};
    msg.type = PEER_POST_LABEL_OBSERVED;
    peer_post_label_msg_t *ext = AT_MSG_EXT(&msg, peer_post_label_msg_t);
    msg.size = sizeof(peer_post_label_msg_t);
    memcpy(ext->peer_uuid, author, 16);
    at_community_bound_did(did, ext->community, sizeof(ext->community));
    snprintf(ext->post_id, sizeof(ext->post_id), "%s", post_id != NULL ? post_id : "");
    snprintf(ext->label_id, sizeof(ext->label_id), "%s",
             label_id != NULL ? label_id : "");
    ext->seq = seq;
    ext->ts = ts;
    ext->hops = hops;
    at_community_bound_label(bundle, ext->bundle, sizeof(ext->bundle));
    return messaging_send(AT_MAIN_QUEUE, PEER_POST_LABEL_OBSERVED, &msg, false);
}

/* Resolve the key to verify a carried artifact against: a known peer's stored
 * key, which the carried one MUST match (an impersonation guard), else the
 * carried key, best-effort. Returns false to drop. */
static bool _carried_key(const process_t *proc, const uuid_t who, const char *pk_hex,
                         const char *verb, unsigned char out[crypto_sign_PUBLICKEYBYTES])
{
    char who_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(who, who_str);
    public_identity_t known;
    if (identity_find_peer_pub(proc, who, &known)) {
        char known_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
        sodium_bin2hex(known_hex, sizeof(known_hex), known.signature.public,
                       crypto_sign_PUBLICKEYBYTES);
        if (strncmp(known_hex, pk_hex, crypto_sign_PUBLICKEYBYTES * 2) != 0) {
            log_warn(proc->logger, "Identity: %s from %s: key != known key, "
                     "dropping (impersonation)\n", verb, who_str);
            return false;
        }
        memcpy(out, known.signature.public, crypto_sign_PUBLICKEYBYTES);
        return true;
    }
    size_t bin_len = 0;
    if (sodium_hex2bin(out, crypto_sign_PUBLICKEYBYTES, pk_hex, strlen(pk_hex), NULL,
                       &bin_len, NULL) != 0
        || bin_len != crypto_sign_PUBLICKEYBYTES) {
        log_warn(proc->logger, "Identity: %s from %s: bad key, dropping\n", verb,
                 who_str);
        return false;
    }
    return true;
}

/* Group-multicast one policy ad, signed by THIS node: first person, never a
 * relay. Returns 0 when sent. */
static int _policy_advertise(const process_t *proc, const char *did, int64_t seq,
                             const char *bundle)
{
    const identity_t *self = identity_self_identity(proc);
    if (self == NULL)
        return -1;
    double ts = (double)time(NULL);
    char sig_hex[AT_COMMUNITY_SIG_HEX_LEN + 1];
    char id_hex[AT_COMMUNITY_ID_HEX_LEN + 1];
    if (at_policy_ad_sign(self->signature.private, self->uuid, did, seq, ts, bundle,
                          sig_hex) != 0
        || at_policy_ad_id(self->uuid, did, seq, ts, bundle, id_hex) != 0) {
        log_warn(proc->logger, "Identity: policy ad signing failed\n");
        return -1;
    }
    /* Record BEFORE sending: our own multicast comes back round. */
    (void)_policy_ad_seen_or_record(id_hex);
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    sodium_bin2hex(pk_hex, sizeof(pk_hex), self->signature.public,
                   crypto_sign_PUBLICKEYBYTES);
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_COMMUNITY_POLICY;
    out.info.net_msg.encrypt = false;          /* the group path encrypts */
    out.info.net_msg.group_multicast = true;
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = at_policy_ad_to_json(self->uuid, pk_hex, did, seq, ts, bundle,
                                       sig_hex);
    if (env == NULL)
        return -1;
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    log_debug(proc->logger, "Identity: carrying the policy of %s seq=%lld (%s)\n",
              did, (long long)seq, id_hex);
    return identity_send_to_network(proc, &out, "a community policy", "the group");
}

/* $AT_SOCIAL_POLICY_SEC, else POLICY_AD_DEFAULT_SEC. */
static double _policy_ad_interval(void)
{
    const char *env = getenv("AT_SOCIAL_POLICY_SEC");
    if (env != NULL && *env != '\0') {
        char *end = NULL;
        long v = strtol(env, &end, 10);
        if (end != env && *end == '\0' && v > 0)
            return (double)v;
    }
    return (double)POLICY_AD_DEFAULT_SEC;
}

/* Carry every policy this node follows, now. Returns how many went out.
 * Conformance seam; the resync calls it on its interval. */
int identity_advertise_communities(const process_t *proc)
{
    char dids[COMMUNITIES_MAX][AT_COMMUNITY_DID_MAX + 1];
    size_t n = 0;
    pthread_mutex_lock(&social_state.lock);
    social_state.last_policy_ad_at = (double)time(NULL);
    map_key_t key = NULL;
    data_t *val = NULL;
    map_entries_for_each(&social_state.communities, key, val)
    {
        (void)val;
        if (n < COMMUNITIES_MAX)
            snprintf(dids[n++], AT_COMMUNITY_DID_MAX + 1, "%s", key);
    }
    map_end_for_each
    pthread_mutex_unlock(&social_state.lock);
    int sent = 0;
    for (size_t i = 0; i < n; i++) {
        static char bundle[AT_COMMUNITY_POLICY_BUNDLE_MAX + 1];
        int64_t seq = 0;
        if (identity_get_followed_community(dids[i], &seq, bundle, sizeof(bundle))
            && _policy_advertise(proc, dids[i], seq, bundle) == 0)
            sent++;
    }
    return sent;
}

static void _maybe_advertise_communities(const process_t *proc)
{
    double now = (double)time(NULL);
    pthread_mutex_lock(&social_state.lock);
    bool due = map_size(&social_state.communities) > 0
               && now - social_state.last_policy_ad_at >= _policy_ad_interval();
    pthread_mutex_unlock(&social_state.lock);
    if (due)
        (void)identity_advertise_communities(proc);
}

/* Observability: what we last HEARD about @p did's policy. */
bool identity_get_last_community_policy(const char *did, int64_t *seq_out,
                                        char *bundle_buf, size_t bundle_sz)
{
    if (!social_state.initialized || did == NULL) return false;
    json_t *rec = _business_map_load_json(&social_state.last_policy_map, did);
    if (rec == NULL) return false;
    json_t *j_s = json_object_get(rec, "seq");
    json_t *j_b = json_object_get(rec, "bundle");
    if (seq_out != NULL)
        *seq_out = json_is_integer(j_s) ? (int64_t)json_integer_value(j_s) : 0;
    if (bundle_buf != NULL && bundle_sz > 0)
        snprintf(bundle_buf, bundle_sz, "%s",
                 json_is_string(j_b) ? json_string_value(j_b) : "");
    json_decref(rec);
    return true;
}

/* Handler: a policy ad. Verify, dedup, record what we heard and tell the app —
 * and nothing more. We do not follow it, replace a held policy with it, or
 * carry it on: the app verifies the root signature and decides, and following
 * is the only thing that makes this node a carrier. */
static bool handle_community_policy(const process_t *proc, directory_t *queues,
                                    generic_msg_t *msg)
{
    (void)queues;
    json_t *payload = NULL;
    if (net_msg_unpack_json(&msg->info.net_msg, &payload) != 0 || payload == NULL)
        return true;
    uuid_t carrier;
    char pk_hex[AT_COMMUNITY_SIG_HEX_LEN + 1];
    char sig_hex[AT_COMMUNITY_SIG_HEX_LEN + 1];
    char did[AT_COMMUNITY_DID_MAX + 1];
    static char bundle[AT_COMMUNITY_POLICY_BUNDLE_MAX + 1];
    int64_t seq = 0;
    double ts = 0.0;
    int rc = at_policy_ad_from_json(payload, carrier, pk_hex, did, sizeof(did), &seq,
                                    &ts, bundle, sizeof(bundle), sig_hex);
    json_decref(payload);
    if (rc != 0) {
        log_warn(proc->logger, "Identity: peer_community_policy malformed, refusing\n");
        return true;
    }
    unsigned char vk[crypto_sign_PUBLICKEYBYTES];
    if (!_carried_key(proc, carrier, pk_hex, "peer_community_policy", vk))
        return true;
    if (!at_policy_ad_verify(vk, carrier, did, seq, ts, bundle, sig_hex)) {
        log_warn(proc->logger, "Identity: peer_community_policy: BAD SIGNATURE, "
                 "dropping\n");
        return true;
    }
    char id_hex[AT_COMMUNITY_ID_HEX_LEN + 1];
    if (at_policy_ad_id(carrier, did, seq, ts, bundle, id_hex) != 0
        || _policy_ad_seen_or_record(id_hex))
        return true;
    /* A carrier we blocked is not heard, as a blocked advertiser is not. */
    if (_is_blocked(carrier))
        return true;
    char carrier_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(carrier, carrier_str);
    json_t *rec = json_pack("{s:s, s:I, s:s, s:s}", "policy_id", id_hex, "seq",
                            (json_int_t)seq, "bundle", bundle, "carrier",
                            carrier_str);
    _business_map_store_json(&social_state.last_policy_map, did, rec);
    identity_emit_community_policy(carrier, did, id_hex, seq, ts, bundle);
    log_debug(proc->logger, "Identity: heard the policy of %s seq=%lld from %s\n",
              did, (long long)seq, carrier_str);
    return true;
}

/* App -> AT verb (AT_APP_FOLLOW_COMMUNITY). Payload {"community","bundle",
 * "seq"}. Locally originated only: following changes what this node carries
 * and persists, which is the operator's decision. */
static bool handle_app_follow_community(const process_t *proc, directory_t *queues,
                                        generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    if (!identity_is_local_app_verb(proc, nmsg))
        return identity_refuse_remote_app_verb(proc, nmsg, AT_APP_FOLLOW_COMMUNITY);
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    const char *did = json_string_value(json_object_get(payload, "community"));
    const char *bundle = json_string_value(json_object_get(payload, "bundle"));
    json_t *j_seq = json_object_get(payload, "seq");
    int64_t seq = json_is_integer(j_seq) ? (int64_t)json_integer_value(j_seq) : 0;
    if (identity_follow_community(did, bundle, seq) != 0) {
        log_warn(proc->logger, "Identity: follow_community refused (missing or "
                 "over-long community/bundle, or %d already followed)\n",
                 COMMUNITIES_MAX);
    } else {
        log_info(proc->logger, "Identity: following %s at seq %lld\n", did,
                 (long long)seq);
        /* Carry it now, in the first person. */
        (void)_policy_advertise(proc, did, seq, bundle);
    }
    json_decref(payload);
    return true;
}

/* App -> AT verb (AT_APP_UNFOLLOW_COMMUNITY). Payload {"community"}. */
static bool handle_app_unfollow_community(const process_t *proc,
                                          directory_t *queues, generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    if (!identity_is_local_app_verb(proc, nmsg))
        return identity_refuse_remote_app_verb(proc, nmsg, AT_APP_UNFOLLOW_COMMUNITY);
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    const char *did = json_string_value(json_object_get(payload, "community"));
    if (did != NULL && did[0] != '\0') {
        identity_unfollow_community(did);
        log_info(proc->logger, "Identity: no longer following %s\n", did);
    }
    json_decref(payload);
    return true;
}

/* Group-multicast one label envelope: the publish (hops 0) and a relay alike. */
static int _multicast_post_label(const process_t *proc, const uuid_t author,
                                 const char *pk_hex, const char *did,
                                 const char *post_id, int64_t seq, double ts,
                                 const char *bundle, const char *sig_hex, int hops)
{
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_POST_LABEL;
    out.info.net_msg.encrypt = false;
    out.info.net_msg.group_multicast = true;
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    json_t *env = at_post_label_to_json(author, pk_hex, did, post_id, seq, ts, bundle,
                                        sig_hex, hops);
    if (env == NULL)
        return -1;
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    return identity_send_to_network(proc, &out, "a post label", "the group");
}

/* Publish a moderator's label: sign the canonical form as THIS node, keep it for
 * backfill, multicast at hops 0. Returns 0 when sent. Conformance seam. */
int identity_publish_post_label(const process_t *proc, const char *did,
                                const char *post_id, int64_t seq, const char *bundle)
{
    const identity_t *self = identity_self_identity(proc);
    if (self == NULL || did == NULL || did[0] == '\0' || bundle == NULL
        || bundle[0] == '\0' || !at_community_post_id_valid(post_id))
        return -1;
    double ts = (double)time(NULL);
    char sig_hex[AT_COMMUNITY_SIG_HEX_LEN + 1];
    char id_hex[AT_COMMUNITY_ID_HEX_LEN + 1];
    if (at_post_label_sign(self->signature.private, self->uuid, did, post_id, seq, ts,
                           bundle, sig_hex) != 0
        || at_post_label_id(self->uuid, did, post_id, seq, ts, bundle, id_hex) != 0)
        return -1;
    (void)_post_label_seen_or_record(id_hex);
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    sodium_bin2hex(pk_hex, sizeof(pk_hex), self->signature.public,
                   crypto_sign_PUBLICKEYBYTES);
    json_t *own = at_post_label_to_json(self->uuid, pk_hex, did, post_id, seq, ts,
                                        bundle, sig_hex, 0);
    _store_for_backfill(&social_state.label_store, id_hex, ts, self->uuid, own);
    json_decref(own);
    int rc = _multicast_post_label(proc, self->uuid, pk_hex, did, post_id, seq, ts,
                                   bundle, sig_hex, 0);
    log_info(proc->logger, "Identity: published label %s on %s in %s\n", id_hex,
             post_id, did);
    return rc;
}

/* App -> AT verb (AT_APP_PUBLISH_POST_LABEL). Payload {"community","post_id",
 * "bundle","seq"}. Confers nothing: the moderator's signature inside the bundle
 * is what a reader checks. */
static bool handle_app_publish_post_label(const process_t *proc, directory_t *queues,
                                          generic_msg_t *msg)
{
    (void)queues;
    json_t *payload = NULL;
    if (net_msg_unpack_json(&msg->info.net_msg, &payload) != 0 || payload == NULL)
        return true;
    const char *did = json_string_value(json_object_get(payload, "community"));
    const char *pid = json_string_value(json_object_get(payload, "post_id"));
    const char *bundle = json_string_value(json_object_get(payload, "bundle"));
    json_t *j_seq = json_object_get(payload, "seq");
    int64_t seq = json_is_integer(j_seq) ? (int64_t)json_integer_value(j_seq) : 0;
    if (identity_publish_post_label(proc, did, pid, seq, bundle) != 0)
        log_warn(proc->logger, "Identity: publish_post_label refused (needs a "
                 "community, a 64-hex post id and a bundle)\n");
    json_decref(payload);
    return true;
}

/* Observability: the label last accepted for post @p post_id. */
bool identity_get_last_post_label(const char *post_id, char *community_buf,
                                  size_t community_sz, int64_t *seq_out,
                                  int *hops_out)
{
    if (!social_state.initialized || post_id == NULL) return false;
    json_t *rec = _business_map_load_json(&social_state.last_label_map, post_id);
    if (rec == NULL) return false;
    json_t *j_c = json_object_get(rec, "community");
    json_t *j_s = json_object_get(rec, "seq");
    json_t *j_h = json_object_get(rec, "hops");
    if (community_buf != NULL && community_sz > 0)
        snprintf(community_buf, community_sz, "%s",
                 json_is_string(j_c) ? json_string_value(j_c) : "");
    if (seq_out != NULL)
        *seq_out = json_is_integer(j_s) ? (int64_t)json_integer_value(j_s) : 0;
    if (hops_out != NULL)
        *hops_out = json_is_integer(j_h) ? (int)json_integer_value(j_h) : 0;
    json_decref(rec);
    return true;
}

/* The one inbound path for a label: the group multicast (@p via_group true) or
 * a directed backfill (false, never relayed). @p payload is borrowed.
 *
 * THE FOLLOW GATE sits after the signature check and before the dedup, the
 * emit and the relay, exactly where a business post's page gate sits: a label
 * matters only where the community's policy applies, and carrying it to nodes
 * that do not follow the community is how a gossip channel becomes an
 * amplifier. There is no block gate: a label is the community's act, and
 * whether it counts is the policy's question. */
static bool _ingest_post_label(const process_t *proc, json_t *payload, bool via_group)
{
    uuid_t author;
    char pk_hex[AT_COMMUNITY_SIG_HEX_LEN + 1];
    char sig_hex[AT_COMMUNITY_SIG_HEX_LEN + 1];
    char did[AT_COMMUNITY_DID_MAX + 1];
    char post_id[AT_COMMUNITY_ID_HEX_LEN + 1];
    char bundle[AT_POST_LABEL_BUNDLE_MAX + 1];
    int64_t seq = 0;
    double ts = 0.0;
    int hops = 0;
    if (at_post_label_from_json(payload, author, pk_hex, did, sizeof(did), post_id,
                                &seq, &ts, bundle, sizeof(bundle), sig_hex,
                                &hops) != 0) {
        log_warn(proc->logger, "Identity: peer_post_label malformed, refusing\n");
        return true;
    }
    unsigned char vk[crypto_sign_PUBLICKEYBYTES];
    if (!_carried_key(proc, author, pk_hex, "peer_post_label", vk))
        return true;
    if (!at_post_label_verify(vk, author, did, post_id, seq, ts, bundle, sig_hex)) {
        log_warn(proc->logger, "Identity: peer_post_label: BAD SIGNATURE, dropping\n");
        return true;
    }
    if (!identity_is_following(did)) {
        log_debug(proc->logger, "Identity: peer_post_label for %s, which we do not "
                  "follow: dropped, not relayed\n", did);
        return true;
    }
    char id_hex[AT_COMMUNITY_ID_HEX_LEN + 1];
    if (at_post_label_id(author, did, post_id, seq, ts, bundle, id_hex) != 0
        || _post_label_seen_or_record(id_hex))
        return true;
    _store_for_backfill(&social_state.label_store, id_hex, ts, author, payload);
    json_t *rec = json_pack("{s:s, s:s, s:I, s:i, s:s}", "label_id", id_hex,
                            "community", did, "seq", (json_int_t)seq, "hops", hops,
                            "bundle", bundle);
    _business_map_store_json(&social_state.last_label_map, post_id, rec);
    identity_emit_post_label(author, did, post_id, id_hex, seq, ts, hops, bundle);
    if (via_group)
        log_debug(proc->logger, "Identity: label %s on %s in %s accepted (hops=%d)\n",
                  id_hex, post_id, did, hops);
    else
        log_info(proc->logger, "Identity: label %s on %s in %s accepted (hops=%d, "
                 "backfilled)\n", id_hex, post_id, did, hops);
    /* Relay the ORIGINAL envelope one more hop, never re-signed (see the
     * business post relay for why). */
    if (via_group && hops < POST_MAX_HOPS)
        (void)_multicast_post_label(proc, author, pk_hex, did, post_id, seq, ts,
                                    bundle, sig_hex, hops + 1);
    return true;
}

static bool handle_post_label(const process_t *proc, directory_t *queues,
                              generic_msg_t *msg)
{
    (void)queues;
    json_t *payload = NULL;
    if (net_msg_unpack_json(&msg->info.net_msg, &payload) != 0 || payload == NULL)
        return true;
    _ingest_post_label(proc, payload, true);
    json_decref(payload);
    return true;
}

/* ======================================================================
 * STORE-AND-FORWARD (Agora Phase 4 DDIL). See ID_POST_DIGEST above.
 * ====================================================================== */

/* $AT_SOCIAL_DIGEST_SEC, else POST_DIGEST_DEFAULT_SEC. */
static double _digest_interval(void)
{
    const char *env = getenv("AT_SOCIAL_DIGEST_SEC");
    if (env != NULL && *env != '\0') {
        char *end = NULL;
        long v = strtol(env, &end, 10);
        if (end != env && *end == '\0' && v > 0)
            return (double)v;
    }
    return (double)POST_DIGEST_DEFAULT_SEC;
}

/* True, and records @p now, unless @p map holds a time for @p peer_str less
 * than POST_WANT_COOLDOWN ago. Caller holds social_state.lock. */
static bool _cooldown_pass_locked(map_t *map, const char *peer_str, double now)
{
    data_t *dat = NULL;
    int when = 0;
    if (map_get(map, (map_key_t)peer_str, &dat) == 0 && dat != NULL
        && data_integer(dat, &when) == 0
        && now - (double)when < POST_WANT_COOLDOWN)
        return false;
    map_set(map, (map_key_t)peer_str, integer_data((int)now));
    return true;
}

/* A digest or want is honoured only from an admitted peer: the answer to a want
 * is the posts themselves, and the posts are the group's. */
static bool _admitted_sender(const process_t *proc, const net_msg_t *nmsg,
                             const char *verb, public_identity_t *out)
{
    if (identity_find_peer_pub(proc, nmsg->from_whom.uuid, out))
        return true;
    log_warn(proc->logger, "Identity: %s from a peer we have not admitted (%s), "
             "refusing\n", verb, nmsg->from_whom.nickname);
    return false;
}

static json_t *_ids_json(char ids[][POST_STORE_ID_LEN + 1], size_t n)
{
    json_t *arr = json_array();
    for (size_t i = 0; arr != NULL && i < n; i++)
        json_array_append_new(arr, json_string(ids[i]));
    return arr;
}

/* Group-multicast the ids of our recent stored posts. Returns 0 when sent, 1
 * when there was nothing to offer, -1 on failure. Conformance seam as
 * identity_send_post_digest. */
int identity_send_post_digest(const process_t *proc)
{
    static char feed[POST_STORE_CAP][POST_STORE_ID_LEN + 1];
    static char biz[POST_STORE_CAP][POST_STORE_ID_LEN + 1];
    static char label[POST_STORE_CAP][POST_STORE_ID_LEN + 1];
    double now = (double)time(NULL);
    pthread_mutex_lock(&social_state.lock);
    size_t nf = post_store_digest(&social_state.feed_store, now,
                                  POST_BACKFILL_MAX_AGE, feed, POST_STORE_CAP);
    size_t nb = post_store_digest(&social_state.biz_store, now,
                                  POST_BACKFILL_MAX_AGE, biz, POST_STORE_CAP);
    size_t nl = post_store_digest(&social_state.label_store, now,
                                  POST_BACKFILL_MAX_AGE, label, POST_STORE_CAP);
    social_state.last_digest_at = now;
    json_t *env = (nf + nb + nl > 0) ? json_object() : NULL;
    if (env != NULL) {
        json_object_set_new(env, "feed", _ids_json(feed, nf));
        json_object_set_new(env, "biz", _ids_json(biz, nb));
        /* A label is offered WITH its community (Phase 4), so a peer that
         * does not follow it asks for nothing: it would only drop the label
         * at the follow gate, and a dropped label never enters its dedup ring,
         * so it would ask again at every digest. */
        if (nl > 0) {
            json_t *arr = json_array();
            for (size_t i = 0; arr != NULL && i < nl; i++) {
                const post_store_entry_t *e =
                    post_store_get(&social_state.label_store, label[i]);
                json_t *le = e ? json_loads(e->envelope, 0, NULL) : NULL;
                const char *did = le ? json_string_value(json_object_get(le, "community"))
                                     : NULL;
                if (did != NULL)
                    json_array_append_new(arr, json_pack("{s:s, s:s}", "id", label[i],
                                                         "community", did));
                json_decref(le);
            }
            json_object_set_new(env, "label", arr);
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    if (nf + nb + nl == 0)
        return 1;
    if (env == NULL)
        return -1;
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = ID_POST_DIGEST;
    out.info.net_msg.encrypt = false;          /* the group path encrypts */
    out.info.net_msg.group_multicast = true;
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    net_msg_pack_json(&out.info.net_msg, env);
    json_decref(env);
    log_debug(proc->logger, "Identity: post digest: %zu feed, %zu business, "
              "%zu label\n", nf, nb, nl);
    return identity_send_to_network(proc, &out, "a post digest", "the group");
}

static void _maybe_send_post_digest(const process_t *proc)
{
    double now = (double)time(NULL);
    pthread_mutex_lock(&social_state.lock);
    bool due = now - social_state.last_digest_at >= _digest_interval();
    pthread_mutex_unlock(&social_state.lock);
    if (due)
        (void)identity_send_post_digest(proc);
}

/* Directed, encrypted send of one store-and-forward message to @p peer. */
static int _send_directed(const process_t *proc, const public_identity_t *peer,
                          char *verb, json_t *env, const char *what)
{
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = verb;
    out.info.net_msg.encrypt = true;
    memcpy(&out.info.net_msg.to_whom, peer, sizeof(public_identity_t));
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    net_msg_pack_json(&out.info.net_msg, env);
    return identity_send_to_network(proc, &out, what, peer->nickname);
}

/* Collect up to POST_WANT_MAX ids from @p arr that @p seen does not hold. */
static json_t *_missing_ids(json_t *arr, bool (*seen)(const char *))
{
    json_t *want = json_array();
    size_t i;
    json_t *v;
    if (want == NULL || !json_is_array(arr))
        return want;
    json_array_foreach(arr, i, v) {
        if (json_array_size(want) >= POST_WANT_MAX)
            break;
        const char *id = json_string_value(v);
        if (id != NULL && strlen(id) == POST_STORE_ID_LEN && !seen(id))
            json_array_append_new(want, json_string(id));
    }
    return want;
}

/* Handler: a peer's digest. Ask it, directed, for the ids we do not hold. */
static bool handle_post_digest(const process_t *proc, directory_t *queues,
                               generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    const identity_t *self = identity_self_identity(proc);
    if (self != NULL && uuid_compare(self->uuid, nmsg->from_whom.uuid) == 0)
        return true;                               /* our own, looped back */
    public_identity_t peer;
    if (!_admitted_sender(proc, nmsg, "peer_post_digest", &peer))
        return true;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    json_t *feed = _missing_ids(json_object_get(payload, "feed"), _post_seen_peek);
    json_t *biz = _missing_ids(json_object_get(payload, "biz"),
                               _business_post_seen_peek);
    /* Labels: only those for communities we follow, and do not hold. */
    json_t *label = json_array();
    {
        json_t *arr = json_object_get(payload, "label");
        size_t i;
        json_t *v;
        if (label != NULL && json_is_array(arr)) {
            json_array_foreach(arr, i, v) {
                if (json_array_size(label) >= POST_WANT_MAX)
                    break;
                const char *id = json_string_value(json_object_get(v, "id"));
                const char *did = json_string_value(json_object_get(v, "community"));
                if (id != NULL && strlen(id) == POST_STORE_ID_LEN && did != NULL
                    && identity_is_following(did) && !_post_label_seen_peek(id))
                    json_array_append_new(label, json_string(id));
            }
        }
    }
    json_decref(payload);
    size_t n = json_array_size(feed) + json_array_size(biz) + json_array_size(label);
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer.uuid, peer_str);
    bool send = false;
    if (n > 0) {
        pthread_mutex_lock(&social_state.lock);
        send = _cooldown_pass_locked(&social_state.want_sent_at, peer_str,
                                     (double)time(NULL));
        pthread_mutex_unlock(&social_state.lock);
    }
    if (send) {
        json_t *env = json_object();
        if (env != NULL) {
            json_object_set(env, "feed", feed);
            json_object_set(env, "biz", biz);
            if (json_array_size(label) > 0)
                json_object_set(env, "label", label);
            log_info(proc->logger, "Identity: asking %s for %zu missed post(s)\n",
                     peer.nickname, n);
            _send_directed(proc, &peer, ID_POST_WANT, env, "a post want");
            json_decref(env);
        }
    }
    json_decref(feed);
    json_decref(biz);
    json_decref(label);
    return true;
}

/* Handler: a peer asks for stored posts. Serve each, directed, as its original
 * envelope; never a post back to its own author. */
static bool handle_post_want(const process_t *proc, directory_t *queues,
                             generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    public_identity_t peer;
    if (!_admitted_sender(proc, nmsg, "peer_post_want", &peer))
        return true;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer.uuid, peer_str);

    /* Copy out under the lock, send after it. */
    static const char *const kind_names[3] = { "feed", "biz", "label" };
    char *envs[3 * POST_WANT_MAX];
    const char *kinds[3 * POST_WANT_MAX];
    size_t n = 0;
    pthread_mutex_lock(&social_state.lock);
    bool serve = _cooldown_pass_locked(&social_state.want_served_at, peer_str,
                                       (double)time(NULL));
    for (int k = 0; serve && k < 3; k++) {
        json_t *arr = json_object_get(payload, kind_names[k]);
        post_store_t *store = k == 0 ? &social_state.feed_store
                              : k == 1 ? &social_state.biz_store
                                       : &social_state.label_store;
        size_t i, taken = 0;
        json_t *v;
        if (!json_is_array(arr))
            continue;
        json_array_foreach(arr, i, v) {
            if (taken >= POST_WANT_MAX)
                break;
            const post_store_entry_t *e = post_store_get(store, json_string_value(v));
            if (e == NULL || uuid_compare(e->author, peer.uuid) == 0)
                continue;
            envs[n] = strdup(e->envelope);
            if (envs[n] == NULL)
                continue;
            kinds[n++] = kind_names[k];
            taken++;
        }
    }
    pthread_mutex_unlock(&social_state.lock);
    json_decref(payload);
    if (!serve)
        log_debug(proc->logger, "Identity: post want from %s within the "
                  "cooldown, not served\n", peer.nickname);

    for (size_t i = 0; i < n; i++) {
        json_t *post = json_loads(envs[i], 0, NULL);
        free(envs[i]);
        if (post == NULL)
            continue;
        json_t *env = json_object();
        if (env != NULL) {
            json_object_set_new(env, "kind", json_string(kinds[i]));
            json_object_set(env, "post", post);
            _send_directed(proc, &peer, ID_POST_BACKFILL, env, "a post backfill");
            json_decref(env);
        }
        json_decref(post);
    }
    if (n > 0)
        log_info(proc->logger, "Identity: backfilled %zu post(s) to %s\n", n,
                 peer.nickname);
    return true;
}

/* Handler: one backfilled post. Through the same path as the original, minus
 * the co-membership record and the relay. crypto_box authenticated the sender;
 * the post's own signature authenticates its author. */
static bool handle_post_backfill(const process_t *proc, directory_t *queues,
                                 generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    public_identity_t peer;
    if (!_admitted_sender(proc, nmsg, "peer_post_backfill", &peer))
        return true;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return true;
    const char *kind = json_string_value(json_object_get(payload, "kind"));
    json_t *post = json_object_get(payload, "post");
    if (kind == NULL || !json_is_object(post))
        log_warn(proc->logger, "Identity: peer_post_backfill malformed, refusing\n");
    else if (strcmp(kind, "feed") == 0)
        _ingest_post(proc, post, false);
    else if (strcmp(kind, "biz") == 0)
        _ingest_business_post(proc, post, false);
    else if (strcmp(kind, "label") == 0)
        _ingest_post_label(proc, post, false);
    else
        log_warn(proc->logger, "Identity: peer_post_backfill of unknown kind "
                 "'%s', refusing\n", kind);
    json_decref(payload);
    return true;
}

/****************************
 * Social as an identity extension (FEATURE_SPLIT_PLAN Phase 5): the hooks
 * identity calls (identity/id_ext.h) and its verb handlers
 * (processes/extension.h). Each hook runs with no identity lock held.
 ****************************/

static void _social_init(void)
{
    social_state.initialized = true;
    map_init(&social_state.peer_position_map);
    map_init(&social_state.peer_proximity_map);
    /* Opt-in own position: seed from $AT_OWN_GEOHASH for headless/testing
     * (the Flutter UI sets it at runtime via AT_APP_SET_POSITION instead).
     * Empty/invalid/unset => opted out, the default. */
    {
        const char *env_geo = getenv("AT_OWN_GEOHASH");
        if (env_geo != NULL && _geohash_valid(env_geo))
            snprintf(social_state.own_geohash, sizeof(social_state.own_geohash),
                     "%s", env_geo);
    }
    map_init(&social_state.peer_profile_map);
    map_init(&social_state.connection_edges);
    map_init(&social_state.peer_group_uuids);
    map_init(&social_state.last_dm_map);
    map_init(&social_state.last_post_map);
    social_state.post_seq = 0;
    social_state.seen_post_next = 0;
    social_state.seen_post_count = 0;
    map_init(&social_state.business_customers);
    map_init(&social_state.business_pages);
    social_state.seen_business_ad_next = 0;
    social_state.seen_business_ad_count = 0;
    social_state.seen_business_post_next = 0;
    social_state.seen_business_post_count = 0;
    social_state.business_post_seq = 0;
    map_init(&social_state.last_business_post_map);
    post_store_init(&social_state.feed_store);
    post_store_init(&social_state.biz_store);
    post_store_init(&social_state.label_store);
    social_state.last_digest_at = 0.0;
    map_init(&social_state.communities);
    map_init(&social_state.last_policy_map);
    map_init(&social_state.last_label_map);
    social_state.seen_policy_ad_next = 0;
    social_state.seen_policy_ad_count = 0;
    social_state.seen_post_label_next = 0;
    social_state.seen_post_label_count = 0;
    social_state.last_policy_ad_at = 0.0;
    map_init(&social_state.want_sent_at);
    map_init(&social_state.want_served_at);
    map_init(&social_state.last_cosign_request_map);
    map_init(&social_state.last_cosign_sig_map);
    map_init(&social_state.social_edges);
    map_init(&social_state.social_tx_observed);
    map_init(&social_state.social_reports);
    social_state.social_day = 0;
    social_state.social_day_count = 0;
    map_init(&social_state.social_blocks);
    /* Opt-in own profile (Increment 3): seed from $AT_OWN_PROFILE (a JSON
     * object string) for headless/conformance; the Flutter UI sets it at
     * runtime via AT_APP_SET_PROFILE instead. Absent/invalid => opted out. */
    memset(&social_state.own_profile, 0, sizeof(social_state.own_profile));
    {
        const char *env_prof = getenv("AT_OWN_PROFILE");
        if (env_prof != NULL && env_prof[0] != '\0') {
            json_error_t jerr;
            json_t *pj = json_loads(env_prof, 0, &jerr);
            if (pj != NULL) {
                at_profile_from_json(pj, false, &social_state.own_profile);
                json_decref(pj);
            }
        }
    }
}

static void _social_reset(void)
{
    /* at_extensions_reset reaches this with identity never initialized. */
    if (!social_state.initialized)
        return;
    pthread_mutex_lock(&social_state.lock);
    map_free(&social_state.peer_position_map);
    map_init(&social_state.peer_position_map);
    social_state.num_reports_in_flight = 0;
    map_free(&social_state.peer_proximity_map);
    map_init(&social_state.peer_proximity_map);
    social_state.own_exact_set = false;
    social_state.own_exact_lat = 0.0;
    social_state.own_exact_lon = 0.0;
    social_state.own_geohash[0] = '\0';
    map_free(&social_state.peer_profile_map);
    map_init(&social_state.peer_profile_map);
    map_free(&social_state.connection_edges);
    map_init(&social_state.connection_edges);
    map_free(&social_state.peer_group_uuids);
    map_init(&social_state.peer_group_uuids);
    map_free(&social_state.last_dm_map);
    map_init(&social_state.last_dm_map);
    map_free(&social_state.last_post_map);
    map_init(&social_state.last_post_map);
    social_state.post_seq = 0;
    social_state.seen_post_next = 0;
    social_state.seen_post_count = 0;
    map_free(&social_state.business_customers);
    map_init(&social_state.business_customers);
    map_free(&social_state.business_pages);
    map_init(&social_state.business_pages);
    social_state.seen_business_ad_next = 0;
    social_state.seen_business_ad_count = 0;
    social_state.seen_business_post_next = 0;
    social_state.seen_business_post_count = 0;
    social_state.business_post_seq = 0;
    map_free(&social_state.last_business_post_map);
    map_init(&social_state.last_business_post_map);
    post_store_clear(&social_state.feed_store);
    post_store_clear(&social_state.biz_store);
    post_store_clear(&social_state.label_store);
    social_state.last_digest_at = 0.0;
    map_free(&social_state.communities);
    map_init(&social_state.communities);
    map_free(&social_state.last_policy_map);
    map_init(&social_state.last_policy_map);
    map_free(&social_state.last_label_map);
    map_init(&social_state.last_label_map);
    social_state.seen_policy_ad_next = 0;
    social_state.seen_policy_ad_count = 0;
    social_state.seen_post_label_next = 0;
    social_state.seen_post_label_count = 0;
    social_state.last_policy_ad_at = 0.0;
    map_free(&social_state.want_sent_at);
    map_init(&social_state.want_sent_at);
    map_free(&social_state.want_served_at);
    map_init(&social_state.want_served_at);
    map_free(&social_state.last_cosign_request_map);
    map_init(&social_state.last_cosign_request_map);
    map_free(&social_state.last_cosign_sig_map);
    map_init(&social_state.last_cosign_sig_map);
    map_free(&social_state.social_edges);
    map_init(&social_state.social_edges);
    map_free(&social_state.social_tx_observed);
    map_init(&social_state.social_tx_observed);
    map_free(&social_state.social_reports);
    map_init(&social_state.social_reports);
    social_state.social_day = 0;
    social_state.social_day_count = 0;
    map_free(&social_state.social_blocks);
    map_init(&social_state.social_blocks);
    memset(&social_state.own_profile, 0, sizeof(social_state.own_profile));
    pthread_mutex_unlock(&social_state.lock);
}

static void _social_run_start(process_t *proc)
{
    /* Local moderation state (Phase 4 P4.1). Loaded BEFORE the node starts
     * taking traffic: a block that only takes effect once the app has
     * reconnected and replayed it would leave a window in which the blocked
     * peer's DMs and posts land, and agorad is a standalone daemon the GUI
     * spawns, so that window is real. */
    {
        char cfg_dir[CFG_PATH_LEN + 1];
        if (get_cfg_dir(cfg_dir, sizeof(cfg_dir)) > 0) {
            pthread_mutex_lock(&social_state.lock);
            int rc = social_store_load_all(cfg_dir, &social_state.social_blocks,
                                           &social_state.communities);
            size_t n = map_size(&social_state.social_blocks);
            size_t nc = map_size(&social_state.communities);
            pthread_mutex_unlock(&social_state.lock);
            if (rc == 0 && nc > 0)
                log_info(proc->logger,
                         "Identity: following %zu communit%s\n", nc,
                         nc == 1 ? "y" : "ies");
            if (rc != 0)
                log_warn(proc->logger,
                         "Identity: %s/%s is unreadable — starting with NO "
                         "blocks; the operator's moderation state is gone, not "
                         "partially applied\n", cfg_dir, AT_SOCIAL_FILENAME);
            else if (n > 0)
                log_info(proc->logger,
                         "Identity: restored %zu local block(s)\n", n);
        }
    }
}

static void _social_peer_confirmed(const process_t *proc, const public_identity_t *peer)
{
    /* Opt-in position (Increment 2): ask every confirmed peer for its coarse
     * position. If it opted out it answers nothing; the periodic resync
     * re-asks, so a peer that opts in later is still picked up. */
    _send_position_query(proc, peer);
    /* Opt-in profile (Increment 3): same pattern — ask every confirmed peer
     * for its agora.profile; an opted-out peer answers nothing. */
    _send_profile_query(proc, peer);
    /* Store-and-forward: a peer we just confirmed may have missed our posts
     * (a partition healing, a late joiner), so the next sweep sends a digest
     * whatever the interval says. */
    pthread_mutex_lock(&social_state.lock);
    social_state.last_digest_at = 0.0;
    /* And the policies we carry: a newcomer has heard none of them. */
    social_state.last_policy_ad_at = 0.0;
    pthread_mutex_unlock(&social_state.lock);
}

static void _social_group_update_seen(const process_t *proc, const char *from_uuid_str,
                                      const char *their_group_uuid_str)
{
    /* Remember which group this peer advertised, keyed by the authenticated
     * sender. The app's "in your group" indicator lights only once this equals
     * OUR group uuid (real convergence), not merely when addresses overlap.
     * proc->protocol.group.uuid is still our PRE-adopt uuid, which is exactly
     * the "ours at record time" the swap-robust check needs. */
    _record_peer_group_uuid(proc, from_uuid_str, their_group_uuid_str);
}

static void _social_periodic_resync(const process_t *proc)
{
    const identity_t *self = identity_self_identity(proc);
    /* Position resync (Increment 2): re-query admitted peers we hold no stored
     * position for. Opted-out peers answer nothing and are simply re-asked next
     * sweep; a peer that opts in later is picked up here. Same lock order as
     * above (social_state.lock nested under peers_read_lock). */
    public_identity_t posless[CAPS_RESYNC_MAX_PER_SWEEP];
    size_t pcnt = 0;
    peers_read_lock(proc);
    size_t np = proc->protocol.num_peers;
    for (size_t i = 0; i < np && pcnt < CAPS_RESYNC_MAX_PER_SWEEP; i++) {
        const public_identity_t *peer = &proc->protocol.peers[i];
        if (self != NULL && uuid_compare(peer->uuid, self->uuid) == 0)
            continue;
        char uuid_str[UUID_STRING_LEN + 1];
        uuid_unparse_lower(peer->uuid, uuid_str);
        pthread_mutex_lock(&social_state.lock);
        data_t *pdat = NULL;
        bool have = (map_get(&social_state.peer_position_map, uuid_str, &pdat) == 0
                     && pdat != NULL);
        pthread_mutex_unlock(&social_state.lock);
        if (have) continue;
        memcpy(&posless[pcnt++], peer, sizeof(public_identity_t));
    }
    peers_read_unlock(proc);
    for (size_t i = 0; i < pcnt; i++)
        _send_position_query(proc, &posless[i]);

    /* Profile resync (Increment 3): same pattern — re-query admitted peers we
     * hold no stored profile for, so an opted-in-later peer is picked up. */
    public_identity_t profless[CAPS_RESYNC_MAX_PER_SWEEP];
    size_t fcnt = 0;
    peers_read_lock(proc);
    size_t nf = proc->protocol.num_peers;
    for (size_t i = 0; i < nf && fcnt < CAPS_RESYNC_MAX_PER_SWEEP; i++) {
        const public_identity_t *peer = &proc->protocol.peers[i];
        if (self != NULL && uuid_compare(peer->uuid, self->uuid) == 0)
            continue;
        char uuid_str[UUID_STRING_LEN + 1];
        uuid_unparse_lower(peer->uuid, uuid_str);
        pthread_mutex_lock(&social_state.lock);
        data_t *fdat = NULL;
        bool have = (map_get(&social_state.peer_profile_map, uuid_str, &fdat) == 0
                     && fdat != NULL);
        pthread_mutex_unlock(&social_state.lock);
        if (have) continue;
        memcpy(&profless[fcnt++], peer, sizeof(public_identity_t));
    }
    peers_read_unlock(proc);
    for (size_t i = 0; i < fcnt; i++)
        _send_profile_query(proc, &profless[i]);

    /* Store-and-forward: advertise our recent posts, at most every
     * $AT_SOCIAL_DIGEST_SEC. No partition detection is needed: whoever missed
     * a post while apart asks for it after the heal. */
    _maybe_send_post_digest(proc);
    /* Communities (Phase 4): carry the policies we follow, first-person. */
    _maybe_advertise_communities(proc);
}

static bool _social_roster_replay(const process_t *proc, int n)
{
    int p = identity_emit_all_positions(proc);
    int f = identity_emit_all_profiles(proc);
    int c = identity_emit_all_connections(proc);
    log_debug(proc->logger,
              "Identity: peer roster request -> %d observation(s), %d position(s), "
              "%d profile(s), %d connection(s)\n", n, p, f, c);
    return true;
}

/* Group co-membership: true only when this peer last advertised the SAME
 * group uuid we currently hold — i.e. we actually converged on one group,
 * so group multicast (feed posts) works. Address membership alone is true
 * from the mesh merge onward, well before key convergence (the split-brain
 * window), so it is NOT sound here — it would light the "in your group"
 * indicator while posts still cannot flow. */
static bool _social_peer_in_group(const process_t *proc, const char *uuid_str)
{
    return _peer_shares_our_group(proc, uuid_str);
}

/* Whether WE have blocked them (Phase 4 P4.1): PEER_OBSERVED's `blocked` (the
 * only way a block becomes visible to the app at all) and the tier clamp in
 * identity_get_peer_tier. */
static bool _social_peer_blocked(const char *uuid_str)
{
    if (!social_state.initialized)
        return false;
    pthread_mutex_lock(&social_state.lock);
    bool blocked = _is_blocked_locked(uuid_str);
    pthread_mutex_unlock(&social_state.lock);
    return blocked;
}

static int _social_register(process_t *proc, const char *proc_name)
{
    if (strcmp(proc_name, "identity") != 0)
        return 0;
    at_social_msg_types_link();
    process_register_handler(proc, ID_POSITION_QUERY,    (handler_ptr_t)handle_position_query);
    process_register_handler(proc, ID_POSITION_RESPONSE, (handler_ptr_t)handle_position_response);
    process_register_handler(proc, ID_APP_SET_POSITION,  (handler_ptr_t)handle_set_position);
    process_register_handler(proc, ID_PROFILE_QUERY,     (handler_ptr_t)handle_profile_query);
    process_register_handler(proc, ID_PROFILE_RESPONSE,  (handler_ptr_t)handle_profile_response);
    process_register_handler(proc, ID_APP_SET_PROFILE,   (handler_ptr_t)handle_set_profile);
    process_register_handler(proc, ID_CONNECTION_REQUEST,  (handler_ptr_t)handle_connection_request);
    process_register_handler(proc, ID_CONNECTION_RESPONSE, (handler_ptr_t)handle_connection_response);
    process_register_handler(proc, ID_APP_CONNECT_REQUEST, (handler_ptr_t)handle_app_connect_request);
    process_register_handler(proc, ID_APP_CONNECT_RESPOND, (handler_ptr_t)handle_app_connect_respond);
    process_register_handler(proc, ID_DM,          (handler_ptr_t)handle_dm);
    process_register_handler(proc, ID_APP_SEND_DM, (handler_ptr_t)handle_app_send_dm);
    process_register_handler(proc, ID_POST,             (handler_ptr_t)handle_post);
    process_register_handler(proc, ID_APP_PUBLISH_POST, (handler_ptr_t)handle_app_publish_post);
    process_register_handler(proc, ID_REACTION,         (handler_ptr_t)handle_reaction);
    process_register_handler(proc, ID_APP_REACT_POST,   (handler_ptr_t)handle_app_react_post);
    process_register_handler(proc, ID_APP_BLOCK,        (handler_ptr_t)handle_app_block);
    process_register_handler(proc, ID_APP_UNBLOCK,      (handler_ptr_t)handle_app_unblock);
    process_register_handler(proc, ID_REPORT,           (handler_ptr_t)handle_peer_report);
    process_register_handler(proc, ID_APP_REPORT_PEER,  (handler_ptr_t)handle_app_report_peer);
    process_register_handler(proc, ID_APP_REQUEST_ATTEND, (handler_ptr_t)handle_request_attend);
    process_register_handler(proc, ID_APP_SET_EXACT_POSITION, (handler_ptr_t)handle_set_exact_position);
    process_register_handler(proc, ID_APP_REQUEST_PROXIMITY, (handler_ptr_t)handle_request_proximity);
    process_register_handler(proc, ID_PROXIMITY_PROBE, (handler_ptr_t)handle_proximity_probe);
    process_register_handler(proc, ID_PROXIMITY_REPLY, (handler_ptr_t)handle_proximity_reply);
    process_register_handler(proc, ID_BUSINESS_AD,     (handler_ptr_t)handle_business_ad);
    process_register_handler(proc, ID_APP_ADVERTISE_BUSINESS,
                             (handler_ptr_t)handle_app_advertise_business);
    process_register_handler(proc, ID_APP_SET_CUSTOMER,
                             (handler_ptr_t)handle_app_set_customer);
    process_register_handler(proc, ID_COSIGN_REQUEST,
                             (handler_ptr_t)handle_cosign_request);
    process_register_handler(proc, ID_COSIGN_SIG,
                             (handler_ptr_t)handle_cosign_sig);
    process_register_handler(proc, ID_APP_REQUEST_COSIGN,
                             (handler_ptr_t)handle_app_request_cosign);
    process_register_handler(proc, ID_APP_RETURN_COSIGN,
                             (handler_ptr_t)handle_app_return_cosign);
    process_register_handler(proc, ID_BUSINESS_POST,
                             (handler_ptr_t)handle_business_post);
    process_register_handler(proc, ID_APP_PUBLISH_BUSINESS_POST,
                             (handler_ptr_t)handle_app_publish_business_post);
    process_register_handler(proc, ID_COMMUNITY_POLICY,
                             (handler_ptr_t)handle_community_policy);
    process_register_handler(proc, ID_POST_LABEL, (handler_ptr_t)handle_post_label);
    process_register_handler(proc, ID_APP_FOLLOW_COMMUNITY,
                             (handler_ptr_t)handle_app_follow_community);
    process_register_handler(proc, ID_APP_UNFOLLOW_COMMUNITY,
                             (handler_ptr_t)handle_app_unfollow_community);
    process_register_handler(proc, ID_APP_PUBLISH_POST_LABEL,
                             (handler_ptr_t)handle_app_publish_post_label);
    process_register_handler(proc, ID_POST_DIGEST,   (handler_ptr_t)handle_post_digest);
    process_register_handler(proc, ID_POST_WANT,     (handler_ptr_t)handle_post_want);
    process_register_handler(proc, ID_POST_BACKFILL, (handler_ptr_t)handle_post_backfill);
    return 0;
}

static const identity_ext_t social_identity_ext = {
    .name = "social",
    .init = _social_init,
    .reset = _social_reset,
    .run_start = _social_run_start,
    .peer_confirmed = _social_peer_confirmed,
    .group_update_seen = _social_group_update_seen,
    .periodic_resync = _social_periodic_resync,
    .roster_replay = _social_roster_replay,
    .peer_in_group = _social_peer_in_group,
    .peer_blocked = _social_peer_blocked,
};
IDENTITY_EXT_REGISTER(social, &social_identity_ext)

static const at_extension_t social_extension = {
    .name = "social",
    .enabled = NULL,   /* present means on */
    .register_handlers = _social_register,
    .reset = _social_reset,
};
AT_EXTENSION_REGISTER(social, &social_extension)

/* Keeps this object, and the app-event decoders, in a static link. */
void at_social_link(void)
{
    at_agora_link();
}
