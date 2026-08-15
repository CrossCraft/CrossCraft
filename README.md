<h1 align="center">CrossCraft</h1>
<p align="center">An open-source Minecraft implementation</p>

## What is CrossCraft?

CrossCraft is a monorepo containing clean-room Minecraft reimplementations written in Zig on top of the custom Aether engine. It is developed in phases, one era at a time.

We choose specific versions deemed important within an era:

* Classic (0.30)
* Survival Test (0.30)
* Indev (0.31)
* Infdev (TBD)
* Alpha (1.1.2 and 1.2.6)
* Beta (1.7.3 and 1.8.1)
* Official (1.0 - TBD)

## Where are we?

The current phase is **Classic (0.30)**, now at **v1.0**. Each completed phase stays in the tree as a first-class build. Shared code lives in shared modules; version-specific behavior lives behind branching code paths so that improvements made while developing a newer phase flow back into older ones automatically.

For example:
- General engine optimizations or new platforms are available to all versions
- Bug fixes in shared systems (worldgen, networking, rendering, etc.) propagate to all in-repo versions

## Classic Client & Server

Classic Client v1.0 is a feature-complete, clean-room reimplementation of Minecraft Classic 0.30.

- **Classic 0.30 protocol** - full client and server implementation, compatible with the public Classic protocol.
- **Singleplayer and multiplayer** - singleplayer runs an in-process server, no code bifurcation.
- **Desktop + PSP** - Linux, macOS, Windows, and PSP (32 & 64 MB) ship from the same tree.
- **Fixed-point worldgen and rendering** - deterministic across targets, fast on all hardware.
- **Zero post-init allocation on the server.** Minimal hot-path allocation on the client.
- **Full in-game settings UI** - options persist in a JSON file and are wired into every system.
- **Accessible UI** - controller & item tooltips available

Classic Server v1.1 is a feature-complete Minecraft Classic 0.30 server and can stand up to the open internet without immediately being cooked. 

**Administrative controls.** Durable IP-keyed policy in `access-control.json` tracks bans (with reasons), ops, and whitelist entries, so recent-player cache eviction can never weaken enforcement. `players.json` stores only bounded last-seen/username metadata and is flushed in batches. All operator actions are IP-keyed so a renamed account does not reset enforcement.

- `/ipop <username>` - grant op to the IP currently behind `<username>`.
- `/ipban <username> [reason]` - ban the IP currently behind `<username>`.
- `/kick <username> [reason]` - drop a connected player.
- `/ipwhitelist <ip>` - add an IP to the whitelist (whitelist mode toggled in `server.properties`).
- `max-players-saved` bounds only recent-player metadata. `max-policy-records` (default 4096) bounds durable policy at startup; policy entries are never evicted, and an attempted change fails clearly when full.

**Console mode.** The standalone server uses stdio as a real operator console: `stdin` accepts commands, `stdout` carries chat, `stderr` carries logs. Pipe each one separately if you want to.

**Persistence.** World saving is fully async. The default save format is now ClassicWorld; existing worlds migrate on first save. Save path and world seed are command-line arguments and `server.properties` keys. On macOS, client data is stored under `~/Library/Application Support/CrossCraft Classic/`, with worlds in `saves/`; on first launch, the bundled `saves/origins.cw` world is copied there if it is not already present.

## Status

| Component        | State       | Notes                                                       |
|------------------|-------------|-------------------------------------------------------------|
| Server (Classic) | v1.1        | Stable. Speaks the Classic 0.30 protocol.                  |
| Client (Classic) | v1.0        | Stable. Full singleplayer and multiplayer, desktop and PSP. |
| Engine (Aether)  | External dep | Powers rendering, audio, input, packing, platform ports.    |

## Roadmap

The near-term plan, in order:

1. **Classic v1.1** - next up. Client release built on top of the v1.1 server work. Includes 3DS, Nintendo Switch, and Web builds.
2. **Classic v1.2** - plugin support, world streaming, bigger worlds and better multiplayer connectivity features
2. **Survival Test** - the next phase. Shares the engine, common primitives, and most of the game module with Classic.

## Performance Notes

- Desktop: high frame rates at full view distance.
- PSP: 60-70 FPS in normal terrain, dipping into the mid-50s only in the densest forest. Achieved through aggressive section LODs, fixed-point worldgen and rendering, and careful meshing. The PSP build detects PSP-1000 vs PSP-2000+ at startup and selects the matching memory profile automatically.
- Server: zero allocations after init. Builds for Linux, macOS, and Windows.

## Building

A recent Zig (matching `build.zig.zon`'s `minimum_zig_version`) is required.

```
zig build game       # desktop client
zig build server     # standalone server
zig build run-game   # run client locally
zig build run-server # run server locally
zig build test       # unit tests
```

### Consoles

```
zig build game -Dtarget=mipsel-psp
zig build game -Dtarget=arm-3ds
zig build game -Dtarget=aarch64-freestanding -Dnintendo-switch
```

### Web

```
zig build serve-web
```

Opens on `localhost:8000`, needs WASM & WebGL2 support in browser.

## Contributing

Read `STYLE.MD` first. Run `zig fmt` before submitting. Add tests inline with `test "..."` blocks. When touching protocol, world, or rendering code, build the affected target plus `zig build test` before opening a PR.

## Legal Notice

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT.**

CrossCraft is an independent, open-source project. It is not affiliated with, endorsed by, or sponsored by Mojang AB, Microsoft, Sony, Nintendo, or any other entity. Minecraft is a trademark of Mojang Synergies AB.

This project does not use or distribute any source code, textures, sounds, or other assets from Minecraft. All assets are original or third-party CC0 / CC-BY-SA licensed works, with attribution provided in `THIRD_PARTY_NOTICES.md`.

Network protocol compatibility is based on publicly available documentation and independent clean-room reverse engineering.

Console builds rely on existing homebrew environments. CrossCraft does not distribute or require any proprietary console firmware, BIOS, or copyrighted system software. Users are responsible for compliance with their local laws and device terms of service.

CrossCraft is provided "as-is" without warranty and is intended for educational and non-commercial purposes.

See `LICENSE` for the full GPLv2 terms.
