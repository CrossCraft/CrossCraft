const std = @import("std");
const builtin = @import("builtin");

const is_psp = builtin.os.tag == .psp;

/// Allegrex D-cache and most desktop CPUs use 64-byte cache lines.
const cache_line: u32 = 64;

/// Prefetch every cache line covering `slice` into the data cache.
///
/// PSP: issues `lw $0, 0(addr)` per line. The MIPS zero register discards
/// the loaded word, so the side effect is just the cache fill - no
/// register pressure, no pipeline stall waiting for the value. Allegrex
/// has no dedicated `pref` opcode in user mode, so this is the cheapest
/// portable warm-up.
///
/// Other targets: emits LLVM `@prefetch` hints, one per line, marked as
/// read+data with maximum locality so the line stays resident through
/// the immediate consumer.
pub inline fn prefetch_slice(comptime T: type, slice: []const T) void {
    if (slice.len == 0) return;
    const len_bytes: u32 = @intCast(slice.len * @sizeOf(T));
    const base: [*]const u8 = @ptrCast(slice.ptr);

    var off: u32 = 0;
    while (off < len_bytes) : (off += cache_line) {
        const addr = base + off;
        if (comptime is_psp) {
            asm volatile (
                \\ lw $0, 0(%[addr])
                :
                : [addr] "r" (addr),
                : .{ .memory = true });
        } else {
            @prefetch(addr, .{ .rw = .read, .locality = 3, .cache = .data });
        }
    }
}
