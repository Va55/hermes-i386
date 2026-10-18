#!/bin/bash
# build-node-i386.sh — build Node.js for i386 (ia32) targeting Debian bookworm.
#
# Run this on a FAST amd64 host with root. It creates (or reuses) a bookworm
# i386 chroot so the resulting binary links against glibc 2.36 and therefore
# runs on Debian 12 i386 targets. Building on the i386 target itself is not
# practical (~30-50x slower).
#
#   sudo bash build-node-i386.sh [VERSION] [CHROOT]
#   sudo bash build-node-i386.sh 22.22.0
#
# Output: <CHROOT>/tmp/node<MAJOR>-i386.tar.gz  (node + npm + npx + corepack)
#
set -euo pipefail

NODE_VER="${1:-22.22.0}"
CHROOT="${2:-/srv/i386-bookworm}"
MAJOR="${NODE_VER%%.*}"
PREFIX="/opt/node${MAJOR}"
ARTIFACT="${CHROOT}/tmp/node${MAJOR}-i386.tar.gz"

if [ "$(id -u)" != "0" ]; then
    echo "error: must run as root (needs debootstrap/mount/chroot)" >&2
    exit 1
fi

echo "=== build-node-i386: Node v${NODE_VER} -> ${PREFIX} ==="
echo "    chroot: $CHROOT"
echo

# --- 1. bookworm i386 chroot ------------------------------------------------
if [ ! -x "${CHROOT}/bin/bash" ]; then
    echo "--- creating bookworm i386 chroot ---"
    command -v debootstrap >/dev/null || {
        apt-get update -qq
        apt-get install -y -qq debootstrap
    }
    debootstrap --arch=i386 --variant=minbase \
        --include=build-essential,python3,git,curl,ca-certificates,xz-utils,wget,pkg-config,file,binutils \
        bookworm "$CHROOT" http://deb.debian.org/debian
else
    echo "--- reusing existing chroot (debian $(cat "${CHROOT}/etc/debian_version" 2>/dev/null)) ---"
fi

for m in proc sys dev dev/pts; do
    mountpoint -q "${CHROOT}/${m}" 2>/dev/null || mount --bind "/${m}" "${CHROOT}/${m}" 2>/dev/null || true
done
cp -f /etc/resolv.conf "${CHROOT}/etc/resolv.conf" 2>/dev/null || true

# --- 2. fetch + configure ---------------------------------------------------
echo
echo "--- fetching source ---"
chroot "$CHROOT" /bin/bash -c "
set -e
cd /root
[ -f node-v${NODE_VER}.tar.xz ] || curl -sL -o node-v${NODE_VER}.tar.xz \
    https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}.tar.xz
[ -d node-v${NODE_VER} ] || tar xf node-v${NODE_VER}.tar.xz
echo \"    source: \$(ls -la node-v${NODE_VER}.tar.xz | awk '{print \$5}') bytes\"
"

echo
echo "--- configuring for ia32 ---"
echo "    --openssl-no-asm : Node's bundled OpenSSL asm ships unexpanded perlasm"
echo "                       (%ifdef __CET__) that GNU as cannot parse"
echo "    -msse2           : deps/zlib/slide_hash_simd.h uses SSE2 intrinsics,"
echo "                       not enabled by default on i386"
chroot "$CHROOT" /bin/bash -c "
set -e
cd /root/node-v${NODE_VER}
rm -rf out
export CFLAGS='-msse2' CXXFLAGS='-msse2'
./configure --dest-cpu=ia32 --openssl-no-asm --prefix=${PREFIX}
"

# --- 3. build ---------------------------------------------------------------
echo
echo "--- building with $(nproc) jobs (expect 30-70 minutes) ---"
chroot "$CHROOT" /bin/bash -c "
set -e
cd /root/node-v${NODE_VER}
export CFLAGS='-msse2' CXXFLAGS='-msse2'
time make -j\$(nproc)
"

# --- 4. assemble distributable ---------------------------------------------
# NOTE: do not use 'make install' -- it re-triggers a full ICU build.
echo
echo "--- assembling node + npm ---"
chroot "$CHROOT" /bin/bash -c "
set -e
S=/root/node-v${NODE_VER}
P=${PREFIX}
rm -rf \$P
mkdir -p \$P/bin \$P/lib/node_modules

cp \$S/out/Release/node \$P/bin/node
strip \$P/bin/node

cp -r \$S/deps/npm \$P/lib/node_modules/npm
ln -sf ../lib/node_modules/npm/bin/npm-cli.js \$P/bin/npm
ln -sf ../lib/node_modules/npm/bin/npx-cli.js \$P/bin/npx

if [ -d \$S/deps/corepack ]; then
    cp -r \$S/deps/corepack \$P/lib/node_modules/corepack
    ln -sf ../lib/node_modules/corepack/dist/corepack.js \$P/bin/corepack
fi

cd /opt && tar czf /tmp/node${MAJOR}-i386.tar.gz \$(basename \$P)
"

chmod 644 "$ARTIFACT" 2>/dev/null || true

# --- 5. verify --------------------------------------------------------------
echo
echo "--- verification ---"
chroot "$CHROOT" /bin/bash -c "
  export PATH=${PREFIX}/bin:\$PATH
  echo \"    node : \$(node --version)\"
  echo \"    npm  : \$(npm --version)\"
  echo \"    arch : \$(node -p 'process.arch + \" / \" + process.platform + \" / v8 \" + process.versions.v8')\"
"
echo "    glibc ceiling : $(objdump -T "${CHROOT}${PREFIX}/bin/node" 2>/dev/null \
        | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -uV | tail -1)"
echo "    artifact      : $ARTIFACT ($(stat -c %s "$ARTIFACT" 2>/dev/null || echo '?') bytes)"
echo
echo "=== done ==="
