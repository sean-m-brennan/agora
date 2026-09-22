#!/usr/bin/env bash
#
# business_cohort.sh — Phase 3 P3.2 live check: a business page travels through
# its CUSTOMERS, and outlives the business.
#
# Three real agorad nodes on one virtual L2 segment (bridge + netns, exactly as
# two_node_cohort.sh), driven through the real app-event queues:
#
#   biz  — the business. Publishes its own page once (AT_APP_ADVERTISE_BUSINESS)
#          with a REAL Ethne bundle minted by tool/make_business_bundle.dart, so
#          the artifact on the wire is the genuine polity-root → envoy → page,
#          not a stub.
#   ada  — a customer. Observes biz's ad, then declares a customer edge
#          (AT_APP_SET_CUSTOMER, satisfaction 4) with an EMPTY bundle, so the
#          page it carries is the one it LEARNED.
#   bob  — a bystander who arrives LATE, after biz is dead. He never met the
#          business at all.
#
# What it proves, in order:
#   1. An ad crosses the whole runtime and lands on the APP-EVENT QUEUE (kind 12
#      with the right polity). Conformance cannot see this: it asserts stored
#      state, and the app queue is downstream of the AT_MAIN_QUEUE forwarder —
#      which is exactly where the Phase-2 proximity bug hid (PEER_PROXIMITY_OBSERVED
#      missing from the forwarder switch: the band was computed and then dropped).
#   2. THE PAGE SURVIVES THE BUSINESS. With biz killed, ada's first-person
#      re-advertisement carries the page to bob. The satisfaction bob sees is 4 —
#      ada's own rating, NOT the 255 self-marker — so what reached him is a
#      customer speaking for the shop, which is the only way reach is ever earned.
#   3. THE PAGE STILL PROVES ITSELF. The bundle bob received is byte-identical to
#      the minted one and still verifies through the Ethne cdylib with the
#      business offline: the artifact is self-contained, so a business that goes
#      quiet — or away — does not invalidate what its customers carry.
#
# TWO BACKENDS, one script. Each node needs its own network stack, because AT's
# open discovery is UDP broadcast on a single fixed port:
#
#   netns  — bridge + three network namespaces, as two_node_cohort.sh does.
#            Needs root and a kernel that permits CLONE_NEWNET.
#   docker — three containers on one user-defined bridge network. Same L2 story,
#            and the fallback for sandboxes that deny CLONE_NEWNET. The
#            containers run the HOST-BUILT agorad over a bind mount, with its
#            non-base shared libraries staged next to it, so what runs is exactly
#            what ./build.sh produced — nothing is rebuilt inside the image.
#
# The app-side driver always runs on the HOST either way: the app-event queues
# are AF_UNIX sockets under AUTONOMOUS_TRUST_ROOT, which is a filesystem path,
# not a network one. Under docker the node root is bind-mounted at the SAME
# absolute path inside the container, so both sides name the same socket.
#
# Requirements: python3, dart (to mint the bundle), the built native layer +
# ethne cdylib (./build.sh), and EITHER root + iproute2 (netns) OR a usable
# docker daemon.
#
# Usage:
#   sudo ./test/cohort/business_cohort.sh
#   BACKEND=docker ./test/cohort/business_cohort.sh
#   WAIT=90 KEEP=1 ./test/cohort/business_cohort.sh
#
# Env knobs: BACKEND (auto|netns|docker, default auto), WAIT (per-phase timeout
#   secs, default 60), SUBNET (default 10.9.1), GEO (the shared coarse bucket,
#   default u4pruy), KEEP=1 (leave the network and run dir up for inspection).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_AGORA_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "$PWD")"
AGORA_DIR="${1:-${AGORA_DIR:-$DEFAULT_AGORA_DIR}}"
AGORA_DIR="$(cd "$AGORA_DIR" 2>/dev/null && pwd || echo "$AGORA_DIR")"
NATIVE="$AGORA_DIR/native/build"
AGORAD="$NATIVE/agorad"
SHIM="$NATIVE/libagora_shim.so"
ATCORE="$NATIVE/at_core"
ETHNE="${AGORA_ETHNE_PATH:-$NATIVE/libethne_agora.so}"

WAIT="${WAIT:-60}"
SUBNET="${SUBNET:-10.9.1}"
GEO="${GEO:-u4pruy}"
# .11/.12/.13, not .1/.2/.3: a docker bridge network claims .1 for its own
# gateway, and a container asking for it is refused.
IP_BIZ="$SUBNET.11"; IP_ADA="$SUBNET.12"; IP_BOB="$SUBNET.13"; PREFIX=24

NS_BIZ=agbiz; NS_ADA=agada; NS_BOB=agbob
BR=agbr1
V_BIZ=agvb; V_BIZB=agvbb; V_ADA=agva; V_ADAB=agvab; V_BOB=agvo; V_BOBB=agvob

BACKEND="${BACKEND:-auto}"
NET=agora-biz-net                          # docker network name

# The run dir lives under the agora directory, not /tmp: a docker daemon only
# bind-mounts paths shared with it, and in a sandbox that is the repo tree. The
# socket path stays well inside sun_path's 108 bytes ($ROOT/var/at/<queue>).
RUN="$AGORA_DIR/.cohort/biz-$$"
ROOT_BIZ="$RUN/biz"; ROOT_ADA="$RUN/ada"; ROOT_BOB="$RUN/bob"; LIBSTAGE="$RUN/lib"
mkdir -p "$ROOT_BIZ" "$ROOT_ADA" "$ROOT_BOB" "$LIBSTAGE"

PID_BIZ=""; PID_ADA=""; PID_BOB=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
if ! have python3; then err "python3 not found."; exit 1; fi
if ! have dart; then err "'dart' not found (needed to mint the Ethne bundle); add the Flutter SDK to PATH."; exit 1; fi
# THE DART BINARY every tool below runs through — deliberately the Dart SDK's
# OWN binary, not the `dart` wrapper in flutter/bin that PATH resolves to.
#
# The wrapper sources bin/internal/shared.sh, whose upgrade_flutter() runs on
# EVERY invocation. It rewrites bin/cache/engine.stamp and engine.realm, and if
# it judges the cache stale it goes much further: takes the SDK-wide lock,
# downloads and unpacks a Dart SDK, re-runs pub, rebuilds
# flutter_tools.snapshot. That is Flutter keeping its own install honest and has
# nothing to do with running a project tool. This script runs under sudo because
# netns needs root, so under the wrapper every bit of it happens AS ROOT inside
# a developer-owned SDK. engine.stamp is replaced by `mv`, so it comes back
# owned by root — that one self-heals, because the next ordinary flutter command
# mv's over it again. A root-downloaded dart-sdk/ or a root-written snapshot
# does not self-heal and needs a manual chown. (engine.realm is truncated in
# place, so it keeps its owner; it is the stamp that turns over.) Each of the
# dart calls below also prints the "you appear to be trying to run flutter as
# root" clippy, which is how this was noticed.
#
# The SDK binary is the same dart with none of that install bookkeeping. A bare
# Dart SDK on PATH has no bin/cache/dart-sdk, in which case what PATH found
# stands.
DART="$(command -v dart)"
_dart_real="$(readlink -f "$DART" 2>/dev/null || printf '%s' "$DART")"
_sdk_dart="$(dirname "$_dart_real")/cache/dart-sdk/bin/dart"
[ -x "$_sdk_dart" ] && DART="$_sdk_dart"

# Run a command as whoever invoked sudo, when there is such a person. Used for
# `flutter pub get` alone: it writes .dart_tool/ and the pub cache, both of
# which belong to that user, and doing it as root leaves root-owned files that
# their next ordinary build cannot rewrite. PATH is passed explicitly for the
# same reason the header tells you to invoke this script with it — sudoers
# secure_path would otherwise drop the Flutter SDK on the way back down.
as_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" -E env "PATH=$PATH" "$@"
  else
    "$@"
  fi
}

# `.dart_tool/package_config.json` holds ABSOLUTE paths into $HOME/.pub-cache,
# so it goes stale whenever the checkout moves between machines or $HOME
# changes underneath it. `package:ffi` then stops resolving and Phase 0 dies in
# a wall of "'Utf8' isn't a type" / "calloc isn't defined" that reads like a
# broken binding and is nothing of the kind. Fetching first is the cure and
# costs a second when it is already correct. --offline because the cache
# already holds these packages; this harness has no business reaching pub.dev.
if have flutter; then
  (cd "$AGORA_DIR" && as_user flutter pub get --offline) >/dev/null 2>&1 \
    || err "'flutter pub get' failed — package:ffi may not resolve below."
fi

for f in "$AGORAD" "$SHIM" "$ATCORE/libautonomous_trust.so" "$ETHNE"; do
  if [ ! -e "$f" ]; then err "missing artifact: $f"; err "build first: (cd '$AGORA_DIR' && ./build.sh)"; exit 1; fi
done

netns_usable() {
  [ "$(id -u)" -eq 0 ] || return 1
  have ip || return 1
  ip netns add _agora_probe 2>/dev/null || return 1
  ip netns del _agora_probe 2>/dev/null
  return 0
}
docker_usable() { have docker && docker info >/dev/null 2>&1; }

case "$BACKEND" in
  netns)  netns_usable || { err "BACKEND=netns but namespaces are not usable here (need root + iproute2 + CLONE_NEWNET)."; exit 1; } ;;
  docker) docker_usable || { err "BACKEND=docker but no usable docker daemon."; exit 1; } ;;
  auto)
    if netns_usable; then BACKEND=netns
    elif docker_usable; then BACKEND=docker
    else
      err "no usable backend: network namespaces are denied here (need root +"
      err "iproute2 + CLONE_NEWNET) and no docker daemon answered."
      exit 1
    fi ;;
  *) err "BACKEND must be auto, netns or docker"; exit 1 ;;
esac
log "Backend: $BACKEND"

# --------------------------------------------------------------------------- #
# Backend primitives. Four verbs — net_up, node_start, node_stop, net_down —
# so the phases below read the same whichever isolation the host allows.
# --------------------------------------------------------------------------- #
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:26.04}"

stage_libs() {
  # Copy agorad's non-base shared libraries next to the run dir, so a stock
  # ubuntu image can load the HOST-BUILT binary without installing anything
  # (apt inside the container may have no route out of a sandbox anyway).
  local lib
  for lib in $(ldd "$AGORAD" "$ATCORE/libautonomous_trust.so" 2>/dev/null \
               | awk '/=> \// {print $3}' | sort -u); do
    case "$lib" in
      */libc.so.*|*/libm.so.*|*/ld-linux*) continue ;;   # in every base image
    esac
    cp -n "$lib" "$LIBSTAGE/" 2>/dev/null || true
  done
}

net_up() {
  if [ "$BACKEND" = netns ]; then
    log "Creating bridge $BR + three namespaces on $SUBNET.0/$PREFIX"
    ip link add "$BR" type bridge
    ip link set "$BR" up
    mk_ns() { # ns veth vethb ip
      ip netns add "$1"
      ip link add "$2" type veth peer name "$3"
      ip link set "$2" netns "$1"
      ip link set "$3" master "$BR"; ip link set "$3" up
      ip -n "$1" addr add "$4/$PREFIX" dev "$2"
      ip -n "$1" link set "$2" up
      ip -n "$1" link set lo up
    }
    mk_ns "$NS_BIZ" "$V_BIZ" "$V_BIZB" "$IP_BIZ"
    mk_ns "$NS_ADA" "$V_ADA" "$V_ADAB" "$IP_ADA"
    mk_ns "$NS_BOB" "$V_BOB" "$V_BOBB" "$IP_BOB"
    if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
      echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
    fi
    if ! ip netns exec "$NS_BIZ" ping -c1 -W2 "$IP_ADA" >/dev/null 2>&1; then
      err "no L2 connectivity across the bridge — discovery cannot work."
      return 1
    fi
  else
    log "Creating docker bridge network $NET on $SUBNET.0/$PREFIX"
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker network create --driver bridge --subnet "$SUBNET.0/$PREFIX" "$NET" >/dev/null || return 1
    stage_libs
    log "Staged $(ls "$LIBSTAGE" | wc -l) shared libraries for the containers"
  fi
  log "L2 segment ready"
  return 0
}

node_start() { # ns-or-container root name seed  -> echoes a handle
  local id="$1" root="$2" name="$3" seed="$4" ip="$5"
  if [ "$BACKEND" = netns ]; then
    ip netns exec "$id" env \
      AUTONOMOUS_TRUST_ROOT="$root" \
      AT_PEER_NAME="$name" AT_PEER_SEED="$seed" \
      AT_OWN_GEOHASH="$GEO" \
      LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
      "$AGORAD" extern_to_at at_to_extern 2 \
      >"$root/agorad.log" 2>&1 &
    echo $!
  else
    # The agora dir is bind-mounted at its OWN absolute path, so the socket the
    # container binds ($root/var/at/...) is the very path the host driver opens.
    docker rm -f "$id" >/dev/null 2>&1 || true
    docker run -d --name "$id" --network "$NET" --ip "$ip" \
      -v "$AGORA_DIR:$AGORA_DIR" \
      -e AUTONOMOUS_TRUST_ROOT="$root" \
      -e AT_PEER_NAME="$name" -e AT_PEER_SEED="$seed" \
      -e AT_OWN_GEOHASH="$GEO" \
      -e LD_LIBRARY_PATH="$LIBSTAGE:$ATCORE" \
      "$DOCKER_IMAGE" \
      sh -c "exec '$AGORAD' extern_to_at at_to_extern 2 >'$root/agorad.log' 2>&1" \
      >/dev/null || return 1
    echo "$id"
  fi
}

node_alive() { # handle
  if [ "$BACKEND" = netns ]; then kill -0 "$1" 2>/dev/null
  else [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; fi
}

node_stop() { # handle
  [ -z "$1" ] && return 0
  if [ "$BACKEND" = netns ]; then
    kill "$1" 2>/dev/null; sleep 1; kill -9 "$1" 2>/dev/null
  else
    docker rm -f "$1" >/dev/null 2>&1
  fi
  return 0
}

net_down() {
  if [ "$BACKEND" = netns ]; then
    ip netns del "$NS_BIZ" 2>/dev/null
    ip netns del "$NS_ADA" 2>/dev/null
    ip netns del "$NS_BOB" 2>/dev/null
    ip link del "$BR" 2>/dev/null
  else
    docker network rm "$NET" >/dev/null 2>&1
  fi
}

cleanup() {
  local keep="${KEEP:-0}"
  node_stop "$PID_BIZ"; node_stop "$PID_ADA"; node_stop "$PID_BOB"
  if [ "$keep" = "1" ]; then
    log "KEEP=1 — leaving the network and $RUN in place."
    return
  fi
  net_down
  rm -rf "$RUN"
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------- #
# Mint the page BEFORE touching the network: if Ethne cannot produce a
# self-verifying artifact there is nothing worth carrying.
# --------------------------------------------------------------------------- #
log "Minting a real Ethne business page (polity → envoy → page)"
PAGE_JSON="$RUN/page.json"
if ! (cd "$AGORA_DIR" && AGORA_ETHNE_PATH="$ETHNE" "$DART" run tool/make_business_bundle.dart \
        --name "Corner Cafe" --locality "$GEO" >"$PAGE_JSON" 2>"$RUN/mint.log"); then
  err "could not mint a business page:"; cat "$RUN/mint.log" >&2; exit 1
fi
POLITY="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['polity'])" "$PAGE_JSON")"
ok "polity $POLITY (page verifies standalone)"

net_up || exit 1

# --------------------------------------------------------------------------- #
# The app-side driver. One script, three verbs, so every phase speaks to the
# node through the SAME shim the Flutter app uses.
#
#   advertise <root> <polity> <page.json>   — the business publishes its page
#   customer  <root> <polity> <sat>         — declare a customer edge (no bundle:
#                                             carry the page we already learned)
#   observe   <root> <polity> <timeout> [want_sat]
#                                           — wait for a business ad on the app
#                                             queue; print + return its fields
# --------------------------------------------------------------------------- #
DRIVER="$RUN/driver.py"
cat >"$DRIVER" <<'PY'
import ctypes, json, sys, time

UUID, KEY, GEO, PROF, DM, PID, PBODY = 16, 32, 12, 2560, 1024, 64, 4096
BDID, BADID, BBUN = 95, 64, 3072
# Business POST bounds (Phase 3 P3.4): its bundle carries the body, so it is
# larger than the page bundle's 3072. Measured worst case 3550 of 4096.
BPID, BPBUN = 64, 4096
# Co-signing bounds (Phase 3 P3.3): AGORA_COSIGN_{BYTES,DID,CID,SIG,TOKEN}_MAX
CBYT, CDID, CCID, CSIG, CTOK = 6144, 95, 67, 128, 15

class Ev(ctypes.Structure):
    _fields_ = [
        ("kind", ctypes.c_int32),
        ("peer_uuid", ctypes.c_uint8 * UUID),
        ("signing_pubkey", ctypes.c_uint8 * KEY),
        ("rank", ctypes.c_int32),
        ("operator_bound", ctypes.c_uint8),
        ("operator_attested_at", ctypes.c_double),
        ("operator_pubkey", ctypes.c_uint8 * KEY),
        ("rep_score", ctypes.c_double),
        ("rep_rated", ctypes.c_uint8),
        ("rtt_ms", ctypes.c_int32),
        ("geohash", ctypes.c_char * (GEO + 1)),
        ("profile_json", ctypes.c_char * (PROF + 1)),
        ("connection_state", ctypes.c_int32),
        ("dm_seq", ctypes.c_int64),
        ("dm_ts", ctypes.c_double),
        ("dm_text", ctypes.c_char * (DM + 1)),
        ("post_id", ctypes.c_char * (PID + 1)),
        ("post_seq", ctypes.c_int64),
        ("post_ts", ctypes.c_double),
        ("post_required_tier", ctypes.c_int32),
        ("post_body", ctypes.c_char * (PBODY + 1)),
        ("reaction_post_id", ctypes.c_char * (PID + 1)),
        ("reaction_seq", ctypes.c_int64),
        ("reaction_ts", ctypes.c_double),
        ("in_group", ctypes.c_uint8),
        ("proximity_band", ctypes.c_int32),
        ("business_polity", ctypes.c_char * (BDID + 1)),
        ("business_ad_id", ctypes.c_char * (BADID + 1)),
        ("business_satisfaction", ctypes.c_int32),
        ("business_seq", ctypes.c_int64),
        ("business_ts", ctypes.c_double),
        ("business_bundle", ctypes.c_char * (BBUN + 1)),
        # AGORA_EVENT_COSIGN_REQUEST / _SIGNATURE (Phase 3 P3.3), appended LAST.
        # cosign_bytes is the OPAQUE exported Ethne payload — the core does not
        # verify it, and no description crosses (the signer derives it).
        ("cosign_record", ctypes.c_char * (CTOK + 1)),
        ("cosign_op", ctypes.c_char * (CTOK + 1)),
        ("cosign_polity", ctypes.c_char * (CDID + 1)),
        ("cosign_cid", ctypes.c_char * (CCID + 1)),
        ("cosign_signer_did", ctypes.c_char * (CDID + 1)),
        ("cosign_sig", ctypes.c_char * (CSIG + 1)),
        ("cosign_seq", ctypes.c_int64),
        ("cosign_ts", ctypes.c_double),
        ("cosign_bytes", ctypes.c_char * (CBYT + 1)),
        # AGORA_EVENT_BUSINESS_POST (Phase 3 P3.4), appended LAST.
        # business_post_bundle is the OPAQUE Ethne {post,delegation} artifact —
        # the core verified only that these bytes arrived unaltered from
        # whoever sent them; the ENVOY signature inside is what makes them the
        # business's words, and only the app checks that.
        ("business_post_polity", ctypes.c_char * (BDID + 1)),
        ("business_post_id", ctypes.c_char * (BPID + 1)),
        ("business_post_seq", ctypes.c_int64),
        ("business_post_ts", ctypes.c_double),
        ("business_post_hops", ctypes.c_int32),
        ("business_post_bundle", ctypes.c_char * (BPBUN + 1)),
        # Moderation (Phase 4 P4.1), appended LAST so every prior offset
        # is unchanged. blocked rides the PEER event; rep_tier and
        # rep_ceiling ride the REPUTATION event. rep_ceiling is -1 when
        # the peer is unbounded and is meaningless on any other kind.
        ("blocked", ctypes.c_uint8),
        ("rep_tier", ctypes.c_int32),
        ("rep_ceiling", ctypes.c_double),
    ]

# ABI guard: MUST equal sizeof(agora_event_t) in at_agora_shim.h. A silent drift
# here would decode every field past the drift point as garbage.
assert ctypes.sizeof(Ev) == 22168, f"Ev size {ctypes.sizeof(Ev)} != 22168 (ABI drift)"

EV_BUSINESS_AD = 12
SAT_SELF = 0xFF


def open_lib(shim, root):
    lib = ctypes.CDLL(shim)
    lib.agora_set_root.argtypes = [ctypes.c_char_p]; lib.agora_set_root.restype = None
    lib.agora_events_open.argtypes = [ctypes.c_char_p]; lib.agora_events_open.restype = ctypes.c_void_p
    lib.agora_events_request_roster.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.agora_events_request_roster.restype = ctypes.c_int
    lib.agora_events_poll.argtypes = [ctypes.c_void_p, ctypes.POINTER(Ev), ctypes.c_int]
    lib.agora_events_poll.restype = ctypes.c_int
    lib.agora_events_close.argtypes = [ctypes.c_void_p]; lib.agora_events_close.restype = None
    lib.agora_advertise_business.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                             ctypes.c_char_p, ctypes.c_char_p,
                                             ctypes.c_int64]
    lib.agora_advertise_business.restype = ctypes.c_int
    lib.agora_set_customer.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                       ctypes.c_char_p, ctypes.c_int,
                                       ctypes.c_char_p, ctypes.c_int64]
    lib.agora_set_customer.restype = ctypes.c_int
    lib.agora_set_root(root.encode())
    return lib


def connect(lib, timeout):
    """Open the app-event channel, retrying until the daemon binds its queue."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        h = lib.agora_events_open(b"at_to_extern")
        if h:
            return h
        time.sleep(0.5)
    return None


def wait_in_group(lib, h, timeout):
    """Block until the roster shows a peer that is IN THIS NODE'S GROUP.

    A business ad is an encrypted GROUP MULTICAST, so advertising before the
    group has a member sends it nowhere — the daemon logs "send failed for
    identity.peer_business_ad" and the page is simply lost. Group formation on a
    fresh segment takes tens of seconds (bootstrap, merge, key rotation), far
    longer than discovery, so the driver waits for the real signal rather than
    guessing a sleep. `in_group` rides the ordinary peer event, which is exactly
    what the app sees.
    """
    buf = (Ev * 32)()
    deadline = time.time() + timeout
    while time.time() < deadline:
        lib.agora_events_request_roster(h, b"extern_to_at")
        time.sleep(0.5)
        n = lib.agora_events_poll(h, buf, 32)
        for i in range(max(n, 0)):
            if buf[i].kind == 1 and buf[i].in_group:
                return True
        time.sleep(0.5)
    return False


def cmd_advertise(shim, root, polity, page_path, timeout):
    page = json.load(open(page_path))
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("    (advertise: could not open the app-event channel)"); return 1
    if not wait_in_group(lib, h, timeout):
        print(f"    (advertise: no peer joined this node's group within {timeout:.0f}s "
              f"— a multicast now would go nowhere)")
        lib.agora_events_close(h); return 1
    print("    group has a member; advertising")
    rc = -1
    # Repeat a few times: the multicast is UDP, and one lost datagram should not
    # read as "the feature is broken". Each attempt is a distinct ad (its content
    # id covers the send time), so the receiver deduplicates nothing here — it
    # simply accepts the first that arrives.
    for attempt in range(3):
        rc = lib.agora_advertise_business(h, b"extern_to_at",
                                          polity.encode(),
                                          page["bundle"].encode(),
                                          int(page.get("seq", 1)))
        print(f"    advertise_business rc={rc} ({len(page['bundle'])}-byte bundle, "
              f"attempt {attempt + 1})")
        if rc != 0:
            break
        time.sleep(4.0)
    lib.agora_events_close(h)
    return 0 if rc == 0 else 1


def cmd_customer(shim, root, polity, sat, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("    (customer: could not open the app-event channel)"); return 1
    if not wait_in_group(lib, h, timeout):
        print(f"    (customer: no peer in this node's group within {timeout:.0f}s)")
        lib.agora_events_close(h); return 1
    rc = -1
    for attempt in range(3):
        # Empty bundle on purpose: carry the page we LEARNED, which is what a
        # person rating a shop they heard about actually does.
        rc = lib.agora_set_customer(h, b"extern_to_at", polity.encode(), int(sat),
                                    b"", 0)
        print(f"    set_customer(sat={sat}, learned page) rc={rc} "
              f"(attempt {attempt + 1})")
        if rc != 0:
            break
        time.sleep(4.0)
    lib.agora_events_close(h)
    return 0 if rc == 0 else 1


def cmd_observe(shim, root, polity, timeout, want_sat, out_path):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("    (observe: could not open the app-event channel)"); return 1
    buf = (Ev * 64)()
    deadline = time.time() + float(timeout)
    peers, hit = set(), None
    while time.time() < deadline and hit is None:
        lib.agora_events_request_roster(h, b"extern_to_at")
        time.sleep(0.4)
        n = lib.agora_events_poll(h, buf, 64)
        for i in range(max(n, 0)):
            e = buf[i]
            peers.add(bytes(e.peer_uuid).hex())
            if e.kind != EV_BUSINESS_AD:
                continue
            did = e.business_polity.decode("ascii", "replace")
            if did != polity:
                continue
            sat = int(e.business_satisfaction)
            if want_sat is not None and sat != want_sat:
                # A self-ad when we are waiting for a customer's (or vice versa)
                # is not the event under test — keep listening.
                print(f"    (saw an ad at satisfaction {sat}, waiting for {want_sat})")
                continue
            hit = dict(
                polity=did,
                ad_id=e.business_ad_id.decode("ascii", "replace"),
                satisfaction=sat,
                seq=int(e.business_seq),
                advertiser=bytes(e.peer_uuid).hex(),
                bundle=e.business_bundle.decode("utf-8", "replace"),
            )
            break
        time.sleep(0.5)
    lib.agora_events_close(h)
    print(f"    peers seen: {len(peers)}")
    if hit is None:
        print(f"    (no business ad for {polity[:24]}… reached the app queue)")
        return 2
    label = "the business itself" if hit["satisfaction"] == SAT_SELF \
        else f"a customer at satisfaction {hit['satisfaction']}"
    print(f"    business ad from {hit['advertiser'][:12]}… — {label}, "
          f"page seq {hit['seq']}, {len(hit['bundle'])}-byte bundle")
    if out_path:
        json.dump(hit, open(out_path, "w"))
    return 0


if __name__ == "__main__":
    verb = sys.argv[1]
    shim = sys.argv[2]
    root = sys.argv[3]
    if verb == "advertise":
        sys.exit(cmd_advertise(shim, root, sys.argv[4], sys.argv[5], float(sys.argv[6])))
    if verb == "customer":
        sys.exit(cmd_customer(shim, root, sys.argv[4], int(sys.argv[5]), float(sys.argv[6])))
    if verb == "observe":
        want = sys.argv[6]
        sys.exit(cmd_observe(shim, root, sys.argv[4], float(sys.argv[5]),
                             None if want == "" else int(want),
                             sys.argv[7] if len(sys.argv) > 7 else ""))
    print(f"unknown verb {verb!r}"); sys.exit(64)
PY

# The driver runs on the HOST under both backends: the app-event queue is an
# AF_UNIX socket at $root/var/at/<queue>, a filesystem path that the container's
# bind mount makes identical on both sides. No network namespace is involved in
# talking to a local node, which is exactly why this works.
drive() { # root verb args...
  local root="$1"; shift
  env AUTONOMOUS_TRUST_ROOT="$root" \
      LD_LIBRARY_PATH="$LIBSTAGE:$ATCORE:${LD_LIBRARY_PATH:-}" \
      python3 "$DRIVER" "$1" "$SHIM" "$root" "${@:2}"
}

# --------------------------------------------------------------------------- #
# Phase 1 — the business advertises; the customer's app queue sees it
# --------------------------------------------------------------------------- #
log "Phase 1: starting biz ($IP_BIZ) and ada ($IP_ADA)"
PID_BIZ="$(node_start "$NS_BIZ" "$ROOT_BIZ" agora-biz biz-seed-1 "$IP_BIZ")" || exit 1
PID_ADA="$(node_start "$NS_ADA" "$ROOT_ADA" agora-ada ada-seed-1 "$IP_ADA")" || exit 1
sleep 6
for h in "$PID_BIZ" "$PID_ADA"; do
  if ! node_alive "$h"; then
    err "a daemon exited early:"; tail -n 30 "$ROOT_BIZ/agorad.log" "$ROOT_ADA/agorad.log" 2>/dev/null; exit 1
  fi
done

# ada listens for the business's OWN ad (satisfaction 255) while biz publishes.
ADA_SAW="$RUN/ada_saw.json"
log "ada: waiting for a business ad to reach the app-event queue"
drive "$ROOT_ADA" observe "$POLITY" "$WAIT" 255 "$ADA_SAW" &
OBS_ADA=$!
sleep 6
log "biz: publishing its page"
drive "$ROOT_BIZ" advertise "$POLITY" "$PAGE_JSON" "$WAIT"
wait "$OBS_ADA"; S_ADA=$?
if [ "$S_ADA" -ne 0 ]; then
  err "FAIL (phase 1) — the business's own ad never reached ada's app queue (rc=$S_ADA)."
  err "  This is the forwarder/emit path, not stored state: check that"
  err "  PEER_BUSINESS_AD_OBSERVED is in the AT_MAIN_QUEUE -> app-queue switch"
  err "  in autonomous_trust.c, the way PEER_PROXIMITY_OBSERVED had to be."
  echo "--- biz ---"; tail -n 25 "$ROOT_BIZ/agorad.log"
  echo "--- ada ---"; tail -n 25 "$ROOT_ADA/agorad.log"
  exit 1
fi
ok "phase 1 — the ad crossed the runtime and landed on ada's app-event queue"

# --------------------------------------------------------------------------- #
# Phase 2 — the business goes away
# --------------------------------------------------------------------------- #
log "Phase 2: stopping biz — from here the business does not exist"
node_stop "$PID_BIZ"
PID_BIZ=""
sleep 2

# --------------------------------------------------------------------------- #
# Phase 3 — a newcomer who never met the business learns its page from a customer
# --------------------------------------------------------------------------- #
log "Phase 3: starting bob ($IP_BOB) — he has never seen the business"
PID_BOB="$(node_start "$NS_BOB" "$ROOT_BOB" agora-bob bob-seed-1 "$IP_BOB")" || exit 1
sleep 10
if ! node_alive "$PID_BOB"; then
  err "bob exited early:"; tail -n 30 "$ROOT_BOB/agorad.log" 2>/dev/null; exit 1
fi

BOB_SAW="$RUN/bob_saw.json"
log "bob: waiting for a CUSTOMER's ad (satisfaction 4, not the 255 self-marker)"
drive "$ROOT_BOB" observe "$POLITY" "$WAIT" 4 "$BOB_SAW" &
OBS_BOB=$!
sleep 6
log "ada: declaring a customer edge (satisfaction 4) — carrying the page it learned"
drive "$ROOT_ADA" customer "$POLITY" 4 "$WAIT"
wait "$OBS_BOB"; S_BOB=$?
if [ "$S_BOB" -ne 0 ]; then
  err "FAIL (phase 3) — bob never received the page from ada (rc=$S_BOB)."
  err "  The business is dead, so ada's first-person re-advertisement was the"
  err "  only possible source: check handle_app_set_customer's learned-page"
  err "  fallback and the customer gate in handle_business_ad."
  echo "--- ada ---"; tail -n 25 "$ROOT_ADA/agorad.log"
  echo "--- bob ---"; tail -n 25 "$ROOT_BOB/agorad.log"
  exit 1
fi
ok "phase 3 — the page outlived the business, carried by a customer"

# --------------------------------------------------------------------------- #
# Phase 4 — the page bob holds is the real one, and still proves itself
# --------------------------------------------------------------------------- #
log "Phase 4: verifying bob's bundle against Ethne, with the business offline"
python3 - "$PAGE_JSON" "$BOB_SAW" "$ADA_SAW" <<'PY' || exit 1
import json, sys
minted = json.load(open(sys.argv[1]))
bob    = json.load(open(sys.argv[2]))
ada    = json.load(open(sys.argv[3]))
fail = False
if bob["bundle"] != minted["bundle"]:
    print("    MISMATCH: bob's bundle is not the page the business minted")
    fail = True
else:
    print(f"    bob's bundle is byte-identical to the minted page "
          f"({len(bob['bundle'])} bytes)")
if bob["satisfaction"] != 4:
    print(f"    WRONG VOICE: satisfaction {bob['satisfaction']} — bob should have "
          f"heard a customer (4), not the business")
    fail = True
if bob["advertiser"] == ada.get("advertiser"):
    # ada's observation names the BUSINESS as advertiser; bob's must name ada.
    print("    WRONG SOURCE: bob's ad names the same advertiser the business's "
          "own ad did — it was not re-advertised in the first person")
    fail = True
else:
    print(f"    advertiser is ada ({bob['advertiser'][:12]}…), not the business "
          f"({ada.get('advertiser','?')[:12]}…) — first-person, as designed")
if bob["ad_id"] == ada.get("ad_id"):
    print("    WRONG ID: the re-advertisement reused the business's content id")
    fail = True
sys.exit(1 if fail else 0)
PY

# The self-verifying half: does the artifact still stand without its author?
cat >"$RUN/verify.dart" <<'DART'
import 'dart:convert';
import 'dart:io';
import 'package:agora/src/ffi/ethne_bindings.dart';
void main(List<String> a) {
  final saw = jsonDecode(File(a[0]).readAsStringSync()) as Map<String, dynamic>;
  final ffi = EthneFfi.open(Platform.environment['AGORA_ETHNE_PATH']);
  final ok = ffi.verifyBusinessPageBundle(saw['bundle'] as String);
  stdout.writeln(ok ? 'verified' : 'NOT VERIFIED');
  exit(ok ? 0 : 1);
}
DART
cp "$RUN/verify.dart" "$AGORA_DIR/tool/_cohort_verify.dart"
if (cd "$AGORA_DIR" && AGORA_ETHNE_PATH="$ETHNE" "$DART" run tool/_cohort_verify.dart "$BOB_SAW"); then
  ok "phase 4 — the page still verifies (polity root → envoy → page) with the business gone"
  rm -f "$AGORA_DIR/tool/_cohort_verify.dart"
else
  rm -f "$AGORA_DIR/tool/_cohort_verify.dart"
  err "FAIL (phase 4) — the page bob holds no longer verifies."
  exit 1
fi

echo
log "PASS — businesses near me, end to end:"
log "       1. the business's ad reached a peer's APP-EVENT QUEUE (kind 12);"
log "       2. with the business STOPPED, its customer carried the page to a"
log "          newcomer, in the first person at her own satisfaction;"
log "       3. that page is byte-identical to the minted one and still proves"
log "          itself through Ethne with nobody left to ask."
exit 0
