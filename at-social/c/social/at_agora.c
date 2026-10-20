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

/* The Agora social feature's half of the flat app-event ABI (at_agora.h):
 * one decoder per social message type, registered with at_app_events_poll,
 * and the app->AT social verbs. Moved verbatim out of app_events.c, which now
 * knows nothing social; see doc/architecture/extensions.md. */

#include <stdlib.h>
#include <string.h>

#include <jansson.h>
#include <uuid/uuid.h>

#include "at_agora.h"
#include "app_events_registry.h"
#include "utilities/message.h"
#include "utilities/msg_types_priv.h"   /* net_msg_pack_json */
#include "social_msg_types.h"
#include "cosign.h"             /* at_cosign_op_ok / at_cosign_bytes_ok */
#include "file_xfer.h"          /* at_file_id_ok */

/* ---- AT -> app: one decoder per social message type. The poll zeroes the
 * event before calling, so a short string stays terminated after each
 * bounded copy, exactly as it did inline. ---- */

static int decode_position(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_position_msg_t *in = AT_MSG_EXT_CONST(msg, peer_position_msg_t);
    at_app_position_t *out = AT_APP_EVENT_EXT(ev, at_app_position_t);
    ev->kind = AT_APP_EVENT_PEER_POSITION;
    memcpy(out->peer_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    /* Bounded copy of the opaque geohash; the emitter already NUL-caps
     * it, and the event was memset so a short string stays terminated. */
    memcpy(out->geohash, in->geohash,
           AT_APP_GEOHASH_LEN);
    out->geohash[AT_APP_GEOHASH_LEN] = '\0';
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_position, PEER_POSITION_OBSERVED, decode_position)

static int decode_business_ad(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_business_ad_msg_t *in = AT_MSG_EXT_CONST(msg, peer_business_ad_msg_t);
    at_app_business_ad_t *out = AT_APP_EVENT_EXT(ev, at_app_business_ad_t);
    ev->kind = AT_APP_EVENT_BUSINESS_AD;
    memcpy(out->advertiser_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    /* The emitter NUL-caps every string; the event was memset, so a
     * short string stays terminated after the bounded copy. */
    memcpy(out->polity, in->polity,
           AT_APP_BUSINESS_DID_LEN);
    out->polity[AT_APP_BUSINESS_DID_LEN] = '\0';
    memcpy(out->ad_id, in->ad_id,
           AT_APP_BUSINESS_AD_ID_LEN);
    out->ad_id[AT_APP_BUSINESS_AD_ID_LEN] = '\0';
    out->satisfaction =
        in->satisfaction;
    out->seq = in->seq;
    out->ts = in->ts;
    memcpy(out->bundle, in->bundle,
           AT_APP_BUSINESS_BUNDLE_LEN);
    out->bundle[AT_APP_BUSINESS_BUNDLE_LEN] = '\0';
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_business_ad, PEER_BUSINESS_AD_OBSERVED, decode_business_ad)

static int decode_business_post(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_business_post_msg_t *in = AT_MSG_EXT_CONST(msg, peer_business_post_msg_t);
    at_app_business_post_t *out = AT_APP_EVENT_EXT(ev, at_app_business_post_t);
    ev->kind = AT_APP_EVENT_BUSINESS_POST;
    memcpy(out->publisher_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    /* The emitter NUL-caps every string; the event was memset, so a
     * short string stays terminated after the bounded copy. */
    memcpy(out->polity,
           in->polity, AT_APP_BUSINESS_DID_LEN);
    out->polity[AT_APP_BUSINESS_DID_LEN] = '\0';
    memcpy(out->post_id,
           in->post_id,
           AT_APP_BUSINESS_POST_ID_LEN);
    out->post_id[AT_APP_BUSINESS_POST_ID_LEN] = '\0';
    out->seq = in->seq;
    out->ts = in->ts;
    out->hops = in->hops;
    memcpy(out->bundle,
           in->bundle,
           AT_APP_BUSINESS_POST_BUNDLE_LEN);
    out->bundle[AT_APP_BUSINESS_POST_BUNDLE_LEN] = '\0';
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_business_post, PEER_BUSINESS_POST_OBSERVED, decode_business_post)

static int decode_cosign_request(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_cosign_request_msg_t *in = AT_MSG_EXT_CONST(msg, peer_cosign_request_msg_t);
    at_app_cosign_request_t *out = AT_APP_EVENT_EXT(ev, at_app_cosign_request_t);
    ev->kind = AT_APP_EVENT_COSIGN_REQUEST;
    memcpy(out->requester_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    /* The emitter NUL-caps every string; the event was memset, so a
     * short string stays terminated after the bounded copy. */
    memcpy(out->record,
           in->record, AT_APP_COSIGN_TOKEN_LEN);
    out->record[AT_APP_COSIGN_TOKEN_LEN] = '\0';
    memcpy(out->op,
           in->op, AT_APP_COSIGN_TOKEN_LEN);
    out->op[AT_APP_COSIGN_TOKEN_LEN] = '\0';
    memcpy(out->polity,
           in->polity, AT_APP_COSIGN_DID_LEN);
    out->polity[AT_APP_COSIGN_DID_LEN] = '\0';
    memcpy(out->cid,
           in->cid, AT_APP_COSIGN_CID_LEN);
    out->cid[AT_APP_COSIGN_CID_LEN] = '\0';
    out->seq = in->seq;
    out->ts = in->ts;
    memcpy(out->bytes,
           in->bytes, AT_APP_COSIGN_BYTES_LEN);
    out->bytes[AT_APP_COSIGN_BYTES_LEN] = '\0';
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_cosign_request, PEER_COSIGN_REQUEST_OBSERVED, decode_cosign_request)

static int decode_cosign_sig(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_cosign_sig_msg_t *in = AT_MSG_EXT_CONST(msg, peer_cosign_sig_msg_t);
    at_app_cosign_sig_t *out = AT_APP_EVENT_EXT(ev, at_app_cosign_sig_t);
    ev->kind = AT_APP_EVENT_COSIGN_SIGNATURE;
    memcpy(out->signer_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    memcpy(out->cid, in->cid,
           AT_APP_COSIGN_CID_LEN);
    out->cid[AT_APP_COSIGN_CID_LEN] = '\0';
    memcpy(out->signer_did,
           in->signer, AT_APP_COSIGN_DID_LEN);
    out->signer_did[AT_APP_COSIGN_DID_LEN] = '\0';
    memcpy(out->sig, in->sig,
           AT_APP_COSIGN_SIG_LEN);
    out->sig[AT_APP_COSIGN_SIG_LEN] = '\0';
    out->seq = in->seq;
    out->ts = in->ts;
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_cosign_sig, PEER_COSIGN_SIG_OBSERVED, decode_cosign_sig)

static int decode_proximity(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_proximity_msg_t *in = AT_MSG_EXT_CONST(msg, peer_proximity_msg_t);
    at_app_proximity_t *out = AT_APP_EVENT_EXT(ev, at_app_proximity_t);
    ev->kind = AT_APP_EVENT_PROXIMITY;
    memcpy(out->peer_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    out->band = (int32_t)in->band;
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_proximity, PEER_PROXIMITY_OBSERVED, decode_proximity)

static int decode_profile(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_profile_msg_t *in = AT_MSG_EXT_CONST(msg, peer_profile_msg_t);
    at_app_profile_t *out = AT_APP_EVENT_EXT(ev, at_app_profile_t);
    ev->kind = AT_APP_EVENT_PEER_PROFILE;
    memcpy(out->peer_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    /* Bounded copy of the compact profile JSON; the emitter NUL-caps it
     * and the event was memset, so a short string stays terminated. */
    memcpy(out->profile_json,
           in->profile_json, AT_APP_PROFILE_JSON_LEN);
    out->profile_json[AT_APP_PROFILE_JSON_LEN] = '\0';
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_profile, PEER_PROFILE_OBSERVED, decode_profile)

static int decode_connection_request(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_connection_msg_t *in = AT_MSG_EXT_CONST(msg, peer_connection_msg_t);
    at_app_connection_t *out = AT_APP_EVENT_EXT(ev, at_app_connection_t);
    ev->kind = AT_APP_EVENT_CONNECTION_REQUEST;
    memcpy(out->peer_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    out->state = in->state;
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_connection_request, PEER_CONNECTION_REQUEST_OBSERVED, decode_connection_request)

static int decode_connection_state(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_connection_msg_t *in = AT_MSG_EXT_CONST(msg, peer_connection_msg_t);
    at_app_connection_t *out = AT_APP_EVENT_EXT(ev, at_app_connection_t);
    ev->kind = AT_APP_EVENT_CONNECTION_STATE;
    memcpy(out->peer_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    out->state = in->state;
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_connection_state, PEER_CONNECTION_STATE_OBSERVED, decode_connection_state)

static int decode_dm(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_dm_msg_t *in = AT_MSG_EXT_CONST(msg, peer_dm_msg_t);
    at_app_dm_t *out = AT_APP_EVENT_EXT(ev, at_app_dm_t);
    ev->kind = AT_APP_EVENT_DM;
    memcpy(out->peer_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    out->seq = in->seq;
    out->ts = in->ts;
    /* Bounded copy of the message body; the emitter NUL-caps it and the
     * event was memset, so a short string stays terminated. */
    memcpy(out->text, in->text, AT_APP_DM_TEXT_LEN);
    out->text[AT_APP_DM_TEXT_LEN] = '\0';
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_dm, PEER_DM_OBSERVED, decode_dm)

static int decode_post(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_post_msg_t *in = AT_MSG_EXT_CONST(msg, peer_post_msg_t);
    at_app_post_t *out = AT_APP_EVENT_EXT(ev, at_app_post_t);
    ev->kind = AT_APP_EVENT_POST;
    memcpy(out->author_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    /* The emitter NUL-caps both strings; the event was memset, so a
     * short string stays terminated after the bounded copy. */
    memcpy(out->post_id, in->post_id,
           AT_APP_POST_ID_LEN);
    out->post_id[AT_APP_POST_ID_LEN] = '\0';
    out->seq = in->seq;
    out->ts = in->ts;
    out->required_tier = in->required_tier;
    memcpy(out->body, in->body,
           AT_APP_POST_BODY_LEN);
    out->body[AT_APP_POST_BODY_LEN] = '\0';
    memcpy(out->community, in->community, AT_APP_POST_COMMUNITY_LEN);
    out->community[AT_APP_POST_COMMUNITY_LEN] = '\0';
    memcpy(out->labels, in->labels, AT_APP_POST_LABELS_LEN);
    out->labels[AT_APP_POST_LABELS_LEN] = '\0';
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_post, PEER_POST_OBSERVED, decode_post)

static int decode_community_policy(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_community_policy_msg_t *in = AT_MSG_EXT_CONST(msg, peer_community_policy_msg_t);
    at_app_community_policy_t *out = AT_APP_EVENT_EXT(ev, at_app_community_policy_t);
    ev->kind = AT_APP_EVENT_COMMUNITY_POLICY;
    memcpy(out->carrier_uuid, in->peer_uuid, AT_APP_UUID_LEN);
    memcpy(out->community, in->community, AT_APP_POST_COMMUNITY_LEN);
    out->community[AT_APP_POST_COMMUNITY_LEN] = '\0';
    memcpy(out->policy_id, in->policy_id, AT_APP_POST_ID_LEN);
    out->policy_id[AT_APP_POST_ID_LEN] = '\0';
    out->seq = in->seq;
    out->ts = in->ts;
    memcpy(out->bundle, in->bundle, AT_APP_COMMUNITY_POLICY_BUNDLE_LEN);
    out->bundle[AT_APP_COMMUNITY_POLICY_BUNDLE_LEN] = '\0';
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_community_policy, PEER_COMMUNITY_POLICY_OBSERVED, decode_community_policy)

static int decode_post_label(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_post_label_msg_t *in = AT_MSG_EXT_CONST(msg, peer_post_label_msg_t);
    at_app_post_label_t *out = AT_APP_EVENT_EXT(ev, at_app_post_label_t);
    ev->kind = AT_APP_EVENT_POST_LABEL;
    memcpy(out->publisher_uuid, in->peer_uuid, AT_APP_UUID_LEN);
    memcpy(out->community, in->community, AT_APP_POST_COMMUNITY_LEN);
    out->community[AT_APP_POST_COMMUNITY_LEN] = '\0';
    memcpy(out->post_id, in->post_id, AT_APP_POST_ID_LEN);
    out->post_id[AT_APP_POST_ID_LEN] = '\0';
    memcpy(out->label_id, in->label_id, AT_APP_POST_ID_LEN);
    out->label_id[AT_APP_POST_ID_LEN] = '\0';
    out->seq = in->seq;
    out->ts = in->ts;
    out->hops = in->hops;
    memcpy(out->bundle, in->bundle, AT_APP_POST_LABEL_BUNDLE_LEN);
    out->bundle[AT_APP_POST_LABEL_BUNDLE_LEN] = '\0';
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_post_label, PEER_POST_LABEL_OBSERVED, decode_post_label)

static int decode_reaction(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_reaction_msg_t *in = AT_MSG_EXT_CONST(msg, peer_reaction_msg_t);
    at_app_reaction_t *out = AT_APP_EVENT_EXT(ev, at_app_reaction_t);
    ev->kind = AT_APP_EVENT_REACTION;
    memcpy(out->peer_uuid,
           in->peer_uuid, AT_APP_UUID_LEN);
    /* The emitter NUL-caps the id; the event was memset, so a short
     * string stays terminated after the bounded copy. */
    memcpy(out->post_id, in->post_id,
           AT_APP_POST_ID_LEN);
    out->post_id[AT_APP_POST_ID_LEN] = '\0';
    out->seq = in->seq;
    out->ts = in->ts;
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_reaction, PEER_REACTION_OBSERVED, decode_reaction)

static int decode_file(const generic_msg_t *msg, at_app_event_t *ev)
{
    const peer_file_msg_t *in = AT_MSG_EXT_CONST(msg, peer_file_msg_t);
    at_app_file_t *out = AT_APP_EVENT_EXT(ev, at_app_file_t);
    ev->kind = AT_APP_EVENT_FILE;
    memcpy(out->peer_uuid, in->peer_uuid, AT_APP_UUID_LEN);
    /* The emitter NUL-caps every string; the event was memset, so a short
     * string stays terminated after the bounded copy. */
    memcpy(out->xfer_id, in->xfer_id, AT_APP_FILE_ID_LEN);
    out->xfer_id[AT_APP_FILE_ID_LEN] = '\0';
    out->state = in->state;
    out->outgoing = in->outgoing;
    out->size = in->size;
    out->bytes_done = in->bytes_done;
    out->ts = in->ts;
    memcpy(out->name, in->name, AT_APP_FILE_NAME_LEN);
    out->name[AT_APP_FILE_NAME_LEN] = '\0';
    memcpy(out->reason, in->reason, AT_APP_FILE_REASON_LEN);
    out->reason[AT_APP_FILE_REASON_LEN] = '\0';
    memcpy(out->path, in->path, AT_APP_FILE_PATH_LEN);
    out->path[AT_APP_FILE_PATH_LEN] = '\0';
    return 0;
}
AT_APP_EVENT_DECODER_REGISTER(decode_file, PEER_FILE_OBSERVED, decode_file)

void at_agora_link(void)
{
    at_social_msg_types_link();
}

/* ---- app -> AT: the social verbs. ---- */

int at_app_events_set_position(at_app_events_t *handle, const char *q_out,
                               const char *geohash)
{
    if (handle == NULL || !at_app_name_survives(q_out))
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_SET_POSITION;
    req.info.net_msg.encrypt = false;
    /* {"pos": "<geohash>"}; NULL/"" opts out (clears own position). */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "pos",
                        json_string(geohash != NULL ? geohash : ""));
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_set_profile(at_app_events_t *handle, const char *q_out,
                              const char *profile_json)
{
    if (handle == NULL || !at_app_name_survives(q_out))
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    /* Payload IS the profile object; NULL/"" => empty object => clears it. */
    json_t *env = NULL;
    if (profile_json != NULL && profile_json[0] != '\0') {
        json_error_t jerr;
        env = json_loads(profile_json, 0, &jerr);
        if (env == NULL || !json_is_object(env)) {
            if (env != NULL) json_decref(env);
            return -1;
        }
    } else {
        env = json_object();
        if (env == NULL) return -1;
    }
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_SET_PROFILE;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

/* Shared body for the two connection app→AT verbs (Increment 5): pack
 * {"peer": "<uuid_str>"} plus, for a respond, {"accept": <bool>}, and send the
 * verb to identity. @p accept is ignored unless @p include_accept. */
static int connect_send(at_app_events_t *handle, const char *q_out,
                        const char *verb,
                        const uint8_t peer_uuid[AT_APP_UUID_LEN],
                        bool include_accept, bool accept)
{
    if (handle == NULL || !at_app_name_survives(q_out) || peer_uuid == NULL)
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    char uuid_str[37];
    uuid_unparse_lower((const unsigned char *)peer_uuid, uuid_str);
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "peer", json_string(uuid_str));
    if (include_accept)
        json_object_set_new(env, "accept", json_boolean(accept));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)verb;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_connect_request(at_app_events_t *handle, const char *q_out,
                                  const uint8_t peer_uuid[AT_APP_UUID_LEN])
{
    return connect_send(handle, q_out, AT_APP_CONNECT_REQUEST, peer_uuid,
                        false, false);
}

int at_app_events_connect_respond(at_app_events_t *handle, const char *q_out,
                                  const uint8_t peer_uuid[AT_APP_UUID_LEN],
                                  bool accept)
{
    return connect_send(handle, q_out, AT_APP_CONNECT_RESPOND, peer_uuid,
                        true, accept);
}

int at_app_events_request_attend(at_app_events_t *handle, const char *q_out,
                                 const uint8_t peer_uuid[AT_APP_UUID_LEN])
{
    /* Same {"peer": "<uuid>"} shape as a connect request; identity issues a
     * nonce-fresh operator_attest_query to the peer (Phase 2, presence). */
    return connect_send(handle, q_out, AT_APP_REQUEST_ATTEND, peer_uuid,
                        false, false);
}

int at_app_events_request_proximity(at_app_events_t *handle, const char *q_out,
                                    const uint8_t peer_uuid[AT_APP_UUID_LEN])
{
    /* {"peer": "<uuid>"}; identity runs the pairwise distance-band probe with
     * this CONNECTED peer (Phase 2, private proximity). */
    return connect_send(handle, q_out, AT_APP_REQUEST_PROXIMITY, peer_uuid,
                        false, false);
}

int at_app_events_set_exact_position(at_app_events_t *handle, const char *q_out,
                                     bool opt_in, double lat, double lon)
{
    if (handle == NULL || !at_app_name_survives(q_out))
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    /* {"lat","lon"} to opt in; an empty object to opt out (clear). The exact
     * position is stored LOCAL-ONLY by identity and never advertised. */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    if (opt_in) {
        json_object_set_new(env, "lat", json_real(lat));
        json_object_set_new(env, "lon", json_real(lon));
    }
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_SET_EXACT_POSITION;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_send_dm(at_app_events_t *handle, const char *q_out,
                          const uint8_t peer_uuid[AT_APP_UUID_LEN],
                          const char *text)
{
    if (handle == NULL || !at_app_name_survives(q_out) || peer_uuid == NULL)
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    char uuid_str[37];
    uuid_unparse_lower((const unsigned char *)peer_uuid, uuid_str);
    /* {"peer": "<uuid_str>", "text": "<body>"}; identity bound-truncates text
     * and sends the directed encrypted peer_dm. */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "peer", json_string(uuid_str));
    json_object_set_new(env, "text", json_string(text != NULL ? text : ""));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_SEND_DM;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_publish_post(at_app_events_t *handle, const char *q_out,
                               const char *body, int required_tier)
{
    if (handle == NULL || !at_app_name_survives(q_out))
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    if (required_tier < 0) required_tier = 0;
    if (required_tier > 4) required_tier = 4;
    /* {"body": "<body>", "tier": <int>}; identity signs, group-encrypts and
     * multicasts the post. */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "body", json_string(body != NULL ? body : ""));
    json_object_set_new(env, "tier", json_integer(required_tier));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_PUBLISH_POST;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_advertise_business(at_app_events_t *handle, const char *q_out,
                                     const char *polity_did, const char *bundle,
                                     int64_t seq)
{
    if (handle == NULL || !at_app_name_survives(q_out) || polity_did == NULL
        || bundle == NULL || polity_did[0] == '\0' || bundle[0] == '\0')
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    /* {"polity": "<did>", "bundle": "<opaque ethne json>", "seq": <int>};
     * identity signs the ad with THIS node's key and group-multicasts it. */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "polity", json_string(polity_did));
    json_object_set_new(env, "bundle", json_string(bundle));
    json_object_set_new(env, "seq", json_integer((json_int_t)seq));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_ADVERTISE_BUSINESS;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_publish_business_post(at_app_events_t *handle, const char *q_out,
                                        const char *polity_did, const char *bundle,
                                        int64_t seq)
{
    if (handle == NULL || !at_app_name_survives(q_out) || polity_did == NULL
        || bundle == NULL || polity_did[0] == '\0' || bundle[0] == '\0')
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    /* {"polity": "<did>", "bundle": "<opaque ethne {post,delegation}>",
     *  "seq": <int>}; identity signs the canonical post with THIS node's key
     * and group-multicasts it. The envoy signature that makes it the
     * business's word is already INSIDE the bundle — this call cannot and does
     * not confer it. */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "polity", json_string(polity_did));
    json_object_set_new(env, "bundle", json_string(bundle));
    json_object_set_new(env, "seq", json_integer((json_int_t)seq));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_PUBLISH_BUSINESS_POST;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_set_customer(at_app_events_t *handle, const char *q_out,
                               const char *polity_did, int satisfaction,
                               const char *bundle, int64_t seq)
{
    if (handle == NULL || !at_app_name_survives(q_out) || polity_did == NULL
        || polity_did[0] == '\0')
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    if (satisfaction > 4) satisfaction = 4;
    /* {"polity": "<did>", "satisfaction": <0..4 | -1 to clear>,
     *  "bundle": "<opaque ethne json>", "seq": <int>}. A negative satisfaction
     * clears the customer edge, after which this node simply goes quiet about
     * the business — it never publishes a negative. */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "polity", json_string(polity_did));
    json_object_set_new(env, "satisfaction", json_integer(satisfaction));
    json_object_set_new(env, "bundle",
                        json_string(bundle != NULL ? bundle : ""));
    json_object_set_new(env, "seq", json_integer((json_int_t)seq));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_SET_CUSTOMER;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_react_post(at_app_events_t *handle, const char *q_out,
                             const uint8_t author_uuid[AT_APP_UUID_LEN],
                             const char *post_id)
{
    if (handle == NULL || !at_app_name_survives(q_out) || author_uuid == NULL
        || post_id == NULL)
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    char uuid_str[37];
    uuid_unparse_lower((const unsigned char *)author_uuid, uuid_str);
    /* {"author": "<uuid_str>", "post_id": "<hex>"}; identity sends the directed
     * encrypted peer_reaction to the author. */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "author", json_string(uuid_str));
    json_object_set_new(env, "post_id", json_string(post_id));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_REACT_POST;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_block(at_app_events_t *handle, const char *q_out,
                        const uint8_t peer_uuid[AT_APP_UUID_LEN])
{
    if (handle == NULL || !at_app_name_survives(q_out) || peer_uuid == NULL)
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    char uuid_str[37];
    uuid_unparse_lower((const unsigned char *)peer_uuid, uuid_str);
    /* {"peer": "<uuid_str>"}; identity clamps the peer's local tier to 0. */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "peer", json_string(uuid_str));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_BLOCK;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_unblock(at_app_events_t *handle, const char *q_out,
                          const uint8_t peer_uuid[AT_APP_UUID_LEN])
{
    if (handle == NULL || !at_app_name_survives(q_out) || peer_uuid == NULL)
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    char uuid_str[37];
    uuid_unparse_lower((const unsigned char *)peer_uuid, uuid_str);
    /* {"peer": "<uuid_str>"}; identity removes the block and re-emits
     * peer_observed so the app sees it land. */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "peer", json_string(uuid_str));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_UNBLOCK;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_report_peer(at_app_events_t *handle, const char *q_out,
                              const uint8_t peer_uuid[AT_APP_UUID_LEN])
{
    if (handle == NULL || !at_app_name_survives(q_out) || peer_uuid == NULL)
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    char uuid_str[37];
    uuid_unparse_lower((const unsigned char *)peer_uuid, uuid_str);
    /* {"peer": "<uuid_str>"} and nothing else: the reason the operator chose
     * never leaves the app (see AT_APP_REPORT_PEER). */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "peer", json_string(uuid_str));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_REPORT_PEER;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_request_cosign(at_app_events_t *handle, const char *q_out,
                                 const uint8_t *peer_uuids, size_t n_peers,
                                 const char *record, const char *op,
                                 const char *polity_did, const char *cid,
                                 const char *bytes)
{
    if (handle == NULL || !at_app_name_survives(q_out) || peer_uuids == NULL
        || n_peers == 0 || polity_did == NULL || cid == NULL
        || polity_did[0] == '\0' || cid[0] == '\0')
        return -1;
    /* Refuse an unknown act or a payload that never came from an exporter,
     * HERE, where the caller still has it. A malformed ask that reached the
     * signers would only be refused after somebody had been interrupted to look
     * at it. */
    if (!at_cosign_op_ok(record, op) || !at_cosign_bytes_ok(bytes))
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    json_t *peers = json_array();
    if (peers == NULL)
        return -1;
    for (size_t i = 0; i < n_peers; i++) {
        char uuid_str[37];
        uuid_unparse_lower((const unsigned char *)(peer_uuids + i * AT_APP_UUID_LEN),
                           uuid_str);
        if (json_array_append_new(peers, json_string(uuid_str)) != 0) {
            json_decref(peers);
            return -1;
        }
    }
    /* {"peers": [...], "record", "op", "polity", "cid", "bytes"}; identity sends
     * each named peer a directed encrypted peer_cosign_request. NO description:
     * every signer's own node derives what the bytes commit to. */
    json_t *env = json_object();
    if (env == NULL) {
        json_decref(peers);
        return -1;
    }
    json_object_set_new(env, "peers", peers);
    json_object_set_new(env, "record", json_string(record));
    json_object_set_new(env, "op", json_string(op));
    json_object_set_new(env, "polity", json_string(polity_did));
    json_object_set_new(env, "cid", json_string(cid));
    json_object_set_new(env, "bytes", json_string(bytes));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_REQUEST_COSIGN;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

int at_app_events_return_cosign(at_app_events_t *handle, const char *q_out,
                                const uint8_t peer_uuid[AT_APP_UUID_LEN],
                                const char *cid, const char *signer_did,
                                const char *sig_hex)
{
    if (handle == NULL || !at_app_name_survives(q_out) || peer_uuid == NULL
        || cid == NULL || signer_did == NULL || sig_hex == NULL
        || cid[0] == '\0' || signer_did[0] == '\0' || sig_hex[0] == '\0')
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    char uuid_str[37];
    uuid_unparse_lower((const unsigned char *)peer_uuid, uuid_str);
    /* {"peer", "cid", "signer", "sig"}; identity sends the requester a directed
     * encrypted peer_cosign_sig. The signature is checked against the payload by
     * the assembling node — the only one that holds it. */
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "peer", json_string(uuid_str));
    json_object_set_new(env, "cid", json_string(cid));
    json_object_set_new(env, "signer", json_string(signer_did));
    json_object_set_new(env, "sig", json_string(sig_hex));
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)AT_APP_RETURN_COSIGN;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    return messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
}

/* Send one app verb to identity with @p env (consumed). */
static int _send_verb(const char *q_out, const char *verb, json_t *env)
{
    if (env == NULL)
        return -1;
    generic_msg_t req = {0};
    req.type = NET_MESSAGE;
    snprintf(req.info.net_msg.process, sizeof(req.info.net_msg.process),
             "identity");
    req.info.net_msg.function = (char *)verb;
    req.info.net_msg.encrypt = false;
    if (net_msg_pack_json(&req.info.net_msg, env) != 0) {
        json_decref(env);
        return -1;
    }
    json_decref(env);
    /* The send serializes; the packed buffer is still ours (net_msg_t.obj). */
    int rc = messaging_send(q_out, NET_MESSAGE, &req, false) == 0 ? 0 : -1;
    net_msg_free_obj(&req.info.net_msg);
    return rc;
}

int at_app_events_publish_post_scoped(at_app_events_t *handle, const char *q_out,
                                      const char *body, int required_tier,
                                      const char *community, const char *labels_csv)
{
    if (handle == NULL || !at_app_name_survives(q_out))
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    if (required_tier < 0) required_tier = 0;
    if (required_tier > 4) required_tier = 4;
    json_t *env = json_object();
    if (env == NULL)
        return -1;
    json_object_set_new(env, "body", json_string(body != NULL ? body : ""));
    json_object_set_new(env, "tier", json_integer(required_tier));
    if (community != NULL && community[0] != '\0')
        json_object_set_new(env, "community", json_string(community));
    /* Split the labels; identity validates them, and refuses the post whole
     * if any is malformed. */
    json_t *labels = json_array();
    if (labels_csv != NULL && labels != NULL) {
        const char *p = labels_csv;
        while (*p != '\0') {
            const char *comma = strchr(p, ',');
            size_t n = comma ? (size_t)(comma - p) : strlen(p);
            if (n > 0)
                json_array_append_new(labels, json_stringn(p, n));
            if (comma == NULL)
                break;
            p = comma + 1;
        }
    }
    json_object_set_new(env, "labels", labels);
    return _send_verb(q_out, AT_APP_PUBLISH_POST, env);
}

int at_app_events_follow_community(at_app_events_t *handle, const char *q_out,
                                   const char *community, const char *bundle,
                                   int64_t seq)
{
    if (handle == NULL || !at_app_name_survives(q_out) || community == NULL
        || bundle == NULL || community[0] == '\0' || bundle[0] == '\0')
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    return _send_verb(q_out, AT_APP_FOLLOW_COMMUNITY,
                      json_pack("{s:s, s:s, s:I}", "community", community, "bundle",
                                bundle, "seq", (json_int_t)seq));
}

int at_app_events_unfollow_community(at_app_events_t *handle, const char *q_out,
                                     const char *community)
{
    if (handle == NULL || !at_app_name_survives(q_out) || community == NULL
        || community[0] == '\0')
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    return _send_verb(q_out, AT_APP_UNFOLLOW_COMMUNITY,
                      json_pack("{s:s}", "community", community));
}

int at_app_events_publish_post_label(at_app_events_t *handle, const char *q_out,
                                     const char *community, const char *post_id,
                                     const char *bundle, int64_t seq)
{
    if (handle == NULL || !at_app_name_survives(q_out) || community == NULL
        || post_id == NULL || bundle == NULL || community[0] == '\0'
        || bundle[0] == '\0')
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    return _send_verb(q_out, AT_APP_PUBLISH_POST_LABEL,
                      json_pack("{s:s, s:s, s:s, s:I}", "community", community,
                                "post_id", post_id, "bundle", bundle, "seq",
                                (json_int_t)seq));
}

/* {"peer","id"[,"path"]}: the four file verbs share a shape. The id is checked
 * here as well as in identity, so a malformed one fails at the call. */
static int _file_verb(at_app_events_t *handle, const char *q_out, const char *verb,
                      const uint8_t peer_uuid[AT_APP_UUID_LEN],
                      const char *xfer_id, const char *path)
{
    if (handle == NULL || !at_app_name_survives(q_out) || peer_uuid == NULL
        || !at_file_id_ok(xfer_id))
        return -1;
    if (!messaging_bound(q_out))
        return AT_APP_NOT_READY;
    char uuid_str[37];
    uuid_unparse_lower((const unsigned char *)peer_uuid, uuid_str);
    json_t *env = json_pack("{s:s, s:s}", "peer", uuid_str, "id", xfer_id);
    if (env != NULL && path != NULL)
        json_object_set_new(env, "path", json_string(path));
    return _send_verb(q_out, verb, env);
}

int at_app_events_file_offer(at_app_events_t *handle, const char *q_out,
                             const uint8_t peer_uuid[AT_APP_UUID_LEN],
                             const char *xfer_id, const char *path)
{
    if (path == NULL || path[0] == '\0')
        return -1;
    return _file_verb(handle, q_out, AT_APP_FILE_OFFER, peer_uuid, xfer_id, path);
}

int at_app_events_file_accept(at_app_events_t *handle, const char *q_out,
                              const uint8_t peer_uuid[AT_APP_UUID_LEN],
                              const char *xfer_id)
{
    return _file_verb(handle, q_out, AT_APP_FILE_ACCEPT, peer_uuid, xfer_id, NULL);
}

int at_app_events_file_decline(at_app_events_t *handle, const char *q_out,
                               const uint8_t peer_uuid[AT_APP_UUID_LEN],
                               const char *xfer_id)
{
    return _file_verb(handle, q_out, AT_APP_FILE_DECLINE, peer_uuid, xfer_id, NULL);
}

int at_app_events_file_cancel(at_app_events_t *handle, const char *q_out,
                              const uint8_t peer_uuid[AT_APP_UUID_LEN],
                              const char *xfer_id)
{
    return _file_verb(handle, q_out, AT_APP_FILE_CANCEL, peer_uuid, xfer_id, NULL);
}
