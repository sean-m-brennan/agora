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

#include <stdlib.h>
#include <string.h>

#include "social/post_store.h"

void post_store_init(post_store_t *s)
{
    if (s != NULL)
        memset(s, 0, sizeof(*s));
}

void post_store_clear(post_store_t *s)
{
    if (s == NULL)
        return;
    for (size_t i = 0; i < POST_STORE_CAP; i++)
        free(s->e[i].envelope);
    memset(s, 0, sizeof(*s));
}

const post_store_entry_t *post_store_get(const post_store_t *s, const char *id)
{
    if (s == NULL || id == NULL)
        return NULL;
    for (size_t i = 0; i < POST_STORE_CAP; i++)
        if (s->e[i].envelope != NULL && strcmp(s->e[i].id, id) == 0)
            return &s->e[i];
    return NULL;
}

int post_store_put(post_store_t *s, const char *id, double ts,
                   const uuid_t author, const char *envelope)
{
    if (s == NULL || id == NULL || envelope == NULL
        || strlen(id) != POST_STORE_ID_LEN)
        return -1;
    if (post_store_get(s, id) != NULL)
        return 0;
    char *copy = strdup(envelope);
    if (copy == NULL)
        return -1;
    post_store_entry_t *slot = &s->e[s->next];
    free(slot->envelope);           /* the oldest, when full */
    memcpy(slot->id, id, POST_STORE_ID_LEN + 1);
    slot->ts = ts;
    uuid_copy(slot->author, author);
    slot->envelope = copy;
    s->next = (s->next + 1) % POST_STORE_CAP;
    if (s->count < POST_STORE_CAP)
        s->count++;
    return 0;
}

size_t post_store_digest(const post_store_t *s, double now, double max_age,
                         char ids[][POST_STORE_ID_LEN + 1], size_t cap)
{
    if (s == NULL || ids == NULL || cap == 0)
        return 0;
    /* Newest first by the post's own timestamp, not by arrival: a backfilled
     * old post must not crowd a fresh one out of a capped digest. */
    size_t order[POST_STORE_CAP];
    size_t n = 0;
    for (size_t i = 0; i < POST_STORE_CAP; i++)
    {
        const post_store_entry_t *e = &s->e[i];
        if (e->envelope == NULL || e->ts <= now - max_age)
            continue;
        size_t j = n++;
        while (j > 0 && s->e[order[j - 1]].ts < e->ts)
        {
            order[j] = order[j - 1];
            j--;
        }
        order[j] = i;
    }
    size_t out = n < cap ? n : cap;
    for (size_t k = 0; k < out; k++)
        memcpy(ids[k], s->e[order[k]].id, POST_STORE_ID_LEN + 1);
    return out;
}
