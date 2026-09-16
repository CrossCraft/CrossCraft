//! Plugin manifest discovery and validation. Every installed manifest is
//! validated before any script executes.
const std = @import("std");
const Server = @import("core").Server;

const log = std.log.scoped(.plugins);

pub const api_version_major: u32 = 1;
pub const api_version_minor: u32 = 0;

pub const Dependency = struct {
    uuid: Uuid,
    version: Range = .{ .any = {} },
    optional: bool = false,
};

pub const Manifest = struct {
    uuid: Uuid,
    name_buf: [64]u8 = @splat(0),
    name_len: u8 = 0,
    version: SemVer,
    entrypoint_buf: [128]u8 = @splat(0),
    entrypoint_len: u8 = 0,
    dependencies_buf: [8]Dependency = undefined,
    dependency_count: u8 = 0,
    capabilities_buf: [16]Capability = undefined,
    capability_count: u8 = 0,

    pub fn name(self: *const Manifest) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn entrypoint(self: *const Manifest) []const u8 {
        return self.entrypoint_buf[0..self.entrypoint_len];
    }

    pub fn dependencies(self: *const Manifest) []const Dependency {
        return self.dependencies_buf[0..self.dependency_count];
    }

    pub fn capabilities(self: *const Manifest) []const Capability {
        return self.capabilities_buf[0..self.capability_count];
    }

    pub fn has_capability(self: *const Manifest, capability: Capability) bool {
        for (self.capabilities()) |c| {
            if (c == capability) return true;
        }
        return false;
    }
};

pub const Capability = enum {
    @"player.lookup",
    @"player.message",
    @"player.teleport",
    @"player.spawn",
    @"player.kick",
    @"player.ban",
    @"world.edit",

    pub fn parse(text: []const u8) ?Capability {
        inline for (@typeInfo(Capability).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, text)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const SemVer = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(text: []const u8) ?SemVer {
        var parts: [3]u32 = .{ 0, 0, 0 };
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, text, '.');
        while (it.next()) |part| {
            if (count == 3) return null;
            if (part.len == 0 or part.len > 6) return null;
            for (part) |c| {
                if (!std.ascii.isDigit(c)) return null;
            }
            parts[count] = std.fmt.parseInt(u32, part, 10) catch return null;
            count += 1;
        }
        if (count == 0 or count > 3) return null;
        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    pub fn order(self: SemVer, other: SemVer) std.math.Order {
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        return std.math.order(self.patch, other.patch);
    }
};

/// Supported range grammar: "1.0" (exact), "1.x" (same major), ">=1.0"
/// (minimum). An empty field matches any version.
pub const Range = union(enum) {
    any: void,
    exact: SemVer,
    wildcard_major: u32,
    minimum: SemVer,

    pub fn parse(text: []const u8) ?Range {
        if (text.len == 0) return .{ .any = {} };
        if (std.mem.startsWith(u8, text, ">=")) {
            const version = SemVer.parse(text[2..]) orelse return null;
            return .{ .minimum = version };
        }
        if (std.mem.endsWith(u8, text, ".x")) {
            const major_text = text[0 .. text.len - 2];
            if (major_text.len == 0 or major_text.len > 6) return null;
            for (major_text) |c| {
                if (!std.ascii.isDigit(c)) return null;
            }
            const major = std.fmt.parseInt(u32, major_text, 10) catch return null;
            return .{ .wildcard_major = major };
        }
        const version = SemVer.parse(text) orelse return null;
        return .{ .exact = version };
    }

    pub fn matches(self: Range, version: SemVer) bool {
        return switch (self) {
            .any => true,
            .exact => |v| version.order(v) == .eq,
            .wildcard_major => |major| version.major == major,
            .minimum => |v| version.order(v) != .lt,
        };
    }

    pub fn describe(self: Range, buf: *[24]u8) []const u8 {
        return switch (self) {
            .any => "*",
            .exact => |v| std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch "?",
            .wildcard_major => |major| std.fmt.bufPrint(buf, "{d}.x", .{major}) catch "?",
            .minimum => |v| std.fmt.bufPrint(buf, ">={d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch "?",
        };
    }
};

pub const Uuid = struct {
    bytes: [16]u8,

    pub fn parse(text: []const u8) ?Uuid {
        if (text.len != 36) return null;
        var bytes: [16]u8 = undefined;
        var index: usize = 0;
        for (text, 0..) |c, i| {
            switch (i) {
                8, 13, 18, 23 => if (c != '-') return null,
                else => {
                    const value = std.fmt.charToDigit(c, 16) catch return null;
                    if (index % 2 == 0) {
                        bytes[index / 2] = @intCast(value << 4);
                    } else {
                        bytes[index / 2] |= @intCast(value);
                    }
                    index += 1;
                },
            }
        }
        if (index != 32) return null;
        return .{ .bytes = bytes };
    }

    pub fn eql(self: Uuid, other: Uuid) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Canonical lowercase 8-4-4-4-12 rendering.
    pub fn format(self: Uuid, buf: *[36]u8) []const u8 {
        const hex = "0123456789abcdef";
        var out_index: usize = 0;
        for (self.bytes, 0..) |byte, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[out_index] = '-';
                out_index += 1;
            }
            buf[out_index] = hex[byte >> 4];
            buf[out_index + 1] = hex[byte & 0xf];
            out_index += 2;
        }
        return buf[0..36];
    }
};

const ParsedDependency = struct {
    uuid: []const u8 = "",
    version: []const u8 = "",
    optional: bool = false,
};

const ParsedManifest = struct {
    uuid: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "",
    author: []const u8 = "",
    api_version: []const u8 = "",
    entrypoint: []const u8 = "",
    dependencies: []ParsedDependency = &.{},
    capabilities: []const []const u8 = &.{},
};

/// Entry points must stay inside the package: no absolute paths, no `..`,
/// no backslashes or drive letters.
pub fn entrypoint_is_safe(path: []const u8) bool {
    if (path.len == 0 or path.len > 128) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".")) return false;
    }
    return true;
}

pub const LoadError = error{
    InvalidManifest,
    DuplicateUuid,
    OutOfMemory,
};

/// Parse and validate one manifest from raw JSON text.
pub fn parse(text: []const u8, alloc: std.mem.Allocator) LoadError!Manifest {
    const parsed = std.json.parseFromSlice(ParsedManifest, alloc, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    defer parsed.deinit();

    return from_parsed(parsed.value) orelse error.InvalidManifest;
}

fn from_parsed(parsed: ParsedManifest) ?Manifest {
    var manifest = Manifest{
        .uuid = Uuid.parse(parsed.uuid) orelse return null,
        .version = SemVer.parse(parsed.version) orelse return null,
    };

    if (parsed.name.len == 0 or parsed.name.len > manifest.name_buf.len) return null;
    @memcpy(manifest.name_buf[0..parsed.name.len], parsed.name);
    manifest.name_len = @intCast(parsed.name.len);

    // The host API version must be inside the plugin's compatibility range.
    const range = Range.parse(parsed.api_version) orelse return null;
    const host: SemVer = .{ .major = api_version_major, .minor = api_version_minor, .patch = 0 };
    if (!range.matches(host)) return null;

    if (!entrypoint_is_safe(parsed.entrypoint)) return null;
    @memcpy(manifest.entrypoint_buf[0..parsed.entrypoint.len], parsed.entrypoint);
    manifest.entrypoint_len = @intCast(parsed.entrypoint.len);

    if (parsed.dependencies.len > manifest.dependencies_buf.len) return null;
    for (parsed.dependencies) |dep| {
        const uuid = Uuid.parse(dep.uuid) orelse return null;
        const version = Range.parse(dep.version) orelse return null;
        manifest.dependencies_buf[manifest.dependency_count] = .{
            .uuid = uuid,
            .version = version,
            .optional = dep.optional,
        };
        manifest.dependency_count += 1;
    }

    if (parsed.capabilities.len > manifest.capabilities_buf.len) return null;
    for (parsed.capabilities) |capability_text| {
        const capability = Capability.parse(capability_text) orelse return null;
        manifest.capabilities_buf[manifest.capability_count] = capability;
        manifest.capability_count += 1;
    }

    return manifest;
}

/// Read `plugins/<dir>/manifest.json` into a scratch buffer and parse it.
pub fn load_from(data_dir: std.Io.Dir, dir_name: []const u8, alloc: std.mem.Allocator, scratch: []u8) ?Manifest {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "plugins/{s}/manifest.json", .{dir_name}) catch return null;
    const file = data_dir.openFile(Server.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.warn("Plugin '{s}' has no manifest.json", .{dir_name});
            return null;
        },
        else => {
            log.warn("Plugin '{s}' manifest is unreadable: {}", .{ dir_name, err });
            return null;
        },
    };
    defer file.close(Server.io);

    const len = file.readPositionalAll(Server.io, scratch, 0) catch return null;
    return parse(scratch[0..len], alloc) catch |err| switch (err) {
        error.OutOfMemory => {
            log.warn("Plugin '{s}' manifest is too large", .{dir_name});
            return null;
        },
        error.InvalidManifest, error.DuplicateUuid => {
            log.warn("Plugin '{s}' manifest is invalid", .{dir_name});
            return null;
        },
    };
}
