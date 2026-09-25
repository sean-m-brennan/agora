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
/* The social half of AT's test/identity_resync_test.c (moved with social to
 * Agora): PEER_OBSERVED's in_group, which libat_social answers
 * (identity_ext_t.peer_in_group), follows real group convergence rather than
 * address overlap. The test and the helpers it needs are the originals
 * verbatim; AT's copy pins the core-only answer (always 0). */
#define DEBUG_TESTS 1
#include "test_setup.h"

#include <pthread.h>
#include <string.h>
#include <stdlib.h>

#include <jansson.h>
#include <uuid/uuid.h>

#include "identity/identity.h"
#include "identity/identity_priv.h"
#include "identity/id_proc_priv.h"
#include "identity/group.h"
#include "config/configuration.h"
#include "structures/data.h"
#include "structures/map.h"
#include "structures/array.h"
#include "processes/processes.h"
#include "utilities/message.h"
#include "utilities/msg_types.h"
#include "utilities/msg_types_priv.h"
#include "utilities/allocation.h"
#include "utilities/util.h"

/* Mutable storage: net_msg_t.function is `char *`, so a const string literal
 * can't be assigned directly. */
static char ID_QUERY_FN[]    = "peer_identity_query";
static char ID_RESPONSE_FN[] = "peer_identity_response";
static char ID_UPDATE_FN[]   = "group_key_update";

/* ------------------------------------------------------------------ */
static size_t g_query_count;
static size_t g_response_count;
static char   g_last_query_group[UUID_STRING_LEN + 1];
static json_t *g_last_query_have;   /* owned; freed in _end */
/* Last PEER_OBSERVED emission's group-membership flag: -1 none yet, else 0/1. */
static int g_last_peer_observed_in_group;

static int _capture_hook(const char *key, const message_type_t type,
                         generic_msg_t *msg, bool blocking)
{
    (void)key; (void)blocking;
    if (type == PEER_OBSERVED) {
        g_last_peer_observed_in_group = msg->info.peer_observed.in_group ? 1 : 0;
        return 0;
    }
    if (type != NET_MESSAGE || msg->info.net_msg.function == NULL)
        return 0;
    const char *fn = msg->info.net_msg.function;
    if (strcmp(fn, ID_QUERY_FN) == 0) {
        g_query_count++;
        /* Stash the payload for assertion (group_uuid + have-list). */
        if (msg->info.net_msg.obj != NULL) {
            json_error_t err;
            json_t *p = json_loads((const char *)msg->info.net_msg.obj, 0, &err);
            if (p != NULL && json_is_object(p)) {
                const char *g = json_string_value(json_object_get(p, "group_uuid"));
                if (g != NULL) {
                    strncpy(g_last_query_group, g, UUID_STRING_LEN);
                    g_last_query_group[UUID_STRING_LEN] = '\0';
                }
                if (g_last_query_have != NULL)
                    json_decref(g_last_query_have);
                g_last_query_have = json_incref(json_object_get(p, "have"));
            }
            if (p != NULL) json_decref(p);
        }
    } else if (strcmp(fn, ID_RESPONSE_FN) == 0) {
        g_response_count++;
    }
    return 0;
}

static identity_t *_mk_identity(const char *name, const char *addr)
{
    uuid_t uuid;
    uuid_generate(uuid);
    identity_t *ident = NULL;
    ck_assert_ret_ok(identity_create(&uuid, addr, name, name, &ident));
    ck_assert_ptr_nonnull(ident);
    return ident;
}

static process_t *_mk_process(identity_t *self)
{
    process_t *proc = smrt_create(sizeof(process_t));
    ck_assert_ptr_nonnull(proc);
    pthread_rwlock_init(&proc->protocol.peers_rwlock, NULL);
    strncpy(proc->name, "identity", PROC_NAME_LEN);
    proc->protocol.phase = 3;
    proc->protocol.num_peers = 0;

    uuid_t guuid;
    uuid_generate(guuid);
    group_init(&guuid, (char *)self->address, &proc->protocol.group);
    char self_uuid[UUID_STRING_LEN + 1];
    uuid_unparse_lower(self->uuid, self_uuid);
    group_add_address(&proc->protocol.group, self_uuid, self->address);

    config_t *id_cfg = calloc(1, sizeof(config_t));
    ck_assert_ptr_nonnull(id_cfg);
    id_cfg->name = "identity";
    id_cfg->data_struct = self;
    data_t *id_dat = object_ptr_data((ptr_t)id_cfg, sizeof(config_t));
    ck_assert_ret_ok(map_create(&proc->configs));
    map_set(proc->configs, (map_key_t)"identity", id_dat);

    ck_assert_ret_ok(map_create(&proc->protocol.handlers));
    ck_assert_ret_ok(identity_register_handlers(proc));
    return proc;
}

static void _add_group_member_addr(process_t *proc, identity_t *member)
{
    char u[UUID_STRING_LEN + 1];
    uuid_unparse_lower(member->uuid, u);
    group_add_address(&proc->protocol.group, u, member->address);
}

static void _group_uuid_str(const process_t *proc, char out[UUID_STRING_LEN + 1])
{
    uuid_unparse_lower(proc->protocol.group.uuid, out);
}

static void _begin(void)
{
    identity_reset_state();
    g_query_count = 0;
    g_response_count = 0;
    g_last_query_group[0] = '\0';
    g_last_query_have = NULL;
    g_last_peer_observed_in_group = -1;
    messaging_set_test_hook(_capture_hook);
}

static void _end(void)
{
    messaging_set_test_hook(NULL);
    if (g_last_query_have != NULL) {
        json_decref(g_last_query_have);
        g_last_query_have = NULL;
    }
}

static void _dispatch_group_update(process_t *proc, identity_t *member,
                                   const char *group_uuid_str)
{
    char mu[UUID_STRING_LEN + 1];
    uuid_unparse_lower(member->uuid, mu);
    json_t *addr_map = json_object();
    json_object_set_new(addr_map, mu, json_string(member->address));

    json_t *payload = json_object();
    json_object_set_new(payload, "uuid", json_string(group_uuid_str));
    json_object_set_new(payload, "address_map", addr_map);
    json_object_set_new(payload, "created", json_real(0.0));

    generic_msg_t msg = {0};
    msg.type = NET_MESSAGE;
    strncpy(msg.info.net_msg.process, "identity", PROC_NAME_LEN);
    msg.info.net_msg.function = ID_UPDATE_FN;
    uuid_copy(msg.info.net_msg.from_whom.uuid, member->uuid);
    at_strlcpy(msg.info.net_msg.from_whom.nickname, member->nickname,
               sizeof(msg.info.net_msg.from_whom.nickname));
    ck_assert_ret_ok(net_msg_pack_json(&msg.info.net_msg, payload));
    json_decref(payload);

    directory_t *queues = NULL;
    ck_assert_ret_ok(array_create(&queues));
    run_message_handlers(proc, queues, NET_MESSAGE, &msg);
    array_free(queues);
}

/* Part B: the "in your group" flag reflects real convergence — the peer having
 * advertised OUR group uuid — NOT mere address overlap (which is true from the
 * mesh merge onward, during the pre-convergence split-brain). Regression for
 * the badge lighting up before posts can flow. Non-social builds lack the flag;
 * the emit must still run. */
DEFINE_TEST(test_emit_peer_observed_in_group_follows_convergence)
{
    _begin();
    identity_t *me = _mk_identity("coord", "10.0.0.1");
    identity_t *member = _mk_identity("alice", "10.0.0.2");
    identity_t *stranger = _mk_identity("mallory", "10.9.9.9");
    process_t *proc = _mk_process(me);

    char ours[UUID_STRING_LEN + 1];
    _group_uuid_str(proc, ours);

    public_identity_t *mpub = NULL;
    ck_assert_ret_ok(identity_publish(member, &mpub));

    /* Address is in our map (mesh merge) but the peer has not advertised our
     * group yet -> NOT in group (the split-brain false-positive we fixed). */
    _add_group_member_addr(proc, member);
    identity_emit_peer_observed(proc, mpub);
    ck_assert_int_eq(g_last_peer_observed_in_group, 0);

    /* Peer advertises OUR group uuid -> converged -> in group. */
    _dispatch_group_update(proc, member, ours);
    identity_emit_peer_observed(proc, mpub);
    ck_assert_int_eq(g_last_peer_observed_in_group, 1);

    /* Swap-robustness: if WE then adopt a different group (our uuid changes),
     * the earlier record ("ours|ours") is stale — it must NOT keep counting as
     * co-membership, even though the peer once advertised our-then-uuid. This is
     * the mutual-adopt-swap case that a bare their==ours check gets wrong. */
    uuid_generate(proc->protocol.group.uuid);
    identity_emit_peer_observed(proc, mpub);
    ck_assert_int_eq(g_last_peer_observed_in_group, 0);

    /* Once the peer re-advertises our NEW group uuid, co-membership holds again. */
    char ours2[UUID_STRING_LEN + 1];
    _group_uuid_str(proc, ours2);
    _dispatch_group_update(proc, member, ours2);
    identity_emit_peer_observed(proc, mpub);
    ck_assert_int_eq(g_last_peer_observed_in_group, 1);
    smrt_deref(mpub);

    /* A peer that never advertised our group stays out. */
    public_identity_t *spub = NULL;
    ck_assert_ret_ok(identity_publish(stranger, &spub));
    identity_emit_peer_observed(proc, spub);
    ck_assert_int_eq(g_last_peer_observed_in_group, 0);
    smrt_deref(spub);
    _end();
}

RUN_TESTS(Social_In_Group, test_emit_peer_observed_in_group_follows_convergence)
