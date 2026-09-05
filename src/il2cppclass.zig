// Offsets are discovered by probing with the public API rather than mirroring Il2CppClass,
// which embeds two Il2CppType bitfield structs: one packing mistake there would silently
// shift every later offset while we write into live runtime memory.
const scan_len = 0x180;
const ptr_slots = scan_len / @sizeOf(usize);
const u16_slots = scan_len / @sizeOf(u16);
const u8_slots = scan_len;
// no bitfields, so this one is safe to mirror directly
const FieldInfo = extern struct {
    name: [*:0]const u8,
    type: *const dotnet.Type,
    parent: *const dotnet.Class,
    offset: i32,
    token: u32,
};
pub const Layout = struct {
    fields: usize,
    field_count: usize,
    methods: usize,
    method_count: usize,
    // klass->parent, probed against class_get_parent. Class::GetMethodFromName's inherited lookup
    // walks it, so a synthetic subclass must set it to the base it derives from.
    parent: usize,
    // klass->typeHierarchy (Il2CppClass**, [depth-1] == self) and klass->typeHierarchyDepth (u8).
    // Class::IsAssignableFrom decides subclassing off these two, not parent, so a synthetic
    // MonoBehaviour must carry its own hierarchy = base's ++ [self] with depth = base + 1.
    type_hierarchy: usize,
    type_hierarchy_depth: usize,
    // vtable_count has no public accessor to probe against, so it is inferred: the u16 count
    // block in Il2CppClass is method_count, property_count, field_count, event_count,
    // nested_type_count, vtable_count in every Unity version in libil2cpp (2017.1 through
    // 6000.x, checked), so it is method_count + 10. discover cross-checks that the independently
    // probed field_count lands at method_count + 4, confirming the block's stride at runtime too.
    vtable_count: usize,
    pub fn fieldsOf(l: Layout, class: *const dotnet.Class) []const FieldInfo {
        const base: [*]const u8 = @ptrCast(class);
        const p: *align(1) const [*]const FieldInfo = @ptrCast(base + l.fields);
        const n: *align(1) const u16 = @ptrCast(base + l.field_count);
        return p.*[0..n.*];
    }
    pub fn vtableCountOf(l: Layout, class: *const dotnet.Class) u16 {
        const base: [*]const u8 = @ptrCast(class);
        const p: *align(1) const u16 = @ptrCast(base + l.vtable_count);
        return p.*;
    }
};
// Walks the class's fields through the discovered offsets and requires the result to match
// what the public API reports, name for name. The probe only ever matches entry [0], so this
// is what confirms the mirrored FieldInfo stride.
fn validate(funcs: *const dotnet.Funcs, class: *const dotnet.Class, l: Layout) bool {
    const fields = l.fieldsOf(class);
    var iterator: ?*anyopaque = null;
    for (fields) |*field| {
        const expect = funcs.class_get_fields(class, &iterator) orelse return false;
        if (expect != @as(*const dotnet.ClassField, @ptrCast(field))) return false;
        if (!std.mem.eql(
            u8,
            std.mem.span(field.name),
            std.mem.span(funcs.field_get_name(expect)),
        )) return false;
    }
    if (funcs.class_get_fields(class, &iterator) != null) return false;
    // parent must match the public accessor too (both null for roots like System.Object). The
    // hierarchy fields are not checked here: this sweep runs over un-initialized classes, whose
    // typeHierarchy is still null (discoverHierarchy validates those on initialized classes).
    const parent_slot: *align(1) const ?*const dotnet.Class = @ptrCast(@as([*]const u8, @ptrCast(class)) + l.parent);
    return parent_slot.* == funcs.class_get_parent(class);
}

pub const Layouts = struct {
    class: Layout,
    method: MethodLayout,
};
pub const DiscoverError = error{
    ClassLayoutNotResolved,
    MethodLayoutNotResolved,
    ClassLayoutInvalid,
    UnsupportedInvokerAbi,
    UnsupportedUnityVersion,
};

// The oldest Unity version whose Il2CppClass u16 count-block layout we have verified against
// the libil2cpp sources. The vtable_count inference below is trusted from here on. The version
// is threaded rather than assumed so that when a future Unity reorders that block, this becomes
// a version ladder with a new case instead of silent corruption.
const layout_verified_from: UnityVersion = .{ .major = 2017, .minor = 1, .build = 0, .revision = 0 };

// Before 2021.2, InvokerMethod took 4 args and returned the boxed object instead of writing
// through a 5th `ret` pointer, and `parameters` was ParameterInfo* rather than Il2CppType**.
// Adding that shape is easy, but the offset cannot select it -- 2020.3 (4-arg) and 2021.1
// (5-arg) have identical layouts -- so it needs UnityPlayer.dll's version, which mutinydll
// already reads. Refused until there is a pre-2021.2 game to verify against.
const supported_invoker_method_offset = 16;
pub fn discover(
    funcs: *const dotnet.Funcs,
    unity_version: UnityVersion,
) DiscoverError!Layouts {
    if (!unity_version.atLeast(layout_verified_from.major, layout_verified_from.minor)) {
        std.log.err("il2cpp class layout is unverified before Unity {f}, but this game is {f}", .{
            layout_verified_from,
            unity_version,
        });
        return error.UnsupportedUnityVersion;
    }
    const il2cpp = &funcs.kind.il2cpp;
    const domain = funcs.domain_get().?;
    var candidates: Candidates = .init();
    var method_candidates: MethodCandidates = .{};
    var assembly_count: usize = 0;
    const assemblies = il2cpp.domain_get_assemblies(domain, &assembly_count);
    var visited: usize = 0;

    // Every class visited forces SetupFields/SetupMethods, which contends with a running game
    // badly enough to cost seconds, so stop as soon as the offsets are pinned. Narrowing is
    // elimination rather than sampling: a wrong slot has to hold the right value for every
    // class checked, so this converges in a handful.
    probe: for (assemblies[0..assembly_count]) |assembly| {
        const image = il2cpp.assembly_get_image(assembly);
        for (0..il2cpp.image_get_class_count(image)) |i| {
            const class = il2cpp.image_get_class(image, i);
            probeFields(funcs, class, &candidates);
            var iterator: ?*anyopaque = null;
            while (funcs.class_get_methods(class, &iterator)) |method| {
                probeMethod(funcs, method, &method_candidates);
            }
            visited += 1;
            if (candidates.resolve() != null and method_candidates.resolve() != null) break :probe;
        }
    }
    const class_offsets = candidates.resolve() orelse {
        report("fields", &candidates.fields, @sizeOf(usize));
        report("field_count", &candidates.field_count, @sizeOf(u16));
        report("methods", &candidates.methods, @sizeOf(usize));
        report("method_count", &candidates.method_count, @sizeOf(u16));
        report("parent", &candidates.parent, @sizeOf(usize));
        return error.ClassLayoutNotResolved;
    };
    // the vtable_count inference rides on the u16 count block's order; the probe pins
    // method_count and field_count independently, so their spacing confirms it at runtime
    if (class_offsets.field_count != class_offsets.method_count + 4) {
        std.log.err("il2cpp field_count (0x{x}) is not method_count (0x{x}) + 4", .{
            class_offsets.field_count,
            class_offsets.method_count,
        });
        return error.ClassLayoutInvalid;
    }
    const method_layout = method_candidates.resolve() orelse {
        report("name", &method_candidates.name, @sizeOf(usize));
        report("klass", &method_candidates.klass, @sizeOf(usize));
        report("return_type", &method_candidates.return_type, @sizeOf(usize));
        report("parameters_count", &method_candidates.parameters_count, 1);
        report("flags", &method_candidates.flags, @sizeOf(u16));
        return error.MethodLayoutNotResolved;
    };
    if (method_layout.invokerMethod() != supported_invoker_method_offset) {
        std.log.err("il2cpp is older than Unity 2021.2 (invoker_method at 0x{x})", .{
            method_layout.invokerMethod(),
        });
        return error.UnsupportedInvokerAbi;
    }
    const hierarchy_offsets = try discoverHierarchy(funcs, assemblies[0..assembly_count]);
    const class_layout: Layout = .{
        .fields = class_offsets.fields,
        .field_count = class_offsets.field_count,
        .methods = class_offsets.methods,
        .method_count = class_offsets.method_count,
        .parent = class_offsets.parent,
        .type_hierarchy = hierarchy_offsets.type_hierarchy,
        .type_hierarchy_depth = hierarchy_offsets.type_hierarchy_depth,
        .vtable_count = class_offsets.vtable_count,
    };
    // Only the classes the probe already visited: they are the ones whose metadata is set up,
    // so revisiting them is free, and validating further would pay the setup cost we just
    // avoided. This checks what probing cannot -- that the mirrored FieldInfo stride is right,
    // since the probe only ever matches entry [0].
    var validated: usize = 0;
    check: for (assemblies[0..assembly_count]) |assembly| {
        const image = il2cpp.assembly_get_image(assembly);
        for (0..il2cpp.image_get_class_count(image)) |i| {
            const class = il2cpp.image_get_class(image, i);
            if (!validate(funcs, class, class_layout)) {
                std.log.err("il2cpp layout validation failed on class '{s}'", .{
                    funcs.class_get_name(class),
                });
                return error.ClassLayoutInvalid;
            }
            validated += 1;
            if (validated == visited) break :check;
        }
    }
    std.log.info("il2cpp layout: probed {} classes and {} methods, validated {} classes (parent 0x{x}, typeHierarchy 0x{x}, depth 0x{x})", .{
        candidates.classes_probed,
        method_candidates.methods_probed,
        validated,
        class_layout.parent,
        class_layout.type_hierarchy,
        class_layout.type_hierarchy_depth,
    });
    return .{ .class = class_layout, .method = method_layout };
}
// Distinct hierarchy depths so the one-byte depth offset resolves to a single slot; the pointer
// offset needs only one initialized class (its self-terminated array is a unique signature).
const hierarchy_probe_classes = [_]struct { ns: [*:0]const u8, name: [*:0]const u8 }{
    .{ .ns = "System", .name = "Object" }, // depth 1
    .{ .ns = "System", .name = "String" }, // depth 2: Object <- String
    .{ .ns = "System", .name = "Int32" }, // depth 3: Object <- ValueType <- Int32
    .{ .ns = "System", .name = "ArgumentException" }, // depth 4
};
// Class::Init runs SetupTypeHierarchy; class_get_method_from_name forces it without running the
// managed static constructor (runtime_class_init does only the cctor, so it leaves typeHierarchy
// null). The lookup result is discarded -- initializing the class is the whole point.
fn forceClassInit(funcs: *const dotnet.Funcs, class: *const dotnet.Class) void {
    _ = funcs.class_get_method_from_name(class, "", 0);
}
// typeHierarchy/typeHierarchyDepth are filled by Class::Init (SetupTypeHierarchy), which the main
// sweep never triggers, so probe them over framework classes initialized on purpose: forcing their
// setup is safe, unlike running arbitrary game static constructors.
fn discoverHierarchy(
    funcs: *const dotnet.Funcs,
    assemblies: []const *const dotnet.Assembly,
) DiscoverError!HierarchyOffsets {
    var candidates: HierarchyCandidates = .{};
    var probed: usize = 0;
    for (hierarchy_probe_classes) |spec| {
        const class = findClass(funcs, assemblies, spec.ns, spec.name) orelse continue;
        forceClassInit(funcs, class);
        probeHierarchy(funcs, class, &candidates);
        probed += 1;
    }
    return candidates.resolve() orelse {
        std.log.err("il2cpp type hierarchy layout unresolved after {} classes", .{probed});
        report("type_hierarchy", &candidates.type_hierarchy, @sizeOf(usize));
        report("type_hierarchy_depth", &candidates.type_hierarchy_depth, 1);
        return error.ClassLayoutNotResolved;
    };
}
fn count(flags: []const bool) usize {
    var total: usize = 0;
    for (flags) |f| total += @intFromBool(f);
    return total;
}
fn only(flags: []const bool, scale: usize) ?usize {
    var found: ?usize = null;
    for (flags, 0..) |f, i| {
        if (!f) continue;
        if (found != null) return null;
        found = i * scale;
    }
    return found;
}
fn report(name: []const u8, flags: []const bool, scale: usize) void {
    const total = count(flags);
    if (total == 1) {
        std.log.info("  {s}: 0x{x}", .{ name, only(flags, scale).? });
        return;
    }
    std.log.err("  {s}: {} candidates, expected exactly 1", .{ name, total });
    for (flags, 0..) |f, i| {
        if (f) std.log.err("    candidate 0x{x}", .{i * scale});
    }
}
// The offsets the un-initialized sweep can pin. typeHierarchy/typeHierarchyDepth are not here: they
// are populated only by Class::Init, which the sweep deliberately never forces, so they get their
// own phase (discoverHierarchy) over a few classes initialized on purpose.
const ClassOffsets = struct {
    fields: usize,
    field_count: usize,
    methods: usize,
    method_count: usize,
    parent: usize,
    vtable_count: usize,
};
const Candidates = struct {
    fields: [ptr_slots]bool = @splat(true),
    field_count: [u16_slots]bool = @splat(true),
    methods: [ptr_slots]bool = @splat(true),
    method_count: [u16_slots]bool = @splat(true),
    parent: [ptr_slots]bool = @splat(true),
    classes_probed: u32 = 0,
    pub fn init() Candidates {
        return .{};
    }
    pub fn resolve(c: *const Candidates) ?ClassOffsets {
        const method_count = only(&c.method_count, @sizeOf(u16)) orelse return null;
        return .{
            .fields = only(&c.fields, @sizeOf(usize)) orelse return null,
            .field_count = only(&c.field_count, @sizeOf(u16)) orelse return null,
            .methods = only(&c.methods, @sizeOf(usize)) orelse return null,
            .method_count = method_count,
            .parent = only(&c.parent, @sizeOf(usize)) orelse return null,
            .vtable_count = method_count + 10,
        };
    }
};
const HierarchyOffsets = struct {
    type_hierarchy: usize,
    type_hierarchy_depth: usize,
};
const HierarchyCandidates = struct {
    type_hierarchy: [ptr_slots]bool = @splat(true),
    type_hierarchy_depth: [u8_slots]bool = @splat(true),
    pub fn resolve(c: *const HierarchyCandidates) ?HierarchyOffsets {
        return .{
            .type_hierarchy = only(&c.type_hierarchy, @sizeOf(usize)) orelse return null,
            .type_hierarchy_depth = only(&c.type_hierarchy_depth, 1) orelse return null,
        };
    }
};
const method_scan_len = 0x80;
const method_ptr_slots = method_scan_len / @sizeOf(usize);
const method_u8_slots = method_scan_len;
const method_u16_slots = method_scan_len / @sizeOf(u16);
// Unlike FieldInfo, MethodInfo moved: virtualMethodPointer was added in Unity 2021.2 as the
// second member, shifting invoker_method from 8 to 16 and everything after it. So it gets
// discovered too. Runtime::Invoke reads only flags, klass, return_type, invoker_method and
// methodPointer, and Class::GetMethodFromName also needs name and parameters_count.
pub const MethodLayout = struct {
    name: usize,
    klass: usize,
    return_type: usize,
    parameters_count: usize,
    flags: usize,
    // methodPointer is offset 0 in every version from 2018.4 through 6000.0, and
    // invoker_method immediately precedes name in both layouts
    pub const method_pointer = 0;
    pub fn invokerMethod(l: MethodLayout) usize {
        return l.name - @sizeOf(usize);
    }
    // parameters immediately follows return_type in both layouts. Runtime::Invoke never reads
    // it, but our own paramTypeKind calls method_get_param to type-check arguments, so a
    // synthetic method with args must supply it or that read faults.
    pub fn parameters(l: MethodLayout) usize {
        return l.return_type + @sizeOf(usize);
    }
};
const MethodCandidates = struct {
    name: [method_ptr_slots]bool = @splat(true),
    klass: [method_ptr_slots]bool = @splat(true),
    return_type: [method_ptr_slots]bool = @splat(true),
    parameters_count: [method_u8_slots]bool = @splat(true),
    flags: [method_u16_slots]bool = @splat(true),
    methods_probed: u32 = 0,
    pub fn resolve(c: *const MethodCandidates) ?MethodLayout {
        const layout: MethodLayout = .{
            .name = only(&c.name, @sizeOf(usize)) orelse return null,
            .klass = only(&c.klass, @sizeOf(usize)) orelse return null,
            .return_type = only(&c.return_type, @sizeOf(usize)) orelse return null,
            .parameters_count = only(&c.parameters_count, 1) orelse return null,
            .flags = only(&c.flags, @sizeOf(u16)) orelse return null,
        };
        // 8 and 16 are the only offsets libil2cpp uses (8 before 2021.2, 16 from 2021.2 on).
        // Anything else means the inference is wrong, not that the runtime is old.
        const invoker = layout.invokerMethod();
        if (invoker != 8 and invoker != 16) return null;
        return layout;
    }
};
fn probeMethod(
    funcs: *const dotnet.Funcs,
    method: *const dotnet.Method,
    c: *MethodCandidates,
) void {
    // MethodInfo is 0x58, so the last one in a metadata block ends before scan_len
    if (!readable(@intFromPtr(method), method_scan_len)) return;
    const il2cpp = &funcs.kind.il2cpp;
    const name = funcs.method_get_name(method);
    const class = funcs.method_get_class(method) orelse return;
    const return_type = il2cpp.method_get_return_type(method) orelse return;
    const param_count = std.math.cast(u8, il2cpp.method_get_param_count(method)) orelse return;
    const flags: u16 = @truncate(@as(u32, @bitCast(funcs.method_get_flags(method, null))));
    const base: [*]const u8 = @ptrCast(method);
    for (&c.name, 0..) |*alive, slot| {
        if (alive.*) alive.* = readPtrAt(base, slot) == @intFromPtr(name);
    }
    for (&c.klass, 0..) |*alive, slot| {
        if (alive.*) alive.* = readPtrAt(base, slot) == @intFromPtr(class);
    }
    for (&c.return_type, 0..) |*alive, slot| {
        if (alive.*) alive.* = readPtrAt(base, slot) == @intFromPtr(return_type);
    }
    for (&c.parameters_count, 0..) |*alive, slot| {
        if (alive.*) alive.* = base[slot] == param_count;
    }
    for (&c.flags, 0..) |*alive, slot| {
        if (alive.*) alive.* = readU16At(base, slot) == flags;
    }
    c.methods_probed += 1;
}
fn readPtrAt(base: [*]const u8, slot: usize) usize {
    const p: *align(1) const usize = @ptrCast(base + slot * @sizeOf(usize));
    return p.*;
}
fn readU16At(base: [*]const u8, slot: usize) u16 {
    const p: *align(1) const u16 = @ptrCast(base + slot * @sizeOf(u16));
    return p.*;
}
// il2cpp calls a method through invoker_method, passing methodPointer back to it, so the
// invoker is where a synthetic method actually lands. It is just a function pointer in
// MethodInfo, which means ours can be plain Zig and we never need one of il2cpp's generated
// per-signature invokers.
pub const MethodPointer = *const fn () callconv(.c) void;
pub const InvokerMethod = *const fn (
    method_pointer: MethodPointer,
    method: *const dotnet.Method,
    obj: ?*anyopaque,
    params: ?[*]?*anyopaque,
    ret: ?*anyopaque,
) callconv(.c) void;
const method_info_size = method_scan_len;
pub const SyntheticMethod = struct {
    storage: [method_info_size]u8 align(@alignOf(usize)),
    pub fn init(
        self: *SyntheticMethod,
        l: MethodLayout,
        args: struct {
            name: [*:0]const u8,
            return_type: *const dotnet.Type,
            method_pointer: MethodPointer,
            invoker: InvokerMethod,
            parameters_count: u8,
            // METHOD_ATTRIBUTE_PUBLIC, and deliberately not STATIC: Invoke only dereferences
            // klass for a static method, so a non-static synthetic method needs no class
            flags: u16 = 0x0006,
            klass: ?*const dotnet.Class = null,
            parameters: ?[*]const *const dotnet.Type = null,
        },
    ) *const dotnet.Method {
        @memset(&self.storage, 0);
        self.write(usize, MethodLayout.method_pointer, @intFromPtr(args.method_pointer));
        self.write(usize, l.invokerMethod(), @intFromPtr(args.invoker));
        self.write(usize, l.name, @intFromPtr(args.name));
        self.write(usize, l.return_type, @intFromPtr(args.return_type));
        self.write(u8, l.parameters_count, args.parameters_count);
        self.write(u16, l.flags, args.flags);
        if (args.klass) |k| self.write(usize, l.klass, @intFromPtr(k));
        if (args.parameters) |p| self.write(usize, l.parameters(), @intFromPtr(p));
        return @ptrCast(&self.storage);
    }
    // A synthetic class and its methods reference each other, so the class pointer isn't known
    // when the method is first written. Patch klass in once the class exists.
    pub fn setKlass(self: *SyntheticMethod, l: MethodLayout, klass: *const dotnet.Class) void {
        self.write(usize, l.klass, @intFromPtr(klass));
    }
    fn write(self: *SyntheticMethod, comptime T: type, offset: usize, value: T) void {
        const p: *align(1) T = @ptrCast(&self.storage[offset]);
        p.* = value;
    }
};

// VirtualInvokeData is two pointers { methodPtr, MethodInfo* } in every libil2cpp version, so the
// inline vtable strides one per entry.
const vtable_entry_size = 2 * @sizeOf(usize);

// Il2CppClass header size: where the inline vtable[] begins, so how many bytes to copy per class.
// Not probeable (it is the struct's own size), so it is a version-gated constant. Byte-identical at
// 0x138 from Unity 2022.3 through 6000.0 (checked against libil2cpp - the one member that grew,
// initializationExceptionGCHandle, is absorbed by padding before cctor_thread), matching the
// hand-walked header (fields 0x80, static_fields 0xb8, field_count 0x124). The gate is a floor:
// versions below 2022.3 are unverified. selfTest also validates it per-process against the base's
// vtable, so a wrong value can't pass silently.
const class_fixed_size = 0x138;
// buildSubclass places the typeHierarchy array at storage.ptr + total (total = fixed_size +
// vtable_count*16); it is only pointer-aligned if the header size is a multiple of 8.
comptime {
    std.debug.assert(class_fixed_size % @alignOf(usize) == 0);
}
const class_fixed_size_verified_from: UnityVersion = .{ .major = 2022, .minor = 3, .build = 0, .revision = 0 };
pub fn classFixedSize(unity_version: UnityVersion) error{UnsupportedUnityVersion}!usize {
    if (!unity_version.atLeast(class_fixed_size_verified_from.major, class_fixed_size_verified_from.minor)) {
        std.log.err("il2cpp class header size is unverified before Unity {f}, but this game is {f}", .{
            class_fixed_size_verified_from,
            unity_version,
        });
        return error.UnsupportedUnityVersion;
    }
    return class_fixed_size;
}

// A class we own, so a synthetic method can be found off it without mutating a real class. It copies
// an initialized base class's whole allocation and overrides the method table, so instance_size,
// gc_desc, init flags and the vtable are inherited correct-by-construction. typeMetadataHandle is left
// as the base's, which is safe because copying an already-initialized class means Class::Init never
// re-runs to read it. The copy keeps the base's name and type identity, so class_get_type resolves back
// to the base -- a synthetic subclass gets its own identity from the FromIl2CppType hook + sentinel,
// not from the copy.
pub const SyntheticClass = struct {
    // the runtime keeps pointers into this (obj->klass), so it outlives every instance; never freed
    storage: []align(@alignOf(usize)) u8,
    pub fn build(
        allocator: std.mem.Allocator, // one allocation, ok to use std.heap.page_allocator
        l: Layout,
        fixed_size: usize,
        base: *const dotnet.Class,
        methods: []const *const dotnet.Method, // pointers into this must outlive the class
    ) error{ OutOfMemory, TooManyMethods, BaseNotReadable }!SyntheticClass {
        const method_count = std.math.cast(u16, methods.len) orelse return error.TooManyMethods;
        const total = try baseCopySize(l, fixed_size, base);
        const storage = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(usize)), total);
        copyBase(storage, l, base, total, methods, method_count);
        return .{ .storage = storage };
    }
    // Sets parent and writes a fresh typeHierarchy (base's plus self) at depth base + 1, which is what
    // Class::IsAssignableFrom reads to accept the copy as a subclass of base.
    pub fn buildSubclass(
        allocator: std.mem.Allocator, // one allocation, ok to use std.heap.page_allocator
        l: Layout,
        fixed_size: usize,
        base: *const dotnet.Class, // both the class to copy and the parent
        methods: []const *const dotnet.Method,
    ) error{ OutOfMemory, TooManyMethods, BaseNotReadable, BaseNotInitialized, TypeHierarchyTooDeep }!SyntheticClass {
        const method_count = std.math.cast(u16, methods.len) orelse return error.TooManyMethods;
        const base_bytes: [*]const u8 = @ptrCast(base);
        const base_depth: u8 = base_bytes[l.type_hierarchy_depth];
        if (base_depth == 0) return error.BaseNotInitialized;
        const new_depth = std.math.add(u8, base_depth, 1) catch return error.TypeHierarchyTooDeep;
        const base_hierarchy_slot: *align(1) const usize = @ptrCast(base_bytes + l.type_hierarchy);
        const base_hierarchy: [*]align(1) const usize = @ptrFromInt(base_hierarchy_slot.*);
        // SetupTypeHierarchy writes depth before the array pointer, so a non-zero depth alone does not
        // prove the array is there; require it, or a base mid-Init hands us a null pointer to memcpy.
        if (!readable(base_hierarchy_slot.*, @as(usize, base_depth) * @sizeOf(usize))) return error.BaseNotInitialized;

        // total is a multiple of 8 (fixed_size and each vtable entry are), so the typeHierarchy array
        // placed at the tail of the same allocation is pointer-aligned.
        const total = try baseCopySize(l, fixed_size, base);
        const storage = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(usize)), total + @as(usize, new_depth) * @sizeOf(usize));
        copyBase(storage, l, base, total, methods, method_count);

        const hierarchy: [*]usize = @ptrCast(@alignCast(storage.ptr + total));
        @memcpy(hierarchy[0..base_depth], base_hierarchy[0..base_depth]);
        hierarchy[base_depth] = @intFromPtr(storage.ptr); // self is the final entry

        const parent_field: *align(1) usize = @ptrCast(storage.ptr + l.parent);
        const hierarchy_field: *align(1) usize = @ptrCast(storage.ptr + l.type_hierarchy);
        parent_field.* = @intFromPtr(base);
        hierarchy_field.* = @intFromPtr(hierarchy);
        storage[l.type_hierarchy_depth] = new_depth;
        return .{ .storage = storage };
    }
    pub fn class(self: SyntheticClass) *const dotnet.Class {
        return @ptrCast(self.storage.ptr);
    }
};
// vtable_count is an inferred offset, so a wrong read could make the copy ~1MB; bound it to base's
// committed pages rather than trusting the computed size.
fn baseCopySize(l: Layout, fixed_size: usize, base: *const dotnet.Class) error{BaseNotReadable}!usize {
    const total = fixed_size + @as(usize, l.vtableCountOf(base)) * vtable_entry_size;
    if (!readable(@intFromPtr(base), total)) return error.BaseNotReadable;
    return total;
}
fn copyBase(
    storage: []u8,
    l: Layout,
    base: *const dotnet.Class,
    total: usize,
    methods: []const *const dotnet.Method,
    method_count: u16,
) void {
    @memcpy(storage[0..total], @as([*]const u8, @ptrCast(base))[0..total]);
    const methods_field: *align(1) [*]const *const dotnet.Method = @ptrCast(storage.ptr + l.methods);
    const method_count_field: *align(1) u16 = @ptrCast(storage.ptr + l.method_count);
    methods_field.* = methods.ptr;
    method_count_field.* = method_count;
}
// the methods probe dereferences a pointer read out of the class, which is a guess until the
// offset is pinned down, so check the page is actually there first
fn readable(addr: usize, len: usize) bool {
    if (builtin.os.tag == .windows) {
        var info: win32.MEMORY_BASIC_INFORMATION = undefined;
        if (0 == win32.VirtualQuery(@ptrFromInt(addr), &info, @sizeOf(@TypeOf(info)))) return false;
        if (info.State != win32.MEM_COMMIT) return false;
        if (info.Protect.PAGE_NOACCESS == 1) return false;
        if (info.Protect.PAGE_GUARD == 1) return false;
        const region_end = @intFromPtr(info.BaseAddress) + info.RegionSize;
        return addr + len <= region_end;
    } else {
        @panic("todo");
    }
}
fn readPtr(class: *const dotnet.Class, slot: usize) usize {
    const base: [*]const u8 = @ptrCast(class);
    const p: *align(1) const usize = @ptrCast(base + slot * @sizeOf(usize));
    return p.*;
}
fn readU16(class: *const dotnet.Class, slot: usize) u16 {
    const base: [*]const u8 = @ptrCast(class);
    const p: *align(1) const u16 = @ptrCast(base + slot * @sizeOf(u16));
    return p.*;
}
fn readU8(class: *const dotnet.Class, slot: usize) u8 {
    const base: [*]const u8 = @ptrCast(class);
    return base[slot];
}
// Narrows `fields` and `field_count` using one class. Read-only: no static constructor is
// run and no guessed pointer is dereferenced, so this is safe to sweep over every class in a
// game. Classes with differing field counts are what separate field_count from the
// method/property/event counts sitting beside it.
fn probeFields(funcs: *const dotnet.Funcs, class: *const dotnet.Class, c: *Candidates) void {
    // Il2CppClass is 0x138 plus 0x10 per vtable entry, so a class with few virtuals is
    // smaller than scan_len and the sweep would read past its allocation.
    if (!readable(@intFromPtr(class), scan_len)) return;
    probeMethodArray(funcs, class, c);
    probeParent(funcs, class, c);

    var iterator: ?*anyopaque = null;
    const first_field = funcs.class_get_fields(class, &iterator) orelse return;
    var field_total: u16 = 1;
    while (funcs.class_get_fields(class, &iterator)) |_| field_total += 1;
    for (&c.fields, 0..) |*alive, slot| {
        if (alive.*) alive.* = readPtr(class, slot) == @intFromPtr(first_field);
    }
    for (&c.field_count, 0..) |*alive, slot| {
        if (alive.*) alive.* = readU16(class, slot) == field_total;
    }
    c.classes_probed += 1;
}
// Narrows `parent` using one class. class_get_parent returns klass->parent directly, so the slot
// holds it with no extra dereference. Read-only: compares a header slot to a known pointer, never
// dereferences a guessed one. Classes with differing parents are what separate `parent` from the
// neighbouring castClass/element_class slots, which alias self on an ordinary class.
fn probeParent(funcs: *const dotnet.Funcs, class: *const dotnet.Class, c: *Candidates) void {
    const parent = funcs.class_get_parent(class) orelse return; // null for System.Object and interfaces
    for (&c.parent, 0..) |*alive, slot| {
        if (alive.*) alive.* = readPtr(class, slot) == @intFromPtr(parent);
    }
}
// depth including self: 1 for a root like System.Object, 4 for MonoBehaviour. Derived from the
// public parent walk, so it needs no offset of its own to compute the expected value to probe for.
fn computeDepth(funcs: *const dotnet.Funcs, class: *const dotnet.Class) u8 {
    var depth: usize = 1;
    var cur = funcs.class_get_parent(class);
    while (cur) |parent| : (cur = funcs.class_get_parent(parent)) depth += 1;
    return @intCast(depth); // real hierarchies are a handful deep; a wild value panics loudly
}
// Narrows `type_hierarchy` and `type_hierarchy_depth` using one class. The depth is probed against
// the computed value; the hierarchy pointer against its self-referential signature (the array's
// last live entry is the class itself), which no other header pointer satisfies. Read-only apart
// from dereferencing the hierarchy candidate, which is bounds-checked first.
fn probeHierarchy(funcs: *const dotnet.Funcs, class: *const dotnet.Class, c: *HierarchyCandidates) void {
    const depth = computeDepth(funcs, class);
    for (&c.type_hierarchy_depth, 0..) |*alive, slot| {
        if (alive.*) alive.* = readU8(class, slot) == depth;
    }
    for (&c.type_hierarchy, 0..) |*alive, slot| {
        if (!alive.*) continue;
        const array = readPtr(class, slot);
        if (!readable(array, @as(usize, depth) * @sizeOf(usize))) {
            alive.* = false;
            continue;
        }
        const entry: [*]align(1) const usize = @ptrFromInt(array);
        alive.* = entry[depth - 1] == @intFromPtr(class);
    }
}
// klass->methods is `const MethodInfo**`, an array of pointers, so unlike `fields` the slot
// holds the array rather than the first entry and needs one more dereference.
fn probeMethodArray(funcs: *const dotnet.Funcs, class: *const dotnet.Class, c: *Candidates) void {
    var iterator: ?*anyopaque = null;
    const first = funcs.class_get_methods(class, &iterator) orelse return;
    var total: u16 = 1;
    while (funcs.class_get_methods(class, &iterator)) |_| total += 1;
    for (&c.methods, 0..) |*alive, slot| {
        if (!alive.*) continue;
        const array = readPtr(class, slot);
        if (!readable(array, @sizeOf(usize))) {
            alive.* = false;
            continue;
        }
        const entry: *align(1) const usize = @ptrFromInt(array);
        alive.* = entry.* == @intFromPtr(first);
    }
    for (&c.method_count, 0..) |*alive, slot| {
        if (alive.*) alive.* = readU16(class, slot) == total;
    }
}

fn findClass(
    funcs: *const dotnet.Funcs,
    assemblies: []const *const dotnet.Assembly,
    namespace: [*:0]const u8,
    name: [*:0]const u8,
) ?*const dotnet.Class {
    for (assemblies) |assembly| {
        const image = funcs.kind.il2cpp.assembly_get_image(assembly);
        if (funcs.class_from_name(image, namespace, name)) |class| return class;
    }
    return null;
}

// The runtime holds pointers into a synthetic class (obj->klass, its typeHierarchy entries), so it
// must outlive the mutiny thread that built it. The arena is page-backed and never deinit'd, so its
// allocations live for the process; each `*_class` flag keeps its slot to one build and lets a
// re-attaching thread recover the class rather than build a second one the GC would then see twice.
const selftest_method_name = "MutinySentinel";
const selftest_sentinel: i32 = 0x5eed;
pub const global = struct {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

    var selftest_method: SyntheticMethod = undefined;
    var selftest_methods: [1]*const dotnet.Method = undefined;
    var selftest_class: ?SyntheticClass = null;

    var subclass_method: SyntheticMethod = undefined;
    var subclass_methods: [1]*const dotnet.Method = undefined;
    var subclass_class: ?SyntheticClass = null;

    pub var fromIl2CppTypeOrig: FromIl2CppType = undefined;
    var injected: ValuePerEnum(InjectedClassId, ?*const dotnet.Class) = .{
        .test_class = null,
    };
    fn getInjectedRef(class_id: InjectedClassId) *?*const dotnet.Class {
        return switch (class_id) {
            inline else => |ct| &@field(injected, @tagName(ct)),
        };
    }
    fn getInjected(class_id: InjectedClassId) ?*const dotnet.Class {
        return getInjectedRef(class_id).*;
    }
};

fn selftestPointer() callconv(.c) void {
    // reached only through invoker_method, never directly; loud rather than UB if that's ever false
    @panic("selftest methodPointer called directly");
}
fn selftestInvoke(
    _: MethodPointer,
    _: *const dotnet.Method,
    _: ?*anyopaque, // obj
    _: ?[*]?*anyopaque,
    out: ?*anyopaque,
) callconv(.c) void {
    const p: *align(1) i32 = @ptrCast(out.?);
    p.* = selftest_sentinel;
}

pub const SelfTestError = error{
    UnsupportedUnityVersion,
    MissingClass,
    AssignableFromWrong,
    FixedSizeInvalid,
    BasePolluted,
    OutOfMemory,
    TooManyMethods,
    BaseNotReadable,
    MethodNotFound,
    FoundWrongMethod,
    InvokeThrew,
    InvokeReturnedNull,
    WrongSentinel,
    BaseModified,
    BaseCorrupted,
    BaseNotInitialized,
    TypeHierarchyTooDeep,
    SubclassNotAssignable,
    SubclassAssignableBackwards,
    SubclassMethodNotFound,
    SubclassFoundWrongMethod,
    InheritedMethodNotFound,
    InheritedMethodWrong,
    IdentityBaselineNotBase,
    IdentityNotHooked,
};

// Validates class_fixed_size on this process, since a wrong header size is the one layout error the
// round-trip below can't see (method lookup and invoke never touch the inline vtable). The first
// VirtualInvokeData sits at fixed_size, its `method` one pointer in; for System.Object every vtable
// slot is one of its own virtual methods, so slot 0's method must appear in class_get_methods.
fn vtableStartsAt(funcs: *const dotnet.Funcs, base: *const dotnet.Class, fixed_size: usize) bool {
    if (!readable(@intFromPtr(base), fixed_size + vtable_entry_size)) return false;
    const bytes: [*]const u8 = @ptrCast(base);
    const slot0_method: *align(1) const usize = @ptrCast(bytes + fixed_size + @sizeOf(usize));
    const target = slot0_method.*;
    if (target == 0) return false;
    var it: ?*anyopaque = null;
    while (funcs.class_get_methods(base, &it)) |m| {
        if (@intFromPtr(m) == target) return true;
    }
    return false;
}

// Round-trips a synthetic class through real runtime code as an independent check of the Layout:
// build one over System.Object, find its method by name off it, invoke it, check the sentinel
// il2cpp boxes back, then confirm the base is untouched. class_get_method_from_name walks our
// overridden method table and Invoke reads our method's fields, so a wrong Layout makes real
// runtime code misbehave here. The value-type return turns a wrong invoker contract into a wrong
// number rather than something that merely didn't crash.
pub fn selfTest(
    funcs: *const dotnet.Funcs,
    assemblies: []const *const dotnet.Assembly,
    layouts: Layouts,
    unity_version: UnityVersion,
) SelfTestError!void {
    if (global.selftest_class != null) return; // already validated this process

    const fixed_size = try classFixedSize(unity_version);
    const base = findClass(funcs, assemblies, "System", "Object") orelse {
        std.log.err("il2cpp synthetic class: no System.Object to copy", .{});
        return error.MissingClass;
    };
    const int32 = findClass(funcs, assemblies, "System", "Int32") orelse {
        std.log.err("il2cpp synthetic class: no System.Int32 for the return type", .{});
        return error.MissingClass;
    };

    // class_is_assignable_from is the oracle the synthetic-subclass work leans on (it reads the
    // typeHierarchy this file discovers), so sanity-check the binding against a known relationship:
    // Int32 is-a Object, not the reverse. IsAssignableFrom runs Class::Init itself, no init needed.
    if (!funcs.class_is_assignable_from(base, int32) or
        funcs.class_is_assignable_from(int32, base) or
        !funcs.class_is_assignable_from(base, base))
    {
        std.log.err("il2cpp class_is_assignable_from gave a wrong answer on System.Object/System.Int32", .{});
        return error.AssignableFromWrong;
    }

    // System.Object may only be lazily set up after il2cpp_init. runtime_class_init runs its cctor,
    // which forces Class::Init transitively, so the copy inherits initialized == 1; otherwise it
    // inherits 0 and a later Class::Init on the synthetic class faults reading metadata that
    // describes the base, not it.
    funcs.kind.il2cpp.runtime_class_init(base);

    if (!vtableStartsAt(funcs, base, fixed_size)) {
        std.log.err("il2cpp class header size 0x{x} did not validate against {s}'s vtable", .{
            fixed_size,
            funcs.class_get_name(base),
        });
        return error.FixedSizeInvalid;
    }

    // non-interference baseline: the base must not already carry our method
    if (funcs.class_get_method_from_name(base, selftest_method_name, 0) != null) return error.BasePolluted;

    // flags default to PUBLIC instance (0x0006), see SyntheticMethod.init
    global.selftest_methods[0] = global.selftest_method.init(layouts.method, .{
        .name = selftest_method_name,
        .return_type = funcs.class_get_type(int32),
        .method_pointer = &selftestPointer,
        .invoker = &selftestInvoke,
        .parameters_count = 0,
    });
    var synth = try SyntheticClass.build(global.arena.allocator(), layouts.class, fixed_size, base, &global.selftest_methods);
    const klass = synth.class();
    global.selftest_method.setKlass(layouts.method, klass);

    const found = funcs.class_get_method_from_name(klass, selftest_method_name, 0) orelse {
        std.log.err("il2cpp synthetic class: could not find {s} off the new class", .{selftest_method_name});
        return error.MethodNotFound;
    };
    if (found != global.selftest_methods[0]) return error.FoundWrongMethod;

    var exc: ?*const dotnet.Object = null;
    const boxed = funcs.runtime_invoke(found, null, null, &exc);
    if (exc != null) return error.InvokeThrew;
    const unboxed: *align(1) const i32 = @ptrCast(funcs.object_unbox(boxed orelse return error.InvokeReturnedNull));
    if (unboxed.* != selftest_sentinel) {
        std.log.err("il2cpp synthetic class: invoke returned 0x{x}, expected 0x{x}", .{ unboxed.*, selftest_sentinel });
        return error.WrongSentinel;
    }
    // non-interference: the base we copied still lacks our method and its fields still validate
    if (funcs.class_get_method_from_name(base, selftest_method_name, 0) != null) return error.BaseModified;
    if (!validate(funcs, base, layouts.class)) return error.BaseCorrupted;

    global.selftest_class = synth;
    std.log.info("il2cpp synthetic class: copied System.Object, found and invoked {s}() -> 0x{x}, base untouched", .{
        selftest_method_name,
        @as(u32, @bitCast(unboxed.*)),
    });

    // object_new is deliberately not exercised here: it faults inside headless dotnet-test for
    // reasons not yet diagnosed - not simply "no GC", since the runtime's own boxing of our return
    // value above uses the GC and works. Instantiation belongs to the in-game path, where Unity's
    // AddComponent does it anyway, not to this fixture.
}

const subclass_update_name = "Update";

fn subclassUpdatePointer() callconv(.c) void {
    @panic("subclass Update methodPointer called directly");
}
fn subclassUpdateInvoke(
    _: MethodPointer,
    _: *const dotnet.Method,
    _: ?*anyopaque, // obj
    _: ?[*]?*anyopaque,
    _: ?*anyopaque, // void return, nothing to write
) callconv(.c) void {}

// The detour installs fromIl2CppTypeHook over the internal Class::FromIl2CppType. An injected class
// has no slot in the baked metadata table, so class_from_type(class_get_type(ours)) resolves to the
// base. We instead write a negative sentinel into our byval_arg.data (the Il2CppType class_get_type
// returns) and map it here; the hook returns ours when it sees data < 0, and passes everything else
// through. This is the identity AddComponent(Il2CppType.Of<ours>) needs, the same way Il2CppInterop
// does it.
// Mutiny injects one synthetic MonoBehaviour; its identity is this sentinel, written into
// byval_arg.data and mapped back by the hook. A second injected type adds its own sentinel and arm.

const InjectedClassId = enum(isize) {
    test_class = -1,
    pub fn fromType(t: *const dotnet.Type) ?InjectedClassId {
        const data: *const isize = @ptrCast(@alignCast(t)); // Il2CppType.data is the first field
        return std.enums.fromInt(InjectedClassId, data.*);
    }
};

pub const FromIl2CppType = *const fn (*const dotnet.Type, bool) callconv(.c) ?*const dotnet.Class;

pub fn fromIl2CppTypeHook(t: *const dotnet.Type, throw_on_error: bool) callconv(.c) ?*const dotnet.Class {
    return if (InjectedClassId.fromType(t)) |class_id|
        global.getInjected(class_id)
    else
        global.fromIl2CppTypeOrig(t, throw_on_error);
}

// this_arg.data wants the same write for the real AddComponent icall, but it has no public accessor;
// byval_arg is what class_get_type / Il2CppType.Of return and all the identity check needs.
fn registerInjected(
    id: InjectedClassId,
    class: *const dotnet.Class,
    funcs: *const dotnet.Funcs,
) void {
    const ref = global.getInjectedRef(id);
    std.debug.assert(ref.* == null);
    ref.* = class;
    const byval: *isize = @ptrCast(@alignCast(@constCast(funcs.class_get_type(class))));
    byval.* = @bitCast(@intFromEnum(id));
}

// Derives a subclass of UnityEngine.MonoBehaviour and checks the runtime agrees via the public
// IsAssignableFrom, exercising the discovered typeHierarchy offsets through real il2cpp code.
pub fn subclassSelfTest(
    funcs: *const dotnet.Funcs,
    assemblies: []const *const dotnet.Assembly,
    layouts: Layouts,
    unity_version: UnityVersion,
) SelfTestError!void {
    if (global.subclass_class != null) return; // already validated this process

    const fixed_size = try classFixedSize(unity_version);
    const mb = findClass(funcs, assemblies, "UnityEngine", "MonoBehaviour") orelse {
        std.log.err("il2cpp synthetic subclass: no UnityEngine.MonoBehaviour to derive from", .{});
        return error.MissingClass;
    };
    const void_class = findClass(funcs, assemblies, "System", "Void") orelse {
        std.log.err("il2cpp synthetic subclass: no System.Void for the Update return type", .{});
        return error.MissingClass;
    };
    // buildSubclass extends MonoBehaviour's typeHierarchy, which only Class::Init populates;
    // class_get_method_from_name forces that Init without running a static constructor.
    forceClassInit(funcs, mb);

    // a MonoBehaviour method to prove the subclass finds inherited methods through its parent;
    // skip constructors and anything shadowed by our own Update
    const inherited = blk: {
        var it: ?*anyopaque = null;
        while (funcs.class_get_methods(mb, &it)) |m| {
            const name = std.mem.span(funcs.method_get_name(m));
            if (std.mem.eql(u8, name, ".ctor")) continue;
            if (std.mem.eql(u8, name, ".cctor")) continue;
            if (std.mem.eql(u8, name, subclass_update_name)) continue;
            break :blk m;
        }
        std.log.err("il2cpp synthetic subclass: MonoBehaviour exposed no method to inherit", .{});
        return error.MissingClass;
    };
    const inherited_name = funcs.method_get_name(inherited);
    const inherited_params: c_int = @intCast(funcs.kind.il2cpp.method_get_param_count(inherited));

    global.subclass_methods[0] = global.subclass_method.init(layouts.method, .{
        .name = subclass_update_name,
        .return_type = funcs.class_get_type(void_class),
        .method_pointer = &subclassUpdatePointer,
        .invoker = &subclassUpdateInvoke,
        .parameters_count = 0,
    });
    var sub = try SyntheticClass.buildSubclass(
        global.arena.allocator(),
        layouts.class,
        fixed_size,
        mb,
        &global.subclass_methods,
    );
    const sub_class = sub.class();
    global.subclass_method.setKlass(layouts.method, sub_class);

    // real IsAssignableFrom reads the typeHierarchy we wrote: ours is-a MonoBehaviour, but not the
    // reverse, since ours is a distinct subclass rather than MonoBehaviour itself.
    if (!funcs.class_is_assignable_from(mb, sub_class)) return error.SubclassNotAssignable;
    if (funcs.class_is_assignable_from(sub_class, mb)) return error.SubclassAssignableBackwards;

    const update = funcs.class_get_method_from_name(sub_class, subclass_update_name, 0) orelse return error.SubclassMethodNotFound;
    if (update != global.subclass_methods[0]) return error.SubclassFoundWrongMethod;
    const found_inherited = funcs.class_get_method_from_name(sub_class, inherited_name, inherited_params) orelse return error.InheritedMethodNotFound;
    if (found_inherited != inherited) return error.InheritedMethodWrong;

    // Identity through the installed hook: byval_arg still holds MonoBehaviour's copied typeHandle, so
    // class_from_type resolves to the base; after the sentinel write it resolves to ours.
    const sub_type = funcs.class_get_type(sub_class);
    if (funcs.class_from_type(sub_type) != mb) return error.IdentityBaselineNotBase;
    registerInjected(.test_class, sub_class, funcs);
    if (funcs.class_from_type(sub_type) != sub_class) return error.IdentityNotHooked;

    global.subclass_class = sub;
    std.log.info("il2cpp synthetic subclass: assignable, Update resolves, {s} inherited", .{
        std.mem.span(inherited_name),
    });
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;

const dotnet = @import("dotnet.zig");

const UnityVersion = @import("UnityVersion.zig");
const ValuePerEnum = @import("valueperenum.zig").ValuePerEnum;
