#!/usr/bin/env bash
#
# hub_cohort.sh — Phase 4 live check: people in one city, on two networks that
# cannot reach each other, find each other at their community's area hub, and
# only if both chose to be findable (SOCIAL_APP_PLAN §4.1 band 2; Ethne D38).
#
# Five real agorad nodes on TWO virtual L2 segments with no route between them:
#
#   segment A (10.9.8.0/24, agbr8)      segment B (10.9.9.0/24, agbr9)
#     keeper — the polity's ROOT key      bob — lists in u4pr, and asks ann
#     ann    — lists in u4pr                eve — follows, never lists: the control
#                     hub — a leg on each, forwarding OFF: AT_RELAY + AT_HUB
#                           for area u4pr, seated by the roll as its
#                           RendezvousOperator
#
# The hub forwards nothing between the segments (ip_forward=0): each side has
# a /32 route to the ONE address the hub's relay listens on, and nothing else
# crosses. Broadcast discovery stays on its own segment.
#
# The driver plays the app: it holds the charter log, mints and verifies every
# artifact through the REAL Ethne cdylib, and drives the real app-event queues.
#
# What it proves, in order:
#   1. TWO ISLANDS. keeper+ann discover each other, bob+eve discover each other,
#      and bob never learns ann exists.
#   2. THE ROLL SEATS A HUB AND ITS ROSTER TRAVELS IN THE POLICY. The hub's own
#      AT key is its member key; the roll confers RendezvousOperator, the hub
#      declares its relay and area u4pr, and keeper mints the policy with the
#      roster inside. ann receives it over her group, verifies it and follows,
#      installing the roster; bob and eve were handed the same bundle (they are
#      on the other island) and do the same. All three register with the hub.
#   3. OPT-IN LISTINGS. ann and bob list themselves in u4pr (the hub confirms);
#      eve does not.
#   4. RECIPROCAL LOOKUPS. bob's lookup finds ann (with her bucket), ann's finds
#      bob, and eve's finds nobody although both are listed.
#   5. THE HUB'S AREA IS THE ONLY AREA. bob listing in gcpv is refused ('area').
#   6. FINDING IS NOT ADDING. bob asks ann; ann's app gets the request (found
#      "area:u4pr") and accepts; both see the handshake complete, as DIRECT
#      peers, and a DM from bob reaches ann across the islands.
#   7. OPTING OUT TAKES EFFECT AT ONCE. ann withdraws; bob's next lookup finds
#      nobody.
#
# NETNS ONLY. Requirements: root + iproute2, python3, and the built native
# layer + ethne cdylib (./build.sh).
#
# Usage:
#   sudo -E env "PATH=$PATH" ./test/cohort/hub_cohort.sh
#   WAIT=120 KEEP=1 ./test/cohort/hub_cohort.sh
#
# Env knobs: WAIT (per-phase timeout, default 120), POLICY_SEC (policy re-carry
#   interval, default 10), SUBNET_A / SUBNET_B (default 10.9.8 / 10.9.9),
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

ETHNE="${AGORA_ETHNE_PATH:-$NATIVE/libethne_agora.so}"

WAIT="${WAIT:-120}"
POLICY_SEC="${POLICY_SEC:-10}"
LOG_LEVEL="${LOG_LEVEL:-2}"
SUBNET_A="${SUBNET_A:-10.9.8}"
SUBNET_B="${SUBNET_B:-10.9.9}"
PREFIX=24
AREA=u4pr
RELAY_PORT=27790

NODES=(keeper ann bob eve hub)
declare -A IP NS V VB ROOT PID SEG GEO
IP[keeper]="$SUBNET_A.11"; SEG[keeper]=A; GEO[keeper]=u4pruy
IP[ann]="$SUBNET_A.12";    SEG[ann]=A;    GEO[ann]=u4pruy
IP[bob]="$SUBNET_B.21";    SEG[bob]=B;    GEO[bob]=u4prvb
IP[eve]="$SUBNET_B.22";    SEG[eve]=B;    GEO[eve]=u4prvc
IP[hub]="$SUBNET_A.10";    SEG[hub]=A;    GEO[hub]=u4pruy
HUB_B="$SUBNET_B.20"
for n in "${NODES[@]}"; do NS[$n]="aghb$n"; V[$n]="agh${n:0:3}"; VB[$n]="agh${n:0:3}b"; done
V2=aghhub2; VB2=aghhub2b
BR_A=agbr8; BR_B=agbr9

RUN="${AGORA_COHORT_RUN:-$AGORA_DIR/.coh/hub-$$}"
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
# --------------------------------------------------------------------------- #
# Two segments, and a hub on both with forwarding off
# --------------------------------------------------------------------------- #
net_reset() {
  local n
  for n in "${NODES[@]}"; do
    ip netns del "${NS[$n]}" 2>/dev/null
    ip link del "${VB[$n]}" 2>/dev/null
  done
  ip link del "$VB2" 2>/dev/null
  ip link del "$BR_A" 2>/dev/null
  ip link del "$BR_B" 2>/dev/null
  return 0
}

leg() { # ns veth veth-bridge-end bridge ip
  ip link add "$2" type veth peer name "$3" || return 1
  ip link set "$2" netns "$1" || return 1
  ip link set "$3" master "$4" || return 1
  ip link set "$3" up || return 1
  ip -n "$1" addr add "$5/$PREFIX" dev "$2" || return 1
  ip -n "$1" link set "$2" up || return 1
}

net_up() {
  net_reset
  log "Creating $BR_A ($SUBNET_A.0/$PREFIX) and $BR_B ($SUBNET_B.0/$PREFIX), no route between"
  ip link add "$BR_A" type bridge && ip link set "$BR_A" up || return 1
  ip link add "$BR_B" type bridge && ip link set "$BR_B" up || return 1
  local n br
  for n in "${NODES[@]}"; do
    ip netns add "${NS[$n]}" || return 1
    ip -n "${NS[$n]}" link set lo up || return 1
    br=$BR_A; [ "${SEG[$n]}" = B ] && br=$BR_B
    leg "${NS[$n]}" "${V[$n]}" "${VB[$n]}" "$br" "${IP[$n]}" || return 1
  done
  leg "${NS[hub]}" "$V2" "$VB2" "$BR_B" "$HUB_B" || return 1
  # procfs, not sysctl: /usr/sbin is often missing from the PATH sudo carries.
  ip netns exec "${NS[hub]}" sh -c 'echo 0 > /proc/sys/net/ipv4/ip_forward' || return 1
  if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
    echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
  fi
  # Each island reaches the hub's OTHER address through the hub's own leg, so
  # whichever one its relay binds is reachable from both; with forwarding off
  # nothing else crosses.
  for n in keeper ann; do ip -n "${NS[$n]}" route add "$HUB_B/32" via "${IP[hub]}" || return 1; done
  for n in bob eve; do ip -n "${NS[$n]}" route add "${IP[hub]}/32" via "$HUB_B" || return 1; done
  ip netns exec "${NS[ann]}" ping -c1 -W2 "${IP[keeper]}" >/dev/null 2>&1 || { err "no path ann -> keeper"; return 1; }
  ip netns exec "${NS[bob]}" ping -c1 -W2 "${IP[eve]}" >/dev/null 2>&1 || { err "no path bob -> eve"; return 1; }
  ip netns exec "${NS[bob]}" ping -c1 -W2 "${IP[hub]}" >/dev/null 2>&1 || { err "bob cannot reach the hub"; return 1; }
  ip netns exec "${NS[ann]}" ping -c1 -W2 "$HUB_B" >/dev/null 2>&1 || { err "ann cannot reach the hub"; return 1; }
  if ip netns exec "${NS[bob]}" ping -c1 -W2 "${IP[ann]}" >/dev/null 2>&1; then
    err "bob reaches ann directly: the islands are not islands"; return 1
  fi
  log "two islands ready; the hub is reachable from both, and nothing else crosses"
}

node_start() { # name [extra env...]
  local n="$1"; shift
  ip netns exec "${NS[$n]}" env \
    AUTONOMOUS_TRUST_ROOT="${ROOT[$n]}" \
    AT_PEER_NAME="$n" AT_PEER_SEED="hub-$n" \
    AT_OWN_GEOHASH="${GEO[$n]}" \
    AT_SOCIAL_POLICY_SEC="$POLICY_SEC" \
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
  PID[$1]=""
}

dump_logs() {
  local n
  for n in "${NODES[@]}"; do
    [ -f "${ROOT[$n]}/agorad.log" ] || continue
    echo "--- $n ---"
    grep -E "Relay|Hub|area|directory|first contact|ERROR" "${ROOT[$n]}/agorad.log" | tail -n 25
  done
}

cleanup() {
  local rc="${1:-0}" n
  for n in "${NODES[@]}"; do node_stop "$n"; done
  if [ "${KEEP:-0}" = "1" ] || [ "$rc" != "0" ]; then
    log "Leaving the network and $RUN in place (exit $rc). Tear down with:"
    for n in "${NODES[@]}"; do log "  ip netns del ${NS[$n]}"; done
    log "  ip link del $BR_A; ip link del $BR_B"
    return
  fi
  net_reset
  rm -rf "$RUN"
}
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT TERM

net_up || exit 1

# --------------------------------------------------------------------------- #
# The app-side driver. Ev, connect(), drain(), open_lib() and Ethne are SPLICED
# VERBATIM out of community_policy_cohort.sh; the hub verbs are new.
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



EV_AREA, EV_CONTACT, EV_DM = 18, 19, 8
AREA_PUBLISHED, AREA_REFUSED, AREA_WITHDRAWN, AREA_CARD, AREA_DONE = 1023, 1024, 1025, 1026, 1027
ROSTER_INSTALLED, ROSTER_REFUSED = 1028, 1029
DIR_REQUEST_SENT, DIR_CONTACT_REQUEST, DIR_ACCEPTED = 1014, 1015, 1016
FC_ESTABLISHED = 1003


def hub_lib(shim, root):
    lib = open_lib(shim, root)
    vp, cp = ctypes.c_void_p, ctypes.c_char_p
    lib.agora_area_publish.argtypes = [vp, cp, cp, cp, cp, cp]
    lib.agora_area_withdraw.argtypes = [vp, cp, cp, cp]
    lib.agora_area_lookup.argtypes = [vp, cp, cp, cp]
    lib.agora_area_request.argtypes = [vp, cp, cp, cp, ctypes.POINTER(ctypes.c_uint8)]
    lib.agora_contact_accept.argtypes = [vp, cp, cp]
    lib.agora_relay_roster_install.argtypes = [vp, cp, cp, cp]
    lib.agora_send_dm.argtypes = [vp, cp, ctypes.POINTER(ctypes.c_uint8), cp]
    return lib


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


def identity(root):
    return json.load(open(os.path.join(root, "etc", "at", "identity.cfg.json")))


def cmd_mint(state, hub_root, relay_port):
    """Found a three-founder polity plus the hub's node as a member (its AT
    key IS its member key), seat the hub as RendezvousOperator, and have it
    declare its relay for the area."""
    e = Ethne()
    e.lib.ethne_keypair_from_seed.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p)]
    hid = identity(hub_root)
    hub = json.loads(e.call_out("ethne_keypair_from_seed", hid["signature"]["hex_seed"].encode()))
    root = e.keypair()
    f = [e.keypair() for _ in range(3)]
    arc = e.lib.ethne_archive_new()
    e.lib.ethne_declare_relay_endpoint.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    e.spec("ethne_found_polity", arc, {
        "polity_did": root["did"], "name": "Riverside Commons",
        "statement": "Neighbours who garden.",
        "members": [k["did"] for k in f] + [hub["did"]],
        "ratifiers": [signer(k) for k in f] + [signer(hub)]})
    e.spec("ethne_confer_office", arc, {
        "polity_did": root["did"], "office": "RendezvousOperator", "holder_did": hub["did"],
        "holder_priv": hub["priv"], "deciders": [signer(k) for k in f]})
    e.spec("ethne_declare_relay_endpoint", arc, {
        "polity_did": root["did"], "member": signer(hub), "at_uuid": hid["uuid"].lower(),
        "host": hid["address"], "port": int(relay_port), "areas": [os.environ["AREA"]]})
    if e.lib.ethne_verify(arc) != 0:
        print("mint: the log does not verify: " + e.err(), file=sys.stderr)
        return 3
    save_state(state, {"root": root, "founders": f, "hub": hub}, arc, e)
    print(root["did"])
    print(f"hub {hid['uuid']} at {hid['address']}:{relay_port} is {hub['did'][-10:]}", file=sys.stderr)
    return 0


def cmd_sign(state, out_path):
    e = Ethne()
    st, arc = load_state(state, e)
    bundle = e.call_out("ethne_content_policy_sign", arc, json.dumps(
        {"polity_did": st["root"]["did"], "root_priv": st["root"]["priv"], "hubs": True}).encode())
    read = e.verify_policy(bundle)
    if read is None or not read.get("hub_areas"):
        print("sign: the minted policy does not verify, or names no hub", file=sys.stderr)
        return 3
    open(out_path, "w").write(bundle)
    print(f"seq {read['seq']} hubs {read['hub_areas']}")
    return 0


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


def cmd_follow(shim, root, bundle_path, timeout):
    """What the app does with a verified policy it follows: follow it, and
    install the community's roster it carries."""
    bundle = open(bundle_path).read()
    read = Ethne().verify_policy(bundle)
    if read is None or not read.get("hubs"):
        print("follow: the bundle does not verify, or carries no roster", file=sys.stderr)
        return 3
    lib = hub_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    q = b"extern_to_at"
    rc = lib.agora_follow_community(h, q, read["community_did"].encode(), bundle.encode(),
                                    int(read["seq"]))
    rc2 = lib.agora_relay_roster_install(h, q, b"roster", read["hubs"].encode())
    got = _take_events(lib, h, timeout, lambda ev: ev.fc_kind
                       if ev.kind == EV_AREA and ev.fc_kind in (ROSTER_INSTALLED, ROSTER_REFUSED)
                       else None)
    lib.agora_events_close(h)
    print(f"follow rc={rc}, roster install rc={rc2}: {'installed' if got == ROSTER_INSTALLED else got}")
    return 0 if rc == 0 and rc2 == 0 and got == ROSTER_INSTALLED else 4


def cmd_await_policy(shim, root, did, timeout, out_path):
    """A policy for `did` carried over the group, verifying out of the
    received bytes and carrying a roster; saved for follow."""
    e = Ethne()
    lib = hub_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2

    def want(ev):
        if ev.kind != EV_POLICY or ev.policy_community.decode() != did:
            return None
        bundle = ev.policy_bundle.decode()
        read = e.verify_policy(bundle)
        return bundle if read is not None and read.get("hubs") else None
    got = _take_events(lib, h, timeout, want)
    lib.agora_events_close(h)
    if got is None:
        print("await-policy: no verifying policy with a roster arrived", file=sys.stderr)
        return 5
    open(out_path, "w").write(got)
    print("await-policy: carried over the group, verified, roster inside")
    return 0


def cmd_list(shim, root, area, bucket, name, timeout, want_reason):
    """List us in `area`, retrying until the hub answers (registration runs in
    the background). want_reason '' expects PUBLISHED, else REFUSED with it."""
    lib = hub_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    deadline = time.time() + timeout
    got = None
    while got is None and time.time() < deadline:
        lib.agora_area_publish(h, b"extern_to_at", b"list", area.encode(), bucket.encode(),
                               name.encode())
        got = _take_events(lib, h, 8, lambda ev: (ev.fc_kind, ev.fc_reason.decode())
                           if ev.kind == EV_AREA and ev.fc_kind in (AREA_PUBLISHED, AREA_REFUSED)
                           and ev.area.decode() == area else None)
    lib.agora_events_close(h)
    print(f"list {area}: {got}")
    if want_reason == "":
        return 0 if got is not None and got[0] == AREA_PUBLISHED else 5
    return 0 if got is not None and got == (AREA_REFUSED, want_reason) else 5


def cmd_withdraw(shim, root, area, timeout):
    lib = hub_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    lib.agora_area_withdraw(h, b"extern_to_at", b"list", area.encode())
    got = _take_events(lib, h, timeout, lambda ev: True
                       if ev.kind == EV_AREA and ev.fc_kind == AREA_WITHDRAWN else None)
    lib.agora_events_close(h)
    print(f"withdraw {area}: {'confirmed' if got else 'no answer'}")
    return 0 if got else 5


def cmd_lookup(shim, root, area, timeout, out_path):
    """One lookup; the cards it found, as {uuid, bucket, name}, to out_path."""
    lib = hub_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    lib.agora_area_lookup(h, b"extern_to_at", b"look", area.encode())
    cards = []

    def want(ev):
        if ev.kind != EV_AREA:
            return None
        if ev.fc_kind == AREA_CARD:
            cards.append({"uuid": bytes(ev.peer_uuid).hex(), "bucket": ev.area_bucket.decode(),
                          "name": ev.area_name.decode()})
        return ev.fc_count if ev.fc_kind == AREA_DONE else None
    n = _take_events(lib, h, timeout, want)
    lib.agora_events_close(h)
    json.dump(cards, open(out_path, "w"))
    print(f"lookup {area}: done={n} cards={[(c['name'], c['bucket']) for c in cards]}")
    return 0 if n is not None else 5


def cmd_ask(shim, root, area, uuid_hex, timeout):
    lib = hub_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    u = (ctypes.c_uint8 * 16)(*bytes.fromhex(uuid_hex))
    lib.agora_area_request(h, b"extern_to_at", b"ask", area.encode(), u)
    got = _take_events(lib, h, timeout, lambda ev: ev.fc_kind
                       if ev.kind == EV_CONTACT and ev.fc_kind in (DIR_REQUEST_SENT, 1010) else None)
    lib.agora_events_close(h)
    print(f"ask {uuid_hex[:8]}: {'sent' if got == DIR_REQUEST_SENT else got}")
    return 0 if got == DIR_REQUEST_SENT else 5


def cmd_answer(shim, root, want_handle, timeout):
    """Wait for a contact request found by `want_handle`, and accept it."""
    lib = hub_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    req = _take_events(lib, h, timeout, lambda ev: (ev.fc_ref.decode(), ev.fc_handle.decode(),
                                                    bytes(ev.peer_uuid).hex())
                       if ev.kind == EV_CONTACT and ev.fc_kind == DIR_CONTACT_REQUEST else None)
    if req is None:
        lib.agora_events_close(h)
        print("answer: no contact request arrived", file=sys.stderr)
        return 5
    print(f"answer: {req[2][:8]} asks, found us via {req[1]}")
    if req[1] != want_handle:
        lib.agora_events_close(h)
        return 6
    lib.agora_contact_accept(h, b"extern_to_at", req[0].encode())
    lib.agora_events_close(h)
    return 0


def cmd_await_established(shim, root, uuid_hex, timeout):
    lib = hub_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    got = _take_events(lib, h, timeout, lambda ev: True
                       if ev.kind == EV_CONTACT and ev.fc_kind == FC_ESTABLISHED
                       and bytes(ev.peer_uuid).hex() == uuid_hex else None)
    lib.agora_events_close(h)
    print(f"established with {uuid_hex[:8]}: {bool(got)}")
    return 0 if got else 5


def cmd_dm(shim, root, uuid_hex, text, timeout):
    lib = hub_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    u = (ctypes.c_uint8 * 16)(*bytes.fromhex(uuid_hex))
    rc = lib.agora_send_dm(h, b"extern_to_at", u, text.encode())
    lib.agora_events_close(h)
    return 0 if rc == 0 else 4


def cmd_await_dm(shim, root, text, timeout):
    lib = hub_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        return 2
    got = _take_events(lib, h, timeout, lambda ev: True
                       if ev.kind == EV_DM and ev.dm_text.decode() == text else None)
    lib.agora_events_close(h)
    return 0 if got else 5


def cmd_never_peer(shim, root, uuid_hex, seconds):
    """0 if `uuid_hex` never appears as a peer within `seconds`."""
    lib = hub_lib(shim, root)
    h = connect(lib, seconds)
    if not h:
        return 2
    deadline = time.time() + seconds
    seen = False
    cap = 64
    buf = (Ev * cap)()
    while time.time() < deadline and not seen:
        lib.agora_events_request_roster(h, b"extern_to_at")
        for ev in drain(lib, h, buf, cap, deadline):
            if ev.kind == EV_PEER and bytes(ev.peer_uuid).hex() == uuid_hex:
                seen = True
        time.sleep(1.0)
    lib.agora_events_close(h)
    return 5 if seen else 0


def cmd_peers(shim, root, want, timeout):
    lib = hub_lib(shim, root)
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
    return 0 if len(seen) >= want else 5


def main(a):
    v = a[1]
    if v == "mint":
        return cmd_mint(a[2], a[3], a[4])
    if v == "sign":
        return cmd_sign(a[2], a[3])
    if v == "uuid":
        print(identity(a[2])["uuid"].replace("-", "").lower())
        return 0
    shim, root = a[2], a[3]
    t = float(a[-1]) if a[-1].replace(".", "").isdigit() else 60.0
    if v == "follow":
        return cmd_follow(shim, root, a[4], t)
    if v == "await-policy":
        return cmd_await_policy(shim, root, a[4], float(a[5]), a[6])
    if v == "list":
        return cmd_list(shim, root, a[4], a[5], a[6], float(a[7]), a[8] if len(a) > 8 else "")
    if v == "withdraw":
        return cmd_withdraw(shim, root, a[4], t)
    if v == "lookup":
        return cmd_lookup(shim, root, a[4], float(a[5]), a[6])
    if v == "ask":
        return cmd_ask(shim, root, a[4], a[5], t)
    if v == "answer":
        return cmd_answer(shim, root, a[4], t)
    if v == "await-established":
        return cmd_await_established(shim, root, a[4], t)
    if v == "dm":
        return cmd_dm(shim, root, a[4], a[5], t)
    if v == "await-dm":
        return cmd_await_dm(shim, root, a[4], t)
    if v == "never-peer":
        return cmd_never_peer(shim, root, a[4], t)
    if v == "peers":
        return cmd_peers(shim, root, int(a[4]), t)
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
  AREA="$AREA" ETHNE="$ETHNE" LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    python3 "$DRIVER" "$verb" "$SHIM" "${ROOT[$n]}" "$@"
}
tool() { # verb args...  (no node, no queue)
  AREA="$AREA" ETHNE="$ETHNE" python3 "$DRIVER" "$@"
}
saw() { grep -q "$2" "${ROOT[$1]}/agorad.log" 2>/dev/null; }
fail() { err "FAIL ($1) — $2"; dump_logs; exit 1; }

# --------------------------------------------------------------------------- #
# Phase 1 — two islands
# --------------------------------------------------------------------------- #
log "Phase 1: starting the hub, then keeper+ann on A and bob+eve on B"
node_start hub AT_RELAY=1 AT_RELAY_PORT="$RELAY_PORT" AT_HUB=1 AT_HUB_AREAS="$AREA"
sleep 3
kill -0 "${PID[hub]}" 2>/dev/null || fail "phase 1" "the hub died at start"
deadline=$(( SECONDS + WAIT ))
until saw hub "Hub: serving area" || [ "$SECONDS" -ge "$deadline" ]; do sleep 1; done
saw hub "Hub: serving area(s) $AREA" || fail "phase 1" "the hub does not serve $AREA"
for n in keeper ann bob eve; do
  node_start "$n"; sleep 3
  kill -0 "${PID[$n]}" 2>/dev/null || fail "phase 1" "$n died at start"
done
drive ann peers 1 "$WAIT" || fail "phase 1" "ann never discovered keeper"
drive bob peers 1 "$WAIT" || fail "phase 1" "bob never discovered eve"
ANN="$(tool uuid "${ROOT[ann]}")"; BOB="$(tool uuid "${ROOT[bob]}")"
drive bob never-peer "$ANN" 20 || fail "phase 1" "bob discovered ann: the islands leak"
ok "phase 1: two islands, and bob does not know ann exists"

# --------------------------------------------------------------------------- #
# Phase 2 — the roll seats a hub; its roster travels inside the policy
# --------------------------------------------------------------------------- #
log "Phase 2: the roll seats the hub; keeper mints the policy with the roster inside"
DID="$(tool mint "$STATE" "${ROOT[hub]}" "$RELAY_PORT")" || fail "phase 2" "could not mint the polity"
tool sign "$STATE" "$RUN/policy.json" || fail "phase 2" "the policy does not carry the hub"
drive ann await-policy "$DID" "$WAIT" "$RUN/ann-policy.json" &
AW=$!
sleep 2
drive keeper follow "$RUN/policy.json" "$WAIT" || fail "phase 2" "keeper could not follow its own policy"
wait "$AW" || fail "phase 2" "the policy never reached ann over her group"
drive ann follow "$RUN/ann-policy.json" "$WAIT" || fail "phase 2" "ann could not follow and install the roster"
for n in bob eve; do
  drive "$n" follow "$RUN/policy.json" "$WAIT" || fail "phase 2" "$n could not follow and install the roster"
done
for n in ann bob eve; do
  deadline=$(( SECONDS + WAIT ))
  until saw "$n" "Relay: registered with" || [ "$SECONDS" -ge "$deadline" ]; do sleep 1; done
  saw "$n" "Relay: registered with" || fail "phase 2" "$n never registered with the hub"
done
ok "phase 2: the roster rode the policy; ann, bob and eve are registered with the hub"

# --------------------------------------------------------------------------- #
# Phase 3 — opt-in listings
# --------------------------------------------------------------------------- #
log "Phase 3: ann and bob list themselves in $AREA; eve does not"
drive ann list "$AREA" u4pru "Ann" "$WAIT" || fail "phase 3" "the hub never listed ann"
drive bob list "$AREA" u4prv "Bob" "$WAIT" || fail "phase 3" "the hub never listed bob"
ok "phase 3: ann and bob are listed; eve is not"

# --------------------------------------------------------------------------- #
# Phase 4 — reciprocal lookups
# --------------------------------------------------------------------------- #
log "Phase 4: lookups"
drive bob lookup "$AREA" "$WAIT" "$RUN/bob-look.json" || fail "phase 4" "bob's lookup never finished"
python3 - "$RUN/bob-look.json" "$ANN" <<'CHK' || fail "phase 4" "bob's lookup did not find ann"
import json, sys
cards, ann = json.load(open(sys.argv[1])), sys.argv[2]
assert [c["uuid"] for c in cards] == [ann], cards
assert cards[0]["bucket"] == "u4pru" and cards[0]["name"] == "Ann", cards
CHK
drive ann lookup "$AREA" "$WAIT" "$RUN/ann-look.json" || fail "phase 4" "ann's lookup never finished"
python3 -c "import json,sys;c=json.load(open(sys.argv[1]));assert [x['uuid'] for x in c]==[sys.argv[2]],c" \
  "$RUN/ann-look.json" "$BOB" || fail "phase 4" "ann's lookup did not find bob"
drive eve lookup "$AREA" "$WAIT" "$RUN/eve-look.json" || fail "phase 4" "eve's lookup never finished"
python3 -c "import json,sys;c=json.load(open(sys.argv[1]));assert c==[],c" "$RUN/eve-look.json" \
  || fail "phase 4" "eve, who is not listed, saw who is"
ok "phase 4: bob finds ann, ann finds bob, and eve finds nobody"

# --------------------------------------------------------------------------- #
# Phase 5 — the hub's area is the only area
# --------------------------------------------------------------------------- #
log "Phase 5: bob tries to list in an area the hub does not serve"
drive bob list gcpv gcpvj "Bob" 30 area || fail "phase 5" "a listing outside the hub's area was not refused"
ok "phase 5: refused ('area')"

# --------------------------------------------------------------------------- #
# Phase 6 — finding is not adding
# --------------------------------------------------------------------------- #
log "Phase 6: bob asks ann; ann's app accepts"
drive ann answer "area:$AREA" "$WAIT" &
AN=$!
sleep 2
drive bob ask "$AREA" "$ANN" "$WAIT" || fail "phase 6" "bob's request was not sent"
wait "$AN" || fail "phase 6" "ann's app never got the request, or not via area:$AREA"
drive bob await-established "$ANN" "$WAIT" & E1=$!
drive ann await-established "$BOB" "$WAIT" & E2=$!
wait "$E1" || fail "phase 6" "bob never completed the handshake"
wait "$E2" || fail "phase 6" "ann never completed the handshake"
drive ann await-dm "hello from across town" "$WAIT" &
DM=$!
sleep 2
drive bob dm "$ANN" "hello from across town" "$WAIT" || fail "phase 6" "bob could not send the DM"
wait "$DM" || fail "phase 6" "the DM never crossed to ann"
ok "phase 6: requested, accepted, established as direct peers, and a DM crossed"

# --------------------------------------------------------------------------- #
# Phase 7 — opting out takes effect at once
# --------------------------------------------------------------------------- #
log "Phase 7: ann withdraws"
drive ann withdraw "$AREA" "$WAIT" || fail "phase 7" "the hub never confirmed ann's withdrawal"
drive bob lookup "$AREA" "$WAIT" "$RUN/bob-look2.json" || fail "phase 7" "bob's lookup never finished"
python3 -c "import json,sys;c=json.load(open(sys.argv[1]));assert c==[],c" "$RUN/bob-look2.json" \
  || fail "phase 7" "ann is still listed after withdrawing"
ok "phase 7: ann is no longer listed"

log "PASS: hub_cohort — two islands met at their community's hub, by choice"
exit 0
