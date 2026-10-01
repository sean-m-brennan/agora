#!/usr/bin/env bash
#
# moderation_cohort.sh — prove P4.1 moderation (block, report, expulsion
# ceiling) between REAL nodes.
#
# Three real agorad nodes on one virtual L2 segment (bridge + netns, exactly as
# its sibling cohorts), driven through the real app-event queues:
#
#   ada   moderates: she blocks, reports, and bounds;
#   bob   is the target;
#   carol is the CONTROL, so every negative below has a positive twin on the
#         same segment at the same moment. "ada did not receive it" proves
#         nothing unless carol, beside her, did.
#
# TIERS HAVE TO BE EARNED LIVE, AND THIS COHORT FOUND THAT THEY NEVER WERE.
# Its first host run had every peer still unrated after eleven commits: a score
# was computed only on a "request reputation", which no running node sends, so
# no tier had ever been published and every gate above tier 0 was shut. AT now
# rescores on a sweep (_rescore_peers / _rescore_sweep, AT_REP_RESCORE_SEC).
#
# Two knobs make that observable inside a cohort's patience. RESCORE_SEC=5
# instead of 60. NEUTRAL=0.70 instead of 0.2, because a fresh peer's score is
# the prereputation prior, NEUTRAL shrunk toward the scores of his other
# transactions. AT's probes score 0.50, so bob drifts from 0.70 toward tier 1's
# floor and does not sink below it. The phases therefore ask for the tier bob
# ACTUALLY holds, measured live: phase 1 needs tier >= 1, and phase 6 caps him
# one tier below whatever carol and ada both give him.
#
# Once the chains converged (ISSUES.md §2.15), he DID sink below it, to 0.43:
# the pure score divided by the task weights alone, so every score was
# multiplied by its reporter's reputation and the rescore sweep compounded it.
# Since 2026-09-23 it is a true weighted average (trust-tiers.md §5), and a peer
# whose transactions score 0.90 holds near 0.90.
#
# What it proves, in order:
#   1. discovery; the starting tier reached carol and ada, and an unbounded
#      peer's ceiling reads -1 on the wire, not 0.0 (the memset trap);
#   2. baseline: ada and carol both receive bob's plain post;
#   3. a block becomes VISIBLE: ada's app is re-sent bob with blocked=1;
#   4. bob's tier-1 post AND his tier-0 post reach carol and not ada. Tier 0 is
#      the hole P4.1 closed — a clamp to 0 cleared a floor of 0;
#   5. unblock restores delivery; a re-block SURVIVES ada's daemon restarting;
#   6. an authority ceiling GATES, it does not merely subtract: with bob at
#      tier P, ada first receives a tier-P post; capped one tier below, his
#      next tier-P post reaches carol and not ada, while a tier-(P-1) post still
#      reaches ada. Found writing this cohort and fixed in both runtimes: a
#      capped standing used to leave identity's tier untouched;
#   7. reports: ada's pairs bilaterally and commits; her second is refused by
#      the daily cap; carol's first is accepted (the cap is per reporter);
#      ada's view of bob moves down.
#   Reports run LAST because they are the one phase that lowers bob's score on
#   purpose, and phase 6's positive twin needs carol still to rate him at P.
#
# NOT COVERED HERE, deliberately: the Ethne half of an expulsion (minting,
# co-signing, the polity record). ethne_polity_roundtrip_test.dart and P3.3's
# staff_cohort.sh cover it; this cohort hands the core the finding the app
# derives from that record, through the same agora_peer_standing verb.
#
# BOUNDED BY OPEN AT ISSUES (ISSUES.md): §2.13, the Paxos quorum is 1 by
# accident, so nothing here leans on quorum size; §2.15, the chains still fork
# by order across three nodes, so the report is asserted bilateral on AT LEAST
# ONE node, never that all three agree.
#
# Requirements: python3, the built native layer (./build.sh), and EITHER root +
# iproute2 (netns) OR a usable docker daemon. Nothing is minted, so no
# dart/Flutter/Ethne here.
#
# Usage:
#   sudo -E env "PATH=$PATH" ./test/cohort/moderation_cohort.sh
#   sudo -E env "PATH=$PATH" WAIT=180 KEEP=1 ./test/cohort/moderation_cohort.sh
#
# Env knobs: BACKEND (auto|netns|docker), WAIT (per-phase timeout, default 90),
#   GATE_WINDOW (how long a negative waits, default 20), NEUTRAL
#   (AT_REP_NEUTRAL for the nodes, default 0.70), RESCORE_SEC
#   (AT_REP_RESCORE_SEC, default 5), CHECKPOINT_SEC (AT_REP_CHECKPOINT_SEC,
#   default 20), SUBNET (default 10.9.5), KEEP=1.

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
GATE_WINDOW="${GATE_WINDOW:-20}"
NEUTRAL="${NEUTRAL:-0.70}"
RESCORE_SEC="${RESCORE_SEC:-5}"
CHECKPOINT_SEC="${CHECKPOINT_SEC:-20}"
SUBNET="${SUBNET:-10.9.5}"
GEO="${GEO:-u4pruy}"
IP_ADA="$SUBNET.11"; IP_BOB="$SUBNET.12"; IP_CAROL="$SUBNET.13"; PREFIX=24

NS_ADA=agmoda; NS_BOB=agmodb; NS_CAROL=agmodc
BR=agbr5
V_ADA=agmva; V_ADAB=agmvab; V_BOB=agmvb; V_BOBB=agmvbb; V_CAROL=agmvc; V_CAROLB=agmvcb

BACKEND="${BACKEND:-auto}"
NET=agora-mod-net                          # docker network name

# The run dir lives under the agora directory, not /tmp: a docker daemon only
# bind-mounts paths shared with it, and a preserved failing run has to be
# rebobble from wherever the checkout is. The socket-path preflight below
# checks it fits sun_path before any daemon starts.
# "mod", not "moderation": from this checkout the longer name put carol's
# supervisor socket at 111 bytes of sun_path's 108 (first host run).
RUN="${AGORA_COHORT_RUN:-$AGORA_DIR/.coh/mod-$$}"
ROOT_ADA="$RUN/ada"; ROOT_BOB="$RUN/bob"; ROOT_CAROL="$RUN/carol"; LIBSTAGE="$RUN/lib"
mkdir -p "$ROOT_ADA" "$ROOT_BOB" "$ROOT_CAROL" "$LIBSTAGE"

PID_ADA=""; PID_BOB=""; PID_CAROL=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
if ! have python3; then err "python3 not found."; exit 1; fi
# Phase 1 needs bob at tier >= 1, whose floor is 0.50 (rep_proc.c TIER_FLOORS).
if ! python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if 0.50 <= v <= 1.0 else 1)" "$NEUTRAL" 2>/dev/null; then
  err "NEUTRAL must be a score in [0.50, 1.0]; got '$NEUTRAL'"; exit 1
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
for r in "$ROOT_ADA" "$ROOT_BOB" "$ROOT_CAROL"; do
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
    ip netns del "$NS_ADA" 2>/dev/null
    ip netns del "$NS_BOB" 2>/dev/null
    ip netns del "$NS_CAROL" 2>/dev/null
    ip link del "$V_ADAB" 2>/dev/null
    ip link del "$V_BOBB" 2>/dev/null
    ip link del "$V_CAROLB" 2>/dev/null
    ip link del "$BR" 2>/dev/null
  else
    docker rm -f agmoda agmodb agmodc >/dev/null 2>&1
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
    mk_ns "$NS_ADA" "$V_ADA" "$V_ADAB" "$IP_ADA" || { err "could not build $NS_ADA"; return 1; }
    mk_ns "$NS_BOB" "$V_BOB" "$V_BOBB" "$IP_BOB" || { err "could not build $NS_BOB"; return 1; }
    mk_ns "$NS_CAROL" "$V_CAROL" "$V_CAROLB" "$IP_CAROL" || { err "could not build $NS_CAROL"; return 1; }
    if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
      echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
    fi
    for tgt in "$IP_BOB" "$IP_CAROL"; do
      if ! ip netns exec "$NS_ADA" ping -c1 -W2 "$tgt" >/dev/null 2>&1; then
        err "no L2 path from ada to $tgt — discovery cannot work."
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
      AT_REP_NEUTRAL="$NEUTRAL" AT_REP_RESCORE_SEC="$RESCORE_SEC" \
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
      -e AT_REP_CHECKPOINT_SEC="$CHECKPOINT_SEC" \
      -e AT_REP_NEUTRAL="$NEUTRAL" -e AT_REP_RESCORE_SEC="$RESCORE_SEC" \
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
  for r in "$ROOT_ADA" "$ROOT_BOB" "$ROOT_CAROL"; do
    [ -f "$r/agorad.log" ] || continue
    echo "--- $(basename "$r") ---"
    tail -n 30 "$r/agorad.log"
  done
}

cleanup() {
  local rc="${1:-0}"
  node_stop "$PID_ADA"; node_stop "$PID_BOB"; node_stop "$PID_CAROL"
  if [ "${KEEP:-0}" = "1" ] || [ "$rc" != "0" ]; then
    log "Leaving the network and $RUN in place (exit $rc)."
    if [ "$BACKEND" = netns ]; then
      log "Tear down with:"
      log "  ip netns del $NS_ADA"
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
# The app-side driver. The ctypes Ev mirror, connect() and drain() below are
# SPLICED VERBATIM out of reputation_cohort.sh, so the ABI mirror cannot drift
# by hand-copy. The moderation verbs below them are new.
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
EV_REPUTATION = 2
EV_POST = 9
NO_CEILING = -1.0      # AGORA_NO_CEILING


def open_lib(shim, root):
    lib = ctypes.CDLL(shim)
    lib.agora_set_root.argtypes = [ctypes.c_char_p]; lib.agora_set_root.restype = None
    lib.agora_events_open.argtypes = [ctypes.c_char_p]; lib.agora_events_open.restype = ctypes.c_void_p
    lib.agora_events_request_roster.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.agora_events_request_roster.restype = ctypes.c_int
    lib.agora_events_poll.argtypes = [ctypes.c_void_p, ctypes.POINTER(Ev), ctypes.c_int]
    lib.agora_events_poll.restype = ctypes.c_int
    lib.agora_events_close.argtypes = [ctypes.c_void_p]; lib.agora_events_close.restype = None
    lib.agora_publish_post.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                       ctypes.c_char_p, ctypes.c_int]
    lib.agora_publish_post.restype = ctypes.c_int
    # The moderation verbs (Phase 4 P4.1). All three peer verbs take the
    # peer's 16 raw identity bytes; a 0 means QUEUED, not accepted — the report
    # caps are applied in the core afterwards, which is why phase 7 reads the
    # outcome off the log rather than off this rc.
    uuid_p = ctypes.POINTER(ctypes.c_uint8)
    for fn in ("agora_block", "agora_unblock", "agora_report_peer"):
        f = getattr(lib, fn)
        f.argtypes = [ctypes.c_void_p, ctypes.c_char_p, uuid_p]
        f.restype = ctypes.c_int
    lib.agora_peer_standing.argtypes = [ctypes.c_void_p, ctypes.c_char_p, uuid_p,
                                        ctypes.c_char_p, ctypes.c_double,
                                        ctypes.c_char_p, ctypes.c_char_p]
    lib.agora_peer_standing.restype = ctypes.c_int
    lib.agora_set_root(root.encode())
    return lib

def drain(lib, h, buf, cap, deadline):
    """Poll until the batch comes back SHORT, or the deadline passes.

    agora_events_poll returns at most 16 events per call whatever `max` says,
    so a single poll on a busy queue reads a sixteenth of it — which is how
    P3.3 spent four host runs believing its peers had not been discovered.

    COPIES, NOT VIEWS: `buf[i]` is a view into the poll buffer, so the next
    batch overwrote every event already collected, and a drain longer than
    one batch returned its last batch's events over and over. The copies of
    this function in the sibling cohorts still return views.
    """
    out = []
    batches = 0
    while batches < 64 and time.time() < deadline:
        n = lib.agora_events_poll(h, buf, cap)
        if n <= 0:
            break
        out.extend(Ev.from_buffer_copy(buf[i]) for i in range(n))
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


def _norm(u):
    return u.replace("-", "").lower()


def cmd_publish(shim, root, text, tier, timeout):
    """Publish an ordinary feed post at audience tier `tier`. The RECEIVER
    gates it: a node drops a post whose author it does not rate at `tier`."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    rc = lib.agora_publish_post(h, b"extern_to_at", text.encode(), int(tier))
    print(f"publish rc={rc} tier={tier}")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def _posts_with(lib, h, marker, deadline, buf, cap):
    """Every feed post whose body carries `marker`, until the deadline or the
    first one. A marker, not 'any post': the group probes and earlier phases'
    posts share this queue, and 'something arrived' would pass on the wrong one."""
    while time.time() < deadline:
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind == EV_POST and marker in e.post_body.decode(errors="replace"):
                return {"author": bytes(e.peer_uuid).hex(),
                        "post_id": e.post_id.decode(errors="replace"),
                        "tier": e.post_required_tier}
        time.sleep(0.5)
    return None


def cmd_observe_body(shim, root, marker, timeout):
    """The positive half: a post carrying `marker` must arrive."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    got = _posts_with(lib, h, marker, time.time() + timeout, buf, cap)
    lib.agora_events_close(h)
    if got is None:
        print(f"observe-body: no post carrying '{marker}' in {timeout}s", file=sys.stderr)
        return 5
    print(f"got '{marker}' ({got['post_id'][:16]}…, tier {got['tier']}) "
          f"from {got['author'][:12]}…")
    return 0


def cmd_observe_none_body(shim, root, marker, seconds):
    """The negative half, and a BOUNDED claim that says so: nothing carrying
    `marker` arrived in this window, on a segment where the same post
    demonstrably reached the control."""
    lib = open_lib(shim, root)
    h = connect(lib, seconds)
    if not h:
        print("observe-none-body: could not open the app-event channel", file=sys.stderr)
        return 2
    cap = 64
    buf = (Ev * cap)()
    got = _posts_with(lib, h, marker, time.time() + seconds, buf, cap)
    lib.agora_events_close(h)
    if got is not None:
        print(f"observe-none-body: '{marker}' ARRIVED and should have been gated "
              f"({got['post_id'][:16]}…, tier {got['tier']})", file=sys.stderr)
        return 7
    print(f"nothing carrying '{marker}' in {seconds}s, as required")
    return 0


def cmd_peer_verb(shim, root, verb, peer_uuid, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    fn = {"block": lib.agora_block, "unblock": lib.agora_unblock,
          "report": lib.agora_report_peer}[verb]
    rc = fn(h, b"extern_to_at", _uuid_arg(peer_uuid))
    print(f"{verb} rc={rc}")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_standing(shim, root, peer_uuid, standing, ceiling, source, reason, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    rc = lib.agora_peer_standing(h, b"extern_to_at", _uuid_arg(peer_uuid),
                                 standing.encode(), float(ceiling),
                                 source.encode(), reason.encode())
    print(f"standing rc={rc} ({standing}, ceiling {ceiling}, source {source})")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_await_blocked(shim, root, peer_uuid, want, timeout):
    """Wait until this node's app is TOLD the peer's block state is `want`.
    5 = no PEER event for the peer at all; 6 = events arrived, wrong state."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    target = _norm(peer_uuid)
    last = None
    deadline = time.time() + timeout
    while time.time() < deadline:
        lib.agora_events_request_roster(h, b"extern_to_at")
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind == EV_PEER and bytes(e.peer_uuid).hex() == target:
                last = e.blocked
        if last is not None and int(last) == int(want):
            break
        time.sleep(1.0)
    lib.agora_events_close(h)
    if last is None:
        print(f"await-blocked: no PEER event for {target[:12]}… in {timeout}s", file=sys.stderr)
        return 5
    print(f"{target[:12]}… blocked={last} (wanted {want})")
    return 0 if int(last) == int(want) else 6


def cmd_await_rep(shim, root, peer_uuid, min_tier, max_tier, ceiling, max_score,
                  timeout, out_path):
    """Wait for a REPUTATION event about the peer that satisfies every given
    bound. `-` leaves a bound open; `ceiling` is `none` (must read -1), `any`,
    or a number. 5 = no reputation event for the peer at all; 6 = events
    arrived and none satisfied the bounds. The last event seen is printed, and
    written to `out_path` when one is given."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    target = _norm(peer_uuid)

    def fits(r):
        if not r["rated"]:
            return False
        if min_tier != "-" and r["tier"] < int(min_tier):
            return False
        if max_tier != "-" and r["tier"] > int(max_tier):
            return False
        if ceiling == "none" and r["ceiling"] != NO_CEILING:
            return False
        if ceiling not in ("none", "any") and abs(r["ceiling"] - float(ceiling)) > 1e-6:
            return False
        if max_score != "-" and r["score"] >= float(max_score):
            return False
        return True

    last = None
    ok = False
    deadline = time.time() + timeout
    while time.time() < deadline and not ok:
        lib.agora_events_request_roster(h, b"extern_to_at")
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind == EV_REPUTATION and bytes(e.peer_uuid).hex() == target:
                last = {"score": e.rep_score, "rated": bool(e.rep_rated),
                        "tier": e.rep_tier, "ceiling": e.rep_ceiling}
                if fits(last):
                    ok = True
                    break
        if not ok:
            time.sleep(1.0)
    lib.agora_events_close(h)
    if last is None:
        print(f"await-rep: no REPUTATION event for {target[:12]}… in {timeout}s", file=sys.stderr)
        return 5
    print(f"{target[:12]}… score={last['score']:.3f} rated={last['rated']} "
          f"tier={last['tier']} ceiling={last['ceiling']}")
    if out_path:
        json.dump(last, open(out_path, "w"))
    return 0 if ok else 6


def cmd_observe_plain(shim, root, timeout):
    """Any feed post at all — the converge_gate probe's receiving half."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    deadline = time.time() + timeout
    while time.time() < deadline:
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind == EV_POST and e.post_id:
                lib.agora_events_close(h)
                return 0
        time.sleep(0.5)
    lib.agora_events_close(h)
    return 5


def main(argv):
    verb, shim, root = argv[1], argv[2], argv[3]
    if verb == "peers":
        return cmd_peers(shim, root, int(argv[4]), float(argv[5]))
    if verb == "publish":
        return cmd_publish(shim, root, argv[4], int(argv[5]), float(argv[6]))
    if verb == "observe-body":
        return cmd_observe_body(shim, root, argv[4], float(argv[5]))
    if verb == "observe-none-body":
        return cmd_observe_none_body(shim, root, argv[4], float(argv[5]))
    if verb == "observe-plain":
        return cmd_observe_plain(shim, root, float(argv[4]))
    if verb in ("block", "unblock", "report"):
        return cmd_peer_verb(shim, root, verb, argv[4], float(argv[5]))
    if verb == "standing":
        return cmd_standing(shim, root, argv[4], argv[5], argv[6], argv[7],
                            argv[8], float(argv[9]))
    if verb == "await-blocked":
        return cmd_await_blocked(shim, root, argv[4], int(argv[5]), float(argv[6]))
    if verb == "await-rep":
        return cmd_await_rep(shim, root, argv[4], argv[5], argv[6], argv[7],
                             argv[8], float(argv[9]), argv[10] if len(argv) > 10 else "")
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

# Prove the group channel publisher -> observer is live before asserting
# anything that rides it. A daemon restart is a membership change: the group
# re-keys, and a post sent into a re-keying group dies with "group decrypt
# failed" — so without this, phase 5's negative would pass on a post nobody
# could have received. Same shape as business_post_cohort.sh's.
converge_gate() { # publisher-root observer-root label
  local pub="$1" obs_root="$2" label="$3"
  local deadline=$(( SECONDS + WAIT ))
  local round=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    round=$(( round + 1 ))
    drive "$obs_root" observe-plain 20 >/dev/null 2>&1 &
    local obs=$!
    sleep 2
    drive "$pub" publish "group probe $label $round" 0 "$WAIT" >/dev/null 2>&1
    if wait "$obs"; then
      log "group channel live: $label (probe $round)"
      return 0
    fi
    log "  group channel not settled yet: $label (probe $round) — retrying"
  done
  return 1
}

# bob publishes one post at `tier`; `pos` must receive it and `neg` must not.
# Both observers are listening before he publishes, and each is on its OWN
# node — two drivers on one node would compete for one app queue.
# Echoes nothing; returns 0, or the failing observer's code (pos: 5, neg: 7).
split_delivery() { # marker tier pos-root neg-root
  local marker="$1" tier="$2" pos="$3" neg="$4"
  drive "$pos" observe-body "$marker" "$WAIT" &
  local o_pos=$!
  drive "$neg" observe-none-body "$marker" "$GATE_WINDOW" &
  local o_neg=$!
  sleep 4
  drive "$ROOT_BOB" publish "$marker" "$tier" "$WAIT" >/dev/null || return 4
  wait "$o_pos"; local s_pos=$?
  wait "$o_neg"; local s_neg=$?
  [ "$s_pos" -ne 0 ] && { err "  $(basename "$pos") (must receive) returned $s_pos"; return "$s_pos"; }
  [ "$s_neg" -ne 0 ] && { err "  $(basename "$neg") (must not receive) returned $s_neg"; return "$s_neg"; }
  return 0
}

# Both ada and carol must receive bob's post.
both_deliver() { # marker tier
  drive "$ROOT_ADA" observe-body "$1" "$WAIT" &
  local o_a=$!
  drive "$ROOT_CAROL" observe-body "$1" "$WAIT" &
  local o_c=$!
  sleep 4
  drive "$ROOT_BOB" publish "$1" "$2" "$WAIT" >/dev/null || return 4
  wait "$o_a"; local s_a=$?
  wait "$o_c"; local s_c=$?
  [ "$s_a" -ne 0 ] && err "  ada did not receive '$1' (rc=$s_a)"
  [ "$s_c" -ne 0 ] && err "  carol did not receive '$1' (rc=$s_c)"
  [ "$s_a" -ne 0 ] && return "$s_a"
  [ "$s_c" -ne 0 ] && return "$s_c"
  return 0
}

# --------------------------------------------------------------------------- #
# Phase 1 — discovery, and the starting tier actually reached the apps
# --------------------------------------------------------------------------- #
log "Phase 1: starting ada ($IP_ADA), bob ($IP_BOB), carol ($IP_CAROL) at AT_REP_NEUTRAL=$NEUTRAL"
PID_ADA="$(node_start "$NS_ADA" "$ROOT_ADA" agora-ada ada-seed "$IP_ADA")" || exit 1
PID_BOB="$(node_start "$NS_BOB" "$ROOT_BOB" agora-bob bob-seed "$IP_BOB")" || exit 1
PID_CAROL="$(node_start "$NS_CAROL" "$ROOT_CAROL" agora-carol carol-seed "$IP_CAROL")" || exit 1
sleep 8
for h in "$PID_ADA" "$PID_BOB" "$PID_CAROL"; do
  if ! node_alive "$h"; then err "a daemon exited early:"; dump_logs; exit 1; fi
done
for r in "$ROOT_ADA" "$ROOT_BOB" "$ROOT_CAROL"; do
  if ! drive "$r" peers 2 "$WAIT"; then
    err "FAIL (phase 1) — $(basename "$r") cannot see both peers."
    dump_logs; exit 1
  fi
done
BOB_UUID="$(node_uuid "$ROOT_BOB")"
log "bob is $BOB_UUID"

# The precondition every tier-dependent phase rests on, checked on BOTH
# receivers. rep_tier is what reputation published beside identity's
# tier_update, so it is the app-visible face of the tier identity gates on.
for r in "$ROOT_CAROL" "$ROOT_ADA"; do
  drive "$r" await-rep "$BOB_UUID" 1 - any - "$WAIT"; S_T=$?
  if [ "$S_T" -ne 0 ]; then
    err "FAIL (phase 1 precondition) — $(basename "$r") never rated bob at tier >= 1"
    err "  (rc=$S_T; 5 = no reputation event for him at all). rated=False means"
    err "  the rescore sweep never ran for him: check AT_REP_RESCORE_SEC reached"
    err "  the daemon and that _rescore_peers is called from the process loop."
    err "  Rated below tier 1 means his other transactions pulled him under 0.50."
    dump_logs; exit 1
  fi
done
# THE MEMSET TRAP. The shim memsets every event, so a reputation case that
# forgot to write rep_ceiling reports 0.0 — "floored at zero" — for every
# peer nobody has bounded.
drive "$ROOT_ADA" await-rep "$BOB_UUID" - - none - "$WAIT"; S_M=$?
if [ "$S_M" -ne 0 ]; then
  err "FAIL (phase 1) — an unbounded bob does not read rep_ceiling == -1 on ada"
  err "  (rc=$S_M). 0.0 here is the memset trap: the REPUTATION flatten case in"
  err "  at_agora_shim.c must write AGORA_NO_CEILING explicitly."
  dump_logs; exit 1
fi
ok "phase 1 — three nodes, mutually discovered; bob rated tier >= 1 by both, unbounded"

# --------------------------------------------------------------------------- #
# Phase 2 — baseline. Without this, every negative below proves nothing.
# --------------------------------------------------------------------------- #
log "Phase 2: bob posts at tier 0 — ada and carol must both receive it"
both_deliver "mod-baseline-$$" 0; S2=$?
if [ "$S2" -ne 0 ]; then
  err "FAIL (phase 2) — bob's plain post did not reach both peers (rc=$S2)."
  err "  That is the feed path, not moderation — nothing below can be asserted."
  dump_logs; exit 1
fi
ok "phase 2 — the baseline post reached ada and carol"

# --------------------------------------------------------------------------- #
# Phase 3 — a block becomes VISIBLE to the app
#
# Before P4.1 handle_app_block emitted NOTHING, and the app derived a peer's
# tier from his score, which a block does not touch — so a blocked peer went
# on rendering exactly as before. identity now re-emits the peer, and
# `blocked` rides the PEER event.
# --------------------------------------------------------------------------- #
log "Phase 3: ada blocks bob"
drive "$ROOT_ADA" block "$BOB_UUID" "$WAIT" || { err "FAIL (phase 3) — block refused"; dump_logs; exit 1; }
drive "$ROOT_ADA" await-blocked "$BOB_UUID" 1 "$WAIT"; S3=$?
if [ "$S3" -ne 0 ]; then
  err "FAIL (phase 3) — ada's app was never told bob is blocked (rc=$S3)."
  if saw "$ROOT_ADA" "locally blocked"; then
    err "  The core DID record the block ('locally blocked' is in ada's log),"
    err "  so the re-emit is what is missing: _reemit_peer_after_block."
  else
    err "  The core never logged 'locally blocked': the verb did not arrive."
  fi
  dump_logs; exit 1
fi
ok "phase 3 — the block is visible: ada's app reads bob blocked=1"

# --------------------------------------------------------------------------- #
# Phase 4 — a blocked peer's posts stop, at EVERY audience tier
# --------------------------------------------------------------------------- #
log "Phase 4a: bob posts at tier 1 — carol must receive it, ada must not"
split_delivery "mod-tier1-$$" 1 "$ROOT_CAROL" "$ROOT_ADA"; S4=$?
if [ "$S4" -ne 0 ]; then
  if [ "$S4" -eq 7 ]; then
    err "FAIL (phase 4a) — THE BLOCK LEAKED: ada received bob's tier-1 post."
  else
    err "FAIL (phase 4a) — carol, the control, did not get bob's tier-1 post"
    err "  (rc=$S4), so ada's silence proves nothing. Check carol still rates"
    err "  bob at tier >= 1."
  fi
  dump_logs; exit 1
fi
ok "phase 4a — same segment, same moment: carol heard the tier-1 post, ada did not"

# THE HOLE THIS INCREMENT EXISTS TO CLOSE. A block clamped bob to tier 0 and a
# public post declares tier 0; `0 < 0` is false, so it arrived anyway.
log "Phase 4b: bob posts at tier 0 — the hole P4.1 closed"
split_delivery "mod-tier0-$$" 0 "$ROOT_CAROL" "$ROOT_ADA"; S4=$?
if [ "$S4" -ne 0 ]; then
  if [ "$S4" -eq 7 ]; then
    err "FAIL (phase 4b) — THE TIER-0 HOLE IS OPEN: a blocked peer's PUBLIC"
    err "  post reached ada. The post path must ask _is_blocked directly; the"
    err "  tier clamp alone cannot stop a post whose floor is 0."
  else
    err "FAIL (phase 4b) — carol did not get bob's tier-0 post (rc=$S4)."
  fi
  dump_logs; exit 1
fi
ok "phase 4b — the tier-0 hole is closed: carol heard it, ada did not"

# --------------------------------------------------------------------------- #
# Phase 5 — unblock restores; a re-block SURVIVES a restart
# --------------------------------------------------------------------------- #
log "Phase 5: ada unblocks bob"
drive "$ROOT_ADA" unblock "$BOB_UUID" "$WAIT" || { err "FAIL (phase 5) — unblock refused"; dump_logs; exit 1; }
drive "$ROOT_ADA" await-blocked "$BOB_UUID" 0 "$WAIT"; S5=$?
if [ "$S5" -ne 0 ]; then
  err "FAIL (phase 5) — ada's app never read bob blocked=0 after unblock (rc=$S5)."
  dump_logs; exit 1
fi
both_deliver "mod-unblocked-$$" 0; S5=$?
if [ "$S5" -ne 0 ]; then
  err "FAIL (phase 5) — after unblock, bob's post did not reach both (rc=$S5)."
  err "  An unblock that clears the flag but not the drop is still a block."
  dump_logs; exit 1
fi
ok "phase 5 — unblock restored delivery"

log "Phase 5: ada re-blocks bob, then her daemon restarts"
drive "$ROOT_ADA" block "$BOB_UUID" "$WAIT" || { err "FAIL (phase 5) — re-block refused"; dump_logs; exit 1; }
drive "$ROOT_ADA" await-blocked "$BOB_UUID" 1 "$WAIT" >/dev/null \
  || { err "FAIL (phase 5) — the re-block never became visible"; dump_logs; exit 1; }
if [ ! -s "$ROOT_ADA/etc/at/social.cfg.json" ]; then
  err "FAIL (phase 5) — ada has no social.cfg.json after blocking: the block"
  err "  would not survive the restart this phase is about to do."
  dump_logs; exit 1
fi
cp "$ROOT_ADA/agorad.log" "$ROOT_ADA/agorad.before-restart.log"
node_stop "$PID_ADA"
PID_ADA="$(node_start "$NS_ADA" "$ROOT_ADA" agora-ada ada-seed "$IP_ADA")" || exit 1
sleep 8
if ! node_alive "$PID_ADA"; then err "ada's daemon did not come back:"; dump_logs; exit 1; fi
drive "$ROOT_ADA" peers 2 "$WAIT" >/dev/null \
  || { err "FAIL (phase 5) — ada did not rediscover both peers after restart"; dump_logs; exit 1; }
# REQUIRED, not hygiene: the restart re-keyed the group. carol publishes the
# probe because bob is blocked at ada and could never pass it.
if ! converge_gate "$ROOT_CAROL" "$ROOT_ADA" "carol -> ada"; then
  err "FAIL (phase 5 setup) — the group channel carol -> ada never came back"
  err "  after ada restarted. Look for 'group decrypt failed' in ada's log:"
  err "  this is AT group-key convergence, NOT moderation."
  dump_logs; exit 1
fi
drive "$ROOT_ADA" await-blocked "$BOB_UUID" 1 "$WAIT"; S5=$?
if [ "$S5" -ne 0 ]; then
  err "FAIL (phase 5) — THE BLOCK DID NOT SURVIVE THE RESTART (rc=$S5; 6 = ada"
  err "  reads bob unblocked). identity loads social.cfg.json at start-up."
  dump_logs; exit 1
fi
split_delivery "mod-restart-$$" 0 "$ROOT_CAROL" "$ROOT_ADA"; S5=$?
if [ "$S5" -ne 0 ]; then
  if [ "$S5" -eq 7 ]; then
    err "FAIL (phase 5) — ada reads bob blocked after restart, but his post"
    err "  ARRIVED: the flag was reloaded and the drop was not."
  else
    err "FAIL (phase 5) — carol did not get bob's post after ada restarted (rc=$S5)."
  fi
  dump_logs; exit 1
fi
ok "phase 5 — the re-block survived ada's restart, and still drops bob's posts"

# --------------------------------------------------------------------------- #
# Phase 6 — an authority ceiling GATES; it does not merely subtract
#
# The finding the app derives from an Ethne expulsion, handed to the core
# through the same verb (the Ethne half is out of scope; see the header). A
# CAPPED standing bounds bob one tier below P on ada without moving his stored
# score. The block is lifted first, or it would mask the ceiling.
# --------------------------------------------------------------------------- #
log "Phase 6: ada unblocks bob"
drive "$ROOT_ADA" unblock "$BOB_UUID" "$WAIT" >/dev/null \
  || { err "FAIL (phase 6) — unblock refused"; dump_logs; exit 1; }
drive "$ROOT_ADA" await-blocked "$BOB_UUID" 0 "$WAIT" >/dev/null \
  || { err "FAIL (phase 6) — the unblock never became visible"; dump_logs; exit 1; }

# P = the tier BOTH receivers give bob right now. The cap goes one tier below.
tier_of() { # root out-file -> echoes the tier, or nothing
  drive "$1" await-rep "$BOB_UUID" 1 - none - "$WAIT" "$2" >/dev/null || return 1
  python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['tier'])" "$2"
}
T_C="$(tier_of "$ROOT_CAROL" "$RUN/carol_bob.json")" \
  || { err "FAIL (phase 6 precondition) — carol no longer rates bob at tier >= 1 unbounded"; dump_logs; exit 1; }
T_A="$(tier_of "$ROOT_ADA" "$RUN/ada_bob.json")" \
  || { err "FAIL (phase 6 precondition) — ada no longer rates bob at tier >= 1 unbounded"; dump_logs; exit 1; }
P=$(( T_C < T_A ? T_C : T_A ))
# The top score of tier P-1, comfortably inside it (rep_proc.c TIER_FLOORS:
# 0.50, 0.65, 0.80, 0.90); tier 0's stays above COMM_CUTOFF (0.1).
case "$P" in
  1) CAP_AT=0.30 ;; 2) CAP_AT=0.55 ;; 3) CAP_AT=0.70 ;; *) CAP_AT=0.85 ;;
esac
LOWER=$(( P - 1 ))
log "Phase 6: bob is tier $T_C to carol, $T_A to ada; P=$P, capping ada at $CAP_AT (tier $LOWER)"

# NOT VACUOUS: before the cap, ada DOES receive a tier-P post from bob.
both_deliver "mod-uncapped-$$" "$P"; S6=$?
if [ "$S6" -ne 0 ]; then
  err "FAIL (phase 6 setup) — uncapped, bob's tier-$P post did not reach both"
  err "  (rc=$S6), though both rate him at tier >= $P. The receive gate and the"
  err "  published tier disagree, or the tier moved in between."
  dump_logs; exit 1
fi
drive "$ROOT_ADA" standing "$BOB_UUID" capped "$CAP_AT" ethne "moderation cohort" "$WAIT" \
  || { err "FAIL (phase 6) — the standing verb was refused"; dump_logs; exit 1; }
drive "$ROOT_ADA" await-rep "$BOB_UUID" - "$LOWER" "$CAP_AT" - "$WAIT"; S6=$?
if [ "$S6" -ne 0 ]; then
  if saw "$ROOT_ADA" "Standing\[ethne\]: .* capped at"; then
    err "FAIL (phase 6) — reputation recorded the cap but ada's app never read"
    err "  bob at tier <= $LOWER with ceiling $CAP_AT (rc=$S6). _publish_standing_change"
    err "  must report the tier of min(score, ceiling), not of the stored score."
  else
    err "FAIL (phase 6) — the finding never reached reputation (rc=$S6)."
  fi
  dump_logs; exit 1
fi
log "Phase 6: bob posts at tier $P — carol must receive it, ada must not"
split_delivery "mod-capped-$$" "$P" "$ROOT_CAROL" "$ROOT_ADA"; S6=$?
if [ "$S6" -ne 0 ]; then
  if [ "$S6" -eq 7 ]; then
    err "FAIL (phase 6) — THE CEILING DID NOT GATE: capped into tier $LOWER, bob's"
    err "  tier-$P post reached ada. identity gates on the tier reputation last"
    err "  SENT it: a cap must republish the tier (_publish_tier_change)."
  else
    err "FAIL (phase 6) — carol did not get bob's tier-$P post (rc=$S6)."
  fi
  dump_logs; exit 1
fi
# ...and it is a CEILING, not a block: what tier P-1 allows still arrives.
log "Phase 6: bob posts at tier $LOWER — ada must still receive it"
drive "$ROOT_ADA" observe-body "mod-lower-$$" "$WAIT" &
O6=$!
sleep 4
drive "$ROOT_BOB" publish "mod-lower-$$" "$LOWER" "$WAIT" >/dev/null
wait "$O6"; S6=$?
if [ "$S6" -ne 0 ]; then
  err "FAIL (phase 6) — capped into tier $LOWER, bob's TIER-$LOWER post did not"
  err "  reach ada (rc=$S6). A ceiling that stops everything is a block by"
  err "  another name."
  dump_logs; exit 1
fi
drive "$ROOT_ADA" standing "$BOB_UUID" proved -1 ethne "reinstated" "$WAIT" >/dev/null \
  || { err "FAIL (phase 6) — the reinstatement was refused"; dump_logs; exit 1; }
drive "$ROOT_ADA" await-rep "$BOB_UUID" - - none - "$WAIT"; S6=$?
if [ "$S6" -ne 0 ]; then
  err "FAIL (phase 6) — after reinstatement ada still reads a ceiling on bob (rc=$S6)."
  dump_logs; exit 1
fi
ok "phase 6 — the ceiling gated tier $P and admitted tier $LOWER, then lifted"

# --------------------------------------------------------------------------- #
# Phase 7 — reports: first-person, bilateral, capped per reporter
#
# A unilateral score commits nothing (reputation.c: a tx goes bilateral only
# when both halves are set), so a report is a directed verb the reported node
# pairs by staging its own half. Both halves derive ONE task uuid; the
# reporter's is `cap -, via first_person`. Its safety comes from that pairing
# and the caps, NOT from the quorum (§2.13).
# --------------------------------------------------------------------------- #
ADA_UUID="$(node_uuid "$ROOT_ADA")"
CAROL_UUID="$(node_uuid "$ROOT_CAROL")"
BEFORE="$RUN/ada_view_of_bob.json"
drive "$ROOT_ADA" await-rep "$BOB_UUID" - - any - "$WAIT" "$BEFORE" >/dev/null \
  || { err "FAIL (phase 7 setup) — ada holds no rating of bob to compare against"; dump_logs; exit 1; }
SCORE0="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['score'])" "$BEFORE")"

# The report task, read off a node's log: the reporter's line names its
# channel; the reported side's names the default one. The task uuid is what
# ties them.
report_task_of() { # root
  sed -e 's/\x1b\[[0-9;]*m//g' "$1/agorad.log" 2>/dev/null \
    | sed -n 's/.*forwarding transaction for task \([0-9a-f-]*\),.*(cap -, via first_person).*/\1/p' \
    | tail -1
}

log "Phase 7: ada reports bob (ada's view of bob before: $SCORE0)"
drive "$ROOT_ADA" report "$BOB_UUID" "$WAIT" || { err "FAIL (phase 7) — report refused (rc)"; dump_logs; exit 1; }
DL=$(( SECONDS + WAIT )); task=""
while [ "$SECONDS" -lt "$DL" ]; do
  task="$(report_task_of "$ROOT_ADA")"
  if [ -n "$task" ] && saw "$ROOT_BOB" "report from peer $ADA_UUID staged" \
     && saw "$ROOT_BOB" "forwarding transaction for task $task"; then
    break
  fi
  task=""
  sleep 2
done
if [ -z "$task" ]; then
  err "FAIL (phase 7) — ada's report did not pair on bob's side."
  err "  ada 'reported peer': $(count_in "$ROOT_ADA" "reported peer $BOB_UUID")"
  err "  ada first_person task: '$(report_task_of "$ROOT_ADA")'"
  err "  bob 'staged': $(count_in "$ROOT_BOB" "report from peer $ADA_UUID staged")"
  err "  A report that pairs on one side only commits nothing."
  dump_logs; exit 1
fi
ok "phase 7 — ada's report paired bilaterally (task $task)"

# BILATERAL, not merely committed. "Transaction committed" names ONE side's
# Paxos round; the report exists only once the reported peer's half is in the
# same entry. Run 9 (2026-09-23) passed the weaker check with ada's half alone
# and moved no score. One node is enough (§2.15): this phase asserts the
# report, not replication.
DL=$(( SECONDS + WAIT )); bilateral=0
while [ "$SECONDS" -lt "$DL" ]; do
  for r in "$ROOT_ADA" "$ROOT_BOB" "$ROOT_CAROL"; do
    if saw "$r" "task $task is bilateral"; then bilateral=1; break 2; fi
  done
  sleep 2
done
if [ "$bilateral" -ne 1 ]; then
  err "FAIL (phase 7) — the report $task never became a bilateral entry on ANY node."
  for r in "$ROOT_ADA" "$ROOT_BOB" "$ROOT_CAROL"; do
    err "  $(basename "$r"): rounds committed for it: $(count_in "$r" "Transaction committed (task $task)")"
  done
  err "  One side's round committing is not the report; both halves must land."
  dump_logs; exit 1
fi
ok "phase 7 — the report is a bilateral entry (on at least one node)"

log "Phase 7: ada reports bob AGAIN — the daily cap must refuse it"
before_ok="$(count_in "$ROOT_ADA" "reported peer $BOB_UUID")"
drive "$ROOT_ADA" report "$BOB_UUID" "$WAIT" >/dev/null || { err "FAIL (phase 7) — second report refused at the verb"; dump_logs; exit 1; }
DL=$(( SECONDS + WAIT )); refused=0
while [ "$SECONDS" -lt "$DL" ]; do
  if saw "$ROOT_ADA" "report of $BOB_UUID refused: daily report or accrual cap"; then refused=1; break; fi
  if [ "$(count_in "$ROOT_ADA" "reported peer $BOB_UUID")" -gt "$before_ok" ]; then refused=7; break; fi
  sleep 2
done
if [ "$refused" -ne 1 ]; then
  if [ "$refused" -eq 7 ]; then
    err "FAIL (phase 7) — THE CAP LEAKED: ada's second report of bob today was sent."
  else
    err "FAIL (phase 7) — ada's second report produced neither a refusal nor a send."
  fi
  dump_logs; exit 1
fi
ok "phase 7 — ada's second report was refused by the daily cap"

log "Phase 7: carol reports bob — her FIRST, so it must be accepted"
drive "$ROOT_CAROL" report "$BOB_UUID" "$WAIT" >/dev/null || { err "FAIL (phase 7) — carol's report refused at the verb"; dump_logs; exit 1; }
DL=$(( SECONDS + WAIT )); c_ok=0
while [ "$SECONDS" -lt "$DL" ]; do
  if saw "$ROOT_CAROL" "reported peer $BOB_UUID" \
     && saw "$ROOT_BOB" "report from peer $CAROL_UUID staged"; then c_ok=1; break; fi
  if saw "$ROOT_CAROL" "report of $BOB_UUID refused"; then c_ok=7; break; fi
  sleep 2
done
if [ "$c_ok" -ne 1 ]; then
  if [ "$c_ok" -eq 7 ]; then
    err "FAIL (phase 7) — carol's FIRST report was refused: the cap is being"
    err "  applied per TARGET, not per reporter."
  else
    err "FAIL (phase 7) — carol's report never paired on bob's side."
  fi
  dump_logs; exit 1
fi
ok "phase 7 — carol's first report was accepted (the cap is per reporter)"

log "Phase 7: ada's view of bob must move down from $SCORE0"
drive "$ROOT_ADA" await-rep "$BOB_UUID" - - any "$SCORE0" "$WAIT"; S7=$?
if [ "$S7" -ne 0 ]; then
  err "FAIL (phase 7) — ada's view of bob did not fall below $SCORE0 (rc=$S7)"
  err "  though her report committed. Either no rep request has rescored him"
  err "  since (raise WAIT), or the first_person channel carries no weight."
  dump_logs; exit 1
fi
ok "phase 7 — ada's view of bob moved down"

echo
log "PASS — P4.1 moderation holds between real nodes:"
log "       1. a block is VISIBLE to the app (blocked=1 on the PEER event);"
log "       2. a blocked peer's posts stop at tier 1 AND at tier 0, with the"
log "          control receiving both — the tier-0 hole is closed;"
log "       3. unblock restores delivery, and a block survives a restart;"
log "       4. an authority ceiling gates the tier above it and admits the one"
log "          below, the moment"
log "          it lands, and lifts on reinstatement;"
log "       5. a report pairs bilaterally and commits, is capped per reporter"
log "          per day, and lowers the reporter's view of its target."
exit 0
