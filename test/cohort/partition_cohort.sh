#!/usr/bin/env bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# partition_cohort.sh — Phase 4 DDIL: split a live cohort into two islands,
# keep both working, heal it, and prove the heal loses nothing.
#
# Seven real agorad nodes on one virtual L2 segment (bridge + netns, as the
# sibling cohorts), driven through the real app-event queues:
#
#   island A: ada, amy, dee, and cal, who first starts WHILE the network is split
#   island B: bob, ben, and eve, who first starts while split and must be refused
#
# THE SPLIT IS 3+2 ON PURPOSE. Admission and checkpoint finality both need a
# majority of the WHOLE group (ISSUES §2.22, §2.26), so an even split leaves
# neither half able to grow or finalize. Three of five can do both, and two of
# five can do neither. The test needs one island of each kind.
#
# THE SPLIT moves island B's host-side veths from the bridge to a second one
# (`ip link set V nomaster; ip link set V master agbr6b`). Inside the
# namespaces nothing changes, no carrier drops and no socket notices, which is
# what a real partition looks like from a node: the other side just goes
# quiet. AT has no liveness mechanism, so each island keeps its full roster and
# its group key; nothing detects the split, and nothing needs to.
#
# WHAT IT PROVES, in order:
#   1. discovery, and the group channel is live across the five founders;
#   2. baseline: ada's post reaches amy, dee, bob and ben;
#   3. THE SPLIT IS REAL: ada's post reaches amy and dee and neither of bob and
#      ben, and bob's reaches ben and none of A. These two posts are the ones
#      the heal must not lose;
#   4. BOTH ISLANDS KEEP WORKING, AND ONLY THE MAJORITY GROWS:
#      - cal starts in A and A admits it (three of five votes; a key rotation
#        in A). eve starts in B, B proposes it and must refuse it (two of five);
#      - a reaction commits bilaterally in EACH island;
#      - A (four of six, with cal) finalizes a checkpoint; B must NOT, since two
#        of five is no majority. Finalizing in both islands would leave two
#        finalized windows that no heal could reconcile.
#   5. THE HEAL: B's veths go back. Fresh posts cross both ways, B learns cal,
#      and the whole group takes in eve, which can then read it;
#   6. STORE-AND-FORWARD: the two split posts cross the healed network, each
#      exactly once, with its original content id. Nobody re-sends them by
#      hand: each node's periodic digest offers them and the other island asks
#      (peer_post_digest / peer_post_want / peer_post_backfill);
#   7. REPUTATION CARRIED FORWARD: the island whose chain is shorter adopts
#      the other's (which island that is depends on how much AT's own probes
#      committed on each side, so the script reads it off the log). That drops
#      the loser's split-time transaction; its nodes re-propose their own
#      halves ("re-proposing N dropped transaction(s)"), and the task then
#      commits on the adopted chain, as seen from a node of the OTHER island.
#      The winner's task needs no such check: it reached the losers inside
#      the adopted chain itself.
#
# NETNS ONLY. Under docker, `docker network disconnect` removes the interface a
# node's discovery socket is bound to, which is a different fault from a
# partition. The script refuses a docker backend rather than test that.
#
# BOUNDED BY OPEN AT ISSUES (ISSUES.md): §2.13, Paxos commits on one grant, so
# each island commits alone (which is what makes the chains fork, and is fine
# here); §2.18, a group_key_update that arrives early is dropped and never
# re-sent, which phase 5 may surface as a node that cannot decrypt after the
# heal. Phase 7 reads every through-split member's persisted chain.
#
# Requirements: root, iproute2, python3, and the built native layer
# (./build.sh). Nothing is minted, so no dart/Flutter/Ethne here.
#
# Usage:
#   sudo -E env "PATH=$PATH" ./test/cohort/partition_cohort.sh
#   sudo -E env "PATH=$PATH" WAIT=240 KEEP=1 ./test/cohort/partition_cohort.sh
#
# Env knobs: WAIT (per-phase timeout, default 120), GATE_WINDOW (how long a
#   negative waits, default 20), DIGEST_SEC (AT_SOCIAL_DIGEST_SEC for the
#   nodes, default 10; the digest rides identity's ~20 s sweep, so ~20 s is
#   the real floor), NEUTRAL (AT_REP_NEUTRAL, default 0.70), RESCORE_SEC
#   (AT_REP_RESCORE_SEC, default 5), CHECKPOINT_SEC (AT_REP_CHECKPOINT_SEC,
#   default 20), LOG_LEVEL (agorad's, 1=DEBUG, default 2=INFO), SUBNET (default
#   10.9.6), KEEP=1 (leave the network and run dir up; a failed run always
#   keeps them).
#
# THE NODES BOOT ONE AT A TIME, and phase 1 checks every "Network: added peer"
# by name. The first host runs (part-3261748, part-3263296, part-3273140) found a
# joiner that learned only the members that had sent it a history, so every
# encrypted frame from the others was deferred for the rest of the run: a lost
# baseline post, and lost admission votes. That was an AT defect, fixed
# 2026-09-25 (ISSUES.md §2.23). The check stays, so a regression fails here and
# not five phases later.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_AGORA_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "$PWD")"
AGORA_DIR="${1:-${AGORA_DIR:-$DEFAULT_AGORA_DIR}}"
AGORA_DIR="$(cd "$AGORA_DIR" 2>/dev/null && pwd || echo "$AGORA_DIR")"
NATIVE="$AGORA_DIR/native/build"
AGORAD="$NATIVE/agorad"
SHIM="$NATIVE/libagora_shim.so"
ATCORE="$NATIVE/at_core"

WAIT="${WAIT:-120}"
GATE_WINDOW="${GATE_WINDOW:-20}"
DIGEST_SEC="${DIGEST_SEC:-10}"
NEUTRAL="${NEUTRAL:-0.70}"
RESCORE_SEC="${RESCORE_SEC:-5}"
CHECKPOINT_SEC="${CHECKPOINT_SEC:-20}"
LOG_LEVEL="${LOG_LEVEL:-2}"   # agorad: 1=DEBUG 2=INFO
SUBNET="${SUBNET:-10.9.6}"
GEO="${GEO:-u4pruy}"
PREFIX=24

# Order fixes the addresses (.11 upward); the last two joined in 2026-09-28 and
# go at the end so the original five keep theirs.
NODES=(ada amy bob ben cal dee eve)
declare -A IP NS V VB ROOT PID
i=11
for n in "${NODES[@]}"; do
  IP[$n]="$SUBNET.$i"; NS[$n]="agpt$n"; V[$n]="agp$n"; VB[$n]="agp${n}b"
  i=$(( i + 1 ))
done
declare -A UUID_OF
BR=agbr6
BR2=agbr6b          # island B's bridge while split
FOUNDERS=(ada amy dee bob ben)
ISLAND_A=(ada amy dee)  # cal joins A while split
ISLAND_B=(bob ben eve)  # eve asks B while split, and must be refused

RUN="${AGORA_COHORT_RUN:-$AGORA_DIR/.coh/part-$$}"
LIBSTAGE="$RUN/lib"
for n in "${NODES[@]}"; do ROOT[$n]="$RUN/$n"; PID[$n]=""; mkdir -p "${ROOT[$n]}"; done

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
if ! have python3; then err "python3 not found."; exit 1; fi
if [ "${BACKEND:-netns}" != netns ] && [ "${BACKEND:-netns}" != auto ]; then
  err "partition_cohort.sh runs on netns only (see the header): a docker"
  err "disconnect removes the interface a node's discovery socket is bound to."
  exit 1
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
# SOCKET PATH BUDGET (see moderation_cohort.sh): AT's supervisor queue
# "AutonomousTrust" under $ROOT/var/at/ must fit sun_path's 108 bytes.
SUN_MAX=108
for n in "${NODES[@]}"; do
  need=$(( ${#ROOT[$n]} + 15 + 9 ))
  if [ "$need" -gt "$SUN_MAX" ]; then
    err "socket path too long: ${ROOT[$n]} needs $need bytes of $SUN_MAX."
    err "  Set AGORA_COHORT_RUN=/tmp/agp-\$\$"
    exit 1
  fi
done

if [ "$(id -u)" -ne 0 ] || ! have ip; then
  err "needs root and iproute2 (network namespaces)."; exit 1
fi
if ! ip netns add _agora_probe 2>/dev/null; then
  err "this kernel refuses network namespaces (CLONE_NEWNET); run on a host."; exit 1
fi
ip netns del _agora_probe 2>/dev/null

# --------------------------------------------------------------------------- #
# Network primitives: build, split, heal, tear down.
# --------------------------------------------------------------------------- #
net_reset() {
  local n
  for n in "${NODES[@]}"; do
    ip netns del "${NS[$n]}" 2>/dev/null
    ip link del "${VB[$n]}" 2>/dev/null
  done
  ip link del "$BR" 2>/dev/null
  ip link del "$BR2" 2>/dev/null
  return 0
}

net_up() {
  net_reset
  log "Creating bridges $BR (+ $BR2 for the split) and ${#NODES[@]} namespaces on $SUBNET.0/$PREFIX"
  ip link add "$BR" type bridge && ip link set "$BR" up || return 1
  ip link add "$BR2" type bridge && ip link set "$BR2" up || return 1
  local n
  for n in "${NODES[@]}"; do
    ip netns add "${NS[$n]}" || return 1
    ip link add "${V[$n]}" type veth peer name "${VB[$n]}" || return 1
    ip link set "${V[$n]}" netns "${NS[$n]}" || return 1
    ip link set "${VB[$n]}" master "$BR" || return 1
    ip link set "${VB[$n]}" up || return 1
    ip -n "${NS[$n]}" addr add "${IP[$n]}/$PREFIX" dev "${V[$n]}" || return 1
    ip -n "${NS[$n]}" link set "${V[$n]}" up || return 1
    ip -n "${NS[$n]}" link set lo up || return 1
  done
  if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
    echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
  fi
  for n in "${NODES[@]:1}"; do
    ip netns exec "${NS[ada]}" ping -c1 -W2 "${IP[$n]}" >/dev/null 2>&1 \
      || { err "no L2 path from ada to $n"; return 1; }
  done
  log "L2 segment ready"
}

reachable() { # from to
  ip netns exec "${NS[$1]}" ping -c1 -W1 "${IP[$2]}" >/dev/null 2>&1
}

split_net() {
  local n
  for n in "${ISLAND_B[@]}"; do
    ip link set "${VB[$n]}" nomaster && ip link set "${VB[$n]}" master "$BR2" || return 1
  done
  reachable ada bob && { err "split: ada still reaches bob"; return 1; }
  reachable bob ben || { err "split: bob cannot reach ben"; return 1; }
  reachable ada amy || { err "split: ada cannot reach amy"; return 1; }
  return 0
}

heal_net() {
  local n i
  for n in "${ISLAND_B[@]}"; do
    ip link set "${VB[$n]}" nomaster && ip link set "${VB[$n]}" master "$BR" || return 1
  done
  # Not one ping: the re-enslaved ports and a neighbour entry that went FAILED
  # during a long split can take a moment (part-3471189 failed a single 1 s
  # ping here). Ten seconds, then show the L2 state rather than guess.
  for i in $(seq 1 10); do
    reachable ada bob && reachable bob ada && return 0
    sleep 1
  done
  err "heal: ada and bob still cannot reach each other after 10 s. L2 state:"
  { bridge link show; ip -br link show master "$BR"; ip -br link show master "$BR2"
    ip -n "${NS[ada]}" neigh show; ip -n "${NS[bob]}" neigh show
    ip -n "${NS[bob]}" -br addr show; } >&2 2>&1
  return 1
}

node_start() { # name
  local n="$1"
  ip netns exec "${NS[$n]}" env \
    AUTONOMOUS_TRUST_ROOT="${ROOT[$n]}" \
    AT_PEER_NAME="$n" AT_PEER_SEED="partition-$n" \
    AT_OWN_GEOHASH="$GEO" \
    AT_SOCIAL_DIGEST_SEC="$DIGEST_SEC" \
    AT_REP_CHECKPOINT_SEC="$CHECKPOINT_SEC" \
    AT_REP_NEUTRAL="$NEUTRAL" AT_REP_RESCORE_SEC="$RESCORE_SEC" \
    LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    "$AGORAD" extern_to_at at_to_extern "$LOG_LEVEL" \
    >"${ROOT[$n]}/agorad.log" 2>&1 &
  PID[$n]=$!
}

node_stop() { # name
  [ -z "${PID[$1]}" ] && return 0
  kill "${PID[$1]}" 2>/dev/null; sleep 1; kill -9 "${PID[$1]}" 2>/dev/null
  PID[$1]=""
}

dump_logs() {
  local n
  for n in "${NODES[@]}"; do
    [ -f "${ROOT[$n]}/agorad.log" ] || continue
    echo "--- $n ---"
    tail -n 30 "${ROOT[$n]}/agorad.log"
  done
}

cleanup() {
  local rc="${1:-0}" n
  for n in "${NODES[@]}"; do node_stop "$n"; done
  if [ "${KEEP:-0}" = "1" ] || [ "$rc" != "0" ]; then
    log "Leaving the network and $RUN in place (exit $rc). Tear down with:"
    for n in "${NODES[@]}"; do log "  ip netns del ${NS[$n]}"; done
    log "  ip link del $BR; ip link del $BR2"
    return
  fi
  net_reset
  rm -rf "$RUN"
}
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT TERM

net_up || exit 1

# --------------------------------------------------------------------------- #
# The app-side driver. Everything down to cmd_observe_none_body is SPLICED
# VERBATIM out of moderation_cohort.sh when this file was written (the ctypes Ev
# mirror carries the ABI guard). The partition verbs below it are new.
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
    ]

# ABI guard: MUST equal sizeof(agora_event_t) in at_agora_shim.h. A silent drift
# here would decode every field past the drift point as garbage.
assert ctypes.sizeof(Ev) == 28600, f"Ev size {ctypes.sizeof(Ev)} != 28600 (ABI drift)"

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
    print(f"post_id={got['post_id']}")
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

def cmd_observe_saw(shim, root, marker, timeout, out_path):
    """A post carrying `marker` must arrive; record its author and content id,
    which a reaction has to address and phase 6 compares."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    got = _posts_with(lib, h, marker, time.time() + timeout, buf, cap)
    lib.agora_events_close(h)
    if got is None:
        print(f"observe-saw: no post carrying '{marker}' in {timeout}s", file=sys.stderr)
        return 5
    json.dump(got, open(out_path, "w"))
    print(f"got '{marker}' ({got['post_id'][:16]}…) from {got['author'][:12]}…")
    return 0


def cmd_react(shim, root, saw_path, timeout):
    """React to a recorded post: the bilateral act (reactor and author both
    score the same task), which is what a Paxos round needs to commit."""
    lib = open_lib(shim, root)
    lib.agora_react_post.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                     ctypes.POINTER(ctypes.c_uint8),
                                     ctypes.c_char_p]
    lib.agora_react_post.restype = ctypes.c_int
    h = connect(lib, timeout)
    if not h:
        return 2
    saw = json.load(open(saw_path))
    rc = lib.agora_react_post(h, b"extern_to_at", _uuid_arg(saw["author"]),
                              saw["post_id"].encode())
    print(f"react rc={rc} to {saw['post_id'][:16]}…")
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_observe_plain(shim, root, timeout):
    """Any feed post at all: the converge_gate probe's receiving half."""
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
    if verb == "observe-saw":
        return cmd_observe_saw(shim, root, argv[4], float(argv[5]), argv[6])
    if verb == "observe-plain":
        return cmd_observe_plain(shim, root, float(argv[4]))
    if verb == "react":
        return cmd_react(shim, root, argv[4], float(argv[5]))
    print(f"unknown verb {verb}", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

if ! python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$DRIVER"; then
  err "the embedded driver does not compile; refusing to start any node."
  exit 1
fi

drive() { # node verb args...
  local n="$1"; shift
  local verb="$1"; shift
  LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    python3 "$DRIVER" "$verb" "$SHIM" "${ROOT[$n]}" "$@"
}

node_uuid() { # node
  python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['uuid'])" \
    "${ROOT[$1]}/etc/at/identity.cfg.json"
}

# Log lines, with the ANSI colour codes stripped (as reputation_cohort.sh).
plain_log() { sed -e 's/\x1b\[[0-9;]*m//g' "${ROOT[$1]}/agorad.log" 2>/dev/null; }
saw() { plain_log "$1" | grep -q "$2"; }
count_in() { local c; c="$(plain_log "$1" | grep -c "$2")" || true; printf '%s' "${c:-0}"; }

# Nothing crossed the split to or from a node that started during it.
# Membership is not reachability: cal learns island B's members from A's
# histories (ISSUES §2.23, a joiner learns every member) and SENDS to them, so a
# PEER event for bob proves nothing. What must hold is that every one of those
# frames died at the split: the far island's logs never name the joiner or its
# address, and the joiner never logs anything received from the far island.
# Outbound lines on the joiner's side ("sent ... to <far address>") are
# expected and ignored.
no_crosstalk() { # joiner "far nodes" -> 0 when nothing crossed
  local j="$1" far="$2" n c rc=0 pat names="" addrs=""
  sleep "$GATE_WINDOW"
  for n in $far; do
    pat="${IP[$j]//./\\.}\\| from $j\\b\\| by $j\\b\\|added peer $j "
    c=$(count_in "$n" "$pat")
    if [ "$c" -gt 0 ]; then
      err "  $n logged $c line(s) naming $j or ${IP[$j]} while split:"
      plain_log "$n" | grep "$pat" | head -3 >&2; rc=1
    fi
    names="${names:+$names\\|}$n"; addrs="$addrs\\|from ${IP[$n]//./\\.}"
  done
  pat="\\(from\\|by\\) \\($names\\)\\b$addrs"
  c=$(count_in "$j" "$pat")
  if [ "$c" -gt 0 ]; then
    err "  $j logged $c line(s) received from the far island while split:"
    plain_log "$j" | grep "$pat" | head -3 >&2; rc=1
  fi
  return $rc
}

# The app-driven task a node submitted most recently (`cap -` is the marker of
# an app interaction, never one of AT's probes).
app_task_of() {
  plain_log "$1" \
    | sed -n 's/.*forwarding transaction for task \([0-9a-f-]*\),.*(cap -,.*/\1/p' \
    | tail -1
}

# Prove the group channel publisher -> observer is live before asserting what
# rides it (a membership change re-keys the group). As moderation_cohort.sh's.
converge_gate() { # publisher observer label
  local deadline=$(( SECONDS + WAIT )) round=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    round=$(( round + 1 ))
    drive "$2" observe-plain 20 >/dev/null 2>&1 &
    local obs=$!
    sleep 2
    drive "$1" publish "group probe $3 $round" 0 "$WAIT" >/dev/null 2>&1
    if wait "$obs"; then
      log "group channel live: $3 (probe $round)"
      return 0
    fi
    log "  group channel not settled yet: $3 (probe $round), retrying"
  done
  return 1
}

# `pub` publishes `marker`; every node in `pos` must receive it and none in
# `neg`. All observers listen before the publish, one driver per node.
deliver() { # pub marker "pos nodes" "neg nodes"
  local pub="$1" marker="$2" n rc=0
  local -a pids=() names=() kinds=()
  for n in $3; do
    drive "$n" observe-body "$marker" "$WAIT" >"$RUN/obs-$marker-$n.out" & pids+=($!); names+=("$n"); kinds+=(pos)
  done
  for n in $4; do
    drive "$n" observe-none-body "$marker" "$GATE_WINDOW" >/dev/null & pids+=($!); names+=("$n"); kinds+=(neg)
  done
  sleep 4
  drive "$pub" publish "$marker" 0 "$WAIT" >/dev/null || return 4
  local k s
  for k in "${!pids[@]}"; do
    wait "${pids[$k]}"; s=$?
    if [ "$s" -ne 0 ]; then
      if [ "${kinds[$k]}" = pos ]; then err "  ${names[$k]} did not receive '$marker' (rc=$s)"
      else err "  ${names[$k]} RECEIVED '$marker' across the split (rc=$s)"; fi
      rc=$s
    fi
  done
  return "$rc"
}

decrypt_report() {
  local n
  for n in "${NODES[@]}"; do
    [ -f "${ROOT[$n]}/agorad.log" ] || continue
    err "  $n: $(count_in "$n" 'group decrypt failed') group-decrypt failure(s), " \
        "$(count_in "$n" 'asking .* for .* missed post') want(s) sent, " \
        "$(count_in "$n" 'backfilled .* post') backfill round(s) served"
  done
}

# --------------------------------------------------------------------------- #
# Phase 1 — five founders discover each other; the group channel is live
# --------------------------------------------------------------------------- #
log "Phase 1: starting ${FOUNDERS[*]} one at a time (cal and eve wait for the split)"
started=()
for n in "${FOUNDERS[@]}"; do
  node_start "$n"
  sleep 3
  kill -0 "${PID[$n]}" 2>/dev/null || { err "FAIL (phase 1): $n died at start"; dump_logs; exit 1; }
  if [ "${#started[@]}" -eq 0 ]; then
    # The founder: let it self-bootstrap its group before anyone asks to join.
    deadline=$(( SECONDS + WAIT ))
    until saw "$n" "self-bootstrapping a fresh group" || [ "$SECONDS" -ge "$deadline" ]; do sleep 1; done
  else
    drive "$n" peers "${#started[@]}" "$WAIT" >/dev/null \
      || { err "FAIL (phase 1): $n did not join the ${#started[@]} running node(s) in ${WAIT}s"; dump_logs; exit 1; }
  fi
  started+=("$n")
done
# Which founders a node's APP never saw, by name. part-3486847 failed here with
# the network layer complete on every node, and the discarded output was the
# only record of who was missing.
missing_from_app() { # node -> names absent from its last `peers` output
  local n="$1" m u out=""
  for m in "${FOUNDERS[@]}"; do
    [ "$m" = "$n" ] && continue
    u="$(node_uuid "$m" 2>/dev/null | tr -d '-')"
    grep -q "^  $u\$" "$RUN/peers-$n.out" 2>/dev/null || out="$out $m"
  done
  echo "${out# }"
}
for n in "${FOUNDERS[@]}"; do
  if ! drive "$n" peers $(( ${#FOUNDERS[@]} - 1 )) "$WAIT" >"$RUN/peers-$n.out"; then
    err "FAIL (phase 1): $n did not discover every other founder in ${WAIT}s"
    err "  $n's app never saw: $(missing_from_app "$n")"
    err "  $n's identity roster replay: $(count_in "$n" 'peer roster replay reached the app') refused replay(s)"
    for m in "${FOUNDERS[@]}"; do
      [ "$m" = "$n" ] && continue
      saw "$n" "Network: added peer $m " || err "  $n never added $m at the network layer"
    done
    dump_logs; exit 1
  fi
done
# Admitted at the NETWORK layer too, by name: the defect this boot order avoids
# (ISSUES.md §2.23) shows exactly as a missing "Network: added peer <name>".
deadline=$(( SECONDS + WAIT ))
while :; do
  missing=""
  for n in "${FOUNDERS[@]}"; do
    for m in "${FOUNDERS[@]}"; do
      [ "$n" = "$m" ] && continue
      saw "$n" "Network: added peer $m " || missing="$missing $n->$m"
    done
  done
  [ -z "$missing" ] && break
  if [ "$SECONDS" -ge "$deadline" ]; then
    err "FAIL (phase 1): accepted but never added at the network layer:$missing"
    err "  Every encrypted frame from such a peer is deferred forever (ISSUES.md §2.23)."
    dump_logs; exit 1
  fi
  sleep 2
done
for n in "${FOUNDERS[@]}"; do UUID_OF[$n]="$(node_uuid "$n")"; done
converge_gate ada bob "ada->bob" && converge_gate bob ada "bob->ada" \
  || { err "FAIL (phase 1): the group channel never settled"; dump_logs; exit 1; }
ok "phase 1: five founders, one group"

# --------------------------------------------------------------------------- #
# Phase 2 — baseline
# --------------------------------------------------------------------------- #
log "Phase 2: ada posts; amy, dee, bob and ben must all receive it"
deliver ada "baseline-$$" "amy dee bob ben" "" \
  || { err "FAIL (phase 2): the connected group does not deliver"; dump_logs; exit 1; }
ok "phase 2: the connected group delivers"

# --------------------------------------------------------------------------- #
# Phase 3 — the split, and the two posts the heal must not lose
# --------------------------------------------------------------------------- #
log "Phase 3: splitting {ada, amy, dee} from {bob, ben}"
split_net || { err "FAIL (phase 3): could not split the segment"; exit 1; }
SPLIT_A="split-A-$$"; SPLIT_B="split-B-$$"
deliver ada "$SPLIT_A" "amy dee" "bob ben" \
  || { err "FAIL (phase 3): island A's post did not stay in island A"; dump_logs; exit 1; }
deliver bob "$SPLIT_B" "ben" "ada amy dee" \
  || { err "FAIL (phase 3): island B's post did not stay in island B"; dump_logs; exit 1; }
ok "phase 3: the split is real; '$SPLIT_A' is only in A, '$SPLIT_B' only in B"
# Their content ids, as the island that saw them computed them: phase 6 finds
# the backfill by id in the other island's logs.
post_id_of() { sed -n 's/^post_id=//p' "$RUN/obs-$1-$2.out" 2>/dev/null | head -1; }
SPLIT_A_ID="$(post_id_of "$SPLIT_A" amy)"; SPLIT_B_ID="$(post_id_of "$SPLIT_B" ben)"
[ -n "$SPLIT_A_ID" ] && [ -n "$SPLIT_B_ID" ] \
  || { err "FAIL (phase 3): could not read the split posts' content ids"; dump_logs; exit 1; }
ckpts_of() { local n t=0; for n in "$@"; do t=$(( t + $(count_in "$n" 'checkpoint stored') )); done; echo "$t"; }
CKPT_A0=$(ckpts_of ada amy dee); CKPT_B0=$(ckpts_of bob ben)

# --------------------------------------------------------------------------- #
# Phase 4 — both islands keep working
# --------------------------------------------------------------------------- #
# Admission needs a majority of the WHOLE group (ISSUES §2.26). A holds three
# of five and can admit; B holds two and must not. One joiner on each side.
log "Phase 4a: cal starts inside island A (3 of 5) and must be admitted"
node_start cal
drive cal peers 3 "$WAIT" >/dev/null \
  || { err "FAIL (phase 4a): cal did not join island A in ${WAIT}s"; dump_logs; exit 1; }
UUID_OF[cal]="$(node_uuid cal)"
no_crosstalk cal "bob ben" \
  || { err "FAIL (phase 4a): traffic crossed the split to or from cal"; dump_logs; exit 1; }
converge_gate ada amy "ada->amy (after cal)" \
  || { err "FAIL (phase 4a): island A's group never settled after cal joined"; dump_logs; exit 1; }
ok "phase 4a: A admitted cal; nothing crossed the split to or from it"

log "Phase 4a: eve starts inside island B (2 of 5) and must be refused"
node_start eve
sleep 3
kill -0 "${PID[eve]}" 2>/dev/null || { err "FAIL (phase 4a): eve died at start"; dump_logs; exit 1; }
UUID_OF[eve]="$(node_uuid eve)"
# The refusal is only evidence if B actually considered eve.
deadline=$(( SECONDS + WAIT ))
until saw bob "proposed peer eve for voting" || saw ben "proposed peer eve for voting"; do
  [ "$SECONDS" -lt "$deadline" ] \
    || { err "FAIL (phase 4a): neither bob nor ben ever proposed eve, so a refusal would prove nothing"; dump_logs; exit 1; }
  sleep 2
done
no_crosstalk eve "ada amy dee cal" \
  || { err "FAIL (phase 4a): traffic crossed the split to or from eve"; dump_logs; exit 1; }
for n in bob ben; do
  if saw "$n" "majority vote reached for ${UUID_OF[eve]}" || saw "$n" "Network: added peer eve "; then
    err "FAIL (phase 4a): $n admitted eve with two of five. Admission must count"
    err "  the whole group: ADMISSION_QUORUM (id_proc.c), ISSUES §2.26."
    plain_log "$n" | grep "majority vote reached for ${UUID_OF[eve]}\\|added peer eve " | head -3 >&2
    dump_logs; exit 1
  fi
done
ok "phase 4a: B proposed eve and refused (2 of 5 is no majority)"

island_commit() { # author reactor island-label -> sets ISLAND_TASK
  local author="$1" reactor="$2" label="$3" saw_json="$RUN/saw-$3.json"
  drive "$reactor" observe-saw "rep-$label-$$" "$WAIT" "$saw_json" >/dev/null &
  local o=$!
  sleep 3
  drive "$author" publish "rep-$label-$$" 0 "$WAIT" >/dev/null || return 4
  wait "$o" || return 5
  drive "$reactor" react "$saw_json" "$WAIT" >/dev/null || return 4
  local deadline=$(( SECONDS + WAIT )) t_a="" t_r=""
  ISLAND_TASK=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    t_a=$(app_task_of "$author"); t_r=$(app_task_of "$reactor")
    if [ -n "$t_a" ] && [ "$t_a" = "$t_r" ]; then
      if saw "$author" "task $t_a is bilateral" || saw "$reactor" "task $t_a is bilateral"; then
        ISLAND_TASK="$t_a"; return 0
      fi
    fi
    sleep 2
  done
  err "  $label: author task '${t_a:-none}', reactor task '${t_r:-none}', never bilateral"
  return 6
}

log "Phase 4b: a reaction commits bilaterally inside EACH island"
island_commit ada amy A || { err "FAIL (phase 4b): island A cannot commit"; dump_logs; exit 1; }
TASK_A="$ISLAND_TASK"
island_commit bob ben B || { err "FAIL (phase 4b): island B cannot commit"; dump_logs; exit 1; }
TASK_B="$ISLAND_TASK"
ok "phase 4b: A committed $TASK_A, B committed $TASK_B, apart"

log "Phase 4c: A (4 of 6) must finalize a checkpoint; B (2 of 5 in its view) must not"
sleep $(( CHECKPOINT_SEC * 2 + 5 ))
CKPT_B1=$(ckpts_of bob ben)
if [ "$CKPT_B1" -gt "$CKPT_B0" ]; then
  err "FAIL (phase 4c): island B finalized $(( CKPT_B1 - CKPT_B0 )) checkpoint(s) while"
  err "  split. Two finalized windows cannot be reconciled at the heal: check"
  err "  _ckpt_quorum_for_group (rep_proc.c) counts the whole group."
  dump_logs; exit 1
fi
# The positive control: without it, "B finalized nothing" could just mean
# nobody finalized anything.
CKPT_A1=$(ckpts_of ada amy dee)
if [ "$CKPT_A1" -le "$CKPT_A0" ]; then
  err "FAIL (phase 4c): island A (ada, amy, dee, cal: 4 of 6) finalized no checkpoint"
  err "  while split, so B's silence proves nothing."
  dump_logs; exit 1
fi
ok "phase 4c: A finalized ($(( CKPT_A1 - CKPT_A0 )) new checkpoint line(s)); B finalized nothing"

# --------------------------------------------------------------------------- #
# Phase 5 — the heal
# --------------------------------------------------------------------------- #
log "Phase 5: healing the segment"
heal_net || { err "FAIL (phase 5): could not heal the segment"; exit 1; }
HEAL_AT=$SECONDS
# Where each log stood at the heal: phase 7 reads only what came after, since
# every node also adopts chains while booting and joining.
declare -A HEAL_LINE
for n in "${NODES[@]}"; do HEAL_LINE[$n]=$(plain_log "$n" | wc -l); done
converge_gate ada bob "ada->bob (healed)" && converge_gate bob cal "bob->cal (healed)" || {
  err "FAIL (phase 5): the healed network does not deliver across the old split."
  err "  A rotated its key when cal joined; B must detect the mismatch (group"
  err "  decrypt failure -> partition probe) and adopt A's group. ISSUES.md"
  err "  §2.18 (a missed group_key_update is never re-sent) is the prime suspect."
  decrypt_report; dump_logs; exit 1
}
# cal already lists bob and ben from A's histories (phase 4a), so its PEER
# count proves nothing here; the heal's news is island B learning cal, and the
# whole group taking in eve, whom B alone could not admit.
drive cal peers 5 "$WAIT" >/dev/null \
  || { err "FAIL (phase 5): cal never discovered bob and ben"; dump_logs; exit 1; }
added_or_fail() { # node peer
  local deadline=$(( SECONDS + WAIT ))
  until saw "$1" "Network: added peer $2 "; do
    [ "$SECONDS" -lt "$deadline" ] \
      || { err "FAIL (phase 5): $1 never added $2 as a network peer"; dump_logs; exit 1; }
    sleep 2
  done
}
for n in bob ben; do added_or_fail "$n" cal; done
for n in ada amy dee bob ben cal; do added_or_fail "$n" eve; done
converge_gate ada eve "ada->eve (healed)" || {
  err "FAIL (phase 5): eve is listed but cannot read the group after the heal."
  decrypt_report; dump_logs; exit 1
}
ok "phase 5: healed in $(( SECONDS - HEAL_AT ))s; posts cross, B added cal, and everyone added eve"

# --------------------------------------------------------------------------- #
# Phase 6 — store-and-forward: the split posts cross, once, unchanged
# --------------------------------------------------------------------------- #
log "Phase 6: the split posts must reach the other island by backfill"
# Checked in each daemon's log, not by an app observer. The digest that
# triggers a backfill can land while phase 5 is still probing, and a node has
# one app queue: a POST event emitted before phase 6's observer attaches went
# nowhere, and the dedup ring (rightly) never emits it again. That was
# part-3330966 and part-3334323. The daemon's own "accepted (…, backfilled)"
# line, keyed by the content id phase 3 recorded, is the durable evidence;
# exactly one of them per node is the exactly-once check.
SETTLE=$(( DIGEST_SEC + 25 ))
backfill_count() { count_in "$1" "Identity: post $2 from .* accepted (hops=[0-9]*, backfilled)"; }
SF_PAIRS=("bob:$SPLIT_A_ID" "ben:$SPLIT_A_ID"
          "ada:$SPLIT_B_ID" "amy:$SPLIT_B_ID" "dee:$SPLIT_B_ID" "cal:$SPLIT_B_ID")
sf_rc=0
deadline=$(( SECONDS + WAIT + DIGEST_SEC ))
for pair in "${SF_PAIRS[@]}"; do
  n="${pair%%:*}"; id="${pair#*:}"
  until [ "$(backfill_count "$n" "$id")" -ge 1 ]; do
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 2
  done
done
sleep "$SETTLE"
for pair in "${SF_PAIRS[@]}"; do
  n="${pair%%:*}"; id="${pair#*:}"; c="$(backfill_count "$n" "$id")"
  if [ "$c" -ne 1 ]; then
    err "  $n: accepted ${id:0:16}… by backfill $c time(s) (want exactly 1)"; sf_rc=1
  fi
done
if [ "$sf_rc" -ne 0 ]; then
  err "FAIL (phase 6): a post made during the split did not reach the healed"
  err "  network exactly once."
  decrypt_report; dump_logs; exit 1
fi
ok "phase 6: '$SPLIT_A' reached bob and ben, '$SPLIT_B' reached ada, amy, dee and cal, once each, by backfill"

# --------------------------------------------------------------------------- #
# Phase 7 — reputation carried forward
# --------------------------------------------------------------------------- #
log "Phase 7: both islands' split-time tasks must survive the heal, two-sided, on every node"
# THE CHAIN ITSELF IS THE EVIDENCE, read from each node's persisted
# reputation-history (rewritten on every stored checkpoint). An earlier version
# looked for "task T is bilateral" on the other island, but that line is logged
# only where the second half is COMMITTED; a node that receives the finished
# entry through a chain adoption logs nothing about it. part-3632221
# (2026-09-29) had both tasks two-sided at the same index in all seven chains
# and still failed here. Checking both tasks on every member is also stronger:
# the old check followed one "losing" island's task, chosen from an adoption
# line that routine churn logs on every node.
chain_has_both() { # node task... -> 0 iff every task has both halves
  local f="${ROOT[$1]}/etc/at/reputation-history.cfg.json"; shift
  [ -s "$f" ] || return 1
  python3 - "$f" "$@" <<'PY'
import json, sys
try:
    chain = json.load(open(sys.argv[1])).get('chain') or []
except Exception:
    sys.exit(1)
full = {e.get('task_id') for e in chain if e.get('p1_id') and e.get('p2_id')}
sys.exit(0 if all(t in full for t in sys.argv[2:]) else 1)
PY
}
MEMBERS=(ada amy dee cal bob ben)   # through the split; eve joined after it
deadline=$(( SECONDS + WAIT )); missing=""
while [ "$SECONDS" -lt "$deadline" ]; do
  missing=""
  for n in "${MEMBERS[@]}"; do chain_has_both "$n" "$TASK_A" "$TASK_B" || missing="$missing $n"; done
  [ -z "$missing" ] && break
  sleep 3
done
# Informational: how the tasks got there.
healed_saw() { plain_log "$1" | tail -n +$(( HEAL_LINE[$1] + 1 )) | grep -q "$2"; }
reproposed=""
for n in "${MEMBERS[@]}"; do healed_saw "$n" "re-proposing [0-9]* dropped transaction" && reproposed="$reproposed $n"; done
if [ -n "$missing" ]; then
  err "FAIL (phase 7): after ${WAIT}s the persisted chain on:$missing lacks a"
  err "  two-sided entry for A's $TASK_A or B's $TASK_B."
  err "  re-proposals after the heal on:${reproposed:- none}."
  for n in $missing; do
    f="${ROOT[$n]}/etc/at/reputation-history.cfg.json"
    for t in "$TASK_A" "$TASK_B"; do
      grep -q "$t" "$f" 2>/dev/null && echo "  $n: $t present, one-sided" >&2 || echo "  $n: $t absent" >&2
    done
  done
  dump_logs; exit 1
fi
ok "phase 7: A's $TASK_A and B's $TASK_B are two-sided in all ${#MEMBERS[@]} members' chains (re-proposals after the heal on:${reproposed:- none})"

log "PASS: two islands kept working apart, and the heal lost neither a post nor a transaction."
log "  evidence: $RUN (kept with KEEP=1)"
exit 0
