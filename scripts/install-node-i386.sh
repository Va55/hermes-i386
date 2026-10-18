#!/bin/bash
# install-node-i386.sh — install the prebuilt i386 Node on a target machine.
#
#   bash install-node-i386.sh [TARBALL] [PREFIX]
#
# Defaults: TARBALL=../dist/node22.22.0-i386.tar.gz, PREFIX=$HOME/node22
#
# If passwordless sudo is available, symlinks are installed into
# /usr/local/bin (which precedes /usr/bin, so apt's node/npm are left intact).
# Otherwise it prints the PATH line to add.
#
set -euo pipefail

# --- distro detection --------------------------------------------------------
DISTRO="unknown"; LIBC="glibc"
[ -f /etc/os-release ] && . /etc/os-release
case "${ID:-}" in alpine) DISTRO="alpine" ;; esac
ldd --version 2>&1 | grep -qi musl && LIBC="musl"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="${1:-}"
PREFIX="${2:-}"

# find a tarball if not given
if [ -z "$TARBALL" ]; then
    for c in "$HERE/../dist"/node*-i386.tar.gz ./node*-i386.tar.gz; do
        [ -f "$c" ] && TARBALL="$c" && break
    done
fi
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || {
    echo "error: no tarball found. Pass one explicitly." >&2
    echo "usage: $0 <tarball> [prefix]" >&2
    exit 1
}

# musl check: the prebuilt Node in dist/ is glibc-linked
if [ "$LIBC" = "musl" ]; then
    echo ""
    echo "WARNING: this is a musl system (Alpine)."
    echo "The prebuilt Node in dist/ is glibc-linked and will NOT run on musl."
    echo ""
    echo "Options:"
    echo "  1. Use the system node:  sudo apk add --no-cache nodejs"
    echo "  2. Build a musl Node from source (see build-node-i386.sh)"
    echo "  3. Pass a musl-linked tarball explicitly:  $0 <musl-node.tar.gz>"
    echo ""
    echo "Continuing — if the binary is glibc-linked this will fail at runtime."
    echo ""
fi

# derive a prefix from the tarball name if not given
if [ -z "$PREFIX" ]; then
    base="$(basename "$TARBALL")"          # node22.22.0-i386.tar.gz
    PREFIX="$HOME/${base%%-i386.tar.gz}"    # -> $HOME/node22.22.0
    # collapse to the major version dir for cosy paths
    PREFIX="$HOME/node$(echo "${base#node}" | cut -d. -f1)"
fi

echo "=== install-node-i386 ==="
echo "    tarball: $TARBALL"
echo "    prefix : $PREFIX"
echo

# --- extract ---------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar xzf "$TARBALL" -C "$TMP"

# the archive may contain node22/ or the files directly
SRC="$TMP"
if [ -d "$TMP"/node2* ]; then
    SRC="$(echo "$TMP"/node2* | head -1)"
fi
[ -x "$SRC/bin/node" ] || { echo "error: no bin/node in tarball" >&2; exit 1; }

rm -rf "$PREFIX"
mkdir -p "$PREFIX"
cp -a "$SRC"/. "$PREFIX"/

NODE_BIN="$PREFIX/bin/node"
chmod +x "$NODE_BIN" "$PREFIX"/bin/* 2>/dev/null || true

echo "--- installed ---"
"$NODE_BIN" --version | sed 's/^/    node: /'
echo "    arch: $("$NODE_BIN" -p 'process.arch + " / " + process.platform')"

# --- link into PATH --------------------------------------------------------
echo
if sudo -n true 2>/dev/null; then
    for b in node npm npx corepack; do
        [ -e "$PREFIX/bin/$b" ] && sudo -n ln -sf "$PREFIX/bin/$b" "/usr/local/bin/$b"
    done
    echo "--- linked into /usr/local/bin (apt binaries untouched) ---"
    echo "    node -> $(command -v node)  ($(node --version 2>/dev/null))"
    echo "    npm  -> $(command -v npm)   ($(npm --version 2>/dev/null))"
else
    echo "--- no passwordless sudo; add this to your shell profile ---"
    echo "    export PATH=\"$PREFIX/bin:\$PATH\""
fi

# --- sanity: the whole point ------------------------------------------------
echo
echo "--- capability checks ---"
"$NODE_BIN" -e 'new RegExp("\\p{RGI_Emoji}","v"); console.log("    v-flag regex    : SUPPORTED")' 2>&1 | tail -1
"$NODE_BIN" -e 'const v=process.versions.node.split(".");
const maj=+v[0], min=+v[1];
console.log("    engines ^22.22.0:", maj>22||(maj===22&&min>=22) ? "SATISFIED" : "not satisfied ("+maj+"."+min+")");'
"$NODE_BIN" -e 'console.log("    heap limit      :", (require("v8").getHeapStatistics().heap_size_limit/1048576).toFixed(0), "MB")'
echo
echo "=== done ==="
