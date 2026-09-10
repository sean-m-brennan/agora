#!/usr/bin/env bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Create any include dir that an installed pkg-config .pc file references but
# that does not exist on disk. This works around a class of Ubuntu 25.10+/26.04
# breakage where GTK's dependency chain (via Requires.private, static-only)
# points at header dirs that are not installed — e.g. /usr/include/glycin-2
# (glycin-2.pc) and /usr/include/sysprof-6 (sysprof-capture-4.pc). CMake then
# fails the Flutter runner's generate: PkgConfig::GTK "includes non-existent
# path".
#
# We read the .pc files DIRECTLY (parsing Cflags, expanding ${includedir} etc.)
# rather than invoking pkg-config, so an active conda env — whose pkg-config
# search path shadows the system one — cannot hide them. Empty dirs are safe:
# the referencing deps are static-only and the dynamically linked GTK app
# includes nothing from them.
set -u

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# awk: collect `name=value` vars, then for the Cflags line emit each -I path
# with ${var} references expanded (iteratively, since includedir=${prefix}/include).
read -r -d '' AWKPROG <<'AWK' || true
function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
function expand(s,   k, c) {
  do { c=0; for (k in v) if (index(s, "${" k "}")) { gsub("[$][{]" k "[}]", v[k], s); c=1 } } while (c)
  return trim(s)
}
/^[A-Za-z_][A-Za-z0-9_.]*[ \t]*=/ { e=index($0,"="); n=substr($0,1,e-1); gsub(/[ \t]/,"",n); v[n]=trim(substr($0,e+1)); next }
/^Cflags:/ { cf=substr($0,9); m=split(cf,t," "); for (i=1;i<=m;i++) if (substr(t[i],1,2)=="-I") { p=expand(substr(t[i],3)); if (p!="") print p } }
AWK

created=0
for pcdir in "/usr/lib/$(uname -m)-linux-gnu/pkgconfig" /usr/lib/pkgconfig /usr/share/pkgconfig; do
  [ -d "$pcdir" ] || continue
  for pc in "$pcdir"/*.pc; do
    [ -f "$pc" ] || continue
    awk "$AWKPROG" "$pc"
  done
done | sort -u | {
  while IFS= read -r d; do
    case "$d" in /usr/*|/usr/local/*) ;; *) continue ;; esac
    [ -d "$d" ] && continue
    # ONLY stub known headerless, static-only Requires.private deps. Never stub a
    # core header dir (gtk-3.0, glib-2.0, pango, cairo, ...): if one of THOSE is
    # missing, the -dev package isn't installed, and creating an empty dir would
    # mask that into a later "gtk/gtk.h not found" compile error. Leave it
    # missing so CMake's non-existent-path error names the real problem.
    case "$(basename "$d")" in
      glycin-*|sysprof-*) ;;
      *)
        echo "note: pkg-config references missing include dir '$d' but it is NOT a" >&2
        echo "      known headerless dep — NOT stubbing. Install its -dev package." >&2
        continue ;;
    esac
    echo "==> Creating missing pkg-config include dir '$d' (empty; static-only header)"
    $SUDO mkdir -p "$d" || echo "    (could not create $d; run: sudo mkdir -p $d)"
  done
}
