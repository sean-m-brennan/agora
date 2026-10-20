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
 * @file file_xfer.h
 * @brief File sharing in a DM thread: wire forms, bounds, the chunk bitmap and
 *        the persisted transfer records.
 *
 * A file goes 1:1 from a sender to one device of a peer, after the receiver
 * accepts. The receiver PULLS: it asks for runs of chunks, keeps a window of
 * them outstanding, and writes each one at its offset in a `.part` file. A
 * bitmap sidecar records which chunks it holds, so a restart or a partition
 * resumes where it stopped. The whole file's BLAKE2b-256 rides the offer and
 * is checked once at the end. Bytes never cross into the app: the sender's
 * core reads the file at the path the app named, the receiver's core writes
 * it, and the app sees only offer and state events.
 *
 * Four directed, ENCRYPTED peer verbs (none on the plaintext allowlist):
 *
 *   peer_file_offer  {id, name, size, chunk, total, hash, ts}
 *   peer_file_ctl    {id, op, reason?}  op: accept|decline|cancel|done|fail
 *   peer_file_req    {id, first, count}           receiver -> sender
 *   peer_file_chunk  {id, i, data}                sender -> receiver, base64
 *
 * NO FRESHNESS SEQ, unlike a DM. The freshness mark keeps one highest seq per
 * (sender, verb), so a chunk, a retried request or two offers that cross on
 * the wire would be refused as replays. Every message here is instead keyed by
 * (peer, id) and idempotent: a repeated offer for a known id, a chunk already
 * held, a control for a transfer already in that state, all change nothing.
 * A terminal record is kept for AT_FILE_RECORD_TTL as a tombstone so that a
 * replayed offer cannot resurrect it. crypto_box authenticates every frame.
 *
 * Everything here is pure (no process, no locks), so the C handlers
 * (id_file_xfer.c), the unit tests and the conformance adapter share it.
 */

#ifndef AUTONOMOUS_TRUST_SOCIAL_FILE_XFER_H
#define AUTONOMOUS_TRUST_SOCIAL_FILE_XFER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <uuid/uuid.h>
#include <jansson.h>

/** A transfer id: 16 random bytes as lowercase hex, chosen by the sender's
 *  app so one offer to every device of a person shares it. MUST match
 *  AT_APP_FILE_ID_LEN (at_agora.h) and AGORA_FILE_ID_MAX in the shim. */
#define AT_FILE_ID_HEX_LEN 32
/** Bytes of a file name after sanitizing. MUST match AT_APP_FILE_NAME_LEN and
 *  AGORA_FILE_NAME_MAX. */
#define AT_FILE_NAME_MAX 255
/** Bytes of a local path (the sender's source, the receiver's result). MUST
 *  match AT_APP_FILE_PATH_LEN and AGORA_FILE_PATH_MAX. */
#define AT_FILE_PATH_MAX 4095
/** Bytes of a failure reason token. MUST match AT_APP_FILE_REASON_LEN and
 *  AGORA_FILE_REASON_MAX. */
#define AT_FILE_REASON_MAX 31
/** BLAKE2b-256 as lowercase hex. */
#define AT_FILE_HASH_HEX_LEN 64

/** Chunk size the sender offers (env AT_FILE_CHUNK overrides, within the
 *  accepted range). 16 KiB base64-encodes to about 22 KB, well inside one UDP
 *  datagram (65,507 B) after the envelope and the box. */
#define AT_FILE_CHUNK_DEFAULT 16384
/** Chunk sizes a receiver accepts. */
#define AT_FILE_CHUNK_MIN 1024
#define AT_FILE_CHUNK_MAX 32768
/** Chunks one request may name. */
#define AT_FILE_REQ_MAX 64
/** Chunks a receiver keeps requested at once (env AT_FILE_WINDOW overrides,
 *  1..AT_FILE_WINDOW_MAX). Eight, because an AF_UNIX datagram queue holds
 *  about ten frames: a larger burst overflows the receiver's network ->
 *  identity hop, and the overflow waits a tick in send_retry. */
#define AT_FILE_WINDOW_DEFAULT 8
#define AT_FILE_WINDOW_MAX 64
/** Seconds before an outstanding chunk request is asked again. */
#define AT_FILE_REQ_TIMEOUT 3.0
/** Largest file a receiver will take (env AT_FILE_MAX_BYTES overrides). An
 *  offer over it is shown as too large, with no way to accept it. */
#define AT_FILE_MAX_BYTES_DEFAULT (2LL * 1024 * 1024 * 1024)
/** Seconds an unanswered offer lives, and a finished record is kept as a
 *  tombstone. */
#define AT_FILE_RECORD_TTL (7.0 * 24 * 3600)
/** Most transfer records held, live and tombstoned. An offer past it is
 *  refused, never evicted. */
#define AT_FILE_RECORDS_MAX 256

/** The persisted store, beside social.cfg.json in etc/at. */
#define AT_FILE_STORE_FILENAME "file_xfer.cfg.json"
#define AT_FILE_STORE_VERSION 1

/** A transfer's state, as the app sees it. MUST match AT_APP_FILE_* and the
 *  Dart FileTransferState. */
typedef enum {
    AT_FILE_OFFERED   = 0,  /**< waiting for the receiver's answer */
    AT_FILE_ACCEPTED  = 1,  /**< under way; bytes_done is the progress */
    AT_FILE_DONE      = 2,  /**< verified and in place */
    AT_FILE_DECLINED  = 3,
    AT_FILE_CANCELLED = 4,
    AT_FILE_FAILED    = 5,  /**< reason says why */
    AT_FILE_TOO_LARGE = 6,  /**< inbound only: over this node's cap */
} at_file_state_t;

/** True for a state nothing moves out of. */
bool at_file_state_terminal(int state);

/** Control ops carried by peer_file_ctl. */
typedef enum {
    AT_FILE_OP_ACCEPT = 0,
    AT_FILE_OP_DECLINE,
    AT_FILE_OP_CANCEL,
    AT_FILE_OP_DONE,
    AT_FILE_OP_FAIL,
} at_file_op_t;

/** The token for @p op ("accept", ...), or NULL. */
const char *at_file_op_name(int op);
/** The op for @p name, or -1. */
int at_file_op_parse(const char *name);

/* ---- bounds and names ---- */

/** True iff @p id is exactly AT_FILE_ID_HEX_LEN lowercase hex characters. */
bool at_file_id_ok(const char *id);

/**
 * Reduce @p in (a path or a peer-supplied name) to a safe file name in @p out.
 *
 * Keeps only what follows the last '/' or '\\'; drops control characters;
 * replaces the characters Windows forbids (<>:"|?*) with '_'; trims trailing
 * dots and spaces (Windows strips them, and "a." would then collide with
 * "a"); truncates to AT_FILE_NAME_MAX bytes without splitting a UTF-8
 * sequence; and turns an empty result, ".", "..", or a Windows device name
 * (CON, NUL, COM1, ...) into "file". Never fails when @p out_sz > 1.
 *
 * @return the length written, excluding the NUL.
 */
size_t at_file_sanitize_name(const char *in, char *out, size_t out_sz);

/**
 * A path in @p dir for @p name that does not exist yet: "name.ext", then
 * "name (1).ext", "name (2).ext", ... up to 999.
 *
 * @return 0, or -1 if none was free or the path did not fit.
 */
int at_file_unique_path(const char *dir, const char *name, char *out, size_t out_sz);

/** Chunks in a file of @p size bytes at @p chunk bytes each (0 for 0 bytes). */
uint32_t at_file_total_chunks(int64_t size, uint32_t chunk);
/** Bytes in chunk @p index (the last may be short). */
uint32_t at_file_chunk_len(int64_t size, uint32_t chunk, uint32_t index);

/**
 * BLAKE2b-256 of the first @p size bytes of @p path, as lowercase hex.
 * @return 0, or -1 if the file could not be read or is shorter than @p size.
 */
int at_file_hash(const char *path, int64_t size, char hex_out[AT_FILE_HASH_HEX_LEN + 1]);

/* ---- wire forms ---- */

typedef struct {
    char     id[AT_FILE_ID_HEX_LEN + 1];
    char     name[AT_FILE_NAME_MAX + 1];
    int64_t  size;
    uint32_t chunk;
    uint32_t total;
    char     hash[AT_FILE_HASH_HEX_LEN + 1];
    double   ts;
} at_file_offer_t;

/** {"id","name","size","chunk","total","hash","ts"}; NULL on allocation error. */
json_t *at_file_offer_to_json(const at_file_offer_t *offer);
/** Parse and bound-check an offer. The name is SANITIZED here, so nothing a
 *  peer sends reaches a path unsanitized. The chunk size must be in range,
 *  total must equal at_file_total_chunks(size, chunk), the hash 64 hex.
 *  @return 0, or -1 on any malformed field (unknown keys are ignored). */
int at_file_offer_from_json(const json_t *obj, at_file_offer_t *out);

/** {"id","op"[,"reason"]}; @p reason may be NULL. */
json_t *at_file_ctl_to_json(const char *id, int op, const char *reason);
int at_file_ctl_from_json(const json_t *obj, char id_out[AT_FILE_ID_HEX_LEN + 1],
                          int *op_out, char reason_out[AT_FILE_REASON_MAX + 1]);

/** {"id","first","count"}. */
json_t *at_file_req_to_json(const char *id, uint32_t first, uint32_t count);
/** count must be 1..AT_FILE_REQ_MAX; the caller checks first+count <= total. */
int at_file_req_from_json(const json_t *obj, char id_out[AT_FILE_ID_HEX_LEN + 1],
                          uint32_t *first_out, uint32_t *count_out);

/** {"id","i","data"} with @p len bytes of @p data base64-encoded. */
json_t *at_file_chunk_to_json(const char *id, uint32_t index,
                              const uint8_t *data, size_t len);
/** Decode a chunk into @p buf (capacity @p buf_sz, at least the chunk size).
 *  @return 0 with *len_out set, or -1 if malformed or larger than @p buf_sz. */
int at_file_chunk_from_json(const json_t *obj, char id_out[AT_FILE_ID_HEX_LEN + 1],
                            uint32_t *index_out, uint8_t *buf, size_t buf_sz,
                            size_t *len_out);

/* ---- the chunk bitmap ---- */

typedef struct {
    uint8_t  *bits;
    uint32_t  n;      /**< chunks */
    uint32_t  count;  /**< set bits */
} at_file_bitmap_t;

int  at_file_bitmap_init(at_file_bitmap_t *bm, uint32_t n);
void at_file_bitmap_free(at_file_bitmap_t *bm);
bool at_file_bitmap_get(const at_file_bitmap_t *bm, uint32_t i);
/** Set bit @p i. @return true iff it was newly set. */
bool at_file_bitmap_set(at_file_bitmap_t *bm, uint32_t i);
/** The first clear bit at or after @p from, or bm->n if none. */
uint32_t at_file_bitmap_next_clear(const at_file_bitmap_t *bm, uint32_t from);
/** Write the raw bits to @p path atomically (temp + rename). */
int at_file_bitmap_save(const at_file_bitmap_t *bm, const char *path);
/** Load @p path into @p bm, sized for @p n chunks. A missing or wrong-sized
 *  file leaves an empty bitmap and returns 0: the chunks are fetched again,
 *  which is slow but never wrong. @return -1 only on allocation failure. */
int at_file_bitmap_load(at_file_bitmap_t *bm, uint32_t n, const char *path);

/* ---- transfer records and their store ---- */

/** One transfer, either direction. The persisted half is everything above
 *  @c bm; the rest is rebuilt at load. */
typedef struct {
    char     id[AT_FILE_ID_HEX_LEN + 1];
    uuid_t   peer;
    bool     outgoing;
    int      state;               /**< at_file_state_t */
    char     name[AT_FILE_NAME_MAX + 1];
    /** Outgoing: the source the app named. Incoming: the finished file, once
     *  DONE ("" before). */
    char     path[AT_FILE_PATH_MAX + 1];
    char     reason[AT_FILE_REASON_MAX + 1];
    int64_t  size;
    int64_t  mtime;               /**< outgoing: the source's, at offer time */
    uint32_t chunk;
    uint32_t total;
    char     hash[AT_FILE_HASH_HEX_LEN + 1];
    double   created;
    double   updated;

    /* Runtime only. */
    at_file_bitmap_t bm;          /**< incoming: held; outgoing: served */
    uint32_t out_idx[AT_FILE_WINDOW_MAX];  /**< incoming: requested chunks */
    double   out_at[AT_FILE_WINDOW_MAX];
    uint32_t n_out;
    uint32_t cursor;              /**< incoming: next chunk to consider */
    int      fd;                  /**< the .part (in) or the source (out); -1 */
    uint32_t unsaved;             /**< incoming: chunks since the map was saved */
    double   last_emit;
    double   last_rx;             /**< incoming: last chunk; outgoing: last req */
} at_file_xfer_t;

/** Zero @p x and set its fd to -1. */
void at_file_xfer_init(at_file_xfer_t *x);
/** Free the runtime half (bitmap, fd). */
void at_file_xfer_release(at_file_xfer_t *x);
/** Bytes held (incoming) or served (outgoing), from the bitmap. */
int64_t at_file_xfer_bytes_done(const at_file_xfer_t *x);

/** The persisted half of @p x as a JSON object. */
json_t *at_file_xfer_to_json(const at_file_xfer_t *x);
/** Fill the persisted half of @p x (already at_file_xfer_init'd). */
int at_file_xfer_from_json(const json_t *obj, at_file_xfer_t *x);

/** Write @p n records to `<cfg_dir>/file_xfer.cfg.json`, atomically, sorted
 *  keys and 2-space indent like social.cfg.json. */
int at_file_store_save(const char *cfg_dir, at_file_xfer_t *const *xs, size_t n);
/** Load up to @p max records into the caller's array of initialized slots.
 *  A missing file is 0 records; a malformed document is -1 with none.
 *  Malformed records inside a good document are skipped.
 *  @return records loaded, or -1. */
int at_file_store_load(const char *cfg_dir, at_file_xfer_t *xs, size_t max);

/** `<root>/var/agora/files`, where finished files land. */
int at_file_files_dir(char *out, size_t out_sz);
/** The partial file and bitmap for an incoming transfer:
 *  `<files>/.partial/<peer>-<id>.part` and `.part.map`. */
int at_file_part_path(const at_file_xfer_t *x, char *out, size_t out_sz);
int at_file_map_path(const at_file_xfer_t *x, char *out, size_t out_sz);
/** mkdir -p @p path (0700). */
int at_file_mkdirs(const char *path);

#endif /* AUTONOMOUS_TRUST_SOCIAL_FILE_XFER_H */
