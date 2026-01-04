pub const Kind = dotnetkind.Kind;
pub const dll_name_mono = dotnetkind.dll_name_mono;
pub const dll_name_il2cpp = dotnetkind.dll_name_il2cpp;

pub const Domain = opaque {};
pub const Thread = opaque {};
pub const Assembly = opaque {};
pub const AssemblyName = opaque {};
pub const Image = opaque {};
pub const Class = opaque {};
pub const Method = opaque {};
pub const MethodSignature = opaque {};
pub const VTable = opaque {};
pub const ClassField = opaque {};
pub const Type = opaque {};
pub const Object = opaque {};
// V1 of the GC handle API will will crash if you call get_target on a
// new handle on the game "PEAK" which uses mono.
pub const GcHandleV1 = enum(u32) {
    null = 0,
    _,
    pub fn fromV2(handle: GcHandleV2) GcHandleV1 {
        return @enumFromInt(@intFromEnum(handle));
    }
    pub fn toV2(handle: GcHandleV1) GcHandleV2 {
        return @enumFromInt(@intFromEnum(handle));
    }
};
pub const GcHandleV2 = enum(usize) { null = 0, _ };
pub const String = opaque {};

pub const Callback = fn (data: *anyopaque, user_data: ?*anyopaque) callconv(.c) void;

const MonoFuncs = struct {
    assembly_foreach: *const fn (func: *const Callback, user_data: ?*anyopaque) callconv(.c) void,
    assembly_get_name: *const fn (*const Assembly) callconv(.c) ?*const AssemblyName,
    assembly_name_get_name: *const fn (*const AssemblyName) callconv(.c) ?[*:0]const u8,
    class_vtable: *const fn (*const Domain, *const Class) callconv(.c) *const VTable,
    field_static_get_value: *const fn (*const VTable, *const ClassField, out_value: *anyopaque) callconv(.c) void,
    field_static_set_value: *const fn (*const VTable, *const ClassField, value: *const anyopaque) callconv(.c) void,
    method_signature: *const fn (*const Method) callconv(.c) ?*const MethodSignature,
    signature_get_return_type: *const fn (*const MethodSignature) callconv(.c) ?*const Type,
    signature_get_params: *const fn (*const MethodSignature, iter: *?*anyopaque) callconv(.c) ?*const Type,
    // V1 of the GC handle API will will crash if you call get_target on a new handle on the game PEAK
    // gchandle_new: *const fn (*const Object, pinned: i32) callconv(.c) GcHandle,
    // gchandle_free: *const fn (handle: GcHandle) callconv(.c) void,
    // gchandle_get_target: *const fn (handle: GcHandle) callconv(.c) *const Object,
    gchandle_new_v2: *const fn (*const Object, pinned: i32) callconv(.c) GcHandleV2,
    gchandle_free_v2: *const fn (handle: GcHandleV2) callconv(.c) void,
    gchandle_get_target_v2: *const fn (handle: GcHandleV2) callconv(.c) *const Object,
    string_to_utf8: *const fn (*const Object) callconv(.c) ?[*:0]const u8,
};

const Il2cppFuncs = struct {
    domain_get_assemblies: *const fn (*const Domain, size: *usize) callconv(.c) [*]const *const Assembly,
    image_get_name: *const fn (*const Image) callconv(.c) [*:0]const u8,
    assembly_get_image: *const fn (*const Assembly) callconv(.c) *const Image,
    field_static_get_value: *const fn (*const ClassField, out_value: *anyopaque) callconv(.c) void,
    field_static_set_value: *const fn (*const ClassField, value: *const anyopaque) callconv(.c) void,
    method_get_return_type: *const fn (*const Method) callconv(.c) ?*const Type,
    gchandle_new: *const fn (*const Object, pinned: i32) callconv(.c) GcHandleV1,
    gchandle_free: *const fn (handle: GcHandleV1) callconv(.c) void,
    gchandle_get_target: *const fn (handle: GcHandleV1) callconv(.c) *const Object,
};

pub const Funcs = struct {
    get_root_domain: *const fn () callconv(.c) ?*const Domain,
    domain_get: *const fn () callconv(.c) ?*const Domain,
    thread_attach: *const fn (*const Domain) callconv(.c) ?*const Thread,
    thread_detach: *const fn (*const Thread) callconv(.c) void,

    kind: union(Kind) {
        mono: MonoFuncs,
        il2cpp: Il2cppFuncs,
    },

    assembly_get_image: *const fn (*const Assembly) callconv(.c) ?*const Image,

    class_from_name: *const fn (*const Image, namespace: [*:0]const u8, name: [*:0]const u8) callconv(.c) ?*const Class,
    class_get_name: *const fn (*const Class) callconv(.c) [*:0]const u8,
    class_get_namespace: *const fn (*const Class) callconv(.c) [*:0]const u8,
    class_get_fields: *const fn (*const Class, iterator: *?*anyopaque) callconv(.c) ?*const ClassField,
    class_get_methods: *const fn (*const Class, iterator: *?*anyopaque) callconv(.c) ?*const Method,
    class_get_method_from_name: *const fn (*const Class, [*:0]const u8, param_count: c_int) callconv(.c) ?*const Method,
    class_get_field_from_name: *const fn (*const Class, [*:0]const u8) callconv(.c) ?*const ClassField,

    field_get_flags: *const fn (*const ClassField) callconv(.c) ClassFieldFlags,
    field_get_name: *const fn (*const ClassField) callconv(.c) [*:0]const u8,
    field_get_type: *const fn (*const ClassField) callconv(.c) *const Type,
    field_get_value: *const fn (*const Object, *const ClassField, out_value: *anyopaque) callconv(.c) void,
    field_set_value: *const fn (*const Object, *const ClassField, value: *const anyopaque) callconv(.c) void,

    method_get_flags: *const fn (*const Method, iflags: ?*MethodFlags) callconv(.c) MethodFlags,
    method_get_name: *const fn (*const Method) callconv(.c) [*:0]const u8,
    method_get_class: *const fn (*const Method) callconv(.c) ?*const Class,

    type_get_type: *const fn (*const Type) callconv(.c) TypeKind,

    object_new: *const fn (*const Domain, *const Class) callconv(.c) ?*const Object,
    object_unbox: *const fn (*const Object) callconv(.c) *anyopaque,
    object_get_class: *const fn (*const Object) callconv(.c) *const Class,

    runtime_invoke: *const fn (*const Method, obj: ?*const Object, params: ?**anyopaque, exception: ?*?*const Object) callconv(.c) ?*const Object,

    string_new_len: *const fn (*const Domain, text: [*]const u8, len: c_uint) callconv(.c) ?*const String,
    string_chars: *const fn (*const String) callconv(.c) [*]const u16,
    string_length: *const fn (*const String) callconv(.c) c_int,

    free: *const fn (*anyopaque) callconv(.c) void,
    pub fn init(proc_ref: *[:0]const u8, kind: Kind, mod: win32.HINSTANCE) error{ProcNotFound}!Funcs {
        return .{
            .get_root_domain = try funcs.monoGet(mod, .get_root_domain, proc_ref),
            .domain_get = try funcs.monoGet(mod, .domain_get, proc_ref),
            .thread_attach = try funcs.monoGet(mod, .thread_attach, proc_ref),
            .thread_detach = try funcs.monoGet(mod, .thread_detach, proc_ref),
            .assembly_get_image = try funcs.sharedGet(kind, mod, .assembly_get_image, proc_ref),
            .class_from_name = try funcs.sharedGet(kind, mod, .class_from_name, proc_ref),
            .class_get_name = try funcs.monoGet(mod, .class_get_name, proc_ref),
            .class_get_namespace = try funcs.monoGet(mod, .class_get_namespace, proc_ref),
            .class_get_fields = try funcs.sharedGet(kind, mod, .class_get_fields, proc_ref),
            .class_get_methods = try funcs.monoGet(mod, .class_get_methods, proc_ref),
            .class_get_method_from_name = try funcs.sharedGet(kind, mod, .class_get_method_from_name, proc_ref),
            .class_get_field_from_name = try funcs.sharedGet(kind, mod, .class_get_field_from_name, proc_ref),
            .field_get_flags = try funcs.sharedGet(kind, mod, .field_get_flags, proc_ref),
            .field_get_name = try funcs.monoGet(mod, .field_get_name, proc_ref),
            .field_get_type = try funcs.monoGet(mod, .field_get_type, proc_ref),
            .field_get_value = try funcs.sharedGet(kind, mod, .field_get_value, proc_ref),
            .field_set_value = try funcs.monoGet(mod, .field_set_value, proc_ref),
            .method_get_name = try funcs.monoGet(mod, .method_get_name, proc_ref),
            .method_get_flags = try funcs.monoGet(mod, .method_get_flags, proc_ref),
            .method_get_class = try funcs.monoGet(mod, .method_get_class, proc_ref),
            .type_get_type = try funcs.monoGet(mod, .type_get_type, proc_ref),
            .object_new = try funcs.sharedGet(kind, mod, .object_new, proc_ref),
            .object_unbox = try funcs.sharedGet(kind, mod, .object_unbox, proc_ref),
            .object_get_class = try funcs.sharedGet(kind, mod, .object_get_class, proc_ref),
            // .gchandle_new = try funcs.monoGet(mod, .gchandle_new, proc_ref),
            // .gchandle_free = try funcs.monoGet(mod, .gchandle_free, proc_ref),
            // .gchandle_get_target = try funcs.monoGet(mod, .gchandle_get_target, proc_ref),
            .runtime_invoke = try funcs.sharedGet(kind, mod, .runtime_invoke, proc_ref),
            .string_new_len = try funcs.sharedGet(kind, mod, .string_new_len, proc_ref),
            .string_chars = try funcs.monoGet(mod, .string_chars, proc_ref),
            .string_length = try funcs.monoGet(mod, .string_length, proc_ref),
            .free = try funcs.sharedGet(kind, mod, .free, proc_ref),
            .kind = switch (kind) {
                .mono => .{ .mono = .{
                    .assembly_foreach = try mono_funcs.monoGet(mod, .assembly_foreach, proc_ref),
                    .assembly_get_name = try mono_funcs.monoGet(mod, .assembly_get_name, proc_ref),
                    .assembly_name_get_name = try mono_funcs.monoGet(mod, .assembly_name_get_name, proc_ref),
                    .class_vtable = try mono_funcs.monoGet(mod, .class_vtable, proc_ref),
                    .field_static_get_value = try mono_funcs.monoGet(mod, .field_static_get_value, proc_ref),
                    .field_static_set_value = try mono_funcs.monoGet(mod, .field_static_set_value, proc_ref),
                    .method_signature = try mono_funcs.monoGet(mod, .method_signature, proc_ref),
                    .signature_get_return_type = try mono_funcs.monoGet(mod, .signature_get_return_type, proc_ref),
                    .signature_get_params = try mono_funcs.monoGet(mod, .signature_get_params, proc_ref),
                    .gchandle_new_v2 = try mono_funcs.monoGet(mod, .gchandle_new_v2, proc_ref),
                    .gchandle_free_v2 = try mono_funcs.monoGet(mod, .gchandle_free_v2, proc_ref),
                    .gchandle_get_target_v2 = try mono_funcs.monoGet(mod, .gchandle_get_target_v2, proc_ref),
                    .string_to_utf8 = try mono_funcs.monoGet(mod, .string_to_utf8, proc_ref),
                } },
                .il2cpp => .{
                    .il2cpp = .{
                        .domain_get_assemblies = try il2cpp_funcs.il2cppGet(mod, .domain_get_assemblies, proc_ref),
                        .image_get_name = try il2cpp_funcs.il2cppGet(mod, .image_get_name, proc_ref),
                        .assembly_get_image = try il2cpp_funcs.il2cppGet(mod, .assembly_get_image, proc_ref),
                        .field_static_get_value = try il2cpp_funcs.il2cppGet(mod, .field_static_get_value, proc_ref),
                        .field_static_set_value = try il2cpp_funcs.il2cppGet(mod, .field_static_set_value, proc_ref),
                        .method_get_return_type = try il2cpp_funcs.il2cppGet(mod, .method_get_return_type, proc_ref),
                        .gchandle_new = try il2cpp_funcs.il2cppGet(mod, .gchandle_new, proc_ref),
                        .gchandle_free = try il2cpp_funcs.il2cppGet(mod, .gchandle_free, proc_ref),
                        .gchandle_get_target = try il2cpp_funcs.il2cppGet(mod, .gchandle_get_target, proc_ref),
                    },
                },
            },
        };
    }
};

pub const Protection = enum(u3) {
    compiler_controlled = 0x0, // 000
    private = 0x1, // 001
    fam_and_assem = 0x2, // 010 - family AND assembly (internal protected)
    assem = 0x3, // 011 - assembly (internal)
    family = 0x4, // 100 - family (protected)
    fam_or_assem = 0x5, // 101 - family OR assembly (protected internal)
    public = 0x6, // 110
};

pub const ClassFieldFlags = packed struct(u16) {
    protection: Protection,
    unused1: bool = false,
    static: bool = false, // 0x0008 (Bit 3)
    init_only: bool = false, // 0x0010 (Bit 4) - Equivalent to C# 'readonly'
    literal: bool = false, // 0x0020 (Bit 5) - Equivalent to C# 'const'
    not_serialized: bool = false, // 0x0040 (Bit 6)
    special_name: bool = false, // 0x0080 (Bit 7) - For compiler-generated fields (e.g., backing fields for properties)
    unused2: u2 = 0, // 0x0100, 0x0200
    pin_marshal_rts: bool = false, // 0x0400 (Bit 10) - Field has marshaling information
    has_field_rva: bool = false, // 0x0800 (Bit 11) - Field has a relative virtual address (RVA)
    has_default: bool = false, // 0x1000 (Bit 12) - Field has a default value (e.g., for optional parameters)
    reserved_mask: u2 = 0, // 0x2000, 0x4000, 0x8000 (Bits 13-15) - Reserved flags
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
const dotnetkind = @import("dotnetkind.zig");

const funcs = @import("dotnetload.zig").template(Funcs);
const mono_funcs = @import("dotnetload.zig").template(MonoFuncs);
const il2cpp_funcs = @import("dotnetload.zig").template(Il2cppFuncs);
