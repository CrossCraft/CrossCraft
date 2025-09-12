const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vulkan");
const Util = @import("../../../util/util.zig");

// GLFW function pointers
extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;
extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *glfw.Window, allocation_callbacks: ?*const vk.AllocationCallbacks, surface: *vk.SurfaceKHR) vk.Result;

const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;
const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;

const required_device_extensions = [_][*:0]const u8{ vk.extensions.khr_swapchain.name, vk.extensions.khr_synchronization_2.name, vk.extensions.khr_create_renderpass_2.name };

const Self = @This();

allocator: std.mem.Allocator,
vkb: BaseWrapper,
instance: Instance,
surface: vk.SurfaceKHR,
physical_device: vk.PhysicalDevice,
physical_properties: vk.PhysicalDeviceProperties,
logical_device: Device,
graphics_queue: Queue,
present_queue: Queue,
memory_properties: vk.PhysicalDeviceMemoryProperties,

fn create_instance(self: *Self, name: [:0]const u8) !void {
    // Initialize Vulkan instance
    self.vkb = vk.BaseWrapper.load(glfwGetInstanceProcAddress);

    // Setup extensions
    var extension_names: std.ArrayList([*:0]const u8) = .empty;
    defer extension_names.deinit(self.allocator);

    // Setup validation layers
    const enable_validation = false; // builtin.mode == .Debug;
    const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};

    if (enable_validation) {
        try extension_names.append(self.allocator, vk.extensions.ext_debug_utils.name);
    }

    try extension_names.append(self.allocator, vk.extensions.khr_portability_enumeration.name);
    try extension_names.append(self.allocator, vk.extensions.khr_get_physical_device_properties_2.name);

    // Get required GLFW extensions
    var glfw_exts_count: u32 = 0;
    const glfw_exts = glfw.getRequiredInstanceExtensions(&glfw_exts_count) orelse @panic("Failed to get GLFW extensions");
    try extension_names.appendSlice(self.allocator, @ptrCast(glfw_exts[0..glfw_exts_count]));

    // Create an instance
    var instance_create_info: vk.InstanceCreateInfo = .{
        .p_application_info = &.{
            .p_application_name = name,
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .p_engine_name = name,
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_4),
        },
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = extension_names.items.ptr,
        .flags = .{ .enumerate_portability_bit_khr = true },
    };

    // With validation layers?
    if (enable_validation) {
        instance_create_info.enabled_layer_count = @intCast(validation_layers.len);
        instance_create_info.pp_enabled_layer_names = @ptrCast(&validation_layers);
    }

    const instance = try self.vkb.createInstance(&instance_create_info, null);
    const vki = try self.allocator.create(vk.InstanceWrapper);
    vki.* = InstanceWrapper.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr.?);
    self.instance = Instance.init(instance, vki);
}

const Surface = @import("../surface.zig");
const gfx = @import("../../gfx.zig");
fn create_surface(self: *Self) !void {
    // Create a window surface
    if (glfwCreateWindowSurface(self.instance.handle, @as(*Surface, @ptrCast(@alignCast(gfx.surface.ptr))).window, null, &self.surface) != .success) {
        return error.SurfaceInitFailed;
    }
}

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

fn pick_device(self: *Self) !DeviceCandidate {
    const physical_devices = try self.instance.enumeratePhysicalDevicesAlloc(self.allocator);
    defer self.allocator.free(physical_devices);

    for (physical_devices) |p_device| {
        if (try self.is_device_suitable(p_device)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDeviceFound;
}

fn is_device_suitable(self: *Self, p_device: vk.PhysicalDevice) !?DeviceCandidate {
    if (!try self.check_device_extensions_support(p_device)) {
        return null;
    }

    if (!try self.check_device_surface_support(p_device)) {
        return null;
    }

    if (try self.allocate_queues(p_device)) |allocation| {
        const props = self.instance.getPhysicalDeviceProperties(p_device);
        return DeviceCandidate{
            .pdev = p_device,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

fn check_device_extensions_support(self: *Self, p_device: vk.PhysicalDevice) !bool {
    const properties_list = try self.instance.enumerateDeviceExtensionPropertiesAlloc(p_device, null, self.allocator);
    defer self.allocator.free(properties_list);

    for (required_device_extensions) |ext| {
        for (properties_list) |properties| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&properties.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}

fn check_device_surface_support(self: *Self, p_device: vk.PhysicalDevice) !bool {
    var format_count: u32 = undefined;
    _ = try self.instance.getPhysicalDeviceSurfaceFormatsKHR(p_device, self.surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try self.instance.getPhysicalDeviceSurfacePresentModesKHR(p_device, self.surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn allocate_queues(self: *Self, p_device: vk.PhysicalDevice) !?QueueAllocation {
    const families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(p_device, self.allocator);
    defer self.allocator.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try self.instance.getPhysicalDeviceSurfaceSupportKHR(p_device, family, self.surface)) == .true) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}

fn device_name(self: *const Self) []const u8 {
    return std.mem.sliceTo(&self.physical_properties.device_name, 0);
}

fn create_logical_device(self: *Self, candidate: *const DeviceCandidate) !void {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1
    else
        2;

    // Physical device feature enablement
    // Base features2
    var features = vk.PhysicalDeviceFeatures2{ .features = .{} };
    self.instance.getPhysicalDeviceFeatures2(self.physical_device, &features);

    // Vulkan 1.2 features (descriptor indexing & friends)
    var vulkan12_features = vk.PhysicalDeviceVulkan12Features{};
    // master switch for descriptor indexing block
    vulkan12_features.descriptor_indexing = .true;
    // bindless / runtime-sized arrays
    vulkan12_features.runtime_descriptor_array = .true;
    vulkan12_features.descriptor_binding_variable_descriptor_count = .true;
    vulkan12_features.descriptor_binding_partially_bound = .true;
    vulkan12_features.descriptor_binding_sampled_image_update_after_bind = .true;
    vulkan12_features.descriptor_binding_update_unused_while_pending = .true;
    vulkan12_features.shader_sampled_image_array_non_uniform_indexing = .true;

    // Vulkan 1.3 features
    var vulkan13_features = vk.PhysicalDeviceVulkan13Features{};
    vulkan13_features.dynamic_rendering = .true;
    vulkan13_features.synchronization_2 = .true;

    var extended_dynamic_state_features = vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT{};
    extended_dynamic_state_features.extended_dynamic_state = .true;

    // pNext chain: features -> v1.2 -> v1.3 -> ext dyn state
    vulkan13_features.p_next = &extended_dynamic_state_features;
    vulkan12_features.p_next = &vulkan13_features;
    features.p_next = &vulkan12_features;
    // Create the device with the aforementioned features
    const device = try self.instance.createDevice(candidate.pdev, &.{
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        .p_next = &features,
    }, null);

    const vkd = try self.allocator.create(DeviceWrapper);
    errdefer self.allocator.destroy(vkd);
    vkd.* = DeviceWrapper.load(device, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);

    self.logical_device = Device.init(device, vkd);
}

pub fn allocate_gpu_buffer(self: *Self, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
    return try self.logical_device.allocateMemory(&.{
        .allocation_size = requirements.size,
        .memory_type_index = try self.find_memory_type_index(requirements.memory_type_bits, flags),
    }, null);
}

pub fn find_memory_type_index(self: *Self, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (self.memory_properties.memory_types[0..self.memory_properties.memory_type_count], 0..) |mem_type, i| {
        if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
            return @truncate(i);
        }
    }

    return error.NoSuitableMemoryType;
}

pub fn init(allocator: std.mem.Allocator, name: [:0]const u8) !Self {
    var self: Self = undefined;
    self.allocator = allocator;

    try self.create_instance(name);
    Util.engine_logger.debug("Vulkan 1.4 Loaded!", .{});
    errdefer allocator.destroy(self.instance.wrapper);

    try self.create_surface();
    errdefer self.instance.destroySurfaceKHR(self.surface, null);

    const device_candidate = try self.pick_device();
    self.physical_device = device_candidate.pdev;
    self.physical_properties = device_candidate.props;

    Util.engine_logger.debug("Selected GPU: {s}", .{self.device_name()});

    try self.create_logical_device(&device_candidate);
    errdefer self.logical_device.destroyDevice(null);

    self.graphics_queue = Queue.init(self.logical_device, device_candidate.queues.graphics_family);
    self.present_queue = Queue.init(self.logical_device, device_candidate.queues.present_family);
    self.memory_properties = self.instance.getPhysicalDeviceMemoryProperties(self.physical_device);

    return self;
}

pub fn deinit(self: *Self) void {
    self.logical_device.destroyDevice(null);

    self.instance.destroySurfaceKHR(self.surface, null);
    self.instance.destroyInstance(null);

    self.allocator.destroy(self.logical_device.wrapper);
    self.allocator.destroy(self.instance.wrapper);
}
