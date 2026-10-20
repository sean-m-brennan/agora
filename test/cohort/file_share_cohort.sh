#!/usr/bin/env bash
# file_share_cohort.sh — live check of file sharing in a DM thread: two real
# agorad nodes on one bridged /24 (as two_node_cohort.sh), driven through the
# real app-event queues the way the Flutter app is.
#
# What it proves, in order:
#   1. A BIG FILE ARRIVES WHOLE. n1 offers a $SIZE_MB MB random file to n2;
#      n2's app sees the offer, accepts, and the core pulls it. n2 reports DONE
#      with the finished path, its SHA-256 equals the source's, and n1 reports
#      DONE too. The rate is printed (MB/s); under ~1 MB/s is worth raising.
#   2. A RESTART RESUMES. n1 offers $RESUME_MB MB; once n2 holds a third of it,
#      n2 is killed -9 and started again on the same root. It must finish from
#      its bitmap (the store and .part.map survive) with the right hash.
#   3. A DECLINE IS FINAL. n2 declines an offer; n1 sees DECLINED.
#   4. A CANCEL MID-TRANSFER STOPS BOTH SIDES. n1 cancels $CANCEL_MB MB under
#      way; n2 sees CANCELLED and keeps no partial file.
#   5. THE LOGS ARE CLEAN. No "decrypt failed" from a file frame, and the
#      EAGAIN / refusal counts per node are printed.
#
# The app is not attached between driver calls, so the driver pulls the roster
# each time it looks: transfers are a STATE type, re-emitted on every pull.
#
# NETNS ONLY. Requirements: root + iproute2, python3 (stdlib only), and the
# built native layer (./build.sh).
#
# Usage:
#   sudo -E env "PATH=$PATH" ./test/cohort/file_share_cohort.sh
#   SIZE_MB=20 KEEP=1 ./test/cohort/file_share_cohort.sh
#
# Env knobs: SIZE_MB (default 150), RESUME_MB (40), CANCEL_MB (40), WAIT
# (discovery timeout, default 60), XFER_WAIT (per-transfer timeout, default
# 1800), SUBNET (default 10.9.12), LOG_LEVEL (default 2), KEEP=1.
# AT_FILE_CHUNK / AT_FILE_WINDOW pass through to both nodes, for tuning.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_AGORA_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "$PWD")"
AGORA_DIR="${1:-${AGORA_DIR:-$DEFAULT_AGORA_DIR}}"
AGORA_DIR="$(cd "$AGORA_DIR" 2>/dev/null && pwd || echo "$AGORA_DIR")"
NATIVE="$AGORA_DIR/native/build"
AGORAD="$NATIVE/agorad"
SHIM="$NATIVE/libagora_shim.so"
ATCORE="$NATIVE/at_core"

WAIT="${WAIT:-60}"
XFER_WAIT="${XFER_WAIT:-1800}"
SIZE_MB="${SIZE_MB:-150}"
RESUME_MB="${RESUME_MB:-40}"
CANCEL_MB="${CANCEL_MB:-40}"
LOG_LEVEL="${LOG_LEVEL:-2}"
SUBNET="${SUBNET:-10.9.12}"
IP1="$SUBNET.1"; IP2="$SUBNET.2"; PREFIX=24

NS1=agfile1; NS2=agfile2
BR=agfbr0
V1=agfv1; V1B=agfv1b; V2=agfv2; V2B=agfv2b

RUN="$(mktemp -d /tmp/agora-files.XXXX)"   # short root (AF_UNIX sun_path <108)
ROOT1="$RUN/n1"; ROOT2="$RUN/n2"
mkdir -p "$ROOT1" "$ROOT2"

PID1=""; PID2=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }
fail() { err "$*"; exit 1; }
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
  if [ "$rc" = "0" ]; then rm -rf "$RUN"; else log "Logs kept: $RUN/n1/agorad.log, $RUN/n2/agorad.log"; fi
  exit $rc
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------- #
# Build the virtual L2 segment: two netns bridged on one /24
# --------------------------------------------------------------------------- #
# What an earlier KEEP=1 run left up, these names only: its namespaces, with
# its daemons still running in them and holding the ports, made this run's
# network processes fail to start (ENOENT on every send to `network`; run-all
# 3927785 and 4015220).
for ns in "$NS1" "$NS2"; do
  if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$ns"; then
    log "Removing $ns left by an earlier run"
    ip netns pids "$ns" 2>/dev/null | while read -r p; do kill -9 "$p" 2>/dev/null; done
    ip netns del "$ns" 2>/dev/null
  fi
done
# A deleted netns is torn down only once its killed daemons have exited, so
# its veths' bridge-side ends can outlive the `netns del`; delete them by name
# (each takes its peer with it) or the `ip link add` below fails with "File
# exists" (run-all-4046791).
ip link del "$V1B" 2>/dev/null || true
ip link del "$V2B" 2>/dev/null || true
ip link del "$BR" 2>/dev/null || true

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
# Nodes
# --------------------------------------------------------------------------- #
start_node() { # ns root name
  ip netns exec "$1" env \
    AUTONOMOUS_TRUST_ROOT="$2" \
    AT_PEER_NAME="$3" AT_PEER_SEED="file-$3-$$" \
    ${AT_FILE_CHUNK:+AT_FILE_CHUNK="$AT_FILE_CHUNK"} \
    ${AT_FILE_WINDOW:+AT_FILE_WINDOW="$AT_FILE_WINDOW"} \
    LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    "$AGORAD" extern_to_at at_to_extern "$LOG_LEVEL" \
    >>"$2/agorad.log" 2>&1 &
  echo $!
}

stop_node() { # pid ns
  [ -z "$1" ] && return 0
  kill -9 "$1" 2>/dev/null
  ip netns pids "$2" 2>/dev/null | while read -r p; do kill -9 "$p" 2>/dev/null; done
  { wait "$1"; } 2>/dev/null
  return 0
}

# --------------------------------------------------------------------------- #
# The app-side driver: one verb per call, each on its own shim handle.
# --------------------------------------------------------------------------- #
DRIVER="$RUN/driver.py"
cat >"$DRIVER" <<'PY'
import ctypes, json, sys, time

UUID, KEY, GEO, PROF, DM, PID, PBODY = 16, 32, 12, 2560, 1024, 64, 4096
BDID, BADID, BBUN = 95, 64, 3072
BPID, BPBUN = 64, 4096
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
        # DM file sharing (45752): the file_* tail.
        ("file_size", ctypes.c_int64),
        ("file_done", ctypes.c_int64),
        ("file_ts", ctypes.c_double),
        ("file_state", ctypes.c_int32),
        ("file_outgoing", ctypes.c_int32),
        ("file_xfer_id", ctypes.c_char * (32 + 1)),
        ("file_name", ctypes.c_char * (255 + 1)),
        ("file_reason", ctypes.c_char * (31 + 1)),
        ("file_path", ctypes.c_char * (4095 + 1)),
    ]

# ABI guard: MUST equal sizeof(agora_event_t) in at_agora_shim.h.
assert ctypes.sizeof(Ev) == 45752, f"Ev size {ctypes.sizeof(Ev)} != 45752 (ABI drift)"

EV_PEER, EV_FILE = 1, 21
STATES = ['offered', 'accepted', 'done', 'declined', 'cancelled', 'failed', 'too_large']

verb, shim, root = sys.argv[1], sys.argv[2], sys.argv[3]
args = sys.argv[4:]
lib = ctypes.CDLL(shim)
lib.agora_set_root.argtypes = [ctypes.c_char_p]; lib.agora_set_root.restype = None
lib.agora_events_open.argtypes = [ctypes.c_char_p]; lib.agora_events_open.restype = ctypes.c_void_p
lib.agora_events_request_roster.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.agora_events_poll.argtypes = [ctypes.c_void_p, ctypes.POINTER(Ev), ctypes.c_int]
lib.agora_events_close.argtypes = [ctypes.c_void_p]; lib.agora_events_close.restype = None
lib.agora_file_offer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p,
                                 ctypes.c_char_p, ctypes.c_char_p]
for name in ('agora_file_accept', 'agora_file_decline', 'agora_file_cancel'):
    getattr(lib, name).argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p,
                                   ctypes.c_char_p]
lib.agora_set_root(root.encode())

h = None
for _ in range(120):
    h = lib.agora_events_open(b"at_to_extern")
    if h:
        break
    time.sleep(0.5)
if not h:
    print("no shim handle"); sys.exit(3)
N = 64
buf = (Ev * N)()

def drain():
    out = []
    n = lib.agora_events_poll(h, buf, N)
    for i in range(max(n, 0)):
        e = buf[i]
        if e.kind == EV_PEER:
            out.append(('peer', bytes(e.peer_uuid).hex(), e.in_group))
        elif e.kind == EV_FILE:
            out.append(('file', dict(id=e.file_xfer_id.decode(), state=STATES[e.file_state],
                                     out=bool(e.file_outgoing), size=e.file_size,
                                     done=e.file_done, path=e.file_path.decode(),
                                     reason=e.file_reason.decode(),
                                     peer=bytes(e.peer_uuid).hex())))
    return out

def retry(fn):
    rc = -2
    for _ in range(60):
        rc = fn()
        if rc != -2:
            break
        time.sleep(0.5)
    return rc

try:
    if verb == 'peer':
        end = time.time() + float(args[0])
        while time.time() < end:
            lib.agora_events_request_roster(h, b"extern_to_at")
            time.sleep(0.5)
            for kind, *rest in drain():
                if kind == 'peer' and rest[1]:
                    print(rest[0]); sys.exit(0)
        sys.exit(1)
    elif verb == 'offer':
        peer, xid, path = args
        print(retry(lambda: lib.agora_file_offer(h, b"extern_to_at", bytes.fromhex(peer),
                                                 xid.encode(), path.encode())))
    elif verb in ('accept', 'decline', 'cancel'):
        peer, xid = args
        fn = getattr(lib, 'agora_file_' + verb)
        print(retry(lambda: fn(h, b"extern_to_at", bytes.fromhex(peer), xid.encode())))
    elif verb == 'wait':
        xid, want, timeout = args[0], args[1], float(args[2])
        min_done = int(args[3]) if len(args) > 3 else 0
        end, last, pulled = time.time() + timeout, None, 0.0
        while time.time() < end:
            if time.time() - pulled > 2.0:
                lib.agora_events_request_roster(h, b"extern_to_at")
                pulled = time.time()
            for kind, *rest in drain():
                if kind == 'file' and rest[0]['id'] == xid:
                    last = rest[0]
            if last and last['state'] == want and last['done'] >= min_done:
                print(json.dumps(last)); sys.exit(0)
            if last and last['state'] != want and last['state'] not in ('offered', 'accepted'):
                print(json.dumps(last)); sys.exit(2)
            time.sleep(0.25)
        print(json.dumps(last)); sys.exit(1)
    else:
        print("unknown verb", verb); sys.exit(3)
finally:
    lib.agora_events_close(h)
PY

drive() { # root verb args...
  local root="$1"; shift
  python3 "$DRIVER" "$1" "$SHIM" "$root" "${@:2}"
}

field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
xid() { python3 -c 'import os; print(os.urandom(16).hex())'; }
mkfile() { head -c "$(( $2 * 1024 * 1024 ))" /dev/urandom >"$1"; }

# --------------------------------------------------------------------------- #
# 0. Two nodes, one group
# --------------------------------------------------------------------------- #
log "Starting n1 ($IP1) and n2 ($IP2)"
PID1="$(start_node "$NS1" "$ROOT1" n1)"
PID2="$(start_node "$NS2" "$ROOT2" n2)"
P2="$(drive "$ROOT1" peer "$WAIT")" || fail "n1 never saw n2 in its group within ${WAIT}s"
P1="$(drive "$ROOT2" peer "$WAIT")" || fail "n2 never saw n1 in its group within ${WAIT}s"
ok "n1 sees n2 (${P2:0:8}), n2 sees n1 (${P1:0:8}), in one group"

# Give a file, return n2's DONE event JSON; time it.
SRC="$RUN/src"; mkdir -p "$SRC"

# --------------------------------------------------------------------------- #
# 1. A big file arrives whole
# --------------------------------------------------------------------------- #
log "1. $SIZE_MB MB, end to end"
F1="$SRC/big.bin"; mkfile "$F1" "$SIZE_MB"
X1="$(xid)"
[ "$(drive "$ROOT1" offer "$P2" "$X1" "$F1")" = "0" ] || fail "n1 could not offer"
drive "$ROOT2" wait "$X1" offered 60 >/dev/null || fail "n2 never saw the offer"
T0=$(date +%s.%N)
[ "$(drive "$ROOT2" accept "$P1" "$X1")" = "0" ] || fail "n2 could not accept"
DONE="$(drive "$ROOT2" wait "$X1" done "$XFER_WAIT")" || fail "n2 did not finish: $DONE"
T1=$(date +%s.%N)
GOT="$(field "$DONE" path)"
[ "$(sha256sum <"$F1" | cut -d' ' -f1)" = "$(sha256sum <"$GOT" | cut -d' ' -f1)" ] \
  || fail "the received file differs from the source ($GOT)"
RATE=$(python3 -c "print(f'{$SIZE_MB / ($T1 - $T0):.2f}')")
ok "n2 holds $GOT, SHA-256 matches; $SIZE_MB MB in $(python3 -c "print(f'{$T1 - $T0:.1f}')") s = $RATE MB/s"
drive "$ROOT1" wait "$X1" done 60 >/dev/null || fail "n1 never saw done"
ok "n1 reports done"

# --------------------------------------------------------------------------- #
# 2. A restart resumes
# --------------------------------------------------------------------------- #
log "2. $RESUME_MB MB, receiver killed -9 a third of the way, then restarted"
F2="$SRC/resume.bin"; mkfile "$F2" "$RESUME_MB"
X2="$(xid)"
drive "$ROOT1" offer "$P2" "$X2" "$F2" >/dev/null
drive "$ROOT2" wait "$X2" offered 60 >/dev/null || fail "n2 never saw the second offer"
drive "$ROOT2" accept "$P1" "$X2" >/dev/null
THIRD=$(( RESUME_MB * 1024 * 1024 / 3 ))
MID="$(drive "$ROOT2" wait "$X2" accepted "$XFER_WAIT" "$THIRD")" \
  || fail "n2 never got a third of the way: $MID"
stop_node "$PID2" "$NS2"; PID2=""
log "   n2 killed holding $(field "$MID" done) bytes; restarting"
PID2="$(start_node "$NS2" "$ROOT2" n2)"
DONE="$(drive "$ROOT2" wait "$X2" done "$XFER_WAIT")" || fail "n2 did not resume: $DONE"
GOT="$(field "$DONE" path)"
[ "$(sha256sum <"$F2" | cut -d' ' -f1)" = "$(sha256sum <"$GOT" | cut -d' ' -f1)" ] \
  || fail "the resumed file differs from the source"
grep -q 'restored [0-9]* file transfer record' "$ROOT2/agorad.log" \
  || fail "n2 did not restore its transfer records"
ok "n2 resumed from its bitmap and finished; SHA-256 matches"

# --------------------------------------------------------------------------- #
# 3. A decline is final
# --------------------------------------------------------------------------- #
log "3. A decline"
F3="$SRC/small.txt"; echo "not this one" >"$F3"
X3="$(xid)"
drive "$ROOT1" offer "$P2" "$X3" "$F3" >/dev/null
drive "$ROOT2" wait "$X3" offered 60 >/dev/null || fail "n2 never saw the third offer"
drive "$ROOT2" decline "$P1" "$X3" >/dev/null
drive "$ROOT1" wait "$X3" declined 60 >/dev/null || fail "n1 never saw the decline"
ok "n1 sees declined"

# --------------------------------------------------------------------------- #
# 4. A cancel mid-transfer stops both sides
# --------------------------------------------------------------------------- #
log "4. $CANCEL_MB MB, cancelled by the sender under way"
F4="$SRC/cancel.bin"; mkfile "$F4" "$CANCEL_MB"
X4="$(xid)"
drive "$ROOT1" offer "$P2" "$X4" "$F4" >/dev/null
drive "$ROOT2" wait "$X4" offered 60 >/dev/null || fail "n2 never saw the fourth offer"
drive "$ROOT2" accept "$P1" "$X4" >/dev/null
drive "$ROOT2" wait "$X4" accepted "$XFER_WAIT" $(( CANCEL_MB * 1024 * 1024 / 10 )) >/dev/null \
  || fail "the fourth transfer never got under way"
drive "$ROOT1" cancel "$P2" "$X4" >/dev/null
drive "$ROOT2" wait "$X4" cancelled 60 >/dev/null || fail "n2 never saw the cancel"
sleep 1
LEFT=$(find "$ROOT2/var/agora/files/.partial" -name "*$X4*" 2>/dev/null | wc -l)
[ "$LEFT" = "0" ] || fail "n2 kept $LEFT partial file(s) after the cancel"
ok "n2 sees cancelled and kept no partial"

# --------------------------------------------------------------------------- #
# 5. The logs
# --------------------------------------------------------------------------- #
log "5. Logs"
BAD=0
for n in n1 n2; do
  L="$RUN/$n/agorad.log"
  printf '   %s: EAGAIN %s, refus %s, decrypt failed %s, file frames not sent %s\n' "$n" \
    "$(grep -c EAGAIN "$L")" "$(grep -ci 'refus' "$L")" \
    "$(grep -c 'decrypt failed' "$L")" "$(grep -c 'not an admitted peer' "$L")"
  if grep 'decrypt failed' "$L" | grep -q 'file'; then BAD=1; fi
done
[ "$BAD" = "0" ] || fail "a file frame failed to decrypt"
ok "no file frame failed to decrypt"

log "PASS — file sharing: $SIZE_MB MB at $RATE MB/s, resume, decline, cancel"
