#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_dir="${HORIZON_BUILD_DIR:-$root_dir/.horizon-build}"

mkdir -p "$out_dir"
cargo build --release --manifest-path "$root_dir/tools/freeman/Cargo.toml"
install -m 0755 "$root_dir/tools/freeman/target/release/pamac" "$out_dir/freeman"
