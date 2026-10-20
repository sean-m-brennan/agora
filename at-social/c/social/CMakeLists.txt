# ******************
#  Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
# ******************

# libat_social: the social feature (position, proximity, profile, connections,
# DMs, feed posts and reactions, reports and blocks, business ads and posts,
# cosign) as an AutonomousTrust extension library (see ../../README.md). It
# lives outside the AT tree and is built inside AT's CMake project, named in
# AT_EXTERNAL_EXTENSIONS (doc/architecture/extensions.md in AT, "External
# extensions"), so at_extension_library and the core's flags and include dirs
# apply as they do in-tree. Present means on: what it registers is in
# at_social.h, and its app-facing API is at_agora.h.

at_extension_library(social
    SOURCES
        id_social.c
        profile.c
        connection.c
        dm.c
        post.c
        business_ad.c
        business_post.c
        community.c
        post_store.c
        cosign.c
        social_tx.c
        social_store.c
        proximity.c
        social_msg_types.c
        at_agora.c
        file_xfer.c
        id_file_xfer.c
)

# The app-facing headers, at the path they were installed to from the core.
install(FILES at_agora.h at_social.h DESTINATION include/autonomous_trust)

at_extension_tests(social
    profile_test
    connection_test
    dm_test
    cosign_test
    post_test
    post_scope_test
    community_test
    post_multicast_test
    social_tx_test
    proximity_test
    social_send_test
    social_store_test
    report_test
    app_verb_origin_test
    app_events_test
    social_link_test
    post_store_test
    file_xfer_test
    file_xfer_flow_test
)

# The social halves of three AT core tests (app_node_test, msg_types3_test,
# identity_resync_test), which AT's copies pin as absent.
at_extension_tests(social
    social_app_routing_test
    social_msg_types_test
    social_in_group_test
)
if(LIBCHECK_LIBRARY)
    # Binds the same queue names as AT's app_node_test; never run the two at once.
    set_tests_properties(social_app_routing_test PROPERTIES RESOURCE_LOCK app_node)
endif()

# The `social` conformance protocol: its corpus and its C adapter (the identity
# adapter plus hooks, ../../conformance/c/). The Python half is the plug-in in
# ../../conformance; ../../test-conformance.sh runs both.
at_conformance_adapter(
    PROTOCOL social
    RUN at_social_run
    SOURCES ../../conformance/c/social_adapter.c
    LIBS at_social_static
    CORPUS ../../conformance)
