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

#include "social_msg_types.h"
#include "utilities/message.h"

/* Each payload is a fixed-size struct that crosses IPC as a raw copy (no
 * to_proto/from_proto), exactly as the union arms it replaces did. */
#define SOCIAL_TYPE(tag, id, T)                                                \
    AT_MSG_ASSERT_FITS(T);                                                     \
    static const at_msg_vtable_t tag##_vt = {                                  \
        .name = #id, .size = sizeof(T), .app_bound = true };                   \
    AT_MSG_TYPE_REGISTER(tag, id, &tag##_vt)

SOCIAL_TYPE(position,           PEER_POSITION_OBSERVED,           peer_position_msg_t)
SOCIAL_TYPE(profile,            PEER_PROFILE_OBSERVED,            peer_profile_msg_t)
SOCIAL_TYPE(connection_request, PEER_CONNECTION_REQUEST_OBSERVED, peer_connection_msg_t)
SOCIAL_TYPE(connection_state,   PEER_CONNECTION_STATE_OBSERVED,   peer_connection_msg_t)
SOCIAL_TYPE(dm,                 PEER_DM_OBSERVED,                 peer_dm_msg_t)
SOCIAL_TYPE(post,               PEER_POST_OBSERVED,               peer_post_msg_t)
SOCIAL_TYPE(reaction,           PEER_REACTION_OBSERVED,           peer_reaction_msg_t)
SOCIAL_TYPE(proximity,          PEER_PROXIMITY_OBSERVED,          peer_proximity_msg_t)
SOCIAL_TYPE(business_ad,        PEER_BUSINESS_AD_OBSERVED,        peer_business_ad_msg_t)
SOCIAL_TYPE(cosign_request,     PEER_COSIGN_REQUEST_OBSERVED,     peer_cosign_request_msg_t)
SOCIAL_TYPE(cosign_sig,         PEER_COSIGN_SIG_OBSERVED,         peer_cosign_sig_msg_t)
SOCIAL_TYPE(business_post,      PEER_BUSINESS_POST_OBSERVED,      peer_business_post_msg_t)
SOCIAL_TYPE(community_policy,   PEER_COMMUNITY_POLICY_OBSERVED,   peer_community_policy_msg_t)
SOCIAL_TYPE(post_label,         PEER_POST_LABEL_OBSERVED,         peer_post_label_msg_t)

/* The app verbs the social feature accepts. Every one is forwarded ONLY to
 * identity, which owns each store and each signed or encrypted send:
 * position/profile (Increments 2-3), connection ask/answer (5), DMs (6), feed
 * posts (7), reactions, local block/unblock and reports (8, P4.1), presence
 * pull, local-only exact position and the proximity probe (Phase 2), business
 * page + customer edge (P3.2), both halves of a detached co-signature (P3.3),
 * the envoy-signed business post (P3.4), and following a community and
 * publishing a moderator's label (Phase 4). */
AT_APP_VERB_REGISTER(set_position,           AT_APP_SET_POSITION,          "identity")
AT_APP_VERB_REGISTER(set_profile,            AT_APP_SET_PROFILE,           "identity")
AT_APP_VERB_REGISTER(connect_request,        AT_APP_CONNECT_REQUEST,       "identity")
AT_APP_VERB_REGISTER(connect_respond,        AT_APP_CONNECT_RESPOND,       "identity")
AT_APP_VERB_REGISTER(send_dm,                AT_APP_SEND_DM,               "identity")
AT_APP_VERB_REGISTER(publish_post,           AT_APP_PUBLISH_POST,          "identity")
AT_APP_VERB_REGISTER(react_post,             AT_APP_REACT_POST,            "identity")
AT_APP_VERB_REGISTER(block,                  AT_APP_BLOCK,                 "identity")
AT_APP_VERB_REGISTER(unblock,                AT_APP_UNBLOCK,               "identity")
AT_APP_VERB_REGISTER(report_peer,            AT_APP_REPORT_PEER,           "identity")
AT_APP_VERB_REGISTER(advertise_business,     AT_APP_ADVERTISE_BUSINESS,    "identity")
AT_APP_VERB_REGISTER(set_customer,           AT_APP_SET_CUSTOMER,          "identity")
AT_APP_VERB_REGISTER(publish_business_post,  AT_APP_PUBLISH_BUSINESS_POST, "identity")
AT_APP_VERB_REGISTER(request_cosign,         AT_APP_REQUEST_COSIGN,        "identity")
AT_APP_VERB_REGISTER(return_cosign,          AT_APP_RETURN_COSIGN,         "identity")
AT_APP_VERB_REGISTER(request_attend,         AT_APP_REQUEST_ATTEND,        "identity")
AT_APP_VERB_REGISTER(set_exact_position,     AT_APP_SET_EXACT_POSITION,    "identity")
AT_APP_VERB_REGISTER(request_proximity,      AT_APP_REQUEST_PROXIMITY,     "identity")
AT_APP_VERB_REGISTER(follow_community,       AT_APP_FOLLOW_COMMUNITY,      "identity")
AT_APP_VERB_REGISTER(unfollow_community,     AT_APP_UNFOLLOW_COMMUNITY,    "identity")
AT_APP_VERB_REGISTER(publish_post_label,     AT_APP_PUBLISH_POST_LABEL,    "identity")

void at_social_msg_types_link(void) {}
