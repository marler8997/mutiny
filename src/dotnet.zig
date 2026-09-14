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
pub const MethodHeader = opaque {};
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

pub const MonoImageOpenStatus = enum(c_int) {
    ok = 0,
    error_errno = 1,
    image_invalid = 2,
    missing_assemblyref = 3,
    _,
};

pub const ExportNames = struct {
    mono: ?[:0]const u8 = null,
    il2cpp: ?[:0]const u8 = null,
};

pub const shared = struct {
    pub const domain_get = fn () callconv(.c) ?*const Domain;
    pub const get_root_domain = fn () callconv(.c) ?*const Domain;
    pub const thread_attach = fn (*const Domain) callconv(.c) ?*const Thread;
    pub const thread_detach = fn (*const Thread) callconv(.c) void;

    pub const assembly_get_image = fn (*const Assembly) callconv(.c) ?*const Image;

    pub const class_from_name = fn (*const Image, namespace: [*:0]const u8, name: [*:0]const u8) callconv(.c) ?*const Class;
    pub const class_from_type = fn (*const Type) callconv(.c) ?*const Class;
    pub const class_get_name = fn (*const Class) callconv(.c) [*:0]const u8;
    pub const class_get_parent = fn (*const Class) callconv(.c) ?*const Class;
    pub const class_enum_basetype = fn (*const Class) callconv(.c) *const Type;
    pub const class_get_type = fn (*const Class) callconv(.c) *const Type;
    pub const class_get_namespace = fn (*const Class) callconv(.c) [*:0]const u8;
    pub const class_get_fields = fn (*const Class, iterator: *?*anyopaque) callconv(.c) ?*const ClassField;
    pub const class_get_methods = fn (*const Class, iterator: *?*anyopaque) callconv(.c) ?*const Method;
    pub const class_get_method_from_name = fn (*const Class, [*:0]const u8, param_count: c_int) callconv(.c) ?*const Method;
    pub const class_get_field_from_name = fn (*const Class, [*:0]const u8) callconv(.c) ?*const ClassField;
    pub const class_is_assignable_from = fn (klass: *const Class, oklass: *const Class) callconv(.c) bool;

    pub const field_get_flags = fn (*const ClassField) callconv(.c) ClassFieldFlags;
    pub const field_get_name = fn (*const ClassField) callconv(.c) [*:0]const u8;
    pub const field_get_type = fn (*const ClassField) callconv(.c) *const Type;
    pub const field_get_value = fn (*const Object, *const ClassField, out_value: *anyopaque) callconv(.c) void;
    pub const field_set_value = fn (*const Object, *const ClassField, value: *const anyopaque) callconv(.c) void;

    pub const class_get_flags = fn (*const Class) callconv(.c) ClassFlags;
    pub const class_get_interfaces = fn (*const Class, iterator: *?*anyopaque) callconv(.c) ?*const Class;
    pub const class_get_nested_types = fn (*const Class, iterator: *?*anyopaque) callconv(.c) ?*const Class;

    pub const method_get_flags = fn (*const Method, iflags: ?*MethodImplFlags) callconv(.c) MethodFlags;
    pub const method_get_name = fn (*const Method) callconv(.c) [*:0]const u8;
    pub const method_get_class = fn (*const Method) callconv(.c) ?*const Class;

    pub const type_get_type = fn (*const Type) callconv(.c) TypeKind;
    pub const type_get_name = fn (*const Type) callconv(.c) ?[*:0]u8;

    pub const object_unbox = fn (*const Object) callconv(.c) *anyopaque;
    pub const object_get_class = fn (*const Object) callconv(.c) *const Class;

    pub const runtime_invoke = fn (*const Method, obj: ?*const Object, params: ?**anyopaque, exception: ?*?*const Object) callconv(.c) ?*const Object;

    pub const string_chars = fn (*const String) callconv(.c) [*]const u16;
    pub const string_length = fn (*const String) callconv(.c) c_int;

    pub const free = fn (*anyopaque) callconv(.c) void;

    pub const export_names = struct {
        pub const get_root_domain: ExportNames = .{ .il2cpp = "mono_get_root_domain" };
        pub const class_from_type: ExportNames = .{ .mono = "mono_class_from_mono_type" };
    };
};

pub const mono = struct {
    pub const jit_init = fn (name: [*:0]const u8) callconv(.c) ?*const Domain;
    pub const set_assemblies_path = fn ([*:0]const u8) callconv(.c) void;
    pub const domain_assembly_open = fn (*const Domain, [*:0]const u8) callconv(.c) ?*const Assembly;

    pub const runtime_class_init = fn (*const VTable) callconv(.c) void;
    pub const assembly_foreach = fn (func: *const Callback, user_data: ?*anyopaque) callconv(.c) void;
    pub const assembly_get_name = fn (*const Assembly) callconv(.c) ?*const AssemblyName;
    pub const assembly_name_get_name = fn (*const AssemblyName) callconv(.c) ?[*:0]const u8;
    pub const image_get_filename = fn (*const Image) callconv(.c) ?[*:0]const u8;
    pub const class_vtable = fn (*const Domain, *const Class) callconv(.c) *const VTable;
    pub const field_static_get_value = fn (*const VTable, *const ClassField, out_value: *anyopaque) callconv(.c) void;
    pub const field_static_set_value = fn (*const VTable, *const ClassField, value: *const anyopaque) callconv(.c) void;
    pub const method_signature = fn (*const Method) callconv(.c) ?*const MethodSignature;
    pub const signature_get_return_type = fn (*const MethodSignature) callconv(.c) ?*const Type;
    pub const signature_get_params = fn (*const MethodSignature, iter: *?*anyopaque) callconv(.c) ?*const Type;
    pub const gchandle_new = fn (*const Object, pinned: i32) callconv(.c) GcHandleV1;
    pub const gchandle_free = fn (handle: GcHandleV1) callconv(.c) void;
    pub const gchandle_get_target = fn (handle: GcHandleV1) callconv(.c) *const Object;
    pub const gchandle_new_v2 = fn (*const Object, pinned: i32) callconv(.c) GcHandleV2;
    pub const gchandle_free_v2 = fn (handle: GcHandleV2) callconv(.c) void;
    pub const gchandle_get_target_v2 = fn (handle: GcHandleV2) callconv(.c) *const Object;
    pub const string_new_len = fn (*const Domain, text: [*]const u8, len: c_uint) callconv(.c) ?*const String;
    pub const object_new = fn (*const Domain, *const Class) callconv(.c) ?*const Object;
    pub const type_get_object = fn (*const Domain, *const Type) callconv(.c) ?*const Object;
    pub const image_open_from_data = fn (
        data: [*]const u8,
        data_len: u32,
        need_copy: i32,
        status: *MonoImageOpenStatus,
    ) callconv(.c) ?*const Image;
    pub const assembly_load_from = fn (
        image: *const Image,
        name: [*:0]const u8,
        status: *MonoImageOpenStatus,
    ) callconv(.c) ?*const Assembly;
    pub const add_internal_call = fn (name: [*:0]const u8, method: *const anyopaque) callconv(.c) void;
    pub const class_is_enum = fn (*const Class) callconv(.c) c_int;
    pub const class_is_valuetype = fn (*const Class) callconv(.c) c_int;
    pub const class_get_nesting_type = fn (*const Class) callconv(.c) ?*const Class;
    pub const class_get = fn (*const Image, type_token: u32) callconv(.c) ?*const Class;
    pub const assembly_open = fn (filename: [*:0]const u8, status: *MonoImageOpenStatus) callconv(.c) ?*const Assembly;
    pub const image_get_name = fn (*const Image) callconv(.c) [*:0]const u8;
    pub const image_get_table_info = fn (*const Image, table_id: c_int) callconv(.c) ?*const TableInfo;
    pub const table_info_get_rows = fn (*const TableInfo) callconv(.c) c_int;
    pub const signature_get_param_count = fn (*const MethodSignature) callconv(.c) u32;
    pub const method_get_param_names = fn (*const Method, names: [*]?[*:0]const u8) callconv(.c) void;
    pub const field_get_value_object = fn (*const Domain, *const ClassField, obj: ?*const Object) callconv(.c) ?*const Object;
    pub const get_corlib = fn () callconv(.c) ?*const Image;
    pub const method_get_header = fn (*const Method) callconv(.c) ?*const MethodHeader;
    pub const method_header_get_code = fn (*const MethodHeader, code_size: *u32, max_stack: *u32) callconv(.c) ?[*]const u8;
    pub const metadata_free_mh = fn (*const MethodHeader) callconv(.c) void;
    pub const opcode_value = fn (ip: *[*]const u8, end: [*]const u8) callconv(.c) c_int;
    pub const opcode_name = fn (opcode: c_int) callconv(.c) [*:0]const u8;
    pub const method_header_get_locals = fn (*const MethodHeader, num_locals: *u32, init_locals: *i32) callconv(.c) ?[*]const *const Type;
    pub const method_header_get_clauses = fn (*const MethodHeader, *const Method, iter: *?*anyopaque, clause: *ExceptionClause) callconv(.c) c_int;
    pub const get_method = fn (*const Image, token: u32, class: ?*const Class) callconv(.c) ?*const Method;
    pub const field_from_token = fn (*const Image, token: u32, class: *?*const Class, context: ?*anyopaque) callconv(.c) ?*const ClassField;
    pub const field_get_parent = fn (*const ClassField) callconv(.c) ?*const Class;
    pub const ldtoken = fn (*const Image, token: u32, handle_class: *?*const Class, context: ?*anyopaque) callconv(.c) ?*anyopaque;
    pub const metadata_user_string = fn (*const Image, index: u32) callconv(.c) [*]const u8;
    pub const metadata_decode_blob_size = fn (ptr: [*]const u8, rptr: *[*]const u8) callconv(.c) u32;
};

pub const ExceptionClause = extern struct {
    kind: enum(u32) { @"catch" = 0, filter = 1, finally = 2, fault = 4, _ },
    try_offset: u32,
    try_len: u32,
    handler_offset: u32,
    handler_len: u32,
    data: extern union {
        filter_offset: u32,
        catch_class: ?*const Class,
    },
};

pub const il2cpp = struct {
    pub const init = fn (name: [*:0]const u8) callconv(.c) void;
    pub const set_data_dir = fn (path: [*:0]const u8) callconv(.c) void;
    pub const register_log_callback = fn (*const fn ([*:0]const u8) callconv(.c) void) callconv(.c) void;

    pub const runtime_class_init = fn (*const Class) callconv(.c) void;
    pub const domain_get_assemblies = fn (*const Domain, size: *usize) callconv(.c) [*]const *const Assembly;
    pub const image_get_name = fn (*const Image) callconv(.c) [*:0]const u8;
    pub const image_get_class_count = fn (*const Image) callconv(.c) usize;
    pub const image_get_class = fn (*const Image, index: usize) callconv(.c) *const Class;
    pub const assembly_get_image = fn (*const Assembly) callconv(.c) *const Image;
    pub const field_static_get_value = fn (*const ClassField, out_value: *anyopaque) callconv(.c) void;
    pub const field_static_set_value = fn (*const ClassField, value: *const anyopaque) callconv(.c) void;
    pub const method_get_return_type = fn (*const Method) callconv(.c) ?*const Type;
    pub const method_get_param_count = fn (*const Method) callconv(.c) u32;
    pub const method_get_param = fn (*const Method, index: u32) callconv(.c) *const Type;
    pub const method_get_param_name = fn (*const Method, index: u32) callconv(.c) [*:0]const u8;
    pub const type_get_object = fn (*const Type) callconv(.c) ?*const Object;
    pub const gchandle_new = fn (*const Object, pinned: i32) callconv(.c) GcHandleV1;
    pub const gchandle_free = fn (handle: GcHandleV1) callconv(.c) void;
    pub const gchandle_get_target = fn (handle: GcHandleV1) callconv(.c) *const Object;
    pub const object_new = fn (*const Class) callconv(.c) ?*const Object;
    pub const string_new_len = fn (text: [*]const u8, len: c_uint) callconv(.c) ?*const String;
    pub const class_is_enum = fn (*const Class) callconv(.c) bool;
    pub const class_is_valuetype = fn (*const Class) callconv(.c) bool;
    pub const class_get_declaring_type = fn (*const Class) callconv(.c) ?*const Class;
    pub const field_get_value_object = fn (*const ClassField, obj: ?*const Object) callconv(.c) ?*const Object;
};

// V1 of the GC handle API will will crash if you call get_target on a new handle on the game PEAK
// which ships a newer mono where V2 exists. Older runtimes (Unity 2019, e.g. Outer Wilds) only
// have V1, so resolve V2 when present and fall back to V1.
pub const MonoGcHandle = union(enum) {
    v1: V1,
    v2: V2,

    pub const V1 = struct {
        gchandle_new: *const mono.gchandle_new,
        gchandle_free: *const mono.gchandle_free,
        gchandle_get_target: *const mono.gchandle_get_target,
    };
    pub const V2 = struct {
        gchandle_new_v2: *const mono.gchandle_new_v2,
        gchandle_free_v2: *const mono.gchandle_free_v2,
        gchandle_get_target_v2: *const mono.gchandle_get_target_v2,
    };

    pub fn resolve(module: dynlib.Module, proc_ref: *[:0]const u8) error{ProcNotFound}!MonoGcHandle {
        if (dotnetload.resolveMono(V2, module, proc_ref)) |v2| return .{ .v2 = v2 } else |err| switch (err) {
            error.ProcNotFound => return .{ .v1 = try dotnetload.resolveMono(V1, module, proc_ref) },
        }
    }

    pub fn new(h: MonoGcHandle, object: *const Object, pinned: i32) GcHandleV2 {
        return switch (h) {
            .v1 => |v1| v1.gchandle_new(object, pinned).toV2(),
            .v2 => |v2| v2.gchandle_new_v2(object, pinned),
        };
    }
    pub fn free(h: MonoGcHandle, handle: GcHandleV2) void {
        switch (h) {
            .v1 => |v1| v1.gchandle_free(.fromV2(handle)),
            .v2 => |v2| v2.gchandle_free_v2(handle),
        }
    }
    pub fn get_target(h: MonoGcHandle, handle: GcHandleV2) *const Object {
        return switch (h) {
            .v1 => |v1| v1.gchandle_get_target(.fromV2(handle)),
            .v2 => |v2| v2.gchandle_get_target_v2(handle),
        };
    }
};

pub fn object_new(f: anytype, class: *const Class) ?*const Object {
    return switch (f.kind) {
        .mono => |m| m.object_new(f.domain_get().?, class),
        .il2cpp => |i| i.object_new(class),
    };
}
pub fn string_new_len(f: anytype, text: [*]const u8, len: c_uint) ?*const String {
    return switch (f.kind) {
        .mono => |m| m.string_new_len(f.domain_get().?, text, len),
        .il2cpp => |i| i.string_new_len(text, len),
    };
}
pub fn class_is_enum(f: anytype, class: *const Class) bool {
    return switch (f.kind) {
        .mono => |m| m.class_is_enum(class) != 0,
        .il2cpp => |i| i.class_is_enum(class),
    };
}
pub fn gchandle_new(f: anytype, object: *const Object, pinned: bool) GcHandleV2 {
    return switch (f.kind) {
        .mono => |m| m.gchandle.new(object, @intFromBool(pinned)),
        .il2cpp => |i| i.gchandle_new(object, @intFromBool(pinned)).toV2(),
    };
}
pub fn gchandle_free(f: anytype, handle: GcHandleV2) void {
    switch (f.kind) {
        .mono => |m| m.gchandle.free(handle),
        .il2cpp => |i| i.gchandle_free(.fromV2(handle)),
    }
}
pub fn gchandle_get_target(f: anytype, handle: GcHandleV2) ?*const Object {
    return switch (f.kind) {
        .mono => |m| m.gchandle.get_target(handle),
        .il2cpp => |i| i.gchandle_get_target(.fromV2(handle)),
    };
}
pub fn type_get_object(f: anytype, t: *const Type) ?*const Object {
    return switch (f.kind) {
        .mono => |m| m.type_get_object(f.domain_get().?, t),
        .il2cpp => |i| i.type_get_object(t),
    };
}
pub fn class_is_valuetype(f: anytype, class: *const Class) bool {
    return switch (f.kind) {
        .mono => |m| m.class_is_valuetype(class) != 0,
        .il2cpp => |i| i.class_is_valuetype(class),
    };
}
pub fn class_get_declaring_type(f: anytype, class: *const Class) ?*const Class {
    return switch (f.kind) {
        .mono => |m| m.class_get_nesting_type(class),
        .il2cpp => |i| i.class_get_declaring_type(class),
    };
}
pub fn field_get_value_object(f: anytype, field: *const ClassField, obj: ?*const Object) ?*const Object {
    return switch (f.kind) {
        .mono => |m| m.field_get_value_object(f.domain_get().?, field, obj),
        .il2cpp => |i| i.field_get_value_object(field, obj),
    };
}

pub const TableInfo = opaque {};
pub const mono_table_typedef: c_int = 2;
pub const mono_token_type_def: u32 = 0x02000000;

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
    unmanaged_export: bool = false,
    static: bool = false,
    final: bool = false,
    virtual: bool = false,
    hide_by_sig: bool = false,
    new_slot: bool = false,
    check_access_on_override: bool = false,
    abstract: bool = false,
    special_name: bool = false,
    rt_special_name: bool = false,
    pinvoke_impl: bool = false,
    has_security: bool = false,
    require_sec_object: bool = false,
    unused: u16 = 0,
};

pub const MethodImplFlags = packed struct(u32) {
    code_type: enum(u2) { il = 0, native = 1, optil = 2, runtime = 3 },
    unmanaged: bool = false,
    no_inlining: bool = false,
    forward_ref: bool = false,
    synchronized: bool = false,
    no_optimization: bool = false,
    preserve_sig: bool = false,
    unused1: u4 = 0,
    internal_call: bool = false,
    unused2: u19 = 0,
};

pub const ClassFlags = packed struct(u32) {
    visibility: enum(u3) {
        not_public = 0,
        public = 1,
        nested_public = 2,
        nested_private = 3,
        nested_family = 4,
        nested_assembly = 5,
        nested_fam_and_assem = 6,
        nested_fam_or_assem = 7,
    },
    layout: u2 = 0,
    interface: bool = false,
    unused1: bool = false,
    abstract: bool = false,
    sealed: bool = false,
    unused2: bool = false,
    special_name: bool = false,
    unused3: bool = false,
    import: bool = false,
    serializable: bool = false,
    unused4: u18 = 0,
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

const dynlib = @import("dynlib.zig");
const dotnetkind = @import("dotnetkind.zig");
const dotnetload = @import("dotnetload.zig");
