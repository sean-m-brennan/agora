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
 * @file at_inject.c
 * @brief TEST-ONLY: hand one AutonomousTrust protocol verb to a running node's
 *        own network process, so it goes out on the real wire, really signed.
 *
 * WHY THIS EXISTS. Two reputation flows — slashing (propose/sign/final) and
 * deep resolution (resolve/resolved) — have five `verified` gates between
 * them and NO PRODUCTION ORIGINATOR. Nothing outside conformance and
 * rep_quorum_test.c has ever sent those verbs; the comment in rep_proc.c that
 * claimed _forward_transaction proposes a slash was stale. Those five gates
 * were dead for the same reason every other gate was (the IPC serializer
 * dropped `verified`), and unlike the others they cannot be woken by driving
 * the application — there is nothing to drive.
 *
 * So the cohort injects them. This is a HARNESS, and the traffic it makes is
 * SYNTHETIC: it proves the gate opens, the handler runs and the round-trip
 * works across two real processes on a real wire. It proves nothing about
 * whether a real deployment would ever send such a message, because today no
 * deployment would.
 *
 * WHAT IT DOES NOT DO, deliberately: it adds nothing to the app-event verb
 * allowlist and changes no production code. It talks to the node's OWN
 * network process by queue name — exactly as id_proc.c:1501 does when it
 * sends a group_key_update — so net_proc serializes, SIGNS with that node's
 * identity, encrypts to the target peer and puts it on the wire. The receiver
 * therefore sees a genuine Ed25519 signature from a peer it knows, which is
 * the whole point: a gate that passes because the harness forced a flag would
 * prove nothing at all.
 *
 * It reads the TARGET's identity config to address the message. That is
 * harness knowledge, not protocol knowledge — the cohort owns every node's
 * directory, and staff_cohort.sh already reads each node's
 * etc/at/identity.cfg.json for its uuid.
 *
 *   at_inject --root <sender root> --peer <target identity.cfg.json>
 *             --verb "<protocol verb>" [--process reputation]
 *             --payload '<json>'
 *
 * Exit: 0 sent, 2 bad usage, 3 could not read the peer, 4 send failed.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jansson.h>

#include "config/configuration.h"
#include "identity/identity.h"
/* The PRIVATE headers, on purpose and only here: identity_s is opaque in the
 * public header, and net_msg_pack_json lives in msg_types_priv.h. A test tool
 * reaching into internals is honest about being a test tool; the alternative
 * is re-implementing the stored-seed -> public-key derivation by hand, which
 * would be a second copy of identity_publish's logic waiting to drift. */
#include "identity/identity_priv.h"
#include "utilities/message.h"
#include "utilities/msg_types.h"
#include "utilities/msg_types_priv.h"
#include "utilities/exception.h"

static const char *arg(int argc, char **argv, const char *flag, const char *dflt)
{
    for (int i = 1; i < argc - 1; i++)
        if (strcmp(argv[i], flag) == 0)
            return argv[i + 1];
    return dflt;
}

int main(int argc, char **argv)
{
    const char *root    = arg(argc, argv, "--root", NULL);
    const char *peercfg = arg(argc, argv, "--peer", NULL);
    const char *verb    = arg(argc, argv, "--verb", NULL);
    const char *procnm  = arg(argc, argv, "--process", "reputation");
    const char *payload = arg(argc, argv, "--payload", "{}");

    if (root == NULL || peercfg == NULL || verb == NULL) {
        fprintf(stderr,
                "usage: at_inject --root <dir> --peer <identity.cfg.json> "
                "--verb <verb> [--process <name>] [--payload <json>]\n");
        return 2;
    }

    /* The messaging layer resolves its socket directory from this, and caches
     * it on first use — so it must be set before anything else touches it. */
    setenv("AUTONOMOUS_TRUST_ROOT", root, 1);

    /* The target's public half, read from its own config. read_config_file
     * dispatches on the file's "typename", so this is AT's own loader rather
     * than a hand-rolled parse that could drift from it. */
    identity_t target = {0};
    if (read_config_file(peercfg, &target) != 0) {
        fprintf(stderr, "at_inject: cannot read peer identity from %s\n", peercfg);
        return 3;
    }
    public_identity_t *target_pub = NULL;
    if (identity_publish(&target, &target_pub) != 0 || target_pub == NULL) {
        fprintf(stderr, "at_inject: cannot derive the peer's public identity\n");
        return 3;
    }

    /* A queue of our own: messaging_send needs an assigned source queue, and
     * a short-lived name nothing else uses avoids the unlink-by-name hazard
     * that messaging_init carries (it unlinks before binding, so two holders
     * of one name fight over the socket). */
    queue_t self = {0};
    if (messaging_init("at_inject", &self) != 0) {
        fprintf(stderr, "at_inject: could not bind my own queue under %s\n", root);
        return 4;
    }
    messaging_assign(&self);

    generic_msg_t msg = {0};
    msg.type = NET_MESSAGE;
    strncpy(msg.info.net_msg.process, procnm, PROC_NAME_LEN - 1);
    msg.info.net_msg.function = (char *)verb;
    /* Encrypted, like every reputation verb: they are not on the plaintext
     * allowlist, and a receiver refuses an unencrypted one by design. */
    msg.info.net_msg.encrypt = true;
    memcpy(&msg.info.net_msg.to_whom, target_pub, sizeof(public_identity_t));
    strncpy(msg.info.net_msg.return_to, procnm, PROC_NAME_LEN - 1);

    json_error_t jerr;
    json_t *body = json_loads(payload, 0, &jerr);
    if (body == NULL) {
        fprintf(stderr, "at_inject: --payload is not JSON: %s\n", jerr.text);
        return 2;
    }
    if (net_msg_pack_json(&msg.info.net_msg, body) != 0) {
        json_decref(body);
        fprintf(stderr, "at_inject: could not pack the payload\n");
        return 4;
    }
    json_decref(body);

    if (messaging_send("network", NET_MESSAGE, &msg, false) != 0) {
        fprintf(stderr, "at_inject: send to the network queue failed — is the "
                        "daemon up, and is --root its AUTONOMOUS_TRUST_ROOT?\n");
        messaging_qclose(&self);
        return 4;
    }
    printf("injected %s.%s -> %s (%s)\n", procnm, verb,
           target_pub->nickname[0] ? target_pub->nickname : "peer",
           target_pub->address);
    messaging_qclose(&self);
    return 0;
}
