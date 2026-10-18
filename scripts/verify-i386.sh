#!/bin/bash
# verify-i386.sh — check a hermes-agent installation on 32-bit x86.
#
#   bash scripts/verify-i386.sh [HERMES_SRC] [NODE_PREFIX]
#
# Exits non-zero if any hard check fails. Warnings do not fail.
#
set -uo pipefail

DISTRO="unknown"; LIBC="glibc"
[ -f /etc/os-release ] && . /etc/os-release
case "${ID:-}" in alpine) DISTRO="alpine" ;; esac
ldd --version 2>&1 | grep -qi musl && LIBC="musl"

SRC="${1:-${HERMES_SRC:-$HOME/hermes-agent}}"
PREFIX="${2:-${PREFIX:-$HOME/node22}}"

pass=0; fail=0; warnn=0
ok()   { printf '  [ok] %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  [!!] %s\n' "$*"; fail=$((fail+1)); }
warn() { printf '  [--] %s\n' "$*"; warnn=$((warnn+1)); }
sec()  { printf '\n=== %s ===\n' "$*"; }

echo "hermes-i386 verification"
echo "  src:    $SRC"
echo "  prefix: $PREFIX"

# --- node -------------------------------------------------------------------
sec "node"
NODE_BIN="$PREFIX/bin/node"
if [ -x "$NODE_BIN" ]; then
    ok "node binary: $NODE_BIN"
elif command -v node >/dev/null 2>&1; then
    NODE_BIN="$(command -v node)"
    warn "using PATH node: $NODE_BIN (prefix node not found)"
    if [ "$LIBC" = "musl" ]; then
        if file "$NODE_BIN" 2>/dev/null | grep -q "ld-linux"; then
            bad "node is glibc-linked on musl system — will NOT run"
        else
            ok "node is musl-compatible"
        fi
    fi
else
    bad "no node binary (looked in $PREFIX/bin and PATH)"
    NODE_BIN=""
fi

if [ -n "$NODE_BIN" ]; then
    NV="$("$NODE_BIN" --version 2>/dev/null)"
    NA="$("$NODE_BIN" -p 'process.arch' 2>/dev/null)"
    [ -n "$NV" ] && ok "version: $NV" || bad "node does not run"
    [ "$NA" = "ia32" ] && ok "arch: ia32" || warn "arch: $NA (expected ia32)"

    major="${NV#v}"; major="${major%%.*}"
    minor="$(echo "$NV" | cut -d. -f2)"
    if [ "${major:-0}" -gt 22 ] || { [ "${major:-0}" -eq 22 ] && [ "${minor:-0}" -ge 22 ]; }; then
        ok "engines.node ^22.22.0: SATISFIED"
    elif [ "${major:-0}" -ge 20 ]; then
        warn "engines.node ^22.22.0: not met ($NV) — TUI runs, npm install may fail"
    else
        bad "node $NV is below 20 — the TUI cannot run (needs the 'v' regex flag)"
    fi

    if "$NODE_BIN" -e 'new RegExp("\\p{RGI_Emoji}","v")' >/dev/null 2>&1; then
        ok "v-flag regex: SUPPORTED"
    else
        bad "v-flag regex: unsupported — the TUI bundle will not start"
    fi

    HEAP="$("$NODE_BIN" -e 'console.log((require("v8").getHeapStatistics().heap_size_limit/1048576).toFixed(0))' 2>/dev/null)"
    [ -n "$HEAP" ] && ok "default V8 heap limit: ${HEAP} MB (hermes requests 8192; clamp required)"
fi

# --- npm --------------------------------------------------------------------
sec "npm"
NPM_BIN="$PREFIX/bin/npm"
[ -x "$NPM_BIN" ] || NPM_BIN="$(command -v npm 2>/dev/null || true)"
if [ -n "$NPM_BIN" ] && [ -n "${NODE_BIN:-}" ]; then
    NPMV="$(PATH="$(dirname "$NODE_BIN"):$PATH" "$NPM_BIN" --version 2>/dev/null)"
    if [ -n "$NPMV" ]; then
        ok "npm: $NPMV"
        # engines.npm is "<11.10.0 || >=11.17.0"
        nmaj="${NPMV%%.*}"; nmin="$(echo "$NPMV" | cut -d. -f2)"
        if [ "$nmaj" -lt 11 ] || [ "$nmaj" -ge 12 ] || { [ "$nmaj" -eq 11 ] && { [ "$nmin" -lt 10 ] || [ "$nmin" -ge 17 ]; }; }; then
            ok "engines.npm <11.10.0 || >=11.17.0: SATISFIED"
        else
            warn "engines.npm: $NPMV is in the excluded 11.10-11.16 band"
        fi
    else
        warn "npm present but does not run"
    fi
else
    warn "npm not found"
fi

# --- hermes -----------------------------------------------------------------
sec "hermes-agent"
if [ -f "$SRC/pyproject.toml" ]; then
    ok "checkout: $SRC"
else
    bad "no pyproject.toml at $SRC"
fi

VENV="$SRC/venv"
if [ -x "$VENV/bin/python" ]; then
    ok "venv: $("$VENV/bin/python" --version 2>&1)"
else
    bad "no venv at $VENV"
fi

if [ -x "$VENV/bin/hermes" ]; then
    HV="$("$VENV/bin/hermes" --version 2>&1 | head -1)"
    [ -n "$HV" ] && ok "hermes: $HV" || warn "hermes --version produced no output"
elif [ -x "$VENV/bin/python" ]; then
    HV="$("$VENV/bin/python" -c 'import hermes_cli; print(getattr(hermes_cli,"__version__","?"))' 2>&1 | tail -1)"
    case "$HV" in
        *Error*|*Traceback*) warn "hermes CLI entry point missing ($HV)" ;;
        *) ok "hermes_cli importable (version $HV)" ;;
    esac
else
    warn "cannot check hermes (no venv)"
fi

# --- python deps ------------------------------------------------------------
sec "python dependencies"
if [ -x "$VENV/bin/python" ]; then
    # NOTE: distribution name != import name. "firecrawl-anydoc" provides the
    # top-level module `anydoc`; hermes says so itself in tools/lazy_deps.py.
    if "$VENV/bin/python" - <<'PY'
import sys
mods = ["hermes_cli", "hermes_state", "tui_gateway", "openai", "cryptography",
        "yaml", "psutil", "PIL", "pydantic", "anydoc"]
bad = []
for m in mods:
    try:
        __import__(m)
        print(f"  [ok] {m}")
    except Exception as e:
        print(f"  [!!] {m}: {type(e).__name__}: {str(e)[:60]}")
        bad.append(m)
print(f"  --- {len(mods) - len(bad)}/{len(mods)} importable")
sys.exit(1 if bad else 0)
PY
    then
        ok "all core imports resolve"
    else
        bad "core import(s) failed -- see the [!!] lines above"
    fi
else
    warn "skipped"
fi
# pillow-heif drives HEIC decoding. Absence is not fatal (hermes runs), but
# this stack has a specific failure mode worth catching: a *successful* build
# that loads the WRONG system libheif and dies on an undefined symbol.
if [ -x "$VENV/bin/python" ]; then
    ph="$("$VENV/bin/python" - <<'PY' 2>&1
try:
    import pillow_heif
except ImportError:
    print("ABSENT")
else:
    try:
        pillow_heif.register_heif_opener()
        print(f"OK|{pillow_heif.__version__}|{pillow_heif.libheif_version()}")
    except Exception as e:
        print(f"BROKEN|{type(e).__name__}: {e}")
PY
)"
    case "$ph" in
        OK*)
            ok "pillow-heif $(printf '%s' "$ph" | cut -d'|' -f2) (libheif $(printf '%s' "$ph" | cut -d'|' -f3)) — HEIC decoding works" ;;
        BROKEN*)
            bad "pillow-heif is installed but unusable: ${ph#BROKEN|}"
            warn "  usually the wrong libheif is being loaded; re-run scripts/install-pillow-heif-i386.sh" ;;
        *)
            warn "pillow-heif ABSENT — HEIC images cannot be decoded (hermes runs otherwise)"
            warn "  fix: bash scripts/install-pillow-heif-i386.sh" ;;
    esac
fi

# --- 32-bit heap clamp ------------------------------------------------------
sec "32-bit heap clamp"
LAUNCH="$SRC/hermes_cli/main_tui_launch.py"
if [ -f "$LAUNCH" ]; then
    if grep -q 'sys\.maxsize < 2 \*\* 32' "$LAUNCH"; then
        ok "patch applied in $LAUNCH"
    else
        bad "patch NOT applied — the TUI will abort with 'Reached heap limit'"
    fi
else
    warn "main_tui_launch.py not found (hermes layout changed?)"
fi
if [ -f "$HOME/hermes-tui" ]; then
    ok "launcher: $HOME/hermes-tui"
else
    warn "no launcher at $HOME/hermes-tui (use provision script)"
fi

# --- TUI assets -------------------------------------------------------------
sec "TUI assets"
SRC_BUNDLE="$SRC/ui-tui/dist/entry.js"
PRE_BUNDLE="$SRC/hermes_cli/tui_dist/entry.js"
if [ -f "$SRC_BUNDLE" ]; then
    ok "ui-tui/dist/entry.js ($(stat -c %s "$SRC_BUNDLE" 2>/dev/null || echo '?') bytes)"
elif [ -f "$PRE_BUNDLE" ]; then
    warn "only the prebuilt bundle exists (hermes_cli/tui_dist/entry.js)"
else
    bad "no TUI bundle — run: cd $SRC && npm install --workspace ui-tui"
fi
if [ -d "$SRC/node_modules/@esbuild/linux-ia32" ]; then
    ok "@esbuild/linux-ia32 present (can rebuild from source)"
else
    warn "@esbuild/linux-ia32 missing — 'npm run build' may not work"
fi

# --- config -----------------------------------------------------------------
sec "config"
[ -d "$HOME/.hermes" ] && ok "$HOME/.hermes exists" || warn "$HOME/.hermes missing"
[ -f "$HOME/.hermes/config.yaml" ] && ok "config.yaml present" || warn "no config.yaml"
[ -f "$HOME/.hermes/.env" ] && ok ".env present" || warn "no .env (add your API key)"
if [ -f "$HOME/.hermes/config.yaml" ]; then
    n="$(grep -cE '^\s*-\s' "$HOME/.hermes/config.yaml" 2>/dev/null)"
    [ "${n:-0}" -gt 0 ] && ok "$n toolset entries in config.yaml" \
                        || warn "config.yaml lists no toolsets — a typo yields 0 tools"
fi

# --- summary ----------------------------------------------------------------
printf '\n=== summary ===\n'
printf '  %d passed, %d failed, %d warnings\n' "$pass" "$fail" "$warnn"
if [ "$fail" -gt 0 ]; then
    echo "  RESULT: FAIL"
    exit 1
fi
echo "  RESULT: PASS"
exit 0
