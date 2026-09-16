//! One sandboxed Luau VM per plugin with memory, deadline, and module
//! confinement. Luau must never execute while a world or roster lock is held.
const std = @import("std");
const luaz = @import("luaz");
const Server = @import("core").Server;
const Client = Server.Client;

const log = std.log.scoped(.plugins);
const assert = std.debug.assert;

pub const max_source_bytes: usize = 256 * 1024;

const MemContext = struct {
    backing: std.mem.Allocator,
    used: usize = 0,
    limit: usize,
    exhausted: bool = false,
};

fn lua_alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const mem: *MemContext = @ptrCast(@alignCast(ud.?));
    if (nsize == 0) {
        if (ptr) |p| {
            mem.backing.free(@as([*]u8, @ptrCast(p))[0..osize]);
            mem.used -= osize;
        }
        return null;
    }
    const current = if (ptr != null) mem.used - osize else mem.used;
    assert(mem.used >= osize or ptr == null);
    if (current + nsize > mem.limit) {
        mem.exhausted = true;
        return null;
    }
    const old_slice: []u8 = if (ptr) |p| @as([*]u8, @ptrCast(p))[0..osize] else &.{};
    const new_slice = mem.backing.realloc(old_slice, nsize) catch {
        mem.exhausted = true;
        return null;
    };
    mem.used = current + nsize;
    return new_slice.ptr;
}

fn interrupt_callback(L: ?*luaz.c.lua_State, gc: c_int) callconv(.c) void {
    _ = gc;
    const cbs = luaz.c.lua_callbacks(L);
    const runtime: *Runtime = @ptrCast(@alignCast(cbs.*.userdata orelse return));
    if (runtime.deadline_ms == 0) return;
    if (Client.now_ms() <= runtime.deadline_ms) return;
    runtime.interrupted = true;
    // Stop the VM at the safepoint; the pending pcall reports the interrupt.
    const state = luaz.State{ .lua = L.? };
    state.break_();
}

pub const Runtime = struct {
    state: luaz.State = undefined,
    mem: MemContext,
    package_dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    /// Monotonic deadline for the running script; 0 disables enforcement.
    deadline_ms: i64 = 0,
    interrupted: bool = false,
    error_buf: [256]u8 = @splat(0),
    error_len: u8 = 0,
    module_cache_ref: i32 = 0,

    pub const max_memory_bytes: usize = 4 * 1024 * 1024;

    pub fn init(alloc: std.mem.Allocator, package_dir: std.Io.Dir) !*Runtime {
        const runtime = try alloc.create(Runtime);
        errdefer alloc.destroy(runtime);
        runtime.* = .{
            .mem = .{ .backing = alloc, .limit = max_memory_bytes },
            .package_dir = package_dir,
            .alloc = alloc,
        };

        runtime.state = luaz.State.initWithAlloc(lua_alloc, &runtime.mem) orelse return error.OutOfMemory;
        const state = runtime.state;
        state.pushLightUserdata(runtime);
        state.callbacks().userdata = runtime;
        state.callbacks().interrupt = interrupt_callback;

        open_lib(state, luaz.c.luaopen_base, "");
        open_lib(state, luaz.c.luaopen_coroutine, "coroutine");
        open_lib(state, luaz.c.luaopen_table, "table");
        open_lib(state, luaz.c.luaopen_string, "string");
        open_lib(state, luaz.c.luaopen_math, "math");
        open_lib(state, luaz.c.luaopen_bit32, "bit32");
        open_lib(state, luaz.c.luaopen_buffer, "buffer");
        open_lib(state, luaz.c.luaopen_utf8, "utf8");
        state.sandbox();
        state.sandboxThread();

        state.createTable(0, 4);
        runtime.module_cache_ref = state.ref(-1);
        state.pop(1);

        state.pushLightUserdata(runtime);
        state.pushCClosureK(require_impl, "require", 1, null);
        state.setGlobal("require");
        return runtime;
    }

    pub fn deinit(self: *Runtime, alloc: std.mem.Allocator) void {
        // The VM allocator points into this struct; close the state first.
        self.state.deinit();
        self.* = undefined;
        alloc.destroy(self);
    }

    fn open_lib(state: luaz.State, open_fn: *const fn (?*luaz.c.lua_State) callconv(.c) c_int, name: [:0]const u8) void {
        state.pushCFunction(@ptrCast(open_fn), null);
        state.pushString(name);
        if (state.pcall(1, 0, 0) != .ok) state.pop(1);
    }

    fn capture_error(self: *Runtime) void {
        var message: []const u8 = if (self.mem.exhausted) "script exceeded its memory budget" else "unknown script error";
        if (self.state.getTop() > 0) {
            // tolstring renders any error object; copy before releasing it.
            const text = self.state.tolString(-1, null);
            const len = @min(text.len, self.error_buf.len);
            @memcpy(self.error_buf[0..len], text[0..len]);
            self.error_len = @intCast(len);
            self.state.setTop(0);
            return;
        }
        const len = @min(message.len, self.error_buf.len);
        @memcpy(self.error_buf[0..len], message[0..len]);
        self.error_len = @intCast(len);
        self.state.setTop(0);
    }

    pub fn last_error(self: *const Runtime) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    /// Compile Luau source and push the resulting function, or fail with the
    /// compiler diagnostic in `last_error`.
    pub fn compile_function(self: *Runtime, chunkname: [:0]const u8, source: []const u8) !void {
        const result = luaz.Compiler.compile(source, .{}) catch return error.OutOfMemory;
        defer result.deinit();

        switch (result) {
            .err => |message| {
                const len = @min(message.len, self.error_buf.len);
                @memcpy(self.error_buf[0..len], message[0..len]);
                self.error_len = @intCast(len);
                return error.Compile;
            },
            .ok => |bytecode| {
                assert(bytecode.len > 0);
                if (self.state.load(chunkname, bytecode, 0) != .ok) {
                    self.capture_error();
                    return error.Compile;
                }
            },
        }
    }

    /// Run the function on top of the stack under the current deadline.
    /// Returns false with `last_error` set when the script failed.
    pub fn protect_call(self: *Runtime, nargs: usize, nresults: usize) bool {
        assert(nargs <= 16 and nresults <= 4);
        const status = self.state.pcall(@intCast(nargs), @intCast(nresults), 0);
        if (status == .ok) return true;
        if (self.interrupted) {
            self.error_buf = @splat(0);
            const text = "script exceeded its execution deadline";
            @memcpy(self.error_buf[0..text.len], text);
            self.error_len = @intCast(text.len);
            self.interrupted = false;
            return false;
        }
        self.capture_error();
        return false;
    }

    pub fn push_function(self: *Runtime, ref: i32) void {
        _ = self.state.getRef(ref);
    }

    fn module_cached(self: *Runtime, name: []const u8) bool {
        assert(self.module_cache_ref != 0);
        self.push_function(self.module_cache_ref);
        defer self.state.pop(1);

        self.state.pushLString(name);
        _ = self.state.getTable(-2);
        const cached = self.state.getType(-1) != .nil;
        self.state.pop(1);
        return cached;
    }

    fn module_path_is_confined(self: *Runtime, name: []const u8, out: *[256]u8) ?[]const u8 {
        if (name.len == 0 or name.len > 96) return null;
        if (std.mem.indexOfScalar(u8, name, '\\') != null) return null;
        var it = std.mem.splitScalar(u8, name, '/');
        while (it.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return null;
        }
        const path = std.fmt.bufPrint(out, "{s}.luau", .{name}) catch return null;
        // A symlink anywhere along the relative path escapes the package.
        var link_buf: [256]u8 = undefined;
        var prefix: usize = 0;
        var component_it = std.mem.splitScalar(u8, path, '/');
        while (component_it.next()) |component| {
            if (self.package_dir.readLink(Server.io, out[0 .. prefix + component.len], &link_buf)) |_| {
                return null;
            } else |_| {}
            prefix += component.len + 1;
        }
        return path;
    }

    fn require_impl(L: ?*luaz.c.lua_State) callconv(.c) c_int {
        const state = luaz.State{ .lua = L.? };
        const runtime: *Runtime = @ptrCast(@alignCast(state.toLightUserdata(luaz.State.upvalueIndex(1)).?));
        const name = state.checkString(1);

        if (runtime.module_cached(name)) {
            runtime.push_function(runtime.module_cache_ref);
            state.pushLString(name);
            _ = runtime.state.getTable(-2);
            state.remove(-2);
            return 1;
        }

        var path_buf: [256]u8 = undefined;
        const path = runtime.module_path_is_confined(name, &path_buf) orelse {
            state.pushLString("require path escapes the plugin package");
            state.raiseError();
        };
        const source = read_package_file(runtime, path) orelse {
            state.pushLString("module not found");
            state.raiseError();
        };
        defer runtime.alloc.free(source);

        var chunk_buf: [112:0]u8 = @splat(0);
        const chunkname = std.fmt.bufPrintZ(&chunk_buf, "{s}", .{path}) catch {
            state.pushLString("module path is too long");
            state.raiseError();
        };
        runtime.compile_function(chunkname, source) catch {
            state.pushLString(runtime.last_error());
            state.raiseError();
        };
        if (!runtime.protect_call(0, 1)) {
            state.pushLString(runtime.last_error());
            state.raiseError();
        }
        if (state.isNil(-1)) {
            state.pop(1);
            state.pushBoolean(true);
        }

        runtime.push_function(runtime.module_cache_ref);
        state.pushLString(name);
        state.pushValue(-3);
        runtime.state.rawSet(-3);
        state.pop(1);
        return 1;
    }

    fn read_package_file(self: *Runtime, path: []const u8) ?[]u8 {
        const file = self.package_dir.openFile(Server.io, path, .{}) catch return null;
        defer file.close(Server.io);

        const stat = file.stat(Server.io) catch return null;
        if (stat.kind == .sym_link) return null;
        if (stat.size == 0 or stat.size > max_source_bytes) return null;
        const source = self.alloc.alloc(u8, @intCast(stat.size)) catch return null;
        const len = file.readPositionalAll(Server.io, source, 0) catch {
            self.alloc.free(source);
            return null;
        };
        return source[0..len];
    }

    /// Run the package entrypoint. The chunk runs on the sandboxed thread.
    pub fn run_entrypoint(self: *Runtime, entrypoint: []const u8, source: []const u8) bool {
        assert(source.len > 0 and source.len <= max_source_bytes);
        var chunkname_buf: [128:0]u8 = @splat(0);
        const chunkname = std.fmt.bufPrintZ(&chunkname_buf, "@{s}", .{entrypoint}) catch return false;
        self.compile_function(chunkname, source) catch return false;
        return self.protect_call(0, 0);
    }
};
