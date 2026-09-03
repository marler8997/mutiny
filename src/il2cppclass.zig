// Offsets are discovered by probing with the public API rather than mirroring Il2CppClass,
// which embeds two Il2CppType bitfield structs: one packing mistake there would silently
// shift every later offset while we write into live runtime memory.
const scan_len = 0x180;
const ptr_slots = scan_len / @sizeOf(usize);
const u16_slots = scan_len / @sizeOf(u16);
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
    return funcs.class_get_fields(class, &iterator) == null;
}

// A synthetic class cannot be found by name: ClassFromName resolves through a metadata type
// handle that indexes the metadata cache's type table, which we cannot extend. So methods are
// appended to a class that is already resolvable.
pub fn appendMethods(
    l: Layout,
    // performs a single allocation, ok to use std.heap.page_allocator
    allocator: std.mem.Allocator,
    class: *const dotnet.Class,
    new_methods: []const *const dotnet.Method,
) error{ OutOfMemory, TooManyMethods }!void {
    const base: [*]u8 = @ptrCast(@constCast(class));
    const methods: *align(1) [*]const *const dotnet.Method = @ptrCast(base + l.methods);
    const method_count: *align(1) u16 = @ptrCast(base + l.method_count);

    const existing = method_count.*;
    // becomes the class's method array, so it is never freed
    const grown = try allocator.alloc(*const dotnet.Method, existing + new_methods.len);
    @memcpy(grown[0..existing], methods.*[0..existing]);
    @memcpy(grown[existing..], new_methods);

    // Class::GetMethods recomputes its end bound from these fields on every step, so a walk
    // running concurrently compares a pointer into the old array against a bound derived from
    // the new one and can run off the end. There is no store order that fixes that; callers
    // must not append while another thread may be enumerating this class's methods.
    methods.* = grown.ptr;
    method_count.* = std.math.cast(u16, grown.len) orelse return error.TooManyMethods;
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
    const class_layout = candidates.resolve() orelse {
        report("fields", &candidates.fields, @sizeOf(usize));
        report("field_count", &candidates.field_count, @sizeOf(u16));
        report("methods", &candidates.methods, @sizeOf(usize));
        report("method_count", &candidates.method_count, @sizeOf(u16));
        return error.ClassLayoutNotResolved;
    };
    // the vtable_count inference rides on the u16 count block's order; the probe pins
    // method_count and field_count independently, so their spacing confirms it at runtime
    if (class_layout.field_count != class_layout.method_count + 4) {
        std.log.err("il2cpp field_count (0x{x}) is not method_count (0x{x}) + 4", .{
            class_layout.field_count,
            class_layout.method_count,
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
    std.log.info("il2cpp layout: probed {} classes and {} methods, validated {} classes", .{
        candidates.classes_probed,
        method_candidates.methods_probed,
        validated,
    });
    return .{ .class = class_layout, .method = method_layout };
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
const Candidates = struct {
    fields: [ptr_slots]bool = @splat(true),
    field_count: [u16_slots]bool = @splat(true),
    methods: [ptr_slots]bool = @splat(true),
    method_count: [u16_slots]bool = @splat(true),
    classes_probed: u32 = 0,
    pub fn init() Candidates {
        return .{};
    }
    pub fn resolve(c: *const Candidates) ?Layout {
        const method_count = only(&c.method_count, @sizeOf(u16)) orelse return null;
        return .{
            .fields = only(&c.fields, @sizeOf(usize)) orelse return null,
            .field_count = only(&c.field_count, @sizeOf(u16)) orelse return null,
            .methods = only(&c.methods, @sizeOf(usize)) orelse return null,
            .method_count = method_count,
            .vtable_count = method_count + 10,
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

// A class we own, so a synthetic method can be found off it without mutating a real class (which
// is what appendMethods does). It copies an initialized base class's whole allocation and
// overrides the method table, so instance_size, gc_desc, init flags and the vtable are inherited
// correct-by-construction. typeMetadataHandle is left as the base's: copying an already-initialized
// class means Class::Init never re-runs to read it; a MonoBehaviour Unity inspects will need it
// NULLed, a later stage. The copy also keeps the base's name and type identity, so class_get_type
// on it resolves back to the base and logs will name it after the base.
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
        const total = fixed_size + @as(usize, l.vtableCountOf(base)) * vtable_entry_size;
        // vtable_count is the one inferred offset; a wrong read here could make total ~1MB, so
        // bound the copy source to the base's actual pages rather than reading off the heap.
        if (!readable(@intFromPtr(base), total)) return error.BaseNotReadable;
        const storage = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(usize)), total);
        @memcpy(storage, @as([*]const u8, @ptrCast(base))[0..total]);

        const methods_field: *align(1) [*]const *const dotnet.Method = @ptrCast(storage.ptr + l.methods);
        const method_count_field: *align(1) u16 = @ptrCast(storage.ptr + l.method_count);
        methods_field.* = methods.ptr;
        method_count_field.* = method_count;
        return .{ .storage = storage };
    }
    pub fn class(self: SyntheticClass) *const dotnet.Class {
        return @ptrCast(self.storage.ptr);
    }
};
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
// Narrows `fields` and `field_count` using one class. Read-only: no static constructor is
// run and no guessed pointer is dereferenced, so this is safe to sweep over every class in a
// game. Classes with differing field counts are what separate field_count from the
// method/property/event counts sitting beside it.
fn probeFields(funcs: *const dotnet.Funcs, class: *const dotnet.Class, c: *Candidates) void {
    // Il2CppClass is 0x138 plus 0x10 per vtable entry, so a class with few virtuals is
    // smaller than scan_len and the sweep would read past its allocation.
    if (!readable(@intFromPtr(class), scan_len)) return;
    probeMethodArray(funcs, class, c);

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

// Kept alive for the life of the process: the class points at the method array and the method
// points back at the class. selftest_class is set only after a run fully validates, so a failed run
// leaves it null and the next retries (leaking the previous copy's page, which is fine here).
const selftest_method_name = "MutinySentinel";
const selftest_sentinel: i32 = 0x5eed;
var selftest_method: SyntheticMethod = undefined;
var selftest_methods: [1]*const dotnet.Method = undefined;
var selftest_class: ?SyntheticClass = null;

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
    if (selftest_class != null) return; // already validated this process

    const fixed_size = try classFixedSize(unity_version);
    const base = findClass(funcs, assemblies, "System", "Object") orelse {
        std.log.err("il2cpp synthetic class: no System.Object to copy", .{});
        return error.MissingClass;
    };
    const int32 = findClass(funcs, assemblies, "System", "Int32") orelse {
        std.log.err("il2cpp synthetic class: no System.Int32 for the return type", .{});
        return error.MissingClass;
    };

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
    selftest_methods[0] = selftest_method.init(layouts.method, .{
        .name = selftest_method_name,
        .return_type = funcs.class_get_type(int32),
        .method_pointer = &selftestPointer,
        .invoker = &selftestInvoke,
        .parameters_count = 0,
    });
    var synth = try SyntheticClass.build(std.heap.page_allocator, layouts.class, fixed_size, base, &selftest_methods);
    const klass = synth.class();
    selftest_method.setKlass(layouts.method, klass);

    const found = funcs.class_get_method_from_name(klass, selftest_method_name, 0) orelse {
        std.log.err("il2cpp synthetic class: could not find {s} off the new class", .{selftest_method_name});
        return error.MethodNotFound;
    };
    if (found != selftest_methods[0]) return error.FoundWrongMethod;

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

    selftest_class = synth; // validated; keep the copy alive for the process (never freed, see above)
    std.log.info("il2cpp synthetic class: copied System.Object, found and invoked {s}() -> 0x{x}, base untouched", .{
        selftest_method_name,
        @as(u32, @bitCast(unboxed.*)),
    });

    // object_new is deliberately not exercised here: it faults inside headless dotnet-test for
    // reasons not yet diagnosed - not simply "no GC", since the runtime's own boxing of our return
    // value above uses the GC and works. Instantiation belongs to the in-game path, where Unity's
    // AddComponent does it anyway, not to this fixture.
}

const builtin = @import("builtin");
const std = @import("std");
const dotnet = @import("dotnet.zig");
const win32 = @import("win32").everything;
const UnityVersion = @import("UnityVersion.zig");
