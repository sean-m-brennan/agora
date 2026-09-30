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
 * @file agorad.c
 * @brief Standalone AutonomousTrust daemon for Agora.
 *
 * Agora runs the AT node in its OWN process so the Flutter GUI process never
 * has to `fork()` (which `at_node_start` does). The GUI spawns this binary and
 * then talks to it purely as an app-events *client* (see at_agora_shim).
 *
 * Supervision model: `run_autonomous_trust()` does NOT block. Internally it
 * `daemonize()`s (a double-fork + setsid, AT's default FORK=2), so the real node
 * runs as a DETACHED grandchild (reparented to init) and the call returns that
 * grandchild's PID (>0) to us. If we simply exited, the node would be orphaned
 * and survive the GUI — quitting the app would leak a running node. So agorad
 * stays in the foreground as a thin supervisor: it captures the daemon PID,
 * forwards SIGTERM/SIGINT to it (the node installs its own SIGTERM handler for a
 * graceful shutdown), and polls until it exits. The Dart supervisor therefore
 * gets exactly what it expects — a long-lived child it can `Process.kill`, whose
 * exit means the node is truly gone. (A future in-process FORK=0 AT-core build
 * would return 0 and block instead; we handle that too.)
 *
 * Queue-direction footgun (documented in SOCIAL_APP_PLAN.md §5.1):
 *   run_autonomous_trust(q_in, q_out, ...) names q_in = app->AT, q_out = AT->app
 *   — the OPPOSITE of at_node_config_t. We take argv in app->AT, AT->app order
 *   and pass them straight through, so argv matches run_autonomous_trust().
 *
 * Usage:
 *   agorad <app_to_at_queue> <at_to_app_queue> [log_level] [log_file]
 *     queues   : BARE relative names (NOT paths). AT roots each socket at
 *                $AUTONOMOUS_TRUST_ROOT/var/at/<name> (message.c unix_addr), so
 *                an absolute path is wrongly concatenated under var/at and the
 *                bind fails (ENOENT). The app-events client uses the same bare
 *                names against the same root, so both meet: conventionally
 *                app->AT = "extern_to_at", AT->app = "at_to_extern" (the AT
 *                defaults the app_events.h example uses). Keep the root SHORT —
 *                the full socket path must fit a 108-byte AF_UNIX sun_path.
 *     log_level: 1=DEBUG 2=INFO 3=WARNING 4=ERROR 5=CRITICAL (default 3)
 *     log_file : path, or omitted/"" for stderr
 *
 * Config bootstrap: a node needs an on-disk identity/config under
 * $AUTONOMOUS_TRUST_ROOT/etc/at before it can form a cohort, else it crashes
 * (SIGILL) running subsystems with no identity. We mirror at_node_init()'s
 * config setup (node.c): resolve the root (defaulting it if unset so the daemon
 * is self-contained — the Dart supervisor does not set it), makedirs the cfg +
 * data dirs, and, when no identity exists yet, call random_config() — the
 * non-interactive C analog of Python generate_identity (mints Ed25519/X25519 +
 * UUID, writes identity/network/subsystems.cfg.json). run_autonomous_trust()
 * resolves the same root via the same env var, so the two agree.
 *
 * Per-instance root: honor $AUTONOMOUS_TRUST_ROOT if set (a 2-node same-host
 * test gives each node a distinct root this way); otherwise default to
 * $AGORA_ROOT, then $XDG_STATE_HOME/agora, then $HOME/.local/state/agora.
 */

#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "autonomous_trust.h"
#include "config/configuration.h"  /* get_cfg_dir, get_data_dir, CFG_PATH_LEN */
#include "config/generate.h"       /* random_config */
#include "utilities/util.h"        /* makedirs */
#include "social/at_social.h"      /* at_social_link */

/* True if an identity config already exists in cfg_dir (either serialization). */
static bool identity_present(const char *cfg_dir)
{
    static const char *const names[] = {"identity.cfg.json", "identity.cfg.pb"};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        char path[CFG_PATH_LEN + 32];
        snprintf(path, sizeof(path), "%s/%s", cfg_dir, names[i]);
        if (access(path, F_OK) == 0)
            return true;
    }
    return false;
}

/* Ensure $AUTONOMOUS_TRUST_ROOT is set, the cfg/data dirs exist, and an identity
 * has been generated. Idempotent: an existing identity is preserved. Returns 0
 * on success, non-zero on failure. */
static int ensure_config(void)
{
    const char *root = getenv("AUTONOMOUS_TRUST_ROOT");
    if (root == NULL || root[0] == '\0') {
        char def[CFG_PATH_LEN + 1];
        const char *agora = getenv("AGORA_ROOT");
        const char *xdg = getenv("XDG_STATE_HOME");
        const char *home = getenv("HOME");
        if (agora && agora[0])
            snprintf(def, sizeof(def), "%s", agora);
        else if (xdg && xdg[0])
            snprintf(def, sizeof(def), "%s/agora", xdg);
        else if (home && home[0])
            snprintf(def, sizeof(def), "%s/.local/state/agora", home);
        else
            snprintf(def, sizeof(def), "/tmp/agora-%d", (int)getuid());
        if (setenv("AUTONOMOUS_TRUST_ROOT", def, 1) != 0) {
            fprintf(stderr, "agorad: setenv AUTONOMOUS_TRUST_ROOT failed: %s\n",
                    strerror(errno));
            return 1;
        }
    }

    /* get_cfg_dir/get_data_dir return path_join's result: the byte length on
     * success (positive), -1 on truncation. */
    char cfg_dir[CFG_PATH_LEN + 1];
    char data_dir[CFG_PATH_LEN + 1];
    if (get_cfg_dir(cfg_dir, sizeof(cfg_dir)) < 0 ||
        get_data_dir(data_dir, sizeof(data_dir)) < 0) {
        fprintf(stderr, "agorad: config/data path too long for root '%s'\n",
                getenv("AUTONOMOUS_TRUST_ROOT"));
        return 1;
    }
    /* First contact on by default (an explicit AT_FIRST_CONTACT wins): Agora
     * finds people nearby at its communities' area hubs and connects through
     * it (SOCIAL_APP_PLAN Phase 4, §4.1). It registers with no relay until the
     * app installs a followed community's roster, and AT's own seed list
     * trusts no release key, so a node that follows no hub community reaches
     * nobody new. */
    (void)setenv("AT_FIRST_CONTACT", "1", 0);
    if (makedirs(cfg_dir, 0755) != 0) {
        fprintf(stderr, "agorad: makedirs %s failed: %s\n", cfg_dir, strerror(errno));
        return 1;
    }
    if (makedirs(data_dir, 0755) != 0) {
        fprintf(stderr, "agorad: makedirs %s failed: %s\n", data_dir, strerror(errno));
        return 1;
    }

    if (identity_present(cfg_dir)) {
        fprintf(stderr, "agorad: using existing identity/config in %s\n", cfg_dir);
        return 0;
    }

    fprintf(stderr, "agorad: generating identity/config in %s\n", cfg_dir);
    /* seed_str=NULL -> random_config falls back to AT_PEER_SEED; name comes from
     * AT_PEER_NAME if set. preserve=true internally, so this never clobbers. */
    int rc = random_config(cfg_dir, NULL);
    if (rc != 0) {
        fprintf(stderr, "agorad: config generation failed (rc=%d): %s\n",
                rc, strerror(errno));
        return 1;
    }
    return 0;
}

/* --- daemon supervision ---------------------------------------------------- */
/* The AT node detaches (setsid) into its own session, so it is NOT our child —
 * we cannot waitpid() on it, only kill()/signal it. These globals let the signal
 * handler forward a stop to it even if the stop arrives during startup. */
static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_daemon_pid = 0;

static void forward_stop(int sig)
{
    g_stop = sig;
    if (g_daemon_pid > 0)
        kill((pid_t)g_daemon_pid, SIGTERM);
}

/* Wait for the detached daemon to exit, forwarding any stop we were sent. */
static int supervise(pid_t daemon_pid)
{
    g_daemon_pid = daemon_pid;
    fprintf(stderr, "agorad: AT node running as pid %d (supervising)\n",
            (int)daemon_pid);
    /* A stop may have arrived between the return and setting g_daemon_pid. */
    if (g_stop)
        kill(daemon_pid, SIGTERM);
    /* kill(pid, 0) probes liveness: 0 while alive, -1/ESRCH once gone. */
    while (kill(daemon_pid, 0) == 0) {
        struct timespec ts = {.tv_sec = 0, .tv_nsec = 200 * 1000 * 1000};
        nanosleep(&ts, NULL);
        if (g_stop)
            kill(daemon_pid, SIGTERM);
    }
    fprintf(stderr, "agorad: AT node (pid %d) exited\n", (int)daemon_pid);
    return 0;
}

int main(int argc, char **argv)
{
    /* agorad IS a social node: keep libat_social in the link (present means
     * on; without it the daemon would run with no social verbs at all). */
    at_social_link();
    if (argc < 3) {
        fprintf(stderr,
                "usage: %s <app_to_at_queue> <at_to_app_queue> "
                "[log_level 1-5] [log_file]\n",
                argv[0]);
        return 2;
    }

    char *q_in = argv[1];  /* app -> AT (run_autonomous_trust naming) */
    char *q_out = argv[2]; /* AT -> app */

    log_level_t level = WARNING;
    if (argc >= 4) {
        int l = atoi(argv[3]);
        if (l >= DEBUG && l <= CRITICAL)
            level = (log_level_t)l;
    }

    /* log_file: a real path, or NULL for the foreground/stderr path. NULL makes
     * run_autonomous_trust set NO_STDERR_REDIRECT, so the detached node's (and
     * its subsystems') stderr stays on our stderr — which the Dart supervisor
     * pipes — instead of going to /dev/null. */
    char *log_file = NULL;
    if (argc >= 5 && argv[4] != NULL && argv[4][0] != '\0')
        log_file = argv[4];

    /* Bootstrap identity/config on disk before the node starts, else it SIGILLs
     * running subsystems with no identity. Idempotent across restarts. */
    if (ensure_config() != 0)
        return 1;

    /* Forward the Dart supervisor's stop to the detached node (see supervise()). */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = forward_stop;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    /* NULL capabilities -> use the on-disk config. Advertising agora.profile via
     * a serialized capabilities buffer is a follow-on (needs the AT capability
     * wire format); see SOCIAL_APP_PLAN.md §5.1.
     *
     * Returns: >0 = the detached node's PID (default forking build; supervise it);
     * 0 = it ran in-process and has now shut down (future FORK=0 build); <0 = error. */
    int rc = run_autonomous_trust(q_in, q_out, NULL, 0, level, log_file);
    if (rc > 0)
        return supervise((pid_t)rc);
    if (rc < 0) {
        fprintf(stderr, "agorad: run_autonomous_trust failed (rc=%d)\n", rc);
        return 1;
    }
    return 0;
}
