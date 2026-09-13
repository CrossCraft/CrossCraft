#!/usr/bin/env bash
set -euo pipefail

# --fetch=all includes SDL's optional FreeType dependency. Its Savannah URL
# can return 502 in CI, so seed Zig's cache from FreeType's official mirror.
# Keep this hash in sync with the freetype wrapper's build.zig.zon.
freetype_hash='N-V-__8AAJo-LAHFNfa0p0oMQqmwlBEAZMOeo03azXgrKLTT'
freetype_url='https://downloads.sourceforge.net/project/freetype/freetype2/2.14.3/freetype-2.14.3.tar.xz'
if fetched_hash=$(zig fetch "$freetype_url"); then
    if [[ "$fetched_hash" != "$freetype_hash" ]]; then
        echo '::error::FreeType mirror package hash does not match the pinned dependency.'
        exit 1
    fi
else
    echo '::warning::FreeType mirror unavailable; trying the original dependency URLs.'
fi

# Preserve completed downloads between attempts when an upstream host fails.
for attempt in 1 2 3; do
    if zig build --fetch=all; then
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
