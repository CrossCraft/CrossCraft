//! Exclusive minigame sessions. A player belongs to at most one active
//! session server-wide. Each session records member roles and return
//! destinations; the host owns cleanup so ending or failing a session removes
//! membership, travel restrictions, and returns connected members safely
//! without relying on script cleanup.
const std = @import("std");
const Server = @import("core").Server;
const Plugins = @import("Plugins.zig");

const assert = std.debug.assert;

pub const max_sessions = 4;
pub const max_members = 16;

pub const ReturnSpot = struct {
    x: u16 = 0,
    y: u16 = 0,
    z: u16 = 0,
    yaw: u8 = 0,
    pitch: u8 = 0,
    valid: bool = false,
};

pub const Member = struct {
    handle: Server.PlayerHandle,
    role_buf: [12]u8 = @splat(0),
    role_len: u8 = 0,
    return_spot: ReturnSpot = .{},

    pub fn role(self: *const Member) []const u8 {
        return self.role_buf[0..self.role_len];
    }
};

pub const Session = struct {
    owner: *Plugins.Plugin,
    capacity: usize,
    travel_locked: bool = false,
    active: bool = false,
    generation: u32 = 0,
    members: [max_members]Member = undefined,
    member_count: usize = 0,

    pub fn find_member(self: *Session, handle: Server.PlayerHandle) ?*Member {
        for (self.members[0..self.member_count]) |*member| {
            if (member.handle.id == handle.id and member.handle.generation == handle.generation) return member;
        }
        return null;
    }

    pub fn admit(self: *Session, handle: Server.PlayerHandle, return_spot: ReturnSpot, role: []const u8) bool {
        if (self.member_count >= self.capacity or self.member_count >= max_members) return false;
        if (self.find_member(handle) != null) return false;
        assert(self.member_count < max_members);
        const member = &self.members[self.member_count];
        member.* = .{ .handle = handle, .return_spot = return_spot };
        const len = @min(role.len, member.role_buf.len);
        @memcpy(member.role_buf[0..len], role[0..len]);
        member.role_len = @intCast(len);
        self.member_count += 1;
        return true;
    }

    pub fn remove(self: *Session, handle: Server.PlayerHandle) bool {
        for (self.members[0..self.member_count], 0..) |*member, i| {
            if (member.handle.id != handle.id or member.handle.generation != handle.generation) continue;
            assert(self.member_count > 0);
            self.members[i] = self.members[self.member_count - 1];
            self.member_count -= 1;
            return true;
        }
        return false;
    }

    pub fn contains(self: *Session, handle: Server.PlayerHandle) bool {
        return self.find_member(handle) != null;
    }

    /// End the session: deactivate membership and travel restrictions, and
    /// return connected members to their captured destinations.
    pub fn end(self: *Session, fallback: ReturnSpot, teleport_members: bool) void {
        assert(self.active);
        for (self.members[0..self.member_count]) |member| {
            if (!teleport_members) continue;
            const spot = member.return_spot;
            if (Server.teleport_handle_block(member.handle, spot.x, spot.y, spot.z, spot.yaw, spot.pitch)) |_| {
                continue;
            } else |_| {
                if (fallback.valid) {
                    Server.teleport_handle_block(member.handle, fallback.x, fallback.y, fallback.z, fallback.yaw, fallback.pitch) catch {};
                }
            }
        }
        self.member_count = 0;
        self.travel_locked = false;
        self.active = false;
    }
};

pub const Registry = struct {
    sessions: [max_sessions]Session = undefined,
    count: usize = 0,
    next_generation: u32 = 1,

    pub fn create(self: *Registry, owner: *Plugins.Plugin, capacity: usize) ?*Session {
        assert(self.count <= max_sessions);
        const slot: *Session = for (self.sessions[0..self.count]) |*session| {
            if (!session.active) break session;
        } else blk: {
            if (self.count == max_sessions) return null;
            self.count += 1;
            break :blk &self.sessions[self.count - 1];
        };
        const generation = self.next_generation;
        self.next_generation += 1;
        slot.* = .{ .owner = owner, .capacity = @min(@max(capacity, 1), max_members), .active = true, .generation = generation };
        return slot;
    }

    /// Admit through the registry so exclusive membership is host-owned: a
    /// player in any active session cannot join another.
    pub fn admit(self: *Registry, session: *Session, handle: Server.PlayerHandle, return_spot: ReturnSpot, role: []const u8) bool {
        if (self.find_present(handle) != null) return false;
        return session.admit(handle, return_spot, role);
    }

    /// The session currently holding this player, for exclusive membership.
    pub fn find_present(self: *Registry, handle: Server.PlayerHandle) ?*Session {
        for (self.sessions[0..self.count]) |*session| {
            if (session.active and session.contains(handle)) return session;
        }
        return null;
    }

    pub fn plugin_contains(self: *Registry, owner: *Plugins.Plugin, handle: Server.PlayerHandle) bool {
        for (self.sessions[0..self.count]) |*session| {
            if (session.active and session.owner == owner and session.contains(handle)) return true;
        }
        return false;
    }

    pub fn travel_locked_for(self: *Registry, handle: Server.PlayerHandle) bool {
        for (self.sessions[0..self.count]) |*session| {
            if (session.active and session.travel_locked and session.contains(handle)) return true;
        }
        return false;
    }

    /// Remove a departed player from every session (host-owned cleanup).
    pub fn purge_player(self: *Registry, handle: Server.PlayerHandle) void {
        for (self.sessions[0..self.count]) |*session| {
            if (session.active) _ = session.remove(handle);
        }
    }

    pub fn end_for_owner(self: *Registry, owner: *Plugins.Plugin, fallback: ReturnSpot, teleport_members: bool) void {
        for (self.sessions[0..self.count]) |*session| {
            if (session.active and session.owner == owner) session.end(fallback, teleport_members);
        }
    }
};
