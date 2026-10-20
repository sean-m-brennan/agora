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

/* File sharing in a DM thread, on the identity process. The protocol and its
 * bounds are in file_xfer.h; this is the state machine.
 *
 *   sender                                   receiver
 *   app_file_offer -> peer_file_offer  --->  OFFERED, emitted
 *                                            app_file_accept
 *   ACCEPTED       <-- peer_file_ctl accept  ACCEPTED
 *                  <-- peer_file_req         (a window of chunks asked for)
 *   reads, serves  --> peer_file_chunk ...   writes at its offset, sets a bit,
 *                                            asks for more
 *                                            all bits set: hash, rename
 *   DONE           <-- peer_file_ctl done    DONE, with the path
 *
 * Either side may cancel at any point; the receiver may decline an offer; a
 * failure on either side (the source changed, the hash did not match) is a
 * fail with a reason. A request also counts as an accept, so a lost accept
 * never stalls a transfer.
 *
 * Handlers run on identity's main loop. The lock is still taken, as social's
 * is, and is a leaf: frames and events are collected under it into a batch
 * and sent once it is released. */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "id_file_xfer.h"
#include "file_xfer.h"
#include "social_msg_types.h"
#include "config/configuration.h"
#include "identity/id_proc_priv.h"
#include "identity/identity_priv.h"
#include "network/net_message.h"
#include "processes/processes.h"
#include "utilities/logger.h"
#include "utilities/message.h"
#include "utilities/msg_types_priv.h"

#ifndef O_BINARY
#define O_BINARY 0
#endif

static char ID_FILE_OFFER[] = "peer_file_offer";
static char ID_FILE_CTL[]   = "peer_file_ctl";
static char ID_FILE_REQ[]   = "peer_file_req";
static char ID_FILE_CHUNK[] = "peer_file_chunk";
static char ID_APP_FILE_OFFER[]   = AT_APP_FILE_OFFER;
static char ID_APP_FILE_ACCEPT[]  = AT_APP_FILE_ACCEPT;
static char ID_APP_FILE_DECLINE[] = AT_APP_FILE_DECLINE;
static char ID_APP_FILE_CANCEL[]  = AT_APP_FILE_CANCEL;

/* Progress events at most this often per transfer (seconds). */
#define FX_EMIT_EVERY 0.25
/* Save the receiver's bitmap after this many new chunks. A crash loses at
 * most this many chunks of progress, which are simply fetched again. */
#define FX_MAP_EVERY 64
/* Close a sender's source after this long without a request. */
#define FX_FD_IDLE 60.0

static struct {
    pthread_mutex_t lock;
    bool loaded;
    at_file_xfer_t *x[AT_FILE_RECORDS_MAX];
    size_t n;
    /* Frames refused or dropped (blocked, unknown transfer, malformed). Only
     * logged; a counter so a flood is visible without a line per frame. */
    unsigned long dropped;
} fx = { .lock = PTHREAD_MUTEX_INITIALIZER };

/* ---- time and settings ---- */

static double _now_mono(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static double _now_wall(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static long long _env_ll(const char *name, long long dflt, long long lo, long long hi)
{
    const char *s = getenv(name);
    if (s == NULL || s[0] == '\0')
        return dflt;
    char *end = NULL;
    long long v = strtoll(s, &end, 10);
    if (end == s || v < lo || v > hi)
        return dflt;
    return v;
}

static uint32_t _chunk_size(void)
{
    return (uint32_t)_env_ll("AT_FILE_CHUNK", AT_FILE_CHUNK_DEFAULT,
                             AT_FILE_CHUNK_MIN, AT_FILE_CHUNK_MAX);
}

static uint32_t _window(void)
{
    return (uint32_t)_env_ll("AT_FILE_WINDOW", AT_FILE_WINDOW_DEFAULT, 1,
                             AT_FILE_WINDOW_MAX);
}

static int64_t _max_bytes(void)
{
    return (int64_t)_env_ll("AT_FILE_MAX_BYTES", AT_FILE_MAX_BYTES_DEFAULT, 0,
                            AT_FILE_MAX_BYTES_DEFAULT * 64);
}

/* ---- the batch: what a handler sends, collected under the lock ---- */

#define FX_OUT_MAX (AT_FILE_REQ_MAX + 8)
#define FX_EV_MAX  4

typedef struct {
    uuid_t peer;
    struct {
        const char *verb;
        json_t *body;
    } out[FX_OUT_MAX];
    size_t n_out;
    peer_file_msg_t ev[FX_EV_MAX];
    size_t n_ev;
} fx_batch_t;

static void _out(fx_batch_t *b, const char *verb, json_t *body)
{
    if (body == NULL)
        return;
    if (b->n_out >= FX_OUT_MAX) {
        json_decref(body);
        return;
    }
    b->out[b->n_out].verb = verb;
    b->out[b->n_out].body = body;
    b->n_out++;
}

static void _ctl(fx_batch_t *b, const char *id, int op, const char *reason)
{
    _out(b, ID_FILE_CTL, at_file_ctl_to_json(id, op, reason));
}

/* Queue an event describing @p x as it stands. */
static void _ev(fx_batch_t *b, const at_file_xfer_t *x)
{
    if (b->n_ev >= FX_EV_MAX)
        return;
    peer_file_msg_t *e = &b->ev[b->n_ev++];
    memset(e, 0, sizeof(*e));
    memcpy(e->peer_uuid, x->peer, sizeof(uuid_t));
    memcpy(e->xfer_id, x->id, sizeof(e->xfer_id));
    e->state = x->state;
    e->outgoing = x->outgoing ? 1 : 0;
    e->size = x->size;
    e->bytes_done = at_file_xfer_bytes_done(x);
    e->ts = _now_wall();
    snprintf(e->name, sizeof(e->name), "%s", x->name);
    snprintf(e->reason, sizeof(e->reason), "%s", x->reason);
    snprintf(e->path, sizeof(e->path), "%s", x->path);
}

/* A progress event, throttled; a state change always goes through _ev. */
static void _ev_progress(fx_batch_t *b, at_file_xfer_t *x, double now)
{
    if (now - x->last_emit < FX_EMIT_EVERY)
        return;
    x->last_emit = now;
    _ev(b, x);
}

/* One directed, encrypted frame to @p peer. */
static int _send_peer(const process_t *proc, const public_identity_t *peer,
                      const char *verb, json_t *body)
{
    generic_msg_t out = {0};
    out.type = NET_MESSAGE;
    strncpy(out.info.net_msg.process, "identity", PROC_NAME_LEN);
    out.info.net_msg.function = (char *)verb;
    out.info.net_msg.encrypt = true;
    memcpy(&out.info.net_msg.to_whom, peer, sizeof(public_identity_t));
    strncpy(out.info.net_msg.return_to, "identity", PROC_NAME_LEN);
    if (net_msg_pack_json(&out.info.net_msg, body) != 0)
        return -1;
    int rc = identity_send_to_network(proc, &out, "a file transfer frame",
                                      peer->nickname);
    net_msg_free_obj(&out.info.net_msg);
    return rc;
}

static void _flush(const process_t *proc, fx_batch_t *b)
{
    if (b->n_out > 0) {
        public_identity_t pub;
        bool known = proc != NULL && identity_find_peer_pub(proc, b->peer, &pub);
        if (!known && proc != NULL) {
            char peer_str[UUID_STRING_LEN + 1];
            uuid_unparse_lower(b->peer, peer_str);
            log_info(proc->logger,
                     "Identity: file transfer: %s is not an admitted peer; "
                     "%zu frame(s) not sent\n", peer_str, b->n_out);
        }
        for (size_t i = 0; i < b->n_out; i++) {
            if (known)
                _send_peer(proc, &pub, b->out[i].verb, b->out[i].body);
            json_decref(b->out[i].body);
        }
        b->n_out = 0;
    }
    for (size_t i = 0; i < b->n_ev; i++) {
        generic_msg_t msg = {0};
        msg.type = PEER_FILE_OBSERVED;
        msg.size = sizeof(peer_file_msg_t);
        memcpy(AT_MSG_EXT(&msg, peer_file_msg_t), &b->ev[i], sizeof(peer_file_msg_t));
        social_emit(&msg, "a file transfer");
    }
    b->n_ev = 0;
}

static fx_batch_t *_batch(const uuid_t peer)
{
    fx_batch_t *b = calloc(1, sizeof(*b));
    if (b != NULL && peer != NULL)
        memcpy(b->peer, peer, sizeof(uuid_t));
    return b;
}

static void _batch_done(const process_t *proc, fx_batch_t *b)
{
    if (b == NULL)
        return;
    _flush(proc, b);
    free(b);
}

/* ---- the store (lock held) ---- */

static at_file_xfer_t *_find(const uuid_t peer, const char *id, bool outgoing)
{
    for (size_t i = 0; i < fx.n; i++) {
        at_file_xfer_t *x = fx.x[i];
        if (x->outgoing == outgoing && uuid_compare(x->peer, peer) == 0
            && strcmp(x->id, id) == 0)
            return x;
    }
    return NULL;
}

static void _persist(const process_t *proc)
{
    char cfg_dir[CFG_PATH_LEN + 1];
    if (get_cfg_dir(cfg_dir, sizeof(cfg_dir)) <= 0)
        return;
    if (at_file_store_save(cfg_dir, fx.x, fx.n) != 0 && proc != NULL)
        log_warn(proc->logger, "Identity: could not save %s/%s\n", cfg_dir,
                 AT_FILE_STORE_FILENAME);
}

static void _remove_at(size_t i)
{
    at_file_xfer_release(fx.x[i]);
    free(fx.x[i]);
    fx.x[i] = fx.x[--fx.n];
}

/* Room for one more record: drop the oldest tombstone if the store is full.
 * A live transfer is never evicted. */
static bool _make_room(void)
{
    if (fx.n < AT_FILE_RECORDS_MAX)
        return true;
    size_t oldest = fx.n;
    for (size_t i = 0; i < fx.n; i++)
        if (at_file_state_terminal(fx.x[i]->state)
            && (oldest == fx.n || fx.x[i]->updated < fx.x[oldest]->updated))
            oldest = i;
    if (oldest == fx.n)
        return false;
    _remove_at(oldest);
    return true;
}

static at_file_xfer_t *_add(void)
{
    if (!_make_room())
        return NULL;
    at_file_xfer_t *x = malloc(sizeof(*x));
    if (x == NULL)
        return NULL;
    at_file_xfer_init(x);
    x->created = x->updated = _now_wall();
    fx.x[fx.n++] = x;
    return x;
}

static void _unlink_partial(const at_file_xfer_t *x)
{
    char p[AT_FILE_PATH_MAX + 1];
    if (at_file_part_path(x, p, sizeof(p)) == 0)
        unlink(p);
    if (at_file_map_path(x, p, sizeof(p)) == 0)
        unlink(p);
}

/* Move @p x to a terminal @p state, releasing what it holds. An incoming
 * transfer that did not finish leaves no partial file behind. */
static void _end(at_file_xfer_t *x, int state, const char *reason)
{
    if (x->fd >= 0)
        close(x->fd);
    x->fd = -1;
    x->n_out = 0;
    if (!x->outgoing && state != AT_FILE_DONE)
        _unlink_partial(x);
    x->state = state;
    snprintf(x->reason, sizeof(x->reason), "%s", reason != NULL ? reason : "");
    x->updated = _now_wall();
}

/* ---- the receiver (lock held) ---- */

static bool _outstanding(const at_file_xfer_t *x, uint32_t idx)
{
    for (uint32_t k = 0; k < x->n_out; k++)
        if (x->out_idx[k] == idx)
            return true;
    return false;
}

static void _drop_outstanding(at_file_xfer_t *x, uint32_t idx)
{
    for (uint32_t k = 0; k < x->n_out; k++)
        if (x->out_idx[k] == idx) {
            x->n_out--;
            x->out_idx[k] = x->out_idx[x->n_out];
            x->out_at[k] = x->out_at[x->n_out];
            return;
        }
}

static int _cmp_u32(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return x < y ? -1 : x > y;
}

/* Ask again for what timed out, and keep the window full. The window is
 * refilled once it has drained to half, so requests go out in runs rather
 * than one frame per chunk; @p force refills it whatever its level. */
static void _rx_top_up(at_file_xfer_t *x, double now, fx_batch_t *b, bool force)
{
    uint32_t want[AT_FILE_WINDOW_MAX];
    uint32_t n_want = 0;
    for (uint32_t k = 0; k < x->n_out; k++)
        if (now - x->out_at[k] >= AT_FILE_REQ_TIMEOUT) {
            want[n_want++] = x->out_idx[k];
            x->out_at[k] = now;
        }
    uint32_t w = _window();
    if (force || n_want > 0 || x->n_out <= w / 2) {
        bool wrapped = false;
        while (x->n_out < w) {
            uint32_t idx = at_file_bitmap_next_clear(&x->bm, x->cursor);
            if (idx >= x->total) {
                if (wrapped || x->cursor == 0)
                    break;
                wrapped = true;
                x->cursor = 0;
                continue;
            }
            x->cursor = idx + 1;
            if (_outstanding(x, idx))
                continue;
            x->out_idx[x->n_out] = idx;
            x->out_at[x->n_out] = now;
            x->n_out++;
            want[n_want++] = idx;
        }
    }
    if (n_want == 0)
        return;
    qsort(want, n_want, sizeof(want[0]), _cmp_u32);
    for (uint32_t i = 0; i < n_want;) {
        uint32_t j = i + 1;
        while (j < n_want && want[j] == want[j - 1] + 1 && j - i < AT_FILE_REQ_MAX)
            j++;
        _out(b, ID_FILE_REQ, at_file_req_to_json(x->id, want[i], j - i));
        i = j;
    }
}

static int _rx_open(const process_t *proc, at_file_xfer_t *x)
{
    if (x->fd >= 0)
        return 0;
    char part[AT_FILE_PATH_MAX + 1];
    if (at_file_part_path(x, part, sizeof(part)) != 0)
        return -1;
    char dir[AT_FILE_PATH_MAX + 1];
    snprintf(dir, sizeof(dir), "%s", part);
    char *slash = strrchr(dir, '/');
    if (slash != NULL)
        *slash = '\0';
    if (at_file_mkdirs(dir) != 0) {
        log_warn(proc->logger, "Identity: file transfer: cannot create %s\n", dir);
        return -1;
    }
    x->fd = open(part, O_RDWR | O_CREAT | O_BINARY, 0600);
    if (x->fd < 0) {
        log_warn(proc->logger, "Identity: file transfer: cannot open %s\n", part);
        return -1;
    }
    return 0;
}

static void _rx_save_map(at_file_xfer_t *x)
{
    char map[AT_FILE_PATH_MAX + 1];
    if (at_file_map_path(x, map, sizeof(map)) == 0)
        at_file_bitmap_save(&x->bm, map);
    x->unsaved = 0;
}

/* Every chunk is held: verify the whole file and put it in place. */
static void _rx_finish(const process_t *proc, at_file_xfer_t *x, fx_batch_t *b)
{
    if (x->fd >= 0)
        close(x->fd);
    x->fd = -1;
    x->n_out = 0;
    char part[AT_FILE_PATH_MAX + 1];
    char hash[AT_FILE_HASH_HEX_LEN + 1];
    if (at_file_part_path(x, part, sizeof(part)) != 0) {
        _end(x, AT_FILE_FAILED, "no_path");
        _ctl(b, x->id, AT_FILE_OP_FAIL, x->reason);
        _ev(b, x);
        return;
    }
    if (x->total == 0) {
        /* An empty file: nothing was pulled, so make the part now. */
        int fd = open(part, O_WRONLY | O_CREAT | O_TRUNC | O_BINARY, 0600);
        if (fd >= 0)
            close(fd);
    }
    if (at_file_hash(part, x->size, hash) != 0 || strcmp(hash, x->hash) != 0) {
        log_warn(proc->logger,
                 "Identity: file transfer %s: the received file does not match "
                 "the offered hash; discarded\n", x->id);
        _end(x, AT_FILE_FAILED, "hash_mismatch");
        _ctl(b, x->id, AT_FILE_OP_FAIL, x->reason);
        _ev(b, x);
        return;
    }
    char dir[AT_FILE_PATH_MAX + 1];
    char final[AT_FILE_PATH_MAX + 1];
    if (at_file_files_dir(dir, sizeof(dir)) != 0
        || at_file_unique_path(dir, x->name, final, sizeof(final)) != 0
        || rename(part, final) != 0) {
        _end(x, AT_FILE_FAILED, "cannot_place");
        _ctl(b, x->id, AT_FILE_OP_FAIL, x->reason);
        _ev(b, x);
        return;
    }
    char map[AT_FILE_PATH_MAX + 1];
    if (at_file_map_path(x, map, sizeof(map)) == 0)
        unlink(map);
    snprintf(x->path, sizeof(x->path), "%s", final);
    _end(x, AT_FILE_DONE, NULL);
    log_info(proc->logger, "Identity: file transfer %s done: %s (%lld bytes)\n",
             x->id, final, (long long)x->size);
    _ctl(b, x->id, AT_FILE_OP_DONE, NULL);
    _ev(b, x);
}

/* Start, or resume, pulling. */
static void _rx_begin(const process_t *proc, at_file_xfer_t *x, fx_batch_t *b)
{
    if (x->bm.bits == NULL) {
        char map[AT_FILE_PATH_MAX + 1];
        if (at_file_map_path(x, map, sizeof(map)) != 0
            || at_file_bitmap_load(&x->bm, x->total, map) != 0) {
            _end(x, AT_FILE_FAILED, "no_memory");
            _ctl(b, x->id, AT_FILE_OP_FAIL, x->reason);
            _ev(b, x);
            return;
        }
    }
    if (_rx_open(proc, x) != 0) {
        _end(x, AT_FILE_FAILED, "cannot_write");
        _ctl(b, x->id, AT_FILE_OP_FAIL, x->reason);
        _ev(b, x);
        return;
    }
    if (x->bm.count >= x->total) {
        _rx_finish(proc, x, b);
        return;
    }
    x->cursor = 0;
    x->n_out = 0;
    x->last_rx = _now_mono();
    _rx_top_up(x, x->last_rx, b, true);
}

/* ---- the sender (lock held) ---- */

static bool _source_unchanged(const at_file_xfer_t *x)
{
    struct stat st;
    return stat(x->path, &st) == 0 && S_ISREG(st.st_mode)
        && (int64_t)st.st_size == x->size && (int64_t)st.st_mtime == x->mtime;
}

static int _read_full(int fd, int64_t off, uint8_t *buf, size_t len)
{
    if (lseek(fd, (off_t)off, SEEK_SET) != (off_t)off)
        return -1;
    size_t got = 0;
    while (got < len) {
        ssize_t r = read(fd, buf + got, len - got);
        if (r <= 0)
            return -1;
        got += (size_t)r;
    }
    return 0;
}

static int _write_full(int fd, int64_t off, const uint8_t *buf, size_t len)
{
    if (lseek(fd, (off_t)off, SEEK_SET) != (off_t)off)
        return -1;
    size_t put = 0;
    while (put < len) {
        ssize_t w = write(fd, buf + put, len - put);
        if (w <= 0)
            return -1;
        put += (size_t)w;
    }
    return 0;
}

/* ---- app verbs ---- */

/* {"peer","id"} common to all four. Returns the parsed payload (caller
 * decrefs) or NULL, having logged why. */
static json_t *_app_args(const process_t *proc, generic_msg_t *msg, const char *verb,
                         uuid_t peer_out, char id_out[AT_FILE_ID_HEX_LEN + 1])
{
    net_msg_t *nmsg = &msg->info.net_msg;
    json_t *payload = NULL;
    if (net_msg_unpack_json(nmsg, &payload) != 0 || payload == NULL)
        return NULL;
    const char *peer = json_string_value(json_object_get(payload, "peer"));
    const char *id = json_string_value(json_object_get(payload, "id"));
    if (peer == NULL || uuid_parse(peer, peer_out) != 0 || !at_file_id_ok(id)) {
        log_warn(proc->logger, "Identity: app %s: bad peer or id\n", verb);
        json_decref(payload);
        return NULL;
    }
    memcpy(id_out, id, AT_FILE_ID_HEX_LEN + 1);
    return payload;
}

static bool handle_app_file_offer(const process_t *proc, directory_t *queues,
                                  generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    if (!identity_is_local_app_verb(proc, nmsg))
        return identity_refuse_remote_app_verb(proc, nmsg, AT_APP_FILE_OFFER);
    uuid_t peer;
    char id[AT_FILE_ID_HEX_LEN + 1];
    json_t *payload = _app_args(proc, msg, AT_APP_FILE_OFFER, peer, id);
    if (payload == NULL)
        return true;
    char path[AT_FILE_PATH_MAX + 1];
    const char *p = json_string_value(json_object_get(payload, "path"));
    snprintf(path, sizeof(path), "%s", p != NULL ? p : "");
    json_decref(payload);

    fx_batch_t *b = _batch(peer);
    if (b == NULL)
        return true;
    /* The same refusal as a DM: we do not write to someone we blocked. */
    if (social_peer_is_blocked(peer)) {
        log_info(proc->logger, "Identity: app file offer refused: peer is blocked\n");
        free(b);
        return true;
    }

    /* Stat and hash before taking the lock: hashing a large file takes a
     * moment, and nothing else needs to wait for it. */
    at_file_xfer_t tmp;
    at_file_xfer_init(&tmp);
    memcpy(tmp.id, id, sizeof(tmp.id));
    memcpy(tmp.peer, peer, sizeof(uuid_t));
    tmp.outgoing = true;
    snprintf(tmp.path, sizeof(tmp.path), "%s", path);
    at_file_sanitize_name(path, tmp.name, sizeof(tmp.name));
    tmp.chunk = _chunk_size();
    struct stat st;
    const char *why = NULL;
    if (path[0] == '\0' || stat(path, &st) != 0 || !S_ISREG(st.st_mode))
        why = "unreadable";
    else {
        tmp.size = (int64_t)st.st_size;
        tmp.mtime = (int64_t)st.st_mtime;
        tmp.total = at_file_total_chunks(tmp.size, tmp.chunk);
        if (tmp.size > (int64_t)tmp.chunk * UINT32_MAX)
            why = "too_large";
        else if (at_file_hash(path, tmp.size, tmp.hash) != 0)
            why = "unreadable";
    }

    pthread_mutex_lock(&fx.lock);
    at_file_xfer_t *x = _find(peer, id, true);
    if (x != NULL) {
        /* The same offer twice (a double drop, a retried call): one transfer. */
        pthread_mutex_unlock(&fx.lock);
        free(b);
        return true;
    }
    if (why != NULL) {
        tmp.state = AT_FILE_FAILED;
        snprintf(tmp.reason, sizeof(tmp.reason), "%s", why);
        _ev(b, &tmp);
        pthread_mutex_unlock(&fx.lock);
        log_info(proc->logger, "Identity: app file offer %s: %s (%s)\n", id, why, path);
        _batch_done(proc, b);
        return true;
    }
    x = _add();
    if (x == NULL) {
        tmp.state = AT_FILE_FAILED;
        snprintf(tmp.reason, sizeof(tmp.reason), "too_many");
        _ev(b, &tmp);
        pthread_mutex_unlock(&fx.lock);
        _batch_done(proc, b);
        return true;
    }
    double created = x->created;
    *x = tmp;
    x->created = x->updated = created;
    x->state = AT_FILE_OFFERED;
    at_file_bitmap_init(&x->bm, x->total);
    at_file_offer_t offer = {0};
    memcpy(offer.id, x->id, sizeof(offer.id));
    memcpy(offer.name, x->name, sizeof(offer.name));
    offer.size = x->size;
    offer.chunk = x->chunk;
    offer.total = x->total;
    memcpy(offer.hash, x->hash, sizeof(offer.hash));
    offer.ts = x->created;
    _out(b, ID_FILE_OFFER, at_file_offer_to_json(&offer));
    _ev(b, x);
    _persist(proc);
    pthread_mutex_unlock(&fx.lock);
    char peer_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer, peer_str);
    log_info(proc->logger, "Identity: file offer %s to %s: %s (%lld bytes)\n",
             id, peer_str, tmp.name, (long long)tmp.size);
    _batch_done(proc, b);
    return true;
}

static bool handle_app_file_accept(const process_t *proc, directory_t *queues,
                                   generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    if (!identity_is_local_app_verb(proc, nmsg))
        return identity_refuse_remote_app_verb(proc, nmsg, AT_APP_FILE_ACCEPT);
    uuid_t peer;
    char id[AT_FILE_ID_HEX_LEN + 1];
    json_t *payload = _app_args(proc, msg, AT_APP_FILE_ACCEPT, peer, id);
    if (payload == NULL)
        return true;
    json_decref(payload);
    fx_batch_t *b = _batch(peer);
    if (b == NULL)
        return true;
    pthread_mutex_lock(&fx.lock);
    at_file_xfer_t *x = _find(peer, id, false);
    if (x == NULL) {
        log_info(proc->logger, "Identity: app file accept: no offer %s\n", id);
    } else if (x->state == AT_FILE_OFFERED) {
        x->state = AT_FILE_ACCEPTED;
        x->updated = _now_wall();
        _ctl(b, x->id, AT_FILE_OP_ACCEPT, NULL);
        _ev(b, x);
        _rx_begin(proc, x, b);
        _persist(proc);
        log_info(proc->logger, "Identity: file %s accepted: %s (%lld bytes)\n",
                 id, x->name, (long long)x->size);
    } else if (x->state == AT_FILE_ACCEPTED) {
        /* Accepting again is a nudge: ask for whatever is missing now. */
        _rx_top_up(x, _now_mono(), b, true);
    }
    pthread_mutex_unlock(&fx.lock);
    _batch_done(proc, b);
    return true;
}

static bool handle_app_file_decline(const process_t *proc, directory_t *queues,
                                    generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    if (!identity_is_local_app_verb(proc, nmsg))
        return identity_refuse_remote_app_verb(proc, nmsg, AT_APP_FILE_DECLINE);
    uuid_t peer;
    char id[AT_FILE_ID_HEX_LEN + 1];
    json_t *payload = _app_args(proc, msg, AT_APP_FILE_DECLINE, peer, id);
    if (payload == NULL)
        return true;
    json_decref(payload);
    fx_batch_t *b = _batch(peer);
    if (b == NULL)
        return true;
    pthread_mutex_lock(&fx.lock);
    at_file_xfer_t *x = _find(peer, id, false);
    if (x != NULL && x->state == AT_FILE_OFFERED) {
        _end(x, AT_FILE_DECLINED, NULL);
        _ctl(b, x->id, AT_FILE_OP_DECLINE, NULL);
        _ev(b, x);
        _persist(proc);
    }
    pthread_mutex_unlock(&fx.lock);
    _batch_done(proc, b);
    return true;
}

static bool handle_app_file_cancel(const process_t *proc, directory_t *queues,
                                   generic_msg_t *msg)
{
    (void)queues;
    net_msg_t *nmsg = &msg->info.net_msg;
    if (!identity_is_local_app_verb(proc, nmsg))
        return identity_refuse_remote_app_verb(proc, nmsg, AT_APP_FILE_CANCEL);
    uuid_t peer;
    char id[AT_FILE_ID_HEX_LEN + 1];
    json_t *payload = _app_args(proc, msg, AT_APP_FILE_CANCEL, peer, id);
    if (payload == NULL)
        return true;
    json_decref(payload);
    fx_batch_t *b = _batch(peer);
    if (b == NULL)
        return true;
    pthread_mutex_lock(&fx.lock);
    /* Either direction: the app names a transfer, not a role. */
    at_file_xfer_t *xs[2] = { _find(peer, id, true), _find(peer, id, false) };
    bool any = false;
    for (int i = 0; i < 2; i++) {
        at_file_xfer_t *x = xs[i];
        if (x == NULL || at_file_state_terminal(x->state))
            continue;
        _end(x, AT_FILE_CANCELLED, NULL);
        _ctl(b, x->id, AT_FILE_OP_CANCEL, NULL);
        _ev(b, x);
        any = true;
    }
    if (any)
        _persist(proc);
    pthread_mutex_unlock(&fx.lock);
    _batch_done(proc, b);
    return true;
}

/* ---- peer verbs ---- */

/* The sender of a wire frame, or false (and counted) if it may not reach us:
 * unauthenticated, or blocked. */
static bool _wire_sender(const process_t *proc, generic_msg_t *msg, const char *verb,
                         uuid_t out)
{
    net_msg_t *nmsg = &msg->info.net_msg;
    if (uuid_is_null(nmsg->from_whom.uuid))
        return false;
    memcpy(out, nmsg->from_whom.uuid, sizeof(uuid_t));
    /* A blocked peer cannot reach us, with files as with DMs. */
    if (social_peer_is_blocked(out)) {
        pthread_mutex_lock(&fx.lock);
        fx.dropped++;
        pthread_mutex_unlock(&fx.lock);
        char s[UUID_STRING_LEN + 1];
        uuid_unparse_lower(out, s);
        log_debug(proc->logger, "Identity: %s from %s dropped (locally blocked)\n",
                  verb, s);
        return false;
    }
    return true;
}

static bool handle_file_offer(const process_t *proc, directory_t *queues,
                              generic_msg_t *msg)
{
    (void)queues;
    uuid_t from;
    if (!_wire_sender(proc, msg, ID_FILE_OFFER, from))
        return true;
    json_t *payload = NULL;
    at_file_offer_t offer;
    if (net_msg_unpack_json(&msg->info.net_msg, &payload) != 0
        || at_file_offer_from_json(payload, &offer) != 0) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: peer_file_offer malformed, refusing\n");
        return true;
    }
    json_decref(payload);
    double now = _now_wall();
    if (offer.ts < now - AT_FILE_RECORD_TTL) {
        log_debug(proc->logger, "Identity: peer_file_offer %s expired\n", offer.id);
        return true;
    }
    fx_batch_t *b = _batch(from);
    if (b == NULL)
        return true;
    pthread_mutex_lock(&fx.lock);
    if (_find(from, offer.id, false) != NULL) {
        /* Known, live or tombstoned: a retry or a replay changes nothing. */
        pthread_mutex_unlock(&fx.lock);
        free(b);
        return true;
    }
    at_file_xfer_t *x = _add();
    if (x == NULL) {
        fx.dropped++;
        _ctl(b, offer.id, AT_FILE_OP_DECLINE, "busy");
        pthread_mutex_unlock(&fx.lock);
        log_warn(proc->logger, "Identity: file offer %s refused: %d transfers held\n",
                 offer.id, AT_FILE_RECORDS_MAX);
        _batch_done(proc, b);
        return true;
    }
    memcpy(x->id, offer.id, sizeof(x->id));
    memcpy(x->peer, from, sizeof(uuid_t));
    x->outgoing = false;
    memcpy(x->name, offer.name, sizeof(x->name));
    x->size = offer.size;
    x->chunk = offer.chunk;
    x->total = offer.total;
    memcpy(x->hash, offer.hash, sizeof(x->hash));
    if (offer.size > _max_bytes()) {
        /* Shown, so the person knows something was offered, but with no way
         * to accept it; the sender is told at once. */
        _end(x, AT_FILE_TOO_LARGE, "too_large");
        _ctl(b, x->id, AT_FILE_OP_DECLINE, "too_large");
    } else {
        x->state = AT_FILE_OFFERED;
    }
    _ev(b, x);
    _persist(proc);
    pthread_mutex_unlock(&fx.lock);
    char s[UUID_STRING_LEN + 1];
    uuid_unparse_lower(from, s);
    log_info(proc->logger, "Identity: file offer %s from %s: %s (%lld bytes)\n",
             offer.id, s, offer.name, (long long)offer.size);
    _batch_done(proc, b);
    return true;
}

static bool handle_file_ctl(const process_t *proc, directory_t *queues,
                            generic_msg_t *msg)
{
    (void)queues;
    uuid_t from;
    if (!_wire_sender(proc, msg, ID_FILE_CTL, from))
        return true;
    json_t *payload = NULL;
    char id[AT_FILE_ID_HEX_LEN + 1];
    char reason[AT_FILE_REASON_MAX + 1];
    int op = -1;
    if (net_msg_unpack_json(&msg->info.net_msg, &payload) != 0
        || at_file_ctl_from_json(payload, id, &op, reason) != 0) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: peer_file_ctl malformed, refusing\n");
        return true;
    }
    json_decref(payload);
    fx_batch_t *b = _batch(from);
    if (b == NULL)
        return true;
    pthread_mutex_lock(&fx.lock);
    bool changed = false;
    if (op == AT_FILE_OP_ACCEPT || op == AT_FILE_OP_DECLINE || op == AT_FILE_OP_DONE) {
        /* Answers to OUR offer. */
        at_file_xfer_t *x = _find(from, id, true);
        if (x == NULL) {
            fx.dropped++;
        } else if (op == AT_FILE_OP_ACCEPT) {
            if (x->state == AT_FILE_OFFERED) {
                x->state = AT_FILE_ACCEPTED;
                x->updated = _now_wall();
                x->last_rx = _now_mono();
                _ev(b, x);
                changed = true;
            } else if (x->state == AT_FILE_CANCELLED || x->state == AT_FILE_FAILED) {
                /* We gave up first; say so again, the earlier word was lost. */
                _ctl(b, x->id, x->state == AT_FILE_CANCELLED ? AT_FILE_OP_CANCEL
                                                             : AT_FILE_OP_FAIL,
                     x->reason);
            }
        } else if (op == AT_FILE_OP_DECLINE) {
            if (x->state == AT_FILE_OFFERED || x->state == AT_FILE_ACCEPTED) {
                _end(x, AT_FILE_DECLINED, reason);
                _ev(b, x);
                changed = true;
            }
        } else if (!at_file_state_terminal(x->state)) {   /* DONE */
            _end(x, AT_FILE_DONE, NULL);
            _ev(b, x);
            changed = true;
        }
    } else {
        /* cancel / fail: either direction. */
        int state = op == AT_FILE_OP_CANCEL ? AT_FILE_CANCELLED : AT_FILE_FAILED;
        at_file_xfer_t *xs[2] = { _find(from, id, false), _find(from, id, true) };
        for (int i = 0; i < 2; i++) {
            at_file_xfer_t *x = xs[i];
            if (x == NULL || at_file_state_terminal(x->state))
                continue;
            _end(x, state, reason[0] != '\0' ? reason
                                             : (state == AT_FILE_CANCELLED ? "" : "peer"));
            _ev(b, x);
            changed = true;
        }
    }
    if (changed)
        _persist(proc);
    pthread_mutex_unlock(&fx.lock);
    if (changed)
        log_info(proc->logger, "Identity: file transfer %s: peer sent %s\n", id,
                 at_file_op_name(op));
    _batch_done(proc, b);
    return true;
}

static bool handle_file_req(const process_t *proc, directory_t *queues,
                            generic_msg_t *msg)
{
    (void)queues;
    uuid_t from;
    if (!_wire_sender(proc, msg, ID_FILE_REQ, from))
        return true;
    json_t *payload = NULL;
    char id[AT_FILE_ID_HEX_LEN + 1];
    uint32_t first = 0, count = 0;
    if (net_msg_unpack_json(&msg->info.net_msg, &payload) != 0
        || at_file_req_from_json(payload, id, &first, &count) != 0) {
        json_decref(payload);
        log_warn(proc->logger, "Identity: peer_file_req malformed, refusing\n");
        return true;
    }
    json_decref(payload);
    fx_batch_t *b = _batch(from);
    if (b == NULL)
        return true;
    uint8_t *buf = NULL;
    pthread_mutex_lock(&fx.lock);
    at_file_xfer_t *x = _find(from, id, true);
    double now = _now_mono();
    bool changed = false;
    if (x == NULL) {
        /* Not ours (a restart lost it, or it was never offered): stop them. */
        fx.dropped++;
        _ctl(b, id, AT_FILE_OP_FAIL, "unknown");
        goto out;
    }
    if (at_file_state_terminal(x->state)) {
        if (x->state != AT_FILE_DONE)
            _ctl(b, id, x->state == AT_FILE_CANCELLED ? AT_FILE_OP_CANCEL
                                                      : AT_FILE_OP_FAIL, x->reason);
        goto out;
    }
    if ((uint64_t)first + count > x->total) {
        fx.dropped++;
        goto out;
    }
    if (x->state == AT_FILE_OFFERED) {
        /* A request is an accept whose own frame we did not see. */
        x->state = AT_FILE_ACCEPTED;
        x->updated = _now_wall();
        _ev(b, x);
        changed = true;
    }
    if (!_source_unchanged(x)) {
        log_warn(proc->logger,
                 "Identity: file transfer %s: %s changed since it was offered; "
                 "stopping\n", id, x->path);
        _end(x, AT_FILE_FAILED, "source_changed");
        _ctl(b, id, AT_FILE_OP_FAIL, x->reason);
        _ev(b, x);
        changed = true;
        goto out;
    }
    if (x->fd < 0)
        x->fd = open(x->path, O_RDONLY | O_BINARY);
    buf = malloc(x->chunk);
    if (x->fd < 0 || buf == NULL) {
        _end(x, AT_FILE_FAILED, "unreadable");
        _ctl(b, id, AT_FILE_OP_FAIL, x->reason);
        _ev(b, x);
        changed = true;
        goto out;
    }
    if (x->bm.bits == NULL)
        at_file_bitmap_init(&x->bm, x->total);
    for (uint32_t i = first; i < first + count; i++) {
        uint32_t len = at_file_chunk_len(x->size, x->chunk, i);
        if (_read_full(x->fd, (int64_t)i * x->chunk, buf, len) != 0) {
            _end(x, AT_FILE_FAILED, "unreadable");
            _ctl(b, id, AT_FILE_OP_FAIL, x->reason);
            _ev(b, x);
            changed = true;
            goto out;
        }
        _out(b, ID_FILE_CHUNK, at_file_chunk_to_json(id, i, buf, len));
        at_file_bitmap_set(&x->bm, i);
    }
    x->last_rx = now;
    _ev_progress(b, x, now);
out:
    if (changed)
        _persist(proc);
    pthread_mutex_unlock(&fx.lock);
    free(buf);
    _batch_done(proc, b);
    return true;
}

static bool handle_file_chunk(const process_t *proc, directory_t *queues,
                              generic_msg_t *msg)
{
    (void)queues;
    uuid_t from;
    if (!_wire_sender(proc, msg, ID_FILE_CHUNK, from))
        return true;
    json_t *payload = NULL;
    char id[AT_FILE_ID_HEX_LEN + 1];
    uint32_t idx = 0;
    size_t len = 0;
    uint8_t *buf = malloc(AT_FILE_CHUNK_MAX);
    if (buf == NULL)
        return true;
    if (net_msg_unpack_json(&msg->info.net_msg, &payload) != 0
        || at_file_chunk_from_json(payload, id, &idx, buf, AT_FILE_CHUNK_MAX, &len) != 0) {
        json_decref(payload);
        free(buf);
        log_warn(proc->logger, "Identity: peer_file_chunk malformed, refusing\n");
        return true;
    }
    json_decref(payload);
    fx_batch_t *b = _batch(from);
    if (b == NULL) {
        free(buf);
        return true;
    }
    pthread_mutex_lock(&fx.lock);
    /* Only for a transfer THIS node accepted, from the peer that offered it:
     * the key is (sender, id), so nobody else can write into it. */
    at_file_xfer_t *x = _find(from, id, false);
    double now = _now_mono();
    if (x == NULL || x->state != AT_FILE_ACCEPTED || idx >= x->total
        || len != at_file_chunk_len(x->size, x->chunk, idx)) {
        fx.dropped++;
        goto out;
    }
    _drop_outstanding(x, idx);
    x->last_rx = now;
    if (!at_file_bitmap_get(&x->bm, idx)) {
        if (_rx_open(proc, x) != 0
            || _write_full(x->fd, (int64_t)idx * x->chunk, buf, len) != 0) {
            _end(x, AT_FILE_FAILED, "cannot_write");
            _ctl(b, id, AT_FILE_OP_FAIL, x->reason);
            _ev(b, x);
            _persist(proc);
            goto out;
        }
        at_file_bitmap_set(&x->bm, idx);
        if (++x->unsaved >= FX_MAP_EVERY)
            _rx_save_map(x);
    }
    if (x->bm.count >= x->total) {
        _rx_finish(proc, x, b);
        _persist(proc);
        goto out;
    }
    _rx_top_up(x, now, b, false);
    _ev_progress(b, x, now);
out:
    pthread_mutex_unlock(&fx.lock);
    free(buf);
    _batch_done(proc, b);
    return true;
}

/* ---- lifecycle ---- */

void file_xfer_register_handlers(process_t *proc)
{
    process_register_handler(proc, ID_FILE_OFFER, (handler_ptr_t)handle_file_offer);
    process_register_handler(proc, ID_FILE_CTL,   (handler_ptr_t)handle_file_ctl);
    process_register_handler(proc, ID_FILE_REQ,   (handler_ptr_t)handle_file_req);
    process_register_handler(proc, ID_FILE_CHUNK, (handler_ptr_t)handle_file_chunk);
    process_register_handler(proc, ID_APP_FILE_OFFER,   (handler_ptr_t)handle_app_file_offer);
    process_register_handler(proc, ID_APP_FILE_ACCEPT,  (handler_ptr_t)handle_app_file_accept);
    process_register_handler(proc, ID_APP_FILE_DECLINE, (handler_ptr_t)handle_app_file_decline);
    process_register_handler(proc, ID_APP_FILE_CANCEL,  (handler_ptr_t)handle_app_file_cancel);
}

void file_xfer_run_start(process_t *proc)
{
    char cfg_dir[CFG_PATH_LEN + 1];
    if (get_cfg_dir(cfg_dir, sizeof(cfg_dir)) <= 0)
        return;
    at_file_xfer_t *loaded = calloc(AT_FILE_RECORDS_MAX, sizeof(at_file_xfer_t));
    if (loaded == NULL)
        return;
    int n = at_file_store_load(cfg_dir, loaded, AT_FILE_RECORDS_MAX);
    if (n < 0)
        log_warn(proc->logger, "Identity: %s/%s is malformed; no transfers restored\n",
                 cfg_dir, AT_FILE_STORE_FILENAME);
    pthread_mutex_lock(&fx.lock);
    if (!fx.loaded) {
        fx.loaded = true;
        for (int i = 0; i < n && fx.n < AT_FILE_RECORDS_MAX; i++) {
            at_file_xfer_t *x = malloc(sizeof(*x));
            if (x == NULL)
                break;
            *x = loaded[i];
            x->fd = -1;
            if (!x->outgoing && x->state == AT_FILE_ACCEPTED) {
                /* Resumed by the next sweep, from what the bitmap says is
                 * held; last_rx 0 makes it look stalled, so it is asked at
                 * once. */
                char map[AT_FILE_PATH_MAX + 1];
                if (at_file_map_path(x, map, sizeof(map)) != 0
                    || at_file_bitmap_load(&x->bm, x->total, map) != 0)
                    at_file_bitmap_init(&x->bm, x->total);
            } else if (!at_file_state_terminal(x->state)) {
                at_file_bitmap_init(&x->bm, x->total);
            }
            fx.x[fx.n++] = x;
        }
        if (n > 0)
            log_info(proc->logger, "Identity: restored %d file transfer record(s)\n", n);
    }
    pthread_mutex_unlock(&fx.lock);
    free(loaded);
}

/* The peers of live transfers that we have blocked. Asked outside our lock:
 * the block list is social's, behind social's own. */
static size_t _blocked_live_peers(uuid_t *out, size_t max)
{
    size_t n = 0;
    pthread_mutex_lock(&fx.lock);
    for (size_t i = 0; i < fx.n && n < max; i++)
        if (!at_file_state_terminal(fx.x[i]->state))
            memcpy(out[n++], fx.x[i]->peer, sizeof(uuid_t));
    pthread_mutex_unlock(&fx.lock);
    size_t kept = 0;
    for (size_t i = 0; i < n; i++)
        if (social_peer_is_blocked(out[i]))
            memcpy(out[kept++], out[i], sizeof(uuid_t));
    return kept;
}

static bool _in_set(const uuid_t *set, size_t n, const uuid_t u)
{
    for (size_t i = 0; i < n; i++)
        if (uuid_compare(set[i], u) == 0)
            return true;
    return false;
}

void file_xfer_periodic(const process_t *proc)
{
    double now = _now_mono();
    double wall = _now_wall();
    uuid_t *blocked = calloc(AT_FILE_RECORDS_MAX, sizeof(uuid_t));
    if (blocked == NULL)
        return;
    size_t n_blocked = _blocked_live_peers(blocked, AT_FILE_RECORDS_MAX);
    /* One batch per peer is the batch's shape; a sweep may touch several, so
     * it collects per transfer and flushes as it goes, outside the lock. */
    for (;;) {
        fx_batch_t *b = NULL;
        bool changed = false;
        pthread_mutex_lock(&fx.lock);
        for (size_t i = 0; i < fx.n && b == NULL; i++) {
            at_file_xfer_t *x = fx.x[i];
            if (at_file_state_terminal(x->state)) {
                if (x->fd >= 0) {
                    close(x->fd);
                    x->fd = -1;
                }
                continue;
            }
            if (x->outgoing && x->fd >= 0 && now - x->last_rx > FX_FD_IDLE) {
                close(x->fd);
                x->fd = -1;
            }
            /* Progress since the last save is kept on every sweep, so a crash
             * costs at most a sweep's worth of chunks. */
            if (!x->outgoing && x->unsaved > 0)
                _rx_save_map(x);
            if (_in_set(blocked, n_blocked, x->peer)) {
                /* Blocked mid-transfer: stop, and tell them nothing, as
                 * with everything else a block does. */
                _end(x, AT_FILE_CANCELLED, "blocked");
                b = _batch(x->peer);
                if (b != NULL) _ev(b, x);
                changed = true;
            } else if (x->state == AT_FILE_OFFERED && wall - x->created > AT_FILE_RECORD_TTL) {
                _end(x, AT_FILE_CANCELLED, "expired");
                b = _batch(x->peer);
                if (b != NULL) {
                    _ctl(b, x->id, AT_FILE_OP_CANCEL, x->reason);
                    _ev(b, x);
                }
                changed = true;
            } else if (!x->outgoing && x->state == AT_FILE_ACCEPTED
                       && now - x->last_rx >= AT_FILE_REQ_TIMEOUT
                       && x->bm.bits != NULL) {
                b = _batch(x->peer);
                if (b != NULL) {
                    if (x->fd < 0 && _rx_open(proc, x) != 0) {
                        _end(x, AT_FILE_FAILED, "cannot_write");
                        _ctl(b, x->id, AT_FILE_OP_FAIL, x->reason);
                        _ev(b, x);
                        changed = true;
                    } else {
                        /* Stalled: everything outstanding is presumed lost. */
                        x->n_out = 0;
                        x->cursor = 0;
                        x->last_rx = now;
                        _rx_top_up(x, now, b, true);
                    }
                }
            }
        }
        if (b == NULL) {
            /* Nothing left to do: prune what has been a tombstone too long. */
            bool pruned = false;
            for (size_t i = fx.n; i-- > 0;)
                if (at_file_state_terminal(fx.x[i]->state)
                    && wall - fx.x[i]->updated > AT_FILE_RECORD_TTL) {
                    _remove_at(i);
                    pruned = true;
                }
            if (pruned || changed)
                _persist(proc);
            pthread_mutex_unlock(&fx.lock);
            free(blocked);
            return;
        }
        if (changed)
            _persist(proc);
        pthread_mutex_unlock(&fx.lock);
        _batch_done(proc, b);
    }
}

int file_xfer_replay(const process_t *proc)
{
    int emitted = 0;
    pthread_mutex_lock(&fx.lock);
    size_t n = fx.n;
    pthread_mutex_unlock(&fx.lock);
    for (size_t i = 0; i < n; i++) {
        fx_batch_t *b = _batch(NULL);
        if (b == NULL)
            break;
        pthread_mutex_lock(&fx.lock);
        if (i < fx.n)
            _ev(b, fx.x[i]);
        pthread_mutex_unlock(&fx.lock);
        emitted += (int)b->n_ev;
        _batch_done(proc, b);
    }
    return emitted;
}

void file_xfer_reset(void)
{
    pthread_mutex_lock(&fx.lock);
    while (fx.n > 0)
        _remove_at(fx.n - 1);
    fx.loaded = false;
    fx.dropped = 0;
    pthread_mutex_unlock(&fx.lock);
}

char *file_xfer_dump(void)
{
    json_t *arr = json_array();
    if (arr == NULL)
        return NULL;
    pthread_mutex_lock(&fx.lock);
    for (size_t i = 0; i < fx.n; i++) {
        json_t *j = at_file_xfer_to_json(fx.x[i]);
        if (j == NULL)
            continue;
        json_object_set_new(j, "done", json_integer(at_file_xfer_bytes_done(fx.x[i])));
        json_array_append_new(arr, j);
    }
    pthread_mutex_unlock(&fx.lock);
    char *s = json_dumps(arr, JSON_COMPACT | JSON_SORT_KEYS);
    json_decref(arr);
    return s;
}
