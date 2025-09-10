const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vulkan");
const Context = @import("context.zig");

const Self = @This();

pub const PresentState = enum {
    optimal,
    suboptimal,
};

context: *Context,
surface_capabilities: vk.SurfaceCapabilitiesKHR,
chain: vk.SwapchainKHR,
surface_format: vk.SurfaceFormatKHR,
swap_images: []SwapImage,
next_image_acquired: vk.Semaphore,
image_index: u32,

fn choose_swap_surface_format(self: *Self) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };

    const surface_formats = try self.context.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
        self.context.physical_device,
        self.context.surface,
        self.context.allocator,
    );
    defer self.context.allocator.free(surface_formats);

    for (surface_formats) |sfmt| {
        if (std.meta.eql(sfmt, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // There must always be at least one supported surface format
}

const Surface = @import("../surface.zig");
const gfx = @import("../../gfx.zig");
fn choose_swap_extent(self: *Self) !vk.Extent2D {
    const surface_capabilities = self.surface_capabilities;

    // Choose the swap extent
    const width = std.math.clamp(gfx.surface.get_width(), surface_capabilities.min_image_extent.width, surface_capabilities.max_image_extent.width);
    const height = std.math.clamp(gfx.surface.get_height(), surface_capabilities.min_image_extent.height, surface_capabilities.max_image_extent.height);

    return vk.Extent2D{
        .width = width,
        .height = height,
    };
}

fn choose_present_mode(self: *Self) !vk.PresentModeKHR {
    const present_modes = try self.context.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
        self.context.physical_device,
        self.context.surface,
        self.context.allocator,
    );
    defer self.context.allocator.free(present_modes);

    const preferred = [_]vk.PresentModeKHR{
        .mailbox_khr,
        .immediate_khr,
    };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .fifo_khr;
}

fn create_swapchain(self: *Self, old_handle: vk.SwapchainKHR) !void {
    self.surface_capabilities = try self.context.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
        self.context.physical_device,
        self.context.surface,
    );

    const surface_format = try self.choose_swap_surface_format();
    const surface_extent = try self.choose_swap_extent();
    const present_mode = try self.choose_present_mode();

    // We want triple buffering so...
    var image_count = @max(3, self.surface_capabilities.min_image_count);
    image_count = if (self.surface_capabilities.max_image_count > 0 and image_count > self.surface_capabilities.max_image_count) self.surface_capabilities.max_image_count else image_count;

    const qfi = [_]u32{ self.context.graphics_queue.family, self.context.present_queue.family };
    const sharing_mode: vk.SharingMode = if (self.context.graphics_queue.family != self.context.present_queue.family)
        .concurrent
    else
        .exclusive;

    self.chain = self.context.logical_device.createSwapchainKHR(&.{
        .surface = self.context.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = surface_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = sharing_mode,
        .pre_transform = self.surface_capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = .true,
        .queue_family_index_count = qfi.len,
        .p_queue_family_indices = &qfi,
        .old_swapchain = old_handle,
    }, null) catch return error.SwapchainCreationFailed;

    self.surface_format = surface_format;

    // Destroy the old swapchain if it exists
    if (old_handle != .null_handle) {
        self.context.logical_device.destroySwapchainKHR(old_handle, null);
    }

    self.swap_images = try self.create_swapchain_images(surface_format.format);
    errdefer self.destroy_swapchain_images();

    var next_image_acquired = try self.context.logical_device.createSemaphore(&.{}, null);
    errdefer self.context.logical_device.destroySemaphore(next_image_acquired, null);

    const timeout_ns: u64 = 100_000_000; // 100ms
    const result = try self.context.logical_device.acquireNextImageKHR(self.chain, timeout_ns, next_image_acquired, .null_handle);

    if (result.result == .not_ready or result.result == .timeout) {
        return error.ImageAcquireFailed;
    }

    std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &next_image_acquired);
    self.next_image_acquired = next_image_acquired;
    self.image_index = result.image_index;
}

fn destroy_swapchain_images(self: *Self) void {
    for (self.swap_images) |si| si.deinit(self.context);
    self.context.allocator.free(self.swap_images);
    self.context.logical_device.destroySemaphore(self.next_image_acquired, null);
}

fn create_swapchain_images(self: *Self, format: vk.Format) ![]SwapImage {
    const images = try self.context.logical_device.getSwapchainImagesAllocKHR(self.chain, self.context.allocator);
    defer self.context.allocator.free(images);

    const swap_images = try self.context.allocator.alloc(SwapImage, images.len);
    errdefer self.context.allocator.free(swap_images);

    var i: usize = 0;
    errdefer for (swap_images[0..i]) |si| si.deinit(self.context);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(self.context, image, format);
        i += 1;
    }

    return swap_images;
}

pub fn init(context: *Context) !Self {
    var self: Self = undefined;
    self.context = context;

    try self.create_swapchain(.null_handle);

    return self;
}

pub fn recreate(self: *Self) !void {
    const context = self.context;
    const old_handle = self.chain;

    self.destroy_swapchain_images();
    // set current handle to NULL_HANDLE to signal that the current swapchain does no longer need to be
    // de-initialized if we fail to recreate it.
    self.chain = .null_handle;
    self.create_swapchain(old_handle) catch |err| switch (err) {
        error.SwapchainCreationFailed => {
            context.logical_device.destroySwapchainKHR(old_handle, null);
            return err;
        },
        else => return err,
    };
}

pub fn deinit(self: *Self) void {
    if (self.chain == .null_handle) return;
    self.destroy_swapchain_images();
    self.context.logical_device.destroySwapchainKHR(self.chain, null);
}

pub fn currentImage(self: *Self) vk.Image {
    return self.swap_images[self.image_index].image;
}

pub fn currentSwapImage(self: *Self) *const SwapImage {
    return &self.swap_images[self.image_index];
}

pub fn present(self: *Self, cmdbuf: vk.CommandBuffer) !PresentState {
    // // Step 1: Make sure the current frame has finished rendering
    const current = self.currentSwapImage();

    // Step 2: Submit the command buffer
    const wait_stage = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
    try self.context.logical_device.queueSubmit(self.context.graphics_queue.handle, 1, &[_]vk.SubmitInfo{.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&current.image_acquired),
        .p_wait_dst_stage_mask = &wait_stage,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&current.render_finished),
    }}, current.frame_fence);

    // Step 3: Present the current frame
    _ = try self.context.logical_device.queuePresentKHR(self.context.present_queue.handle, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&current.render_finished),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.chain),
        .p_image_indices = @ptrCast(&self.image_index),
    });

    // Step 4: Acquire next frame
    const result = try self.context.logical_device.acquireNextImageKHR(
        self.chain,
        std.math.maxInt(u64),
        self.next_image_acquired,
        .null_handle,
    );

    std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &self.next_image_acquired);
    self.image_index = result.image_index;

    return switch (result.result) {
        .success => .optimal,
        .suboptimal_khr => .suboptimal,
        else => unreachable,
    };
}

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,

    fn init(context: *const Context, image: vk.Image, format: vk.Format) !SwapImage {
        const view = try context.logical_device.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer context.logical_device.destroyImageView(view, null);

        const image_acquired = try context.logical_device.createSemaphore(&.{}, null);
        errdefer context.logical_device.destroySemaphore(image_acquired, null);

        const render_finished = try context.logical_device.createSemaphore(&.{}, null);
        errdefer context.logical_device.destroySemaphore(render_finished, null);

        const frame_fence = try context.logical_device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer context.logical_device.destroyFence(frame_fence, null);

        return SwapImage{
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: SwapImage, context: *const Context) void {
        self.waitForFence(context) catch return;
        context.logical_device.destroyImageView(self.view, null);
        context.logical_device.destroySemaphore(self.image_acquired, null);
        context.logical_device.destroySemaphore(self.render_finished, null);
        context.logical_device.destroyFence(self.frame_fence, null);
    }

    fn waitForFence(self: SwapImage, context: *const Context) !void {
        _ = try context.logical_device.waitForFences(1, @ptrCast(&self.frame_fence), .true, std.math.maxInt(u64));
    }
};
