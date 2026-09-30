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

#include "post.h"
#include "utilities/msg_types.h"
#include "social_msg_types.h"

#include <string.h>

/* The post body bound is spelled once per header (self-contained like dm.h); a
 * drift between them would corrupt the app-boundary buffer, so pin them here
 * where both are visible. */
_Static_assert(AT_POST_BODY_MAX == AT_POST_BODY_LEN,
               "AT_POST_BODY_MAX (post.h) out of sync with AT_POST_BODY_LEN (social_msg_types.h)");
_Static_assert(AT_POST_ID_HEX_LEN == AT_POST_ID_LEN,
               "AT_POST_ID_HEX_LEN (post.h) out of sync with AT_POST_ID_LEN (social_msg_types.h)");

_Static_assert(AT_POST_COMMUNITY_MAX == AT_BUSINESS_DID_LEN,
               "AT_POST_COMMUNITY_MAX (post.h) out of sync with AT_BUSINESS_DID_LEN "
               "(social_msg_types.h) — a community is a polity, bounded as a business is");
_Static_assert(AT_POST_COMMUNITY_MAX == AT_POST_COMMUNITY_LEN,
               "AT_POST_COMMUNITY_MAX (post.h) out of sync with AT_POST_COMMUNITY_LEN "
               "(social_msg_types.h)");
_Static_assert(AT_POST_LABELS_MAX * (AT_POST_LABEL_MAX + 1) - 1 <= AT_POST_LABELS_LEN,
               "AT_POST_LABELS_LEN (social_msg_types.h) cannot hold every label joined");

/* Signing public-key hex length (32 raw bytes -> 64 chars). */
#define AT_POST_PK_HEX_LEN ((size_t)(crypto_sign_PUBLICKEYBYTES * 2))

size_t at_post_bound_body(const char *in, char *out, size_t out_sz)
{
    if (out == NULL || out_sz == 0) return 0;
    if (in == NULL) { out[0] = '\0'; return 0; }
    size_t cap = AT_POST_BODY_MAX;
    if (out_sz - 1 < cap) cap = out_sz - 1;
    size_t n = strnlen(in, cap);
    memcpy(out, in, n);
    out[n] = '\0';
    return n;
}

bool at_post_label_valid(const char *label)
{
    if (label == NULL) return false;
    size_t n = strnlen(label, AT_POST_LABEL_MAX + 1);
    if (n == 0 || n > AT_POST_LABEL_MAX) return false;
    for (size_t i = 0; i < n; i++) {
        char c = label[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_'))
            return false;
    }
    return true;
}

bool at_post_scope_valid(const at_post_scope_t *scope)
{
    if (scope == NULL) return true;
    size_t dlen = strnlen(scope->community, AT_POST_COMMUNITY_MAX + 1);
    if (dlen > AT_POST_COMMUNITY_MAX) return false;
    /* A label means something only under a policy, and a policy is a
     * community's: labels with nowhere to apply them are refused. */
    if (dlen == 0) return scope->n_labels == 0;
    if (scope->n_labels > AT_POST_LABELS_MAX) return false;
    for (uint8_t i = 0; i < scope->n_labels; i++)
        if (!at_post_label_valid(scope->labels[i])) return false;
    return true;
}

void at_post_scope_normalize(at_post_scope_t *scope)
{
    if (scope == NULL || scope->n_labels > AT_POST_LABELS_MAX) return;
    /* Insertion sort: eight labels at most. */
    for (uint8_t i = 1; i < scope->n_labels; i++) {
        char key[AT_POST_LABEL_MAX + 1];
        memcpy(key, scope->labels[i], sizeof(key));
        int j = (int)i - 1;
        while (j >= 0 && strcmp(scope->labels[j], key) > 0) {
            memcpy(scope->labels[j + 1], scope->labels[j], sizeof(key));
            j--;
        }
        memcpy(scope->labels[j + 1], key, sizeof(key));
    }
    uint8_t w = 0;
    for (uint8_t i = 0; i < scope->n_labels; i++) {
        if (w > 0 && strcmp(scope->labels[w - 1], scope->labels[i]) == 0) continue;
        if (w != i) memcpy(scope->labels[w], scope->labels[i], sizeof(scope->labels[0]));
        w++;
    }
    scope->n_labels = w;
}

void at_post_scope_labels_joined(const at_post_scope_t *scope, char *out,
                                 size_t out_sz)
{
    if (out == NULL || out_sz == 0) return;
    out[0] = '\0';
    if (scope == NULL) return;
    size_t off = 0;
    for (uint8_t i = 0; i < scope->n_labels && i < AT_POST_LABELS_MAX; i++) {
        int n = snprintf(out + off, out_sz - off, "%s%s", i ? "," : "",
                         scope->labels[i]);
        if (n < 0 || (size_t)n >= out_sz - off) break;
        off += (size_t)n;
    }
}

static bool _scoped(const at_post_scope_t *scope)
{
    return scope != NULL && scope->community[0] != '\0';
}

size_t at_post_canonical(const uuid_t author_uuid, int64_t seq, double ts,
                         uint8_t required_tier, const char *body,
                         uint8_t *out, size_t outcap)
{
    return at_post_canonical_scoped(author_uuid, seq, ts, required_tier, body,
                                    NULL, out, outcap);
}

size_t at_post_canonical_scoped(const uuid_t author_uuid, int64_t seq, double ts,
                                uint8_t required_tier, const char *body,
                                const at_post_scope_t *scope,
                                uint8_t *out, size_t outcap)
{
    if (out == NULL) return (size_t)-1;
    if (!at_post_scope_valid(scope)) return (size_t)-1;
    char bounded[AT_POST_BODY_MAX + 1];
    size_t blen = at_post_bound_body(body, bounded, sizeof(bounded));
    size_t need = 16 + 8 + 8 + 1 + 4 + blen;
    size_t dlen = 0;
    if (_scoped(scope)) {
        dlen = strnlen(scope->community, AT_POST_COMMUNITY_MAX);
        need += 1 + 2 + dlen + 1;
        for (uint8_t i = 0; i < scope->n_labels; i++)
            need += 1 + strlen(scope->labels[i]);
    }
    if (outcap < need) return (size_t)-1;

    size_t off = 0;
    memcpy(out + off, author_uuid, sizeof(uuid_t)); off += sizeof(uuid_t);

    uint64_t u = (uint64_t)seq;
    for (int i = 0; i < 8; i++) out[off++] = (uint8_t)((u >> (8 * i)) & 0xFF);

    /* ts as its raw IEEE-754 little-endian bytes: deterministic across C and
     * Python (struct.pack('<d', ts)). */
    uint64_t tb;
    memcpy(&tb, &ts, sizeof(tb));
    for (int i = 0; i < 8; i++) out[off++] = (uint8_t)((tb >> (8 * i)) & 0xFF);

    out[off++] = required_tier;

    uint32_t bl = (uint32_t)blen;
    out[off++] = (uint8_t)(bl & 0xFF);
    out[off++] = (uint8_t)((bl >> 8) & 0xFF);
    out[off++] = (uint8_t)((bl >> 16) & 0xFF);
    out[off++] = (uint8_t)((bl >> 24) & 0xFF);

    if (blen > 0) memcpy(out + off, bounded, blen);
    off += blen;

    /* The scope trailer, only for a post in a community's name: an unscoped
     * post keeps the bytes, and the content id, it always had. */
    if (_scoped(scope)) {
        out[off++] = 1;                                   /* scope version */
        out[off++] = (uint8_t)(dlen & 0xFF);
        out[off++] = (uint8_t)((dlen >> 8) & 0xFF);
        memcpy(out + off, scope->community, dlen);
        off += dlen;
        out[off++] = scope->n_labels;
        for (uint8_t i = 0; i < scope->n_labels; i++) {
            size_t ll = strlen(scope->labels[i]);
            out[off++] = (uint8_t)ll;
            memcpy(out + off, scope->labels[i], ll);
            off += ll;
        }
    }
    return off;
}

int at_post_content_id(const uuid_t author_uuid, int64_t seq, double ts,
                       uint8_t required_tier, const char *body,
                       char *id_hex_out)
{
    return at_post_content_id_scoped(author_uuid, seq, ts, required_tier, body,
                                     NULL, id_hex_out);
}

int at_post_content_id_scoped(const uuid_t author_uuid, int64_t seq, double ts,
                              uint8_t required_tier, const char *body,
                              const at_post_scope_t *scope, char *id_hex_out)
{
    if (id_hex_out == NULL) return -1;
    uint8_t canon[AT_POST_CANON_MAX];
    size_t clen = at_post_canonical_scoped(author_uuid, seq, ts, required_tier,
                                           body, scope, canon, sizeof(canon));
    if (clen == (size_t)-1) return -1;
    unsigned char digest[crypto_generichash_BYTES];   /* 32 */
    crypto_generichash(digest, sizeof(digest), canon, clen, NULL, 0);
    sodium_bin2hex(id_hex_out, AT_POST_ID_HEX_LEN + 1, digest, sizeof(digest));
    return 0;
}

int at_post_sign(const unsigned char sk[crypto_sign_SECRETKEYBYTES],
                 const uuid_t author_uuid, int64_t seq, double ts,
                 uint8_t required_tier, const char *body, char *sig_hex_out)
{
    return at_post_sign_scoped(sk, author_uuid, seq, ts, required_tier, body,
                               NULL, sig_hex_out);
}

int at_post_sign_scoped(const unsigned char sk[crypto_sign_SECRETKEYBYTES],
                        const uuid_t author_uuid, int64_t seq, double ts,
                        uint8_t required_tier, const char *body,
                        const at_post_scope_t *scope, char *sig_hex_out)
{
    if (sk == NULL || sig_hex_out == NULL) return -1;
    uint8_t canon[AT_POST_CANON_MAX];
    size_t clen = at_post_canonical_scoped(author_uuid, seq, ts, required_tier,
                                           body, scope, canon, sizeof(canon));
    if (clen == (size_t)-1) return -1;
    unsigned char sig[crypto_sign_BYTES];
    if (crypto_sign_detached(sig, NULL, canon, clen, sk) != 0)
        return -1;
    sodium_bin2hex(sig_hex_out, AT_POST_SIG_HEX_LEN + 1, sig, sizeof(sig));
    return 0;
}

bool at_post_verify(const unsigned char pk[crypto_sign_PUBLICKEYBYTES],
                    const uuid_t author_uuid, int64_t seq, double ts,
                    uint8_t required_tier, const char *body, const char *sig_hex)
{
    return at_post_verify_scoped(pk, author_uuid, seq, ts, required_tier, body,
                                 NULL, sig_hex);
}

bool at_post_verify_scoped(const unsigned char pk[crypto_sign_PUBLICKEYBYTES],
                           const uuid_t author_uuid, int64_t seq, double ts,
                           uint8_t required_tier, const char *body,
                           const at_post_scope_t *scope, const char *sig_hex)
{
    if (pk == NULL || sig_hex == NULL) return false;
    if (strlen(sig_hex) != AT_POST_SIG_HEX_LEN) return false;
    unsigned char sig[crypto_sign_BYTES];
    size_t bin_len = 0;
    if (sodium_hex2bin(sig, sizeof(sig), sig_hex, strlen(sig_hex),
                       NULL, &bin_len, NULL) != 0 || bin_len != sizeof(sig))
        return false;
    uint8_t canon[AT_POST_CANON_MAX];
    size_t clen = at_post_canonical_scoped(author_uuid, seq, ts, required_tier,
                                           body, scope, canon, sizeof(canon));
    if (clen == (size_t)-1) return false;
    return crypto_sign_verify_detached(sig, canon, clen, pk) == 0;
}

json_t *at_post_to_json(const uuid_t author_uuid, const char *author_pk_hex,
                        int64_t seq, double ts, uint8_t required_tier,
                        const char *body, const char *sig_hex, int hops)
{
    return at_post_to_json_scoped(author_uuid, author_pk_hex, seq, ts,
                                  required_tier, body, NULL, sig_hex, hops);
}

json_t *at_post_to_json_scoped(const uuid_t author_uuid, const char *author_pk_hex,
                               int64_t seq, double ts, uint8_t required_tier,
                               const char *body, const at_post_scope_t *scope,
                               const char *sig_hex, int hops)
{
    if (!at_post_scope_valid(scope)) return NULL;
    char bounded[AT_POST_BODY_MAX + 1];
    at_post_bound_body(body, bounded, sizeof(bounded));
    char author_str[UUID_STRING_LEN + 1];
    uuid_unparse_lower(author_uuid, author_str);
    json_t *env = json_object();
    if (env == NULL) return NULL;
    if (json_object_set_new(env, "author", json_string(author_str)) != 0
        || json_object_set_new(env, "author_pk",
                               json_string(author_pk_hex ? author_pk_hex : "")) != 0
        || json_object_set_new(env, "seq", json_integer((json_int_t)seq)) != 0
        || json_object_set_new(env, "ts", json_real(ts)) != 0
        || json_object_set_new(env, "tier", json_integer(required_tier)) != 0
        || json_object_set_new(env, "body", json_string(bounded)) != 0
        || json_object_set_new(env, "sig", json_string(sig_hex ? sig_hex : "")) != 0
        || json_object_set_new(env, "hops", json_integer(hops)) != 0) {
        json_decref(env);
        return NULL;
    }
    if (_scoped(scope)) {
        json_t *labels = json_array();
        for (uint8_t i = 0; labels != NULL && i < scope->n_labels; i++)
            json_array_append_new(labels, json_string(scope->labels[i]));
        if (labels == NULL
            || json_object_set_new(env, "community", json_string(scope->community)) != 0
            || json_object_set_new(env, "labels", labels) != 0) {
            json_decref(env);
            return NULL;
        }
    }
    return env;
}

int at_post_from_json(const json_t *obj, uuid_t author_out,
                      char author_pk_out[AT_POST_SIG_HEX_LEN + 1],
                      int64_t *seq_out, double *ts_out,
                      uint8_t *tier_out, char *body_out, size_t body_sz,
                      char sig_out[AT_POST_SIG_HEX_LEN + 1], int *hops_out)
{
    return at_post_from_json_scoped(obj, author_out, author_pk_out, seq_out,
                                    ts_out, tier_out, body_out, body_sz, NULL,
                                    sig_out, hops_out);
}

/* Read the optional scope. Absent is unscoped; anything present must be
 * well-formed, because it is signed and a half-read scope would verify against
 * nothing. Returns 0, or -1 on a malformed scope. */
static int _scope_from_json(const json_t *obj, at_post_scope_t *scope)
{
    at_post_scope_t tmp;
    memset(&tmp, 0, sizeof(tmp));
    const json_t *j_comm = json_object_get(obj, "community");
    const json_t *j_labels = json_object_get(obj, "labels");
    if (j_comm == NULL && j_labels == NULL) {
        if (scope != NULL) *scope = tmp;
        return 0;
    }
    if (!json_is_string(j_comm)) return -1;
    const char *c = json_string_value(j_comm);
    size_t clen = strlen(c);
    if (clen == 0 || clen > AT_POST_COMMUNITY_MAX) return -1;
    memcpy(tmp.community, c, clen);
    if (j_labels != NULL) {
        if (!json_is_array(j_labels) || json_array_size(j_labels) > AT_POST_LABELS_MAX)
            return -1;
        size_t i;
        const json_t *v;
        json_array_foreach(j_labels, i, v) {
            if (!json_is_string(v) || !at_post_label_valid(json_string_value(v)))
                return -1;
            snprintf(tmp.labels[tmp.n_labels++], AT_POST_LABEL_MAX + 1, "%s",
                     json_string_value(v));
        }
    }
    if (scope != NULL) *scope = tmp;
    return 0;
}

int at_post_from_json_scoped(const json_t *obj, uuid_t author_out,
                             char author_pk_out[AT_POST_SIG_HEX_LEN + 1],
                             int64_t *seq_out, double *ts_out,
                             uint8_t *tier_out, char *body_out, size_t body_sz,
                             at_post_scope_t *scope_out,
                             char sig_out[AT_POST_SIG_HEX_LEN + 1], int *hops_out)
{
    if (scope_out != NULL) memset(scope_out, 0, sizeof(*scope_out));
    if (body_out != NULL && body_sz > 0) body_out[0] = '\0';
    if (author_pk_out != NULL) author_pk_out[0] = '\0';
    if (sig_out != NULL) sig_out[0] = '\0';
    if (obj == NULL || !json_is_object(obj)) return -1;

    const json_t *j_author = json_object_get(obj, "author");
    const json_t *j_pk     = json_object_get(obj, "author_pk");
    const json_t *j_seq    = json_object_get(obj, "seq");
    const json_t *j_ts     = json_object_get(obj, "ts");
    const json_t *j_tier   = json_object_get(obj, "tier");
    const json_t *j_body   = json_object_get(obj, "body");
    const json_t *j_sig    = json_object_get(obj, "sig");
    const json_t *j_hops   = json_object_get(obj, "hops");

    if (!json_is_string(j_author) || !json_is_string(j_pk)
        || !json_is_integer(j_seq) || !json_is_number(j_ts)
        || !json_is_integer(j_tier) || !json_is_string(j_body)
        || !json_is_string(j_sig) || !json_is_integer(j_hops))
        return -1;

    if (uuid_parse(json_string_value(j_author), author_out) != 0)
        return -1;

    const char *pk = json_string_value(j_pk);
    if (strlen(pk) != AT_POST_PK_HEX_LEN) return -1;
    const char *sg = json_string_value(j_sig);
    if (strlen(sg) != AT_POST_SIG_HEX_LEN) return -1;

    json_int_t tier = json_integer_value(j_tier);
    if (tier < AT_POST_TIER_MIN || tier > AT_POST_TIER_MAX) return -1;

    /* Read even when the caller does not want it: an unscoped reader must
     * still refuse a malformed scope rather than verify a post whose signed
     * bytes it cannot reproduce. */
    at_post_scope_t scope;
    if (_scope_from_json(obj, &scope) != 0) return -1;
    if (scope_out != NULL) *scope_out = scope;

    if (author_pk_out != NULL) {
        memcpy(author_pk_out, pk, AT_POST_PK_HEX_LEN);
        author_pk_out[AT_POST_PK_HEX_LEN] = '\0';
    }
    if (sig_out != NULL) {
        memcpy(sig_out, sg, AT_POST_SIG_HEX_LEN);
        sig_out[AT_POST_SIG_HEX_LEN] = '\0';
    }
    at_post_bound_body(json_string_value(j_body), body_out, body_sz);
    if (seq_out != NULL) *seq_out = (int64_t)json_integer_value(j_seq);
    if (ts_out != NULL) *ts_out = json_number_value(j_ts);
    if (tier_out != NULL) *tier_out = (uint8_t)tier;
    if (hops_out != NULL) *hops_out = (int)json_integer_value(j_hops);
    return 0;
}
