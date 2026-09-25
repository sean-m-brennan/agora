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
/* The social half of AT's test/msg_types3_test.c's
 * test_feature_types_are_registered (moved with social to Agora): the twelve
 * social message types are registered in their range under their historical
 * names and app-bound, and two social app verbs route to identity. It links
 * the static archive and references nothing social but the anchor, which is
 * exactly the link that would drop a constructor-registered type. */
#define DEBUG_TESTS 1
#include "test_setup.h"

#include <string.h>

#include "autonomous_trust/utilities/msg_types.h"
#include "autonomous_trust/utilities/message.h"
#include "autonomous_trust/utilities/msg_types_priv.h"
#include "social/social_msg_types.h"

DEFINE_TEST(test_social_types_are_registered)
{
    at_social_msg_types_link();
    static const struct { long id; const char *name; } social[] = {
        { PEER_POSITION_OBSERVED, "PEER_POSITION_OBSERVED" },
        { PEER_PROFILE_OBSERVED, "PEER_PROFILE_OBSERVED" },
        { PEER_CONNECTION_REQUEST_OBSERVED, "PEER_CONNECTION_REQUEST_OBSERVED" },
        { PEER_CONNECTION_STATE_OBSERVED, "PEER_CONNECTION_STATE_OBSERVED" },
        { PEER_DM_OBSERVED, "PEER_DM_OBSERVED" },
        { PEER_POST_OBSERVED, "PEER_POST_OBSERVED" },
        { PEER_REACTION_OBSERVED, "PEER_REACTION_OBSERVED" },
        { PEER_PROXIMITY_OBSERVED, "PEER_PROXIMITY_OBSERVED" },
        { PEER_BUSINESS_AD_OBSERVED, "PEER_BUSINESS_AD_OBSERVED" },
        { PEER_COSIGN_REQUEST_OBSERVED, "PEER_COSIGN_REQUEST_OBSERVED" },
        { PEER_COSIGN_SIG_OBSERVED, "PEER_COSIGN_SIG_OBSERVED" },
        { PEER_BUSINESS_POST_OBSERVED, "PEER_BUSINESS_POST_OBSERVED" },
    };
    for (size_t i = 0; i < sizeof(social) / sizeof(*social); i++)
    {
        const at_msg_vtable_t *vt = at_msg_type_lookup(social[i].id);
        ck_assert_ptr_nonnull(vt);
        ck_assert(social[i].id >= AT_MSG_TYPE_SOCIAL_MIN && social[i].id <= AT_MSG_TYPE_SOCIAL_MAX);
        /* The names are what cross IPC: they must be the historical spellings. */
        ck_assert_str_eq(vt->name, social[i].name);
        ck_assert(vt->app_bound);
    }
    ck_assert_str_eq(at_app_verb_target(AT_APP_PUBLISH_POST), "identity");
    ck_assert_str_eq(at_app_verb_target(AT_APP_REQUEST_COSIGN), "identity");
}
END_TEST_DEFINITION()

RUN_TESTS(Social_Msg_Types, test_social_types_are_registered)
