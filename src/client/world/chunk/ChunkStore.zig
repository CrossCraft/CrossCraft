const std = @import("std");
const Chunk = @import("Chunk.zig");
const limits = @import("ChunkCoord.zig");
const ChunkCoord = limits.ChunkCoord;

pub const SlotIndex = u16;
pub const NO_SLOT: SlotIndex = std.math.maxInt(SlotIndex);

/// One resident slot: generation, chunk, and queue linkage (the chunk
/// carries queue_index). Inactive slots are free-list entries; their chunk
/// storage is undefined until ensure() makes a coordinate resident.
pub const Slot = struct {
    generation: u32,
    active: bool,
    chunk: Chunk,
};

/// Fixed-capacity store of resident chunks. All storage is allocated at
/// renderer initialization, so making a chunk resident afterwards is
/// allocation-free. The coordinate table covers the full 8,192-entry
/// design-limit index space but holds small slot indices, not mesh bundles.
slots: []Slot,
free_stack: []SlotIndex,
free_count: u32,
coord_to_slot: [limits.MAX_CHUNK_COUNT]SlotIndex,
active_count: u32,
allocator: std.mem.Allocator,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, slot_capacity: u32) !Self {
    std.debug.assert(slot_capacity > 0 and slot_capacity <= limits.MAX_CHUNK_COUNT);
    const slots = try allocator.alloc(Slot, slot_capacity);
    errdefer allocator.free(slots);
    for (slots) |*slot| {
        slot.* = .{ .generation = 0, .active = false, .chunk = undefined };
    }
    const free_stack = try allocator.alloc(SlotIndex, slot_capacity);
    for (free_stack, 0..) |*entry, i| entry.* = @intCast(i);
    return .{
        .slots = slots,
        .free_stack = free_stack,
        .free_count = @intCast(slot_capacity),
        .coord_to_slot = .{NO_SLOT} ** limits.MAX_CHUNK_COUNT,
        .active_count = 0,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    for (self.slots) |*slot| {
        if (slot.active) slot.chunk.release_meshes(self.allocator);
    }
    self.allocator.free(self.free_stack);
    self.allocator.free(self.slots);
}

pub fn capacity(self: *const Self) u32 {
    return @intCast(self.slots.len);
}

/// Slot for a resident coordinate, or null when the chunk is not resident.
pub fn lookup(self: *const Self, coord: ChunkCoord) ?SlotIndex {
    const slot = self.coord_to_slot[coord.index()];
    return if (slot == NO_SLOT) null else slot;
}

pub fn chunk(self: *Self, slot: SlotIndex) *Chunk {
    std.debug.assert(slot < self.slots.len);
    std.debug.assert(self.slots[slot].active);
    return &self.slots[slot].chunk;
}

pub fn generation(self: *const Self, slot: SlotIndex) u32 {
    std.debug.assert(slot < self.slots.len);
    return self.slots[slot].generation;
}

/// A {slot, generation} claim is valid only while the slot still holds the
/// same generation; retirement increments it so stale claims are rejected
/// without dereferencing a different chunk.
pub fn validate(self: *const Self, slot: SlotIndex, gen: u32) bool {
    if (slot >= self.slots.len) return false;
    const s = &self.slots[slot];
    return s.active and s.generation == gen;
}

/// Make a coordinate resident with a fresh metadata-only chunk. Returns
/// null when the store is full; one failed coordinate never disturbs any
/// other resident chunk.
pub fn ensure(self: *Self, coord: ChunkCoord) ?SlotIndex {
    if (self.lookup(coord)) |slot| return slot;
    if (self.free_count == 0) return null;
    self.free_count -= 1;
    const slot = self.free_stack[self.free_count];
    const s = &self.slots[slot];
    std.debug.assert(!s.active);
    s.active = true;
    s.chunk = Chunk.init(coord);
    self.coord_to_slot[coord.index()] = slot;
    self.active_count += 1;
    return slot;
}

/// Retire a resident chunk: release mesh resources, detach the coordinate,
/// and bump the generation so queued or claimed work for the old residency
/// is rejected. The caller must have cancelled queue membership first.
pub fn retire(self: *Self, slot: SlotIndex) void {
    std.debug.assert(slot < self.slots.len);
    const s = &self.slots[slot];
    std.debug.assert(s.active);
    std.debug.assert(s.chunk.queue_index == null);
    s.chunk.release_meshes(self.allocator);
    self.coord_to_slot[s.chunk.coord.index()] = NO_SLOT;
    s.generation +%= 1;
    s.active = false;
    self.free_stack[self.free_count] = slot;
    self.free_count += 1;
    self.active_count -= 1;
}

test "chunks enter and leave independently" {
    var store = try Self.init(std.testing.allocator, 8);
    defer store.deinit();

    // One X/Z column of four Y chunks, plus a stray.
    var slots: [5]SlotIndex = undefined;
    for (0..4) |y| {
        slots[y] = store.ensure(ChunkCoord.init(2, @intCast(y), 3)).?;
    }
    slots[4] = store.ensure(ChunkCoord.init(5, 0, 5)).?;
    try std.testing.expectEqual(@as(u32, 5), store.active_count);

    // Retiring one Y chunk leaves its vertical neighbors resident.
    store.retire(slots[1]);
    try std.testing.expectEqual(@as(?SlotIndex, null), store.lookup(ChunkCoord.init(2, 1, 3)));
    try std.testing.expect(store.lookup(ChunkCoord.init(2, 0, 3)) != null);
    try std.testing.expect(store.lookup(ChunkCoord.init(2, 2, 3)) != null);
    try std.testing.expect(store.lookup(ChunkCoord.init(2, 3, 3)) != null);
    try std.testing.expect(store.lookup(ChunkCoord.init(5, 0, 5)) != null);
    try std.testing.expectEqual(@as(u32, 4), store.active_count);
}

test "capacity is bounded and ensure never fails neighbors" {
    var store = try Self.init(std.testing.allocator, 2);
    defer store.deinit();

    const a = store.ensure(ChunkCoord.init(0, 0, 0)).?;
    const b = store.ensure(ChunkCoord.init(1, 0, 0)).?;
    // Full: a third coordinate cannot become resident, but the first two
    // are untouched (no rollback of any neighbor).
    try std.testing.expectEqual(@as(?SlotIndex, null), store.ensure(ChunkCoord.init(2, 0, 0)));
    try std.testing.expectEqual(a, store.lookup(ChunkCoord.init(0, 0, 0)).?);
    try std.testing.expectEqual(b, store.lookup(ChunkCoord.init(1, 0, 0)).?);

    // ensure on an already-resident coordinate is idempotent.
    try std.testing.expectEqual(a, store.ensure(ChunkCoord.init(0, 0, 0)).?);
}

test "slot generation invalidates stale claims on reuse" {
    var store = try Self.init(std.testing.allocator, 2);
    defer store.deinit();

    const slot = store.ensure(ChunkCoord.init(0, 0, 0)).?;
    const gen0 = store.generation(slot);
    try std.testing.expect(store.validate(slot, gen0));

    store.retire(slot);
    try std.testing.expect(!store.validate(slot, gen0));

    // The freed slot is reused for a different coordinate; the old
    // generation still does not validate against it.
    const reused = store.ensure(ChunkCoord.init(7, 1, 9)).?;
    try std.testing.expectEqual(slot, reused);
    try std.testing.expect(!store.validate(reused, gen0));
    try std.testing.expect(store.validate(reused, store.generation(reused)));
}

test "coord_to_slot covers the design-limit index space" {
    var store = try Self.init(std.testing.allocator, 1);
    defer store.deinit();
    const far = ChunkCoord.init(31, 7, 31);
    try std.testing.expectEqual(@as(?SlotIndex, null), store.lookup(far));
    const slot = store.ensure(far).?;
    try std.testing.expectEqual(slot, store.lookup(far).?);
    store.retire(slot);
    try std.testing.expectEqual(@as(?SlotIndex, null), store.lookup(far));
}
