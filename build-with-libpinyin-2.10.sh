#!/usr/bin/env bash

set -euo pipefail

log() {
    printf '[build-with-libpinyin-2.10] %s\n' "$*"
}

warn() {
    printf '[build-with-libpinyin-2.10] warning: %s\n' "$*" >&2
}

die() {
    printf '[build-with-libpinyin-2.10] error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: scripts/build-with-libpinyin-2.10.sh [options] [-- configure-args...]

Options:
  --prefix DIR             Install prefix passed to configure. Default: /usr
  --build-dir DIR          Out-of-tree build directory.
                           Default: <repo>/build-libpinyin-2.10
  --libpinyin-pcdir DIR    Directory containing the libpinyin-2.10 pkg-config
                           file. Default: /usr/lib/pkgconfig
  --install                Run make install and ldconfig after a successful build
  --refresh-ibus           Run ibus cache refresh and restart after install/build
  -h, --help               Show this help

Examples:
  scripts/build-with-libpinyin-2.10.sh
  scripts/build-with-libpinyin-2.10.sh --install --refresh-ibus
  scripts/build-with-libpinyin-2.10.sh -- --disable-cloud-input-mode
EOF
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

version_ge() {
    local lhs=$1
    local rhs=$2
    [[ "$(printf '%s\n%s\n' "$rhs" "$lhs" | sort -V | head -n1)" == "$rhs" ]]
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

PREFIX=/usr
BUILD_DIR="${REPO_ROOT}/build-libpinyin-2.10"
LIBPINYIN_PCDIR=/usr/lib/pkgconfig
DO_INSTALL=0
DO_REFRESH_IBUS=0
CONFIGURE_ARGS=()

while (($# > 0)); do
    case "$1" in
        --prefix)
            shift
            [[ $# -gt 0 ]] || die "--prefix requires a value"
            PREFIX=$1
            ;;
        --build-dir)
            shift
            [[ $# -gt 0 ]] || die "--build-dir requires a value"
            BUILD_DIR=$1
            ;;
        --libpinyin-pcdir)
            shift
            [[ $# -gt 0 ]] || die "--libpinyin-pcdir requires a value"
            LIBPINYIN_PCDIR=$1
            ;;
        --install)
            DO_INSTALL=1
            ;;
        --refresh-ibus)
            DO_REFRESH_IBUS=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            CONFIGURE_ARGS+=("$@")
            break
            ;;
        *)
            CONFIGURE_ARGS+=("$1")
            ;;
    esac
    shift
done

require_tool autoreconf
require_tool make
require_tool pkg-config
require_tool sed
require_tool nproc
require_tool awk

if command -v /usr/bin/python3 >/dev/null 2>&1; then
    HAVE_WITH_PYTHON=0
    for arg in "${CONFIGURE_ARGS[@]}"; do
        if [[ "${arg}" == --with-python=* || "${arg}" == "--with-python" ]]; then
            HAVE_WITH_PYTHON=1
            break
        fi
    done
    if (( ! HAVE_WITH_PYTHON )); then
        CONFIGURE_ARGS+=(--with-python=/usr/bin/python3)
    fi
fi

NEW_PC="${LIBPINYIN_PCDIR}/libpinyin.pc"
OLD_PC="/usr/lib/x86_64-linux-gnu/pkgconfig/libpinyin.pc"
NEW_SO="/usr/lib/libpinyin.so"
NEW_SO_VERSIONED="/usr/lib/libpinyin.so.15"
OLD_SO_VERSIONED="/usr/lib/x86_64-linux-gnu/libpinyin.so.13"
OLD_STATIC="/usr/lib/x86_64-linux-gnu/libpinyin.a"
PYXMLUTIL="${REPO_ROOT}/src/PYXMLUtil.cc"

[[ -f "${NEW_PC}" ]] || die "expected new pkg-config file not found: ${NEW_PC}"
[[ -f "${PYXMLUTIL}" ]] || die "source file not found: ${PYXMLUTIL}"

NEW_VERSION=$(PKG_CONFIG_PATH="${LIBPINYIN_PCDIR}" pkg-config --modversion libpinyin 2>/dev/null || true)
[[ -n "${NEW_VERSION}" ]] || die "failed to query libpinyin version from ${NEW_PC}"
version_ge "${NEW_VERSION}" "2.9.92" || die "libpinyin from ${NEW_PC} is too old: ${NEW_VERSION}"

DEFAULT_VERSION=$(pkg-config --modversion libpinyin 2>/dev/null || true)
if [[ -n "${DEFAULT_VERSION}" && "${DEFAULT_VERSION}" != "${NEW_VERSION}" ]]; then
    warn "default pkg-config resolves libpinyin ${DEFAULT_VERSION}; build will override it with ${LIBPINYIN_PCDIR}"
fi

[[ -e "${NEW_SO}" || -e "${NEW_SO_VERSIONED}" ]] || die "new libpinyin shared library not found under /usr/lib"

if [[ -f "${OLD_PC}" ]]; then
    OLD_VERSION=$(sed -n 's/^Version: //p' "${OLD_PC}" | head -n1 || true)
    warn "detected legacy pkg-config file: ${OLD_PC}${OLD_VERSION:+ (${OLD_VERSION})}"
fi

if [[ -e "${OLD_SO_VERSIONED}" || -e "${OLD_STATIC}" ]]; then
    warn "detected legacy libpinyin libraries under /usr/lib/x86_64-linux-gnu; build will force /usr/lib first"
fi

OLD_MARKUP_LINE='g_markup_parse_context_new (&engine_xml_parser, G_MARKUP_DEFAULT_FLAGS, &xmlfile, NULL);'
NEW_MARKUP_LINE='g_markup_parse_context_new (&engine_xml_parser, (GMarkupParseFlags)0, &xmlfile, NULL);'
if grep -Fq "${OLD_MARKUP_LINE}" "${PYXMLUTIL}"; then
    log "applying GLib compatibility patch in src/PYXMLUtil.cc"
    sed -i "s/G_MARKUP_DEFAULT_FLAGS/(GMarkupParseFlags)0/" "${PYXMLUTIL}"
elif grep -Fq "${NEW_MARKUP_LINE}" "${PYXMLUTIL}"; then
    log "GLib compatibility patch already present in src/PYXMLUtil.cc"
else
    warn "did not find the expected GMarkup line in src/PYXMLUtil.cc; leaving file unchanged"
fi

log "running autoreconf to regenerate missing autotools files"
(cd "${REPO_ROOT}" && autoreconf -vfi)

mkdir -p "${BUILD_DIR}"

export PKG_CONFIG_PATH="${LIBPINYIN_PCDIR}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export CPPFLAGS="-I/usr/include${CPPFLAGS:+ ${CPPFLAGS}}"
export LDFLAGS="-L/usr/lib -Wl,-rpath,/usr/lib${LDFLAGS:+ ${LDFLAGS}}"
export LIBS="-ldb${LIBS:+ ${LIBS}}"

if [[ -f "${REPO_ROOT}/config.status" && "${BUILD_DIR}" != "${REPO_ROOT}" ]]; then
    warn "source tree is already configured; falling back to an in-tree build in ${REPO_ROOT}"
    BUILD_DIR="${REPO_ROOT}"
fi

log "configuring build in ${BUILD_DIR}"
(
    cd "${BUILD_DIR}"
    "${REPO_ROOT}/configure" --prefix="${PREFIX}" "${CONFIGURE_ARGS[@]}"
)

GENERATED_LIBPINYIN_LIBS=$(sed -n 's/^LIBPINYIN_LIBS = //p' "${BUILD_DIR}/src/Makefile" | head -n1 || true)
GENERATED_LIBPINYIN_CFLAGS=$(sed -n 's/^LIBPINYIN_CFLAGS = //p' "${BUILD_DIR}/src/Makefile" | head -n1 || true)
GENERATED_LDFLAGS=$(sed -n 's/^LDFLAGS = //p' "${BUILD_DIR}/src/Makefile" | head -n1 || true)
RESOLVED_PCFILEDIR=$(PKG_CONFIG_PATH="${LIBPINYIN_PCDIR}" pkg-config --variable=pcfiledir libpinyin)

[[ -n "${GENERATED_LIBPINYIN_LIBS}" ]] || die "failed to extract LIBPINYIN_LIBS from ${BUILD_DIR}/src/Makefile"
[[ -n "${GENERATED_LIBPINYIN_CFLAGS}" ]] || die "failed to extract LIBPINYIN_CFLAGS from ${BUILD_DIR}/src/Makefile"
log "configure resolved libpinyin pcfiledir: ${RESOLVED_PCFILEDIR}"
log "configure resolved LIBPINYIN_CFLAGS: ${GENERATED_LIBPINYIN_CFLAGS}"
log "configure resolved LIBPINYIN_LIBS: ${GENERATED_LIBPINYIN_LIBS}"

if [[ "${RESOLVED_PCFILEDIR}" != "${LIBPINYIN_PCDIR}" ]]; then
    die "pkg-config resolved an unexpected libpinyin pcfiledir: ${RESOLVED_PCFILEDIR}"
fi

if [[ "${GENERATED_LIBPINYIN_CFLAGS}" != *"libpinyin-${NEW_VERSION}"* ]]; then
    die "configure did not pick the libpinyin-${NEW_VERSION} headers: ${GENERATED_LIBPINYIN_CFLAGS}"
fi

if [[ "${GENERATED_LDFLAGS}" != *"-L/usr/lib"* || "${GENERATED_LDFLAGS}" != *"-Wl,-rpath,/usr/lib"* ]]; then
    die "configure lost the forced /usr/lib linker flags: ${GENERATED_LDFLAGS}"
fi

log "building ibus-engine-libpinyin"
(
    cd "${BUILD_DIR}"
    make -j"$(nproc)" V=1
)

ENGINE_BIN="${BUILD_DIR}/src/.libs/ibus-engine-libpinyin"
if [[ ! -x "${ENGINE_BIN}" ]]; then
    ENGINE_BIN="${BUILD_DIR}/src/ibus-engine-libpinyin"
fi
[[ -x "${ENGINE_BIN}" ]] || die "expected built binary not found under ${BUILD_DIR}/src"

if command -v ldd >/dev/null 2>&1; then
    LINKED_LIBPINYIN=$(ldd "${ENGINE_BIN}" | awk '/libpinyin\.so/ {print $3; exit}')
    [[ -n "${LINKED_LIBPINYIN}" ]] || die "ldd did not report a linked libpinyin shared library"
    log "ldd resolved libpinyin to: ${LINKED_LIBPINYIN}"
    [[ "${LINKED_LIBPINYIN}" == /usr/lib/libpinyin.so* ]] || die "binary linked against unexpected libpinyin: ${LINKED_LIBPINYIN}"
fi

if ((DO_INSTALL)); then
    log "installing into ${PREFIX}"
    if [[ ${EUID} -eq 0 ]]; then
        (cd "${BUILD_DIR}" && make install)
        ldconfig
    else
        require_tool sudo
        (cd "${BUILD_DIR}" && sudo make install)
        sudo ldconfig
    fi
fi

if ((DO_REFRESH_IBUS)); then
    if ! command -v ibus >/dev/null 2>&1; then
        warn "ibus command not found; skipping refresh"
    elif [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        warn "DBUS_SESSION_BUS_ADDRESS is not set; run 'ibus read-cache && ibus restart' from your desktop session"
    else
        log "refreshing ibus component cache"
        ibus read-cache || warn "ibus read-cache failed"
        ibus restart || ibus-daemon -drx || warn "failed to restart ibus in the current session"
    fi
fi

log "finished successfully"
