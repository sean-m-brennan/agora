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
 * @file community_test.c
 * @brief The policy ad and the post label (Phase 4, Ethne D37): canonical
 *        forms, content ids, signatures and envelopes. The canonical bytes and
 *        ids are PINNED and MUST match tests/a_unit/test_community_codec.py.
 */

#define DEBUG_TESTS 1
#include "test_setup.h"

#include <string.h>
#include <sodium.h>

#include "social/community.h"

#define DID "did:key:z6MkvZr75pe3PnPy11ixErx25xJ83E6MkqQQc4JpRogj3ytJ"
#define POST "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

static const char *const POLICY_CANON_HEX =
    "000102030405060708090a0b0c0d0e0f"  /* carrier uuid */
    "38000000"                          /* did_len = 56 (u32 le) */
    "6469643a6b65793a7a364d6b765a723735706533506e5079313169784572783235784a38"
    "3345364d6b71515163344a70526f676a3379744a"
    "0300000000000000"                  /* seq = 3 */
    "0000000000000000"                  /* ts = 0.0 */
    "07000000" "7b2270223a317d";        /* bundle {"p":1} */
static const char *const POLICY_ID_HEX =
    "2366865e4adc460c0c88b27a0d8f28ab0b39b72920689dd6c844d8f9cc8886bd";
static const char *const LABEL_CANON_HEX =
    "000102030405060708090a0b0c0d0e0f"
    "38000000"
    "6469643a6b65793a7a364d6b765a723735706533506e5079313169784572783235784a38"
    "3345364d6b71515163344a70526f676a3379744a"
    "61616161616161616161616161616161616161616161616161616161616161616161616161"
    "616161616161616161616161616161616161616161616161616161"   /* post id, ASCII */
    "0200000000000000"                  /* seq = 2 */
    "0000000000000000"
    "07000000" "7b226c223a317d";        /* bundle {"l":1} */
static const char *const LABEL_ID_HEX =
    "c01a4cf23de76552d184a670c9f79a0b1d9ae0ff4ac0a4cd20ee79a08531f505";

static void ref_uuid(uuid_t u) { for (int i = 0; i < 16; i++) u[i] = (uint8_t)i; }
static void ref_keys(unsigned char pk[crypto_sign_PUBLICKEYBYTES],
                     unsigned char sk[crypto_sign_SECRETKEYBYTES])
{
    unsigned char seed[crypto_sign_SEEDBYTES];
    for (size_t i = 0; i < crypto_sign_SEEDBYTES; i++) seed[i] = (unsigned char)(i + 1);
    crypto_sign_seed_keypair(pk, sk, seed);
}

DEFINE_TEST(test_policy_ad_matches_pinned_vector)
{
    uuid_t c; ref_uuid(c);
    uint8_t canon[AT_POLICY_AD_CANON_MAX];
    size_t n = at_policy_ad_canonical(c, DID, 3, 0.0, "{\"p\":1}", canon, sizeof(canon));
    ck_assert(n != (size_t)-1);
    char hex[2 * AT_POLICY_AD_CANON_MAX + 1];
    sodium_bin2hex(hex, sizeof(hex), canon, n);
    ck_assert_str_eq(hex, POLICY_CANON_HEX);
    char id[AT_COMMUNITY_ID_HEX_LEN + 1];
    ck_assert_int_eq(at_policy_ad_id(c, DID, 3, 0.0, "{\"p\":1}", id), 0);
    ck_assert_str_eq(id, POLICY_ID_HEX);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_post_label_matches_pinned_vector)
{
    uuid_t a; ref_uuid(a);
    uint8_t canon[AT_POST_LABEL_CANON_MAX];
    size_t n = at_post_label_canonical(a, DID, POST, 2, 0.0, "{\"l\":1}", canon,
                                       sizeof(canon));
    ck_assert(n != (size_t)-1);
    char hex[2 * AT_POST_LABEL_CANON_MAX + 1];
    sodium_bin2hex(hex, sizeof(hex), canon, n);
    ck_assert_str_eq(hex, LABEL_CANON_HEX);
    char id[AT_COMMUNITY_ID_HEX_LEN + 1];
    ck_assert_int_eq(at_post_label_id(a, DID, POST, 2, 0.0, "{\"l\":1}", id), 0);
    ck_assert_str_eq(id, LABEL_ID_HEX);
    /* A label must name a real post id. */
    ck_assert(at_post_label_canonical(a, DID, "nope", 2, 0.0, "{}", canon, sizeof(canon))
              == (size_t)-1);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_signatures_bind_every_field)
{
    uuid_t a; ref_uuid(a);
    unsigned char pk[crypto_sign_PUBLICKEYBYTES], sk[crypto_sign_SECRETKEYBYTES];
    ref_keys(pk, sk);
    char sig[AT_COMMUNITY_SIG_HEX_LEN + 1];
    ck_assert_int_eq(at_policy_ad_sign(sk, a, DID, 3, 0.0, "{\"p\":1}", sig), 0);
    ck_assert(at_policy_ad_verify(pk, a, DID, 3, 0.0, "{\"p\":1}", sig));
    ck_assert(!at_policy_ad_verify(pk, a, DID, 4, 0.0, "{\"p\":1}", sig));
    ck_assert(!at_policy_ad_verify(pk, a, DID, 3, 0.0, "{\"p\":2}", sig));
    ck_assert(!at_policy_ad_verify(pk, a, "did:key:other", 3, 0.0, "{\"p\":1}", sig));

    ck_assert_int_eq(at_post_label_sign(sk, a, DID, POST, 2, 0.0, "{\"l\":1}", sig), 0);
    ck_assert(at_post_label_verify(pk, a, DID, POST, 2, 0.0, "{\"l\":1}", sig));
    char other[] = POST;
    other[0] = 'b';
    ck_assert(!at_post_label_verify(pk, a, DID, other, 2, 0.0, "{\"l\":1}", sig));
    ck_assert(!at_post_label_verify(pk, a, DID, POST, 3, 0.0, "{\"l\":1}", sig));
}
END_TEST_DEFINITION()

DEFINE_TEST(test_envelopes_round_trip)
{
    uuid_t a; ref_uuid(a);
    unsigned char pk[crypto_sign_PUBLICKEYBYTES], sk[crypto_sign_SECRETKEYBYTES];
    ref_keys(pk, sk);
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    sodium_bin2hex(pk_hex, sizeof(pk_hex), pk, sizeof(pk));
    char sig[AT_COMMUNITY_SIG_HEX_LEN + 1];

    ck_assert_int_eq(at_policy_ad_sign(sk, a, DID, 3, 0.0, "{\"p\":1}", sig), 0);
    json_t *env = at_policy_ad_to_json(a, pk_hex, DID, 3, 0.0, "{\"p\":1}", sig);
    uuid_t w; char pko[AT_COMMUNITY_SIG_HEX_LEN + 1], sgo[AT_COMMUNITY_SIG_HEX_LEN + 1];
    char did[AT_COMMUNITY_DID_MAX + 1], bundle[AT_COMMUNITY_POLICY_BUNDLE_MAX + 1];
    int64_t seq = 0; double ts = 1;
    ck_assert_int_eq(at_policy_ad_from_json(env, w, pko, did, sizeof(did), &seq, &ts,
                                            bundle, sizeof(bundle), sgo), 0);
    ck_assert(at_policy_ad_verify(pk, w, did, seq, ts, bundle, sgo));
    json_decref(env);

    ck_assert_int_eq(at_post_label_sign(sk, a, DID, POST, 2, 0.0, "{\"l\":1}", sig), 0);
    env = at_post_label_to_json(a, pk_hex, DID, POST, 2, 0.0, "{\"l\":1}", sig, 1);
    char pid[AT_COMMUNITY_ID_HEX_LEN + 1], lb[AT_POST_LABEL_BUNDLE_MAX + 1];
    int hops = 0;
    ck_assert_int_eq(at_post_label_from_json(env, w, pko, did, sizeof(did), pid, &seq,
                                             &ts, lb, sizeof(lb), sgo, &hops), 0);
    ck_assert_str_eq(pid, POST);
    ck_assert_int_eq(hops, 1);
    ck_assert(at_post_label_verify(pk, w, did, pid, seq, ts, lb, sgo));
    json_decref(env);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_malformed_envelopes_are_refused)
{
    uuid_t a; ref_uuid(a);
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    memset(pk_hex, 'a', sizeof(pk_hex) - 1); pk_hex[sizeof(pk_hex) - 1] = '\0';
    char sig[AT_COMMUNITY_SIG_HEX_LEN + 1];
    memset(sig, 'b', AT_COMMUNITY_SIG_HEX_LEN); sig[AT_COMMUNITY_SIG_HEX_LEN] = '\0';
    uuid_t w; char pko[AT_COMMUNITY_SIG_HEX_LEN + 1], sgo[AT_COMMUNITY_SIG_HEX_LEN + 1];
    char did[AT_COMMUNITY_DID_MAX + 1], bundle[AT_COMMUNITY_POLICY_BUNDLE_MAX + 1];
    char pid[AT_COMMUNITY_ID_HEX_LEN + 1];
    int64_t seq = 0; double ts = 0; int hops = 0;

    /* An empty community or bundle. */
    json_t *env = at_policy_ad_to_json(a, pk_hex, "", 3, 0.0, "{}", sig);
    ck_assert_ret_nonzero(at_policy_ad_from_json(env, w, pko, did, sizeof(did), &seq,
                                                 &ts, bundle, sizeof(bundle), sgo));
    json_decref(env);
    env = at_policy_ad_to_json(a, pk_hex, DID, 3, 0.0, "", sig);
    ck_assert_ret_nonzero(at_policy_ad_from_json(env, w, pko, did, sizeof(did), &seq,
                                                 &ts, bundle, sizeof(bundle), sgo));
    json_decref(env);

    /* A label for no real post, and a negative hop count. */
    env = at_post_label_to_json(a, pk_hex, DID, "not-a-post", 2, 0.0, "{}", sig, 0);
    ck_assert_ret_nonzero(at_post_label_from_json(env, w, pko, did, sizeof(did), pid,
                                                  &seq, &ts, bundle, sizeof(bundle),
                                                  sgo, &hops));
    json_decref(env);
    env = at_post_label_to_json(a, pk_hex, DID, POST, 2, 0.0, "{}", sig, -1);
    ck_assert_ret_nonzero(at_post_label_from_json(env, w, pko, did, sizeof(did), pid,
                                                  &seq, &ts, bundle, sizeof(bundle),
                                                  sgo, &hops));
    json_decref(env);

    /* An over-long label bundle is refused, not truncated into unsigned bytes. */
    static char big[AT_POST_LABEL_BUNDLE_MAX + 8];
    memset(big, 'x', sizeof(big) - 1);
    big[sizeof(big) - 1] = '\0';
    env = at_post_label_to_json(a, pk_hex, DID, POST, 2, 0.0, "{}", sig, 0);
    json_object_set_new(env, "bundle", json_string(big));
    ck_assert_ret_nonzero(at_post_label_from_json(env, w, pko, did, sizeof(did), pid,
                                                  &seq, &ts, bundle, sizeof(bundle),
                                                  sgo, &hops));
    json_decref(env);
}
END_TEST_DEFINITION()

RUN_TESTS(Community,
          test_policy_ad_matches_pinned_vector,
          test_post_label_matches_pinned_vector,
          test_signatures_bind_every_field,
          test_envelopes_round_trip,
          test_malformed_envelopes_are_refused)
