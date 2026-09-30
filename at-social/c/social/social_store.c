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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <jansson.h>

#include "social_store.h"
#include "structures/data.h"
#include "utilities/util.h"
#include "utilities/allocation.h"

static int _default_path(const char *cfg_dir, char *out, size_t out_len)
{
    int n = snprintf(out, out_len, "%s/%s", cfg_dir, AT_SOCIAL_FILENAME);
    return (n > 0 && (size_t)n < out_len) ? 0 : -1;
}

int social_store_load(const char *cfg_dir, map_t *blocks)
{
    return social_store_load_all(cfg_dir, blocks, NULL);
}

int social_store_save(const map_t *blocks, const char *cfg_dir)
{
    return social_store_save_all(blocks, NULL, cfg_dir);
}

/* The follows, as string_data of compact {"bundle","seq"}. */
static int _load_communities(json_t *root, map_t *communities)
{
    json_t *j_com = json_object_get(root, "communities");
    if (j_com == NULL)
        return 0;                              /* follows nothing */
    if (!json_is_object(j_com))
        return -1;
    const char *did;
    json_t *entry;
    json_object_foreach(j_com, did, entry) {
        json_t *j_b = json_object_get(entry, "bundle");
        json_t *j_s = json_object_get(entry, "seq");
        if (!json_is_object(entry) || !json_is_string(j_b) || !json_is_integer(j_s))
            return -1;
        json_t *rec = json_pack("{s:s, s:I}", "bundle", json_string_value(j_b),
                                "seq", json_integer_value(j_s));
        char *js = rec ? json_dumps(rec, JSON_COMPACT | JSON_SORT_KEYS) : NULL;
        json_decref(rec);
        if (js == NULL)
            return -1;
        /* string_data takes a smrt buffer, NUL included. */
        size_t len = strlen(js);
        char *dup = smrt_create(len + 1);
        if (dup == NULL) {
            free(js);
            return -1;
        }
        memcpy(dup, js, len + 1);
        free(js);
        data_t *dat = string_data(dup, len + 1);
        if (dat == NULL) {
            smrt_deref(dup);
            return -1;
        }
        map_set(communities, (map_key_t)did, dat);
    }
    return 0;
}

int social_store_load_all(const char *cfg_dir, map_t *blocks, map_t *communities)
{
    if (blocks == NULL)
        return -1;
    map_free(blocks);
    map_init(blocks);
    if (communities != NULL) {
        map_free(communities);
        map_init(communities);
    }
    if (cfg_dir == NULL)
        return -1;
    char path[4096];
    if (_default_path(cfg_dir, path, sizeof(path)) != 0)
        return -1;
    if (access(path, F_OK) != 0)
        return 0;   /* no file yet -> empty store, not an error */

    json_error_t err;
    json_t *root = json_load_file(path, 0, &err);
    if (root == NULL)
        return -1;
    json_t *j_blocks = json_object_get(root, "blocks");
    if (!json_is_object(j_blocks)) {
        json_decref(root);
        return -1;
    }
    /* The VERSION is read but not enforced: an older reader meeting a newer
     * document should keep the blocks it understands rather than discard
     * somebody's moderation state over a number. A shape it cannot parse at
     * all is what the checks above already refuse. */
    const char *uuid_str;
    json_t *entry;
    json_object_foreach(j_blocks, uuid_str, entry) {
        double at = 0.0;
        if (json_is_object(entry)) {
            json_t *j_at = json_object_get(entry, "at");
            if (json_is_number(j_at))
                at = json_number_value(j_at);
        }
        data_t *dat = floating_pt_dbl_data(at);
        if (dat != NULL)
            map_set(blocks, (map_key_t)uuid_str, dat);
    }
    if (communities != NULL && _load_communities(root, communities) != 0) {
        /* Whole or not at all, as for the blocks. */
        map_free(blocks);
        map_init(blocks);
        map_free(communities);
        map_init(communities);
        json_decref(root);
        return -1;
    }
    json_decref(root);
    return 0;
}

int social_store_save_all(const map_t *blocks, const map_t *communities,
                          const char *cfg_dir)
{
    if (blocks == NULL || cfg_dir == NULL)
        return -1;
    char path[4096];
    if (_default_path(cfg_dir, path, sizeof(path)) != 0)
        return -1;

    json_t *j_blocks = json_object();
    if (j_blocks == NULL)
        return -1;
    map_key_t key = NULL;
    data_t *val = NULL;
    map_entries_for_each((map_t *)blocks, key, val)
    {
        double at = 0.0;
        if (val != NULL)
            (void)data_floating_pt_dbl(val, &at);
        /* `reason` is written empty and always present: the field has no
         * producer yet (no UI collects one), but a key that appears only
         * sometimes would make the two runtimes' files differ by whether
         * anyone had typed something. The shape is the contract. */
        json_t *entry = json_pack("{s:o, s:s}",
                                  "at", json_real(at),
                                  "reason", "");
        if (entry != NULL)
            json_object_set_new(j_blocks, key, entry);
    }
    map_end_for_each

    json_t *doc = json_pack("{s:i, s:o}",
                            "version", AT_SOCIAL_STORE_VERSION,
                            "blocks", j_blocks);
    if (doc == NULL) {
        json_decref(j_blocks);
        return -1;
    }
    /* Follows, only when there are any: see social_store.h. */
    if (communities != NULL && map_size((map_t *)communities) > 0) {
        json_t *j_com = json_object();
        map_key_t did = NULL;
        data_t *rec = NULL;
        map_entries_for_each((map_t *)communities, did, rec)
        {
            char *js = NULL;
            json_t *obj = (rec != NULL && data_string_ptr(rec, &js) == 0 && js != NULL)
                              ? json_loads(js, 0, NULL) : NULL;
            json_t *j_b = obj ? json_object_get(obj, "bundle") : NULL;
            json_t *j_s = obj ? json_object_get(obj, "seq") : NULL;
            if (j_com != NULL && json_is_string(j_b) && json_is_integer(j_s))
                json_object_set_new(j_com, did,
                                    json_pack("{s:s, s:I}", "bundle",
                                              json_string_value(j_b), "seq",
                                              json_integer_value(j_s)));
            json_decref(obj);
        }
        map_end_for_each
        if (j_com == NULL) {
            json_decref(doc);
            return -1;
        }
        json_object_set_new(doc, "communities", j_com);
    }

    /* Atomic write: dump to a temp sibling, then rename over the target, so a
     * concurrent reader — or a crash — never sees a torn social.cfg.json.
     * rename(2) is atomic within a filesystem, and the temp sits beside the
     * target so they are always on the same one. Copied from contacts_save,
     * which is the house pattern for this. */
    char tmp[4096 + 16];
    snprintf(tmp, sizeof(tmp), "%s.tmp%d", path, (int)getpid());
    /* SORT_KEYS is not cosmetic: the Python twin writes the same document with
     * sort_keys=True, and test/social_store_test.c pins the exact bytes
     * against the identical golden string in tests/a_unit/test_social_store.py.
     * Map iteration order is not a contract; sorted order is. */
    int rc = json_dump_file(doc, tmp, JSON_INDENT(2) | JSON_SORT_KEYS);
    json_decref(doc);
    if (rc != 0) {
        unlink(tmp);
        return -1;
    }
    if (rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}
