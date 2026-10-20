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

/** @file DM file sharing through the identity handlers (id_file_xfer.c).
 *
 *  Identity's state is process-global, so one test process is one node. Each
 *  test plays ONE side for real and writes the other side's frames by hand,
 *  exactly as route_to_process would deliver them (from_whom populated). What
 *  the node sends is caught by messaging_set_test_hook: frames to "network"
 *  and events to the app's queue. */

#define DEBUG_TESTS 1
#include "test_setup.h"

#include <dirent.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <jansson.h>
#include <uuid/uuid.h>

#include "identity/identity.h"
#include "identity/identity_priv.h"
#include "identity/id_proc_priv.h"
#include "config/configuration.h"
#include "structures/data.h"
#include "structures/map.h"
#include "processes/processes.h"
#include "utilities/message.h"
#include "utilities/msg_types.h"
#include "utilities/msg_types_priv.h"
#include "utilities/allocation.h"
#include "utilities/send_retry.h"
#include "social/social_msg_types.h"
#include "social/file_xfer.h"
#include "social/id_file_xfer.h"

static const char ID[] = "00112233445566778899aabbccddeeff";

/* ------------------------------------------------------------------ */
/* Capture                                                             */
/* ------------------------------------------------------------------ */

#define CAP_MAX 256

static struct {
    char    fn[CAP_MAX][40];
    json_t *body[CAP_MAX];
    uuid_t  to[CAP_MAX];
    size_t  n;
    peer_file_msg_t ev[CAP_MAX];
    size_t  n_ev;
} cap;

static int _hook(const char *key, const message_type_t type,
                 generic_msg_t *msg, bool blocking)
{
    (void)blocking;
    if (key != NULL && strcmp(key, AT_MAIN_QUEUE) == 0) {
        if (type == PEER_FILE_OBSERVED && cap.n_ev < CAP_MAX)
            memcpy(&cap.ev[cap.n_ev++], AT_MSG_EXT(msg, peer_file_msg_t),
                   sizeof(peer_file_msg_t));
        return 0;
    }
    if (key != NULL && strcmp(key, "network") == 0 && type == NET_MESSAGE
        && msg->info.net_msg.function != NULL
        && strncmp(msg->info.net_msg.function, "peer_file_", 10) == 0
        && cap.n < CAP_MAX) {
        snprintf(cap.fn[cap.n], sizeof(cap.fn[0]), "%s", msg->info.net_msg.function);
        cap.body[cap.n] = json_loadb((const char *)msg->info.net_msg.obj,
                                     msg->info.net_msg.len, 0, NULL);
        memcpy(cap.to[cap.n], msg->info.net_msg.to_whom.uuid, sizeof(uuid_t));
        cap.n++;
    }
    return 0;
}

static void _cap_clear(void)
{
    for (size_t i = 0; i < cap.n; i++)
        json_decref(cap.body[i]);
    cap.n = 0;
    cap.n_ev = 0;
}

static size_t _count(const char *fn)
{
    size_t c = 0;
    for (size_t i = 0; i < cap.n; i++)
        if (strcmp(cap.fn[i], fn) == 0)
            c++;
    return c;
}

/* The k-th captured frame of @p fn, or NULL. */
static json_t *_frame(const char *fn, size_t k)
{
    for (size_t i = 0; i < cap.n; i++)
        if (strcmp(cap.fn[i], fn) == 0 && k-- == 0)
            return cap.body[i];
    return NULL;
}

static const char *_ctl_op(size_t k)
{
    json_t *j = _frame("peer_file_ctl", k);
    return j != NULL ? json_string_value(json_object_get(j, "op")) : NULL;
}

static const peer_file_msg_t *_last_ev(void)
{
    return cap.n_ev > 0 ? &cap.ev[cap.n_ev - 1] : NULL;
}

/* ------------------------------------------------------------------ */
/* Fixtures                                                            */
/* ------------------------------------------------------------------ */

static char g_root[64];

static identity_t *_mk_identity(const char *name, const char *addr)
{
    uuid_t uuid;
    uuid_generate(uuid);
    identity_t *ident = NULL;
    ck_assert_ret_ok(identity_create(&uuid, addr, name, name, &ident));
    return ident;
}

static process_t *_mk_process(identity_t *self)
{
    process_t *proc = smrt_create(sizeof(process_t));
    ck_assert_ptr_nonnull(proc);
    pthread_rwlock_init(&proc->protocol.peers_rwlock, NULL);
    strncpy(proc->name, "identity", PROC_NAME_LEN);
    proc->protocol.phase = 3;
    uuid_t guuid;
    uuid_generate(guuid);
    group_init(&guuid, (char *)self->address, &proc->protocol.group);
    char self_uuid[UUID_STRING_LEN + 1];
    uuid_unparse_lower(self->uuid, self_uuid);
    group_add_address(&proc->protocol.group, self_uuid, self->address);
    config_t *id_cfg = calloc(1, sizeof(config_t));
    id_cfg->name = "identity";
    id_cfg->data_struct = self;
    data_t *id_dat = object_ptr_data((ptr_t)id_cfg, sizeof(config_t));
    ck_assert_ret_ok(map_create(&proc->configs));
    map_set(proc->configs, (map_key_t)"identity", id_dat);
    ck_assert_ret_ok(map_create(&proc->protocol.handlers));
    ck_assert_ret_ok(identity_register_handlers(proc));
    return proc;
}

static void _add_peer(process_t *proc, identity_t *peer)
{
    public_identity_t *pub = NULL;
    ck_assert_ret_ok(identity_publish(peer, &pub));
    memcpy(&proc->protocol.peers[proc->protocol.num_peers++], pub,
           sizeof(public_identity_t));
    smrt_deref(pub);
}

/* A verb as the shim sends it (@p from NULL) or as a peer's frame arrives. */
static void _drive(process_t *proc, const char *fn, json_t *payload,
                   const identity_t *from)
{
    generic_msg_t msg = {0};
    msg.type = NET_MESSAGE;
    strncpy(msg.info.net_msg.process, "identity", PROC_NAME_LEN);
    msg.info.net_msg.function = (char *)fn;
    msg.info.net_msg.verified = true;
    if (from != NULL) {
        public_identity_t *pub = NULL;
        ck_assert_ret_ok(identity_publish((identity_t *)from, &pub));
        memcpy(&msg.info.net_msg.from_whom, pub, sizeof(public_identity_t));
        smrt_deref(pub);
    }
    ck_assert_ret_ok(net_msg_pack_json(&msg.info.net_msg, payload));
    json_decref(payload);
    run_message_handlers(proc, NULL, NET_MESSAGE, &msg);
    net_msg_free_obj(&msg.info.net_msg);
}

static json_t *_peer_id(const identity_t *peer, const char *id)
{
    char s[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer->uuid, s);
    return json_pack("{s:s, s:s}", "peer", s, "id", id);
}

static void _rm_rf(const char *dir)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", dir);
    ck_assert_int_eq(system(cmd), 0);
}

static void _begin(void)
{
    snprintf(g_root, sizeof(g_root), "/tmp/fx_flow_XXXXXX");
    ck_assert_ptr_nonnull(mkdtemp(g_root));
    char etc[128];
    snprintf(etc, sizeof(etc), "%s/etc/at", g_root);
    char cmd[200];
    snprintf(cmd, sizeof(cmd), "mkdir -p '%s'", etc);
    ck_assert_int_eq(system(cmd), 0);
    setenv("AUTONOMOUS_TRUST_ROOT", g_root, 1);
    unsetenv("AT_FILE_WINDOW");
    unsetenv("AT_FILE_MAX_BYTES");
    unsetenv("AT_FILE_CHUNK");
    identity_reset_state();
    _cap_clear();
    messaging_set_test_hook(_hook);
}

static void _end(void)
{
    messaging_set_test_hook(NULL);
    at_send_retry_reset();
    file_xfer_reset();
    _cap_clear();
    _rm_rf(g_root);
}

/* @p n deterministic bytes. */
static uint8_t *_bytes(size_t n, unsigned seed)
{
    uint8_t *b = malloc(n);
    for (size_t i = 0; i < n; i++)
        b[i] = (uint8_t)((i * 2654435761u + seed) >> 7);
    return b;
}

static void _write(const char *path, const uint8_t *b, size_t n)
{
    FILE *f = fopen(path, "wb");
    ck_assert_ptr_nonnull(f);
    ck_assert_uint_eq(fwrite(b, 1, n, f), n);
    fclose(f);
}

static void _hash_of(const uint8_t *b, size_t n, char out[AT_FILE_HASH_HEX_LEN + 1])
{
    char p[128];
    snprintf(p, sizeof(p), "%s/hash.tmp", g_root);
    _write(p, b, n);
    ck_assert_int_eq(at_file_hash(p, (int64_t)n, out), 0);
    unlink(p);
}

/* Bob offers @p n bytes in @p chunk-sized chunks. */
static void _bob_offers(process_t *proc, const identity_t *bob, const uint8_t *b,
                        size_t n, uint32_t chunk, const char *name)
{
    at_file_offer_t o = {0};
    memcpy(o.id, ID, sizeof(o.id));
    snprintf(o.name, sizeof(o.name), "%s", name);
    o.size = (int64_t)n;
    o.chunk = chunk;
    o.total = at_file_total_chunks(o.size, chunk);
    _hash_of(b, n, o.hash);
    o.ts = (double)time(NULL);
    _drive(proc, "peer_file_offer", at_file_offer_to_json(&o), bob);
}

static void _chunk_from(process_t *proc, const identity_t *who, const uint8_t *b,
                        size_t n, uint32_t chunk, uint32_t i)
{
    _drive(proc, "peer_file_chunk",
           at_file_chunk_to_json(ID, i, b + (size_t)i * chunk,
                                 at_file_chunk_len((int64_t)n, chunk, i)),
           who);
}

static size_t _files_in(const char *sub)
{
    char dir[160];
    snprintf(dir, sizeof(dir), "%s/var/agora/files%s", g_root, sub);
    DIR *d = opendir(dir);
    if (d == NULL)
        return 0;
    size_t c = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL)
        if (e->d_name[0] != '.' || (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")
                                    && strcmp(e->d_name, ".partial")))
            c++;
    closedir(d);
    return c;
}

/* ------------------------------------------------------------------ */
/* The sender                                                          */
/* ------------------------------------------------------------------ */

DEFINE_TEST(test_the_sender_offers_serves_what_is_asked_and_finishes_on_done)
{
    _begin();
    identity_t *me = _mk_identity("me", "10.0.0.1");
    identity_t *bob = _mk_identity("bob", "10.0.0.2");
    identity_t *carol = _mk_identity("carol", "10.0.0.3");
    process_t *proc = _mk_process(me);
    _add_peer(proc, bob);
    _add_peer(proc, carol);

    size_t n = 40000;
    uint8_t *src = _bytes(n, 1);
    char path[128];
    snprintf(path, sizeof(path), "%s/holiday photo.jpg", g_root);
    _write(path, src, n);

    json_t *p = _peer_id(bob, ID);
    json_object_set_new(p, "path", json_string(path));
    _drive(proc, AT_APP_FILE_OFFER, p, NULL);

    ck_assert_uint_eq(_count("peer_file_offer"), 1);
    json_t *offer = _frame("peer_file_offer", 0);
    ck_assert_str_eq(json_string_value(json_object_get(offer, "name")), "holiday photo.jpg");
    ck_assert_int_eq(json_integer_value(json_object_get(offer, "size")), 40000);
    ck_assert_int_eq(json_integer_value(json_object_get(offer, "chunk")), AT_FILE_CHUNK_DEFAULT);
    char want_hash[AT_FILE_HASH_HEX_LEN + 1];
    _hash_of(src, n, want_hash);
    ck_assert_str_eq(json_string_value(json_object_get(offer, "hash")), want_hash);
    ck_assert_int_eq(uuid_compare(cap.to[0], bob->uuid), 0);
    ck_assert_int_eq(_last_ev()->state, AT_FILE_OFFERED);
    ck_assert_int_eq(_last_ev()->outgoing, 1);
    ck_assert_str_eq(_last_ev()->xfer_id, ID);

    /* Offering the same id again is the same transfer, not a second one. */
    p = _peer_id(bob, ID);
    json_object_set_new(p, "path", json_string(path));
    _drive(proc, AT_APP_FILE_OFFER, p, NULL);
    ck_assert_uint_eq(_count("peer_file_offer"), 1);

    p = json_pack("{s:s, s:s}", "id", ID, "op", "accept");
    _drive(proc, "peer_file_ctl", p, bob);
    ck_assert_int_eq(_last_ev()->state, AT_FILE_ACCEPTED);

    /* Carol asks for Bob's transfer: she gets nothing but a refusal. */
    _cap_clear();
    _drive(proc, "peer_file_req", at_file_req_to_json(ID, 0, 3), carol);
    ck_assert_uint_eq(_count("peer_file_chunk"), 0);
    ck_assert_str_eq(_ctl_op(0), "fail");
    ck_assert_int_eq(uuid_compare(cap.to[0], carol->uuid), 0);

    /* Bob asks for all three, out of order of arrival being his business. */
    _cap_clear();
    _drive(proc, "peer_file_req", at_file_req_to_json(ID, 0, 3), bob);
    ck_assert_uint_eq(_count("peer_file_chunk"), 3);
    uint8_t *got = calloc(1, n);
    uint8_t buf[AT_FILE_CHUNK_MAX];
    for (size_t k = 0; k < 3; k++) {
        char id[AT_FILE_ID_HEX_LEN + 1];
        uint32_t idx = 0;
        size_t len = 0;
        ck_assert_int_eq(at_file_chunk_from_json(_frame("peer_file_chunk", k), id,
                                                 &idx, buf, sizeof(buf), &len), 0);
        memcpy(got + (size_t)idx * AT_FILE_CHUNK_DEFAULT, buf, len);
    }
    ck_assert_int_eq(memcmp(got, src, n), 0);

    /* A request past the end is dropped. */
    _cap_clear();
    _drive(proc, "peer_file_req", at_file_req_to_json(ID, 2, 2), bob);
    ck_assert_uint_eq(_count("peer_file_chunk"), 0);

    p = json_pack("{s:s, s:s}", "id", ID, "op", "done");
    _drive(proc, "peer_file_ctl", p, bob);
    ck_assert_int_eq(_last_ev()->state, AT_FILE_DONE);
    ck_assert_int_eq(_last_ev()->bytes_done, 40000);

    free(got);
    free(src);
    _end();
}
END_TEST_DEFINITION()

DEFINE_TEST(test_a_source_changed_after_the_offer_is_not_served)
{
    _begin();
    identity_t *me = _mk_identity("me", "10.0.0.1");
    identity_t *bob = _mk_identity("bob", "10.0.0.2");
    process_t *proc = _mk_process(me);
    _add_peer(proc, bob);
    uint8_t *src = _bytes(5000, 2);
    char path[128];
    snprintf(path, sizeof(path), "%s/notes.txt", g_root);
    _write(path, src, 5000);
    json_t *p = _peer_id(bob, ID);
    json_object_set_new(p, "path", json_string(path));
    _drive(proc, AT_APP_FILE_OFFER, p, NULL);

    _write(path, src, 4000);   /* edited after offering */
    _cap_clear();
    _drive(proc, "peer_file_req", at_file_req_to_json(ID, 0, 1), bob);
    ck_assert_uint_eq(_count("peer_file_chunk"), 0);
    ck_assert_str_eq(_ctl_op(0), "fail");
    ck_assert_int_eq(_last_ev()->state, AT_FILE_FAILED);
    ck_assert_str_eq(_last_ev()->reason, "source_changed");

    /* An unreadable path fails at once, so the bubble is never stuck. */
    _cap_clear();
    p = _peer_id(bob, "ffeeddccbbaa99887766554433221100");
    json_object_set_new(p, "path", json_string("/nonexistent/x"));
    _drive(proc, AT_APP_FILE_OFFER, p, NULL);
    ck_assert_uint_eq(_count("peer_file_offer"), 0);
    ck_assert_int_eq(_last_ev()->state, AT_FILE_FAILED);
    ck_assert_str_eq(_last_ev()->reason, "unreadable");
    free(src);
    _end();
}
END_TEST_DEFINITION()

/* ------------------------------------------------------------------ */
/* The receiver                                                        */
/* ------------------------------------------------------------------ */

DEFINE_TEST(test_the_receiver_pulls_verifies_and_places_the_file)
{
    _begin();
    identity_t *me = _mk_identity("me", "10.0.0.1");
    identity_t *bob = _mk_identity("bob", "10.0.0.2");
    process_t *proc = _mk_process(me);
    _add_peer(proc, bob);
    size_t n = 40000;
    uint8_t *src = _bytes(n, 3);

    _bob_offers(proc, bob, src, n, 16384, "../../report.pdf");
    ck_assert_uint_eq(cap.n_ev, 1);
    ck_assert_int_eq(_last_ev()->state, AT_FILE_OFFERED);
    ck_assert_int_eq(_last_ev()->outgoing, 0);
    ck_assert_str_eq(_last_ev()->name, "report.pdf");
    ck_assert_uint_eq(cap.n, 0);   /* nothing moves before Accept */

    _drive(proc, AT_APP_FILE_ACCEPT, _peer_id(bob, ID), NULL);
    ck_assert_str_eq(_ctl_op(0), "accept");
    ck_assert_uint_eq(_count("peer_file_req"), 1);
    json_t *req = _frame("peer_file_req", 0);
    ck_assert_int_eq(json_integer_value(json_object_get(req, "first")), 0);
    ck_assert_int_eq(json_integer_value(json_object_get(req, "count")), 3);

    _cap_clear();
    _chunk_from(proc, bob, src, n, 16384, 2);
    _chunk_from(proc, bob, src, n, 16384, 2);   /* a duplicate is harmless */
    _chunk_from(proc, bob, src, n, 16384, 0);
    ck_assert_uint_eq(_count("peer_file_ctl"), 0);
    _chunk_from(proc, bob, src, n, 16384, 1);

    ck_assert_str_eq(_ctl_op(0), "done");
    const peer_file_msg_t *ev = _last_ev();
    ck_assert_int_eq(ev->state, AT_FILE_DONE);
    char want[160];
    snprintf(want, sizeof(want), "%s/var/agora/files/report.pdf", g_root);
    ck_assert_str_eq(ev->path, want);
    FILE *f = fopen(want, "rb");
    ck_assert_ptr_nonnull(f);
    uint8_t *got = malloc(n + 1);
    ck_assert_uint_eq(fread(got, 1, n + 1, f), n);
    fclose(f);
    ck_assert_int_eq(memcmp(got, src, n), 0);
    ck_assert_uint_eq(_files_in("/.partial"), 0);   /* no part, no map */
    free(got);
    free(src);
    _end();
}
END_TEST_DEFINITION()

DEFINE_TEST(test_a_chunk_from_anyone_but_the_offerer_is_ignored)
{
    _begin();
    identity_t *me = _mk_identity("me", "10.0.0.1");
    identity_t *bob = _mk_identity("bob", "10.0.0.2");
    identity_t *mallory = _mk_identity("mallory", "10.0.0.4");
    process_t *proc = _mk_process(me);
    _add_peer(proc, bob);
    _add_peer(proc, mallory);
    size_t n = 3000;
    uint8_t *src = _bytes(n, 4);
    uint8_t *junk = _bytes(n, 99);
    _bob_offers(proc, bob, src, n, 1024, "a.bin");

    /* Before Accept, even Bob's chunks are refused. */
    _chunk_from(proc, bob, src, n, 1024, 0);
    _drive(proc, AT_APP_FILE_ACCEPT, _peer_id(bob, ID), NULL);
    for (uint32_t i = 0; i < 3; i++)
        _chunk_from(proc, mallory, junk, n, 1024, i);
    char *dump = file_xfer_dump();
    json_t *arr = json_loads(dump, 0, NULL);
    free(dump);
    ck_assert_uint_eq(json_array_size(arr), 1);
    ck_assert_int_eq(json_integer_value(json_object_get(json_array_get(arr, 0), "done")), 0);
    json_decref(arr);

    for (uint32_t i = 0; i < 3; i++)
        _chunk_from(proc, bob, src, n, 1024, i);
    ck_assert_int_eq(_last_ev()->state, AT_FILE_DONE);
    free(src);
    free(junk);
    _end();
}
END_TEST_DEFINITION()

DEFINE_TEST(test_a_corrupt_file_fails_and_leaves_nothing_behind)
{
    _begin();
    identity_t *me = _mk_identity("me", "10.0.0.1");
    identity_t *bob = _mk_identity("bob", "10.0.0.2");
    process_t *proc = _mk_process(me);
    _add_peer(proc, bob);
    size_t n = 3000;
    uint8_t *src = _bytes(n, 5);
    _bob_offers(proc, bob, src, n, 1024, "a.bin");
    _drive(proc, AT_APP_FILE_ACCEPT, _peer_id(bob, ID), NULL);
    src[1500] ^= 0xff;   /* Bob's copy is not what Bob hashed */
    _cap_clear();
    for (uint32_t i = 0; i < 3; i++)
        _chunk_from(proc, bob, src, n, 1024, i);
    ck_assert_int_eq(_last_ev()->state, AT_FILE_FAILED);
    ck_assert_str_eq(_last_ev()->reason, "hash_mismatch");
    ck_assert_str_eq(_ctl_op(0), "fail");
    ck_assert_uint_eq(_files_in(""), 0);
    ck_assert_uint_eq(_files_in("/.partial"), 0);
    free(src);
    _end();
}
END_TEST_DEFINITION()

DEFINE_TEST(test_a_restart_resumes_from_the_bitmap)
{
    _begin();
    setenv("AT_FILE_WINDOW", "4", 1);
    identity_t *me = _mk_identity("me", "10.0.0.1");
    identity_t *bob = _mk_identity("bob", "10.0.0.2");
    process_t *proc = _mk_process(me);
    _add_peer(proc, bob);
    size_t n = 20 * 1024 + 7;   /* 21 chunks */
    uint8_t *src = _bytes(n, 6);
    _bob_offers(proc, bob, src, n, 1024, "big.bin");
    _drive(proc, AT_APP_FILE_ACCEPT, _peer_id(bob, ID), NULL);
    /* The window is 4: the first request names 0..3 and no more. */
    json_t *req = _frame("peer_file_req", 0);
    ck_assert_int_eq(json_integer_value(json_object_get(req, "count")), 4);

    for (uint32_t i = 0; i < 18; i++)
        _chunk_from(proc, bob, src, n, 1024, i);
    /* The sweep saves what has not been saved; then the node "stops". */
    file_xfer_periodic(proc);
    file_xfer_reset();

    _cap_clear();
    file_xfer_run_start(proc);
    file_xfer_periodic(proc);
    /* Only the missing tail is asked for: 18, 19, 20 in one run. */
    ck_assert_uint_eq(_count("peer_file_req"), 1);
    req = _frame("peer_file_req", 0);
    ck_assert_int_eq(json_integer_value(json_object_get(req, "first")), 18);
    ck_assert_int_eq(json_integer_value(json_object_get(req, "count")), 3);
    for (uint32_t i = 18; i < 21; i++)
        _chunk_from(proc, bob, src, n, 1024, i);
    ck_assert_int_eq(_last_ev()->state, AT_FILE_DONE);
    char path[160];
    snprintf(path, sizeof(path), "%s/var/agora/files/big.bin", g_root);
    struct stat st;
    ck_assert_int_eq(stat(path, &st), 0);
    ck_assert_int_eq(st.st_size, (off_t)n);
    free(src);
    _end();
}
END_TEST_DEFINITION()

/* ------------------------------------------------------------------ */
/* Refusals                                                            */
/* ------------------------------------------------------------------ */

DEFINE_TEST(test_a_blocked_sender_cannot_offer)
{
    _begin();
    identity_t *me = _mk_identity("me", "10.0.0.1");
    identity_t *bob = _mk_identity("bob", "10.0.0.2");
    process_t *proc = _mk_process(me);
    _add_peer(proc, bob);
    char s[UUID_STRING_LEN + 1];
    uuid_unparse_lower(bob->uuid, s);
    _drive(proc, "app_block", json_pack("{s:s}", "peer", s), NULL);
    uint8_t *src = _bytes(100, 7);
    _bob_offers(proc, bob, src, 100, 1024, "a.bin");
    ck_assert_uint_eq(cap.n_ev, 0);
    char *dump = file_xfer_dump();
    ck_assert_str_eq(dump, "[]");
    free(dump);
    free(src);
    _end();
}
END_TEST_DEFINITION()

DEFINE_TEST(test_an_offer_over_the_cap_cannot_be_accepted)
{
    _begin();
    setenv("AT_FILE_MAX_BYTES", "1000", 1);
    identity_t *me = _mk_identity("me", "10.0.0.1");
    identity_t *bob = _mk_identity("bob", "10.0.0.2");
    process_t *proc = _mk_process(me);
    _add_peer(proc, bob);
    uint8_t *src = _bytes(5000, 8);
    _bob_offers(proc, bob, src, 5000, 1024, "a.bin");
    ck_assert_int_eq(_last_ev()->state, AT_FILE_TOO_LARGE);
    ck_assert_str_eq(_ctl_op(0), "decline");
    _cap_clear();
    _drive(proc, AT_APP_FILE_ACCEPT, _peer_id(bob, ID), NULL);
    ck_assert_uint_eq(cap.n, 0);
    free(src);
    _end();
}
END_TEST_DEFINITION()

DEFINE_TEST(test_a_peer_cannot_drive_our_file_verbs_and_a_cancel_stops_it)
{
    _begin();
    identity_t *me = _mk_identity("me", "10.0.0.1");
    identity_t *bob = _mk_identity("bob", "10.0.0.2");
    process_t *proc = _mk_process(me);
    _add_peer(proc, bob);
    size_t n = 3000;
    uint8_t *src = _bytes(n, 9);
    _bob_offers(proc, bob, src, n, 1024, "a.bin");

    /* Bob accepting his own offer ON OUR NODE (§2.17): refused. */
    _cap_clear();
    _drive(proc, AT_APP_FILE_ACCEPT, _peer_id(bob, ID), bob);
    ck_assert_uint_eq(cap.n, 0);
    ck_assert_uint_eq(cap.n_ev, 0);

    _drive(proc, AT_APP_FILE_ACCEPT, _peer_id(bob, ID), NULL);
    _chunk_from(proc, bob, src, n, 1024, 0);
    /* Bob withdraws mid-transfer: we stop and drop the partial. */
    _drive(proc, "peer_file_ctl", json_pack("{s:s, s:s}", "id", ID, "op", "cancel"), bob);
    ck_assert_int_eq(_last_ev()->state, AT_FILE_CANCELLED);
    ck_assert_uint_eq(_files_in("/.partial"), 0);
    /* And what arrives afterwards is dropped. */
    _cap_clear();
    _chunk_from(proc, bob, src, n, 1024, 1);
    ck_assert_uint_eq(cap.n + cap.n_ev, 0);
    free(src);
    _end();
}
END_TEST_DEFINITION()

RUN_TESTS(FileXferFlow,
          test_the_sender_offers_serves_what_is_asked_and_finishes_on_done,
          test_a_source_changed_after_the_offer_is_not_served,
          test_the_receiver_pulls_verifies_and_places_the_file,
          test_a_chunk_from_anyone_but_the_offerer_is_ignored,
          test_a_corrupt_file_fails_and_leaves_nothing_behind,
          test_a_restart_resumes_from_the_bitmap,
          test_a_blocked_sender_cannot_offer,
          test_an_offer_over_the_cap_cannot_be_accepted,
          test_a_peer_cannot_drive_our_file_verbs_and_a_cancel_stops_it)
