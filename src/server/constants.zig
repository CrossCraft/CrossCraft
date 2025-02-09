const std = @import("std");

pub const MajorVersion: u8 = 0;
pub const MinorVersion: u8 = 1;
pub const PatchVersion: u8 = 0;

/// X length
pub const WorldLength: usize = 256;
/// Z length
pub const WorldDepth: usize = 256;
/// Y length
pub const WorldHeight: usize = 64;

/// 50 MS per tick
pub const TickSpeedNS: usize = std.time.ns_per_ms * 50;

/// Number of Max Clients
pub const MaxClients: usize = 128;
