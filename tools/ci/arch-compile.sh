#!/usr/bin/env bash
# ==============================================================================
#  AcreetionOS Horizon - compilation conversion helper (cross/native)
# ==============================================================================
#  Consumes tools/ci/arch-layer.sh and converts the active architecture into
#  concrete toolchain settings for the three build backends in this repo:
#
#    meson  (patched GNOME 48 / XLibre desktop packages)
#    cargo  (Freeman workspace)
#    gcc    (mkarchiso wrapper is host-tool, always native)
#
#  Usage:
#    arch-compile.sh <command> [arch]     (arch defaults to $HORIZON_ARCH)
#  Commands:
#    env      print shell exports for CC/AR/STRIP/... of the target
#    cargo    print extra arguments for cargo build (cross target triple)
#    meson    path to a generated meson cross file for the target
#    check    verify the toolchain for the arch strategy is available
#
#  Strategies: "native" runs on a same-arch runner (preferred; CI provides
#  arm64 runners); "native-and-cross" also emits cross settings for host
#  machines of the other arch, requiring the cross prefix toolchain to exist.
# ==============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=arch-layer.sh
source "$here/arch-layer.sh"

arch="${2:-${HORIZON_ARCH:-x86_64}}"
arch_set "$arch"
triple="$(arch_gcc_triple)"

fail() { printf 'error: arch-compile: %s\n' "$*" >&2; exit 1; }

native_host="$(uname -m)"
native_ok() { [[ "$(arch_get arch)" == "$native_host" ]]; }

case "${1:-}" in
    env)
        if native_ok; then
            echo "export HORIZON_ARCH=$(arch_get arch)"
            echo "# native build on $native_host: no cross env required"
            exit 0
        fi
        [[ -n "$triple" && "$triple" != "-" ]] || fail "no cross toolchain for $arch (native runner required)"
        t="${triple}"
        echo "export CC=${t}-gcc"
        echo "export CXX=${t}-g++"
        echo "export AR=${t}-ar"
        echo "export AS=${t}-as"
        echo "export LD=${t}-ld"
        echo "export STRIP=${t}-strip"
        echo "export RANLIB=${t}-ranlib"
        echo "export PKG_CONFIG_ALLOW_CROSS=1"
        echo "export HORIZON_ARCH=$(arch_get arch)"
        ;;
    cargo)
        if native_ok; then echo "# native cargo build for $(arch_get arch)"; exit 0; fi
        {
            echo "--target $(arch_get arch)-unknown-linux-gnu"
            echo "--config target.$(arch_get arch)-unknown-linux-gnu.\"linker\"=\"${triple}-gcc\""
        }
        ;;
    meson)
        if native_ok; then echo "# native meson build for $(arch_get arch)"; exit 0; fi
        [[ -n "$triple" && "$triple" != "-" ]] || fail "no cross toolchain for $arch"
        cross_file="$(mktemp "${TMPDIR:-/tmp}/horizon-${arch}-cross.XXXXXXXX.ini")"
        {
            echo "[binaries]"
            echo "c    = '${triple}-gcc'"
            echo "cpp  = '${triple}-g++'"
            echo "ar   = '${triple}-ar'"
            echo "strip= '${triple}-strip'"
            echo "pkg-config = 'pkg-config'"
            echo
            echo "[host_machine]"
            echo "system = 'linux'"
            echo "cpu_family = '$(arch_get arch)'"
            echo "cpu        = '$(arch_get arch)'"
            echo "endian     = 'little'"
        } > "$cross_file"
        echo "$cross_file"
        ;;
    check)
        if native_ok; then
            echo "arch-compile: target $(arch_get arch) matches host ($native_host): native OK"
            exit 0
        fi
        tools_needed=("${triple}gcc" "${triple}g++" "${triple}ar")
        missing=()
        for tool in "${tools_needed[@]}"; do
            command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
        done
        if (( ${#missing[@]} > 0 )); then
            printf 'arch-compile: MISSING cross toolchain for %s: %s\n' \
                "$(arch_get arch)" "${missing[*]}" >&2
            echo "Pick a native runner for this architecture (see CI pipelines) or install the ${triple} toolchain." >&2
            exit 1
        fi
        echo "arch-compile: cross toolchain for $(arch_get arch) present"
        ;;
    ''|--help|-h)
        printf 'Usage: %s <env|cargo|meson|check> [arch]\n' "$0" >&2
        exit 0 ;;
    *) fail "unknown command: $1" ;;
esac
