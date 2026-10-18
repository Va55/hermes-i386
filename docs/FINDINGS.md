# i386 constraints — what we hit and why

Everything below was reproduced on real hardware, not inferred. The target was a
ThinkPad X60s (Core Duo L2500, 3.2 GB RAM, Debian 12 bookworm i386, glibc 2.36).

---

## 1. There is no usable 32-bit Node at the required version

hermes' root `package.json`:

```json
"engines": { "node": "^22.22.0 || ^24.11.0 || >=26.0.0",
             "npm":  "<11.10.0 || >=11.17.0" }
```

and `.npmrc` contains `engine-strict=true`, so these are enforced, not advisory.

| Source | Result |
|---|---|
| nodejs.org `/dist/v*` | **404** for `node-v*-linux-x86.tar.gz` on every release checked (v10, v12, v18, v20, v22) |
| unofficial-builds.nodejs.org | **404** for `linux-x86` — the usual 32-bit lifeline does not exist |
| Debian bookworm i386 | `nodejs 18.20.4` — below the floor |
| Debian trixie i386 | `nodejs 20.19.2` — below the floor *and* needs GLIBC 2.38 |
| Debian forky/sid i386 | `nodejs 24.x` exists — **but see §2** |

## 2. The Debian Node 24 i386 trap

Debian *does* publish an i386 Node 24 (`libnode137`). It looks like the easy fix.
It is not.

```
$ objdump -T libnode.so.137 | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1
GLIBC_2.43

$ ldd --version                     # on trixie
ldd (Debian GLIBC 2.41-12+deb13u4) 2.41

$ LD_LIBRARY_PATH=... ./node --version
node: /lib/i386-linux-gnu/libm.so.6: version `GLIBC_2.43' not found
      (required by libnode.so.137)
```

Verified for **both** the sid build (24.21.0) and the forky build (24.20.0):
both demand GLIBC_2.43.

Compare the targets:

| Release | glibc |
|---|---|
| bookworm (Debian 12) | **2.36** |
| trixie (Debian 13) | 2.41 |
| sid (needed by Debian's Node 24) | 2.43 |

This is ELF symbol versioning in the dynamic linker — there is no flag, env var,
or forward-compatibility shim. The only workaround is bundling a newer glibc
alongside the binary and invoking it through an explicit loader path, which is
fragile enough that we did not do it.

**Conclusion: building from source is the only route to Node >= 22 on i386.**

## 3. Why Node 22 and not 24

Both satisfy `engines.node`, and **both also satisfy `engines.npm`**. The range
`"<11.10.0 || >=11.17.0"` allows everything below 11.10.0 or at/above 11.17.0, so the
*excluded* band is only `11.10.0 … 11.16.x`:

| | engine floor met | bundled npm | `engines.npm` (`<11.10.0 \|\| >=11.17.0`) |
|---|---|---|---|
| Node 22.22.0 | yes (`^22.22.0`) | **10.9.4** | **satisfied** (< 11.10.0) |
| Node 24.x | yes (`^24.11.0`) | 11.6.1 | **satisfied** (< 11.10.0); the trap only bites npm 11.10–11.16 |

Correction: an earlier draft of this note called Node 24's npm 11.6.1 "excluded" — it
is actually below 11.10.0, so it qualifies. Node 22 is shipped because this kit carries
a tested, self-contained ia32 build of it, and it is lighter, which matters on a 3.2 GB
machine — not because Node 24's npm is disallowed.

## 4. The two source-level build fixes

Neither is optional; both were hit as hard failures.

### a) OpenSSL assembly ships unexpanded perlasm

```
deps/openssl/config/archs/linux-elf/asm/crypto/aes/aes-586.S:5: Error:
junk at end of line, first unrecognized character is `%'
```

71 such errors. The shipped `.S` files still contain perlasm directives:

```
    %ifdef __CET__
    .byte   243,15,30,251
    %endif
```

`perl` is present but the Node build never invokes it — it consumes the
pre-generated asm as-is. GNU `as` cannot parse `%ifdef`.

**Fix:** configure with `--openssl-no-asm`. (Costs some crypto throughput;
irrelevant for this workload.)

### b) zlib SIMD intrinsics require SSE2, which i386 does not enable by default

```
deps/zlib/slide_hash_simd.h:29:  error: inlining failed in call to
'always_inline' '_mm_set1_epi16': target specific option mismatch
```

`slide_hash_simd.h` uses SSE2 intrinsics unconditionally on x86, but GCC for
i386 does not enable SSE2 (unlike x86_64, where it is baseline).

**Fix:** `export CFLAGS="-msse2" CXXFLAGS="-msse2"` before `./configure`.
Safe for any CPU from this century — the X60s Core Duo reports
`mmx sse sse2 pni`.

## 5. The 32-bit V8 heap cap — permanent, unfixable by version

`hermes_cli/main_tui_launch.py` computes a V8 heap size and injects it:

```python
def _resolve_tui_heap_mb(default_mb: int = 8192) -> int:
    ...
    if not limit:
        return default_mb          # -> 8192 when no cgroup limit is set
```

On ia32 that is unallocatable — V8 cannot reserve an 8 GB heap in a 4 GB address
space. The failure is immediate and confusing:

```
<--- Last few GCs --->
[14852]  152 ms: Mark-sweep (reduce) 0.4 (2.7) -> 0.4 (1.7) MB ...
FATAL ERROR: CALL_AND_RETRY_LAST Allocation failed - JavaScript heap out of memory
```

Note it dies at **0.4 MB used** — that is the signature of a reservation failure,
not a real out-of-memory.

### The default ceiling is a function of installed RAM, not the Node version

Worth stating because it is easy to misread: V8 derives its default heap ceiling
from **installed physical memory**, so the same Node build reports different
values on different machines.

| Host | Node | default `heap_size_limit` |
|---|---|---|
| X60s (3.2 GB RAM) | 20.20.2 | 841 MB |
| X60s (3.2 GB RAM) | 22.22.0 | 841 MB |
| a larger host (>8 GB) | 22.22.0 | 1048 MB |

So do not treat any particular number as "the" Node 22 default — only the *asked
for* value matters. hermes requests **8192 MB**, and `--max-old-space-size=8192`
aborts on **every** i386 host regardless of how much RAM is fitted, because the
limit is address-space, not memory.

For reference, on the X60s:

```
$ node -e 'console.log(require("v8").getHeapStatistics().heap_size_limit/1048576)'
841.0                                   # default, RAM-derived

$ NODE_OPTIONS=--max-old-space-size=700 node -e '...'
724.0                                   # clamped -> works

$ NODE_OPTIONS=--max-old-space-size=8192 node -e '...'
<--- Last few GCs --->
FATAL ERROR: ... JavaScript heap out of memory      # aborts
```

**Fix:** clamp the default on 32-bit interpreters. See
`patches/0001-32bit-heap-clamp.patch`. The patch keys off `sys.maxsize < 2 ** 32`
— i.e. *interpreter bitness*, never a RAM figure — which is why one constant
(700 MB) is correct across every i386 host.

## 6. The `v` regex flag (why Node 18 could not run the TUI at all)

`string-width` (pulled in by `ink` -> `widest-line` -> `measure-text`) uses
RegExp Unicode-sets:

```js
new RegExp("^\\p{RGI_Emoji}$", "v")
new RegExp("^(?:\\p{Default_Ignorable_Code_Point}|...)+$", "v")
```

The `v` flag requires V8 11.0+ (**Node 20**). On Node 18 the bundle dies at
startup with `SyntaxError: Invalid flags supplied to RegExp constructor 'v'`.

This is the practical reason a Node 20+ runtime is mandatory — independent of
the `engines` string. Node 22 handles it natively, so **no bundle patch is
needed**.

## 7. `pillow-heif` — solved, via a source-built libheif

`pillow-heif` is a **core** dependency (`pillow-heif>=1.4.0,<2`). Getting it
running on i386 takes three separate fixes, each failing differently. It is now
working: hermes decodes HEIC and converts it to PNG.

### a) There are no i686 wheels

| pillow-heif | i686 wheel? |
|---|---|
| <= 0.12.0 | yes |
| >= 1.3.0 | **no** — sdist only |

Every version in hermes' pinned range is sdist-only, so it must compile.

### b) The libheif floor is above every Debian release

- `pillow-heif >= 1.5` requires **libheif >= 1.23.1**
- even `1.4.0` calls `heif_context_set_security_limits`, which does not exist
  before roughly 1.17

| Release | libheif | verdict |
|---|---|---|
| bookworm (12) | 1.15.1 | too old |
| trixie (13) | 1.19.8 | too old |

So libheif 1.23.0 must be built from source too.

### c) pillow-heif ships a 32-bit LIGHT mode — and it is exactly right here

`libheif/build_libs.py` (in the sdist) contains:

```python
PH_LIGHT_VERSION = sys.maxsize <= 2**32 or getenv("PH_LIGHT_ACTION", "0") != "0"
```

On any 32-bit Python that is **True**, so it skips x265 entirely — meaning
**nasm is not required** — and configures libheif with `-DWITH_X265=OFF`:
decode-only, no HEVC encoder. That is sufficient because hermes only ever
*decodes* HEIC and re-encodes to PNG through Pillow
(`tools/vision_tools_image_prep.py` → `_normalize_to_supported_image`).

Note that `setup.py` **never calls `build_libs()`** — it is a standalone helper
you must run yourself. It reuses the system libde265 when present and only
builds libheif.

### d) The runtime trap that makes a clean build fail anyway

Even after building successfully against libheif 1.23.0, the extension dies at
import:

```
ImportError: _pillow_heif.cpython-311-i386-linux-gnu.so:
  undefined symbol: heif_camera_extrinsic_matrix_release
```

That symbol exists in 1.23.0 but not 1.15.1, and `ldd` shows the loader picked
the wrong library:

```
libheif.so.1 => /lib/i386-linux-gnu/libheif.so.1     <-- 1.15.1, not ours
```

The cause is loader-cache ordering. `/etc/ld.so.conf.d/i386-linux-gnu.conf` is
included **before** `libc.conf`, and for a duplicate soname the first directory
wins:

```
i386-linux-gnu.conf:  /usr/local/lib/i386-linux-gnu, /lib/i386-linux-gnu, ...
libc.conf:            /usr/local/lib            <-- included later, so it loses
```

Installing into `/usr/local/lib` is therefore not sufficient. The fix is to bake
an rpath into the extension so it never depends on cache ordering:

```sh
export LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"
export LD_RUN_PATH="/usr/local/lib"
pip install --force-reinstall --no-deps pillow-heif==1.4.0
```

(Both are set deliberately; the export matters — plain shell assignment is not
inherited by pip, which silently drops the rpath and reintroduces the bug.)

Confirmed afterwards:

```
RUNPATH  Library runpath: [/usr/local/lib]
libheif.so.1 => /usr/local/lib/libheif.so.1
pillow_heif 1.4.0 / libheif 1.23.0
```

### e) Proof it works

A real 718 KB HEIC through hermes' own normaliser:

```
input : /tmp/sample.heic 718114 bytes (HEIC)
result: ~/.hermes/cache/vision/converted_....png  mime=image/png  err=None
output: 1934579 bytes, PNG magic 89504e470d0a1a0a
decodes as: PNG RGB (1280, 854)
```

### Caveat: decode-only

LIGHT mode builds libheif with `-DWITH_X265=OFF`, so there is **no HEVC
encoder**: hermes can read `.heic` but cannot write one. It never writes HEIF,
so this does not limit anything in practice.

### Related trap: distribution name != import name

Worth knowing when writing any health check for this stack:

| Distribution (`pyproject.toml`) | Import name | Notes |
|---|---|---|
| `pillow-heif` | `pillow_heif` | underscores |
| `firecrawl-anydoc` | **`anydoc`** | completely different — the dist name is a vendor prefix |
| `PyJWT` | `jwt` | |

`firecrawl-anydoc` caught us out: `import firecrawl_anydoc` raises
`ModuleNotFoundError` even though the package is installed and working. hermes
documents this itself in `tools/lazy_deps.py`:

```python
"tool.doc_extract": ("firecrawl-anydoc==0.2.4",),  # imports as `anydoc`
```

Any verification script must import `anydoc`, not `firecrawl_anydoc`.

### Automation

`scripts/install-pillow-heif-i386.sh` performs all of the above and
`provision-hermes-i386.sh` calls it. A prebuilt libheif 1.23.0 is cached at
`dist/libheif-1.23.0-i386.tar.gz` (~1 MB) so later machines skip the
~10-15 minute source build.

## 8. Cosmetic: the TUI shows `0 tools · 0 skills` briefly

Not a fault. The banner is painted **before** the tool registry finishes its
capability probes, and it renders the (still empty) structure honestly. On the
Core Duo those probes take ~20-25 s:

```
check_browser_back_requirements    -> False   (~1.5 s each)
_browser_cdp_check                 -> False
check_browser_click_requirements   -> False
... 11 more browser / computer_use / image_gen / tts checks ...
```

It resolves on its own to `19 tools · 54 skills` and stays there. Just wait.

## 9. What still does not work on i386

- **Browser toolset** — needs Chromium; not practical on this class of machine.
  Silence the startup warning with `browser.backend: off`.
- **computer_use / image generation** — the `check_fn` probes return False.
- **Large heaps** — the 700 MB clamp is a hard ceiling. Fine for normal use;
  long sessions or large pasted files may hit it.
