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

#include "community.h"
#include "utilities/msg_types.h"
#include "social_msg_types.h"

#include <string.h>

_Static_assert(AT_COMMUNITY_POLICY_BUNDLE_MAX == AT_COMMUNITY_POLICY_BUNDLE_LEN,
               "AT_COMMUNITY_POLICY_BUNDLE_MAX (community.h) out of sync with "
               "AT_COMMUNITY_POLICY_BUNDLE_LEN (social_msg_types.h)");
_Static_assert(AT_POST_LABEL_BUNDLE_MAX == AT_POST_LABEL_BUNDLE_LEN,
               "AT_POST_LABEL_BUNDLE_MAX (community.h) out of sync with "
               "AT_POST_LABEL_BUNDLE_LEN (social_msg_types.h)");
_Static_assert(AT_COMMUNITY_DID_MAX == AT_BUSINESS_DID_LEN,
               "AT_COMMUNITY_DID_MAX (community.h) out of sync with AT_BUSINESS_DID_LEN "
               "— a community is a polity, bounded as a business is");
_Static_assert(AT_COMMUNITY_ID_HEX_LEN == AT_COMMUNITY_POLICY_ID_LEN
                   && AT_COMMUNITY_ID_HEX_LEN == AT_POST_LABEL_ID_LEN
                   && AT_COMMUNITY_ID_HEX_LEN == AT_POST_ID_LEN,
               "community content ids out of sync with social_msg_types.h");

#define PK_HEX_LEN ((size_t)(crypto_sign_PUBLICKEYBYTES * 2))

static size_t bound_copy(const char *in, char *out, size_t out_sz, size_t cap)
{
    if (out == NULL || out_sz == 0) return 0;
    if (in == NULL) { out[0] = '\0'; return 0; }
    if (out_sz - 1 < cap) cap = out_sz - 1;
    size_t n = strnlen(in, cap);
    memcpy(out, in, n);
    out[n] = '\0';
    return n;
}

size_t at_community_bound_did(const char *in, char *out, size_t out_sz)
{
    return bound_copy(in, out, out_sz, AT_COMMUNITY_DID_MAX);
}

size_t at_community_bound_policy(const char *in, char *out, size_t out_sz)
{
    return bound_copy(in, out, out_sz, AT_COMMUNITY_POLICY_BUNDLE_MAX);
}

size_t at_community_bound_label(const char *in, char *out, size_t out_sz)
{
    return bound_copy(in, out, out_sz, AT_POST_LABEL_BUNDLE_MAX);
}

bool at_community_post_id_valid(const char *id)
{
    if (id == NULL || strnlen(id, AT_COMMUNITY_ID_HEX_LEN + 1) != AT_COMMUNITY_ID_HEX_LEN)
        return false;
    for (size_t i = 0; i < AT_COMMUNITY_ID_HEX_LEN; i++) {
        char c = id[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            return false;
    }
    return true;
}

static void put_u32le(uint8_t *out, size_t *off, uint32_t v)
{
    for (int i = 0; i < 4; i++) out[(*off)++] = (uint8_t)((v >> (8 * i)) & 0xFF);
}

static void put_u64le(uint8_t *out, size_t *off, uint64_t v)
{
    for (int i = 0; i < 8; i++) out[(*off)++] = (uint8_t)((v >> (8 * i)) & 0xFF);
}

/* The one canonical writer for both artifacts: @p post_id NULL is a policy ad,
 * non-NULL a label (which splices the 64 id bytes after the DID). */
static size_t _canonical(const uuid_t who, const char *community,
                         const char *post_id, int64_t seq, double ts,
                         const char *bundle, size_t bundle_cap,
                         uint8_t *out, size_t outcap)
{
    if (out == NULL) return (size_t)-1;
    char did[AT_COMMUNITY_DID_MAX + 1];
    size_t dlen = at_community_bound_did(community, did, sizeof(did));
    char bnd[AT_COMMUNITY_POLICY_BUNDLE_MAX + 1];
    size_t blen = bound_copy(bundle, bnd, sizeof(bnd), bundle_cap);
    if (post_id != NULL && !at_community_post_id_valid(post_id)) return (size_t)-1;
    size_t need = 16 + 4 + dlen + (post_id ? AT_COMMUNITY_ID_HEX_LEN : 0) + 8 + 8
                  + 4 + blen;
    if (outcap < need) return (size_t)-1;

    size_t off = 0;
    memcpy(out + off, who, sizeof(uuid_t)); off += sizeof(uuid_t);
    put_u32le(out, &off, (uint32_t)dlen);
    if (dlen > 0) { memcpy(out + off, did, dlen); off += dlen; }
    if (post_id != NULL) {
        memcpy(out + off, post_id, AT_COMMUNITY_ID_HEX_LEN);
        off += AT_COMMUNITY_ID_HEX_LEN;
    }
    put_u64le(out, &off, (uint64_t)seq);
    /* ts as its raw IEEE-754 little-endian bytes (struct.pack('<d')). */
    uint64_t tb;
    memcpy(&tb, &ts, sizeof(tb));
    put_u64le(out, &off, tb);
    put_u32le(out, &off, (uint32_t)blen);
    if (blen > 0) { memcpy(out + off, bnd, blen); off += blen; }
    return off;
}

static int _id(const uint8_t *canon, size_t clen, char *id_hex_out)
{
    if (id_hex_out == NULL || clen == (size_t)-1) return -1;
    unsigned char digest[crypto_generichash_BYTES];
    crypto_generichash(digest, sizeof(digest), canon, clen, NULL, 0);
    sodium_bin2hex(id_hex_out, AT_COMMUNITY_ID_HEX_LEN + 1, digest, sizeof(digest));
    return 0;
}

static int _sign(const unsigned char *sk, const uint8_t *canon, size_t clen,
                 char *sig_hex_out)
{
    if (sk == NULL || sig_hex_out == NULL || clen == (size_t)-1) return -1;
    unsigned char sig[crypto_sign_BYTES];
    if (crypto_sign_detached(sig, NULL, canon, clen, sk) != 0) return -1;
    sodium_bin2hex(sig_hex_out, AT_COMMUNITY_SIG_HEX_LEN + 1, sig, sizeof(sig));
    return 0;
}

static bool _verify(const unsigned char *pk, const uint8_t *canon, size_t clen,
                    const char *sig_hex)
{
    if (pk == NULL || sig_hex == NULL || clen == (size_t)-1) return false;
    if (strlen(sig_hex) != AT_COMMUNITY_SIG_HEX_LEN) return false;
    unsigned char sig[crypto_sign_BYTES];
    size_t bin_len = 0;
    if (sodium_hex2bin(sig, sizeof(sig), sig_hex, strlen(sig_hex), NULL, &bin_len,
                       NULL) != 0 || bin_len != sizeof(sig))
        return false;
    return crypto_sign_verify_detached(sig, canon, clen, pk) == 0;
}

/* ---- The policy ad -------------------------------------------------------- */

size_t at_policy_ad_canonical(const uuid_t carrier_uuid, const char *community,
                              int64_t seq, double ts, const char *bundle,
                              uint8_t *out, size_t outcap)
{
    return _canonical(carrier_uuid, community, NULL, seq, ts, bundle,
                      AT_COMMUNITY_POLICY_BUNDLE_MAX, out, outcap);
}

int at_policy_ad_id(const uuid_t carrier_uuid, const char *community, int64_t seq,
                    double ts, const char *bundle, char *id_hex_out)
{
    uint8_t canon[AT_POLICY_AD_CANON_MAX];
    return _id(canon, at_policy_ad_canonical(carrier_uuid, community, seq, ts,
                                             bundle, canon, sizeof(canon)),
               id_hex_out);
}

int at_policy_ad_sign(const unsigned char sk[crypto_sign_SECRETKEYBYTES],
                      const uuid_t carrier_uuid, const char *community,
                      int64_t seq, double ts, const char *bundle,
                      char *sig_hex_out)
{
    uint8_t canon[AT_POLICY_AD_CANON_MAX];
    return _sign(sk, canon, at_policy_ad_canonical(carrier_uuid, community, seq,
                                                   ts, bundle, canon, sizeof(canon)),
                 sig_hex_out);
}

bool at_policy_ad_verify(const unsigned char pk[crypto_sign_PUBLICKEYBYTES],
                         const uuid_t carrier_uuid, const char *community,
                         int64_t seq, double ts, const char *bundle,
                         const char *sig_hex)
{
    uint8_t canon[AT_POLICY_AD_CANON_MAX];
    return _verify(pk, canon, at_policy_ad_canonical(carrier_uuid, community, seq,
                                                     ts, bundle, canon, sizeof(canon)),
                   sig_hex);
}

json_t *at_policy_ad_to_json(const uuid_t carrier_uuid, const char *carrier_pk_hex,
                             const char *community, int64_t seq, double ts,
                             const char *bundle, const char *sig_hex)
{
    char did[AT_COMMUNITY_DID_MAX + 1];
    at_community_bound_did(community, did, sizeof(did));
    char bnd[AT_COMMUNITY_POLICY_BUNDLE_MAX + 1];
    at_community_bound_policy(bundle, bnd, sizeof(bnd));
    char who[UUID_STRING_LEN + 1];
    uuid_unparse_lower(carrier_uuid, who);
    json_t *env = json_object();
    if (env == NULL) return NULL;
    if (json_object_set_new(env, "carrier", json_string(who)) != 0
        || json_object_set_new(env, "carrier_pk",
                               json_string(carrier_pk_hex ? carrier_pk_hex : "")) != 0
        || json_object_set_new(env, "community", json_string(did)) != 0
        || json_object_set_new(env, "seq", json_integer((json_int_t)seq)) != 0
        || json_object_set_new(env, "ts", json_real(ts)) != 0
        || json_object_set_new(env, "bundle", json_string(bnd)) != 0
        || json_object_set_new(env, "sig", json_string(sig_hex ? sig_hex : "")) != 0) {
        json_decref(env);
        return NULL;
    }
    return env;
}

/* Shared envelope checks: uuid, key and signature shape, and a non-empty
 * community and bundle within their bounds. */
static int _common_from_json(const json_t *obj, const char *who_key,
                             const char *pk_key, uuid_t who_out,
                             char pk_out[AT_COMMUNITY_SIG_HEX_LEN + 1],
                             char *community_out, size_t community_sz,
                             int64_t *seq_out, double *ts_out,
                             char *bundle_out, size_t bundle_sz, size_t bundle_cap,
                             char sig_out[AT_COMMUNITY_SIG_HEX_LEN + 1])
{
    if (community_out != NULL && community_sz > 0) community_out[0] = '\0';
    if (bundle_out != NULL && bundle_sz > 0) bundle_out[0] = '\0';
    if (pk_out != NULL) pk_out[0] = '\0';
    if (sig_out != NULL) sig_out[0] = '\0';
    if (obj == NULL || !json_is_object(obj)) return -1;
    const json_t *j_who = json_object_get(obj, who_key);
    const json_t *j_pk  = json_object_get(obj, pk_key);
    const json_t *j_com = json_object_get(obj, "community");
    const json_t *j_seq = json_object_get(obj, "seq");
    const json_t *j_ts  = json_object_get(obj, "ts");
    const json_t *j_bnd = json_object_get(obj, "bundle");
    const json_t *j_sig = json_object_get(obj, "sig");
    if (!json_is_string(j_who) || !json_is_string(j_pk) || !json_is_string(j_com)
        || !json_is_integer(j_seq) || !json_is_number(j_ts)
        || !json_is_string(j_bnd) || !json_is_string(j_sig))
        return -1;
    if (uuid_parse(json_string_value(j_who), who_out) != 0) return -1;
    const char *pk = json_string_value(j_pk);
    const char *sg = json_string_value(j_sig);
    if (strlen(pk) != PK_HEX_LEN || strlen(sg) != AT_COMMUNITY_SIG_HEX_LEN) return -1;
    /* An empty community would let two communities collide in the follow gate;
     * an over-long one or bundle would be truncated into bytes nobody signed. */
    size_t clen = strlen(json_string_value(j_com));
    size_t blen = strlen(json_string_value(j_bnd));
    if (clen == 0 || clen > AT_COMMUNITY_DID_MAX || blen == 0 || blen > bundle_cap)
        return -1;
    if (pk_out != NULL) { memcpy(pk_out, pk, PK_HEX_LEN); pk_out[PK_HEX_LEN] = '\0'; }
    if (sig_out != NULL) {
        memcpy(sig_out, sg, AT_COMMUNITY_SIG_HEX_LEN);
        sig_out[AT_COMMUNITY_SIG_HEX_LEN] = '\0';
    }
    bound_copy(json_string_value(j_com), community_out, community_sz, AT_COMMUNITY_DID_MAX);
    bound_copy(json_string_value(j_bnd), bundle_out, bundle_sz, bundle_cap);
    if (seq_out != NULL) *seq_out = (int64_t)json_integer_value(j_seq);
    if (ts_out != NULL) *ts_out = json_number_value(j_ts);
    return 0;
}

int at_policy_ad_from_json(const json_t *obj, uuid_t carrier_out,
                           char carrier_pk_out[AT_COMMUNITY_SIG_HEX_LEN + 1],
                           char *community_out, size_t community_sz,
                           int64_t *seq_out, double *ts_out,
                           char *bundle_out, size_t bundle_sz,
                           char sig_out[AT_COMMUNITY_SIG_HEX_LEN + 1])
{
    return _common_from_json(obj, "carrier", "carrier_pk", carrier_out,
                             carrier_pk_out, community_out, community_sz, seq_out,
                             ts_out, bundle_out, bundle_sz,
                             AT_COMMUNITY_POLICY_BUNDLE_MAX, sig_out);
}

/* ---- The post label --------------------------------------------------------- */

size_t at_post_label_canonical(const uuid_t author_uuid, const char *community,
                               const char *post_id, int64_t seq, double ts,
                               const char *bundle, uint8_t *out, size_t outcap)
{
    if (post_id == NULL) return (size_t)-1;
    return _canonical(author_uuid, community, post_id, seq, ts, bundle,
                      AT_POST_LABEL_BUNDLE_MAX, out, outcap);
}

int at_post_label_id(const uuid_t author_uuid, const char *community,
                     const char *post_id, int64_t seq, double ts,
                     const char *bundle, char *id_hex_out)
{
    uint8_t canon[AT_POST_LABEL_CANON_MAX];
    return _id(canon, at_post_label_canonical(author_uuid, community, post_id, seq,
                                              ts, bundle, canon, sizeof(canon)),
               id_hex_out);
}

int at_post_label_sign(const unsigned char sk[crypto_sign_SECRETKEYBYTES],
                       const uuid_t author_uuid, const char *community,
                       const char *post_id, int64_t seq, double ts,
                       const char *bundle, char *sig_hex_out)
{
    uint8_t canon[AT_POST_LABEL_CANON_MAX];
    return _sign(sk, canon, at_post_label_canonical(author_uuid, community, post_id,
                                                    seq, ts, bundle, canon,
                                                    sizeof(canon)),
                 sig_hex_out);
}

bool at_post_label_verify(const unsigned char pk[crypto_sign_PUBLICKEYBYTES],
                          const uuid_t author_uuid, const char *community,
                          const char *post_id, int64_t seq, double ts,
                          const char *bundle, const char *sig_hex)
{
    uint8_t canon[AT_POST_LABEL_CANON_MAX];
    return _verify(pk, canon, at_post_label_canonical(author_uuid, community,
                                                      post_id, seq, ts, bundle,
                                                      canon, sizeof(canon)),
                   sig_hex);
}

json_t *at_post_label_to_json(const uuid_t author_uuid, const char *author_pk_hex,
                              const char *community, const char *post_id,
                              int64_t seq, double ts, const char *bundle,
                              const char *sig_hex, int hops)
{
    char did[AT_COMMUNITY_DID_MAX + 1];
    at_community_bound_did(community, did, sizeof(did));
    char bnd[AT_POST_LABEL_BUNDLE_MAX + 1];
    at_community_bound_label(bundle, bnd, sizeof(bnd));
    char who[UUID_STRING_LEN + 1];
    uuid_unparse_lower(author_uuid, who);
    json_t *env = json_object();
    if (env == NULL) return NULL;
    if (json_object_set_new(env, "author", json_string(who)) != 0
        || json_object_set_new(env, "author_pk",
                               json_string(author_pk_hex ? author_pk_hex : "")) != 0
        || json_object_set_new(env, "community", json_string(did)) != 0
        || json_object_set_new(env, "post_id", json_string(post_id ? post_id : "")) != 0
        || json_object_set_new(env, "seq", json_integer((json_int_t)seq)) != 0
        || json_object_set_new(env, "ts", json_real(ts)) != 0
        || json_object_set_new(env, "bundle", json_string(bnd)) != 0
        || json_object_set_new(env, "sig", json_string(sig_hex ? sig_hex : "")) != 0
        || json_object_set_new(env, "hops", json_integer(hops)) != 0) {
        json_decref(env);
        return NULL;
    }
    return env;
}

int at_post_label_from_json(const json_t *obj, uuid_t author_out,
                            char author_pk_out[AT_COMMUNITY_SIG_HEX_LEN + 1],
                            char *community_out, size_t community_sz,
                            char post_id_out[AT_COMMUNITY_ID_HEX_LEN + 1],
                            int64_t *seq_out, double *ts_out,
                            char *bundle_out, size_t bundle_sz,
                            char sig_out[AT_COMMUNITY_SIG_HEX_LEN + 1],
                            int *hops_out)
{
    if (post_id_out != NULL) post_id_out[0] = '\0';
    if (_common_from_json(obj, "author", "author_pk", author_out, author_pk_out,
                          community_out, community_sz, seq_out, ts_out,
                          bundle_out, bundle_sz, AT_POST_LABEL_BUNDLE_MAX,
                          sig_out) != 0)
        return -1;
    const json_t *j_pid  = json_object_get(obj, "post_id");
    const json_t *j_hops = json_object_get(obj, "hops");
    if (!json_is_string(j_pid) || !json_is_integer(j_hops)) return -1;
    if (!at_community_post_id_valid(json_string_value(j_pid))) return -1;
    json_int_t hops = json_integer_value(j_hops);
    if (hops < 0 || hops > INT32_MAX) return -1;
    if (post_id_out != NULL) {
        memcpy(post_id_out, json_string_value(j_pid), AT_COMMUNITY_ID_HEX_LEN);
        post_id_out[AT_COMMUNITY_ID_HEX_LEN] = '\0';
    }
    if (hops_out != NULL) *hops_out = (int)hops;
    return 0;
}
