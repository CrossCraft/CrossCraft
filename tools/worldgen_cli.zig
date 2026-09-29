//! Worldgen oracle CLI.
//!
//! Exposes the `worldgen` module through the Classic-Worldgen-RE oracle
//! contracts so it can be differentially fuzzed against other oracles:
//!
//!   worldgen_cli --seed S --width W --height H --depth D --blocks-out FILE
//!     One-shot v1 interface (Classic-Worldgen-RE fuzzer/ORACLE.md).
//!
//!   worldgen_cli --serve
//!     Persistent v2 worker (Classic-Worldgen-RE fuzzer_v2/ORACLE.md).
//!
//! Usage: zig build worldgen-cli -Doptimize=ReleaseSafe
//!        zig-out/bin/worldgen_cli --serve

const std = @import("std");
const worldgen = @import("worldgen");
const assert = std.debug.assert;

const dimensions_type = worldgen.level.world_dimensions;

const args = struct {
    seed: i64,
    dimensions: dimensions_type,
    blocks_out: []const u8,
};

const cli_mode = union(enum) {
    one_shot: args,
    serve,
};

const worker_case = struct {
    id: []const u8,
    seed: i64,
    dimensions: dimensions_type,
};

const worker_protocol_error = error{
    protocol_failure,
};

const parse_error = error{
    invalid_arguments,
};

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        std.debug.print("oracle: failed to read arguments: {s}\n", .{@errorName(err)});
        return 1;
    };

    const mode = parse_cli_mode(argv) catch {
        std.debug.print("oracle: invalid arguments\n", .{});
        return 2;
    };

    switch (mode) {
        .one_shot => |parsed_args| return run_one_shot(init, parsed_args),
        .serve => return run_worker_mode(init),
    }
}

/// Generates one level. `scratch` holds the generator's transient workspace;
/// the caller owns the returned block buffer through `allocator`.
fn generate(allocator: std.mem.Allocator, seed: i64, dimensions: dimensions_type) std.mem.Allocator.Error![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const generated = try worldgen.generate(allocator, scratch.allocator(), seed, dimensions);
    assert(generated.blocks.len == dimensions.volume());
    return generated.blocks;
}

fn run_one_shot(init: std.process.Init, parsed_args: args) u8 {
    const blocks = generate(init.gpa, parsed_args.seed, parsed_args.dimensions) catch |err| {
        std.debug.print("oracle: generation failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer init.gpa.free(blocks);

    const output = std.Io.Dir.cwd().createFile(init.io, parsed_args.blocks_out, .{}) catch |err| {
        std.debug.print("oracle: cannot create output '{s}': {s}\n", .{ parsed_args.blocks_out, @errorName(err) });
        return 1;
    };
    defer output.close(init.io);

    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = output.writer(init.io, &buffer);
    file_writer.interface.writeAll(blocks) catch |err| {
        std.debug.print("oracle: cannot write output '{s}': {s}\n", .{ parsed_args.blocks_out, @errorName(err) });
        return 1;
    };
    file_writer.interface.flush() catch |err| {
        std.debug.print("oracle: cannot finish output '{s}': {s}\n", .{ parsed_args.blocks_out, @errorName(err) });
        return 1;
    };

    return 0;
}

fn run_worker_mode(init: std.process.Init) u8 {
    var stdin_buffer: [16 * 1024]u8 = undefined;
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stderr_buffer: [4 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);

    serve_worker(
        init.gpa,
        &stdin_reader.interface,
        &stdout_writer.interface,
        &stderr_writer.interface,
    ) catch |err| {
        write_worker_diagnostic(&stderr_writer.interface, "oracle worker: terminated: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn parse_cli_mode(argv: []const [:0]const u8) parse_error!cli_mode {
    if (argv.len == 2 and std.mem.eql(u8, argv[1], "--serve")) return .serve;
    return .{ .one_shot = try parse_args(argv) };
}

fn parse_args(argv: []const [:0]const u8) parse_error!args {
    var seed: ?i64 = null;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var depth: ?u32 = null;
    var blocks_out: ?[]const u8 = null;

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const flag: []const u8 = argv[index];
        if (index + 1 >= argv.len) return error.invalid_arguments;

        const value: []const u8 = argv[index + 1];
        index += 1;

        if (std.mem.eql(u8, flag, "--seed")) {
            if (seed != null) return error.invalid_arguments;
            seed = std.fmt.parseInt(i64, value, 10) catch return error.invalid_arguments;
        } else if (std.mem.eql(u8, flag, "--width")) {
            if (width != null) return error.invalid_arguments;
            width = try parse_dimension(value);
        } else if (std.mem.eql(u8, flag, "--height")) {
            if (height != null) return error.invalid_arguments;
            height = try parse_dimension(value);
        } else if (std.mem.eql(u8, flag, "--depth")) {
            if (depth != null) return error.invalid_arguments;
            depth = try parse_dimension(value);
        } else if (std.mem.eql(u8, flag, "--blocks-out")) {
            if (blocks_out != null or value.len == 0) return error.invalid_arguments;
            blocks_out = value;
        } else {
            return error.invalid_arguments;
        }
    }

    const dimensions: dimensions_type = .{
        .width = width orelse return error.invalid_arguments,
        .height = height orelse return error.invalid_arguments,
        .depth = depth orelse return error.invalid_arguments,
    };
    if (!dimensions.validate()) return error.invalid_arguments;

    return .{
        .seed = seed orelse return error.invalid_arguments,
        .dimensions = dimensions,
        .blocks_out = blocks_out orelse return error.invalid_arguments,
    };
}

fn parse_dimension(text: []const u8) parse_error!u32 {
    const value = std.fmt.parseInt(u32, text, 10) catch return error.invalid_arguments;
    if (value < 16 or !std.math.isPowerOfTwo(value)) return error.invalid_arguments;
    return value;
}

fn serve_worker(
    allocator: std.mem.Allocator,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    diagnostics: *std.Io.Writer,
) worker_protocol_error!void {
    write_worker_header(output, "READY 2\n") catch return error.protocol_failure;

    while (true) {
        const line = read_control_line(allocator, input) catch |err| {
            write_worker_diagnostic(diagnostics, "oracle worker: cannot read control line: {s}\n", .{@errorName(err)});
            return error.protocol_failure;
        } orelse {
            write_worker_diagnostic(diagnostics, "oracle worker: stdin closed without QUIT\n", .{});
            return error.protocol_failure;
        };
        defer allocator.free(line);

        if (std.mem.eql(u8, line, "QUIT")) {
            write_worker_header(output, "BYE\n") catch return error.protocol_failure;
            return;
        }

        const request = parse_worker_case(line) catch {
            if (recoverable_case_id(line)) |id| {
                write_worker_failure(output, id) catch return error.protocol_failure;
                write_worker_diagnostic(diagnostics, "oracle worker: invalid CASE {s}\n", .{id});
                continue;
            }
            write_worker_diagnostic(diagnostics, "oracle worker: invalid control line\n", .{});
            return error.protocol_failure;
        };

        const blocks = generate(allocator, request.seed, request.dimensions) catch |err| {
            write_worker_failure(output, request.id) catch return error.protocol_failure;
            write_worker_diagnostic(diagnostics, "oracle worker: CASE {s} failed: {s}\n", .{ request.id, @errorName(err) });
            continue;
        };
        defer allocator.free(blocks);

        output.print("OK {s} {d}\n", .{ request.id, blocks.len }) catch return error.protocol_failure;
        output.writeAll(blocks) catch return error.protocol_failure;
        output.flush() catch return error.protocol_failure;
    }
}

fn read_control_line(allocator: std.mem.Allocator, input: *std.Io.Reader) !?[]u8 {
    var line_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer line_writer.deinit();

    _ = try input.streamDelimiterEnding(&line_writer.writer, '\n');
    const next = input.peekGreedy(1) catch |err| switch (err) {
        error.EndOfStream => {
            if (line_writer.written().len == 0) return null;
            return error.unterminated_control_line;
        },
        else => return err,
    };
    assert(next[0] == '\n');
    input.toss(1);

    return try line_writer.toOwnedSlice();
}

fn recoverable_case_id(line: []const u8) ?[]const u8 {
    const prefix = "CASE ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;

    const id_end = std.mem.indexOfScalarPos(u8, line, prefix.len, ' ') orelse line.len;
    const id = line[prefix.len..id_end];
    return if (is_decimal_identifier(id)) id else null;
}

fn parse_worker_case(line: []const u8) error{invalid_case}!worker_case {
    var fields: [6][]const u8 = undefined;
    var iterator = std.mem.splitScalar(u8, line, ' ');
    for (&fields) |*field| {
        field.* = iterator.next() orelse return error.invalid_case;
        if (field.len == 0) return error.invalid_case;
    }
    if (iterator.next() != null) return error.invalid_case;
    if (!std.mem.eql(u8, fields[0], "CASE") or !is_decimal_identifier(fields[1])) return error.invalid_case;

    const dimensions: dimensions_type = .{
        .width = parse_dimension(fields[3]) catch return error.invalid_case,
        .height = parse_dimension(fields[4]) catch return error.invalid_case,
        .depth = parse_dimension(fields[5]) catch return error.invalid_case,
    };
    if (!dimensions.validate()) return error.invalid_case;

    return .{
        .id = fields[1],
        .seed = std.fmt.parseInt(i64, fields[2], 10) catch return error.invalid_case,
        .dimensions = dimensions,
    };
}

fn is_decimal_identifier(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn write_worker_header(output: *std.Io.Writer, header: []const u8) !void {
    try output.writeAll(header);
    try output.flush();
}

fn write_worker_failure(output: *std.Io.Writer, id: []const u8) !void {
    assert(is_decimal_identifier(id));
    try output.print("FAIL {s}\n", .{id});
    try output.flush();
}

fn write_worker_diagnostic(diagnostics: *std.Io.Writer, comptime format: []const u8, format_args: anytype) void {
    diagnostics.print(format, format_args) catch return;
    diagnostics.flush() catch {};
}
