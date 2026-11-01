# hermes-i386

Provisioning kit for running **hermes-agent** on **i386 (32-bit x86) Linux**.

Developed and verified on a Lenovo ThinkPad X60s (Intel Core Duo L2500, 3.2 GB RAM)
with **Debian 12 "bookworm" i386** (glibc) and **Alpine Linux i386** (musl).
The scripts auto-detect the distro and adapt package-manager hints accordingly.

> **Alpine note:** the prebuilt Node 22.22 in `dist/` is glibc-linked and will
> **not** run on musl. On Alpine use the system `nodejs` package (Node 24,
> musl-linked) or build a musl Node from source. The scripts detect this and
> warn.

---

## Why this exists

The hermes-agent TUI declares `engines.node: "^22.22.0 || ^24.11.0 || >=26.0.0"`,
and with `.npmrc` setting `engine-strict=true` that is a **hard** gate on
`npm install`. There is no 32-bit Node at that version anywhere:

| Source | i386 status |
|---|---|
| nodejs.org | No `linux-x86` builds — 404 for every release |
| unofficial-builds.nodejs.org | No `linux-x86` either |
| Debian bookworm | Node **18.20.4** only |
| Debian trixie | Node **20.19.2** only (also needs GLIBC 2.38) |
| Debian forky / sid | Node 24 exists for i386, but requires **GLIBC 2.43** |

That last row is the trap: Debian *does* publish an i386 Node 24, but it is
dynamically linked against glibc 2.43 — newer than any released Debian
(bookworm 2.36, trixie 2.41). It cannot be loaded, and no flag works around it.

**So this kit ships a purpose-built Node 22.22.0 for i386.**

---

## Contents

```
Makefile   make all / node / provision / verify / build-node / checksum ...
dist/      prebuilt Node 22.22.0 for i386 (node + npm + npx + corepack)
scripts/   provision-all.sh, install-node-i386.sh, provision-hermes-i386.sh,
           verify-i386.sh, build-node-i386.sh
patches/   the one source patch hermes needs on 32-bit
docs/      the constraints we hit and why the workarounds exist
```

| Target | Does |
|---|---|
| `make all` | `node` + `provision` + `verify` |
| `make node` | install the prebuilt Node for i386 |
| `make provision` | venv, deps, heap patch, npm, launcher, config |
| `make verify` | check the installation (non-zero exit on failure) |
| `make build-node` | rebuild Node from source (needs root, ~63 min on 8 cores) |
| `make checksum` | verify the dist artifact against `SHA256SUMS` |
| `make test-install` | self-test: install Node into a throwaway prefix |
| `make pull` | update this checkout from origin |
| `make clean` | remove the installed Node prefix |

| Script | Does |
|---|---|
| `scripts/provision-all.sh` | the one-shot: Node + hermes + verify (what `make all` calls) |
| `scripts/install-node-i386.sh` | install the prebuilt Node, link `/usr/local/bin`, capability-check |
| `scripts/provision-hermes-i386.sh` | hermes itself: venv, deps, patch, npm, launcher, config |
| `scripts/verify-i386.sh` | standalone verification, usable as a CI/preflight gate |
| `scripts/build-node-i386.sh` | rebuild Node from source in a bookworm i386 chroot |
| `scripts/setup-git-access.sh` | pin the git host key + create/authorize a client key |
| `scripts/install-pillow-heif-i386.sh` | build libheif + pillow-heif for HEIC decoding |

---

## Quick start on a new i386 machine

```sh
git clone https://github.com/Va55/hermes-i386.git
cd hermes-i386

make all          # install Node + provision hermes + verify
```

`git clone https://github.com/Va55/hermes-i386.git` needs no setup (public repo).

Prefer SSH? Add your public key under GitHub → **Settings → SSH and GPG keys**,
then `git clone git@github.com:Va55/hermes-i386.git`.

(`scripts/setup-git-access.sh` still exists for hosting a self-contained mirror
on your own git server — it pins the server's host key and sets up client-key
access. Not required for the public GitHub copy.)

Or without `make`:

```sh
bash scripts/provision-all.sh          # same thing, one shot
```

Both are idempotent — re-run them freely.

### Individual steps

```sh
make node         # just install the prebuilt Node for i386
make provision    # just set up hermes-agent
make verify       # just check the resulting installation
```

`make verify` also works standalone against an existing install:

```sh
bash scripts/verify-i386.sh [HERMES_SRC] [NODE_PREFIX]
```

It exits non-zero on hard failures, so it is safe to use as a gate.

### Running it remotely

```sh
scp -r . target:~/hermes-i386
ssh target 'cd hermes-i386 && make all'
```

If you need to rebuild Node from source (different version, different libc
target, or you do not trust the prebuilt binary), see
`scripts/build-node-i386.sh` and `docs/BUILD-NOTES.md`.

---

## What the target machine ends up with

- `~/node22/` — Node 22.22.0, ia32, statically self-contained
- `/usr/local/bin/{node,npm,npx,corepack}` → `~/node22/bin/*`
  (apt's `node`/`npm` are left untouched at `/usr/bin`)
- `~/hermes-agent/` — hermes-agent checkout with a venv at `venv/`
- `~/hermes-tui` — launcher that pins `HERMES_NODE` and the 32-bit heap clamp
- `~/.hermes/` — config directory

---

## The three things that are non-obvious

1. **Node 22, not 24.** Both satisfy `engines.node`. On npm, `engines.npm` is
   `"<11.10.0 || >=11.17.0"`, which allows every npm **below 11.10.0 or ≥ 11.17.0**;
   the *excluded* band is only `11.10.0 … 11.16.x`. Node 22 ships npm 10.9.4 and
   Node 24 ships npm 11.6.1 — both are `< 11.10.0`, so **both satisfy** the
   constraint (the trap only bites a Node whose bundled npm lands in 11.10–11.16).
   Node 22 is the shipped choice because this kit carries a tested, self-contained
   ia32 build of it — not because Node 24's npm is disallowed.

2. **The heap clamp patch is mandatory and permanent.** V8 on ia32 cannot
   reserve a multi-GB heap in a 4 GB address space. hermes asks for 8192 MB by
   default, so Node aborts within ~150 ms with *"Reached heap limit"* at only
   0.4 MB used. No Node version fixes this — it is an address-space fact.

3. **`pillow-heif` needs a source-built libheif.** It is a *core* dependency,
   and there are no i686 wheels for any version in hermes' pinned range
   (`>=1.4.0,<2` — PyPI's last i686 wheel is 0.12.0). Worse, Debian ships
   libheif 1.15.1 (bookworm) / 1.19.8 (trixie), both too old: even pillow-heif
   1.4.0 calls `heif_context_set_security_limits`. So libheif 1.23.0 is built
   from source in 32-bit **LIGHT mode** (no x265, no nasm, decode-only) and the
   extension is linked with an **rpath** — without it the loader silently picks
   the *system* libheif and import fails with `undefined symbol:
   heif_camera_extrinsic_matrix_release`. `scripts/install-pillow-heif-i386.sh`
   automates the whole thing and `dist/` caches the libheif build.
   Full write-up: `docs/FINDINGS.md` §7.

---

## Verified end state

```
node -v          v22.22.0   (ia32 / linux / v8 12.4.254.21-node.33)
npm -v           10.9.4
hermes           Hermes Agent v0.21.3
TUI banner       19 tools · 54 skills
```

See `docs/FINDINGS.md` for the full constraint list and `docs/BUILD-NOTES.md`
for build timings and the two source fixes required.

---

## Related projects (same author, same 32-bit + musl stack)

- **hermes-i386 needs a browser for automation?** Your i386 agent has no headless
  browser out of the box — **no glibc** required and a **32-bit port** included:
  [Va55/lightpanda-static](https://github.com/Va55/lightpanda-static) — fully static,
  pure-musl Lightpanda builds (x86_64 & i386) that run on the same Debian/Alpine i386
  boxes this kit provisions. Its i386 V8 port pairs with this kit's i386 Node/V8.
