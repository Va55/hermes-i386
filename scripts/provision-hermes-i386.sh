#!/bin/bash
# provision-hermes-i386.sh — set up hermes-agent on an i386 Linux host (Debian/Alpine).
#
# Assumes Node 22 is already installed (see install-node-i386.sh). Idempotent:
# safe to re-run.
#
# Environment overrides:
#   HERMES_SRC    existing hermes-agent checkout to use (default: $HOME/hermes-agent)
#   HERMES_REPO   git URL to clone when no checkout exists
#   HERMES_REF    branch/tag to check out when cloning
#   HERMES_HOME   config directory (default: $HOME/.hermes)
#
set -uo pipefail

# --- distro detection --------------------------------------------------------
DISTRO="unknown"; LIBC="glibc"
[ -f /etc/os-release ] && . /etc/os-release
case "${ID:-}" in alpine) DISTRO="alpine" ;; esac
ldd --version 2>&1 | grep -qi musl && LIBC="musl"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${HERMES_SRC:-$HOME/hermes-agent}"
REPO="${HERMES_REPO:-https://github.com/NousResearch/hermes-agent.git}"
REF="${HERMES_REF:-}"
HHOME="${HERMES_HOME:-$HOME/.hermes}"
VENV="$TARGET/venv"

say()  { printf '\n=== %s ===\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
ok()   { printf '  + %s\n' "$*"; }

# --- 0. preconditions -------------------------------------------------------
say "preconditions"

fail=0
for c in python3 git node npm; do
    if command -v "$c" >/dev/null 2>&1; then
        ok "$c: $(command -v "$c")"
    else
        warn "$c: MISSING"; fail=1
    fi
done
[ "$fail" -eq 0 ] || {
    echo
    case "$DISTRO" in
        alpine)
            echo "Install the missing tools first (Alpine, musl):"
            echo "  sudo apk add --no-cache python3 python3-dev build-base \\"
            echo "       openssl-dev libffi-dev libxslt-dev zlib-dev \\"
            echo "       libjpeg-turbo-dev libtiff-dev freetype-dev \\"
            echo "       cmake pkgconfig git curl ca-certificates libde265"
            ;;
        *)
            echo "Install the missing tools first (Debian):"
            echo "  sudo apt-get install -y build-essential python3 python3-venv python3-dev \\"
            echo "       libssl-dev libffi-dev pkg-config git curl ca-certificates \\"
            echo "       zlib1g-dev libjpeg62-turbo-dev libtiff-dev libfreetype6-dev"
            ;;
    esac
    exit 1
}

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
NODE_MINOR="$(node -p 'process.versions.node.split(".")[1]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -lt 20 ]; then
    warn "node $(node --version) is too old — the TUI needs >= 20 (22 recommended)."
    warn "Run install-node-i386.sh first."
    exit 1
fi
ok "node $(node --version)  (need >= 20 for the 'v' regex flag)"
# musl box + glibc Node = problem
if [ "$LIBC" = "musl" ]; then
    NODE_LD="$(file "$(command -v node)" 2>/dev/null)"
    if printf '%s' "$NODE_LD" | grep -q "ld-linux"; then
        warn "WARNING: node is glibc-linked on a musl system — it should not work."
        warn "Install a musl-linked node (apk add nodejs) or a musl build."
    fi
fi
[ "$NODE_MAJOR" -ge 22 ] && ok "engines.node ^22.22.0 satisfied" \
                         || warn "engines.node ^22.22.0 NOT satisfied (npm install may fail)"

# python3-venv present?
if ! python3 -c 'import venv' 2>/dev/null; then
    case "$DISTRO" in
        alpine) warn "python3-venv is missing: sudo apk add --no-cache python3" ;;
        *)      warn "python3-venv is missing: sudo apt-get install -y python3-venv" ;;
    esac
    exit 1
fi

# --- 1. source --------------------------------------------------------------
say "source"
if [ -d "$TARGET/.git" ] || [ -f "$TARGET/pyproject.toml" ]; then
    ok "using existing checkout: $TARGET"
elif [ -n "$REF" ]; then
    ok "cloning $REPO @ $REF"
    git clone --branch "$REF" "$REPO" "$TARGET"
else
    ok "cloning $REPO"
    git clone "$REPO" "$TARGET"
fi

[ -f "$TARGET/pyproject.toml" ] || { warn "no pyproject.toml in $TARGET"; exit 1; }

# --- 2. venv ----------------------------------------------------------------
say "venv"
if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
    ok "created $VENV"
else
    ok "reusing $VENV"
fi
"$VENV/bin/pip" install -q --upgrade pip setuptools wheel
ok "pip $("$VENV/bin/pip" --version | awk '{print $2}')"

# --- 3. core dependencies ---------------------------------------------------
# Note: pillow-heif is deliberately excluded here and handled separately below.
say "core dependencies"
cat > /tmp/hermes-i386-core.txt <<'REQS'
openai==2.24.0
certifi==2026.5.20
python-dotenv==1.2.2
fire==0.7.1
httpx[socks]==0.28.1
rich==14.3.3
tenacity==9.1.4
pyyaml==6.0.3
ruamel.yaml==0.18.17
requests==2.33.0
jinja2==3.1.6
firecrawl-anydoc==0.2.4
pydantic==2.13.4
prompt_toolkit==3.0.52
croniter==6.0.0
snowballstemmer==3.1.1
packaging==26.0
Markdown==3.10.2
PyJWT[crypto]==2.13.0
urllib3>=2.7.0,<3
cryptography==50.0.0
psutil==7.2.2
websockets==15.0.1
pathspec==1.1.1
fastapi>=0.104.0,<1
uvicorn[standard]>=0.31.0,<1
python-multipart>=0.0.9,<1
ptyprocess>=0.7.0,<1
Pillow==12.3.0
REQS

if "$VENV/bin/pip" install -r /tmp/hermes-i386-core.txt > /tmp/hermes-i386-core.log 2>&1; then
    ok "core deps installed"
else
    warn "core deps FAILED — see /tmp/hermes-i386-core.log"
    tail -15 /tmp/hermes-i386-core.log | sed 's/^/    /'
    exit 1
fi
# cryptography compiles from Rust source here — this is the long pole (minutes).
ok "note: pyyaml, psutil, Pillow and cryptography are all built from source on i386"

# --- 4. pillow-heif (HEIC decoding) -----------------------------------------
say "pillow-heif (HEIC decoding)"
if "$VENV/bin/python" -c 'import pillow_heif' >/dev/null 2>&1; then
    ok "already importable: $("$VENV/bin/python" -c 'import pillow_heif; print(pillow_heif.__version__)' 2>/dev/null)"
else
    # Not a plain `pip install`: no i686 wheels exist, and the libheif that
    # Debian ships (bookworm 1.15.1) is too old even for pillow-heif 1.4.0.
    # libheif must be built from source. See install-pillow-heif-i386.sh.
    # Takes ~10-15 min on a Core Duo, or seconds from the dist/ cache.
    if [ -x "$HERE/install-pillow-heif-i386.sh" ]; then
        say "building HEIC support (libheif from source — this is the slow step)"
        if bash "$HERE/install-pillow-heif-i386.sh" "$VENV"; then
            ok "pillow-heif installed"
        else
            warn "pillow-heif install failed"
            warn "hermes still runs; HEIC images just cannot be decoded"
        fi
    else
        warn "install-pillow-heif-i386.sh not found — skipping HEIC support"
    fi
fi

# --- 5. hermes itself -------------------------------------------------------
say "hermes-agent"
"$VENV/bin/pip" install -e "$TARGET" --no-deps > /tmp/hermes-i386-hermes.log 2>&1 \
    && ok "installed (editable, --no-deps)" \
    || { warn "install failed"; tail -15 /tmp/hermes-i386-hermes.log | sed 's/^/    /'; exit 1; }

# --- 6. the 32-bit heap clamp patch -----------------------------------------
say "32-bit heap clamp"
PATCH="$HERE/../patches/0001-32bit-heap-clamp.patch"
LAUNCH="$TARGET/hermes_cli/main_tui_launch.py"
if [ ! -f "$LAUNCH" ]; then
    warn "main_tui_launch.py not found — skipping patch"
elif grep -q 'sys\.maxsize < 2 \*\* 32' "$LAUNCH"; then
    ok "already applied"
elif [ -f "$PATCH" ]; then
    if patch -p1 -d "$TARGET" --forward < "$PATCH" > /tmp/hermes-i386-patch.log 2>&1; then
        ok "applied $PATCH"
    else
        warn "patch failed — see /tmp/hermes-i386-patch.log"
        warn "V8 will abort with 'Reached heap limit' without it"
        cat /tmp/hermes-i386-patch.log | sed 's/^/    /'
    fi
else
    warn "patch file not found at $PATCH"
fi

# --- 7. TUI node_modules ----------------------------------------------------
say "TUI dependencies (npm)"
if [ -f "$TARGET/ui-tui/dist/entry.js" ] && [ ! -f "$TARGET/package-lock.json" ]; then
    ok "prebuilt bundle present, no lockfile — npm install not required"
else
    if ( cd "$TARGET" && npm install --workspace ui-tui > /tmp/hermes-i386-npm.log 2>&1 ); then
        ok "npm install --workspace ui-tui"
    else
        warn "npm install failed — see /tmp/hermes-i386-npm.log"
        warn "if this is EBADENGINE, node is below the engines floor (need 22.22+)"
        grep -iE "EBADENGINE|notsup|Required|Actual" /tmp/hermes-i386-npm.log | head -5 | sed 's/^/    /'
    fi
fi
[ -d "$TARGET/node_modules/@esbuild/linux-ia32" ] \
    && ok "@esbuild/linux-ia32 present (can rebuild the TUI from source)" \
    || warn "@esbuild/linux-ia32 missing — 'npm run build' may fail"

# --- 8. launcher ------------------------------------------------------------
say "launcher"
cat > "$HOME/hermes-tui" <<'LAUNCH'
#!/bin/bash
# Launch the hermes-agent TUI on i386.
# Node >= 20 is required (the TUI's string-width uses the 'v' regex flag);
# Node 22.22+ is needed for the engines floor. Debian ships only Node 18 for
# i386, so node22 is built for this platform by the hermes-i386 kit.
NODE_BIN="${HERMES_NODE:-$HOME/node22/bin/node}"
[ -x "$NODE_BIN" ] || NODE_BIN="$(command -v node)"
export HERMES_NODE="$NODE_BIN"
# 32-bit V8 cannot reserve a multi-GB heap in a 4GB address space.
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=700}"
exec "$HOME/hermes-agent/venv/bin/hermes" --tui "$@"
LAUNCH
chmod +x "$HOME/hermes-tui"
ok "wrote $HOME/hermes-tui"

# put it on PATH
if sudo -n true 2>/dev/null; then
    sudo -n ln -sf "$VENV/bin/hermes" /usr/local/bin/hermes
    ok "linked /usr/local/bin/hermes -> $VENV/bin/hermes"
else
    warn "no passwordless sudo; add $VENV/bin to PATH or use ~/hermes-tui"
fi

# --- 9. config stub ---------------------------------------------------------
say "config"
mkdir -p "$HHOME"
if [ ! -f "$HHOME/config.yaml" ]; then
    cat > "$HHOME/config.yaml" <<'CFG'
model:
  default: deepseek-chat
  provider: deepseek
  base_url: https://api.deepseek.com/v1

# Tool packages to load. These are the ids from hermes_cli/tools_config
# (CONFIGURABLE_TOOLSETS). A typo silently yields zero tools.
toolsets:
  - terminal
  - file
  - web
  - skills
  - memory
  - todo
  - vision
  - tts
  - clarify
CFG
    ok "wrote $HHOME/config.yaml (edit the model/provider)"
else
    ok "kept existing $HHOME/config.yaml"
fi
[ -f "$HHOME/.env" ] || { : > "$HHOME/.env"; chmod 600 "$HHOME/.env"; ok "created $HHOME/.env (add your API key)"; }

# --- 10. verify -------------------------------------------------------------
say "verification"
"$VENV/bin/python" - <<'PY'
mods = ["hermes_cli","hermes_state","tui_gateway","openai","cryptography",
        "yaml","psutil","PIL","pydantic","anydoc"]
ok = bad = 0
for m in mods:
    try:
        __import__(m); print(f"  + {m}"); ok += 1
    except Exception as e:
        print(f"  ! {m}: {type(e).__name__}: {str(e)[:50]}"); bad += 1
print(f"  --- {ok} ok / {bad} failed")
PY
printf '  + hermes: %s\n' "$("$VENV/bin/hermes" --version 2>&1 | head -1)"

say "done"
cat <<EOF
  Launch with:   hermes --tui        (or ~/hermes-tui)
  Expect ~25 s to first prompt on a slow CPU — the tool-registry capability
  probes run serially. The banner shows '0 tools · 0 skills' until they finish,
  then updates to the real counts.
EOF
