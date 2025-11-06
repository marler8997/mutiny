pub const Domain = opaque {};
pub const Thread = opaque {};
pub const Assembly = opaque {};
pub const AssemblyName = opaque {};
pub const Image = opaque {};
pub const Class = opaque {};
pub const Method = opaque {};
pub const MethodSignature = opaque {};
pub const Type = opaque {};

pub const Callback = fn (data: *anyopaque, user_data: ?*anyopaque) callconv(.c) void;

pub const Funcs = struct {
    get_root_domain: *const fn () callconv(.c) ?*const Domain,
    thread_attach: *const fn (?*const Domain) callconv(.c) ?*const Thread,
    // domain_assembly_open: *const fn (*const Domain, [*:0]const u8) callconv(.c) ?*const Assembly,

    assembly_foreach: *const fn (func: *const Callback, user_data: ?*anyopaque) callconv(.c) void,
    assembly_get_name: *const fn (*const Assembly) callconv(.c) ?*const AssemblyName,
    assembly_get_image: *const fn (*const Assembly) callconv(.c) ?*const Image,
    assembly_name_get_name: *const fn (*const AssemblyName) callconv(.c) ?[*:0]const u8,

    class_from_name: *const fn (*const Image, namespace: [*:0]const u8, name: [*:0]const u8) callconv(.c) ?*const Class,
    class_get_method_from_name: *const fn (*const Class, [*:0]const u8, param_count: c_int) callconv(.c) ?*const Method,

    method_signature: *const fn (*const Method) callconv(.c) ?*const MethodSignature,

    signature_get_params: *const fn (*const MethodSignature, iter: *?*anyopaque) callconv(.c) ?*const Type,
    pub fn init(proc_ref: *[:0]const u8, mod: win32.HINSTANCE) error{ProcNotFound}!Funcs {
        return .{
            .get_root_domain = try monoload.get(mod, .get_root_domain, proc_ref),
            .thread_attach = try monoload.get(mod, .thread_attach, proc_ref),
            // .domain_assembly_open = try monoload.get(mod, .domain_assembly_open, proc_ref),
            .assembly_foreach = try monoload.get(mod, .assembly_foreach, proc_ref),
            .assembly_get_name = try monoload.get(mod, .assembly_get_name, proc_ref),
            .assembly_get_image = try monoload.get(mod, .assembly_get_image, proc_ref),
            .assembly_name_get_name = try monoload.get(mod, .assembly_name_get_name, proc_ref),
            .class_from_name = try monoload.get(mod, .class_from_name, proc_ref),
            .class_get_method_from_name = try monoload.get(mod, .class_get_method_from_name, proc_ref),
            .method_signature = try monoload.get(mod, .method_signature, proc_ref),
        };
    }
};

const win32 = @import("win32").everything;
const monoload = @import("monoload.zig").template(Funcs);
