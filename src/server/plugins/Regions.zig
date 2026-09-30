//! Axis-aligned region claims owned by plugins. Claims from different plugins
//! never overlap; a plugin may nest or overlap its own claims. The host uses
//! claims for edit authorization and simulation containment. Handles carry a
//! generation so a script cannot act through a stale claim slot.
const std = @import("std");
const Plugins = @import("Plugins.zig");

const assert = std.debug.assert;

pub const max_regions = 16;

pub const Box = struct {
    x0: u16,
    y0: u16,
    z0: u16,
    x1: u16,
    y1: u16,
    z1: u16,

    pub fn volume(self: Box) u32 {
        const w: u32 = @as(u32, self.x1) - self.x0 + 1;
        const d: u32 = @as(u32, self.z1) - self.z0 + 1;
        const h: u32 = @as(u32, self.y1) - self.y0 + 1;
        return w * h * d;
    }

    pub fn contains(self: Box, x: u16, y: u16, z: u16) bool {
        return x >= self.x0 and x <= self.x1 and y >= self.y0 and y <= self.y1 and z >= self.z0 and z <= self.z1;
    }

    pub fn overlaps(self: Box, other: Box) bool {
        return self.x0 <= other.x1 and self.x1 >= other.x0 and
            self.y0 <= other.y1 and self.y1 >= other.y0 and
            self.z0 <= other.z1 and self.z1 >= other.z0;
    }
};

pub const Region = struct {
    owner: *Plugins.Plugin,
    box: Box,
    frozen: bool,
    active: bool = false,
    generation: u32 = 0,

    pub fn release(self: *Region) void {
        self.active = false;
    }
};

pub const Registry = struct {
    regions: [max_regions]Region = undefined,
    count: usize = 0,
    next_generation: u32 = 1,

    /// Claim a box, rejecting overlaps with other plugins' active claims.
    /// Returns null on conflict or exhaustion.
    pub fn claim(self: *Registry, owner: *Plugins.Plugin, box: Box, frozen: bool) ?*Region {
        assert(self.count <= max_regions);
        for (self.regions[0..self.count]) |region| {
            if (!region.active or region.owner == owner) continue;
            if (region.box.overlaps(box)) return null;
        }
        const slot: *Region = for (self.regions[0..self.count]) |*region| {
            if (!region.active) break region;
        } else blk: {
            if (self.count == max_regions) return null;
            self.count += 1;
            break :blk &self.regions[self.count - 1];
        };
        const generation = self.next_generation;
        self.next_generation += 1;
        slot.* = .{ .owner = owner, .box = box, .frozen = frozen, .active = true, .generation = generation };
        return slot;
    }

    pub fn release_owner(self: *Registry, owner: *Plugins.Plugin) void {
        for (self.regions[0..self.count]) |*region| {
            if (region.active and region.owner == owner) region.active = false;
        }
    }

    pub fn find(self: *Registry, x: u16, y: u16, z: u16) ?*Region {
        for (self.regions[0..self.count]) |*region| {
            if (region.active and region.box.contains(x, y, z)) return region;
        }
        return null;
    }
};
