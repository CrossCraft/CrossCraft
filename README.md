# CrossCraft

CrossCraft is a monorepo of clean-room Minecraft reimplementations written in Zig on top of the custom Aether engine. It is developed in phases, one classic-era version at a time.

The current phase is **Classic (0.30)**, now at **v1.0**. Each completed phase stays in the tree as a first-class build. Shared code lives in shared modules; version-specific behavior lives behind branching code paths so that improvements made while developing a newer phase flow back into older ones automatically.

Concretely:

- An audio optimization made while working on Survival Test is immediately available to Classic. Cut a new Classic build and players get it.
- A new Aether target plus minimal integration work brings every existing phase to that platform at once.
- Bug fixes in shared systems (worldgen primitives, networking, rendering, allocators) benefit every phase in the repo.

This is the point of the monorepo: keep every implementation alive and improving as the project moves forward, instead of forking and abandoning.

## Classic v1.0

Classic v1.0 is a feature-complete, clean-room reimplementation of Minecraft Classic 0.30.

- **Classic 0.30 protocol** - full client and server implementation, compatible with the public Classic protocol.
- **Singleplayer and multiplayer** - singleplayer runs an in-process server behind a `FakeConn`; there is no second code path.
- **Desktop + PSP** - Linux, macOS, Windows, and PSP (both PSP-1000 and PSP-2000+ memory profiles) ship from the same tree.
- **Fixed-point worldgen and rendering** - deterministic across targets, fast on hardware without an FPU.
- **Zero post-init allocation on the server.** Minimal hot-path allocation on the client.
- **Full in-game settings UI** - options persist in a JSON file and are wired into every system.

## Status

| Component        | State       | Notes                                                       |
|------------------|-------------|-------------------------------------------------------------|
| Server (Classic) | v1.0        | Stable. Speaks the Classic 0.30 protocol.                   |
| Client (Classic) | v1.0        | Stable. Full singleplayer and multiplayer, desktop and PSP. |
| Engine (Aether)  | In-tree dep | Powers rendering, audio, input, packing, platform ports.    |

## Roadmap

The near-term plan, in order:

1. **Classic Server v1.1** - next up. Iterate on the server first so improvements land for everyone speaking the protocol.
2. **Classic v1.1** - follow-up client release built on top of the v1.1 server work.
3. **Survival Test** - the next phase. Shares the engine, common primitives, and most of the game module with Classic.

No firm dates or feature promises on any of the above yet; specifics land in release notes as each ships.

Additional platforms (3DS, Nintendo Switch) are under consideration. Adding them is mostly an Aether targeting exercise plus minimal per-platform integration; once that lands, every existing phase in the repo gains support at once.

## Design Goals

1. Strong performance on real hardware, including PSP-class targets (333 MHz, ~32-64 MB).
2. No runtime allocation on the server after init. The client follows the same rule on hot paths as much as possible.
3. Fixed-point worldgen and rendering. Floating point is reserved for a few simulation paths. This keeps results identical across targets and keeps the math cheap on platforms without fast FPUs.
4. Shared code by default; branching only where versions actually differ.

The full style rules live in `STYLE.MD`. They are inspired by NASA's Power of Ten and TigerBeetle's Tiger Style: assertions on in release builds, bounded loops, sized buffers, explicit-sized integer types, no recursion, narrow platform boundaries, and server-first allocation discipline.

## Performance Notes

- Desktop: high frame rates at full view distance.
- PSP: 60-70 FPS in normal terrain, dipping into the mid-50s only in the densest forest. Achieved through aggressive section LODs, fixed-point worldgen and rendering, and careful meshing. Two memory profiles are available: the default PSP build and `-Dslim=true` for the PSP-2000+ to take advantage of higher memory.
- Server: zero allocations after init. Builds for desktop and PSP.

## Building

A recent Zig (matching `build.zig.zon`'s `minimum_zig_version`) is required. On macOS, install `glfw` and `vulkan-loader` first.

```
zig build game     -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe   # desktop client
zig build server   -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe   # standalone server
zig build run-game                                                    # run client locally
zig build run-server                                                  # run server locally
zig build test                                                        # unit tests
```

### PSP

```
zig build game   -Dtarget=mipsel-psp                # default PSP profile
zig build game   -Dtarget=mipsel-psp -Dslim=true    # PSP-2000+ slim profile
zig build server -Dtarget=mipsel-psp                # server build for PSP
```

PSP builds produce a full `EBOOT.PBP`. The Aether engine handles the ELF -> PRX -> EBOOT pipeline.

### Build options

| Flag                     | Description                                                  |
|--------------------------|--------------------------------------------------------------|
| `-Dgfx=...`              | Override the graphics backend (default: auto from target).   |
| `-Dpsp-display=rgba8888` | PSP 32-bit display (default).                                |
| `-Dpsp-display=rgb565`   | PSP 16-bit display.                                          |
| `-Dslim=true`            | Slim memory profile for PSP-1000.                            |

CI builds Linux, macOS, Windows, and PSP on every change.

## Architecture

Four Zig modules, wired together in `build.zig`:

- `protocol` - generated at build time from `protocol.zb` by the ZeeBuffer compiler. Edit the schema, not the generated file.
- `common` (`src/common/`) - shared primitives: fixed-point math, noise, RNG, allocators (`counting_allocator`, `static_allocator`, `fa_buffer`), constants, protocol re-export. No graphics, no platform.
- `game` (`src/game/`) - shared gameplay and world logic used by both client and server (`world.zig`, `worldgen.zig`, `server.zig`, `client.zig`). Phase-specific behavior branches inside this module.
- Client (`src/client/main.zig`) - built via `Aether.addGame`. Subdirs cover `world/` (chunks, blocks, sky, particles, selection outline), `state/` (menu, load, game), `connection/` (real `ClientConn` and an in-process `FakeConn` for singleplayer), `player/`, `graphics/`, `ui/`, `shaders/`, and `util/`.
- Server (`src/server/main.zig`) - a plain executable on most targets; on PSP it goes through `Aether.addGame` to pick up `pspsdk` and the linker script.

The client always speaks the protocol. Singleplayer is just an in-process server behind a `FakeConn`, not a parallel code path.

Resource pack: `tools/pack_zip.zig` zips the `resources` dependency's `default/` directory into `pack.zip` at build time, installed next to the client binary.

## Contributing

Read `STYLE.MD` first. Run `zig fmt` before submitting. Add tests inline with `test "..."` blocks. When touching protocol, world, or rendering code, build the affected target plus `zig build test` before opening a PR.

A short summary of the style rules:

- snake_case for ordinary functions and variables; PascalCase for types, type-centric files, and module aliases (`Player.zig`, `GameState.zig`).
- Explicit-sized integer types; never `usize` / `isize` for domain values.
- Assertions on in release builds. Bound loops, size buffers so overflow is impossible.
- No recursion. Avoid `std.os` / `std.c` / `std.posix` outside narrow platform-boundary code.
- No runtime allocation on the server after init. Avoid unexpected hot-path allocation on the client.
- One responsibility per file. Functions stay readable (~70 lines as a soft ceiling).
- ASCII-only source. Comments explain why, not how.
- No external dependencies beyond the Zig standard library, the Aether / Iridescence ecosystem, and a small set of platform APIs (GLFW, miniaudio, OpenGL, pspsdk).

## Legal Notice

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT.**

CrossCraft is an independent, open-source project. It is not affiliated with, endorsed by, or sponsored by Mojang AB, Microsoft, Sony, Nintendo, or any other entity. Minecraft is a trademark of Mojang Synergies AB.

This project does not use or distribute any source code, textures, sounds, or other assets from Minecraft. All assets are original or third-party CC0 / CC-BY-SA licensed works, with attribution provided in `THIRD_PARTY_NOTICES.md`.

Network protocol compatibility is based on publicly available documentation and independent clean-room reverse engineering.

Console builds rely on existing homebrew environments. CrossCraft does not distribute or require any proprietary console firmware, BIOS, or copyrighted system software. Users are responsible for compliance with their local laws and device terms of service.

CrossCraft is provided "as-is" without warranty and is intended for educational and non-commercial purposes.

See `LICENSE` for the full LGPL-2.1 terms.
