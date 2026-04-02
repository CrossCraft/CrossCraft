const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;
const Vertex = @import("../../graphics/Vertex.zig").Vertex;

/// Bump-allocator vertex pool shared across all chunk section meshes.
/// Allocates exact sizes -- no wasted space for empty/sparse sections.
/// Call `reset()` before rebuilding all sections, then `alloc()` per mesh.
pub const MeshPool = struct {
    slab: []Vertex,
    bump: u32,

    pub fn init(total_verts: u32) !MeshPool {
        const slab = try Util.allocator(.render).alloc(Vertex, total_verts);
        return .{ .slab = slab, .bump = 0 };
    }

    pub fn deinit(self: *MeshPool) void {
        Util.allocator(.render).free(self.slab);
    }

    /// Reset bump pointer. Call before a full rebuild pass.
    pub fn reset(self: *MeshPool) void {
        self.bump = 0;
    }

    /// Align each sub-allocation to a cache-line boundary (64 bytes).
    /// On PSP, the GE reads via DMA which requires cache-line alignment.
    const CACHE_LINE: u32 = 64;
    const VERT_SIZE: u32 = @sizeOf(Vertex);
    /// Vertices per cache line (64 / 16 = 4).
    const ALIGN_VERTS: u32 = (CACHE_LINE + VERT_SIZE - 1) / VERT_SIZE;

    /// Claim `n` vertices, aligned to cache-line boundary. Returns base pointer or null if full.
    pub fn alloc(self: *MeshPool, n: u32) ?[*]Vertex {
        if (n == 0) return self.slab.ptr;
        // Align bump up to cache-line boundary (in vertex units)
        const aligned_bump = (self.bump + ALIGN_VERTS - 1) / ALIGN_VERTS * ALIGN_VERTS;
        if (aligned_bump + n > self.slab.len) return null;
        const base = self.slab[aligned_bump..].ptr;
        self.bump = aligned_bump + n;
        return base;
    }

    pub fn used(self: *const MeshPool) u32 {
        return self.bump;
    }

    pub fn capacity(self: *const MeshPool) u32 {
        return @intCast(self.slab.len);
    }
};
