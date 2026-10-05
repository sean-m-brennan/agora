#!/usr/bin/env bash
#
# reputation_cohort.sh — prove the reputation gates that the IPC fix brought
# to life actually pass between REAL nodes.
#
# WHY THIS EXISTS. `net_msg_to_proto` never carried `verified`/`has_signature`
# across the network->sibling IPC hop, so every handler gated on
# `nmsg->verified` refused everything in live operation. Thirteen gates were
# dead: three in identity (group-key rotation, proven green by
# business_post_cohort.sh) and TEN in reputation, which no cohort has ever
# touched.
#
# The evidence that they never passed is unusually clean. Every preserved
# cohort run logs `Reputation: forwarding transaction …` — Paxos rounds start
# constantly, driven by AT's own at.handshake / at.echo-challenge /
# at.time-attest probes. `Reputation: Transaction committed` is logged at INFO,
# the level every cohort runs at, and appears ZERO times in 25 runs of history.
# Rounds start; nothing has ever committed.
#
# Three real agorad nodes on one virtual L2 segment (bridge + netns, exactly as
# its sibling cohorts), driven through the real app-event queues:
#
#   alice, bob, carol — three, not two, because a majority quorum of two is not
#   a quorum, and three is the size this environment reliably converges at.
#
# What it proves, in order:
#   1. PAXOS COMMITS. `Reputation: Transaction committed` appears — a line
#      absent from every cohort log ever recorded here.
#   2. AN APP-DRIVEN TRANSACTION COMMITS. A post reaction between two nodes is
#      bilateral by construction: reactor and author independently derive the
#      SAME task uuid and each submits a score for it. A capability-less
#      (`cap -`) transaction carrying one shared task uuid on both nodes is
#      what separates traffic the APPLICATION caused from AT's own probes,
#      which always name a capability.
#   3. CHECKPOINTS REACH QUORUM: propose -> co-sign -> final, across nodes.
#   4. THE TWO UNREACHABLE FLOWS, INJECTED. Slashing and deep resolution have
#      five gates between them and NO production originator — nothing outside
#      conformance and rep_quorum_test.c has ever sent those verbs. The cohort
#      injects them with test/cohort/tools/at_inject.c, which hands the verb to
#      a node's OWN network process so it is really signed and really crosses
#      the wire. THIS TRAFFIC IS SYNTHETIC: it proves the gate opens and the
#      handler runs, and nothing about whether a deployment would ever send it.
#
# Requirements: python3, a C compiler (for the injector), the built native
# layer (./build.sh), and EITHER root + iproute2 (netns) OR a usable docker
# daemon. Nothing is minted, so no dart/Flutter/Ethne here.
#
# Usage:
#   sudo -E env "PATH=$PATH" ./test/cohort/reputation_cohort.sh
#   WAIT=180 KEEP=1 ./test/cohort/reputation_cohort.sh
#
# Env knobs: BACKEND (auto|netns|docker), WAIT (per-phase timeout, default 90),
#   CHECKPOINT_SEC (AT_REP_CHECKPOINT_SEC for the nodes, default 20 — the
#   production default is 300 and this cohort will not wait five minutes),
#   SUBNET (default 10.9.4), KEEP=1.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_AGORA_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "$PWD")"
AGORA_DIR="${1:-${AGORA_DIR:-$DEFAULT_AGORA_DIR}}"
AGORA_DIR="$(cd "$AGORA_DIR" 2>/dev/null && pwd || echo "$AGORA_DIR")"
NATIVE="$AGORA_DIR/native/build"
AGORAD="$NATIVE/agorad"
SHIM="$NATIVE/libagora_shim.so"
ATCORE="$NATIVE/at_core"

WAIT="${WAIT:-90}"
CHECKPOINT_SEC="${CHECKPOINT_SEC:-20}"
LOG_LEVEL="${LOG_LEVEL:-2}"   # agorad: 1=DEBUG 2=INFO (1 shows Paxos retries)
SUBNET="${SUBNET:-10.9.4}"
GEO="${GEO:-u4pruy}"
IP_ALICE="$SUBNET.11"; IP_BOB="$SUBNET.12"; IP_CAROL="$SUBNET.13"; PREFIX=24

NS_ALICE=agrpa; NS_BOB=agrpb; NS_CAROL=agrpc
BR=agbr4
V_ALICE=agrva; V_ALICEB=agrvab; V_BOB=agrvb; V_BOBB=agrvbb; V_CAROL=agrvc; V_CAROLB=agrvcb

BACKEND="${BACKEND:-auto}"
NET=agora-rep-net                          # docker network name

# The run dir lives under the agora directory, not /tmp: a docker daemon only
# bind-mounts paths shared with it, and a preserved failing run has to be
# rebobble from wherever the checkout is. The socket-path preflight below
# checks it fits sun_path before any daemon starts.
RUN="${AGORA_COHORT_RUN:-$AGORA_DIR/.coh/rep-$$}"
ROOT_ALICE="$RUN/alice"; ROOT_BOB="$RUN/bob"; ROOT_CAROL="$RUN/carol"; LIBSTAGE="$RUN/lib"
mkdir -p "$ROOT_ALICE" "$ROOT_BOB" "$ROOT_CAROL" "$LIBSTAGE"

PID_ALICE=""; PID_BOB=""; PID_CAROL=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
if ! have python3; then err "python3 not found."; exit 1; fi
if ! have cc && ! have gcc; then
  err "no C compiler found (needed to build the injector for phase 4)."; exit 1
fi

for f in "$AGORAD" "$SHIM" "$ATCORE/libautonomous_trust.so"; do
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
for r in "$ROOT_ALICE" "$ROOT_BOB" "$ROOT_CAROL"; do
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
    ip netns del "$NS_ALICE" 2>/dev/null
    ip netns del "$NS_BOB" 2>/dev/null
    ip netns del "$NS_CAROL" 2>/dev/null
    ip link del "$V_ALICEB" 2>/dev/null
    ip link del "$V_BOBB" 2>/dev/null
    ip link del "$V_CAROLB" 2>/dev/null
    ip link del "$BR" 2>/dev/null
  else
    docker rm -f agrpa agrpb agrpc >/dev/null 2>&1
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
    mk_ns "$NS_ALICE" "$V_ALICE" "$V_ALICEB" "$IP_ALICE" || { err "could not build $NS_ALICE"; return 1; }
    mk_ns "$NS_BOB" "$V_BOB" "$V_BOBB" "$IP_BOB" || { err "could not build $NS_BOB"; return 1; }
    mk_ns "$NS_CAROL" "$V_CAROL" "$V_CAROLB" "$IP_CAROL" || { err "could not build $NS_CAROL"; return 1; }
    if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
      echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
    fi
    for tgt in "$IP_BOB" "$IP_CAROL"; do
      if ! ip netns exec "$NS_ALICE" ping -c1 -W2 "$tgt" >/dev/null 2>&1; then
        err "no L2 path from alice to $tgt — discovery cannot work."
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
      AT_REP_CHECKPOINT_SEC="$CHECKPOINT_SEC" \
      LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
      "$AGORAD" extern_to_at at_to_extern "$LOG_LEVEL" \
      >"$root/agorad.log" 2>&1 &
    echo $!
  else
    docker rm -f "$id" >/dev/null 2>&1 || true
    docker run -d --name "$id" --network "$NET" --ip "$ip" \
      -v "$AGORA_DIR:$AGORA_DIR" \
      -e AUTONOMOUS_TRUST_ROOT="$root" \
      -e AT_PEER_NAME="$name" -e AT_PEER_SEED="$seed" \
      -e AT_OWN_GEOHASH="$GEO" \
      -e AT_REP_CHECKPOINT_SEC="$CHECKPOINT_SEC" \
      -e LD_LIBRARY_PATH="$LIBSTAGE:$ATCORE" \
      "$DOCKER_IMAGE" \
      sh -c "exec '$AGORAD' extern_to_at at_to_extern $LOG_LEVEL >'$root/agorad.log' 2>&1" \
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
  for r in "$ROOT_ALICE" "$ROOT_BOB" "$ROOT_CAROL"; do
    [ -f "$r/agorad.log" ] || continue
    echo "--- $(basename "$r") ---"
    tail -n 30 "$r/agorad.log"
  done
}

cleanup() {
  local rc="${1:-0}"
  node_stop "$PID_ALICE"; node_stop "$PID_BOB"; node_stop "$PID_CAROL"
  if [ "${KEEP:-0}" = "1" ] || [ "$rc" != "0" ]; then
    log "Leaving the network and $RUN in place (exit $rc)."
    if [ "$BACKEND" = netns ]; then
      log "Tear down with:"
      log "  ip netns del $NS_ALICE"
      log "  ip netns del $NS_BOB"
      log "  ip netns del $NS_CAROL"
      log "  ip link del $BR"
    fi
    return
  fi
  net_down
  rm -rf "$RUN"
}
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT TERM

net_up || exit 1

# --------------------------------------------------------------------------- #
# The injector (phase 4 only). Built here, from the cohort's own source, so it
# always matches the installed native layer — and so nothing test-shaped ever
# lands in a shipped artifact. It hands one protocol verb to a node's OWN
# network process, which signs it and puts it on the wire.
# --------------------------------------------------------------------------- #
INJECT="$RUN/at_inject"
ATC="$AGORA_DIR/../../lib/autonomous_trust/src/c"
# The system compiler, as build.sh builds the AT core: with a conda env active,
# `cc` is conda's, whose linker does not search the system library dirs that
# the system libprotobuf's own dependency (libz) lives in.
CC_BIN=""
for c in /usr/bin/cc /usr/bin/gcc "$(command -v cc)" "$(command -v gcc)"; do
  [ -n "$c" ] && [ -x "$c" ] && { CC_BIN="$c"; break; }
done
[ -n "$CC_BIN" ] || { err "no C compiler found to build the injector"; exit 1; }
# A system-only PATH as well: gcc runs the first `ld` on PATH, and conda's is.
if ! env PATH=/usr/local/bin:/usr/bin:/bin "$CC_BIN" -fms-extensions \
     -I"$ATC" -I"$ATC/autonomous_trust" \
     -I"$NATIVE/at_core" -I"$NATIVE/at_core/autonomous_trust" \
     -I"$NATIVE/at_core/protobuf" \
     -I"$NATIVE/at_core/protobuf/autonomous_trust/core/protobuf" \
     "$SCRIPT_DIR/tools/at_inject.c" -o "$INJECT" \
     -L"$NATIVE/at_core" -lautonomous_trust -luuid -lsodium -ljansson \
     -lprotobuf-c -lstdc++ -lprotobuf -Wl,-rpath,"$NATIVE/at_core" \
     >"$RUN/inject_build.log" 2>&1; then
  err "could not build the injector:"; cat "$RUN/inject_build.log" >&2; exit 1
fi
ok "injector built"

# --------------------------------------------------------------------------- #
# The app-side driver. The ctypes Ev mirror and connect() below are SPLICED
# VERBATIM out of business_cohort.sh, so the ABI mirror cannot drift by
# hand-copy. The verbs BELOW it are new: connect / connect-respond / dm /
# react are the only shim entry points that reach _submit_interaction_score,
# and no cohort driver has ever called them.
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
        # Communities (Phase 4), appended LAST so every prior offset is
        # unchanged. post_community/post_labels ride the POST event;
        # policy_* the COMMUNITY_POLICY event (16); label_* the POST_LABEL
        # event (17). Both bundles are OPAQUE: only the app verifies them.
        ("post_community", ctypes.c_char * (BDID + 1)),
        ("post_labels", ctypes.c_char * (263 + 1)),
        ("policy_community", ctypes.c_char * (BDID + 1)),
        ("policy_id", ctypes.c_char * (64 + 1)),
        ("policy_seq", ctypes.c_int64),
        ("policy_ts", ctypes.c_double),
        ("policy_bundle", ctypes.c_char * (4096 + 1)),
        ("label_community", ctypes.c_char * (BDID + 1)),
        ("label_post_id", ctypes.c_char * (64 + 1)),
        ("label_id", ctypes.c_char * (64 + 1)),
        ("label_seq", ctypes.c_int64),
        ("label_ts", ctypes.c_double),
        ("label_hops", ctypes.c_int32),
        ("label_bundle", ctypes.c_char * (1536 + 1)),
        # Proximity hubs (29200): the fc_* / area_* tail, appended last.
        ("fc_kind", ctypes.c_int32),
        ("fc_ref", ctypes.c_char * (63 + 1)),
        ("fc_handle", ctypes.c_char * (128 + 1)),
        ("fc_nickname", ctypes.c_char * (128 + 1)),
        ("fc_relay", ctypes.c_char * (79 + 1)),
        ("fc_reason", ctypes.c_char * (31 + 1)),
        ("area", ctypes.c_char * (7 + 1)),
        ("area_bucket", ctypes.c_char * (7 + 1)),
        ("area_name", ctypes.c_char * (64 + 1)),
        ("area_issuer", ctypes.c_char * (64 + 1)),
        ("fc_seq", ctypes.c_int64),
        ("fc_count", ctypes.c_int32),
        # Multi-device (41296): the address-book / device / backup tail.
        ("fc_blob", ctypes.c_char * (7679 + 1)),
        ("fc_expiry", ctypes.c_int64),
        ("fc_role", ctypes.c_int32),
        ("fc_petname", ctypes.c_char * (128 + 1)),
        ("fc_verified", ctypes.c_uint8),
        ("fc_provenance", ctypes.c_int32),
        ("fc_added_at", ctypes.c_double),
        ("fc_verified_at", ctypes.c_double),
        ("fc_safety_number", ctypes.c_char * (71 + 1)),
        ("fc_method", ctypes.c_int32),
        ("fc_peer_dropped", ctypes.c_uint8),
        ("fc_device_uuid", ctypes.c_uint8 * 16),
        ("fc_origin", ctypes.c_int32),
        ("backup_path", ctypes.c_char * (4095 + 1)),
        ("backup_passphrase", ctypes.c_char * (31 + 1)),
        ("backup_contacts", ctypes.c_int32),
        ("backup_siblings", ctypes.c_int32),
        ("backup_added", ctypes.c_int32),
        ("backup_updated", ctypes.c_int32),
        ("backup_removed", ctypes.c_int32),
    ]

# ABI guard: MUST equal sizeof(agora_event_t) in at_agora_shim.h. A silent drift
# here would decode every field past the drift point as garbage.
assert ctypes.sizeof(Ev) == 41296, f"Ev size {ctypes.sizeof(Ev)} != 41296 (ABI drift)"

def connect(lib, timeout):
    """Open the app-event channel, retrying until the daemon binds its queue."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        h = lib.agora_events_open(b"at_to_extern")
        if h:
            return h
        time.sleep(0.5)
    return None

EV_PEER = 1
EV_POST = 9


def open_lib(shim, root):
    lib = ctypes.CDLL(shim)
    lib.agora_set_root.argtypes = [ctypes.c_char_p]; lib.agora_set_root.restype = None
    lib.agora_events_open.argtypes = [ctypes.c_char_p]; lib.agora_events_open.restype = ctypes.c_void_p
    lib.agora_events_request_roster.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.agora_events_request_roster.restype = ctypes.c_int
    lib.agora_events_poll.argtypes = [ctypes.c_void_p, ctypes.POINTER(Ev), ctypes.c_int]
    lib.agora_events_poll.restype = ctypes.c_int
    lib.agora_events_close.argtypes = [ctypes.c_void_p]; lib.agora_events_close.restype = None
    # The four verbs no cohort driver has ever called. These are the ONLY shim
    # entry points that reach _submit_interaction_score (id_proc.c:5634) and so
    # the only way an application can cause reputation traffic at all.
    lib.agora_publish_post.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                       ctypes.c_char_p, ctypes.c_int]
    lib.agora_publish_post.restype = ctypes.c_int
    lib.agora_react_post.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                     ctypes.POINTER(ctypes.c_uint8), ctypes.c_char_p]
    lib.agora_react_post.restype = ctypes.c_int
    lib.agora_connect_request.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                          ctypes.POINTER(ctypes.c_uint8)]
    lib.agora_connect_request.restype = ctypes.c_int
    lib.agora_connect_respond.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                          ctypes.POINTER(ctypes.c_uint8), ctypes.c_int]
    lib.agora_connect_respond.restype = ctypes.c_int
    lib.agora_send_dm.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.POINTER(ctypes.c_uint8), ctypes.c_char_p]
    lib.agora_send_dm.restype = ctypes.c_int
    lib.agora_set_root(root.encode())
    return lib


def drain(lib, h, buf, cap, deadline):
    """Poll until the batch comes back SHORT, or the deadline passes.

    agora_events_poll returns at most 16 events per call whatever `max` says,
    so a single poll on a busy queue reads a sixteenth of it — which is how
    P3.3 spent four host runs believing its peers had not been discovered.
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


def _uuid_arg(hexstr):
    raw = bytes.fromhex(hexstr.replace("-", ""))
    if len(raw) != 16:
        raise ValueError("a peer uuid is 16 bytes")
    return (ctypes.c_uint8 * 16)(*raw)


def cmd_peers(shim, root, want, timeout):
    """Wait until this node can see `want` peers — the precondition for every
    phase below, since a transaction needs somebody to have it with."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("peers: could not open the app-event channel", file=sys.stderr)
        return 2
    cap = 64
    buf = (Ev * cap)()
    seen = {}
    deadline = time.time() + timeout
    while time.time() < deadline:
        lib.agora_events_request_roster(h, b"extern_to_at")
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind == EV_PEER:
                seen[bytes(e.peer_uuid).hex()] = True
        if len(seen) >= want:
            break
        time.sleep(1.0)
    lib.agora_events_close(h)
    print(f"peers discovered: {len(seen)} of {want} wanted")
    for u in seen:
        print(f"  {u}")
    return 0 if len(seen) >= want else 5


def cmd_publish_plain(shim, root, text, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    rc = lib.agora_publish_post(h, b"extern_to_at", text.encode(), 0)
    print(f"publish-plain rc={rc}")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_observe_plain(shim, root, timeout, out_path):
    """Wait for a feed post and record its author + content id, which is what
    a reaction has to address."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    deadline = time.time() + timeout
    while time.time() < deadline:
        lib.agora_events_request_roster(h, b"extern_to_at")
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind != EV_POST:
                continue
            got = {"author": bytes(e.peer_uuid).hex(),
                   "post_id": e.post_id.decode(errors="replace"),
                   "body": e.post_body.decode(errors="replace")}
            if not got["post_id"]:
                continue
            print(f"feed post {got['post_id'][:16]}… from {got['author'][:12]}…")
            if out_path:
                json.dump(got, open(out_path, "w"))
            lib.agora_events_close(h)
            return 0
        time.sleep(0.5)
    lib.agora_events_close(h)
    print(f"observe-plain: no feed post in {timeout}s", file=sys.stderr)
    return 5


def cmd_react(shim, root, saw_path, timeout):
    """React to the post recorded by observe-plain. THE BILATERAL ACT: the
    reactor submits an interaction score and so does the author on receipt,
    both against the same task uuid — which is what a Paxos round needs in
    order to reach agreement rather than sit at one vote."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    saw = json.load(open(saw_path))
    rc = lib.agora_react_post(h, b"extern_to_at", _uuid_arg(saw["author"]),
                              saw["post_id"].encode())
    print(f"react rc={rc} to {saw['post_id'][:16]}…")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_connect(shim, root, peer_uuid, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    rc = lib.agora_connect_request(h, b"extern_to_at", _uuid_arg(peer_uuid))
    print(f"connect-request rc={rc}")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_connect_respond(shim, root, peer_uuid, accept, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    rc = lib.agora_connect_respond(h, b"extern_to_at", _uuid_arg(peer_uuid),
                                   int(accept))
    print(f"connect-respond rc={rc} accept={accept}")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_dm(shim, root, peer_uuid, text, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    rc = lib.agora_send_dm(h, b"extern_to_at", _uuid_arg(peer_uuid), text.encode())
    print(f"dm rc={rc}")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def main(argv):
    verb, shim, root = argv[1], argv[2], argv[3]
    if verb == "peers":
        return cmd_peers(shim, root, int(argv[4]), float(argv[5]))
    if verb == "publish-plain":
        return cmd_publish_plain(shim, root, argv[4], float(argv[5]))
    if verb == "observe-plain":
        return cmd_observe_plain(shim, root, float(argv[4]), argv[5] or None)
    if verb == "react":
        return cmd_react(shim, root, argv[4], float(argv[5]))
    if verb == "connect":
        return cmd_connect(shim, root, argv[4], float(argv[5]))
    if verb == "connect-respond":
        return cmd_connect_respond(shim, root, argv[4], int(argv[5]), float(argv[6]))
    if verb == "dm":
        return cmd_dm(shim, root, argv[4], argv[5], float(argv[6]))
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
  LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    python3 "$DRIVER" "$verb" "$SHIM" "$root" "$@"
}

# Every node's own uuid, read from the config its daemon wrote at first start.
# The harness knowing its own nodes is not a registry the design lacks — it is
# the same thing staff_cohort.sh does.
node_uuid() { # root
  python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['uuid'])" \
    "$1/etc/at/identity.cfg.json"
}

# grep a node's log, quietly
saw() { # root pattern
  grep -q "$2" "$1/agorad.log" 2>/dev/null
}
count_in() { # root pattern
  # grep -c PRINTS 0 and EXITS 1 when it matches nothing, so a `|| echo 0`
  # here emits a second zero and every count reads "0\n0".
  local n
  n="$(grep -c "$2" "$1/agorad.log" 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}

# --------------------------------------------------------------------------- #
# Phase 1 — the three nodes come up and find each other
# --------------------------------------------------------------------------- #
log "Phase 1: starting alice ($IP_ALICE), bob ($IP_BOB), carol ($IP_CAROL)"
PID_ALICE="$(node_start "$NS_ALICE" "$ROOT_ALICE" agora-alice alice-seed "$IP_ALICE")" || exit 1
PID_BOB="$(node_start "$NS_BOB" "$ROOT_BOB" agora-bob bob-seed "$IP_BOB")" || exit 1
PID_CAROL="$(node_start "$NS_CAROL" "$ROOT_CAROL" agora-carol carol-seed "$IP_CAROL")" || exit 1
sleep 8
for h in "$PID_ALICE" "$PID_BOB" "$PID_CAROL"; do
  if ! node_alive "$h"; then err "a daemon exited early:"; dump_logs; exit 1; fi
done
if ! drive "$ROOT_ALICE" peers 2 "$WAIT"; then
  err "FAIL (phase 1) — alice cannot see both peers, so no quorum is possible."
  dump_logs; exit 1
fi
ok "phase 1 — three nodes, mutually discovered"

# --------------------------------------------------------------------------- #
# Phase 2 — A PAXOS ROUND COMMITS. The headline.
#
# Nothing has to be driven for this: AT's own negotiation probes
# (at.handshake / at.echo-challenge / at.time-attest) submit transaction
# scores continuously, and every cohort ever run logs "forwarding transaction"
# because of them. What has NEVER appeared, in 25 runs, is the commit.
# --------------------------------------------------------------------------- #
log "Phase 2: waiting for a Paxos round to COMMIT (the line no run has had)"
COMMIT_DEADLINE=$(( SECONDS + WAIT ))
committed=0
while [ "$SECONDS" -lt "$COMMIT_DEADLINE" ]; do
  for r in "$ROOT_ALICE" "$ROOT_BOB" "$ROOT_CAROL"; do
    if saw "$r" "Reputation: Transaction committed"; then committed=1; break 2; fi
  done
  sleep 2
done
if [ "$committed" -ne 1 ]; then
  err "FAIL (phase 2) — no Paxos round committed in ${WAIT}s."
  err "  Rounds ARE starting if you see 'forwarding transaction' below; a"
  err "  start with no commit is the signature of handle_transaction /"
  err "  handle_accepted refusing their messages. Check that the IPC"
  err "  serializer still carries the verified flag (msg_types.c"
  err "  net_msg_to_proto)."
  for r in "$ROOT_ALICE" "$ROOT_BOB" "$ROOT_CAROL"; do
    echo "--- $(basename "$r"): forwarding=$(count_in "$r" 'forwarding transaction') committed=$(count_in "$r" 'Transaction committed') unverified=$(count_in "$r" 'rejecting unverified')"
  done
  dump_logs; exit 1
fi
ok "phase 2 — a Paxos round COMMITTED (first time in this cohort's history)"

# --------------------------------------------------------------------------- #
# Phase 3 — an APPLICATION-driven transaction commits
#
# A post reaction is bilateral BY CONSTRUCTION: the reactor submits an
# interaction score on send and the author submits one on receipt, both
# against a task uuid each derives independently from the same
# (domain, peer-pair, post-id) — nothing on the wire carries it, so neither
# side can forge the pairing (social_tx.h).
#
# HOW AN APP-DRIVEN ROUND IS RECOGNIZED, and how it is NOT. The first version
# of this phase grepped for "cap agora-post" and failed a run in which the
# feature had worked perfectly. `agora-post` is a task_uuid DOMAIN TAG
# (social_tx.h:60), not a capability name: _submit_interaction_score
# deliberately leaves capability_name empty, so a social score logs as
# `cap -`. The honest signature is the pair — ONE task uuid, with no
# capability, forwarded by BOTH the reactor and the author. AT's own probes
# always carry a capability (at.handshake and friends), so `cap -` alone
# separates app traffic from background traffic, and the shared uuid proves
# the bilateral derivation agreed across two machines.
# --------------------------------------------------------------------------- #
log "Phase 3: alice posts, bob reacts — an app-driven (bilateral) transaction"
SAW="$RUN/bob_saw_post.json"
drive "$ROOT_BOB" observe-plain "$WAIT" "$SAW" &
OBS=$!
sleep 4
drive "$ROOT_ALICE" publish-plain "reputation cohort post" "$WAIT"
wait "$OBS"; S_OBS=$?
if [ "$S_OBS" -ne 0 ]; then
  err "FAIL (phase 3) — bob never saw alice's post (rc=$S_OBS), so there is"
  err "  nothing for him to react to. That is the feed path, not reputation."
  dump_logs; exit 1
fi
drive "$ROOT_BOB" react "$SAW" "$WAIT" || { err "FAIL (phase 3) — react refused"; dump_logs; exit 1; }

# The task uuid both sides derived, read off whichever log shows it first.
# `cap -` is the marker: a capability-less transaction is an app interaction,
# never one of AT's probes.
app_task_of() {
  sed -e 's/\x1b\[[0-9;]*m//g' "$1/agorad.log" 2>/dev/null \
    | sed -n 's/.*forwarding transaction for task \([0-9a-f-]*\),.*(cap -,.*/\1/p' \
    | tail -1
}

APP_DEADLINE=$(( SECONDS + WAIT ))
app_task=""
while [ "$SECONDS" -lt "$APP_DEADLINE" ]; do
  t_bob=$(app_task_of "$ROOT_BOB")
  t_alice=$(app_task_of "$ROOT_ALICE")
  # BOTH halves, and the SAME task: either alone would pass on a node that
  # submitted into the void.
  if [ -n "$t_bob" ] && [ "$t_bob" = "$t_alice" ]; then app_task="$t_bob"; break; fi
  sleep 2
done
if [ -z "$app_task" ]; then
  err "FAIL (phase 3) — the reaction produced no paired app transaction."
  err "  Reactor saw: '${t_bob:-none}'   author saw: '${t_alice:-none}'"
  err "  _submit_interaction_score (id_proc.c:5634) is the only path from an"
  err "  app verb into reputation. If exactly one side submitted, the"
  err "  task_uuid derivation disagreed (social_tx.h canonical form); if"
  err "  neither did, check the daily/per-edge accrual caps."
  dump_logs; exit 1
fi
ok "phase 3 — reactor and author both submitted task $app_task (cap -)"

# ...and it must reach the chain, not merely be proposed. The commit line
# names its task precisely so this can be asserted rather than inferred from
# a commit happening to occur nearby.
COMMIT_DEADLINE=$(( SECONDS + WAIT ))
app_committed=0
while [ "$SECONDS" -lt "$COMMIT_DEADLINE" ]; do
  for r in "$ROOT_ALICE" "$ROOT_BOB" "$ROOT_CAROL"; do
    if saw "$r" "Transaction committed (task $app_task)"; then
      app_committed=1; break 2
    fi
  done
  sleep 2
done
if [ "$app_committed" -ne 1 ]; then
  err "FAIL (phase 3) — the app-driven round $app_task never committed,"
  err "  though both halves were submitted. The round is reaching Paxos and"
  err "  losing it: check the 'try again' rate and whether"
  err "  _retry_nacked_rounds is re-proposing (rep_proc.c)."
  dump_logs; exit 1
fi
ok "phase 3 — the app-driven round COMMITTED (task $app_task)"

# --------------------------------------------------------------------------- #
# Phase 4 — checkpoints reach quorum
#
# Downstream of a commit: _maybe_checkpoint only originates for a chain whose
# committed window has advanced. The nodes run with AT_REP_CHECKPOINT_SEC
# shortened, because the production default is 300s.
# --------------------------------------------------------------------------- #
log "Phase 4: waiting for a checkpoint round (interval ${CHECKPOINT_SEC}s)"
CP_DEADLINE=$(( SECONDS + WAIT ))
cp_ok=0
while [ "$SECONDS" -lt "$CP_DEADLINE" ]; do
  for r in "$ROOT_ALICE" "$ROOT_BOB" "$ROOT_CAROL"; do
    if saw "$r" "co-signed checkpoint_propose" || saw "$r" "checkpoint stored"; then
      cp_ok=1; break 2
    fi
  done
  sleep 3
done
if [ "$cp_ok" -ne 1 ]; then
  err "FAIL (phase 4) — no checkpoint round in ${WAIT}s."
  for r in "$ROOT_ALICE" "$ROOT_BOB" "$ROOT_CAROL"; do
    echo "--- $(basename "$r"): unverified_cp=$(count_in "$r" 'unverified checkpoint')"
  done
  dump_logs; exit 1
fi
ok "phase 4 — a checkpoint was co-signed / stored"

# --------------------------------------------------------------------------- #
# Phase 5 — THE TWO FLOWS WITH NO PRODUCTION ORIGINATOR, INJECTED
#
# Slashing and deep resolution have five `verified` gates between them and
# nothing in production ever sends their verbs — only conformance and
# rep_quorum_test.c do. So the cohort sends them itself, through a node's own
# network process, which signs them exactly as it signs anything else.
#
# THIS TRAFFIC IS SYNTHETIC. It proves the gate opens and the handler runs
# across two real processes on a real wire. It proves nothing about whether a
# deployment would ever send such a message, because today none would.
#
# The assertion is paired on purpose: "no refusal line" passes vacuously if
# the message never arrived, so we require BOTH that the unverified-refusal is
# absent AND that the handler visibly reached its own logic.
# --------------------------------------------------------------------------- #
log "Phase 5: injecting slash_propose and rep_resolve (SYNTHETIC traffic)"
BOB_CFG="$ROOT_BOB/etc/at/identity.cfg.json"
TARGET_UUID="$(node_uuid "$ROOT_CAROL")"

before_slash="$(count_in "$ROOT_BOB" 'rejecting unverified slash_propose')"
before_res="$(count_in "$ROOT_BOB" 'rejecting unverified rep_resolve')"

LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" "$INJECT" \
  --root "$ROOT_ALICE" --peer "$BOB_CFG" --verb "slash propose" \
  --payload "{\"target_uuid\":\"$TARGET_UUID\",\"epoch\":1,\"reason\":\"cohort injection\"}" \
  || { err "FAIL (phase 5) — the injector could not hand the verb to alice"; dump_logs; exit 1; }

LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" "$INJECT" \
  --root "$ROOT_ALICE" --peer "$BOB_CFG" --verb "resolve reputation" \
  --payload "{\"query_id\":\"cohort-1\",\"subject_uuid\":\"$TARGET_UUID\",\"depth\":1}" \
  || { err "FAIL (phase 5) — the injector could not hand the resolve verb to alice"; dump_logs; exit 1; }

sleep 8
after_slash="$(count_in "$ROOT_BOB" 'rejecting unverified slash_propose')"
after_res="$(count_in "$ROOT_BOB" 'rejecting unverified rep_resolve')"

fail5=0
if [ "$after_slash" -gt "$before_slash" ]; then
  err "slash_propose was REFUSED AS UNVERIFIED — the gate is still shut."
  fail5=1
fi
if [ "$after_res" -gt "$before_res" ]; then
  err "rep_resolve was REFUSED AS UNVERIFIED — the gate is still shut."
  fail5=1
fi
# The paired half: the handler must have been REACHED. Any of its own outcomes
# will do — co-signing, declining on evidence, or ignoring a stale epoch — but
# silence means the message never arrived and the assertion above is empty.
reached=0
for pat in "co-signed slash_propose" "declining slash_propose" \
           "not co-signing slash_propose" "rejecting slash_propose"; do
  if saw "$ROOT_BOB" "$pat"; then reached=1; break; fi
done
if [ "$reached" -ne 1 ]; then
  err "the injected slash_propose never reached bob's handler at all — so"
  err "  'it was not refused as unverified' proves nothing. Look for the"
  err "  frame on alice's side ('Network: sent reputation.slash propose')."
  fail5=1
fi
if [ "$fail5" -ne 0 ]; then dump_logs; exit 1; fi
ok "phase 5 — both injected verbs passed the verified gate and were handled"

echo
log "PASS — the reputation gates are live:"
log "       1. a Paxos round COMMITTED (never once seen before this fix);"
log "       2. an application-driven transaction — one shared task uuid,"
log "          submitted by both the reactor and the author — reached"
log "          reputation AND committed, not just AT's own probes;"
log "       3. a checkpoint round was co-signed and stored;"
log "       4. slash_propose and rep_resolve — which nothing in production"
log "          originates — passed their gates when injected across the real"
log "          wire. That traffic is SYNTHETIC and proves the plumbing only."
exit 0
