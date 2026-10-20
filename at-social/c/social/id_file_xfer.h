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
 * @file id_file_xfer.h
 * @brief File sharing on the identity process: the handlers for the four
 *        app_file_* verbs and the four peer_file_* verbs (file_xfer.h).
 *
 * Kept out of id_social.c, which reaches it through the five entry points
 * below from its own register / run_start / resync / roster / reset hooks.
 * It keeps its own state behind its own lock, a leaf like social's: nothing
 * that takes another lock is called while it is held, so every frame and
 * every event is collected under it and sent after it is released.
 */

#ifndef AUTONOMOUS_TRUST_SOCIAL_ID_FILE_XFER_H
#define AUTONOMOUS_TRUST_SOCIAL_ID_FILE_XFER_H

#include <stdbool.h>
#include <uuid/uuid.h>

#include "processes/processes.h"
#include "utilities/msg_types.h"

/** Register the eight handlers (identity process only). */
void file_xfer_register_handlers(process_t *proc);
/** Restore the persisted transfers and their bitmaps (once per run). */
void file_xfer_run_start(process_t *proc);
/** Resume stalled pulls, expire old offers, prune tombstones. Called from
 *  social's periodic resync (~20 s). */
void file_xfer_periodic(const process_t *proc);
/** Re-emit every transfer the store holds, for the app's roster pull.
 *  @return events emitted. */
int file_xfer_replay(const process_t *proc);
/** Drop all state (tests, conformance). Leaves files on disk alone. */
void file_xfer_reset(void);

/** Test and conformance seam: every record as a JSON array (the persisted
 *  form plus "done", the bytes held or served). Caller frees; NULL if none
 *  could be built. */
char *file_xfer_dump(void);

/* Provided by id_social.c, which owns the block list and the emit path. */
bool social_peer_is_blocked(const uuid_t uuid);
int social_emit(generic_msg_t *msg, const char *what);

#endif /* AUTONOMOUS_TRUST_SOCIAL_ID_FILE_XFER_H */
