#!/bin/bash
# provision-all.sh — one-shot setup: install Node, provision hermes, verify.
#
#   bash scripts/provision-all.sh [options]
#
# Options:
#   --skip-node        do not (re)install Node
#   --prefix DIR       Node install location        (default: $HOME/node22)
#   --src DIR          hermes-agent checkout        (default: $HOME/hermes-agent)
#   --tarball FILE     Node artifact                (default: dist/nodeNN-i386.tar.gz)
#   --no-verify        skip the final verification
#   -h, --help         this message
#
# Idempotent: safe to re-run.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SKIP_NODE=0
DO_VERIFY=1
PREFIX="${PREFIX:-$HOME/node22}"
SRC="${HERMES_SRC:-$HOME/hermes-agent}"
TARBALL="${TARBALL:-}"

usage() { sed -n '2,16p' "$HERE/provision-all.sh" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-node) SKIP_NODE=1; shift ;;
        --no-verify) DO_VERIFY=0; shift ;;
        --prefix)    PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --src)       SRC="${2:?--src needs a directory}"; shift 2 ;;
        --tarball)   TARBALL="${2:?--tarball needs a file}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# locate the artifact if not given
if [ -z "$TARBALL" ]; then
    for c in "$ROOT/dist"/node*-i386.tar.gz "$ROOT/dist"/node2*.tar.gz; do
        [ -f "$c" ] && TARBALL="$c" && break
    done
fi

step() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
die()  { printf '\n[FAILED] %s\n' "$*" >&2; exit 1; }

printf 'hermes-i386 — one-shot provisioning\n'
printf '  node prefix : %s\n' "$PREFIX"
printf '  hermes src  : %s\n' "$SRC"
printf '  artifact    : %s\n' "${TARBALL:-(none)}"

# --- 1. node ----------------------------------------------------------------
if [ "$SKIP_NODE" -eq 1 ]; then
    step "1/3 node (skipped)"
elif [ -x "$PREFIX/bin/node" ] && \
     "$PREFIX/bin/node" -e 'const [a,b]=process.versions.node.split(".").map(Number);
                            process.exit((a>22||(a===22&&b>=22))?0:1)' 2>/dev/null; then
    step "1/3 node already satisfies the engines floor ($("$PREFIX/bin/node" --version))"
else
    step "1/3 installing Node for i386"
    [ -n "$TARBALL" ] && [ -f "$TARBALL" ] || die "no Node tarball found in $ROOT/dist"
    bash "$HERE/install-node-i386.sh" "$TARBALL" "$PREFIX" || die "node install failed"
fi

# --- 2. hermes --------------------------------------------------------------
step "2/3 provisioning hermes-agent"
# install-node may have linked into /usr/local/bin; make sure it is visible
export PATH="$PREFIX/bin:$PATH"
HERMES_SRC="$SRC" bash "$HERE/provision-hermes-i386.sh" || die "provisioning failed"

# --- 3. verify --------------------------------------------------------------
if [ "$DO_VERIFY" -eq 1 ]; then
    step "3/3 verifying"
    bash "$HERE/verify-i386.sh" "$SRC" "$PREFIX"
    rc=$?
else
    step "3/3 verify (skipped)"
    rc=0
fi

printf '\n\033[1m>>> done\033[0m\n'
if [ "$rc" -eq 0 ]; then
    cat <<EOF
  Launch:   hermes --tui        (or ~/hermes-tui)
  Expect ~25 s to the first prompt on a slow CPU while the tool-registry
  capability probes run; the banner shows '0 tools · 0 skills' until they
  finish, then updates to the real counts.
EOF
else
    printf '  Verification reported failures — see the [!!] lines above.\n' >&2
fi
exit "$rc"
