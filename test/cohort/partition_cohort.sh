#!/usr/bin/env bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# partition_cohort.sh — Phase 4 DDIL: split a live cohort into two islands,
# keep both working, heal it, and prove the heal loses nothing.
#
# Five real agorad nodes on one virtual L2 segment (bridge + netns, as the
# sibling cohorts), driven through the real app-event queues:
#
#   island A: ada, amy, and cal, who first starts WHILE the network is split
#   island B: bob, ben
#
# THE SPLIT moves island B's host-side veths from the bridge to a second one
# (`ip link set V nomaster; ip link set V master agbr6b`). Inside the
# namespaces nothing changes, no carrier drops and no socket notices, which is
# what a real partition looks like from a node: the other side just goes
# quiet. AT has no liveness mechanism, so each island keeps its full roster and
# its group key; nothing detects the split, and nothing needs to.
#
# WHAT IT PROVES, in order:
#   1. discovery, and the group channel is live across all four;
#   2. baseline: ada's post reaches amy, bob and ben;
#   3. THE SPLIT IS REAL: ada's post reaches amy and neither of bob and ben, and
#      bob's reaches ben and neither of ada and amy. These two posts are the
#      ones the heal must not lose;
#   4. BOTH ISLANDS KEEP WORKING:
#      - cal starts in A and joins it (a key rotation in A, and it makes the
#        islands 3 against 2);
#      - a reaction commits bilaterally in EACH island;
#      - island B must NOT finalize a checkpoint: two of a five-member group is
#        no majority. Finalizing in both islands would leave two finalized
#        windows that no heal could reconcile. That was reachable until the
#        checkpoint quorum counted the whole group (2026-09-25).
#   5. THE HEAL: B's veths go back. Fresh posts cross both ways, and cal, who
#      has never met bob or ben, sees them;
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
# heal. Phase 7 asserts on AT LEAST ONE node, as the sibling cohorts do.
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

NODES=(ada amy bob ben cal)
declare -A IP NS V VB ROOT PID
i=11
for n in "${NODES[@]}"; do
  IP[$n]="$SUBNET.$i"; NS[$n]="agpt$n"; V[$n]="agp$n"; VB[$n]="agp${n}b"
  i=$(( i + 1 ))
done
declare -A UUID_OF
BR=agbr6
BR2=agbr6b          # island B's bridge while split
ISLAND_A=(ada amy)  # cal joins A later
ISLAND_B=(bob ben)

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
  log "Creating bridges $BR (+ $BR2 for the split) and five namespaces on $SUBNET.0/$PREFIX"
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
  for n in amy bob ben cal; do
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
  local n
  for n in "${ISLAND_B[@]}"; do
    ip link set "${VB[$n]}" nomaster && ip link set "${VB[$n]}" master "$BR" || return 1
  done
  reachable ada bob || { err "heal: ada cannot reach bob"; return 1; }
  return 0
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


def cmd_observe_once(shim, root, marker, timeout, settle, out_path):
    """A post carrying `marker` arrives, and then no SECOND copy of it for
    `settle` seconds: a backfilled post is deduplicated in the core, and this
    is the app-side check that it was."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    seen = []
    deadline = time.time() + timeout
    first_at = None
    while time.time() < deadline:
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind == EV_POST and marker in e.post_body.decode(errors="replace"):
                seen.append(e.post_id.decode(errors="replace"))
                if first_at is None:
                    first_at = time.time()
                    deadline = min(deadline, first_at + settle)
        time.sleep(0.5)
    lib.agora_events_close(h)
    if not seen:
        print(f"observe-once: no post carrying '{marker}' in {timeout}s", file=sys.stderr)
        return 5
    json.dump({"post_ids": seen}, open(out_path, "w"))
    if len(seen) != 1:
        print(f"observe-once: '{marker}' arrived {len(seen)} times", file=sys.stderr)
        return 6
    print(f"got '{marker}' once ({seen[0][:16]}…)")
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


def cmd_peers_absent(shim, root, uuids, seconds):
    """No PEER event for any of `uuids` in `seconds`: cal, started inside
    island A, must not learn of island B while the network is split."""
    lib = open_lib(shim, root)
    h = connect(lib, seconds)
    if not h:
        return 2
    want = {_norm(u) for u in uuids.split(",") if u}
    cap = 64
    buf = (Ev * cap)()
    deadline = time.time() + seconds
    while time.time() < deadline:
        lib.agora_events_request_roster(h, b"extern_to_at")
        for e in drain(lib, h, buf, cap, deadline):
            if e.kind == EV_PEER and bytes(e.peer_uuid).hex() in want:
                lib.agora_events_close(h)
                print(f"peers-absent: saw {bytes(e.peer_uuid).hex()[:12]}…", file=sys.stderr)
                return 7
        time.sleep(1.0)
    lib.agora_events_close(h)
    print(f"none of {len(want)} peer(s) seen in {seconds}s, as required")
    return 0


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
    if verb == "observe-once":
        return cmd_observe_once(shim, root, argv[4], float(argv[5]),
                                float(argv[6]), argv[7])
    if verb == "observe-plain":
        return cmd_observe_plain(shim, root, float(argv[4]))
    if verb == "react":
        return cmd_react(shim, root, argv[4], float(argv[5]))
    if verb == "peers-absent":
        return cmd_peers_absent(shim, root, argv[4], float(argv[5]))
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
    drive "$n" observe-body "$marker" "$WAIT" >/dev/null & pids+=($!); names+=("$n"); kinds+=(pos)
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
# Phase 1 — four nodes discover each other; the group channel is live
# --------------------------------------------------------------------------- #
log "Phase 1: starting ada, amy, bob, ben one at a time (cal waits for the split)"
started=()
for n in ada amy bob ben; do
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
for n in ada amy bob ben; do
  drive "$n" peers 3 "$WAIT" >/dev/null \
    || { err "FAIL (phase 1): $n did not discover three peers in ${WAIT}s"; dump_logs; exit 1; }
done
# Admitted at the NETWORK layer too, by name: the defect this boot order avoids
# (ISSUES.md §2.23) shows exactly as a missing "Network: added peer <name>".
deadline=$(( SECONDS + WAIT ))
while :; do
  missing=""
  for n in ada amy bob ben; do
    for m in ada amy bob ben; do
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
for n in ada amy bob ben; do UUID_OF[$n]="$(node_uuid "$n")"; done
converge_gate ada bob "ada->bob" && converge_gate bob ada "bob->ada" \
  || { err "FAIL (phase 1): the group channel never settled"; dump_logs; exit 1; }
ok "phase 1: four nodes, one group"

# --------------------------------------------------------------------------- #
# Phase 2 — baseline
# --------------------------------------------------------------------------- #
log "Phase 2: ada posts; amy, bob and ben must all receive it"
deliver ada "baseline-$$" "amy bob ben" "" \
  || { err "FAIL (phase 2): the connected group does not deliver"; dump_logs; exit 1; }
ok "phase 2: the connected group delivers"

# --------------------------------------------------------------------------- #
# Phase 3 — the split, and the two posts the heal must not lose
# --------------------------------------------------------------------------- #
log "Phase 3: splitting {ada, amy} from {bob, ben}"
split_net || { err "FAIL (phase 3): could not split the segment"; exit 1; }
SPLIT_A="split-A-$$"; SPLIT_B="split-B-$$"
deliver ada "$SPLIT_A" "amy" "bob ben" \
  || { err "FAIL (phase 3): island A's post did not stay in island A"; dump_logs; exit 1; }
deliver bob "$SPLIT_B" "ben" "ada amy" \
  || { err "FAIL (phase 3): island B's post did not stay in island B"; dump_logs; exit 1; }
ok "phase 3: the split is real; '$SPLIT_A' is only in A, '$SPLIT_B' only in B"
CKPT_B0=$(( $(count_in bob 'checkpoint stored') + $(count_in ben 'checkpoint stored') ))

# --------------------------------------------------------------------------- #
# Phase 4 — both islands keep working
# --------------------------------------------------------------------------- #
log "Phase 4a: cal starts inside island A"
node_start cal
drive cal peers 2 "$WAIT" >/dev/null \
  || { err "FAIL (phase 4a): cal did not join island A in ${WAIT}s"; dump_logs; exit 1; }
UUID_OF[cal]="$(node_uuid cal)"
drive cal peers-absent "${UUID_OF[bob]},${UUID_OF[ben]}" "$GATE_WINDOW" >/dev/null \
  || { err "FAIL (phase 4a): cal learned of island B through the split"; dump_logs; exit 1; }
converge_gate ada amy "ada->amy (after cal)" \
  || { err "FAIL (phase 4a): island A's group never settled after cal joined"; dump_logs; exit 1; }
ok "phase 4a: cal joined A and knows nothing of B"

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

log "Phase 4c: island B must not finalize a checkpoint (2 of 5 is no majority)"
sleep $(( CHECKPOINT_SEC * 2 + 5 ))
CKPT_B1=$(( $(count_in bob 'checkpoint stored') + $(count_in ben 'checkpoint stored') ))
if [ "$CKPT_B1" -gt "$CKPT_B0" ]; then
  err "FAIL (phase 4c): island B finalized $(( CKPT_B1 - CKPT_B0 )) checkpoint(s) while"
  err "  split. Two finalized windows cannot be reconciled at the heal: check"
  err "  _ckpt_quorum_for_group (rep_proc.c) counts the whole group."
  dump_logs; exit 1
fi
CKPT_A=$(( $(count_in ada 'checkpoint stored') + $(count_in amy 'checkpoint stored') + $(count_in cal 'checkpoint stored') ))
ok "phase 4c: B finalized nothing while split (A stored $CKPT_A checkpoint line(s))"

# --------------------------------------------------------------------------- #
# Phase 5 — the heal
# --------------------------------------------------------------------------- #
log "Phase 5: healing the segment"
heal_net || { err "FAIL (phase 5): could not heal the segment"; exit 1; }
HEAL_AT=$SECONDS
converge_gate ada bob "ada->bob (healed)" && converge_gate bob cal "bob->cal (healed)" || {
  err "FAIL (phase 5): the healed network does not deliver across the old split."
  err "  A rotated its key when cal joined; B must detect the mismatch (group"
  err "  decrypt failure -> partition probe) and adopt A's group. ISSUES.md"
  err "  §2.18 (a missed group_key_update is never re-sent) is the prime suspect."
  decrypt_report; dump_logs; exit 1
}
drive cal peers 4 "$WAIT" >/dev/null \
  || { err "FAIL (phase 5): cal never discovered bob and ben"; dump_logs; exit 1; }
ok "phase 5: healed in $(( SECONDS - HEAL_AT ))s; posts cross, cal knows all four"

# --------------------------------------------------------------------------- #
# Phase 6 — store-and-forward: the split posts cross, once, unchanged
# --------------------------------------------------------------------------- #
log "Phase 6: the split posts must reach the other island by backfill"
SETTLE=$(( DIGEST_SEC + 25 ))
declare -A SF_PID
for n in bob ben; do
  drive "$n" observe-once "$SPLIT_A" "$WAIT" "$SETTLE" "$RUN/sf-$n.json" & SF_PID[$n]=$!
done
for n in ada amy cal; do
  drive "$n" observe-once "$SPLIT_B" "$WAIT" "$SETTLE" "$RUN/sf-$n.json" & SF_PID[$n]=$!
done
sf_rc=0
for n in "${!SF_PID[@]}"; do
  wait "${SF_PID[$n]}"; s=$?
  [ "$s" -ne 0 ] && { err "  $n: rc=$s (5 = never arrived, 6 = arrived more than once)"; sf_rc=1; }
done
if [ "$sf_rc" -ne 0 ]; then
  err "FAIL (phase 6): a post made during the split did not reach the healed"
  err "  network exactly once."
  decrypt_report; dump_logs; exit 1
fi
ok "phase 6: '$SPLIT_A' reached bob and ben, '$SPLIT_B' reached ada, amy and cal, once each"

# --------------------------------------------------------------------------- #
# Phase 7 — reputation carried forward
# --------------------------------------------------------------------------- #
log "Phase 7: the losing island's split-time task must survive the chain adoption"
island_of() { case "$1" in bob|ben) echo B ;; *) echo A ;; esac; }
deadline=$(( SECONDS + WAIT ))
loser=""; adopter=""; reproposed=""; carried=""; lose_task=""
while [ "$SECONDS" -lt "$deadline" ]; do
  if [ -z "$loser" ]; then
    for n in "${NODES[@]}"; do
      if saw "$n" "adopted .*chain .*dropped [1-9]"; then
        adopter="$n"; loser="$(island_of "$n")"; break
      fi
    done
  fi
  if [ -n "$loser" ]; then
    if [ "$loser" = B ]; then lose_task="$TASK_B"; others="ada amy cal"; mine="bob ben"
    else lose_task="$TASK_A"; others="bob ben"; mine="ada amy cal"; fi
    for n in $mine; do saw "$n" "re-proposing [0-9]* dropped transaction" && reproposed="$n"; done
    for n in $others; do saw "$n" "task $lose_task is bilateral" && carried="$n"; done
    [ -n "$carried" ] && break
  fi
  sleep 3
done
if [ -z "$loser" ]; then
  err "FAIL (phase 7): no node adopted the other island's chain in ${WAIT}s,"
  err "  so the forked chains never met (a Paxos grant needs equal lengths, and"
  err "  catch-up runs only when one is refused)."
  dump_logs; exit 1
fi
if [ -z "$carried" ]; then
  err "FAIL (phase 7): island $loser adopted (on $adopter), but its split-time task"
  err "  $lose_task never committed where the other island can see it."
  err "  re-proposal on $loser: ${reproposed:-none seen}. None means"
  err "  _repropose_dropped found nothing of its own to re-submit."
  dump_logs; exit 1
fi
ok "phase 7: island $loser adopted (on $adopter), re-proposed (on ${reproposed:-?}), and its task $lose_task is bilateral on $carried"

log "PASS: two islands kept working apart, and the heal lost neither a post nor a transaction."
log "  evidence: $RUN (kept with KEEP=1)"
exit 0
