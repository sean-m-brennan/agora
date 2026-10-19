#!/usr/bin/env bash
#
# repeat.sh — run one cohort N times, to catch a defect that shows once in many
# runs (AT ISSUES §2.61: the rep-2368077 group-key fork, seen once in 15
# reputation runs).
#
# Each pass runs with KEEP=1, so the cohort leaves its network and its run
# directory up; this script then removes the network namespaces and links the
# pass created (so the next pass starts clean) and scans the run's logs with
# tools/key_fork_scan.py. A run directory is kept when the pass failed OR the
# scan found the fork shape, and deleted otherwise, so N passes do not fill
# .coh/. Run it as yourself; it re-runs itself under sudo like run_all.sh.
#
# Usage:
#   ./test/cohort/repeat.sh reputation 20
#   ./test/cohort/repeat.sh reputation 20 --stop     # stop at the first kept run
#   WAIT=120 ./test/cohort/repeat.sh reputation 20   # env passes through
#
# Exit status: the number of kept runs (failed or fork-shaped).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGORA_DIR="${AGORA_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

usage() { sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; }

ARGS=("$@")
NAME="${1:-}"; COUNT="${2:-}"; STOP=0
[ "${3:-}" = "--stop" ] && STOP=1
if [ -z "$NAME" ] || ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
  usage >&2; exit 2
fi
NAME="${NAME%_cohort.sh}"
SCRIPT="$SCRIPT_DIR/${NAME}_cohort.sh"
[ -f "$SCRIPT" ] || { echo "repeat: no cohort named '$NAME'" >&2; exit 2; }

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E env "PATH=$PATH" AGORA_DIR="$AGORA_DIR" "$0" "${ARGS[@]}"
fi
case ":$PATH:" in *:/usr/sbin:*) ;; *) PATH="$PATH:/usr/sbin" ;; esac
case ":$PATH:" in *:/sbin:*) ;; *) PATH="$PATH:/sbin" ;; esac
export PATH AGORA_DIR
# netns only: the teardown below finds what a pass left by diffing namespaces
# and links, and a docker backend's containers would escape it.
export BACKEND="${BACKEND:-netns}"
[ "$BACKEND" = netns ] || { echo "repeat: BACKEND=netns only" >&2; exit 2; }

LOGS="$AGORA_DIR/.coh/repeat-$NAME-$$"
mkdir -p "$LOGS"
OWNER="${SUDO_USER:-}"
own() { [ -n "$OWNER" ] && chown -R "$OWNER": "$1" 2>/dev/null; true; }

netns_now() { ip netns list 2>/dev/null | awk '{print $1}' | sort; }
links_now() { ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | sort; }

# Remove what this pass added: its namespaces (after killing what still runs
# in them) and then any links left in the root namespace. Links go last and by
# name, since a veth's root-side end can outlive its namespace briefly.
teardown_new() {
  local before_ns="$1" before_links="$2" ns l p
  for ns in $(comm -13 <(echo "$before_ns") <(netns_now)); do
    for p in $(ip netns pids "$ns" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    ip netns del "$ns" 2>/dev/null
  done
  for l in $(comm -13 <(echo "$before_links") <(links_now)); do
    ip link del "$l" 2>/dev/null
  done
}

declare -a VERDICT
kept=0
for i in $(seq 1 "$COUNT"); do
  run="$AGORA_DIR/.coh/${NAME:0:3}-$$-$i"   # short: node socket paths must fit 108 bytes
  echo
  echo "################ $NAME pass $i/$COUNT ($run) ################"
  ns0="$(netns_now)"; links0="$(links_now)"
  start=$(date +%s)
  KEEP=1 AGORA_COHORT_RUN="$run" bash "$SCRIPT" 2>&1 | tee "$LOGS/pass-$i.log"
  rc=${PIPESTATUS[0]}
  secs=$(( $(date +%s) - start ))
  teardown_new "$ns0" "$links0"

  scan="no run dir"
  if [ -d "$run" ]; then
    python3 "$SCRIPT_DIR/tools/key_fork_scan.py" "$run" | tee "$LOGS/scan-$i.txt"
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then scan=clean; else scan="FORK SHAPE"; fi
  fi
  if [ "$rc" -eq 0 ] && [ "$scan" != "FORK SHAPE" ]; then
    VERDICT[$i]="PASS  ${secs}s  $scan"
    [ -d "$run" ] && rm -rf "$run"
  else
    VERDICT[$i]="KEPT  ${secs}s  exit $rc, $scan: $run"
    kept=$((kept + 1))
    own "$run"
  fi
  own "$LOGS"
  if [ "$kept" -gt 0 ] && [ "$STOP" = 1 ]; then
    echo "repeat: stopping at pass $i (--stop)"
    COUNT=$i
    break
  fi
done

echo
echo "================ $NAME x$COUNT ================"
for i in $(seq 1 "$COUNT"); do printf '  %3d  %s\n' "$i" "${VERDICT[$i]:-not run}"; done
echo "  logs: $LOGS"
if [ "$kept" -eq 0 ]; then echo "==> ALL $COUNT PASS, no fork shape"
else echo "==> $kept of $COUNT KEPT"; fi
own "$LOGS"
exit "$kept"
