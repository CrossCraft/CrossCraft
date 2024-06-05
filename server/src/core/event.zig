const std = @import("std");
const assert = std.debug.assert;

/// Unique ID for each event
pub const EventStamp = struct {
    var event_counter: u64 = 0;
    pub fn get_event_id_stamp() u64 {
        event_counter += 1;
        return event_counter;
    }
};

pub const Event = struct {
    // ID of the event when it was created
    // This is used to determine the order of events
    // This is in the same order as the events are created
    id_stamp: u64,

    data: EventData,

    pub const EventData = union(enum) {
        PlayerMove: struct {
            id: u8,
            x: u16,
            y: u16,
            z: u16,
            pitch: u8,
            yaw: u8,
        },
        SetBlock: struct {
            pub const Mode = enum(u8) {
                Break = 0x0,
                Place = 0x1,
            };

            x: u16,
            y: u16,
            z: u16,
            mode: Mode,
            block_id: u8,
        },
        ChatMessage: struct {
            id: u8,
            message: [64]u8,
        },
        SpawnPlayer: struct {
            id: u8,
            name: [64]u8,
            x: u16,
            y: u16,
            z: u16,
            pitch: u8,
            yaw: u8,
        },
        DespawnPlayer: struct {
            id: u8,
        },
        Disconnect: struct {
            id: u8,
            reason: [64]u8,
        },
        UpdatePlayerType: struct {
            type: u8,
        },
    };
};
