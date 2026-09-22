#!/usr/bin/env bash
#
# business_post_cohort.sh — Phase 3 P3.4 live check: a business POST reaches the
# feed of a node that knows the business, and only of a node that knows it.
#
# Three real agorad nodes on one virtual L2 segment (bridge + netns, exactly as
# business_cohort.sh), driven through the real app-event queues:
#
#   biz  — the business. Advertises its page once, then publishes posts with
#          REAL Ethne {post,delegation} bundles minted by
#          tool/make_business_post.dart, so what crosses the wire is the genuine
#          polity-root → envoy → post and not a stub.
#   ada  — a neighbour who learns the page from biz's ad, and so is allowed to
#          hear what the business says.
#   bob  — arrives knowing nothing. He is the gate's negative case, until a
#          customer's re-advertisement teaches him the page.
#
# What it proves, in order:
#   1. A business post crosses the whole runtime and lands on the APP-EVENT
#      QUEUE (kind 15) with the envoy bundle intact — and the bundle VERIFIES
#      out of the received bytes, not out of the minting tool's memory.
#   2. THE AUDIENCE GATE IS REAL. The same post, on the same segment, at the
#      same moment, does NOT reach bob — who holds no page for that polity.
#      This is the one assertion conformance cannot make: it is about two nodes
#      disagreeing about the same broadcast.
#   3. THE GATE OPENS WHEN THE PAGE ARRIVES. After a customer carries the page
#      to bob (P3.2's mechanism), the next post reaches him.
#   4. THE POST OUTLIVES THE BUSINESS. With biz stopped, the bundle bob holds
#      still proves polity-root → envoy → post with nobody left to ask.
#   5. THE CORE CARRIES, THE APP JUDGES. ada publishes a TAMPERED bundle — the
#      body edited after the envoy signed it. The core accepts it (it holds no
#      Ethne and cannot know), bob's core delivers it, and the app-side
#      verifier REFUSES it. A tampered post reaching the app queue is not a
#      failure; being believed would be.
#
# WHAT THIS DELIBERATELY DOES NOT TEST: the relay hop itself. Everyone on one
# L2 segment hears the original multicast, so a relayed copy — which carries
# the publisher's own envelope, byte for byte, and therefore the same content
# id — is deduped against the original it raced. Proving a relay needs a
# partition this harness has no way to build. The hop bound and the
# hops-outside-the-signature property are pinned by conformance instead
# (business-post-relay-bound, business-post-hops-outside-the-signature).
#
# TWO BACKENDS, one script — netns (root) or docker — exactly as its siblings.
#
# Requirements: python3, dart (to mint the bundles), the built native layer +
# ethne cdylib (./build.sh), and EITHER root + iproute2 OR a usable docker
# daemon.
#
# Usage:
#   sudo -E env "PATH=$PATH" ./test/cohort/business_post_cohort.sh
#   WAIT=120 KEEP=1 ./test/cohort/business_post_cohort.sh
#
# Env knobs: BACKEND (auto|netns|docker), WAIT (per-phase timeout, default 90),
#   GATE_WINDOW (how long bob must stay silent, default 45), SUBNET (default
#   10.9.3), GEO (shared coarse bucket, default u4pruy), KEEP=1.

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

WAIT="${WAIT:-90}"
GATE_WINDOW="${GATE_WINDOW:-45}"
SUBNET="${SUBNET:-10.9.3}"
GEO="${GEO:-u4pruy}"
IP_BIZ="$SUBNET.11"; IP_ADA="$SUBNET.12"; IP_BOB="$SUBNET.13"; PREFIX=24

NS_BIZ=agpbiz; NS_ADA=agpada; NS_BOB=agpbob
BR=agbr3
V_BIZ=agpb; V_BIZB=agpbb; V_ADA=agpa; V_ADAB=agpab; V_BOB=agpo; V_BOBB=agpob

BACKEND="${BACKEND:-auto}"
NET=agora-post-net                          # docker network name

# The run dir lives under the agora directory, not /tmp: a docker daemon only
# bind-mounts paths shared with it, and a preserved failing run has to be
# readable from wherever the checkout is. The socket-path preflight below
# checks it fits sun_path before any daemon starts.
RUN="${AGORA_COHORT_RUN:-$AGORA_DIR/.coh/post-$$}"
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
if ! have dart; then err "'dart' not found (needed to mint the Ethne bundles); add the Flutter SDK to PATH."; exit 1; fi

# THE DART BINARY every tool below runs through — deliberately the Dart SDK's
# OWN binary, not the `dart` wrapper in flutter/bin. The wrapper re-runs
# Flutter's install bookkeeping on every call, and this script runs under sudo
# for netns, so that bookkeeping would happen AS ROOT inside a developer-owned
# SDK. (See the same note in business_cohort.sh, where it was found.)
DART="$(command -v dart)"
_dart_real="$(readlink -f "$DART" 2>/dev/null || printf '%s' "$DART")"
_sdk_dart="$(dirname "$_dart_real")/cache/dart-sdk/bin/dart"
[ -x "$_sdk_dart" ] && DART="$_sdk_dart"

as_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" -E env "PATH=$PATH" "$@"
  else
    "$@"
  fi
}

# `.dart_tool/package_config.json` holds ABSOLUTE paths into $HOME/.pub-cache,
# so it goes stale whenever the checkout moves between machines or $HOME
# changes underneath it. `package:ffi` then stops resolving and the minting
# step dies in a wall of "'Utf8' isn't a type" that reads like a broken binding
# and is nothing of the kind.
if have flutter; then
  (cd "$AGORA_DIR" && as_user flutter pub get --offline) >/dev/null 2>&1 \
    || err "'flutter pub get' failed — package:ffi may not resolve below."
fi

for f in "$AGORAD" "$SHIM" "$ATCORE/libautonomous_trust.so" "$ETHNE"; do
  if [ ! -e "$f" ]; then err "missing artifact: $f"; err "build first: (cd '$AGORA_DIR' && ./build.sh)"; exit 1; fi
done

# THEY MUST RUN HERE, NOT MERELY EXIST. A native layer built inside a Claude
# sandbox links against that sandbox's newer glibc/libstdc++, and on a host with
# older runtime libraries every daemon dies instantly with
#   version `GLIBCXX_3.4.32' not found (required by …libautonomous_trust.so)
# Without this check that arrives ~30 seconds in, after minting and building the
# network, as three dead daemons and a tail of linker errors — which reads like
# a cohort fault and is a build-provenance one. Costs one ldd per artifact.
_unrunnable=""
for f in "$AGORAD" "$SHIM" "$ATCORE/libautonomous_trust.so"; do
  _bad="$(LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" ldd -r "$f" 2>&1 \
          | grep -E "not found" | head -2)"
  if [ -n "$_bad" ]; then
    _unrunnable="$_unrunnable
  $(basename "$f"): $(echo "$_bad" | tr '\n' ';')"
  fi
done
if [ -n "$_unrunnable" ]; then
  err "the native layer cannot run on THIS machine:$_unrunnable"
  err "  These artifacts were built somewhere with newer runtime libraries"
  err "  (a Claude sandbox, typically). Rebuild them here, as your normal user:"
  err "    (cd '$AGORA_DIR' && AGORA_CLEAN=1 ./build.sh)"
  err "  AGORA_CLEAN also clears the CMake cache the other machine configured."
  exit 1
fi

# SOCKET PATH BUDGET. AT binds its queues at $ROOT/var/at/<queue> and a unix
# sun_path holds 108 bytes INCLUDING the terminator. The binding constraint is
# not an app queue: it is AT's own supervisor queue "AutonomousTrust", 15
# characters. A root one byte too long fails to bind, every messaging_send
# returns EBADF, and the symptom is "peers discovered: 0" — a path length
# wearing a networking fault's clothes. P3.3 spent two host runs on it.
SUN_MAX=108
LONGEST_Q="AutonomousTrust"
_worst_node=""; _worst_need=0
for r in "$ROOT_BIZ" "$ROOT_ADA" "$ROOT_BOB"; do
  need=$(( ${#r} + ${#LONGEST_Q} + 9 ))   # "/var/at/" + name + NUL
  if [ "$need" -gt "$_worst_need" ]; then _worst_need=$need; _worst_node="$r"; fi
done
if [ "$_worst_need" -gt "$SUN_MAX" ]; then
  err "socket path too long: $_worst_node needs $_worst_need bytes of $SUN_MAX."
  err "  Set AGORA_COHORT_RUN=/tmp/agora-post-\$\$ (netns only — a docker"
  err "  backend can bind-mount only paths shared with the daemon)."
  exit 1
fi
log "Socket paths fit: worst node needs $_worst_need of $SUN_MAX bytes"

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
# Backend primitives.
# --------------------------------------------------------------------------- #
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:26.04}"

stage_libs() {
  local lib
  for lib in $(ldd "$AGORAD" "$ATCORE/libautonomous_trust.so" 2>/dev/null \
               | awk '/=> \// {print $3}' | sort -u); do
    case "$lib" in
      */libc.so.*|*/libm.so.*|*/ld-linux*) continue ;;
    esac
    cp -n "$lib" "$LIBSTAGE/" 2>/dev/null || true
  done
}

# ONE definition of "remove the network", called at the START of net_up as well
# as by net_down. A failed run that kept its namespaces for diagnosis must not
# poison the next one — and `ip netns del` takes ONE name, never a list, which
# is how P3.3 left four of five namespaces behind and then read the wreckage as
# a discovery fault.
net_reset() {
  if [ "$BACKEND" = netns ]; then
    ip netns del "$NS_BIZ" 2>/dev/null
    ip netns del "$NS_ADA" 2>/dev/null
    ip netns del "$NS_BOB" 2>/dev/null
    ip link del "$V_BIZB" 2>/dev/null
    ip link del "$V_ADAB" 2>/dev/null
    ip link del "$V_BOBB" 2>/dev/null
    ip link del "$BR" 2>/dev/null
  else
    docker rm -f agpbiz agpada agpbob >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
  fi
  return 0
}

net_up() {
  net_reset
  if [ "$BACKEND" = netns ]; then
    log "Creating bridge $BR + three namespaces on $SUBNET.0/$PREFIX"
    ip link add "$BR" type bridge || return 1
    ip link set "$BR" up || return 1
    mk_ns() { # ns veth vethb ip
      ip netns add "$1" || return 1
      ip link add "$2" type veth peer name "$3" || return 1
      ip link set "$2" netns "$1" || return 1
      ip link set "$3" master "$BR" || return 1
      ip link set "$3" up || return 1
      ip -n "$1" addr add "$4/$PREFIX" dev "$2" || return 1
      ip -n "$1" link set "$2" up || return 1
      ip -n "$1" link set lo up || return 1
      return 0
    }
    mk_ns "$NS_BIZ" "$V_BIZ" "$V_BIZB" "$IP_BIZ" || { err "could not build $NS_BIZ"; return 1; }
    mk_ns "$NS_ADA" "$V_ADA" "$V_ADAB" "$IP_ADA" || { err "could not build $NS_ADA"; return 1; }
    mk_ns "$NS_BOB" "$V_BOB" "$V_BOBB" "$IP_BOB" || { err "could not build $NS_BOB"; return 1; }
    if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
      echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
    fi
    for tgt in "$IP_ADA" "$IP_BOB"; do
      if ! ip netns exec "$NS_BIZ" ping -c1 -W2 "$tgt" >/dev/null 2>&1; then
        err "no L2 path from biz to $tgt — discovery cannot work."
        return 1
      fi
    done
  else
    log "Creating docker bridge network $NET on $SUBNET.0/$PREFIX"
    docker network create --driver bridge --subnet "$SUBNET.0/$PREFIX" "$NET" >/dev/null || return 1
    stage_libs
    log "Staged $(ls "$LIBSTAGE" | wc -l) shared libraries for the containers"
  fi
  log "L2 segment ready"
  return 0
}

node_start() { # ns-or-container root name seed ip -> echoes a handle
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

net_down() { net_reset; }

# Tail every daemon log. Called on failure, because "the sender sent and the
# receiver logged nothing" is a different diagnosis from "the receiver refused
# it", and only the logs tell them apart.
dump_logs() {
  local r
  for r in "$ROOT_BIZ" "$ROOT_ADA" "$ROOT_BOB"; do
    [ -f "$r/agorad.log" ] || continue
    echo "--- $(basename "$r") ---"
    tail -n 30 "$r/agorad.log"
  done
}

cleanup() {
  local rc="${1:-0}"
  node_stop "$PID_BIZ"; node_stop "$PID_ADA"; node_stop "$PID_BOB"
  if [ "${KEEP:-0}" = "1" ] || [ "$rc" != "0" ]; then
    log "Leaving the network and $RUN in place (exit $rc)."
    if [ "$BACKEND" = netns ]; then
      log "Tear down with:"
      log "  ip netns del $NS_BIZ"
      log "  ip netns del $NS_ADA"
      log "  ip netns del $NS_BOB"
      log "  ip link del $BR"
    fi
    return
  fi
  net_down
  rm -rf "$RUN"
}
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT TERM

# --------------------------------------------------------------------------- #
# Mint the page and the posts BEFORE touching the network. One invocation, one
# polity: a post only means anything to a reader that holds the same business's
# PAGE, so minting them separately would mint two businesses and the run would
# fail at the audience gate for a reason that has nothing to do with the gate.
# --------------------------------------------------------------------------- #
log "Minting a real Ethne business page + posts (polity → envoy → page/post)"
MINT="$RUN/mint.json"
if ! (cd "$AGORA_DIR" && AGORA_ETHNE_PATH="$ETHNE" "$DART" run tool/make_business_post.dart \
        --name "Corner Cafe" --locality "$GEO" \
        --post "Fresh croissants at seven." \
        --post "The grinder is fixed." \
        --post "Closed Monday for the holiday." >"$MINT" 2>"$RUN/mint.log"); then
  err "could not mint the business artifacts:"; cat "$RUN/mint.log" >&2; exit 1
fi
POLITY="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['polity'])" "$MINT")"
for i in 0 1 2; do
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
open(sys.argv[3],'w').write(d['posts'][int(sys.argv[2])]['bundle'])
" "$MINT" "$i" "$RUN/post$((i+1)).bundle"
done
ok "polity $POLITY (page and 3 posts verify standalone)"

# A tampered copy of post 3: the body edited AFTER the envoy signed it. The
# core cannot tell — it holds no Ethne — so this is what the app-side verifier
# is for, and phase 5 makes it say so out loud.
python3 - "$RUN/post3.bundle" "$RUN/post3-tampered.bundle" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
b["post"]["payload"]["body"] = "FREE COFFEE FOREVER, just send your keys"
open(sys.argv[2], "w").write(json.dumps(b))
PY

net_up || exit 1

# --------------------------------------------------------------------------- #
# The app-side driver: one script, five verbs, every phase speaking to its node
# through the SAME shim the Flutter app uses.
#
#   advertise <root> <polity> <mint.json>        — publish the business page
#   customer  <root> <polity> <sat>              — declare a customer edge
#   post      <root> <polity> <bundle> <seq>     — publish a business post
#   observe-post <root> <polity> <t> <out> [hops]— wait for one on the app queue
#   observe-none <root> <polity> <seconds>       — assert none arrives
#
# The ctypes Ev mirror and connect()/wait_in_group() below are SPLICED VERBATIM
# out of business_cohort.sh, so the fourth ABI mirror cannot drift by hand-copy.
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

EV_POST = 9
EV_BUSINESS_AD = 12
EV_BUSINESS_POST = 15
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
    lib.agora_publish_business_post.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                                ctypes.c_char_p, ctypes.c_char_p,
                                                ctypes.c_int64]
    lib.agora_publish_business_post.restype = ctypes.c_int
    # A PLAIN feed post, used only as the group-channel probe below.
    lib.agora_publish_post.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                       ctypes.c_char_p, ctypes.c_int]
    lib.agora_publish_post.restype = ctypes.c_int
    lib.agora_set_root(root.encode())
    return lib


def drain(lib, h, buf, cap, deadline):
    """Poll until the batch comes back SHORT, or the deadline passes.

    agora_events_poll returns at most 16 events per call whatever `max` says
    (at_agora_shim.c) — a caller asking for more simply polls again. A single
    poll on a busy queue therefore reads a sixteenth of it, which is how P3.3
    spent four host runs believing its peers had not been discovered. Bounded
    at both ends so a queue refilled as fast as it is read cannot hang us.
    """
    out = []
    batches = 0
    while batches < 64 and time.time() < deadline:
        n = lib.agora_events_poll(h, buf, cap)
        if n <= 0:
            break
        out.extend(buf[i] for i in range(n))
        batches += 1
        if n < 16:
            break
    return out


def cmd_advertise(shim, root, polity, page_path, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("advertise: could not open the app-event channel", file=sys.stderr)
        return 2
    # A business ad is an encrypted GROUP multicast: publishing before the
    # group has a member sends it nowhere at all.
    if not wait_in_group(lib, h, timeout):
        print("advertise: no peer joined this node's group in time", file=sys.stderr)
        return 3
    page = json.load(open(page_path))
    rc = lib.agora_advertise_business(h, b"extern_to_at",
                                      polity.encode(),
                                      page["page_bundle"].encode(),
                                      int(page.get("page_seq", 1)))
    print(f"advertise rc={rc} ({len(page['page_bundle'])} bundle bytes)")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_customer(shim, root, polity, sat, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("customer: could not open the app-event channel", file=sys.stderr)
        return 2
    if not wait_in_group(lib, h, timeout):
        print("customer: no peer joined this node's group in time", file=sys.stderr)
        return 3
    rc = lib.agora_set_customer(h, b"extern_to_at", polity.encode(), int(sat),
                                b"", 0)
    print(f"customer rc={rc} sat={sat}")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_post(shim, root, polity, bundle_path, seq, timeout):
    """Publish one business post. `bundle_path` holds the raw Ethne
    {post,delegation} JSON — envoy-signed, opaque to the core."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("post: could not open the app-event channel", file=sys.stderr)
        return 2
    if not wait_in_group(lib, h, timeout):
        print("post: no peer joined this node's group in time", file=sys.stderr)
        return 3
    bundle = open(bundle_path).read().strip()
    rc = lib.agora_publish_business_post(h, b"extern_to_at", polity.encode(),
                                         bundle.encode(), int(seq))
    print(f"post rc={rc} seq={seq} ({len(bundle)} bundle bytes)")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def _collect_posts(lib, h, polity, deadline, buf, cap):
    """Every business post for `polity` seen before the deadline."""
    seen = []
    while time.time() < deadline:
        lib.agora_events_request_roster(h, b"extern_to_at")
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind != EV_BUSINESS_POST:
                continue
            if e.business_post_polity.decode(errors="replace") != polity:
                continue
            seen.append({
                "polity": e.business_post_polity.decode(errors="replace"),
                "post_id": e.business_post_id.decode(errors="replace"),
                "seq": e.business_post_seq,
                "ts": e.business_post_ts,
                "hops": e.business_post_hops,
                "bundle": e.business_post_bundle.decode(errors="replace"),
                "publisher": bytes(e.peer_uuid).hex(),
            })
            return seen          # one is all any phase needs
        time.sleep(0.5)
    return seen


def cmd_observe_post(shim, root, polity, timeout, out_path, want_hops=None):
    """Wait for ONE business post for `polity` on the app-event queue."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("observe-post: could not open the app-event channel", file=sys.stderr)
        return 2
    cap = 64
    buf = (Ev * cap)()
    seen = _collect_posts(lib, h, polity, time.time() + timeout, buf, cap)
    lib.agora_events_close(h)
    if not seen:
        print(f"observe-post: no business post for {polity[:16]}… in {timeout}s",
              file=sys.stderr)
        return 5
    got = seen[0]
    if want_hops is not None and int(got["hops"]) != int(want_hops):
        print(f"observe-post: hops={got['hops']}, wanted {want_hops}",
              file=sys.stderr)
        return 6
    print(f"business post {got['post_id'][:16]}… seq={got['seq']} "
          f"hops={got['hops']} from {got['publisher'][:12]}… "
          f"({len(got['bundle'])} bundle bytes)")
    if out_path:
        json.dump(got, open(out_path, "w"))
    return 0


def cmd_observe_none(shim, root, polity, seconds):
    """Assert that NO business post for `polity` arrives within `seconds`.

    The gate's negative half. It cannot be proven by waiting forever, so it is
    a bounded claim and says so: nothing arrived in this window, on a segment
    where the same post demonstrably reached the node that holds the page.
    """
    lib = open_lib(shim, root)
    h = connect(lib, seconds)
    if not h:
        print("observe-none: could not open the app-event channel", file=sys.stderr)
        return 2
    cap = 64
    buf = (Ev * cap)()
    seen = _collect_posts(lib, h, polity, time.time() + seconds, buf, cap)
    lib.agora_events_close(h)
    if seen:
        got = seen[0]
        print(f"observe-none: a post ARRIVED that should have been gated: "
              f"{got['post_id'][:16]}… seq={got['seq']} hops={got['hops']}",
              file=sys.stderr)
        return 7
    print(f"nothing for {polity[:16]}… in {seconds}s, as required")
    return 0


def cmd_publish_plain(shim, root, text, timeout):
    """Publish an ORDINARY feed post (kind 9). Used only as the group-channel
    probe: it is the cheapest group multicast that carries no business page,
    so it can be sent after bob joins without teaching him anything."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("publish-plain: could not open the app-event channel", file=sys.stderr)
        return 2
    rc = lib.agora_publish_post(h, b"extern_to_at", text.encode(), 0)
    print(f"publish-plain rc={rc}")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_observe_plain(shim, root, timeout):
    """Wait for any ORDINARY feed post (kind 9) — the other half of the probe.

    Receiving one proves the group channel between the publisher and this node
    is CURRENTLY WORKING: a feed post rides the same encrypted group multicast
    a business post does, so if this arrives, the group key agrees. That is
    the thing a membership change breaks, and the thing an assertion about
    business posts must not be allowed to depend on silently.
    """
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("observe-plain: could not open the app-event channel", file=sys.stderr)
        return 2
    cap = 64
    buf = (Ev * cap)()
    deadline = time.time() + timeout
    while time.time() < deadline:
        lib.agora_events_request_roster(h, b"extern_to_at")
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind == EV_POST:
                print(f"feed post {e.post_id.decode(errors='replace')[:16]}… "
                      f"— the group channel is live")
                lib.agora_events_close(h)
                return 0
        time.sleep(0.5)
    lib.agora_events_close(h)
    print(f"observe-plain: no feed post in {timeout}s", file=sys.stderr)
    return 5


def cmd_observe_ad(shim, root, polity, timeout, out_path):
    """Wait for one business AD (kind 12) — the page arriving. Setup for the
    post phases rather than a claim of its own; business_cohort.sh is where the
    ad path is actually under test."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("observe-ad: could not open the app-event channel", file=sys.stderr)
        return 2
    cap = 64
    buf = (Ev * cap)()
    deadline = time.time() + timeout
    while time.time() < deadline:
        lib.agora_events_request_roster(h, b"extern_to_at")
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind != EV_BUSINESS_AD:
                continue
            if e.business_polity.decode(errors="replace") != polity:
                continue
            got = {
                "polity": e.business_polity.decode(errors="replace"),
                "ad_id": e.business_ad_id.decode(errors="replace"),
                "satisfaction": e.business_satisfaction,
                "seq": e.business_seq,
                "bundle": e.business_bundle.decode(errors="replace"),
                "advertiser": bytes(e.peer_uuid).hex(),
            }
            print(f"business ad {got['ad_id'][:16]}… sat={got['satisfaction']} "
                  f"seq={got['seq']}")
            if out_path:
                json.dump(got, open(out_path, "w"))
            lib.agora_events_close(h)
            return 0
        time.sleep(0.5)
    lib.agora_events_close(h)
    print(f"observe-ad: no ad for {polity[:16]}… in {timeout}s", file=sys.stderr)
    return 5


def main(argv):
    verb = argv[1]
    shim = argv[2]
    root = argv[3]
    if verb == "advertise":
        return cmd_advertise(shim, root, argv[4], argv[5], float(argv[6]))
    if verb == "customer":
        return cmd_customer(shim, root, argv[4], int(argv[5]), float(argv[6]))
    if verb == "post":
        return cmd_post(shim, root, argv[4], argv[5], int(argv[6]), float(argv[7]))
    if verb == "observe-post":
        # argv: 0 script, 1 verb, 2 shim, 3 root, 4 polity, 5 timeout, 6 out,
        # 7 want_hops. Spelled out because reading it one slot along made the
        # hop assertion silently optional — the check ran, on nothing.
        want = None
        if len(argv) > 7 and argv[7] != "":
            want = int(argv[7])
        return cmd_observe_post(shim, root, argv[4], float(argv[5]), argv[6] or None,
                                want)
    if verb == "publish-plain":
        return cmd_publish_plain(shim, root, argv[4], float(argv[5]))
    if verb == "observe-plain":
        return cmd_observe_plain(shim, root, float(argv[4]))
    if verb == "observe-ad":
        return cmd_observe_ad(shim, root, argv[4], float(argv[5]),
                              argv[6] or None)
    if verb == "observe-none":
        return cmd_observe_none(shim, root, argv[4], float(argv[5]))
    print(f"unknown verb {verb}", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

if ! python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$DRIVER"; then
  err "the embedded driver does not compile — refusing to start any node."
  exit 1
fi

drive() { # root verb args...
  local root="$1"; shift
  local verb="$1"; shift
  AGORA_ETHNE_PATH="$ETHNE" LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    python3 "$DRIVER" "$verb" "$SHIM" "$root" "$@"
}

# The app-side Ethne verifier, used on RECEIVED bytes rather than on what the
# minting tool remembers. Written into the project's tool/ dir because it
# imports package:agora, and removed again on the way out.
VERIFY_SRC="$AGORA_DIR/tool/_cohort_post_verify.dart"
cat >"$VERIFY_SRC" <<'DART'
// Temporary: written and removed by test/cohort/business_post_cohort.sh.
import 'dart:convert';
import 'dart:io';
import 'package:agora/src/ffi/ethne_bindings.dart';

void main(List<String> a) {
  final saw = jsonDecode(File(a[0]).readAsStringSync()) as Map<String, dynamic>;
  final want = a.length > 1 ? a[1] : 'verified';
  final ffi = EthneFfi.open(Platform.environment['AGORA_ETHNE_PATH']);
  final ok = ffi.verifyBusinessPostBundle(saw['bundle'] as String);
  stdout.writeln(ok ? 'verified' : 'NOT VERIFIED: ${ffi.lastError()}');
  // `want` lets a phase assert a REFUSAL as firmly as an acceptance.
  exit((want == 'verified') == ok ? 0 : 1);
}
DART
verify_post() { # saw.json [verified|refused]
  (cd "$AGORA_DIR" && AGORA_ETHNE_PATH="$ETHNE" "$DART" run tool/_cohort_post_verify.dart "$1" "${2:-verified}")
}
cleanup_verify() { rm -f "$VERIFY_SRC"; }

# --------------------------------------------------------------------------- #
# Phase 1 — biz and ada come up together; ada learns the page from an ad
#
# STARTED TOGETHER, then one settle sleep. P3.3 staggered its node starts to
# dodge a group-key fork that had already been fixed, and the mesh converged
# worse for it; the siblings that converge reliably start their nodes back to
# back.
# --------------------------------------------------------------------------- #
log "Phase 1: starting biz ($IP_BIZ) and ada ($IP_ADA)"
PID_BIZ="$(node_start "$NS_BIZ" "$ROOT_BIZ" agora-biz biz-seed-1 "$IP_BIZ")" || exit 1
PID_ADA="$(node_start "$NS_ADA" "$ROOT_ADA" agora-ada ada-seed-1 "$IP_ADA")" || exit 1
sleep 6
for h in "$PID_BIZ" "$PID_ADA"; do
  if ! node_alive "$h"; then err "a daemon exited early:"; dump_logs; exit 1; fi
done

ADA_AD="$RUN/ada_ad.json"
log "ada: waiting for the business's page to arrive"
drive "$ROOT_ADA" observe-ad "$POLITY" "$WAIT" "$ADA_AD" 2>/dev/null &
OBS_AD=$!
sleep 6
log "biz: advertising its page"
drive "$ROOT_BIZ" advertise "$POLITY" "$MINT" "$WAIT"
wait "$OBS_AD" || true      # the ad is setup, not the claim; phase 2 is the claim

# --------------------------------------------------------------------------- #
# Phase 2 — the business speaks, and the neighbour who knows it hears
# --------------------------------------------------------------------------- #
ADA_SAW="$RUN/ada_post.json"
log "ada: waiting for a business POST on the app-event queue (kind 15)"
drive "$ROOT_ADA" observe-post "$POLITY" "$WAIT" "$ADA_SAW" 0 &
OBS_ADA=$!
sleep 6
log "biz: publishing post 1"
drive "$ROOT_BIZ" post "$POLITY" "$RUN/post1.bundle" 1 "$WAIT"
wait "$OBS_ADA"; S_ADA=$?
if [ "$S_ADA" -ne 0 ]; then
  err "FAIL (phase 2) — the post never reached ada's app queue (rc=$S_ADA)."
  err "  This is the forwarder/emit path, not stored state. Check that"
  err "  AT_APP_PUBLISH_BUSINESS_POST is on at_route_extern_msg's allowlist and"
  err "  PEER_BUSINESS_POST_OBSERVED is in the AT_MAIN_QUEUE -> app-queue switch"
  err "  in autonomous_trust.c, and that the shim's poll case ends in w++."
  dump_logs; cleanup_verify; exit 1
fi
if ! verify_post "$ADA_SAW" verified; then
  err "FAIL (phase 2) — the bundle ada RECEIVED does not verify."
  err "  The bytes on the wire are not the bytes that were signed."
  dump_logs; cleanup_verify; exit 1
fi
ok "phase 2 — the post crossed the runtime, and the envoy chain verifies out of the RECEIVED bytes"

# --------------------------------------------------------------------------- #
# Phase 3 — THE GATE. bob is on the same segment and hears nothing.
# --------------------------------------------------------------------------- #
log "Phase 3: starting bob ($IP_BOB) — he holds no page for this business"
PID_BOB="$(node_start "$NS_BOB" "$ROOT_BOB" agora-bob bob-seed-1 "$IP_BOB")" || exit 1
sleep 10
if ! node_alive "$PID_BOB"; then err "bob exited early:"; dump_logs; exit 1; fi

# THE GROUP CHANNEL MUST BE PROVEN LIVE FIRST. bob's arrival is a membership
# change, and a membership change re-keys the group: on the first host run ada
# rotated to epoch 2 six seconds before biz published post 2 under the old key,
# and ada's daemon said so exactly —
#   net_proc.c: Network: group decrypt failed (-1) from <biz> (our key … epoch 0)
# — so the post never reached her app queue and the gate assertion below would
# have "passed" on a post nobody could have received. That is not a business-
# post defect: ANY group multicast sent into a re-keying group dies the same
# way. So we prove the channel between biz and ada is working again, with an
# ORDINARY feed post — the cheapest group multicast that teaches bob nothing —
# and only then make an assertion that depends on it.
converge_gate() { # publisher-root observer-root label
  local pub="$1" obs_root="$2" label="$3"
  local deadline=$(( SECONDS + WAIT ))
  local round=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    round=$(( round + 1 ))
    drive "$obs_root" observe-plain 20 >/dev/null 2>&1 &
    local obs=$!
    sleep 2
    drive "$pub" publish-plain "group probe $label $round" "$WAIT" >/dev/null 2>&1
    if wait "$obs"; then
      log "group channel live: $label (probe $round)"
      return 0
    fi
    log "  group channel not settled yet: $label (probe $round) — retrying"
  done
  return 1
}
log "Waiting for the group to re-converge after bob's arrival"
if ! converge_gate "$ROOT_BIZ" "$ROOT_ADA" "biz -> ada"; then
  err "FAIL (phase 3 setup) — the group channel between biz and ada never came"
  err "  back after bob joined, so nothing below can be asserted. Look for"
  err "  'group decrypt failed' in ada's log and 'rotated group key to epoch'"
  err "  in both: this is AT group-key convergence on a membership change, NOT"
  err "  the business-post path (phase 2 already proved that works)."
  dump_logs; cleanup_verify; exit 1
fi

ADA_SAW2="$RUN/ada_post2.json"
log "ada (knows the cafe): waiting for post 2"
drive "$ROOT_ADA" observe-post "$POLITY" "$WAIT" "$ADA_SAW2" "" &
OBS_ADA2=$!
log "bob (does not): must hear NOTHING for ${GATE_WINDOW}s"
drive "$ROOT_BOB" observe-none "$POLITY" "$GATE_WINDOW" &
OBS_NONE=$!
sleep 6
log "biz: publishing post 2"
drive "$ROOT_BIZ" post "$POLITY" "$RUN/post2.bundle" 2 "$WAIT"
wait "$OBS_ADA2"; S_ADA2=$?
wait "$OBS_NONE"; S_NONE=$?
if [ "$S_ADA2" -ne 0 ]; then
  err "FAIL (phase 3) — ada, who HOLDS the page, did not get post 2 (rc=$S_ADA2)."
  err "  Without this the gate assertion below proves nothing: a post nobody"
  err "  received would pass it."
  dump_logs; cleanup_verify; exit 1
fi
if [ "$S_NONE" -ne 0 ]; then
  err "FAIL (phase 3) — THE AUDIENCE GATE LEAKED: bob received a post for a"
  err "  business he holds no page for (rc=$S_NONE). Check the"
  err "  _business_page_held gate in handle_business_post — and that it sits"
  err "  BEFORE the emit and the relay, not after."
  dump_logs; cleanup_verify; exit 1
fi
ok "phase 3 — same segment, same moment: ada heard it, bob did not"

# --------------------------------------------------------------------------- #
# Phase 4 — the gate opens when the page arrives (P3.2's mechanism, reused)
# --------------------------------------------------------------------------- #
log "Phase 4: ada declares a customer edge — carrying the page to bob"
BOB_AD="$RUN/bob_ad.json"
drive "$ROOT_BOB" observe-ad "$POLITY" "$WAIT" "$BOB_AD" 2>/dev/null &
OBS_BOB_AD=$!
sleep 4
drive "$ROOT_ADA" customer "$POLITY" 4 "$WAIT"
wait "$OBS_BOB_AD" || true
sleep 2

BOB_SAW="$RUN/bob_post.json"
log "bob: now holds the page — waiting for post 3"
drive "$ROOT_BOB" observe-post "$POLITY" "$WAIT" "$BOB_SAW" "" &
OBS_BOB=$!
sleep 6
log "biz: publishing post 3"
drive "$ROOT_BIZ" post "$POLITY" "$RUN/post3.bundle" 3 "$WAIT"
wait "$OBS_BOB"; S_BOB=$?
if [ "$S_BOB" -ne 0 ]; then
  err "FAIL (phase 4) — bob holds the page now and still heard nothing (rc=$S_BOB)."
  err "  Either the customer's re-advertisement never reached him (P3.2 path)"
  err "  or the page-cache gate is not keyed the way the ad stores it."
  dump_logs; cleanup_verify; exit 1
fi
if ! verify_post "$BOB_SAW" verified; then
  err "FAIL (phase 4) — bob's post does not verify."
  dump_logs; cleanup_verify; exit 1
fi
ok "phase 4 — learning the page is what opened the gate"

# --------------------------------------------------------------------------- #
# Phase 5 — the post outlives the business, and a tampered one is refused
# --------------------------------------------------------------------------- #
log "Phase 5: stopping biz — from here the business does not exist"
node_stop "$PID_BIZ"; PID_BIZ=""
sleep 2

if ! verify_post "$BOB_SAW" verified; then
  err "FAIL (phase 5) — the post stopped verifying once the business went away."
  err "  The artifact is supposed to be self-contained: polity root → envoy →"
  err "  post, with nobody left to ask."
  cleanup_verify; exit 1
fi
ok "phase 5a — the post still proves itself with the business gone"

# Stopping biz is a membership change too, and a membership change re-keys the
# group (see the note in phase 3). Prove ada can still reach bob before making
# an assertion that depends on it.
log "Waiting for the group to re-converge after biz stopped"
if ! converge_gate "$ROOT_ADA" "$ROOT_BOB" "ada -> bob"; then
  err "FAIL (phase 5 setup) — the group channel between ada and bob never came"
  err "  back after biz stopped. Same diagnosis as phase 3's gate: AT group-key"
  err "  convergence on a membership change, not the business-post path."
  dump_logs; cleanup_verify; exit 1
fi

BOB_TAMPER="$RUN/bob_tampered.json"
log "ada: publishing a TAMPERED bundle (body edited after signing)"
drive "$ROOT_BOB" observe-post "$POLITY" "$WAIT" "$BOB_TAMPER" "" &
OBS_TAMPER=$!
sleep 4
drive "$ROOT_ADA" post "$POLITY" "$RUN/post3-tampered.bundle" 9 "$WAIT"
wait "$OBS_TAMPER"; S_TAMPER=$?
if [ "$S_TAMPER" -ne 0 ]; then
  # Reaching the app queue is EXPECTED: the core holds no Ethne and cannot
  # know. If it never arrives, something else refused it and the assertion
  # below would pass for the wrong reason.
  err "FAIL (phase 5) — the tampered post never reached bob's app queue"
  err "  (rc=$S_TAMPER). The core is not supposed to be the one refusing it;"
  err "  this test only means something if the bytes get all the way to the app."
  dump_logs; cleanup_verify; exit 1
fi
if ! verify_post "$BOB_TAMPER" refused; then
  err "FAIL (phase 5) — A TAMPERED POST VERIFIED. The envoy signature no longer"
  err "  covers the body, or the app-side verifier is not being consulted."
  cleanup_verify; exit 1
fi
ok "phase 5b — the core carried it, the app refused it"

cleanup_verify

echo
log "PASS — business posts in the feed, end to end:"
log "       1. a post reached a peer's APP-EVENT QUEUE (kind 15) and its envoy"
log "          chain verified out of the RECEIVED bytes;"
log "       2. on the same segment, a node holding no page heard nothing;"
log "       3. learning the page — from a customer, not the business — opened"
log "          the gate;"
log "       4. the post still proves itself with the business stopped;"
log "       5. a tampered bundle crossed the core and was refused by the app,"
log "          which is exactly the division of labour the design asks for."
exit 0
