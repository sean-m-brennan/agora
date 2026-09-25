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

#ifndef AUTONOMOUS_TRUST_SOCIAL_POST_STORE_H
#define AUTONOMOUS_TRUST_SOCIAL_POST_STORE_H

/**
 * @file post_store.h
 * @brief The bounded store of recent signed posts that STORE-AND-FORWARD
 *        serves from (Agora Phase 4 DDIL).
 *
 * WHY THIS EXISTS. A post is a group multicast, and a multicast is
 * fire-and-forget: a node that is not on the segment when it goes out never
 * hears it. Across a partition that is every post the other island made,
 * lost for good at the heal, because until now no node kept a post's body
 * past delivering it (only its content id, in the dedup ring). So each node
 * keeps its recent posts here, advertises their ids in a periodic digest,
 * and hands a missing one to whoever asks (id_social.c,
 * `peer_post_digest` / `peer_post_want` / `peer_post_backfill`).
 *
 * WHAT IS STORED is the post's wire envelope exactly as it was verified, so a
 * backfilled copy re-verifies against the author's own signature and dedups by
 * the same content id as the original: the store vouches for nothing. It holds
 * our own posts and every post that passed its gate, including a blocked
 * author's (a personal block governs what we see, not what our neighbours may
 * see: the same reason handle_post still relays such a post).
 *
 * BOUNDS. @ref POST_STORE_CAP entries per store (the dedup ring's size), and
 * only entries younger than the caller's max age are advertised. In memory
 * only: a restarted node has forgotten its store, and cannot backfill what it
 * held before the restart.
 *
 * NO LOCKING. The caller holds social_state.lock, and nothing here calls out.
 */

#include <stddef.h>
#include <uuid/uuid.h>

#define POST_STORE_CAP 256
#define POST_STORE_ID_LEN 64

typedef struct {
    char   id[POST_STORE_ID_LEN + 1];
    double ts;             /**< the post's own timestamp (signed) */
    uuid_t author;         /**< never served back to its author */
    char  *envelope;       /**< compact wire JSON, owned; NULL == empty slot */
} post_store_entry_t;

typedef struct {
    post_store_entry_t e[POST_STORE_CAP];
    size_t next;           /**< slot the next put overwrites (FIFO) */
    size_t count;
} post_store_t;

/** Zero @p s. */
void post_store_init(post_store_t *s);

/** Free every envelope and empty @p s. */
void post_store_clear(post_store_t *s);

/** Keep a copy of @p envelope under content id @p id. A known id is left as it
 *  is; a full store evicts its oldest entry. Returns 0, or -1 on bad input or
 *  allocation failure (nothing changed). */
int post_store_put(post_store_t *s, const char *id, double ts,
                   const uuid_t author, const char *envelope);

/** The entry stored under @p id, or NULL. Borrowed: valid until the next put
 *  or clear. */
const post_store_entry_t *post_store_get(const post_store_t *s, const char *id);

/** Write the ids of entries with ts > @p now - @p max_age into @p ids, newest
 *  first, at most @p cap of them. Returns how many were written. */
size_t post_store_digest(const post_store_t *s, double now, double max_age,
                         char ids[][POST_STORE_ID_LEN + 1], size_t cap);

#endif /* AUTONOMOUS_TRUST_SOCIAL_POST_STORE_H */
