#!/usr/bin/env bash
#
# device_cohort.sh — Phase 4 live check: one person, several devices
# (SOCIAL_APP_PLAN "Multi-device per person"; AT FIRST_CONTACT_PLAN Phase 4).
#
# Five real agorad nodes, each on its own point-to-point link to a router
# namespace that forwards unicast. Broadcast discovery stays on each link, so
# nobody meets anybody except through first contact, and every crossing below is
# the address book's doing, not a shared cohort's:
#
#   annphone, annlaptop, anntablet — one human's devices. Each is its own node,
#       with a device cert from ONE operator key the driver holds (the key never
#       enters a node). The tablet starts only after the other two are gone.
#   bob — Ann's contact.
#   eve — a device certified by a DIFFERENT operator: the pairing control.
#
# What it proves, in order:
#   1. ADDED AND VERIFIED. bob mints a link; annphone redeems it. Both screens
#      show the same safety number, and bob verifies by typing annphone's.
#      bob's book holds Ann, verified, with no further device yet.
#   2. PAIRING NEEDS ONE OPERATOR. eve redeems annphone's pairing link and is
#      refused not_sibling.
#   3. PAIRED, AND THE BOOK FOLLOWS. annlaptop redeems the same kind of link.
#      Both sides see SIBLING_PAIRED, and annlaptop's book now holds bob,
#      verified, provenance sibling.
#   4. THE CONTACT SEES ONE PERSON. annlaptop announces itself, and bob's node
#      files it under Ann (DEVICE_LINKED). bob's list says so too: one record,
#      followed by one DEVICE_LINKED for the laptop.
#   5. THE OTHER DEVICE IS REACHABLE AS ANN. annphone stops; a DM from bob to
#      annlaptop crosses.
#   6. LOST BOTH, RESTORED FROM A BACKUP. annphone's backup was sealed with a
#      generated passphrase (a 0600 file). Both of Ann's devices are gone. The
#      new anntablet, certified by the same operator, restores it: bob is back,
#      still verified, provenance backup.
#   7. AND bob's node files the tablet under Ann too: two further devices.
#
# NETNS ONLY. Requirements: root + iproute2, python3 (stdlib only), libsodium,
# and the built native layer (./build.sh).
#
# Usage:
#   sudo -E env "PATH=$PATH" ./test/cohort/device_cohort.sh
#   WAIT=180 KEEP=1 ./test/cohort/device_cohort.sh
#
# Env knobs: WAIT (per-phase timeout, default 120), SUBNET (default 10.9.10),
#   LOG_LEVEL (1 DEBUG, 2 INFO), KEEP=1.

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
LOG_LEVEL="${LOG_LEVEL:-2}"
SUBNET="${SUBNET:-10.9.10}"

NODES=(annphone annlaptop anntablet bob eve)
declare -A IP GW NS V VB ROOT PID
i=0
for n in "${NODES[@]}"; do
  GW[$n]="$SUBNET.$(( 4 * i + 1 ))"; IP[$n]="$SUBNET.$(( 4 * i + 2 ))"
  NS[$n]="agdv$n"; V[$n]="agdv${n:0:5}"; VB[$n]="agdv${n:0:5}r"
  i=$(( i + 1 ))
done
RTR=agdvrouter

RUN="${AGORA_COHORT_RUN:-$AGORA_DIR/.coh/dev-$$}"
for n in "${NODES[@]}"; do ROOT[$n]="$RUN/$n"; PID[$n]=""; mkdir -p "${ROOT[$n]}"; done
# The operators' keys: the driver signs device certs with them and they never
# enter a node, as tools/device_cert.py's keystore never does.
OP_ANN="$(python3 -c 'import os;print(os.urandom(32).hex())')"
OP_EVE="$(python3 -c 'import os;print(os.urandom(32).hex())')"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Preflight (the same checks as the sibling cohorts)
# --------------------------------------------------------------------------- #
if ! have python3; then err "python3 not found."; exit 1; fi
for f in "$AGORAD" "$SHIM" "$ATCORE/libautonomous_trust.so"; do
  if [ ! -e "$f" ]; then err "missing artifact: $f"; err "build first: (cd '$AGORA_DIR' && ./build.sh)"; exit 1; fi
done
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
  err "  Rebuild here, as your normal user: (cd '$AGORA_DIR' && AGORA_CLEAN=1 ./build.sh)"
  exit 1
fi
if ! python3 -c 'import ctypes.util,sys; sys.exit(0 if ctypes.util.find_library("sodium") else 1)'; then
  err "libsodium not found (the driver signs device certs with it)."; exit 1
fi
SUN_MAX=108
for n in "${NODES[@]}"; do
  need=$(( ${#ROOT[$n]} + 15 + 9 ))
  if [ "$need" -gt "$SUN_MAX" ]; then
    err "socket path too long: ${ROOT[$n]} needs $need bytes of $SUN_MAX."
    err "  Set AGORA_COHORT_RUN=/tmp/agc-\$\$"
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
# One link per node, to a router that forwards unicast and nothing else
# --------------------------------------------------------------------------- #
net_reset() {
  local n
  for n in "${NODES[@]}"; do ip netns del "${NS[$n]}" 2>/dev/null; done
  ip netns del "$RTR" 2>/dev/null
  return 0
}

net_up() {
  net_reset
  log "Creating a router and one /30 link per node on $SUBNET.0/24"
  ip netns add "$RTR" || return 1
  ip -n "$RTR" link set lo up || return 1
  # procfs, not sysctl: /usr/sbin is often missing from the PATH sudo carries.
  ip netns exec "$RTR" sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward' || return 1
  local n
  for n in "${NODES[@]}"; do
    ip netns add "${NS[$n]}" || return 1
    ip -n "${NS[$n]}" link set lo up || return 1
    ip link add "${V[$n]}" type veth peer name "${VB[$n]}" || return 1
    ip link set "${V[$n]}" netns "${NS[$n]}" || return 1
    ip link set "${VB[$n]}" netns "$RTR" || return 1
    ip -n "$RTR" addr add "${GW[$n]}/30" dev "${VB[$n]}" || return 1
    ip -n "$RTR" link set "${VB[$n]}" up || return 1
    ip -n "${NS[$n]}" addr add "${IP[$n]}/30" dev "${V[$n]}" || return 1
    ip -n "${NS[$n]}" link set "${V[$n]}" up || return 1
    ip -n "${NS[$n]}" route add default via "${GW[$n]}" || return 1
  done
  ip netns exec "${NS[bob]}" ping -c1 -W2 "${IP[annphone]}" >/dev/null 2>&1 \
    || { err "bob cannot reach annphone through the router"; return 1; }
  log "links ready; unicast routes between them, broadcast stays on each link"
}

node_start() { # name [extra env...]
  local n="$1"; shift
  ip netns exec "${NS[$n]}" env \
    AUTONOMOUS_TRUST_ROOT="${ROOT[$n]}" \
    AT_PEER_NAME="$n" AT_PEER_SEED="dev-$n-$$" \
    AT_FIRST_CONTACT=1 \
    "$@" \
    LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    "$AGORAD" extern_to_at at_to_extern "$LOG_LEVEL" \
    >"${ROOT[$n]}/agorad.log" 2>&1 &
  PID[$n]=$!
}

node_stop() { # name
  [ -z "${PID[$1]}" ] && return 0
  kill "${PID[$1]}" 2>/dev/null; sleep 1; kill -9 "${PID[$1]}" 2>/dev/null
  # Reap it here, so bash's "Killed" job notice does not land in the output.
  { wait "${PID[$1]}"; } 2>/dev/null
  PID[$1]=""
}

dump_logs() {
  local n
  for n in "${NODES[@]}"; do
    [ -f "${ROOT[$n]}/agorad.log" ] || continue
    echo "--- $n ---"
    grep -E "first contact|device|sibling|backup|Contacts|ERROR|WARN" "${ROOT[$n]}/agorad.log" | tail -n 25
  done
}

cleanup() {
  local rc="${1:-0}" n
  for n in "${NODES[@]}"; do node_stop "$n"; done
  if [ "${KEEP:-0}" = "1" ] || [ "$rc" != "0" ]; then
    log "Leaving the network and $RUN in place (exit $rc). Tear down with:"
    for n in "${NODES[@]}"; do log "  ip netns del ${NS[$n]}"; done
    log "  ip netns del $RTR"
    return
  fi
  net_reset
  rm -rf "$RUN"
}
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT TERM

net_up || exit 1

# --------------------------------------------------------------------------- #
# The app-side driver. Ev, connect(), drain() and open_lib() are SPLICED
# VERBATIM out of hub_cohort.sh; the address-book verbs are new.
# --------------------------------------------------------------------------- #
DRIVER="$RUN/driver.py"
cat >"$DRIVER" <<'PY'
import ctypes, json, os, sys, time

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

# ABI guard: MUST equal sizeof(agora_event_t) in at_agora_shim.h. A silent drift
# here would decode every field past the drift point as garbage.
assert ctypes.sizeof(Ev) == 45752, f"Ev size {ctypes.sizeof(Ev)} != 45752 (ABI drift)"

EV_PEER, EV_POST, EV_POLICY, EV_LABEL = 1, 9, 16, 17


def connect(lib, timeout):
    """Open the app-event channel, retrying until the daemon binds its queue."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        h = lib.agora_events_open(b"at_to_extern")
        if h:
            return h
        time.sleep(0.5)
    return None


def drain(lib, h, buf, cap, deadline):
    """Poll until a batch comes back short (a poll returns at most 16), copying
    each event out of the reused buffer."""
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


def open_lib(shim, root):
    lib = ctypes.CDLL(shim)
    vp, cp = ctypes.c_void_p, ctypes.c_char_p
    lib.agora_set_root.argtypes = [cp]; lib.agora_set_root.restype = None
    lib.agora_events_open.argtypes = [cp]; lib.agora_events_open.restype = vp
    lib.agora_events_request_roster.argtypes = [vp, cp]
    lib.agora_events_request_roster.restype = ctypes.c_int
    lib.agora_events_poll.argtypes = [vp, ctypes.POINTER(Ev), ctypes.c_int]
    lib.agora_events_poll.restype = ctypes.c_int
    lib.agora_events_close.argtypes = [vp]; lib.agora_events_close.restype = None
    lib.agora_publish_post.argtypes = [vp, cp, cp, ctypes.c_int]
    lib.agora_publish_post.restype = ctypes.c_int
    lib.agora_publish_post_scoped.argtypes = [vp, cp, cp, ctypes.c_int, cp, cp]
    lib.agora_publish_post_scoped.restype = ctypes.c_int
    lib.agora_follow_community.argtypes = [vp, cp, cp, cp, ctypes.c_int64]
    lib.agora_follow_community.restype = ctypes.c_int
    lib.agora_publish_post_label.argtypes = [vp, cp, cp, cp, cp, ctypes.c_int64]
    lib.agora_publish_post_label.restype = ctypes.c_int
    lib.agora_set_root(root.encode())
    return lib


import ctypes.util  # cert minting finds libsodium

EV_CONTACT, EV_BACKUP, EV_DM = 19, 20, 8
FC_INVITATION, FC_REFUSED, FC_ESTABLISHED = 1000, 1002, 1003
FC_CONTACT, FC_CONTACTS_DONE, FC_SAFETY_NUMBER, FC_VERIFIED = 1004, 1005, 1006, 1007
FC_DEVICE_LINKED, FC_SIBLING_PAIRED = 1018, 1019
BACKUP_WRITTEN, BACKUP_RESTORED, BACKUP_REFUSED = 1031, 1032, 1033
REASON_NOT_SIBLING = 10
PROVENANCE = ["in_person", "token", "directory", "sibling", "area", "backup"]
Q = b"extern_to_at"


def fc_lib(shim, root):
    lib = open_lib(shim, root)
    vp, cp, u8p = ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint8)
    lib.agora_fc_invite.argtypes = [vp, cp, cp, ctypes.c_long]
    lib.agora_fc_pair_invite.argtypes = [vp, cp, cp, ctypes.c_long]
    lib.agora_fc_initiate.argtypes = [vp, cp, cp, cp, ctypes.c_int, cp]
    lib.agora_fc_list.argtypes = [vp, cp, cp]
    lib.agora_fc_safety_number.argtypes = [vp, cp, cp, u8p]
    lib.agora_fc_verify.argtypes = [vp, cp, cp, u8p, cp, ctypes.c_int]
    lib.agora_backup_export.argtypes = [vp, cp, cp, cp, cp]
    lib.agora_backup_import.argtypes = [vp, cp, cp, cp, cp]
    lib.agora_send_dm.argtypes = [vp, cp, u8p, cp]
    return lib


def _u(hexs):
    return (ctypes.c_uint8 * 16)(*bytes.fromhex(hexs))


def _take_events(lib, h, timeout, want):
    """Poll until want(ev) returns non-None; that value, or None at the deadline."""
    cap = 64
    buf = (Ev * cap)()
    deadline = time.time() + timeout
    while time.time() < deadline:
        for ev in drain(lib, h, buf, cap, deadline):
            got = want(ev)
            if got is not None:
                return got
        time.sleep(0.3)
    return None


def _session(shim, root, timeout):
    lib = fc_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("no app-event channel", file=sys.stderr)
    return lib, h


def identity(root):
    return json.load(open(os.path.join(root, "etc", "at", "identity.cfg.json")))


def cmd_cert(root, operator_seed_hex):
    """Issue the node under `root` a device cert from the operator seed, as
    tools/device_cert.py does (domain at-device-v1|, compact body), and install
    it. The operator key stays here."""
    na = ctypes.CDLL(ctypes.util.find_library("sodium"))
    if na.sodium_init() < 0:
        return 3
    def keypair(seed):
        pk, sk = ctypes.create_string_buffer(32), ctypes.create_string_buffer(64)
        if na.crypto_sign_seed_keypair(pk, sk, bytes.fromhex(seed)) != 0:
            raise RuntimeError("keypair")
        return pk.raw, sk.raw
    ident = identity(root)
    node_pk, _ = keypair(ident["signature"]["hex_seed"])
    op_pk, op_sk = keypair(operator_seed_hex)
    body = json.dumps({"v": 1, "typename": "at-device-cert", "operator": op_pk.hex(),
                       "uuid": ident["uuid"].lower(), "key": node_pk.hex(),
                       "issued_at": int(time.time())},
                      separators=(",", ":"), ensure_ascii=True)
    msg = b"at-device-v1|" + body.encode()
    sig = ctypes.create_string_buffer(64)
    if na.crypto_sign_detached(sig, None, msg, ctypes.c_ulonglong(len(msg)), op_sk) != 0:
        return 3
    path = os.path.join(root, "etc", "at", "device_cert.cfg.json")
    json.dump({"body": body, "sig": sig.raw.hex()}, open(path, "w"))
    print(f"cert for {ident['uuid'][:8]} from operator {op_pk.hex()[:8]}", file=sys.stderr)
    return 0


def cmd_mint(shim, root, pair, out, timeout):
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    # A ref of this request's own: an event an earlier link of ours caused (a
    # refusal of someone who redeemed it) carries that link's ref, and with a
    # fixed one it read as this mint's answer (dev-4032840: phase 2's
    # not_sibling refusal, held for the app, answered phase 3's mint).
    ref = (b"pair-" if pair else b"invite-") + os.urandom(4).hex().encode()
    fn = lib.agora_fc_pair_invite if pair else lib.agora_fc_invite
    if fn(h, Q, ref, -1) != 0:
        return 4
    got = _take_events(lib, h, timeout, lambda ev: (ev.fc_kind, ev.fc_blob.decode(), ev.fc_count)
                       if ev.kind == EV_CONTACT and ev.fc_ref == ref
                       and ev.fc_kind in (FC_INVITATION, FC_REFUSED) else None)
    lib.agora_events_close(h)
    if got is None or got[0] != FC_INVITATION or not got[1]:
        print(f"mint: no link ({got})", file=sys.stderr)
        return 5
    open(out, "w").write(got[1])
    return 0


def cmd_redeem(shim, root, link_path, in_person, expect, timeout):
    """Redeem a link and wait for the outcome `expect`: established (a contact),
    paired (a pairing), or not_sibling (a pairing refused)."""
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    link = open(link_path).read().strip().encode()
    ref = b"redeem-" + os.urandom(4).hex().encode()   # this request's own; see cmd_mint
    if lib.agora_fc_initiate(h, Q, ref, link, int(in_person), None) != 0:
        return 4
    def outcome(ev):
        if ev.kind != EV_CONTACT:
            return None
        if ev.fc_kind == FC_SIBLING_PAIRED:
            return "paired"
        if ev.fc_kind == FC_ESTABLISHED and ev.fc_ref == ref:
            return "established"
        if ev.fc_kind == FC_REFUSED and ev.fc_ref == ref:
            return "not_sibling" if ev.fc_count == REASON_NOT_SIBLING else f"refused:{ev.fc_count}"
        return None
    got = _take_events(lib, h, timeout, outcome)
    lib.agora_events_close(h)
    print(f"redeem: {got}")
    return 0 if got == expect else 5


def cmd_await_paired(shim, root, timeout):
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    got = _take_events(lib, h, timeout, lambda ev: bytes(ev.peer_uuid).hex()
                       if ev.kind == EV_CONTACT and ev.fc_kind == FC_SIBLING_PAIRED else None)
    lib.agora_events_close(h)
    print(f"paired with: {got}")
    return 0 if got else 5


def cmd_safety(shim, root, peer_hex, out, timeout):
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    lib.agora_fc_safety_number(h, Q, b"sn", _u(peer_hex))
    got = _take_events(lib, h, timeout, lambda ev: ev.fc_safety_number.decode()
                       if ev.kind == EV_CONTACT and ev.fc_kind == FC_SAFETY_NUMBER else None)
    lib.agora_events_close(h)
    if not got:
        return 5
    open(out, "w").write(got)
    return 0


def cmd_verify(shim, root, peer_hex, digits_path, timeout):
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    digits = open(digits_path).read().strip().encode()
    ref = b"verify-" + os.urandom(4).hex().encode()   # this request's own; see cmd_mint
    lib.agora_fc_verify(h, Q, ref, _u(peer_hex), digits, 0)
    got = _take_events(lib, h, timeout, lambda ev: ev.fc_kind
                       if ev.kind == EV_CONTACT and ev.fc_ref == ref
                       and ev.fc_kind in (FC_VERIFIED, FC_REFUSED) else None)
    lib.agora_events_close(h)
    return 0 if got == FC_VERIFIED else 5


def cmd_list(shim, root, out, timeout):
    """The address book as the app rebuilds it: each record, then the further
    devices the list files under it."""
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    lib.agora_fc_list(h, Q, b"book")
    book, order = {}, []
    def take(ev):
        if ev.kind != EV_CONTACT or ev.fc_ref != b"book":
            return None
        who = bytes(ev.peer_uuid).hex()
        if ev.fc_kind == FC_CONTACT:
            book[who] = {"uuid": who, "verified": bool(ev.fc_verified),
                         "provenance": PROVENANCE[ev.fc_provenance]
                         if 0 <= ev.fc_provenance < len(PROVENANCE) else ev.fc_provenance,
                         "devices": []}
            order.append(who)
        elif ev.fc_kind == FC_DEVICE_LINKED and who in book:
            book[who]["devices"].append(bytes(ev.fc_device_uuid).hex())
        elif ev.fc_kind == FC_CONTACTS_DONE:
            return ev.fc_count
        return None
    n = _take_events(lib, h, timeout, take)
    lib.agora_events_close(h)
    if n is None:
        return 5
    json.dump([book[u] for u in order], open(out, "w"))
    print(f"list: {n} record(s): {[(b['uuid'][:8], b['verified'], b['provenance'], [d[:8] for d in b['devices']]) for b in (book[u] for u in order)]}")
    return 0


def cmd_await_linked(shim, root, device_hex, timeout):
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    got = _take_events(lib, h, timeout, lambda ev: bytes(ev.peer_uuid).hex()
                       if ev.kind == EV_CONTACT and ev.fc_kind == FC_DEVICE_LINKED
                       and bytes(ev.fc_device_uuid).hex() == device_hex else None)
    lib.agora_events_close(h)
    print(f"linked {device_hex[:8]} under {got[:8] if got else None}")
    return 0 if got else 5


def cmd_backup_export(shim, root, path, pass_out, timeout):
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    lib.agora_backup_export(h, Q, b"backup", path.encode(), None)
    got = _take_events(lib, h, timeout, lambda ev: (ev.fc_kind, ev.backup_passphrase.decode(),
                                                    ev.backup_contacts, ev.fc_reason.decode())
                       if ev.kind == EV_BACKUP else None)
    lib.agora_events_close(h)
    print(f"backup: {got and (got[0], got[2], got[3])}")
    if got is None or got[0] != BACKUP_WRITTEN or not got[1]:
        return 5
    open(pass_out, "w").write(got[1])
    return 0


def cmd_backup_import(shim, root, path, pass_path, timeout):
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    lib.agora_backup_import(h, Q, b"restore", path.encode(), open(pass_path).read().strip().encode())
    got = _take_events(lib, h, timeout, lambda ev: (ev.fc_kind, ev.backup_added, ev.backup_contacts,
                                                    ev.backup_siblings, ev.fc_reason.decode())
                       if ev.kind == EV_BACKUP else None)
    lib.agora_events_close(h)
    print(f"restore: {got}")
    return 0 if got and got[0] == BACKUP_RESTORED else 5


def cmd_dm(shim, root, uuid_hex, text, timeout):
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    rc = lib.agora_send_dm(h, Q, _u(uuid_hex), text.encode())
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_await_dm(shim, root, text, timeout):
    lib, h = _session(shim, root, timeout)
    if not h:
        return 2
    got = _take_events(lib, h, timeout, lambda ev: True
                       if ev.kind == EV_DM and ev.dm_text.decode() == text else None)
    lib.agora_events_close(h)
    return 0 if got else 5


def main(a):
    v = a[1]
    if v == "uuid":
        print(identity(a[2])["uuid"].replace("-", "").lower())
        return 0
    if v == "cert":
        return cmd_cert(a[2], a[3])
    shim, root = a[2], a[3]
    t = float(a[-1])
    if v == "invite":
        return cmd_mint(shim, root, False, a[4], t)
    if v == "pair-invite":
        return cmd_mint(shim, root, True, a[4], t)
    if v == "redeem":
        return cmd_redeem(shim, root, a[4], a[5] == "1", a[6], t)
    if v == "await-paired":
        return cmd_await_paired(shim, root, t)
    if v == "safety":
        return cmd_safety(shim, root, a[4], a[5], t)
    if v == "verify":
        return cmd_verify(shim, root, a[4], a[5], t)
    if v == "list":
        return cmd_list(shim, root, a[4], t)
    if v == "await-linked":
        return cmd_await_linked(shim, root, a[4], t)
    if v == "backup-export":
        return cmd_backup_export(shim, root, a[4], a[5], t)
    if v == "backup-import":
        return cmd_backup_import(shim, root, a[4], a[5], t)
    if v == "dm":
        return cmd_dm(shim, root, a[4], a[5], t)
    if v == "await-dm":
        return cmd_await_dm(shim, root, a[4], t)
    print(f"unknown verb {v}", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

if ! python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$DRIVER"; then
  err "the embedded driver does not compile — refusing to start any node."
  exit 1
fi

drive() { # node verb args...
  local n="$1"; shift
  local verb="$1"; shift
  LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    python3 "$DRIVER" "$verb" "$SHIM" "${ROOT[$n]}" "$@"
}
tool() { # verb args...  (no node, no queue)
  python3 "$DRIVER" "$@"
}
saw() { grep -q "$2" "${ROOT[$1]}/agorad.log" 2>/dev/null; }
fail() { err "FAIL ($1) — $2"; dump_logs; exit 1; }
await_identity() { # node
  local deadline=$(( SECONDS + WAIT ))
  until [ -s "${ROOT[$1]}/etc/at/identity.cfg.json" ] || [ "$SECONDS" -ge "$deadline" ]; do sleep 1; done
  [ -s "${ROOT[$1]}/etc/at/identity.cfg.json" ]
}
start_certified() { # node operator-seed
  node_start "$1"; sleep 2
  kill -0 "${PID[$1]}" 2>/dev/null || fail "start" "$1 died at start"
  await_identity "$1" || fail "start" "$1 wrote no identity"
  tool cert "${ROOT[$1]}" "$2" || fail "start" "could not issue $1 a device cert"
}
check() { # phase json-file python-assertion-expr  (b = the list)
  python3 - "$2" "$3" <<'CHK' || fail "$1" "unexpected address book: $(cat "$2")"
import json, sys
b = json.load(open(sys.argv[1]))
assert eval(sys.argv[2], {"b": b, "env": __import__("os").environ}), b
CHK
}

# --------------------------------------------------------------------------- #
# Phase 1 — added and verified
# --------------------------------------------------------------------------- #
log "Phase 1: bob and annphone start; annphone (certified) redeems bob's link"
node_start bob; sleep 2
kill -0 "${PID[bob]}" 2>/dev/null || fail "phase 1" "bob died at start"
start_certified annphone "$OP_ANN"
await_identity bob || fail "phase 1" "bob wrote no identity"
BOB="$(tool uuid "${ROOT[bob]}")"; PHONE="$(tool uuid "${ROOT[annphone]}")"
drive bob invite "$RUN/bob.link" "$WAIT" || fail "phase 1" "bob could not mint a link"
drive annphone redeem "$RUN/bob.link" 1 established "$WAIT" || fail "phase 1" "annphone could not add bob"
drive bob safety "$PHONE" "$RUN/bob.sn" "$WAIT" || fail "phase 1" "bob's node showed no safety number"
drive annphone safety "$BOB" "$RUN/ann.sn" "$WAIT" || fail "phase 1" "annphone's node showed no safety number"
cmp -s "$RUN/bob.sn" "$RUN/ann.sn" || fail "phase 1" "the two screens show different numbers"
drive bob verify "$PHONE" "$RUN/ann.sn" "$WAIT" || fail "phase 1" "bob could not verify by typing annphone's number"
drive bob list "$RUN/bob-1.json" "$WAIT" || fail "phase 1" "bob's list never finished"
PHONE="$PHONE" check "phase 1" "$RUN/bob-1.json" \
  'len(b)==1 and b[0]["uuid"]==env["PHONE"] and b[0]["verified"] and b[0]["devices"]==[]'
ok "phase 1: added, the same safety number on both screens, and verified"

# --------------------------------------------------------------------------- #
# Phase 2 — pairing needs one operator
# --------------------------------------------------------------------------- #
log "Phase 2: eve (another operator's device) redeems annphone's pairing link"
start_certified eve "$OP_EVE"
drive annphone pair-invite "$RUN/pair-eve.link" "$WAIT" || fail "phase 2" "annphone could not mint a pairing link"
drive eve redeem "$RUN/pair-eve.link" 0 not_sibling "$WAIT" || fail "phase 2" "eve was not refused not_sibling"
node_stop eve
ok "phase 2: refused not_sibling — a pairing link alone pairs nothing"

# --------------------------------------------------------------------------- #
# Phase 3 — paired, and the book follows
# --------------------------------------------------------------------------- #
log "Phase 3: annlaptop (same operator) pairs with annphone"
start_certified annlaptop "$OP_ANN"
LAPTOP="$(tool uuid "${ROOT[annlaptop]}")"
drive annphone pair-invite "$RUN/pair.link" "$WAIT" || fail "phase 3" "annphone could not mint a pairing link"
# bob listens from before the pairing: annlaptop announces itself to him as
# soon as the synced book names him.
drive bob await-linked "$LAPTOP" "$WAIT" >"$RUN/bob-linked-laptop.txt" 2>&1 &
BL=$!
drive annphone await-paired "$WAIT" & AP=$!
sleep 2
drive annlaptop redeem "$RUN/pair.link" 0 paired "$WAIT" || fail "phase 3" "annlaptop did not pair"
wait "$AP" || fail "phase 3" "annphone never saw the pairing"
deadline=$(( SECONDS + WAIT ))
until drive annlaptop list "$RUN/laptop.json" 10 >/dev/null 2>&1 \
      && BOB="$BOB" python3 -c 'import json,os,sys;b=json.load(open(sys.argv[1]));sys.exit(0 if any(r["uuid"]==os.environ["BOB"] for r in b) else 1)' "$RUN/laptop.json" \
      || [ "$SECONDS" -ge "$deadline" ]; do sleep 2; done
BOB="$BOB" check "phase 3" "$RUN/laptop.json" \
  'any(r["uuid"]==env["BOB"] and r["verified"] and r["provenance"]=="sibling" for r in b)'
ok "phase 3: paired both ways, and annlaptop's book holds bob, verified, from its sibling"

# --------------------------------------------------------------------------- #
# Phase 4 — the contact sees one person
# --------------------------------------------------------------------------- #
log "Phase 4: bob's node files annlaptop under Ann"
wait "$BL" || { cat "$RUN/bob-linked-laptop.txt"; fail "phase 4" "bob never got DEVICE_LINKED for annlaptop"; }
cat "$RUN/bob-linked-laptop.txt"
drive bob list "$RUN/bob-4.json" "$WAIT" || fail "phase 4" "bob's list never finished"
PHONE="$PHONE" LAPTOP="$LAPTOP" check "phase 4" "$RUN/bob-4.json" \
  'len(b)==1 and b[0]["uuid"]==env["PHONE"] and b[0]["devices"]==[env["LAPTOP"]]'
ok "phase 4: one record for Ann, and the list names the laptop under it"

# --------------------------------------------------------------------------- #
# Phase 5 — the other device is reachable as Ann
# --------------------------------------------------------------------------- #
log "Phase 5: annphone makes a backup, then stops; bob DMs annlaptop"
BACKUP="$RUN/annphone/ann.atbk"
drive annphone backup-export "$BACKUP" "$RUN/ann.pass" "$WAIT" || fail "phase 5" "annphone could not write a backup"
[ "$(stat -c %a "$BACKUP")" = "600" ] || fail "phase 5" "the backup is not mode 0600"
node_stop annphone
drive annlaptop await-dm "hi Ann, on whichever device" "$WAIT" &
DM=$!
sleep 2
drive bob dm "$LAPTOP" "hi Ann, on whichever device" "$WAIT" || fail "phase 5" "bob could not send the DM"
wait "$DM" || fail "phase 5" "the DM never reached annlaptop"
ok "phase 5: backup sealed (0600, generated passphrase); with the phone gone, the laptop got the DM"

# --------------------------------------------------------------------------- #
# Phase 6 — lost both, restored from the backup
# --------------------------------------------------------------------------- #
log "Phase 6: annlaptop stops too; a new anntablet restores the backup"
node_stop annlaptop
start_certified anntablet "$OP_ANN"
TABLET="$(tool uuid "${ROOT[anntablet]}")"
drive bob await-linked "$TABLET" "$WAIT" >"$RUN/bob-linked-tablet.txt" 2>&1 &
BT=$!
sleep 2
drive anntablet backup-import "$BACKUP" "$RUN/ann.pass" "$WAIT" || fail "phase 6" "anntablet could not restore the backup"
drive anntablet list "$RUN/tablet.json" "$WAIT" || fail "phase 6" "anntablet's list never finished"
BOB="$BOB" check "phase 6" "$RUN/tablet.json" \
  'any(r["uuid"]==env["BOB"] and r["verified"] and r["provenance"]=="backup" for r in b)'
ok "phase 6: with no old device present, bob is back on the tablet, still verified"

# --------------------------------------------------------------------------- #
# Phase 7 — and the contact files the tablet under Ann too
# --------------------------------------------------------------------------- #
log "Phase 7: bob's node files anntablet under Ann"
wait "$BT" || { cat "$RUN/bob-linked-tablet.txt"; fail "phase 7" "bob never got DEVICE_LINKED for anntablet"; }
cat "$RUN/bob-linked-tablet.txt"
drive bob list "$RUN/bob-7.json" "$WAIT" || fail "phase 7" "bob's list never finished"
PHONE="$PHONE" LAPTOP="$LAPTOP" TABLET="$TABLET" check "phase 7" "$RUN/bob-7.json" \
  'len(b)==1 and b[0]["uuid"]==env["PHONE"] and b[0]["devices"]==[env["LAPTOP"], env["TABLET"]]'
ok "phase 7: Ann is one record with three devices"

log "PASS: device_cohort — one person, three devices, one address book"
