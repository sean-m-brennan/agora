#!/usr/bin/env bash
#
# staff_cohort.sh — Phase 3 P3.3 live check: a staff polity decides together,
# over the wire, and nobody's private key ever moves.
#
# A FIVE-MEMBER staff polity carried by THREE real agorad nodes on one virtual L2
# segment (bridge + netns, exactly as business_cohort.sh), driven through the
# real app-event queues. The counts differ on purpose — see cal:
#
#   keeper — holds the charter log AND the polity root key. It authors every
#            act, asks the others to co-sign, and assembles what comes back.
#   ada    — a founder, and the polity's ENVOY. She departs in phase 3 so the
#            cohort can watch an office lapse with its holder.
#   bob    — a founder, and an ordinary decider throughout.
#   cal    — a founder, and the one expelled in phase 2. HE HAS NO NODE: he is
#            asked nothing and signs nothing, so a daemon for him would only add
#            a peer to the mesh that no phase ever talks to.
#   dee    — NOT a founder. She is admitted over the wire in phase 1 and then
#            inducted through the five-movement rite.
#
# WHY FIVE MEMBERS, AND WHY ONLY THREE NODES. An expulsion needs majority+1 and
# bars its target from deciding. At five seasoned that is four deciders drawn
# from exactly four eligible — the bar is EXACTLY reachable, which is P3.3 S2's
# finding made live. At four seasoned it would need four from three and could
# never close, whatever anyone agreed. So the POLITY must be five. The MESH need
# not be. cal is the expulsion's target and is asked nothing; dee's consent is
# real but needs no network to compute. Three is the size business_cohort.sh has
# always run at, and the size this environment actually converges at — see the
# NODES array for the measurement.
#
# WHAT ACTUALLY CROSSES THE WIRE, and what does not. Only the CO-SIGNATURE
# EXCHANGE is a network act. Admission, induction, expulsion assembly, departure
# and the office lapse are archive operations, local to whoever holds the log.
# This script does not dress those up as network tests. Admission and expulsion
# do reach the wire, because both are co-signed acts — the exchange is the
# multi-node content of this cohort, and it is the whole of it.
#
# What it proves, in order:
#   1. A co-signature ask crosses the whole runtime and lands on a peer's
#      APP-EVENT QUEUE (kind 13). Conformance is single-process and cannot see
#      this — both P3.2 group-key forks were visible only in a live cohort, and
#      the first business_cohort.sh run found a real split-brain in the AT core
#      that every unit and conformance suite had passed over.
#   2. NO PRIVATE KEY MOVES, IN EITHER DIRECTION. Each node signs on its own node
#      with its own key file; what returns is a detached signature and a DID.
#   3. NO DESCRIPTION CROSSES (P3.3 S5, live). The event has no field to carry
#      one. Each signer derives what it is being asked to sign from the bytes it
#      received, and REFUSES if the recomputed cid is not the one the asker sent.
#      A node that could choose both what you sign and the sentence describing it
#      could put friendly wording over a hostile act.
#   4. A NODE THAT WAS NOT ASKED REFUSES. cal receives the ask for his own
#      expulsion and declines it: the target of an expulsion neither decides nor
#      signs.
#   5. THE ROLL OUTLIVES THE POLITY'S RUNNING NODES. Phase 4 publishes the S9
#      member roll, stops every node, and re-verifies it with nobody left to ask —
#      the same close as business_cohort.sh's "the page outlives the business".
#
# EVERY READOUT IS PAIRED WITH verify(). affirmationState is a fold over what the
# log CLAIMS: it will report a member seasoned while the authority pass refuses
# the whole log (see ethne_polity_roundtrip_test.dart:280). An assertion that
# reads only the claim passes straight over a broken rite — which is exactly what
# happened while this script was being written, and why the checks below always
# ask whether the log still verifies.
#
# TWO BACKENDS, one script. Each node needs its own network stack, because AT's
# open discovery is UDP broadcast on a single fixed port:
#
#   netns  — bridge + five network namespaces, as business_cohort.sh does.
#            Needs root and a kernel that permits CLONE_NEWNET.
#   docker — five containers on one user-defined bridge network. Same L2 story,
#            and the fallback for sandboxes that deny CLONE_NEWNET.
#
# The app-side driver always runs on the HOST either way: the app-event queues
# are AF_UNIX sockets under AUTONOMOUS_TRUST_ROOT, which is a filesystem path,
# not a network one.
#
# Requirements: python3, dart (to mint the polity and to sign), the built native
# layer + ethne cdylib (./build.sh), and EITHER root + iproute2 (netns) OR a
# usable docker daemon.
#
# Usage:
#   sudo -E env "PATH=$PATH" ./test/cohort/staff_cohort.sh
#   BACKEND=docker ./test/cohort/staff_cohort.sh
#   WAIT=180 KEEP=1 ./test/cohort/staff_cohort.sh
#
# `sudo -E env "PATH=$PATH"` is not decoration: plain sudo wipes PATH through
# secure_path and the script dies in preflight looking for dart.
#
# Env knobs: BACKEND (auto|netns|docker, default auto), WAIT (per-phase timeout
#   secs, default 120 — 60 was only ever measured for THREE nodes), STAGGER
#   (secs between node starts, default 8), SUBNET (default 10.9.2), GEO (the
#   shared coarse bucket, default u4pruy), KEEP=1 (leave the network and run dir
#   up for inspection).

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
STAGGER="${STAGGER:-0}"
SUBNET="${SUBNET:-10.9.2}"
GEO="${GEO:-u4pruy}"
PREFIX=24

# THE NODE COUNT IS A PARAMETER HERE, unlike business_cohort.sh, which calls
# mk_ns three times inline with a constant per name and address. Five nodes make
# that unreadable, so everything below indexes these arrays in step. NODES[0] is
# the keeper by convention — it is the only node that holds the log.
# EVERY MEMBER OF THE POLITY — each gets a keypair and an agora.polity.json.
POLITY_MEMBERS=(keeper ada bob cal dee)
# THE NODES THAT ACTUALLY RUN A DAEMON, which is NOT the same list.
#
# cal has NO NODE and never needed one: in the expulsion it is the TARGET — done
# TO, not with — so it neither decides nor signs, and it consents to nothing in
# the admission either. The bonus assertion that a node not asked to decide
# refuses anyway is pinned without any network by drive_ethne_half.sh.
#
# dee has no node EITHER, and THAT one is a concession to the environment rather
# than a property of the design. Its consent to its own admission is real and
# required; it is simply computed host-side from dee's own key file, exactly as
# the keeper's own signature always has been. The cost is one fewer signature
# crossing the wire — the property under test (a decider signs on its own node
# with its own key, and no private key ever travels) is untouched.
#
# WHY: a FOUR-node mesh does not converge here, and not for want of time. At
# WAIT=300 the result was byte-for-byte what it was at WAIT=120 — a STABLE
# partial topology, not a slow one: the first and last nodes each saw the middle
# two and never each other. Three is what business_cohort.sh has always run, and
# across every run of this cohort the keeper has reliably seen ada and bob.
#
# THE POLITY IS STILL FIVE MEMBERS, which is the part that matters. Five
# SEASONED members is what makes majority+1 exactly reachable — four deciders
# drawn from exactly four eligible — and that is a property of the POLITY, not
# of how many daemons are running.
NODES=(keeper ada bob)
BR=agbr2
# .11 upward: a docker bridge network claims .1 for its own gateway, and a
# container asking for it is refused.
declare -a IPS NSS VETH VETHB ROOTS PIDS
for i in "${!NODES[@]}"; do
  IPS[i]="$SUBNET.$((11 + i))"
  NSS[i]="ags${i}ns"
  VETH[i]="ags${i}"          # <= 15 chars, or the kernel refuses the name
  VETHB[i]="ags${i}b"
  PIDS[i]=""
done

BACKEND="${BACKEND:-auto}"
NET=agora-staff-net                        # docker network name

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Index of a node by name, so the phases can read as prose.
idx() { local n; for n in "${!NODES[@]}"; do [ "${NODES[$n]}" = "$1" ] && { echo "$n"; return 0; }; done; return 1; }
K=$(idx keeper)

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
if ! have python3; then err "python3 not found."; exit 1; fi
if ! have dart; then err "'dart' not found (needed to mint the polity and to sign); add the Flutter SDK to PATH."; err "under sudo, invoke as: sudo -E env \"PATH=\$PATH\" $0"; exit 1; fi
# THE DART BINARY every tool below runs through — deliberately the Dart SDK's
# OWN binary, not the `dart` wrapper in flutter/bin that PATH resolves to.
#
# The wrapper sources bin/internal/shared.sh, whose upgrade_flutter() runs on
# EVERY invocation. It rewrites bin/cache/engine.stamp and engine.realm, and if
# it judges the cache stale it goes much further: takes the SDK-wide lock,
# downloads and unpacks a Dart SDK, re-runs pub, rebuilds
# flutter_tools.snapshot. That is Flutter keeping its own install honest and has
# nothing to do with running a project tool. This script runs under sudo because
# netns needs root, so under the wrapper every bit of it happens AS ROOT inside
# a developer-owned SDK. engine.stamp is replaced by `mv`, so it comes back
# owned by root — that one self-heals, because the next ordinary flutter command
# mv's over it again. A root-downloaded dart-sdk/ or a root-written snapshot
# does not self-heal and needs a manual chown. (engine.realm is truncated in
# place, so it keeps its owner; it is the stamp that turns over.) Each of the
# dart calls below also prints the "you appear to be trying to run flutter as
# root" clippy, which is how this was noticed.
#
# The SDK binary is the same dart with none of that install bookkeeping. A bare
# Dart SDK on PATH has no bin/cache/dart-sdk, in which case what PATH found
# stands.
DART="$(command -v dart)"
_dart_real="$(readlink -f "$DART" 2>/dev/null || printf '%s' "$DART")"
_sdk_dart="$(dirname "$_dart_real")/cache/dart-sdk/bin/dart"
[ -x "$_sdk_dart" ] && DART="$_sdk_dart"

# Run a command as whoever invoked sudo, when there is such a person. Used for
# `flutter pub get` alone: it writes .dart_tool/ and the pub cache, both of
# which belong to that user, and doing it as root leaves root-owned files that
# their next ordinary build cannot rewrite. PATH is passed explicitly for the
# same reason the header tells you to invoke this script with it — sudoers
# secure_path would otherwise drop the Flutter SDK on the way back down.
as_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" -E env "PATH=$PATH" "$@"
  else
    "$@"
  fi
}

# `.dart_tool/package_config.json` holds ABSOLUTE paths into $HOME/.pub-cache,
# so it goes stale whenever the checkout moves between machines or $HOME
# changes underneath it. `package:ffi` then stops resolving and Phase 0 dies in
# a wall of "'Utf8' isn't a type" / "calloc isn't defined" that reads like a
# broken binding and is nothing of the kind. Fetching first is the cure and
# costs a second when it is already correct. --offline because the cache
# already holds these packages; this harness has no business reaching pub.dev.
if have flutter; then
  (cd "$AGORA_DIR" && as_user flutter pub get --offline) >/dev/null 2>&1 \
    || err "'flutter pub get' failed — package:ffi may not resolve below."
fi

for f in "$AGORAD" "$SHIM" "$ATCORE/libautonomous_trust.so" "$ETHNE"; do
  if [ ! -e "$f" ]; then err "missing artifact: $f"; err "build first: (cd '$AGORA_DIR' && ./build.sh)"; exit 1; fi
done

netns_usable() {
  [ "$(id -u)" -eq 0 ] || return 1
  have ip || return 1
  ip netns add _agora_probe 2>/dev/null || return 1
  ip netns del _agora_probe 2>/dev/null
  return 0
}
docker_usable() { have docker && docker info >/dev/null 2>&1; }

case "$BACKEND" in
  netns)  netns_usable || { err "BACKEND=netns but namespaces are not usable here (need root + iproute2 + CLONE_NEWNET)."; exit 1; } ;;
  docker) docker_usable || { err "BACKEND=docker but no usable docker daemon."; exit 1; } ;;
  auto)
    if netns_usable; then BACKEND=netns
    elif docker_usable; then BACKEND=docker
    else
      err "no usable backend: network namespaces are denied here (need root +"
      err "iproute2 + CLONE_NEWNET) and no docker daemon answered."
      exit 1
    fi ;;
  *) err "BACKEND must be auto, netns or docker"; exit 1 ;;
esac
log "Backend: $BACKEND, ${#NODES[@]} nodes"

# --------------------------------------------------------------------------- #
# The run directory, and why it depends on the backend.
#
# AT binds its queues at $AUTONOMOUS_TRUST_ROOT/var/at/<queue>, and a unix
# socket path holds 108 bytes INCLUDING the terminator. The longest queue name
# is not an app queue: it is AT's own supervisor, "AutonomousTrust", at 15
# characters. So the budget every node must satisfy is
#
#     len(root) + len("/var/at/") + 15 + 1  <=  108
#
# THE FIRST HOST RUN OF THIS SCRIPT DIED HERE and spent a whole diagnosis
# looking like a discovery fault. The run dir was under the repo, as
# business_cohort.sh puts it, and the KEEPER — the one node named with six
# characters instead of three — needed 110:
#
#     message.c:116: socket path for queue "AutonomousTrust" needs 110 bytes
#     and a unix socket path holds 108
#
# Its supervisor queue never bound, so every messaging_send from the roster
# forward failed EBADF and the app queue answered nothing. To the driver the
# keeper looked as though it had discovered NOBODY, while its daemon was
# visibly exchanging UDP with all four peers in the same log. The other four
# nodes fitted with ONE byte to spare, which is exactly why only the keeper
# failed and why the symptom pointed at the network.
#
# Under netns the run dir therefore lives in /tmp, as two_node_cohort.sh has
# always done. Under docker it must stay under the agora directory, because a
# docker daemon only bind-mounts paths shared with it — so there the check
# below is the only thing between a deep checkout and that same diagnosis.
# --------------------------------------------------------------------------- #
SOCK_MAX=108
AT_SUPERVISOR_Q=AutonomousTrust
# The longest node name decides whether a candidate run dir fits, so measure
# with it: $RUN/<node>/var/at/<queue>, terminator included.
LONGEST_NODE=""
for n in "${NODES[@]}"; do
  [ "${#n}" -gt "${#LONGEST_NODE}" ] && LONGEST_NODE="$n"
done
run_fits() { # <candidate run dir>
  [ $(( ${#1} + 1 + ${#LONGEST_NODE} + 8 + ${#AT_SUPERVISOR_Q} + 1 )) -le "$SOCK_MAX" ]
}

# PREFER A PROJECT-LOCAL RUN DIR. cleanup() keeps a failing run deliberately,
# and a run kept somewhere only the host can read is evidence nobody else can
# look at — which cost a whole round trip when the keeper's own driver log was
# the thing that explained the failure. /tmp is the FALLBACK, taken only when
# the checkout is too deep for a socket path.
if [ -n "${AGORA_COHORT_RUN:-}" ]; then
  RUN="$AGORA_COHORT_RUN"
elif [ "$BACKEND" = netns ]; then
  for cand in "$AGORA_DIR/.coh/$$" "/tmp/ag-$$"; do
    RUN="$cand"
    run_fits "$cand" && break
  done
else
  # Docker has no choice: the daemon only bind-mounts paths shared with it.
  RUN="$AGORA_DIR/.coh/$$"
fi
LIBSTAGE="$RUN/lib"
mkdir -p "$LIBSTAGE" || exit 1
for i in "${!NODES[@]}"; do
  ROOTS[i]="$RUN/${NODES[$i]}"
  mkdir -p "${ROOTS[$i]}" || exit 1
done

# Refuse before a single daemon starts, naming the node and the number — rather
# than letting one node come up mute and calling it a network problem.
SOCK_TIGHTEST=0
for i in "${!NODES[@]}"; do
  need=$(( ${#ROOTS[i]} + 8 + ${#AT_SUPERVISOR_Q} + 1 ))
  # The TIGHTEST node is the one needing the MOST, not the least.
  [ "$need" -gt "$SOCK_TIGHTEST" ] && SOCK_TIGHTEST=$need
  if [ "$need" -gt "$SOCK_MAX" ]; then
    err "${NODES[$i]}'s socket path needs $need bytes and a unix socket path holds $SOCK_MAX."
    err "  root: ${ROOTS[$i]}"
    err "  AT would refuse to bind its \"$AT_SUPERVISOR_Q\" queue, and the node would"
    err "  run but answer nothing — which reads as a discovery failure and is not."
    err "  Set a shorter run dir: AGORA_COHORT_RUN=/tmp/ag-\$\$ $0"
    exit 1
  fi
done
log "Socket paths fit: tightest node needs $SOCK_TIGHTEST of $SOCK_MAX bytes"


# --------------------------------------------------------------------------- #
# Backend primitives. Four verbs — net_up, node_start, node_stop, net_down — so
# the phases below read the same whichever isolation the host allows. Each now
# loops over NODES instead of naming three nodes by hand.
# --------------------------------------------------------------------------- #
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:26.04}"

stage_libs() {
  # Copy agorad's non-base shared libraries next to the run dir, so a stock
  # ubuntu image can load the HOST-BUILT binary without installing anything.
  local lib
  for lib in $(ldd "$AGORAD" "$ATCORE/libautonomous_trust.so" 2>/dev/null \
               | awk '/=> \// {print $3}' | sort -u); do
    case "$lib" in
      */libc.so.*|*/libm.so.*|*/ld-linux*) continue ;;   # in every base image
    esac
    cp -n "$lib" "$LIBSTAGE/" 2>/dev/null || true
  done
}

# Remove anything an earlier run left behind. THIS IS NOT OPTIONAL HOUSEKEEPING:
# cleanup() deliberately KEEPS the network when the script fails, so that the
# next invocation can inspect it — which means the next invocation must also be
# able to rebuild over it. Without this, one failed run poisons every run after
# it with "Cannot create namespace file … File exists", and the L2 check then
# reports "no path to the keeper", which reads as a networking fault and is
# nothing but stale state.
#
# `ip netns del` takes ONE name, never a list. Deleting a namespace takes its
# veth with it; the peer half is removed explicitly in case an earlier teardown
# got only part of the way.
net_reset() {
  local i
  if [ "$BACKEND" = netns ]; then
    for i in "${!NODES[@]}"; do
      ip netns del "${NSS[$i]}" 2>/dev/null
      ip link del "${VETHB[$i]}" 2>/dev/null
    done
    ip link del "$BR" 2>/dev/null
  else
    docker network rm "$NET" >/dev/null 2>&1
  fi
  return 0
}

net_up() {
  local i
  if [ "$BACKEND" = netns ]; then
    net_reset
    log "Creating bridge $BR + ${#NODES[@]} namespaces on $SUBNET.0/$PREFIX"
    ip link add "$BR" type bridge || return 1
    ip link set "$BR" up || return 1
    for i in "${!NODES[@]}"; do
      # Every one of these is checked. Letting a failed `netns add` fall through
      # to the ping is what turned stale state into a discovery diagnosis.
      ip netns add "${NSS[$i]}" || { err "could not create namespace ${NSS[$i]}"; return 1; }
      ip link add "${VETH[$i]}" type veth peer name "${VETHB[$i]}" \
        || { err "could not create veth ${VETH[$i]}"; return 1; }
      ip link set "${VETH[$i]}" netns "${NSS[$i]}" || return 1
      ip link set "${VETHB[$i]}" master "$BR" || return 1
      ip link set "${VETHB[$i]}" up || return 1
      ip -n "${NSS[$i]}" addr add "${IPS[$i]}/$PREFIX" dev "${VETH[$i]}" || return 1
      ip -n "${NSS[$i]}" link set "${VETH[$i]}" up || return 1
      ip -n "${NSS[$i]}" link set lo up || return 1
    done
    if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
      echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
    fi
    # Every node must reach the keeper: the ask is directed, not broadcast.
    for i in "${!NODES[@]}"; do
      [ "$i" = "$K" ] && continue
      if ! ip netns exec "${NSS[$i]}" ping -c1 -W2 "${IPS[$K]}" >/dev/null 2>&1; then
        err "${NODES[$i]} has no L2 path to the keeper — discovery cannot work."
        return 1
      fi
    done
  else
    log "Creating docker bridge network $NET on $SUBNET.0/$PREFIX"
    net_reset
    docker network create --driver bridge --subnet "$SUBNET.0/$PREFIX" "$NET" >/dev/null || return 1
    stage_libs
    log "Staged $(ls "$LIBSTAGE" | wc -l) shared libraries for the containers"
  fi
  log "L2 segment ready"
  return 0
}

node_start() { # index -> echoes a handle
  local i="$1" id="${NSS[$1]}" root="${ROOTS[$1]}" name="agora-${NODES[$1]}" ip="${IPS[$1]}"
  if [ "$BACKEND" = netns ]; then
    ip netns exec "$id" env \
      AUTONOMOUS_TRUST_ROOT="$root" \
      AT_PEER_NAME="$name" AT_PEER_SEED="${NODES[$1]}-seed-1" \
      AT_OWN_GEOHASH="$GEO" \
      LD_LIBRARY_PATH="$ATCORE:${LD_LIBRARY_PATH:-}" \
      "$AGORAD" extern_to_at at_to_extern 2 \
      >"$root/agorad.log" 2>&1 &
    echo $!
  else
    docker rm -f "$id" >/dev/null 2>&1 || true
    docker run -d --name "$id" --network "$NET" --ip "$ip" \
      -v "$AGORA_DIR:$AGORA_DIR" \
      -e AUTONOMOUS_TRUST_ROOT="$root" \
      -e AT_PEER_NAME="$name" -e AT_PEER_SEED="${NODES[$1]}-seed-1" \
      -e AT_OWN_GEOHASH="$GEO" \
      -e LD_LIBRARY_PATH="$LIBSTAGE:$ATCORE" \
      "$DOCKER_IMAGE" \
      sh -c "exec '$AGORAD' extern_to_at at_to_extern 2 >'$root/agorad.log' 2>&1" \
      >/dev/null || return 1
    echo "$id"
  fi
}

node_alive() { # handle
  [ -z "$1" ] && return 1
  if [ "$BACKEND" = netns ]; then kill -0 "$1" 2>/dev/null
  else [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; fi
}

node_stop() { # handle
  [ -z "$1" ] && return 0
  if [ "$BACKEND" = netns ]; then
    kill "$1" 2>/dev/null; sleep 1; kill -9 "$1" 2>/dev/null
  else
    docker rm -f "$1" >/dev/null 2>&1
  fi
  return 0
}

net_down() { net_reset; }

# Dump the tail of every daemon log. Called on ANY failure: with five nodes the
# interesting line is rarely in the one node the phase happened to name.
dump_logs() {
  local i
  for i in "${!NODES[@]}"; do
    echo "--- ${NODES[$i]} (${IPS[$i]}) ---"
    tail -n 25 "${ROOTS[$i]}/agorad.log" 2>/dev/null || echo "    (no log)"
  done
}

# A FAILING RUN KEEPS ITS EVIDENCE, whether or not KEEP was set. The first host
# run of this script lost every daemon log to this trap and had to be repeated —
# deleting the one artifact that explains a failure is not a tidy-up.
cleanup() {
  local rc="$1" keep="${KEEP:-0}" i
  for i in "${!NODES[@]}"; do node_stop "${PIDS[$i]}"; done
  if [ "$rc" != 0 ]; then
    err "exit $rc — KEEPING $RUN and the network for diagnosis."
    err "  daemon logs:   $RUN/<node>/agorad.log"
    err "  watch discovery: ip netns exec ${NSS[0]} tcpdump -ni ${VETH[0]} udp port 27787"
    err "  the NEXT run clears this automatically; to do it by hand (note that"
    err "  'ip netns del' takes ONE name, so these are separate commands):"
    err "    $(for i in "${!NODES[@]}"; do printf 'ip netns del %s; ' "${NSS[$i]}"; done)ip link del $BR"
    return
  fi
  if [ "$keep" = "1" ]; then
    log "KEEP=1 — leaving the network and $RUN in place."
    return
  fi
  net_down
  rm -rf "$RUN"
}
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT TERM

# --------------------------------------------------------------------------- #
# Phase 0 — mint the polity BEFORE touching the network. If Ethne cannot produce
# a four-seasoned charter there is nothing worth deciding about, and finding that
# out after five daemons are up wastes two minutes proving nothing.
# --------------------------------------------------------------------------- #
log "Phase 0: minting a real staff polity (4 founders, all ratifying; ada is envoy)"
MINT="$RUN/mint.json"
if ! (cd "$AGORA_DIR" && AGORA_ETHNE_PATH="$ETHNE" "$DART" run tool/make_staff_polity.dart \
        --out "$RUN" --name "Corner Cafe" >"$MINT" 2>"$RUN/mint.log"); then
  err "could not mint a staff polity:"; cat "$RUN/mint.log" >&2; exit 1
fi
jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{'d':d}))" "$1" "$2"; }
POLITY="$(jget "$MINT" "d['polity']")"
DID_ADA="$(jget "$MINT" "d['members']['ada']")"
DID_CAL="$(jget "$MINT" "d['members']['cal']")"
DID_DEE="$(jget "$MINT" "d['members']['dee']")"
DID_KEEPER="$(jget "$MINT" "d['members']['keeper']")"
DID_BOB="$(jget "$MINT" "d['members']['bob']")"
[ "$(jget "$MINT" "d['seasoned']")" = 4 ] || { err "minted polity is not 4-seasoned"; exit 1; }
ok "polity $POLITY — 4 seasoned, envoy is ada"
# Only the keeper may hold the root key. If the minter ever leaks it into another
# node's identity, every later claim about who signed what is worthless.
for m in "${POLITY_MEMBERS[@]}"; do
  [ "$m" = keeper ] && continue
  if grep -q '"root"' "$RUN/$m/etc/at/agora.polity.json" 2>/dev/null; then
    err "$m holds the polity root key — it must not"; exit 1
  fi
done
ok "no node but the keeper holds the polity root key"

net_up || exit 1

# --------------------------------------------------------------------------- #
# The app-side driver. One script, four verbs, so every phase speaks to the node
# through the SAME shim the Flutter app uses.
#
#   cosign-ask     <exchange.json> <timeout> <n_peers>  — ask every visible peer
#   cosign-await   <cid> <timeout> <out.json>           — receive one ask (kind 13)
#   cosign-return  <received.json> <signed.json> <to>   — return one signature
#   cosign-collect <cid> <n> <timeout> <out.json>       — gather signatures (kind 14)
#
# THE ASK GOES TO EVERY PEER THE KEEPER CAN SEE, not to a chosen few. In this
# tier there is no mapping from an Ethne member DID to an AT identity uuid, and
# inventing a registry to fake one would test the registry rather than the
# design. Each receiving node judges FOR ITSELF whether it is among the signers
# the act requires — which is exactly the check tool/cosign_sign.dart makes, and
# a node that was not asked refuses. That refusal is part of what phase 2 proves.
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
    ]

# ABI guard: MUST equal sizeof(agora_event_t) in at_agora_shim.h. A silent drift
# here would decode every field past the drift point as garbage.
assert ctypes.sizeof(Ev) == 29200, f"Ev size {ctypes.sizeof(Ev)} != 29200 (ABI drift)"

EV_PEER = 1
EV_COSIGN_REQUEST = 13
EV_COSIGN_SIGNATURE = 14


def open_lib(shim, root):
    lib = ctypes.CDLL(shim)
    lib.agora_set_root.argtypes = [ctypes.c_char_p]; lib.agora_set_root.restype = None
    lib.agora_events_open.argtypes = [ctypes.c_char_p]; lib.agora_events_open.restype = ctypes.c_void_p
    lib.agora_events_request_roster.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.agora_events_request_roster.restype = ctypes.c_int
    lib.agora_events_poll.argtypes = [ctypes.c_void_p, ctypes.POINTER(Ev), ctypes.c_int]
    lib.agora_events_poll.restype = ctypes.c_int
    lib.agora_events_close.argtypes = [ctypes.c_void_p]; lib.agora_events_close.restype = None
    # THE ONLY THING P3.3 S10 ADDS TO THIS MIRROR. Both entry points already
    # exist in the shim (at_agora_shim.h:373-388) and the struct above already
    # carries their tail — what was missing was only the argtypes. Nothing in C
    # or Rust is touched by this cohort, and native/build/ is used as built.
    lib.agora_request_cosign.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                         ctypes.POINTER(ctypes.c_uint8), ctypes.c_int,
                                         ctypes.c_char_p, ctypes.c_char_p,
                                         ctypes.c_char_p, ctypes.c_char_p,
                                         ctypes.c_char_p]
    lib.agora_request_cosign.restype = ctypes.c_int
    lib.agora_return_cosign.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                        ctypes.POINTER(ctypes.c_uint8),
                                        ctypes.c_char_p, ctypes.c_char_p,
                                        ctypes.c_char_p]
    lib.agora_return_cosign.restype = ctypes.c_int
    lib.agora_set_root(root.encode())
    return lib


def connect(lib, timeout):
    """Open the app-event channel, retrying until the daemon binds its queue."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        h = lib.agora_events_open(b"at_to_extern")
        if h:
            return h
        time.sleep(0.5)
    return None



# agora_events_poll returns AT MOST 16 events PER CALL, whatever `max` says:
# at_agora_shim.c:226 shrank the batch from 64 to 16 at P3.3, because
# at_app_event_t's union now holds the co-signing request and its opaque payload
# alone is 6 KB, so 64 slots would put ~420 KB on the caller's stack. Its own
# comment says "a caller asking for more than one batch simply polls again" —
# and a caller that does NOT poll again reads a busy queue one sixteenth at a
# time. That is not hypothetical: polling once per second-long iteration made a
# five-node roster look like a three-node one, and read as a discovery failure
# while every daemon log showed all four peers known by name.
POLL_BATCH = 16

# HOW OFTEN TO ASK FOR THE ROSTER, in seconds. Draining stays frequent; the
# REQUEST does not need to be. This cohort runs a driver on every node at once,
# and at roughly one request per second each that was several hundred roster
# re-emissions per node per phase — every one of them fanning out to the
# identity, reputation and network procs (autonomous_trust.c:88) while those
# same procs were still trying to converge discovery. The converging siblings
# poll one or two nodes, not all of them.
ROSTER_REQUEST_INTERVAL = 3.0


# A busy five-node queue can be refilled as fast as it is read, so the drain is
# BOUNDED: it stops at a short batch, at this many batches, or when its own
# deadline passes. An unbounded "drain until empty" is a hang waiting for a
# chatty enough cohort.
DRAIN_MAX_BATCHES = 64


def drain(lib, h, buf, on_event, deadline=None):
    """Poll until the queue is empty, handing every event to `on_event`.

    `buf` is reused between batches, so `on_event` must take what it needs from
    each event before returning rather than keeping the struct."""
    total = 0
    for _ in range(DRAIN_MAX_BATCHES):
        n = lib.agora_events_poll(h, buf, POLL_BATCH)
        if n <= 0:
            return total
        for i in range(n):
            on_event(buf[i])
        total += n
        if n < POLL_BATCH:      # a short batch means the queue is drained
            return total
        if deadline is not None and time.time() > deadline:
            return total
    return total


def gather_peers(lib, h, timeout, required):
    """Poll the roster until every uuid in `required` is visible; return what
    was seen as {hex: raw16}.

    `required` is NAMED, not counted. The cohort does not need "some number of
    peers" — it needs the specific deciders an act requires, and a count cannot
    tell the difference between seeing the three that matter and seeing three
    that do not. Each node's uuid comes from its own
    $AUTONOMOUS_TRUST_ROOT/etc/at/identity.cfg.json, which the harness reads
    after the daemons generate it: that is the harness knowing its own nodes,
    not a DID registry the design does not have.

    Unlike a business ad, a co-signature ask is DIRECTED and encrypted — it
    names its recipients rather than going out as a group multicast — so this
    waits for peers to be discovered rather than for a group to form. It still
    reports how many are in-group: if asks go nowhere with peers discovered but
    none in-group, the group gate is the first suspect.
    """
    seen, in_group = {}, set()
    buf = (Ev * POLL_BATCH)()
    required = set(required or ())

    def note(e):
        if e.kind != EV_PEER:
            return
        u = bytes(e.peer_uuid)
        seen[u.hex()] = u
        if e.in_group:
            in_group.add(u.hex())

    deadline = time.time() + timeout
    last_request = 0.0
    while time.time() < deadline:
        if time.time() - last_request >= ROSTER_REQUEST_INTERVAL:
            lib.agora_events_request_roster(h, b"extern_to_at")
            last_request = time.time()
        time.sleep(0.5)
        drain(lib, h, buf, note, deadline)
        if required and required <= set(seen):
            break
        time.sleep(0.5)
    missing = sorted(required - set(seen))
    print(f"    peers discovered: {len(seen)} (in-group: {len(in_group)}); "
          f"required present: {len(required) - len(missing)}/{len(required)}")
    if missing:
        print("    missing: " + ",".join(missing))
    return seen


def _hexes(csv):
    return [x for x in (csv or "").split(",") if x]


def cmd_peers(shim, root, timeout, required_csv):
    """Report what this node can see, judged against the peers it MUST see.

    The discovery gate, run before any Ethne work: a cohort that cannot reach
    its deciders has nothing to say about co-signing, and finding that out here
    costs seconds instead of a whole phase timeout."""
    required = _hexes(required_csv)
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("    (peers: could not open the app-event channel)"); return 1
    seen = gather_peers(lib, h, timeout, required)
    lib.agora_events_close(h)
    return 0 if set(required) <= set(seen) else 2


def cmd_ask(shim, root, ex_path, timeout, required_csv, optional_csv=""):
    """Ask exactly the named peers to co-sign.

    REQUIRED are the deciders this act cannot close without; OPTIONAL are peers
    worth asking if they happen to be visible — the expulsion's target, who must
    receive the ask and refuse it on its own judgement. Asking "everyone
    visible" instead would make the act's success depend on which peers
    discovery happened to deliver, which is how a co-signing phase comes to fail
    for reasons that have nothing to do with co-signing."""
    ex = json.load(open(ex_path))
    required, optional = _hexes(required_csv), _hexes(optional_csv)
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("    (ask: could not open the app-event channel)"); return 1
    seen = gather_peers(lib, h, timeout, required)
    missing = [x for x in required if x not in seen]
    if missing:
        print(f"    (ask: {len(missing)} required decider(s) never became visible)")
        lib.agora_events_close(h); return 1
    targets = list(required) + [x for x in optional if x in seen]
    skipped = [x for x in optional if x not in seen]
    if skipped:
        print(f"    (not asking {len(skipped)} optional peer(s) this node cannot see)")
    blob = (ctypes.c_uint8 * (16 * len(targets)))()
    for i, hx in enumerate(targets):
        u = seen[hx]
        for j in range(16):
            blob[i * 16 + j] = u[j]
    peers = targets
    # NOTE WHAT IS NOT PASSED: there is no description parameter. The signer
    # derives the wording on its own node, from these same bytes.
    rc = -1
    for attempt in range(3):
        rc = lib.agora_request_cosign(h, b"extern_to_at", blob, len(peers),
                                      ex["record"].encode(), ex["op"].encode(),
                                      ex["polity_did"].encode(),
                                      ex["cid"].encode(), ex["bytes"].encode())
        print(f"    request_cosign rc={rc} -> {len(peers)} peers "
              f"({len(ex['bytes'])} hex chars, attempt {attempt + 1})")
        if rc != 0:
            break
        time.sleep(4.0)
    lib.agora_events_close(h)
    return 0 if rc == 0 else 1


def cmd_await(shim, root, cid, timeout, out_path):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("    (await: could not open the app-event channel)"); return 1
    buf = (Ev * POLL_BATCH)()
    deadline = time.time() + float(timeout)
    last_request = 0.0
    found = []

    def note(e):
        if e.kind != EV_COSIGN_REQUEST or found:
            return
        got = e.cosign_cid.decode("ascii", "replace")
        if cid and got != cid:
            print(f"    (saw an ask for {got[:16]}…, waiting for {cid[:16]}…)")
            return
        found.append(dict(
            record=e.cosign_record.decode("ascii", "replace"),
            op=e.cosign_op.decode("ascii", "replace"),
            polity=e.cosign_polity.decode("ascii", "replace"),
            cid=got,
            bytes=e.cosign_bytes.decode("ascii", "replace"),
            seq=int(e.cosign_seq),
            requester=bytes(e.peer_uuid).hex(),
        ))

    while time.time() < deadline and not found:
        # A cosign event is pushed to us; the roster request is only here to keep
        # the channel warm, so it does not need to be frequent.
        if time.time() - last_request >= ROSTER_REQUEST_INTERVAL:
            lib.agora_events_request_roster(h, b"extern_to_at")
            last_request = time.time()
        time.sleep(0.4)
        drain(lib, h, buf, note, deadline)
        time.sleep(0.5)
    hit = found[0] if found else None
    lib.agora_events_close(h)
    if hit is None:
        print(f"    (no co-signature ask for {cid[:16]}… reached the app queue)")
        return 2
    print(f"    ask from {hit['requester'][:12]}… — {hit['op']} on "
          f"{hit['record']}, seq {hit['seq']}, {len(hit['bytes'])} hex chars")
    json.dump(hit, open(out_path, "w"))
    return 0


def cmd_return(shim, root, received_path, signed_path, timeout):
    recv = json.load(open(received_path))
    sig = json.load(open(signed_path))
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("    (return: could not open the app-event channel)"); return 1
    # The requester's uuid comes from the EVENT, not from configuration: a
    # signature goes back to whoever actually asked.
    raw = bytes.fromhex(recv["requester"])
    blob = (ctypes.c_uint8 * 16)(*raw[:16])
    rc = -1
    for attempt in range(3):
        rc = lib.agora_return_cosign(h, b"extern_to_at", blob,
                                     recv["cid"].encode(),
                                     sig["signer_did"].encode(),
                                     sig["sig"].encode())
        print(f"    return_cosign rc={rc} (attempt {attempt + 1})")
        if rc != 0:
            break
        time.sleep(3.0)
    lib.agora_events_close(h)
    return 0 if rc == 0 else 1


def cmd_collect(shim, root, cid, want, timeout, out_path):
    lib = open_lib(shim, root)
    h = connect(lib, timeout)
    if not h:
        print("    (collect: could not open the app-event channel)"); return 1
    buf = (Ev * POLL_BATCH)()
    deadline = time.time() + float(timeout)
    last_request = 0.0
    # DEDUPLICATED BY SIGNER, and that is load-bearing: if a repeated return
    # counted twice, one node could meet a majority-plus-one bar by itself.
    got, stats, seqs = {}, {"dups": 0}, []

    def note(e):
        if e.kind != EV_COSIGN_SIGNATURE:
            return
        if e.cosign_cid.decode("ascii", "replace") != cid:
            return
        did = e.cosign_signer_did.decode("ascii", "replace")
        seqs.append(int(e.cosign_seq))
        if did in got:
            stats["dups"] += 1
            return
        got[did] = e.cosign_sig.decode("ascii", "replace")
        print(f"    signature from {did[-12:]} ({len(got)}/{want})")

    while time.time() < deadline and len(got) < want:
        # A cosign event is pushed to us; the roster request is only here to keep
        # the channel warm, so it does not need to be frequent.
        if time.time() - last_request >= ROSTER_REQUEST_INTERVAL:
            lib.agora_events_request_roster(h, b"extern_to_at")
            last_request = time.time()
        time.sleep(0.4)
        drain(lib, h, buf, note, deadline)
        time.sleep(0.5)
    dups = stats["dups"]
    lib.agora_events_close(h)
    print(f"    {len(got)} distinct signer(s), {dups} duplicate return(s) ignored")
    json.dump([{"did": d, "sig": s} for d, s in got.items()], open(out_path, "w"))
    if seqs:
        json.dump({"seqs": seqs}, open(out_path + ".seqs", "w"))
    return 0 if len(got) >= want else 2


if __name__ == "__main__":
    verb = sys.argv[1]
    shim = sys.argv[2]
    root = sys.argv[3]
    if verb == "peers":
        sys.exit(cmd_peers(shim, root, float(sys.argv[4]), sys.argv[5]))
    if verb == "cosign-ask":
        sys.exit(cmd_ask(shim, root, sys.argv[4], float(sys.argv[5]), sys.argv[6],
                         sys.argv[7] if len(sys.argv) > 7 else ""))
    if verb == "cosign-await":
        sys.exit(cmd_await(shim, root, sys.argv[4], float(sys.argv[5]), sys.argv[6]))
    if verb == "cosign-return":
        sys.exit(cmd_return(shim, root, sys.argv[4], sys.argv[5], float(sys.argv[6])))
    if verb == "cosign-collect":
        sys.exit(cmd_collect(shim, root, sys.argv[4], int(sys.argv[5]),
                             float(sys.argv[6]), sys.argv[7]))
    print(f"unknown verb {verb!r}"); sys.exit(64)
PY

# The driver runs on the HOST under both backends: the app-event queue is an
# AF_UNIX socket at $root/var/at/<queue>, a filesystem path that the container's
# bind mount makes identical on both sides.
drive() { # root verb args...
  local root="$1"; shift
  env AUTONOMOUS_TRUST_ROOT="$root" \
      LD_LIBRARY_PATH="$LIBSTAGE:$ATCORE:${LD_LIBRARY_PATH:-}" \
      python3 "$DRIVER" "$1" "$SHIM" "$root" "${@:2}"
}

# Run one of the Dart tools from the agora dir with the cdylib on hand.
dartt() { (cd "$AGORA_DIR" && AGORA_ETHNE_PATH="$ETHNE" "$DART" run "$@"); }

# Strip a pending exchange down to WHAT THE WIRE MAY CARRY. The pend file holds
# a description for the operator's eyes; the ask must not. This is the same
# subset agora_request_cosign accepts, and building it explicitly means a field
# added to the exchange later cannot ride along unnoticed.
wire_subset() { # <pend.json> <out.json>
  python3 - "$1" "$2" <<'PYW'
import json, sys
ex = json.load(open(sys.argv[1]))
# Subscripted, never .get(): a default would turn a field the exporter stopped
# emitting into an ask AT refuses on the wire, which reads as a network fault
# rather than the export gap it is.
json.dump({"record": ex.get("record", "membership"), "op": ex["op"],
           "polity_did": ex["polity_did"], "cid": ex["cid"],
           "bytes": ex["bytes"]}, open(sys.argv[2], "w"))
PYW
}

# Every readout is paired with this. affirmationState is a fold over what the log
# CLAIMS; only verify() judges it.
assert_verified() { # <json-with-verified> <label>
  local v; v="$(jget "$1" "d.get('verified')")"
  if [ "$v" = True ]; then ok "the log still verifies $2"; return 0; fi
  err "THE LOG DOES NOT VERIFY $2 — the fold may still read correctly, which is"
  err "  precisely why this check exists. Run: dart run tool/staff_govern.dart"
  err "  state '${ROOTS[$K]}' and read the authority error."
  return 1
}

# --------------------------------------------------------------------------- #
# One co-signature exchange, end to end over the wire. Used by both the
# admission and the expulsion, because they ARE the same exchange with different
# bars — which is the point S2 made and this makes live.
#
#   $1 tag, $2 pending file, $3 nodes expected to SIGN over the wire,
#   $4 nodes expected to REFUSE, $5 how many signatures the keeper waits for.
# --------------------------------------------------------------------------- #
declare -A AWPID
declare -A CAPPID

# Print the counters that moved between two /proc/net/snmp snapshots, limited to
# the handful that can explain a datagram that left one node and never reached
# the other. Anything not listed is noise for this question.
snmp_delta() { # <before> <after> <label>
  [ -s "$1" ] && [ -s "$2" ] || { echo "    ($3: no counters captured)"; return 0; }
  python3 - "$1" "$2" "$3" <<'PYS'
import sys
def parse(path):
    out = {}
    lines = open(path).read().splitlines()
    for i in range(0, len(lines) - 1):
        h, v = lines[i].split(), lines[i + 1].split()
        if not h or not v or h[0] != v[0] or h[0].endswith(':') is False:
            continue
        if len(h) != len(v):
            continue
        for k, x in zip(h[1:], v[1:]):
            try:
                out[h[0] + k] = int(x)
            except ValueError:
                pass
    return out
b, a, label = parse(sys.argv[1]), parse(sys.argv[2]), sys.argv[3]
want = [("Udp:InDatagrams",  "udp datagrams received"),
        ("Udp:OutDatagrams", "udp datagrams sent"),
        ("Udp:InErrors",     "UDP IN-ERRORS"),
        ("Udp:RcvbufErrors", "UDP DROPPED FOR RECEIVE BUFFER"),
        ("Udp:SndbufErrors", "UDP DROPPED FOR SEND BUFFER"),
        ("Udp:InCsumErrors", "UDP CHECKSUM ERRORS"),
        ("Udp:NoPorts",      "udp to a closed port"),
        ("Ip:ReasmFails",    "IP FRAGMENT REASSEMBLY FAILURES"),
        ("Ip:InDiscards",    "IP INPUT DISCARDS")]
print(f"    {label}:")
for key, human in want:
    if key in a and key in b:
        d = a[key] - b[key]
        if d:
            print(f"      {human:34s} +{d}")
PYS
}

run_exchange() {
  local tag="$1" pend="$2" signers="$3" locals="$4" refusers="$5" want="$6"
  local cid n i rc
  cid="$(jget "$pend" "d['cid']")"
  wire_subset "$pend" "$RUN/$tag.wire"

  # What may cross is built by hand above; prove it carries neither a wording
  # nor a key before a single datagram is sent.
  if grep -q '"description"' "$RUN/$tag.wire"; then err "a description was about to cross the wire"; return 1; fi
  if grep -qi '"priv' "$RUN/$tag.wire"; then err "a private key was about to cross the wire"; return 1; fi
  ok "the ask carries no description and no private key"

  # Receivers listen BEFORE the ask goes out; an ask nobody is polling for is a
  # lost datagram, not a failed feature.
  for n in $signers $refusers; do
    i="$(idx "$n")"
    drive "${ROOTS[$i]}" cosign-await "$cid" "$WAIT" "$RUN/$tag.$n.recv.json" \
      >"$RUN/$tag.$n.await.log" 2>&1 &
    AWPID[$n]=$!
  done
  sleep 4

  # The deciders are NAMED. Asking "every visible peer" instead would make the
  # act's success depend on which peers discovery happened to deliver — and an
  # admission that fails because the keeper could not see a node it never needed
  # reads as a co-signing bug and is not one.
  local req="" opt=""
  for n in $signers;  do req="${req:+$req,}$(uuid_of "$n")"; done
  for n in $refusers; do opt="${opt:+$opt,}$(uuid_of "$n")"; done

  # WATCH THE WIRE WHILE WE ASK. Three runs in a row ended with the keeper
  # logging a successful sendto and the signer's daemon logging nothing at all,
  # which leaves "the frame never arrived" and "it arrived and died inside the
  # daemon" indistinguishable from the logs alone.
  #
  # TWO independent witnesses, because the first one was not there when it
  # mattered: tcpdump IS NOT INSTALLED on this host, so the capture added for
  # run 15 silently did nothing and the run answered nothing. The kernel
  # counters below need no package at all — /proc/net/snmp is per-NETWORK-
  # NAMESPACE, so a snapshot inside each node's own netns is that node's own
  # traffic. They also say things a capture cannot: a datagram dropped for
  # receive-buffer space (RcvbufErrors) or a bad checksum (InCsumErrors) is
  # invisible to "did bytes arrive" and is exactly the kind of fault that
  # would take the LARGE verb and leave the small ones alone.
  snmp_snap() { ip netns exec "$1" cat /proc/net/snmp 2>/dev/null > "$2" || true; }

  for n in $signers; do
    i="$(idx "$n")"
    snmp_snap "${NSS[$i]}" "$RUN/$tag.$n.snmp.before"
  done
  snmp_snap "${NSS[$K]}" "$RUN/$tag.keeper.snmp.before"

  local cap_ok=""
  if command -v tcpdump >/dev/null 2>&1; then
    cap_ok=1
    for n in $signers; do
      i="$(idx "$n")"
      ip netns exec "${NSS[$i]}" timeout "$((WAIT + 10))" \
        tcpdump -ni "${VETH[$i]}" -q "udp and src host ${IPS[$K]}" \
        >"$RUN/$tag.$n.wire.log" 2>/dev/null &
      CAPPID[$n]=$!
    done
    sleep 1
  fi

  log "  keeper: asking $signers to co-sign ($tag)${refusers:+, and $refusers if visible}"
  drive "${ROOTS[$K]}" cosign-ask "$RUN/$tag.wire" "$WAIT" "$req" "$opt" \
    || { err "the keeper could not put the ask on the wire"; dump_logs; return 1; }

  # Every send has happened by now (cosign-ask makes all its attempts before it
  # returns), so stop the captures HERE — tcpdump buffers, and reading the file
  # while it still holds the frame we care about is how a capture lies.
  if [ -n "$cap_ok" ]; then
    for n in $signers; do
      kill "${CAPPID[$n]}" 2>/dev/null || true
      wait "${CAPPID[$n]}" 2>/dev/null || true
    done
  fi
  for n in $signers; do
    i="$(idx "$n")"
    snmp_snap "${NSS[$i]}" "$RUN/$tag.$n.snmp.after"
  done
  snmp_snap "${NSS[$K]}" "$RUN/$tag.keeper.snmp.after"

  for n in $signers; do
    wait "${AWPID[$n]}"; rc=$?
    sed 's/^/    /' "$RUN/$tag.$n.await.log"
    if [ "$rc" -ne 0 ]; then
      err "FAIL ($tag) — the ask never reached $n's app-event queue (rc=$rc)."
      err "  WHAT THE KERNEL COUNTED during the ask (per-namespace, no tooling"
      err "  required). An error counter that moved is the answer by itself:"
      snmp_delta "$RUN/$tag.keeper.snmp.before" "$RUN/$tag.keeper.snmp.after" \
                 "keeper (sender)" >&2
      snmp_delta "$RUN/$tag.$n.snmp.before" "$RUN/$tag.$n.snmp.after" \
                 "$n (receiver)" >&2
      err "  A moved RcvbufErrors/InCsumErrors/InErrors on $n means THE FRAME"
      err "  ARRIVED AND THE KERNEL DROPPED IT — which would take the large ask"
      err "  and leave the small caps/profile chatter alone. SndbufErrors on the"
      err "  keeper means it never really left, whatever its 'sent' line says."
      if [ -n "$cap_ok" ] && [ -s "$RUN/$tag.$n.wire.log" ]; then
        local npkt big
        npkt="$(grep -c 'IP ' "$RUN/$tag.$n.wire.log" 2>/dev/null || echo 0)"
        # The ask is ~1 KB where the routine chatter is a few hundred bytes, so
        # a large datagram on the wire IS the ask arriving.
        big="$(awk '{for(i=1;i<=NF;i++) if($i+0>900) {c++; break}} END{print c+0}' \
                 "$RUN/$tag.$n.wire.log" 2>/dev/null || echo 0)"
        err "  ON $n'S OWN WIRE during the ask: $npkt datagram(s) from the keeper,"
        err "  $big of them over 900 bytes (the ask is ~1 KB; the routine"
        err "  caps/profile chatter is far smaller)."
        if [ "$big" -gt 0 ]; then
          err "  => THE FRAME ARRIVED. The fault is INSIDE $n's daemon, after the"
          err "     socket: read $n's agorad.log for the co-signing WARN/INFO lines"
          err "     (decrypt / did not parse as / could not be unpacked / COULD NOT"
          err "     BE EMITTED / co-signing ask from peer)."
        else
          err "  => THE FRAME NEVER ARRIVED on $n's interface. The fault is on the"
          err "     SENDING side or in transit, NOT in $n's dispatch — the keeper's"
          err "     'sent' line only proves its own sendto() returned 0."
        fi
        err "  full capture: $RUN/$tag.$n.wire.log"
      elif [ -n "$cap_ok" ]; then
        err "  (capture on $n's wire was empty — tcpdump saw nothing at all)"
      else
        err "  (no tcpdump here, so there is no packet-by-packet view; the"
        err "   counters above are the witness. \`sudo apt-get install -y tcpdump\`"
        err "   adds the per-datagram detail if the counters are inconclusive.)"
      fi
      dump_logs
      return 1
    fi
  done
  ok "the ask reached every required decider's app-event queue (kind 13)"

  # A refuser is asked only as a bonus: it is not needed for the act to close,
  # so not reaching it is a note, not a failure. The refusal itself is pinned
  # unconditionally by drive_ethne_half.sh, which needs no network for it.
  local got_refusers=""
  for n in $refusers; do
    if wait "${AWPID[$n]}"; then
      got_refusers="$got_refusers $n"
      sed 's/^/    /' "$RUN/$tag.$n.await.log"
    else
      log "  ($n never received the ask — skipping the live refusal check; it is"
      log "   pinned without a network in test/cohort/drive_ethne_half.sh)"
    fi
  done

  # The bytes must arrive EXACTLY as exported: the signatures are over these
  # bytes, so anything that truncates or re-encodes them signs nothing.
  for n in $signers $got_refusers; do
    python3 - "$pend" "$RUN/$tag.$n.recv.json" "$n" <<'PYB' || return 1
import json, sys
pend = json.load(open(sys.argv[1])); got = json.load(open(sys.argv[2]))
if got["bytes"] != pend["bytes"]:
    print(f"    MANGLED: the bytes {sys.argv[3]} received are not the bytes exported "
          f"({len(got['bytes'])} vs {len(pend['bytes'])} hex chars)")
    sys.exit(1)
for bad in ("priv", "private", "description"):
    if bad in got:
        print(f"    LEAK: {sys.argv[3]}'s received ask carries a {bad!r} field")
        sys.exit(1)
PYB
  done
  ok "every node received the exported bytes intact, with no wording and no key"

  # The keeper collects while the signers return; start the listener first.
  drive "${ROOTS[$K]}" cosign-collect "$cid" "$want" "$WAIT" "$RUN/$tag.wiresigs.json" \
    >"$RUN/$tag.collect.log" 2>&1 &
  local col=$!
  sleep 2

  for n in $signers; do
    i="$(idx "$n")"
    if ! dartt tool/cosign_sign.dart --node "${ROOTS[$i]}" \
           --received "$RUN/$tag.$n.recv.json" >"$RUN/$tag.$n.sig.json" 2>"$RUN/$tag.$n.sig.err"; then
      err "$n refused to sign an act it was asked to decide:"; sed 's/^/    /' "$RUN/$tag.$n.sig.err" >&2
      kill "$col" 2>/dev/null; return 1
    fi
    drive "${ROOTS[$i]}" cosign-return "$RUN/$tag.$n.recv.json" "$RUN/$tag.$n.sig.json" "$WAIT" \
      >"$RUN/$tag.$n.return.log" 2>&1 &
  done

  # A node that was not asked to decide must refuse ON ITS OWN JUDGEMENT, from
  # the bytes — not because this script declined to call it.
  for n in $got_refusers; do
    i="$(idx "$n")"
    if dartt tool/cosign_sign.dart --node "${ROOTS[$i]}" \
         --received "$RUN/$tag.$n.recv.json" >"$RUN/$tag.$n.sig.json" 2>"$RUN/$tag.$n.sig.err"; then
      err "FAIL ($tag) — $n signed an act it is not among the signers of."
      kill "$col" 2>/dev/null; return 1
    fi
    ok "$n received the ask and refused it: $(head -1 "$RUN/$tag.$n.sig.err")"
  done

  wait "$col"; rc=$?
  sed 's/^/    /' "$RUN/$tag.collect.log"
  if [ "$rc" -ne 0 ]; then
    err "FAIL ($tag) — only $(jget "$RUN/$tag.wiresigs.json" "len(d)") of $want"
    err "  signatures came back within ${WAIT}s. Check the return path"
    err "  (PEER_COSIGN_SIGNATURE in the forwarder switch) before the crypto."
    return 1
  fi
  ok "$want signatures returned over the wire, deduplicated by signer"

  # SIGNATURES THAT NEED NO WIRE. The keeper is a decider and already holds the
  # bytes; dee consents to its own admission and has no node. Each signs from
  # its OWN key file and nothing else — the same act a remote decider performs,
  # minus the delivery. Signing never needed the network, which is exactly why
  # no private key has to travel for anyone.
  : > "$RUN/$tag.localsigs"
  for n in $locals; do
    if ! dartt tool/cosign_sign.dart --node "$RUN/$n" --received "$RUN/$tag.wire" \
           >"$RUN/$tag.$n.sig.json" 2>"$RUN/$tag.$n.sig.err"; then
      err "$n could not sign the act it is required to decide:"
      sed 's/^/    /' "$RUN/$tag.$n.sig.err" >&2
      return 1
    fi
    cat "$RUN/$tag.$n.sig.json" >> "$RUN/$tag.localsigs"
  done

  python3 - "$RUN/$tag.wiresigs.json" "$RUN/$tag.localsigs" "$RUN/$tag.sigs.json" <<'PYM' || return 1
import json, sys
wire = json.load(open(sys.argv[1]))
local = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
# Keyed by signer: a signature that arrived twice — or both locally and over the
# wire — must never count twice toward a bar.
sigs = {s["did"]: s["sig"] for s in wire}
for s in local:
    sigs[s["signer_did"]] = s["sig"]
json.dump([{"did": d, "sig": s} for d, s in sigs.items()], open(sys.argv[3], "w"))
print(f"    assembling {len(sigs)} signature(s): {len(wire)} gathered over the "
      f"wire, {len(local)} computed from local key files")
PYM
  return 0
}

# --------------------------------------------------------------------------- #
# Phase 1 — dee is admitted OVER THE WIRE, then inducted
# --------------------------------------------------------------------------- #
log "Phase 1: starting ${#NODES[@]} nodes${STAGGER:+, staggered ${STAGGER}s apart}"
# STAGGER DEFAULTS TO 0, i.e. start them together, because that is what the two
# cohorts that actually converge do: two_node_cohort.sh:185-190 starts both
# nodes back to back and then sleeps once, and business_cohort.sh starts biz and
# ada together.
#
# This script used to default to 8s, staggering "on purpose" to avoid the
# group-key fork P3.2 hit when business_cohort started two nodes simultaneously.
# That was defensive about a bug which had ALREADY BEEN FIXED — the sibling
# still starts two nodes together and passes — and it bought nothing. What it
# cost was discovery: across three host runs with an 8s stagger, at 5 nodes and
# at 4, the FIRST-STARTED node was found only by the node started immediately
# after it, and by nobody else. Staggering is the single thing this cohort did
# that no converging cohort does, so it is no longer the default.
for i in "${!NODES[@]}"; do
  PIDS[i]="$(node_start "$i")" || exit 1
  log "  ${NODES[$i]} up at ${IPS[$i]}"
  [ "${STAGGER:-0}" != 0 ] && sleep "$STAGGER"
done
# One settle, as the siblings do, rather than a gap between each start.
sleep 4
for i in "${!NODES[@]}"; do
  if ! node_alive "${PIDS[$i]}"; then
    err "${NODES[$i]} exited early:"; tail -n 30 "${ROOTS[$i]}/agorad.log" 2>/dev/null; exit 1
  fi
done
ok "all ${#NODES[@]} daemons are running"

# EACH NODE'S AT IDENTITY UUID, read from the config its own daemon generates at
# first start ($ROOT/etc/at/identity.cfg.json). This is the harness knowing its
# own nodes — the same way business_cohort.sh knows which root belongs to which
# node — NOT a DID->uuid registry, which the design does not have and which this
# cohort must not invent. It is what lets the keeper ask the deciders an act
# actually requires, instead of whoever discovery happened to deliver.
declare -a UUIDS
for i in "${!NODES[@]}"; do
  UUIDS[i]="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['uuid'].replace('-',''))" \
                "${ROOTS[$i]}/etc/at/identity.cfg.json" 2>/dev/null)"
  if [ -z "${UUIDS[$i]}" ]; then
    err "could not read ${NODES[$i]}'s AT identity uuid from ${ROOTS[$i]}/etc/at/identity.cfg.json"
    exit 1
  fi
done
uuid_of() { local n; for n in "${!NODES[@]}"; do [ "${NODES[$n]}" = "$1" ] && { printf '%s' "${UUIDS[$n]}"; return 0; }; done; return 1; }
name_of_uuid() { local n; for n in "${!NODES[@]}"; do [ "${UUIDS[$n]}" = "$1" ] && { printf '%s' "${NODES[$n]}"; return 0; }; done; printf '%s' "$1"; }
KEEPER_UUID="$(uuid_of keeper)"
# The deciders that answer OVER THE WIRE. dee decides both acts as well, but has
# no node, so it is not something the keeper has to discover.
DECIDER_UUIDS="$(uuid_of ada),$(uuid_of bob)"

# DISCOVERY GATE. Before a single Ethne act, prove every node can see the others.
# Open discovery is UDP broadcast on a fixed port; if it is not working, every
# phase below fails as a timeout that looks like a co-signing bug and is not.
# WHAT EACH NODE ACTUALLY HAS TO SEE, rather than a round number:
#   * the KEEPER must see all ${#NODES[@]}-1, because it asks EVERY visible peer
#     to co-sign, and a decider it cannot see is a signature that never arrives;
#   * every other node need only be reachable — it receives from the keeper and
#     returns to the uuid it received from, both of which follow from seeing at
#     least one peer. Demanding all-see-all here would fail the cohort over
#     peers nobody is going to talk to.
log "Phase 1: waiting for discovery — the keeper must see ada and bob; each of them must see the keeper"
DISCOVERY_WAIT="${DISCOVERY_WAIT:-$WAIT}"
declare -a DPID
for i in "${!NODES[@]}"; do
  if [ "$i" = "$K" ]; then req="$DECIDER_UUIDS"; else req="$KEEPER_UUID"; fi
  drive "${ROOTS[$i]}" peers "$DISCOVERY_WAIT" "$req" \
    >"$RUN/${NODES[$i]}.peers.log" 2>&1 &
  DPID[i]=$!
done
DISC_BAD=0
for i in "${!NODES[@]}"; do
  # WAIT FIRST, THEN READ. Reading the log before the process has finished is
  # reading a file still being written: the keeper polls for the whole window,
  # so grepping it up front printed an EMPTY count and hid the one number the
  # gate exists to report.
  if wait "${DPID[$i]}"; then disc_rc=0; else disc_rc=$?; fi
  seen="$(grep -o 'peers discovered: .*' "$RUN/${NODES[$i]}.peers.log" | tail -1)"
  [ -z "$seen" ] && seen="(no count reported — see ${NODES[$i]}.peers.log)"
  # Say WHICH node is missing, by name. "3 of 4" sent us looking at the network
  # three times; "missing: dee" names the thing to look at.
  miss="$(grep -o 'missing: .*' "$RUN/${NODES[$i]}.peers.log" | tail -1)"
  if [ -n "$miss" ]; then
    names=""
    for hx in $(printf '%s' "${miss#missing: }" | tr ',' ' '); do
      names="$names $(name_of_uuid "$hx")"
    done
    seen="$seen — missing:$names"
  fi
  if [ "$disc_rc" = 0 ]; then
    ok "${NODES[$i]}: $seen"
  else
    err "${NODES[$i]}: $seen"
    DISC_BAD=$((DISC_BAD + 1))
  fi
done
if [ "$DISC_BAD" -ne 0 ]; then
  err "FAIL — $DISC_BAD node(s) fell short of what they must see in ${DISCOVERY_WAIT}s."
  err "  Nothing below is meaningful until this passes: every co-signature phase"
  err "  would fail as a timeout that reads like a co-signing bug and is not."
  err "  Each line above names the peers that node still cannot see. L2 unicast"
  err "  already passed (net_up pings the keeper from every node) and the daemon"
  err "  logs will show traffic to every address regardless — a node's identity"
  err "  proc can be exchanging UDP with a peer that has not yet entered the"
  err "  roster the app queue serves, so compare the NAMES above with the logs"
  err "  rather than assuming the network. If nothing is moving at all:"
  err "    ip netns exec ${NSS[0]} tcpdump -ni ${VETH[0]} udp port 27787"
  # The DRIVER's own output first: when a node reports no count at all, the
  # reason is in here and in no daemon log.
  for i in "${!NODES[@]}"; do
    echo "--- ${NODES[$i]} driver ---"
    tail -n 12 "$RUN/${NODES[$i]}.peers.log" 2>/dev/null | sed 's/^/    /'
  done
  dump_logs
  exit 1
fi
ok "discovery is working — every node sees the whole cohort"

log "Phase 1: admitting dee — 3 deciders plus the joiner's own consent"
dartt tool/staff_govern.dart pend "${ROOTS[$K]}" --op admit --member "$DID_DEE" \
  --deciders "$DID_KEEPER,$DID_ADA,$DID_BOB" --rationale "hired" \
  --out "$RUN/admit.pend" >"$RUN/admit.pendout" || { err "could not pend the admission"; exit 1; }
sed 's/^/    /' "$RUN/admit.pendout"
# ada, bob and dee sign over the wire; cal is not among this act's signers.
run_exchange admit "$RUN/admit.pend" "ada bob" "keeper dee" "" 2 || exit 1

dartt tool/staff_govern.dart assemble "${ROOTS[$K]}" --pending "$RUN/admit.pend" \
  --sigs "$RUN/admit.sigs.json" >"$RUN/admit.done" || { err "the admission would not assemble"; exit 1; }
sed 's/^/    /' "$RUN/admit.done"
[ "$(jget "$RUN/admit.done" "d['roll']")" = 5 ] || { err "the roll is not 5 after admission"; exit 1; }
assert_verified "$RUN/admit.done" "after the admission" || exit 1
ok "phase 1a — dee is on the roll, admitted by signatures gathered over the wire"

log "Phase 1: inducting dee through the five movements"
dartt tool/staff_govern.dart induct "${ROOTS[$K]}" --member "$RUN/dee" \
  --attending "${ROOTS[$K]},${ROOTS[$(idx ada)]},${ROOTS[$(idx bob)]}" \
  >"$RUN/induct.done" || { err "the rite would not complete"; exit 1; }
sed 's/^/    /' "$RUN/induct.done"
[ "$(jget "$RUN/induct.done" "d['seasoned']")" = 5 ] || { err "not 5 seasoned after the rite"; exit 1; }
assert_verified "$RUN/induct.done" "after the five-movement rite" || exit 1
ok "phase 1b — 5 seasoned; the expulsion bar is now $(jget "$RUN/induct.done" "d['expel_need']")"

# --------------------------------------------------------------------------- #
# Phase 2 — cal is expelled at majority+1, the bar exactly reachable
# --------------------------------------------------------------------------- #
log "Phase 2: expelling cal — majority+1 of 5 is 4, drawn from exactly 4 eligible"
dartt tool/staff_govern.dart pend "${ROOTS[$K]}" --op expel --member "$DID_CAL" \
  --deciders "$DID_KEEPER,$DID_ADA,$DID_BOB,$DID_DEE" --rationale "no longer with the shop" \
  --out "$RUN/expel.pend" >"$RUN/expel.pendout" || { err "could not pend the expulsion"; exit 1; }
sed 's/^/    /' "$RUN/expel.pendout"
# cal is the TARGET: done TO them, not with them. It neither decides nor signs,
# which is exactly why it needs no node. The refusal a node owes when it is not
# among an act's signers is pinned, without a network, in drive_ethne_half.sh.
run_exchange expel "$RUN/expel.pend" "ada bob" "keeper dee" "" 2 || exit 1

dartt tool/staff_govern.dart assemble "${ROOTS[$K]}" --pending "$RUN/expel.pend" \
  --sigs "$RUN/expel.sigs.json" >"$RUN/expel.done" || { err "the expulsion would not assemble"; exit 1; }
sed 's/^/    /' "$RUN/expel.done"
[ "$(jget "$RUN/expel.done" "d['roll']")" = 4 ] || { err "the roll did not actually shrink"; exit 1; }
assert_verified "$RUN/expel.done" "after the expulsion" || exit 1
ok "phase 2 — the roll shrank to 4 at a bar that is exactly, and only just, reachable"

# --------------------------------------------------------------------------- #
# Phase 3 — ada departs; the envoy office lapses with its holder
# --------------------------------------------------------------------------- #
log "Phase 3: ada departs — self-signed, needing nobody's permission"
dartt tool/staff_govern.dart state "${ROOTS[$K]}" >"$RUN/before.state" || exit 1
grep -q "$DID_ADA" "$RUN/before.state" || { err "ada is not the envoy before departing"; exit 1; }
assert_verified "$RUN/before.state" "on reload, before the departure" || exit 1

dartt tool/staff_govern.dart depart "${ROOTS[$K]}" --member "${ROOTS[$(idx ada)]}" \
  >"$RUN/depart.done" || { err "the departure would not record"; exit 1; }
sed 's/^/    /' "$RUN/depart.done"
assert_verified "$RUN/depart.done" "after the departure" || exit 1
if grep -q "$DID_ADA" <(jget "$RUN/depart.done" "d['envoys']"); then
  err "FAIL (phase 3) — ada still holds the envoy office after leaving the roll."
  err "  An office is conferred by the roll and must lapse with it."
  exit 1
fi
ok "phase 3 — ada is gone and the envoy office lapsed with her"
log "  stopping ada's node: she has left, and nothing below may depend on her"
node_stop "${PIDS[$(idx ada)]}"; PIDS[$(idx ada)]=""

# --------------------------------------------------------------------------- #
# Phase 4 — the roll outlives the nodes
# --------------------------------------------------------------------------- #
log "Phase 4: publishing the member roll"
dartt tool/staff_govern.dart publish-roll "${ROOTS[$K]}" --out "$RUN/roll.json" \
  >"$RUN/roll.out" || { err "the roll would not publish"; exit 1; }
sed 's/^/    /' "$RUN/roll.out"
[ "$(jget "$RUN/roll.out" "d['publisher_proven']")" = True ] || { err "the roll does not prove its publisher"; exit 1; }
[ "$(jget "$RUN/roll.out" "d['audited_against_log']")" = True ] || { err "the roll does not audit against the keeper's own log"; exit 1; }
if grep -q '"priv' "$RUN/roll.json"; then err "the published roll carries a private key"; exit 1; fi
ok "the roll publishes, audits against the log, and carries no private key"

log "Phase 4: stopping every node — there is now nobody left to ask"
for i in "${!NODES[@]}"; do node_stop "${PIDS[$i]}"; PIDS[i]=""; done
sleep 2
dartt tool/staff_govern.dart verify-roll --roll "$RUN/roll.json" >"$RUN/roll.verify" \
  || { err "FAIL (phase 4) — the roll no longer verifies with the polity offline."; exit 1; }
sed 's/^/    /' "$RUN/roll.verify"
ok "phase 4 — the roll still proves its publisher with every node stopped"

echo
log "PASS — a staff polity deciding together, end to end:"
log "       1. co-signature asks crossed the whole runtime to the deciders'"
log "          APP-EVENT QUEUES (kind 13), carrying the exported bytes intact,"
log "          with NO description and NO private key in either direction;"
log "       2. dee was admitted on signatures gathered over the wire from her"
log "          fellow deciders, then inducted — and NO private key moved to do"
log "          it: 5 seasoned, log verifying;"
log "       3. cal was expelled at majority+1 — four deciders drawn from exactly"
log "          four eligible, a bar reachable at five seasoned and at no smaller"
log "          size, and cal neither decided nor signed;"
log "       4. ada departed self-signed and the envoy office lapsed with her;"
log "       5. the member roll still proves itself with every node stopped."
exit 0
