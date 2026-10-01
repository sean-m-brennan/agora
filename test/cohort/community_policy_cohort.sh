#!/usr/bin/env bash
#
# community_policy_cohort.sh — Phase 4 live check: a community's content policy,
# set by its roll and carried by its members, moderates the feed of a reader who
# follows it, and only of a reader who follows it (Ethne D37).
#
# Four real agorad nodes on one virtual L2 segment (bridge + netns), driven
# through the real app-event queues. The driver plays the app: it holds the
# polity's charter log, mints and verifies every artifact through the REAL
# Ethne cdylib, and computes every verdict with ethne_content_policy_verdict
# over the bytes that ARRIVED — the same call the Flutter app makes.
#
#   keeper — a member holding the polity's ROOT key: it mints the policy and
#            carries it. It also authors the community posts.
#   mod    — a member the roll seats as Moderator; it labels posts.
#   cal    — a neighbour who hears the policy, verifies it, and follows it.
#   dee    — a neighbour who hears it and does not follow: the control.
#
# What it proves, in order:
#   1. Discovery, one node at a time, and a live group channel.
#   2. THE POLICY IS CARRIED AND FOLLOWED. keeper follows the policy its log
#      mints; cal and dee both receive it (kind 16) and it VERIFIES out of the
#      received bytes; cal follows, dee does not.
#   3. THE POLICY MODERATES ONLY ITS FOLLOWERS. keeper posts three times in the
#      community's name, the first labelled "spoiler". Under cal's policy the
#      first is behind a warning, the second shows, the third is over the daily
#      cap of 2 and hidden. dee receives all three, scope intact, unmoderated.
#   4. A MODERATOR'S LABEL. mod labels the second post "nsfw": cal receives the
#      label (kind 17) and the post is now hidden, the reason naming mod; dee,
#      who does not follow, receives NO label at all (the follow gate).
#   5. LOOSENING NEEDS MORE THAN A MAJORITY. Removing the cap is refused at 2
#      of 3 deciders and accepted at 3; the newer policy is carried, replaces
#      cal's held one, and the third post now shows.
#   6. A REVOKED MODERATOR STOPS COUNTING. The roll unseats mod; the next
#      policy lists no moderators; mod's label on the first post reaches cal
#      and is refused, so that post is still only behind its warning.
#
# WHAT THIS DELIBERATELY DOES NOT TEST: a label made across a partition and
# backfilled after the heal (conformance pins it: post-label-backfill-*,
# post-digest-label-*), and the reader's own "apply this policy" switch, which
# is app-local and pinned by test/community_policy_test.dart.
#
# NETNS ONLY. Requirements: root + iproute2, python3, and the built native
# layer + ethne cdylib (./build.sh).
#
# Usage:
#   sudo -E env "PATH=$PATH" ./test/cohort/community_policy_cohort.sh
#   WAIT=120 KEEP=1 ./test/cohort/community_policy_cohort.sh
#
# Env knobs: WAIT (per-phase timeout, default 120), GATE_WINDOW (how long dee
#   must stay silent, default 30), POLICY_SEC (policy re-carry interval, default
#   10), SUBNET (default 10.9.7), LOG_LEVEL (1 DEBUG, 2 INFO), KEEP=1.

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

WAIT="${WAIT:-120}"
GATE_WINDOW="${GATE_WINDOW:-30}"
POLICY_SEC="${POLICY_SEC:-10}"
LOG_LEVEL="${LOG_LEVEL:-2}"
SUBNET="${SUBNET:-10.9.7}"
GEO="${GEO:-u4pruy}"
PREFIX=24

NODES=(keeper mod cal dee)
declare -A IP NS V VB ROOT PID
i=11
for n in "${NODES[@]}"; do
  IP[$n]="$SUBNET.$i"; NS[$n]="agcp$n"; V[$n]="agc${n:0:3}"; VB[$n]="agc${n:0:3}b"
  i=$(( i + 1 ))
done
BR=agbr7

RUN="${AGORA_COHORT_RUN:-$AGORA_DIR/.coh/comm-$$}"
for n in "${NODES[@]}"; do ROOT[$n]="$RUN/$n"; PID[$n]=""; mkdir -p "${ROOT[$n]}"; done
STATE="$RUN/polity.json"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Preflight (the same checks as the sibling cohorts)
# --------------------------------------------------------------------------- #
if ! have python3; then err "python3 not found."; exit 1; fi
for f in "$AGORAD" "$SHIM" "$ATCORE/libautonomous_trust.so" "$ETHNE"; do
  if [ ! -e "$f" ]; then err "missing artifact: $f"; err "build first: (cd '$AGORA_DIR' && ./build.sh)"; exit 1; fi
done
_unrunnable=""
for f in "$AGORAD" "$SHIM" "$ATCORE/libautonomous_trust.so" "$ETHNE"; do
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
# Network and node primitives
# --------------------------------------------------------------------------- #
net_reset() {
  local n
  for n in "${NODES[@]}"; do
    ip netns del "${NS[$n]}" 2>/dev/null
    ip link del "${VB[$n]}" 2>/dev/null
  done
  ip link del "$BR" 2>/dev/null
  return 0
}

net_up() {
  net_reset
  log "Creating bridge $BR and ${#NODES[@]} namespaces on $SUBNET.0/$PREFIX"
  ip link add "$BR" type bridge && ip link set "$BR" up || return 1
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
    ip netns exec "${NS[keeper]}" ping -c1 -W2 "${IP[$n]}" >/dev/null 2>&1 \
      || { err "no L2 path from keeper to $n"; return 1; }
  done
  log "L2 segment ready"
}

node_start() { # name
  local n="$1"
  ip netns exec "${NS[$n]}" env \
    AUTONOMOUS_TRUST_ROOT="${ROOT[$n]}" \
    AT_PEER_NAME="$n" AT_PEER_SEED="community-$n" \
    AT_OWN_GEOHASH="$GEO" \
    AT_SOCIAL_POLICY_SEC="$POLICY_SEC" \
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
    log "  ip link del $BR"
    return
  fi
  net_reset
  rm -rf "$RUN"
}
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT TERM

net_up || exit 1

# --------------------------------------------------------------------------- #
# The app-side driver. The ctypes Ev mirror, connect() and drain() are SPLICED
# VERBATIM out of partition_cohort.sh when this file was written (the Ev mirror
# carries the ABI guard). The Ethne calls and the community verbs are new.
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
    ]

# ABI guard: MUST equal sizeof(agora_event_t) in at_agora_shim.h. A silent drift
# here would decode every field past the drift point as garbage.
assert ctypes.sizeof(Ev) == 41296, f"Ev size {ctypes.sizeof(Ev)} != 41296 (ABI drift)"

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


class Ethne:
    """The Ethne cdylib, as the app calls it."""

    def __init__(self):
        lib = ctypes.CDLL(os.environ["ETHNE"])
        vp, cp = ctypes.c_void_p, ctypes.c_char_p
        out = ctypes.POINTER(ctypes.c_char_p)
        lib.ethne_last_error.restype = cp
        lib.ethne_string_free.argtypes = [ctypes.c_void_p]
        lib.ethne_keypair_generate.argtypes = [out]
        lib.ethne_archive_new.restype = vp
        lib.ethne_archive_load_json.argtypes = [cp]; lib.ethne_archive_load_json.restype = vp
        lib.ethne_archive_dump_json.argtypes = [vp, out]
        lib.ethne_verify.argtypes = [vp]
        for fn in ("ethne_found_polity", "ethne_amend_content_policy",
                   "ethne_confer_office", "ethne_revoke_office"):
            getattr(lib, fn).argtypes = [vp, cp]
        lib.ethne_content_policy_sign.argtypes = [vp, cp, out]
        for fn in ("ethne_content_policy_verify", "ethne_post_label_sign",
                   "ethne_content_policy_verdict"):
            getattr(lib, fn).argtypes = [cp, out]
        self.lib = lib

    def err(self):
        return (self.lib.ethne_last_error() or b"").decode(errors="replace")

    def _take(self, rc, out):
        if rc != 0:
            raise RuntimeError(self.err())
        s = ctypes.cast(out, ctypes.c_char_p).value.decode()
        self.lib.ethne_string_free(out)
        return s

    def call_out(self, fn, *args):
        out = ctypes.c_char_p()
        rc = getattr(self.lib, fn)(*args, ctypes.byref(out))
        return self._take(rc, out)

    def keypair(self):
        return json.loads(self.call_out("ethne_keypair_generate"))

    def spec(self, fn, arc, spec):
        rc = getattr(self.lib, fn)(arc, json.dumps(spec).encode())
        if rc != 0:
            raise RuntimeError(f"{fn}: {self.err()}")

    def verify_policy(self, bundle):
        try:
            return json.loads(self.call_out("ethne_content_policy_verify", bundle.encode()))
        except RuntimeError:
            return None


def signer(kp):
    return {"did": kp["did"], "priv": kp["priv"]}


def load_state(path, e):
    st = json.load(open(path))
    arc = e.lib.ethne_archive_load_json(json.dumps(st["archive"]).encode())
    if not arc:
        raise RuntimeError("could not reload the charter log: " + e.err())
    return st, arc


def save_state(path, st, arc, e):
    st["archive"] = json.loads(e.call_out("ethne_archive_dump_json", arc))
    json.dump(st, open(path, "w"))


POLICY_V1 = {"operator_bound_required": False, "min_tier": 0, "daily_post_cap": 2,
             "labels": {"spoiler": "Warn", "nsfw": "Hide"}}


def cmd_mint(state):
    """Found a three-member polity (keeper, mod, and a third founder no node
    holds), set policy v1 at a majority, seat mod as Moderator."""
    e = Ethne()
    root = e.keypair()
    f = [e.keypair() for _ in range(3)]
    arc = e.lib.ethne_archive_new()
    e.spec("ethne_found_polity", arc, {
        "polity_did": root["did"], "name": "Riverside Commons",
        "statement": "Neighbours who garden.",
        "members": [k["did"] for k in f], "ratifiers": [signer(k) for k in f]})
    e.spec("ethne_amend_content_policy", arc, {
        "polity_did": root["did"], "policy": POLICY_V1, "rationale": "first policy",
        "deciders": [signer(f[0]), signer(f[1])]})
    e.spec("ethne_confer_office", arc, {
        "polity_did": root["did"], "office": "Moderator", "holder_did": f[1]["did"],
        "holder_priv": f[1]["priv"], "deciders": [signer(f[0]), signer(f[2])]})
    if e.lib.ethne_verify(arc) != 0:
        print("mint: the log does not verify: " + e.err(), file=sys.stderr)
        return 3
    st = {"root": root, "founders": f}
    save_state(state, st, arc, e)
    print(root["did"])
    print(f"moderator {f[1]['did']}", file=sys.stderr)
    return 0


def cmd_sign(state, out_path):
    e = Ethne()
    st, arc = load_state(state, e)
    bundle = e.call_out("ethne_content_policy_sign", arc, json.dumps(
        {"polity_did": st["root"]["did"], "root_priv": st["root"]["priv"]}).encode())
    read = e.verify_policy(bundle)
    if read is None:
        print("sign: the minted policy does not verify", file=sys.stderr)
        return 3
    open(out_path, "w").write(bundle)
    print(read["seq"])
    return 0


def cmd_amend(state, policy_json, n):
    """Replace the policy, decided by the first n founders. 0 = accepted (and
    saved), 9 = refused by the authority pass (nothing saved)."""
    e = Ethne()
    st, arc = load_state(state, e)
    f = st["founders"]
    e.spec("ethne_amend_content_policy", arc, {
        "polity_did": st["root"]["did"], "policy": json.loads(policy_json),
        "rationale": f"amended by {n}", "deciders": [signer(k) for k in f[:n]]})
    if e.lib.ethne_verify(arc) != 0:
        print(f"amend by {n}: refused — {e.err()}")
        return 9
    save_state(state, st, arc, e)
    print(f"amend by {n}: accepted")
    return 0


def cmd_revoke(state):
    e = Ethne()
    st, arc = load_state(state, e)
    f = st["founders"]
    e.spec("ethne_revoke_office", arc, {
        "polity_did": st["root"]["did"], "office": "Moderator",
        "holder_did": f[1]["did"], "deciders": [signer(f[0]), signer(f[2])]})
    if e.lib.ethne_verify(arc) != 0:
        print("revoke: refused — " + e.err(), file=sys.stderr)
        return 9
    save_state(state, st, arc, e)
    return 0


def cmd_follow(shim, root, bundle_path, timeout):
    """Follow the community a verified bundle names — what the app does after
    ethne_content_policy_verify accepts it."""
    bundle = open(bundle_path).read()
    read = Ethne().verify_policy(bundle)
    if read is None:
        print("follow: the bundle does not verify", file=sys.stderr)
        return 3
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    rc = lib.agora_follow_community(h, b"extern_to_at", read["community_did"].encode(),
                                    bundle.encode(), int(read["seq"]))
    lib.agora_events_close(h)
    print(f"follow {read['community_did'][-10:]} seq {read['seq']} rc={rc}")
    return 0 if rc == 0 else 4


def cmd_await_policy(shim, root, did, min_seq, timeout, out_path):
    """Wait for a carried policy for `did` that VERIFIES out of the received
    bytes and is at least `min_seq`; save it."""
    e = Ethne()
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    deadline = time.time() + timeout
    got = None
    while time.time() < deadline and got is None:
        for ev in drain(lib, h, buf, cap, deadline):
            if ev.kind != EV_POLICY or ev.policy_community.decode() != did:
                continue
            bundle = ev.policy_bundle.decode()
            read = e.verify_policy(bundle)
            if read is None:
                print("await-policy: a carried policy did NOT verify", file=sys.stderr)
                continue
            if read["seq"] >= min_seq:
                got = (bundle, read, bytes(ev.peer_uuid).hex())
                break
        time.sleep(0.5)
    lib.agora_events_close(h)
    if got is None:
        print(f"await-policy: no verifying policy seq>={min_seq} in {timeout}s", file=sys.stderr)
        return 5
    open(out_path, "w").write(got[0])
    print(f"policy seq {got[1]['seq']} carried by {got[2][:12]}…, "
          f"{len(got[1]['moderators'])} moderator(s)")
    return 0


def cmd_publish_scoped(shim, root, body, community, labels, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    rc = lib.agora_publish_post_scoped(h, b"extern_to_at", body.encode(), 0,
                                       community.encode(), labels.encode())
    lib.agora_events_close(h)
    print(f"publish '{body}' rc={rc}")
    return 0 if rc == 0 else 4


def cmd_publish(shim, root, body, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    rc = lib.agora_publish_post(h, b"extern_to_at", body.encode(), 0)
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_observe_posts(shim, root, marker, count, timeout, out_path):
    """Collect `count` distinct posts carrying `marker`, in the order received,
    with the scope the core delivered."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    seen, posts = set(), []
    deadline = time.time() + timeout
    while time.time() < deadline and len(posts) < count:
        for ev in drain(lib, h, buf, cap, deadline):
            body = ev.post_body.decode(errors="replace")
            pid = ev.post_id.decode()
            if ev.kind == EV_POST and marker in body and pid not in seen:
                seen.add(pid)
                labels = ev.post_labels.decode()
                posts.append({"post_id": pid, "body": body, "ts": ev.post_ts,
                              "author": bytes(ev.peer_uuid).hex(),
                              "community": ev.post_community.decode(),
                              "labels": labels.split(",") if labels else []})
        time.sleep(0.5)
    lib.agora_events_close(h)
    json.dump(posts, open(out_path, "w"))
    for p in posts:
        print(f"  {p['body']!r} in {p['community'][-10:] or '-'} labels {p['labels']}")
    if len(posts) < count:
        print(f"observe-posts: {len(posts)} of {count} '{marker}' posts in {timeout}s", file=sys.stderr)
        return 5
    return 0


def cmd_observe_labels(shim, root, post_id, timeout, out_path):
    """Wait for a moderator label on `post_id`; save the bundles received."""
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    got = []
    deadline = time.time() + timeout
    while time.time() < deadline and not got:
        for ev in drain(lib, h, buf, cap, deadline):
            if ev.kind == EV_LABEL and ev.label_post_id.decode() == post_id:
                got.append(ev.label_bundle.decode())
        time.sleep(0.5)
    lib.agora_events_close(h)
    if not got:
        print(f"observe-labels: no label on {post_id[:16]}… in {timeout}s", file=sys.stderr)
        return 5
    prev = json.load(open(out_path)) if os.path.exists(out_path) else []
    json.dump(prev + got, open(out_path, "w"))
    print(f"label on {post_id[:16]}… received ({len(got)})")
    return 0


def cmd_observe_no_labels(shim, root, seconds):
    """THE FOLLOW GATE, a bounded claim: no label of any kind arrives."""
    lib = open_lib(shim, root)
    h = connect(lib, seconds)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    deadline = time.time() + seconds
    while time.time() < deadline:
        for ev in drain(lib, h, buf, cap, deadline):
            if ev.kind == EV_LABEL:
                print(f"observe-no-labels: a label ARRIVED ({ev.label_community.decode()[-10:]})",
                      file=sys.stderr)
                lib.agora_events_close(h)
                return 7
        time.sleep(0.5)
    lib.agora_events_close(h)
    print(f"no label in {seconds}s, as required")
    return 0


def cmd_label(state, shim, root, post_id, labels, seq, timeout):
    """mod labels a post, signing with its own member key."""
    e = Ethne()
    st = json.load(open(state))
    mod = st["founders"][1]
    bundle = e.call_out("ethne_post_label_sign", json.dumps({
        "community_did": st["root"]["did"], "post_id": post_id,
        "labels": [l for l in labels.split(",") if l], "seq": int(seq),
        "moderator": signer(mod)}).encode())
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    rc = lib.agora_publish_post_label(h, b"extern_to_at", st["root"]["did"].encode(),
                                      post_id.encode(), bundle.encode(), int(seq))
    lib.agora_events_close(h)
    print(f"label {labels} on {post_id[:16]}… rc={rc}")
    return 0 if rc == 0 else 4


def cmd_verdicts(policy_path, posts_path, labels_path, out_path):
    """The verdict for each received post under a policy, computed exactly as
    the app computes it: each author's place among their posts in the community
    that UTC day, by the posts' own timestamps (post id breaks ties) and not by
    the order received, and every label received for the post."""
    e = Ethne()
    policy = open(policy_path).read()
    posts = json.load(open(posts_path))
    labels = json.load(open(labels_path)) if labels_path != "-" and os.path.exists(labels_path) else []
    days, out = {}, []
    for p in posts:
        key = (p["community"], p["author"], time.strftime("%Y-%m-%d", time.gmtime(p["ts"])))
        days.setdefault(key, []).append((p["ts"], p["post_id"]))
    for p in posts:
        key = (p["community"], p["author"], time.strftime("%Y-%m-%d", time.gmtime(p["ts"])))
        index = sorted(days[key]).index((p["ts"], p["post_id"])) + 1
        v = json.loads(e.call_out("ethne_content_policy_verdict", json.dumps({
            "policy": policy, "post_id": p["post_id"], "author_labels": p["labels"],
            "labels": labels, "author_tier": 0, "author_operator_bound": False,
            "author_post_index_today": index}).encode()))
        out.append({"body": p["body"], "action": v["action"], "reasons": v["reasons"],
                    "refused": v["labels_refused"]})
        print(f"  {p['body']!r}: {v['action']} "
              f"{[r['code'] + ('/' + r.get('label', '') if r['code'] == 'label' else '') for r in v['reasons']]}"
              f"{' (labels refused: %d)' % v['labels_refused'] if v['labels_refused'] else ''}")
    json.dump(out, open(out_path, "w"))
    return 0


def cmd_expect(verdicts_path, body_marker, action, code, by):
    """One verdict, by the marker in its body: its action, and optionally one
    reason code and who applied a label."""
    for v in json.load(open(verdicts_path)):
        if body_marker in v["body"]:
            if v["action"] != action:
                print(f"expect: {body_marker!r} is {v['action']}, wanted {action}", file=sys.stderr)
                return 6
            if code != "-" and not any(r["code"] == code and (by == "-" or r.get("by") == by)
                                       for r in v["reasons"]):
                print(f"expect: {body_marker!r} lacks reason {code} by {by}: {v['reasons']}",
                      file=sys.stderr)
                return 6
            return 0
    print(f"expect: no verdict for {body_marker!r}", file=sys.stderr)
    return 5


def cmd_peers(shim, root, want, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    seen = {}
    deadline = time.time() + timeout
    while time.time() < deadline:
        lib.agora_events_request_roster(h, b"extern_to_at")
        for ev in drain(lib, h, buf, cap, deadline):
            if ev.kind == EV_PEER:
                seen[bytes(ev.peer_uuid).hex()] = True
        if len(seen) >= want:
            break
        time.sleep(1.0)
    lib.agora_events_close(h)
    print(f"peers discovered: {len(seen)} of {want} wanted")
    return 0 if len(seen) >= want else 5


def cmd_observe_plain(shim, root, timeout):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    cap = 64
    buf = (Ev * cap)()
    deadline = time.time() + timeout
    while time.time() < deadline:
        for ev in drain(lib, h, buf, cap, deadline):
            if ev.kind == EV_POST and ev.post_id:
                lib.agora_events_close(h)
                return 0
        time.sleep(0.5)
    lib.agora_events_close(h)
    return 5


def main(a):
    v = a[1]
    if v == "mint":
        return cmd_mint(a[2])
    if v == "sign":
        return cmd_sign(a[2], a[3])
    if v == "amend":
        return cmd_amend(a[2], a[3], int(a[4]))
    if v == "revoke":
        return cmd_revoke(a[2])
    if v == "verdicts":
        return cmd_verdicts(a[2], a[3], a[4], a[5])
    if v == "expect":
        return cmd_expect(a[2], a[3], a[4], a[5], a[6])
    if v == "label":
        return cmd_label(a[2], a[3], a[4], a[5], a[6], a[7], float(a[8]))
    shim, root = a[2], a[3]
    if v == "peers":
        return cmd_peers(shim, root, int(a[4]), float(a[5]))
    if v == "follow":
        return cmd_follow(shim, root, a[4], float(a[5]))
    if v == "await-policy":
        return cmd_await_policy(shim, root, a[4], int(a[5]), float(a[6]), a[7])
    if v == "publish-scoped":
        return cmd_publish_scoped(shim, root, a[4], a[5], a[6], float(a[7]))
    if v == "publish":
        return cmd_publish(shim, root, a[4], float(a[5]))
    if v == "observe-posts":
        return cmd_observe_posts(shim, root, a[4], int(a[5]), float(a[6]), a[7])
    if v == "observe-labels":
        return cmd_observe_labels(shim, root, a[4], float(a[5]), a[6])
    if v == "observe-no-labels":
        return cmd_observe_no_labels(shim, root, float(a[4]))
    if v == "observe-plain":
        return cmd_observe_plain(shim, root, float(a[4]))
    print(f"unknown verb {v}", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

if ! python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$DRIVER"; then
  err "the embedded driver does not compile — refusing to start any node."
  exit 1
fi

drive() { # node verb args...  (a node-facing verb)
  local n="$1"; shift
  local verb="$1"; shift
  ETHNE="$ETHNE" LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    python3 "$DRIVER" "$verb" "$SHIM" "${ROOT[$n]}" "$@"
}
tool() { # verb args...  (an Ethne-only verb: no node, no queue)
  ETHNE="$ETHNE" python3 "$DRIVER" "$@"
}

saw() { # node pattern
  grep -q "$2" "${ROOT[$1]}/agorad.log" 2>/dev/null
}

converge_gate() { # publisher observer
  local pub="$1" obs="$2" round=0 deadline=$(( SECONDS + WAIT ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    round=$(( round + 1 ))
    drive "$obs" observe-plain 20 >/dev/null 2>&1 &
    local o=$!
    sleep 2
    drive "$pub" publish "group probe $pub->$obs $round" "$WAIT" >/dev/null 2>&1
    if wait "$o"; then log "group channel live: $pub -> $obs (probe $round)"; return 0; fi
    log "  group channel not settled yet: $pub -> $obs (probe $round) — retrying"
  done
  return 1
}

fail() { err "FAIL ($1) — $2"; dump_logs; exit 1; }

# --------------------------------------------------------------------------- #
# Phase 1 — discovery, one node at a time; the group channel is live
# --------------------------------------------------------------------------- #
log "Phase 1: starting ${NODES[*]} one at a time"
started=()
for n in "${NODES[@]}"; do
  node_start "$n"
  sleep 3
  kill -0 "${PID[$n]}" 2>/dev/null || fail "phase 1" "$n died at start"
  if [ "${#started[@]}" -eq 0 ]; then
    deadline=$(( SECONDS + WAIT ))
    until saw "$n" "self-bootstrapping a fresh group" || [ "$SECONDS" -ge "$deadline" ]; do sleep 1; done
  else
    drive "$n" peers "${#started[@]}" "$WAIT" >/dev/null \
      || fail "phase 1" "$n did not join the ${#started[@]} running node(s)"
  fi
  started+=("$n")
done
for n in "${NODES[@]}"; do
  drive "$n" peers $(( ${#NODES[@]} - 1 )) "$WAIT" >/dev/null \
    || fail "phase 1" "$n did not discover every other node"
done
for n in mod cal dee; do
  converge_gate keeper "$n" || fail "phase 1" "the group channel keeper -> $n never settled"
done
ok "phase 1: four nodes, one live group"

# --------------------------------------------------------------------------- #
# Phase 2 — the policy is carried, verifies on arrival, and is followed
# --------------------------------------------------------------------------- #
log "Phase 2: the roll sets policy v1 and seats mod as Moderator"
DID="$(tool mint "$STATE")" || fail "phase 2" "could not mint the polity"
SEQ1="$(tool sign "$STATE" "$RUN/policy-v1.json")" || fail "phase 2" "could not sign policy v1"
log "community $DID, policy v1 at seq $SEQ1"
drive cal await-policy "$DID" "$SEQ1" "$WAIT" "$RUN/cal-v1.json" & W_CAL=$!
drive dee await-policy "$DID" "$SEQ1" "$WAIT" "$RUN/dee-v1.json" & W_DEE=$!
sleep 4
drive keeper follow "$RUN/policy-v1.json" "$WAIT" || fail "phase 2" "keeper could not follow v1"
drive mod follow "$RUN/policy-v1.json" "$WAIT" || fail "phase 2" "mod could not follow v1"
wait "$W_CAL" || fail "phase 2" "cal never received a verifying policy"
wait "$W_DEE" || fail "phase 2" "dee never received a verifying policy"
cmp -s "$RUN/cal-v1.json" "$RUN/policy-v1.json" || fail "phase 2" "cal holds bytes other than the ones minted"
drive cal follow "$RUN/cal-v1.json" "$WAIT" || fail "phase 2" "cal could not follow"
deadline=$(( SECONDS + 20 ))
until saw cal "following $DID at seq $SEQ1" || [ "$SECONDS" -ge "$deadline" ]; do sleep 1; done
saw cal "following $DID at seq $SEQ1" || fail "phase 2" "cal's core never recorded the follow"
saw dee "following " && fail "phase 2" "dee follows something, and must not"
ok "phase 2: the policy crossed, verified out of the received bytes, and cal follows it"

# --------------------------------------------------------------------------- #
# Phase 3 — the policy moderates its follower, and only its follower
# --------------------------------------------------------------------------- #
log "Phase 3: keeper posts three times in the community's name"
drive cal observe-posts "P3-" 3 "$WAIT" "$RUN/cal-p3.json" & O_CAL=$!
drive dee observe-posts "P3-" 3 "$WAIT" "$RUN/dee-p3.json" & O_DEE=$!
sleep 4
drive keeper publish-scoped "P3-a first light" "$DID" "spoiler" "$WAIT" || fail "phase 3" "publish a"
sleep 1
drive keeper publish-scoped "P3-b seedlings" "$DID" "" "$WAIT" || fail "phase 3" "publish b"
sleep 1
drive keeper publish-scoped "P3-c compost" "$DID" "" "$WAIT" || fail "phase 3" "publish c"
wait "$O_CAL" || fail "phase 3" "cal did not receive all three posts"
wait "$O_DEE" || fail "phase 3" "dee did not receive all three posts"
python3 - "$RUN/dee-p3.json" "$DID" <<'CHK' || fail "phase 3" "dee's copies lost their scope"
import json, sys
posts, did = json.load(open(sys.argv[1])), sys.argv[2]
a = [p for p in posts if "P3-a" in p["body"]][0]
assert all(p["community"] == did for p in posts), "a post lost its community"
assert a["labels"] == ["spoiler"], f"the author's label did not survive: {a['labels']}"
CHK
tool verdicts "$RUN/cal-v1.json" "$RUN/cal-p3.json" - "$RUN/v3.json"
tool expect "$RUN/v3.json" "P3-a" warn label author || fail "phase 3" "the spoiler post is not behind a warning"
tool expect "$RUN/v3.json" "P3-b" show - - || fail "phase 3" "the plain second post is not shown"
tool expect "$RUN/v3.json" "P3-c" hide over_daily_cap - || fail "phase 3" "the third post is not over the daily cap"
ok "phase 3: under cal's policy a=warn, b=show, c=hide (cap); dee got all three, scope intact, unmoderated"

# --------------------------------------------------------------------------- #
# Phase 4 — a moderator's label reaches followers only
# --------------------------------------------------------------------------- #
B_ID="$(python3 -c "import json,sys;print([p['post_id'] for p in json.load(open(sys.argv[1])) if 'P3-b' in p['body']][0])" "$RUN/cal-p3.json")"
MOD_DID="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['founders'][1]['did'])" "$STATE")"
log "Phase 4: mod labels P3-b 'nsfw'"
drive cal observe-labels "$B_ID" "$WAIT" "$RUN/cal-labels.json" & L_CAL=$!
drive dee observe-no-labels "$GATE_WINDOW" & L_DEE=$!
sleep 4
tool label "$STATE" "$SHIM" "${ROOT[mod]}" "$B_ID" "nsfw" 1 "$WAIT" || fail "phase 4" "mod could not label"
wait "$L_CAL" || fail "phase 4" "cal never received the label"
wait "$L_DEE" || fail "phase 4" "dee, who follows nothing, received a label"
tool verdicts "$RUN/cal-v1.json" "$RUN/cal-p3.json" "$RUN/cal-labels.json" "$RUN/v4.json"
tool expect "$RUN/v4.json" "P3-b" hide label "$MOD_DID" || fail "phase 4" "the labelled post is not hidden by mod's label"
ok "phase 4: the label hid P3-b at cal, naming mod; dee received no label at all"

# --------------------------------------------------------------------------- #
# Phase 5 — loosening needs more than a majority; the newer policy replaces
# --------------------------------------------------------------------------- #
log "Phase 5: the roll lifts the daily cap"
V2='{"operator_bound_required": false, "min_tier": 0, "daily_post_cap": null, "labels": {"spoiler": "Warn", "nsfw": "Hide"}}'
tool amend "$STATE" "$V2" 2; rc=$?
[ "$rc" -eq 9 ] || fail "phase 5" "a loosening at 2 of 3 was not refused (rc $rc)"
tool amend "$STATE" "$V2" 3 || fail "phase 5" "a loosening at 3 of 3 was refused"
SEQ2="$(tool sign "$STATE" "$RUN/policy-v2.json")" || fail "phase 5" "could not sign v2"
[ "$SEQ2" -gt "$SEQ1" ] || fail "phase 5" "v2's seq $SEQ2 is not above v1's $SEQ1"
drive cal await-policy "$DID" "$SEQ2" "$WAIT" "$RUN/cal-v2.json" & W_CAL=$!
sleep 4
drive keeper follow "$RUN/policy-v2.json" "$WAIT" || fail "phase 5" "keeper could not carry v2"
wait "$W_CAL" || fail "phase 5" "cal never received v2"
drive cal follow "$RUN/cal-v2.json" "$WAIT" || fail "phase 5" "cal could not follow v2"
deadline=$(( SECONDS + 20 ))
until saw cal "following $DID at seq $SEQ2" || [ "$SECONDS" -ge "$deadline" ]; do sleep 1; done
saw cal "following $DID at seq $SEQ2" || fail "phase 5" "cal's core still holds the old policy"
tool verdicts "$RUN/cal-v2.json" "$RUN/cal-p3.json" - "$RUN/v5.json"
tool expect "$RUN/v5.json" "P3-c" show - - || fail "phase 5" "with the cap lifted, P3-c is still hidden"
ok "phase 5: refused at 2, accepted at 3; v2 (seq $SEQ2) replaced v1 at cal, and P3-c shows"

# --------------------------------------------------------------------------- #
# Phase 6 — an unseated moderator's label no longer counts
# --------------------------------------------------------------------------- #
log "Phase 6: the roll unseats mod"
tool revoke "$STATE" || fail "phase 6" "the revocation was refused"
SEQ3="$(tool sign "$STATE" "$RUN/policy-v3.json")" || fail "phase 6" "could not sign v3"
drive cal await-policy "$DID" "$SEQ3" "$WAIT" "$RUN/cal-v3.json" & W_CAL=$!
sleep 4
drive keeper follow "$RUN/policy-v3.json" "$WAIT" || fail "phase 6" "keeper could not carry v3"
wait "$W_CAL" || fail "phase 6" "cal never received v3"
drive cal follow "$RUN/cal-v3.json" "$WAIT" || fail "phase 6" "cal could not follow v3"
A_ID="$(python3 -c "import json,sys;print([p['post_id'] for p in json.load(open(sys.argv[1])) if 'P3-a' in p['body']][0])" "$RUN/cal-p3.json")"
drive cal observe-labels "$A_ID" "$WAIT" "$RUN/cal-labels.json" & L_CAL=$!
sleep 4
tool label "$STATE" "$SHIM" "${ROOT[mod]}" "$A_ID" "nsfw" 2 "$WAIT" || fail "phase 6" "mod could not publish"
wait "$L_CAL" || fail "phase 6" "cal never received mod's second label"
tool verdicts "$RUN/cal-v3.json" "$RUN/cal-p3.json" "$RUN/cal-labels.json" "$RUN/v6.json"
tool expect "$RUN/v6.json" "P3-a" warn label author || fail "phase 6" "P3-a is not still only behind its warning"
tool expect "$RUN/v6.json" "P3-b" show - - || fail "phase 6" "mod's earlier label still hides P3-b"
ok "phase 6: v3 lists no moderator; mod's labels reach cal and count for nothing"

log "PASS: community policy — carried, followed, applied only by its follower, loosened only above a majority"
exit 0
