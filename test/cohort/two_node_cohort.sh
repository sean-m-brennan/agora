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
# (peer UUID + presence + reputation + RTT + opt-in coarse POSITION). RTT is a
# network-latency proximity proxy in ms (0 = unknown). Position (Increment 2) is
# an opt-in coarse geohash bucket a node chooses to share; the app decodes it and
# computes geographic distance (see lib/src/geo/geohash.dart). Opt-in signed
# agora.profile (Increment 3, kind==5) is now ALSO on the C event surface
# (SOCIAL_APP_PLAN.md §5.1); this headless harness checks presence/RTT/position —
# see two_node_gui.sh to watch profiles + distance in the real Flutter UI.
#
# This run exercises BOTH halves of the opt-in position feature in one cohort:
# node 1 opts IN (AT_OWN_GEOHASH=$GEO1, default u4pruy), node 2 opts OUT. PASS
# requires: both nodes observe a peer + its RTT event (kind==3); node 2 observes
# node 1's shared position (kind==4, geohash==$GEO1); and node 1 observes NO
# position for the opted-out node 2 (the privacy control — silence is correct).
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
  local ns="$1" root="$2" name="$3" seed="$4" geo="${5:-}"
  # AT_OWN_GEOHASH opts this node IN to sharing its coarse position (Increment 2).
  # agorad's C node reads it once at identity init (_ensure_id_init); empty/unset
  # => opted OUT, the default, so nothing geographic is advertised or answered.
  # The veth must be up (done above) BEFORE agorad first generates config:
  # discover_network_for() captures the interface CIDR at generation time.
  ip netns exec "$ns" env \
    AUTONOMOUS_TRUST_ROOT="$root" \
    AT_PEER_NAME="$name" AT_PEER_SEED="$seed" \
    AT_OWN_GEOHASH="$geo" \
    LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    "$AGORAD" extern_to_at at_to_extern 2 \
    >"$root/agorad.log" 2>&1 &
  echo $!
}

# Node 1 opts IN with a fixed coarse bucket; node 2 opts OUT (no geohash). This
# single cohort exercises BOTH halves of the opt-in position feature: node 2 must
# OBSERVE node 1's shared bucket, while node 1 must observe NO position for the
# opted-out node 2 (the privacy control).
GEO1="${GEO1:-u4pruy}"
log "Starting node 1 in $NS1 (root=$ROOT1, opted-in geohash=$GEO1)"
PID1="$(start_node "$NS1" "$ROOT1" agora-node-1 cohort-seed-1 "$GEO1")"
log "Starting node 2 in $NS2 (root=$ROOT2, opted-out)"
PID2="$(start_node "$NS2" "$ROOT2" agora-node-2 cohort-seed-2 "")"

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
# The coarse geohash we EXPECT to observe for the peer (Increment 2, opt-in
# position). Non-empty => the peer opted in and must be seen sharing exactly this
# bucket. Empty => the OPT-OUT CONTROL: the peer opted out, so NO position event
# (kind==4) may arrive for it — silence is the correct, private behavior.
expect_pos = sys.argv[4] if len(sys.argv) > 4 else ""

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
        ("rtt_ms", ctypes.c_int32),          # AGORA_EVENT_RTT (offset 116)
        ("geohash", ctypes.c_char * (GEO + 1)),   # AGORA_EVENT_POSITION (offset 120)
        ("profile_json", ctypes.c_char * (PROF + 1)),  # AGORA_EVENT_PROFILE (offset 133)
        ("connection_state", ctypes.c_int32),  # AGORA_EVENT_CONNECTION_* (offset 2696)
        ("dm_seq", ctypes.c_int64),          # AGORA_EVENT_DM (offset 2704), appended LAST
        ("dm_ts", ctypes.c_double),
        ("dm_text", ctypes.c_char * (DM + 1)),
        ("post_id", ctypes.c_char * (PID + 1)),  # AGORA_EVENT_POST (offset 3745), appended LAST
        ("post_seq", ctypes.c_int64),
        ("post_ts", ctypes.c_double),
        ("post_required_tier", ctypes.c_int32),
        ("post_body", ctypes.c_char * (PBODY + 1)),
        ("reaction_post_id", ctypes.c_char * (PID + 1)),  # AGORA_EVENT_REACTION, appended LAST
        ("reaction_seq", ctypes.c_int64),
        ("reaction_ts", ctypes.c_double),
        ("in_group", ctypes.c_uint8),  # AGORA_EVENT_PEER
        ("proximity_band", ctypes.c_int32),  # AGORA_EVENT_PROXIMITY, appended LAST (reuses tail padding)
        # AGORA_EVENT_BUSINESS_AD (Phase 3 P3.2), appended LAST. business_bundle
        # is the OPAQUE Ethne page artifact — the core does not verify it.
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
# ABI guard: this MUST equal sizeof(agora_event_t) in at_agora_shim.h (22168 with
# the geohash + profile_json + connection_state + DM + POST + REACTION + in_group +
# proximity_band + BUSINESS_AD tail; rtt@116, geohash@120, profile_json@133,
# connection_state@2696, dm_seq@2704, post_id@3745, post_seq@3752, reaction tail after
# post_body, in_group@8016 + proximity_band@8020 in the tail padding, business tail
# from 8024, co-signing tail from 11288, business-post tail from 17864). If the C struct grows and this is not updated in lockstep, poll() would
# misread every field past the drift.
assert ctypes.sizeof(Ev) == 22168, f"Ev size {ctypes.sizeof(Ev)} != 22168 (ABI drift)"

lib = ctypes.CDLL(shim)
lib.agora_set_root.argtypes = [ctypes.c_char_p]; lib.agora_set_root.restype = None
lib.agora_events_open.argtypes = [ctypes.c_char_p]; lib.agora_events_open.restype = ctypes.c_void_p
lib.agora_events_request_roster.argtypes = [ctypes.c_void_p, ctypes.c_char_p]; lib.agora_events_request_roster.restype = ctypes.c_int
lib.agora_events_poll.argtypes = [ctypes.c_void_p, ctypes.POINTER(Ev), ctypes.c_int]; lib.agora_events_poll.restype = ctypes.c_int
lib.agora_events_close.argtypes = [ctypes.c_void_p]; lib.agora_events_close.restype = None

lib.agora_set_root(root.encode())
h = None
deadline = time.time() + timeout
peers = {}   # uuid_hex -> dict(rank, bound, att, rated, score, rtt, rtt_seen)
def _p(uid):
    return peers.setdefault(uid, dict(rank=0, bound=False, att=0.0,
                                      rated=False, score=0.0, rtt=0, rtt_seen=False,
                                      geohash="", pos_seen=False))
N = 64
buf = (Ev * N)()
grace = 0   # opt-out control: extra polls after ready before asserting absence
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
        p = _p(uid)
        if e.kind == 1:    # AGORA_EVENT_PEER
            p.update(rank=e.rank, bound=bool(e.operator_bound), att=e.operator_attested_at)
        elif e.kind == 2:  # AGORA_EVENT_REPUTATION
            p.update(rated=bool(e.rep_rated), score=e.rep_score)
        elif e.kind == 3:  # AGORA_EVENT_RTT
            p.update(rtt=e.rtt_ms, rtt_seen=True)
        elif e.kind == 4:  # AGORA_EVENT_POSITION
            p.update(geohash=e.geohash.decode("ascii", "replace"), pos_seen=True)
    ready = bool(peers) and any(p["rtt_seen"] for p in peers.values())
    if expect_pos:
        # Opt-in run: stop as soon as the peer's shared bucket is observed.
        if any(p["pos_seen"] and p["geohash"] == expect_pos
               for p in peers.values()):
            break
    elif ready:
        # Opt-out CONTROL: we cannot "wait for absence", so once the peer + its
        # RTT are seen (position would ride the SAME post-admission round-trip),
        # give a short grace for a stray position to arrive, then stop and assert
        # none did.
        grace += 1
        if grace >= 5:
            break
    time.sleep(0.6)
if h:
    lib.agora_events_close(h)

rtt_seen = any(p["rtt_seen"] for p in peers.values())
any_pos = any(p["pos_seen"] for p in peers.values())
pos_match = expect_pos and any(
    p["pos_seen"] and p["geohash"] == expect_pos for p in peers.values())
for uid, p in peers.items():
    # rtt_ms of 0 is a legitimate "unknown / not yet measured" value; report
    # whether an RTT event arrived at all, not just its magnitude.
    if p["rtt_seen"]:
        rtt = f"{p['rtt']}ms" if p["rtt"] > 0 else "observed(0=unknown)"
    else:
        rtt = "n/a"
    pos = f"'{p['geohash']}'" if p["pos_seen"] else "none(opted-out)"
    print(f"    peer {uid[:12]}… rank={p['rank']} operator_bound={p['bound']} "
          f"attested_at={p['att']:.0f} rep={'%.3f' % p['score'] if p['rated'] else 'n/a'} "
          f"rtt={rtt} position={pos}")

if not peers:
    print("    (no peers observed)")
    sys.exit(1)

# Increment 2 (opt-in coarse position) is the exit gate for this run.
if expect_pos:
    if pos_match:
        sys.exit(0)   # PASS: the opted-in peer's coarse bucket was observed
    print(f"    (expected peer position {expect_pos!r} was not observed)")
    sys.exit(3)
else:
    # Opt-out CONTROL: the peer must NOT have shared a position. Require RTT too,
    # so we know the event channel actually worked — otherwise "no position"
    # could just mean "no events at all", and the control would pass vacuously.
    if any_pos:
        print("    (opt-out CONTROL VIOLATED: a position event arrived for an "
              "opted-out peer — it should have shared nothing)")
        sys.exit(4)
    if rtt_seen:
        sys.exit(0)   # PASS: channel works (RTT seen) yet no position leaked
    print("    (peer observed but no RTT event — cannot confirm the channel "
          "carried events, so the position silence is inconclusive)")
    sys.exit(2)
PY

log "Waiting up to ${WAIT}s for mutual discovery…"
# node 1 opted IN, its peer (node 2) opted OUT -> node 1 must observe NO position
# for node 2 (EXPECT_POS=""): the privacy control.
echo "  node 1 ($IP1) roster [opted-in; peer opted-out => expect NO peer position]:"
python3 "$HARNESS" "$SHIM" "$ROOT1" "$WAIT" ""; S1=$?
# node 2 opted OUT, its peer (node 1) shares $GEO1 -> node 2 must observe it.
echo "  node 2 ($IP2) roster [opted-out; peer shares $GEO1 => expect that position]:"
python3 "$HARNESS" "$SHIM" "$ROOT2" "$WAIT" "$GEO1"; S2=$?

echo
if [ "$S1" -eq 0 ] && [ "$S2" -eq 0 ]; then
  log "PASS — mutual discovery + presence + reputation + RTT confirmed, AND the"
  log "       opt-in position feature: node 2 observed node 1's shared bucket"
  log "       ($GEO1), while node 1 observed NO position for the opted-out node 2."
  RESULT=0
else
  err "FAIL — cohort exit not met (node1 rc=$S1, node2 rc=$S2)."
  err "  rc legend: 0=pass 1=no-peer 2=no-RTT(inconclusive) 3=expected-position-missing 4=opt-out-leak"
  err "Daemon logs (tail):"
  echo "--- node1 ---"; tail -n 25 "$ROOT1/agorad.log"
  echo "--- node2 ---"; tail -n 25 "$ROOT2/agorad.log"
  echo "Debug tip: run with KEEP=1 and watch traffic:"
  echo "    ip netns exec $NS1 tcpdump -ni $V1 udp port 27787"
  RESULT=1
fi

exit $RESULT
