#!/usr/bin/env bash
set -euo pipefail

# SDL's FreeType dependency is fetched from Savannah, which can return 502 in
# CI, so seed Zig's cache from FreeType's official mirror.
# Keep this hash in sync with the freetype wrapper's build.zig.zon.
# Seed through `zig build` rather than `zig fetch <url>`: on 0.18-dev the
# latter caches the archive without stripping the tarball's root directory,
# poisoning the cache with contents that no longer match the hash.
freetype_hash='N-V-__8AAJo-LAHFNfa0p0oMQqmwlBEAZMOeo03azXgrKLTT'
freetype_url='https://downloads.sourceforge.net/project/freetype/freetype2/2.14.3/freetype-2.14.3.tar.xz'
seed_dir=$(mktemp -d)
trap 'rm -rf "$seed_dir"' EXIT
echo 'pub fn build(_: *@import("std").Build) void {}' >"$seed_dir/build.zig"
cat >"$seed_dir/build.zig.zon" <<EOF
.{
    .name = .freetype_mirror,
    .version = "0.0.0",
    .fingerprint = 0xccc56d58c01ed58,
    .dependencies = .{
        .freetype = .{ .url = "$freetype_url", .hash = "$freetype_hash" },
    },
    .paths = .{""},
}
EOF
if ! zig build --build-file "$seed_dir/build.zig" --fetch; then
    echo '::warning::FreeType mirror unavailable; trying the original dependency URLs.'
fi

# Configure each CI target so build.zig requests only the lazy dependencies
# it actually uses. --fetch=all would also pull unused ones (e.g. dxc), whose
# build scripts are then compiled and may not support this Zig version. macOS
# is omitted: SDL refuses to configure it from Linux without a sysroot.
fetch_all_targets() {
    zig build -l >/dev/null &&
        zig build -l -Dtarget=x86_64-windows-gnu >/dev/null &&
        zig build -l -Dtarget=mipsel-psp >/dev/null &&
        zig build -l -Dtarget=arm-3ds >/dev/null &&
        zig build -l -Dtarget=aarch64-switch >/dev/null
}

# Preserve completed downloads between attempts when an upstream host fails.
for attempt in 1 2 3; do
    if fetch_all_targets; then
        exit 0
    fi
    if (( attempt < 3 )); then
        delay=$((attempt * 10))
        echo "::warning::Zig package fetch failed (attempt $attempt/3); retrying in ${delay}s."
        sleep "$delay"
    fi
done

echo '::error::Zig package fetch failed after 3 attempts.'
exit 1
