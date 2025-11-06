pub const Domain = opaque {};
pub const Thread = opaque {};
pub const Assembly = opaque {};
pub const AssemblyName = opaque {};
pub const Image = opaque {};
pub const Class = opaque {};
pub const Method = opaque {};
pub const MethodSignature = opaque {};
pub const Type = opaque {};
pub const Object = opaque {};

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

    method_get_flags: *const fn (*const Method, iflags: ?*MethodFlags) callconv(.c) MethodFlags,
    method_signature: *const fn (*const Method) callconv(.c) ?*const MethodSignature,
    method_get_class: *const fn (*const Method) callconv(.c) ?*const Class,

    signature_get_return_type: *const fn (*const MethodSignature) callconv(.c) ?*const Type,
    signature_get_params: *const fn (*const MethodSignature, iter: *?*anyopaque) callconv(.c) ?*const Type,

    type_get_type: *const fn (*const Type) callconv(.c) TypeKind,

    object_new: *const fn (*const Domain, *const Class) callconv(.c) ?*const Object,
    runtime_invoke: *const fn (*const Method, obj: ?*anyopaque, params: ?**anyopaque, exception: ?**const Object) callconv(.c) ?*const Object,
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
            .method_get_flags = try monoload.get(mod, .method_get_flags, proc_ref),
            .method_get_class = try monoload.get(mod, .method_get_class, proc_ref),
            .signature_get_return_type = try monoload.get(mod, .signature_get_return_type, proc_ref),
            .signature_get_params = try monoload.get(mod, .signature_get_params, proc_ref),
            .type_get_type = try monoload.get(mod, .type_get_type, proc_ref),
            .object_new = try monoload.get(mod, .object_new, proc_ref),
            .runtime_invoke = try monoload.get(mod, .runtime_invoke, proc_ref),
        };
    }
};

pub const MethodFlags = packed struct(u32) {
    protection: enum(u3) {
        compiler_controlled = 0x0, // 000
        private = 0x1, // 001
        fam_and_assem = 0x2, // 010 - family AND assembly (internal protected)
        assem = 0x3, // 011 - assembly (internal)
        family = 0x4, // 100 - family (protected)
        fam_or_assem = 0x5, // 101 - family OR assembly (protected internal)
        public = 0x6, // 110
    },
    unused1: bool = false,
    static: bool = false,
    final: bool = false,
    virtual: bool = false,
    hide_by_sig: bool = false,
    unused2: u2 = 0,
    abstract: bool = false,
    special_name: bool = false,
    unused3: u20 = 0,
};

pub const TypeKind = enum(c_int) {
    end = 0x00, // end of list */
    void = 0x01,
    boolean = 0x02,
    char = 0x03,
    i1 = 0x04,
    u1 = 0x05,
    i2 = 0x06,
    u2 = 0x07,
    i4 = 0x08,
    u4 = 0x09,
    i8 = 0x0a,
    u8 = 0x0b,
    r4 = 0x0c,
    r8 = 0x0d,
    string = 0x0e,
    ptr = 0x0f, // arg: <type> token */
    byref = 0x10, // arg: <type> token */
    valuetype = 0x11, // arg: <type> token */
    class = 0x12, // arg: <type> token */
    @"var" = 0x13, // number */
    array = 0x14, // type, rank, boundscount, bound1, locount, lo1 */
    genericinst = 0x15, // <type> <type-arg-count> <type-1> \x{2026} <type-n> */
    typedbyref = 0x16,
    i = 0x18,
    u = 0x19,
    fnptr = 0x1b, // arg: full method signature */
    object = 0x1c,
    szarray = 0x1d, // 0-based one-dim-array */
    mvar = 0x1e, // number */
    cmod_reqd = 0x1f, // arg: typedef or typeref token */
    cmod_opt = 0x20, // optional arg: typedef or typref token */
    internal = 0x21, // clr internal type */

    modifier = 0x40, // or with the following types */
    sentinel = 0x41, // sentinel for varargs method signature */
    pinned = 0x45, // local var that points to pinned object */

    @"enum" = 0x55, // an enumeration */
    _,
};

const win32 = @import("win32").everything;
const monoload = @import("monoload.zig").template(Funcs);
