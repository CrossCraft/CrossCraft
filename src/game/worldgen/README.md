# Classic-Worldgen Fast

This is a variant of the Classic-Worldgen finely tuned and optimized for PSP and general case to be faster. The code was iterated via LLM loop and is non-trivial. Many of the techniques are worth studying but this code is not intended to be touched regularly. Unlike the prior worldgen which has negligible performance difference, worldgen is *SIGNIFICANTLY* faster on `ReleaseFast`

After touching it would be necessary to rerun the fuzzer to check 100% byte accuracy. Existing unit tests get general accuracy.

## Provenance

This module is CrossCraft's own reverse-engineered, byte-accurate implementation of the Minecraft Classic world generation algorithm. It is not derived from ClassiCube source code or wiki materials and requires no third-party attribution; see the root `THIRD_PARTY_NOTICES.md` for the notices that apply to other parts of the project.
