# Classic world generation

This core module generates the same deterministic block buffer for the playable client and the dedicated server. `root.zig` is the public entry point; `level.zig` owns the pipeline, while terrain, carving, ore, noise, and Java-compatible randomness are kept in focused modules.

Generation is byte-accurate and tuned for constrained targets, especially PSP. Preserve floating-point operation order and random draw order when changing it.

Run `zig build test` for focused behavior checks and `zig build worldgen-test -Doptimize=ReleaseSafe` for the 100-case golden-hash corpus.

## Provenance

This module is CrossCraft's own reverse-engineered, byte-accurate implementation of the Minecraft Classic world generation algorithm. It is not derived from ClassiCube source code or wiki materials and requires no third-party attribution; see the root `THIRD_PARTY_NOTICES.md` for the notices that apply to other parts of the project.
