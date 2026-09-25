#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${HORIZON_PATCH_MANIFEST:-$root_dir/xlibre-patches/packages.conf}"
build_dir="${HORIZON_BUILD_DIR:-$root_dir/.horizon-build}"
check_only=false
case "${1:-}" in
    --check-patches) check_only=true ;;
    --help|-h)
        printf 'Usage: %s [--check-patches]\n' "$0"
        printf 'Fetch pinned sources and apply patches, or build the complete local repository.\n'
        exit 0 ;;
    '') ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { printf 'error: too many arguments\n' >&2; exit 2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "$manifest" ]] || fail "missing source manifest: $manifest"
# Validate every entry before creating files or invoking a build tool.
mapfile -t entries < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$manifest")
(( ${#entries[@]} > 0 )) || fail 'source manifest is empty'
declare -A seen=()
for entry in "${entries[@]}"; do
    IFS='|' read -r package repository ref meson_options extra <<< "$entry"
    [[ "$package" =~ ^[a-z0-9][a-z0-9+._-]*$ && -n "$repository" && "$ref" =~ ^v?[0-9]+(\.[0-9]+)*$ && -z "$extra" ]] || fail "invalid source manifest entry: $entry"
    [[ -z "${seen[$package]:-}" ]] || fail "duplicate package: $package"
    seen[$package]=1
    read -r -a options <<< "$meson_options"
    for option in "${options[@]}"; do
        [[ "$option" =~ ^-D[a-zA-Z0-9_-]+=[a-zA-Z0-9_./,+:-]+$ ]] || fail "invalid Meson option: $option"
    done
done

tools=(git patch mktemp)
if ! "$check_only"; then
    tools+=(meson ninja makepkg repo-add glib-mkenums python3 pkg-config)
    [[ -f "${PACMAN_CONF:-$root_dir/pacman.conf}" ]] || fail 'missing base pacman.conf'
    if [[ "$(id -u)" -eq 0 ]]; then tools+=(setpriv useradd chown); fi
fi
for tool in "${tools[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || fail "required build tool is missing: $tool"
done
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
# Each invocation owns a fresh directory. Never delete the caller's build root.
run_dir="$(mktemp -d "$build_dir/run.XXXXXXXX")"
trap 'status=$?; if (( status != 0 )); then printf "Build failed; diagnostics retained in %s\n" "$run_dir" >&2; fi' EXIT
source_dir="$run_dir/sources"
repo_dir="$build_dir/repo"
mkdir -p "$source_dir" "$run_dir/packages" "$run_dir/pkgconfig"
base_ld_library_path="${LD_LIBRARY_PATH:-}"
base_gi_typelib_path="${GI_TYPELIB_PATH:-}"
export PKG_CONFIG_PATH="$run_dir/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export XDG_DATA_DIRS="$run_dir/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

for entry in "${entries[@]}"; do
    IFS='|' read -r package repository ref meson_options <<< "$entry"
    source_path="$source_dir/$package"
    build_path="$run_dir/meson/$package"
    stage_path="$run_dir/stage/$package"
    package_path="$run_dir/package/$package"
    git clone --depth 1 --branch "$ref" -- "$repository" "$source_path"
    # Refuse a moving branch masquerading as the release tag.
    [[ "$(git -C "$source_path" rev-parse HEAD)" == "$(git -C "$source_path" rev-parse "refs/tags/$ref^{commit}")" ]] || fail "not the release tag: $package $ref"
    shopt -s nullglob
    patches=("$root_dir/xlibre-patches/$package/"*.patch)
    for patch_file in "${patches[@]}"; do
        printf 'Applying patch: %s\n' "$patch_file"
        patch -p1 --directory "$source_path" --forward --batch --fuzz=0 < "$patch_file"
    done
    if "$check_only"; then continue; fi

    mkdir -p "$stage_path" "$package_path"
    read -r -a options <<< "$meson_options"
    meson setup "$build_path" "$source_path" --prefix=/usr --libdir=lib \
        --libexecdir=lib --sysconfdir=/etc --localstatedir=/var \
        --buildtype=release "${options[@]}"
    meson compile -C "$build_path" -j "${HORIZON_BUILD_JOBS:-$(nproc)}"
    DESTDIR="$stage_path" meson install -C "$build_path" --no-rebuild

    rm -rf "$stage_path/usr/share/doc" "$stage_path/usr/share/gtk-doc" \
        "$stage_path/usr/share/man" "$stage_path/usr/share/info" "$stage_path/usr/share/help"
    for directory in "$stage_path/usr/sbin" "$stage_path/sbin"; do
        if [[ -d "$directory" && ! -L "$directory" ]]; then
            mkdir -p "$stage_path/usr/bin"
            cp -a "$directory/." "$stage_path/usr/bin/"
            rm -rf "$directory"
        fi
    done
    # The ISO overlay owns GDM's configuration.
    if [[ "$package" == gdm ]]; then
        rm -f "$stage_path/etc/gdm/custom.conf"
        mkdir -p "$stage_path/usr/lib/sysusers.d" "$stage_path/var/lib/gdm" "$stage_path/var/log/gdm"
        cat > "$stage_path/usr/lib/sysusers.d/gdm.conf" <<'SYSEOF'
g gdm 120 -
u gdm 120 "Gnome Display Manager" /var/lib/gdm /usr/bin/nologin
m gdm video
SYSEOF
    fi

    # Relocate only build copies of .pc files; packaged metadata stays under /usr.
    python3 "$root_dir/xlibre-patches/build-support.py" stage-pkgconfig "$stage_path" "$run_dir/pkgconfig"
    mkdir -p "$run_dir/share/gir-1.0"
    while IFS= read -r -d '' gir; do
        cp "$gir" "$run_dir/share/gir-1.0/"
    done < <(find "$stage_path/usr" -name '*.gir' -print0)
    library_dirs=("$stage_path/usr/lib")
    for directory in "$stage_path/usr/lib/"mutter-* "$stage_path/usr/lib/girepository-1.0"; do
        [[ -d "$directory" ]] && library_dirs+=("$directory")
    done
    for directory in "${library_dirs[@]}"; do
        base_ld_library_path="$directory${base_ld_library_path:+:$base_ld_library_path}"
        base_gi_typelib_path="$directory${base_gi_typelib_path:+:$base_gi_typelib_path}"
    done
    export LD_LIBRARY_PATH="$base_ld_library_path"
    export GI_TYPELIB_PATH="$base_gi_typelib_path"

    cat > "$package_path/PKGBUILD" <<EOF
pkgname=$package
pkgver=${ref#v}
pkgrel=2
epoch=2
pkgdesc='AcreetionOS Horizon patched GNOME component'
arch=('x86_64')
license=('GPL')
options=('!docs' '!libtool' '!staticlibs' 'emptydirs' 'zipman' 'purge' '!debug' '!lto')
package() {
    cp -a "\$HORIZON_STAGE/." "\$pkgdir/"
}
EOF
    # Upstream GDM installs both daemon and libgdm, unlike Arch's split package.
    if [[ "$package" == gdm ]]; then
        printf "provides=('libgdm=%s' 'libgdm.so=1-64')\nconflicts=('libgdm')\n" "${ref#v}" >> "$package_path/PKGBUILD"
    fi
    (
        if [[ "$(id -u)" -eq 0 ]]; then
            id -u builduser >/dev/null 2>&1 || useradd -m -s /bin/bash builduser
            # Makepkg must be unprivileged. A private /tmp copy avoids home-dir
            # traversal failures without chmod 777 or changing checkout ACLs.
            packaging_tmp="$(mktemp -d /tmp/horizon-package.XXXXXXXX)"
            trap 'rm -rf "$packaging_tmp"' EXIT
            cp "$package_path/PKGBUILD" "$packaging_tmp/"
            cp -a "$stage_path" "$packaging_tmp/stage"
            chown -R builduser:builduser "$packaging_tmp"
            cd "$packaging_tmp"
            setpriv --reuid=builduser --regid=builduser --clear-groups \
                env HORIZON_STAGE="$packaging_tmp/stage" \
                makepkg --noconfirm --nodeps --clean
            cp -- ./*.pkg.tar.* "$run_dir/packages/"
        else
            cd "$package_path"
            HORIZON_STAGE="$stage_path" makepkg --noconfirm --nodeps --clean
            cp -- ./*.pkg.tar.* "$run_dir/packages/"
        fi
    )
done

if "$check_only"; then
    printf 'All patches applied successfully. Sources retained in %s\n' "$source_dir"
    exit 0
fi
packages=("$run_dir/packages/"*.pkg.tar.zst "$run_dir/packages/"*.pkg.tar.xz "$run_dir/packages/"*.pkg.tar.gz)
(( ${#packages[@]} > 0 )) || fail 'no patched packages were built'
# Build a fresh database so entries removed from the manifest cannot linger.
repo-add "$run_dir/packages/horizon-patched.db.tar.gz" "${packages[@]}"
python3 "$root_dir/xlibre-patches/build-support.py" pacman-config \
    "${PACMAN_CONF:-$root_dir/pacman.conf}" "$repo_dir" "$run_dir/pacman.conf"
mkdir -p "$repo_dir"
cp -a "$run_dir/packages/." "$repo_dir/"
mv "$run_dir/pacman.conf" "$build_dir/pacman.conf"
printf 'Patched repository ready: %s\nBuild diagnostics retained: %s\n' "$repo_dir" "$run_dir"
