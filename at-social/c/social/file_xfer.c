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

#include "file_xfer.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#include <sodium.h>

#include "config/configuration.h"
#include "utilities/b64.h"
#include "utilities/portable.h"  /* at_tmp_path */
#include "utilities/util.h"      /* path_join, makedirs */

#ifndef O_BINARY
#define O_BINARY 0
#endif

/* ---- states and ops ---- */

bool at_file_state_terminal(int state)
{
    return state == AT_FILE_DONE || state == AT_FILE_DECLINED
        || state == AT_FILE_CANCELLED || state == AT_FILE_FAILED
        || state == AT_FILE_TOO_LARGE;
}

static const char *const OP_NAMES[] = {
    [AT_FILE_OP_ACCEPT]  = "accept",
    [AT_FILE_OP_DECLINE] = "decline",
    [AT_FILE_OP_CANCEL]  = "cancel",
    [AT_FILE_OP_DONE]    = "done",
    [AT_FILE_OP_FAIL]    = "fail",
};
#define N_OPS (sizeof(OP_NAMES) / sizeof(OP_NAMES[0]))

const char *at_file_op_name(int op)
{
    return (op >= 0 && (size_t)op < N_OPS) ? OP_NAMES[op] : NULL;
}

int at_file_op_parse(const char *name)
{
    if (name == NULL)
        return -1;
    for (size_t i = 0; i < N_OPS; i++)
        if (strcmp(name, OP_NAMES[i]) == 0)
            return (int)i;
    return -1;
}

/* ---- bounds and names ---- */

static bool _hex_ok(const char *s, size_t len)
{
    if (s == NULL || strlen(s) != len)
        return false;
    for (size_t i = 0; i < len; i++)
        if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f')))
            return false;
    return true;
}

bool at_file_id_ok(const char *id)
{
    return _hex_ok(id, AT_FILE_ID_HEX_LEN);
}

/* Windows device names, which no file may be called whatever its extension
 * ("nul.txt" opens the null device). Compared case-insensitively against the
 * part before the first '.'. */
static bool _reserved_stem(const char *name)
{
    static const char *const DEV[] = {
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    };
    size_t stem = strcspn(name, ".");
    for (size_t i = 0; i < sizeof(DEV) / sizeof(DEV[0]); i++)
        if (strlen(DEV[i]) == stem && strncasecmp(name, DEV[i], stem) == 0)
            return true;
    return false;
}

size_t at_file_sanitize_name(const char *in, char *out, size_t out_sz)
{
    if (out == NULL || out_sz == 0)
        return 0;
    out[0] = '\0';
    if (out_sz < 2)
        return 0;
    const char *base = in != NULL ? in : "";
    for (const char *p = base; *p != '\0'; p++)
        if (*p == '/' || *p == '\\')
            base = p + 1;

    size_t cap = out_sz - 1;
    if (cap > AT_FILE_NAME_MAX)
        cap = AT_FILE_NAME_MAX;
    size_t n = 0;
    for (const unsigned char *p = (const unsigned char *)base; *p != '\0'; p++) {
        unsigned char c = *p;
        if (c < 0x20 || c == 0x7f)
            continue;
        if (strchr("<>:\"|?*", (int)c) != NULL)
            c = '_';
        if (n >= cap)
            break;
        out[n++] = (char)c;
    }
    /* Never end inside a UTF-8 sequence: back up over continuation bytes to
     * the lead byte and drop the sequence if it was cut. */
    if (n > 0 && ((unsigned char)out[n - 1] & 0x80) != 0) {
        size_t lead = n - 1;
        while (lead > 0 && ((unsigned char)out[lead] & 0xC0) == 0x80)
            lead--;
        unsigned char l = (unsigned char)out[lead];
        size_t need = (l & 0xE0) == 0xC0 ? 2 : (l & 0xF0) == 0xE0 ? 3
                    : (l & 0xF8) == 0xF0 ? 4 : 1;
        if (n - lead < need)
            n = lead;
    }
    while (n > 0 && (out[n - 1] == '.' || out[n - 1] == ' '))
        n--;
    out[n] = '\0';
    if (n == 0 || strcmp(out, ".") == 0 || strcmp(out, "..") == 0
        || _reserved_stem(out)) {
        snprintf(out, out_sz, "file");
        return strlen(out);
    }
    return n;
}

int at_file_unique_path(const char *dir, const char *name, char *out, size_t out_sz)
{
    if (dir == NULL || name == NULL || out == NULL)
        return -1;
    const char *dot = strrchr(name, '.');
    if (dot == name)
        dot = NULL;   /* ".bashrc" is all stem */
    size_t stem = dot != NULL ? (size_t)(dot - name) : strlen(name);
    const char *ext = dot != NULL ? dot : "";
    for (int i = 0; i < 1000; i++) {
        int n = i == 0 ? snprintf(out, out_sz, "%s/%s", dir, name)
                       : snprintf(out, out_sz, "%s/%.*s (%d)%s", dir, (int)stem,
                                  name, i, ext);
        if (n < 0 || (size_t)n >= out_sz)
            return -1;
        struct stat st;
        if (stat(out, &st) != 0 && errno == ENOENT)
            return 0;
    }
    return -1;
}

uint32_t at_file_total_chunks(int64_t size, uint32_t chunk)
{
    if (size <= 0 || chunk == 0)
        return 0;
    return (uint32_t)((size + chunk - 1) / chunk);
}

uint32_t at_file_chunk_len(int64_t size, uint32_t chunk, uint32_t index)
{
    int64_t off = (int64_t)index * chunk;
    if (off >= size)
        return 0;
    int64_t left = size - off;
    return left < chunk ? (uint32_t)left : chunk;
}

static void _to_hex(const uint8_t *b, size_t n, char *out)
{
    static const char HEX[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[2 * i]     = HEX[b[i] >> 4];
        out[2 * i + 1] = HEX[b[i] & 0xf];
    }
    out[2 * n] = '\0';
}

int at_file_hash(const char *path, int64_t size, char hex_out[AT_FILE_HASH_HEX_LEN + 1])
{
    if (path == NULL || hex_out == NULL || size < 0)
        return -1;
    int fd = open(path, O_RDONLY | O_BINARY);
    if (fd < 0)
        return -1;
    crypto_generichash_blake2b_state st;
    crypto_generichash_blake2b_init(&st, NULL, 0, 32);
    uint8_t *buf = malloc(1 << 16);
    if (buf == NULL) {
        close(fd);
        return -1;
    }
    int64_t left = size;
    int rc = 0;
    while (left > 0) {
        size_t want = left < (1 << 16) ? (size_t)left : (1 << 16);
        ssize_t got = read(fd, buf, want);
        if (got <= 0) {
            rc = -1;
            break;
        }
        crypto_generichash_blake2b_update(&st, buf, (size_t)got);
        left -= got;
    }
    free(buf);
    close(fd);
    if (rc != 0)
        return -1;
    uint8_t digest[32];
    crypto_generichash_blake2b_final(&st, digest, sizeof(digest));
    _to_hex(digest, sizeof(digest), hex_out);
    return 0;
}

/* ---- wire forms ---- */

static int _copy_id(const json_t *obj, char id_out[AT_FILE_ID_HEX_LEN + 1])
{
    const char *id = json_string_value(json_object_get(obj, "id"));
    if (!at_file_id_ok(id))
        return -1;
    memcpy(id_out, id, AT_FILE_ID_HEX_LEN + 1);
    return 0;
}

json_t *at_file_offer_to_json(const at_file_offer_t *o)
{
    if (o == NULL)
        return NULL;
    return json_pack("{s:s, s:s, s:I, s:I, s:I, s:s, s:f}",
                     "id", o->id, "name", o->name,
                     "size", (json_int_t)o->size,
                     "chunk", (json_int_t)o->chunk,
                     "total", (json_int_t)o->total,
                     "hash", o->hash, "ts", o->ts);
}

int at_file_offer_from_json(const json_t *obj, at_file_offer_t *out)
{
    if (obj == NULL || out == NULL || !json_is_object(obj))
        return -1;
    memset(out, 0, sizeof(*out));
    const json_t *j_name  = json_object_get(obj, "name");
    const json_t *j_size  = json_object_get(obj, "size");
    const json_t *j_chunk = json_object_get(obj, "chunk");
    const json_t *j_total = json_object_get(obj, "total");
    const json_t *j_hash  = json_object_get(obj, "hash");
    const json_t *j_ts    = json_object_get(obj, "ts");
    if (_copy_id(obj, out->id) != 0 || !json_is_string(j_name)
        || !json_is_integer(j_size) || !json_is_integer(j_chunk)
        || !json_is_integer(j_total) || !json_is_number(j_ts)
        || !_hex_ok(json_string_value(j_hash), AT_FILE_HASH_HEX_LEN))
        return -1;
    json_int_t size = json_integer_value(j_size);
    json_int_t chunk = json_integer_value(j_chunk);
    json_int_t total = json_integer_value(j_total);
    if (size < 0 || chunk < AT_FILE_CHUNK_MIN || chunk > AT_FILE_CHUNK_MAX)
        return -1;
    /* A total that disagrees with size/chunk would let a sender make the
     * receiver allocate a bitmap for chunks that cannot exist. */
    if (total < 0 || (int64_t)total != (int64_t)at_file_total_chunks(size, (uint32_t)chunk)
        || size > (int64_t)chunk * (int64_t)UINT32_MAX)
        return -1;
    out->size = size;
    out->chunk = (uint32_t)chunk;
    out->total = (uint32_t)total;
    memcpy(out->hash, json_string_value(j_hash), AT_FILE_HASH_HEX_LEN + 1);
    out->ts = json_number_value(j_ts);
    at_file_sanitize_name(json_string_value(j_name), out->name, sizeof(out->name));
    return 0;
}

json_t *at_file_ctl_to_json(const char *id, int op, const char *reason)
{
    const char *name = at_file_op_name(op);
    if (id == NULL || name == NULL)
        return NULL;
    json_t *j = json_pack("{s:s, s:s}", "id", id, "op", name);
    if (j != NULL && reason != NULL && reason[0] != '\0') {
        char r[AT_FILE_REASON_MAX + 1];
        snprintf(r, sizeof(r), "%s", reason);
        json_object_set_new(j, "reason", json_string(r));
    }
    return j;
}

int at_file_ctl_from_json(const json_t *obj, char id_out[AT_FILE_ID_HEX_LEN + 1],
                          int *op_out, char reason_out[AT_FILE_REASON_MAX + 1])
{
    if (obj == NULL || !json_is_object(obj) || id_out == NULL || op_out == NULL)
        return -1;
    if (_copy_id(obj, id_out) != 0)
        return -1;
    int op = at_file_op_parse(json_string_value(json_object_get(obj, "op")));
    if (op < 0)
        return -1;
    *op_out = op;
    if (reason_out != NULL) {
        reason_out[0] = '\0';
        const char *r = json_string_value(json_object_get(obj, "reason"));
        if (r != NULL) {
            /* A token from a peer: keep [a-z0-9_] only, so it can never be
             * mistaken for more than a word in a log line or the UI. */
            size_t n = 0;
            for (const char *p = r; *p != '\0' && n < AT_FILE_REASON_MAX; p++)
                if ((*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '_')
                    reason_out[n++] = *p;
            reason_out[n] = '\0';
        }
    }
    return 0;
}

json_t *at_file_req_to_json(const char *id, uint32_t first, uint32_t count)
{
    if (id == NULL)
        return NULL;
    return json_pack("{s:s, s:I, s:I}", "id", id, "first", (json_int_t)first,
                     "count", (json_int_t)count);
}

int at_file_req_from_json(const json_t *obj, char id_out[AT_FILE_ID_HEX_LEN + 1],
                          uint32_t *first_out, uint32_t *count_out)
{
    if (obj == NULL || !json_is_object(obj) || first_out == NULL || count_out == NULL)
        return -1;
    if (_copy_id(obj, id_out) != 0)
        return -1;
    const json_t *j_first = json_object_get(obj, "first");
    const json_t *j_count = json_object_get(obj, "count");
    if (!json_is_integer(j_first) || !json_is_integer(j_count))
        return -1;
    json_int_t first = json_integer_value(j_first);
    json_int_t count = json_integer_value(j_count);
    if (first < 0 || first > (json_int_t)UINT32_MAX || count < 1 || count > AT_FILE_REQ_MAX)
        return -1;
    *first_out = (uint32_t)first;
    *count_out = (uint32_t)count;
    return 0;
}

json_t *at_file_chunk_to_json(const char *id, uint32_t index,
                              const uint8_t *data, size_t len)
{
    if (id == NULL || (data == NULL && len > 0))
        return NULL;
    size_t enc = b64_encoded_len(len);   /* counts the NUL */
    char *b64 = malloc(enc);
    if (b64 == NULL)
        return NULL;
    base64_encode(data, len, b64, enc);
    json_t *j = json_pack("{s:s, s:I, s:s}", "id", id, "i", (json_int_t)index,
                          "data", b64);
    free(b64);
    return j;
}

int at_file_chunk_from_json(const json_t *obj, char id_out[AT_FILE_ID_HEX_LEN + 1],
                            uint32_t *index_out, uint8_t *buf, size_t buf_sz,
                            size_t *len_out)
{
    if (obj == NULL || !json_is_object(obj) || index_out == NULL || buf == NULL
        || len_out == NULL)
        return -1;
    if (_copy_id(obj, id_out) != 0)
        return -1;
    const json_t *j_i = json_object_get(obj, "i");
    const json_t *j_data = json_object_get(obj, "data");
    if (!json_is_integer(j_i) || !json_is_string(j_data))
        return -1;
    json_int_t i = json_integer_value(j_i);
    if (i < 0 || i > (json_int_t)UINT32_MAX)
        return -1;
    const char *s = json_string_value(j_data);
    size_t slen = json_string_length(j_data);
    if (slen % 4 != 0 || (slen > 0 && b64_decoded_len_s(slen, s) > buf_sz))
        return -1;
    /* sodium refuses anything that is not canonical base64, and anything
     * that would not fit. */
    size_t dec = 0;
    if (slen > 0
        && sodium_base642bin(buf, buf_sz, s, slen, NULL, &dec, NULL,
                             sodium_base64_VARIANT_ORIGINAL) != 0)
        return -1;
    *index_out = (uint32_t)i;
    *len_out = dec;
    return 0;
}

/* ---- the chunk bitmap ---- */

int at_file_bitmap_init(at_file_bitmap_t *bm, uint32_t n)
{
    if (bm == NULL)
        return -1;
    bm->n = n;
    bm->count = 0;
    bm->bits = calloc((size_t)n / 8 + 1, 1);
    return bm->bits != NULL ? 0 : -1;
}

void at_file_bitmap_free(at_file_bitmap_t *bm)
{
    if (bm == NULL)
        return;
    free(bm->bits);
    bm->bits = NULL;
    bm->n = 0;
    bm->count = 0;
}

bool at_file_bitmap_get(const at_file_bitmap_t *bm, uint32_t i)
{
    if (bm == NULL || bm->bits == NULL || i >= bm->n)
        return false;
    return (bm->bits[i / 8] >> (i % 8)) & 1;
}

bool at_file_bitmap_set(at_file_bitmap_t *bm, uint32_t i)
{
    if (bm == NULL || bm->bits == NULL || i >= bm->n || at_file_bitmap_get(bm, i))
        return false;
    bm->bits[i / 8] |= (uint8_t)(1u << (i % 8));
    bm->count++;
    return true;
}

uint32_t at_file_bitmap_next_clear(const at_file_bitmap_t *bm, uint32_t from)
{
    if (bm == NULL || bm->bits == NULL)
        return 0;
    for (uint32_t i = from; i < bm->n; i++) {
        if (i % 8 == 0 && bm->bits[i / 8] == 0xff) {
            i += 7;
            continue;
        }
        if (!at_file_bitmap_get(bm, i))
            return i;
    }
    return bm->n;
}

int at_file_bitmap_save(const at_file_bitmap_t *bm, const char *path)
{
    if (bm == NULL || bm->bits == NULL || path == NULL)
        return -1;
    char tmp[AT_FILE_PATH_MAX + 32];
    if (at_tmp_path(tmp, sizeof(tmp), path) != 0)
        return -1;
    FILE *f = fopen(tmp, "wb");
    if (f == NULL)
        return -1;
    size_t len = (size_t)bm->n / 8 + 1;
    bool ok = fwrite(bm->bits, 1, len, f) == len;
    ok = (fclose(f) == 0) && ok;
    if (!ok || rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

int at_file_bitmap_load(at_file_bitmap_t *bm, uint32_t n, const char *path)
{
    if (at_file_bitmap_init(bm, n) != 0)
        return -1;
    if (path == NULL)
        return 0;
    FILE *f = fopen(path, "rb");
    if (f == NULL)
        return 0;
    size_t len = (size_t)n / 8 + 1;
    size_t got = fread(bm->bits, 1, len, f);
    int extra = fgetc(f);
    fclose(f);
    if (got != len || extra != EOF) {
        memset(bm->bits, 0, len);
        return 0;
    }
    /* Bits past n are not chunks; a sidecar written for a different total
     * must not count them. */
    for (uint32_t i = n; i < (uint32_t)(len * 8); i++)
        bm->bits[i / 8] &= (uint8_t)~(1u << (i % 8));
    for (uint32_t i = 0; i < n; i++)
        if (at_file_bitmap_get(bm, i))
            bm->count++;
    return 0;
}

/* ---- records ---- */

void at_file_xfer_init(at_file_xfer_t *x)
{
    if (x == NULL)
        return;
    memset(x, 0, sizeof(*x));
    x->fd = -1;
}

void at_file_xfer_release(at_file_xfer_t *x)
{
    if (x == NULL)
        return;
    at_file_bitmap_free(&x->bm);
    if (x->fd >= 0)
        close(x->fd);
    x->fd = -1;
    x->n_out = 0;
}

int64_t at_file_xfer_bytes_done(const at_file_xfer_t *x)
{
    if (x == NULL)
        return 0;
    if (x->state == AT_FILE_DONE)
        return x->size;
    if (x->bm.bits == NULL || x->bm.count == 0)
        return 0;
    int64_t bytes = (int64_t)x->bm.count * x->chunk;
    /* The last chunk is short; count it at its real length. */
    if (x->total > 0 && at_file_bitmap_get(&x->bm, x->total - 1))
        bytes -= (int64_t)x->chunk - at_file_chunk_len(x->size, x->chunk, x->total - 1);
    return bytes;
}

json_t *at_file_xfer_to_json(const at_file_xfer_t *x)
{
    if (x == NULL)
        return NULL;
    char peer[37];
    uuid_unparse_lower(x->peer, peer);
    return json_pack("{s:s, s:s, s:s, s:i, s:s, s:s, s:s, s:I, s:I, s:I, s:I,"
                     " s:s, s:f, s:f}",
                     "id", x->id, "peer", peer, "dir", x->outgoing ? "out" : "in",
                     "state", x->state, "name", x->name, "path", x->path,
                     "reason", x->reason, "size", (json_int_t)x->size,
                     "mtime", (json_int_t)x->mtime, "chunk", (json_int_t)x->chunk,
                     "total", (json_int_t)x->total, "hash", x->hash,
                     "created", x->created, "updated", x->updated);
}

static void _copy_str(const json_t *obj, const char *key, char *out, size_t out_sz)
{
    const char *s = json_string_value(json_object_get(obj, key));
    snprintf(out, out_sz, "%s", s != NULL ? s : "");
}

int at_file_xfer_from_json(const json_t *obj, at_file_xfer_t *x)
{
    if (obj == NULL || x == NULL || !json_is_object(obj))
        return -1;
    const char *peer = json_string_value(json_object_get(obj, "peer"));
    const char *dir = json_string_value(json_object_get(obj, "dir"));
    const json_t *j_state = json_object_get(obj, "state");
    const json_t *j_size = json_object_get(obj, "size");
    const json_t *j_chunk = json_object_get(obj, "chunk");
    const json_t *j_total = json_object_get(obj, "total");
    if (_copy_id(obj, x->id) != 0 || peer == NULL || uuid_parse(peer, x->peer) != 0
        || dir == NULL || (strcmp(dir, "out") != 0 && strcmp(dir, "in") != 0)
        || !json_is_integer(j_state) || !json_is_integer(j_size)
        || !json_is_integer(j_chunk) || !json_is_integer(j_total))
        return -1;
    x->outgoing = strcmp(dir, "out") == 0;
    x->state = (int)json_integer_value(j_state);
    if (x->state < AT_FILE_OFFERED || x->state > AT_FILE_TOO_LARGE)
        return -1;
    x->size = json_integer_value(j_size);
    json_int_t chunk = json_integer_value(j_chunk);
    if (x->size < 0 || chunk < AT_FILE_CHUNK_MIN || chunk > AT_FILE_CHUNK_MAX)
        return -1;
    x->chunk = (uint32_t)chunk;
    x->total = at_file_total_chunks(x->size, x->chunk);
    if ((int64_t)json_integer_value(j_total) != (int64_t)x->total)
        return -1;
    x->mtime = json_integer_value(json_object_get(obj, "mtime"));
    _copy_str(obj, "name", x->name, sizeof(x->name));
    _copy_str(obj, "path", x->path, sizeof(x->path));
    _copy_str(obj, "reason", x->reason, sizeof(x->reason));
    _copy_str(obj, "hash", x->hash, sizeof(x->hash));
    if (!_hex_ok(x->hash, AT_FILE_HASH_HEX_LEN))
        return -1;
    /* A name read back from disk is sanitized again: the file is ours, but
     * nothing that ends up in a path is trusted for having been written. */
    char clean[AT_FILE_NAME_MAX + 1];
    at_file_sanitize_name(x->name, clean, sizeof(clean));
    memcpy(x->name, clean, sizeof(clean));
    x->created = json_number_value(json_object_get(obj, "created"));
    x->updated = json_number_value(json_object_get(obj, "updated"));
    return 0;
}

int at_file_store_save(const char *cfg_dir, at_file_xfer_t *const *xs, size_t n)
{
    if (cfg_dir == NULL)
        return -1;
    char path[AT_FILE_PATH_MAX + 1];
    int len = snprintf(path, sizeof(path), "%s/%s", cfg_dir, AT_FILE_STORE_FILENAME);
    if (len < 0 || (size_t)len >= sizeof(path))
        return -1;
    json_t *arr = json_array();
    for (size_t i = 0; arr != NULL && i < n; i++)
        if (xs[i] != NULL)
            json_array_append_new(arr, at_file_xfer_to_json(xs[i]));
    json_t *doc = json_pack("{s:i, s:o}", "version", AT_FILE_STORE_VERSION,
                            "xfers", arr);
    if (doc == NULL)
        return -1;
    char tmp[AT_FILE_PATH_MAX + 32];
    if (at_tmp_path(tmp, sizeof(tmp), path) != 0) {
        json_decref(doc);
        return -1;
    }
    int rc = json_dump_file(doc, tmp, JSON_INDENT(2) | JSON_SORT_KEYS);
    json_decref(doc);
    if (rc != 0 || rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

int at_file_store_load(const char *cfg_dir, at_file_xfer_t *xs, size_t max)
{
    if (cfg_dir == NULL || xs == NULL)
        return -1;
    char path[AT_FILE_PATH_MAX + 1];
    int len = snprintf(path, sizeof(path), "%s/%s", cfg_dir, AT_FILE_STORE_FILENAME);
    if (len < 0 || (size_t)len >= sizeof(path))
        return -1;
    struct stat st;
    if (stat(path, &st) != 0)
        return 0;
    json_t *doc = json_load_file(path, 0, NULL);
    json_t *arr = doc != NULL ? json_object_get(doc, "xfers") : NULL;
    if (!json_is_array(arr)) {
        json_decref(doc);
        return -1;
    }
    size_t got = 0;
    for (size_t i = 0; i < json_array_size(arr) && got < max; i++) {
        at_file_xfer_init(&xs[got]);
        if (at_file_xfer_from_json(json_array_get(arr, i), &xs[got]) == 0)
            got++;
    }
    json_decref(doc);
    return (int)got;
}

int at_file_files_dir(char *out, size_t out_sz)
{
    if (out == NULL)
        return -1;
    return path_join(out, out_sz, rootDir(), "var/agora/files") > 0 ? 0 : -1;
}

static int _partial(const at_file_xfer_t *x, const char *suffix, char *out, size_t out_sz)
{
    if (x == NULL || out == NULL)
        return -1;
    char dir[AT_FILE_PATH_MAX + 1];
    if (at_file_files_dir(dir, sizeof(dir)) != 0)
        return -1;
    char peer[37];
    uuid_unparse_lower(x->peer, peer);
    int n = snprintf(out, out_sz, "%s/.partial/%s-%s%s", dir, peer, x->id, suffix);
    return (n < 0 || (size_t)n >= out_sz) ? -1 : 0;
}

int at_file_part_path(const at_file_xfer_t *x, char *out, size_t out_sz)
{
    return _partial(x, ".part", out, out_sz);
}

int at_file_map_path(const at_file_xfer_t *x, char *out, size_t out_sz)
{
    return _partial(x, ".part.map", out, out_sz);
}

int at_file_mkdirs(const char *path)
{
    if (path == NULL || path[0] == '\0')
        return -1;
    char buf[AT_FILE_PATH_MAX + 1];
    snprintf(buf, sizeof(buf), "%s", path);
    return makedirs(buf, 0700) == 0 ? 0 : -1;
}
