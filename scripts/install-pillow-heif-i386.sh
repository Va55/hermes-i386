#!/bin/bash
# install-pillow-heif-i386.sh — get pillow-heif working on 32-bit Linux (Debian/Alpine).
#
#   bash install-pillow-heif-i386.sh [VENV] [options]
#
# Options:
#   --prefix DIR      libheif install prefix          (default: /usr/local)
#   --libheif VER     libheif version to build        (default: 1.23.0)
#   --pillow-heif VER pillow-heif version             (default: 1.4.0)
#   --no-cache        ignore any prebuilt libheif in dist/
#   --skip-build      assume libheif is already present
#
# ---------------------------------------------------------------------------
# Why this is not just `pip install pillow-heif`
# ---------------------------------------------------------------------------
#
# 1. NO i686 WHEELS. PyPI's last i686 wheel is 0.12.0; every release from 1.3.0
#    onward is sdist-only for 32-bit Linux.
#
# 2. THE libheif FLOOR. pillow-heif >= 1.5 requires libheif >= 1.23.1. Even
#    1.4.0 needs more than Debian ships: it calls
#    heif_context_set_security_limits, which does not exist before ~1.17.
#        bookworm (12) libheif = 1.15.1   -> too old
#        trixie   (13) libheif = 1.19.8   -> too old
#    So libheif must be built from source.
#
# 3. LIGHT MODE exists for exactly this. pillow-heif ships
#    libheif/build_libs.py, and it auto-detects 32-bit Python:
#        PH_LIGHT_VERSION = sys.maxsize <= 2**32
#    In light mode it skips x265 entirely (so **nasm is not needed**) and
#    configures libheif with -DWITH_X265=OFF: decode-only, no HEVC encoder.
#    That is sufficient for hermes, which only *decodes* HEIC and re-encodes to
#    PNG through Pillow — it never writes HEIF.
#
# 4. THE RUNTIME TRAP. Even after a successful build the extension fails with
#        undefined symbol: heif_camera_extrinsic_matrix_release
#    /etc/ld.so.conf.d/i386-linux-gnu.conf (Debian) lists /lib/i386-linux-gnu
#    BEFORE /usr/local/lib. On Alpine the same ordering issue exists in
#    /etc/ld/musl-*.conf. The loader cache therefore prefers
#    the system libheif.so.1 (1.15.1) over the freshly built 1.23.0.
#    The fix is an rpath baked into the extension:
#        LDFLAGS=-Wl,-rpath,<prefix>/lib
#
set -uo pipefail

DISTRO="unknown"; LIBC="glibc"
[ -f /etc/os-release ] && . /etc/os-release
case "${ID:-}" in alpine) DISTRO="alpine" ;; esac
ldd --version 2>&1 | grep -qi musl && LIBC="musl"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only treat $1 as the venv path if it is not an option.
VENV=""
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    VENV="$1"; shift
fi

PREFIX="/usr/local"
LIBHEIF_VER="1.23.0"
PH_VER="1.4.0"
USE_CACHE=1
SKIP_BUILD=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)      PREFIX="${2:?}"; shift 2 ;;
        --libheif)     LIBHEIF_VER="${2:?}"; shift 2 ;;
        --pillow-heif) PH_VER="${2:?}"; shift 2 ;;
        --no-cache)    USE_CACHE=0; shift ;;
        --skip-build)  SKIP_BUILD=1; shift ;;
        -h|--help)     sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "$VENV" ] || VENV="$HOME/hermes-agent/venv"
PY="$VENV/bin/python"
PIP="$VENV/bin/pip"

step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  + %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '\n  FATAL: %s\n' "$*" >&2; exit 1; }

echo "install-pillow-heif-i386"
echo "  venv        : $VENV"
echo "  prefix      : $PREFIX"
echo "  libheif     : $LIBHEIF_VER"
echo "  pillow-heif : $PH_VER"

[ -x "$PY" ] || die "no python at $PY (pass the venv path as arg 1)"

# --- 1. preconditions -------------------------------------------------------
step "preconditions"
missing=0
for t in cmake pkg-config make gcc; do
    if command -v "$t" >/dev/null 2>&1; then
        ok "$t"
    else
        warn "$t MISSING"; missing=1
    fi
done
command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 \
    || { warn "need wget or curl (libheif download)"; missing=1; }

# cmake >= 3.16.3 is required by build_libs.py
if command -v cmake >/dev/null 2>&1; then
    cv="$(cmake --version | head -1 | awk '{print $3}')"
    if [ "$(printf '%s\n3.16.3\n' "$cv" | sort -V | head -1)" = "3.16.3" ]; then
        ok "cmake $cv (>= 3.16.3)"
    else
        warn "cmake $cv is too old (build_libs.py needs >= 3.16.3)"; missing=1
    fi
fi

# libde265 is what actually decodes HEVC; reuse the system one if present so
# libheif does not rebuild it.
# NOTE: do not pipe gcc into grep here. `set -o pipefail` would mark the
# pipeline failed because gcc exits non-zero by design (the probe has no
# main()), which produced a false "not found" for an installed libde265-dev.
de265_out="$(gcc -lde265 -o /dev/null -x c /dev/null 2>&1 || true)"
if printf '%s' "$de265_out" | grep -q "main"; then
    ok "libde265 present (libheif links it, no rebuild)"
else
    warn "libde265-dev not found — libheif will build libde265 from source too"
    case "$DISTRO" in
        alpine) warn "  install it to save time: sudo apk add --no-cache libde265" ;;
        *)      warn "  install it to save time: sudo apt-get install -y libde265-dev" ;;
    esac
fi
[ "$missing" -eq 0 ] || die "install the missing build tools first"

# --- 2. is a good enough libheif already there? -----------------------------
need_build=1
if [ "$SKIP_BUILD" -eq 1 ]; then
    need_build=0
    ok "skipping the libheif build (--skip-build)"
elif pkg-config --exists libheif 2>/dev/null; then
    have="$(pkg-config --modversion libheif 2>/dev/null)"
    if [ "$(printf '%s\n%s\n' "$LIBHEIF_VER" "$have" | sort -V | head -1)" = "$LIBHEIF_VER" ]; then
        need_build=0
        ok "pkg-config already resolves libheif $have (>= $LIBHEIF_VER) — no build needed"
    else
        ok "pkg-config resolves libheif $have — too old, will build $LIBHEIF_VER"
    fi
fi

# --- 3. obtain libheif ------------------------------------------------------
if [ "$need_build" -eq 1 ]; then
    CACHE="$HERE/../dist/libheif-${LIBHEIF_VER}-i386.tar.gz"

    if [ "$USE_CACHE" -eq 1 ] && [ -f "$CACHE" ]; then
        step "installing prebuilt libheif $LIBHEIF_VER from dist/"
        ok "cache: $CACHE ($(stat -c %s "$CACHE") bytes)"
        TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
        tar xzf "$CACHE" -C "$TMP"
        SRC="$(echo "$TMP"/libheif-*)"
        [ -d "$SRC" ] || die "unexpected cache layout"
        sudo mkdir -p "$PREFIX/lib" "$PREFIX/include"
        sudo cp -a "$SRC/lib/." "$PREFIX/lib/"
        sudo cp -a "$SRC/include/." "$PREFIX/include/"
        # rewrite the pkg-config prefix if installing somewhere non-default
        if [ -f "$PREFIX/lib/pkgconfig/libheif.pc" ] && [ "$PREFIX" != "/usr/local" ]; then
            sudo sed -i "s|^prefix=.*|prefix=$PREFIX|" "$PREFIX/lib/pkgconfig/libheif.pc"
            ok "rewrote libheif.pc prefix -> $PREFIX"
        fi
        sudo ldconfig
        ok "installed from cache"
    else
        step "building libheif $LIBHEIF_VER from source"
        warn "this is the slow part: ~10-15 min on a Core Duo"
        [ -f "$CACHE" ] && warn "cache exists but --no-cache was given"

        WORK="$(mktemp -d)"
        trap 'rm -rf "$WORK"' EXIT
        ok "work dir: $WORK"
        "$PIP" download --no-deps --no-binary :all: "pillow-heif==$PH_VER" -d "$WORK" >/dev/null 2>&1 \
            || die "could not download the pillow-heif sdist"
        tar xzf "$WORK"/pillow_heif-*.tar.gz -C "$WORK"
        BL="$WORK/pillow_heif-$PH_VER/libheif"
        [ -f "$BL/build_libs.py" ] || die "build_libs.py not found in the sdist"

        # PH_LIGHT_ACTION forces light mode even if python is not 32-bit, so this
        # is deterministic: no x265, no nasm, decode-only libheif.
        BUILD_DIR="${BUILD_DIR:-/tmp/ph_build_stuff}"
        sudo rm -rf "$BUILD_DIR/libheif"
        ( cd "$BL" && sudo env \
              INSTALL_DIR_LIBS="$PREFIX" \
              BUILD_DIR="$BUILD_DIR" \
              PH_LIGHT_ACTION=1 \
              python3 build_libs.py ) 2>&1 | tail -5 | sed 's/^/    /'
        sudo ldconfig
        ok "libheif $LIBHEIF_VER built and installed to $PREFIX"
    fi
fi

# --- 4. verify libheif is discoverable --------------------------------------
step "libheif visibility"
if pkg-config --exists libheif 2>/dev/null; then
    ok "pkg-config libheif: $(pkg-config --modversion libheif)"
    ok "  cflags: $(pkg-config --cflags-only-I libheif)"
    ok "  libs:   $(pkg-config --libs-only-L libheif)"
else
    die "pkg-config still cannot find libheif — check $PREFIX/lib/pkgconfig"
fi

# --- 5. build pillow-heif WITH an rpath -------------------------------------
# The rpath is what makes the extension load OUR libheif rather than the system
# one, independent of ld.so.conf ordering.
step "building pillow-heif $PH_VER (with rpath)"
export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
export LD_RUN_PATH="$PREFIX/lib"
ok "LDFLAGS=$LDFLAGS"
if "$VENV/bin/pip" install --no-cache-dir --force-reinstall --no-deps \
        "pillow-heif==$PH_VER" >/tmp/ph-install.log 2>&1; then
    ok "installed"
else
    tail -20 /tmp/ph-install.log | sed 's/^/    /'
    die "pillow-heif build failed (see /tmp/ph-install.log)"
fi

# --- 6. functional verification ---------------------------------------------
step "verification"
SO="$("$PY" - <<'PY' 2>/dev/null
import sysconfig, glob, os
for p in sysconfig.get_paths().values():
    for f in glob.glob(os.path.join(p, "_pillow_heif*.so")):
        print(f); raise SystemExit
PY
)"
if [ -n "$SO" ]; then
    ok "extension: $SO"
    rp="$(readelf -d "$SO" 2>/dev/null | grep -iE 'rpath|runpath' | sed 's/.*\[\(.*\)\]/\1/')"
    if [ -n "$rp" ]; then
        ok "rpath: $rp"
    else
        warn "NO rpath — it may load the wrong libheif"
    fi
    loaded="$(ldd "$SO" 2>/dev/null | awk '/libheif/{print $3}')"
    ok "loads libheif from: ${loaded:-<unresolved>}"
    case "$loaded" in
        "$PREFIX"/*) ok "resolves to our build ($PREFIX)" ;;
        "")          warn "libheif not resolved" ;;
        *)           warn "resolves to $loaded, NOT $PREFIX — version skew likely" ;;
    esac
else
    warn "could not locate the built extension"
fi

if "$PY" - <<'PY'
import pillow_heif
pillow_heif.register_heif_opener()
print("  + pillow_heif", pillow_heif.__version__)
print("  + libheif   ", pillow_heif.libheif_version())
PY
then
    ok "import + register_heif_opener() OK"
else
    die "pillow-heif does not import — see the error above"
fi

printf '\n=== done ===\n'
printf '  pillow-heif %s against libheif %s\n' "$PH_VER" "$LIBHEIF_VER"
printf '  NOTE: light mode has no HEVC *encoder* (x265). Decoding HEIC works;\n'
printf '        writing .heic does not. hermes only decodes.\n'
