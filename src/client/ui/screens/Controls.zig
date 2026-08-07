const std = @import("std");
const ae = @import("aether");
const input = ae.Core.input;

const Ui = @import("../Ui.zig");
const Options = @import("../../Options.zig");
const Prompts = @import("../Prompts.zig");
const widget_id = @import("../widget_id.zig");

pub const Widget = enum(u16) {
    reset = 1,
    done = 2,
    psp_analog = 3,
    psp_jump = 4,
    _,
};

pub const Status = enum(u8) {
    none,
    duplicate,
    reserved,
};

pub const Ctx = struct {
    capture: *?Options.PcControl,
    status: *Status,
};

pub const Result = struct {
    changed: bool = false,
    back: bool = false,
};

pub const WIDGET_W: i16 = 180;
const row_base: u16 = 100;

pub fn wid(w: Widget) widget_id.WidgetId {
    return widget_id.from(Widget, w);
}

pub fn row_wid(control: Options.PcControl) widget_id.WidgetId {
    return widget_id.raw(row_base + @intFromEnum(control));
}

pub fn run(ui: *Ui, opt: *Options.Options, ctx: Ctx) Result {
    var result: Result = .{};
    const sys = ui.input.input_system;
    var col = ui.stack(.{ .axis = .vertical, .anchor = .middle_center, .cross_align = .center, .gap = 4 });

    ui.label("Controls");
    if (!Options.controls_rebinding_supported()) {
        ui.label("Fixed on this platform");
        if (ui.button(wid(.done), "Done", .{ .width = WIDGET_W })) {
            cancel_capture(sys, ctx);
            result.back = true;
        }
        col.end();
        ui.prompts(&.{ Prompts.select(), Prompts.back() });
        if (ui.cancel_pressed()) {
            cancel_capture(sys, ctx);
            result.back = true;
        }
        return result;
    }

    var suppress_actions = false;
    if (ae.platform == .psp) {
        run_psp(ui, opt, &result);
    } else if (Options.uses_old_3ds_controls()) {
        run_old_3ds(ui, opt, &result);
    } else {
        suppress_actions = run_pc(ui, opt, ctx, &result);
    }

    if (ui.button(wid(.reset), "Reset Defaults", .{ .width = WIDGET_W, .enabled = !suppress_actions })) {
        if (ae.platform == .psp) {
            opt.reset_psp_controls();
        } else if (Options.uses_old_3ds_controls()) {
            opt.reset_psp_controls();
        } else {
            opt.reset_pc_controls();
            ctx.status.* = .none;
            cancel_capture(sys, ctx);
        }
        result.changed = true;
    }
    if (ui.button(wid(.done), "Done", .{ .width = WIDGET_W, .enabled = !suppress_actions })) {
        cancel_capture(sys, ctx);
        result.back = true;
    }

    col.end();
    ui.prompts(&.{ Prompts.select(), Prompts.back() });
    if (!suppress_actions and ui.cancel_pressed()) {
        cancel_capture(sys, ctx);
        result.back = true;
    }
    return result;
}

pub fn cancel_capture(sys: ?*input.InputSystem, ctx: Ctx) void {
    if (ctx.capture.* != null) {
        if (sys) |s| s.cancel_capture() catch {};
        ctx.capture.* = null;
    }
}

fn run_pc(ui: *Ui, opt: *Options.Options, ctx: Ctx, result: *Result) bool {
    const suppress_actions = ui.input.text_events and poll_capture(ui.input.input_system, opt, ctx, result);
    pc_row(ui, opt, .forward, "Forward", ctx, !suppress_actions);
    pc_row(ui, opt, .back, "Back", ctx, !suppress_actions);
    pc_row(ui, opt, .left, "Left", ctx, !suppress_actions);
    pc_row(ui, opt, .right, "Right", ctx, !suppress_actions);
    pc_row(ui, opt, .inventory, "Inventory", ctx, !suppress_actions);
    switch (ctx.status.*) {
        .none => ui.spacer(0, 8),
        .duplicate => ui.label("&cKey already in use"),
        .reserved => ui.label("Key is reserved"),
    }
    return suppress_actions;
}

fn pc_row(ui: *Ui, opt: *Options.Options, control: Options.PcControl, label: []const u8, ctx: Ctx, enabled: bool) void {
    const waiting = if (ctx.capture.*) |active| active == control else false;
    const text = if (waiting)
        ui.fmt("{s}: Press key...", .{label})
    else
        ui.fmt("{s}: {s}", .{ label, Options.pc_key_label(opt.pc_key(control)) });
    if (ui.button(row_wid(control), text, .{ .width = WIDGET_W, .enabled = enabled })) {
        begin_capture(ui.input.input_system, ctx, control);
    }
}

fn begin_capture(sys: ?*input.InputSystem, ctx: Ctx, control: Options.PcControl) void {
    const s = sys orelse return;
    cancel_capture(sys, ctx);
    var eligible = std.EnumSet(input.BindingSourceKind).initEmpty();
    eligible.insert(.key);
    s.begin_capture_next_input(eligible) catch return;
    ctx.capture.* = control;
    ctx.status.* = .none;
}

fn poll_capture(sys: ?*input.InputSystem, opt: *Options.Options, ctx: Ctx, result: *Result) bool {
    const s = sys orelse return false;
    const control = ctx.capture.* orelse return false;
    const session = s.current_capture_session() orelse return false;
    switch (session.status) {
        .waiting => return false,
        .cancelled => {
            ctx.capture.* = null;
            return true;
        },
        .captured => {
            ctx.capture.* = null;
            const key = switch (session.result.source) {
                .key => |k| k,
                else => return true,
            };
            if (!Options.pc_key_assignable(key)) {
                ctx.status.* = .reserved;
                return true;
            }
            const old = opt.pc_key(control);
            if (!opt.set_pc_key(control, key)) {
                ctx.status.* = .duplicate;
                return true;
            }
            ctx.status.* = .none;
            if (old != key) result.changed = true;
            return true;
        },
    }
}

fn run_psp(ui: *Ui, opt: *Options.Options, result: *Result) void {
    if (ui.button(wid(.psp_analog), ui.fmt("Analog: {s}", .{psp_analog_label(opt.psp_analog_mode)}), .{ .width = WIDGET_W })) {
        opt.psp_analog_mode = switch (opt.psp_analog_mode) {
            .move => .look,
            .look => .move,
        };
        result.changed = true;
    }
    if (ui.button(wid(.psp_jump), ui.fmt("Jump: {s}", .{psp_jump_label(opt.psp_jump_mode)}), .{ .width = WIDGET_W })) {
        opt.psp_jump_mode = switch (opt.psp_jump_mode) {
            .select => .up,
            .up => .select,
        };
        result.changed = true;
    }
}

fn run_old_3ds(ui: *Ui, opt: *Options.Options, result: *Result) void {
    run_psp(ui, opt, result);
}

fn psp_analog_label(mode: Options.PspAnalogMode) []const u8 {
    return switch (mode) {
        .move => "Move",
        .look => "Look",
    };
}

fn psp_jump_label(mode: Options.PspJumpMode) []const u8 {
    return switch (mode) {
        .select => "Select",
        .up => "Up",
    };
}
