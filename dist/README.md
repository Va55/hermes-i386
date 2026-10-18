# dist/ — prebuilt artifacts

## node22.22.0-i386.tar.gz

Purpose-built **Node.js 22.22.0 for i386 (ia32)**, targeting Debian 12 bookworm.

Built from source in a bookworm i386 chroot on an 8-core amd64 host, because:

- there are no upstream 32-bit Node builds at all (nodejs.org and
  unofficial-builds both lack `linux-x86`)
- Debian's own i386 Node 24 requires **GLIBC 2.43**, which no released Debian has

Built in a bookworm chroot so the binary's GLIBC ceiling stays at **2.34**,
which runs on bookworm (2.36) and newer.

| Property | Value |
|---|---|
| Version | 22.22.0 |
| Arch | ia32 (Intel i386) |
| V8 | 12.4.254.21-node.33 |
| GLIBC ceiling | 2.34 |
| Bundled npm | 10.9.4 |
| Linkage | dynamic, glibc-linked (interpreter `/lib/ld-linux.so.2`); glibc only — **not** static, **not** musl |
| Runs on | Debian-family i386 with glibc >= 2.34 (bookworm, trixie, sid). Does **not** run on Alpine/musl |
| Size | ~43 MB compressed (node + npm + npx + corepack, stripped) |

### Install

```sh
tar xzf node22.22.0-i386.tar.gz -C ~/
# -> ~/node22/bin/{node,npm,npx,corepack}
export PATH="$HOME/node22/bin:$PATH"
node --version   # v22.22.0
```

Or use `scripts/install-node-i386.sh`, which also creates `/usr/local/bin`
symlinks (leaving apt's node/npm untouched) and runs capability checks.

### Reproducing

`scripts/build-node-i386.sh 22.22.0` rebuilds this from source.
Expect ~63 minutes on 8 cores. See `docs/BUILD-NOTES.md`.

### Trust

This is a locally-built binary, not a distribution artifact. If you would rather
not trust a prebuilt blob, build it yourself — the script is the whole recipe.

### Checksums

Regenerate after any rebuild:

```sh
sha256sum node22.22.0-i386.tar.gz
```

## Checksums

See `SHA256SUMS` in this directory. Current:

```
2bc97496b54e396eae21ba4c03650e1dece65ec5309148ccc915f8294aff1c6b  node22.22.0-i386.tar.gz
```

## libheif-1.23.0-i386.tar.gz

Prebuilt **libheif 1.23.0 for i386**, decode-only (LIGHT mode).

pillow-heif cannot be installed without it: there are no i686 wheels for
`pillow-heif >= 1.3.0`, and Debian's libheif (1.15.1 on bookworm, 1.19.8 on
trixie) is too old for even pillow-heif 1.4.0. Building libheif takes ~10-15
minutes on a Core Duo, so this cache makes later machines take seconds.

Built by pillow-heif's own `libheif/build_libs.py` in 32-bit LIGHT mode, which
means `-DWITH_X265=OFF` — no HEVC **encoder**, so it decodes `.heic` but cannot
write it. hermes only decodes, so that is sufficient.

| Property | Value |
|---|---|
| libheif | 1.23.0 |
| Arch | i386 |
| Encoder | none (x265 off) |
| Decoder | libde265 (HEVC) |
| Contains | `lib/libheif.so*`, `include/libheif/*.h`, `lib/pkgconfig/libheif.pc` |
| Size | ~1.1 MB |

Consumed automatically by `scripts/install-pillow-heif-i386.sh`; pass
`--no-cache` to force a source build instead.

```sh
# what the installer does with it
tar xzf libheif-1.23.0-i386.tar.gz -C /tmp/x
sudo cp -a /tmp/x/libheif-1.23.0-i386/lib/.     /usr/local/lib/
sudo cp -a /tmp/x/libheif-1.23.0-i386/include/. /usr/local/include/
sudo ldconfig
```

Note the installer then links pillow-heif with
`LDFLAGS=-Wl,-rpath,/usr/local/lib`. That is not optional — see
`docs/FINDINGS.md` §7(d).
