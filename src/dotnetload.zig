pub fn resolve(comptime T: type, kind: Kind, module: dynlib.Module, proc_ref: *[:0]const u8) error{ProcNotFound}!T {
    return resolveSet(T, kind, null, module, proc_ref);
}

pub fn resolveOnly(comptime T: type, comptime kind: Kind, module: dynlib.Module, proc_ref: *[:0]const u8) error{ProcNotFound}!T {
    return resolveSet(T, kind, kind, module, proc_ref);
}

pub fn resolveMono(comptime T: type, module: dynlib.Module, proc_ref: *[:0]const u8) error{ProcNotFound}!T {
    return resolveGroup(T, .mono, module, proc_ref);
}

pub fn resolveIl2cpp(comptime T: type, module: dynlib.Module, proc_ref: *[:0]const u8) error{ProcNotFound}!T {
    return resolveGroup(T, .il2cpp, module, proc_ref);
}

const Group = enum { shared, mono, il2cpp };

fn catalog(comptime group: Group) type {
    return switch (group) {
        .shared => dotnet.shared,
        .mono => dotnet.mono,
        .il2cpp => dotnet.il2cpp,
    };
}

fn resolveSet(
    comptime T: type,
    kind: Kind,
    comptime only: ?Kind,
    module: dynlib.Module,
    proc_ref: *[:0]const u8,
) error{ProcNotFound}!T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const F = field.type;
        @field(result, field.name) = if (comptime isFnPtr(F)) blk: {
            comptime checkSignature(.shared, F, field.name);
            break :blk try getProc(F, module, switch (kind) {
                .mono => comptime exportName(.shared, .mono, field.name),
                .il2cpp => comptime exportName(.shared, .il2cpp, field.name),
            }, proc_ref);
        } else if (comptime std.mem.eql(u8, field.name, "kind")) blk: {
            if (only) |o| @compileError(@typeName(T) ++ " has a 'kind' union but is composed into a " ++ @tagName(o) ++ "-only set");
            break :blk switch (kind) {
                .mono => .{ .mono = try resolveGroup(@FieldType(F, "mono"), .mono, module, proc_ref) },
                .il2cpp => .{ .il2cpp = try resolveGroup(@FieldType(F, "il2cpp"), .il2cpp, module, proc_ref) },
            };
        } else if (comptime std.mem.eql(u8, field.name, "mono")) blk: {
            if (only != .mono) @compileError(@typeName(T) ++ " has mono-only functions, so it can only be composed under a set's kind.mono");
            break :blk try resolveGroup(F, .mono, module, proc_ref);
        } else if (comptime std.mem.eql(u8, field.name, "il2cpp")) blk: {
            if (only != .il2cpp) @compileError(@typeName(T) ++ " has il2cpp-only functions, so it can only be composed under a set's kind.il2cpp");
            break :blk try resolveGroup(F, .il2cpp, module, proc_ref);
        } else try resolveSet(F, kind, only, module, proc_ref);
    }
    return result;
}

fn resolveGroup(
    comptime T: type,
    comptime group: Kind,
    module: dynlib.Module,
    proc_ref: *[:0]const u8,
) error{ProcNotFound}!T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const F = field.type;
        @field(result, field.name) = if (comptime isFnPtr(F)) blk: {
            comptime checkSignature(switch (group) {
                .mono => .mono,
                .il2cpp => .il2cpp,
            }, F, field.name);
            break :blk try getProc(F, module, comptime exportName(switch (group) {
                .mono => .mono,
                .il2cpp => .il2cpp,
            }, group, field.name), proc_ref);
        } else if (comptime @hasDecl(F, "resolve"))
            try F.resolve(module, proc_ref)
        else
            try resolveSet(F, group, group, module, proc_ref);
    }
    return result;
}

fn isFnPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| @typeInfo(p.child) == .@"fn",
        else => false,
    };
}

fn checkSignature(comptime group: Group, comptime F: type, comptime name: []const u8) void {
    const C = catalog(group);
    if (!@hasDecl(C, name)) @compileError("'" ++ name ++ "' is not a dotnet." ++ @tagName(group) ++ " function");
    if (F != *const @field(C, name)) @compileError("the field '" ++ name ++ "' must have type *const dotnet." ++ @tagName(group) ++ "." ++ name);
}

fn exportName(comptime group: Group, comptime kind: Kind, comptime name: [:0]const u8) [:0]const u8 {
    const C = catalog(group);
    if (@hasDecl(C, "export_names") and @hasDecl(C.export_names, name)) {
        const names: dotnet.ExportNames = @field(C.export_names, name);
        const override = switch (kind) {
            .mono => names.mono,
            .il2cpp => names.il2cpp,
        };
        if (override) |o| return o;
    }
    return switch (kind) {
        .mono => "mono_" ++ name,
        .il2cpp => "il2cpp_" ++ name,
    };
}

fn getProc(comptime F: type, module: dynlib.Module, name: [:0]const u8, proc_ref: *[:0]const u8) error{ProcNotFound}!F {
    proc_ref.* = name;
    const proc = dynlib.getProc(module, name) catch |err| switch (err) {
        error.ProcNotFound => return error.ProcNotFound,
        error.Unexpected => std.debug.panic(
            "GetProc '{s}' on dotnet DLL failed with {s}",
            .{ name, @errorName(err) },
        ),
    };
    return @ptrCast(@alignCast(proc));
}

const std = @import("std");
const dynlib = @import("dynlib.zig");
const dotnet = @import("dotnet.zig");
const Kind = @import("dotnetkind.zig").Kind;
