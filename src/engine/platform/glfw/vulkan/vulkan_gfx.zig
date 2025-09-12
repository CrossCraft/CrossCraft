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

const PipelineData = struct {
    layout: vk.PipelineLayout,
    vert_layout: Pipeline.VertexLayout,
    pipeline: vk.Pipeline,
};

const MeshData = struct {
    memory: vk.DeviceMemory = .null_handle,
    buffer: vk.Buffer = .null_handle,
    pipeline: Pipeline.Handle = 0,
    built: bool = false,
};

pub const ShaderState = struct {
    view: zm.Mat,
    proj: zm.Mat,
};

pub var state: ShaderState = .{
    .view = zm.identity(),
    .proj = zm.identity(),
};

pub const UBO = struct {
    memory: vk.DeviceMemory,
    buffer: vk.Buffer,
    mapped_ptr: *ShaderState,
};

pub var ubos: []UBO = undefined;

pub var context: Context = undefined;
pub var swapchain: Swapchain = undefined;
pub var gc: GarbageCollector = undefined;

pub var command_pool: vk.CommandPool = .null_handle;
var command_buffers: []vk.CommandBuffer = undefined;
pub var command_buffer: vk.CommandBufferProxy = undefined;

var descriptor_set_layout: vk.DescriptorSetLayout = .null_handle;
var descriptor_pool: vk.DescriptorPool = .null_handle;
var descriptor_sets: []vk.DescriptorSet = undefined;

var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var meshes = Util.CircularBuffer(MeshData, 2048).init();

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

fn create_uniform_buffers() !void {
    ubos = try Util.allocator().alloc(UBO, swapchain.swap_images.len);

    for (ubos) |*ubo| {
        ubo.buffer = context.logical_device.createBuffer(&.{
            .size = @sizeOf(ShaderState),
            .usage = .{ .uniform_buffer_bit = true },
            .sharing_mode = .exclusive,
        }, null) catch unreachable;

        const mem_reqs = context.logical_device.getBufferMemoryRequirements(ubo.buffer);
        ubo.memory = context.allocate_gpu_buffer(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true }) catch unreachable;
        context.logical_device.bindBufferMemory(ubo.buffer, ubo.memory, 0) catch unreachable;

        const mapped_data = context.logical_device.mapMemory(ubo.memory, 0, vk.WHOLE_SIZE, .{}) catch unreachable;
        ubo.mapped_ptr = @ptrCast(@alignCast(mapped_data));
        ubo.mapped_ptr.* = state;
    }
}

fn destroy_uniform_buffers() void {
    for (ubos) |ubo| {
        context.logical_device.unmapMemory(ubo.memory);
        context.logical_device.destroyBuffer(ubo.buffer, null);
        context.logical_device.freeMemory(ubo.memory, null);
    }
    Util.allocator().free(ubos);
}

fn create_descriptor_set_layout() !void {
    const ubo_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_count = 1,
        .descriptor_type = .uniform_buffer,
        .stage_flags = .{ .vertex_bit = true },
    };

    descriptor_set_layout = try context.logical_device.createDescriptorSetLayout(&.{
        .binding_count = 1,
        .p_bindings = @ptrCast(&ubo_layout_binding),
    }, null);
}

fn destroy_descriptor_set_layout() void {
    context.logical_device.destroyDescriptorSetLayout(descriptor_set_layout, null);
}

fn create_descriptor_pool() !void {
    const pool_size = vk.DescriptorPoolSize{
        .type = .uniform_buffer,
        .descriptor_count = @intCast(swapchain.swap_images.len),
    };

    descriptor_pool = try context.logical_device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
        .max_sets = @intCast(swapchain.swap_images.len),
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
        .flags = .{ .free_descriptor_set_bit = true },
    }, null);
}

fn destroy_descriptor_pool() void {
    context.logical_device.destroyDescriptorPool(descriptor_pool, null);
}

fn create_descriptor_sets() !void {
    const layouts = try Util.allocator().alloc(vk.DescriptorSetLayout, swapchain.swap_images.len);
    defer Util.allocator().free(layouts);

    for (layouts) |*layout| {
        layout.* = descriptor_set_layout;
    }

    descriptor_sets = try Util.allocator().alloc(vk.DescriptorSet, swapchain.swap_images.len);

    try context.logical_device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo{
        .descriptor_pool = descriptor_pool,
        .descriptor_set_count = @intCast(swapchain.swap_images.len),
        .p_set_layouts = @ptrCast(layouts.ptr),
    }, descriptor_sets.ptr);

    for (descriptor_sets, 0..) |set, i| {
        const buffer_info = vk.DescriptorBufferInfo{
            .buffer = ubos[i].buffer,
            .offset = 0,
            .range = @sizeOf(ShaderState),
        };

        const descriptor_write = vk.WriteDescriptorSet{
            .dst_set = set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .uniform_buffer,
            .p_buffer_info = @ptrCast(&buffer_info),
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        context.logical_device.updateDescriptorSets(1, @ptrCast(&descriptor_write), 0, null);
    }
}

fn destroy_descriptor_sets() void {
    context.logical_device.freeDescriptorSets(descriptor_pool, @intCast(swapchain.swap_images.len), @ptrCast(descriptor_sets.ptr)) catch unreachable;
    Util.allocator().free(descriptor_sets);
}

fn init(ctx: *anyopaque) !void {
    _ = ctx;

    context = try Context.init(Util.allocator(), "SparkEngine");
    swapchain = try Swapchain.init(&context);
    gc = GarbageCollector.init(Util.allocator());

    try create_command_pool();
    try create_uniform_buffers();
    try create_descriptor_set_layout();
    try create_descriptor_pool();
    try create_descriptor_sets();
}

fn deinit(ctx: *anyopaque) void {
    _ = ctx;
    context.logical_device.deviceWaitIdle() catch {};

    destroy_descriptor_sets();
    destroy_descriptor_pool();
    destroy_descriptor_set_layout();
    destroy_uniform_buffers();
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
    ubos[swapchain.image_index].mapped_ptr.proj = mat.*;
}

fn set_view_matrix(ctx: *anyopaque, mat: *const zm.Mat) void {
    _ = ctx;
    ubos[swapchain.image_index].mapped_ptr.view = mat.*;
}

fn create_pipeline(ctx: *anyopaque, layout: Pipeline.VertexLayout, vs: ?[:0]align(4) const u8, fs: ?[:0]align(4) const u8) anyerror!Pipeline.Handle {
    _ = ctx;

    if (vs == null or fs == null) return error.InvalidShader;

    const range = vk.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true },
        .offset = 0,
        .size = @sizeOf(zm.Mat),
    };

    const pl = try context.logical_device.createPipelineLayout(&.{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&descriptor_set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&range),
    }, null);

    const vert = try context.logical_device.createShaderModule(&.{
        .code_size = vs.?.len,
        .p_code = @ptrCast(@alignCast(vs.?.ptr)),
    }, null);

    const frag = try context.logical_device.createShaderModule(&.{
        .code_size = fs.?.len,
        .p_code = @ptrCast(@alignCast(fs.?.ptr)),
    }, null);

    const pipeline_shade_stage_create_info = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
        },
    };

    const pipeline_viewport_state_create_info = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = null,
        .scissor_count = 1,
        .p_scissors = null,
    };

    const pipeline_input_assembly_state_create_info = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const vertex_attribute_descriptions = try Util.allocator().alloc(vk.VertexInputAttributeDescription, layout.attributes.len);
    defer Util.allocator().free(vertex_attribute_descriptions);
    for (vertex_attribute_descriptions, 0..) |*desc, i| {
        const attr = layout.attributes[i];

        desc.* = .{
            .binding = attr.binding,
            .location = attr.location,
            .offset = @intCast(attr.offset),
            .format = switch (attr.format) {
                .f32x2 => .r32g32_sfloat,
                .f32x3 => .r32g32b32_sfloat,
                .unorm8x4 => .r8g8b8a8_unorm,
            },
        };
    }

    const binding = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @intCast(layout.stride),
        .input_rate = .vertex,
    };

    const pipeline_vertex_input_state_create_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast(&binding),
        .vertex_attribute_description_count = @intCast(layout.attributes.len),
        .p_vertex_attribute_descriptions = @ptrCast(vertex_attribute_descriptions.ptr),
    };

    const pipeline_rasterization_state_create_info = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
        .front_face = .counter_clockwise,
        .depth_bias_enable = .false,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .depth_bias_constant_factor = 0,
        .line_width = 1.0,
    };

    const pipeline_multisample_state_create_info = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const pipeline_color_blend_attachment_state = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
            .a_bit = true,
        },
    };

    const pipeline_color_blend_state_create_info = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&pipeline_color_blend_attachment_state),
        .blend_constants = @splat(0),
    };

    const dynstate = [_]vk.DynamicState{
        .viewport,
        .scissor,
    };

    const pipeline_dynamic_state_create_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = @intCast(dynstate.len),
        .p_dynamic_states = @ptrCast(&dynstate),
    };

    const pipeline_rendering_create_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&swapchain.surface_format.format),
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };

    const graphics_pipeline_create_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_stages = &pipeline_shade_stage_create_info,
        .p_vertex_input_state = &pipeline_vertex_input_state_create_info,
        .p_input_assembly_state = &pipeline_input_assembly_state_create_info,
        .p_viewport_state = &pipeline_viewport_state_create_info,
        .p_rasterization_state = &pipeline_rasterization_state_create_info,
        .p_multisample_state = &pipeline_multisample_state_create_info,
        .p_color_blend_state = &pipeline_color_blend_state_create_info,
        .p_dynamic_state = &pipeline_dynamic_state_create_info,
        .layout = pl,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
        .p_depth_stencil_state = null,
        .p_tessellation_state = null,
        .render_pass = .null_handle,
        .subpass = 0,
        .p_next = &pipeline_rendering_create_info,
    };

    var pipeline: vk.Pipeline = .null_handle;
    if (try context.logical_device.createGraphicsPipelines(.null_handle, 1, @ptrCast(&graphics_pipeline_create_info), null, @ptrCast(&pipeline)) != .success) {
        return error.PipelineCreationFailed;
    }

    const p_handle = pipelines.add_element(.{
        .layout = pl,
        .vert_layout = layout,
        .pipeline = pipeline,
    }) orelse return error.OutOfPipelines;

    return @intCast(p_handle);
}

fn destroy_pipeline(ctx: *anyopaque, handle: Pipeline.Handle) void {
    _ = ctx;

    context.logical_device.deviceWaitIdle() catch {};
    const pd = pipelines.get_element(handle) orelse return;

    context.logical_device.destroyPipeline(pd.pipeline, null);
    context.logical_device.destroyPipelineLayout(pd.layout, null);
}

fn bind_pipeline(ctx: *anyopaque, handle: Pipeline.Handle) void {
    _ = ctx;
    const pd = pipelines.get_element(handle) orelse return;

    command_buffer.bindPipeline(.graphics, pd.pipeline);
    command_buffer.bindDescriptorSets(.graphics, pd.layout, 0, 1, @ptrCast(&descriptor_sets[swapchain.image_index]), 0, null);
}

fn create_mesh(ctx: *anyopaque, pipeline: Pipeline.Handle) anyerror!u32 {
    _ = ctx;

    const m_handle = meshes.add_element(.{
        .pipeline = pipeline,
    }) orelse return error.OutOfMeshes;
    return @intCast(m_handle);
}

fn destroy_mesh(ctx: *anyopaque, handle: u32) void {
    _ = ctx;
    const m_data = meshes.get_element(handle) orelse return;

    if (m_data.built) {
        gc.defer_destroy_buffer(m_data.buffer, m_data.memory) catch unreachable;
    }

    _ = meshes.remove_element(handle);
}

fn update_mesh(ctx: *anyopaque, handle: u32, data: []const u8) void {
    _ = ctx;

    const m_data = meshes.get_element(handle) orelse return;

    var mesh: MeshData = undefined;
    mesh.buffer = context.logical_device.createBuffer(&.{
        .size = data.len,
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch unreachable;

    const mem_reqs = context.logical_device.getBufferMemoryRequirements(mesh.buffer);
    mesh.memory = context.allocate_gpu_buffer(mem_reqs, .{ .device_local_bit = true }) catch unreachable;
    context.logical_device.bindBufferMemory(mesh.buffer, mesh.memory, 0) catch unreachable;

    const staging_buffer = context.logical_device.createBuffer(&.{
        .size = data.len,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch unreachable;
    defer context.logical_device.destroyBuffer(staging_buffer, null);

    const staging_mem_reqs = context.logical_device.getBufferMemoryRequirements(staging_buffer);
    const staging_memory = context.allocate_gpu_buffer(staging_mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true }) catch unreachable;
    defer context.logical_device.freeMemory(staging_memory, null);
    context.logical_device.bindBufferMemory(staging_buffer, staging_memory, 0) catch unreachable;

    {
        const mapped_data = context.logical_device.mapMemory(staging_memory, 0, vk.WHOLE_SIZE, .{}) catch unreachable;
        defer context.logical_device.unmapMemory(staging_memory);

        const gpu_vertices: [*]u8 = @ptrCast(@alignCast(mapped_data));
        @memcpy(gpu_vertices, data);
    }

    var cmdbuf_handle: vk.CommandBuffer = undefined;
    context.logical_device.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf_handle)) catch unreachable;

    const cmdbuf = vk.CommandBufferProxy.init(cmdbuf_handle, context.logical_device.wrapper);

    cmdbuf.beginCommandBuffer(&.{
        .flags = .{ .one_time_submit_bit = true },
    }) catch unreachable;

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = data.len,
    };
    cmdbuf.copyBuffer(staging_buffer, mesh.buffer, 1, @ptrCast(&region));

    const barrier = vk.BufferMemoryBarrier2{
        .src_stage_mask = .{ .copy_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .vertex_input_bit = true },
        .dst_access_mask = .{ .vertex_attribute_read_bit = true },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .buffer = mesh.buffer,
        .offset = 0,
        .size = vk.WHOLE_SIZE,
    };

    const dep = vk.DependencyInfo{
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = @ptrCast(&barrier),
    };

    cmdbuf.pipelineBarrier2(&dep);
    cmdbuf.endCommandBuffer() catch unreachable;

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf_handle),
    };

    context.logical_device.queueSubmit(context.graphics_queue.handle, 1, @ptrCast(&submit_info), .null_handle) catch unreachable;
    context.logical_device.queueWaitIdle(context.graphics_queue.handle) catch unreachable;

    context.logical_device.freeCommandBuffers(command_pool, 1, @ptrCast(&cmdbuf_handle));

    meshes.buffer[handle].? = MeshData{
        .buffer = mesh.buffer,
        .memory = mesh.memory,
        .pipeline = m_data.pipeline,
        .built = true,
    };
}

fn draw_mesh(ctx: *anyopaque, handle: u32, model: *const zm.Mat, count: usize) void {
    _ = ctx;

    const m_data = meshes.get_element(handle) orelse return;
    const p_data = pipelines.get_element(m_data.pipeline) orelse return;

    const offset = [_]vk.DeviceSize{0};
    command_buffer.bindVertexBuffers(0, 1, @ptrCast(&m_data.buffer), &offset);
    command_buffer.pushConstants(p_data.layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(zm.Mat), model);
    command_buffer.draw(@intCast(count), 1, 0, 0);
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
