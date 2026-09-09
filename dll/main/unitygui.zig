const global = struct {
    var state: State = .pending;
    var panel: Panel = .{};
};

const Rect = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    fn contains(rect: Rect, x: f32, y: f32) bool {
        return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height;
    }
};

const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const disabled: Color = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 };
    const background: Color = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 0.9 };
    const outline: Color = .{ .r = 0.75, .g = 0.75, .b = 0.75, .a = 1 };
    const mod_name: Color = .{ .r = 0.55, .g = 0.8, .b = 1, .a = 1 };
    const status_error: Color = .{ .r = 1, .g = 0.4, .b = 0.4, .a = 1 };
};

const Gui = struct {
    label: *const dotnet.Method,
    styled_label: *const dotnet.Method,
    set_color: *const dotnet.Method,
    event_current: *const dotnet.Method,
    event_type: *const dotnet.Method,
    event_button: *const dotnet.Method,
    event_mouse_position: *const dotnet.Method,
    event_use: *const dotnet.Method,
    fill_style: dotnet.GcHandleV2,
    empty: dotnet.GcHandleV2,
    title: dotnet.GcHandleV2,
    expanded: dotnet.GcHandleV2,
    collapsed: dotnet.GcHandleV2,
};

const EventType = enum(i32) {
    mouse_down = 0,
    mouse_up = 1,
    mouse_drag = 3,
    repaint = 7,
    _,
};

const State = union(enum) {
    pending,
    unavailable,
    ready: Gui,
};

const Panel = struct {
    x: f32 = 8,
    y: f32 = 8,
    minimized: bool = false,
    drag: ?struct { dx: f32, dy: f32 } = null,
};

pub const ModLabel = struct {
    name: dotnet.GcHandleV2 = .null,
    status: dotnet.GcHandleV2 = .null,
    status_wyhash: u64 = 0,

    pub fn deinit(label: *ModLabel, dotnet_funcs: *const dotnet.Funcs) void {
        if (label.name != .null) dotnet_funcs.gchandle_free(label.name);
        if (label.status != .null) dotnet_funcs.gchandle_free(label.status);
        label.* = undefined;
    }
};

const line_height: f32 = 20;
const width: f32 = 640;
const margin: f32 = 8;
const title_height: f32 = 24;
const button_size: f32 = 20;
const button_inset: f32 = (title_height - button_size) / 2;
const minimized_width: f32 = 120;
const outline_thickness: f32 = 2;
const name_column: f32 = 220;
const checkbox_size: f32 = 14;
const checkbox_inset: f32 = (line_height - checkbox_size) / 2;
const checkbox_column: f32 = checkbox_size + margin;
const title = "Mutiny";

pub fn draw(dotnet_funcs: *const dotnet.Funcs) void {
    const gui = state: switch (global.state) {
        .pending => {
            global.state = if (resolve(dotnet_funcs)) |gui| .{ .ready = gui } else |err| unavailable: {
                std.log.err("unity gui disabled: {t}", .{err});
                break :unavailable .unavailable;
            };
            continue :state global.state;
        },
        .unavailable => return,
        .ready => |*gui| gui,
    };

    var context: Context = .{ .dotnet_funcs = dotnet_funcs, .gui = gui };
    const event = context.call(gui.event_current, null, null) orelse return;
    const event_type: EventType = @enumFromInt(context.unbox(i32, gui.event_type, event) orelse return);
    switch (event_type) {
        .repaint, .mouse_down, .mouse_up, .mouse_drag => {},
        _ => return,
    }

    var count: usize = 0;
    var it = mods.modIterator();
    while (it.next()) |_| count += 1;
    if (count == 0) return;

    const panel = &global.panel;
    const content_height: f32 = if (panel.minimized) 0 else line_height * @as(f32, @floatFromInt(count)) + margin * 2;
    const box: Rect = .{
        .x = panel.x,
        .y = panel.y,
        .width = if (panel.minimized) minimized_width else width,
        .height = title_height + content_height,
    };
    const button: Rect = .{
        .x = box.x + button_inset,
        .y = box.y + button_inset,
        .width = button_size,
        .height = button_size,
    };

    switch (event_type) {
        .repaint => paint(&context, panel, box, button),
        .mouse_down, .mouse_up, .mouse_drag => {
            if ((context.unbox(i32, gui.event_button, event) orelse return) != 0) return;
            const position = context.unbox([2]f32, gui.event_mouse_position, event) orelse return;
            const x = position[0];
            const y = position[1];
            switch (event_type) {
                .mouse_down => if (button.contains(x, y)) {
                    panel.minimized = !panel.minimized;
                    context.use(event);
                } else if (if (panel.minimized) null else checkboxAt(box, x, y)) |mod| {
                    const enable = !mod.enabled();
                    std.debug.assert(mod.setEnabled(enable) == .changed);
                    std.log.info("mod '{s}' {s} from the panel", .{ mod.name.slice(), if (enable) "enabled" else "disabled" });
                    context.use(event);
                } else if (box.contains(x, y)) {
                    panel.drag = .{ .dx = x - panel.x, .dy = y - panel.y };
                    context.use(event);
                },
                .mouse_drag => if (panel.drag) |drag| {
                    panel.x = x - drag.dx;
                    panel.y = y - drag.dy;
                    context.use(event);
                },
                .mouse_up => if (panel.drag != null) {
                    panel.drag = null;
                    context.use(event);
                },
                else => unreachable,
            }
        },
        _ => unreachable,
    }
}

fn paint(context: *Context, panel: *const Panel, box: Rect, button: Rect) void {
    const gui = context.gui;
    context.fill(box, .background);
    context.outline(box);
    context.color(.white);
    context.label(.{ .x = button.x + 4, .y = button.y, .width = button_size, .height = button_size }, if (panel.minimized) gui.collapsed else gui.expanded);
    context.label(.{ .x = button.x + button_size + button_inset, .y = box.y, .width = box.width - button_size - button_inset * 3, .height = title_height }, gui.title);
    if (panel.minimized) return;

    var y = box.y + title_height + margin;
    var it = mods.modIterator();
    while (it.next()) |mod| : (y += line_height) {
        const strings = context.modStrings(mod) orelse return;
        const check = checkboxRect(box, y);
        context.outline(check);
        if (mod.enabled()) context.fill(.{
            .x = check.x + 3,
            .y = check.y + 3,
            .width = check.width - 6,
            .height = check.height - 6,
        }, .white);
        const x = box.x + margin + checkbox_column;
        context.color(if (mod.enabled()) .mod_name else .disabled);
        context.label(.{ .x = x, .y = y, .width = name_column, .height = line_height }, strings.name);
        context.color(switch (mod.statusText().kind) {
            .disabled => .disabled,
            .ok => .white,
            .err => .status_error,
        });
        context.label(.{ .x = x + name_column, .y = y, .width = width - margin * 2 - checkbox_column - name_column, .height = line_height }, strings.status);
    }
    context.color(.white);
}

fn checkboxRect(box: Rect, row_y: f32) Rect {
    return .{
        .x = box.x + margin,
        .y = row_y + checkbox_inset,
        .width = checkbox_size,
        .height = checkbox_size,
    };
}

fn checkboxAt(box: Rect, x: f32, y: f32) ?*Mod {
    var row_y = box.y + title_height + margin;
    var it = mods.modIterator();
    while (it.next()) |mod| : (row_y += line_height) {
        if (checkboxRect(box, row_y).contains(x, y)) return mod;
    }
    return null;
}

const Context = struct {
    dotnet_funcs: *const dotnet.Funcs,
    gui: *const Gui,
    current_color: ?Color = null,

    fn use(context: *Context, event: *const dotnet.Object) void {
        _ = context.call(context.gui.event_use, event, null);
    }

    fn color(context: *Context, c: Color) void {
        if (context.current_color) |current| if (std.meta.eql(current, c)) return;
        var arg = c;
        var args = [_]*anyopaque{@ptrCast(&arg)};
        _ = context.call(context.gui.set_color, null, @ptrCast(&args));
        context.current_color = c;
    }

    fn fill(context: *Context, rect: Rect, c: Color) void {
        context.color(c);
        const empty = context.dotnet_funcs.gchandle_get_target(context.gui.empty) orelse return;
        const style = context.dotnet_funcs.gchandle_get_target(context.gui.fill_style) orelse return;
        var rect_arg = rect;
        var args = [_]*anyopaque{ @ptrCast(&rect_arg), @constCast(empty), @constCast(style) };
        _ = context.call(context.gui.styled_label, null, @ptrCast(&args));
    }

    fn outline(context: *Context, rect: Rect) void {
        const t = outline_thickness;
        context.fill(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = t }, .outline);
        context.fill(.{ .x = rect.x, .y = rect.y + rect.height - t, .width = rect.width, .height = t }, .outline);
        context.fill(.{ .x = rect.x, .y = rect.y, .width = t, .height = rect.height }, .outline);
        context.fill(.{ .x = rect.x + rect.width - t, .y = rect.y, .width = t, .height = rect.height }, .outline);
    }

    fn label(context: *Context, rect: Rect, text: dotnet.GcHandleV2) void {
        const string = context.dotnet_funcs.gchandle_get_target(text) orelse return;
        var rect_arg = rect;
        var args = [_]*anyopaque{ @ptrCast(&rect_arg), @constCast(string) };
        _ = context.call(context.gui.label, null, @ptrCast(&args));
    }

    fn modStrings(context: *Context, mod: *Mod) ?struct { name: dotnet.GcHandleV2, status: dotnet.GcHandleV2 } {
        const dotnet_funcs = context.dotnet_funcs;
        if (mod.label.name == .null) {
            mod.label.name = newString(dotnet_funcs, mod.name.slice()) orelse return null;
        }
        const status_text = mod.statusText().text;
        const status_wyhash = std.hash.Wyhash.hash(0, status_text);
        if (mod.label.status == .null or mod.label.status_wyhash != status_wyhash) {
            if (mod.label.status != .null) dotnet_funcs.gchandle_free(mod.label.status);
            mod.label.status = newString(dotnet_funcs, status_text) orelse return null;
            mod.label.status_wyhash = status_wyhash;
        }
        return .{ .name = mod.label.name, .status = mod.label.status };
    }

    fn unbox(context: *Context, comptime T: type, method: *const dotnet.Method, obj: *const dotnet.Object) ?T {
        const boxed = context.call(method, obj, null) orelse return null;
        const value: *align(1) const T = @ptrCast(context.dotnet_funcs.object_unbox(boxed));
        return value.*;
    }

    fn call(context: *Context, method: *const dotnet.Method, obj: ?*const dotnet.Object, args: ?**anyopaque) ?*const dotnet.Object {
        if (global.state != .ready) return null;
        return invoke(context.dotnet_funcs, method, obj, args) catch |err| switch (err) {
            error.ManagedException => {
                global.state = .unavailable;
                return null;
            },
        };
    }
};

fn newString(dotnet_funcs: *const dotnet.Funcs, text: []const u8) ?dotnet.GcHandleV2 {
    const string = dotnet_funcs.string_new_len(text.ptr, @intCast(text.len)) orelse {
        std.log.err("unity gui disabled: string_new_len failed for {} bytes", .{text.len});
        global.state = .unavailable;
        return null;
    };
    return dotnet_funcs.gchandle_new(@ptrCast(string), false);
}

fn invoke(
    dotnet_funcs: *const dotnet.Funcs,
    method: *const dotnet.Method,
    obj: ?*const dotnet.Object,
    args: ?**anyopaque,
) error{ManagedException}!?*const dotnet.Object {
    var exception: ?*const dotnet.Object = null;
    const result = dotnet_funcs.runtime_invoke(method, obj, args, &exception);
    if (exception) |e| {
        std.log.err("unity gui disabled: {s} threw {s}", .{
            dotnet_funcs.method_get_name(method),
            dotnet_funcs.class_get_name(dotnet_funcs.object_get_class(e)),
        });
        return error.ManagedException;
    }
    return result;
}

const ResolveError = error{
    NoImguiModule,
    NoCoreModule,
    NoGuiClass,
    NoLabelMethod,
    NoStyledLabelMethod,
    NoSetColorMethod,
    NoEventClass,
    NoEventMethod,
    NoStyleClass,
    NoStyleMethod,
    NoTextureMethod,
    ObjectNewFailed,
    StringNewFailed,
    ManagedException,
};

fn resolve(dotnet_funcs: *const dotnet.Funcs) ResolveError!Gui {
    const imgui = findImage(dotnet_funcs, "UnityEngine.IMGUIModule") orelse return error.NoImguiModule;
    const core = findImage(dotnet_funcs, "UnityEngine.CoreModule") orelse return error.NoCoreModule;
    const gui_class = dotnet_funcs.class_from_name(imgui, "UnityEngine", "GUI") orelse return error.NoGuiClass;
    const event_class = dotnet_funcs.class_from_name(imgui, "UnityEngine", "Event") orelse return error.NoEventClass;
    const style_class = dotnet_funcs.class_from_name(imgui, "UnityEngine", "GUIStyle") orelse return error.NoStyleClass;
    const style_state_class = dotnet_funcs.class_from_name(imgui, "UnityEngine", "GUIStyleState") orelse return error.NoStyleClass;
    const texture2d_class = dotnet_funcs.class_from_name(core, "UnityEngine", "Texture2D") orelse return error.NoTextureMethod;

    const style_ctor = dotnet_funcs.class_get_method_from_name(style_class, ".ctor", 0) orelse return error.NoStyleMethod;
    const get_normal = dotnet_funcs.class_get_method_from_name(style_class, "get_normal", 0) orelse return error.NoStyleMethod;
    const set_background = dotnet_funcs.class_get_method_from_name(style_state_class, "set_background", 1) orelse return error.NoStyleMethod;
    const get_white_texture = dotnet_funcs.class_get_method_from_name(texture2d_class, "get_whiteTexture", 0) orelse return error.NoTextureMethod;

    const style = dotnet_funcs.object_new(style_class) orelse return error.ObjectNewFailed;
    _ = try invoke(dotnet_funcs, style_ctor, style, null);
    const white = try invoke(dotnet_funcs, get_white_texture, null, null) orelse return error.ObjectNewFailed;
    const normal = try invoke(dotnet_funcs, get_normal, style, null) orelse return error.ObjectNewFailed;
    var set_background_args = [_]*anyopaque{@constCast(white)};
    _ = try invoke(dotnet_funcs, set_background, normal, @ptrCast(&set_background_args));

    return .{
        .label = findLabelMethod(dotnet_funcs, gui_class, 2) orelse return error.NoLabelMethod,
        .styled_label = findLabelMethod(dotnet_funcs, gui_class, 3) orelse return error.NoStyledLabelMethod,
        .set_color = dotnet_funcs.class_get_method_from_name(gui_class, "set_color", 1) orelse return error.NoSetColorMethod,
        .event_current = dotnet_funcs.class_get_method_from_name(event_class, "get_current", 0) orelse return error.NoEventMethod,
        .event_type = dotnet_funcs.class_get_method_from_name(event_class, "get_type", 0) orelse return error.NoEventMethod,
        .event_button = dotnet_funcs.class_get_method_from_name(event_class, "get_button", 0) orelse return error.NoEventMethod,
        .event_mouse_position = dotnet_funcs.class_get_method_from_name(event_class, "get_mousePosition", 0) orelse return error.NoEventMethod,
        .event_use = dotnet_funcs.class_get_method_from_name(event_class, "Use", 0) orelse return error.NoEventMethod,
        .fill_style = dotnet_funcs.gchandle_new(style, false),
        .empty = try resolveString(dotnet_funcs, ""),
        .title = try resolveString(dotnet_funcs, title),
        .expanded = try resolveString(dotnet_funcs, "\u{25BC}"),
        .collapsed = try resolveString(dotnet_funcs, "\u{25B6}"),
    };
}

fn resolveString(dotnet_funcs: *const dotnet.Funcs, text: []const u8) error{StringNewFailed}!dotnet.GcHandleV2 {
    const string = dotnet_funcs.string_new_len(text.ptr, @intCast(text.len)) orelse return error.StringNewFailed;
    return dotnet_funcs.gchandle_new(@ptrCast(string), false);
}

fn findLabelMethod(dotnet_funcs: *const dotnet.Funcs, class: *const dotnet.Class, param_count: usize) ?*const dotnet.Method {
    var iterator: ?*anyopaque = null;
    while (dotnet_funcs.class_get_methods(class, &iterator)) |method| {
        if (!std.mem.eql(u8, std.mem.span(dotnet_funcs.method_get_name(method)), "Label")) continue;
        const params = paramTypes(dotnet_funcs, method);
        if (params.len != param_count) continue;
        if (!paramIsClass(dotnet_funcs, params.types[0], .valuetype, "Rect")) continue;
        if (dotnet_funcs.type_get_type(params.types[1]) != .string) continue;
        if (param_count == 3 and !paramIsClass(dotnet_funcs, params.types[2], .class, "GUIStyle")) continue;
        return method;
    }
    return null;
}

fn paramIsClass(dotnet_funcs: *const dotnet.Funcs, param: *const dotnet.Type, kind: dotnet.TypeKind, name: []const u8) bool {
    if (dotnet_funcs.type_get_type(param) != kind) return false;
    const class = dotnet_funcs.class_from_type(param) orelse return false;
    return std.mem.eql(u8, std.mem.span(dotnet_funcs.class_get_name(class)), name);
}

const ParamTypes = struct {
    types: [4]*const dotnet.Type,
    len: usize,
};

fn paramTypes(dotnet_funcs: *const dotnet.Funcs, method: *const dotnet.Method) ParamTypes {
    var result: ParamTypes = .{ .types = undefined, .len = 0 };
    switch (dotnet_funcs.kind) {
        .mono => |*mono| {
            const sig = mono.method_signature(method) orelse return result;
            var iter: ?*anyopaque = null;
            while (mono.signature_get_params(sig, &iter)) |param_type| {
                if (result.len == result.types.len) {
                    result.len += 1;
                    return result;
                }
                result.types[result.len] = param_type;
                result.len += 1;
            }
        },
        .il2cpp => |*il2cpp| {
            const count = il2cpp.method_get_param_count(method);
            if (count > result.types.len) {
                result.len = count;
                return result;
            }
            for (0..count) |i| result.types[i] = il2cpp.method_get_param(method, @intCast(i));
            result.len = count;
        },
    }
    return result;
}

fn findImage(dotnet_funcs: *const dotnet.Funcs, name: []const u8) ?*const dotnet.Image {
    switch (dotnet_funcs.kind) {
        .mono => |*mono| {
            var ctx: FindImageMono = .{ .dotnet_funcs = dotnet_funcs, .needle = name };
            mono.assembly_foreach(&findImageMonoCallback, &ctx);
            return ctx.match;
        },
        .il2cpp => |*il2cpp| {
            var count: usize = 0;
            const assemblies = il2cpp.domain_get_assemblies(dotnet_funcs.domain_get().?, &count);
            for (assemblies[0..count]) |assembly| {
                const image = il2cpp.assembly_get_image(assembly);
                const image_name = std.mem.span(il2cpp.image_get_name(image));
                if (std.mem.eql(u8, image_name, name) or
                    (std.mem.endsWith(u8, image_name, ".dll") and std.mem.eql(u8, image_name[0 .. image_name.len - 4], name)))
                    return image;
            }
            return null;
        },
    }
}

const FindImageMono = struct {
    dotnet_funcs: *const dotnet.Funcs,
    needle: []const u8,
    match: ?*const dotnet.Image = null,
};

fn findImageMonoCallback(assembly_opaque: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const assembly: *const dotnet.Assembly = @ptrCast(assembly_opaque);
    const ctx: *FindImageMono = @ptrCast(@alignCast(user_data));
    if (ctx.match != null) return;
    const mono = &ctx.dotnet_funcs.kind.mono;
    const name = mono.assembly_get_name(assembly) orelse return;
    const str = mono.assembly_name_get_name(name) orelse return;
    if (!std.mem.eql(u8, std.mem.span(str), ctx.needle)) return;
    ctx.match = ctx.dotnet_funcs.assembly_get_image(assembly);
}

const std = @import("std");
const mutiny = @import("mutiny");

const dotnet = mutiny.dotnet;
const mods = @import("mods.zig");

const Mod = @import("Mod.zig");
