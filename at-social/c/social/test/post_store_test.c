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

/** @file The store store-and-forward serves from (Agora Phase 4 DDIL).
 *
 *  What the digest may offer is decided here, so the three properties a heal
 *  depends on are pinned directly: the store is bounded and evicts its OLDEST
 *  entry; only posts younger than the window are offered, newest first by the
 *  post's own timestamp (not by arrival: a backfilled old post must not crowd a
 *  fresh one out of a capped digest); and a FULL digest still fits in one UDP
 *  datagram, which truncates rather than fragments (net_transport_udp.c).
 */

#define DEBUG_TESTS 1
#include "test_setup.h"

#include <stdio.h>
#include <string.h>
#include <uuid/uuid.h>
#include <jansson.h>

#include "social/post_store.h"

static void _id(int n, char out[POST_STORE_ID_LEN + 1])
{
    snprintf(out, POST_STORE_ID_LEN + 1, "%064x", n);
}

DEFINE_TEST(test_post_store_is_bounded_and_evicts_the_oldest)
{
    post_store_t s;
    post_store_init(&s);
    uuid_t a;
    uuid_generate(a);
    char id[POST_STORE_ID_LEN + 1];
    for (int i = 0; i < POST_STORE_CAP + 5; i++) {
        _id(i, id);
        ck_assert_int_eq(post_store_put(&s, id, 1000.0 + i, a, "{\"x\":1}"), 0);
    }
    ck_assert_int_eq((int)s.count, POST_STORE_CAP);
    for (int i = 0; i < 5; i++) {
        _id(i, id);
        ck_assert(post_store_get(&s, id) == NULL);        /* the oldest went */
    }
    _id(5, id);
    ck_assert(post_store_get(&s, id) != NULL);
    _id(POST_STORE_CAP + 4, id);
    const post_store_entry_t *e = post_store_get(&s, id);
    ck_assert(e != NULL);
    ck_assert_str_eq(e->envelope, "{\"x\":1}");
    ck_assert(uuid_compare(e->author, a) == 0);

    /* A known id is left as it is. */
    ck_assert_int_eq(post_store_put(&s, id, 1.0, a, "{\"y\":2}"), 0);
    ck_assert_str_eq(post_store_get(&s, id)->envelope, "{\"x\":1}");
    /* Bad input changes nothing. */
    ck_assert_int_eq(post_store_put(&s, "short", 1.0, a, "{}"), -1);
    ck_assert_int_eq(post_store_put(&s, id, 1.0, a, NULL), -1);

    post_store_clear(&s);
    ck_assert_int_eq((int)s.count, 0);
    ck_assert(post_store_get(&s, id) == NULL);
    post_store_clear(&s);   /* idempotent */
}
END_TEST_DEFINITION()

DEFINE_TEST(test_post_store_digest_is_the_window_newest_first)
{
    post_store_t s;
    post_store_init(&s);
    uuid_t a;
    uuid_generate(a);
    char id[POST_STORE_ID_LEN + 1];
    /* Arrival order 0,1,2,3; post timestamps 500, 90 (too old), 700, 600. */
    const double ts[] = { 500.0, 90.0, 700.0, 600.0 };
    for (int i = 0; i < 4; i++) {
        _id(i, id);
        post_store_put(&s, id, ts[i], a, "{}");
    }
    char out[4][POST_STORE_ID_LEN + 1];
    size_t n = post_store_digest(&s, 1000.0, 600.0, out, 4);   /* ts > 400 */
    ck_assert_int_eq((int)n, 3);
    _id(2, id); ck_assert_str_eq(out[0], id);   /* 700 */
    _id(3, id); ck_assert_str_eq(out[1], id);   /* 600 */
    _id(0, id); ck_assert_str_eq(out[2], id);   /* 500 */
    /* A cap takes the newest. */
    n = post_store_digest(&s, 1000.0, 600.0, out, 1);
    ck_assert_int_eq((int)n, 1);
    _id(2, id); ck_assert_str_eq(out[0], id);
    /* Nothing in the window, nothing offered. */
    ck_assert_int_eq((int)post_store_digest(&s, 1e9, 600.0, out, 4), 0);
    post_store_clear(&s);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_a_full_digest_fits_one_datagram)
{
    /* 256 feed + 256 business ids, as id_social.c packs them, base64'd as the
     * JSON wire format carries a payload (net_message.c), plus a generous 1 KB
     * for the envelope and the group encryption: under 65,507 bytes. */
    json_t *env = json_object();
    json_t *feed = json_array(), *biz = json_array();
    char id[POST_STORE_ID_LEN + 1];
    for (int i = 0; i < POST_STORE_CAP; i++) {
        _id(i, id);
        json_array_append_new(feed, json_string(id));
        json_array_append_new(biz, json_string(id));
    }
    json_object_set_new(env, "feed", feed);
    json_object_set_new(env, "biz", biz);
    char *dump = json_dumps(env, JSON_COMPACT);
    ck_assert(dump != NULL);
    size_t raw = strlen(dump);
    size_t b64 = 4 * ((raw + 2) / 3);
    ck_assert(b64 + 1024 < 65507);
    free(dump);
    json_decref(env);
}
END_TEST_DEFINITION()

RUN_TESTS(PostStore, test_post_store_is_bounded_and_evicts_the_oldest,
          test_post_store_digest_is_the_window_newest_first,
          test_a_full_digest_fits_one_datagram)
