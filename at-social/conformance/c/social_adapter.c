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

/* Conformance adapter for the social extension (libat_social,
 * FEATURE_SPLIT_PLAN Phase 5): the identity adapter plus the social fixtures,
 * inbound builders, trigger pseudo-functions and expected_state keys, through
 * identity_priv.h's ic_ext_t. Every block here moved verbatim from
 * adapters/identity.c. Built, and `social` dispatched to it, only when
 * libat_social is (AT_CONF_SOCIAL); without it the protocol reads as "no C
 * adapter" and skips. The Python twin is harness/python/adapters/social.py. */
#include "social_adapter.h"
#include "identity_priv.h"


#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>  /* mkdtemp: Darwin declares it here, not in stdlib.h */
#include <string.h>
#include <time.h>

#include <sodium.h>
#include <uuid/uuid.h>

#include "identity/identity.h"
#include "identity/identity_priv.h"   /* hexlify / public_identity_to_json */
#include "identity/id_proc_priv.h"
#include "processes/extension.h"
#include "utilities/util.h"
#include "identity/group.h"           /* group_init / group_add_address */
#include "config/configuration.h"     /* config_t (proc->configs["identity"]) */
#include "structures/data.h"          /* object_ptr_data */
#ifdef AT_ZTA_ENABLED
#include <openssl/evp.h>              /* scenario-time operator-binding signing */
#include <openssl/pem.h>
#include "zta/zta_policy.h"           /* zta_policy_t / defaults / from_json */
#include "zta/zta_binding.h"          /* credential->identity binding
# (doc/architecture/zta-integration.md) */
#endif
#include "network/net_message.h"
#include "processes/processes.h"
#include "structures/array.h"
#include "structures/map.h"
#include "utilities/message.h"
#include "utilities/msg_types_priv.h"
#include "utilities/allocation.h"
#include <math.h>

#include "negative_runner.h"
#include "scenario_engine.h"

/* Provided by runner.c; needed for kind:negative case dispatch to resolve
 * based_on references inside the JSON corpus mirror. */
extern const char *at_runner_corpus_json_root(void);

#include "social/profile.h"         /* at_profile_* for the profile builder */
#include "social/connection.h"      /* at_connection_* for the connection builder */
#include "social/dm.h"              /* AT_DM_TEXT_MAX for the dm_last check */
#include "social/post.h"            /* at_post_* for the peer_post builder */
#include "social/business_ad.h"   /* at_business_ad_* for the peer_business_ad builder */
#include "social/business_post.h" /* at_business_post_* for the peer_business_post builder */
#include "social/community.h"     /* at_policy_ad_* / at_post_label_* (Phase 4) */
#include "social/cosign.h"        /* AT_COSIGN_* bounds for the cosign_*_last checks */
#include "social/id_social.h"
#include "social/social_msg_types.h"
#include "social/file_xfer.h"       /* file sharing: builders and the file_xfer seam */
#include "social/id_file_xfer.h"

/* Each participant's opt-in EXACT position, from fixtures.exact_positions; hung
 * on impl->ext (formerly fields of ic_impl_t). */
typedef struct {
    /* This participant's opt-in EXACT position (Phase 2, private proximity),
     * from fixtures.exact_positions. id_state.own_exact is a SINGLETON, but a
     * proximity round trip needs BOTH sides' positions, so the fixture parks
     * each here and _ic_run_proximity_probe swaps id_state.own_exact to the
     * active side before running that side's handler (via
     * identity_set_exact_position). prox_exact_set=false means opted out.
     * Mirrors the Python adapter storing own_exact per participant. */
    bool prox_exact_set;
    double prox_exact_lat;
    double prox_exact_lon;
} sx_impl_t;

static sx_impl_t *_sx(ic_impl_t *impl)
{
    if (impl->ext == NULL)
        impl->ext = calloc(1, sizeof(sx_impl_t));
    return (sx_impl_t *)impl->ext;
}

/* File sharing writes under the node's root (etc/at/file_xfer.cfg.json and
 * var/agora/files), and this harness's default root is not writable. A
 * scenario's first file step points AUTONOMOUS_TRUST_ROOT at a fresh temp
 * root, and the participant teardown puts the environment back, so no other
 * scenario runs with a writable root it never asked for (a block would be
 * persisted there). Mirrors the Python adapter's _fx_root. */
static char g_fx_root[64] = {0};
static char *g_fx_prev_root = NULL;
static bool g_fx_had_prev = false;

static const char *_fx_root(void)
{
    if (g_fx_root[0] != '\0')
        return g_fx_root;
    const char *prev = getenv("AUTONOMOUS_TRUST_ROOT");
    g_fx_had_prev = prev != NULL;
    free(g_fx_prev_root);
    g_fx_prev_root = prev != NULL ? strdup(prev) : NULL;
    snprintf(g_fx_root, sizeof(g_fx_root), "/tmp/at-conf-files-XXXXXX");
    if (mkdtemp(g_fx_root) == NULL) {
        g_fx_root[0] = '\0';
        return NULL;
    }
    char sub[128];
    snprintf(sub, sizeof(sub), "%s/etc/at", g_fx_root);
    makedirs(sub, 0700);
    snprintf(sub, sizeof(sub), "%s/src", g_fx_root);
    makedirs(sub, 0700);
    setenv("AUTONOMOUS_TRUST_ROOT", g_fx_root, 1);
    return g_fx_root;
}

static void _fx_root_restore(void)
{
    if (g_fx_root[0] == '\0')
        return;
    if (g_fx_had_prev && g_fx_prev_root != NULL)
        setenv("AUTONOMOUS_TRUST_ROOT", g_fx_prev_root, 1);
    else
        unsetenv("AUTONOMOUS_TRUST_ROOT");
    char cmd[128];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", g_fx_root);
    if (system(cmd) != 0) { /* a temp dir left behind is harmless */ }
    g_fx_root[0] = '\0';
}

/* A step's `content`, repeated `repeat` times (a file of several chunks
 * without a page of YAML). Caller frees; NULL if there is none. */
static char *_fx_content(json_t *payload)
{
    json_t *jc = json_object_get(payload, "content");
    if (!json_is_string(jc))
        return NULL;
    json_t *jr = json_object_get(payload, "repeat");
    size_t rep = json_is_integer(jr) && json_integer_value(jr) > 1
                     ? (size_t)json_integer_value(jr) : 1;
    size_t one = json_string_length(jc);
    char *out = malloc(one * rep + 1);
    if (out == NULL)
        return NULL;
    for (size_t k = 0; k < rep; k++)
        memcpy(out + k * one, json_string_value(jc), one);
    out[one * rep] = '\0';
    return out;
}

static bool _fx_verb(const char *function)
{
    return function != NULL && strncmp(function, "peer_file_", 10) == 0;
}

static void _social_impl_free(ic_impl_t *impl)
{
    free(impl->ext);
    impl->ext = NULL;
    _fx_root_restore();
}

/* A private-proximity probe/reply payload the send hook grabbed for the current
 * round trip. ctx->captured records only (from, to, function), but the round
 * trip must RE-DELIVER the exact {salt, tags} the handler computed. While
 * g_prox_capture is on, _send_hook deep-copies the outbound proximity payload
 * here; _ic_run_proximity_probe consumes and frees it. Only one is ever live at
 * a time (the trip is strictly sequential), so a single slot suffices. */
static bool     g_prox_capture = false;
static bool     g_prox_have = false;
static uint8_t *g_prox_obj = NULL;   /* heap copy of net_msg.obj */
static size_t   g_prox_len = 0;
static char     g_prox_fn[PROC_NAME_LEN + 1] = {0};

static void _prox_capture_reset(void) {
    if (g_prox_obj != NULL) { free(g_prox_obj); g_prox_obj = NULL; }
    g_prox_len = 0;
    g_prox_fn[0] = '\0';
    g_prox_have = false;
}

static void _social_on_send(message_type_t type, const char *function,
                            generic_msg_t *msg)
{
    /* During a proximity round trip, grab the computed {salt, tags} payload so
     * it can be re-delivered to the other side — captured (from,to,function)
     * alone cannot carry it (see g_prox_capture). Keep only the LATEST proximity
     * emission; the trip consumes each before the next is produced. */
    /* The same capture carries a report's {seq, ts} to the reported side
     * (trigger_report): its seq is the reporter's freshness stamp, chosen at
     * run time, so it too cannot come from the scenario. */
    if (g_prox_capture && type == NET_MESSAGE
        && (strcmp(function, "peer_proximity_probe") == 0
            || strcmp(function, "peer_proximity_reply") == 0
            || strcmp(function, "peer_report") == 0)) {
        _prox_capture_reset();
        size_t n = msg->info.net_msg.len;
        if (msg->info.net_msg.obj != NULL && n > 0) {
            g_prox_obj = malloc(n);
            if (g_prox_obj != NULL) {
                memcpy(g_prox_obj, msg->info.net_msg.obj, n);
                g_prox_len = n;
                at_strlcpy(g_prox_fn, function, sizeof(g_prox_fn));
                g_prox_have = true;
            }
        }
    }
}

/* One private-proximity probe (Phase 2), end to end, inside the harness.
 *
 * The band is not a value a step can supply: each side derives keyed grid tags
 * from its OWN opt-in exact position and the pairwise box secret, and the two
 * only learn a band by intersecting tag sets. So the harness drives the real
 * chain of three handlers rather than pre-baking a payload:
 *   1. an app-verb request on the initiator (AT_APP_REQUEST_PROXIMITY) -> emits
 *      an encrypted probe {salt, tags} to the target;
 *   2. the target's handle_proximity_probe records its band and, if it opted in
 *      too, replies with its own tags under the same salt;
 *   3. the initiator's handle_proximity_reply records the same band.
 *
 * id_state.own_exact is a SINGLETON, so before running each side's handler we
 * swap it to that side's fixtures.exact_positions value; the CONNECTED edges and
 * the recorded bands are keyed by peer uuid, so both participants' entries
 * coexist in the shared maps. current_dispatcher is set per hop so the probe
 * emission is attributed to the initiator and the reply to the target
 * (proximity_probes/replies_emitted). ctx->captured drops payloads, so the
 * computed {salt, tags} is grabbed by _send_hook into g_prox_* and re-delivered
 * here (own copy, freed after). Mirrors the Python adapter's
 * _run_proximity_probe. Either side opting out short-circuits.
 */
static int _ic_run_proximity_probe(sce_run_ctx_t *ctx, ic_impl_t *initiator,
                                   ic_impl_t *target) {
    char targ_uuid[UUID_STRING_LEN + 1];
    _ic_uuid_str(target, targ_uuid);

    /* handle_request_proximity resolves the target's pubkey from the
     * initiator's peer list (identity_find_peer_pub). The Python adapter
     * cross-populates every participant's roster by default; the C adapter does
     * not (only the amnesia case), so ensure the target is present here or the
     * probe is never emitted. Idempotent. */
    {
        process_t *p = initiator->proc;
        bool have = false;
        peers_read_lock(p);
        for (size_t i = 0; i < p->protocol.num_peers; i++) {
            if (uuid_compare(p->protocol.peers[i].uuid, target->pub->uuid) == 0) {
                have = true;
                break;
            }
        }
        peers_read_unlock(p);
        if (!have) {
            peers_write_lock(p);
            if (p->protocol.num_peers < DEFAULT_MAX_PEERS) {
                memcpy(&p->protocol.peers[p->protocol.num_peers],
                       target->pub, sizeof(public_identity_t));
                p->protocol.num_peers++;
            }
            peers_write_unlock(p);
        }
    }

    g_prox_capture = true;
    _prox_capture_reset();

    /* 1. Trigger the initiator's probe. own_exact = initiator's; the emitted
     *    probe is attributed to the initiator. */
    identity_set_exact_position(_sx(initiator)->prox_exact_set,
                                _sx(initiator)->prox_exact_lat,
                                _sx(initiator)->prox_exact_lon);
    at_strlcpy(ctx->current_dispatcher, initiator->id,
               sizeof(ctx->current_dispatcher));
    {
        json_t *p = json_object();
        json_object_set_new(p, "peer", json_string(targ_uuid));
        generic_msg_t m = {0};
        m.type = NET_MESSAGE;
        strncpy(m.info.net_msg.process, "identity", PROC_NAME_LEN);
        m.info.net_msg.function = (char *)AT_APP_REQUEST_PROXIMITY;
        net_msg_pack_json(&m.info.net_msg, p);
        json_decref(p);
        run_message_handlers(initiator->proc, NULL, NET_MESSAGE, &m);
        if (m.info.net_msg.obj != NULL) smrt_deref(m.info.net_msg.obj);
    }
    if (!g_prox_have) {          /* initiator opted out: no probe, no band */
        g_prox_capture = false;
        _prox_capture_reset();
        return 0;
    }

    /* 2. Deliver the captured probe to the target. own_exact = target's; the
     *    reply it emits is attributed to the target. */
    {
        uint8_t *probe_obj = g_prox_obj;    /* detach so the reply capture below
                                             * does not clobber it */
        size_t probe_len = g_prox_len;
        g_prox_obj = NULL; g_prox_len = 0; g_prox_have = false;

        identity_set_exact_position(_sx(target)->prox_exact_set,
                                    _sx(target)->prox_exact_lat,
                                    _sx(target)->prox_exact_lon);
        at_strlcpy(ctx->current_dispatcher, target->id,
                   sizeof(ctx->current_dispatcher));
        generic_msg_t m = {0};
        m.type = NET_MESSAGE;
        strncpy(m.info.net_msg.process, "identity", PROC_NAME_LEN);
        m.info.net_msg.function = (char *)"peer_proximity_probe";
        memcpy(&m.info.net_msg.from_whom, initiator->pub,
               sizeof(public_identity_t));
        memcpy(&m.info.net_msg.to_whom, target->pub, sizeof(public_identity_t));
        m.info.net_msg.obj = probe_obj;
        m.info.net_msg.len = probe_len;
        run_message_handlers(target->proc, NULL, NET_MESSAGE, &m);
        free(probe_obj);
    }
    if (!g_prox_have) {          /* target opted out: recorded UNKNOWN, no reply */
        g_prox_capture = false;
        _prox_capture_reset();
        return 0;
    }

    /* 3. Deliver the captured reply to the initiator. own_exact = initiator's. */
    {
        uint8_t *reply_obj = g_prox_obj;
        size_t reply_len = g_prox_len;
        g_prox_obj = NULL; g_prox_len = 0; g_prox_have = false;

        identity_set_exact_position(_sx(initiator)->prox_exact_set,
                                    _sx(initiator)->prox_exact_lat,
                                    _sx(initiator)->prox_exact_lon);
        at_strlcpy(ctx->current_dispatcher, initiator->id,
                   sizeof(ctx->current_dispatcher));
        generic_msg_t m = {0};
        m.type = NET_MESSAGE;
        strncpy(m.info.net_msg.process, "identity", PROC_NAME_LEN);
        m.info.net_msg.function = (char *)"peer_proximity_reply";
        memcpy(&m.info.net_msg.from_whom, target->pub,
               sizeof(public_identity_t));
        memcpy(&m.info.net_msg.to_whom, initiator->pub,
               sizeof(public_identity_t));
        m.info.net_msg.obj = reply_obj;
        m.info.net_msg.len = reply_len;
        run_message_handlers(initiator->proc, NULL, NET_MESSAGE, &m);
        free(reply_obj);
    }

    g_prox_capture = false;
    _prox_capture_reset();
    return 0;
}

/* One report (Phase 4 P4.1), end to end: drive the REAL AT_APP_REPORT_PEER
 * handler on the reporter, then hand the peer_report it emitted to the reported
 * side's real handle_peer_report. The frame's seq is the reporter's freshness
 * stamp, chosen at run time, so the payload is grabbed by _send_hook (the
 * proximity capture) rather than built from the scenario.
 *
 * id_state is a SINGLETON here, so both participants' staged records land in
 * one map — keyed by SUBJECT uuid, which is what keeps the reporter's record
 * (about the target) and the target's (about the reporter) apart. The report
 * ledger is keyed the same way. A refused report emits nothing, so nothing is
 * delivered. Mirrors the Python adapter's _TRIGGER_REPORT. */
static int _ic_run_report(sce_run_ctx_t *ctx, ic_impl_t *reporter,
                          ic_impl_t *target) {
    /* handle_app_report_peer resolves the target from the reporter's peer
     * list; the C adapter does not cross-populate rosters (see
     * _ic_run_proximity_probe), so make sure it is there. Idempotent. */
    {
        process_t *p = reporter->proc;
        bool have = false;
        peers_read_lock(p);
        for (size_t i = 0; i < p->protocol.num_peers; i++) {
            if (uuid_compare(p->protocol.peers[i].uuid, target->pub->uuid) == 0) {
                have = true;
                break;
            }
        }
        peers_read_unlock(p);
        if (!have) {
            peers_write_lock(p);
            if (p->protocol.num_peers < DEFAULT_MAX_PEERS) {
                memcpy(&p->protocol.peers[p->protocol.num_peers],
                       target->pub, sizeof(public_identity_t));
                p->protocol.num_peers++;
            }
            peers_write_unlock(p);
        }
    }
    char targ_uuid[UUID_STRING_LEN + 1];
    _ic_uuid_str(target, targ_uuid);

    g_prox_capture = true;
    _prox_capture_reset();
    at_strlcpy(ctx->current_dispatcher, reporter->id,
               sizeof(ctx->current_dispatcher));
    {
        json_t *p = json_object();
        json_object_set_new(p, "peer", json_string(targ_uuid));
        generic_msg_t m = {0};
        m.type = NET_MESSAGE;
        strncpy(m.info.net_msg.process, "identity", PROC_NAME_LEN);
        m.info.net_msg.function = (char *)AT_APP_REPORT_PEER;
        net_msg_pack_json(&m.info.net_msg, p);
        json_decref(p);
        run_message_handlers(reporter->proc, NULL, NET_MESSAGE, &m);
        if (m.info.net_msg.obj != NULL) smrt_deref(m.info.net_msg.obj);
    }
    if (!g_prox_have || strcmp(g_prox_fn, "peer_report") != 0) {
        g_prox_capture = false;      /* refused: nothing went, nothing to pair */
        _prox_capture_reset();
        return 0;
    }
    uint8_t *obj = g_prox_obj;
    size_t len = g_prox_len;
    g_prox_obj = NULL; g_prox_len = 0; g_prox_have = false;
    g_prox_capture = false;

    at_strlcpy(ctx->current_dispatcher, target->id,
               sizeof(ctx->current_dispatcher));
    generic_msg_t m = {0};
    m.type = NET_MESSAGE;
    strncpy(m.info.net_msg.process, "identity", PROC_NAME_LEN);
    m.info.net_msg.function = (char *)"peer_report";
    memcpy(&m.info.net_msg.from_whom, reporter->pub, sizeof(public_identity_t));
    memcpy(&m.info.net_msg.to_whom, target->pub, sizeof(public_identity_t));
    m.info.net_msg.obj = obj;
    m.info.net_msg.len = len;
    run_message_handlers(target->proc, NULL, NET_MESSAGE, &m);
    free(obj);
    _prox_capture_reset();
    return 0;
}

static void _social_fixtures(sce_run_ctx_t *ctx, json_t *fixtures)
{
    /* positions: { "<participant>": "<geohash>", ... } (Increment 2, the
     * "with-distance" feature) — install each named participant's opt-in coarse
     * position via identity_set_own_geohash so its handle_position_query answers
     * with that bucket. id_state is a singleton per scenario, so a scenario opts
     * in exactly ONE participant (the responder); an unlisted participant is
     * opted OUT, the default. Mirrors the Python adapter reading
     * fixtures.positions into process.own_geohash. */
    json_t *positions = json_object_get(fixtures, "positions");
    if (json_is_object(positions))
    {
        const char *ppid;
        json_t *pval;
        json_object_foreach(positions, ppid, pval) {
            sce_participant_t *part = sce_find_participant(ctx, ppid);
            if (part == NULL) continue;
            ic_impl_t *impl = (ic_impl_t *)part->impl;
            if (impl == NULL || impl->proc == NULL) continue;
            identity_set_own_geohash(json_string_value(pval));
        }
    }

    /* profiles: { "<participant>": {<profile fields>}, ... } (Increment 3) —
     * install each named participant's opt-in agora.profile via
     * identity_set_own_profile so its handle_profile_query answers, signed.
     * Same singleton semantics as positions above. Mirrors the Python adapter
     * reading fixtures.profiles into process.own_profile. */
    json_t *profiles = json_object_get(fixtures, "profiles");
    if (json_is_object(profiles))
    {
        const char *fpid;
        json_t *fval;
        json_object_foreach(profiles, fpid, fval) {
            sce_participant_t *part = sce_find_participant(ctx, fpid);
            if (part == NULL) continue;
            ic_impl_t *impl = (ic_impl_t *)part->impl;
            if (impl == NULL || impl->proc == NULL) continue;
            char *pj = json_dumps(fval, JSON_COMPACT);
            if (pj != NULL) { identity_set_own_profile(pj); free(pj); }
        }
    }

    /* exact_positions: { "<participant>": [lat, lon], ... } (Phase 2, private
     * proximity) — park each named participant's opt-in EXACT position in its
     * impl. Unlike positions above this is NOT pushed into the singleton
     * id_state here: a proximity round trip needs BOTH sides' positions, so
     * _ic_run_proximity_probe swaps id_state.own_exact per side at dispatch.
     * Unlisted => opted OUT (the default). Mirrors the Python adapter storing
     * own_exact per participant. */
    json_t *exacts = json_object_get(fixtures, "exact_positions");
    if (json_is_object(exacts))
    {
        const char *epid;
        json_t *eval;
        json_object_foreach(exacts, epid, eval) {
            sce_participant_t *part = sce_find_participant(ctx, epid);
            if (part == NULL) continue;
            ic_impl_t *impl = (ic_impl_t *)part->impl;
            if (impl == NULL || impl->proc == NULL) continue;
            if (!json_is_array(eval) || json_array_size(eval) != 2) continue;
            json_t *jla = json_array_get(eval, 0);
            json_t *jlo = json_array_get(eval, 1);
            if (!json_is_number(jla) || !json_is_number(jlo)) continue;
            _sx(impl)->prox_exact_lat = json_number_value(jla);
            _sx(impl)->prox_exact_lon = json_number_value(jlo);
            _sx(impl)->prox_exact_set = true;
        }
    }

    /* connections: { "<participant>": ["<other>", ...], ... } (Increment 5) —
     * pre-seed CONNECTED edges directly, standing in for a completed request/
     * accept exchange so a scenario exercising a DOWNSTREAM connected-peers-only
     * feature (proximity) need not re-run the handshake. connection_edges is a
     * singleton map keyed by peer uuid, so both directions coexist. Mirrors the
     * Python adapter's fixtures.connections. */
    json_t *conns = json_object_get(fixtures, "connections");
    if (json_is_object(conns))
    {
        const char *cpid;
        json_t *cval;
        json_object_foreach(conns, cpid, cval) {
            if (!json_is_array(cval)) continue;
            size_t ci;
            json_t *other;
            json_array_foreach(cval, ci, other) {
                const char *other_pid = json_string_value(other);
                if (other_pid == NULL) continue;
                sce_participant_t *op = sce_find_participant(ctx, other_pid);
                if (op == NULL) continue;
                char other_uuid[UUID_STRING_LEN + 1];
                uuid_unparse_lower(((ic_impl_t *)op->impl)->pub->uuid, other_uuid);
                identity_set_connection_state(other_uuid, AT_CONN_CONNECTED);
            }
        }
    }

    /* customers: { "<participant>": { "<polity did>": {sat, bundle, seq} } }
     * (Phase 3 P3.2) — install CUSTOMER edges directly. The customer edge is the
     * RELAY GATE: only a node holding one carries a business's page, so this
     * fixture is what separates a re-advertising customer from a silent
     * bystander. identity_set_customer writes the edge WITHOUT advertising, so
     * the setup itself is not an emission. business_customers is a singleton map
     * keyed by did, matching the Python adapter's per-process set_customer()
     * with no queues. Mirrors the Python adapter's fixtures.customers. */
    json_t *custs = json_object_get(fixtures, "customers");
    if (json_is_object(custs))
    {
        const char *cust_pid;
        json_t *cust_val;
        json_object_foreach(custs, cust_pid, cust_val) {
            if (!json_is_object(cust_val)) continue;
            if (sce_find_participant(ctx, cust_pid) == NULL) continue;
            const char *cdid;
            json_t *cspec;
            json_object_foreach(cust_val, cdid, cspec) {
                if (!json_is_object(cspec)) continue;
                json_t *j_sat = json_object_get(cspec, "sat");
                json_t *j_bun = json_object_get(cspec, "bundle");
                json_t *j_seq = json_object_get(cspec, "seq");
                identity_set_customer(
                    cdid,
                    json_is_integer(j_sat) ? (int)json_integer_value(j_sat) : 0,
                    json_is_string(j_bun) ? json_string_value(j_bun) : "",
                    json_is_integer(j_seq) ? (int64_t)json_integer_value(j_seq) : 0);
            }
        }
    }
}

/* ---- Store-and-forward (Agora Phase 4 DDIL) --------------------------- */

/* Put @p pub on @p p's peer list if it is not there. The C adapter does not
 * cross-populate rosters the way the Python one does (every existing
 * participant knows every other; a `new_node` is known by none), so the three
 * store-and-forward verbs, which are honoured only from an admitted peer,
 * admit their sender on delivery by the same rule. Idempotent. */
static void _sf_admit(process_t *p, const public_identity_t *pub)
{
    bool have = false;
    peers_read_lock(p);
    for (size_t i = 0; i < p->protocol.num_peers; i++)
        if (uuid_compare(p->protocol.peers[i].uuid, pub->uuid) == 0)
            have = true;
    peers_read_unlock(p);
    if (have)
        return;
    peers_write_lock(p);
    if (p->protocol.num_peers < DEFAULT_MAX_PEERS) {
        memcpy(&p->protocol.peers[p->protocol.num_peers], pub,
               sizeof(public_identity_t));
        p->protocol.num_peers++;
    }
    peers_write_unlock(p);
}

static bool _sf_verb(const char *function)
{
    return function != NULL
        && (strcmp(function, "peer_post_digest") == 0
            || strcmp(function, "peer_post_want") == 0
            || strcmp(function, "peer_post_backfill") == 0);
}

/* Read a post scope from a scenario object: `community` and `labels`, or, for
 * the SIGNED scope, `signed_community` / `signed_labels` when present (a relay
 * that edits the scope is a scope the author did not sign). Labels are copied
 * as given, unvalidated, so a malformed scope can be put on the wire. */
static void _scope_from(json_t *obj, const char *ckey, const char *lkey,
                        at_post_scope_t *out)
{
    memset(out, 0, sizeof(*out));
    const char *c = json_string_value(json_object_get(obj, ckey));
    if (c != NULL)
        snprintf(out->community, sizeof(out->community), "%s", c);
    json_t *arr = json_object_get(obj, lkey);
    size_t i;
    json_t *v;
    if (json_is_array(arr))
        json_array_foreach(arr, i, v) {
            if (out->n_labels >= AT_POST_LABELS_MAX || !json_is_string(v))
                break;
            snprintf(out->labels[out->n_labels++], AT_POST_LABEL_MAX + 1, "%s",
                     json_string_value(v));
        }
}

static void _signed_scope(json_t *obj, at_post_scope_t *out)
{
    bool over = json_object_get(obj, "signed_community") != NULL
                || json_object_get(obj, "signed_labels") != NULL;
    if (over)
        _scope_from(obj, "signed_community", "signed_labels", out);
    else
        _scope_from(obj, "community", "labels", out);
}

static int _label_spec_id(sce_run_ctx_t *ctx, ic_impl_t *sender_impl, json_t *spec,
                          char id_out[AT_COMMUNITY_ID_HEX_LEN + 1]);
static json_t *_label_env(sce_run_ctx_t *ctx, ic_impl_t *sender_impl, json_t *spec);

/* The participant a post spec names as its `author`, else the step's sender. */
static ic_impl_t *_sf_author(sce_run_ctx_t *ctx, ic_impl_t *sender_impl,
                             json_t *spec)
{
    const char *pid = json_string_value(json_object_get(spec, "author"));
    sce_participant_t *ap = pid != NULL ? sce_find_participant(ctx, pid) : NULL;
    return ap != NULL ? (ic_impl_t *)ap->impl : sender_impl;
}

/* The content id of the post a spec describes, computed as the runtime does:
 * feed {author, seq, ts, tier, body}, business {author, polity, seq, ts,
 * bundle}. Scenarios cannot name ids (they are hashes), so they name posts. */
static int _sf_spec_id(sce_run_ctx_t *ctx, ic_impl_t *sender_impl, json_t *spec,
                       bool biz, char id_out[AT_POST_ID_HEX_LEN + 1])
{
    ic_impl_t *a = _sf_author(ctx, sender_impl, spec);
    if (a == NULL || a->full == NULL)
        return -1;
    json_t *jseq = json_object_get(spec, "seq");
    int64_t seq = json_is_integer(jseq) ? (int64_t)json_integer_value(jseq) : 1;
    json_t *jts = json_object_get(spec, "ts");
    double ts = json_is_number(jts) ? json_number_value(jts) : 0.0;
    if (biz) {
        const char *did = json_string_value(json_object_get(spec, "polity"));
        const char *bundle = json_string_value(json_object_get(spec, "bundle"));
        return at_business_post_content_id(a->full->uuid, did ? did : "", seq,
                                           ts, bundle ? bundle : "", id_out);
    }
    json_t *jtier = json_object_get(spec, "tier");
    int tier = json_is_integer(jtier) ? (int)json_integer_value(jtier) : 0;
    const char *body = json_string_value(json_object_get(spec, "body"));
    return at_post_content_id(a->full->uuid, seq, ts, (uint8_t)tier,
                              body ? body : "", id_out);
}

/* {"feed":[spec...], "biz":[spec...]} -> {"feed":[id...], "biz":[id...]}. */
static json_t *_sf_ids_body(sce_run_ctx_t *ctx, ic_impl_t *sender_impl,
                            json_t *payload, bool digest)
{
    json_t *out = json_object();
    /* Labels (Phase 4): a digest offers {id, community}, a want asks by id. */
    json_t *lspecs = json_object_get(payload, "label");
    if (out != NULL && json_is_array(lspecs)) {
        json_t *arr = json_array();
        size_t li;
        json_t *lspec;
        json_array_foreach(lspecs, li, lspec) {
            char id[AT_COMMUNITY_ID_HEX_LEN + 1];
            if (!json_is_object(lspec) || _label_spec_id(ctx, sender_impl, lspec, id) != 0)
                continue;
            const char *did = json_string_value(json_object_get(lspec, "community"));
            if (digest)
                json_array_append_new(arr, json_pack("{s:s, s:s}", "id", id,
                                                     "community", did ? did : ""));
            else
                json_array_append_new(arr, json_string(id));
        }
        json_object_set_new(out, "label", arr);
    }
    for (int k = 0; out != NULL && k < 2; k++) {
        const char *key = k == 0 ? "feed" : "biz";
        json_t *arr = json_array();
        json_t *specs = json_object_get(payload, key);
        size_t i;
        json_t *spec;
        if (json_is_array(specs))
            json_array_foreach(specs, i, spec) {
                char id[AT_POST_ID_HEX_LEN + 1];
                if (json_is_object(spec)
                    && _sf_spec_id(ctx, sender_impl, spec, k == 1, id) == 0)
                    json_array_append_new(arr, json_string(id));
            }
        json_object_set_new(out, key, arr);
    }
    return out;
}

/* One post's signed envelope, as its author would have sent it. `sig`
 * overrides the signature (bad-signature drop). */
static json_t *_sf_post_env(sce_run_ctx_t *ctx, ic_impl_t *sender_impl,
                            json_t *spec, bool biz)
{
    ic_impl_t *a = _sf_author(ctx, sender_impl, spec);
    if (a == NULL || a->full == NULL)
        return NULL;
    json_t *jseq = json_object_get(spec, "seq");
    int64_t seq = json_is_integer(jseq) ? (int64_t)json_integer_value(jseq) : 1;
    json_t *jts = json_object_get(spec, "ts");
    double ts = json_is_number(jts) ? json_number_value(jts) : 0.0;
    json_t *jhops = json_object_get(spec, "hops");
    int hops = json_is_integer(jhops) ? (int)json_integer_value(jhops) : 0;
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    sodium_bin2hex(pk_hex, sizeof(pk_hex), a->full->signature.public,
                   crypto_sign_PUBLICKEYBYTES);
    const char *sig_over = json_string_value(json_object_get(spec, "sig"));
    if (biz) {
        const char *did = json_string_value(json_object_get(spec, "polity"));
        const char *bundle = json_string_value(json_object_get(spec, "bundle"));
        char sig[AT_BUSINESS_POST_SIG_HEX_LEN + 1] = {0};
        if (sig_over != NULL)
            snprintf(sig, sizeof(sig), "%s", sig_over);
        else
            at_business_post_sign(a->full->signature.private, a->full->uuid,
                                  did ? did : "", seq, ts, bundle ? bundle : "",
                                  sig);
        return at_business_post_to_json(a->full->uuid, pk_hex, did ? did : "",
                                        seq, ts, bundle ? bundle : "", sig, hops);
    }
    json_t *jtier = json_object_get(spec, "tier");
    int tier = json_is_integer(jtier) ? (int)json_integer_value(jtier) : 0;
    const char *body = json_string_value(json_object_get(spec, "body"));
    char sig[AT_POST_SIG_HEX_LEN + 1] = {0};
    if (sig_over != NULL)
        snprintf(sig, sizeof(sig), "%s", sig_over);
    else
        at_post_sign(a->full->signature.private, a->full->uuid, seq, ts,
                     (uint8_t)tier, body ? body : "", sig);
    return at_post_to_json(a->full->uuid, pk_hex, seq, ts, (uint8_t)tier,
                           body ? body : "", sig, hops);
}

/* One moderator label's envelope (Phase 4): {author?, community, post_id, seq,
 * ts, bundle, hops, sig?, author_pk?}, signed by its `author` (default: the
 * sender) exactly as identity_publish_post_label would. */
static json_t *_label_env(sce_run_ctx_t *ctx, ic_impl_t *sender_impl, json_t *spec)
{
    ic_impl_t *a = _sf_author(ctx, sender_impl, spec);
    if (a == NULL || a->full == NULL)
        return NULL;
    const char *did = json_string_value(json_object_get(spec, "community"));
    const char *pid = json_string_value(json_object_get(spec, "post_id"));
    const char *bundle = json_string_value(json_object_get(spec, "bundle"));
    json_t *jseq = json_object_get(spec, "seq");
    int64_t seq = json_is_integer(jseq) ? (int64_t)json_integer_value(jseq) : 1;
    json_t *jts = json_object_get(spec, "ts");
    double ts = json_is_number(jts) ? json_number_value(jts) : 0.0;
    json_t *jhops = json_object_get(spec, "hops");
    int hops = json_is_integer(jhops) ? (int)json_integer_value(jhops) : 0;
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    const char *pk_over = json_string_value(json_object_get(spec, "author_pk"));
    if (pk_over != NULL)
        snprintf(pk_hex, sizeof(pk_hex), "%s", pk_over);
    else
        sodium_bin2hex(pk_hex, sizeof(pk_hex), a->full->signature.public,
                       crypto_sign_PUBLICKEYBYTES);
    char sig[AT_COMMUNITY_SIG_HEX_LEN + 1] = {0};
    const char *sig_over = json_string_value(json_object_get(spec, "sig"));
    if (sig_over != NULL)
        snprintf(sig, sizeof(sig), "%s", sig_over);
    else
        at_post_label_sign(a->full->signature.private, a->full->uuid,
                           did ? did : "", pid ? pid : "", seq, ts,
                           bundle ? bundle : "", sig);
    return at_post_label_to_json(a->full->uuid, pk_hex, did ? did : "",
                                 pid ? pid : "", seq, ts, bundle ? bundle : "",
                                 sig, hops);
}

/* A label spec's content id, as the runtime computes it. */
static int _label_spec_id(sce_run_ctx_t *ctx, ic_impl_t *sender_impl, json_t *spec,
                          char id_out[AT_COMMUNITY_ID_HEX_LEN + 1])
{
    ic_impl_t *a = _sf_author(ctx, sender_impl, spec);
    if (a == NULL || a->full == NULL)
        return -1;
    json_t *jseq = json_object_get(spec, "seq");
    json_t *jts = json_object_get(spec, "ts");
    const char *did = json_string_value(json_object_get(spec, "community"));
    const char *pid = json_string_value(json_object_get(spec, "post_id"));
    const char *bundle = json_string_value(json_object_get(spec, "bundle"));
    return at_post_label_id(a->full->uuid, did ? did : "", pid ? pid : "",
                            json_is_integer(jseq) ? (int64_t)json_integer_value(jseq) : 1,
                            json_is_number(jts) ? json_number_value(jts) : 0.0,
                            bundle ? bundle : "", id_out);
}

static int _social_inbound(sce_run_ctx_t *ctx, sce_participant_t *sender,
                           ic_impl_t *sender_impl, const char *from_id,
                           const char *to_id, const char *function,
                           json_t *payload, generic_msg_t *out)
{
    (void)ctx; (void)sender; (void)sender_impl; (void)from_id; (void)to_id;
    /* The social pseudo-functions that carry a payload (identity.c packs its
     * own the same way). */
    if ((strcmp(function, "trigger_block") == 0
         || strcmp(function, "trigger_unblock") == 0
         || strcmp(function, "trigger_report") == 0
         || strcmp(function, "trigger_follow_community") == 0
         || strcmp(function, "trigger_unfollow_community") == 0
         || strcmp(function, "trigger_publish_post_label") == 0
         || strncmp(function, "trigger_file_", 13) == 0)
        && json_is_object(payload)) {
        json_t *body = json_deep_copy(payload);
        if (body != NULL) {
            net_msg_pack_json(&out->info.net_msg, body);
            json_decref(body);
        }
        return 0;
    }

    /* File sharing. A scenario names CONTENT, never bytes or hashes: an offer
     * {id, name, content, chunk?} gets its size, total and BLAKE2b computed
     * here as the sender's node computes them (`repeat: N` repeats the
     * content), and a chunk {id, i, content, chunk?, corrupt?} is sliced from the same content and base64-encoded
     * (`corrupt: true` flips its first byte, a sender whose bytes are not what
     * it hashed). `ts` defaults to now, so an offer is never stale. Every other
     * field passes through, so a malformed frame can still be written by hand.
     * ctl and req pass through whole. Mirrors the Python file builders. */
    if (_fx_verb(function) && json_is_object(payload)) {
        json_t *body = json_deep_copy(payload);
        char *content = _fx_content(payload);
        size_t clen = content != NULL ? strlen(content) : 0;
        json_t *jchunk = json_object_get(payload, "chunk");
        size_t chunk = json_is_integer(jchunk) ? (size_t)json_integer_value(jchunk) : 1024;
        if (chunk == 0) chunk = 1024;
        json_object_del(body, "content");
        json_object_del(body, "repeat");
        json_object_del(body, "corrupt");
        if (strcmp(function, "peer_file_offer") == 0) {
            if (content != NULL) {
                uint8_t h[32];
                char hex[65];
                crypto_generichash(h, sizeof(h), (const unsigned char *)content, clen, NULL, 0);
                for (int k = 0; k < 32; k++)
                    snprintf(hex + 2 * k, 3, "%02x", h[k]);
                json_object_set_new(body, "size", json_integer((json_int_t)clen));
                json_object_set_new(body, "chunk", json_integer((json_int_t)chunk));
                json_object_set_new(body, "total",
                                    json_integer((json_int_t)((clen + chunk - 1) / chunk)));
                if (json_object_get(body, "hash") == NULL)
                    json_object_set_new(body, "hash", json_string(hex));
            }
            if (json_object_get(body, "ts") == NULL)
                json_object_set_new(body, "ts", json_real((double)time(NULL)));
        } else if (strcmp(function, "peer_file_chunk") == 0 && content != NULL) {
            json_t *ji = json_object_get(payload, "i");
            size_t i = json_is_integer(ji) ? (size_t)json_integer_value(ji) : 0;
            size_t off = i * chunk;
            size_t len = off < clen ? (clen - off < chunk ? clen - off : chunk) : 0;
            uint8_t *raw = malloc(len + 1);
            if (raw != NULL) {
                memcpy(raw, content + (off < clen ? off : 0), len);
                if (len > 0 && json_is_true(json_object_get(payload, "corrupt")))
                    raw[0] ^= 0xff;
                size_t enc = sodium_base64_encoded_len(len, sodium_base64_VARIANT_ORIGINAL);
                char *b64 = malloc(enc);
                if (b64 != NULL) {
                    sodium_bin2base64(b64, enc, raw, len, sodium_base64_VARIANT_ORIGINAL);
                    json_object_set_new(body, "data", json_string(b64));
                    free(b64);
                }
                free(raw);
            }
            json_object_del(body, "chunk");
        }
        free(content);
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }

    /* peer_position_response — pack {pos, seq} as the envelope
     * handle_position_response expects (Increment 2, the "with-distance"
     * feature). `pos` is the opaque geohash bucket; `seq` is the responder's
     * freshness sequence (_ic_set_seq honors `unstamped: true` by omitting it,
     * so the replay/unstamped-refusal case is exercised the same way caps is).
     * Mirrors the Python position_response builder; peer_position_query needs
     * no branch (empty payload, generic path, like caps_query). Without this
     * the C handler sees no payload and silently no-ops. */
    if (strcmp(function, "peer_position_response") == 0 && json_is_object(payload)) {
        json_t *body = json_object();
        json_t *jpos = json_object_get(payload, "pos");
        json_object_set_new(body, "pos",
                            json_string(json_is_string(jpos)
                                        ? json_string_value(jpos) : ""));
        _ic_set_seq(body, payload);
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }

    /* peer_profile_response — pack {profile, sig, seq} (Increment 3). The
     * `profile` object comes from the scenario; the signature is computed over
     * the SENDER's canonical form (sender uuid + profile) with the sender's own
     * key, exactly as the real handle_profile_query would — so a C receiver
     * verifies a signature this adapter produced, and cross-runtime a Python
     * receiver does too. A scenario may override `sig` with an explicit string
     * to exercise the bad-signature drop. `seq` honors `unstamped` via
     * _ic_set_seq, like the position/caps builders. */
    if (strcmp(function, "peer_profile_response") == 0 && json_is_object(payload)) {
        json_t *jprof = json_object_get(payload, "profile");
        at_profile_t pp;
        memset(&pp, 0, sizeof(pp));
        if (json_is_object(jprof))
            at_profile_from_json(jprof, false, &pp);
        char sig[AT_PROFILE_SIG_HEX_LEN + 1] = {0};
        json_t *jsig = json_object_get(payload, "sig");
        if (json_is_string(jsig))
            snprintf(sig, sizeof(sig), "%s", json_string_value(jsig));
        else if (sender_impl != NULL && sender_impl->full != NULL)
            at_profile_sign(sender_impl->full->signature.private,
                            sender_impl->full->uuid, &pp, sig);
        json_t *body = json_object();
        json_t *pj = at_profile_to_json(&pp);
        json_object_set_new(body, "profile", pj != NULL ? pj : json_object());
        json_object_set_new(body, "sig", json_string(sig));
        _ic_set_seq(body, payload);
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }

    /* peer_connection_request — no payload; the handler reads only from_whom
     * (the requester). The generic path packs an empty body, like caps_query. */

    /* peer_connection_response — pack {decision, sig, seq} (Increment 5). The
     * signature is computed over the canonical (requester, accepter, decision,
     * seq) form with the SENDER's (accepter's) key: requester is the recipient
     * (to_id), accepter is the sender — exactly as the real
     * handle_app_connect_respond would sign it. A scenario may override `sig`
     * (bad-signature drop). `accept` (bool) selects the decision; `seq` /
     * `unstamped` are honored like the profile builder, so replay is exercised
     * the same way. */
    if (strcmp(function, "peer_connection_response") == 0 && json_is_object(payload)) {
        int decision = json_is_true(json_object_get(payload, "accept")) ? 1 : 0;
        bool unstamped = json_is_true(json_object_get(payload, "unstamped"));
        int64_t seq = _ic_step_seq(payload, "seq");
        sce_participant_t *recip = sce_find_participant(ctx, to_id);
        char sig[AT_CONNECTION_SIG_HEX_LEN + 1] = {0};
        json_t *jsig = json_object_get(payload, "sig");
        if (json_is_string(jsig))
            snprintf(sig, sizeof(sig), "%s", json_string_value(jsig));
        else if (sender_impl != NULL && sender_impl->full != NULL
                 && recip != NULL && recip->impl != NULL) {
            const public_identity_t *rpub = ((ic_impl_t *)recip->impl)->pub;
            at_connection_sign(sender_impl->full->signature.private,
                               rpub->uuid, sender_impl->full->uuid,
                               (uint8_t)decision, (uint64_t)seq, sig);
        }
        json_t *body = json_object();
        json_object_set_new(body, "decision", json_integer(decision));
        json_object_set_new(body, "sig", json_string(sig));
        if (!unstamped)
            json_object_set_new(body, "seq", json_integer((json_int_t)seq));
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }

    /* peer_dm — pack {text, seq, ts} (Increment 6). A DM carries no signature
     * (crypto_box authenticates the sender on the wire; in the harness the
     * from_whom identity stands in), so this is the trivial payload builder:
     * `text` and `ts` from the scenario, `seq` honored via _ic_set_seq so
     * `unstamped: true` drops it and the replay/unstamped-refusal case is
     * exercised the same way the position/profile responses are. Mirrors the
     * Python peer_dm builder. */
    if (strcmp(function, "peer_dm") == 0 && json_is_object(payload)) {
        json_t *body = json_object();
        json_t *jtext = json_object_get(payload, "text");
        json_t *jts = json_object_get(payload, "ts");
        json_object_set_new(body, "text",
                            json_string(json_is_string(jtext)
                                        ? json_string_value(jtext) : ""));
        json_object_set_new(body, "ts",
                            json_real(json_is_number(jts)
                                      ? json_number_value(jts) : 0.0));
        _ic_set_seq(body, payload);
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }

    /* Store-and-forward (Agora Phase 4 DDIL). peer_post_digest and
     * peer_post_want carry content ids, which a scenario cannot name, so it
     * names POSTS ({"feed":[{author, seq, ts, tier, body}], "biz":[{author,
     * polity, seq, ts, bundle}]}) and the ids are computed here as the runtime
     * computes them. peer_post_backfill carries one post's envelope, signed by
     * its `author` (default: the sender), {"kind", "post": {...}}. Mirrors the
     * Python builders. */
    if ((strcmp(function, "peer_post_digest") == 0
         || strcmp(function, "peer_post_want") == 0) && json_is_object(payload)) {
        json_t *body = _sf_ids_body(ctx, sender_impl, payload,
                                    strcmp(function, "peer_post_digest") == 0);
        if (body == NULL)
            return -1;
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }
    if (strcmp(function, "peer_post_backfill") == 0 && json_is_object(payload)) {
        const char *kind = json_string_value(json_object_get(payload, "kind"));
        json_t *spec = json_object_get(payload, "post");
        json_t *env = !json_is_object(spec) ? NULL
            : (kind != NULL && strcmp(kind, "label") == 0)
                ? _label_env(ctx, sender_impl, spec)
                : _sf_post_env(ctx, sender_impl, spec,
                               kind != NULL && strcmp(kind, "biz") == 0);
        if (env == NULL) {
            snprintf(ctx->err, sizeof(ctx->err),
                     "peer_post_backfill: could not build the post envelope");
            return -1;
        }
        json_t *body = json_object();
        json_object_set_new(body, "kind", json_string(kind ? kind : "feed"));
        json_object_set_new(body, "post", env);
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }

    /* peer_post — pack the group-multicast feed post {author, author_pk, seq, ts,
     * tier, body, sig, hops} (Increment 7). The post is SIGNED with the SENDER's
     * (author's) key over the canonical (author, seq, ts, tier, body) form,
     * exactly as handle_app_publish_post would; author/author_pk name the sender.
     * A scenario may override `sig` (bad-signature drop) and `author_pk`
     * (impersonation). `body`/`text`, `ts`, `tier`, `hops` come from the scenario;
     * `seq` is honored via _ic_step_seq. Mirrors the Python peer_post builder. */
    if (strcmp(function, "peer_post") == 0 && json_is_object(payload)) {
        json_t *jbody = json_object_get(payload, "body");
        if (!json_is_string(jbody)) jbody = json_object_get(payload, "text");
        const char *body_str = json_is_string(jbody) ? json_string_value(jbody) : "";
        int64_t seq = _ic_step_seq(payload, "seq");
        json_t *jts = json_object_get(payload, "ts");
        double ts = json_is_number(jts) ? json_number_value(jts) : 0.0;
        json_t *jtier = json_object_get(payload, "tier");
        int tier = json_is_integer(jtier) ? (int)json_integer_value(jtier) : 0;
        json_t *jhops = json_object_get(payload, "hops");
        int hops = json_is_integer(jhops) ? (int)json_integer_value(jhops) : 0;

        /* author_pk: the sender's ed25519 signing pubkey hex, unless overridden. */
        char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1] = {0};
        json_t *jpk = json_object_get(payload, "author_pk");
        if (json_is_string(jpk))
            snprintf(pk_hex, sizeof(pk_hex), "%s", json_string_value(jpk));
        else if (sender_impl != NULL && sender_impl->full != NULL)
            sodium_bin2hex(pk_hex, sizeof(pk_hex),
                           sender_impl->full->signature.public,
                           crypto_sign_PUBLICKEYBYTES);

        /* sig over the canonical form with the sender's key, unless overridden. */
        char sig[AT_POST_SIG_HEX_LEN + 1] = {0};
        json_t *jsig = json_object_get(payload, "sig");
        if (json_is_string(jsig))
            snprintf(sig, sizeof(sig), "%s", json_string_value(jsig));
        else if (sender_impl != NULL && sender_impl->full != NULL) {
            /* The scope the AUTHOR signed (Phase 4), which a scenario may make
             * differ from the one on the envelope. */
            at_post_scope_t signed_scope;
            _signed_scope(payload, &signed_scope);
            at_post_sign_scoped(sender_impl->full->signature.private,
                                sender_impl->full->uuid, seq, ts, (uint8_t)tier,
                                body_str, &signed_scope, sig);
        }

        json_t *env = json_object();
        if (sender_impl != NULL && sender_impl->full != NULL) {
            char author_str[UUID_STRING_LEN + 1];
            uuid_unparse_lower(sender_impl->full->uuid, author_str);
            json_object_set_new(env, "author", json_string(author_str));
        } else {
            json_object_set_new(env, "author", json_string(""));
        }
        json_object_set_new(env, "author_pk", json_string(pk_hex));
        json_object_set_new(env, "seq", json_integer((json_int_t)seq));
        json_object_set_new(env, "ts", json_real(ts));
        json_object_set_new(env, "tier", json_integer(tier));
        json_object_set_new(env, "body", json_string(body_str));
        json_object_set_new(env, "sig", json_string(sig));
        json_object_set_new(env, "hops", json_integer(hops));
        /* The scope keys, only when the scenario names them. */
        json_t *jcomm = json_object_get(payload, "community");
        json_t *jlabels = json_object_get(payload, "labels");
        if (jcomm != NULL)
            json_object_set(env, "community", jcomm);
        if (jlabels != NULL)
            json_object_set(env, "labels", jlabels);
        net_msg_pack_json(&out->info.net_msg, env);
        json_decref(env);
        return 0;
    }

    /* peer_community_policy (Phase 4) — {carrier, carrier_pk, community, seq,
     * ts, bundle, sig}, signed by the SENDER in the first person, as
     * _policy_advertise would. `sig` / `carrier_pk` override. */
    if (strcmp(function, "peer_community_policy") == 0 && json_is_object(payload)) {
        if (sender_impl == NULL || sender_impl->full == NULL)
            return -1;
        const char *did = json_string_value(json_object_get(payload, "community"));
        const char *bundle = json_string_value(json_object_get(payload, "bundle"));
        json_t *jseq = json_object_get(payload, "seq");
        int64_t seq = json_is_integer(jseq) ? (int64_t)json_integer_value(jseq) : 0;
        json_t *jts = json_object_get(payload, "ts");
        double ts = json_is_number(jts) ? json_number_value(jts) : 0.0;
        char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
        const char *pk_over = json_string_value(json_object_get(payload, "carrier_pk"));
        if (pk_over != NULL)
            snprintf(pk_hex, sizeof(pk_hex), "%s", pk_over);
        else
            sodium_bin2hex(pk_hex, sizeof(pk_hex), sender_impl->full->signature.public,
                           crypto_sign_PUBLICKEYBYTES);
        char sig[AT_COMMUNITY_SIG_HEX_LEN + 1] = {0};
        const char *sig_over = json_string_value(json_object_get(payload, "sig"));
        if (sig_over != NULL)
            snprintf(sig, sizeof(sig), "%s", sig_over);
        else
            at_policy_ad_sign(sender_impl->full->signature.private,
                              sender_impl->full->uuid, did ? did : "", seq, ts,
                              bundle ? bundle : "", sig);
        json_t *env = at_policy_ad_to_json(sender_impl->full->uuid, pk_hex,
                                           did ? did : "", seq, ts,
                                           bundle ? bundle : "", sig);
        if (env == NULL)
            return -1;
        net_msg_pack_json(&out->info.net_msg, env);
        json_decref(env);
        return 0;
    }

    /* peer_post_label (Phase 4) — see _label_env. */
    if (strcmp(function, "peer_post_label") == 0 && json_is_object(payload)) {
        json_t *env = _label_env(ctx, sender_impl, payload);
        if (env == NULL) {
            snprintf(ctx->err, sizeof(ctx->err),
                     "peer_post_label: could not build the label envelope");
            return -1;
        }
        net_msg_pack_json(&out->info.net_msg, env);
        json_decref(env);
        return 0;
    }

    /* peer_business_ad — pack the group-multicast business ad {advertiser,
     * advertiser_pk, polity, sat, seq, ts, bundle, sig} (Phase 3 P3.2). The ad
     * is SIGNED with the SENDER's key over the canonical (advertiser, polity,
     * sat, seq, ts, bundle) form, exactly as _business_advertise would — the
     * sender always speaks for ITSELF, since an ad is never relayed, only
     * re-advertised in the first person. Note there is no `hops`. A scenario may
     * override `sig` (bad-signature drop) and `advertiser_pk` (impersonation).
     * Mirrors the Python peer_business_ad builder. */
    if (strcmp(function, "peer_business_ad") == 0 && json_is_object(payload)) {
        json_t *jdid = json_object_get(payload, "polity");
        const char *did_str = json_is_string(jdid) ? json_string_value(jdid) : "";
        json_t *jbundle = json_object_get(payload, "bundle");
        const char *bundle_str =
            json_is_string(jbundle) ? json_string_value(jbundle) : "";
        json_t *jsat = json_object_get(payload, "sat");
        unsigned sat = json_is_integer(jsat) ? (unsigned)json_integer_value(jsat)
                                             : AT_BUSINESS_SAT_SELF;
        /* `seq` here is the PAGE VERSION, not a freshness seq, so it is read
         * straight from the payload rather than through _ic_step_seq. */
        json_t *jseq = json_object_get(payload, "seq");
        int64_t seq = json_is_integer(jseq) ? (int64_t)json_integer_value(jseq) : 0;
        json_t *jts = json_object_get(payload, "ts");
        double ts = json_is_number(jts) ? json_number_value(jts) : 0.0;

        /* advertiser_pk: the sender's ed25519 signing pubkey hex, unless overridden. */
        char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1] = {0};
        json_t *jpk = json_object_get(payload, "advertiser_pk");
        if (json_is_string(jpk))
            snprintf(pk_hex, sizeof(pk_hex), "%s", json_string_value(jpk));
        else if (sender_impl != NULL && sender_impl->full != NULL)
            sodium_bin2hex(pk_hex, sizeof(pk_hex),
                           sender_impl->full->signature.public,
                           crypto_sign_PUBLICKEYBYTES);

        /* sig over the canonical form with the sender's key, unless overridden. */
        char sig[AT_BUSINESS_AD_SIG_HEX_LEN + 1] = {0};
        json_t *jsig = json_object_get(payload, "sig");
        if (json_is_string(jsig))
            snprintf(sig, sizeof(sig), "%s", json_string_value(jsig));
        else if (sender_impl != NULL && sender_impl->full != NULL)
            at_business_ad_sign(sender_impl->full->signature.private,
                                sender_impl->full->uuid, did_str, (uint8_t)sat,
                                seq, ts, bundle_str, sig);

        json_t *env = NULL;
        if (sender_impl != NULL && sender_impl->full != NULL) {
            env = at_business_ad_to_json(sender_impl->full->uuid, pk_hex, did_str,
                                         (uint8_t)sat, seq, ts, bundle_str, sig);
        }
        if (env == NULL) {
            snprintf(ctx->err, sizeof(ctx->err),
                     "peer_business_ad: could not build the ad envelope");
            return -1;
        }
        net_msg_pack_json(&out->info.net_msg, env);
        json_decref(env);
        return 0;
    }

    /* peer_business_post — pack the group-multicast business post {author,
     * author_pk, polity, seq, ts, bundle, sig, hops} (Phase 3 P3.4). The post
     * is SIGNED with the SENDER's key over the canonical (author, polity, seq,
     * ts, bundle) form — which is what a RELAY does too, since the signature
     * says only who sent this copy. HOPS IS OUTSIDE THE SIGNATURE, so a
     * scenario can set it to drive the relay bound without breaking anything.
     * A scenario may override `sig` (bad-signature drop) and `author_pk`
     * (impersonation). Mirrors the Python peer_business_post builder. */
    if (strcmp(function, "peer_business_post") == 0 && json_is_object(payload)) {
        json_t *jdid = json_object_get(payload, "polity");
        const char *did_str = json_is_string(jdid) ? json_string_value(jdid) : "";
        json_t *jbundle = json_object_get(payload, "bundle");
        const char *bundle_str =
            json_is_string(jbundle) ? json_string_value(jbundle) : "";
        /* `seq` is the BUSINESS's post counter, not a freshness seq, so it is
         * read straight from the payload rather than through _ic_step_seq. */
        json_t *jseq = json_object_get(payload, "seq");
        int64_t seq = json_is_integer(jseq) ? (int64_t)json_integer_value(jseq) : 0;
        json_t *jts = json_object_get(payload, "ts");
        double ts = json_is_number(jts) ? json_number_value(jts) : 0.0;
        json_t *jhops = json_object_get(payload, "hops");
        int hops = json_is_integer(jhops) ? (int)json_integer_value(jhops) : 0;

        /* author_pk: the sender's ed25519 signing pubkey hex, unless overridden. */
        char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1] = {0};
        json_t *jpk = json_object_get(payload, "author_pk");
        if (json_is_string(jpk))
            snprintf(pk_hex, sizeof(pk_hex), "%s", json_string_value(jpk));
        else if (sender_impl != NULL && sender_impl->full != NULL)
            sodium_bin2hex(pk_hex, sizeof(pk_hex),
                           sender_impl->full->signature.public,
                           crypto_sign_PUBLICKEYBYTES);

        /* sig over the canonical form with the sender's key, unless overridden. */
        char sig[AT_BUSINESS_POST_SIG_HEX_LEN + 1] = {0};
        json_t *jsig = json_object_get(payload, "sig");
        if (json_is_string(jsig))
            snprintf(sig, sizeof(sig), "%s", json_string_value(jsig));
        else if (sender_impl != NULL && sender_impl->full != NULL)
            at_business_post_sign(sender_impl->full->signature.private,
                                  sender_impl->full->uuid, did_str, seq, ts,
                                  bundle_str, sig);

        json_t *env = NULL;
        if (sender_impl != NULL && sender_impl->full != NULL) {
            env = at_business_post_to_json(sender_impl->full->uuid, pk_hex,
                                           did_str, seq, ts, bundle_str, sig,
                                           hops);
        }
        if (env == NULL) {
            snprintf(ctx->err, sizeof(ctx->err),
                     "peer_business_post: could not build the post envelope");
            return -1;
        }
        net_msg_pack_json(&out->info.net_msg, env);
        json_decref(env);
        return 0;
    }

    /* peer_reaction — pack {post_id, seq, ts} (Increment 8). A reaction carries no
     * signature (crypto_box authenticates the reactor on the wire; in the harness
     * the from_whom identity stands in). `post_id` and `ts` come from the scenario;
     * `seq` is honored via _ic_set_seq so `unstamped: true` drops it. Mirrors the
     * Python peer_reaction builder. */
    if (strcmp(function, "peer_reaction") == 0 && json_is_object(payload)) {
        json_t *body = json_object();
        json_t *jpid = json_object_get(payload, "post_id");
        json_t *jts = json_object_get(payload, "ts");
        json_object_set_new(body, "post_id",
                            json_string(json_is_string(jpid)
                                        ? json_string_value(jpid) : ""));
        json_object_set_new(body, "ts",
                            json_real(json_is_number(jts)
                                      ? json_number_value(jts) : 0.0));
        _ic_set_seq(body, payload);
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }

    /* peer_report — pack {seq, ts} and nothing else (Phase 4 P4.1). No
     * signature: crypto_box authenticates the reporter on the wire (in the
     * harness the from_whom identity stands in). `unstamped: true` drops the
     * seq via _ic_set_seq. Mirrors the Python peer_report builder. */
    if (strcmp(function, "peer_report") == 0 && json_is_object(payload)) {
        json_t *body = json_object();
        json_t *jts = json_object_get(payload, "ts");
        json_object_set_new(body, "ts",
                            json_real(json_is_number(jts)
                                      ? json_number_value(jts) : 0.0));
        _ic_set_seq(body, payload);
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }

    /* peer_cosign_request — pack {record, op, polity, cid, bytes, seq, ts}
     * (Phase 3 P3.3). A co-signing ask carries NO signature: it is directed and
     * encrypted, so crypto_box authenticates the asker (in the harness the
     * from_whom identity stands in).
     *
     * EVERY FIELD IS PASSED THROUGH VERBATIM, deliberately. Building it with
     * at_cosign_request_to_json would let the BUILDER refuse a malformed ask, and
     * then the refusal scenarios would prove nothing about the handler — which is
     * the side a hostile peer actually reaches. A hand-built message from a peer
     * is exactly what the parser exists for. `seq` is honored via _ic_set_seq so
     * `unstamped: true` drops it. Mirrors the Python peer_cosign_request builder.
     *
     * There is no `description` field to build, and that is the point: the
     * wording of what is being signed is derived on the SIGNER's node from the
     * bytes (see social/cosign.h). */
    if (strcmp(function, "peer_cosign_request") == 0 && json_is_object(payload)) {
        static const char *keys[] = {"record", "op", "polity", "cid", "bytes"};
        json_t *body = json_object();
        for (size_t k = 0; k < sizeof(keys) / sizeof(keys[0]); k++) {
            json_t *v = json_object_get(payload, keys[k]);
            json_object_set_new(body, keys[k],
                                json_string(json_is_string(v)
                                            ? json_string_value(v) : ""));
        }
        json_t *jts = json_object_get(payload, "ts");
        json_object_set_new(body, "ts",
                            json_real(json_is_number(jts)
                                      ? json_number_value(jts) : 0.0));
        /* A scenario may smuggle a description in to prove it is ignored. */
        json_t *jdesc = json_object_get(payload, "description");
        if (json_is_string(jdesc))
            json_object_set_new(body, "description",
                                json_string(json_string_value(jdesc)));
        _ic_set_seq(body, payload);
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }

    /* peer_cosign_sig — pack {cid, signer, sig, seq, ts} (Phase 3 P3.3): the
     * signer's half coming back to the node authoring the exchange. Passed
     * through verbatim for the same reason as the ask. The core does NOT verify
     * the signature here and cannot — it does not hold the payload the signature
     * is over. Mirrors the Python peer_cosign_sig builder. */
    if (strcmp(function, "peer_cosign_sig") == 0 && json_is_object(payload)) {
        static const char *keys[] = {"cid", "signer", "sig"};
        json_t *body = json_object();
        for (size_t k = 0; k < sizeof(keys) / sizeof(keys[0]); k++) {
            json_t *v = json_object_get(payload, keys[k]);
            json_object_set_new(body, keys[k],
                                json_string(json_is_string(v)
                                            ? json_string_value(v) : ""));
        }
        json_t *jts = json_object_get(payload, "ts");
        json_object_set_new(body, "ts",
                            json_real(json_is_number(jts)
                                      ? json_number_value(jts) : 0.0));
        _ic_set_seq(body, payload);
        net_msg_pack_json(&out->info.net_msg, body);
        json_decref(body);
        return 0;
    }
    return 1;
}

/* Drive one file app verb on @p impl with {peer, id[, path]}. */
static void _fx_app_verb(ic_impl_t *impl, const char *verb, const char *peer_uuid,
                         const char *id, const char *path)
{
    json_t *jp = json_pack("{s:s, s:s}", "peer", peer_uuid, "id", id != NULL ? id : "");
    if (path != NULL)
        json_object_set_new(jp, "path", json_string(path));
    generic_msg_t m = {0};
    m.type = NET_MESSAGE;
    strncpy(m.info.net_msg.process, "identity", PROC_NAME_LEN);
    m.info.net_msg.function = (char *)verb;
    net_msg_pack_json(&m.info.net_msg, jp);
    json_decref(jp);
    run_message_handlers(impl->proc, NULL, NET_MESSAGE, &m);
    net_msg_free_obj(&m.info.net_msg);
}

/* File sharing: the app verbs as triggers ({peer: <pid>, id[, name, content]}),
 * and a sweep. Returns 0 if @p fn was one, 1 if not, -1 on a bad step. */
static int _fx_dispatch(sce_run_ctx_t *ctx, ic_impl_t *impl, const char *fn,
                        generic_msg_t *inbound)
{
    if (strncmp(fn, "trigger_file_", 13) != 0)
        return 1;
    _sx(impl);   /* so impl_free runs and restores the root */
    if (_fx_root() == NULL) {
        snprintf(ctx->err, sizeof(ctx->err), "%s: no writable temp root", fn);
        return -1;
    }
    if (strcmp(fn, "trigger_file_sweep") == 0) {
        file_xfer_periodic(impl->proc);
        return 0;
    }
    json_t *jp = NULL;
    if (net_msg_unpack_json(&inbound->info.net_msg, &jp) != 0 || jp == NULL) {
        snprintf(ctx->err, sizeof(ctx->err), "%s: no payload", fn);
        return -1;
    }
    const char *peer_pid = json_string_value(json_object_get(jp, "peer"));
    const char *id = json_string_value(json_object_get(jp, "id"));
    sce_participant_t *tp = peer_pid != NULL ? sce_find_participant(ctx, peer_pid) : NULL;
    if (tp == NULL || id == NULL) {
        snprintf(ctx->err, sizeof(ctx->err), "%s: needs peer and id", fn);
        json_decref(jp);
        return -1;
    }
    ic_impl_t *peer = (ic_impl_t *)tp->impl;
    _sf_admit(impl->proc, peer->pub);
    char peer_uuid[UUID_STR_LEN + 1];
    uuid_unparse_lower(peer->pub->uuid, peer_uuid);
    if (strcmp(fn, "trigger_file_offer") == 0) {
        const char *name = json_string_value(json_object_get(jp, "name"));
        char *content = _fx_content(jp);
        char path[256];
        snprintf(path, sizeof(path), "%s/src/%s", g_fx_root,
                 name != NULL ? name : "file");
        FILE *f = fopen(path, "wb");
        if (f != NULL) {
            if (content != NULL)
                fwrite(content, 1, strlen(content), f);
            fclose(f);
        }
        free(content);
        _fx_app_verb(impl, AT_APP_FILE_OFFER, peer_uuid, id, path);
    } else {
        const char *verb = strcmp(fn, "trigger_file_accept") == 0 ? AT_APP_FILE_ACCEPT
                         : strcmp(fn, "trigger_file_decline") == 0 ? AT_APP_FILE_DECLINE
                         : strcmp(fn, "trigger_file_cancel") == 0 ? AT_APP_FILE_CANCEL
                         : NULL;
        if (verb == NULL) {
            snprintf(ctx->err, sizeof(ctx->err), "unknown file trigger %s", fn);
            json_decref(jp);
            return -1;
        }
        _fx_app_verb(impl, verb, peer_uuid, id, NULL);
    }
    json_decref(jp);
    return 0;
}

static int _social_dispatch(sce_run_ctx_t *ctx, sce_participant_t *target,
                            generic_msg_t *inbound)
{
    ic_impl_t *impl = (ic_impl_t *)target->impl;
    (void)impl;
    if (inbound->type == NET_MESSAGE && _fx_verb(inbound->info.net_msg.function)) {
        /* A file frame from a peer: admit the sender (one-hop scenarios, the
         * C state is a singleton), make sure the root is writable, then let
         * the real handler run. */
        _sx(impl);
        _fx_root();
        ic_impl_t *snd = _ic_impl_for_uuid(ctx, inbound->info.net_msg.from_whom.uuid);
        if (snd != NULL && snd->pub != NULL)
            _sf_admit(impl->proc, snd->pub);
        return 1;
    }
    if (inbound->type == NET_MESSAGE && inbound->info.net_msg.function != NULL) {
        int rc = _fx_dispatch(ctx, impl, inbound->info.net_msg.function, inbound);
        if (rc != 1)
            return rc;
    }
    if (inbound->type == NET_MESSAGE && _sf_verb(inbound->info.net_msg.function)) {
        /* Admit the sender the way the Python adapter's rosters already do
         * (see _sf_admit), then let the real handler run. */
        ic_impl_t *snd = _ic_impl_for_uuid(ctx, inbound->info.net_msg.from_whom.uuid);
        sce_participant_t *sp = snd != NULL ? sce_find_participant(ctx, snd->id) : NULL;
        if (snd != NULL && snd->pub != NULL
            && !(sp != NULL && strcmp(sp->role, "new_node") == 0))
            _sf_admit(impl->proc, snd->pub);
        return 1;
    }
    /* Communities (Phase 4). Following and labelling are app verbs, so each
     * trigger drives the real AT_APP_* handler with the step's payload; the
     * emitted policy ad or label is attributed to this participant. Mirrors
     * the Python adapter's _TRIGGER_FOLLOW_COMMUNITY & co. */
    if (inbound->type == NET_MESSAGE && inbound->info.net_msg.function != NULL) {
        const char *fn = inbound->info.net_msg.function;
        const char *verb = strcmp(fn, "trigger_follow_community") == 0
                               ? AT_APP_FOLLOW_COMMUNITY
                         : strcmp(fn, "trigger_unfollow_community") == 0
                               ? AT_APP_UNFOLLOW_COMMUNITY
                         : strcmp(fn, "trigger_publish_post_label") == 0
                               ? AT_APP_PUBLISH_POST_LABEL
                               : NULL;
        if (verb != NULL) {
            json_t *jp = NULL;
            if (net_msg_unpack_json(&inbound->info.net_msg, &jp) != 0 || jp == NULL) {
                snprintf(ctx->err, sizeof(ctx->err), "%s: no payload", fn);
                return -1;
            }
            generic_msg_t m = {0};
            m.type = NET_MESSAGE;
            strncpy(m.info.net_msg.process, "identity", PROC_NAME_LEN);
            m.info.net_msg.function = (char *)verb;
            net_msg_pack_json(&m.info.net_msg, jp);
            json_decref(jp);
            run_message_handlers(impl->proc, NULL, NET_MESSAGE, &m);
            if (m.info.net_msg.obj != NULL) smrt_deref(m.info.net_msg.obj);
            return 0;
        }
        if (strcmp(fn, "trigger_advertise_communities") == 0) {
            (void)identity_advertise_communities(impl->proc);
            return 0;
        }
    }
    if (inbound->type == NET_MESSAGE
        && inbound->info.net_msg.function != NULL
        && strcmp(inbound->info.net_msg.function, "trigger_post_digest") == 0) {
        /* Pseudo-function: `impl` sends its digest (store-and-forward), as the
         * periodic resync would. Mirrors the Python adapter's
         * _TRIGGER_POST_DIGEST. */
        (void)identity_send_post_digest(impl->proc);
        return 0;
    }
    if (inbound->type == NET_MESSAGE
        && inbound->info.net_msg.function != NULL
        && strcmp(inbound->info.net_msg.function,
                  "trigger_proximity_probe") == 0) {
        /* Pseudo-function: one private-proximity probe, end to end. `impl` is
         * the probe TARGET; from_whom is the INITIATOR (the step's `from`). The
         * probe/reply payloads are handler-COMPUTED keyed tags, so the whole
         * round trip runs through the real handlers. Mirrors the Python
         * adapter's _TRIGGER_PROXIMITY_PROBE. */
        ic_impl_t *initiator =
            _ic_impl_for_uuid(ctx, inbound->info.net_msg.from_whom.uuid);
        if (initiator == NULL) {
            snprintf(ctx->err, sizeof(ctx->err),
                     "proximity probe: unknown initiator");
            return -1;
        }
        return _ic_run_proximity_probe(ctx, initiator, impl);
    }
    if (inbound->type == NET_MESSAGE
        && inbound->info.net_msg.function != NULL
        && strcmp(inbound->info.net_msg.function,
                  "trigger_advertise_business") == 0) {
        /* Pseudo-function: `impl` is the BUSINESS; the step's payload names its
         * polity and page ({"polity","bundle","seq"}). Advertising is an app
         * verb, not a wire message, so drive the real AT_APP_ADVERTISE_BUSINESS
         * handler and let the emitted peer_business_ad travel. The engine has
         * already set current_dispatcher to this participant, so the emission is
         * attributed to the business. Mirrors the Python adapter's
         * _TRIGGER_ADVERTISE_BUSINESS. */
        json_t *jp = NULL;
        if (net_msg_unpack_json(&inbound->info.net_msg, &jp) != 0 || jp == NULL) {
            snprintf(ctx->err, sizeof(ctx->err),
                     "trigger_advertise_business: no payload");
            return -1;
        }
        generic_msg_t m = {0};
        m.type = NET_MESSAGE;
        strncpy(m.info.net_msg.process, "identity", PROC_NAME_LEN);
        m.info.net_msg.function = (char *)AT_APP_ADVERTISE_BUSINESS;
        net_msg_pack_json(&m.info.net_msg, jp);
        json_decref(jp);
        run_message_handlers(impl->proc, NULL, NET_MESSAGE, &m);
        if (m.info.net_msg.obj != NULL) smrt_deref(m.info.net_msg.obj);
        return 0;
    }
    if (inbound->type == NET_MESSAGE
        && inbound->info.net_msg.function != NULL
        && strcmp(inbound->info.net_msg.function, "trigger_report") == 0) {
        /* Pseudo-function: `impl` is the REPORTER; the payload names the
         * reported participant ({"peer": <pid>}). Mirrors the Python adapter's
         * _TRIGGER_REPORT — see _ic_run_report. */
        json_t *jp = NULL;
        const char *peer_pid = NULL;
        sce_participant_t *tp = NULL;
        if (net_msg_unpack_json(&inbound->info.net_msg, &jp) == 0 && jp != NULL) {
            peer_pid = json_string_value(json_object_get(jp, "peer"));
            tp = peer_pid != NULL ? sce_find_participant(ctx, peer_pid) : NULL;
        }
        if (tp == NULL) {
            snprintf(ctx->err, sizeof(ctx->err), "trigger_report: unknown peer %s",
                     peer_pid != NULL ? peer_pid : "(none)");
            if (jp != NULL) json_decref(jp);
            return -1;
        }
        json_decref(jp);
        return _ic_run_report(ctx, impl, (ic_impl_t *)tp->impl);
    }
    if (inbound->type == NET_MESSAGE
        && inbound->info.net_msg.function != NULL
        && strcmp(inbound->info.net_msg.function, "trigger_block") == 0) {
        /* Pseudo-function: locally block the peer the step names ({"peer":
         * <pid>}). Block is an app verb, not a wire message, so there is nothing
         * to dispatch — call the identity_block_peer seam directly;
         * identity_get_peer_tier then clamps this peer to 0. Purely local — no
         * wire traffic, no reputation transaction. Mirrors the Python adapter's
         * _TRIGGER_BLOCK. */
        json_t *jp = NULL;
        if (net_msg_unpack_json(&inbound->info.net_msg, &jp) == 0
            && jp != NULL) {
            const char *peer_pid =
                json_string_value(json_object_get(jp, "peer"));
            sce_participant_t *tp = peer_pid != NULL
                ? sce_find_participant(ctx, peer_pid) : NULL;
            if (tp != NULL) {
                char uuid_str[UUID_STRING_LEN + 1];
                uuid_unparse_lower(((ic_impl_t *)tp->impl)->pub->uuid,
                                   uuid_str);
                identity_block_peer(uuid_str);
            }
            json_decref(jp);
        }
        return 0;
    }
    if (inbound->type == NET_MESSAGE
        && inbound->info.net_msg.function != NULL
        && strcmp(inbound->info.net_msg.function,
                  "trigger_social_reload") == 0) {
        /* Pseudo-function: save the block set and load it back — the round trip
         * a restart performs, without needing one. A conformance step cannot
         * restart a process, and asserting on the in-memory map alone would
         * pass with no file written at all. Mirrors the Python adapter's
         * _TRIGGER_SOCIAL_RELOAD. */
        /* A WRITABLE dir, explicitly. This harness's default config root is
         * /etc/at and nothing may be written there (the same reason the
         * reputation snapshot warns on every run), so a reload that could not
         * write would be a no-op that PASSED — proving nothing while looking
         * green. Same shape as the Python adapter's tempfile.mkdtemp. */
        char reload_dir[] = "/tmp/at-conf-social-XXXXXX";
        if (mkdtemp(reload_dir) != NULL)
            identity_reload_social_blocks(reload_dir);
        return 0;
    }
    if (inbound->type == NET_MESSAGE
        && inbound->info.net_msg.function != NULL
        && strcmp(inbound->info.net_msg.function, "trigger_unblock") == 0) {
        /* Pseudo-function: lift the block on the peer the step names ({"peer":
         * <pid>}). Unblock is an app verb, not a wire message, so there is
         * nothing to dispatch — call the identity_unblock_peer seam directly.
         * Mirrors the Python adapter's _TRIGGER_UNBLOCK. */
        json_t *jp = NULL;
        if (net_msg_unpack_json(&inbound->info.net_msg, &jp) == 0
            && jp != NULL) {
            const char *peer_pid =
                json_string_value(json_object_get(jp, "peer"));
            sce_participant_t *tp = peer_pid != NULL
                ? sce_find_participant(ctx, peer_pid) : NULL;
            if (tp != NULL) {
                char uuid_str[UUID_STRING_LEN + 1];
                uuid_unparse_lower(((ic_impl_t *)tp->impl)->pub->uuid,
                                   uuid_str);
                identity_unblock_peer(uuid_str);
            }
            json_decref(jp);
        }
        return 0;
    }
    return 1;
}

static int _social_check_key(sce_run_ctx_t *ctx, const char *pid,
                             ic_impl_t *impl, process_t *proc, const char *key,
                             json_t *val)
{
    (void)impl; (void)proc;
    if (0) {
    }
            else if (strcmp(key, "peer_position") == 0) {
                /* {peer_id: geohash} (Increment 2) — the coarse position this
                 * participant recorded for another, via
                 * identity_get_peer_position. '' means none recorded (the peer
                 * opted out, or the response was dropped/refused) — the ordinary
                 * default. Mirrors the Python adapter's peer_position, keyed by
                 * the same lowercased uuid. */
                const char *pp_pid;
                json_t *pp_want;
                json_object_foreach(val, pp_pid, pp_want) {
                    sce_participant_t *other = sce_find_participant(ctx, pp_pid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: peer_position names unknown participant %s",
                                 pid, pp_pid);
                        return -1;
                    }
                    const public_identity_t *want_id =
                        ((ic_impl_t *)other->impl)->pub;
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(want_id->uuid, want_uuid);
                    char got[64];
                    identity_get_peer_position(want_uuid, got, sizeof(got));
                    const char *want = json_string_value(pp_want);
                    if (want == NULL) want = "";
                    if (strcmp(got, want) != 0) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: peer_position[%s]=%s, expected %s",
                                 pid, pp_pid, got, want);
                        return -1;
                    }
                }
            } else if (strcmp(key, "peer_profile") == 0) {
                /* {peer_id: {profile fields}} (Increment 3) — the profile this
                 * participant recorded for another (via identity_get_peer_profile,
                 * a compact JSON object), compared structurally. An empty object
                 * {} means none recorded (opted out, or dropped on bad signature /
                 * over-bound field / replay). Mirrors the Python adapter's
                 * peer_profile check. */
                const char *fp_pid;
                json_t *fp_want;
                json_object_foreach(val, fp_pid, fp_want) {
                    sce_participant_t *other = sce_find_participant(ctx, fp_pid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: peer_profile names unknown participant %s",
                                 pid, fp_pid);
                        return -1;
                    }
                    const public_identity_t *want_id =
                        ((ic_impl_t *)other->impl)->pub;
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(want_id->uuid, want_uuid);
                    char got[AT_PROFILE_JSON_MAX + 1];
                    identity_get_peer_profile(want_uuid, got, sizeof(got));
                    json_t *got_obj = (got[0] != '\0')
                        ? json_loads(got, 0, NULL) : json_object();
                    if (got_obj == NULL) got_obj = json_object();
                    bool eq = json_is_object(fp_want)
                        ? json_equal(got_obj, fp_want)
                        : (json_object_size(got_obj) == 0);
                    json_decref(got_obj);
                    if (!eq) {
                        char *want_str = json_dumps(fp_want, JSON_COMPACT);
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: peer_profile[%s]=%.120s, expected %.120s",
                                 pid, fp_pid, got, want_str ? want_str : "?");
                        free(want_str);
                        return -1;
                    }
                }
            } else if (strcmp(key, "peer_proximity") == 0) {
                /* {peer_id: <int band>} (Phase 2) — the coarse distance BAND
                 * this participant last learned toward another CONNECTED
                 * peer, via identity_get_peer_proximity: unknown=0, near=1,
                 * mid=2, far=3. 0 is the ordinary default (never probed,
                 * opted out, or the probe refused). No coordinates cross the
                 * wire; the corpus pins the band the keyed-tag intersection
                 * yields. Mirrors the Python adapter's peer_proximity check,
                 * which is what id_proc_priv.h's comment on the getter has
                 * always promised. */
                const char *px_pid;
                json_t *px_want;
                json_object_foreach(val, px_pid, px_want) {
                    sce_participant_t *other = sce_find_participant(ctx, px_pid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: peer_proximity names unknown participant %s",
                                 pid, px_pid);
                        return -1;
                    }
                    const public_identity_t *want_id =
                        ((ic_impl_t *)other->impl)->pub;
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(want_id->uuid, want_uuid);
                    int got_band = identity_get_peer_proximity(want_uuid);
                    int want_band = (int)json_integer_value(px_want);
                    if (got_band != want_band) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: peer_proximity[%s]=%d, expected %d",
                                 pid, px_pid, got_band, want_band);
                        return -1;
                    }
                }
            } else if (strcmp(key, "connection_state") == 0) {
                /* {peer_id: <int>} (Increment 5) — the connection edge state
                 * this participant holds toward another, via
                 * identity_get_connection_state: none=0, pending_out=1,
                 * pending_in=2, connected=3, declined=4. Mirrors the Python
                 * adapter's connection_state check. */
                const char *cs_pid;
                json_t *cs_want;
                json_object_foreach(val, cs_pid, cs_want) {
                    sce_participant_t *other = sce_find_participant(ctx, cs_pid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: connection_state names unknown participant %s",
                                 pid, cs_pid);
                        return -1;
                    }
                    const public_identity_t *want_id =
                        ((ic_impl_t *)other->impl)->pub;
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(want_id->uuid, want_uuid);
                    int got = identity_get_connection_state(want_uuid);
                    int want = (int)json_integer_value(cs_want);
                    if (got != want) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: connection_state[%s]=%d, expected %d",
                                 pid, cs_pid, got, want);
                        return -1;
                    }
                }
            } else if (strcmp(key, "peer_proximity") == 0) {
                /* {peer_id: <int band>} (Phase 2) — the coarse distance BAND
                 * this participant last learned toward another CONNECTED peer,
                 * via identity_get_peer_proximity: unknown=0, near=1, mid=2,
                 * far=3. 0 is the ordinary default (never probed, opted out, or
                 * refused). Mirrors the Python adapter's peer_proximity check. */
                const char *px_pid;
                json_t *px_want;
                json_object_foreach(val, px_pid, px_want) {
                    sce_participant_t *other = sce_find_participant(ctx, px_pid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: peer_proximity names unknown participant %s",
                                 pid, px_pid);
                        return -1;
                    }
                    const public_identity_t *want_id =
                        ((ic_impl_t *)other->impl)->pub;
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(want_id->uuid, want_uuid);
                    int got = identity_get_peer_proximity(want_uuid);
                    int want = (int)json_integer_value(px_want);
                    if (got != want) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: peer_proximity[%s]=%d, expected %d",
                                 pid, px_pid, got, want);
                        return -1;
                    }
                }
            } else if (strcmp(key, "business_page") == 0) {
                /* {polity_did: {seq, endorsers}} (Phase 3 P3.2) — what this
                 * participant LEARNED about a business, via
                 * identity_get_business_page. `seq` is the page version it
                 * holds; `endorsers` the number of CUSTOMERS that have vouched
                 * for it (a business's own ad is not an endorsement, so a page
                 * nobody patronizes has 0). {} means no page held at all —
                 * which, for a node whose ad never verified, is the correct
                 * outcome. Mirrors the Python adapter's business_page check. */
                const char *bp_did;
                json_t *bp_want;
                json_object_foreach(val, bp_did, bp_want) {
                    char bundle[AT_BUSINESS_BUNDLE_MAX + 1] = {0};
                    int64_t got_seq = 0;
                    int got_endorsers = 0;
                    bool held = identity_get_business_page(
                        bp_did, bundle, sizeof(bundle), &got_seq, &got_endorsers);
                    if (!json_is_object(bp_want) || json_object_size(bp_want) == 0) {
                        if (held) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: business_page[%s] present at seq %lld, "
                                     "expected none", pid, bp_did,
                                     (long long)got_seq);
                            return -1;
                        }
                        continue;
                    }
                    if (!held) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: business_page[%s] missing", pid, bp_did);
                        return -1;
                    }
                    json_t *w_seq = json_object_get(bp_want, "seq");
                    if (json_is_integer(w_seq)
                        && got_seq != (int64_t)json_integer_value(w_seq)) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: business_page[%s].seq=%lld, expected %lld",
                                 pid, bp_did, (long long)got_seq,
                                 (long long)json_integer_value(w_seq));
                        return -1;
                    }
                    json_t *w_end = json_object_get(bp_want, "endorsers");
                    if (json_is_integer(w_end)
                        && got_endorsers != (int)json_integer_value(w_end)) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: business_page[%s].endorsers=%d, expected %d",
                                 pid, bp_did, got_endorsers,
                                 (int)json_integer_value(w_end));
                        return -1;
                    }
                    json_t *w_bun = json_object_get(bp_want, "bundle");
                    if (json_is_string(w_bun)
                        && strcmp(bundle, json_string_value(w_bun)) != 0) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: business_page[%s].bundle mismatch",
                                 pid, bp_did);
                        return -1;
                    }
                }
            } else if (strcmp(key, "customer_satisfaction") == 0) {
                /* {polity_did: <int>} (Phase 3 P3.2) — this participant's OWN
                 * customer edge, via identity_get_customer_satisfaction: 0..4,
                 * or -1 when it holds none and therefore carries nothing for
                 * that business. Mirrors the Python adapter's check. */
                const char *cs_did;
                json_t *cs_want;
                json_object_foreach(val, cs_did, cs_want) {
                    int got = identity_get_customer_satisfaction(cs_did);
                    int want = (int)json_integer_value(cs_want);
                    if (got != want) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: customer_satisfaction[%s]=%d, expected %d",
                                 pid, cs_did, got, want);
                        return -1;
                    }
                }
            } else if (strcmp(key, "business_ads_emitted") == 0) {
                /* peer_business_ad emissions attributed to this participant
                 * (Phase 3 P3.2). THE GATE ASSERTION: a CUSTOMER that receives
                 * an ad re-advertises (>=1), a non-customer stays SILENT (0).
                 * This is what makes a page travel only through people who
                 * actually patronize the business. Mirrors the Python emit_tally
                 * check. */
                int want = (int)json_integer_value(val);
                int got = 0;
                for (size_t i = 0; i < ctx->captured_count; i++) {
                    if (strcmp(ctx->captured[i].from, pid) == 0
                        && strcmp(ctx->captured[i].function,
                                  "peer_business_ad") == 0)
                        got++;
                }
                if (got != want) {
                    snprintf(ctx->err, sizeof(ctx->err),
                             "%s: business_ads_emitted=%d, expected %d",
                             pid, got, want);
                    return -1;
                }
            } else if (strcmp(key, "business_post_last") == 0) {
                /* {polity_did: {seq, hops, present}} (Phase 3 P3.4) — the most
                 * recent business post this participant ACCEPTED for that
                 * polity, via identity_get_last_business_post. Filled only
                 * AFTER the signature check, THE PAGE GATE and dedup, so an
                 * expected `{}` is the assertion that one of those three
                 * refused it. Keyed by the POLITY, never by the sender: the
                 * post is the business's and the carrier is incidental.
                 * Mirrors the Python adapter's business_post_last. */
                const char *bpl_did;
                json_t *bpl_want;
                json_object_foreach(val, bpl_did, bpl_want) {
                    char post_id[AT_BUSINESS_POST_ID_HEX_LEN + 1] = {0};
                    char bundle[AT_BUSINESS_POST_BUNDLE_MAX + 1] = {0};
                    int64_t got_seq = 0;
                    int got_hops = 0;
                    bool held = identity_get_last_business_post(
                        bpl_did, post_id, sizeof(post_id), bundle,
                        sizeof(bundle), &got_seq, &got_hops);
                    if (!json_is_object(bpl_want)
                        || json_object_size(bpl_want) == 0) {
                        if (held) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: business_post_last[%s] present at "
                                     "seq %lld, expected none", pid, bpl_did,
                                     (long long)got_seq);
                            return -1;
                        }
                        continue;
                    }
                    if (!held) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: business_post_last[%s] missing", pid,
                                 bpl_did);
                        return -1;
                    }
                    json_t *w_seq = json_object_get(bpl_want, "seq");
                    if (json_is_integer(w_seq)
                        && got_seq != (int64_t)json_integer_value(w_seq)) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: business_post_last[%s].seq=%lld, "
                                 "expected %lld", pid, bpl_did,
                                 (long long)got_seq,
                                 (long long)json_integer_value(w_seq));
                        return -1;
                    }
                    json_t *w_hops = json_object_get(bpl_want, "hops");
                    if (json_is_integer(w_hops)
                        && got_hops != (int)json_integer_value(w_hops)) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: business_post_last[%s].hops=%d, "
                                 "expected %d", pid, bpl_did, got_hops,
                                 (int)json_integer_value(w_hops));
                        return -1;
                    }
                    json_t *w_bundle = json_object_get(bpl_want, "bundle");
                    if (json_is_string(w_bundle)
                        && strcmp(bundle, json_string_value(w_bundle)) != 0) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: business_post_last[%s].bundle mismatch",
                                 pid, bpl_did);
                        return -1;
                    }
                }
            } else if (strcmp(key, "business_posts_emitted") == 0) {
                /* peer_business_post emissions attributed to this participant
                 * (Phase 3 P3.4). THE RELAY ASSERTION, and the twin of
                 * business_ads_emitted: a node that HOLDS THE PAGE relays once
                 * (1), a node that does not stays silent (0) — which is the
                 * audience gate made observable rather than argued for. */
                int want = (int)json_integer_value(val);
                int got = 0;
                for (size_t i = 0; i < ctx->captured_count; i++) {
                    if (strcmp(ctx->captured[i].from, pid) == 0
                        && strcmp(ctx->captured[i].function,
                                  "peer_business_post") == 0)
                        got++;
                }
                if (got != want) {
                    snprintf(ctx->err, sizeof(ctx->err),
                             "%s: business_posts_emitted=%d, expected %d",
                             pid, got, want);
                    return -1;
                }
            } else if (strcmp(key, "post_digests_emitted") == 0
                       || strcmp(key, "post_wants_emitted") == 0
                       || strcmp(key, "post_backfills_emitted") == 0
                       || strcmp(key, "posts_emitted") == 0) {
                /* Store-and-forward emissions attributed to this participant
                 * (Agora Phase 4 DDIL): digests sent, wants sent, backfills
                 * served, and plain feed posts sent (a relay; a backfill must
                 * never cause one). Mirrors the Python emit tallies. */
                const char *fn =
                    strcmp(key, "post_digests_emitted") == 0 ? "peer_post_digest"
                  : strcmp(key, "post_wants_emitted") == 0 ? "peer_post_want"
                  : strcmp(key, "post_backfills_emitted") == 0 ? "peer_post_backfill"
                  : "peer_post";
                int want = (int)json_integer_value(val);
                int got = 0;
                for (size_t i = 0; i < ctx->captured_count; i++)
                    if (strcmp(ctx->captured[i].from, pid) == 0
                        && strcmp(ctx->captured[i].function, fn) == 0)
                        got++;
                if (got != want) {
                    snprintf(ctx->err, sizeof(ctx->err), "%s: %s=%d, expected %d",
                             pid, key, got, want);
                    return -1;
                }
            } else if (strcmp(key, "communities_followed") == 0
                       || strcmp(key, "community_policy_last") == 0) {
                /* {did: {seq?} | {}} (Phase 4): what this node FOLLOWS, or
                 * what it last HEARD of a community's policy. {} asserts none. */
                bool followed = strcmp(key, "communities_followed") == 0;
                const char *did;
                json_t *want;
                json_object_foreach(val, did, want) {
                    int64_t got_seq = 0;
                    static char got_bundle[AT_COMMUNITY_POLICY_BUNDLE_MAX + 1];
                    bool have = followed
                        ? identity_get_followed_community(did, &got_seq, got_bundle,
                                                          sizeof(got_bundle))
                        : identity_get_last_community_policy(did, &got_seq, got_bundle,
                                                             sizeof(got_bundle));
                    if (json_object_size(want) == 0) {
                        if (have) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: %s[%s] present, expected none", pid, key, did);
                            return -1;
                        }
                        continue;
                    }
                    if (!have) {
                        snprintf(ctx->err, sizeof(ctx->err), "%s: %s[%s] missing",
                                 pid, key, did);
                        return -1;
                    }
                    json_t *js = json_object_get(want, "seq");
                    if (json_is_integer(js) && got_seq != (int64_t)json_integer_value(js)) {
                        snprintf(ctx->err, sizeof(ctx->err), "%s: %s[%s].seq=%lld, "
                                 "expected %lld", pid, key, did, (long long)got_seq,
                                 (long long)json_integer_value(js));
                        return -1;
                    }
                    json_t *jb = json_object_get(want, "bundle");
                    if (json_is_string(jb) && strcmp(got_bundle, json_string_value(jb)) != 0) {
                        snprintf(ctx->err, sizeof(ctx->err), "%s: %s[%s].bundle differs",
                                 pid, key, did);
                        return -1;
                    }
                }
            } else if (strcmp(key, "post_label_last") == 0) {
                /* {post_id: {community?, seq?, hops?} | {}} (Phase 4). */
                const char *post_id;
                json_t *want;
                json_object_foreach(val, post_id, want) {
                    char got_comm[AT_COMMUNITY_DID_MAX + 1];
                    int64_t got_seq = 0;
                    int got_hops = 0;
                    bool have = identity_get_last_post_label(post_id, got_comm,
                                                             sizeof(got_comm), &got_seq,
                                                             &got_hops);
                    if (json_object_size(want) == 0) {
                        if (have) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: post_label_last[%.16s] present, expected none",
                                     pid, post_id);
                            return -1;
                        }
                        continue;
                    }
                    if (!have) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: post_label_last[%.16s] missing", pid, post_id);
                        return -1;
                    }
                    json_t *jc = json_object_get(want, "community");
                    json_t *js = json_object_get(want, "seq");
                    json_t *jh = json_object_get(want, "hops");
                    if ((json_is_string(jc) && strcmp(got_comm, json_string_value(jc)) != 0)
                        || (json_is_integer(js) && got_seq != (int64_t)json_integer_value(js))
                        || (json_is_integer(jh) && got_hops != (int)json_integer_value(jh))) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: post_label_last[%.16s] = {%s, seq %lld, hops %d} "
                                 "differs from expected", pid, post_id, got_comm,
                                 (long long)got_seq, got_hops);
                        return -1;
                    }
                }
            } else if (strcmp(key, "community_policies_emitted") == 0
                       || strcmp(key, "post_labels_emitted") == 0) {
                const char *fn = strcmp(key, "community_policies_emitted") == 0
                                     ? "peer_community_policy" : "peer_post_label";
                int want = (int)json_integer_value(val);
                int got = 0;
                for (size_t i = 0; i < ctx->captured_count; i++)
                    if (strcmp(ctx->captured[i].from, pid) == 0
                        && strcmp(ctx->captured[i].function, fn) == 0)
                        got++;
                if (got != want) {
                    snprintf(ctx->err, sizeof(ctx->err), "%s: %s=%d, expected %d",
                             pid, key, got, want);
                    return -1;
                }
            } else if (strcmp(key, "dm_last") == 0) {
                /* {peer_id: {seq, text} | {absent: true}} (Increment 6) — the
                 * most-recent DM this participant received from another, via
                 * identity_get_last_dm. `absent: true` asserts that NO DM is
                 * held, which a DM dropped at the block gate produces (Phase 4
                 * P4.1); an unexpectedly absent DM still fails. Mirrors the
                 * Python adapter's dm_last, keyed by the same lowercased uuid. */
                const char *dm_pid;
                json_t *dm_want;
                json_object_foreach(val, dm_pid, dm_want) {
                    sce_participant_t *other = sce_find_participant(ctx, dm_pid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: dm_last names unknown participant %s",
                                 pid, dm_pid);
                        return -1;
                    }
                    const public_identity_t *want_id =
                        ((ic_impl_t *)other->impl)->pub;
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(want_id->uuid, want_uuid);
                    char got_text[AT_DM_TEXT_MAX + 1];
                    int64_t got_seq = 0;
                    bool have = identity_get_last_dm(want_uuid, got_text,
                                                     sizeof(got_text), &got_seq);
                    json_t *j_absent = json_object_get(dm_want, "absent");
                    if (json_is_true(j_absent)) {
                        if (have) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: dm_last[%s] present (text=%.60s), "
                                     "expected ABSENT", pid, dm_pid, got_text);
                            return -1;
                        }
                        continue;
                    }
                    if (!have) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: dm_last[%s] absent, expected a DM", pid,
                                 dm_pid);
                        return -1;
                    }
                    json_t *jt = json_object_get(dm_want, "text");
                    if (json_is_string(jt)
                        && strcmp(got_text, json_string_value(jt)) != 0) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: dm_last[%s].text=%.80s, expected %.80s",
                                 pid, dm_pid, got_text, json_string_value(jt));
                        return -1;
                    }
                    json_t *js = json_object_get(dm_want, "seq");
                    if (json_is_integer(js)
                        && got_seq != (int64_t)json_integer_value(js)) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: dm_last[%s].seq=%lld, expected %lld", pid,
                                 dm_pid, (long long)got_seq,
                                 (long long)json_integer_value(js));
                        return -1;
                    }
                }
            } else if (strcmp(key, "post_last") == 0) {
                /* {author_id: {seq, tier, body} | {absent: true}} (Increment 7) —
                 * the most-recent feed post this participant accepted from
                 * another AUTHOR, via identity_get_last_post. A post that never
                 * arrived, was dropped by the signature/tier-gate, or was deduped
                 * away is ABSENT; `absent: true` asserts that. Mirrors the Python
                 * adapter's post_last, keyed by the same lowercased author uuid. */
                const char *post_pid;
                json_t *post_want;
                json_object_foreach(val, post_pid, post_want) {
                    sce_participant_t *other = sce_find_participant(ctx, post_pid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: post_last names unknown participant %s",
                                 pid, post_pid);
                        return -1;
                    }
                    const public_identity_t *want_id =
                        ((ic_impl_t *)other->impl)->pub;
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(want_id->uuid, want_uuid);
                    char got_post_id[AT_POST_ID_HEX_LEN + 1];
                    char got_body[AT_POST_BODY_MAX + 1];
                    int64_t got_seq = 0;
                    int got_tier = 0;
                    bool have = identity_get_last_post(want_uuid, got_post_id,
                                                       sizeof(got_post_id),
                                                       got_body, sizeof(got_body),
                                                       &got_seq, &got_tier);
                    bool want_absent =
                        json_is_true(json_object_get(post_want, "absent"));
                    if (want_absent) {
                        if (have) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: post_last[%s] present (body=%.40s), "
                                     "expected ABSENT", pid, post_pid, got_body);
                            return -1;
                        }
                        continue;
                    }
                    if (!have) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: post_last[%s] absent, expected a post", pid,
                                 post_pid);
                        return -1;
                    }
                    json_t *jb = json_object_get(post_want, "body");
                    if (json_is_string(jb)
                        && strcmp(got_body, json_string_value(jb)) != 0) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: post_last[%s].body=%.80s, expected %.80s",
                                 pid, post_pid, got_body, json_string_value(jb));
                        return -1;
                    }
                    json_t *js = json_object_get(post_want, "seq");
                    if (json_is_integer(js)
                        && got_seq != (int64_t)json_integer_value(js)) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: post_last[%s].seq=%lld, expected %lld", pid,
                                 post_pid, (long long)got_seq,
                                 (long long)json_integer_value(js));
                        return -1;
                    }
                    json_t *jtr = json_object_get(post_want, "tier");
                    if (json_is_integer(jtr)
                        && got_tier != (int)json_integer_value(jtr)) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: post_last[%s].tier=%d, expected %lld", pid,
                                 post_pid, got_tier,
                                 (long long)json_integer_value(jtr));
                        return -1;
                    }
                    /* The scope (Phase 4): `community` a string, `labels` a
                     * list, compared joined. */
                    char got_comm[AT_POST_COMMUNITY_MAX + 1];
                    char got_labels[AT_POST_LABELS_LEN + 1];
                    identity_get_last_post_scope(want_uuid, got_comm, sizeof(got_comm),
                                                 got_labels, sizeof(got_labels));
                    json_t *jc = json_object_get(post_want, "community");
                    if (json_is_string(jc) && strcmp(got_comm, json_string_value(jc)) != 0) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: post_last[%s].community=%s, expected %s", pid,
                                 post_pid, got_comm, json_string_value(jc));
                        return -1;
                    }
                    json_t *jl = json_object_get(post_want, "labels");
                    if (json_is_array(jl)) {
                        char want_labels[AT_POST_LABELS_LEN + 1] = {0};
                        size_t off = 0, li;
                        json_t *lv;
                        json_array_foreach(jl, li, lv) {
                            int n = snprintf(want_labels + off, sizeof(want_labels) - off,
                                             "%s%s", li ? "," : "",
                                             json_string_value(lv) ? json_string_value(lv) : "");
                            if (n < 0 || (size_t)n >= sizeof(want_labels) - off) break;
                            off += (size_t)n;
                        }
                        if (strcmp(got_labels, want_labels) != 0) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: post_last[%s].labels=%s, expected %s", pid,
                                     post_pid, got_labels, want_labels);
                            return -1;
                        }
                    }
                }
            } else if (strcmp(key, "cosign_request_last") == 0) {
                /* {requester_id: {record, op, cid, bytes, seq} | {absent: true}}
                 * (Phase 3 P3.3) — the most-recent co-signing ask this
                 * participant received from another, via
                 * identity_get_last_cosign_request. An ask that was refused by
                 * the shape gate (unknown act, a payload no exporter produced) or
                 * by the replay gate is ABSENT; `absent: true` asserts that, and
                 * it is what makes the refusal scenarios load-bearing rather than
                 * merely non-crashing. Mirrors the Python adapter's
                 * cosign_request_last, keyed by the same lowercased uuid. */
                const char *cr_pid;
                json_t *cr_want;
                json_object_foreach(val, cr_pid, cr_want) {
                    sce_participant_t *other = sce_find_participant(ctx, cr_pid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: cosign_request_last names unknown "
                                 "participant %s", pid, cr_pid);
                        return -1;
                    }
                    const public_identity_t *want_id =
                        ((ic_impl_t *)other->impl)->pub;
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(want_id->uuid, want_uuid);
                    char got_record[AT_COSIGN_TOKEN_MAX + 1];
                    char got_op[AT_COSIGN_TOKEN_MAX + 1];
                    char got_polity[AT_COSIGN_DID_MAX + 1];
                    char got_cid[AT_COSIGN_CID_MAX + 1];
                    static char got_bytes[AT_COSIGN_BYTES_MAX + 1];
                    int64_t got_seq = 0;
                    bool have = identity_get_last_cosign_request(
                        want_uuid, got_record, sizeof(got_record), got_op,
                        sizeof(got_op), got_polity, sizeof(got_polity), got_cid,
                        sizeof(got_cid), got_bytes, sizeof(got_bytes), &got_seq);
                    bool want_absent =
                        json_is_true(json_object_get(cr_want, "absent"));
                    if (want_absent) {
                        if (have) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: cosign_request_last[%s] present "
                                     "(%s/%s), expected ABSENT", pid, cr_pid,
                                     got_record, got_op);
                            return -1;
                        }
                        continue;
                    }
                    if (!have) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: cosign_request_last[%s] absent, expected "
                                 "an ask", pid, cr_pid);
                        return -1;
                    }
                    static const struct { const char *k; const char *v; }
                        cr_fields[] = {{"record", NULL}, {"op", NULL},
                                       {"polity", NULL}, {"cid", NULL},
                                       {"bytes", NULL}};
                    const char *cr_got[] = {got_record, got_op, got_polity,
                                            got_cid, got_bytes};
                    for (size_t f = 0; f < sizeof(cr_fields) / sizeof(cr_fields[0]); f++) {
                        json_t *jw = json_object_get(cr_want, cr_fields[f].k);
                        if (json_is_string(jw)
                            && strcmp(cr_got[f], json_string_value(jw)) != 0) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: cosign_request_last[%s].%s=%.80s, "
                                     "expected %.80s", pid, cr_pid,
                                     cr_fields[f].k, cr_got[f],
                                     json_string_value(jw));
                            return -1;
                        }
                    }
                    json_t *jcs = json_object_get(cr_want, "seq");
                    if (json_is_integer(jcs)
                        && got_seq != (int64_t)json_integer_value(jcs)) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: cosign_request_last[%s].seq=%lld, expected "
                                 "%lld", pid, cr_pid, (long long)got_seq,
                                 (long long)json_integer_value(jcs));
                        return -1;
                    }
                }
            } else if (strcmp(key, "cosign_sig_last") == 0) {
                /* {signer_id: {cid, signer, sig, seq} | {absent: true}} (Phase 3
                 * P3.3) — the most-recent co-signature this participant received
                 * back, via identity_get_last_cosign_sig. The core does NOT
                 * verify it (it does not hold the payload the signature is over),
                 * so what is pinned here is carriage and the replay gate, not
                 * validity. Mirrors the Python adapter's cosign_sig_last. */
                const char *cs_pid;
                json_t *cs_want;
                json_object_foreach(val, cs_pid, cs_want) {
                    sce_participant_t *other = sce_find_participant(ctx, cs_pid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: cosign_sig_last names unknown participant "
                                 "%s", pid, cs_pid);
                        return -1;
                    }
                    const public_identity_t *want_id =
                        ((ic_impl_t *)other->impl)->pub;
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(want_id->uuid, want_uuid);
                    char got_cid[AT_COSIGN_CID_MAX + 1];
                    char got_signer[AT_COSIGN_DID_MAX + 1];
                    char got_sig[AT_COSIGN_SIG_MAX + 1];
                    int64_t got_seq = 0;
                    bool have = identity_get_last_cosign_sig(
                        want_uuid, got_cid, sizeof(got_cid), got_signer,
                        sizeof(got_signer), got_sig, sizeof(got_sig), &got_seq);
                    bool want_absent =
                        json_is_true(json_object_get(cs_want, "absent"));
                    if (want_absent) {
                        if (have) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: cosign_sig_last[%s] present (cid=%.20s), "
                                     "expected ABSENT", pid, cs_pid, got_cid);
                            return -1;
                        }
                        continue;
                    }
                    if (!have) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: cosign_sig_last[%s] absent, expected a "
                                 "signature", pid, cs_pid);
                        return -1;
                    }
                    static const char *cs_keys[] = {"cid", "signer", "sig"};
                    const char *cs_got[] = {got_cid, got_signer, got_sig};
                    for (size_t f = 0; f < sizeof(cs_keys) / sizeof(cs_keys[0]); f++) {
                        json_t *jw = json_object_get(cs_want, cs_keys[f]);
                        if (json_is_string(jw)
                            && strcmp(cs_got[f], json_string_value(jw)) != 0) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: cosign_sig_last[%s].%s=%.80s, expected "
                                     "%.80s", pid, cs_pid, cs_keys[f], cs_got[f],
                                     json_string_value(jw));
                            return -1;
                        }
                    }
                    json_t *jss = json_object_get(cs_want, "seq");
                    if (json_is_integer(jss)
                        && got_seq != (int64_t)json_integer_value(jss)) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: cosign_sig_last[%s].seq=%lld, expected %lld",
                                 pid, cs_pid, (long long)got_seq,
                                 (long long)json_integer_value(jss));
                        return -1;
                    }
                }
            } else if (strcmp(key, "social_tx_last") == 0) {
                /* {subject_id: {score} | {absent: true}} (Increment 8) — the last
                 * interaction reputation score this participant STAGED about
                 * another peer, via identity_get_last_social_tx. A one-way (bilateral
                 * gate unmet) or capped interaction stages NOTHING -> ABSENT;
                 * `absent: true` asserts that. The score is the deterministic
                 * accrual observable, independent of the Paxos round. Mirrors the
                 * Python adapter's social_tx_last, keyed by the same lowercased
                 * subject uuid. */
                const char *stx_pid;
                json_t *stx_want;
                json_object_foreach(val, stx_pid, stx_want) {
                    sce_participant_t *other = sce_find_participant(ctx, stx_pid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: social_tx_last names unknown participant %s",
                                 pid, stx_pid);
                        return -1;
                    }
                    const public_identity_t *want_id =
                        ((ic_impl_t *)other->impl)->pub;
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(want_id->uuid, want_uuid);
                    char got_task[UUID_STR_LEN + 1] = {0};
                    double got_score = 0.0;
                    bool have = identity_get_last_social_tx(want_uuid, got_task,
                                                            &got_score);
                    bool want_absent =
                        json_is_true(json_object_get(stx_want, "absent"));
                    if (want_absent) {
                        if (have) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: social_tx_last[%s] present (score=%.6f), "
                                     "expected ABSENT", pid, stx_pid, got_score);
                            return -1;
                        }
                        continue;
                    }
                    if (!have) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: social_tx_last[%s] absent, expected a staged "
                                 "score", pid, stx_pid);
                        return -1;
                    }
                    json_t *jsc = json_object_get(stx_want, "score");
                    if (json_is_number(jsc)) {
                        double want_score = json_number_value(jsc);
                        if (fabs(got_score - want_score) > 1e-6) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: social_tx_last[%s].score=%.6f, expected "
                                     "%.6f", pid, stx_pid, got_score, want_score);
                            return -1;
                        }
                    }
                    /* channel / n (Phase 4 P4.1): which evidence channel the
                     * score was staged on, and how many were staged about this
                     * subject in all — what tells a capped second report from a
                     * first. Mirrors the Python adapter's generic field check. */
                    char got_ch[TX_CHANNEL_NAMELEN + 1] = {0};
                    int got_n = 0;
                    identity_get_social_tx_detail(want_uuid, got_ch,
                                                  sizeof(got_ch), &got_n);
                    json_t *jch = json_object_get(stx_want, "channel");
                    if (json_is_string(jch)
                        && strcmp(got_ch, json_string_value(jch)) != 0) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: social_tx_last[%s].channel=%s, expected %s",
                                 pid, stx_pid, got_ch, json_string_value(jch));
                        return -1;
                    }
                    json_t *jn = json_object_get(stx_want, "n");
                    if (json_is_integer(jn) && got_n != (int)json_integer_value(jn)) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: social_tx_last[%s].n=%d, expected %lld",
                                 pid, stx_pid, got_n,
                                 (long long)json_integer_value(jn));
                        return -1;
                    }
                    /* same_task_as {participant, subject}: our task must be the
                     * one that participant staged about that subject — the two
                     * halves of one transaction. id_state is shared, so the
                     * other participant's record is read by its SUBJECT uuid;
                     * the participant name is resolved only to fail loudly on a
                     * typo. */
                    json_t *jst = json_object_get(stx_want, "same_task_as");
                    if (json_is_object(jst)) {
                        const char *op = json_string_value(
                            json_object_get(jst, "participant"));
                        const char *os = json_string_value(
                            json_object_get(jst, "subject"));
                        sce_participant_t *opp = op != NULL
                            ? sce_find_participant(ctx, op) : NULL;
                        sce_participant_t *osp = os != NULL
                            ? sce_find_participant(ctx, os) : NULL;
                        if (opp == NULL || osp == NULL) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: same_task_as names an unknown participant",
                                     pid);
                            return -1;
                        }
                        char os_uuid[UUID_STR_LEN + 1];
                        uuid_unparse_lower(((ic_impl_t *)osp->impl)->pub->uuid,
                                           os_uuid);
                        char their_task[UUID_STR_LEN + 1] = {0};
                        if (!identity_get_last_social_tx(os_uuid, their_task, NULL)
                            || strcmp(their_task, got_task) != 0) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: social_tx_last[%s].task=%s, but %s staged"
                                     " %s about %s -- the halves would not pair",
                                     pid, stx_pid, got_task, op,
                                     their_task[0] ? their_task : "(none)", os);
                            return -1;
                        }
                    }
                }
            }
            else if (strcmp(key, "position_responses_emitted") == 0) {
                /* peer_position_response emissions by this participant
                 * (Increment 2). The opt-in guard's observable: an opted-OUT
                 * node emits 0 (position-absent-is-normal), an opted-IN one
                 * emits 1 per answered query — so dropping the guard makes the
                 * opt-out case fail. Mirrors the Python emit_tally check. */
                int want = (int)json_integer_value(val);
                int got = 0;
                for (size_t i = 0; i < ctx->captured_count; i++) {
                    if (strcmp(ctx->captured[i].from, pid) == 0
                        && strcmp(ctx->captured[i].function,
                                  "peer_position_response") == 0)
                        got++;
                }
                if (got != want) {
                    snprintf(ctx->err, sizeof(ctx->err),
                             "%s: position_responses_emitted=%d, expected %d",
                             pid, got, want);
                    return -1;
                }
            } else if (strcmp(key, "profile_responses_emitted") == 0) {
                /* peer_profile_response emissions by this participant (Increment
                 * 3) — the opt-in guard's observable, same shape as
                 * position_responses_emitted: 0 when opted out, 1 per answered
                 * query when opted in. Mirrors the Python emit_tally check. */
                int want = (int)json_integer_value(val);
                int got = 0;
                for (size_t i = 0; i < ctx->captured_count; i++) {
                    if (strcmp(ctx->captured[i].from, pid) == 0
                        && strcmp(ctx->captured[i].function,
                                  "peer_profile_response") == 0)
                        got++;
                }
                if (got != want) {
                    snprintf(ctx->err, sizeof(ctx->err),
                             "%s: profile_responses_emitted=%d, expected %d",
                             pid, got, want);
                    return -1;
                }
            } else if (strcmp(key, "file_frames_emitted") == 0) {
                /* {peer_file_<verb>: n}: file frames this participant sent.
                 * Mirrors the Python emit tallies. */
                const char *fn;
                json_t *jn;
                json_object_foreach(val, fn, jn) {
                    int want = (int)json_integer_value(jn);
                    int got = 0;
                    for (size_t i = 0; i < ctx->captured_count; i++)
                        if (strcmp(ctx->captured[i].from, pid) == 0
                            && strcmp(ctx->captured[i].function, fn) == 0)
                            got++;
                    if (got != want) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: file_frames_emitted[%s]=%d, expected %d",
                                 pid, fn, got, want);
                        return -1;
                    }
                }
            } else if (strcmp(key, "file_xfer") == 0) {
                /* {peer_id: {dir?, state?, done?, name?, reason?} | {absent:
                 * true}}: the transfer this participant holds with another,
                 * from file_xfer_dump. Mirrors the Python adapter's file_xfer. */
                char *dump = file_xfer_dump();
                json_t *arr = dump != NULL ? json_loads(dump, 0, NULL) : NULL;
                free(dump);
                const char *fpid;
                json_t *fwant;
                int rc = 0;
                json_object_foreach(val, fpid, fwant) {
                    sce_participant_t *other = sce_find_participant(ctx, fpid);
                    if (other == NULL) {
                        snprintf(ctx->err, sizeof(ctx->err),
                                 "%s: file_xfer names unknown participant %s", pid, fpid);
                        rc = -1;
                        break;
                    }
                    char want_uuid[UUID_STR_LEN + 1];
                    uuid_unparse_lower(((ic_impl_t *)other->impl)->pub->uuid, want_uuid);
                    const char *want_dir = json_string_value(json_object_get(fwant, "dir"));
                    json_t *rec = NULL;
                    for (size_t i = 0; arr != NULL && i < json_array_size(arr); i++) {
                        json_t *r = json_array_get(arr, i);
                        if (strcmp(json_string_value(json_object_get(r, "peer")), want_uuid) == 0
                            && (want_dir == NULL
                                || strcmp(json_string_value(json_object_get(r, "dir")), want_dir) == 0)) {
                            rec = r;
                            break;
                        }
                    }
                    bool absent = json_is_true(json_object_get(fwant, "absent"));
                    if (absent || rec == NULL) {
                        if (absent != (rec == NULL)) {
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: file_xfer[%s] %s", pid, fpid,
                                     absent ? "present, expected ABSENT" : "absent");
                            rc = -1;
                            break;
                        }
                        continue;
                    }
                    const char *fk;
                    json_t *fv;
                    json_object_foreach(fwant, fk, fv) {
                        json_t *g = json_object_get(rec, fk);
                        if (!json_equal(g, fv)) {
                            char *gs = g != NULL ? json_dumps(g, JSON_ENCODE_ANY) : NULL;
                            char *ws = json_dumps(fv, JSON_ENCODE_ANY);
                            snprintf(ctx->err, sizeof(ctx->err),
                                     "%s: file_xfer[%s].%s=%s, expected %s", pid, fpid,
                                     fk, gs != NULL ? gs : "(none)", ws != NULL ? ws : "?");
                            free(gs);
                            free(ws);
                            rc = -1;
                            break;
                        }
                    }
                    if (rc != 0)
                        break;
                }
                json_decref(arr);
                if (rc != 0)
                    return -1;
            } else if (strcmp(key, "proximity_probes_emitted") == 0
                       || strcmp(key, "proximity_replies_emitted") == 0) {
                /* peer_proximity_probe/reply emissions attributed to this
                 * participant (Phase 2). The initiator's probe count is the
                 * opt-in guard's observable (0 opted out / not connected, 1 per
                 * trigger); the responder's reply count is its own opt-in
                 * observable. Mirrors the Python emit_tally check. */
                const char *want_fn = (strcmp(key, "proximity_probes_emitted") == 0)
                    ? "peer_proximity_probe" : "peer_proximity_reply";
                int want = (int)json_integer_value(val);
                int got = 0;
                for (size_t i = 0; i < ctx->captured_count; i++) {
                    if (strcmp(ctx->captured[i].from, pid) == 0
                        && strcmp(ctx->captured[i].function, want_fn) == 0)
                        got++;
                }
                if (got != want) {
                    snprintf(ctx->err, sizeof(ctx->err),
                             "%s: %s=%d, expected %d", pid, key, got, want);
                    return -1;
                }
            }
    else {
        return 1;
    }
    return 0;
}

static const ic_ext_t SOCIAL_EXT = {
    .name = "social",
    .fixtures = _social_fixtures,
    .inbound = _social_inbound,
    .dispatch = _social_dispatch,
    .check_key = _social_check_key,
    .on_send = _social_on_send,
    .impl_free = _social_impl_free,
};

void at_social_run(const at_case_t *c, at_case_result_t *out)
{
    at_identity_run_ext(c, out, &SOCIAL_EXT);
}
