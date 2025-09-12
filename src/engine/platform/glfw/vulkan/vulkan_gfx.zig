const std = @import("std");
const Util = @import("../../../util/util.zig");
const glfw = @import("glfw");
const zm = @import("zmath");

const vk = @import("vulkan");
const gfx = @import("../../gfx.zig");
const Rendering = @import("../../../rendering/rendering.zig");
const Pipeline = Rendering.Pipeline;
const Mesh = Rendering.Mesh;
const GFXAPI = @import("../../gfx_api.zig");
const Self = @This();

const Context = @import("context.zig");
const Swapchain = @import("swapchain.zig");
const GarbageCollector = @import("garbage_collector.zig");

pub var context: Context = undefined;
pub var swapchain: Swapchain = undefined;
pub var gc: GarbageCollector = undefined;

pub var command_pool: vk.CommandPool = .null_handle;
var command_buffers: []vk.CommandBuffer = undefined;
pub var command_buffer: vk.CommandBufferProxy = undefined;

var swap_state: Swapchain.PresentState = .optimal;

fn create_command_pool() !void {
    command_pool = try context.logical_device.createCommandPool(&.{
        .queue_family_index = context.graphics_queue.family,
        .flags = .{
            .reset_command_buffer_bit = true,
        },
    }, null);

    command_buffers = try context.allocator.alloc(vk.CommandBuffer, swapchain.swap_images.len);
    try context.logical_device.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = @intCast(swapchain.swap_images.len),
    }, command_buffers.ptr);
}

fn destroy_command_pool() void {
    context.logical_device.freeCommandBuffers(command_pool, @intCast(swapchain.swap_images.len), command_buffers.ptr);
    context.allocator.free(command_buffers);
    context.logical_device.destroyCommandPool(command_pool, null);
}

fn init(ctx: *anyopaque) !void {
    _ = ctx;

    context = try Context.init(Util.allocator(), "SparkEngine");
    swapchain = try Swapchain.init(&context);
    gc = GarbageCollector.init(Util.allocator());

    try create_command_pool();
}

fn deinit(ctx: *anyopaque) void {
    _ = ctx;
    context.logical_device.deviceWaitIdle() catch {};

    destroy_command_pool();
    swapchain.deinit();
    gc.deinit();
    context.deinit();
}

var clear_color: [4]f32 = @splat(0);
fn set_clear_color(ctx: *anyopaque, r: f32, g: f32, b: f32, a: f32) void {
    _ = ctx;
    clear_color[0] = r;
    clear_color[1] = g;
    clear_color[2] = b;
    clear_color[3] = a;
}

fn start_frame(ctx: *anyopaque) bool {
    _ = ctx;

    if (gfx.surface.get_width() == 0 or gfx.surface.get_height() == 0) {
        @branchHint(.unlikely);
        return false;
    }

    // Acquire next command buffer
    command_buffer = vk.CommandBufferProxy.init(command_buffers[swapchain.image_index], context.logical_device.wrapper);

    // Garbage collect resources
    const current = swapchain.currentSwapImage();
    _ = context.logical_device.waitForFences(1, @ptrCast(&current.frame_fence), .true, std.math.maxInt(u64)) catch unreachable;
    context.logical_device.resetFences(1, @ptrCast(&current.frame_fence)) catch unreachable;
    context.logical_device.resetCommandBuffer(command_buffer.handle, .{}) catch unreachable;
    gc.frame_index = swapchain.image_index;
    gc.collect();

    command_buffer.beginCommandBuffer(&.{}) catch unreachable;

    const extent = vk.Extent2D{
        .width = @intCast(gfx.surface.get_width()),
        .height = @intCast(gfx.surface.get_height()),
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(gfx.surface.get_width()),
        .height = @floatFromInt(gfx.surface.get_height()),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };

    const clear_value = vk.ClearValue{ .color = .{ .float_32 = clear_color } };

    command_buffer.setViewport(0, 1, @ptrCast(&viewport));
    command_buffer.setScissor(0, 1, @ptrCast(&scissor));

    const pre = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .color_attachment_output_bit = true, .top_of_pipe_bit = true },
        .src_access_mask = .{}, // no accesses to wait on
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
        .old_layout = .undefined, // or .present_src_khr if you track it
        .new_layout = .color_attachment_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = swapchain.currentSwapImage().image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    const pre_dep = vk.DependencyInfo{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&pre),
    };

    command_buffer.pipelineBarrier2(&pre_dep);

    command_buffer.beginRendering(&.{
        .layer_count = 1,
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        },
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&vk.RenderingAttachmentInfo{
            .image_layout = .color_attachment_optimal,
            .image_view = swapchain.currentSwapImage().view,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = clear_value,
        }),
    });

    return true;
}

fn end_frame(ctx: *anyopaque) void {
    _ = ctx;

    command_buffer.endRendering();
    const post = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{ .color_attachment_write_bit = true },
        .dst_stage_mask = .{}, // present isn't a pipeline stage
        .dst_access_mask = .{},
        .old_layout = .color_attachment_optimal,
        .new_layout = .present_src_khr,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = swapchain.currentSwapImage().image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    const post_dep = vk.DependencyInfo{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&post),
    };
    command_buffer.pipelineBarrier2(&post_dep);

    command_buffer.endCommandBuffer() catch unreachable;

    swap_state = swapchain.present(command_buffer.handle) catch |err| switch (err) {
        error.OutOfDateKHR => .suboptimal,
        else => unreachable,
    };

    if (swap_state == .suboptimal) {
        if (gfx.surface.get_width() == 0 or gfx.surface.get_height() == 0) {
            swap_state = .optimal; // Reset state to avoid loop
            return; // Skip recreate until restored
        }
        swapchain.recreate() catch unreachable;
    }
}

fn set_proj_matrix(ctx: *anyopaque, mat: *const zm.Mat) void {
    _ = ctx;
    _ = mat;
}

fn set_view_matrix(ctx: *anyopaque, mat: *const zm.Mat) void {
    _ = ctx;
    _ = mat;
}

fn create_pipeline(ctx: *anyopaque, layout: Pipeline.VertexLayout, vs: ?[:0]const u8, fs: ?[:0]const u8) anyerror!Pipeline.Handle {
    _ = ctx;
    _ = layout;
    _ = vs;
    _ = fs;
    return 0;
}

fn destroy_pipeline(ctx: *anyopaque, handle: Pipeline.Handle) void {
    _ = ctx;
    _ = handle;
}

fn bind_pipeline(ctx: *anyopaque, handle: Pipeline.Handle) void {
    _ = ctx;
    _ = handle;
}

fn create_mesh(ctx: *anyopaque, pipeline: Pipeline.Handle) anyerror!u32 {
    _ = ctx;
    _ = pipeline;
    return 0;
}

fn destroy_mesh(ctx: *anyopaque, handle: u32) void {
    _ = ctx;
    _ = handle;
}

fn update_mesh(ctx: *anyopaque, handle: u32, offset: usize, data: []const u8) void {
    _ = ctx;
    _ = handle;
    _ = offset;
    _ = data;
}

fn draw_mesh(ctx: *anyopaque, handle: u32, model: *const zm.Mat, count: usize) void {
    _ = ctx;
    _ = handle;
    _ = model;
    _ = count;
}

fn create_texture(ctx: *anyopaque, width: u32, height: u32, data: []const u8) anyerror!u32 {
    _ = ctx;
    _ = width;
    _ = height;
    _ = data;
    return 0;
}

fn bind_texture(ctx: *anyopaque, handle: u32) void {
    _ = ctx;
    _ = handle;
}

fn destroy_texture(ctx: *anyopaque, handle: u32) void {
    _ = ctx;
    _ = handle;
}

pub fn gfx_api(self: *Self) GFXAPI {
    return GFXAPI{
        .ptr = self,
        .tab = &.{
            .init = init,
            .deinit = deinit,
            .set_clear_color = set_clear_color,
            .start_frame = start_frame,
            .end_frame = end_frame,
            .set_proj_matrix = set_proj_matrix,
            .set_view_matrix = set_view_matrix,
            .create_mesh = create_mesh,
            .destroy_mesh = destroy_mesh,
            .update_mesh = update_mesh,
            .draw_mesh = draw_mesh,
            .create_texture = create_texture,
            .bind_texture = bind_texture,
            .destroy_texture = destroy_texture,
            .create_pipeline = create_pipeline,
            .destroy_pipeline = destroy_pipeline,
            .bind_pipeline = bind_pipeline,
        },
    };
}
