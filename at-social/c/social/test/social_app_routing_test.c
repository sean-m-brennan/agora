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
/* The social half of AT's test/app_node_test.c (moved with social to Agora):
 * every social app verb passes at_route_extern_msg's allowlist, every social
 * PEER_*_OBSERVED type is forwarded by at_route_internal_msgs, and the largest
 * of them (the co-signing ask) survives the hop byte for byte. The loops and
 * the round trip are the originals verbatim; see app_node_test.c for why each
 * exists (the cosign pair shipped missing from both switches). */
#define DEBUG_TESTS 1   /* _test_count / _ck_fail, as app_node_test.c */
#include "test_setup.h"

#include <string.h>

#include "autonomous_trust/app_events.h"
#include "utilities/message.h"
#include "autonomous_trust/at_route_priv.h"   /* at_route_internal_msgs forward */
#include "social/social_msg_types.h"

DEFINE_TEST(test_every_social_app_verb_is_allowlisted_for_routing)
{
    queue_t sender_q;
    ck_assert_ret_ok(messaging_init("_route_verb_q", &sender_q));
    messaging_assign(&sender_q);

    static const char *const app_verbs[] = {
        AT_APP_SET_POSITION, AT_APP_SET_PROFILE,
        AT_APP_CONNECT_REQUEST, AT_APP_CONNECT_RESPOND,
        AT_APP_SEND_DM, AT_APP_PUBLISH_POST, AT_APP_REACT_POST, AT_APP_BLOCK,
        AT_APP_REQUEST_ATTEND, AT_APP_SET_EXACT_POSITION,
        AT_APP_REQUEST_PROXIMITY,
        AT_APP_ADVERTISE_BUSINESS, AT_APP_SET_CUSTOMER,
        AT_APP_REQUEST_COSIGN, AT_APP_RETURN_COSIGN,
        AT_APP_PUBLISH_BUSINESS_POST,
        AT_APP_UNBLOCK, AT_APP_REPORT_PEER,     /* Phase 4 P4.1 */
    };

    for (size_t i = 0; i < sizeof(app_verbs) / sizeof(app_verbs[0]); i++) {
        generic_msg_t msg = {0};
        msg.type = NET_MESSAGE;
        msg.size = message_size(NET_MESSAGE);
        msg.info.net_msg.function = (char *)app_verbs[i];
        snprintf(msg.info.net_msg.process, sizeof(msg.info.net_msg.process),
                 "%s", "identity");
        /* Names the verb in the failure, so a miss says WHICH one. */
        _test_count++;
        if (at_route_extern_msg(&msg, NULL) != 0)
            _ck_fail("app verb '%s' is not allowlisted in at_route_extern_msg"
                     " -- the daemon refuses it and the app never learns",
                     app_verbs[i]);
    }

    messaging_assign(NULL);
    messaging_qclose(&sender_q);
}
END_TEST_DEFINITION()

DEFINE_TEST(test_every_social_app_event_type_forwards_to_the_app_queue)
{
    queue_t app_q, sender_q;
    ck_assert_ret_ok(messaging_init("_route_app_q", &app_q));
    ck_assert_ret_ok(messaging_init("_route_sender_q", &sender_q));
    messaging_assign(&sender_q);

    static const message_type_t app_types[] = {
        PEER_POSITION_OBSERVED, PEER_PROFILE_OBSERVED,
        PEER_CONNECTION_REQUEST_OBSERVED, PEER_CONNECTION_STATE_OBSERVED,
        PEER_DM_OBSERVED, PEER_POST_OBSERVED, PEER_REACTION_OBSERVED,
        PEER_PROXIMITY_OBSERVED, PEER_BUSINESS_AD_OBSERVED,
        PEER_COSIGN_REQUEST_OBSERVED, PEER_COSIGN_SIG_OBSERVED,
        PEER_BUSINESS_POST_OBSERVED,
    };
    const size_t n = sizeof(app_types) / sizeof(app_types[0]);

    /* ONE AT A TIME, receiving between sends. These are AF_UNIX SOCK_DGRAM
     * queues and net.unix.max_dgram_qlen is 10 on a stock kernel, so queueing
     * every type before reading any caps the batch at the queue depth, NOT at
     * the switch: this test used to send exactly 10 and sat one datagram from
     * failing. Adding Phase 2 / P3.3's types made it fail at 11 of 14 — which
     * reads exactly like three missing switch cases and is not. Draining as we
     * go makes the assertion mean what it says at any number of types. */
    for (size_t i = 0; i < n; i++) {
        generic_msg_t msg = {0};   /* must outlive the drain below */
        msg.type = app_types[i];
        msg.size = message_size(app_types[i]);
        array_t unhandled;
        ck_assert_ret_ok(array_init(&unhandled));
        ck_assert_ret_ok(at_route_queue_msg(&unhandled, &msg));

        /* Forwarded (sent == 1) or fallen through the switch (sent == 0). The
         * array is emptied either way. */
        int sent = at_route_internal_msgs(&unhandled, "_route_app_q", NULL);
        _test_count++;
        if (sent != 1)
            _ck_fail("app event type %d is not forwarded by at_route_internal_msgs"
                     " -- it is dropped on the way to the app queue",
                     (int)app_types[i]);
        ck_assert_int_eq((int)array_size(&unhandled), 0);
        array_free(&unhandled);

        /* It lands on the app queue with its type intact. Only read what was
         * actually sent, so a dropped case fails above rather than blocking. */
        if (sent == 1) {
            generic_msg_t got = {0};
            ck_assert_ret_ok(messaging_recv_on(&app_q, &got, NULL, true));
            ck_assert_int_eq((int)got.type, (int)app_types[i]);
        }
    }

    /* THE TYPE ARRIVING IS NOT THE PAYLOAD ARRIVING. The hop serializes through
     * protobuf (generic_msg_to_proto) and rides one datagram, so a type whose
     * payload the serializer does not carry — or carries truncated — still
     * reads back with the right type and an empty body. P3.3's co-signing ask is
     * the largest of them (its opaque hex bytes alone bound at 6 KB), so pin the
     * round trip on that one, byte for byte. */
    {
        generic_msg_t out = {0};
        out.type = PEER_COSIGN_REQUEST_OBSERVED;
        out.size = message_size(PEER_COSIGN_REQUEST_OBSERVED);
        memset(AT_MSG_EXT(&out, peer_cosign_request_msg_t)->peer_uuid, 0xA5, 16);
        snprintf(AT_MSG_EXT(&out, peer_cosign_request_msg_t)->record,
                 sizeof(AT_MSG_EXT(&out, peer_cosign_request_msg_t)->record), "%s", "membership");
        snprintf(AT_MSG_EXT(&out, peer_cosign_request_msg_t)->op,
                 sizeof(AT_MSG_EXT(&out, peer_cosign_request_msg_t)->op), "%s", "admit");
        snprintf(AT_MSG_EXT(&out, peer_cosign_request_msg_t)->polity,
                 sizeof(AT_MSG_EXT(&out, peer_cosign_request_msg_t)->polity), "%s",
                 "did:key:z6MkiQ5Nq4QCVnW5pSg5iuX5WyjXi2qD1rFKV4n8gAsXKH8A");
        snprintf(AT_MSG_EXT(&out, peer_cosign_request_msg_t)->cid,
                 sizeof(AT_MSG_EXT(&out, peer_cosign_request_msg_t)->cid), "%s",
                 "b3:bba6b3b8dc0e26358a1b4996d722a922297ff988b421f72bd64a012de03665bc");
        AT_MSG_EXT(&out, peer_cosign_request_msg_t)->seq = 4242;
        AT_MSG_EXT(&out, peer_cosign_request_msg_t)->ts  = 1.5;
        /* A realistic exchange, not a token: 770 hex chars is what the live
         * cohort's admission actually exports. */
        for (size_t k = 0; k < 770; k++)
            AT_MSG_EXT(&out, peer_cosign_request_msg_t)->bytes[k] = "0123456789abcdef"[k % 16];
        AT_MSG_EXT(&out, peer_cosign_request_msg_t)->bytes[770] = '\0';

        array_t one;
        ck_assert_ret_ok(array_init(&one));
        ck_assert_ret_ok(at_route_queue_msg(&one, &out));
        ck_assert_int_eq(at_route_internal_msgs(&one, "_route_app_q", NULL), 1);
        array_free(&one);

        generic_msg_t got = {0};
        ck_assert_ret_ok(messaging_recv_on(&app_q, &got, NULL, true));
        ck_assert_int_eq((int)got.type, (int)PEER_COSIGN_REQUEST_OBSERVED);
        ck_assert_str_eq(AT_MSG_EXT(&got, peer_cosign_request_msg_t)->record, "membership");
        ck_assert_str_eq(AT_MSG_EXT(&got, peer_cosign_request_msg_t)->op, "admit");
        ck_assert_str_eq(AT_MSG_EXT(&got, peer_cosign_request_msg_t)->polity,
                         AT_MSG_EXT(&out, peer_cosign_request_msg_t)->polity);
        ck_assert_str_eq(AT_MSG_EXT(&got, peer_cosign_request_msg_t)->cid,
                         AT_MSG_EXT(&out, peer_cosign_request_msg_t)->cid);
        ck_assert_int_eq((int)AT_MSG_EXT(&got, peer_cosign_request_msg_t)->seq, 4242);
        ck_assert_mem_eq(AT_MSG_EXT(&got, peer_cosign_request_msg_t)->peer_uuid,
                         AT_MSG_EXT(&out, peer_cosign_request_msg_t)->peer_uuid, 16);
        /* The whole opaque payload, not a prefix: a truncating hop reproduces
         * to nothing on the signer's node. */
        ck_assert_str_eq(AT_MSG_EXT(&got, peer_cosign_request_msg_t)->bytes,
                         AT_MSG_EXT(&out, peer_cosign_request_msg_t)->bytes);
    }

    messaging_assign(NULL);
    messaging_qclose(&app_q);
    messaging_qclose(&sender_q);
}
END_TEST_DEFINITION()

RUN_TESTS(Social_App_Routing,
          test_every_social_app_verb_is_allowlisted_for_routing,
          test_every_social_app_event_type_forwards_to_the_app_queue)
