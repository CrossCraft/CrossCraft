<h1 align="center">CrossCraft</h1>
<p align="center">An open-source Minecraft implementation</p>

## What is CrossCraft?

CrossCraft is a monorepo containing clean-room Minecraft reimplementations written in Zig on top of the custom Aether engine. It is developed in phases, one era at a time.

Every era stays within the same source tree, allowing code changes to benefit all versions. For example:
- General engine optimizations or new platforms are available to all versions
- Bug fixes in shared systems (worldgen, networking, rendering, etc.) propagate to all versions

## Current Status & Roadmap

#### Current Phase: Classic (0.30)

| Component | State  |
|-----------|--------|
| Client    | v1.1.2 |
| Server    | v1.1.0 |

#### Next Version: Classic v1.2

**Features:**
* Plugin Support
* Byte-Identical World Generator
* Bigger Worlds
* World Streaming
* Better Multiplayer in Client

#### Next Phase: Survival Test (0.30)

### Client

Classic Client v1.1 is a feature-complete, clean-room reimplementation of Minecraft Classic 0.30.

- **Singleplayer and multiplayer** - full client and server support for Classic 0.30
- **Cross-platform** - Linux, macOS, Windows, PSP, 3DS, Switch and Web
- **Cross-compatbile** - Supports ClassicWorld format for broader ecosystem, base protocol compatible with ClassiCube & others
- **Full in-game settings UI** - Persistent options and control remapping
- **Accessible UI** - Controller & Item tooltips available

### Server

Classic Server v1.1 is a feature-complete Minecraft Classic 0.30 server with basic server administration. 

- **Administrative controls** - A persistent IP-keyed player stat tracker allowing OPs, Bans, etc.
- **Console mode** - The server runs as a regular console application on Windows, macOS, and Linux.
- **Tiny footprint** - Creates a fixed 32 MB pool and uses around 6 MB, never grows or OOMs after startup.
- **Configurable** - `server.properties` keys allows granular control over server internals.

## Building

Requirement: Zig (matching `build.zig.zon`'s `minimum_zig_version`)

```
# General
zig build game       # desktop client
zig build server     # standalone server
zig build run-game   # run client locally
zig build run-server # run server locally
zig build test       # unit tests

# Consoles
zig build game -Dtarget=mipsel-psp
zig build game -Dtarget=arm-3ds
zig build game -Dtarget=aarch64-freestanding -Dnintendo-switch

# Web
zig build serve-web
```

## Contributing

Read `STYLE.MD` first. Run `zig fmt` before submitting. Run `zig build test` before opening a PR.

### Architecture and target capabilities

- `src/core` owns shared game logic, world generation, physics, protocol, and saves.
- `src/client` provides the playable game, rendering, input, and UI.
- `src/server` provides the PC-only standalone server and administration.

[`src/capabilities.zig`](src/capabilities.zig) is the single place for target identity checks. Callers ask for behavior or limits, such as `execution.background_workers`, `filesystem.rename_replaces_destination`, or `controls.single_stick`. Add new target decisions there instead of checking `builtin`, `ae.platform`, or the graphics backend at the call site.

Core and host tools import the std-only `capabilities` module. Client code uses `@import("capabilities").ClientType(ae)` for engine-dependent policy and system hooks. `client/config.zig` selects the runtime memory profile before allocation and applies its budgets; PSP model detection and Old/New 3DS control support remain runtime decisions. Build packaging uses `build_policy` with the requested target rather than the build runner's target.

Run `zig build test-capabilities` to verify target capability policy. These tests also run under `zig build test`.

`tiger_lint.json` bans direct target checks and excludes `src/capabilities.zig` from linting.

## Legal Notice

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT.**

CrossCraft is an independent, open-source project. It is not affiliated with, endorsed by, or sponsored by Mojang AB, Microsoft, Sony, Nintendo, or any other entity. Minecraft is a trademark of Mojang Synergies AB.

This project does not use or distribute any source code, textures, sounds, or other assets from Minecraft. All assets are original or third-party CC0 / CC-BY-SA licensed works, with attribution provided in `THIRD_PARTY_NOTICES.md`.

Network protocol compatibility is based on publicly available documentation and independent clean-room reverse engineering.

Console builds rely on existing homebrew environments. CrossCraft does not distribute or require any proprietary console firmware, BIOS, or copyrighted system software. Users are responsible for compliance with their local laws and device terms of service.

CrossCraft is provided "as-is" without warranty and is intended for educational and non-commercial purposes.

See `LICENSE` for the full GPLv2 terms.
