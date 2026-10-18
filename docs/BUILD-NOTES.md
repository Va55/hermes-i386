# Build notes

## Where and how long

Built on an 8-core / 31 GB RAM Debian 13 amd64 host, inside a **bookworm i386
chroot** (so the output links against glibc 2.36 and therefore runs on the
bookworm target).

| | Node 20.20.2 | Node 22.22.0 |
|---|---|---|
| Real time | ~38 min | **63 min 19 s** |
| CPU time | — | 457 min 32 s (across 8 cores) |
| Objects | 3772 | 4171 |
| Errors | 0 | 0 |

Do **not** attempt this on the i386 target itself — a Core Duo is roughly 30-50x
slower than the builder used here.

## Resulting binary properties

```
node v22.22.0
ELF 32-bit LSB pie executable, Intel i386
ia32 / linux / v8 12.4.254.21-node.33
GLIBC symbol ceiling: 2.34      (bookworm has 2.36 -> OK)
Bundled npm: 10.9.4
```

The GLIBC ceiling is the property that matters most. Debian's own i386 Node 24
needs 2.43 and is therefore unusable; building in a bookworm chroot is what keeps
our ceiling at 2.34.

## Recipe

```sh
# on a fast amd64 builder, as root
apt-get install -y debootstrap

debootstrap --arch=i386 --variant=minbase \
  --include=build-essential,python3,git,curl,ca-certificates,xz-utils,wget,pkg-config,file,binutils \
  bookworm /srv/i386-bookworm http://deb.debian.org/debian

for m in proc sys dev dev/pts; do
  mountpoint -q /srv/i386-bookworm/$m || mount --bind /$m /srv/i386-bookworm/$m
done
cp /etc/resolv.conf /srv/i386-bookworm/etc/resolv.conf

chroot /srv/i386-bookworm /bin/bash -c '
  set -e
  cd /root
  curl -sLO https://nodejs.org/dist/v22.22.0/node-v22.22.0.tar.xz
  tar xf node-v22.22.0.tar.xz
  cd node-v22.22.0
  export CFLAGS="-msse2" CXXFLAGS="-msse2"       # fix (b)
  ./configure --dest-cpu=ia32 --openssl-no-asm \  # fix (a)
              --prefix=/opt/node22
  make -j$(nproc)
'
```

Then assemble the distributable **without** `make install` — that target
triggers a full ICU rebuild. Copy the pieces by hand instead:

```sh
chroot /srv/i386-bookworm /bin/bash -c '
  S=/root/node-v22.22.0; P=/opt/node22
  mkdir -p $P/bin $P/lib/node_modules
  cp $S/out/Release/node $P/bin/node && strip $P/bin/node
  cp -r $S/deps/npm $P/lib/node_modules/npm
  ln -sf ../lib/node_modules/npm/bin/npm-cli.js $P/bin/npm
  ln -sf ../lib/node_modules/npm/bin/npx-cli.js $P/bin/npx
  cd /opt && tar czf /tmp/node22-i386.tar.gz node22
'
```

`scripts/build-node-i386.sh` does exactly this, parameterised by version.

## Gotchas encountered

- **`make install` is a trap.** It depends on `all`, which re-triggers the ICU
  build (~10+ min of nothing useful). We only need the `node` binary and the
  bundled npm tree; assemble them manually.
- **`--no-binary :all:` in pip is a trap for a different reason** — it applies to
  *build dependencies* too, forcing `maturin` to compile from Rust source instead
  of using its i686 wheel. Use plain `pip install <pkg>` and let pip fall back
  to sdist only when no wheel exists.
- **`config.gypi` is not valid JSON** — it is gypi format with comments. Do not
  try to `json.load()` it to verify flags. `CFLAGS`/`CXXFLAGS` are inherited by
  the generated Makefiles rather than recorded in that file, so grepping it for
  `-msse2` returns 0 even when the flag *is* being applied. The reliable check is
  that `deps/zlib/.../deflate.o` builds without the SSE2 error.

## Artifacts

| File | Size | Notes |
|---|---|---|
| `node22.22.0-i386.tar.gz` | ~43 MB | node + npm + npx + corepack, stripped |
| Node 22 unstripped | 118 MB | |
| Node 22 stripped | 103 MB | |
