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

/* libat_social present after link (FEATURE_SPLIT_PLAN Phase 5): the "social"
 * identity extension is registered, identity_register_handlers on a real
 * process gives it all 37 social verbs, and a block reaches the core through
 * the hooks -- PEER_OBSERVED's `blocked` and the tier clamp. The core's
 * identity_test asserts the converse, that a core-only binary registers none
 * of these verbs. */

#define DEBUG_TESTS 1
#include "test_setup.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <uuid/uuid.h>

#include "identity/id_ext.h"
#include "identity/id_proc_priv.h"
#include "processes/processes.h"
#include "structures/map.h"
#include "social/at_social.h"
#include "social/id_social.h"
#include "social/social_msg_types.h"

/* The 19 wire verbs and 18 app verbs social registers on identity. */
static const char *const SOCIAL_VERBS[] = {
    "peer_position_query", "peer_position_response",
    "peer_profile_query", "peer_profile_response",
    "peer_proximity_probe", "peer_proximity_reply",
    "peer_connection_request", "peer_connection_response",
    "peer_dm", "peer_post", "peer_reaction", "peer_report",
    "peer_business_ad", "peer_business_post",
    "peer_cosign_request", "peer_cosign_sig",
    "peer_post_digest", "peer_post_want", "peer_post_backfill",
    AT_APP_SET_POSITION, AT_APP_SET_PROFILE,
    AT_APP_CONNECT_REQUEST, AT_APP_CONNECT_RESPOND,
    AT_APP_SEND_DM, AT_APP_PUBLISH_POST, AT_APP_REACT_POST,
    AT_APP_BLOCK, AT_APP_UNBLOCK, AT_APP_REPORT_PEER,
    AT_APP_REQUEST_ATTEND, AT_APP_SET_EXACT_POSITION,
    AT_APP_REQUEST_PROXIMITY, AT_APP_ADVERTISE_BUSINESS,
    AT_APP_SET_CUSTOMER, AT_APP_REQUEST_COSIGN, AT_APP_RETURN_COSIGN,
    AT_APP_PUBLISH_BUSINESS_POST,
};

DEFINE_TEST(test_social_is_registered_and_owns_its_verbs)
{
    at_social_link();
    ck_assert(identity_ext_present("social"));
    ck_assert_int_eq(sizeof(SOCIAL_VERBS) / sizeof(*SOCIAL_VERBS), 37);

    process_t proc;
    memset(&proc, 0, sizeof(proc));
    ck_assert_int_eq(map_create(&proc.protocol.handlers), 0);
    ck_assert_int_eq(identity_register_handlers(&proc), 0);
    for (size_t i = 0; i < sizeof(SOCIAL_VERBS) / sizeof(*SOCIAL_VERBS); i++) {
        data_t *h = NULL;
        ck_assert_int_eq(map_get(proc.protocol.handlers, (map_key_t)SOCIAL_VERBS[i], &h), 0);
        ck_assert(h != NULL);
    }
}
END_TEST_DEFINITION()

DEFINE_TEST(test_a_block_reaches_the_core_through_the_hooks)
{
    char root[] = "/tmp/at-social-link-testXXXXXX";
    ck_assert(mkdtemp(root) != NULL);
    setenv("AUTONOMOUS_TRUST_ROOT", root, 1);
    identity_reset_state();

    uuid_t peer;
    uuid_generate(peer);
    char ps[UUID_STRING_LEN + 1];
    uuid_unparse_lower(peer, ps);

    ck_assert(!identity_ext_peer_blocked(ps));
    identity_block_peer(ps);
    ck_assert(identity_is_blocked(ps));
    /* What PEER_OBSERVED's `blocked` and identity_get_peer_tier read. */
    ck_assert(identity_ext_peer_blocked(ps));
    ck_assert_int_eq(identity_get_peer_tier(peer), 0);
    identity_unblock_peer(ps);
    ck_assert(!identity_ext_peer_blocked(ps));

    identity_reset_state();
    unsetenv("AUTONOMOUS_TRUST_ROOT");
}
END_TEST_DEFINITION()

RUN_TESTS(SocialLink, test_social_is_registered_and_owns_its_verbs,
          test_a_block_reaches_the_core_through_the_hooks)
