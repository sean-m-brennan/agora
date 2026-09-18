#!/usr/bin/env bash
#
# drive_ethne_half.sh — Phase 3 P3.3 pre-flight: every act the live staff cohort
# performs, MINUS THE WIRE.
#
# This is staff_cohort.sh's ground half, and it needs no network, no root, no
# namespaces and no daemons — only the ethne cdylib and dart. Founding,
# seasoning, the five-movement rite, pend/describe/sign/assemble, the expulsion
# at majority+1, the departure, the office lapse and the member roll are all
# ARCHIVE operations, local to whoever holds the log. Only the co-signature
# exchange is a network act, and this script stands in for it by handing each
# node the same byte subset the wire would carry.
#
# WHY IT EXISTS. The live cohort needs root and a kernel that permits
# CLONE_NEWNET, so it runs on a host and not in a sandbox or in CI. Without this
# script an Ethne-side mistake is found five daemons and two minutes into a host
# run, far from its cause. With it, everything but the wire is provable in
# thirty seconds, anywhere. It earned its place on the first run: see THE TRAP
# below.
#
# WHAT IT DOES NOT TEST, and must not be read as testing: the wire. Nothing here
# exercises agora_request_cosign, agora_return_cosign, the app-event queues, the
# forwarder, group formation or discovery. A green run here says the polity
# logic is sound; it says nothing whatever about whether an ask crosses. That is
# staff_cohort.sh's job and it requires a host.
#
# THE TRAP, and the reason every phase below ends in a verify() check:
# `affirmationState` is a FOLD OVER WHAT THE LOG CLAIMS. It will report a member
# seasoned, and the roll the right size, while the authority pass refuses the
# whole archive. The first version of this script asserted only the fold and
# printed ALL GREEN over a log that did not verify — the induction rite was
# reciting a pretty phrase instead of the charter's own substrate name, and
# `publish-roll` was quietly reporting `audited_against_log: false`.
# `ethne_polity_roundtrip_test.dart:280` warns about exactly this split. Pair
# every readout with `verify()`; an assertion that reads only the claim is worse
# than no assertion, because it reports success.
#
# Unlike the cohort scripts this one does NOT stop at the first failure: it
# counts them and keeps going, because when the polity logic breaks it is far
# more useful to see every phase that broke than the first.
#
# Requirements: python3, dart (Flutter SDK on PATH), and the ethne cdylib
# (./build.sh, or set AGORA_ETHNE_PATH).
#
# Usage:
#   ./test/cohort/drive_ethne_half.sh
#   KEEP=1 ./test/cohort/drive_ethne_half.sh     # leave the run dir for inspection
#
# Exit status is the number of failed assertions, 0 on a clean run.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_AGORA_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "$PWD")"
AGORA_DIR="${1:-${AGORA_DIR:-$DEFAULT_AGORA_DIR}}"
AGORA_DIR="$(cd "$AGORA_DIR" 2>/dev/null && pwd || echo "$AGORA_DIR")"
ETHNE="${AGORA_ETHNE_PATH:-$AGORA_DIR/native/build/libethne_agora.so}"

# Same layout as the cohort scripts, so KEEP=1 leaves its evidence where you
# would already go looking for it.
RUN="$AGORA_DIR/.cohort/drive-$$"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; FAILED=$((FAILED + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }
FAILED=0

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
if ! have python3; then printf 'ERR: python3 not found.\n' >&2; exit 1; fi
if ! have dart; then printf "ERR: 'dart' not found; add the Flutter SDK to PATH.\n" >&2; exit 1; fi
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

# Run a command as whoever invoked sudo, when there is such a person. `flutter
# pub get` below is the only caller: it writes .dart_tool/ and the pub cache,
# both of which belong to that user, and as root it leaves root-owned files
# their next ordinary build cannot rewrite. PATH is passed explicitly because
# sudoers secure_path would otherwise drop the Flutter SDK on the way down.
as_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" -E env "PATH=$PATH" "$@"
  else
    "$@"
  fi
}
if [ ! -e "$ETHNE" ]; then
  printf 'ERR: missing the ethne cdylib: %s\n' "$ETHNE" >&2
  printf "ERR: build first: (cd '%s' && ./build.sh)\n" "$AGORA_DIR" >&2
  exit 1
fi
# `.dart_tool/package_config.json` intermittently gets rewritten WITHOUT the
# Flutter SDK packages, after which `package:ffi` stops resolving and every tool
# below dies with "'Utf8' isn't a type" / "calloc isn't defined" — which reads
# like a broken binding and is nothing of the kind. It also holds ABSOLUTE paths
# into $HOME/.pub-cache, so it goes stale on its own whenever the checkout moves
# between machines or $HOME changes underneath it — same wall of errors, same
# cure. --offline because the cache already holds these packages and a test
# harness has no business reaching pub.dev; as_user because pub get writes the
# invoking user's files, not root's.
if have flutter; then
  (cd "$AGORA_DIR" && as_user flutter pub get --offline) >/dev/null 2>&1 \
    || printf 'WARN: flutter pub get failed; package:ffi may not resolve.\n' >&2
fi
mkdir -p "$RUN" || exit 1

cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    log "KEEP=1 — leaving $RUN in place."
    return
  fi
  rm -rf "$RUN"
}
trap cleanup EXIT INT TERM

# Read one value out of a JSON file. NOTE this prints JSON (`true`, `"did:…"`),
# unlike staff_cohort.sh's `jget`, which prints Python repr (`True`). The two
# scripts therefore compare against different literals on purpose — do not
# "unify" them without changing every comparison.
jqp() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(eval(sys.argv[2],{'d':d})))" "$1" "$2"; }
jstr() { jqp "$1" "$2" | tr -d '"'; }

# Every readout is paired with this. See THE TRAP above.
verified() { # <file-with-a-verified-field> <label>
  local v; v="$(jqp "$1" "d.get('verified')")"
  if [ "$v" = true ]; then ok "the log still verifies $2"; return 0; fi
  err "THE LOG DOES NOT VERIFY $2 — the fold above may still read correctly,"
  err "  which is exactly why this check exists. For the authority error, run:"
  err "  dart run tool/staff_govern.dart state '$RUN/keeper'"
  return 1
}

dartt() { (cd "$AGORA_DIR" && AGORA_ETHNE_PATH="$ETHNE" "$DART" run "$@"); }

# Stand in for the wire: the asker may send record/op/polity/cid/bytes and
# NOTHING else. Identical to staff_cohort.sh's wire_subset, and deliberately
# written out field by field so that a field added to the exchange later cannot
# ride along unnoticed in either script.
wire_subset() { # <pend.json> <out.json>
  python3 - "$1" "$2" <<'PYW'
import json, sys
ex = json.load(open(sys.argv[1]))
json.dump({"record": ex.get("record", "membership"), "op": ex["op"],
           "polity_did": ex.get("polity_did", ""), "cid": ex["cid"],
           "bytes": ex["bytes"]}, open(sys.argv[2], "w"))
PYW
}

# Each named node signs the received bytes on its own node with its own key,
# which is the whole property the wire half exists to preserve.
sign_round() { # <received.json> <out-sigs.json> <node...>
  local recv="$1" sigf="$2"; shift 2
  local node out
  : > "$sigf.parts"
  for node in "$@"; do
    if ! out="$(dartt tool/cosign_sign.dart --node "$RUN/$node" --received "$recv" 2>"$RUN/$node.signerr")"; then
      err "$node refused to sign an act it was asked to decide: $(head -1 "$RUN/$node.signerr")"
      return 1
    fi
    printf '%s\n' "$out" >> "$sigf.parts"
  done
  python3 - "$sigf.parts" "$sigf" <<'PYS'
import json, sys
sigs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
# Keyed by signer: a repeated signature must never count twice toward a bar.
out = {s["signer_did"]: s["sig"] for s in sigs}
json.dump([{"did": d, "sig": s} for d, s in out.items()], open(sys.argv[2], "w"))
PYS
}

# --------------------------------------------------------------------------- #
# Phase 0 — found, ratify, authorize the envoy, write per-node identities
# --------------------------------------------------------------------------- #
log "Phase 0: founding a 4-member polity, all four ratifying; ada is envoy"
if ! dartt tool/make_staff_polity.dart --out "$RUN" --name "Corner Cafe" \
       >"$RUN/mint.json" 2>"$RUN/mint.log"; then
  printf 'ERR: could not mint a staff polity:\n' >&2; cat "$RUN/mint.log" >&2; exit 1
fi
DID_KEEPER="$(jstr "$RUN/mint.json" "d['members']['keeper']")"
DID_ADA="$(jstr "$RUN/mint.json" "d['members']['ada']")"
DID_BOB="$(jstr "$RUN/mint.json" "d['members']['bob']")"
DID_CAL="$(jstr "$RUN/mint.json" "d['members']['cal']")"
DID_DEE="$(jstr "$RUN/mint.json" "d['members']['dee']")"
if [ "$(jqp "$RUN/mint.json" "d['seasoned']")" = 4 ]; then
  ok "4 seasoned at founding — ratifying a founding seasons that founder"
else
  err "the minted polity is not 4-seasoned"
fi
for n in keeper ada bob cal dee; do
  [ -f "$RUN/$n/etc/at/agora.polity.json" ] || err "no identity was written for $n"
done
# Publishing a roll is signing under the polity's own key. If the minter ever
# leaks that key into another node's identity, every later claim about who
# signed what is worthless.
grep -q '"root"' "$RUN/keeper/etc/at/agora.polity.json" || err "the keeper holds no root key"
for n in ada bob cal dee; do
  if grep -q '"root"' "$RUN/$n/etc/at/agora.polity.json"; then
    err "$n holds the polity root key — it must not"
  fi
done
ok "the keeper alone holds the polity root key"

# --------------------------------------------------------------------------- #
# Phase 1 — dee is admitted, then inducted through the five movements
# --------------------------------------------------------------------------- #
log "Phase 1: admitting dee — 3 deciders plus the joiner's own consent"
dartt tool/staff_govern.dart pend "$RUN/keeper" --op admit --member "$DID_DEE" \
  --deciders "$DID_KEEPER,$DID_ADA,$DID_BOB" --rationale "hired" \
  --out "$RUN/admit.pend" >"$RUN/admit.pendout" \
  || { printf 'ERR: could not pend the admission\n' >&2; exit 1; }
sed 's/^/    /' "$RUN/admit.pendout"
wire_subset "$RUN/admit.pend" "$RUN/admit.wire"
if grep -q '"description"' "$RUN/admit.wire"; then err "a description was about to cross"
else ok "the ask carries no description (P3.3 S5, on the ground)"; fi
if grep -qi '"priv' "$RUN/admit.wire"; then err "a private key was about to cross"
else ok "the ask carries no private key"; fi
sign_round "$RUN/admit.wire" "$RUN/admit.sigs" keeper ada bob dee
dartt tool/staff_govern.dart assemble "$RUN/keeper" --pending "$RUN/admit.pend" \
  --sigs "$RUN/admit.sigs" >"$RUN/admit.done" \
  || { printf 'ERR: the admission would not assemble\n' >&2; exit 1; }
sed 's/^/    /' "$RUN/admit.done"
if [ "$(jqp "$RUN/admit.done" "d['roll']")" = 5 ]; then ok "the roll is 5 after the admission"
else err "the roll is not 5 after the admission"; fi
verified "$RUN/admit.done" "after the admission"

log "Phase 1: inducting dee through the five movements"
dartt tool/staff_govern.dart induct "$RUN/keeper" --member "$RUN/dee" \
  --attending "$RUN/keeper,$RUN/ada,$RUN/bob" >"$RUN/induct.done" \
  || { printf 'ERR: the rite would not complete\n' >&2; exit 1; }
sed 's/^/    /' "$RUN/induct.done"
if [ "$(jqp "$RUN/induct.done" "d['seasoned']")" = 5 ]; then ok "5 seasoned after the rite"
else err "not 5 seasoned after the rite"; fi
# This is the assertion the first version of this script did not have, and the
# one that catches a substrate name that does not match the charter.
verified "$RUN/induct.done" "after the five-movement rite"

# --------------------------------------------------------------------------- #
# Phase 2 — cal is expelled at majority+1, the bar exactly reachable
# --------------------------------------------------------------------------- #
log "Phase 2: expelling cal — majority+1 of 5 is $(jqp "$RUN/induct.done" "d['expel_need']"), from exactly 4 eligible"
dartt tool/staff_govern.dart pend "$RUN/keeper" --op expel --member "$DID_CAL" \
  --deciders "$DID_KEEPER,$DID_ADA,$DID_BOB,$DID_DEE" --rationale "no longer with the shop" \
  --out "$RUN/expel.pend" >"$RUN/expel.pendout" \
  || { printf 'ERR: could not pend the expulsion\n' >&2; exit 1; }
sed 's/^/    /' "$RUN/expel.pendout"
wire_subset "$RUN/expel.pend" "$RUN/expel.wire"
sign_round "$RUN/expel.wire" "$RUN/expel.sigs" keeper ada bob dee
dartt tool/staff_govern.dart assemble "$RUN/keeper" --pending "$RUN/expel.pend" \
  --sigs "$RUN/expel.sigs" >"$RUN/expel.done" \
  || { printf 'ERR: the expulsion would not assemble\n' >&2; exit 1; }
sed 's/^/    /' "$RUN/expel.done"
if [ "$(jqp "$RUN/expel.done" "d['roll']")" = 4 ]; then ok "the roll actually shrank to 4"
else err "the roll did not shrink"; fi
verified "$RUN/expel.done" "after the expulsion"

# --------------------------------------------------------------------------- #
# Phase 3 — ada departs; the envoy office lapses with its holder
# --------------------------------------------------------------------------- #
log "Phase 3: ada departs — self-signed, needing nobody's permission"
dartt tool/staff_govern.dart state "$RUN/keeper" >"$RUN/before.state" \
  || { printf 'ERR: could not read the polity state\n' >&2; exit 1; }
if grep -q "$DID_ADA" "$RUN/before.state"; then ok "ada holds the envoy office before departing"
else err "ada is not the envoy before departing"; fi
verified "$RUN/before.state" "on reload, before the departure"
dartt tool/staff_govern.dart depart "$RUN/keeper" --member "$RUN/ada" \
  >"$RUN/depart.done" || { printf 'ERR: the departure would not record\n' >&2; exit 1; }
sed 's/^/    /' "$RUN/depart.done"
verified "$RUN/depart.done" "after the departure"
# An office is conferred by the roll and lapses with it.
if python3 -c "
import json, sys
d = json.load(open('$RUN/depart.done'))
sys.exit(1 if '$DID_ADA' in json.dumps(d.get('envoys')) else 0)"; then
  ok "envoyState no longer lists ada — the office lapsed with its holder"
else
  err "ada still holds the envoy office after leaving the roll"
fi

# --------------------------------------------------------------------------- #
# Phase 4 — the roll, and what a stranger can establish from it
# --------------------------------------------------------------------------- #
log "Phase 4: publishing the member roll"
dartt tool/staff_govern.dart publish-roll "$RUN/keeper" --out "$RUN/roll.json" \
  >"$RUN/roll.out" || { printf 'ERR: the roll would not publish\n' >&2; exit 1; }
sed 's/^/    /' "$RUN/roll.out"
if [ "$(jqp "$RUN/roll.out" "d['publisher_proven']")" = true ]; then ok "the roll proves its publisher"
else err "the roll does not prove its publisher"; fi
# The verdict the first run got wrong: a roll signed over a log that does not
# verify still proves its PUBLISHER, and only this second verdict notices.
if [ "$(jqp "$RUN/roll.out" "d['audited_against_log']")" = true ]; then
  ok "the roll audits against the log the keeper actually holds"
else err "the roll does not audit against the keeper's log"; fi
if grep -q '"priv' "$RUN/roll.json"; then err "the published roll carries a private key"
else ok "the published roll carries no private key"; fi
if dartt tool/staff_govern.dart verify-roll --roll "$RUN/roll.json" >"$RUN/roll.verify"; then
  ok "the roll verifies standalone — exactly a compact tier's reach"
else err "the roll does not verify standalone"; fi

# --------------------------------------------------------------------------- #
# The refusals cosign_sign.dart owes. Each must exit non-zero, and each exists
# because signing anyway is the habit the two-phase design avoids teaching.
# --------------------------------------------------------------------------- #
log "Refusals: every one of these must be declined"

python3 - "$RUN/admit.wire" "$RUN/bad_cid.wire" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["cid"] = "b3:0000000000000000000000000000000000000000000000000000000000000000"
json.dump(d, open(sys.argv[2], "w"))
PY
if dartt tool/cosign_sign.dart --node "$RUN/ada" --received "$RUN/bad_cid.wire" >/dev/null 2>&1; then
  err "ada signed an ask whose cid did not match its bytes"
else ok "refused a cid that names one act and carries another"; fi

python3 - "$RUN/admit.wire" "$RUN/garbage.wire" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["bytes"] = "deadbeef"; d["cid"] = ""
json.dump(d, open(sys.argv[2], "w"))
PY
if dartt tool/cosign_sign.dart --node "$RUN/ada" --received "$RUN/garbage.wire" >/dev/null 2>&1; then
  err "ada signed bytes it could not read"
else ok "refused bytes that do not describe — nothing there knows what it would sign"; fi

if dartt tool/cosign_sign.dart --node "$RUN/cal" --received "$RUN/admit.wire" >/dev/null 2>&1; then
  err "cal signed an act it is not among the signers of"
else ok "refused an act this node was never asked to decide"; fi

python3 - "$RUN/admit.wire" "$RUN/withpriv.wire" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["priv"] = {"d": "nope"}
json.dump(d, open(sys.argv[2], "w"))
PY
if dartt tool/cosign_sign.dart --node "$RUN/ada" --received "$RUN/withpriv.wire" >/dev/null 2>&1; then
  err "ada accepted an ask carrying a private key"
else ok "refused, loudly, an ask carrying a private key"; fi

echo
if [ "$FAILED" = 0 ]; then
  log "PASS — the Ethne half stands up with no network:"
  log "       founding and seasoning, the five-movement rite, co-signatures"
  log "       assembled from keys that never moved, an expulsion at a bar only"
  log "       just reachable, an office lapsing with its holder, and a roll that"
  log "       proves itself — every one of them paired with verify()."
  log "       THE WIRE IS STILL UNTESTED: run test/cohort/staff_cohort.sh on a host."
else
  err "$FAILED assertion(s) failed — see above."
fi
exit "$FAILED"
