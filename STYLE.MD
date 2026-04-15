# CrossCraft Style Guide

Inspired by [NASA's Power of Ten](https://spinroot.com/gerard/pdf/P10.pdf) and [TigerBeetle's Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)

## Scope

These rules are the strict baseline for `src/server` and shared simulation code in
`src/common` and `src/game`. The client follows the same spirit, but rendering,
audio, UI, and platform integration may allocate or block during setup, loading,
resource-pack changes, and other non-frame-critical paths.

For client code, hot paths are the important boundary: per-frame rendering,
input, chunk meshing, player movement, packet processing, and audio mixing should
avoid unbounded work, unexpected allocation, and platform-specific leakage.

* #### Assert maximally
	* Assertions must be enabled in Release (e.g. `ReleaseSafe`)
	* Assert all function arguments, return values, preconditions, postconditions, and invariants.
	* Pair Assertions, for every enforced property ensure that it is enforced before and after an operation (e.g. write to disk)
	* Use assertions as documentation
	* Use compile time assertions to ensure data layouts, type sizes, and subtle invariants are true at compilation time
	* Assert both the positive and negative space (what do we expect, and what do we not expect?)
* #### Use limits
	* Bound loops with maximum iterations or timeout mechanisms.
	* Size buffers such that they should never be possible to overflow, this means setting a maximum limit for some buffers.
		* Zig enforces buffer bounds, and will panic if attempted.
* #### Use Explicit Sized Types
	* Architecture-specific size `usize`/`isize` will eventually break your code.
* #### Avoid complex control flow
	* Do not use recursion.
		* Recursive code tends to be more complex to understand and optimize.
	* Zig disallows `goto`'s in favor of `defer` and `errdefer`.
* #### All Errors Must Be Handled
	* Handle all error cases, bubbling up errors is valid, but should be limited to the minimum necessary.
	* If an error cannot be handled, panic is a valid solution
* #### Don't Trust Defaults
	* Always explicitly set your defaults, in case a library changes its expected defaults, such that your code will always work
* #### No Dynamic Memory Allocation After Initialization
	* Heap allocation is slow and prone to errors, prefer static allocation when possible.
	* Server and shared game systems must not allocate after initialization.
	* Client code may allocate during startup, loading, resource-pack swaps, and other explicit setup phases. Client hot paths should reserve capacity ahead of time and avoid first-use growth where practical.
	* Use `defer` to manage automatic memory deallocation.
	* No runtime allocations results in easier to follow code, and more statically analyzable code
* #### Keep Functions Readable
	* Each function should have a clear purpose
	* Each function can be up to approximately 70 lines
* #### Keep Modules Focused
	* Each file should have a single, well-defined responsibility
	* If a function doesn't relate to the file's core purpose, it belongs elsewhere
	* Group related functionality - physics with physics, protocol with protocol
* #### Restrict Data Scope
	* Use global variables sparingly
	* Use the least number of variables in the scope to reduce the likelihood of misusing a variable.
* #### Check Return Values
	* Zig enforces checking return values, or explicitly discarding with `_ = x()`
* #### Avoid blocking operations
	* Server tick and packet processing code should not block.
	* Client loading, menu actions, and dedicated I/O tasks may block when the user-visible state already expects waiting.
	* If an operation is reliant on I/O, prefer non-blocking or bounded behavior where possible.
* #### Avoid external dependencies
	* This refers to dependencies external to CrossCraft
	* The only allowed dependencies are modules controlled by CrossCraft or Iridescence
        * Tooling is not considered to be a dependency (i.e. ZeeBuffers)
        * Runtime dependencies are not allowed beyond the Zig runtime and platform APIs (OpenGL, etc.)
  * Exceptions are made sparingly for platform APIs like GLFW, miniaudio
	* The only other dependencies should be the Zig compiler and sections of the Standard Library
	* Standard Library:
		* Allowed imports:
			* All `std.*` not explicitly disallowed
			* All software submodules built with this design ruleset.
			* Particularly encouraged: `std.mem`, `std.io`.
				These implementations are highly generic, and allow for overloading via static polymorphism or runtime VTables, so have no cross-platform concerns (dependency injection)
		* Disallowed:
			* `std.os`, `std.c`, and `std.posix` in portable gameplay, world, protocol, rendering, UI, and allocator code.
			* Platform boundary code may use these APIs when Aether does not provide the needed hook, such as server signal handling or socket shutdown. Keep these uses narrow and behind `builtin.os` branches.
* #### Design with performance in mind
	* Design is the easiest time to create a good, performant system
	* Optimize for the slowest resources (Network, Disk, Memory, GPU, CPU)
	* Perform sketches with respect to the resources and their characteristics (Bandwidth, Latency)
* #### Avoid Duplicating Variables
	* This may result in copies, which may not reflect state correctly
	* Do not rely on the compiler's inlining choices for copy elision
		* Instead, write `*const` to the data if the structure is greater than 16 bytes.
* #### Explain Why
	* Explain why a decision was made over another
	* Always reach to explain why something is done, rather than how it is done

## Code Style
* Use snake_case for ordinary functions and variables. The `_` is the closest you can get to a space and helps with understanding.
* Use PascalCase for type names, type-centric files, and imported module aliases, such as `Player`, `GameState`, `TextureAtlas`, and `ClientConn`.
* Use SCREAMING_SNAKE_CASE for compile-time constants and fixed limits, such as `MAX_PLAYERS` and `VERTS_PER_SPRITE`.
* Existing protocol names, external API names, generated identifiers, and compatibility-facing names may keep their source naming.
* Keep source text ASCII unless a non-ASCII character is required by data or an external format.
