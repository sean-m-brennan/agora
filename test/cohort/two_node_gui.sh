#!/usr/bin/env bash
#
# two_node_gui.sh — SEE the Phase-0 exit in the real Flutter UI.
#
# Same virtual L2 segment as two_node_cohort.sh (bridge + two netns on one /24),
# but instead of a headless ctypes harness, node 1 runs the actual **Flutter GUI**
# so you can watch peers appear with live presence, reputation, RTT, opt-in
# distance, and opt-in signed profiles. Node 2 is a headless seeded peer ("Bob")
# that opts in to a profile + coarse position, so node 1's window shows a real
# person to connect to.
#
#   node 1 = GUI (the window you watch), opted in: profile "Ada Lovelace" + bucket
#   node 2 = headless agorad peer, opted in: profile "Bob Rivera" + bucket
#
# What you should see in node 1's window:
#   • Bob Rivera appears in "People near me" within ~10-30 s of discovery.
#   • His tile shows presence (operator-attended), reputation once rated, an RTT
#     line (network-latency proxy, ms), and — once YOU tap the location icon and
#     enter your own bucket — a coarse distance to him.
#   • Tap the profile icon (top bar) to view/edit your own opt-in profile.
#
# Why netns: AT discovery is UDP broadcast on COMM_PORT 27787; two nodes cannot
# share that broadcast port in one network stack, so each gets its own netns,
# bridged on one L2 /24 (see two_node_cohort.sh's header for the full rationale).
#
# Requirements: root (netns/veth/bridge), iproute2, a running X11/Wayland display
# you can reach, and the built app:
#     ./build.sh          # native layer + `flutter build linux`
# Then:
#     sudo -E ./test/cohort/two_node_gui.sh          # -E preserves DISPLAY etc.
#
# Env knobs:
#   GUI2=1     also run node 2 as a second GUI window (two apps discovering).
#   KEEP=1     leave netns/bridge up for inspection after exit.
#   SUBNET     default 10.9.0
#   GEO1/GEO2  coarse geohash buckets (default u4pruy / u4prv0 — a few km apart,
#              so once you opt node 1 in via the UI you get a non-zero distance).
#   DISPLAY / WAYLAND_DISPLAY / XAUTHORITY / XDG_RUNTIME_DIR are forwarded into
#   the namespaces; run `xhost +local:` first if the app cannot open the display.
#
# NOTE (X in a netns): the app connects to your display over the X/Wayland
# PATHNAME socket (/tmp/.X11-unix/X0 or $XDG_RUNTIME_DIR/wayland-0), which is a
# filesystem path shared across network namespaces — so this works on a normal
# desktop session. If your X server listens ONLY on an abstract socket, run it
# with a local pathname socket (X.Org's default) or use `xhost` + TCP.

set -u

# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGORA_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "$PWD")"
NATIVE="$AGORA_DIR/native/build"
AGORAD="$NATIVE/agorad"
SHIM="$NATIVE/libagora_shim.so"
ATCORE="$NATIVE/at_core"
# Prefer the self-contained bundle exe (ships agorad + shim in its lib/); fall
# back to any built flavor.
BUNDLE="$(ls -d "$AGORA_DIR"/build/linux/*/debug/bundle/agora 2>/dev/null | head -1)"

SUBNET="${SUBNET:-10.9.0}"
IP1="$SUBNET.1"; IP2="$SUBNET.2"; PREFIX=24
GEO1="${GEO1:-u4pruy}"; GEO2="${GEO2:-u4prv0}"

NS1=agoragui1; NS2=agoragui2
BR=aggbr0
V1=agg1; V1B=agg1b; V2=agg2; V2B=agg2b

RUN="$(mktemp -d /tmp/agora-gui.XXXX)"       # short root (AF_UNIX sun_path <108)
ROOT1="$RUN/n1"; ROOT2="$RUN/n2"
mkdir -p "$ROOT1" "$ROOT2"

PID1=""; PID2=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
if [ "$(id -u)" -ne 0 ]; then err "must run as root (sudo -E). netns/veth/bridge need it."; exit 1; fi
if ! have ip; then err "'ip' (iproute2) not found: apt-get install -y iproute2"; exit 1; fi
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  err "no DISPLAY or WAYLAND_DISPLAY in the environment — run under a desktop session,"
  err "and use 'sudo -E' so the display variables survive into this script."; exit 1
fi
for f in "$AGORAD" "$SHIM" "$ATCORE/libautonomous_trust.so"; do
  [ -e "$f" ] || { err "missing native artifact: $f — build first: (cd '$AGORA_DIR' && ./build.sh)"; exit 1; }
done
if [ -z "$BUNDLE" ] || [ ! -x "$BUNDLE" ]; then
  err "no Flutter Linux bundle found under build/linux/*/debug/bundle/agora."
  err "build it: (cd '$AGORA_DIR' && ./build.sh)  # runs 'flutter build linux'"; exit 1
fi
if ! ip netns add _agg_probe 2>/dev/null; then
  err "cannot create a network namespace here (kernel/policy denies CLONE_NEWNET)."
  err "Run on a real Linux host/VM that permits network namespaces."; exit 1
fi
ip netns del _agg_probe 2>/dev/null

# --------------------------------------------------------------------------- #
# Cleanup
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
  for ns in "$NS1" "$NS2"; do
    ip netns pids "$ns" 2>/dev/null | while read -r p; do kill "$p" 2>/dev/null; done
  done
  sleep 1
  ip netns del "$NS1" 2>/dev/null
  ip netns del "$NS2" 2>/dev/null
  ip link del "$BR"  2>/dev/null
  ip link del "$V1B" 2>/dev/null
  ip link del "$V2B" 2>/dev/null
  rm -rf "$RUN"
  exit $rc
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------- #
# Virtual L2 segment: two netns bridged on one /24
# --------------------------------------------------------------------------- #
log "Creating bridge $BR + namespaces ($NS1, $NS2) on $SUBNET.0/$PREFIX"
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
ip -n "$NS1" addr add "$IP1/$PREFIX" dev "$V1"; ip -n "$NS1" link set "$V1" up; ip -n "$NS1" link set lo up
ip -n "$NS2" addr add "$IP2/$PREFIX" dev "$V2"; ip -n "$NS2" link set "$V2" up; ip -n "$NS2" link set lo up

if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
  echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
fi
if ip netns exec "$NS1" ping -c1 -W2 "$IP2" >/dev/null 2>&1; then
  log "L2 connectivity OK ($IP1 <-> $IP2)"
else
  err "no L2 connectivity across the bridge — discovery cannot work. Aborting."; exit 1
fi

# Let root reach the operator's X display (best-effort; harmless if already open).
# The GUI runs in the HOST namespace (not a netns), so the display's abstract
# socket is reachable normally; this only helps if root needs X-auth grace.
if [ -n "${DISPLAY:-}" ] && have xhost; then xhost +local:root >/dev/null 2>&1 || true; fi

# Profiles the two nodes advertise (opt-in, signed by the C node — AT_OWN_PROFILE).
PROF1="${PROF1:-{\"display_name\":\"Ada Lovelace\",\"handle\":\"ada\",\"bio\":\"node 1 (the GUI you are watching)\"}}"
PROF2="${PROF2:-{\"display_name\":\"Bob Rivera\",\"handle\":\"bob\",\"bio\":\"node 2 — the peer you should see appear\"}}"

# --------------------------------------------------------------------------- #
# Launchers
# --------------------------------------------------------------------------- #
# A headless AT node inside a netns: agorad only, opted in via env. This is where
# the real UDP-broadcast discovery happens (one non-lo IPv4 per netns, so AT's
# discover_network_for() deterministically picks the veth). BOTH nodes run this
# way so they can share the broadcast port on one host.
start_headless() {
  local ns="$1" root="$2" name="$3" seed="$4" geo="$5" prof="$6"
  ip netns exec "$ns" env \
    AUTONOMOUS_TRUST_ROOT="$root" \
    AT_PEER_NAME="$name" AT_PEER_SEED="$seed" \
    AT_OWN_GEOHASH="$geo" AT_OWN_PROFILE="$prof" \
    LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    "$AGORAD" extern_to_at at_to_extern 2 \
    >"$root/agorad.log" 2>&1 &
  echo $!
}

# The Flutter GUI in the HOST namespace (your normal display — no X-in-netns
# problem), ATTACHING to a netns node's already-running agorad over its
# filesystem socket under $root. AGORA_EXTERNAL_DAEMON=1 makes the app a pure
# app-events client (it does NOT spawn its own daemon); an AF_UNIX pathname
# socket is not network-namespace scoped, so the host-side GUI reads the
# netns-side daemon's roster directly.
start_gui_attach() {
  local root="$1"
  env \
    AGORA_EXTERNAL_DAEMON=1 \
    AUTONOMOUS_TRUST_ROOT="$root" \
    AGORA_SHIM_PATH="$SHIM" \
    LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
    "$BUNDLE" >"$root/gui.log" 2>&1 &
  echo $!
}

# 1) Bring up both AT nodes headless in their namespaces; they discover each other.
log "Starting node 1 (Ada) headless in $NS1  (geohash=$GEO1)"
NODE1="$(start_headless "$NS1" "$ROOT1" agora-node-1 gui-seed-1 "$GEO1" "$PROF1")"
log "Starting node 2 (Bob) headless in $NS2  (geohash=$GEO2)"
NODE2="$(start_headless "$NS2" "$ROOT2" agora-node-2 gui-seed-2 "$GEO2" "$PROF2")"

# Give them time to bootstrap identity + bind their app-events sockets.
sleep 4
for pid in "$NODE1" "$NODE2"; do
  if ! kill -0 "$pid" 2>/dev/null; then
    err "a daemon exited early — logs:"; tail -n 40 "$ROOT1"/*.log "$ROOT2"/*.log 2>/dev/null; exit 1
  fi
done

# 2) Launch the GUI(s) in the host session, attaching to the netns node(s).
log "Launching node 1 GUI (host session, attaching to $ROOT1)"
PID1="$(start_gui_attach "$ROOT1")"
if [ "${GUI2:-0}" = "1" ]; then
  log "Launching node 2 GUI (host session, attaching to $ROOT2)"
  PID2="$(start_gui_attach "$ROOT2")"
fi

sleep 2
if ! kill -0 "$PID1" 2>/dev/null; then
  # The launcher pid is gone. This is NOT necessarily a failure: some desktops
  # hand the window to a compositor helper and the exec returns while the window
  # lives on. Only treat it as fatal if the log shows a hard startup error;
  # otherwise fall through to the hold so the cohort stays up and inspectable.
  if grep -qiE "cannot open display|failed to|error while loading|No such file" \
       "$ROOT1/gui.log" 2>/dev/null; then
    err "the GUI failed to start — log:"; tail -n 40 "$ROOT1/gui.log" 2>/dev/null
    err "If it says 'cannot open display', run 'xhost +local:root' in your session and retry,"
    err "or launch the GUI yourself as your own user:"
    err "    AGORA_EXTERNAL_DAEMON=1 AUTONOMOUS_TRUST_ROOT=$ROOT1 \\"
    err "    AGORA_SHIM_PATH=$SHIM LD_LIBRARY_PATH=$ATCORE $BUNDLE"
    exit 1
  fi
  log "GUI launcher returned but no startup error logged — window likely handed off."
  log "Keeping the cohort UP; check the window (and $ROOT1/gui.log) below."
fi

cat <<EOF

  ${BR}: node 1 ($IP1) <-> node 2 ($IP2), both headless in netns; GUI attached from host.
  Watch node 1's window: "Bob Rivera" should appear in People near me within
  ~10-30 s. Tap the location icon and enter a bucket (e.g. $GEO1) to see distance
  to Bob ($GEO2). Tap the profile icon to view/edit your own shared profile.

  Logs:  GUI $ROOT1/gui.log   daemons $ROOT1/agorad.log  $ROOT2/agorad.log

  >>> The cohort is UP and will STAY up. Take your time with the window.
  >>> Press Enter here (or Ctrl-C) to tear everything down.
EOF

# Explicit hold: keep the namespaces, daemons, and config root alive so the GUI
# window stays usable, regardless of whether the launcher process returns early
# (some desktops hand the window off to a compositor helper and the exec returns).
# Do NOT teardown until the operator says so — the trap still cleans up on Ctrl-C.
read -r _ || true

# If the GUI process is still ours, close it before the trap tears down the rest.
if [ -n "${PID1:-}" ] && kill -0 "$PID1" 2>/dev/null; then
  kill "$PID1" 2>/dev/null
fi
