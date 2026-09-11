#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${HORIZON_PATCH_MANIFEST:-$root_dir/xlibre-patches/packages.conf}"
build_dir="${HORIZON_BUILD_DIR:-$root_dir/.horizon-build}"
source_dir="$build_dir/sources"
repo_dir="$build_dir/repo"

[[ -f "$manifest" ]] || { printf 'error: missing source manifest: %s\n' "$manifest" >&2; exit 1; }
for tool in git meson makepkg repo-add glib-mkenums; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'error: required build tool is missing: %s\n' "$tool" >&2
        exit 1
    }
done
if [[ "$(id -u)" -eq 0 ]]; then
    rm -rf "$build_dir"
else
    rm -rf "$build_dir" 2>/dev/null || sudo rm -rf "$build_dir"
fi
mkdir -p "$source_dir" "$repo_dir"
mapfile -t entries < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$manifest")

for entry in "${entries[@]}"; do
    IFS='|' read -r package repository ref meson_options <<< "$entry"
    [[ -n "${package:-}" && -n "${repository:-}" && -n "${ref:-}" ]] || {
        printf 'error: invalid source manifest entry: %s\n' "$entry" >&2
        exit 2
    }

    source_path="$source_dir/$package"
    build_path="$build_dir/meson/$package"
    stage_path="$build_dir/stage/$package"
    package_path="$build_dir/package/$package"
    mkdir -p "$build_path" "$stage_path" "$package_path"
    git clone --depth 1 --branch "$ref" "$repository" "$source_path"

    patch_dir="$root_dir/xlibre-patches/$package"
    if [[ -d "$patch_dir" ]]; then
        while IFS= read -r patch_file; do
            echo "Applying patch: $patch_file"
            patch -p1 --directory "$source_path" --forward --batch < "$patch_file"
        done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' | sort)
    fi

    export PKG_CONFIG_PATH="$build_dir/stage_pkgconfig:${PKG_CONFIG_PATH:-}"
    mkdir -p "$build_dir/stage_pkgconfig"
    find "$build_dir/stage"/*/usr/lib/pkgconfig "$build_dir/stage"/*/usr/share/pkgconfig -type f 2>/dev/null -exec cp -f {} "$build_dir/stage_pkgconfig/" \; || true

    # Provide include headers from previous build stages (e.g. mutter-16 for gnome-shell)
    cflags=""
    for incdir in "$build_dir/stage"/*/usr/include "$build_dir/stage"/*/usr/include/*/clutter "$build_dir/stage"/*/usr/include/*/cogl "$build_dir/stage"/*/usr/include/*/mtk; do
        if [[ -d "$incdir" ]]; then
            cflags+=" -I$incdir"
        fi
    done
    export CFLAGS="${CFLAGS:-} $cflags"
    export CXXFLAGS="${CXXFLAGS:-} $cflags"
    export CPPFLAGS="${CPPFLAGS:-} $cflags"

    meson setup "$build_path" "$source_path" --prefix=/usr --buildtype=release $meson_options
    meson compile -C "$build_path"
    DESTDIR="$stage_path" meson install -C "$build_path"
    
    # Arch package compatibility fix: merge sbin into bin if present
    if [[ -d "$stage_path/usr/sbin" ]]; then
        mkdir -p "$stage_path/usr/bin"
        cp -a "$stage_path/usr/sbin/." "$stage_path/usr/bin/"
        rm -rf "$stage_path/usr/sbin"
    fi
    if [[ -d "$stage_path/sbin" ]]; then
        mkdir -p "$stage_path/usr/bin"
        cp -a "$stage_path/sbin/." "$stage_path/usr/bin/"
        rm -rf "$stage_path/sbin"
    fi
    
    find "$stage_path/usr/lib/pkgconfig" "$stage_path/usr/share/pkgconfig" -type f 2>/dev/null -exec cp -f {} "$build_dir/stage_pkgconfig/" \; || true

    # Do not package etc/gdm/custom.conf inside gdm package so airootfs overlay can provide it without conflict
    rm -f "$stage_path/etc/gdm/custom.conf"

    # Also stage libraries and pkgconfig for later components to link against
    if [[ -d "$stage_path/usr/lib" ]]; then
        ln -sfn "$stage_path/usr/lib" "$build_dir/staged-libs-$package"
        # Ensure dynamic linker and linker can find staged libraries
        export LD_LIBRARY_PATH="$stage_path/usr/lib:$stage_path/usr/lib/mutter-16:${LD_LIBRARY_PATH:-}"
        export LDFLAGS="${LDFLAGS:-} -L$stage_path/usr/lib -L$stage_path/usr/lib/mutter-16"
    fi

    # Merge this package's staged headers into a shared staging include tree
    # so later builds (e.g. gnome-shell needing mutter's meta/* headers) resolve includes.
    mkdir -p "$build_dir/stage_usr/include" "$build_dir/stage_usr/lib/girepository-1.0" "$build_dir/stage_usr/share/gir-1.0" "$build_dir/stage_usr/lib/mutter-16"
    if [[ -d "$stage_path/usr/include" ]]; then
        cp -a "$stage_path/usr/include/." "$build_dir/stage_usr/include/"
        export CFLAGS="${CFLAGS:-} -I$build_dir/stage_usr/include -I$build_dir/stage_usr/include/mutter-16 -I$build_dir/stage_usr/include/mutter-16/clutter -I$build_dir/stage_usr/include/mutter-16/cogl -I$build_dir/stage_usr/include/mutter-16/mtk"
        export CXXFLAGS="${CXXFLAGS:-} -I$build_dir/stage_usr/include -I$build_dir/stage_usr/include/mutter-16"
        export CPPFLAGS="${CPPFLAGS:-} -I$build_dir/stage_usr/include -I$build_dir/stage_usr/include/mutter-16"
    fi

    # Stage GIR/typelib files so downstream g-ir-scanner can resolve deps (Clutter-16, Meta-16).
    # Mutter installs .gir/.typelib under $libdir/mutter-16 (per girdir in the .pc file).
    find "$stage_path" -name '*.gir' -exec cp -f {} "$build_dir/stage_usr/share/gir-1.0/" \; 2>/dev/null || true
    find "$stage_path" -name '*.typelib' -exec cp -f {} "$build_dir/stage_usr/lib/girepository-1.0/" \; 2>/dev/null || true
    if [[ -d "$stage_path/usr/lib/mutter-16" ]]; then
        cp -a "$stage_path/usr/lib/mutter-16/." "$build_dir/stage_usr/lib/mutter-16/" 2>/dev/null || true
    fi
    export XDG_DATA_DIRS="$build_dir/stage_usr/share:${XDG_DATA_DIRS:-}"

    cat > "$package_path/PKGBUILD" <<EOF
pkgname=$package
pkgver=${ref#v}
pkgrel=1
epoch=2
pkgdesc='AcreetionOS Horizon patched GNOME component'
arch=('x86_64')
license=('GPL')
package() {
    cp -a "\$HORIZON_STAGE/." "\$pkgdir/"
}
EOF
    (
        export MAKEFLAGS="-j$(nproc)"
        export CFLAGS CPPFLAGS LDFLAGS
        export PKG_CONFIG_PATH LD_LIBRARY_PATH
        cd "$package_path"
        if [[ "$(id -u)" -eq 0 ]]; then
            id -u builduser >/dev/null 2>&1 || useradd -m -s /bin/bash builduser
            # Grant builduser rwX via ACL without changing ownership (keeps natalie access).
            setfacl -R -m u:builduser:rwX "$build_dir" 2>/dev/null || chmod -R 777 "$build_dir"
            # Default ACLs so files builduser creates stay accessible to the caller.
            setfacl -R -d -m u:builduser:rwX "$build_dir" 2>/dev/null || true
            # Re-grant natalie full access on the shared tree.
            chmod 777 "$build_dir"
            HORIZON_STAGE="$stage_path" CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" PKG_CONFIG_PATH="$PKG_CONFIG_PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" setpriv --reuid=builduser --regid=builduser --clear-groups env HORIZON_STAGE="$stage_path" CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" PKG_CONFIG_PATH="$PKG_CONFIG_PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" HOME=/tmp XDG_CACHE_HOME=/tmp/.cache makepkg --noconfirm --nodeps --clean
            setfacl -R -m u:"$(logname 2>/dev/null || echo natalie)":rwX "$build_dir" 2>/dev/null || true
        else
            HORIZON_STAGE="$stage_path" makepkg --noconfirm --nodeps --clean
        fi
    )
    find "$package_path" -maxdepth 1 -type f -name '*.pkg.tar.*' -exec cp -f {} "$repo_dir/" \;
done

shopt -s nullglob
packages=("$repo_dir"/*.pkg.tar.*)
(( ${#packages[@]} > 0 )) || { printf 'error: no patched packages were built\n' >&2; exit 1; }
repo-add --remove "$repo_dir/horizon-patched.db.tar.gz" "${packages[@]}"
cat > "$build_dir/pacman.conf" <<EOF
[horizon-patched]
SigLevel = Never
Server = file://${repo_dir}

EOF
cat "$root_dir/pacman.conf" >> "$build_dir/pacman.conf"
if [[ "$(id -u)" -eq 0 ]]; then
    rm -rf "$source_dir" "$build_dir/meson" "$build_dir/stage" "$build_dir/package"
else
    rm -rf "$source_dir" "$build_dir/meson" "$build_dir/stage" "$build_dir/package" 2>/dev/null || sudo rm -rf "$source_dir" "$build_dir/meson" "$build_dir/stage" "$build_dir/package"
fi
