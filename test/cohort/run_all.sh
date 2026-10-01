#!/usr/bin/env bash
#
# run_all.sh — run every live cohort test, one after another, and summarize.
#
# Run it as yourself; it re-runs itself under sudo, keeping your PATH (the
# `sudo -E env "PATH=$PATH"` every cohort needs, so dart stays reachable). It
# also appends /usr/sbin and /sbin, which a user PATH often lacks and root
# tools live in.
#
# Each script's output goes to its own log under .coh/run-all-<pid>/ (owned by
# you, not root) and to the terminal. By default every test runs whatever the
# others did, and the exit status is the number that failed.
#
# Usage:
#   ./test/cohort/run_all.sh                       # everything
#   ./test/cohort/run_all.sh hub moderation        # only these (names without _cohort.sh)
#   ./test/cohort/run_all.sh --skip partition,staff
#   ./test/cohort/run_all.sh --fail-fast           # stop at the first failure
#   ./test/cohort/run_all.sh --list                # print the run order and exit
#   WAIT=180 ./test/cohort/run_all.sh              # env passes through to every script
#
# Not run: two_node_gui.sh (a visual check that needs a display and asserts
# nothing). A new *_cohort.sh is picked up automatically, after the ones below.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGORA_DIR="${AGORA_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Cheapest and most basic first, so a broken build shows up in seconds; the
# Ethne pre-flight runs before the staff cohort it stands in for.
ORDER=(two_node reputation moderation business business_post drive_ethne_half
       staff partition community_policy hub device compact)

script_of() {
  case "$1" in
    drive_ethne_half) echo "$SCRIPT_DIR/drive_ethne_half.sh" ;;
    *)                echo "$SCRIPT_DIR/${1}_cohort.sh" ;;
  esac
}

all_tests() {
  local t f n seen=" ${ORDER[*]} "
  for t in "${ORDER[@]}"; do [ -f "$(script_of "$t")" ] && echo "$t"; done
  for f in "$SCRIPT_DIR"/*_cohort.sh; do
    n="$(basename "$f" _cohort.sh)"
    case "$seen" in *" $n "*) ;; *) echo "$n" ;; esac
  done
}

usage() { sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; }

ARGS=("$@")
FAIL_FAST=0 LIST=0 SKIP="" ONLY=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fail-fast) FAIL_FAST=1 ;;
    --list)      LIST=1 ;;
    --skip)      shift; SKIP="${1:-}" ;;
    --skip=*)    SKIP="${1#--skip=}" ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "run_all: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)           ONLY+=("${1%_cohort.sh}") ;;
  esac
  shift
done

mapfile -t AVAILABLE < <(all_tests)
TESTS=()
if [ ${#ONLY[@]} -gt 0 ]; then
  for t in "${ONLY[@]}"; do
    t="${t%.sh}"
    if [ -f "$(script_of "$t")" ]; then TESTS+=("$t")
    else echo "run_all: no cohort named '$t' (try --list)" >&2; exit 2; fi
  done
else
  TESTS=("${AVAILABLE[@]}")
fi
if [ -n "$SKIP" ]; then
  kept=()
  for t in "${TESTS[@]}"; do
    case ",$SKIP," in *",$t,"*) ;; *) kept+=("$t") ;; esac
  done
  TESTS=("${kept[@]}")
fi

if [ "$LIST" = 1 ]; then printf '%s\n' "${TESTS[@]}"; exit 0; fi
[ ${#TESTS[@]} -gt 0 ] || { echo "run_all: nothing to run" >&2; exit 2; }

# Root, keeping the caller's PATH. Done after parsing so --list and --help
# never ask for a password.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E env "PATH=$PATH" AGORA_DIR="$AGORA_DIR" "$0" "${ARGS[@]}"
fi
case ":$PATH:" in *:/usr/sbin:*) ;; *) PATH="$PATH:/usr/sbin" ;; esac
case ":$PATH:" in *:/sbin:*) ;; *) PATH="$PATH:/sbin" ;; esac
export PATH AGORA_DIR

if [ ! -x "$AGORA_DIR/native/build/agorad" ]; then
  echo "run_all: $AGORA_DIR/native/build/agorad is missing; run ./build.sh first (as yourself)." >&2
  exit 2
fi

LOGS="$AGORA_DIR/.coh/run-all-$$"
mkdir -p "$LOGS"
OWNER="${SUDO_USER:-}"
own() { [ -n "$OWNER" ] && chown -R "$OWNER": "$LOGS" 2>/dev/null; true; }

declare -A RESULT SECS
failed=0
for t in "${TESTS[@]}"; do
  echo
  echo "################ $t ################"
  start=$(date +%s)
  # Each script finds the agora dir itself; AGORA_DIR in the env covers a
  # caller's override. PIPESTATUS keeps the script's own status through tee.
  bash "$(script_of "$t")" 2>&1 | tee "$LOGS/$t.log"
  rc=${PIPESTATUS[0]}
  SECS[$t]=$(( $(date +%s) - start ))
  if [ "$rc" -eq 0 ]; then RESULT[$t]=PASS
  else RESULT[$t]="FAIL ($rc)"; failed=$((failed + 1)); fi
  own
  if [ "$rc" -ne 0 ] && [ "$FAIL_FAST" = 1 ]; then
    echo "run_all: stopping at $t (--fail-fast)"
    break
  fi
done

echo
echo "================ cohort summary ================"
for t in "${TESTS[@]}"; do
  printf '  %-18s %-10s %s\n' "$t" "${RESULT[$t]:-not run}" \
    "${SECS[$t]:+${SECS[$t]}s}"
done
echo "  logs: $LOGS"
if [ "$failed" -eq 0 ]; then echo "==> ALL PASS"; else echo "==> $failed FAILED"; fi
own
exit "$failed"
