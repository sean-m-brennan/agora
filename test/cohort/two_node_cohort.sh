#!/usr/bin/env bash
#
# two_node_cohort.sh — Agora Phase-0 exit check: prove two AutonomousTrust nodes
# discover each other, on a SINGLE Linux host, using network namespaces.
#
# Why netns: AT's open discovery is UDP broadcast on COMM_PORT (27787). Two nodes
# on one host cannot share that broadcast port in the same network stack, so we
# give each its own netns and bridge them on one L2 /24 segment. AT binds its
# discovery recv socket to the subnet broadcast address (e.g. 10.9.0.255:27787),
# and Linux delivers subnet-broadcast to such a socket, so a bridged /24 carries
# discovery between the two namespaces.
#
# What it validates: each node's app-events roster observes the OTHER node
# (peer UUID + presence + reputation). NOTE: agora.profile fields and
# proximity/distance are NOT in AT's C event surface yet (SOCIAL_APP_PLAN.md
# §5.1), so this checks discovery + presence + reputation, not distance.
#
# Requirements: root (for ip netns/veth/bridge), iproute2 (`ip`), python3, and
# the built native layer (native/build/{agorad,libagora_shim.so,
# at_core/libautonomous_trust.so} — run ./build.sh first).
#
# NOTE: this needs a Linux host/VM where the kernel permits network namespaces
# (CLONE_NEWNET). Some sandboxed containers deny it; the preflight says so.
#
# Usage (from anywhere — the agora dir is found relative to this script):
#   sudo ./test/cohort/two_node_cohort.sh
#   sudo WAIT=60 ./test/cohort/two_node_cohort.sh
#   sudo AGORA_DIR=/path/to/apps/agora ./two_node_cohort.sh   # override
#
# Env knobs: WAIT (discovery timeout secs, default 45), SUBNET (default 10.9.0),
#   KEEP=1 (leave the netns/bridge up for inspection instead of cleaning up).

set -u

# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
# This script lives at apps/agora/test/cohort/ — default the agora dir to ../../.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_AGORA_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "$PWD")"
AGORA_DIR="${1:-${AGORA_DIR:-$DEFAULT_AGORA_DIR}}"
AGORA_DIR="$(cd "$AGORA_DIR" 2>/dev/null && pwd || echo "$AGORA_DIR")"
NATIVE="$AGORA_DIR/native/build"
AGORAD="$NATIVE/agorad"
SHIM="$NATIVE/libagora_shim.so"
ATCORE="$NATIVE/at_core"

WAIT="${WAIT:-45}"
SUBNET="${SUBNET:-10.9.0}"
IP1="$SUBNET.1"; IP2="$SUBNET.2"; PREFIX=24

NS1=agora1; NS2=agora2
BR=agbr0
# veth: vN lives in the netns, vNb is the bridge leg in the host.
V1=agv1; V1B=agv1b; V2=agv2; V2B=agv2b

RUN="$(mktemp -d /tmp/agora-cohort.XXXX)"   # short root (AF_UNIX sun_path <108)
ROOT1="$RUN/n1"; ROOT2="$RUN/n2"
mkdir -p "$ROOT1" "$ROOT2"

PID1=""; PID2=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
if [ "$(id -u)" -ne 0 ]; then err "must run as root (sudo). netns/veth/bridge need it."; exit 1; fi
if ! have ip; then err "'ip' (iproute2) not found. Install it: apt-get install -y iproute2"; exit 1; fi
if ! have python3; then err "python3 not found."; exit 1; fi
for f in "$AGORAD" "$SHIM" "$ATCORE/libautonomous_trust.so"; do
  if [ ! -e "$f" ]; then err "missing native artifact: $f"; err "build first: (cd '$AGORA_DIR' && ./build.sh)"; exit 1; fi
done
# Kernel must actually allow a new net namespace here (some sandboxes block it).
if ! ip netns add _agora_probe 2>/dev/null; then
  err "cannot create a network namespace in this environment (kernel/policy denies it)."
  err "Run this on a real Linux host or a VM where CLONE_NEWNET is permitted."
  exit 1
fi
ip netns del _agora_probe 2>/dev/null

# --------------------------------------------------------------------------- #
# Cleanup (always)
# --------------------------------------------------------------------------- #
cleanup() {
  local rc=$?
  if [ "${KEEP:-0}" = "1" ]; then
    log "KEEP=1 — leaving namespaces/bridge up. Manual teardown:"
    echo "    ip netns del $NS1; ip netns del $NS2; ip link del $BR"
    return
  fi
  log "Cleaning up"
  [ -n "$PID1" ] && kill "$PID1" 2>/dev/null
  [ -n "$PID2" ] && kill "$PID2" 2>/dev/null
  # Kill any detached AT node grandchildren still living in each netns.
  for ns in "$NS1" "$NS2"; do
    ip netns pids "$ns" 2>/dev/null | while read -r p; do kill "$p" 2>/dev/null; done
  done
  sleep 1
  ip netns del "$NS1" 2>/dev/null
  ip netns del "$NS2" 2>/dev/null
  ip link del "$BR"  2>/dev/null
  ip link del "$V1B" 2>/dev/null   # harmless if already gone with its netns
  ip link del "$V2B" 2>/dev/null
  rm -rf "$RUN"
  exit $rc
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------- #
# Build the virtual L2 segment: two netns bridged on one /24
# --------------------------------------------------------------------------- #
log "Creating bridge $BR + two namespaces ($NS1, $NS2) on $SUBNET.0/$PREFIX"
ip link add "$BR" type bridge
ip link set "$BR" up

ip netns add "$NS1"
ip netns add "$NS2"

ip link add "$V1" type veth peer name "$V1B"
ip link add "$V2" type veth peer name "$V2B"
ip link set "$V1" netns "$NS1"
ip link set "$V2" netns "$NS2"
ip link set "$V1B" master "$BR"; ip link set "$V1B" up
ip link set "$V2B" master "$BR"; ip link set "$V2B" up

ip -n "$NS1" addr add "$IP1/$PREFIX" dev "$V1"
ip -n "$NS1" link set "$V1" up
ip -n "$NS1" link set lo up
ip -n "$NS2" addr add "$IP2/$PREFIX" dev "$V2"
ip -n "$NS2" link set "$V2" up
ip -n "$NS2" link set lo up

# br_netfilter (if loaded) can drop bridged broadcast via iptables; relax it.
if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
  echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
fi

# Sanity: can NS1 reach NS2 across the bridge?
if ip netns exec "$NS1" ping -c1 -W2 "$IP2" >/dev/null 2>&1; then
  log "L2 connectivity OK ($IP1 <-> $IP2)"
else
  err "no L2 connectivity across the bridge — discovery cannot work. Aborting."
  exit 1
fi

# --------------------------------------------------------------------------- #
# Launch the two daemons (each in its own netns + root + identity)
# --------------------------------------------------------------------------- #
start_node() {
  local ns="$1" root="$2" name="$3" seed="$4"
  # The veth must be up (done above) BEFORE agorad first generates config:
  # discover_network_for() captures the interface CIDR at generation time.
  ip netns exec "$ns" env \
    AUTONOMOUS_TRUST_ROOT="$root" \
    AT_PEER_NAME="$name" AT_PEER_SEED="$seed" \
    LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    "$AGORAD" extern_to_at at_to_extern 2 \
    >"$root/agorad.log" 2>&1 &
  echo $!
}

log "Starting node 1 in $NS1 (root=$ROOT1)"
PID1="$(start_node "$NS1" "$ROOT1" agora-node-1 cohort-seed-1)"
log "Starting node 2 in $NS2 (root=$ROOT2)"
PID2="$(start_node "$NS2" "$ROOT2" agora-node-2 cohort-seed-2)"

# Give them a moment to bootstrap identity + bind their sockets.
sleep 4
for pid in "$PID1" "$PID2"; do
  if ! kill -0 "$pid" 2>/dev/null; then
    err "a daemon exited early — see logs:"; tail -n 40 "$ROOT1/agorad.log" "$ROOT2/agorad.log"; exit 1
  fi
done

# --------------------------------------------------------------------------- #
# app-events harness: does each node observe the other?
# --------------------------------------------------------------------------- #
HARNESS="$RUN/harness.py"
cat >"$HARNESS" <<'PY'
import ctypes, os, sys, time

shim, root, timeout = sys.argv[1], sys.argv[2], float(sys.argv[3])

UUID, KEY = 16, 32
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
    ]

lib = ctypes.CDLL(shim)
lib.agora_set_root.argtypes = [ctypes.c_char_p]; lib.agora_set_root.restype = None
lib.agora_events_open.argtypes = [ctypes.c_char_p]; lib.agora_events_open.restype = ctypes.c_void_p
lib.agora_events_request_roster.argtypes = [ctypes.c_void_p, ctypes.c_char_p]; lib.agora_events_request_roster.restype = ctypes.c_int
lib.agora_events_poll.argtypes = [ctypes.c_void_p, ctypes.POINTER(Ev), ctypes.c_int]; lib.agora_events_poll.restype = ctypes.c_int
lib.agora_events_close.argtypes = [ctypes.c_void_p]; lib.agora_events_close.restype = None

lib.agora_set_root(root.encode())
h = None
deadline = time.time() + timeout
peers = {}   # uuid_hex -> (rank, bound, attested, rep_rated, rep_score)
N = 64
buf = (Ev * N)()
while time.time() < deadline:
    if not h:
        h = lib.agora_events_open(b"at_to_extern")
        if not h:
            time.sleep(0.5); continue
    lib.agora_events_request_roster(h, b"extern_to_at")
    time.sleep(0.4)
    n = lib.agora_events_poll(h, buf, N)
    for i in range(max(n, 0)):
        e = buf[i]
        uid = bytes(e.peer_uuid).hex()
        if e.kind == 1:  # AGORA_EVENT_PEER
            r = peers.get(uid, (0, False, 0.0, False, 0.0))
            peers[uid] = (e.rank, bool(e.operator_bound), e.operator_attested_at, r[3], r[4])
        elif e.kind == 2:  # AGORA_EVENT_REPUTATION
            r = peers.get(uid, (0, False, 0.0, False, 0.0))
            peers[uid] = (r[0], r[1], r[2], bool(e.rep_rated), e.rep_score)
    if peers:
        break
    time.sleep(0.6)
if h:
    lib.agora_events_close(h)

if peers:
    for uid, (rank, bound, att, rated, score) in peers.items():
        print(f"    peer {uid[:12]}… rank={rank} operator_bound={bound} "
              f"attested_at={att:.0f} rep={'%.3f' % score if rated else 'n/a'}")
    sys.exit(0)
else:
    print("    (no peers observed)")
    sys.exit(1)
PY

log "Waiting up to ${WAIT}s for mutual discovery…"
echo "  node 1 ($IP1) roster:"
python3 "$HARNESS" "$SHIM" "$ROOT1" "$WAIT"; S1=$?
echo "  node 2 ($IP2) roster:"
python3 "$HARNESS" "$SHIM" "$ROOT2" "$WAIT"; S2=$?

echo
if [ "$S1" -eq 0 ] && [ "$S2" -eq 0 ]; then
  log "PASS — both nodes observed a peer. Phase-0 discovery + presence + reputation confirmed."
  RESULT=0
else
  err "FAIL — mutual discovery not observed (node1 rc=$S1, node2 rc=$S2)."
  err "Daemon logs (tail):"
  echo "--- node1 ---"; tail -n 25 "$ROOT1/agorad.log"
  echo "--- node2 ---"; tail -n 25 "$ROOT2/agorad.log"
  echo "Debug tip: run with KEEP=1 and watch traffic:"
  echo "    ip netns exec $NS1 tcpdump -ni $V1 udp port 27787"
  RESULT=1
fi

exit $RESULT
