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

/** @file The pure half of DM file sharing (file_xfer.h): names, wire forms,
 *  the bitmap, the store.
 *
 *  The name and the offer are where a peer's bytes come closest to a path on
 *  this disk, so those get the hostile inputs. */

#define DEBUG_TESTS 1
#include "test_setup.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <jansson.h>
#include <uuid/uuid.h>

#include "social/file_xfer.h"

static const char ID[] = "0123456789abcdef0123456789abcdef";

static void _clean(const char *in, const char *want)
{
    char out[AT_FILE_NAME_MAX + 1];
    at_file_sanitize_name(in, out, sizeof(out));
    ck_assert_str_eq(out, want);
}

DEFINE_TEST(test_a_name_is_never_a_path)
{
    _clean("report.pdf", "report.pdf");
    _clean("/etc/passwd", "passwd");
    _clean("../../.ssh/authorized_keys", "authorized_keys");
    _clean("..\\..\\boot.ini", "boot.ini");
    _clean("..", "file");
    _clean(".", "file");
    _clean("", "file");
    _clean(NULL, "file");
    _clean("dir/", "file");
    _clean("a\nb\tc\x7f.txt", "abc.txt");
    _clean("what?<now>:\"|*.txt", "what__now_____.txt");
    _clean("trailing.  ", "trailing");
    _clean("NUL.txt", "file");
    _clean("com1", "file");
    _clean("console.log", "console.log");
    _clean(".bashrc", ".bashrc");
}
END_TEST_DEFINITION()

DEFINE_TEST(test_a_long_name_is_cut_on_a_character_boundary)
{
    /* 254 ASCII then a 3-byte character: the cut at 255 must drop the whole
     * character, not leave its first byte. */
    char in[300];
    memset(in, 'a', 254);
    memcpy(in + 254, "\xe2\x82\xac", 3);   /* U+20AC */
    in[257] = '\0';
    char out[AT_FILE_NAME_MAX + 1];
    size_t n = at_file_sanitize_name(in, out, sizeof(out));
    ck_assert_uint_eq(n, 254);
    ck_assert_uint_eq(strlen(out), 254);
    /* A small buffer bounds it too. */
    char tiny[8];
    ck_assert_uint_eq(at_file_sanitize_name("abcdefghijkl", tiny, sizeof(tiny)), 7);
    ck_assert_str_eq(tiny, "abcdefg");
}
END_TEST_DEFINITION()

DEFINE_TEST(test_a_finished_file_never_overwrites_another)
{
    char dir[] = "/tmp/fx_unique_XXXXXX";
    ck_assert_ptr_nonnull(mkdtemp(dir));
    char p[512];
    ck_assert_int_eq(at_file_unique_path(dir, "a.txt", p, sizeof(p)), 0);
    ck_assert(strstr(p, "/a.txt") != NULL);
    FILE *f = fopen(p, "w");
    fclose(f);
    ck_assert_int_eq(at_file_unique_path(dir, "a.txt", p, sizeof(p)), 0);
    ck_assert(strstr(p, "/a (1).txt") != NULL);
    f = fopen(p, "w");
    fclose(f);
    ck_assert_int_eq(at_file_unique_path(dir, "a.txt", p, sizeof(p)), 0);
    ck_assert(strstr(p, "/a (2).txt") != NULL);
    /* No extension, and a dotfile, keep their whole name as the stem. */
    char q[512];
    snprintf(q, sizeof(q), "%s/.env", dir);
    f = fopen(q, "w");
    fclose(f);
    ck_assert_int_eq(at_file_unique_path(dir, ".env", p, sizeof(p)), 0);
    ck_assert(strstr(p, "/.env (1)") != NULL);
    char cmd[600];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", dir);
    ck_assert_int_eq(system(cmd), 0);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_chunk_arithmetic)
{
    ck_assert_uint_eq(at_file_total_chunks(0, 4096), 0);
    ck_assert_uint_eq(at_file_total_chunks(1, 4096), 1);
    ck_assert_uint_eq(at_file_total_chunks(4096, 4096), 1);
    ck_assert_uint_eq(at_file_total_chunks(4097, 4096), 2);
    ck_assert_uint_eq(at_file_chunk_len(4097, 4096, 0), 4096);
    ck_assert_uint_eq(at_file_chunk_len(4097, 4096, 1), 1);
    ck_assert_uint_eq(at_file_chunk_len(4097, 4096, 2), 0);
}
END_TEST_DEFINITION()

static at_file_offer_t _offer(void)
{
    at_file_offer_t o = {0};
    memcpy(o.id, ID, sizeof(o.id));
    snprintf(o.name, sizeof(o.name), "x.bin");
    o.size = 40000;
    o.chunk = 16384;
    o.total = 3;
    memset(o.hash, 'a', AT_FILE_HASH_HEX_LEN);
    o.ts = 1000.0;
    return o;
}

DEFINE_TEST(test_an_offer_round_trips_and_its_name_is_sanitized)
{
    at_file_offer_t o = _offer();
    snprintf(o.name, sizeof(o.name), "../../evil.sh");
    json_t *j = at_file_offer_to_json(&o);
    ck_assert_ptr_nonnull(j);
    at_file_offer_t back;
    ck_assert_int_eq(at_file_offer_from_json(j, &back), 0);
    ck_assert_str_eq(back.id, ID);
    ck_assert_str_eq(back.name, "evil.sh");
    ck_assert_int_eq(back.size, 40000);
    ck_assert_uint_eq(back.total, 3);
    json_decref(j);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_an_offer_whose_numbers_disagree_is_refused)
{
    at_file_offer_t back;
    at_file_offer_t o = _offer();
    json_t *j = at_file_offer_to_json(&o);

    /* total must be ceil(size/chunk): a lie would size the bitmap. */
    json_object_set_new(j, "total", json_integer(1000000));
    ck_assert(at_file_offer_from_json(j, &back) != 0);
    json_object_set_new(j, "total", json_integer(3));
    ck_assert_int_eq(at_file_offer_from_json(j, &back), 0);

    json_object_set_new(j, "chunk", json_integer(16));
    ck_assert(at_file_offer_from_json(j, &back) != 0);
    json_object_set_new(j, "chunk", json_integer(16384));

    json_object_set_new(j, "size", json_integer(-1));
    ck_assert(at_file_offer_from_json(j, &back) != 0);
    json_object_set_new(j, "size", json_integer(40000));

    json_object_set_new(j, "hash", json_string("not-hex"));
    ck_assert(at_file_offer_from_json(j, &back) != 0);
    json_object_set_new(j, "hash", json_string(o.hash));

    json_object_set_new(j, "id", json_string("0123456789ABCDEF0123456789ABCDEF"));
    ck_assert(at_file_offer_from_json(j, &back) != 0);
    json_decref(j);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_ctl_req_and_chunk_round_trip)
{
    char id[AT_FILE_ID_HEX_LEN + 1];
    char reason[AT_FILE_REASON_MAX + 1];
    int op = -1;
    json_t *j = at_file_ctl_to_json(ID, AT_FILE_OP_FAIL, "Hash Mismatch!; rm -rf");
    ck_assert_int_eq(at_file_ctl_from_json(j, id, &op, reason), 0);
    ck_assert_int_eq(op, AT_FILE_OP_FAIL);
    /* A peer's reason is a token, nothing more. */
    ck_assert_str_eq(reason, "ashismatchrmrf");
    json_decref(j);
    j = json_pack("{s:s, s:s}", "id", ID, "op", "explode");
    ck_assert(at_file_ctl_from_json(j, id, &op, reason) != 0);
    json_decref(j);

    uint32_t first = 0, count = 0;
    j = at_file_req_to_json(ID, 7, 16);
    ck_assert_int_eq(at_file_req_from_json(j, id, &first, &count), 0);
    ck_assert_uint_eq(first, 7);
    ck_assert_uint_eq(count, 16);
    json_object_set_new(j, "count", json_integer(AT_FILE_REQ_MAX + 1));
    ck_assert(at_file_req_from_json(j, id, &first, &count) != 0);
    json_object_set_new(j, "count", json_integer(0));
    ck_assert(at_file_req_from_json(j, id, &first, &count) != 0);
    json_decref(j);

    uint8_t data[1000];
    for (size_t i = 0; i < sizeof(data); i++)
        data[i] = (uint8_t)(i * 7);
    j = at_file_chunk_to_json(ID, 2, data, sizeof(data));
    uint8_t back[2048];
    size_t len = 0;
    uint32_t idx = 0;
    ck_assert_int_eq(at_file_chunk_from_json(j, id, &idx, back, sizeof(back), &len), 0);
    ck_assert_uint_eq(idx, 2);
    ck_assert_uint_eq(len, sizeof(data));
    ck_assert_int_eq(memcmp(back, data, len), 0);
    /* Too big for the caller's buffer is refused, not truncated. */
    ck_assert(at_file_chunk_from_json(j, id, &idx, back, 999, &len) != 0);
    json_object_set_new(j, "data", json_string("!!!!"));
    ck_assert(at_file_chunk_from_json(j, id, &idx, back, sizeof(back), &len) != 0);
    json_decref(j);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_the_bitmap_counts_and_survives_a_restart)
{
    at_file_bitmap_t bm;
    ck_assert_int_eq(at_file_bitmap_init(&bm, 20), 0);
    ck_assert(at_file_bitmap_set(&bm, 0));
    ck_assert(!at_file_bitmap_set(&bm, 0));   /* a duplicate counts once */
    ck_assert(at_file_bitmap_set(&bm, 9));
    ck_assert(at_file_bitmap_set(&bm, 19));
    ck_assert(!at_file_bitmap_set(&bm, 20));  /* out of range */
    ck_assert_uint_eq(bm.count, 3);
    ck_assert_uint_eq(at_file_bitmap_next_clear(&bm, 0), 1);
    ck_assert_uint_eq(at_file_bitmap_next_clear(&bm, 9), 10);
    ck_assert_uint_eq(at_file_bitmap_next_clear(&bm, 19), 20);

    char path[] = "/tmp/fx_map_XXXXXX";
    int fd = mkstemp(path);
    ck_assert(fd >= 0);
    close(fd);
    ck_assert_int_eq(at_file_bitmap_save(&bm, path), 0);
    at_file_bitmap_t back;
    ck_assert_int_eq(at_file_bitmap_load(&back, 20, path), 0);
    ck_assert_uint_eq(back.count, 3);
    ck_assert(at_file_bitmap_get(&back, 9));
    at_file_bitmap_free(&back);
    /* A sidecar for a different size is ignored: fetch again, never trust. */
    ck_assert_int_eq(at_file_bitmap_load(&back, 2000, path), 0);
    ck_assert_uint_eq(back.count, 0);
    at_file_bitmap_free(&back);
    at_file_bitmap_free(&bm);
    unlink(path);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_the_store_round_trips_and_skips_bad_records)
{
    char dir[] = "/tmp/fx_store_XXXXXX";
    ck_assert_ptr_nonnull(mkdtemp(dir));
    at_file_xfer_t a;
    at_file_xfer_init(&a);
    memcpy(a.id, ID, sizeof(a.id));
    uuid_generate(a.peer);
    a.outgoing = true;
    a.state = AT_FILE_ACCEPTED;
    snprintf(a.name, sizeof(a.name), "a.bin");
    snprintf(a.path, sizeof(a.path), "/home/me/a.bin");
    a.size = 40000;
    a.mtime = 1234;
    a.chunk = 16384;
    a.total = 3;
    memset(a.hash, 'b', AT_FILE_HASH_HEX_LEN);
    a.created = 10.0;
    a.updated = 11.0;
    at_file_xfer_t *xs[1] = { &a };
    ck_assert_int_eq(at_file_store_save(dir, xs, 1), 0);

    at_file_xfer_t back[4];
    ck_assert_int_eq(at_file_store_load(dir, back, 4), 1);
    ck_assert_str_eq(back[0].id, ID);
    ck_assert(back[0].outgoing);
    ck_assert_int_eq(back[0].state, AT_FILE_ACCEPTED);
    ck_assert_str_eq(back[0].path, "/home/me/a.bin");
    ck_assert_int_eq(back[0].mtime, 1234);
    ck_assert_int_eq(uuid_compare(back[0].peer, a.peer), 0);
    ck_assert_int_eq(back[0].fd, -1);

    /* One good record and one whose total lies: the good one loads. */
    char path[600];
    snprintf(path, sizeof(path), "%s/%s", dir, AT_FILE_STORE_FILENAME);
    json_t *doc = json_load_file(path, 0, NULL);
    json_t *arr = json_object_get(doc, "xfers");
    json_t *bad = json_deep_copy(json_array_get(arr, 0));
    json_object_set_new(bad, "total", json_integer(99));
    json_array_append_new(arr, bad);
    ck_assert_int_eq(json_dump_file(doc, path, 0), 0);
    json_decref(doc);
    ck_assert_int_eq(at_file_store_load(dir, back, 4), 1);

    /* A missing file is an empty store; a corrupt one is an error. */
    unlink(path);
    ck_assert_int_eq(at_file_store_load(dir, back, 4), 0);
    FILE *f = fopen(path, "w");
    fputs("{not json", f);
    fclose(f);
    ck_assert_int_eq(at_file_store_load(dir, back, 4), -1);
    unlink(path);
    rmdir(dir);
}
END_TEST_DEFINITION()

RUN_TESTS(FileXfer,
          test_a_name_is_never_a_path,
          test_a_long_name_is_cut_on_a_character_boundary,
          test_a_finished_file_never_overwrites_another,
          test_chunk_arithmetic,
          test_an_offer_round_trips_and_its_name_is_sanitized,
          test_an_offer_whose_numbers_disagree_is_refused,
          test_ctl_req_and_chunk_round_trip,
          test_the_bitmap_counts_and_survives_a_restart,
          test_the_store_round_trips_and_skips_bad_records)
