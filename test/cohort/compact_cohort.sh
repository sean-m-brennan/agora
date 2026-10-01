#!/usr/bin/env bash
#
# compact_cohort.sh — Phase 5 live check: communities federate through a
# kith-covenant compact, over the wire, by detached co-signing, and a reader
# sees and acts on how they stand with each other (SOCIAL_APP_PLAN Phase 5;
# Ethne D39, D40).
#
# Five real agorad nodes on one virtual L2 segment (bridge + netns), driven
# through the real app-event queues. The driver plays the app: it holds each
# community's charter log, keeps each governance node's KC replica, and mints,
# signs and verifies every artifact through the REAL Ethne cdylib — the calls
# Agora's CompactEngine makes. No private key leaves its node: bytes travel by
# co-sign ask, signatures come back.
#
#   agov   — Alpha's governance node: its root key and its envoy (m0)
#   awit   — Alpha's second member (m2) on its own device: Alpha's Inductor,
#            who recites Alpha's KC rite, and later a seated examiner
#   bgov   — Beta's governance node (envoy m0; its Inductor is local)
#   cgov   — Gamma's governance node (likewise)
#   reader — follows nothing to begin with; hears every view and policy
#
# What it proves, in order:
#   1. Discovery; each community seals its KC rite. Alpha's recitation is signed
#      by its Inductor on awit (kc_attest/recite), never by the envoy: KC holds
#      one delegation per speaker, so the envoy cannot also be the Inductor.
#   2. THE ROLL JOINS AND THE COMPACT IS FOUNDED. Each roll decides Join (D40);
#      the envoys present the five anti-spiral claims, accept each other's, and
#      co-sign the seal from a CBOR manifest each replica rebuilds. Both
#      replicas read the other as in_compact, and the reader holds Alpha's
#      signed view saying so.
#   3. A THIRD IS SPONSORED, EXAMINED AND ADMITTED. Gamma's roll joins, Alpha's
#      sponsors, both sitting rolls admit; Alpha seats m0 + m2 (on awit) and Beta
#      m0 as examiners, a panel of 3 from 2 communities. Alpha relays its whole
#      replica to awit so it can rebuild the seal it signs. Four signatures land
#      the seal; every replica reads Gamma as probationary, as does the view.
#   4. TWO COMMUNITIES ANATHEMATIZE A THIRD. Both rolls decide at majority + 1;
#      Alpha drafts a SecondClass conduct record, Beta co-signs; Gamma is
#      anathema in every replica and in Alpha's view.
#   5. A POLICY HIDES BY STANDING (D39). Alpha's policy hides posts made in an
#      anathematized community's name. Gamma posts; the reader receives the post
#      and, under Alpha's policy and Alpha's view, the verdict is Hide; a post in
#      Beta's name is Allowed.
#   6. A VIEW IS ITS COMMUNITY'S WORD. A view edited after signing does not
#      verify, and Alpha's older view, offered again, does not replace the newer.
#
# WHAT THIS DELIBERATELY DOES NOT TEST: reach (compact-mates' businesses and the
# "In compact with your communities" card) and the badges, which are app-side
# reads of the same view and are pinned by test/compact_test.dart; a refused
# ceremony (Denied), pinned in-process by native/ethne_ffi's kc tests and the
# Ethne recognition_handoff example.
#
# NETNS ONLY. Requirements: root + iproute2, python3, and the built native
# layer + ethne cdylib (./build.sh).
#
# Usage:
#   sudo -E env "PATH=$PATH" ./test/cohort/compact_cohort.sh
#   WAIT=180 KEEP=1 ./test/cohort/compact_cohort.sh
#
# Env knobs: WAIT (per-phase timeout, default 180), POLICY_SEC (policy and view
#   re-carry interval, default 10), SUBNET (default 10.9.11), LOG_LEVEL (1 DEBUG,
#   2 INFO), KEEP=1.

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

WAIT="${WAIT:-180}"
POLICY_SEC="${POLICY_SEC:-10}"
LOG_LEVEL="${LOG_LEVEL:-2}"
SUBNET="${SUBNET:-10.9.11}"
GEO="${GEO:-u4pruy}"
PREFIX=24
COMPACT=river

NODES=(agov awit bgov cgov reader)
declare -A IP NS V VB ROOT PID APID
i=11
for n in "${NODES[@]}"; do
  IP[$n]="$SUBNET.$i"; NS[$n]="agk$n"; V[$n]="agk${n:0:4}"; VB[$n]="agk${n:0:4}b"
  i=$(( i + 1 ))
done
BR=agbr11

# A short tag: the node socket paths under it must fit 108 bytes.
RUN="${AGORA_COHORT_RUN:-$AGORA_DIR/.coh/kc-$$}"
for n in "${NODES[@]}"; do ROOT[$n]="$RUN/$n"; PID[$n]=""; APID[$n]=""; mkdir -p "${ROOT[$n]}"; done

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
    ip netns exec "${NS[agov]}" ping -c1 -W2 "${IP[$n]}" >/dev/null 2>&1 \
      || { err "no L2 path from agov to $n"; return 1; }
  done
  log "L2 segment ready"
}

node_start() { # name
  local n="$1"
  ip netns exec "${NS[$n]}" env \
    AUTONOMOUS_TRUST_ROOT="${ROOT[$n]}" \
    AT_PEER_NAME="$n" AT_PEER_SEED="compact-$n" \
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

agent_stop() { # name
  [ -z "${APID[$1]}" ] && return 0
  kill "${APID[$1]}" 2>/dev/null; sleep 0.5; kill -9 "${APID[$1]}" 2>/dev/null
  APID[$1]=""
}

dump_logs() {
  local n
  for n in "${NODES[@]}"; do
    [ -f "${ROOT[$n]}/agorad.log" ] || continue
    echo "--- $n ---"
    tail -n 30 "${ROOT[$n]}/agorad.log"
    [ -f "$RUN/$n.agent.log" ] && { echo "--- $n (app) ---"; tail -n 30 "$RUN/$n.agent.log"; }
  done
}

cleanup() {
  local rc="${1:-0}" n
  for n in "${NODES[@]}"; do agent_stop "$n"; node_stop "$n"; done
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
# The app-side driver. The ctypes Ev mirror, connect(), drain() and open_lib()
# are SPLICED VERBATIM out of hub_cohort.sh (the Ev mirror carries the ABI
# guard). The Agent class is the Python twin of lib/src/node/compact_engine.dart.
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


# --- kith-covenant (Phase 5) --------------------------------------------------

EV_POST, EV_POLICY, EV_COSIGN_REQ, EV_COSIGN_SIG = 9, 16, 13, 14
Q = b"extern_to_at"


class Ethne:
    """The Ethne cdylib, as the app calls it: the charter log and the KC border."""

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
        lib.ethne_archive_free.argtypes = [vp]
        lib.ethne_verify.argtypes = [vp]
        for fn in ("ethne_found_polity", "ethne_amend_content_policy", "ethne_confer_office",
                   "ethne_authorize_envoy", "ethne_assemble"):
            getattr(lib, fn).argtypes = [vp, cp]
        for fn in ("ethne_pending", "ethne_content_policy_sign", "ethne_kc_conduct_draft",
                   "ethne_recite_movement"):
            getattr(lib, fn).argtypes = [vp, cp, out]
        for fn in ("ethne_sign_detached", "ethne_content_policy_verify", "ethne_compact_view_verify",
                   "ethne_compact_standing_verdict", "ethne_kc_receipt_sign"):
            getattr(lib, fn).argtypes = [cp, out]
        lib.ethne_kc_receipt_verify.argtypes = [cp]
        lib.ethne_kc_new.restype = vp
        lib.ethne_kc_load_json.argtypes = [cp]; lib.ethne_kc_load_json.restype = vp
        lib.ethne_kc_dump_json.argtypes = [vp, out]
        lib.ethne_kc_free.argtypes = [vp]
        for fn in ("ethne_kc_border", "ethne_kc_rite_draft", "ethne_kc_claims", "ethne_kc_verdicts",
                   "ethne_kc_sponsor", "ethne_kc_seal_sign", "ethne_kc_conduct_sign"):
            getattr(lib, fn).argtypes = [vp, vp, cp, out]
        for fn in ("ethne_kc_rite_seal", "ethne_kc_examiners", "ethne_kc_seal_draft", "ethne_kc_seal_assemble",
                   "ethne_kc_seal_ingest", "ethne_kc_conduct_assemble", "ethne_kc_ingest", "ethne_kc_view_sign",
                   "ethne_kc_standing", "ethne_kc_deliveries"):
            getattr(lib, fn).argtypes = [vp, cp, out]
        self.lib = lib

    def err(self):
        return (self.lib.ethne_last_error() or b"").decode(errors="replace")

    def call_out(self, fn, *args):
        out = ctypes.c_char_p()
        rc = getattr(self.lib, fn)(*args, ctypes.byref(out))
        if rc != 0:
            raise RuntimeError(f"{fn}: {self.err()}")
        s = ctypes.cast(out, ctypes.c_char_p).value.decode()
        self.lib.ethne_string_free(out)
        return s

    def j(self, fn, *args):
        """Call with JSON-encoded trailing spec, decode the JSON answer."""
        *head, spec = args
        enc = spec if isinstance(spec, bytes) else (spec.encode() if isinstance(spec, str) else json.dumps(spec).encode())
        return json.loads(self.call_out(fn, *head, enc))

    def spec(self, fn, arc, spec):
        if getattr(self.lib, fn)(arc, json.dumps(spec).encode()) != 0:
            raise RuntimeError(f"{fn}: {self.err()}")

    def keypair(self):
        return json.loads(self.call_out("ethne_keypair_generate"))

    def sign(self, priv, bytes_hex):
        return self.call_out("ethne_sign_detached", json.dumps({"priv": priv, "bytes": bytes_hex}).encode())


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
    tmp = path + ".tmp"
    json.dump(st, open(tmp, "w"))
    os.replace(tmp, path)


def cosigned(e, arc, members, spec):
    """A roll act on the detached co-signing path, every named signer signing the
    exported bytes: the same classes Agora's app uses."""
    p = e.j("ethne_pending", arc, spec)
    keys = {m["did"]: m["priv"] for m in members}
    sigs = [{"did": d, "sig": e.sign(keys[d], p["bytes"])} for d in p["signers_required"]]
    e.spec("ethne_assemble", arc, {"record": p["record"], "payload": p["payload"], "signatures": sigs})


MOVEMENTS = lambda name: [{"Substrate": {"names": name}}, "Fallenness", "Recognition",
                          {"CommonVirtue": {"commits_to": ["mutual-aid"]}}, {"NonUltimacy": {"names_anchor": None}}]


def cmd_found(state, name):
    """Found a three-member community: m0 is the envoy (its governance member) and
    m2 the Inductor, who recites the KC rite: KC holds one delegation per speaker,
    so the envoy is never the Inductor. Every member recites the five movements
    with the others attending."""
    e = Ethne()
    root = e.keypair()
    m = [e.keypair() for _ in range(3)]
    arc = e.lib.ethne_archive_new()
    sub = f"{name}-substrate"
    e.spec("ethne_found_polity", arc, {
        "polity_did": root["did"], "name": sub, "statement": "the ground we did not make",
        "members": [k["did"] for k in m], "ratifiers": [signer(k) for k in m],
        "commitments": [{"key": "mutual-aid", "description": "we answer for one another"}]})
    e.spec("ethne_authorize_envoy", arc, {
        "polity_did": root["did"], "envoy_did": m[0]["did"], "authorizers": [signer(m[0]), signer(m[1])],
        "envoy_priv": m[0]["priv"]})
    e.spec("ethne_confer_office", arc, {
        "polity_did": root["did"], "office": "Inductor", "holder_did": m[2]["did"], "holder_priv": m[2]["priv"],
        "deciders": [signer(m[0]), signer(m[1])]})
    # m1 recites last, so the attendees of the last complete rite less the Inductor
    # (m2) are m0: the envoy witnesses, and the Inductor recites from its own device.
    for me in (m[0], m[2], m[1]):
        others = [k["did"] for k in m if k is not me]
        cids = []
        for mv in MOVEMENTS(sub):
            # The affirmation cites each movement by its charter entry, which only
            # the recital returns.
            cids.append(e.call_out("ethne_recite_movement", arc, json.dumps({
                "polity_did": root["did"], "member": signer(me), "kind": "ReAffirmation", "movement": mv,
                "statement": "as we received it",
                "attending": [signer(k) for k in m if k is not me]}).encode()))
            time.sleep(1.05)  # one movement a second: a rite recites in order
        cosigned(e, arc, m, {"record": "rite", "op": "affirm", "polity_did": root["did"], "member_did": "",
                             "body": {"polity": root["did"], "member": me["did"], "kind": "ReAffirmation",
                                      "witnesses": others, "movements": cids}})
    if e.lib.ethne_verify(arc) != 0:
        print("found: the log does not verify: " + e.err(), file=sys.stderr)
        return 3
    save_state(state, {"name": name, "root": root, "members": m}, arc, e)
    print(root["did"])
    return 0


def cmd_decide(state, kind, compact, others_csv, probation):
    """The roll decides a compact act; all three members decide (enough for the
    acts that need more than a majority)."""
    e = Ethne()
    st, arc = load_state(state, e)
    did = st["root"]["did"]
    op = "anathema" if kind == "Anathematize" else kind.lower()
    body = {"polity": did, "kind": kind, "compact": compact, "counterparties": others_csv.split(","),
            "rationale": f"the roll decides to {op}", "deciders": [k["did"] for k in st["members"]]}
    if kind == "Sponsor":
        body["probation_days"] = int(probation)
    cosigned(e, arc, st["members"], {"record": "compact", "op": op, "polity_did": did, "member_did": "",
                                     "body": body})
    if e.lib.ethne_verify(arc) != 0:
        print("decide: the log does not verify: " + e.err(), file=sys.stderr)
        return 3
    save_state(state, st, arc, e)
    return 0


def cmd_policy(state, out):
    """Hide posts made in an anathematized community's name (D39), at a majority."""
    e = Ethne()
    st, arc = load_state(state, e)
    did = st["root"]["did"]
    e.spec("ethne_amend_content_policy", arc, {
        "polity_did": did, "rationale": "we will not carry the anathematized",
        "policy": {"operator_bound_required": False, "min_tier": 0, "daily_post_cap": None, "labels": {},
                   "standing": {"Anathema": "Hide"}},
        "deciders": [signer(st["members"][0]), signer(st["members"][1])]})
    save_state(state, st, arc, e)
    bundle = e.call_out("ethne_content_policy_sign", arc, json.dumps(
        {"polity_did": did, "root_priv": st["root"]["priv"]}).encode())
    open(out, "w").write(bundle)
    return 0


def kc_lib(shim, root):
    lib = open_lib(shim, root)
    vp, cp, u8p = ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint8)
    lib.agora_request_cosign.argtypes = [vp, cp, u8p, ctypes.c_int, cp, cp, cp, cp, cp]
    lib.agora_return_cosign.argtypes = [vp, cp, u8p, cp, cp, cp]
    lib.agora_follow_community.argtypes = [vp, cp, cp, cp, ctypes.c_int64]
    lib.agora_publish_post_scoped.argtypes = [vp, cp, cp, ctypes.c_int, cp, cp]
    return lib


class Agent:
    """One node's app, as far as compacts go: the twin of Agora's CompactEngine."""

    def __init__(self, shim, root, role, state, member, nodes_path):
        self.e = Ethne()
        self.root, self.role, self.state_path, self.member = root, role, state, member
        self.nodes_path = nodes_path
        self.lib = kc_lib(shim, root)
        self.h = connect(self.lib, 60)
        if not self.h:
            raise SystemExit("no app-event channel")
        self.own = identity(root)["uuid"].replace("-", "").lower()
        self.st, self.arc = (load_state(state, self.e) if state else (None, None))
        self.did = self.st["root"]["did"] if self.st else ""
        self.self_kp = self.st["members"][member] if self.st else None
        kcp = os.path.join(root, "kc.json")
        self.kc = self.e.lib.ethne_kc_load_json(open(kcp).read().encode()) if os.path.exists(kcp) else self.e.lib.ethne_kc_new()
        self.outbox = {}          # cid -> {record, op, hex, to: {node: acked}}
        self.seals, self.conducts, self.rite = {}, {}, None
        self.examiner_nodes = []
        self.view_stale = role == "gov"
        self.heard = {"policies": {}, "views": [], "posts": []}
        self.cap = 64
        self.buf = (Ev * self.cap)()

    # -- plumbing --------------------------------------------------------
    def nodes(self):
        return json.load(open(self.nodes_path))

    def node_of(self, did):
        for c in self.nodes().values():
            if c["did"] == did:
                return c["gov"]
        return None

    def recipients(self):
        out = []
        for c in self.nodes().values():
            if c["did"] != self.did and c.get("gov"):
                out.append(c["gov"])
        out += [n for n in self.examiner_nodes if n != self.own]
        return [n for n in dict.fromkeys(out) if n != self.own]

    def ask(self, nodes, record, op, cid, hex_):
        if not nodes:
            return
        arr = (ctypes.c_uint8 * (16 * len(nodes)))(*b"".join(bytes.fromhex(n) for n in nodes))
        self.lib.agora_request_cosign(self.h, Q, arr, len(nodes), record.encode(), op.encode(),
                                      self.did.encode(), cid.encode(), hex_.encode())

    def answer(self, node, cid, signer_did, sig):
        u = (ctypes.c_uint8 * 16)(*bytes.fromhex(node))
        self.lib.agora_return_cosign(self.h, Q, u, cid.encode(), signer_did.encode(), sig.encode())

    def queue(self, record, op, cid, hex_):
        o = self.outbox.setdefault(cid, {"record": record, "op": op, "hex": hex_, "to": {}})
        for n in self.recipients():
            o["to"].setdefault(n, False)
        self.ask([n for n, ok in o["to"].items() if not ok], record, op, cid, hex_)

    def widen(self):
        """Give a recipient that is new (a seated examiner's node, an entrant)
        every delivery it missed, now rather than at the next resend."""
        for cid, o in self.outbox.items():
            new = [n for n in self.recipients() if n not in o["to"]]
            for n in new:
                o["to"][n] = False
            self.ask(new, o["record"], o["op"], cid, o["hex"])

    def relay(self):
        """Hand this community's examiners' nodes everything the replica holds,
        other communities' records included: they rebuild every seal they sign."""
        if not self.examiner_nodes:
            return
        for d in self.e.j("ethne_kc_deliveries", self.kc, {})["deliveries"]:
            o = self.outbox.setdefault(d["cid"], {"record": d["record"], "op": d["op"], "hex": d["hex"], "to": {}})
            fresh = [n for n in self.examiner_nodes if n != self.own and n not in o["to"]]
            for n in fresh:
                o["to"][n] = False
            self.ask(fresh, o["record"], o["op"], d["cid"], o["hex"])

    def deliver(self, out):
        for d in out.get("deliveries", []):
            self.queue("kc_record", "deliver", d["cid"], d["hex"])
        self.view_stale = True
        self.save()

    def save(self):
        open(os.path.join(self.root, "kc.json"), "w").write(self.e.call_out("ethne_kc_dump_json", self.kc))
        json.dump(self.heard, open(os.path.join(self.root, "heard.json"), "w"))

    def receipt(self, cid):
        return self.e.call_out("ethne_kc_receipt_sign", json.dumps({"cid": cid, "priv": self.self_kp["priv"]}).encode())

    def standing(self, did):
        return self.e.j("ethne_kc_standing", self.kc, did)["standing"]

    # -- what arrives ----------------------------------------------------
    def on_request(self, ev):
        rec, op = ev.cosign_record.decode(), ev.cosign_op.decode()
        cid, b = ev.cosign_cid.decode(), ev.cosign_bytes.decode()
        frm = bytes(ev.peer_uuid).hex()
        try:
            if (rec, op) == ("kc_record", "deliver"):
                self.e.call_out("ethne_kc_ingest", self.kc, b.encode())
                self.relay()
                self.view_stale = True
                self.save()
                self.answer(frm, cid, self.self_kp["did"], self.receipt(cid))
            elif (rec, op) == ("kc_seal", "sealed"):
                self.e.call_out("ethne_kc_seal_ingest", self.kc, b.encode())
                self.relay()
                self.view_stale = True
                self.save()
                self.answer(frm, cid, self.self_kp["did"], self.receipt(cid))
            elif (rec, op) == ("kc_seal", "sign"):
                r = self.e.j("ethne_kc_seal_sign", self.arc, self.kc, {
                    "manifest": b, "polity_did": self.did, "signer_did": self.self_kp["did"],
                    "signer_priv": self.self_kp["priv"]})
                self.answer(frm, cid, self.self_kp["did"], r["sig"])
            elif (rec, op) == ("kc_conduct", "sign"):
                r = self.e.j("ethne_kc_conduct_sign", self.arc, self.kc, {
                    "polity_did": self.did, "compact": COMPACT, "bytes": b, "envoy_priv": self.self_kp["priv"]})
                self.answer(frm, cid, r["did"], r["sig"])
            elif rec == "kc_attest" and op in ("attest", "recite"):
                self.answer(frm, cid, self.self_kp["did"], self.e.sign(self.self_kp["priv"], b))
            print(f"[{self.role}] answered {rec}/{op} {cid[:16]}", flush=True)
        except RuntimeError as err:
            print(f"[{self.role}] {rec}/{op} {cid[:16]}: {err}", flush=True)

    def on_signature(self, ev):
        cid, signer, sig = ev.cosign_cid.decode(), ev.cosign_signer_did.decode(), ev.cosign_sig.decode()
        frm = bytes(ev.peer_uuid).hex()
        if cid in self.outbox:
            if self.e.lib.ethne_kc_receipt_verify(json.dumps({"cid": cid, "did": signer, "sig": sig}).encode()) == 0:
                self.outbox[cid]["to"][frm] = True
            return
        if cid in self.seals:
            s = self.seals[cid]
            s["sigs"][signer] = sig
            self.try_seal(s)
            return
        if cid in self.conducts:
            c = self.conducts[cid]
            c["sigs"][signer] = sig
            if not c.get("landed") and len(c["sigs"]) >= len(c["reporters"]):
                out = self.e.j("ethne_kc_conduct_assemble", self.kc, {
                    "payload": c["payload"], "signatures": [{"did": d, "sig": g} for d, g in c["sigs"].items()]})
                c["landed"] = True
                self.deliver(out)
            return
        if self.rite and cid.startswith("recite:") and signer == self.rite["inductor"]:
            self.rite["recitation_sig"] = sig
            self.try_rite()
            return
        if self.rite and cid.startswith("attest:"):
            for a in self.rite["attest"]:
                if a["witness_did"] == signer:
                    self.rite["sigs"][signer] = sig
            self.try_rite()

    def try_seal(self, s):
        if s.get("landed"):
            return
        try:
            out = self.e.j("ethne_kc_seal_assemble", self.kc, {
                "manifest": s["manifest"], "signatures": [{"did": d, "sig": g} for d, g in s["sigs"].items()]})
        except RuntimeError as err:
            print(f"[{self.role}] seal not yet: {err}", flush=True)
            return
        s["landed"] = True
        print(f"[{self.role}] seal {out['cid'][:16]} landed with {len(s['sigs'])} signatures", flush=True)
        self.queue("kc_seal", "sealed", out["cid"], out["sealed"])
        self.view_stale = True
        self.save()

    def try_rite(self):
        r = self.rite
        if not r or not r["recitation_sig"] or any(a["witness_did"] not in r["sigs"] for a in r["attest"]):
            return
        out = self.e.j("ethne_kc_rite_seal", self.kc, {
            "polity_did": self.did, "root_priv": self.st["root"]["priv"], "recitation": r["recitation"],
            "recitation_sig": {"did": r["inductor"], "sig": r["recitation_sig"]},
            "attestations": [{"payload": a["payload"], "sig": r["sigs"][a["witness_did"]]} for a in r["attest"]],
            "at": r["at"]})
        self.rite = None
        print(f"[{self.role}] rite sealed", flush=True)
        self.deliver(out)

    def hear_view(self, v, bundle):
        """Keep a view only when it is newer than every one held for its community
        (CompactBook.hear's rule): an older view never replaces a newer."""
        held = [x["seq"] for x in self.heard["views"] if x["community_did"] == v["community_did"]]
        if held and max(held) >= v["seq"]:
            return False
        self.heard["views"].append({**v, "bundle": bundle})
        return True

    def on_policy(self, ev):
        key, bundle, seq = ev.policy_community.decode(), ev.policy_bundle.decode(), ev.policy_seq
        if key.endswith("#compact"):
            try:
                v = self.e.j("ethne_compact_view_verify", bundle)
            except RuntimeError:
                return
            if v["community_did"] != key[:-len("#compact")]:
                return
            self.hear_view(v, bundle)
        else:
            try:
                p = self.e.j("ethne_content_policy_verify", bundle)
            except RuntimeError:
                return
            held = self.heard["policies"].get(key)
            if held is None or held["seq"] < p["seq"]:
                self.heard["policies"][key] = {"seq": p["seq"], "bundle": bundle, "policy": p["policy"]}
        self.save()

    # -- commands --------------------------------------------------------
    def run(self, c):
        k = c["cmd"]
        if k == "reload":
            self.e.lib.ethne_archive_free(self.arc)
            self.st, self.arc = load_state(self.state_path, self.e)
            return {}
        if k == "cross":
            self.deliver(self.e.j("ethne_kc_border", self.arc, self.kc, {
                "polity_did": self.did, "root_priv": self.st["root"]["priv"], "envoy_did": self.self_kp["did"]}))
            inductor = self.st["members"][2]["did"]
            d = self.e.j("ethne_kc_rite_draft", self.arc, self.kc, {
                "polity_did": self.did, "root_priv": self.st["root"]["priv"], "inductor_did": inductor})
            self.deliver(d)
            r = {"recitation": d["recitation"], "attest": d["attest"], "at": d["at"], "sigs": {},
                 "inductor": inductor, "recitation_sig": None, "asks": []}
            local = {m["did"]: m["priv"] for i, m in enumerate(self.st["members"]) if i not in c.get("remote", [])}
            self.rite = r  # before any ask goes out: an answer may come back at once
            if inductor in local:
                r["recitation_sig"] = self.e.sign(local[inductor], d["recitation_bytes"])
            else:
                r["asks"].append([c.get("witness_nodes", []), "kc_attest", "recite", "recite:" + inductor[-16:],
                                  d["recitation_bytes"]])
            for a in d["attest"]:
                if a["witness_did"] in local:
                    r["sigs"][a["witness_did"]] = self.e.sign(local[a["witness_did"]], a["bytes"])
                else:
                    r["asks"].append([c.get("witness_nodes", []), "kc_attest", "attest",
                                      "attest:" + a["witness_did"][-16:], a["bytes"]])
            for x in r["asks"]:
                self.ask(*x)
            self.try_rite()
            return {"witnesses": len(d["attest"])}
        if k == "present":
            self.deliver(self.e.j("ethne_kc_claims", self.arc, self.kc, {
                "polity_did": self.did, "compact": COMPACT, "counterparties": c["counterparties"],
                "envoy_priv": self.self_kp["priv"]}))
            return {}
        if k == "accept":
            self.deliver(self.e.j("ethne_kc_verdicts", self.arc, self.kc, {
                "polity_did": self.did, "compact": COMPACT, "presenter": c["presenter"], "accepted": True,
                "envoy_priv": self.self_kp["priv"]}))
            return {}
        if k == "vouch":
            self.deliver(self.e.j("ethne_kc_sponsor", self.arc, self.kc, {
                "polity_did": self.did, "compact": COMPACT, "entrant": c["entrant"],
                "envoy_priv": self.self_kp["priv"]}))
            return {}
        if k == "seat":
            seats = [{"did": self.st["members"][i]["did"]} for i in c["members"]]
            self.examiner_nodes += c.get("nodes", [])
            self.relay()  # first: it sends seals after their parts
            self.widen()
            self.deliver(self.e.j("ethne_kc_examiners", self.kc, {
                "polity_did": self.did, "root_priv": self.st["root"]["priv"], "seats": seats, "days": 180}))
            return {}
        if k == "convene":
            d = self.e.j("ethne_kc_seal_draft", self.kc, {"compact": COMPACT, "participants": c["participants"]})
            mine = self.e.j("ethne_kc_seal_sign", self.arc, self.kc, {
                "manifest": d["manifest"], "polity_did": self.did, "signer_did": self.self_kp["did"],
                "signer_priv": self.self_kp["priv"]})
            s = {"manifest": d["manifest"], "sigs": {self.self_kp["did"]: mine["sig"]},
                 "ask": [c["signer_nodes"], "kc_seal", "sign", d["cid"], d["manifest"]]}
            self.seals[d["cid"]] = s
            self.ask(*s["ask"])
            self.try_seal(s)
            return {"kind": d["kind"], "cid": d["cid"], "manifest_hex": len(d["manifest"])}
        if k == "report":
            reporters = [self.did] + c["co"]
            d = self.e.j("ethne_kc_conduct_draft", self.arc, {
                "polity_did": self.did, "compact": COMPACT, "kind": "anathema", "reporters": reporters,
                "subject": c["subject"]})
            mine = self.e.j("ethne_kc_conduct_sign", self.arc, self.kc, {
                "polity_did": self.did, "compact": COMPACT, "payload": d["payload"],
                "envoy_priv": self.self_kp["priv"]})
            cd = {"payload": d["payload"], "reporters": reporters, "sigs": {mine["did"]: mine["sig"]},
                  "ask": [[self.node_of(x) for x in c["co"]], "kc_conduct", "sign", d["cid"], d["bytes"]]}
            self.conducts[d["cid"]] = cd
            self.ask(*cd["ask"])
            return {}
        if k == "carry_policy":
            bundle = open(c["bundle"]).read()
            p = self.e.j("ethne_content_policy_verify", bundle)
            self.lib.agora_follow_community(self.h, Q, self.did.encode(), bundle.encode(), p["seq"])
            return {"seq": p["seq"]}
        if k == "follow":
            pol = self.heard["policies"].get(c["did"])
            if pol is None:
                raise RuntimeError("no policy heard from that community yet")
            self.lib.agora_follow_community(self.h, Q, c["did"].encode(), pol["bundle"].encode(), pol["seq"])
            return {}
        if k == "post":
            self.lib.agora_publish_post_scoped(self.h, Q, c["body"].encode(), 0, self.did.encode(), b"")
            return {}
        if k == "status":
            out = {"unacked": sum(1 for o in self.outbox.values() if False in o["to"].values()),
                   "seals": {cid: s.get("landed", False) for cid, s in self.seals.items()},
                   "rite_pending": self.rite is not None}
            for name, cfg in self.nodes().items():
                out[f"standing_{name}"] = self.standing(cfg["did"])
            return out
        if k == "heard":
            return self.heard
        if k == "offer":
            # Hand the reader a view bundle as if it had arrived: taken or not.
            bundle = open(c["bundle"]).read()
            v = self.e.j("ethne_compact_view_verify", bundle)
            taken = self.hear_view(v, bundle)
            self.save()
            return {"taken": taken, "seq": v["seq"]}
        raise RuntimeError(f"unknown command {k}")

    def view(self):
        if not self.view_stale or self.role != "gov":
            return
        self.view_stale = False
        try:
            bundle = self.e.call_out("ethne_kc_view_sign", self.kc, json.dumps({
                "polity_did": self.did, "root_priv": self.st["root"]["priv"], "node": self.own}).encode())
            v = self.e.j("ethne_compact_view_verify", bundle)
            self.lib.agora_follow_community(self.h, Q, f"{self.did}#compact".encode(), bundle.encode(), v["seq"])
        except RuntimeError as err:
            print(f"[{self.role}] view: {err}", flush=True)

    def loop(self, cmd_dir, res_dir, seconds):
        deadline = time.time() + seconds
        last_resend = time.time()
        while time.time() < deadline:
            for ev in drain(self.lib, self.h, self.buf, self.cap, time.time() + 1):
                try:
                    if ev.kind == EV_COSIGN_REQ:
                        self.on_request(ev)
                    elif ev.kind == EV_COSIGN_SIG:
                        self.on_signature(ev)
                    elif ev.kind == EV_POLICY:
                        self.on_policy(ev)
                    elif ev.kind == EV_POST:
                        self.heard["posts"].append({"community": ev.post_community.decode(),
                                                    "body": ev.post_body.decode(errors="replace")})
                        self.save()
                except Exception as err:  # noqa: BLE001 - one bad event must not stop the app
                    print(f"[{self.role}] event kind {ev.kind}: {err!r}", flush=True)
            for name in sorted(os.listdir(cmd_dir)):
                path = os.path.join(cmd_dir, name)
                try:
                    c = json.load(open(path))
                except (ValueError, OSError):
                    continue
                os.remove(path)
                try:
                    res = {"ok": True, "result": self.run(c)}
                except Exception as err:  # noqa: BLE001 - report every failure to the phase
                    res = {"ok": False, "error": str(err)}
                tmp = os.path.join(res_dir, name + ".tmp")
                json.dump(res, open(tmp, "w"))
                os.replace(tmp, os.path.join(res_dir, name))
            if time.time() - last_resend > 3:
                last_resend = time.time()
                # A signer asked before its parts arrived refused; ask again until done.
                for s in self.seals.values():
                    if not s.get("landed") and s.get("ask"):
                        self.ask(*s["ask"])
                for cd in self.conducts.values():
                    if not cd.get("landed") and cd.get("ask"):
                        self.ask(*cd["ask"])
                if self.rite:
                    for x in self.rite.get("asks", []):
                        self.ask(*x)
                for cid, o in self.outbox.items():
                    for n in self.recipients():
                        o["to"].setdefault(n, False)
                    pending = [n for n, ok in o["to"].items() if not ok]
                    if pending:
                        self.ask(pending, o["record"], o["op"], cid, o["hex"])
            self.view()
            time.sleep(0.2)


def cmd_verdict(heard_path, community, post_community):
    """What the reader's followed community's policy does to a post made in
    `post_community`'s name, by that community's standing in its view (D39)."""
    e = Ethne()
    h = json.load(open(heard_path))
    pol = h["policies"][community]
    views = [v for v in h["views"] if v["community_did"] == community]
    view = max(views, key=lambda v: v["seq"])
    r = e.j("ethne_compact_standing_verdict", {"policy": pol["policy"], "view": view, "post_community": post_community})
    print(json.dumps(r))
    return 0


def cmd_forged(heard_path):
    """A view whose standings were edited after signing does not verify."""
    e = Ethne()
    h = json.load(open(heard_path))
    bundle = h["views"][-1]["bundle"]
    forged = bundle.replace("probationary", "in_compact").replace("anathema", "in_compact")
    if forged == bundle:
        forged = bundle.replace('"seq":', '"seq":9')
    try:
        e.j("ethne_compact_view_verify", forged)
        return 5
    except RuntimeError:
        return 0


def identity(root):
    return json.load(open(os.path.join(root, "etc", "at", "identity.cfg.json")))


COMPACT = os.environ.get("COMPACT", "river")


def main(a):
    v = a[1]
    if v == "found":
        return cmd_found(a[2], a[3])
    if v == "decide":
        return cmd_decide(a[2], a[3], a[4], a[5], a[6] if len(a) > 6 else "0")
    if v == "policy":
        return cmd_policy(a[2], a[3])
    if v == "uuid":
        print(identity(a[2])["uuid"].replace("-", "").lower())
        return 0
    if v == "verdict":
        return cmd_verdict(a[2], a[3], a[4])
    if v == "forged":
        return cmd_forged(a[2])
    if v == "agent":
        shim, root, role, state, member, nodes, cmd_dir, res_dir, secs = a[2:11]
        Agent(shim, root, role, state or None, int(member), nodes).loop(cmd_dir, res_dir, float(secs))
        return 0
    if v == "peers":
        lib = open_lib(a[2], a[3])
        h = connect(lib, float(a[5]))
        cap = 64
        buf = (Ev * cap)()
        seen = set()
        deadline = time.time() + float(a[5])
        while time.time() < deadline and len(seen) < int(a[4]):
            lib.agora_events_request_roster(h, Q)
            for ev in drain(lib, h, buf, cap, deadline):
                if ev.kind == 1:
                    seen.add(bytes(ev.peer_uuid).hex())
            time.sleep(1.0)
        lib.agora_events_close(h)
        return 0 if len(seen) >= int(a[4]) else 5
    print(f"unknown verb {v}", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

if ! python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$DRIVER"; then
  err "the embedded driver does not compile — refusing to start any node."
  exit 1
fi

tool() { # verb args...  (an Ethne-only verb: no node, no queue)
  ETHNE="$ETHNE" COMPACT="$COMPACT" python3 "$DRIVER" "$@"
}
drive() { # node verb args...  (a node-facing verb, before the node's app starts)
  local n="$1"; shift
  local verb="$1"; shift
  ETHNE="$ETHNE" LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    python3 "$DRIVER" "$verb" "$SHIM" "${ROOT[$n]}" "$@"
}
saw() { # node pattern
  grep -q "$2" "${ROOT[$1]}/agorad.log" 2>/dev/null
}
fail() { err "FAIL ($1) — $2"; dump_logs; exit 1; }

# The app on each node: one long-running agent holding the node's app-event
# channel, taking one command file at a time.
agent_start() { # node role state member
  local n="$1"
  mkdir -p "$RUN/$n.cmd" "$RUN/$n.res"
  ETHNE="$ETHNE" COMPACT="$COMPACT" LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    python3 -u "$DRIVER" agent "$SHIM" "${ROOT[$n]}" "$2" "$3" "$4" "$RUN/nodes.json" \
    "$RUN/$n.cmd" "$RUN/$n.res" 7200 >"$RUN/$n.agent.log" 2>&1 &
  APID[$n]=$!
}

app() { # node json  -> prints the result JSON; non-zero on an app error
  # Named by the clock, not a counter: app runs in $(...) subshells, where a
  # counter's increment is lost and a name would come round again.
  local n="$1" c="$2" name deadline rc
  name="$(date +%s%N)-$$-$RANDOM.json"
  printf '%s' "$c" >"$RUN/$n.tmp-$name" && mv "$RUN/$n.tmp-$name" "$RUN/$n.cmd/$name"
  deadline=$(( SECONDS + 60 ))
  until [ -f "$RUN/$n.res/$name" ] || [ "$SECONDS" -ge "$deadline" ]; do
    kill -0 "${APID[$n]}" 2>/dev/null || { err "$n's app died (see $RUN/$n.agent.log)"; return 1; }
    sleep 0.3
  done
  [ -f "$RUN/$n.res/$name" ] || { err "$n's app did not answer: $c"; return 1; }
  python3 - "$RUN/$n.res/$name" <<'P'
import json, sys
r = json.load(open(sys.argv[1]))
if not r["ok"]:
    print(r["error"], file=sys.stderr)
    sys.exit(1)
print(json.dumps(r["result"]))
P
  rc=$?
  rm -f "$RUN/$n.res/$name"
  return "$rc"
}

app_retry() { # node json  — a step whose inputs may still be in flight
  local deadline=$(( SECONDS + WAIT )) out
  while [ "$SECONDS" -lt "$deadline" ]; do
    out="$(app "$1" "$2" 2>"$RUN/last-err")" && { printf '%s\n' "$out"; return 0; }
    sleep 2
  done
  err "$1 kept refusing $2: $(cat "$RUN/last-err")"; return 1
}

until_app() { # node json cond  (cond: a Python expression over the result r)
  local deadline=$(( SECONDS + WAIT )) out=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    out="$(app "$1" "$2")" || return 1
    if python3 -c "import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if ($3) else 1)" "$out" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  err "last answer from $1: ${out:0:600}"; return 1
}

settled() { # node...  — every delivery each has made is acknowledged
  local n
  for n in "$@"; do until_app "$n" '{"cmd":"status"}' "r['unacked'] == 0" || return 1; done
}

reads() { # node community-did standing  — the node's replica reads it so
  until_app "$1" '{"cmd":"status"}' "[v for k, v in r.items() if k.startswith('standing_') and k[9:] == '$2'] == ['$3']"
}

view_says() { # community-did other-did standing  — the reader holds a view saying so
  until_app reader '{"cmd":"heard"}' \
    "max([v for v in r['views'] if v['community_did'] == '$1'], key=lambda v: v['seq'], default={'standings': {}})['standings'].get('$2') == '$3'"
}

# --------------------------------------------------------------------------- #
# Phase 1 — three communities, five nodes, three sealed rites
# --------------------------------------------------------------------------- #
log "Phase 1: founding Alpha, Beta and Gamma (each recites the five movements; ~20 s)"
tool found "$RUN/A.json" Alpha >"$RUN/A.did" & F1=$!
tool found "$RUN/B.json" Beta >"$RUN/B.did" & F2=$!
tool found "$RUN/C.json" Gamma >"$RUN/C.did" & F3=$!
wait "$F1" && wait "$F2" && wait "$F3" || fail "phase 1" "a community could not be founded"
A="$(cat "$RUN/A.did")"; B="$(cat "$RUN/B.did")"; C="$(cat "$RUN/C.did")"
log "Alpha $A"; log "Beta  $B"; log "Gamma $C"

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
declare -A U
for n in "${NODES[@]}"; do U[$n]="$(tool uuid "${ROOT[$n]}")" || fail "phase 1" "no identity for $n"; done
python3 - "$RUN/nodes.json" "$A" "$B" "$C" "${U[agov]}" "${U[awit]}" "${U[bgov]}" "${U[cgov]}" <<'P'
import json, sys
out, a, b, c, ag, aw, bg, cg = sys.argv[1:]
json.dump({"A": {"did": a, "gov": ag, "wit": aw}, "B": {"did": b, "gov": bg}, "C": {"did": c, "gov": cg}},
          open(out, "w"))
P
agent_start agov gov "$RUN/A.json" 0
agent_start awit witness "$RUN/A.json" 2
agent_start bgov gov "$RUN/B.json" 0
agent_start cgov gov "$RUN/C.json" 0
agent_start reader reader "" 0
for n in "${NODES[@]}"; do app "$n" '{"cmd":"status"}' >/dev/null || fail "phase 1" "$n's app did not come up"; done

log "Phase 1: each community seals its KC rite; Alpha's Inductor recites on awit"
app agov "{\"cmd\":\"cross\",\"remote\":[2],\"witness_nodes\":[\"${U[awit]}\"]}" >/dev/null || fail "phase 1" "Alpha could not cross"
app bgov '{"cmd":"cross"}' >/dev/null || fail "phase 1" "Beta could not cross"
app cgov '{"cmd":"cross"}' >/dev/null || fail "phase 1" "Gamma could not cross"
for n in agov bgov cgov; do
  until_app "$n" '{"cmd":"status"}' "not r['rite_pending']" || fail "phase 1" "$n's rite was never sealed"
done
grep -q "answered kc_attest/recite" "$RUN/awit.agent.log" \
  || fail "phase 1" "Alpha's recitation was not signed on awit"
settled agov bgov cgov || fail "phase 1" "the borders and rites were not all received"
ok "phase 1: five nodes; three rites sealed, Alpha's recited by its Inductor on its own device"

# --------------------------------------------------------------------------- #
# Phase 2 — the rolls join; Alpha and Beta found the compact
# --------------------------------------------------------------------------- #
log "Phase 2: Alpha's and Beta's rolls decide Join (D40); Alpha's policy hides the anathematized (D39)"
tool decide "$RUN/A.json" Join "$COMPACT" "$B" 0 || fail "phase 2" "Alpha's Join was refused"
tool decide "$RUN/B.json" Join "$COMPACT" "$A" 0 || fail "phase 2" "Beta's Join was refused"
tool policy "$RUN/A.json" "$RUN/policy-A.json" || fail "phase 2" "Alpha's policy was refused"
for n in agov awit bgov; do app "$n" '{"cmd":"reload"}' >/dev/null || fail "phase 2" "$n could not reload"; done
app agov "{\"cmd\":\"carry_policy\",\"bundle\":\"$RUN/policy-A.json\"}" >/dev/null || fail "phase 2" "agov could not carry the policy"
app_retry agov "{\"cmd\":\"present\",\"counterparties\":[\"$B\"]}" >/dev/null || fail "phase 2" "Alpha's claims"
app_retry bgov "{\"cmd\":\"present\",\"counterparties\":[\"$A\"]}" >/dev/null || fail "phase 2" "Beta's claims"
settled agov bgov || fail "phase 2" "the claims were not received"
app_retry agov "{\"cmd\":\"accept\",\"presenter\":\"$B\"}" >/dev/null || fail "phase 2" "Alpha's verdicts"
app_retry bgov "{\"cmd\":\"accept\",\"presenter\":\"$A\"}" >/dev/null || fail "phase 2" "Beta's verdicts"
settled agov bgov || fail "phase 2" "the verdicts were not received"
app_retry agov "{\"cmd\":\"convene\",\"participants\":[\"$A\",\"$B\"],\"signer_nodes\":[\"${U[bgov]}\"]}" >/dev/null \
  || fail "phase 2" "the founding seal could not be convened"
reads agov "B" in_compact || fail "phase 2" "Alpha's replica does not read Beta in compact"
reads bgov "A" in_compact || fail "phase 2" "Beta's replica does not read Alpha in compact"
view_says "$A" "$B" in_compact || fail "phase 2" "the reader holds no view of Alpha's naming Beta in compact"
app reader '{"cmd":"heard"}' | python3 -c "
import json, sys
h = json.load(sys.stdin)
v = max([v for v in h['views'] if v['community_did'] == sys.argv[1]], key=lambda v: v['seq'])
open(sys.argv[2], 'w').write(v['bundle'])
print(v['seq'])" "$A" "$RUN/view-A-founding.json" >"$RUN/view-A-founding.seq" || fail "phase 2" "could not keep the founding view"
ok "phase 2: the compact '$COMPACT' is founded; both replicas and Alpha's signed view say in_compact"

# --------------------------------------------------------------------------- #
# Phase 3 — Gamma is sponsored, examined by a panel of 3, and admitted
# --------------------------------------------------------------------------- #
log "Phase 3: Gamma joins; Alpha sponsors; Alpha and Beta admit"
tool decide "$RUN/C.json" Join "$COMPACT" "$A,$B" 0 || fail "phase 3" "Gamma's Join"
tool decide "$RUN/A.json" Sponsor "$COMPACT" "$C" 90 || fail "phase 3" "Alpha's Sponsor"
tool decide "$RUN/A.json" Admit "$COMPACT" "$C" 0 || fail "phase 3" "Alpha's Admit"
tool decide "$RUN/B.json" Admit "$COMPACT" "$C" 0 || fail "phase 3" "Beta's Admit"
for n in agov awit bgov cgov; do app "$n" '{"cmd":"reload"}' >/dev/null || fail "phase 3" "$n could not reload"; done
app agov "{\"cmd\":\"vouch\",\"entrant\":\"$C\"}" >/dev/null || fail "phase 3" "Alpha could not vouch"
app agov "{\"cmd\":\"seat\",\"members\":[0,2],\"nodes\":[\"${U[awit]}\"]}" >/dev/null || fail "phase 3" "Alpha could not seat"
app bgov '{"cmd":"seat","members":[0]}' >/dev/null || fail "phase 3" "Beta could not seat"
settled agov bgov || fail "phase 3" "the sponsorship and seats were not received (awit included)"
app_retry agov "{\"cmd\":\"present\",\"counterparties\":[\"$C\"]}" >/dev/null || fail "phase 3" "Alpha's claims"
app_retry bgov "{\"cmd\":\"present\",\"counterparties\":[\"$C\"]}" >/dev/null || fail "phase 3" "Beta's claims"
app_retry cgov "{\"cmd\":\"present\",\"counterparties\":[\"$A\",\"$B\"]}" >/dev/null || fail "phase 3" "Gamma's claims"
settled agov bgov cgov || fail "phase 3" "the claims were not received"
for pair in "agov $B" "agov $C" "bgov $A" "bgov $C" "cgov $A" "cgov $B"; do
  set -- $pair
  app_retry "$1" "{\"cmd\":\"accept\",\"presenter\":\"$2\"}" >/dev/null || fail "phase 3" "$1's verdict on $2"
done
settled agov bgov cgov || fail "phase 3" "the verdicts were not received"
app_retry agov "{\"cmd\":\"convene\",\"participants\":[\"$A\",\"$B\",\"$C\"],\"signer_nodes\":[\"${U[bgov]}\",\"${U[cgov]}\",\"${U[awit]}\"]}" >/dev/null \
  || fail "phase 3" "the admission seal could not be convened"
for n in agov bgov cgov; do
  reads "$n" "C" probationary || fail "phase 3" "$n's replica does not read Gamma as probationary"
done
grep -q "answered kc_seal/sign" "$RUN/awit.agent.log" || fail "phase 3" "the examiner on awit never signed"
view_says "$A" "$C" probationary || fail "phase 3" "Alpha's view does not name Gamma probationary"
ok "phase 3: Gamma admitted by envoys and a panel of 3 (one on awit); every replica and Alpha's view: probationary"

# --------------------------------------------------------------------------- #
# Phase 4 — Alpha and Beta anathematize Gamma
# --------------------------------------------------------------------------- #
log "Phase 4: both rolls decide Anathematize at majority + 1; Alpha drafts, Beta co-signs"
tool decide "$RUN/A.json" Anathematize "$COMPACT" "$C" 0 || fail "phase 4" "Alpha's Anathematize"
tool decide "$RUN/B.json" Anathematize "$COMPACT" "$C" 0 || fail "phase 4" "Beta's Anathematize"
for n in agov awit bgov; do app "$n" '{"cmd":"reload"}' >/dev/null || fail "phase 4" "$n could not reload"; done
app_retry agov "{\"cmd\":\"report\",\"co\":[\"$B\"],\"subject\":\"$C\"}" >/dev/null || fail "phase 4" "Alpha could not report"
for n in agov bgov; do
  reads "$n" "C" anathema || fail "phase 4" "$n's replica does not read Gamma as anathema"
done
view_says "$A" "$C" anathema || fail "phase 4" "Alpha's view does not name Gamma anathema"
ok "phase 4: a SecondClass conduct record from two reporters; Gamma is anathema"

# --------------------------------------------------------------------------- #
# Phase 5 — Alpha's policy hides by standing (D39)
# --------------------------------------------------------------------------- #
log "Phase 5: Gamma posts; the reader judges it by Alpha's policy and view"
app cgov '{"cmd":"post","body":"P5 from gamma"}' >/dev/null || fail "phase 5" "Gamma could not post"
until_app reader '{"cmd":"heard"}' \
  "any('P5 from gamma' in p['body'] and p['community'] == '$C' for p in r['posts']) and '$A' in r['policies']" \
  || fail "phase 5" "the reader never received Gamma's post, scope intact, and Alpha's policy"
app reader '{"cmd":"heard"}' >"$RUN/reader-heard.json" || fail "phase 5" "could not read what the reader heard"
tool verdict "$RUN/reader-heard.json" "$A" "$C" >"$RUN/verdict-C.json" || fail "phase 5" "no verdict on Gamma's post"
tool verdict "$RUN/reader-heard.json" "$A" "$B" >"$RUN/verdict-B.json" || fail "phase 5" "no verdict on a post in Beta's name"
grep -q '"action": "Hide"' "$RUN/verdict-C.json" || fail "phase 5" "Gamma's post is not hidden: $(cat "$RUN/verdict-C.json")"
grep -q '"action": "Allow"' "$RUN/verdict-B.json" || fail "phase 5" "a post in Beta's name is not allowed: $(cat "$RUN/verdict-B.json")"
ok "phase 5: under Alpha's policy and view, Gamma's post is hidden (anathema) and Beta's allowed (in_compact)"

# --------------------------------------------------------------------------- #
# Phase 6 — a view is its community's word, and the newest stands
# --------------------------------------------------------------------------- #
log "Phase 6: a forged view, and an old one offered again"
tool forged "$RUN/reader-heard.json" || fail "phase 6" "a view edited after signing verified"
OLD_SEQ="$(cat "$RUN/view-A-founding.seq")"
out="$(app reader "{\"cmd\":\"offer\",\"bundle\":\"$RUN/view-A-founding.json\"}")" || fail "phase 6" "the reader refused to look"
python3 -c "import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if not r['taken'] else 1)" "$out" \
  || fail "phase 6" "Alpha's founding view (seq $OLD_SEQ) replaced a newer one"
view_says "$A" "$C" anathema || fail "phase 6" "the reader no longer holds Alpha's newest view"
ok "phase 6: the forged view is refused; the founding view (seq $OLD_SEQ) does not replace the newest"

log "PASS: compact — founded, a third admitted by a panel, anathema by two, and a policy that hides by standing"
exit 0
