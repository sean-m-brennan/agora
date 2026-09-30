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
 * @file post_scope_test.c
 * @brief A post in a community's name (Phase 4, Ethne D37): the signed scope
 *        trailer, its bounds, and that an unscoped post is unchanged.
 *
 * The canonical bytes, content id and signature below are PINNED and MUST match
 * the Python twin (tests/a_unit/test_post_scope.py), which asserts the same
 * literals — the cross-language guard the signed scope depends on.
 */

#define DEBUG_TESTS 1
#include "test_setup.h"

#include <string.h>
#include <sodium.h>

#include "social/post.h"

#define DID "did:key:z6MkvZr75pe3PnPy11ixErx25xJ83E6MkqQQc4JpRogj3ytJ"

/* post_test.c's reference post ("hi", seq 7, tier 2, author bytes 0..15) made
 * in community DID with labels nsfw and spoiler. */
static const char *const SCOPED_CANON_HEX =
    "000102030405060708090a0b0c0d0e0f"  /* author uuid */
    "0700000000000000"                  /* seq = 7 */
    "0000000000000000"                  /* ts = 0.0 */
    "02"                                /* tier = 2 */
    "02000000" "6869"                   /* body "hi" */
    "01"                                /* scope version */
    "3800"                              /* did_len = 56 (u16 le) */
    "6469643a6b65793a7a364d6b765a723735706533506e5079313169784572783235784a38"
    "3345364d6b71515163344a70526f676a3379744a"
    "02"                                /* two labels */
    "04" "6e736677"                     /* nsfw */
    "07" "73706f696c6572";              /* spoiler */
static const char *const SCOPED_ID_HEX =
    "004798b4ae862cb2b45b8a52cc7fbedc3dd067fbc55c68c63955b72edda19278";
static const char *const SCOPED_SIG_HEX =
    "ddbd7c978c0085c6168f0e8560c7ed42271a1fe58c4abb23baac619f4ad8b8c0"
    "1b2a871a58c02e8f2cb0a3a0df7e2c844b79cd4d4248412c5443f93befd17d0d";
/* post_test.c's REF_ID_HEX: an unscoped post keeps it. */
static const char *const UNSCOPED_ID_HEX =
    "cea547b388f5ad97fa994ce0cbfff1bf62b679ff5a0c4eb6202b51c4c7513e7c";

static void ref_author(uuid_t u) { for (int i = 0; i < 16; i++) u[i] = (uint8_t)i; }
static void ref_keys(unsigned char pk[crypto_sign_PUBLICKEYBYTES],
                     unsigned char sk[crypto_sign_SECRETKEYBYTES])
{
    unsigned char seed[crypto_sign_SEEDBYTES];
    for (size_t i = 0; i < crypto_sign_SEEDBYTES; i++) seed[i] = (unsigned char)(i + 1);
    crypto_sign_seed_keypair(pk, sk, seed);
}

static at_post_scope_t ref_scope(void)
{
    at_post_scope_t s;
    memset(&s, 0, sizeof(s));
    snprintf(s.community, sizeof(s.community), "%s", DID);
    s.n_labels = 2;
    snprintf(s.labels[0], sizeof(s.labels[0]), "nsfw");
    snprintf(s.labels[1], sizeof(s.labels[1]), "spoiler");
    return s;
}

DEFINE_TEST(test_scoped_canonical_matches_pinned_vector)
{
    uuid_t a; ref_author(a);
    at_post_scope_t s = ref_scope();
    uint8_t canon[AT_POST_CANON_MAX];
    size_t clen = at_post_canonical_scoped(a, 7, 0.0, 2, "hi", &s, canon, sizeof(canon));
    ck_assert(clen != (size_t)-1);
    char hex[2 * AT_POST_CANON_MAX + 1];
    sodium_bin2hex(hex, sizeof(hex), canon, clen);
    ck_assert_str_eq(hex, SCOPED_CANON_HEX);
    char id[AT_POST_ID_HEX_LEN + 1];
    ck_assert_int_eq(at_post_content_id_scoped(a, 7, 0.0, 2, "hi", &s, id), 0);
    ck_assert_str_eq(id, SCOPED_ID_HEX);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_an_unscoped_post_is_unchanged)
{
    uuid_t a; ref_author(a);
    at_post_scope_t none;
    memset(&none, 0, sizeof(none));
    char id[AT_POST_ID_HEX_LEN + 1];
    ck_assert_int_eq(at_post_content_id_scoped(a, 7, 0.0, 2, "hi", &none, id), 0);
    ck_assert_str_eq(id, UNSCOPED_ID_HEX);
    ck_assert_int_eq(at_post_content_id_scoped(a, 7, 0.0, 2, "hi", NULL, id), 0);
    ck_assert_str_eq(id, UNSCOPED_ID_HEX);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_the_signature_covers_the_scope)
{
    uuid_t a; ref_author(a);
    unsigned char pk[crypto_sign_PUBLICKEYBYTES], sk[crypto_sign_SECRETKEYBYTES];
    ref_keys(pk, sk);
    at_post_scope_t s = ref_scope();
    char sig[AT_POST_SIG_HEX_LEN + 1];
    ck_assert_int_eq(at_post_sign_scoped(sk, a, 7, 0.0, 2, "hi", &s, sig), 0);
    ck_assert_str_eq(sig, SCOPED_SIG_HEX);
    ck_assert(at_post_verify_scoped(pk, a, 7, 0.0, 2, "hi", &s, sig));

    /* A relay that strips the scope, drops a label, adds one, or moves the post
     * to another community breaks the signature. */
    ck_assert(!at_post_verify_scoped(pk, a, 7, 0.0, 2, "hi", NULL, sig));
    at_post_scope_t t = s;
    t.n_labels = 1;
    ck_assert(!at_post_verify_scoped(pk, a, 7, 0.0, 2, "hi", &t, sig));
    t = s;
    t.n_labels = 3;
    snprintf(t.labels[2], sizeof(t.labels[2]), "gore");
    ck_assert(!at_post_verify_scoped(pk, a, 7, 0.0, 2, "hi", &t, sig));
    t = s;
    t.community[8] = 'Y';
    ck_assert(!at_post_verify_scoped(pk, a, 7, 0.0, 2, "hi", &t, sig));
}
END_TEST_DEFINITION()

DEFINE_TEST(test_labels_are_bounded_and_need_a_community)
{
    ck_assert(at_post_label_valid("nsfw"));
    ck_assert(at_post_label_valid("content-warning_2"));
    ck_assert(!at_post_label_valid(""));
    ck_assert(!at_post_label_valid("NSFW"));
    ck_assert(!at_post_label_valid("two words"));
    ck_assert(!at_post_label_valid("a,b"));
    ck_assert(at_post_label_valid("0123456789abcdef0123456789abcdef"));   /* 32 */
    ck_assert(!at_post_label_valid("0123456789abcdef0123456789abcdef0")); /* 33 */

    at_post_scope_t s;
    memset(&s, 0, sizeof(s));
    ck_assert(at_post_scope_valid(&s));
    s.n_labels = 1;
    snprintf(s.labels[0], sizeof(s.labels[0]), "nsfw");
    ck_assert(!at_post_scope_valid(&s));      /* labels need a community */
    snprintf(s.community, sizeof(s.community), "%s", DID);
    ck_assert(at_post_scope_valid(&s));
    s.n_labels = AT_POST_LABELS_MAX + 1;
    ck_assert(!at_post_scope_valid(&s));

    /* A scope that cannot be signed has no canonical form at all. */
    uuid_t a; ref_author(a);
    uint8_t canon[AT_POST_CANON_MAX];
    ck_assert(at_post_canonical_scoped(a, 7, 0.0, 2, "hi", &s, canon, sizeof(canon))
              == (size_t)-1);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_normalize_sorts_and_dedups)
{
    at_post_scope_t s;
    memset(&s, 0, sizeof(s));
    snprintf(s.community, sizeof(s.community), "%s", DID);
    const char *in[] = { "spoiler", "nsfw", "spoiler", "art" };
    for (int i = 0; i < 4; i++)
        snprintf(s.labels[s.n_labels++], AT_POST_LABEL_MAX + 1, "%s", in[i]);
    at_post_scope_normalize(&s);
    ck_assert_int_eq(s.n_labels, 3);
    char joined[64];
    at_post_scope_labels_joined(&s, joined, sizeof(joined));
    ck_assert_str_eq(joined, "art,nsfw,spoiler");
}
END_TEST_DEFINITION()

DEFINE_TEST(test_scoped_wire_json_round_trips)
{
    uuid_t a; ref_author(a);
    unsigned char pk[crypto_sign_PUBLICKEYBYTES], sk[crypto_sign_SECRETKEYBYTES];
    ref_keys(pk, sk);
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    sodium_bin2hex(pk_hex, sizeof(pk_hex), pk, sizeof(pk));
    at_post_scope_t s = ref_scope();
    char sig[AT_POST_SIG_HEX_LEN + 1];
    ck_assert_int_eq(at_post_sign_scoped(sk, a, 7, 0.0, 2, "hi", &s, sig), 0);
    json_t *env = at_post_to_json_scoped(a, pk_hex, 7, 0.0, 2, "hi", &s, sig, 0);
    ck_assert_ptr_nonnull(env);
    ck_assert_str_eq(json_string_value(json_object_get(env, "community")), DID);
    ck_assert_int_eq((int)json_array_size(json_object_get(env, "labels")), 2);

    uuid_t ao; char pko[AT_POST_SIG_HEX_LEN + 1], sgo[AT_POST_SIG_HEX_LEN + 1];
    char body[AT_POST_BODY_MAX + 1];
    int64_t seq = 0; double ts = 0; uint8_t tier = 0; int hops = 0;
    at_post_scope_t so;
    ck_assert_int_eq(at_post_from_json_scoped(env, ao, pko, &seq, &ts, &tier, body,
                                              sizeof(body), &so, sgo, &hops), 0);
    ck_assert_str_eq(so.community, DID);
    ck_assert_int_eq(so.n_labels, 2);
    ck_assert(at_post_verify_scoped(pk, ao, seq, ts, tier, body, &so, sgo));
    json_decref(env);

    /* An unscoped post's envelope has neither key. */
    json_t *plain = at_post_to_json_scoped(a, pk_hex, 7, 0.0, 2, "hi", NULL, sig, 0);
    ck_assert(json_object_get(plain, "community") == NULL);
    ck_assert(json_object_get(plain, "labels") == NULL);
    json_decref(plain);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_a_malformed_scope_is_refused)
{
    uuid_t a; ref_author(a);
    char pk_hex[crypto_sign_PUBLICKEYBYTES * 2 + 1];
    memset(pk_hex, 'a', sizeof(pk_hex) - 1); pk_hex[sizeof(pk_hex) - 1] = '\0';
    char sig_hex[AT_POST_SIG_HEX_LEN + 1];
    memset(sig_hex, 'b', AT_POST_SIG_HEX_LEN); sig_hex[AT_POST_SIG_HEX_LEN] = '\0';
    uuid_t ao; char pko[AT_POST_SIG_HEX_LEN + 1], sgo[AT_POST_SIG_HEX_LEN + 1];
    char body[AT_POST_BODY_MAX + 1];
    int64_t seq = 0; double ts = 0; uint8_t tier = 0; int hops = 0;
    at_post_scope_t so;

    const char *bad[] = {
        "{\"labels\":[\"nsfw\"]}",                          /* labels, no community */
        "{\"community\":\"\",\"labels\":[]}",               /* empty community */
        "{\"community\":\"" DID "\",\"labels\":[\"NSFW\"]}", /* bad label */
        "{\"community\":\"" DID "\",\"labels\":\"nsfw\"}",   /* not an array */
        "{\"community\":\"" DID "\",\"labels\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\"]}",
    };
    for (size_t i = 0; i < sizeof(bad) / sizeof(*bad); i++) {
        json_t *env = at_post_to_json(a, pk_hex, 1, 0.0, 0, "hi", sig_hex, 0);
        json_t *extra = json_loads(bad[i], 0, NULL);
        ck_assert_ptr_nonnull(extra);
        json_object_update(env, extra);
        json_decref(extra);
        ck_assert_ret_nonzero(at_post_from_json_scoped(env, ao, pko, &seq, &ts, &tier,
                                                       body, sizeof(body), &so, sgo,
                                                       &hops));
        /* The unscoped reader refuses it too, rather than verifying a post whose
         * signed bytes it cannot reproduce. */
        ck_assert_ret_nonzero(at_post_from_json(env, ao, pko, &seq, &ts, &tier, body,
                                                sizeof(body), sgo, &hops));
        json_decref(env);
    }
}
END_TEST_DEFINITION()

RUN_TESTS(PostScope,
          test_scoped_canonical_matches_pinned_vector,
          test_an_unscoped_post_is_unchanged,
          test_the_signature_covers_the_scope,
          test_labels_are_bounded_and_need_a_community,
          test_normalize_sorts_and_dedups,
          test_scoped_wire_json_round_trips,
          test_a_malformed_scope_is_refused)
